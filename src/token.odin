package main

// TokenType represents all JavaScript token types
TokenType :: enum {
	// Literals
	Null,
	True,
	False,
	Number,
	String,
	BigInt,
	RegularExpression,
	Template,
	TemplateHead,
	TemplateMiddle,
	TemplateTail,

	// Keywords
	Break,
	Case,
	Catch,
	Class,
	Const,
	Continue,
	Debugger,
	Default,
	Delete,
	Do,
	Else,
	Export,
	Extends,
	Finally,
	For,
	Function,
	If,
	Import,
	In,
	Instanceof,
	Let,
	New,
	Return,
	Super,
	Switch,
	This,
	Throw,
	Try,
	Typeof,
	Var,
	Void,
	While,
	With,
	Yield,

	// Contextual keywords
	Accessor,
	Abstract,
	As,
	Assert,
	Asserts,
	Async,
	Await,
	Constructor,
	Declare,
	Enum,
	From,
	Get,
	Implements,
	Infer,
	Interface,
	Is,
	Keyof,
	Module,
	Namespace,
	Never,
	Of,
	Override,
	Package,
	Private,
	Protected,
	Public,
	Readonly,
	Require,
	Satisfies,
	Set,
	Static,
	Target,
	Type,
	Unique,
	Using,

	// Identifiers
	Identifier,
	PrivateIdentifier, // #name

	// Punctuators
	LBrace,    // {
	RBrace,    // }
	LParen,    // (
	RParen,    // )
	LBracket,  // [
	RBracket,  // ]
	Dot,       // .
	Dot3,      // ...
	Semi,      // ;
	Comma,     // ,
	LAngle,    // <
	RAngle,    // >
	LEq,       // <=
	GEq,       // >=
	Eq,        // ==
	NotEq,     // !=
	EqStrict,  // ===
	NotEqStrict, // !==
	Plus,      // +
	Minus,     // -
	Mul,       // *
	Div,       // /
	Mod,       // %
	Pow,       // **
	PlusPlus,  // ++
	MinusMinus, // --
	LShift,    // <<
	RShift,    // >>
	URShift,   // >>>
	BitAnd,    // &
	BitOr,     // |
	BitXor,    // ^
	BitNot,    // ~
	Not,       // !
	LogicalAnd, // &&
	LogicalOr, // ||
	Nullish,   // ??
	Arrow,     // =>
	Assign,    // =
	AssignAdd, // +=
	AssignSub, // -=
	AssignMul, // *=
	AssignDiv, // /=
	AssignMod, // %=
	AssignPow, // **=
	AssignLShift, // <<=
	AssignRShift, // >>=
	AssignURShift, // >>>=
	AssignBitAnd, // &=
	AssignBitOr, // |=
	AssignBitXor, // ^=
	AssignLogicalAnd, // &&=
	AssignLogicalOr, // ||=
	AssignNullish, // ??=
	Question,  // ?
	Colon,     // :
	OptionalChain, // ?.
	At,            // @

	// Special
	// JSX
	JSXText,        // raw text between JSX tags

	EOF,
	Invalid,
}

// Token represents a lexical token
Token :: struct {
	type:     TokenType,
	loc:      LexerLoc,
	value:    string,  // Raw source text OR cooked identifier name (for \uXXXX escapes)
	raw_end:  u32,     // Source‑byte end offset, always from the FastToken. Needed because
	                  // `value` holds the *cooked* name for escaped identifiers, so
	                  // `loc.offset + len(value)` can underestimate the span by up to
	                  // 5 bytes per \uXXXX (source `\uNNNN` is 6 bytes; cooked UTF‑8
	                  // is 1‑4). Callers reading .value still see the cooked name.
	literal:  LiteralValue, // Parsed value for literals
	had_line_terminator: bool, // True if there was a line terminator before this token
	has_escape: bool,  // FLAG_HAS_ESCAPE from FastToken. Preserved so the parser can
	                  // enforce the ECMA-262 §12.7.2 rule that a ReservedWord's code
	                  // points cannot be expressed via \UnicodeEscapeSequence — the
	                  // check needs to know AFTER the token has been eaten whether
	                  // the identifier arrived via escape.
}

// LiteralValue holds the parsed value of a literal token
LiteralValue :: union {
	bool,
	f64,
	string,
	struct {
		pattern: string,
		flags:   string,
	},
}

// Source location — byte offset only.
//
// Earlier revisions wrapped this in a struct alongside `line` and
// `column`, but the lexer never writes the latter two and the parser
// only ever read 0. Line / column are computed lazily from `offset`
// in the error path (`report_error` / the printer in main.odin) via
// `offset_to_line_col`. With those gone, the wrapper struct buys
// nothing — collapsed to `distinct int` so callers still pass it
// nominally (no random integers leaking into Token / ParseError) but
// it occupies one machine word, not three.
//
// Net: `LexerLoc` shrank from 24 → 8 bytes; every `current := p.cur_tok`
// snapshot and every cross-function Token copy got 16 bytes lighter.
LexerLoc :: distinct int

// IsAssignmentOperator checks if token is an assignment operator
is_assignment_operator :: proc(t: TokenType) -> bool {
	#partial switch t {
	case .Assign, .AssignAdd, .AssignSub, .AssignMul, .AssignDiv, .AssignMod,
	     .AssignPow, .AssignLShift, .AssignRShift, .AssignURShift, .AssignBitAnd,
	     .AssignBitOr, .AssignBitXor, .AssignLogicalAnd, .AssignLogicalOr,
	     .AssignNullish:
		return true
	}
	return false
}

// GetTokenName returns the string name of a token type
get_token_name :: proc(t: TokenType) -> string {
	#partial switch t {
	case .Null:             return "null"
	case .True:             return "true"
	case .False:            return "false"
	case .Number:           return "number"
	case .String:           return "string"
	case .BigInt:           return "bigint"
	case .RegularExpression: return "regexp"
	case .Template:         return "template"
	case .TemplateHead:     return "template_head"
	case .TemplateMiddle:   return "template_middle"
	case .TemplateTail:     return "template_tail"
	case .Break:            return "break"
	case .Case:             return "case"
	case .Catch:            return "catch"
	case .Class:            return "class"
	case .Const:            return "const"
	case .Continue:         return "continue"
	case .Debugger:         return "debugger"
	case .Default:          return "default"
	case .Delete:           return "delete"
	case .Do:               return "do"
	case .Else:             return "else"
	case .Export:           return "export"
	case .Extends:          return "extends"
	case .Finally:          return "finally"
	case .For:              return "for"
	case .Function:         return "function"
	case .If:               return "if"
	case .Import:           return "import"
	case .In:               return "in"
	case .Infer:            return "infer"
	case .Instanceof:       return "instanceof"
	case .Is:               return "is"
	case .Keyof:            return "keyof"
	case .From:             return "from"
	case .Never:            return "never"
	case .Of:               return "of"
	case .Override:         return "override"
	case .Accessor:         return "accessor"
	case .Abstract:         return "abstract"
	case .As:               return "as"
	case .Asserts:          return "asserts"
	case .Let:              return "let"
	case .New:              return "new"
	case .Return:           return "return"
	case .Super:            return "super"
	case .Switch:           return "switch"
	case .This:             return "this"
	case .Throw:            return "throw"
	case .Try:              return "try"
	case .Typeof:           return "typeof"
	case .Var:              return "var"
	case .Void:             return "void"
	case .While:            return "while"
	case .With:             return "with"
	case .Readonly:         return "readonly"
	case .Require:          return "require"
	case .Satisfies:        return "satisfies"
	case .Unique:           return "unique"
	case .Using:            return "using"
	case .Yield:            return "yield"
	case .Identifier:       return "identifier"
	case .PrivateIdentifier: return "private_identifier"
	case .LBrace:           return "{"
	case .RBrace:           return "}"
	case .LParen:           return "("
	case .RParen:           return ")"
	case .LBracket:         return "["
	case .RBracket:         return "]"
	case .Dot:              return "."
	case .Dot3:             return "..."
	case .Semi:             return ";"
	case .Comma:            return ","
	case .LAngle:           return "<"
	case .RAngle:           return ">"
	case .LEq:              return "<="
	case .GEq:              return ">="
	case .Eq:               return "=="
	case .NotEq:            return "!="
	case .EqStrict:         return "==="
	case .NotEqStrict:      return "!=="
	case .Assign:           return "="
	case .Plus:             return "+"
	case .Minus:            return "-"
	case .Mul:              return "*"
	case .Div:              return "/"
	case .Mod:              return "%"
	case .Pow:              return "**"
	case .PlusPlus:         return "++"
	case .MinusMinus:       return "--"
	case .LShift:           return "<<"
	case .RShift:           return ">>"
	case .URShift:          return ">>>"
	case .BitAnd:           return "&"
	case .BitOr:            return "|"
	case .BitXor:           return "^"
	case .BitNot:           return "~"
	case .Not:              return "!"
	case .LogicalAnd:       return "&&"
	case .LogicalOr:        return "||"
	case .Nullish:          return "??"
	case .Arrow:            return "=>"
	case .Question:         return "?"
	case .Colon:            return ":"
	case .OptionalChain:    return "?."
	case .At:               return "@"
	case .JSXText:          return "jsx_text"
	case .EOF:              return "EOF"
	case .Invalid:          return "INVALID"
	case:                   return "UNKNOWN"
	}
}

// Keyword lookup table

// ============================================================================
// FAST TOKEN — 16 bytes by-value, like OXC's Token(u128)
// 16 bytes by-value. Copied between lexer and parser.
// ============================================================================


// FastToken — the primary token type. 16 bytes, fits in a register pair.
// Passed by value between lexer and parser (no indirection).
FastToken :: struct {
	start:  u32,        // byte offset of token start in source
	end:    u32,        // byte offset past last char
	kind:   TokenType,  // 1 byte
	flags:  u8,         // bit 0 = is_on_new_line (had line terminator before this token)
	_pad:   [6]u8,      // padding to 16 bytes (room for future flags)
}

FLAG_NEW_LINE :: u8(1)
// Token contains unicode escape(s). For identifiers this signals that
// the literal store holds the COOKED (decoded) name; the raw span still
// covers the source text including the \uXXXX sequences. ECMA-262 §12.7.2:
// an identifier with any unicode escape is always an Identifier, never a
// keyword, even if the decoded text spells one.
FLAG_HAS_ESCAPE :: u8(2)

token_eof :: #force_inline proc(offset: u32) -> FastToken {
	return FastToken{start = offset, end = offset, kind = .EOF}
}

// ============================================================================
// Literal storage — separate from token, indexed by token start offset
// Only ~20% of tokens have literals (strings, numbers, regex)
// ============================================================================

LiteralType :: enum u8 {
	None,
	Number,
	String,
	Bool,
	Regex,
	BigInt,
	// Identifier — used only when the source contains \uXXXX / \u{H...H}
	// escapes; the cooked (decoded) name is stored so the parser can use it
	// instead of the raw src[start:end] slice. Non-escaped identifiers do
	// NOT populate the literal store (zero-cost hot path).
	Identifier,
}
