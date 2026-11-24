package coverage

// Unit tests for the parser's nesting-depth limit, through the library
// surface (ParseConfig / ParseJob) rather than the CLI.
//
// Goal: pin the contract an embedder relies on. `max_depth` zero means the
// default of 512; nesting past the limit yields exactly one spanned K2081
// and a tree without the offending item; binary / logical / member / call
// chains are exempt and reach the checker, the semantic model and both
// emitters without recursion.
//
// Method: sources are built in memory and parsed with
// parse_job_open_inline, the entry point the FFI layer uses. The chains
// here are 200,000 terms: several times past the length that overflowed
// an 8 MB stack before the walkers became iterative (about 29,000 in an
// optimised build), yet quick enough for the unit gate. The million-term
// and constrained-stack runs live in tests/verifiers/verify_depth_limit.js.

import "core:strings"
import "core:testing"

import kessel "../../../src"

DEPTH_TEST_CHAIN_TERMS :: 200_000

// depth_test_repeat builds prefix^count + middle + suffix^count.
depth_test_repeat :: proc(prefix: string, middle: string, suffix: string, count: int) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< count { strings.write_string(&builder, prefix) }
	strings.write_string(&builder, middle)
	for _ in 0 ..< count { strings.write_string(&builder, suffix) }
	return strings.to_string(builder)
}

// depth_test_parse opens and runs a job. The caller closes it.
depth_test_parse :: proc(
	t: ^testing.T,
	job: ^kessel.ParseJob,
	source: string,
	config: kessel.ParseConfig,
	label: string,
) -> bool {
	if !testing.expect(t, kessel.parse_job_open_inline(job, source, config, label)) { return false }
	kessel.parse_job_run(job)
	return true
}

@(test)
test_depth_limit_default_is_512 :: proc(t: ^testing.T) {
	testing.expect_value(t, kessel.PARSE_RESOURCE_AST_DEPTH, 512)
	// Zero and negative both select the default; there is no "unlimited".
	for requested in ([?]int{0, -1, -512}) {
		job: kessel.ParseJob
		if !depth_test_parse(t, &job, "x;", {max_depth = requested}, "default.js") { return }
		testing.expect_value(t, job.parser.depth_max, u32(512))
		testing.expect_value(t, job.parser.depth_left, u32(512))
		testing.expect_value(t, len(job.parser.errors), 0)
		kessel.parse_job_close(&job)
	}
}

@(test)
test_depth_limit_rejects_with_one_spanned_error :: proc(t: ^testing.T) {
	source := depth_test_repeat("[", "", "]", 600)
	job: kessel.ParseJob
	if !depth_test_parse(t, &job, source, {}, "deep.js") { return }
	defer kessel.parse_job_close(&job)

	testing.expect(t, job.parser.depth_exceeded)
	if !testing.expect_value(t, len(job.parser.errors), 1) { return }
	err := job.parser.errors[0]
	testing.expect_value(t, err.code, kessel.ErrorCode.K2081_NestingTooDeep)
	testing.expect_value(t, err.severity, kessel.Severity.Error)
	// Spanned: the error covers the token that would have opened level 513.
	testing.expect(t, err.end > err.start)
	testing.expect(t, int(err.end) <= len(source))
	testing.expect_value(t, source[err.start:err.end], "[")
	// The budget is whole again once every frame has unwound.
	testing.expect_value(t, job.parser.depth_left, job.parser.depth_max)
	// The checker adds nothing to a tree the parser gave up on.
	kessel.checker_run_for_job(&job)
	testing.expect_value(t, len(job.parser.errors), 1)
}

@(test)
test_depth_limit_keeps_earlier_items_and_errors :: proc(t: ^testing.T) {
	deep := depth_test_repeat("(", "1", ")", 600)
	source := strings.concatenate({"first;\nvar = 2;\n", deep, ";\nnever;\n"}, context.temp_allocator)
	job: kessel.ParseJob
	if !depth_test_parse(t, &job, source, {}, "mixed.js") { return }
	defer kessel.parse_job_close(&job)

	// The diagnostic reported before the limit stays, K2081 comes last,
	// and nothing from the unwinding frames is reported.
	if !testing.expect_value(t, len(job.parser.errors), 2) { return }
	testing.expect(t, job.parser.errors[0].code != .K2081_NestingTooDeep)
	testing.expect_value(t, job.parser.errors[1].code, kessel.ErrorCode.K2081_NestingTooDeep)
	// Items completed before the limit stay in the tree; the item the
	// limit was hit in, and everything after it, is absent.
	testing.expect_value(t, len(job.program.body), 2)
}

@(test)
test_depth_limit_is_configurable :: proc(t: ^testing.T) {
	source := depth_test_repeat("[", "", "]", 40)
	{
		job: kessel.ParseJob
		if !depth_test_parse(t, &job, source, {max_depth = 32}, "low.js") { return }
		defer kessel.parse_job_close(&job)
		if testing.expect_value(t, len(job.parser.errors), 1) {
			testing.expect_value(t, job.parser.errors[0].code, kessel.ErrorCode.K2081_NestingTooDeep)
		}
	}
	{
		job: kessel.ParseJob
		if !depth_test_parse(t, &job, source, {max_depth = 64}, "high.js") { return }
		defer kessel.parse_job_close(&job)
		testing.expect_value(t, len(job.parser.errors), 0)
		testing.expect(t, !job.parser.depth_exceeded)
	}
	{
		// resource_budget.ast_depth is the fallback when max_depth is unset.
		job: kessel.ParseJob
		config := kessel.ParseConfig{resource_budget = {ast_depth = 32}}
		if !depth_test_parse(t, &job, source, config, "budget.js") { return }
		defer kessel.parse_job_close(&job)
		testing.expect_value(t, job.parser.depth_max, u32(32))
		testing.expect_value(t, len(job.parser.errors), 1)
	}
}

@(test)
test_depth_limit_survives_speculation :: proc(t: ^testing.T) {
	// Arrow-parameter and TypeScript generic lookahead rewind the lexer on
	// failure. The limit must hold across that: one error, no re-parse of
	// the deep input per speculation point, budget restored afterwards.
	sources := [?]struct{ label: string, text: string }{
		{"arrow.ts", depth_test_repeat("(a = (", "1", ")) => a", 400)},
		{"generic.ts", depth_test_repeat("f<A>(", "1", ")", 700)},
		{"async.js", depth_test_repeat("async (", "1", ")", 700)},
		{"cast.ts", depth_test_repeat("<A>(", "1", ")", 700)},
	}
	for entry in sources {
		job: kessel.ParseJob
		if !depth_test_parse(t, &job, entry.text, {}, entry.label) { return }
		testing.expectf(t, job.parser.depth_exceeded, "%s: limit should be hit", entry.label)
		testing.expectf(t, len(job.parser.errors) == 1,
			"%s: expected one error, got %d", entry.label, len(job.parser.errors))
		testing.expectf(t, job.parser.depth_left == job.parser.depth_max,
			"%s: budget not restored", entry.label)
		kessel.parse_job_close(&job)
	}
	// And inside the limit the same constructs still parse.
	{
		job: kessel.ParseJob
		source := depth_test_repeat("(a = (", "1", ")) => a", 60)
		if !depth_test_parse(t, &job, source, {}, "arrow-ok.ts") { return }
		defer kessel.parse_job_close(&job)
		testing.expect_value(t, len(job.parser.errors), 0)
		testing.expect_value(t, job.parser.depth_left, job.parser.depth_max)
	}
}

@(test)
test_depth_limit_exempts_chains :: proc(t: ^testing.T) {
	chains := [?]struct{ label: string, head: string, link: string }{
		{"plus.js", "x = 1", " + 1"},
		{"and.js", "x = a", " && a"},
		{"member.js", "x = a", ".b"},
		{"call.js", "x = a", "()"},
	}
	for chain in chains {
		source := depth_test_repeat("", chain.head, chain.link, DEPTH_TEST_CHAIN_TERMS - 1)
		job: kessel.ParseJob
		if !depth_test_parse(t, &job, source, {}, chain.label) { return }
		testing.expectf(t, len(job.parser.errors) == 0, "%s: chain should parse", chain.label)
		testing.expectf(t, !job.parser.depth_exceeded, "%s: chain hit the depth limit", chain.label)

		// Every walker below used to recurse once per link.
		kessel.checker_run_for_job(&job)
		testing.expectf(t, len(job.parser.errors) == 0, "%s: chain should check", chain.label)

		model := kessel.semantic_build(job.program, source, .JS, job.arena_alloc)
		testing.expectf(t, len(model.scopes) > 0, "%s: semantic model is empty", chain.label)

		emitter: kessel.Emitter
		kessel.emitter_init(&emitter, {compact = true}, len(source), context.allocator)
		kessel.emit_job_json(&emitter, &job)
		testing.expectf(t, emitter.pos > DEPTH_TEST_CHAIN_TERMS,
			"%s: JSON output is %d bytes", chain.label, emitter.pos)
		kessel.emitter_destroy(&emitter)

		kessel.parse_job_close(&job)
	}
}

@(test)
test_expr_spine_flattens_long_and_short_chains :: proc(t: ^testing.T) {
	// One chain that fits the inline storage and one that needs the heap.
	for terms in ([?]int{3, kessel.EXPR_SPINE_INLINE_COUNT + 1, 5000}) {
		source := depth_test_repeat("", "a", ".b", terms - 1)
		job: kessel.ParseJob
		if !depth_test_parse(t, &job, source, {}, "spine.js") { return }
		if !testing.expect_value(t, len(job.program.body), 1) { return }
		statement, is_expression := job.program.body[0]^.(^kessel.ExpressionStatement)
		if !testing.expect(t, is_expression) { return }

		spine: kessel.ExprSpine
		if !testing.expect(t, kessel.expr_spine_open(&spine, statement.expression)) { return }
		testing.expect_value(t, len(spine.nodes), terms - 1)
		testing.expect_value(t, spine.heap_backed, terms - 1 > kessel.EXPR_SPINE_INLINE_COUNT)
		// Outermost first; each node's chain operand is the next node.
		if testing.expect(t, len(spine.nodes) > 0) {
			testing.expect(t, spine.nodes[0] == statement.expression)
			last_child, _ := kessel.expr_spine_child(spine.nodes[len(spine.nodes) - 1])
			testing.expect(t, last_child == spine.leaf)
		}
		_, leaf_is_identifier := spine.leaf^.(^kessel.Identifier)
		testing.expect(t, leaf_is_identifier)
		testing.expect(t, kessel.expr_spine_leaf(statement.expression) == spine.leaf)
		kessel.expr_spine_close(&spine)
		testing.expect_value(t, len(spine.nodes), 0)

		kessel.parse_job_close(&job)
	}
	// A non-chain expression is its own leaf.
	spine: kessel.ExprSpine
	testing.expect(t, kessel.expr_spine_open(&spine, nil))
	testing.expect_value(t, len(spine.nodes), 0)
	testing.expect(t, spine.leaf == nil)
	kessel.expr_spine_close(&spine)
}
