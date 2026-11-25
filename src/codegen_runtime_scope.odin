package kessel

import "core:fmt"
import "core:mem"
import "core:strings"

CodegenRuntimeScope :: struct {
	program: ^Program,
	allocator: mem.Allocator,
	declarations: map[u32]ScopeId,
	namespaces: map[u32]NamespaceDeclarationScope,
	namespace_bindings: map[SymbolId]bool,
	symbols: []Symbol,
	references: map[u32]ScopeId,
	jsx_model: ^SemanticModel,
	jsx_imports: JSXRuntimeImports,
	enum_constants: ^EnumConstants,
	used_names: map[string]bool,
	active_aliases: map[ScopeId]string,
	emitted_exports: map[ScopeId]bool,
	active_namespace: string,
	needs_module_marker: bool,
	require_alias: string,
	next_alias: int,
}

codegen_resolve_runtime_scopes :: proc(cg: ^Codegen, state: ^CodegenRuntimeScope) {
	// Most stripped files contain neither enums nor namespaces.
	classic := cg.cfg.jsx.runtime == .Classic
	model := semantic_build(state.program, cg.source, .TS, state.allocator, track_jsx_scopes = classic, enum_constants = state.enum_constants)
	state.declarations = model.enum_declarations
	state.namespaces = model.namespace_declarations
	state.symbols = model.symbols[:]
	state.namespace_bindings = make(map[SymbolId]bool, state.allocator)
	state.references = make(map[u32]ScopeId, state.allocator)
	state.used_names = make(map[string]bool, state.allocator)
	state.active_aliases = make(map[ScopeId]string, state.allocator)
	state.emitted_exports = make(map[ScopeId]bool, state.allocator)
	if classic {
		state.jsx_model = new(SemanticModel, state.allocator)
		state.jsx_model^ = model
		state.used_names[jsx_pragma_root(cg.cfg.jsx.pragma)] = true
		state.used_names[jsx_pragma_root(cg.cfg.jsx.pragma_frag)] = true
	}
	for symbol in model.symbols {
		state.used_names[symbol.name] = true
	}
	for ref in model.refs {
		state.used_names[ref.name] = true
		if ref.resolved == SYMBOL_UNRESOLVED { continue }
		symbol := model.symbols[ref.resolved]
		scope := codegen_runtime_property_scope(&model, symbol, ref.scope)
		if scope != SCOPE_ROOT { state.references[ref.start] = scope }
	}
	state.program = nil
}

codegen_runtime_property_scope :: proc(model: ^SemanticModel, symbol: Symbol, scope: ScopeId) -> ScopeId {
	if symbol.kind == .EnumMember { return symbol.scope }
	exports, found := model.namespace_exports[symbol.scope]
	if !found || .Exported not_in symbol.flags { return SCOPE_ROOT }
	#partial switch symbol.kind {
	case .Var, .Let, .Const, .Import:
		return exports
	}
	// Functions, classes, enums and namespaces keep a local binding inside
	// their own IIFE. Sibling declarations reach them through the shared object.
	for current := scope; current != SCOPE_ROOT; current = model.scopes[current].parent {
		if current == symbol.scope { return SCOPE_ROOT }
	}
	return exports
}

codegen_open_enum :: proc(cg: ^Codegen, declaration: ^TSEnumDeclaration) -> (name: string, scope: ScopeId) {
	state := cg.runtime_scope
	if state == nil { return declaration.id.name, SCOPE_ROOT }
	if state.program != nil { codegen_resolve_runtime_scopes(cg, state) }
	found: bool
	scope, found = state.declarations[declaration.loc.start]
	if !found { return declaration.id.name, SCOPE_ROOT }
	return codegen_open_runtime_scope(cg, scope, "enum"), scope
}

codegen_open_runtime_scope :: proc(cg: ^Codegen, scope: ScopeId, kind: string) -> (name: string) {
	name = codegen_fresh_runtime_binding(cg, kind)
	cg.runtime_scope.active_aliases[scope] = name
	return name
}

codegen_fresh_runtime_binding :: proc(cg: ^Codegen, kind: string) -> (name: string) {
	state := cg.runtime_scope
	if state.program != nil { codegen_resolve_runtime_scopes(cg, state) }
	for {
		state.next_alias += 1
		name = fmt.aprintf("__kessel_%s_%d", kind, state.next_alias, allocator = state.allocator)
		// Decoded identifiers catch escaped names, and the source check also
		// covers spellings in syntax the semantic walker does not visit.
		if !state.used_names[name] && !strings.contains(cg.source, name) { break }
	}
	return name
}

gen_strip_require_binding :: proc(cg: ^Codegen) {
	factory := codegen_fresh_runtime_binding(cg, "create_require")
	require_name := codegen_fresh_runtime_binding(cg, "require")
	cg.runtime_scope.require_alias = require_name
	cg_module_keyword(cg, "import { createRequire as ")
	cg_str(cg, factory)
	cg_str(cg, " } from \"node:module\";")
	cg_newline(cg)
	cg_str(cg, "const ")
	cg_str(cg, require_name)
	cg_str(cg, " = ")
	cg_str(cg, factory)
	cg_str(cg, "(import.meta.url);")
	cg_newline(cg)
}

codegen_close_runtime_scope :: proc(cg: ^Codegen, scope: ScopeId) {
	if scope != SCOPE_ROOT { delete_key(&cg.runtime_scope.active_aliases, scope) }
}

codegen_property_reference :: proc(cg: ^Codegen, identifier: ^Identifier) -> string {
	if cg.runtime_scope == nil || identifier == nil { return "" }
	scope, found := cg.runtime_scope.references[identifier.loc.start]
	if !found { return "" }
	return cg.runtime_scope.active_aliases[scope]
}

gen_expression_identifier :: proc(cg: ^Codegen, identifier: ^Identifier) {
	if alias := codegen_property_reference(cg, identifier); alias != "" {
		gen_runtime_property(cg, alias, identifier.name)
	} else {
		gen_pattern_identifier(cg, identifier)
	}
}
