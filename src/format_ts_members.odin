package kessel

// Object types, interface bodies and their members, function types and
// mapped types. Ports of Prettier's object-type, type-member and
// function-type rules.

// Parameters group on their own when a lone parameter is followed by an
// object type or by a return type that breaks: the parentheses then stay
// tight and the return type opens up instead.
format_should_group_params :: proc(
	type_parameters: Maybe(^TSTypeParameterDeclaration),
	param_count: int,
	return_type: ^TSType,
	return_doc: Doc,
) -> bool {
	if return_type == nil {return false}
	if declaration, generic := type_parameters.?; generic && declaration != nil {
		if len(declaration.params) > 1 {return false}
		if len(declaration.params) == 1 {
			param := declaration.params[0]
			if _, constrained := param.constraint.?; constrained {return false}
			if _, defaulted := param.default_.?; defaulted {return false}
		}
	}
	if param_count != 1 {return false}
	return format_type_is_object(return_type) || doc_will_break(return_doc)
}

// The object type literal that an annotation holds, or nil.
format_annotation_literal :: proc(annotation: Maybe(^TSTypeAnnotation)) -> rawptr {
	type := format_annotation_type(annotation)
	if type == nil {return nil}
	literal, is_literal := type^.(^TSTypeLiteral)
	if !is_literal {return nil}
	return literal
}

// A lone destructured parameter, or one annotated with an object type, hugs
// the parentheses of a signature.
@(private = "file")
format_should_hug_signature_param :: proc(params: []TSFunctionParam) -> bool {
	if len(params) != 1 {return false}
	#partial switch _ in params[0].pattern {
	case ^ObjectPattern, ^ArrayPattern:
		return true
	case ^Identifier:
		return format_type_is_object(format_annotation_type(params[0].type_annotation))
	}
	return false
}

@(private = "file")
format_signature_param :: proc(f: ^FormatContext, param: ^TSFunctionParam) -> Doc {
	// The parser hangs the annotation on the parameter, so a default value
	// inside the pattern would print on the wrong side of it.
	if _, defaulted := param.pattern.(^AssignmentPattern); defaulted {return format_fail(f)}
	if _, decorated := f.param_decorators[param.loc.start]; decorated {return format_fail(f)}
	return fc(
		f,
		format_pattern(f, param.pattern, .Params),
		ft(f, "?") if param.optional else nil,
		format_type_annotation(f, param.type_annotation),
	)
}

// The parameter list of a function type or a signature, with the type
// parameters that precede it.
format_signature_params :: proc(
	f: ^FormatContext,
	params: []TSFunctionParam,
	type_parameters: Doc,
) -> Doc {
	count := len(params)
	list := FormatParams {
		docs            = make([]Doc, count, f.alloc),
		ends            = make([]u32, count, f.alloc),
		hug_only        = format_should_hug_signature_param(params),
		type_parameters = type_parameters,
	}
	saved_pattern, saved_type := f.hug_pattern, f.hug_type
	defer f.hug_pattern, f.hug_type = saved_pattern, saved_type
	if list.hug_only {
		if pattern, is_object := params[0].pattern.(^ObjectPattern); is_object {
			f.hug_pattern = pattern
		}
		f.hug_type = format_annotation_literal(params[0].type_annotation)
	}
	for &param, index in params {
		list.docs[index] = format_signature_param(f, &param)
		list.ends[index] = param.loc.end
	}
	if count > 0 {_, list.has_rest = params[count - 1].pattern.(^RestElement)}
	return format_params_layout(f, list, false)
}

// `(a: A) => R` and `new (a: A) => R`.
format_function_type :: proc(
	f: ^FormatContext,
	type_parameters: Maybe(^TSTypeParameterDeclaration),
	params: []TSFunctionParam,
	return_type: ^TSTypeAnnotation,
	prefix: string,
) -> Doc {
	if return_type == nil {return format_fail(f)}
	generics := format_type_parameters(f, type_parameters)
	parameters := format_signature_params(f, params, generics)
	returned := fc(f, ft(f, " => "), format_annotated_type(f, return_type, .Return_Type))
	returned_type := format_type_unwrap(return_type.type_annotation)
	if format_should_group_params(type_parameters, len(params), returned_type, returned) {
		parameters = doc_group(f, parameters)
	}
	return fg(f, ft(f, prefix), parameters, returned)
}

@(private = "file")
format_signature_loc :: proc(signature: ^TSSignature) -> Loc {
	switch node in signature^ {
	case TSPropertySignature: return node.loc
	case TSMethodSignature: return node.loc
	case TSCallSignatureDeclaration: return node.loc
	case TSConstructSignatureDeclaration: return node.loc
	case TSIndexSignature: return node.loc
	}
	return {}
}

// The members of an object type or an interface body, each with its
// terminator. Members of an object type share a line when they fit, and the
// last one then has no terminator. Returns nil for an empty list, or the
// comments that dangle in one.
@(private = "file")
format_signatures :: proc(
	f: ^FormatContext,
	members: []^TSSignature,
	loc: Loc,
	in_literal: bool,
) -> Doc {
	count := len(members)
	starts := make([]u32, count, f.alloc)
	ends := make([]u32, count, f.alloc)
	for member, index in members {
		if member == nil {return format_fail(f)}
		member_loc := format_signature_loc(member)
		starts[index], ends[index] = member_loc.start, member_loc.end
	}
	bounds := FormatListBounds{open = loc.start + 1, close = loc.end - 1}
	comments, dangling := format_list_comments(f, bounds, starts, ends)
	if count == 0 {return dangling}
	parts := make([dynamic]Doc, f.alloc)
	for member, index in members {
		is_last := index == count - 1
		terminator := ft(f, ";")
		if in_literal && is_last {terminator = doc_if_break(f, ft(f, ";"))}
		printed := format_signature(f, member, terminator)
		append(&parts, format_with_comments(f, comments[index], printed))
		if is_last {break}
		append(&parts, doc_line() if in_literal else doc_hardline())
		if format_is_next_line_empty(f.source, ends[index]) {append(&parts, doc_hardline())}
	}
	return fc(f, ..parts[:])
}

// `{ a: A; b(): B }`. Written with its first member on a later line than
// the brace, it stays expanded.
format_type_literal :: proc(f: ^FormatContext, node: ^TSTypeLiteral) -> Doc {
	if !format_is_delimited(f, node.loc, '{', '}') {return format_fail(f)}
	count := len(node.members)
	members := format_signatures(f, node.members[:], node.loc, true)
	if members == nil {return ft(f, "{}")}
	space := doc_line() if f.options.bracket_spacing else doc_softline()
	contents := fc(f, ft(f, "{"), fi(f, space, members), space, ft(f, "}"))
	if f.hug_type == rawptr(node) {return contents}
	should_break := count == 0
	if count > 0 {
		first := format_signature_loc(node.members[0]).start
		should_break = format_has_newline_in_range(f.source, node.loc.start, first)
	}
	return doc_group(f, contents, should_break)
}

// The braces of an interface: one member per line, always.
format_interface_body :: proc(f: ^FormatContext, body: ^TSInterfaceBody) -> Doc {
	if !format_is_delimited(f, body.loc, '{', '}') {return format_fail(f)}
	if !format_path_push(f, {kind = .TS_Interface_Body, key = .Body, node = body}) {return nil}
	defer format_path_pop(f)
	members := format_signatures(f, body.body[:], body.loc, false)
	if members == nil {return ft(f, "{}")}
	return fc(f, ft(f, "{"), fi(f, doc_hardline(), members), doc_hardline(), ft(f, "}"))
}

@(private = "file")
format_signature :: proc(f: ^FormatContext, signature: ^TSSignature, terminator: Doc) -> Doc {
	if !format_path_push(f, {kind = .TS_Signature, key = .Members, node = signature}) {return nil}
	defer format_path_pop(f)
	switch &node in signature^ {
	case TSPropertySignature:
		return fc(
			f,
			ft(f, "readonly ") if node.readonly else nil,
			format_property_key(f, node.key, node.computed),
			ft(f, "?") if node.optional else nil,
			format_type_annotation(f, node.type_annotation),
			terminator,
		)
	case TSMethodSignature:
		prefix: Doc
		#partial switch node.kind {
		case .Get: prefix = ft(f, "get ")
		case .Set: prefix = ft(f, "set ")
		}
		head := fc(
			f,
			prefix,
			format_property_key(f, node.key, node.computed),
			ft(f, "?") if node.optional else nil,
		)
		rest := format_signature_tail(f, node.type_parameters, node.params[:], node.return_type)
		return fc(f, fg(f, head, rest), terminator)
	case TSCallSignatureDeclaration:
		rest := format_signature_tail(f, node.type_parameters, node.params[:], node.return_type)
		return fc(f, fg(f, rest), terminator)
	case TSConstructSignatureDeclaration:
		rest := format_signature_tail(f, node.type_parameters, node.params[:], node.return_type)
		return fc(f, fg(f, ft(f, "new "), rest), terminator)
	case TSIndexSignature:
		return fc(f, format_index_signature(f, &node), terminator)
	}
	return format_fail(f)
}

// The parameters and return type of a method, call or construct signature.
@(private = "file")
format_signature_tail :: proc(
	f: ^FormatContext,
	type_parameters: Maybe(^TSTypeParameterDeclaration),
	params: []TSFunctionParam,
	return_type: Maybe(^TSTypeAnnotation),
) -> Doc {
	generics := format_type_parameters(f, type_parameters)
	parameters := format_signature_params(f, params, generics)
	returned := format_return_type(f, return_type)
	returned_type := format_annotation_type(return_type)
	if format_should_group_params(type_parameters, len(params), returned_type, returned) {
		parameters = doc_group(f, parameters)
	}
	if returned == nil {return parameters}
	return fc(f, parameters, doc_group(f, returned))
}

// `[key: string]: Value`, in an object type, an interface or a class.
format_index_signature :: proc(f: ^FormatContext, node: ^TSIndexSignature) -> Doc {
	count := len(node.parameters)
	printed := make([]Doc, count, f.alloc)
	for &param, index in node.parameters {printed[index] = format_signature_param(f, &param)}
	comma: Doc
	if count > 1 && f.options.trailing_comma {comma = doc_if_break(f, ft(f, ","))}
	separator := fc(f, ft(f, ", "), doc_softline())
	list := fi(f, doc_softline(), doc_join(f, separator, printed))
	return fc(
		f,
		ft(f, "static ") if node.static_ else nil,
		ft(f, "readonly ") if node.readonly else nil,
		ft(f, "["),
		fg(f, list, comma, doc_softline()),
		ft(f, "]"),
		format_type_annotation(f, node.type_annotation),
	)
}

@(private = "file")
format_mapped_modifier :: proc(modifier: TSMappedTypeModifier, text: string) -> string {
	switch modifier {
	case .None: return ""
	case .True: return text
	case .Plus: return text == "?" ? "+?" : "+readonly"
	case .Minus: return text == "?" ? "-?" : "-readonly"
	}
	return ""
}

// `{ readonly [K in Keys as Name]?: Value }`. Written with the key on a
// later line than the brace, it stays expanded.
format_mapped_type :: proc(f: ^FormatContext, node: ^TSMappedType) -> Doc {
	if !format_is_delimited(f, node.loc, '{', '}') {return format_fail(f)}
	constraint, constrained := node.type_parameter.constraint.?
	if !constrained {return format_fail(f)}
	parts := make([dynamic]Doc, f.alloc)
	readonly := format_mapped_modifier(node.readonly, "readonly")
	if readonly != "" {append(&parts, ft(f, readonly), ft(f, " "))}
	append(&parts, ft(f, "["), ft(f, node.type_parameter.name.name), ft(f, " in "))
	append(&parts, format_type(f, constraint, .Constraint))
	if name_type, renamed := node.name_type.?; renamed {
		append(&parts, ft(f, " as "), format_type(f, name_type, .Name_Type))
	}
	append(&parts, ft(f, "]"), ft(f, format_mapped_modifier(node.optional, "?")))
	if value, typed := node.type_annotation.?; typed {
		append(&parts, ft(f, ": "), format_type(f, value, .Type_Annotation))
	}
	first := u32(format_next_code_index(f.source, node.loc.start + 1))
	should_break := format_has_newline_in_range(f.source, node.loc.start, first)
	space := doc_line() if f.options.bracket_spacing else doc_softline()
	body := fi(f, space, fg(f, ..parts[:]), doc_if_break(f, ft(f, ";")))
	return doc_group(f, fc(f, ft(f, "{"), body, space, ft(f, "}")), should_break)
}
