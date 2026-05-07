// Estree-conformance suite — discover and classify the curated
// `oxc-project/estree-conformance` corpus.
//
// Mirrors `oxc-project/oxc:tasks/coverage/src/load.rs:load_acorn_jsx`.
// Layout: `tests/acorn-jsx/{pass,fail}/<NN>.{jsx,json,tokens.json}`.
// We only consume the `.jsx` source files; the JSON sidecars are ESTree
// AST golden files reserved for a future deep-walker comparison
// (analogous to OXC's `estree_acorn_jsx` snap).
//
// should_fail: parent dir is `fail` ⇒ true; `pass` ⇒ false.
package coverage

import "base:runtime"
import "core:path/filepath"
import "core:strings"

import kessel "../../../src"

ESTREE_SUBPATH :: "estree-conformance/tests/acorn-jsx"

estree_skip_path :: proc(abs_path: string) -> bool {
	// Only walk the .jsx source files. The .json sidecars are golden ASTs
	// that the deep-walker (future phase) will consume; they're not source
	// inputs.
	if !strings.has_suffix(abs_path, ".jsx") { return true }
	return false
}

load_estree :: proc(vendor_root: string, allocator: runtime.Allocator) -> []Fixture {
	files := walk_and_read(vendor_root, ESTREE_SUBPATH, estree_skip_path, allocator)
	out := make([dynamic]Fixture, 0, len(files), allocator)

	for f in files {
		// Parent-dir basename: `pass` or `fail`.
		dir := filepath.dir(f.abs, allocator)
		defer delete(dir, allocator)
		bucket := filepath.base(dir)

		should_fail := bucket == "fail"

		append(&out, Fixture{
			path        = f.abs,
			rel         = f.rel,
			code        = f.code,
			source_type = .Module,  // ESTree corpus is module-mode
			lang        = .JSX,
			should_fail = should_fail,
			suite       = .Estree,
		})
	}

	return out[:]
}
