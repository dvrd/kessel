package kessel

// ============================================================================
// Codegen — TypeScript constructs.
//
// Real source emission for every TS form the parser produces. Replaces the
// placeholder `/*marker*/` stubs that previously lived in codegen_impl.odin.
//
// The procs here are split into three layers:
//
//   1. `gen_ts_type_parameter_declaration` / `gen_ts_type_arguments` /
//      `gen_ts_heritage_args` — small helpers shared by declarations,
//      signatures, and expressions.
//
//   2. Top-level TS declarations (interface, type alias, enum, module,
//      import-equals, export-assignment, namespace export). Each emits a
//      full statement that round-trips through `kessel parse --lang=ts`
//      and lands on the same AST.
//
//   3. Interface/object-type member signatures (property, method, call,
//      construct, index). Used by interface bodies and `TSTypeLiteral`.
//
// Hot-path note: codegen is not on the steady-state parse path. These
// procs prioritize correctness and round-trip fidelity over per-byte
// micro-optimization.
// ============================================================================


// ----------------------------------------------------------------------------
// Type parameters / arguments
// ----------------------------------------------------------------------------

gen_ts_type_parameter_declaration :: proc(
	cg: ^Codegen,
	decl: Maybe(^TSTypeParameterDeclaration),
) {
	d, ok := decl.?
	if !ok || d == nil || len(d.params) == 0 { return }
	cg_byte(cg, '<')
	for i in 0..<len(d.params) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_ts_type_parameter(cg, d.params[i])
	}
	cg_byte(cg, '>')
}

gen_ts_type_parameter :: proc(cg: ^Codegen, p: TSTypeParameter) {
	if p.const_ { cg_str(cg, "const ") }
	if p.in_    { cg_str(cg, "in ") }
	if p.out    { cg_str(cg, "out ") }
	cg_str(cg, p.name.name)
	if c, ok := p.constraint.?; ok {
		cg_str(cg, " extends ")
		gen_ts_type(cg, c)
	}
	if d, ok := p.default_.?; ok {
		cg_str(cg, " = ")
		gen_ts_type(cg, d)
	}
}

gen_ts_type_arguments :: proc(
	cg: ^Codegen,
	args: Maybe(^TSTypeParameterInstantiation),
) {
	a, ok := args.?
	if !ok || a == nil || len(a.params) == 0 { return }
	cg_byte(cg, '<')
	for i in 0..<len(a.params) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_ts_type(cg, a.params[i])
	}
	cg_byte(cg, '>')
}


// ----------------------------------------------------------------------------
// TS function-type / method-signature parameter lists
// ----------------------------------------------------------------------------

gen_ts_function_params :: proc(cg: ^Codegen, params: []TSFunctionParam) {
	cg_byte(cg, '(')
	for i in 0..<len(params) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_ts_function_param(cg, params[i])
	}
	cg_byte(cg, ')')
}

gen_ts_function_param :: proc(cg: ^Codegen, p: TSFunctionParam) {
	gen_pattern(cg, p.pattern)
	if p.optional { cg_byte(cg, '?') }
	if ta, ok := p.type_annotation.?; ok {
		cg_str(cg, ": ")
		gen_ts_type(cg, ta.type_annotation)
	}
}


// ----------------------------------------------------------------------------
// Member signatures (interface bodies and object-type literals)
// ----------------------------------------------------------------------------

gen_ts_signature :: proc(cg: ^Codegen, sig: ^TSSignature) {
	if sig == nil { return }
	switch v in sig^ {
	case TSPropertySignature:
		if v.readonly { cg_str(cg, "readonly ") }
		if v.computed { cg_byte(cg, '[') }
		gen_expression(cg, v.key, PREC_ASSIGN)
		if v.computed { cg_byte(cg, ']') }
		if v.optional { cg_byte(cg, '?') }
		if ta, ok := v.type_annotation.?; ok {
			cg_str(cg, ": ")
			gen_ts_type(cg, ta.type_annotation)
		}

	case TSMethodSignature:
		switch v.kind {
		case .Method: // nothing
		case .Get:    cg_str(cg, "get ")
		case .Set:    cg_str(cg, "set ")
		}
		if v.computed { cg_byte(cg, '[') }
		gen_expression(cg, v.key, PREC_ASSIGN)
		if v.computed { cg_byte(cg, ']') }
		if v.optional { cg_byte(cg, '?') }
		gen_ts_type_parameter_declaration(cg, v.type_parameters)
		gen_ts_function_params(cg, v.params[:])
		if rt, ok := v.return_type.?; ok {
			cg_str(cg, ": ")
			gen_ts_type(cg, rt.type_annotation)
		}

	case TSCallSignatureDeclaration:
		gen_ts_type_parameter_declaration(cg, v.type_parameters)
		gen_ts_function_params(cg, v.params[:])
		if rt, ok := v.return_type.?; ok {
			cg_str(cg, ": ")
			gen_ts_type(cg, rt.type_annotation)
		}

	case TSConstructSignatureDeclaration:
		cg_str(cg, "new ")
		gen_ts_type_parameter_declaration(cg, v.type_parameters)
		gen_ts_function_params(cg, v.params[:])
		if rt, ok := v.return_type.?; ok {
			cg_str(cg, ": ")
			gen_ts_type(cg, rt.type_annotation)
		}

	case TSIndexSignature:
		if v.static_  { cg_str(cg, "static ") }
		if v.readonly { cg_str(cg, "readonly ") }
		cg_byte(cg, '[')
		for i in 0..<len(v.parameters) {
			if i > 0 { cg_byte(cg, ','); cg_space(cg) }
			gen_ts_function_param(cg, v.parameters[i])
		}
		cg_byte(cg, ']')
		if ta, ok := v.type_annotation.?; ok {
			cg_str(cg, ": ")
			gen_ts_type(cg, ta.type_annotation)
		}
	}
}

gen_ts_signature_list :: proc(cg: ^Codegen, members: []^TSSignature) {
	cg_byte(cg, '{')
	if len(members) == 0 { cg_byte(cg, '}'); return }
	cg_newline(cg)
	cg.depth += 1
	for i in 0..<len(members) {
		cg_indent(cg)
		gen_ts_signature(cg, members[i])
		cg_byte(cg, ';')
		cg_newline(cg)
	}
	cg.depth -= 1
	cg_indent(cg)
	cg_byte(cg, '}')
}


// ----------------------------------------------------------------------------
// Top-level declarations
// ----------------------------------------------------------------------------

gen_ts_interface_declaration_full :: proc(cg: ^Codegen, s: ^TSInterfaceDeclaration) {
	if s.declare { cg_str(cg, "declare ") }
	cg_str(cg, "interface ")
	cg_str(cg, s.id.name)
	gen_ts_type_parameter_declaration(cg, s.type_parameters)
	if len(s.extends) > 0 {
		cg_str(cg, " extends ")
		for i in 0..<len(s.extends) {
			if i > 0 { cg_byte(cg, ','); cg_space(cg) }
			gen_expression(cg, s.extends[i].expression, PREC_CALL)
			gen_ts_type_arguments(cg, s.extends[i].type_parameters)
		}
	}
	cg_space(cg)
	gen_ts_signature_list(cg, s.body.body[:])
}

gen_ts_type_alias_declaration_full :: proc(cg: ^Codegen, s: ^TSTypeAliasDeclaration) {
	if s.declare { cg_str(cg, "declare ") }
	cg_str(cg, "type ")
	cg_str(cg, s.id.name)
	gen_ts_type_parameter_declaration(cg, s.type_parameters)
	cg_str(cg, " = ")
	gen_ts_type(cg, s.type_annotation)
	cg_byte(cg, ';')
}

gen_ts_enum_declaration_full :: proc(cg: ^Codegen, s: ^TSEnumDeclaration) {
	if s.declare { cg_str(cg, "declare ") }
	if s.const_  { cg_str(cg, "const ") }
	cg_str(cg, "enum ")
	cg_str(cg, s.id.name)
	cg_space(cg)
	cg_byte(cg, '{')
	if len(s.body.members) == 0 { cg_byte(cg, '}'); return }
	cg_newline(cg)
	cg.depth += 1
	for i in 0..<len(s.body.members) {
		cg_indent(cg)
		m := s.body.members[i]
		gen_expression(cg, m.id, PREC_ASSIGN)
		if init, ok := m.initializer.?; ok {
			cg_str(cg, " = ")
			gen_expression(cg, init, PREC_ASSIGN)
		}
		cg_byte(cg, ',')
		cg_newline(cg)
	}
	cg.depth -= 1
	cg_indent(cg)
	cg_byte(cg, '}')
}

gen_ts_module_declaration_full :: proc(cg: ^Codegen, s: ^TSModuleDeclaration) {
	if s.declare { cg_str(cg, "declare ") }
	switch s.kind {
	case .Namespace: cg_str(cg, "namespace ")
	case .Module:    cg_str(cg, "module ")
	case .Global:    cg_str(cg, "global ")
	}
	gen_expression(cg, s.id, PREC_CALL)
	body_opt, has_body := s.body.?
	if !has_body || body_opt == nil { cg_byte(cg, ';'); return }
	cg_space(cg)
	switch b in body_opt^ {
	case ^TSModuleBlock:
		cg_byte(cg, '{')
		if len(b.body) == 0 { cg_byte(cg, '}'); return }
		cg_newline(cg)
		cg.depth += 1
		for i in 0..<len(b.body) {
			cg_indent(cg)
			gen_statement(cg, b.body[i]^)
			cg_newline(cg)
		}
		cg.depth -= 1
		cg_indent(cg)
		cg_byte(cg, '}')
	case ^TSModuleDeclaration:
		// `namespace A.B.C { ... }` — nested namespace chain.
		cg_byte(cg, '.')
		gen_ts_module_declaration_full(cg, b)
	}
}

gen_ts_import_equals_full :: proc(cg: ^Codegen, s: ^TSImportEqualsDeclaration) {
	cg_str(cg, "import ")
	if s.import_kind == .Type { cg_str(cg, "type ") }
	cg_str(cg, s.id.name)
	cg_str(cg, " = ")
	switch r in s.module_reference {
	case ^Expression:
		gen_expression(cg, r, PREC_CALL)
	case ^TSExternalModuleReference:
		cg_str(cg, "require(")
		gen_string_literal(cg, r.expression)
		cg_byte(cg, ')')
	}
	cg_byte(cg, ';')
}

gen_ts_export_assignment_full :: proc(cg: ^Codegen, s: ^TSExportAssignment) {
	cg_str(cg, "export = ")
	gen_expression(cg, s.expression, PREC_ASSIGN)
	cg_byte(cg, ';')
}

gen_ts_namespace_export_full :: proc(cg: ^Codegen, s: ^TSNamespaceExportDeclaration) {
	cg_str(cg, "export as namespace ")
	cg_str(cg, s.id.name)
	cg_byte(cg, ';')
}


// ----------------------------------------------------------------------------
// TSType — extended forms not handled by gen_ts_type's short branches
// ----------------------------------------------------------------------------

gen_ts_function_type :: proc(cg: ^Codegen, t: ^TSFunctionType) {
	gen_ts_type_parameter_declaration(cg, t.type_parameters)
	gen_ts_function_params(cg, t.params[:])
	cg_str(cg, " => ")
	gen_ts_type(cg, t.return_type.type_annotation)
}

gen_ts_constructor_type :: proc(cg: ^Codegen, t: ^TSConstructorType) {
	if t.abstract_ { cg_str(cg, "abstract ") }
	cg_str(cg, "new ")
	gen_ts_type_parameter_declaration(cg, t.type_parameters)
	gen_ts_function_params(cg, t.params[:])
	cg_str(cg, " => ")
	gen_ts_type(cg, t.return_type.type_annotation)
}

gen_ts_type_literal :: proc(cg: ^Codegen, t: ^TSTypeLiteral) {
	gen_ts_signature_list(cg, t.members[:])
}

gen_ts_conditional_type :: proc(cg: ^Codegen, t: ^TSConditionalType) {
	gen_ts_type(cg, t.check_type)
	cg_str(cg, " extends ")
	gen_ts_type(cg, t.extends_type)
	cg_str(cg, " ? ")
	gen_ts_type(cg, t.true_type)
	cg_str(cg, " : ")
	gen_ts_type(cg, t.false_type)
}

gen_ts_infer_type :: proc(cg: ^Codegen, t: ^TSInferType) {
	cg_str(cg, "infer ")
	cg_str(cg, t.type_parameter.name.name)
	if c, ok := t.type_parameter.constraint.?; ok {
		cg_str(cg, " extends ")
		gen_ts_type(cg, c)
	}
}

gen_ts_type_query :: proc(cg: ^Codegen, t: ^TSTypeQuery) {
	cg_str(cg, "typeof ")
	gen_expression(cg, t.expr_name, PREC_CALL)
	gen_ts_type_arguments(cg, t.type_parameters)
}

gen_ts_type_operator :: proc(cg: ^Codegen, t: ^TSTypeOperator) {
	cg_str(cg, t.operator)
	cg_space(cg)
	gen_ts_type(cg, t.type_annotation)
}

gen_ts_indexed_access_type :: proc(cg: ^Codegen, t: ^TSIndexedAccessType) {
	gen_ts_type(cg, t.object_type)
	cg_byte(cg, '[')
	gen_ts_type(cg, t.index_type)
	cg_byte(cg, ']')
}

gen_ts_mapped_type :: proc(cg: ^Codegen, t: ^TSMappedType) {
	cg_byte(cg, '{')
	cg_space(cg)
	switch t.readonly {
	case .None:   // nothing
	case .Plus:   cg_str(cg, "+readonly ")
	case .Minus:  cg_str(cg, "-readonly ")
	case .True:   cg_str(cg, "readonly ")
	}
	cg_byte(cg, '[')
	cg_str(cg, t.type_parameter.name.name)
	if c, ok := t.type_parameter.constraint.?; ok {
		cg_str(cg, " in ")
		gen_ts_type(cg, c)
	}
	if nt, ok := t.name_type.?; ok {
		cg_str(cg, " as ")
		gen_ts_type(cg, nt)
	}
	cg_byte(cg, ']')
	switch t.optional {
	case .None:   // nothing
	case .Plus:   cg_str(cg, "+?")
	case .Minus:  cg_str(cg, "-?")
	case .True:   cg_byte(cg, '?')
	}
	if ta, ok := t.type_annotation.?; ok {
		cg_str(cg, ": ")
		gen_ts_type(cg, ta)
	}
	cg_byte(cg, ';')
	cg_space(cg)
	cg_byte(cg, '}')
}

gen_ts_literal_type :: proc(cg: ^Codegen, t: ^TSLiteralType) {
	gen_expression(cg, t.literal, PREC_ASSIGN)
}

gen_ts_template_literal_type :: proc(cg: ^Codegen, t: ^TSTemplateLiteralType) {
	cg_byte(cg, '`')
	for i in 0..<len(t.quasis) {
		if c, ok := t.quasis[i].cooked.?; ok {
			cg_str(cg, c)
		} else {
			cg_str(cg, t.quasis[i].raw)
		}
		if i < len(t.types) {
			cg_str(cg, "${")
			gen_ts_type(cg, t.types[i])
			cg_byte(cg, '}')
		}
	}
	cg_byte(cg, '`')
}

gen_ts_type_predicate :: proc(cg: ^Codegen, t: ^TSTypePredicate) {
	if t.asserts { cg_str(cg, "asserts ") }
	gen_expression(cg, t.parameter_name, PREC_CALL)
	if ta, ok := t.type_annotation.?; ok {
		cg_str(cg, " is ")
		gen_ts_type(cg, ta.type_annotation)
	}
}

gen_ts_import_type_full :: proc(cg: ^Codegen, t: ^TSImportType) {
	if t.is_typeof { cg_str(cg, "typeof ") }
	cg_str(cg, "import(")
	gen_ts_type(cg, t.argument)
	cg_byte(cg, ')')
	if q, ok := t.qualifier.?; ok {
		cg_byte(cg, '.')
		gen_expression(cg, q, PREC_CALL)
	}
	gen_ts_type_arguments(cg, t.type_parameters)
}

gen_ts_instantiation_full :: proc(cg: ^Codegen, e: ^TSInstantiationExpression) {
	gen_expression(cg, e.expression, PREC_CALL)
	gen_ts_type_arguments(cg, e.type_arguments)
}
