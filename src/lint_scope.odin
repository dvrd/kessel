package kessel

// ============================================================================
// Lint — scope-aware rules (M3): no-undef (L2006), no-unused-vars (L2007),
// no-shadow (L2008).
//
// These rules cannot be decided from a single node: they need the binding /
// reference structure of the whole program. So, unlike the AST-local rules in
// lint.odin (which fan out per node in one #complete walk), they run as a
// dedicated TWO-PHASE pass:
//
//   Phase 1 (collect): walk the AST once, building a scope tree. Each scope
//     records its declared bindings (with var/function hoisting to the nearest
//     function scope) and the identifier references that occur inside it.
//   Phase 2 (resolve): diff bindings against references.
//       • no-undef       — a reference resolving to no binding in any enclosing
//                           scope and not a known global.
//       • no-unused-vars  — a non-root local binding never referenced.
//       • no-shadow       — a binding whose name is also declared in an
//                           enclosing scope.
//
// This mirrors regex.odin's justified multi-pass design (the named-group walk
// is the in-tree precedent): the scope chain has a different granularity than
// the per-node rule fan-out, so forcing it into the lint.odin visitor would be
// anti-TigerStyle. The collector uses a `#partial switch` (not `#complete`)
// because it only needs the node forms that introduce bindings or references;
// every other node is a leaf for scope purposes and carries neither.
//
// All three rules ship default-off (config-gated via `--rule name:error`),
// matching no-redeclare's posture: they are opinionated and, without project
// environment configuration, prone to false positives — so they never fire on
// a default `kessel lint` run and cannot regress the positive corpus.
// ============================================================================

import "core:fmt"
import "core:mem"

// LSBindKind classifies a binding so the resolver can apply per-kind policy
// (e.g. no-unused-vars skips params / catch / import).
LSBindKind :: enum u8 {
	Var,
	Let,
	Const,
	Function,
	Class,
	Param,
	Catch,
	Import,
}

// LSBinding is one declared name in a scope. `referenced` is flipped by the
// resolver when any reference resolves to it.
LSBinding :: struct {
	name:       string,
	start, end: u32,
	kind:       LSBindKind,
	referenced: bool,
}

// LSScope is one lexical scope. `is_function` marks a var/function hoist
// target (program, function body, arrow body). `parent` indexes into
// LSState.scopes; the root scope has parent -1.
LSScope :: struct {
	parent:      int,
	is_function: bool,
	bindings:    [dynamic]LSBinding,
}

// LSRef is one identifier read/write occurrence, tagged with the scope it
// appears in so the resolver can walk the parent chain.
LSRef :: struct {
	name:       string,
	start, end: u32,
	scope:      int,
}

// LSState threads the collector's mutable state. Allocated in the temp
// allocator (scoped to the parse job); nothing is freed individually.
LSState :: struct {
	l:      ^Linter,
	lang:   Lang,
	cur:    int,
	scopes: [dynamic]LSScope,
	refs:   [dynamic]LSRef,
	alloc:  mem.Allocator,
}

// lint_scope_pass is the entry point: build the root scope, collect, resolve.
lint_scope_pass :: proc(l: ^Linter, ctx: ^LintContext, program: ^Program) {
	if program == nil { return }
	st := LSState{l = l, lang = ctx.lang, alloc = context.temp_allocator}
	st.scopes = make([dynamic]LSScope, 0, 16, st.alloc)
	st.refs = make([dynamic]LSRef, 0, 64, st.alloc)
	ls_open(&st, -1, true) // root (module / global) scope is a hoist target.
	for s in program.body { ls_stmt(&st, s) }
	ls_resolve(&st)
}

// ls_open pushes a new scope, makes it current, and returns its index. The
// caller saves the previous `cur` and restores it after walking the subtree.
ls_open :: proc(st: ^LSState, parent: int, is_function: bool) -> int {
	append(&st.scopes, LSScope{
		parent = parent,
		is_function = is_function,
		bindings = make([dynamic]LSBinding, 0, 8, st.alloc),
	})
	st.cur = len(st.scopes) - 1
	return st.cur
}

// ls_declare records a binding, hoisting var / function declarations to the
// nearest enclosing function scope (ECMA-262 var hoisting).
ls_declare :: proc(st: ^LSState, name: string, start, end: u32, kind: LSBindKind) {
	target := st.cur
	if kind == .Var || kind == .Function {
		for target >= 0 && !st.scopes[target].is_function {
			target = st.scopes[target].parent
		}
		if target < 0 { target = 0 }
	}
	append(&st.scopes[target].bindings, LSBinding{
		name = name, start = start, end = end, kind = kind,
	})
}

// ls_ref records an identifier reference in the current scope.
ls_ref :: proc(st: ^LSState, name: string, start, end: u32) {
	append(&st.refs, LSRef{name = name, start = start, end = end, scope = st.cur})
}

// ls_declare_pattern declares every binding target inside a Pattern, walking
// initializer / computed-key / default expressions as references.
ls_declare_pattern :: proc(st: ^LSState, pat: Pattern, kind: LSBindKind) {
	switch p in pat {
	case ^Identifier:
		if p != nil { ls_declare(st, p.name, u32(p.loc.start), u32(p.loc.end), kind) }
	case ^AssignmentPattern:
		if p != nil { ls_declare_pattern(st, p.left, kind); ls_expr(st, p.right) }
	case ^ObjectPattern:
		if p != nil {
			for prop in p.properties {
				if prop.computed {
					if key, have := prop.key.(ObjectPatternPropertyKey); have {
						if e, ok := key.(^Expression); ok { ls_expr(st, e) }
					}
				}
				ls_declare_pattern(st, prop.value, kind)
			}
		}
	case ^ArrayPattern:
		if p != nil {
			for el in p.elements {
				if inner, ok := el.(Pattern); ok { ls_declare_pattern(st, inner, kind) }
			}
		}
	case ^RestElement:
		if p != nil { ls_declare_pattern(st, p.argument, kind) }
	case ^MemberExpression:
		// Destructuring into a member target (`[a.b] = x`) is a reference to
		// the object, not a new binding.
		if p != nil { ls_expr(st, p.object) }
	}
}

// ls_bind_kind maps a VariableKind to the scope-pass binding kind.
ls_bind_kind :: proc(k: VariableKind) -> LSBindKind {
	#partial switch k {
	case .Var: return .Var
	case .Const, .Using, .AwaitUsing: return .Const
	}
	return .Let
}

// ============================================================================
// Phase 1 — collection. ls_stmt / ls_expr mirror lint.odin's walk but maintain
// the scope stack and record bindings + references instead of running rules.
// ============================================================================

ls_stmt :: proc(st: ^LSState, stmt: ^Statement) {
	if stmt == nil { return }
	#partial switch v in stmt^ {
	case ^ExpressionStatement:
		if v != nil { ls_expr(st, v.expression) }
	case ^BlockStatement:
		if v != nil { ls_block(st, v.body[:]) }
	case ^IfStatement:
		if v != nil {
			ls_expr(st, v.test)
			ls_stmt(st, v.consequent)
			if alt, ok := v.alternate.(^Statement); ok && alt != nil { ls_stmt(st, alt) }
		}
	case ^WhileStatement:
		if v != nil { ls_expr(st, v.test); ls_stmt(st, v.body) }
	case ^DoWhileStatement:
		if v != nil { ls_stmt(st, v.body); ls_expr(st, v.test) }
	case ^ForStatement:
		ls_for(st, v)
	case ^ForInStatement:
		ls_forin(st, v)
	case ^ForOfStatement:
		ls_forof(st, v)
	case ^SwitchStatement:
		ls_switch(st, v)
	case ^ReturnStatement:
		if v != nil {
			if e, ok := v.argument.(^Expression); ok && e != nil { ls_expr(st, e) }
		}
	case ^ThrowStatement:
		if v != nil { ls_expr(st, v.argument) }
	case ^TryStatement:
		ls_try(st, v)
	case ^WithStatement:
		if v != nil { ls_expr(st, v.object); ls_stmt(st, v.body) }
	case ^LabeledStatement:
		if v != nil { ls_stmt(st, v.body) }
	case ^VariableDeclaration:
		if v != nil { ls_var_decl(st, v) }
	case ^FunctionDeclaration:
		if v != nil {
			if bid, ok := v.id.(BindingIdentifier); ok {
				ls_declare(st, bid.name, u32(bid.loc.start), u32(bid.loc.end), .Function)
			}
			ls_function(st, &v.expr, false)
		}
	case ^ClassDeclaration:
		if v != nil {
			if bid, ok := v.id.(BindingIdentifier); ok {
				ls_declare(st, bid.name, u32(bid.loc.start), u32(bid.loc.end), .Class)
			}
			ls_class(st, &v.expr)
		}
	case ^ExportNamedDeclaration:
		if v != nil {
			if d, ok := v.declaration.(^Declaration); ok && d != nil { ls_decl(st, d) }
		}
	case ^ExportDefaultDeclaration:
		ls_export_default(st, v)
	case ^ImportDeclaration:
		ls_import(st, v)
	}
}

// ls_block opens a block scope, walks the statement list, then restores.
ls_block :: proc(st: ^LSState, body: []^Statement) {
	saved := st.cur
	ls_open(st, st.cur, false)
	for s in body { ls_stmt(st, s) }
	st.cur = saved
}

ls_for :: proc(st: ^LSState, v: ^ForStatement) {
	if v == nil { return }
	saved := st.cur
	ls_open(st, st.cur, false)
	if d, ok := v.init_decl.(^VariableDeclaration); ok && d != nil { ls_var_decl(st, d) }
	if e, ok := v.init_expr.(^Expression); ok && e != nil { ls_expr(st, e) }
	if t, ok := v.test.(^Expression); ok && t != nil { ls_expr(st, t) }
	if u, ok := v.update.(^Expression); ok && u != nil { ls_expr(st, u) }
	ls_stmt(st, v.body)
	st.cur = saved
}

ls_forin :: proc(st: ^LSState, v: ^ForInStatement) {
	if v == nil { return }
	saved := st.cur
	ls_open(st, st.cur, false)
	if d, ok := v.left_decl.(^VariableDeclaration); ok && d != nil { ls_var_decl(st, d) }
	if e, ok := v.left_expr.(^Expression); ok && e != nil { ls_expr(st, e) }
	ls_expr(st, v.right)
	ls_stmt(st, v.body)
	st.cur = saved
}

ls_forof :: proc(st: ^LSState, v: ^ForOfStatement) {
	if v == nil { return }
	saved := st.cur
	ls_open(st, st.cur, false)
	if d, ok := v.left_decl.(^VariableDeclaration); ok && d != nil { ls_var_decl(st, d) }
	if e, ok := v.left_expr.(^Expression); ok && e != nil { ls_expr(st, e) }
	ls_expr(st, v.right)
	ls_stmt(st, v.body)
	st.cur = saved
}

ls_switch :: proc(st: ^LSState, v: ^SwitchStatement) {
	if v == nil { return }
	ls_expr(st, v.discriminant)
	saved := st.cur
	ls_open(st, st.cur, false)
	for sc in v.cases {
		if t, ok := sc.test.(^Expression); ok && t != nil { ls_expr(st, t) }
		for s in sc.consequent { ls_stmt(st, s) }
	}
	st.cur = saved
}

ls_try :: proc(st: ^LSState, v: ^TryStatement) {
	if v == nil { return }
	ls_block(st, v.block.body[:])
	if h, ok := v.handler.(CatchClause); ok {
		saved := st.cur
		ls_open(st, st.cur, false)
		if p, have := h.param.(Pattern); have { ls_declare_pattern(st, p, .Catch) }
		for s in h.body.body { ls_stmt(st, s) }
		st.cur = saved
	}
	if f, ok := v.finalizer.(BlockStatement); ok { ls_block(st, f.body[:]) }
}

// ls_var_decl declares each declarator's binding(s) and walks initializers.
ls_var_decl :: proc(st: ^LSState, d: ^VariableDeclaration) {
	if d == nil { return }
	kind := ls_bind_kind(d.kind)
	for decl in d.declarations {
		ls_declare_pattern(st, decl.id, kind)
		if init, ok := decl.init.(^Expression); ok && init != nil { ls_expr(st, init) }
	}
}

// ls_decl handles a Declaration appearing under `export <decl>`.
ls_decl :: proc(st: ^LSState, d: ^Declaration) {
	if d == nil { return }
	#partial switch inner in d^ {
	case ^FunctionDeclaration:
		if inner != nil {
			if bid, ok := inner.id.(BindingIdentifier); ok {
				ls_declare(st, bid.name, u32(bid.loc.start), u32(bid.loc.end), .Function)
			}
			ls_function(st, &inner.expr, false)
		}
	case ^ClassDeclaration:
		if inner != nil {
			if bid, ok := inner.id.(BindingIdentifier); ok {
				ls_declare(st, bid.name, u32(bid.loc.start), u32(bid.loc.end), .Class)
			}
			ls_class(st, &inner.expr)
		}
	case ^VariableDeclaration:
		if inner != nil { ls_var_decl(st, inner) }
	}
}

ls_export_default :: proc(st: ^LSState, v: ^ExportDefaultDeclaration) {
	if v == nil || v.declaration == nil { return }
	#partial switch inner in v.declaration^ {
	case ^Expression:  if inner != nil { ls_expr(st, inner) }
	case ^Declaration: if inner != nil { ls_decl(st, inner) }
	}
}

ls_import :: proc(st: ^LSState, v: ^ImportDeclaration) {
	if v == nil { return }
	for spec in v.specifiers {
		if spec == nil { continue }
		switch s in spec^ {
		case ImportSpecifier:
			ls_declare(st, s.local.name, u32(s.local.loc.start), u32(s.local.loc.end), .Import)
		case ImportDefaultSpecifier:
			ls_declare(st, s.local.name, u32(s.local.loc.start), u32(s.local.loc.end), .Import)
		case ImportNamespaceSpecifier:
			ls_declare(st, s.local.name, u32(s.local.loc.start), u32(s.local.loc.end), .Import)
		}
	}
}

// ls_function opens a function scope, declares params, and walks the body.
// `self_name` declares a named function expression's own name inside its scope
// (visible only there); function declarations pass false (the outer scope owns
// the name).
ls_function :: proc(st: ^LSState, fn: ^FunctionExpression, self_name: bool) {
	if fn == nil { return }
	saved := st.cur
	ls_open(st, st.cur, true)
	if self_name {
		if bid, ok := fn.id.(BindingIdentifier); ok {
			ls_declare(st, bid.name, u32(bid.loc.start), u32(bid.loc.end), .Function)
		}
	}
	for pr in fn.params {
		ls_declare_pattern(st, pr.pattern, .Param)
		if d, ok := pr.default_val.(^Expression); ok && d != nil { ls_expr(st, d) }
	}
	if !fn.no_body {
		for s in fn.body.body { ls_stmt(st, s) }
	}
	st.cur = saved
}

ls_arrow :: proc(st: ^LSState, fn: ^ArrowFunctionExpression) {
	if fn == nil { return }
	saved := st.cur
	ls_open(st, st.cur, true)
	for pr in fn.params {
		ls_declare_pattern(st, pr.pattern, .Param)
		if d, ok := pr.default_val.(^Expression); ok && d != nil { ls_expr(st, d) }
	}
	switch b in fn.body {
	case ^Expression:     if b != nil { ls_expr(st, b) }
	case ^BlockStatement: if b != nil { for s in b.body { ls_stmt(st, s) } }
	}
	st.cur = saved
}

// ls_class walks a class's heritage and member values. Method bodies are
// FunctionExpressions reached via ls_expr, which opens their own scopes.
ls_class :: proc(st: ^LSState, cls: ^ClassExpression) {
	if cls == nil { return }
	if sc, ok := cls.super_class.(^Expression); ok && sc != nil { ls_expr(st, sc) }
	for elem in cls.body.body {
		if elem.computed && elem.key != nil { ls_expr(st, elem.key) }
		if val, ok := elem.value.(^Expression); ok && val != nil { ls_expr(st, val) }
	}
}

// ls_expr records identifier references and descends into child expressions.
// `#partial`: only forms that carry references or open scopes are handled;
// literals / this / super / private names / meta / JSX text are leaves.
ls_expr :: proc(st: ^LSState, expr: ^Expression) {
	if expr == nil { return }
	#partial switch e in expr^ {
	case ^Identifier:
		if e != nil { ls_ref(st, e.name, u32(e.loc.start), u32(e.loc.end)) }
	case ^MemberExpression:
		if e != nil {
			ls_expr(st, e.object)
			if e.computed && e.property != nil { ls_expr(st, e.property) }
		}
	case ^CallExpression:
		if e != nil { ls_expr(st, e.callee); for a in e.arguments { ls_expr(st, a) } }
	case ^NewExpression:
		if e != nil { ls_expr(st, e.callee); for a in e.arguments { ls_expr(st, a) } }
	case ^ConditionalExpression:
		if e != nil { ls_expr(st, e.test); ls_expr(st, e.consequent); ls_expr(st, e.alternate) }
	case ^BinaryExpression:
		if e != nil { ls_expr(st, e.left); ls_expr(st, e.right) }
	case ^LogicalExpression:
		if e != nil { ls_expr(st, e.left); ls_expr(st, e.right) }
	case ^AssignmentExpression:
		if e != nil { ls_expr(st, e.left); ls_expr(st, e.right) }
	case ^SequenceExpression:
		if e != nil { for s in e.expressions { ls_expr(st, s) } }
	case ^ArrayExpression:
		if e != nil {
			for el in e.elements {
				if inner, ok := el.(^Expression); ok && inner != nil { ls_expr(st, inner) }
			}
		}
	case ^ObjectExpression:
		if e != nil {
			for prop in e.properties {
				if prop.computed && prop.key != nil { ls_expr(st, prop.key) }
				if prop.value != nil { ls_expr(st, prop.value) }
			}
		}
	case ^SpreadElement:
		if e != nil { ls_expr(st, e.argument) }
	case ^UnaryExpression:
		if e != nil { ls_expr(st, e.argument) }
	case ^UpdateExpression:
		if e != nil { ls_expr(st, e.argument) }
	case ^ParenthesizedExpression:
		if e != nil { ls_expr(st, e.expression) }
	case ^AwaitExpression:
		if e != nil { ls_expr(st, e.argument) }
	case ^YieldExpression:
		if e != nil {
			if a, ok := e.argument.(^Expression); ok && a != nil { ls_expr(st, a) }
		}
	case ^ChainExpression:
		if e != nil { ls_expr(st, e.expression) }
	case ^TaggedTemplateExpression:
		if e != nil { ls_expr(st, e.tag); ls_expr(st, e.quasi) }
	case ^TemplateLiteral:
		if e != nil { for s in e.expressions { ls_expr(st, s) } }
	case ^ImportExpression:
		if e != nil { ls_expr(st, e.source); ls_expr(st, e.options) }
	case ^FunctionExpression:
		if e != nil { ls_function(st, e, true) }
	case ^ArrowFunctionExpression:
		ls_arrow(st, e)
	case ^ClassExpression:
		if e != nil { ls_class(st, e) }
	case ^TSAsExpression:
		if e != nil { ls_expr(st, e.expression) }
	case ^TSSatisfiesExpression:
		if e != nil { ls_expr(st, e.expression) }
	case ^TSNonNullExpression:
		if e != nil { ls_expr(st, e.expression) }
	case ^TSTypeAssertion:
		if e != nil { ls_expr(st, e.expression) }
	case ^TSInstantiationExpression:
		if e != nil { ls_expr(st, e.expression) }
	case ^JSXElement:
		ls_jsx_element(st, e)
	case ^JSXFragment:
		if e != nil { for child in e.children { ls_jsx_child(st, child) } }
	}
}

ls_jsx_element :: proc(st: ^LSState, e: ^JSXElement) {
	if e == nil { return }
	if e.opening_element != nil {
		for attr in e.opening_element.attributes { ls_jsx_attr(st, attr) }
	}
	for child in e.children { ls_jsx_child(st, child) }
}

ls_jsx_child :: proc(st: ^LSState, child: JSXChild) {
	#partial switch v in child {
	case ^JSXElement:
		ls_jsx_element(st, v)
	case ^JSXFragment:
		if v != nil { for ch in v.children { ls_jsx_child(st, ch) } }
	case ^JSXExpressionContainer:
		if v != nil && v.expression != nil { ls_expr(st, v.expression) }
	case ^JSXSpreadChild:
		if v != nil { ls_expr(st, v.expression) }
	}
}

ls_jsx_attr :: proc(st: ^LSState, attr: JSXAttributeItem) {
	#partial switch a in attr {
	case JSXAttribute:
		if val, ok := a.value.(^Expression); ok && val != nil { ls_expr(st, val) }
	case ^JSXSpreadAttribute:
		if a != nil && a.argument != nil { ls_expr(st, a.argument) }
	}
}

// ============================================================================
// Phase 2 — resolution. Diff the collected bindings and references.
// ============================================================================

// ls_lookup returns the nearest binding for `name` visible from `scope`,
// walking the parent chain. Returns (scope_idx, binding_idx, found).
ls_lookup :: proc(st: ^LSState, scope: int, name: string) -> (int, int, bool) {
	s := scope
	for s >= 0 {
		for i in 0 ..< len(st.scopes[s].bindings) {
			if st.scopes[s].bindings[i].name == name { return s, i, true }
		}
		s = st.scopes[s].parent
	}
	return -1, -1, false
}

// ls_resolve marks referenced bindings, then dispatches the enabled rules.
// The mark loop always runs (it is cheap and no-unused-vars needs it).
ls_resolve :: proc(st: ^LSState) {
	undef_on := lint_rule_enabled(st.l, .L2006_NoUndef)
	// TypeScript ambient declarations / global augmentation make undefined-
	// reference detection unsound without a type checker, so no-undef is
	// JS/JSX-only.
	skip_undef := st.lang == .TS || st.lang == .TSX
	for r in st.refs {
		s, i, found := ls_lookup(st, r.scope, r.name)
		if found {
			st.scopes[s].bindings[i].referenced = true
			continue
		}
		if undef_on && !skip_undef && !ls_is_global(r.name) {
			lint_report(st.l, r.start, r.end, .L2006_NoUndef,
				fmt.tprintf("'%s' is not defined", r.name))
		}
	}
	if lint_rule_enabled(st.l, .L2007_NoUnusedVars) { ls_report_unused(st) }
	if lint_rule_enabled(st.l, .L2008_NoShadow)     { ls_report_shadow(st) }
}

// ls_report_unused flags never-referenced local bindings. The root scope
// (index 0) is skipped: top-level names may be the module's external API.
// Params / catch bindings / imports are skipped to avoid noisy false
// positives (an unused param is often required by a callback signature).
ls_report_unused :: proc(st: ^LSState) {
	for si in 1 ..< len(st.scopes) {
		for b in st.scopes[si].bindings {
			if b.referenced { continue }
			skip := false
			#partial switch b.kind {
			case .Param, .Catch, .Import: skip = true
			}
			if skip { continue }
			lint_report(st.l, b.start, b.end, .L2007_NoUnusedVars,
				fmt.tprintf("'%s' is declared but never used", b.name))
		}
	}
}

// ls_report_shadow flags a binding whose name is also declared in an enclosing
// scope (checking only ancestors — same-scope duplicates are no-redeclare's job).
ls_report_shadow :: proc(st: ^LSState) {
	for si in 1 ..< len(st.scopes) {
		parent := st.scopes[si].parent
		for b in st.scopes[si].bindings {
			if _, _, found := ls_lookup(st, parent, b.name); found {
				lint_report(st.l, b.start, b.end, .L2008_NoShadow,
					fmt.tprintf("'%s' shadows a variable in an outer scope", b.name))
			}
		}
	}
}

// ls_is_global reports whether `name` is a standard global / host builtin, so
// no-undef does not flag it. Conservative superset of the ECMAScript intrinsics
// plus common Node and DOM globals.
ls_is_global :: proc(name: string) -> bool {
	switch name {
	case "undefined", "NaN", "Infinity", "globalThis", "arguments", "eval":
		return true
	case "Object", "Function", "Array", "String", "Number", "Boolean", "Symbol",
	     "BigInt", "Math", "JSON", "Date", "RegExp", "Map", "Set", "WeakMap",
	     "WeakSet", "WeakRef", "Proxy", "Reflect", "Promise", "ArrayBuffer",
	     "SharedArrayBuffer", "DataView", "Atomics", "Intl":
		return true
	case "Error", "TypeError", "RangeError", "SyntaxError", "ReferenceError",
	     "EvalError", "URIError", "AggregateError":
		return true
	case "Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array",
	     "Uint16Array", "Int32Array", "Uint32Array", "Float32Array",
	     "Float64Array", "BigInt64Array", "BigUint64Array":
		return true
	case "parseInt", "parseFloat", "isNaN", "isFinite", "encodeURIComponent",
	     "decodeURIComponent", "encodeURI", "decodeURI", "structuredClone",
	     "queueMicrotask":
		return true
	case "console", "setTimeout", "setInterval", "clearTimeout", "clearInterval",
	     "setImmediate", "fetch", "window", "document", "navigator",
	     "location", "history", "localStorage", "sessionStorage", "alert",
	     "URL", "URLSearchParams", "Headers", "Request", "Response", "Blob",
	     "FormData", "AbortController", "Event", "CustomEvent", "performance":
		return true
	case "require", "module", "exports", "process", "global", "Buffer",
	     "__dirname", "__filename":
		return true
	}
	return false
}
