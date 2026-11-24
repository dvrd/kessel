package kessel

// Binary and logical expressions. Operands of operators that chain, such as
// `a + b + c` or `a && b && c`, print as one flat list so that every operator
// of the chain breaks at the same level. A port of Prettier's binaryish rules.

@(private = "file")
format_binary_sides :: proc(expr: ^Expression) -> (left, right: ^Expression) {
	#partial switch node in expr^ {
	case ^BinaryExpression: return node.left, node.right
	case ^LogicalExpression: return node.left, node.right
	}
	return nil, nil
}

// Appends the operands and operators of the binary expression on top of the
// path. `nested` is true for the left operands that were flattened into it.
@(private = "file")
format_binary_parts :: proc(
	f: ^FormatContext,
	parts: ^[dynamic]Doc,
	inside_parens: bool,
) {
	current := format_path_at(f, 0)
	node := current.expr
	if !format_is_binaryish(node) {
		append(parts, doc_group(f, format_expr_entered(f)))
		return
	}
	kind := current.kind
	parent_kind := format_parent(f).kind
	left, right := format_binary_sides(node)
	left_inner := format_expr_unwrap(left)
	right_inner := format_expr_unwrap(right)
	if left_inner == nil || right_inner == nil {
		f.failed = true
		return
	}
	if format_is_binaryish(left_inner) && format_should_flatten(node, left_inner) {
		if _, entered := format_expr_enter(f, left, .Left); !entered {return}
		format_binary_parts(f, parts, inside_parens)
		format_path_pop(f)
	} else {
		append(parts, doc_group(f, format_expr(f, left, .Left)))
	}
	operator := ft(f, format_binary_operator_text(node))
	right_doc := format_expr(f, right, .Right)
	tail: Doc
	if format_should_inline_logical(node) {
		tail = fc(f, operator, ft(f, " "), right_doc)
	} else {
		tail = fc(f, operator, doc_line(), right_doc)
	}
	// An operand group of its own lets `a * b` stay together inside a
	// longer `+` chain. Logical tests inside `if (…)` break all at once.
	should_group := !(inside_parens && kind == .Logical)
	should_group = should_group && parent_kind != kind
	should_group = should_group && format_expr_kind(left_inner) != kind
	should_group = should_group && format_expr_kind(right_inner) != kind
	if should_group {tail = doc_group(f, tail)}
	append(parts, ft(f, " "), tail)
}

// `Boolean(a && b)` prints its argument like a condition.
@(private = "file")
format_is_boolean_call_argument :: proc(f: ^FormatContext) -> bool {
	current := format_path_at(f, 0)
	parent := format_parent(f)
	if current.key != .Arguments || parent.kind != .Call {return false}
	call := parent.expr^.(^CallExpression)
	if call.optional || len(call.arguments) != 1 || call.callee == nil {return false}
	callee, named := call.callee^.(^Identifier)
	return named && callee.name == "Boolean"
}

format_binaryish :: proc(f: ^FormatContext, expr: ^Expression) -> Doc {
	current := format_path_at(f, 0)
	parent := format_parent(f)
	grandparent := format_path_at(f, 2)
	key := current.key
	parent_kind, grandparent_kind := parent.kind, grandparent.kind
	inside_parens := false
	if key != .Body {
		#partial switch parent_kind {
		case .If, .While, .Switch, .Do_While: inside_parens = true
		}
	}
	member_parent := false
	if parent_kind == .Member {member_parent = !parent.expr^.(^MemberExpression).computed}
	boolean_argument := format_is_boolean_call_argument(f)

	parts := make([dynamic]Doc, f.alloc)
	format_binary_parts(f, &parts, inside_parens)
	if f.failed || len(parts) == 0 {return nil}
	if inside_parens {return fc(f, ..parts[:])}
	// A callee, unary operand or member object is parenthesised, and the
	// parentheses hold the break.
	if (key == .Callee && (parent_kind == .Call || parent_kind == .New)) ||
	   parent_kind == .Unary ||
	   member_parent {
		return fg(f, fi(f, doc_softline(), fc(f, ..parts[:])), doc_softline())
	}
	should_not_indent := parent_kind == .Return || parent_kind == .Throw
	should_not_indent = should_not_indent || (parent_kind == .Arrow_Function && key == .Body)
	should_not_indent = should_not_indent || (parent_kind == .For && key != .Body)
	should_not_indent = should_not_indent || parent_kind == .Template || boolean_argument
	if parent_kind == .Conditional {
		#partial switch grandparent_kind {
		case .Return, .Throw, .Call, .New:
		case: should_not_indent = true
		}
	}
	should_indent_if_inlining :=
		parent_kind == .Assignment ||
		parent_kind == .Variable_Declarator ||
		parent_kind == .Class_Property ||
		parent_kind == .Property
	left, _ := format_binary_sides(expr)
	left_inner := format_expr_unwrap(left)
	chained_left := format_is_binaryish(left_inner) && format_should_flatten(expr, left_inner)
	inline := format_should_inline_logical(expr)
	if should_not_indent || (inline && !chained_left) || (!inline && should_indent_if_inlining) {
		return fg(f, ..parts[:])
	}
	return fg(f, parts[0], fi(f, ..parts[1:]))
}
