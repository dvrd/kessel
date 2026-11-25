package kessel

import "core:strings"
import "core:unicode/utf8"

// JSX elements, fragments, attributes and children. Ports of Prettier's JSX
// rules: an element stays on one line when it fits and has no nested
// element, and otherwise puts its children on lines of their own, filling
// text like a paragraph.

// One child of an element, reduced to what the layout rules ask about.
@(private = "file")
FormatJsxChild :: struct {
	// The source text of a text child, or " " for the `{" "}` idiom.
	text:         string,
	is_text:      bool,
	is_element:   bool, // An element or a fragment.
	self_closing: bool,
	is_container: bool,
	expr:         ^Expression,
}

@(private = "file")
format_jsx_is_space :: #force_inline proc(char: u8) -> bool {
	return char == ' ' || char == '\n' || char == '\r' || char == '\t'
}

// Text prints unless it is only whitespace with a line break in it, which
// is how the source separates children.
@(private = "file")
format_jsx_text_is_meaningful :: proc(text: string) -> bool {
	has_newline := false
	for index in 0 ..< len(text) {
		if !format_jsx_is_space(text[index]) {return true}
		has_newline = has_newline || text[index] == '\n'
	}
	return !has_newline
}

@(private = "file")
format_jsx_child_is_meaningful_text :: proc(child: FormatJsxChild) -> bool {
	return child.is_text && format_jsx_text_is_meaningful(child.text)
}

// `{" "}`: a space that the source wrote as an expression so that it would
// survive a line break.
@(private = "file")
format_jsx_is_space_expression :: proc(f: ^FormatContext, node: ^JSXExpressionContainer) -> bool {
	inner := format_expr_unwrap(node.expression)
	if inner == nil {return false}
	literal, is_string := inner^.(^StringLiteral)
	if !is_string || literal.value != " " {return false}
	return len(format_comments_in(f, node.loc.start, node.loc.end)) == 0
}

@(private = "file")
format_jsx_collect :: proc(f: ^FormatContext, children: []JSXChild) -> []FormatJsxChild {
	out := make([]FormatJsxChild, len(children), f.alloc)
	for child, index in children {
		wrapper := new(Expression, f.alloc)
		item := FormatJsxChild{expr = wrapper}
		switch node in child {
		case ^JSXText:
			item.is_text, item.text = true, node.raw
		case ^JSXElement:
			wrapper^ = node
			item.is_element = true
			_, has_closing := node.closing_element.?
			item.self_closing = !has_closing
		case ^JSXFragment:
			wrapper^ = node
			item.is_element = true
		case ^JSXExpressionContainer:
			wrapper^ = node
			if format_jsx_is_space_expression(f, node) {
				item.is_text, item.text = true, " "
			} else {
				item.is_container = true
			}
		case ^JSXSpreadChild:
			wrapper^ = node
		}
		out[index] = item
	}
	return out
}

// The separator after a word or a child that the source did not follow
// with whitespace. A one-character word stays attached to a self-closing
// element beside it.
@(private = "file")
format_jsx_separator_tight :: proc(word: string, child, next: FormatJsxChild) -> Doc {
	if child.self_closing || next.self_closing {
		return doc_softline() if format_jsx_word_is_one_unit(word) else doc_hardline()
	}
	return doc_softline()
}

// The separator where the source had whitespace with a line break in it.
@(private = "file")
format_jsx_separator_spaced :: proc(word: string, child, next: FormatJsxChild) -> Doc {
	if !format_jsx_word_is_one_unit(word) {return doc_hardline()}
	return doc_hardline() if child.self_closing || next.self_closing else doc_softline()
}

// Prettier measures the word in UTF-16 units.
@(private = "file")
format_jsx_word_is_one_unit :: proc(word: string) -> bool {
	if utf8.rune_count_in_string(word) != 1 {return false}
	char, _ := utf8.decode_rune_in_string(word)
	return char < 0x10000
}

// The children as alternating contents and separators, starting with a
// content. An untouched content is nil.
@(private = "file")
FormatJsxParts :: struct {
	parts: [dynamic]Doc,
	word:  string, // The last word pushed, for the separator rules.
}

@(private = "file")
format_jsx_push :: proc(f: ^FormatContext, state: ^FormatJsxParts, doc: Doc, word: string) {
	last := len(state.parts) - 1
	state.parts[last] = fc(f, state.parts[last], doc)
	state.word = word
}

@(private = "file")
format_jsx_push_line :: proc(state: ^FormatJsxParts, separator: Doc) {
	assert(separator != nil)
	append(&state.parts, separator, nil)
}

@(private = "file")
format_jsx_first_word :: proc(text: string) -> string {
	start := 0
	for start < len(text) && format_jsx_is_space(text[start]) {start += 1}
	end := start
	for end < len(text) && !format_jsx_is_space(text[end]) {end += 1}
	return text[start:end]
}

// Pushes the words of a text child with the separators around them.
@(private = "file")
format_jsx_push_text :: proc(
	f: ^FormatContext,
	state: ^FormatJsxParts,
	child, next: FormatJsxChild,
	whitespace: Doc,
) {
	text := child.text
	if !format_jsx_text_is_meaningful(text) {
		// Only a blank line between children survives.
		if strings.count(text, "\n") > 1 {format_jsx_push_line(state, doc_hardline())}
		return
	}
	index := 0
	for index < len(text) && format_jsx_is_space(text[index]) {index += 1}
	if index > 0 {
		if strings.contains_rune(text[:index], '\n') {
			first := format_jsx_first_word(text)
			format_jsx_push_line(state, format_jsx_separator_spaced(first, child, next))
		} else {
			format_jsx_push_line(state, whitespace)
		}
	}
	if index == len(text) {return}
	trailing := ""
	for index < len(text) {
		start := index
		for index < len(text) && !format_jsx_is_space(text[index]) {index += 1}
		word := text[start:index]
		format_jsx_push(f, state, ft(f, word), word)
		gap := index
		for index < len(text) && format_jsx_is_space(text[index]) {index += 1}
		if index == len(text) {
			trailing = text[gap:]
		} else {
			format_jsx_push_line(state, doc_line())
		}
	}
	if trailing == "" {
		format_jsx_push_line(state, format_jsx_separator_tight(state.word, child, next))
	} else if strings.contains_rune(trailing, '\n') {
		format_jsx_push_line(state, format_jsx_separator_spaced(state.word, child, next))
	} else {
		format_jsx_push_line(state, whitespace)
	}
}

@(private = "file")
format_jsx_children :: proc(
	f: ^FormatContext,
	children: []FormatJsxChild,
	whitespace: Doc,
) -> [dynamic]Doc {
	state := FormatJsxParts{parts = make([dynamic]Doc, f.alloc)}
	append(&state.parts, nil)
	for child, index in children {
		next: FormatJsxChild
		if index + 1 < len(children) {next = children[index + 1]}
		if child.is_text {
			format_jsx_push_text(f, &state, child, next, whitespace)
			continue
		}
		format_jsx_push(f, &state, format_expr(f, child.expr, .Elements), "")
		if index + 1 < len(children) && format_jsx_child_is_meaningful_text(next) {
			first := format_jsx_first_word(next.text)
			format_jsx_push_line(&state, format_jsx_separator_tight(first, child, next))
		} else {
			format_jsx_push_line(&state, doc_hardline())
		}
	}
	return state.parts
}

@(private = "file")
format_jsx_is_line :: proc(doc: Doc) -> bool {
	return doc == nil || doc == doc_line() || doc == doc_hardline() || doc == doc_softline()
}

// Drops the separators that the collection doubled up, and the lines at
// either end. `whitespace` is the element's own document for a space that
// must survive, so it can be told apart by identity.
@(private = "file")
format_jsx_clean :: proc(parts: ^[dynamic]Doc, whitespace: Doc, contains_text: bool) {
	hard, soft := doc_hardline(), doc_softline()
	for index := len(parts) - 2; index >= 0; index -= 1 {
		if index + 1 >= len(parts) {continue}
		a, b := parts[index], parts[index + 1]
		c: Doc = nil
		has_c := index + 2 < len(parts)
		if has_c {c = parts[index + 2]}
		a_is_line := a == soft || a == hard
		c_is_line := has_c && (c == soft || c == hard)
		pair_of_empty := a == nil && b == nil
		pair_of_hard := a == hard && b == nil && has_c && c == hard
		line_then_space := a_is_line && b == nil && has_c && c == whitespace
		space_then_line := a == whitespace && b == nil && c_is_line
		double_space := a == whitespace && b == nil && has_c && c == whitespace
		mixed_lines := a_is_line && b == nil && c_is_line && a != c
		if (pair_of_hard && contains_text) || pair_of_empty || line_then_space || double_space ||
		   mixed_lines {
			ordered_remove(parts, index)
			ordered_remove(parts, index)
		} else if space_then_line {
			ordered_remove(parts, index + 1)
			ordered_remove(parts, index + 1)
		}
	}
	for len(parts) > 0 && format_jsx_is_line(parts[len(parts) - 1]) {pop(parts)}
	for len(parts) > 1 && format_jsx_is_line(parts[0]) && format_jsx_is_line(parts[1]) {
		ordered_remove(parts, 0)
		ordered_remove(parts, 0)
	}
}

// The children for the broken layout. A space at either end of a line
// would be lost there, so it prints as `{" "}`.
@(private = "file")
format_jsx_multiline :: proc(
	f: ^FormatContext,
	children: []Doc,
	whitespace: Doc,
) -> (
	parts: [dynamic]Doc,
	will_break: bool,
) {
	raw := ft(f, "{' '}" if f.options.single_quote else "{\" \"}")
	parts = make([dynamic]Doc, f.alloc)
	append(&parts, nil)
	count := len(children)
	for child, index in children {
		last := len(parts) - 1
		if child == whitespace {
			if index == 1 && children[0] == nil {
				if count == 2 {
					parts[last] = fc(f, parts[last], raw)
				} else {
					append(&parts, fc(f, raw, doc_hardline()), nil)
				}
				continue
			}
			after_break := index >= 2 && children[index - 1] == nil
			after_break = after_break && children[index - 2] == doc_hardline()
			if index == count - 1 || after_break {
				parts[last] = fc(f, parts[last], raw)
				continue
			}
		}
		if index % 2 == 0 {
			parts[last] = fc(f, parts[last], child)
		} else {
			append(&parts, child, nil)
		}
		will_break = will_break || doc_will_break(child)
	}
	return parts, will_break
}

// An element or a fragment, without the parentheses that its parent may
// call for.
@(private = "file")
format_jsx_element :: proc(
	f: ^FormatContext,
	opening, closing: Doc,
	nodes: []JSXChild,
	attribute_count: int,
	is_element: bool,
) -> Doc {
	children := format_jsx_collect(f, nodes)
	// No children, or only the line break between the tags.
	if is_element && (len(children) == 0 || (len(children) == 1 && children[0].is_text &&
				   !format_jsx_text_is_meaningful(children[0].text))) {
		return fc(f, opening, closing)
	}
	if len(children) == 1 && children[0].is_container {
		container := children[0].expr^.(^JSXExpressionContainer)
		inner := format_expr_unwrap(container.expression)
		if inner != nil {
			#partial switch _ in inner^ {
			case ^TemplateLiteral, ^TaggedTemplateExpression:
				return fc(f, opening, format_expr(f, children[0].expr, .Elements), closing)
			}
		}
	}
	containers, contains_tag, contains_text := 0, false, false
	for child in children {
		if child.is_container {containers += 1}
		contains_tag = contains_tag || child.is_element
		contains_text = contains_text || format_jsx_child_is_meaningful_text(child)
	}
	forced_break := doc_will_break(opening) || contains_tag || attribute_count > 1 || containers > 1
	raw := ft(f, "{' '}" if f.options.single_quote else "{\" \"}")
	whitespace := doc_if_break(f, fc(f, raw, doc_softline()), ft(f, " "))
	parts := format_jsx_children(f, children, whitespace)
	format_jsx_clean(&parts, whitespace, contains_text)
	multiline, breaks := format_jsx_multiline(f, parts[:], whitespace)
	forced_break = forced_break || breaks
	content: Doc
	if contains_text {
		content = doc_fill(f, multiline[:])
	} else {
		content = doc_group(f, fc(f, ..multiline[:]), true)
	}
	expanded := fg(f, opening, fi(f, doc_hardline(), content), doc_hardline(), closing)
	if forced_break {return expanded}
	flat := fg(f, opening, fc(f, ..parts[:]), closing)
	return doc_conditional_group(f, []Doc{flat, expanded})
}

@(private = "file")
format_jsx_name :: proc(f: ^FormatContext, name: JSXElementName) -> string {
	switch node in name {
	case JSXIdentifier:
		return node.name
	case ^JSXNamespacedName:
		return strings.concatenate({node.namespace.name, ":", node.name.name}, f.alloc)
	case ^JSXMemberExpression:
		// The object nests to the left, so the names come out last first.
		names := make([dynamic]string, f.alloc)
		member := node
		for _ in 0 ..< FORMAT_DEPTH_MAX {
			append(&names, member.property.name)
			switch object in member.object {
			case JSXIdentifier:
				append(&names, object.name)
				member = nil
			case ^JSXMemberExpression:
				member = object
			}
			if member == nil {break}
		}
		if member != nil {
			f.failed = true
			return ""
		}
		out := strings.builder_make(f.alloc)
		for index := len(names) - 1; index >= 0; index -= 1 {
			strings.write_string(&out, names[index])
			if index > 0 {strings.write_byte(&out, '.')}
		}
		return strings.to_string(out)
	}
	return ""
}

// A string attribute keeps its text. Only the quotes may change, to the
// kind that needs fewer entities.
@(private = "file")
format_jsx_string :: proc(f: ^FormatContext, literal: ^StringLiteral) -> Doc {
	raw := literal.raw
	if len(raw) < 2 {return format_fail(f)}
	text, _ := strings.replace_all(raw[1:len(raw) - 1], "&apos;", "'", f.alloc)
	text, _ = strings.replace_all(text, "&quot;", "\"", f.alloc)
	doubles, singles := strings.count(text, "\""), strings.count(text, "'")
	quote := "\""
	if doubles > singles {
		quote = "'"
		text, _ = strings.replace_all(text, "'", "&apos;", f.alloc)
	} else {
		text, _ = strings.replace_all(text, "\"", "&quot;", f.alloc)
	}
	return doc_literal_text(f, strings.concatenate({quote, text, quote}, f.alloc))
}

@(private = "file")
format_jsx_attribute_has_newline :: proc(item: JSXAttributeItem) -> (is_string, has_newline: bool) {
	attribute, plain := item.(JSXAttribute)
	if !plain {return false, false}
	value, has_value := attribute.value.?
	if !has_value || value == nil {return false, false}
	literal, quoted := value^.(^StringLiteral)
	if !quoted {return false, false}
	return true, strings.contains_rune(literal.value, '\n')
}

@(private = "file")
format_jsx_attribute :: proc(f: ^FormatContext, item: ^JSXAttributeItem) -> Doc {
	switch &node in item^ {
	case ^JSXSpreadAttribute:
		if !format_path_push(f, {kind = .JSX_Spread, key = .Properties, node = node}) {return nil}
		defer format_path_pop(f)
		return fc(f, ft(f, "{..."), format_expr(f, node.argument, .Argument), ft(f, "}"))
	case JSXAttribute:
		name: string
		switch attribute_name in node.name {
		case JSXIdentifier:
			name = attribute_name.name
		case ^JSXNamespacedName:
			parts := []string{attribute_name.namespace.name, ":", attribute_name.name.name}
			name = strings.concatenate(parts, f.alloc)
		}
		value, has_value := node.value.?
		if !has_value || value == nil {return ft(f, name)}
		if literal, quoted := value^.(^StringLiteral); quoted {
			return fc(f, ft(f, name), ft(f, "="), format_jsx_string(f, literal))
		}
		if !format_path_push(f, {kind = .JSX_Attribute, key = .Properties, node = &node}) {
			return nil
		}
		defer format_path_pop(f)
		return fc(f, ft(f, name), ft(f, "="), format_expr(f, value, .Value))
	}
	return format_fail(f)
}

@(private = "file")
format_jsx_opening :: proc(f: ^FormatContext, node: ^JSXOpeningElement) -> Doc {
	name := format_jsx_name(f, node.name)
	// Prettier lays out the children of a translation tag by other rules.
	if name == "fbt" || name == "" {return format_fail(f)}
	head := fc(f, ft(f, "<"), ft(f, name), format_type_arguments(f, node.type_arguments))
	count := len(node.attributes)
	if count == 0 {return fc(f, head, ft(f, " />" if node.self_closing else ">"))}
	printed := make([]Doc, count, f.alloc)
	any_newline := false
	for &attribute, index in node.attributes {
		printed[index] = format_jsx_attribute(f, &attribute)
		_, has_newline := format_jsx_attribute_has_newline(attribute)
		any_newline = any_newline || has_newline
	}
	if count == 1 {
		// A lone string attribute never leaves the tag's line.
		if is_string, has_newline := format_jsx_attribute_has_newline(node.attributes[0]);
		   is_string && !has_newline {
			return fg(f, head, ft(f, " "), printed[0], ft(f, " />" if node.self_closing else ">"))
		}
	}
	attributes := make([dynamic]Doc, f.alloc)
	for attribute in printed {append(&attributes, doc_line(), attribute)}
	end := fc(f, doc_softline(), ft(f, ">"))
	if node.self_closing {end = fc(f, doc_line(), ft(f, "/>"))}
	return doc_group(f, fc(f, head, fi(f, ..attributes[:]), end), any_newline)
}

// True for the body of a callback that is an argument of a call that a JSX
// expression holds, as in `{items.map((item) => <li />)}`. Such a body
// always takes parentheses and lines of its own.
@(private = "file")
format_jsx_is_callback_body :: proc(f: ^FormatContext) -> bool {
	current := format_path_at(f, 0)
	arrow := format_path_at(f, 1)
	call := format_path_at(f, 2)
	if current.key != .Body || arrow.kind != .Arrow_Function {return false}
	if arrow.key != .Arguments || call.kind != .Call {return false}
	return call.key == .Expression && format_path_at(f, 3).kind == .JSX_Expression_Container
}

// An element or a fragment as an expression. Where a break would detach it
// from what introduces it, it takes parentheses when it breaks.
format_jsx :: proc(f: ^FormatContext, expr: ^Expression) -> Doc {
	element: Doc
	#partial switch node in expr^ {
	case ^JSXElement:
		if node.opening_element == nil {return format_fail(f)}
		opening := format_jsx_opening(f, node.opening_element)
		closing: Doc
		if closing_element, has_closing := node.closing_element.?; has_closing {
			name := format_jsx_name(f, closing_element.name)
			closing = fc(f, ft(f, "</"), ft(f, name), ft(f, ">"))
		}
		count := len(node.opening_element.attributes)
		element = format_jsx_element(f, opening, closing, node.children[:], count, true)
	case ^JSXFragment:
		element = format_jsx_element(f, ft(f, "<>"), ft(f, "</>"), node.children[:], 0, false)
	case:
		return format_fail(f)
	}
	#partial switch format_parent(f).kind {
	case .Array, .JSX_Attribute, .JSX, .JSX_Expression_Container, .Expression_Statement, .New,
	     .Call, .Conditional:
		return element
	}
	needs_parens := format_needs_parens(f)
	return doc_group(
		f,
		fc(
			f,
			nil if needs_parens else doc_if_break(f, ft(f, "(")),
			fi(f, doc_softline(), element),
			doc_softline(),
			nil if needs_parens else doc_if_break(f, ft(f, ")")),
		),
		format_jsx_is_callback_body(f),
	)
}

// Whether `{expression}` keeps its braces tight around the expression,
// which then breaks by itself.
@(private = "file")
format_jsx_container_inlines :: proc(expr: ^Expression, parent_is_jsx: bool) -> bool {
	inner := format_expr_unwrap(expr)
	if inner == nil {return false}
	#partial switch node in inner^ {
	case ^JSXEmptyExpression, ^ArrayExpression, ^ObjectExpression, ^ArrowFunctionExpression,
	     ^CallExpression, ^FunctionExpression, ^TemplateLiteral, ^TaggedTemplateExpression:
		return true
	case ^ChainExpression:
		chained := format_expr_unwrap(node.expression)
		if chained == nil {return false}
		_, is_call := chained^.(^CallExpression)
		return is_call
	case ^AwaitExpression:
		argument := format_expr_unwrap(node.argument)
		if argument == nil {return false}
		if _, is_element := argument^.(^JSXElement); is_element {return true}
		return format_jsx_container_inlines(node.argument, false)
	case ^ConditionalExpression, ^BinaryExpression, ^LogicalExpression:
		return parent_is_jsx
	}
	return false
}

// True for a template held by the expression on top of the path when that
// expression is the value of a `css` attribute or a child of `<style>`.
@(private = "file")
format_jsx_template_is_css :: proc(f: ^FormatContext) -> bool {
	parent := format_parent(f)
	#partial switch parent.kind {
	case .JSX_Attribute:
		attribute := cast(^JSXAttribute)parent.node
		name, plain := attribute.name.(JSXIdentifier)
		return plain && name.name == "css"
	case .JSX:
		element, is_element := parent.expr^.(^JSXElement)
		if !is_element || element.opening_element == nil {return false}
		name, plain := element.opening_element.name.(JSXIdentifier)
		return plain && name.name == "style"
	}
	return false
}

// `{expression}` as a child or an attribute value, `{...spread}` as a
// child, and `{/* comment */}`.
format_jsx_container :: proc(f: ^FormatContext, expr: ^Expression) -> Doc {
	#partial switch node in expr^ {
	case ^JSXSpreadChild:
		return fc(f, ft(f, "{..."), format_expr(f, node.expression, .Expression), ft(f, "}"))
	case ^JSXEmptyExpression:
		// A comment is all that an empty expression can hold. Only one block
		// comment on the braces' line is covered.
		inside := format_comments_in(f, node.loc.start, node.loc.end)
		if len(inside) == 0 {return nil}
		if len(inside) != 1 || !format_comment_is_block(f, inside[0]) {return format_fail(f)}
		format_comment_mark(f, inside[0])
		return format_comment_contents(f, inside[0])
	case ^JSXExpressionContainer:
		parent_is_jsx := format_parent(f).kind == .JSX
		inner := format_expr_unwrap(node.expression)
		if inner == nil {return format_fail(f)}
		inside_start := node.loc.start + 1
		if _, empty := inner^.(^JSXEmptyExpression); empty {
			// The parser may give the empty expression no span of its own.
			comments := format_comments_in(f, inside_start, node.loc.end - 1)
			if len(comments) == 0 {return ft(f, "{}")}
			if len(comments) != 1 || !format_comment_is_block(f, comments[0]) {
				return format_fail(f)
			}
			format_comment_mark(f, comments[0])
			return fc(f, ft(f, "{"), format_comment_contents(f, comments[0]), ft(f, "}"))
		}
		if _, template := inner^.(^TemplateLiteral); template {
			// Prettier formats the template of a `css` attribute and of a
			// `<style>` element as CSS, which is not ported.
			if format_jsx_template_is_css(f) {return format_fail(f)}
		}
		value := format_expr(f, node.expression, .Expression)
		if format_jsx_container_inlines(node.expression, parent_is_jsx) {
			return fg(f, ft(f, "{"), value, doc_line_suffix_boundary(), ft(f, "}"))
		}
		close := fc(f, doc_softline(), doc_line_suffix_boundary(), ft(f, "}"))
		return fg(f, ft(f, "{"), fi(f, doc_softline(), value), close)
	}
	return format_fail(f)
}
