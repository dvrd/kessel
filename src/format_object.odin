package kessel

import "core:strings"

// Objects, arrays, binding patterns and template literals. Ports of
// Prettier's object, property, array and template-literal rules.

@(private = "file")
FormatObjectItem :: struct {
	doc: Doc,
	end: u32,
}

// Properties separated by commas, with one blank line kept wherever the
// source has one. `hug` leaves the braces to the enclosing group.
@(private = "file")
format_object_body :: proc(
	f: ^FormatContext,
	items: []FormatObjectItem,
	should_break: bool,
	trailing_comma: bool,
	hug: bool,
) -> Doc {
	if len(items) == 0 {return ft(f, "{}")}
	parts := make([dynamic]Doc, f.alloc)
	for item, index in items {
		if index > 0 {
			append(&parts, ft(f, ","), doc_line())
			if format_is_next_line_empty(f.source, items[index - 1].end) {
				append(&parts, doc_hardline())
			}
		}
		append(&parts, doc_group(f, item.doc))
	}
	space := doc_line() if f.options.bracket_spacing else doc_softline()
	comma: Doc
	if trailing_comma && f.options.trailing_comma {comma = doc_if_break(f, ft(f, ","))}
	contents := fc(f, ft(f, "{"), fi(f, space, fc(f, ..parts[:])), comma, space, ft(f, "}"))
	if hug {return contents}
	return doc_group(f, contents, should_break)
}

format_object :: proc(f: ^FormatContext, node: ^ObjectExpression) -> Doc {
	if !format_is_delimited(f, node.loc, '{', '}') {return format_fail(f)}
	count := len(node.properties)
	starts := make([]u32, count, f.alloc)
	ends := make([]u32, count, f.alloc)
	for property, index in node.properties {
		starts[index], ends[index] = property.loc.start, property.loc.end
	}
	bounds := FormatListBounds{open = node.loc.start + 1, close = node.loc.end - 1}
	comments, dangling := format_list_comments(f, bounds, starts, ends)
	if count == 0 && dangling != nil {
		return fg(f, ft(f, "{"), fi(f, doc_hardline(), dangling), doc_softline(), ft(f, "}"))
	}
	items := make([]FormatObjectItem, count, f.alloc)
	for &property, index in node.properties {
		printed := format_with_comments(f, comments[index], format_property(f, &property))
		items[index] = {printed, property.loc.end}
	}
	// An object written across several lines stays expanded.
	should_break := false
	if count > 0 {
		first := node.properties[0].loc.start
		should_break = format_has_newline_in_range(f.source, node.loc.start, first)
	}
	return format_object_body(f, items, should_break, true, false)
}

// Whether a quoted key may lose its quotes: a plain ASCII identifier, or a
// number whose text survives a round trip through a JavaScript number.
@(private = "file")
format_key_unquoted :: proc(f: ^FormatContext, raw: string) -> (text: string, ok: bool) {
	if len(raw) < 3 {return "", false}
	content := raw[1:len(raw) - 1]
	digits, dots, others := 0, 0, 0
	for index in 0 ..< len(content) {
		char := content[index]
		switch {
		case char >= 0x80:
			// Prettier tests against an ES5 identifier table that this
			// printer does not carry.
			f.failed = true
			return "", false
		case char >= '0' && char <= '9':
			digits += 1
		case char == '.':
			dots += 1
		case (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') || char == '_' ||
		     char == '$':
			others += 1
		case:
			return "", false
		}
	}
	first := content[0]
	if others > 0 {
		if dots > 0 || (first >= '0' && first <= '9') {return "", false}
		return content, true
	}
	// Digits and dots only: `1`, `1.5`. Reject forms a number would print
	// differently, such as `01`, `1.` or `1.50`.
	if f.typescript {return "", false}
	if dots > 1 || first == '.' || content[len(content) - 1] == '.' {return "", false}
	if first == '0' && len(content) > 1 && content[1] != '.' {return "", false}
	if dots == 1 && content[len(content) - 1] == '0' {return "", false}
	if digits > 15 {
		// Beyond double precision the round trip needs real arithmetic.
		f.failed = true
		return "", false
	}
	return content, true
}

format_property_key :: proc(f: ^FormatContext, key: ^Expression, computed: bool) -> Doc {
	if key == nil {return format_fail(f)}
	if computed {return fc(f, ft(f, "["), format_expr(f, key, .Key), ft(f, "]"))}
	#partial switch node in key^ {
	case ^Identifier:
		if node.has_escape {return format_fail(f)}
		return ft(f, node.name)
	case ^StringLiteral:
		if strings.contains_any(node.raw, "\\\r\n") {return format_string_literal(f, node)}
		if text, unquoted := format_key_unquoted(f, node.raw); unquoted {return ft(f, text)}
		return format_string_literal(f, node)
	case ^NumericLiteral:
		return ft(f, format_number(f, node.raw))
	}
	return format_expr(f, key, .Key)
}

@(private = "file")
format_property :: proc(f: ^FormatContext, property: ^Property) -> Doc {
	if property.value == nil {return format_fail(f)}
	if property.key == nil {
		// A spread element.
		if _, spread := property.value^.(^SpreadElement); !spread {return format_fail(f)}
		return format_expr(f, property.value, .Properties)
	}
	if property.kind != .Init {return format_object_method(f, property)}
	if !format_path_push(f, {kind = .Property, key = .Properties, node = property}) {return nil}
	defer format_path_pop(f)
	if property.shorthand {
		// `{ a = 1 }` exists only in destructuring assignment targets.
		if _, plain := property.value^.(^Identifier); !plain {return format_fail(f)}
		return format_expr(f, property.value, .Value)
	}
	key := format_property_key(f, property.key, property.computed)
	return format_assignment_like(
		f,
		FormatAssignment{kind = .Property, left = key, right = property.value},
	)
}

@(private = "file")
format_object_method :: proc(f: ^FormatContext, property: ^Property) -> Doc {
	function, is_function := property.value^.(^FunctionExpression)
	if !is_function {return format_fail(f)}
	if !format_path_push(f, {kind = .Object_Method, key = .Properties, node = property}) {
		return nil
	}
	defer format_path_pop(f)
	prefix: Doc
	#partial switch property.kind {
	case .Get: prefix = ft(f, "get ")
	case .Set: prefix = ft(f, "set ")
	case .Method:
		if function.async {prefix = ft(f, "async ")}
	}
	return fc(
		f,
		prefix,
		ft(f, "*") if function.generator else nil,
		format_property_key(f, property.key, property.computed),
		format_method_value(f, function),
	)
}

// The parameters and body of a method, after its name.
format_method_value :: proc(f: ^FormatContext, function: ^FunctionExpression) -> Doc {
	if _, typed := function.type_parameters.?; typed {return format_fail(f)}
	if _, typed := function.return_type.?; typed {return format_fail(f)}
	if function.no_body {return format_fail(f)}
	return fc(
		f,
		fg(f, format_function_params(f, function.params[:], false)),
		ft(f, " "),
		format_function_body(f, &function.body),
	)
}

// ---------------------------------------------------------------------------
// Patterns
// ---------------------------------------------------------------------------

format_pattern :: proc(f: ^FormatContext, pattern: Pattern, key: FormatKey) -> Doc {
	switch node in pattern {
	case ^Identifier:
		if node == nil || node.has_escape || node.optional {return format_fail(f)}
		if _, typed := node.type_annotation.?; typed {return format_fail(f)}
		if node.name == "let" {return format_fail(f)}
		return ft(f, node.name)
	case ^ObjectPattern:
		return format_object_pattern(f, node, key)
	case ^ArrayPattern:
		return format_array_pattern(f, node, key)
	case ^AssignmentPattern:
		if !format_path_push(f, {kind = .Assignment_Pattern, key = key, node = node}) {return nil}
		defer format_path_pop(f)
		return fc(
			f,
			format_pattern(f, node.left, .Left),
			ft(f, " = "),
			format_expr(f, node.right, .Right),
		)
	case ^RestElement:
		if !format_path_push(f, {kind = .Rest_Element, key = key, node = node}) {return nil}
		defer format_path_pop(f)
		return fc(f, ft(f, "..."), format_pattern(f, node.argument, .Argument))
	case ^MemberExpression:
		// Only assignment targets hold members, and those are not printed
		// as patterns yet.
		return format_fail(f)
	}
	return format_fail(f)
}

@(private = "file")
format_pattern_key :: proc(f: ^FormatContext, property: ^ObjectPatternProperty) -> Doc {
	key, _ := property.key.?
	switch node in key {
	case IdentifierName:
		if property.computed {return fc(f, ft(f, "["), ft(f, node.name), ft(f, "]"))}
		return ft(f, node.name)
	case ^StringLiteral:
		if property.computed {
			return fc(f, ft(f, "["), format_string_literal(f, node), ft(f, "]"))
		}
		if strings.contains_any(node.raw, "\\\r\n") {return format_string_literal(f, node)}
		if text, unquoted := format_key_unquoted(f, node.raw); unquoted {return ft(f, text)}
		return format_string_literal(f, node)
	case ^NumericLiteral:
		if property.computed {return format_fail(f)}
		return ft(f, format_number(f, node.raw))
	case ^Expression:
		return format_property_key(f, node, property.computed)
	}
	return format_fail(f)
}

@(private = "file")
format_object_pattern :: proc(f: ^FormatContext, node: ^ObjectPattern, key: FormatKey) -> Doc {
	if _, typed := node.type_annotation.?; typed {return format_fail(f)}
	parent_kind := format_path_at(f, 0).kind
	if !format_path_push(f, {kind = .Object_Pattern, key = key, node = node}) {return nil}
	defer format_path_pop(f)
	items := make([]FormatObjectItem, len(node.properties), f.alloc)
	has_rest := false
	nested := false
	for &property, index in node.properties {
		doc: Doc
		if _, has_key := property.key.?; !has_key {
			doc = format_pattern(f, property.value, .Properties)
			has_rest = index == len(node.properties) - 1
		} else if property.shorthand {
			doc = format_pattern(f, property.value, .Value)
		} else {
			#partial switch _ in property.value {
			case ^ObjectPattern, ^ArrayPattern: nested = true
			}
			left := format_pattern_key(f, &property)
			right := format_pattern(f, property.value, .Value)
			short_key := false
			if text, plain := doc_plain_text(f, left); plain {
				short_key = format_width(text) < int(f.options.tab_width) + 3
			}
			layout := FormatAssignLayout.Fluid
			if short_key && !doc_can_break(left) {layout = .Never_Break_After_Operator}
			doc = format_assignment_render(f, layout, left, ft(f, ":"), right)
		}
		items[index] = {doc, property.loc.end}
	}
	// A destructuring declaration with a nested pattern expands, so that
	// each level of nesting is visible.
	should_break := nested
	#partial switch parent_kind {
	case .Function_Declaration, .Function_Expression, .Arrow_Function, .Object_Method,
	     .Class_Method, .Assignment_Pattern, .Catch_Clause:
		should_break = false
	}
	hug := f.hug_pattern == rawptr(node)
	if !should_break && parent_kind == .Variable_Declarator {hug = true}
	return format_object_body(f, items, should_break, !has_rest, hug)
}

// ---------------------------------------------------------------------------
// Arrays
// ---------------------------------------------------------------------------

@(private = "file")
FormatArrayItem :: struct {
	doc:     Doc,
	present: bool,
	end:     u32,
	start:   u32,
}

// A blank line after the comma that follows an element.
@(private = "file")
format_array_line_after_is_empty :: proc(f: ^FormatContext, item: FormatArrayItem) -> bool {
	if item.start == item.end {return false}
	// Comments never sit here, because statements with comments are not
	// formatted, so the scan to the comma only steps over code.
	index := int(item.end)
	for index < len(f.source) && f.source[index] != ',' {index += 1}
	if index >= len(f.source) || f.source[index] != ',' {return false}
	return format_is_next_line_empty(f.source, u32(index))
}

@(private = "file")
format_array_body :: proc(
	f: ^FormatContext,
	items: []FormatArrayItem,
	should_break: bool,
	concise: bool,
	can_trail: bool,
) -> Doc {
	if len(items) == 0 {return ft(f, "[]")}
	id := doc_group_id(f)
	last := items[len(items) - 1]
	trailing: Doc
	if can_trail {
		if !last.present {
			trailing = ft(f, ",")
		} else if f.options.trailing_comma {
			trailing = doc_if_break(f, ft(f, ","), nil, id if concise else 0)
		}
	}
	contents: Doc
	if concise {
		parts := make([dynamic]Doc, f.alloc)
		for item, index in items {
			is_last := index == len(items) - 1
			append(&parts, fc(f, item.doc, trailing if is_last else ft(f, ",")))
			if is_last {break}
			if format_array_line_after_is_empty(f, item) {
				append(&parts, fc(f, doc_hardline(), doc_hardline()))
			} else {
				append(&parts, doc_line())
			}
		}
		contents = doc_fill(f, parts[:])
	} else {
		parts := make([dynamic]Doc, f.alloc)
		for item, index in items {
			if item.present {append(&parts, doc_group(f, item.doc))}
			if index == len(items) - 1 {break}
			append(&parts, ft(f, ","), doc_line())
			if item.present && format_array_line_after_is_empty(f, item) {
				append(&parts, doc_softline())
			}
		}
		contents = fc(f, fc(f, ..parts[:]), trailing)
	}
	return doc_group(
		f,
		fc(f, ft(f, "["), fi(f, doc_softline(), contents), doc_softline(), ft(f, "]")),
		should_break,
		id,
	)
}

// Rows of arrays or of objects, each with several entries, print one row
// per line.
@(private = "file")
format_array_is_matrix :: proc(node: ^ArrayExpression) -> bool {
	if len(node.elements) <= 1 {return false}
	first_kind := FormatNodeKind.Other
	for element, index in node.elements {
		value, present := element.?
		if !present || value == nil {return false}
		inner := format_expr_unwrap(value)
		if inner == nil {return false}
		kind: FormatNodeKind
		#partial switch row in inner^ {
		case ^ArrayExpression:
			if len(row.elements) <= 1 {return false}
			kind = .Array
		case ^ObjectExpression:
			if len(row.properties) <= 1 {return false}
			kind = .Object
		case:
			return false
		}
		if index == 0 {first_kind = kind}
		if kind != first_kind {return false}
	}
	return true
}

format_array :: proc(f: ^FormatContext, node: ^ArrayExpression) -> Doc {
	items := make([]FormatArrayItem, len(node.elements), f.alloc)
	for element, index in node.elements {
		value, present := element.?
		if !present || value == nil {continue}
		loc := get_expression_loc(value)
		items[index] = {format_expr(f, value, .Elements), true, loc.end, loc.start}
	}
	concise := format_is_concisely_printed_array(format_path_at(f, 0).expr)
	return format_array_body(f, items, format_array_is_matrix(node), concise, true)
}

@(private = "file")
format_array_pattern :: proc(f: ^FormatContext, node: ^ArrayPattern, key: FormatKey) -> Doc {
	if _, typed := node.type_annotation.?; typed {return format_fail(f)}
	if !format_path_push(f, {kind = .Array_Pattern, key = key, node = node}) {return nil}
	defer format_path_pop(f)
	items := make([]FormatArrayItem, len(node.elements), f.alloc)
	can_trail := true
	for element, index in node.elements {
		value, present := element.?
		if !present {continue}
		loc := get_pattern_loc(value)
		items[index] = {format_pattern(f, value, .Elements), true, loc.end, loc.start}
		if _, rest := value.(^RestElement); rest && index == len(node.elements) - 1 {
			can_trail = false
		}
	}
	return format_array_body(f, items, false, false, can_trail)
}

// ---------------------------------------------------------------------------
// Template literals
// ---------------------------------------------------------------------------

// The width of the indentation of the last line of a template's text.
@(private = "file")
format_template_indent :: proc(text: string, tab_width: int) -> int {
	line_start := strings.last_index_byte(text, '\n') + 1
	if line_start == 0 {return 0}
	size := 0
	for index in line_start ..< len(text) {
		switch text[index] {
		case '\t': size = size + tab_width - (size % max(tab_width, 1))
		case ' ': size += 1
		case: return size
		}
	}
	return size
}

@(private = "file")
format_template_has_text_newline :: proc(text: string) -> bool {
	return strings.contains_any(text, "\r\n")
}

// An interpolation written on one line prints on one line however long it
// is. One written across lines may break like any other expression.
@(private = "file")
format_template_expression :: proc(
	f: ^FormatContext,
	node: ^TemplateLiteral,
	index: int,
	indent_size: int,
) -> Doc {
	expression := node.expressions[index]
	printed := format_expr(f, expression, .Expressions)
	if f.failed {return nil}
	quasi := node.quasis[index]
	next := node.quasis[index + 1]
	has_newline := format_has_newline_in_range(f.source, quasi.loc.end, next.loc.start)
	if !has_newline {
		wide := f.options
		wide.print_width = max(i32)
		out := strings.builder_make(f.alloc)
		format_doc_print(&out, printed, wide, 0, "\n", f.alloc)
		text := strings.to_string(out)
		if strings.contains_rune(text, '\n') {
			has_newline = true
		} else {
			printed = ft(f, text)
		}
	}
	if has_newline {
		inner := format_expr_strip(expression)
		indent := false
		#partial switch _ in inner^ {
		case ^Identifier, ^MemberExpression, ^ConditionalExpression, ^SequenceExpression,
		     ^TSAsExpression, ^TSSatisfiesExpression, ^BinaryExpression, ^LogicalExpression:
			indent = true
		}
		if indent {printed = fc(f, fi(f, doc_softline(), printed), doc_softline())}
	}
	tab_width := int(f.options.tab_width)
	aligned := printed
	if indent_size == 0 && strings.has_suffix(quasi.raw, "\n") {
		aligned = doc_align(f, FORMAT_ALIGN_DEDENT_TO_ROOT, printed)
	} else if indent_size > 0 && tab_width > 0 {
		for _ in 0 ..< indent_size / tab_width {aligned = doc_indent(f, aligned)}
		aligned = doc_align(f, i32(indent_size % tab_width), aligned)
		aligned = doc_align(f, FORMAT_ALIGN_DEDENT_TO_ROOT, aligned)
	}
	return fg(f, ft(f, "${"), aligned, doc_line_suffix_boundary(), ft(f, "}"))
}

format_template :: proc(f: ^FormatContext, node: ^TemplateLiteral) -> Doc {
	if len(node.quasis) != len(node.expressions) + 1 {return format_fail(f)}
	parts := make([dynamic]Doc, f.alloc)
	append(&parts, doc_line_suffix_boundary(), ft(f, "`"))
	indent_size := 0
	for quasi, index in node.quasis {
		append(&parts, doc_literal_text(f, quasi.raw))
		if index == len(node.quasis) - 1 {break}
		if format_template_has_text_newline(quasi.raw) {
			indent_size = format_template_indent(quasi.raw, int(f.options.tab_width))
		}
		append(&parts, format_template_expression(f, node, index, indent_size))
	}
	append(&parts, ft(f, "`"))
	return fc(f, ..parts[:])
}

// Prettier formats the contents of these templates as CSS, GraphQL, HTML or
// Markdown, and lays out `describe.each` tables. None of that is ported.
@(private = "file")
format_tag_is_special :: proc(tag: ^Expression) -> bool {
	node := format_expr_strip(tag)
	for node != nil {
		#partial switch inner in node^ {
		case ^Identifier:
			switch inner.name {
			case "css", "styled", "graphql", "gql", "html", "markdown", "md": return true
			}
			return false
		case ^MemberExpression:
			if inner.property != nil {
				if property, named := inner.property^.(^Identifier); named {
					if property.name == "each" {return true}
				}
			}
			node = format_expr_strip(inner.object)
		case ^CallExpression:
			node = format_expr_strip(inner.callee)
		case:
			return false
		}
	}
	return false
}

format_tagged_template :: proc(f: ^FormatContext, node: ^TaggedTemplateExpression) -> Doc {
	if format_tag_is_special(node.tag) {return format_fail(f)}
	return fc(
		f,
		format_expr(f, node.tag, .Tag),
		doc_line_suffix_boundary(),
		format_expr(f, node.quasi, .Quasi),
	)
}

// ---------------------------------------------------------------------------
// Assignment targets
// ---------------------------------------------------------------------------

// The left side of a destructuring assignment parses as an object or array
// expression. Prettier's reference AST has patterns there, so these targets
// print with the pattern rules.
format_target :: proc(f: ^FormatContext, expr: ^Expression, key: FormatKey) -> Doc {
	node := format_expr_unwrap(expr)
	if node == nil {return format_fail(f)}
	#partial switch inner in node^ {
	case ^ObjectExpression:
		return format_target_object(f, inner, key)
	case ^ArrayExpression:
		return format_target_array(f, inner, key)
	case ^AssignmentExpression:
		if inner.operator != .Assign {return format_fail(f)}
		if !format_path_push(f, {kind = .Assignment_Pattern, key = key}) {return nil}
		defer format_path_pop(f)
		return fc(
			f,
			format_target(f, inner.left, .Left),
			ft(f, " = "),
			format_expr(f, inner.right, .Right),
		)
	case ^SpreadElement:
		if !format_path_push(f, {kind = .Rest_Element, key = key}) {return nil}
		defer format_path_pop(f)
		return fc(f, ft(f, "..."), format_target(f, inner.argument, .Argument))
	}
	return format_expr(f, expr, key)
}

@(private = "file")
format_target_is_nested :: proc(expr: ^Expression) -> bool {
	node := format_expr_unwrap(expr)
	if node == nil {return false}
	#partial switch _ in node^ {
	case ^ObjectExpression, ^ArrayExpression: return true
	}
	return false
}

@(private = "file")
format_target_is_pattern :: proc(expr: ^Expression) -> bool {
	node := format_expr_unwrap(expr)
	if node == nil {return false}
	#partial switch _ in node^ {
	case ^ObjectExpression, ^ArrayExpression, ^AssignmentExpression: return true
	}
	return false
}

@(private = "file")
format_target_object :: proc(f: ^FormatContext, node: ^ObjectExpression, key: FormatKey) -> Doc {
	parent_kind := format_path_at(f, 0).kind
	if !format_path_push(f, {kind = .Object_Pattern, key = key, node = node}) {return nil}
	defer format_path_pop(f)
	items := make([]FormatObjectItem, len(node.properties), f.alloc)
	has_rest, nested := false, false
	for &property, index in node.properties {
		if property.value == nil || property.kind != .Init {return format_fail(f)}
		doc: Doc
		if property.key == nil {
			doc = format_target(f, property.value, .Properties)
			has_rest = index == len(node.properties) - 1
		} else if property.shorthand {
			doc = format_target(f, property.value, .Value)
		} else if !format_target_is_pattern(property.value) {
			// A plain target such as `{ key: this.value }` takes the
			// property layout that an expression would.
			if !format_path_push(f, {kind = .Property, key = .Properties, node = &property}) {
				return nil
			}
			left := format_property_key(f, property.key, property.computed)
			doc = format_assignment_like(
				f,
				FormatAssignment{kind = .Property, left = left, right = property.value},
			)
			format_path_pop(f)
		} else {
			if format_target_is_nested(property.value) {nested = true}
			left := format_property_key(f, property.key, property.computed)
			right := format_target(f, property.value, .Value)
			short_key := false
			if text, plain := doc_plain_text(f, left); plain {
				short_key = format_width(text) < int(f.options.tab_width) + 3
			}
			layout := FormatAssignLayout.Fluid
			if short_key && !doc_can_break(left) {layout = .Never_Break_After_Operator}
			doc = format_assignment_render(f, layout, left, ft(f, ":"), right)
		}
		items[index] = {doc, property.loc.end}
	}
	should_break := nested && parent_kind != .Assignment_Pattern
	hug := !should_break && parent_kind == .Assignment
	return format_object_body(f, items, should_break, !has_rest, hug)
}

@(private = "file")
format_target_array :: proc(f: ^FormatContext, node: ^ArrayExpression, key: FormatKey) -> Doc {
	if !format_path_push(f, {kind = .Array_Pattern, key = key, node = node}) {return nil}
	defer format_path_pop(f)
	items := make([]FormatArrayItem, len(node.elements), f.alloc)
	can_trail := true
	for element, index in node.elements {
		value, present := element.?
		if !present || value == nil {continue}
		loc := get_expression_loc(value)
		items[index] = {format_target(f, value, .Elements), true, loc.end, loc.start}
		inner := format_expr_unwrap(value)
		if _, rest := inner^.(^SpreadElement); rest && index == len(node.elements) - 1 {
			can_trail = false
		}
	}
	return format_array_body(f, items, false, false, can_trail)
}
