package lexer

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
	As,
	Async,
	Await,
	Constructor,
	Declare,
	Enum,
	From,
	Get,
	Implements,
	Interface,
	Module,
	Namespace,
	Of,
	Package,
	Private,
	Protected,
	Public,
	Readonly,
	Require,
	Set,
	Static,
	Target,
	Type,

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

	// Special
	EOF,
	Invalid,
}

// Token represents a lexical token
Token :: struct {
	type:     TokenType,
	loc:      Loc,
	value:    string,  // Raw source text
	literal:  LiteralValue, // Parsed value for literals
	had_line_terminator: bool, // True if there was a line terminator before this token
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

// Source location
Loc :: struct {
	offset: int,
	line:   int,
	column: int,
}

// IsLiteral checks if a token type is a literal
is_literal :: proc(t: TokenType) -> bool {
	#partial switch t {
	case .Null, .True, .False, .Number, .String, .BigInt, .RegularExpression,
	     .Template, .TemplateHead, .TemplateMiddle, .TemplateTail:
		return true
	}
	return false
}

// IsKeyword checks if a token type is a keyword
is_keyword :: proc(t: TokenType) -> bool {
	#partial switch t {
	case .Break, .Case, .Catch, .Class, .Const, .Continue, .Debugger, .Default,
	     .Delete, .Do, .Else, .Export, .Extends, .Finally, .For, .Function,
	     .If, .Import, .In, .Instanceof, .Let, .New, .Return, .Super, .Switch,
	     .This, .Throw, .Try, .Typeof, .Var, .Void, .While, .With, .Yield:
		return true
	}
	return false
}

// IsContextualKeyword checks if a token type is a contextual keyword
is_contextual_keyword :: proc(t: TokenType) -> bool {
	#partial switch t {
	case .Async, .Await, .Constructor, .Declare, .Enum, .From, .Get, .Implements,
	     .Interface, .Module, .Namespace, .Of, .Package, .Private, .Protected,
	     .Public, .Readonly, .Require, .Set, .Static, .Target, .Type:
		return true
	}
	return false
}

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
	case .Instanceof:       return "instanceof"
	case .From:             return "from"
	case .Of:               return "of"
	case .As:               return "as"
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
	case .EOF:              return "EOF"
	case .Invalid:          return "INVALID"
	case:                   return "UNKNOWN"
	}
}

// Keyword lookup table
KeywordTable :: struct {
	name:  string,
	token: TokenType,
}

KEYWORDS := []KeywordTable{
	{"as", .As},
	{"async", .Async},
	{"await", .Await},
	{"break", .Break},
	{"case", .Case},
	{"catch", .Catch},
	{"class", .Class},
	{"const", .Const},
	{"continue", .Continue},
	{"constructor", .Constructor},
	{"debugger", .Debugger},
	{"declare", .Declare},
	{"default", .Default},
	{"delete", .Delete},
	{"do", .Do},
	{"else", .Else},
	{"enum", .Enum},
	{"export", .Export},
	{"extends", .Extends},
	{"finally", .Finally},
	{"for", .For},
	{"from", .From},
	{"function", .Function},
	{"get", .Get},
	{"if", .If},
	{"implements", .Implements},
	{"import", .Import},
	{"in", .In},
	{"instanceof", .Instanceof},
	{"interface", .Interface},
	{"let", .Let},
	{"module", .Module},
	{"namespace", .Namespace},
	{"new", .New},
	{"null", .Null},
	{"of", .Of},
	{"package", .Package},
	{"private", .Private},
	{"protected", .Protected},
	{"public", .Public},
	{"readonly", .Readonly},
	{"require", .Require},
	{"return", .Return},
	{"set", .Set},
	{"static", .Static},
	{"super", .Super},
	{"switch", .Switch},
	{"target", .Target},
	{"this", .This},
	{"throw", .Throw},
	{"true", .True},
	{"false", .False},
	{"try", .Try},
	{"type", .Type},
	{"typeof", .Typeof},
	{"var", .Var},
	{"void", .Void},
	{"while", .While},
	{"with", .With},
	{"yield", .Yield},
}

// ============================================================================
// Keyword Lookup (implemented in keyword_hash.odin)
// ============================================================================

// The keyword hash implementation is in keyword_hash.odin
// It provides O(1) lookup for JavaScript keywords
