package coverage

import "core:testing"

import kessel "../../../src"

@(test)
test_semantic_model_resolves_reads_and_writes :: proc(t: ^testing.T) {
	source := "const outer = 1; function run(value = outer) { let local = value; local += outer; return local; }"
	job: kessel.ParseJob
	if !testing.expect(t, kessel.parse_job_open_inline(&job, source, {}, "semantic.js")) { return }
	defer kessel.parse_job_close(&job)
	kessel.parse_job_run(&job)
	if !testing.expect_value(t, len(job.parser.errors), 0) { return }

	model := kessel.semantic_build(job.program, source, .JS, job.arena_alloc)
	if !testing.expect_value(t, len(model.refs), 5) { return }
	want_names := [?]string{"outer", "value", "local", "outer", "local"}
	want_kinds := [?]kessel.RefKind{.Read, .Read, .ReadWrite, .Read, .Read}
	for ref, index in model.refs {
		testing.expect_value(t, ref.name, want_names[index])
		testing.expect_value(t, ref.kind, want_kinds[index])
		if testing.expect(t, ref.resolved != kessel.SYMBOL_UNRESOLVED) {
			testing.expect_value(t, kessel.semantic_symbol(&model, ref.resolved).name, ref.name)
		}
	}
	testing.expect_value(t, model.refs[0].resolved, model.refs[3].resolved)
	testing.expect_value(t, model.refs[2].resolved, model.refs[4].resolved)
}

@(test)
test_semantic_model_visits_computed_keys :: proc(t: ^testing.T) {
	source := "const key = 0, value = 1; target[key] = {[key]: value}; const {[key]: item} = target;"
	job: kessel.ParseJob
	if !testing.expect(t, kessel.parse_job_open_inline(&job, source, {}, "computed.js")) { return }
	defer kessel.parse_job_close(&job)
	kessel.parse_job_run(&job)
	if !testing.expect_value(t, len(job.parser.errors), 0) { return }

	model := kessel.semantic_build(job.program, source, .JS, job.arena_alloc)
	for symbol in model.symbols {
		if symbol.name != "key" { continue }
		testing.expect_value(t, symbol.ref_count, 3)
		return
	}
	testing.expect(t, false, "missing key binding")
}

@(test)
test_semantic_model_try_blocks_have_lexical_scope :: proc(t: ^testing.T) {
	source := "try { let hidden = 1; hidden; } finally { const cleanup = 2; cleanup; } hidden; cleanup;"
	job: kessel.ParseJob
	if !testing.expect(t, kessel.parse_job_open_inline(&job, source, {}, "try.js")) { return }
	defer kessel.parse_job_close(&job)
	kessel.parse_job_run(&job)
	if !testing.expect_value(t, len(job.parser.errors), 0) { return }

	model := kessel.semantic_build(job.program, source, .JS, job.arena_alloc)
	if !testing.expect_value(t, len(model.refs), 4) { return }
	testing.expect(t, model.refs[0].resolved != kessel.SYMBOL_UNRESOLVED)
	testing.expect(t, model.refs[1].resolved != kessel.SYMBOL_UNRESOLVED)
	testing.expect_value(t, model.refs[2].resolved, kessel.SYMBOL_UNRESOLVED)
	testing.expect_value(t, model.refs[3].resolved, kessel.SYMBOL_UNRESOLVED)
}
