package kessel

// ============================================================================
// Codegen — shared helpers (patterns, function bodies, class bodies, TS types).
// ============================================================================

// ----------------------------------------------------------------------------
// Patterns (destructuring)
// ----------------------------------------------------------------------------

gen_pattern :: proc(cg: ^Codegen, p: Pattern) {
	switch v in p {
	case ^Identifier:         gen_pattern_identifier(cg, v)
	case ^ObjectPattern:      gen_object_pattern(cg, v)
	case ^ArrayPattern:       gen_array_pattern(cg, v)
	case ^AssignmentPattern:  gen_assignment_pattern(cg, v)
	case ^RestElement:        cg_str(cg, "..."); gen_pattern(cg, v.argument)
	case ^MemberExpression:   gen_member_expression(cg, v)
	}
}

gen_pattern_identifier :: proc(cg: ^Codegen, e: ^Identifier) {
	cg_str(cg, e.name)
	if e.optional { cg_byte(cg, '?') }
	if ta, ok := e.type_annotation.?; ok {
		cg_str(cg, ": ")
		gen_ts_type(cg, ta.type_annotation)
	}
}

gen_object_pattern :: proc(cg: ^Codegen, e: ^ObjectPattern) {
	cg_byte(cg, '{')
	if len(e.properties) == 0 { cg_byte(cg, '}'); return }
	cg_space(cg)
	for i in 0..<len(e.properties) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_object_pattern_property(cg, e.properties[i])
	}
	cg_space(cg)
	cg_byte(cg, '}')
}

gen_object_pattern_property :: proc(cg: ^Codegen, p: ObjectPatternProperty) {
	if p.shorthand {
		gen_pattern(cg, p.value)
		return
	}
	if key, ok := p.key.?; ok {
		if p.computed { cg_byte(cg, '[') }
		gen_object_pattern_key(cg, key)
		if p.computed { cg_byte(cg, ']') }
		cg_byte(cg, ':')
		cg_space(cg)
	}
	gen_pattern(cg, p.value)
}

gen_object_pattern_key :: proc(cg: ^Codegen, k: ObjectPatternPropertyKey) {
	switch v in k {
	case IdentifierName:   cg_str(cg, v.name)
	case ^StringLiteral:   gen_string_literal(cg, v)
	case ^NumericLiteral:  gen_numeric_literal(cg, v)
	case ^Expression:      gen_expression(cg, v, PREC_ASSIGN)
	}
}

gen_array_pattern :: proc(cg: ^Codegen, e: ^ArrayPattern) {
	cg_byte(cg, '[')
	for i in 0..<len(e.elements) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		if el, ok := e.elements[i].?; ok {
			gen_pattern(cg, el)
		}
	}
	cg_byte(cg, ']')
}

gen_assignment_pattern :: proc(cg: ^Codegen, e: ^AssignmentPattern) {
	gen_pattern(cg, e.left)
	cg_space(cg)
	cg_byte(cg, '=')
	cg_space(cg)
	gen_expression(cg, e.right, PREC_ASSIGN)
}

// ----------------------------------------------------------------------------
// Function shared
// ----------------------------------------------------------------------------

gen_function_param :: proc(cg: ^Codegen, p: FunctionParameter) {
	// Accessibility / readonly / override / parameter properties — emit
	// the minimum keywords so the output still parses; full TS shape is a
	// follow-up.
	switch p.accessibility {
	case .None:      // nothing
	case .Public:    cg_str(cg, "public ")
	case .Private:   cg_str(cg, "private ")
	case .Protected: cg_str(cg, "protected ")
	}
	if p.readonly { cg_str(cg, "readonly ") }
	gen_pattern(cg, p.pattern)
	if d, ok := p.default_val.?; ok {
		cg_space(cg)
		cg_byte(cg, '=')
		cg_space(cg)
		gen_expression(cg, d, PREC_ASSIGN)
	}
}

gen_function_expression_like :: proc(
	cg: ^Codegen,
	async, generator: bool,
	name: string,
	params: []FunctionParameter,
	body: FunctionBody,
	no_body: bool,
	type_parameters: Maybe(^TSTypeParameterDeclaration),
	return_type: Maybe(^TSTypeAnnotation),
	is_decl: bool,
) {
	if async { cg_str(cg, "async ") }
	cg_str(cg, "function")
	if generator { cg_byte(cg, '*') }
	if len(name) > 0 {
		cg_hard_space(cg)
		cg_str(cg, name)
	}
	gen_function_params_and_body(cg, async, generator, params, body, no_body, type_parameters, return_type)
}

gen_function_params_and_body :: proc(
	cg: ^Codegen,
	async, generator: bool,
	params: []FunctionParameter,
	body: FunctionBody,
	no_body: bool,
	type_parameters: Maybe(^TSTypeParameterDeclaration),
	return_type: Maybe(^TSTypeAnnotation),
) {
	_ = type_parameters
	cg_byte(cg, '(')
	for i in 0..<len(params) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_function_param(cg, params[i])
	}
	cg_byte(cg, ')')
	if rt, ok := return_type.?; ok {
		cg_str(cg, ": ")
		gen_ts_type(cg, rt.type_annotation)
	}
	if no_body { cg_byte(cg, ';'); return }
	cg_space(cg)
	cg_byte(cg, '{')
	if len(body.body) == 0 { cg_byte(cg, '}'); return }
	cg_newline(cg)
	cg.depth += 1
	for d in body.directives {
		cg_byte(cg, '"')
		cg_str(cg, d.value.value)
		cg_str(cg, "\";")
		cg_newline(cg)
	}
	for i in 0..<len(body.body) {
		gen_statement(cg, body.body[i]^)
		cg_newline(cg)
	}
	cg.depth -= 1
	cg_byte(cg, '}')
}

// ----------------------------------------------------------------------------
// Class shared
// ----------------------------------------------------------------------------

gen_class_like :: proc(
	cg: ^Codegen,
	name: string,
	super_class: Maybe(^Expression),
	body: ClassBody,
	type_parameters: Maybe(^TSTypeParameterDeclaration),
	super_type_arguments: Maybe(^TSTypeParameterInstantiation),
	implements_list: [dynamic]TSInterfaceHeritage,
) {
	_ = type_parameters
	_ = super_type_arguments
	_ = implements_list
	cg_str(cg, "class")
	if len(name) > 0 { cg_hard_space(cg); cg_str(cg, name) }
	if sc, ok := super_class.?; ok {
		cg_str(cg, " extends ")
		gen_expression(cg, sc, PREC_CALL)
	}
	cg_space(cg)
	cg_byte(cg, '{')
	if len(body.body) == 0 { cg_byte(cg, '}'); return }
	cg_newline(cg)
	cg.depth += 1
	for el in body.body {
		gen_class_element(cg, el)
		cg_newline(cg)
	}
	cg.depth -= 1
	cg_byte(cg, '}')
}

gen_class_element :: proc(cg: ^Codegen, el: ClassElement) {
	if el.static { cg_str(cg, "static ") }
	switch el.kind {
	case .Method:
		if el.computed { cg_byte(cg, '[') }
		gen_expression(cg, el.key, PREC_ASSIGN)
		if el.computed { cg_byte(cg, ']') }
		if val, ok := el.value.?; ok {
			if fn, is_fn := val.(^FunctionExpression); is_fn {
				gen_function_params_and_body(cg, fn.async, fn.generator, fn.params[:], fn.body, fn.no_body, fn.type_parameters, fn.return_type)
				return
			}
		}
		cg_str(cg, "() {}")
	case .Get:
		cg_str(cg, "get ")
		if el.computed { cg_byte(cg, '[') }
		gen_expression(cg, el.key, PREC_ASSIGN)
		if el.computed { cg_byte(cg, ']') }
		if val, ok := el.value.?; ok {
			if fn, is_fn := val.(^FunctionExpression); is_fn {
				gen_function_params_and_body(cg, false, false, fn.params[:], fn.body, fn.no_body, nil, fn.return_type)
				return
			}
		}
		cg_str(cg, "() {}")
	case .Set:
		cg_str(cg, "set ")
		if el.computed { cg_byte(cg, '[') }
		gen_expression(cg, el.key, PREC_ASSIGN)
		if el.computed { cg_byte(cg, ']') }
		if val, ok := el.value.?; ok {
			if fn, is_fn := val.(^FunctionExpression); is_fn {
				gen_function_params_and_body(cg, false, false, fn.params[:], fn.body, fn.no_body, nil, fn.return_type)
				return
			}
		}
		cg_str(cg, "() {}")
	case .Constructor:
		cg_str(cg, "constructor")
		if val, ok := el.value.?; ok {
			if fn, is_fn := val.(^FunctionExpression); is_fn {
				gen_function_params_and_body(cg, fn.async, fn.generator, fn.params[:], fn.body, fn.no_body, fn.type_parameters, fn.return_type)
				return
			}
		}
		cg_str(cg, "() {}")
	case .StaticBlock:
		// Static-block static prefix already emitted above.
		cg_str(cg, "{ /*static block*/ }")
	}
}

// ----------------------------------------------------------------------------
// Declaration -> Statement conversion for ExportNamedDeclaration.declaration.
// ----------------------------------------------------------------------------

decl_to_stmt :: proc(d: Declaration) -> Statement {
	switch v in d {
	case ^FunctionDeclaration:        return v
	case ^VariableDeclaration:        return v
	case ^ClassDeclaration:           return v
	case ^ImportDeclaration:          return v
	case ^ExportNamedDeclaration:     return v
	case ^ExportDefaultDeclaration:   return v
	case ^ExportAllDeclaration:       return v
	case ^TSInterfaceDeclaration:     return v
	case ^TSTypeAliasDeclaration:     return v
	case ^TSEnumDeclaration:          return v
	case ^TSModuleDeclaration:        return v
	case ^TSImportEqualsDeclaration:  return v
	}
	return nil
}

// ----------------------------------------------------------------------------
// TS types — minimal coverage so TypeScript files round-trip without crash.
// ----------------------------------------------------------------------------

gen_ts_type :: proc(cg: ^Codegen, ty: ^TSType) {
	if ty == nil { cg_str(cg, "any"); return }
	switch v in ty^ {
	case ^TSAnyKeyword:       cg_str(cg, "any")
	case ^TSBigIntKeyword:    cg_str(cg, "bigint")
	case ^TSBooleanKeyword:   cg_str(cg, "boolean")
	case ^TSIntrinsicKeyword: cg_str(cg, "intrinsic")
	case ^TSNeverKeyword:     cg_str(cg, "never")
	case ^TSNullKeyword:      cg_str(cg, "null")
	case ^TSNumberKeyword:    cg_str(cg, "number")
	case ^TSObjectKeyword:    cg_str(cg, "object")
	case ^TSStringKeyword:    cg_str(cg, "string")
	case ^TSSymbolKeyword:    cg_str(cg, "symbol")
	case ^TSUndefinedKeyword: cg_str(cg, "undefined")
	case ^TSUnknownKeyword:   cg_str(cg, "unknown")
	case ^TSVoidKeyword:      cg_str(cg, "void")
	case ^TSThisType:         cg_str(cg, "this")
	case ^TSTypeReference:    gen_expression(cg, v.type_name, PREC_CALL)
	case ^TSUnionType:
		for i in 0..<len(v.types) {
			if i > 0 { cg_str(cg, " | ") }
			gen_ts_type(cg, v.types[i])
		}
	case ^TSIntersectionType:
		for i in 0..<len(v.types) {
			if i > 0 { cg_str(cg, " & ") }
			gen_ts_type(cg, v.types[i])
		}
	case ^TSArrayType:
		gen_ts_type(cg, v.element_type)
		cg_str(cg, "[]")
	case ^TSTupleType:
		cg_byte(cg, '[')
		for i in 0..<len(v.element_types) {
			if i > 0 { cg_byte(cg, ','); cg_space(cg) }
			gen_ts_type(cg, v.element_types[i])
		}
		cg_byte(cg, ']')
	case ^TSFunctionType:        cg_str(cg, "(...) => any")
	case ^TSConstructorType:     cg_str(cg, "new (...) => any")
	case ^TSTypeLiteral:         cg_str(cg, "{}")
	case ^TSConditionalType:     cg_str(cg, "/*conditional*/")
	case ^TSInferType:           cg_str(cg, "/*infer*/")
	case ^TSTypeQuery:           cg_str(cg, "/*typeof*/")
	case ^TSTypeOperator:        cg_str(cg, "/*op*/")
	case ^TSIndexedAccessType:   cg_str(cg, "/*indexed*/")
	case ^TSMappedType:          cg_str(cg, "/*mapped*/")
	case ^TSLiteralType:         cg_str(cg, "/*literal-type*/")
	case ^TSTemplateLiteralType: cg_str(cg, "/*template-literal*/")
	case ^TSParenthesizedType:
		cg_byte(cg, '(')
		gen_ts_type(cg, v.type_annotation)
		cg_byte(cg, ')')
	case ^TSRestType:
		cg_str(cg, "...")
		gen_ts_type(cg, v.type_annotation)
	case ^TSOptionalType:
		gen_ts_type(cg, v.type_annotation)
		cg_byte(cg, '?')
	case ^TSNamedTupleMember:
		cg_str(cg, v.label.name)
		cg_str(cg, ": ")
		gen_ts_type(cg, v.element_type)
	case ^TSTypePredicate:    cg_str(cg, "/*predicate*/")
	case ^TSImportType:       cg_str(cg, "/*import-type*/")
	}
}
