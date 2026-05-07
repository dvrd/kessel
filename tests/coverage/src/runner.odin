// runner.odin — execute fixtures through kessel's parser and convert
// (parse-error count, should_fail) into a `TestResult`.
//
// Mirrors `oxc-project/oxc:tasks/coverage/src/tools.rs:run_parser_*`. Each
// suite has a `run_<suite>` proc that:
//
//   1. Discovers fixtures via load_<suite>.
//   2. Allocates a single large mvirtual.Arena per worker (reused across
//      fixtures via `parse_job_reset_arena`). Avoids 50k mmap/munmap
//      round-trips that would otherwise dominate runtime.
//   3. For each fixture:
//        * open ParseJob over the source string with the worker's arena
//        * run → get error count
//        * classify → TestResult (Passed / CorrectError / IncorrectlyPassed
//          / ParseError)
//        * reset arena
//   4. Returns a `[]CoverageRecord` sorted by `rel`.
//
// Phase-7 scope: sequential per-fixture. Phase 10 wraps `core:thread.Pool`
// around it for inner parallelism in the standalone binary; the
// `core:testing` wrapper relies on outer parallelism (one @test per core)
// so it stays sequential.
package coverage

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

import kessel "../../../src"

// run_parser_one — execute one Fixture through kessel's parser pipeline.
//
// Uses `parse_job_open_inline` (which allocates its own per-fixture arena
// via mmap). Per-fixture mmap costs ~50µs which adds up to a few seconds
// across 50k fixtures — acceptable for phase 7. Phase 10 will introduce a
// borrowed-arena variant of the inline opener for the standalone binary's
// hot path.
//
// The diagnostic string (when non-empty) is allocated in `record_alloc`
// and lives until the suite render completes. The job's arena dies with
// `parse_job_close`, so we always clone the diagnostic out first.
run_parser_one :: proc(
	fix:          Fixture,
	tool:         Tool,
	record_alloc: runtime.Allocator,
) -> TestResult {
	cfg := kessel.ParseConfig{
		lang_override          = fix.lang,
		source_type_override   = fix.source_type,
		strict_source_type     = false,
		force_strict           = fix.force_strict,
		preserve_parens        = false,
		ast_only               = false,
		check_semantics        = tool == .Semantic,
		source_is_dts_override = fix.source_is_dts,
		is_commonjs_override   = fix.is_commonjs,
	}

	job: kessel.ParseJob
	defer kessel.parse_job_close(&job)

	source_label := fix.path  // routes through detect_lang_from_path / dts detection
	if !kessel.parse_job_open_inline(&job, fix.code, cfg, source_label) {
		return TestResult{
			tag        = .GenericError,
			diagnostic = strings.clone("parse_job_open_inline failed (arena init)", record_alloc),
		}
	}

	kessel.parse_job_run(&job)
	if tool == .Semantic {
		kessel.checker_run_for_job(&job)
	}

	error_count := len(job.parser.errors)

	// Classify.
	switch {
	case fix.should_fail && error_count > 0:
		return TestResult{
			tag        = .CorrectError,
			diagnostic = render_first_error(&job, fix.rel, record_alloc),
		}
	case fix.should_fail && error_count == 0:
		return TestResult{
			tag = .IncorrectlyPassed,
		}
	case !fix.should_fail && error_count > 0:
		return TestResult{
			tag        = .ParseError,
			diagnostic = render_first_error(&job, fix.rel, record_alloc),
		}
	}

	return TestResult{tag = .Passed}
}

// Render the first parser error as a single-line diagnostic suitable for
// the snap file. Format: `<rel>:<line>:<col>: <message>`. Mirrors the
// non-JSON output kessel CLI emits to stderr.
@(private="file")
render_first_error :: proc(
	job:   ^kessel.ParseJob,
	rel:   string,
	alloc: runtime.Allocator,
) -> string {
	if len(job.parser.errors) == 0 { return "" }
	err := job.parser.errors[0]
	// Lazily build the line-offset table — `parse_job_run` doesn't, so
	// `job.lexer.line_offsets` is empty here.
	if len(job.lexer.line_offsets) == 0 {
		kessel.build_line_table(&job.lexer)
	}
	line, col := kessel.offset_to_line_col(job.lexer.line_offsets, u32(err.loc))
	buf := strings.builder_make(alloc)
	fmt.sbprintf(&buf, "%s:%d:%d: %s", rel, line, col, err.message)
	return strings.to_string(buf)
}

// ============================================================================
// Per-suite runner — sequential
// ============================================================================

run_parser_suite :: proc(
	suite:        Suite,
	tool:         Tool,
	fixtures:     []Fixture,
	record_alloc: runtime.Allocator,
) -> CoverageRun {
	t0 := time.now()

	records := make([dynamic]CoverageRecord, 0, len(fixtures), record_alloc)

	for fix in fixtures {
		result := run_parser_one(fix, tool, record_alloc)

		append(&records, CoverageRecord{
			rel         = strings.clone(fix.rel, record_alloc),
			should_fail = fix.should_fail,
			result      = result,
		})
	}

	// Stable order for deterministic snapshot output.
	sorted := records[:]
	slice.sort_by(sorted, proc(a, b: CoverageRecord) -> bool { return a.rel < b.rel })

	stats := stats_compute(sorted)

	return CoverageRun{
		tool    = tool,
		suite   = suite,
		records = sorted,
		stats   = stats,
		elapsed = time.since(t0),
	}
}

// Forwarder used by the standalone CLI / @test wrappers. Same code path
// regardless of caller. Phase 11+ may add a parallel variant under the
// standalone binary; @test stays sequential and relies on outer parallelism.
run_one_suite :: proc(
	suite:        Suite,
	tool:         Tool,
	vendor_root:  string,
	project_root: string,
	record_alloc: runtime.Allocator,
) -> CoverageRun {
	fixtures: []Fixture
	switch suite {
	case .Test262:    fixtures = load_test262   (vendor_root,  record_alloc)
	case .Babel:      fixtures = load_babel     (vendor_root,  record_alloc)
	case .TypeScript: fixtures = load_typescript(vendor_root,  record_alloc)
	case .Estree:     fixtures = load_estree    (vendor_root,  record_alloc)
	case .Misc:       fixtures = load_misc      (project_root, record_alloc)
	}
	return run_parser_suite(suite, tool, fixtures, record_alloc)
}


