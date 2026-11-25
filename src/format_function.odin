package kessel

import "core:strings"

// Function declarations and expressions, parameters and arrow functions.
// Ports of Prettier's function, function-parameters and arrow-function rules.

format_function :: proc(f: ^FormatContext, node: ^FunctionExpression, args: FormatArgs) -> Doc {
	// A callback that is the last argument keeps its parameters on one line
	// when the call has other arguments or the parameters are plain names.
	expand_arg := false
	parent := format_parent(f)
	if args.expand_last_arg && parent.kind == .Call {
		call := parent.expr^.(^CallExpression)
		expand_arg = len(call.arguments) > 1 || format_params_are_identifiers(node.params[:])
	}
	head := "function* " if node.generator else "function "
	name: Doc
	if id, named := node.id.?; named {name = ft(f, id.name)}
	return fc(
		f,
		ft(f, "declare ") if node.declare else nil,
		ft(f, "async ") if node.async else nil,
		ft(f, head),
		name,
		format_type_parameters(f, node.type_parameters),
		format_function_signature(f, node, expand_arg),
		format_function_end(f, node),
	)
}

// The parameters and return type of a function, grouped so that the
// parameters break before the return type does.
format_function_signature :: proc(
	f: ^FormatContext,
	node: ^FunctionExpression,
	expand_arg: bool,
) -> Doc {
	parameters := format_function_params(f, node.params[:], expand_arg)
	returned := format_return_type(f, node.return_type)
	returned_type := format_annotation_type(node.return_type)
	if format_should_group_params(node.type_parameters, len(node.params), returned_type, returned) {
		parameters = doc_group(f, parameters)
	}
	return fg(f, parameters, returned)
}

// The body of a function, or the semicolon of a declaration without one.
@(private = "file")
format_function_end :: proc(f: ^FormatContext, node: ^FunctionExpression) -> Doc {
	if node.no_body {return ft(f, ";")}
	body := format_function_body(f, &node.body)
	// An ambient function with a body is an error that Prettier still prints.
	return fc(f, ft(f, " "), body, ft(f, ";") if node.declare else nil)
}

@(private = "file")
format_params_are_identifiers :: proc(params: []FunctionParameter) -> bool {
	for param in params {
		if _, defaulted := param.default_val.?; defaulted {return false}
		identifier, plain := param.pattern.(^Identifier)
		if !plain {return false}
		if _, typed := identifier.type_annotation.?; typed {return false}
	}
	return true
}

// True when every parameter is a plain name, typed or not.
@(private = "file")
format_params_are_names :: proc(params: []FunctionParameter) -> bool {
	for param in params {
		if _, defaulted := param.default_val.?; defaulted {return false}
		if _, plain := param.pattern.(^Identifier); !plain {return false}
	}
	return true
}

format_function_body :: proc(f: ^FormatContext, body: ^FunctionBody) -> Doc {
	// The parser keeps directives in the statement list. A separate list
	// would mean a tree shape this printer has not seen.
	if len(body.directives) > 0 {return format_fail(f)}
	if !format_path_push(f, {kind = .Block, key = .Body}) {return nil}
	defer format_path_pop(f)
	return format_block(f, body.body[:], true, body.loc)
}

// The default value of a parameter, whichever way the parser stored it.
@(private = "file")
format_param_parts :: proc(param: ^FunctionParameter) -> (pattern: Pattern, value: ^Expression) {
	pattern = param.pattern
	if default_value, present := param.default_val.?; present && default_value != nil {
		return pattern, default_value
	}
	if assignment, is_assignment := pattern.(^AssignmentPattern); is_assignment {
		return assignment.left, assignment.right
	}
	return pattern, nil
}

@(private = "file")
format_param :: proc(f: ^FormatContext, param: ^FunctionParameter) -> Doc {
	if param.optional_destructuring {return format_fail(f)}
	decorators := format_param_decorators(f, param)
	modifiers := format_param_modifiers(f, param)
	pattern, value := format_param_parts(param)
	if value == nil {
		printed := fc(f, modifiers, format_pattern(f, pattern, .Params))
		if decorators == nil {return printed}
		return fg(f, decorators, printed)
	}
	if !format_path_push(f, {kind = .Assignment_Pattern, key = .Params}) {return nil}
	defer format_path_pop(f)
	left := format_pattern(f, pattern, .Left)
	printed := fc(f, modifiers, left, ft(f, " = "), format_expr(f, value, .Right))
	if decorators == nil {return printed}
	return fg(f, decorators, printed)
}

// The decorators of a parameter with the line that follows them, or nil.
// The parser keeps them beside the tree, keyed by where the parameter
// starts, so a parameter whose text starts with `@` must find them there.
@(private = "file")
format_param_decorators :: proc(f: ^FormatContext, param: ^FunctionParameter) -> Doc {
	start := param.loc.start
	if param.modifier_start != 0 {start = min(start, param.modifier_start)}
	decorators, decorated := f.param_decorators[start]
	if !decorated || len(decorators) == 0 {
		// A decorator that ends right in front of the parameter is one that
		// the lookup missed, and printing without it would drop it.
		before := strings.trim_right(f.source[:start], " \t\r\n")
		if strings.has_suffix(before, ")") || format_ends_with_decorator_name(before) {
			return format_fail(f)
		}
		return nil
	}
	list, own_line := format_decorators(f, decorators[:])
	return fc(f, doc_break_parent() if own_line else nil, list, doc_line())
}

// True when the text ends with `@name` or `@a.b`.
@(private = "file")
format_ends_with_decorator_name :: proc(text: string) -> bool {
	for index := len(text); index > 0; index -= 1 {
		char := text[index - 1]
		if char == '@' {return index < len(text)}
		is_name := char == '.' || char == '$' || char >= 0x80 || is_id_cont_codepoint(u32(char))
		if !is_name {return false}
	}
	return false
}

// `private readonly` and the like in front of a constructor parameter that
// declares a property.
@(private = "file")
format_param_modifiers :: proc(f: ^FormatContext, param: ^FunctionParameter) -> Doc {
	accessibility: Doc
	switch param.accessibility {
	case .None:
	case .Public: accessibility = ft(f, "public ")
	case .Private: accessibility = ft(f, "private ")
	case .Protected: accessibility = ft(f, "protected ")
	}
	return fc(
		f,
		accessibility,
		ft(f, "override ") if param.override_ else nil,
		ft(f, "readonly ") if param.readonly else nil,
	)
}

format_param_is_property :: proc(param: FunctionParameter) -> bool {
	return param.accessibility != .None || param.readonly || param.override_
}

// A lone destructuring parameter hugs the parentheses: `({ a, b }) => …`.
// So does a lone name annotated with an object type.
format_should_hug_only_param :: proc(params: []FunctionParameter) -> bool {
	if len(params) != 1 {return false}
	param := params[0]
	if format_param_is_property(param) {return false}
	pattern, value := format_param_parts(&param)
	#partial switch node in pattern {
	case ^ObjectPattern, ^ArrayPattern:
	case ^Identifier:
		if value != nil {return false}
		return format_type_is_object(format_annotation_type(node.type_annotation))
	case:
		return false
	}
	if value == nil {return true}
	inner := format_expr_unwrap(value)
	if inner == nil {return false}
	#partial switch node in inner^ {
	case ^Identifier: return true
	case ^ObjectExpression: return len(node.properties) == 0
	case ^ArrayExpression: return len(node.elements) == 0
	}
	return false
}

// A curried call such as `const useStore = create()((set) => {…})` lets the
// callback's parameters break even though the callback hugs.
@(private = "file")
format_params_may_break_when_hugged :: proc(f: ^FormatContext) -> bool {
	current := format_path_at(f, 0)
	parent := format_parent(f)
	if current.kind != .Arrow_Function || parent.kind != .Call || current.key != .Arguments {
		return false
	}
	arrow := current.expr^.(^ArrowFunctionExpression)
	if _, block := arrow.body.(^BlockStatement); !block {return false}
	call := parent.expr^.(^CallExpression)
	if len(call.arguments) != 1 || call.callee == nil {return false}
	inner_call, curried := call.callee^.(^CallExpression)
	if !curried || inner_call.callee == nil {return false}
	#partial switch callee in inner_call.callee^ {
	case ^Identifier:
	case ^MemberExpression:
		if callee.computed || callee.object == nil || callee.property == nil {return false}
		_, object_plain := callee.object^.(^Identifier)
		_, property_plain := callee.property^.(^Identifier)
		if !object_plain || !property_plain {return false}
	case:
		return false
	}
	owner := format_path_at(f, 2)
	#partial switch owner.kind {
	case .Variable_Declarator:
		if parent.key != .Init {return false}
	case .Export_Default:
		if parent.key != .Declaration {return false}
	case .Assignment:
		if parent.key != .Right {return false}
		assignment := owner.expr^.(^AssignmentExpression)
		if format_member_text(assignment.left) != "module.exports" {return false}
	case:
		return false
	}
	declaration := format_path_at(f, 3)
	if declaration.kind != .Variable_Declaration {return true}
	node := cast(^VariableDeclaration)declaration.node
	return node != nil && node.kind == .Const && len(node.declarations) == 1
}

// "a.b" for a plain two-part member access, otherwise "".
@(private = "file")
format_member_text :: proc(expr: ^Expression) -> string {
	node := format_expr_unwrap(expr)
	if node == nil {return ""}
	member, is_member := node^.(^MemberExpression)
	if !is_member || member.computed || member.object == nil || member.property == nil {return ""}
	object, object_plain := member.object^.(^Identifier)
	property, property_plain := member.property^.(^Identifier)
	if !object_plain || !property_plain {return ""}
	if object.name == "module" && property.name == "exports" {return "module.exports"}
	return ""
}

// Parameters that are printed and ready to lay out.
FormatParams :: struct {
	docs:            []Doc,
	// Where each parameter ends in the source.
	ends:            []u32,
	hug_only:        bool,
	has_rest:        bool,
	// Type parameters that print in front of the parentheses as part of the
	// same group, as those of arrow functions and signatures do.
	type_parameters: Doc,
}

format_function_params :: proc(
	f: ^FormatContext,
	params: []FunctionParameter,
	expand_arg: bool,
	type_parameters: Doc = nil,
) -> Doc {
	count := len(params)
	list := FormatParams {
		docs            = make([]Doc, count, f.alloc),
		ends            = make([]u32, count, f.alloc),
		hug_only        = format_should_hug_only_param(params),
		type_parameters = type_parameters,
	}
	saved_pattern, saved_type := f.hug_pattern, f.hug_type
	defer f.hug_pattern, f.hug_type = saved_pattern, saved_type
	if list.hug_only {
		// A decorated parameter does not hug.
		start := params[0].loc.start
		if params[0].modifier_start != 0 {start = min(start, params[0].modifier_start)}
		_, decorated := f.param_decorators[start]
		list.hug_only = !decorated
	}
	if list.hug_only {
		#partial switch pattern in params[0].pattern {
		case ^ObjectPattern:
			f.hug_pattern = pattern
			f.hug_type = format_annotation_literal(pattern.type_annotation)
		case ^ArrayPattern:
			f.hug_type = format_annotation_literal(pattern.type_annotation)
		case ^Identifier:
			f.hug_type = format_annotation_literal(pattern.type_annotation)
		}
	}
	for &param, index in params {
		list.docs[index] = format_param(f, &param)
		list.ends[index] = param.loc.end
	}
	if count > 0 {_, list.has_rest = params[count - 1].pattern.(^RestElement)}
	return format_params_layout(f, list, expand_arg)
}

// Lays out a parameter list. The path holds the function, and its parent
// decides the test-call layout.
format_params_layout :: proc(f: ^FormatContext, list: FormatParams, expand_arg: bool) -> Doc {
	assert(len(list.docs) == len(list.ends))
	count := len(list.docs)
	generics := list.type_parameters
	if count == 0 {return fc(f, generics, ft(f, "()"))}
	parent := format_parent(f)
	hug_test := parent.expr != nil && format_is_test_call(f, parent.expr, nil)
	printed := make([dynamic]Doc, f.alloc)
	for doc, index in list.docs {
		append(&printed, doc)
		if index == count - 1 {break}
		append(&printed, ft(f, ","))
		if hug_test || list.hug_only {
			append(&printed, ft(f, " "))
		} else if format_is_next_line_empty(f.source, list.ends[index]) {
			append(&printed, doc_hardline(), doc_hardline())
		} else {
			append(&printed, doc_line())
		}
	}
	joined := fc(f, ..printed[:])
	if expand_arg && !format_params_may_break_when_hugged(f) {
		if doc_will_break(joined) || doc_will_break(generics) {
			f.bailout = true
			return nil
		}
		flat := doc_remove_lines(f, joined)
		return fg(f, doc_remove_lines(f, generics), ft(f, "("), flat, ft(f, ")"))
	}
	if list.hug_only || hug_test {return fc(f, generics, ft(f, "("), joined, ft(f, ")"))}
	trailing_comma: Doc
	if !list.has_rest && f.options.trailing_comma && !f.options.trailing_comma_es5 {
		trailing_comma = doc_if_break(f, ft(f, ","))
	}
	return fc(
		f,
		generics,
		ft(f, "("),
		fi(f, doc_softline(), joined),
		trailing_comma,
		doc_softline(),
		ft(f, ")"),
	)
}

// ---------------------------------------------------------------------------
// Arrow functions
// ---------------------------------------------------------------------------

@(private = "file")
format_arrow_signature :: proc(
	f: ^FormatContext,
	node: ^ArrowFunctionExpression,
	args: FormatArgs,
) -> Doc {
	expand_arg := args.expand_last_arg || args.expand_first_arg
	returned := format_return_type(f, node.return_type)
	if expand_arg && returned != nil {
		// A hugged callback keeps its whole signature on one line.
		if doc_will_break(returned) {
			f.bailout = true
			return nil
		}
		returned = doc_group(f, doc_remove_lines(f, returned))
	}
	generics := format_type_parameters(f, node.type_parameters)
	params := fg(f, format_function_params(f, node.params[:], expand_arg, generics), returned)
	return fc(f, ft(f, "async ") if node.async else nil, params)
}

// A conditional body is wrapped in parentheses when it stays on one line,
// unless it starts with an object, which gets its own parentheses.
@(private = "file")
format_arrow_body_wants_parens :: proc(body: ^Expression) -> bool {
	node := format_expr_unwrap(body)
	if node == nil {return false}
	if _, conditional := node^.(^ConditionalExpression); !conditional {return false}
	leftmost := format_expr_leftmost(node)
	if leftmost == nil {return true}
	_, object := leftmost^.(^ObjectExpression)
	return !object
}

// Bodies that open with a short prefix and then break on their own stay on
// the arrow's line.
@(private = "file")
format_arrow_body_stays_on_line :: proc(f: ^FormatContext, body: ^Expression) -> bool {
	node := format_expr_unwrap(body)
	if node == nil {return false}
	#partial switch _ in node^ {
	case ^ArrayExpression, ^ObjectExpression, ^ArrowFunctionExpression, ^JSXElement, ^JSXFragment,
	     ^SequenceExpression:
		return true
	}
	return format_is_template_on_its_own_line(f, node)
}

format_arrow :: proc(f: ^FormatContext, node: ^ArrowFunctionExpression, args: FormatArgs) -> Doc {
	current := format_path_at(f, 0)
	parent := format_parent(f)
	key := current.key
	parent_is_call_like := parent.kind == .Call || parent.kind == .New
	parent_is_call_like = parent_is_call_like || parent.kind == .Import_Expression
	parent_is_binaryish := parent.kind == .Binary || parent.kind == .Logical

	signatures := make([dynamic]Doc, f.alloc)
	should_break_chain := false
	is_chain := !args.expand_last_arg && format_arrow_body_is_arrow(node)
	tail := node
	pushed := 0
	defer for _ in 0 ..< pushed {format_path_pop(f)}
	for {
		append(&signatures, format_arrow_signature(f, tail, args))
		if !is_chain {break}
		if !format_params_are_names(tail.params[:]) {should_break_chain = true}
		if _, typed := tail.return_type.?; typed && len(tail.params) > 0 {
			should_break_chain = true
		}
		if !format_arrow_body_is_arrow(tail) {break}
		inner, entered := format_expr_enter(f, tail.body.(^Expression), .Body)
		if !entered {return nil}
		pushed += 1
		tail = inner^.(^ArrowFunctionExpression)
	}

	body_doc: Doc
	on_same_line := false
	wants_parens := false
	switch body in tail.body {
	case ^BlockStatement:
		if !format_path_push(f, {kind = .Block, key = .Body, node = body}) {return nil}
		body_doc = format_block(f, body.body[:], true, body.loc)
		format_path_pop(f)
		on_same_line = true
	case ^Expression:
		body_doc = format_expr(f, body, .Body, args)
		wants_parens = format_arrow_body_wants_parens(body)
		on_same_line = format_arrow_body_stays_on_line(f, body)
		on_same_line = on_same_line || (!should_break_chain && wants_parens)
	}

	is_callee := key == .Callee && parent_is_call_like
	chain_id := doc_group_id(f)
	hangs_off_parent := (key != .Callee && parent_is_call_like) || parent_is_binaryish
	chain := format_arrow_chain(
		f,
		signatures[:],
		should_break_chain,
		hangs_off_parent,
		is_callee || args.layout != .None,
	)
	should_break_signatures := false
	if is_chain && (is_callee || args.layout != .None) {
		chain = fi(f, doc_softline(), chain)
		should_break_signatures =
			args.layout == .Chain_Tail_Arrow_Chain || (is_callee && !on_same_line)
	}
	in_jsx := parent.kind == .JSX_Expression_Container
	body := format_arrow_body(f, body_doc, on_same_line, wants_parens, args.expand_last_arg, in_jsx)
	return fg(
		f,
		doc_group(f, chain, should_break_signatures, chain_id),
		ft(f, " =>"),
		doc_indent_if_break(f, body, chain_id) if is_chain else doc_group(f, body),
		doc_if_break(f, doc_softline(), nil, chain_id) if is_chain && is_callee else nil,
	)
}

// The signatures of an arrow chain, `a => b => c =>`, one per line when the
// chain breaks. How far the later ones indent depends on what the chain
// hangs off.
@(private = "file")
format_arrow_chain :: proc(
	f: ^FormatContext,
	signatures: []Doc,
	should_break: bool,
	hangs_off_parent: bool,
	flush: bool,
) -> Doc {
	assert(len(signatures) > 0)
	if len(signatures) == 1 {return signatures[0]}
	separator := fc(f, ft(f, " =>"), doc_line())
	if hangs_off_parent {
		rest := doc_join(f, separator, signatures[1:])
		contents := fc(f, signatures[0], ft(f, " =>"), fi(f, doc_line(), rest))
		return doc_group(f, contents, should_break)
	}
	joined := doc_join(f, separator, signatures)
	if flush {return doc_group(f, joined, should_break)}
	return doc_group(f, doc_indent(f, joined), should_break)
}

// The body after `=>`: on the arrow's line, or indented on the next one. A
// callback that hugs its call ends with the call's trailing comma.
@(private = "file")
format_arrow_body :: proc(
	f: ^FormatContext,
	body_doc: Doc,
	on_same_line, wants_parens, expand_last_arg, in_container: bool,
) -> Doc {
	trailing_comma: Doc
	if expand_last_arg && f.options.trailing_comma && !f.options.trailing_comma_es5 {
		trailing_comma = doc_if_break(f, ft(f, ","))
	}
	// The braces of a JSX expression close on a line of their own too.
	trailing_space := doc_softline() if expand_last_arg || in_container else nil
	if on_same_line && wants_parens {
		return fc(
			f,
			ft(f, " "),
			fg(
				f,
				doc_if_break(f, nil, ft(f, "(")),
				fi(f, doc_softline(), body_doc),
				doc_if_break(f, nil, ft(f, ")")),
				trailing_comma,
				trailing_space,
			),
		)
	}
	if on_same_line {return fc(f, ft(f, " "), body_doc)}
	return fc(f, fi(f, doc_line(), body_doc), trailing_comma, trailing_space)
}

@(private = "file")
format_arrow_body_is_arrow :: proc(node: ^ArrowFunctionExpression) -> bool {
	body, is_expression := node.body.(^Expression)
	if !is_expression {return false}
	inner := format_expr_unwrap(body)
	if inner == nil {return false}
	_, arrow := inner^.(^ArrowFunctionExpression)
	return arrow
}
