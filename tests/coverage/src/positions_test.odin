// Byte offset <-> (line, UTF-16 column) conversion, as a library consumer
// calls it (src/positions.odin).
//
// Method: every case is checked two ways. Hand-written expectations pin the
// conventions (1-based lines, 0-based UTF-16 columns, which bytes end a
// line, where a byte order mark sits). Then `positions_reference` \u2014 a
// deliberately naive decoder that shares no code with the implementation \u2014
// is compared with `source_position_at` at every character boundary of the
// source, and `source_offset_at` must invert each of those positions.
package coverage

import "core:testing"
import "core:unicode/utf8"

import kessel "../../../src"

// Walk `source` one character at a time and return the position of `offset`,
// which must be a character boundary.
@(private = "file")
positions_reference :: proc(source: string, offset: int) -> kessel.SourcePosition {
	position := kessel.SourcePosition{line = 1, column = 0}
	index := 0
	for index < offset {
		character, width := utf8.decode_rune_in_string(source[index:])
		index += width
		is_crlf := character == '\r' && index < len(source) && source[index] == '\n'
		switch {
		case is_crlf:
			// `\r\n` is one terminator; the `\r` still occupies a column
			// until the `\n` ends the line.
			position.column += 1
		case character == '\n' || character == '\r' ||
		     character == '\u2028' || character == '\u2029':
			position.line += 1
			position.column = 0
		case character >= 0x10000:
			position.column += 2
		case:
			position.column += 1
		}
	}
	assert(index == offset)
	return position
}

@(private = "file")
positions_check_all_offsets :: proc(t: ^testing.T, source: string) {
	positions: kessel.SourcePositions
	if !testing.expect(t, kessel.source_positions_init(&positions, source, context.allocator)) {
		return
	}
	defer kessel.source_positions_destroy(&positions)

	offset := 0
	for offset <= len(source) {
		want := positions_reference(source, offset)
		got := kessel.source_position_at(&positions, u32(offset))
		testing.expectf(
			t, got == want, "%q offset %d: got %d:%d, want %d:%d",
			source, offset, got.line, got.column, want.line, want.column,
		)
		// The inverse is exact at every character boundary, `\r\n` included:
		// the `\r` occupies a column of its own.
		back, found := kessel.source_offset_at(&positions, got)
		testing.expectf(
			t, found && int(back) == offset, "%q %d:%d: inverse gave %d (found=%v), want %d",
			source, got.line, got.column, back, found, offset,
		)
		if offset == len(source) { break }
		_, width := utf8.decode_rune_in_string(source[offset:])
		// A byte inside a character reports that character's position.
		for inner in 1..<width {
			inside := kessel.source_position_at(&positions, u32(offset + inner))
			testing.expectf(
				t, inside == want, "%q offset %d (inside a character)", source, offset + inner,
			)
		}
		offset += width
	}
}

@(test)
test_positions_match_reference_decoder :: proc(t: ^testing.T) {
	sources := [?]string{
		"",
		"x",
		"\n",
		"a\nb\n",
		"a\r\nb\r\nc",
		"a\rb\r\rc",
		"a\u2028b\u2029c",
		"\r\n\r\n",
		"\n\r\n\r",
		"caf\u00e9 = \"\u00e9\";\nna\u00efve",
		"let s = \"\U0001F600\";\nlet t = \"a\U0001F600\U0001F600b\";",
		"\ufeffconst x = 1;\r\nconst y = \"\U00010000\u2028\";\n",
		"\u4e2d\u6587\n\U0001F468\u200d\U0001F469\u200d\U0001F467\n",
	}
	for source in sources { positions_check_all_offsets(t, source) }
}

@(test)
test_positions_conventions :: proc(t: ^testing.T) {
	// Bytes:  U+FEFF = 0..2, `a` = 3, U+1F600 = 4..7, `b` = 8, `\r\n` = 9..10,
	//         `c` = 11, `\r` = 12, `d` = 13, U+2028 = 14..16, `e` = 17,
	//         U+2029 = 18..20, `f` = 21.
	source := "\ufeffa\U0001F600b\r\nc\rd\u2028e\u2029f"
	positions: kessel.SourcePositions
	if !testing.expect(t, kessel.source_positions_init(&positions, source, context.allocator)) {
		return
	}
	defer kessel.source_positions_destroy(&positions)

	testing.expect_value(t, kessel.source_positions_line_count(&positions), 5)
	Case :: struct { offset: u32, line: u32, column: u32 }
	cases := [?]Case{
		{0, 1, 0},  // the byte order mark is column 0 of line 1
		{3, 1, 1},  // `a` follows it
		{4, 1, 2},  // astral character
		{8, 1, 4},  // ...is two UTF-16 code units wide
		{9, 1, 5},  // `\r` of `\r\n`
		{10, 1, 6}, // `\n` of `\r\n`: still line 1
		{11, 2, 0}, // `c`
		{12, 2, 1}, // lone `\r`
		{13, 3, 0}, // `d`
		{14, 3, 1}, // U+2028 ends line 3
		{17, 4, 0}, // `e`
		{21, 5, 0}, // `f` after U+2029
		{22, 5, 1}, // end of source
		{1000, 5, 1}, // past the end clamps to the end
	}
	for position_case in cases {
		got := kessel.source_position_at(&positions, position_case.offset)
		testing.expectf(
			t, got.line == position_case.line && got.column == position_case.column,
			"offset %d: got %d:%d, want %d:%d",
			position_case.offset, got.line, got.column, position_case.line, position_case.column,
		)
	}

	// Inverse: positions that do not exist are rejected, never clamped.
	offset, found := kessel.source_offset_at(&positions, {line = 1, column = 4})
	testing.expect(t, found)
	testing.expect_value(t, offset, 8)
	// Column 3 is the low surrogate of the astral character at byte 4.
	offset, found = kessel.source_offset_at(&positions, {line = 1, column = 3})
	testing.expect(t, found)
	testing.expect_value(t, offset, 4)
	// Line 1 has 7 code units including `\r\n`; column 7 is its end.
	offset, found = kessel.source_offset_at(&positions, {line = 1, column = 7})
	testing.expect(t, found)
	testing.expect_value(t, offset, 11)
	_, found = kessel.source_offset_at(&positions, {line = 1, column = 8})
	testing.expect(t, !found, "column past the end of the line")
	_, found = kessel.source_offset_at(&positions, {line = 0, column = 0})
	testing.expect(t, !found, "lines are 1-based")
	_, found = kessel.source_offset_at(&positions, {line = 6, column = 0})
	testing.expect(t, !found, "line past the end of the source")
	_, found = kessel.source_offset_at(&positions, {line = 5, column = 2})
	testing.expect(t, !found, "column past the end of the last line")
}

// ASCII-only sources take the path without a UTF-16 table.
@(test)
test_positions_ascii_source :: proc(t: ^testing.T) {
	source := "const a = 1;\nconst b = 2;\r\nconst c = 3;"
	positions: kessel.SourcePositions
	if !testing.expect(t, kessel.source_positions_init(&positions, source, context.allocator)) {
		return
	}
	defer kessel.source_positions_destroy(&positions)
	testing.expect(t, positions.utf16_offsets == nil, "ASCII sources need no UTF-16 table")
	testing.expect_value(t, kessel.source_position_at(&positions, 19), kessel.SourcePosition{2, 6})
	offset, found := kessel.source_offset_at(&positions, {line = 3, column = 6})
	testing.expect(t, found)
	testing.expect_value(t, offset, 33)
	_, found = kessel.source_offset_at(&positions, {line = 2, column = 15})
	testing.expect(t, !found)
}

// The typed AST carries byte offsets; this is the conversion a consumer does
// to report an AST node in editor coordinates.
@(test)
test_positions_for_ast_node :: proc(t: ^testing.T) {
	source := "const s = \"\U0001F600\";\nlet \u00e9t\u00e9 = s;"
	job: kessel.ParseJob
	if !testing.expect(t, kessel.parse_job_open_inline(&job, source, {}, "positions.js")) { return }
	defer kessel.parse_job_close(&job)
	kessel.parse_job_run(&job)
	if !testing.expect_value(t, len(job.parser.errors), 0) { return }
	if !testing.expect_value(t, len(job.program.body), 2) { return }

	positions: kessel.SourcePositions
	if !testing.expect(t, kessel.source_positions_init(&positions, source, context.allocator)) {
		return
	}
	defer kessel.source_positions_destroy(&positions)

	declaration, is_declaration := job.program.body[1].(^kessel.VariableDeclaration)
	if !testing.expect(t, is_declaration) { return }
	testing.expect_value(
		t, kessel.source_position_at(&positions, declaration.loc.start),
		kessel.SourcePosition{line = 2, column = 0},
	)
	// The second statement is 12 UTF-16 code units but 14 bytes long.
	testing.expect_value(
		t, kessel.source_position_at(&positions, declaration.loc.end),
		kessel.SourcePosition{line = 2, column = 12},
	)
}
