package kessel

// ============================================================================
// Codegen — shared helpers (patterns, function bodies, class bodies, TS types).
// ============================================================================

// gen_decorator emits `@Expr` with parens when the expression is not a
// bare DecoratorMemberExpression / DecoratorCallExpression. The legacy
// decorator grammar only allows `@Ident.foo.bar(args)` style chains
// bare; anything else — `@(foo + bar)`, `@(obj[key])`, `@(foo().bar)`,
// `@(arrow => x)` — must be wrapped, otherwise the regen reparses
// differently (or as a syntax error).
gen_decorator :: proc(cg: ^Codegen, d: Decorator) {
	cg_byte(cg, '@')
	if decorator_expr_is_bare(d.expression) {
		gen_expression(cg, d.expression, PREC_CALL)
	} else {
		cg_byte(cg, '(')
		gen_expression(cg, d.expression, PREC_LOWEST)
		cg_byte(cg, ')')
	}
}

// decorator_expr_is_bare reports whether `expr` is a member-chain or
// call-on-member-chain that fits the bare decorator grammar. Anything
// else needs `@(...)` parens.
decorator_expr_is_bare :: proc(expr: ^Expression) -> bool {
	if expr == nil { return false }
	cur := expr
	// Unwrap a leading CallExpression: `@foo.bar(args)` is allowed; the
	// callee must itself be a bare member chain.
	if ce, is_call := cur^.(^CallExpression); is_call {
		if ce.optional { return false }
		cur = ce.callee
	}
	// Now `cur` must be a bare member chain: Identifier, or a chain of
	// non-computed, non-optional MemberExpression ending in Identifier.
	for {
		#partial switch v in cur^ {
		case ^Identifier:
			return true
		case ^MemberExpression:
			if v.computed { return false }
			if v.optional { return false }
			cur = v.object
		case:
			return false
		}
	}
}

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
	if len(e.properties) == 0 {
		cg_byte(cg, '}')
	} else {
		cg_space(cg)
		for i in 0..<len(e.properties) {
			if i > 0 { cg_byte(cg, ','); cg_space(cg) }
			gen_object_pattern_property(cg, e.properties[i])
		}
		cg_space(cg)
		cg_byte(cg, '}')
	}
	// TS-position annotation lives on the ObjectPattern itself when the
	// pattern is not a bare Identifier. Mirror the Identifier branch in
	// gen_pattern_identifier so `function f({a, b}: Props)` round-trips.
	if ta, ok := e.type_annotation.?; ok {
		cg_str(cg, ": ")
		gen_ts_type(cg, ta.type_annotation)
	}
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
	// Preserve a trailing hole: in `[a, ,]` the last comma is the
	// element separator, not the elision marker, so the array has 2
	// elements. Without the extra comma we would emit `[a, ]` which
	// reparses as `[a]` and silently drops the hole.
	n := len(e.elements)
	if n > 0 {
		if _, ok := e.elements[n-1].?; !ok {
			cg_byte(cg, ',')
		}
	}
	cg_byte(cg, ']')
	// Same TS-position annotation as ObjectPattern: `function
	// f([a, b]: number[])` carries `: number[]` on the ArrayPattern.
	if ta, ok := e.type_annotation.?; ok {
		cg_str(cg, ": ")
		gen_ts_type(cg, ta.type_annotation)
	}
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
	gen_ts_type_parameter_declaration(cg, type_parameters)
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
	// Directive prologue (e.g. "use strict") is already present at the
	// front of body.body[] as an ExpressionStatement; emitting it from
	// body.directives too would duplicate output. See codegen_program.
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
	_ = super_type_arguments
	cg_str(cg, "class")
	if len(name) > 0 { cg_hard_space(cg); cg_str(cg, name) }
	gen_ts_type_parameter_declaration(cg, type_parameters)
	if sc, ok := super_class.?; ok {
		cg_str(cg, " extends ")
		gen_expression(cg, sc, PREC_CALL)
		gen_ts_type_arguments(cg, super_type_arguments)
	}
	if len(implements_list) > 0 {
		cg_str(cg, " implements ")
		for i in 0..<len(implements_list) {
			if i > 0 { cg_byte(cg, ','); cg_space(cg) }
			gen_expression(cg, implements_list[i].expression, PREC_CALL)
			gen_ts_type_arguments(cg, implements_list[i].type_parameters)
		}
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
	for d in el.decorators {
		gen_decorator(cg, d)
		cg_newline(cg)
	}
	switch el.accessibility {
	case .None:      // nothing
	case .Public:    cg_str(cg, "public ")
	case .Private:   cg_str(cg, "private ")
	case .Protected: cg_str(cg, "protected ")
	}
	if el.abstract  { cg_str(cg, "abstract ") }
	if el.static    { cg_str(cg, "static ") }
	if el.override_ { cg_str(cg, "override ") }
	if el.readonly  { cg_str(cg, "readonly ") }
	if el.is_accessor { cg_str(cg, "accessor ") }
	switch el.kind {
	case .Method:
		// ClassElementKind.Method covers both MethodDefinition AND
		// PropertyDefinition: if the value is a FunctionExpression it's
		// a method; otherwise it's a field initializer (`x = 1;` or `x;`).
		// Mirrors the emitter's class-element dispatch.
		raw_val, val_ok := el.value.?
		fn: ^FunctionExpression
		is_method := false
		if val_ok {
			if f, ok := raw_val.(^FunctionExpression); ok {
				fn = f
				is_method = true
			}
		}
		if is_method {
			if fn.async { cg_str(cg, "async ") }
			if fn.generator { cg_byte(cg, '*') }
		}
		if el.computed { cg_byte(cg, '[') }
		gen_expression(cg, el.key, PREC_ASSIGN)
		if el.computed { cg_byte(cg, ']') }
		if el.optional { cg_byte(cg, '?') }
		if el.definite { cg_byte(cg, '!') }
		if ta, ok := el.type_annotation.?; ok {
			cg_str(cg, ": ")
			gen_ts_type(cg, ta.type_annotation)
		}
		if is_method {
			gen_function_params_and_body(cg, fn.async, fn.generator, fn.params[:], fn.body, fn.no_body, fn.type_parameters, fn.return_type)
			return
		}
		// PropertyDefinition path. Optional initializer + terminating `;`.
		if val_ok {
			cg_space(cg)
			cg_byte(cg, '=')
			cg_space(cg)
			gen_expression(cg, raw_val, PREC_ASSIGN)
		}
		cg_byte(cg, ';')
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
		// Parser stores the static block as a FunctionExpression with no
		// params; body.body holds the statements. See parse_static_block.
		cg_str(cg, "static ")
		cg_byte(cg, '{')
		if v, ok := el.value.?; ok {
			if fn, is_fn := v.(^FunctionExpression); is_fn && len(fn.body.body) > 0 {
				cg_newline(cg)
				cg.depth += 1
				for i in 0..<len(fn.body.body) {
					gen_statement(cg, fn.body.body[i]^)
					cg_newline(cg)
				}
				cg.depth -= 1
			}
		}
		cg_byte(cg, '}')
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
	case ^TSTypeReference:
		gen_expression(cg, v.type_name, PREC_CALL)
		gen_ts_type_arguments(cg, v.type_parameters)
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
	case ^TSFunctionType:        gen_ts_function_type(cg, v)
	case ^TSConstructorType:     gen_ts_constructor_type(cg, v)
	case ^TSTypeLiteral:         gen_ts_type_literal(cg, v)
	case ^TSConditionalType:     gen_ts_conditional_type(cg, v)
	case ^TSInferType:           gen_ts_infer_type(cg, v)
	case ^TSTypeQuery:           gen_ts_type_query(cg, v)
	case ^TSTypeOperator:        gen_ts_type_operator(cg, v)
	case ^TSIndexedAccessType:   gen_ts_indexed_access_type(cg, v)
	case ^TSMappedType:          gen_ts_mapped_type(cg, v)
	case ^TSLiteralType:         gen_ts_literal_type(cg, v)
	case ^TSTemplateLiteralType: gen_ts_template_literal_type(cg, v)
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
	case ^TSTypePredicate:    gen_ts_type_predicate(cg, v)
	case ^TSImportType:       gen_ts_import_type_full(cg, v)
	}
}
