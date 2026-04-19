package lexer

// ============================================================================
// PERFECT HASH KEYWORDS
// O(1) keyword lookup using minimal perfect hash
// ============================================================================

// Keyword hash table - size 256 for extra space (power of 2 for fast mask)
KEYWORD_HASH_SIZE_2 :: 256

// Pre-computed hash table for JavaScript keywords
keyword_hash_table_2: [KEYWORD_HASH_SIZE_2]struct {
	name:  string,
	token: TokenType,
	used:  bool,
}

// FNV-1a hash
fnv1a_hash_keyword :: proc(s: string) -> u32 {
	hash: u32 = 2166136261
	for c in s {
		hash ~= u32(c)
		hash *= 16777619
	}
	return hash
}

// Perfect hash function
perfect_hash :: proc(s: string) -> u32 {
	hash := fnv1a_hash_keyword(s)
	hash = (hash ~ (hash >> 7)) & (KEYWORD_HASH_SIZE_2 - 1)
	return hash
}

// Initialize keyword hash table at startup
// This runs once on first use (lazy initialization)
init_keyword_hash_table :: proc() {
	// Keywords array
	keywords := []struct{ name: string, token: TokenType }{
		// Reserved words
		{"break", .Break},
		{"case", .Case},
		{"catch", .Catch},
		{"class", .Class},
		{"const", .Const},
		{"continue", .Continue},
		{"debugger", .Debugger},
		{"default", .Default},
		{"delete", .Delete},
		{"do", .Do},
		{"else", .Else},
		{"export", .Export},
		{"extends", .Extends},
		{"finally", .Finally},
		{"for", .For},
		{"function", .Function},
		{"if", .If},
		{"import", .Import},
		{"in", .In},
		{"instanceof", .Instanceof},
		{"let", .Let},
		{"new", .New},
		{"return", .Return},
		{"super", .Super},
		{"switch", .Switch},
		{"this", .This},
		{"throw", .Throw},
		{"try", .Try},
		{"typeof", .Typeof},
		{"var", .Var},
		{"void", .Void},
		{"while", .While},
		{"with", .With},
		{"yield", .Yield},
		
		// Literals
		{"null", .Null},
		{"true", .True},
		{"false", .False},
		
		// Contextual keywords (strict mode / module)
		{"async", .Async},
		{"await", .Await},
		{"from", .From},
		{"as", .As},
		{"of", .Of},
		{"get", .Get},
		{"set", .Set},
		{"static", .Static},
	}
	
	// Insert all keywords
	for kw in keywords {
		hash := perfect_hash(kw.name)
		
		// Linear probing for collision resolution
		idx := int(hash)
		for keyword_hash_table_2[idx].used {
			idx = (idx + 1) & (KEYWORD_HASH_SIZE_2 - 1)
		}
		
		keyword_hash_table_2[idx] = {
			name  = kw.name,
			token = kw.token,
			used  = true,
		}
	}
}

// Fast keyword lookup - O(1) average case
// Returns (token_type, is_keyword)
lookup_keyword_fast :: proc(s: string) -> (TokenType, bool) {
	// Fast rejection by first char (most identifiers start with non-keyword letters)
	if len(s) == 0 || len(s) > 12 {  // Longest keyword is "instanceof" (10)
		return .Identifier, false
	}
	
	hash := perfect_hash(s)
	idx := int(hash)
	
	// Check primary slot
	entry := &keyword_hash_table_2[idx]
	if entry.used && entry.name == s {
		return entry.token, true
	}
	
	// Linear probing (rare - only on collisions)
	for i := 0; i < 4; i += 1 {  // Max 4 probes
		idx = (idx + 1) & (KEYWORD_HASH_SIZE_2 - 1)
		entry = &keyword_hash_table_2[idx]
		if !entry.used {
			return .Identifier, false
		}
		if entry.name == s {
			return entry.token, true
		}
	}
	
	return .Identifier, false
}

// ============================================================================
// Fast Keyword Check (first char optimization)
// ============================================================================

// Quick reject: check if first char could start a keyword
// First letters that start keywords: a, b, c, d, e, f, g, i, l, n, r, s, t, v, w, y
fast_keyword_reject :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	
	c := s[0]
	switch c {
	case 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'i', 'l', 'n', 'o', 'r', 's', 't', 'v', 'w', 'y':
		return true
	case:
		return false
	}
}

// Ultra-fast lookup with quick reject
lookup_keyword_ultra :: #force_inline proc(s: string) -> (TokenType, bool) {
	l := len(s)
	// 1 char: never a keyword
	if l < 2 { return .Identifier, false }
	if l > 12 { return .Identifier, false }
	// 2 char: tiny inline table (only 5 keywords)
	if l == 2 {
		c0 := s[0]; c1 := s[1]
		if c0 == 'a' && c1 == 's' { return .As, true }
		if c0 == 'd' && c1 == 'o' { return .Do, true }
		if c0 == 'i' {
			if c1 == 'f' { return .If, true }
			if c1 == 'n' { return .In, true }
		}
		if c0 == 'o' && c1 == 'f' { return .Of, true }
		return .Identifier, false
	}
	// 3+ chars: quick reject by first char, then hash
	if !fast_keyword_reject(s) {
		return .Identifier, false
	}
	return lookup_keyword_fast(s)
}

// ============================================================================
// Initialization (runs once at process startup via @(init))
// ============================================================================

keyword_hash_initialized := false

ensure_keyword_hash :: #force_inline proc() {
	if !keyword_hash_initialized {
		init_keyword_hash_table()
		keyword_hash_initialized = true
	}
}
