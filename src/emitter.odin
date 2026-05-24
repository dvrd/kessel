// ============================================================================
// emitter.odin — ESTree JSON emission module with owned state
// ============================================================================
//
// Pre-refactor the JSON emitter was 5K+ lines embedded in main.odin and
// depended on a forest of process globals: direct_buf, direct_pos,
// use_direct_buf, utf16_offsets, line_offsets_for_loc, emit_ts_shape,
// emit_loc_enabled, emit_range_enabled, emit_module_record, compact_json,
// error_format. parse_file_to_disk had to save / restore some of these
// globals for thread safety; others still leaked across calls. Tests
// could not construct an emitter without mutating the same globals.
//
// This module fixes that by owning every piece of emitter state on an
// `Emitter` value and threading `^Emitter` through every emit
// proc. There is no thread-local pointer, no ambient state, no global
// configuration read during emission - the emitter is a pure value-and-
// function module:
//
//   cfg := emit_config_from_globals(job.lang)   // snapshot CLI flags
//   e: Emitter
//   emitter_init(&e, cfg, len(source), context.allocator)
//   defer emitter_destroy(&e, context.allocator)
//   emitter_build_utf16(&e, source, context.allocator)  // optional
//   emitter_adopt_lines(&e, lex.line_offsets)            // optional
//   emit_program(&e, program, 1, lex.comments[:], hashbang)
//   if cfg.module_record { emit_module_record(&e, &p, 1) }
//   emit_errors(&e, &p, 1)
//   os.write(os.stdout, e.buf[:e.pos])
//
// Every worker thread constructs its own Emitter; there is no shared
// state, no save / restore dance.
//
// What stays in main.odin:
//   * The CLI-side stdout writer (init_stdout_writer, flush_stdout_writer,
//     out_print / out_println / out_printf) used by banners, help text,
//     server-mode framing, lex JSON, and error messages. These are
//     general stdout helpers, not AST emitter helpers.
//   * The CLI option globals (compact_json, emit_loc_enabled, ...) - the
//     emit_config_from_globals snapshot reads them once at parse_file
//     entry; #6 will replace them with a CLI config struct.
//
// Naming convention:
//   emit_<something>(e: ^Emitter, ...)  - all emitter procs
//   out_<something>(...)                - stdout-only helpers (in main.odin)
//
// The split is what unblocks Test surface (#2 brief): a test can build
// an Emitter, call emit_program, and read e.buf[:e.pos] without going
// through stdout, files, or any process global.

package kessel

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"

// ============================================================================
// EmitConfig — snapshot of CLI flags that affect emission
// ============================================================================
//
// Built once at parse_file entry via emit_config_from_globals. Treated as
// immutable for the lifetime of the Emitter. Each worker thread builds
// its own EmitConfig; concurrent workers cannot race on it.
EmitConfig :: struct {
	// --compact: skip indentation and newlines in JSON output.
	compact: bool,

	// --loc: emit ESTree `loc: { start, end }` line/column object on
	// every node. Requires line_offsets to be adopted into the
	// emitter via emitter_adopt_lines.
	loc: bool,

	// --range: emit ESLint-style `range: [start, end]` on every node
	// in addition to the separate `start` / `end` fields.
	range: bool,

	// Resolved from --ast-type and the parse Lang. When true, emit
	// unconditional TS-ESTree fields (typeAnnotation: null, optional:
	// false, decorators: [], ...) that OXC's TS shape produces.
	ts_shape: bool,

	// --module-record: append the ESM module record (hasModuleSyntax,
	// staticImports, staticExports, dynamicImports, importMetas).
	module_record: bool,

	// --errors=oxc | kessel. Selects the JSON shape of the trailing
	// `errors` array.
	error_format: string,
}

// Snapshot a CliConfig into an EmitConfig. `lang` comes from the parse
// job - it drives the auto-detection of ts_shape when the --ast-type
// override is .Auto.
//
// Pre-#6 this read 6 process globals; post-#6 it reads the explicit
// `cli` argument. Same resolution rules as before.
emit_config_from_cli :: proc(cli: CliConfig, lang: Lang) -> EmitConfig {
	cfg := EmitConfig{
		compact       = cli.compact,
		loc           = cli.emit_loc,
		range         = cli.emit_range,
		module_record = cli.emit_module_record,
		error_format  = cli.error_format,
	}
	switch cli.ast_type {
	case .JS:   cfg.ts_shape = false
	case .TS:   cfg.ts_shape = true
	case .Auto: cfg.ts_shape = lang == .TS || lang == .TSX
	}
	return cfg
}

// ============================================================================
// Emitter — owns the writer buffer + per-source tables + config
// ============================================================================
//
// Field grouping: cfg first (immutable), buffer second (mutated by every
// emit_* call), tables third (built once per source, read by hot helpers).
Emitter :: struct {
	cfg: EmitConfig,

	// Output buffer. Grown by emit_reserve; never freed mid-emit (the
	// old slice is released after copy on grow). Owned by the Emitter;
	// emitter_destroy frees it.
	buf: []byte,
	pos: int,

	// Byte-to-UTF16 offset mapping. ESTree positions are UTF-16 code unit
	// indices (matching JS string semantics). Kessel's lexer tracks byte
	// offsets. For ASCII-only sources the two are identical (utf16_offsets
	// stays nil); when multi-byte UTF-8 chars are present we precompute
	// this adjustment table via emitter_build_utf16. utf16_offsets[byte_pos]
	// gives the UTF-16 code unit index.
	utf16_offsets: []u32,

	// Line-offset table for ESTree `loc` emission. Adopted from the
	// lexer (which built it lazily during parse); the emitter does not
	// own this slice and does not free it.
	line_offsets: []u32,
}

// ============================================================================
// Lifecycle
// ============================================================================
//
// Pattern: emitter_init -> [emitter_build_utf16] -> [emitter_adopt_lines]
// -> emit_program -> [emit_module_record] -> [emit_errors] -> read e.buf
// -> emitter_destroy.

// Initialise the emitter with the given config and an output buffer
// pre-sized for source_len_hint. Pretty-print mode is ~20× source size;
// compact ~9×. We size for pretty (20×) with a 4 KiB minimum to absorb
// tiny-file overhead. The buffer grows on overflow via emit_reserve.
emitter_init :: proc(e: ^Emitter, cfg: EmitConfig, source_len_hint: int, alloc: mem.Allocator) {
	est_size := max(source_len_hint * 20, 4096)
	e.cfg           = cfg
	e.buf           = make([]byte, est_size, alloc)
	e.pos           = 0
	e.utf16_offsets = nil
	e.line_offsets  = nil
}

// Release the emitter's output buffer. Idempotent on a zero-value emitter.
emitter_destroy :: proc(e: ^Emitter, alloc: mem.Allocator) {
	if e.buf != nil { delete(e.buf, alloc) }
	e.buf = nil
	e.pos = 0
}

// Build the byte->UTF-16 offset table for `source`. Only allocates if the
// source contains non-ASCII bytes; for pure-ASCII files utf16_offsets
// stays nil and to_utf16 returns the byte offset directly.
emitter_build_utf16 :: proc(e: ^Emitter, source: []byte, alloc: mem.Allocator) {
	if !simd_has_multibyte(source) {
		e.utf16_offsets = nil
		return
	}
	e.utf16_offsets = simd_build_utf16_offsets(source, alloc)
}

// Adopt the lexer's line_offsets table for `loc` emission. Borrowed -
// the lexer (and the parse arena) own the storage; the emitter only
// reads it.
emitter_adopt_lines :: proc(e: ^Emitter, line_offsets: []u32) {
	e.line_offsets = line_offsets
}

// Convert a byte offset to a UTF-16 code unit offset for ESTree emission.
// Hot path - called for every span emission. Returns the byte offset
// unchanged for ASCII-only sources (utf16_offsets stays nil after
// emitter_build_utf16).
to_utf16 :: #force_inline proc(e: ^Emitter, byte_off: u32) -> u32 {
	if e.utf16_offsets == nil { return byte_off }
	if int(byte_off) < len(e.utf16_offsets) { return e.utf16_offsets[byte_off] }
	// Past end: return last entry.
	if len(e.utf16_offsets) > 0 { return e.utf16_offsets[len(e.utf16_offsets)-1] }
	return byte_off
}

// ============================================================================
// Writer helpers — every write goes through e.buf
// ============================================================================
//
// All emit_* helpers below write to e.buf and grow it on demand via
// emit_reserve. The CLI-side `out_*` helpers (in main.odin) write to the
// stdout bufio writer and have a separate identity. The pre-refactor
// `out_s` / `out_string` / etc. routed between buf and stdout based on a
// `use_direct_buf` global; that routing is gone - emitter procs always
// write to e.buf and CLI procs always write to stdout.

// Ensure e.buf has at least `need` unused bytes from e.pos. Grows by
// doubling when the current allocation would overflow. Doubling
// amortises to O(1) per byte. Callers MUST reserve BEFORE indexing
// e.buf so indexed writes never touch freed memory.
emit_reserve :: #force_inline proc(e: ^Emitter, need: int) {
	if e.pos + need <= len(e.buf) { return }
	new_cap := max(len(e.buf) * 2, e.pos + need)
	new_buf := make([]byte, new_cap, context.allocator)
	mem.copy(raw_data(new_buf), raw_data(e.buf), e.pos)
	delete(e.buf, context.allocator)
	e.buf = new_buf
}

// Raw write. Strips '\n' in compact mode (matches the pre-refactor
// `out_s` semantics for direct-buffer mode). Most static strings on
// the hot path do not contain '\n' so the strip branch is rarely taken.
emit_raw :: #force_inline proc(e: ^Emitter, s: string) {
	emit_reserve(e, len(s))
	if e.cfg.compact {
		for i in 0..<len(s) {
			if s[i] != '\n' {
				e.buf[e.pos] = s[i]
				e.pos += 1
			}
		}
		return
	}
	mem.copy(&e.buf[e.pos], raw_data(s), len(s))
	e.pos += len(s)
}

// wtf8_surrogate_at is defined further down in this file (moved from
// main.odin). emit_str / emit_str_inner call it via package-scope
// resolution.

// Escape a string for JSON without the surrounding quotes. Used when
// embedding escaped content inside a larger quoted string (e.g. the
// regex `raw` field "/<pattern>/<flags>").
emit_str_inner :: proc(e: ^Emitter, s: string) {
	// Worst case: every byte escapes to `\u00xx` (6 bytes). WTF-8 surrogate
	// triples (3 bytes -> 6-byte \uXXXX) stay inside that bound.
	emit_reserve(e, len(s) * 6)
	i := 0
	for i < len(s) {
		c := s[i]
		switch c {
		case '"':
			e.buf[e.pos] = '\\'; e.buf[e.pos+1] = '"'; e.pos += 2
			i += 1
		case '\\':
			e.buf[e.pos] = '\\'; e.buf[e.pos+1] = '\\'; e.pos += 2
			i += 1
		case '\n':
			e.buf[e.pos] = '\\'; e.buf[e.pos+1] = 'n'; e.pos += 2
			i += 1
		case '\r':
			e.buf[e.pos] = '\\'; e.buf[e.pos+1] = 'r'; e.pos += 2
			i += 1
		case '\t':
			e.buf[e.pos] = '\\'; e.buf[e.pos+1] = 't'; e.pos += 2
			i += 1
		case:
			if c < 0x20 {
				tmp: [8]byte
				esc := fmt.bprintf(tmp[:], "\\u%04x", c)
				mem.copy(&e.buf[e.pos], raw_data(esc), len(esc))
				e.pos += len(esc)
				i += 1
			} else if cp, ok := wtf8_surrogate_at(s, i); ok {
				// Lone surrogate: emit \uXXXX (lowercase hex matches OXC).
				tmp: [8]byte
				esc := fmt.bprintf(tmp[:], "\\u%04x", cp)
				mem.copy(&e.buf[e.pos], raw_data(esc), len(esc))
				e.pos += len(esc)
				i += 3
			} else {
				e.buf[e.pos] = c
				e.pos += 1
				i += 1
			}
		}
	}
}

// Escape a string for JSON: surrounding quotes, backslashes, control
// chars, lone surrogates. See `wtf8_surrogate_at` for the surrogate
// rationale.
emit_str :: proc(e: ^Emitter, s: string) {
	// Worst case: 2 surrounding quotes + every byte escapes to `\u00xx`.
	emit_reserve(e, len(s) * 6 + 2)
	e.buf[e.pos] = '"'
	e.pos += 1
	i := 0
	for i < len(s) {
		c := s[i]
		switch c {
		case '"':
			e.buf[e.pos] = '\\'; e.buf[e.pos+1] = '"'; e.pos += 2
			i += 1
		case '\\':
			e.buf[e.pos] = '\\'; e.buf[e.pos+1] = '\\'; e.pos += 2
			i += 1
		case '\n':
			e.buf[e.pos] = '\\'; e.buf[e.pos+1] = 'n'; e.pos += 2
			i += 1
		case '\r':
			e.buf[e.pos] = '\\'; e.buf[e.pos+1] = 'r'; e.pos += 2
			i += 1
		case '\t':
			e.buf[e.pos] = '\\'; e.buf[e.pos+1] = 't'; e.pos += 2
			i += 1
		case:
			if c < 0x20 {
				tmp: [8]byte
				esc := fmt.bprintf(tmp[:], "\\u%04x", c)
				mem.copy(&e.buf[e.pos], raw_data(esc), len(esc))
				e.pos += len(esc)
				i += 1
			} else if cp, ok := wtf8_surrogate_at(s, i); ok {
				tmp: [8]byte
				esc := fmt.bprintf(tmp[:], "\\u%04x", cp)
				mem.copy(&e.buf[e.pos], raw_data(esc), len(esc))
				e.pos += len(esc)
				i += 3
			} else {
				e.buf[e.pos] = c
				e.pos += 1
				i += 1
			}
		}
	}
	e.buf[e.pos] = '"'
	e.pos += 1
}

// Write a bool as 'true' or 'false'.
emit_bool :: #force_inline proc(e: ^Emitter, b: bool) {
	emit_reserve(e, 5)
	if b {
		e.buf[e.pos] = 't'; e.buf[e.pos+1] = 'r'; e.buf[e.pos+2] = 'u'; e.buf[e.pos+3] = 'e'
		e.pos += 4
	} else {
		e.buf[e.pos] = 'f'; e.buf[e.pos+1] = 'a'; e.buf[e.pos+2] = 'l'; e.buf[e.pos+3] = 's'; e.buf[e.pos+4] = 'e'
		e.pos += 5
	}
}

// Write a u32 as decimal.
emit_u32 :: #force_inline proc(e: ^Emitter, n: u32) {
	// u32 max is 10 digits.
	tmp: [12]byte
	s := strconv.write_uint(tmp[:], u64(n), 10)
	emit_reserve(e, len(s))
	mem.copy(&e.buf[e.pos], raw_data(s), len(s))
	e.pos += len(s)
}

// emit_number writes an f64 using JSON-compatible number formatting that
// round-trips through JSON.parse to the exact same f64.
//
// Background: Odin's `fmt.printf("%v", f64)` and `strconv.write_float(...,
// 'g', -1, 64)` ("shortest" mode) are almost-but-not-always round-trippable.
// For most f64 values they produce a compact representation that JSON.parse
// re-reads to the same bit pattern; for boundary values (notably 2^64) the
// shortest formatter rounds to 16 significant digits, which then re-parses
// to the *next* f64 above the original — 1 ULP of silent corruption.
//
// 17 significant decimal digits is the IEEE-754 binary64 round-trip
// threshold: every f64 has a 17-digit decimal representation that
// JSON.parse returns to the exact same bit pattern.
//
// Strategy: try Odin's shortest first (compact, matches OXC / babel for
// the typical case), parse it back, and if the round-trip differs from
// the source f64 in bits, fall back to 17-digit precision. This keeps
// emitted JSON small for ordinary literals (1.5, 0.1, 100) and only
// pays the verbosity cost on the rare boundary values where the
// shortest formatter is wrong.
emit_number :: proc(e: ^Emitter, v: f64) {
	buf: [40]byte
	s := strconv.write_float(buf[:], v, 'g', -1, 64)
	if len(s) > 0 && s[0] == '+' { s = s[1:] }
	rt, ok := strconv.parse_f64(s)
	if !ok || transmute(u64)rt != transmute(u64)v {
		// Round-trip failed - fall back to 17-digit form which is
		// guaranteed to round-trip for every finite f64.
		s = strconv.write_float(buf[:], v, 'g', 17, 64)
		if len(s) > 0 && s[0] == '+' { s = s[1:] }
	}
	emit_raw(e, s)
}

// Variadic raw write - concatenate string args into e.buf.
emit_print :: proc(e: ^Emitter, args: ..any) {
	for arg in args {
		if v, ok := arg.(string); ok {
			emit_raw(e, v)
		}
	}
}

// Variadic raw write + trailing newline (skipped in compact mode).
emit_println :: proc(e: ^Emitter, args: ..any) {
	for arg in args {
		if v, ok := arg.(string); ok {
			emit_raw(e, v)
		}
	}
	if !e.cfg.compact {
		emit_reserve(e, 1)
		e.buf[e.pos] = '\n'
		e.pos += 1
	}
}

// Format string into e.buf. Used by the AST emitter for span fields,
// numbers, line/col output. Routes through a strings.Builder because
// fmt.bprintf's signature returns a string slice into a stack array
// that we can't directly memcpy without a length-aware helper.
emit_printf :: proc(e: ^Emitter, format: string, args: ..any) {
	sb: strings.Builder
	strings.builder_init(&sb)
	defer strings.builder_destroy(&sb)
	fmt.sbprintf(&sb, format, ..args)
	emit_raw(e, strings.to_string(sb))
}

// Indent N levels (skipped in compact mode). Two-space indent matches
// the existing pretty-print format.
emit_indent :: #force_inline proc(e: ^Emitter, depth: int) {
	if e.cfg.compact { return }
	emit_reserve(e, depth * 2)
	for _ in 0..<depth {
		e.buf[e.pos]   = ' '
		e.buf[e.pos+1] = ' '
		e.pos += 2
	}
}

// ============================================================================
// Public emit entry points - declared here, defined further down. Putting
// the prototypes near the top keeps the public API surface visible while
// the bodies sit alongside the rest of the AST printer code that gets
// moved in from main.odin during the #2 deepening.
// ============================================================================
//
// emit_program(e, program, indent, comments, hashbang)
//   Emit the top-level Program object. Mirrors the pre-refactor
//   print_program_ast.
//
// emit_module_record(e, parser, indent)
//   Emit the ESM module record block (hasModuleSyntax, staticImports,
//   staticExports, dynamicImports, importMetas). Caller decides whether
//   to invoke based on cfg.module_record.
//
// emit_errors(e, parser, indent)
//   Emit the trailing `errors` array using cfg.error_format ("kessel" |
//   "oxc"). No-op when len(parser.errors) == 0. Emits its own leading
//   ",\n" comma when there are errors. Builds the lexer line table on
//   demand for the kessel format's line/column fields.

emit_errors :: proc(e: ^Emitter, p: ^Parser, indent: int) {
	if len(p.errors) == 0 { return }

	// kessel error format needs line/column - build the table on demand.
	if p.lexer != nil && p.lexer.num_lines == 0 {
		build_line_table(p.lexer)
	}

	emit_raw(e, ",\n")
	emit_indent(e, indent)
	emit_raw(e, "\"errors\": [\n")
	if e.cfg.error_format == "oxc" {
		// OXC TS-ESTree shape: { severity, message, labels: [{ span: { start, end } }] }
		// Point-span errors use end = start + 1 (OXC convention for 1-char labels).
		for err, i in p.errors {
			emit_indent(e, indent + 1)
			emit_raw(e, "{\n")
			emit_indent(e, indent + 2)
			emit_raw(e, "\"severity\": \"error\",\n")
			emit_indent(e, indent + 2)
			emit_raw(e, "\"message\": ")
			emit_str(e, err.message)
			emit_raw(e, ",\n")
			emit_indent(e, indent + 2)
			emit_raw(e, "\"labels\": [\n")
			emit_indent(e, indent + 3)
			emit_raw(e, "{\n")
			emit_indent(e, indent + 4)
			emit_raw(e, "\"span\": {\n")
			emit_indent(e, indent + 5)
			emit_raw(e, "\"start\": ")
			emit_u32(e, to_utf16(e, err.start))
			emit_raw(e, ",\n")
			emit_indent(e, indent + 5)
			emit_raw(e, "\"end\": ")
			// Fall back to start+1 for single-point reports (start == end) so
			// the rustc-style label always has a one-character minimum width;
			// otherwise use the true token-aware span.
			err_end := err.end if err.end > err.start else err.start + 1
			emit_u32(e, to_utf16(e, err_end))
			emit_raw(e, "\n")
			emit_indent(e, indent + 4)
			emit_raw(e, "}\n")
			emit_indent(e, indent + 3)
			emit_raw(e, "}\n")
			emit_indent(e, indent + 2)
			emit_raw(e, "]\n")
			emit_indent(e, indent + 1)
			if i < len(p.errors) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
		}
	} else {
		// Kessel legacy shape: { message, line, column, offset } - default.
		for err, i in p.errors {
			emit_indent(e, indent + 1)
			emit_raw(e, "{\n")
			emit_indent(e, indent + 2)
			emit_raw(e, "\"message\": ")
			emit_str(e, err.message)
			emit_raw(e, ",\n")
			emit_indent(e, indent + 2)
			line, col := offset_to_line_col(p.lexer.line_offsets, err.start)
			emit_printf(e, "\"line\": %d,\n", line)
			emit_indent(e, indent + 2)
			emit_printf(e, "\"column\": %d,\n", col)
			emit_indent(e, indent + 2)
			emit_printf(e, "\"offset\": %d\n", int(err.start))
			emit_indent(e, indent + 1)
			if i < len(p.errors) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
		}
	}
	emit_indent(e, indent)
	emit_raw(e, "]")
}

// Emit ESM module record: hasModuleSyntax, staticImports, staticExports, dynamicImports, importMetas
emit_module_record :: proc(e: ^Emitter, p: ^Parser, indent: int) {
	emit_raw(e, ",\n")
	emit_indent(e, indent)
	emit_raw(e, "\"module\": {\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"hasModuleSyntax\": ")
	emit_bool(e, p.has_module_syntax)
	emit_raw(e, ",\n")

	// Emit staticImports array
	emit_indent(e, indent + 1)
	emit_raw(e, "\"staticImports\": [\n")
	for imp, i in p.staticImports {
		emit_indent(e, indent + 2)
		emit_raw(e, "{\n")
		emit_indent(e, indent + 3)
		emit_raw(e, "\"start\": ")
		emit_u32(e, to_utf16(e, imp.start))
		emit_raw(e, ",\n")
		emit_indent(e, indent + 3)
		emit_raw(e, "\"end\": ")
		emit_u32(e, to_utf16(e, imp.end))
		emit_raw(e, ",\n")
		emit_indent(e, indent + 3)
		emit_raw(e, "\"moduleRequest\": {\n")
		emit_indent(e, indent + 4)
		emit_raw(e, "\"value\": ")
		emit_str(e, imp.moduleRequest.value)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 4)
		emit_raw(e, "\"start\": ")
		emit_u32(e, to_utf16(e, imp.moduleRequest.start))
		emit_raw(e, ",\n")
		emit_indent(e, indent + 4)
		emit_raw(e, "\"end\": ")
		emit_u32(e, to_utf16(e, imp.moduleRequest.end))
		emit_raw(e, "\n")
		emit_indent(e, indent + 3)
		emit_raw(e, "},\n")
		emit_indent(e, indent + 3)
		emit_raw(e, "\"entries\": [\n")
		for entry, j in imp.entries {
			emit_indent(e, indent + 4)
			emit_raw(e, "{\n")
			emit_indent(e, indent + 5)
			emit_raw(e, "\"importName\": {\n")
			emit_indent(e, indent + 6)
			emit_raw(e, "\"kind\": \"")
			switch entry.importName.kind {
			case .Default:
				emit_raw(e, "Default")
			case .Namespace:
				emit_raw(e, "Namespace")
			case .Name:
				emit_raw(e, "Name")
			}
			emit_raw(e, "\",\n")
			emit_indent(e, indent + 6)
			emit_raw(e, "\"name\": ")
			emit_str(e, entry.importName.name)
			emit_raw(e, "\n")
			emit_indent(e, indent + 5)
			emit_raw(e, "},\n")
			emit_indent(e, indent + 5)
			emit_raw(e, "\"localName\": {\n")
			emit_indent(e, indent + 6)
			emit_raw(e, "\"value\": ")
			emit_str(e, entry.localName.name)
			emit_raw(e, ",\n")
			emit_indent(e, indent + 6)
			emit_raw(e, "\"start\": ")
			emit_u32(e, to_utf16(e, entry.localName.start))
			emit_raw(e, ",\n")
			emit_indent(e, indent + 6)
			emit_raw(e, "\"end\": ")
			emit_u32(e, to_utf16(e, entry.localName.end))
			emit_raw(e, "\n")
			emit_indent(e, indent + 5)
			emit_raw(e, "}\n")
			emit_indent(e, indent + 4)
			if j < len(imp.entries) - 1 {
				emit_raw(e, "},\n")
			} else {
				emit_raw(e, "}\n")
			}
		}
		emit_indent(e, indent + 3)
		emit_raw(e, "]\n")
		emit_indent(e, indent + 2)
		if i < len(p.staticImports) - 1 {
			emit_raw(e, "},\n")
		} else {
			emit_raw(e, "}\n")
		}
	}
	emit_indent(e, indent + 1)
	emit_raw(e, "],\n")

	// Emit staticExports array
	emit_indent(e, indent + 1)
	emit_raw(e, "\"staticExports\": [\n")
	for exp, i in p.staticExports {
		emit_indent(e, indent + 2)
		emit_raw(e, "{\n")
		emit_indent(e, indent + 3)
		emit_raw(e, "\"start\": ")
		emit_u32(e, to_utf16(e, exp.start))
		emit_raw(e, ",\n")
		emit_indent(e, indent + 3)
		emit_raw(e, "\"end\": ")
		emit_u32(e, to_utf16(e, exp.end))
		emit_raw(e, ",\n")
		if exp.moduleRequest.value != "" {
			emit_indent(e, indent + 3)
			emit_raw(e, "\"moduleRequest\": {\n")
			emit_indent(e, indent + 4)
			emit_raw(e, "\"value\": ")
			emit_str(e, exp.moduleRequest.value)
			emit_raw(e, ",\n")
			emit_indent(e, indent + 4)
			emit_raw(e, "\"start\": ")
			emit_u32(e, to_utf16(e, exp.moduleRequest.start))
			emit_raw(e, ",\n")
			emit_indent(e, indent + 4)
			emit_raw(e, "\"end\": ")
			emit_u32(e, to_utf16(e, exp.moduleRequest.end))
			emit_raw(e, "\n")
			emit_indent(e, indent + 3)
			emit_raw(e, "},\n")
		}
		emit_indent(e, indent + 3)
		emit_raw(e, "\"entries\": [\n")
		for entry, j in exp.entries {
			emit_indent(e, indent + 4)
			emit_raw(e, "{\n")
			emit_indent(e, indent + 5)
			emit_raw(e, "\"exportName\": {\n")
			emit_indent(e, indent + 6)
			emit_raw(e, "\"kind\": \"")
			switch entry.exportName.kind {
			case .Default:
				emit_raw(e, "Default")
			case .Namespace:
				emit_raw(e, "Namespace")
			case .Name:
				emit_raw(e, "Name")
			}
			emit_raw(e, "\",\n")
			emit_indent(e, indent + 6)
			emit_raw(e, "\"name\": ")
			emit_str(e, entry.exportName.name)
			emit_raw(e, "\n")
			emit_indent(e, indent + 5)
			emit_raw(e, "},\n")
			emit_indent(e, indent + 5)
			emit_raw(e, "\"localName\": {\n")
			emit_indent(e, indent + 6)
			emit_raw(e, "\"kind\": \"")
			switch entry.localName.kind {
			case .Default:
				emit_raw(e, "Default")
			case .Namespace:
				emit_raw(e, "Namespace")
			case .Name:
				emit_raw(e, "Name")
			}
			emit_raw(e, "\",\n")
			emit_indent(e, indent + 6)
			emit_raw(e, "\"name\": ")
			emit_str(e, entry.localName.name)
			emit_raw(e, "\n")
			emit_indent(e, indent + 5)
			emit_raw(e, "}\n")
			emit_indent(e, indent + 4)
			if j < len(exp.entries) - 1 {
				emit_raw(e, "},\n")
			} else {
				emit_raw(e, "}\n")
			}
		}
		emit_indent(e, indent + 3)
		emit_raw(e, "]\n")
		emit_indent(e, indent + 2)
		if i < len(p.staticExports) - 1 {
			emit_raw(e, "},\n")
		} else {
			emit_raw(e, "}\n")
		}
	}
	emit_indent(e, indent + 1)
	emit_raw(e, "],\n")

	// Emit dynamicImports array
	emit_indent(e, indent + 1)
	emit_raw(e, "\"dynamicImports\": [\n")
	for dyn, i in p.dynamicImports {
		emit_indent(e, indent + 2)
		emit_raw(e, "{\n")
		emit_indent(e, indent + 3)
		emit_raw(e, "\"start\": ")
		emit_u32(e, to_utf16(e, dyn.start))
		emit_raw(e, ",\n")
		emit_indent(e, indent + 3)
		emit_raw(e, "\"end\": ")
		emit_u32(e, to_utf16(e, dyn.end))
		emit_raw(e, ",\n")
		emit_indent(e, indent + 3)
		emit_raw(e, "\"moduleRequest\": {\n")
		emit_indent(e, indent + 4)
		emit_raw(e, "\"start\": ")
		emit_u32(e, to_utf16(e, dyn.moduleRequest.start))
		emit_raw(e, ",\n")
		emit_indent(e, indent + 4)
		emit_raw(e, "\"end\": ")
		emit_u32(e, to_utf16(e, dyn.moduleRequest.end))
		emit_raw(e, "\n")
		emit_indent(e, indent + 3)
		emit_raw(e, "}\n")
		emit_indent(e, indent + 2)
		if i < len(p.dynamicImports) - 1 {
			emit_raw(e, "},\n")
		} else {
			emit_raw(e, "}\n")
		}
	}
	emit_indent(e, indent + 1)
	emit_raw(e, "],\n")

	// Emit importMetas array
	emit_indent(e, indent + 1)
	emit_raw(e, "\"importMetas\": [\n")
	for meta, i in p.importMetas {
		emit_indent(e, indent + 2)
		emit_raw(e, "{\n")
		emit_indent(e, indent + 3)
		emit_raw(e, "\"start\": ")
		emit_u32(e, to_utf16(e, meta.start))
		emit_raw(e, ",\n")
		emit_indent(e, indent + 3)
		emit_raw(e, "\"end\": ")
		emit_u32(e, to_utf16(e, meta.end))
		emit_raw(e, "\n")
		emit_indent(e, indent + 2)
		if i < len(p.importMetas) - 1 {
			emit_raw(e, "},\n")
		} else {
			emit_raw(e, "}\n")
		}
	}
	emit_indent(e, indent + 1)
	emit_raw(e, "]\n")
	emit_indent(e, indent)
	emit_raw(e, "}")
}


// ESTree-compatible root node emission.
//
// Drifts closed here:
//   * type: "Script"/"Module" → type: "Program" + sourceType: "script"/"module".
//     Every standard ESTree parser (acorn, babel, espree, oxc) uses "Program"
//     as the root node type; "Script" was a Kessel-internal name that no
//     downstream consumer recognises.
//   * Add start/end: byte offsets covering the entire source. Acorn/OXC/Babel
//     all emit these; Kessel previously emitted no position info at all.
//   * hashbang: emit "hashbang" field with null when absent (OXC shape). The
//     lexer currently skips shebang lines without preserving content - we
//     still declare the field so consumers don't see it as "missing".
emit_program :: proc(e: ^Emitter, program: ^Program, indent: int, comments: []Comment = nil, hashbang: Maybe(HashbangInfo) = nil) {
	source_type_str := "script" if program.type == .Script else "module"
	emit_indent(e, indent)
	emit_raw(e, "\"type\": \"Program\",\n")
	emit_indent(e, indent)
	emit_span_leading(e, program.loc, indent)
	emit_raw(e, "\"sourceType\": \"")
	emit_raw(e, source_type_str)
	emit_raw(e, "\",\n")
	emit_indent(e, indent)
	// ES2023 HashbangComment - emit `{type:"Hashbang", value, start, end}` when
	// the source started with `#!...`. OXC parity shape.
	if hb, ok := hashbang.?; ok {
		emit_raw(e, "\"hashbang\": { \"type\": \"Hashbang\", \"value\": ")
		emit_str(e, hb.value)
		emit_raw(e, ", \"start\": ")
		emit_u32(e, to_utf16(e, hb.start))
		emit_raw(e, ", \"end\": ")
		emit_u32(e, to_utf16(e, hb.end))
		emit_raw(e, " },\n")
	} else {
		emit_raw(e, "\"hashbang\": null,\n")
	}

	emit_indent(e, indent)
	emit_raw(e, "\"body\": [\n")

	for stmt, i in program.body {
		emit_indent(e, indent + 1)
		emit_raw(e, "{\n")
		print_statement_ast(e, stmt, indent + 2)
		emit_indent(e, indent + 1)
		if i < len(program.body) - 1 {
			emit_raw(e, "},\n")
		} else {
			emit_raw(e, "}\n")
		}
	}

	emit_indent(e, indent)
	emit_raw(e, "]")

	// Emit comments array if any were collected
	if len(comments) > 0 {
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"comments\": [\n")
		for c, i in comments {
			emit_indent(e, indent + 1)
			emit_raw(e, "{\n")
			emit_indent(e, indent + 2)
			if c.type == .Line {
				emit_raw(e, "\"type\": \"Line\",\n")
			} else {
				emit_raw(e, "\"type\": \"Block\",\n")
			}
			emit_indent(e, indent + 2)
			emit_printf(e, "\"start\": %d,\n", c.start)
			emit_indent(e, indent + 2)
			emit_printf(e, "\"end\": %d,\n", c.end)
			emit_indent(e, indent + 2)
			emit_raw(e, "\"value\": ")
			emit_str(e, c.value)
			emit_raw(e, "\n")
			emit_indent(e, indent + 1)
			if i < len(comments) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
		}
		emit_indent(e, indent)
		emit_raw(e, "]")
	}
}

// emit_identifier_name_object writes a full `{"type":"Identifier","start":N,
// "end":N,"name":"..."}` object for an `IdentifierName` or `BindingIdentifier`
// value. Used wherever ESTree expects an Identifier node inline - e.g.
// ExportSpecifier.local, ImportSpecifier.imported, ClassDeclaration.id. Emits
// with the caller-supplied indent on each line; the opening `{` is written
// here, the closing `}` too. Callers handle leading field name and trailing
// comma.
emit_identifier_name_object :: proc(e: ^Emitter, id: IdentifierName, indent: int) {
	emit_raw(e, "{\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"type\": \"Identifier\",\n")
	emit_indent(e, indent + 1)
	emit_span_leading(e, id.loc, indent + 1)
	emit_raw(e, "\"name\": ")
	emit_str(e, id.name)
	if e.cfg.ts_shape {
		// TS-ESTree shape parity - OXC emits these fields unconditionally
		// on every Identifier, even where the source has no annotation or
		// `?` marker. S26 W4: added `optional: false` alongside the
		// existing `typeAnnotation: null`.
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"typeAnnotation\": null,\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"optional\": false")
	}
	emit_raw(e, "\n")
	emit_indent(e, indent)
	emit_raw(e, "}")
}

// emit_export_specifier_name dispatches the ExportSpecifierName union to the
// right leaf emitter: IdentifierName -> inline Identifier object; ^StringLiteral
// -> Literal object. Used for both `local` and `exported` positions of an
// ExportSpecifier, since ES2022 permits string literals on either side.
emit_export_specifier_name :: proc(e: ^Emitter, name: ExportSpecifierName, indent: int) {
	switch n in name {
	case IdentifierName:
		emit_identifier_name_object(e, n, indent)
	case ^StringLiteral:
		emit_string_literal_object(e, n^, indent)
	}
}

// emit_binding_identifier_object is a convenience alias for BindingIdentifier,
// which has the same layout. Odin treats them as distinct types so we give it
// its own entry point rather than cast at every call site.
emit_binding_identifier_object :: proc(e: ^Emitter, id: BindingIdentifier, indent: int) {
	emit_raw(e, "{\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"type\": \"Identifier\",\n")
	emit_indent(e, indent + 1)
	emit_span_leading(e, id.loc, indent + 1)
	emit_raw(e, "\"name\": ")
	emit_str(e, id.name)
	if e.cfg.ts_shape {
		// Same TS-shape footer as emit_identifier_name_object (S26 W4).
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"typeAnnotation\": null,\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"optional\": false")
	}
	emit_raw(e, "\n")
	emit_indent(e, indent)
	emit_raw(e, "}")
}

// emit_string_literal_object writes a full ESTree Literal object for a
// StringLiteral value - used inline by ImportDeclaration.source and
// ExportAllDeclaration.source, which previously emitted a compact one-line
// `{"type":"Literal","value":"...","raw":"..."}` with no start/end.
emit_string_literal_object :: proc(e: ^Emitter, s: StringLiteral, indent: int) {
	emit_raw(e, "{\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"type\": \"Literal\",\n")
	emit_indent(e, indent + 1)
	emit_span_leading(e, s.loc, indent + 1)
	emit_raw(e, "\"value\": ")
	emit_str(e, s.value)
	emit_raw(e, ",\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"raw\": ")
	emit_str(e, s.raw)
	emit_raw(e, "\n")
	emit_indent(e, indent)
	emit_raw(e, "}")
}

// out_u32 writes an unsigned 32-bit integer to the output, fast-pathing through
// the direct buffer to avoid `strings.Builder` allocation in out_printf. Used
// on every single emitted node for start/end offsets - millions of calls on a
// large file - so the allocation-free path is worth the ~40 lines.

// emit_span_fields writes `,\n<indent>"start": N,\n<indent>"end": N` - a
// LEADING comma (no trailing one), designed to slot between the `"type": "X"`
// line and whatever the case emits next (which still starts with its own
// `,\n<indent>"field": ...`). This is the one-call-per-node invariant that
// closes the ESTree position-info drift uniformly.
//
// Accepts loc by value (16B) rather than by pointer so there's no risk of
// accidental mutation. Hot path: inlined. Invariant: start <= end (asserted;
// an inverted span is a parser bug and we'd rather crash than emit nonsense).
emit_span_fields :: #force_inline proc(e: ^Emitter, loc: Loc, indent: int) {
	// Tolerate inverted spans (end < start) that can arise from deeply-nested
	// JSX children or error-recovery paths - clamp `end := max(start, end)` so
	// invalid input is still emitted as well-formed JSON instead of SIGTRAPping.
	// See K5 (deep JSX child recursion) and fuzz:invalid contract.
	start := loc.start
	end := loc.end
	if end < start { end = start }
	start_u16 := to_utf16(e, start)
	end_u16 := to_utf16(e, end)
	emit_raw(e, ",\n")
	emit_indent(e, indent)
	emit_raw(e, "\"start\": ")
	emit_u32(e, start_u16)
	emit_raw(e, ",\n")
	emit_indent(e, indent)
	emit_raw(e, "\"end\": ")
	emit_u32(e, end_u16)

	if e.cfg.range {
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"range\": [")
		emit_u32(e, start_u16)
		emit_raw(e, ", ")
		emit_u32(e, end_u16)
		emit_raw(e, "]")
	}

	if e.cfg.loc {
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"loc\": { \"start\": { \"line\": ")

		start_line, _ := offset_to_line_col(e.line_offsets, loc.start)
		emit_u32(e, start_line)
		emit_raw(e, ", \"column\": ")

		line_start_byte := e.line_offsets[start_line - 1] if start_line > 0 && start_line - 1 < u32(len(e.line_offsets)) else 0
		line_start_utf16 := to_utf16(e, line_start_byte)
		start_utf16 := to_utf16(e, loc.start)
		start_col_0indexed := start_utf16 - line_start_utf16
		emit_u32(e, start_col_0indexed)

		emit_raw(e, " }, \"end\": { \"line\": ")
		end_line, _ := offset_to_line_col(e.line_offsets, loc.end)
		emit_u32(e, end_line)
		emit_raw(e, ", \"column\": ")

		line_end_start_byte := e.line_offsets[end_line - 1] if end_line > 0 && end_line - 1 < u32(len(e.line_offsets)) else 0
		line_end_start_utf16 := to_utf16(e, line_end_start_byte)
		end_utf16 := to_utf16(e, loc.end)
		end_col_0indexed := end_utf16 - line_end_start_utf16
		emit_u32(e, end_col_0indexed)

		emit_raw(e, " } }")
	}
}

// emit_span_leading writes `"start": N,\n<indent>"end": N,\n<indent>` - a
// TRAILING comma, used when the caller has JUST printed `"type": "X",\n` +
// emit_indent(e, indent). Convenient for inline emitters (SwitchCase, Property,
// ImportSpecifier, CatchClause, Directive, etc.) that don't use `emit_span_fields`'s
// leading-comma pattern.
emit_span_leading :: #force_inline proc(e: ^Emitter, loc: Loc, indent: int) {
	// Tolerate inverted spans - see note on emit_span_fields.
	start := loc.start
	end := loc.end
	if end < start { end = start }
	start_u16 := to_utf16(e, start)
	end_u16 := to_utf16(e, end)
	emit_raw(e, "\"start\": ")
	emit_u32(e, start_u16)
	emit_raw(e, ",\n")
	emit_indent(e, indent)
	emit_raw(e, "\"end\": ")
	emit_u32(e, end_u16)

	if e.cfg.range {
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"range\": [")
		emit_u32(e, start_u16)
		emit_raw(e, ", ")
		emit_u32(e, end_u16)
		emit_raw(e, "]")
	}

	if e.cfg.loc {
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"loc\": { \"start\": { \"line\": ")

		start_line, _ := offset_to_line_col(e.line_offsets, loc.start)
		emit_u32(e, start_line)
		emit_raw(e, ", \"column\": ")

		line_start_byte := e.line_offsets[start_line - 1] if start_line > 0 && start_line - 1 < u32(len(e.line_offsets)) else 0
		line_start_utf16 := to_utf16(e, line_start_byte)
		start_utf16 := to_utf16(e, loc.start)
		start_col_0indexed := start_utf16 - line_start_utf16
		emit_u32(e, start_col_0indexed)

		emit_raw(e, " }, \"end\": { \"line\": ")
		end_line, _ := offset_to_line_col(e.line_offsets, loc.end)
		emit_u32(e, end_line)
		emit_raw(e, ", \"column\": ")

		line_end_start_byte := e.line_offsets[end_line - 1] if end_line > 0 && end_line - 1 < u32(len(e.line_offsets)) else 0
		line_end_start_utf16 := to_utf16(e, line_end_start_byte)
		end_utf16 := to_utf16(e, loc.end)
		end_col_0indexed := end_utf16 - line_end_start_utf16
		emit_u32(e, end_col_0indexed)

		emit_raw(e, " } }")
	}

	emit_raw(e, ",\n")
	emit_indent(e, indent)
}

// get_statement_loc / get_expression_loc / get_declaration_loc / get_pattern_loc
// extract the `loc: Loc` header that every AST struct shares as its first field.
// Returned by value; zero-allocation. Used by the top-level print_*_ast procs to
// emit start/end without threading a loc argument through every variant's case.
// statement_inner_nil returns true when a ^Statement union holds a nil typed
// pointer. Error-recovery paths in the parser can append a Statement variant
// whose inner pointer is nil; dereferencing `s.loc` crashes. Used as a guard
// at emitter entry and in get_statement_loc to downgrade a crash into a safe
// placeholder emission. Fixes a class of invalid-input fuzz crashes (K1).
statement_inner_nil :: proc(stmt: ^Statement) -> bool {
	if stmt == nil { return true }
	#partial switch s in stmt^ {
	case ^ExpressionStatement:       return s == nil
	case ^EmptyStatement:            return s == nil
	case ^BlockStatement:            return s == nil
	case ^DebuggerStatement:         return s == nil
	case ^ReturnStatement:           return s == nil
	case ^BreakStatement:            return s == nil
	case ^ContinueStatement:         return s == nil
	case ^LabeledStatement:          return s == nil
	case ^IfStatement:               return s == nil
	case ^SwitchStatement:           return s == nil
	case ^WhileStatement:            return s == nil
	case ^DoWhileStatement:          return s == nil
	case ^ForStatement:              return s == nil
	case ^ForInStatement:            return s == nil
	case ^ForOfStatement:            return s == nil
	case ^WithStatement:             return s == nil
	case ^ThrowStatement:            return s == nil
	case ^TryStatement:              return s == nil
	case ^FunctionDeclaration:       return s == nil
	case ^VariableDeclaration:       return s == nil
	case ^ClassDeclaration:          return s == nil
	case ^ImportDeclaration:         return s == nil
	case ^ExportNamedDeclaration:    return s == nil
	case ^ExportDefaultDeclaration:  return s == nil
	case ^ExportAllDeclaration:      return s == nil
	case ^TSInterfaceDeclaration:    return s == nil
	case ^TSTypeAliasDeclaration:    return s == nil
	case ^TSEnumDeclaration:         return s == nil
	case ^TSModuleDeclaration:       return s == nil
	case ^TSImportEqualsDeclaration: return s == nil
	case ^TSExportAssignment:        return s == nil
	case ^TSNamespaceExportDeclaration: return s == nil
	}
	return true  // unknown variant - treat as nil to be safe
}

get_statement_loc :: proc(stmt: ^Statement) -> Loc {
	if statement_inner_nil(stmt) { return Loc{} }
	#partial switch s in stmt^ {
	case ^ExpressionStatement:      return s.loc
	case ^EmptyStatement:            return s.loc
	case ^BlockStatement:            return s.loc
	case ^DebuggerStatement:         return s.loc
	case ^ReturnStatement:           return s.loc
	case ^BreakStatement:            return s.loc
	case ^ContinueStatement:         return s.loc
	case ^LabeledStatement:          return s.loc
	case ^IfStatement:                return s.loc
	case ^SwitchStatement:           return s.loc
	case ^WhileStatement:            return s.loc
	case ^DoWhileStatement:          return s.loc
	case ^ForStatement:              return s.loc
	case ^ForInStatement:            return s.loc
	case ^ForOfStatement:            return s.loc
	case ^WithStatement:             return s.loc
	case ^ThrowStatement:            return s.loc
	case ^TryStatement:              return s.loc
	case ^FunctionDeclaration:       return s.loc
	case ^VariableDeclaration:       return s.loc
	case ^ClassDeclaration:          return s.loc
	case ^ImportDeclaration:         return s.loc
	case ^ExportNamedDeclaration:    return s.loc
	case ^ExportDefaultDeclaration:  return s.loc
	case ^ExportAllDeclaration:      return s.loc
	case ^TSInterfaceDeclaration:   return s.loc
	case ^TSTypeAliasDeclaration:   return s.loc
	case ^TSEnumDeclaration:        return s.loc
	case ^TSModuleDeclaration:      return s.loc
	case ^TSImportEqualsDeclaration: return s.loc
	case ^TSExportAssignment:        return s.loc
	case ^TSNamespaceExportDeclaration: return s.loc
	}
	return Loc{}
}

// expression_inner_nil - same contract as statement_inner_nil for ^Expression
// unions. See commentary on statement_inner_nil for motivation.
expression_inner_nil :: proc(expr: ^Expression) -> bool {
	if expr == nil { return true }
	#partial switch e in expr^ {
	case ^NullLiteral:              return e == nil
	case ^BooleanLiteral:           return e == nil
	case ^NumericLiteral:           return e == nil
	case ^StringLiteral:            return e == nil
	case ^BigIntLiteral:            return e == nil
	case ^RegExpLiteral:            return e == nil
	case ^TemplateLiteral:          return e == nil
	case ^TaggedTemplateExpression: return e == nil
	case ^Identifier:               return e == nil
	case ^ThisExpression:           return e == nil
	case ^Super:                    return e == nil
	case ^ArrayExpression:          return e == nil
	case ^ObjectExpression:         return e == nil
	case ^FunctionExpression:       return e == nil
	case ^ArrowFunctionExpression:  return e == nil
	case ^ClassExpression:          return e == nil
	case ^MemberExpression:         return e == nil
	case ^CallExpression:           return e == nil
	case ^NewExpression:            return e == nil
	case ^ConditionalExpression:    return e == nil
	case ^UpdateExpression:         return e == nil
	case ^UnaryExpression:          return e == nil
	case ^BinaryExpression:         return e == nil
	case ^LogicalExpression:        return e == nil
	case ^AssignmentExpression:     return e == nil
	case ^SequenceExpression:       return e == nil
	case ^SpreadElement:            return e == nil
	case ^YieldExpression:          return e == nil
	case ^AwaitExpression:          return e == nil
	case ^ImportExpression:         return e == nil
	case ^MetaProperty:             return e == nil
	case ^PrivateIdentifier:        return e == nil
	case ^ChainExpression:          return e == nil
	case ^JSXElement:               return e == nil
	case ^JSXFragment:              return e == nil
	case ^JSXText:                  return e == nil
	case ^JSXExpressionContainer:   return e == nil
	case ^JSXEmptyExpression:       return e == nil
	case ^JSXSpreadChild:           return e == nil
	case ^TSAsExpression:           return e == nil
	case ^TSSatisfiesExpression:    return e == nil
	case ^TSNonNullExpression:      return e == nil
	case ^TSTypeAssertion:          return e == nil
	case ^TSInstantiationExpression: return e == nil
	case ^ParenthesizedExpression:  return e == nil
	}
	return true
}

get_expression_loc :: proc(expr: ^Expression) -> Loc {
	if expression_inner_nil(expr) { return Loc{} }
	#partial switch e in expr^ {
	case ^NullLiteral:              return e.loc
	case ^BooleanLiteral:           return e.loc
	case ^NumericLiteral:           return e.loc
	case ^StringLiteral:            return e.loc
	case ^BigIntLiteral:            return e.loc
	case ^RegExpLiteral:            return e.loc
	case ^TemplateLiteral:          return e.loc
	case ^TaggedTemplateExpression: return e.loc
	case ^Identifier:                return e.loc
	case ^ThisExpression:            return e.loc
	case ^Super:                     return e.loc
	case ^ArrayExpression:           return e.loc
	case ^ObjectExpression:          return e.loc
	case ^FunctionExpression:        return e.loc
	case ^ArrowFunctionExpression:   return e.loc
	case ^ClassExpression:           return e.loc
	case ^MemberExpression:          return e.loc
	case ^CallExpression:            return e.loc
	case ^ChainExpression:           return e.loc
	case ^NewExpression:             return e.loc
	case ^ConditionalExpression:     return e.loc
	case ^UpdateExpression:          return e.loc
	case ^UnaryExpression:           return e.loc
	case ^BinaryExpression:          return e.loc
	case ^LogicalExpression:         return e.loc
	case ^AssignmentExpression:      return e.loc
	case ^SequenceExpression:        return e.loc
	case ^SpreadElement:             return e.loc
	case ^YieldExpression:           return e.loc
	case ^AwaitExpression:           return e.loc
	case ^ImportExpression:          return e.loc
	case ^MetaProperty:              return e.loc
	case ^PrivateIdentifier:         return e.loc
	case ^JSXElement:               return e.loc
	case ^JSXFragment:              return e.loc
	case ^JSXText:                  return e.loc
	case ^JSXExpressionContainer:   return e.loc
	case ^JSXEmptyExpression:       return e.loc
	case ^JSXSpreadChild:           return e.loc
	case ^TSAsExpression:           return e.loc
	case ^TSSatisfiesExpression:    return e.loc
	case ^TSNonNullExpression:      return e.loc
	case ^TSTypeAssertion:          return e.loc
	case ^TSInstantiationExpression: return e.loc
	case ^ParenthesizedExpression:  return e.loc
	}
	return Loc{}
}

get_declaration_loc :: proc(decl: ^Declaration) -> Loc {
	if decl == nil { return Loc{} }
	#partial switch d in decl^ {
	case ^FunctionDeclaration:       return d.loc
	case ^VariableDeclaration:       return d.loc
	case ^ClassDeclaration:          return d.loc
	case ^ImportDeclaration:         return d.loc
	case ^ExportNamedDeclaration:    return d.loc
	case ^ExportDefaultDeclaration:  return d.loc
	case ^ExportAllDeclaration:      return d.loc
	}
	return Loc{}
}

get_pattern_loc :: proc(pattern: Pattern) -> Loc {
	#partial switch p in pattern {
	case ^Identifier:         return p.loc
	case ^ObjectPattern:       return p.loc
	case ^ArrayPattern:        return p.loc
	case ^AssignmentPattern:   return p.loc
	case ^RestElement:         return p.loc
	case ^MemberExpression:    return p.loc
	}
	return Loc{}
}

// Emit a BlockStatement body as inline JSON fields ("type" + "body" array).
// Walks `block.body` via print_statement_ast on each inner statement, producing
// a valid ESTree BlockStatement shape. Used wherever the AST holds a
// BlockStatement by value (TryStatement.block, TryStatement.finalizer,
// CatchClause.body) rather than through a ^Statement union - casting to
// ^Statement would re-interpret the BlockStatement bytes as a union header
// and corrupt output (same UB class as Bug H).
print_block_statement_inline :: proc(e: ^Emitter, block: ^BlockStatement, indent: int) {
	emit_indent(e, indent)
	emit_raw(e, "\"type\": \"BlockStatement\",\n")
	emit_indent(e, indent)
	emit_span_leading(e, block.loc, indent)
	emit_raw(e, "\"body\": [\n")
	for inner_stmt, i in block.body {
		emit_indent(e, indent + 1)
		emit_raw(e, "{\n")
		print_statement_ast(e, inner_stmt, indent + 2)
		emit_indent(e, indent + 1)
		if i < len(block.body) - 1 {
			emit_raw(e, "},\n")
		} else {
			emit_raw(e, "}\n")
		}
	}
	emit_indent(e, indent)
	emit_raw(e, "]")
}

// Emit a FunctionBody as inline BlockStatement. FunctionBody differs from
// BlockStatement by carrying directives; we flatten the directives into the
// body array as expression statements the same way OXC does, which keeps
// the ESTree shape uniform for consumers.
// print_function_parameter emits a single FunctionParameter as an ESTree
// pattern node. When `default_val` is present (e.g. `x = 1`), ESTree wraps
// the pattern in an AssignmentPattern { left: pattern, right: expression }.
// Previously the emit ignored default_val entirely, silently dropping every
// default-argument string literal (e.g. `constructor(msg = "Unspecified")`
// in assertion-error.js, and all the RHS expressions in chance.js /
// prettier.js / chartjs.js defaults).
print_function_parameter :: proc(e: ^Emitter, param: FunctionParameter, indent: int) {
	// TSParameterProperty: when a constructor param has TS modifiers
	// (accessibility/readonly/override), wrap in a TSParameterProperty node.
	// Only in TS-shape mode (TS/TSX lang). Additive - plain params are
	// emitted as before.
	has_modifiers := param.accessibility != .None || param.readonly || param.override_
	if has_modifiers && e.cfg.ts_shape {
		emit_indent(e, indent)
		emit_raw(e, "\"type\": \"TSParameterProperty\",\n")
		emit_indent(e, indent)
		// Outer span covers the modifier keyword through the param end.
		outer_start := param.modifier_start
		outer_end   := param.loc.end
		emit_printf(e, "\"start\": %d,\n", outer_start)
		emit_indent(e, indent)
		emit_printf(e, "\"end\": %d,\n", outer_end)
		emit_indent(e, indent)
		switch param.accessibility {
		case .None:      emit_raw(e, "\"accessibility\": null,\n")
		case .Public:    emit_raw(e, "\"accessibility\": \"public\",\n")
		case .Private:   emit_raw(e, "\"accessibility\": \"private\",\n")
		case .Protected: emit_raw(e, "\"accessibility\": \"protected\",\n")
		}
		emit_indent(e, indent)
		emit_raw(e, "\"readonly\": ")
		emit_bool(e, param.readonly)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"override\": ")
		emit_bool(e, param.override_)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"static\": false,\n")
		emit_indent(e, indent)
		emit_raw(e, "\"parameter\": {\n")
		// Inner parameter is the binding without the modifiers.
		if def, ok := param.default_val.(^Expression); ok && def != nil {
			emit_indent(e, indent + 1)
			emit_raw(e, "\"type\": \"AssignmentPattern\",\n")
			emit_indent(e, indent + 1)
			emit_span_leading(e, param.loc, indent + 1)
			emit_raw(e, "\"left\": {\n")
			print_pattern_ast(e, param.pattern, indent + 2)
			emit_raw(e, "\n")
			emit_indent(e, indent + 1)
			emit_raw(e, "},\n")
			emit_indent(e, indent + 1)
			emit_raw(e, "\"right\": {\n")
			print_expression_ast(e, def, indent + 2)
			emit_raw(e, "\n")
			emit_indent(e, indent + 1)
			emit_raw(e, "}")
		} else {
			print_pattern_ast(e, param.pattern, indent + 1)
		}
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")
		return
	}
	if def, ok := param.default_val.(^Expression); ok && def != nil {
		emit_indent(e, indent)
		emit_raw(e, "\"type\": \"AssignmentPattern\",\n")
		emit_indent(e, indent)
		emit_span_leading(e, param.loc, indent)
		emit_raw(e, "\"left\": {\n")
		print_pattern_ast(e, param.pattern, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		emit_indent(e, indent)
		emit_raw(e, "\"right\": {\n")
		print_expression_ast(e, def, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")
	} else {
		print_pattern_ast(e, param.pattern, indent)
	}
}

print_function_body_inline :: proc(e: ^Emitter, body: ^FunctionBody, indent: int) {
	emit_indent(e, indent)
	emit_raw(e, "\"type\": \"BlockStatement\",\n")
	emit_indent(e, indent)
	emit_span_leading(e, body.loc, indent)
	emit_raw(e, "\"body\": [\n")
	total := len(body.directives) + len(body.body)
	emitted := 0
	for dir, i in body.directives {
		emit_indent(e, indent + 1)
		emit_raw(e, "{\n")
		emit_indent(e, indent + 2)
		emit_raw(e, "\"type\": \"ExpressionStatement\",\n")
		emit_indent(e, indent + 2)
		emit_span_leading(e, dir.loc, indent + 2)
		emit_raw(e, "\"expression\": {\n")
		emit_indent(e, indent + 3)
		emit_raw(e, "\"type\": \"Literal\",\n")
		emit_indent(e, indent + 3)
		emit_span_leading(e, dir.value.loc, indent + 3)
		emit_raw(e, "\"value\": ")
		emit_str(e, dir.value.value)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 3)
		emit_raw(e, "\"raw\": ")
		emit_str(e, dir.value.raw)
		emit_raw(e, "\n")
		emit_indent(e, indent + 2)
		emit_raw(e, "},\n")
		emit_indent(e, indent + 2)
		emit_raw(e, "\"directive\": ")
		emit_str(e, dir.raw)
		emit_raw(e, "\n")
		emit_indent(e, indent + 1)
		emitted += 1
		if emitted < total { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
		_ = i
	}
	for inner_stmt, i in body.body {
		emit_indent(e, indent + 1)
		emit_raw(e, "{\n")
		print_statement_ast(e, inner_stmt, indent + 2)
		emit_indent(e, indent + 1)
		emitted += 1
		if emitted < total { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
		_ = i
	}
	emit_indent(e, indent)
	emit_raw(e, "]")
}

// print_declaration_ast emits a ^Declaration by rebuilding a ^Statement whose
// union tag matches the inner variant. The previous `(^Statement)(decl)` cast
// preserved the pointer address but kept the ^Declaration tag ordinal - which
// disagrees with the ^Statement tag ordinal for the same variant, since
// Declaration has 7 variants and Statement has 25 (different ordinal
// positions). That made `print_statement_ast` dispatch on the wrong case:
// e.g. a VariableDeclaration (^Declaration tag 1) was read as a
// BlockStatement (^Statement tag 2), corrupting the whole subtree walk.
//
// Symptom: SIGSEGV inside `get_statement_type_name`'s type-switch when
// classes containing exported declarations were emitted (tone.js, mathjax.js,
// marked.js, etc.).
//
// Reassigning `stmt = d` (where d is the typed inner pointer) lets Odin
// compute the correct ^Statement tag at assignment time. This is the safe
// idiom for "convert between union types that share a variant".
print_declaration_ast :: proc(e: ^Emitter, decl: ^Declaration, indent: int) {
	if decl == nil { return }
	stmt: Statement
	#partial switch d in decl^ {
	case ^FunctionDeclaration:       stmt = d
	case ^VariableDeclaration:       stmt = d
	case ^ClassDeclaration:           stmt = d
	case ^ImportDeclaration:          stmt = d
	case ^ExportNamedDeclaration:     stmt = d
	case ^ExportDefaultDeclaration:   stmt = d
	case ^ExportAllDeclaration:       stmt = d
	case ^TSInterfaceDeclaration:     stmt = d
	case ^TSTypeAliasDeclaration:     stmt = d
	case ^TSEnumDeclaration:          stmt = d
	case ^TSModuleDeclaration:        stmt = d
	case:
		// Unknown Declaration variant: emit a safe placeholder so the JSON
		// stays well-formed rather than silently skipping.
		emit_indent(e, indent)
		emit_raw(e, "\"type\": \"Unknown\"")
		return
	}
	print_statement_ast(e, &stmt, indent)
}

// print_variable_declaration_body emits the VariableDeclaration body fields
// (kind, declarations) starting with `,` - the caller has already written
// `"type": "VariableDeclaration"` and is positioned to continue the object.
//
// Extracted so for-in / for-of emit can reuse it on a ^VariableDeclaration
// directly, rather than casting the ^VariableDeclaration back through a
// fake ^Statement (which was UB: the cast would treat the VariableDeclaration
// struct as a Statement union header and dispatch on garbage bytes).
print_variable_declaration_body :: proc(e: ^Emitter, s: ^VariableDeclaration, indent: int) {
	kind_str := "var"
	#partial switch s.kind {
	case .Let:       kind_str = "let"
	case .Const:     kind_str = "const"
	case .Using:     kind_str = "using"
	case .AwaitUsing: kind_str = "await using"
	}
	emit_raw(e, ",\n")
	emit_indent(e, indent)
	emit_raw(e, "\"kind\": \"")
	emit_raw(e, kind_str)
	emit_raw(e, "\",\n")
	emit_indent(e, indent)
	emit_raw(e, "\"declarations\": [\n")
	for decl, i in s.declarations {
		emit_indent(e, indent + 1)
		emit_raw(e, "{\n")
		emit_indent(e, indent + 2)
		emit_raw(e, "\"type\": \"VariableDeclarator\",\n")
		emit_indent(e, indent + 2)
		emit_span_leading(e, decl.loc, indent + 2)
		// `decl.id` is nil when error recovery (e.g. reserved-word as binding,
		// or an incomplete `let : T`) couldn't synthesize a pattern. Without
		// this nil-check the emitter wrote `"id": {null}` — invalid JSON
		// that broke any downstream tool that round-trips the AST. Mirrors
		// the `"init": null` pattern below. (S26 W6 phase 3 bug class #3:
		// closes 135 "<no-error-captured>" cases in the OXC corpus triage,
		// each of which was kessel emitting unparseable JSON.)
		emit_raw(e, "\"id\": ")
		if decl.id == nil {
			emit_raw(e, "null,\n")
		} else {
			emit_raw(e, "{\n")
			print_pattern_ast(e, decl.id, indent + 3)
			emit_indent(e, indent + 2)
			emit_raw(e, "},\n")
		}
		emit_indent(e, indent + 2)
		emit_raw(e, "\"init\": ")
		if init, ok := decl.init.(^Expression); ok {
			emit_raw(e, "{\n")
			print_expression_ast(e, init, indent + 3)
			emit_indent(e, indent + 2)
			emit_raw(e, "}")
		} else {
			emit_raw(e, "null")
		}
		// TS-only: emit `"definite": true` when the declarator carried `!:`.
		// Match OXC's pattern of omitting the field when false (consistent
		// with `s.declare` above for VariableDeclaration).
		if decl.definite {
			emit_raw(e, ",\n")
			emit_indent(e, indent + 2)
			emit_raw(e, "\"definite\": true")
		}
		emit_indent(e, indent + 1)
		if i < len(s.declarations) - 1 {
			emit_raw(e, "},\n")
		} else {
			emit_raw(e, "}\n")
		}
	}
	emit_indent(e, indent)
	emit_raw(e, "]")
	// JS VariableDeclaration: emit `declare` only when true (OXC parity).
	if s.declare {
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"declare\": true")
	}
}

// print_class_body_inline emits the inside of the `"body": { ... }` payload
// for ClassDeclaration and ClassExpression. The caller has already written
// the opening `{` and must emit the matching `}`. Shape:
//     "type": "ClassBody",
//     "body": [ <class_element>, ... ]
//
// Previously this path emitted an empty `[]` stub regardless of actual body
// contents, rendering strings/expressions inside class methods invisible to
// the JSON emitter (raw-transfer buffer had them correctly). See P1 in the
// HANDOFF for context.
print_class_body_inline :: proc(e: ^Emitter, body: ^ClassBody, indent: int) {
	emit_indent(e, indent)
	emit_raw(e, "\"type\": \"ClassBody\",\n")
	emit_indent(e, indent)
	emit_span_leading(e, body.loc, indent)
	if len(body.body) == 0 {
		emit_raw(e, "\"body\": []\n")
		return
	}
	emit_raw(e, "\"body\": [\n")
	for i in 0 ..< len(body.body) {
		elem := &body.body[i]
		emit_indent(e, indent + 1)
		emit_raw(e, "{\n")
		print_class_element_fields(e, elem, indent + 2)
		emit_indent(e, indent + 1)
		if i < len(body.body) - 1 {
			emit_raw(e, "},\n")
		} else {
			emit_raw(e, "}\n")
		}
	}
	emit_indent(e, indent)
	emit_raw(e, "]\n")
}

// print_class_element_fields emits the fields of a single class element
// inside an already-opened `{`. The ESTree node type depends on the
// element's kind and the shape of its value:
//
//   * .StaticBlock                                 → "StaticBlock" (body only)
//   * .Constructor / .Get / .Set                   → "MethodDefinition"
//   * .Method with a FunctionExpression value      → "MethodDefinition"
//   * .Method with a non-function (or nil) value   → "PropertyDefinition"
//     (class field; `value` may be null)
//
// Known edge case: `field = function() {}` (a class field whose initializer
// is a non-arrow function expression) cannot be distinguished from a method
// by the current AST representation alone - the parser reuses .Method for
// fields. We accept the rare misclassification rather than bolt a
// parser-side kind field on in this pass. Arrow-valued fields
// (`field = () => ...`) are ArrowFunctionExpression, not
// FunctionExpression, so they take the PropertyDefinition path correctly.
print_class_element_fields :: proc(e: ^Emitter, elem: ^ClassElement, indent: int) {
	// Unwrap Maybe(^Expression) once. value_expr is nil if the element has
	// no initializer (bare `x;` field) or if disambiguation failed.
	value_expr: ^Expression = nil
	value_is_function := false
	if v, ok := elem.value.(^Expression); ok && v != nil {
		value_expr = v
		#partial switch _ in v^ {
		case ^FunctionExpression:
			value_is_function = true
		}
	}

	// StaticBlock has a dedicated shape: only `body: [Statement]`. The
	// parser stashes its statements inside a FunctionExpression.body.body
	// (see parse_static_block), so we unwrap that container here.
	if elem.kind == .StaticBlock {
		print_class_element_static_block(e, value_expr, indent, elem.loc)
		return
	}

	is_method := value_is_function
	#partial switch elem.kind {
	case .Constructor, .Get, .Set:
		is_method = true
	}

	type_name := is_method ? "MethodDefinition" : "PropertyDefinition"
	if elem.is_accessor {
		type_name = "AccessorProperty"
	}
	emit_indent(e, indent)
	emit_raw(e, "\"type\": \"")
	emit_raw(e, type_name)
	emit_raw(e, "\",\n")
	emit_indent(e, indent)

	// Emit decorators array only when non-empty (OXC omits it when empty).
	if len(elem.decorators) > 0 {
		emit_raw(e, "\"decorators\": [\n")
		for d, i in elem.decorators {
			emit_indent(e, indent + 1)
			emit_raw(e, "{\n")
			emit_indent(e, indent + 2)
			emit_raw(e, "\"type\": \"Decorator\",\n")
			emit_indent(e, indent + 2)
			emit_span_leading(e, d.loc, indent + 2)
			emit_raw(e, "\"expression\": {\n")
			print_expression_ast(e, d.expression, indent + 3)
			emit_raw(e, "\n")
			emit_indent(e, indent + 2)
			emit_raw(e, "}\n")
			emit_indent(e, indent + 1)
			if i < len(elem.decorators) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
		}
		emit_indent(e, indent)
		emit_raw(e, "],\n")
	}

	emit_indent(e, indent)
	emit_span_leading(e, elem.loc, indent)

	// key: ^Expression. MethodDefinition and PropertyDefinition both carry
	// a non-null key (Identifier, PrivateIdentifier, Literal, or an
	// expression when `computed` is true).
	emit_indent(e, indent)
	if elem.key != nil {
		emit_raw(e, "\"key\": {\n")
		print_expression_ast(e, elem.key, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "},\n")
	} else {
		emit_raw(e, "\"key\": null,\n")
	}

	// value: Maybe(^Expression). null for uninitialised fields (`x;`).
	emit_indent(e, indent)
	if value_expr != nil {
		emit_raw(e, "\"value\": {\n")
		print_expression_ast(e, value_expr, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "},\n")
	} else {
		emit_raw(e, "\"value\": null,\n")
	}

	// kind is MethodDefinition-only per ESTree. PropertyDefinition has no
	// kind field - OXC confirms.
	if is_method {
		kind_str := "method"
		#partial switch elem.kind {
		case .Constructor:
			kind_str = "constructor"
		case .Get:
			kind_str = "get"
		case .Set:
			kind_str = "set"
		}
		emit_indent(e, indent)
		emit_raw(e, "\"kind\": \"")
		emit_raw(e, kind_str)
		emit_raw(e, "\",\n")
	}

	emit_indent(e, indent)
	emit_raw(e, "\"computed\": ")
	emit_bool(e, elem.computed)
	emit_raw(e, ",\n")

	emit_indent(e, indent)
	emit_raw(e, "\"static\": ")
	emit_bool(e, elem.static)

	// class-element abstract: emit only when true (OXC parity).
	if elem.abstract {
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"abstract\": true")
	}

	// TS class member modifiers (K12). Only emitted when set, matching
	// OXC / typescript-eslint's convention of omitting null defaults. This
	// keeps the JS output byte-identical; .ts / .tsx paths get the extra
	// fields whenever the parser observed them.
	#partial switch elem.accessibility {
	case .Public:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"accessibility\": \"public\"")
	case .Private:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"accessibility\": \"private\"")
	case .Protected:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"accessibility\": \"protected\"")
	}
	if elem.readonly {
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"readonly\": true")
	}
	if elem.override_ {
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"override\": true")
	}

	// TS field modifiers: optional (`foo?:`) and definite (`foo!:`).
	// In TS-shape mode always emit `optional` (OXC always emits false, even
	// when not optional). In plain JS mode only emit when true (minimise diff).
	if elem.optional || e.cfg.ts_shape {
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"optional\": ")
		emit_bool(e, elem.optional)
	}
	if elem.definite {
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"definite\": true")
	}
	// typeAnnotation is a PropertyDefinition field only (not MethodDefinition).
	if !is_method {
		if ann, ok := elem.type_annotation.(^TSTypeAnnotation); ok {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"typeAnnotation\": ")
			emit_ts_type_annotation_node(e, ann, indent)
		} else if e.cfg.ts_shape {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"typeAnnotation\": null")
		}
	}
	emit_raw(e, "\n")
}

// print_class_element_static_block emits a StaticBlock class element. The
// parser wraps the block's statement list inside a FunctionExpression.body
// (see parse_static_block in src/parser.odin); we unwrap that one level so
// the JSON matches OXC's `{"type":"StaticBlock","body":[<stmt>,...]}`.
print_class_element_static_block :: proc(e: ^Emitter, value_expr: ^Expression, indent: int, static_loc: Loc) {
	emit_indent(e, indent)
	emit_raw(e, "\"type\": \"StaticBlock\",\n")
	emit_indent(e, indent)
	emit_span_leading(e, static_loc, indent)

	stmts: ^[dynamic]^Statement = nil
	if value_expr != nil {
		#partial switch fe in value_expr^ {
		case ^FunctionExpression:
			stmts = &fe.body.body
		}
	}

	emit_indent(e, indent)
	if stmts == nil || len(stmts^) == 0 {
		emit_raw(e, "\"body\": []\n")
		return
	}
	emit_raw(e, "\"body\": [\n")
	for j in 0 ..< len(stmts^) {
		emit_indent(e, indent + 1)
		emit_raw(e, "{\n")
		print_statement_ast(e, stmts[j], indent + 2)
		emit_indent(e, indent + 1)
		if j < len(stmts^) - 1 {
			emit_raw(e, "},\n")
		} else {
			emit_raw(e, "}\n")
		}
	}
	emit_indent(e, indent)
	emit_raw(e, "]\n")
}

print_statement_ast :: proc(e: ^Emitter, stmt: ^Statement, indent: int) {
	// Emitter robustness: if the parser appended a Statement with a nil inner
	// typed pointer (can happen on invalid/fuzzed input), emit a safe
	// placeholder instead of dereferencing. See statement_inner_nil.
	// Placeholder carries start=end=0 so the I3_start_end_present invariant holds.
	if statement_inner_nil(stmt) {
		emit_indent(e, indent)
		emit_raw(e, "\"type\": \"Unknown\"")
		emit_span_fields(e, Loc{}, indent)
		return
	}
	emit_indent(e, indent)
	emit_raw(e, "\"type\": \"")
	emit_raw(e, get_statement_type_name(e, stmt))
	emit_raw(e, "\"")
	emit_span_fields(e, get_statement_loc(stmt), indent)

	#partial switch s in stmt^ {
	case ^ExpressionStatement:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"expression\": {\n")
		print_expression_ast(e, s.expression, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "}")
		// ESTree: ExpressionStatement in a directive prologue gets a
		// `directive: "<content>"` field. The parser marks these by setting
		// `directive` to the unquoted literal value; regular expression
		// statements leave it empty (len==0).
		if len(s.directive) > 0 {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"directive\": ")
			emit_str(e, s.directive)
		}

	case ^VariableDeclaration:
		print_variable_declaration_body(e, s, indent)

	case ^FunctionDeclaration:
		// S26 W4b: ambient (no-body) function declarations —
		// `declare function f(): T;`, overload signatures, and the
		// `export function init(opts): void;` lines inside
		// `declare module 'x' { ... }` — are emitted as TSDeclareFunction
		// in TS-ESTree, not FunctionDeclaration. The parser already
		// distinguishes the two via `expr.no_body`; switch on it here so
		// the emitted `type` field, `body: null` placeholder, and the
		// always-on `declare: <bool>` field all match OXC. Plain JS keeps
		// the historical FunctionDeclaration shape.
		emit_as_declare_fn := e.cfg.ts_shape && s.expr.no_body
		if emit_as_declare_fn {
			// Override the default `"type": "FunctionDeclaration"` written
			// upstream of this switch arm. We can't actually rewrite the
			// already-emitted bytes, so the `type` field is fixed by the
			// caller-side path: emit_decl_type_label / decl_type_string
			// already pick TSDeclareFunction when no_body is set. This
			// branch only adjusts the field set that follows.
		}
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"id\": ")
		if id, ok := s.expr.id.(BindingIdentifier); ok {
			emit_identifier_name_object(e, IdentifierName{loc = id.loc, name = id.name}, indent)
		} else {
			emit_raw(e, "null")
		}
		emit_raw(e, ",\n")
		// typeParameters: always emit in TS-shape mode (null when absent).
		if tp, ok := s.expr.type_parameters.(^TSTypeParameterDeclaration); ok && tp != nil {
			emit_indent(e, indent)
			emit_raw(e, "\"typeParameters\": ")
			emit_ts_type_parameter_declaration(e, s.expr.type_parameters, indent)
			emit_raw(e, ",\n")
		} else if e.cfg.ts_shape {
			emit_indent(e, indent)
			emit_raw(e, "\"typeParameters\": null,\n")
		}
		emit_indent(e, indent)
		// expression: false. OXC emits this on both FunctionDeclaration
		// and TSDeclareFunction for symmetry with ArrowFunctionExpression.
		emit_raw(e, "\"expression\": false,\n")
		emit_indent(e, indent)
		emit_raw(e, "\"generator\": ")
		emit_bool(e, s.expr.generator)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"async\": ")
		emit_bool(e, s.expr.async)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"params\": [")
		if len(s.expr.params) == 0 {
			emit_raw(e, "]")
		} else {
			emit_raw(e, "\n")
			for param, i in s.expr.params {
				emit_indent(e, indent + 1)
				emit_raw(e, "{\n")
				print_function_parameter(e, param, indent + 2)
				emit_raw(e, "\n")
				emit_indent(e, indent + 1)
				if i < len(s.expr.params) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
			}
			emit_indent(e, indent)
			emit_raw(e, "]")
		}
		// TypeScript return type annotation. In TS-shape mode always emit
		// the field (null when absent) for OXC parity — the FunctionExpression
		// / ArrowFunctionExpression cases already do this; FunctionDeclaration
		// was the lone holdout (S26 W4).
		if ann, ok := s.expr.return_type.(^TSTypeAnnotation); ok {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"returnType\": ")
			emit_ts_type_annotation_node(e, ann, indent)
		} else if e.cfg.ts_shape {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"returnType\": null")
		}
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		// Body: TSDeclareFunction has `body: null`; FunctionDeclaration has
		// the inline BlockStatement.
		if emit_as_declare_fn {
			emit_raw(e, "\"body\": null")
		} else {
			emit_println(e, "\"body\": {")
			fn_body := &s.expr.body
			print_function_body_inline(e, fn_body, indent + 1)
			emit_raw(e, "\n")
			emit_indent(e, indent)
			emit_print(e, "}")
		}
		// `declare`: TS-shape mode always emits the field (false placeholder
		// when absent); plain JS only when set. TSDeclareFunction is
		// inherently a TS-only node, so it always emits.
		if e.cfg.ts_shape {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"declare\": ")
			emit_bool(e, s.expr.declare)
		} else if s.expr.declare {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"declare\": true")
		}

	case ^BlockStatement:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"body\": [\n")
		for inner_stmt, i in s.body {
			emit_indent(e, indent + 1)
			emit_raw(e, "{\n")
			print_statement_ast(e, inner_stmt, indent + 2)
			emit_indent(e, indent + 1)
			if i < len(s.body) - 1 {
				emit_raw(e, "},\n")
			} else {
				emit_raw(e, "}\n")
			}
		}
		emit_indent(e, indent)
		emit_raw(e, "]")

	case ^ReturnStatement:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"argument\": ")
		if arg, ok := s.argument.(^Expression); ok {
			emit_raw(e, "{\n")
			print_expression_ast(e, arg, indent + 1)
			emit_indent(e, indent)
			emit_raw(e, "}")
		} else {
			emit_raw(e, "null")
		}

	case ^IfStatement:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"test\": {\n")
		print_expression_ast(e, s.test, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		emit_indent(e, indent)
		emit_raw(e, "\"consequent\": {\n")
		print_statement_ast(e, s.consequent, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		emit_indent(e, indent)
		emit_raw(e, "\"alternate\": ")
		if alt, ok := s.alternate.(^Statement); ok {
			emit_raw(e, "{\n")
			print_statement_ast(e, alt, indent + 1)
			emit_indent(e, indent)
			emit_raw(e, "}")
		} else {
			emit_raw(e, "null")
		}

	case ^WhileStatement:
		emit_println(e, ",")
		emit_indent(e, indent)
		emit_println(e, "\"test\": {")
		print_expression_ast(e, s.test, indent + 1)
		emit_indent(e, indent)
		emit_println(e, "},")
		emit_indent(e, indent)
		emit_println(e, "\"body\": {")
		print_statement_ast(e, s.body, indent + 1)
		emit_indent(e, indent)
		emit_print(e, "}")

	case ^ForStatement:
		emit_println(e, ",")
		emit_indent(e, indent)
		emit_print(e, "\"init\": ")
		if decl, ok := s.init_decl.(^VariableDeclaration); ok {
			// Do NOT cast ^VariableDeclaration to ^Statement - that was UB of the
			// same class as Bug H: the VariableDeclaration struct bytes would be
			// read as if they were a Statement union header, corrupting dispatch.
			// Symptom: SIGSEGV deep inside class methods containing
			// `for (let x = 0; ...; ...)` loops (e.g. tone.js, mathjax.js, etc.).
			emit_println(e, "{")
			emit_indent(e, indent + 1)
			emit_raw(e, "\"type\": \"VariableDeclaration\"")
			emit_span_fields(e, decl.loc, indent + 1)
			print_variable_declaration_body(e, decl, indent + 1)
			emit_raw(e, "\n")
			emit_indent(e, indent)
			emit_println(e, "},")
		} else if expr, ok2 := s.init_expr.(^Expression); ok2 {
			emit_println(e, "{")
			print_expression_ast(e, expr, indent + 1)
			emit_indent(e, indent)
			emit_println(e, "},")
		} else {
			emit_println(e, "null,")
		}
		emit_indent(e, indent)
		emit_print(e, "\"test\": ")
		if test_expr, ok := s.test.(^Expression); ok {
			emit_println(e, "{")
			print_expression_ast(e, test_expr, indent + 1)
			emit_indent(e, indent)
			emit_println(e, "},")
		} else {
			emit_println(e, "null,")
		}
		emit_indent(e, indent)
		emit_print(e, "\"update\": ")
		if upd_expr, ok := s.update.(^Expression); ok {
			emit_println(e, "{")
			print_expression_ast(e, upd_expr, indent + 1)
			emit_indent(e, indent)
			emit_println(e, "},")
		} else {
			emit_println(e, "null,")
		}
		emit_indent(e, indent)
		emit_println(e, "\"body\": {")
		print_statement_ast(e, s.body, indent + 1)
		emit_indent(e, indent)
		emit_print(e, "}")

	case ^ClassDeclaration:
		emit_println(e, ",")
		// Emit decorators only when non-empty (OXC omits empty arrays).
		if len(s.expr.decorators) > 0 {
			emit_indent(e, indent)
			emit_raw(e, "\"decorators\": [\n")
			for d, i in s.expr.decorators {
				emit_indent(e, indent + 1)
				emit_raw(e, "{\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"type\": \"Decorator\",\n")
				emit_indent(e, indent + 2)
				emit_span_leading(e, d.loc, indent + 2)
				emit_raw(e, "\"expression\": {\n")
				print_expression_ast(e, d.expression, indent + 3)
				emit_raw(e, "\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "}\n")
				emit_indent(e, indent + 1)
				if i < len(s.expr.decorators) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
			}
			emit_indent(e, indent)
			emit_raw(e, "],\n")
		}
		emit_indent(e, indent)
		emit_print(e, "\"id\": ")
		if id, ok := s.id.(BindingIdentifier); ok {
			emit_identifier_name_object(e, IdentifierName{loc = id.loc, name = id.name}, indent)
			emit_raw(e, ",\n")
		} else {
			emit_raw(e, "null,\n")
		}
		if tp, ok := s.expr.type_parameters.(^TSTypeParameterDeclaration); ok && tp != nil {
			emit_indent(e, indent)
			emit_raw(e, "\"typeParameters\": ")
			emit_ts_type_parameter_declaration(e, s.expr.type_parameters, indent)
			emit_raw(e, ",\n")
		} else if e.cfg.ts_shape {
			emit_indent(e, indent)
			emit_raw(e, "\"typeParameters\": null,\n")
		}
		emit_indent(e, indent)
		emit_print(e, "\"superClass\": ")
		if super, ok := s.super_class.(^Expression); ok && super != nil {
			emit_println(e, "{")
			print_expression_ast(e, super, indent + 1)
			emit_indent(e, indent)
			emit_println(e, "},")
		} else {
			emit_println(e, "null,")
		}
		// superTypeArguments: type arguments for the superclass. OXC always emits
		// the field in TS-shape mode (null when absent).
		if e.cfg.ts_shape {
			emit_indent(e, indent)
			emit_raw(e, "\"superTypeArguments\": null,\n")
		}
		// `implements` clause — ts-only. Emit in TS-shape mode always (OXC
		// always writes the field; null-array or populated), and in JS mode
		// only when non-empty to keep plain-JS output unchanged.
		if e.cfg.ts_shape || len(s.expr.implements) > 0 {
			emit_indent(e, indent)
			emit_raw(e, "\"implements\": [")
			if len(s.expr.implements) == 0 {
				emit_raw(e, "],\n")
			} else {
				emit_raw(e, "\n")
				for h, i in s.expr.implements {
					emit_ts_heritage_entry(e, h, "TSClassImplements", indent + 1)
					if i < len(s.expr.implements) - 1 { emit_raw(e, ",\n") } else { emit_raw(e, "\n") }
				}
				emit_indent(e, indent)
				emit_raw(e, "],\n")
			}
		}
		emit_indent(e, indent)
		emit_println(e, "\"body\": {")
		print_class_body_inline(e, &s.body, indent + 1)
		emit_indent(e, indent)
		emit_print(e, "}")
		// `abstract` and `declare`: JS mode emits only when true (keeps JS
		// output minimal); TS-shape mode always emits (matches OXC's shape).
		if e.cfg.ts_shape {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"abstract\": ")
			emit_bool(e, s.expr.abstract)
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"declare\": ")
			emit_bool(e, s.expr.declare)
		} else {
			if s.expr.declare {
				emit_raw(e, ",\n")
				emit_indent(e, indent)
				emit_raw(e, "\"declare\": true")
			}
			if s.expr.abstract {
				emit_raw(e, ",\n")
				emit_indent(e, indent)
				emit_raw(e, "\"abstract\": true")
			}
		}

	case ^TryStatement:
		emit_println(e, ",")
		emit_indent(e, indent)
		emit_println(e, "\"block\": {")
		block := &s.block
		print_block_statement_inline(e, block, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_println(e, "},")
		emit_indent(e, indent)
		emit_print(e, "\"handler\": ")
		if handler, ok := s.handler.(CatchClause); ok {
			emit_println(e, "{")
			emit_indent(e, indent + 1)
			emit_println(e, "\"type\": \"CatchClause\",")
			emit_indent(e, indent + 1)
			emit_span_leading(e, handler.loc, indent + 1)
			emit_print(e, "\"param\": ")
			if param, ok2 := handler.param.(Pattern); ok2 {
				emit_println(e, "{")
				print_pattern_ast(e, param, indent + 2)
				emit_indent(e, indent + 1)
				emit_println(e, "},")
			} else {
				emit_println(e, "null,")
			}
			emit_indent(e, indent + 1)
			emit_println(e, "\"body\": {")
			body := handler.body
			print_block_statement_inline(e, &body, indent + 2)
			emit_raw(e, "\n")
			emit_indent(e, indent + 1)
			emit_println(e, "}")
			emit_indent(e, indent)
			emit_println(e, "},")
		} else {
			emit_println(e, "null,")
		}
		emit_indent(e, indent)
		emit_print(e, "\"finalizer\": ")
		if fin, ok := s.finalizer.(BlockStatement); ok {
			emit_println(e, "{")
			print_block_statement_inline(e, &fin, indent + 1)
			emit_raw(e, "\n")
			emit_indent(e, indent)
			emit_print(e, "}")
		} else {
			emit_print(e, "null")
		}

	case ^ExportNamedDeclaration:
		emit_println(e, ",")
		emit_indent(e, indent)
		emit_print(e, "\"declaration\": ")
		if decl, ok := s.declaration.(^Declaration); ok && decl != nil {
			emit_println(e, "{")
			print_declaration_ast(e, decl, indent + 1)
			emit_indent(e, indent)
			emit_println(e, "},")
		} else {
			emit_println(e, "null,")
		}
		emit_indent(e, indent)
		emit_raw(e, "\"specifiers\": [")
		if len(s.specifiers) == 0 {
			emit_raw(e, "],\n")
		} else {
			emit_raw(e, "\n")
			for spec, i in s.specifiers {
				emit_indent(e, indent + 1)
				emit_raw(e, "{\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"type\": \"ExportSpecifier\",\n")
				emit_indent(e, indent + 2)
				emit_span_leading(e, spec.loc, indent + 2)
				emit_raw(e, "\"local\": ")
				emit_export_specifier_name(e, spec.local, indent + 2)
				emit_raw(e, ",\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"exported\": ")
				emit_export_specifier_name(e, spec.exported, indent + 2)
				emit_raw(e, "\n")
				emit_indent(e, indent + 1)
				if i < len(s.specifiers) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
			}
			emit_indent(e, indent)
			emit_raw(e, "],\n")
		}
		emit_indent(e, indent)
		emit_raw(e, "\"source\": ")
		if src, ok := s.source.(StringLiteral); ok {
			emit_string_literal_object(e, src, indent)
		} else {
			emit_raw(e, "null")
		}
		// OXC always emits `attributes: []` on every Export* declaration.
		// See the equivalent block on ImportDeclaration for the rationale.
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"attributes\": [")
		if len(s.attributes) == 0 {
			emit_raw(e, "]")
		} else {
			emit_raw(e, "\n")
			for attr, i in s.attributes {
				emit_indent(e, indent + 1)
				emit_raw(e, "{\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"type\": \"ImportAttribute\",\n")
				emit_indent(e, indent + 2)
				emit_span_leading(e, attr.loc, indent + 2)
				emit_raw(e, "\"key\": ")
				emit_identifier_name_object(e, attr.key, indent + 2)
				emit_raw(e, ",\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"value\": ")
				emit_string_literal_object(e, attr.value, indent + 2)
				emit_raw(e, "\n")
				emit_indent(e, indent + 1)
				if i < len(s.attributes) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
			}
			emit_indent(e, indent)
			emit_raw(e, "]")
		}
		if e.cfg.ts_shape {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"exportKind\": \"")
			emit_raw(e, s.export_kind == .Type ? "type" : "value")
			emit_raw(e, "\"")
		}

	case ^ExportDefaultDeclaration:
		emit_println(e, ",")
		emit_indent(e, indent)
		emit_raw(e, "\"declaration\": ")
		if def := s.declaration; def != nil {
			emit_raw(e, "{\n")
			switch kind in def^ {
			case ^Declaration:
				if kind != nil {
					print_declaration_ast(e, kind, indent + 1)
				}
			case ^Expression:
				if kind != nil {
					print_expression_ast(e, kind, indent + 1)
				}
			}
			emit_indent(e, indent)
			emit_raw(e, "}")
		} else {
			emit_raw(e, "null")
		}

	case ^ExportAllDeclaration:
		emit_println(e, ",")
		emit_indent(e, indent)
		// ESTree ExportAllDeclaration has an `exported` field: null for
		// `export * from "x"`, an Identifier for `export * as ns from "x"`.
		emit_raw(e, "\"exported\": ")
		if exp, ok := s.exported.(IdentifierName); ok {
			emit_identifier_name_object(e, exp, indent)
		} else {
			emit_raw(e, "null")
		}
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"source\": ")
		emit_string_literal_object(e, s.source, indent)
		// Always emit attributes — see ImportDeclaration block above.
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"attributes\": [")
		if len(s.attributes) == 0 {
			emit_raw(e, "]")
		} else {
			emit_raw(e, "\n")
			for attr, i in s.attributes {
				emit_indent(e, indent + 1)
				emit_raw(e, "{\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"type\": \"ImportAttribute\",\n")
				emit_indent(e, indent + 2)
				emit_span_leading(e, attr.loc, indent + 2)
				emit_raw(e, "\"key\": ")
				emit_identifier_name_object(e, attr.key, indent + 2)
				emit_raw(e, ",\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"value\": ")
				emit_string_literal_object(e, attr.value, indent + 2)
				emit_raw(e, "\n")
				emit_indent(e, indent + 1)
				if i < len(s.attributes) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
			}
			emit_indent(e, indent)
			emit_raw(e, "]")
		}
		if e.cfg.ts_shape {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"exportKind\": \"")
			emit_raw(e, s.export_kind == .Type ? "type" : "value")
			emit_raw(e, "\"")
		}

	case ^DoWhileStatement:
		emit_println(e, ",")
		emit_indent(e, indent)
		emit_println(e, "\"body\": {")
		print_statement_ast(e, s.body, indent + 1)
		emit_indent(e, indent)
		emit_println(e, "},")
		emit_indent(e, indent)
		emit_println(e, "\"test\": {")
		print_expression_ast(e, s.test, indent + 1)
		emit_indent(e, indent)
		emit_print(e, "}")

	case ^SwitchStatement:
		emit_println(e, ",")
		emit_indent(e, indent)
		emit_println(e, "\"discriminant\": {")
		print_expression_ast(e, s.discriminant, indent + 1)
		emit_indent(e, indent)
		emit_println(e, "},")
		emit_indent(e, indent)
		emit_raw(e, "\"cases\": [")
		if len(s.cases) == 0 {
			emit_raw(e, "]")
		} else {
			emit_raw(e, "\n")
			for c, i in s.cases {
				emit_indent(e, indent + 1)
				emit_raw(e, "{\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"type\": \"SwitchCase\",\n")
				emit_indent(e, indent + 2)
				emit_span_leading(e, c.loc, indent + 2)
				emit_raw(e, "\"test\": ")
				if test_expr, ok := c.test.(^Expression); ok && test_expr != nil {
					emit_raw(e, "{\n")
					print_expression_ast(e, test_expr, indent + 3)
					emit_indent(e, indent + 2)
					emit_raw(e, "},\n")
				} else {
					emit_raw(e, "null,\n")
				}
				emit_indent(e, indent + 2)
				emit_raw(e, "\"consequent\": [")
				if len(c.consequent) == 0 {
					emit_raw(e, "]\n")
				} else {
					emit_raw(e, "\n")
					for cs, j in c.consequent {
						emit_indent(e, indent + 3)
						emit_raw(e, "{\n")
						print_statement_ast(e, cs, indent + 4)
						emit_indent(e, indent + 3)
						if j < len(c.consequent) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
					}
					emit_indent(e, indent + 2)
					emit_raw(e, "]\n")
				}
				emit_indent(e, indent + 1)
				if i < len(s.cases) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
			}
			emit_indent(e, indent)
			emit_raw(e, "]")
		}

	case ^ForInStatement:
		emit_println(e, ",")
		emit_indent(e, indent)
		emit_print(e, "\"left\": ")
		if decl, ok := s.left_decl.(^VariableDeclaration); ok {
			emit_println(e, "{")
			emit_indent(e, indent + 1)
			emit_raw(e, "\"type\": \"VariableDeclaration\"")
			emit_span_fields(e, decl.loc, indent + 1)
			print_variable_declaration_body(e, decl, indent + 1)
			emit_raw(e, "\n")
			emit_indent(e, indent)
			emit_println(e, "},")
		} else if expr, ok2 := s.left_expr.(^Expression); ok2 {
			// `for (LHS in RHS)` — LHS is a destructuring target. Route through
			// print_expression_as_pattern so array/object literals become
			// ArrayPattern/ObjectPattern and inner `a = default` defaults
			// become AssignmentPattern per ESTree. Identifier and
			// MemberExpression targets pass through unchanged.
			emit_println(e, "{")
			print_expression_as_pattern(e, expr, indent + 1)
			emit_raw(e, "\n")
			emit_indent(e, indent)
			emit_println(e, "},")
		} else {
			emit_println(e, "null,")
		}
		emit_indent(e, indent)
		emit_println(e, "\"right\": {")
		print_expression_ast(e, s.right, indent + 1)
		emit_indent(e, indent)
		emit_println(e, "},")
		emit_indent(e, indent)
		emit_println(e, "\"body\": {")
		print_statement_ast(e, s.body, indent + 1)
		emit_indent(e, indent)
		emit_print(e, "}")

	case ^ForOfStatement:
		emit_println(e, ",")
		emit_indent(e, indent)
		emit_print(e, "\"left\": ")
		if decl, ok := s.left_decl.(^VariableDeclaration); ok {
			emit_println(e, "{")
			emit_indent(e, indent + 1)
			emit_raw(e, "\"type\": \"VariableDeclaration\"")
			emit_span_fields(e, decl.loc, indent + 1)
			print_variable_declaration_body(e, decl, indent + 1)
			emit_raw(e, "\n")
			emit_indent(e, indent)
			emit_println(e, "},")
		} else if expr, ok2 := s.left_expr.(^Expression); ok2 {
			// `for (LHS of RHS)` — LHS is a destructuring target. See the
			// ForInStatement case above for the rationale; same conversion.
			emit_println(e, "{")
			print_expression_as_pattern(e, expr, indent + 1)
			emit_raw(e, "\n")
			emit_indent(e, indent)
			emit_println(e, "},")
		} else {
			emit_println(e, "null,")
		}
		emit_indent(e, indent)
		emit_println(e, "\"right\": {")
		print_expression_ast(e, s.right, indent + 1)
		emit_indent(e, indent)
		emit_println(e, "},")
		emit_indent(e, indent)
		emit_print(e, "\"await\": ")
		if s.await {
			emit_println(e, "true,")
		} else {
			emit_println(e, "false,")
		}
		emit_indent(e, indent)
		emit_println(e, "\"body\": {")
		print_statement_ast(e, s.body, indent + 1)
		emit_indent(e, indent)
		emit_print(e, "}")
		// (pre-refactor dead code that emitted a second "await"/"body" pair
		// has been removed; it was unreachable after the body emit above.)

	case ^ThrowStatement:
		emit_println(e, ",")
		emit_indent(e, indent)
		emit_println(e, "\"argument\": {")
		print_expression_ast(e, s.argument, indent + 1)
		emit_indent(e, indent)
		emit_print(e, "}")

	case ^ImportDeclaration:
		emit_println(e, ",")
		emit_indent(e, indent)
		emit_raw(e, "\"specifiers\": [")
		if len(s.specifiers) == 0 {
			emit_raw(e, "],\n")
		} else {
			emit_raw(e, "\n")
			for spec_ptr, i in s.specifiers {
				emit_indent(e, indent + 1)
				emit_raw(e, "{\n")
				if spec_ptr != nil {
					switch v in spec_ptr^ {
					case ImportSpecifier:
						emit_indent(e, indent + 2)
						emit_raw(e, "\"type\": \"ImportSpecifier\",\n")
						emit_indent(e, indent + 2)
						emit_span_leading(e, v.loc, indent + 2)
						emit_raw(e, "\"imported\": ")
						emit_identifier_name_object(e, v.imported, indent + 2)
						emit_raw(e, ",\n")
						emit_indent(e, indent + 2)
						emit_raw(e, "\"local\": ")
						emit_binding_identifier_object(e, v.local, indent + 2)
						if e.cfg.ts_shape {
							// TS-ESTree: OXC emits importKind on every specifier.
							// "type" for `import { type X }`, "value" otherwise.
							emit_raw(e, ",\n")
							emit_indent(e, indent + 2)
							emit_raw(e, "\"importKind\": \"value\"")
						}
						emit_raw(e, "\n")
					case ImportDefaultSpecifier:
						emit_indent(e, indent + 2)
						emit_raw(e, "\"type\": \"ImportDefaultSpecifier\",\n")
						emit_indent(e, indent + 2)
						emit_span_leading(e, v.loc, indent + 2)
						emit_raw(e, "\"local\": ")
						emit_binding_identifier_object(e, v.local, indent + 2)
						emit_raw(e, "\n")
					case ImportNamespaceSpecifier:
						emit_indent(e, indent + 2)
						emit_raw(e, "\"type\": \"ImportNamespaceSpecifier\",\n")
						emit_indent(e, indent + 2)
						emit_span_leading(e, v.loc, indent + 2)
						emit_raw(e, "\"local\": ")
						emit_binding_identifier_object(e, v.local, indent + 2)
						emit_raw(e, "\n")
					}
				}
				emit_indent(e, indent + 1)
				if i < len(s.specifiers) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
			}
			emit_indent(e, indent)
			emit_raw(e, "],\n")
		}
		emit_indent(e, indent)
		emit_raw(e, "\"source\": ")
		emit_string_literal_object(e, s.source, indent)
		if s.import_kind == .Type {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"importKind\": \"type\"")
		}
		// Always emit `attributes` on ImportDeclaration (even when empty) to
		// match OXC's shape — OXC writes `attributes: []` on every import,
		// and the verifier expects both sides to agree. Previously this
		// branch skipped the field when empty, which only matched because
		// the verifier separately stripped it from OXC; removing that strip
		// exposed the asymmetry on every non-import-attributes import
		// (observed as 16 snabbdom divergences + 7 chalk + 1 each on
		// zod/petite-vue when we dropped the strip rule).
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"attributes\": [")
		if len(s.attributes) == 0 {
			emit_raw(e, "]")
		} else {
			emit_raw(e, "\n")
			for attr, i in s.attributes {
				emit_indent(e, indent + 1)
				emit_raw(e, "{\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"type\": \"ImportAttribute\",\n")
				emit_indent(e, indent + 2)
				emit_span_leading(e, attr.loc, indent + 2)
				emit_raw(e, "\"key\": ")
				emit_identifier_name_object(e, attr.key, indent + 2)
				emit_raw(e, ",\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"value\": ")
				emit_string_literal_object(e, attr.value, indent + 2)
				emit_raw(e, "\n")
				emit_indent(e, indent + 1)
				if i < len(s.attributes) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
			}
			emit_indent(e, indent)
			emit_raw(e, "]")
		}
		// Phase Imports stage-3 `phase` field. null for plain
		// `import x from ...`, "defer" for `import defer * as ns from ...`,
		// "source" for `import source x from ...`. Matches OXC shape.
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"phase\": ")
		if s.phase == "" {
			emit_raw(e, "null")
		} else {
			emit_str(e, s.phase)
		}

	case ^BreakStatement:
		emit_println(e, ",")
		emit_indent(e, indent)
		if label, ok := s.label.(LabelIdentifier); ok {
			emit_println(e, "\"label\": {")
			emit_indent(e, indent + 1)
			emit_raw(e, "\"type\": \"Identifier\",\n")
			emit_indent(e, indent + 1)
			emit_span_leading(e, label.loc, indent + 1)
			emit_raw(e, "\"name\": ")
			emit_str(e, label.name)
			emit_raw(e, "\n")
			emit_indent(e, indent)
			emit_print(e, "}")
		} else {
			emit_print(e, "\"label\": null")
		}

	case ^ContinueStatement:
		emit_println(e, ",")
		emit_indent(e, indent)
		if label, ok := s.label.(LabelIdentifier); ok {
			emit_println(e, "\"label\": {")
			emit_indent(e, indent + 1)
			emit_raw(e, "\"type\": \"Identifier\",\n")
			emit_indent(e, indent + 1)
			emit_span_leading(e, label.loc, indent + 1)
			emit_raw(e, "\"name\": ")
			emit_str(e, label.name)
			emit_raw(e, "\n")
			emit_indent(e, indent)
			emit_print(e, "}")
		} else {
			emit_print(e, "\"label\": null")
		}

	case ^LabeledStatement:
		emit_println(e, ",")
		emit_indent(e, indent)
		emit_println(e, "\"label\": {")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"Identifier\",\n")
		emit_indent(e, indent + 1)
		emit_span_leading(e, s.label.loc, indent + 1)
		emit_raw(e, "\"name\": ")
		emit_str(e, s.label.name)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_println(e, "},")
		emit_indent(e, indent)
		emit_println(e, "\"body\": {")
		print_statement_ast(e, s.body, indent + 1)
		emit_indent(e, indent)
		emit_print(e, "}")

	case ^WithStatement:
		emit_println(e, ",")
		emit_indent(e, indent)
		emit_println(e, "\"object\": {")
		print_expression_ast(e, s.object, indent + 1)
		emit_indent(e, indent)
		emit_println(e, "},")
		emit_indent(e, indent)
		emit_println(e, "\"body\": {")
		print_statement_ast(e, s.body, indent + 1)
		emit_indent(e, indent)
		emit_print(e, "}")

	case ^EmptyStatement:
		// No additional fields

	case ^DebuggerStatement:
		// No additional fields

	case ^TSInterfaceDeclaration:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"id\": {\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"Identifier\",\n")
		emit_indent(e, indent + 1)
		emit_span_leading(e, s.id.loc, indent + 1)
		emit_raw(e, "\"name\": ")
		emit_str(e, s.id.name)
		// typeAnnotation + optional: OXC always emits both on the interface
		// id in TS-shape mode (S26 W4: added optional alongside the
		// existing typeAnnotation).
		if e.cfg.ts_shape {
			emit_raw(e, ",\n")
			emit_indent(e, indent + 1)
			emit_raw(e, "\"typeAnnotation\": null,\n")
			emit_indent(e, indent + 1)
			emit_raw(e, "\"optional\": false")
		}
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		emit_indent(e, indent)
		emit_raw(e, "\"typeParameters\": ")
		emit_ts_type_parameter_declaration(e, s.type_parameters, indent)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"extends\": [")
		if len(s.extends) == 0 {
			emit_raw(e, "],\n")
		} else {
			emit_raw(e, "\n")
			for h, i in s.extends {
				emit_ts_heritage_entry(e, h, "TSInterfaceHeritage", indent + 1)
				if i < len(s.extends) - 1 { emit_raw(e, ",\n") } else { emit_raw(e, "\n") }
			}
			emit_indent(e, indent)
			emit_raw(e, "],\n")
		}
		emit_indent(e, indent)
		emit_raw(e, "\"body\": {\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSInterfaceBody\"")
		emit_span_fields(e, s.body.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"body\": [")
		if len(s.body.body) == 0 {
			emit_raw(e, "]\n")
		} else {
			emit_raw(e, "\n")
			for member, i in s.body.body {
				emit_indent(e, indent + 2)
				emit_ts_signature(e, member, indent + 2)
				if i < len(s.body.body) - 1 { emit_raw(e, ",\n") } else { emit_raw(e, "\n") }
			}
			emit_indent(e, indent + 1)
			emit_raw(e, "]\n")
		}
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		emit_indent(e, indent)
		emit_raw(e, "\"declare\": ")
		emit_bool(e, s.declare)

	case ^TSTypeAliasDeclaration:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"id\": ")
		emit_identifier_name_object(e, IdentifierName{loc = s.id.loc, name = s.id.name}, indent)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"typeParameters\": ")
		emit_ts_type_parameter_declaration(e, s.type_parameters, indent)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"typeAnnotation\": ")
		emit_ts_type(e, s.type_annotation, indent)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"declare\": ")
		emit_bool(e, s.declare)

	case ^TSEnumDeclaration:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"id\": {\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"Identifier\",\n")
		emit_indent(e, indent + 1)
		emit_span_leading(e, s.id.loc, indent + 1)
		emit_raw(e, "\"name\": ")
		emit_str(e, s.id.name)
		// TS-ESTree shape: OXC always emits `typeAnnotation: null` and
		// `optional: false` on enum identifiers (S26 W4: added optional).
		if e.cfg.ts_shape {
			emit_raw(e, ",\n")
			emit_indent(e, indent + 1)
			emit_raw(e, "\"typeAnnotation\": null,\n")
			emit_indent(e, indent + 1)
			emit_raw(e, "\"optional\": false")
		}
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		emit_indent(e, indent)
		emit_raw(e, "\"body\": {\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSEnumBody\"")
		emit_span_fields(e, s.body.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"members\": [\n")
		for m, i in s.body.members {
			emit_indent(e, indent + 2)
			emit_raw(e, "{\n")
			emit_indent(e, indent + 3)
			emit_raw(e, "\"type\": \"TSEnumMember\"")
			emit_span_fields(e, m.loc, indent + 3)
			emit_raw(e, ",\n")
			emit_indent(e, indent + 3)
			emit_raw(e, "\"id\": {\n")
			print_expression_ast(e, m.id, indent + 4)
			emit_raw(e, "\n")
			emit_indent(e, indent + 3)
			emit_raw(e, "},\n")
			// OXC emits `computed: false` on every TSEnumMember (enum keys
			// are never computed); Kessel previously omitted it entirely.
			emit_indent(e, indent + 3)
			emit_raw(e, "\"computed\": false,\n")
			emit_indent(e, indent + 3)
			emit_raw(e, "\"initializer\": ")
			if init, ok := m.initializer.(^Expression); ok {
				emit_raw(e, "{\n")
				print_expression_ast(e, init, indent + 4)
				emit_raw(e, "\n")
				emit_indent(e, indent + 3)
				emit_raw(e, "}")
			} else {
				emit_raw(e, "null")
			}
			emit_raw(e, "\n")
			emit_indent(e, indent + 2)
			if i < len(s.body.members) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
		}
		emit_indent(e, indent + 1)
		emit_raw(e, "]\n")
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		emit_indent(e, indent)
		emit_raw(e, "\"const\": ")
		emit_bool(e, s.const_)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"declare\": ")
		emit_bool(e, s.declare)

	case ^TSModuleDeclaration:
		// S26 W4b: fold the qualified-name desugar chain into OXC's flat
		// shape — single TSModuleDeclaration with a TSQualifiedName id
		// and the deepest TSModuleBlock body.
		emit_ts_module_decl_fields(e, s, indent)

	case ^TSImportEqualsDeclaration:
		// S26 W6 phase 3 bug class #4. ESTree TS-shape:
		//   { type, start, end, id: Identifier, moduleReference, importKind }
		// moduleReference shapes:
		//   * Identifier         (`= N`)
		//   * TSQualifiedName    (`= A.B.C` — fold MemberExpression chain)
		//   * TSExternalModuleReference (`= require("m")`)
		// Use emit_identifier_name_object so the `id` Identifier carries the
		// full TS-shape footer (`typeAnnotation: null, optional: false`); the
		// hand-rolled inline form was missing those fields and produced 8
		// divergences against OXC on the spec/typescript/020 fixture.
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"id\": ")
		emit_identifier_name_object(e, IdentifierName{loc = s.id.loc, name = s.id.name}, indent)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"moduleReference\": ")
		emit_ts_module_reference(e, s.module_reference, indent)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"importKind\": \"")
		switch s.import_kind {
		case .Type:  emit_raw(e, "type")
		case .Value: emit_raw(e, "value")
		}
		emit_raw(e, "\"")

	case ^TSExportAssignment:
		// `export = <expr>;` — single-field shape: { expression }.
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"expression\": {\n")
		print_expression_ast(e, s.expression, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")

	case ^TSNamespaceExportDeclaration:
		// `export as namespace N;` — single-field shape: { id: Identifier }.
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"id\": ")
		emit_identifier_name_object(e, IdentifierName{loc = s.id.loc, name = s.id.name}, indent)

	case:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"[UNIMPLEMENTED]\": true")
	}
}

// Emit a TSImportEqualsDeclaration's moduleReference field. Closes over
// the three legal shapes:
//   * ^TSExternalModuleReference — emit directly
//   * ^Expression that's a bare ^Identifier — emit as Identifier
//   * ^Expression that's a MemberExpression chain — flatten left-deep into
//     a TSQualifiedName tree by collecting the chain's identifiers and
//     reusing emit_ts_module_qualified_id (the same helper that backs
//     TSModuleDeclaration's `namespace A.B.C { ... }` id emission).
emit_ts_module_reference :: proc(e: ^Emitter, ref: TSModuleReference, indent: int) {
	switch r in ref {
	case ^TSExternalModuleReference:
		emit_raw(e, "{\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSExternalModuleReference\"")
		emit_span_fields(e, r.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"expression\": {\n")
		print_expression_ast(e, expression_from_str(r.expression), indent + 2)
		emit_raw(e, "\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "}\n")
		emit_indent(e, indent)
		emit_raw(e, "}")
	case ^Expression:
		// Walk the MemberExpression chain to a flat []^Expression, then reuse
		// emit_ts_module_qualified_id which handles both 1-element (bare
		// identifier) and N-element (left-deep TSQualifiedName fold).
		ids := make([dynamic]^Expression, 0, 4, context.temp_allocator)
		walk: ^Expression = r
		for walk != nil {
			if mem, ok := walk^.(^MemberExpression); ok && mem != nil && !mem.computed {
				append(&ids, mem.property)
				walk = mem.object
			} else {
				append(&ids, walk)
				break
			}
		}
		// Reverse: collected right-to-left, emit_ts_module_qualified_id wants
		// left-to-right.
		for i := 0; i < len(ids) / 2; i += 1 {
			j := len(ids) - 1 - i
			ids[i], ids[j] = ids[j], ids[i]
		}
		emit_ts_module_qualified_id(e, ids[:], indent)
	}
}

// Wrap a ^StringLiteral in an ^Expression for print_expression_ast — used
// by emit_ts_module_reference's TSExternalModuleReference arm.
expression_from_str :: proc(s: ^StringLiteral) -> ^Expression {
	e := new(Expression, context.temp_allocator)
	e^ = s
	return e
}

// Map TSModuleKind to its OXC string label. `namespace`, `module`, and
// `global` correspond to `namespace Foo {}`, `declare module 'x' {}`, and
// `declare global {}`. Emitted unconditionally on every TSModuleDeclaration
// (S26 W4).
ts_module_kind_label :: proc(kind: TSModuleKind) -> string {
	switch kind {
	case .Namespace: return "namespace"
	case .Module:    return "module"
	case .Global:    return "global"
	}
	return "namespace"
}

// Walk the qualified-name desugar chain starting at `m`. Kessel's parser
// represents `namespace A.B.C {}` as a chain of nested TSModuleDeclaration
// nodes whose body slots hold ^TSModuleDeclaration (not ^TSModuleBlock).
// OXC instead emits a single TSModuleDeclaration with a left-deep
// TSQualifiedName id and a TSModuleBlock body. This walker collects the
// chain so the emitter can fold it into OXC's shape (S26 W4b).
//
// Returns:
//   ids[]            — the id ^Expression at each level, leftmost first
//   deepest          — the deepest TSModuleDeclaration in the chain
//                      (caller pulls .body and the per-decl flags from it)
//
// User-written nested namespaces (`namespace A { namespace B {} }`) parse
// as TSModuleDeclaration -> ^TSModuleBlock -> Statement -> TSModuleDeclaration,
// which terminates this walker after the first link, leaving the user's
// shape intact.
ts_module_chain :: proc(m: ^TSModuleDeclaration) -> ([dynamic]^Expression, ^TSModuleDeclaration) {
	ids := make([dynamic]^Expression, 0, 4, context.temp_allocator)
	cur := m
	append(&ids, cur.id)
	for {
		body_union, ok := cur.body.(^TSModuleBody)
		if !ok || body_union == nil { break }
		inner, is_decl := body_union^.(^TSModuleDeclaration)
		if !is_decl || inner == nil { break }
		cur = inner
		append(&ids, cur.id)
	}
	return ids, cur
}

// Emit the `id` field for a TSModuleDeclaration whose qualified-name
// chain has been collected by ts_module_chain. A single id passes through
// as a plain Identifier; two or more fold left-deep into a recursive
// TSQualifiedName tree matching OXC's shape:
//
//   ids = [A]              -> { Identifier A }
//   ids = [A, B]           -> TSQualifiedName{ left: A, right: B }
//   ids = [A, B, C]        -> TSQualifiedName{ left: TSQualifiedName{A,B}, right: C }
//
// Each TSQualifiedName carries `start` = leftmost id's start and `end` =
// rightmost id's end at its level, matching OXC's per-segment span
// accumulation.
emit_ts_module_qualified_id :: proc(e: ^Emitter, ids: []^Expression, indent: int) {
	if len(ids) == 1 {
		emit_raw(e, "{\n")
		print_expression_ast(e, ids[0], indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")
		return
	}
	// 2+ — fold left-deep. The right side is always the last id.
	left_ids  := ids[:len(ids)-1]
	right_id  := ids[len(ids)-1]
	left_loc  := get_expression_loc(ids[0])
	right_loc := get_expression_loc(right_id)
	span := Loc{start = left_loc.start, end = right_loc.end}

	emit_raw(e, "{\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"type\": \"TSQualifiedName\"")
	emit_span_fields(e, span, indent + 1)
	emit_raw(e, ",\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"left\": ")
	emit_ts_module_qualified_id(e, left_ids, indent + 1)
	emit_raw(e, ",\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"right\": {\n")
	print_expression_ast(e, right_id, indent + 2)
	emit_raw(e, "\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "}\n")
	emit_indent(e, indent)
	emit_raw(e, "}")
}

// Helper used by the inline TSModuleBody emitter — when the union variant
// is ^TSModuleDeclaration we want the SAME fold + flatten as the top-level
// case, not a recursive nested-decl emit. emit_ts_module_decl_fields
// handles both, parameterised on the indent base.
emit_ts_module_decl_fields :: proc(e: ^Emitter, m: ^TSModuleDeclaration, indent: int) {
	ids, deepest := ts_module_chain(m)
	emit_raw(e, ",\n")
	emit_indent(e, indent)
	emit_raw(e, "\"id\": ")
	emit_ts_module_qualified_id(e, ids[:], indent)
	emit_raw(e, ",\n")
	emit_indent(e, indent)
	emit_raw(e, "\"body\": ")
	if body_union, ok := deepest.body.(^TSModuleBody); ok && body_union != nil {
		emit_ts_module_body(e, body_union, indent)
	} else {
		emit_raw(e, "null")
	}
	emit_raw(e, ",\n")
	emit_indent(e, indent)
	emit_raw(e, "\"kind\": ")
	emit_str(e, ts_module_kind_label(m.kind))
	emit_raw(e, ",\n")
	emit_indent(e, indent)
	emit_raw(e, "\"global\": ")
	emit_bool(e, m.global)
	emit_raw(e, ",\n")
	emit_indent(e, indent)
	emit_raw(e, "\"declare\": ")
	emit_bool(e, m.declare)
}

print_pattern_ast :: proc(e: ^Emitter, pattern: Pattern, indent: int) {
	// MemberExpression delegates to print_expression_ast which has its own
	// span emission; every other pattern variant emits type + span here.
	#partial switch p in pattern {
	case ^Identifier:
		emit_indent(e, indent)
		emit_raw(e, "\"type\": \"Identifier\",\n")
		emit_indent(e, indent)
		emit_span_leading(e, p.loc, indent)
		emit_raw(e, "\"name\": ")
		emit_str(e, p.name)
		// TypeScript type annotation on binding identifier. In TS-shape mode
		// always emit the field (null when absent) so the AST matches OXC's
		// TS-ESTree shape; in JS mode omit the field when null.
		if ann, ok := p.type_annotation.(^TSTypeAnnotation); ok {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"typeAnnotation\": ")
			emit_ts_type_annotation_node(e, ann, indent)
		} else if e.cfg.ts_shape {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"typeAnnotation\": null")
		}
		// S26 W4: TS-ESTree always emits `optional: false` on every binding
		// Identifier, even ones with no `?` marker (parameters and class
		// fields are the obvious carriers, but OXC emits it on plain `let x`
		// declarators too). The Identifier struct doesn't carry an
		// `optional` flag yet — every binding-position Identifier in source
		// today is non-optional, so emit a hard-coded `false`.
		if e.cfg.ts_shape {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"optional\": false")
		}
	case ^RestElement:
		// ESTree `RestElement { argument: Pattern }` - the `...x` inside
		// `[a, ...x]` or `{ a, ...x }`. Prior to this case the fallthrough
		// `case:` produced bare `null`, which the ArrayPattern.elements loop
		// wrapped in `{...}` - emitting invalid `{null}` JSON.
		emit_indent(e, indent)
		emit_raw(e, "\"type\": \"RestElement\",\n")
		emit_indent(e, indent)
		emit_span_leading(e, p.loc, indent)
		emit_raw(e, "\"argument\": {\n")
		print_pattern_ast(e, p.argument, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")
	case ^AssignmentPattern:
		// ESTree `AssignmentPattern { left: Pattern, right: Expression }` -
		// the `x = 1` inside `{ x = 1 }` or `[x = 1]`. Same JSON-validity
		// rationale as RestElement above.
		emit_indent(e, indent)
		emit_raw(e, "\"type\": \"AssignmentPattern\",\n")
		emit_indent(e, indent)
		emit_span_leading(e, p.loc, indent)
		emit_raw(e, "\"left\": {\n")
		print_pattern_ast(e, p.left, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		emit_indent(e, indent)
		emit_raw(e, "\"right\": {\n")
		print_expression_ast(e, p.right, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")
		// S26 W4: TS-shape footer — OXC always emits `optional: false` and
		// a `typeAnnotation` field on every Pattern node, including
		// AssignmentPattern. The default for the latter is null since the
		// `: T` annotation in `function f(x: T = 1)` lives on the inner
		// Identifier, not on the AssignmentPattern wrapper itself.
		if e.cfg.ts_shape {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"optional\": false,\n")
			emit_indent(e, indent)
			emit_raw(e, "\"typeAnnotation\": null")
		}
	case ^MemberExpression:
		// Destructuring target like `({a} = obj, foo.bar = 1)`. ESTree emits
		// the MemberExpression inline in the pattern position. Rebuild a local
		// Expression union - we can't take `&pattern` (procedure parameter), so
		// allocate on the stack.
		expr: Expression = p
		print_expression_ast(e, &expr, indent)
	case ^ArrayPattern:
		emit_indent(e, indent)
		emit_raw(e, "\"type\": \"ArrayPattern\",\n")
		emit_indent(e, indent)
		emit_span_leading(e, p.loc, indent)
		emit_raw(e, "\"elements\": [")
		if len(p.elements) == 0 {
			emit_raw(e, "]")
		} else {
			emit_raw(e, "\n")
			for elem, i in p.elements {
				if pat, ok := elem.(Pattern); ok {
					emit_indent(e, indent + 1)
					emit_raw(e, "{\n")
					print_pattern_ast(e, pat, indent + 2)
					emit_raw(e, "\n")
					emit_indent(e, indent + 1)
					if i < len(p.elements) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
				} else {
					// Hole in destructuring (e.g. `[,,x]`) - ESTree emits `null`.
					emit_indent(e, indent + 1)
					if i < len(p.elements) - 1 { emit_raw(e, "null,\n") } else { emit_raw(e, "null\n") }
				}
			}
			emit_indent(e, indent)
			emit_raw(e, "]")
		}
		// S26 W4: TS-ESTree always emits `optional: false` and a
		// `typeAnnotation` field on every Pattern node, regardless of
		// whether the source has a `?` marker or `:T` annotation.
		// S26 W4b: ArrayPattern.type_annotation is now a real AST slot
		// populated by parse_function_param when the source has
		// `function f([a, b]: T)`; emit the actual annotation when set,
		// `null` otherwise.
		if e.cfg.ts_shape {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"optional\": false,\n")
			emit_indent(e, indent)
			emit_raw(e, "\"typeAnnotation\": ")
			if ann, ok := p.type_annotation.(^TSTypeAnnotation); ok {
				emit_ts_type_annotation_node(e, ann, indent)
			} else {
				emit_raw(e, "null")
			}
		}
	case ^ObjectPattern:
		emit_indent(e, indent)
		emit_raw(e, "\"type\": \"ObjectPattern\",\n")
		emit_indent(e, indent)
		emit_span_leading(e, p.loc, indent)
		emit_raw(e, "\"properties\": [")
		if len(p.properties) == 0 {
			emit_raw(e, "]")
		} else {
			emit_raw(e, "\n")
			for prop, i in p.properties {
				// ESTree: `ObjectPattern.properties` is a heterogeneous list of
				// `Property` OR `RestElement`. Our parser stashes the rest element
				// as an `ObjectPatternProperty { key: nil, value: ^RestElement }`
				// because it reuses the same struct - but the emit must unwrap
				// it: emit a bare `RestElement`, NOT a `Property` wrapper with a
				// `RestElement` value. Detected by the prop.key being nil.
				if _, is_rest := prop.value.(^RestElement); is_rest {
					emit_indent(e, indent + 1)
					emit_raw(e, "{\n")
					print_pattern_ast(e, prop.value, indent + 2)
					emit_raw(e, "\n")
					emit_indent(e, indent + 1)
					if i < len(p.properties) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
					continue
				}
				emit_indent(e, indent + 1)
				emit_raw(e, "{\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"type\": \"Property\",\n")
				emit_indent(e, indent + 2)
				emit_span_leading(e, prop.loc, indent + 2)
				emit_raw(e, "\"shorthand\": ")
				emit_bool(e, prop.shorthand)
				emit_raw(e, ",\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"computed\": ")
				emit_bool(e, prop.computed)
				emit_raw(e, ",\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"kind\": \"init\",\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"method\": false,\n")
				// S26 W4: TS-ESTree emits `optional: false` on Property,
				// even in a pattern position. ObjectPatternProperty doesn't
				// carry an optional flag (no source syntax for it), so emit
				// the placeholder unconditionally in TS-shape mode.
				if e.cfg.ts_shape {
					emit_indent(e, indent + 2)
					emit_raw(e, "\"optional\": false,\n")
				}
				// key: ObjectPatternPropertyKey is a union of IdentifierName,
				// ^StringLiteral, or ^Expression (for computed). Previously omitted
				// entirely - OXC emits the key as an Identifier/Literal/Expression
				// inline, so the prior output silently dropped 1 string literal
				// per `{ 'aria-label': x }`-style destructure (antd.js et al.).
				emit_indent(e, indent + 2)
				emit_raw(e, "\"key\": ")
				if key, ok := prop.key.(ObjectPatternPropertyKey); ok {
					switch k in key {
					case IdentifierName:
						// emit_identifier_name_object writes its own opening/closing braces.
						emit_identifier_name_object(e, k, indent + 2)
					case ^StringLiteral:
						emit_raw(e, "{\n")
						emit_indent(e, indent + 3)
						emit_raw(e, "\"type\": \"Literal\",\n")
						emit_indent(e, indent + 3)
						emit_span_leading(e, k.loc, indent + 3)
						emit_raw(e, "\"value\": ")
						emit_str(e, k.value)
						emit_raw(e, ",\n")
						emit_indent(e, indent + 3)
						emit_raw(e, "\"raw\": ")
						emit_str(e, k.raw)
						emit_raw(e, "\n")
						emit_indent(e, indent + 2)
						emit_raw(e, "}")
					case ^Expression:
						emit_raw(e, "{\n")
						print_expression_ast(e, k, indent + 3)
						emit_raw(e, "\n")
						emit_indent(e, indent + 2)
						emit_raw(e, "}")
					case ^NumericLiteral:
						// §14.3.3 PropertyName : NumericLiteral — ESTree emits
						// as a plain Literal with `value` and `raw`. Matches
						// the main NumericLiteral path (Inf / NaN substitution).
						emit_raw(e, "{\n")
						emit_indent(e, indent + 3)
						emit_raw(e, "\"type\": \"Literal\",\n")
						emit_indent(e, indent + 3)
						emit_span_leading(e, k.loc, indent + 3)
						emit_raw(e, "\"value\": ")
						if math.classify_f64(k.value) == .Inf {
							emit_raw(e, k.value > 0 ? "1e+400" : "-1e+400")
						} else if math.classify_f64(k.value) == .NaN {
							emit_raw(e, "null")
						} else {
							emit_printf(e, "%v", k.value)
						}
						emit_raw(e, ",\n")
						emit_indent(e, indent + 3)
						emit_raw(e, "\"raw\": ")
						emit_str(e, k.raw)
						emit_raw(e, "\n")
						emit_indent(e, indent + 2)
						emit_raw(e, "}")
					}
				} else {
					emit_raw(e, "null")
				}
				emit_raw(e, ",\n")
				emit_indent(e, indent + 2)
				// Every remaining Pattern variant has a real emit case in
				// print_pattern_ast now (Identifier / ArrayPattern / ObjectPattern
				// / AssignmentPattern / MemberExpression), so wrapping in `{...}`
				// is always safe.
				emit_raw(e, "\"value\": {\n")
				print_pattern_ast(e, prop.value, indent + 3)
				emit_raw(e, "\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "}\n")
				emit_indent(e, indent + 1)
				if i < len(p.properties) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
			}
			emit_indent(e, indent)
			emit_raw(e, "]")
		}
		// S26 W4 / W4b: same TS-shape footer as ArrayPattern — OXC always
		// emits `optional: false` and a `typeAnnotation` field, with the
		// real annotation when `function f({a, b}: T)` puts one on the
		// ObjectPattern.
		if e.cfg.ts_shape {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"optional\": false,\n")
			emit_indent(e, indent)
			emit_raw(e, "\"typeAnnotation\": ")
			if ann, ok := p.type_annotation.(^TSTypeAnnotation); ok {
				emit_ts_type_annotation_node(e, ann, indent)
			} else {
				emit_raw(e, "null")
			}
		}
	case:
		emit_indent(e, indent)
		emit_raw(e, "null")
	}
}

// print_expression_as_pattern emits an ^Expression as ESTree pattern JSON.
// Called from destructuring-target positions where the parser records an
// expression (AssignmentExpression.left with operator `=`, ForIn/ForOfStatement
// .left_expr) but ESTree requires a Pattern node:
//
//   ArrayExpression      → ArrayPattern
//   ObjectExpression     → ObjectPattern (Property[].value re-patternised)
//   AssignmentExpression → AssignmentPattern (only when operator is `=`)
//   SpreadElement        → RestElement
//   Identifier / MemberExpression → emit as expression (valid pattern targets)
//
// Prior to this helper, destructuring-target array/object literals were
// routed inline from `case ^AssignmentExpression` (one ad-hoc branch) and
// for-in/of `left_expr` skipped the conversion entirely. Both paths emitted
// inner `AssignmentExpression` nodes where ESTree expects `AssignmentPattern`,
// desynchronising walkers (visitor.js, eslint, any ESTree consumer) the moment
// they descend into `ForOfStatement.left.elements[*]`. Symptom: 6 real
// divergences against OXC in antd.js plus ~19 cascading false-positives.
// Centralising the conversion here makes all pattern positions go through a
// single recursive emitter that mirrors OXC's shape exactly.
print_expression_as_pattern :: proc(e: ^Emitter, expr: ^Expression, indent: int) {
	if expr == nil {
		emit_indent(e, indent)
		emit_raw(e, "null")
		return
	}
	#partial switch n in expr^ {
	case ^ArrayExpression:
		emit_indent(e, indent)
		emit_raw(e, "\"type\": \"ArrayPattern\",\n")
		emit_indent(e, indent)
		emit_span_leading(e, n.loc, indent)
		emit_raw(e, "\"elements\": [")
		if len(n.elements) == 0 {
			emit_raw(e, "]")
		} else {
			emit_raw(e, "\n")
			for elem, i in n.elements {
				if el, ok := elem.(^Expression); ok && el != nil {
					emit_indent(e, indent + 1)
					emit_raw(e, "{\n")
					print_expression_as_pattern(e, el, indent + 2)
					emit_raw(e, "\n")
					emit_indent(e, indent + 1)
					if i < len(n.elements) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
				} else {
					// Sparse hole (n.g. `[, , x] = arr`) — ESTree emits null.
					emit_indent(e, indent + 1)
					if i < len(n.elements) - 1 { emit_raw(e, "null,\n") } else { emit_raw(e, "null\n") }
				}
			}
			emit_indent(e, indent)
			emit_raw(e, "]")
		}
		// Mirror the print_pattern_ast ArrayPattern footer (S26 W4).
		if e.cfg.ts_shape {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"optional\": false,\n")
			emit_indent(e, indent)
			emit_raw(e, "\"typeAnnotation\": null")
		}
	case ^ObjectExpression:
		emit_indent(e, indent)
		emit_raw(e, "\"type\": \"ObjectPattern\",\n")
		emit_indent(e, indent)
		emit_span_leading(e, n.loc, indent)
		emit_raw(e, "\"properties\": [")
		if len(n.properties) == 0 {
			emit_raw(e, "]")
		} else {
			emit_raw(e, "\n")
			for prop, i in n.properties {
				// Rest element in object destructure: parser stashes `...rest`
				// as a Property { key: nil, value: ^SpreadElement }. Unwrap it
				// to a bare RestElement node per ESTree.
				if prop.key == nil {
					if se, ok := prop.value^.(^SpreadElement); ok {
						emit_indent(e, indent + 1)
						emit_raw(e, "{\n")
						emit_indent(e, indent + 2)
						emit_raw(e, "\"type\": \"RestElement\",\n")
						emit_indent(e, indent + 2)
						emit_span_leading(e, se.loc, indent + 2)
						emit_raw(e, "\"argument\": {\n")
						print_expression_as_pattern(e, se.argument, indent + 3)
						emit_raw(e, "\n")
						emit_indent(e, indent + 2)
						emit_raw(e, "}\n")
						emit_indent(e, indent + 1)
						if i < len(n.properties) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
						continue
					}
				}
				emit_indent(e, indent + 1)
				emit_raw(e, "{\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"type\": \"Property\",\n")
				emit_indent(e, indent + 2)
				emit_span_leading(e, prop.loc, indent + 2)
				emit_raw(e, "\"shorthand\": ")
				emit_bool(e, prop.shorthand)
				emit_raw(e, ",\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"computed\": ")
				emit_bool(e, prop.computed)
				emit_raw(e, ",\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"kind\": \"init\",\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"method\": false,\n")
				// Mirror the print_pattern_ast Property footer (S26 W4).
				if e.cfg.ts_shape {
					emit_indent(e, indent + 2)
					emit_raw(e, "\"optional\": false,\n")
				}
				emit_indent(e, indent + 2)
				emit_raw(e, "\"key\": ")
				if prop.key != nil {
					emit_raw(e, "{\n")
					print_expression_ast(e, prop.key, indent + 3)
					emit_raw(e, "\n")
					emit_indent(e, indent + 2)
					emit_raw(e, "}")
				} else {
					emit_raw(e, "null")
				}
				emit_raw(e, ",\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"value\": {\n")
				print_expression_as_pattern(e, prop.value, indent + 3)
				emit_raw(e, "\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "}\n")
				emit_indent(e, indent + 1)
				if i < len(n.properties) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
			}
			emit_indent(e, indent)
			emit_raw(e, "]")
		}
		// Mirror the print_pattern_ast ObjectPattern footer (S26 W4).
		if e.cfg.ts_shape {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"optional\": false,\n")
			emit_indent(e, indent)
			emit_raw(e, "\"typeAnnotation\": null")
		}
	case ^AssignmentExpression:
		// Only `=` forms a destructuring default; `+=`/etc. are not valid
		// in pattern position. If any other operator appears here it's an
		// upstream bug — fall through to plain expression emit so the shape
		// is at least valid JSON rather than corrupt.
		if n.operator != .Assign {
			print_expression_ast(e, expr, indent)
			return
		}
		emit_indent(e, indent)
		emit_raw(e, "\"type\": \"AssignmentPattern\",\n")
		emit_indent(e, indent)
		emit_span_leading(e, n.loc, indent)
		emit_raw(e, "\"left\": {\n")
		print_expression_as_pattern(e, n.left, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		emit_indent(e, indent)
		emit_raw(e, "\"right\": {\n")
		print_expression_ast(e, n.right, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")
	case ^SpreadElement:
		// `...rest` in an array destructure → RestElement in the pattern.
		emit_indent(e, indent)
		emit_raw(e, "\"type\": \"RestElement\",\n")
		emit_indent(e, indent)
		emit_span_leading(e, n.loc, indent)
		emit_raw(e, "\"argument\": {\n")
		print_expression_as_pattern(e, n.argument, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")
	case:
		// Identifier, MemberExpression, ParenthesizedExpression, etc. — all
		// valid pattern targets that share their expression emit shape.
		print_expression_ast(e, expr, indent)
	}
}

emit_ts_module_body :: proc(e: ^Emitter, body: ^TSModuleBody, indent: int) {
	if body == nil { emit_raw(e, "null"); return }
	#partial switch v in body^ {
	case ^TSModuleBlock:
		emit_raw(e, "{\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSModuleBlock\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"body\": [")
		if len(v.body) == 0 {
			emit_raw(e, "]")
		} else {
			emit_raw(e, "\n")
			for stmt, i in v.body {
				emit_indent(e, indent + 2)
				emit_raw(e, "{\n")
				print_statement_ast(e, stmt, indent + 3)
				emit_raw(e, "\n")
				emit_indent(e, indent + 2)
				if i < len(v.body) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
			}
			emit_indent(e, indent + 1)
			emit_raw(e, "]")
		}
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")
	case ^TSModuleDeclaration:
		// Nested-namespace case reached via ^TSModuleBody from a TSModuleBlock
		// (user-written `namespace A { namespace B {} }`). Same field set as
		// the top-level emit; emit_ts_module_decl_fields handles the
		// dotted-name fold internally so a deeper `namespace A.B {}` chain
		// nested inside a block still flattens correctly.
		emit_raw(e, "{\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSModuleDeclaration\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_ts_module_decl_fields(e, v, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")
	}
}

// ============================================================================
// JSX Helper Functions
// ============================================================================

emit_jsx_identifier :: proc(e: ^Emitter, id: JSXIdentifier, indent: int) {
	emit_raw(e, "{\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"type\": \"JSXIdentifier\",\n")
	emit_indent(e, indent + 1)
	emit_span_leading(e, id.loc, indent + 1)
	emit_raw(e, "\"name\": ")
	emit_str(e, id.name)
	emit_raw(e, "\n")
	emit_indent(e, indent)
	emit_raw(e, "}")
}

emit_jsx_member_object :: proc(e: ^Emitter, obj: JSXMemberObject, indent: int) {
	switch o in obj {
	case JSXIdentifier:
		emit_jsx_identifier(e, o, indent)
	case ^JSXMemberExpression:
		emit_raw(e, "{\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"JSXMemberExpression\",\n")
		emit_indent(e, indent + 1)
		emit_span_leading(e, o.loc, indent + 1)
		emit_raw(e, "\"object\": ")
		emit_jsx_member_object(e, o.object, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"property\": ")
		emit_jsx_identifier(e, o.property, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")
	}
}

emit_jsx_element_name :: proc(e: ^Emitter, name: JSXElementName, indent: int) {
	switch n in name {
	case:
		// Nil union variant (error-recovery produced a closing element
		// with no name). Emit null so the JSON stays valid.
		emit_raw(e, "null")
	case JSXIdentifier:
		emit_jsx_identifier(e, n, indent)
	case ^JSXMemberExpression:
		emit_raw(e, "{\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"JSXMemberExpression\",\n")
		emit_indent(e, indent + 1)
		emit_span_leading(e, n.loc, indent + 1)
		emit_raw(e, "\"object\": ")
		emit_jsx_member_object(e, n.object, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"property\": ")
		emit_jsx_identifier(e, n.property, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")
	case ^JSXNamespacedName:
		emit_raw(e, "{\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"JSXNamespacedName\",\n")
		emit_indent(e, indent + 1)
		emit_span_leading(e, n.loc, indent + 1)
		emit_raw(e, "\"namespace\": ")
		emit_jsx_identifier(e, n.namespace, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"name\": ")
		emit_jsx_identifier(e, n.name, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")
	}
}

emit_jsx_attribute_name :: proc(e: ^Emitter, name: JSXAttributeName, indent: int) {
	switch n in name {
	case JSXIdentifier:
		emit_jsx_identifier(e, n, indent)
	case ^JSXNamespacedName:
		emit_raw(e, "{\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"JSXNamespacedName\",\n")
		emit_indent(e, indent + 1)
		emit_span_leading(e, n.loc, indent + 1)
		emit_raw(e, "\"namespace\": ")
		emit_jsx_identifier(e, n.namespace, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"name\": ")
		emit_jsx_identifier(e, n.name, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")
	}
}

emit_jsx_children :: proc(e: ^Emitter, children: [dynamic]JSXChild, indent: int) {
	emit_raw(e, "\"children\": [")
	if len(children) == 0 {
		emit_raw(e, "]")
		return
	}
	emit_raw(e, "\n")
	for child, i in children {
		emit_indent(e, indent + 1)
		emit_raw(e, "{\n")
		switch c in child {
		case ^JSXElement:
			emit_indent(e, indent + 2)
			emit_raw(e, "\"type\": \"JSXElement\"")
			emit_span_fields(e, c.loc, indent + 2)
			emit_jsx_element_body(e, c, indent + 2)
		case ^JSXFragment:
			emit_indent(e, indent + 2)
			emit_raw(e, "\"type\": \"JSXFragment\"")
			emit_span_fields(e, c.loc, indent + 2)
			emit_jsx_fragment_body(e, c, indent + 2)
		case ^JSXText:
			emit_indent(e, indent + 2)
			emit_raw(e, "\"type\": \"JSXText\"")
			emit_span_fields(e, c.loc, indent + 2)
			emit_raw(e, ",\n")
			emit_indent(e, indent + 2)
			emit_raw(e, "\"value\": ")
			emit_str(e, c.value)
			emit_raw(e, ",\n")
			emit_indent(e, indent + 2)
			emit_raw(e, "\"raw\": ")
			emit_str(e, c.raw)
			emit_raw(e, "\n")
		case ^JSXExpressionContainer:
			emit_indent(e, indent + 2)
			emit_raw(e, "\"type\": \"JSXExpressionContainer\"")
			emit_span_fields(e, c.loc, indent + 2)
			emit_raw(e, ",\n")
			emit_indent(e, indent + 2)
			emit_raw(e, "\"expression\": {\n")
			print_expression_ast(e, c.expression, indent + 3)
			emit_raw(e, "\n")
			emit_indent(e, indent + 2)
			emit_raw(e, "}\n")
		case ^JSXSpreadChild:
			emit_indent(e, indent + 2)
			emit_raw(e, "\"type\": \"JSXSpreadChild\"")
			emit_span_fields(e, c.loc, indent + 2)
			emit_raw(e, ",\n")
			emit_indent(e, indent + 2)
			emit_raw(e, "\"expression\": {\n")
			print_expression_ast(e, c.expression, indent + 3)
			emit_raw(e, "\n")
			emit_indent(e, indent + 2)
			emit_raw(e, "}\n")
		}
		emit_indent(e, indent + 1)
		if i < len(children) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
	}
	emit_indent(e, indent)
	emit_raw(e, "]")
}

emit_jsx_element_body :: proc(e: ^Emitter, el: ^JSXElement, indent: int) {
	emit_raw(e, ",\n")
	emit_indent(e, indent)
	emit_raw(e, "\"openingElement\": {\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"type\": \"JSXOpeningElement\",\n")
	emit_indent(e, indent + 1)
	emit_span_leading(e, el.opening_element.loc, indent + 1)
	emit_raw(e, "\"name\": ")
	emit_jsx_element_name(e, el.opening_element.name, indent + 1)
	emit_raw(e, ",\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"attributes\": [")
	if len(el.opening_element.attributes) == 0 {
		emit_raw(e, "],\n")
	} else {
		emit_raw(e, "\n")
		for attr, i in el.opening_element.attributes {
			emit_indent(e, indent + 2)
			emit_raw(e, "{\n")
			switch a in attr {
			case JSXAttribute:
				emit_indent(e, indent + 3)
				emit_raw(e, "\"type\": \"JSXAttribute\",\n")
				emit_indent(e, indent + 3)
				emit_span_leading(e, a.loc, indent + 3)
				emit_raw(e, "\"name\": ")
				emit_jsx_attribute_name(e, a.name, indent + 3)
				emit_raw(e, ",\n")
				emit_indent(e, indent + 3)
				emit_raw(e, "\"value\": ")
				if val, ok := a.value.(^Expression); ok && val != nil {
					emit_raw(e, "{\n")
					print_expression_ast(e, val, indent + 4)
					emit_indent(e, indent + 3)
					emit_raw(e, "}\n")
				} else {
					emit_raw(e, "null\n")
				}
			case ^JSXSpreadAttribute:
				emit_indent(e, indent + 3)
				emit_raw(e, "\"type\": \"JSXSpreadAttribute\",\n")
				emit_indent(e, indent + 3)
				emit_span_leading(e, a.loc, indent + 3)
				emit_raw(e, "\"argument\": {\n")
				print_expression_ast(e, a.argument, indent + 4)
				emit_indent(e, indent + 3)
				emit_raw(e, "}\n")
			}
			emit_indent(e, indent + 2)
			if i < len(el.opening_element.attributes) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
		}
		emit_indent(e, indent + 1)
		emit_raw(e, "],\n")
	}
	emit_indent(e, indent + 1)
	emit_raw(e, "\"selfClosing\": ")
	emit_bool(e, el.opening_element.self_closing)
	if e.cfg.ts_shape {
		// TS-ESTree shape parity: emit `typeArguments` on every
		// JSXOpeningElement in .ts/.tsx mode.
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"typeArguments\": ")
		if ta, has := el.opening_element.type_arguments.(^TSTypeParameterInstantiation); has && ta != nil {
			emit_ts_type_argument_list(e, ta, indent + 1)
		} else {
			emit_raw(e, "null")
		}
	}
	emit_raw(e, "\n")
	emit_indent(e, indent)
	emit_raw(e, "},\n")
	emit_indent(e, indent)
	emit_jsx_children(e, el.children, indent)
	emit_raw(e, ",\n")
	emit_indent(e, indent)
	emit_raw(e, "\"closingElement\": ")
	if closing, ok := el.closing_element.(^JSXClosingElement); ok && closing != nil {
		emit_raw(e, "{\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"JSXClosingElement\",\n")
		emit_indent(e, indent + 1)
		emit_span_leading(e, closing.loc, indent + 1)
		emit_raw(e, "\"name\": ")
		emit_jsx_element_name(e, closing.name, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")
	} else {
		emit_raw(e, "null")
	}
	emit_raw(e, "\n")
}

emit_jsx_fragment_body :: proc(e: ^Emitter, f: ^JSXFragment, indent: int) {
	emit_raw(e, ",\n")
	emit_indent(e, indent)
	emit_raw(e, "\"openingFragment\": {\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"type\": \"JSXOpeningFragment\",\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"start\": ")
	emit_u32(e, to_utf16(e, f.opening_fragment.loc.start))
	emit_raw(e, ",\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"end\": ")
	emit_u32(e, to_utf16(e, f.opening_fragment.loc.end))
	// OXC emits `attributes: []` and `selfClosing: false` on JSXOpeningFragment
	// in .jsx mode (for ESTree symmetry with JSXOpeningElement) but NOT in
	// .tsx mode. Mirror that split so the TS-shape compare lines up.
	if !e.cfg.ts_shape {
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"attributes\": [],\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"selfClosing\": false")
	}
	emit_raw(e, "\n")
	emit_indent(e, indent)
	emit_raw(e, "},\n")
	emit_indent(e, indent)
	emit_jsx_children(e, f.children, indent)
	emit_raw(e, ",\n")
	emit_indent(e, indent)
	emit_raw(e, "\"closingFragment\": {\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"type\": \"JSXClosingFragment\",\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"start\": ")
	emit_u32(e, to_utf16(e, f.closing_fragment.loc.start))
	emit_raw(e, ",\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"end\": ")
	emit_u32(e, to_utf16(e, f.closing_fragment.loc.end))
	emit_raw(e, "\n")
	emit_indent(e, indent)
	emit_raw(e, "}\n")
}

// emit_ts_signature writes a TSPropertySignature or TSMethodSignature.
emit_ts_signature :: proc(e: ^Emitter, sig: ^TSSignature, indent: int) {
	if sig == nil { emit_raw(e, "null"); return }
	emit_raw(e, "{\n")
	#partial switch v in sig^ {
	case TSPropertySignature:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSPropertySignature\",\n")
		emit_indent(e, indent + 1)
		emit_span_leading(e, v.loc, indent + 1)
		emit_raw(e, "\"key\": {\n")
		print_expression_ast(e, v.key, indent + 2)
		emit_raw(e, "\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "},\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"computed\": ")
		emit_bool(e, v.computed)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"optional\": ")
		emit_bool(e, v.optional)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"readonly\": ")
		emit_bool(e, v.readonly)
		if ann, ok := v.type_annotation.(^TSTypeAnnotation); ok {
			emit_raw(e, ",\n")
			emit_indent(e, indent + 1)
			emit_raw(e, "\"typeAnnotation\": ")
			emit_ts_type_annotation_node(e, ann, indent + 1)
		}
		emit_raw(e, "\n")
	case TSMethodSignature:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSMethodSignature\",\n")
		emit_indent(e, indent + 1)
		emit_span_leading(e, v.loc, indent + 1)
		emit_raw(e, "\"key\": {\n")
		print_expression_ast(e, v.key, indent + 2)
		emit_raw(e, "\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "},\n")
		// OXC's TSMethodSignature shape carries `kind` ("method" | "get" |
		// "set"), `typeParameters` (null when absent), and `readonly`
		// (false when absent) on every signature. Kessel previously
		// omitted all three, causing every interface method signature to
		// diverge in TS-shape mode.
		emit_indent(e, indent + 1)
		kind_s := "method"
		#partial switch v.kind {
		case .Get: kind_s = "get"
		case .Set: kind_s = "set"
		}
		emit_raw(e, "\"kind\": \"")
		emit_raw(e, kind_s)
		emit_raw(e, "\",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"typeParameters\": ")
		emit_ts_type_parameter_declaration(e, v.type_parameters, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"readonly\": false,\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"computed\": ")
		emit_bool(e, v.computed)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"optional\": ")
		emit_bool(e, v.optional)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"params\": [")
		if len(v.params) == 0 {
			emit_raw(e, "]")
		} else {
			emit_raw(e, "\n")
			for fp, i in v.params {
				emit_indent(e, indent + 2)
				emit_raw(e, "{\n")
				emit_indent(e, indent + 3)
				emit_raw(e, "\"type\": \"Identifier\",\n")
				emit_indent(e, indent + 3)
				emit_span_leading(e, fp.loc, indent + 3)
				emit_raw(e, "\"name\": ")
				if ident, ok := fp.pattern.(^Identifier); ok {
					emit_str(e, ident.name)
				} else {
					emit_raw(e, "\"\"")
				}
				if ann, ok := fp.type_annotation.(^TSTypeAnnotation); ok {
					emit_raw(e, ",\n")
					emit_indent(e, indent + 3)
					emit_raw(e, "\"typeAnnotation\": ")
					emit_ts_type_annotation_node(e, ann, indent + 3)
				} else if e.cfg.ts_shape {
					emit_raw(e, ",\n")
					emit_indent(e, indent + 3)
					emit_raw(e, "\"typeAnnotation\": null")
				}
				// S26 W4: TSMethodSignature param Identifiers also need the
				// TS-shape `optional: false` placeholder for parity with OXC.
				if e.cfg.ts_shape {
					emit_raw(e, ",\n")
					emit_indent(e, indent + 3)
					emit_raw(e, "\"optional\": false")
				}
				emit_raw(e, "\n")
				emit_indent(e, indent + 2)
				if i < len(v.params) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
			}
			emit_indent(e, indent + 1)
			emit_raw(e, "]")
		}
		if ann, ok := v.return_type.(^TSTypeAnnotation); ok {
			emit_raw(e, ",\n")
			emit_indent(e, indent + 1)
			emit_raw(e, "\"returnType\": ")
			emit_ts_type_annotation_node(e, ann, indent + 1)
		}
		emit_raw(e, "\n")
	case TSIndexSignature:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSIndexSignature\",\n")
		emit_indent(e, indent + 1)
		emit_span_leading(e, v.loc, indent + 1)
		emit_raw(e, "\"parameters\": [")
		if len(v.parameters) == 0 {
			emit_raw(e, "]")
		} else {
			emit_raw(e, "\n")
			for fp, i in v.parameters {
				emit_indent(e, indent + 2)
				emit_raw(e, "{\n")
				emit_indent(e, indent + 3)
				emit_raw(e, "\"type\": \"Identifier\",\n")
				emit_indent(e, indent + 3)
				emit_span_leading(e, fp.loc, indent + 3)
				emit_raw(e, "\"name\": ")
				if ident, ok := fp.pattern.(^Identifier); ok {
					emit_str(e, ident.name)
				} else {
					emit_raw(e, "\"\"")
				}
				if ann, ok := fp.type_annotation.(^TSTypeAnnotation); ok {
					emit_raw(e, ",\n")
					emit_indent(e, indent + 3)
					emit_raw(e, "\"typeAnnotation\": ")
					emit_ts_type_annotation_node(e, ann, indent + 3)
				} else if e.cfg.ts_shape {
					emit_raw(e, ",\n")
					emit_indent(e, indent + 3)
					emit_raw(e, "\"typeAnnotation\": null")
				}
				// S26 W4: same TS-shape `optional: false` placeholder as the
				// TSMethodSignature params above.
				if e.cfg.ts_shape {
					emit_raw(e, ",\n")
					emit_indent(e, indent + 3)
					emit_raw(e, "\"optional\": false")
				}
				emit_raw(e, "\n")
				emit_indent(e, indent + 2)
				if i < len(v.parameters) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
			}
			emit_indent(e, indent + 1)
			emit_raw(e, "]")
		}
		if ann, ok := v.type_annotation.(^TSTypeAnnotation); ok {
			emit_raw(e, ",\n")
			emit_indent(e, indent + 1)
			emit_raw(e, "\"typeAnnotation\": ")
			emit_ts_type_annotation_node(e, ann, indent + 1)
		}
		// accessibility: OXC always emits null in TS-shape mode.
		if e.cfg.ts_shape {
			emit_raw(e, ",\n")
			emit_indent(e, indent + 1)
			emit_raw(e, "\"accessibility\": null")
		}
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"readonly\": ")
		emit_bool(e, v.readonly)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"static\": ")
		emit_bool(e, v.static_)
		emit_raw(e, "\n")
	case TSCallSignatureDeclaration:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSCallSignatureDeclaration\",\n")
		emit_indent(e, indent + 1)
		emit_span_leading(e, v.loc, indent + 1)
		emit_raw(e, "\"params\": [")
		if len(v.params) == 0 {
			emit_raw(e, "]")
		} else {
			emit_raw(e, "\n")
			for fp, i in v.params {
				emit_indent(e, indent + 2)
				emit_raw(e, "{\n")
				emit_indent(e, indent + 3)
				emit_raw(e, "\"type\": \"Identifier\",\n")
				emit_indent(e, indent + 3)
				emit_span_leading(e, fp.loc, indent + 3)
				emit_raw(e, "\"name\": ")
				if ident, ok := fp.pattern.(^Identifier); ok {
					emit_str(e, ident.name)
				} else {
					emit_raw(e, "\"\"")
				}
				if ann, ok := fp.type_annotation.(^TSTypeAnnotation); ok {
					emit_raw(e, ",\n")
					emit_indent(e, indent + 3)
					emit_raw(e, "\"typeAnnotation\": ")
					emit_ts_type_annotation_node(e, ann, indent + 3)
				}
				emit_raw(e, "\n")
				emit_indent(e, indent + 2)
				if i < len(v.params) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
			}
			emit_indent(e, indent + 1)
			emit_raw(e, "]")
		}
		if ann, ok := v.return_type.(^TSTypeAnnotation); ok {
			emit_raw(e, ",\n")
			emit_indent(e, indent + 1)
			emit_raw(e, "\"returnType\": ")
			emit_ts_type_annotation_node(e, ann, indent + 1)
		}
		emit_raw(e, "\n")
	case TSConstructSignatureDeclaration:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSConstructSignatureDeclaration\",\n")
		emit_indent(e, indent + 1)
		emit_span_leading(e, v.loc, indent + 1)
		emit_raw(e, "\"params\": [")
		if len(v.params) == 0 {
			emit_raw(e, "]")
		} else {
			emit_raw(e, "\n")
			for fp, i in v.params {
				emit_indent(e, indent + 2)
				emit_raw(e, "{\n")
				emit_indent(e, indent + 3)
				emit_raw(e, "\"type\": \"Identifier\",\n")
				emit_indent(e, indent + 3)
				emit_span_leading(e, fp.loc, indent + 3)
				emit_raw(e, "\"name\": ")
				if ident, ok := fp.pattern.(^Identifier); ok {
					emit_str(e, ident.name)
				} else {
					emit_raw(e, "\"\"")
				}
				if ann, ok := fp.type_annotation.(^TSTypeAnnotation); ok {
					emit_raw(e, ",\n")
					emit_indent(e, indent + 3)
					emit_raw(e, "\"typeAnnotation\": ")
					emit_ts_type_annotation_node(e, ann, indent + 3)
				}
				emit_raw(e, "\n")
				emit_indent(e, indent + 2)
				if i < len(v.params) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
			}
			emit_indent(e, indent + 1)
			emit_raw(e, "]")
		}
		if ann, ok := v.return_type.(^TSTypeAnnotation); ok {
			emit_raw(e, ",\n")
			emit_indent(e, indent + 1)
			emit_raw(e, "\"returnType\": ")
			emit_ts_type_annotation_node(e, ann, indent + 1)
		}
		emit_raw(e, "\n")
	}
	emit_indent(e, indent)
	emit_raw(e, "}")
}

// emit_ts_heritage_entry writes one heritage clause (used by
// `interface X extends A, B` and `class X implements A, B`). OXC shape:
//   { type: <kind>, expression: <ident-or-member>, typeArguments: <...|null> }
// where <kind> is `TSInterfaceHeritage` for interface-extends and
// `TSClassImplements` for class-implements — same underlying shape, only
// the `type` string differs. Single helper so both emit paths stay in
// lockstep.
emit_ts_heritage_entry :: proc(e: ^Emitter, h: TSInterfaceHeritage, type_name: string, indent: int) {
	emit_indent(e, indent)
	emit_raw(e, "{\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"type\": \"")
	emit_raw(e, type_name)
	emit_raw(e, "\"")
	emit_span_fields(e, h.loc, indent + 1)
	emit_raw(e, ",\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"expression\": {\n")
	print_expression_ast(e, h.expression, indent + 2)
	emit_raw(e, "\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "},\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"typeArguments\": ")
	emit_ts_type_argument_list(e, h.type_parameters, indent + 1)
	emit_raw(e, "\n")
	emit_indent(e, indent)
	emit_raw(e, "}")
}

// emit_ts_type_argument_list writes a TSTypeParameterInstantiation node
// (the `<T, U>` part of a generic call/new expression). Used by CallExpression
// and NewExpression emitters.
emit_ts_type_argument_list :: proc(e: ^Emitter, targs_opt: Maybe(^TSTypeParameterInstantiation), indent: int) {
	targs, ok := targs_opt.(^TSTypeParameterInstantiation)
	if !ok || targs == nil {
		emit_raw(e, "null")
		return
	}
	emit_raw(e, "{\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"type\": \"TSTypeParameterInstantiation\",\n")
	emit_indent(e, indent + 1)
	emit_span_leading(e, targs.loc, indent + 1)
	emit_raw(e, "\"params\": [")
	if len(targs.params) == 0 {
		emit_raw(e, "]\n")
	} else {
		emit_raw(e, "\n")
		for p, i in targs.params {
			emit_indent(e, indent + 2)
			// emit_ts_type already wraps its output in '{...}'
			emit_ts_type(e, p, indent + 2)
			if i < len(targs.params) - 1 { emit_raw(e, ",\n") } else { emit_raw(e, "\n") }
		}
		emit_indent(e, indent + 1)
		emit_raw(e, "]\n")
	}
	emit_indent(e, indent)
	emit_raw(e, "}")
}

// emit_ts_function_param writes one TSFunctionParam (as an Identifier with
// optional typeAnnotation) — the shape OXC uses for entries in a
// TSFunctionType's `params` list. The underlying pattern is typically an
// Identifier, so we reuse print_pattern_ast to stamp type + span + name, then
// glue on `optional` + `typeAnnotation` from the TS wrapper.
emit_ts_function_param :: proc(e: ^Emitter, fp: TSFunctionParam, indent: int) {
	emit_raw(e, "{\n")
	print_pattern_ast(e, fp.pattern, indent + 1)
	if fp.optional {
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"optional\": true")
	}
	emit_raw(e, ",\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"typeAnnotation\": ")
	if ann, ok := fp.type_annotation.(^TSTypeAnnotation); ok && ann != nil {
		emit_ts_type_annotation_node(e, ann, indent + 1)
	} else {
		emit_raw(e, "null")
	}
	emit_raw(e, "\n")
	emit_indent(e, indent)
	emit_raw(e, "}")
}

// emit_ts_type_parameter_declaration writes a TSTypeParameterDeclaration or null.
emit_ts_type_parameter_declaration :: proc(e: ^Emitter, decl_opt: Maybe(^TSTypeParameterDeclaration), indent: int) {
	decl, ok := decl_opt.(^TSTypeParameterDeclaration)
	if !ok || decl == nil { emit_raw(e, "null"); return }
	emit_raw(e, "{\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"type\": \"TSTypeParameterDeclaration\"")
	emit_span_fields(e, decl.loc, indent + 1)
	emit_raw(e, ",\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"params\": [")
	if len(decl.params) == 0 { emit_raw(e, "]")
	} else {
		emit_raw(e, "\n")
		for param, i in decl.params {
			emit_indent(e, indent + 2)
			emit_raw(e, "{\n")
			emit_indent(e, indent + 3)
			emit_raw(e, "\"type\": \"TSTypeParameter\"")
			emit_span_fields(e, param.loc, indent + 3)
			emit_raw(e, ",\n")
			emit_indent(e, indent + 3)
			emit_raw(e, "\"name\": ")
			emit_identifier_name_object(e, IdentifierName{loc = param.name.loc, name = param.name.name}, indent + 3)
			emit_raw(e, ",\n")
			emit_indent(e, indent + 3)
			emit_raw(e, "\"constraint\": ")
			if c, c_ok := param.constraint.(^TSType); c_ok { emit_ts_type(e, c, indent + 3) } else { emit_raw(e, "null") }
			emit_raw(e, ",\n")
			emit_indent(e, indent + 3)
			emit_raw(e, "\"default\": ")
			if d, d_ok := param.default_.(^TSType); d_ok { emit_ts_type(e, d, indent + 3) } else { emit_raw(e, "null") }
			emit_raw(e, ",\n")
			emit_indent(e, indent + 3)
			emit_raw(e, "\"in\": ")
			emit_bool(e, param.in_)
			emit_raw(e, ",\n")
			emit_indent(e, indent + 3)
			emit_raw(e, "\"out\": ")
			emit_bool(e, param.out)
			emit_raw(e, ",\n")
			emit_indent(e, indent + 3)
			emit_raw(e, "\"const\": ")
			emit_bool(e, param.const_)
			emit_raw(e, "\n")
			emit_indent(e, indent + 2)
			if i < len(decl.params) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
		}
		emit_indent(e, indent + 1)
		emit_raw(e, "]")
	}
	emit_raw(e, "\n")
	emit_indent(e, indent)
	emit_raw(e, "}")
}

// emit_ts_type_name converts a type-position expression (the `typeName`
// slot on TSTypeReference / TSTypeQuery / TSImportType) into the OXC
// TS-ESTree shape. A plain Identifier maps directly; a MemberExpression
// chain (`A.B.C`) folds left-deep into a recursive TSQualifiedName tree:
//
//   MemberExpression{object: A, property: B}
//     -> TSQualifiedName{left: A, right: B}
//   MemberExpression{object: MemberExpression{A, B}, property: C}
//     -> TSQualifiedName{left: TSQualifiedName{left: A, right: B}, right: C}
//
// Kessel's parser produces MemberExpression even in type position today,
// matching swc's choice; OXC produces TSQualifiedName. This emit-time
// rewrite gives us OXC parity without changing the parser. Each emitted
// Identifier carries the same TS-shape footer (`typeAnnotation: null,
// optional: false`) as every other TS-mode Identifier.
emit_ts_type_name :: proc(e: ^Emitter, expr: ^Expression, indent: int) {
	if expr == nil { emit_raw(e, "null"); return }
	if me, ok := expr^.(^MemberExpression); ok {
		emit_raw(e, "{\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSQualifiedName\"")
		emit_span_fields(e, me.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"left\": ")
		emit_ts_type_name(e, me.object, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"right\": ")
		// .property is always an Identifier in a valid TS qualified name
		// (`A.B`, `A.B.C`); recurse via emit_ts_type_name so a non-Identifier
		// property would still produce well-formed JSON rather than crash.
		emit_ts_type_name(e, me.property, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")
		return
	}
	// Leaf — plain Identifier (or other expression). Wrap in `{...}` and
	// dispatch through the standard expression printer; that path emits
	// the TS-shape footer (typeAnnotation, optional) on Identifier so
	// every TSQualifiedName leaf matches OXC's shape.
	emit_raw(e, "{\n")
	print_expression_ast(e, expr, indent + 1)
	emit_raw(e, "\n")
	emit_indent(e, indent)
	emit_raw(e, "}")
}

// emit_ts_type_annotation_node writes a TSTypeAnnotation wrapper object:
// { "type": "TSTypeAnnotation", "start": N, "end": N, "typeAnnotation": <TSType> }
emit_ts_type_annotation_node :: proc(e: ^Emitter, ann: ^TSTypeAnnotation, indent: int) {
	if ann == nil {
		emit_raw(e, "null")
		return
	}
	emit_raw(e, "{\n")
	emit_indent(e, indent + 1)
	emit_raw(e, "\"type\": \"TSTypeAnnotation\",\n")
	emit_indent(e, indent + 1)
	emit_span_leading(e, ann.loc, indent + 1)
	emit_raw(e, "\"typeAnnotation\": ")
	emit_ts_type(e, ann.type_annotation, indent + 1)
	emit_raw(e, "\n")
	emit_indent(e, indent)
	emit_raw(e, "}")
}

// emit_ts_type emits a TSType union variant as JSON.
emit_ts_type :: proc(e: ^Emitter, t: ^TSType, indent: int) {
	if t == nil {
		emit_raw(e, "null")
		return
	}
	emit_raw(e, "{\n")
	#partial switch v in t^ {
	case ^TSAnyKeyword:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSAnyKeyword\"")
		emit_span_fields(e, v.loc, indent + 1)
	case ^TSNumberKeyword:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSNumberKeyword\"")
		emit_span_fields(e, v.loc, indent + 1)
	case ^TSStringKeyword:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSStringKeyword\"")
		emit_span_fields(e, v.loc, indent + 1)
	case ^TSBooleanKeyword:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSBooleanKeyword\"")
		emit_span_fields(e, v.loc, indent + 1)
	case ^TSVoidKeyword:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSVoidKeyword\"")
		emit_span_fields(e, v.loc, indent + 1)
	case ^TSNullKeyword:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSNullKeyword\"")
		emit_span_fields(e, v.loc, indent + 1)
	case ^TSNeverKeyword:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSNeverKeyword\"")
		emit_span_fields(e, v.loc, indent + 1)
	case ^TSUnknownKeyword:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSUnknownKeyword\"")
		emit_span_fields(e, v.loc, indent + 1)
	case ^TSUndefinedKeyword:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSUndefinedKeyword\"")
		emit_span_fields(e, v.loc, indent + 1)
	case ^TSObjectKeyword:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSObjectKeyword\"")
		emit_span_fields(e, v.loc, indent + 1)
	case ^TSBigIntKeyword:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSBigIntKeyword\"")
		emit_span_fields(e, v.loc, indent + 1)
	case ^TSSymbolKeyword:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSSymbolKeyword\"")
		emit_span_fields(e, v.loc, indent + 1)
	case ^TSThisType:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSThisType\"")
		emit_span_fields(e, v.loc, indent + 1)
	case ^TSIntrinsicKeyword:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSIntrinsicKeyword\"")
		emit_span_fields(e, v.loc, indent + 1)
	case ^TSTypeReference:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSTypeReference\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"typeName\": ")
		emit_ts_type_name(e, v.type_name, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		// `typeArguments` is the TS-ESTree field for the `<A, B>` instantiation
		// on a reference, e.g. `Array<T>`. The parser records it on
		// v.type_parameters (an internal Kessel name pre-dating the ESTree
		// rename); previously this branch always emitted `null`, silently
		// dropping every generic type reference. Emit the real list when set.
		if targs, ok := v.type_parameters.(^TSTypeParameterInstantiation); ok && targs != nil {
			emit_raw(e, "\"typeArguments\": ")
			emit_ts_type_argument_list(e, v.type_parameters, indent + 1)
		} else {
			emit_raw(e, "\"typeArguments\": null")
		}
	case ^TSUnionType:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSUnionType\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"types\": [\n")
		for t_inner, i in v.types {
			emit_indent(e, indent + 2)
			emit_ts_type(e, t_inner, indent + 2)
			if i < len(v.types) - 1 { emit_raw(e, ",\n") } else { emit_raw(e, "\n") }
		}
		emit_indent(e, indent + 1)
		emit_raw(e, "]")
	case ^TSIntersectionType:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSIntersectionType\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"types\": [\n")
		for t_inner, i in v.types {
			emit_indent(e, indent + 2)
			emit_ts_type(e, t_inner, indent + 2)
			if i < len(v.types) - 1 { emit_raw(e, ",\n") } else { emit_raw(e, "\n") }
		}
		emit_indent(e, indent + 1)
		emit_raw(e, "]")
	case ^TSArrayType:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSArrayType\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"elementType\": ")
		emit_ts_type(e, v.element_type, indent + 1)
	case ^TSFunctionType:
		// `(params) => ret` function types. Previously fell through to the
		// default TSUnknownType arm, so every function type annotation
		// surfaced as `TSUnknownType` — observed on every interface method
		// signature in the spec fixtures. OXC shape:
		//   { type: "TSFunctionType", typeParameters, params, returnType }
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSFunctionType\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"typeParameters\": ")
		emit_ts_type_parameter_declaration(e, v.type_parameters, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"params\": [")
		if len(v.params) == 0 {
			emit_raw(e, "]")
		} else {
			emit_raw(e, "\n")
			for fp, i in v.params {
				emit_indent(e, indent + 2)
				emit_ts_function_param(e, fp, indent + 2)
				if i < len(v.params) - 1 { emit_raw(e, ",\n") } else { emit_raw(e, "\n") }
			}
			emit_indent(e, indent + 1)
			emit_raw(e, "]")
		}
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"returnType\": ")
		if v.return_type != nil {
			emit_ts_type_annotation_node(e, v.return_type, indent + 1)
		} else {
			emit_raw(e, "null")
		}
	case ^TSConstructorType:
		// `new (params) => ret` constructor types, plus the abstract variant
		// `abstract new (...) => ret`. Same shape as TSFunctionType with an
		// extra `abstract: bool` field. OXC shape:
		//   { type: "TSConstructorType", abstract, typeParameters, params,
		//     returnType }
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSConstructorType\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"abstract\": ")
		emit_raw(e, v.abstract_ ? "true" : "false")
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"typeParameters\": ")
		emit_ts_type_parameter_declaration(e, v.type_parameters, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"params\": [")
		if len(v.params) == 0 {
			emit_raw(e, "]")
		} else {
			emit_raw(e, "\n")
			for fp, i in v.params {
				emit_indent(e, indent + 2)
				emit_ts_function_param(e, fp, indent + 2)
				if i < len(v.params) - 1 { emit_raw(e, ",\n") } else { emit_raw(e, "\n") }
			}
			emit_indent(e, indent + 1)
			emit_raw(e, "]")
		}
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"returnType\": ")
		if v.return_type != nil {
			emit_ts_type_annotation_node(e, v.return_type, indent + 1)
		} else {
			emit_raw(e, "null")
		}
	case ^TSTupleType:
		// `[A, B]` tuple types. Previously fell through to the default
		// TSUnknownType arm, so every tuple annotation surfaced as
		// `TSUnknownType` with no element list. OXC field name is
		// `elementTypes` (plural), matching ESTree's TSTupleType shape.
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSTupleType\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"elementTypes\": [")
		if len(v.element_types) == 0 {
			emit_raw(e, "]")
		} else {
			emit_raw(e, "\n")
			for et, i in v.element_types {
				emit_indent(e, indent + 2)
				emit_ts_type(e, et, indent + 2)
				if i < len(v.element_types) - 1 { emit_raw(e, ",\n") } else { emit_raw(e, "\n") }
			}
			emit_indent(e, indent + 1)
			emit_raw(e, "]")
		}
	case ^TSIndexedAccessType:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSIndexedAccessType\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"objectType\": ")
		emit_ts_type(e, v.object_type, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"indexType\": ")
		emit_ts_type(e, v.index_type, indent + 1)
	case ^TSLiteralType:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSLiteralType\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"literal\": {\n")
		print_expression_ast(e, v.literal, indent + 2)
		emit_raw(e, "\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "}")
	case ^TSParenthesizedType:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSParenthesizedType\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"typeAnnotation\": ")
		emit_ts_type(e, v.type_annotation, indent + 1)
	case ^TSRestType:
		// `[A, ...B[]]` — the `...B[]` segment is a TSRestType wrapping a
		// TSArrayType. Only legal as a tuple element. (S26 W6 phase 3 #19)
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSRestType\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"typeAnnotation\": ")
		emit_ts_type(e, v.type_annotation, indent + 1)
	case ^TSOptionalType:
		// `[T?, U]` — a tuple element marked optional with a postfix `?`.
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSOptionalType\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"typeAnnotation\": ")
		emit_ts_type(e, v.type_annotation, indent + 1)
	case ^TSNamedTupleMember:
		// `[a: string, b?: number]` — named-tuple-member elements with
		// optional `?` between label and type. OXC shape:
		//   { type: "TSNamedTupleMember", label, elementType, optional }
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSNamedTupleMember\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"label\": {\n")
		emit_indent(e, indent + 2)
		emit_raw(e, "\"type\": \"Identifier\"")
		emit_span_fields(e, v.label.loc, indent + 2)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 2)
		emit_raw(e, "\"name\": ")
		emit_str(e, v.label.name)
		emit_raw(e, "\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "},\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"elementType\": ")
		emit_ts_type(e, v.element_type, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"optional\": ")
		emit_raw(e, v.optional ? "true" : "false")
	case ^TSTypeOperator:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSTypeOperator\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"operator\": ")
		emit_str(e, v.operator)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"typeAnnotation\": ")
		emit_ts_type(e, v.type_annotation, indent + 1)
	case ^TSTypeQuery:
		// `typeof X` in type position. The parser already builds a
		// TSTypeQuery node with expr_name set to the parsed left-hand
		// side (Identifier for `typeof X`, MemberExpression for
		// `typeof X.Y`); without an emit case, every TSTypeQuery fell
		// through to the TSUnknownType fallback below — 5 baseline
		// divergences on tsx/002 (S26 W4c). The emit shape mirrors
		// TSTypeReference: typeName-style expr_name (folded to
		// TSQualifiedName for member chains via emit_ts_type_name) plus
		// optional `typeArguments` instantiation list.
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSTypeQuery\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"exprName\": ")
		emit_ts_type_name(e, v.expr_name, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		if targs, ok := v.type_parameters.(^TSTypeParameterInstantiation); ok && targs != nil {
			emit_raw(e, "\"typeArguments\": ")
			emit_ts_type_argument_list(e, v.type_parameters, indent + 1)
		} else {
			emit_raw(e, "\"typeArguments\": null")
		}
	case ^TSMappedType:
		// OXC shape (oxc-parser @0.127+):
		//   key: Identifier  (just the variable name, e.g. K in [K in keyof T])
		//   constraint: TSType  (the constraint, e.g. keyof T)
		//   nameType: null | TSType  (the `as` rename clause)
		//   typeAnnotation: null | TSType  (the value type)
		//   optional: false | true | "+" | "-"
		//   readonly: null | true | "+" | "-"
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSMappedType\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_raw(e, ",\n")
		// key: just the identifier part of the type parameter
		emit_indent(e, indent + 1)
		emit_raw(e, "\"key\": {\n")
		emit_indent(e, indent + 2)
		emit_raw(e, "\"type\": \"Identifier\",\n")
		emit_indent(e, indent + 2)
		emit_span_leading(e, v.type_parameter.name.loc, indent + 2)
		emit_raw(e, "\"name\": ")
		emit_str(e, v.type_parameter.name.name)
		// S26 W4: TS-shape parity — OXC always emits `typeAnnotation: null`
		// AND `optional: false` on every Identifier in TS mode.
		if e.cfg.ts_shape {
			emit_raw(e, ",\n")
			emit_indent(e, indent + 2)
			emit_raw(e, "\"typeAnnotation\": null,\n")
			emit_indent(e, indent + 2)
			emit_raw(e, "\"optional\": false")
		}
		emit_raw(e, "\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "},\n")
		// constraint: the `in keyof T` part
		emit_indent(e, indent + 1)
		emit_raw(e, "\"constraint\": ")
		if c, ok := v.type_parameter.constraint.(^TSType); ok { emit_ts_type(e, c, indent + 1) } else { emit_raw(e, "null") }
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"nameType\": ")
		if nt, ok := v.name_type.(^TSType); ok { emit_ts_type(e, nt, indent + 1) } else { emit_raw(e, "null") }
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"typeAnnotation\": ")
		if ta, ok := v.type_annotation.(^TSType); ok { emit_ts_type(e, ta, indent + 1) } else { emit_raw(e, "null") }
		emit_raw(e, ",\n")
		// optional modifier: false | true | "+" | "-"
		emit_indent(e, indent + 1)
		emit_raw(e, "\"optional\": ")
		switch v.optional {
		case .None:  emit_raw(e, "false")
		case .True:  emit_raw(e, "true")
		case .Plus:  emit_raw(e, "\"+\"")
		case .Minus: emit_raw(e, "\"-\"")
		}
		emit_raw(e, ",\n")
		// readonly modifier: null | true | "+" | "-"
		emit_indent(e, indent + 1)
		emit_raw(e, "\"readonly\": ")
		switch v.readonly {
		case .None:  emit_raw(e, "null")
		case .True:  emit_raw(e, "true")
		case .Plus:  emit_raw(e, "\"+\"")
		case .Minus: emit_raw(e, "\"-\"")
		}
	case ^TSConditionalType:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSConditionalType\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"checkType\": ")
		emit_ts_type(e, v.check_type, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"extendsType\": ")
		emit_ts_type(e, v.extends_type, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"trueType\": ")
		emit_ts_type(e, v.true_type, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"falseType\": ")
		emit_ts_type(e, v.false_type, indent + 1)
	case ^TSTypeLiteral:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSTypeLiteral\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"members\": [")
		if len(v.members) == 0 {
			emit_raw(e, "]")
		} else {
			emit_raw(e, "\n")
			for member, i in v.members {
				emit_indent(e, indent + 2)
				emit_ts_signature(e, member, indent + 2)
				if i < len(v.members) - 1 { emit_raw(e, ",\n") } else { emit_raw(e, "\n") }
			}
			emit_indent(e, indent + 1)
			emit_raw(e, "]")
		}
	case ^TSInferType:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSInferType\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"typeParameter\": {\n")
		emit_indent(e, indent + 2)
		emit_raw(e, "\"type\": \"TSTypeParameter\"")
		emit_span_fields(e, v.type_parameter.loc, indent + 2)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 2)
		emit_raw(e, "\"name\": ")
		emit_identifier_name_object(e, IdentifierName{loc = v.type_parameter.name.loc, name = v.type_parameter.name.name}, indent + 2)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 2)
		emit_raw(e, "\"constraint\": ")
		if c, ok := v.type_parameter.constraint.(^TSType); ok { emit_ts_type(e, c, indent + 2) } else { emit_raw(e, "null") }
		emit_raw(e, ",\n")
		emit_indent(e, indent + 2)
		emit_raw(e, "\"default\": ")
		if d, ok := v.type_parameter.default_.(^TSType); ok { emit_ts_type(e, d, indent + 2) } else { emit_raw(e, "null") }
		emit_raw(e, ",\n")
		emit_indent(e, indent + 2)
		emit_raw(e, "\"in\": ")
		emit_bool(e, v.type_parameter.in_)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 2)
		emit_raw(e, "\"out\": ")
		emit_bool(e, v.type_parameter.out)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 2)
		emit_raw(e, "\"const\": ")
		emit_bool(e, v.type_parameter.const_)
		emit_raw(e, "\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "}")
	case ^TSTypePredicate:
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSTypePredicate\"")
		emit_span_fields(e, v.loc, indent + 1)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"asserts\": ")
		emit_bool(e, v.asserts)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"parameterName\": {\n")
		print_expression_ast(e, v.parameter_name, indent + 2)
		emit_raw(e, "\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "},\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"typeAnnotation\": ")
		if ann, ok := v.type_annotation.(^TSTypeAnnotation); ok {
			emit_ts_type_annotation_node(e, ann, indent + 1)
		} else {
			emit_raw(e, "null")
		}
	case:
		// Fallback for types not yet handled in emitter
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"TSUnknownType\"")
	}
	emit_raw(e, "\n")
	emit_indent(e, indent)
	emit_raw(e, "}")
}

print_expression_ast :: proc(e: ^Emitter, expr: ^Expression, indent: int) {
	// Emitter robustness: same rationale as print_statement_ast. A nil inner
	// typed pointer on an Expression would crash every downstream emitter
	// branch that reads `n.<field>`. Emit a safe placeholder with start/end=0
	// so I3_start_end_present invariant still holds.
	if expression_inner_nil(expr) {
		emit_indent(e, indent)
		emit_raw(e, "\"type\": \"Unknown\"")
		emit_span_fields(e, Loc{}, indent)
		return
	}
	// ESTree Literal short-circuit: collapse six OXC-style literal types into one.
	// ESTree spec uses a single "Literal" node for Numeric/String/Boolean/Null/BigInt/RegExp.
	// Every branch emits start/end via emit_span_fields or emit_span_leading so
	// downstream consumers get position info uniformly.
	#partial switch n in expr^ {
	case ^NumericLiteral:
		emit_indent(e, indent)
		emit_raw(e, "\"type\": \"Literal\",\n")
		emit_indent(e, indent)
		emit_span_leading(e, n.loc, indent)
		emit_raw(e, "\"value\": ")
		// JSON forbids Infinity and NaN (they're not grammatical number
		// literals); Odin's %v format emits "+Inf", "-Inf", "NaN" for those
		// cases, which break downstream JSON.parse. Substitute JSON-safe
		// equivalents that still round-trip via JSON.parse in Node/V8:
		//   +Inf -> 1e+400  (parses as Number.POSITIVE_INFINITY)
		//   -Inf -> -1e+400 (parses as Number.NEGATIVE_INFINITY)
		//   NaN  -> null    (no JSON escape exists; null is the canonical
		//                    ESTree fallback, also what acorn/meriyah emit)
		// OXC picks the same 1e+400 encoding for overflow literals.
		if math.classify_f64(n.value) == .Inf {
			emit_raw(e, n.value > 0 ? "1e+400" : "-1e+400")
			emit_raw(e, ",\n")
		} else if math.classify_f64(n.value) == .NaN {
			emit_raw(e, "null,\n")
		} else {
			emit_number(e, n.value)
			emit_raw(e, ",\n")
		}
		emit_indent(e, indent)
		emit_raw(e, "\"raw\": ")
		emit_str(e, n.raw)
		return

	case ^StringLiteral:
		emit_indent(e, indent)
		emit_raw(e, "\"type\": \"Literal\",\n")
		emit_indent(e, indent)
		emit_span_leading(e, n.loc, indent)
		emit_raw(e, "\"value\": ")
		emit_str(e, n.value)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"raw\": ")
		emit_str(e, n.raw)
		return

	case ^BooleanLiteral:
		emit_indent(e, indent)
		emit_raw(e, "\"type\": \"Literal\",\n")
		emit_indent(e, indent)
		emit_span_leading(e, n.loc, indent)
		emit_raw(e, "\"value\": ")
		emit_bool(e, n.value)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"raw\": ")
		if n.value {
			emit_raw(e, "\"true\"")
		} else {
			emit_raw(e, "\"false\"")
		}
		return

	case ^NullLiteral:
		emit_indent(e, indent)
		emit_raw(e, "\"type\": \"Literal\",\n")
		emit_indent(e, indent)
		emit_span_leading(e, n.loc, indent)
		emit_raw(e, "\"value\": null,\n")
		emit_indent(e, indent)
		emit_raw(e, "\"raw\": \"null\"")
		return

	case ^BigIntLiteral:
		emit_indent(e, indent)
		emit_raw(e, "\"type\": \"Literal\",\n")
		emit_indent(e, indent)
		emit_span_leading(e, n.loc, indent)
		emit_raw(e, "\"value\": null,\n")
		emit_indent(e, indent)
		emit_raw(e, "\"raw\": ")
		emit_str(e, n.raw)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"bigint\": ")
		// Convert to decimal representation
		decimal_repr := bigint_to_decimal(n.raw)
		emit_str(e, decimal_repr)
		return

	case ^RegExpLiteral:
		emit_indent(e, indent)
		emit_raw(e, "\"type\": \"Literal\",\n")
		emit_indent(e, indent)
		emit_span_leading(e, n.loc, indent)
		emit_raw(e, "\"value\": null,\n")
		emit_indent(e, indent)
		// Splice pattern/flags inside the quoted raw to get n.g. `"/\\D/g"`.
		// A naive out_s would leave literal backslashes unescaped and break
		// downstream JSON.parse; out_string_inner escapes each chunk without
		// emitting its own surrounding quotes.
		emit_raw(e, "\"raw\": \"/")
		emit_str_inner(e, n.pattern)
		emit_raw(e, "/")
		emit_str_inner(e, n.flags)
		emit_raw(e, "\",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"regex\": {\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"pattern\": ")
		emit_str(e, n.pattern)
		emit_raw(e, ",\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"flags\": ")
		// `regex.flags` is canonicalised: OXC / V8 normalise flag order by
		// sorting each flag character alphabetically (so `/…/mg` and `/…/gm`
		// both report `"gm"`), mirroring `new RegExp().flags` at runtime.
		// `raw` keeps the source order (via `emit_str(e, n.raw)` above); only
		// the structured `regex.flags` view gets the sorted form. ASCII-only
		// sort is sufficient here — every valid ES regex flag is one of
		// `dgimsuvy` (all < 0x80), so byte-sort == code-point sort.
		emit_str(e, sort_regex_flags(n.flags))
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")
		return
	case:
	}

	emit_indent(e, indent)
	emit_raw(e, "\"type\": \"")
	emit_raw(e, get_expression_type_name(e, expr))
	emit_raw(e, "\"")
	emit_span_fields(e, get_expression_loc(expr), indent)

	#partial switch n in expr^ {
	case ^Identifier:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"name\": ")
		emit_str(e, n.name)
		// TypeScript type annotation on expression identifier. In TS-shape mode
		// (p.lang == .TS / .TSX) always emit the field (null when absent) so
		// the AST matches OXC's TS-ESTree shape; in JS/JSX mode only emit when
		// meaningful (Kessel's historical behaviour, matches OXC JS mode).
		if ann, ok := n.type_annotation.(^TSTypeAnnotation); ok {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"typeAnnotation\": ")
			emit_ts_type_annotation_node(e, ann, indent)
		} else if e.cfg.ts_shape {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"typeAnnotation\": null")
		}
		// S26 W4: TS-ESTree emits `optional: false` on EVERY Identifier in
		// TS-shape mode — not just binding-position ones. OXC's TS-mode
		// output puts it on function ids, TypeParameter names, property
		// keys, TSTypeReference typeNames, etc. Kessel's Identifier struct
		// has no `optional` slot today (no source syntax for an optional
		// expression-position identifier), so emit a hard-coded `false`
		// placeholder. The pattern-position emit in print_pattern_ast does
		// the same.
		if e.cfg.ts_shape {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"optional\": false")
		}

	case ^ThisExpression:
		// No additional fields

	case ^Super:
		// No additional fields - ESTree Super is a leaf node with only `type`.
		// Previously fell through to the `case:` UNIMPLEMENTED arm, producing
		// `{"type":"Super","[UNIMPLEMENTED]":true}` - invalid JSON-drift against
		// OXC, which emits plain `{"type":"Super"}`.


	case ^ChainExpression:
		// Span is already emitted by the generic header (now that
		// get_expression_loc handles ChainExpression). Previously this
		// branch also called emit_span_leading, producing duplicate
		// `"start"`/`"end"` keys plus a zero‑inited 0/0 pair from the
		// header hitting the default `return Loc{}` arm — invalid JSON
		// that also smashed LogicalExpression.start to 0 via
		// loc_from_expr when the chain was a logical expr's LHS.
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"expression\": {\n")
		print_expression_ast(e, n.expression, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "}")

	case ^ArrayExpression:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"elements\": [\n")
		for elem, i in n.elements {
			if el, ok := elem.(^Expression); ok && el != nil {
				emit_indent(e, indent + 1)
				emit_raw(e, "{\n")
				print_expression_ast(e, el, indent + 2)
				emit_indent(e, indent + 1)
				if i < len(n.elements) - 1 {
					emit_raw(e, "},\n")
				} else {
					emit_raw(e, "}\n")
				}
			} else {
				// Sparse hole (n.g. `[, x]` / `[x,,,y]`) — ESTree spec requires
				// these to appear as `null` in the `elements` array so
				// positional indexing matches the source. Previously these were
				// silently skipped, making `[, -0]` look like `[-0]` to any
				// downstream ESTree walker (observed on lodash.js where a
				// `new Set([,-0])` expression diverged vs OXC).
				emit_indent(e, indent + 1)
				if i < len(n.elements) - 1 {
					emit_raw(e, "null,\n")
				} else {
					emit_raw(e, "null\n")
				}
			}
		}
		emit_indent(e, indent)
		emit_raw(e, "]")

	case ^ObjectExpression:
		// ESTree ObjectExpression.properties is a heterogeneous array of
		// Property | SpreadElement. Spread properties have `kind: nil` and
		// `key: nil` in Kessel's AST - emit them as SpreadElement, not as a
		// malformed Property.
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"properties\": [\n")
		for prop, i in n.properties {
			emit_indent(e, indent + 1)
			emit_raw(e, "{\n")
			// SpreadElement path: no key AND no explicit kind - Kessel stores it
			// with key:nil, value:^SpreadElement (already the right ESTree node).
			if prop.key == nil && prop.value != nil {
				if _, is_spread := prop.value^.(^SpreadElement); is_spread {
					print_expression_ast(e, prop.value, indent + 2)
					emit_raw(e, "\n")
					emit_indent(e, indent + 1)
					if i < len(n.properties) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
					continue
				}
			}
			emit_indent(e, indent + 2)
			emit_raw(e, "\"type\": \"Property\",\n")
			emit_indent(e, indent + 2)
			emit_span_leading(e, prop.loc, indent + 2)
			// ESTree kind: "init" | "get" | "set". OXC treats methods as
			// kind:"init" with method:true - follow that convention here.
			kind_str := "init"
			is_method := false
			#partial switch prop.kind {
			case .Get: kind_str = "get"
			case .Set: kind_str = "set"
			case .Method: is_method = true   // kind stays "init"
			}
			emit_raw(e, "\"kind\": \"")
			emit_raw(e, kind_str)
			emit_raw(e, "\",\n")
			emit_indent(e, indent + 2)
			emit_raw(e, "\"method\": ")
			emit_bool(e, is_method)
			emit_raw(e, ",\n")
			emit_indent(e, indent + 2)
			emit_raw(e, "\"shorthand\": ")
			emit_bool(e, prop.shorthand)
			emit_raw(e, ",\n")
			emit_indent(e, indent + 2)
			emit_raw(e, "\"computed\": ")
			emit_bool(e, prop.computed)
			emit_raw(e, ",\n")
			// S26 W4: TS-ESTree always emits `optional: false` on Property,
			// in both ObjectExpression and ObjectPattern positions. Kessel's
			// ObjectPropertyExpression doesn't carry an optional flag
			// (no source syntax for `{a?: b}` outside type positions), so
			// emit the placeholder unconditionally in TS-shape mode.
			if e.cfg.ts_shape {
				emit_indent(e, indent + 2)
				emit_raw(e, "\"optional\": false,\n")
			}

			if prop.key != nil {
				emit_indent(e, indent + 2)
				emit_raw(e, "\"key\": {\n")
				print_expression_ast(e, prop.key, indent + 3)
				emit_indent(e, indent + 2)
				emit_raw(e, "},\n")
			} else {
				emit_indent(e, indent + 2)
				emit_raw(e, "\"key\": null,\n")
			}

			if prop.value != nil {
				emit_indent(e, indent + 2)
				emit_raw(e, "\"value\": {\n")
				print_expression_ast(e, prop.value, indent + 3)
				emit_indent(e, indent + 2)
				emit_raw(e, "}\n")
			} else {
				emit_indent(e, indent + 2)
				emit_raw(e, "\"value\": null\n")
			}

			emit_indent(e, indent + 1)
			if i < len(n.properties) - 1 {
				emit_raw(e, "},\n")
			} else {
				emit_raw(e, "}\n")
			}
		}
		emit_indent(e, indent)
		emit_raw(e, "]")

	case ^BinaryExpression:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		op_str := binary_op_to_string(n.operator)
		emit_raw(e, "\"operator\": \"")
		emit_raw(e, op_str)
		emit_raw(e, "\",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"left\": {\n")
		print_expression_ast(e, n.left, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		emit_indent(e, indent)
		emit_raw(e, "\"right\": {\n")
		print_expression_ast(e, n.right, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "}")

	case ^UnaryExpression:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		op_str := unary_op_to_string(n.operator)
		emit_raw(e, "\"operator\": \"")
		emit_raw(e, op_str)
		emit_raw(e, "\",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"prefix\": ")
		emit_bool(e, n.prefix)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"argument\": {\n")
		print_expression_ast(e, n.argument, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "}")

	case ^AssignmentExpression:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		op_str := assignment_op_to_string(n.operator)
		emit_raw(e, "\"operator\": \"")
		emit_raw(e, op_str)
		emit_raw(e, "\",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"left\": {\n")
		if n.operator == .Assign {
			// Destructuring assignment: left must be a Pattern (ArrayPattern,
			// ObjectPattern, Identifier, MemberExpression) even though we
			// stored it as ^Expression. Route through print_expression_as_pattern
			// which recursively converts nested AssignmentExpression →
			// AssignmentPattern and SpreadElement → RestElement. Previously
			// an inline conversion here fixed only the outer wrapper, leaving
			// inner defaults in `[a = 1, b = 2] = arr` or `{a = 1, b = 2} = obj`
			// emitting `AssignmentExpression` children that desynchronised
			// every ESTree walker descending into the pattern.
			print_expression_as_pattern(e, n.left, indent + 1)
		} else {
			// Non-destructuring forms (`+=`, `-=`, etc.) — left is a regular
			// assignment target expression; no pattern conversion needed.
			print_expression_ast(e, n.left, indent + 1)
		}
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		emit_indent(e, indent)
		emit_raw(e, "\"right\": {\n")
		print_expression_ast(e, n.right, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "}")

	case ^CallExpression:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"callee\": {\n")
		print_expression_ast(e, n.callee, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		if n.optional {
			emit_indent(e, indent)
			emit_raw(e, "\"optional\": true,\n")
		}
		emit_indent(e, indent)
		// typeArguments: emit when present (generic call `foo<T>(args)`); emit null
		// placeholder in TS-shape mode for structural uniformity (OXC always emits it).
		if targs, ok := n.type_parameters.(^TSTypeParameterInstantiation); ok && targs != nil {
			emit_raw(e, "\"typeArguments\": ")
			emit_ts_type_argument_list(e, n.type_parameters, indent)
			emit_raw(e, ",\n")
			emit_indent(e, indent)
		} else if e.cfg.ts_shape {
			emit_raw(e, "\"typeArguments\": null,\n")
			emit_indent(e, indent)
		}
		emit_raw(e, "\"arguments\": [\n")
		for arg, i in n.arguments {
			emit_indent(e, indent + 1)
			emit_raw(e, "{\n")
			print_expression_ast(e, arg, indent + 2)
			emit_indent(e, indent + 1)
			if i < len(n.arguments) - 1 {
				emit_raw(e, "},\n")
			} else {
				emit_raw(e, "}\n")
			}
		}
		emit_indent(e, indent)
		emit_raw(e, "]")

	case ^MemberExpression:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"computed\": ")
		emit_bool(e, n.computed)
		emit_raw(e, ",\n")
		if n.optional {
			emit_indent(e, indent)
			emit_raw(e, "\"optional\": true,\n")
		}
		emit_indent(e, indent)
		emit_raw(e, "\"object\": {\n")
		print_expression_ast(e, n.object, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		emit_indent(e, indent)
		emit_raw(e, "\"property\": {\n")
		print_expression_ast(e, n.property, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "}")

	case ^ConditionalExpression:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"test\": {\n")
		print_expression_ast(e, n.test, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		emit_indent(e, indent)
		emit_raw(e, "\"consequent\": {\n")
		print_expression_ast(e, n.consequent, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		emit_indent(e, indent)
		emit_raw(e, "\"alternate\": {\n")
		print_expression_ast(e, n.alternate, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "}")

	case ^FunctionExpression:
		// ESTree FunctionExpression.id is `Identifier | null` - for anonymous
		// functions (the common IIFE case) it's null. OXC always emits it, so
		// does Kessel (null fallback).
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"id\": ")
		if id, ok := n.id.(BindingIdentifier); ok {
			emit_binding_identifier_object(e, id, indent)
		} else {
			emit_raw(e, "null")
		}
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		// expression: false - FunctionExpression always has a block body. OXC
		// emits this for symmetry with ArrowFunctionExpression.
		emit_raw(e, "\"expression\": false,\n")
		emit_indent(e, indent)
		emit_raw(e, "\"generator\": ")
		emit_bool(e, n.generator)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"async\": ")
		emit_bool(e, n.async)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		// declare: OXC always emits `declare: false` in TS-shape mode.
		if n.declare || e.cfg.ts_shape {
			emit_raw(e, "\"declare\": ")
			emit_bool(e, n.declare)
			emit_raw(e, ",\n")
			emit_indent(e, indent)
		}
		// typeParameters: emit when present; null placeholder in TS-shape mode.
		if tp, ok := n.type_parameters.(^TSTypeParameterDeclaration); ok && tp != nil {
			emit_raw(e, "\"typeParameters\": ")
			emit_ts_type_parameter_declaration(e, n.type_parameters, indent)
			emit_raw(e, ",\n")
			emit_indent(e, indent)
		} else if e.cfg.ts_shape {
			emit_raw(e, "\"typeParameters\": null,\n")
			emit_indent(e, indent)
		}
		emit_raw(e, "\"params\": [")
		if len(n.params) == 0 {
			emit_raw(e, "]")
		} else {
			emit_raw(e, "\n")
			for param, i in n.params {
				emit_indent(e, indent + 1)
				emit_raw(e, "{\n")
				print_function_parameter(e, param, indent + 2)
				emit_raw(e, "\n")
				emit_indent(e, indent + 1)
				if i < len(n.params) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
			}
			emit_indent(e, indent)
			emit_raw(e, "]")
		}
		// TypeScript return type annotation.
		if ann, ok := n.return_type.(^TSTypeAnnotation); ok {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"returnType\": ")
			emit_ts_type_annotation_node(e, ann, indent)
		} else if e.cfg.ts_shape {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"returnType\": null")
		}
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_println(e, "\"body\": {")
		fn_body := &n.body
		print_function_body_inline(e, fn_body, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_print(e, "}")

	case ^ArrowFunctionExpression:
		// OXC emits `id: null` and `generator: false` on ArrowFunctionExpression
		// too, even though the grammar never allows either (arrows are always
		// anonymous non-generators). Emitted for structural uniformity with
		// FunctionExpression so consumers can walk either with the same shape.
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"id\": null,\n")
		emit_indent(e, indent)
		emit_raw(e, "\"expression\": ")
		emit_bool(e, n.expression)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"generator\": false,\n")
		emit_indent(e, indent)
		emit_raw(e, "\"async\": ")
		emit_bool(e, n.async)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		// typeParameters: emit when present (generic arrow <T>(x)=>x); emit
		// null placeholder in TS-shape mode for structural uniformity.
		if tp, ok := n.type_parameters.(^TSTypeParameterDeclaration); ok && tp != nil {
			emit_raw(e, "\"typeParameters\": ")
			emit_ts_type_parameter_declaration(e, n.type_parameters, indent)
			emit_raw(e, ",\n")
			emit_indent(e, indent)
		} else if e.cfg.ts_shape {
			emit_raw(e, "\"typeParameters\": null,\n")
			emit_indent(e, indent)
		}
		emit_raw(e, "\"params\": [")
		if len(n.params) == 0 {
			emit_raw(e, "]")
		} else {
			emit_raw(e, "\n")
			for param, i in n.params {
				emit_indent(e, indent + 1)
				emit_raw(e, "{\n")
				print_function_parameter(e, param, indent + 2)
				emit_raw(e, "\n")
				emit_indent(e, indent + 1)
				if i < len(n.params) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
			}
			emit_indent(e, indent)
			emit_raw(e, "]")
		}
		// returnType: emit the explicit return type annotation when present;
		// in TS-shape mode always emit the field (null when absent).
		if ann, ok := n.return_type.(^TSTypeAnnotation); ok && ann != nil {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"returnType\": ")
			emit_ts_type_annotation_node(e, ann, indent)
		} else if e.cfg.ts_shape {
			emit_raw(e, ",\n")
			emit_indent(e, indent)
			emit_raw(e, "\"returnType\": null")
		}
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"body\": ")
		// ArrowFunctionBody is union { ^Expression, ^BlockStatement }. The
		// variant was previously emitted as a "..." placeholder due to the
		// pre-Bug-H transmute UB; post-fix we can switch cleanly on the tag.
		switch body in n.body {
		case ^Expression:
			emit_raw(e, "{\n")
			print_expression_ast(e, body, indent + 1)
			emit_indent(e, indent)
			emit_raw(e, "}")
		case ^BlockStatement:
			emit_raw(e, "{\n")
			print_block_statement_inline(e, body, indent + 1)
			emit_raw(e, "\n")
			emit_indent(e, indent)
			emit_raw(e, "}")
		case:
			emit_raw(e, "null")
		}

	case ^NewExpression:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"callee\": {\n")
		print_expression_ast(e, n.callee, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		emit_indent(e, indent)
		// typeArguments: TS generic new `new Foo<T>(args)`. OXC always emits the
		// field in TS-shape mode (null when no type args, TSTypeParameterInstantiation
		// when present).
		if targs, ok := n.type_parameters.(^TSTypeParameterInstantiation); ok && targs != nil {
			emit_raw(e, "\"typeArguments\": ")
			emit_ts_type_argument_list(e, n.type_parameters, indent)
			emit_raw(e, ",\n")
			emit_indent(e, indent)
		} else if e.cfg.ts_shape {
			emit_raw(e, "\"typeArguments\": null,\n")
			emit_indent(e, indent)
		}
		emit_raw(e, "\"arguments\": [\n")
		for arg, i in n.arguments {
			emit_indent(e, indent + 1)
			emit_raw(e, "{\n")
			print_expression_ast(e, arg, indent + 2)
			emit_indent(e, indent + 1)
			if i < len(n.arguments) - 1 {
				emit_raw(e, "},\n")
			} else {
				emit_raw(e, "}\n")
			}
		}
		emit_indent(e, indent)
		emit_raw(e, "]")

	case ^TemplateLiteral:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"quasis\": [")
		if len(n.quasis) == 0 {
			emit_raw(e, "],\n")
		} else {
			emit_raw(e, "\n")
			for q, i in n.quasis {
				emit_indent(e, indent + 1)
				emit_raw(e, "{\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"type\": \"TemplateElement\",\n")
				emit_indent(e, indent + 2)
				emit_span_leading(e, q.loc, indent + 2)
				emit_raw(e, "\"tail\": ")
				emit_bool(e, q.tail)
				emit_raw(e, ",\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"value\": { \"raw\": ")
				emit_str(e, q.raw)
				emit_raw(e, ", \"cooked\": ")
				if cooked, ok := q.cooked.(string); ok {
					emit_str(e, cooked)
				} else {
					emit_raw(e, "null")
				}
				emit_raw(e, " }\n")
				emit_indent(e, indent + 1)
				if i < len(n.quasis) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
			}
			emit_indent(e, indent)
			emit_raw(e, "],\n")
		}
		emit_indent(e, indent)
		emit_raw(e, "\"expressions\": [")
		if len(n.expressions) == 0 {
			emit_raw(e, "]")
		} else {
			emit_raw(e, "\n")
			for ex, i in n.expressions {
				emit_indent(e, indent + 1)
				emit_raw(e, "{\n")
				print_expression_ast(e, ex, indent + 2)
				emit_indent(e, indent + 1)
				if i < len(n.expressions) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
			}
			emit_indent(e, indent)
			emit_raw(e, "]")
		}

	case ^TaggedTemplateExpression:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"tag\": {\n")
		print_expression_ast(e, n.tag, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		emit_indent(e, indent)
		emit_raw(e, "\"quasi\": {\n")
		print_expression_ast(e, n.quasi, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "}")

	case ^SpreadElement:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"argument\": {\n")
		print_expression_ast(e, n.argument, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "}")

	case ^UpdateExpression:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		op_str := ""
		switch n.operator {
		case .Increment: op_str = "++"
		case .Decrement: op_str = "--"
		}
		emit_raw(e, "\"operator\": \"")
		emit_raw(e, op_str)
		emit_raw(e, "\",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"prefix\": ")
		emit_bool(e, n.prefix)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"argument\": {\n")
		print_expression_ast(e, n.argument, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "}")

	case ^LogicalExpression:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		op_str := ""
		#partial switch n.operator {
		case .And: op_str = "&&"
		case .Or:  op_str = "||"
		case .NullishCoalescing: op_str = "??"
		}
		emit_raw(e, "\"operator\": \"")
		emit_raw(e, op_str)
		emit_raw(e, "\",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"left\": {\n")
		print_expression_ast(e, n.left, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		emit_indent(e, indent)
		emit_raw(e, "\"right\": {\n")
		print_expression_ast(e, n.right, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "}")

	case ^SequenceExpression:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"expressions\": [\n")
		for expr_elem, i in n.expressions {
			emit_indent(e, indent + 1)
			emit_raw(e, "{\n")
			print_expression_ast(e, expr_elem, indent + 2)
			emit_indent(e, indent + 1)
			if i < len(n.expressions) - 1 {
				emit_raw(e, "},\n")
			} else {
				emit_raw(e, "}\n")
			}
		}
		emit_indent(e, indent)
		emit_raw(e, "]")

	case ^YieldExpression:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		if arg, ok := n.argument.(^Expression); ok && arg != nil {
			emit_raw(e, "\"argument\": {\n")
			print_expression_ast(e, arg, indent + 1)
			emit_indent(e, indent)
			emit_raw(e, "},\n")
		} else {
			emit_raw(e, "\"argument\": null,\n")
		}
		emit_indent(e, indent)
		emit_raw(e, "\"delegate\": ")
		emit_bool(e, n.delegate)

	case ^AwaitExpression:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"argument\": {\n")
		print_expression_ast(e, n.argument, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "}")

	case ^ImportExpression:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"source\": {\n")
		print_expression_ast(e, n.source, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		// Import Attributes stage-3 `options` field. null when the
		// second argument of ImportCall is absent.
		emit_indent(e, indent)
		emit_raw(e, "\"options\": ")
		if n.options == nil {
			emit_raw(e, "null")
		} else {
			emit_raw(e, "{\n")
			print_expression_ast(e, n.options, indent + 1)
			emit_indent(e, indent)
			emit_raw(e, "}")
		}
		// Phase Imports stage-3 `phase` field. null for plain import(...),
		// "defer" for import.defer(...), "source" for import.source(...).
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"phase\": ")
		if n.phase == "" {
			emit_raw(e, "null")
		} else {
			emit_str(e, n.phase)
		}

	case ^MetaProperty:
		// ESTree MetaProperty covers both `import.meta` AND `new.target` —
		// the parser records the actual identifier names in `n.meta.name`
		// and `n.property.name`. Hard-coding "import" / "meta" here (as we
		// did before) silently rewrote every `new.target` into `import.meta`
		// in the emitted AST, corrupting zod.js and any other code that
		// checks the constructor target. Emit the real names instead.
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"meta\": {\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"Identifier\",\n")
		emit_indent(e, indent + 1)
		emit_span_leading(e, n.meta.loc, indent + 1)
		emit_raw(e, "\"name\": ")
		emit_str(e, n.meta.name)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		emit_indent(e, indent)
		emit_raw(e, "\"property\": {\n")
		emit_indent(e, indent + 1)
		emit_raw(e, "\"type\": \"Identifier\",\n")
		emit_indent(e, indent + 1)
		emit_span_leading(e, n.property.loc, indent + 1)
		emit_raw(e, "\"name\": ")
		emit_str(e, n.property.name)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")

	case ^PrivateIdentifier:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"name\": ")
		emit_str(e, n.name)

	case ^ClassExpression:
		emit_raw(e, ",\n")
		// Emit decorators only when non-empty (OXC omits empty arrays).
		if len(n.decorators) > 0 {
			emit_indent(e, indent)
			emit_raw(e, "\"decorators\": [\n")
			for d, i in n.decorators {
				emit_indent(e, indent + 1)
				emit_raw(e, "{\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "\"type\": \"Decorator\",\n")
				emit_indent(e, indent + 2)
				emit_span_leading(e, d.loc, indent + 2)
				emit_raw(e, "\"expression\": {\n")
				print_expression_ast(e, d.expression, indent + 3)
				emit_raw(e, "\n")
				emit_indent(e, indent + 2)
				emit_raw(e, "}\n")
				emit_indent(e, indent + 1)
				if i < len(n.decorators) - 1 { emit_raw(e, "},\n") } else { emit_raw(e, "}\n") }
			}
			emit_indent(e, indent)
			emit_raw(e, "],\n")
		}
		emit_indent(e, indent)
		if n.id != nil {
			id := n.id.(BindingIdentifier)
			emit_raw(e, "\"id\": {\n")
			emit_indent(e, indent + 1)
			emit_raw(e, "\"type\": \"Identifier\",\n")
			emit_indent(e, indent + 1)
			emit_span_leading(e, id.loc, indent + 1)
			emit_raw(e, "\"name\": ")
			emit_str(e, id.name)
			emit_raw(e, "\n")
			emit_indent(e, indent)
			emit_raw(e, "},\n")
		} else {
			emit_indent(e, indent)
			emit_raw(e, "\"id\": null,\n")
		}
		if super, ok := n.super_class.(^Expression); ok && super != nil {
			emit_raw(e, "\"superClass\": {\n")
			print_expression_ast(e, super, indent + 1)
			emit_indent(e, indent)
			emit_raw(e, "},\n")
		} else {
			emit_indent(e, indent)
			emit_raw(e, "\"superClass\": null,\n")
		}
		// ClassBody.body is a [dynamic]ClassElement. Delegate the full emit to
		// print_class_body_inline, which mirrors the ClassDeclaration path.
		emit_raw(e, "\"body\": {\n")
		print_class_body_inline(e, &n.body, indent + 1)
		emit_indent(e, indent)
		emit_raw(e, "}\n")

	case ^JSXElement:
		emit_jsx_element_body(e, n, indent)

	case ^JSXFragment:
		emit_jsx_fragment_body(e, n, indent)

	case ^JSXText:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"value\": ")
		emit_str(e, n.value)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"raw\": ")
		emit_str(e, n.raw)

	case ^JSXExpressionContainer:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"expression\": {\n")
		print_expression_ast(e, n.expression, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")

	case ^JSXEmptyExpression:
		// No additional fields - just type + span

	case ^JSXSpreadChild:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"expression\": {\n")
		print_expression_ast(e, n.expression, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")

	case ^TSAsExpression:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"expression\": {\n")
		print_expression_ast(e, n.expression, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		emit_indent(e, indent)
		emit_raw(e, "\"typeAnnotation\": ")
		emit_ts_type(e, n.type_annotation, indent)

	case ^TSSatisfiesExpression:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"expression\": {\n")
		print_expression_ast(e, n.expression, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		emit_indent(e, indent)
		emit_raw(e, "\"typeAnnotation\": ")
		emit_ts_type(e, n.type_annotation, indent)

	case ^TSNonNullExpression:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"expression\": {\n")
		print_expression_ast(e, n.expression, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")

	case ^TSInstantiationExpression:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"expression\": {\n")
		print_expression_ast(e, n.expression, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "},\n")
		emit_indent(e, indent)
		emit_raw(e, "\"typeArguments\": ")
		if n.type_arguments != nil {
			emit_ts_type_argument_list(e, n.type_arguments, indent)
		} else {
			emit_raw(e, "null")
		}

	case ^TSTypeAssertion:
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"typeAnnotation\": ")
		emit_ts_type(e, n.type_annotation, indent)
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"expression\": {\n")
		print_expression_ast(e, n.expression, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")

	case ^ParenthesizedExpression:
		// EST-3 / OPT-3. Shape matches Acorn `preserveParens` + OXC default:
		//   { type: "ParenthesizedExpression", expression, start, end }
		// The inner expression keeps its own natural span; only the
		// wrapper span covers the outer `(` ... `)`.
		emit_raw(e, ",\n")
		emit_indent(e, indent)
		emit_raw(e, "\"expression\": {\n")
		print_expression_ast(e, n.expression, indent + 1)
		emit_raw(e, "\n")
		emit_indent(e, indent)
		emit_raw(e, "}")

	case:
		emit_println(e, ",")
		emit_indent(e, indent)
		emit_printf(e, "\"[UNIMPLEMENTED]\": true")
	}
}

// ============================================================================
// Type Name Helpers
// ============================================================================

get_statement_type_name :: proc(e: ^Emitter, stmt: ^Statement) -> string {
	if stmt == nil {
		return "nil"
	}
	switch s in stmt^ {
	case ^ExpressionStatement: return "ExpressionStatement"
	case ^EmptyStatement:      return "EmptyStatement"
	case ^BlockStatement:       return "BlockStatement"
	case ^DebuggerStatement:    return "DebuggerStatement"
	case ^ReturnStatement:      return "ReturnStatement"
	case ^BreakStatement:       return "BreakStatement"
	case ^ContinueStatement:    return "ContinueStatement"
	case ^LabeledStatement:     return "LabeledStatement"
	case ^IfStatement:          return "IfStatement"
	case ^SwitchStatement:      return "SwitchStatement"
	case ^WhileStatement:       return "WhileStatement"
	case ^DoWhileStatement:     return "DoWhileStatement"
	case ^ForStatement:         return "ForStatement"
	case ^ForInStatement:       return "ForInStatement"
	case ^ForOfStatement:       return "ForOfStatement"
	case ^WithStatement:        return "WithStatement"
	case ^ThrowStatement:       return "ThrowStatement"
	case ^TryStatement:         return "TryStatement"
	case ^FunctionDeclaration:
		// S26 W4b: ambient (no-body) function declarations emit as
		// TSDeclareFunction in TS-ESTree mode. The shape switch lives at
		// the type-label level so the upstream `"type": <label>` write
		// picks the right one without rewriting bytes downstream.
		if e.cfg.ts_shape && s.expr.no_body {
			return "TSDeclareFunction"
		}
		return "FunctionDeclaration"
	case ^VariableDeclaration:  return "VariableDeclaration"
	case ^ClassDeclaration:     return "ClassDeclaration"
	case ^ImportDeclaration:    return "ImportDeclaration"
	case ^ExportNamedDeclaration: return "ExportNamedDeclaration"
	case ^ExportDefaultDeclaration: return "ExportDefaultDeclaration"
	case ^ExportAllDeclaration: return "ExportAllDeclaration"
	case ^TSInterfaceDeclaration: return "TSInterfaceDeclaration"
	case ^TSTypeAliasDeclaration: return "TSTypeAliasDeclaration"
	case ^TSEnumDeclaration:    return "TSEnumDeclaration"
	case ^TSModuleDeclaration:  return "TSModuleDeclaration"
	case ^TSImportEqualsDeclaration: return "TSImportEqualsDeclaration"
	case ^TSExportAssignment: return "TSExportAssignment"
	case ^TSNamespaceExportDeclaration: return "TSNamespaceExportDeclaration"
	}
	return "Unknown"
}

get_expression_type_name :: proc(e: ^Emitter, expr: ^Expression) -> string {
	#partial switch e in expr^ {
	case ^NullLiteral:           return "NullLiteral"
	case ^BooleanLiteral:        return "BooleanLiteral"
	case ^NumericLiteral:        return "NumericLiteral"
	case ^StringLiteral:         return "StringLiteral"
	case ^BigIntLiteral:         return "BigIntLiteral"
	case ^RegExpLiteral:         return "RegExpLiteral"
	case ^TemplateLiteral:       return "TemplateLiteral"
	case ^TaggedTemplateExpression: return "TaggedTemplateExpression"
	case ^Identifier:            return "Identifier"
	case ^ThisExpression:        return "ThisExpression"
	case ^Super:                 return "Super"
	case ^ChainExpression:       return "ChainExpression"
	case ^ArrayExpression:       return "ArrayExpression"
	case ^ObjectExpression:      return "ObjectExpression"
	case ^FunctionExpression:    return "FunctionExpression"
	case ^ArrowFunctionExpression: return "ArrowFunctionExpression"
	case ^ClassExpression:       return "ClassExpression"
	case ^MemberExpression:      return "MemberExpression"
	case ^CallExpression:        return "CallExpression"
	case ^NewExpression:         return "NewExpression"
	case ^ConditionalExpression: return "ConditionalExpression"
	case ^UpdateExpression:      return "UpdateExpression"
	case ^UnaryExpression:       return "UnaryExpression"
	case ^BinaryExpression:      return "BinaryExpression"
	case ^LogicalExpression:     return "LogicalExpression"
	case ^AssignmentExpression:  return "AssignmentExpression"
	case ^SequenceExpression:    return "SequenceExpression"
	case ^SpreadElement:         return "SpreadElement"
	case ^YieldExpression:       return "YieldExpression"
	case ^AwaitExpression:       return "AwaitExpression"
	case ^ImportExpression:      return "ImportExpression"
	case ^MetaProperty:          return "MetaProperty"
	case ^PrivateIdentifier:     return "PrivateIdentifier"
	case ^JSXElement:            return "JSXElement"
	case ^JSXFragment:           return "JSXFragment"
	case ^JSXText:               return "JSXText"
	case ^JSXExpressionContainer: return "JSXExpressionContainer"
	case ^JSXEmptyExpression:    return "JSXEmptyExpression"
	case ^JSXSpreadChild:        return "JSXSpreadChild"
	case ^TSAsExpression:        return "TSAsExpression"
	case ^TSSatisfiesExpression: return "TSSatisfiesExpression"
	case ^TSNonNullExpression:   return "TSNonNullExpression"
	case ^TSTypeAssertion:       return "TSTypeAssertion"
	case ^TSInstantiationExpression: return "TSInstantiationExpression"
	case ^ParenthesizedExpression: return "ParenthesizedExpression"
	}
	return "Unknown"
}

unary_op_to_string :: proc(op: UnaryOperator) -> string {
	switch op {
	case .Minus:        return "-"
	case .Plus:         return "+"
	case .LogicalNot:   return "!"
	case .BitwiseNot:   return "~"
	case .Typeof:       return "typeof"
	case .Void:         return "void"
	case .Delete:       return "delete"
	}
	return "unknown"
}

binary_op_to_string :: proc(op: BinaryOperator) -> string {
	switch op {
	case .Add:                 return "+"
	case .Sub:                 return "-"
	case .Mul:                 return "*"
	case .Div:                 return "/"
	case .Mod:                 return "%"
	case .Pow:                 return "**"
	case .BitOr:               return "|"
	case .BitXor:              return "^"
	case .BitAnd:              return "&"
	case .ShiftLeft:           return "<<"
	case .ShiftRight:          return ">>"
	case .ShiftRightUnsigned:  return ">>>"
	case .Eq:                  return "=="
	case .NotEq:               return "!="
	case .StrictEq:            return "==="
	case .StrictNotEq:         return "!=="
	case .Lt:                  return "<"
	case .Gt:                  return ">"
	case .LtEq:                return "<="
	case .GtEq:                return ">="
	case .Instanceof:          return "instanceof"
	case .In:                  return "in"
	}
	return "unknown"
}

assignment_op_to_string :: proc(op: AssignmentOperator) -> string {
	switch op {
	case .Assign:              return "="
	case .AddAssign:           return "+="
	case .SubAssign:           return "-="
	case .MulAssign:           return "*="
	case .DivAssign:           return "/="
	case .ModAssign:           return "%="
	case .PowAssign:           return "**="
	case .ShiftLeftAssign:     return "<<="
	case .ShiftRightAssign:    return ">>="
	case .ShiftRightUAssign:   return ">>>="
	case .BitOrAssign:         return "|="
	case .BitXorAssign:        return "^="
	case .BitAndAssign:        return "&="
	case .AssignLogicalAnd:    return "&&="
	case .AssignLogicalOr:     return "||="
	case .AssignNullish:       return "??="
	}
	return "unknown"
}

// Sort the flag characters of a regex flag string in ascending ASCII
// order. All valid ES regex flags (`dgimsuvy`) live in 7-bit ASCII, so a
// byte-level insertion sort is both correct and O(n²)-trivially bounded by
// the 8-flag maximum. The returned slice is freshly allocated in the parser
// arena (via `strings.clone(... , p.allocator)` is overkill here — just use
// the shared temp allocator) and is stable across calls.
sort_regex_flags :: proc(flags: string) -> string {
	n := len(flags)
	if n < 2 { return flags }
	// Fast path: already sorted.
	sorted := true
	for i in 1..<n {
		if flags[i-1] > flags[i] { sorted = false; break }
	}
	if sorted { return flags }
	buf := make([]u8, n, context.temp_allocator)
	for i in 0..<n { buf[i] = flags[i] }
	// Insertion sort — at most 8 distinct ES regex flags, so O(n²) is
	// 64 byte swaps worst case. No need for a heavier algorithm.
	for i in 1..<n {
		k := buf[i]
		j := i
		for ; j > 0 && buf[j-1] > k; j -= 1 {
			buf[j] = buf[j-1]
		}
		buf[j] = k
	}
	return string(buf)
}

// Convert BigInt source representation to decimal string
// Handles: decimal (e.g. "123"), hex (e.g. "0xFF"), octal (e.g. "0o77"),
// binary (e.g. "0b1111"), AND numeric separators in any base (e.g. "1_000n",
// "0xff_ff").
//
// ESTree's `Literal.bigint` field is the decimal integer value as a string,
// with no base prefix, no separators, and no trailing `n` — so `1_000n`
// becomes `"1000"`, `0xff_ffn` becomes `"65535"`. Previously the decimal
// path returned the source slice unchanged, leaking `_` separators into
// `bigint` (e.g. `"1_000"`), which diverged from OXC on any separator-bearing
// literal. Strip separators first and the rest of the logic works unchanged.
bigint_to_decimal :: proc(bigint_source: string) -> string {
	if len(bigint_source) == 0 {
		return bigint_source
	}

	// Remove 'n' suffix if present
	source := bigint_source
	if source[len(source)-1] == 'n' {
		source = source[:len(source)-1]
	}

	if len(source) == 0 {
		return "0"
	}

	// Strip numeric separators (`_`) — valid in every base. Only allocate
	// when we actually find one; clean literals pass through unchanged.
	has_sep := false
	for i in 0..<len(source) {
		if source[i] == '_' { has_sep = true; break }
		}
	if has_sep {
		buf := make([dynamic]u8, 0, len(source), context.temp_allocator)
		for i in 0..<len(source) {
			if source[i] != '_' {
				append(&buf, source[i])
			}
		}
		source = string(buf[:])
	}

	if len(source) == 0 {
		return "0"
	}

	// Check for hex, octal, or binary prefixes
	if len(source) >= 2 && source[0] == '0' {
		switch source[1] {
		case 'x', 'X':
			// Hex: parse as base 16
			if val, ok := strconv.parse_u64(source[2:], 16); ok {
				return fmt.aprint(val)
			}
		case 'o', 'O':
			// Octal: parse as base 8
			if val, ok := strconv.parse_u64(source[2:], 8); ok {
				return fmt.aprint(val)
			}
		case 'b', 'B':
			// Binary: parse as base 2
			if val, ok := strconv.parse_u64(source[2:], 2); ok {
				return fmt.aprint(val)
			}
		}
	}

	// Decimal: separators already stripped above; return as-is.
	return source
}

// ============================================================================
// WTF-8 surrogate helper (moved from main.odin during the #2 deepening)
// ============================================================================

wtf8_surrogate_at :: #force_inline proc(s: string, i: int) -> (cp: u32, ok: bool) {
	if i + 2 >= len(s) { return 0, false }
	b0 := s[i]
	if b0 != 0xED { return 0, false }
	b1 := s[i + 1]
	if b1 < 0xA0 || b1 > 0xBF { return 0, false }
	b2 := s[i + 2]
	if b2 < 0x80 || b2 > 0xBF { return 0, false }
	cp = (u32(b0 & 0x0F) << 12) | (u32(b1 & 0x3F) << 6) | u32(b2 & 0x3F)
	return cp, true
}
