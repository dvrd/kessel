package lexer

// ============================================================================
// FAST TOKEN — 16 bytes by-value, like OXC's Token(u128)
// No SoA, no ring buffer, no indices. Copied by value between lexer and parser.
// ============================================================================

import "core:mem"

// FastToken — the primary token type. 16 bytes, fits in a register pair.
// Passed by value between lexer and parser (no indirection).
FastToken :: struct {
	start:  u32,        // byte offset of token start in source
	end:    u32,        // byte offset past last char
	kind:   TokenType,  // 1 byte
	flags:  u8,         // bit 0 = is_on_new_line (had line terminator before this token)
	_pad:   [6]u8,      // padding to 16 bytes (room for future flags)
}

FAST_FLAG_NEW_LINE :: u8(1)

fast_token_default :: #force_inline proc() -> FastToken {
	return FastToken{}  // kind = .Null which is 0, but we want EOF
}

fast_token_eof :: #force_inline proc(offset: u32) -> FastToken {
	return FastToken{start = offset, end = offset, kind = .EOF}
}

// ============================================================================
// Literal storage — separate from token, indexed by token start offset
// Only ~20% of tokens have literals (strings, numbers, regex)
// ============================================================================

LiteralType :: enum u8 {
	None,
	Number,
	String,
	Bool,
	Regex,
	BigInt,
}

// LiteralValue defined in token.odin

// LiteralStore — hash map from token start offset to literal value
// Only populated for literal tokens. Parser queries by offset.
LiteralStore :: struct {
	// Simple open-addressing hash map: offset → (type, value)
	// For ~20K literal tokens in bench_large, this is very fast.
	keys:   []u32,
	types:  []LiteralType,
	values: []LiteralValue,
	mask:   u32,  // capacity - 1 (power of 2)
}

init_literal_store :: proc(store: ^LiteralStore, capacity: int, alloc: mem.Allocator) {
	// Round up to power of 2
	cap := u32(1)
	for int(cap) < capacity { cap *= 2 }
	store.keys   = make([]u32, cap, alloc)
	store.types  = make([]LiteralType, cap, alloc)
	store.values = make([]LiteralValue, cap, alloc)
	store.mask   = cap - 1
	// Keys are 0 by default; we use 0xFFFFFFFF as "empty" sentinel
	for i in 0..<int(cap) { store.keys[i] = 0xFFFFFFFF }
}

store_literal :: #force_inline proc(store: ^LiteralStore, offset: u32, lit_type: LiteralType, value: LiteralValue) {
	idx := offset & store.mask
	for {
		if store.keys[idx] == 0xFFFFFFFF {
			store.keys[idx] = offset
			store.types[idx] = lit_type
			store.values[idx] = value
			return
		}
		idx = (idx + 1) & store.mask
	}
}

lookup_literal :: #force_inline proc(store: ^LiteralStore, offset: u32) -> (LiteralValue, LiteralType) {
	idx := offset & store.mask
	for {
		if store.keys[idx] == offset {
			return store.values[idx], store.types[idx]
		}
		if store.keys[idx] == 0xFFFFFFFF {
			return LiteralValue{}, .None
		}
		idx = (idx + 1) & store.mask
	}
}

// ============================================================================
// Legacy compat — types kept for code that still references them
// ============================================================================

// These are kept so lexer_adapter.odin and other code compiles.
// The fast path bypasses them entirely.

CompactTokenIndex :: u32
INVALID_TOKEN_INDEX :: CompactTokenIndex(max(u32))

CompactToken :: struct {
	index: CompactTokenIndex,
	soa:   ^TokenSoA,
}

TokenSlot :: struct {
	offset: u32,
	length: u16,
	type:   TokenType,
	flags:  u8,
}

TOKEN_FLAG_LINE_TERM :: u8(1)

TokenSoA :: struct {
	slots:          []TokenSlot,
	literal_types:  []LiteralType,
	literal_values: []LiteralValue,
	allocator: mem.Allocator,
	count:    u32,
	capacity: u32,
}

init_token_soa :: proc(soa: ^TokenSoA, alloc: mem.Allocator, capacity: int = 1024) {
	cap := u32(capacity)
	soa.slots   = make([]TokenSlot, cap, alloc)
	soa.literal_types  = make([]LiteralType, cap, alloc)
	soa.literal_values = make([]LiteralValue, cap, alloc)
	soa.allocator = alloc
	soa.count    = 0
	soa.capacity = cap
}

add_token :: #force_inline proc(soa: ^TokenSoA, token_type: TokenType, loc: Loc, length: int, had_line_term: bool = false) -> CompactToken {
	idx := soa.count
	soa.count += 1
	soa.slots[idx] = TokenSlot{
		offset = u32(loc.offset),
		length = u16(length),
		type   = token_type,
		flags  = TOKEN_FLAG_LINE_TERM if had_line_term else 0,
	}
	return CompactToken{index = idx, soa = soa}
}

add_token_literal :: proc(soa: ^TokenSoA, token_type: TokenType, loc: Loc, length: int,
                          lit_type: LiteralType, value: LiteralValue, had_line_term: bool = false) -> CompactToken {
	tok := add_token(soa, token_type, loc, length, had_line_term)
	soa.literal_types[tok.index]  = lit_type
	soa.literal_values[tok.index] = value
	return tok
}

get_token_type :: #force_inline proc(tok: CompactToken) -> TokenType {
	if tok.index == INVALID_TOKEN_INDEX || tok.soa == nil { return .Invalid }
	if tok.index >= tok.soa.count { return .Invalid }
	return tok.soa.slots[tok.index].type
}

get_token_view :: proc(tok: CompactToken) -> TokenView {
	if tok.index == INVALID_TOKEN_INDEX || tok.soa == nil { return TokenView{token_type = .Invalid} }
	s := tok.soa.slots[tok.index]
	return TokenView{
		token_type = s.type,
		offset  = s.offset,
		length  = s.length,
		had_line_terminator = (s.flags & TOKEN_FLAG_LINE_TERM) != 0,
		literal = tok.soa.literal_values[tok.index],
		literal_type = tok.soa.literal_types[tok.index],
	}
}

TokenView :: struct {
	token_type:   TokenType,
	offset:  u32,
	length:  u16,
	had_line_terminator: bool,
	literal: LiteralValue,
	literal_type: LiteralType,
}

get_token_loc :: proc(tok: CompactToken) -> Loc {
	if tok.index == INVALID_TOKEN_INDEX || tok.soa == nil { return Loc{} }
	return Loc{offset = int(tok.soa.slots[tok.index].offset)}
}

get_token_source :: proc(tok: CompactToken, source: string) -> string {
	if tok.index == INVALID_TOKEN_INDEX || tok.soa == nil { return "" }
	s := tok.soa.slots[tok.index]
	offset := int(s.offset)
	length := int(s.length)
	if offset + length <= len(source) { return source[offset:offset+length] }
	return ""
}

get_token_literal :: proc(tok: CompactToken) -> (LiteralValue, LiteralType) {
	if tok.index == INVALID_TOKEN_INDEX || tok.soa == nil { return LiteralValue{}, .None }
	return tok.soa.literal_values[tok.index], tok.soa.literal_types[tok.index]
}

set_token_literal :: proc(tok: CompactToken, lit_type: LiteralType, value: LiteralValue) {
	if tok.index == INVALID_TOKEN_INDEX || tok.soa == nil { return }
	tok.soa.literal_types[tok.index]  = lit_type
	tok.soa.literal_values[tok.index] = value
}

// Ring compat (2-slot)
TokenRing :: struct {
	cur:       CompactToken,
	nxt:       CompactToken,
	cur_type:  TokenType,
	nxt_type:  TokenType,
	has_next:  bool,
	soa:       ^TokenSoA,
}

init_token_ring :: proc(ring: ^TokenRing, soa: ^TokenSoA) {
	ring.soa = soa
	ring.cur = CompactToken{index = INVALID_TOKEN_INDEX, soa = soa}
	ring.nxt = CompactToken{index = INVALID_TOKEN_INDEX, soa = soa}
	ring.cur_type = .EOF
	ring.nxt_type = .EOF
	ring.has_next = false
}

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

ring_peek :: #force_inline proc(ring: ^TokenRing, offset: u8) -> CompactToken {
	if offset == 0 { return ring.cur }
	if offset == 1 && ring.has_next { return ring.nxt }
	return CompactToken{index = INVALID_TOKEN_INDEX, soa = ring.soa}
}

ring_peek_type :: #force_inline proc(ring: ^TokenRing, offset: u8) -> TokenType {
	if offset == 0 { return ring.cur_type }
	if offset == 1 { return ring.nxt_type }
	return .EOF
}

ring_is_type :: #force_inline proc(ring: ^TokenRing, offset: u8, token_type: TokenType) -> bool {
	return ring_peek_type(ring, offset) == token_type
}

compact_to_legacy :: proc(tok: CompactToken, source: string) -> Token {
	view := get_token_view(tok)
	return Token{
		type    = view.token_type,
		loc     = Loc{offset = int(view.offset)},
		value   = get_token_source(tok, source),
		literal = view.literal,
		had_line_terminator = view.had_line_terminator,
	}
}
