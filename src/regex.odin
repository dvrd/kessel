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

	// Named-group declarations + `\k<name>` references.
	regex_validate_named_groups(l, pat_start, pat_end)
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
