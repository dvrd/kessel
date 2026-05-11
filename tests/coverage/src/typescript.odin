// TypeScript suite — discover, classify, and produce `Fixture`s for the
// `microsoft/TypeScript:tests/cases/{compiler,conformance}/` corpora.
//
// Mirrors `oxc-project/oxc:tasks/coverage/src/{typescript/meta.rs,
// load.rs#load_typescript}`. The control flow per fixture:
//
//   1. Path-level skip: must live under `compiler/` or `conformance/`,
//      and the basename must NOT appear in `TS_NOT_SUPPORTED_TEST_PATHS`.
//   2. Unit splitting: TSC fixtures may bundle multiple "virtual files"
//      via `// @filename: foo.ts` directives. Each unit has its own
//      basename + content; settings (target, module, jsx, etc.) come
//      from `// @<name>: <value>` directives outside any unit.
//   3. should_fail = error_codes contains any code NOT in
//      `TS_NOT_SUPPORTED_ERROR_CODES`. Error codes come from the
//      sibling baseline file at
//      `tests/baselines/reference/<basename>.errors.txt` (and its
//      compiler-option variants like `(target=es5).errors.txt`).
//
// Phase-3 scope: discovery + classification only. Each TSC fixture
// expands to N units (N >= 1); we emit one Fixture per unit but inherit
// the parent fixture's `should_fail`. The runner (phase 7) parses each
// unit independently.
package coverage

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"

import kessel "../../../src"

TYPESCRIPT_SUBPATH :: "typescript/tests/cases"
TYPESCRIPT_BASELINE_SUBPATH :: "typescript/tests/baselines/reference"

// ============================================================================
// CompilerSettings — a small subset of TSC's compiler options we read from
// `// @<name>: <value>` directives. Used to:
//   * locate variant baseline files (`(target=es5).errors.txt`)
//   * drive lang inference (jsx mode → JSX/TSX promotion)
// ============================================================================

CompilerSettings :: struct {
	modules: []string,  // "module" directive (comma-separated)
	targets: []string,  // "target"
	jsx:     []string,  // "jsx" — react / preserve / react-jsx / react-native
	preserve_const_enums:        []string,
	use_define_for_class_fields: []string,
	experimental_decorators:     []string,
	module_detection:            []string,
	strict:                      []string,  // "strict" — controls alwaysStrict
	always_strict:               []string,  // "alwaysStrict" — explicit override
}

// ============================================================================
// Path-level skip predicate
// ============================================================================

ts_skip_path :: proc(abs_path: string) -> bool {
	// Only walk `compiler/` and `conformance/` (matches OXC's load_typescript).
	supported := strings.contains(abs_path, "/conformance/") ||
	             strings.contains(abs_path, "/compiler/")
	if !supported { return true }

	// Reject anything that's not a .ts / .tsx fixture top-level. Baselines,
	// .json, .md, etc. all live outside `tests/cases/` so the supported
	// guard already handles most of those, but be defensive.
	ext := filepath.ext(abs_path)
	if ext != ".ts" && ext != ".tsx" && ext != ".cts" && ext != ".mts" {
		return true
	}

	base := filepath.base(abs_path)
	for sub in TS_NOT_SUPPORTED_TEST_PATHS {
		if base == sub { return true }
	}
	return false
}

// ============================================================================
// Per-fixture metadata extraction
// ============================================================================
//
// `// @<name>: <value>` directives can appear anywhere in the file. They
// either:
//   (a) configure the compiler for the WHOLE fixture (`@target`, `@module`,
//       `@jsx`, ...); or
//   (b) start a new "virtual file" via `@filename`.
//
// We scan once, accumulating settings + splitting at every `@filename`.
// Unit content is the lines BETWEEN directive lines (directive lines are
// not included in any unit's source).

TestUnit :: struct {
	name:    string,  // basename of this virtual file
	content: string,  // owned source bytes
}

TestCaseContent :: struct {
	units:       []TestUnit,
	settings:    CompilerSettings,
	error_codes: []string,
}

// scan_test_case parses a single TSC fixture's bytes into units + settings.
// Mirrors `oxc-project/oxc:tasks/coverage/src/typescript/meta.rs:make_units_from_test`.
scan_test_case :: proc(path: string, code: string, allocator: runtime.Allocator) -> TestCaseContent {
	options_map := make(map[string]string, 8, allocator)
	defer delete(options_map)

	units := make([dynamic]TestUnit, 0, 1, allocator)
	current_name: string
	current_content := strings.builder_make(allocator)

	flush :: proc(units: ^[dynamic]TestUnit, name: ^string, builder: ^strings.Builder, allocator: runtime.Allocator) {
		if name^ == "" && strings.builder_len(builder^) == 0 { return }
		content := strings.clone(strings.to_string(builder^), allocator)
		strings.builder_reset(builder)
		append(units, TestUnit{
			name    = name^,
			content = content,
		})
		name^ = ""
	}

	// Iterate lines. An option line matches: `^//\s*@\w+\s*:\s*<value>`.
	code_iter := code
	for line in strings.split_lines_iterator(&code_iter) {
		opt_name, opt_value, has_opt := parse_meta_option(line)
		if has_opt {
			low := strings.to_lower(opt_name, allocator)
			if low == "filename" {
				if current_name != "" || strings.builder_len(current_content) > 0 {
					flush(&units, &current_name, &current_content, allocator)
				}
				current_name = strings.clone(opt_value, allocator)
			} else {
				options_map[low] = strings.clone(opt_value, allocator)
			}
			continue
		}
		// Plain content line. Append (with newline separator).
		if strings.builder_len(current_content) > 0 {
			strings.write_byte(&current_content, '\n')
		}
		strings.write_string(&current_content, line)
	}

	// Flush final unit. Single-file fixtures hit this with current_name == ""
	// — we synthesize from the input path.
	if current_name == "" {
		current_name = strings.clone(filepath.base(path), allocator)
	}
	flush(&units, &current_name, &current_content, allocator)

	// Drop synthetic placeholder units that contain TSC's not-actually-source
	// markers. TS conformance fixtures use these to materialize a fake
	// `node_modules/<pkg>/index.js` whose body is the literal text
	// "This file is not processed." — used by the TS module-resolution
	// runner to verify that `package.json` redirects are respected without
	// the parser ever touching the dummy file. Mirrors OXC's filter in
	// tasks/coverage/src/typescript/meta.rs:make_units_from_test.
	filtered := make([dynamic]TestUnit, 0, len(units), allocator)
	for unit in units {
		if unit_content_is_invalid(unit.content) { continue }
		append(&filtered, unit)
	}

	settings := compiler_settings_from_map(options_map, allocator)

	return TestCaseContent{
		units       = filtered[:],
		settings    = settings,
		error_codes = nil,  // populated by caller via load_typescript
	}
}

@(private="file")
unit_content_is_invalid :: proc(content: string) -> bool {
	INVALID_LINE_PREFIXES :: [?]string{
		"This file is not read.",
		"This file is not processed.",
		"Nor is this one.",
		"not read",
		"content not parsed",
	}
	iter := content
	for line in strings.split_lines_iterator(&iter) {
		trimmed := strings.trim_left(line, " \t")
		for pfx in INVALID_LINE_PREFIXES {
			if strings.has_prefix(trimmed, pfx) { return true }
		}
	}
	return false
}

// parse_meta_option returns (name, value, ok) for `// @name: value` lines.
@(private="file")
parse_meta_option :: proc(line: string) -> (name, value: string, ok: bool) {
	rest := strings.trim_left(line, " \t")
	if !strings.has_prefix(rest, "//") { return "", "", false }
	rest = rest[2:]
	rest = strings.trim_left(rest, " \t")
	if !strings.has_prefix(rest, "@") { return "", "", false }
	rest = rest[1:]
	// name = identifier-ish chars
	end := 0
	for end < len(rest) && is_ident_char(rest[end]) { end += 1 }
	if end == 0 { return "", "", false }
	name = rest[:end]
	rest = rest[end:]
	rest = strings.trim_left(rest, " \t")
	if !strings.has_prefix(rest, ":") { return "", "", false }
	rest = rest[1:]
	rest = strings.trim_left(rest, " \t")
	value = strings.trim_right(rest, " \t\r")
	return name, value, true
}

@(private="file")
is_ident_char :: proc(b: byte) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') ||
	       (b >= '0' && b <= '9') || b == '_'
}

@(private="file")
compiler_settings_from_map :: proc(m: map[string]string, allocator: runtime.Allocator) -> CompilerSettings {
	split_csv := proc(s: string, allocator: runtime.Allocator) -> []string {
		if s == "" { return nil }
		parts := strings.split(s, ",", allocator)
		for &p in parts { p = strings.trim_space(strings.to_lower(p, allocator)) }
		return parts
	}
	return CompilerSettings{
		modules                       = split_csv(m["module"],                       allocator),
		targets                       = split_csv(m["target"],                       allocator),
		jsx                           = split_csv(m["jsx"],                          allocator),
		preserve_const_enums          = split_csv(m["preserveconstenums"],           allocator),
		use_define_for_class_fields   = split_csv(m["usedefineforclassfields"],      allocator),
		experimental_decorators       = split_csv(m["experimentaldecorators"],       allocator),
		module_detection              = split_csv(m["moduledetection"],              allocator),
		strict                        = split_csv(m["strict"],                        allocator),
		always_strict                 = split_csv(m["alwaysstrict"],                  allocator),
	}
}

// ============================================================================
// Baseline file lookup — index `<name>.errors.txt` once per suite load
// ============================================================================
//
// TSC names baselines as `<stem>.errors.txt` for the bare case and
// `<stem>(<flag>=<value>).errors.txt` for compiler-option matrix variants
// (target=es5, alwaysstrict=true, isolatedmodules=true, ...). The directive
// surface is too wide to enumerate at fixture time, so we scan the baseline
// directory once, group files by stem, and record whether any grouped error
// code is parser-relevant.

TypeScriptBaselineIndex :: struct {
	should_fail_by_stem: map[string]bool,
}

load_typescript_baseline_index :: proc(
	baseline_root: string,
	allocator:     runtime.Allocator,
) -> TypeScriptBaselineIndex {
	out := TypeScriptBaselineIndex{
		should_fail_by_stem = make(map[string]bool, 4096, allocator),
	}

	infos, infos_err := os.read_all_directory_by_path(baseline_root, allocator)
	if infos_err != nil { return out }
	defer os.file_info_slice_delete(infos, allocator)

	for info in infos {
		stem, ok := ts_errors_baseline_stem(info.name)
		if !ok { continue }
		if out.should_fail_by_stem[stem] { continue }

		bytes, read_err := os.read_entire_file_from_path(info.fullpath, allocator)
		if read_err != nil { continue }
		text := string(bytes)
		if ts_text_has_supported_error_code(text) {
			out.should_fail_by_stem[strings.clone(stem, allocator)] = true
		}
		delete(bytes, allocator)
	}

	return out
}

@(private="file")
ts_errors_baseline_stem :: proc(name: string) -> (string, bool) {
	if !strings.has_suffix(name, ".errors.txt") { return "", false }
	stem := name[:len(name) - len(".errors.txt")]
	if paren := strings.index(stem, "("); paren >= 0 {
		stem = stem[:paren]
	}
	if stem == "" { return "", false }
	return stem, true
}

@(private="file")
typescript_should_fail :: proc(index: TypeScriptBaselineIndex, fixture_path: string) -> bool {
	stem := strings.trim_suffix(filepath.base(fixture_path), filepath.ext(fixture_path))
	return index.should_fail_by_stem[stem]
}

@(private="file")
ts_text_has_supported_error_code :: proc(text: string) -> bool {
	// Look for the literal "error TS<digits>:" pattern. Hand-rolled matcher
	// (no regex dep) — we just scan byte-by-byte.
	src := text
	for {
		idx := strings.index(src, "error TS")
		if idx < 0 { break }
		src = src[idx + len("error TS"):]
		end := 0
		for end < len(src) && src[end] >= '0' && src[end] <= '9' { end += 1 }
		if end >= 4 && end <= 5 && end < len(src) && src[end] == ':' {
			if !ts_error_code_is_excluded(src[:end]) { return true }
		}
		if end == len(src) { break }
		src = src[end:]
	}
	return false
}

// ============================================================================
// load_typescript — phase-3 deliverable
// ============================================================================

load_typescript :: proc(vendor_root: string, allocator: runtime.Allocator) -> []Fixture {
	files := walk_and_read(vendor_root, TYPESCRIPT_SUBPATH, ts_skip_path, allocator)

	baseline_root, _ := filepath.join({vendor_root, TYPESCRIPT_BASELINE_SUBPATH}, allocator)
	defer delete(baseline_root)
	baseline_index := load_typescript_baseline_index(baseline_root, allocator)

	out := make([dynamic]Fixture, 0, len(files), allocator)

	for f in files {
		content := scan_test_case(f.abs, f.code, allocator)
		should_fail := typescript_should_fail(baseline_index, f.abs)

		// Emit one Fixture per unit. Multi-file TSC fixtures expand into
		// independent parser runs; the runner (phase 7) consumes them
		// individually.
		for unit in content.units {
			if !unit_is_parseable(unit.name) { continue }
			lang := resolve_ts_lang(unit.name, content.settings)
			st   := resolve_ts_source_type(unit.name, content.settings)
			dts  := resolve_ts_source_is_dts(unit.name)

			rel_with_unit := f.rel
			if len(content.units) > 1 {
				rel_with_unit = strings.concatenate({f.rel, "::", unit.name}, allocator)
			}

			// Determine force_strict from compiler settings.
			// TypeScript defaults to alwaysStrict=true when target >= ES2015 and
			// @strict is not explicitly false.
			force_strict := false
			if lang == .TS || lang == .TSX {
				has_strict_false := false
				for s in content.settings.strict {
					if s == "false" { has_strict_false = true }
				}
				has_always_strict_false := false
				has_always_strict_true := false
				for s in content.settings.always_strict {
					if s == "false" { has_always_strict_false = true }
					if s == "true"  { has_always_strict_true  = true }
				}
				if has_always_strict_true {
					force_strict = true
				} else if !has_always_strict_false && !has_strict_false {
					force_strict = true
				}
			}

			// .cjs / .cts sub-units are CommonJS — set the override so
			// the parser knows import/export in script-mode is valid.
			cjs: Maybe(bool)
			if strings.has_suffix(unit.name, ".cjs") ||
			   strings.has_suffix(unit.name, ".cts") {
				cjs = true
			}

			append(&out, Fixture{
				path          = f.abs,
				rel           = rel_with_unit,
				code          = unit.content,
				source_type   = st,
				lang          = lang,
				source_is_dts = dts,
				is_commonjs   = cjs,
				force_strict  = force_strict,
				should_fail   = should_fail,
				suite         = .TypeScript,
			})
		}
	}

	return out[:]
}

@(private="file")
ts_error_code_is_excluded :: proc(code: string) -> bool {
	for excluded in TS_NOT_SUPPORTED_ERROR_CODES {
		if code == excluded { return true }
	}
	return false
}

@(private="file")
unit_is_parseable :: proc(name: string) -> bool {
	ext := filepath.ext(name)
	switch ext {
	case ".ts", ".tsx", ".cts", ".mts", ".js", ".jsx", ".mjs", ".cjs":
		return true
	}
	// package.json units, baselines, and other non-source virtual files.
	return false
}

@(private="file")
resolve_ts_lang :: proc(name: string, settings: CompilerSettings) -> kessel.Lang {
	ext := filepath.ext(name)
	has_jsx_setting := len(settings.jsx) > 0
	switch ext {
	case ".tsx": return .TSX
	case ".jsx": return .JSX  // OXC distinguishes .jsx (no TS types) from .tsx.
	case ".ts", ".cts", ".mts":
		if has_jsx_setting { return .TSX }
		return .TS
	case ".js", ".cjs", ".mjs":
		// Plain JS within a TS fixture — JSX accepted (OXC's default).
		return .JSX
	}
	return .TS
}

@(private="file")
resolve_ts_source_type :: proc(
	name:     string,
	settings: CompilerSettings,
) -> Maybe(kessel.SourceType) {
	_ = settings
	if strings.has_suffix(name, ".mts") || strings.has_suffix(name, ".mjs") {
		return .Module
	}
	// .cts files are CommonJS TypeScript but can use ESM syntax
	// (TypeScript compiles to CJS). OXC treats them as Module.
	if strings.has_suffix(name, ".cts") {
		return .Module
	}
	// .cjs files are CommonJS JavaScript — no ESM syntax.
	if strings.has_suffix(name, ".cjs") {
		return .Script
	}
	return nil
}

@(private="file")
is_dts_path :: proc(name: string) -> bool {
	// Standard `.d.ts` / `.d.mts` / `.d.cts`.
	if strings.has_suffix(name, ".d.ts") ||
	   strings.has_suffix(name, ".d.mts") ||
	   strings.has_suffix(name, ".d.cts") {
		return true
	}
	// Arbitrary-extension declaration: `.d.<ext>.ts` (TS 5.0+
	// `allowArbitraryExtensions`). e.g. `component.d.html.ts`.
	if strings.has_suffix(name, ".ts") {
		stem := name[:len(name) - len(".ts")]
		if idx := strings.last_index(stem, ".d."); idx >= 0 { return true }
	}
	return false
}

@(private="file")
resolve_ts_source_is_dts :: proc(name: string) -> Maybe(bool) {
	if is_dts_path(name) { return true }
	return nil
}
