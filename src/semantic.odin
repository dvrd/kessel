package kessel

// ============================================================================
// Semantic model (Phase 6) — reusable symbol table, scope tree, and reference
// resolution. Every downstream tool (checker, linter, minifier, transformer)
// can query this model instead of re-deriving scope information ad hoc.
//
// The model is built in a single AST walk and produces three parallel arrays:
//   • symbols  — every declared binding (var/let/const/function/class/import/
//                 catch/param/type), with a stable SymbolId.
//   • scopes   — lexical scope tree with parent links and child lists.
//   • refs     — every identifier reference, tagged with read/write/type and
//                 resolved to a SymbolId (or unresolved = global).
//
// Memory: all arrays live in the parse arena (arena-only, no free).
// ============================================================================

import "core:mem"
import "core:fmt"

// SymbolId is a stable, dense index into the symbols array. Zero is reserved
// for "unresolved" (global or undeclared).
SymbolId :: distinct u32
SYMBOL_UNRESOLVED :: SymbolId(0)

// ScopeId is a dense index into the scopes array.
ScopeId :: distinct u32
SCOPE_ROOT :: ScopeId(0)

// SymbolKind classifies how a binding was introduced.
SymbolKind :: enum u8 {
	Var,
	Let,
	Const,
	Function,
	Class,
	Param,
	CatchParam,
	Import,
	TypeAlias,    // TS `type X = ...`
	Interface,    // TS `interface X { ... }`
	Enum,         // TS `enum X { ... }`
	Namespace,    // TS `namespace X { ... }`
	Using,        // ES2024 `using`
}

// SymbolFlags are orthogonal properties of a symbol.
SymbolFlags :: bit_set[SymbolFlag; u8]
SymbolFlag :: enum u8 {
	Exported,     // `export` or `export default`
	DefaultExport,
	Readonly,     // `const` or `readonly` modifier
	Ambient,      // `declare`
	TypeOnly,     // TS type-only import
}

// Symbol represents one declared binding.
Symbol :: struct {
	name:       string,
	kind:       SymbolKind,
	flags:      SymbolFlags,
	scope:      ScopeId,       // scope this symbol is declared in
	decl_start: u32,           // source offset of the declaration
	decl_end:   u32,
	ref_count:  u32,           // number of references resolved to this symbol
}

// ScopeKind classifies the scope for hoisting and lookup rules.
ScopeKind :: enum u8 {
	Module,       // top-level module/script
	Function,     // function body (var hoist target)
	Block,        // { } block, for-body, if-body
	Class,        // class body
	Catch,        // catch clause
	For,          // for/for-in/for-of initializer scope
	StaticBlock,  // class static { }
	With,         // with() body — poisons scope lookup
	Switch,       // switch body
	Namespace,    // TS namespace body
}

// Scope represents one lexical scope in the scope tree.
Scope :: struct {
	kind:       ScopeKind,
	parent:     ScopeId,       // parent scope (root has parent = SCOPE_ROOT)
	symbols:    [dynamic]SymbolId, // symbols declared directly in this scope
	children:   [dynamic]ScopeId,  // child scopes
	node_start: u32,           // source span of the scope-introducing node
	node_end:   u32,
	strict:     bool,          // whether this scope is in strict mode
}

// RefKind classifies how an identifier is used.
RefKind :: enum u8 {
	Read,         // `x` in an expression
	Write,        // `x = ...` or `x++`
	ReadWrite,    // `x += ...`
	Type,         // TS type position
}

// Ref represents one identifier reference occurrence.
Ref :: struct {
	name:       string,
	kind:       RefKind,
	scope:      ScopeId,       // scope the reference appears in
	resolved:   SymbolId,      // resolved symbol (SYMBOL_UNRESOLVED if global)
	start, end: u32,           // source span
}

// SemanticModel is the output of the semantic analysis pass.
SemanticModel :: struct {
	symbols: [dynamic]Symbol,
	scopes:  [dynamic]Scope,
	refs:    [dynamic]Ref,
	alloc:   mem.Allocator,
}

// semantic_build runs the semantic analysis pass over a parsed program.
// Returns a fully-resolved SemanticModel. All memory is allocated from the
// provided arena allocator.
semantic_build :: proc(program: ^Program, source: string, lang: Lang, alloc: mem.Allocator) -> SemanticModel {
	model := SemanticModel{
		symbols = make([dynamic]Symbol, 1, 64, alloc),  // index 0 = sentinel
		scopes  = make([dynamic]Scope, 0, 32, alloc),
		refs    = make([dynamic]Ref, 0, 128, alloc),
		alloc   = alloc,
	}
	// Sentinel symbol at index 0 (SYMBOL_UNRESOLVED).
	model.symbols[0] = Symbol{name = "<unresolved>"}

	if program == nil { return model }

	ctx := SemCtx{model = &model, lang = lang, source = source}
	// Open root scope.
	sem_open_scope(&ctx, .Module, 0, u32(len(source)), false)
	// Collect: walk AST, declare symbols and record refs.
	for stmt in program.body {
		sem_walk_stmt(&ctx, stmt)
	}
	// Resolve: match refs to symbols via scope chain walk.
	sem_resolve(&model)

	return model
}

// SemCtx is the mutable state threaded through the collection walk.
SemCtx :: struct {
	model:    ^SemanticModel,
	lang:     Lang,
	source:   string,
	cur_scope: ScopeId,
}

// sem_open_scope pushes a new scope and returns its id.
sem_open_scope :: proc(ctx: ^SemCtx, kind: ScopeKind, start, end: u32, strict: bool) -> ScopeId {
	id := ScopeId(len(ctx.model.scopes))
	parent := ctx.cur_scope if len(ctx.model.scopes) > 0 else SCOPE_ROOT
	append(&ctx.model.scopes, Scope{
		kind       = kind,
		parent     = parent,
		symbols    = make([dynamic]SymbolId, 0, 8, ctx.model.alloc),
		children   = make([dynamic]ScopeId, 0, 4, ctx.model.alloc),
		node_start = start,
		node_end   = end,
		strict     = strict,
	})
	// Register as child of parent.
	if len(ctx.model.scopes) > 1 {
		append(&ctx.model.scopes[parent].children, id)
	}
	ctx.cur_scope = id
	return id
}

// sem_close_scope restores the parent scope.
sem_close_scope :: proc(ctx: ^SemCtx) {
	ctx.cur_scope = ctx.model.scopes[ctx.cur_scope].parent
}

// sem_declare adds a symbol to the current scope (or hoists to function scope
// for var/function declarations).
sem_declare :: proc(ctx: ^SemCtx, name: string, kind: SymbolKind, flags: SymbolFlags, start, end: u32) -> SymbolId {
	target := ctx.cur_scope
	// Var and function declarations hoist to the nearest function/module scope.
	if kind == .Var || kind == .Function {
		for target != SCOPE_ROOT {
			sk := ctx.model.scopes[target].kind
			if sk == .Function || sk == .Module { break }
			target = ctx.model.scopes[target].parent
		}
	}
	id := SymbolId(len(ctx.model.symbols))
	append(&ctx.model.symbols, Symbol{
		name       = name,
		kind       = kind,
		flags      = flags,
		scope      = target,
		decl_start = start,
		decl_end   = end,
	})
	append(&ctx.model.scopes[target].symbols, id)
	return id
}

// sem_ref records an identifier reference in the current scope.
sem_ref :: proc(ctx: ^SemCtx, name: string, kind: RefKind, start, end: u32) {
	append(&ctx.model.refs, Ref{
		name     = name,
		kind     = kind,
		scope    = ctx.cur_scope,
		resolved = SYMBOL_UNRESOLVED,
		start    = start,
		end      = end,
	})
}

// sem_resolve walks every ref and resolves it by searching up the scope chain.
sem_resolve :: proc(model: ^SemanticModel) {
	for i in 0..<len(model.refs) {
		ref := &model.refs[i]
		scope := ref.scope
		found := false
		for !found {
			for sym_id in model.scopes[scope].symbols {
				if model.symbols[sym_id].name == ref.name {
					ref.resolved = sym_id
					model.symbols[sym_id].ref_count += 1
					found = true
					break
				}
			}
			if found { break }
			if scope == SCOPE_ROOT { break }
			scope = model.scopes[scope].parent
		}
	}
}

// ============================================================================
// Collection walk — mirrors lint_scope.odin's ls_stmt/ls_expr but builds the
// semantic model instead of lint-specific state.
// ============================================================================

sem_walk_stmt :: proc(ctx: ^SemCtx, stmt: ^Statement) {
	if stmt == nil { return }
	#partial switch v in stmt^ {
	case ^ExpressionStatement:
		if v != nil { sem_walk_expr(ctx, v.expression) }
	case ^BlockStatement:
		if v != nil {
			saved := ctx.cur_scope
			sem_open_scope(ctx, .Block, u32(v.loc.start), u32(v.loc.end), false)
			for s in v.body { sem_walk_stmt(ctx, s) }
			sem_close_scope(ctx)
		}
	case ^VariableDeclaration:
		if v != nil { sem_walk_var_decl(ctx, v) }
	case ^FunctionDeclaration:
		if v != nil {
			if bid, ok := v.id.(BindingIdentifier); ok {
				sem_declare(ctx, bid.name, .Function, {}, u32(bid.loc.start), u32(bid.loc.end))
			}
			sem_walk_function(ctx, &v.expr)
		}
	case ^ClassDeclaration:
		if v != nil {
			if bid, ok := v.id.(BindingIdentifier); ok {
				sem_declare(ctx, bid.name, .Class, {}, u32(bid.loc.start), u32(bid.loc.end))
			}
			sem_walk_class(ctx, &v.expr)
		}
	case ^IfStatement:
		if v != nil {
			sem_walk_expr(ctx, v.test)
			sem_walk_stmt(ctx, v.consequent)
			if alt, ok := v.alternate.(^Statement); ok { sem_walk_stmt(ctx, alt) }
		}
	case ^WhileStatement:
		if v != nil { sem_walk_expr(ctx, v.test); sem_walk_stmt(ctx, v.body) }
	case ^DoWhileStatement:
		if v != nil { sem_walk_stmt(ctx, v.body); sem_walk_expr(ctx, v.test) }
	case ^ForStatement:
		if v != nil {
			saved := ctx.cur_scope
			sem_open_scope(ctx, .For, u32(v.loc.start), u32(v.loc.end), false)
			if e, ok := v.init_expr.(^Expression); ok { sem_walk_expr(ctx, e) }
			if d, ok := v.init_decl.(^VariableDeclaration); ok { sem_walk_var_decl(ctx, d) }
			if t, ok := v.test.(^Expression); ok { sem_walk_expr(ctx, t) }
			if u, ok := v.update.(^Expression); ok { sem_walk_expr(ctx, u) }
			sem_walk_stmt(ctx, v.body)
			sem_close_scope(ctx)
		}
	case ^ForInStatement:
		if v != nil {
			saved := ctx.cur_scope
			sem_open_scope(ctx, .For, u32(v.loc.start), u32(v.loc.end), false)
			if e, ok := v.left_expr.(^Expression); ok { sem_walk_expr(ctx, e) }
			if d, ok := v.left_decl.(^VariableDeclaration); ok { sem_walk_var_decl(ctx, d) }
			sem_walk_expr(ctx, v.right)
			sem_walk_stmt(ctx, v.body)
			sem_close_scope(ctx)
		}
	case ^ForOfStatement:
		if v != nil {
			saved := ctx.cur_scope
			sem_open_scope(ctx, .For, u32(v.loc.start), u32(v.loc.end), false)
			if e, ok := v.left_expr.(^Expression); ok { sem_walk_expr(ctx, e) }
			if d, ok := v.left_decl.(^VariableDeclaration); ok { sem_walk_var_decl(ctx, d) }
			sem_walk_expr(ctx, v.right)
			sem_walk_stmt(ctx, v.body)
			sem_close_scope(ctx)
		}
	case ^SwitchStatement:
		if v != nil {
			sem_walk_expr(ctx, v.discriminant)
			saved := ctx.cur_scope
			sem_open_scope(ctx, .Switch, u32(v.loc.start), u32(v.loc.end), false)
			for sc in v.cases {
				if t, ok := sc.test.(^Expression); ok { sem_walk_expr(ctx, t) }
				for s in sc.consequent { sem_walk_stmt(ctx, s) }
			}
			sem_close_scope(ctx)
		}
	case ^ReturnStatement:
		if v != nil { if e, ok := v.argument.(^Expression); ok { sem_walk_expr(ctx, e) } }
	case ^ThrowStatement:
		if v != nil { sem_walk_expr(ctx, v.argument) }
	case ^TryStatement:
		if v != nil {
			for s in v.block.body { sem_walk_stmt(ctx, s) }
			if h, ok := v.handler.(CatchClause); ok {
				saved := ctx.cur_scope
				sem_open_scope(ctx, .Catch, u32(h.loc.start), u32(h.loc.end), false)
				if pat, has := h.param.(Pattern); has {
					sem_declare_pattern(ctx, pat, .CatchParam, {})
				}
				for s in h.body.body { sem_walk_stmt(ctx, s) }
				sem_close_scope(ctx)
			}
			if f, ok := v.finalizer.(BlockStatement); ok {
				for s in f.body { sem_walk_stmt(ctx, s) }
			}
		}
	case ^WithStatement:
		if v != nil { sem_walk_expr(ctx, v.object); sem_walk_stmt(ctx, v.body) }
	case ^LabeledStatement:
		if v != nil { sem_walk_stmt(ctx, v.body) }
	case ^ExportNamedDeclaration:
		if v != nil {
			if d, ok := v.declaration.(^Declaration); ok { sem_walk_decl(ctx, d, true) }
		}
	case ^ExportDefaultDeclaration:
		if v != nil && v.declaration != nil {
			#partial switch inner in v.declaration^ {
			case ^Expression:  if inner != nil { sem_walk_expr(ctx, inner) }
			case ^Declaration: if inner != nil { sem_walk_decl(ctx, inner, true) }
			}
		}
	case ^ImportDeclaration:
		if v != nil {
			for spec_ptr in v.specifiers {
				if spec_ptr == nil { continue }
				switch sp in spec_ptr^ {
				case ImportDefaultSpecifier:
					sem_declare(ctx, sp.local.name, .Import, {.Readonly}, u32(sp.loc.start), u32(sp.loc.end))
				case ImportSpecifier:
					sem_declare(ctx, sp.local.name, .Import, {.Readonly}, u32(sp.loc.start), u32(sp.loc.end))
				case ImportNamespaceSpecifier:
					sem_declare(ctx, sp.local.name, .Import, {.Readonly}, u32(sp.loc.start), u32(sp.loc.end))
				}
			}
		}
	case ^TSInterfaceDeclaration:
		if v != nil { sem_declare(ctx, v.id.name, .Interface, {}, u32(v.loc.start), u32(v.loc.end)) }
	case ^TSTypeAliasDeclaration:
		if v != nil { sem_declare(ctx, v.id.name, .TypeAlias, {}, u32(v.loc.start), u32(v.loc.end)) }
	case ^TSEnumDeclaration:
		if v != nil { sem_declare(ctx, v.id.name, .Enum, {}, u32(v.loc.start), u32(v.loc.end)) }
	case ^TSModuleDeclaration:
		if v != nil {
			if id, ok := v.id^.(^Identifier); ok && id != nil {
				sem_declare(ctx, id.name, .Namespace, {}, u32(v.loc.start), u32(v.loc.end))
			}
		}
	}
}

sem_walk_decl :: proc(ctx: ^SemCtx, d: ^Declaration, exported: bool) {
	if d == nil { return }
	#partial switch inner in d^ {
	case ^FunctionDeclaration:
		if inner != nil {
			flags: SymbolFlags = {.Exported} if exported else {}
			if bid, ok := inner.id.(BindingIdentifier); ok {
				sem_declare(ctx, bid.name, .Function, flags, u32(bid.loc.start), u32(bid.loc.end))
			}
			sem_walk_function(ctx, &inner.expr)
		}
	case ^ClassDeclaration:
		if inner != nil {
			flags: SymbolFlags = {.Exported} if exported else {}
			if bid, ok := inner.id.(BindingIdentifier); ok {
				sem_declare(ctx, bid.name, .Class, flags, u32(bid.loc.start), u32(bid.loc.end))
			}
			sem_walk_class(ctx, &inner.expr)
		}
	case ^VariableDeclaration:
		if inner != nil { sem_walk_var_decl(ctx, inner) }
	}
}

sem_walk_var_decl :: proc(ctx: ^SemCtx, d: ^VariableDeclaration) {
	if d == nil { return }
	kind: SymbolKind
	flags: SymbolFlags
	switch d.kind {
	case .Var:      kind = .Var
	case .Let:      kind = .Let
	case .Const:    kind = .Const; flags = {.Readonly}
	case .Using:    kind = .Using
	case .AwaitUsing: kind = .Using
	}
	for decl in d.declarations {
		sem_declare_pattern(ctx, decl.id, kind, flags)
		if init, ok := decl.init.(^Expression); ok { sem_walk_expr(ctx, init) }
	}
}

sem_declare_pattern :: proc(ctx: ^SemCtx, pat: Pattern, kind: SymbolKind, flags: SymbolFlags) {
	if pat == nil { return }
	switch p in pat {
	case ^Identifier:
		if p != nil { sem_declare(ctx, p.name, kind, flags, u32(p.loc.start), u32(p.loc.end)) }
	case ^AssignmentPattern:
		if p != nil { sem_declare_pattern(ctx, p.left, kind, flags); sem_walk_expr(ctx, p.right) }
	case ^ObjectPattern:
		if p != nil {
			for prop in p.properties {
				sem_declare_pattern(ctx, prop.value, kind, flags)
			}
		}
	case ^ArrayPattern:
		if p != nil {
			for el in p.elements {
				if inner, ok := el.(Pattern); ok { sem_declare_pattern(ctx, inner, kind, flags) }
			}
		}
	case ^RestElement:
		if p != nil { sem_declare_pattern(ctx, p.argument, kind, flags) }
	case ^MemberExpression:
		// Not a binding — a reference.
	}
}

sem_walk_function :: proc(ctx: ^SemCtx, fn: ^FunctionExpression) {
	if fn == nil { return }
	saved := ctx.cur_scope
	sem_open_scope(ctx, .Function, u32(fn.loc.start), u32(fn.loc.end), false)
	for pr in fn.params {
		sem_declare_pattern(ctx, pr.pattern, .Param, {})
		if d, ok := pr.default_val.(^Expression); ok { sem_walk_expr(ctx, d) }
	}
	if !fn.no_body {
		for s in fn.body.body { sem_walk_stmt(ctx, s) }
	}
	sem_close_scope(ctx)
}

sem_walk_class :: proc(ctx: ^SemCtx, cls: ^ClassExpression) {
	if cls == nil { return }
	if sc, ok := cls.super_class.(^Expression); ok { sem_walk_expr(ctx, sc) }
	saved := ctx.cur_scope
	sem_open_scope(ctx, .Class, u32(cls.loc.start), u32(cls.loc.end), false)
	for elem in cls.body.body {
		if val, ok := elem.value.(^Expression); ok { sem_walk_expr(ctx, val) }
	}
	sem_close_scope(ctx)
}

sem_walk_expr :: proc(ctx: ^SemCtx, expr: ^Expression) {
	if expr == nil { return }
	#partial switch e in expr^ {
	case ^Identifier:
		if e != nil { sem_ref(ctx, e.name, .Read, u32(e.loc.start), u32(e.loc.end)) }
	case ^AssignmentExpression:
		if e != nil {
			if id, ok := e.left.(^Identifier); ok && id != nil {
				sem_ref(ctx, id.name, .Write if e.operator == .Assign else .ReadWrite, u32(id.loc.start), u32(id.loc.end))
			} else {
				sem_walk_expr(ctx, e.left)
			}
			sem_walk_expr(ctx, e.right)
		}
	case ^UpdateExpression:
		if e != nil {
			if id, ok := e.argument^.(^Identifier); ok && id != nil {
				sem_ref(ctx, id.name, .ReadWrite, u32(id.loc.start), u32(id.loc.end))
			} else {
				sem_walk_expr(ctx, e.argument)
			}
		}
	case ^BinaryExpression:     if e != nil { sem_walk_expr(ctx, e.left); sem_walk_expr(ctx, e.right) }
	case ^LogicalExpression:    if e != nil { sem_walk_expr(ctx, e.left); sem_walk_expr(ctx, e.right) }
	case ^MemberExpression:     if e != nil { sem_walk_expr(ctx, e.object) }
	case ^CallExpression:       if e != nil { sem_walk_expr(ctx, e.callee); for a in e.arguments { sem_walk_expr(ctx, a) } }
	case ^NewExpression:        if e != nil { sem_walk_expr(ctx, e.callee); for a in e.arguments { sem_walk_expr(ctx, a) } }
	case ^ConditionalExpression: if e != nil { sem_walk_expr(ctx, e.test); sem_walk_expr(ctx, e.consequent); sem_walk_expr(ctx, e.alternate) }
	case ^SequenceExpression:   if e != nil { for s in e.expressions { sem_walk_expr(ctx, s) } }
	case ^ArrayExpression:      if e != nil { for el in e.elements { if inner, ok := el.(^Expression); ok { sem_walk_expr(ctx, inner) } } }
	case ^ObjectExpression:     if e != nil { for prop in e.properties { if prop.value != nil { sem_walk_expr(ctx, prop.value) } } }
	case ^SpreadElement:        if e != nil { sem_walk_expr(ctx, e.argument) }
	case ^UnaryExpression:      if e != nil { sem_walk_expr(ctx, e.argument) }
	case ^AwaitExpression:      if e != nil { sem_walk_expr(ctx, e.argument) }
	case ^YieldExpression:      if e != nil { if a, ok := e.argument.(^Expression); ok { sem_walk_expr(ctx, a) } }
	case ^TemplateLiteral:      if e != nil { for s in e.expressions { sem_walk_expr(ctx, s) } }
	case ^TaggedTemplateExpression: if e != nil { sem_walk_expr(ctx, e.tag); sem_walk_expr(ctx, e.quasi) }
	case ^FunctionExpression:   if e != nil { sem_walk_function(ctx, e) }
	case ^ArrowFunctionExpression:
		if e != nil {
			saved := ctx.cur_scope
			sem_open_scope(ctx, .Function, u32(e.loc.start), u32(e.loc.end), false)
			for pr in e.params {
				sem_declare_pattern(ctx, pr.pattern, .Param, {})
				if d, ok := pr.default_val.(^Expression); ok { sem_walk_expr(ctx, d) }
			}
			switch b in e.body {
			case ^Expression:     if b != nil { sem_walk_expr(ctx, b) }
			case ^BlockStatement: if b != nil { for s in b.body { sem_walk_stmt(ctx, s) } }
			}
			sem_close_scope(ctx)
		}
	case ^ClassExpression:      if e != nil { sem_walk_class(ctx, e) }
	case ^ChainExpression:      if e != nil { sem_walk_expr(ctx, e.expression) }
	case ^ParenthesizedExpression: if e != nil { sem_walk_expr(ctx, e.expression) }
	case ^ImportExpression:     if e != nil { sem_walk_expr(ctx, e.source) }
	case ^TSAsExpression:       if e != nil { sem_walk_expr(ctx, e.expression) }
	case ^TSSatisfiesExpression: if e != nil { sem_walk_expr(ctx, e.expression) }
	case ^TSNonNullExpression:  if e != nil { sem_walk_expr(ctx, e.expression) }
	case ^TSTypeAssertion:      if e != nil { sem_walk_expr(ctx, e.expression) }
	case ^TSInstantiationExpression: if e != nil { sem_walk_expr(ctx, e.expression) }
	}
}

// ============================================================================
// Query API — downstream tools use these to inspect the model.
// ============================================================================

// semantic_symbol_by_id returns the symbol for a given id.
semantic_symbol :: proc(model: ^SemanticModel, id: SymbolId) -> ^Symbol {
	return &model.symbols[id]
}

// semantic_scope returns the scope for a given id.
semantic_scope :: proc(model: ^SemanticModel, id: ScopeId) -> ^Scope {
	return &model.scopes[id]
}

// semantic_is_function_scope reports whether a scope is a var-hoist target.
semantic_is_function_scope :: proc(model: ^SemanticModel, id: ScopeId) -> bool {
	kind := model.scopes[id].kind
	return kind == .Function || kind == .Module
}

// semantic_unreferenced_symbols returns symbols with ref_count == 0,
// excluding params and catch bindings (which are expected to be unused).
semantic_unreferenced :: proc(model: ^SemanticModel, alloc: mem.Allocator) -> []SymbolId {
	result := make([dynamic]SymbolId, 0, 16, alloc)
	for i in 1..<len(model.symbols) {
		sym := &model.symbols[i]
		if sym.ref_count == 0 && sym.kind != .Param && sym.kind != .CatchParam {
			append(&result, SymbolId(i))
		}
	}
	return result[:]
}
