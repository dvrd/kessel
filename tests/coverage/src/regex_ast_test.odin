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
