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
// SIMD Identifier-body Scanning
// ============================================================================
//
// Find the offset of the first byte that is NOT an ASCII identifier-continue
// character (a-z, A-Z, 0-9, _, $) and is NOT a non-ASCII byte (≥ 0x80) AND
// is NOT a `\` (which the caller must hand off to the escape slow path).
//
// Returns `start` on the first miss (i.e. caller's first byte is already a
// break). Returns `len(src)` if the whole tail is identifier-continue.
//
// On ARM64 NEON we process 16 bytes per iteration with five OR'd range
// checks: lower / upper / digit / [_$] / ≥ 0x80. A backslash byte is also
// flagged as a break so the caller can decide between escape decoding and
// terminating the identifier. The scalar tail handles bytes 0..15 left over.
//
// The byte-by-byte scalar loop in lex_identifier costs ~3 cycles/byte on
// modern Apple Silicon (one CHAR_CLASS_TABLE load + two compares + branch);
// the SIMD chunk costs ~6 cycles for 16 bytes. For identifiers ≥ 8 bytes
// (~half of all identifiers in real-world JS) this halves the inner-loop
// time. We measured ≈50 % of total parse-CPU was lex_token before this
// optimization.
//
// ECMA-262 §12.6: most ASCII whitespace, all line terminators, and many
// Pattern_Syntax characters fall outside IdentifierPart. The SIMD path
// is *deliberately permissive* with high bytes — it accepts every byte
// >= 0x80 as id-cont so that the inner loop never falls out for valid
// non-ASCII identifiers (CJK, Latin-1 letters, ZWJ/ZWNJ, math letters,
// …). Scanning past the (rare) spec-rejected high bytes (U+2028, U+2029,
// U+2E2F, ZWNBSP, …) is corrected by `lex_identifier`, which runs a
// post-pass over the scanned slice ONLY when it actually contains a
// non-ASCII byte. The result: pure-ASCII identifiers (the 99 % case)
// pay zero extra cost, and identifiers with non-ASCII pay one cheap
// scalar walk instead of per-byte UTF-8 decoding inside the hot loop.
simd_scan_id_cont :: #force_inline proc(src: []u8, start: int) -> (end: int, hit_backslash: bool, has_non_ascii: bool) {
	off := start
	src_len := len(src)
	// Short-identifier scalar fast path. Most JS identifiers are 1–7 bytes
	// (single-letter parameters like `i`, `x`; common names like `obj`,
	// `length`, `value`, etc.). Per-chunk SIMD overhead (6 vector compares +
	// reduce_or + mask extract) was dominating over the actual work for
	// these short IDs — the SIMD loop scanned 16 bytes even when the ID
	// terminated after 2-3. Profile of monaco.js showed lex_identifier (the
	// caller of this function) at ~5.7 ms wall time, vs OXC's equivalent at
	// ~2.6 ms. After this change: monaco -4.3 %, cesium -5.4 %.
	when ODIN_ARCH == .arm64 {
		prefix_end := min(off + 8, src_len)
		for off < prefix_end {
			c := src[off]
			if c == '\\' { return off, true, has_non_ascii }
			class := CHAR_CLASS_TABLE[c]
			if class != u8(CharClass.IdStart) && class != u8(CharClass.Digit) {
				return off, false, has_non_ascii
			}
			if c >= 0x80 { has_non_ascii = true }
			off += 1
		}

		lo_a:  Vec16 = 'a'
		lo_z:  Vec16 = 'z'
		up_a:  Vec16 = 'A'
		up_z:  Vec16 = 'Z'
		dg_0:  Vec16 = '0'
		dg_9:  Vec16 = '9'
		under: Vec16 = '_'
		dollr: Vec16 = '$'
		high:  Vec16 = 0x80
		back:  Vec16 = '\\'
		ones:  simd.u8x16 = 0xFF
		for off + 16 <= src_len {
			chunk := (transmute(^Vec16)&src[off])^
			is_lo := transmute(simd.u8x16)simd.lanes_ge(chunk, lo_a) & transmute(simd.u8x16)simd.lanes_le(chunk, lo_z)
			is_up := transmute(simd.u8x16)simd.lanes_ge(chunk, up_a) & transmute(simd.u8x16)simd.lanes_le(chunk, up_z)
			is_di := transmute(simd.u8x16)simd.lanes_ge(chunk, dg_0) & transmute(simd.u8x16)simd.lanes_le(chunk, dg_9)
			is_un := transmute(simd.u8x16)simd.lanes_eq(chunk, under) | transmute(simd.u8x16)simd.lanes_eq(chunk, dollr)
			is_hi := transmute(simd.u8x16)simd.lanes_ge(chunk, high)
			is_bk := transmute(simd.u8x16)simd.lanes_eq(chunk, back)
			// One reduce_or per chunk records whether ANY byte was >= 0x80,
			// so the caller can skip the spec validator entirely for chunks
			// that consumed only ASCII. Cheap (single SIMD op per 16 bytes)
			// and avoids a per-identifier scalar scan in the hot path.
			if intrinsics.simd_reduce_or(transmute(Vec16)is_hi) != 0 {
				has_non_ascii = true
			}
			// is_id includes is_hi: high bytes flow through SIMD as id-cont.
			// The (rare) spec-invalid ones are caught by the post-pass.
			is_id := is_lo | is_up | is_di | is_un | is_hi
			// break_lane = ~is_id | is_bk — every byte that's neither id-cont
			// nor backslash gets msb cleared; backslash flips it back on so
			// the caller can take the escape slow path.
			break_v := transmute(Vec16)((is_id ~ ones) | is_bk)
			mask := simd.extract_msbs(break_v)
			if card(mask) > 0 {
				for lane in mask {
					p := off + int(lane)
					return p, src[p] == '\\', has_non_ascii
				}
			}
			off += 16
		}
	}
	// Scalar tail (and full-loop fallback on non-arm64). Mirrors the SIMD
	// permissiveness: high bytes are accepted unconditionally and validated
	// post-hoc by `lex_identifier`. The CHAR_CLASS_TABLE entry for every
	// byte >= 0x80 is `IdStart`, so the scan terminates only on `\\`,
	// ASCII whitespace/operators, or end-of-source.
	for off < src_len {
		c := src[off]
		if c == '\\' { return off, true, has_non_ascii }
		class := CHAR_CLASS_TABLE[c]
		if class != u8(CharClass.IdStart) && class != u8(CharClass.Digit) { return off, false, has_non_ascii }
		if c >= 0x80 { has_non_ascii = true }
		off += 1
	}
	return src_len, false, has_non_ascii
}

// ============================================================================
// SIMD ASCII Whitespace Skipping
// ============================================================================
//
// Skip a contiguous run of ASCII space (0x20) and horizontal tab (0x09) bytes.
// Returns the offset of the first byte that is neither — `\n`, `\r`, `\v`,
// `\f`, a multi-byte WS lead, `<`, `-`, `/`, an identifier byte, EOF, etc.
//
// This is the inner loop of `lex_token`'s slow-path indent run, hit after
// every LineTerminator in real-world JS/TS where indent depths of 8–32
// spaces are typical (TypeScript compiler bundle: median 20-byte indent
// runs between newlines). The previous scalar `if c == ' ' || c == '\t'
// { off += 1 }` walks one byte per iteration with a load + two compares +
// branch (~3 cycles/byte). The SIMD path handles 16 bytes per ~6 cycles —
// > 8× speedup on indent runs, with the dispatcher's other arms (newlines,
// multi-byte WS, comment starts) untouched and still scalar.
//
// Spec scope (§12.2 / §5.1.1 WhiteSpace): this function ONLY consumes
// 0x20 / 0x09. The caller's outer loop still fires for `\n` / `\r` (so
// `had_line_terminator` flips), `\v` / `\f` (rare so a fast SIMD-skip
// isn't worth the extra compares), and every multi-byte Zs / line
// terminator (NBSP / U+1680 / U+2000-200A / U+2028-2029 / U+202F / U+205F
// / U+3000 / U+FEFF). Annex B `<!--` / `-->` and `//` / `/*` comments are
// also handled by the caller — this function never crosses them.
simd_skip_ascii_ws_run :: #force_inline proc(src: []u8, start: int) -> int {
	off := start
	src_len := len(src)
	when ODIN_ARCH == .arm64 {
		sp_vec:  Vec16 = ' '
		tab_vec: Vec16 = 0x09
		ones:    simd.u8x16 = 0xFF
		for off + 16 <= src_len {
			chunk := (transmute(^Vec16)&src[off])^
			is_sp := simd.lanes_eq(chunk, sp_vec)
			is_tb := simd.lanes_eq(chunk, tab_vec)
			is_ws := transmute(simd.u8x16)is_sp | transmute(simd.u8x16)is_tb
			// `non_ws` flips the MSB of every byte that is NOT space/tab.
			// `extract_msbs` then yields the lane indices of those bytes;
			// the first one is the answer (and we return immediately).
			non_ws := transmute(Vec16)(is_ws ~ ones)
			mask := simd.extract_msbs(non_ws)
			if card(mask) > 0 {
				for lane in mask {
					return off + int(lane)
				}
			}
			off += 16
		}
	}
	// Scalar tail (and full-loop fallback on non-arm64).
	for off < src_len {
		c := src[off]
		if c != ' ' && c != '\t' { return off }
		off += 1
	}
	return src_len
}

// ============================================================================
// SIMD Comment Scanning
// ============================================================================

// Skip line comment: find any LineTerminator. Returns offset AT the
// terminator (or src_len at EOF). Caller has already consumed `//`.
//
// ECMA-262 §12.3 LineTerminator :: <LF> | <CR> | <LS> | <PS>
//
// PERF: the SIMD body uses ONE `lanes_lt(chunk, 0x20)` per 16 bytes —
// the same op count as the old LF-only loop — to detect ANY ASCII
// control character (which includes both LF=0x0A and CR=0x0D, plus
// TAB=0x09 / VT=0x0B / FF=0x0C). When the chunk has only printable
// ASCII or non-ASCII bytes the loop just advances 16 bytes. When it
// hits a control char, the scalar walk inside the chunk pinpoints LF
// or CR (or U+2028 / U+2029 via the 0xE2 lead byte), since spec line
// terminators are LF / CR / LS / PS. TAB and other inert controls
// fall through and the SIMD continues.
simd_skip_line_comment :: #force_inline proc(src: []u8, start: int) -> (end: int, had_nl: bool) {
	off := start
	src_len := len(src)
	ctrl_thresh: Vec16 = 0x20

	for off + 16 <= src_len {
		chunk := (transmute(^Vec16)&src[off])^
		cmp := simd.lanes_lt(chunk, ctrl_thresh)
		any_ctrl := intrinsics.simd_reduce_or(transmute(Vec16)cmp)
		if any_ctrl != 0 {
			// One control byte was found; walk this chunk scalar for the
			// real terminators. Almost always a one-iteration exit — the
			// first control byte in a comment IS the line terminator.
			end_chunk := off + 16
			for i := off; i < end_chunk; i += 1 {
				b := src[i]
				if b == '\n' || b == '\r' { return i, true }
			}
			// All low-byte hits were inert (TAB / VT / FF / NUL). Fall
			// through to advance 16 and keep the SIMD scan going.
		}
		// Independent 0xE2 (U+2028 / U+2029) check within the chunk.
		// LS / PS in line comments are vanishingly rare — a single
		// SIMD compare per chunk is the cost of spec correctness.
		e2_vec: Vec16 = 0xE2
		e2_cmp := simd.lanes_eq(chunk, e2_vec)
		if intrinsics.simd_reduce_or(transmute(Vec16)e2_cmp) != 0 {
			end_chunk := off + 16
			for i := off; i < end_chunk; i += 1 {
				if src[i] == 0xE2 && i + 2 < src_len &&
				   src[i+1] == 0x80 &&
				   (src[i+2] == 0xA8 || src[i+2] == 0xA9) {
					return i, true
				}
			}
		}
		off += 16
	}
	// Scalar tail (and full-loop fallback on non-arm64).
	for off < src_len {
		b := src[off]
		if b == '\n' || b == '\r' { return off, true }
		if b == 0xE2 && off + 2 < src_len &&
		   src[off+1] == 0x80 &&
		   (src[off+2] == 0xA8 || src[off+2] == 0xA9) {
			return off, true
		}
		off += 1
	}
	return src_len, false
}

// Skip block comment: find */ using SIMD. Returns offset past the */.
// Also tracks whether any LineTerminator was encountered (for the
// caller's had_line_terminator). Caller has already consumed `/*`.
//
// ECMA-262 §12.4 — a MultiLineComment containing ANY LineTerminator
// (LF / CR / LS / PS) is itself treated as a LineTerminator for ASI.
// Detect each via:
//   * LF / CR — single SIMD `lanes_lt(chunk, 0x20)` rolls all ASCII
//     control chars into one comparison.
//   * LS / PS (U+2028 / U+2029, UTF-8 `E2 80 A8/A9`) — detect via the
//     0xE2 lead byte with a scalar 3-byte recheck on hit (the 0xE2 may
//     start an ordinary 3-byte char like ☃, so the cont bytes matter).
//
// CORRECTNESS: when both an LT and `*/` appear in the same 16-byte
// chunk we must only count the LT(s) that fall STRICTLY BEFORE the
// first `*/`. Otherwise `/*c*/++;\n}` (where `*/` is lane 7 and `\n`
// is lane 12) would wrongly flip had_line_terminator on, triggering
// ASI for the postfix `++` after the comment.
simd_skip_block_comment :: #force_inline proc(src: []u8, start: int) -> (end: int, had_nl: bool) {
	off := start
	src_len := len(src)
	had_newline := false
	star_vec:  Vec16 = '*'
	slash_vec: Vec16 = '/'
	ctrl_vec:  Vec16 = 0x20
	e2_vec:    Vec16 = 0xE2

	// Process 15 bytes at a time (need 1 byte lookahead for */)
	for off + 16 < src_len {
		chunk := (transmute(^Vec16)&src[off])^
		next_chunk := (transmute(^Vec16)&src[off + 1])^

		star_cmp  := simd.lanes_eq(chunk, star_vec)
		slash_cmp := simd.lanes_eq(next_chunk, slash_vec)
		pair_match := transmute(Vec16)(transmute(simd.u8x16)star_cmp & transmute(simd.u8x16)slash_cmp)
		any_pair := intrinsics.simd_reduce_or(pair_match)

		// Detect comment-body line terminators. `lanes_lt(chunk, 0x20)`
		// catches LF (0x0A), CR (0x0D), and a few inert controls (TAB,
		// VT, FF, NUL). The `lanes_eq(chunk, 0xE2)` lead-byte check
		// handles U+2028 / U+2029 with a scalar continuation re-check on
		// hit so plain 3-byte UTF-8 chars (☃, …) don't false-positive.
		ctrl_cmp := simd.lanes_lt(chunk, ctrl_vec)
		e2_cmp   := simd.lanes_eq(chunk, e2_vec)

		if any_pair != 0 {
			pair_bits := simd.extract_msbs(pair_match)
			ctrl_bits := simd.extract_msbs(transmute(Vec16)ctrl_cmp)
			e2_bits   := simd.extract_msbs(transmute(Vec16)e2_cmp)
			for lane in pair_bits {
				end_pos := off + int(lane) + 2
				// LF / CR before the `*/`.
				if !had_newline {
					for c_lane in ctrl_bits {
						if int(c_lane) >= int(lane) { continue }
						b := src[off + int(c_lane)]
						if b == '\n' || b == '\r' { had_newline = true; break }
					}
				}
				// LS / PS before the `*/` (full E2 80 A8/A9 sequence).
				if !had_newline {
					for e_lane in e2_bits {
						p := off + int(e_lane)
						if p >= off + int(lane) { continue }
						if p + 2 < src_len &&
						   src[p+1] == 0x80 &&
						   (src[p+2] == 0xA8 || src[p+2] == 0xA9) {
							had_newline = true; break
						}
					}
				}
				return end_pos, had_newline
			}
		}
		// No `*/` in this chunk — any LT is inside the comment body.
		if !had_newline {
			if intrinsics.simd_reduce_or(transmute(Vec16)ctrl_cmp) != 0 {
				end_chunk := off + 16
				for i := off; i < end_chunk; i += 1 {
					b := src[i]
					if b == '\n' || b == '\r' { had_newline = true; break }
				}
			}
			if !had_newline && intrinsics.simd_reduce_or(transmute(Vec16)e2_cmp) != 0 {
				end_chunk := off + 16
				for i := off; i < end_chunk; i += 1 {
					if src[i] == 0xE2 && i + 2 < src_len &&
					   src[i+1] == 0x80 &&
					   (src[i+2] == 0xA8 || src[i+2] == 0xA9) {
						had_newline = true; break
					}
				}
			}
		}
		off += 16
	}
	// Scalar tail.
	for off + 1 < src_len {
		b := src[off]
		if b == '\n' || b == '\r' { had_newline = true }
		if b == 0xE2 && off + 2 < src_len &&
		   src[off+1] == 0x80 &&
		   (src[off+2] == 0xA8 || src[off+2] == 0xA9) { had_newline = true }
		if b == '*' && src[off + 1] == '/' { return off + 2, had_newline }
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

// simd_find_module_pre_scan_candidate scans forward from `start` and
// returns the offset of the next byte that the module-syntax pre-scan
// (parser.odin pre_scan_for_module_syntax) needs to inspect. Bytes
// that aren't in the candidate set are skipped 16-at-a-time on ARM64
// NEON — turning the worst case (whole-source scan of a CJS bundle
// with no module syntax) from ~1.3 cycles/byte scalar into ~0.4
// cycles/byte vectorised, a ~3× speedup measured on bench/real_world.
//
// The candidate set is exactly the bytes that change pre-scan state
// or might start an `import` / `export` keyword:
//   /  comment lead
//   '  string
//   "  string
//   `  template
//   {  brace depth +1
//   }  brace depth -1
//   i  potential `import`
//   e  potential `export`
// (Plus byte 0xE2 to allow Unicode line-terminators inside line
// comments to be seen by the caller — not strictly needed for the
// pre-scan since LS/PS only matter for ASI which doesn't run here,
// but keeping the helper fully spec-aware costs nothing extra.)
//
// Returns len(src) when no candidate is found in the rest of the source.
simd_find_module_pre_scan_candidate :: #force_inline proc(src: []u8, start: int) -> int {
	when ODIN_ARCH == .arm64 {
		off := start
		n   := len(src)
		slash_v: Vec16 = '/'
		sq_v:    Vec16 = '\''
		dq_v:    Vec16 = '"'
		bt_v:    Vec16 = '`'
		lb_v:    Vec16 = '{'
		rb_v:    Vec16 = '}'
		i_v:     Vec16 = 'i'
		e_v:     Vec16 = 'e'
		for off + 16 <= n {
			chunk := (transmute(^Vec16)&src[off])^
			hits :=
				transmute(simd.u8x16)simd.lanes_eq(chunk, slash_v) |
				transmute(simd.u8x16)simd.lanes_eq(chunk, sq_v) |
				transmute(simd.u8x16)simd.lanes_eq(chunk, dq_v) |
				transmute(simd.u8x16)simd.lanes_eq(chunk, bt_v) |
				transmute(simd.u8x16)simd.lanes_eq(chunk, lb_v) |
				transmute(simd.u8x16)simd.lanes_eq(chunk, rb_v) |
				transmute(simd.u8x16)simd.lanes_eq(chunk, i_v) |
				transmute(simd.u8x16)simd.lanes_eq(chunk, e_v)
			mask := simd.extract_msbs(transmute(Vec16)hits)
			if card(mask) > 0 {
				for lane in mask { return off + int(lane) }
			}
			off += 16
		}
		// Scalar tail.
		for off < n {
			b := src[off]
			if b == '/' || b == '\'' || b == '"' || b == '`' ||
			   b == '{' || b == '}' || b == 'i' || b == 'e' {
				return off
			}
			off += 1
		}
		return n
	} else {
		off := start
		for off < len(src) {
			b := src[off]
			if b == '/' || b == '\'' || b == '"' || b == '`' ||
			   b == '{' || b == '}' || b == 'i' || b == 'e' {
				return off
			}
			off += 1
		}
		return len(src)
	}
}

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
