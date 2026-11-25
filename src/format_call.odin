package kessel

import "core:strings"

// Member access, calls, argument lists and member chains. Ports of
// Prettier's member, call-expression, call-arguments and member-chain rules.

format_member :: proc(f: ^FormatContext, node: ^MemberExpression) -> Doc {
	object := format_expr(f, node.object, .Object)
	lookup := format_member_lookup(f, node)
	// The first ancestor that is not itself a member access.
	level := 1
	for format_path_at(f, level).kind == .Member || format_path_at(f, level).kind == .TS_Non_Null {
		level += 1
	}
	outer := format_path_at(f, level)
	parent := format_parent(f)
	should_inline := node.computed || format_member_is_new_callee(f)
	if outer.kind == .Assignment {
		left := format_expr_unwrap(outer.expr^.(^AssignmentExpression).left)
		if left != nil {
			if _, plain := left^.(^Identifier); !plain {should_inline = true}
		}
	}
	object_node := format_expr_unwrap(node.object)
	if object_node != nil && node.property != nil {
		_, object_plain := object_node^.(^Identifier)
		_, property_plain := node.property^.(^Identifier)
		if object_plain && property_plain && parent.kind != .Member {should_inline = true}
	}
	if parent.kind == .Assignment || parent.kind == .Variable_Declarator {
		if format_is_call_with_arguments(node.object) {should_inline = true}
		if object != nil && object.label == .Member_Chain {should_inline = true}
	}
	if !should_inline {lookup = fg(f, fi(f, doc_softline(), lookup))}
	result := fc(f, object, lookup)
	if object != nil && object.label != .None {return doc_label(f, object.label, result)}
	return result
}

@(private = "file")
format_is_call_with_arguments :: proc(expr: ^Expression) -> bool {
	node := format_expr_strip(expr)
	if node == nil {return false}
	if non_null, asserted := node^.(^TSNonNullExpression); asserted {
		node = format_expr_strip(non_null.expression)
		if node == nil {return false}
	}
	call, is_call := node^.(^CallExpression)
	return is_call && len(call.arguments) > 0
}

// True when the access is part of the constructor expression of `new`.
@(private = "file")
format_member_is_new_callee :: proc(f: ^FormatContext) -> bool {
	for level := 1; level < len(f.path); level += 1 {
		ancestor := format_path_at(f, level)
		below := format_path_at(f, level - 1)
		climbing := ancestor.kind == .Member && below.key == .Object
		climbing = climbing || (ancestor.kind == .TS_Non_Null && below.key == .Expression)
		if !climbing {return ancestor.kind == .New && below.key == .Callee}
	}
	return false
}

format_member_lookup :: proc(f: ^FormatContext, node: ^MemberExpression) -> Doc {
	property := format_expr(f, node.property, .Property)
	if !node.computed {return fc(f, ft(f, "?." if node.optional else "."), property)}
	optional := ft(f, "?.") if node.optional else nil
	inner := format_expr_unwrap(node.property)
	if inner != nil {
		if _, numeric := inner^.(^NumericLiteral); numeric {
			return fc(f, optional, ft(f, "["), property, ft(f, "]"))
		}
	}
	return fg(f, optional, ft(f, "["), fi(f, doc_softline(), property), doc_softline(), ft(f, "]"))
}

// ---------------------------------------------------------------------------
// Calls
// ---------------------------------------------------------------------------

// The pieces of a call, `new` or `import()` expression that the printers
// share.
FormatCallParts :: struct {
	callee:    ^Expression,
	arguments: []^Expression,
	optional:  bool,
	is_new:    bool,
	is_import: bool,
	phase:     string,
	type_arguments: Maybe(^TSTypeParameterInstantiation),
	// The whole expression's span, and the comments that sit between its
	// arguments, one entry per argument. Nil when there are none.
	loc:       Loc,
	comments:  []FormatItemComments,
}

format_call_parts :: proc(f: ^FormatContext, expr: ^Expression) -> (parts: FormatCallParts) {
	#partial switch node in expr^ {
	case ^CallExpression:
		parts.callee = node.callee
		parts.arguments = node.arguments[:]
		parts.loc = node.loc
		parts.optional = node.optional
		parts.type_arguments = node.type_parameters
	case ^NewExpression:
		parts.callee = node.callee
		parts.arguments = node.arguments[:]
		parts.loc = node.loc
		parts.is_new = true
		parts.type_arguments = node.type_parameters
	case ^ImportExpression:
		arguments := make([dynamic]^Expression, 0, 2, f.alloc)
		append(&arguments, node.source)
		if node.options != nil {append(&arguments, node.options)}
		parts.arguments = arguments[:]
		parts.is_import = true
		parts.phase = node.phase
	}
	// The argument comments below are found by position, and a comment
	// among the type arguments is not one of them.
	if generics, typed := parts.type_arguments.?; typed && generics != nil {
		if len(format_comments_in(f, generics.loc.start, generics.loc.end)) > 0 {f.failed = true}
	}
	format_call_argument_comments(f, &parts)
	return parts
}

// Attaches block comments written inline between the arguments, as in
// `visit(node, 80 /* Identifier */)`. Each leads the argument after it or
// trails the one before it. Comments on lines of their own follow rules
// that are not ported, and the statement then keeps its text.
@(private = "file")
format_call_argument_comments :: proc(f: ^FormatContext, parts: ^FormatCallParts) {
	if parts.is_import || parts.callee == nil || len(parts.arguments) == 0 {return}
	callee_end := get_expression_loc(parts.callee).end
	if callee_end >= parts.loc.end || parts.loc.end == 0 {return}
	if len(format_comments_in(f, callee_end, parts.loc.end)) == 0 {return}
	open := format_next_code_index(f.source, callee_end)
	// A parenthesised callee ends before its own closing parenthesis.
	for open < int(parts.loc.end) && f.source[open] == ')' {
		open = format_next_code_index(f.source, u32(open + 1))
	}
	if open + 1 < len(f.source) && f.source[open] == '?' && f.source[open + 1] == '.' {
		open = format_next_code_index(f.source, u32(open + 2))
	}
	close := parts.loc.end - 1
	if open >= int(close) || f.source[open] != '(' || f.source[close] != ')' {
		f.failed = true
		return
	}
	bounds := FormatListBounds{open = u32(open + 1), close = close}
	count := len(parts.arguments)
	starts := make([]u32, count, f.alloc)
	ends := make([]u32, count, f.alloc)
	for argument, index in parts.arguments {
		loc := get_expression_loc(argument)
		starts[index], ends[index] = loc.start, loc.end
	}
	// Comments nested in an argument are that argument's business.
	if !format_gaps_have_comments(f, bounds, starts, ends) {return}
	for gap in 0 ..= count {
		low := bounds.open if gap == 0 else ends[gap - 1]
		high := bounds.close if gap == count else starts[gap]
		if low < high && !format_comments_are_inline_blocks(f, low, high) {
			f.failed = true
			return
		}
	}
	parts.comments, _ = format_list_comments(f, bounds, starts, ends)
}

@(private = "file")
format_call_argument_has_comment :: proc(parts: FormatCallParts, index: int) -> bool {
	if parts.comments == nil {return false}
	return parts.comments[index].leading != nil || parts.comments[index].trailing != nil
}

format_call :: proc(f: ^FormatContext, expr: ^Expression) -> Doc {
	parts := format_call_parts(f, expr)
	arguments := parts.arguments
	generics := format_type_arguments(f, parts.type_arguments)
	head: Doc
	if parts.is_import {
		head = ft(f, "import")
		if parts.phase != "" {head = fc(f, head, ft(f, "."), ft(f, parts.phase))}
	}
	optional := ft(f, "?.") if parts.optional else nil
	if format_call_prints_flat(f, expr, parts) {
		printed := make([]Doc, len(arguments), f.alloc)
		for argument, index in arguments {
			printed[index] = format_expr(f, argument, .Arguments)
			if parts.comments != nil {
				printed[index] = format_with_comments(f, parts.comments[index], printed[index])
			}
		}
		if !parts.is_import {head = format_expr(f, parts.callee, .Callee)}
		return fc(
			f,
			ft(f, "new ") if parts.is_new else nil,
			head,
			optional,
			generics,
			ft(f, "("),
			doc_join(f, ft(f, ", "), printed),
			ft(f, ")"),
		)
	}
	if !parts.is_import && !parts.is_new && format_is_member(parts.callee) {
		_, entered := format_expr_enter(f, parts.callee, .Callee)
		if !entered {return nil}
		callee_needs_parens := format_needs_parens(f)
		format_path_pop(f)
		if !callee_needs_parens {return format_member_chain(f, expr)}
	}
	if !parts.is_import {head = format_expr(f, parts.callee, .Callee)}
	contents := fc(
		f,
		ft(f, "new ") if parts.is_new else nil,
		head,
		optional,
		generics,
		format_call_arguments(f, parts),
	)
	if parts.is_import || format_is_call(parts.callee) {return doc_group(f, contents)}
	return contents
}

format_is_member :: proc(expr: ^Expression) -> bool {
	node := format_expr_strip(expr)
	if node == nil {return false}
	_, member := node^.(^MemberExpression)
	return member
}

format_is_call :: proc(expr: ^Expression) -> bool {
	node := format_expr_strip(expr)
	if node == nil {return false}
	_, call := node^.(^CallExpression)
	return call
}

format_is_function :: proc(expr: ^Expression) -> bool {
	node := format_expr_unwrap(expr)
	if node == nil {return false}
	#partial switch _ in node^ {
	case ^FunctionExpression, ^ArrowFunctionExpression: return true
	}
	return false
}

format_is_string :: proc(expr: ^Expression) -> bool {
	node := format_expr_unwrap(expr)
	if node == nil {return false}
	_, text := node^.(^StringLiteral)
	return text
}

// The dotted name of a callee such as `describe.only`, or "" when the callee
// is anything other than identifiers joined by dots.
@(private = "file")
format_dotted_name :: proc(f: ^FormatContext, expr: ^Expression, depth := 0) -> string {
	// The longest name any rule asks about has five parts.
	if depth > 8 {return ""}
	node := format_expr_unwrap(expr)
	if node == nil {return ""}
	#partial switch inner in node^ {
	case ^Identifier:
		return inner.name
	case ^MetaProperty:
		return strings.concatenate({inner.meta.name, ".", inner.property.name}, f.alloc)
	case ^MemberExpression:
		if inner.computed || inner.optional || inner.property == nil {return ""}
		property, named := inner.property^.(^Identifier)
		if !named {return ""}
		object := format_dotted_name(f, inner.object, depth + 1)
		if object == "" {return ""}
		return strings.concatenate({object, ".", property.name}, f.alloc)
	}
	return ""
}

@(private = "file")
FORMAT_TEST_CALLEES := [?]string {
	"it", "it.only", "it.skip", "describe", "describe.only", "describe.skip", "test",
	"test.only", "test.skip", "test.fixme", "test.step", "test.describe", "test.describe.only",
	"test.describe.skip", "test.describe.fixme", "test.describe.parallel",
	"test.describe.parallel.only", "test.describe.serial", "test.describe.serial.only", "skip",
	"xit", "xdescribe", "xtest", "fit", "fdescribe", "ftest",
}

@(private = "file")
format_is_angular_test_wrapper :: proc(expr: ^Expression) -> bool {
	node := format_expr_strip(expr)
	if node == nil {return false}
	call, is_call := node^.(^CallExpression)
	if !is_call || call.callee == nil {return false}
	callee, named := call.callee^.(^Identifier)
	if !named {return false}
	switch callee.name {
	case "async", "inject", "fakeAsync", "waitForAsync": return true
	}
	return false
}

// Test runner calls such as `it("name", () => {…})` keep their arguments on
// the call's line however long the description is.
format_is_test_call :: proc(f: ^FormatContext, expr: ^Expression, parent: ^Expression) -> bool {
	if expr == nil {return false}
	call, is_call := expr^.(^CallExpression)
	if !is_call || call.optional || call.callee == nil {return false}
	arguments := call.arguments[:]
	if len(arguments) == 1 {
		if format_is_angular_test_wrapper(expr) && format_is_test_call(f, parent, nil) {
			return format_is_function(arguments[0])
		}
		if callee, named := call.callee^.(^Identifier); named {
			switch callee.name {
			case "beforeEach", "beforeAll", "afterEach", "afterAll":
				return format_is_angular_test_wrapper(arguments[0])
			}
		}
		return false
	}
	if len(arguments) != 2 && len(arguments) != 3 {return false}
	first := format_expr_unwrap(arguments[0])
	if first == nil {return false}
	_, first_template := first^.(^TemplateLiteral)
	if !first_template && !format_is_string(first) {return false}
	name := format_dotted_name(f, call.callee)
	matched := false
	for candidate in FORMAT_TEST_CALLEES {
		if candidate == name {matched = true}
	}
	if !matched {return false}
	if len(arguments) == 3 {
		third := format_expr_unwrap(arguments[2])
		if third == nil {return false}
		if _, numeric := third^.(^NumericLiteral); !numeric {return false}
	}
	if format_is_angular_test_wrapper(arguments[1]) {return true}
	second := format_expr_unwrap(arguments[1])
	if second == nil {return false}
	if len(arguments) == 2 {return format_is_function(second)}
	#partial switch callback in second^ {
	case ^FunctionExpression:
		return len(callback.params) <= 1
	case ^ArrowFunctionExpression:
		_, block := callback.body.(^BlockStatement)
		return block && len(callback.params) <= 1
	}
	return false
}

@(private = "file")
format_template_has_newline :: proc(template: ^TemplateLiteral) -> bool {
	for quasi in template.quasis {
		if strings.contains_any(quasi.raw, "\r\n") {return true}
	}
	return false
}

// A multi-line template literal that starts on the line of its call keeps
// the call's parentheses tight around it.
format_is_template_on_its_own_line :: proc(f: ^FormatContext, expr: ^Expression) -> bool {
	node := format_expr_unwrap(expr)
	if node == nil {return false}
	template: ^TemplateLiteral
	start: u32
	#partial switch inner in node^ {
	case ^TemplateLiteral:
		template, start = inner, inner.loc.start
	case ^TaggedTemplateExpression:
		quasi := format_expr_unwrap(inner.quasi)
		if quasi == nil {return false}
		template, _ = quasi^.(^TemplateLiteral)
		start = inner.loc.start
	}
	if template == nil || !format_template_has_newline(template) {return false}
	// The literal must not be the first thing on its line.
	index := int(start) - 1
	for index >= 0 && (f.source[index] == ' ' || f.source[index] == '\t') {index -= 1}
	return index < 0 || (f.source[index] != '\n' && f.source[index] != '\r')
}

@(private = "file")
format_call_prints_flat :: proc(
	f: ^FormatContext,
	expr: ^Expression,
	parts: FormatCallParts,
) -> bool {
	arguments := parts.arguments
	if len(arguments) == 1 && format_is_template_on_its_own_line(f, arguments[0]) {return true}
	call, is_call := expr^.(^CallExpression)
	plain_call := is_call && !call.optional
	// A comment on the first argument rules out the module-reference forms.
	first_commented := len(arguments) > 0 && format_call_argument_has_comment(parts, 0)
	if first_commented {return format_is_test_call(f, expr, format_parent(f).expr)}
	// Module references with one string argument never break.
	if parts.is_import || plain_call {
		named := parts.is_import
		if !named {
			switch format_dotted_name(f, call.callee) {
			case "require", "require.resolve", "require.resolve.paths", "import.meta.resolve":
				named = true
			}
		}
		if named && len(arguments) == 1 && format_is_string(arguments[0]) {return true}
	}
	if plain_call && call.callee != nil {
		if callee, named := call.callee^.(^Identifier); named {
			if callee.name == "require" {
				if len(arguments) > 1 {return true}
			} else if callee.name == "define" && format_parent(f).kind == .Expression_Statement {
				if len(arguments) == 1 {return true}
				first := format_expr_unwrap(arguments[0])
				if len(arguments) == 2 && first != nil {
					if _, array := first^.(^ArrayExpression); array {return true}
				}
				if len(arguments) == 3 && format_is_string(first) {
					second := format_expr_unwrap(arguments[1])
					if second != nil {
						if _, array := second^.(^ArrayExpression); array {return true}
					}
				}
			}
		}
	}
	return format_is_test_call(f, expr, format_parent(f).expr)
}

// ---------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------

@(private = "file")
format_call_argument :: proc(f: ^FormatContext, argument: ^Expression) -> Doc {
	if cached, present := f.arg_cache[argument]; present {return cached}
	doc := format_expr(f, argument, .Arguments)
	f.arg_cache[argument] = doc
	return doc
}

format_is_simple_call_argument :: proc(expr: ^Expression, depth := 2) -> bool {
	if depth <= 0 {return false}
	node := format_expr_strip(expr)
	if node == nil {return false}
	#partial switch inner in node^ {
	case ^TSNonNullExpression:
		return format_is_simple_call_argument(inner.expression, depth)
	case ^RegExpLiteral:
		return format_width(inner.pattern) <= 5
	case ^NullLiteral, ^BooleanLiteral, ^NumericLiteral, ^StringLiteral, ^BigIntLiteral,
	     ^Identifier, ^ThisExpression, ^Super, ^PrivateIdentifier:
		return true
	case ^TemplateLiteral:
		if format_template_has_newline(inner) {return false}
		for expression in inner.expressions {
			if !format_is_simple_call_argument(expression, depth - 1) {return false}
		}
		return true
	case ^ObjectExpression:
		for property in inner.properties {
			if property.computed {return false}
			if property.shorthand {continue}
			if property.key == nil || property.kind != .Init {return false}
			if !format_is_simple_call_argument(property.value, depth - 1) {return false}
		}
		return true
	case ^ArrayExpression:
		for element in inner.elements {
			value, present := element.?
			if !present || value == nil {continue}
			if !format_is_simple_call_argument(value, depth - 1) {return false}
		}
		return true
	case ^ImportExpression:
		count := 2 if inner.options != nil else 1
		if count > depth {return false}
		if inner.options != nil && !format_is_simple_call_argument(inner.options, depth - 1) {
			return false
		}
		return format_is_simple_call_argument(inner.source, depth - 1)
	case ^CallExpression:
		if !format_is_simple_call_argument(inner.callee, depth) {return false}
		if len(inner.arguments) > depth {return false}
		for argument in inner.arguments {
			if !format_is_simple_call_argument(argument, depth - 1) {return false}
		}
		return true
	case ^NewExpression:
		if !format_is_simple_call_argument(inner.callee, depth) {return false}
		if len(inner.arguments) > depth {return false}
		for argument in inner.arguments {
			if !format_is_simple_call_argument(argument, depth - 1) {return false}
		}
		return true
	case ^MemberExpression:
		return(
			format_is_simple_call_argument(inner.object, depth) &&
			format_is_simple_call_argument(inner.property, depth) \
		)
	case ^UnaryExpression:
		#partial switch inner.operator {
		case .LogicalNot, .Minus, .Plus, .BitwiseNot:
			return format_is_simple_call_argument(inner.argument, depth)
		}
	case ^UpdateExpression:
		return format_is_simple_call_argument(inner.argument, depth)
	}
	return false
}

// An argument that reads well when the call's parentheses hug it.
@(private = "file")
format_could_expand_argument :: proc(expr: ^Expression, arrow_chain := false) -> bool {
	node := format_expr_unwrap(expr)
	if node == nil {return false}
	#partial switch inner in node^ {
	case ^ObjectExpression: return len(inner.properties) > 0
	case ^ArrayExpression: return len(inner.elements) > 0
	case ^TSTypeAssertion: return format_could_expand_argument(inner.expression)
	case ^TSAsExpression: return format_could_expand_argument(inner.expression)
	case ^TSSatisfiesExpression: return format_could_expand_argument(inner.expression)
	case ^FunctionExpression: return true
	case ^ArrowFunctionExpression:
		body, is_expression := inner.body.(^Expression)
		if format_returns_type_reference(inner.return_type) {
			block, is_block := inner.body.(^BlockStatement)
			if !is_block {return false}
			filled := false
			for stmt in block.body {filled = filled || !format_stmt_is_empty(stmt)}
			if !filled {return false}
		}
		if !is_expression {return true}
		value := format_expr_unwrap(body)
		if value == nil {return false}
		#partial switch nested in value^ {
		case ^ArrowFunctionExpression: return format_could_expand_argument(value, true)
		case ^ObjectExpression, ^ArrayExpression, ^JSXElement, ^JSXFragment: return true
		case ^ConditionalExpression: return !arrow_chain
		case ^ChainExpression: return !arrow_chain && format_is_call(value)
		case ^CallExpression: return !arrow_chain
		}
	}
	return false
}

// Arrays of numbers print several per line and so never hug.
format_is_concisely_printed_array :: proc(expr: ^Expression) -> bool {
	node := format_expr_unwrap(expr)
	if node == nil {return false}
	array, is_array := node^.(^ArrayExpression)
	if !is_array || len(array.elements) == 0 {return false}
	for element in array.elements {
		value, present := element.?
		if !present || value == nil {return false}
		inner := format_expr_unwrap(value)
		#partial switch number in inner^ {
		case ^NumericLiteral:
		case ^UnaryExpression:
			if number.operator != .Plus && number.operator != .Minus {return false}
			argument := format_expr_unwrap(number.argument)
			if argument == nil {return false}
			if _, numeric := argument^.(^NumericLiteral); !numeric {return false}
		case:
			return false
		}
	}
	return true
}

@(private = "file")
format_same_variant :: proc(a, b: ^Expression) -> bool {
	left, right := format_expr_unwrap(a), format_expr_unwrap(b)
	if left == nil || right == nil {return false}
	return format_expr_kind(left) == format_expr_kind(right) && format_expr_kind(left) != .Literal
}

@(private = "file")
format_should_group_last :: proc(arguments: []^Expression) -> bool {
	count := len(arguments)
	last := arguments[count - 1]
	if !format_could_expand_argument(last) {return false}
	if count > 1 {
		penultimate := arguments[count - 2]
		if format_same_variant(penultimate, last) {return false}
		if format_is_concisely_printed_array(last) {return false}
		if count == 2 {
			before, after := format_expr_unwrap(penultimate), format_expr_unwrap(last)
			_, arrow := before^.(^ArrowFunctionExpression)
			_, array := after^.(^ArrayExpression)
			if arrow && array {return false}
		}
	}
	return true
}

@(private = "file")
format_is_hopefully_short_argument :: proc(expr: ^Expression) -> bool {
	node := format_expr_unwrap(expr)
	if node == nil {return false}
	#partial switch inner in node^ {
	case ^TSAsExpression, ^TSSatisfiesExpression:
		return false
	case ^CallExpression:
		if len(inner.arguments) > 1 {return false}
	case ^NewExpression:
		if len(inner.arguments) > 1 {return false}
	case ^ImportExpression:
		if inner.options != nil {return false}
	case ^BinaryExpression:
		return(
			format_is_simple_call_argument(inner.left, 1) &&
			format_is_simple_call_argument(inner.right, 1) \
		)
	case ^LogicalExpression:
		return(
			format_is_simple_call_argument(inner.left, 1) &&
			format_is_simple_call_argument(inner.right, 1) \
		)
	case ^RegExpLiteral:
		return true
	}
	return format_is_simple_call_argument(node)
}

@(private = "file")
format_should_group_first :: proc(arguments: []^Expression) -> bool {
	if len(arguments) != 2 {return false}
	first, second := format_expr_unwrap(arguments[0]), format_expr_unwrap(arguments[1])
	if first == nil || second == nil {return false}
	#partial switch callback in first^ {
	case ^FunctionExpression:
	case ^ArrowFunctionExpression:
		if _, block := callback.body.(^BlockStatement); !block {return false}
	case:
		return false
	}
	#partial switch _ in second^ {
	case ^FunctionExpression, ^ArrowFunctionExpression, ^ConditionalExpression: return false
	}
	return format_is_hopefully_short_argument(second) && !format_could_expand_argument(second)
}

// `useEffect(() => {…}, [dep])` stays on one line around the callback.
@(private = "file")
format_is_hook_with_deps :: proc(arguments: []^Expression) -> bool {
	offset := 0
	if len(arguments) == 3 {
		first := format_expr_unwrap(arguments[0])
		if first == nil {return false}
		if _, named := first^.(^Identifier); !named {return false}
		offset = 1
	} else if len(arguments) != 2 {
		return false
	}
	callback := format_expr_unwrap(arguments[offset])
	deps := format_expr_unwrap(arguments[offset + 1])
	if callback == nil || deps == nil {return false}
	arrow, is_arrow := callback^.(^ArrowFunctionExpression)
	if !is_arrow || len(arrow.params) != 0 {return false}
	if _, block := arrow.body.(^BlockStatement); !block {return false}
	_, array := deps^.(^ArrayExpression)
	return array
}

// Several functions among the arguments, as in `compose(a => b, c => d)`,
// read best with one argument per line.
@(private = "file")
format_is_function_composition :: proc(arguments: []^Expression) -> bool {
	if len(arguments) <= 1 {return false}
	functions := 0
	for argument in arguments {
		if format_is_function(argument) {
			functions += 1
			if functions > 1 {return true}
			continue
		}
		node := format_expr_strip(argument)
		if node == nil {continue}
		if call, is_call := node^.(^CallExpression); is_call {
			for inner in call.arguments {
				if format_is_function(inner) {return true}
			}
		}
	}
	return false
}

// A call whose callee is a call with more arguments, as in `f(a, b, c)(d)`.
format_is_long_curried :: proc(f: ^FormatContext) -> bool {
	current := format_path_at(f, 0)
	parent := format_parent(f)
	if current.key != .Callee || current.kind != .Call || parent.kind != .Call {return false}
	inner := current.expr^.(^CallExpression)
	outer := parent.expr^.(^CallExpression)
	return len(outer.arguments) > 0 && len(inner.arguments) > len(outer.arguments)
}

@(private = "file")
format_all_broken_out :: proc(f: ^FormatContext, printed: []Doc, trailing_comma: Doc) -> Doc {
	contents := fc(
		f,
		ft(f, "("),
		fi(f, doc_line(), fc(f, ..printed)),
		trailing_comma,
		doc_line(),
		ft(f, ")"),
	)
	return doc_group(f, contents, true)
}

format_call_arguments :: proc(f: ^FormatContext, parts: FormatCallParts) -> Doc {
	arguments := parts.arguments
	count := len(arguments)
	if count == 0 {return ft(f, "()")}
	commented := parts.comments != nil
	if !commented && format_is_hook_with_deps(arguments) {
		items := make([]Doc, count, f.alloc)
		for argument, index in arguments {items[index] = format_call_argument(f, argument)}
		return fc(f, ft(f, "("), doc_join(f, ft(f, ", "), items), ft(f, ")"))
	}
	any_empty_line := false
	printed := make([]Doc, count, f.alloc)
	for argument, index in arguments {
		doc := format_call_argument(f, argument)
		if commented {doc = format_with_comments(f, parts.comments[index], doc)}
		if index == count - 1 {
			printed[index] = doc
		} else if format_is_next_line_empty(f.source, get_expression_loc(argument).end) {
			any_empty_line = true
			printed[index] = fc(f, doc, ft(f, ","), doc_hardline(), doc_hardline())
		} else {
			printed[index] = fc(f, doc, ft(f, ","), doc_line())
		}
	}
	// The layout rules below walk the arguments again, and some follow a
	// member chain by recursion. An argument too deep to print has already
	// failed the statement, so they must not look at it.
	if f.failed {return nil}
	trailing_comma: Doc
	if !parts.is_import && f.options.trailing_comma && !f.options.trailing_comma_es5 {
		trailing_comma = ft(f, ",")
	}
	// A decorator's call is exempt from the composition rule.
	composition := format_parent(f).kind != .Decorator && format_is_function_composition(arguments)
	if any_empty_line || composition {
		return format_all_broken_out(f, printed, trailing_comma)
	}
	if !format_call_argument_has_comment(parts, 0) && format_should_group_first(arguments) {
		return format_call_arguments_hug(f, parts, printed, trailing_comma, true)
	}
	if !format_call_argument_has_comment(parts, count - 1) && format_should_group_last(arguments) {
		return format_call_arguments_hug(f, parts, printed, trailing_comma, false)
	}
	contents := fc(
		f,
		ft(f, "("),
		fi(f, doc_softline(), fc(f, ..printed)),
		doc_if_break(f, trailing_comma),
		doc_softline(),
		ft(f, ")"),
	)
	if format_is_long_curried(f) {return contents}
	should_break := false
	for doc in printed {should_break = should_break || doc_will_break(doc)}
	return doc_group(f, contents, should_break)
}

// The first or last argument hugs the parentheses when it fits that way.
// The states are: everything flat, the hugged argument broken, and every
// argument on its own line.
@(private = "file")
format_call_arguments_hug :: proc(
	f: ^FormatContext,
	parts: FormatCallParts,
	printed: []Doc,
	trailing_comma: Doc,
	first: bool,
) -> Doc {
	count := len(printed)
	others := printed[1:] if first else printed[:count - 1]
	for doc in others {
		if doc_will_break(doc) {return format_all_broken_out(f, printed, trailing_comma)}
	}
	hugged_index := 0 if first else count - 1
	saved_bailout := f.bailout
	f.bailout = false
	args := FormatArgs{expand_first_arg = first, expand_last_arg = !first}
	hugged := format_expr(f, parts.arguments[hugged_index], .Arguments, args)
	bailed := f.bailout
	f.bailout = saved_bailout
	if bailed {return format_all_broken_out(f, printed, trailing_comma)}
	rest := fc(f, ..others)
	broken := doc_group(f, hugged, true)
	flat_state, broken_state: Doc
	if first {
		flat_state = fc(f, ft(f, "("), hugged, ft(f, ", "), rest, ft(f, ")"))
		broken_state = fc(f, ft(f, "("), broken, ft(f, ", "), rest, ft(f, ")"))
	} else {
		flat_state = fc(f, ft(f, "("), rest, hugged, ft(f, ")"))
		broken_state = fc(f, ft(f, "("), rest, broken, ft(f, ")"))
	}
	all_broken := format_all_broken_out(f, printed, trailing_comma)
	if doc_will_break(hugged) {
		return fc(f, doc_break_parent(), doc_conditional_group(f, {broken_state, all_broken}))
	}
	return doc_conditional_group(f, {flat_state, broken_state, all_broken})
}
