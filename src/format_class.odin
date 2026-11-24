package kessel

// Class declarations, class expressions and their members. Ports of
// Prettier's class and class-members rules for the JavaScript subset.
// TypeScript modifiers and decorators are not printed yet.

format_class :: proc(f: ^FormatContext, node: ^ClassExpression) -> Doc {
	if node.declare || node.abstract || len(node.decorators) > 0 {return format_fail(f)}
	if len(node.implements) > 0 {return format_fail(f)}
	if _, typed := node.type_parameters.?; typed {return format_fail(f)}
	if _, typed := node.super_type_arguments.?; typed {return format_fail(f)}
	parent_is_assignment := format_parent(f).kind == .Assignment
	name: Doc
	if id, named := node.id.?; named {name = fc(f, ft(f, " "), ft(f, id.name))}
	body := format_class_body(f, &node.body)
	super_class, has_super := node.super_class.?
	if !has_super || super_class == nil {return fc(f, ft(f, "class"), name, ft(f, " "), body)}

	printed_super := format_expr(f, super_class, .Super_Class)
	if parent_is_assignment {
		inner := fi(f, doc_softline(), printed_super)
		wrapped := fc(f, ft(f, "("), inner, doc_softline(), ft(f, ")"))
		printed_super = fg(f, doc_if_break(f, wrapped, printed_super))
	}
	heritage := fc(f, ft(f, "extends "), printed_super)
	// A dotted superclass may move to its own line, and the body's brace
	// then starts a line too.
	if !parent_is_assignment && format_is_member(super_class) {
		id := doc_group_id(f)
		head := doc_group(f, fc(f, name, fi(f, doc_line(), fg(f, heritage))), false, id)
		separator := ft(f, " ")
		if len(node.body.body) > 0 {separator = doc_if_break(f, doc_hardline(), ft(f, " "), id)}
		return fc(f, ft(f, "class"), head, separator, body)
	}
	return fc(f, ft(f, "class"), name, ft(f, " "), heritage, ft(f, " "), body)
}

@(private = "file")
format_class_body :: proc(f: ^FormatContext, body: ^ClassBody) -> Doc {
	if !format_is_delimited(f, body.loc, '{', '}') {return format_fail(f)}
	count := len(body.body)
	starts := make([]u32, count, f.alloc)
	ends := make([]u32, count, f.alloc)
	for element, index in body.body {
		starts[index], ends[index] = element.loc.start, element.loc.end
	}
	bounds := FormatListBounds{open = body.loc.start + 1, close = body.loc.end - 1}
	comments, dangling := format_list_comments(f, bounds, starts, ends)
	if count == 0 {
		if dangling == nil {return ft(f, "{}")}
		return fc(f, ft(f, "{"), fi(f, doc_hardline(), dangling), doc_hardline(), ft(f, "}"))
	}
	parts := make([dynamic]Doc, f.alloc)
	for &element, index in body.body {
		append(&parts, format_with_comments(f, comments[index], format_class_element(f, &element)))
		if index == count - 1 {break}
		append(&parts, doc_hardline())
		if format_is_next_line_empty(f.source, element.loc.end) {append(&parts, doc_hardline())}
	}
	return fc(f, ft(f, "{"), fi(f, doc_hardline(), fc(f, ..parts[:])), doc_hardline(), ft(f, "}"))
}

@(private = "file")
format_class_element :: proc(f: ^FormatContext, element: ^ClassElement) -> Doc {
	if len(element.decorators) > 0 || element.abstract || element.optional {return format_fail(f)}
	if element.definite || element.readonly || element.override_ || element.declare {
		return format_fail(f)
	}
	if element.accessibility != .None {return format_fail(f)}
	static := ft(f, "static ") if element.static else nil
	value, has_value := element.value.?
	switch element.kind {
	case .IndexSignature:
		return format_fail(f)
	case .StaticBlock:
		if !has_value || value == nil {return ft(f, "static {}")}
		function, is_function := value^.(^FunctionExpression)
		if !is_function {return format_fail(f)}
		if !format_path_push(f, {kind = .Class_Method, key = .Body}) {return nil}
		defer format_path_pop(f)
		return fc(f, ft(f, "static "), format_function_body(f, &function.body))
	case .Field:
		if _, typed := element.typing.annotation.?; typed {return format_fail(f)}
		if !format_path_push(f, {kind = .Class_Property, key = .Body, node = element}) {return nil}
		defer format_path_pop(f)
		left := fc(
			f,
			static,
			ft(f, "accessor ") if element.is_accessor else nil,
			format_property_key(f, element.key, element.computed),
		)
		right := value if has_value else nil
		assignment := FormatAssignment{kind = .Class_Property, left = left, right = right}
		return fc(f, format_assignment_like(f, assignment), ft(f, ";"))
	case .Method, .Constructor, .Get, .Set:
		if !has_value || value == nil {return format_fail(f)}
		function, is_function := value^.(^FunctionExpression)
		if !is_function {return format_fail(f)}
		if !format_path_push(f, {kind = .Class_Method, key = .Body, node = element}) {return nil}
		defer format_path_pop(f)
		prefix: Doc
		#partial switch element.kind {
		case .Get: prefix = ft(f, "get ")
		case .Set: prefix = ft(f, "set ")
		case:
			if function.async {prefix = ft(f, "async ")}
		}
		return fc(
			f,
			static,
			prefix,
			ft(f, "*") if function.generator else nil,
			format_property_key(f, element.key, element.computed),
			format_method_value(f, function),
		)
	}
	return format_fail(f)
}
