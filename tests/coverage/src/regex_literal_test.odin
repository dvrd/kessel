package coverage

import "core:strings"
import "core:testing"

import kessel "../../../src"

// Goal: a regexp literal is accepted by the lexer exactly when V8 compiles it.
//
// The lexer's own validator is a fast approximation, so a complaint from it is
// checked against the regexp tree builder before it is reported (see
// regex_validate_literal in src/regex.odin). This table pins valid literals
// the validator alone used to reject.
//
// Method: each row is parsed as the program `/pattern/flags;`. The expected
// column was produced by Node v26.13.0 (`new RegExp` and the literal agree on
// every row); it is not Kessel's own opinion. 13 rows, 13 of them valid.
@(test)
test_regex_literal_verdicts :: proc(t: ^testing.T) {
	Case :: struct { pattern, flags: string, valid: bool }
	cases := [?]Case{
		// Valid literals the validator used to reject.
		{`[\&]`, "v", true},
		{`[a&&\&]`, "v", true},
		{`[[]]`, "v", true},
		{`[\q{\}}]`, "v", true},
		{`[\q{\u{1F600}}]`, "v", true},
		{`[\!\#\%\,\:\;\<\=\>\@\~]`, "v", true},
		{`[^\p{L}\q{a}]`, "v", true},
		{`(?<a>a)\k<a>`, "", true},
		{`(?<\u0061>a)\k<a>`, "", true},
		{`(?<\u{61}>a)\k<a>`, "", true},
		{`(?<a>a)\k<\u0061>`, "u", true},
		{`\n(?<=){,2}`, "", true},
		{`(?<=a){,2}`, "", true},
	}
	#assert(len(cases) == 13)
	for c in cases {
		source := strings.concatenate({"/", c.pattern, "/", c.flags, ";"}, context.temp_allocator)
		job: kessel.ParseJob
		if !testing.expect(t, kessel.parse_job_open_inline(&job, source, {}, "regexp.js")) { continue }
		defer kessel.parse_job_close(&job)
		kessel.parse_job_run(&job)
		rejected := len(job.lexer.lexer_errors) + len(job.parser.errors) > 0
		message := "" if !rejected else
		           job.lexer.lexer_errors[0].message if len(job.lexer.lexer_errors) > 0 else
		           job.parser.errors[0].message
		testing.expectf(t, rejected != c.valid,
			"%s: expected %s, got %s %s", source,
			"valid" if c.valid else "a syntax error",
			"a syntax error:" if rejected else "no error", message)
	}
}
