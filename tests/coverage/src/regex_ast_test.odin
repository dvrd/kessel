package coverage

import "core:testing"

import kessel "../../../src"

@(test)
test_regex_ast_structure :: proc(t: ^testing.T) {
	pattern := `^(?<word>[a-z]+?){2,4}|(?<=π)\k<word>\1$`
	ast, err := kessel.regex_parse_ast(pattern, "giu", context.allocator)
	if !testing.expectf(t, err.kind == .None, "%v", err) { return }
	defer kessel.regex_ast_destroy(&ast)
	testing.expect_value(t, ast.capture_count, u32(1))
	testing.expect_value(t, ast.has_named_captures, true)
	testing.expect_value(t, .Global in ast.flags && .Ignore_Case in ast.flags && .Unicode in ast.flags, true)
	root := ast.nodes[ast.root]
	first := ast.nodes[root.first_child]
	second := ast.nodes[first.next_sibling]
	testing.expect_value(t, root.kind, .Pattern)
	testing.expect_value(t, pattern[first.span.start:first.span.end], `^(?<word>[a-z]+?){2,4}`)
	testing.expect_value(t, pattern[second.span.start:second.span.end], `(?<=π)\k<word>\1$`)

	assertion := ast.nodes[first.first_child]
	repeat := ast.nodes[assertion.next_sibling]
	group := ast.nodes[repeat.first_child]
	nongreedy := ast.nodes[ast.nodes[group.first_child].first_child]
	characters := ast.nodes[nongreedy.first_child]
	range := ast.nodes[characters.first_child]
	testing.expect_value(t, assertion.kind, .Start_Assertion)
	if !testing.expect_value(t, repeat.kind, .Quantifier) { return }
	testing.expect_value(t, repeat.repeat.min.value, u64(2))
	testing.expect_value(t, repeat.repeat.max.?.value, u64(4))
	testing.expect_value(t, repeat.repeat.greedy, true)
	testing.expect_value(t, group.group_kind, .Named_Capture)
	testing.expect_value(t, pattern[group.name.start:group.name.end], "word")
	testing.expect_value(t, nongreedy.kind, .Quantifier)
	testing.expect_value(t, nongreedy.repeat.min.value, u64(1))
	testing.expect_value(t, nongreedy.repeat.max == nil, true)
	testing.expect_value(t, nongreedy.repeat.greedy, false)
	testing.expect_value(t, characters.kind, .Character_Class)
	testing.expect_value(t, range.kind, .Class_Range)
	testing.expect_value(t, pattern[range.span.start:range.span.end], "a-z")

	lookbehind := ast.nodes[second.first_child]
	named := ast.nodes[lookbehind.next_sibling]
	reference := ast.nodes[named.next_sibling]
	testing.expect_value(t, lookbehind.group_kind, .Lookbehind)
	testing.expect_value(t, named.kind, .Named_Reference)
	testing.expect_value(t, pattern[named.name.start:named.name.end], "word")
	testing.expect_value(t, reference.kind, .Indexed_Reference)
	testing.expect_value(t, reference.capture_index, u32(1))
	testing.expect_value(t, ast.nodes[reference.next_sibling].kind, .End_Assertion)
}

@(test)
test_regex_ast_unicode_sets :: proc(t: ^testing.T) {
	pattern := `[[\p{L}&&[^\p{ASCII}]]--[\q{ab|cd}]]`
	ast, err := kessel.regex_parse_ast(pattern, "v", context.allocator)
	if !testing.expectf(t, err.kind == .None, "%v", err) { return }
	defer kessel.regex_ast_destroy(&ast)
	outer := ast.nodes[ast.nodes[ast.nodes[ast.root].first_child].first_child]
	inner := ast.nodes[outer.first_child]
	property := ast.nodes[inner.first_child]
	intersection := ast.nodes[property.next_sibling]
	negated := ast.nodes[intersection.next_sibling]
	subtraction := ast.nodes[inner.next_sibling]
	removed := ast.nodes[subtraction.next_sibling]
	strings := ast.nodes[removed.first_child]
	left := ast.nodes[strings.first_child]
	right := ast.nodes[left.next_sibling]
	testing.expect_value(t, outer.kind, .Character_Class)
	testing.expect_value(t, property.kind, .Property_Escape)
	testing.expect_value(t, pattern[property.name.start:property.name.end], "L")
	testing.expect_value(t, intersection.kind, .Class_Intersection)
	testing.expect_value(t, negated.negative, true)
	testing.expect_value(t, subtraction.kind, .Class_Subtraction)
	testing.expect_value(t, strings.kind, .Class_String)
	testing.expect_value(t, pattern[left.span.start:left.span.end], "ab")
	testing.expect_value(t, pattern[right.span.start:right.span.end], "cd")
	testing.expect_value(t, strings.may_contain_strings, true)
	testing.expect_value(t, outer.may_contain_strings, false)
	allowed, allowed_err := kessel.regex_parse_ast(`[^\p{RGI_Emoji}&&a]`, "v", context.allocator)
	defer kessel.regex_ast_destroy(&allowed)
	testing.expect_value(t, allowed_err.kind, .None)
}

@(test)
test_regex_ast_legacy_and_invalid :: proc(t: ^testing.T) {
	invalid := [?]struct{pattern, flags: string, kind: kessel.RegexAstErrorKind}{
		{"(", "", .Invalid_Pattern}, {"[a", "", .Invalid_Pattern},
		{"a++", "", .Invalid_Pattern}, {"a{5,2}", "", .Invalid_Pattern},
		{"standalone}", "u", .Invalid_Pattern}, {"a{b}", "u", .Invalid_Pattern},
		{"[z-a]", "", .Invalid_Pattern},
		{"[a-z&&[abcd]]", "v", .Invalid_Pattern}, {"[a&&b--c]", "v", .Invalid_Pattern},
		{`[^\q{ab}]`, "v", .Invalid_Pattern}, {`[^\p{RGI_Emoji}--\q{ab}]`, "v", .Invalid_Pattern},
		{"a{999999999999999999999,999999999999999999998}", "", .Invalid_Pattern},
		{"x", "uu", .Invalid_Flags}, {"x", "z", .Invalid_Flags},
		{"x", "uv", .Invalid_Flags}, { `\00`, "u", .Invalid_Pattern},
	}
	for fixture in invalid {
		ast, err := kessel.regex_parse_ast(fixture.pattern, fixture.flags, context.allocator)
		testing.expectf(t, err.kind == fixture.kind, "/%s/%s: expected %v, got %v", fixture.pattern, fixture.flags, fixture.kind, err)
		kessel.regex_ast_destroy(&ast)
	}
	pattern := `\1(a)\18+\k<x>|a{b}`
	ast, err := kessel.regex_parse_ast(pattern, "", context.allocator)
	if !testing.expect_value(t, err.kind, .None) { return }
	defer kessel.regex_ast_destroy(&ast)
	first := ast.nodes[ast.nodes[ast.root].first_child]
	backreference := ast.nodes[first.first_child]
	group := ast.nodes[backreference.next_sibling]
	octal := ast.nodes[group.next_sibling]
	repeated := ast.nodes[octal.next_sibling]
	identity := ast.nodes[repeated.next_sibling]
	testing.expect_value(t, backreference.kind, .Indexed_Reference)
	testing.expect_value(t, pattern[octal.span.start:octal.span.end], `\1`)
	testing.expect_value(t, pattern[repeated.span.start:repeated.span.end], "8+")
	testing.expect_value(t, identity.kind, .Escape)
	testing.expect_value(t, pattern[identity.span.start:identity.span.end], `\k`)
}

@(test)
test_regex_ast_character_values :: proc(t: ^testing.T) {
	pattern := `\uD83D\uDE00+\cA\0\p{Script=Greek}`
	ast, err := kessel.regex_parse_ast(pattern, "u", context.allocator)
	if !testing.expect_value(t, err.kind, .None) { return }
	defer kessel.regex_ast_destroy(&ast)
	alt := ast.nodes[ast.nodes[ast.root].first_child]
	repeat := ast.nodes[alt.first_child]
	emoji := ast.nodes[repeat.first_child]
	control := ast.nodes[repeat.next_sibling]
	null := ast.nodes[control.next_sibling]
	property := ast.nodes[null.next_sibling]
	testing.expect_value(t, emoji.code_point, Maybe(u32)(0x1f600))
	testing.expect_value(t, pattern[repeat.span.start:repeat.span.end], `\uD83D\uDE00+`)
	testing.expect_value(t, control.code_point, Maybe(u32)(1))
	testing.expect_value(t, null.code_point, Maybe(u32)(0))
	testing.expect_value(t, pattern[property.name.start:property.name.end], "Script")
	value := property.property_value.?
	testing.expect_value(t, pattern[value.start:value.end], "Greek")
}


@(test)
test_regex_ast_legacy_code_units :: proc(t: ^testing.T) {
	pattern := "😀+"
	legacy, legacy_err := kessel.regex_parse_ast(pattern, "", context.allocator)
	if !testing.expect_value(t, legacy_err.kind, .None) { return }
	defer kessel.regex_ast_destroy(&legacy)
	first := legacy.nodes[legacy.nodes[legacy.nodes[legacy.root].first_child].first_child]
	repeat := legacy.nodes[first.next_sibling]
	second := legacy.nodes[repeat.first_child]
	testing.expect_value(t, first.code_point, Maybe(u32)(0xd83d))
	testing.expect_value(t, repeat.kind, .Quantifier)
	testing.expect_value(t, second.code_point, Maybe(u32)(0xde00))
	testing.expect_value(t, second.span, first.span)

	unicode, unicode_err := kessel.regex_parse_ast(pattern, "u", context.allocator)
	if !testing.expect_value(t, unicode_err.kind, .None) { return }
	defer kessel.regex_ast_destroy(&unicode)
	unicode_repeat := unicode.nodes[unicode.nodes[unicode.nodes[unicode.root].first_child].first_child]
	testing.expect_value(t, unicode_repeat.kind, .Quantifier)
	testing.expect_value(t, unicode.nodes[unicode_repeat.first_child].code_point, Maybe(u32)(0x1f600))

	class, class_err := kessel.regex_parse_ast("[a-😀]", "", context.allocator)
	if !testing.expect_value(t, class_err.kind, .None) { return }
	defer kessel.regex_ast_destroy(&class)
	class_node := class.nodes[class.nodes[class.nodes[class.root].first_child].first_child]
	range := class.nodes[class_node.first_child]
	right := class.nodes[class.nodes[range.first_child].next_sibling]
	testing.expect_value(t, range.kind, .Class_Range)
	testing.expect_value(t, right.code_point, Maybe(u32)(0xd83d))
	testing.expect_value(t, class.nodes[range.next_sibling].code_point, Maybe(u32)(0xde00))

	reversed, reversed_err := kessel.regex_parse_ast("[😀-a]", "", context.allocator)
	defer kessel.regex_ast_destroy(&reversed)
	testing.expect_value(t, reversed_err.kind, .Invalid_Pattern)
}

// Helpers for the grammar-area tests below. Each test parses a few patterns
// and checks node kinds, spans, values and capture indices by walking the
// first_child / next_sibling links from the first alternative.

@(private="file")
RegexCase :: struct {
	pattern, flags: string,
}

// The `index`-th child of `parent`, or node zero (kind Pattern, empty span)
// when the chain is shorter. Tests then fail on the kind they expect.
@(private="file")
regex_test_child :: proc(
	ast: ^kessel.RegexAst,
	parent: kessel.RegexAstNode,
	index: int,
) -> kessel.RegexAstNode {
	id := parent.first_child
	for _ in 0..<index {
		if id == 0 { break }
		id = ast.nodes[id].next_sibling
	}
	return ast.nodes[id]
}

@(private="file")
regex_test_count :: proc(ast: ^kessel.RegexAst, parent: kessel.RegexAstNode) -> int {
	count := 0
	for id := parent.first_child; id != 0; id = ast.nodes[id].next_sibling { count += 1 }
	return count
}

// The first alternative of the pattern.
@(private="file")
regex_test_terms :: proc(ast: ^kessel.RegexAst) -> kessel.RegexAstNode {
	return ast.nodes[ast.nodes[ast.root].first_child]
}

@(private="file")
regex_test_text :: proc(pattern: string, span: kessel.Loc) -> string {
	return pattern[span.start:span.end]
}

@(private="file")
regex_test_all :: proc(t: ^testing.T, cases: []RegexCase, expected: kessel.RegexAstErrorKind) {
	for item in cases {
		ast, err := kessel.regex_parse_ast(item.pattern, item.flags, context.allocator)
		testing.expectf(
			t, err.kind == expected,
			"/%s/%s: expected %v, got %v", item.pattern, item.flags, expected, err,
		)
		kessel.regex_ast_destroy(&ast)
	}
}

@(test)
test_regex_ast_modifiers :: proc(t: ^testing.T) {
	pattern := `(?i-ms:a)(?s:.)(?-i:b)(?:c)`
	ast, err := kessel.regex_parse_ast(pattern, "", context.allocator)
	if !testing.expectf(t, err.kind == .None, "%v", err) { return }
	defer kessel.regex_ast_destroy(&ast)
	terms := regex_test_terms(&ast)
	mixed := regex_test_child(&ast, terms, 0)
	testing.expect_value(t, mixed.group_kind, kessel.RegexGroupKind.Modifiers)
	testing.expect_value(t, mixed.modifiers.add, kessel.RegexAstFlags{.Ignore_Case})
	testing.expect_value(t, mixed.modifiers.remove, kessel.RegexAstFlags{.Multiline, .Dot_All})
	testing.expect_value(t, regex_test_text(pattern, mixed.name), "i-ms")
	testing.expect_value(t, regex_test_text(pattern, mixed.span), "(?i-ms:a)")
	testing.expect_value(t, mixed.capture_index, u32(0))
	adding := regex_test_child(&ast, terms, 1)
	testing.expect_value(t, adding.modifiers.add, kessel.RegexAstFlags{.Dot_All})
	testing.expect_value(t, adding.modifiers.remove, kessel.RegexAstFlags{})
	removing := regex_test_child(&ast, terms, 2)
	testing.expect_value(t, removing.modifiers.add, kessel.RegexAstFlags{})
	testing.expect_value(t, removing.modifiers.remove, kessel.RegexAstFlags{.Ignore_Case})
	plain := regex_test_child(&ast, terms, 3)
	testing.expect_value(t, plain.group_kind, kessel.RegexGroupKind.Noncapturing)
	testing.expect_value(t, plain.modifiers, kessel.RegexModifiers{})

	regex_test_all(t, {{`(?i-:a)`, ""}, {`(?-i:a)`, "u"}, {`(?ims:a)`, "v"}}, .None)
	regex_test_all(t, {
		{`(?-:a)`, ""}, {`(?ii:a)`, ""}, {`(?i-i:a)`, ""}, {`(?i-m-s:a)`, ""}, {`(?u:a)`, ""},
		{`(?I:a)`, ""}, {`(?i`, ""}, {`(?i-`, ""}, {`(?i)`, ""}, {`(?i:a`, ""},
	}, .Invalid_Pattern)
}

@(test)
test_regex_ast_duplicate_names :: proc(t: ^testing.T) {
	pattern := `(?:(?<y>\d{4})-(\d{2})|(\d{2})-(?<y>\d{4}))\k<y>`
	ast, err := kessel.regex_parse_ast(pattern, "", context.allocator)
	if !testing.expectf(t, err.kind == .None, "%v", err) { return }
	defer kessel.regex_ast_destroy(&ast)
	testing.expect_value(t, ast.capture_count, u32(4))
	outer := regex_test_child(&ast, regex_test_terms(&ast), 0)
	first := regex_test_child(&ast, outer, 0)
	second := regex_test_child(&ast, outer, 1)
	testing.expect_value(t, regex_test_child(&ast, first, 0).capture_index, u32(1))
	testing.expect_value(t, regex_test_child(&ast, first, 2).capture_index, u32(2))
	testing.expect_value(t, regex_test_child(&ast, second, 0).capture_index, u32(3))
	late := regex_test_child(&ast, second, 2)
	testing.expect_value(t, late.capture_index, u32(4))
	testing.expect_value(t, late.group_kind, kessel.RegexGroupKind.Named_Capture)
	testing.expect_value(t, regex_test_text(pattern, late.name), "y")
	reference := regex_test_child(&ast, regex_test_terms(&ast), 1)
	testing.expect_value(t, reference.kind, kessel.RegexAstKind.Named_Reference)

	regex_test_all(t, {
		{`(?<a>x)|(?<a>y)|(?<a>z)`, ""}, {`(?<a>x)|(?:(?<a>y)|(?<a>z))`, "u"},
		{`((?<a>x)|(?<b>y))|(?<a>z)`, ""}, {`(?<a>a)(?<A>b)`, ""},
		// A name spelled with an escape is the same name.
		{`(?<\u0061>x)\k<a>`, ""}, {`(?<a>x)\k<\u{61}>`, ""}, {`(?<\ud835\udc9c>x)`, ""},
		{`(?<𝒜>x)\k<\u{1d49c}>`, ""},
	}, .None)
	regex_test_all(t, {
		{`(?<a>x)(?<a>y)`, ""}, {`(?<a>(?<a>x))`, ""}, {`(?<a>x)(?:(?<a>y)|(?<a>z))`, ""},
		{`(?<a>x)|(?<b>y)(?<a>z)(?<a>w)`, ""}, {`(?:(?<a>x)|(?<a>y))(?<a>z)`, "u"},
		{`(?<a>x)(?<\u0061>y)`, ""}, {`(?<a>x)\k<b>`, ""}, {`(?<1a>x)`, ""}, {`(?<>x)`, ""},
		{`(?<a`, ""}, {`(?<\ud835>x)`, ""},
	}, .Invalid_Pattern)
}

@(test)
test_regex_ast_annex_b :: proc(t: ^testing.T) {
	// Without named groups `\k` is an identity escape; `\c` before a non-letter
	// is a literal backslash and the `c` is its own, quantifiable atom.
	pattern := `\k<a>\c*\x\u{2}(?=b)+{]}`
	ast, err := kessel.regex_parse_ast(pattern, "", context.allocator)
	if !testing.expectf(t, err.kind == .None, "%v", err) { return }
	defer kessel.regex_ast_destroy(&ast)
	terms := regex_test_terms(&ast)
	identity := regex_test_child(&ast, terms, 0)
	testing.expect_value(t, identity.kind, kessel.RegexAstKind.Escape)
	testing.expect_value(t, identity.code_point, Maybe(u32)('k'))
	testing.expect_value(t, regex_test_text(pattern, identity.span), `\k`)
	backslash := regex_test_child(&ast, terms, 4)
	testing.expect_value(t, backslash.kind, kessel.RegexAstKind.Character)
	testing.expect_value(t, backslash.code_point, Maybe(u32)('\\'))
	testing.expect_value(t, regex_test_text(pattern, backslash.span), `\`)
	starred := regex_test_child(&ast, terms, 5)
	testing.expect_value(t, starred.kind, kessel.RegexAstKind.Quantifier)
	testing.expect_value(t, regex_test_text(pattern, starred.span), `c*`)
	hex := regex_test_child(&ast, terms, 6)
	testing.expect_value(t, hex.code_point, Maybe(u32)('x'))
	testing.expect_value(t, regex_test_text(pattern, hex.span), `\x`)
	braced := regex_test_child(&ast, terms, 7)
	testing.expect_value(t, braced.kind, kessel.RegexAstKind.Quantifier)
	testing.expect_value(t, regex_test_text(pattern, braced.span), `\u{2}`)
	testing.expect_value(t, braced.repeat.min.value, u64(2))
	testing.expect_value(t, regex_test_child(&ast, braced, 0).code_point, Maybe(u32)('u'))
	lookahead := regex_test_child(&ast, terms, 8)
	testing.expect_value(t, lookahead.kind, kessel.RegexAstKind.Quantifier)
	testing.expect_value(
		t, regex_test_child(&ast, lookahead, 0).group_kind, kessel.RegexGroupKind.Lookahead,
	)
	for expected, index in ([]u32{'{', ']', '}'}) {
		literal := regex_test_child(&ast, terms, 9 + index)
		testing.expect_value(t, literal.kind, kessel.RegexAstKind.Character)
		testing.expect_value(t, literal.code_point, Maybe(u32)(expected))
	}
	testing.expect_value(t, regex_test_count(&ast, terms), 12)

	regex_test_all(t, {
		{`\k<a>`, "u"}, {`\c*`, "u"}, {`\x`, "u"}, {`\u`, "u"}, {`(?=b)+`, "u"}, {`{`, "u"},
		{`]`, "u"}, {`}`, "v"}, {`(?<=b)+`, ""}, {`{1}`, ""}, {`a{1}{2}`, ""}, {`\`, ""},
		{`\1`, "u"}, {`\8`, "u"}, {`\-`, "u"}, {`\a`, "u"}, {`\p`, "u"}, {`\u{110000}`, "u"},
	}, .Invalid_Pattern)
}

@(test)
test_regex_ast_legacy_octal :: proc(t: ^testing.T) {
	// `\400` is `\40` then `0`: an octal escape stops before exceeding 0o377.
	pattern := `\400\08\377\0\9(a)\1\2`
	ast, err := kessel.regex_parse_ast(pattern, "", context.allocator)
	if !testing.expectf(t, err.kind == .None, "%v", err) { return }
	defer kessel.regex_ast_destroy(&ast)
	terms := regex_test_terms(&ast)
	expected := [?]struct{text: string, value: u32}{
		{`\40`, 0o40}, {`0`, '0'}, {`\0`, 0}, {`8`, '8'}, {`\377`, 0o377}, {`\0`, 0}, {`\9`, '9'},
	}
	for item, index in expected {
		node := regex_test_child(&ast, terms, index)
		testing.expect_value(t, regex_test_text(pattern, node.span), item.text)
		testing.expect_value(t, node.code_point, Maybe(u32)(item.value))
	}
	reference := regex_test_child(&ast, terms, 8)
	testing.expect_value(t, reference.kind, kessel.RegexAstKind.Indexed_Reference)
	testing.expect_value(t, reference.capture_index, u32(1))
	// Only one group exists, so `\2` is the octal escape for U+0002.
	octal := regex_test_child(&ast, terms, 9)
	testing.expect_value(t, octal.kind, kessel.RegexAstKind.Escape)
	testing.expect_value(t, octal.code_point, Maybe(u32)(2))
}

@(test)
test_regex_ast_class_atoms :: proc(t: ^testing.T) {
	// In a class `\c` takes a digit or `_` as its letter (Annex B), `\b` is
	// backspace, and a bare `\c` is a backslash followed by `c`.
	pattern := `[\c1\c_\cJ\b\c!\d-a-z\k]`
	ast, err := kessel.regex_parse_ast(pattern, "", context.allocator)
	if !testing.expectf(t, err.kind == .None, "%v", err) { return }
	defer kessel.regex_ast_destroy(&ast)
	class := regex_test_child(&ast, regex_test_terms(&ast), 0)
	expected := [?]struct{text: string, value: Maybe(u32)}{
		{`\c1`, 0x11}, {`\c_`, 0x1f}, {`\cJ`, 0x0a}, {`\b`, 8}, {`\`, '\\'}, {`c`, 'c'},
		{`!`, '!'}, {`\d`, nil},
		// `\d-a` keeps all three as members, and `a` cannot then start `a-z`.
		{`-`, '-'}, {`a`, 'a'}, {`-`, '-'}, {`z`, 'z'}, {`\k`, 'k'},
	}
	for item, index in expected {
		node := regex_test_child(&ast, class, index)
		testing.expect_value(t, regex_test_text(pattern, node.span), item.text)
		testing.expect_value(t, node.code_point, item.value)
		testing.expect(t, node.kind != .Class_Range)
	}
	testing.expect_value(t, regex_test_count(&ast, class), len(expected))

	regex_test_all(t, {{`[--a]`, ""}, {`[a-b-c]`, "u"}, {`[\d-]`, "u"}, {`[\-]`, "u"}}, .None)
	regex_test_all(t, {
		{`[\d-a]`, "u"}, {`[a-\d]`, "u"}, {`[\c1]`, "u"}, {`[\c]`, "u"}, {`[\B]`, "u"},
		{`[\1]`, "u"}, {`[\k]`, "u"}, {`(?<a>.)[\k<a>]`, ""}, {`[a-\c]`, ""}, {`[a--]`, ""},
		{`[\q{a}]`, "u"}, {`[\p{L}-a]`, "u"},
	}, .Invalid_Pattern)
}

@(test)
test_regex_ast_set_notation :: proc(t: ^testing.T) {
	pattern := `[\q{\}|\u{1F600}b|}[]\&]`
	ast, err := kessel.regex_parse_ast(pattern, "v", context.allocator)
	if !testing.expectf(t, err.kind == .None, "%v", err) { return }
	defer kessel.regex_ast_destroy(&ast)
	class := regex_test_child(&ast, regex_test_terms(&ast), 0)
	testing.expect_value(t, class.class_relation, kessel.RegexClassRelation.Union)
	strings := regex_test_child(&ast, class, 0)
	testing.expect_value(t, strings.kind, kessel.RegexAstKind.Class_String)
	testing.expect_value(t, regex_test_count(&ast, strings), 3)
	brace := regex_test_child(&ast, regex_test_child(&ast, strings, 0), 0)
	testing.expect_value(t, brace.code_point, Maybe(u32)('}'))
	emoji := regex_test_child(&ast, regex_test_child(&ast, strings, 1), 0)
	testing.expect_value(t, emoji.code_point, Maybe(u32)(0x1f600))
	testing.expect_value(t, regex_test_count(&ast, regex_test_child(&ast, strings, 2)), 0)
	testing.expect_value(t, strings.may_contain_strings, true)
	empty := regex_test_child(&ast, class, 1)
	testing.expect_value(t, empty.kind, kessel.RegexAstKind.Character_Class)
	testing.expect_value(t, regex_test_text(pattern, empty.span), "[]")
	punctuator := regex_test_child(&ast, class, 2)
	testing.expect_value(t, punctuator.code_point, Maybe(u32)('&'))
	testing.expect_value(t, regex_test_count(&ast, class), 3)

	subtraction := `[\w--[a-c]--\d]`
	removed, removed_err := kessel.regex_parse_ast(subtraction, "v", context.allocator)
	if !testing.expectf(t, removed_err.kind == .None, "%v", removed_err) { return }
	defer kessel.regex_ast_destroy(&removed)
	outer := regex_test_child(&removed, regex_test_terms(&removed), 0)
	testing.expect_value(t, outer.class_relation, kessel.RegexClassRelation.Subtraction)
	operator := regex_test_child(&removed, outer, 1)
	testing.expect_value(t, operator.kind, kessel.RegexAstKind.Class_Subtraction)
	range := regex_test_child(&removed, regex_test_child(&removed, outer, 2), 0)
	testing.expect_value(t, range.kind, kessel.RegexAstKind.Class_Range)
	testing.expect_value(t, regex_test_text(subtraction, range.span), "a-c")

	regex_test_all(t, {
		{`[a&b]`, "v"}, {`[\-a]`, "v"}, {`[[a]&&[^b]&&\p{L}]`, "v"}, {`[^\q{a|b}]`, "v"},
		{`[^\q{ab}&&a]`, "v"}, {`[\p{RGI_Emoji}--\q{ab}]`, "v"},
	}, .None)
	regex_test_all(t, {
		{`[a-b-c]`, "v"}, {`[-a]`, "v"}, {`[a-]`, "v"}, {`[a&&&b]`, "v"}, {`[&&a]`, "v"},
		{`[a--]`, "v"}, {`[a!!b]`, "v"}, {`[(]`, "v"}, {`[a|b]`, "v"}, {`[\d-a]`, "v"},
		{`[a-\d]`, "v"}, {`[\q{(}]`, "v"}, {`[\q{a-b}]`, "v"}, {`[\q{\d}]`, "v"}, {`[\q{a]`, "v"},
		{`[\q]`, "v"}, {`\q{a}`, "v"}, {`[ab&&c]`, "v"}, {`[a&&b-z]`, "v"}, {`[[]`, "v"},
		{`[^\q{}]`, "v"}, {`[^[\q{ab}]]`, "v"}, {`\P{RGI_Emoji}`, "v"},
	}, .Invalid_Pattern)
}

@(test)
test_regex_ast_properties :: proc(t: ^testing.T) {
	pattern := `\p{Lu}\P{Script_Extensions=Grek}[\p{RGI_Emoji}]`
	ast, err := kessel.regex_parse_ast(pattern, "v", context.allocator)
	if !testing.expectf(t, err.kind == .None, "%v", err) { return }
	defer kessel.regex_ast_destroy(&ast)
	terms := regex_test_terms(&ast)
	lone := regex_test_child(&ast, terms, 0)
	testing.expect_value(t, lone.kind, kessel.RegexAstKind.Property_Escape)
	testing.expect_value(t, regex_test_text(pattern, lone.name), "Lu")
	testing.expect_value(t, lone.property_value == nil, true)
	pair := regex_test_child(&ast, terms, 1)
	testing.expect_value(t, pair.negative, true)
	testing.expect_value(t, regex_test_text(pattern, pair.name), "Script_Extensions")
	testing.expect_value(t, regex_test_text(pattern, pair.property_value.?), "Grek")
	class := regex_test_child(&ast, terms, 2)
	testing.expect_value(t, class.may_contain_strings, true)
	testing.expect_value(t, regex_test_child(&ast, class, 0).may_contain_strings, true)

	regex_test_all(t, {
		{`\p{gc=Lu}`, "u"}, {`\p{Any}`, "u"}, {`\p{sc=Sidetic}`, "u"}, {`\p{ASCII_Hex_Digit}`, "v"},
		// Without `u`/`v`, `\p` is the identity escape `p`.
		{`\p{NotAProperty}`, ""}, {`\p`, ""},
	}, .None)
	regex_test_all(t, {
		{`\p{Script=NotAScript}`, "u"}, {`\p{gc=Latin}`, "u"}, {`\p{Latin}`, "u"},
		{`\p{ASCII=Yes}`, "u"}, {`\p{Block=Basic_Latin}`, "u"}, {`\p{lu}`, "u"}, {`\p{L`, "u"},
		{`\p{}`, "u"}, {`\pL`, "u"}, {`\p{RGI_Emoji}`, "u"}, {`\p{Script=}`, "u"},
	}, .Invalid_Pattern)
}
