package ast

import "core:mem"
import "core:fmt"

// Span represents source location information (u32 = up to 4GB source)
Span :: struct {
	start: u32,
	end:   u32,
}

// Source location with line/column (16 bytes, down from 32)
Loc :: struct {
	span:   Span,
	line:   u32,
	column: u32,
}

// ============================================================================
// Identifier Types (OXC-style distinct types)
// ============================================================================

// BindingIdentifier: Variable declarations (let x, const y, function z)
BindingIdentifier :: struct {
	loc:  Loc,
	name: string,
}

// IdentifierReference: Variable usage (x = 1, console.log(x))
IdentifierReference :: struct {
	loc:          Loc,
	name:         string,
	reference_id: Maybe(int),
}

// IdentifierName: Property names (obj.property, {key: value})
IdentifierName :: struct {
	loc:  Loc,
	name: string,
}

// LabelIdentifier: Loop/switch labels
LabelIdentifier :: struct {
	loc:  Loc,
	name: string,
}

// ============================================================================
// AST Node Types
// ============================================================================

NodeType :: enum {
	// Expressions
	NullLiteral,
	BooleanLiteral,
	NumericLiteral,
	StringLiteral,
	BigIntLiteral,
	RegExpLiteral,
	TemplateLiteral,
	Identifier,
	ThisExpression,
	Super,
	ArrayExpression,
	ObjectExpression,
	FunctionExpression,
	ArrowFunctionExpression,
	ClassExpression,
	MemberExpression,
	ComputedMemberExpression,
	CallExpression,
	NewExpression,
	ConditionalExpression,
	UpdateExpression,
	UnaryExpression,
	BinaryExpression,
	LogicalExpression,
	AssignmentExpression,
	SequenceExpression,
	SpreadElement,
	YieldExpression,
	AwaitExpression,
	ImportExpression,
	MetaProperty,

	// Statements
	ExpressionStatement,
	EmptyStatement,
	BlockStatement,
	DebuggerStatement,
	ReturnStatement,
	BreakStatement,
	ContinueStatement,
	LabeledStatement,
	IfStatement,
	SwitchStatement,
	WhileStatement,
	DoWhileStatement,
	ForStatement,
	ForInStatement,
	ForOfStatement,
	WithStatement,
	ThrowStatement,
	TryStatement,

	// Declarations (also valid as statements at top level)
	FunctionDeclaration,
	VariableDeclaration,
	ClassDeclaration,

	// Module
	ImportDeclaration,
	ExportNamedDeclaration,
	ExportDefaultDeclaration,
	ExportAllDeclaration,
	ImportSpecifier,
	ImportDefaultSpecifier,
	ImportNamespaceSpecifier,
	ExportSpecifier,

	// Programs
	Program,
	Script,
	Module,
}

// ============================================================================
// Expression Nodes
// ============================================================================

NullLiteral :: struct {
	loc: Loc,
}

BooleanLiteral :: struct {
	loc:   Loc,
	value: bool,
}

NumericLiteral :: struct {
	loc:   Loc,
	value: f64,
	raw:   string,
}

StringLiteral :: struct {
	loc:   Loc,
	value: string,
	raw:   string,
}

BigIntLiteral :: struct {
	loc:   Loc,
	value: string, // Stored as string since BigInt can exceed 64-bit
	raw:   string,
}

RegExpLiteral :: struct {
	loc:     Loc,
	pattern: string,
	flags:   string,
}

TemplateElement :: struct {
	loc:               Loc,
	tail:              bool,
	cooked:            Maybe(string),
	raw:               string,
}

TemplateLiteral :: struct {
	loc:        Loc,
	quasis:     [dynamic]TemplateElement,
	expressions: [dynamic]^Expression,
}

// Tagged template literal: tag`hello ${name}`
TaggedTemplateExpression :: struct {
	loc:   Loc,
	tag:   ^Expression,
	quasi: ^Expression, // TemplateLiteral
}

Identifier :: struct {
	loc:  Loc,
	name: string,
}

// PrivateIdentifier for class private fields/methods (#field)
PrivateIdentifier :: struct {
	loc:  Loc,
	name: string, // without the # prefix
}

ThisExpression :: struct {
	loc: Loc,
}

Super :: struct {
	loc: Loc,
}

SpreadElement :: struct {
	loc:       Loc,
	argument:  ^Expression,
}

ArrayExpression :: struct {
	loc:      Loc,
	elements: [dynamic]Maybe(^Expression), // null for sparse arrays
}

PropertyKind :: enum {
	Init,
	Get,
	Set,
	Method,
}

Property :: struct {
	loc:       Loc,
	key:       ^Expression, // Identifier, StringLiteral, or NumericLiteral
	value:     ^Expression,
	kind:      PropertyKind,
	computed:  bool,
	shorthand: bool,
}

ObjectExpression :: struct {
	loc:        Loc,
	properties: [dynamic]Property,
}

MemberExpression :: struct {
	loc:       Loc,
	object:    ^Expression,
	property:  ^Expression, // IdentifierName for non-computed
	computed:  bool,
	optional:  bool, // true for ?.prop (ES2020 Optional Chaining)
}

CallExpression :: struct {
	loc:       Loc,
	callee:    ^Expression,
	arguments: [dynamic]^Expression,
	optional:  bool, // true for ?.() (ES2020 Optional Chaining)
}

NewExpression :: struct {
	loc:       Loc,
	callee:    ^Expression,
	arguments: [dynamic]^Expression,
}

ConditionalExpression :: struct {
	loc:       Loc,
	test:      ^Expression,
	consequent: ^Expression,
	alternate: ^Expression,
}

UpdateExpression :: struct {
	loc:      Loc,
	operator: enum { Increment, Decrement },
	argument: ^Expression,
	prefix:   bool,
}

UnaryExpression :: struct {
	loc:      Loc,
	operator: UnaryOperator,
	argument: ^Expression,
	prefix:   bool,
}

UnaryOperator :: enum {
	Minus,        // -
	Plus,         // +
	LogicalNot,   // !
	BitwiseNot,   // ~
	Typeof,       // typeof
	Void,         // void
	Delete,       // delete
}

BinaryExpression :: struct {
	loc:      Loc,
	operator: BinaryOperator,
	left:     ^Expression,
	right:    ^Expression,
}

BinaryOperator :: enum {
	// Arithmetic
	Add, Sub, Mul, Div, Mod, Pow,
	// Bitwise
	BitOr, BitXor, BitAnd,
	ShiftLeft, ShiftRight, ShiftRightUnsigned,
	// Relational
	Eq, NotEq, StrictEq, StrictNotEq,
	Lt, LtEq, Gt, GtEq,
	// instanceof, in
	Instanceof, In,
}

LogicalExpression :: struct {
	loc:      Loc,
	operator: LogicalOperator,
	left:     ^Expression,
	right:    ^Expression,
}

LogicalOperator :: enum {
	Or,                // ||
	And,               // &&
	NullishCoalescing, // ?? (ES2020)
}

AssignmentExpression :: struct {
	loc:      Loc,
	operator: AssignmentOperator,
	left:     ^Expression, // Must be valid assignment target
	right:    ^Expression,
}

AssignmentOperator :: enum {
	Assign,              // =
	AddAssign,           // +=
	SubAssign,           // -=
	MulAssign,           // *=
	DivAssign,           // /=
	ModAssign,           // %=
	PowAssign,           // **=
	ShiftLeftAssign,     // <<=
	ShiftRightAssign,    // >>>=
	ShiftRightUAssign,   // >>>=
	BitOrAssign,         // |=
	BitXorAssign,        // ^=
	BitAndAssign,        // &=
	AssignLogicalAnd,    // &&=
	AssignLogicalOr,     // ||=
	AssignNullish,       // ??=
}

SequenceExpression :: struct {
	loc:        Loc,
	expressions: [dynamic]^Expression,
}

YieldExpression :: struct {
	loc:      Loc,
	argument: Maybe(^Expression),
	delegate: bool, // yield*
}

AwaitExpression :: struct {
	loc:      Loc,
	argument: ^Expression,
}

ImportExpression :: struct {
	loc:      Loc,
	source:   ^Expression,
}

MetaProperty :: struct {
	loc:      Loc,
	meta:     Identifier,
	property: Identifier,
}

// ============================================================================
// Function/Class Definitions
// ============================================================================

FunctionBody :: struct {
	loc:        Loc,
	body:       [dynamic]^Statement,
	directives: [dynamic]Directive,
}

Directive :: struct {
	loc:    Loc,
	value:  StringLiteral,
	raw:    string,
}

Pattern :: union {
	^Identifier,
	^ObjectPattern,
	^ArrayPattern,
	^AssignmentPattern,
	^RestElement,
	^MemberExpression, // Destructuring target
}

ObjectPatternPropertyKey :: union {
	IdentifierName,
	^StringLiteral,
	^Expression, // computed key
}

ObjectPatternProperty :: struct {
	loc:       Loc,
	key:       Maybe(ObjectPatternPropertyKey),
	value:     Pattern,
	computed:  bool,
	shorthand: bool,
}

ObjectPattern :: struct {
	loc:        Loc,
	properties: [dynamic]ObjectPatternProperty,
}

ArrayPattern :: struct {
	loc:      Loc,
	elements: []Maybe(Pattern),
}

AssignmentPattern :: struct {
	loc:       Loc,
	left:      Pattern,
	right:     ^Expression,
}

RestElement :: struct {
	loc:      Loc,
	argument: Pattern,
}

FunctionParameter :: struct {
	loc:         Loc,
	pattern:     Pattern,
	default_val: Maybe(^Expression),
}

FunctionExpression :: struct {
	loc:          Loc,
	id:           Maybe(BindingIdentifier),
	params:       [dynamic]FunctionParameter,
	body:         FunctionBody,
	generator:    bool,
	async:        bool,
}

ArrowFunctionExpression :: struct {
	loc:        Loc,
	params:     [dynamic]FunctionParameter,
	body:       ^Expression, // Can be expression or BlockStatement
	expression: bool,
	async:      bool,
}

ClassBody :: struct {
	loc:    Loc,
	body:   [dynamic]ClassElement,
}

ClassElementKind :: enum {
	Method,
	Get,
	Set,
	Constructor,
	StaticBlock,  // ES2022 static { ... }
}

ClassElement :: struct {
	loc:           Loc,
	key:           ^Expression,
	value:         Maybe(^Expression),
	kind:          ClassElementKind,
	computed:      bool,
	static:        bool,
	decorators:    [dynamic]^Expression,
}

ClassExpression :: struct {
	loc:           Loc,
	id:            Maybe(BindingIdentifier),
	super_class:   Maybe(^Expression),
	body:          ClassBody,
}

// StaticBlock for ES2022 static class blocks (static { ... })
StaticBlock :: struct {
	loc:  Loc,
	body: [dynamic]^Statement,
}

// ============================================================================
// Statement Nodes
// ============================================================================

ExpressionStatement :: struct {
	loc:        Loc,
	expression: ^Expression,
}

EmptyStatement :: struct {
	loc: Loc,
}

BlockStatement :: struct {
	loc:  Loc,
	body: [dynamic]^Statement,
}

DebuggerStatement :: struct {
	loc: Loc,
}

ReturnStatement :: struct {
	loc:      Loc,
	argument: Maybe(^Expression),
}

BreakStatement :: struct {
	loc:   Loc,
	label: Maybe(LabelIdentifier),
}

ContinueStatement :: struct {
	loc:   Loc,
	label: Maybe(LabelIdentifier),
}

LabeledStatement :: struct {
	loc:   Loc,
	label: LabelIdentifier,
	body:  ^Statement,
}

IfStatement :: struct {
	loc:       Loc,
	test:      ^Expression,
	consequent: ^Statement,
	alternate: Maybe(^Statement),
}

SwitchCase :: struct {
	loc:      Loc,
	test:     Maybe(^Expression), // null for default
	consequent: [dynamic]^Statement,
}

SwitchStatement :: struct {
	loc:         Loc,
	discriminant: ^Expression,
	cases:       [dynamic]SwitchCase,
}

WhileStatement :: struct {
	loc:  Loc,
	test: ^Expression,
	body: ^Statement,
}

DoWhileStatement :: struct {
	loc:  Loc,
	body: ^Statement,
	test: ^Expression,
}

VariableDeclarator :: struct {
	loc:   Loc,
	id:    Pattern,
	init:  Maybe(^Expression),
}

VariableKind :: enum {
	Var,
	Let,
	Const,
}

VariableDeclaration :: struct {
	loc:         Loc,
	kind:        VariableKind,
	declarations: [dynamic]VariableDeclarator,
}

ForStatement :: struct {
	loc:        Loc,
	init_decl:  Maybe(^VariableDeclaration), // for (let/const/var ...)
	init_expr:  Maybe(^Expression),           // for (expr; ...)
	test:       Maybe(^Expression),
	update:     Maybe(^Expression),
	body:       ^Statement,
}

ForInStatement :: struct {
	loc:       Loc,
	left_decl: Maybe(^VariableDeclaration), // for (let/const/var ... in ...)
	left_expr: Maybe(^Expression),           // for (expr in ...)
	right:     ^Expression,
	body:      ^Statement,
}

ForOfStatement :: struct {
	loc:       Loc,
	left_decl: Maybe(^VariableDeclaration), // for (let/const/var ... of ...)
	left_expr: Maybe(^Expression),           // for (expr of ...)
	right:     ^Expression,
	body:      ^Statement,
	await:     bool, // for await...of
}

WithStatement :: struct {
	loc:    Loc,
	object: ^Expression,
	body:   ^Statement,
}

ThrowStatement :: struct {
	loc:      Loc,
	argument: ^Expression,
}

CatchClause :: struct {
	loc:       Loc,
	param:     Maybe(Pattern),
	body:      BlockStatement,
}

TryStatement :: struct {
	loc:      Loc,
	block:    BlockStatement,
	handler:  Maybe(CatchClause),
	finalizer: Maybe(BlockStatement),
}

// ============================================================================
// Declaration Nodes
// ============================================================================

FunctionDeclaration :: struct {
	using expr: FunctionExpression,
}

ClassDeclaration :: struct {
	using expr: ClassExpression,
}

// ============================================================================
// Module Nodes
// ============================================================================

ImportSpecifier :: struct {
	loc:       Loc,
	local:     BindingIdentifier,
	imported:  IdentifierName,
}

ImportDefaultSpecifier :: struct {
	loc:   Loc,
	local: BindingIdentifier,
}

ImportNamespaceSpecifier :: struct {
	loc:   Loc,
	local: BindingIdentifier,
}

ImportAttribute :: struct {
	loc:   Loc,
	key:   IdentifierName,
	value: StringLiteral,
}

ImportDeclaration :: struct {
	loc:        Loc,
	specifiers: [dynamic]^ImportSpecifierSpec,
	source:     StringLiteral,
	attributes: [dynamic]ImportAttribute,
}

ImportSpecifierSpec :: union {
	ImportSpecifier,
	ImportDefaultSpecifier,
	ImportNamespaceSpecifier,
}

ExportSpecifier :: struct {
	loc:       Loc,
	local:     IdentifierName,
	exported:  IdentifierName,
}

ExportNamedDeclaration :: struct {
	loc:        Loc,
	declaration: Maybe(^Declaration),
	specifiers: [dynamic]ExportSpecifier,
	source:     Maybe(StringLiteral),
}

ExportDefaultDeclaration :: struct {
	loc:         Loc,
	declaration: ^ExportDefaultDef,
}

ExportDefaultDef :: union {
	^Declaration,
	^Expression,
}

ExportAllDeclaration :: struct {
	loc:        Loc,
	source:     StringLiteral,
	exported:   Maybe(IdentifierName), // null for "export *", identifier for "export * as ns"
}

// ============================================================================
// Program Node
// ============================================================================

SourceType :: enum {
	Script,
	Module,
}

Program :: struct {
	loc:        Loc,
	type:       SourceType,
	body:       [dynamic]^Statement,
	directives: [dynamic]Directive,
}

// ============================================================================
// Union Types for AST Traversal
// ============================================================================

Expression :: union {
	^NullLiteral,
	^BooleanLiteral,
	^NumericLiteral,
	^StringLiteral,
	^BigIntLiteral,
	^RegExpLiteral,
	^TemplateLiteral,
	^TaggedTemplateExpression,
	^Identifier,
	^PrivateIdentifier,  // #field, #method
	^ThisExpression,
	^Super,
	^ArrayExpression,
	^ObjectExpression,
	^FunctionExpression,
	^ArrowFunctionExpression,
	^ClassExpression,
	^MemberExpression,
	^CallExpression,
	^NewExpression,
	^ConditionalExpression,
	^UpdateExpression,
	^UnaryExpression,
	^BinaryExpression,
	^LogicalExpression,
	^AssignmentExpression,
	^SequenceExpression,
	^SpreadElement,
	^YieldExpression,
	^AwaitExpression,
	^ImportExpression,
	^MetaProperty,
}

Statement :: union {
	^ExpressionStatement,
	^EmptyStatement,
	^BlockStatement,
	^DebuggerStatement,
	^ReturnStatement,
	^BreakStatement,
	^ContinueStatement,
	^LabeledStatement,
	^IfStatement,
	^SwitchStatement,
	^WhileStatement,
	^DoWhileStatement,
	^ForStatement,
	^ForInStatement,
	^ForOfStatement,
	^WithStatement,
	^ThrowStatement,
	^TryStatement,
	^FunctionDeclaration,
	^VariableDeclaration,
	^ClassDeclaration,
	^ImportDeclaration,
	^ExportNamedDeclaration,
	^ExportDefaultDeclaration,
	^ExportAllDeclaration,
}

Declaration :: union {
	^FunctionDeclaration,
	^VariableDeclaration,
	^ClassDeclaration,
	^ImportDeclaration,
	^ExportNamedDeclaration,
	^ExportDefaultDeclaration,
	^ExportAllDeclaration,
}

Node :: union {
	Program,
	Statement,
	Expression,
	Declaration,
	Pattern,
	FunctionBody,
	ClassBody,
	SwitchCase,
	CatchClause,
	Property,
	TemplateElement,
}

// ============================================================================
// Arena Allocation Helpers
// ============================================================================

new_expression :: proc($T: typeid, alloc: mem.Allocator) -> ^Expression {
	return cast(^Expression)mem.new(T, alloc)
}

new_statement :: proc($T: typeid, alloc: mem.Allocator) -> ^Statement {
	return cast(^Statement)mem.new(T, alloc)
}

new_node :: proc($T: typeid, alloc: mem.Allocator) -> ^T {
	ptr, err := mem.new(T, alloc)
	if err != nil || ptr == nil {
		panic(fmt.tprintf("Failed to allocate AST node: %v", err))
	}
	return ptr
}
