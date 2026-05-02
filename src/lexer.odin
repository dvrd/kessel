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

// FAST_TOKEN_START_TABLE[c] is `true` when byte `c` is a guaranteed
// fast-path token start — i.e. NOT one of:
//
//   * ASCII whitespace / control (c <= 0x20)  — needs WS-skip slow path
//   * `/`                                       — may begin `//` or `/*` comment
//   * 0xC2, 0xE1, 0xE2, 0xE3, 0xEF              — lead bytes of multi-byte
//                                                 spec WhiteSpace / LineTerm
//                                                 (NBSP, OGHAM, Zs/LT block,
//                                                 IDEOGRAPHIC SP, ZWNBSP)
//
// `lex_token`'s prologue used to evaluate this predicate as a chain of seven
// compares against c0; each token paid 5–7 dependent ALU ops. The table
// flattens the same logic to a single byte load, which the next step
// (single_char_tokens / is_id_start_fast) re-uses from the same cache line.
FAST_TOKEN_START_TABLE: [256]bool

@(init)
init_fast_token_start_table :: proc "contextless" () {
    for i in 0..<256 {
        c := u8(i)
        slow := c <= ' ' || c == '/' ||
                c == 0xC2 || c == 0xE1 || c == 0xE2 || c == 0xE3 || c == 0xEF
        FAST_TOKEN_START_TABLE[i] = !slow
    }
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
	last_token_type: TokenType,       // 1B  — write every token
	template_depth: u8,               // 1B  — number of active template interpolations
	// (Reserved.) Was previously populated by an unused full-source SIMD
	// scan in init_lexer; the identifier-scan tracks `has_non_ascii` per-
	// token directly inside SIMD so the field is never read on the hot
	// path. Removed to eliminate a 9 MB per-parse scan that didn't help.
	_unused_lexer_pad: bool,          // 1B  — layout placeholder
	// `is_module_mode` gates Annex B HTML-like comments (`<!--` and `-->`).
	// These are valid only in script source per ECMA-262 §B.1.3; in module
	// code the same byte sequences are SyntaxErrors. Set by the parser
	// (or by an explicit `init_lexer_with_source_type`) before the first
	// token is fetched.
	is_module_mode: bool,             // 1B  — set once at init
	_hot_pad: [2]u8,                  // 2B  — align to 32B boundary
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
	strict_mode: bool,
	at_start_of_file: bool,

	// JSX attribute string mode: when true, lex_string allows raw newlines
	// inside quoted strings (JSX §2.2: attribute values are NOT JS strings;
	// they can span multiple lines). Set by the parser before scanning tokens
	// in JSX attribute position, cleared after.
	jsx_string_mode: bool,

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

// Initialize lexer. `source_type` gates Annex B HTML-like comments
// (`<!--` and `-->`): they are valid only in script source per
// ECMA-262 §B.1.3, so module-mode lexing skips the recogniser. Pass
// `.Script` if you don't care — the recogniser is harmless for source
// that doesn't actually contain those byte sequences.
init_lexer :: proc(l: ^Lexer, source: string, alloc: mem.Allocator, source_type: SourceType = .Script) {
	l.source = source
	l.source_bytes = transmute([]u8)source
	l.offset = 0
	l.line = 1
	l.allocator = alloc
	l.strict_mode = false
	l.last_token_type = .EOF
	l.at_start_of_file = true
	l.is_module_mode = source_type == .Module
	// Note: the previous `source_has_multibyte = simd_has_multibyte(...)`
	// here scanned the full source on every parse and was never read on
	// the hot path — the identifier-scan tracks per-token has_non_ascii
	// directly inside SIMD. The byte-to-UTF16 offset table built in
	// build_utf16_table during AST emission performs its own SIMD scan
	// (when emission is actually requested). Removed: was ~9 MB per
	// parse on bench/real_world/typescript.js for no benefit.

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
			// Spec rejects BOM-before-hashbang — record one diagnostic
			// and skip the entire offending line. Without the skip the
			// `#!...` body lexes as a sequence of regular tokens (private
			// identifier, `!`, the program body, etc.) producing a 5-6 error
			// cascade. OXC matches this stop-after-one behaviour.
			bump_append(&l.lexer_errors, LexerError{offset = u32(l.offset + 1), message = "Invalid character `!`"})
			// Skip past the hashbang line.
			for l.offset < len(source) {
				c := l.source_bytes[l.offset]
				if c == '\n' || c == '\r' { break }
				if c == 0xE2 && l.offset + 2 < len(source) &&
				   l.source_bytes[l.offset+1] == 0x80 &&
				   (l.source_bytes[l.offset+2] == 0xA8 || l.source_bytes[l.offset+2] == 0xA9) {
					break
				}
				l.offset += 1
			}
			// Consume the terminator so the rest of the lexer doesn't see
			// a leading newline.
			if l.offset < len(source) {
				c := l.source_bytes[l.offset]
				if c == '\r' {
					l.offset += 1
					if l.offset < len(source) && l.source_bytes[l.offset] == '\n' { l.offset += 1 }
				} else if c == '\n' {
					l.offset += 1
				} else if c == 0xE2 && l.offset + 2 < len(source) &&
				          l.source_bytes[l.offset+1] == 0x80 &&
				          (l.source_bytes[l.offset+2] == 0xA8 || l.source_bytes[l.offset+2] == 0xA9) {
					l.offset += 3
				}
			}
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
			// U+2028 (LINE SEPARATOR) and U+2029 (PARAGRAPH SEPARATOR) are
			// spec line terminators and terminate the hashbang comment.
			if c == 0xE2 && l.offset + 2 < len(source) &&
			   l.source_bytes[l.offset+1] == 0x80 &&
			   (l.source_bytes[l.offset+2] == 0xA8 || l.source_bytes[l.offset+2] == 0xA9) {
				break
			}
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
			} else if c == 0xE2 && l.offset + 2 < len(source) &&
			          l.source_bytes[l.offset+1] == 0x80 &&
			          (l.source_bytes[l.offset+2] == 0xA8 || l.source_bytes[l.offset+2] == 0xA9) {
				l.offset += 3 // consume U+2028/U+2029
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

// 256 entries (not 128) so the high half is always populated with .Invalid.
// This lets `lex_token` index by the raw lead byte without a `c < 128` guard
// — non-ASCII bytes simply read .Invalid and fall through to the identifier /
// escape / number / operator dispatch chain. Saves one branch per token on
// the hot path. The 128-byte memory cost is irrelevant.
single_char_tokens: [256]TokenType

@(init)
init_single_char_table :: proc "contextless" () {
	for i in 0..<256 { single_char_tokens[i] = .Invalid }
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

// Split the leading `>` off a multi-`>` operator token so a TS type-
// argument-list parser can consume it as a closing angle bracket. Used
// when expecting `>` (RAngle) to close a TSTypeParameterInstantiation /
// TSTypeParameterDeclaration / TSGenericArrow:
//
//   Foo<Bar<Baz>>      — lexer emits `>>`; we consume one as RAngle,
//                       leaving `>` for the outer type's closer.
//   Foo<Bar<Baz>>=...  — unlikely, but `>>=` would split `>` + `>=`.
//   Foo<Bar<Baz<Q>>>>  — nested 4 deep — each level peels one `>`.
//   Foo<{x: T}>=v      — `>=` splits to `>` + `=`.
//
// Mechanism: rewind l.offset to (cur.start + 1) and re-lex from there.
// The new cur becomes RAngle (the consumed `>`), and the new nxt picks
// up where the old multi-char operator continues. Caller still needs to
// consume the resulting RAngle via skip_token / advance_token; this
// helper just normalises the token stream.
//
// Returns true iff a split happened. False for tokens that are already
// a single `>` or that aren't `>`-starting at all.
try_split_close_angle :: proc(l: ^Lexer) -> bool {
	#partial switch l.cur.kind {
	case .RAngle:
		return false  // already a single `>`; caller consumes normally
	case .RShift, .URShift, .GEq, .AssignRShift, .AssignURShift:
		// All of these start with `>` at l.cur.start. Rewind one byte
		// past it and re-lex. The first `>` is now an RAngle; the rest
		// of the original operator becomes the next token.
		start := l.cur.start
		l.offset = int(start) + 1
		l.cur = FastToken{
			kind  = .RAngle,
			start = start,
			end   = start + 1,
			flags = 0,
		}
		l.nxt = lex_token(l)
		return true
	case:
		return false
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
	     // `.In` / `.Instanceof` are reserved words — always operators here.
	     // `.Of` is intentionally NOT in this set: it's a contextual keyword
	     // that may also be used as an IdentifierReference (`var of = 6;
	     // of/g/h;`), and its presence here mis-lexed the next `/` as a
	     // regex-start. The genuine for-of head case (`for (x of /re/)`)
	     // is handled by the parser via relex_as_regex when it commits to
	     // parsing the iterator expression. Test262: language/expressions/
	     // division/no-magic-asi.js.
	     .In, .Instanceof,
	     // `.Yield` is intentionally NOT here (same reason as `.Of` above):
	     // bare `yield` may be an IdentifierReference in non-generator code
	     // (`var yield = 12; yield/a/g;` — staging/sm/generators/yield-non-
	     // regexp.js). The genuine `yield <regex>` case in a generator is
	     // re-lexed at parse time via parse_yield_expr.
	     .Await,
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
		bump_append(&l.comments, Comment{
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
	// §12.4 — A block comment that reaches EOF without a closing `*/` is a
	// SyntaxError. simd_skip_block_comment returns `src_len` either way
	// (terminated `*/` at end-of-file vs ran-off-the-end without finding
	// one); distinguish by checking the trailing two bytes. Test:
	// CRLF-and-LF files where the final two bytes are exactly `*/` with
	// no trailing newline (typescript/compiler/baseIndexSignatureResolution.ts
	// and ~9 sibling fixtures).
	terminated := end >= 2 && l.source_bytes[end-2] == '*' && l.source_bytes[end-1] == '/'
	if !terminated {
		bump_append(&l.lexer_errors, LexerError{
			offset  = comment_start,
			message = "Unterminated block comment",
		})
	}
	if l.collect_comments {
		// Content ends before the */ (end points past */)
		content_end := end - 2 if end >= 2 else end
		bump_append(&l.comments, Comment{
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
	// lead bytes for every spec whitespace / line-terminator we recognise:
	//   * 0xC2 — U+00A0 NBSP
	//   * 0xE1 — U+1680 OGHAM SPACE MARK
	//   * 0xE2 — U+2000…U+200A Zs / U+2028–2029 LT / U+202F NNBSP / U+205F MMSP
	//   * 0xE3 — U+3000 IDEOGRAPHIC SPACE
	//   * 0xEF — U+FEFF ZWNBSP / BOM
	// Missing any of those leads lets a multi-byte whitespace char slide
	// straight into the next token — e.g. `var a = 1\u2028var b = 2` would
	// fuse into one mangled identifier without the slow-path dispatch.
	ws_done := false
	c0: u8 = 0
	if off + 1 < src_len {
		is_space := int(src[off] == ' ')
		off += is_space  // branchless advance 0 or 1
		c0 = src[off]
		// One byte load + one truthy test, replacing a 7-compare chain.
		ws_done = FAST_TOKEN_START_TABLE[c0]
	}
	// Annex B §B.1.3 HTML-like comments must reach the slow path so the
	// comment scanner consumes them; otherwise the fast path would fall
	// through to the `-` / `<` token dispatch and the parser would see
	// the raw bytes. The expensive byte-pattern check (`<!--` / `-->`)
	// is gated three ways, in cheapest-first order:
	//
	//   1. !is_module_mode  — Annex B doesn't apply in module code.
	//   2. c0 in {`<`, `-`}  — only these bytes can begin one of the two
	//      Annex B comment forms. The space-skip above never produces
	//      `<` or `-` from `' '`, so c0 is the correct byte to test even
	//      when is_space==1 (in that case is_space==0 by definition).
	//   3. Full byte-pattern check — only reached for ~0 % of script
	//      tokens. Module-mode parses pay zero cost from this block.
	if !l.is_module_mode && (c0 == '<' || c0 == '-') {
		if c0 == '<' && off + 3 < src_len &&
		   src[off+1] == '!' && src[off+2] == '-' && src[off+3] == '-' {
			ws_done = false  // SingleLineHTMLOpenComment
		} else if c0 == '-' && (off == 0 || l.had_line_terminator) &&
		          off + 2 < src_len && src[off+1] == '-' && src[off+2] == '>' {
			ws_done = false  // SingleLineHTMLCloseComment
		}
	}
	if !ws_done {
		// Slow path: multi-space, newline, comment, or EOF.
		//
		// `at_logical_line_start` is true at file-start (BEFORE any leading
		// whitespace, hence `l.offset == 0` not `off == 0`) and after every
		// LineTerminator or multi-line block comment consumed inside the
		// loop. It gates Annex B `-->` SingleLineHTMLCloseComment.
		at_logical_line_start := l.offset == 0 || l.had_line_terminator
		for off < src_len {
			c := src[off]
			if c == ' ' || c == '\t' {
				// SIMD-skip the entire space/tab run in one shot. After a
				// newline this collapses indent runs (typical 8–32 bytes
				// in TS) from N scalar iterations to one 16-byte SIMD probe.
				off = simd_skip_ascii_ws_run(src, off + 1)
			} else if c == '\n' {
				l.had_line_terminator = true
				at_logical_line_start = true
				off += 1
			} else if c == '\r' {
				// ECMA-262 §12.3 - <CR> (U+000D) is a LineTerminator,
				// not whitespace. CR + LF is a single LineTerminator-
				// Sequence; consume the LF together so we don't fire two
				// ASI / new-line events for one logical line break.
				l.had_line_terminator = true
				at_logical_line_start = true
				off += 1
				if off < src_len && src[off] == '\n' { off += 1 }
			} else if c == 0x0B || c == 0x0C {
				// <VT> (U+000B) and <FF> (U+000C) are ES `WhiteSpace` per §5.1.1.
				// They're not line terminators so no ASI is triggered.
				off += 1
			} else if c == 0xE2 && off + 2 < src_len && src[off+1] == 0x80 {
				b2 := src[off + 2]
				if b2 == 0xA8 || b2 == 0xA9 {
					// U+2028 LINE SEPARATOR / U+2029 PARAGRAPH SEPARATOR.
					// Both are LineTerminators (§12.3); fire ASI like `\n`.
					l.had_line_terminator = true
					at_logical_line_start = true
					off += 3
				} else if b2 >= 0x80 && b2 <= 0x8A {
					// U+2000…U+200A — Zs Space_Separator (EN/EM quads,
					// figure / punctuation / hair / thin space, …). Test262
					// language/white-space/after-regular-expression-literal-*.
					off += 3
				} else if b2 == 0xAF {
					// U+202F NARROW NO-BREAK SPACE — Zs.
					off += 3
				} else {
					break  // not whitespace; let lexer dispatch handle it.
				}
			} else if c == 0xE2 && off + 2 < src_len && src[off+1] == 0x81 && src[off+2] == 0x9F {
				// U+205F MEDIUM MATHEMATICAL SPACE — Zs.
				off += 3
			} else if c == 0xE1 && off + 2 < src_len && src[off+1] == 0x9A && src[off+2] == 0x80 {
				// U+1680 OGHAM SPACE MARK — Zs.
				off += 3
			} else if c == 0xE3 && off + 2 < src_len && src[off+1] == 0x80 && src[off+2] == 0x80 {
				// U+3000 IDEOGRAPHIC SPACE — Zs.
				off += 3
			} else if c == 0xC2 && off + 1 < src_len && src[off+1] == 0xA0 {
				// U+00A0 NO-BREAK SPACE (`NBSP`). 2-byte UTF-8 `C2 A0`.
				// WhiteSpace per §5.1.1 — not a line terminator.
				off += 2
			} else if c == 0xEF && off + 2 < src_len && src[off+1] == 0xBB && src[off+2] == 0xBF {
				// U+FEFF ZWNBSP. WhiteSpace per §5.1.1.
				off += 3
			} else if c == '<' && !l.is_module_mode &&
			          off + 3 < src_len &&
			          src[off+1] == '!' && src[off+2] == '-' && src[off+3] == '-' {
				// ECMA-262 §B.1.3 SingleLineHTMLOpenComment: `<!--` opens
				// a single-line comment in script source. Module mode
				// rejects this (no Annex B). Test262: annexB/language/
				// comments/single-line-html-open.js.
				comment_start := off
				off += 4 // skip `<!--`
				content_start := off
				end, had_nl := simd_skip_line_comment(src, off)
				if had_nl { l.had_line_terminator = true }
				if l.collect_comments {
					bump_append(&l.comments, Comment{
						type  = .Line,
						start = u32(comment_start),
						end   = u32(end),
						value = l.source[content_start:end],
					})
				}
				off = end
			} else if c == '-' && !l.is_module_mode && at_logical_line_start &&
			          off + 2 < src_len &&
			          src[off+1] == '-' && src[off+2] == '>' {
				// ECMA-262 §B.1.3 SingleLineHTMLCloseComment: `-->` opens
				// a single-line comment when the preceding input contains
				// a LineTerminator (or a multi-line block comment, or is
				// at file start). The `at_logical_line_start` predicate
				// covers all three. Test262: annexB/language/comments/
				// single-line-html-close*.js & multi-line-html-close.js.
				comment_start := off
				off += 3 // skip `-->`
				content_start := off
				end, had_nl := simd_skip_line_comment(src, off)
				if had_nl { l.had_line_terminator = true }
				if l.collect_comments {
					bump_append(&l.comments, Comment{
						type  = .Line,
						start = u32(comment_start),
						end   = u32(end),
						value = l.source[content_start:end],
					})
				}
				off = end
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
						bump_append(&l.comments, Comment{
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
					if had_nl {
						l.had_line_terminator = true
						// Annex B: a `*/` followed by `-->` (with optional WS)
						// counts as a SingleLineHTMLCloseComment when the body
						// of the block comment contained a LineTerminator.
						at_logical_line_start = true
					}
					// Unterminated block comment — report as lexer error.
					// (simd_skip_block_comment returns `src_len` for both
					// terminated-at-EOF and run-off-end; check trailing `*/`.)
					terminated := end >= 2 && src[end-2] == '*' && src[end-1] == '/'
					if !terminated {
						bump_append(&l.lexer_errors, LexerError{
							offset  = u32(comment_start),
							message = "Unterminated block comment",
						})
					}
					if l.collect_comments {
						content_end := end - 2 if end >= 2 else end
						bump_append(&l.comments, Comment{
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
	// `single_char_tokens` is sized [256] so the high half (non-ASCII lead
	// bytes) is populated with .Invalid and falls through naturally. This
	// drops the `if c < 128` guard that otherwise gates every token.
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
	// Step past the first character. ASCII starts are 1-byte; multi-byte
	// UTF-8 starts (CJK, Latin-1 letters, …) need the full sequence
	// consumed up-front so simd_scan_id_cont's per-lane validator doesn't
	// see continuation bytes (0x80–0xBF) as a stand-alone code point and
	// reject them. See `is_id_cont_codepoint` for the spec predicate.
	first := src[l.offset]
	off := l.offset + 1
	if first >= 0x80 {
		if first < 0xC0 {
			// Stray continuation byte at identifier-start position; the
			// lexer's outer dispatch shouldn't reach us in that state
			// but be defensive.
			off = l.offset + 1
		} else if first < 0xE0 {
			off = l.offset + 2
		} else if first < 0xF0 {
			off = l.offset + 3
		} else {
			off = l.offset + 4
		}
		if off > src_len { off = src_len }
	}
	// SIMD body scan — 16 bytes/iter on ARM64 NEON, scalar fallback elsewhere.
	// `simd_scan_id_cont` is permissive with high bytes; `body_has_non_ascii`
	// is set whenever any byte >= 0x80 was consumed by the scan. The post-pass
	// below catches spec-invalid non-ASCII (U+2028/9, U+2E2F, surrogate
	// halves, …) without running on pure-ASCII identifiers.
	next_off, hit_bs, body_has_non_ascii := simd_scan_id_cont(src, off)
	off = next_off
	if hit_bs && off + 1 < src_len && src[off + 1] == 'u' {
		return lex_identifier_escaped(l, start, flags)
	}
	// Spec validation runs only when there's something to validate:
	//   * the first code point was multi-byte (might fail IdStart), OR
	//   * the body contained any non-ASCII byte (might fail IdContinue).
	// The validator may TRUNCATE the identifier when it encounters a
	// non-id-cont code point that the permissive SIMD scan greedily
	// consumed (e.g. NBSP / LS / PS / U+2E2F appearing as whitespace
	// between tokens). The truncated end is then propagated to both
	// `l.offset` and the FastToken.end so the next token starts where
	// the spec expects it to.
	end := u32(off)
	if first >= 0x80 || body_has_non_ascii {
		body_start := int(start) + 1
		if first >= 0x80 {
			switch {
			case first < 0xC0: body_start = int(start) + 1
			case first < 0xE0: body_start = int(start) + 2
			case first < 0xF0: body_start = int(start) + 3
			case:              body_start = int(start) + 4
			}
			if body_start > off { body_start = off }
		}
		truncated := lex_validate_unicode_identifier(l, int(start), body_start, off)
		if truncated >= 0 {
			off = truncated
			end = u32(off)
		}
	}
	l.offset = off
	tok_type := lookup_keyword_by_letter(src, start, end)
	return FastToken{start = start, end = end, kind = tok_type, flags = flags}
}

// lex_validate_unicode_identifier walks an identifier slice and either
// (a) emits a lexer error when the IdStart code point is invalid, or
// (b) returns a TRUNCATION offset when the body contains a code point
// that the permissive SIMD scan greedily consumed but is not actually
// a valid IdentifierPart (NBSP, LS / PS, ZWNBSP, U+2E2F, …). The
// truncation makes the IDENT_BODY scan spec-correct while keeping the
// SIMD hot loop fast (single mask, no per-byte decode).
//
// Returns -1 when the identifier is fully valid and should keep its
// permissive end. Returns a positive byte offset (within [body_start,
// end]) when the identifier must be cut at that offset — the caller
// then re-points l.offset and the FastToken.end at the truncation.
//
// Layout: the FIRST code point starts at `start`; subsequent code points
// (the "body") start at `body_start` and end at `end` (exclusive).
lex_validate_unicode_identifier :: proc(l: ^Lexer, start: int, body_start: int, end: int) -> int {
	src := l.source_bytes
	// IdStart for the first code point. An invalid IdStart is a hard
	// error — we don't truncate to zero, we just diagnose.
	if start < end && src[start] >= 0x80 {
		cp := decode_utf8_codepoint(src, start)
		if !is_id_start_codepoint(cp) {
			bump_append(&l.lexer_errors, LexerError{
				offset  = u32(start),
				message = "Invalid character in identifier",
			})
		}
	}
	// IdContinue scan over the body. ASCII bytes are already validated
	// via CHAR_CLASS_TABLE during the SIMD scan; only non-ASCII code
	// points need re-checking. The first failure becomes the truncation
	// offset — the lexer treats everything from there onward as belonging
	// to the next token (which is what spec-strict scanners do natively).
	i := body_start
	for i < end {
		c := src[i]
		if c < 0x80 {
			i += 1
			continue
		}
		cp := decode_utf8_codepoint(src, i)
		if !is_id_cont_codepoint(cp) {
			return i
		}
		switch {
		case c < 0xC0: i += 1
		case c < 0xE0: i += 2
		case c < 0xF0: i += 3
		case:          i += 4
		}
	}
	return -1
}

// Decode one UTF-8 code point at `pos`. Caller guarantees `pos` is the
// start of a valid sequence; returns the leading-byte value when the
// sequence is malformed (caller still surfaces the diagnostic).
decode_utf8_codepoint :: proc(src: []u8, pos: int) -> u32 {
	src_len := len(src)
	if pos >= src_len { return 0 }
	ch := src[pos]
	if ch < 0x80 { return u32(ch) }
	cp:    u32 = 0
	bytes: int = 1
	if ch < 0xC0 {
		return u32(ch)
	} else if ch < 0xE0 {
		cp = u32(ch & 0x1F); bytes = 2
	} else if ch < 0xF0 {
		cp = u32(ch & 0x0F); bytes = 3
	} else {
		cp = u32(ch & 0x07); bytes = 4
	}
	for bi := 1; bi < bytes && pos + bi < src_len; bi += 1 {
		cp = (cp << 6) | u32(src[pos + bi] & 0x3F)
	}
	return cp
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

// Codepoint-level IdentifierStart check. ASCII delegated to
// CHAR_CLASS_TABLE; non-ASCII codepoints first short-circuit on the few
// characters that are SPEC-MANDATED non-IdentifierStart regardless of the
// table's Unicode version (line terminators, ZWJ/ZWNJ here, surrogates),
// then fall through to the full ID_Start range table. Test262
// `language/identifiers/vertical-tilde-*-escaped.js` and
// `language/line-terminators/S7.3_A6_T*.js` rely on these rejections.
is_id_start_codepoint :: #force_inline proc(cp: u32) -> bool {
	if cp < 128 {
		return CHAR_CLASS_TABLE[cp] == u8(CharClass.IdStart)
	}
	// Hard rejections (independent of Unicode version):
	//   * U+2028 / U+2029  — LineTerminator (§12.3); never identifier.
	//   * ZWNJ / ZWJ      — IdentifierPart only, not IdentifierStart.
	//   * Surrogates      — invalid as standalone code points.
	//   * U+2E2F          — VERTICAL TILDE has Pattern_Syntax=Yes,
	//                       so it's neither ID_Start nor ID_Continue.
	//                       The bundled UNICODE_ID_START_RANGES table
	//                       was generated without subtracting
	//                       Pattern_Syntax, so a hard reject here
	//                       compensates until that table is
	//                       regenerated. Test262
	//                       language/identifiers/vertical-tilde-*.
	if cp == 0x2028 || cp == 0x2029 { return false }
	if cp == 0x200C || cp == 0x200D { return false }
	if cp == 0x2E2F                 { return false }
	if cp >= 0xD800 && cp <= 0xDFFF { return false }
	if is_unicode_id_start(cp) { return true }
	// `Other_ID_Start` (Unicode 16.0 PropList.txt). These are
	// grandfathered IdentifierStart code points whose general category
	// alone wouldn't qualify, so they're not in UNICODE_ID_START_RANGES.
	// Test262: language/identifiers/{other_id_continue,part-unicode-*,
	// start-unicode-17.0.0*}.js.
	switch cp {
	case 0x1885, 0x1886:           // MONGOLIAN LETTER ALI GALI BALUDA / THREE BALUDA
		return true
	case 0x2118:                   // SCRIPT CAPITAL P
		return true
	case 0x212E:                   // ESTIMATED SYMBOL
		return true
	case 0x309B, 0x309C:           // KATAKANA-HIRAGANA (SEMI-)VOICED SOUND MARK
		return true
	}
	return false
}

is_id_cont_codepoint :: #force_inline proc(cp: u32) -> bool {
	if cp < 128 {
		class := CHAR_CLASS_TABLE[cp]
		return class == u8(CharClass.IdStart) || class == u8(CharClass.Digit)
	}
	if cp == 0x2028 || cp == 0x2029 { return false }
	if cp == 0x2E2F                 { return false }  // Pattern_Syntax
	// `Other_ID_Continue` (Unicode 16.0 PropList.txt). MIDDLE DOT,
	// GREEK ANO TELEIA, ETHIOPIC DIGIT ONE..NINE, NEW TAI LUE THAM
	// DIGIT ONE, KATAKANA MIDDLE DOT, HALFWIDTH KATAKANA MIDDLE DOT
	// — grandfathered IdentifierPart code points that don't qualify
	// on category alone. Test262: language/identifiers/{other_id_
	// continue,part-unicode-*}.js.
	switch cp {
	case 0x00B7:                   // MIDDLE DOT
		return true
	case 0x0387:                   // GREEK ANO TELEIA
		return true
	case 0x1369..=0x1371:          // ETHIOPIC DIGIT ONE..NINE
		return true
	case 0x19DA:                   // NEW TAI LUE THAM DIGIT ONE
		return true
	case 0x30FB:                   // KATAKANA MIDDLE DOT
		return true
	case 0xFF65:                   // HALFWIDTH KATAKANA MIDDLE DOT
		return true
	}
	// Other_ID_Start is a strict subset of ID_Continue (ID_Continue
	// includes ID_Start), so include those grandfathered code points
	// here too — covers `var a℘` etc. when ℘ isn't the IdStart.
	if is_id_start_codepoint(cp) { return true }
	if cp >= 0xD800 && cp <= 0xDFFF { return false }
	return is_unicode_id_continue(cp)
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
				bump_append(&l.lexer_errors, LexerError{offset = u32(off), message = "Invalid Unicode escape in identifier"})
				l.offset = off + 1
				return FastToken{start = start, end = u32(off + 1), kind = .Invalid, flags = flags}
			}
			if first {
				if !is_id_start_codepoint(cp) {
					bump_append(&l.lexer_errors, LexerError{offset = u32(off), message = "Invalid character in identifier escape"})
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
					bump_append(&l.lexer_errors, LexerError{offset = u32(off), message = "Invalid character in identifier"})
					l.offset = off + 1
					return FastToken{start = start, end = u32(off + 1), kind = .Invalid, flags = flags}
				}
				bump_append(&cooked, c)
				off += 1
				first = false
			} else {
				if !is_id_cont_fast(c) { break }
				bump_append(&cooked, c)
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
	//   * Separators are forbidden in LegacyOctalIntegerLiteral and
	//     NonOctalDecimalIntegerLiteral (raw form `0` followed by digits
	//     or `_`). The grammar permits them only in the modern
	//     `NonZeroDigit (NumericLiteralSeparator? DecimalDigits)?` shape.
	off := l.offset
	is_simple_int := true
	acc : u64 = 0
	prev_was_sep := false
	had_any_sep := false
	// Detect 0-prefixed integer (Legacy octal / NonOctalDecimal). When
	// the literal starts with `0` AND the next char is a digit OR `_`,
	// any separator inside is a SyntaxError.
	legacy_zero_prefix := false
	if off < src_len && src[off] == '0' && off + 1 < src_len {
		n := src[off + 1]
		if (n >= '0' && n <= '9') || n == '_' {
			legacy_zero_prefix = true
		}
	}
	for off < src_len {
		ch := src[off]
		if ch >= '0' && ch <= '9' {
			acc = acc * 10 + u64(ch - '0')
			prev_was_sep = false
			off += 1
		} else if ch == '_' {
			if legacy_zero_prefix {
				bump_append(&l.lexer_errors, LexerError{offset = u32(off), message = "Numeric separator not allowed in legacy octal / non-octal-decimal literal"})
			}
			is_simple_int = false
			had_any_sep = true
			if prev_was_sep && !legacy_zero_prefix {
				bump_append(&l.lexer_errors, LexerError{offset = u32(off), message = "Numeric separator must be between two digits"})
			}
			prev_was_sep = true
			off += 1
		} else {
			break
		}
	}
	if had_any_sep && prev_was_sep {
		// Trailing `_` at end of integer part (`1_` or `1_.0`).
		bump_append(&l.lexer_errors, LexerError{offset = u32(off - 1), message = "Numeric separator not allowed here"})
	}

	// Check for decimal point or exponent → not a simple integer.
	// Validate separator placement in the fraction part and the exponent
	// part the same way we did for the integer part above. §12.9.3
	// forbids leading (`._1`, `e_1`), trailing (`1.0_`, `1e1_`), and
	// double (`1.0__0`) separators in every digit-run of a numeric literal.
	had_dot := false
	had_exp := false
	if off < src_len && (src[off] == '.' || src[off] == 'e' || src[off] == 'E') {
		is_simple_int = false
		if src[off] == '.' {
			had_dot = true
			off += 1
			frac_start := off
			prev_sep := true // leading sep illegal (`._1`)
			frac_digits := 0
			for off < src_len {
				ch := src[off]
				if ch >= '0' && ch <= '9' {
					prev_sep = false
					frac_digits += 1
					off += 1
				} else if ch == '_' {
					if prev_sep {
						bump_append(&l.lexer_errors, LexerError{offset = u32(off), message = "Numeric separator must be between two digits"})
					}
					prev_sep = true
					off += 1
				} else { break }
			}
			if prev_sep && frac_digits > 0 {
				// Trailing `_` in fraction (`1.0_` or `1.0_e1`).
				bump_append(&l.lexer_errors, LexerError{offset = u32(off - 1), message = "Numeric separator not allowed here"})
			}
			_ = frac_start
		}
		if off < src_len && (src[off] == 'e' || src[off] == 'E') {
			had_exp = true
			off += 1
			if off < src_len && (src[off] == '+' || src[off] == '-') { off += 1 }
			prev_sep := true // leading sep illegal (`1e_1`)
			exp_digits := 0
			for off < src_len {
				ch := src[off]
				if ch >= '0' && ch <= '9' {
					prev_sep = false
					exp_digits += 1
					off += 1
				} else if ch == '_' {
					if prev_sep {
						bump_append(&l.lexer_errors, LexerError{offset = u32(off), message = "Numeric separator must be between two digits"})
					}
					prev_sep = true
					off += 1
				} else { break }
			}
			if prev_sep && exp_digits > 0 {
				// Trailing `_` in exponent (`1e10_`).
				bump_append(&l.lexer_errors, LexerError{offset = u32(off - 1), message = "Numeric separator not allowed here"})
			}
		}
	}
	l.offset = off

	end := u32(off)

	// BigInt suffix. Spec: `n` is only legal on integer literals — NOT
	// after a decimal point and NOT after an exponent. `1.0n` and `1e1n`
	// are SyntaxErrors.
	if off < src_len && src[off] == 'n' {
		if had_dot {
			bump_append(&l.lexer_errors, LexerError{offset = u32(off), message = "BigInt literal cannot contain a decimal point"})
		}
		if had_exp {
			bump_append(&l.lexer_errors, LexerError{offset = u32(off), message = "BigInt literal cannot contain an exponent"})
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
				bump_append(&buf, text[i])
			}
		}
		text_no_underscores := string(buf[:])
		value, _ = strconv.parse_f64(text_no_underscores)
	}
	l.last_lit_offset = start; l.last_lit_value = LiteralValue(value); l.last_lit_type = .Number

	// §12.9.3 — "The SourceCharacter immediately following a
	// NumericLiteral must not be an IdentifierStart or DecimalDigit."
	// `1a`, `1e1x`, `00b0`, `0.5c`, `0\u0062` are all SyntaxErrors.
	// Without this check the lexer stops at the bad char and lets the
	// parser see a Number followed by an Identifier; ASI then accepts
	// the two as separate statements on the same line, masking the error.
	if end < u32(src_len) {
		c := src[end]
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '$' || c == '_' || c == '\\' {
			bump_append(&l.lexer_errors, LexerError{offset = end, message = "Identifier directly after number"})
		}
	}

	return FastToken{start = start, end = end, kind = .Number, flags = flags}
}

lex_hex :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	src := l.source_bytes
	src_len := len(src)
	l.offset += 2 // skip 0x
	digits_seen := 0
	prev_was_sep := true // start: leading separator illegal (`0x_F`)
	for l.offset < src_len {
		c := src[l.offset]
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') {
			l.offset += 1
			digits_seen += 1
			prev_was_sep = false
		} else if c == '_' {
			if prev_was_sep {
				bump_append(&l.lexer_errors, LexerError{offset = u32(l.offset), message = "Numeric separator must be between two digits"})
			}
			l.offset += 1
			prev_was_sep = true
		} else { break }
	}
	if prev_was_sep && digits_seen > 0 {
		// Trailing `_` (`0xF_`).
		bump_append(&l.lexer_errors, LexerError{offset = u32(l.offset - 1), message = "Numeric separator not allowed here"})
	}
	// §12.9.3 HexIntegerLiteral requires at least one HexDigit after `0x`.
	if digits_seen == 0 {
		bump_append(&l.lexer_errors, LexerError{offset = u32(l.offset), message = "Hex literal requires at least one digit"})
	}
	// Reject identifier-continue chars immediately following the hex body
	// (`0xzzz`, `0xfoo`, `0xff\u006fff` — the bad char is kept separate;
	// surface the error before ASI merges the next token as an
	// identifier). `n` is the legal BigInt suffix handled below.
	if l.offset < src_len {
		c := src[l.offset]
		if (c >= 'g' && c <= 'z') || (c >= 'G' && c <= 'Z') || c == '$' || c == '\\' {
			if c != 'n' {
				bump_append(&l.lexer_errors, LexerError{offset = u32(l.offset), message = "Invalid hex digit"})
			}
		}
	}
	end := u32(l.offset)
	if l.offset < src_len && src[l.offset] == 'n' {
		l.offset += 1
		end = u32(l.offset)
		return FastToken{start = start, end = end, kind = .BigInt, flags = flags}
	}

	// Compute f64 value from hex digits [start+2, end). Underscores are
	// separators and skipped. Parser reads last_lit_value for .Number tokens.
	// digits_seen counts non-underscore digits already; >16 hex digits
	// can exceed u64 (max u64 = 0xFFFF_FFFF_FFFF_FFFF, 16 hex digits) so
	// fall back to f64 accumulation to match `Number("0x...")` semantics
	// (JS represents hex literals as f64; precision loss is expected
	// above 2^53).
	value: f64
	if digits_seen > 16 {
		val: f64 = 0
		for i in int(start) + 2 ..< int(end) {
			c := src[i]
			if c == '_' { continue }
			d: u64
			switch {
			case c >= '0' && c <= '9': d = u64(c - '0')
			case c >= 'a' && c <= 'f': d = u64(c - 'a' + 10)
			case c >= 'A' && c <= 'F': d = u64(c - 'A' + 10)
			}
			val = val * 16 + f64(d)
		}
		value = val
	} else {
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
		value = f64(acc)
	}
	l.last_lit_offset = start
	l.last_lit_value = LiteralValue(value)
	l.last_lit_type = .Number

	return FastToken{start = start, end = end, kind = .Number, flags = flags}
}

lex_binary :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	src := l.source_bytes
	src_len := len(src)
	l.offset += 2 // skip 0b
	digits_seen := 0
	prev_was_sep := true // start: leading separator illegal (`0b_1`)
	for l.offset < src_len {
		c := src[l.offset]
		if c == '0' || c == '1' { l.offset += 1; digits_seen += 1; prev_was_sep = false }
		else if c == '_' {
			if prev_was_sep {
				bump_append(&l.lexer_errors, LexerError{offset = u32(l.offset), message = "Numeric separator must be between two digits"})
			}
			l.offset += 1
			prev_was_sep = true
		}
		else { break }
	}
	if prev_was_sep && digits_seen > 0 {
		// Trailing `_` (`0b1_`).
		bump_append(&l.lexer_errors, LexerError{offset = u32(l.offset - 1), message = "Numeric separator not allowed here"})
	}
	// `0b2`, `0bz`, `0b1\u006fff`, etc. — binary literal followed by a
	// digit / letter / \uXXXX that isn't a valid binary digit but *is* a
	// legal identifier-continue character. Per §12.9.3 the char
	// immediately after a NumericLiteral must not be IdentifierStart /
	// DecimalDigit; previously the lexer just stopped at the bad char
	// and ASI accepted the two as separate tokens.
	if l.offset < src_len {
		c := src[l.offset]
		if (c >= '2' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '$' || c == '\\' {
			if c != 'n' {
				bump_append(&l.lexer_errors, LexerError{offset = u32(l.offset), message = "Invalid binary digit"})
			}
		}
	}
	if digits_seen == 0 {
		bump_append(&l.lexer_errors, LexerError{offset = u32(l.offset), message = "Binary literal requires at least one digit"})
	}
	end := u32(l.offset)
	if l.offset < src_len && src[l.offset] == 'n' {
		l.offset += 1
		end = u32(l.offset)
		return FastToken{start = start, end = end, kind = .BigInt, flags = flags}
	}

	// >64 binary digits overflows u64 — fall back to f64.
	value: f64
	if digits_seen > 64 {
		val: f64 = 0
		for i in int(start) + 2 ..< int(end) {
			c := src[i]
			if c == '_' { continue }
			val = val * 2 + f64(c - '0')
		}
		value = val
	} else {
		acc: u64 = 0
		for i in int(start) + 2 ..< int(end) {
			c := src[i]
			if c == '_' { continue }
			acc = acc * 2 + u64(c - '0')
		}
		value = f64(acc)
	}
	l.last_lit_offset = start
	l.last_lit_value = LiteralValue(value)
	l.last_lit_type = .Number

	return FastToken{start = start, end = end, kind = .Number, flags = flags}
}

lex_octal :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	src := l.source_bytes
	src_len := len(src)
	l.offset += 2 // skip 0o
	digits_seen := 0
	prev_was_sep := true // start: leading separator illegal (`0o_7`)
	for l.offset < src_len {
		c := src[l.offset]
		if c >= '0' && c <= '7' { l.offset += 1; digits_seen += 1; prev_was_sep = false }
		else if c == '_' {
			if prev_was_sep {
				bump_append(&l.lexer_errors, LexerError{offset = u32(l.offset), message = "Numeric separator must be between two digits"})
			}
			l.offset += 1
			prev_was_sep = true
		}
		else { break }
	}
	if prev_was_sep && digits_seen > 0 {
		// Trailing `_` (`0o7_`).
		bump_append(&l.lexer_errors, LexerError{offset = u32(l.offset - 1), message = "Numeric separator not allowed here"})
	}
	// Same rejection rule as lex_binary: `0o8`, `0o9`, `0oz`, `0o7\u006fff`
	// etc. are SyntaxErrors. The `n` suffix is legal and handled below.
	if l.offset < src_len {
		c := src[l.offset]
		if (c == '8' || c == '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '$' || c == '\\' {
			if c != 'n' {
				bump_append(&l.lexer_errors, LexerError{offset = u32(l.offset), message = "Invalid octal digit"})
			}
		}
	}
	if digits_seen == 0 {
		bump_append(&l.lexer_errors, LexerError{offset = u32(l.offset), message = "Octal literal requires at least one digit"})
	}
	end := u32(l.offset)
	if l.offset < src_len && src[l.offset] == 'n' {
		l.offset += 1
		end = u32(l.offset)
		return FastToken{start = start, end = end, kind = .BigInt, flags = flags}
	}

	// >21 octal digits can overflow u64 (8^22 ≈ 7.4e19 > 2^64). Fall
	// back to f64 above the threshold.
	value: f64
	if digits_seen > 21 {
		val: f64 = 0
		for i in int(start) + 2 ..< int(end) {
			c := src[i]
			if c == '_' { continue }
			val = val * 8 + f64(c - '0')
		}
		value = val
	} else {
		acc: u64 = 0
		for i in int(start) + 2 ..< int(end) {
			c := src[i]
			if c == '_' { continue }
			acc = acc * 8 + u64(c - '0')
		}
		value = f64(acc)
	}
	l.last_lit_offset = start
	l.last_lit_value = LiteralValue(value)
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
		// No escape — direct string. Check for unescaped line
		// terminators (§12.9.4.1): bare LF / CR inside a string
		// literal is a SyntaxError. In JSX attribute string mode
		// (jsx_string_mode), raw newlines are allowed per JSX §2.2.
		span := remaining[:pos]
		if !l.jsx_string_mode {
			for bi := 0; bi < len(span); bi += 1 {
				b := span[bi]
				if b == '\n' || b == '\r' {
					bump_append(&l.lexer_errors, LexerError{
						offset = u32(int(start) + 1 + bi),
						message = "Unterminated string literal",
					})
					l.had_line_terminator = true
					break
				}
			}
		} else {
			// JSX strings: still track had_line_terminator for ASI.
			for b in span {
				if b == '\n' || b == '\r' {
					l.had_line_terminator = true
					break
				}
			}
		}
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
			bump_append(&l.lexer_errors, LexerError{offset = start, message = "Unterminated string literal"})
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
			for bi := 0; bi < len(span); bi += 1 {
				b := span[bi]
				if b == '\n' || b == '\r' {
					// §12.9.4.1 — unescaped LineTerminator in string.
					l.had_line_terminator = true
					if !l.jsx_string_mode {
						bump_append(&l.lexer_errors, LexerError{
							offset = u32(l.offset + bi),
							message = "Unterminated string literal",
						})
					}
					break
				}
			}
			append(&cook_buf, ..span)  // variadic-slice append: stays on runtime path
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
				bump_append(&cook_buf, u8(0x0A))
				l.offset += 2
			case 'r':
				bump_append(&cook_buf, u8(0x0D))
				l.offset += 2
			case 't':
				bump_append(&cook_buf, u8(0x09))
				l.offset += 2
			case 'b':
				bump_append(&cook_buf, u8(0x08))
				l.offset += 2
			case 'f':
				bump_append(&cook_buf, u8(0x0C))
				l.offset += 2
			case 'v':
				bump_append(&cook_buf, u8(0x0B))
				l.offset += 2
			case '\'', '"', '\\', '/':
				bump_append(&cook_buf, next)
				l.offset += 2
			case '0':
				// \0 only if not followed by a digit
				if l.offset + 2 < src_len && src[l.offset + 2] >= '0' && src[l.offset + 2] <= '9' {
					// Followed by digit; fallback to identity
					bump_append(&cook_buf, next)
					l.offset += 2
				} else {
					bump_append(&cook_buf, u8(0x00))
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
						bump_append(&l.lexer_errors, LexerError{offset = escape_off, message = "Invalid \\x escape: expected 2 hex digits"})
						bump_append(&cook_buf, '\\')
						bump_append(&cook_buf, next)
						l.offset += 2
					}
				} else {
					bump_append(&l.lexer_errors, LexerError{offset = escape_off, message = "Invalid \\x escape: expected 2 hex digits"})
					bump_append(&cook_buf, '\\')
					bump_append(&cook_buf, next)
					l.offset += 2
				}
			case 'u':
				// \u escape: \uHHHH (exactly 4 hex digits) or \u{H...H}
				// (variable-length, code point <= 0x10FFFF). Note: only
				// lowercase \u starts a Unicode escape; \U is identity.
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
							bump_append(&l.lexer_errors, LexerError{offset = uesc_off, message = "Invalid \\u{} escape: empty code point"})
						} else if overflow {
							bump_append(&l.lexer_errors, LexerError{offset = uesc_off, message = "Invalid \\u{} escape: code point out of range [0..0x10FFFF]"})
						} else {
							append_utf8(&cook_buf, cp)
						}
					} else {
						bump_append(&l.lexer_errors, LexerError{offset = uesc_off, message = "Invalid \\u{} escape: missing closing '}'"})
					}
				} else if l.offset + 5 < src_len {
					// \uHHHH — exactly 4 hex digits.
					h1 := hex_val(src[l.offset + 2])
					h2 := hex_val(src[l.offset + 3])
					h3 := hex_val(src[l.offset + 4])
					h4 := hex_val(src[l.offset + 5])
					if h1 >= 0 && h2 >= 0 && h3 >= 0 && h4 >= 0 {
						cp := u32(h1*4096 + h2*256 + h3*16 + h4)
						// S26 W5b: surrogate-pair combination.
					// `\uD835\uDD6B` (UTF-16 surrogate pair for U+1D56B "ᵖb")
					// must encode as a SINGLE 4-byte UTF-8 sequence, not as
					// two 3-byte sequences encoding the surrogate halves
					// (which is invalid UTF-8 / WTF-8). Pre-W5b the cooked
					// string was 6 bytes of invalid UTF-8; readers like
					// `Buffer.toString('utf8', …)` would replace each surrogate
					// half with U+FFFD. Surfaced via verify_integration walking
					// markdown-it / mathjax / showdown / katex / tippy entity
					// tables (~2000 mismatches across 5 files).
					//
					// ECMA-262 §12.9.4.1 SS: SV, SE: when a String literal
					// contains `\u<HighSurrogate>\u<LowSurrogate>` the parser
					// must concatenate to the supplementary code point.
					if cp >= 0xD800 && cp <= 0xDBFF && l.offset + 11 < src_len &&
					   src[l.offset + 6] == '\\' && src[l.offset + 7] == 'u' {
						lh1 := hex_val(src[l.offset + 8])
						lh2 := hex_val(src[l.offset + 9])
						lh3 := hex_val(src[l.offset + 10])
						lh4 := hex_val(src[l.offset + 11])
						if lh1 >= 0 && lh2 >= 0 && lh3 >= 0 && lh4 >= 0 {
							low_cp := u32(lh1*4096 + lh2*256 + lh3*16 + lh4)
							if low_cp >= 0xDC00 && low_cp <= 0xDFFF {
								cp = 0x10000 + (cp - 0xD800) * 0x400 + (low_cp - 0xDC00)
								append_utf8(&cook_buf, cp)
								l.offset += 12
								continue
							}
						}
					}
						append_utf8(&cook_buf, cp)
						l.offset += 6
					} else {
						bump_append(&l.lexer_errors, LexerError{offset = uesc_off, message = "Invalid \\u escape: expected 4 hex digits"})
						bump_append(&cook_buf, '\\')
						bump_append(&cook_buf, next)
						l.offset += 2
					}
				} else {
					bump_append(&l.lexer_errors, LexerError{offset = uesc_off, message = "Invalid \\u escape: expected 4 hex digits"})
					bump_append(&cook_buf, '\\')
					bump_append(&cook_buf, next)
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
				bump_append(&cook_buf, next)
				l.offset += 2
			}
		} else if c == '\n' || c == '\r' {
			// §12.9.4.1 — unescaped LineTerminator in a string literal
			// is a SyntaxError. The string is unterminated.
			l.had_line_terminator = true
			bump_append(&l.lexer_errors, LexerError{
				offset = u32(l.offset),
				message = "Unterminated string literal",
			})
			bump_append(&cook_buf, c)
			l.offset += 1
			if c == '\r' && l.offset < src_len && src[l.offset] == '\n' {
				l.offset += 1 // skip CR+LF pair
			}
		} else if c == 0xE2 && l.offset + 2 < src_len &&
		          src[l.offset + 1] == 0x80 &&
		          (src[l.offset + 2] == 0xA8 || src[l.offset + 2] == 0xA9) {
			// U+2028 LINE SEPARATOR (E2 80 A8) / U+2029 PARAGRAPH
			// SEPARATOR (E2 80 A9) — also line terminators per §12.3.
			// ES2019+ allows them in strings, so NO error here. Just
			// set had_line_terminator and copy through.
			l.had_line_terminator = true
			bump_append(&cook_buf, src[l.offset])
			bump_append(&cook_buf, src[l.offset + 1])
			bump_append(&cook_buf, src[l.offset + 2])
			l.offset += 3
		} else {
			// Regular character
			bump_append(&cook_buf, c)
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

lex_plus :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		if next == '+' { l.offset += 2; return FastToken{start = start, end = u32(l.offset), kind = .PlusPlus, flags = flags} }
		if next == '=' { l.offset += 2; return FastToken{start = start, end = u32(l.offset), kind = .AssignAdd, flags = flags} }
	}
	l.offset += 1
	return FastToken{start = start, end = u32(l.offset), kind = .Plus, flags = flags}
}

lex_minus :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	if l.offset + 1 < len(l.source) {
		next := l.source_bytes[l.offset + 1]
		if next == '-' { l.offset += 2; return FastToken{start = start, end = u32(l.offset), kind = .MinusMinus, flags = flags} }
		if next == '=' { l.offset += 2; return FastToken{start = start, end = u32(l.offset), kind = .AssignSub, flags = flags} }
	}
	l.offset += 1
	return FastToken{start = start, end = u32(l.offset), kind = .Minus, flags = flags}
}

lex_star :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
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

lex_equals :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
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

lex_bang :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
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

lex_less :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
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

lex_greater :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
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

lex_amp :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
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

lex_pipe :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
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

lex_dot :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
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
	// §12.9.3 — separator placement in the fraction part. Leading
	// separator after `.` (`._1`) is illegal; trailing (`0.1_`) and
	// doubled (`0.1__2`) are illegal too.
	prev_sep := true // the dot itself is the prior "non-digit"
	frac_digits := 0
	had_sep := false
	for off < src_len {
		ch := src[off]
		if ch >= '0' && ch <= '9' {
			prev_sep = false
			frac_digits += 1
			off += 1
		} else if ch == '_' {
			if prev_sep {
				bump_append(&l.lexer_errors, LexerError{offset = u32(off), message = "Numeric separator must be between two digits"})
			}
			had_sep = true
			prev_sep = true
			off += 1
		} else { break }
	}
	if prev_sep && frac_digits > 0 {
		bump_append(&l.lexer_errors, LexerError{offset = u32(off - 1), message = "Numeric separator not allowed here"})
	}
	had_exp := false
	// Exponent (with separator validation in the digit run).
	if off < src_len && (src[off] == 'e' || src[off] == 'E') {
		had_exp = true
		off += 1
		if off < src_len && (src[off] == '+' || src[off] == '-') { off += 1 }
		prev_sep_e := true
		exp_digits := 0
		for off < src_len {
			ch := src[off]
			if ch >= '0' && ch <= '9' {
				prev_sep_e = false
				exp_digits += 1
				off += 1
			} else if ch == '_' {
				if prev_sep_e {
					bump_append(&l.lexer_errors, LexerError{offset = u32(off), message = "Numeric separator must be between two digits"})
				}
				had_sep = true
				prev_sep_e = true
				off += 1
			} else { break }
		}
		if prev_sep_e && exp_digits > 0 {
			bump_append(&l.lexer_errors, LexerError{offset = u32(off - 1), message = "Numeric separator not allowed here"})
		}
	}
	l.offset = off
	end := u32(off)

	// Compute and publish the f64 value so the parser's NumericLiteral
	// emit picks up an accurate `.value`. Without this `last_lit_*`
	// stays stale from a previous token and the AST's `value` field
	// either reads as 0 (no offset match) or as garbage (coincidental
	// offset match) — see ESTree Literal.value contract: `Number(raw)
	// must equal value` for finite numeric literals.
	value: f64
	if !had_sep && !had_exp {
		// Fast integer-arithmetic path for `.<digits>` with no exponent
		// and no separators. Compute as <frac> / 10^<frac_digits> using
		// f64 directly to avoid a strconv allocation; produces an
		// exactly-rounded f64 for fractions <= 15 digits (the IEEE-754
		// double-precision exact-decimal limit).
		if frac_digits > 0 && frac_digits <= 15 {
			numer: u64 = 0
			for i in int(start) + 1 ..< int(end) {
				numer = numer * 10 + u64(src[i] - '0')
			}
			denom: f64 = 1
			for _ in 0 ..< frac_digits { denom *= 10 }
			value = f64(numer) / denom
		} else if frac_digits == 0 {
			value = 0
		} else {
			text := l.source[start:end]
			value, _ = strconv.parse_f64(text)
		}
	} else {
		text := l.source[start:end]
		if had_sep {
			buf := make([dynamic]u8, 0, len(text), context.temp_allocator)
			for i := 0; i < len(text); i += 1 {
				if text[i] != '_' { bump_append(&buf, text[i]) }
			}
			value, _ = strconv.parse_f64(string(buf[:]))
		} else {
			value, _ = strconv.parse_f64(text)
		}
	}
	l.last_lit_offset = start
	l.last_lit_value = LiteralValue(value)
	l.last_lit_type = .Number

	// §12.9.3 — reject identifier-continue immediately after the
	// numeric literal (`.5a`, `.5e1x`, `.5\u0062`). Without this the
	// lexer stops at the bad char and ASI papers over the error.
	if end < u32(src_len) {
		c := src[end]
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '$' || c == '_' || c == '\\' {
			bump_append(&l.lexer_errors, LexerError{offset = end, message = "Identifier directly after number"})
		}
	}
	return FastToken{start = start, end = end, kind = .Number, flags = flags}
}

lex_question :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
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

lex_caret :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	if l.offset + 1 < len(l.source) && l.source_bytes[l.offset + 1] == '=' {
		l.offset += 2
		return FastToken{start = start, end = u32(l.offset), kind = .AssignBitXor, flags = flags}
	}
	l.offset += 1
	return FastToken{start = start, end = u32(l.offset), kind = .BitXor, flags = flags}
}

lex_percent :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
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

// Force-lex a `/` as division (not regex). Called by the parser when
// it knows the `/` follows a postfix operator (e.g. TS non-null `x!`)
// and the can_start_regex heuristic was wrong.
lex_slash_as_div :: proc(l: ^Lexer) -> FastToken {
	start := u32(l.offset)
	flags := u8(0)
	if l.had_line_terminator { flags |= 1 }
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

	// Scan pattern. Tracks:
	//   • in_class  — inside `[...]` where `/` is literal.
	//   • group_depth — paren-balance `(` / `)` for group validation.
	// ECMA-262 §22.2 Pattern grammar validates more than just delimiter
	// balance (quantifier positions, AtomEscape / CharacterClassEscape /
	// GroupName surface, assertion forms, Unicode flag subset, etc.) —
	// the full validator is deferred to a dedicated regex parser. What
	// kessel enforces here is the set of common malformed-pattern cases
	// that OXC / V8 also catch at parse time.
	in_class := false
	group_depth := 0
	pattern_start := l.offset
	for l.offset < src_len {
		c := src[l.offset]
		if c == '\\' {
			// AtomEscape — swallow the next code unit. `\` at the very
			// end of the pattern (before closing `/`) is a SyntaxError.
			if l.offset + 1 >= src_len {
				bump_append(&l.lexer_errors, LexerError{offset = u32(l.offset), message = "Trailing backslash in regular expression"})
				l.offset += 1
				break
			}
			nxt := src[l.offset + 1]
			if nxt == '\n' || nxt == '\r' {
				bump_append(&l.lexer_errors, LexerError{offset = u32(l.offset), message = "Unterminated regular expression (escape before newline)"})
				break
			}
			l.offset += 2
			continue
		}
		if c == '[' && !in_class {
			in_class = true
			l.offset += 1
			continue
		}
		if c == ']' && in_class {
			in_class = false
			l.offset += 1
			continue
		}
		if c == '(' && !in_class {
			group_depth += 1
			l.offset += 1
			continue
		}
		if c == ')' && !in_class {
			if group_depth == 0 {
				bump_append(&l.lexer_errors, LexerError{offset = u32(l.offset), message = "Unmatched ')' in regular expression"})
			} else {
				group_depth -= 1
			}
			l.offset += 1
			continue
		}
		if c == '/' && !in_class {
			break
		}
		if c == '\n' || c == '\r' {
			break
		}
		// U+2028 LINE SEPARATOR (LS, `E2 80 A8`) and U+2029 PARAGRAPH
		// SEPARATOR (PS, `E2 80 A9`) are LineTerminators per §12.3 and
		// the RegularExpressionNonTerminator production excludes them.
		// Treat the same as `\n` / `\r` — break the body scan, let the
		// `unterminated` path below emit the diagnostic. Test262:
		//   regexp-{first,source}-char-no-{line,paragraph}-separator.js.
		if c == 0xE2 && l.offset + 2 < src_len && src[l.offset + 1] == 0x80 &&
		   (src[l.offset + 2] == 0xA8 || src[l.offset + 2] == 0xA9) {
			break
		}
		l.offset += 1
	}

	if l.offset >= src_len || src[l.offset] != '/' {
		// Unterminated regex — ran to EOF or a line terminator without
		// finding the closing `/`. Emit a diagnostic at the opening `/`
		// and return a RegularExpression token spanning the consumed
		// content so error recovery stays anchored. Previously this
		// silently fell back to `.Div`, which let `/abc;` at the end of
		// a file parse cleanly as `a/b/c;` — a spec violation observed on
		// the negative/007_unterminated_regex fixture.
		bump_append(&l.lexer_errors, LexerError{offset = start, message = "Unterminated regular expression"})
		end := u32(l.offset)
		full_regex := l.source[start:end]
		l.last_lit_offset = start
		l.last_lit_value = LiteralValue(full_regex)
		l.last_lit_type = .Regex
		return FastToken{start = start, end = end, kind = .RegularExpression, flags = flags}
	}

	if in_class {
		bump_append(&l.lexer_errors, LexerError{offset = u32(pattern_start), message = "Unterminated character class in regular expression"})
	}
	if group_depth > 0 {
		bump_append(&l.lexer_errors, LexerError{offset = u32(pattern_start), message = "Unterminated group in regular expression"})
	}

	// Pattern body validation is delegated to regex_validate_pattern
	// (src/regex.odin) — runs once after flag parsing so it can branch
	// on `has_u` / `has_v`. The named-group validator that used to live
	// inline here is now invoked from there.
	pattern_end := u32(l.offset)

	l.offset += 1 // skip closing /

	// Parse and validate flags (§22.2.1 RegExp constructor, Step 3).
	// Valid single-char flags: d g i m s u v y. Each may appear at most
	// once. `u` and `v` are mutually exclusive. The validator emits one
	// diagnostic per offending character so the lexer diag channel keeps
	// precise offsets.
	flags_start := l.offset
	seen_flags: [26]u8 // a-z bit set
	for l.offset < src_len {
		c := src[l.offset]
		// §B.1.4 / §11.8.5 — Regex flags may not contain Unicode escape sequences.
		// If `\uXXXX` immediately follows the closing `/`, report as lexer error.
		if c == '\\' && l.offset + 1 < src_len && src[l.offset+1] == 'u' {
			bump_append(&l.lexer_errors, LexerError{offset = u32(l.offset), message = "Regular expression flags must not contain Unicode escape sequences"})
			break
		}
		if !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') && c != '$' && c != '_' {
			break
		}
		if !(c >= 'a' && c <= 'z') {
			bump_append(&l.lexer_errors, LexerError{offset = u32(l.offset), message = "Invalid regular expression flag"})
			l.offset += 1
			continue
		}
		switch c {
		case 'd', 'g', 'i', 'm', 's', 'u', 'v', 'y':
			idx := int(c - 'a')
			if seen_flags[idx] != 0 {
				bump_append(&l.lexer_errors, LexerError{offset = u32(l.offset), message = "Duplicate regular expression flag"})
			}
			seen_flags[idx] = 1
		case:
			bump_append(&l.lexer_errors, LexerError{offset = u32(l.offset), message = "Invalid regular expression flag"})
		}
		l.offset += 1
	}
	// u and v are mutually exclusive (§22.2.1 Step 3 check).
	has_u := seen_flags[int('u' - 'a')] != 0
	has_v := seen_flags[int('v' - 'a')] != 0
	if has_u && has_v {
		bump_append(&l.lexer_errors, LexerError{offset = u32(flags_start), message = "Regular expression flags 'u' and 'v' are mutually exclusive"})
	}

	// Now that flags are parsed, run the full pattern validator. It owns
	// every diagnostic that depends on flag context (property escapes,
	// strict IdentityEscape, char-class range early errors in u/v mode,
	// v-flag set notation, …) plus the flag-agnostic named-group checks.
	regex_validate_pattern(l, u32(pattern_start), pattern_end, has_u, has_v)

	end := u32(l.offset)
	full_regex := l.source[start:end]
	l.last_lit_offset = start; l.last_lit_value = LiteralValue(full_regex); l.last_lit_type = .Regex
	return FastToken{start = start, end = end, kind = .RegularExpression, flags = flags}
}

// Scan the pattern body [pat_start, pat_end) for named-group issues:
//   * Empty group name: `(?<>x)` — reject.
//   * Unclosed group name: `(?<a` / `(?<a)` — reject.
//   * Duplicate group name: `(?<a>x)(?<a>y)` — reject.
//   * Dangling \k<name> reference: `(?<a>x)\k<b>` — reject.
//
// This is a surface-level syntactic check; the full RegExp grammar
// (AtomEscape / CharacterEscape / CharacterClassEscape / lookbehind
// restrictions / v-flag set notation / Unicode property escapes) is
// deferred to a dedicated regex parser.
regex_validate_named_groups :: proc(l: ^Lexer, pat_start, pat_end: u32, has_u, has_v: bool) {
	src := l.source_bytes
	if int(pat_end) > len(src) { return }

	// Pass 1 — collect declared names + report duplicate / empty.
	//
	// Alternation tracking (ES2025 Duplicate Named Capturing Groups):
	// Duplicate group names are allowed only when the duplicates
	// appear in different alternatives of the same group. We track a
	// stack of alternation indices: each `(` pushes 0, each `|`
	// increments the top, each `)` pops. A name's "branch path" is
	// the current stack snapshot; two names conflict if their paths
	// are identical (meaning they're in the same alternative at every
	// nesting level).
	names := make(map[string]bool, 4, context.temp_allocator)

	NameEntry :: struct {
		path: [16]u16,
		depth: int,
	}

	max_names :: 32
	name_entries: [max_names]struct {
		name: string,
		entry: NameEntry,
	}
	name_count := 0

	// Alternation stack: alt_stack[d] is the current alternative index at depth d.
	// Start at depth 1 to represent the implicit top-level Disjunction —
	// the entire pattern body is itself a Disjunction, so `|` at the top
	// level creates alternatives that can hold duplicate names.
	alt_stack: [64]u16
	alt_depth := 1
	alt_stack[0] = 0

	in_class := false
	for i := int(pat_start); i < int(pat_end); {
		c := src[i]
		if c == '\\' {
			// Skip AtomEscape — two-char slot. Handled in pass 2.
			i += 2
			continue
		}
		if c == '[' && !in_class { in_class = true; i += 1; continue }
		if c == ']' && in_class  { in_class = false; i += 1; continue }
		if in_class { i += 1; continue }
		// Track alternation: `|` increments alt at current depth.
		if c == '|' {
			if alt_depth > 0 && alt_depth <= len(alt_stack) {
				alt_stack[alt_depth - 1] += 1
			}
			i += 1
			continue
		}
		// Track group open/close for alternation depth.
		if c == ')' {
			if alt_depth > 0 { alt_depth -= 1 }
			i += 1
			continue
		}
		if c == '(' {
			// Push new alternation frame for any group.
			if alt_depth < len(alt_stack) {
				alt_stack[alt_depth] = 0
				alt_depth += 1
			}
			// Only process named groups `(?<name>…)` below.
			if !(i + 2 < int(pat_end) && src[i+1] == '?' && src[i+2] == '<') {
				i += 1
				continue
			}
			// `(?<` — skip lookbehind forms `(?<=` / `(?<!`.
			if i + 3 < int(pat_end) && (src[i+3] == '=' || src[i+3] == '!') {
				i += 4
				continue
			}
			name_start := i + 3
			j := name_start
			for j < int(pat_end) && src[j] != '>' && src[j] != ')' {
				if src[j] == '\\' && j + 1 < int(pat_end) {
					// Skip the backslash + the escape body. \uXXXX (4 hex)
					// or \u{H+} (variable). Don't fully decode here — the
					// outer name validator just needs to skip past.
					if src[j+1] == 'u' && j + 2 < int(pat_end) && src[j+2] == '{' {
						k := j + 3
						for k < int(pat_end) && src[k] != '}' { k += 1 }
						if k < int(pat_end) { j = k + 1 } else { j = k }
					} else {
						j += 2
						// Skip 4 hex digits for \uHHHH (best-effort).
						for k := 0; k < 4 && j < int(pat_end) && src[j] != '>'; k += 1 {
							j += 1
						}
					}
					continue
				}
				j += 1
			}
			if j >= int(pat_end) || src[j] != '>' {
				bump_append(&l.lexer_errors, LexerError{offset = u32(name_start), message = "Unterminated named capture group"})
				i = j + 1
				continue
			}
			name := string(src[name_start:j])
			if len(name) == 0 {
				bump_append(&l.lexer_errors, LexerError{offset = u32(name_start), message = "Empty named capture group"})
			} else {
				// ES2025 §Duplicate Named Capturing Groups: duplicate
				// group names are allowed only when the duplicates appear
				// in different alternatives (`(?:(?<a>x)|(?<a>y))`).
				// Check if this name conflicts with any existing entry
				// by comparing alternation branch paths.
				cur_path: NameEntry
				cur_path.depth = alt_depth
				for d := 0; d < alt_depth && d < len(cur_path.path); d += 1 {
					cur_path.path[d] = alt_stack[d]
				}
				// Check for conflict: same name with same branch path.
				has_conflict := false
				for ni := 0; ni < name_count; ni += 1 {
					if name_entries[ni].name == name {
						// Same name found. Check if branch paths differ.
						prev := name_entries[ni].entry
						// Find common ancestor depth.
						min_depth := prev.depth
						if cur_path.depth < min_depth { min_depth = cur_path.depth }
						same_path := true
						for d := 0; d < min_depth; d += 1 {
							if prev.path[d] != cur_path.path[d] {
								same_path = false
								break
							}
						}
						if same_path {
							has_conflict = true
							break
						}
					}
				}
				if has_conflict {
					bump_append(&l.lexer_errors, LexerError{
						offset = u32(name_start),
						message = "Duplicate named capture group",
					})
				}
				if name_count < max_names {
					name_entries[name_count].name = name
					name_entries[name_count].entry = cur_path
					name_count += 1
				}
				// Validate name characters — ASCII-only check that rejects
				// obvious non-identifier punctuation (`-`, `,`, space, etc.).
				// Non-ASCII bytes pass through as Unicode IdentifierPart
				// (UTF-8 encoded). The validator must skip over `\u{H…H}` /
				// `\uHHHH` escape bodies wholesale: those bodies legally
				// contain `{`, `}`, hex digits in the leading position, etc.
				// which would otherwise fail the character check. Without
				// this skip, every `(?<\u{1d4d1}…>...)/u` named group with
				// astral codepoints in its name is rejected (the
				// unicode-property-names-valid Test262 corpus).
				ok := true
				k := name_start
				for k < j {
					ch := src[k]
					// Non-ASCII byte — decode full UTF-8 codepoint
					// and validate against Unicode ID_Start / ID_Continue.
					if ch >= 0x80 {
						cp: u32 = 0
						bytes: int = 1
						if ch < 0xC0 {
							cp = u32(ch)
						} else if ch < 0xE0 {
							cp = u32(ch & 0x1F)
							bytes = 2
						} else if ch < 0xF0 {
							cp = u32(ch & 0x0F)
							bytes = 3
						} else {
							cp = u32(ch & 0x07)
							bytes = 4
						}
						for bi := 1; bi < bytes && k + bi < j; bi += 1 {
							cp = (cp << 6) | u32(src[k + bi] & 0x3F)
						}
						is_first := k == name_start
						if is_first {
							if !is_unicode_id_start(cp) {
								ok = false
								break
							}
						} else {
							if !is_unicode_id_continue(cp) {
								ok = false
								break
							}
						}
						k += bytes
						continue
					}
					if ch == '\\' {
						// Decode `\u…` escape and validate the resulting
						// codepoint against ID_Start / ID_Continue.
						esc_start := k
						esc_cp: u32 = 0
						esc_valid := false
						k += 1
						if k < j && src[k] == 'u' {
							k += 1
							if k < j && src[k] == '{' {
								// `\u{H+}` form.
								k += 1
								for k < j && src[k] != '}' {
									h := hex_val(src[k])
									if h >= 0 {
										esc_cp = esc_cp * 16 + u32(h)
										esc_valid = true
									}
									k += 1
								}
								if k < j { k += 1 } // skip '}'
							} else {
								// `\uHHHH` form.
								hex_digits := 0
								for n := 0; n < 4 && k < j; n += 1 {
									h := hex_val(src[k])
									if h >= 0 {
										esc_cp = esc_cp * 16 + u32(h)
										hex_digits += 1
									}
									k += 1
								}
								if hex_digits == 4 { esc_valid = true }
								// Surrogate pair: \uD800-\uDBFF followed by
								// \uDC00-\uDFFF → combine into supplementary CP.
								if esc_valid && esc_cp >= 0xD800 && esc_cp <= 0xDBFF {
									if k + 5 < j && src[k] == '\\' && src[k+1] == 'u' {
										low_cp: u32 = 0
										low_ok := true
										for n := 0; n < 4; n += 1 {
											h := hex_val(src[k+2+n])
											if h >= 0 {
												low_cp = low_cp * 16 + u32(h)
											} else {
												low_ok = false
											}
										}
										if low_ok && low_cp >= 0xDC00 && low_cp <= 0xDFFF {
											// Combine surrogate pair.
											esc_cp = 0x10000 + (esc_cp - 0xD800) * 0x400 + (low_cp - 0xDC00)
											k += 6 // skip \uDCxx
										}
									}
								}
							}
						}
						if esc_valid {
							// Validate the decoded codepoint against
							// ID_Start (first char) or ID_Continue.
							// For ASCII codepoints, use the ASCII checks;
							// for non-ASCII, use strict Unicode tables.
							is_first_char := esc_start == name_start
							valid_id := false
							if esc_cp < 0x80 {
								// ASCII: $, _, a-z, A-Z are ID_Start;
								// additionally 0-9 are ID_Continue.
								ec := u8(esc_cp)
								if ec == '$' || ec == '_' ||
								   (ec >= 'a' && ec <= 'z') ||
								   (ec >= 'A' && ec <= 'Z') {
									valid_id = true
								} else if !is_first_char && ec >= '0' && ec <= '9' {
									valid_id = true
								}
							} else {
								if is_first_char {
									valid_id = is_unicode_id_start(esc_cp)
								} else {
									valid_id = is_unicode_id_start(esc_cp) ||
									          is_unicode_id_continue(esc_cp)
								}
							}
							if !valid_id {
								ok = false
								break
							}
						}
						continue
					}
					is_start := k == name_start
					if ch == '$' || ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') {
						k += 1
						continue
					}
					if !is_start && ch >= '0' && ch <= '9' {
						k += 1
						continue
					}
					ok = false
					break
				}
				if !ok {
					bump_append(&l.lexer_errors, LexerError{offset = u32(name_start), message = "Invalid named capture group name"})
				} else {
					names[name] = true
				}
			}
			i = j + 1
			continue
		}
		i += 1
	}

	// Pass 2 — collect `\k<name>` references and verify each resolves.
	// Resolution rules (§22.2.1.5):
	//   * In u / v mode, a `\k` is ALWAYS a NamedBackreference. The
	//     name MUST resolve to a declared group; otherwise SyntaxError.
	//     `\k` not followed by `<` is also a SyntaxError.
	//   * In non-u mode, Annex B keeps the legacy escape: when the
	//     pattern has no named groups, `\k...` is literal characters.
	//     When at least one named group exists, `\k<name>` must resolve.
	has_any := len(names) > 0
	strict := has_u || has_v
	in_class = false
	for i := int(pat_start); i < int(pat_end); {
		c := src[i]
		if c == '[' && !in_class { in_class = true; i += 1; continue }
		if c == ']' && in_class  { in_class = false; i += 1; continue }
		if c == '\\' && i + 1 < int(pat_end) && src[i+1] == 'k' {
			// `\k` is a NamedBackreference. Only legal as `\k<name>`
			// when EITHER:
			//   (a) the pattern is u/v mode (always strict), OR
			//   (b) the pattern has at least one named group declared
			//       — then Annex B's literal-fallback no longer applies.
			// `/(?<a>.)\k/` and `/\k(?<a>.)/` both reject under (b).
			if i + 2 >= int(pat_end) || src[i+2] != '<' {
				if strict || has_any {
					bump_append(&l.lexer_errors, LexerError{offset = u32(i), message = "Invalid named back-reference: '\\k' must be followed by '<name>'"})
				}
				i += 2
				continue
			}
			name_start := i + 3
			j := name_start
			has_escape := false
			for j < int(pat_end) && src[j] != '>' && src[j] != ')' {
				if src[j] == '\\' && j + 1 < int(pat_end) {
					has_escape = true
					if src[j+1] == 'u' && j + 2 < int(pat_end) && src[j+2] == '{' {
						k := j + 3
						for k < int(pat_end) && src[k] != '}' { k += 1 }
						if k < int(pat_end) { j = k + 1 } else { j = k }
					} else {
						j += 2
						for k := 0; k < 4 && j < int(pat_end) && src[j] != '>'; k += 1 {
							j += 1
						}
					}
					continue
				}
				j += 1
			}
			if j < int(pat_end) && src[j] == '>' {
				// Skip name verification when the reference contains a
				// \uXXXX escape — we'd need to decode to compare against
				// the declaration set, which the lexer doesn't do.
				if !has_escape {
					name := string(src[name_start:j])
					if has_any || strict {
						if _, ok := names[name]; !ok {
							bump_append(&l.lexer_errors, LexerError{offset = u32(name_start), message = "Invalid named capture reference"})
						}
					}
				}
				i = j + 1
				continue
			}
			// Unterminated \k<…> — in non-u mode and with no declared
			// names, Annex B keeps the legacy escape behaviour. In u / v
			// mode and when names exist, this is a SyntaxError.
			if has_any || strict {
				bump_append(&l.lexer_errors, LexerError{offset = u32(name_start), message = "Unterminated named capture reference"})
			}
			i += 3
			continue
		}
		if c == '\\' {
			i += 2
			continue
		}
		i += 1
	}
}

// ============================================================================
// Hash — private identifier (#name)
// ============================================================================

lex_hash :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	l.offset += 1 // skip #
	src := l.source_bytes
	src_len := len(src)

	// §12.7.2: PrivateIdentifier : '#' IdentifierName. The IdentifierName
	// body accepts \uXXXX / \u{H...H} escapes in the same positions as a
	// regular identifier. If the body starts with `\`, or later contains
	// one, fall back to the escape-aware slow path.
	if l.offset < src_len && src[l.offset] == '\\' {
		return lex_private_identifier_escaped(l, start, flags)
	}
	if l.offset < src_len && is_id_start_fast(src[l.offset]) {
		l.offset += 1
		for l.offset < src_len {
			c := src[l.offset]
			if c == '\\' && l.offset + 1 < src_len && src[l.offset + 1] == 'u' {
				return lex_private_identifier_escaped(l, start, flags)
			}
			if !is_id_cont_fast(c) { break }
			l.offset += 1
		}
	}
	end := u32(l.offset)
	return FastToken{start = start, end = end, kind = .PrivateIdentifier, flags = flags}
}

// Escape-aware private identifier. Mirrors lex_identifier_escaped but
// starts after the '#' and emits a .PrivateIdentifier token. The cooked
// name INCLUDES the leading '#' so downstream parser code (which strips
// a leading '#' from cur_tok.value when building the PrivateIdentifier
// AST node) keeps working without a special case.
lex_private_identifier_escaped :: proc(l: ^Lexer, start: u32, flags: u8) -> FastToken {
	src := l.source_bytes
	src_len := len(src)
	off := int(start) + 1 // past the '#'

	cooked := make([dynamic]u8, 0, 32, l.allocator)
	bump_append(&cooked, u8('#'))

	first := true
	for off < src_len {
		c := src[off]
		if c == '\\' && off + 1 < src_len && src[off + 1] == 'u' {
			cp, ok, consumed := decode_u_escape(src, off)
			if !ok {
				bump_append(&l.lexer_errors, LexerError{offset = u32(off), message = "Invalid Unicode escape in private identifier"})
				l.offset = off + 1
				return FastToken{start = start, end = u32(off + 1), kind = .Invalid, flags = flags}
			}
			if first {
				if !is_id_start_codepoint(cp) {
					bump_append(&l.lexer_errors, LexerError{offset = u32(off), message = "Invalid character in private identifier"})
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
					bump_append(&l.lexer_errors, LexerError{offset = u32(off), message = "Invalid character in private identifier"})
					l.offset = off + 1
					return FastToken{start = start, end = u32(off + 1), kind = .Invalid, flags = flags}
				}
				bump_append(&cooked, c)
				off += 1
				first = false
			} else {
				if !is_id_cont_fast(c) { break }
				bump_append(&cooked, c)
				off += 1
			}
		}
	}

	end := u32(off)
	l.offset = off
	l.last_lit_offset = start
	l.last_lit_value = LiteralValue(string(cooked[:]))
	l.last_lit_type = .Identifier
	return FastToken{start = start, end = end, kind = .PrivateIdentifier, flags = flags | FLAG_HAS_ESCAPE}
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
			bump_append(&buf, ch)
			continue
		}
		next := src[i + 1]
		switch next {
		case 'n':  bump_append(&buf, u8(0x0A)); i += 1
		case 'r':  bump_append(&buf, u8(0x0D)); i += 1
		case 't':  bump_append(&buf, u8(0x09)); i += 1
		case 'b':  bump_append(&buf, u8(0x08)); i += 1
		case 'f':  bump_append(&buf, u8(0x0C)); i += 1
		case 'v':  bump_append(&buf, u8(0x0B)); i += 1
		case '\\', '`', '$', '\'', '"':
			bump_append(&buf, next); i += 1
		case '0':
			// \0 is NUL only when not followed by a decimal digit (else it's
			// a legacy octal, disallowed in templates — keep literal).
			if i + 2 >= src_len || src[i + 2] < '0' || src[i + 2] > '9' {
				bump_append(&buf, u8(0x00)); i += 1
			} else {
				bump_append(&buf, ch) // drop to identity path below
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
			bump_append(&buf, ch) // malformed — keep backslash literal
		case 'u':
			// \uHHHH or \u{H...H}. Reuse the shared decoder.
			cp, ok, consumed := decode_u_escape(src, i)
			if ok {
				append_utf8(&buf, cp)
				i += consumed - 1
			} else {
				bump_append(&buf, ch)
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
			bump_append(&buf, next); i += 1
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
	bump_append(&l.template_stack, false)

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

// `#force_no_inline` is critical here. The body is ~1000+ instructions of
// per-letter byte compares that dispatch by length. Inlining it into
// `lex_identifier` (which is itself inlined into `lex_token`) bloats the
// hot dispatch loop's icache footprint by ~5–10 KB — every identifier-lex
// site pulls the entire keyword table into icache. Forcing it out keeps
// `lex_token` lean and lets identifier-heavy bundles (real-world JS / TS
// where keywords are <5 % of identifiers) stay in L1 for the actual hot
// loop, paying a single call+return only when an identifier ACTUALLY needs
// keyword classification.
lookup_keyword_by_letter :: #force_inline proc(src: []u8, start: u32, end: u32) -> TokenType {
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
