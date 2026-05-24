package kessel

import "core:fmt"

// ============================================================================
// Diagnostic system — error codes, severity, and source-aware token
// formatting helpers. Phase 1 of the error-quality work (see
// `docs/diagnostics.md` once written, and the audit notes in commit
// `feat(diagnostics): error codes + source-aware Expected/got messages`).
//
// Design goals (carried over from the audit):
//   - One `ErrorCode` namespace covering lexer (K1xxx), parser (K2xxx),
//     early errors (K3xxx), and TypeScript parser-level (K4xxx).
//   - `code = .None` (zero value) is the legacy / un-coded path. All 610
//     pre-existing call sites compile unchanged; we migrate in batches.
//   - Codes carry a canonical message + optional hint + optional mapping
//     to a TypeScript error code via `ERROR_TABLE`. Call sites are free
//     to override the message at the call site (e.g. when quoting source
//     text); the code+severity still travel with the diagnostic.
//   - No new allocations in the hot path. The table is a `#partial switch`
//     over a small enum (compile-time dispatch, no map lookup).
// ============================================================================

// Severity classifies a Diagnostic. Phase 1 only emits `.Error`; the
// enum exists so that warnings (e.g. `with` outside strict mode, empty
// blocks, unreachable code) have a place to land in later phases.
Severity :: enum u8 {
	Error   = 0,   // zero value — preserves legacy "everything is an error" behaviour
	Warning = 1,
}

// ErrorCode is the stable, machine-readable identifier for a diagnostic.
// The numeric ranges are:
//   K1xxx (1000–1999): lexer
//   K2xxx (2000–2999): parser — syntax / structural
//   K3xxx (3000–3999): early errors (ECMA-262 §15-§17)
//   K4xxx (4000–4999): TypeScript parser-level (overload / ambient / modifier rules)
//
// `None` (zero) is the legacy sentinel for un-migrated call sites.
ErrorCode :: enum u16 {
	None                         = 0,

	// K2xxx — parser syntax
	K2002_ExpectedToken          = 2002,  // "Expected X, got Y" — generic
	K2003_ExpectedTypeElement    = 2003,  // empty tuple / type-arg / type-param slot
}

// ErrorInfo is the static record looked up by ErrorCode. Held in a
// `#partial switch` rather than a map to keep lookup branchless and
// avoid runtime initialisation. All strings are compile-time literals.
ErrorInfo :: struct {
	default_message: string,   // canonical wording; call sites MAY override
	hint:            string,   // optional, "" if none
	ts_code:         string,   // optional, "" if none — for TS editor parity
	severity:        Severity,
}

// error_info returns the canonical record for a code. Callers must
// supply codes that exist in the table; unknown codes return a zero
// `ErrorInfo` (silent fallback — never crashes the parser).
error_info :: proc(code: ErrorCode) -> ErrorInfo {
	#partial switch code {
	case .K2002_ExpectedToken:
		return ErrorInfo{
			default_message = "Expected token",
			hint            = "",
			ts_code         = "TS1005",
			severity        = .Error,
		}
	case .K2003_ExpectedTypeElement:
		return ErrorInfo{
			default_message = "Expected type element",
			hint            = "remove the stray comma, or fill in the missing type",
			ts_code         = "",
			severity        = .Error,
		}
	}
	return ErrorInfo{severity = .Error}
}

// error_code_string returns the stable "K####" identifier used in JSON
// output and the pretty renderer. Returns "" for `.None` so the emitter
// can skip the field on legacy diagnostics.
error_code_string :: proc(code: ErrorCode) -> string {
	if code == .None { return "" }
	// The enum value IS the numeric code, so we format it directly.
	// `fmt.tprintf` uses the temp allocator which lives for the parse job.
	return fmt.tprintf("K%04d", u16(code))
}

// severity_string maps the enum to its lowercase wire-format name.
// Used by both JSON emitters and the pretty renderer.
severity_string :: proc(s: Severity) -> string {
	switch s {
	case .Error:   return "error"
	case .Warning: return "warning"
	}
	return "error"
}

// ============================================================================
// Source-aware token formatting — Phase 3
// ============================================================================
//
// The old `fmt.tprintf("Expected %v, got %v", get_token_name(t), get_token_name(p.cur_type))`
// pattern produced messages like `Expected }, got identifier` which tells
// the reader nothing about what they actually wrote. The two helpers
// below replace `get_token_name(p.cur_type)` with a source-aware
// description AND apply consistent single-quote framing for punctuation
// and keywords (`'}'`, `'const'`).
//
// Both helpers allocate into the temp allocator (matches the rest of
// the parser's tprintf-based message construction). Strings live for
// the duration of the parse job.

// format_actual_token returns a description of the CURRENT token,
// suitable to follow "got " in an error message. For tokens with a
// fixed lexeme (punctuation, keyword) the lexeme is single-quoted:
// `')'`, `'const'`. For tokens whose lexeme varies (identifier,
// number, string, etc.) the result is a kind word plus a quoted
// preview of the source text where useful: `identifier 'foo'`,
// `numeric literal '0x1f'`.
//
// Per TigerStyle ("explain the rationale for a decision"): the
// asymmetry is deliberate — quoting `string literal '"hello"'`
// would double-quote and noise up the message, so string / template /
// regex stay as kind-only descriptions.
format_actual_token :: proc(p: ^Parser) -> string {
	t := p.cur_type
	#partial switch t {
	case .Identifier, .PrivateIdentifier:
		v := cur_value(p)
		if len(v) == 0 { return "identifier" }
		return fmt.tprintf("identifier '%s'", v)
	case .Number:
		v := cur_value(p)
		if len(v) == 0 { return "numeric literal" }
		return fmt.tprintf("numeric literal '%s'", v)
	case .BigInt:
		v := cur_value(p)
		if len(v) == 0 { return "bigint literal" }
		return fmt.tprintf("bigint literal '%s'", v)
	case .String:                return "string literal"
	case .Template, .TemplateHead, .TemplateMiddle, .TemplateTail:
		return "template literal"
	case .RegularExpression:     return "regular expression"
	case .JSXText:               return "JSX text"
	case .EOF:                   return "end of input"
	case .Invalid:               return "invalid token"
	case:
		// Punctuation and keywords have stable lexemes via
		// `get_token_name`. Single-quote them for consistency
		// with the expected-side formatter.
		return fmt.tprintf("'%s'", get_token_name(t))
	}
}

// format_expected_token returns a description of an EXPECTED token
// type, suitable to follow "Expected " in an error message. Mirrors
// `format_actual_token` but works from a TokenType alone (no source
// to quote). Punctuation and keywords are single-quoted (`'}'`,
// `'from'`); category tokens get a kind word (`identifier`,
// `numeric literal`, `end of input`).
format_expected_token :: proc(t: TokenType) -> string {
	#partial switch t {
	case .Identifier:            return "identifier"
	case .PrivateIdentifier:     return "private identifier"
	case .Number:                return "numeric literal"
	case .BigInt:                return "bigint literal"
	case .String:                return "string literal"
	case .Template, .TemplateHead, .TemplateMiddle, .TemplateTail:
		return "template literal"
	case .RegularExpression:     return "regular expression"
	case .EOF:                   return "end of input"
	case:
		return fmt.tprintf("'%s'", get_token_name(t))
	}
}
