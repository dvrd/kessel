package kessel


DeclarationMemberKey :: struct { property: DeclarationPropertyKey, static: bool }
DeclarationClassMember :: struct {
	getter, setter: ^FunctionExpression,
	overload, accessor_error, private_emitted: bool,
}

@(private)
dts_member_name :: proc(key: ^Expression) -> string {
	if key == nil { return "" }
	#partial switch k in key^ {
	case ^Identifier: return k.name
	case ^StringLiteral: return k.value
	}
	return ""
}

@(private)
dts_class :: proc(state: ^DeclarationEmit, s: ^ClassDeclaration) {
	cg := &state.writer
	if s.abstract { cg_str(cg, "abstract ") }
	cg_str(cg, "class")
	if id, ok := s.id.?; ok { cg_byte(cg, ' '); cg_str(cg, id.name) }
	dts_type_parameters(state, s.type_parameters, s.loc)
	gen_ts_type_parameter_declaration(cg, s.type_parameters)
	if base, ok := s.super_class.?; ok {
		root := base
		for root != nil {
			if member, property := root^.(^MemberExpression); property && !member.computed { root = member.object; continue }
			// `extends null` names no binding and is preserved as written.
			_, named := root^.(^Identifier)
			_, null := root^.(^NullLiteral)
			if !named && !(null && root == base) {
				// A class expression is reported at its name or `class` keyword.
				span := get_expression_loc(base)
				if class, anonymous := base^.(^ClassExpression); anonymous {
					span = {class.loc.start, class.loc.start + u32(len("class"))}
					if id, has_name := class.id.?; has_name { span = id.loc }
				}
				dts_error(state, "TS9021", "Extends clause can't contain an expression with --isolatedDeclarations.", span)
			}
			break
		}
		dts_reference(state, base, true)
		cg_str(cg, " extends "); gen_expression(cg, base, PREC_CALL)
		gen_ts_type_arguments(cg, s.super_type_arguments)
	}
	for base, i in s.implements {
		cg_str(cg, " implements " if i == 0 else ", ")
		dts_reference(state, base.expression, false)
		gen_expression(cg, base.expression, PREC_CALL)
		gen_ts_type_arguments(cg, base.type_parameters)
	}
	cg_str(cg, " {"); cg_newline(cg); cg.depth += 1
	members := make(map[DeclarationMemberKey]DeclarationClassMember)
	private_names := false
	for el in s.body.body {
		if el.key == nil { continue }
		if _, private_name := el.key^.(^PrivateIdentifier); private_name { private_names = true; continue }
		name := dts_class_key(el)
		fn, callable := dts_method_value(el)
		if !callable { continue }
		entry := members[name]
		switch el.kind {
		case .Get: entry.getter = fn
		case .Set: entry.setter = fn
		case .Method, .Constructor: if fn.no_body { entry.overload = true }
		case .Field, .StaticBlock, .IndexSignature:
		}
		members[name] = entry
	}
	if private_names { cg_str(cg, "#private;"); cg_newline(cg) }
	for el in s.body.body {
		if el.kind == .Constructor { dts_parameter_properties(state, el) }
	}
	for el in s.body.body { dts_class_member(state, el, &members) }
	cg.depth -= 1; cg_byte(cg, '}')
}

@(private)
dts_class_key :: proc(el: ClassElement) -> DeclarationMemberKey {
	return {dts_member_key(el.key, el.computed), el.static}
}

@(private)
dts_method_value :: proc(el: ClassElement) -> (^FunctionExpression, bool) {
	if el.kind == .Field || el.kind == .StaticBlock { return nil, false }
	if expr, ok := el.value.?; ok { if fn, method := expr^.(^FunctionExpression); method { return fn, true } }
	return nil, false
}

@(private)
dts_accessibility :: proc(cg: ^Codegen, access: ClassAccessibility) {
	if access == .Private { cg_str(cg, "private ") }
	if access == .Protected { cg_str(cg, "protected ") }
}

@(private)
dts_parameter_properties :: proc(state: ^DeclarationEmit, el: ClassElement) {
	fn, ok := dts_method_value(el)
	if !ok { return }
	cg := &state.writer
	for p in fn.params {
		if p.accessibility == .None && !p.readonly && !p.override_ { continue }
		pattern := p.pattern
		if assign, assigned := pattern.(^AssignmentPattern); assigned { pattern = assign.left }
		id, simple := pattern.(^Identifier)
		if !simple { continue }
		dts_accessibility(cg, p.accessibility)
		if p.readonly { cg_str(cg, "readonly ") }
		cg_str(cg, id.name)
		if id.optional { cg_byte(cg, '?') }
		if p.accessibility != .Private {
			cg_str(cg, ": ")
			init := p.default_val.? or_else nil
			if assign, assigned := p.pattern.(^AssignmentPattern); assigned { init = assign.right }
			// The property is always present, so only `?` adds undefined to it.
			dts_parameter_type(state, p, id.type_annotation, init, id.optional, true, id.loc, 0)
		}
		cg_byte(cg, ';'); cg_newline(cg)
	}
}

@(private)
dts_class_member :: proc(state: ^DeclarationEmit, el: ClassElement, members: ^map[DeclarationMemberKey]DeclarationClassMember) {
	if el.kind == .IndexSignature {
		gen_ts_signature(&state.writer, el.typing.index_signature)
		cg_byte(&state.writer, ';')
		cg_newline(&state.writer)
		return
	}
	if el.kind == .StaticBlock || el.key == nil { return }
	if _, private_name := el.key^.(^PrivateIdentifier); private_name { return }
	key := dts_class_key(el)
	entry := members^[key]
	fn, callable := dts_method_value(el)
	if callable && entry.overload && !fn.no_body { return }
	if el.accessibility == .Private && el.kind == .Method {
		// Every overload of a private method erases to the same bare name.
		if entry.private_emitted { return }
		entry.private_emitted = true
		members^[key] = entry
	}
	cg := &state.writer
	dts_accessibility(cg, el.accessibility)
	if el.static { cg_str(cg, "static ") }
	if el.abstract { cg_str(cg, "abstract ") }
	if el.readonly { cg_str(cg, "readonly ") }
	if el.is_accessor { cg_str(cg, "accessor ") }
	if el.kind == .Get { cg_str(cg, "get ") }
	if el.kind == .Set { cg_str(cg, "set ") }
	static_key := dts_property_key(state, el.key, el.computed)
	if !static_key && (el.kind != .Method || dts_entity_name_root(el.key) == nil) { return }
	if el.optional { cg_byte(cg, '?') }
	loc := get_expression_loc(el.key)
	if el.computed { loc = dts_computed_span(state, loc) }
	if el.kind == .Constructor && callable {
		cg_byte(cg, '(')
		if el.accessibility != .Private { dts_parameters(state, fn.params[:], 0) }
		cg_byte(cg, ')')
	} else if el.accessibility == .Private {
		// Private members still distinguish otherwise identical nominal classes.
		// Their types are erased, and a setter's parameter is always `value`.
		if el.kind == .Get { cg_str(cg, "()") }
		if el.kind == .Set { cg_str(cg, "(value)") }
	} else if el.kind == .Get || el.kind == .Set {
		dts_accessor(state, el, entry, loc, members)
	} else if callable {
		dts_method_signature(state, fn, loc, false, 0, false)
	} else if ty, ok := el.typing.annotation.?; ok {
		cg_str(cg, ": "); gen_ts_type(cg, ty.type_annotation)
	} else {
		init := el.value.? or_else nil
		kind := dts_primitive_type(init)
		literal := el.readonly && kind != "" && kind != "null" && kind != "undefined"
		cg_str(cg, " = " if literal && !el.optional else ": ")
		dynamic_template := false
		if init != nil { if e, ok := init^.(^TemplateLiteral); ok { dynamic_template = len(e.expressions) != 0 } }
		if (el.readonly && dynamic_template) || !dts_infer(state, init, literal, 0) {
			dts_error(state, "TS9012", "Property must have an explicit type annotation with --isolatedDeclarations.", loc)
		} else if el.optional && init != nil && dts_optional_inferred_field(init) { cg_str(cg, " | undefined") }
	}
	cg_byte(cg, ';'); cg_newline(cg)
}

@(private)
dts_accessor :: proc(state: ^DeclarationEmit, el: ClassElement, entry: DeclarationClassMember, loc: Loc, members: ^map[DeclarationMemberKey]DeclarationClassMember) {
	cg := &state.writer
	get_type, set_type: Maybe(^TSTypeAnnotation)
	set_pattern: Pattern
	if entry.getter != nil { get_type = entry.getter.return_type }
	if entry.setter != nil && len(entry.setter.params) > 0 {
		param := entry.setter.params[len(entry.setter.params) - 1]
		set_pattern = param.pattern
		set_type = dts_setter_annotation(set_pattern)
		if el.kind == .Set && set_type != nil {
			cg_byte(cg, '('); dts_parameter(state, param, true, 0); cg_byte(cg, ')')
			return
		}
	}
	chosen := get_type if get_type != nil else set_type
	if el.kind == .Get {
		cg_str(cg, "(): ")
	} else {
		cg_byte(cg, '('); gen_pattern(cg, set_pattern); cg_str(cg, ": ")
	}
	if ty, ok := chosen.?; ok { gen_ts_type(cg, ty.type_annotation) } else {
		expr: ^Expression
		if entry.getter != nil { expr = dts_return_expression(entry.getter.body.body[:]) }
		if !dts_infer(state, expr, false, 0) && !entry.accessor_error {
			key := dts_class_key(el)
			reported := entry
			reported.accessor_error = true
			members^[key] = reported
			loc := loc
			if el.kind == .Set && entry.setter != nil && len(entry.setter.params) > 0 { loc = get_pattern_loc(entry.setter.params[0].pattern) }
			dts_error(state, "TS9009", "At least one accessor must have an explicit type annotation with --isolatedDeclarations.", loc)
		}
	}
	if el.kind == .Set { cg_byte(cg, ')') }
}

@(private)
dts_method_signature :: proc(state: ^DeclarationEmit, fn: ^FunctionExpression, loc: Loc, arrow: bool, depth: int, force_return: bool) {
	dts_signature(state, fn.params[:], fn.type_parameters, fn.return_type, dts_return_expression(fn.body.body[:]), fn.loc, loc, force_return || fn.async || fn.generator, arrow, depth, method = true)
}

@(private)
dts_property_key :: proc(state: ^DeclarationEmit, key: ^Expression, computed: bool, inferred_object := false) -> bool {
	cg := &state.writer
	named := true
	if inferred_object {
		// An inferred object type spells literal names canonically: `"a"` as
		// `a`, `0x10` as `16`, and a computed literal without its brackets.
		if literal, known := dts_literal_key(key); known {
			dts_print_object_key(cg, literal)
			return true
		}
	}
	if computed {
		_, known := dts_literal_key(key)
		named = known || dts_global_symbol_member(state, key)
		if !named {
			loc := dts_computed_span(state, get_expression_loc(key))
			dts_error(state, "TS9038", "Computed property names on class or object literals cannot be inferred with --isolatedDeclarations.", loc)
		}
		if root := dts_entity_name_root(key); root != nil { dts_reference(state, root, true) }
		cg_byte(cg, '[')
	}
	gen_expression(cg, key, PREC_ASSIGN)
	if computed { cg_byte(cg, ']') }
	return named
}

// A global well-known symbol can be named directly in a declaration file.
// Local bindings named Symbol or globalThis must still pass isolated-declaration checks.
@(private)
dts_global_symbol_member :: proc(state: ^DeclarationEmit, key: ^Expression) -> bool {
	if key == nil { return false }
	expr := key
	if chain, ok := expr^.(^ChainExpression); ok { expr = chain.expression }
	member, ok := expr^.(^MemberExpression)
	if !ok || member.computed { return false }
	if _, named := member.property^.(^Identifier); !named { return false }
	if base, plain := member.object^.(^Identifier); plain {
		return base.name == "Symbol" && len(dts_lookup(state, "Symbol", .Value)) == 0
	}
	object, qualified := member.object^.(^MemberExpression)
	if !qualified || object.computed { return false }
	root, global := object.object^.(^Identifier)
	field, symbol := object.property^.(^Identifier)
	return global && symbol && root.name == "globalThis" && field.name == "Symbol" && len(dts_lookup(state, "globalThis", .Value)) == 0
}

DeclarationLiteralKey :: union {string, f64}

@(private)
dts_literal_key :: proc(key: ^Expression) -> (DeclarationLiteralKey, bool) {
	assert(key != nil)
	#partial switch node in key^ {
	case ^StringLiteral: return node.value, true
	case ^NumericLiteral: return node.value, true
	case ^TemplateLiteral:
		if len(node.expressions) == 0 {
			assert(len(node.quasis) == 1)
			return node.quasis[0].cooked.? or_else node.quasis[0].raw, true
		}
	case ^UnaryExpression:
		if num, ok := node.argument^.(^NumericLiteral); ok {
			if node.operator == .Plus { return num.value, true }
			if node.operator == .Minus { return -num.value, true }
		}
	}
	return nil, false
}

// Inferred object types spell a computed literal as a property name. Negative
// numbers still need brackets and string names must be valid IdentifierNames.
@(private)
dts_print_object_key :: proc(cg: ^Codegen, key: DeclarationLiteralKey) {
	switch name in key {
	case string:
		valid := len(name) > 0
		for cp, offset in name {
			valid = is_id_start_codepoint(u32(cp)) if offset == 0 else is_id_cont_codepoint(u32(cp))
			if !valid { break }
		}
		if valid { cg_str(cg, name) } else { gen_string_quoted(cg, name) }
	case f64:
		if name < 0 { cg_byte(cg, '[') }
		buf: [64]byte
		cg_str(cg, enum_number_string(buf[:], name))
		if name < 0 { cg_byte(cg, ']') }
	}
}

@(private)
dts_object_accessor :: proc(state: ^DeclarationEmit, property: Property, key: DeclarationPropertyKey, entry: DeclarationObjectAccessor, literal: bool, depth: int) {
	cg := &state.writer
	if key.dynamic_start == 0 && entry.getter != nil && entry.setter != nil && len(entry.setter.params) > 0 {
		param := &entry.setter.params[len(entry.setter.params) - 1]
		get_type, read := entry.getter.return_type.?
		set_type, write := dts_setter_annotation(param.pattern).?
		if read && write {
			if dts_typed_accessors(state, key.name, entry.numeric, get_type.type_annotation, param, set_type.type_annotation) { return }
		}
	}
	cg_byte(cg, ' ')
	if key.dynamic_start != 0 {
		if literal { cg_str(cg, "readonly ") }
		if !dts_property_key(state, property.key, true) { return }
	} else {
		if entry.setter == nil { cg_str(cg, "readonly ") }
		dts_print_accessor_name(cg, key.name, entry.numeric)
	}
	cg_str(cg, ": ")
	ty: Maybe(^TSTypeAnnotation)
	expr: ^Expression
	if entry.getter != nil {
		ty = entry.getter.return_type
		if !literal { expr = dts_return_expression(entry.getter.body.body[:]) }
	}
	loc := get_expression_loc(property.key)
	if property.computed { loc = dts_computed_span(state, loc) }
	if entry.setter != nil && len(entry.setter.params) > 0 {
		param := entry.setter.params[len(entry.setter.params) - 1]
		if ty == nil { ty = dts_setter_annotation(param.pattern) }
		if property.kind == .Set { loc = get_pattern_loc(param.pattern) }
	}
	if annotation, ok := ty.?; ok { gen_ts_type(cg, annotation.type_annotation) } else if !dts_infer(state, expr, false, depth + 1) {
		dts_error(state, "TS9009", "At least one accessor must have an explicit type annotation with --isolatedDeclarations.", loc)
	}
	cg_byte(cg, ';')
}

@(private)
dts_computed_span :: proc(state: ^DeclarationEmit, inner: Loc) -> Loc {
	source := state.writer.source
	comments := state.job.lexer.comments[:]
	assert(inner.start > 0)
	assert(int(inner.end) < len(source))
	loc := inner
	// The brackets can be separated from the expression by comments that
	// themselves contain brackets. Skip the parser's complete comment spans.
	if source[loc.start - 1] != '[' {
		before := codegen_comment_lower_bound(comments, loc.start)
		for loc.start > 0 {
			if before > 0 && comments[before - 1].end == loc.start {
				before -= 1
				loc.start = comments[before].start
				continue
			}
			if source[loc.start - 1] == '[' { break }
			loc.start -= 1
		}
	}
	if source[loc.end] != ']' {
		after := codegen_comment_lower_bound(comments, loc.end)
		for int(loc.end) < len(source) && source[loc.end] != ']' {
			if after < len(comments) && comments[after].start == loc.end {
				loc.end = comments[after].end
				after += 1
			} else { loc.end += 1 }
		}
	}
	assert(loc.start > 0)
	assert(int(loc.end) < len(source))
	return {loc.start - 1, loc.end + 1}
}

@(private)
dts_optional_inferred_field :: proc(init: ^Expression) -> bool {
	expr := init
	for expr != nil {
		#partial switch e in expr^ {
		case ^ParenthesizedExpression: expr = e.expression
		case ^TSAsExpression:
			if _, array := e.expression^.(^ArrayExpression); array { return dts_is_const_type(e.type_annotation) }
			if _, object := e.expression^.(^ObjectExpression); object { return dts_is_const_type(e.type_annotation) }
			return false
		case ^TSTypeAssertion: return false
		case: return dts_primitive_type(expr) != "undefined"
		}
	}
	return false
}
