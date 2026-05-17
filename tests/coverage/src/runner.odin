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
		source_is_dts_override = fix.source_is_dts,
		is_commonjs_override   = fix.is_commonjs,
		disallow_ambiguous_jsx_like = fix.disallow_ambiguous_jsx_like,
	}

	job: kessel.ParseJob
	defer kessel.parse_job_close(&job)

	// Use the relative path which includes the sub-unit name (e.g.
	// `.../foo.ts::subfolder/index.mts`). The sub-unit's extension matters
	// for .cts/.mts detection.
	source_label := fix.rel
	if idx := strings.last_index(fix.rel, "::"); idx >= 0 {
		source_label = fix.rel[idx+2:]
	}
	if source_label == "" {
		source_label = fix.path
	}
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

	// TypeScript suite: collapse per-unit records into per-parent-file
	// records to match OXC's classification granularity. OXC produces
	// one CoverageResult per TypeScriptFile (which may contain multiple
	// @filename units). Their rule: run all units, if ANY unit has an
	// error the whole file fails. This avoids inflating the negative
	// denominator with 0-error sub-units of multi-file fixtures.
	final := sorted
	if suite == .TypeScript {
		final = collapse_ts_units(sorted, record_alloc)
	}

	stats := stats_compute(final)

	return CoverageRun{
		tool    = tool,
		suite   = suite,
		records = final,
		stats   = stats,
		elapsed = time.since(t0),
	}
}

// collapse_ts_units — merge per-unit CoverageRecords into per-parent-file
// records. Mirrors OXC's one-result-per-TypeScriptFile approach.
//
// Groups records by parent path (everything before "::"). For each group:
//   - should_fail: inherited from the parent (same for all units)
//   - result: if ANY unit produced a non-Passed result, use the first
//     non-Passed result. Otherwise Passed.
//
// Single-file fixtures (no "::") pass through unchanged.
@(private="file")
collapse_ts_units :: proc(records: []CoverageRecord, alloc: runtime.Allocator) -> []CoverageRecord {
	out := make([dynamic]CoverageRecord, 0, len(records), alloc)

	i := 0
	for i < len(records) {
		rec := records[i]
		parent := parent_path(rec.rel)

		// Find extent of this group (consecutive records with same parent).
		j := i + 1
		for j < len(records) && parent_path(records[j].rel) == parent {
			j += 1
		}

		if j == i + 1 {
			// Single record — pass through (may or may not have "::").
			append(&out, rec)
		} else {
			// Multi-unit group. Merge: if any unit failed, whole file fails.
			merged := CoverageRecord{
				rel         = strings.clone(parent, alloc),
				should_fail = rec.should_fail,
				result      = TestResult{tag = .Passed},
			}
			for k := i; k < j; k += 1 {
				r := records[k]
				// Any non-Passed result means the file has errors.
				if r.result.tag != .Passed && r.result.tag != .IncorrectlyPassed {
					// CorrectError or ParseError — file has errors.
					if merged.result.tag == .Passed || merged.result.tag == .IncorrectlyPassed {
						merged.result = r.result
					}
				}
				if r.result.tag == .IncorrectlyPassed && merged.result.tag == .Passed {
					merged.result = r.result
				}
			}
			// Re-evaluate: should_fail + has_errors → CorrectError / IncorrectlyPassed
			has_errors := merged.result.tag == .CorrectError || merged.result.tag == .ParseError
			if merged.should_fail {
				if has_errors {
					merged.result.tag = .CorrectError
				} else {
					merged.result.tag = .IncorrectlyPassed
				}
			} else {
				if has_errors {
					merged.result.tag = .ParseError
				} else {
					merged.result.tag = .Passed
				}
			}
			append(&out, merged)
		}
		i = j
	}
	return out[:]
}

// parent_path strips the "::unit_name" suffix from a TS multi-file rel path.
@(private="file")
parent_path :: proc(rel: string) -> string {
	if idx := strings.index(rel, "::"); idx >= 0 {
		return rel[:idx]
	}
	return rel
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


