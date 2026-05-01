package main


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
// Comment Node
// ============================================================================

CommentType :: enum {
	Line,  // //
	Block, // /* */
}

Comment :: struct {
	type:  CommentType,
	start: u32,
	end:   u32,
	value: string, // the text between // and newline, or /* and */
}

// ============================================================================
// Decorator Node (Stage 3)
// ============================================================================

Decorator :: struct {
	loc:        Loc,
	expression: ^Expression,
}

// ============================================================================
// ESM Module Record Nodes
// ============================================================================

// Name kind for imports/exports
ESMNameKind :: enum {
	Default,
	Namespace,
	Name,
}

// ESM import/export name with kind and optional location info
ESMNameEntry :: struct {
	kind:  ESMNameKind,
	name:  string,
	start: u32,
	end:   u32,
}

// Static import entry (import X from "m")
ESMStaticImportEntry :: struct {
	importName: ESMNameEntry,  // the imported name
	localName:  ESMNameEntry,  // the local binding name
}

ESMStaticImport :: struct {
	start:         u32,
	end:           u32,
	moduleRequest: struct {
		value: string,  // the module specifier
		start: u32,
		end:   u32,
	},
	entries: [dynamic]ESMStaticImportEntry,
}

// Static export entry (export { x, y as z } or export * from "m")
ESMExportNameEntry :: struct {
	kind:  ESMNameKind,  // kind of the export (Default, Name, Namespace)
	name:  string,
	start: u32,
	end:   u32,
}

ESMStaticExportEntry :: struct {
	exportName: ESMExportNameEntry,
	localName:  ESMExportNameEntry,
}

ESMStaticExport :: struct {
	start:         u32,
	end:           u32,
	moduleRequest: struct {
		value: string,  // the module specifier (for export * from "m"), empty for local exports
		start: u32,
		end:   u32,
	},
	entries: [dynamic]ESMStaticExportEntry,
}

// Dynamic import entry (import("m"))
ESMDynamicImport :: struct {
	start:         u32,
	end:           u32,
	moduleRequest: struct {
		start: u32,
		end:   u32,
	},
}

// import.meta access
ESMImportMeta :: struct {
	start: u32,
	end:   u32,
}

// ============================================================================
// JSX Nodes
// ============================================================================

JSXElement :: struct {
	loc:             Loc,
	opening_element: ^JSXOpeningElement,
	children:        [dynamic]JSXChild,
	closing_element: Maybe(^JSXClosingElement),
}

JSXFragment :: struct {
	loc:              Loc,
	opening_fragment: JSXOpeningFragment,
	children:         [dynamic]JSXChild,
	closing_fragment: JSXClosingFragment,
}

JSXOpeningElement :: struct {
	loc:          Loc,
	name:         JSXElementName,
	attributes:   [dynamic]JSXAttributeItem,
	self_closing: bool,
}

JSXClosingElement :: struct {
	loc:  Loc,
	name: JSXElementName,
}

JSXOpeningFragment :: struct {
	loc: Loc,
}

JSXClosingFragment :: struct {
	loc: Loc,
}

JSXIdentifier :: struct {
	loc:  Loc,
	name: string,
}

JSXMemberExpression :: struct {
	loc:      Loc,
	object:   JSXMemberObject,
	property: JSXIdentifier,
}

JSXNamespacedName :: struct {
	loc:       Loc,
	namespace: JSXIdentifier,
	name:      JSXIdentifier,
}

JSXAttribute :: struct {
	loc:   Loc,
	name:  JSXAttributeName,
	value: Maybe(^Expression), // StringLiteral or JSXExpressionContainer or JSXElement
}

JSXSpreadAttribute :: struct {
	loc:      Loc,
	argument: ^Expression,
}

JSXText :: struct {
	loc:   Loc,
	value: string,
	raw:   string,
}

JSXExpressionContainer :: struct {
	loc:        Loc,
	expression: ^Expression, // or JSXEmptyExpression
}

JSXEmptyExpression :: struct {
	loc: Loc,
}

JSXSpreadChild :: struct {
	loc:        Loc,
	expression: ^Expression,
}

// Union types for JSX
JSXElementName :: union {
	JSXIdentifier,
	^JSXMemberExpression,
	^JSXNamespacedName,
}

JSXMemberObject :: union {
	JSXIdentifier,
	^JSXMemberExpression,
}

JSXAttributeName :: union {
	JSXIdentifier,
	^JSXNamespacedName,
}

JSXAttributeItem :: union {
	JSXAttribute,
	^JSXSpreadAttribute,
}

JSXChild :: union {
	^JSXElement,
	^JSXFragment,
	^JSXText,
	^JSXExpressionContainer,
	^JSXSpreadChild,
}

// ============================================================================
// TypeScript Nodes
// ============================================================================

// Type annotation wrapper: `: Type`
TSTypeAnnotation :: struct {
	loc:             Loc,
	type_annotation: ^TSType,
}

// Type parameter declaration: `<T extends U = V>`
TSTypeParameterDeclaration :: struct {
	loc:    Loc,
	params: [dynamic]TSTypeParameter,
}

TSTypeParameter :: struct {
	loc:        Loc,
	name:       BindingIdentifier,
	constraint: Maybe(^TSType),   // extends clause
	default_:   Maybe(^TSType),   // = default type
	in_:        bool,             // variance modifier
	out:        bool,             // variance modifier
	const_:     bool,             // const modifier
}

// Type argument instantiation: `<string, number>`
TSTypeParameterInstantiation :: struct {
	loc:    Loc,
	params: [dynamic]^TSType,
}

// Keyword types
TSAnyKeyword :: struct { loc: Loc }
TSBigIntKeyword :: struct { loc: Loc }
TSBooleanKeyword :: struct { loc: Loc }
TSIntrinsicKeyword :: struct { loc: Loc }
TSNeverKeyword :: struct { loc: Loc }
TSNullKeyword :: struct { loc: Loc }
TSNumberKeyword :: struct { loc: Loc }
TSObjectKeyword :: struct { loc: Loc }
TSStringKeyword :: struct { loc: Loc }
TSSymbolKeyword :: struct { loc: Loc }
TSUndefinedKeyword :: struct { loc: Loc }
TSUnknownKeyword :: struct { loc: Loc }
TSVoidKeyword :: struct { loc: Loc }
TSThisType :: struct { loc: Loc }

// Type reference: `Foo`, `Array<T>`
TSTypeReference :: struct {
	loc:             Loc,
	type_name:       ^Expression,  // Identifier or qualified name
	type_parameters: Maybe(^TSTypeParameterInstantiation),
}

// Union type: `A | B | C`
TSUnionType :: struct {
	loc:   Loc,
	types: [dynamic]^TSType,
}

// Intersection type: `A & B & C`
TSIntersectionType :: struct {
	loc:   Loc,
	types: [dynamic]^TSType,
}

// Array type: `T[]`
TSArrayType :: struct {
	loc:           Loc,
	element_type:  ^TSType,
}

// Tuple type: `[string, number]`
TSTupleType :: struct {
	loc:            Loc,
	element_types:  [dynamic]^TSType,
}

// Function type: `(x: T) => R`
TSFunctionType :: struct {
	loc:             Loc,
	type_parameters: Maybe(^TSTypeParameterDeclaration),
	params:          [dynamic]TSFunctionParam,
	return_type:     ^TSTypeAnnotation,
}

// Constructor type: `new (x: T) => R`
TSConstructorType :: struct {
	loc:             Loc,
	type_parameters: Maybe(^TSTypeParameterDeclaration),
	params:          [dynamic]TSFunctionParam,
	return_type:     ^TSTypeAnnotation,
	abstract_:       bool,
}

TSFunctionParam :: struct {
	loc:             Loc,
	pattern:         Pattern,
	type_annotation: Maybe(^TSTypeAnnotation),
	optional:        bool,
}

// Type literal / object type: `{ x: number; y: string }`
TSTypeLiteral :: struct {
	loc:     Loc,
	members: [dynamic]^TSSignature,
}

// Conditional type: `T extends U ? X : Y`
TSConditionalType :: struct {
	loc:           Loc,
	check_type:    ^TSType,
	extends_type:  ^TSType,
	true_type:     ^TSType,
	false_type:    ^TSType,
}

// Infer type: `infer T`
TSInferType :: struct {
	loc:             Loc,
	type_parameter:  TSTypeParameter,
}

// Type query: `typeof x`
TSTypeQuery :: struct {
	loc:             Loc,
	expr_name:       ^Expression,
	type_parameters: Maybe(^TSTypeParameterInstantiation),
}

// Type operator: `keyof T`, `unique T`, `readonly T`
TSTypeOperator :: struct {
	loc:             Loc,
	operator:        string,
	type_annotation: ^TSType,
}

// Indexed access: `T[K]`
TSIndexedAccessType :: struct {
	loc:         Loc,
	object_type: ^TSType,
	index_type:  ^TSType,
}

// Mapped type: `{ [K in T]: V }`
TSMappedType :: struct {
	loc:             Loc,
	type_parameter:  TSTypeParameter,
	name_type:       Maybe(^TSType),  // `as` clause
	type_annotation: Maybe(^TSType),
	optional:        TSMappedTypeModifier,
	readonly:        TSMappedTypeModifier,
}

TSMappedTypeModifier :: enum {
	None,
	Plus,    // +readonly, +?
	Minus,   // -readonly, -?
	True,    // readonly, ?
}

// Literal type: `"hello"`, `42`, `true`
TSLiteralType :: struct {
	loc:     Loc,
	literal: ^Expression,
}

// Template literal type: `hello ${T}`
TSTemplateLiteralType :: struct {
	loc:    Loc,
	quasis: [dynamic]TemplateElement,
	types:  [dynamic]^TSType,
}

// Parenthesized type: `(T)`
TSParenthesizedType :: struct {
	loc:             Loc,
	type_annotation: ^TSType,
}

// Rest type in tuple: `...T`
TSRestType :: struct {
	loc:             Loc,
	type_annotation: ^TSType,
}

// Optional type in tuple: `T?`
TSOptionalType :: struct {
	loc:             Loc,
	type_annotation: ^TSType,
}

// Named tuple member: `name: T` or `name?: T`
TSNamedTupleMember :: struct {
	loc:           Loc,
	label:         BindingIdentifier,
	element_type:  ^TSType,
	optional:      bool,
}

// Type predicate: `x is T`
TSTypePredicate :: struct {
	loc:             Loc,
	parameter_name:  ^Expression,
	type_annotation: Maybe(^TSTypeAnnotation),
	asserts:         bool,
}

// Import type: `import("module").T`
TSImportType :: struct {
	loc:             Loc,
	argument:        ^TSType,
	qualifier:       Maybe(^Expression),
	type_parameters: Maybe(^TSTypeParameterInstantiation),
	is_typeof:       bool,
}

// `as` expression: `expr as Type`
TSAsExpression :: struct {
	loc:             Loc,
	expression:      ^Expression,
	type_annotation: ^TSType,
}

// `satisfies` expression: `expr satisfies Type`
TSSatisfiesExpression :: struct {
	loc:             Loc,
	expression:      ^Expression,
	type_annotation: ^TSType,
}

// Non-null assertion: `expr!`
TSNonNullExpression :: struct {
	loc:        Loc,
	expression: ^Expression,
}

// Type assertion: `<Type>expr`
TSTypeAssertion :: struct {
	loc:             Loc,
	type_annotation: ^TSType,
	expression:      ^Expression,
}

// Instantiation expression: `f<T>` (the bare-type-arguments form, not
// followed by `(args)`). Babel and OXC both surface this as a distinct
// node so consumers can tell `f<T>` (instantiate the polymorphic value)
// from `f<T>(args)` (CallExpression with type_parameters). See
// microsoft/TypeScript#47607.
TSInstantiationExpression :: struct {
	loc:             Loc,
	expression:      ^Expression,
	type_arguments:  ^TSTypeParameterInstantiation,
}

// TS interface declaration
TSInterfaceDeclaration :: struct {
	loc:             Loc,
	id:              BindingIdentifier,
	type_parameters: Maybe(^TSTypeParameterDeclaration),
	extends:         [dynamic]TSInterfaceHeritage,
	body:            TSInterfaceBody,
	declare:         bool,
}

TSInterfaceBody :: struct {
	loc:  Loc,
	body: [dynamic]^TSSignature,
}

TSInterfaceHeritage :: struct {
	loc:             Loc,
	expression:      ^Expression,
	type_parameters: Maybe(^TSTypeParameterInstantiation),
}

// TS type alias: `type X = T`
TSTypeAliasDeclaration :: struct {
	loc:             Loc,
	id:              BindingIdentifier,
	type_parameters: Maybe(^TSTypeParameterDeclaration),
	type_annotation: ^TSType,
	declare:         bool,
}

// TS enum
TSEnumDeclaration :: struct {
	loc:     Loc,
	id:      BindingIdentifier,
	body:    TSEnumBody,
	const_:  bool,
	declare: bool,
}

TSEnumBody :: struct {
	loc:     Loc,
	members: [dynamic]TSEnumMember,
}

TSEnumMember :: struct {
	loc:         Loc,
	id:          ^Expression,  // Identifier or StringLiteral
	initializer: Maybe(^Expression),
}

// TS `import X = N` / `import X = A.B.C` / `import X = require("m")`.
// Top-level declaration form, distinct from ImportDeclaration. Per
// TypeScript grammar this is the only place TSExternalModuleReference
// appears (TS spec calls it ImportEqualsDeclaration; ESTree's TS-shape
// adds the TS prefix).
//
//   id                : the local binding (Identifier)
//   module_reference  : the right-hand side
//                          - bare Identifier        (`= N`)
//                          - `A.B.C` chain          (qualified entity name)
//                          - `require("m")`         (external module ref)
//                       Stored as ^Expression for the entity-name forms
//                       (Identifier or MemberExpression chain that the
//                       emitter folds into TSQualifiedName), or as a
//                       ^TSExternalModuleReference for the `require()`
//                       form.
//   import_kind       : `import type X = ...` vs plain `import X = ...`
TSImportEqualsDeclaration :: struct {
	loc:              Loc,
	id:               Identifier,
	module_reference: TSModuleReference,
	import_kind:      ImportExportKind,
}

TSModuleReference :: union {
	^Expression,                  // Identifier or MemberExpression `A.B.C`
	^TSExternalModuleReference,   // require("m")
}

TSExternalModuleReference :: struct {
	loc:        Loc,
	expression: ^StringLiteral,
}

// TS module/namespace declaration
TSModuleDeclaration :: struct {
	loc:     Loc,
	id:      ^Expression,  // Identifier or StringLiteral
	body:    Maybe(^TSModuleBody),
	declare: bool,
	global:  bool,
	kind:    TSModuleKind,
}

TSModuleKind :: enum {
	Namespace,
	Module,
	Global,
}

TSModuleBody :: union {
	^TSModuleBlock,
	^TSModuleDeclaration,
}

TSModuleBlock :: struct {
	loc:  Loc,
	body: [dynamic]^Statement,
}

// Interface/object-type signatures
TSPropertySignature :: struct {
	loc:             Loc,
	key:             ^Expression,
	type_annotation: Maybe(^TSTypeAnnotation),
	computed:        bool,
	optional:        bool,
	readonly:        bool,
}

TSMethodSignature :: struct {
	loc:              Loc,
	key:              ^Expression,
	type_parameters:  Maybe(^TSTypeParameterDeclaration),
	params:           [dynamic]TSFunctionParam,
	return_type:      Maybe(^TSTypeAnnotation),
	computed:         bool,
	optional:         bool,
	kind:             TSMethodSignatureKind,
}

TSMethodSignatureKind :: enum {
	Method,
	Get,
	Set,
}

TSCallSignatureDeclaration :: struct {
	loc:              Loc,
	type_parameters:  Maybe(^TSTypeParameterDeclaration),
	params:           [dynamic]TSFunctionParam,
	return_type:      Maybe(^TSTypeAnnotation),
}

TSConstructSignatureDeclaration :: struct {
	loc:              Loc,
	type_parameters:  Maybe(^TSTypeParameterDeclaration),
	params:           [dynamic]TSFunctionParam,
	return_type:      Maybe(^TSTypeAnnotation),
}

TSIndexSignature :: struct {
	loc:              Loc,
	parameters:       [dynamic]TSFunctionParam,
	type_annotation:  Maybe(^TSTypeAnnotation),
	readonly:         bool,
	static_:          bool,
}

// Signature union
TSSignature :: union {
	TSPropertySignature,
	TSMethodSignature,
	TSCallSignatureDeclaration,
	TSConstructSignatureDeclaration,
	TSIndexSignature,
}

// Master TSType union
TSType :: union {
	// Keywords
	^TSAnyKeyword,
	^TSBigIntKeyword,
	^TSBooleanKeyword,
	^TSIntrinsicKeyword,
	^TSNeverKeyword,
	^TSNullKeyword,
	^TSNumberKeyword,
	^TSObjectKeyword,
	^TSStringKeyword,
	^TSSymbolKeyword,
	^TSUndefinedKeyword,
	^TSUnknownKeyword,
	^TSVoidKeyword,
	^TSThisType,
	// Compound
	^TSTypeReference,
	^TSUnionType,
	^TSIntersectionType,
	^TSArrayType,
	^TSTupleType,
	^TSFunctionType,
	^TSConstructorType,
	^TSTypeLiteral,
	^TSConditionalType,
	^TSInferType,
	^TSTypeQuery,
	^TSIndexedAccessType,
	^TSMappedType,
	^TSTypeOperator,
	^TSLiteralType,
	^TSTemplateLiteralType,
	^TSParenthesizedType,
	^TSRestType,
	^TSOptionalType,
	^TSNamedTupleMember,
	^TSTypePredicate,
	^TSImportType,
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
	loc:                Loc,
	name:               string,
	type_annotation:    Maybe(^TSTypeAnnotation),
	optional:           bool,
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

ChainExpression :: struct {
	loc:        Loc,
	expression: ^Expression, // MemberExpression or CallExpression with optional=true
}

ArrayExpression :: struct {
	loc:      Loc,
	elements: [dynamic]Maybe(^Expression), // null for sparse arrays
}

// ParenthesizedExpression is NOT in ESTree core — ESTree treats `(...)` as
// purely syntactic and discards the grouping in the AST. It IS in the Acorn
// preserveParens extension, ESLint, and OXC's default output. Shape matches
// Acorn/OXC: `{ type: "ParenthesizedExpression", expression, start, end }`.
// Babel uses a different convention (`extra.parenthesized: true` on the
// inner node) and is intentionally NOT the target here.
//
// Kessel gates emission behind `--preserve-parens` so default JS output
// stays byte-identical for consumers that follow ESTree core.
ParenthesizedExpression :: struct {
	loc:        Loc,
	expression: ^Expression,
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
	loc:               Loc,
	callee:            ^Expression,
	arguments:         [dynamic]^Expression,
	optional:          bool, // true for ?.() (ES2020 Optional Chaining)
	type_parameters:   Maybe(^TSTypeParameterInstantiation),
}

NewExpression :: struct {
	loc:               Loc,
	callee:            ^Expression,
	arguments:         [dynamic]^Expression,
	type_parameters:   Maybe(^TSTypeParameterInstantiation),
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
	// Import attributes object from the second argument of ImportCall:
	//   import('./x.js', { assert: { type: 'json' } })
	// null when absent. Matches the `options` field OXC/Acorn emit for
	// the stage-3 Import Attributes proposal.
	options:  ^Expression,
	// Phase imports (stage-3). "" = regular import() call,
	// "defer"  = import.defer(x)   (import-defer proposal),
	// "source" = import.source(x)  (import-source / module source proposal).
	// Emitted as JSON string when non-empty, else null — matches OXC.
	phase:    string,
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
	^NumericLiteral,
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
	// TS-position type annotation: `function f({a, b}: Props)` attaches
	// `: Props` to the ObjectPattern itself in OXC's TS-ESTree shape
	// (Identifier patterns store it on the Identifier; non-Identifier
	// patterns store it on the pattern node). Pre-S26 W4b kessel's
	// parser parsed the annotation but silently dropped it for non-
	// Identifier patterns; adding the slot lets parse_function_param
	// thread it through.
	type_annotation: Maybe(^TSTypeAnnotation),
}

ArrayPattern :: struct {
	loc:      Loc,
	elements: []Maybe(Pattern),
	// Same TS-position annotation as ObjectPattern (`function
	// f([a, b]: number[])`). Same drop bug, same fix (S26 W4b).
	type_annotation: Maybe(^TSTypeAnnotation),
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
	loc:              Loc,
	pattern:          Pattern,
	default_val:      Maybe(^Expression),
	// TS parameter property modifiers. When any is set, the emitter wraps
	// the parameter in a `TSParameterProperty` node (TS-ESTree shape).
	// modifier_start is the span.start of the first modifier keyword;
	// the outer TSParameterProperty node uses [modifier_start, param.loc.span.end].
	accessibility:    ClassAccessibility,  // None = not a parameter property
	readonly:         bool,
	override_:        bool,  // named override_ to avoid clash with Odin builtin
	modifier_start:   u32,   // source offset of the first modifier (0 = none)
}

FunctionExpression :: struct {
	loc:               Loc,
	id:                Maybe(BindingIdentifier),
	params:            [dynamic]FunctionParameter,
	body:              FunctionBody,
	generator:         bool,
	async:             bool,
	type_parameters:   Maybe(^TSTypeParameterDeclaration),
	return_type:       Maybe(^TSTypeAnnotation),
	declare:           bool,
	// True iff this is a TS overload signature / ambient declaration
	// (no `{ ... }` body — just `;` or ASI). Two TS-specific relaxations
	// key off this flag:
	//   1. Same-name FunctionDeclarations are NOT a duplicate-binding
	//      error when at least one of them is an overload sig.
	//   2. Same-name `export function`s aren't a duplicate-export error
	//      under the same condition (canonical TS overload pattern in
	//      `.d.ts` libraries: see @babel/types/lib/index-legacy.d.ts).
	no_body:           bool,
}

// ArrowFunctionBody discriminates the ESTree shape of an arrow's body.
// When the arrow uses a concise expression body (`x => x+1`), the variant
// is `^Expression`. When it uses a block body (`x => { return x+1 }`),
// the variant is `^BlockStatement`. Storing a ^BlockStatement through a
// ^Expression field previously caused UB during raw-transfer rewrite.
ArrowFunctionBody :: union {
	^Expression,
	^BlockStatement,
}

ArrowFunctionExpression :: struct {
	loc:                Loc,
	params:             [dynamic]FunctionParameter,
	body:               ArrowFunctionBody,
	expression:         bool,
	async:              bool,
	type_parameters:    Maybe(^TSTypeParameterDeclaration),
	return_type:        Maybe(^TSTypeAnnotation),
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

// TS class-member visibility modifier. .None means no modifier was written
// (the ESTree TS-ESTree shape then either omits `accessibility` or emits it
// as `null`; we omit unless the emit_ts_shape toggle is on). Order matches
// TypeScript/typescript-eslint's own string values.
ClassAccessibility :: enum u8 {
	None,
	Public,
	Private,
	Protected,
}

ClassElement :: struct {
	loc:             Loc,
	key:             ^Expression,
	value:           Maybe(^Expression),
	kind:            ClassElementKind,
	computed:        bool,
	static:          bool,
	is_accessor:     bool, // `accessor` keyword — emits as "AccessorProperty"
	decorators:      [dynamic]Decorator,
	abstract:        bool,
	type_annotation: Maybe(^TSTypeAnnotation),  // TS: `foo: T`
	optional:        bool,                        // TS: `foo?:`
	definite:        bool,                        // TS: `foo!:` (definite assignment)
	accessibility:   ClassAccessibility,          // TS: public/private/protected
	readonly:        bool,                        // TS: readonly
	override_:       bool,                        // TS: override
}

ClassExpression :: struct {
	loc:                  Loc,
	id:                   Maybe(BindingIdentifier),
	super_class:          Maybe(^Expression),
	body:                 ClassBody,
	decorators:           [dynamic]Decorator,
	type_parameters:      Maybe(^TSTypeParameterDeclaration),
	implements:           [dynamic]TSInterfaceHeritage,
	declare:              bool,
	abstract:             bool,
	// Appended last to preserve existing struct field offsets used by the
	// raw_transfer binary layout and verify_integration.js walker. Adding
	// a Maybe(^T) in the middle shifts every following field by 16 bytes,
	// which silently corrupts every walker offset for ClassDeclaration
	// downstream of the insertion point. (Hit on S26 W6 phase 3 bug class
	// #8: spec/typescript/002_generic_class binary walker reported
	// `body.body.length: kessel=0 oxc=3` because `body` had moved.)
	super_type_arguments: Maybe(^TSTypeParameterInstantiation),  // TS: `extends Foo<T, U>`
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
	// Directive prologue raw string (e.g. `"use strict"` including quotes).
	// Non-empty only when this ExpressionStatement is part of a prologue
	// (sequence of unparenthesised string-literal statements at the top of a
	// Program or function body). ESTree emits `directive: <raw>` on such
	// statements — a flag the spec uses to preserve directive intent across
	// source transformations. Empty string for regular `"hello";` statements.
	directive:  string,
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
	// TS-only: `var x!: T` definite assignment assertion. Mirrors the
	// `definite` flag on ClassElement (which uses the same `foo!:` syntax
	// for class fields). ESTree-TS shape emits `"definite": true` only when
	// set; OXC and ts-eslint both omit the field when false. Append-only at
	// end of struct (see HANDOFF design decision #6: middle-of-struct field
	// inserts shift binary-buffer offsets and silently corrupt raw_transfer).
	definite: bool,
}

VariableKind :: enum {
	Var,
	Let,
	Const,
	Using,
	AwaitUsing,
}

VariableDeclaration :: struct {
	loc:         Loc,
	kind:        VariableKind,
	declarations: [dynamic]VariableDeclarator,
	declare:     bool,
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
	loc:         Loc,
	specifiers:  [dynamic]^ImportSpecifierSpec,
	source:      StringLiteral,
	attributes:  [dynamic]ImportAttribute,
	import_kind: ImportExportKind,
	// Phase Imports stage-3: `import defer * as ns from "x"` or
	// `import source x from "x"`. "" for plain imports; "defer" or
	// "source" otherwise. Matches OXC's ImportDeclaration.phase.
	phase:       string,
}

ImportExportKind :: enum {
	Value,
	Type,
}

ImportSpecifierSpec :: union {
	ImportSpecifier,
	ImportDefaultSpecifier,
	ImportNamespaceSpecifier,
}

// ES2022 string-literal exports (`export { x as "string-name" }`) allow
// either a bare IdentifierName or a StringLiteral in both positions; the
// union picks one without an extra heap allocation for the common
// identifier case.
ExportSpecifierName :: union {
	IdentifierName,
	^StringLiteral,
}

ExportSpecifier :: struct {
	loc:       Loc,
	local:     ExportSpecifierName,
	exported:  ExportSpecifierName,
}

ExportNamedDeclaration :: struct {
	loc:        Loc,
	declaration: Maybe(^Declaration),
	specifiers: [dynamic]ExportSpecifier,
	source:     Maybe(StringLiteral),
	attributes: [dynamic]ImportAttribute,
	export_kind: ImportExportKind,
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
	attributes: [dynamic]ImportAttribute,
	export_kind: ImportExportKind,    // "value" by default; "type" for `export type * from`
}

// `export = expr;` — TS legacy CommonJS-compatible export. Body is a
// single expression. Distinct AST node from ExportDefaultDeclaration
// because semantics differ: only one TSExportAssignment per module is
// allowed and it cannot mix with named exports.
TSExportAssignment :: struct {
	loc:        Loc,
	expression: ^Expression,
}

// `export as namespace N;` — TS UMD-style global declaration in a
// declaration file. Maps the module's exports to a global identifier.
TSNamespaceExportDeclaration :: struct {
	loc: Loc,
	id:  Identifier,
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
	^ChainExpression,
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
	^JSXElement,
	^JSXFragment,
	^JSXText,
	^JSXExpressionContainer,
	^JSXEmptyExpression,
	^JSXSpreadChild,
	^TSAsExpression,
	^TSSatisfiesExpression,
	^TSNonNullExpression,
	^TSTypeAssertion,
	^TSInstantiationExpression,
	^ParenthesizedExpression,
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
	^TSInterfaceDeclaration,
	^TSTypeAliasDeclaration,
	^TSEnumDeclaration,
	^TSModuleDeclaration,
	^TSImportEqualsDeclaration,
	^TSExportAssignment,
	^TSNamespaceExportDeclaration,
}

Declaration :: union {
	^FunctionDeclaration,
	^VariableDeclaration,
	^ClassDeclaration,
	^ImportDeclaration,
	^ExportNamedDeclaration,
	^ExportDefaultDeclaration,
	^ExportAllDeclaration,
	^TSInterfaceDeclaration,
	^TSTypeAliasDeclaration,
	^TSEnumDeclaration,
	^TSModuleDeclaration,
	^TSImportEqualsDeclaration,
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
