package coverage

import "core:strings"
import "core:testing"

import kessel "../../../src"

// Goal: a regexp literal is accepted by the lexer exactly when V8 compiles it.
//
// The lexer's own validator is a fast approximation, so its answer is checked
// against the regexp tree builder for every literal with `u` or `v` and for
// every legacy literal it complains about or has doubts about (see
// regex_validate_literal in src/regex.odin). This table pins both directions of
// that arrangement: valid literals the validator alone used to reject, invalid
// ones it used to accept, and for each rule the valid neighbours that must keep
// taking the fast path.
//
// Method: each row is parsed as the program `/pattern/flags;`. The expected
// column was produced by Node v26.13.0 (`new RegExp` and the literal agree on
// every row); it is not Kessel's own opinion. 174 rows, 96 of them valid.
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
		// Invalid literals the validator used to accept: the five reported ones.
		{`x{3,2}`, "", false},
		{`[\B]`, "u", false},
		{`\p{Script=NotAScript}`, "u", false},
		{`[a-b-c]`, "v", false},
		{`[\q{(}]`, "v", false},
		// Quantifier bounds out of order, and their valid neighbours.
		{`x{2,1}`, "u", false},
		{`x{2,1}`, "v", false},
		{`x{10,9}`, "", false},
		{`x{010,9}`, "", false},
		{`x{2,3}`, "", true},
		{`x{2,2}`, "", true},
		{`x{02,2}`, "", true},
		{`x{9,010}`, "", true},
		{`x{2,}`, "", true},
		{`x{2}`, "", true},
		{`x{3,2`, "", true},
		{`x{,2}`, "", true},
		{`x{3,2}?`, "", false},
		{`[x{3,2}]`, "", true},
		{`\x{3,2}`, "", false},
		{`\{3,2}`, "", true},
		// A quantifier on a quantifier or on an assertion.
		{`a**`, "", false},
		{`a++`, "", false},
		{`a???`, "", false},
		{`a*?`, "", true},
		{`a+?`, "", true},
		{`a??`, "", true},
		{`a{1,2}?`, "", true},
		{`a{1,2}??`, "", false},
		{`a{1}{2}`, "", false},
		{`a{1}*`, "", false},
		{`a*{1}`, "", false},
		{`a*?+`, "", false},
		{`^*`, "", false},
		{`$+`, "", false},
		{`\b+`, "", false},
		{`\B{1}`, "", false},
		{`\b`, "", true},
		{`^a$`, "", true},
		{`(?=a)*`, "", true},
		{`(?=a)*`, "u", false},
		{`(?!a){2}`, "", true},
		{`(?<=a)*`, "", false},
		{`(?:a*)*`, "", true},
		{`(a*)+`, "", true},
		{`[a*]*`, "", true},
		{`\**`, "", true},
		{`\u{41}+`, "", false},
		{`\u{41}+`, "u", true},
		{`a|*`, "", false},
		{`(*)`, "", false},
		{`a{2}{`, "", true},
		// Class ranges out of order, and ranges this scan cannot decode itself.
		{`[z-a]`, "", false},
		{`[z-a]`, "u", false},
		{`[b-ac-e]`, "", false},
		{`[a-z]`, "", true},
		{`[a-a]`, "", true},
		{`[-a]`, "", true},
		{`[a-]`, "", true},
		{`[^-a]`, "", true},
		{`[a-c-e]`, "", true},
		{`[\x7a-a]`, "", false},
		{`[\x41-Z]`, "", true},
		{`[\u4e00-\u9fa5]`, "", true},
		{`[\u9fa5-\u4e00]`, "", false},
		{`[\d-a]`, "", true},
		{`[a-\d]`, "", true},
		{`[\d-a]`, "u", false},
		{`[\w-\d]`, "", true},
		{`[\b-\n]`, "", true},
		{`[\n-\b]`, "", false},
		{`[\c-a]`, "", false},
		{`[a-\c]`, "", false},
		{`[é-z]`, "", false},
		{`[z-é]`, "", true},
		{`[\u{1d608}-\u{1d621}]`, "", false},
		{`[\u{1d608}-\u{1d621}]`, "u", true},
		{`[\u{1d621}-\u{1d608}]`, "u", false},
		{`[\0-\x1F]`, "", true},
		{`[\x1F-\0]`, "", false},
		{`[\101-A]`, "", true},
		{`[\102-A]`, "", false},
		{`[\cA-\x00]`, "", false},
		{`[\cb-a]`, "", true},
		{`[a-\cA]`, "", false},
		{`[\xA0-\uFFFF]`, "", true},
		{`[\uFFFF-\xA0]`, "", false},
		{`[\uD83D\uDE00-x]`, "", false},
		{`[😀-😃]`, "", false},
		{`[😀-😃]`, "u", true},
		{`[😃-😀]`, "u", false},
		{`[\d-\w]`, "", true},
		{`[\--a]`, "", true},
		{`[a-\-]`, "", false},
		{`[--a]`, "", true},
		{`[a--]`, "", false},
		{`[^a-z]`, "", true},
		{`[^z-a]`, "", false},
		{`[]a-z]`, "", true},
		{`[\]-a]`, "", true},
		{`[a-\]]`, "", false},
		{`[\da-z]`, "", true},
		{`[\dz-a]`, "", false},
		{`[a-z\d-]`, "", true},
		{`[\x4-a]`, "", true},
		{`[\u00-a]`, "", true},
		{`[\8-a]`, "", true},
		{`[\08-a]`, "", true},
		{`[a-\08]`, "", false},
		// Named references.
		{`\k`, "", true},
		{`[\k]`, "", true},
		{`\k<a>`, "", true},
		{`\k<a>`, "u", false},
		{`[\k<a>](?<a>a)`, "", false},
		{`(?<a>a)[\k<a>]`, "", false},
		{`[\k<a>]`, "", true},
		{`(?<a>a)\k<b>`, "", false},
		{`\k<a>(?<a>a)`, "", true},
		{`(?<a>a)|(?<a>b)`, "", true},
		{`(?<a>a)(?<a>b)`, "", false},
		// Unicode properties: names and values come from the builder's tables.
		{`\p{Script=Greek}`, "u", true},
		{`\p{sc=Grek}`, "u", true},
		{`\p{Script=Grek}`, "v", true},
		{`\p{scx=Greek}`, "u", true},
		{`\p{General_Category=Lu}`, "u", true},
		{`\p{gc=NotACategory}`, "u", false},
		{`\p{Lu}`, "u", true},
		{`\p{L}`, "u", true},
		{`\p{Foo}`, "u", false},
		{`\p{Alphabetic}`, "u", true},
		{`\p{Alphabetic=Yes}`, "u", false},
		{`\p{RGI_Emoji}`, "v", true},
		{`\p{RGI_Emoji}`, "u", false},
		{`\P{RGI_Emoji}`, "v", false},
		{`\p{Script=}`, "u", false},
		{`\p{Script}`, "u", false},
		{`\p{Script=NotAScript}`, "", true},
		{`\p`, "", true},
		{`\p`, "u", false},
		// Set notation and strict escapes with the v flag.
		{`[a--b]`, "v", true},
		{`[a&&b]`, "v", true},
		{`[a&&&b]`, "v", false},
		{`[a--b&&c]`, "v", false},
		{`[[a-z]--[aeiou]]`, "v", true},
		{`[\q{ab|c}]`, "v", true},
		{`[\q{ab}]`, "u", false},
		{`[a-b-c]`, "u", true},
		{`[a-b-c]`, "", true},
		{`[(]`, "v", false},
		{`[\(]`, "v", true},
		{`[a|b]`, "v", false},
		{`[\-]`, "v", true},
		{`[^\q{ab}]`, "v", false},
		{`[^\q{a}]`, "v", true},
		{`[&&]`, "v", false},
		{`[a-]`, "v", false},
		{`[\B]`, "", true},
		{`[\B]`, "v", false},
		{`\-`, "u", false},
		{`\a`, "u", false},
		{`\a`, "", true},
	}
	#assert(len(cases) == 174)
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
