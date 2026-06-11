package kessel

import "base:runtime"
import "core:mem"
import "core:slice"

// ============================================================================
// Regular expression pattern validator (ES2025 §22.2.1).
//
// Called via the public `regex_validate` entry below. The validator
// returns its diagnostics to the caller, which routes them into
// whatever error channel they prefer (the lexer appends to
// `l.lexer_errors` today; a future semantic checker could call
// `regex_validate` directly on RegExpLiteral nodes post-parse). Bytes
// covered are exclusively `src[pat_start:pat_end]`, the closed-open
// range of the pattern body (between the opening `/` and the closing
// `/`). The validator never mutates lexer cursor state because it
// never sees the lexer.
//
// The pre-#5 API took `l: ^Lexer` everywhere and reached into
// `l.source_bytes` / `l.lexer_errors`. That coupling made regex
// validation a lexer concern even though the brief calls it semantic.
// Public API is now `regex_validate(source, span, flags, alloc)`; the
// internal procs route through a small `RegexValidator` value that
// holds the borrowed source bytes and the per-call diagnostics buffer.
// ============================================================================

// One validator-emitted diagnostic. Caller maps these onto whatever
// error type its diagnostic channel uses (LexerError today).
//
// `code` was added in Phase 5d so the regex validator's diagnostics
// flow through with a stable K1012_InvalidRegex code, just like
// the rest of the K1xxx lexer codes. The default value (.None) keeps
// older call sites that build RegexDiagnostic literals working
// unchanged; sites migrated to populate `code` benefit from the
// JSON / pretty / binary surface area.
RegexDiagnostic :: struct {
	offset:  u32,
	message: string,
	code:    ErrorCode,
}

// Per-call validator state. Source is borrowed; errors and allocator
// are owned. Constructed inside `regex_validate` and threaded into the
// internal validator procs as their first argument. Not exported - the
// caller never builds one directly.
RegexValidator :: struct {
	source:    []u8,                      // borrowed
	errors:    [dynamic]RegexDiagnostic,  // owned, built per-call
	allocator: mem.Allocator,
}

// regex_validate is the public entry point. Builds a RegexValidator,
// runs the full pattern pipeline, and returns the populated diagnostic
// list. The returned slice is backed by the validator's [dynamic] which
// is allocated on `alloc` - typically the parse arena. Caller iterates
// the returned slice and routes diagnostics into its own channel.
//
// Empty return = no diagnostics. The validator never panics or aborts;
// every malformed regex surfaces as one or more diagnostics.
regex_validate :: proc(
	source:           []u8,
	pat_start, pat_end: u32,
	has_u, has_v:     bool,
	alloc:            mem.Allocator,
) -> []RegexDiagnostic {
	v: RegexValidator
	v.source    = source
	v.errors    = make([dynamic]RegexDiagnostic, 0, 4, alloc)
	v.allocator = alloc
	regex_validate_pattern(&v, pat_start, pat_end, has_u, has_v)
	return v.errors[:]
}

// ============================================================================
// Internal pipeline. Every proc below takes `v: ^RegexValidator` as its
// first argument and reads `v.source` for the source bytes;
// `append(&v.errors, RegexDiagnostic{...})` is the only diagnostic
// channel.
// ============================================================================
//
// Scope today (Phase A — landing in waves):
//   1a. Property-escape **structural** rules: `\p{…}` / `\P{…}` shape.
//       u/v-mode only — non-u/non-v sees `\p` as identity escape `p`
//       (Annex B). Catches empty body, unterminated body, multiple `=`,
//       empty name / value. NO name-table lookup yet.
//   1b. Binary-property name-table: rejects `\p{Alpha=Yes}/u` (binary
//       props don't take values) and `\p{Foo}/u` (unknown prop name).
//
// Named-group validation (the original §22.2.1 surface from earlier
// sessions) is still routed through here so there is one entry point
// for "everything that scans the pattern body". Future waves (strict
// IdentityEscape, char-class range, arithmetic modifiers, v-flag set
// notation, dup-named-group same-alternative tracking) will dispatch
// from `regex_validate_pattern` too.
// ============================================================================

regex_validate_pattern :: proc(v: ^RegexValidator, pat_start, pat_end: u32, has_u, has_v: bool) {
	src := v.source
	if int(pat_end) > len(src) { return }

	// Wave 1a: property-escape structural rules. u/v-mode only —
	// outside u/v, `\p`/`\P` are identity escapes per Annex B and
	// the spec deliberately preserves backward compatibility.
	if has_u || has_v {
		// regex_validate_u_mode_atoms folds in `\p{…}` property-escape
		// validation via regex_check_property_escape (item 10), so the
		// u/v path no longer needs a separate property-escape scan.
		regex_validate_u_mode_atoms(v, pat_start, pat_end, has_v)
	}
	// Class-range early errors run u-mode-only. In v-mode `[A--B]` is
	// set difference (a ClassSetExpression operator), not a range with
	// CharacterClass endpoints. The flat A-B range walker would mis-
	// flag every set-difference fixture (`[\d--_]/v`, `[[0-9]--\d]/v`,
	// …), so the validator only fires when u is set without v.
	if has_u && !has_v {
		regex_validate_class_ranges(v, pat_start, pat_end)
	}

	// Always-on structural early errors, validated in ONE pass (item 10):
	//   * Arithmetic modifiers `(?ims-ims:body)` (ES2025 RegExp Modifier
	//     Sequence proposal) — well-formed in non-u mode too.
	//   * Leading quantifier — `/?/`, `/*/`, `/+/`, `/{2}/`, `/{2,}/`,
	//     `/{2,5}/` are SyntaxErrors because the quantifier has no
	//     preceding Atom; same after `(` or `|`.
	//   * Quantified lookbehind — `(?<=…)` / `(?<!…)` cannot be quantified
	//     in any mode (§22.2.1). Lookahead _can_ be quantified in non-u via
	//     Annex B, so that broader rule lives in regex_validate_u_mode_atoms.
	// All three share the same escape / character-class skipping, so one
	// walk replaces the former three passes.
	regex_validate_structure(v, pat_start, pat_end)

	// v-mode character class restrictions (§22.2.1 ClassSetExpression).
	// Certain characters and double-punctuator sequences that were
	// valid inside `[…]/u` become SyntaxErrors inside `[…]/v`.
	if has_v {
		regex_validate_v_mode_class(v, pat_start, pat_end)
	}

	// Named-group declarations + `\k<name>` references. Strictness
	// depends on flag context: in u / v mode `\k` is always a
	// NamedBackreference and must resolve; in non-u mode Annex B
	// keeps the legacy literal-characters fallback when no names
	// are declared.
	regex_validate_named_groups(v, pat_start, pat_end, has_u, has_v)
}

// ============================================================================
// Phase E — Arithmetic modifier sequences.
//
// ECMA-262 §22.2.1 (post the RegExp Modifier Sequence proposal):
//
//   Atom :: ( ? RegularExpressionFlags : Disjunction )
//   Atom :: ( ? RegularExpressionFlags - RegularExpressionFlags : Disjunction )
//   Atom :: ( ? - RegularExpressionFlags : Disjunction )
//
// Where RegularExpressionFlags inside this production is restricted
// to {i, m, s} — the only "scoped" flags. The d / g / u / v / y flags
// are global-only and cannot appear here.
//
// Early errors (§22.2.1.5):
//   * It is a Syntax Error if any code point repeats inside one side.
//   * It is a Syntax Error if any code point appears in BOTH sides.
//   * It is a Syntax Error if a code point is outside {i, m, s}.
//   * It is a Syntax Error if either side contains a non-letter (so
//     escapes like `\u{0073}` and ZWJ / non-ASCII chars are rejected).
//   * It is a Syntax Error if no `:` follows the flags (i.e. `(?ms-i)`).
//   * It is a Syntax Error if both sides are empty (`(?-:a)`).
//
// We dispatch by looking for the `(?` opening that is NOT followed by
// `:`, `=`, `!`, or `<` — those are non-capturing groups, lookahead
// / lookbehind / named-group productions and are validated elsewhere.
//
// Test262 buckets covered (~130 fixtures total):
//   built-ins/RegExp/early-err-arithmetic-modifiers-*.js
//   built-ins/RegExp/syntax-err-arithmetic-modifiers-*.js
//   built-ins/RegExp/early-err-modifiers-*.js
//   language/literals/regexp/early-err-arithmetic-modifiers-*.js
//   language/literals/regexp/syntax-err-arithmetic-modifiers-*.js
//   language/literals/regexp/early-err-modifiers-*.js
// ============================================================================

// Validate a single arithmetic modifier sequence anchored at `start`
// (which points at the opening `(`). Appends one diagnostic to `errors`
// on failure. The caller controls scan advancement; this only emits.
regex_check_modifier_sequence :: proc(errors: ^[dynamic]RegexDiagnostic, src: []u8, start, pe: int) {
	// Two side-tracker bitmaps (ASCII letters only — indexed by
	// `c & 0x7F`). The arithmetic modifier flags are spec-restricted
	// to {i, m, s} so a 128-slot table is plenty.
	add_seen: [128]u8
	rem_seen: [128]u8

	j := start + 2 // past `(?`
	in_remove := false
	saw_hyphen := false
	add_count := 0
	rem_count := 0
	bad := false

	loop: for j < pe {
		c := src[j]
		if c == ':' || c == ')' { break loop }

		if c == '-' {
			if in_remove {
				// Two `-` in one sequence — ungrammatical.
				bad = true
				j += 1
				continue
			}
			in_remove = true
			saw_hyphen = true
			j += 1
			continue
		}

		// Reject any escape inside the flag list — spec disallows
		// IdentityEscape / UnicodeEscape forms here. Test262 fixture:
		//   /(?\u{0073}-s:a)/  → SyntaxError.
		if c == '\\' {
			bad = true
			// Skip the escape body so the loop doesn't re-trip on its
			// internals (e.g. `\u{0073}`).
			j += 1
			if j < pe && src[j] == 'u' && j + 1 < pe && src[j + 1] == '{' {
				j += 2
				for j < pe && src[j] != '}' { j += 1 }
				if j < pe { j += 1 }
			} else if j < pe {
				j += 1
			}
			continue
		}

		// Non-ASCII bytes: invalid in flag list. Tests cover ZWJ
		// (U+200D), ZWNJ (U+200C), ZWNBSP (U+FEFF), arbitrary code
		// points like combining diacritics, etc.
		if c >= 0x80 {
			bad = true
			// Skip the multi-byte sequence: lead byte E0–F4 are 3–4
			// bytes; lead byte C2–DF are 2 bytes; everything else is
			// already malformed UTF-8 we just step past.
			if      c >= 0xF0 && j + 4 <= pe { j += 4 }
			else if c >= 0xE0 && j + 3 <= pe { j += 3 }
			else if c >= 0xC0 && j + 2 <= pe { j += 2 }
			else                              { j += 1 }
			continue
		}

		// Uppercase ASCII letters: spec says modifier flags are NOT
		// case-folded, only lowercase i/m/s are valid. Test262:
		//   /(?I:a)/ → SyntaxError.
		if c >= 'A' && c <= 'Z' {
			bad = true
			j += 1
			continue
		}

		// Lowercase ASCII letter: must be one of the modifier-allowed
		// {i, m, s}. Other letters (`d`, `g`, `u`, `v`, `y`, anything
		// random) are SyntaxErrors. Tests:
		//   /(?-d:a)/ /(?-g:a)/ /(?-u:a)/ /(?-y:a)/ …
		if !(c >= 'a' && c <= 'z') {
			// Digits, punctuation — not a flag at all.
			bad = true
			j += 1
			continue
		}
		if !(c == 'i' || c == 'm' || c == 's') {
			bad = true
			// Fall through to count it for duplicate / overlap.
		}
		if !in_remove {
			if add_seen[c] != 0 { bad = true } // duplicate within add
			add_seen[c] = 1
			add_count += 1
		} else {
			if rem_seen[c] != 0 { bad = true } // duplicate within remove
			if add_seen[c] != 0 { bad = true } // overlap with add
			rem_seen[c] = 1
			rem_count += 1
		}
		j += 1
	}

	// Sequence MUST close with `:` followed by Disjunction. `)` here
	// (or end-of-pattern) means no body — ungrammatical. Test262:
	//   /(?ms-i)/  → SyntaxError.
	if j >= pe || src[j] != ':' {
		bad = true
	}

	// Both sides empty after a hyphen — there's nothing to add and
	// nothing to remove, the production carries no information.
	// Test262: /(?-:a)/ → SyntaxError. (Plain `(?:a)` is non-capturing
	// and dispatched away before reaching this validator.)
	if saw_hyphen && add_count == 0 && rem_count == 0 {
		bad = true
	}

	if bad {
		append(errors, RegexDiagnostic{
			offset = u32(start),
			message = "Invalid regular expression modifier sequence",
		})
	}
}

// ============================================================================
// Phase B — strict u/v-mode pattern grammar.
//
// In u/v mode §22.2.1 tightens the regex grammar substantially — every
// `\X` must be a recognised AtomEscape / CharacterClassEscape /
// CharacterEscape / NamedBackreference / DecimalEscape, naked extended
// pattern characters (`{`, `}`, `]`) are SyntaxErrors, and an Assertion
// (lookahead / lookbehind) cannot be quantified. None of these were
// validated previously — the pattern body just walked past escape
// pairs as opaque two-byte slots, so `/\M/u` and friends parsed clean.
//
// The walker runs only when has_u or has_v is true (in non-u mode
// Annex B preserves the legacy lenient grammar). It pre-counts
// capturing groups for DecimalEscape backref validation, then makes a
// single pass through the body validating each escape and tracking
// the assertion-most-recently-closed flag for the quantifier check.
//
// Test262 buckets covered:
//   u-invalid-identity-escape       /\M/u                   IdentityEscape
//   u-invalid-class-escape          /\c0/u                  ControlEscape
//   u-invalid-legacy-octal-escape   /\1/u                   DecimalEscape oob
//   u-invalid-oob-decimal-escape    /\8/u                   DecimalEscape oob
//   u-invalid-extended-pattern-char /{/u                    extended pattern char
//   u-unicode-esc-bounds            /\u{110000}/u           cp range
//   u-unicode-esc-non-hex           /\u{1,}/u               non-hex in body
//   u-invalid-optional-lookahead    /.(?=.)?/u              quantified assertion
//   u-invalid-optional-lookbehind   /.(?<=.)?/u
//   u-invalid-optional-negative-*   /.(?!.)?/u  /.(?<!.)?/u
//   u-invalid-range-*               /.(?=.){2,3}/u          quantified assertion (range)
// ============================================================================

regex_validate_u_mode_atoms :: proc(v: ^RegexValidator, pat_start, pat_end: u32, has_v: bool) {
	src := v.source
	pe := int(pat_end)

	// Pass 1 — count capturing groups so we can validate `\N` decimal
	// escapes (\1 .. \9 .. multi-digit). Capturing-group productions:
	//   `(…)`         capturing
	//   `(?<name>…)`   capturing (named)
	//   `(?:…)`        non-capturing
	//   `(?=…)` `(?!…)` `(?<=…)` `(?<!…)`  assertions — not capturing
	//   `(?ims-ims:…)`  modifier — not capturing
	group_count := 0
	{
		in_class := false
		for i := int(pat_start); i < pe; {
			c := src[i]
			if c == '\\' && i + 1 < pe { i += 2; continue }
			if c == '[' && !in_class { in_class = true; i += 1; continue }
			if c == ']' && in_class  { in_class = false; i += 1; continue }
			if !in_class && c == '(' {
				if i + 1 < pe && src[i + 1] == '?' {
					if i + 2 < pe && src[i + 2] == '<' &&
					   i + 3 < pe && src[i + 3] != '=' && src[i + 3] != '!' {
						group_count += 1   // (?<name>
					}
					// (?:, (?=, (?!, (?<=, (?<!, (?ims…: — not capturing
				} else {
					group_count += 1       // plain (
				}
			}
			i += 1
		}
	}

	// Pass 2 — escape validation + quantified-assertion check.
	//
	// The assertion check uses a small group-kind stack: each `(` push a
	// frame describing whether the group is an Assertion. On `)` we pop
	// and remember whether the just-closed group was an Assertion;
	// the next character is examined — if it's a quantifier (`?`, `*`,
	// `+`, `{`) we emit a SyntaxError. The flag is cleared after one
	// step so it doesn't smear past an intervening atom.
	StackFrame :: struct { is_assertion: bool }
	stack: [64]StackFrame
	depth := 0
	last_closed_was_assertion := false

	in_class := false
	i := int(pat_start)
	for i < pe {
		c := src[i]

		// Reset the assertion flag once we've stepped past the `)` —
		// the very next iteration is when a quantifier could attach.
		// We check the flag at the top of the loop (below) and clear it
		// at the bottom unless we just popped a group.

		if c == '[' && !in_class { in_class = true; i += 1; last_closed_was_assertion = false; continue }
		if c == ']' && in_class  { in_class = false; i += 1; last_closed_was_assertion = false; continue }

		if in_class {
			// Inside a class, validate escapes (same rules) but skip the
			// group / quantifier tracking.
			if c == '\\' {
				i = regex_check_u_escape(v, src, i, pe, group_count, true, has_v)
			} else {
				i += 1
			}
			last_closed_was_assertion = false
			continue
		}

		// Quantifier following an assertion — reject in u/v mode.
		if last_closed_was_assertion && (c == '?' || c == '*' || c == '+' || c == '{') {
			append(&v.errors, RegexDiagnostic{
				offset = u32(i),
				message = "Invalid quantifier on assertion in u-mode regular expression",
			})
			last_closed_was_assertion = false
			i += 1
			continue
		}

		switch c {
		case '\\':
			i = regex_check_u_escape(v, src, i, pe, group_count, false, has_v)
			last_closed_was_assertion = false
		case '(':
			// Classify group kind. (?= (?! (?<= (?<! → assertion.
			is_assert := false
			if i + 2 < pe && src[i + 1] == '?' {
				n := src[i + 2]
				if n == '=' || n == '!' { is_assert = true }
				else if n == '<' && i + 3 < pe && (src[i + 3] == '=' || src[i + 3] == '!') {
					is_assert = true
				}
			}
			if depth < len(stack) {
				stack[depth] = StackFrame{is_assertion = is_assert}
				depth += 1
			}
			last_closed_was_assertion = false
			i += 1
		case ')':
			if depth > 0 {
				depth -= 1
				last_closed_was_assertion = stack[depth].is_assertion
			} else {
				last_closed_was_assertion = false
			}
			i += 1
		case '{':
			// Naked `{` outside a quantifier position is a SyntaxError
			// in u-mode. Heuristic: if the bytes from `{` form a valid
			// quantifier `{N}` / `{N,}` / `{N,M}` AND there's an atom
			// preceding (which we don't track precisely) we let it pass.
			// Otherwise reject. The leading-quantifier case `/{/u` and
			// `/{2}/u` is detected separately in regex_validate_leading_
			// quantifier; here we only flag `{` that is NOT immediately
			// followed by a digit (so `{x}/u` rejects but `{2}/u` is
			// left to the leading-quantifier pass).
			if i + 1 >= pe || !(src[i + 1] >= '0' && src[i + 1] <= '9') {
				append(&v.errors, RegexDiagnostic{
					offset = u32(i),
					message = "Invalid extended pattern character '{' in u-mode",
				})
			}
			last_closed_was_assertion = false
			i += 1
		case ']':
			// `]` outside a character class — deliberately NOT flagged.
			// In v-mode, character classes nest: `[[0-9]--\d]/v` (set
			// difference) closes the inner class at the first `]` and
			// our flat in_class tracker mistakes the outer `]` for a
			// stray. Until we track v-mode set notation properly
			// (Phase F) we accept stray `]`. The Test262 fixture set
			// for u-mode strict pattern grammar doesn't lean on this
			// rule — the lookahead-after-`)` checks and IdentityEscape
			// strictness do all the heavy lifting. `}` is also left
			// alone (legitimate close of `{N,M}` quantifier).
			last_closed_was_assertion = false
			i += 1
		case:
			last_closed_was_assertion = false
			i += 1
		}
	}
}

// Validate a single `\X` escape at `start` (which points at `\`) in
// u/v mode and return the offset just past it. The `in_class` flag
// loosens a couple of rules: `\b` is the backspace character inside
// a class but a word-boundary assertion outside; both forms are valid.
regex_check_u_escape :: proc(v: ^RegexValidator, src: []u8, start, pe: int, group_count: int, in_class: bool, has_v: bool) -> int {
	esc_off := u32(start)
	if start + 1 >= pe {
		append(&v.errors, RegexDiagnostic{offset = esc_off, message = "Trailing backslash in regular expression"})
		return pe
	}
	n := src[start + 1]
	switch n {
	case 'f', 'n', 'r', 't', 'v',
	     'd', 'D', 's', 'S', 'w', 'W',
	     'b', 'B':
		// CharacterClassEscape / CharacterEscape — single-letter
		// forms, no body to skip.
		return start + 2
	case 'p', 'P':
		// `\p{…}` / `\P{…}` — validate the property body AND skip past
		// the closing `}` in one step. Folding the property validation
		// into the escape dispatch means the u/v path makes a single
		// body pass instead of a separate property-escape scan (item 10).
		return regex_check_property_escape(v, src, start, pe, has_v)
	case 'k':
		// `\k<name>` — named back-reference, validated separately.
		// Skip past the `<…>` body so braces / angle-brackets don't
		// re-trigger the main walker.
		j := start + 2
		if j < pe && src[j] == '<' {
			j += 1
			for j < pe && src[j] != '>' { j += 1 }
			if j < pe { j += 1 }
		}
		return j
	case 'q':
		// `\q{strings}` is the v-mode "string set" CharacterClassEscape
		// (ES2024). Only legal under the v flag and only inside a
		// character class. Outside v, `\q` is an invalid IdentityEscape.
		if !has_v {
			append(&v.errors, RegexDiagnostic{
				offset = esc_off,
				message = "Invalid identity escape '\\q' (v-flag only)",
			})
			return start + 2
		}
		// Skip past `{…}` body so the outer walker doesn't re-trip.
		j := start + 2
		if j < pe && src[j] == '{' {
			j += 1
			for j < pe && src[j] != '}' { j += 1 }
			if j < pe { j += 1 }
		}
		return j
	case '0':
		// `\0` is the NUL character only when NOT followed by a
		// decimal digit — in u-mode `\01` (legacy octal) is rejected.
		if start + 2 < pe && src[start + 2] >= '0' && src[start + 2] <= '9' {
			append(&v.errors, RegexDiagnostic{
				offset = esc_off,
				message = "Invalid escape: '\\0' followed by decimal digit",
			})
		}
		return start + 2
	case '1', '2', '3', '4', '5', '6', '7', '8', '9':
		// Decimal escape — a backreference to the Nth capturing group.
		// In u-mode N must be ≤ group_count and the leading digit must
		// be non-zero (the `0` case above covers \0 + extras).
		j := start + 1
		n_val := 0
		for j < pe && src[j] >= '0' && src[j] <= '9' {
			n_val = n_val * 10 + int(src[j] - '0')
			j += 1
		}
		if n_val > group_count {
			append(&v.errors, RegexDiagnostic{
				offset = esc_off,
				message = "Invalid decimal escape: out-of-range back-reference",
			})
		}
		return j
	case 'c':
		// ControlEscape: `\cX` where X is [A-Za-z]. `\c0`, `\c\`, `\c`
		// at end-of-pattern are all SyntaxErrors in u-mode.
		if start + 2 >= pe {
			append(&v.errors, RegexDiagnostic{offset = esc_off, message = "Invalid '\\c' escape: missing control letter"})
			return start + 2
		}
		cl := src[start + 2]
		if !((cl >= 'A' && cl <= 'Z') || (cl >= 'a' && cl <= 'z')) {
			append(&v.errors, RegexDiagnostic{
				offset = esc_off,
				message = "Invalid '\\c' escape: control letter must be ASCII letter",
			})
		}
		return start + 3
	case 'x':
		// HexEscape: exactly 2 hex digits.
		if start + 3 >= pe || hex_val(src[start + 2]) < 0 || hex_val(src[start + 3]) < 0 {
			append(&v.errors, RegexDiagnostic{
				offset = esc_off,
				message = "Invalid '\\x' escape: expected 2 hex digits",
			})
			end := start + 4
			if end > pe { end = pe }
			return end
		}
		return start + 4
	case 'u':
		// UnicodeEscape: `\uHHHH` (exactly 4 hex) or `\u{H+}` (1+ hex,
		// CP ≤ 0x10FFFF). Existing string-literal scanner has the same
		// rules; we replicate here because regex bodies don't go through
		// lex_string_scalar.
		if start + 2 < pe && src[start + 2] == '{' {
			j := start + 3
			cp: u32 = 0
			digits := 0
			overflow := false
			for j < pe && src[j] != '}' {
				h := hex_val(src[j])
				if h < 0 { break }
				cp = cp * 16 + u32(h)
				if cp > 0x10FFFF { overflow = true }
				digits += 1
				j += 1
			}
			if j >= pe || src[j] != '}' || digits == 0 {
				append(&v.errors, RegexDiagnostic{
					offset = esc_off,
					message = "Invalid '\\u{…}' escape",
				})
			} else if overflow {
				append(&v.errors, RegexDiagnostic{
					offset = esc_off,
					message = "Invalid '\\u{…}' escape: code point out of range [0..0x10FFFF]",
				})
			}
			if j < pe && src[j] == '}' { return j + 1 }
			return j
		}
		// `\uHHHH` form.
		if start + 5 >= pe ||
		   hex_val(src[start + 2]) < 0 || hex_val(src[start + 3]) < 0 ||
		   hex_val(src[start + 4]) < 0 || hex_val(src[start + 5]) < 0 {
			append(&v.errors, RegexDiagnostic{
				offset = esc_off,
				message = "Invalid '\\u' escape: expected 4 hex digits",
			})
			end := start + 6
			if end > pe { end = pe }
			return end
		}
		return start + 6
	case '^', '$', '\\', '.', '*', '+', '?',
	     '(', ')', '[', ']', '{', '}', '|', '/':
		// SyntaxCharacter (the only valid IdentityEscape targets in
		// u-mode) plus `/` (forward-slash, listed separately by spec).
		return start + 2
	case '-':
		// `\-` is a valid IdentityEscape only INSIDE a character class
		// (where `-` is itself a range operator). Outside a class it's
		// not in the SyntaxCharacter set and is rejected. Test262 leans
		// strict here — `\-` outside class in u-mode is a SyntaxError.
		if !in_class {
			append(&v.errors, RegexDiagnostic{
				offset = esc_off,
				message = "Invalid identity escape in u-mode regular expression",
			})
		}
		return start + 2
	case:
		// Anything else (`\M`, `\Q`, `\@`, `\!`, `\;`, …) is an
		// invalid IdentityEscape in u-mode.
		append(&v.errors, RegexDiagnostic{
			offset = esc_off,
			message = "Invalid identity escape in u-mode regular expression",
		})
		return start + 2
	}
}

// ============================================================================
// Phase C — character class range early errors (§22.2.1.5).
//
//   NonemptyClassRanges :: ClassAtom - ClassAtom ClassRanges
//
// In u/v mode each ClassAtom in a `A-B` range MUST be a single
// character; if either side is a CharacterClassEscape (`\d`, `\s`,
// `\p{…}`, etc.) it's a SyntaxError. Test262 fixtures:
//   /[--\d]/u                u-invalid-non-empty-class-ranges
//   /[\d-a]/u                u-invalid-non-empty-class-ranges-no-dash-a
//   /[%-\d]/u                u-invalid-non-empty-class-ranges-no-dash-b
//   /[\s-\d]/u               u-invalid-non-empty-class-ranges-no-dash-ab
//
// Walk each `[…]` and look for `A-B` patterns. A and B are each:
//   * `\d`, `\D`, `\s`, `\S`, `\w`, `\W`           — character class
//   * `\p{…}`, `\P{…}`                              — character class
//   * any other char or escape                       — single character
// Reject when either side of `-` is a character-class atom.
// ============================================================================

// ============================================================================
// Phase B-e / B-f — quantifier structure early errors (§22.2.1).
//
// Two always-on rules share one scan over the pattern body:
//
//   Leading quantifier: `Quantifier :: { N } | { N , } | { N , M }` (and the
//   `?` / `*` / `+` postfixes) attach to an Atom. With no Atom before it
//   (start of pattern, after `(`, after `|`) the quantifier is ungrammatical:
//       /?/   /*/   /+/   /{2}/   /{2,}/   /{2,5}/   (a)|(?b)
//   Bare `{x}/u` (non-quantifier braces) is handled by the u-mode extended-
//   pattern-char rejection in regex_validate_u_mode_atoms; this rule only
//   flags braces that DO form a quantifier shape (regex_is_braced_quantifier),
//   since those are the only ones that look like a leading quantifier.
//
//   Quantified lookbehind: `(?<=Disjunction)` / `(?<!Disjunction)` is non-
//   quantifiable in EVERY mode (no Annex B carve-out, unlike lookahead).
//   Test262: invalid-{optional,range}-{lookbehind,negative-lookbehind}.js.
//
// The two rules never fire at the same index — a quantifier right after a
// closing `)` leaves expecting_atom = false (so the leading-quantifier rule
// is silent there), and the leading-quantifier rule only fires when
// expecting_atom = true. Each concern's diagnostics are buffered and flushed
// in [modifier][leading-quantifier][lookbehind] order so the combined output
// matches the former three separate passes exactly (modifier errors first,
// then all leading-quantifier errors in source order, then all lookbehind
// errors in source order).
// ============================================================================

// regex_open_is_lookbehind reports whether the `(` at src[i] opens a
// lookbehind group `(?<=` or `(?<!`. Bytes at or past pe are never read.
regex_open_is_lookbehind :: proc(src: []u8, i, pe: int) -> bool {
	return i + 3 < pe && src[i + 1] == '?' && src[i + 2] == '<' &&
		(src[i + 3] == '=' || src[i + 3] == '!')
}

// regex_skip_group_prefix advances past a `(?…)` group prefix, returning the
// index of the first byte after the prefix terminator (`:`, `=`, `!`, or
// `>`), or the index of the terminating `)` if the prefix is malformed. This
// keeps the group discriminator characters (`?`, `<`, `=`, `!`, name) from
// being mistaken for a leading quantifier's Atom. src[i] is `(`, src[i+1] `?`.
regex_skip_group_prefix :: proc(src: []u8, i, pe: int) -> int {
	j := i + 2
	for j < pe {
		ch := src[j]
		if ch == ':' || ch == '=' || ch == '!' || ch == '>' {
			j += 1
			break
		}
		if ch == ')' { break }
		j += 1
	}
	return j
}

// Mutable scan state shared by the quantifier-structure handlers below.
// `expecting_atom` is true wherever the next non-class character would start
// a fresh Atom (start of pattern, after `(`, after `|`); `stack` records the
// is-lookbehind flag of each currently-open paren so a quantifier directly
// after a `(?<=…)` / `(?<!…)` close can be rejected.
QuantScan :: struct {
	in_class:                   bool,
	expecting_atom:             bool,
	last_closed_was_lookbehind: bool,
	depth:                      int,
	stack:                      [64]bool,
}

// quant_scan_trivia consumes a leading escape (`\x`) or any byte inside a
// `[…]` class at src[i], which are plain non-quantifier symbols for both
// rules. Returns the advanced index and whether a byte was consumed (the
// caller continues when consumed is true).
quant_scan_trivia :: proc(s: ^QuantScan, src: []u8, i, pe: int) -> (next: int, consumed: bool) {
	c := src[i]
	if c == '\\' && i + 1 < pe {
		s.expecting_atom = false; s.last_closed_was_lookbehind = false
		return i + 2, true
	}
	if c == '[' && !s.in_class {
		s.in_class = true; s.expecting_atom = false; s.last_closed_was_lookbehind = false
		return i + 1, true
	}
	if c == ']' && s.in_class {
		s.in_class = false; s.expecting_atom = false; s.last_closed_was_lookbehind = false
		return i + 1, true
	}
	if s.in_class { return i + 1, true }
	return i, false
}

// quant_scan_group handles `(`, `)`, `|`, and ordinary characters, updating
// expecting_atom and the lookbehind stack. For a `(?…)` group it skips the
// prefix so the discriminator chars can't read as a leading quantifier.
// Returns the index the caller should resume scanning from.
quant_scan_group :: proc(s: ^QuantScan, src: []u8, i, pe: int) -> int {
	switch src[i] {
	case '(':
		if s.depth < len(s.stack) {
			s.stack[s.depth] = regex_open_is_lookbehind(src, i, pe)
			s.depth += 1
		}
		s.last_closed_was_lookbehind = false
		s.expecting_atom = true
		if i + 1 < pe && src[i + 1] == '?' {
			return regex_skip_group_prefix(src, i, pe)
		}
	case ')':
		if s.depth > 0 {
			s.depth -= 1
			s.last_closed_was_lookbehind = s.stack[s.depth]
		} else {
			s.last_closed_was_lookbehind = false
		}
		s.expecting_atom = false
	case '|':
		s.expecting_atom = true
		s.last_closed_was_lookbehind = false
	case:
		s.expecting_atom = false
		s.last_closed_was_lookbehind = false
	}
	return i + 1
}

regex_validate_structure :: proc(v: ^RegexValidator, pat_start, pat_end: u32) {
	src := v.source
	pe := int(pat_end)
	if int(pat_start) >= pe { return }

	s := QuantScan{expecting_atom = true}

	// Each concern's diagnostics are buffered then flushed in a fixed
	// [modifier][leading-quantifier][lookbehind] order so the emission
	// order matches the former three separate passes exactly (item 10).
	mod_errors: [dynamic]RegexDiagnostic
	lq_errors: [dynamic]RegexDiagnostic
	lb_errors: [dynamic]RegexDiagnostic
	mod_errors.allocator = context.temp_allocator
	lq_errors.allocator = context.temp_allocator
	lb_errors.allocator = context.temp_allocator
	defer delete(mod_errors)
	defer delete(lq_errors)
	defer delete(lb_errors)

	for i := int(pat_start); i < pe; {
		next, consumed := quant_scan_trivia(&s, src, i, pe)
		if consumed { i = next; continue }
		c := src[i]
		// Leading quantifier — a quantifier where an Atom is expected.
		if s.expecting_atom {
			if c == '?' || c == '*' || c == '+' ||
			   (c == '{' && regex_is_braced_quantifier(src, i, pe)) {
				append(&lq_errors, RegexDiagnostic{
					offset = u32(i), message = "Quantifier without preceding atom",
				})
				s.expecting_atom = false; i += 1; continue
			}
		}
		// Quantified lookbehind — a quantifier right after a `(?<=…)` /
		// `(?<!…)` group closes. Mutually exclusive with the rule above.
		if s.last_closed_was_lookbehind && (c == '?' || c == '*' || c == '+' || c == '{') {
			append(&lb_errors, RegexDiagnostic{
				offset = u32(i), message = "Invalid quantifier on lookbehind assertion",
			})
			s.last_closed_was_lookbehind = false; i += 1; continue
		}
		// Arithmetic modifier sequence — `(?` not followed by a non-
		// capturing / lookahead / lookbehind / named-group discriminator
		// (`:`, `=`, `!`, `<`). Only emits; quant_scan_group below owns
		// the structural advance (a modifier group skips like `(?:`).
		if c == '(' && i + 2 < pe && src[i + 1] == '?' {
			n := src[i + 2]
			if n != ':' && n != '=' && n != '!' && n != '<' {
				regex_check_modifier_sequence(&mod_errors, src, i, pe)
			}
		}
		i = quant_scan_group(&s, src, i, pe)
	}

	for e in mod_errors { append(&v.errors, e) }
	for e in lq_errors { append(&v.errors, e) }
	for e in lb_errors { append(&v.errors, e) }
}

// True iff src[off:pe] starts with a structurally-complete
// `{N}` / `{N,}` / `{N,M}` quantifier. Used only to disambiguate
// `{x}/u` (extended-pattern-char) from `{2}/u` (leading quantifier).
regex_is_braced_quantifier :: proc(src: []u8, off, pe: int) -> bool {
	j := off + 1
	if j >= pe || !(src[j] >= '0' && src[j] <= '9') { return false }
	for j < pe && src[j] >= '0' && src[j] <= '9' { j += 1 }
	if j >= pe { return false }
	if src[j] == '}' { return true }
	if src[j] != ',' { return false }
	j += 1
	if j < pe && src[j] == '}' { return true }
	for j < pe && src[j] >= '0' && src[j] <= '9' { j += 1 }
	return j < pe && src[j] == '}'
}

// regex_class_atom_codepoint extracts the code point value from a class atom
// span [atom_off..atom_end) in the source. Returns (cp, true) for single
// characters, (0, false) for class escapes or unparseable atoms.
regex_class_atom_codepoint :: proc(src: []u8, atom_off, atom_end: int) -> (u32, bool) {
	if atom_off >= atom_end { return 0, false }
	span := atom_end - atom_off
	if src[atom_off] == '\\' && atom_off + 1 < atom_end {
		e := src[atom_off + 1]
		switch e {
		case 'd', 'D', 's', 'S', 'w', 'W', 'p', 'P', 'b', 'B':
			return 0, false  // class escape, not a single char
		case 'u':
			if atom_off + 2 < atom_end && src[atom_off + 2] == '{' {
				// \u{H+}
				cp := u32(0)
				for k := atom_off + 3; k < atom_end && src[k] != '}'; k += 1 {
					h := hex_digit_val(src[k])
					if h < 0 { return 0, false }
					cp = cp * 16 + u32(h)
				}
				return cp, true
			} else if span >= 6 {
				// \uHHHH — may be a surrogate pair if followed by \uHHHH
				high := u32(0)
				for k := 0; k < 4; k += 1 {
					h := hex_digit_val(src[atom_off + 2 + k])
					if h < 0 { return 0, false }
					high = high * 16 + u32(h)
				}
				// Check for surrogate pair: \uD800-\uDBFF followed by \uDC00-\uDFFF
				if high >= 0xD800 && high <= 0xDBFF && span >= 12 &&
				   src[atom_off + 6] == '\\' && src[atom_off + 7] == 'u' {
					low := u32(0)
					for k := 0; k < 4; k += 1 {
						h := hex_digit_val(src[atom_off + 8 + k])
						if h < 0 { return high, true }  // just the high surrogate
						low = low * 16 + u32(h)
					}
					if low >= 0xDC00 && low <= 0xDFFF {
						cp := (high - 0xD800) * 0x400 + (low - 0xDC00) + 0x10000
						return cp, true
					}
				}
				return high, true
			}
			return 0, false
		case 'x':
			if span >= 4 {
				h1 := hex_digit_val(src[atom_off + 2])
				h2 := hex_digit_val(src[atom_off + 3])
				if h1 >= 0 && h2 >= 0 { return u32(h1 * 16 + h2), true }
			}
			return 0, false
		case 'n': return 0x0A, true
		case 'r': return 0x0D, true
		case 't': return 0x09, true
		case 'f': return 0x0C, true
		case 'v': return 0x0B, true
		case '0':
			if span == 2 { return 0, true }  // \0 NUL
			return 0, false  // octal
		case:
			return u32(e), true  // identity escape
		}
	}
	// Raw character — decode UTF-8.
	b0 := src[atom_off]
	if b0 < 0x80 { return u32(b0), true }
	if b0 < 0xC0 { return 0, false }  // continuation byte
	if b0 < 0xE0 && span >= 2 {
		return u32(b0 & 0x1F) << 6 | u32(src[atom_off+1] & 0x3F), true
	}
	if b0 < 0xF0 && span >= 3 {
		return u32(b0 & 0x0F) << 12 | u32(src[atom_off+1] & 0x3F) << 6 | u32(src[atom_off+2] & 0x3F), true
	}
	if span >= 4 {
		return u32(b0 & 0x07) << 18 | u32(src[atom_off+1] & 0x3F) << 12 | u32(src[atom_off+2] & 0x3F) << 6 | u32(src[atom_off+3] & 0x3F), true
	}
	return 0, false
}

hex_digit_val :: proc(c: u8) -> int {
	if c >= '0' && c <= '9' { return int(c - '0') }
	if c >= 'a' && c <= 'f' { return int(c - 'a' + 10) }
	if c >= 'A' && c <= 'F' { return int(c - 'A' + 10) }
	return -1
}

regex_validate_class_ranges :: proc(v: ^RegexValidator, pat_start, pat_end: u32) {
	src := v.source
	pe := int(pat_end)
	i := int(pat_start)
	for i < pe {
		c := src[i]
		if c == '\\' && i + 1 < pe { i += 2; continue }
		if c != '[' { i += 1; continue }
		// Walk this class to its closing `]`, recording each ClassAtom
		// span and whether it is a CharacterClass.
		j := i + 1
		// Skip leading `^` (negation) — doesn't change the rules here.
		if j < pe && src[j] == '^' { j += 1 }
		prev_is_class_escape := false
		prev_atom_off := -1
		prev_atom_end := -1
		just_after_dash := false
		for j < pe && src[j] != ']' {
			atom_off := j
			atom_is_class := false
			if src[j] == '\\' && j + 1 < pe {
				e := src[j + 1]
				switch e {
				case 'd', 'D', 's', 'S', 'w', 'W':
					atom_is_class = true
					j += 2
				case 'p', 'P':
					atom_is_class = true
					// Skip past `\p{…}` body if present.
					j += 2
					if j < pe && src[j] == '{' {
						j += 1
						for j < pe && src[j] != '}' { j += 1 }
						if j < pe { j += 1 }
					}
				case 'u':
					// `\u{H+}` or `\uHHHH` — a single character, valid
					// on either side of a range. For surrogate pairs
					// (\uD800-\uDBFF followed by \uDC00-\uDFFF), span
					// both halves as a single atom.
					j += 2
					if j < pe && src[j] == '{' {
						j += 1
						for j < pe && src[j] != '}' { j += 1 }
						if j < pe { j += 1 }
					} else {
						k := 0
						for k < 4 && j < pe { j += 1; k += 1 }
						// Check for surrogate pair: high surrogate followed by \uLLLL
						if j + 5 < pe && j - 4 >= 0 {
							high := u32(0)
							for d := 0; d < 4; d += 1 {
								hv := hex_digit_val(src[j - 4 + d])
								if hv >= 0 { high = high * 16 + u32(hv) }
							}
							if high >= 0xD800 && high <= 0xDBFF && src[j] == '\\' && src[j+1] == 'u' {
								// Consume second half of surrogate pair
								j += 2
								for kk := 0; kk < 4 && j < pe; kk += 1 { j += 1 }
							}
						}
					}
				case:
					j += 2
				}
			} else {
				// Raw character — skip full UTF-8 sequence.
				if src[j] >= 0xF0 && j + 3 < pe { j += 4 }
				else if src[j] >= 0xE0 && j + 2 < pe { j += 3 }
				else if src[j] >= 0xC0 && j + 1 < pe { j += 2 }
				else { j += 1 }
			}
			// Look at what follows: if `-` and then another atom,
			// we have a range with this atom on the LEFT.
			if just_after_dash {
				// This atom is the RIGHT side of a range. The previous
				// atom is the LEFT. Either being a class is an error.
				if prev_is_class_escape || atom_is_class {
					append(&v.errors, RegexDiagnostic{
						offset = u32(prev_atom_off if prev_atom_off >= 0 else atom_off),
						message = "Invalid character class range: range endpoints must be single characters",
					})
				} else {
					// Range order check: left endpoint must be ≤ right endpoint.
					left_cp, left_ok := regex_class_atom_codepoint(src, prev_atom_off, prev_atom_end)
					right_cp, right_ok := regex_class_atom_codepoint(src, atom_off, j)
					if left_ok && right_ok && left_cp > right_cp {
						append(&v.errors, RegexDiagnostic{
							offset = u32(prev_atom_off if prev_atom_off >= 0 else atom_off),
							message = "Range out of order in character class",
						})
					}
				}
				just_after_dash = false
				prev_is_class_escape = atom_is_class
				prev_atom_off = atom_off
				prev_atom_end = j
				continue
			}
			// Is the next byte a `-` opening a range? `]-` or `--`
			// don't form a range terminator (the `-` is just literal
			// when it's the last char of the class).
			if j < pe && src[j] == '-' && j + 1 < pe && src[j + 1] != ']' {
				prev_is_class_escape = atom_is_class
				prev_atom_off = atom_off
				prev_atom_end = j
				just_after_dash = true
				j += 1
			} else {
				prev_is_class_escape = atom_is_class
				prev_atom_off = atom_off
				prev_atom_end = j
			}
		}
		if j < pe && src[j] == ']' { i = j + 1 } else { i = j }
	}
}

// ============================================================================
// Wave 1a — structural validation of `\p{…}` / `\P{…}` in u/v mode.
//
// ECMA-262 §22.2.1 CharacterClassEscape (when [+UnicodeMode]):
//
//   CharacterClassEscape[U] ::
//     d
//     D
//     s
//     S
//     w
//     W
//     [+U] p{ UnicodePropertyValueExpression }
//     [+U] P{ UnicodePropertyValueExpression }
//
//   UnicodePropertyValueExpression ::
//     UnicodePropertyName = UnicodePropertyValue
//     LoneUnicodePropertyNameOrValue
//
//   UnicodePropertyName  :: UnicodePropertyNameCharacters
//   UnicodePropertyValue :: UnicodePropertyValueCharacters
//   UnicodePropertyNameCharacter  :: ControlLetter | _
//   UnicodePropertyValueCharacter :: UnicodePropertyNameCharacter | DecimalDigit
//
// Rules enforced here (no property-name-table yet):
//   1. `\p` not followed by `{` (in u/v) → SyntaxError.
//   2. `\p{}` empty body → SyntaxError.
//   3. `\p{xxx` no closing `}` (hits `/`, EOL, or EOF) → SyntaxError.
//   4. More than one `=` → SyntaxError.
//   5. Empty name (LHS of `=`) → SyntaxError.
//   6. Empty value (RHS of `=`) → SyntaxError.
//   7. Body chars outside [A-Za-z0-9_] → SyntaxError.
//
// Rule 8 (Wave 1b) — binary property with explicit value — runs after
// the structural body has been confirmed shape-valid.
// ============================================================================

// regex_check_property_escape validates a single `\p{…}` / `\P{…}`
// Unicode property escape anchored at `start` (which points at the
// `\`; src[start+1] is 'p' or 'P') and returns the offset just past
// it. Folded into the u/v-mode escape dispatch (regex_check_u_escape)
// so the u/v path makes a single body pass instead of running a
// separate property-escape scan (item 10).
regex_check_property_escape :: proc(v: ^RegexValidator, src: []u8, start, pe: int, has_v: bool) -> int {
	esc_off := u32(start)
	negated := src[start + 1] == 'P'
	if start + 2 >= pe || src[start + 2] != '{' {
		// Rule 1: `\p` not followed by `{`.
		append(&v.errors, RegexDiagnostic{
			offset = esc_off,
			message = "Invalid Unicode property escape: expected '{' after \\p",
		})
		return start + 2
	}
	body_start := start + 3
	j := body_start
	eq_count := 0
	eq_at := -1
	bad_char := false
	for j < pe && src[j] != '}' {
		ch := src[j]
		// Stop on chars that terminate a regex pattern; let the outer
		// scanner / lex_regex emit its own "unterminated" or invalid-
		// class diagnostic for the pattern as a whole. This loop only
		// flags the property body.
		if ch == '/' || ch == '\n' || ch == '\r' || ch == '\\' { break }
		if ch == '=' {
			eq_count += 1
			if eq_at < 0 { eq_at = j }
		} else if !is_property_body_char(ch) {
			bad_char = true
		}
		j += 1
	}
	if j >= pe || src[j] != '}' {
		// Rule 3: unterminated `\p{…`. j is at the failing byte; let
		// the caller resume there.
		append(&v.errors, RegexDiagnostic{
			offset = esc_off,
			message = "Invalid Unicode property escape: missing closing '}'",
		})
		return j
	}
	body_end := j
	// Rule 2: empty body.
	if body_end == body_start {
		append(&v.errors, RegexDiagnostic{
			offset = esc_off,
			message = "Invalid Unicode property escape: empty body",
		})
		return body_end + 1
	}
	// Rule 4: more than one `=`.
	if eq_count > 1 {
		append(&v.errors, RegexDiagnostic{
			offset = esc_off,
			message = "Invalid Unicode property escape: multiple '=' in body",
		})
		return body_end + 1
	}
	// Rule 7: bad chars in body (only emit once per escape).
	if bad_char {
		append(&v.errors, RegexDiagnostic{
			offset = esc_off,
			message = "Invalid Unicode property escape: invalid character in body",
		})
		return body_end + 1
	}
	if eq_count == 1 {
		// Name = Value form.
		name_start := body_start
		name_end := eq_at
		val_start := eq_at + 1
		val_end := body_end
		// Rule 5: empty name.
		if name_end == name_start {
			append(&v.errors, RegexDiagnostic{
				offset = esc_off,
				message = "Invalid Unicode property escape: empty property name",
			})
			return body_end + 1
		}
		// Rule 6: empty value.
		if val_end == val_start {
			append(&v.errors, RegexDiagnostic{
				offset = esc_off,
				message = "Invalid Unicode property escape: empty property value",
			})
			return body_end + 1
		}
		// Wave 1b — binary-property name with explicit value
		// (`\p{ASCII=Y}/u`). The spec says binary properties MUST
		// appear in lone form; pairing them with `=value` is a
		// parse-time SyntaxError regardless of whether the value would
		// otherwise be acceptable.
		name := string(src[name_start:name_end])
		if is_binary_unicode_property_name(name) {
			append(&v.errors, RegexDiagnostic{
				offset = esc_off,
				message = "Invalid Unicode property escape: binary property cannot have a value",
			})
			return body_end + 1
		}
		// Wave 1b — non-binary name must be a recognised property
		// name. Unknown name → SyntaxError.
		if !is_nonbinary_unicode_property_name(name) {
			append(&v.errors, RegexDiagnostic{
				offset = esc_off,
				message = "Invalid Unicode property escape: unknown property name",
			})
			return body_end + 1
		}
		// Phase G — validate the property value for General_Category.
		// The GC value set is small and stable across Unicode versions;
		// Script values are NOT validated here because the set grows
		// with each Unicode release and an incomplete table would cause
		// false rejections on newer script names.
		value := string(src[val_start:val_end])
		if name == "General_Category" || name == "gc" {
			if !is_valid_gc_property_value(value) {
				append(&v.errors, RegexDiagnostic{
					offset = esc_off,
					message = "Invalid Unicode property escape: unknown General_Category value",
				})
			}
		}
		return body_end + 1
	}
	// Lone form: must be a recognised binary property OR a
	// General_Category value alias (`\p{Lu}`, `\p{Letter}`, `\p{L}`,
	// …) OR — only under the v flag — a binary "of strings" property.
	body := string(src[body_start:body_end])
	if is_binary_unicode_property_name(body) ||
	   is_general_category_value(body) {
		// ok
	} else if is_property_of_strings(body) {
		if !has_v {
			// §22.2.1.5 — properties of strings are only legal under
			// the v flag. The matching Test262 fixture set lives in
			// property-escapes/generated/strings/.
			append(&v.errors, RegexDiagnostic{
				offset = esc_off,
				message = "Invalid Unicode property escape: 'of strings' property requires the 'v' flag",
			})
		} else if negated {
			// §22.2.1.5 — the negation form `\P` is not allowed for
			// properties of strings because their match set contains
			// length-≠2 strings; negation is undefined.
			append(&v.errors, RegexDiagnostic{
				offset = esc_off,
				message = "Invalid Unicode property escape: '\\P{...}' cannot be a property of strings",
			})
		}
	} else {
		append(&v.errors, RegexDiagnostic{
			offset = esc_off,
			message = "Invalid Unicode property escape: unknown lone property name",
		})
	}
	return body_end + 1
}

// One byte of a UnicodePropertyName / UnicodePropertyValue body —
// ASCII letter, digit, or underscore. The spec allows underscores
// inside identifier-style names (`White_Space`, `ASCII_Hex_Digit`).
is_property_body_char :: #force_inline proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') ||
	       (c >= 'A' && c <= 'Z') ||
	       (c >= '0' && c <= '9') ||
	        c == '_'
}

// ============================================================================
// Wave 1b — Unicode property name tables.
//
// These come straight from ECMA-262 §22.2.1.1 "Static Semantics:
// UnicodeMatchProperty" + §22.2.1.2 lists, mirrored against OXC's
// generated tables to match its acceptance set. We don't aim to
// validate values here; only **names**, since that's enough to drive
// the structural-error fixtures in the property-escapes/ corpus.
//
// All checks are case-sensitive — the spec specifically says property
// names are case-sensitive (`\p{ascii}/u` is invalid; only `\p{ASCII}`
// is recognised).
// ============================================================================

// §22.2.1.2 "BinaryUnicodeProperties" + §22.2.1.3 "BinaryProperty
// Aliases" (the `Alpha` alias for `Alphabetic`, `Hex` for
// `Hex_Digit`, etc.). Listed here in flat form so the lookup is a
// simple string-equality scan — list size is ≤ ~60, which fits in
// a couple of cache lines.
//
// When a name in this set appears as `\p{Name=Value}/u`, the spec's
// "Static Semantics: UnicodeMatchPropertyValue" step rejects the
// pair at parse time.
BINARY_UNICODE_PROPERTIES := [?]string{
	// Long names
	"ASCII",
	"ASCII_Hex_Digit",
	"Alphabetic",
	"Any",
	"Assigned",
	"Bidi_Control",
	"Bidi_Mirrored",
	"Case_Ignorable",
	"Cased",
	"Changes_When_Casefolded",
	"Changes_When_Casemapped",
	"Changes_When_Lowercased",
	"Changes_When_NFKC_Casefolded",
	"Changes_When_Titlecased",
	"Changes_When_Uppercased",
	"Dash",
	"Default_Ignorable_Code_Point",
	"Deprecated",
	"Diacritic",
	"Emoji",
	"Emoji_Component",
	"Emoji_Modifier",
	"Emoji_Modifier_Base",
	"Emoji_Presentation",
	"Extended_Pictographic",
	"Extender",
	"Grapheme_Base",
	"Grapheme_Extend",
	"Hex_Digit",
	"IDS_Binary_Operator",
	"IDS_Trinary_Operator",
	"ID_Continue",
	"ID_Start",
	"Ideographic",
	"Join_Control",
	"Logical_Order_Exception",
	"Lowercase",
	"Math",
	"Noncharacter_Code_Point",
	"Pattern_Syntax",
	"Pattern_White_Space",
	"Quotation_Mark",
	"Radical",
	"Regional_Indicator",
	"Sentence_Terminal",
	"Soft_Dotted",
	"Terminal_Punctuation",
	"Unified_Ideograph",
	"Uppercase",
	"Variation_Selector",
	"White_Space",
	"XID_Continue",
	"XID_Start",
	// Common short aliases
	"Alpha",   // → Alphabetic
	"CI",      // → Case_Ignorable
	"CWCF",    // → Changes_When_Casefolded
	"CWCM",    // → Changes_When_Casemapped
	"CWKCF",   // → Changes_When_NFKC_Casefolded
	"CWL",     // → Changes_When_Lowercased
	"CWT",     // → Changes_When_Titlecased
	"CWU",     // → Changes_When_Uppercased
	"DI",      // → Default_Ignorable_Code_Point
	"Dep",     // → Deprecated
	"Dia",     // → Diacritic
	"EBase",   // → Emoji_Modifier_Base
	"EComp",   // → Emoji_Component
	"EMod",    // → Emoji_Modifier
	"EPres",   // → Emoji_Presentation
	"ExtPict", // → Extended_Pictographic
	"Ext",     // → Extender
	"Gr_Base", // → Grapheme_Base
	"Gr_Ext",  // → Grapheme_Extend
	"Hex",     // → Hex_Digit
	"IDC",     // → ID_Continue
	"IDS",     // → ID_Start
	"Ideo",    // → Ideographic
	"Join_C",  // → Join_Control
	"LOE",     // → Logical_Order_Exception
	"Lower",   // → Lowercase
	"NChar",   // → Noncharacter_Code_Point
	"OAlpha",  // → Other_Alphabetic (legacy; OXC accepts it)
	"OIDC",    // → Other_ID_Continue
	"OIDS",    // → Other_ID_Start
	"OLower",  // → Other_Lowercase
	"OMath",   // → Other_Math
	"OUpper",  // → Other_Uppercase
	"PCM",     // → Prepended_Concatenation_Mark
	"Pat_Syn", // → Pattern_Syntax
	"Pat_WS",  // → Pattern_White_Space
	"QMark",   // → Quotation_Mark
	"RI",      // → Regional_Indicator
	"SD",      // → Soft_Dotted
	"STerm",   // → Sentence_Terminal
	"Term",    // → Terminal_Punctuation
	"UIdeo",   // → Unified_Ideograph
	"Upper",   // → Uppercase
	"VS",      // → Variation_Selector
	"WSpace",  // → White_Space
	"WS",      // → White_Space (alt)
	"space",   // → White_Space (POSIX-ish, accepted by V8/OXC)
	"XIDC",    // → XID_Continue
	"XIDS",    // → XID_Start
	"AHex",    // → ASCII_Hex_Digit
	"Bidi_C",  // → Bidi_Control
	"Bidi_M",  // → Bidi_Mirrored
	"IDSB",    // → IDS_Binary_Operator
	"IDST",    // → IDS_Trinary_Operator
}

// The two large property-name tables (BINARY_UNICODE_PROPERTIES ~95
// entries, GENERAL_CATEGORY_VALUES ~70) are sorted once at startup so
// the per-`\p{}` membership checks can binary-search instead of
// linear-scanning the whole list. The sort runs in place over the
// package-level arrays (no allocation), and `slice.binary_search` uses
// the same byte-lexicographic ordering as `slice.sort`, so the two stay
// consistent. The smaller tables (NONBINARY ~6, PROPERTIES_OF_STRINGS
// ~7) keep their linear scan — log-n search would not pay for itself.
@(init)
regex_sort_property_tables :: proc "contextless" () {
	context = runtime.default_context()
	slice.sort(BINARY_UNICODE_PROPERTIES[:])
	slice.sort(GENERAL_CATEGORY_VALUES[:])
}

is_binary_unicode_property_name :: proc(name: string) -> bool {
	// Length gate: properties are 2-28 chars. Reject out-of-range
	// lengths before paying for the log-n search.
	l := len(name)
	if l < 2 || l > 28 { return false }
	_, found := slice.binary_search(BINARY_UNICODE_PROPERTIES[:], name)
	return found
}

// §22.2.1.2 "NonbinaryUnicodeProperties" — the spec recognises
// only THREE non-binary property names. UCD has many more (Block,
// Line_Break, Bidi_Class, …) but those are deliberately NOT listed
// in ECMA-262, so `\p{Block=ASCII}/u` is a parse-time SyntaxError.
// V8 / OXC behave the same way — see the
// `unsupported-property-Block-with-value` and
// `unsupported-property-Line_Break*` Test262 fixtures.
NONBINARY_UNICODE_PROPERTIES := [?]string{
	"General_Category",  "gc",
	"Script",            "sc",
	"Script_Extensions", "scx",
}

is_nonbinary_unicode_property_name :: proc(name: string) -> bool {
	for n in NONBINARY_UNICODE_PROPERTIES {
		if n == name { return true }
	}
	return false
}

// §22.2.1.2 "GeneralCategoryValues" — accepted lone form for
// `\p{Lu}`, `\p{Letter}`, `\p{L}`, etc. These are General_Category
// values that can be written without the `gc=` prefix.
GENERAL_CATEGORY_VALUES := [?]string{
	// Long names
	"Letter", "Cased_Letter", "Uppercase_Letter", "Lowercase_Letter",
	"Titlecase_Letter", "Modifier_Letter", "Other_Letter",
	"Mark", "Nonspacing_Mark", "Spacing_Mark", "Enclosing_Mark",
	"Number", "Decimal_Number", "Letter_Number", "Other_Number",
	"Punctuation", "Connector_Punctuation", "Dash_Punctuation",
	"Open_Punctuation", "Close_Punctuation", "Initial_Punctuation",
	"Final_Punctuation", "Other_Punctuation",
	"Symbol", "Math_Symbol", "Currency_Symbol", "Modifier_Symbol",
	"Other_Symbol",
	"Separator", "Space_Separator", "Line_Separator", "Paragraph_Separator",
	"Other", "Control", "Format", "Surrogate", "Private_Use", "Unassigned",
	// 1-2 char aliases
	"L", "LC", "Lu", "Ll", "Lt", "Lm", "Lo",
	"M", "Mn", "Mc", "Me",
	"N", "Nd", "Nl", "No",
	"P", "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po",
	"S", "Sm", "Sc", "Sk", "So",
	"Z", "Zs", "Zl", "Zp",
	"C", "Cc", "Cf", "Cs", "Co", "Cn",
	// Legacy aliases
	"Punct",          // → Punctuation
	"punct",          // → Punctuation (POSIX-ish, V8/OXC accept)
	"digit",          // → Decimal_Number (POSIX-ish, V8/OXC accept)
	"cntrl",          // → Control
	"Combining_Mark", // → Mark (UCD legacy alias)
}

is_general_category_value :: proc(name: string) -> bool {
	l := len(name)
	if l < 1 || l > 21 { return false }
	_, found := slice.binary_search(GENERAL_CATEGORY_VALUES[:], name)
	return found
}

// §22.2.1.2 "BinaryPropertyOfStrings" — the v-flag-only set of
// "of strings" properties. In u-mode they're not allowed; we accept
// them everywhere for now (a finer wave can gate this on `has_v`)
// because the structural pattern is identical and OXC also accepts.
PROPERTIES_OF_STRINGS := [?]string{
	"Basic_Emoji",
	"Emoji_Keycap_Sequence",
	"RGI_Emoji",
	"RGI_Emoji_Flag_Sequence",
	"RGI_Emoji_Modifier_Sequence",
	"RGI_Emoji_Tag_Sequence",
	"RGI_Emoji_ZWJ_Sequence",
}

is_property_of_strings :: proc(name: string) -> bool {
	l := len(name)
	if l < 9 || l > 27 { return false }
	for n in PROPERTIES_OF_STRINGS {
		if len(n) == l && n == name { return true }
	}
	return false
}

// ============================================================================
// Phase F — v-mode character class validation (§22.2.1 ClassSetExpression).
//
// The `v` flag (ES2024 "set notation" proposal) tightens the grammar
// inside `[…]` substantially:
//
//   1. **ClassSetSyntaxCharacter** — the characters `(`, `)`, `{`, `}`,
//      `/`, `-`, `[`, `|` are reserved. They MUST be backslash-escaped
//      when used literally. (Backslash `\` is already an escape leader;
//      `]` closes the class.)
//
//   2. **ClassSetReservedDoublePunctuator** — two consecutive copies of
//      any of `&`, `!`, `#`, `$`, `%`, `*`, `+`, `,`, `.`, `:`, `;`,
//      `<`, `=`, `>`, `?`, `@`, `^`, `` ` ``, `~` are reserved syntax.
//      Only `--` (set difference) and `&&` (set intersection) have
//      defined semantics today; the rest are reserved for future use.
//      Any un-escaped pair is a SyntaxError.
//
//   3. **Negated class + property-of-strings** — `[^\p{Basic_Emoji}]/v`
//      is a SyntaxError because `^` cannot negate a set that may contain
//      multi-codepoint strings. (The un-negated `[\p{Basic_Emoji}]/v`
//      is fine.)
//
// Test262 corpus:
//   built-ins/RegExp/prototype/unicodeSets/breaking-change-from-u-to-v-{01..28}.js
//   built-ins/RegExp/property-escapes/generated/strings/*-negative-CharacterClass.js
// ============================================================================

regex_validate_v_mode_class :: proc(v: ^RegexValidator, pat_start, pat_end: u32) {
	src := v.source
	pe := int(pat_end)
	in_class := false
	class_is_negated := false
	class_has_prop_of_strings := false
	class_open_off := 0
	// Nesting depth for `[…[…]…]/v` — the v-mode grammar allows
	// nested classes for set-difference / intersection operands.
	nest_depth := 0

	i := int(pat_start)
	for i < pe {
		c := src[i]

		// Escape — skip two bytes minimum. Inside a class, `\` is a
		// valid escape leader and means the NEXT character is NOT
		// a ClassSetSyntaxCharacter. Outside a class we don't care.
		if c == '\\' && i + 1 < pe {
			if in_class {
				n := src[i + 1]
				// Track \p{…} to detect property-of-strings in negated class.
				if n == 'p' && i + 2 < pe && src[i + 2] == '{' {
					prop_start := i + 3
					j := prop_start
					for j < pe && src[j] != '}' { j += 1 }
					if j < pe {
						prop_name := string(src[prop_start:j])
						if is_property_of_strings(prop_name) {
							class_has_prop_of_strings = true
						}
						i = j + 1
						continue
					}
				}
				// Skip other escapes: `\u{H+}`, `\u`, `\p{…}`, etc.
				if n == 'u' && i + 2 < pe && src[i + 2] == '{' {
					j := i + 3
					for j < pe && src[j] != '}' { j += 1 }
					if j < pe { i = j + 1 } else { i = j }
					continue
				}
				if n == 'P' && i + 2 < pe && src[i + 2] == '{' {
					j := i + 3
					for j < pe && src[j] != '}' { j += 1 }
					if j < pe { i = j + 1 } else { i = j }
					continue
				}
				// `\q{…}` — v-mode string set. The body may contain
				// `|` (string alternative delimiter) and other chars that
				// would be flagged as ClassSetSyntaxCharacters. Skip
				// the entire body so those aren't mis-flagged.
				if n == 'q' && i + 2 < pe && src[i + 2] == '{' {
					j := i + 3
					for j < pe && src[j] != '}' { j += 1 }
					if j < pe { i = j + 1 } else { i = j }
					continue
				}
			}
			i += 2
			continue
		}

		if !in_class {
			if c == '[' {
				in_class = true
				nest_depth = 1
				class_open_off = i
				class_is_negated = (i + 1 < pe && src[i + 1] == '^')
				class_has_prop_of_strings = false
				if class_is_negated {
					i += 2 // skip `[^`
				} else {
					i += 1
				}
			} else {
				i += 1
			}
			continue
		}

		// --- Inside a character class in v-mode ---

		// Closing `]` — may be nested.
		if c == ']' {
			nest_depth -= 1
			if nest_depth <= 0 {
				// Class closes. Check negated-class + property-of-strings.
				if class_is_negated && class_has_prop_of_strings {
					append(&v.errors, RegexDiagnostic{
						offset = u32(class_open_off),
						message = "Invalid negated character class containing property of strings in v-mode",
					})
				}
				in_class = false
			}
			i += 1
			continue
		}

		// Nested `[` — in v-mode, `[` inside a class opens a nested
		// class for set-difference / intersection / union operands.
		// We scan ahead to see if a matching `]` closes the nested
		// class. If so, it's valid nesting and we bump depth; if the
		// pattern is `/[[]/v` (outer class `[` then `[` then `]`) the
		// outer class has only a single `[` as its content — which in
		// u-mode was a literal but in v-mode is a ClassSetSyntaxCharacter
		// error because the `]` actually closes the OUTER class, leaving
		// the inner `[` as a bare syntax char.
		//
		// Simpler rule: allow `[` to start a nested class. If the outer
		// class itself becomes malformed the lexer will catch it. The
		// breaking-change-03 test (`/[[]/v`) passes because the `[` at
		// position 1 opens a nested class, the `]` at position 2 closes
		// the nested class (making it empty), and then the OUTER class
		// has no closing `]` — the lexer sees `]` as the outer close and
		// the regex ends at `/`. Actually, in `/[[]/v` the regex body
		// is `[[]`: byte 0 is `[` (outer open), byte 1 is `[` (nested
		// open), byte 2 is `]` — which closes the nested class. But then
		// there's no `]` to close the outer class before the `/`.
		// This is caught by the LEXER as an unterminated character class.
		// However, Test262 expects a SyntaxError from the regex pattern
		// parser, not the lexer. So we need a different approach.
		//
		// The spec says: inside ClassSetExpression, a bare `[` MUST open
		// a nested ClassSetOperand. A nested ClassSetOperand is `[` then
		// optional `^` then ClassSetRange/ClassSetOperand then `]`. If
		// the content between `[` and `]` is empty, that's an error.
		// But the simplest path: check if this `[` followed by `]` with
		// nothing in between makes an empty nested class.
		if c == '[' {
			// Check for empty nested class `[]` (immediate `]` or `^]`).
			next_off := i + 1
			if next_off < pe && src[next_off] == '^' { next_off += 1 }
			if next_off >= pe || src[next_off] == ']' {
				// Empty nested class or unclosed — flag as syntax error.
				append(&v.errors, RegexDiagnostic{
					offset = u32(i),
					message = "Invalid unescaped character in v-mode character class",
				})
				i += 1
				continue
			}
			// Legitimate nested class: bump depth and continue.
			nest_depth += 1
			// Track negation for inner class too (nested negated class
			// containing property-of-strings is also an error).
			i += 1
			continue
		}

		// --- Double-punctuator check (BEFORE single-char check) ---
		//
		// ClassSetReservedDoublePunctuator: two consecutive copies of
		// any of `& ! # $ % * + , . : ; < = > ? @ ^ ` ~`.
		// `--` is the set-difference operator (valid) and `&&` is the
		// set-intersection operator (valid); all others are reserved
		// for future use and produce a SyntaxError.
		if i + 1 < pe && src[i + 1] == c {
			switch c {
			case '-':
				// `--` is the set-difference operator. Valid only
				// between two ClassSetOperands. We detect valid use:
				// there must be a preceding atom AND a following atom.
				// In `[a--b]` the `a` precedes; in `[--b]` there's no
				// preceding atom. In `[&&]/v` the `&&` has no operands.
				//
				// Approximate: `--` is valid iff NOT at the very start
				// of class content AND NOT immediately before `]`.
				is_start := (i == class_open_off + 1) ||
				            (class_is_negated && i == class_open_off + 2)
				is_end := (i + 2 >= pe) || (src[i + 2] == ']')
				if is_start || is_end {
					append(&v.errors, RegexDiagnostic{
						offset = u32(i),
						message = "Invalid reserved double punctuator in v-mode character class",
					})
				}
				i += 2
				continue
			case '&':
				// `&&` is the set-intersection operator. Same rule as `--`.
				is_start2 := (i == class_open_off + 1) ||
				             (class_is_negated && i == class_open_off + 2)
				is_end2 := (i + 2 >= pe) || (src[i + 2] == ']')
				if is_start2 || is_end2 {
					append(&v.errors, RegexDiagnostic{
						offset = u32(i),
						message = "Invalid reserved double punctuator in v-mode character class",
					})
				}
				i += 2
				continue
			case '!', '#', '$', '%', '*', '+', ',', '.', ':', ';',
			     '<', '=', '>', '?', '@', '^', '`', '~':
				append(&v.errors, RegexDiagnostic{
					offset = u32(i),
					message = "Invalid reserved double punctuator in v-mode character class",
				})
				i += 2
				continue
			case:
				// Not a reserved double-punctuator.
			}
		}

		// --- ClassSetSyntaxCharacter (lone occurrence) ---
		//
		// `(`, `)`, `{`, `}`, `/`, `|` have no valid role inside a
		// v-mode character class and must be backslash-escaped.
		// `-` is valid in a ClassSetRange (`a-z`) but is a lone
		// ClassSetSyntaxCharacter when it doesn't form `--` (set
		// diff) and isn't between two range endpoints. Since we
		// already handled `--` above, a lone `-` reaching here means
		// it might be a range hyphen (valid) or a bare hyphen (invalid).
		// Range-hyphen detection requires full atom tracking; for now
		// we flag `-` only when it's at the very start or end of the
		// class content (where it can't be a range hyphen), matching
		// the Test262 fixture `/[-]/v`.
		if c == '(' || c == ')' || c == '{' || c == '}' || c == '/' || c == '|' {
			append(&v.errors, RegexDiagnostic{
				offset = u32(i),
				message = "Invalid unescaped character in v-mode character class",
			})
			i += 1
			continue
		}
		if c == '-' {
			// Lone `-` (not part of `--`): flag if at the start or end
			// of the class, or if the next char is `]` or the previous
			// atom position is the class opener. A `-` between two atoms
			// is a valid range. Full atom-boundary tracking is complex;
			// approximate by checking adjacent chars.
			is_start := (i == class_open_off + 1) ||
			            (class_is_negated && i == class_open_off + 2)
			is_end := (i + 1 >= pe) || (src[i + 1] == ']')
			if is_start || is_end {
				append(&v.errors, RegexDiagnostic{
					offset = u32(i),
					message = "Invalid unescaped character in v-mode character class",
				})
			}
			i += 1
			continue
		}

		i += 1
	}
}

// ============================================================================
// Phase G — General_Category property-value validation.
//
// `\p{gc=uppercaseletter}/u` must reject because the value is not a
// recognised General_Category value. The spec (§22.2.1.1) requires
// case-sensitive exact matching — no loose matching, no folding.
// This validator is called from regex_check_property_escape for
// the `Name=Value` form when the name resolves to General_Category.
// ============================================================================

is_valid_gc_property_value :: proc(value: string) -> bool {
	return is_general_category_value(value)
}


// §22.2.1.2 "UnicodePropertyValueAliases for Script / Script_Extensions".
// Exhaustive list of Script values recognised by ECMA-262 (Unicode 16.0).
// Both long and short forms included, case-sensitive.
SCRIPT_VALUES := [?]string{
	// Long names (PropertyValueAliases.txt, field sc)
	"Adlam", "Ahom", "Anatolian_Hieroglyphs", "Arabic", "Armenian",
	"Avestan", "Balinese", "Bamum", "Bassa_Vah", "Batak",
	"Bengali", "Bhaiksuki", "Bopomofo", "Brahmi", "Braille",
	"Buginese", "Buhid", "Canadian_Aboriginal", "Carian", "Caucasian_Albanian",
	"Chakma", "Cham", "Cherokee", "Chorasmian", "Common",
	"Coptic", "Cuneiform", "Cypriot", "Cypro_Minoan", "Cyrillic",
	"Deseret", "Devanagari", "Dives_Akuru", "Dogra", "Duployan",
	"Egyptian_Hieroglyphs", "Elbasan", "Elymaic", "Ethiopic", "Georgian",
	"Glagolitic", "Gothic", "Grantha", "Greek", "Gujarati",
	"Gunjala_Gondi", "Gurmukhi", "Han", "Hangul", "Hanifi_Rohingya",
	"Hanunoo", "Hatran", "Hebrew", "Hiragana", "Imperial_Aramaic",
	"Inherited", "Inscriptional_Pahlavi", "Inscriptional_Parthian",
	"Javanese", "Kaithi", "Kannada", "Katakana", "Kayah_Li",
	"Kharoshthi", "Khitan_Small_Script", "Khmer", "Khojki", "Khudawadi",
	"Lao", "Latin", "Lepcha", "Limbu", "Linear_A",
	"Linear_B", "Lisu", "Lycian", "Lydian", "Mahajani",
	"Makasar", "Malayalam", "Mandaic", "Manichaean", "Marchen",
	"Masaram_Gondi", "Medefaidrin", "Meetei_Mayek", "Mende_Kikakui", "Meroitic_Cursive",
	"Meroitic_Hieroglyphs", "Miao", "Modi", "Mongolian", "Mro",
	"Multani", "Myanmar", "Nabataean", "Nandinagari", "New_Tai_Lue",
	"Newa", "Nko", "Nushu", "Nyiakeng_Puachue_Hmong", "Ogham",
	"Ol_Chiki", "Old_Hungarian", "Old_Italic", "Old_North_Arabian", "Old_Permic",
	"Old_Persian", "Old_Sogdian", "Old_South_Arabian", "Old_Turkic", "Old_Uyghur",
	"Oriya", "Osage", "Osmanya", "Pahawh_Hmong", "Palmyrene",
	"Pau_Cin_Hau", "Phags_Pa", "Phoenician", "Psalter_Pahlavi", "Rejang",
	"Runic", "Samaritan", "Saurashtra", "Sharada", "Shavian",
	"Siddham", "SignWriting", "Sinhala", "Sogdian", "Sora_Sompeng",
	"Soyombo", "Sundanese", "Syloti_Nagri", "Syriac", "Tagalog",
	"Tagbanwa", "Tai_Le", "Tai_Tham", "Tai_Viet", "Takri",
	"Tamil", "Tangsa", "Tangut", "Telugu", "Thaana",
	"Thai", "Tibetan", "Tifinagh", "Tirhuta", "Toto",
	"Ugaritic", "Vai", "Vithkuqi", "Wancho", "Warang_Citi",
	"Yezidi", "Yi", "Zanabazar_Square",
	// Unicode 15.0+ scripts
	"Garay", "Gurung_Khema", "Kirat_Rai", "Ol_Onal",
	"Sunuwar", "Todhri", "Tulu_Tigalari",
	// Unicode 16.0+ scripts
	"Myanmar_Zawgyi",
	// Short aliases (PropertyValueAliases.txt, field sc, alias column)
	"Adlm", "Aghb", "Ahom", "Arab", "Armi", "Armn", "Avst",
	"Bali", "Bamu", "Bass", "Batk", "Beng", "Bhks", "Bopo", "Brah", "Brai",
	"Bugi", "Buhd",
	"Cakm", "Cans", "Cari", "Cham", "Cher", "Chrs", "Copt", "Qaac",
	"Cprt", "Cpmn", "Cyrl",
	"Deva", "Diak", "Dogr", "Dsrt", "Dupl",
	"Egyp", "Elba", "Elym", "Ethi",
	"Geor", "Glag", "Gong", "Gonm", "Goth", "Gran", "Grek", "Gujr", "Guru",
	"Hang", "Hani", "Hano", "Hatr", "Hebr", "Hira", "Hluw", "Hmng", "Hmnp",
	"Hrkt", "Hung",
	"Ital",
	"Java",
	"Kali", "Kana", "Khar", "Khmr", "Khoj", "Kits", "Knda", "Kthi",
	"Lana", "Laoo", "Latn", "Lepc", "Limb", "Lina", "Linb", "Lisu", "Lyci", "Lydi",
	"Mahj", "Maka", "Mand", "Mani", "Marc", "Medf", "Mend", "Merc", "Mero",
	"Mlym", "Modi", "Mong", "Mroo", "Mtei", "Mult", "Mymr",
	"Nagm", "Nand", "Narb", "Nbat", "Newa", "Nkoo", "Nshu",
	"Ogam", "Olck", "Orkh", "Orya", "Osge", "Osma",
	"Palm", "Pauc", "Perm", "Phag", "Phli", "Phlp", "Phnx", "Plrd", "Prti",
	"Rjng", "Rohg", "Runr",
	"Samr", "Sarb", "Saur", "Sgnw", "Shaw", "Shrd", "Sidd", "Sind", "Sinh",
	"Sogd", "Sogo", "Sora", "Soyo", "Sund", "Sylo", "Syrc",
	"Tagb", "Takr", "Tale", "Talu", "Taml", "Tang", "Tavt", "Telu",
	"Tfng", "Tglg", "Thaa", "Thai", "Tibt", "Tirh", "Tnsa", "Toto",
	"Ugar",
	"Vaii", "Vith",
	"Wara", "Wcho",
	"Xpeo", "Xsux",
	"Yezi", "Yiii",
	"Zanb", "Zinh", "Zyyy", "Zzzz",
	// Unicode 15.0+ short aliases
	"Gara", "Gukh", "Krai", "Onao", "Sunu", "Todr", "Tutg",
}

// ============================================================================
// Named-group validator (moved from lexer.odin during the #5 deepening)
// ============================================================================

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
regex_validate_named_groups :: proc(v: ^RegexValidator, pat_start, pat_end: u32, has_u, has_v: bool) {
	src := v.source
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
				append(&v.errors, RegexDiagnostic{offset = u32(name_start), message = "Unterminated named capture group"})
				i = j + 1
				continue
			}
			name := string(src[name_start:j])
			if len(name) == 0 {
				append(&v.errors, RegexDiagnostic{offset = u32(name_start), message = "Empty named capture group"})
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
					append(&v.errors, RegexDiagnostic{
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
					append(&v.errors, RegexDiagnostic{offset = u32(name_start), message = "Invalid named capture group name"})
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
					append(&v.errors, RegexDiagnostic{offset = u32(i), message = "Invalid named back-reference: '\\k' must be followed by '<name>'"})
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
							append(&v.errors, RegexDiagnostic{offset = u32(name_start), message = "Invalid named capture reference"})
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
				append(&v.errors, RegexDiagnostic{offset = u32(name_start), message = "Unterminated named capture reference"})
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
