// Input and allocation hardening for library consumers that embed kessel
// in-process (src/parse_job.odin, src/parser.odin, src/lexer.odin).
package coverage

import "core:strings"
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

// ----------------------------------------------------------------------------
// ParseConfig.reject_invalid_utf8
// ----------------------------------------------------------------------------
//
// Goal: with the option on, ill-formed UTF-8 anywhere in the source yields
// exactly one K1017 diagnostic spanning the first ill-formed sequence and an
// empty program; well-formed source parses exactly as without the option.
// With the option off (the default) nothing changes.
//
// Method: a table of byte sequences drawn from Unicode Table 3-7, each
// embedded at the start, at the end, inside a string and inside a comment.

@(private="file")
Utf8Case :: struct {
	name:       string,
	bytes:      []u8,
	bad_length: int, // 0 = well formed; else length of the reported span
}

@(private="file")
UTF8_CASES := [?]Utf8Case{
	// Well-formed boundaries of each sequence length.
	{"U+0080 (first 2-byte)",        {0xC2, 0x80}, 0},
	{"U+07FF (last 2-byte)",         {0xDF, 0xBF}, 0},
	{"U+0800 (first 3-byte)",        {0xE0, 0xA0, 0x80}, 0},
	{"U+D7FF (below surrogates)",    {0xED, 0x9F, 0xBF}, 0},
	{"U+E000 (above surrogates)",    {0xEE, 0x80, 0x80}, 0},
	{"U+FFFF (last 3-byte)",         {0xEF, 0xBF, 0xBF}, 0},
	{"U+10000 (first 4-byte)",       {0xF0, 0x90, 0x80, 0x80}, 0},
	{"U+10FFFF (last code point)",   {0xF4, 0x8F, 0xBF, 0xBF}, 0},
	// Overlong encodings.
	{"overlong NUL, 2 bytes",        {0xC0, 0x80}, 1},
	{"overlong '/', 2 bytes",        {0xC0, 0xAF}, 1},
	{"overlong U+007F, 2 bytes",     {0xC1, 0xBF}, 1},
	{"overlong U+07FF, 3 bytes",     {0xE0, 0x9F, 0xBF}, 1},
	{"overlong U+FFFF, 4 bytes",     {0xF0, 0x8F, 0xBF, 0xBF}, 1},
	// Truncated sequences (cut short by an ASCII byte or end of input).
	{"2-byte lead alone",            {0xC2}, 1},
	{"3-byte lead + 1",              {0xE2, 0x82}, 2},
	{"3-byte lead alone",            {0xE2}, 1},
	{"4-byte lead + 2",              {0xF0, 0x9F, 0x98}, 3},
	{"4-byte lead + 1",              {0xF0, 0x9F}, 2},
	{"4-byte lead alone",            {0xF0}, 1},
	// Lone continuation bytes.
	{"continuation 0x80",            {0x80}, 1},
	{"continuation 0xBF",            {0xBF}, 1},
	{"two continuations",            {0x80, 0x80}, 1},
	// Surrogates encoded in UTF-8 (CESU-8 / WTF-8 input).
	{"U+D800 encoded",               {0xED, 0xA0, 0x80}, 1},
	{"U+DBFF encoded",               {0xED, 0xAF, 0xBF}, 1},
	{"U+DC00 encoded",               {0xED, 0xB0, 0x80}, 1},
	{"U+DFFF encoded",               {0xED, 0xBF, 0xBF}, 1},
	{"encoded surrogate pair",       {0xED, 0xA0, 0xBD, 0xED, 0xB8, 0x80}, 1},
	// Bytes that never appear in UTF-8, and code points past U+10FFFF.
	{"U+110000",                     {0xF4, 0x90, 0x80, 0x80}, 1},
	{"byte 0xF5",                    {0xF5, 0x80, 0x80, 0x80}, 1},
	{"byte 0xF8",                    {0xF8}, 1},
	{"byte 0xFE",                    {0xFE}, 1},
	{"byte 0xFF",                    {0xFF}, 1},
}

// Where a case's bytes are embedded. `prefix + bytes + suffix` is the
// source; every prefix ends, and every suffix starts, with an ASCII byte
// so a truncated sequence is followed by a non-continuation or by EOF.
@(private="file")
Utf8Placement :: struct { name, prefix, suffix: string }

@(private="file")
UTF8_PLACEMENTS := [?]Utf8Placement{
	{"at start (line comment)", "//", "\nvar a = 1;\n"},
	{"at end (line comment)",   "var a = 1;\n// tail ", ""},
	{"inside a string",         "var a = 1; var s = \"x", "y\"; var b = 2;\n"},
	{"inside a block comment",  "var a = 1; /* x", "y */ var b = 2;\n"},
	// Exactly 16 and 17 ASCII bytes before: both sides of a SIMD block edge.
	{"after 16 ASCII bytes",    "var a = 1; // 16", "\n"},
	{"after 17 ASCII bytes",    "var a = 12; // 17", "\n"},
}

@(private="file")
utf8_source :: proc(placement: Utf8Placement, bytes: []u8) -> string {
	parts := [?]string{placement.prefix, string(bytes), placement.suffix}
	return strings.concatenate(parts[:], context.temp_allocator)
}

@(test)
test_reject_invalid_utf8_validator :: proc(t: ^testing.T) {
	// Every byte 0xF5..0xFF is ill-formed on its own, wherever it appears.
	for value in 0xF5..=0xFF {
		source := [?]u8{'a', u8(value), 'b'}
		start, length := kessel.utf8_first_ill_formed(source[:])
		testing.expectf(t, start == 1 && length == 1, "byte %x: start %d length %d", value, start, length)
	}
	// Every lone continuation byte, likewise.
	for value in 0x80..=0xBF {
		source := [?]u8{u8(value)}
		start, length := kessel.utf8_first_ill_formed(source[:])
		testing.expectf(t, start == 0 && length == 1, "byte %x: start %d length %d", value, start, length)
	}
	// Empty and pure-ASCII inputs of every length around the SIMD width.
	ascii: [40]u8
	for &b in ascii { b = 'a' }
	for size in 0..=len(ascii) {
		start, length := kessel.utf8_first_ill_formed(ascii[:size])
		testing.expectf(t, start == size && length == 0, "ascii %d: start %d length %d", size, start, length)
	}
	for c in UTF8_CASES {
		for placement in UTF8_PLACEMENTS {
			source := utf8_source(placement, c.bytes)
			start, length := kessel.utf8_first_ill_formed(transmute([]u8)source)
			if c.bad_length == 0 {
				testing.expectf(t, length == 0 && start == len(source),
					"%s %s: reported ill-formed at %d", c.name, placement.name, start)
			} else {
				testing.expectf(t, start == len(placement.prefix) && length == c.bad_length,
					"%s %s: start %d length %d, expected %d length %d",
					c.name, placement.name, start, length, len(placement.prefix), c.bad_length)
			}
		}
	}
}

@(test)
test_reject_invalid_utf8_option :: proc(t: ^testing.T) {
	for c in UTF8_CASES {
		for placement in UTF8_PLACEMENTS {
			source := utf8_source(placement, c.bytes)

			strict: kessel.ParseJob
			if !testing.expect(t, kessel.parse_job_open_inline(&strict, source, {reject_invalid_utf8 = true}, "utf8.js")) { continue }
			kessel.parse_job_run(&strict)
			if c.bad_length == 0 {
				testing.expectf(t, len(strict.parser.errors) == 0,
					"%s %s: well-formed source rejected", c.name, placement.name)
				testing.expectf(t, len(strict.program.body) > 0, "%s %s: empty program", c.name, placement.name)
			} else if testing.expectf(t, len(strict.parser.errors) == 1,
					"%s %s: %d errors", c.name, placement.name, len(strict.parser.errors)) {
				error := strict.parser.errors[0]
				bad_start := u32(len(placement.prefix))
				testing.expect_value(t, error.code, kessel.ErrorCode.K1017_InvalidUtf8)
				testing.expectf(t, error.start == bad_start && error.end == bad_start + u32(c.bad_length),
					"%s %s: span [%d, %d), expected [%d, %d)", c.name, placement.name,
					error.start, error.end, bad_start, bad_start + u32(c.bad_length))
				testing.expect_value(t, len(strict.program.body), 0)
				testing.expect_value(t, len(strict.lexer.comments), 0)
			}
			kessel.parse_job_close(&strict)

			// Default: the option is off and K1017 is never reported.
			lenient: kessel.ParseJob
			if !testing.expect(t, kessel.parse_job_open_inline(&lenient, source, {}, "utf8.js")) { continue }
			kessel.parse_job_run(&lenient)
			for error in lenient.parser.errors {
				testing.expectf(t, error.code != .K1017_InvalidUtf8, "%s %s: K1017 with the option off", c.name, placement.name)
			}
			kessel.parse_job_close(&lenient)
		}
	}
}

// A source whose very first bytes are refused must not leak diagnostics or
// comments gathered while the lexer primed its first token over those bytes.
@(test)
test_reject_invalid_utf8_at_offset_zero :: proc(t: ^testing.T) {
	sources := [?]string{"\xff", "\xffvar a = 1;", "\x80/* unterminated", "\xc0\x80\"unterminated"}
	for source in sources {
		job: kessel.ParseJob
		if !testing.expect(t, kessel.parse_job_open_inline(&job, source, {reject_invalid_utf8 = true}, "utf8.js")) { continue }
		defer kessel.parse_job_close(&job)
		kessel.parse_job_run(&job)
		if !testing.expect_value(t, len(job.parser.errors), 1) { continue }
		testing.expect_value(t, job.parser.errors[0].code, kessel.ErrorCode.K1017_InvalidUtf8)
		testing.expect_value(t, job.parser.errors[0].start, u32(0))
		testing.expect_value(t, job.parser.errors[0].end, u32(1))
	}
}
