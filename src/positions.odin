package kessel

// ============================================================================
// positions.odin — byte offsets <-> (line, UTF-16 column)
// ============================================================================
//
// Every `Loc` in the typed AST and every `ParseError` span is a UTF-8 byte
// offset into the source. Editors, the Language Server Protocol, source maps
// and ESTree `loc` objects count columns in UTF-16 code units instead. This
// module converts between the two for library consumers:
//
//   positions: SourcePositions
//   if !source_positions_init(&positions, source, allocator) { ... }
//   defer source_positions_destroy(&positions)
//
//   position := source_position_at(&positions, node.loc.start)
//   offset, found := source_offset_at(&positions, position)
//
// Conventions (the ones ESTree `loc` uses, and what `kessel parse --loc`
// prints): lines are 1-based, columns are 0-based UTF-16 code units. A line
// ends after `\n`, `\r\n` (one terminator), a lone `\r`, U+2028 or U+2029. A
// byte order mark is an ordinary character of line 1 and occupies column 0.
//
// The tables are the ones the JSON emitter uses for `start` / `end` / `loc`
// (`source_line_offsets` and `simd_build_utf16_offsets`), built here without
// an emitter, so the two can never disagree about a position.
//
// Cost: `init` is one pass over the source for the line table, plus one pass
// and 4 bytes per source byte for the UTF-16 table when the source holds a
// non-ASCII byte (ASCII-only sources skip that table). A lookup is a binary
// search over the lines; nothing is rescanned, so a one-line minified bundle
// costs the same per lookup as any other file.

import "core:mem"

// 1-based line, 0-based column in UTF-16 code units.
SourcePosition :: struct {
	line:   u32,
	column: u32,
}

SourcePositions :: struct {
	// Borrowed: the caller keeps the source alive while this index is used.
	source:        string,
	// Byte offset of the first byte of each line; `line_offsets[0] == 0`.
	line_offsets:  []u32,
	// `utf16_offsets[byte]` is the UTF-16 offset of the character holding
	// that byte; one extra entry for the end of the source. nil when the
	// source is ASCII-only, where byte and UTF-16 offsets are equal.
	utf16_offsets: []u32,
	allocator:     mem.Allocator,
}

// Offsets are u32 everywhere in Kessel, so that is the largest source the
// index can describe.
SOURCE_POSITIONS_SOURCE_SIZE_MAX :: 1 << 32 - 1

// Build the index for `source`. Returns false, leaving `positions` zeroed,
// when the source is too large to address with u32 offsets or a table could
// not be allocated. `allocator` owns the tables until
// `source_positions_destroy`.
source_positions_init :: proc(
	positions: ^SourcePositions,
	source: string,
	allocator: mem.Allocator,
) -> bool {
	assert(positions != nil)
	positions^ = {}
	if len(source) > SOURCE_POSITIONS_SOURCE_SIZE_MAX { return false }

	line_offsets := source_line_offsets(source, allocator)
	if len(line_offsets) == 0 { return false }
	assert(line_offsets[0] == 0)

	utf16_offsets: []u32
	bytes := transmute([]u8)source
	if simd_has_multibyte(bytes) {
		utf16_offsets = simd_build_utf16_offsets(bytes, allocator)
		if len(utf16_offsets) != len(source) + 1 {
			delete(line_offsets, allocator)
			return false
		}
	}

	positions^ = SourcePositions{
		source        = source,
		line_offsets  = line_offsets,
		utf16_offsets = utf16_offsets,
		allocator     = allocator,
	}
	return true
}

source_positions_destroy :: proc(positions: ^SourcePositions) {
	assert(positions != nil)
	if positions.line_offsets != nil { delete(positions.line_offsets, positions.allocator) }
	if positions.utf16_offsets != nil { delete(positions.utf16_offsets, positions.allocator) }
	positions^ = {}
}

// Number of lines; at least 1, since an empty source is one empty line.
source_positions_line_count :: proc(positions: ^SourcePositions) -> u32 {
	assert(len(positions.line_offsets) >= 1)
	return u32(len(positions.line_offsets))
}

// Position of a byte offset. An offset past the end of the source is treated
// as the end. An offset inside a multi-byte character gives the position of
// that character.
source_position_at :: proc(positions: ^SourcePositions, offset: u32) -> SourcePosition {
	assert(len(positions.line_offsets) >= 1)
	clamped := min(offset, u32(len(positions.source)))

	// Last line whose start is <= clamped. Line 0 starts at 0, so one exists.
	low, high := u32(0), u32(len(positions.line_offsets))
	for low + 1 < high {
		middle := low + (high - low) / 2
		if positions.line_offsets[middle] <= clamped { low = middle } else { high = middle }
	}
	line_start := positions.line_offsets[low]
	assert(line_start <= clamped)

	column := source_positions_utf16(positions, clamped) -
	          source_positions_utf16(positions, line_start)
	return SourcePosition{line = low + 1, column = column}
}

// Byte offset of a position: the inverse of `source_position_at`. `found` is
// false when the line does not exist or the column lies beyond the end of the
// line (its terminator included). A column that falls between the two
// surrogates of an astral character gives the offset of that character, since
// no byte offset exists in the middle of it.
source_offset_at :: proc(
	positions: ^SourcePositions,
	position: SourcePosition,
) -> (offset: u32, found: bool) {
	assert(len(positions.line_offsets) >= 1)
	if position.line == 0 { return 0, false }
	if position.line > u32(len(positions.line_offsets)) { return 0, false }

	line_start := positions.line_offsets[position.line - 1]
	line_end := u32(len(positions.source))
	if position.line < u32(len(positions.line_offsets)) {
		line_end = positions.line_offsets[position.line]
	}
	assert(line_start <= line_end)

	if positions.utf16_offsets == nil {
		// ASCII-only: one byte per code unit.
		if position.column > line_end - line_start { return 0, false }
		return line_start + position.column, true
	}

	line_start_utf16 := positions.utf16_offsets[line_start]
	line_end_utf16   := positions.utf16_offsets[line_end]
	if position.column > line_end_utf16 - line_start_utf16 { return 0, false }
	target := line_start_utf16 + position.column

	// First byte in [line_start, line_end] whose UTF-16 offset is >= target.
	// The table never decreases, and `line_end` satisfies the condition.
	low, high := line_start, line_end
	for low < high {
		middle := low + (high - low) / 2
		if positions.utf16_offsets[middle] >= target { high = middle } else { low = middle + 1 }
	}
	if positions.utf16_offsets[low] == target { return low, true }

	// No byte has this offset: `target` is the low surrogate of the 4-byte
	// character that ends just before `low`.
	assert(positions.utf16_offsets[low] == target + 1)
	assert(low >= line_start + 4)
	return low - 4, true
}

// UTF-16 offset of a byte offset that is known to lie inside the source.
@(private = "file")
source_positions_utf16 :: #force_inline proc(positions: ^SourcePositions, offset: u32) -> u32 {
	assert(int(offset) <= len(positions.source))
	if positions.utf16_offsets == nil { return offset }
	return positions.utf16_offsets[offset]
}
