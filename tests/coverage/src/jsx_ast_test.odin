// JSX AST details that downstream compilers rely on.
//
// Each test parses an inline source the way a library consumer does
// (`parse_job_open_inline` + `parse_job_run`) and asserts on the typed AST
// rather than on emitted JSON, so a regression shows up as the field that
// moved. Covered:
//
//   * a mismatched closing tag is reported on the closing tag's name;
//   * `{...xs}` in child position is a `JSXSpreadChild`;
//   * `{...}` without an operand is an error spanning the `}`;
//   * entity decoding: `JSXText.value` and string attribute values are
//     cooked, `raw` keeps the source text;
//
// tests/verifiers/verify_jsx_ast.js checks the same contract against the
// pinned reference parsers.
package coverage

import "core:testing"

import kessel "../../../src"

// Parse `source` as JSX and return the JSX element of its first statement.
// `job` stays open so the caller can read errors and the arena-backed AST.
@(private = "file")
jsx_open :: proc(t: ^testing.T, job: ^kessel.ParseJob, source: string) -> ^kessel.JSXElement {
	config := kessel.ParseConfig{lang_override = kessel.Lang.JSX}
	if !testing.expect(t, kessel.parse_job_open_inline(job, source, config, "inline.jsx")) {
		return nil
	}
	kessel.parse_job_run(job)
	if job.program == nil || len(job.program.body) == 0 { return nil }
	statement, is_expression := job.program.body[0].(^kessel.ExpressionStatement)
	if !is_expression || statement.expression == nil { return nil }
	element, _ := statement.expression.(^kessel.JSXElement)
	return element
}

@(private = "file")
JSXErrorCase :: struct {
	source: string,
	start:  u32,
	end:    u32,
	code:   kessel.ErrorCode,
}

// Spans are the ones oxc-parser 0.127.0 labels for the same sources.
@(test)
test_jsx_error_spans :: proc(t: ^testing.T) {
	cases := [?]JSXErrorCase{
		// Mismatched closing tag: the closing tag's whole name.
		{"<p></div>;",            5,  8, .K3063_JSXInvalid},
		{"<a.b></a.c>;",          7, 10, .K3063_JSXInvalid},
		{"<a:b></a:c>;",          7, 10, .K3063_JSXInvalid},
		{"<a></b.c>;",            5,  8, .K3063_JSXInvalid},
		{"<a>\n  <b></c>\n</a>;", 11, 12, .K3063_JSXInvalid},
		// `{...}` without an operand: the `}` where an expression was expected.
		{"<a {...}/>;",           7,  8, .K2020_ExpectedExpression},
		{"<a>{...}</a>;",         7,  8, .K2020_ExpectedExpression},
		{"<a>{... }</a>;",        8,  9, .K2020_ExpectedExpression},
	}
	for error_case in cases {
		job: kessel.ParseJob
		jsx_open(t, &job, error_case.source)
		defer kessel.parse_job_close(&job)
		if !testing.expectf(t, len(job.parser.errors) >= 1, "no error for %q", error_case.source) {
			continue
		}
		first := job.parser.errors[0]
		testing.expectf(
			t, first.start == error_case.start && first.end == error_case.end,
			"%q: error spans [%d, %d), want [%d, %d)",
			error_case.source, first.start, first.end, error_case.start, error_case.end,
		)
		testing.expect_value(t, first.code, error_case.code)
	}
}

@(test)
test_jsx_spread_child_node :: proc(t: ^testing.T) {
	source := "<a>{...xs}{ys}{}</a>;"
	job: kessel.ParseJob
	element := jsx_open(t, &job, source)
	defer kessel.parse_job_close(&job)
	if !testing.expect(t, element != nil) { return }
	testing.expect_value(t, len(job.parser.errors), 0)
	if !testing.expect_value(t, len(element.children), 3) { return }

	spread, is_spread := element.children[0].(^kessel.JSXSpreadChild)
	if !testing.expect(t, is_spread, "`{...xs}` must be a JSXSpreadChild") { return }
	// The span covers both braces; the operand is the bare expression.
	testing.expect_value(t, spread.loc, kessel.Loc{start = 3, end = 10})
	operand, is_identifier := spread.expression.(^kessel.Identifier)
	if testing.expect(t, is_identifier, "operand must not be wrapped in a SpreadElement") {
		testing.expect_value(t, operand.name, "xs")
		testing.expect_value(t, operand.loc, kessel.Loc{start = 7, end = 9})
	}

	// Neighbouring containers are unchanged.
	_, is_container := element.children[1].(^kessel.JSXExpressionContainer)
	testing.expect(t, is_container)
	empty, is_empty_container := element.children[2].(^kessel.JSXExpressionContainer)
	if testing.expect(t, is_empty_container) {
		_, is_empty := empty.expression.(^kessel.JSXEmptyExpression)
		testing.expect(t, is_empty)
	}
}

@(private = "file")
JSXEntityCase :: struct {
	raw:   string, // source text, used both as attribute body and as child text
	value: string, // expected cooked value
}

// Decoding follows the transform's decoder (and so `oxc-transform`): what
// does not decode stays literal instead of becoming an error.
@(private = "file")
JSX_ENTITY_CASES := [?]JSXEntityCase{
	{"plain", "plain"},
	{"&amp;", "&"},
	{"&lt;&gt;&quot;&apos;", "<>\"'"},
	{"&nbsp;&copy;&hellip;", "\u00a0\u00a9\u2026"},
	{"&#65;&#x41;&#x1F600;", "AA\U0001F600"},
	{"&amp;lt;", "&lt;"},              // decoded once, never twice
	{"&foo;", "&foo;"},                // unknown name
	{"&AMP;", "&AMP;"},                // names are case-sensitive
	{"&amp x &lt", "&amp x &lt"},      // missing semicolon
	{"&#X41;", "&#X41;"},              // only a lowercase `x` marks hex
	{"&#;&#x;&;", "&#;&#x;&;"},        // no digits, no name
	{"&#1114112;", "&#1114112;"},      // above U+10FFFF (decimal)
	{"&#x110000;", "&#x110000;"},      // above U+10FFFF (hex)
	{"&#12345678901234567890;", "&#12345678901234567890;"},
	{"&#xD800;", "&#xD800;"},          // surrogates are not scalar values
	{"&&amp;;&amp&amp;", "&&;&amp&"},
}

@(test)
test_jsx_entities_decode_into_value :: proc(t: ^testing.T) {
	for entity_case in JSX_ENTITY_CASES {
		source := jsx_concat({"<a b=\"", entity_case.raw, "\">", entity_case.raw, "</a>;"})
		defer delete(source)
		job: kessel.ParseJob
		element := jsx_open(t, &job, source)
		defer kessel.parse_job_close(&job)
		if !testing.expectf(t, element != nil, "no JSX element for %q", source) { continue }
		testing.expect_value(t, len(job.parser.errors), 0)

		if !testing.expect_value(t, len(element.opening_element.attributes), 1) { continue }
		attribute, is_attribute := element.opening_element.attributes[0].(kessel.JSXAttribute)
		if !testing.expect(t, is_attribute) { continue }
		attribute_value, has_value := attribute.value.?
		if !testing.expect(t, has_value) { continue }
		literal, is_string := attribute_value.(^kessel.StringLiteral)
		if !testing.expect(t, is_string) { continue }
		testing.expect_value(t, literal.value, entity_case.value)
		testing.expect_value(t, len(literal.raw), len(entity_case.raw) + 2)
		testing.expect_value(t, literal.raw[1:len(literal.raw) - 1], entity_case.raw)

		if !testing.expect_value(t, len(element.children), 1) { continue }
		text, is_text := element.children[0].(^kessel.JSXText)
		if !testing.expect(t, is_text) { continue }
		testing.expect_value(t, text.value, entity_case.value)
		testing.expect_value(t, text.raw, entity_case.raw)
	}
}

// Text without `&` must not be copied: `value` aliases the source bytes.
@(test)
test_jsx_text_without_entities_is_not_copied :: proc(t: ^testing.T) {
	source := "<a>plain text</a>;"
	job: kessel.ParseJob
	element := jsx_open(t, &job, source)
	defer kessel.parse_job_close(&job)
	if !testing.expect(t, element != nil) { return }
	if !testing.expect_value(t, len(element.children), 1) { return }
	text, is_text := element.children[0].(^kessel.JSXText)
	if !testing.expect(t, is_text) { return }
	testing.expect_value(t, raw_data(text.value), raw_data(text.raw))
	testing.expect_value(t, text.value, "plain text")
}

// A `>` or `}` produced by decoding is not the bare character the grammar
// forbids in text, so it must not raise "Unexpected token".
@(test)
test_jsx_decoded_brackets_are_not_errors :: proc(t: ^testing.T) {
	source := "<a>&gt;&#62;&#125;</a>;"
	job: kessel.ParseJob
	element := jsx_open(t, &job, source)
	defer kessel.parse_job_close(&job)
	if !testing.expect(t, element != nil) { return }
	testing.expect_value(t, len(job.parser.errors), 0)
	if !testing.expect_value(t, len(element.children), 1) { return }
	text, is_text := element.children[0].(^kessel.JSXText)
	if !testing.expect(t, is_text) { return }
	testing.expect_value(t, text.value, ">>}")
}

// A string inside an expression container is a JavaScript string: entities
// are not decoded there.
@(test)
test_jsx_entities_not_decoded_in_expressions :: proc(t: ^testing.T) {
	source := "<a b={\"&amp;\"}>{\"&lt;\"}</a>;"
	job: kessel.ParseJob
	element := jsx_open(t, &job, source)
	defer kessel.parse_job_close(&job)
	if !testing.expect(t, element != nil) { return }
	testing.expect_value(t, len(job.parser.errors), 0)
	if !testing.expect_value(t, len(element.children), 1) { return }
	container, is_container := element.children[0].(^kessel.JSXExpressionContainer)
	if !testing.expect(t, is_container) { return }
	literal, is_string := container.expression.(^kessel.StringLiteral)
	if !testing.expect(t, is_string) { return }
	testing.expect_value(t, literal.value, "&lt;")
}

@(private = "file")
jsx_concat :: proc(parts: []string) -> string {
	total := 0
	for part in parts { total += len(part) }
	buffer := make([]u8, total)
	offset := 0
	for part in parts { offset += copy(buffer[offset:], part) }
	assert(offset == total)
	return string(buffer)
}
