package kessel

// Module bindings must remain at module scope. Guard evaluations in source
// order and initialize each binding only when its initializer has completed.
ModuleResources :: struct {
	value, completion, failure: string,
	pattern, pattern_factory: string,
}

gen_module_resource_item :: proc(cg: ^Codegen, stmt: ^Statement, kind: ResourceKind) {
	if cg.module_resources.value == "" {
		declaration, ok := stmt^.(^VariableDeclaration)
		if !ok || resource_kind(declaration) == .None {
			gen_statement(cg, stmt^)
			return
		}
		codegen_resource_init(cg, kind)
		cg.module_resources.value = codegen_fresh_runtime_binding(cg, "value")
		cg.module_resources.completion = codegen_fresh_runtime_binding(cg, "error")
		cg.module_resources.failure = codegen_fresh_runtime_binding(cg, "unwind")
		cg_str(cg, "let ")
		cg_str(cg, cg.module_resources.value)
		cg_byte(cg, ';')
		cg_newline(cg)
	}
	if !strip_statement_has_runtime(stmt^) { return }
	if cg.sm != nil { cg_indent(cg); cg_record_stmt_mapping(cg, stmt) }
	#partial switch s in stmt^ {
	case ^ImportDeclaration, ^ExportAllDeclaration, ^FunctionDeclaration:
		gen_statement(cg, stmt^)
	case ^ExportNamedDeclaration:
		if declaration, present := s.declaration.?; present {
			gen_module_resource_declaration(cg, decl_to_stmt(declaration^), true)
		} else {
			gen_statement(cg, stmt^)
		}
	case ^ExportDefaultDeclaration: gen_module_resource_default(cg, s)
	case ^VariableDeclaration, ^ClassDeclaration, ^TSImportEqualsDeclaration, ^TSEnumDeclaration, ^TSModuleDeclaration:
		gen_module_resource_declaration(cg, stmt^, false)
	case:
		gen_module_resource_try(cg)
		gen_statement(cg, stmt^)
		gen_module_resource_catch(cg)
	}
}

gen_module_resource_try :: proc(cg: ^Codegen) {
	cg_str(cg, "try {")
	cg_newline(cg)
	cg.depth += 1
}

gen_module_resource_catch :: proc(cg: ^Codegen) {
	cg_newline(cg)
	cg.depth -= 1
	cg_str(cg, "} catch (")
	error := cg.module_resources.completion
	cg_str(cg, error)
	cg_str(cg, ") {")
	cg_newline(cg)
	cg.depth += 1
	// A failed synchronous unwind throws while evaluating the await operand.
	// Only a returned promise introduces an async boundary.
	if cg.resource_scope.kind == .Async { cg_str(cg, "await ") }
	cg_str(cg, cg.module_resources.failure)
	cg_byte(cg, '(')
	cg_str(cg, error)
	cg_str(cg, ");")
	cg_newline(cg)
	cg.depth -= 1
	cg_byte(cg, '}')
}

gen_module_resource_unwind :: proc(cg: ^Codegen) {
	module := &cg.module_resources
	if module.failure == "" { return }
	cg_str(cg, "function ")
	cg_str(cg, module.failure)
	cg_str(cg, "(error) {")
	cg_newline(cg)
	cg.depth += 1
	if module.pattern != "" {
		cg_str(cg, "if (")
		cg_str(cg, module.pattern)
		cg_str(cg, ") ")
		cg_str(cg, module.pattern)
		cg_str(cg, ".abort();")
		cg_newline(cg)
	}
	cg_str(cg, cg.resource_scope.name)
	cg_str(cg, ".fail(error);")
	cg_newline(cg)
	cg_str(cg, "return ")
	cg_str(cg, cg.resource_scope.name)
	cg_str(cg, ".dispose();")
	cg_newline(cg)
	cg.depth -= 1
	cg_byte(cg, '}')
	cg_newline(cg)
}

gen_module_value_start :: proc(cg: ^Codegen, target: string) {
	gen_module_resource_try(cg)
	cg_str(cg, target)
	cg_infix_operator(cg, "=")
}

gen_module_value_end :: proc(cg: ^Codegen) {
	cg_byte(cg, ';')
	gen_module_resource_catch(cg)
	cg_newline(cg)
}

gen_module_binding :: proc(cg: ^Codegen, keyword, name, value: string, exported: bool, loc: Loc) {
	if exported { cg_module_keyword(cg, "export ") }
	cg_str(cg, keyword)
	cg_hard_space(cg)
	if cg.sm != nil { sourcemap_record(cg.sm, u32(cg.pos), loc.start) }
	cg_str(cg, name)
	if value != "" {
		cg_infix_operator(cg, "=")
		cg_str(cg, value)
	}
	cg_byte(cg, ';')
}

gen_module_resource_declaration :: proc(cg: ^Codegen, stmt: Statement, exported: bool) {
	#partial switch s in stmt {
	case ^FunctionDeclaration:
		if exported { cg_module_keyword(cg, "export ") }
		gen_function_declaration(cg, s)
	case ^VariableDeclaration:
		for item, index in s.declarations {
			if index != 0 { cg_newline(cg) }
			gen_module_resource_variable(cg, item, s.kind, exported)
		}
	case ^ClassDeclaration: gen_module_resource_class(cg, s, exported, false)
	case ^TSImportEqualsDeclaration:
		gen_module_value_start(cg, cg.module_resources.value)
		gen_ts_import_equals_reference(cg, s.module_reference)
		gen_module_value_end(cg)
		gen_module_binding(cg, "const", s.id.name, cg.module_resources.value, exported, s.id.loc)
	case ^TSEnumDeclaration:
		gen_ts_enum_lowered(cg, s, exported = exported, guard_initializer = true)
	case ^TSModuleDeclaration:
		gen_ts_module_declaration_stripped(cg, s, exported = exported, guard_initializer = true)
	}
}

gen_module_resource_variable :: proc(cg: ^Codegen, item: VariableDeclarator, kind: VariableKind, exported: bool) {
	name := ""
	if id, ok := item.id.(^Identifier); ok { name = id.name }
	keyword := "var" if kind == .Var else "let" if kind == .Let else "const"
	value := ""
	if init, present := item.init.?; present {
		value = cg.module_resources.value
		gen_module_value_start(cg, value)
		resource := kind == .Using || kind == .AwaitUsing
		if resource { codegen_resource_register(cg, .Async if kind == .AwaitUsing else .Sync) }
		gen_resource_named_value(cg, init, name)
		if resource { cg_byte(cg, ')') }
		gen_module_value_end(cg)
	}
	if name == "" {
		gen_module_resource_pattern(cg, item.id, keyword, value, exported)
	} else {
		gen_module_binding(cg, keyword, name, value, exported, item.loc)
	}
}

// Named evaluation must happen before class static fields and blocks run.
// A static property preserves a user-defined class method named "name".
gen_resource_named_value :: proc(cg: ^Codegen, value: ^Expression, name: string) {
	anonymous := false
	current := codegen_runtime_expression(cg, value)
	for current != nil {
		#partial switch v in current^ {
		case ^ParenthesizedExpression: current = codegen_runtime_expression(cg, v.expression); continue
		case ^FunctionExpression: anonymous = v.id == nil
		case ^ClassExpression: anonymous = v.id == nil
		case ^ArrowFunctionExpression: anonymous = true
		}
		break
	}
	if !anonymous { gen_expression(cg, value, PREC_ASSIGN); return }
	if name == "__proto__" {
		if class, ok := current^.(^ClassExpression); ok {
			outer := cg.resource_proto_class
			cg.resource_proto_class = class.body.loc.start
			defer cg.resource_proto_class = outer
			cg_str(cg, "(0,")
			gen_expression(cg, value, PREC_ASSIGN)
			cg_byte(cg, ')')
			return
		}
	}
	cg_str(cg, "({")
	if name == "__proto__" { cg_byte(cg, '[') }
	gen_string_quoted(cg, name)
	if name == "__proto__" { cg_byte(cg, ']') }
	cg_byte(cg, ':')
	gen_expression(cg, value, PREC_ASSIGN)
	cg_str(cg, "})[")
	gen_string_quoted(cg, name)
	cg_byte(cg, ']')
}

gen_module_resource_class :: proc(cg: ^Codegen, declaration: ^ClassDeclaration, exported, default_export: bool) {
	name := ""
	if id, ok := declaration.id.?; ok { name = id.name }
	gen_module_value_start(cg, cg.module_resources.value)
	if name == "" { cg_str(cg, "({default:") }
	gen_class_declaration(cg, declaration)
	if name == "" { cg_str(cg, "}).default") }
	gen_module_value_end(cg)
	if name != "" {
		gen_module_binding(cg, "let", name, cg.module_resources.value, exported, declaration.id.?.loc)
		if default_export { cg_newline(cg) }
	}
	if default_export {
		if name == "" {
			cg_module_keyword(cg, "export default ")
			cg_str(cg, cg.module_resources.value)
			cg_byte(cg, ';')
		} else {
			cg_module_keyword(cg, "export {")
			cg_str(cg, name)
			cg_str(cg, " as default};")
		}
	}
}

gen_module_resource_default :: proc(cg: ^Codegen, decl: ^ExportDefaultDeclaration) {
	if strip_default_export_is_erased(decl) { return }
	switch value in decl.declaration^ {
	case ^Declaration:
		if class, ok := value^.(^ClassDeclaration); ok {
			gen_module_resource_class(cg, class, false, true)
			return
		}
		gen_export_default_declaration(cg, decl)
	case ^Expression:
		gen_module_value_start(cg, cg.module_resources.value)
		gen_resource_named_value(cg, value, "default")
		gen_module_value_end(cg)
		cg_module_keyword(cg, "export default ")
		cg_str(cg, cg.module_resources.value)
		cg_byte(cg, ';')
	}
}
