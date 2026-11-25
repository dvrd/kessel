package kessel

import "core:strings"

// TypeScript types. Ports of Prettier's type-annotation, union,
// intersection, tuple, conditional and type-parameter rules. Object types
// and function types live in format_ts_members.odin.

// The parser keeps parentheses around a type as a node. Prettier's
// reference AST never has them, so every rule looks through them and the
// printer adds back the ones the grammar needs.
format_type_unwrap :: proc(type: ^TSType) -> ^TSType {
	inner := type
	for inner != nil {
		parenthesized, wrapped := inner^.(^TSParenthesizedType)
		if !wrapped {break}
		inner = parenthesized.type_annotation
	}
	return inner
}

@(private = "file")
format_type_kind :: proc(type: ^TSType) -> FormatNodeKind {
	switch _ in type^ {
	case ^TSKeywordType: return .TS_Keyword
	case ^TSTypeReference: return .TS_Reference
	case ^TSUnionType: return .TS_Union
	case ^TSIntersectionType: return .TS_Intersection
	case ^TSArrayType: return .TS_Array
	case ^TSTupleType: return .TS_Tuple
	case ^TSFunctionType: return .TS_Function_Type
	case ^TSConstructorType: return .TS_Constructor_Type
	case ^TSTypeLiteral: return .TS_Type_Literal
	case ^TSConditionalType: return .TS_Conditional
	case ^TSInferType: return .TS_Infer
	case ^TSTypeQuery: return .TS_Type_Query
	case ^TSIndexedAccessType: return .TS_Indexed_Access
	case ^TSMappedType: return .TS_Mapped
	case ^TSTypeOperator: return .TS_Type_Operator
	case ^TSLiteralType: return .TS_Literal_Type
	case ^TSTemplateLiteralType: return .TS_Template_Type
	case ^TSParenthesizedType: return .Other
	case ^TSRestType: return .TS_Rest_Type
	case ^TSOptionalType: return .TS_Optional_Type
	case ^TSNamedTupleMember: return .TS_Named_Member
	case ^TSTypePredicate: return .TS_Predicate
	case ^TSImportType: return .TS_Import_Type
	}
	return .Other
}

// `{…}` and mapped types: the types whose braces Prettier keeps on the line
// of whatever introduces them.
format_type_is_object :: proc(type: ^TSType) -> bool {
	inner := format_type_unwrap(type)
	if inner == nil {return false}
	#partial switch _ in inner^ {
	case ^TSTypeLiteral, ^TSMappedType: return true
	}
	return false
}

// A keyword, `this`, a literal, or a name without type arguments.
@(private = "file")
format_type_is_simple :: proc(type: ^TSType) -> bool {
	inner := format_type_unwrap(type)
	if inner == nil {return false}
	#partial switch node in inner^ {
	case ^TSKeywordType, ^TSLiteralType, ^TSTemplateLiteralType:
		return true
	case ^TSTypeReference:
		_, has_arguments := node.type_parameters.?
		return !has_arguments
	}
	return false
}

// `Name | null`, `{…} | void`: one object-like member and otherwise only
// `null` and `void`. Such a union stays on one line and lets the object
// break instead.
@(private = "file")
format_union_should_hug :: proc(node: ^TSUnionType) -> bool {
	object_like: ^TSType
	for type in node.types {
		inner := format_type_unwrap(type)
		if inner == nil {return false}
		#partial switch _ in inner^ {
		case ^TSTypeLiteral, ^TSTypeReference:
			if object_like == nil {object_like = inner}
		}
	}
	if object_like == nil {return false}
	for type in node.types {
		inner := format_type_unwrap(type)
		if inner == object_like {continue}
		keyword, is_keyword := inner^.(^TSKeywordType)
		if !is_keyword {return false}
		if keyword.kind != .Void && keyword.kind != .Null {return false}
	}
	return true
}

@(private = "file")
format_type_should_hug :: proc(type: ^TSType) -> bool {
	if format_type_is_simple(type) || format_type_is_object(type) {return true}
	inner := format_type_unwrap(type)
	if inner == nil {return false}
	union_type, is_union := inner^.(^TSUnionType)
	return is_union && format_union_should_hug(union_type)
}

format_type :: proc(f: ^FormatContext, type: ^TSType, key: FormatKey) -> Doc {
	inner := format_type_unwrap(type)
	if inner == nil {return format_fail(f)}
	entry := FormatPathEntry {
		kind = format_type_kind(inner),
		key  = key,
		type = inner,
	}
	if !format_path_push(f, entry) {return nil}
	defer format_path_pop(f)
	doc := format_type_inner(f, inner)
	if format_type_needs_parens(f) {return fc(f, ft(f, "("), doc, ft(f, ")"))}
	return doc
}

// Whether the type on top of the path needs parentheses in its parent.
// Prettier's switch falls through from each case to the next, so the checks
// accumulate in that order.
@(private = "file")
format_type_needs_parens :: proc(f: ^FormatContext) -> bool {
	current := format_path_at(f, 0)
	parent := format_parent(f)
	kind := current.kind
	stage := 0
	#partial switch kind {
	case .TS_Function_Type: stage = 1
	case .TS_Conditional, .TS_Constructor_Type: stage = 2
	case .TS_Union, .TS_Intersection: stage = 3
	case .TS_Infer: stage = 4
	case .TS_Type_Operator: stage = 5
	case .TS_Type_Query:
		if current.key == .Object_Type && parent.kind == .TS_Indexed_Access {return true}
		return current.key == .Element_Type && parent.kind == .TS_Array
	case:
		return false
	}
	if stage == 1 {
		// The return type of an arrow function would swallow the arrow.
		if parent.kind == .TS_Annotation && parent.key == .Return_Type {
			if format_path_at(f, 2).kind == .Arrow_Function {return true}
		}
	}
	if stage <= 2 {
		if current.key == .Extends_Type && parent.kind == .TS_Conditional {
			if kind == .TS_Conditional {return true}
			if format_returns_constrained_infer(current.type) {return true}
		}
		if current.key == .Check_Type && parent.kind == .TS_Conditional {return true}
	}
	if stage <= 3 {
		if parent.kind == .TS_Union || parent.kind == .TS_Intersection {return true}
	}
	if stage <= 4 && kind == .TS_Infer {
		if parent.kind == .TS_Rest_Type {return false}
		infer := current.type^.(^TSInferType)
		_, constrained := infer.type_parameter.constraint.?
		if constrained && current.key == .Types {
			if parent.kind == .TS_Union || parent.kind == .TS_Intersection {return true}
		}
	}
	#partial switch parent.kind {
	case .TS_Array, .TS_Optional_Type, .TS_Rest_Type, .TS_Type_Operator: return true
	case .TS_Indexed_Access: return current.key == .Object_Type
	}
	return false
}

// A function type whose return type is `infer U extends X`. As the
// `extends` operand of a conditional type it would read as the conditional's
// own constraint.
@(private = "file")
format_returns_constrained_infer :: proc(type: ^TSType) -> bool {
	annotation: ^TSTypeAnnotation
	#partial switch node in type^ {
	case ^TSFunctionType: annotation = node.return_type
	case ^TSConstructorType: annotation = node.return_type
	}
	if annotation == nil {return false}
	returned := format_type_unwrap(annotation.type_annotation)
	if returned == nil {return false}
	if predicate, is_predicate := returned^.(^TSTypePredicate); is_predicate {
		asserted, present := predicate.type_annotation.?
		if !present || asserted == nil {return false}
		returned = format_type_unwrap(asserted.type_annotation)
		if returned == nil {return false}
	}
	infer, is_infer := returned^.(^TSInferType)
	if !is_infer {return false}
	_, constrained := infer.type_parameter.constraint.?
	return constrained
}

@(private = "file")
format_type_inner :: proc(f: ^FormatContext, type: ^TSType) -> Doc {
	switch node in type^ {
	case ^TSKeywordType:
		return ft(f, TS_KEYWORD_SOURCE[node.kind])
	case ^TSTypeReference:
		name := format_type_name(f, node.type_name)
		return fc(f, name, format_type_arguments(f, node.type_parameters))
	case ^TSUnionType:
		return format_union_type(f, node)
	case ^TSIntersectionType:
		return format_intersection_type(f, node)
	case ^TSArrayType:
		return fc(f, format_type(f, node.element_type, .Element_Type), ft(f, "[]"))
	case ^TSTupleType:
		return format_tuple_type(f, node)
	case ^TSFunctionType:
		return format_function_type(f, node.type_parameters, node.params[:], node.return_type, "")
	case ^TSConstructorType:
		prefix := "abstract new " if node.abstract_ else "new "
		return format_function_type(
			f,
			node.type_parameters,
			node.params[:],
			node.return_type,
			prefix,
		)
	case ^TSTypeLiteral:
		return format_type_literal(f, node)
	case ^TSConditionalType:
		return format_conditional_type(f, node)
	case ^TSInferType:
		return fc(f, ft(f, "infer "), format_type_parameter(f, &node.type_parameter))
	case ^TSTypeQuery:
		return format_type_query(f, node)
	case ^TSIndexedAccessType:
		object := format_type(f, node.object_type, .Object_Type)
		index := format_type(f, node.index_type, .Index_Type)
		return fc(f, object, ft(f, "["), index, ft(f, "]"))
	case ^TSMappedType:
		return format_mapped_type(f, node)
	case ^TSTypeOperator:
		operand := format_type(f, node.type_annotation, .Type_Annotation)
		return fc(f, ft(f, node.operator), ft(f, " "), operand)
	case ^TSLiteralType:
		return format_expr(f, node.literal, .Expression)
	case ^TSTemplateLiteralType:
		return format_template_type(f, node)
	case ^TSParenthesizedType:
		return format_fail(f)
	case ^TSRestType:
		return fc(f, ft(f, "..."), format_type(f, node.type_annotation, .Type_Annotation))
	case ^TSOptionalType:
		return fc(f, format_type(f, node.type_annotation, .Type_Annotation), ft(f, "?"))
	case ^TSNamedTupleMember:
		return format_named_tuple_member(f, node)
	case ^TSTypePredicate:
		return format_type_predicate(f, node)
	case ^TSImportType:
		return format_import_type(f, node)
	}
	return format_fail(f)
}

// `typeof name<Args>`. TypeScript does not read `<…>` on a new line as
// the type arguments of `typeof x`, and the parser does, so such a type
// keeps its lines.
@(private = "file")
format_type_query :: proc(f: ^FormatContext, node: ^TSTypeQuery) -> Doc {
	if arguments, generic := node.type_parameters.?; generic && arguments != nil {
		name_end := get_expression_loc(node.expr_name).end
		if format_has_newline_in_range(f.source, name_end, arguments.loc.start) {
			return format_fail(f)
		}
	}
	name := format_type_name(f, node.expr_name)
	return fc(f, ft(f, "typeof "), name, format_type_arguments(f, node.type_parameters))
}

// `label?: Type` in a tuple. The parser stores `...label: Type` as a label
// whose type is a rest type that starts before the label.
@(private = "file")
format_named_tuple_member :: proc(f: ^FormatContext, node: ^TSNamedTupleMember) -> Doc {
	label := fc(f, ft(f, node.label.name), ft(f, "?") if node.optional else nil, ft(f, ": "))
	if node.element_type == nil {return format_fail(f)}
	rest, is_rest := node.element_type^.(^TSRestType)
	if is_rest && rest.loc.start < node.label.loc.start {
		return fc(f, ft(f, "..."), label, format_type(f, rest.type_annotation, .Element_Type))
	}
	return fc(f, label, format_type(f, node.element_type, .Element_Type))
}

// `a`, `a.b.c` or `this.a`: the names that types, heritage clauses and
// import aliases refer to. The parser stores a qualified name as a member
// access, and anything else in that position is not a name.
format_type_name :: proc(f: ^FormatContext, expr: ^Expression) -> Doc {
	names := make([dynamic]string, f.alloc)
	node := format_expr_unwrap(expr)
	complete := false
	for _ in 0 ..< FORMAT_DEPTH_MAX {
		if node == nil {return format_fail(f)}
		#partial switch inner in node^ {
		case ^Identifier:
			if inner.has_escape {return format_fail(f)}
			append(&names, inner.name)
			complete = true
		case ^ThisExpression:
			append(&names, "this")
			complete = true
		case ^MemberExpression:
			if inner.computed || inner.optional || inner.property == nil {return format_fail(f)}
			property, named := inner.property^.(^Identifier)
			if !named || property.has_escape {return format_fail(f)}
			append(&names, property.name)
			node = inner.object
		case:
			return format_fail(f)
		}
		if complete {break}
	}
	if !complete {return format_fail(f)}
	out := strings.builder_make(f.alloc)
	for index := len(names) - 1; index >= 0; index -= 1 {
		strings.write_string(&out, names[index])
		if index > 0 {strings.write_byte(&out, '.')}
	}
	return ft(f, strings.to_string(out))
}

// `<A, B>` after a name, a callee or a tag. A lone simple or object-like
// argument never breaks away from its angle brackets.
format_type_arguments :: proc(
	f: ^FormatContext,
	arguments: Maybe(^TSTypeParameterInstantiation),
) -> Doc {
	node, present := arguments.?
	if !present || node == nil {return nil}
	entry := FormatPathEntry {
		kind = .TS_Type_Arguments,
		key  = .Type_Arguments,
		node = node,
	}
	if !format_path_push(f, entry) {return nil}
	defer format_path_pop(f)
	count := len(node.params)
	if count == 0 {return ft(f, "<>")}
	printed := make([]Doc, count, f.alloc)
	for param, index in node.params {printed[index] = format_type(f, param, .Types)}
	if format_type_arguments_stay_inline(f, node) {
		return fc(f, ft(f, "<"), doc_join(f, ft(f, ", "), printed), ft(f, ">"))
	}
	separator := fc(f, ft(f, ","), doc_line())
	list := fi(f, doc_softline(), doc_join(f, separator, printed))
	return fg(f, ft(f, "<"), list, doc_softline(), ft(f, ">"))
}

@(private = "file")
format_type_arguments_stay_inline :: proc(
	f: ^FormatContext,
	node: ^TSTypeParameterInstantiation,
) -> bool {
	lone_object := len(node.params) == 1 && format_type_is_object(node.params[0])
	// `const f: Handler<A, B> = () => …` breaks its arguments rather than
	// the arrow function's signature.
	annotation := format_path_at(f, 2)
	owner := format_path_at(f, 3)
	if !lone_object && annotation.kind == .TS_Annotation && annotation.key == .Type_Annotation {
		if owner.kind == .Variable_Declarator && owner.node != nil {
			declarator := cast(^VariableDeclarator)owner.node
			_, plain := declarator.id.(^Identifier)
			if plain && format_declarator_holds_arrow(declarator) {return false}
		}
	}
	grandparent := format_path_at(f, 2)
	if grandparent.kind == .Call && grandparent.expr != nil {
		if format_is_test_call(f, grandparent.expr, nil) {return true}
	}
	return len(node.params) == 1 && format_type_should_hug(node.params[0])
}

format_declarator_holds_arrow :: proc(declarator: ^VariableDeclarator) -> bool {
	init, present := declarator.init.?
	if !present {return false}
	value := format_expr_unwrap(init)
	if value == nil {return false}
	_, arrow := value^.(^ArrowFunctionExpression)
	return arrow
}

// `<T, U extends V = W>` on a declaration.
format_type_parameters :: proc(
	f: ^FormatContext,
	parameters: Maybe(^TSTypeParameterDeclaration),
) -> Doc {
	node, present := parameters.?
	if !present || node == nil {return nil}
	entry := FormatPathEntry {
		kind = .TS_Type_Parameters,
		key  = .Type_Parameters,
		node = node,
	}
	if !format_path_push(f, entry) {return nil}
	defer format_path_pop(f)
	count := len(node.params)
	if count == 0 {return format_fail(f)}
	printed := make([]Doc, count, f.alloc)
	for &param, index in node.params {printed[index] = format_type_parameter(f, &param)}
	grandparent := format_path_at(f, 2)
	if grandparent.kind == .Call && grandparent.expr != nil {
		if format_is_test_call(f, grandparent.expr, nil) {
			return fc(f, ft(f, "<"), doc_join(f, ft(f, ", "), printed), ft(f, ">"))
		}
	}
	separator := fc(f, ft(f, ","), doc_line())
	list := fi(f, doc_softline(), doc_join(f, separator, printed))
	comma: Doc
	if f.options.trailing_comma {comma = doc_if_break(f, ft(f, ","))}
	// Outside a `.ts` file `<T>(x) => …` could open a JSX element, so
	// Prettier writes the comma that rules that reading out.
	_, constrained := node.params[0].constraint.?
	if count == 1 && !constrained && !f.dot_ts && format_path_at(f, 1).kind == .Arrow_Function {
		comma = ft(f, ",")
	}
	return fg(f, ft(f, "<"), list, comma, doc_softline(), ft(f, ">"))
}

// One type parameter. Its constraint and its default each move to the next
// line as a whole before they break inside.
format_type_parameter :: proc(f: ^FormatContext, node: ^TSTypeParameter) -> Doc {
	if !format_path_push(f, {kind = .TS_Type_Parameter, key = .Type_Parameters, node = node}) {
		return nil
	}
	defer format_path_pop(f)
	parts := make([dynamic]Doc, f.alloc)
	if node.const_ {append(&parts, ft(f, "const "))}
	if node.in_ {append(&parts, ft(f, "in "))}
	if node.out {append(&parts, ft(f, "out "))}
	append(&parts, ft(f, node.name.name))
	if constraint, constrained := node.constraint.?; constrained {
		id := doc_group_id(f)
		append(&parts, ft(f, " extends"), doc_group(f, doc_indent(f, doc_line()), false, id))
		append(&parts, doc_line_suffix_boundary())
		append(&parts, doc_indent_if_break(f, format_type(f, constraint, .Constraint), id))
	}
	if default, defaulted := node.default_.?; defaulted {
		id := doc_group_id(f)
		append(&parts, ft(f, " ="), doc_group(f, doc_indent(f, doc_line()), false, id))
		append(&parts, doc_line_suffix_boundary())
		append(&parts, doc_indent_if_break(f, format_type(f, default, .Default), id))
	}
	return fg(f, ..parts[:])
}

@(private = "file")
format_union_type :: proc(f: ^FormatContext, node: ^TSUnionType) -> Doc {
	// A union of one type is a type written with a leading `|`.
	if len(node.types) < 2 {return format_fail(f)}
	parent := format_parent(f)
	should_indent := parent.kind != .TS_Type_Arguments && parent.kind != .TS_Tuple
	should_indent = should_indent && parent.kind != .TS_Type_Assertion
	should_hug := format_union_should_hug(node)
	printed := make([]Doc, len(node.types), f.alloc)
	for type, index in node.types {
		printed[index] = format_type(f, type, .Types)
		if !should_hug {printed[index] = doc_align(f, 2, printed[index])}
	}
	if should_hug {return doc_join(f, ft(f, " | "), printed)}
	leading := fc(f, doc_line() if should_indent else nil, ft(f, "| "))
	separator := fc(f, doc_line(), ft(f, "| "))
	code := fc(f, doc_if_break(f, leading), doc_join(f, separator, printed))
	if format_type_needs_parens(f) {return fg(f, fi(f, code), doc_softline())}
	grouped := doc_group(f, code)
	if parent.kind == .TS_Tuple {
		tuple := parent.type^.(^TSTupleType)
		if len(tuple.element_types) > 1 {
			open := doc_if_break(f, fc(f, ft(f, "("), doc_softline()))
			return fg(f, fi(f, open, grouped), doc_softline(), doc_if_break(f, ft(f, ")")))
		}
	}
	return doc_group(f, doc_indent(f, grouped) if should_indent else grouped)
}

// Object types join with ` & ` on one line. Between two other types the
// operator ends the line when the intersection breaks.
@(private = "file")
format_intersection_type :: proc(f: ^FormatContext, node: ^TSIntersectionType) -> Doc {
	if len(node.types) < 2 {return format_fail(f)}
	parts := make([dynamic]Doc, f.alloc)
	was_indented := false
	for type, index in node.types {
		printed := format_type(f, type, .Types)
		if index == 0 {
			append(&parts, printed)
			continue
		}
		current_is_object := format_type_is_object(type)
		previous_is_object := format_type_is_object(node.types[index - 1])
		if previous_is_object && current_is_object {
			append(&parts, ft(f, " & "), doc_indent(f, printed) if was_indented else printed)
		} else if !previous_is_object && !current_is_object {
			append(&parts, fi(f, ft(f, " &"), doc_line(), printed))
		} else {
			if index > 1 {was_indented = true}
			append(&parts, ft(f, " & "), doc_indent(f, printed) if index > 1 else printed)
		}
	}
	return fg(f, ..parts[:])
}

@(private = "file")
format_tuple_type :: proc(f: ^FormatContext, node: ^TSTupleType) -> Doc {
	if !format_is_delimited(f, node.loc, '[', ']') {return format_fail(f)}
	count := len(node.element_types)
	if count == 0 {return ft(f, "[]")}
	parts := make([dynamic]Doc, f.alloc)
	for element, index in node.element_types {
		append(&parts, doc_group(f, format_type(f, element, .Element_Type)))
		if index == count - 1 {break}
		append(&parts, ft(f, ","), doc_line())
		loc := get_ts_type_loc(element)
		if loc != nil && format_is_next_line_empty(f.source, loc.end) {
			append(&parts, doc_softline())
		}
	}
	comma: Doc
	if f.options.trailing_comma {comma = doc_if_break(f, ft(f, ","))}
	list := fi(f, doc_softline(), fc(f, ..parts[:]), comma)
	return fg(f, ft(f, "["), list, doc_softline(), ft(f, "]"))
}

// `Check extends Extends ? True : False`, laid out like a conditional
// expression: a chain of them in the false branch stays flat on the left.
@(private = "file")
format_conditional_type :: proc(f: ^FormatContext, node: ^TSConditionalType) -> Doc {
	current := format_path_at(f, 0)
	parent := format_parent(f)
	parent_is_conditional := parent.kind == .TS_Conditional
	is_parent_test := current.key == .Check_Type || current.key == .Extends_Type
	is_parent_test = is_parent_test && parent_is_conditional
	is_false := parent_is_conditional && current.key == .False_Type
	branch :: proc(f: ^FormatContext, type: ^TSType, key: FormatKey) -> Doc {
		printed := format_type(f, type, key)
		if f.options.use_tabs {return doc_indent(f, printed)}
		return doc_align(f, 2, printed)
	}
	true_type := format_type_unwrap(node.true_type)
	if true_type == nil {return format_fail(f)}
	_, nested := true_type^.(^TSConditionalType)
	part := fc(
		f,
		doc_line(),
		ft(f, "? "),
		doc_if_break(f, nil, ft(f, "(")) if nested else nil,
		branch(f, node.true_type, .True_Type),
		doc_if_break(f, nil, ft(f, ")")) if nested else nil,
		doc_line(),
		ft(f, ": "),
		branch(f, node.false_type, .False_Type),
	)
	if parent_is_conditional && !is_false && !is_parent_test {
		if f.options.use_tabs {
			part = doc_align(f, -1, doc_indent(f, part))
		} else {
			part = doc_align(f, max(0, f.options.tab_width - 2), part)
		}
	}
	test := fc(
		f,
		format_type(f, node.check_type, .Check_Type),
		ft(f, " extends "),
		format_type(f, node.extends_type, .Extends_Type),
	)
	if is_false {test = doc_align(f, 2, test)}
	force_no_indent := parent_is_conditional && !is_parent_test
	result := fc(f, test, part if force_no_indent else doc_indent(f, part))
	if !parent_is_conditional || is_parent_test {result = doc_group(f, result)}
	if is_parent_test {return fg(f, fi(f, doc_softline(), result), doc_softline())}
	return result
}

// A template literal type prints as written. Only placeholders that hold a
// type without line breaks are covered.
@(private = "file")
format_template_type :: proc(f: ^FormatContext, node: ^TSTemplateLiteralType) -> Doc {
	if len(node.quasis) != len(node.types) + 1 {return format_fail(f)}
	parts := make([dynamic]Doc, f.alloc)
	append(&parts, doc_line_suffix_boundary(), ft(f, "`"))
	for quasi, index in node.quasis {
		if strings.contains_any(quasi.raw, "\r\n") {return format_fail(f)}
		append(&parts, ft(f, quasi.raw))
		if index == len(node.types) {break}
		next := node.quasis[index + 1]
		if format_has_newline_in_range(f.source, quasi.loc.end, next.loc.start) {
			return format_fail(f)
		}
		printed := format_type(f, node.types[index], .Types)
		text, plain := doc_plain_text(f, printed)
		if !plain {return format_fail(f)}
		append(&parts, ft(f, "${"), ft(f, text), doc_line_suffix_boundary(), ft(f, "}"))
	}
	append(&parts, ft(f, "`"))
	return fc(f, ..parts[:])
}

@(private = "file")
format_type_predicate :: proc(f: ^FormatContext, node: ^TSTypePredicate) -> Doc {
	name := format_type_name(f, node.parameter_name)
	asserts := ft(f, "asserts ") if node.asserts else nil
	annotation, present := node.type_annotation.?
	if !present || annotation == nil {return fc(f, asserts, name)}
	asserted := format_type(f, annotation.type_annotation, .Type_Annotation)
	return fc(f, asserts, name, ft(f, " is "), asserted)
}

@(private = "file")
format_import_type :: proc(f: ^FormatContext, node: ^TSImportType) -> Doc {
	if node.has_options {return format_fail(f)}
	argument := format_type_unwrap(node.argument)
	if argument == nil {return format_fail(f)}
	literal, is_literal := argument^.(^TSLiteralType)
	if !is_literal || literal.literal == nil {return format_fail(f)}
	if _, is_string := literal.literal^.(^StringLiteral); !is_string {return format_fail(f)}
	parts := make([dynamic]Doc, f.alloc)
	if node.is_typeof {append(&parts, ft(f, "typeof "))}
	append(&parts, ft(f, "import("), format_expr(f, literal.literal, .Expression), ft(f, ")"))
	if qualifier, qualified := node.qualifier.?; qualified {
		append(&parts, ft(f, "."), format_type_name(f, qualifier))
	}
	append(&parts, format_type_arguments(f, node.type_parameters))
	return fc(f, ..parts[:])
}

// The type behind an annotation. The path records the annotation itself,
// because parenthesis and layout rules ask what it annotates.
format_annotated_type :: proc(
	f: ^FormatContext,
	annotation: Maybe(^TSTypeAnnotation),
	key: FormatKey,
) -> Doc {
	node, present := annotation.?
	if !present || node == nil {return nil}
	if !format_path_push(f, {kind = .TS_Annotation, key = key, node = node}) {return nil}
	defer format_path_pop(f)
	return format_type(f, node.type_annotation, .Type_Annotation)
}

// `: Type` after a binding, or nil without annotation.
format_type_annotation :: proc(f: ^FormatContext, annotation: Maybe(^TSTypeAnnotation)) -> Doc {
	type := format_annotated_type(f, annotation, .Type_Annotation)
	if type == nil {return nil}
	return fc(f, ft(f, ": "), type)
}

// `: Type` after a parameter list, or nil without annotation.
format_return_type :: proc(f: ^FormatContext, annotation: Maybe(^TSTypeAnnotation)) -> Doc {
	type := format_annotated_type(f, annotation, .Return_Type)
	if type == nil {return nil}
	return fc(f, ft(f, ": "), type)
}

// The type an annotation holds, without parentheses, or nil.
format_annotation_type :: proc(annotation: Maybe(^TSTypeAnnotation)) -> ^TSType {
	node, present := annotation.?
	if !present || node == nil {return nil}
	return format_type_unwrap(node.type_annotation)
}

// True for a return type that names a type, as opposed to a keyword.
// Prettier does not hug an arrow function that has one unless its body is a
// block with statements.
format_returns_type_reference :: proc(annotation: Maybe(^TSTypeAnnotation)) -> bool {
	node, present := annotation.?
	if !present || node == nil || node.type_annotation == nil {return false}
	_, reference := node.type_annotation^.(^TSTypeReference)
	return reference
}
