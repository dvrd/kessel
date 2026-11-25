package kessel

import "core:strings"
import "core:unicode/utf8"

// Rules that inspect a regular expression see it in two places: a literal,
// whose pattern is source text, and the string or template passed to the
// RegExp constructor, whose pattern is the decoded value. LintRegExpSource
// gives both the same shape and maps a span of the pattern back to the bytes
// of the file that spell it, which is the range oxlint labels.
LintRegExpSource :: struct {
	pattern, flags: string,
	// Source offset of each pattern byte, plus one entry for the end. Nil for
	// a literal, where the pattern is a slice of the file starting at `base`.
	offsets: []u32,
	base:    u32,
	// The identifier that must be unbound for a constructor call to mean the
	// built-in RegExp. Nil for a literal.
	global: ^Identifier,
}

lint_regexp_loc :: proc(source: ^LintRegExpSource, span: Loc) -> Loc {
	assert(span.start <= span.end)
	if source.offsets == nil { return {source.base + span.start, source.base + span.end} }
	assert(int(span.end) < len(source.offsets))
	return {source.offsets[span.start], source.offsets[span.end]}
}

lint_regexp_emit :: proc(l: ^Linter, source: ^LintRegExpSource, loc: Loc, rule: LintRule, message := "") {
	if source.global == nil {
		lint_emit(l, loc, rule, message)
	} else {
		lint_report_if_global(l, source.global, loc, rule, message)
	}
}

// One escape sequence of a string or template literal, starting at the
// backslash. `value` is negative for a line continuation, which adds nothing
// to the string.
LintStringEscape :: struct {
	value: i32,
	size:  int,
}

lint_hex_digit :: proc(char: u8) -> (u32, bool) {
	switch char {
	case '0'..='9': return u32(char - '0'), true
	case 'a'..='f': return u32(char - 'a') + 10, true
	case 'A'..='F': return u32(char - 'A') + 10, true
	}
	return 0, false
}

lint_hex_run :: proc(raw: string, start, count: int) -> (value: u32, ok: bool) {
	if start + count > len(raw) { return 0, false }
	for index in start..<start + count {
		digit := lint_hex_digit(raw[index]) or_return
		value = value * 16 + digit
	}
	return value, true
}

lint_string_escape :: proc(raw: string, at: int) -> (escape: LintStringEscape, ok: bool) {
	assert(raw[at] == '\\')
	if at + 1 >= len(raw) { return {}, false }
	char := raw[at + 1]
	switch char {
	case 'n': return {'\n', 2}, true
	case 't': return {'\t', 2}, true
	case 'r': return {'\r', 2}, true
	case 'b': return {'\b', 2}, true
	case 'f': return {'\f', 2}, true
	case 'v': return {'\v', 2}, true
	case '\n': return {-1, 2}, true
	case '\r':
		if at + 2 < len(raw) && raw[at + 2] == '\n' { return {-1, 3}, true }
		return {-1, 2}, true
	case 'x':
		value := lint_hex_run(raw, at + 2, 2) or_return
		return {i32(value), 4}, true
	case 'u':
		if at + 2 < len(raw) && raw[at + 2] == '{' {
			close := strings.index_byte(raw[at:], '}')
			if close < 4 || close > 11 { return {}, false }
			value := lint_hex_run(raw, at + 3, close - 3) or_return
			return {i32(value), close + 1}, value <= 0x10FFFF
		}
		value := lint_hex_run(raw, at + 2, 4) or_return
		return {i32(value), 6}, true
	case '0'..='7':
		// Legacy octal: up to three digits, and no more than \377.
		digits_max := 3 if char <= '3' else 2
		value: i32
		size := 1
		for size <= digits_max && at + size < len(raw) {
			digit := raw[at + size]
			if digit < '0' || digit > '7' { break }
			value = value * 8 + i32(digit - '0')
			size += 1
		}
		return {value, size}, true
	}
	decoded, width := utf8.decode_rune_in_string(raw[at + 1:])
	if decoded == utf8.RUNE_ERROR { return {}, false }
	// LS and PS end a line too, so a backslash before one is a continuation.
	if decoded == 0x2028 || decoded == 0x2029 { return {-1, 1 + width}, true }
	return {i32(decoded), 1 + width}, true
}

lint_utf8_size :: proc(value: i32) -> int {
	switch {
	case value < 0x80:    return 1
	case value < 0x800:   return 2
	case value < 0x10000: return 3
	}
	return 4
}

// Maps every byte of a literal's decoded `value` to the source offset of the
// character or escape that produced it. `raw_loc` is the text between the
// quotes. The map ends with the offset just past the text. Fails when this
// decoding and the parser's disagree on the length, so a wrong map is never
// used.
lint_string_offsets :: proc(l: ^Linter, raw_loc: Loc, value: string) -> (offsets: []u32, ok: bool) {
	assert(raw_loc.start <= raw_loc.end)
	if int(raw_loc.end) > len(l.source) { return nil, false }
	raw := l.source[raw_loc.start:raw_loc.end]
	out := make([dynamic]u32, 0, len(value) + 1, l.allocator)
	high_pending := false
	for at := 0; at < len(raw); {
		start := raw_loc.start + u32(at)
		size := 1
		if raw[at] == '\\' {
			escape := lint_string_escape(raw, at) or_return
			at += escape.size
			if escape.value < 0 { continue }
			size = lint_utf8_size(escape.value)
			// A surrogate pair written as two escapes is stored as one
			// four-byte character: three bytes here and one for the low half.
			low := escape.value >= 0xDC00 && escape.value <= 0xDFFF
			if low && high_pending { size = 1 }
			high_pending = escape.value >= 0xD800 && escape.value <= 0xDBFF
		} else {
			_, size = utf8.decode_rune_in_string(raw[at:])
			at += size
			high_pending = false
		}
		for _ in 0..<size { append(&out, start) }
	}
	append(&out, raw_loc.end)
	if len(out) != len(value) + 1 { return nil, false }
	return out[:], true
}

// A string literal or a template without substitutions, as a pattern or flags
// argument. `raw_loc` excludes the quotes.
lint_regexp_argument :: proc(argument: ^Expression) -> (value: string, raw_loc: Loc, ok: bool) {
	inner := lint_inner(argument)
	if inner == nil { return "", {}, false }
	#partial switch node in inner^ {
	case ^StringLiteral:
		return node.value, {node.loc.start + 1, node.loc.end - 1}, true
	case ^TemplateLiteral:
		if len(node.expressions) != 0 || len(node.quasis) != 1 { return "", {}, false }
		cooked, valid := node.quasis[0].cooked.?
		return cooked, {node.loc.start + 1, node.loc.end - 1}, valid
	}
	return "", {}, false
}

// `RegExp` or `globalThis.RegExp`: the identifier that has to be unbound.
lint_regexp_callee :: proc(callee: ^Expression) -> ^Identifier {
	if callee == nil { return nil }
	#partial switch node in callee^ {
	case ^Identifier:
		return node if node.name == "RegExp" else nil
	case ^MemberExpression:
		object := lint_identifier(node.object)
		property := lint_identifier(node.property)
		if node.computed || object == nil || property == nil { return nil }
		if object.name == "globalThis" && property.name == "RegExp" { return object }
	}
	return nil
}

lint_regexp_rules_enabled :: proc(l: ^Linter) -> bool {
	return lint_rule_enabled(l, .L2039_NoControlRegex) || lint_rule_enabled(l, .L2037_NoUselessEscape) ||
		lint_rule_enabled(l, .L2059_NoMisleadingCharacterClass)
}

// The rules that read the pattern of `RegExp("…", "…")` and `new RegExp(…)`.
// Flags that are not a constant are treated as absent, as oxlint does.
lint_regexp_constructor :: proc(l: ^Linter, callee: ^Expression, arguments: []^Expression) {
	lint_check_invalid_regexp(l, callee, arguments)
	if len(arguments) == 0 || !lint_regexp_rules_enabled(l) { return }
	global := lint_regexp_callee(callee)
	if global == nil { return }
	pattern, pattern_loc, constant := lint_regexp_argument(arguments[0])
	if !constant { return }
	source := LintRegExpSource{pattern = pattern, global = global}
	if len(arguments) > 1 {
		flags, _, known := lint_regexp_argument(arguments[1])
		if known {
			source.flags = flags
		} else if inner := lint_inner(arguments[1]); inner != nil {
			// A template with substitutions as flags: the reference skips the call.
			if _, template := inner^.(^TemplateLiteral); template { return }
		}
	}
	offsets, mapped := lint_string_offsets(l, pattern_loc, pattern)
	if !mapped { return }
	source.offsets = offsets
	lint_regexp_rules(l, &source)
}

lint_regexp_literal :: proc(l: ^Linter, literal: ^RegExpLiteral) {
	if !lint_regexp_rules_enabled(l) { return }
	// The pattern starts one byte after the literal's opening slash.
	source := LintRegExpSource{pattern = literal.pattern, flags = literal.flags, base = literal.loc.start + 1}
	lint_regexp_rules(l, &source)
}

lint_regexp_rules :: proc(l: ^Linter, source: ^LintRegExpSource) {
	// Both rules need an escape or a character outside ASCII to report anything.
	interesting := false
	for char in transmute([]u8)source.pattern {
		if char == '\\' || char >= 0x80 || char < 0x20 { interesting = true; break }
	}
	if !interesting { return }
	tree, err := regex_parse_ast(source.pattern, source.flags, l.allocator)
	if err.kind != .None { return }
	defer regex_ast_destroy(&tree)
	lint_check_control_regex(l, source, &tree)
	lint_check_misleading_class(l, source, &tree)
	lint_check_useless_escape_regexp(l, source, &tree)
}

lint_regexp_is_character :: proc(node: ^RegexAstNode) -> (value: u32, ok: bool) {
	if node.kind != .Character && node.kind != .Escape { return 0, false }
	return node.code_point.?
}

// no-control-regex. oxlint decides from the spelling: a hexadecimal or
// Unicode escape, or an escape whose first character read as a hexadecimal
// digit equals the value (`\0`, an octal `\1` that is not a backreference, and
// by the same test `\cL`). A raw control character is not reported.
lint_check_control_regex :: proc(l: ^Linter, source: ^LintRegExpSource, tree: ^RegexAst) {
	if !lint_rule_enabled(l, .L2039_NoControlRegex) { return }
	first: Loc
	found := false
	for &node in tree.nodes[1:] {
		value, is_character := lint_regexp_is_character(&node)
		if !is_character || value > 0x1F { continue }
		// The reference drops values that could be a group number, whatever the spelling.
		if tree.capture_count > 0 && value > 1 && value <= tree.capture_count { continue }
		loc := lint_regexp_loc(source, node.span)
		if !lint_control_spelling(l.source[loc.start:loc.end], value) { continue }
		if !found || loc.start < first.start { first = loc }
		found = true
	}
	if found { lint_regexp_emit(l, source, first, .L2039_NoControlRegex) }
}

lint_control_spelling :: proc(text: string, value: u32) -> bool {
	if strings.has_prefix(text, "\\x") || strings.has_prefix(text, "\\\\x") { return true }
	if strings.has_prefix(text, "\\u") || strings.has_prefix(text, "\\\\u") { return true }
	rest := strings.trim_left(text, "\\")
	if len(rest) == 0 { return false }
	digit, is_digit := lint_hex_digit(rest[0])
	return is_digit && digit == value
}

LintClassCharacter :: struct {
	value:   u32,
	span:    Loc,
	unicode: bool, // \uXXXX or \u{…}
	escape:  bool, // any escape that names the character by number
}

lint_class_character :: proc(l: ^Linter, source: ^LintRegExpSource, node: ^RegexAstNode) -> (LintClassCharacter, bool) {
	value, is_character := lint_regexp_is_character(node)
	if !is_character { return {}, false }
	item := LintClassCharacter{value = value, span = node.span}
	// The spelling decides, so an escape of the string that holds the pattern
	// counts like an escape of the pattern.
	loc := lint_regexp_loc(source, node.span)
	rest := strings.trim_left(l.source[loc.start:loc.end], "\\")
	if len(rest) > 0 && len(rest) < int(loc.end - loc.start) {
		switch rest[0] {
		case 'u': item.unicode, item.escape = true, true
		case 'x', 'c', '0'..='9': item.escape = true
		}
	}
	return item, true
}

// Without `u` the tree gives both halves of a character outside the BMP the
// character's span. The reference gives it to the high half and an empty
// range at its end to the low half.
lint_class_run_append :: proc(
	l: ^Linter, source: ^LintRegExpSource, run: ^[dynamic]LintClassCharacter, node: ^RegexAstNode,
) -> bool {
	item := lint_class_character(l, source, node) or_return
	if len(run) > 0 && item.span.start != item.span.end && run[len(run) - 1].span == item.span {
		item.span.start = item.span.end
	}
	append(run, item)
	return true
}

// no-misleading-character-class: a class lists code points, so a character
// made of several (a surrogate pair without `u`, a base and a combining mark,
// a flag, a joined emoji) matches its parts one at a time.
lint_check_misleading_class :: proc(l: ^Linter, source: ^LintRegExpSource, tree: ^RegexAst) {
	if !lint_rule_enabled(l, .L2059_NoMisleadingCharacterClass) { return }
	if !strings.contains(source.pattern, "[") { return }
	run := make([dynamic]LintClassCharacter, 0, 16, l.allocator)
	for &class in tree.nodes[1:] {
		if class.kind != .Character_Class { continue }
		clear(&run)
		for child := class.first_child; child != 0; child = tree.nodes[child].next_sibling {
			node := &tree.nodes[child]
			if node.kind == .Class_Range {
				low := node.first_child
				assert(low != 0)
				high := tree.nodes[low].next_sibling
				assert(high != 0)
				lint_class_run_append(l, source, &run, &tree.nodes[low])
				lint_misleading_run(l, source, run[:])
				clear(&run)
				lint_class_run_append(l, source, &run, &tree.nodes[high])
			} else if lint_class_run_append(l, source, &run, node) {
				// The run continues.
			} else {
				lint_misleading_run(l, source, run[:])
				clear(&run)
			}
		}
		lint_misleading_run(l, source, run[:])
	}
}

lint_is_combining :: proc(value: u32) -> bool {
	switch value {
	case 0x0300..=0x036F, 0x1AB0..=0x1AFF, 0x1DC0..=0x1DFF, 0x20D0..=0x20FF,
	     0xFE20..=0xFE2F, 0xFE00..=0xFE0F, 0xE0100..=0xE01EF:
		return true
	}
	return false
}

lint_is_regional_indicator :: proc(value: u32) -> bool { return value >= 0x1F1E6 && value <= 0x1F1FF }
lint_is_emoji_modifier :: proc(value: u32) -> bool { return value >= 0x1F3FB && value <= 0x1F3FF }

// Every test runs over each adjacent pair, so one pair can be reported by
// more than one of them, as in the reference.
lint_misleading_run :: proc(l: ^Linter, source: ^LintRegExpSource, run: []LintClassCharacter) {
	rule := LintRule.L2059_NoMisleadingCharacterClass
	if l.options.misleading_allow_escape {
		for item in run {
			if item.escape { return }
		}
	}
	for index in 1..<len(run) {
		previous, current := run[index - 1], run[index]
		loc := lint_regexp_loc(source, {previous.span.start, current.span.end})
		if lint_is_combining(current.value) && !lint_is_combining(previous.value) {
			lint_regexp_emit(l, source, loc, rule, "Unexpected combining class in character class.")
		}
		if lint_is_regional_indicator(previous.value) && lint_is_regional_indicator(current.value) {
			lint_regexp_emit(l, source, loc, rule, "Unexpected regional indicator in character class.")
		}
		if lint_is_emoji_modifier(current.value) && !lint_is_emoji_modifier(previous.value) {
			lint_regexp_emit(l, source, loc, rule, "Unexpected emoji modifier in character class.")
		}
		high := previous.value >= 0xD800 && previous.value <= 0xDBFF
		if high && current.value >= 0xDC00 && current.value <= 0xDFFF {
			lint_regexp_emit(l, source, loc, rule, "Unexpected surrogate pair in character class.")
		}
		if index + 1 < len(run) && current.value == 0x200D && previous.value != 0x200D {
			next := run[index + 1]
			if next.value != 0x200D {
				joined := lint_regexp_loc(source, {previous.span.start, next.span.end})
				message := "Unexpected joined character sequence in character class."
				lint_regexp_emit(l, source, joined, rule, message)
			}
		}
	}
}

// no-invalid-regexp: the flags first, then the pattern. A range of length
// zero marks the offending flag, as in the reference.
lint_check_invalid_regexp :: proc(l: ^Linter, callee: ^Expression, arguments: []^Expression) {
	rule := LintRule.L2058_NoInvalidRegexp
	if !lint_rule_enabled(l, rule) || len(arguments) == 0 { return }
	if !lint_is_specific_id(callee, "RegExp") { return }
	pattern, has_pattern := arguments[0]^.(^StringLiteral)
	unicode, unicode_sets := false, false
	if len(arguments) > 1 {
		flags, has_flags := arguments[1]^.(^StringLiteral)
		if !has_flags {
			has_pattern = false
		} else {
			if int(flags.loc.end) > len(l.source) { return }
			text := strings.trim(strings.trim(l.source[flags.loc.start:flags.loc.end], "'"), "\"")
			seen: [128]bool
			for char, index in text {
				at := flags.loc.start + 1 + u32(index)
				point := Loc{at, at}
				if (char == 'u' && unicode_sets) || (char == 'v' && unicode) {
					message := "Invalid regular expression: `u` and `v` flags should be used alone"
					lint_emit(l, point, rule, message)
					return
				}
				if char == 'u' { unicode = true }
				if char == 'v' { unicode_sets = true }
				if char >= 128 || seen[char] {
					duplicate := char < 128
					message := "Invalid regular expression: Unknown flag"
					if duplicate { message = "Invalid regular expression: Duplicated flag" }
					lint_emit(l, point, rule, message)
					return
				}
				seen[char] = true
				known := strings.index_rune("dgimsuvy", char) >= 0
				if !known && strings.index_rune(l.options.invalid_regexp_flags, char) < 0 {
					lint_emit(l, point, rule, "Invalid regular expression: Unknown flag")
					return
				}
			}
		}
	}
	if !has_pattern { return }
	flags := "v" if unicode_sets else ("u" if unicode else "")
	tree, err := regex_parse_ast(pattern.value, flags, l.allocator)
	if err.kind == .None {
		regex_ast_destroy(&tree)
		return
	}
	if err.kind != .Invalid_Pattern { return }
	offsets, mapped := lint_string_offsets(l, {pattern.loc.start + 1, pattern.loc.end - 1}, pattern.value)
	if !mapped { return }
	span := lint_invalid_regexp_span(pattern.value, err)
	lint_emit(l, {offsets[span.start], offsets[span.end]}, rule, "Invalid regular expression")
}

// The reference labels each kind of pattern error differently: some from the
// start of the construct to where parsing stopped, some as an empty range.
// The tree builder reports one offset, so the kinds the upstream tests cover
// are rebuilt here from its message. Any other error is marked at its offset.
lint_invalid_regexp_span :: proc(pattern: string, err: RegexAstError) -> Loc {
	at := min(err.offset, u32(len(pattern)))
	end := u32(len(pattern))
	next := min(at + 1, end)
	switch err.message {
	case "Unterminated character class", "Trailing regexp escape":
		return {at, end}
	case "Invalid identity escape":
		return {next, next}
	case "Term cannot be quantified":
		return {at, next}
	case "Character class range is reversed":
		return {at, min(at + 2, end)}
	case "Duplicate capture group name":
		// The first group of that name is labelled first.
		close := strings.index_byte(pattern[at:], '>')
		if close < 0 { return {at, at} }
		name := pattern[at:int(at) + close]
		for index in 0..<int(at) {
			rest := pattern[index:]
			if !strings.has_prefix(rest, "(?<") || !strings.has_prefix(rest[3:], name) { continue }
			if rest[3 + len(name)] != '>' { continue }
			return {u32(index) + 3, u32(index) + 3 + u32(len(name))}
		}
	case "Repeated modifier flag", "Modifier group changes no flags", "Invalid modifier flag":
		open := strings.last_index(pattern[:at], "(?")
		if open < 0 { return {at, at} }
		return {u32(open) + 2, at if err.message == "Invalid modifier flag" else next}
	}
	return {at, at}
}
