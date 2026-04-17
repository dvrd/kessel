package lexer

// ============================================================================
// ARM64 NEON SIMD - True SIMD Implementation
// Uses Odin's SIMD intrinsics for ARM64 NEON
// ============================================================================

import "core:simd"
import "base:intrinsics"

// SIMD vector type aliases for clarity
Vec16 :: simd.u8x16   // 16 bytes vector

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
		// Load 16 bytes from memory using transmute
		chunk := (transmute(^Vec16)&data[ptr])^
		
		// Compare against whitespace chars using NEON
		// Result is vector of 0 (no match) or 255 (match)
		cmp_space := simd.lanes_eq(chunk, space_vec)
		cmp_tab   := simd.lanes_eq(chunk, tab_vec)
		cmp_lf    := simd.lanes_eq(chunk, lf_vec)
		cmp_cr    := simd.lanes_eq(chunk, cr_vec)
		
		// Combine: whitespace = space | tab | lf | cr
		// Convert bool masks to u8 for OR operation
		is_ws_space := transmute(Vec16)cmp_space
		is_ws_tab   := transmute(Vec16)cmp_tab
		is_ws_lf    := transmute(Vec16)cmp_lf
		is_ws_cr    := transmute(Vec16)cmp_cr
		
		is_ws := simd.bit_or(simd.bit_or(is_ws_space, is_ws_tab), 
		                     simd.bit_or(is_ws_lf, is_ws_cr))
		
		// Reduce OR to check if any whitespace in this chunk
		mask := intrinsics.simd_reduce_or(is_ws)
		
		if mask == 0 {
			// No whitespace in this chunk, stop
			break
		}
		
		// Count consecutive whitespace from start
		// Check first byte
		if !is_whitespace_fast(data[ptr]) {
			break
		}
		
		// Find first non-whitespace in chunk using scalar
		// (NEON doesn't have easy way to find first zero lane)
		for i := 0; i < 16; i += 1 {
			if ptr + i >= end || !is_whitespace_fast(data[ptr + i]) {
				return count + i
			}
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
		
		// Check if all 16 are whitespace
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
		
		mask := intrinsics.simd_reduce_or(is_ws)
		
		// mask != 0xFF means not all bytes are whitespace
		// (each matching byte is 255, so full match = 255)
		if mask != 0xFF {  // Not all match
			// Found non-whitespace, find exact position
			for i := 0; i < 16; i += 1 {
				if !is_whitespace_fast(data[ptr + i]) {
					return ptr + i
				}
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
		// If all are identifiers (255), reduce_and returns 255
		// If any is not identifier (0), reduce_and returns 0
		mask := intrinsics.simd_reduce_and(is_id)
		
		if mask == 0 {
			// Found non-identifier, count scalar within chunk
			for i := 0; i < 16; i += 1 {
				if ptr + i >= end || !is_id_cont_fast(data[ptr + i]) {
					return count + i
				}
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
	
	for ptr + 16 <= end {
		chunk := (transmute(^Vec16)&data[ptr])^
		
		// Find quotes
		is_quote := simd.lanes_eq(chunk, quote_vec)
		
		// Check if any quotes found
		mask := intrinsics.simd_reduce_or(transmute(Vec16)is_quote)
		
		if mask != 0 {
			// Found quote(s), process scalar to handle escapes
			for i := 0; i < 16 && ptr + i < end; i += 1 {
				c := data[ptr + i]
				if c == quote {
					return ptr + i
				}
				if c == '\\' && ptr + i + 1 < end {
					i += 1  // Skip escaped char
				}
			}
		}
		
		// Check for backslash (escape sequences) - need to handle
		is_esc := simd.lanes_eq(chunk, backslash)
		esc_mask := intrinsics.simd_reduce_or(transmute(Vec16)is_esc)
		
		if esc_mask != 0 {
			// Handle escapes in scalar
			for i := 0; i < 16 && ptr + i < end; i += 1 {
				if data[ptr + i] == '\\' && ptr + i + 1 < end {
					// Check if next char is our quote
					if data[ptr + i + 1] == quote {
						i += 1  // Skip escaped quote
					}
				}
			}
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
