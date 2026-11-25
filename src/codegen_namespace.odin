package kessel

// A namespace with only erased declarations has no JavaScript binding.
runtime_namespace :: proc(s: ^TSModuleDeclaration) -> bool {
	if s == nil || s.id == nil || s.declare || s.kind == .Global { return false }
	if _, named := s.id^.(^Identifier); !named { return false }
	body, present := s.body.?
	if !present || body == nil { return false }
	switch value in body^ {
	case ^TSModuleDeclaration:
		return runtime_namespace(value)
	case ^TSModuleBlock:
		for statement in value.body {
			if statement != nil && strip_statement_has_runtime(statement^) { return true }
		}
	}
	return false
}

strip_statement_has_runtime :: proc(statement: Statement) -> bool {
	#partial switch value in statement {
	case ^ExportNamedDeclaration:
		if value.export_kind == .Type { return false }
		if declaration, present := value.declaration.?; present && declaration != nil {
			return strip_statement_has_runtime(decl_to_stmt(declaration^))
		}
		return true
	case ^TSModuleDeclaration: return runtime_namespace(value)
	case ^TSEnumDeclaration: return !value.declare
	case ^TSImportEqualsDeclaration: return value.import_kind != .Type
	case ^TSInterfaceDeclaration, ^TSTypeAliasDeclaration, ^TSNamespaceExportDeclaration: return false
	case ^FunctionDeclaration: return !value.declare && !value.no_body
	case ^ClassDeclaration: return !value.declare
	case ^VariableDeclaration: return !value.declare
	}
	return true
}

gen_ts_module_declaration_stripped :: proc(cg: ^Codegen, s: ^TSModuleDeclaration, exported := false, parent := "", guard_initializer := false) {
	if !runtime_namespace(s) { return }
	state := cg.runtime_scope
	if state.program != nil { codegen_resolve_runtime_scopes(cg, state) }
	scope, found := state.namespaces[s.loc.start]
	if !found {
		cg_strip_unsupported(cg, s.loc, "unresolved namespace")
		return
	}

	id := s.id^.(^Identifier)
	name := id.name
	binding := state.symbols[scope.binding]
	if binding.kind == .Namespace && !state.namespace_bindings[scope.binding] {
		if exported { cg_module_keyword(cg, "export ") }
		cg_str(cg, "var ")
		cg_str(cg, name)
		cg_byte(cg, ';')
		cg_newline(cg)
		cg_indent(cg)
		state.namespace_bindings[scope.binding] = true
	}

	alias := codegen_open_runtime_scope(cg, scope.exports, "namespace")
	defer codegen_close_runtime_scope(cg, scope.exports)
	outer := state.active_namespace
	state.active_namespace = alias
	defer state.active_namespace = outer
	if guard_initializer { gen_module_resource_try(cg) }
	cg_str(cg, "(function(")
	cg_str(cg, alias)
	cg_str(cg, ") {")
	cg_newline(cg)
	cg.depth += 1
	switch body in s.body.?^ {
	case ^TSModuleDeclaration:
		cg_indent(cg)
		gen_ts_module_declaration_stripped(cg, body, parent = alias)
		cg_newline(cg)
	case ^TSModuleBlock:
		kind := resource_list_kind(cg, body.body[:])
		outer_resource := codegen_resource_open(cg, kind)
		for statement in body.body {
			if statement == nil || !strip_statement_has_runtime(statement^) { continue }
			gen_statement(cg, statement^)
			cg_newline(cg)
		}
		codegen_resource_close(cg, kind, outer_resource)
	}
	cg.depth -= 1
	cg_indent(cg)
	gen_runtime_scope_invocation(cg, name, parent)
	if guard_initializer { gen_module_resource_catch(cg) }
}

gen_runtime_scope_invocation :: proc(cg: ^Codegen, name, parent: string) {
	cg_str(cg, "})(")
	cg_str(cg, name)
	if parent != "" {
		cg_str(cg, " = ")
		gen_runtime_property(cg, parent, name)
	}
	cg_str(cg, " || (")
	if parent == "" {
		cg_str(cg, name)
	} else {
		gen_runtime_property(cg, parent, name)
	}
	cg_str(cg, " = {}));")
}

gen_runtime_namespace_export :: proc(cg: ^Codegen, s: ^ExportNamedDeclaration, parent: string) {
	declaration, present := s.declaration.?
	if !present || declaration == nil {
		cg_strip_unsupported(cg, s.loc, "namespace export without a declaration")
		return
	}
	if !strip_statement_has_runtime(decl_to_stmt(declaration^)) { return }
	#partial switch value in declaration^ {
	case ^VariableDeclaration:
		gen_runtime_namespace_variables(cg, value, parent)
	case ^TSModuleDeclaration:
		gen_ts_module_declaration_stripped(cg, value, parent = parent)
	case ^TSEnumDeclaration:
		gen_ts_enum_lowered(cg, value, namespace = parent)
	case ^TSImportEqualsDeclaration:
		gen_runtime_property(cg, parent, value.id.name)
		cg_str(cg, " = ")
		gen_ts_import_equals_reference(cg, value.module_reference)
		cg_byte(cg, ';')
	case ^FunctionDeclaration:
		gen_function_declaration(cg, value)
		if id, named := value.id.?; named { gen_runtime_namespace_attachment(cg, parent, id.name) }
	case ^ClassDeclaration:
		gen_class_declaration(cg, value)
		if id, named := value.id.?; named { gen_runtime_namespace_attachment(cg, parent, id.name) }
	case:
		cg_strip_unsupported(cg, s.loc, "unsupported namespace export")
	}
}

gen_runtime_namespace_attachment :: proc(cg: ^Codegen, parent, name: string) {
	cg_newline(cg)
	cg_indent(cg)
	gen_runtime_property(cg, parent, name)
	cg_str(cg, " = ")
	cg_str(cg, name)
	cg_byte(cg, ';')
}

gen_runtime_namespace_variables :: proc(cg: ^Codegen, s: ^VariableDeclaration, parent: string) {
	first := true
	for declaration in s.declarations {
		init, initialized := declaration.init.?
		if !initialized { continue }
		// An object destructuring assignment needs expression grouping.
		_, group := declaration.id.(^ObjectPattern)
		if !first { cg_newline(cg) }
		first = false
		if group { cg_byte(cg, '(') }
		gen_pattern(cg, declaration.id, parent)
		cg_str(cg, " = ")
		gen_expression(cg, init, PREC_ASSIGN)
		if group { cg_byte(cg, ')') }
		cg_byte(cg, ';')
	}
}
