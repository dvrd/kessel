package kessel

import "core:strings"

// Class declarations, class expressions and their members. Ports of
// Prettier's class and class-members rules, with TypeScript's modifiers,
// heritage clauses, index signatures and bodiless members. Decorators are
// not printed yet.

// Where an abstract class starts, `abstract` included. The parser starts
// the class at `class` unless `declare` comes first. The second result is
// false when the keyword is not directly in front, and the printed class
// would then repeat it.
format_class_abstract_start :: proc(source: string, start: u32) -> (u32, bool) {
	KEYWORD :: "abstract"
	rest := source[start:]
	if strings.has_prefix(rest, KEYWORD) || strings.has_prefix(rest, "declare") {return start, true}
	index := int(start)
	for index > 0 && (source[index - 1] == ' ' || source[index - 1] == '\t') {index -= 1}
	if index < len(KEYWORD) || source[index - len(KEYWORD):index] != KEYWORD {return start, false}
	return u32(index - len(KEYWORD)), true
}

// A decorator that Prettier prints without parentheses: a name, a dotted
// name, or a call of one.
@(private = "file")
format_decorator_is_simple :: proc(expr: ^Expression) -> bool {
	node := format_expr_unwrap(expr)
	if node == nil {return false}
	if call, is_call := node^.(^CallExpression); is_call {
		if call.optional {return false}
		node = format_expr_unwrap(call.callee)
		// Prettier formats the templates and styles of an Angular component
		// as HTML and CSS, which is not ported.
		if name, named := node^.(^Identifier); named && name.name == "Component" {return false}
	}
	for _ in 0 ..< FORMAT_DEPTH_MAX {
		if node == nil {return false}
		#partial switch inner in node^ {
		case ^Identifier:
			return true
		case ^MemberExpression:
			if inner.computed || inner.optional || inner.property == nil {return false}
			if _, named := inner.property^.(^Identifier); !named {return false}
			node = format_expr_unwrap(inner.object)
		case:
			return false
		}
	}
	return false
}

// The decorators in front of a class, a member or a parameter, separated by
// lines that the caller's group breaks or keeps. The second result is true
// when one of them ends its line in the source, which keeps them all on
// lines of their own.
format_decorators :: proc(
	f: ^FormatContext,
	decorators: []Decorator,
) -> (
	list: Doc,
	own_line: bool,
) {
	if len(decorators) == 0 {return nil, false}
	printed := make([]Doc, len(decorators), f.alloc)
	for decorator, index in decorators {
		if !format_decorator_is_simple(decorator.expression) {return format_fail(f), false}
		if !format_path_push(f, {kind = .Decorator, key = .Expression}) {return nil, false}
		printed[index] = fc(f, ft(f, "@"), format_expr(f, decorator.expression, .Expression))
		format_path_pop(f)
		own_line = own_line || format_has_newline_after(f.source, int(decorator.loc.end))
	}
	return doc_join(f, doc_line(), printed), own_line
}

format_class :: proc(f: ^FormatContext, node: ^ClassExpression) -> Doc {
	if len(node.decorators) == 0 {return format_class_undecorated(f, node)}
	// Decorators in front of `export` lie outside the statement, and those of
	// a class expression take parentheses under rules that are not ported.
	current := format_path_at(f, 0)
	if current.kind != .Class_Declaration || current.key == .Declaration {return format_fail(f)}
	if node.decorators[0].loc.start < node.loc.start {return format_fail(f)}
	decorators, _ := format_decorators(f, node.decorators[:])
	class := format_class_undecorated(f, node)
	return fg(f, doc_break_parent(), decorators, doc_line(), class)
}

@(private = "file")
format_class_undecorated :: proc(f: ^FormatContext, node: ^ClassExpression) -> Doc {
	if node.abstract {
		if _, found := format_class_abstract_start(f.source, node.loc.start); !found {
			return format_fail(f)
		}
	}
	parent_is_assignment := format_parent(f).kind == .Assignment
	name: Doc
	if id, named := node.id.?; named {name = fc(f, ft(f, " "), ft(f, id.name))}
	name = fc(f, name, format_type_parameters(f, node.type_parameters))
	super_class, has_super := node.super_class.?
	has_super = has_super && super_class != nil
	multiple := len(node.implements) + (1 if has_super else 0) > 1
	// A lone dotted supertype may move to its own line, and so may the
	// clauses of a class that has several supertypes.
	indent_only := multiple
	if !multiple && has_super {
		_, generic := node.super_type_arguments.?
		indent_only = !parent_is_assignment && !generic && format_is_member(super_class)
	} else if !multiple {
		indent_only = format_heritage_is_member(node.implements[:])
	}
	heritage: Doc
	if has_super {
		clause := fc(f, ft(f, "extends "), format_super_class(f, node, parent_is_assignment))
		if indent_only {
			heritage = fc(f, doc_line(), doc_group(f, clause))
		} else {
			heritage = fc(f, ft(f, " "), clause)
		}
	}
	implements := node.implements[:]
	heritage = fc(
		f,
		heritage,
		format_heritage_clause(f, "implements", implements, multiple, indent_only),
	)
	body := format_class_body(f, &node.body)
	keyword := fc(
		f,
		ft(f, "declare ") if node.declare else nil,
		ft(f, "abstract ") if node.abstract else nil,
		ft(f, "class"),
	)
	if !indent_only {return fc(f, keyword, name, heritage, ft(f, " "), body)}
	// When the head breaks, the body's brace starts a line too.
	id := doc_group_id(f)
	head := doc_group(f, fc(f, name, doc_indent(f, heritage)), false, id)
	separator := ft(f, " ")
	if len(node.body.body) > 0 {separator = doc_if_break(f, doc_hardline(), ft(f, " "), id)}
	return fc(f, keyword, head, separator, body)
}

// The superclass with its type arguments. As the value of an assignment it
// takes parentheses when it breaks.
@(private = "file")
format_super_class :: proc(
	f: ^FormatContext,
	node: ^ClassExpression,
	parent_is_assignment: bool,
) -> Doc {
	super_class := node.super_class.?
	printed := format_expr(f, super_class, .Super_Class)
	if parent_is_assignment {
		inner := fi(f, doc_softline(), printed)
		wrapped := fc(f, ft(f, "("), inner, doc_softline(), ft(f, ")"))
		printed = fg(f, doc_if_break(f, wrapped, printed))
	}
	return fc(f, printed, format_type_arguments(f, node.super_type_arguments))
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

// The modifiers in front of a member's name, in Prettier's order.
@(private = "file")
format_class_modifiers :: proc(f: ^FormatContext, element: ^ClassElement, field: bool) -> Doc {
	accessibility: Doc
	switch element.accessibility {
	case .None:
	case .Public: accessibility = ft(f, "public ")
	case .Private: accessibility = ft(f, "private ")
	case .Protected: accessibility = ft(f, "protected ")
	}
	return fc(
		f,
		ft(f, "declare ") if element.declare && field else nil,
		accessibility,
		ft(f, "static ") if element.static else nil,
		ft(f, "abstract ") if element.abstract else nil,
		ft(f, "override ") if element.override_ else nil,
		ft(f, "readonly ") if element.readonly && field else nil,
	)
}

// The name of a field. Prettier's TypeScript parsers keep the quotes of a
// field's name even where a method's would go.
@(private = "file")
format_class_field_key :: proc(f: ^FormatContext, element: ^ClassElement) -> Doc {
	if element.key == nil {return format_fail(f)}
	if f.typescript && !element.computed {
		if literal, quoted := element.key^.(^StringLiteral); quoted {
			return format_string_literal(f, literal)
		}
	}
	return format_property_key(f, element.key, element.computed)
}

@(private = "file")
format_class_element :: proc(f: ^FormatContext, element: ^ClassElement) -> Doc {
	if len(element.decorators) == 0 {return format_class_member(f, element)}
	#partial switch element.kind {
	case .IndexSignature, .StaticBlock: return format_fail(f)
	}
	decorators, own_line := format_decorators(f, element.decorators[:])
	separator := doc_hardline() if own_line else doc_line()
	return fc(f, fg(f, decorators, separator), format_class_member(f, element))
}

@(private = "file")
format_class_member :: proc(f: ^FormatContext, element: ^ClassElement) -> Doc {
	value, has_value := element.value.?
	switch element.kind {
	case .IndexSignature:
		signature := element.typing.index_signature
		if signature == nil {return format_fail(f)}
		index, is_index := &signature^.(TSIndexSignature)
		if !is_index || element.static != index.static_ {return format_fail(f)}
		return fc(f, format_index_signature(f, index), ft(f, ";"))
	case .StaticBlock:
		if !has_value || value == nil {return ft(f, "static {}")}
		function, is_function := value^.(^FunctionExpression)
		if !is_function {return format_fail(f)}
		if !format_path_push(f, {kind = .Class_Method, key = .Body}) {return nil}
		defer format_path_pop(f)
		return fc(f, ft(f, "static "), format_function_body(f, &function.body))
	case .Field:
		return format_class_field(f, element)
	case .Method, .Constructor, .Get, .Set:
		// Only fields are declared ambient or read-only.
		if element.declare || element.readonly || element.definite {return format_fail(f)}
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
			format_class_modifiers(f, element, false),
			prefix,
			ft(f, "*") if function.generator else nil,
			format_property_key(f, element.key, element.computed),
			ft(f, "?") if element.optional else nil,
			format_method_value(f, function),
		)
	}
	return format_fail(f)
}

@(private = "file")
format_class_field :: proc(f: ^FormatContext, element: ^ClassElement) -> Doc {
	if !format_path_push(f, {kind = .Class_Property, key = .Body, node = element}) {return nil}
	defer format_path_pop(f)
	left := fc(
		f,
		format_class_modifiers(f, element, true),
		ft(f, "accessor ") if element.is_accessor else nil,
		format_class_field_key(f, element),
		ft(f, "?") if element.optional else nil,
		ft(f, "!") if element.definite else nil,
		format_type_annotation(f, element.typing.annotation),
	)
	value, has_value := element.value.?
	right := value if has_value else nil
	assignment := FormatAssignment{kind = .Class_Property, left = left, right = right}
	return fc(f, format_assignment_like(f, assignment), ft(f, ";"))
}
