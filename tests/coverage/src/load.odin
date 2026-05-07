// Filesystem walker shared by every suite.
//
// Mirrors `oxc-project/oxc:tasks/coverage/src/load.rs:walk_and_read`. Recursive
// walk under a vendored corpus root, applies a per-suite skip predicate, reads
// each surviving file's bytes (UTF-8, BOM stripped), and returns the
// (rel_path, bytes) pairs.
//
// Differences from OXC's version:
//   * No UTF-16LE fallback. test262 / babel / typescript / acorn-jsx / kessel-misc
//     are 100% UTF-8 in the SHAs we vendor (we'd see this immediately during
//     phase 7 if a fixture decoded badly).
//   * Sequential walk + sequential read here. Outer parallelism happens in
//     the runner (one worker per fixture, see runner.odin in phase 7).
//
// The walker uses `core:path/filepath:walker_walk` which is breadth-first;
// we sort the output by path before returning so snap files are deterministic
// regardless of OS readdir order.
package coverage

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// One on-disk file the harness will eventually run through the parser.
// Owned by the suite-level arena passed to `walk_and_read`.
LoadedFile :: struct {
	abs:  string,  // absolute path on disk
	rel:  string,  // path relative to the vendor root we walked from
	code: string,  // UTF-8 source, BOM-stripped
}

// `skip_path` returns true when the given absolute path should be excluded
// from the suite. Implementations match OXC's per-suite skip lists (see
// babel.odin / typescript.odin) — substring matches against the path string
// keep the harness reviewer-friendly.
//
// `skip_path` is called for every file during the walk; directories that
// match it are NOT pruned (the walker still descends into them and the
// predicate fires per file). For pruning whole subtrees, predicates can
// short-circuit on path prefixes — the cost is one stat per file under a
// skipped subtree, which is negligible against the parse run.
SkipPredicate :: #type proc(abs_path: string) -> bool

// Walk `vendor_subpath` (relative to `vendor_root`) and return every
// non-skipped file as a `[]LoadedFile`. The result is sorted by `rel` so
// snap files are stable across machines.
//
// `vendor_root` is the absolute path to the kessel `vendor/` directory.
// `vendor_subpath` is the per-suite root e.g.
// "babel/packages/babel-parser/test/fixtures".
//
// All allocation is performed in `allocator`; the caller owns every string
// in the returned slice. Use a single suite-scoped arena in the runner so
// the whole suite frees in one shot.
walk_and_read :: proc(
	vendor_root:    string,
	vendor_subpath: string,
	skip_path:      SkipPredicate,
	allocator:      runtime.Allocator,
) -> []LoadedFile {
	full_root, join_err := filepath.join({vendor_root, vendor_subpath}, allocator)
	if join_err != nil {
		fmt.eprintfln("[coverage] join failed for %s + %s: %v", vendor_root, vendor_subpath, join_err)
		return nil
	}

	if !is_dir(full_root) {
		fmt.eprintfln("[coverage] vendored corpus missing: %s", full_root)
		fmt.eprintfln("[coverage] run `tests/runners/oxc_corpus_fetch.sh` first.")
		return nil
	}

	w := os.walker_create(full_root)
	defer os.walker_destroy(&w)

	out := make([dynamic]LoadedFile, 0, 4096, allocator)

	for info in os.walker_walk(&w) {
		if info.type == .Directory { continue }
		if skip_path != nil && skip_path(info.fullpath) { continue }

		bytes, read_err := os.read_entire_file_from_path(info.fullpath, allocator)
		if read_err != nil { continue }

		// Strip UTF-8 BOM if present (test262 has a few BOM-prefixed fixtures).
		code_start := 0
		if len(bytes) >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
			code_start = 3
		}
		code := string(bytes[code_start:])

		// Compute path relative to `vendor_root`. Relative path = the part
		// after `vendor_root + "/"`. We keep forward slashes.
		rel := info.fullpath
		if strings.has_prefix(rel, vendor_root) {
			rel = rel[len(vendor_root):]
			if len(rel) > 0 && rel[0] == '/' { rel = rel[1:] }
		}

		// Clone path strings into the suite arena (the walker hands us
		// transient views).
		abs_clone := strings.clone(info.fullpath, allocator)
		rel_clone := strings.clone(rel, allocator)

		append(&out, LoadedFile{
			abs  = abs_clone,
			rel  = rel_clone,
			code = code,
		})
	}

	if path, err := os.walker_error(&w); err != nil {
		fmt.eprintfln("[coverage] walker error at %s: %v", path, err)
	}

	files := out[:]
	slice.sort_by(files, proc(a, b: LoadedFile) -> bool { return a.rel < b.rel })
	return files
}

@(private)
is_dir :: proc(path: string) -> bool {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil { return false }
	return info.type == .Directory
}
