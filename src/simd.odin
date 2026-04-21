package main

// ============================================================================
// ARM64 NEON SIMD - True SIMD Implementation
// Uses Odin's SIMD intrinsics for ARM64 NEON
// ============================================================================

import "core:simd"
import "base:intrinsics"

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
