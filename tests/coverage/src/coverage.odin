// Package coverage — kessel's parser/semantic conformance harness.
//
// Mirrors `oxc-project/oxc:tasks/coverage/`. Every fixture in vendored
// test262 / babel / typescript / acorn-jsx / kessel-misc is classified
// against a single declared expectation (parse vs reject) and each
// (tool, suite) pair produces ONE snapshot file:
//
//   tests/coverage/snapshots/parser_test262.snap        ← ES2025 spec gate
//   tests/coverage/snapshots/parser_babel.snap          ← babel corpus
//   tests/coverage/snapshots/parser_typescript.snap     ← TS corpus
//   tests/coverage/snapshots/parser_estree.snap         ← ESTree shape
//   tests/coverage/snapshots/parser_misc.snap           ← regression museum
//
//   semantic_*.snap                                     ← same files, with
//                                                         pass-3 enabled
//
// The snap files are committed; the gate is "run produces no diff vs
// committed snap". Bug-fix workflow:
//
//   1. Add a fixture under tests/coverage/misc/pass/ or .../fail/.
//   2. Run `task test:coverage` — fails because the new fixture's outcome
//      isn't in the committed snap.
//   3. Fix the parser.
//   4. `task test:coverage:update` — regenerates the snap.
//   5. Commit the parser fix + the new fixture + the snap diff. One PR.
//
// Architecture lifted from OXC:
//
//   load.odin       — walk_and_read shared by every suite
//   babel.odin      — determine_should_fail + skip lists
//   typescript.odin — `// @filename:` directive parser, error-code rules
//   test262.odin    — frontmatter (negative.phase, flags, features)
//   misc.odin       — misc/{pass,fail} regression suite
//   estree.odin     — acorn-jsx pass/fail
//   snapshot.odin   — render + diff
//   coverage_test.odin — @test wrappers (one per (tool, suite) pair)
//   main.odin       — standalone CLI: bin/kessel_coverage
//
// On parallelism: under `odin test` the @test procs run in parallel
// (one per core) thanks to Odin's testing pool. Inside each test the
// per-fixture loop is sequential. The standalone binary uses
// `core:thread.Pool` for inner parallelism and gets full machine usage
// (mirrors OXC's rayon default).
package coverage

import "core:strings"
import "core:time"

import kessel "../../../src"

// ============================================================================
// Suite identity
// ============================================================================

Suite :: enum {
	Test262,
	Babel,
	TypeScript,
	Estree,
	Misc,
}

suite_name :: proc(s: Suite) -> string {
	switch s {
	case .Test262:    return "test262"
	case .Babel:      return "babel"
	case .TypeScript: return "typescript"
	case .Estree:     return "estree"
	case .Misc:       return "misc"
	}
	return "unknown"
}

// Tool identity — currently parser + semantic. Codegen / formatter / etc.
// could land later if we ship the corresponding passes.
Tool :: enum {
	Parser,
	Semantic,
}

tool_name :: proc(t: Tool) -> string {
	switch t {
	case .Parser:   return "parser"
	case .Semantic: return "semantic"
	}
	return "unknown"
}

// Snapshot file basename: `parser_<suite>` / `semantic_<suite>` (matches
// OXC's `parser_babel.snap`, `parser_typescript.snap`, ...).
snap_basename :: proc(t: Tool, s: Suite, allocator := context.allocator) -> string {
	return strings.concatenate({tool_name(t), "_", suite_name(s)}, allocator)
}

// ============================================================================
// Fixture — one source file (post-discovery, pre-run)
// ============================================================================
//
// Suite-specific metadata stays in suite-private structs (see babel.odin /
// test262.odin / typescript.odin). The Fixture type is the lowest common
// denominator the runner needs:
//
//   * path:        absolute on-disk path (used for diagnostics + snap entry)
//   * rel:         vendor-relative path ("babel/.../foo/input.js") used in
//                  snap entries; matches OXC's `tasks/coverage/<rel>` line
//   * code:        source bytes (UTF-8 with BOM stripped); owned
//   * source_type: optional kessel SourceType override for parse_job;
//                  nil means unambiguous auto-detection.
//   * lang:        kessel Lang (JS / JSX / TS / TSX)
//   * force_strict: run the parser with strict mode enabled from byte 0
//   * source_is_dts: optional .d.ts ambient-mode override for virtual files
//   * should_fail: declared-by-fixture expectation
//   * suite:       which suite this fixture belongs to (drives snap routing)

Fixture :: struct {
	path:          string,
	rel:           string,
	code:          string,
	source_type:   Maybe(kessel.SourceType),
	lang:          kessel.Lang,
	force_strict:  bool,
	source_is_dts: Maybe(bool),
	is_commonjs:   Maybe(bool),  // override for inline sources whose path is synthetic

	// Babel `disallowAmbiguousJSXLike` — reject `<T>x` assertions and
	// `<T>() => ...` generic arrows without trailing comma / extends.
	disallow_ambiguous_jsx_like: bool,

	should_fail:   bool,
	suite:         Suite,
}

// ============================================================================
// TestResult — verdict for one fixture after the runner has executed
// ============================================================================
//
// Mirrors `oxc_coverage::TestResult` (`tasks/coverage/src/lib.rs`).
//
//   Passed              — parser accepted, fixture expects pass            ✅
//   CorrectError        — parser rejected, fixture expects fail            ✅
//   IncorrectlyPassed   — parser accepted, fixture expects fail            ❌
//   ParseError          — parser rejected, fixture expects pass            ❌
//   Mismatch            — AST / token-shape diff (deep-walker, future use) ❌
//   GenericError        — runner-level failure (read error, panic, etc.)   ❌
//
// `CorrectError` carries the diagnostic text so the snap file can record
// negative-test outputs (matches OXC's `parser_test262.snap` shape).
TestResult_Tag :: enum {
	Passed,
	CorrectError,
	IncorrectlyPassed,
	ParseError,
	Mismatch,
	GenericError,
}

TestResult :: struct {
	tag:        TestResult_Tag,
	// Populated when tag is ParseError, CorrectError, GenericError, or
	// Mismatch. The string is allocated in the per-suite arena and lives
	// until the suite's render finishes.
	diagnostic: string,
	// Set by the panic / bounds-check signal handler. Reserved for the
	// future where we wire runner-side fault catching; today every result
	// has `panicked = false`.
	panicked:   bool,
}

result_passed :: proc(r: TestResult) -> bool {
	#partial switch r.tag {
	case .Passed:       return true
	case .CorrectError: return true
	}
	return false
}

result_parsed :: proc(r: TestResult) -> bool {
	if r.panicked { return false }
	#partial switch r.tag {
	case .Passed, .IncorrectlyPassed:
		return true
	}
	return false
}

// ============================================================================
// CoverageRecord — fixture + verdict, the unit the snap file consumes
// ============================================================================

CoverageRecord :: struct {
	rel:         string,        // vendor-relative path
	should_fail: bool,
	result:      TestResult,
}

// ============================================================================
// CoverageStats — summary numbers for one (tool, suite) pair
// ============================================================================
//
// Mirrors OXC's `CoverageStats::write_summary`. Output shape:
//
//   parser_test262 Summary:
//   AST Parsed     : N/N (100.00%)
//   Positive Passed: N/N (100.00%)
//   Negative Passed: M/M (100.00%)
//
// The first line is what publishers compare. test262 at 100/100/100 = ES2025.

CoverageStats :: struct {
	all_positives:    int,
	parsed_positives: int,
	passed_positives: int,
	all_negatives:    int,
	passed_negatives: int,
}

stats_compute :: proc(records: []CoverageRecord) -> CoverageStats {
	out: CoverageStats
	for r in records {
		if r.should_fail {
			out.all_negatives += 1
			if result_passed(r.result) { out.passed_negatives += 1 }
		} else {
			out.all_positives += 1
			if result_parsed(r.result) { out.parsed_positives += 1 }
			if result_passed(r.result) { out.passed_positives += 1 }
		}
	}
	return out
}

// ============================================================================
// CoverageRun — full output of one (tool, suite) execution
// ============================================================================

CoverageRun :: struct {
	tool:    Tool,
	suite:   Suite,
	commit:  string,            // vendored submodule SHA (blank for misc/estree)
	records: []CoverageRecord,  // sorted by rel for stable snap output
	stats:   CoverageStats,
	elapsed: time.Duration,
}
