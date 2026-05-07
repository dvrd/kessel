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
import "core:strings"
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
	case "discover":   cmd_discover()
	case "babel":      cmd_babel_smoke()
	case "typescript": cmd_typescript_smoke()
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

// cmd_babel_smoke — phase 2 smoke. Walks the babel corpus with the
// real `babel_skip_path` predicate, applies plugin-level skips, runs
// `determine_should_fail` for every survivor, and prints summary counts
// without invoking the parser.
cmd_babel_smoke :: proc() {
	root := find_kessel_root()
	vendor, _ := filepath.join({root, "vendor"}, context.allocator)
	defer delete(vendor)

	t0 := time.now()
	fixtures := load_babel(vendor, context.allocator)
	dt := time.since(t0)

	n_pos, n_neg := 0, 0
	n_ts, n_tsx, n_js, n_jsx := 0, 0, 0, 0
	for f in fixtures {
		if f.should_fail { n_neg += 1 } else { n_pos += 1 }
		switch f.lang {
		case .TS:  n_ts  += 1
		case .TSX: n_tsx += 1
		case .JS:  n_js  += 1
		case .JSX: n_jsx += 1
		}
	}

	fmt.printfln("[babel] discovered %d fixtures in %v", len(fixtures), dt)
	fmt.printfln("        positives (should-pass): %d", n_pos)
	fmt.printfln("        negatives (should-fail): %d", n_neg)
	fmt.printfln("        lang: TS=%d TSX=%d JS=%d JSX=%d", n_ts, n_tsx, n_js, n_jsx)
}

// cmd_typescript_smoke — phase 3 smoke. Walks the typescript corpus,
// applies path skip + unit-splitting + error-code exclusion, prints
// summary counts. No parser invocation yet.
cmd_typescript_smoke :: proc() {
	root := find_kessel_root()
	vendor, _ := filepath.join({root, "vendor"}, context.allocator)
	defer delete(vendor)

	t0 := time.now()
	fixtures := load_typescript(vendor, context.allocator)
	dt := time.since(t0)

	n_pos, n_neg := 0, 0
	n_ts, n_tsx, n_js, n_jsx := 0, 0, 0, 0
	n_multi := 0
	for f in fixtures {
		if f.should_fail { n_neg += 1 } else { n_pos += 1 }
		switch f.lang {
		case .TS:  n_ts  += 1
		case .TSX: n_tsx += 1
		case .JS:  n_js  += 1
		case .JSX: n_jsx += 1
		}
		if strings.contains(f.rel, "::") { n_multi += 1 }
	}

	fmt.printfln("[typescript] discovered %d units in %v", len(fixtures), dt)
	fmt.printfln("             positives (should-pass): %d", n_pos)
	fmt.printfln("             negatives (should-fail): %d", n_neg)
	fmt.printfln("             lang: TS=%d TSX=%d JS=%d JSX=%d", n_ts, n_tsx, n_js, n_jsx)
	fmt.printfln("             multi-file units: %d", n_multi)
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
