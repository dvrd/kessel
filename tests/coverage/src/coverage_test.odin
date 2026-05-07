// `core:testing` integration.
//
// The test runner gives us automatic parallelism: each `@(test)` proc
// is a task in Odin's pool, sized to `os.get_processor_core_count()`.
// We register one test per (tool, suite) pair = 10 tests total.
//
// Each test:
//   1. Runs its suite end-to-end (sequential per-fixture inside).
//   2. Renders the result as a .snap-format string.
//   3. Compares against the committed `tests/coverage/snapshots/*.snap`.
//   4. `testing.errorf` on drift; the diff goes through the test's
//      logger so it shows up in `odin test` output.
//
// First-run-wins behavior is the same as the standalone CLI: if no
// snap file exists yet, we write it and succeed. CI must commit the
// initial baseline before this gate becomes meaningful.
//
// Run with:
//
//   odin test tests/coverage/src
//
// Or filtered:
//
//   odin test tests/coverage/src -define:ODIN_TEST_NAMES=test_parser_test262
package coverage

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

// ============================================================================
// Parser-side tests (5)
// ============================================================================

@(test)
test_parser_misc :: proc(t: ^testing.T) {
	run_snap_test(t, .Parser, .Misc)
}

@(test)
test_parser_estree :: proc(t: ^testing.T) {
	run_snap_test(t, .Parser, .Estree)
}

@(test)
test_parser_babel :: proc(t: ^testing.T) {
	run_snap_test(t, .Parser, .Babel)
}

@(test)
test_parser_typescript :: proc(t: ^testing.T) {
	run_snap_test(t, .Parser, .TypeScript)
}

@(test)
test_parser_test262 :: proc(t: ^testing.T) {
	run_snap_test(t, .Parser, .Test262)
}

// ============================================================================
// Semantic-side tests (5) — same suites, kessel pass-3 enabled
// ============================================================================

@(test)
test_semantic_misc :: proc(t: ^testing.T) {
	run_snap_test(t, .Semantic, .Misc)
}

@(test)
test_semantic_estree :: proc(t: ^testing.T) {
	run_snap_test(t, .Semantic, .Estree)
}

@(test)
test_semantic_babel :: proc(t: ^testing.T) {
	run_snap_test(t, .Semantic, .Babel)
}

@(test)
test_semantic_typescript :: proc(t: ^testing.T) {
	run_snap_test(t, .Semantic, .TypeScript)
}

@(test)
test_semantic_test262 :: proc(t: ^testing.T) {
	run_snap_test(t, .Semantic, .Test262)
}

// ============================================================================
// Shared body — discover, run, render, diff, gate
// ============================================================================

@(private="file")
run_snap_test :: proc(t: ^testing.T, tool: Tool, suite: Suite) {
	root := find_kessel_root_for_test()
	if root == "" {
		testing.expectf(t, false, "could not locate kessel project root (Taskfile.yml)")
		return
	}
	vendor, _ := filepath.join({root, "vendor"}, context.allocator)

	run := run_one_suite(suite, tool, vendor, root, context.allocator)
	actual := render_snap(run, context.allocator)

	snap_path := snap_file_path(root, run, context.allocator)

	expected, exists := read_snap(snap_path, context.allocator)
	if !exists {
		// First run: land the baseline.
		ok := write_snap(snap_path, actual)
		testing.expectf(t, ok,
			"%s_%s: failed to write initial baseline %s",
			tool_name(tool), suite_name(suite), snap_path)
		return
	}

	if actual == expected { return }

	diff := snap_diff(actual, expected, context.allocator)
	testing.expectf(t, false,
		"%s_%s snap drift\n   path: %s\n   summary: AST %d/%d  pos %d/%d  neg %d/%d\n%s\nRun `bin/kessel_coverage run %s%s --update` to accept the new state.",
		tool_name(tool), suite_name(suite),
		snap_path,
		run.stats.parsed_positives, run.stats.all_positives,
		run.stats.passed_positives, run.stats.all_positives,
		run.stats.passed_negatives, run.stats.all_negatives,
		diff,
		suite_name(suite),
		tool == .Semantic ? " --semantic" : "",
	)
}

// `@test` procs run with cwd = wherever `odin test` was invoked from.
// The `find_kessel_root` proc in main.odin uses cwd; that file's
// `main` is excluded from `odin test` builds since `main` is reserved
// for `odin build` mode. We duplicate the small helper here so the
// test path doesn't depend on main.odin's compilation.
@(private="file")
find_kessel_root_for_test :: proc() -> string {
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil { return "." }
	dir := cwd
	for {
		taskfile, _ := filepath.join({dir, "Taskfile.yml"}, context.temp_allocator)
		if os.exists(taskfile) { return dir }
		parent := filepath.dir(dir, context.temp_allocator)
		if parent == dir { break }
		dir = parent
	}
	return cwd
}

_ :: fmt
