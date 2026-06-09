package kessel

// ============================================================================
// Source Map v3 \u2014 sourcemap generation for codegen output.
// ============================================================================
//
// Spec: https://tc39.es/source-map/
//
// Design notes
// ------------
//
//   * The map is built **post-codegen**, not inline. Codegen records a
//     `(gen_offset, src_offset)` pair into `Codegen.sm.records` at each
//     statement boundary; this is a single u32-pair append on a hot path
//     and costs nothing when `sm == nil` (the default for users who don't
//     ask for sourcemaps).
//
//   * Line/column conversion happens once, after the whole buffer is
//     written. Two single passes:
//       1. Walk `cg.buf[:cg.pos]` to compute (line, col) for each gen
//          offset recorded in `sm.records`.
//       2. Walk `source` byte-by-byte (or reuse `line_offsets`) to convert
//          src_offset \u2192 (src_line, src_col).
//
//   * Each (gen_line, gen_col, src_line, src_col) tuple is encoded as a
//     comma-separated VLQ segment in the `mappings` string, segments
//     joined by `;` per line. UTF-16 BMP columns are required by the
//     spec for both gen and src \u2014 we approximate with byte columns when
//     the source is pure ASCII (the common case); when non-ASCII is
//     present we convert byte offsets to UTF-16 units using the same
//     algorithm as `emitter.odin`'s `convert_to_utf16_offset`.
//
//   * Granularity: one mapping per Statement is enough for usable
//     debugger jump-to-source on minified output. Finer-grained
//     per-expression mappings can be layered on later without changing
//     the wire format here.
import "core:strings"
import "core:slice"

// ----------------------------------------------------------------------------
// Records (gathered during codegen)
// ----------------------------------------------------------------------------

SourceMapRecord :: struct {
	gen_offset: u32,  // byte index into Codegen.buf
	src_offset: u32,  // byte index into the original source
}

SourceMap :: struct {
	records: [dynamic]SourceMapRecord,
	// Borrowed from the lexer. Used by offset_to_line_col for the source
	// side. If nil, src_offset \u2192 (line, col) falls back to a fresh scan.
	src_line_offsets: []u32,
	source: string,
}

sourcemap_init :: proc(sm: ^SourceMap, source: string, src_line_offsets: []u32) {
	sm.records          = make([dynamic]SourceMapRecord)
	sm.src_line_offsets = src_line_offsets
	sm.source           = source
}

sourcemap_destroy :: proc(sm: ^SourceMap) {
	if sm.records != nil { delete(sm.records) }
	sm.records = nil
}

// Record a mapping at the current codegen position for a Statement.
// Reuses `get_statement_loc` from the emitter side so both pipelines
// agree on what counts as the "start" of a statement (typically the
// loc.start of the matching variant struct).
cg_record_stmt_mapping :: #force_inline proc(cg: ^Codegen, stmt: ^Statement) {
	if cg.sm == nil { return }
	loc := get_statement_loc(stmt)
	sourcemap_record(cg.sm, u32(cg.pos), loc.start)
}

// Record a mapping at the current codegen position for a class element
// (method, property, accessor, static block). The element's `loc.start`
// points at the first byte the parser saw for this element — typically
// the leading modifier (`static`, `accessor`, `public`, etc.) or the
// key. Mapping each class element lets sourcemap consumers resolve
// `gen L<n>C<col>` queries on method-header lines back to the right
// source position instead of returning (unmapped).
cg_record_class_element_mapping :: #force_inline proc(cg: ^Codegen, el: ^ClassElement) {
	if cg.sm == nil { return }
	sourcemap_record(cg.sm, u32(cg.pos), el.loc.start)
}

// Record a mapping at the current codegen position. Called by codegen
// helpers right before they emit the first byte of a Statement/Expression
// that carries a Loc. `src_offset` is `loc.start`. No-op when `sm == nil`.
sourcemap_record :: #force_inline proc(sm: ^SourceMap, gen_offset, src_offset: u32) {
	if sm == nil { return }
	// Skip duplicates at the same gen position: the latest source
	// location wins (matches OXC's behavior).
	if len(sm.records) > 0 {
		last := &sm.records[len(sm.records) - 1]
		if last.gen_offset == gen_offset {
			last.src_offset = src_offset
			return
		}
	}
	append(&sm.records, SourceMapRecord{gen_offset = gen_offset, src_offset = src_offset})
}

// ----------------------------------------------------------------------------
// Base64-VLQ encoder
// ----------------------------------------------------------------------------
//
// Spec: each value is split into 5-bit groups, low-bit-first; the high
// bit of each digit is the continuation flag; the LSB of the FIRST digit
// is the sign bit. Encoded as base64 (A-Z a-z 0-9 + /).
B64 := [64]byte{
	'A','B','C','D','E','F','G','H','I','J','K','L','M','N','O','P',
	'Q','R','S','T','U','V','W','X','Y','Z','a','b','c','d','e','f',
	'g','h','i','j','k','l','m','n','o','p','q','r','s','t','u','v',
	'w','x','y','z','0','1','2','3','4','5','6','7','8','9','+','/',
}

// Standard base64 (RFC 4648) encoder. Used by codegen_file to embed
// the source-map JSON in an inline `data:application/json;base64,...`
// trailer. Returns a freshly-allocated byte slice the caller must delete.
base64_encode :: proc(input: []byte) -> []byte {
	n := len(input)
	out_len := ((n + 2) / 3) * 4
	out := make([]byte, out_len)
	i, j := 0, 0
	for i + 2 < n {
		v := (u32(input[i]) << 16) | (u32(input[i+1]) << 8) | u32(input[i+2])
		out[j+0] = B64[(v >> 18) & 0x3f]
		out[j+1] = B64[(v >> 12) & 0x3f]
		out[j+2] = B64[(v >>  6) & 0x3f]
		out[j+3] = B64[v & 0x3f]
		i += 3
		j += 4
	}
	switch n - i {
	case 1:
		v := u32(input[i]) << 16
		out[j+0] = B64[(v >> 18) & 0x3f]
		out[j+1] = B64[(v >> 12) & 0x3f]
		out[j+2] = '='
		out[j+3] = '='
	case 2:
		v := (u32(input[i]) << 16) | (u32(input[i+1]) << 8)
		out[j+0] = B64[(v >> 18) & 0x3f]
		out[j+1] = B64[(v >> 12) & 0x3f]
		out[j+2] = B64[(v >>  6) & 0x3f]
		out[j+3] = '='
	}
	return out
}

vlq_encode_into :: proc(buf: ^[dynamic]byte, value: int) {
	v: u32
	if value < 0 {
		v = (u32(-value) << 1) | 1
	} else {
		v = u32(value) << 1
	}
	for {
		digit := v & 0x1f
		v >>= 5
		if v != 0 { digit |= 0x20 }
		append(buf, B64[digit])
		if v == 0 { break }
	}
}

// ----------------------------------------------------------------------------
// Map serialisation
// ----------------------------------------------------------------------------

// Convert a byte offset into (line, col_utf16) for a buffer with the
// given line-offset table. Lines are 0-based, columns are UTF-16 code
// units (BMP \u2192 1 unit, supplementary \u2192 2 units).
offset_to_zero_based_line_col_u16 :: proc(buf: string, line_offsets: []u32, offset: u32) -> (line, col: u32) {
	// Binary search for the largest line_offset <= offset.
	if len(line_offsets) == 0 || offset == 0 {
		return 0, 0
	}
	lo, hi := 0, len(line_offsets) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if line_offsets[mid] <= offset { lo = mid } else { hi = mid - 1 }
	}
	line_start := line_offsets[lo]
	// UTF-16 column: count code units from line_start to offset.
	col_u16 := u32(0)
	i := int(line_start)
	end := int(offset)
	if end > len(buf) { end = len(buf) }
	for i < end {
		b := buf[i]
		if b < 0x80 {
			col_u16 += 1
			i += 1
		} else if b < 0xC0 {
			// Continuation byte, shouldn't be the start of a code point.
			i += 1
		} else if b < 0xE0 {
			col_u16 += 1
			i += 2
		} else if b < 0xF0 {
			col_u16 += 1
			i += 3
		} else {
			// Supplementary plane: 2 UTF-16 units.
			col_u16 += 2
			i += 4
		}
	}
	return u32(lo), col_u16
}

// Build a line-offset table for `buf` in one linear scan. Same shape as
// the lexer's table: indices into `buf` where each line starts.
build_line_offsets :: proc(buf: string) -> []u32 {
	out := make([dynamic]u32, 1, max(64, len(buf) / 32))
	out[0] = 0
	for i in 0..<len(buf) {
		if buf[i] == '\n' {
			append(&out, u32(i + 1))
		}
	}
	return out[:]
}

// Encode the recorded mappings into a `mappings` VLQ string.
encode_mappings :: proc(sm: ^SourceMap, gen_buf: string) -> string {
	gen_line_offsets := build_line_offsets(gen_buf)
	defer delete(gen_line_offsets)

	// Sort records by (gen_offset). They should already be in order, but
	// nested expression emission could theoretically interleave.
	slice.sort_by(sm.records[:], proc(a, b: SourceMapRecord) -> bool {
		return a.gen_offset < b.gen_offset
	})

	sb := strings.builder_make()
	tmp := make([dynamic]byte, 0, 16)
	defer delete(tmp)

	prev_gen_line: u32 = 0
	prev_gen_col:  i64 = 0  // resets per generated line
	prev_src_line: i64 = 0
	prev_src_col:  i64 = 0

	for rec in sm.records {
		gen_line, gen_col := offset_to_zero_based_line_col_u16(gen_buf, gen_line_offsets, rec.gen_offset)

		// Advance generated-line separators. Each `;` resets the col delta.
		for prev_gen_line < gen_line {
			strings.write_byte(&sb, ';')
			prev_gen_line += 1
			prev_gen_col = 0
		}
		// Comma between segments on the same line.
		if strings.builder_len(sb) > 0 {
			last := sb.buf[len(sb.buf) - 1]
			if last != ';' { strings.write_byte(&sb, ',') }
		}

		src_line, src_col := offset_to_zero_based_line_col_u16(sm.source, sm.src_line_offsets, rec.src_offset)

		clear(&tmp)
		vlq_encode_into(&tmp, int(i64(gen_col) - prev_gen_col))
		vlq_encode_into(&tmp, 0) // source index (always 0; single-source maps)
		vlq_encode_into(&tmp, int(i64(src_line) - prev_src_line))
		vlq_encode_into(&tmp, int(i64(src_col)  - prev_src_col))
		strings.write_bytes(&sb, tmp[:])

		prev_gen_col = i64(gen_col)
		prev_src_line = i64(src_line)
		prev_src_col  = i64(src_col)
	}

	return strings.to_string(sb)
}

// Build the full sourcemap JSON. `source_name` is what appears in
// `sources`; `gen_file` is what appears in `file`. `gen_buf` is the
// generated output buffer (Codegen.buf[:Codegen.pos]).
//
// The caller owns the returned string (built from a `strings.Builder`).
sourcemap_to_json :: proc(
	sm: ^SourceMap,
	source_name: string,
	gen_file: string,
	gen_buf: string,
	include_sources_content: bool,
) -> string {
	mappings := encode_mappings(sm, gen_buf)
	defer delete(mappings)

	sb := strings.builder_make()
	strings.write_string(&sb, `{"version":3,"file":`)
	write_json_string(&sb, gen_file)
	strings.write_string(&sb, `,"sourceRoot":"","sources":[`)
	write_json_string(&sb, source_name)
	strings.write_string(&sb, `],"names":[]`)
	if include_sources_content {
		strings.write_string(&sb, `,"sourcesContent":[`)
		write_json_string(&sb, sm.source)
		strings.write_byte(&sb, ']')
	}
	strings.write_string(&sb, `,"mappings":`)
	write_json_string(&sb, mappings)
	strings.write_byte(&sb, '}')
	return strings.to_string(sb)
}

// Minimal JSON string writer for the source-map fields. Handles the
// subset of escapes that can appear in either filenames or JS source:
// backslash, double-quote, control bytes < 0x20 (escaped as `\u00XX`),
// and the JSON-line-terminator pair U+2028 / U+2029 which are valid in
// JS but illegal mid-string in strict-mode JSON consumers.
write_json_string :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	hex := "0123456789abcdef"
	i := 0
	for i < len(s) {
		c := s[i]
		switch c {
		case '"':  strings.write_string(sb, `\"`); i += 1
		case '\\': strings.write_string(sb, `\\`); i += 1
		case '\b': strings.write_string(sb, `\b`); i += 1
		case '\f': strings.write_string(sb, `\f`); i += 1
		case '\n': strings.write_string(sb, `\n`); i += 1
		case '\r': strings.write_string(sb, `\r`); i += 1
		case '\t': strings.write_string(sb, `\t`); i += 1
		case:
			if c < 0x20 {
				strings.write_string(sb, `\u00`)
				strings.write_byte(sb, hex[(c >> 4) & 0xf])
				strings.write_byte(sb, hex[c & 0xf])
				i += 1
			} else if c == 0xE2 && i + 2 < len(s) && s[i+1] == 0x80 && (s[i+2] == 0xA8 || s[i+2] == 0xA9) {
				// U+2028 / U+2029
				strings.write_string(sb, `\u202`)
				strings.write_byte(sb, s[i+2] == 0xA8 ? '8' : '9')
				i += 3
			} else {
				strings.write_byte(sb, c)
				i += 1
			}
		}
	}
	strings.write_byte(sb, '"')
}
