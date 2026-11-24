package kessel

import "core:strings"
import "core:unicode/utf8"

// Atoms, escapes and group names for the regexp tree builder. See
// regex_ast.odin for the overall shape.
//
// Three grammar parameters decide what an escape means:
//   UnicodeMode (`u`/`v`)   escapes are strict; an unknown escape is an error.
//   otherwise (Annex B)     an escape that fails to parse falls back to the
//                           escaped character itself, e.g. `\x` is `x`.
//   NamedCaptureGroups      `\k` must be a complete `\k<name>` reference.

// An atom outside a character class.
@(private)
regex_ast_atom :: proc(p: ^RegexAstParser, start: int) -> (RegexAstNode, int, RegexAstError) {
	pattern := p.pattern
	if pattern[start] == '\\' { return regex_ast_escape(p, start, false) }
	kind := RegexAstKind.Character
	switch pattern[start] {
	case ']', '}':
		// Annex B lets these stand for themselves; UnicodeMode does not.
		if p.unicode { return {}, 0, regex_ast_invalid(start, "Unescaped regexp delimiter") }
	case '.': kind = .Dot
	case '^': kind = .Start_Assertion
	case '$': kind = .End_Assertion
	}
	return regex_ast_source_character(pattern, start, kind)
}

// One source character as a node of the given kind.
@(private)
regex_ast_source_character :: proc(
	pattern: string,
	start: int,
	kind: RegexAstKind,
) -> (RegexAstNode, int, RegexAstError) {
	code_point, width := utf8.decode_rune_in_string(pattern[start:])
	if code_point == utf8.RUNE_ERROR && width == 1 {
		return {}, 0, regex_ast_invalid(start, "Pattern is not valid UTF-8")
	}
	end := start + width
	node := RegexAstNode{kind = kind, span = {u32(start), u32(end)}}
	if kind == .Character { node.code_point = u32(code_point) }
	return node, end, {}
}

// Parse the escape at `start`, inside or outside a character class.
@(private)
regex_ast_escape :: proc(
	p: ^RegexAstParser,
	start: int,
	in_class: bool,
) -> (RegexAstNode, int, RegexAstError) {
	pattern := p.pattern
	assert(pattern[start] == '\\')
	if start + 1 == len(pattern) {
		return {}, 0, regex_ast_invalid(start, "Trailing regexp escape")
	}
	node := RegexAstNode{kind = .Escape, span = {u32(start), u32(start + 2)}}
	letter := pattern[start + 1]
	switch letter {
	case 'd', 'D', 's', 'S', 'w', 'W':
		node.kind = .Character_Class_Escape
		node.negative = letter < 'a'
	case 'b', 'B':
		if in_class {
			// `\b` is backspace in a class. `\B` is only an Annex B identity escape.
			if letter == 'B' { return regex_ast_identity_escape(p, start, in_class) }
			node.code_point = u32(8)
		} else {
			node.kind = .Boundary_Assertion
			node.negative = letter == 'B'
		}
	case 'f': node.code_point = u32(0x0c)
	case 'n': node.code_point = u32(0x0a)
	case 'r': node.code_point = u32(0x0d)
	case 't': node.code_point = u32(0x09)
	case 'v': node.code_point = u32(0x0b)
	case 'p', 'P':
		if p.unicode { return regex_ast_property_escape(p, start) }
		return regex_ast_identity_escape(p, start, in_class)
	case 'k': return regex_ast_named_reference(p, start, in_class)
	case '0'..='9': return regex_ast_digit_escape(p, start, in_class)
	case 'c': return regex_ast_control_escape(p, start, in_class)
	case 'x': return regex_ast_hex_escape(p, start)
	case 'u': return regex_ast_unicode_escape(p, start)
	case: return regex_ast_identity_escape(p, start, in_class)
	}
	return node, start + 2, {}
}

@(private="file")
regex_ast_is_syntax_character :: proc(ch: u8) -> bool {
	switch ch {
	case '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|': return true
	}
	return false
}

// ClassSetReservedPunctuator: escapable only inside a `v`-mode class.
@(private="file")
regex_ast_is_reserved_punctuator :: proc(ch: u8) -> bool {
	switch ch {
	case '&', '-', '!', '#', '%', ',', ':', ';', '<', '=', '>', '@', '`', '~': return true
	}
	return false
}

// IdentityEscape. UnicodeMode allows only syntax characters and `/` (plus `-`
// in a class and the reserved punctuators in a `v`-mode class). Annex B allows
// any character; `c` and, with named groups, `k` never reach this procedure.
@(private="file")
regex_ast_identity_escape :: proc(
	p: ^RegexAstParser,
	start: int,
	in_class: bool,
) -> (RegexAstNode, int, RegexAstError) {
	pattern := p.pattern
	node, end, err := regex_ast_source_character(pattern, start + 1, .Character)
	if err.kind != .None { return {}, 0, err }
	if p.unicode {
		ch := pattern[start + 1]
		allowed := regex_ast_is_syntax_character(ch) || ch == '/'
		if in_class {
			if ch == '-' { allowed = true }
			if p.unicode_sets && regex_ast_is_reserved_punctuator(ch) { allowed = true }
		}
		if !allowed { return {}, 0, regex_ast_invalid(start, "Invalid identity escape") }
	}
	node.kind = .Escape
	node.span.start = u32(start)
	return node, end, {}
}

// `\k<name>`, or the identity escape `k` when the pattern has no named groups.
@(private="file")
regex_ast_named_reference :: proc(
	p: ^RegexAstParser,
	start: int,
	in_class: bool,
) -> (RegexAstNode, int, RegexAstError) {
	pattern := p.pattern
	if !p.named_groups { return regex_ast_identity_escape(p, start, in_class) }
	if in_class {
		return {}, 0, regex_ast_invalid(start, "Named reference inside a character class")
	}
	if start + 2 == len(pattern) || pattern[start + 2] != '<' {
		return {}, 0, regex_ast_invalid(start, "Named reference needs a group name")
	}
	name_end, err := regex_ast_group_name(pattern, start + 3)
	if err.kind != .None { return {}, 0, err }
	node := RegexAstNode{
		kind = .Named_Reference, span = {u32(start), u32(name_end + 1)},
		name = {u32(start + 3), u32(name_end)},
	}
	return node, name_end + 1, {}
}

// `\1`..`\9…` backreferences, `\0`, and Annex B legacy octal escapes.
@(private="file")
regex_ast_digit_escape :: proc(
	p: ^RegexAstParser,
	start: int,
	in_class: bool,
) -> (RegexAstNode, int, RegexAstError) {
	pattern := p.pattern
	body := start + 1
	digit := pattern[body]
	node := RegexAstNode{kind = .Escape, span = {start = u32(start)}}
	if digit != '0' && !in_class {
		decimal, decimal_end := regex_ast_read_decimal(pattern, body)
		if !decimal.overflow && decimal.value <= u64(p.ast.capture_count) {
			node.kind = .Indexed_Reference
			node.capture_index = u32(decimal.value)
			node.span.end = u32(decimal_end)
			return node, decimal_end, {}
		}
		// Annex B reads an out-of-range reference as an octal or identity escape.
	}
	end := body + 1
	if p.unicode {
		followed := end < len(pattern) && pattern[end] >= '0' && pattern[end] <= '9'
		if digit != '0' { return {}, 0, regex_ast_invalid(start, "Reference to a missing group") }
		if followed { return {}, 0, regex_ast_invalid(start, "Octal escape in Unicode mode") }
	}
	value := u32(digit - '0')
	if digit >= '8' {
		value = u32(digit) // `\8` and `\9` are identity escapes.
	} else if !p.unicode {
		// LegacyOctalEscapeSequence: up to three digits while the value fits a byte.
		limit := body + (3 if digit <= '3' else 2)
		for end < len(pattern) && end < limit && pattern[end] >= '0' && pattern[end] <= '7' {
			value = value * 8 + u32(pattern[end] - '0')
			end += 1
		}
		assert(value <= 0o377)
	}
	node.code_point = value
	node.span.end = u32(end)
	return node, end, {}
}

// `\cA`. In a class, Annex B also accepts a digit or `_` as the control letter.
@(private="file")
regex_ast_control_escape :: proc(
	p: ^RegexAstParser,
	start: int,
	in_class: bool,
) -> (RegexAstNode, int, RegexAstError) {
	pattern := p.pattern
	if start + 2 < len(pattern) {
		ch := pattern[start + 2]
		letter := (ch | 0x20) >= 'a' && (ch | 0x20) <= 'z'
		class_letter := in_class && !p.unicode && ((ch >= '0' && ch <= '9') || ch == '_')
		if letter || class_letter {
			node := RegexAstNode{
				kind = .Escape, span = {u32(start), u32(start + 3)}, code_point = u32(ch & 0x1f),
			}
			return node, start + 3, {}
		}
	}
	if p.unicode { return {}, 0, regex_ast_invalid(start, "Invalid control escape") }
	// Annex B: `\` before a `c` that starts no control escape is a literal
	// backslash. The `c` is left in place and parses as the next atom.
	backslash := RegexAstNode{
		kind = .Character, span = {u32(start), u32(start + 1)}, code_point = u32('\\'),
	}
	return backslash, start + 1, {}
}

@(private="file")
regex_ast_hex_value :: proc(ch: u8) -> (u32, bool) {
	switch ch {
	case '0'..='9': return u32(ch - '0'), true
	case 'a'..='f': return u32(ch - 'a') + 10, true
	case 'A'..='F': return u32(ch - 'A') + 10, true
	}
	return 0, false
}

// Exactly `count` hex digits at `start`.
@(private="file")
regex_ast_hex_digits :: proc(pattern: string, start, count: int) -> (u32, bool) {
	assert(count == 2 || count == 4)
	if start + count > len(pattern) { return 0, false }
	value: u32
	for ch in transmute([]u8)pattern[start:start + count] {
		digit, ok := regex_ast_hex_value(ch)
		if !ok { return 0, false }
		value = value * 16 + digit
	}
	return value, true
}

@(private="file")
regex_ast_hex_escape :: proc(p: ^RegexAstParser, start: int) -> (RegexAstNode, int, RegexAstError) {
	value, ok := regex_ast_hex_digits(p.pattern, start + 2, 2)
	if !ok {
		if p.unicode { return {}, 0, regex_ast_invalid(start, "Invalid hexadecimal escape") }
		return regex_ast_identity_escape(p, start, false)
	}
	node := RegexAstNode{kind = .Escape, span = {u32(start), u32(start + 4)}, code_point = value}
	return node, start + 4, {}
}

// `\u{…}` with at least one hex digit and a value up to U+10FFFF. Returns the
// offset past the closing brace.
@(private="file")
regex_ast_braced_code_point :: proc(pattern: string, open: int) -> (u32, int, bool) {
	assert(pattern[open] == '{')
	value: u32
	for cursor := open + 1; cursor < len(pattern); cursor += 1 {
		if pattern[cursor] == '}' { return value, cursor + 1, cursor > open + 1 }
		digit, ok := regex_ast_hex_value(pattern[cursor])
		if !ok { return 0, 0, false }
		value = value * 16 + digit
		// Checked per digit, so leading zeros are unlimited and nothing overflows.
		if value > 0x10ffff { return 0, 0, false }
	}
	return 0, 0, false
}

// One `\u` escape as it appears in UnicodeMode and in group names: `\u{…}`,
// `\uXXXX`, or a lead and trail surrogate pair of `\uXXXX` read as one code point.
@(private="file")
regex_ast_unicode_code_point :: proc(pattern: string, start: int) -> (u32, int, bool) {
	assert(pattern[start] == '\\' && pattern[start + 1] == 'u')
	if start + 2 < len(pattern) && pattern[start + 2] == '{' {
		return regex_ast_braced_code_point(pattern, start + 2)
	}
	value, ok := regex_ast_hex_digits(pattern, start + 2, 4)
	if !ok { return 0, 0, false }
	end := start + 6
	lead := value >= 0xd800 && value <= 0xdbff
	if lead && end + 1 < len(pattern) && pattern[end] == '\\' && pattern[end + 1] == 'u' {
		trail, trail_ok := regex_ast_hex_digits(pattern, end + 2, 4)
		if trail_ok && trail >= 0xdc00 && trail <= 0xdfff {
			return 0x10000 + ((value - 0xd800) << 10) + (trail - 0xdc00), end + 6, true
		}
	}
	return value, end, true
}

@(private="file")
regex_ast_unicode_escape :: proc(
	p: ^RegexAstParser,
	start: int,
) -> (RegexAstNode, int, RegexAstError) {
	pattern := p.pattern
	node := RegexAstNode{kind = .Escape, span = {start = u32(start)}}
	if p.unicode {
		value, end, ok := regex_ast_unicode_code_point(pattern, start)
		if !ok { return {}, 0, regex_ast_invalid(start, "Invalid Unicode escape") }
		node.code_point = value
		node.span.end = u32(end)
		return node, end, {}
	}
	// Without UnicodeMode only `\uXXXX` exists and it is one code unit; `\u{…}`
	// is the identity escape `u` followed by a braced quantifier or literal.
	value, ok := regex_ast_hex_digits(pattern, start + 2, 4)
	if !ok { return regex_ast_identity_escape(p, start, false) }
	node.code_point = value
	node.span.end = u32(start + 6)
	return node, start + 6, {}
}

// `\p{Name}`, `\p{Name=Value}` and the negated `\P` forms. UnicodeMode only.
@(private="file")
regex_ast_property_escape :: proc(
	p: ^RegexAstParser,
	start: int,
) -> (RegexAstNode, int, RegexAstError) {
	pattern := p.pattern
	assert(p.unicode)
	if start + 2 == len(pattern) || pattern[start + 2] != '{' {
		return {}, 0, regex_ast_invalid(start, "Property escape needs a braced name")
	}
	body := start + 3
	close := strings.index_byte(pattern[body:], '}')
	if close < 0 { return {}, 0, regex_ast_invalid(start, "Unterminated property escape") }
	text := pattern[body:body + close]
	end := body + close + 1
	node := RegexAstNode{
		kind = .Property_Escape, span = {u32(start), u32(end)},
		name = {u32(body), u32(body + close)}, negative = pattern[start + 1] == 'P',
	}
	if equals := strings.index_byte(text, '='); equals >= 0 {
		if !regex_ast_property_pair_valid(text[:equals], text[equals + 1:]) {
			return {}, 0, regex_ast_invalid(start, "Unknown Unicode property name or value")
		}
		node.name.end = u32(body + equals)
		node.property_value = Loc{u32(body + equals + 1), u32(body + close)}
		return node, end, {}
	}
	switch regex_ast_lone_property(text) {
	case .Unknown:
		return {}, 0, regex_ast_invalid(start, "Unknown Unicode property name")
	case .Characters:
	case .Strings:
		// A property of strings needs `v`, and its complement is not a set of strings.
		if !p.unicode_sets {
			return {}, 0, regex_ast_invalid(start, "Property of strings needs the v flag")
		}
		if node.negative {
			return {}, 0, regex_ast_invalid(start, "Property of strings cannot be negated")
		}
		node.may_contain_strings = true
	}
	return node, end, {}
}

// RegExpIdentifierName code point at `start`: a source character or a `\u`
// escape. Group names accept `\u{…}` and surrogate pairs in every mode.
@(private="file")
regex_ast_name_code_point :: proc(pattern: string, start: int) -> (u32, int, bool) {
	if pattern[start] == '\\' {
		if start + 1 == len(pattern) || pattern[start + 1] != 'u' { return 0, 0, false }
		return regex_ast_unicode_code_point(pattern, start)
	}
	code_point, width := utf8.decode_rune_in_string(pattern[start:])
	if code_point == utf8.RUNE_ERROR && width == 1 { return 0, 0, false }
	return u32(code_point), start + width, true
}

// Validate the group name starting at `start` and return the offset of its
// closing `>`.
@(private)
regex_ast_group_name :: proc(pattern: string, start: int) -> (int, RegexAstError) {
	for cursor := start; cursor < len(pattern); {
		if pattern[cursor] == '>' {
			if cursor == start { return 0, regex_ast_invalid(start, "Empty group name") }
			return cursor, {}
		}
		code_point, next, ok := regex_ast_name_code_point(pattern, cursor)
		if !ok { return 0, regex_ast_invalid(cursor, "Invalid group name") }
		valid: bool
		if cursor == start {
			valid = is_id_start_codepoint(code_point)
		} else {
			valid = is_id_cont_codepoint(code_point)
		}
		if !valid { return 0, regex_ast_invalid(cursor, "Invalid group name") }
		assert(next > cursor)
		cursor = next
	}
	return 0, regex_ast_invalid(start, "Unterminated group name")
}

// The name a span spells, with `\u` escapes decoded, so `(?<a>)` and
// `\k<a>` meet. Names without escapes are returned as a slice of the pattern.
@(private)
regex_ast_name_key :: proc(p: ^RegexAstParser, name: Loc) -> (string, RegexAstError) {
	pattern := p.pattern
	assert(name.start < name.end)
	raw := pattern[name.start:name.end]
	if strings.index_byte(raw, '\\') < 0 { return raw, {} }
	builder, alloc_err := strings.builder_make(0, len(raw), p.scratch)
	if alloc_err != nil { return "", {kind = .Allocation_Error} }
	for cursor := int(name.start); cursor < int(name.end); {
		code_point, next, ok := regex_ast_name_code_point(pattern, cursor)
		assert(ok) // regex_ast_group_name validated this span.
		strings.write_rune(&builder, rune(code_point))
		cursor = next
	}
	return strings.to_string(builder), {}
}
