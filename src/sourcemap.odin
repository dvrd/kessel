package kessel

// ============================================================================
// Source Map v3 generation for codegen output.
// ============================================================================
//
// Spec: https://tc39.es/source-map/
//
// Design notes
// ------------
//
//   * The map is built **post-codegen**, not inline. Codegen records a
//     `(gen_offset, src_offset)` pair into `Codegen.sm.records` at each
//     statement, class member, or expression boundary. The record stores
//     two u32 offsets.
//
//   * After codegen, index the ECMAScript line terminators in both buffers.
//     Forward mappings on one line reuse their previous UTF-16 column.
//
//   * Each (gen_line, gen_col, src_line, src_col) tuple is encoded as a
//     comma-separated VLQ segment in the `mappings` string, segments
//     joined by `;` per line. Columns count UTF-16 code units on both sides.
//
import "core:strings"
import "core:slice"
import "core:mem"

// ----------------------------------------------------------------------------
// Records (gathered during codegen)
// ----------------------------------------------------------------------------

SourceMapRecord :: struct {
	gen_offset: u32,  // byte index into Codegen.buf
	src_offset: u32,  // byte index into the original source
}

SourceMap :: struct {
	records: [dynamic]SourceMapRecord,
	source: string,
}

sourcemap_init :: proc(sm: ^SourceMap, source: string) {
	sm.records = make([dynamic]SourceMapRecord)
	sm.source  = source
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

// ----------------------------------------------------------------------------
// Map serialisation
// ----------------------------------------------------------------------------

SourceMapPosition :: struct {
	line, col, offset: u32,
}

// Convert a byte offset into zero-based line and UTF-16 column coordinates.
sourcemap_position_at :: proc(buf: string, line_offsets: []u32, offset: u32, previous: ^SourceMapPosition) -> (line, col: u32) {
	lo, hi := 0, len(line_offsets) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if line_offsets[mid] <= offset { lo = mid } else { hi = mid - 1 }
	}
	col_u16 := u32(0)
	i := int(line_offsets[lo])
	// Resume a forward scan on the same line. In particular, a minified
	// file can have thousands of mappings on one line.
	if previous.line == u32(lo) && previous.offset <= offset {
		i = int(previous.offset)
		col_u16 = previous.col
	}
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
	previous^ = {line = u32(lo), col = col_u16, offset = offset}
	return previous.line, previous.col
}

// Encode the recorded mappings into a `mappings` VLQ string.
encode_mappings :: proc(sm: ^SourceMap, gen_buf: string) -> string {
	gen_line_offsets := source_line_offsets(gen_buf)
	defer delete(gen_line_offsets)
	src_line_offsets := source_line_offsets(sm.source)
	defer delete(src_line_offsets)

	// Sort records by (gen_offset). They should already be in order, but
	// nested expression emission could theoretically interleave.
	slice.sort_by(sm.records[:], proc(a, b: SourceMapRecord) -> bool {
		return a.gen_offset < b.gen_offset
	})

	sb := strings.builder_make()
	// One segment encoder for this map and for SourceMapBuilder
	// (sourcemap_builder.odin): the delta and separator rules live there.
	state: SourceMapSegmentState
	gen_position, src_position: SourceMapPosition

	for rec in sm.records {
		gen_line, gen_col := sourcemap_position_at(gen_buf, gen_line_offsets, rec.gen_offset, &gen_position)
		src_line, src_col := sourcemap_position_at(sm.source, src_line_offsets, rec.src_offset, &src_position)
		sourcemap_write_segment(&sb, &state, SourceMapMapping{
			generated_line   = gen_line,
			generated_column = gen_col,
			source           = 0, // single-source maps
			original_line    = src_line,
			original_column  = src_col,
			name             = SOURCEMAP_NO_NAME,
		})
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
