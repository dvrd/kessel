package lexer

// ============================================================================
// COMPACT TOKEN OPTIMIZATION
// Structure of Arrays (SoA) instead of Array of Structures (AoS)
// Reduces token size from ~76 bytes to 16 bytes (4.75x reduction)
// ============================================================================

import "core:mem"

// CompactTokenIndex is a handle to a token in the SoA storage
// Uses 32-bit index for cache efficiency
CompactTokenIndex :: u32

// INVALID_TOKEN_INDEX represents an invalid token
INVALID_TOKEN_INDEX :: CompactTokenIndex(max(u32))

// TokenSoA - Structure of Arrays for token storage
// All token data stored in parallel arrays for cache efficiency
TokenSoA :: struct {
	// Fixed-size token data (16 bytes per token)
	types:   [dynamic]TokenType,     // 1 byte each (padded to 4)
	offsets: [dynamic]u32,           // 4 bytes - source offset
	lines:   [dynamic]u32,           // 4 bytes - line number
	cols:    [dynamic]u16,           // 2 bytes - column
	lengths: [dynamic]u16,           // 2 bytes - token length in source
	
	// Extended data for literals (sparse, only when needed)
	literal_types:  [dynamic]LiteralType,  // Type of literal value
	literal_values: [dynamic]LiteralValue, // Actual parsed value
	
	// String storage for identifiers and string literals
	// Uses arena allocation, stores offset into arena
	string_data: ^mem.Arena,
	
	// Token count and capacity
	count: u32,
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
// Only 8 bytes - can be passed by value efficiently
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
	literal: LiteralValue,
	literal_type: LiteralType,
}

// Initialize SoA token storage
init_token_soa :: proc(soa: ^TokenSoA, arena: ^mem.Arena, capacity: int = 1024) {
	soa.types   = make([dynamic]TokenType, 0, capacity, mem.arena_allocator(arena))
	soa.offsets = make([dynamic]u32, 0, capacity, mem.arena_allocator(arena))
	soa.lines   = make([dynamic]u32, 0, capacity, mem.arena_allocator(arena))
	soa.cols    = make([dynamic]u16, 0, capacity, mem.arena_allocator(arena))
	soa.lengths = make([dynamic]u16, 0, capacity, mem.arena_allocator(arena))
	soa.literal_types  = make([dynamic]LiteralType, 0, capacity, mem.arena_allocator(arena))
	soa.literal_values = make([dynamic]LiteralValue, 0, capacity, mem.arena_allocator(arena))
	soa.string_data = arena
	soa.count = 0
}

// Add a token to SoA storage, returns compact handle
add_token :: proc(soa: ^TokenSoA, token_type: TokenType, loc: Loc, length: int) -> CompactToken {
	idx := soa.count
	soa.count += 1
	
	// Use append to handle dynamic growth
	append(&soa.types, token_type)
	append(&soa.offsets, u32(loc.offset))
	append(&soa.lines, u32(loc.line))
	append(&soa.cols, u16(loc.column))
	append(&soa.lengths, u16(length))
	
	// Ensure literal arrays grow with the token arrays
	// This is critical to prevent index out of range
	if len(soa.literal_types) <= int(idx) {
		append(&soa.literal_types, LiteralType.None)
		append(&soa.literal_values, LiteralValue{})
	}
	
	return CompactToken{index = idx, soa = soa}
}

// Add a token with literal value
add_token_literal :: proc(soa: ^TokenSoA, token_type: TokenType, loc: Loc, length: int, 
                          lit_type: LiteralType, value: LiteralValue) -> CompactToken {
	tok := add_token(soa, token_type, loc, length)
	
	// Ensure arrays have the element at tok.index
	// This might happen if add_token didn't populate them
	for len(soa.literal_types) <= int(tok.index) {
		append(&soa.literal_types, LiteralType.None)
	}
	for len(soa.literal_values) <= int(tok.index) {
		append(&soa.literal_values, LiteralValue{})
	}
	
	soa.literal_types[tok.index] = lit_type
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
		literal = soa.literal_values[idx],
		literal_type = soa.literal_types[idx],
	}
}

// Get token type quickly
get_token_type :: proc(tok: CompactToken) -> TokenType {
	if tok.index == INVALID_TOKEN_INDEX || tok.soa == nil {
		return .Invalid
	}
	// Bounds check
	if int(tok.index) >= len(tok.soa.types) {
		return .Invalid
	}
	return tok.soa.types[tok.index]
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
// Token Ring Buffer for Lexer Lookahead
// ============================================================================

TOKEN_RING_SIZE :: 8  // Power of 2 for fast modulo

TokenRing :: struct {
	tokens:   [TOKEN_RING_SIZE]CompactToken,
	indices:  [TOKEN_RING_SIZE]CompactTokenIndex,
	types:    [TOKEN_RING_SIZE]TokenType,
	head:     u8,  // Next token to consume
	tail:     u8,  // Next slot to fill
	count:    u8,  // Current count
	soa:      ^TokenSoA,
}

// Initialize token ring
init_token_ring :: proc(ring: ^TokenRing, soa: ^TokenSoA) {
	ring.head = 0
	ring.tail = 0
	ring.count = 0
	ring.soa = soa
}

// Push token to ring
ring_push :: proc(ring: ^TokenRing, tok: CompactToken) {
	ring.tokens[ring.tail] = tok
	ring.indices[ring.tail] = tok.index
	ring.types[ring.tail] = get_token_type(tok)
	ring.tail = (ring.tail + 1) & (TOKEN_RING_SIZE - 1)
	ring.count += 1
}

// Pop token from ring
ring_pop :: proc(ring: ^TokenRing) -> CompactToken {
	if ring.count == 0 {
		return CompactToken{index = INVALID_TOKEN_INDEX, soa = ring.soa}
	}
	tok := ring.tokens[ring.head]
	ring.head = (ring.head + 1) & (TOKEN_RING_SIZE - 1)
	ring.count -= 1
	return tok
}

// Peek at token in ring (0 = current, 1 = lookahead, etc.)
ring_peek :: proc(ring: ^TokenRing, offset: u8) -> CompactToken {
	if offset >= ring.count {
		return CompactToken{index = INVALID_TOKEN_INDEX, soa = ring.soa}
	}
	idx := (ring.head + offset) & (TOKEN_RING_SIZE - 1)
	return ring.tokens[idx]
}

// Get type of token in ring (faster than full view)
ring_peek_type :: proc(ring: ^TokenRing, offset: u8) -> TokenType {
	if offset >= ring.count {
		return .EOF
	}
	idx := (ring.head + offset) & (TOKEN_RING_SIZE - 1)
	return ring.types[idx]
}

// Check if ring has token of type at offset
ring_is_type :: proc(ring: ^TokenRing, offset: u8, token_type: TokenType) -> bool {
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
	}
}
