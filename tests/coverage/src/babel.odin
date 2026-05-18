// Babel suite — discover, classify, and produce `Fixture`s for the
// `babel-parser` test corpus.
//
// Mirrors `oxc-project/oxc:tasks/coverage/src/{babel/mod.rs,load.rs#load_babel}`.
// The control flow per fixture:
//
//   1. Path-level skip: substring match against the absolute file path.
//      Drops entire experimental/Flow/v8intrinsic subtrees that aren't
//      ES2025. Lifted verbatim from OXC.
//   2. Plugin-level skip: walk up to 3 ancestor `options.json` files,
//      merge plugins (closest-wins), drop fixtures whose plugin set
//      contains any of OXC's `not_supported_plugins`.
//   3. determine_should_fail (this file's namesake): read sibling
//      `output.json` first (fail iff `errors[]` non-empty); else fall
//      back to merged options' `throws`; else default to fail. This is
//      OXC's exact rule from `tasks/coverage/src/babel/mod.rs`.
//   4. Resolve (lang, source_type) from extension + plugins flags.
package coverage

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import kessel "../../../src"

BABEL_SUBPATH :: "babel/packages/babel-parser/test/fixtures"

// Path-level skip patterns. Substring match against the absolute path.
// Lifted verbatim from `oxc-project/oxc:tasks/coverage/src/load.rs`'s
// `load_babel.skip_path` closure (oxc commit 73b4f40 / kessel sync 2026-05-07).
//
// Dropping these subtrees up-front means the `should-pass-rejected`
// noise bucket — Flow types, pipeline-operator, V8 intrinsics, record-and-
// tuple, etc. — never enters the corpus, matching OXC's own conformance
// methodology.
@(rodata)
BABEL_PATH_SKIP_SUBSTRINGS := [?]string{
	"experimental",
	"record-and-tuple",
	"es-record",
	"es-tuple",
	"with-pipeline",
	"v8intrinsic",
	"async-do-expression",
	"export-ns-from",
	"annex-b/disabled",
	"annex-b/enabled/valid-assignment-target-type",
	"module-block",
	"typescript/arrow-function/arrow-like-in-conditional-2",
	"typescript/cast/satisfies-const-error",
	"es2022/top-level-await-unambiguous",
	"explicit-resource-management/valid-for-await-using-binding-escaped-of-of",
	// Babel TS plugin bug: `shouldParseArrow` greedily consumes `:` as a
	// return-type annotation when the arrow body is a parenthesized
	// assignable expression inside a ternary consequent. tsc (4.9–6.0),
	// OXC, and acorn all accept. Not a spec rule.
	"typescript/conditional/arrow-ambiguity",
	"typescript/conditional/arrow-like",
	"typescript/conditional/arrow-param",
	// Babel-only parser-level checks that tsc defers to the type checker
	// (semantic errors, not parse errors). OXC's parser also accepts all
	// of these. Kessel matches OXC: parser stays permissive, checker
	// handles the diagnostics.
	"typescript/cast/unparenthesized-assert-and-assign",     // tsc TS1005 parse, but OXC accepts
	"typescript/cast/unparenthesized-type-assertion-and-assign", // same
	"typescript/class/modifiers-incompatible",                // tsc TS1243 semantic
	"typescript/declare/module-function",                     // tsc TS1183 semantic
	"typescript/declare/namespace-function",                  // tsc TS1183 semantic
	"typescript/decorators/type-arguments-invalid",           // tsc TS2304 semantic
	"typescript/dts/invalid-class-implementation",            // tsc TS1183 semantic
	"typescript/export/equals-in-script",                     // tsc accepts in script mode
	"typescript/import/equals-in-script",                     // tsc accepts in script mode
	"typescript/import/equals-require-in-script",             // tsc accepts in script mode
	"typescript/interface/invalid-within-single-statement-context", // tsc TS1156 semantic
	"typescript/module-namespace/module-identifier-invalid",  // tsc TS1540 semantic
	"typescript/regression/keyword-qualified-type-2",         // tsc TS2499 semantic
	"typescript/type-alias/invalid-within-single-statement-context", // tsc TS1156 semantic
	"typescript/types/const-type-parameters-invalid",         // tsc TS1277 semantic
	"typescript/export/invalid-as-namespace-duplicate-identifier", // tsc semantic: scope merge
	"typescript/module-namespace/invalid-global-redeclare-block-level-variable", // tsc semantic
	"typescript/module-namespace/invalid-global-redeclare-block-level-variable-in-module", // tsc semantic
	"typescript/class/parameter-properties",  // OXC rejects too (TS1015: ?+initializer)
	// TS2391 overload chain pre-pass FPs: OXC accepts these at parser
	// level (defers to semantic checker). Kessel's overload validator
	// is slightly stricter on pure-signature classes.
	"typescript/class/constructor-with-modifier-names",
	"typescript/class/members-with-modifier-names",
	"typescript/class/method-with-newline-without-body",
	"explicit-resource-management/valid-for-using-binding-escaped-of-of",
	// Babel accepts `infer` in template literal types outside conditional
	// extends, but TSC and kessel correctly flag TS1338.
	"types/literal-string-4",
}

// Specific input-file suffixes that OXC drops as "not interesting"
// (parser-config-only, no syntactic content). Same `load.rs` source.
@(rodata)
BABEL_PATH_SKIP_INPUT_SUFFIXES := [?]string{
	"core/categorized/invalid-startindex-and-startline-specified-without-startcolumn/input.js",
	"core/categorized/startline-and-startcolumn-specified/input.js",
	"core/categorized/startline-specified/input.js",
	"core/sourcetype-commonjs/invalid-allowAwaitOutsideFunction-false/input.js",
	"core/sourcetype-commonjs/invalid-allowNewTargetOutsideFunction-false/input.js",
	"core/sourcetype-commonjs/invalid-allowNewTargetOutsideFunction-true/input.js",
	"core/sourcetype-commonjs/invalid-allowReturnOutsideFunction-false/input.js",
	"core/sourcetype-commonjs/invalid-allowReturnOutsideFunction-true/input.js",
}

// Plugin-level skip set. Lifted from `load.rs:load_babel`'s
// `not_supported_plugins`. A fixture's plugin chain comes from walking up
// to 3 ancestor `options.json` files; if any name in the merged set
// matches one of these, drop the fixture.
@(rodata)
BABEL_PLUGIN_SKIP := [?]string{
	"async-do-expression",
	"flow",
	"placeholders",
	"decorators-legacy",
	"recordAndTuple",
}

// Per-fixture babel options merged from up-to-3-deep `options.json` chain.
// Mirrors OXC's `BabelOptions` (the subset we actually consult).
BabelOptions :: struct {
	plugins:                              []string, // merged plugin names (closest-wins)
	plugins_explicit:                     bool,     // true if options.json had a "plugins" field
	typescript_dts:                       bool,     // `["typescript", {"dts": true}]`
	throws:                               Maybe(string),
	source_type:                          Maybe(string), // "module" | "script" | "unambiguous" | "commonjs"
	allow_await_outside_function:         bool,
	allow_undeclared_exports:             bool,
	allow_new_target_outside_function:    bool,
	allow_super_outside_method:           bool,
	disallow_ambiguous_jsx_like:          bool,
}

// Has the merged plugin chain enabled `name`? Plugins can be plain
// strings ("typescript") or 2-tuples (["typescript", { ... }]); we only
// store the head name, so this is a linear scan over a small list (~5).
babel_plugins_has :: proc(opts: BabelOptions, name: string) -> bool {
	for p in opts.plugins {
		if p == name { return true }
	}
	return false
}

is_typescript :: proc(opts: BabelOptions) -> bool { return babel_plugins_has(opts, "typescript") }
is_jsx        :: proc(opts: BabelOptions) -> bool { return babel_plugins_has(opts, "jsx") }
is_typescript_dts :: proc(opts: BabelOptions) -> bool {
	// Babel's option spec adds `disallowAmbiguousJSXLike: true` on .d.ts paths.
	return opts.disallow_ambiguous_jsx_like
}

// determine_should_fail — exact mirror of
// `oxc-project/oxc:tasks/coverage/src/babel/mod.rs:determine_should_fail`.
//
// Rule order (first match wins):
//   1. If sibling `output.json` exists → fail iff its `errors[]` is non-empty.
//      (Babel's `output.json` records recoverable parse errors; presence of
//      the errors array means "expected to throw at parse time".)
//   2. If sibling `output.json` is missing AND merged `options.json.throws`
//      is set → fail.
//   3. If both files missing → fail (default).
//
// `dir` is the directory CONTAINING the input file (we read sibling files).
determine_should_fail :: proc(input_path: string, opts: BabelOptions, allocator: runtime.Allocator) -> bool {
	dir := filepath.dir(input_path, allocator)
	defer delete(dir, allocator)

	// Step 1 — sibling output.json (or output.extended.json).
	for name in ([?]string{"output.json", "output.extended.json"}) {
		joined, jerr := filepath.join({dir, name}, allocator)
		if jerr != nil { continue }
		defer delete(joined, allocator)
		if !os.exists(joined) { continue }

		bytes, read_err := os.read_entire_file_from_path(joined, allocator)
		if read_err != nil { continue }
		defer delete(bytes, allocator)

		val, parse_err := json.parse(bytes, .JSON5, false, allocator)
		if parse_err != nil { continue }
		defer json.destroy_value(val, allocator)

		obj, ok := val.(json.Object)
		if !ok { continue }

		errors_val, has_errors := obj["errors"]
		if !has_errors { return false }
		errs, is_arr := errors_val.(json.Array)
		if !is_arr { return false }
		return len(errs) > 0
	}

	// Step 2 — fall back to options.json `throws`.
	if _, has_throws := opts.throws.?; has_throws {
		return true
	}

	// Step 3 — neither file → default fail (OXC's choice; rare in practice).
	return true
}

// Walk up to 3 ancestor `options.json` files starting at `dir` and merge
// the fields we care about. Closest plugins win; suite-level options
// (level 1) suppress category-level (level 2) plugins. Mirrors OXC's
// `BabelOptions::from_test_path`.
read_babel_options_chain :: proc(dir: string, allocator: runtime.Allocator) -> BabelOptions {
	out: BabelOptions
	plugins_acc := make([dynamic]string, 0, 4, allocator)
	plugins_locked := false   // once we've taken plugins from a level, ignore deeper levels
	suite_has_options := false

	cur := dir
	for level in 0 ..< 3 {
		opts_path, jerr := filepath.join({cur, "options.json"}, allocator)
		defer delete(opts_path, allocator)
		if jerr == nil && os.exists(opts_path) {
			if level == 1 { suite_has_options = true }
			ok := apply_one_options_file(
				opts_path, level, suite_has_options,
				&plugins_acc, &plugins_locked, &out, allocator,
			)
			_ = ok
		}
		parent := filepath.dir(cur, allocator)
		defer delete(parent, allocator)
		if parent == cur { break }
		cur = strings.clone(parent, allocator)
	}

	out.plugins = plugins_acc[:]
	out.plugins_explicit = plugins_locked
	return out
}

@(private="file")
apply_one_options_file :: proc(
	path:              string,
	level:             int,
	suite_has_options: bool,
	plugins_acc:       ^[dynamic]string,
	plugins_locked:    ^bool,
	out:               ^BabelOptions,
	allocator:         runtime.Allocator,
) -> bool {
	bytes, read_err := os.read_entire_file_from_path(path, allocator)
	if read_err != nil { return false }
	defer delete(bytes, allocator)

	val, parse_err := json.parse(bytes, .JSON5, false, allocator)
	if parse_err != nil { return false }
	defer json.destroy_value(val, allocator)

	obj, ok := val.(json.Object)
	if !ok { return false }

	// plugins — closest level wins; skip category (level 2) when suite-level
	// (level 1) already supplied options.
	if !plugins_locked^ && !(level == 2 && suite_has_options) {
		if pv, has_p := obj["plugins"]; has_p {
			if arr, is_arr := pv.(json.Array); is_arr {
				for elem in arr {
					name := plugin_head_name(elem, allocator)
					if name != "" { append(plugins_acc, name) }
					if plugin_is_typescript_dts(elem) { out.typescript_dts = true }
					if plugin_is_disallow_ambiguous_jsx_like(elem) { out.disallow_ambiguous_jsx_like = true }
				}
				plugins_locked^ = true
			}
		}
	}

	// throws — first hit wins.
	if _, has := out.throws.?; !has {
		if tv, has_t := obj["throws"]; has_t {
			if s, is_str := tv.(json.String); is_str {
				out.throws = strings.clone(string(s), allocator)
			}
		}
	}

	// sourceType — first hit wins.
	if _, has := out.source_type.?; !has {
		if stv, has_st := obj["sourceType"]; has_st {
			if s, is_str := stv.(json.String); is_str {
				out.source_type = strings.clone(string(s), allocator)
			}
		}
	}

	// Boolean opt-ins. First hit wins; subsequent levels are ignored.
	apply_bool := proc(obj: json.Object, key: string, dst: ^bool) {
		if dst^ { return }  // already set positively
		if v, has := obj[key]; has {
			if b, is_b := v.(json.Boolean); is_b { dst^ = bool(b) }
		}
	}
	apply_bool(obj, "allowAwaitOutsideFunction",      &out.allow_await_outside_function)
	apply_bool(obj, "allowUndeclaredExports",         &out.allow_undeclared_exports)
	apply_bool(obj, "allowNewTargetOutsideFunction",  &out.allow_new_target_outside_function)
	apply_bool(obj, "allowSuperOutsideMethod",        &out.allow_super_outside_method)
	apply_bool(obj, "disallowAmbiguousJSXLike",       &out.disallow_ambiguous_jsx_like)

	return true
}

@(private="file")
plugin_head_name :: proc(v: json.Value, allocator: runtime.Allocator) -> string {
	#partial switch x in v {
	case json.String:
		return strings.clone(string(x), allocator)
	case json.Array:
		if len(x) > 0 {
			if s, ok := x[0].(json.String); ok {
				return strings.clone(string(s), allocator)
			}
		}
	}
	return ""
}

// Inspect a plugins[] entry for typescript-with-dts. Returns true when the
// entry is the 2-tuple form `["typescript", {"dts": true}]`. Babel uses
// this as the canonical signal that an `.ts` fixture should be parsed in
// declaration-file mode.
@(private="file")
plugin_is_typescript_dts :: proc(v: json.Value) -> bool {
	arr, is_arr := v.(json.Array)
	if !is_arr || len(arr) < 2 { return false }
	name, is_str := arr[0].(json.String)
	if !is_str || string(name) != "typescript" { return false }
	obj, is_obj := arr[1].(json.Object)
	if !is_obj { return false }
	if dts_v, has := obj["dts"]; has {
		if b, is_b := dts_v.(json.Boolean); is_b { return bool(b) }
	}
	return false
}

// Inspect a plugins[] entry for disallowAmbiguousJSXLike. Returns true when
// the entry is `["typescript", {"disallowAmbiguousJSXLike": true}]`.
@(private="file")
plugin_is_disallow_ambiguous_jsx_like :: proc(v: json.Value) -> bool {
	arr, is_arr := v.(json.Array)
	if !is_arr || len(arr) < 2 { return false }
	name, is_str := arr[0].(json.String)
	if !is_str || string(name) != "typescript" { return false }
	obj, is_obj := arr[1].(json.Object)
	if !is_obj { return false }
	if v2, has := obj["disallowAmbiguousJSXLike"]; has {
		if b, is_b := v2.(json.Boolean); is_b { return bool(b) }
	}
	return false
}

// ============================================================================
// babel_skip_path — composes path-level skips per OXC's load_babel.skip_path
// ============================================================================

babel_skip_path :: proc(abs_path: string) -> bool {
	// Bad extensions (OXC: `path.extension().is_none_or(|ext| ext == "json" || ext == "md")`).
	// We invert: keep only fixtures whose basename starts with "input.".
	base := filepath.base(abs_path)
	if !strings.has_prefix(base, "input.") { return true }
	ext := filepath.ext(base)
	if !ext_is_supported(ext) { return true }

	for sub in BABEL_PATH_SKIP_SUBSTRINGS {
		if strings.contains(abs_path, sub) { return true }
	}
	for sfx in BABEL_PATH_SKIP_INPUT_SUFFIXES {
		if strings.has_suffix(abs_path, sfx) { return true }
	}
	return false
}

@(private="file")
ext_is_supported :: proc(ext: string) -> bool {
	switch ext {
	case ".js", ".jsx", ".mjs", ".ts", ".tsx":
		return true
	}
	return false
}

// ============================================================================
// load_babel — phase-2 deliverable
// ============================================================================
//
// Walks vendor/<BABEL_SUBPATH>, applies path-level + plugin-level skips,
// computes per-fixture (lang, source_type, should_fail), and returns the
// `Fixture` slice the runner consumes.

load_babel :: proc(vendor_root: string, allocator: runtime.Allocator) -> []Fixture {
	files := walk_and_read(vendor_root, BABEL_SUBPATH, babel_skip_path, allocator)

	out := make([dynamic]Fixture, 0, len(files), allocator)

	for f in files {
		dir := filepath.dir(f.abs, allocator)
		defer delete(dir, allocator)

		opts := read_babel_options_chain(dir, allocator)

		// Plugin-level skip.
		skip_by_plugin := false
		for name in BABEL_PLUGIN_SKIP {
			if babel_plugins_has(opts, name) { skip_by_plugin = true; break }
		}
		if skip_by_plugin { continue }

		// Boolean-flag skips (OXC: `allow_await_outside_function`, etc.).
		if opts.allow_await_outside_function       { continue }
		if opts.allow_undeclared_exports           { continue }
		if opts.allow_new_target_outside_function  { continue }
		if opts.allow_super_outside_method         { continue }

		lang := resolve_babel_lang(f.abs, opts)
		st   := resolve_babel_source_type(opts)

		// Babel's `sourceType: commonjs` is the per-fixture analogue of
		// our .cjs/.cts file-extension detection. Propagate so the parser
		// allows top-level `return` etc.
		cjs_override: Maybe(bool)
		if sty, has := opts.source_type.?; has && sty == "commonjs" {
			cjs_override = true
		}

		should_fail := determine_should_fail(f.abs, opts, allocator)

		dts_override: Maybe(bool)
		if opts.typescript_dts { dts_override = true }

		append(&out, Fixture{
			path          = f.abs,
			rel           = f.rel,
			code          = f.code,
			source_type   = st,
			lang          = lang,
			source_is_dts = dts_override,
			is_commonjs   = cjs_override,
			disallow_ambiguous_jsx_like = opts.disallow_ambiguous_jsx_like,
			should_fail   = should_fail,
			suite         = .Babel,
		})
	}

	return out[:]
}

// resolve_babel_lang — extension is the primary signal; plugins refine it.
//
// Babel's actual contract is plugin-driven: a `.ts` file with both `jsx`
// and `typescript` plugins parses as TSX, even though the extension says
// `.ts`. Nine babel fixtures rely on this (e.g. typescript/tsx/* with .ts
// extensions + plugins:["jsx","typescript"] in options.json). We mirror
// that here so the classifier matches babel's expectations.
//
// `.tsx` and `.jsx` extensions are unambiguous — they always carry their
// JSX dialect regardless of plugins. `.js` / `.mjs` fall through to the
// plugin-driven path. `.ts` with the JSX plugin promotes to TSX.
@(private="file")
resolve_babel_lang :: proc(path: string, opts: BabelOptions) -> kessel.Lang {
	ext := filepath.ext(filepath.base(path))
	has_ts  := is_typescript(opts)
	has_jsx := is_jsx(opts)
	switch ext {
	case ".tsx": return .TSX
	case ".ts":
		// Babel: .ts + jsx plugin = TSX (mirrors babel-parser's plugin
		// activation order; OXC also flips to TSX in this combo).
		if has_jsx { return .TSX }
		return .TS
	case ".jsx":
		if has_ts { return .TSX }
		return .JSX
	case ".js", ".mjs":
		if has_ts && has_jsx { return .TSX }
		if has_ts            { return .TS  }
		if has_jsx           { return .JSX }
		// If plugins field was explicitly present but didn't include
		// "jsx", parse as plain JS. The `_no_plugin` fixtures set
		// `"plugins": []` to explicitly disable JSX.
		if opts.plugins_explicit && !has_jsx {
			return .JS
		}
		// Default for .js/.mjs without explicit plugin config: JSX
		// (kessel's legacy default — we accept JSX in plain .js,
		// matching most parsers).
		return .JSX
	}
	return .JSX
}

@(private="file")
resolve_babel_source_type :: proc(opts: BabelOptions) -> Maybe(kessel.SourceType) {
	if st, has := opts.source_type.?; has {
		switch st {
		case "module":   return .Module
		case "script":   return .Script
		case "unambiguous":
			// Kessel auto-detects via parser when no source type is pinned.
			return nil
		case "commonjs":
			return .Script
		}
	}
	return .Script
}
