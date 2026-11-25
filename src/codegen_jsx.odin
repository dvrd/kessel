package kessel

import "core:strings"

JSXOptions :: struct {
	runtime: enum { Preserve, Classic, Automatic },
	pragma, pragma_frag, import_source, filename: string,
	allow_namespaces, omit_pure, development: bool,
}

jsx_component_name :: proc(name: string) -> bool {
	return len(name) != 0 && !(name[0] >= 'a' && name[0] <= 'z') && !strings.contains_rune(name, '-')
}

jsx_pragma_directive :: proc(word: string) -> bool {
	return word == "@jsx" || word == "@jsxFrag" || word == "@jsxRuntime" || word == "@jsxImportSource"
}

// JSX consumers differ on case, whitespace and which of several directives wins.
// Preserve the source comment and reserve each possible factory or fragment root.
// A mention in prose can reserve an extra name without changing the emitted JSX.
jsx_comment_has_pragma :: proc(comment: Comment, roots: ^map[string]bool = nil) -> bool {
	text := comment.value
	found := false
	for len(text) > 0 {
		offset := strings.index_byte(text, '@')
		if offset < 0 { break }
		text = text[offset+1:]
		end := 0
		for end < len(text) && (text[end] >= 'a' && text[end] <= 'z' || text[end] >= 'A' && text[end] <= 'Z') { end += 1 }
		word := text[:end]
		text = text[end:]
		factory := strings.equal_fold(word, "jsx") || strings.equal_fold(word, "jsxFrag")
		if !factory && !strings.equal_fold(word, "jsxRuntime") && !strings.equal_fold(word, "jsxImportSource") { continue }
		found = true
		if roots == nil { return true }
		if !factory { continue }
		name := strings.trim_left_space(text)
		for ch, index in name {
			if !is_id_cont_codepoint(u32(ch)) { name = name[:index]; break }
		}
		if name != "" { roots^[name] = true }
	}
	return found
}

// File-wide directives must precede generated imports. Leave documentation and
// next-line diagnostics after those imports, adjacent to their original statement.
jsx_file_header :: proc(comments: []Comment, first_statement: u32) -> []Comment {
	count := 0
	for comment, index in comments {
		if comment.end > first_statement { break }
		text := strings.trim_space(comment.value)
		if strings.has_prefix(text, "/ <reference") { count = index + 1; continue }
		for word in strings.fields_iterator(&text) {
			switch strings.trim_left(word, "*") {
			case "@ts-check", "@ts-nocheck", "@flow", "@noflow", "@jsx", "@jsxFrag", "@jsxRuntime", "@jsxImportSource":
				count = index + 1
			}
		}
	}
	return comments[:count]
}

gen_jsx_runtime :: proc(cg: ^Codegen, start: u32, opening: ^JSXOpeningElement, children: []JSXChild) {
	location: JSXSourceLocation
	if cg.cfg.jsx.development && opening != nil { location = jsx_source_location(cg, start) }
	if !cg.cfg.jsx.omit_pure { codegen_write_annotation(cg, start, .Pure) }
	if cg.cfg.jsx.runtime == .Automatic {
		if !jsx_needs_create_element(opening) {
			gen_jsx_automatic(cg, opening, children, location)
			return
		}
		gen_jsx_helper(cg, .CreateElement)
	} else {
		gen_jsx_pragma(cg, start, cg.cfg.jsx.pragma, true)
	}
	cg_byte(cg, '(')
	if opening == nil {
		gen_jsx_pragma(cg, start, cg.cfg.jsx.pragma_frag, false)
		cg_byte(cg, ',')
		cg_space(cg)
		cg_str(cg, "null")
	} else {
		gen_jsx_classic_name(cg, opening.name)
		cg_byte(cg, ',')
		cg_space(cg)
		gen_jsx_classic_props(cg, opening.attributes[:], location)
	}
	for child in children { gen_jsx_classic_child(cg, child) }
	cg_byte(cg, ')')
	if cg.cfg.jsx.runtime == .Automatic { jsx_finish_helper(cg, .CreateElement) }
}

jsx_pragma_root :: proc(path: string) -> string {
	dot := strings.index_byte(path, '.')
	return path[:dot] if dot >= 0 else path
}

// Factory and fragment names are implicit lexical references at the JSX site.
// An exported namespace variable may live only on its emitted namespace object.
gen_jsx_pragma :: proc(cg: ^Codegen, start: u32, path: string, callee: bool) {
	state := cg.runtime_scope
	model := state.jsx_model
	if model != nil && len(state.active_aliases) != 0 {
		root := jsx_pragma_root(path)
		scope, found := model.jsx_scopes[start]
		if found {
			id := semantic_lookup(model, scope, root)
			if id != SYMBOL_UNRESOLVED {
				property_scope := codegen_runtime_property_scope(model, model.symbols[id], scope)
				if alias := state.active_aliases[property_scope]; alias != "" {
					unbound := callee && len(path) == len(root)
					if unbound { cg_str(cg, "(0,") }
					gen_runtime_property(cg, alias, root)
					if unbound { cg_byte(cg, ')') }
					cg_str(cg, path[len(root):])
					return
				}
			}
		}
	}
	cg_str(cg, path)
}

gen_jsx_classic_name :: proc(cg: ^Codegen, name: JSXElementName) {
	switch item in name {
	case JSXIdentifier:
		sourcemap_record(cg.sm, u32(cg.pos), item.loc.start)
		if item.name == "this" || jsx_component_name(item.name) {
			gen_expression_identifier(cg, &Identifier{loc = item.loc, name = item.name})
		} else {
			gen_string_quoted(cg, item.name)
		}
	case ^JSXMemberExpression: gen_jsx_classic_member(cg, item)
	case ^JSXNamespacedName:
		sourcemap_record(cg.sm, u32(cg.pos), item.loc.start)
		if !cg.cfg.jsx.allow_namespaces {
			cg_strip_unsupported(cg, item.loc, "JSX namespace tags are unsupported by the React runtime")
		}
		cg_byte(cg, '"')
		gen_jsx_name(cg, name)
		cg_byte(cg, '"')
	}
}

gen_jsx_classic_member :: proc(cg: ^Codegen, member: ^JSXMemberExpression) {
	switch base in member.object {
	case JSXIdentifier:
		sourcemap_record(cg.sm, u32(cg.pos), base.loc.start)
		if strings.contains_rune(base.name, '-') {
			cg_strip_unsupported(cg, base.loc, "hyphenated JSX member base cannot name a binding")
			return
		}
		gen_expression_identifier(cg, &Identifier{loc = base.loc, name = base.name})
	case ^JSXMemberExpression: gen_jsx_classic_member(cg, base)
	}
	if strings.contains_rune(member.property.name, '-') {
		cg_byte(cg, '[')
		gen_string_quoted(cg, member.property.name)
		cg_byte(cg, ']')
	} else {
		cg_byte(cg, '.')
		sourcemap_record(cg.sm, u32(cg.pos), member.property.loc.start)
		cg_str(cg, member.property.name)
	}
}

gen_jsx_classic_props :: proc(cg: ^Codegen, attrs: []JSXAttributeItem, location: JSXSourceLocation) {
	if len(attrs) == 0 && !cg.cfg.jsx.development { cg_str(cg, "null"); return }
	if len(attrs) == 1 && !cg.cfg.jsx.development {
		if spread, ok := attrs[0].(^JSXSpreadAttribute); ok && !jsx_spread_has_proto(spread.argument) {
			gen_expression(cg, spread.argument, PREC_ASSIGN)
			return
		}
	}
	emitted := false
	for attr in attrs { gen_jsx_prop(cg, attr, &emitted) }
	if cg.cfg.jsx.development {
		if !cg.jsx_omit_self {
			gen_jsx_prop_start(cg, &emitted)
			cg_str(cg, "__self: this")
		}
		gen_jsx_prop_start(cg, &emitted)
		cg_str(cg, "__source:")
		gen_jsx_source(cg, location)
	}
	if emitted { cg_space(cg); cg_byte(cg, '}') } else { cg_str(cg, "null") }
}

gen_jsx_prop :: proc(cg: ^Codegen, attr: JSXAttributeItem, emitted: ^bool) {
	switch item in attr {
	case ^JSXSpreadAttribute:
		if object, ok := item.argument^.(^ObjectExpression); ok && !jsx_spread_has_proto(item.argument) {
			for property in object.properties {
				gen_jsx_prop_start(cg, emitted)
				gen_property(cg, property)
			}
		} else {
			gen_jsx_prop_start(cg, emitted)
			cg_str(cg, "...")
			gen_expression(cg, item.argument, PREC_ASSIGN)
		}
	case JSXAttribute:
		gen_jsx_prop_start(cg, emitted)
		gen_jsx_classic_attr(cg, item)
	}
}

gen_jsx_prop_start :: proc(cg: ^Codegen, emitted: ^bool) {
	cg_byte(cg, ',' if emitted^ else '{')
	cg_space(cg)
	emitted^ = true
}

gen_jsx_classic_attr :: proc(cg: ^Codegen, attr: JSXAttribute) {
	sourcemap_record(cg.sm, u32(cg.pos), attr.loc.start)
	switch key in attr.name {
	case JSXIdentifier:
		if key.name == "key" && attr.value == nil {
			cg_strip_unsupported(cg, key.loc, "JSX key requires a value")
		}
		// Keep this attribute as data even when the user passes an object as its value.
		if key.name == "__proto__" { cg_byte(cg, '[') }
		gen_string_quoted(cg, key.name)
		if key.name == "__proto__" { cg_byte(cg, ']') }
	case ^JSXNamespacedName:
		cg_byte(cg, '"')
		gen_jsx_attr_name(cg, attr.name)
		cg_byte(cg, '"')
	}
	cg_byte(cg, ':')
	cg_space(cg)
	if value, ok := attr.value.?; ok {
		gen_jsx_classic_attr_value(cg, value)
	} else {
		cg_str(cg, "true")
	}
}

jsx_spread_has_proto :: proc(value: ^Expression) -> bool {
	expression := value
	for expression != nil {
		group, ok := expression^.(^ParenthesizedExpression)
		if !ok { break }
		expression = group.expression
	}
	if expression == nil { return false }
	if object, ok := expression^.(^ObjectExpression); ok {
		for property in object.properties {
			if key, valid := enum_member_name(property.key); valid && key == "__proto__" { return true }
		}
	}
	return false
}

gen_jsx_classic_attr_value :: proc(cg: ^Codegen, value: ^Expression) {
	#partial switch item in value^ {
	case ^StringLiteral:
		sourcemap_record(cg.sm, u32(cg.pos), item.loc.start)
		gen_string_quoted(cg, jsx_text_value(cg, jsx_attr_string_source(item), false))
	case ^JSXExpressionContainer:
		gen_expression(cg, item.expression, PREC_ASSIGN)
	case:
		gen_expression(cg, value, PREC_ASSIGN)
	}
}

gen_jsx_classic_child :: proc(cg: ^Codegen, child: JSXChild) {
	text, present := jsx_child_value(cg, child)
	if !present { return }
	cg_byte(cg, ',')
	cg_space(cg)
	gen_jsx_child_value(cg, child, text)
}

jsx_child_value :: proc(cg: ^Codegen, child: JSXChild) -> (string, bool) {
	text: string
	#partial switch item in child {
	case ^JSXText:
		// `value` is already entity-decoded by the parser. Start from `raw`
		// so that decoding happens exactly once, after line trimming.
		text = jsx_text_value(cg, item.raw, true)
		if text == "" { return "", false }
	case ^JSXExpressionContainer:
		if _, empty := item.expression^.(^JSXEmptyExpression); empty { return "", false }
	}
	return text, true
}

gen_jsx_child_value :: proc(cg: ^Codegen, child: JSXChild, text: string) {
	switch item in child {
	case ^JSXText:
		sourcemap_record(cg.sm, u32(cg.pos), item.loc.start)
		gen_string_quoted(cg, text)
	case ^JSXExpressionContainer: gen_expression(cg, item.expression, PREC_ASSIGN)
	case ^JSXSpreadChild:
		cg_str(cg, "...")
		gen_expression(cg, item.expression, PREC_ASSIGN)
	case ^JSXElement:
		value := Expression(item)
		gen_expression(cg, &value, PREC_ASSIGN)
	case ^JSXFragment:
		value := Expression(item)
		gen_expression(cg, &value, PREC_ASSIGN)
	}
}

// The parser decodes entities into a JSX attribute's `StringLiteral.value`.
// The transform decodes too, so it must start from the undecoded source text
// (`raw` without its quotes): decoding `value` again would turn `&amp;lt;`
// into `<`. A literal built by another pass has no `raw`; its `value` is
// taken as undecoded text, which is what such passes produced before.
jsx_attr_string_source :: proc(literal: ^StringLiteral) -> string {
	raw := literal.raw
	if len(raw) < 2 { return literal.value }
	quote := raw[0]
	if quote != '"' && quote != '\'' { return literal.value }
	if raw[len(raw)-1] != quote { return literal.value }
	return raw[1:len(raw)-1]
}

// Trim before decoding so an explicit &nbsp; at a line boundary survives.
jsx_text_value :: proc(cg: ^Codegen, raw: string, trim_lines: bool) -> string {
	if !strings.contains_any(raw, "&\n\r\u2028\u2029") { return raw }
	builder := strings.builder_make(0, len(raw), cg.runtime_scope.allocator)
	start := 0
	if trim_lines {
		for ch, index in raw {
			if ch != '\r' && ch != '\n' && ch != '\u2028' && ch != '\u2029' { continue }
			jsx_append_text_line(&builder, raw[start:index], start > 0, true)
			start = index + (3 if ch >= 0x2028 else 1)
		}
	}
	jsx_append_text_line(&builder, raw[start:], start > 0, false)
	return strings.to_string(builder)
}

jsx_append_text_line :: proc(builder: ^strings.Builder, line: string, left, right: bool) {
	SPACE :: " \t\v\f\u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u202f\u205f\u3000\ufeff"
	text := line
	if left { text = strings.trim_left(text, SPACE) }
	if right { text = strings.trim_right(text, SPACE) }
	if text == "" { return }
	if strings.builder_len(builder^) != 0 { strings.write_byte(builder, ' ') }
	jsx_write_decoded(builder, text)
}

jsx_decode_entity :: proc(name: string) -> (rune, bool) {
	if len(name) == 0 { return 0, false }
	if name[0] != '#' {
		low, high := 0, len(JSX_ENTITIES)
		for low < high {
			mid := low + (high - low) / 2
			entry := JSX_ENTITIES[mid]
			if entry.name == name { return entry.value, true }
			if entry.name < name { low = mid + 1 } else { high = mid }
		}
		return 0, false
	}
	base, index := u32(10), 1
	if index < len(name) && name[index] == 'x' { base, index = 16, 2 }
	if index < len(name) && name[index] == '+' { index += 1 }
	if index == len(name) { return 0, false }
	value: u32
	for ch in transmute([]u8)name[index:] {
		digit: u32
		switch {
		case ch >= '0' && ch <= '9': digit = u32(ch - '0')
		case ch >= 'a' && ch <= 'f': digit = u32(ch - 'a') + 10
		case ch >= 'A' && ch <= 'F': digit = u32(ch - 'A') + 10
		case: return 0, false
		}
		if digit >= base { return 0, false }
		value = value * base + digit
		if value > 0x10ffff { return 0, false }
	}
	return rune(value), value < 0xd800 || value > 0xdfff
}
