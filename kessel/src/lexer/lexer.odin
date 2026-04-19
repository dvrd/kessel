package lexer

import "core:mem"

// ============================================================================
// OPTIMIZATION: Fast Character Classification
// ============================================================================

// Character class constants
CharClass :: enum u8 {
    Other      = 0,
    Whitespace = 1,
    IdStart    = 2,  // a-z, A-Z, _, $
    IdCont     = 3,  // a-z, A-Z, 0-9, _, $
    Digit      = 4,
    Operator   = 5,
    Punct      = 6,
}

// 256-byte lookup table for character classification
// Initialized at process startup via @(init)
CHAR_CLASS_TABLE: [256]u8
char_table_initialized := false

@(init)
init_char_class_table :: proc "contextless" () {
    for i in 0..<256 {
        c := u8(i)
        if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f' {
            CHAR_CLASS_TABLE[i] = u8(CharClass.Whitespace)
        } else if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$' {
            CHAR_CLASS_TABLE[i] = u8(CharClass.IdStart)
        } else if c >= '0' && c <= '9' {
            CHAR_CLASS_TABLE[i] = u8(CharClass.Digit)
        } else {
            CHAR_CLASS_TABLE[i] = u8(CharClass.Other)
        }
    }
    char_table_initialized = true
}

// Fast inline character classification
get_char_class :: proc(c: u8) -> CharClass {
    if !char_table_initialized {
        init_char_class_table()
    }
    return CharClass(CHAR_CLASS_TABLE[c])
}

// Fast whitespace check
is_whitespace_fast :: proc(c: u8) -> bool {
    if !char_table_initialized {
        init_char_class_table()
    }
    return CHAR_CLASS_TABLE[c] == u8(CharClass.Whitespace)
}

// Fast identifier start check  
// Table is guaranteed initialized by @(init) — no runtime check needed
is_id_start_fast :: #force_inline proc(c: u8) -> bool {
    return CHAR_CLASS_TABLE[c] == u8(CharClass.IdStart)
}

is_id_cont_fast :: #force_inline proc(c: u8) -> bool {
    class := CHAR_CLASS_TABLE[c]
    return class == u8(CharClass.IdStart) || class == u8(CharClass.Digit)
}
import "core:unicode"
import "core:unicode/utf8"
import "core:strconv"

// Lexer represents the lexical analyzer
Lexer :: struct {
	source:     string,
	offset:     int,
	line:       int,
	column:     int,
	
	// Arena for token allocations
	arena:      ^mem.Arena,
	
	// Current and lookahead tokens
	current:    Token,
	lookahead:  Token,
	lookahead2: Token,
	
	// Token buffer for multiple token peeking
	token_buf:  [dynamic]Token,
	buf_pos:    int,
	
	// State for template literals
	template_stack: [dynamic]bool,
	in_template: bool,  // true when waiting for TemplateMiddle or TemplateTail after }
	
	// Inside JSX?
	jsx_context: bool,
	
	// Strict mode flag
	strict_mode: bool,
}

// Error types
LexerError :: enum {
	None,
	UnexpectedCharacter,
	UnterminatedString,
	UnterminatedTemplate,
	UnterminatedComment,
	InvalidEscapeSequence,
	InvalidNumber,
	InvalidRegExp,
}

// Initialize a new lexer
init :: proc(l: ^Lexer, source: string, arena: ^mem.Arena) {
	l.source = source
	l.offset = 0
	l.line = 1
	l.column = 1
	l.arena = arena
	l.buf_pos = 0
	l.jsx_context = false
	l.strict_mode = false
	
	// Initialize token buffer with arena allocator
	l.token_buf = make([dynamic]Token, mem.arena_allocator(arena))
	l.template_stack = make([dynamic]bool, mem.arena_allocator(arena))
	
	// Prime the lexer with first tokens
	next_token(l, &l.current)
	next_token(l, &l.lookahead)
	next_token(l, &l.lookahead2)
}

// Get current token
get_current :: proc(l: ^Lexer) -> Token {
	return l.current
}

// Get next token (advance)
next :: proc(l: ^Lexer) -> Token {
	result := l.current
	l.current = l.lookahead
	l.lookahead = l.lookahead2
	next_token(l, &l.lookahead2)
	return result
}

// Peek at next token without consuming
peek :: proc(l: ^Lexer) -> Token {
	return l.lookahead
}

// Peek two tokens ahead
peek2 :: proc(l: ^Lexer) -> Token {
	return l.lookahead2
}

// Check if current token matches type
is :: proc(l: ^Lexer, t: TokenType) -> bool {
	return l.current.type == t
}

// Expect a specific token type, consume if matches
expect :: proc(l: ^Lexer, t: TokenType) -> (Token, bool) {
	if l.current.type == t {
		return next(l), true
	}
	return l.current, false
}

// Skip whitespace and comments
skip_whitespace :: proc(l: ^Lexer) {
	for l.offset < len(l.source) {
		c := l.source[l.offset]
		
		switch c {
		case ' ', '\t', '\r':
			advance(l, 1)
		case '\n':
			advance_line(l)
		case '/':
			// Potential comment
			if l.offset + 1 < len(l.source) {
				next := l.source[l.offset + 1]
				if next == '/' {
					skip_line_comment(l)
				} else if next == '*' {
					skip_block_comment(l)
				} else {
					return
				}
			} else {
				return
			}
		case:
			return
		}
	}
}

// SIMD-accelerated whitespace skipping
skip_whitespace_fast :: proc(l: ^Lexer) {
	// Minimum bytes before SIMD is worth it (overhead threshold)
	SIMD_THRESHOLD :: 32
	
	for l.offset < len(l.source) {
		// Check if we have enough bytes for SIMD
		remaining := len(l.source) - l.offset
		
		if remaining >= SIMD_THRESHOLD {
			// Try to skip whitespace in chunks using SIMD
			advanced := skip_whitespace_simd(l)
			if advanced > 0 {
				continue
			}
		}
		
		// Fall back to scalar for small chunks or non-whitespace
		c := l.source[l.offset]
		
		switch c {
		case ' ', '\t', '\r':
			advance(l, 1)
		case '\n':
			advance_line(l)
		case '/':
			// Potential comment - handled by scalar version
			if l.offset + 1 < len(l.source) {
				next := l.source[l.offset + 1]
				if next == '/' {
					skip_line_comment(l)
					continue
				} else if next == '*' {
					skip_block_comment(l)
					continue
				}
			}
			return
		case:
			return
		}
	}
}

// SIMD-accelerated whitespace detection
// Uses platform-specific SIMD to check 16/32 bytes at once
skip_whitespace_simd :: proc(l: ^Lexer) -> int {
	// Whitespace characters to match: space, tab, \r, \n
	// We'll use a simple byte comparison approach
	
	start_offset := l.offset
	end := len(l.source)
	
	// Process 16 bytes at a time
	for l.offset + 16 <= end {
		// Load 16 bytes
		chunk := l.source[l.offset:l.offset+16]
		
		// Check if all 16 bytes are whitespace
		// This is a simplified scalar version - real SIMD would use intrinsics
		all_ws := true
		for b in chunk {
			if b != ' ' && b != '\t' && b != '\r' && b != '\n' {
				all_ws = false
				break
			}
		}
		
		if !all_ws {
			// Found non-whitespace, process remaining bytes individually
			break
		}
		
		// All 16 bytes are whitespace, advance
		// Count newlines for line tracking
		for b in chunk {
			if b == '\n' {
				l.line += 1
				l.column = 1
			} else {
				l.column += 1
			}
		}
		l.offset += 16
	}
	
	return l.offset - start_offset
}

// TODO: Add true SIMD intrinsics for ARM64 NEON and x86 SSE/AVX
// This requires platform detection and assembly/intrinsic usage

// Skip single-line comment
skip_line_comment :: proc(l: ^Lexer) {
	// Skip //
	advance(l, 2)
	
	for l.offset < len(l.source) && l.source[l.offset] != '\n' {
		advance(l, 1)
	}
}

// Skip block comment
skip_block_comment :: proc(l: ^Lexer) -> LexerError {
	start_line := l.line
	start_col := l.column
	
	// Skip /*
	advance(l, 2)
	
	for l.offset + 1 < len(l.source) {
		if l.source[l.offset] == '*' && l.source[l.offset + 1] == '/' {
			advance(l, 2)
			return .None
		}
		
		if l.source[l.offset] == '\n' {
			advance_line(l)
		} else {
			advance(l, 1)
		}
	}
	
	return .UnterminatedComment
}

// Get the next token
next_token :: proc(l: ^Lexer, tok: ^Token) -> LexerError {
	skip_whitespace(l)
	
	tok.loc.offset = l.offset
	tok.loc.line = l.line
	tok.loc.column = l.column
	
	if l.offset >= len(l.source) {
		tok.type = .EOF
		tok.value = ""
		return .None
	}
	
	c := l.source[l.offset]
	
	// Check for multi-character tokens first
	switch c {
	case '/':
		if l.offset + 1 < len(l.source) {
			next_c := l.source[l.offset + 1]
			if next_c == '=' {
				tok.type = .AssignDiv
				tok.value = l.source[l.offset:l.offset+2]
				advance(l, 2)
				return .None
			}
		}
		
		// Check for regex literal (context-sensitive)
		if can_parse_regex(l) {
			return scan_regexp(l, tok)
		}
		
		tok.type = .Div
		tok.value = "/"
		advance(l, 1)
		return .None
		
	case '*':
		if l.offset + 1 < len(l.source) {
			next_c := l.source[l.offset + 1]
			switch next_c {
			case '=':
				tok.type = .AssignMul
				tok.value = l.source[l.offset:l.offset+2]
				advance(l, 2)
				return .None
			case '*':
				if l.offset + 2 < len(l.source) && l.source[l.offset + 2] == '=' {
					tok.type = .AssignPow
					tok.value = l.source[l.offset:l.offset+3]
					advance(l, 3)
					return .None
				}
				tok.type = .Pow
				tok.value = l.source[l.offset:l.offset+2]
				advance(l, 2)
				return .None
			}
		}
		tok.type = .Mul
		tok.value = "*"
		advance(l, 1)
		return .None
		
	case '%':
		if l.offset + 1 < len(l.source) && l.source[l.offset + 1] == '=' {
			tok.type = .AssignMod
			tok.value = l.source[l.offset:l.offset+2]
			advance(l, 2)
			return .None
		}
		tok.type = .Mod
		tok.value = "%"
		advance(l, 1)
		return .None
		
	case '+':
		if l.offset + 1 < len(l.source) {
			next_c := l.source[l.offset + 1]
			switch next_c {
			case '+':
				tok.type = .PlusPlus
				tok.value = l.source[l.offset:l.offset+2]
				advance(l, 2)
				return .None
			case '=':
				tok.type = .AssignAdd
				tok.value = l.source[l.offset:l.offset+2]
				advance(l, 2)
				return .None
			}
		}
		tok.type = .Plus
		tok.value = "+"
		advance(l, 1)
		return .None
		
	case '-':
		if l.offset + 1 < len(l.source) {
			next_c := l.source[l.offset + 1]
			switch next_c {
			case '-':
				tok.type = .MinusMinus
				tok.value = l.source[l.offset:l.offset+2]
				advance(l, 2)
				return .None
			case '=':
				tok.type = .AssignSub
				tok.value = l.source[l.offset:l.offset+2]
				advance(l, 2)
				return .None
			}
		}
		tok.type = .Minus
		tok.value = "-"
		advance(l, 1)
		return .None
		
	case '<':
		if l.offset + 1 < len(l.source) {
			next_c := l.source[l.offset + 1]
			switch next_c {
			case '=':
				tok.type = .LEq
				tok.value = l.source[l.offset:l.offset+2]
				advance(l, 2)
				return .None
			case '<':
				if l.offset + 2 < len(l.source) && l.source[l.offset + 2] == '=' {
					tok.type = .AssignLShift
					tok.value = l.source[l.offset:l.offset+3]
					advance(l, 3)
					return .None
				}
				tok.type = .LShift
				tok.value = l.source[l.offset:l.offset+2]
				advance(l, 2)
				return .None
			}
		}
		tok.type = .LAngle
		tok.value = "<"
		advance(l, 1)
		return .None
		
	case '>':
		if l.offset + 1 < len(l.source) {
			next_c := l.source[l.offset + 1]
			switch next_c {
			case '=':
				tok.type = .GEq
				tok.value = l.source[l.offset:l.offset+2]
				advance(l, 2)
				return .None
			case '>':
				if l.offset + 2 < len(l.source) {
					next2_c := l.source[l.offset + 2]
					if next2_c == '=' {
						tok.type = .AssignURShift
						tok.value = l.source[l.offset:l.offset+3]
						advance(l, 3)
						return .None
					} else if next2_c == '>' {
						tok.type = .URShift
						tok.value = l.source[l.offset:l.offset+3]
						advance(l, 3)
						return .None
					}
				}
				tok.type = .RShift
				tok.value = l.source[l.offset:l.offset+2]
				advance(l, 2)
				return .None
			}
		}
		tok.type = .RAngle
		tok.value = ">"
		advance(l, 1)
		return .None
		
	case '=':
		if l.offset + 1 < len(l.source) {
			next_c := l.source[l.offset + 1]
			switch next_c {
			case '=':
				if l.offset + 2 < len(l.source) && l.source[l.offset + 2] == '=' {
					tok.type = .EqStrict
					tok.value = l.source[l.offset:l.offset+3]
					advance(l, 3)
					return .None
				}
				tok.type = .Eq
				tok.value = l.source[l.offset:l.offset+2]
				advance(l, 2)
				return .None
			case '>':
				tok.type = .Arrow
				tok.value = l.source[l.offset:l.offset+2]
				advance(l, 2)
				return .None
			}
		}
		tok.type = .Assign
		tok.value = "="
		advance(l, 1)
		return .None
		
	case '!':
		if l.offset + 1 < len(l.source) && l.source[l.offset + 1] == '=' {
			if l.offset + 2 < len(l.source) && l.source[l.offset + 2] == '=' {
				tok.type = .NotEqStrict
				tok.value = l.source[l.offset:l.offset+3]
				advance(l, 3)
				return .None
			}
			tok.type = .NotEq
			tok.value = l.source[l.offset:l.offset+2]
			advance(l, 2)
			return .None
		}
		tok.type = .Not
		tok.value = "!"
		advance(l, 1)
		return .None
		
	case '&':
		if l.offset + 1 < len(l.source) {
			next_c := l.source[l.offset + 1]
			switch next_c {
			case '&':
				if l.offset + 2 < len(l.source) && l.source[l.offset + 2] == '=' {
					tok.type = .AssignLogicalAnd
					tok.value = l.source[l.offset:l.offset+3]
					advance(l, 3)
					return .None
				}
				tok.type = .LogicalAnd
				tok.value = l.source[l.offset:l.offset+2]
				advance(l, 2)
				return .None
			case '=':
				tok.type = .AssignBitAnd
				tok.value = l.source[l.offset:l.offset+2]
				advance(l, 2)
				return .None
			}
		}
		tok.type = .BitAnd
		tok.value = "&"
		advance(l, 1)
		return .None
		
	case '|':
		if l.offset + 1 < len(l.source) {
			next_c := l.source[l.offset + 1]
			switch next_c {
			case '|':
				if l.offset + 2 < len(l.source) && l.source[l.offset + 2] == '=' {
					tok.type = .AssignLogicalOr
					tok.value = l.source[l.offset:l.offset+3]
					advance(l, 3)
					return .None
				}
				tok.type = .LogicalOr
				tok.value = l.source[l.offset:l.offset+2]
				advance(l, 2)
				return .None
			case '=':
				tok.type = .AssignBitOr
				tok.value = l.source[l.offset:l.offset+2]
				advance(l, 2)
				return .None
			}
		}
		tok.type = .BitOr
		tok.value = "|"
		advance(l, 1)
		return .None
		
	case '^':
		if l.offset + 1 < len(l.source) && l.source[l.offset + 1] == '=' {
			tok.type = .AssignBitXor
			tok.value = l.source[l.offset:l.offset+2]
			advance(l, 2)
			return .None
		}
		tok.type = .BitXor
		tok.value = "^"
		advance(l, 1)
		return .None
		
	case '?':
		if l.offset + 1 < len(l.source) {
			next_c := l.source[l.offset + 1]
			switch next_c {
			case '?':
				if l.offset + 2 < len(l.source) && l.source[l.offset + 2] == '=' {
					tok.type = .AssignNullish
					tok.value = l.source[l.offset:l.offset+3]
					advance(l, 3)
					return .None
				}
				tok.type = .Nullish
				tok.value = l.source[l.offset:l.offset+2]
				advance(l, 2)
				return .None
			case '.':
				tok.type = .OptionalChain
				tok.value = l.source[l.offset:l.offset+2]
				advance(l, 2)
				return .None
			}
		}
		tok.type = .Question
		tok.value = "?"
		advance(l, 1)
		return .None
		
	case '.':
		if l.offset + 2 < len(l.source) &&
		   l.source[l.offset + 1] == '.' &&
		   l.source[l.offset + 2] == '.' {
			tok.type = .Dot3
			tok.value = l.source[l.offset:l.offset+3]
			advance(l, 3)
			return .None
		}
		// Check for decimal number
		if l.offset + 1 < len(l.source) && is_digit(l.source[l.offset + 1]) {
			return scan_number(l, tok, true)
		}
		tok.type = .Dot
		tok.value = "."
		advance(l, 1)
		return .None
		
	case '{':
		tok.type = .LBrace
		tok.value = "{"
		advance(l, 1)
		return .None
	case '}':
		// Check if we're inside a template literal
		if l.in_template {
			advance(l, 1) // consume }
			// Continue scanning template for TemplateMiddle or TemplateTail
			return scan_template_continuation(l, tok)
		}
		tok.type = .RBrace
		tok.value = "}"
		advance(l, 1)
		return .None
	case '(':
		tok.type = .LParen
		tok.value = "("
		advance(l, 1)
		return .None
	case ')':
		tok.type = .RParen
		tok.value = ")"
		advance(l, 1)
		return .None
	case '[':
		tok.type = .LBracket
		tok.value = "["
		advance(l, 1)
		return .None
	case ']':
		tok.type = .RBracket
		tok.value = "]"
		advance(l, 1)
		return .None
	case ';':
		tok.type = .Semi
		tok.value = ";"
		advance(l, 1)
		return .None
	case ',':
		tok.type = .Comma
		tok.value = ","
		advance(l, 1)
		return .None
	case ':':
		tok.type = .Colon
		tok.value = ":"
		advance(l, 1)
		return .None
	case '~':
		tok.type = .BitNot
		tok.value = "~"
		advance(l, 1)
		return .None
		
	case '`':
		return scan_template(l, tok)
		
	case '"', '\'':
		return scan_string(l, tok, c)
		
	case '#':
		// Private identifier (ES2022+)
		if l.offset + 1 < len(l.source) && is_id_start(l.source[l.offset + 1]) {
			return scan_private_identifier(l, tok)
		}
		return .UnexpectedCharacter
		
	case:
		// Number literal
		if is_digit(c) {
			return scan_number(l, tok, false)
		}
		
		// Identifier or keyword
		if is_id_start(c) {
			return scan_identifier(l, tok)
		}
		
		// Invalid character
		tok.type = .Invalid
		tok.value = l.source[l.offset:l.offset+1]
		advance(l, 1)
		return .UnexpectedCharacter
	}
}

// Scan identifier or keyword
scan_identifier :: proc(l: ^Lexer, tok: ^Token) -> LexerError {
	start := l.offset
	
	for l.offset < len(l.source) && is_id_part(l.source[l.offset]) {
		advance(l, 1)
	}
	
	value := l.source[start:l.offset]
	
	// Fast keyword lookup using perfect hash (O(1) average case)
	ensure_keyword_hash()
	if token_type, is_kw := lookup_keyword_ultra(value); is_kw {
		tok.type = token_type
	} else {
		tok.type = .Identifier
	}
	
	tok.value = value
	return .None
}

// Scan string literal
scan_string :: proc(l: ^Lexer, tok: ^Token, quote: byte) -> LexerError {
	start := l.offset
	start_line := l.line
	start_col := l.column
	
	// Skip opening quote
	advance(l, 1)
	
	builder := make([dynamic]byte, mem.arena_allocator(l.arena))
	
	for l.offset < len(l.source) {
		c := l.source[l.offset]
		
		if c == quote {
			advance(l, 1)
			tok.type = .String
			tok.value = l.source[start:l.offset]
			tok.literal = string(builder[:])
			return .None
		}
		
		if c == '\\' {
			// Escape sequence
			err := scan_escape_sequence(l, &builder)
			if err != .None {
				return err
			}
		} else if c == '\n' || c == '\r' {
			return .UnterminatedString
		} else {
			append(&builder, c)
			advance(l, 1)
		}
	}
	
	return .UnterminatedString
}

// Scan escape sequence
scan_escape_sequence :: proc(l: ^Lexer, builder: ^[dynamic]byte) -> LexerError {
	// Skip backslash
	advance(l, 1)
	
	if l.offset >= len(l.source) {
		return .InvalidEscapeSequence
	}
	
	c := l.source[l.offset]
	
	switch c {
	case 'n':  append(builder, '\n')
	case 't':  append(builder, '\t')
	case 'r':  append(builder, '\r')
	case 'v':  append(builder, '\v')
	case 'f':  append(builder, '\f')
	case 'b':  append(builder, '\b')
	case '0':  append(builder, '\x00')
	case '\\': append(builder, '\\')
	case '/':  append(builder, '/')
	case '"':  append(builder, '"')
	case '\'': append(builder, '\'')
	case '`':  append(builder, '`')
	case 'x':
		// Hex escape \xNN
		hex, err := scan_hex_escape(l, 2)
		if !err {
			return .InvalidEscapeSequence
		}
		append(builder, byte(hex))
		return .None
	case 'u':
		// Unicode escape
		if l.offset + 1 < len(l.source) && l.source[l.offset + 1] == '{' {
			// \u{NNNNN}
			r, err := scan_unicode_escape_braced(l)
			if !err {
				return .InvalidEscapeSequence
			}
			b, _ := utf8.encode_rune(r)
			append(builder, b[0], b[1], b[2], b[3])
		} else {
			// \uNNNN
			r, ok := scan_unicode_escape(l, 4)
			if !ok {
				return .InvalidEscapeSequence
			}
			b, _ := utf8.encode_rune(r)
			append(builder, b[0], b[1], b[2], b[3])
		}
		return .None
	case:
		return .InvalidEscapeSequence
	}
	
	advance(l, 1)
	return .None
}

// Scan hex escape sequence
scan_hex_escape :: proc(l: ^Lexer, digits: int) -> (int, bool) {
	advance(l, 1) // Skip 'x' or start of escape
	
	if l.offset + digits > len(l.source) {
		return 0, false
	}
	
	value := 0
	for i in 0..<digits {
		c := l.source[l.offset + i]
		digit := hex_digit_value(c)
		if digit < 0 {
			return 0, false
		}
		value = value * 16 + digit
	}
	
	advance(l, digits)
	return value, true
}

// Scan braced unicode escape \u{NNNNN}
scan_unicode_escape_braced :: proc(l: ^Lexer) -> (rune, bool) {
	advance(l, 2) // Skip 'u{'
	
	value := 0
	digit_count := 0
	
	for l.offset < len(l.source) && l.source[l.offset] != '}' {
		c := l.source[l.offset]
		digit := hex_digit_value(c)
		if digit < 0 {
			return 0, false
		}
		value = value * 16 + digit
		digit_count += 1
		advance(l, 1)
	}
	
	if digit_count == 0 || digit_count > 6 || l.offset >= len(l.source) {
		return 0, false
	}
	
	advance(l, 1) // Skip '}'
	return rune(value), true
}

// Scan unicode escape \uNNNN
scan_unicode_escape :: proc(l: ^Lexer, digits: int) -> (rune, bool) {
	value, ok := scan_hex_escape(l, digits)
	return rune(value), ok
}

// Scan number literal
scan_number :: proc(l: ^Lexer, tok: ^Token, starts_with_dot: bool) -> LexerError {
	start := l.offset
	
	// Integer part
	if !starts_with_dot {
		// Handle 0x, 0o, 0b prefixes
		if l.source[l.offset] == '0' && l.offset + 1 < len(l.source) {
			next_c := l.source[l.offset + 1]
			switch next_c {
			case 'x', 'X':
				return scan_hex_number(l, tok)
			case 'o', 'O':
				return scan_octal_number(l, tok)
			case 'b', 'B':
				return scan_binary_number(l, tok)
			}
		}
		
		// Decimal integer
		for l.offset < len(l.source) && is_digit(l.source[l.offset]) {
			advance(l, 1)
		}
	} else {
		// Already consumed the leading dot
		advance(l, 1)
	}
	
	// Fractional part
	if l.offset < len(l.source) && l.source[l.offset] == '.' {
		advance(l, 1)
		for l.offset < len(l.source) && is_digit(l.source[l.offset]) {
			advance(l, 1)
		}
	}
	
	// Exponent
	if l.offset < len(l.source) {
		c := l.source[l.offset]
		if c == 'e' || c == 'E' {
			advance(l, 1)
			if l.offset < len(l.source) {
				sign_c := l.source[l.offset]
				if sign_c == '+' || sign_c == '-' {
					advance(l, 1)
				}
			}
			for l.offset < len(l.source) && is_digit(l.source[l.offset]) {
				advance(l, 1)
			}
		}
	}
	
	// BigInt suffix
	if l.offset < len(l.source) && l.source[l.offset] == 'n' {
		advance(l, 1)
		tok.type = .BigInt
		tok.value = l.source[start:l.offset]
		return .None
	}
	
	value := l.source[start:l.offset]
	
	// Parse the number
	num, ok := strconv.parse_f64(value)
	if !ok {
		return .InvalidNumber
	}
	
	tok.type = .Number
	tok.value = value
	tok.literal = num
	
	return .None
}

// Scan hex number
scan_hex_number :: proc(l: ^Lexer, tok: ^Token) -> LexerError {
	start := l.offset
	advance(l, 2) // Skip 0x
	
	if l.offset >= len(l.source) || !is_hex_digit(l.source[l.offset]) {
		return .InvalidNumber
	}
	
	for l.offset < len(l.source) && is_hex_digit(l.source[l.offset]) {
		advance(l, 1)
	}
	
	// BigInt
	if l.offset < len(l.source) && l.source[l.offset] == 'n' {
		advance(l, 1)
		tok.type = .BigInt
		tok.value = l.source[start:l.offset]
		return .None
	}
	
	value := l.source[start:l.offset]
	
	// Parse hex
	num := 0
	for i := start + 2; i < l.offset; i += 1 {
		num = num * 16 + hex_digit_value(l.source[i])
	}
	
	tok.type = .Number
	tok.value = value
	tok.literal = f64(num)
	
	return .None
}

// Scan octal number
scan_octal_number :: proc(l: ^Lexer, tok: ^Token) -> LexerError {
	start := l.offset
	advance(l, 2) // Skip 0o/0O

	if l.offset >= len(l.source) || !is_octal_digit(l.source[l.offset]) {
		return .InvalidNumber
	}

	for l.offset < len(l.source) && is_octal_digit(l.source[l.offset]) {
		advance(l, 1)
	}

	// BigInt
	if l.offset < len(l.source) && l.source[l.offset] == 'n' {
		advance(l, 1)
		tok.type = .BigInt
		tok.value = l.source[start:l.offset]
		return .None
	}

	value := l.source[start:l.offset]
	num := 0
	for i := start + 2; i < l.offset; i += 1 {
		num = num * 8 + int(l.source[i] - '0')
	}

	tok.type = .Number
	tok.value = value
	tok.literal = f64(num)
	return .None
}

// Scan binary number
scan_binary_number :: proc(l: ^Lexer, tok: ^Token) -> LexerError {
	start := l.offset
	advance(l, 2) // Skip 0b/0B

	if l.offset >= len(l.source) || !is_binary_digit(l.source[l.offset]) {
		return .InvalidNumber
	}

	for l.offset < len(l.source) && is_binary_digit(l.source[l.offset]) {
		advance(l, 1)
	}

	// BigInt
	if l.offset < len(l.source) && l.source[l.offset] == 'n' {
		advance(l, 1)
		tok.type = .BigInt
		tok.value = l.source[start:l.offset]
		return .None
	}

	value := l.source[start:l.offset]
	num := 0
	for i := start + 2; i < l.offset; i += 1 {
		num = num * 2 + int(l.source[i] - '0')
	}

	tok.type = .Number
	tok.value = value
	tok.literal = f64(num)
	return .None
}

// Scan template literal
scan_template :: proc(l: ^Lexer, tok: ^Token) -> LexerError {
	start := l.offset
	start_line := l.line
	start_col := l.column
	
	// Skip backtick
	advance(l, 1)
	
	builder := make([dynamic]byte, mem.arena_allocator(l.arena))
	
	is_head := true
	is_tail := true
	
	for l.offset < len(l.source) {
		c := l.source[l.offset]
		
		if c == '`' {
			advance(l, 1)
			is_tail = true
			break
		}
		
		if c == '$' && l.offset + 1 < len(l.source) && l.source[l.offset + 1] == '{' {
			advance(l, 2)
			is_tail = false
			break
		}
		
		if c == '\\' {
			err := scan_escape_sequence(l, &builder)
			if err != .None {
				return err
			}
		} else {
			if c == '\n' {
				advance_line(l)
			} else {
				append(&builder, c)
				advance(l, 1)
			}
		}
	}
	
	if l.offset >= len(l.source) {
		return .UnterminatedTemplate
	}
	
	tok.value = l.source[start:l.offset]
	
	// Determine template token type
	if is_head && is_tail {
		tok.type = .Template
		l.in_template = false
	} else if is_head {
		tok.type = .TemplateHead
		l.in_template = true
	} else if is_tail {
		tok.type = .TemplateTail
		l.in_template = false
	} else {
		tok.type = .TemplateMiddle
		l.in_template = true
	}
	
	tok.literal = string(builder[:])
	return .None
}

// Scan template continuation after }
scan_template_continuation :: proc(l: ^Lexer, tok: ^Token) -> LexerError {
	start := l.offset
	start_line := l.line
	start_col := l.column
	
	builder := make([dynamic]byte, mem.arena_allocator(l.arena))
	
	is_tail := true
	
	for l.offset < len(l.source) {
		c := l.source[l.offset]
		
		if c == '`' {
			advance(l, 1)
			is_tail = true
			break
		}
		
		if c == '$' && l.offset + 1 < len(l.source) && l.source[l.offset + 1] == '{' {
			advance(l, 2)
			is_tail = false
			break
		}
		
		if c == '\\' {
			err := scan_escape_sequence(l, &builder)
			if err != .None {
				return err
			}
		} else {
			if c == '\n' {
				advance_line(l)
			} else {
				append(&builder, c)
				advance(l, 1)
			}
		}
	}
	
	if l.offset >= len(l.source) {
		return .UnterminatedTemplate
	}
	
	// Include the leading } in the value
	tok.value = l.source[start:l.offset]
	
	// Determine template token type
	if is_tail {
		tok.type = .TemplateTail
		l.in_template = false
	} else {
		tok.type = .TemplateMiddle
		l.in_template = true
	}
	
	tok.literal = string(builder[:])
	return .None
}

// Scan regexp literal
scan_regexp :: proc(l: ^Lexer, tok: ^Token) -> LexerError {
	start := l.offset
	
	// Skip /
	advance(l, 1)
	
	pattern_start := l.offset
	
	for l.offset < len(l.source) {
		c := l.source[l.offset]
		
		if c == '/' {
			break
		}
		
		if c == '\\' {
			advance(l, 2)
		} else if c == '[' {
			// Character class
			advance(l, 1)
			for l.offset < len(l.source) && l.source[l.offset] != ']' {
				if l.source[l.offset] == '\\' {
					advance(l, 2)
				} else {
					advance(l, 1)
				}
			}
			if l.offset < len(l.source) {
				advance(l, 1) // Skip ]
			}
		} else if c == '\n' || c == '\r' {
			return .InvalidRegExp
		} else {
			advance(l, 1)
		}
	}
	
	if l.offset >= len(l.source) || l.source[l.offset] != '/' {
		return .InvalidRegExp
	}
	
	pattern := l.source[pattern_start:l.offset]
	advance(l, 1) // Skip /
	
	// Scan flags
	flags_start := l.offset
	for l.offset < len(l.source) && is_id_part(l.source[l.offset]) {
		advance(l, 1)
	}
	flags := l.source[flags_start:l.offset]
	
	tok.type = .RegularExpression
	tok.value = l.source[start:l.offset]
	
	return .None
}

// Scan private identifier (#name)
scan_private_identifier :: proc(l: ^Lexer, tok: ^Token) -> LexerError {
	start := l.offset
	advance(l, 1) // Skip #
	
	return scan_identifier(l, tok)
}

// Helper functions

advance :: proc(l: ^Lexer, n: int) {
	l.offset += n
	l.column += n
}

advance_line :: proc(l: ^Lexer) {
	l.offset += 1
	l.line += 1
	l.column = 1
}

is_whitespace :: proc(c: byte) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

is_digit :: proc(c: byte) -> bool {
	return c >= '0' && c <= '9'
}

is_hex_digit :: proc(c: byte) -> bool {
	return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

is_octal_digit :: proc(c: byte) -> bool {
	return c >= '0' && c <= '7'
}

is_binary_digit :: proc(c: byte) -> bool {
	return c == '0' || c == '1'
}

hex_digit_value :: proc(c: byte) -> int {
	if c >= '0' && c <= '9' {
		return int(c - '0')
	}
	if c >= 'a' && c <= 'f' {
		return int(c - 'a' + 10)
	}
	if c >= 'A' && c <= 'F' {
		return int(c - 'A' + 10)
	}
	return -1
}

is_id_start :: proc(c: byte) -> bool {
	// ASCII fast path
	if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$' {
		return true
	}
	// TODO: Unicode ID_Start
	return false
}

is_id_part :: proc(c: byte) -> bool {
	// ASCII fast path
	if is_id_start(c) || is_digit(c) {
		return true
	}
	// TODO: Unicode ID_Continue
	return false
}

// Check if we can parse a regex literal at current position
// This is context-sensitive - we only parse regex after certain tokens
can_parse_regex :: proc(l: ^Lexer) -> bool {
	// Simplified check - in real implementation, need to check previous token type
	// Regex can follow: (, [, {, ;, ,, =, :, return, throw, case, in, instanceof, etc.
	return true
}
