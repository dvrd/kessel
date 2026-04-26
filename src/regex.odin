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
	}

	// Arithmetic modifiers `(?ims-ims:body)` (ES2025 RegExp Modifier
	// Sequence proposal). Always-on — the syntax is well-formed in
	// non-u mode too.
	regex_validate_modifiers(l, pat_start, pat_end)

	// Named-group declarations + `\k<name>` references.
	regex_validate_named_groups(l, pat_start, pat_end)
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
