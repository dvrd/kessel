// Input and allocation hardening for library consumers that embed kessel
// in-process (src/parse_job.odin, src/parser.odin, src/lexer.odin).
package coverage

import "core:testing"

import kessel "../../../src"

// Parse `source` as a script holding one expression statement whose
// expression is a string literal; return that literal's cooked value as
// bytes. The job is left open (arena-owned bytes) and closed by the caller.
@(private="file")
string_literal_value :: proc(t: ^testing.T, job: ^kessel.ParseJob, source: string) -> []u8 {
	if !testing.expect(t, kessel.parse_job_open_inline(job, source, {}, "string.js")) { return nil }
	kessel.parse_job_run(job)
	if !testing.expectf(t, len(job.parser.errors) == 0, "%q: unexpected parse error", source) { return nil }
	if !testing.expect_value(t, len(job.program.body), 1) { return nil }
	statement, is_expression := job.program.body[0]^.(^kessel.ExpressionStatement)
	if !testing.expect(t, is_expression) { return nil }
	literal, is_string := statement.expression^.(^kessel.StringLiteral)
	if !testing.expect(t, is_string) { return nil }
	return transmute([]u8)literal.value
}

// Pins the documented encoding of `StringLiteral.value` (src/ast.odin):
// UTF-8, except that a lone surrogate written as an escape is kept as its
// 3-byte generalized-UTF-8 form (WTF-8), and an escaped surrogate PAIR is
// combined into the one 4-byte sequence of the code point it denotes.
@(test)
test_string_value_lone_surrogates_are_wtf8 :: proc(t: ^testing.T) {
	Case :: struct { source: string, value: []u8 }
	cases := [?]Case{
		// Lone high / low surrogate, both escape spellings.
		{`("\uD800");`,        {0xED, 0xA0, 0x80}},
		{`("\uDBFF");`,        {0xED, 0xAF, 0xBF}},
		{`("\uDC00");`,        {0xED, 0xB0, 0x80}},
		{`("\uDFFF");`,        {0xED, 0xBF, 0xBF}},
		{`("\u{D800}");`,      {0xED, 0xA0, 0x80}},
		{`('a\uD83Db');`,      {'a', 0xED, 0xA0, 0xBD, 'b'}},
		// Low then high: not a pair, two lone surrogates.
		{`("\uDE00\uD83D");`,  {0xED, 0xB8, 0x80, 0xED, 0xA0, 0xBD}},
		// High + low pair: one supplementary code point (U+1F600), true UTF-8.
		{`("😀");`,  {0xF0, 0x9F, 0x98, 0x80}},
		// Neighbours of the surrogate range are ordinary 3-byte UTF-8.
		{`("퟿");`,  {0xED, 0x9F, 0xBF, 0xEE, 0x80, 0x80}},
	}
	for c in cases {
		job: kessel.ParseJob
		value := string_literal_value(t, &job, c.source)
		testing.expectf(t, string(value) == string(c.value),
			"%s: value bytes % x, expected % x", c.source, value, c.value)
		kessel.parse_job_close(&job)
	}
}

// Template literals cook escapes through a separate routine
// (process_template_escapes); pin that it encodes lone surrogates the same
// way. Escaped surrogate PAIRS are deliberately absent: unlike string
// literals, that routine does not yet combine them (each half comes out as
// its own 3-byte sequence), which TemplateElement.cooked documents as a
// known inconsistency rather than a contract.
@(test)
test_template_cooked_lone_surrogates_are_wtf8 :: proc(t: ^testing.T) {
	Case :: struct { source: string, cooked: []u8 }
	cases := [?]Case{
		{"(`\\uD800`);",        {0xED, 0xA0, 0x80}},
		{"(`\\u{DFFF}`);",      {0xED, 0xBF, 0xBF}},
		{"(`a\\uDBFFb`);",     {'a', 0xED, 0xAF, 0xBF, 'b'}},
	}
	for c in cases {
		job: kessel.ParseJob
		if !testing.expect(t, kessel.parse_job_open_inline(&job, c.source, {}, "template.js")) { continue }
		defer kessel.parse_job_close(&job)
		kessel.parse_job_run(&job)
		if !testing.expectf(t, len(job.parser.errors) == 0, "%q: unexpected parse error", c.source) { continue }
		statement := job.program.body[0]^.(^kessel.ExpressionStatement)
		template, is_template := statement.expression^.(^kessel.TemplateLiteral)
		if !testing.expect(t, is_template) { continue }
		if !testing.expect_value(t, len(template.quasis), 1) { continue }
		cooked, has_cooked := template.quasis[0].cooked.?
		testing.expect(t, has_cooked)
		testing.expectf(t, cooked == string(c.cooked),
			"%s: cooked bytes % x, expected % x", c.source, transmute([]u8)cooked, c.cooked)
	}
}
