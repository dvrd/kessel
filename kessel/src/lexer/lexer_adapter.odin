package lexer

// ============================================================================
// LEXER ADAPTER
// Provides backwards-compatible interface to optimized lexer
// Allows gradual migration from legacy Token to CompactToken
// ============================================================================

import "core:mem"

// LexerAdapter wraps Lexer2 with legacy interface
LexerAdapter :: struct {
	// The optimized lexer
	opt: Lexer2,
	
	// Source reference (needed for legacy token conversion)
	source: string,
	
	// Token conversion cache (avoids repeated conversions)
	current_cache: Token,
	peek_cache: Token,
	peek2_cache: Token,
	
	// Cache valid flags
	current_valid: bool,
	peek_valid: bool,
	peek2_valid: bool,
}

// Initialize adapter with optimized lexer
init_adapter :: proc(a: ^LexerAdapter, source: string, arena: ^mem.Arena) {
	a.source = source
	init_lexer2(&a.opt, source, arena)
	a.current_valid = false
	a.peek_valid = false
	a.peek2_valid = false
}

// ============================================================================
// Legacy Interface Implementation
// ============================================================================

// Get current token (legacy format)
get_current_adapter :: proc(a: ^LexerAdapter) -> Token {
	if a == nil {
		return Token{type = .EOF}
	}
	if !a.current_valid {
		compact := get_current2(&a.opt)
		a.current_cache = compact_to_legacy(compact, a.source)
		a.current_valid = true
	}
	return a.current_cache
}

// Advance and return next token (legacy format)
next_adapter :: proc(a: ^LexerAdapter) -> Token {
	if a == nil {
		return Token{type = .EOF}
	}
	// Get current BEFORE advancing
	result := get_current_adapter(a)
	
	// Invalidate caches and advance
	a.current_valid = false
	a.peek_valid = false
	a.peek2_valid = false
	next2(&a.opt)
	
	return result
}

// Peek at next token (legacy format)
peek_adapter :: proc(a: ^LexerAdapter) -> Token {
	if a == nil {
		return Token{type = .EOF}
	}
	if !a.peek_valid {
		compact := peek2_compact(&a.opt)
		a.peek_cache = compact_to_legacy(compact, a.source)
		a.peek_valid = true
	}
	return a.peek_cache
}

// Peek two tokens ahead (legacy format)
peek2_adapter :: proc(a: ^LexerAdapter) -> Token {
	if a == nil {
		return Token{type = .EOF}
	}
	if !a.peek2_valid {
		compact := peek2_ahead(&a.opt)
		a.peek2_cache = compact_to_legacy(compact, a.source)
		a.peek2_valid = true
	}
	return a.peek2_cache
}

// Check current token type
is_adapter :: proc(a: ^LexerAdapter, type_: TokenType) -> bool {
	return is2(&a.opt, type_)
}

// Expect and consume token
expect_adapter :: proc(a: ^LexerAdapter, type_: TokenType) -> (Token, bool) {
	if is_adapter(a, type_) {
		return next_adapter(a), true
	}
	return get_current_adapter(a), false
}

// ============================================================================
// Direct Access to Optimized Features
// ============================================================================

// Get compact token directly (for new code)
get_compact_current :: proc(a: ^LexerAdapter) -> CompactToken {
	return get_current2(&a.opt)
}

// Advance and get compact token
next_compact_adapter :: proc(a: ^LexerAdapter) -> CompactToken {
	a.current_valid = false
	a.peek_valid = false
	a.peek2_valid = false
	return next2(&a.opt)
}

// Get lexer statistics
get_stats :: proc(a: ^LexerAdapter) -> LexerStats {
	return a.opt.stats
}

// ============================================================================
// Macro-like helpers (Odin doesn't have macros, use inline procs)
// ============================================================================

// Reset all cache flags
invalidate_cache :: proc(a: ^LexerAdapter) {
	a.current_valid = false
	a.peek_valid = false
	a.peek2_valid = false
}
