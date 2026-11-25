package kessel

// Layout of `left operator right` for assignments, variable declarators and
// object properties. A port of Prettier's assignment layout rules.

FormatAssignment :: struct {
	kind:       enum u8 {
		Assignment,
		Declarator,
		Property,
		Class_Property,
	},
	declarator: ^VariableDeclarator,
	left:       Doc,
	left_expr:  ^Expression, // Assignment target, when the node is an assignment.
	// Where the left side ends in the source. Zero when unknown, in which
	// case a comment before the right side is not printed.
	left_end:   u32,
	operator:   string,
	right:      ^Expression,
}

format_assignment_expression :: proc(f: ^FormatContext, node: ^AssignmentExpression) -> Doc {
	target := format_expr_unwrap(node.left)
	if target == nil {return format_fail(f)}
	left := format_target(f, node.left, .Left)
	return format_assignment_like(
		f,
		FormatAssignment {
			kind = .Assignment,
			left = left,
			left_expr = target,
			left_end = get_expression_loc(node.left).end,
			operator = assign_op_text(node.operator),
			right = node.right,
		},
	)
}

format_assignment_like :: proc(f: ^FormatContext, assignment: FormatAssignment) -> Doc {
	operator: Doc
	right_key: FormatKey
	switch assignment.kind {
	case .Assignment:
		operator = fc(f, ft(f, " "), ft(f, assignment.operator))
		right_key = .Right
	case .Declarator:
		operator = ft(f, " =")
		right_key = .Init
	case .Property:
		operator = ft(f, ":")
		right_key = .Value
	case .Class_Property:
		operator = ft(f, " =")
		right_key = .Value
	}
	left := assignment.left
	layout := format_assignment_layout(f, assignment, right_key)
	if layout == .Only_Left {return left}
	right := format_expr(f, assignment.right, right_key, FormatArgs{layout = layout})
	if assignment.left_end != 0 {
		right_start := get_expression_loc(assignment.right).start
		if assignment.left_end < right_start &&
		   len(format_comments_in(f, assignment.left_end, right_start)) > 0 {
			// Calls are the values that carry annotations such as
			// `/*#__PURE__*/`, and their printers never ask about their
			// own comments. Other values keep the statement as written.
			value := format_expr_strip(assignment.right)
			#partial switch _ in value^ {
			case ^CallExpression, ^NewExpression:
			case: return format_fail(f)
			}
			operator_end := format_assignment_operator_end(f, assignment.left_end, right_start)
			leading := format_inline_leading_comments(f, operator_end, right_start)
			right = fc(f, leading, right)
		}
	}
	return format_assignment_render(f, layout, left, operator, right)
}

// The offset just past the operator between the two sides. Comments before
// the operator belong to the left side, which does not print comments, so
// the scan stops at the first code character.
@(private = "file")
format_assignment_operator_end :: proc(f: ^FormatContext, left_end, right_start: u32) -> u32 {
	index := format_next_code_index(f.source, left_end)
	for index < int(right_start) {
		char := f.source[index]
		if char == ' ' || char == '\t' || char == '\n' || char == '\r' || char == '/' {break}
		index += 1
	}
	return u32(min(index, int(right_start)))
}

format_assignment_render :: proc(
	f: ^FormatContext,
	layout: FormatAssignLayout,
	left, operator, right: Doc,
) -> Doc {
	#partial switch layout {
	case .Break_After_Operator:
		return fg(f, fg(f, left), operator, fg(f, fi(f, doc_line(), right)))
	case .Never_Break_After_Operator:
		return fg(f, fg(f, left), operator, ft(f, " "), right)
	case .Fluid:
		id := doc_group_id(f)
		return fg(
			f,
			fg(f, left),
			operator,
			doc_group(f, doc_indent(f, doc_line()), false, id),
			doc_line_suffix_boundary(),
			doc_indent_if_break(f, right, id),
		)
	case .Break_Lhs:
		return fg(f, left, operator, ft(f, " "), fg(f, right))
	case .Chain:
		return fc(f, fg(f, left), operator, doc_line(), right)
	case .Chain_Tail:
		return fc(f, fg(f, left), operator, fi(f, doc_line(), right))
	case .Chain_Tail_Arrow_Chain:
		return fc(f, fg(f, left), operator, right)
	}
	return left
}

@(private = "file")
format_assignment_layout :: proc(
	f: ^FormatContext,
	assignment: FormatAssignment,
	right_key: FormatKey,
) -> FormatAssignLayout {
	right := format_expr_unwrap(assignment.right)
	if right == nil {return .Only_Left}
	right_assignment, right_is_assignment := right^.(^AssignmentExpression)
	is_tail := !right_is_assignment
	parent := format_parent(f)
	if assignment.kind == .Assignment &&
	   (parent.kind == .Assignment || parent.kind == .Variable_Declarator) {
		grandparent := format_path_at(f, 2)
		statement_level :=
			grandparent.kind == .Expression_Statement || grandparent.kind == .Variable_Declaration
		if !is_tail || !statement_level {
			if !is_tail {return .Chain}
			if arrow, is_arrow := right^.(^ArrowFunctionExpression); is_arrow {
				if body, expression := arrow.body.(^Expression); expression {
					inner := format_expr_unwrap(body)
					if inner != nil {
						if _, nested := inner^.(^ArrowFunctionExpression); nested {
							return .Chain_Tail_Arrow_Chain
						}
					}
				}
			}
			return .Chain_Tail
		}
	}
	if !is_tail {
		inner := format_expr_unwrap(right_assignment.right)
		if inner != nil {
			if _, head_of_chain := inner^.(^AssignmentExpression); head_of_chain {
				return .Break_After_Operator
			}
		}
	}
	if call, is_call := right^.(^CallExpression); is_call && call.callee != nil {
		if callee, named := call.callee^.(^Identifier); named && callee.name == "require" {
			return .Never_Break_After_Operator
		}
	}
	can_break_left := doc_can_break(assignment.left)
	if format_is_complex_destructuring(assignment) {return .Break_Lhs}
	if format_has_complex_type_annotation(assignment) {return .Break_Lhs}
	_, right_is_arrow := right^.(^ArrowFunctionExpression)
	if assignment.kind == .Declarator && right_is_arrow && can_break_left {return .Break_Lhs}
	has_short_key := false
	if assignment.kind == .Property {
		if text, plain := doc_plain_text(f, assignment.left); plain {
			has_short_key = format_width(text) < int(f.options.tab_width) + 3
		}
	}
	if format_should_break_after_operator(f, assignment.right, right_key, has_short_key) {
		return .Break_After_Operator
	}
	if !can_break_left {
		if has_short_key {return .Never_Break_After_Operator}
		#partial switch _ in right^ {
		case ^TemplateLiteral, ^TaggedTemplateExpression, ^BooleanLiteral, ^NumericLiteral,
		     ^ClassExpression:
			return .Never_Break_After_Operator
		}
	}
	return .Fluid
}

// A pattern with more than two properties, one of which renames or has a
// default, reads best with one property per line.
@(private = "file")
format_is_complex_destructuring :: proc(assignment: FormatAssignment) -> bool {
	if assignment.kind == .Assignment {
		target, is_target := assignment.left_expr^.(^ObjectExpression)
		if !is_target || len(target.properties) <= 2 {return false}
		for property in target.properties {
			if property.key == nil || property.value == nil {continue}
			if !property.shorthand {return true}
			if _, defaulted := property.value^.(^AssignmentExpression); defaulted {return true}
		}
		return false
	}
	if assignment.kind != .Declarator {return false}
	pattern, is_object := assignment.declarator.id.(^ObjectPattern)
	if !is_object || len(pattern.properties) <= 2 {return false}
	for property in pattern.properties {
		if _, has_key := property.key.?; !has_key {continue}
		if !property.shorthand {return true}
		if _, defaulted := property.value.(^AssignmentPattern); defaulted {return true}
	}
	return false
}

// A declarator annotated with a generic type that has several arguments,
// one of them generic or conditional, as in `const m: Map<string, Set<T>>`.
// The annotation breaks before the value moves to the next line.
@(private = "file")
format_has_complex_type_annotation :: proc(assignment: FormatAssignment) -> bool {
	if assignment.kind != .Declarator {return false}
	annotation: Maybe(^TSTypeAnnotation)
	#partial switch id in assignment.declarator.id {
	case ^Identifier: annotation = id.type_annotation
	case ^ObjectPattern: annotation = id.type_annotation
	case ^ArrayPattern: annotation = id.type_annotation
	}
	type := format_annotation_type(annotation)
	if type == nil {return false}
	reference, is_reference := type^.(^TSTypeReference)
	if !is_reference {return false}
	arguments, generic := reference.type_parameters.?
	if !generic || arguments == nil || len(arguments.params) < 2 {return false}
	for param in arguments.params {
		inner := format_type_unwrap(param)
		if inner == nil {continue}
		#partial switch node in inner^ {
		case ^TSConditionalType:
			return true
		case ^TSTypeReference:
			nested, nested_generic := node.type_parameters.?
			if nested_generic && nested != nil && len(nested.params) > 0 {return true}
		}
	}
	return false
}

// `a && {…}` and `a || […]` keep the literal on the operator's line.
format_should_inline_logical :: proc(expr: ^Expression) -> bool {
	if expr == nil {return false}
	logical, is_logical := expr^.(^LogicalExpression)
	if !is_logical {return false}
	right := format_expr_unwrap(logical.right)
	if right == nil {return false}
	#partial switch node in right^ {
	case ^ObjectExpression: return len(node.properties) > 0
	case ^ArrayExpression: return len(node.elements) > 0
	case ^JSXElement, ^JSXFragment: return true
	}
	return false
}

@(private = "file")
format_should_break_after_operator :: proc(
	f: ^FormatContext,
	right_expr: ^Expression,
	right_key: FormatKey,
	has_short_key: bool,
) -> bool {
	right := format_expr_unwrap(right_expr)
	if format_is_binaryish(right) && !format_should_inline_logical(right) {return true}
	#partial switch node in right^ {
	case ^SequenceExpression:
		return true
	case ^ConditionalExpression:
		test := format_expr_unwrap(node.test)
		if format_is_binaryish(test) && !format_should_inline_logical(test) {return true}
	}
	if has_short_key {return false}
	// Look through prefix operators, entering each node so that the chain
	// test below sees the same path the printer will.
	pushed := 0
	defer for _ in 0 ..< pushed {format_path_pop(f)}
	node := right_expr
	key := right_key
	for {
		inner, entered := format_expr_enter(f, node, key)
		if !entered {return false}
		pushed += 1
		next: ^Expression
		#partial switch wrapper in inner^ {
		case ^UnaryExpression: next = wrapper.argument
		case ^AwaitExpression: next = wrapper.argument
		case ^YieldExpression:
			argument, present := wrapper.argument.?
			if present {next = argument}
		case ^TSNonNullExpression:
			node = wrapper.expression
			key = .Expression
			continue
		}
		if next == nil {
			if _, is_string := inner^.(^StringLiteral); is_string {return true}
			return format_is_poorly_breakable_chain(f, inner, false)
		}
		node = next
		key = .Argument
	}
}

// A member chain with no calls, or with calls that take nothing or one short
// argument, has no good place to break. Breaking after the operator is then
// better than letting the chain run past the width.
@(private = "file")
format_is_poorly_breakable_chain :: proc(f: ^FormatContext, expr: ^Expression, deep: bool) -> bool {
	#partial switch node in expr^ {
	case ^MemberExpression:
		inner, entered := format_expr_enter(f, node.object, .Object)
		if !entered {return false}
		defer format_path_pop(f)
		return format_is_poorly_breakable_chain(f, inner, true)
	case ^CallExpression:
		if format_call_has_complex_type_arguments(f, node) {return false}
		if len(node.arguments) > 1 {return false}
		if len(node.arguments) == 1 && node.callee != nil {
			// An argument that carries a comment is not short.
			callee_end := get_expression_loc(node.callee).end
			if callee_end < node.loc.end &&
			   len(format_comments_in(f, callee_end, node.loc.end)) > 0 {
				return false
			}
		}
		if len(node.arguments) == 1 && !format_is_lone_short_argument(f, node.arguments[0]) {
			return false
		}
		printed := format_call(f, expr)
		if printed != nil && printed.label == .Member_Chain {return false}
		inner, entered := format_expr_enter(f, node.callee, .Callee)
		if !entered {return false}
		defer format_path_pop(f)
		return format_is_poorly_breakable_chain(f, inner, true)
	case ^TSNonNullExpression:
		inner, entered := format_expr_enter(f, node.expression, .Expression)
		if !entered {return false}
		defer format_path_pop(f)
		return format_is_poorly_breakable_chain(f, inner, true)
	case ^Identifier, ^ThisExpression:
		return deep
	}
	return false
}

// Several type arguments, or one that is a union, an intersection or an
// object type, give a call a place to break.
@(private = "file")
format_call_has_complex_type_arguments :: proc(f: ^FormatContext, node: ^CallExpression) -> bool {
	generics, typed := node.type_parameters.?
	if !typed || generics == nil || len(generics.params) == 0 {return false}
	if len(generics.params) > 1 {return true}
	lone := format_type_unwrap(generics.params[0])
	if lone == nil {return false}
	#partial switch _ in lone^ {
	case ^TSUnionType, ^TSIntersectionType, ^TSTypeLiteral: return true
	}
	return doc_will_break(format_type_arguments(f, node.type_parameters))
}

format_is_lone_short_argument :: proc(f: ^FormatContext, expr: ^Expression) -> bool {
	node := format_expr_unwrap(expr)
	if node == nil {return false}
	width := int(f.options.print_width)
	#partial switch inner in node^ {
	case ^ThisExpression:
		return true
	case ^Identifier:
		return 4 * len(inner.name) <= width
	case ^RegExpLiteral:
		return 4 * len(inner.pattern) <= width
	case ^StringLiteral:
		if len(inner.raw) < 2 {return false}
		return 4 * len(format_string(inner.raw, f.options.single_quote, f.alloc)) <= width
	case ^TemplateLiteral:
		if len(inner.expressions) != 0 || len(inner.quasis) != 1 {return false}
		raw := inner.quasis[0].raw
		return 4 * len(raw) <= width && !format_has_newline_in_range(raw, 0, u32(len(raw)))
	case ^UnaryExpression:
		if inner.operator == .Plus || inner.operator == .Minus {
			argument := format_expr_unwrap(inner.argument)
			if argument != nil {
				if _, numeric := argument^.(^NumericLiteral); numeric {return true}
			}
		}
		return format_is_lone_short_argument(f, inner.argument)
	case ^CallExpression:
		if inner.optional || len(inner.arguments) != 0 || inner.callee == nil {return false}
		callee, named := inner.callee^.(^Identifier)
		return named && 4 * (len(callee.name) + 2) <= width
	case ^NumericLiteral, ^BooleanLiteral, ^NullLiteral, ^BigIntLiteral:
		return true
	}
	return false
}
