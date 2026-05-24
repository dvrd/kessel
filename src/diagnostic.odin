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
//   K3xxx (3000–3999): early errors (ECMA-262 §15–§17)
//   K4xxx (4000–4999): TypeScript parser-level (overload / ambient / modifier rules)
//
// `None` (zero) is the legacy sentinel for un-migrated call sites.
ErrorCode :: enum u16 {
	None                                          = 0,

	// K1xxx — lexer.
	K1010_InvalidNumericLiteral                   = 1010,
	K1011_InvalidEscapeSequence                   = 1011,
	K1012_InvalidRegex                            = 1012,
	K1013_UnterminatedString                      = 1013,
	K1014_InvalidIdentifier                       = 1014,
	K1015_UnterminatedComment                     = 1015,

	// K2xxx — parser syntax
	K2002_ExpectedToken                           = 2002,  // "Expected X, got Y" — generic
	K2003_ExpectedTypeElement                     = 2003,  // empty tuple / type-arg / type-param slot

	// K3xxx — ECMA-262 early errors. Phase 4 first slice covers the
	// await/yield/async/generator family (§15.5 — AsyncFunction,
	// AsyncGenerator, GeneratorDeclaration; §13.3.7.1 — IdentifierReference
	// reserved-word rules; §14.7.1 — for-of restrictions; §12.7.2 —
	// keywords-with-escapes).
	K3010_AwaitYieldAsBindingName                 = 3010,
	K3011_AwaitYieldExpressionContextRestricted   = 3011,
	K3012_AsyncGeneratorMisplaced                 = 3012,
	K3013_ForAwaitContextRestricted               = 3013,
	K3014_AwaitUsingContextRestricted             = 3014,
	K3015_KeywordContainsEscape                   = 3015,

	// Module syntax (§16, §13.3.12 — import / export / import.meta
	// / dynamic import / import attributes).
	K3020_ImportExportNameOrBinding               = 3020,
	K3021_ExportDefaultRestrictions               = 3021,
	K3022_ModuleSyntaxInScript                    = 3022,
	K3023_ImportMetaOrDynamicImportInvalid        = 3023,
	K3024_ImportAttributeInvalid                  = 3024,

	// Class (§15.7 — ClassDefinitions, §13.2.7 — PrivateName).
	K3030_ClassDeclarationStructure               = 3030,
	K3031_StaticBlockOrFieldInitRestriction       = 3031,
	K3032_PrivateNameInvalid                      = 3032,
	K3033_SuperInvalidContext                     = 3033,
	K3034_ConstructorShape                        = 3034,
	K3035_GetterSetterParam                       = 3035,
	K3036_ObjectLiteralDuplicate                  = 3036,

	// Destructuring, rest, spread (§14.3.3 — BindingPattern,
	// §15.7 — RestElement, §13.3 — SpreadElement).
	K3040_RestNotLast                             = 3040,
	K3041_RestForm                                = 3041,
	K3042_RestSpreadMisuse                        = 3042,
	K3043_DestructuringInvalid                    = 3043,

	// K4xxx — TypeScript parser-level rules.
	K4010_TypeOnlyImportExportInvalid             = 4010,
	K4020_ConstructorTSModifier                   = 4020,
	K4021_PrivateNameWithModifier                 = 4021,
	K4022_ParameterPropertyOnlyInCtor             = 4022,
	K4023_NamespaceMergeOrder                     = 4023,

	// TypeScript modifier rules.
	K4030_ModifierOrder                           = 4030,
	K4031_DuplicateModifier                       = 4031,
	K4032_ModifierMisplaced                       = 4032,
	K4033_DecoratorOrder                          = 4033,
	K4034_AbstractNewline                         = 4034,
	K4040_TSRestInvalid                           = 4040,
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

	// ------------------------------------------------------------------
	// K3010 — `await` or `yield` used as a binding name where reserved.
	//   Covers: identifier reference, label, function/class declaration
	//   name, arrow parameter, shorthand-property identifier.
	//   Spec: §13.3.7.1 IdentifierReference, §14.13 LabelledStatement.
	case .K3010_AwaitYieldAsBindingName:
		return ErrorInfo{
			default_message = "'await' or 'yield' cannot be used as a binding name in this context",
			hint            = "rename the binding; `await`/`yield` are reserved inside modules / async functions / generators",
			ts_code         = "TS1100",
			severity        = .Error,
		}

	// K3011 — `await` or `yield` expression in a position the spec disallows.
	//   Covers: `await` in class static block / field initializer /
	//   formal parameters / outside async; `yield` in formal parameters /
	//   outside generator / as operand of unary / binary / conditional.
	//   Spec: §14.8 (AwaitExpression), §15.5 (YieldExpression).
	case .K3011_AwaitYieldExpressionContextRestricted:
		return ErrorInfo{
			default_message = "'await' or 'yield' expression is not allowed in this context",
			hint            = "",
			ts_code         = "TS1308",   // covers the most common case (await outside async)
			severity        = .Error,
		}

	// K3012 — async / generator function / method / accessor / shorthand
	//   placed in a position the spec does not permit (single-statement
	//   context, labeled item, constructor, accessor body, etc.), or
	//   `async` used as a for-of LHS or as a misplaced modifier.
	case .K3012_AsyncGeneratorMisplaced:
		return ErrorInfo{
			default_message = "async or generator construct is not allowed in this position",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K3013 — `for await ... of` in a context that disallows it (class
	//   static block; outside an async function and outside module top-level).
	case .K3013_ForAwaitContextRestricted:
		return ErrorInfo{
			default_message = "'for await' is not allowed in this context",
			hint            = "`for await` is only valid in async functions or at the top level of a module",
			ts_code         = "",
			severity        = .Error,
		}

	// K3014 — `await using` restrictions: at script top-level (not module);
	//   line-terminator between the `await` and `using` tokens (Stage-3
	//   Explicit Resource Management).
	case .K3014_AwaitUsingContextRestricted:
		return ErrorInfo{
			default_message = "'await using' is not allowed in this context",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K3015 — a keyword token (`async`, `type`, ...) contained Unicode
	//   escapes. Per §12.7.2 keywords are matched by raw lexeme; an
	//   identifier that reduces to a reserved word via escapes is rejected.
	case .K3015_KeywordContainsEscape:
		return ErrorInfo{
			default_message = "keyword must not contain Unicode escape sequences",
			hint            = "write the keyword using its raw characters — escapes turn it into an identifier",
			ts_code         = "",
			severity        = .Error,
		}

	// ------------------------------------------------------------------
	// K3020 — import / export name or binding is invalid: numeric or
	//   bigint literal in name position, unpaired surrogates in a
	//   string-form name, or reserved word as a local exported binding
	//   without an `as` clause.
	case .K3020_ImportExportNameOrBinding:
		return ErrorInfo{
			default_message = "import or export name / binding is not valid here",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K3021 — `export default` and `using` / `await using` exports have
	//   specific restrictions: cannot default-export a variable
	//   declaration; cannot directly export a `using` declaration.
	case .K3021_ExportDefaultRestrictions:
		return ErrorInfo{
			default_message = "this declaration cannot follow 'export default'",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K3022 — module-only syntax (`import.meta`, top-level `await`) used
	//   in script source. The source must be a Module — mark the file
	//   `.mjs`, use `import` / `export`, or set `"type": "module"`.
	case .K3022_ModuleSyntaxInScript:
		return ErrorInfo{
			default_message = "this syntax is only valid in module code",
			hint            = "make the source a Module — add an `import` / `export`, rename to `.mjs`, or set `\"type\": \"module\"`",
			ts_code         = "",
			severity        = .Error,
		}

	// K3023 — `import.meta` and dynamic `import()` restrictions:
	//   `import.meta` property name must be a raw identifier; dynamic
	//   `import()` cannot be invoked with `new` and cannot take `...spread`.
	case .K3023_ImportMetaOrDynamicImportInvalid:
		return ErrorInfo{
			default_message = "invalid use of 'import.meta' or dynamic 'import()'",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K3024 — import attribute (`with { key: value }`) restrictions:
	//   numeric / bigint literal as a key; spread element inside the
	//   attribute block.
	case .K3024_ImportAttributeInvalid:
		return ErrorInfo{
			default_message = "invalid form in an import attribute block",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// ------------------------------------------------------------------
	// K4010 — TypeScript type-only import / export restrictions:
	//   `type` modifier on an already-type-only specifier; combining
	//   default and named bindings in a type-only import.
	case .K4010_TypeOnlyImportExportInvalid:
		return ErrorInfo{
			default_message = "invalid form in a type-only import or export",
			hint            = "",
			ts_code         = "TS1363",
			severity        = .Error,
		}

	// ------------------------------------------------------------------
	// K3030 — class declaration shape: declaration in single-statement
	//   context; field named 'constructor'; static member 'prototype';
	//   private member name '#constructor'; reserved word as class name;
	//   array literal as computed member name.
	case .K3030_ClassDeclarationStructure:
		return ErrorInfo{
			default_message = "class declaration form is invalid here",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K3031 — restrictions inside a class static block or a class field
	//   initializer: `return`, `arguments` are not bound there.
	case .K3031_StaticBlockOrFieldInitRestriction:
		return ErrorInfo{
			default_message = "this construct is not allowed in a class static block or field initializer",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K3032 — private name (`#x`) used in an invalid position: outside
	//   any class; with whitespace after `#`; via `super.#x`.
	case .K3032_PrivateNameInvalid:
		return ErrorInfo{
			default_message = "private name is not valid in this position",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K3033 — `super` used in a context the spec disallows: `super()`
	//   outside a derived constructor; `super.x` outside a method;
	//   `new super(...)`.
	case .K3033_SuperInvalidContext:
		return ErrorInfo{
			default_message = "'super' is not valid in this context",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K3034 — class constructor shape: cannot be a getter or setter;
	//   class field cannot be named 'constructor'; cannot have multiple
	//   constructor implementations.
	case .K3034_ConstructorShape:
		return ErrorInfo{
			default_message = "invalid class constructor form",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K3035 — getter / setter parameter list violations: a getter must
	//   take zero parameters; a setter parameter cannot be a rest element.
	case .K3035_GetterSetterParam:
		return ErrorInfo{
			default_message = "invalid getter or setter parameter list",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K3036 — object literal duplicates: multiple data properties with
	//   the same name in strict mode; multiple get/set accessors with
	//   the same name (§13.2.5.1).
	case .K3036_ObjectLiteralDuplicate:
		return ErrorInfo{
			default_message = "duplicate property in object literal",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// ------------------------------------------------------------------
	// K1010 — numeric literal forms: malformed digit groups, BigInt
	//   restrictions, legacy octal restrictions, missing exponent,
	//   numeric separator placement.
	case .K1010_InvalidNumericLiteral:
		return ErrorInfo{
			default_message = "invalid numeric literal",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K1011 — backslash escape sequence is malformed: short \x or \u
	//   escapes, \u{} out of range / missing brace, invalid Unicode
	//   escape in identifier.
	case .K1011_InvalidEscapeSequence:
		return ErrorInfo{
			default_message = "invalid escape sequence",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K1012 — regular expression literal: invalid flag, duplicate flag,
	//   incompatible flag combination, unterminated pattern / group /
	//   character class, trailing backslash, escape-before-newline.
	case .K1012_InvalidRegex:
		return ErrorInfo{
			default_message = "invalid regular expression",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K1013 — string literal not terminated before EOF or end-of-line.
	case .K1013_UnterminatedString:
		return ErrorInfo{
			default_message = "unterminated string literal",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K1014 — identifier contains a character not in ID_Start /
	//   ID_Continue, or an isolated invalid character at the lex level.
	case .K1014_InvalidIdentifier:
		return ErrorInfo{
			default_message = "invalid character in identifier",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K1015 — block comment not terminated before EOF.
	case .K1015_UnterminatedComment:
		return ErrorInfo{
			default_message = "unterminated block comment",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K4020 — TypeScript modifier (`abstract`, `override`, `declare`,
	//   `type-param`, type-annotation) used on a constructor declaration.
	case .K4020_ConstructorTSModifier:
		return ErrorInfo{
			default_message = "this TypeScript modifier cannot appear on a constructor declaration",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K4021 — TypeScript modifier combined with a private name where the
	//   spec disallows it: `abstract` + `#x`, accessibility + `#x`.
	case .K4021_PrivateNameWithModifier:
		return ErrorInfo{
			default_message = "this modifier cannot be used with a private identifier",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K4022 — TypeScript parameter property used outside a constructor.
	case .K4022_ParameterPropertyOnlyInCtor:
		return ErrorInfo{
			default_message = "parameter property modifiers are only allowed in constructors",
			hint            = "",
			ts_code         = "TS2369",
			severity        = .Error,
		}

	// K4023 — TypeScript declaration merging order: a namespace
	//   declaration cannot be located prior to the class or function
	//   with which it is merged.
	case .K4023_NamespaceMergeOrder:
		return ErrorInfo{
			default_message = "namespace declaration must follow the class or function it merges with",
			hint            = "",
			ts_code         = "TS2434",
			severity        = .Error,
		}

	// K4030 — TypeScript modifiers appear in a fixed order; this site
	//   saw modifier X after modifier Y where X must precede Y.
	case .K4030_ModifierOrder:
		return ErrorInfo{
			default_message = "TypeScript modifiers are out of order",
			hint            = "",
			ts_code         = "TS1029",
			severity        = .Error,
		}

	// K4031 — the same modifier appeared twice on a single declaration
	//   (e.g. two accessibility modifiers, two `export` keywords).
	case .K4031_DuplicateModifier:
		return ErrorInfo{
			default_message = "modifier already seen",
			hint            = "",
			ts_code         = "TS1030",
			severity        = .Error,
		}

	// K4032 — a modifier is not permitted in this position: on a
	//   parameter, index signature, type member, in an ambient context,
	//   or in JavaScript when the modifier is TypeScript-only.
	case .K4032_ModifierMisplaced:
		return ErrorInfo{
			default_message = "this modifier is not allowed here",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K4033 — decorators must precede the `abstract` modifier on a
	//   class declaration.
	case .K4033_DecoratorOrder:
		return ErrorInfo{
			default_message = "decorators must precede the 'abstract' modifier",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K4034 — line terminator not permitted between `abstract` and the
	//   following `class` token.
	case .K4034_AbstractNewline:
		return ErrorInfo{
			default_message = "line terminator not permitted between 'abstract' and 'class'",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// ------------------------------------------------------------------
	// K3040 — a rest element / rest parameter / rest property is not in
	//   the final position of its parameter list or binding pattern.
	case .K3040_RestNotLast:
		return ErrorInfo{
			default_message = "rest element must be last",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K3041 — rest element has an invalid form: trailing comma after
	//   the rest element; default initializer on rest; rest property
	//   as a binding pattern; rest parameter marked optional.
	case .K3041_RestForm:
		return ErrorInfo{
			default_message = "invalid rest element form",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K3042 — spread / rest used in a position that the spec disallows:
	//   spread in expression; spread of spread; rest in non-pattern
	//   target; rest parameter without parentheses; ill-formed rest
	//   argument.
	case .K3042_RestSpreadMisuse:
		return ErrorInfo{
			default_message = "invalid use of rest or spread",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K3043 — destructuring pattern shape is invalid: missing
	//   initializer; missing colon in `{ "x" }` form; non-pattern as
	//   binding target; for-in LHS pattern not allowed; parameter
	//   property as a pattern.
	case .K3043_DestructuringInvalid:
		return ErrorInfo{
			default_message = "invalid destructuring pattern",
			hint            = "",
			ts_code         = "",
			severity        = .Error,
		}

	// K4040 — TypeScript-specific rest/parameter restrictions: index
	//   signature parameter cannot be a rest pattern; set accessor
	//   parameter cannot be a rest parameter.
	case .K4040_TSRestInvalid:
		return ErrorInfo{
			default_message = "this TypeScript signature cannot use a rest parameter",
			hint            = "",
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
