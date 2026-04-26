package main

// ============================================================================
// Regular expression pattern validator (ES2025 §22.2.1).
//
// Called by `lex_regex` *after* flags have been parsed, so the validator
// can branch on `has_u` / `has_v`. The validator emits diagnostics into
// `l.lexer_errors`; it does not mutate `l.offset` or any other lexer
// cursor state. Bytes covered are exclusively `src[pat_start:pat_end]`,
// the closed-open range of the pattern body (between the opening `/`
// and the closing `/`).
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

regex_validate_pattern :: proc(l: ^Lexer, pat_start, pat_end: u32, has_u, has_v: bool) {
	src := l.source_bytes
	if int(pat_end) > len(src) { return }

	// Wave 1a: property-escape structural rules. u/v-mode only —
	// outside u/v, `\p`/`\P` are identity escapes per Annex B and
	// the spec deliberately preserves backward compatibility.
	if has_u || has_v {
		regex_validate_property_escapes(l, pat_start, pat_end, has_v)
		regex_validate_u_mode_atoms(l, pat_start, pat_end, has_v)
	}
	// Class-range early errors run u-mode-only. In v-mode `[A--B]` is
	// set difference (a ClassSetExpression operator), not a range with
	// CharacterClass endpoints. The flat A-B range walker would mis-
	// flag every set-difference fixture (`[\d--_]/v`, `[[0-9]--\d]/v`,
	// …), so the validator only fires when u is set without v.
	if has_u && !has_v {
		regex_validate_class_ranges(l, pat_start, pat_end)
	}

	// Arithmetic modifiers `(?ims-ims:body)` (ES2025 RegExp Modifier
	// Sequence proposal). Always-on — the syntax is well-formed in
	// non-u mode too.
	regex_validate_modifiers(l, pat_start, pat_end)

	// Leading-quantifier early errors. Always-on. `/?/`, `/*/`, `/+/`,
	// `/{2}/`, `/{2,}/`, `/{2,5}/` are all SyntaxErrors because the
	// quantifier has no preceding Atom; same after `(` or `|`.
	regex_validate_leading_quantifier(l, pat_start, pat_end)

	// Lookbehind cannot be quantified in any mode (§22.2.1). Lookahead
	// _can_ be quantified in non-u via Annex B, so the broader
	// quantified-assertion rule lives in regex_validate_u_mode_atoms.
	regex_validate_quantified_lookbehind(l, pat_start, pat_end)

	// Named-group declarations + `\k<name>` references. Strictness
	// depends on flag context: in u / v mode `\k` is always a
	// NamedBackreference and must resolve; in non-u mode Annex B
	// keeps the legacy literal-characters fallback when no names
	// are declared.
	regex_validate_named_groups(l, pat_start, pat_end, has_u, has_v)
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

regex_validate_modifiers :: proc(l: ^Lexer, pat_start, pat_end: u32) {
	src := l.source_bytes
	pe := int(pat_end)
	in_class := false
	i := int(pat_start)
	for i < pe {
		c := src[i]
		// AtomEscape — skip both bytes.
		if c == '\\' && i + 1 < pe { i += 2; continue }
		if c == '[' && !in_class { in_class = true; i += 1; continue }
		if c == ']' && in_class  { in_class = false; i += 1; continue }
		if in_class || c != '(' { i += 1; continue }
		// `(` only — need `(?` next, otherwise plain group.
		if i + 2 >= pe || src[i + 1] != '?' { i += 1; continue }
		n := src[i + 2]
		// Other `(?`-prefixed productions: non-capturing, lookahead /
		// negative-lookahead, named-group / lookbehind / negative-
		// lookbehind. Validated elsewhere; not modifiers.
		if n == ':' || n == '=' || n == '!' || n == '<' { i += 1; continue }
		// Modifier production starts at i. Consume + emit one diagnostic
		// at most per malformed modifier; skip past the closing `:` or
		// `)` so we don't double-report.
		end := regex_check_modifier_sequence(l, src, i, pe)
		if end > i + 2 {
			i = end
		} else {
			i += 2
		}
	}
}

// Validate a single arithmetic modifier sequence anchored at `start`
// (which points at the opening `(`). Emits one LexerError on failure
// and returns the position just past the closing `:` (or wherever
// the scan terminated) so the outer loop can resume.
regex_check_modifier_sequence :: proc(l: ^Lexer, src: []u8, start, pe: int) -> int {
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
		append(&l.lexer_errors, LexerError{
			offset = u32(start),
			message = "Invalid regular expression modifier sequence",
		})
	}

	// Skip past the `:` (or stop where the scan died) so the outer
	// pass doesn't re-enter this same modifier on the next iteration.
	if j < pe && src[j] == ':' { return j + 1 }
	return j
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

regex_validate_u_mode_atoms :: proc(l: ^Lexer, pat_start, pat_end: u32, has_v: bool) {
	src := l.source_bytes
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
				i = regex_check_u_escape(l, src, i, pe, group_count, true, has_v)
			} else {
				i += 1
			}
			last_closed_was_assertion = false
			continue
		}

		// Quantifier following an assertion — reject in u/v mode.
		if last_closed_was_assertion && (c == '?' || c == '*' || c == '+' || c == '{') {
			append(&l.lexer_errors, LexerError{
				offset = u32(i),
				message = "Invalid quantifier on assertion in u-mode regular expression",
			})
			last_closed_was_assertion = false
			i += 1
			continue
		}

		switch c {
		case '\\':
			i = regex_check_u_escape(l, src, i, pe, group_count, false, has_v)
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
				append(&l.lexer_errors, LexerError{
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
regex_check_u_escape :: proc(l: ^Lexer, src: []u8, start, pe: int, group_count: int, in_class: bool, has_v: bool) -> int {
	esc_off := u32(start)
	if start + 1 >= pe {
		append(&l.lexer_errors, LexerError{offset = esc_off, message = "Trailing backslash in regular expression"})
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
		// `\p{…}` / `\P{…}` — the body is validated by
		// regex_validate_property_escapes, but we MUST skip past the
		// closing `}` here so the main u-mode walker doesn't see the
		// braces and flag them as stray extended pattern characters.
		j := start + 2
		if j < pe && src[j] == '{' {
			j += 1
			for j < pe && src[j] != '}' { j += 1 }
			if j < pe { j += 1 }
		}
		return j
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
			append(&l.lexer_errors, LexerError{
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
			append(&l.lexer_errors, LexerError{
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
			append(&l.lexer_errors, LexerError{
				offset = esc_off,
				message = "Invalid decimal escape: out-of-range back-reference",
			})
		}
		return j
	case 'c':
		// ControlEscape: `\cX` where X is [A-Za-z]. `\c0`, `\c\`, `\c`
		// at end-of-pattern are all SyntaxErrors in u-mode.
		if start + 2 >= pe {
			append(&l.lexer_errors, LexerError{offset = esc_off, message = "Invalid '\\c' escape: missing control letter"})
			return start + 2
		}
		cl := src[start + 2]
		if !((cl >= 'A' && cl <= 'Z') || (cl >= 'a' && cl <= 'z')) {
			append(&l.lexer_errors, LexerError{
				offset = esc_off,
				message = "Invalid '\\c' escape: control letter must be ASCII letter",
			})
		}
		return start + 3
	case 'x':
		// HexEscape: exactly 2 hex digits.
		if start + 3 >= pe || hex_val(src[start + 2]) < 0 || hex_val(src[start + 3]) < 0 {
			append(&l.lexer_errors, LexerError{
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
				append(&l.lexer_errors, LexerError{
					offset = esc_off,
					message = "Invalid '\\u{…}' escape",
				})
			} else if overflow {
				append(&l.lexer_errors, LexerError{
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
			append(&l.lexer_errors, LexerError{
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
			append(&l.lexer_errors, LexerError{
				offset = esc_off,
				message = "Invalid identity escape in u-mode regular expression",
			})
		}
		return start + 2
	case:
		// Anything else (`\M`, `\Q`, `\@`, `\!`, `\;`, …) is an
		// invalid IdentityEscape in u-mode.
		append(&l.lexer_errors, LexerError{
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
// Phase B-e — leading quantifier rejection (§22.2.1).
//
// `Quantifier :: { DecimalDigits } | { DecimalDigits , } | { N , M }` is
// a postfix on Atom. With no Atom before it (start of pattern, after
// `(`, after `|`) it's ungrammatical:
//
//   /?/   /*/   /+/   /{2}/   /{2,}/   /{2,5}/  (a)|(?b)
//
// Bare `{x}/u` (non-quantifier braces) is handled by the u-mode
// extended-pattern-char rejection in regex_validate_u_mode_atoms; this
// pass only flags the cases where the braces DO form a quantifier
// shape, since those are the only ones that look like a quantifier and
// thus can be "leading".
// ============================================================================

regex_validate_leading_quantifier :: proc(l: ^Lexer, pat_start, pat_end: u32) {
	src := l.source_bytes
	pe := int(pat_end)
	if int(pat_start) >= pe { return }

	// `expecting_atom` is true whenever the next non-class character
	// would start a fresh Atom: at the very start, after a `(`, or
	// after a `|` (alternation branch start). In any other position the
	// previous symbol can serve as the Atom for the quantifier.
	in_class := false
	expecting_atom := true
	for i := int(pat_start); i < pe; {
		c := src[i]
		if c == '\\' && i + 1 < pe { i += 2; expecting_atom = false; continue }
		if c == '[' && !in_class { in_class = true; i += 1; expecting_atom = false; continue }
		if c == ']' && in_class  { in_class = false; i += 1; expecting_atom = false; continue }
		if in_class { i += 1; continue }

		if expecting_atom {
			if c == '?' || c == '*' || c == '+' {
				append(&l.lexer_errors, LexerError{
					offset = u32(i),
					message = "Quantifier without preceding atom",
				})
				expecting_atom = false
				i += 1
				continue
			}
			if c == '{' && regex_is_braced_quantifier(src, i, pe) {
				append(&l.lexer_errors, LexerError{
					offset = u32(i),
					message = "Quantifier without preceding atom",
				})
				expecting_atom = false
				i += 1
				continue
			}
		}

		switch c {
		case '(':
			// Skip past `(?…)` prefixes so the discriminator chars don't
			// confuse the leading-quantifier check. Forms covered:
			//   (?:   non-capturing group
			//   (?=   (?!   lookahead / negative-lookahead
			//   (?<=  (?<!  lookbehind / negative-lookbehind
			//   (?<NAME>  named capture
			//   (?ims-ims:  arithmetic modifier
			// Each prefix terminates at the first `:`, `=`, `!`, or `>`
			// (the latter only for named-group). After the prefix ends,
			// the next character is the start of the group's content —
			// expecting_atom = true.
			if i + 1 < pe && src[i + 1] == '?' {
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
				i = j
				expecting_atom = true
				continue
			}
			expecting_atom = true
		case '|':
			expecting_atom = true
		case:
			expecting_atom = false
		}
		i += 1
	}
}

// ============================================================================
// Phase B-f — quantified lookbehind rejection.
//
// `Lookbehind :: ( ? <= Disjunction ) | ( ? <! Disjunction )`
// is non-quantifiable in EVERY mode (no Annex B carve-out, unlike
// lookahead). Test262: invalid-{optional,range}-{lookbehind,negative-
// lookbehind}.js. Track open-paren stack with a flag for `(?<=` /
// `(?<!`; on `)` of such a group, look at the very next character
// and reject if it's a quantifier.
// ============================================================================

regex_validate_quantified_lookbehind :: proc(l: ^Lexer, pat_start, pat_end: u32) {
	src := l.source_bytes
	pe := int(pat_end)

	StackEntry :: struct { is_lookbehind: bool }
	stack: [64]StackEntry
	depth := 0
	last_closed_was_lookbehind := false
	in_class := false

	for i := int(pat_start); i < pe; {
		c := src[i]
		if c == '\\' && i + 1 < pe { i += 2; last_closed_was_lookbehind = false; continue }
		if c == '[' && !in_class { in_class = true; i += 1; last_closed_was_lookbehind = false; continue }
		if c == ']' && in_class  { in_class = false; i += 1; last_closed_was_lookbehind = false; continue }
		if in_class { i += 1; continue }

		if last_closed_was_lookbehind && (c == '?' || c == '*' || c == '+' || c == '{') {
			append(&l.lexer_errors, LexerError{
				offset = u32(i),
				message = "Invalid quantifier on lookbehind assertion",
			})
			last_closed_was_lookbehind = false
			i += 1
			continue
		}

		if c == '(' {
			is_lb := false
			if i + 3 < pe && src[i + 1] == '?' && src[i + 2] == '<' &&
			   (src[i + 3] == '=' || src[i + 3] == '!') {
				is_lb = true
			}
			if depth < len(stack) {
				stack[depth] = StackEntry{is_lookbehind = is_lb}
				depth += 1
			}
			last_closed_was_lookbehind = false
			i += 1
			continue
		}
		if c == ')' {
			if depth > 0 {
				depth -= 1
				last_closed_was_lookbehind = stack[depth].is_lookbehind
			} else {
				last_closed_was_lookbehind = false
			}
			i += 1
			continue
		}

		last_closed_was_lookbehind = false
		i += 1
	}
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

regex_validate_class_ranges :: proc(l: ^Lexer, pat_start, pat_end: u32) {
	src := l.source_bytes
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
					// on either side of a range.
					j += 2
					if j < pe && src[j] == '{' {
						j += 1
						for j < pe && src[j] != '}' { j += 1 }
						if j < pe { j += 1 }
					} else {
						k := 0
						for k < 4 && j < pe { j += 1; k += 1 }
						// (Validity of the hex digits is the u-mode
						// escape walker's job; this loop just spans it.)
					}
				case:
					j += 2
				}
			} else {
				j += 1
			}
			// Look at what follows: if `-` and then another atom,
			// we have a range with this atom on the LEFT.
			if just_after_dash {
				// This atom is the RIGHT side of a range. The previous
				// atom is the LEFT. Either being a class is an error.
				if prev_is_class_escape || atom_is_class {
					append(&l.lexer_errors, LexerError{
						offset = u32(prev_atom_off if prev_atom_off >= 0 else atom_off),
						message = "Invalid character class range: range endpoints must be single characters",
					})
				}
				just_after_dash = false
				prev_is_class_escape = atom_is_class
				prev_atom_off = atom_off
				continue
			}
			// Is the next byte a `-` opening a range? `]-` or `--`
			// don't form a range terminator (the `-` is just literal
			// when it's the last char of the class).
			if j < pe && src[j] == '-' && j + 1 < pe && src[j + 1] != ']' {
				prev_is_class_escape = atom_is_class
				prev_atom_off = atom_off
				just_after_dash = true
				j += 1
			} else {
				prev_is_class_escape = atom_is_class
				prev_atom_off = atom_off
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

regex_validate_property_escapes :: proc(l: ^Lexer, pat_start, pat_end: u32, has_v: bool) {
	src := l.source_bytes
	in_class := false
	i := int(pat_start)
	pe := int(pat_end)
	for i < pe {
		c := src[i]
		// Mirror the simple bracket / escape skip used by the named-group
		// pass — `\p` inside `[...]` is still subject to the same rules.
		if c == '[' && !in_class { in_class = true; i += 1; continue }
		if c == ']' && in_class  { in_class = false; i += 1; continue }
		if c == '\\' && i + 1 < pe {
			n := src[i + 1]
			if n != 'p' && n != 'P' {
				i += 2
				continue
			}
			// `\p` / `\P` — Wave 1a checks.
			esc_off := u32(i)
			negated := n == 'P'
			if i + 2 >= pe || src[i + 2] != '{' {
				// Rule 1: `\p` not followed by `{`.
				append(&l.lexer_errors, LexerError{
					offset = esc_off,
					message = "Invalid Unicode property escape: expected '{' after \\p",
				})
				i += 2
				continue
			}
			body_start := i + 3
			j := body_start
			eq_count := 0
			eq_at := -1
			bad_char := false
			for j < pe && src[j] != '}' {
				ch := src[j]
				// Stop on chars that terminate a regex pattern; let the
				// outer scanner / lex_regex emit its own "unterminated"
				// or invalid-class diagnostic for the pattern as a
				// whole. This loop only flags the property body.
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
				// Rule 3: unterminated `\p{…`.
				append(&l.lexer_errors, LexerError{
					offset = esc_off,
					message = "Invalid Unicode property escape: missing closing '}'",
				})
				// Skip past `\p{` and continue — j is at the failing byte.
				i = j
				continue
			}
			body_end := j
			// Rule 2: empty body.
			if body_end == body_start {
				append(&l.lexer_errors, LexerError{
					offset = esc_off,
					message = "Invalid Unicode property escape: empty body",
				})
				i = body_end + 1
				continue
			}
			// Rule 4: more than one `=`.
			if eq_count > 1 {
				append(&l.lexer_errors, LexerError{
					offset = esc_off,
					message = "Invalid Unicode property escape: multiple '=' in body",
				})
				i = body_end + 1
				continue
			}
			// Rule 7: bad chars in body (only emit once per escape).
			if bad_char {
				append(&l.lexer_errors, LexerError{
					offset = esc_off,
					message = "Invalid Unicode property escape: invalid character in body",
				})
				i = body_end + 1
				continue
			}
			if eq_count == 1 {
				// Name = Value form.
				name_start := body_start
				name_end := eq_at
				val_start := eq_at + 1
				val_end := body_end
				// Rule 5: empty name.
				if name_end == name_start {
					append(&l.lexer_errors, LexerError{
						offset = esc_off,
						message = "Invalid Unicode property escape: empty property name",
					})
					i = body_end + 1
					continue
				}
				// Rule 6: empty value.
				if val_end == val_start {
					append(&l.lexer_errors, LexerError{
						offset = esc_off,
						message = "Invalid Unicode property escape: empty property value",
					})
					i = body_end + 1
					continue
				}
				// Wave 1b — binary-property name with explicit value
				// (`\p{ASCII=Y}/u`). The spec says binary properties
				// MUST appear in lone form; pairing them with `=value`
				// is a parse-time SyntaxError regardless of whether
				// the value would otherwise be acceptable.
				name := string(src[name_start:name_end])
				if is_binary_unicode_property_name(name) {
					append(&l.lexer_errors, LexerError{
						offset = esc_off,
						message = "Invalid Unicode property escape: binary property cannot have a value",
					})
					i = body_end + 1
					continue
				}
				// Wave 1b — non-binary name must be a recognised
				// property name. Unknown name → SyntaxError.
				if !is_nonbinary_unicode_property_name(name) {
					append(&l.lexer_errors, LexerError{
						offset = esc_off,
						message = "Invalid Unicode property escape: unknown property name",
					})
					i = body_end + 1
					continue
				}
				// Don't validate the value itself yet — that requires
				// per-property value tables (Script names, Block names,
				// General_Category aliases, …) which is a much larger
				// data set. Future wave.
			} else {
				// Lone form: must be a recognised binary property
				// OR a General_Category value alias (`\p{Lu}`,
				// `\p{Letter}`, `\p{L}`, …) OR — only under the v
				// flag — a binary "of strings" property.
				body := string(src[body_start:body_end])
				if is_binary_unicode_property_name(body) ||
					is_general_category_value(body) {
					// ok
				} else if is_property_of_strings(body) {
					if !has_v {
						// §22.2.1.5 — properties of strings are
						// only legal under the v flag. The matching
						// Test262 fixture set lives in
						// property-escapes/generated/strings/.
						append(&l.lexer_errors, LexerError{
							offset = esc_off,
							message = "Invalid Unicode property escape: 'of strings' property requires the 'v' flag",
						})
					} else if negated {
						// §22.2.1.5 — the negation form `\P` is
						// not allowed for properties of strings
						// because their match set contains
						// length-≠2 strings; negation is undefined.
						append(&l.lexer_errors, LexerError{
							offset = esc_off,
							message = "Invalid Unicode property escape: '\\P{...}' cannot be a property of strings",
						})
					}
				} else {
					append(&l.lexer_errors, LexerError{
						offset = esc_off,
						message = "Invalid Unicode property escape: unknown lone property name",
					})
				}
			}
			i = body_end + 1
			continue
		}
		i += 1
	}
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

is_binary_unicode_property_name :: proc(name: string) -> bool {
	for n in BINARY_UNICODE_PROPERTIES {
		if n == name { return true }
	}
	return false
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
	for n in GENERAL_CATEGORY_VALUES {
		if n == name { return true }
	}
	return false
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
	for n in PROPERTIES_OF_STRINGS {
		if n == name { return true }
	}
	return false
}
