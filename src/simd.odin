package main

// ============================================================================
// ARM64 NEON SIMD - True SIMD Implementation
// Uses Odin's SIMD intrinsics for ARM64 NEON
// ============================================================================

import "core:simd"
import "base:intrinsics"
import "core:mem"

// SIMD vector type aliases for clarity
Vec16 :: simd.u8x16   // 16 bytes vector


// Find first quote or backslash — returns (position, is_quote)
// If returns len(data), neither was found in the scanned range.
simd_find_string_end :: proc(data: []u8, quote: u8) -> (pos: int, found_quote: bool) {
	when ODIN_ARCH == .arm64 {
		q_vec: Vec16 = quote
		b_vec: Vec16 = '\\'
		ptr := 0
		for ptr + 16 <= len(data) {
			chunk := (transmute(^Vec16)&data[ptr])^
			is_q := simd.lanes_eq(chunk, q_vec)
			is_b := simd.lanes_eq(chunk, b_vec)
			combined := transmute(Vec16)(transmute(simd.u8x16)is_q | transmute(simd.u8x16)is_b)
			mask := simd.extract_msbs(combined)
			if card(mask) > 0 {
				// Find first set lane
				for lane in mask {
					p := ptr + int(lane)
					return p, data[p] == quote
				}
			}
			ptr += 16
		}
		// Scalar tail
		for ptr < len(data) {
			if data[ptr] == quote { return ptr, true }
			if data[ptr] == '\\' { return ptr, false }
			ptr += 1
		}
		return len(data), false
	} else {
		for i := 0; i < len(data); i += 1 {
			if data[i] == quote { return i, true }
			if data[i] == '\\' { return i, false }
		}
		return len(data), false
	}
}

// ============================================================================
// SIMD Comment Scanning
// ============================================================================

// Skip line comment: find \n using SIMD. Returns offset past the newline (or src_len).
// Caller has already consumed the leading //.
simd_skip_line_comment :: #force_inline proc(src: []u8, start: int) -> (end: int, had_nl: bool) {
	off := start
	src_len := len(src)
	nl_vec: Vec16 = '\n'

	for off + 16 <= src_len {
		chunk := (transmute(^Vec16)&src[off])^
		cmp := simd.lanes_eq(chunk, nl_vec)
		any_nl := intrinsics.simd_reduce_or(transmute(Vec16)cmp)
		if any_nl != 0 {
			// Found newline — find which lane
			bits := simd.extract_msbs(transmute(Vec16)cmp)
			for lane in bits {
				return off + int(lane), true
			}
		}
		off += 16
	}
	// Scalar tail
	for off < src_len {
		if src[off] == '\n' { return off, true }
		off += 1
	}
	return src_len, false
}

// Skip block comment: find */ using SIMD. Returns offset past the */.
// Also tracks whether any newline was encountered (for had_line_terminator).
// Caller has already consumed the leading /*.
simd_skip_block_comment :: #force_inline proc(src: []u8, start: int) -> (end: int, had_nl: bool) {
	off := start
	src_len := len(src)
	had_newline := false
	star_vec: Vec16 = '*'
	nl_vec: Vec16 = '\n'
	slash_vec: Vec16 = '/'

	// Process 15 bytes at a time (need 1 byte lookahead for */)
	for off + 16 < src_len {
		chunk := (transmute(^Vec16)&src[off])^
		next_chunk := (transmute(^Vec16)&src[off + 1])^

		// Check for \n
		nl_cmp := simd.lanes_eq(chunk, nl_vec)
		any_nl := intrinsics.simd_reduce_or(transmute(Vec16)nl_cmp)
		if any_nl != 0 { had_newline = true }

		// Check for */ pair: chunk[i]=='*' AND chunk[i+1]=='/'
		star_cmp := simd.lanes_eq(chunk, star_vec)
		slash_cmp := simd.lanes_eq(next_chunk, slash_vec)
		pair_match := transmute(Vec16)(transmute(simd.u8x16)star_cmp & transmute(simd.u8x16)slash_cmp)
		any_pair := intrinsics.simd_reduce_or(pair_match)

		if any_pair != 0 {
			// Found */ — find first position
			bits := simd.extract_msbs(pair_match)
			for lane in bits {
				return off + int(lane) + 2, had_newline
			}
		}
		off += 16
	}
	// Scalar tail
	for off + 1 < src_len {
		if src[off] == '\n' { had_newline = true }
		if src[off] == '*' && src[off + 1] == '/' { return off + 2, had_newline }
		off += 1
	}
	return src_len, had_newline
}

// ============================================================================
// SIMD UTF-8 → UTF-16 Offset Conversion
//
// ESTree positions are UTF-16 code unit indices. Kessel's lexer tracks byte
// offsets. For files with multi-byte UTF-8 characters, we precompute a
// byte→UTF-16 mapping table. SIMD accelerates both the ASCII detection
// (skip table entirely for pure-ASCII files) and the ASCII-only chunks
// during table construction.
//
// Reference: Lemire, "Efficient In-Place UTF-16 Unicode Correction with
// ARM NEON" (2024). The core insight — SIMD byte classification for
// UTF encoding properties — is adapted here for offset table construction.
// ============================================================================

// simd_has_multibyte returns true if source contains any byte >= 0x80.
// Processes 16 bytes per iteration on ARM64 NEON; scalar fallback otherwise.
// simd_has_multibyte uses Odin's cross-platform SIMD (SSE2 on x86-64,
// NEON on ARM64) to scan 16 bytes per iteration.
simd_has_multibyte :: proc(source: []u8) -> bool {
	high_bit: Vec16 = 0x80
	off := 0
	for off + 16 <= len(source) {
		chunk := (transmute(^Vec16)&source[off])^
		test := simd.lanes_ge(chunk, high_bit)
		if intrinsics.simd_reduce_or(transmute(Vec16)test) != 0 {
			return true
		}
		off += 16
	}
	// Scalar tail.
	for off < len(source) {
		if source[off] >= 0x80 { return true }
		off += 1
	}
	return false
}

// simd_build_utf16_offsets builds the byte→UTF-16 offset lookup table.
// For each byte position, stores the corresponding UTF-16 code unit index.
//
// Multi-byte UTF-8 characters span 2-4 bytes but map to 1 (or 2 for
// surrogates) UTF-16 code unit. ALL bytes within a character must get the
// SAME table value — the UTF-16 index of that character's start.
//
// A naive per-byte prefix-sum is INCORRECT: it would advance the offset at
// the lead byte, causing continuation bytes to see the wrong (incremented)
// value. Instead we step through characters (variable-width), assigning
// the lead byte's offset to all bytes in the character.
//
// SIMD acceleration: for chunks that are all-ASCII (the common case in JS
// source), we bypass the character-stepping loop and fill 16 table entries
// with a simple running_total + 0..15 sequence. Only chunks containing
// multi-byte characters fall back to the correct scalar character-step.
simd_build_utf16_offsets :: proc(source: []u8, alloc: mem.Allocator) -> []u32 {
	table := make([]u32, len(source) + 1, alloc)
	utf16_pos: u32 = 0
	i := 0

	// SIMD fast path: Odin's simd package is cross-platform (SSE2 on x86-64,
	// NEON on ARM64). Check 16 bytes at a time; all-ASCII chunks get a fast
	// linear fill. Only multi-byte chunks fall back to character-stepping.
	v_high: Vec16 = 0x80
	for i + 16 <= len(source) {
		chunk := (transmute(^Vec16)&source[i])^
		test := simd.lanes_ge(chunk, v_high)
		if intrinsics.simd_reduce_or(transmute(Vec16)test) == 0 {
			// All ASCII: fast fill — table[i+k] = utf16_pos + k.
			for k in 0..<16 { table[i + k] = utf16_pos + u32(k) }
			utf16_pos += 16
			i += 16
		} else {
			// Chunk has multi-byte chars. Scalar character-step through
			// to correctly assign continuation bytes the lead's offset.
			end := min(i + 16, len(source))
			for i < end {
				table[i] = utf16_pos
				b := source[i]
				if b < 0x80 {
					i += 1; utf16_pos += 1
				} else if b < 0xE0 {
					if i+1 < len(source) { table[i+1] = utf16_pos }
					i += 2; utf16_pos += 1
				} else if b < 0xF0 {
					for j in 1..<3 { if i+j < len(source) { table[i+j] = utf16_pos } }
					i += 3; utf16_pos += 1
				} else {
					for j in 1..<4 { if i+j < len(source) { table[i+j] = utf16_pos } }
					i += 4; utf16_pos += 2
				}
			}
		}
	}

	// Scalar tail (or entire loop on non-ARM64).
	for i < len(source) {
		table[i] = utf16_pos
		b := source[i]
		if b < 0x80 {
			i += 1; utf16_pos += 1
		} else if b < 0xE0 {
			if i+1 < len(source) { table[i+1] = utf16_pos }
			i += 2; utf16_pos += 1
		} else if b < 0xF0 {
			for j in 1..<3 { if i+j < len(source) { table[i+j] = utf16_pos } }
			i += 3; utf16_pos += 1
		} else {
			for j in 1..<4 { if i+j < len(source) { table[i+j] = utf16_pos } }
			i += 4; utf16_pos += 2
		}
	}

	table[len(source)] = utf16_pos
	return table
}
