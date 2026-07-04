package kessel

// ============================================================================
// Linter — Pass 4 of the kessel pipeline (opt-in via `kessel lint`).
//
// Walks a finished AST and reports lint diagnostics. Like the semantic
// checker (pass 3) it is a separate AST-walking pass and shares the parser's
// arena-only memory model: rule state allocates in the parse arena and nothing
// is freed.
//
// Design (see HANDOFF.md "Next Phase — Linter"):
//   • One walk. A single `#complete switch` visitor (lint_walk_stmt /
//     lint_walk_expr) dispatches every enabled rule per node — there is NOT
//     one full traversal per rule. Because the switches omit a `case:`
//     default, a newly-added AST variant fails the build.
//   • New code range. Lint diagnostics get their own `LintRule` namespace
//     (L1xxx style, L2xxx correctness, L3xxx TS-specific) kept out of the
//     parser/checker `K####` range. `lint_rule_info` mirrors `error_info`.
//   • Pure leaf rules. Each rule is a leaf `(l, ctx, node)` reporting via
//     `lint_report`; control flow (the walk) stays in the parent visitor.
//
// M1 (this slice): the visitor + rule engine skeleton. The traversal reaches
// every node and `lint_report` buffers diagnostics, but no rules are wired
// yet — `kessel lint` runs the empty pass and renders nothing. Rules land in
// M2.
// ============================================================================

import "core:fmt"
import "core:mem"
import "core:os"
import "core:encoding/json"

// LintRule is the stable, machine-readable identifier for a lint diagnostic.
// The numeric ranges mirror the planned rule families:
//   L1xxx (1000–1999): style
//   L2xxx (2000–2999): correctness
//   L3xxx (3000–3999): TypeScript-specific
//
// `None` (zero) is the sentinel for "no rule" (un-coded report).
LintRule :: enum u16 {
	None = 0,

	// L1xxx — style.
	L1001_NoEmpty        = 1001,
	L1002_NoSparseArrays = 1002,
	L1003_Eqeqeq         = 1003,

	// L2xxx — correctness.
	L2001_NoDebugger          = 2001,
	L2002_NoDupeKeys          = 2002,
	L2003_NoConstantCondition = 2003,
	L2004_NoDupeClassMembers  = 2004,
	L2005_NoRedeclare         = 2005,
	L2006_NoUndef             = 2006,
	L2007_NoUnusedVars        = 2007,
	L2008_NoShadow            = 2008,
}

// LintRuleInfo is the static record looked up by LintRule. Held in a
// `#partial switch` rather than a map to keep lookup branchless and avoid
// runtime initialisation. All strings are compile-time literals.
LintRuleInfo :: struct {
	name:             string,   // ESLint-style kebab-case rule name
	default_message:  string,   // canonical wording; call sites MAY override
	default_severity: Severity,
	default_enabled:  bool,     // whether the rule fires without explicit opt-in
}

// lint_rule_info returns the canonical record for a rule. Unknown rules
// return a zero `LintRuleInfo` (silent fallback — never crashes the linter).
// M1 ships the table scaffold; the rule bodies that consume these records
// land in M2.
lint_rule_info :: proc(rule: LintRule) -> LintRuleInfo {
	#partial switch rule {
	case .L1001_NoEmpty:
		return LintRuleInfo{
			name = "no-empty", default_message = "empty block statement",
			default_severity = .Warning, default_enabled = true,
		}
	case .L1002_NoSparseArrays:
		return LintRuleInfo{
			name = "no-sparse-arrays", default_message = "sparse array (unexpected array hole)",
			default_severity = .Warning, default_enabled = true,
		}
	case .L1003_Eqeqeq:
		return LintRuleInfo{
			name = "eqeqeq", default_message = "expected '===' and instead saw '=='",
			default_severity = .Warning, default_enabled = false,
		}
	case .L2001_NoDebugger:
		return LintRuleInfo{
			name = "no-debugger", default_message = "unexpected 'debugger' statement",
			default_severity = .Error, default_enabled = true,
		}
	case .L2002_NoDupeKeys:
		return LintRuleInfo{
			name = "no-dupe-keys", default_message = "duplicate key in object literal",
			default_severity = .Error, default_enabled = true,
		}
	case .L2003_NoConstantCondition:
		return LintRuleInfo{
			name = "no-constant-condition",
			default_message = "unexpected constant condition",
			default_severity = .Error, default_enabled = false,
		}
	case .L2004_NoDupeClassMembers:
		return LintRuleInfo{
			name = "no-dupe-class-members", default_message = "duplicate class member",
			default_severity = .Error, default_enabled = true,
		}
	case .L2005_NoRedeclare:
		return LintRuleInfo{
			name = "no-redeclare",
			default_message = "identifier is already declared in this scope",
			default_severity = .Error, default_enabled = false,
		}
	case .L2006_NoUndef:
		return LintRuleInfo{
			name = "no-undef",
			default_message = "reference to undefined variable",
			default_severity = .Error, default_enabled = false,
		}
	case .L2007_NoUnusedVars:
		return LintRuleInfo{
			name = "no-unused-vars",
			default_message = "variable is declared but never used",
			default_severity = .Warning, default_enabled = false,
		}
	case .L2008_NoShadow:
		return LintRuleInfo{
			name = "no-shadow",
			default_message = "variable shadows one in an outer scope",
			default_severity = .Warning, default_enabled = false,
		}
	}
	return LintRuleInfo{}
}

// lint_rule_code_string returns the stable "L####" identifier used in JSON
// output and the pretty renderer. Returns "" for `.None`.
lint_rule_code_string :: proc(rule: LintRule) -> string {
	if rule == .None { return "" }
	return fmt.tprintf("L%04d", u16(rule))
}

// LintContext — mutable walker state threaded through the traversal. M1 keeps
// it minimal; scope-aware rules (M3) add binding/usage tables here. Bundling
// the walk state in one struct mirrors CheckerContext so save/restore around
// function / class boundaries collapses to a single struct copy.
LintContext :: struct {
	lang: Lang,
}

// Linter owns the diagnostic buffer and the enable/severity configuration.
// Mirrors `Checker`: diagnostics are `ParseError` so they share the existing
// pretty renderer (`render_pretty_diagnostics`) and JSON shape.
Linter :: struct {
	diagnostics: [dynamic]ParseError,
	allocator:   mem.Allocator,
	source:      string,
	// enabled / severity override maps. Empty in M1 (no rule fires); the
	// config surface (M4) populates these. A rule consults `lint_rule_enabled`
	// before reporting.
	enabled:  map[LintRule]bool,
	severity: map[LintRule]Severity,
}

// init_linter constructs a Linter bound to the parse arena allocator.
init_linter :: proc(alloc: mem.Allocator) -> Linter {
	return Linter{
		diagnostics = make([dynamic]ParseError, 0, 8, alloc),
		enabled     = make(map[LintRule]bool, 0, alloc),
		severity    = make(map[LintRule]Severity, 0, alloc),
		allocator   = alloc,
	}
}

// lint_rule_enabled reports whether `rule` should fire. An explicit config
// override (M4) wins; otherwise the rule's `default_enabled` applies.
lint_rule_enabled :: proc(l: ^Linter, rule: LintRule) -> bool {
	if on, ok := l.enabled[rule]; ok { return on }
	return lint_rule_info(rule).default_enabled
}

// lint_report buffers a diagnostic. The severity comes from the per-run
// override map, falling back to the rule's default. A point span (start ==
// end) is used unless the caller supplies a real end offset.
lint_report :: proc(l: ^Linter, start, end: u32, rule: LintRule, message: string) {
	sev := lint_rule_info(rule).default_severity
	if s, ok := l.severity[rule]; ok { sev = s }
	bump_append(&l.diagnostics, ParseError{
		start     = start,
		end       = end if end > start else start,
		message   = message,
		severity  = sev,
		lint_code = rule,
	})
}

// ============================================================================
// Visitor — a single recursive traversal that reaches every node. Mirrors the
// dispatch shape of checker.odin's `ck_walk_*` family. The Statement and
// Expression switches are exhaustive (no `case:` default) so adding an AST
// variant fails the build until the visitor handles it.
//
// Recursion is bounded by AST depth (already bounded by the parser).
// ============================================================================

// lint_program is the entry point: walk every top-level statement.
lint_program :: proc(l: ^Linter, ctx: ^LintContext, program: ^Program) {
	if program == nil { return }
	lint_check_redeclare(l, ctx, program.body[:])
	for stmt in program.body {
		lint_walk_stmt(l, ctx, stmt)
	}
	// Scope-aware rules (M3) run as a separate two-phase pass — collect
	// declarations + references, then diff them — rather than fold their
	// bookkeeping into the AST-local walk above. This mirrors regex.odin's
	// justified multi-pass design: the scope chain has different granularity
	// than the per-node rule fan-out. The pass is skipped entirely unless a
	// scope rule is enabled, so default `kessel lint` runs pay nothing.
	if lint_rule_enabled(l, .L2006_NoUndef) ||
	   lint_rule_enabled(l, .L2007_NoUnusedVars) ||
	   lint_rule_enabled(l, .L2008_NoShadow) {
		lint_scope_pass(l, ctx, program)
	}
}

lint_walk_stmt :: proc(l: ^Linter, ctx: ^LintContext, stmt: ^Statement) {
	if stmt == nil { return }
	switch v in stmt^ {
	case ^ExpressionStatement:
		if v != nil { lint_walk_expr(l, ctx, v.expression) }
	case ^BlockStatement:
		if v != nil {
			lint_check_redeclare(l, ctx, v.body[:])
			// no-empty (L1001): a bare `{}` block with no statements. Function
			// bodies are a distinct AST type (FunctionBody), so only standalone /
			// nested / control-flow-body blocks reach here — matching ESLint's
			// no-empty (empty function bodies are a separate rule).
			if len(v.body) == 0 && lint_rule_enabled(l, .L1001_NoEmpty) {
				info := lint_rule_info(.L1001_NoEmpty)
				lint_report(l, u32(v.loc.start), u32(v.loc.end), .L1001_NoEmpty, info.default_message)
			}
			for s in v.body { lint_walk_stmt(l, ctx, s) }
		}
	case ^IfStatement:
		if v != nil {
			lint_check_constant_condition(l, v.test, u32(v.loc.start), u32(v.loc.end))
			lint_walk_expr(l, ctx, v.test)
			lint_walk_stmt(l, ctx, v.consequent)
			if alt, ok := v.alternate.(^Statement); ok && alt != nil {
				lint_walk_stmt(l, ctx, alt)
			}
		}
	case ^WhileStatement:
		if v != nil {
			lint_check_constant_condition(l, v.test, u32(v.loc.start), u32(v.loc.end))
			lint_walk_expr(l, ctx, v.test); lint_walk_stmt(l, ctx, v.body)
		}
	case ^DoWhileStatement:
		if v != nil {
			lint_check_constant_condition(l, v.test, u32(v.loc.start), u32(v.loc.end))
			lint_walk_stmt(l, ctx, v.body); lint_walk_expr(l, ctx, v.test)
		}
	case ^ForStatement:
		lint_walk_for(l, ctx, v)
	case ^ForInStatement:
		if v != nil {
			if e, ok := v.left_expr.(^Expression); ok && e != nil { lint_walk_expr(l, ctx, e) }
			if d, ok := v.left_decl.(^VariableDeclaration); ok && d != nil { lint_walk_var_decl(l, ctx, d) }
			lint_walk_expr(l, ctx, v.right)
			lint_walk_stmt(l, ctx, v.body)
		}
	case ^ForOfStatement:
		if v != nil {
			if e, ok := v.left_expr.(^Expression); ok && e != nil { lint_walk_expr(l, ctx, e) }
			if d, ok := v.left_decl.(^VariableDeclaration); ok && d != nil { lint_walk_var_decl(l, ctx, d) }
			lint_walk_expr(l, ctx, v.right)
			lint_walk_stmt(l, ctx, v.body)
		}
	case ^SwitchStatement:
		lint_walk_switch(l, ctx, v)
	case ^ReturnStatement:
		if v != nil {
			if e, ok := v.argument.(^Expression); ok && e != nil { lint_walk_expr(l, ctx, e) }
		}
	case ^ThrowStatement:
		if v != nil { lint_walk_expr(l, ctx, v.argument) }
	case ^TryStatement:
		lint_walk_try(l, ctx, v)
	case ^WithStatement:
		if v != nil { lint_walk_expr(l, ctx, v.object); lint_walk_stmt(l, ctx, v.body) }
	case ^LabeledStatement:
		if v != nil { lint_walk_stmt(l, ctx, v.body) }
	case ^VariableDeclaration:
		if v != nil { lint_walk_var_decl(l, ctx, v) }
	case ^FunctionDeclaration:
		if v != nil { lint_walk_function(l, ctx, &v.expr) }
	case ^ClassDeclaration:
		if v != nil { lint_walk_class(l, ctx, &v.expr) }
	case ^ExportNamedDeclaration:
		if v != nil {
			if d, ok := v.declaration.(^Declaration); ok && d != nil { lint_walk_decl(l, ctx, d) }
		}
	case ^ExportDefaultDeclaration:
		lint_walk_export_default(l, ctx, v)
	case ^DebuggerStatement:
		// no-debugger (L2001): a leaf rule — the visitor (parent) owns the walk
		// and enable gate; the rule only decides whether to report.
		if v != nil && lint_rule_enabled(l, .L2001_NoDebugger) {
			info := lint_rule_info(.L2001_NoDebugger)
			lint_report(l, u32(v.loc.start), u32(v.loc.end), .L2001_NoDebugger, info.default_message)
		}
	case ^EmptyStatement, ^BreakStatement, ^ContinueStatement,
	     ^ImportDeclaration, ^ExportAllDeclaration, ^TSInterfaceDeclaration,
	     ^TSTypeAliasDeclaration, ^TSEnumDeclaration, ^TSModuleDeclaration,
	     ^TSImportEqualsDeclaration, ^TSExportAssignment, ^TSNamespaceExportDeclaration:
		// Leaf for traversal purposes: no JS statement/expression children the
		// current rule set inspects. TS type internals and namespace bodies are
		// not walked in M1 — M3 deepens this if a scope-aware rule needs it.
	}
}

lint_walk_for :: proc(l: ^Linter, ctx: ^LintContext, v: ^ForStatement) {
	if v == nil { return }
	if e, ok := v.init_expr.(^Expression); ok && e != nil { lint_walk_expr(l, ctx, e) }
	if d, ok := v.init_decl.(^VariableDeclaration); ok && d != nil { lint_walk_var_decl(l, ctx, d) }
	if t, ok := v.test.(^Expression); ok && t != nil { lint_walk_expr(l, ctx, t) }
	if u, ok := v.update.(^Expression); ok && u != nil { lint_walk_expr(l, ctx, u) }
	lint_walk_stmt(l, ctx, v.body)
}

lint_walk_switch :: proc(l: ^Linter, ctx: ^LintContext, v: ^SwitchStatement) {
	if v == nil { return }
	lint_walk_expr(l, ctx, v.discriminant)
	for sc in v.cases {
		if t, ok := sc.test.(^Expression); ok && t != nil { lint_walk_expr(l, ctx, t) }
		for s in sc.consequent { lint_walk_stmt(l, ctx, s) }
	}
}

lint_walk_try :: proc(l: ^Linter, ctx: ^LintContext, v: ^TryStatement) {
	if v == nil { return }
	for s in v.block.body { lint_walk_stmt(l, ctx, s) }
	if h, ok := v.handler.(CatchClause); ok {
		for s in h.body.body { lint_walk_stmt(l, ctx, s) }
	}
	if f, ok := v.finalizer.(BlockStatement); ok {
		for s in f.body { lint_walk_stmt(l, ctx, s) }
	}
}

lint_walk_var_decl :: proc(l: ^Linter, ctx: ^LintContext, d: ^VariableDeclaration) {
	if d == nil { return }
	for decl in d.declarations {
		lint_walk_pattern(l, ctx, decl.id)
		if init, ok := decl.init.(^Expression); ok && init != nil { lint_walk_expr(l, ctx, init) }
	}
}

lint_walk_decl :: proc(l: ^Linter, ctx: ^LintContext, d: ^Declaration) {
	if d == nil { return }
	#partial switch inner in d^ {
	case ^FunctionDeclaration: if inner != nil { lint_walk_function(l, ctx, &inner.expr) }
	case ^ClassDeclaration:    if inner != nil { lint_walk_class(l, ctx, &inner.expr) }
	case ^VariableDeclaration: if inner != nil { lint_walk_var_decl(l, ctx, inner) }
	}
}

lint_walk_export_default :: proc(l: ^Linter, ctx: ^LintContext, v: ^ExportDefaultDeclaration) {
	if v == nil || v.declaration == nil { return }
	#partial switch inner in v.declaration^ {
	case ^Expression:  if inner != nil { lint_walk_expr(l, ctx, inner) }
	case ^Declaration: if inner != nil { lint_walk_decl(l, ctx, inner) }
	}
}

lint_walk_pattern :: proc(l: ^Linter, ctx: ^LintContext, pat: Pattern) {
	if pat == nil { return }
	switch pp in pat {
	case ^Identifier, ^MemberExpression:
		// Leaf binding target (or destructuring member target).
	case ^AssignmentPattern:
		if pp != nil { lint_walk_pattern(l, ctx, pp.left); lint_walk_expr(l, ctx, pp.right) }
	case ^ObjectPattern:
		if pp != nil {
			for prop in pp.properties {
				if prop.computed {
					if key, have := prop.key.(ObjectPatternPropertyKey); have {
						if e, ok := key.(^Expression); ok && e != nil { lint_walk_expr(l, ctx, e) }
					}
				}
				lint_walk_pattern(l, ctx, prop.value)
			}
		}
	case ^ArrayPattern:
		if pp != nil {
			for elem in pp.elements {
				if inner, ok := elem.(Pattern); ok { lint_walk_pattern(l, ctx, inner) }
			}
		}
	case ^RestElement:
		if pp != nil { lint_walk_pattern(l, ctx, pp.argument) }
	}
}

lint_walk_function :: proc(l: ^Linter, ctx: ^LintContext, fn: ^FunctionExpression) {
	if fn == nil { return }
	for pr in fn.params {
		lint_walk_pattern(l, ctx, pr.pattern)
		if d, ok := pr.default_val.(^Expression); ok && d != nil { lint_walk_expr(l, ctx, d) }
	}
	if !fn.no_body {
		lint_check_redeclare(l, ctx, fn.body.body[:])
		for s in fn.body.body { lint_walk_stmt(l, ctx, s) }
	}
}

lint_walk_arrow :: proc(l: ^Linter, ctx: ^LintContext, fn: ^ArrowFunctionExpression) {
	if fn == nil { return }
	for pr in fn.params {
		lint_walk_pattern(l, ctx, pr.pattern)
		if d, ok := pr.default_val.(^Expression); ok && d != nil { lint_walk_expr(l, ctx, d) }
	}
	switch b in fn.body {
	case ^Expression:     if b != nil { lint_walk_expr(l, ctx, b) }
	case ^BlockStatement: if b != nil { for s in b.body { lint_walk_stmt(l, ctx, s) } }
	}
}

// lint_check_dupe_class_members (no-dupe-class-members, L2004): reports a
// class member name declared more than once with the same static-ness, EXCEPT
// a single getter + single setter pair (which is legal). Computed keys,
// private names, the constructor, and static blocks are skipped. Both methods
// and data fields (kind .Method, value function-or-not) count as "data" slots;
// only kind .Get / .Set form the accessor pair exemption.
//
// Per-name slot flags: bit 0 = getter seen, bit 1 = setter seen, bit 2 = data
// seen. A member is a duplicate if its slot collides with anything already
// recorded that is not its complementary accessor.
lint_check_dupe_class_members :: proc(l: ^Linter, cls: ^ClassExpression) {
	if cls == nil || !lint_rule_enabled(l, .L2004_NoDupeClassMembers) { return }
	seen := make(map[string]u8, 0, context.temp_allocator)
	for elem in cls.body.body {
		if elem.computed || elem.key == nil { continue }
		if elem.kind == .Constructor || elem.kind == .StaticBlock { continue }
		name: string
		have := false
		#partial switch k in elem.key^ {
		case ^Identifier:    if k != nil { name = k.name;  have = true }
		case ^StringLiteral: if k != nil { name = k.value; have = true }
		}
		if !have { continue }
		key := name
		if elem.static { key = lint_static_key(name) }
		bit: u8 = 4 // data (method or field)
		if elem.kind == .Get { bit = 1 } else if elem.kind == .Set { bit = 2 }
		prev := seen[key]
		// Collision = anything seen that is not the complementary accessor.
		//   getter (1) only coexists with a lone setter (2).
		//   setter (2) only coexists with a lone getter (1).
		//   data (4) coexists with nothing.
		collides := false
		switch bit {
		case 1: collides = prev != 0 && prev != 2
		case 2: collides = prev != 0 && prev != 1
		case:   collides = prev != 0
		}
		if collides {
			info := lint_rule_info(.L2004_NoDupeClassMembers)
			lint_report(l, u32(elem.loc.start), u32(elem.loc.end), .L2004_NoDupeClassMembers, info.default_message)
		}
		seen[key] = prev | bit
	}
}

// lint_static_key namespaces a static member name so a static and an instance
// member of the same name do not collide. The "static " prefix contains a
// space, which can never appear in an identifier or quoted-string key, so the
// namespaces cannot alias.
lint_static_key :: proc(name: string) -> string {
	return fmt.tprintf("static %s", name)
}

lint_walk_class :: proc(l: ^Linter, ctx: ^LintContext, cls: ^ClassExpression) {
	if cls == nil { return }
	lint_check_dupe_class_members(l, cls)
	if sc, ok := cls.super_class.(^Expression); ok && sc != nil { lint_walk_expr(l, ctx, sc) }
	for elem in cls.body.body {
		if elem.computed && elem.key != nil { lint_walk_expr(l, ctx, elem.key) }
		if val, ok := elem.value.(^Expression); ok && val != nil { lint_walk_expr(l, ctx, val) }
	}
}

// lint_check_dupe_keys (no-dupe-keys, L2002): reports a duplicate property
// name within a single object literal. Computed keys are skipped (their value
// is not statically known). A get/set accessor pair is legal, so accessor
// properties (kind Get/Set) are excluded from the duplicate set; only data and
// method properties (Init/Method) participate. Allocates its `seen` set in the
// temp allocator (scoped to the parse job).
lint_check_dupe_keys :: proc(l: ^Linter, e: ^ObjectExpression) {
	if e == nil || !lint_rule_enabled(l, .L2002_NoDupeKeys) { return }
	seen := make(map[string]bool, 0, context.temp_allocator)
	for prop in e.properties {
		if prop.computed || prop.key == nil { continue }
		if prop.kind == .Get || prop.kind == .Set { continue }
		name: string
		have := false
		#partial switch k in prop.key^ {
		case ^Identifier:    if k != nil { name = k.name;  have = true }
		case ^StringLiteral: if k != nil { name = k.value; have = true }
		}
		if !have { continue }
		if seen[name] {
			info := lint_rule_info(.L2002_NoDupeKeys)
			lint_report(l, u32(prop.loc.start), u32(prop.loc.end), .L2002_NoDupeKeys, info.default_message)
		} else {
			seen[name] = true
		}
	}
}

// lint_check_sparse_array (no-sparse-arrays, L1002): reports an array literal
// that contains a hole (elision), e.g. `[1, , 3]` or `[, ]`. A trailing comma
// (`[1, 2,]`) does NOT create a hole and is not reported. Holes appear as an
// empty `Maybe(^Expression)` element. One diagnostic per array.
lint_check_sparse_array :: proc(l: ^Linter, e: ^ArrayExpression) {
	if e == nil || !lint_rule_enabled(l, .L1002_NoSparseArrays) { return }
	for el in e.elements {
		if _, ok := el.(^Expression); !ok {
			info := lint_rule_info(.L1002_NoSparseArrays)
			lint_report(l, u32(e.loc.start), u32(e.loc.end), .L1002_NoSparseArrays, info.default_message)
			return
		}
	}
}

// lint_redeclare_mark reports a duplicate declaration the second time a name is
// seen in the same scope list; otherwise records it.
lint_redeclare_mark :: proc(l: ^Linter, seen: ^map[string]bool, name: string, start, end: u32) {
	if seen[name] {
		info := lint_rule_info(.L2005_NoRedeclare)
		lint_report(l, start, end, .L2005_NoRedeclare, info.default_message)
	} else {
		seen[name] = true
	}
}

// lint_check_redeclare (no-redeclare, L2005): flags a name declared more than
// once in the SAME scope statement list — e.g. `var x; var x;` or
// `function x(){} var x;`. Only simple `Identifier` bindings are collected
// (destructuring is skipped to avoid false positives). Skipped entirely in
// TS/TSX where declaration merging makes same-name declarations legal.
// Config-gated (default-off): enable via `--rule no-redeclare:error`.
lint_check_redeclare :: proc(l: ^Linter, ctx: ^LintContext, body: []^Statement) {
	if !lint_rule_enabled(l, .L2005_NoRedeclare) { return }
	if ctx.lang == .TS || ctx.lang == .TSX { return }
	seen := make(map[string]bool, 0, context.temp_allocator)
	for s in body {
		if s == nil { continue }
		#partial switch v in s^ {
		case ^VariableDeclaration:
			if v != nil {
				for decl in v.declarations {
					if id, ok := decl.id.(^Identifier); ok && id != nil {
						lint_redeclare_mark(l, &seen, id.name, u32(id.loc.start), u32(id.loc.end))
					}
				}
			}
		case ^FunctionDeclaration:
			if v != nil {
				if id, ok := v.expr.id.(BindingIdentifier); ok {
					lint_redeclare_mark(l, &seen, id.name, u32(id.loc.start), u32(id.loc.end))
				}
			}
		case ^ClassDeclaration:
			if v != nil {
				if id, ok := v.expr.id.(BindingIdentifier); ok {
					lint_redeclare_mark(l, &seen, id.name, u32(id.loc.start), u32(id.loc.end))
				}
			}
		}
	}
}

// lint_check_eqeqeq (eqeqeq, L1003): flags loose equality (`==` / `!=`) and
// recommends the strict form. Config-gated (default-off); enable via
// `--rule eqeqeq:error`.
lint_check_eqeqeq :: proc(l: ^Linter, e: ^BinaryExpression) {
	if e == nil || !lint_rule_enabled(l, .L1003_Eqeqeq) { return }
	msg: string
	have := false
	#partial switch e.operator {
	case .Eq:    msg = "expected '===' and instead saw '=='"; have = true
	case .NotEq: msg = "expected '!==' and instead saw '!='"; have = true
	}
	if !have { return }
	lint_report(l, u32(e.loc.start), u32(e.loc.end), .L1003_Eqeqeq, msg)
}

// lint_is_constant_test reports whether an expression in a condition position
// is a compile-time constant literal (e.g. `if (true)`, `while (1)`). The
// minimal set covers the literal node kinds; compound constant folding is out
// of scope.
lint_is_constant_test :: proc(expr: ^Expression) -> bool {
	if expr == nil { return false }
	#partial switch _ in expr^ {
	case ^BooleanLiteral, ^NumericLiteral, ^StringLiteral, ^NullLiteral,
	     ^BigIntLiteral, ^RegExpLiteral:
		return true
	}
	return false
}

// lint_check_constant_condition (no-constant-condition, L2003): flags a loop /
// conditional whose test is a constant literal. Reports at the enclosing
// statement/expression span. Config-gated (default-off) — `while (true)` is a
// common intentional idiom, so the rule ships opt-in via `--rule`.
lint_check_constant_condition :: proc(l: ^Linter, test: ^Expression, start, end: u32) {
	if test == nil || !lint_rule_enabled(l, .L2003_NoConstantCondition) { return }
	if lint_is_constant_test(test) {
		info := lint_rule_info(.L2003_NoConstantCondition)
		lint_report(l, start, end, .L2003_NoConstantCondition, info.default_message)
	}
}

lint_walk_expr :: proc(l: ^Linter, ctx: ^LintContext, expr: ^Expression) {
	if expr == nil { return }
	switch e in expr^ {
	case ^MemberExpression:
		if e != nil {
			lint_walk_expr(l, ctx, e.object)
			if e.computed && e.property != nil { lint_walk_expr(l, ctx, e.property) }
		}
	case ^CallExpression:
		if e != nil { lint_walk_expr(l, ctx, e.callee); for a in e.arguments { lint_walk_expr(l, ctx, a) } }
	case ^NewExpression:
		if e != nil { lint_walk_expr(l, ctx, e.callee); for a in e.arguments { lint_walk_expr(l, ctx, a) } }
	case ^ConditionalExpression:
		if e != nil {
			lint_check_constant_condition(l, e.test, u32(e.loc.start), u32(e.loc.end))
			lint_walk_expr(l, ctx, e.test)
			lint_walk_expr(l, ctx, e.consequent)
			lint_walk_expr(l, ctx, e.alternate)
		}
	case ^BinaryExpression:     if e != nil { lint_check_eqeqeq(l, e); lint_walk_expr(l, ctx, e.left); lint_walk_expr(l, ctx, e.right) }
	case ^LogicalExpression:    if e != nil { lint_walk_expr(l, ctx, e.left); lint_walk_expr(l, ctx, e.right) }
	case ^AssignmentExpression: if e != nil { lint_walk_expr(l, ctx, e.left); lint_walk_expr(l, ctx, e.right) }
	case ^SequenceExpression:   if e != nil { for s in e.expressions { lint_walk_expr(l, ctx, s) } }
	case ^ArrayExpression:
		if e != nil {
			lint_check_sparse_array(l, e)
			for el in e.elements {
				if inner, ok := el.(^Expression); ok && inner != nil { lint_walk_expr(l, ctx, inner) }
			}
		}
	case ^ObjectExpression:
		if e != nil {
			lint_check_dupe_keys(l, e)
			for prop in e.properties {
				if prop.computed && prop.key != nil { lint_walk_expr(l, ctx, prop.key) }
				if prop.value != nil { lint_walk_expr(l, ctx, prop.value) }
			}
		}
	case ^SpreadElement:           if e != nil { lint_walk_expr(l, ctx, e.argument) }
	case ^UnaryExpression:         if e != nil { lint_walk_expr(l, ctx, e.argument) }
	case ^UpdateExpression:        if e != nil { lint_walk_expr(l, ctx, e.argument) }
	case ^ParenthesizedExpression: if e != nil { lint_walk_expr(l, ctx, e.expression) }
	case ^AwaitExpression:         if e != nil { lint_walk_expr(l, ctx, e.argument) }
	case ^YieldExpression:
		if e != nil {
			if a, ok := e.argument.(^Expression); ok && a != nil { lint_walk_expr(l, ctx, a) }
		}
	case ^ChainExpression:           if e != nil { lint_walk_expr(l, ctx, e.expression) }
	case ^TaggedTemplateExpression:  if e != nil { lint_walk_expr(l, ctx, e.tag); lint_walk_expr(l, ctx, e.quasi) }
	case ^TemplateLiteral:           if e != nil { for s in e.expressions { lint_walk_expr(l, ctx, s) } }
	case ^ImportExpression:          if e != nil { lint_walk_expr(l, ctx, e.source); lint_walk_expr(l, ctx, e.options) }
	case ^FunctionExpression:        if e != nil { lint_walk_function(l, ctx, e) }
	case ^ArrowFunctionExpression:   lint_walk_arrow(l, ctx, e)
	case ^ClassExpression:           if e != nil { lint_walk_class(l, ctx, e) }
	case ^TSAsExpression:            if e != nil { lint_walk_expr(l, ctx, e.expression) }
	case ^TSSatisfiesExpression:     if e != nil { lint_walk_expr(l, ctx, e.expression) }
	case ^TSNonNullExpression:       if e != nil { lint_walk_expr(l, ctx, e.expression) }
	case ^TSTypeAssertion:           if e != nil { lint_walk_expr(l, ctx, e.expression) }
	case ^TSInstantiationExpression: if e != nil { lint_walk_expr(l, ctx, e.expression) }
	case ^JSXElement:
		if e != nil {
			if e.opening_element != nil {
				for attr in e.opening_element.attributes { lint_walk_jsx_attr(l, ctx, attr) }
			}
			for child in e.children { lint_walk_jsx_child(l, ctx, child) }
		}
	case ^JSXFragment:
		if e != nil { for child in e.children { lint_walk_jsx_child(l, ctx, child) } }
	case ^NullLiteral, ^BooleanLiteral, ^NumericLiteral, ^StringLiteral, ^BigIntLiteral,
	     ^RegExpLiteral, ^Identifier, ^PrivateIdentifier, ^ThisExpression, ^Super,
	     ^MetaProperty, ^JSXText, ^JSXExpressionContainer, ^JSXEmptyExpression,
	     ^JSXSpreadChild:
		// Leaf / handled via JSX child walk. Literals, identifiers, this/super,
		// meta-property and JSXText carry no child Expression. JSXExpressionContainer
		// / JSXSpreadChild are reached as JSXChild via lint_walk_jsx_child when
		// they appear inside an element; as bare expressions they carry no
		// rule-relevant children for M1.
	}
}

lint_walk_jsx_child :: proc(l: ^Linter, ctx: ^LintContext, child: JSXChild) {
	#partial switch v in child {
	case ^JSXElement:
		if v != nil {
			if v.opening_element != nil {
				for attr in v.opening_element.attributes { lint_walk_jsx_attr(l, ctx, attr) }
			}
			for ch in v.children { lint_walk_jsx_child(l, ctx, ch) }
		}
	case ^JSXFragment:
		if v != nil { for ch in v.children { lint_walk_jsx_child(l, ctx, ch) } }
	case ^JSXExpressionContainer:
		if v != nil && v.expression != nil { lint_walk_expr(l, ctx, v.expression) }
	case ^JSXSpreadChild:
		if v != nil { lint_walk_expr(l, ctx, v.expression) }
	}
}

lint_walk_jsx_attr :: proc(l: ^Linter, ctx: ^LintContext, attr: JSXAttributeItem) {
	#partial switch a in attr {
	case JSXAttribute:
		if val, ok := a.value.(^Expression); ok && val != nil { lint_walk_expr(l, ctx, val) }
	case ^JSXSpreadAttribute:
		if a != nil && a.argument != nil { lint_walk_expr(l, ctx, a.argument) }
	}
}

// LintOverride is one `--rule name:level` / config entry resolved to a rule.
LintOverride :: struct {
	rule:         LintRule,
	enabled:      bool,
	severity:     Severity,
	set_severity: bool,
}

// lint_rule_by_name maps an ESLint-style kebab-case rule name to its LintRule.
// Returns (rule, true) on a hit, (.None, false) otherwise.
lint_rule_by_name :: proc(name: string) -> (LintRule, bool) {
	switch name {
	case "no-empty":              return .L1001_NoEmpty, true
	case "no-sparse-arrays":      return .L1002_NoSparseArrays, true
	case "eqeqeq":               return .L1003_Eqeqeq, true
	case "no-debugger":           return .L2001_NoDebugger, true
	case "no-dupe-keys":          return .L2002_NoDupeKeys, true
	case "no-constant-condition": return .L2003_NoConstantCondition, true
	case "no-dupe-class-members": return .L2004_NoDupeClassMembers, true
	case "no-redeclare":          return .L2005_NoRedeclare, true
	case "no-undef":              return .L2006_NoUndef, true
	case "no-unused-vars":        return .L2007_NoUnusedVars, true
	case "no-shadow":             return .L2008_NoShadow, true
	}
	return .None, false
}

// lint_override_from_level resolves a level word (off|warn|error) for a rule.
lint_override_from_level :: proc(rule: LintRule, level: string) -> (LintOverride, bool) {
	switch level {
	case "off":   return LintOverride{rule = rule, enabled = false}, true
	case "warn":  return LintOverride{rule = rule, enabled = true, severity = .Warning, set_severity = true}, true
	case "error": return LintOverride{rule = rule, enabled = true, severity = .Error, set_severity = true}, true
	}
	return LintOverride{}, false
}

// lint_parse_rule_flag parses a `name:level` value (level ∈ off|warn|error)
// into a LintOverride. Returns ok=false on an unknown rule name or level.
lint_parse_rule_flag :: proc(value: string) -> (LintOverride, bool) {
	colon := -1
	for i in 0..<len(value) {
		if value[i] == ':' { colon = i; break }
	}
	if colon < 0 { return LintOverride{}, false }
	name  := value[:colon]
	level := value[colon + 1:]
	rule, have := lint_rule_by_name(name)
	if !have { return LintOverride{}, false }
	return lint_override_from_level(rule, level)
}

// lint_parse_rules_text parses a newline-separated list of `name:level` tokens
// (the wire format the FFI receives from the JS `opts.rules` object) into
// per-rule overrides, appending each valid entry to `out`. Blank tokens and
// unrecognised names/levels are skipped so callers stay forward-compatible
// with rule names this build does not know. The loop is bounded by the text
// length (TigerStyle: put a limit on everything).
lint_parse_rules_text :: proc(text: string, out: ^[dynamic]LintOverride) {
	start := 0
	for i := 0; i <= len(text); i += 1 {
		if i < len(text) && text[i] != '\n' { continue }
		token := text[start:i]
		start = i + 1
		if len(token) == 0 { continue }
		if ov, ok := lint_parse_rule_flag(token); ok { append(out, ov) }
	}
}

// lint_discover_config searches for a `kessel.lint.json` file starting at
// `start_dir` and walking up toward the filesystem root, returning the path of
// the first match (true) or "" (false) when none is found. This mirrors
// ESLint's upward config search so a bare `kessel lint <files>` picks up a
// project config without an explicit `--config`. The walk is capped at 64
// levels so a pathological path can never loop unbounded (TigerStyle).
lint_discover_config :: proc(start_dir: string) -> (string, bool) {
	dir := start_dir
	for _ in 0..<64 {
		candidate := fmt.tprintf("%s/kessel.lint.json", dir)
		if os.exists(candidate) { return candidate, true }
		parent := os.dir(dir)
		if parent == dir { break }
		dir = parent
	}
	return "", false
}

// lint_load_config reads a `kessel.lint.json` config file and appends the
// resolved per-rule overrides into `out`. Shape:
//   { "rules": { "no-debugger": "off", "eqeqeq": "error" } }
// Unknown rule names and non-string levels are skipped silently (forward-
// compatible). Returns false only when the file cannot be read or is not a
// valid JSON object. CLI `--rule` flags are applied AFTER these so the CLI
// wins.
lint_load_config :: proc(path: string, out: ^[dynamic]LintOverride) -> bool {
	data, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil { return false }
	v, err := json.parse(data, allocator = context.temp_allocator)
	if err != .None { return false }
	obj, is_obj := v.(json.Object)
	if !is_obj { return false }
	rules_v, has_rules := obj["rules"]
	if !has_rules { return true }
	rules, is_rules := rules_v.(json.Object)
	if !is_rules { return false }
	for name, lvl_v in rules {
		lvl, is_str := lvl_v.(json.String)
		if !is_str { continue }
		rule, have := lint_rule_by_name(name)
		if !have { continue }
		if ov, ok2 := lint_override_from_level(rule, string(lvl)); ok2 {
			append(out, ov)
		}
	}
	return true
}

// lint_run_for_job runs the lint pass over a parsed ParseJob, populating the
// returned Linter's diagnostics. `overrides` apply per-rule enable/severity
// config (from `--rule` flags or a config file) before the walk. The arena
// allocator is the job's parse arena (rule state is freed wholesale when the
// job closes). Returns the Linter by value so the caller can render
// `l.diagnostics`.
lint_run_for_job :: proc(job: ^ParseJob, overrides: []LintOverride = nil) -> Linter {
	l := init_linter(job.arena_alloc)
	for ov in overrides {
		l.enabled[ov.rule] = ov.enabled
		if ov.set_severity { l.severity[ov.rule] = ov.severity }
	}
	if job == nil || job.program == nil { return l }
	l.source = job.lexer.source
	ctx := LintContext{ lang = job.lang }
	lint_program(&l, &ctx, job.program)
	return l
}
