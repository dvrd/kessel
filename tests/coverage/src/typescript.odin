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
import "core:fmt"
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

	settings := compiler_settings_from_map(options_map, allocator)

	return TestCaseContent{
		units       = units[:],
		settings    = settings,
		error_codes = nil,  // populated by caller via load_typescript
	}
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
	}
}

// ============================================================================
// Baseline file lookup — extract error codes from `<name>.errors.txt`
// ============================================================================
//
// Error codes look like `error TS1234:`. OXC builds a cartesian product of
// `(module=X)`, `(target=Y)`, `(jsx=Z)` etc. variants when the fixture has
// multiple values. Phase-3 only handles the bare `<name>.errors.txt` path —
// variants are an enhancement we add when snap parity says it's worth it.

extract_error_codes :: proc(
	fixture_path:    string,
	baseline_root:   string,
	settings:        CompilerSettings,
	allocator:       runtime.Allocator,
) -> []string {
	stem := strings.trim_suffix(filepath.base(fixture_path), filepath.ext(fixture_path))
	candidates := make([dynamic]string, 0, 4, allocator)
	defer delete(candidates)

	// Bare baseline.
	bare, _ := filepath.join({baseline_root, strings.concatenate({stem, ".errors.txt"}, allocator)}, allocator)
	append(&candidates, bare)

	// Variants: `(module=es2022).errors.txt`, etc. Only emit when a
	// flag has 2+ values (matches OXC's `create_suffixes`).
	add_variant_set :: proc(
		stem:     string,
		flag:     string,
		values:   []string,
		acc:      ^[dynamic]string,
		allocator: runtime.Allocator,
	) {
		if len(values) < 2 { return }
		for v in values {
			parts := []string{
				stem, "(", flag, "=", v, ")", ".errors.txt",
			}
			append(acc, strings.concatenate(parts, allocator))
		}
	}
	variants := make([dynamic]string, 0, 8, allocator)
	defer delete(variants)
	add_variant_set(stem, "module",                  settings.modules,                       &variants, allocator)
	add_variant_set(stem, "target",                  settings.targets,                       &variants, allocator)
	add_variant_set(stem, "jsx",                     settings.jsx,                           &variants, allocator)
	add_variant_set(stem, "preserveconstenums",      settings.preserve_const_enums,          &variants, allocator)
	add_variant_set(stem, "usedefineforclassfields", settings.use_define_for_class_fields,   &variants, allocator)
	add_variant_set(stem, "experimentaldecorators",  settings.experimental_decorators,       &variants, allocator)
	for v in variants {
		full, _ := filepath.join({baseline_root, v}, allocator)
		append(&candidates, full)
	}

	codes_set := make(map[string]bool, 16, allocator)
	defer delete(codes_set)

	for path in candidates {
		if !os.exists(path) { continue }
		bytes, read_err := os.read_entire_file_from_path(path, allocator)
		if read_err != nil { continue }
		text := string(bytes)
		extract_codes_from_text(text, &codes_set)
	}

	out := make([dynamic]string, 0, len(codes_set), allocator)
	for code in codes_set {
		append(&out, code)
	}
	return out[:]
}

@(private="file")
extract_codes_from_text :: proc(text: string, out: ^map[string]bool) {
	// Look for the literal "error TS<digits>:" pattern. Hand-rolled matcher
	// (no regex dep) — we just scan byte-by-byte.
	src := text
	for {
		idx := strings.index(src, "error TS")
		if idx < 0 { break }
		src = src[idx + len("error TS"):]
		// Read decimal digits.
		end := 0
		for end < len(src) && src[end] >= '0' && src[end] <= '9' { end += 1 }
		if end >= 4 && end <= 5 && end < len(src) && src[end] == ':' {
			code := strings.clone(src[:end])
			out[code] = true
		}
		if end == len(src) { break }
		src = src[end:]
	}
}

// ============================================================================
// load_typescript — phase-3 deliverable
// ============================================================================

load_typescript :: proc(vendor_root: string, allocator: runtime.Allocator) -> []Fixture {
	files := walk_and_read(vendor_root, TYPESCRIPT_SUBPATH, ts_skip_path, allocator)

	baseline_root, _ := filepath.join({vendor_root, TYPESCRIPT_BASELINE_SUBPATH}, allocator)
	defer delete(baseline_root)

	out := make([dynamic]Fixture, 0, len(files), allocator)

	for f in files {
		content := scan_test_case(f.abs, f.code, allocator)
		error_codes := extract_error_codes(f.abs, baseline_root, content.settings, allocator)

		// should_fail iff at least one error code is NOT in the
		// not-supported list. (Mirrors OXC's load_typescript.)
		should_fail := false
		for code in error_codes {
			if !ts_error_code_is_excluded(code) { should_fail = true; break }
		}

		// Emit one Fixture per unit. Multi-file TSC fixtures expand into
		// independent parser runs; the runner (phase 7) consumes them
		// individually.
		for unit in content.units {
			if !unit_is_parseable(unit.name) { continue }
			lang := resolve_ts_lang(unit.name, content.settings)
			st   := resolve_ts_source_type(unit.name, content.settings)

			rel_with_unit := f.rel
			if len(content.units) > 1 {
				rel_with_unit = strings.concatenate({f.rel, "::", unit.name}, allocator)
			}

			append(&out, Fixture{
				path        = f.abs,
				rel         = rel_with_unit,
				code        = unit.content,
				source_type = st,
				lang        = lang,
				should_fail = should_fail,
				suite       = .TypeScript,
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
	// package.json units, d.ts files where parser-mode would be wrong, etc.
	return false
}

@(private="file")
resolve_ts_lang :: proc(name: string, settings: CompilerSettings) -> kessel.Lang {
	ext := filepath.ext(name)
	has_jsx_setting := len(settings.jsx) > 0
	switch ext {
	case ".tsx": return .TSX
	case ".jsx": return .TSX  // .jsx in TS corpus implies TS+JSX; OXC matches.
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
resolve_ts_source_type :: proc(name: string, settings: CompilerSettings) -> kessel.SourceType {
	// .d.ts variants are ambient declarations — kessel's parser treats them
	// as scripts but recognizes `declare`, `import type`, etc. We emit
	// Script and let the parser's source_is_dts path do the right thing.
	if strings.has_suffix(name, ".d.ts") ||
	   strings.has_suffix(name, ".d.mts") ||
	   strings.has_suffix(name, ".d.cts") {
		return .Script
	}
	return .Script
}
