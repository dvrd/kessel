// Input and allocation hardening for library consumers that embed kessel
// in-process (src/parse_job.odin, src/parser.odin, src/lexer.odin).
package coverage

import "core:fmt"
import "core:log"
import "core:mem"
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
		{`("\uD83D\uDE00");`,  {0xF0, 0x9F, 0x98, 0x80}},
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
// way. Escaped surrogate pairs are pinned for both kinds of literal by
// test_cooked_surrogate_pairs_are_joined below.
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

// Goal: an escaped high + low surrogate pair cooks to the one 4-byte sequence
// of its supplementary code point, in template literals exactly as in string
// literals, and whichever `\u` spelling each half uses. Templates used to
// leave the pair as two 3-byte sequences, which is neither UTF-8 nor WTF-8.
//
// Method: each body is parsed twice, once between double quotes and once
// between backticks, and both cooked values must equal the expected bytes.
// The table walks the boundary in both directions: pairs that must join,
// and neighbours that must not (a reversed pair, a pair split by another
// character, two highs, a high next to a non-surrogate).
@(test)
test_cooked_surrogate_pairs_are_joined :: proc(t: ^testing.T) {
	Case :: struct { body: string, cooked: []u8 }
	grin := []u8{0xF0, 0x9F, 0x98, 0x80} // U+1F600
	cases := [?]Case{
		{`\uD83D\uDE00`,           grin},
		{`\u{D83D}\u{DE00}`,       grin},
		{`\uD83D\u{DE00}`,         grin},
		{`\u{D83D}\uDE00`,         grin},
		{`\u{1F600}`,              grin},
		{`a\uD83D\uDE00b`,         {'a', 0xF0, 0x9F, 0x98, 0x80, 'b'}},
		// First and last code points reachable through a pair.
		{`\uD800\uDC00`,           {0xF0, 0x90, 0x80, 0x80}},
		{`\uDBFF\uDFFF`,           {0xF4, 0x8F, 0xBF, 0xBF}},
		// Two pairs back to back, and a pair after a lone high surrogate.
		{`\uD83D\uDE00\uD83D\uDE00`, {0xF0, 0x9F, 0x98, 0x80, 0xF0, 0x9F, 0x98, 0x80}},
		{`\uD83D\uD83D\uDE00`,     {0xED, 0xA0, 0xBD, 0xF0, 0x9F, 0x98, 0x80}},
		// The halves are adjacent code units even across a line continuation.
		{"\\uD83D\\\n\\uDE00",        grin},
		// Not pairs: reversed, separated, low + low, high + ordinary.
		{`\uDE00\uD83D`,           {0xED, 0xB8, 0x80, 0xED, 0xA0, 0xBD}},
		{`\uD83Dx\uDE00`,          {0xED, 0xA0, 0xBD, 'x', 0xED, 0xB8, 0x80}},
		{`\uDE00\uDE00`,           {0xED, 0xB8, 0x80, 0xED, 0xB8, 0x80}},
		{`\uD83D\uD7FF`,           {0xED, 0xA0, 0xBD, 0xED, 0x9F, 0xBF}},
		{`\uD83D\uE000`,           {0xED, 0xA0, 0xBD, 0xEE, 0x80, 0x80}},
	}
	for c in cases {
		string_source := strings.concatenate({`("`, c.body, `");`}, context.temp_allocator)
		string_job: kessel.ParseJob
		value := string_literal_value(t, &string_job, string_source)
		testing.expectf(t, string(value) == string(c.cooked),
			"%s: value bytes % x, expected % x", string_source, value, c.cooked)
		kessel.parse_job_close(&string_job)

		template_source := strings.concatenate({"(`", c.body, "`);"}, context.temp_allocator)
		job: kessel.ParseJob
		if !testing.expect(t, kessel.parse_job_open_inline(&job, template_source, {}, "pair.js")) {
			continue
		}
		defer kessel.parse_job_close(&job)
		kessel.parse_job_run(&job)
		if !testing.expectf(t, len(job.parser.errors) == 0, "%q: parse error", template_source) {
			continue
		}
		statement := job.program.body[0]^.(^kessel.ExpressionStatement)
		template, is_template := statement.expression^.(^kessel.TemplateLiteral)
		if !testing.expect(t, is_template) { continue }
		if !testing.expect_value(t, len(template.quasis), 1) { continue }
		cooked, has_cooked := template.quasis[0].cooked.?
		testing.expect(t, has_cooked)
		testing.expectf(t, cooked == string(c.cooked),
			"%s: cooked bytes % x, expected % x", template_source, transmute([]u8)cooked, c.cooked)
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

// ----------------------------------------------------------------------------
// Allocation failure and caller-supplied allocators
// ----------------------------------------------------------------------------

// Sources chosen to reach many allocation sites: every statement kind,
// templates and regexes (cooked strings), classes, destructuring (pattern
// conversion), JSX, TypeScript declarations, deep nesting (many frames on
// the stack when memory runs out) and syntax errors (formatted messages).
@(private="file")
HardeningSample :: struct { label, source: string }

@(private="file")
HARDENING_SAMPLES := [?]HardeningSample{
	{"mix.js", `
		"use strict";
		import def, { a as b, c } from "mod";
		export const answer = 42, { x, y: [z = 1, ...rest] } = obj;
		async function* gen(p = 1, { q, ...r }, [s, t]) {
			for await (const item of source()) { yield* item?.list ?? []; }
			label: for (let i = 0, n = 10; i < n; i++) { if (i % 2) continue label; else break; }
			try { await f(` + "`a${b}c${`d${e}`}`" + `); } catch ({ message }) { throw new Error(message); } finally { done(); }
			switch (p) { case 1: case 2: return /re[/]gex/giu.test("s\n\u{1F600}"); default: debugger; }
		}
		class A extends B { static #p = 1; #m() { return super.m(this.#m, new.target); } get g() { return 1 } set g(v) {} static { init(); } }
		const fn = (a, b = a, ...c) => ({ a, b, [c]: c, 'k': 1n, 2: 0x10, m() {}, get n() { return 1 }, ...a });
		do { x = y ? z : w, a ||= b, c ??= d, e **= 2; } while (!done && typeof x !== "undefined" || x instanceof A);
		var o = a?.b?.[c]?.(d), t = tag` + "`x${1}y`" + `, u = void 0, v = delete o.p, w = -+~!x;
		with_label: { break with_label; }
	`},
	{"deep.js", `var d = [[[[[[[[[[[[[[[[[[[[{a:{b:{c:{d:(((((((((((1+(2*(3-(4/(5%(6**7))))))))))))))))}}}}]]]]]]]]]]]]]]]]]]]];
		function f(){return function(){return function(){return function(){return () => () => () => { if (a) { if (b) { if (c) { while (d) { for (;;) { try { x; } catch { y; } } } } } } }}}}}`},
	{"types.ts", `
		import type { T } from "t";
		export interface I<A extends object = {}> extends J<A>, K { readonly a?: A; [key: string]: unknown; m<B>(this: I, b: B): asserts b is B; new (x: number): I; }
		type U = { [P in keyof T as ` + "`get${Capitalize<P & string>}`" + `]-?: T[P] extends infer R ? R[] : never } | [a: string, b?: number, ...rest: boolean[]];
		declare namespace N.M { export function f(x: number): void; export const enum E { A = 1 << 2, B = A | 1, C = "c".length } }
		abstract class C<T> implements I<T> { private constructor(public readonly x: T, protected y?: number) { super(); } abstract m(): void; declare z: string; static s = <T,>(v: T) => v as unknown as Map<string, Array<Set<T>>>; }
		function over(a: string): string; function over(a: number): number; function over(a: any) { return a satisfies unknown, a!; }
		let tuple = [1, "a"] as const, fn2 = function <T extends keyof U>(this: void, ...args: T[]): args is T[] { return true };
	`},
	{"view.jsx", `
		const View = ({ items, ...props }) => (
			<Fragment key="k">
				<ns:tag a="1" b={2} {...props} c={` + "`t${items.length}`" + `}>text &amp; {items.map(item => <li key={item.id}>{item.name}</li>)}</ns:tag>
				<Member.Expr.Tag /><>{/* comment */}</>
			</Fragment>
		);
	`},
	{"errors.js", `var = 1; function ( { } class { ; let let = 2; x = ` + "`${`" + `; if (a b) c; return; const k; "\u{110000}"; 0b2; 1_; for (;;;) {} import x from; export { q };`},
}

// Fails every allocation request after the first `budget` of them, the way
// an exhausted arena does. Frees and queries pass through.
@(private="file")
FailingAllocator :: struct {
	backing:  mem.Allocator,
	budget:   int, // requests still allowed to succeed
	requests: int, // allocation requests seen
	failures: int, // of which refused
}

@(private="file")
failing_allocator_proc :: proc(
	allocator_data: rawptr, mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr, old_size: int,
	loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^FailingAllocator)(allocator_data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if size > 0 {
			state.requests += 1
			if state.budget == 0 {
				state.failures += 1
				return nil, .Out_Of_Memory
			}
			state.budget -= 1
		}
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

@(private="file")
OomOutcome :: struct {
	requests:     int,
	failures:     int,
	errors:       int,
	oom_errors:   int,
	oom_span:     [2]u32,
	body:         int,
	reserve_used: int,
	fallback_used: int,
}

// Parse `sample` through the ordinary job pipeline with the job's arena
// wrapped so that it fails after `budget` allocation requests.
@(private="file")
parse_with_allocation_budget :: proc(t: ^testing.T, sample: HardeningSample, budget: int) -> (outcome: OomOutcome) {
	job: kessel.ParseJob
	if !testing.expect(t, kessel.parse_job_open_inline(&job, sample.source, {}, sample.label)) { return }
	defer kessel.parse_job_close(&job)
	failing := FailingAllocator{backing = job.arena_alloc, budget = budget}
	job.arena_alloc = mem.Allocator{procedure = failing_allocator_proc, data = &failing}
	kessel.parse_job_run(&job)

	outcome.requests = failing.requests
	outcome.failures = failing.failures
	outcome.errors = len(job.parser.errors)
	for error in job.parser.errors {
		if error.code != .K2085_OutOfMemory { continue }
		outcome.oom_errors += 1
		outcome.oom_span = {error.start, error.end}
	}
	if testing.expect(t, job.program != nil) { outcome.body = len(job.program.body) }
	outcome.reserve_used = job.guard.reserve_used
	outcome.fallback_used = job.guard.fallback_used
	return
}

// Goal: wherever in a parse the arena runs out, the job reports exactly one
// K2085 diagnostic with a span inside the source, hands back an empty
// Program, and does not crash; and a parse that had enough memory is
// untouched by the machinery.
//
// Method: fault injection. For each sample, count the allocation requests
// R of an unrestricted parse, then re-run the parse R + 1 times with the
// arena failing from request 0, 1, ..., R onward.
@(test)
test_allocation_failure_at_every_request :: proc(t: ^testing.T) {
	reserve_used_max := 0
	runs := 0
	for sample in HARDENING_SAMPLES {
		baseline := parse_with_allocation_budget(t, sample, max(int))
		testing.expect_value(t, baseline.failures, 0)
		testing.expect_value(t, baseline.oom_errors, 0)
		testing.expect_value(t, baseline.reserve_used, 0)
		testing.expectf(t, baseline.requests > 20, "%s: only %d requests", sample.label, baseline.requests)

		for budget in 0..=baseline.requests {
			outcome := parse_with_allocation_budget(t, sample, budget)
			runs += 1
			reserve_used_max = max(reserve_used_max, outcome.reserve_used)
			if outcome.failures == 0 {
				// Enough memory after all: identical to the baseline.
				testing.expectf(t, outcome.errors == baseline.errors && outcome.body == baseline.body,
					"%s budget %d: differs from baseline without a failure", sample.label, budget)
				continue
			}
			testing.expectf(t, outcome.oom_errors == 1,
				"%s budget %d: %d K2085 errors (of %d)", sample.label, budget, outcome.oom_errors, outcome.errors)
			testing.expectf(t, outcome.body == 0, "%s budget %d: body not emptied", sample.label, budget)
			testing.expectf(t, outcome.oom_span[0] <= outcome.oom_span[1] && int(outcome.oom_span[1]) <= len(sample.source),
				"%s budget %d: span %v outside source", sample.label, budget, outcome.oom_span)
		}
	}
	// The reserve must cover unwinding with room to spare; if this trips,
	// raise ALLOC_GUARD_RESERVE_SIZE rather than the fraction.
	testing.expectf(t, reserve_used_max <= kessel.ALLOC_GUARD_RESERVE_SIZE / 2,
		"reserve high-water mark %d of %d", reserve_used_max, kessel.ALLOC_GUARD_RESERVE_SIZE)
	log.infof("allocation-failure sweep: %d parses, reserve high-water mark %d bytes", runs, reserve_used_max)
}

// As parse_with_allocation_budget, but with the parser's node bump pool cut
// down to `pool_capacity` bytes so that almost every AST node takes the
// constructors' fallback path and is a separate allocation request. The
// job pipeline is spelled out by hand because that is the only way to
// reach the pool between init_parser and parse_program, which also means
// the guard here has no fallback allocator unless `fallback` supplies one.
// `reserve_available` = false empties the guard's inline reserve.
@(private="file")
parse_with_small_pool :: proc(
	t: ^testing.T, sample: HardeningSample, budget: int, pool_capacity: int,
	reserve_available := true, fallback := mem.Allocator{},
) -> (outcome: OomOutcome) {
	job: kessel.ParseJob
	if !testing.expect(t, kessel.parse_job_open_inline(&job, sample.source, {}, sample.label)) { return }
	defer kessel.parse_job_close(&job)
	failing := FailingAllocator{backing = job.arena_alloc, budget = budget}
	backing := mem.Allocator{procedure = failing_allocator_proc, data = &failing}

	kessel.alloc_guard_init(&job.guard, backing, fallback, &job.lexer.offset)
	if !reserve_available { job.guard.reserve_used = kessel.ALLOC_GUARD_RESERVE_SIZE }
	guarded := kessel.alloc_guard_allocator(&job.guard)
	context.allocator = guarded
	kessel.init_lexer(&job.lexer, sample.source, guarded, job.lex_source_type)
	kessel.init_parser(&job.parser, &job.lexer, guarded, job.lang, job.source_is_dts)
	job.parser.alloc_guard = &job.guard
	job.parser.node_pool.capacity = min(job.parser.node_pool.capacity, pool_capacity)
	job.program = kessel.parse_program(&job.parser, job.initial_source_type)

	outcome.requests = failing.requests
	outcome.failures = failing.failures
	outcome.errors = len(job.parser.errors)
	for error in job.parser.errors {
		if error.code != .K2085_OutOfMemory { continue }
		outcome.oom_errors += 1
		outcome.oom_span = {error.start, error.end}
	}
	if testing.expect(t, job.program != nil) { outcome.body = len(job.program.body) }
	outcome.reserve_used = job.guard.reserve_used
	outcome.fallback_used = job.guard.fallback_used
	return
}

// Goal: the node constructors (new_node / new_expr / new_stmt) survive the
// arena failing at ANY node, deep inside nested expressions and statements,
// and the frames unwinding afterwards are served from the guard's reserve.
//
// Method: the same sweep as above with a 256-byte node pool, which makes
// every node past the first few an allocation request of its own; the
// number of requests per sample goes from a few dozen to over a thousand.
@(test)
test_allocation_failure_at_every_node :: proc(t: ^testing.T) {
	reserve_used_max := 0
	runs := 0
	requests_total := 0
	for sample in HARDENING_SAMPLES {
		baseline := parse_with_small_pool(t, sample, max(int), 256)
		whole := parse_with_allocation_budget(t, sample, max(int))
		testing.expect_value(t, baseline.failures, 0)
		// A starved pool changes where nodes live, not what is parsed.
		testing.expectf(t, baseline.errors == whole.errors && baseline.body == whole.body,
			"%s: small pool changed the parse", sample.label)
		testing.expectf(t, baseline.requests > 30, "%s: only %d requests", sample.label, baseline.requests)
		requests_total += baseline.requests

		for budget in 0..=baseline.requests {
			outcome := parse_with_small_pool(t, sample, budget, 256)
			runs += 1
			reserve_used_max = max(reserve_used_max, outcome.reserve_used)
			if outcome.failures == 0 {
				testing.expectf(t, outcome.errors == baseline.errors && outcome.body == baseline.body,
					"%s budget %d: differs from baseline without a failure", sample.label, budget)
				continue
			}
			testing.expectf(t, outcome.oom_errors == 1,
				"%s budget %d: %d K2085 errors (of %d)", sample.label, budget, outcome.oom_errors, outcome.errors)
			testing.expectf(t, outcome.body == 0, "%s budget %d: body not emptied", sample.label, budget)
			testing.expectf(t, int(outcome.oom_span[1]) <= len(sample.source),
				"%s budget %d: span %v outside source", sample.label, budget, outcome.oom_span)
		}
	}
	testing.expectf(t, reserve_used_max <= kessel.ALLOC_GUARD_RESERVE_SIZE / 2,
		"reserve high-water mark %d of %d", reserve_used_max, kessel.ALLOC_GUARD_RESERVE_SIZE)
	testing.expectf(t, requests_total > 1000, "only %d requests across the samples", requests_total)
	log.infof("per-node failure sweep: %d parses, reserve high-water mark %d bytes", runs, reserve_used_max)
}

// Goal: when the arena is exhausted the guard's fallback allocator alone,
// with the inline reserve unavailable, is enough to finish every parse.
// This is the arrangement parse_job_run sets up (fallback = fresh pages
// from the OS, or small blocks from the caller's allocator); the reserve
// is the layer behind it.
//
// Method: the per-node sweep again with the reserve marked used up and a
// heap-backed arena as the fallback.
@(test)
test_allocation_failure_served_by_fallback :: proc(t: ^testing.T) {
	runs := 0
	fallback_used_max := 0
	for sample in HARDENING_SAMPLES {
		baseline := parse_with_small_pool(t, sample, max(int), 256)
		for budget in 0..=baseline.requests {
			spare: mem.Dynamic_Arena
			mem.dynamic_arena_init(&spare, context.allocator, context.allocator)
			outcome := parse_with_small_pool(t, sample, budget, 256, false, mem.dynamic_arena_allocator(&spare))
			mem.dynamic_arena_destroy(&spare)
			runs += 1
			fallback_used_max = max(fallback_used_max, outcome.fallback_used)
			if outcome.failures == 0 {
				testing.expectf(t, outcome.fallback_used == 0, "%s budget %d: fallback used without a failure", sample.label, budget)
				continue
			}
			testing.expectf(t, outcome.oom_errors == 1,
				"%s budget %d: %d K2085 errors (of %d)", sample.label, budget, outcome.oom_errors, outcome.errors)
			testing.expectf(t, outcome.body == 0, "%s budget %d: body not emptied", sample.label, budget)
			testing.expectf(t, outcome.reserve_used == kessel.ALLOC_GUARD_RESERVE_SIZE,
				"%s budget %d: reserve touched", sample.label, budget)
		}
	}
	testing.expectf(t, fallback_used_max > 0, "fallback never used in %d runs", runs)
	testing.expectf(t, fallback_used_max <= kessel.ALLOC_GUARD_FALLBACK_SIZE_MAX, "fallback cap exceeded: %d", fallback_used_max)
	log.infof("fallback sweep: %d parses, fallback high-water mark %d bytes", runs, fallback_used_max)
}

// ----------------------------------------------------------------------------
// parse_job_open_inline(..., backing)
// ----------------------------------------------------------------------------

// Counts every allocation request it sees and forwards it. Installed as
// context.allocator / context.temp_allocator around a job that was given
// its own allocator, where any request at all is a leak past that allocator.
@(private="file")
CountingAllocator :: struct {
	backing:  mem.Allocator,
	requests: int,
}

@(private="file")
counting_allocator_proc :: proc(
	allocator_data: rawptr, mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr, old_size: int,
	loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^CountingAllocator)(allocator_data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if size > 0 { state.requests += 1 }
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

// Goal: a job opened with a caller-supplied allocator takes all its memory
// from that allocator and gives all of it back on close.
//
// Method: supply a tracking allocator and, for the duration of open / run /
// close, replace context.allocator and context.temp_allocator with counting
// allocators. Afterwards the tracker must show allocations made and none
// outstanding, no bad frees, and the two counters must still be zero. The
// samples include one full of syntax errors, whose formatted messages are
// the allocations most likely to stray.
@(test)
test_supplied_allocator_owns_all_memory :: proc(t: ^testing.T) {
	for sample in HARDENING_SAMPLES {
		tracker: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracker, context.allocator)
		defer mem.tracking_allocator_destroy(&tracker)
		stray_heap := CountingAllocator{backing = context.allocator}
		stray_temp := CountingAllocator{backing = context.temp_allocator}

		reference: kessel.ParseJob
		if !testing.expect(t, kessel.parse_job_open_inline(&reference, sample.source, {}, sample.label)) { continue }
		kessel.parse_job_run(&reference)
		reference_errors := len(reference.parser.errors)
		reference_body := len(reference.program.body)
		kessel.parse_job_close(&reference)

		errors, body, live_peak: int
		{
			context.allocator = mem.Allocator{procedure = counting_allocator_proc, data = &stray_heap}
			context.temp_allocator = mem.Allocator{procedure = counting_allocator_proc, data = &stray_temp}
			job: kessel.ParseJob
			opened := kessel.parse_job_open_inline(&job, sample.source, {}, sample.label, mem.tracking_allocator(&tracker))
			if !testing.expect(t, opened) { continue }
			testing.expect(t, job.arena_ptr == nil) // no virtual arena behind the caller's back
			kessel.parse_job_run(&job)
			errors = len(job.parser.errors)
			body = len(job.program.body)
			live_peak = len(tracker.allocation_map)
			kessel.parse_job_close(&job)
			kessel.parse_job_close(&job) // idempotent
		}

		// Same parse as with the job's own arena.
		testing.expectf(t, errors == reference_errors && body == reference_body,
			"%s: %d errors / %d statements, reference %d / %d", sample.label, errors, body, reference_errors, reference_body)
		testing.expectf(t, live_peak > 0, "%s: nothing was allocated from the supplied allocator", sample.label)
		testing.expectf(t, len(tracker.allocation_map) == 0,
			"%s: %d allocations not released on close", sample.label, len(tracker.allocation_map))
		testing.expectf(t, len(tracker.bad_free_array) == 0, "%s: %d bad frees", sample.label, len(tracker.bad_free_array))
		testing.expectf(t, tracker.current_memory_allocated == 0,
			"%s: %d bytes outstanding", sample.label, tracker.current_memory_allocated)
		testing.expectf(t, stray_heap.requests == 0, "%s: %d requests to context.allocator", sample.label, stray_heap.requests)
		testing.expectf(t, stray_temp.requests == 0, "%s: %d requests to context.temp_allocator", sample.label, stray_temp.requests)
	}
}

// A heap with a ceiling: refuses any request that would take the bytes
// outstanding in `tracker` past `limit`. Unlike a fixed-buffer arena it
// honours free, so "everything was released" stays checkable.
@(private="file")
LimitedAllocator :: struct {
	tracker: ^mem.Tracking_Allocator,
	limit:   i64,
	refused: int,
}

@(private="file")
limited_allocator_proc :: proc(
	allocator_data: rawptr, mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr, old_size: int,
	loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^LimitedAllocator)(allocator_data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		growth := i64(size) - i64(old_size if old_memory != nil else 0)
		if state.tracker.current_memory_allocated + growth > state.limit {
			state.refused += 1
			return nil, .Out_Of_Memory
		}
	}
	return mem.tracking_allocator_proc(state.tracker, mode, size, alignment, old_memory, old_size, loc)
}

// Goal: an allocator that is simply too small ("deliberately tiny arena")
// produces K2085, not a crash, at whatever point it runs dry, and whatever
// was taken from it is still returned on close.
//
// Method: supply a heap with a byte ceiling, raising the ceiling from zero
// in 512-byte steps until the parse succeeds. The job is opened through the
// public API, so this covers the whole supplied-allocator arrangement: the
// 64 KiB block arena, the 4 KiB emergency blocks taken from the same
// allocator once it refuses a big request, and the guard's inline reserve.
@(test)
test_supplied_allocator_too_small :: proc(t: ^testing.T) {
	LIMIT_STEP :: 512
	LIMIT_MAX  :: 4 * 1024 * 1024
	for sample in HARDENING_SAMPLES {
		reference: kessel.ParseJob
		if !testing.expect(t, kessel.parse_job_open_inline(&reference, sample.source, {}, sample.label)) { continue }
		kessel.parse_job_run(&reference)
		reference_errors := len(reference.parser.errors)
		reference_body := len(reference.program.body)
		kessel.parse_job_close(&reference)

		refused_runs := 0
		succeeded := false
		for limit := 0; limit <= LIMIT_MAX; limit += LIMIT_STEP {
			tracker: mem.Tracking_Allocator
			mem.tracking_allocator_init(&tracker, context.allocator)
			limited := LimitedAllocator{tracker = &tracker, limit = i64(limit)}
			supplied := mem.Allocator{procedure = limited_allocator_proc, data = &limited}

			job: kessel.ParseJob
			if testing.expect(t, kessel.parse_job_open_inline(&job, sample.source, {}, sample.label, supplied)) {
				kessel.parse_job_run(&job)
				oom_errors := 0
				for error in job.parser.errors {
					if error.code == .K2085_OutOfMemory { oom_errors += 1 }
				}
				// A refusal need not be a failure: the node pool asks for
				// less when its first request is refused. The guard's latch
				// is the definition of "this parse ran out of memory".
				if job.guard.failed {
					testing.expectf(t, limited.refused > 0, "%s, limit %d: latch without a refusal", sample.label, limit)
					refused_runs += 1
					testing.expectf(t, oom_errors == 1, "%s, limit %d: %d K2085 errors", sample.label, limit, oom_errors)
					testing.expectf(t, len(job.program.body) == 0, "%s, limit %d: body not emptied", sample.label, limit)
				} else {
					testing.expectf(t, oom_errors == 0, "%s, limit %d: K2085 without a failure", sample.label, limit)
					testing.expectf(t, len(job.parser.errors) == reference_errors && len(job.program.body) == reference_body,
						"%s, limit %d: parse differs from the reference", sample.label, limit)
					succeeded = true
				}
				kessel.parse_job_close(&job)
			}
			testing.expectf(t, len(tracker.allocation_map) == 0,
				"%s, limit %d: %d allocations not released", sample.label, limit, len(tracker.allocation_map))
			testing.expectf(t, len(tracker.bad_free_array) == 0, "%s, limit %d: bad frees", sample.label, limit)
			mem.tracking_allocator_destroy(&tracker)
			if succeeded { break }
		}
		testing.expectf(t, succeeded, "%s: never fit in %d bytes", sample.label, LIMIT_MAX)
		testing.expectf(t, refused_runs > 50, "%s: only %d limits were too small", sample.label, refused_runs)
	}
}

// A large generated program wrapped in one function: many functions with
// nested blocks, long argument lists, object and array literals, so lists
// are still growing and frames are still deep whenever memory runs out.
@(private="file")
large_program_source :: proc(size_min: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	// One top-level statement, like a bundled library: the parser's
	// per-top-level-statement check never runs while memory runs out.
	strings.write_string(&b, "(function (root) {\n")
	for index := 0; strings.builder_len(b) < size_min; index += 1 {
		fmt.sbprintf(&b, "function f%d(a, b = {{x: [1, 2, 3], y: `t${{a}}`}}, ...rest) {{\n", index)
		for row in 0 ..< 12 {
			fmt.sbprintf(&b, "  if (a.p%d && b[%d] !== rest.length) {{ for (const k of rest) {{", row, row)
			fmt.sbprintf(&b, " g(k, [a, b, k, %d, 'v%d'], {{k, n: k + %d, m() {{ return a ? b : k; }}}}); }} }}\n", row, row, row)
		}
		strings.write_string(&b, "  return [a, b, ...rest].map((v, i) => ({v, i, s: String(v)}));\n}\n")
	}
	strings.write_string(&b, "})(this);\n")
	return strings.to_string(b)
}

// Goal: on an input of several hundred kilobytes, a supplied allocator that
// runs dry anywhere produces exactly one K2085 and never a panic.
//
// Method: the same ceiling allocator as above, on a generated 380 KB
// program, with ceilings from 64 KiB up to the first one the parse fits in.
// The small samples above run dry within a few frames of the top level;
// this one runs dry with long lists mid-growth and the node pool mid-chunk,
// which is where the wind-down used to outgrow the guard's reserve.
@(test)
test_supplied_allocator_too_small_for_a_large_input :: proc(t: ^testing.T) {
	LIMIT_FIRST :: 64 * 1024
	LIMIT_STEP  :: 37 * 1024
	LIMIT_MAX   :: 64 * 1024 * 1024
	source := large_program_source(380 * 1024)
	refused_runs := 0
	succeeded := false
	for limit := LIMIT_FIRST; limit <= LIMIT_MAX && !succeeded; limit += LIMIT_STEP {
		tracker: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracker, context.allocator)
		limited := LimitedAllocator{tracker = &tracker, limit = i64(limit)}
		supplied := mem.Allocator{procedure = limited_allocator_proc, data = &limited}

		job: kessel.ParseJob
		if testing.expect(t, kessel.parse_job_open_inline(&job, source, {}, "large", supplied)) {
			kessel.parse_job_run(&job)
			oom_errors := 0
			for error in job.parser.errors {
				if error.code == .K2085_OutOfMemory { oom_errors += 1 }
			}
			if job.guard.failed {
				refused_runs += 1
				testing.expectf(t, oom_errors == 1, "limit %d: %d K2085 errors", limit, oom_errors)
				testing.expectf(t, len(job.program.body) == 0, "limit %d: body not emptied", limit)
			} else {
				testing.expectf(t, len(job.parser.errors) == 0, "limit %d: unexpected errors", limit)
				succeeded = true
			}
			kessel.parse_job_close(&job)
		}
		testing.expectf(t, len(tracker.allocation_map) == 0, "limit %d: allocations not released", limit)
		mem.tracking_allocator_destroy(&tracker)
	}
	testing.expectf(t, succeeded, "never fit in %d bytes", LIMIT_MAX)
	testing.expectf(t, refused_runs > 20, "only %d limits were too small", refused_runs)
}
