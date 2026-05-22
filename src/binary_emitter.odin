package kessel

// ============================================================================
// Binary AST Emitter — compact binary format for cross-language consumption
//
// Walks the AST (same traversal as emitter.odin's JSON emission) and writes
// a compact binary stream. A JS reader (npm/kessel-parser/binary-reader.js)
// decodes this into ESTree-compatible plain objects using DataView.
//
// Format: [Header 16B] [Node stream ...] [String table ...]
//
// Each node in the stream is a variable-length record written in DFS
// pre-order. The JS reader reconstructs the tree by following the same
// DFS order — children appear immediately after their parent.
//
// Measured: binary decode in JS is ~30× faster than JSON.parse.
// ============================================================================

import "core:mem"
import "core:math"

// ============================================================================
// Node type IDs — shared between Odin emitter and JS reader.
// Keep in sync with TYPE_NAMES in binary-reader.js.
// ============================================================================

BinNodeType :: enum u8 {
	Program = 0,
	Identifier,
	PrivateIdentifier,
	NumericLiteral,       // "Literal" in ESTree with typeof value === "number"
	StringLiteral,        // "Literal" in ESTree with typeof value === "string"
	BooleanLiteral,       // "Literal" in ESTree with typeof value === "boolean"
	NullLiteral,          // "Literal" in ESTree with value === null
	BigIntLiteral,        // "Literal" in ESTree
	RegExpLiteral,        // "Literal" in ESTree with regex field
	TemplateLiteral,
	TemplateElement,
	TaggedTemplateExpression,
	ThisExpression,
	Super,
	ArrayExpression,
	ObjectExpression,
	Property,
	SpreadElement,
	FunctionExpression,
	ArrowFunctionExpression,
	ClassExpression,
	ClassBody,
	MethodDefinition,
	PropertyDefinition,
	StaticBlock,
	MemberExpression,
	CallExpression,
	NewExpression,
	ConditionalExpression,
	UpdateExpression,
	UnaryExpression,
	BinaryExpression,
	LogicalExpression,
	AssignmentExpression,
	SequenceExpression,
	YieldExpression,
	AwaitExpression,
	ImportExpression,
	MetaProperty,
	ChainExpression,
	ParenthesizedExpression,
	// Statements
	ExpressionStatement,
	Directive,
	BlockStatement,
	EmptyStatement,
	DebuggerStatement,
	ReturnStatement,
	BreakStatement,
	ContinueStatement,
	LabeledStatement,
	IfStatement,
	SwitchStatement,
	SwitchCase,
	WhileStatement,
	DoWhileStatement,
	ForStatement,
	ForInStatement,
	ForOfStatement,
	WithStatement,
	ThrowStatement,
	TryStatement,
	CatchClause,
	// Declarations
	FunctionDeclaration,
	VariableDeclaration,
	VariableDeclarator,
	ClassDeclaration,
	// Patterns
	ObjectPattern,
	ArrayPattern,
	AssignmentPattern,
	RestElement,
	// Module
	ImportDeclaration,
	ImportSpecifier,
	ImportDefaultSpecifier,
	ImportNamespaceSpecifier,
	ExportNamedDeclaration,
	ExportDefaultDeclaration,
	ExportAllDeclaration,
	ExportSpecifier,
	// JSX
	JSXElement,
	JSXFragment,
	JSXOpeningElement,
	JSXClosingElement,
	JSXOpeningFragment,
	JSXClosingFragment,
	JSXAttribute,
	JSXSpreadAttribute,
	JSXExpressionContainer,
	JSXEmptyExpression,
	JSXText,
	JSXIdentifier,
	JSXMemberExpression,
	JSXNamespacedName,
	JSXSpreadChild,
	// TS (subset — expand as needed)
	TSTypeAnnotation,
	TSTypeReference,
	TSAsExpression,
	TSSatisfiesExpression,
	TSNonNullExpression,
	TSTypeAssertion,
	TSInstantiationExpression,
	// Sentinel
	_Count,
}

// ============================================================================
// Value type tags for inline field data
// ============================================================================

BinValType :: enum u8 {
	Null      = 0,
	Bool      = 1,
	U32       = 2,
	F64       = 3,
	StringRef = 4,  // u32 index into string table
	Node      = 5,  // next record in stream is the child
	NodeArray = 6,  // u32 count, then count nodes follow
	NullNode  = 7,  // nullable node that is nil
}

// ============================================================================
// Binary Emitter state
// ============================================================================

BinaryEmitter :: struct {
	buf:          [dynamic]u8,       // output buffer
	pos:          int,               // write cursor
	strings:      [dynamic]string,   // string table (ordered by first occurrence)
	string_map:   map[string]u32,    // dedup: string → index in strings
	source:       string,            // borrowed source text
	node_count:   u32,
}

binary_emitter_init :: proc(be: ^BinaryEmitter, source: string, alloc: mem.Allocator) {
	cap := max(len(source), 64 * 1024)
	be.buf = make([dynamic]u8, cap, alloc)
	be.pos = 16  // skip header (filled at the end)
	be.strings = make([dynamic]string, 0, 4096, alloc)
	be.string_map = make(map[string]u32, 4096, alloc)
	be.source = source
	be.node_count = 0
}

binary_emitter_destroy :: proc(be: ^BinaryEmitter, alloc: mem.Allocator) {
	delete(be.buf)
	delete(be.strings)
	delete(be.string_map)
}

// Ensure buf has room for n more bytes. Grow by doubling if needed.
@(private="file")
be_ensure :: #force_inline proc(be: ^BinaryEmitter, n: int) {
	if be.pos + n > len(be.buf) {
		resize(&be.buf, max(len(be.buf) * 2, be.pos + n))
	}
}

// ============================================================================
// Low-level write helpers
// ============================================================================

@(private="file")
bw_u8 :: #force_inline proc(be: ^BinaryEmitter, v: u8) {
	be_ensure(be, 1)
	be.buf[be.pos] = v
	be.pos += 1
}

@(private="file")
bw_u32 :: #force_inline proc(be: ^BinaryEmitter, v: u32) {
	be_ensure(be, 4)
	p := be.pos
	be.buf[p]   = u8(v)
	be.buf[p+1] = u8(v >> 8)
	be.buf[p+2] = u8(v >> 16)
	be.buf[p+3] = u8(v >> 24)
	be.pos = p + 4
}

@(private="file")
bw_f64 :: #force_inline proc(be: ^BinaryEmitter, v: f64) {
	be_ensure(be, 8)
	bits := transmute(u64)v
	p := be.pos
	be.buf[p]   = u8(bits)
	be.buf[p+1] = u8(bits >> 8)
	be.buf[p+2] = u8(bits >> 16)
	be.buf[p+3] = u8(bits >> 24)
	be.buf[p+4] = u8(bits >> 32)
	be.buf[p+5] = u8(bits >> 40)
	be.buf[p+6] = u8(bits >> 48)
	be.buf[p+7] = u8(bits >> 56)
	be.pos = p + 8
}

@(private="file")
bw_bool :: #force_inline proc(be: ^BinaryEmitter, v: bool) {
	be_ensure(be, 1)
	be.buf[be.pos] = 1 if v else 0
	be.pos += 1
}

// Intern a string and write its index as u32.
@(private="file")
bw_string_ref :: proc(be: ^BinaryEmitter, s: string) {
	if idx, ok := be.string_map[s]; ok {
		bw_u32(be, idx)
		return
	}
	idx := u32(len(be.strings))
	append(&be.strings, s)
	be.string_map[s] = idx
	bw_u32(be, idx)
}

// ============================================================================
// Node emission — writes [type_id: u8] [start: u32] [end: u32] then fields
// ============================================================================

@(private="file")
bin_node_header :: proc(be: ^BinaryEmitter, type_id: BinNodeType, loc: Loc) {
	bw_u8(be, u8(type_id))
	bw_u32(be, loc.start)
	bw_u32(be, loc.end)
	be.node_count += 1
}

// ============================================================================
// AST walk — mirrors emitter.odin's emit_* procs
// ============================================================================

bin_emit_program :: proc(be: ^BinaryEmitter, program: ^Program) {
	bin_node_header(be, .Program, program.loc)
	// sourceType
	bw_string_ref(be, program.type == .Module ? "module" : "script")
	// body
	bw_u32(be, u32(len(program.body)))
	for stmt in program.body {
		bin_emit_statement(be, stmt)
	}
	// directives
	bw_u32(be, u32(len(program.directives)))
	for d in program.directives {
		bin_emit_directive(be, d)
	}
}

bin_emit_directive :: proc(be: ^BinaryEmitter, d: Directive) {
	bin_node_header(be, .Directive, d.loc)
	bw_string_ref(be, d.raw)
	// value (the string literal inline)
	bin_node_header(be, .StringLiteral, d.value.loc)
	bw_string_ref(be, d.value.value)
	bw_string_ref(be, d.value.raw)
}

bin_emit_statement :: proc(be: ^BinaryEmitter, stmt: ^Statement) {
	if stmt == nil || statement_inner_nil(stmt) {
		bw_u8(be, u8(BinValType.NullNode))
		return
	}
	#partial switch s in stmt^ {
	case ^ExpressionStatement:
		bin_node_header(be, .ExpressionStatement, s.loc)
		bin_emit_expression(be, s.expression)
	case ^BlockStatement:
		bin_node_header(be, .BlockStatement, s.loc)
		bw_u32(be, u32(len(s.body)))
		for child in s.body { bin_emit_statement(be, child) }
	case ^EmptyStatement:
		bin_node_header(be, .EmptyStatement, s.loc)
	case ^DebuggerStatement:
		bin_node_header(be, .DebuggerStatement, s.loc)
	case ^ReturnStatement:
		bin_node_header(be, .ReturnStatement, s.loc)
		if arg, ok := s.argument.?; ok && arg != nil {
			bw_u8(be, u8(BinValType.Node))
			bin_emit_expression(be, arg)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
	case ^BreakStatement:
		bin_node_header(be, .BreakStatement, s.loc)
		if label, ok := s.label.(LabelIdentifier); ok {
			bw_u8(be, u8(BinValType.StringRef))
			bw_string_ref(be, label.name)
		} else {
			bw_u8(be, u8(BinValType.Null))
		}
	case ^ContinueStatement:
		bin_node_header(be, .ContinueStatement, s.loc)
		if label, ok := s.label.(LabelIdentifier); ok {
			bw_u8(be, u8(BinValType.StringRef))
			bw_string_ref(be, label.name)
		} else {
			bw_u8(be, u8(BinValType.Null))
		}
	case ^IfStatement:
		bin_node_header(be, .IfStatement, s.loc)
		bin_emit_expression(be, s.test)
		bin_emit_statement(be, s.consequent)
		if alt, ok := s.alternate.?; ok && alt != nil {
			bw_u8(be, u8(BinValType.Node))
			bin_emit_statement(be, alt)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
	case ^WhileStatement:
		bin_node_header(be, .WhileStatement, s.loc)
		bin_emit_expression(be, s.test)
		bin_emit_statement(be, s.body)
	case ^DoWhileStatement:
		bin_node_header(be, .DoWhileStatement, s.loc)
		bin_emit_expression(be, s.test)
		bin_emit_statement(be, s.body)
	case ^ForStatement:
		bin_node_header(be, .ForStatement, s.loc)
		// init (VariableDeclaration | Expression | null)
		if d, ok := s.init_decl.?; ok && d != nil {
			bw_u8(be, u8(BinValType.Node))
			bin_emit_var_decl(be, d)
		} else if e, ok := s.init_expr.?; ok && e != nil {
			bw_u8(be, u8(BinValType.Node))
			bin_emit_expression(be, e)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
		// test
		if t, ok := s.test.?; ok && t != nil {
			bw_u8(be, u8(BinValType.Node))
			bin_emit_expression(be, t)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
		// update
		if u, ok := s.update.?; ok && u != nil {
			bw_u8(be, u8(BinValType.Node))
			bin_emit_expression(be, u)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
		bin_emit_statement(be, s.body)
	case ^ForInStatement:
		bin_node_header(be, .ForInStatement, s.loc)
		// left (VariableDeclaration | Expression)
		if d, ok := s.left_decl.?; ok && d != nil {
			bin_emit_var_decl(be, d)
		} else if e, ok := s.left_expr.?; ok && e != nil {
			bin_emit_expression(be, e)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
		bin_emit_expression(be, s.right)
		bin_emit_statement(be, s.body)
	case ^ForOfStatement:
		bin_node_header(be, .ForOfStatement, s.loc)
		bw_bool(be, s.await)
		// left (VariableDeclaration | Expression)
		if d, ok := s.left_decl.?; ok && d != nil {
			bin_emit_var_decl(be, d)
		} else if e, ok := s.left_expr.?; ok && e != nil {
			bin_emit_expression(be, e)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
		bin_emit_expression(be, s.right)
		bin_emit_statement(be, s.body)
	case ^ThrowStatement:
		bin_node_header(be, .ThrowStatement, s.loc)
		bin_emit_expression(be, s.argument)
	case ^TryStatement:
		bin_node_header(be, .TryStatement, s.loc)
		bin_emit_block(be, s.block)
		if handler, ok := s.handler.?; ok {
			bw_u8(be, u8(BinValType.Node))
			bin_node_header(be, .CatchClause, handler.loc)
			if param, pok := handler.param.?; pok {
				bw_u8(be, u8(BinValType.Node))
				bin_emit_pattern(be, param)
			} else {
				bw_u8(be, u8(BinValType.NullNode))
			}
			bin_emit_block(be, handler.body)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
		if fin, ok := s.finalizer.?; ok {
			bw_u8(be, u8(BinValType.Node))
			bin_emit_block(be, fin)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
	case ^SwitchStatement:
		bin_node_header(be, .SwitchStatement, s.loc)
		bin_emit_expression(be, s.discriminant)
		bw_u32(be, u32(len(s.cases)))
		for c in s.cases {
			bin_node_header(be, .SwitchCase, c.loc)
			if t, ok := c.test.?; ok && t != nil {
				bw_u8(be, u8(BinValType.Node))
				bin_emit_expression(be, t)
			} else {
				bw_u8(be, u8(BinValType.NullNode))
			}
			bw_u32(be, u32(len(c.consequent)))
			for cs in c.consequent { bin_emit_statement(be, cs) }
		}
	case ^LabeledStatement:
		bin_node_header(be, .LabeledStatement, s.loc)
		bw_string_ref(be, s.label.name)
		bin_emit_statement(be, s.body)
	case ^WithStatement:
		bin_node_header(be, .WithStatement, s.loc)
		bin_emit_expression(be, s.object)
		bin_emit_statement(be, s.body)
	case ^VariableDeclaration:
		bin_emit_var_decl(be, s)
	case ^FunctionDeclaration:
		bin_emit_function_node(be, .FunctionDeclaration, s)
	case ^ClassDeclaration:
		bin_emit_class(be, .ClassDeclaration, s)
	case ^ImportDeclaration:
		bin_node_header(be, .ImportDeclaration, s.loc)
		bw_u32(be, u32(len(s.specifiers)))
		for spec in s.specifiers {
			if spec == nil { bw_u8(be, u8(BinValType.NullNode)); continue }
			switch ss in spec^ {
			case ImportSpecifier:
				bin_node_header(be, .ImportSpecifier, ss.loc)
				bw_string_ref(be, ss.imported.name)
				bw_string_ref(be, ss.local.name)
			case ImportDefaultSpecifier:
				bin_node_header(be, .ImportDefaultSpecifier, ss.loc)
				bw_string_ref(be, ss.local.name)
			case ImportNamespaceSpecifier:
				bin_node_header(be, .ImportNamespaceSpecifier, ss.loc)
				bw_string_ref(be, ss.local.name)
			}
		}
		bw_string_ref(be, s.source.value)
	case ^ExportNamedDeclaration:
		bin_node_header(be, .ExportNamedDeclaration, s.loc)
		if decl, ok := s.declaration.?; ok && decl != nil {
			bw_u8(be, u8(BinValType.Node))
			bin_emit_declaration(be, decl)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
		bw_u32(be, u32(len(s.specifiers)))
		for spec in s.specifiers {
			bin_node_header(be, .ExportSpecifier, spec.loc)
			bin_emit_export_spec_name(be, spec.local)
			bin_emit_export_spec_name(be, spec.exported)
		}
		if src, ok := s.source.?; ok {
			bw_u8(be, u8(BinValType.StringRef))
			bw_string_ref(be, src.value)
		} else {
			bw_u8(be, u8(BinValType.Null))
		}
	case ^ExportDefaultDeclaration:
		bin_node_header(be, .ExportDefaultDeclaration, s.loc)
		bin_emit_export_default_def(be, s.declaration)
	case ^ExportAllDeclaration:
		bin_node_header(be, .ExportAllDeclaration, s.loc)
		bw_string_ref(be, s.source.value)
		if exported, ok := s.exported.?; ok {
			bw_u8(be, u8(BinValType.StringRef))
			bw_string_ref(be, exported.name)
		} else {
			bw_u8(be, u8(BinValType.Null))
		}
	case:
		// Unknown statement type — emit as null for now
		bw_u8(be, u8(BinValType.NullNode))
	}
}

bin_emit_expression :: proc(be: ^BinaryEmitter, expr: ^Expression) {
	if expr == nil || expression_inner_nil(expr) {
		bw_u8(be, u8(BinValType.NullNode))
		return
	}
	#partial switch e in expr^ {
	case ^Identifier:
		bin_node_header(be, .Identifier, e.loc)
		bw_string_ref(be, e.name)
	case ^PrivateIdentifier:
		bin_node_header(be, .PrivateIdentifier, e.loc)
		bw_string_ref(be, e.name)
	case ^NullLiteral:
		bin_node_header(be, .NullLiteral, e.loc)
	case ^BooleanLiteral:
		bin_node_header(be, .BooleanLiteral, e.loc)
		bw_bool(be, e.value)
	case ^NumericLiteral:
		bin_node_header(be, .NumericLiteral, e.loc)
		bw_f64(be, e.value)
		bw_string_ref(be, e.raw)
	case ^StringLiteral:
		bin_node_header(be, .StringLiteral, e.loc)
		bw_string_ref(be, e.value)
		bw_string_ref(be, e.raw)
	case ^BigIntLiteral:
		bin_node_header(be, .BigIntLiteral, e.loc)
		bw_string_ref(be, e.value)
		bw_string_ref(be, e.raw)
	case ^RegExpLiteral:
		bin_node_header(be, .RegExpLiteral, e.loc)
		bw_string_ref(be, e.pattern)
		bw_string_ref(be, e.flags)
	case ^TemplateLiteral:
		bin_node_header(be, .TemplateLiteral, e.loc)
		bw_u32(be, u32(len(e.quasis)))
		for q in e.quasis {
			bin_node_header(be, .TemplateElement, q.loc)
			bw_bool(be, q.tail)
			if cooked, ok := q.cooked.?; ok {
				bw_u8(be, 1) // has cooked
				bw_string_ref(be, cooked)
			} else {
				bw_u8(be, 0) // no cooked
			}
			bw_string_ref(be, q.raw)
		}
		bw_u32(be, u32(len(e.expressions)))
		for child in e.expressions { bin_emit_expression(be, child) }
	case ^TaggedTemplateExpression:
		bin_node_header(be, .TaggedTemplateExpression, e.loc)
		bin_emit_expression(be, e.tag)
		bin_emit_expression(be, e.quasi)
	case ^ThisExpression:
		bin_node_header(be, .ThisExpression, e.loc)
	case ^Super:
		bin_node_header(be, .Super, e.loc)
	case ^ArrayExpression:
		bin_node_header(be, .ArrayExpression, e.loc)
		bw_u32(be, u32(len(e.elements)))
		for child in e.elements {
			if c, ok := child.?; ok && c != nil {
				bin_emit_expression(be, c)
			} else {
				bw_u8(be, u8(BinValType.NullNode))
			}
		}
	case ^ObjectExpression:
		bin_node_header(be, .ObjectExpression, e.loc)
		bw_u32(be, u32(len(e.properties)))
		for prop in e.properties {
			bin_emit_property(be, prop)
		}
	case ^SpreadElement:
		bin_node_header(be, .SpreadElement, e.loc)
		bin_emit_expression(be, e.argument)
	case ^FunctionExpression:
		bin_emit_function_node(be, .FunctionExpression, e)
	case ^ArrowFunctionExpression:
		bin_node_header(be, .ArrowFunctionExpression, e.loc)
		bw_bool(be, e.async)
		bw_bool(be, e.expression)
		bw_u32(be, u32(len(e.params)))
		for param in e.params { bin_emit_param(be, param) }
		// body is ArrowFunctionBody union: ^Expression | ^BlockStatement
		switch b in e.body {
		case ^Expression:
			bin_emit_expression(be, b)
		case ^BlockStatement:
			if b != nil {
				bin_node_header(be, .BlockStatement, b.loc)
				bw_u32(be, u32(len(b.body)))
				for child in b.body { bin_emit_statement(be, child) }
			} else {
				bw_u8(be, u8(BinValType.NullNode))
			}
		}
	case ^ClassExpression:
		bin_emit_class(be, .ClassExpression, e)
	case ^MemberExpression:
		bin_node_header(be, .MemberExpression, e.loc)
		bw_bool(be, e.computed)
		bw_bool(be, e.optional)
		bin_emit_expression(be, e.object)
		bin_emit_expression(be, e.property)
	case ^CallExpression:
		bin_node_header(be, .CallExpression, e.loc)
		bw_bool(be, e.optional)
		bin_emit_expression(be, e.callee)
		bw_u32(be, u32(len(e.arguments)))
		for arg in e.arguments { bin_emit_expression(be, arg) }
	case ^NewExpression:
		bin_node_header(be, .NewExpression, e.loc)
		bin_emit_expression(be, e.callee)
		bw_u32(be, u32(len(e.arguments)))
		for arg in e.arguments { bin_emit_expression(be, arg) }
	case ^ConditionalExpression:
		bin_node_header(be, .ConditionalExpression, e.loc)
		bin_emit_expression(be, e.test)
		bin_emit_expression(be, e.consequent)
		bin_emit_expression(be, e.alternate)
	case ^UpdateExpression:
		bin_node_header(be, .UpdateExpression, e.loc)
		op_str: string
		switch e.operator {
		case .Increment: op_str = "++"
		case .Decrement: op_str = "--"
		}
		bw_string_ref(be, op_str)
		bw_bool(be, e.prefix)
		bin_emit_expression(be, e.argument)
	case ^UnaryExpression:
		bin_node_header(be, .UnaryExpression, e.loc)
		bw_string_ref(be, unary_op_to_string(e.operator))
		bw_bool(be, e.prefix)
		bin_emit_expression(be, e.argument)
	case ^BinaryExpression:
		bin_node_header(be, .BinaryExpression, e.loc)
		bw_string_ref(be, binary_op_to_string(e.operator))
		bin_emit_expression(be, e.left)
		bin_emit_expression(be, e.right)
	case ^LogicalExpression:
		bin_node_header(be, .LogicalExpression, e.loc)
		lop_str: string
		#partial switch e.operator {
		case .And: lop_str = "&&"
		case .Or:  lop_str = "||"
		case .NullishCoalescing: lop_str = "??"
		}
		bw_string_ref(be, lop_str)
		bin_emit_expression(be, e.left)
		bin_emit_expression(be, e.right)
	case ^AssignmentExpression:
		bin_node_header(be, .AssignmentExpression, e.loc)
		bw_string_ref(be, assignment_op_to_string(e.operator))
		bin_emit_expression(be, e.left)
		bin_emit_expression(be, e.right)
	case ^SequenceExpression:
		bin_node_header(be, .SequenceExpression, e.loc)
		bw_u32(be, u32(len(e.expressions)))
		for child in e.expressions { bin_emit_expression(be, child) }
	case ^YieldExpression:
		bin_node_header(be, .YieldExpression, e.loc)
		bw_bool(be, e.delegate)
		if arg, ok := e.argument.?; ok && arg != nil {
			bw_u8(be, u8(BinValType.Node))
			bin_emit_expression(be, arg)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
	case ^AwaitExpression:
		bin_node_header(be, .AwaitExpression, e.loc)
		bin_emit_expression(be, e.argument)
	case ^ImportExpression:
		bin_node_header(be, .ImportExpression, e.loc)
		bin_emit_expression(be, e.source)
	case ^MetaProperty:
		bin_node_header(be, .MetaProperty, e.loc)
		bw_string_ref(be, e.meta.name)
		bw_string_ref(be, e.property.name)
	case ^ChainExpression:
		bin_node_header(be, .ChainExpression, e.loc)
		bin_emit_expression(be, e.expression)
	case ^ParenthesizedExpression:
		bin_node_header(be, .ParenthesizedExpression, e.loc)
		bin_emit_expression(be, e.expression)
	case:
		bw_u8(be, u8(BinValType.NullNode))
	}
}

bin_emit_pattern :: proc(be: ^BinaryEmitter, pat: Pattern) {
	#partial switch p in pat {
	case ^Identifier:
		bin_node_header(be, .Identifier, p.loc)
		bw_string_ref(be, p.name)
	case ^ObjectPattern:
		bin_node_header(be, .ObjectPattern, p.loc)
		bw_u32(be, u32(len(p.properties)))
		for prop in p.properties {
			bin_emit_obj_pat_prop(be, prop)
		}
	case ^ArrayPattern:
		bin_node_header(be, .ArrayPattern, p.loc)
		bw_u32(be, u32(len(p.elements)))
		for elem in p.elements {
			if e, ok := elem.?; ok {
				bw_u8(be, u8(BinValType.Node))
				bin_emit_pattern(be, e)
			} else {
				bw_u8(be, u8(BinValType.NullNode))
			}
		}
	case ^AssignmentPattern:
		bin_node_header(be, .AssignmentPattern, p.loc)
		bin_emit_pattern(be, p.left)
		bin_emit_expression(be, p.right)
	case ^RestElement:
		bin_node_header(be, .RestElement, p.loc)
		bin_emit_pattern(be, p.argument)
	case ^MemberExpression:
		bin_node_header(be, .MemberExpression, p.loc)
		bw_bool(be, p.computed)
		bw_bool(be, p.optional)
		bin_emit_expression(be, p.object)
		bin_emit_expression(be, p.property)
	case:
		bw_u8(be, u8(BinValType.NullNode))
	}
}

@(private="file")
bin_emit_property :: proc(be: ^BinaryEmitter, prop: Property) {
	bin_node_header(be, .Property, prop.loc)
	bw_u8(be, u8(prop.kind))
	bw_bool(be, prop.computed)
	bw_bool(be, prop.shorthand)
	bin_emit_expression(be, prop.key)
	bin_emit_expression(be, prop.value)
}

@(private="file")
bin_emit_obj_pat_prop :: proc(be: ^BinaryEmitter, prop: ObjectPatternProperty) {
	bin_node_header(be, .Property, prop.loc)
	bw_bool(be, prop.computed)
	bw_bool(be, prop.shorthand)
	// key (Maybe)
	if key, ok := prop.key.?; ok {
		switch k in key {
		case ^Expression:
			bin_emit_expression(be, k)
		case IdentifierName:
			bin_node_header(be, .Identifier, k.loc)
			bw_string_ref(be, k.name)
		case ^StringLiteral:
			if k != nil {
				bin_node_header(be, .StringLiteral, k.loc)
				bw_string_ref(be, k.value)
				bw_string_ref(be, k.raw)
			} else {
				bw_u8(be, u8(BinValType.NullNode))
			}
		case ^NumericLiteral:
			if k != nil {
				bin_node_header(be, .NumericLiteral, k.loc)
				bw_f64(be, k.value)
				bw_string_ref(be, k.raw)
			} else {
				bw_u8(be, u8(BinValType.NullNode))
			}
		}
	} else {
		bw_u8(be, u8(BinValType.NullNode))
	}
	bin_emit_pattern(be, prop.value)
}

@(private="file")
bin_emit_declaration :: proc(be: ^BinaryEmitter, decl: ^Declaration) {
	if decl == nil { bw_u8(be, u8(BinValType.NullNode)); return }
	#partial switch d in decl^ {
	case ^FunctionDeclaration:
		bin_emit_function_node(be, .FunctionDeclaration, d)
	case ^VariableDeclaration:
		bin_emit_var_decl(be, d)
	case ^ClassDeclaration:
		bin_emit_class(be, .ClassDeclaration, d)
	case:
		bw_u8(be, u8(BinValType.NullNode))
	}
}

@(private="file")
bin_emit_export_default_def :: proc(be: ^BinaryEmitter, def: ^ExportDefaultDef) {
	if def == nil { bw_u8(be, u8(BinValType.NullNode)); return }
	switch d in def^ {
	case ^Declaration:
		bin_emit_declaration(be, d)
	case ^Expression:
		bin_emit_expression(be, d)
	}
}

@(private="file")
bin_emit_var_decl :: proc(be: ^BinaryEmitter, s: ^VariableDeclaration) {
	bin_node_header(be, .VariableDeclaration, s.loc)
	bw_u8(be, u8(s.kind))
	bw_u32(be, u32(len(s.declarations)))
	for d in s.declarations {
		bin_node_header(be, .VariableDeclarator, d.loc)
		bin_emit_pattern(be, d.id)
		if init, ok := d.init.(^Expression); ok && init != nil {
			bw_u8(be, u8(BinValType.Node))
			bin_emit_expression(be, init)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
	}
}

@(private="file")
bin_emit_export_spec_name :: proc(be: ^BinaryEmitter, name: ExportSpecifierName) {
	switch n in name {
	case IdentifierName:
		bw_string_ref(be, n.name)
	case ^StringLiteral:
		if n != nil {
			bw_string_ref(be, n.value)
		} else {
			bw_string_ref(be, "")
		}
	}
}

// ============================================================================
// Shared helpers for function / class emission
// ============================================================================

@(private="file")
bin_emit_block :: proc(be: ^BinaryEmitter, block: BlockStatement) {
	bin_node_header(be, .BlockStatement, block.loc)
	bw_u32(be, u32(len(block.body)))
	for child in block.body { bin_emit_statement(be, child) }
}

@(private="file")
bin_emit_function_body :: proc(be: ^BinaryEmitter, body: FunctionBody) {
	bin_node_header(be, .BlockStatement, body.loc)
	bw_u32(be, u32(len(body.body)))
	for child in body.body { bin_emit_statement(be, child) }
}

@(private="file")
bin_emit_function_node :: proc(be: ^BinaryEmitter, type_id: BinNodeType, fn: ^FunctionExpression) {
	bin_node_header(be, type_id, fn.loc)
	// id
	if bid, ok := fn.id.(BindingIdentifier); ok {
		bw_u8(be, u8(BinValType.StringRef))
		bw_string_ref(be, bid.name)
	} else {
		bw_u8(be, u8(BinValType.Null))
	}
	bw_bool(be, fn.async)
	bw_bool(be, fn.generator)
	bw_u32(be, u32(len(fn.params)))
	for param in fn.params { bin_emit_param(be, param) }
	bin_emit_function_body(be, fn.body)
}

@(private="file")
bin_emit_param :: proc(be: ^BinaryEmitter, param: FunctionParameter) {
	bin_emit_pattern(be, param.pattern)
	if def, ok := param.default_val.(^Expression); ok && def != nil {
		bw_u8(be, u8(BinValType.Node))
		bin_emit_expression(be, def)
	} else {
		bw_u8(be, u8(BinValType.NullNode))
	}
}

@(private="file")
bin_emit_class :: proc(be: ^BinaryEmitter, type_id: BinNodeType, class: ^$T) {
	bin_node_header(be, type_id, class.loc)
	// id
	if bid, ok := class.id.(BindingIdentifier); ok {
		bw_u8(be, u8(BinValType.StringRef))
		bw_string_ref(be, bid.name)
	} else {
		bw_u8(be, u8(BinValType.Null))
	}
	// superClass
	if sc, ok := class.super_class.?; ok && sc != nil {
		bw_u8(be, u8(BinValType.Node))
		bin_emit_expression(be, sc)
	} else {
		bw_u8(be, u8(BinValType.NullNode))
	}
	// body (ClassBody)
	bin_node_header(be, .ClassBody, class.body.loc)
	bw_u32(be, u32(len(class.body.body)))
	for elem in class.body.body {
		bin_emit_class_element(be, elem)
	}
}

@(private="file")
bin_emit_class_element :: proc(be: ^BinaryEmitter, elem: ClassElement) {
	#partial switch elem.kind {
	case .StaticBlock:
		bin_node_header(be, .StaticBlock, elem.loc)
		if v, ok := elem.value.?; ok && v != nil {
			bin_emit_expression(be, v) // FunctionExpression wrapping the block body
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
	case .Method, .Get, .Set, .Constructor:
		bin_node_header(be, .MethodDefinition, elem.loc)
		bw_u8(be, u8(elem.kind))
		bw_bool(be, elem.computed)
		bw_bool(be, elem.static)
		if elem.key != nil {
			bw_u8(be, u8(BinValType.Node))
			bin_emit_expression(be, elem.key)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
		if v, ok := elem.value.?; ok && v != nil {
			bw_u8(be, u8(BinValType.Node))
			bin_emit_expression(be, v)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
	case: // Property (field definition)
		bin_node_header(be, .PropertyDefinition, elem.loc)
		bw_bool(be, elem.computed)
		bw_bool(be, elem.static)
		if elem.key != nil {
			bw_u8(be, u8(BinValType.Node))
			bin_emit_expression(be, elem.key)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
		if v, ok := elem.value.?; ok && v != nil {
			bw_u8(be, u8(BinValType.Node))
			bin_emit_expression(be, v)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
	}
}

// ============================================================================
// Finalize — write header + string table
// ============================================================================

bin_emit_finalize :: proc(be: ^BinaryEmitter) {
	string_table_off := u32(be.pos)

	source_ptr := uintptr(raw_data(be.source))
	source_end := source_ptr + uintptr(len(be.source))

	// First pass: write [offset, length] entries for each string
	for s in be.strings {
		ptr := uintptr(raw_data(s))
		if ptr >= source_ptr && ptr < source_end {
			bw_u32(be, u32(ptr - source_ptr))
			bw_u32(be, u32(len(s)))
		} else {
			// Placeholder for cooked string — patched in second pass
			bw_u32(be, 0x80000000)
			bw_u32(be, u32(len(s)))
		}
	}

	// Second pass: append cooked string bytes and patch offsets
	for s, i in be.strings {
		ptr := uintptr(raw_data(s))
		if ptr < source_ptr || ptr >= source_end {
			entry_off := int(string_table_off) + i * 8
			actual_off := u32(be.pos) | 0x80000000
			be.buf[entry_off + 0] = u8(actual_off)
			be.buf[entry_off + 1] = u8(actual_off >> 8)
			be.buf[entry_off + 2] = u8(actual_off >> 16)
			be.buf[entry_off + 3] = u8(actual_off >> 24)
			be_ensure(be, len(s))
			copy(be.buf[be.pos:], transmute([]u8)s)
			be.pos += len(s)
		}
	}

	// Write header at offset 0
	magic := u32(0x4B455354)  // "KEST"
	be.buf[0]  = u8(magic);       be.buf[1]  = u8(magic >> 8)
	be.buf[2]  = u8(magic >> 16); be.buf[3]  = u8(magic >> 24)
	version := u32(1)
	be.buf[4]  = u8(version);     be.buf[5]  = u8(version >> 8)
	be.buf[6]  = u8(version >> 16); be.buf[7]  = u8(version >> 24)
	nc := be.node_count
	be.buf[8]  = u8(nc);          be.buf[9]  = u8(nc >> 8)
	be.buf[10] = u8(nc >> 16);    be.buf[11] = u8(nc >> 24)
	st := string_table_off
	be.buf[12] = u8(st);          be.buf[13] = u8(st >> 8)
	be.buf[14] = u8(st >> 16);    be.buf[15] = u8(st >> 24)
}
