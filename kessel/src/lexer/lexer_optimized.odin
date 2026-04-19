package lexer

// ============================================================================
// OPTIMIZED LEXER
// Integrates compact tokens (SoA) + SIMD scanning
// ============================================================================

import "core:mem"
import "core:fmt"
import "core:unicode"
import "core:unicode/utf8"
import "core:strconv"

// Lexer2 is the optimized lexer using compact tokens
Lexer2 :: struct {
	// Source
	source:     string,
	source_bytes: []u8,
	offset:     int,

	// Lazy line/column: only offset tracked during lexing.
	// line_offsets[i] = byte offset of the start of line i+1.
	// line_offsets[0] = 0 (line 1 starts at offset 0).
	line_offsets: []u32,
	num_lines:   u32,

	// Legacy: kept for code that still reads l.line / l.column
	line:       int,
	column:     int,
	
	// Allocator for memory allocations
	allocator:  mem.Allocator,
	
	// Token storage (SoA)
	token_soa:  TokenSoA,
	
	// Token ring buffer for lookahead
	ring:       TokenRing,
	
	// State for template literals
	template_stack: [dynamic]bool,
	in_template: bool,
	
	// Context flags
	jsx_context: bool,
	strict_mode: bool,
	
	// Track last emitted token type for regex context detection
	last_token_type: TokenType,
	
	// Hashbang: track if we're at start of file
	at_start_of_file: bool,
	
	// ASI: track if there was a line terminator before the current token
	had_line_terminator: bool,
	
	// Statistics for debugging
	stats: LexerStats,
}

// Build line offset table in a single pre-pass
build_line_table :: proc(l: ^Lexer2) {
	src := l.source_bytes
	src_len := len(src)
	// Estimate: 1 line per 40 chars on average
	cap := max(src_len / 40 + 16, 256)
	lines := make([]u32, cap, l.allocator)
	lines[0] = 0  // line 1 starts at offset 0
	count: u32 = 1
	for i := 0; i < src_len; i += 1 {
		if src[i] == '\n' {
			if int(count) >= len(lines) {
				// Rare: more lines than estimate. Just stop tracking.
				break
			}
			lines[count] = u32(i + 1)
			count += 1
		}
	}
	l.line_offsets = lines[:count]
	l.num_lines = count
}

// Compute line number from byte offset using binary search on line_offsets
offset_to_line_col :: proc(line_offsets: []u32, offset: u32) -> (line: u32, col: u32) {
	// Binary search for the largest line_offsets[i] <= offset
	lo : u32 = 0
	hi := u32(len(line_offsets))
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if line_offsets[mid] <= offset {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	// lo-1 is the line index (0-based), line number is lo (1-based)
	line_idx := lo - 1 if lo > 0 else 0
	return line_idx + 1, offset - line_offsets[line_idx] + 1
}

LexerStats :: struct {
	tokens_created: u32,
	simd_chunks_processed: u32,
	scalar_fallbacks: u32,
}

// ============================================================================
// Arena Pre-sizing Estimation
// ============================================================================

// Estimate required arena size based on source characteristics
// Heuristic: ~128x source size for large JS to leave headroom for AST-heavy inputs
estimate_arena_size :: proc(source_len: int) -> int {
	// Base: 256 bytes per source byte for tokens + AST.
	// Large files with many nodes can exceed lower estimates.
	base_size := source_len * 256
	
	// Minimum: 4MB for small files
	if base_size < 4 * 1024 * 1024 {
		return 4 * 1024 * 1024
	}
	
	// Maximum: 1GB for very large files (may need to adjust for system limits)
	if base_size > 1024 * 1024 * 1024 {
		return 1024 * 1024 * 1024
	}
	
	return base_size
}

// Estimate token capacity based on source size
// Heuristic: ~1 token per 2 chars on average for punctuation-heavy JS
estimate_token_capacity :: proc(source_len: int) -> int {
	// source_len / 2 gives ~2x headroom over typical usage (~source_len / 4 actual tokens)
	return max(source_len / 2, 4096)
}

// Initialize optimized lexer
init_lexer2 :: proc(l: ^Lexer2, source: string, alloc: mem.Allocator) {
	l.source = source
	l.source_bytes = transmute([]u8)source
	l.offset = 0
	l.line = 1
	
	l.allocator = alloc
	
	// Build line offset table for lazy line/column computation
	// (pre-scan ~150us for 300KB, amortized over parse)
	build_line_table(l)
	l.jsx_context = false
	l.strict_mode = false
	l.last_token_type = .EOF  // Start of input allows regex
	l.at_start_of_file = true
	
	// Pre-size token storage based on source length
	token_capacity := estimate_token_capacity(len(source))
	init_token_soa(&l.token_soa, alloc, token_capacity)
	
	// Initialize token ring
	init_token_ring(&l.ring, &l.token_soa)
	
	// Initialize template stack
	l.template_stack = make([dynamic]bool, alloc)
	
	// Reset stats
	l.stats = {}
	
	// Prime the lexer with first tokens
	prime_lexer(l)
}

// Prime the lexer with initial tokens
prime_lexer :: proc(l: ^Lexer2) {
	// Handle hashbang at absolute start of file
	if l.at_start_of_file && l.offset + 1 < len(l.source) && l.source_bytes[l.offset] == '#' && l.source_bytes[l.offset + 1] == '!' {
		for l.offset < len(l.source) {
			c := l.source_bytes[l.offset]
			l.offset += 1
			if c == '\n' {
				
				
				break
			}
		}
	}
	l.at_start_of_file = false

	// Prime 2-slot pair: current + next
	tok0 := lex_next_compact(l)
	l.ring.cur = tok0
	l.ring.cur_type = l.last_token_type
	if l.ring.cur_type != .EOF {
		tok1 := lex_next_compact(l)
		l.ring.nxt = tok1
		l.ring.nxt_type = l.last_token_type
		l.ring.has_next = true
	}
}

// Get current token
get_current2 :: #force_inline proc(l: ^Lexer2) -> CompactToken {
	return ring_peek(&l.ring, 0)
}

// Advance to next token — shift next→current, lex new next
next2 :: #force_inline proc(l: ^Lexer2) -> CompactToken {
	old := l.ring.cur
	// Shift next → current
	l.ring.cur = l.ring.nxt
	l.ring.cur_type = l.ring.nxt_type
	// Lex new next (only if current wasn't EOF)
	if l.ring.cur_type != .EOF {
		tok := lex_next_compact(l)
		l.ring.nxt = tok
		l.ring.nxt_type = l.last_token_type  // already set by lex_next_compact
		l.ring.has_next = true
	} else {
		l.ring.nxt = CompactToken{index = INVALID_TOKEN_INDEX, soa = l.ring.soa}
		l.ring.nxt_type = .EOF
		l.ring.has_next = false
	}
	return old
}

// Peek at next token
peek2_compact :: proc(l: ^Lexer2) -> CompactToken {
	return ring_peek(&l.ring, 1)
}

// Peek two tokens ahead
peek2_ahead :: proc(l: ^Lexer2) -> CompactToken {
	return ring_peek(&l.ring, 2)
}

// Check current token type
is2 :: #force_inline proc(l: ^Lexer2, type_: TokenType) -> bool {
	return ring_peek_type(&l.ring, 0) == type_
}

// ============================================================================
// Single-char token lookup table (128 ASCII entries)
// ============================================================================

single_char_tokens: [128]TokenType

@(init)
init_single_char_table :: proc "contextless" () {
	for i in 0..<128 { single_char_tokens[i] = .Invalid }
	single_char_tokens['{'] = .LBrace
	single_char_tokens['}'] = .RBrace
	single_char_tokens['('] = .LParen
	single_char_tokens[')'] = .RParen
	single_char_tokens['['] = .LBracket
	single_char_tokens[']'] = .RBracket
	single_char_tokens[','] = .Comma
	single_char_tokens[';'] = .Semi
	single_char_tokens[':'] = .Colon
	single_char_tokens['~'] = .BitNot
}

// ============================================================================
// Core Lexing — ultra-fast main loop
// ============================================================================

lex_next_compact :: proc(l: ^Lexer2) -> CompactToken {
	// ---- Inline whitespace skip — only offset tracking, no line/col ----
	l.had_line_terminator = false
	for l.offset < len(l.source) {
		c := l.source_bytes[l.offset]
		if c == ' ' || c == '\t' || c == '\r' {
			l.offset += 1
		} else if c == '\n' {
			l.had_line_terminator = true
			l.offset += 1
		} else if c == '/' && l.offset + 1 < len(l.source) {
			n := l.source_bytes[l.offset + 1]
			if n == '/' { skip_line_comment2(l) }
			else if n == '*' { skip_block_comment2(l) }
			else { break }
		} else {
			break
		}
	}

	if l.offset >= len(l.source) {
		tok := add_token(&l.token_soa, .EOF, Loc{offset = l.offset}, 0, l.had_line_terminator)
		l.last_token_type = .EOF
		return tok
	}

	c := l.source_bytes[l.offset]

	// Template resume (rare)
	if l.in_template && c == '}' {
		l.offset += 1; 
		l.in_template = false
		tok := lex_template_resume(l, Loc{offset = l.offset})
		l.last_token_type = get_token_type(tok)
		return tok
	}

	loc := Loc{offset = l.offset}

	// ---- Fast path: single-char token via lookup table ----
	if c < 128 {
		tt := single_char_tokens[c]
		if tt != .Invalid {
			l.offset += 1; 
			tok := add_token(&l.token_soa, tt, loc, 1, l.had_line_terminator)
			l.last_token_type = tt
			return tok
		}
	}

	// ---- Identifier or keyword ----
	if is_id_start_fast(c) {
		tok := lex_identifier_optimized(l, loc)
		l.last_token_type = l.token_soa.types[l.token_soa.count - 1]
		return tok
	}

	// ---- Number ----
	if c >= '0' && c <= '9' {
		tok := lex_number_optimized(l, loc)
		l.last_token_type = l.token_soa.types[l.token_soa.count - 1]
		return tok
	}

	// ---- Multi-char operators and strings ----
	tok: CompactToken
	switch c {
	case '"', '\'':
		tok = lex_string_optimized(l, loc, c)
	case '/':
		tok = lex_slash_optimized(l, loc)
	case '+':
		tok = lex_plus_optimized(l, loc)
	case '-':
		tok = lex_minus_optimized(l, loc)
	case '*':
		tok = lex_star_optimized(l, loc)
	case '=':
		tok = lex_equals_optimized(l, loc)
	case '!':
		tok = lex_bang_optimized(l, loc)
	case '<':
		tok = lex_less_optimized(l, loc)
	case '>':
		tok = lex_greater_optimized(l, loc)
	case '&':
		tok = lex_and_optimized(l, loc)
	case '|':
		tok = lex_or_optimized(l, loc)
	case '.':
		tok = lex_dot_optimized(l, loc)
	case '?':
		tok = lex_question_optimized(l, loc)
	case '^':
		tok = lex_xor_optimized(l, loc)
	case '%':
		tok = lex_percent_optimized(l, loc)
	case '#':
		tok = lex_private_identifier(l, loc)
	case '`':
		tok = lex_template_start(l, loc)
	case:
		l.offset += 1; 
		tok = add_token(&l.token_soa, .Invalid, loc, 1, l.had_line_terminator)
	}

	l.last_token_type = l.token_soa.types[l.token_soa.count - 1]
	return tok
}

// ============================================================================
// SIMD-Accelerated Whitespace Skip
// ============================================================================

skip_whitespace_simd_lex :: proc(l: ^Lexer2) {
	// Reset line terminator flag at start of whitespace skip
	l.had_line_terminator = false
	
	remaining := len(l.source) - l.offset
	
	if remaining < 16 {
		// Scalar fallback for small inputs (< 16 bytes)
		if remaining > 0 {
			l.stats.scalar_fallbacks += 1
		}
		skip_whitespace_scalar(l)
		return
	}
	
	start_offset := l.offset
	
	// Use SIMD to skip whitespace
	for remaining >= 16 {
		data := l.source_bytes[l.offset:]
		
		// Count leading whitespace using SIMD
		ws_count := simd_count_whitespace(data)
		
		if ws_count == 0 {
			if len(data) >= 2 && data[0] == '/' {
				next := data[1]
				if next == '/' {
					skip_line_comment2(l)
					remaining = len(l.source) - l.offset
					continue
				} else if next == '*' {
					skip_block_comment2(l)
					remaining = len(l.source) - l.offset
					continue
				}
			}
			break
		}
		
		// SIMD was used - count it for large chunks
		if ws_count >= 16 {
			l.stats.simd_chunks_processed += 1
		}
		
		// Count newlines in this chunk
		chunk := data[:ws_count]
		nl_info := simd_count_newlines(chunk)
		
		if nl_info.count > 0 {
			l.had_line_terminator = true
		}
		
		l.offset += ws_count
		remaining = len(l.source) - l.offset
		if remaining >= 2 && l.source_bytes[l.offset] == '/' {
			next := l.source_bytes[l.offset + 1]
			if next == '/' {
				skip_line_comment2(l)
				remaining = len(l.source) - l.offset
			} else if next == '*' {
				skip_block_comment2(l)
				remaining = len(l.source) - l.offset
			}
		}
	}
	
	// Handle comments and remaining whitespace scalar
	skip_whitespace_scalar(l)
}

skip_whitespace_scalar :: proc(l: ^Lexer2) {
	// Fast path for 0-char whitespace (most common)
	if l.offset >= len(l.source) { return }
	c := l.source_bytes[l.offset]
	// Non-whitespace fast exit: most tokens are not preceded by whitespace at scalar stage
	if c > ' ' && c != '/' { return }

	for l.offset < len(l.source) {
		c = l.source_bytes[l.offset]
		if c == ' ' || c == '\t' || c == '\r' {
			l.offset += 1
			
		} else if c == '\n' {
			l.had_line_terminator = true
			l.offset += 1
			
			
		} else if c == '/' && l.offset + 1 < len(l.source) {
			next := l.source_bytes[l.offset + 1]
			if next == '/' {
				skip_line_comment2(l)
			} else if next == '*' {
				skip_block_comment2(l)
			} else {
				return
			}
		} else {
			return
		}
	}
}

// ============================================================================
// Optimized Token Lexers
// ============================================================================

// Identifier/keyword — ultra-tight scalar loop
lex_identifier_optimized :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	start := l.offset
	l.offset += 1  // skip first char (already verified)
	
	// Tight loop: check char class table directly (no function call)
	src := l.source_bytes
	src_len := len(l.source)
	for l.offset < src_len {
		class := CHAR_CLASS_TABLE[src[l.offset]]
		if class != u8(CharClass.IdStart) && class != u8(CharClass.Digit) { break }
		l.offset += 1
	}
	
	length := l.offset - start
	
	
	// Keyword check (hash table auto-initialized via @init or first call)
	tok_type, _ := lookup_keyword_ultra(l.source[start:l.offset])
	return add_token(&l.token_soa, tok_type, loc, length, l.had_line_terminator)
}

// Number literal
lex_number_optimized :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	start := l.offset
	start_offset := l.offset
	
	// Handle hex, binary, octal
	if l.source_bytes[l.offset] == '0' && l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		switch next {
		case 'x', 'X':
			return lex_hex_number(l, loc)
		case 'b', 'B':
			return lex_binary_number(l, loc)
		case 'o', 'O':
			return lex_octal_number(l, loc)
		}
	}
	
	// Decimal number — tight loop, no function calls
	src := l.source_bytes
	for l.offset < len(src) {
		ch := src[l.offset]
		if (ch >= '0' && ch <= '9') || ch == '_' { l.offset += 1 }
		else { break }
	}
	
	// Decimal part
	if l.offset < len(src) && src[l.offset] == '.' {
		l.offset += 1
		for l.offset < len(src) && src[l.offset] >= '0' && src[l.offset] <= '9' {
			l.offset += 1
		}
	}
	
	// Exponent
	if l.offset < len(src) && (src[l.offset] == 'e' || src[l.offset] == 'E') {
		l.offset += 1
		if l.offset < len(src) && (src[l.offset] == '+' || src[l.offset] == '-') {
			l.offset += 1
		}
		for l.offset < len(src) && src[l.offset] >= '0' && src[l.offset] <= '9' {
			l.offset += 1
		}
	}
	
	length := l.offset - start_offset
	  // update column for all digits scanned
	text := l.source[start_offset:l.offset]
	
	// Check for BigInt suffix: 123n
	if l.offset < len(l.source) && l.source_bytes[l.offset] == 'n' {
		l.offset += 1; 
		length = l.offset - start_offset
		return add_token(&l.token_soa, .BigInt, loc, length, l.had_line_terminator)
	}
	
	// Parse the number
	value, _ := strconv.parse_f64(text)
	
	return add_token_literal(
		&l.token_soa, 
		.Number, 
		loc, 
		length,
		.Number,
		LiteralValue(value),
	)
}

// String literal with SIMD quote finding
lex_string_optimized :: proc(l: ^Lexer2, loc: Loc, quote: u8) -> CompactToken {
	start := l.offset
	// Skip opening quote
	l.offset += 1
	

	// SIMD fast path: find first quote or backslash simultaneously
	remaining := l.source_bytes[l.offset:]
	pos, found_quote := simd_find_string_end(remaining, quote)

	if found_quote {
		// No escape in [offset..offset+pos) — direct fast path
		text := l.source[l.offset:l.offset+pos]
		l.offset += pos + 1
		return add_token_literal(
			&l.token_soa, .String, loc, pos + 2,
			.String, LiteralValue(text),
		)
	}

	// Hit backslash or end of data — fall back to scalar
	// Reset offset to after opening quote for scalar
	return lex_string_scalar(l, loc, quote, start)
}

// Check if current position can start a regex literal based on previous token
can_start_regex :: proc(l: ^Lexer2) -> bool {
	// Regex can start after these token types
	#partial switch l.last_token_type {
	case .EOF, .Semi, .Colon, .Comma, .LParen, .LBrace, .LBracket,
	     .Assign, .AssignAdd, .AssignSub, .AssignMul, .AssignDiv, .AssignMod,
	     .AssignPow, .AssignLShift, .AssignRShift, .AssignURShift, .AssignBitAnd,
	     .AssignBitOr, .AssignBitXor, .AssignNullish, .AssignLogicalAnd, .AssignLogicalOr,
	     .Return, .Case, .Throw, .New, .Delete, .Void, .Typeof,
	     .Plus, .Minus, .Mul, .Div, .Mod, .Pow, .BitNot, .BitAnd, .BitOr, .BitXor,
	     .LShift, .RShift, .URShift, .Not, .LogicalAnd, .LogicalOr, .Nullish,
	     .Eq, .NotEq, .EqStrict, .NotEqStrict, .LAngle, .RAngle, .LEq, .GEq,
	     .In, .Instanceof, .Of,
	     .Arrow, .Question, .Dot3,
	     .PlusPlus, .MinusMinus:
		return true
	case:
		// After identifiers, literals, closing brackets, etc. - it's division
		return false
	}
}

// Parse regex literal: /pattern/flags
lex_regex_literal :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	start := l.offset
	
	// Skip opening /
	advance2(l, 1)
	
	// Parse pattern (everything until unescaped /)
	pattern_start := l.offset
	for l.offset < len(l.source) {
		c := l.source_bytes[l.offset]
		if c == '\\' && l.offset + 1 < len(l.source) {
			// Skip escaped character
			advance2(l, 2)
		} else if c == '/' {
			// End of pattern
			break
		} else if c == '\n' || c == '\r' {
			// Unterminated regex - let it be invalid
			break
		} else {
			advance2(l, 1)
		}
	}
	
	pattern_end := l.offset
	
	// Check if we found closing /
	if l.offset >= len(l.source) || l.source_bytes[l.offset] != '/' {
		// Invalid regex, treat as division
		return add_token(&l.token_soa, .Div, loc, 1, l.had_line_terminator)
	}
	
	// Skip closing /
	advance2(l, 1)
	
	// Parse flags [a-z]*
	flags_start := l.offset
	for l.offset < len(l.source) {
		c := l.source_bytes[l.offset]
		if c >= 'a' && c <= 'z' {
			advance2(l, 1)
		} else {
			break
		}
	}
	flags_end := l.offset
	
	length := l.offset - start
	
	// Create regex literal value
	pattern := pattern_start < pattern_end ? l.source[pattern_start:pattern_end] : ""
	flags := flags_start < flags_end ? l.source[flags_start:flags_end] : ""
	
	// Store as combined "pattern" + "/" + "flags" or just pattern
	full_regex := length > 0 ? l.source[start:l.offset] : ""
	
	return add_token_literal(
		&l.token_soa,
		.RegularExpression,
		loc,
		length,
		.Regex,
		LiteralValue(full_regex),
	)
}

// Slash handling (division, comment, or regex)
lex_slash_optimized :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		
		switch next {
		case '=':
			advance2(l, 2)
			return add_token(&l.token_soa, .AssignDiv, loc, 2, l.had_line_terminator)
		case '/':
			skip_line_comment2(l)
			return lex_next_compact(l)  // Return next token after comment
		case '*':
			skip_block_comment2(l)
			return lex_next_compact(l)  // Return next token after comment
		}
	}
	
	// Context-aware: check if this should be regex or division
	if can_start_regex(l) {
		return lex_regex_literal(l, loc)
	}
	
	// Division operator
	advance2(l, 1)
	return add_token(&l.token_soa, .Div, loc, 1, l.had_line_terminator)
}

// Plus operator (+, ++, +=)
lex_plus_optimized :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		switch next {
		case '+':
			advance2(l, 2)
			return add_token(&l.token_soa, .PlusPlus, loc, 2, l.had_line_terminator)
		case '=':
			advance2(l, 2)
			return add_token(&l.token_soa, .AssignAdd, loc, 2, l.had_line_terminator)
		}
	}
	advance2(l, 1)
	return add_token(&l.token_soa, .Plus, loc, 1, l.had_line_terminator)
}

// Minus operator (-, --, -=)
lex_minus_optimized :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		switch next {
		case '-':
			advance2(l, 2)
			return add_token(&l.token_soa, .MinusMinus, loc, 2, l.had_line_terminator)
		case '=':
			advance2(l, 2)
			return add_token(&l.token_soa, .AssignSub, loc, 2, l.had_line_terminator)
		}
	}
	advance2(l, 1)
	return add_token(&l.token_soa, .Minus, loc, 1, l.had_line_terminator)
}

// Star operator (*, **, *=, **=)
lex_star_optimized :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		switch next {
		case '*':
			if l.offset + 2 < len(l.source) && l.source_bytes[l.offset + 2] == '=' {
				advance2(l, 3)
				return add_token(&l.token_soa, .AssignPow, loc, 3, l.had_line_terminator)
			}
			advance2(l, 2)
			return add_token(&l.token_soa, .Pow, loc, 2, l.had_line_terminator)
		case '=':
			advance2(l, 2)
			return add_token(&l.token_soa, .AssignMul, loc, 2, l.had_line_terminator)
		}
	}
	advance2(l, 1)
	return add_token(&l.token_soa, .Mul, loc, 1, l.had_line_terminator)
}

// Equals (=, ==, ===, =>)
lex_equals_optimized :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		
		switch next {
		case '=':
			if l.offset + 2 < len(l.source) && l.source_bytes[l.offset + 2] == '=' {
				advance2(l, 3)
				return add_token(&l.token_soa, .EqStrict, loc, 3, l.had_line_terminator)
			}
			advance2(l, 2)
			return add_token(&l.token_soa, .Eq, loc, 2, l.had_line_terminator)
		case '>':
			advance2(l, 2)
			return add_token(&l.token_soa, .Arrow, loc, 2, l.had_line_terminator)
		}
	}
	advance2(l, 1)
	return add_token(&l.token_soa, .Assign, loc, 1, l.had_line_terminator)
}

// Bang (!, !=, !==)
lex_bang_optimized :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		
		if next == '=' {
			if l.offset + 2 < len(l.source) && l.source_bytes[l.offset + 2] == '=' {
				advance2(l, 3)
				return add_token(&l.token_soa, .NotEqStrict, loc, 3, l.had_line_terminator)
			}
			advance2(l, 2)
			return add_token(&l.token_soa, .NotEq, loc, 2, l.had_line_terminator)
		}
	}
	advance2(l, 1)
	return add_token(&l.token_soa, .Not, loc, 1, l.had_line_terminator)
}

// Less than (<, <=, <<, <<=)
lex_less_optimized :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		
		switch next {
		case '=':
			advance2(l, 2)
			return add_token(&l.token_soa, .LEq, loc, 2, l.had_line_terminator)
		case '<':
			if l.offset + 2 < len(l.source) && l.source_bytes[l.offset + 2] == '=' {
				advance2(l, 3)
				return add_token(&l.token_soa, .AssignLShift, loc, 3, l.had_line_terminator)
			}
			advance2(l, 2)
			return add_token(&l.token_soa, .LShift, loc, 2, l.had_line_terminator)
		}
	}
	advance2(l, 1)
	return add_token(&l.token_soa, .LAngle, loc, 1, l.had_line_terminator)
}

// Greater than (>, >=, >>, >>>, >>=, >>>=)
lex_greater_optimized :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		
		switch next {
		case '=':
			advance2(l, 2)
			return add_token(&l.token_soa, .GEq, loc, 2, l.had_line_terminator)
		case '>':
			if l.offset + 2 < len(l.source) {
				next2 := l.source_bytes[l.offset + 2]
				if next2 == '=' {
					advance2(l, 3)
					return add_token(&l.token_soa, .AssignRShift, loc, 3, l.had_line_terminator)
				}
				if next2 == '>' {
					if l.offset + 3 < len(l.source) && l.source_bytes[l.offset + 3] == '=' {
						advance2(l, 4)
						return add_token(&l.token_soa, .AssignURShift, loc, 4, l.had_line_terminator)
					}
					advance2(l, 3)
					return add_token(&l.token_soa, .URShift, loc, 3, l.had_line_terminator)
				}
			}
			advance2(l, 2)
			return add_token(&l.token_soa, .RShift, loc, 2, l.had_line_terminator)
		}
	}
	advance2(l, 1)
	return add_token(&l.token_soa, .RAngle, loc, 1, l.had_line_terminator)
}

// Logical AND (&, &&, &=)
lex_and_optimized :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		
		switch next {
		case '&':
			// Check for &&= (logical AND assignment)
			if l.offset + 2 < len(l.source) && l.source_bytes[l.offset + 2] == '=' {
				advance2(l, 3)
				return add_token(&l.token_soa, .AssignLogicalAnd, loc, 3, l.had_line_terminator)
			}
			advance2(l, 2)
			return add_token(&l.token_soa, .LogicalAnd, loc, 2, l.had_line_terminator)
		case '=':
			advance2(l, 2)
			return add_token(&l.token_soa, .AssignBitAnd, loc, 2, l.had_line_terminator)
		}
	}
	advance2(l, 1)
	return add_token(&l.token_soa, .BitAnd, loc, 1, l.had_line_terminator)
}

// Logical OR (|, ||, |=)
lex_or_optimized :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		
		switch next {
		case '|':
			// Check for ||= (logical OR assignment)
			if l.offset + 2 < len(l.source) && l.source_bytes[l.offset + 2] == '=' {
				advance2(l, 3)
				return add_token(&l.token_soa, .AssignLogicalOr, loc, 3, l.had_line_terminator)
			}
			advance2(l, 2)
			return add_token(&l.token_soa, .LogicalOr, loc, 2, l.had_line_terminator)
		case '=':
			advance2(l, 2)
			return add_token(&l.token_soa, .AssignBitOr, loc, 2, l.had_line_terminator)
		}
	}
	advance2(l, 1)
	return add_token(&l.token_soa, .BitOr, loc, 1, l.had_line_terminator)
}

// Dot (. or ...)
lex_dot_optimized :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	if l.offset + 2 < len(l.source) {
		if l.source_bytes[l.offset + 1] == '.' && l.source_bytes[l.offset + 2] == '.' {
			advance2(l, 3)
			return add_token(&l.token_soa, .Dot3, loc, 3, l.had_line_terminator)
		}
	}
	advance2(l, 1)
	return add_token(&l.token_soa, .Dot, loc, 1, l.had_line_terminator)
}

// Question mark (?, ?., ??, ??=)
lex_question_optimized :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		
		switch next {
		case '.':
			advance2(l, 2)
			return add_token(&l.token_soa, .OptionalChain, loc, 2, l.had_line_terminator)
		case '?':
			if l.offset + 2 < len(l.source) && l.source_bytes[l.offset + 2] == '=' {
				advance2(l, 3)
				return add_token(&l.token_soa, .AssignNullish, loc, 3, l.had_line_terminator)
			}
			advance2(l, 2)
			return add_token(&l.token_soa, .Nullish, loc, 2, l.had_line_terminator)
		}
	}
	advance2(l, 1)
	return add_token(&l.token_soa, .Question, loc, 1, l.had_line_terminator)
}

// XOR (^, ^=)
lex_xor_optimized :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	if l.offset + 1 < len(l.source) && l.source_bytes[l.offset + 1] == '=' {
		advance2(l, 2)
		return add_token(&l.token_soa, .AssignBitXor, loc, 2, l.had_line_terminator)
	}
	advance2(l, 1)
	return add_token(&l.token_soa, .BitXor, loc, 1, l.had_line_terminator)
}

// Percent (%, %=)
lex_percent_optimized :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	if l.offset + 1 < len(l.source) && l.source_bytes[l.offset + 1] == '=' {
		advance2(l, 2)
		return add_token(&l.token_soa, .AssignMod, loc, 2, l.had_line_terminator)
	}
	advance2(l, 1)
	return add_token(&l.token_soa, .Mod, loc, 1, l.had_line_terminator)
}

// ============================================================================
// Helper Functions
// ============================================================================

advance2 :: #force_inline proc(l: ^Lexer2, n: int) {
	l.offset += n
	
}

advance_line2 :: #force_inline proc(l: ^Lexer2) {
	l.offset += 1
	
	
}

skip_line_comment2 :: proc(l: ^Lexer2) {
	l.offset += 2  // Skip //
	for l.offset < len(l.source) && l.source_bytes[l.offset] != '\n' {
		l.offset += 1
	}
}

skip_block_comment2 :: proc(l: ^Lexer2) {
	l.offset += 2  // Skip /*
	for l.offset + 1 < len(l.source) {
		c := l.source_bytes[l.offset]
		if c == '*' && l.source_bytes[l.offset + 1] == '/' {
			l.offset += 2
			return
		}
		if c == '\n' {
			l.had_line_terminator = true
		}
		l.offset += 1
	}
}

// Scalar string fallback
lex_string_scalar :: proc(l: ^Lexer2, loc: Loc, quote: u8, start: int) -> CompactToken {
	// Skip opening quote
	advance2(l, 1)
	
	for l.offset < len(l.source) {
		c := l.source_bytes[l.offset]
		
		if c == quote {
			advance2(l, 1)
			text := l.source[start+1:l.offset-1]
			return add_token_literal(
				&l.token_soa,
				.String,
				loc,
				l.offset - start,
				.String,
				LiteralValue(text),
			)
		}
		
		if c == '\\' && l.offset + 1 < len(l.source) {
			next := l.source_bytes[l.offset + 1]
			// Handle \u{...} unicode extended escapes
			if (next == 'u' || next == 'U') && l.offset + 2 < len(l.source) && l.source_bytes[l.offset + 2] == '{' {
				// Skip \u{ and find closing }
				advance2(l, 3)  // Skip \u{
				for l.offset < len(l.source) && l.source_bytes[l.offset] != '}' {
					if l.source_bytes[l.offset] == '\n' {
						advance_line2(l)
					} else {
						advance2(l, 1)
					}
				}
				if l.offset < len(l.source) && l.source_bytes[l.offset] == '}' {
					advance2(l, 1)  // Skip }
				}
			} else {
				advance2(l, 2)  // Skip escaped char
			}
		} else if c == '\n' {
			advance_line2(l)
		} else {
			advance2(l, 1)
		}
	}
	
	// Unterminated string
	return add_token(&l.token_soa, .Invalid, loc, l.offset - start, l.had_line_terminator)
}

// Hex number
lex_hex_number :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	start := l.offset
	advance2(l, 2)  // Skip 0x
	
	for l.offset < len(l.source) {
		c := l.source_bytes[l.offset]
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') || c == '_' {
			advance2(l, 1)
		} else {
			break
		}
	}
	
	length := l.offset - start
	
	// Check for BigInt suffix
	if l.offset < len(l.source) && l.source_bytes[l.offset] == 'n' {
		advance2(l, 1)
		length = l.offset - start
		return add_token(&l.token_soa, .BigInt, loc, length, l.had_line_terminator)
	}
	
	return add_token(&l.token_soa, .Number, loc, length, l.had_line_terminator)
}

// Binary number
lex_binary_number :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	start := l.offset
	advance2(l, 2)  // Skip 0b
	
	for l.offset < len(l.source) {
		c := l.source_bytes[l.offset]
		if c == '0' || c == '1' || c == '_' {
			advance2(l, 1)
		} else {
			break
		}
	}
	
	length := l.offset - start
	
	// Check for BigInt suffix
	if l.offset < len(l.source) && l.source_bytes[l.offset] == 'n' {
		advance2(l, 1)
		length = l.offset - start
		return add_token(&l.token_soa, .BigInt, loc, length, l.had_line_terminator)
	}
	
	return add_token(&l.token_soa, .Number, loc, length, l.had_line_terminator)
}

// Octal number
lex_octal_number :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	start := l.offset
	advance2(l, 2)  // Skip 0o
	
	for l.offset < len(l.source) {
		c := l.source_bytes[l.offset]
		if (c >= '0' && c <= '7') || c == '_' {
			advance2(l, 1)
		} else {
			break
		}
	}
	
	length := l.offset - start
	
	// Check for BigInt suffix
	if l.offset < len(l.source) && l.source_bytes[l.offset] == 'n' {
		advance2(l, 1)
		length = l.offset - start
		return add_token(&l.token_soa, .BigInt, loc, length, l.had_line_terminator)
	}
	
	return add_token(&l.token_soa, .Number, loc, length, l.had_line_terminator)
}

// Private identifier (#name)
lex_private_identifier :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	start := l.offset
	advance2(l, 1)  // Skip #
	
	// Must start with identifier char
	if l.offset < len(l.source) && is_id_start_fast(l.source_bytes[l.offset]) {
		advance2(l, 1)
		
		// Continue with identifier chars
		for l.offset < len(l.source) && is_id_cont_fast(l.source_bytes[l.offset]) {
			advance2(l, 1)
		}
	}
	
	length := l.offset - start
	return add_token(&l.token_soa, .PrivateIdentifier, loc, length, l.had_line_terminator)
}

// Template literal start
lex_template_start :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	start := l.offset
	
	// Opening backtick
	advance2(l, 1)
	
	// Track if we're in a template with interpolations
	in_interpolation := false
	template_start_idx := len(l.template_stack)
	append(&l.template_stack, false)
	
	// Scan template content
	for l.offset < len(l.source) {
		c := l.source_bytes[l.offset]
		
		// Check for interpolation start: ${
		if c == '$' && l.offset + 1 < len(l.source) && l.source_bytes[l.offset + 1] == '{' {
			// Found interpolation - this is a TemplateHead (or TemplateMiddle if nested)
			in_interpolation = true
			l.template_stack[template_start_idx] = true
			
			// Get the cooked string (content before ${})
			cooked_len := l.offset - start - 1  // -1 to exclude the opening backtick
			cooked := l.source[start + 1:l.offset] if cooked_len > 0 else ""
			
			// Create literal value
			lit_val := LiteralValue(cooked)
			
			// Determine token type based on context
			tok_type: TokenType
			if len(l.template_stack) == 1 || !l.template_stack[len(l.template_stack) - 2] {
				// First part of template or simple template
				tok_type = .TemplateHead
			} else {
				tok_type = .TemplateMiddle
			}
			
			// Consume ${} - the parser will see the expression tokens inside
			// and expects to find } which signals end of interpolation
			advance2(l, 2) // consume ${
			l.in_template = true
			
			return add_token_literal(&l.token_soa, tok_type, loc, l.offset - start, .String, lit_val, l.had_line_terminator)
		}
		
		// Check for closing backtick
		if c == '`' {
			// End of template
			cooked_len := l.offset - start - 1
			cooked := l.source[start + 1:l.offset] if cooked_len > 0 else ""
			
			lit_val := LiteralValue(cooked)
			
			// Determine token type
			tok_type: TokenType
			if in_interpolation {
				tok_type = .TemplateTail
			} else {
				tok_type = .Template  // Simple template without interpolations
			}
			
			// Pop template stack
			if template_start_idx < len(l.template_stack) {
				// Remove the last entry
				ordered_remove(&l.template_stack, template_start_idx)
			}
			
			advance2(l, 1)
			return add_token_literal(&l.token_soa, tok_type, loc, l.offset - start, .String, lit_val, l.had_line_terminator)
		}
		
		// Handle escape sequences
		if c == '\\' && l.offset + 1 < len(l.source) {
			advance2(l, 2)
			continue
		}
		
		// Handle newlines
		if c == '\n' {
			advance_line2(l)
			continue
		}
		
		advance2(l, 1)
	}
	
	// Unterminated template
	return add_token(&l.token_soa, .Invalid, loc, l.offset - start, l.had_line_terminator)
}

// Resume template scanning after } - for template middle/tail
lex_template_resume :: proc(l: ^Lexer2, loc: Loc) -> CompactToken {
	start := l.offset
	
	// Scan template content after }
	for l.offset < len(l.source) {
		c := l.source_bytes[l.offset]
		
		// Check for interpolation start: ${
		if c == '$' && l.offset + 1 < len(l.source) && l.source_bytes[l.offset + 1] == '{' {
			cooked_len := l.offset - start
			cooked := l.source[start:l.offset] if cooked_len > 0 else ""
			
			lit_val := LiteralValue(cooked)
			
			// Consume ${ so the next token is the start of the expression
			// NOT the Dollar token
			advance2(l, 2)
			l.in_template = true
			
			return add_token_literal(&l.token_soa, .TemplateMiddle, loc, l.offset - start, .String, lit_val, l.had_line_terminator)
		}
		
		// Check for closing backtick
		if c == '`' {
			cooked_len := l.offset - start
			cooked := l.source[start:l.offset] if cooked_len > 0 else ""
			
			lit_val := LiteralValue(cooked)
			
			l.in_template = false
			advance2(l, 1)
			return add_token_literal(&l.token_soa, .TemplateTail, loc, l.offset - start, .String, lit_val, l.had_line_terminator)
		}
		
		// Handle escape sequences
		if c == '\\' && l.offset + 1 < len(l.source) {
			advance2(l, 2)
			continue
		}
		
		// Handle newlines
		if c == '\n' {
			advance_line2(l)
			continue
		}
		
		advance2(l, 1)
	}
	
	return add_token(&l.token_soa, .Invalid, loc, l.offset - start, l.had_line_terminator)
}
