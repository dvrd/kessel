// Misc suite — kessel's regression-fixture museum.
//
// Mirrors `oxc-project/oxc:tasks/coverage/misc/{pass,fail}/`. Every fixed
// parser bug should add one fixture under `tests/coverage/misc/pass/` (or
// `.../fail/` for must-reject cases) named `kessel-NN-<slug>.<ext>` (or
// any descriptive name — the snap pins the exact file).
//
// The initial 200 fixtures are lifted from OXC's tasks/coverage/misc/
// verbatim (commit synced 2026-05-07). Treating OXC's regression suite as
// the seed corpus inherits years of edge-case discovery for free.
//
// Path-level skip: nothing (the directory is hand-curated).
//
// should_fail: nearest `pass`/`fail` ancestor under `tests/coverage/misc/`.
// We walk up from the fixture path so subdirectories under `pass/` and
// `fail/` (e.g. `fail/negative/truncation/...`) inherit the bucket from
// the closest `pass`/`fail` directory, not from the immediate parent.
// This lets us preserve the semantic grouping of regression families
// (truncation, numeric_literals, regex_literals, strict_mode, ...) while
// keeping a single classification axis.
//
// Lang/source_type: derived from the file extension; .ts/.tsx default to
// TS-mode, .mjs to module, .cjs/.cts to commonjs (Script). The suite is
// kessel-internal — we control naming conventions.
package coverage

import "base:runtime"
import "core:path/filepath"
import "core:strings"

import kessel "../../../src"

// Misc lives inside the kessel project repo (not vendor/), so the path
// shape passed to load_misc differs from the other suites: caller passes
// the absolute kessel root, we look under `tests/coverage/misc/`.
MISC_PROJECT_SUBPATH :: "tests/coverage/misc"

misc_skip_path :: proc(abs_path: string) -> bool {
	// Allow only source extensions; the directory is hand-curated so we
	// rarely have stragglers, but be defensive.
	switch filepath.ext(abs_path) {
	case ".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx", ".cts", ".mts":
		return false
	}
	return true
}

load_misc :: proc(project_root: string, allocator: runtime.Allocator) -> []Fixture {
	files := walk_and_read(project_root, MISC_PROJECT_SUBPATH, misc_skip_path, allocator)
	out := make([dynamic]Fixture, 0, len(files), allocator)

	for f in files {
		should_fail := resolve_misc_should_fail(f.abs, allocator)

		lang := resolve_misc_lang(f.abs)
		st   := resolve_misc_source_type(f.abs)

		// For .cjs FAIL fixtures, explicitly set is_commonjs = false so
		// the parser enforces script-mode restrictions (no ESM syntax).
		// PASS fixtures keep is_commonjs = nil so CJS allowances (e.g.
		// top-level return, new.target) are honoured via path detection.
		cjs: Maybe(bool)
		if strings.has_suffix(f.abs, ".cjs") && should_fail {
			cjs = false
		}

		append(&out, Fixture{
			path        = f.abs,
			rel         = f.rel,
			code        = f.code,
			source_type = st,
			lang        = lang,
			is_commonjs = cjs,
			should_fail = should_fail,
			suite       = .Misc,
		})
	}

	return out[:]
}

// Walk up from the fixture path looking for the nearest ancestor whose
// basename is `pass` or `fail`. Returns true on `fail`, false on `pass`,
// false on neither (defensive default — every fixture under
// `tests/coverage/misc/` is reachable through one of the two buckets).
//
// Memory note: `filepath.dir` is `os.dir` which returns a SLICE of the
// input string — not a heap allocation. Calling `delete` on its result
// crashes the heap (`pointer being freed was not allocated`). This
// resolver walks the path by sliding an offset into the original input
// string, allocating nothing and deleting nothing, which is also faster
// than the clone-per-level approach.
@(private="file")
resolve_misc_should_fail :: proc(path: string, allocator: runtime.Allocator) -> bool {
	// Start at the directory containing `path`. `filepath.dir` returns
	// a slice into `path`, so `cur` aliases the caller's string and we
	// must NOT free it.
	cur := filepath.dir(path)

	for cur != "." && cur != "/" && cur != "" {
		base := filepath.base(cur)
		switch base {
		case "fail": return true
		case "pass": return false
		}
		parent := filepath.dir(cur)
		if parent == cur { break }
		cur = parent
	}
	return false
}

@(private="file")
resolve_misc_lang :: proc(path: string) -> kessel.Lang {
	switch filepath.ext(path) {
	case ".tsx":                     return .TSX
	case ".ts", ".cts", ".mts":      return .TS
	case ".jsx":                     return .JSX
	case ".js", ".cjs", ".mjs":
		// JSX accepted in plain JS to mirror kessel's legacy default
		// (matches babel suite resolver).
		return .JSX
	}
	return .JSX
}

@(private="file")
resolve_misc_source_type :: proc(path: string) -> Maybe(kessel.SourceType) {
	if strings.has_suffix(path, ".mjs") || strings.has_suffix(path, ".mts") {
		return .Module
	}
	if strings.has_suffix(path, ".cjs") || strings.has_suffix(path, ".cts") {
		return .Script
	}
	// Default: nil so Kessel auto-promotes to Module on encountering
	// import/export per ECMA-262 §16.6 unambiguous-mode.
	return nil
}
