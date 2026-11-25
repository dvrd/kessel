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
	EnumMember,
}

// SymbolFlags are orthogonal properties of a symbol.
SymbolFlags :: bit_set[SymbolFlag; u8]
SymbolFlag :: enum u8 {
	Exported,     // `export` or `export default`
	DefaultExport,
	Readonly,     // `const` or `readonly` modifier
	Ambient,      // `declare`
	TypeOnly,     // TS type-only import
	NamespaceImport, // The imported value is a module namespace object.
	RestParameter,
}

// Symbol represents one declared binding.
Symbol :: struct {
	name:       string,
	kind:       SymbolKind,
	kinds:      bit_set[SymbolKind; u16], // All declarations sharing this runtime binding.
	flags:      SymbolFlags,
	scope:      ScopeId,       // scope this symbol is declared in
	decl_scope: ScopeId,       // scope containing the declaration text; a hoisted var differs
	decl_start: u32,           // source offset of the declaration
	decl_end:   u32,
	read_count: u32,           // reads other than discarded updates and compound writes
	ref_count:  u32,           // number of references resolved to this symbol
}

// ScopeKind classifies the scope for hoisting and lookup rules.
ScopeKind :: enum u8 {
	Module,       // top-level module/script
	FunctionName, // named function-expression binding outside the parameter scope
	Function,     // function parameters; simple parameters share the body scope
	FunctionBody, // separate var environment when the parameters are non-simple
	Block,        // { } block, for-body, if-body
	Class,        // class body
	Catch,        // catch clause
	For,          // classic for initializer scope
	ForEach,      // for-in/of supplies a fresh binding on each iteration
	StaticBlock,  // class static { }
	With,         // with() body — poisons scope lookup
	Switch,       // switch body
	Namespace,    // TS namespace body
	Enum,
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
	implicit_arguments: bool,  // ordinary functions introduce arguments; arrows inherit it
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
	typeof_operand: bool,
	discarded_update: bool,
	scope:      ScopeId,       // scope the reference appears in
	resolved:   SymbolId,      // resolved symbol (SYMBOL_UNRESOLVED if global)
	start, end: u32,           // source span
}

// SemanticModel is the output of the semantic analysis pass.
SemanticModel :: struct {
	symbols:       [dynamic]Symbol,
	scopes:        [dynamic]Scope,
	refs:          [dynamic]Ref,
	binding_index: map[SemanticBindingKey]SymbolId,
	enum_scopes:   map[SemanticBindingKey]ScopeId,
	enum_members:  map[ScopeId]ScopeId,
	enum_declarations: map[u32]ScopeId,
	namespace_declarations: map[u32]NamespaceDeclarationScope,
	namespace_groups: map[SemanticBindingKey]ScopeId,
	namespace_exports: map[ScopeId]ScopeId,
	jsx_scopes: map[u32]ScopeId,
	alloc:         mem.Allocator,
}

// Optional property-use records preserve the lexical scope needed to resolve
// receivers and call arguments after all declarations have been collected.
SemanticMemberWrite :: struct { scope: ScopeId, member: ^MemberExpression }
SemanticMemberCall :: struct { scope: ScopeId, member: ^MemberExpression, argument: ^Expression }
SemanticPropertyUses :: struct {
	writes: [dynamic]SemanticMemberWrite,
	calls: [dynamic]SemanticMemberCall,
}

NamespaceDeclarationScope :: struct {
	exports: ScopeId,
	binding: SymbolId,
}

SemanticBindingKey :: struct {
	scope: ScopeId,
	name:  string,
}

// semantic_build runs the semantic analysis pass over a parsed program.
// Returns a fully-resolved SemanticModel. All memory is allocated from the
// provided arena allocator.
semantic_build :: proc(program: ^Program, source: string, lang: Lang, alloc: mem.Allocator, track_jsx_scopes := false, enum_constants: ^EnumConstants = nil, property_uses: ^SemanticPropertyUses = nil, let_uses: ^SemanticLetUses = nil, defines: ^TransformDefines = nil, mangle: ^MangleUses = nil) -> SemanticModel {
	model := SemanticModel{
		symbols = make([dynamic]Symbol, 1, 64, alloc),  // index 0 = sentinel
		scopes  = make([dynamic]Scope, 0, 32, alloc),
		refs    = make([dynamic]Ref, 0, 128, alloc),
		binding_index = make(map[SemanticBindingKey]SymbolId, 0, alloc),
		alloc   = alloc,
	}
	// Sentinel symbol at index 0 (SYMBOL_UNRESOLVED).
	model.symbols[0] = Symbol{name = "<unresolved>"}

	if program == nil { return model }
	if track_jsx_scopes { model.jsx_scopes = make(map[u32]ScopeId, alloc) }

	ctx := SemCtx{model = &model, lang = lang, source = source, track_jsx_scopes = track_jsx_scopes, enum_constants = enum_constants, property_uses = property_uses, let_uses = let_uses, defines = defines, mangle = mangle}
	if let_uses != nil {
		let_uses.declarations = make([dynamic]SemanticLetDeclaration, alloc)
		let_uses.assignments = make([dynamic]SemanticLetAssignment, alloc)
		let_uses.eval_scopes = make(map[ScopeId]bool, alloc)
	}
	ctx.block_functions = make([dynamic]SymbolId, alloc)
	if enum_constants != nil { enum_constants_init(enum_constants, alloc, len(source)) }
	if property_uses != nil {
		property_uses.writes = make([dynamic]SemanticMemberWrite, alloc)
		property_uses.calls = make([dynamic]SemanticMemberCall, alloc)
	}
	strict := program.type == .Module || directives_have_use_strict(program.directives[:]) || fn_body_lifts_strict({body=program.body})
	sem_open_scope(&ctx, .Module, 0, u32(len(source)), strict)
	// Collect: walk AST, declare symbols and record refs.
	for stmt in program.body {
		sem_walk_stmt(&ctx, stmt)
	}
	sem_bind_block_functions(&ctx)
	// Resolve: match refs to symbols via scope chain walk.
	sem_resolve(&model)
	if enum_constants != nil { enum_constants_resolve(enum_constants, &model) }

	return model
}

// SemCtx is the mutable state threaded through the collection walk.
SemCtx :: struct {
	model:    ^SemanticModel,
	lang:     Lang,
	source:   string,
	cur_scope: ScopeId,
	block_functions: [dynamic]SymbolId,
	track_jsx_scopes: bool,
	enum_constants: ^EnumConstants,
	property_uses: ^SemanticPropertyUses,
	let_uses: ^SemanticLetUses,
	let_barrier: Maybe(ScopeId),
	defines: ^TransformDefines,
	mangle: ^MangleUses,
}

// sem_open_scope pushes a new scope and returns its id.
sem_open_scope :: proc(ctx: ^SemCtx, kind: ScopeKind, start, end: u32, strict: bool) -> ScopeId {
	id := ScopeId(len(ctx.model.scopes))
	parent := ctx.cur_scope if len(ctx.model.scopes) > 0 else SCOPE_ROOT
	append(&ctx.model.scopes, Scope{
		kind       = kind,
		implicit_arguments = id != SCOPE_ROOT && ctx.model.scopes[parent].implicit_arguments,
		parent     = parent,
		symbols    = make([dynamic]SymbolId, 0, 8, ctx.model.alloc),
		children   = make([dynamic]ScopeId, 0, 4, ctx.model.alloc),
		node_start = start,
		node_end   = end,
		strict     = strict || (id != SCOPE_ROOT && ctx.model.scopes[parent].strict),
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

// sem_declare adds a symbol to its lexical or hoisted scope.
sem_declare :: proc(ctx: ^SemCtx, name: string, kind: SymbolKind, flags: SymbolFlags, start, end: u32) -> SymbolId {
	target := ctx.cur_scope
	if kind == .Var {
		for !semantic_is_function_scope(ctx.model, target) { target = ctx.model.scopes[target].parent }
	}
	kinds := bit_set[SymbolKind; u16]{kind}
	scope := &ctx.model.scopes[target]
	if scope.kind == .FunctionBody && (kind == .Var || kind == .Function) {
		if param, found := ctx.model.binding_index[{scope.parent, name}]; found && ctx.model.symbols[param].kind == .Param {
			kinds += {.Param}
		}
	}
	id := SymbolId(len(ctx.model.symbols))
	append(&ctx.model.symbols, Symbol{
		name       = name,
		kind       = kind,
		kinds      = kinds,
		flags      = flags,
		scope      = target,
		decl_scope = ctx.cur_scope,
		decl_start = start,
		decl_end   = end,
	})
	append(&ctx.model.scopes[target].symbols, id)
	key := SemanticBindingKey{scope = target, name = name}
	// Types can share a name with a value without hiding the runtime binding.
	if kind == .TypeAlias || kind == .Interface || .TypeOnly in flags { return id }
	if existing, found := ctx.model.binding_index[key]; found {
		ctx.model.symbols[existing].kinds += kinds
	} else {
		ctx.model.binding_index[key] = id
	}
	return id
}

// sem_ref records an identifier reference in the current scope.
sem_ref :: proc(ctx: ^SemCtx, name: string, kind: RefKind, start, end: u32, typeof_operand := false, discarded_update := false) {
	append(&ctx.model.refs, Ref{
		name     = name,
		kind     = kind,
		typeof_operand = typeof_operand,
		discarded_update = discarded_update,
		scope    = ctx.cur_scope,
		resolved = SYMBOL_UNRESOLVED,
		start    = start,
		end      = end,
	})
}

// sem_resolve walks every ref and resolves it by searching up the scope chain.
sem_resolve :: proc(model: ^SemanticModel) {
	for &ref in model.refs {
		ref.resolved = semantic_lookup(model, ref.scope, ref.name)
		if ref.resolved != SYMBOL_UNRESOLVED {
			symbol := &model.symbols[ref.resolved]
			symbol.ref_count += 1
			if ref.kind != .Write && !ref.discarded_update { symbol.read_count += 1 }
		}
	}
}

// semantic_lookup returns the nearest binding, or SYMBOL_UNRESOLVED.
semantic_lookup :: proc(model: ^SemanticModel, start_scope: ScopeId, name: string) -> SymbolId {
	assert(model != nil)
	assert(int(start_scope) < len(model.scopes))
	scope := start_scope
	for _ in 0..<len(model.scopes) {
		if id, found := model.binding_index[{scope = scope, name = name}]; found {
			return id
		}
		if exports, in_namespace := model.namespace_exports[scope]; in_namespace {
			if id, found := model.binding_index[{scope = exports, name = name}]; found {
				return id
			}
		}
		if members, in_enum := model.enum_members[scope]; in_enum {
			if id, found := model.binding_index[{scope = members, name = name}]; found {
				return id
			}
		}
		if scope == SCOPE_ROOT { return SYMBOL_UNRESOLVED }
		parent := model.scopes[scope].parent
		assert(parent < scope)
		scope = parent
	}
	return SYMBOL_UNRESOLVED
}

// ============================================================================
// Collect lexical declarations and references before resolving forward uses.
// ============================================================================

sem_walk_stmt :: proc(ctx: ^SemCtx, stmt: ^Statement) {
	if stmt == nil { return }
	barrier := ctx.let_barrier
	defer ctx.let_barrier = barrier
	if ctx.let_uses != nil {
		#partial switch _ in stmt^ {
		case ^IfStatement, ^WhileStatement, ^DoWhileStatement, ^SwitchStatement, ^TryStatement, ^WithStatement:
			ctx.let_barrier = ctx.cur_scope
		}
	}
	#partial switch v in stmt^ {
	case ^ExpressionStatement:
		if v != nil { sem_walk_expr(ctx, v.expression, value_used=false) }
	case ^BlockStatement:
		if v != nil { sem_walk_block(ctx, v) }
	case ^VariableDeclaration:
		if v != nil { sem_walk_var_decl(ctx, v) }
	case ^FunctionDeclaration: sem_walk_function_declaration(ctx, v, {})
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
			sem_open_scope(ctx, .For, u32(v.loc.start), u32(v.loc.end), false)
			if e, ok := v.init_expr.(^Expression); ok { sem_walk_expr(ctx, e, value_used=false) }
			if d, ok := v.init_decl.(^VariableDeclaration); ok { sem_walk_var_decl(ctx, d, loop_head=true) }
			if ctx.let_uses != nil { ctx.let_barrier = ctx.cur_scope }
			if t, ok := v.test.(^Expression); ok { sem_walk_expr(ctx, t) }
			if u, ok := v.update.(^Expression); ok { sem_walk_expr(ctx, u, value_used=false) }
			sem_walk_stmt(ctx, v.body)
			sem_close_scope(ctx)
		}
	case ^ForInStatement:
		if v != nil {
			sem_open_scope(ctx, .ForEach, u32(v.loc.start), u32(v.loc.end), false)
			if ctx.let_uses != nil { ctx.let_barrier = ctx.cur_scope }
			if e, ok := v.left_expr.(^Expression); ok { sem_walk_assignment_target(ctx, e, .Write) }
			if d, ok := v.left_decl.(^VariableDeclaration); ok { sem_walk_var_decl(ctx, d, loop_head=true) }
			sem_walk_expr(ctx, v.right)
			sem_walk_stmt(ctx, v.body)
			sem_close_scope(ctx)
		}
	case ^ForOfStatement:
		if v != nil {
			sem_open_scope(ctx, .ForEach, u32(v.loc.start), u32(v.loc.end), false)
			if ctx.let_uses != nil { ctx.let_barrier = ctx.cur_scope }
			if e, ok := v.left_expr.(^Expression); ok { sem_walk_assignment_target(ctx, e, .Write) }
			if d, ok := v.left_decl.(^VariableDeclaration); ok { sem_walk_var_decl(ctx, d, loop_head=true) }
			sem_walk_expr(ctx, v.right)
			sem_walk_stmt(ctx, v.body)
			sem_close_scope(ctx)
		}
	case ^SwitchStatement:
		if v != nil {
			sem_walk_expr(ctx, v.discriminant)
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
			sem_walk_block(ctx, &v.block)
			if h, ok := v.handler.(CatchClause); ok {
				sem_open_scope(ctx, .Catch, u32(h.loc.start), u32(h.loc.end), false)
				if pat, has := h.param.(Pattern); has {
					sem_declare_pattern(ctx, pat, .CatchParam, {})
				}
				for s in h.body.body { sem_walk_stmt(ctx, s) }
				sem_close_scope(ctx)
			}
			if f, ok := v.finalizer.(BlockStatement); ok {
				sem_walk_block(ctx, &f)
			}
		}
	case ^WithStatement:
		if v != nil {
			sem_walk_expr(ctx, v.object)
			if ctx.mangle != nil { mangle_protect_scope(ctx.model, ctx.mangle, ctx.cur_scope) }
			// Dynamic object bindings are not eligible global definitions.
			if ctx.defines != nil { ctx.defines.with_depth += 1 }
			sem_walk_stmt(ctx, v.body)
			if ctx.defines != nil { ctx.defines.with_depth -= 1 }
		}
	case ^LabeledStatement:
		if v != nil { sem_walk_stmt(ctx, v.body) }
	case ^ExportNamedDeclaration:
		if v != nil {
			if d, ok := v.declaration.(^Declaration); ok { sem_walk_decl(ctx, d, true) }
			if v.source == nil && v.export_kind != .Type {
				for item in v.specifiers {
					if local, ok := item.local.(IdentifierName); ok {
						sem_ref(ctx, local.name, .Read, local.loc.start, local.loc.end)
					}
				}
			}
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
			sem_walk_import(ctx, v)
		}
	case ^TSInterfaceDeclaration:
		if v != nil { sem_declare(ctx, v.id.name, .Interface, {}, u32(v.loc.start), u32(v.loc.end)) }
	case ^TSTypeAliasDeclaration:
		if v != nil { sem_declare(ctx, v.id.name, .TypeAlias, {}, u32(v.loc.start), u32(v.loc.end)) }
	case ^TSEnumDeclaration:
		sem_walk_enum(ctx, v, {})
	case ^TSModuleDeclaration:
		sem_walk_namespace(ctx, v, false)
	case ^TSImportEqualsDeclaration:
		sem_walk_import_equals(ctx, v, {})
	case ^TSExportAssignment:
		if v != nil { sem_walk_expr(ctx, v.expression) }
	}
}

sem_walk_block :: proc(ctx: ^SemCtx, block: ^BlockStatement) {
	assert(ctx != nil)
	assert(block != nil)
	sem_open_scope(ctx, .Block, u32(block.loc.start), u32(block.loc.end), false)
	for statement in block.body { sem_walk_stmt(ctx, statement) }
	sem_close_scope(ctx)
}

sem_walk_decl :: proc(ctx: ^SemCtx, d: ^Declaration, exported: bool) {
	if d == nil { return }
	#partial switch inner in d^ {
	case ^FunctionDeclaration: sem_walk_function_declaration(ctx, inner, {.Exported} if exported else {})
	case ^ClassDeclaration:
		if inner != nil {
			flags: SymbolFlags = {.Exported} if exported else {}
			if bid, ok := inner.id.(BindingIdentifier); ok {
				sem_declare(ctx, bid.name, .Class, flags, u32(bid.loc.start), u32(bid.loc.end))
			}
			sem_walk_class(ctx, &inner.expr)
		}
	case ^VariableDeclaration:
		flags: SymbolFlags = {.Exported} if exported else {}
		sem_walk_var_decl(ctx, inner, flags)
	case ^TSEnumDeclaration:
		flags: SymbolFlags = {.Exported} if exported else {}
		sem_walk_enum(ctx, inner, flags)
	case ^TSModuleDeclaration:
		sem_walk_namespace(ctx, inner, exported)
	case ^TSImportEqualsDeclaration:
		flags: SymbolFlags = {.Exported} if exported else {}
		sem_walk_import_equals(ctx, inner, flags)
	}
}

sem_walk_function_declaration :: proc(ctx: ^SemCtx, declaration: ^FunctionDeclaration, flags: SymbolFlags) {
	if declaration == nil { return }
	if name, ok := declaration.id.?; ok {
		id := sem_declare(ctx, name.name, .Function, flags, name.loc.start, name.loc.end)
		scope := &ctx.model.scopes[ctx.cur_scope]
		if !scope.strict && ctx.lang != .TS && ctx.lang != .TSX && !declaration.expr.async && !declaration.expr.generator {
			if !semantic_is_function_scope(ctx.model, ctx.cur_scope) { append(&ctx.block_functions, id) }
		}
	}
	sem_walk_function(ctx, &declaration.expr)
}

// An Annex B block function always has a lexical binding. It also creates
// an outer var binding when no intervening declaration blocks that name.
// Resolve these aliases after the walk so later declarations are visible.
sem_bind_block_functions :: proc(ctx: ^SemCtx) {
	model := ctx.model
	for id in ctx.block_functions {
		symbol := &model.symbols[id]
		scope := model.scopes[symbol.scope].parent
		for _ in 0..<len(model.scopes) {
			key := SemanticBindingKey{scope, symbol.name}
			if _, exists := model.binding_index[key]; exists { break }
			if semantic_is_function_scope(model, scope) {
				if model.scopes[scope].kind == .FunctionBody {
					if _, param := model.binding_index[{model.scopes[scope].parent, symbol.name}]; param { break }
				}
				model.binding_index[key] = id
				break
			}
			scope = model.scopes[scope].parent
		}
	}
}

sem_walk_import :: proc(ctx: ^SemCtx, declaration: ^ImportDeclaration) {
	for item in declaration.specifiers {
		if item == nil { continue }
		flags: SymbolFlags = {.Readonly}
		if declaration.import_kind == .Type { flags += {.TypeOnly} }
		local: BindingIdentifier
		switch spec in item^ {
		case ImportDefaultSpecifier: local = spec.local
		case ImportNamespaceSpecifier: local = spec.local; flags += {.NamespaceImport}
		case ImportSpecifier:
			local = spec.local
			if spec.loc.start < spec.imported.loc.start { flags += {.TypeOnly} }
		}
		sem_declare(ctx, local.name, .Import, flags, local.loc.start, local.loc.end)
	}
}

sem_walk_import_equals :: proc(ctx: ^SemCtx, declaration: ^TSImportEqualsDeclaration, flags: SymbolFlags) {
	if declaration == nil { return }
	flags := flags
	if declaration.import_kind == .Type { flags += {.TypeOnly} }
	id := declaration.id
	sem_declare(ctx, id.name, .Import, flags, id.loc.start, id.loc.end)
	if reference, ok := declaration.module_reference.(^Expression); ok {
		sem_walk_expr(ctx, reference)
	}
}

sem_walk_namespace :: proc(ctx: ^SemCtx, declaration: ^TSModuleDeclaration, exported: bool) {
	if declaration == nil || declaration.id == nil || declaration.declare { return }
	id, named := declaration.id^.(^Identifier)
	if !named || id == nil { return }
	body, has_body := declaration.body.?
	if !has_body || body == nil { return }

	model := ctx.model
	if model.namespace_declarations == nil {
		model.namespace_declarations = make(map[u32]NamespaceDeclarationScope, model.alloc)
		model.namespace_groups = make(map[SemanticBindingKey]ScopeId, model.alloc)
		model.namespace_exports = make(map[ScopeId]ScopeId, model.alloc)
	}
	enclosing := ctx.cur_scope
	flags: SymbolFlags = {.Exported} if exported else {}
	binding, found := model.binding_index[{scope = enclosing, name = id.name}]
	if !found {
		binding = sem_declare(ctx, id.name, .Namespace, flags, id.loc.start, id.loc.end)
	} else {
		model.symbols[binding].flags += flags
	}
	group_key := SemanticBindingKey{scope = enclosing, name = id.name}
	if parent_exports, in_namespace := model.namespace_exports[enclosing]; exported && in_namespace {
		group_key.scope = parent_exports
	}
	exports, merged := model.namespace_groups[group_key]
	if !merged {
		exports = sem_open_scope(ctx, .Namespace, declaration.loc.start, declaration.loc.end, false)
		sem_close_scope(ctx)
		model.namespace_groups[group_key] = exports
	}
	scope := sem_open_scope(ctx, .Namespace, declaration.loc.start, declaration.loc.end, false)
	defer sem_close_scope(ctx)
	model.namespace_exports[scope] = exports
	model.namespace_declarations[declaration.loc.start] = {exports, binding}
	switch value in body^ {
	case ^TSModuleBlock:
		for statement in value.body { sem_walk_stmt(ctx, statement) }
	case ^TSModuleDeclaration:
		sem_walk_namespace(ctx, value, true)
	}
	for symbol_id in model.scopes[scope].symbols {
		symbol := model.symbols[symbol_id]
		if .Exported not_in symbol.flags || .TypeOnly in symbol.flags { continue }
		key := SemanticBindingKey{scope = exports, name = symbol.name}
		if _, declared := model.binding_index[key]; !declared { model.binding_index[key] = symbol_id }
	}
}

sem_walk_enum :: proc(ctx: ^SemCtx, declaration: ^TSEnumDeclaration, flags: SymbolFlags) {
	if declaration == nil { return }
	parent := ctx.cur_scope
	model := ctx.model
	key := SemanticBindingKey{scope = parent, name = declaration.id.name}
	symbol, found := model.binding_index[key]
	if !found || model.symbols[symbol].kind != .Enum {
		symbol = sem_declare(ctx, key.name, .Enum, flags, declaration.id.loc.start, declaration.id.loc.end)
	} else {
		model.symbols[symbol].flags += flags
	}

	if model.enum_scopes == nil {
		model.enum_scopes = make(map[SemanticBindingKey]ScopeId, model.alloc)
		model.enum_members = make(map[ScopeId]ScopeId, model.alloc)
		model.enum_declarations = make(map[u32]ScopeId, model.alloc)
	}
	if exports, in_namespace := model.namespace_exports[parent]; .Exported in flags && in_namespace {
		key.scope = exports
	}
	members, merged := model.enum_scopes[key]
	if !merged {
		members = sem_open_scope(ctx, .Enum, declaration.loc.start, declaration.loc.end, false)
		sem_close_scope(ctx)
		model.enum_scopes[key] = members
	}
	model.enum_declarations[declaration.loc.start] = members
	if ctx.enum_constants != nil {
		append(&ctx.enum_constants.declarations, EnumConstantDeclaration{declaration, members, symbol})
	}
	ctx.cur_scope = members
	for member in declaration.body.members {
		if name, valid := enum_member_name(member.id); valid {
			if _, exists := model.binding_index[{scope = members, name = name}]; !exists {
				sem_declare(ctx, name, .EnumMember, {.Readonly}, member.loc.start, member.loc.end)
			}
		}
	}
	ctx.cur_scope = parent
	local := sem_open_scope(ctx, .Enum, declaration.loc.start, declaration.loc.end, false)
	defer sem_close_scope(ctx)
	model.enum_members[local] = members
	for member in declaration.body.members {
		if initializer, ok := member.initializer.?; ok { sem_walk_expr(ctx, initializer) }
	}
}

sem_walk_var_decl :: proc(ctx: ^SemCtx, d: ^VariableDeclaration, flags: SymbolFlags = {}, loop_head := false) {
	if d == nil { return }
	if ctx.let_uses != nil && d.kind == .Let && !d.declare {
		append(&ctx.let_uses.declarations, SemanticLetDeclaration{d, ctx.cur_scope, loop_head})
	}
	kind: SymbolKind
	flags := flags
	switch d.kind {
	case .Var:      kind = .Var
	case .Let:      kind = .Let
	case .Const:    kind = .Const; flags += {.Readonly}
	case .Using:    kind = .Using
	case .AwaitUsing: kind = .Using
	}
	for decl in d.declarations {
		sem_declare_pattern(ctx, decl.id, kind, flags)
		if init, ok := decl.init.(^Expression); ok {
			if ctx.mangle != nil { mangle_keep_inferred_name(ctx.mangle, decl.id, init) }
			sem_walk_expr(ctx, init)
		}
	}
}

sem_declare_pattern :: proc(ctx: ^SemCtx, pat: Pattern, kind: SymbolKind, flags: SymbolFlags) {
	if pat == nil { return }
	switch p in pat {
	case ^Identifier:
		if p != nil { sem_declare(ctx, p.name, kind, flags, u32(p.loc.start), u32(p.loc.end)) }
	case ^AssignmentPattern:
		if p != nil {
			if ctx.mangle != nil { mangle_keep_inferred_name(ctx.mangle, p.left, p.right) }
			sem_declare_pattern(ctx, p.left, kind, flags)
			sem_walk_expr(ctx, p.right)
		}
	case ^ObjectPattern:
		if p != nil {
			for prop in p.properties {
				if ctx.mangle != nil && prop.shorthand {
					if id := mangle_pattern_identifier(prop.value); id != nil { ctx.mangle.shorthand[id.loc.start] = true }
				}
				if prop.computed {
					if key, ok := prop.key.(ObjectPatternPropertyKey); ok {
						if expr, found := key.(^Expression); found { sem_walk_expr(ctx, expr) }
					}
				}
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

sem_walk_function :: proc(ctx: ^SemCtx, fn: ^FunctionExpression, bind_self := false) {
	if fn == nil { return }
	if ctx.defines != nil { ctx.defines.local_this_depth += 1 }
	defer if ctx.defines != nil { ctx.defines.local_this_depth -= 1 }
	self_scope := false
	if bind_self {
		if name, ok := fn.id.(BindingIdentifier); ok {
			sem_open_scope(ctx, .FunctionName, u32(fn.loc.start), u32(fn.loc.end), false)
			sem_declare(ctx, name.name, .Function, {.Readonly}, u32(name.loc.start), u32(name.loc.end))
			self_scope = true
		}
	}
	sem_open_scope(ctx, .Function, u32(fn.loc.start), u32(fn.loc.end), fn_body_lifts_strict(fn.body))
	ctx.model.scopes[ctx.cur_scope].implicit_arguments = true
	separate_body := sem_walk_parameters(ctx, fn.params[:])
	if !fn.no_body {
		sem_walk_function_body(ctx, fn.body.loc, fn.body.body[:], separate_body)
	}
	sem_close_scope(ctx)
	if self_scope { sem_close_scope(ctx) }
}

sem_walk_parameters :: proc(ctx: ^SemCtx, params: []FunctionParameter) -> bool {
	separate_body := false
	for param in params {
		_, rest := param.pattern.(^RestElement)
		sem_declare_pattern(ctx, param.pattern, .Param, {.RestParameter} if rest else {})
		if _, simple := param.pattern.(^Identifier); !simple { separate_body = true }
		if expression, ok := param.default_val.?; ok {
			if ctx.mangle != nil { mangle_keep_inferred_name(ctx.mangle, param.pattern, expression) }
			sem_walk_expr(ctx, expression)
			separate_body = true
		}
	}
	return separate_body
}

sem_walk_function_body :: proc(ctx: ^SemCtx, loc: Loc, body: []^Statement, separate: bool) {
	// A parameter initializer cannot see a binding declared in the body.
	if separate { sem_open_scope(ctx, .FunctionBody, loc.start, loc.end, false) }
	for statement in body { sem_walk_stmt(ctx, statement) }
	if separate { sem_close_scope(ctx) }
}

sem_walk_class :: proc(ctx: ^SemCtx, cls: ^ClassExpression, bind_self := false) {
	if cls == nil { return }
	for decorator in cls.decorators { sem_walk_expr(ctx, decorator.expression) }
	sem_open_scope(ctx, .Class, u32(cls.loc.start), u32(cls.loc.end), true)
	if bind_self {
		if name, ok := cls.id.?; ok {
			sem_declare(ctx, name.name, .Class, {.Readonly}, name.loc.start, name.loc.end)
		}
	}
	if sc, ok := cls.super_class.(^Expression); ok { sem_walk_expr(ctx, sc) }
	for elem in cls.body.body {
		for decorator in elem.decorators { sem_walk_expr(ctx, decorator.expression) }
		if elem.computed { sem_walk_expr(ctx, elem.key) }
		if val, ok := elem.value.(^Expression); ok && val != nil {
			if ctx.defines != nil { ctx.defines.local_this_depth += 1 }
			defer if ctx.defines != nil { ctx.defines.local_this_depth -= 1 }
			if elem.kind == .StaticBlock {
				if block, present := val^.(^FunctionExpression); present && block != nil {
					sem_open_scope(ctx, .StaticBlock, elem.loc.start, elem.loc.end, true)
					for stmt in block.body.body { sem_walk_stmt(ctx, stmt) }
					sem_close_scope(ctx)
				}
			} else { sem_walk_expr(ctx, val) }
		}
	}
	sem_close_scope(ctx)
}

// Grouping and erased TypeScript wrappers do not change which object is used.
semantic_runtime_expression :: proc(expr: ^Expression) -> ^Expression {
	node := expr
	for node != nil {
		#partial switch v in node^ {
		case ^ChainExpression: node = v.expression
		case ^ParenthesizedExpression: node = v.expression
		case ^TSAsExpression: node = v.expression
		case ^TSSatisfiesExpression: node = v.expression
		case ^TSNonNullExpression: node = v.expression
		case ^TSTypeAssertion: node = v.expression
		case ^TSInstantiationExpression: node = v.expression
		case: return node
		}
	}
	return nil
}

// Assignment targets use expression nodes in the AST. Walk binding-shaped
// expressions as writes and still visit receiver, key, and default expressions.
sem_walk_assignment_target :: proc(ctx: ^SemCtx, expr: ^Expression, kind: RefKind, value_used := true, deleting := false) {
	if expr == nil { return }
	assert(kind == .Write || kind == .ReadWrite)
	if ctx.defines != nil { transform_define_note(ctx, expr, true, deleting) }
	#partial switch target in expr^ {
	case ^MemberExpression:
		if target != nil {
			if ctx.property_uses != nil { append(&ctx.property_uses.writes, SemanticMemberWrite{ctx.cur_scope, target}) }
			sem_walk_expr(ctx, target.object)
			if target.computed { sem_walk_expr(ctx, target.property) }
		}
	case ^Identifier:
		if target != nil {
			sem_ref(ctx, target.name, kind, target.loc.start, target.loc.end, discarded_update = kind == .ReadWrite && !value_used)
		}
	case ^ArrayExpression:
		if target != nil {
			for element in target.elements {
				if value, ok := element.(^Expression); ok { sem_walk_assignment_target(ctx, value, kind) }
			}
		}
	case ^ObjectExpression:
		if target != nil {
			for property in target.properties {
				if ctx.mangle != nil && property.shorthand { ctx.mangle.shorthand[get_expression_loc(property.key).start] = true }
				if ctx.defines != nil && property.shorthand { ctx.defines.shorthand[get_expression_loc(property.key).start] = true }
				if property.computed { sem_walk_expr(ctx, property.key) }
				sem_walk_assignment_target(ctx, property.value, kind)
			}
		}
	case ^AssignmentExpression:
		if target != nil {
			if ctx.mangle != nil { mangle_keep_assignment_name(ctx.mangle, target) }
			sem_walk_assignment_target(ctx, target.left, kind)
			sem_walk_expr(ctx, target.right)
		}
	case ^ChainExpression:
		if target != nil { sem_walk_assignment_target(ctx, target.expression, kind, value_used) }
	case ^SpreadElement:
		if target != nil { sem_walk_assignment_target(ctx, target.argument, kind) }
	case ^ParenthesizedExpression:
		if target != nil { sem_walk_assignment_target(ctx, target.expression, kind, value_used) }
	case ^TSAsExpression:
		if target != nil { sem_walk_assignment_target(ctx, target.expression, kind, value_used) }
	case ^TSSatisfiesExpression:
		if target != nil { sem_walk_assignment_target(ctx, target.expression, kind, value_used) }
	case ^TSInstantiationExpression:
		if target != nil { sem_walk_assignment_target(ctx, target.expression, kind, value_used) }
	case ^TSTypeAssertion:
		if target != nil { sem_walk_assignment_target(ctx, target.expression, kind, value_used) }
	case ^TSNonNullExpression:
		if target != nil { sem_walk_assignment_target(ctx, target.expression, kind, value_used) }
	case:
		sem_walk_expr(ctx, expr)
	}
}

// sem_walk_chain is sem_walk_expr for binary / logical / member / call
// chains. The parser builds these in a loop and does not bound their
// length, so the chain operand is reached iteratively (see spine.odin);
// each link's other operands are walked on the way back up, in the same
// order as the recursive form.
//
// ctx.let_barrier needs care: sem_walk_expr saves it on entry and
// restores it on exit, and a LogicalExpression raises it to the current
// scope for its whole subtree. Entering the links outermost-first
// therefore leaves it raised from the first logical link inward, and
// each link's operands must see the value that was in effect just after
// that link was entered.
sem_walk_chain :: proc(ctx: ^SemCtx, expr: ^Expression) {
	assert(expr_is_spine_node(expr))
	spine: ExprSpine = ---
	// Without the chain table the links cannot be visited; the model
	// then lacks their references, the same as for an unparsed operand.
	if !expr_spine_open(&spine, expr) { return }
	defer expr_spine_close(&spine)

	barrier_outer := ctx.let_barrier
	defer ctx.let_barrier = barrier_outer
	scope := ctx.cur_scope
	barrier_raised_from := len(spine.nodes) // index of the first link that raised it

	for node, index in spine.nodes {
		if ctx.let_uses != nil {
			sem_note_let_expression(ctx, node)
			if _, is_logical := node^.(^LogicalExpression); is_logical {
				barrier_raised_from = min(barrier_raised_from, index)
			}
		}
		if ctx.defines != nil { transform_define_note(ctx, node, false) }
		sem_walk_chain_enter(ctx, node)
	}
	sem_walk_expr(ctx, spine.leaf)
	assert(ctx.cur_scope == scope)

	#reverse for node, index in spine.nodes {
		ctx.let_barrier = barrier_outer
		if index >= barrier_raised_from { ctx.let_barrier = scope }
		sem_walk_chain_leave(ctx, node)
	}
}

// sem_walk_chain_enter records what a link notes before its chain
// operand is walked.
sem_walk_chain_enter :: proc(ctx: ^SemCtx, node: ^Expression) {
	#partial switch e in node^ {
	case ^MemberExpression:
		if ctx.enum_constants != nil { enum_constants_note_read(ctx.enum_constants, e) }
	case ^CallExpression:
		if ctx.property_uses != nil && len(e.arguments) != 0 && e.callee != nil {
			callee := semantic_runtime_expression(e.callee)
			if callee != nil {
				if member, ok := callee^.(^MemberExpression); ok {
					use := SemanticMemberCall{ctx.cur_scope, member, e.arguments[0]}
					append(&ctx.property_uses.calls, use)
				}
			}
		}
	case ^BinaryExpression, ^LogicalExpression:
		// Nothing to note before the left operand.
	case:
		unreachable()
	}
}

// sem_walk_chain_leave walks a link's operands other than its chain
// operand; these are bounded by the parser's nesting limit.
sem_walk_chain_leave :: proc(ctx: ^SemCtx, node: ^Expression) {
	#partial switch e in node^ {
	case ^MemberExpression:
		if e.computed { sem_walk_expr(ctx, e.property) }
	case ^CallExpression:
		for a in e.arguments { sem_walk_expr(ctx, a) }
	case ^BinaryExpression:
		sem_walk_expr(ctx, e.right)
	case ^LogicalExpression:
		sem_walk_expr(ctx, e.right)
	case:
		unreachable()
	}
}

sem_walk_expr :: proc(ctx: ^SemCtx, expr: ^Expression, value_used := true) {
	if expr == nil { return }
	// Binary / logical / member / call chains are unbounded in length;
	// walk them with a loop instead of one frame per link.
	if expr_is_spine_node(expr) {
		sem_walk_chain(ctx, expr)
		return
	}
	barrier := ctx.let_barrier
	defer ctx.let_barrier = barrier
	if ctx.let_uses != nil { sem_note_let_expression(ctx, expr) }
	if ctx.defines != nil { transform_define_note(ctx, expr, false) }
	#partial switch e in expr^ {
	case ^Identifier:
		if e != nil { sem_ref(ctx, e.name, .Read, u32(e.loc.start), u32(e.loc.end)) }
	case ^AssignmentExpression:
		if e != nil {
			if ctx.mangle != nil { mangle_keep_assignment_name(ctx.mangle, e) }
			sem_walk_assignment_target(ctx, e.left, .Write if e.operator == .Assign else .ReadWrite, value_used)
			sem_walk_expr(ctx, e.right)
		}
	case ^UpdateExpression:
		if e != nil { sem_walk_assignment_target(ctx, e.argument, .ReadWrite, value_used) }
	case ^BinaryExpression, ^LogicalExpression, ^MemberExpression, ^CallExpression:
		unreachable() // handled by sem_walk_chain above
	case ^NewExpression:        if e != nil { sem_walk_expr(ctx, e.callee); for a in e.arguments { sem_walk_expr(ctx, a) } }
	case ^ConditionalExpression: if e != nil { sem_walk_expr(ctx, e.test); sem_walk_expr(ctx, e.consequent); sem_walk_expr(ctx, e.alternate) }
	case ^SequenceExpression:   if e != nil {
			for item, i in e.expressions { sem_walk_expr(ctx, item, value_used && i == len(e.expressions)-1) }
		}
	case ^ArrayExpression:      if e != nil { for el in e.elements { if inner, ok := el.(^Expression); ok { sem_walk_expr(ctx, inner) } } }
	case ^ObjectExpression:
		if e != nil {
			for prop in e.properties {
				if ctx.mangle != nil && prop.shorthand { ctx.mangle.shorthand[get_expression_loc(prop.key).start] = true }
				if ctx.defines != nil && prop.shorthand { ctx.defines.shorthand[get_expression_loc(prop.key).start] = true }
				if prop.computed { sem_walk_expr(ctx, prop.key) }
				sem_walk_expr(ctx, prop.value)
			}
		}
	case ^SpreadElement:        if e != nil { sem_walk_expr(ctx, e.argument) }
	case ^UnaryExpression:
		if e != nil {
			target := semantic_runtime_expression(e.argument) if e.operator == .Delete || e.operator == .Typeof else nil
			if e.operator == .Typeof && target != nil {
				if id, ok := target^.(^Identifier); ok && id != nil {
					if ctx.defines != nil { transform_define_note(ctx, target, false) }
					sem_ref(ctx, id.name, .Read, id.loc.start, id.loc.end, typeof_operand=true)
					return
				}
			}
			member_delete := false
			if ctx.property_uses != nil && target != nil { _, member_delete = target^.(^MemberExpression) }
			if e.operator == .Delete && (ctx.enum_constants != nil || member_delete || ctx.defines != nil) {
				sem_walk_assignment_target(ctx, target, .Write, deleting = true)
			} else { sem_walk_expr(ctx, e.argument, value_used=e.operator != .Void) }
		}
	case ^AwaitExpression:      if e != nil { sem_walk_expr(ctx, e.argument) }
	case ^YieldExpression:      if e != nil { if a, ok := e.argument.(^Expression); ok { sem_walk_expr(ctx, a) } }
	case ^TemplateLiteral:      if e != nil { for s in e.expressions { sem_walk_expr(ctx, s) } }
	case ^TaggedTemplateExpression: if e != nil { sem_walk_expr(ctx, e.tag); sem_walk_expr(ctx, e.quasi) }
	case ^FunctionExpression:   if e != nil { sem_walk_function(ctx, e, bind_self = true) }
	case ^ArrowFunctionExpression:
		if e != nil {
			strict := false
			if body, ok := e.body.(^BlockStatement); ok && body != nil { strict = fn_body_lifts_strict({body=body.body}) }
			sem_open_scope(ctx, .Function, u32(e.loc.start), u32(e.loc.end), strict)
			separate_body := sem_walk_parameters(ctx, e.params[:])
			switch b in e.body {
			case ^Expression:     if b != nil { sem_walk_expr(ctx, b) }
			case ^BlockStatement: if b != nil { sem_walk_function_body(ctx, b.loc, b.body[:], separate_body) }
			}
			sem_close_scope(ctx)
		}
	case ^ClassExpression:      if e != nil { sem_walk_class(ctx, e, bind_self = true) }
	case ^ChainExpression:      if e != nil { sem_walk_expr(ctx, e.expression, value_used) }
	case ^ParenthesizedExpression: if e != nil { sem_walk_expr(ctx, e.expression, value_used) }
	case ^ImportExpression:
		if e != nil { sem_walk_expr(ctx, e.source); sem_walk_expr(ctx, e.options) }
	case ^JSXElement:            if e != nil { sem_walk_jsx_element(ctx, e) }
	case ^JSXFragment:           if e != nil { sem_walk_jsx_children(ctx, e.children[:], e.loc.start) }
	case ^JSXExpressionContainer: if e != nil { sem_walk_expr(ctx, e.expression, value_used) }
	case ^JSXSpreadChild:        if e != nil { sem_walk_expr(ctx, e.expression, value_used) }
	case ^TSAsExpression:       if e != nil { sem_walk_expr(ctx, e.expression, value_used) }
	case ^TSSatisfiesExpression: if e != nil { sem_walk_expr(ctx, e.expression, value_used) }
	case ^TSNonNullExpression:  if e != nil { sem_walk_expr(ctx, e.expression, value_used) }
	case ^TSTypeAssertion:      if e != nil { sem_walk_expr(ctx, e.expression, value_used) }
	case ^TSInstantiationExpression: if e != nil { sem_walk_expr(ctx, e.expression, value_used) }
	}
}

sem_walk_jsx_element :: proc(ctx: ^SemCtx, element: ^JSXElement) {
	if element.opening_element != nil {
		name := element.opening_element.name
		is_member := false
		for {
			member, ok := name.(^JSXMemberExpression)
			if !ok { break }
			is_member = true
			switch base in member.object {
			case JSXIdentifier: name = base
			case ^JSXMemberExpression: name = base
			}
		}
		if id, ok := name.(JSXIdentifier); ok && id.name != "this" && (is_member || jsx_component_name(id.name)) {
			sem_ref(ctx, id.name, .Read, id.loc.start, id.loc.end)
		}
		for attr in element.opening_element.attributes {
			#partial switch item in attr {
			case JSXAttribute:
				if value, ok := item.value.(^Expression); ok { sem_walk_expr(ctx, value) }
			case ^JSXSpreadAttribute:
				if item != nil { sem_walk_expr(ctx, item.argument) }
			}
		}
	}
	sem_walk_jsx_children(ctx, element.children[:], element.loc.start)
}

sem_walk_jsx_children :: proc(ctx: ^SemCtx, children: []JSXChild, start: u32) {
	if ctx.track_jsx_scopes { ctx.model.jsx_scopes[start] = ctx.cur_scope }
	for child in children {
		#partial switch item in child {
		case ^JSXElement:             if item != nil { sem_walk_jsx_element(ctx, item) }
		case ^JSXFragment:            if item != nil { sem_walk_jsx_children(ctx, item.children[:], item.loc.start) }
		case ^JSXExpressionContainer: if item != nil { sem_walk_expr(ctx, item.expression) }
		case ^JSXSpreadChild:          if item != nil { sem_walk_expr(ctx, item.expression) }
		}
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
	return kind == .Function || kind == .FunctionBody || kind == .Module || kind == .Namespace || kind == .StaticBlock
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
