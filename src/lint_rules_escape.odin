package kessel

import "core:strings"
import "core:unicode/utf8"

// no-useless-escape: a backslash before a character that means the same
// without it. The range is the backslash and the character.

LINT_STRING_ESCAPES :: "\\nrvtbfux\n\r\u2028\u2029"

lint_useless_escape_emit :: proc(l: ^Linter, backslash: u32) {
	assert(int(backslash) + 1 < len(l.source))
	_, width := utf8.decode_rune_in_string(l.source[backslash + 1:])
	lint_emit(l, {backslash, backslash + 1 + u32(width)}, .L2037_NoUselessEscape)
}

// `loc` covers the quotes. A backslash directly after another backslash is
// never examined, which also skips the escape in `\\\a`; the reference does
// the same.
lint_check_useless_escape_string :: proc(l: ^Linter, loc: Loc) {
	if !lint_rule_enabled(l, .L2037_NoUselessEscape) { return }
	if loc.end < loc.start + 2 || int(loc.end) > len(l.source) { return }
	text := l.source[loc.start:loc.end]
	if !strings.contains_rune(text, '\\') { return }
	quote := rune(text[0])
	previous := -2
	for index in 1..<len(text) - 1 {
		if text[index] != '\\' { continue }
		after_backslash := previous == index - 1
		previous = index
		if after_backslash { continue }
		char, _ := utf8.decode_rune_in_string(text[index + 1:])
		if char == quote || (char >= '0' && char <= '9') { continue }
		if strings.contains_rune(LINT_STRING_ESCAPES, char) { continue }
		lint_useless_escape_emit(l, loc.start + u32(index))
	}
}

// A template that is not the quasi of a tagged template, where escapes are
// the tag's business.
lint_check_useless_escape_template :: proc(l: ^Linter, template: ^TemplateLiteral) {
	if !lint_rule_enabled(l, .L2037_NoUselessEscape) { return }
	if parent := lint_ancestor_expr(l, 1); parent != nil {
		tagged, is_tagged := parent^.(^TaggedTemplateExpression)
		if is_tagged && tagged.quasi != nil && lint_expr_loc(tagged.quasi) == template.loc { return }
	}
	for element in template.quasis {
		if int(element.loc.end) > len(l.source) || element.loc.end < element.loc.start { continue }
		text := l.source[element.loc.start:element.loc.end]
		if !strings.contains_rune(text, '\\') { continue }
		escaped := false
		before: rune = '`' // the last character that did not start an escape
		for index := 0; index < len(text); {
			char, width := utf8.decode_rune_in_string(text[index:])
			at := index
			index += width
			if !escaped {
				if char == '\\' { escaped = true } else { before = char }
				continue
			}
			escaped = false
			useless: bool
			switch {
			case (char >= '0' && char <= '9') || char == '`':
				useless = false
			case char == '{':
				useless = before != '$'
			case char == '$':
				// `\${` keeps a substitution from starting.
				useless = index < len(text) && text[index] != '{'
			case:
				useless = !strings.contains_rune(LINT_STRING_ESCAPES, char)
			}
			if useless { lint_useless_escape_emit(l, element.loc.start + u32(at) - 1) }
			before = char
		}
	}
}

LINT_REGEX_ESCAPES_CLASS :: "\\bcdDfnpPrsStvwWxu0123456789]"
LINT_REGEX_ESCAPES_OUTSIDE :: "\\bcdDfnpPrsStvwWxu0123456789]^/.$*+?[{}|()Bk"
LINT_REGEX_ESCAPES_CLASS_SET :: "\\bcdDfnpPrsStvwWxu0123456789]q/[{}|()-"
LINT_REGEX_DOUBLE_PUNCTUATORS :: "!#$%&*+,.:;<=>?@^`~"

LintRegExpVisit :: struct {
	node, class: u32,
}

// Every escaped character of a regular expression literal, with the class it
// sits in. The tree is walked with a worklist, so nesting costs no stack.
lint_check_useless_escape_regexp :: proc(l: ^Linter, source: ^LintRegExpSource, tree: ^RegexAst) {
	if !lint_rule_enabled(l, .L2037_NoUselessEscape) || source.global != nil { return }
	work := make([dynamic]LintRegExpVisit, 0, 32, l.allocator)
	append(&work, LintRegExpVisit{tree.root, 0})
	for len(work) > 0 {
		visit := pop(&work)
		node := &tree.nodes[visit.node]
		class := visit.node if node.kind == .Character_Class else visit.class
		for child := node.first_child; child != 0; child = tree.nodes[child].next_sibling {
			append(&work, LintRegExpVisit{child, class})
		}
		if node.kind != .Escape || node.span.end < node.span.start + 2 { continue }
		if _, is_character := node.code_point.?; !is_character { continue }
		if lint_regexp_escape_useless(l, source, tree, node, visit.class) {
			loc := lint_regexp_loc(source, node.span)
			if strings.index_byte(l.options.useless_escape_allow, l.source[loc.end - 1]) < 0 {
				lint_emit(l, loc, .L2037_NoUselessEscape)
			}
		}
	}
}

lint_regexp_escape_useless :: proc(
	l: ^Linter, source: ^LintRegExpSource, tree: ^RegexAst, node: ^RegexAstNode, class_index: u32,
) -> bool {
	pattern := source.pattern
	char := pattern[node.span.start + 1]
	unicode_sets := .Unicode_Sets in tree.flags
	if class_index == 0 { return strings.index_byte(LINT_REGEX_ESCAPES_OUTSIDE, char) < 0 }
	allowed := LINT_REGEX_ESCAPES_CLASS_SET if unicode_sets else LINT_REGEX_ESCAPES_CLASS
	if strings.index_byte(allowed, char) >= 0 { return false }
	class := tree.nodes[class_index]
	first := class.span.start + 1
	// `^` needs its escape only where it would negate the class.
	if char == '^' && first == node.span.start { return false }
	if !unicode_sets {
		// `-` needs its escape only between two members.
		middle := first != node.span.start && node.span.end != class.span.end - 1
		return !(char == '-' && middle)
	}
	if strings.index_byte(LINT_REGEX_DOUBLE_PUNCTUATORS, char) < 0 { return true }
	// The escape keeps two punctuators from forming a reserved pair.
	if int(node.span.end) < len(pattern) && pattern[node.span.end] == char { return false }
	if node.span.start > 0 && pattern[node.span.start - 1] == char {
		if char != '^' || !class.negative { return false }
		return !(first < node.span.start - 1)
	}
	return true
}

// A string that is the value of a JSX attribute has no escapes to judge.
lint_check_useless_escape_expr :: proc(l: ^Linter, literal: ^StringLiteral) {
	if parent := lint_ancestor_expr(l, 1); parent != nil {
		if _, jsx := parent^.(^JSXElement); jsx { return }
	}
	lint_check_useless_escape_string(l, literal.loc)
}

// A quoted property key. The walk does not visit plain keys.
lint_check_useless_escape_key :: proc(l: ^Linter, key: ^Expression) {
	if literal, quoted := key^.(^StringLiteral); quoted { lint_check_useless_escape_string(l, literal.loc) }
}
