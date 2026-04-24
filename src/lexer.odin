package main


// ============================================================================
// Character Classification Utilities
// ============================================================================

CharClass :: enum u8 {
    Other      = 0,
    Whitespace = 1,
    IdStart    = 2,  // a-z, A-Z, _, $, non-ASCII
    Digit      = 4,
}

CHAR_CLASS_TABLE: [256]u8
char_table_initialized := false

@(init)
init_char_class_table :: proc "contextless" () {
    for i in 0..<256 {
        c := u8(i)
        if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f' {
            CHAR_CLASS_TABLE[i] = u8(CharClass.Whitespace)
        } else if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$' || c >= 0x80 {
            CHAR_CLASS_TABLE[i] = u8(CharClass.IdStart)
        } else if c >= '0' && c <= '9' {
            CHAR_CLASS_TABLE[i] = u8(CharClass.Digit)
        } else {
            CHAR_CLASS_TABLE[i] = u8(CharClass.Other)
        }
    }
    char_table_initialized = true
}

is_id_start_fast :: #force_inline proc(c: u8) -> bool {
    return CHAR_CLASS_TABLE[c] == u8(CharClass.IdStart)
}

is_id_cont_fast :: #force_inline proc(c: u8) -> bool {
    class := CHAR_CLASS_TABLE[c]
    return class == u8(CharClass.IdStart) || class == u8(CharClass.Digit)
}

// ============================================================================
// Lexer — optimized lexer with FastToken output and SIMD scanning
// ============================================================================

import "core:mem"

Lexer :: struct {
	// === HOT FIELDS (grouped for cache-line locality) ===
	source_bytes: []u8,              // 16B — read every token
	offset:     int,                  // 8B  — read/write every token
	had_line_terminator: bool,        // 1B  — write every token
	in_template: bool,                // 1B  (use template_brace_depth instead)
	last_token_type: TokenType,       // 1B  — write every token
	template_depth: u8,               // 1B  — number of active template interpolations
	_hot_pad: [4]u8,                  // 4B  — align to 32B boundary
	template_brace_stack: [8]u8,      // 8B  — brace depth per template nesting level (max 8 deep)
	cur:   FastToken,            // 16B — read/write every token (parser reads)
	nxt:   FastToken,            // 16B — read/write every token
	// --- 64 bytes so far: fits in 1 cache line ---

	// === WARM FIELDS (accessed frequently but not every token) ===
	source:     string,               // 16B
	last_lit_offset: u32,             // 4B  — write on literal tokens (reflects the LAST lex_token call — i.e. `nxt`)
	last_lit_value:  LiteralValue,    // 16B
	last_lit_type:   LiteralType,     // 1B
	// Parallel slot shadowing the literal data for the CURRENT token (`cur`).
	// advance_token copies last_lit_* → cur_lit_* BEFORE the next lex_token call
	// overwrites last_lit_*. Without this, a literal followed by another
	// cooking literal (e.g. string inside template `${...}`, number after
	// escape-cooked string) would drop the first literal's cooked value
	// on the floor and fall back to the raw source slice.
	cur_lit_offset:  u32,
	cur_lit_value:   LiteralValue,
	cur_lit_type:    LiteralType,

	// === COLD FIELDS (rarely accessed) ===
	line_offsets: []u32,
	num_lines:   u32,
	line:       int,
	column:     int,
	allocator:  mem.Allocator,
	template_stack: [dynamic]bool,
	jsx_context: bool,
	strict_mode: bool,
	at_start_of_file: bool,

	// Comment collection — populated during lexing
	comments: [dynamic]Comment,
	collect_comments: bool,

	// Hashbang comment — if the source starts with `#!...`, capture the
	// content and span. ES2023 elevated this to Program.hashbang in ESTree.
	// hashbang_value is the text AFTER `#!` up to (but not including) the
	// first LineTerminator; start/end is the full span including `#!`.
	hashbang_value: string,
	hashbang_start: u32,
	hashbang_end:   u32,
	has_hashbang:   bool,

	// bom_before_hashbang: true when the source opens with UTF-8 BOM
	// (`EF BB BF`) immediately followed by `#!`. OXC, Acorn, and Babel all
	// reject this: the hashbang production requires the `#!` to be the
	// very first bytes of the source, no BOM allowed. V8 accepts it, but
	// matching the conservative parsers is the stricter (and spec-blessed)
	// choice for us. The parser reads this flag at startup and emits an
	// `Invalid character '!'` error to mirror OXC's diagnostic.
	bom_before_hashbang: bool,

	// Diagnostics emitted by the lexer itself (invalid numeric literals,
	// malformed escapes, etc.). The parser drains this list after each
	// advance_token so the surfaced errors mix with parser-side errors
	// in order. Previously the lexer silently accepted `1_`, `1_.0`,
	// `1__0`, `1.0n`, `1e1n`, `0b2` and friends because there was no
	// channel to surface a syntax error at the lexer layer.
	lexer_errors:   [dynamic]LexerError,
}

// LexerError carries one diagnostic from the lexer. `offset` is the
// source byte where the bad construct starts; `message` is a short,
// spec-tied description that matches the existing parser-side error
// phrasing (so grepping tests for the diagnostic text stays consistent).
LexerError :: struct {
	offset:  u32,
	message: string,
}

// Build line offset table in a single pre-pass
build_line_table :: proc(l: ^Lexer) {
	src := l.source_bytes
	src_len := len(src)
	cap := max(src_len / 40 + 16, 256)
	lines := make([]u32, cap, l.allocator)
	lines[0] = 0
	count: u32 = 1
	for i := 0; i < src_len; i += 1 {
		if src[i] == '\n' {
			if int(count) >= len(lines) { break }
			lines[count] = u32(i + 1)
			count += 1
		}
	}
	l.line_offsets = lines[:count]
	l.num_lines = count
}

// Compute line/col from byte offset using binary search
offset_to_line_col :: proc(line_offsets: []u32, offset: u32) -> (line: u32, col: u32) {
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
	line_idx := lo - 1 if lo > 0 else 0
	return line_idx + 1, offset - line_offsets[line_idx] + 1
}

// Initialize lexer
init_lexer :: proc(l: ^Lexer, source: string, alloc: mem.Allocator) {
	l.source = source
	l.source_bytes = transmute([]u8)source
	l.offset = 0
	l.line = 1
	l.allocator = alloc
	l.jsx_context = false
	l.strict_mode = false
	l.last_token_type = .EOF
	l.at_start_of_file = true

	l.template_stack = make([dynamic]bool, 0, 0, alloc)
	l.comments = make([dynamic]Comment, 0, 64, alloc)
	l.collect_comments = true
	l.lexer_errors = make([dynamic]LexerError, 0, 4, alloc)

	// BOM handling: if the file opens with UTF-8 BOM (`EF BB BF`), skip it
	// before testing for the hashbang. Spec-wise this is a WhiteSpace
	// character and is valid at the file start. BUT the hashbang form is
	// *not* allowed after a BOM — hashbang must be the very first
	// non-skipped bytes of the source. Record the illegal combination so
	// the parser can surface a diagnostic matching OXC's
	// `Invalid character '!'` at position 2 (i.e. post-BOM, post-`#`).
	if l.at_start_of_file && l.offset + 2 < len(source) &&
	   l.source_bytes[l.offset] == 0xEF &&
	   l.source_bytes[l.offset + 1] == 0xBB &&
	   l.source_bytes[l.offset + 2] == 0xBF {
		l.offset += 3
		if l.offset + 1 < len(source) &&
		   l.source_bytes[l.offset] == '#' &&
		   l.source_bytes[l.offset + 1] == '!' {
			l.bom_before_hashbang = true
		}
	}

	// Handle hashbang. ES2023 makes `#!` at file start a HashbangComment
	// that lands on Program.hashbang. Capture content + span for the emitter.
	if l.at_start_of_file && !l.bom_before_hashbang &&
	   l.offset + 1 < len(source) && l.source_bytes[l.offset] == '#' && l.source_bytes[l.offset + 1] == '!' {
		hb_start := u32(l.offset)
		l.offset += 2 // skip `#!`
		content_start := l.offset
		content_end   := l.offset
		for l.offset < len(source) {
			c := l.source_bytes[l.offset]
			if c == '\n' || c == '\r' { break }
			l.offset += 1
			content_end = l.offset
		}
		l.hashbang_value = string(l.source_bytes[content_start:content_end])
		l.hashbang_start = hb_start
		l.hashbang_end   = u32(content_end)
		l.has_hashbang   = true
		// Consume the terminating line terminator so the rest of the lexer
		// doesn't see it as a leading newline.
		if l.offset < len(source) {
			c := l.source_bytes[l.offset]
			if c == '\r' {
				l.offset += 1
				if l.offset < len(source) && l.source_bytes[l.offset] == '\n' {
					l.offset += 1
				}
			} else if c == '\n' {
				l.offset += 1
			}
		}
	}
	l.at_start_of_file = false

	// Prime: fill cur + nxt
	l.cur.kind = .EOF
	l.cur = lex_token(l)
	// Capture cur's literal slot BEFORE lex_token is called for nxt — that
	// call may overwrite last_lit_* with nxt's cooked value (e.g. when nxt
	// is a number or another cooking literal). advance_token captures the
	// same way on every subsequent swap; priming has to do it manually
	// because there's no prior `cur = nxt` step. See comment on cur_lit_*
	// in the Lexer struct.
	l.cur_lit_offset = l.last_lit_offset
	l.cur_lit_value  = l.last_lit_value
	l.cur_lit_type   = l.last_lit_type
	if l.cur.kind != .EOF {
		l.nxt = lex_token(l)
	}
}

// ============================================================================
// Single-char token lookup table
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
	single_char_tokens['@'] = .At
}

// ============================================================================
// Fast token production — wraps lex_token
// ============================================================================

// Re-lex the current cur token as a regex literal.
// Called by the parser when it knows `/` should be regex.
relex_as_regex :: proc(l: ^Lexer) {
	if l.cur.kind != .Div && l.cur.kind != .AssignDiv { return }
	l.offset = int(l.cur.start)
	start := l.cur.start
	flags := l.cur.flags
	l.cur = lex_regex(l, start, flags)
	if l.cur.kind != .EOF {
		l.nxt = lex_token(l)
	} else {
		l.nxt = token_eof(u32(l.offset))
	}
}

// Get source text for a fast token
token_source :: #force_inline proc(l: ^Lexer, ft: FastToken) -> string {
	if ft.start >= ft.end { return "" }
	return l.source[ft.start:ft.end]
}

// Check if current position can start a regex literal based on previous token
can_start_regex :: proc(l: ^Lexer) -> bool {
	#partial switch l.cur.kind {
	case .EOF, .Semi, .Colon, .Comma, .LParen, .LBrace, .LBracket,
	     .Assign, .AssignAdd, .AssignSub, .AssignMul, .AssignDiv, .AssignMod,
	     .AssignPow, .AssignLShift, .AssignRShift, .AssignURShift, .AssignBitAnd,
	     .AssignBitOr, .AssignBitXor, .AssignNullish, .AssignLogicalAnd, .AssignLogicalOr,
	     .Return, .Case, .Throw, .New, .Delete, .Void, .Typeof,
	     .Plus, .Minus, .Mul, .Div, .Mod, .Pow, .BitNot, .BitAnd, .BitOr, .BitXor,
	     .LShift, .RShift, .URShift, .Not, .LogicalAnd, .LogicalOr, .Nullish,
	     .Eq, .NotEq, .EqStrict, .NotEqStrict, .LEq, .GEq,
	     .In, .Instanceof, .Of,
	     .Arrow, .Question, .Dot3,
	     .TemplateHead, .TemplateMiddle:
		return true
	// `++` / `--` deliberately NOT here: postfix `x++ / y` must treat `/`
	// as division, not regex. Prefix `++/re/` (legal but rare) would lose
	// out, but in practice JS code never writes `++/regex/` — the risk/reward
	// overwhelmingly favours classifying these as operators. Before the
	// Unterminated-regex error was wired in this mis‑lex silently fell
	// back to `.Div`; now it surfaces, breaking real files on `x++ / 10`.
	case:
		// .LAngle / .RAngle deliberately NOT in the can_start_regex set:
		// `<` followed by `/` almost always means a JSX closing tag or an
		// HTML-like comment pattern — never a regex start in practice.
		// OXC/Acorn/Babel all treat `/` after `<` as division (which parses
		// as a syntax error in JS but correctly as `</...>` in JSX). Keeping
		// them here broke deep-nested JSX (K5): `<Outer><Middle><Inner/>`
		// had the `/` of `</Middle>` lexed as a regex-start.
		return false
	}
}

// SIMD-accelerated comment skipping
skip_line_comment :: proc(l: ^Lexer) {
	comment_start := u32(l.offset)
	l.offset += 2
	content_start := l.offset
	end, had_nl := simd_skip_line_comment(l.source_bytes, l.offset)
	if had_nl { l.had_line_terminator = true }
	if l.collect_comments {
		// end points AT the \n (or EOF). Content is source[content_start:end].
		append(&l.comments, Comment{
			type  = .Line,
			start = comment_start,
			end   = u32(end),
			value = l.source[content_start:end],
		})
	}
	l.offset = end
}

skip_block_comment :: proc(l: ^Lexer) {
	comment_start := u32(l.offset)
	l.offset += 2
	content_start := l.offset
	end, had_nl := simd_skip_block_comment(l.source_bytes, l.offset)
	if had_nl { l.had_line_terminator = true }
	if l.collect_comments {
		// Content ends before the */ (end points past */)
		content_end := end - 2 if end >= 2 else end
		append(&l.comments, Comment{
			type  = .Block,
			start = comment_start,
			end   = u32(end),
			value = l.source[content_start:content_end],
		})
	}
	l.offset = end
}

// ============================================================================
// Lexer — main tokenization loop
// Produces FastToken by-value. Literals stored in LiteralStore.
// This is the hot path called by the parser's advance_token.
// ============================================================================

import "core:strconv"
import "core:simd"



// ============================================================================
// Main entry point — replaces the old lex_token that wrapped lex_next_compact
// ============================================================================

lex_token :: proc(l: ^Lexer) -> FastToken {
	// ---- Inline whitespace skip (register-local offset) ----
	// NOTE: had_line_terminator is NOT reset here (OXC pattern).
	// It was reset after flags capture in the previous call.
	src := l.source_bytes
	src_len := len(src)
	off := l.offset  // local copy for register residency

	// OXC-style branchless double-read: skip one space with arithmetic,
	// then check if we're at a token. Avoids branch for common single-space case.
	//
	// `ws_done` means "no further whitespace/comment skip is needed". We rule
	// out ASCII whitespace (< ' '), `/` (possible comment), and the UTF-8
	// lead bytes for spec whitespace/line-terminators: 0xC2 (U+00A0 NBSP),
	// 0xE2 (U+2028/U+2029 LS/PS), 0xEF (U+FEFF ZWNBSP). Missing any of those
	// leads lets a multi-byte whitespace char slide straight into the next
	// token — which silently corrupted `var a = 1\u2028var b = 2` into a
	// single identifier until the slow path was wired to handle them.
	ws_done := false
	if off + 1 < src_len {
		is_space := int(src[off] == ' ')
		off += is_space  // branchless advance 0 or 1
		c0 := src[off]
		ws_done = c0 > ' ' && c0 != '/' && c0 != 0xC2 && c0 != 0xE2 && c0 != 0xEF
	}
	if !ws_done {
		// Slow path: multi-space, newline, comment, or EOF
		for off < src_len {
			c := src[off]
			if c == ' ' || c == '\t' || c == '\r' {
				off += 1
			} else if c == '\n' {
				l.had_line_terminator = true
				off += 1
			} else if c == 0x0B || c == 0x0C {
				// <VT> (U+000B) and <FF> (U+000C) are ES `WhiteSpace` per §5.1.1.
				// They're not line terminators so no ASI is triggered.
				off += 1
			} else if c == 0xE2 && off + 2 < src_len && src[off+1] == 0x80 &&
			          (src[off+2] == 0xA8 || src[off+2] == 0xA9) {
				// U+2028 (LINE SEPARATOR, `LS`) and U+2029 (PARAGRAPH
				// SEPARATOR, `PS`) encoded as 3-byte UTF-8 `E2 80 A8/A9`.
				// Both are spec line terminators (§12.3) and MUST trigger
				// ASI just like `\n`. Previously the lexer fell through to
				// the `else { break }` below, letting these bytes slide into
				// the next token — on `var a = 1\u2028var b = 2\u2029var c`
				// the three declarations fused into one garbled
				// ExpressionStatement whose identifier started with `\u2028`.
				l.had_line_terminator = true
				off += 3
			} else if c == 0xC2 && off + 1 < src_len && src[off+1] == 0xA0 {
				// U+00A0 NO-BREAK SPACE (`NBSP`). 2-byte UTF-8 `C2 A0`.
				// WhiteSpace per §5.1.1 — not a line terminator.
				off += 2
			} else if c == 0xEF && off + 2 < src_len && src[off+1] == 0xBB && src[off+2] == 0xBF {
				// U+FEFF ZERO WIDTH NO-BREAK SPACE (ZWNBSP). 3-byte UTF-8
				// `EF BB BF` — spec WhiteSpace (also doubles as UTF-8 BOM
				// when at byte 0, handled separately in init). Not a line
				// terminator.
				off += 3
			} else if c == '/' && off + 1 < src_len {
				n := src[off + 1]
				if n == '/' {
					comment_start := off
					off += 2
					content_start := off
					end, had_nl := simd_skip_line_comment(src, off)
					if had_nl { l.had_line_terminator = true }
					if l.collect_comments {
						// end points AT the \n (or EOF). Content is src[content_start:end].
						content_end := end
						append(&l.comments, Comment{
							type  = .Line,
							start = u32(comment_start),
							end   = u32(end),
							value = l.source[content_start:content_end],
						})
					}
					off = end
				} else if n == '*' {
					comment_start := off
					off += 2
					content_start := off
					end, had_nl := simd_skip_block_comment(src, off)
					if had_nl { l.had_line_terminator = true }
					if l.collect_comments {
						content_end := end - 2 if end >= 2 else end
						append(&l.comments, Comment{
							type  = .Block,
							start = u32(comment_start),
							end   = u32(end),
							value = l.source[content_start:content_end],
						})
					}
					off = end
				} else { break }
			} else {
				break
			}
		}
	}
	l.offset = off  // write back

	if off >= src_len {
		return FastToken{start = u32(off), end = u32(off), kind = .EOF}
	}

	start := u32(off)
	flags: u8 = FLAG_NEW_LINE if l.had_line_terminator else 0
	l.had_line_terminator = false  // reset AFTER capture, not at start (saves 1 write when no newline)
	c := src[off]

	// ---- Single-char token via lookup table ----
	if c < 128 {
		tt := single_char_tokens[c]
		if tt != .Invalid {
			// When inside template interpolation, track brace depth
			if l.template_depth > 0 {
				idx := l.template_depth - 1
				if tt == .RBrace {
					if l.template_brace_stack[idx] == 0 {
						// Closes the interpolation → template resume
						return lex_template_resume(l, start, flags)
					}
					l.template_brace_stack[idx] -= 1
				} else if tt == .LBrace {
					l.template_brace_stack[idx] += 1
				}
			}
			l.offset += 1
			return FastToken{start = start, end = u32(l.offset), kind = tt, flags = flags}
		}
	}

	// ---- Identifier or keyword ----
	if is_id_start_fast(c) {
		return lex_identifier(l, start, flags)
	}

	// ---- Escaped identifier — \uXXXX or \u{H...H} at start.
	// ECMA-262 §12.7.2: identifier with any unicode escape is ALWAYS an
	// Identifier, never a reserved word. Cooked name published via last_lit_*.
	if c == '\\' && off + 1 < src_len && src[off + 1] == 'u' {
		return lex_identifier_escaped(l, start, flags)
	}

	// ---- Number ----
	if c >= '0' && c <= '9' {
		return lex_number(l, start, flags)
	}

	// ---- Operators and complex tokens ----
	switch c {
	case '"', '\'':
		return lex_string(l, start, flags, c)
	case '/':
		return lex_slash(l, start, flags)
	case '+':
		return lex_plus(l, start, flags)
	case '-':
		return lex_minus(l, start, flags)
	case '*':
		return lex_star(l, start, flags)
	case '=':
		return lex_equals(l, start, flags)
	case '!':
		return lex_bang(l, start, flags)
	case '<':
		return lex_less(l, start, flags)
	case '>':
		return lex_greater(l, start, flags)
	case '&':
		return lex_amp(l, start, flags)
	case '|':
		return lex_pipe(l, start, flags)
	case '.':
		return lex_dot(l, start, flags)
	case '?':
		return lex_question(l, start, flags)
	case '^':
		return lex_caret(l, start, flags)
	case '%':
		return lex_percent(l, start, flags)
	case '#':
		return lex_hash(l, start, flags)
	case '`':
		return lex_template_start(l, start, flags)
	case:
		l.offset += 1
		return FastToken{start = start, end = u32(l.offset), kind = .Invalid, flags = flags}
	}
}

// ============================================================================
// Identifier — tight scalar loop + per-letter keyword dispatch
// ============================================================================

lex_identifier :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	src := l.source_bytes
	src_len := len(src)
	off := l.offset + 1
	for off < src_len {
		c := src[off]
		if c == '\\' && off + 1 < src_len && src[off + 1] == 'u' {
			// Escape seen mid-identifier — fall back to the escape-aware slow
			// path, which re-scans from `start` and produces a cooked name.
			return lex_identifier_escaped(l, start, flags)
		}
		class := CHAR_CLASS_TABLE[c]
		if class != u8(CharClass.IdStart) && class != u8(CharClass.Digit) { break }
		off += 1
	}
	l.offset = off
	end := u32(off)
	tok_type := lookup_keyword_by_letter(src, start, end)
	return FastToken{start = start, end = end, kind = tok_type, flags = flags}
}

// ============================================================================
// Escaped identifier — slow path for \uXXXX / \u{H...H} in identifiers.
// ECMA-262 §12.7.2: the decoded codepoint must be IdentifierStart (first) or
// IdentifierPart (rest); an escaped identifier is NEVER a reserved word. The
// cooked (decoded) name is stored in last_lit_value; the parser reads it when
// FLAG_HAS_ESCAPE is set on the token.
// ============================================================================

// Decode one \uXXXX or \u{H...H} escape starting at `off` (which points at the
// backslash). Returns (codepoint, ok, bytes_consumed). On failure returns
// (0, false, 1) so callers can advance past the backslash and flag an error.
decode_u_escape :: proc(src: []u8, off: int) -> (cp: u32, ok: bool, consumed: int) {
	src_len := len(src)
	if off + 1 >= src_len || src[off] != '\\' || src[off + 1] != 'u' { return 0, false, 1 }
	if off + 2 < src_len && src[off + 2] == '{' {
		// \u{H...H} — at least 1 hex digit, terminated by `}`.
		p := off + 3
		acc: u32 = 0
		digits := 0
		for p < src_len && src[p] != '}' {
			h := hex_val(src[p])
			if h < 0 { return 0, false, 1 }
			acc = acc * 16 + u32(h)
			if acc > 0x10FFFF { return 0, false, 1 }
			digits += 1
			p += 1
		}
		if digits == 0 || p >= src_len || src[p] != '}' { return 0, false, 1 }
		return acc, true, (p + 1) - off
	}
	// \uHHHH — exactly 4 hex digits.
	if off + 5 >= src_len { return 0, false, 1 }
	h1 := hex_val(src[off + 2])
	h2 := hex_val(src[off + 3])
	h3 := hex_val(src[off + 4])
	h4 := hex_val(src[off + 5])
	if h1 < 0 || h2 < 0 || h3 < 0 || h4 < 0 { return 0, false, 1 }
	return u32(h1)*4096 + u32(h2)*256 + u32(h3)*16 + u32(h4), true, 6
}

// Codepoint-level IdentifierStart check. Simplified: ASCII delegated to
// CHAR_CLASS_TABLE; any non-ASCII codepoint ≥ 0x80 accepted — mirrors the
// raw-byte heuristic already used by is_id_start_fast, so behaviour is
// consistent between the escaped and unescaped paths. Spec-strict Unicode
// ID_Start classification is a follow-up.
is_id_start_codepoint :: #force_inline proc(cp: u32) -> bool {
	if cp < 128 {
		return CHAR_CLASS_TABLE[cp] == u8(CharClass.IdStart)
	}
	return cp <= 0x10FFFF
}

is_id_cont_codepoint :: #force_inline proc(cp: u32) -> bool {
	if cp < 128 {
		class := CHAR_CLASS_TABLE[cp]
		return class == u8(CharClass.IdStart) || class == u8(CharClass.Digit)
	}
	return cp <= 0x10FFFF
}

lex_identifier_escaped :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	src := l.source_bytes
	src_len := len(src)
	off := int(start)

	// Cooked (decoded) name buffer. Most identifiers are short; 32 B start
	// covers typical names without a realloc.
	cooked := make([dynamic]u8, 0, 32, l.allocator)

	first := true
	for off < src_len {
		c := src[off]
		if c == '\\' && off + 1 < src_len && src[off + 1] == 'u' {
			cp, ok, consumed := decode_u_escape(src, off)
			if !ok {
				// Invalid escape — produce Invalid token, advance past backslash.
				l.offset = off + 1
				return FastToken{start = start, end = u32(off + 1), kind = .Invalid, flags = flags}
			}
			if first {
				if !is_id_start_codepoint(cp) {
					l.offset = off + consumed
					return FastToken{start = start, end = u32(off + consumed), kind = .Invalid, flags = flags}
				}
			} else {
				if !is_id_cont_codepoint(cp) { break }
			}
			append_utf8(&cooked, cp)
			off += consumed
			first = false
		} else {
			if first {
				if !is_id_start_fast(c) {
					// No valid start at all (e.g. `\x` with no id start) — bail.
					l.offset = off + 1
					return FastToken{start = start, end = u32(off + 1), kind = .Invalid, flags = flags}
				}
				append(&cooked, c)
				off += 1
				first = false
			} else {
				if !is_id_cont_fast(c) { break }
				append(&cooked, c)
				off += 1
			}
		}
	}

	end := u32(off)
	l.offset = off
	l.last_lit_offset = start
	l.last_lit_value = LiteralValue(string(cooked[:]))
	l.last_lit_type = .Identifier
	// Always .Identifier — never a keyword (ECMA-262 §12.7.2). The
	// "escaped keyword used as Identifier" Syntax Error is enforced on
	// the parser side, because IdentifierName positions (property name,
	// property access, method name, import/export specifier name) do
	// permit escaped reserved words — only the narrower Identifier
	// production (`IdentifierName but not ReservedWord`) rejects them.
	return FastToken{start = start, end = end, kind = .Identifier, flags = flags | FLAG_HAS_ESCAPE}
}

// ============================================================================
// Number — scan digits, store literal in LiteralStore
// ============================================================================

lex_number :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	src := l.source_bytes
	src_len := len(src)

	// Handle hex, binary, octal prefixes
	if src[l.offset] == '0' && l.offset + 1 < src_len {
		next := src[l.offset + 1]
		switch next {
		case 'x', 'X':
			return lex_hex(l, start, flags)
		case 'b', 'B':
			return lex_binary(l, start, flags)
		case 'o', 'O':
			return lex_octal(l, start, flags)
		}
	}

	// Fast integer path: accumulate digits, detect if float/underscore.
	// Validate numeric separator placement inline per ECMA-262 §12.9.3:
	//   * No leading separator after the digit that opens the literal.
	//     (The outer lex_token dispatch guarantees `src[start]` is a digit,
	//     so a leading `_` would already have been lexed as an identifier.)
	//   * No two separators in a row (`1__0`).
	//   * No trailing separator at end of integer part (`1_`, `1_.0`).
	off := l.offset
	is_simple_int := true
	acc : u64 = 0
	prev_was_sep := false
	had_any_sep := false
	for off < src_len {
		ch := src[off]
		if ch >= '0' && ch <= '9' {
			acc = acc * 10 + u64(ch - '0')
			prev_was_sep = false
			off += 1
		} else if ch == '_' {
			is_simple_int = false
			had_any_sep = true
			if prev_was_sep {
				append(&l.lexer_errors, LexerError{offset = u32(off), message = "Numeric separator must be between two digits"})
			}
			prev_was_sep = true
			off += 1
		} else {
			break
		}
	}
	if had_any_sep && prev_was_sep {
		// Trailing `_` at end of integer part (`1_` or `1_.0`).
		append(&l.lexer_errors, LexerError{offset = u32(off - 1), message = "Numeric separator not allowed here"})
	}

	// Check for decimal point or exponent → not a simple integer
	had_dot := false
	had_exp := false
	if off < src_len && (src[off] == '.' || src[off] == 'e' || src[off] == 'E') {
		is_simple_int = false
		if src[off] == '.' {
			had_dot = true
			off += 1
			for off < src_len && (src[off] >= '0' && src[off] <= '9' || src[off] == '_') { off += 1 }
		}
		if off < src_len && (src[off] == 'e' || src[off] == 'E') {
			had_exp = true
			off += 1
			if off < src_len && (src[off] == '+' || src[off] == '-') { off += 1 }
			for off < src_len && (src[off] >= '0' && src[off] <= '9' || src[off] == '_') { off += 1 }
		}
	}
	l.offset = off

	end := u32(off)

	// BigInt suffix. Spec: `n` is only legal on integer literals — NOT
	// after a decimal point and NOT after an exponent. `1.0n` and `1e1n`
	// are SyntaxErrors.
	if off < src_len && src[off] == 'n' {
		if had_dot {
			append(&l.lexer_errors, LexerError{offset = u32(off), message = "BigInt literal cannot contain a decimal point"})
		}
		if had_exp {
			append(&l.lexer_errors, LexerError{offset = u32(off), message = "BigInt literal cannot contain an exponent"})
		}
		l.offset += 1
		end = u32(l.offset)
		return FastToken{start = start, end = end, kind = .BigInt, flags = flags}
	}

	// Fast path: simple integer (no dot, no exponent, no underscore, fits in u64)
	value: f64
	if is_simple_int && (end - start) <= 15 {
		value = f64(acc)
	} else {
		text := l.source[start:end]
		// Strip underscores before parsing (strconv.parse_f64 doesn't handle them)
		buf := make([dynamic]u8, 0, len(text), context.temp_allocator)
		for i := 0; i < len(text); i += 1 {
			if text[i] != '_' {
				append(&buf, text[i])
			}
		}
		text_no_underscores := string(buf[:])
		value, _ = strconv.parse_f64(text_no_underscores)
	}
	l.last_lit_offset = start; l.last_lit_value = LiteralValue(value); l.last_lit_type = .Number

	return FastToken{start = start, end = end, kind = .Number, flags = flags}
}

lex_hex :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	src := l.source_bytes
	src_len := len(src)
	l.offset += 2 // skip 0x
	for l.offset < src_len {
		c := src[l.offset]
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') || c == '_' {
			l.offset += 1
		} else { break }
	}
	end := u32(l.offset)
	if l.offset < src_len && src[l.offset] == 'n' {
		l.offset += 1
		end = u32(l.offset)
		return FastToken{start = start, end = end, kind = .BigInt, flags = flags}
	}

	// Compute f64 value from hex digits [start+2, end). Underscores are
	// separators and skipped. Parser reads last_lit_value for .Number tokens.
	acc: u64 = 0
	for i in int(start) + 2 ..< int(end) {
		c := src[i]
		if c == '_' { continue }
		d: u64
		switch {
		case c >= '0' && c <= '9': d = u64(c - '0')
		case c >= 'a' && c <= 'f': d = u64(c - 'a' + 10)
		case c >= 'A' && c <= 'F': d = u64(c - 'A' + 10)
		}
		acc = acc * 16 + d
	}
	l.last_lit_offset = start
	l.last_lit_value = LiteralValue(f64(acc))
	l.last_lit_type = .Number

	return FastToken{start = start, end = end, kind = .Number, flags = flags}
}

lex_binary :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	src := l.source_bytes
	src_len := len(src)
	l.offset += 2 // skip 0b
	digits_seen := 0
	for l.offset < src_len {
		c := src[l.offset]
		if c == '0' || c == '1' { l.offset += 1; digits_seen += 1 }
		else if c == '_' { l.offset += 1 }
		else { break }
	}
	// `0b2`, `0bz`, etc. — binary literal followed by a digit / letter
	// that isn't a valid binary digit but *is* a legal identifier-continue
	// character. Per §12.9.3 `0b<invalid>` is a SyntaxError; previously the
	// lexer just stopped at the bad character and let the parser see
	// `Number(0b)` followed by the trailing char as a separate token.
	if l.offset < src_len {
		c := src[l.offset]
		if (c >= '2' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') {
			if c != 'n' {
				append(&l.lexer_errors, LexerError{offset = u32(l.offset), message = "Invalid binary digit"})
			}
		}
	}
	if digits_seen == 0 {
		append(&l.lexer_errors, LexerError{offset = u32(l.offset), message = "Binary literal requires at least one digit"})
	}
	end := u32(l.offset)
	if l.offset < src_len && src[l.offset] == 'n' {
		l.offset += 1
		end = u32(l.offset)
		return FastToken{start = start, end = end, kind = .BigInt, flags = flags}
	}

	acc: u64 = 0
	for i in int(start) + 2 ..< int(end) {
		c := src[i]
		if c == '_' { continue }
		acc = acc * 2 + u64(c - '0')
	}
	l.last_lit_offset = start
	l.last_lit_value = LiteralValue(f64(acc))
	l.last_lit_type = .Number

	return FastToken{start = start, end = end, kind = .Number, flags = flags}
}

lex_octal :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	src := l.source_bytes
	src_len := len(src)
	l.offset += 2 // skip 0o
	digits_seen := 0
	for l.offset < src_len {
		c := src[l.offset]
		if c >= '0' && c <= '7' { l.offset += 1; digits_seen += 1 }
		else if c == '_' { l.offset += 1 }
		else { break }
	}
	// Same rejection rule as lex_binary: `0o8`, `0o9`, `0oz` etc. are
	// SyntaxErrors. The `n` suffix is legal and handled below.
	if l.offset < src_len {
		c := src[l.offset]
		if (c == '8' || c == '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') {
			if c != 'n' {
				append(&l.lexer_errors, LexerError{offset = u32(l.offset), message = "Invalid octal digit"})
			}
		}
	}
	if digits_seen == 0 {
		append(&l.lexer_errors, LexerError{offset = u32(l.offset), message = "Octal literal requires at least one digit"})
	}
	end := u32(l.offset)
	if l.offset < src_len && src[l.offset] == 'n' {
		l.offset += 1
		end = u32(l.offset)
		return FastToken{start = start, end = end, kind = .BigInt, flags = flags}
	}

	acc: u64 = 0
	for i in int(start) + 2 ..< int(end) {
		c := src[i]
		if c == '_' { continue }
		acc = acc * 8 + u64(c - '0')
	}
	l.last_lit_offset = start
	l.last_lit_value = LiteralValue(f64(acc))
	l.last_lit_type = .Number

	return FastToken{start = start, end = end, kind = .Number, flags = flags}
}

// ============================================================================
// String scanning — SIMD + scalar fallback
// ============================================================================

lex_string :: proc(l: ^Lexer, start: u32, flags: u8, quote: u8) -> FastToken {
	l.offset += 1 // skip opening quote

	// SIMD: find first quote or backslash
	remaining := l.source_bytes[l.offset:]
	pos, found_quote := simd_find_string_end(remaining, quote)

	if found_quote {
		// No escape — direct string, literal derived in parser from source[start+1:end-1].
		// Additional check: simd_find_string_end treats `\n` as a terminator
		// (which is correct for early-exit) — but if it HAS found a quote
		// we're fine. We still need to catch the case where EOF hit before
		// a closing quote, surfaced as !found_quote below.
		l.offset += pos + 1 // skip content + closing quote
		end := u32(l.offset)
		return FastToken{start = start, end = end, kind = .String, flags = flags}
	}

	// No closing quote before EOF or newline — try the scalar fallback first
	// (handles escape sequences cleanly) and let it emit a diagnostic if it
	// also hits EOF. For the pure fast‑path case where simd saw no escape
	// and no quote, that's an unterminated string no matter what the scalar
	// path finds; record it here so callers get a clear message.
	// lex_string_scalar will also emit one if its own scan runs off the end,
	// but catching it here gives the earliest offset.
	if len(remaining) == 0 || !found_quote {
		// Only flag if there's no `\\` in the span — if there is, the
		// scalar path will re‑scan and make the final call.
		has_escape := false
		for b in remaining {
			if b == '\\' { has_escape = true; break }
		}
		if !has_escape {
			append(&l.lexer_errors, LexerError{offset = start, message = "Unterminated string literal"})
			l.offset = len(l.source_bytes)
			return FastToken{start = start, end = u32(l.offset), kind = .String, flags = flags}
		}
	}

	// Scalar fallback for strings with escapes
	return lex_string_scalar(l, start, flags, quote)
}

// Helper: convert a codepoint to UTF-8 bytes and append to buffer
append_utf8 :: #force_inline proc(cook_buf: ^[dynamic]u8, cp: u32) {
	if cp < 0x80 {
		append(cook_buf, u8(cp))
	} else if cp < 0x800 {
		append(cook_buf, u8(0xC0 | (cp >> 6)))
		append(cook_buf, u8(0x80 | (cp & 0x3F)))
	} else if cp < 0x10000 {
		append(cook_buf, u8(0xE0 | (cp >> 12)))
		append(cook_buf, u8(0x80 | ((cp >> 6) & 0x3F)))
		append(cook_buf, u8(0x80 | (cp & 0x3F)))
	} else {
		append(cook_buf, u8(0xF0 | (cp >> 18)))
		append(cook_buf, u8(0x80 | ((cp >> 12) & 0x3F)))
		append(cook_buf, u8(0x80 | ((cp >> 6) & 0x3F)))
		append(cook_buf, u8(0x80 | (cp & 0x3F)))
	}
}

// Helper: get the value of a hex digit, or -1 if not hex
hex_val :: #force_inline proc(c: u8) -> i32 {
	switch {
	case c >= '0' && c <= '9': return i32(c - '0')
	case c >= 'a' && c <= 'f': return i32(c - 'a') + 10
	case c >= 'A' && c <= 'F': return i32(c - 'A') + 10
	case: return -1
	}
}

lex_string_scalar :: proc(l: ^Lexer, start: u32, flags: u8, quote: u8) -> FastToken {
	src := l.source_bytes
	src_len := len(src)

	// Cook buffer is allocated on the lexer's arena. No `defer delete` — the
	// slice exposed via `string(cook_buf[:])` on the return path is published
	// to `l.last_lit_value` and read by the parser AFTER this proc returns.
	// Bulk arena reset at the end of the parse owns the lifetime of the
	// backing memory; an individual delete here would dangle the published
	// string if the allocator ever stops no-op'ing frees.
	//
	cook_buf := make([dynamic]u8, l.allocator)

	for l.offset < src_len {
		// ====================================================================
		// SIMD hop: scan for the next `quote` or `\\` and bulk-copy the
		// intervening span into the cook buffer. Previously this function
		// byte-walked every character, so any string with a single escape
		// somewhere inside a multi-KB literal (slugify.js — one `\'` inside
		// a 6 KB JSON body) paid O(n) scalar scanning cost. 30× slower than
		// OXC on the affected files; now O(n/16) like the no-escape fast
		// path for the bulk of the content, scalar-only at the escapes.
		//
		// Unescaped `\n` inside a quoted string is technically an ECMA-262
		// error; we preserve Kessel's current lenient behaviour (append,
		// set had_line_terminator, continue) by scanning the span after the
		// bulk-copy — cheaper than having SIMD stop on `\n` because real-world
		// strings rarely contain literal newlines.
		remaining := src[l.offset:]
		pos, found_quote := simd_find_string_end(remaining, quote)
		if pos > 0 {
			span := src[l.offset : l.offset + pos]
			for b in span {
				if b == '\n' {
					l.had_line_terminator = true
					break
				}
			}
			append(&cook_buf, ..span)
			l.offset += pos
		}

		if l.offset >= src_len {
			break // unterminated — fall through to the end-of-proc path
		}

		c := src[l.offset]

		// Closing quote found
		if c == quote {
			l.offset += 1 // skip closing quote
			end := u32(l.offset)

			// Publish the cooked value
			l.last_lit_offset = start
			l.last_lit_value = LiteralValue(string(cook_buf[:]))
			l.last_lit_type = .String

			return FastToken{start = start, end = end, kind = .String, flags = flags}
		}

		// Escape sequence
		if c == '\\' && l.offset + 1 < src_len {
			next := src[l.offset + 1]

			switch next {
			// Single-char escapes
			case 'n':
				append(&cook_buf, u8(0x0A))
				l.offset += 2
			case 'r':
				append(&cook_buf, u8(0x0D))
				l.offset += 2
			case 't':
				append(&cook_buf, u8(0x09))
				l.offset += 2
			case 'b':
				append(&cook_buf, u8(0x08))
				l.offset += 2
			case 'f':
				append(&cook_buf, u8(0x0C))
				l.offset += 2
			case 'v':
				append(&cook_buf, u8(0x0B))
				l.offset += 2
			case '\'', '"', '\\', '/':
				append(&cook_buf, next)
				l.offset += 2
			case '0':
				// \0 only if not followed by a digit
				if l.offset + 2 < src_len && src[l.offset + 2] >= '0' && src[l.offset + 2] <= '9' {
					// Followed by digit; fallback to identity
					append(&cook_buf, next)
					l.offset += 2
				} else {
					append(&cook_buf, u8(0x00))
					l.offset += 2
				}
			case 'x':
				// \xHH — hex escape, exactly 2 hex digits per §12.9.4.2.
				escape_off := u32(l.offset)
				if l.offset + 3 < src_len {
					h1 := hex_val(src[l.offset + 2])
					h2 := hex_val(src[l.offset + 3])
					if h1 >= 0 && h2 >= 0 {
						cp := u32(h1 * 16 + h2)
						append_utf8(&cook_buf, cp)
						l.offset += 4
					} else {
						// Fewer than 2 hex digits, or non-hex next char.
						// Report and still consume `\x` so the rest of the
						// string lexes normally (error recovery).
						append(&l.lexer_errors, LexerError{offset = escape_off, message = "Invalid \\x escape: expected 2 hex digits"})
						append(&cook_buf, '\\')
						append(&cook_buf, next)
						l.offset += 2
					}
				} else {
					append(&l.lexer_errors, LexerError{offset = escape_off, message = "Invalid \\x escape: expected 2 hex digits"})
					append(&cook_buf, '\\')
					append(&cook_buf, next)
					l.offset += 2
				}
			case 'u', 'U':
				// \u escape: \uHHHH (exactly 4 hex digits) or \u{H...H}
				// (variable-length, code point <= 0x10FFFF).
				uesc_off := u32(l.offset)
				if l.offset + 2 < src_len && src[l.offset + 2] == '{' {
					// \u{H...H} — variable-length hex inside braces.
					l.offset += 3 // skip \u{
					cp: u32 = 0
					got_hex := false
					overflow := false
					for l.offset < src_len && src[l.offset] != '}' {
						hval := hex_val(src[l.offset])
						if hval < 0 { break }
						cp = cp * 16 + u32(hval)
						if cp > 0x10FFFF { overflow = true }
						got_hex = true
						l.offset += 1
					}
					if l.offset < src_len && src[l.offset] == '}' {
						l.offset += 1 // skip }
						if !got_hex {
							append(&l.lexer_errors, LexerError{offset = uesc_off, message = "Invalid \\u{} escape: empty code point"})
						} else if overflow {
							append(&l.lexer_errors, LexerError{offset = uesc_off, message = "Invalid \\u{} escape: code point out of range [0..0x10FFFF]"})
						} else {
							append_utf8(&cook_buf, cp)
						}
					} else {
						append(&l.lexer_errors, LexerError{offset = uesc_off, message = "Invalid \\u{} escape: missing closing '}'"})
					}
				} else if l.offset + 5 < src_len {
					// \uHHHH — exactly 4 hex digits.
					h1 := hex_val(src[l.offset + 2])
					h2 := hex_val(src[l.offset + 3])
					h3 := hex_val(src[l.offset + 4])
					h4 := hex_val(src[l.offset + 5])
					if h1 >= 0 && h2 >= 0 && h3 >= 0 && h4 >= 0 {
						cp := u32(h1*4096 + h2*256 + h3*16 + h4)
						append_utf8(&cook_buf, cp)
						l.offset += 6
					} else {
						append(&l.lexer_errors, LexerError{offset = uesc_off, message = "Invalid \\u escape: expected 4 hex digits"})
						append(&cook_buf, '\\')
						append(&cook_buf, next)
						l.offset += 2
					}
				} else {
					append(&l.lexer_errors, LexerError{offset = uesc_off, message = "Invalid \\u escape: expected 4 hex digits"})
					append(&cook_buf, '\\')
					append(&cook_buf, next)
					l.offset += 2
				}
			case '\n':
				// Line continuation: \<LF> produces nothing
				l.had_line_terminator = true
				l.offset += 2
			case '\r':
				// Line continuation: \<CR> or \<CR><LF> produces nothing
				l.had_line_terminator = true
				l.offset += 2
				if l.offset < src_len && src[l.offset] == '\n' {
					l.offset += 1
				}
			case:
				// Any other char after backslash: identity fallback
				append(&cook_buf, next)
				l.offset += 2
			}
		} else if c == '\n' {
			// Unescaped newline in string
			l.had_line_terminator = true
			append(&cook_buf, c)
			l.offset += 1
		} else {
			// Regular character
			append(&cook_buf, c)
			l.offset += 1
		}
	}

	// Unterminated string — do NOT publish cooked value
	end := u32(l.offset)
	return FastToken{start = start, end = end, kind = .Invalid, flags = flags}
}

// ============================================================================
// Operator handlers — each advances l.offset and returns FastToken directly
// ============================================================================

lex_plus :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		if next == '+' { l.offset += 2; return FastToken{start = start, end = u32(l.offset), kind = .PlusPlus, flags = flags} }
		if next == '=' { l.offset += 2; return FastToken{start = start, end = u32(l.offset), kind = .AssignAdd, flags = flags} }
	}
	l.offset += 1
	return FastToken{start = start, end = u32(l.offset), kind = .Plus, flags = flags}
}

lex_minus :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		if next == '-' { l.offset += 2; return FastToken{start = start, end = u32(l.offset), kind = .MinusMinus, flags = flags} }
		if next == '=' { l.offset += 2; return FastToken{start = start, end = u32(l.offset), kind = .AssignSub, flags = flags} }
	}
	l.offset += 1
	return FastToken{start = start, end = u32(l.offset), kind = .Minus, flags = flags}
}

lex_star :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		if next == '*' {
			if l.offset + 2 < len(l.source) && l.source_bytes[l.offset + 2] == '=' {
				l.offset += 3
				return FastToken{start = start, end = u32(l.offset), kind = .AssignPow, flags = flags}
			}
			l.offset += 2
			return FastToken{start = start, end = u32(l.offset), kind = .Pow, flags = flags}
		}
		if next == '=' { l.offset += 2; return FastToken{start = start, end = u32(l.offset), kind = .AssignMul, flags = flags} }
	}
	l.offset += 1
	return FastToken{start = start, end = u32(l.offset), kind = .Mul, flags = flags}
}

lex_equals :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		if next == '=' {
			if l.offset + 2 < len(l.source) && l.source_bytes[l.offset + 2] == '=' {
				l.offset += 3
				return FastToken{start = start, end = u32(l.offset), kind = .EqStrict, flags = flags}
			}
			l.offset += 2
			return FastToken{start = start, end = u32(l.offset), kind = .Eq, flags = flags}
		}
		if next == '>' { l.offset += 2; return FastToken{start = start, end = u32(l.offset), kind = .Arrow, flags = flags} }
	}
	l.offset += 1
	return FastToken{start = start, end = u32(l.offset), kind = .Assign, flags = flags}
}

lex_bang :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		if next == '=' {
			if l.offset + 2 < len(l.source) && l.source_bytes[l.offset + 2] == '=' {
				l.offset += 3
				return FastToken{start = start, end = u32(l.offset), kind = .NotEqStrict, flags = flags}
			}
			l.offset += 2
			return FastToken{start = start, end = u32(l.offset), kind = .NotEq, flags = flags}
		}
	}
	l.offset += 1
	return FastToken{start = start, end = u32(l.offset), kind = .Not, flags = flags}
}

lex_less :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		if next == '=' { l.offset += 2; return FastToken{start = start, end = u32(l.offset), kind = .LEq, flags = flags} }
		if next == '<' {
			if l.offset + 2 < len(l.source) && l.source_bytes[l.offset + 2] == '=' {
				l.offset += 3
				return FastToken{start = start, end = u32(l.offset), kind = .AssignLShift, flags = flags}
			}
			l.offset += 2
			return FastToken{start = start, end = u32(l.offset), kind = .LShift, flags = flags}
		}
	}
	l.offset += 1
	return FastToken{start = start, end = u32(l.offset), kind = .LAngle, flags = flags}
}

lex_greater :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		if next == '=' { l.offset += 2; return FastToken{start = start, end = u32(l.offset), kind = .GEq, flags = flags} }
		if next == '>' {
			if l.offset + 2 < len(l.source) {
				next2 := l.source_bytes[l.offset + 2]
				if next2 == '=' {
					l.offset += 3
					return FastToken{start = start, end = u32(l.offset), kind = .AssignRShift, flags = flags}
				}
				if next2 == '>' {
					if l.offset + 3 < len(l.source) && l.source_bytes[l.offset + 3] == '=' {
						l.offset += 4
						return FastToken{start = start, end = u32(l.offset), kind = .AssignURShift, flags = flags}
					}
					l.offset += 3
					return FastToken{start = start, end = u32(l.offset), kind = .URShift, flags = flags}
				}
			}
			l.offset += 2
			return FastToken{start = start, end = u32(l.offset), kind = .RShift, flags = flags}
		}
	}
	l.offset += 1
	return FastToken{start = start, end = u32(l.offset), kind = .RAngle, flags = flags}
}

lex_amp :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		if next == '&' {
			if l.offset + 2 < len(l.source) && l.source_bytes[l.offset + 2] == '=' {
				l.offset += 3
				return FastToken{start = start, end = u32(l.offset), kind = .AssignLogicalAnd, flags = flags}
			}
			l.offset += 2
			return FastToken{start = start, end = u32(l.offset), kind = .LogicalAnd, flags = flags}
		}
		if next == '=' { l.offset += 2; return FastToken{start = start, end = u32(l.offset), kind = .AssignBitAnd, flags = flags} }
	}
	l.offset += 1
	return FastToken{start = start, end = u32(l.offset), kind = .BitAnd, flags = flags}
}

lex_pipe :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		if next == '|' {
			if l.offset + 2 < len(l.source) && l.source_bytes[l.offset + 2] == '=' {
				l.offset += 3
				return FastToken{start = start, end = u32(l.offset), kind = .AssignLogicalOr, flags = flags}
			}
			l.offset += 2
			return FastToken{start = start, end = u32(l.offset), kind = .LogicalOr, flags = flags}
		}
		if next == '=' { l.offset += 2; return FastToken{start = start, end = u32(l.offset), kind = .AssignBitOr, flags = flags} }
	}
	l.offset += 1
	return FastToken{start = start, end = u32(l.offset), kind = .BitOr, flags = flags}
}

lex_dot :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		// .5, .123 etc — number starting with dot
		if next >= '0' && next <= '9' {
			return lex_dot_number(l, start, flags)
		}
		// ... spread
		if next == '.' && l.offset + 2 < len(l.source) && l.source_bytes[l.offset + 2] == '.' {
			l.offset += 3
			return FastToken{start = start, end = u32(l.offset), kind = .Dot3, flags = flags}
		}
	}
	l.offset += 1
	return FastToken{start = start, end = u32(l.offset), kind = .Dot, flags = flags}
}

lex_dot_number :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	src := l.source_bytes
	src_len := len(src)
	off := l.offset + 1 // skip the dot
	for off < src_len && src[off] >= '0' && src[off] <= '9' { off += 1 }
	// Exponent
	if off < src_len && (src[off] == 'e' || src[off] == 'E') {
		off += 1
		if off < src_len && (src[off] == '+' || src[off] == '-') { off += 1 }
		for off < src_len && src[off] >= '0' && src[off] <= '9' { off += 1 }
	}
	l.offset = off
	return FastToken{start = start, end = u32(off), kind = .Number, flags = flags}
}

lex_question :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		if next == '.' {
			// ?. is OptionalChain ONLY if not followed by a digit (otherwise it's ternary + .N number)
			if l.offset + 2 >= len(l.source) || !(l.source_bytes[l.offset + 2] >= '0' && l.source_bytes[l.offset + 2] <= '9') {
				l.offset += 2; return FastToken{start = start, end = u32(l.offset), kind = .OptionalChain, flags = flags}
			}
		}
		if next == '?' {
			if l.offset + 2 < len(l.source) && l.source_bytes[l.offset + 2] == '=' {
				l.offset += 3
				return FastToken{start = start, end = u32(l.offset), kind = .AssignNullish, flags = flags}
			}
			l.offset += 2
			return FastToken{start = start, end = u32(l.offset), kind = .Nullish, flags = flags}
		}
	}
	l.offset += 1
	return FastToken{start = start, end = u32(l.offset), kind = .Question, flags = flags}
}

lex_caret :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	if l.offset + 1 < len(l.source) && l.source_bytes[l.offset + 1] == '=' {
		l.offset += 2
		return FastToken{start = start, end = u32(l.offset), kind = .AssignBitXor, flags = flags}
	}
	l.offset += 1
	return FastToken{start = start, end = u32(l.offset), kind = .BitXor, flags = flags}
}

lex_percent :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	if l.offset + 1 < len(l.source) && l.source_bytes[l.offset + 1] == '=' {
		l.offset += 2
		return FastToken{start = start, end = u32(l.offset), kind = .AssignMod, flags = flags}
	}
	l.offset += 1
	return FastToken{start = start, end = u32(l.offset), kind = .Mod, flags = flags}
}

// ============================================================================
// Slash — division, regex, or comment (comments handled in whitespace skip)
// ============================================================================

lex_slash :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		// Comments should have been consumed in whitespace skip, but handle just in case
		if next == '/' {
			skip_line_comment(l)
			return lex_token(l) // recurse for next token
		}
		if next == '*' {
			skip_block_comment(l)
			return lex_token(l) // recurse for next token
		}
	}

	// Context-aware: regex or division/assign-div
	if can_start_regex(l) {
		return lex_regex(l, start, flags)
	}

	// Division or /=
	if l.offset + 1 < len(l.source) && l.source_bytes[l.offset + 1] == '=' {
		l.offset += 2
		return FastToken{start = start, end = u32(l.offset), kind = .AssignDiv, flags = flags}
	}

	l.offset += 1
	return FastToken{start = start, end = u32(l.offset), kind = .Div, flags = flags}
}

lex_regex :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	l.offset += 1 // skip opening /
	src := l.source_bytes
	src_len := len(src)

	// Scan pattern (handle character classes [...]  where / is literal)
	in_class := false
	for l.offset < src_len {
		c := src[l.offset]
		if c == '\\' && l.offset + 1 < src_len {
			l.offset += 2
		} else if c == '[' && !in_class {
			in_class = true
			l.offset += 1
		} else if c == ']' && in_class {
			in_class = false
			l.offset += 1
		} else if c == '/' && !in_class {
			break
		} else if c == '\n' || c == '\r' {
			break
		} else {
			l.offset += 1
		}
	}

	if l.offset >= src_len || src[l.offset] != '/' {
		// Unterminated regex — ran to EOF or a line terminator without
		// finding the closing `/`. Emit a diagnostic at the opening `/`
		// and return a RegularExpression token spanning the consumed
		// content so error recovery stays anchored. Previously this
		// silently fell back to `.Div`, which let `/abc;` at the end of
		// a file parse cleanly as `a/b/c;` — a spec violation observed on
		// the negative/007_unterminated_regex fixture.
		append(&l.lexer_errors, LexerError{offset = start, message = "Unterminated regular expression"})
		end := u32(l.offset)
		full_regex := l.source[start:end]
		l.last_lit_offset = start
		l.last_lit_value = LiteralValue(full_regex)
		l.last_lit_type = .Regex
		return FastToken{start = start, end = end, kind = .RegularExpression, flags = flags}
	}

	l.offset += 1 // skip closing /

	// Parse flags
	for l.offset < src_len {
		c := src[l.offset]
		if c >= 'a' && c <= 'z' { l.offset += 1 }
		else { break }
	}

	end := u32(l.offset)
	full_regex := l.source[start:end]
	l.last_lit_offset = start; l.last_lit_value = LiteralValue(full_regex); l.last_lit_type = .Regex
	return FastToken{start = start, end = end, kind = .RegularExpression, flags = flags}
}

// ============================================================================
// Hash — private identifier (#name)
// ============================================================================

lex_hash :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	l.offset += 1 // skip #
	src := l.source_bytes
	src_len := len(src)
	if l.offset < src_len && is_id_start_fast(src[l.offset]) {
		l.offset += 1
		for l.offset < src_len && is_id_cont_fast(src[l.offset]) {
			l.offset += 1
		}
	}
	end := u32(l.offset)
	return FastToken{start = start, end = end, kind = .PrivateIdentifier, flags = flags}
}

// ============================================================================
// Template literals
// ============================================================================

// Helper: cook template content (process escape sequences)
// process_template_escapes decodes ECMA-262 §12.9.6 TemplateCharacter
// escapes in a raw template body into the "cooked" value. Handles the full
// escape grammar:
//   \n \r \t \b \f \v           — simple char escapes
//   \\ \` \$ \' \"              — literal escapes
//   \0 (not followed by digit) — NUL
//   \xHH                        — hex escape
//   \uHHHH / \u{H...H}          — unicode escape
//   \<LineTerminator>           — line continuation, produces no output
//   \<other>                    — identity escape, drops backslash
process_template_escapes :: proc(raw: string, allocator: mem.Allocator) -> string {
	// Quick path: no backslashes = no escapes
	has_escape := false
	for ch in raw {
		if ch == '\\' {
			has_escape = true
			break
		}
	}
	if !has_escape {
		return raw
	}

	src := transmute([]u8)raw
	src_len := len(src)
	buf := make([dynamic]u8, 0, src_len, allocator)
	for i := 0; i < src_len; i += 1 {
		ch := src[i]
		if ch != '\\' || i + 1 >= src_len {
			append(&buf, ch)
			continue
		}
		next := src[i + 1]
		switch next {
		case 'n':  append(&buf, u8(0x0A)); i += 1
		case 'r':  append(&buf, u8(0x0D)); i += 1
		case 't':  append(&buf, u8(0x09)); i += 1
		case 'b':  append(&buf, u8(0x08)); i += 1
		case 'f':  append(&buf, u8(0x0C)); i += 1
		case 'v':  append(&buf, u8(0x0B)); i += 1
		case '\\', '`', '$', '\'', '"':
			append(&buf, next); i += 1
		case '0':
			// \0 is NUL only when not followed by a decimal digit (else it's
			// a legacy octal, disallowed in templates — keep literal).
			if i + 2 >= src_len || src[i + 2] < '0' || src[i + 2] > '9' {
				append(&buf, u8(0x00)); i += 1
			} else {
				append(&buf, ch) // drop to identity path below
			}
		case 'x':
			// \xHH — exactly 2 hex digits.
			if i + 3 < src_len {
				h1 := hex_val(src[i + 2])
				h2 := hex_val(src[i + 3])
				if h1 >= 0 && h2 >= 0 {
					append_utf8(&buf, u32(h1) * 16 + u32(h2))
					i += 3
					continue
				}
			}
			append(&buf, ch) // malformed — keep backslash literal
		case 'u':
			// \uHHHH or \u{H...H}. Reuse the shared decoder.
			cp, ok, consumed := decode_u_escape(src, i)
			if ok {
				append_utf8(&buf, cp)
				i += consumed - 1
			} else {
				append(&buf, ch)
			}
		case '\n':
			// Line continuation — skip the backslash and the newline, emit
			// nothing (ECMA-262 §12.9.4.1).
			i += 1
		case '\r':
			// \<CR> or \<CR><LF> line continuation.
			if i + 2 < src_len && src[i + 2] == '\n' {
				i += 2
			} else {
				i += 1
			}
		case:
			// Identity escape — drop the backslash, keep the char.
			append(&buf, next); i += 1
		}
	}
	return string(buf[:])
}

lex_template_start :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	src := l.source_bytes
	src_len := len(src)
	l.offset += 1 // skip opening backtick

	// Track interpolation state
	template_start_idx := len(l.template_stack)
	append(&l.template_stack, false)

	content_start := l.offset // byte after opening backtick

	// Inline SIMD vectors (created once, reused across loop iterations)
	tick_v: Vec16 = '`'; dollar_v: Vec16 = '$'; bs_v: Vec16 = '\\'; nl_v: Vec16 = '\n'

	for l.offset < src_len {
		// SIMD bulk skip: 16 bytes at a time, vectors already initialized
		for l.offset + 16 <= src_len {
			chunk := (transmute(^Vec16)&src[l.offset])^
			combined := transmute(Vec16)(
				transmute(simd.u8x16)simd.lanes_eq(chunk, tick_v) |
				transmute(simd.u8x16)simd.lanes_eq(chunk, dollar_v) |
				transmute(simd.u8x16)simd.lanes_eq(chunk, bs_v) |
				transmute(simd.u8x16)simd.lanes_eq(chunk, nl_v))
			mask := simd.extract_msbs(combined)
			if card(mask) > 0 {
				for lane in mask { l.offset += int(lane); break }
				break
			}
			l.offset += 16
		}
		if l.offset >= src_len { break }
		c := src[l.offset]
		if c != '`' && c != '$' && c != '\\' && c != '\n' {
			l.offset += 1
			continue
		}

		// Interpolation: ${  → TemplateHead
		if c == '$' && l.offset + 1 < src_len && src[l.offset + 1] == '{' {
			l.template_stack[template_start_idx] = true
			raw_content := l.source[content_start:l.offset]
			cooked := process_template_escapes(raw_content, l.allocator)
			content_end := u32(l.offset) // position before ${
			l.offset += 2 // consume ${  
			// Push template brace depth
			if l.template_depth < len(l.template_brace_stack) {
				l.template_brace_stack[l.template_depth] = 0
				l.template_depth += 1
			}
			// Store literal offset matching the token start position (after the backtick)
			l.last_lit_offset = u32(content_start); l.last_lit_value = LiteralValue(cooked); l.last_lit_type = .String
			// Token should span the template element content, not including the opening backtick or ${}
			return FastToken{start = u32(content_start), end = content_end, kind = .TemplateHead, flags = flags}
		}

		// Closing backtick → Template (no interpolation)
		if c == '`' {
			raw_content := l.source[content_start:l.offset]
			cooked := process_template_escapes(raw_content, l.allocator)
			content_end := u32(l.offset) // position before closing backtick
			l.offset += 1
			if template_start_idx < len(l.template_stack) {
				ordered_remove(&l.template_stack, template_start_idx)
			}
			// Store literal offset matching the token start position (after the backtick)
			l.last_lit_offset = u32(content_start); l.last_lit_value = LiteralValue(cooked); l.last_lit_type = .String
			// Token should span the template element content, not including the delimiters
			return FastToken{start = u32(content_start), end = content_end, kind = .Template, flags = flags}
		}

		if c == '\\' && l.offset + 1 < src_len {
			l.offset += 2
			continue
		}
		if c == '\n' {
			l.had_line_terminator = true
		}
		l.offset += 1
	}

	// Unterminated
	return FastToken{start = start, end = u32(l.offset), kind = .Invalid, flags = flags}
}

lex_template_resume :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	l.offset += 1 // skip }
	// Pop the brace depth for the interpolation we're leaving
	if l.template_depth > 0 {
		l.template_depth -= 1
	}
	src := l.source_bytes
	src_len := len(src)
	content_start := l.offset

	tick_v2: Vec16 = '`'; dollar_v2: Vec16 = '$'; bs_v2: Vec16 = '\\'; nl_v2: Vec16 = '\n'

	for l.offset < src_len {
		for l.offset + 16 <= src_len {
			chunk := (transmute(^Vec16)&src[l.offset])^
			combined := transmute(Vec16)(
				transmute(simd.u8x16)simd.lanes_eq(chunk, tick_v2) |
				transmute(simd.u8x16)simd.lanes_eq(chunk, dollar_v2) |
				transmute(simd.u8x16)simd.lanes_eq(chunk, bs_v2) |
				transmute(simd.u8x16)simd.lanes_eq(chunk, nl_v2))
			mask := simd.extract_msbs(combined)
			if card(mask) > 0 {
				for lane in mask { l.offset += int(lane); break }
				break
			}
			l.offset += 16
		}
		if l.offset >= src_len { break }
		c := src[l.offset]
		if c != '`' && c != '$' && c != '\\' && c != '\n' {
			l.offset += 1
			continue
		}

		// Next interpolation: ${ → TemplateMiddle
		if c == '$' && l.offset + 1 < src_len && src[l.offset + 1] == '{' {
			raw_content := l.source[content_start:l.offset]
			cooked := process_template_escapes(raw_content, l.allocator)
			content_end := u32(l.offset) // position before ${
			l.offset += 2
			// Push brace depth for new interpolation
			if l.template_depth < len(l.template_brace_stack) {
				l.template_brace_stack[l.template_depth] = 0
				l.template_depth += 1
			}
			// Store literal offset matching the token start position (after the closing brace)
			l.last_lit_offset = u32(content_start); l.last_lit_value = LiteralValue(cooked); l.last_lit_type = .String
			// Token should span the template element content, not including the closing brace or ${
			return FastToken{start = u32(content_start), end = content_end, kind = .TemplateMiddle, flags = flags}
		}

		// Closing backtick → TemplateTail
		if c == '`' {
			raw_content := l.source[content_start:l.offset]
			cooked := process_template_escapes(raw_content, l.allocator)
			content_end := u32(l.offset) // position before closing backtick
			l.offset += 1
			// Template is done — depth already popped at start of resume
			// Store literal offset matching the token start position (after the closing brace)
			l.last_lit_offset = u32(content_start); l.last_lit_value = LiteralValue(cooked); l.last_lit_type = .String
			// Token should span the template element content, not including the closing brace or backtick
			return FastToken{start = u32(content_start), end = content_end, kind = .TemplateTail, flags = flags}
		}

		if c == '\\' && l.offset + 1 < src_len {
			l.offset += 2
			continue
		}
		if c == '\n' {
			l.had_line_terminator = true
		}
		l.offset += 1
	}

	return FastToken{start = start, end = u32(l.offset), kind = .Invalid, flags = flags}
}

// ============================================================================
// Per-letter keyword dispatch (Optimization B)
// Eliminates FNV hash — dispatches by first character then length
// ============================================================================

lookup_keyword_by_letter :: proc(src: []u8, start: u32, end: u32) -> TokenType {
	length := end - start
	if length < 2 || length > 10 { return .Identifier }

	c0 := src[start]
	switch c0 {
	case 'a':
		if length == 2 && src[start+1] == 's' { return .As }
		if length == 6 && src[start+1] == 's' && src[start+2] == 's' && src[start+3] == 'e' && src[start+4] == 'r' && src[start+5] == 't' { return .Assert }
		if length == 7 && src[start+1] == 's' && src[start+2] == 's' && src[start+3] == 'e' &&
		   src[start+4] == 'r' && src[start+5] == 't' && src[start+6] == 's' { return .Asserts }
		if length == 5 {
			// async, await
			if src[start+1] == 's' && src[start+2] == 'y' && src[start+3] == 'n' && src[start+4] == 'c' { return .Async }
			if src[start+1] == 'w' && src[start+2] == 'a' && src[start+3] == 'i' && src[start+4] == 't' { return .Await }
		}
		if length == 8 && src[start+1] == 'b' && src[start+2] == 's' && src[start+3] == 't' &&
		   src[start+4] == 'r' && src[start+5] == 'a' && src[start+6] == 'c' && src[start+7] == 't' { return .Abstract }
		if length == 8 && src[start+1] == 'c' && src[start+2] == 'c' && src[start+3] == 'e' &&
		   src[start+4] == 's' && src[start+5] == 's' && src[start+6] == 'o' && src[start+7] == 'r' { return .Accessor }
	case 'b':
		if length == 5 && src[start+1] == 'r' && src[start+2] == 'e' && src[start+3] == 'a' && src[start+4] == 'k' { return .Break }
	case 'c':
		if length == 4 && src[start+1] == 'a' && src[start+2] == 's' && src[start+3] == 'e' { return .Case }
		if length == 5 {
			if src[start+1] == 'a' && src[start+2] == 't' && src[start+3] == 'c' && src[start+4] == 'h' { return .Catch }
			if src[start+1] == 'l' && src[start+2] == 'a' && src[start+3] == 's' && src[start+4] == 's' { return .Class }
			if src[start+1] == 'o' && src[start+2] == 'n' && src[start+3] == 's' && src[start+4] == 't' { return .Const }
		}
		if length == 8 && src[start+1] == 'o' && src[start+2] == 'n' && src[start+3] == 't' &&
		   src[start+4] == 'i' && src[start+5] == 'n' && src[start+6] == 'u' && src[start+7] == 'e' { return .Continue }
	case 'd':
		if length == 2 && src[start+1] == 'o' { return .Do }
		if length == 6 && src[start+1] == 'e' && src[start+2] == 'l' && src[start+3] == 'e' &&
		   src[start+4] == 't' && src[start+5] == 'e' { return .Delete }
		if length == 7 {
			if src[start+1] == 'e' {
				if src[start+2] == 'f' && src[start+3] == 'a' && src[start+4] == 'u' &&
				   src[start+5] == 'l' && src[start+6] == 't' { return .Default }
				if src[start+2] == 'b' && src[start+3] == 'u' && src[start+4] == 'g' &&
				   src[start+5] == 'g' && src[start+6] == 'e' { /* debugger is 8 */ }
			}
		}
		if length == 8 && src[start+1] == 'e' && src[start+2] == 'b' && src[start+3] == 'u' &&
		   src[start+4] == 'g' && src[start+5] == 'g' && src[start+6] == 'e' && src[start+7] == 'r' { return .Debugger }
	case 'e':
		if length == 4 {
			if src[start+1] == 'l' && src[start+2] == 's' && src[start+3] == 'e' { return .Else }
			// Note: 'enum' is a TS contextual keyword — lexed as Identifier,
			// checked by string value in the parser to allow `var enum = 1`.
		}
		if length == 6 && src[start+1] == 'x' {
			if src[start+2] == 'p' && src[start+3] == 'o' && src[start+4] == 'r' && src[start+5] == 't' { return .Export }
		}
		if length == 7 && src[start+1] == 'x' && src[start+2] == 't' && src[start+3] == 'e' &&
		   src[start+4] == 'n' && src[start+5] == 'd' && src[start+6] == 's' { return .Extends }
	case 'f':
		if length == 3 && src[start+1] == 'o' && src[start+2] == 'r' { return .For }
		if length == 4 && src[start+1] == 'r' && src[start+2] == 'o' && src[start+3] == 'm' { return .From }
		if length == 5 && src[start+1] == 'a' && src[start+2] == 'l' && src[start+3] == 's' && src[start+4] == 'e' { return .False }
		if length == 7 && src[start+1] == 'i' && src[start+2] == 'n' && src[start+3] == 'a' &&
		   src[start+4] == 'l' && src[start+5] == 'l' && src[start+6] == 'y' { return .Finally }
		if length == 8 && src[start+1] == 'u' && src[start+2] == 'n' && src[start+3] == 'c' &&
		   src[start+4] == 't' && src[start+5] == 'i' && src[start+6] == 'o' && src[start+7] == 'n' { return .Function }
	case 'g':
		if length == 3 && src[start+1] == 'e' && src[start+2] == 't' { return .Get }
	case 'i':
		if length == 2 {
			if src[start+1] == 'f' { return .If }
			if src[start+1] == 'n' { return .In }
			if src[start+1] == 's' { return .Is }
		}
		if length == 5 && src[start+1] == 'n' && src[start+2] == 'f' && src[start+3] == 'e' && src[start+4] == 'r' { return .Infer }
		if length == 6 && src[start+1] == 'm' && src[start+2] == 'p' && src[start+3] == 'o' &&
		   src[start+4] == 'r' && src[start+5] == 't' { return .Import }
// Note: 'interface' is a TS contextual keyword — lexed as Identifier,
		// checked by string value in the parser to allow `var interface = 1`.
		if length == 10 && src[start+1] == 'n' && src[start+2] == 's' && src[start+3] == 't' &&
		   src[start+4] == 'a' && src[start+5] == 'n' && src[start+6] == 'c' && src[start+7] == 'e' &&
		   src[start+8] == 'o' && src[start+9] == 'f' { return .Instanceof }
	case 'l':
		if length == 3 && src[start+1] == 'e' && src[start+2] == 't' { return .Let }
	case 'k':
		if length == 5 && src[start+1] == 'e' && src[start+2] == 'y' && src[start+3] == 'o' && src[start+4] == 'f' { return .Keyof }
	case 'n':
		if length == 3 && src[start+1] == 'e' && src[start+2] == 'w' { return .New }
		if length == 4 && src[start+1] == 'u' && src[start+2] == 'l' && src[start+3] == 'l' { return .Null }
		if length == 5 && src[start+1] == 'e' && src[start+2] == 'v' && src[start+3] == 'e' && src[start+4] == 'r' { return .Never }
	case 'o':
		if length == 2 && src[start+1] == 'f' { return .Of }
		if length == 8 && src[start+1] == 'v' && src[start+2] == 'e' && src[start+3] == 'r' &&
		   src[start+4] == 'r' && src[start+5] == 'i' && src[start+6] == 'd' && src[start+7] == 'e' { return .Override }
	case 'r':
		if length == 6 && src[start+1] == 'e' && src[start+2] == 't' && src[start+3] == 'u' &&
		   src[start+4] == 'r' && src[start+5] == 'n' { return .Return }
	case 's':
		if length == 3 && src[start+1] == 'e' && src[start+2] == 't' { return .Set }
		if length == 5 && src[start+1] == 'u' && src[start+2] == 'p' && src[start+3] == 'e' && src[start+4] == 'r' { return .Super }
		if length == 6 {
			if src[start+1] == 'w' && src[start+2] == 'i' && src[start+3] == 't' &&
			   src[start+4] == 'c' && src[start+5] == 'h' { return .Switch }
			if src[start+1] == 't' && src[start+2] == 'a' && src[start+3] == 't' &&
			   src[start+4] == 'i' && src[start+5] == 'c' { return .Static }
		}
		if length == 9 && src[start+1] == 'a' && src[start+2] == 't' && src[start+3] == 'i' &&
		   src[start+4] == 's' && src[start+5] == 'f' && src[start+6] == 'i' && src[start+7] == 'e' && src[start+8] == 's' { return .Satisfies }
	case 't':
		if length == 3 && src[start+1] == 'r' && src[start+2] == 'y' { return .Try }
		if length == 4 {
			if src[start+1] == 'h' && src[start+2] == 'i' && src[start+3] == 's' { return .This }
			if src[start+1] == 'r' && src[start+2] == 'u' && src[start+3] == 'e' { return .True }
			// Note: 'type' is a TS contextual keyword — lexed as Identifier,
			// checked by string value in the parser to allow `var type = 1`.
		}
		if length == 5 && src[start+1] == 'h' && src[start+2] == 'r' && src[start+3] == 'o' && src[start+4] == 'w' { return .Throw }
		if length == 6 && src[start+1] == 'y' && src[start+2] == 'p' && src[start+3] == 'e' &&
		   src[start+4] == 'o' && src[start+5] == 'f' { return .Typeof }
	case 'u':
		if length == 5 && src[start+1] == 's' && src[start+2] == 'i' && src[start+3] == 'n' && src[start+4] == 'g' { return .Using }
		if length == 6 && src[start+1] == 'n' && src[start+2] == 'i' && src[start+3] == 'q' &&
		   src[start+4] == 'u' && src[start+5] == 'e' { return .Unique }
	case 'v':
		if length == 3 && src[start+1] == 'a' && src[start+2] == 'r' { return .Var }
		if length == 4 && src[start+1] == 'o' && src[start+2] == 'i' && src[start+3] == 'd' { return .Void }
	case 'w':
		if length == 4 && src[start+1] == 'i' && src[start+2] == 't' && src[start+3] == 'h' { return .With }
		if length == 5 && src[start+1] == 'h' && src[start+2] == 'i' && src[start+3] == 'l' && src[start+4] == 'e' { return .While }
	case 'y':
		if length == 5 && src[start+1] == 'i' && src[start+2] == 'e' && src[start+3] == 'l' && src[start+4] == 'd' { return .Yield }
	}
	return .Identifier
}
