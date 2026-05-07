// Standalone CLI entry for the coverage harness.
//
//   bin/kessel_coverage parser                     — run all suites
//   bin/kessel_coverage parser --filter <substr>   — only matching fixtures
//   bin/kessel_coverage parser --update            — regenerate snaps
//   bin/kessel_coverage all                        — parser + semantic
//
// Mirrors the command shape of `oxc-project/oxc:tasks/coverage/src/main.rs`.
// Inner parallelism uses `core:thread.Pool` for full machine usage; the
// `core:testing` wrapper in coverage_test.odin uses sequential per-fixture
// execution and relies on outer @test parallelism instead.
//
// PHASE 1 STATUS: skeleton only — the suite runners are not wired yet.
// Running this binary today prints the package banner and exits.
package coverage

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:time"

main :: proc() {
	args := os.args
	if len(args) < 2 {
		fmt.println("kessel_coverage — OXC-style conformance harness")
		fmt.println("")
		fmt.println("Usage:")
		fmt.println("  kessel_coverage parser   [--filter <substr>] [--update]")
		fmt.println("  kessel_coverage semantic [--filter <substr>] [--update]")
		fmt.println("  kessel_coverage all      [--filter <substr>] [--update]")
		fmt.println("  kessel_coverage discover                          # phase 1 smoke")
		fmt.println("")
		fmt.println("Phase 1: discovery + classifier wiring in progress.")
		os.exit(0)
	}
	command := args[1]
	switch command {
	case "discover": cmd_discover()
	case "parser":   fmt.println("[parser]    not yet wired — phase 7 lands the runner")
	case "semantic": fmt.println("[semantic]  not yet wired — phase 11 lands the runner")
	case "all":      fmt.println("[all]       not yet wired — phase 7 / 11 land the runners")
	case:
		fmt.printfln("unknown command: %s", command)
		os.exit(1)
	}
}

// cmd_discover — phase 1 smoke. Walks every vendored corpus root with NO
// suite-specific skip predicates and prints how many files we found per
// root. This validates `walk_and_read` end-to-end before we layer skip
// lists / classifiers on top.
cmd_discover :: proc() {
	root := find_kessel_root()
	vendor, _ := filepath.join({root, "vendor"}, context.allocator)
	defer delete(vendor)

	fmt.printfln("[coverage] vendor root: %s", vendor)
	fmt.println("")

	probe :: proc(vendor_root, sub, label: string) {
		t0 := time.now()
		files := walk_and_read(vendor_root, sub, nil, context.allocator)
		dt := time.since(t0)
		fmt.printfln("%-15s %5d files  (%v)", label, len(files), dt)
	}

	probe(vendor, "test262/test",                              "test262")
	probe(vendor, "babel/packages/babel-parser/test/fixtures", "babel")
	probe(vendor, "typescript/tests/cases",                    "typescript")
	probe(vendor, "estree-conformance/tests/acorn-jsx",        "estree")
}

// Walk parents of cwd looking for the kessel project marker (`Taskfile.yml`).
// The standalone binary is invoked from many places (bin/kessel_coverage,
// odin run tests/coverage/src, ...) so we resolve relative to the project
// root rather than cwd.
find_kessel_root :: proc() -> string {
	cwd, cwd_err := os.get_working_directory(context.temp_allocator)
	if cwd_err != nil { return "." }
	dir := cwd
	for {
		taskfile, _ := filepath.join({dir, "Taskfile.yml"}, context.temp_allocator)
		if os.exists(taskfile) {
			return dir
		}
		parent := filepath.dir(dir, context.temp_allocator)
		if parent == dir { break }
		dir = parent
	}
	return cwd
}
