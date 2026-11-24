package kessel

@(private)
dts_variable :: proc(state: ^DeclarationEmit, decl: ^VariableDeclaration, part: int) {
	entry := decl.declarations[part]
	id, plain := entry.id.(^Identifier)
	if !plain {
		dts_bound_errors(state, entry.id)
		return
	}
	cg := &state.writer
	cg_str(cg, id.name)
	if annotation, ok := id.type_annotation.?; ok {
		cg_str(cg, ": ")
		gen_ts_type(cg, annotation.type_annotation)
		return
	}
	if dts_redeclared_variable(state, id.name) {
		// TypeScript merges the declarations of one variable and takes its type
		// from the checker, which an isolated emitter does not have.
		dts_error(state, "TS9010", "Variable must have an explicit type annotation with --isolatedDeclarations.", id.loc)
		return
	}
	init := entry.init.? or_else nil
	kind := dts_primitive_type(init)
	literal := decl.kind == .Const && kind != "" && kind != "null" && kind != "undefined"
	cg_str(cg, " = " if literal else ": ")
	dynamic_template := false
	if init != nil { if e, ok := init^.(^TemplateLiteral); ok { dynamic_template = len(e.expressions) > 0 } }
	if (decl.kind == .Const && dynamic_template) || !dts_infer(state, init, literal, 0) {
		dts_error(state, "TS9010", "Variable must have an explicit type annotation with --isolatedDeclarations.", id.loc)
	}
}

@(private)
dts_redeclared_variable :: proc(state: ^DeclarationEmit, name: string) -> bool {
	declarations := 0
	for index in state.regions[state.region].bindings[name] {
		if _, variable := state.items[index].statement.(^VariableDeclaration); variable {
			declarations += 1
		}
	}
	assert(declarations >= 1)
	return declarations > 1
}

@(private)
dts_bound_errors :: proc(state: ^DeclarationEmit, pattern: Pattern) {
	pending: [dynamic]Pattern
	append(&pending, pattern)
	for len(pending) > 0 {
		current := pop(&pending)
		#partial switch p in current {
		case ^Identifier: dts_error(state, "TS9019", "Binding elements can't be exported directly with --isolatedDeclarations.", p.loc)
		case ^ArrayPattern: for i := len(p.elements) - 1; i >= 0; i -= 1 { if el, ok := p.elements[i].?; ok { append(&pending, el) } }
		case ^ObjectPattern: for i := len(p.properties) - 1; i >= 0; i -= 1 { append(&pending, p.properties[i].value) }
		case ^AssignmentPattern: append(&pending, p.left)
		case ^RestElement: append(&pending, p.argument)
		}
	}
}

@(private)
dts_primitive_type :: proc(node: ^Expression) -> string {
	expr := node
	for expr != nil {
		#partial switch e in expr^ {
		case ^ParenthesizedExpression: expr = e.expression
		case ^UnaryExpression:
			if e.operator != .Minus && e.operator != .Plus { return "" }
			#partial switch _ in e.argument^ {
			case ^NumericLiteral: return "number"
			case ^BigIntLiteral: if e.operator == .Minus { return "bigint" }
			}
			return ""
		case ^NumericLiteral: return "number"
		case ^BigIntLiteral: return "bigint"
		case ^StringLiteral: return "string"
		case ^TemplateLiteral: return "string" if len(e.expressions) == 0 else ""
		case ^BooleanLiteral: return "boolean"
		case ^NullLiteral: return "null"
		case ^Identifier: return "undefined" if e.name == "undefined" else ""
		case: return ""
		}
	}
	return ""
}

@(private)
dts_primitive_literal :: proc(cg: ^Codegen, node: ^Expression) {
	expr := node
	sign := f64(1)
	for expr != nil {
		#partial switch e in expr^ {
		case ^UnaryExpression: sign = -1 if e.operator == .Minus else 1; expr = e.argument
		case ^ParenthesizedExpression: expr = e.expression
		case ^NumericLiteral:
			buf: [64]byte
			cg_str(cg, enum_number_string(buf[:], sign * e.value))
			return
		case ^TemplateLiteral: gen_string_quoted(cg, e.quasis[0].cooked.? or_else e.quasis[0].raw); return
		case ^StringLiteral: gen_string_quoted(cg, e.value); return
		case ^BigIntLiteral:
			if sign < 0 { cg_byte(cg, '-') }
			gen_bigint_literal(cg, e)
			return
		case: gen_expression(cg, expr, PREC_ASSIGN); return
		}
	}
}

@(private)
dts_infer :: proc(state: ^DeclarationEmit, expr: ^Expression, literal: bool, depth: int) -> bool {
	if expr == nil || depth >= 128 { return false }
	cg := &state.writer
	if kind := dts_primitive_type(expr); kind != "" {
		if literal { dts_primitive_literal(cg, expr) } else { cg_str(cg, kind) }
		return true
	}
	#partial switch e in expr^ {
	case ^TemplateLiteral:
		if literal { return false }; cg_str(cg, "string"); return true
	case ^ParenthesizedExpression: return dts_infer(state, e.expression, literal, depth + 1)
	// `satisfies` checks an expression without declaring its type, so TypeScript
	// does not infer through it: the declaration still needs an annotation.
	case ^TSSatisfiesExpression: return false
	case ^TSAsExpression: return dts_assertion(state, e.expression, e.type_annotation, literal, depth)
	case ^TSTypeAssertion: return dts_assertion(state, e.expression, e.type_annotation, literal, depth)
	case ^ArrayExpression:
		if !literal {
			dts_error(state, "TS9017", "Only const arrays can be inferred with --isolatedDeclarations.", e.loc)
			return true
		}
		cg_str(cg, "readonly [")
		for part, i in e.elements {
			if i > 0 { cg_str(cg, ", ") }
			element, ok := part.?
			if !ok { cg_str(cg, "undefined"); continue }
			if _, spread := element^.(^SpreadElement); spread {
				dts_error(state, "TS9018", "Arrays with spread elements can't inferred with --isolatedDeclarations.", get_expression_loc(element))
			} else if !dts_infer(state, element, true, depth + 1) { dts_expression_error(state, element) }
		}
		cg_byte(cg, ']')
		return true
	case ^ObjectExpression: dts_object(state, e, literal, depth); return true
	case ^ArrowFunctionExpression:
		body, block := e.body.(^BlockStatement)
		result := e.body.(^Expression) if !block else dts_return_expression(body.body[:])
		dts_signature(state, e.params[:], e.type_parameters, e.return_type, result, e.loc, e.loc, e.async, true, depth + 1, arrow_node = e)
		return true
	case ^ClassExpression:
		loc := Loc{e.loc.start, e.loc.start + 5}
		if id, ok := e.id.?; ok { loc = id.loc }
		dts_error(state, "TS9022", "Inference from class expressions is not supported with --isolatedDeclarations.", loc)
		return true
	case ^FunctionExpression:
		// An anonymous function is reported at its first keyword.
		loc := Loc{e.loc.start, e.loc.start + u32(len("async" if e.async else "function"))}
		if id, ok := e.id.?; ok { loc = id.loc }
		dts_signature(state, e.params[:], e.type_parameters, e.return_type, dts_return_expression(e.body.body[:]), e.loc, loc, e.async || e.generator, true, depth + 1)
		return true
	}
	return false
}

@(private)
dts_assertion :: proc(state: ^DeclarationEmit, expr: ^Expression, ty: ^TSType, literal: bool, depth: int) -> bool {
	if dts_is_const_type(ty) { return dts_infer(state, expr, true, depth + 1) }
	if ref, named := ty^.(^TSTypeReference); literal && named && ref.type_parameters == nil {
		if id, simple := ref.type_name^.(^Identifier); simple && !dts_reference_is_local(state, {id.name, id.loc, false, false}) {
			for index in dts_lookup(state, id.name, .Either) {
				if alias, found := state.items[index].statement.(^TSTypeAliasDeclaration); found && alias.type_parameters == nil {
					#partial switch _ in alias.type_annotation^ {
					case ^TSLiteralType, ^TSKeywordType:
						dts_reference(state, ref.type_name, false)
						gen_ts_type(&state.writer, alias.type_annotation)
						return true
					}
				}
			}
		}
	}
	gen_ts_type(&state.writer, ty)
	return true
}

@(private)
dts_is_const_type :: proc(ty: ^TSType) -> bool {
	if ref, ok := ty^.(^TSTypeReference); ok {
		if id, plain := ref.type_name^.(^Identifier); plain { return id.name == "const" }
	}
	return false
}

@(private)
dts_expression_error :: proc(state: ^DeclarationEmit, expr: ^Expression) {
	dts_error(state, "TS9013", "Expression type can't be inferred with --isolatedDeclarations.", dts_expression_span(state, expr))
}

// TypeScript reports a `satisfies` expression at its operator, not at the
// whole expression. Comments may separate the operand from the keyword.
@(private)
dts_expression_span :: proc(state: ^DeclarationEmit, expr: ^Expression) -> Loc {
	assert(expr != nil)
	loc := get_expression_loc(expr)
	node, satisfies := expr^.(^TSSatisfiesExpression)
	if !satisfies { return loc }
	source := state.writer.source
	comments := state.job.lexer.comments[:]
	offset := get_expression_loc(node.expression).end
	comment := codegen_comment_lower_bound(comments, offset)
	for offset < loc.end {
		if comment < len(comments) && comments[comment].start == offset {
			offset = comments[comment].end
			comment += 1
		} else if source[offset] == 's' {
			return {offset, offset + u32(len("satisfies"))}
		} else {
			offset += 1
		}
	}
	return loc
}

@(private)
dts_object :: proc(state: ^DeclarationEmit, object: ^ObjectExpression, literal: bool, depth: int) {
	cg := &state.writer
	accessors := make(map[DeclarationPropertyKey]DeclarationObjectAccessor)
	// A repeated property name keeps its first position and its last definition.
	latest := make(map[DeclarationPropertyKey]int)
	cg_byte(cg, '{')
	for property, index in object.properties {
		symbol := property.computed && dts_global_symbol_member(state, property.key)
		if key, plain := dts_plain_property_key(property); plain { latest[key] = index }
		if property.kind == .Get || property.kind == .Set {
			if property.value == nil { continue }
			fn, ok := property.value^.(^FunctionExpression)
			if !ok { continue }
			key := dts_member_key(property.key, property.computed)
			entry := accessors[key]
			if property.kind == .Get { entry.getter = fn } else { entry.setter = fn }
			if value, known := dts_literal_key(property.key); known {
				if _, numeric := value.(f64); numeric { entry.numeric = true }
			}
			accessors[key] = entry
		}
		// Symbol members are serialized independently, ahead of the named properties.
		if symbol { dts_object_member(state, property, literal, depth, true, &accessors) }
	}
	for property in object.properties {
		if property.computed && dts_global_symbol_member(state, property.key) { continue }
		member := property
		if key, plain := dts_plain_property_key(property); plain {
			index, pending := latest[key]
			if !pending { continue }
			delete_key(&latest, key)
			member = object.properties[index]
		}
		dts_object_member(state, member, literal, depth, false, &accessors)
	}
	if len(object.properties) > 0 { cg_byte(cg, ' ') }
	cg_byte(cg, '}')
}

// Only data properties with a statically known name replace one another.
// Methods, accessors and dynamic names keep their own declarations.
@(private)
dts_plain_property_key :: proc(property: Property) -> (key: DeclarationPropertyKey, plain: bool) {
	if property.kind != .Init || property.shorthand { return }
	if property.key == nil || property.value == nil { return }
	if _, spread := property.value^.(^SpreadElement); spread { return }
	key = dts_member_key(property.key, property.computed)
	return key, key.dynamic_start == 0
}

@(private)
dts_object_member :: proc(state: ^DeclarationEmit, p: Property, literal: bool, depth: int, symbol: bool, accessors: ^map[DeclarationPropertyKey]DeclarationObjectAccessor) {
	if p.key == nil || p.value == nil { dts_error(state, "TS9015", "Objects that contain spread assignments can't be inferred with --isolatedDeclarations.", p.loc); return }
	if _, spread := p.value^.(^SpreadElement); spread { dts_error(state, "TS9015", "Objects that contain spread assignments can't be inferred with --isolatedDeclarations.", p.loc); return }
	if p.shorthand { dts_error(state, "TS9016", "Objects that contain shorthand properties can't be inferred with --isolatedDeclarations.", p.loc); return }
	cg := &state.writer
	if _, boolean := p.key^.(^BooleanLiteral); boolean && p.computed {
		// TypeScript accepts `[true]` as a literal name, then omits the member
		// because it has no property name. Its value is still checked.
		start := cg.pos
		if p.kind == .Init && !dts_infer(state, p.value, literal, depth + 1) {
			dts_expression_error(state, p.value)
		}
		cg.pos = start
		return
	}
	if p.kind == .Get || p.kind == .Set {
		key := dts_member_key(p.key, p.computed)
		entry, first := accessors^[key]
		if first {
			dts_object_accessor(state, p, key, entry, literal, depth)
			delete_key(accessors, key)
		}
		return
	}
	cg_byte(cg, ' ')
	if literal { cg_str(cg, "readonly ") }
	named := dts_property_key(state, p.key, p.computed, inferred_object = true)
	if p.kind == .Method {
		arrow := literal || symbol
		if arrow { cg_str(cg, ": ") }
		fn := p.value^.(^FunctionExpression)
		loc := get_expression_loc(p.key)
		if p.computed { loc = dts_computed_span(state, loc) }
		dts_method_signature(state, fn, loc, arrow, depth + 1, literal)
	} else {
		// An unnameable property has no declaration type to infer. Callable
		// initializers still have independently checked parameter and return types.
		if !named {
			#partial switch _ in p.value^ { case ^FunctionExpression, ^ArrowFunctionExpression: case: return }
		}
		cg_str(cg, ": ")
		if !dts_infer(state, p.value, literal, depth + 1) { dts_expression_error(state, p.value) }
	}
	cg_byte(cg, ';')
}

DeclarationPropertyKey :: struct { name: string, dynamic_start: u32 }
DeclarationObjectAccessor :: struct { getter, setter: ^FunctionExpression, numeric: bool }

@(private)
dts_member_key :: proc(expr: ^Expression, computed: bool) -> DeclarationPropertyKey {
	assert(expr != nil)
	if value, known := dts_literal_key(expr); known {
		switch key in value {
		case string: return {name = key}
		case f64: return {name = dts_numeric_key(key)}
		}
	}
	if !computed { return {name = dts_member_name(expr)} }
	// Separate dynamic declarations may evaluate to different property keys.
	return {dynamic_start = get_expression_loc(expr).start}
}

@(private)
dts_default :: proc(state: ^DeclarationEmit, expr: ^Expression, keyword: string) {
	cg := &state.writer
	if id, ok := expr^.(^Identifier); ok {
		// An exported name carries its value, type and namespace meanings, so
		// a merged interface or type alias is retained with the value.
		append(&state.references, DeclarationReference{name = id.name})
		cg_str(cg, keyword)
		cg_str(cg, id.name)
		cg_byte(cg, ';')
		return
	}
	cg_str(cg, "declare const ")
	cg_str(cg, state.default_name)
	cg_str(cg, ": ")
	_, grouped := expr^.(^ParenthesizedExpression)
	if !dts_infer(state, expr, !grouped && dts_primitive_type(expr) != "", 0) {
		dts_error(state, "TS9037", "Default exports can't be inferred with --isolatedDeclarations.", dts_expression_span(state, expr))
	}
	cg_str(cg, ";\n"); cg_str(cg, keyword)
	cg_str(cg, state.default_name)
	cg_byte(cg, ';')
}
