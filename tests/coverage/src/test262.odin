// test262 suite — discover, classify, and produce `Fixture`s for the
// official ECMAScript test suite (`tc39/test262:test/`).
//
// Mirrors `oxc-project/oxc:tasks/coverage/src/{test262/{mod,meta}.rs,
// load.rs#load_test262}`. test262 is the canonical ES conformance corpus —
// our `parser_test262.snap` headline number IS the ES2025 compliance proof.
//
// Per-fixture flow:
//
//   1. Path-level skip: drop fixtures under `staging/`, drop `_FIXTURE.js`
//      helpers, drop `annexB/.../assignmenttargettype/` (matches OXC).
//   2. Frontmatter parse: scan the leading `/*--- ... ---*/` block as a
//      tiny YAML subset (key: value, key: > with continuation, sequences).
//   3. Classify:
//        * `negative.phase: parse` → should_fail = true
//        * `negative.phase: early` → should_fail = true (early errors are
//          still parser-level under kessel's --show-semantic-errors)
//        * `negative.phase: resolution` / `runtime` → should_fail = false
//          (parser must accept; runtime engine catches it)
//        * no `negative` block → should_fail = false (positive test)
//   4. Emit one Fixture per file. test262 generates two variants per
//      negative test (strict / sloppy) via its harness; we only run the
//      raw file (matching OXC's parser-only coverage path).
package coverage

import "base:runtime"
import "core:strings"

import kessel "../../../src"

TEST262_SUBPATH :: "test262/test"

// ============================================================================
// Frontmatter — tiny YAML-subset parser
// ============================================================================
//
// test262 frontmatter is enclosed in `/*--- ... ---*/`. We support the
// fields the harness actually consumes:
//
//   negative:
//     phase: parse|early|resolution|runtime
//     type: SyntaxError
//   flags: [onlyStrict, noStrict, module, raw, ...]
//   features: [feature-name, ...]   (parsed but not consulted today)
//
// Multi-line scalars (`>` or `|`) are tolerated — we accumulate the
// continuation lines but don't actually use the body text.

NegativePhase :: enum {
	None,
	Parse,
	Early,
	Resolution,
	Runtime,
}

Test262Flag :: enum {
	OnlyStrict,
	NoStrict,
	Module,
	Raw,
	Async,
	Generated,
	CanBlockIsFalse,
	CanBlockIsTrue,
	NonDeterministic,
	ExplicitResourceManagement,
}

Test262Meta :: struct {
	phase: NegativePhase,
	flags: bit_set[Test262Flag],
}

parse_test262_frontmatter :: proc(code: string, allocator: runtime.Allocator) -> Test262Meta {
	out: Test262Meta

	// Locate the frontmatter block. test262 places it within the first
	// few hundred bytes; the opening marker is `/*---` and the closing
	// marker is `---*/`.
	open_idx := strings.index(code, "/*---")
	if open_idx < 0 { return out }
	rest := code[open_idx + len("/*---"):]
	close_idx := strings.index(rest, "---*/")
	if close_idx < 0 { return out }
	body := rest[:close_idx]

	// Walk lines. We support:
	//   "negative:"        → start of negative block
	//   "  phase: <ident>" → set phase
	//   "  type: <ident>"  → ignored (we don't consume yet)
	//   "flags: [a, b, c]" → set flag bit_set
	in_negative := false
	body_iter := body
	for line in strings.split_lines_iterator(&body_iter) {
		trimmed := strings.trim_right(line, " \t\r")
		if trimmed == "" { continue }

		// Determine indent — top-level keys vs nested-under-`negative:`.
		stripped := strings.trim_left(trimmed, " \t")
		indent := len(trimmed) - len(stripped)

		if indent == 0 {
			in_negative = false
			if strings.has_prefix(stripped, "negative:") {
				in_negative = true
				continue
			}
			if strings.has_prefix(stripped, "flags:") {
				rhs := strings.trim_space(stripped[len("flags:"):])
				out.flags = parse_flag_list(rhs)
				continue
			}
			continue
		}

		if in_negative && strings.has_prefix(stripped, "phase:") {
			rhs := strings.trim_space(stripped[len("phase:"):])
			out.phase = phase_from_string(rhs)
		}
	}

	return out
}

@(private="file")
phase_from_string :: proc(s: string) -> NegativePhase {
	switch s {
	case "parse":      return .Parse
	case "early":      return .Early
	case "resolution": return .Resolution
	case "runtime":    return .Runtime
	}
	return .None
}

// flags: [foo, bar, baz]   (bracketed YAML flow sequence)
@(private="file")
parse_flag_list :: proc(rhs: string) -> bit_set[Test262Flag] {
	out: bit_set[Test262Flag]
	if !strings.has_prefix(rhs, "[") { return out }
	end := strings.index(rhs, "]")
	if end < 0 { return out }
	inside := rhs[1:end]
	parts_iter := inside
	for {
		comma := strings.index(parts_iter, ",")
		token: string
		if comma < 0 {
			token = parts_iter
			parts_iter = ""
		} else {
			token = parts_iter[:comma]
			parts_iter = parts_iter[comma+1:]
		}
		token = strings.trim_space(token)
		if token == "" {
			if comma < 0 { break }
			continue
		}
		if flag, ok := flag_from_string(token); ok {
			out += {flag}
		}
		if comma < 0 { break }
	}
	return out
}

@(private="file")
flag_from_string :: proc(s: string) -> (Test262Flag, bool) {
	switch s {
	case "onlyStrict":                   return .OnlyStrict, true
	case "noStrict":                     return .NoStrict, true
	case "module":                       return .Module, true
	case "raw":                          return .Raw, true
	case "async":                        return .Async, true
	case "generated":                    return .Generated, true
	case "CanBlockIsFalse":              return .CanBlockIsFalse, true
	case "CanBlockIsTrue":               return .CanBlockIsTrue, true
	case "non-deterministic":            return .NonDeterministic, true
	case "explicit-resource-management": return .ExplicitResourceManagement, true
	}
	return .OnlyStrict, false  // sentinel — caller checks the bool
}

// ============================================================================
// test262_skip_path — drop staging/, _FIXTURE.js, etc.
// ============================================================================

test262_skip_path :: proc(abs_path: string) -> bool {
	if strings.contains(abs_path, "/test262/test/staging/") { return true }
	if strings.contains(abs_path, "_FIXTURE") { return true }
	// Empty fixture-target subdir OXC drops too.
	if strings.contains(abs_path, "annexB/language/expressions/assignmenttargettype") {
		return true
	}
	// `.md` are README-like text files alongside fixtures.
	if strings.has_suffix(abs_path, ".md") { return true }
	// We expect .js / .mjs only.
	if !strings.has_suffix(abs_path, ".js") && !strings.has_suffix(abs_path, ".mjs") {
		return true
	}
	return false
}

// ============================================================================
// load_test262 — phase-4 deliverable
// ============================================================================

load_test262 :: proc(vendor_root: string, allocator: runtime.Allocator) -> []Fixture {
	files := walk_and_read(vendor_root, TEST262_SUBPATH, test262_skip_path, allocator)
	out := make([dynamic]Fixture, 0, len(files), allocator)

	for f in files {
		meta := parse_test262_frontmatter(f.code, allocator)

		// `parse` and `early` errors are within kessel's parser-pipeline
		// remit. `resolution` and `runtime` errors are the host's
		// problem — the parser must accept these fixtures.
		should_fail := meta.phase == .Parse || meta.phase == .Early

		// SourceType: explicit `module` flag wins; .mjs always module;
		// otherwise script (kessel auto-promotes on import/export).
		st: kessel.SourceType
		if .Module in meta.flags || strings.has_suffix(f.abs, ".mjs") {
			st = .Module
		} else {
			st = .Script
		}

		// Lang: test262 is JavaScript-only (no JSX / TS).
		lang := kessel.Lang.JS

		append(&out, Fixture{
			path        = f.abs,
			rel         = f.rel,
			code        = f.code,
			source_type = st,
			lang        = lang,
			should_fail = should_fail,
			suite       = .Test262,
		})
	}

	return out[:]
}
