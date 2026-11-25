package kessel

import "core:slice"
import "core:strings"

// Expression printers. See format_print.odin for the conventions.

// The parser may keep parentheses as nodes. Prettier's reference AST never
// has them, so every rule looks through them.
format_expr_unwrap :: proc(expr: ^Expression) -> ^Expression {
	inner := expr
	for inner != nil {
		parenthesized, wrapped := inner^.(^ParenthesizedExpression)
		if !wrapped {break}
		inner = parenthesized.expression
	}
	return inner
}

// Looks through parentheses and the ChainExpression wrapper.
format_expr_strip :: proc(expr: ^Expression) -> ^Expression {
	inner := format_expr_unwrap(expr)
	if inner == nil {return nil}
	if chain, is_chain := inner^.(^ChainExpression); is_chain {
		return format_expr_unwrap(chain.expression)
	}
	return inner
}

format_expr_kind :: proc(expr: ^Expression) -> FormatNodeKind {
	#partial switch _ in expr^ {
	case ^NullLiteral, ^BooleanLiteral, ^BigIntLiteral, ^RegExpLiteral: return .Literal
	case ^NumericLiteral: return .Number
	case ^StringLiteral: return .String
	case ^TemplateLiteral: return .Template
	case ^TaggedTemplateExpression: return .Tagged_Template
	case ^Identifier: return .Identifier
	case ^PrivateIdentifier: return .Private_Name
	case ^ThisExpression: return .This
	case ^Super: return .Super
	case ^ArrayExpression: return .Array
	case ^ObjectExpression: return .Object
	case ^FunctionExpression: return .Function_Expression
	case ^ArrowFunctionExpression: return .Arrow_Function
	case ^ClassExpression: return .Class_Expression
	case ^MemberExpression: return .Member
	case ^CallExpression: return .Call
	case ^NewExpression: return .New
	case ^ConditionalExpression: return .Conditional
	case ^UpdateExpression: return .Update
	case ^UnaryExpression: return .Unary
	case ^BinaryExpression: return .Binary
	case ^LogicalExpression: return .Logical
	case ^AssignmentExpression: return .Assignment
	case ^SequenceExpression: return .Sequence
	case ^SpreadElement: return .Spread
	case ^YieldExpression: return .Yield
	case ^AwaitExpression: return .Await
	case ^ImportExpression: return .Import_Expression
	case ^MetaProperty: return .Meta_Property
	case ^JSXElement, ^JSXFragment: return .JSX
	case ^JSXExpressionContainer: return .JSX_Expression_Container
	case ^TSAsExpression: return .TS_As
	case ^TSSatisfiesExpression: return .TS_Satisfies
	case ^TSNonNullExpression: return .TS_Non_Null
	case ^TSTypeAssertion: return .TS_Type_Assertion
	case ^TSInstantiationExpression: return .TS_Instantiation
	}
	return .Other
}

// Pushes the path entry for an expression and returns the node that the
// entry describes. The caller pops the entry.
format_expr_enter :: proc(
	f: ^FormatContext,
	expr: ^Expression,
	key: FormatKey,
) -> (
	inner: ^Expression,
	ok: bool,
) {
	inner = format_expr_unwrap(expr)
	if inner == nil {
		f.failed = true
		return nil, false
	}
	chain_root := false
	if chain, is_chain := inner^.(^ChainExpression); is_chain {
		inner = format_expr_unwrap(chain.expression)
		if inner == nil {
			f.failed = true
			return nil, false
		}
		chain_root = true
	}
	entry := FormatPathEntry {
		kind       = format_expr_kind(inner),
		key        = key,
		expr       = inner,
		chain_root = chain_root,
	}
	if !format_path_push(f, entry) {return nil, false}
	return inner, true
}

// Prints the expression whose entry is on top of the path.
format_expr_entered :: proc(f: ^FormatContext, args := FormatArgs{}) -> Doc {
	doc := format_expr_inner(f, format_path_at(f, 0).expr, args)
	if format_needs_parens(f) {return fc(f, ft(f, "("), doc, ft(f, ")"))}
	return doc
}

format_expr :: proc(
	f: ^FormatContext,
	expr: ^Expression,
	key: FormatKey,
	args := FormatArgs{},
) -> Doc {
	if _, entered := format_expr_enter(f, expr, key); !entered {return nil}
	defer format_path_pop(f)
	return format_expr_entered(f, args)
}

@(private = "file")
format_expr_inner :: proc(f: ^FormatContext, expr: ^Expression, args: FormatArgs) -> Doc {
	#partial switch node in expr^ {
	case ^NullLiteral, ^BooleanLiteral, ^NumericLiteral, ^BigIntLiteral, ^StringLiteral,
	     ^RegExpLiteral:
		return format_literal(f, expr)
	case ^TemplateLiteral:
		return format_template(f, node)
	case ^TaggedTemplateExpression:
		return format_tagged_template(f, node)
	case ^Identifier:
		if node.has_escape {return format_fail(f)}
		// Outside their functions these parse as plain names, where Prettier's
		// parser reads a keyword. The statement keeps its text.
		if node.name == "await" || node.name == "yield" {return format_fail(f)}
		optional := ft(f, "?") if node.optional else nil
		return fc(f, ft(f, node.name), optional, format_type_annotation(f, node.type_annotation))
	case ^PrivateIdentifier, ^ThisExpression, ^Super, ^MetaProperty:
		return format_literal(f, expr)
	case ^ArrayExpression:
		return format_array(f, node)
	case ^ObjectExpression:
		return format_object(f, node)
	case ^FunctionExpression:
		return format_function(f, node, args)
	case ^ArrowFunctionExpression:
		return format_arrow(f, node, args)
	case ^ClassExpression:
		return format_class(f, node)
	case ^MemberExpression:
		return format_member(f, node)
	case ^CallExpression:
		return format_call(f, expr)
	case ^NewExpression:
		return format_call(f, expr)
	case ^ImportExpression:
		return format_call(f, expr)
	case ^ConditionalExpression:
		return format_conditional(f, node)
	case ^UpdateExpression:
		operator := "++" if node.operator == .Increment else "--"
		argument := format_expr(f, node.argument, .Argument)
		if node.prefix {return fc(f, ft(f, operator), argument)}
		return fc(f, argument, ft(f, operator))
	case ^UnaryExpression:
		operator := ft(f, format_unary_text(node.operator))
		return fc(f, operator, format_expr(f, node.argument, .Argument))
	case ^BinaryExpression, ^LogicalExpression:
		return format_binaryish(f, expr)
	case ^AssignmentExpression:
		return format_assignment_expression(f, node)
	case ^SequenceExpression:
		return format_sequence(f, node)
	case ^SpreadElement:
		return fc(f, ft(f, "..."), format_expr(f, node.argument, .Argument))
	case ^YieldExpression:
		keyword := ft(f, "yield*" if node.delegate else "yield")
		if argument, present := node.argument.?; present && argument != nil {
			return fc(f, keyword, ft(f, " "), format_expr(f, argument, .Argument))
		}
		return keyword
	case ^AwaitExpression:
		return format_await(f, node)
	}
	// What remains is TypeScript's and JSX's own expressions.
	return format_ts_expression(f, expr)
}

// Literals and the other expressions that are a single token or name.
@(private = "file")
format_literal :: proc(f: ^FormatContext, expr: ^Expression) -> Doc {
	#partial switch node in expr^ {
	case ^NullLiteral:
		return ft(f, "null")
	case ^BooleanLiteral:
		return ft(f, "true" if node.value else "false")
	case ^NumericLiteral:
		return ft(f, format_number(f, node.raw))
	case ^BigIntLiteral:
		return ft(f, strings.to_lower(node.raw, f.alloc))
	case ^StringLiteral:
		return format_string_literal(f, node)
	case ^RegExpLiteral:
		return format_regexp(f, node)
	case ^PrivateIdentifier:
		return fc(f, ft(f, "#"), ft(f, node.name))
	case ^ThisExpression:
		return ft(f, "this")
	case ^Super:
		return ft(f, "super")
	case ^MetaProperty:
		return fc(f, ft(f, node.meta.name), ft(f, "."), ft(f, node.property.name))
	}
	return format_fail(f)
}

@(private = "file")
format_ts_expression :: proc(f: ^FormatContext, expr: ^Expression) -> Doc {
	#partial switch node in expr^ {
	case ^TSAsExpression:
		return format_cast(f, node.expression, " as ", node.type_annotation)
	case ^TSSatisfiesExpression:
		return format_cast(f, node.expression, " satisfies ", node.type_annotation)
	case ^TSNonNullExpression:
		return fc(f, format_expr(f, node.expression, .Expression), ft(f, "!"))
	case ^TSTypeAssertion:
		return format_type_assertion(f, node)
	case ^TSInstantiationExpression:
		value := format_expr(f, node.expression, .Expression)
		return fc(f, value, format_type_arguments(f, node.type_arguments))
	case ^JSXElement, ^JSXFragment:
		return format_jsx(f, expr)
	case ^JSXExpressionContainer, ^JSXSpreadChild, ^JSXEmptyExpression:
		return format_jsx_container(f, expr)
	}
	return format_fail(f)
}

// `<Type>value`. When the two do not fit on a line, the value moves into
// parentheses on lines of its own, unless it is an array or an object, which
// break by themselves.
@(private = "file")
format_type_assertion :: proc(f: ^FormatContext, node: ^TSTypeAssertion) -> Doc {
	type := format_type(f, node.type_annotation, .Type_Annotation)
	angle := fg(f, ft(f, "<"), fi(f, doc_softline(), type), doc_softline(), ft(f, ">"))
	value := format_expr(f, node.expression, .Expression)
	inner := format_expr_unwrap(node.expression)
	if inner == nil {return format_fail(f)}
	#partial switch _ in inner^ {
	case ^ArrayExpression, ^ObjectExpression:
		return fg(f, angle, value)
	}
	wrapped := fc(
		f,
		doc_if_break(f, ft(f, "(")),
		fi(f, doc_softline(), value),
		doc_softline(),
		doc_if_break(f, ft(f, ")")),
	)
	plain := fc(f, angle, value)
	states := []Doc{plain, fc(f, angle, doc_group(f, wrapped, true)), plain}
	return doc_conditional_group(f, states)
}

// `value as Type` and `value satisfies Type`. As a callee or the object of a
// member access the angle is parenthesised, and the parentheses hold the
// break.
@(private = "file")
format_cast :: proc(f: ^FormatContext, value: ^Expression, keyword: string, type: ^TSType) -> Doc {
	current := format_path_at(f, 0)
	parent := format_parent(f)
	is_callee := current.key == .Callee && parent.kind == .Call
	is_object := current.key == .Object && parent.kind == .Member
	// TypeScript does not read `as` on a new line as a cast, and the parser
	// does. The statement keeps its lines so that its meaning cannot change.
	type_loc := get_ts_type_loc(type)
	value_end := get_expression_loc(value).end
	if type_loc == nil || format_has_newline_in_range(f.source, value_end, type_loc.start) {
		return format_fail(f)
	}
	target := format_type(f, type, .Type_Annotation)
	parts := fc(f, format_expr(f, value, .Expression), ft(f, keyword), target)
	if is_callee || is_object {return fg(f, fi(f, doc_softline(), parts), doc_softline())}
	return parts
}

@(private = "file")
format_unary_text :: proc(operator: UnaryOperator) -> string {
	switch operator {
	case .Minus: return "-"
	case .Plus: return "+"
	case .LogicalNot: return "!"
	case .BitwiseNot: return "~"
	case .Typeof: return "typeof "
	case .Void: return "void "
	case .Delete: return "delete "
	}
	return ""
}

// The first token of the expression belongs to this node. Statements that
// begin with `{`, `function` or `class` would parse as something else.
format_expr_leftmost :: proc(expr: ^Expression) -> ^Expression {
	node := format_expr_strip(expr)
	for node != nil {
		next: ^Expression
		#partial switch inner in node^ {
		case ^BinaryExpression: next = inner.left
		case ^LogicalExpression: next = inner.left
		case ^AssignmentExpression: next = inner.left
		case ^MemberExpression: next = inner.object
		case ^TaggedTemplateExpression:
			tag := format_expr_strip(inner.tag)
			if tag == nil {return node}
			if _, function := tag^.(^FunctionExpression); function {return node}
			next = inner.tag
		case ^CallExpression:
			callee := format_expr_strip(inner.callee)
			if callee == nil {return node}
			if _, function := callee^.(^FunctionExpression); function {return node}
			next = inner.callee
		case ^ConditionalExpression: next = inner.test
		case ^UpdateExpression:
			if inner.prefix {return node}
			next = inner.argument
		case ^SequenceExpression:
			if len(inner.expressions) == 0 {return node}
			next = inner.expressions[0]
		case ^TSAsExpression: next = inner.expression
		case ^TSSatisfiesExpression: next = inner.expression
		case ^TSNonNullExpression: next = inner.expression
		case:
			return node
		}
		node = format_expr_strip(next)
	}
	return node
}

// Prettier's number normalisation: lowercase, no `+` or leading zeros in the
// exponent, no zero exponent, a digit before the dot, and no trailing zeros
// or trailing dot in the fraction.
format_number :: proc(f: ^FormatContext, raw: string) -> string {
	if len(raw) <= 1 {return raw}
	text := strings.to_lower(raw, f.alloc)
	mantissa_end := 0
	for mantissa_end < len(text) {
		char := text[mantissa_end]
		if (char < '0' || char > '9') && char != '.' {break}
		mantissa_end += 1
	}
	if mantissa_end > 0 && mantissa_end < len(text) && text[mantissa_end] == 'e' {
		mantissa := text[:mantissa_end]
		exponent := text[mantissa_end + 1:]
		sign := ""
		if len(exponent) > 0 && (exponent[0] == '+' || exponent[0] == '-') {
			if exponent[0] == '-' {sign = "-"}
			exponent = exponent[1:]
		}
		for len(exponent) > 1 && exponent[0] == '0' && exponent[1] >= '0' && exponent[1] <= '9' {
			exponent = exponent[1:]
		}
		if exponent == "0" {
			text = mantissa
		} else {
			text = strings.concatenate({mantissa, "e", sign, exponent}, f.alloc)
		}
	}
	if strings.has_prefix(text, ".") {text = strings.concatenate({"0", text}, f.alloc)}
	dot := strings.index_byte(text, '.')
	if dot < 0 {return text}
	digits_end := dot + 1
	for digits_end < len(text) && text[digits_end] >= '0' && text[digits_end] <= '9' {
		digits_end += 1
	}
	if digits_end < len(text) && text[digits_end] != 'e' {return text}
	kept_end := digits_end
	// The fraction keeps its first digit even when that digit is a zero.
	for kept_end > dot + 2 && text[kept_end - 1] == '0' {kept_end -= 1}
	if kept_end == dot + 1 {kept_end = dot}
	if kept_end == digits_end {return text}
	return strings.concatenate({text[:kept_end], text[digits_end:]}, f.alloc)
}

format_string_literal :: proc(f: ^FormatContext, node: ^StringLiteral) -> Doc {
	if len(node.raw) < 2 {return format_fail(f)}
	// A line continuation would put a newline inside one text part.
	if strings.contains_any(node.raw, "\r\n  ") {return format_fail(f)}
	return ft(f, format_string(node.raw, f.options.single_quote, f.alloc))
}

@(private = "file")
format_regexp :: proc(f: ^FormatContext, node: ^RegExpLiteral) -> Doc {
	raw := f.source[node.loc.start:node.loc.end]
	slash := strings.last_index_byte(raw, '/')
	if slash <= 0 || raw[0] != '/' {return format_fail(f)}
	flags := transmute([]u8)strings.clone(raw[slash + 1:], f.alloc)
	slice.sort(flags)
	return fc(f, ft(f, raw[:slash + 1]), ft(f, string(flags)))
}

@(private = "file")
format_sequence :: proc(f: ^FormatContext, node: ^SequenceExpression) -> Doc {
	parent := format_parent(f)
	if len(node.expressions) == 0 {return format_fail(f)}
	if parent.kind == .Expression_Statement || parent.kind == .For {
		parts := make([dynamic]Doc, f.alloc)
		for expression, index in node.expressions {
			printed := format_expr(f, expression, .Expressions)
			if index == 0 {
				append(&parts, printed)
			} else {
				append(&parts, ft(f, ","), fi(f, doc_line(), printed))
			}
		}
		return fg(f, ..parts[:])
	}
	items := make([]Doc, len(node.expressions), f.alloc)
	for expression, index in node.expressions {
		items[index] = format_expr(f, expression, .Expressions)
	}
	joined := doc_join(f, fc(f, ft(f, ","), doc_line()), items)
	hugging_parent := parent.kind == .Return || parent.kind == .Throw
	hugging_parent = hugging_parent && format_path_at(f, 0).key == .Argument
	if parent.kind == .Arrow_Function && format_path_at(f, 0).key == .Body {hugging_parent = true}
	if hugging_parent {
		return fg(f, doc_if_break(f, fc(f, fi(f, doc_softline(), joined), doc_softline()), joined))
	}
	return fg(f, joined)
}

// An awaited value used as a callee or object gets its own group, unless an
// enclosing await already starts with it and so already groups the line.
@(private = "file")
format_await :: proc(f: ^FormatContext, node: ^AwaitExpression) -> Doc {
	current := format_path_at(f, 0)
	parent := format_parent(f)
	parts := fc(f, ft(f, "await "), format_expr(f, node.argument, .Argument))
	is_callee := (parent.kind == .Call) && current.key == .Callee
	is_object := parent.kind == .Member && current.key == .Object
	if !is_callee && !is_object {return parts}
	wrapped := fc(f, fi(f, doc_softline(), parts), doc_softline())
	for level := 1; level < len(f.path); level += 1 {
		ancestor := format_path_at(f, level)
		if ancestor.kind == .Block {break}
		if ancestor.kind != .Await {continue}
		outer := ancestor.expr^.(^AwaitExpression)
		if format_expr_leftmost(outer.argument) == current.expr {return wrapped}
		break
	}
	return fg(f, wrapped)
}

// One branch of a conditional. A block comment after the `?` or `:` in
// front of it leads it. `before` is what precedes the branch.
@(private = "file")
format_conditional_branch :: proc(
	f: ^FormatContext,
	expr, before: ^Expression,
	key: FormatKey,
) -> Doc {
	printed := format_expr(f, expr, key)
	start, end := get_expression_loc(before).end, get_expression_loc(expr).start
	printed = fc(f, format_operand_leading_comments(f, start, end), printed)
	if f.options.use_tabs {return doc_indent(f, printed)}
	return doc_align(f, 2, printed)
}

// Nested conditionals in the alternate position form a flat chain of
// `test ? value : test ? value : value` lines.
@(private = "file")
format_conditional :: proc(f: ^FormatContext, node: ^ConditionalExpression) -> Doc {
	current := format_path_at(f, 0)
	parent := format_parent(f)
	parent_is_conditional := parent.kind == .Conditional
	is_parent_test := parent_is_conditional && current.key == .Test
	is_alternate := parent_is_conditional && current.key == .Alternate
	force_no_indent := parent_is_conditional && !is_parent_test

	// The chain ends at the first ancestor that is not a conditional holding
	// the previous node as a branch.
	level := 1
	for {
		ancestor := format_path_at(f, level)
		below := format_path_at(f, level - 1)
		if ancestor.kind != .Conditional || below.key == .Test {break}
		level += 1
	}
	chain_parent := format_path_at(f, level)

	consequent := format_expr_strip(node.consequent)
	alternate := format_expr_strip(node.alternate)
	if consequent == nil || alternate == nil {return format_fail(f)}
	if format_conditional_chain_has_jsx(format_path_at(f, level - 1).expr) {
		return format_conditional_jsx(f, node, parent == chain_parent, is_alternate, is_parent_test)
	}
	_, consequent_nested := consequent^.(^ConditionalExpression)
	part := fc(
		f,
		doc_line(),
		ft(f, "? "),
		doc_if_break(f, nil, ft(f, "(")) if consequent_nested else nil,
		format_conditional_branch(f, node.consequent, node.test, .Consequent),
		doc_if_break(f, nil, ft(f, ")")) if consequent_nested else nil,
		doc_line(),
		ft(f, ": "),
		format_conditional_branch(f, node.alternate, node.consequent, .Alternate),
	)
	if parent_is_conditional && !is_alternate && !is_parent_test {
		if f.options.use_tabs {
			part = doc_align(f, -1, doc_indent(f, part))
		} else {
			part = doc_align(f, max(0, f.options.tab_width - 2), part)
		}
	}

	test := format_expr(f, node.test, .Test)
	if is_alternate {test = doc_align(f, 2, test)}
	break_closing_paren := parent.kind == .Member && current.key == .Object
	if break_closing_paren {
		member := parent.expr^.(^MemberExpression)
		break_closing_paren = !member.computed
	}
	in_argument := format_conditional_is_chain_argument(f)
	result := fc(
		f,
		test,
		part if force_no_indent else doc_indent(f, part),
		doc_softline() if break_closing_paren && !in_argument else nil,
	)
	if parent == chain_parent {result = doc_group(f, result)}
	if is_parent_test || in_argument {
		return fg(f, fi(f, doc_softline(), result), doc_softline())
	}
	return result
}

@(private = "file")
format_is_jsx :: proc(expr: ^Expression) -> bool {
	inner := format_expr_unwrap(expr)
	if inner == nil {return false}
	#partial switch _ in inner^ {
	case ^JSXElement, ^JSXFragment: return true
	}
	return false
}

// True when a chain of conditionals holds a JSX element as a test or a
// branch anywhere. `root` is the conditional that starts the chain.
@(private = "file")
format_conditional_chain_has_jsx :: proc(root: ^Expression) -> bool {
	node := format_expr_unwrap(root)
	if node == nil {return false}
	conditional, is_conditional := node^.(^ConditionalExpression)
	if !is_conditional {return false}
	for side in ([3]^Expression{conditional.test, conditional.consequent, conditional.alternate}) {
		if format_is_jsx(side) {return true}
		// Nested conditionals are few levels deep, and the path bounds how
		// deep the printer itself goes.
		if format_conditional_chain_has_jsx(side) {return true}
	}
	return false
}

// A conditional that chooses between JSX elements. Each branch takes
// parentheses and lines of its own when the conditional breaks, apart from
// `null` and `undefined`, and the chain does not indent.
@(private = "file")
format_conditional_jsx :: proc(
	f: ^FormatContext,
	node: ^ConditionalExpression,
	grouped, is_alternate, is_parent_test: bool,
) -> Doc {
	branch :: proc(f: ^FormatContext, expr: ^Expression, key: FormatKey, chain: bool) -> Doc {
		printed := format_expr(f, expr, key)
		inner := format_expr_strip(expr)
		if inner == nil {return format_fail(f)}
		#partial switch value in inner^ {
		case ^NullLiteral:
			return printed
		case ^Identifier:
			if value.name == "undefined" {return printed}
		case ^ConditionalExpression:
			if chain {return printed}
		}
		open, close := doc_if_break(f, ft(f, "(")), doc_if_break(f, ft(f, ")"))
		return fc(f, open, fi(f, doc_softline(), printed), doc_softline(), close)
	}
	test := format_expr(f, node.test, .Test)
	if is_alternate {test = doc_align(f, 2, test)}
	result := fc(
		f,
		test,
		ft(f, " ? "),
		branch(f, node.consequent, .Consequent, false),
		ft(f, " : "),
		branch(f, node.alternate, .Alternate, true),
	)
	if grouped {result = doc_group(f, result)}
	if is_parent_test {return fg(f, fi(f, doc_softline(), result), doc_softline())}
	return result
}

// True when the conditional heads a member or call chain that is itself the
// value of an assignment, return, throw, unary, yield or await.
@(private = "file")
format_conditional_is_chain_argument :: proc(f: ^FormatContext) -> bool {
	level := 1
	moved := false
	for level < len(f.path) {
		ancestor := format_path_at(f, level)
		below := format_path_at(f, level - 1)
		climbing := false
		#partial switch ancestor.kind {
		case .Call: climbing = below.key == .Callee
		case .Member: climbing = below.key == .Object
		case .TS_Non_Null: climbing = below.key == .Expression
		}
		if climbing {
			moved = true
			level += 1
			continue
		}
		owner := ancestor
		if (ancestor.kind == .New && below.key == .Callee) ||
		   ((ancestor.kind == .TS_As || ancestor.kind == .TS_Satisfies) &&
				   below.key == .Expression) {
			moved = true
			owner = format_path_at(f, level + 1)
			below = ancestor
		}
		if !moved {return false}
		#partial switch owner.kind {
		case .Assignment: return below.key == .Right
		case .Variable_Declarator: return below.key == .Init
		case .Return, .Throw, .Unary, .Yield, .Await: return below.key == .Argument
		}
		return false
	}
	return false
}
