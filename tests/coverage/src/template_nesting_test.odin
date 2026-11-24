// Template-literal interpolation tracking (src/lexer.odin, "Template
// interpolation state").
//
// Goal: any nesting depth up to TEMPLATE_DEPTH_MAX and any number of open
// braces inside an interpolation lex correctly; one level past the cap is
// refused with K1016 instead of being mis-lexed.
//
// Method: generate the sources (they are too large and too regular to keep
// as fixtures), then check them at two levels:
//
//   * Lexer only — walk the token stream and count template pieces. This
//     pins the lexer's behaviour without depending on how deep the
//     recursive-descent parser can go, so it covers the cap boundary and
//     1000 open braces.
//   * Whole parse — the depths the parser is expected to handle.
//
// The accept/reject decisions are cross-checked against a JavaScript engine
// by tests/verifiers/verify_template_nesting.js.
package coverage

import "core:strings"
import "core:testing"

import kessel "../../../src"

// `depth` template literals, each inside the interpolation of the previous.
@(private="file")
template_nested_source :: proc(depth: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "var x = ")
	for _ in 0..<depth { strings.write_string(&b, "`a${") }
	strings.write_string(&b, "0")
	for _ in 0..<depth { strings.write_string(&b, "}b`") }
	strings.write_string(&b, ";\n")
	return strings.to_string(b)
}

// One interpolation with `count` object-literal braces open at once.
@(private="file")
template_braces_source :: proc(count: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "var x = `a${")
	for _ in 0..<count { strings.write_string(&b, "{a:") }
	strings.write_string(&b, "1")
	for _ in 0..<count { strings.write_string(&b, "}") }
	strings.write_string(&b, "}b`;\n")
	return strings.to_string(b)
}

@(private="file")
TemplateTokenCounts :: struct {
	heads:    int, // TemplateHead: "`a${"
	tails:    int, // TemplateTail: "}b`"
	l_braces: int,
	r_braces: int,
	invalid:  int,
	errors:   int,
	code:     kessel.ErrorCode, // code of the first lexer error, if any
	span:     [2]u32,           // [start, end) of the first lexer error
}

// Tokenise `source` to EOF and count what the template machinery produced.
// Also asserts the lexer ends with no interpolation still open.
@(private="file")
template_lex_counts :: proc(t: ^testing.T, source: string) -> TemplateTokenCounts {
	lexer: kessel.Lexer
	kessel.init_lexer(&lexer, source, context.temp_allocator, .Script)
	counts: TemplateTokenCounts
	// Every token consumes at least one byte, so len + 1 bounds the walk.
	for _ in 0..=len(source) {
		token := kessel.lex_token(&lexer)
		#partial switch token.kind {
		case .TemplateHead: counts.heads += 1
		case .TemplateTail: counts.tails += 1
		case .LBrace:       counts.l_braces += 1
		case .RBrace:       counts.r_braces += 1
		case .Invalid:      counts.invalid += 1
		}
		if token.kind == .EOF { break }
	}
	counts.errors = len(lexer.lexer_errors)
	if counts.errors > 0 {
		first := lexer.lexer_errors[0]
		counts.code = first.code
		counts.span = {first.offset, first.offset + first.length}
	} else {
		testing.expect_value(t, lexer.template_depth, u16(0))
		testing.expect_value(t, lexer.template_brace_depth, u32(0))
		testing.expect(t, lexer.template_outer == nil)
	}
	return counts
}

// The first diagnostic of a parse, reduced to plain values: the job, and
// with it the diagnostic's message, is gone by the time the caller looks.
@(private="file")
TemplateFirstError :: struct {
	code: kessel.ErrorCode,
	span: [2]u32,
}

@(private="file")
template_parse_error_count :: proc(t: ^testing.T, source: string) -> (count: int, first: TemplateFirstError) {
	job: kessel.ParseJob
	if !testing.expect(t, kessel.parse_job_open_inline(&job, source, {}, "template.js")) { return -1, {} }
	defer kessel.parse_job_close(&job)
	kessel.parse_job_run(&job)
	count = len(job.parser.errors)
	if count > 0 {
		first.code = job.parser.errors[0].code
		first.span = {job.parser.errors[0].start, job.parser.errors[0].end}
	}
	return
}

// Depths 8 (old limit), 9 (first depth the old `[8]u8` lost track of), 64,
// and the cap itself all lex to exactly `depth` heads and `depth` tails.
@(test)
test_template_nesting_depths :: proc(t: ^testing.T) {
	#assert(kessel.TEMPLATE_DEPTH_MAX == 256)
	depths := [?]int{1, 2, 8, 9, 30, 64, kessel.TEMPLATE_DEPTH_MAX - 1, kessel.TEMPLATE_DEPTH_MAX}
	for depth in depths {
		source := template_nested_source(depth)
		counts := template_lex_counts(t, source)
		testing.expectf(t, counts.errors == 0, "depth %d: %d lexer errors", depth, counts.errors)
		testing.expectf(t, counts.invalid == 0, "depth %d: Invalid token", depth)
		testing.expectf(t, counts.heads == depth, "depth %d: %d heads", depth, counts.heads)
		testing.expectf(t, counts.tails == depth, "depth %d: %d tails", depth, counts.tails)
		testing.expectf(t, counts.r_braces == 0, "depth %d: stray `}` tokens", depth)

		errors, first := template_parse_error_count(t, source)
		testing.expectf(t, errors == 0, "depth %d: parse errors, first: %v", depth, first)
	}
}

// One level past the cap: a single K1016 spanning the offending `${`, and
// no cascade of follow-on syntax errors from the halted lexer.
@(test)
test_template_nesting_over_cap :: proc(t: ^testing.T) {
	depths := [?]int{kessel.TEMPLATE_DEPTH_MAX + 1, kessel.TEMPLATE_DEPTH_MAX + 2, 2000}
	for depth in depths {
		source := template_nested_source(depth)
		// "var x = " is 8 bytes and each level opens with the 4 bytes "`a${",
		// so the `${` that opens level 257 sits at 8 + 256 * 4 + 2.
		dollar := u32(8 + kessel.TEMPLATE_DEPTH_MAX * 4 + 2)
		testing.expect_value(t, source[dollar:dollar + 2], "${")

		counts := template_lex_counts(t, source)
		testing.expectf(t, counts.errors == 1, "depth %d: %d lexer errors", depth, counts.errors)
		testing.expect_value(t, counts.code, kessel.ErrorCode.K1016_TemplateNestingTooDeep)
		testing.expect_value(t, counts.span, [2]u32{dollar, dollar + 2})
		testing.expect_value(t, counts.heads, kessel.TEMPLATE_DEPTH_MAX)

		errors, first := template_parse_error_count(t, source)
		testing.expectf(t, errors == 1, "depth %d: %d parse errors", depth, errors)
		testing.expect_value(t, first.code, kessel.ErrorCode.K1016_TemplateNestingTooDeep)
		testing.expect_value(t, first.span, [2]u32{dollar, dollar + 2})
	}
}

// 255 was the old u8 maximum, 256 wrapped it to zero, 1000 is far past it.
// The closing `}` of the interpolation must be the only one read as a
// template tail.
@(test)
test_template_open_brace_counts :: proc(t: ^testing.T) {
	brace_counts := [?]int{0, 1, 254, 255, 256, 257, 1000, 70000}
	for count in brace_counts {
		source := template_braces_source(count)
		counts := template_lex_counts(t, source)
		testing.expectf(t, counts.errors == 0, "%d braces: %d lexer errors", count, counts.errors)
		testing.expectf(t, counts.invalid == 0, "%d braces: Invalid token", count)
		testing.expectf(t, counts.heads == 1, "%d braces: %d heads", count, counts.heads)
		testing.expectf(t, counts.tails == 1, "%d braces: %d tails", count, counts.tails)
		testing.expectf(t, counts.l_braces == count, "%d braces: %d `{`", count, counts.l_braces)
		testing.expectf(t, counts.r_braces == count, "%d braces: %d `}`", count, counts.r_braces)
	}

	// Whole parse for the counts around the old wrap point. 1000 nested
	// object literals are parsed by the engine-comparison verifier instead:
	// that much recursion is a parser stack question, not a lexer one.
	parsed_counts := [?]int{255, 256, 257}
	for count in parsed_counts {
		errors, first := template_parse_error_count(t, template_braces_source(count))
		testing.expectf(t, errors == 0, "%d braces: parse errors, first: %v", count, first)
	}
}

// Braces are counted per interpolation: closing an inner template must
// bring back the enclosing interpolation's count, at depths past the old
// array, so the outer `}` characters are still read as plain braces.
@(test)
test_template_brace_counts_per_level :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	levels :: 20
	strings.write_string(&b, "var x = ")
	for level in 0..<levels {
		strings.write_string(&b, "`a${")
		for _ in 0..=level { strings.write_string(&b, "{k:") } // level + 1 braces stay open
	}
	strings.write_string(&b, "0")
	for level := levels - 1; level >= 0; level -= 1 {
		for _ in 0..=level { strings.write_string(&b, "}") }
		strings.write_string(&b, "}b`")
	}
	strings.write_string(&b, ";\n")
	source := strings.to_string(b)

	braces_expected := levels * (levels + 1) / 2
	counts := template_lex_counts(t, source)
	testing.expect_value(t, counts.errors, 0)
	testing.expect_value(t, counts.heads, levels)
	testing.expect_value(t, counts.tails, levels)
	testing.expect_value(t, counts.l_braces, braces_expected)
	testing.expect_value(t, counts.r_braces, braces_expected)

	errors, first := template_parse_error_count(t, source)
	testing.expectf(t, errors == 0, "parse errors, first: %v", first)
}

// lexer_snapshot / lexer_restore must capture the complete interpolation
// state. Take a snapshot at depth 12 with braces open, lex on until every
// level has been left and other levels entered, restore, and require the
// replayed token stream to match the first pass token for token.
@(test)
test_template_state_survives_lexer_restore :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	depth :: 12
	strings.write_string(&b, "var x = ")
	for _ in 0..<depth { strings.write_string(&b, "`a${ {k: ") }
	strings.write_string(&b, "0")
	for _ in 0..<depth { strings.write_string(&b, " } }b`") }
	strings.write_string(&b, " + `c${ `d${ {e: 1} }` }`;\n")
	source := strings.to_string(b)

	job: kessel.ParseJob
	if !testing.expect(t, kessel.parse_job_open_inline(&job, source, {}, "restore.js")) { return }
	defer kessel.parse_job_close(&job)
	kessel.init_lexer(&job.lexer, source, job.arena_alloc, .Script)
	kessel.init_parser(&job.parser, &job.lexer, job.arena_alloc, .JS, false)
	p := &job.parser

	// Advance to the innermost `0`: all 12 interpolations are open.
	for _ in 0..<len(source) {
		if p.lexer.cur.kind == .Number { break }
		kessel.advance_token(p)
	}
	testing.expect_value(t, p.lexer.cur.kind, kessel.TokenType.Number)
	testing.expect_value(t, p.lexer.template_depth, u16(depth))
	testing.expect_value(t, p.lexer.template_brace_depth, u32(1))

	snapshot := kessel.lexer_snapshot(p)
	first_pass := make([dynamic]kessel.FastToken, context.temp_allocator)
	for _ in 0..<len(source) {
		kessel.advance_token(p)
		append(&first_pass, p.lexer.cur)
		if p.lexer.cur.kind == .EOF { break }
	}
	testing.expect_value(t, p.lexer.template_depth, u16(0))

	kessel.lexer_restore(p, snapshot)
	testing.expect_value(t, p.lexer.template_depth, u16(depth))
	testing.expect_value(t, p.lexer.template_brace_depth, u32(1))
	for expected, index in first_pass {
		kessel.advance_token(p)
		if p.lexer.cur != expected {
			testing.expectf(t, false, "token %d differs after restore: %v vs %v", index, p.lexer.cur, expected)
			return
		}
	}
	testing.expect_value(t, p.lexer.cur.kind, kessel.TokenType.EOF)
	testing.expect_value(t, len(p.lexer.lexer_errors), 0)
}
