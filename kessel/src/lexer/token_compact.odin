package lexer

// ============================================================================
// COMPACT TOKEN OPTIMIZATION
// Structure of Arrays (SoA) instead of Array of Structures (AoS)
// Reduces token size from ~76 bytes to 16 bytes (4.75x reduction)
//
// v2: Uses raw []T slices instead of [dynamic]T for zero-overhead stores.
// Pre-allocated at estimated capacity; add_token does direct stores
// (no append, no len check, no function call overhead).
// ============================================================================

import "core:mem"

// CompactTokenIndex is a handle to a token in the SoA storage
// Uses 32-bit index for cache efficiency
CompactTokenIndex :: u32

// INVALID_TOKEN_INDEX represents an invalid token
INVALID_TOKEN_INDEX :: CompactTokenIndex(max(u32))

// TokenSoA - Structure of Arrays for token storage
// Uses raw slices (no dynamic append overhead). Capacity pre-allocated.
TokenSoA :: struct {
	types:   []TokenType,
	offsets: []u32,
	lines:   []u32,
	cols:    []u16,
	lengths: []u16,
	had_line_terminator: []bool,
	literal_types:  []LiteralType,
	literal_values: []LiteralValue,
	allocator: mem.Allocator,
	count:    u32,
	capacity: u32,
}

// LiteralType distinguishes what kind of literal a token holds
LiteralType :: enum u8 {
	None,       // Not a literal
	Number,     // Numeric literal (f64)
	String,     // String literal
	Bool,       // true/false
	Regex,      // Regular expression
	BigInt,     // BigInt literal
}

// CompactToken represents a lightweight token handle
// Only 12 bytes - can be passed by value efficiently
CompactToken :: struct {
	index: CompactTokenIndex,  // Index into SoA
	soa:   ^TokenSoA,          // Reference to storage
}

// TokenView provides access to token data through the compact handle
TokenView :: struct {
	token_type:   TokenType,
	offset:  u32,
	line:    u32,
	column:  u16,
	length:  u16,
	had_line_terminator: bool,
	literal: LiteralValue,
	literal_type: LiteralType,
}

// Initialize SoA token storage with pre-allocated raw slices
init_token_soa :: proc(soa: ^TokenSoA, alloc: mem.Allocator, capacity: int = 1024) {
	cap := u32(capacity)
	
	soa.types   = make([]TokenType, cap, alloc)
	soa.offsets = make([]u32, cap, alloc)
	soa.lines   = make([]u32, cap, alloc)
	soa.cols    = make([]u16, cap, alloc)
	soa.lengths = make([]u16, cap, alloc)
	soa.had_line_terminator = make([]bool, cap, alloc)
	soa.literal_types  = make([]LiteralType, cap, alloc)
	soa.literal_values = make([]LiteralValue, cap, alloc)
	
	soa.allocator = alloc
	soa.count    = 0
	soa.capacity = cap
}

// Add a token — direct stores, zero append overhead
add_token :: #force_inline proc(soa: ^TokenSoA, token_type: TokenType, loc: Loc, length: int, had_line_term: bool = false) -> CompactToken {
	idx := soa.count
	soa.count += 1
	
	// Direct store into pre-allocated slices
	soa.types[idx]   = token_type
	soa.offsets[idx] = u32(loc.offset)
	soa.lines[idx]   = u32(loc.line)
	soa.cols[idx]    = u16(loc.column)
	soa.lengths[idx] = u16(length)
	soa.had_line_terminator[idx] = had_line_term
	
	// Literal arrays already pre-allocated — default values are .None / zero
	// No per-token append needed
	
	return CompactToken{index = idx, soa = soa}
}

// Add a token with literal value
add_token_literal :: proc(soa: ^TokenSoA, token_type: TokenType, loc: Loc, length: int, 
                          lit_type: LiteralType, value: LiteralValue, had_line_term: bool = false) -> CompactToken {
	tok := add_token(soa, token_type, loc, length, had_line_term)
	
	soa.literal_types[tok.index]  = lit_type
	soa.literal_values[tok.index] = value
	return tok
}

// Get token view from compact handle
get_token_view :: proc(tok: CompactToken) -> TokenView {
	if tok.index == INVALID_TOKEN_INDEX || tok.soa == nil {
		return TokenView{token_type = .Invalid}
	}
	
	soa := tok.soa
	idx := tok.index
	
	return TokenView{
		token_type = soa.types[idx],
		offset  = soa.offsets[idx],
		line    = soa.lines[idx],
		column  = soa.cols[idx],
		length  = soa.lengths[idx],
		had_line_terminator = soa.had_line_terminator[idx],
		literal = soa.literal_values[idx],
		literal_type = soa.literal_types[idx],
	}
}

// Get token type quickly
get_token_type :: #force_inline proc(tok: CompactToken) -> TokenType {
	if tok.index == INVALID_TOKEN_INDEX || tok.soa == nil {
		return .Invalid
	}
	soa := tok.soa
	if tok.index >= soa.count {
		return .Invalid
	}
	return soa.types[tok.index]
}

// Get token location
get_token_loc :: proc(tok: CompactToken) -> Loc {
	if tok.index == INVALID_TOKEN_INDEX || tok.soa == nil {
		return Loc{}
	}
	soa := tok.soa
	idx := tok.index
	return Loc{
		offset = int(soa.offsets[idx]),
		line   = int(soa.lines[idx]),
		column = int(soa.cols[idx]),
	}
}

// Get token source text (creates string slice from source)
get_token_source :: proc(tok: CompactToken, source: string) -> string {
	if tok.index == INVALID_TOKEN_INDEX || tok.soa == nil {
		return ""
	}
	soa := tok.soa
	idx := tok.index
	offset := int(soa.offsets[idx])
	length := int(soa.lengths[idx])
	
	if offset + length <= len(source) {
		return source[offset:offset+length]
	}
	return ""
}

// Get literal value
get_token_literal :: proc(tok: CompactToken) -> (LiteralValue, LiteralType) {
	if tok.index == INVALID_TOKEN_INDEX || tok.soa == nil {
		return LiteralValue{}, .None
	}
	soa := tok.soa
	idx := tok.index
	return soa.literal_values[idx], soa.literal_types[idx]
}

// Set literal value
set_token_literal :: proc(tok: CompactToken, lit_type: LiteralType, value: LiteralValue) {
	if tok.index == INVALID_TOKEN_INDEX || tok.soa == nil {
		return
	}
	soa := tok.soa
	idx := tok.index
	soa.literal_types[idx] = lit_type
	soa.literal_values[idx] = value
}

// Compact token comparison
token_eq :: proc(a, b: CompactToken) -> bool {
	return a.index == b.index && a.soa == b.soa
}

// Check if token is EOF
is_eof_compact :: proc(tok: CompactToken) -> bool {
	return get_token_type(tok) == .EOF
}

// Check if token is valid
is_valid_compact :: proc(tok: CompactToken) -> bool {
	return tok.index != INVALID_TOKEN_INDEX && tok.soa != nil
}

// ============================================================================
// Token Pair — minimal 2-slot lookahead (replaces 8-slot ring buffer)
// ============================================================================

TOKEN_RING_SIZE :: 8  // kept for compat; actual storage is 2 slots

TokenRing :: struct {
	cur:       CompactToken,   // current token
	nxt:       CompactToken,   // lookahead(1)
	cur_type:  TokenType,
	nxt_type:  TokenType,
	has_next:  bool,
	soa:       ^TokenSoA,
}

// Initialize token pair
init_token_ring :: proc(ring: ^TokenRing, soa: ^TokenSoA) {
	ring.soa = soa
	ring.cur = CompactToken{index = INVALID_TOKEN_INDEX, soa = soa}
	ring.nxt = CompactToken{index = INVALID_TOKEN_INDEX, soa = soa}
	ring.cur_type = .EOF
	ring.nxt_type = .EOF
	ring.has_next = false
}

// Push: fill next slot
ring_push :: #force_inline proc(ring: ^TokenRing, tok: CompactToken) {
	if ring.cur.index == INVALID_TOKEN_INDEX {
		ring.cur = tok
		ring.cur_type = get_token_type(tok)
	} else {
		ring.nxt = tok
		ring.nxt_type = get_token_type(tok)
		ring.has_next = true
	}
}

// Pop current; shift next → current
ring_pop :: #force_inline proc(ring: ^TokenRing) -> CompactToken {
	old := ring.cur
	if ring.has_next {
		ring.cur = ring.nxt
		ring.cur_type = ring.nxt_type
		ring.has_next = false
		ring.nxt = CompactToken{index = INVALID_TOKEN_INDEX, soa = ring.soa}
		ring.nxt_type = .EOF
	} else {
		ring.cur = CompactToken{index = INVALID_TOKEN_INDEX, soa = ring.soa}
		ring.cur_type = .EOF
	}
	return old
}

// Peek at offset 0 (current) or 1 (next)
ring_peek :: #force_inline proc(ring: ^TokenRing, offset: u8) -> CompactToken {
	if offset == 0 { return ring.cur }
	if offset == 1 && ring.has_next { return ring.nxt }
	return CompactToken{index = INVALID_TOKEN_INDEX, soa = ring.soa}
}

// Type at offset 0 or 1
ring_peek_type :: #force_inline proc(ring: ^TokenRing, offset: u8) -> TokenType {
	if offset == 0 { return ring.cur_type }
	if offset == 1 { return ring.nxt_type }  // .EOF if no next
	return .EOF
}

ring_is_type :: #force_inline proc(ring: ^TokenRing, offset: u8, token_type: TokenType) -> bool {
	return ring_peek_type(ring, offset) == token_type
}

// ============================================================================
// Backwards Compatibility Helpers
// ============================================================================

// Convert compact token to legacy Token (for gradual migration)
compact_to_legacy :: proc(tok: CompactToken, source: string) -> Token {
	view := get_token_view(tok)
	return Token{
		type    = view.token_type,
		loc     = Loc{offset = int(view.offset), line = int(view.line), column = int(view.column)},
		value   = get_token_source(tok, source),
		literal = view.literal,
		had_line_terminator = view.had_line_terminator,
	}
}
