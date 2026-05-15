// snapshot.odin — render a `CoverageRun` as a `.snap` file and diff
// against the committed golden.
//
// Mirrors the snap format used by `oxc-project/oxc:tasks/coverage/snapshots/`
// to keep our numbers visually comparable to OXC's published conformance.
//
// Format (matches `parser_misc.snap`, `parser_babel.snap`, ...):
//
//   commit: <SHA>                          ← only for vendored suites
//
//   <tool>_<suite> Summary:
//   AST Parsed     : <n>/<N> (<pct>%)
//   Positive Passed: <n>/<N> (<pct>%)
//   Negative Passed: <n>/<N> (<pct>%)     ← omitted when N == 0
//
//   Expect Syntax Error: <rel>            ← failed negatives (IncorrectlyPassed)
//
//   Expect to Parse: <rel>                ← failed positives (ParseError)
//   <diagnostic>
//
//   <correct-error diagnostics, sorted>   ← negatives that fired correctly,
//                                           recorded for stable diff review
//
// Workflow:
//   * `bin/kessel_coverage run <suite>`            — print summary to stdout
//   * `bin/kessel_coverage run <suite> --update`   — write snap file
//   * `bin/kessel_coverage run <suite>` and the snap exists — also diff;
//     non-zero exit code if drift.
package coverage

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// ============================================================================
// Per-suite vendored SHA — populated from tests/runners/oxc_corpus_fetch.sh.
// Re-baseline: when bumping a vendored corpus, update both the SHA constant
// AND the snap header (the harness writes the SHA into the file).
// ============================================================================

// Synchronized with tests/runners/oxc_corpus_fetch.sh — bump together.
TYPESCRIPT_SHA          :: "f350b52331494b68c90ab02e2b6d0828d2a22a74"
BABEL_SHA               :: "4079bcda153cafc76f76d2b683aa0ede0a93864c"
ESTREE_CONFORMANCE_SHA  :: "9c67f5e33f7a2d122e87d9b8f6eec5f53861cc53"

suite_vendored_sha :: proc(s: Suite) -> string {
	switch s {
	case .Test262:    return OXC_TEST262_SHA
	case .Babel:      return BABEL_SHA
	case .TypeScript: return TYPESCRIPT_SHA
	case .Estree:     return ESTREE_CONFORMANCE_SHA
	case .Misc:       return ""  // misc is in-tree, no vendored SHA
	}
	return ""
}

// ============================================================================
// Render a CoverageRun to a snap-format string
// ============================================================================

render_snap :: proc(run: CoverageRun, allocator: runtime.Allocator) -> string {
	buf := strings.builder_make(allocator)
	w := strings.to_writer(&buf)

	// Header
	if sha := suite_vendored_sha(run.suite); sha != "" {
		fmt.wprintfln(w, "commit: %s", sha[:8])
		fmt.wprintln(w, "")
	}

	// Summary (matches OXC's `CoverageStats::write_summary` exactly).
	fmt.wprintfln(w, "%s_%s Summary:", tool_name(run.tool), suite_name(run.suite))
	fmt.wprintfln(w, "AST Parsed     : %s", format_count_pct(run.stats.parsed_positives, run.stats.all_positives))
	fmt.wprintfln(w, "Positive Passed: %s", format_count_pct(run.stats.passed_positives, run.stats.all_positives))
	if run.stats.all_negatives > 0 {
		fmt.wprintfln(w, "Negative Passed: %s", format_count_pct(run.stats.passed_negatives, run.stats.all_negatives))
	}

	// Failed negatives — fixtures that should fail but parser accepted.
	failed_negs := filter_records(run.records, proc(r: CoverageRecord) -> bool {
		return r.should_fail && r.result.tag == .IncorrectlyPassed
	}, allocator)
	for r in failed_negs {
		fmt.wprintfln(w, "Expect Syntax Error: %s", format_snap_path(run.suite, r.rel))
	}

	// Failed positives — fixtures that should parse but parser rejected.
	// Includes the diagnostic body so reviewers can see what broke.
	failed_pos := filter_records(run.records, proc(r: CoverageRecord) -> bool {
		return !r.should_fail && r.result.tag == .ParseError
	}, allocator)
	for r in failed_pos {
		label := r.result.panicked ? "Panicked" : "Expect to Parse"
		fmt.wprintfln(w, "%s: %s", label, format_snap_path(run.suite, r.rel))
		if len(r.result.diagnostic) > 0 {
			fmt.wprintln(w, r.result.diagnostic)
			fmt.wprintln(w, "")
		}
	}

	// Generic errors (runner panics, read failures, etc.).
	gen_errs := filter_records(run.records, proc(r: CoverageRecord) -> bool {
		return r.result.tag == .GenericError
	}, allocator)
	for r in gen_errs {
		fmt.wprintfln(w, "GenericError: %s", format_snap_path(run.suite, r.rel))
		if len(r.result.diagnostic) > 0 {
			fmt.wprintln(w, r.result.diagnostic)
			fmt.wprintln(w, "")
		}
	}

	// CorrectError diagnostics — negatives that fired correctly. Recording
	// them in the snap pins the exact diagnostic surface; phrasing changes
	// surface as snap drift even when the verdict is unchanged.
	corr_errs := filter_records(run.records, proc(r: CoverageRecord) -> bool {
		return r.should_fail && r.result.tag == .CorrectError && len(r.result.diagnostic) > 0
	}, allocator)
	for r in corr_errs {
		fmt.wprintln(w, r.result.diagnostic)
	}

	return strings.to_string(buf)
}

// suite_root_label — the prefix OXC uses on each `Expect to Parse:` /
// `Expect Syntax Error:` line. Vendored fixtures live under
// `tasks/coverage/<vendor-relative-path>`; the per-fixture `rel` already
// includes the suite subpath (e.g. `babel/.../input.js`), so we only
// prepend `tasks/coverage` here. Misc lives in-tree and the rel already
// starts with `tests/coverage/misc/...` so we emit nothing.
@(private="file")
suite_root_label :: proc(s: Suite) -> string {
	switch s {
	case .Test262, .Babel, .TypeScript, .Estree:
		return "tasks/coverage"
	case .Misc:
		return ""
	}
	return ""
}

// Format a snap-file fixture path. Combines suite_root_label with the
// per-fixture rel; collapses the leading `/` for misc.
@(private="file")
format_snap_path :: proc(s: Suite, rel: string) -> string {
	label := suite_root_label(s)
	if label == "" { return rel }
	return fmt.tprintf("%s/%s", label, rel)
}

@(private="file")
filter_records :: proc(
	records: []CoverageRecord,
	pred:    proc(r: CoverageRecord) -> bool,
	allocator: runtime.Allocator,
) -> []CoverageRecord {
	out := make([dynamic]CoverageRecord, 0, 8, allocator)
	for r in records { if pred(r) { append(&out, r) } }
	sorted := out[:]
	slice.sort_by(sorted, proc(a, b: CoverageRecord) -> bool { return a.rel < b.rel })
	return sorted
}

@(private="file")
format_count_pct :: proc(n, d: int) -> string {
	pct := f64(0)
	if d > 0 { pct = f64(n) / f64(d) * 100 }
	return fmt.tprintf("%d/%d (%.2f%%)", n, d, pct)
}

// ============================================================================
// Snapshot file I/O
// ============================================================================

snap_file_path :: proc(project_root: string, run: CoverageRun, allocator: runtime.Allocator) -> string {
	name := strings.concatenate({tool_name(run.tool), "_", suite_name(run.suite), ".snap"}, allocator)
	path, _ := filepath.join({project_root, "tests", "coverage", "snapshots", name}, allocator)
	return path
}

write_snap :: proc(path: string, content: string) -> bool {
	// Ensure directory exists.
	dir := filepath.dir(path, context.temp_allocator)
	make_dir_all(dir)

	bytes := transmute([]u8)content
	err := os.write_entire_file(path, bytes)
	return err == nil
}

read_snap :: proc(path: string, allocator: runtime.Allocator) -> (string, bool) {
	if !os.exists(path) { return "", false }
	bytes, err := os.read_entire_file_from_path(path, allocator)
	if err != nil { return "", false }
	return string(bytes), true
}

@(private="file")
make_dir_all :: proc(path: string) {
	if os.exists(path) { return }
	parent := filepath.dir(path, context.temp_allocator)
	if parent != path { make_dir_all(parent) }
	os.make_directory(path)
}

// ============================================================================
// Diff rendering — minimal line-based diff for snap drift reports
// ============================================================================
//
// We don't import a full diff lib. The output mirrors `git diff --no-color`
// in shape (-/+ markers) but is line-based without grouping or hunks. That's
// enough for reviewers to see what changed; the snap files are committed
// so any deeper inspection lives in `git diff` proper.

snap_diff :: proc(actual, expected: string, allocator: runtime.Allocator) -> string {
	if actual == expected { return "" }

	a_lines := strings.split_lines(actual,   allocator)
	b_lines := strings.split_lines(expected, allocator)

	buf := strings.builder_make(allocator)
	w := strings.to_writer(&buf)

	// Trivial line-by-line diff with zip-shortest. For deeper alignment,
	// the user runs `git diff` against the committed snap.
	max_len := max(len(a_lines), len(b_lines))
	any_diff := false
	for i in 0 ..< max_len {
		al := i < len(a_lines) ? a_lines[i] : ""
		bl := i < len(b_lines) ? b_lines[i] : ""
		if al == bl { continue }
		any_diff = true
		fmt.wprintfln(w, "@ line %d", i + 1)
		if i < len(b_lines) { fmt.wprintfln(w, "- %s", bl) }
		if i < len(a_lines) { fmt.wprintfln(w, "+ %s", al) }
	}
	if !any_diff { return "" }
	return strings.to_string(buf)
}

// Marker import to silence unused-import warnings while phase 9 lands the
// `core:testing` wrapper that uses `os.exists` directly.
_ :: io
