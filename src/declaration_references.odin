package kessel

@(private)
dts_reference :: proc(state: ^DeclarationEmit, expr: ^Expression, value: bool, qualified := false) {
	root := expr
	for root != nil {
		#partial switch node in root^ {
		case ^Identifier:
			append(&state.references, DeclarationReference{node.name, node.loc, value, qualified})
			return
		case ^MemberExpression: root = node.object
		case: return
		}
	}
}

@(private)
dts_reference_is_local :: proc(state: ^DeclarationEmit, ref: DeclarationReference) -> bool {
	// `E.Member` in a type names a namespace. Type parameters cannot shadow it.
	if ref.qualified && !ref.value { return false }
	for scope in state.scopes {
		if scope.value == ref.value && scope.name == ref.name && scope.loc.start <= ref.loc.start && ref.loc.end <= scope.loc.end { return true }
	}
	return false
}

@(private)
dts_type_parameters :: proc(state: ^DeclarationEmit, parameters: Maybe(^TSTypeParameterDeclaration), loc: Loc) {
	if params, ok := parameters.?; ok {
		for p in params.params { append(&state.scopes, DeclarationScope{p.name.name, loc, false}) }
	}
}

@(private)
dts_parameter_scope :: proc(state: ^DeclarationEmit, pattern: Pattern, loc: Loc) {
	names: [dynamic]string
	collect_pattern_bound_names_list(pattern, &names)
	for name in names { append(&state.scopes, DeclarationScope{name, loc, true}) }
}

// A destructured parameter is printed as written, so a computed key keeps the
// binding it names alive. Nested patterns are visited without recursion.
@(private)
dts_pattern_references :: proc(state: ^DeclarationEmit, pattern: Pattern) {
	pending: [dynamic]Pattern
	append(&pending, pattern)
	for len(pending) > 0 {
		#partial switch p in pop(&pending) {
		case ^ObjectPattern:
			for property in p.properties {
				append(&pending, property.value)
				if !property.computed { continue }
				if key, ok := property.key.?; ok {
					if expr, dynamic_key := key.(^Expression); dynamic_key {
						if root := dts_entity_name_root(expr); root != nil {
							dts_reference(state, root, true)
						}
					}
				}
			}
		case ^ArrayPattern:
			for element in p.elements { if inner, ok := element.?; ok { append(&pending, inner) } }
		case ^AssignmentPattern: append(&pending, p.left)
		case ^RestElement: append(&pending, p.argument)
		}
	}
}

@(private)
dts_track_type :: proc(state: ^DeclarationEmit, ty: ^TSType) {
	#partial switch v in ty^ {
	case ^TSTypeReference:
		_, qualified := v.type_name^.(^MemberExpression)
		dts_reference(state, v.type_name, false, qualified)
	case ^TSTypeQuery: dts_reference(state, v.expr_name, true)
	case ^TSConditionalType:
		append(&state.conditionals, DeclarationConditional{get_ts_type_loc(v.extends_type)^, get_ts_type_loc(v.true_type)^})
	case ^TSInferType:
		for i := len(state.conditionals) - 1; i >= 0; i -= 1 {
			guard := state.conditionals[i]
			if guard.constraint.start <= v.loc.start && v.loc.end <= guard.constraint.end {
				append(&state.scopes, DeclarationScope{v.type_parameter.name.name, guard.result, false})
				break
			}
		}
	case ^TSMappedType:
		// The mapped key is in scope in the remapping and value types.
		if t, ok := v.name_type.?; ok { append(&state.scopes, DeclarationScope{v.type_parameter.name.name, get_ts_type_loc(t)^, false}) }
		if t, ok := v.type_annotation.?; ok { append(&state.scopes, DeclarationScope{v.type_parameter.name.name, get_ts_type_loc(t)^, false}) }
	case ^TSFunctionType:
		dts_type_parameters(state, v.type_parameters, v.loc)
		for p in v.params { dts_parameter_scope(state, p.pattern, v.loc) }
	case ^TSConstructorType:
		dts_type_parameters(state, v.type_parameters, v.loc)
		for p in v.params { dts_parameter_scope(state, p.pattern, v.loc) }
	}
}

@(private)
dts_track_signature :: proc(state: ^DeclarationEmit, sig: ^TSSignature) -> bool {
	switch v in sig^ {
	case TSPropertySignature:
		loc := get_expression_loc(v.key)
		if v.computed {
			loc = dts_computed_span(state, loc)
			if !dts_track_computed_signature(state, v.key, loc) { return false }
		}
		if v.type_annotation == nil { dts_missing_signature_type(state, loc) }
	case TSMethodSignature:
		if v.computed {
			loc := v.loc
			if v.kind != .Method { loc = dts_computed_span(state, get_expression_loc(v.key)) }
			if !dts_track_computed_signature(state, v.key, loc) { return false }
		}
		dts_type_parameters(state, v.type_parameters, v.loc)
		if v.return_type == nil && v.kind == .Method { dts_missing_signature_type(state, v.loc) }
		dts_signature_params(state, v.params[:], v.loc)
	case TSCallSignatureDeclaration:
		dts_type_parameters(state, v.type_parameters, v.loc)
		if v.return_type == nil { dts_missing_signature_type(state, v.loc) }
		dts_signature_params(state, v.params[:], v.loc)
	case TSConstructSignatureDeclaration:
		dts_type_parameters(state, v.type_parameters, v.loc)
		if v.return_type == nil { dts_error(state, "TS9008", "Method must have an explicit return type annotation with --isolatedDeclarations.", v.loc) }
		dts_signature_params(state, v.params[:], v.loc)
	case TSIndexSignature:
		for p in v.parameters { dts_parameter_scope(state, p.pattern, v.loc) }
	}
	return true
}

// An isolated type signature can name a value through a dotted path. Retain
// its root binding, including when the AST wraps the path in an optional chain.
@(private)
dts_track_computed_signature :: proc(state: ^DeclarationEmit, key: ^Expression, loc: Loc) -> bool {
	assert(key != nil)
	assert(loc.start < loc.end)
	if _, literal := dts_literal_key(key); literal { return true }
	if root := dts_entity_name_root(key); root != nil {
		dts_reference(state, root, true)
		return true
	}
	dts_error(state, "TS9014", "Computed properties must be number or string literals, variables or dotted expressions with --isolatedDeclarations.", loc)
	return false
}

@(private)
dts_entity_name_root :: proc(key: ^Expression) -> ^Expression {
	root := key
	for root != nil {
		#partial switch node in root^ {
		case ^Identifier: return root
		case ^ChainExpression: root = node.expression
		case ^MemberExpression:
			_, named := node.property^.(^Identifier)
			if node.computed || !named { return nil }
			root = node.object
		case: return nil
		}
	}
	return nil
}

@(private)
dts_missing_signature_type :: proc(state: ^DeclarationEmit, loc: Loc) {
	dts_error(state, "TS9013", "Expression type can't be inferred with --isolatedDeclarations.", loc)
}

@(private)
dts_signature_params :: proc(state: ^DeclarationEmit, params: []TSFunctionParam, loc: Loc) {
	for p in params {
		dts_parameter_scope(state, p.pattern, loc)
		if p.type_annotation == nil {
			if id, ok := p.pattern.(^Identifier); ok && id.type_annotation != nil { continue }
			dts_error(state, "TS9011", "Parameter must have an explicit type annotation with --isolatedDeclarations.", get_pattern_loc(p.pattern))
		}
	}
}
