package lexer

// ============================================================================
// ARM64 NEON SIMD - True SIMD Implementation
// Uses Odin's SIMD intrinsics for ARM64 NEON
// ============================================================================

import "core:simd"
import "base:intrinsics"

// SIMD vector type aliases for clarity
Vec16 :: simd.u8x16   // 16 bytes vector

first_set_lane :: proc(mask: Vec16) -> int {
	bits := simd.extract_msbs(mask)
	for lane in bits {
		return int(lane)
	}
	return -1
}

trailing_backslash_odd :: proc(data: []u8) -> bool {
	count := 0
	for i := len(data) - 1; i >= 0; i -= 1 {
		if data[i] != '\\' {
			break
		}
		count += 1
	}
	return (count & 1) == 1
}

quote_is_escaped :: proc(data: []u8, quote_pos: int, carry_backslash_odd: bool) -> bool {
	backslashes := 0
	for i := quote_pos - 1; i >= 0; i -= 1 {
		if data[i] != '\\' {
			break
		}
		backslashes += 1
	}
	if backslashes == quote_pos && carry_backslash_odd {
		backslashes += 1
	}
	return (backslashes & 1) == 1
}

// ============================================================================
// SIMD Whitespace Detection with NEON
// ============================================================================

// Count leading whitespace bytes using NEON
// Returns number of consecutive whitespace chars from start
neon_count_whitespace :: proc(data: []u8) -> int {
	if len(data) < 16 {
		return scalar_count_whitespace(data)
	}
	
	count := 0
	ptr := 0
	end := len(data)
	
	// Create comparison vectors (splat/broadcast)
	space_vec: Vec16 = ' '
	tab_vec: Vec16 = '\t'
	lf_vec: Vec16 = '\n'
	cr_vec: Vec16 = '\r'
	
	// Process 16 bytes at a time using NEON
	for ptr + 16 <= end {
		chunk := (transmute(^Vec16)&data[ptr])^
		cmp_space := simd.lanes_eq(chunk, space_vec)
		cmp_tab   := simd.lanes_eq(chunk, tab_vec)
		cmp_lf    := simd.lanes_eq(chunk, lf_vec)
		cmp_cr    := simd.lanes_eq(chunk, cr_vec)
		is_ws_space := transmute(Vec16)cmp_space
		is_ws_tab   := transmute(Vec16)cmp_tab
		is_ws_lf    := transmute(Vec16)cmp_lf
		is_ws_cr    := transmute(Vec16)cmp_cr
		is_ws := simd.bit_or(simd.bit_or(is_ws_space, is_ws_tab), 
		                     simd.bit_or(is_ws_lf, is_ws_cr))

		all_ws := intrinsics.simd_reduce_and(is_ws)
		if all_ws != 0xFF {
			non_ws_mask := transmute(Vec16)simd.lanes_eq(is_ws, Vec16{})
			lane := first_set_lane(non_ws_mask)
			if lane < 0 {
				break
			}
			return count + lane
		}

		count += 16
		ptr += 16
	}
	
	// Process remaining bytes scalar
	for ptr < end && is_whitespace_fast(data[ptr]) {
		count += 1
		ptr += 1
	}
	
	return count
}

// Find first non-whitespace byte using NEON
// Returns index of first non-whitespace char, or len(data) if all whitespace
neon_find_non_ws :: proc(data: []u8) -> int {
	if len(data) < 32 {
		return scalar_find_non_ws(data)
	}
	
	ptr := 0
	end := len(data)
	
	// Create comparison vectors
	space_vec: Vec16 = ' '
	tab_vec: Vec16 = '\t'
	lf_vec: Vec16 = '\n'
	cr_vec: Vec16 = '\r'
	
	// Align to 16-byte boundary first (for efficient loads)
	for ptr < end && (uintptr(&data[ptr]) & 15) != 0 {
		if !is_whitespace_fast(data[ptr]) {
			return ptr
		}
		ptr += 1
	}
	
	// Process 16 bytes at a time with NEON
	for ptr + 16 <= end {
		chunk := (transmute(^Vec16)&data[ptr])^
		cmp_space := simd.lanes_eq(chunk, space_vec)
		cmp_tab   := simd.lanes_eq(chunk, tab_vec)
		cmp_lf    := simd.lanes_eq(chunk, lf_vec)
		cmp_cr    := simd.lanes_eq(chunk, cr_vec)
		is_ws_space := transmute(Vec16)cmp_space
		is_ws_tab   := transmute(Vec16)cmp_tab
		is_ws_lf    := transmute(Vec16)cmp_lf
		is_ws_cr    := transmute(Vec16)cmp_cr
		is_ws := simd.bit_or(simd.bit_or(is_ws_space, is_ws_tab),
		                     simd.bit_or(is_ws_lf, is_ws_cr))

		all_ws := intrinsics.simd_reduce_and(is_ws)
		if all_ws != 0xFF {
			non_ws_mask := transmute(Vec16)simd.lanes_eq(is_ws, Vec16{})
			lane := first_set_lane(non_ws_mask)
			if lane >= 0 {
				return ptr + lane
			}
		}
		
		ptr += 16
	}
	
	// Remaining bytes
	for ptr < end {
		if !is_whitespace_fast(data[ptr]) {
			return ptr
		}
		ptr += 1
	}
	
	return end
}

// ============================================================================
// SIMD Identifier Scanning with NEON
// ============================================================================

// Count leading identifier characters using NEON
neon_count_ident :: proc(data: []u8) -> int {
	if len(data) < 16 {
		return scalar_count_ident(data)
	}
	
	count := 0
	ptr := 0
	end := len(data)
	
	// Create comparison vectors
	lower_a: Vec16 = 'a'
	lower_z: Vec16 = 'z'
	upper_a: Vec16 = 'A'
	upper_z: Vec16 = 'Z'
	digit_0: Vec16 = '0'
	digit_9: Vec16 = '9'
	underscore: Vec16 = '_'
	dollar: Vec16 = '$'
	
	// Process 16 bytes at a time
	for ptr + 16 <= end {
		chunk := (transmute(^Vec16)&data[ptr])^
		
		// Create masks for valid identifier chars
		// is_lower = (c >= 'a') & (c <= 'z')
		ge_lower := simd.lanes_ge(chunk, lower_a)
		le_lower := simd.lanes_le(chunk, lower_z)
		is_lower := simd.bit_and(transmute(Vec16)ge_lower, transmute(Vec16)le_lower)
		
		// is_upper = (c >= 'A') & (c <= 'Z')
		ge_upper := simd.lanes_ge(chunk, upper_a)
		le_upper := simd.lanes_le(chunk, upper_z)
		is_upper := simd.bit_and(transmute(Vec16)ge_upper, transmute(Vec16)le_upper)
		
		// is_digit = (c >= '0') & (c <= '9')
		ge_digit := simd.lanes_ge(chunk, digit_0)
		le_digit := simd.lanes_le(chunk, digit_9)
		is_digit := simd.bit_and(transmute(Vec16)ge_digit, transmute(Vec16)le_digit)
		
		// is_underscore = c == '_'
		is_underscore := transmute(Vec16)simd.lanes_eq(chunk, underscore)
		
		// is_dollar = c == '$'
		is_dollar := transmute(Vec16)simd.lanes_eq(chunk, dollar)
		
		// is_id = is_lower | is_upper | is_digit | is_underscore | is_dollar
		is_id := simd.bit_or(simd.bit_or(is_lower, is_upper),
		                     simd.bit_or(is_digit, simd.bit_or(is_underscore, is_dollar)))
		
		// Check if all 16 are identifiers using reduce_and
		mask := intrinsics.simd_reduce_and(is_id)
		
		if mask == 0 {
			non_id_mask := transmute(Vec16)simd.lanes_eq(is_id, Vec16{})
			lane := first_set_lane(non_id_mask)
			if lane >= 0 {
				return count + lane
			}
		}
		
		count += 16
		ptr += 16
	}
	
	// Remaining bytes
	for ptr < end && is_id_cont_fast(data[ptr]) {
		count += 1
		ptr += 1
	}
	
	return count
}

// ============================================================================
// SIMD String Quote Finding with NEON
// ============================================================================

// Find unescaped quote in string using NEON
neon_find_quote :: proc(data: []u8, quote: u8) -> int {
	if len(data) < 16 {
		return scalar_find_quote(data, quote)
	}
	
	quote_vec: Vec16 = quote
	backslash: Vec16 = '\\'
	ptr := 0
	end := len(data)
	carry_backslash_odd := false
	
	for ptr + 16 <= end {
		chunk := (transmute(^Vec16)&data[ptr])^
		is_quote := transmute(Vec16)simd.lanes_eq(chunk, quote_vec)
		is_esc   := transmute(Vec16)simd.lanes_eq(chunk, backslash)
		quote_mask := intrinsics.simd_reduce_or(is_quote)
		esc_mask   := intrinsics.simd_reduce_or(is_esc)

		if quote_mask == 0 && esc_mask == 0 {
			carry_backslash_odd = false
			ptr += 16
			continue
		}

		if quote_mask != 0 {
			chunk_data := data[ptr:ptr+16]
			quote_bits := simd.extract_msbs(is_quote)
			for lane in quote_bits {
				quote_pos := int(lane)
				if !quote_is_escaped(chunk_data, quote_pos, carry_backslash_odd) {
					return ptr + quote_pos
				}
			}
		}

		if esc_mask != 0 {
			carry_backslash_odd = trailing_backslash_odd(data[ptr:ptr+16])
		} else {
			carry_backslash_odd = false
		}
		ptr += 16
	}
	
	// Remaining bytes
	return scalar_find_quote(data[ptr:], quote) + ptr
}

// ============================================================================
// SIMD Newline Counting with NEON
// ============================================================================

// Count newlines in a range using NEON
neon_count_newlines :: proc(data: []u8) -> NewlineCount {
	if len(data) < 16 {
		return scalar_count_newlines(data)
	}
	
	count := 0
	last_nl := -1
	ptr := 0
	end := len(data)
	
	lf_vec: Vec16 = '\n'
	
	for ptr + 16 <= end {
		chunk := (transmute(^Vec16)&data[ptr])^
		is_nl := simd.lanes_eq(chunk, lf_vec)
		
		mask := intrinsics.simd_reduce_or(transmute(Vec16)is_nl)
		
		if mask != 0 {
			// Newlines found, count them scalar
			for i := 0; i < 16; i += 1 {
				if data[ptr + i] == '\n' {
					count += 1
					last_nl = ptr + i
				}
			}
		}
		
		ptr += 16
	}
	
	// Remaining bytes
	for ptr < end {
		if data[ptr] == '\n' {
			count += 1
			last_nl = ptr
		}
		ptr += 1
	}
	
	return NewlineCount{count = count, last_nl_pos = last_nl}
}

// ============================================================================
// Exported Functions (Dispatch to NEON or scalar)
// ============================================================================

// Use NEON on ARM64, scalar elsewhere
simd_count_whitespace :: proc(data: []u8) -> int {
	when ODIN_ARCH == .arm64 {
		return neon_count_whitespace(data)
	} else {
		return scalar_count_whitespace(data)
	}
}

simd_find_non_ws :: proc(data: []u8) -> int {
	when ODIN_ARCH == .arm64 {
		return neon_find_non_ws(data)
	} else {
		return scalar_find_non_ws(data)
	}
}

simd_count_ident :: proc(data: []u8) -> int {
	when ODIN_ARCH == .arm64 {
		return neon_count_ident(data)
	} else {
		return scalar_count_ident(data)
	}
}

simd_find_quote :: proc(data: []u8, quote: u8) -> int {
	when ODIN_ARCH == .arm64 {
		return neon_find_quote(data, quote)
	} else {
		return scalar_find_quote(data, quote)
	}
}

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

NewlineCount :: struct {
	count: int,
	last_nl_pos: int,
}

simd_count_newlines :: proc(data: []u8) -> NewlineCount {
	when ODIN_ARCH == .arm64 {
		return neon_count_newlines(data)
	} else {
		return scalar_count_newlines(data)
	}
}

// ============================================================================
// Scalar Fallbacks (for small inputs or non-ARM64)
// ============================================================================

scalar_count_whitespace :: proc(data: []u8) -> int {
	count := 0
	for count < len(data) && is_whitespace_fast(data[count]) {
		count += 1
	}
	return count
}

scalar_find_non_ws :: proc(data: []u8) -> int {
	for i := 0; i < len(data); i += 1 {
		if !is_whitespace_fast(data[i]) {
			return i
		}
	}
	return len(data)
}

scalar_count_ident :: proc(data: []u8) -> int {
	count := 0
	for count < len(data) && is_id_cont_fast(data[count]) {
		count += 1
	}
	return count
}

scalar_find_quote :: proc(data: []u8, quote: u8) -> int {
	i := 0
	for i < len(data) {
		if data[i] == quote {
			return i
		}
		if data[i] == '\\' && i + 1 < len(data) {
			i += 2
		} else {
			i += 1
		}
	}
	return len(data)
}

scalar_count_newlines :: proc(data: []u8) -> NewlineCount {
	count := 0
	last_nl := -1
	for i := 0; i < len(data); i += 1 {
		if data[i] == '\n' {
			count += 1
			last_nl = i
		}
	}
	return NewlineCount{count = count, last_nl_pos = last_nl}
}

// ============================================================================
// Configuration
// ============================================================================

// Check if running on ARM64 with NEON
has_neon :: proc() -> bool {
	when ODIN_ARCH == .arm64 {
		return true
	} else {
		return false
	}
}

// Get optimal chunk size for current platform
optimal_chunk_size :: proc() -> int {
	when ODIN_ARCH == .arm64 {
		return 64  // 4x 16-byte NEON registers
	} else {
		return 32  // SSE/AVX fallback
	}
}
