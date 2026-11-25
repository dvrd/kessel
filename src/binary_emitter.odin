package kessel

// ============================================================================
// Binary AST Emitter — compact binary format for cross-language consumption
//
// Walks the AST (same traversal as emitter.odin's JSON emission) and writes
// a compact binary stream. A JS reader (npm/binary-reader.js)
// decodes this into ESTree-compatible plain objects using DataView.
//
// Format: [Header 16B] [Node stream ...] [String table ...]
//
// Each node in the stream is a variable-length record written in DFS
// pre-order. The JS reader reconstructs the tree by following the same
// DFS order — children appear immediately after their parent.
//
// Binary decode path is ~3× faster than JSON.parse end-to-end.
// ============================================================================

import "core:mem"

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
	TypedRecord,
	TypedPrefix,
	Hashbang,
	// Sentinel
	_Count,
}

// ============================================================================
// Value type tags for inline field data
// ============================================================================

// Value type tags — used as prefixes before nullable node fields.
// IMPORTANT: these must NOT collide with any BinNodeType value (0..99).
// Tags 0xFD and 0xFE are safely above the type ID range.
BinValType :: enum u8 {
	Null      = 0,   // used for non-node nullable fields (e.g. string tags)
	StringRef = 4,   // u32 index into string table
	Node      = 0xFD,  // next record in stream is the child node
	NullNode  = 0xFE,  // nullable node that is nil
}

// ============================================================================
// Binary Emitter state
// ============================================================================

// Binary format version. Bump when the on-the-wire layout changes;
// the JS decoder (npm/kessel/binary-reader.js) hard-checks this.
//
//   v1: [header 16B] [nodes] [string table]
//   v2: [header 24B] [nodes] [errors{start,end,msg_len,msg}] [strings]
//   v3: same on-wire shape; explicit `end` per error (was implicit start+1)
//   v4: [header 24B] [nodes] [errors{start,end,code:u16,sev:u8,_pad:u8,msg_len,msg}] [strings]
//       errors gained a stable K-code and severity for FFI consumers.
//   v5: PropertyDefinition encodes static (bit 0) and declare (bit 1) in the
//       former static byte. Emit v4 for trees that only use the original flags.
//   v6: Names and module sources formerly stored as string indexes are child
//       nodes with their original spans. Absent optional fields keep their null tag.
//   v7: Typed records and field prefixes share the string table with fixed-layout nodes.
//   v8: A byte immediately before the string table identifies the TypeScript ESTree shape.
//       JavaScript decorators can use typed records, and plain TypeScript may use none.
//   v9: A Program that starts with `#!` ends with a Hashbang node. Emitted only for such
//       programs; every other tree keeps the version it had.
BINARY_VERSION_DIAGNOSTICS     :: u32(4)
BINARY_VERSION_DECLARED_FIELDS :: u32(5)
BINARY_VERSION_CHILD_SPANS     :: u32(6)
BINARY_VERSION_TYPES           :: u32(7)
BINARY_VERSION_SOURCE_SHAPE    :: u32(8)
BINARY_VERSION_HASHBANG        :: u32(9)
#assert(BINARY_VERSION_HASHBANG > BINARY_VERSION_SOURCE_SHAPE)
BINARY_HEADER_SIZE    :: 24

BinaryEmitter :: struct {
	scratch:      mem.Allocator, // Borrowed parser arena for temporary token data.
	buf:          [dynamic]u8,       // output buffer
	pos:          int,               // write cursor
	strings:      [dynamic]string,   // string table (ordered by first occurrence)
	string_map:   map[string]u32,    // dedup: string → index in strings
	source:       string,            // borrowed source text
	ts_shape:     bool,
	node_count:   u32,
	version:      u32,               // lowest compatible wire version for this tree
	errors_off:   u32,               // start of errors section (0 = no errors written)
	error_count:  u32,               // count of errors written
}

binary_emitter_init :: proc(be: ^BinaryEmitter, source: string, alloc, scratch: mem.Allocator, ts_shape: bool) {
	be.scratch = scratch
	cap := max(len(source), 64 * 1024)
	be.buf = make([dynamic]u8, cap, alloc)
	be.pos = BINARY_HEADER_SIZE  // skip header (filled at the end)
	be.strings = make([dynamic]string, 0, 4096, alloc)
	be.string_map = make(map[string]u32, 4096, alloc)
	be.source = source
	be.node_count = 0
	be.ts_shape = ts_shape
	be.version = BINARY_VERSION_SOURCE_SHAPE if ts_shape else BINARY_VERSION_DIAGNOSTICS
}

binary_emitter_destroy :: proc(be: ^BinaryEmitter, alloc: mem.Allocator) {
	delete(be.buf)
	delete(be.strings)
	delete(be.string_map)
}

// Ensure buf has room for n more bytes. Grow by doubling if needed.
be_ensure :: #force_inline proc(be: ^BinaryEmitter, n: int) {
	if be.pos + n > len(be.buf) {
		resize(&be.buf, max(len(be.buf) * 2, be.pos + n))
	}
}

// ============================================================================
// Low-level write helpers
// ============================================================================

bw_u8 :: #force_inline proc(be: ^BinaryEmitter, v: u8) {
	be_ensure(be, 1)
	be.buf[be.pos] = v
	be.pos += 1
}

bw_u16 :: #force_inline proc(be: ^BinaryEmitter, v: u16) {
	be_ensure(be, 2)
	p := be.pos
	be.buf[p]   = u8(v)
	be.buf[p+1] = u8(v >> 8)
	be.pos = p + 2
}

bw_u32 :: #force_inline proc(be: ^BinaryEmitter, v: u32) {
	be_ensure(be, 4)
	// Single unaligned little-endian store; u32le byte-swaps only on
	// big-endian hosts so the wire format stays LE everywhere.
	(^u32le)(&be.buf[be.pos])^ = u32le(v)
	be.pos += 4
}

bw_f64 :: #force_inline proc(be: ^BinaryEmitter, v: f64) {
	be_ensure(be, 8)
	(^u64le)(&be.buf[be.pos])^ = u64le(transmute(u64)v)
	be.pos += 8
}

bw_bool :: #force_inline proc(be: ^BinaryEmitter, v: bool) {
	be_ensure(be, 1)
	be.buf[be.pos] = 1 if v else 0
	be.pos += 1
}

// Intern a string and write its index as u32.
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
	bw_string_ref(be, program.type == .Module ? "module" : "script")
	bw_u32(be, u32(len(program.body)))
	for stmt in program.body {
		bin_emit_statement(be, stmt)
	}
	bw_u32(be, u32(len(program.directives)))
	for d in program.directives {
		bin_emit_directive(be, d)
	}
	// Written only when present, so a program without a hashbang keeps its
	// earlier layout and version; a v9 reader reads it for v9 buffers only.
	if hashbang, present := program.hashbang.?; present {
		be.version = max(be.version, BINARY_VERSION_HASHBANG)
		bin_node_header(be, .Hashbang, hashbang.loc)
		bw_string_ref(be, hashbang.value)
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
	// Complete switch (no #partial): every Statement variant must have an explicit
	// case so a newly-added AST node fails the build instead of being silently
	// emitted as NullNode in the binary buffer consumed by the npm reader.
	switch s in stmt^ {
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
		bin_emit_optional_identifier(be, s.label)
	case ^ContinueStatement:
		bin_node_header(be, .ContinueStatement, s.loc)
		bin_emit_optional_identifier(be, s.label)
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
		if d, ok := s.init_decl.?; ok && d != nil {
			bw_u8(be, u8(BinValType.Node))
			bin_emit_var_decl(be, d)
		} else if e, found := s.init_expr.?; found && e != nil {
			bw_u8(be, u8(BinValType.Node))
			bin_emit_expression(be, e)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
		if t, ok := s.test.?; ok && t != nil {
			bw_u8(be, u8(BinValType.Node))
			bin_emit_expression(be, t)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
		if u, ok := s.update.?; ok && u != nil {
			bw_u8(be, u8(BinValType.Node))
			bin_emit_expression(be, u)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
		bin_emit_statement(be, s.body)
	case ^ForInStatement:
		bin_node_header(be, .ForInStatement, s.loc)
		if d, ok := s.left_decl.?; ok && d != nil {
			bin_emit_var_decl(be, d)
		} else if e, found := s.left_expr.?; found && e != nil {
			bin_emit_expression(be, e)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
		bin_emit_expression(be, s.right)
		bin_emit_statement(be, s.body)
	case ^ForOfStatement:
		bin_node_header(be, .ForOfStatement, s.loc)
		bw_bool(be, s.await)
		if d, ok := s.left_decl.?; ok && d != nil {
			bin_emit_var_decl(be, d)
		} else if e, found := s.left_expr.?; found && e != nil {
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
		bin_emit_identifier_child(be, s.label.loc, s.label.name)
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
		if s.import_kind == .Type {
			bin_extra(be)
			bin_field_text(be, "importKind", "type")
			bin_fields_end(be)
		}
		bin_node_header(be, .ImportDeclaration, s.loc)
		bw_u32(be, u32(len(s.specifiers)))
		for spec in s.specifiers {
			if spec == nil { bw_u8(be, u8(BinValType.NullNode)); continue }
			switch ss in spec^ {
			case ImportSpecifier:
				if ss.loc.start < ss.imported.loc.start {
					bin_extra(be)
					bin_field_text(be, "importKind", "type")
					bin_fields_end(be)
				}
				bin_node_header(be, .ImportSpecifier, ss.loc)
				bin_emit_module_name_child(be, ss.imported)
				bin_emit_identifier_child(be, ss.local.loc, ss.local.name)
			case ImportDefaultSpecifier:
				bin_node_header(be, .ImportDefaultSpecifier, ss.loc)
				bin_emit_identifier_child(be, ss.local.loc, ss.local.name)
			case ImportNamespaceSpecifier:
				bin_node_header(be, .ImportNamespaceSpecifier, ss.loc)
				bin_emit_identifier_child(be, ss.local.loc, ss.local.name)
			}
		}
		bin_emit_string_child(be, s.source.loc, s.source.value, s.source.raw)
	case ^ExportNamedDeclaration:
		if s.export_kind == .Type {
			bin_extra(be)
			bin_field_text(be, "exportKind", "type")
			bin_fields_end(be)
		}
		bin_node_header(be, .ExportNamedDeclaration, s.loc)
		if decl, ok := s.declaration.?; ok && decl != nil {
			bw_u8(be, u8(BinValType.Node))
			bin_emit_declaration(be, decl)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
		bw_u32(be, u32(len(s.specifiers)))
		for &spec in s.specifiers {
			type_only := export_specifier_is_type(&spec)
			if type_only {
				bin_extra(be)
				bin_field_text(be, "exportKind", "type")
				bin_fields_end(be)
			}
			bin_node_header(be, .ExportSpecifier, spec.loc)
			bin_emit_export_spec_name(be, spec.local)
			bin_emit_export_spec_name(be, spec.exported)
		}
		if src, ok := s.source.?; ok {
			bw_u8(be, u8(BinValType.Node))
			bin_emit_string_child(be, src.loc, src.value, src.raw)
		} else {
			bw_u8(be, u8(BinValType.Null))
		}
	case ^ExportDefaultDeclaration:
		bin_node_header(be, .ExportDefaultDeclaration, s.loc)
		bin_emit_export_default_def(be, s.declaration)
	case ^ExportAllDeclaration:
		if s.export_kind == .Type {
			bin_extra(be)
			bin_field_text(be, "exportKind", "type")
			bin_fields_end(be)
		}
		bin_node_header(be, .ExportAllDeclaration, s.loc)
		bin_emit_string_child(be, s.source.loc, s.source.value, s.source.raw)
		if exported, ok := s.exported.?; ok {
			bw_u8(be, u8(BinValType.Node))
			bin_emit_module_name_child(be, exported)
		} else {
			bw_u8(be, u8(BinValType.Null))
		}
	case ^TSInterfaceDeclaration: bin_type_interface(be, s)
	case ^TSTypeAliasDeclaration: bin_type_alias(be, s)
	case ^TSEnumDeclaration: bin_type_enum(be, s)
	case ^TSModuleDeclaration: bin_type_module(be, s)
	case ^TSImportEqualsDeclaration: bin_type_import_equals(be, s)
	case ^TSExportAssignment:
		bin_record(be, "TSExportAssignment", s.loc)
		bin_field_expr(be, "expression", s.expression)
		bin_fields_end(be)
	case ^TSNamespaceExportDeclaration:
		bin_record(be, "TSNamespaceExportDeclaration", s.loc)
		bin_field(be, .Node, "id")
		bin_type_identifier(be, s.id.loc, s.id.name)
		bin_fields_end(be)
	}
}

// bin_emit_expression_chain emits a member / call / binary / logical
// chain. The parser builds these in a loop and does not limit their
// length, so one frame per link would overflow the stack on a generated
// million-term expression. The byte stream is identical to the recursive
// form: every link's header and leading fields on the way down, then the
// innermost operand, then each link's remaining fields on the way up.
bin_emit_expression_chain :: proc(be: ^BinaryEmitter, expr: ^Expression) {
	assert(expr_is_spine_node(expr))
	spine: ExprSpine = ---
	if !expr_spine_open(&spine, expr) {
		// No memory for the chain table: a null node keeps the stream
		// well-formed, which a partial chain would not.
		bw_u8(be, u8(BinValType.NullNode))
		return
	}
	defer expr_spine_close(&spine)

	for node in spine.nodes { bin_emit_expression_chain_enter(be, node) }
	bin_emit_expression(be, spine.leaf)
	#reverse for node in spine.nodes { bin_emit_expression_chain_leave(be, node) }
}

// bin_emit_expression_chain_enter writes what precedes a link's chain
// operand in the stream.
bin_emit_expression_chain_enter :: proc(be: ^BinaryEmitter, expr: ^Expression) {
	#partial switch e in expr^ {
	case ^MemberExpression:
		bin_node_header(be, .MemberExpression, e.loc)
		bw_bool(be, e.computed)
		bw_bool(be, e.optional)
	case ^CallExpression:
		if e.type_parameters != nil {
			bin_extra(be)
			bin_field_type_args(be, e.type_parameters)
			bin_fields_end(be)
		}
		bin_node_header(be, .CallExpression, e.loc)
		bw_bool(be, e.optional)
	case ^BinaryExpression:
		bin_node_header(be, .BinaryExpression, e.loc)
		bw_string_ref(be, binary_op_to_string(e.operator))
	case ^LogicalExpression:
		bin_node_header(be, .LogicalExpression, e.loc)
		lop_str: string
		#partial switch e.operator {
		case .And: lop_str = "&&"
		case .Or:  lop_str = "||"
		case .NullishCoalescing: lop_str = "??"
		}
		bw_string_ref(be, lop_str)
	case:
		unreachable()
	}
}

// bin_emit_expression_chain_leave writes what follows a link's chain
// operand in the stream.
bin_emit_expression_chain_leave :: proc(be: ^BinaryEmitter, expr: ^Expression) {
	#partial switch e in expr^ {
	case ^MemberExpression:
		bin_emit_expression(be, e.property)
	case ^CallExpression:
		bw_u32(be, u32(len(e.arguments)))
		for arg in e.arguments { bin_emit_expression(be, arg) }
	case ^BinaryExpression:
		bin_emit_expression(be, e.right)
	case ^LogicalExpression:
		bin_emit_expression(be, e.right)
	case:
		unreachable()
	}
}

bin_emit_expression :: proc(be: ^BinaryEmitter, expr: ^Expression) {
	if expr == nil || expression_inner_nil(expr) {
		bw_u8(be, u8(BinValType.NullNode))
		return
	}
	// Complete switch (no #partial): every Expression variant must have an explicit
	// case so a newly-added AST node fails the build instead of being silently
	// emitted as NullNode in the binary buffer consumed by the npm reader.
	switch e in expr^ {
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
		for q in e.quasis { bin_template_element(be, q) }
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
		if e.type_parameters != nil || e.return_type != nil {
			bin_extra(be)
			bin_field_generics(be, e.type_parameters)
			bin_field_annotation(be, "returnType", e.return_type)
			bin_fields_end(be)
		}
		bin_node_header(be, .ArrowFunctionExpression, e.loc)
		bw_bool(be, e.async)
		bw_bool(be, e.expression)
		bw_u32(be, u32(len(e.params)))
		for param in e.params { bin_emit_param(be, param) }
		// body is ArrowFunctionBody union: ^Expression | ^BlockStatement.
		// Use VT_Node / VT_NullNode tagging so the reader can distinguish.
		switch b in e.body {
		case ^Expression:
			if b != nil && !expression_inner_nil(b) {
				bin_emit_expression(be, b)
			} else {
				bw_u8(be, u8(BinValType.NullNode))
			}
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
	case ^MemberExpression, ^CallExpression, ^BinaryExpression, ^LogicalExpression:
		// Unbounded chains: emitted by a loop, not one frame per link.
		bin_emit_expression_chain(be, expr)
	case ^NewExpression:
		if e.type_parameters != nil {
			bin_extra(be)
			bin_field_type_args(be, e.type_parameters)
			bin_fields_end(be)
		}
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
		bin_emit_identifier_child(be, e.meta.loc, e.meta.name)
		bin_emit_identifier_child(be, e.property.loc, e.property.name)
	case ^ChainExpression:
		bin_node_header(be, .ChainExpression, e.loc)
		bin_emit_expression(be, e.expression)
	case ^ParenthesizedExpression:
		bin_node_header(be, .ParenthesizedExpression, e.loc)
		bin_emit_expression(be, e.expression)
	// ===================== JSX =====================
	case ^JSXElement:
		bin_node_header(be, .JSXElement, e.loc)
		bin_emit_jsx_opening(be, e.opening_element)
		bw_u32(be, u32(len(e.children)))
		for child in e.children { bin_emit_jsx_child(be, child) }
		if ce, ok := e.closing_element.?; ok && ce != nil {
			bw_u8(be, u8(BinValType.Node))
			bin_node_header(be, .JSXClosingElement, ce.loc)
			bin_emit_jsx_elem_name(be, ce.name)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
	case ^JSXFragment:
		bin_node_header(be, .JSXFragment, e.loc)
		bin_node_header(be, .JSXOpeningFragment, e.opening_fragment.loc)
		bw_u32(be, u32(len(e.children)))
		for child in e.children { bin_emit_jsx_child(be, child) }
		bin_node_header(be, .JSXClosingFragment, e.closing_fragment.loc)
	case ^JSXText:
		bin_node_header(be, .JSXText, e.loc)
		bw_string_ref(be, e.value)
		bw_string_ref(be, e.raw)
	case ^JSXExpressionContainer:
		bin_node_header(be, .JSXExpressionContainer, e.loc)
		bin_emit_expression(be, e.expression)
	case ^JSXEmptyExpression:
		bin_node_header(be, .JSXEmptyExpression, e.loc)
	case ^JSXSpreadChild:
		bin_node_header(be, .JSXSpreadChild, e.loc)
		bin_emit_expression(be, e.expression)
	// ===================== TypeScript =====================
	case ^TSAsExpression:
		bin_record(be, "TSAsExpression", e.loc)
		bin_field_expr(be, "expression", e.expression)
		bin_field_type(be, "typeAnnotation", e.type_annotation)
		bin_fields_end(be)
	case ^TSSatisfiesExpression:
		bin_record(be, "TSSatisfiesExpression", e.loc)
		bin_field_expr(be, "expression", e.expression)
		bin_field_type(be, "typeAnnotation", e.type_annotation)
		bin_fields_end(be)
	case ^TSNonNullExpression:
		bin_node_header(be, .TSNonNullExpression, e.loc)
		bin_emit_expression(be, e.expression)
	case ^TSTypeAssertion:
		bin_record(be, "TSTypeAssertion", e.loc)
		bin_field_expr(be, "expression", e.expression)
		bin_field_type(be, "typeAnnotation", e.type_annotation)
		bin_fields_end(be)
	case ^TSInstantiationExpression:
		bin_record(be, "TSInstantiationExpression", e.loc)
		bin_field_expr(be, "expression", e.expression)
		bin_field_type_args(be, e.type_arguments)
		bin_fields_end(be)
	}
}

bin_template_element :: proc(be: ^BinaryEmitter, q: TemplateElement) {
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

bin_emit_pattern :: proc(be: ^BinaryEmitter, pat: Pattern, param: ^TSFunctionParam = nil) {
	#partial switch p in pat {
	case ^Identifier:
		loc, annotation, optional := ts_param_binding_fields(p.loc, p.type_annotation, p.optional, param)
		if annotation != nil || optional {
			bin_type_identifier(be, loc, p.name, annotation, optional)
			return
		}
		bin_node_header(be, .Identifier, loc)
		bw_string_ref(be, p.name)
	case ^ObjectPattern:
		loc, annotation, optional := ts_param_binding_fields(p.loc, p.type_annotation, false, param)
		bin_pattern_typing(be, annotation, optional)
		bin_node_header(be, .ObjectPattern, loc)
		bw_u32(be, u32(len(p.properties)))
		for prop in p.properties {
			bin_emit_obj_pat_prop(be, prop)
		}
	case ^ArrayPattern:
		loc, annotation, optional := ts_param_binding_fields(p.loc, p.type_annotation, false, param)
		bin_pattern_typing(be, annotation, optional)
		bin_node_header(be, .ArrayPattern, loc)
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
		bin_emit_pattern(be, p.left, param)
		bin_emit_expression(be, p.right)
	case ^RestElement:
		if param != nil {
			bin_type_rest(be, p, param.type_annotation, param.loc)
			return
		}
		if id, plain := p.argument.(^Identifier); plain && id.type_annotation != nil {
			bin_type_rest(be, p, id.type_annotation, p.loc)
			return
		}
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

bin_pattern_typing :: proc(be: ^BinaryEmitter, annotation: Maybe(^TSTypeAnnotation), optional: bool) {
	if annotation == nil && !optional { return }
	bin_extra(be)
	if annotation != nil { bin_field_annotation(be, "typeAnnotation", annotation) }
	if optional { bin_field_bool(be, "optional", true) }
	bin_fields_end(be)
}

// ============================================================================
// JSX binary emission helpers
// ============================================================================

bin_emit_jsx_elem_name :: proc(be: ^BinaryEmitter, name: JSXElementName) {
	switch n in name {
	case JSXIdentifier:
		bin_node_header(be, .JSXIdentifier, n.loc)
		bw_string_ref(be, n.name)
	case ^JSXMemberExpression:
		bin_node_header(be, .JSXMemberExpression, n.loc)
		bin_emit_jsx_member_object(be, n.object)
		bin_node_header(be, .JSXIdentifier, n.property.loc)
		bw_string_ref(be, n.property.name)
	case ^JSXNamespacedName:
		bin_node_header(be, .JSXNamespacedName, n.loc)
		bin_node_header(be, .JSXIdentifier, n.namespace.loc)
		bw_string_ref(be, n.namespace.name)
		bin_node_header(be, .JSXIdentifier, n.name.loc)
		bw_string_ref(be, n.name.name)
	}
}

bin_emit_jsx_member_object :: proc(be: ^BinaryEmitter, obj: JSXMemberObject) {
	switch o in obj {
	case JSXIdentifier:
		bin_node_header(be, .JSXIdentifier, o.loc)
		bw_string_ref(be, o.name)
	case ^JSXMemberExpression:
		bin_node_header(be, .JSXMemberExpression, o.loc)
		bin_emit_jsx_member_object(be, o.object)
		bin_node_header(be, .JSXIdentifier, o.property.loc)
		bw_string_ref(be, o.property.name)
	}
}

bin_emit_jsx_attr_name :: proc(be: ^BinaryEmitter, name: JSXAttributeName) {
	switch n in name {
	case JSXIdentifier:
		bin_node_header(be, .JSXIdentifier, n.loc)
		bw_string_ref(be, n.name)
	case ^JSXNamespacedName:
		bin_node_header(be, .JSXNamespacedName, n.loc)
		bin_node_header(be, .JSXIdentifier, n.namespace.loc)
		bw_string_ref(be, n.namespace.name)
		bin_node_header(be, .JSXIdentifier, n.name.loc)
		bw_string_ref(be, n.name.name)
	}
}

bin_emit_jsx_opening :: proc(be: ^BinaryEmitter, oe: ^JSXOpeningElement) {
	if oe.type_arguments != nil {
		bin_extra(be)
		bin_field_type_args(be, oe.type_arguments)
		bin_fields_end(be)
	}
	bin_node_header(be, .JSXOpeningElement, oe.loc)
	bw_bool(be, oe.self_closing)
	bin_emit_jsx_elem_name(be, oe.name)
	bw_u32(be, u32(len(oe.attributes)))
	for attr in oe.attributes {
		switch a in attr {
		case JSXAttribute:
			bin_node_header(be, .JSXAttribute, a.loc)
			bin_emit_jsx_attr_name(be, a.name)
			if val, ok := a.value.?; ok && val != nil {
				bw_u8(be, u8(BinValType.Node))
				bin_emit_expression(be, val)
			} else {
				bw_u8(be, u8(BinValType.NullNode))
			}
		case ^JSXSpreadAttribute:
			bin_node_header(be, .JSXSpreadAttribute, a.loc)
			bin_emit_expression(be, a.argument)
		}
	}
}

bin_emit_jsx_child :: proc(be: ^BinaryEmitter, child: JSXChild) {
	switch c in child {
	case ^JSXElement:
		if c != nil {
			// Re-use expression path — JSXElement is an Expression variant.
			bin_node_header(be, .JSXElement, c.loc)
			bin_emit_jsx_opening(be, c.opening_element)
			bw_u32(be, u32(len(c.children)))
			for gc in c.children { bin_emit_jsx_child(be, gc) }
			if ce, ok := c.closing_element.?; ok && ce != nil {
				bw_u8(be, u8(BinValType.Node))
				bin_node_header(be, .JSXClosingElement, ce.loc)
				bin_emit_jsx_elem_name(be, ce.name)
			} else {
				bw_u8(be, u8(BinValType.NullNode))
			}
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
	case ^JSXFragment:
		if c != nil {
			bin_node_header(be, .JSXFragment, c.loc)
			bin_node_header(be, .JSXOpeningFragment, c.opening_fragment.loc)
			bw_u32(be, u32(len(c.children)))
			for gc in c.children { bin_emit_jsx_child(be, gc) }
			bin_node_header(be, .JSXClosingFragment, c.closing_fragment.loc)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
	case ^JSXText:
		if c != nil {
			bin_node_header(be, .JSXText, c.loc)
			bw_string_ref(be, c.value)
			bw_string_ref(be, c.raw)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
	case ^JSXExpressionContainer:
		if c != nil {
			bin_node_header(be, .JSXExpressionContainer, c.loc)
			bin_emit_expression(be, c.expression)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
	case ^JSXSpreadChild:
		if c != nil {
			bin_node_header(be, .JSXSpreadChild, c.loc)
			bin_emit_expression(be, c.expression)
		} else {
			bw_u8(be, u8(BinValType.NullNode))
		}
	}
}

bin_emit_property :: proc(be: ^BinaryEmitter, prop: Property) {
	// SpreadElement path: parser stores spread as Property { key: nil, value: ^SpreadElement }.
	// Emit as a bare SpreadElement node, matching the JSON emitter.
	if prop.key == nil && prop.value != nil {
		if se, ok := prop.value^.(^SpreadElement); ok {
			bin_node_header(be, .SpreadElement, se.loc)
			bin_emit_expression(be, se.argument)
			return
		}
	}
	bin_node_header(be, .Property, prop.loc)
	// ESTree: Method maps to kind="init" + method=true.
	is_method := prop.kind == .Method
	kind_byte: u8 = 0 // "init"
	switch prop.kind {
	case .Init:   kind_byte = 0
	case .Get:    kind_byte = 1
	case .Set:    kind_byte = 2
	case .Method: kind_byte = 0 // ESTree: method stays kind "init"
	}
	bw_u8(be, kind_byte)
	bw_bool(be, prop.computed)
	bw_bool(be, prop.shorthand)
	bw_bool(be, is_method) // method flag
	// key (tagged with VT_Node / VT_NullNode)
	if prop.key != nil && !expression_inner_nil(prop.key) {
		bw_u8(be, u8(BinValType.Node))
		bin_emit_expression(be, prop.key)
	} else {
		bw_u8(be, u8(BinValType.NullNode))
	}
	bin_emit_expression(be, prop.value)
}

bin_emit_obj_pat_prop :: proc(be: ^BinaryEmitter, prop: ObjectPatternProperty) {
	bin_node_header(be, .Property, prop.loc)
	bw_u8(be, 0) // kind: always 'init' for pattern properties
	bw_bool(be, prop.computed)
	bw_bool(be, prop.shorthand)
	bw_bool(be, false) // method: always false for patterns
	// key (nullable — tagged with VT_Node / VT_NullNode)
	if key, ok := prop.key.?; ok {
		bw_u8(be, u8(BinValType.Node))
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

bin_emit_declaration :: proc(be: ^BinaryEmitter, decl: ^Declaration) {
	if decl == nil { bw_u8(be, u8(BinValType.NullNode)); return }
	statement := decl_to_stmt(decl^)
	bin_emit_statement(be, &statement)
}

bin_emit_export_default_def :: proc(be: ^BinaryEmitter, def: ^ExportDefaultDef) {
	if def == nil { bw_u8(be, u8(BinValType.NullNode)); return }
	switch d in def^ {
	case ^Declaration:
		bin_emit_declaration(be, d)
	case ^Expression:
		bin_emit_expression(be, d)
	}
}

bin_emit_var_decl :: proc(be: ^BinaryEmitter, s: ^VariableDeclaration) {
	if s.declare {
		bin_extra(be)
		bin_field_bool(be, "declare", true)
		bin_fields_end(be)
	}
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

bin_emit_export_spec_name :: proc(be: ^BinaryEmitter, name: ExportSpecifierName) {
	switch n in name {
	case IdentifierName:
		bin_emit_identifier_child(be, n.loc, n.name)
	case ^StringLiteral:
		if n != nil {
			bin_emit_string_child(be, n.loc, n.value, n.raw)
		} else {
			be.version = max(be.version, BINARY_VERSION_CHILD_SPANS)
			bw_u8(be, u8(BinValType.NullNode))
		}
	}
}

bin_emit_identifier_child :: proc(be: ^BinaryEmitter, loc: Loc, name: string) {
	be.version = max(be.version, BINARY_VERSION_CHILD_SPANS)
	bin_node_header(be, .Identifier, loc)
	bw_string_ref(be, name)
}

bin_emit_string_child :: proc(be: ^BinaryEmitter, loc: Loc, value, raw: string) {
	be.version = max(be.version, BINARY_VERSION_CHILD_SPANS)
	bin_node_header(be, .StringLiteral, loc)
	bw_string_ref(be, value)
	bw_string_ref(be, raw)
}

bin_emit_optional_identifier :: proc(be: ^BinaryEmitter, child: Maybe($T)) {
	if id, present := child.?; present {
		bw_u8(be, u8(BinValType.Node))
		bin_emit_identifier_child(be, id.loc, id.name)
	} else {
		bw_u8(be, u8(BinValType.Null))
	}
}

// Import names and namespace export aliases retain their decoded name and
// original source span for both identifier and quoted spellings.
bin_emit_module_name_child :: proc(be: ^BinaryEmitter, name: IdentifierName) {
	loc := name.loc
	if loc.start < loc.end && loc.end <= u32(len(be.source)) {
		raw := be.source[loc.start:loc.end]
		if raw[0] == '\'' || raw[0] == '"' {
			bin_emit_string_child(be, loc, name.name, raw)
			return
		}
	}
	bin_emit_identifier_child(be, loc, name.name)
}

// ============================================================================
// Shared helpers for function / class emission
// ============================================================================

bin_emit_block :: proc(be: ^BinaryEmitter, block: BlockStatement) {
	bin_node_header(be, .BlockStatement, block.loc)
	bw_u32(be, u32(len(block.body)))
	for child in block.body { bin_emit_statement(be, child) }
}

bin_emit_function_body :: proc(be: ^BinaryEmitter, body: FunctionBody) {
	bin_node_header(be, .BlockStatement, body.loc)
	bw_u32(be, u32(len(body.body)))
	for child in body.body { bin_emit_statement(be, child) }
}

bin_emit_function_node :: proc(be: ^BinaryEmitter, type_id: BinNodeType, fn: ^FunctionExpression) {
	if fn.no_body || fn.declare || fn.type_parameters != nil || fn.return_type != nil {
		name := "FunctionDeclaration" if type_id == .FunctionDeclaration else "FunctionExpression"
		if fn.no_body { name = "TSDeclareFunction" if type_id == .FunctionDeclaration else "TSEmptyBodyFunctionExpression" }
		bin_type_function(be, name, fn)
		return
	}
	bin_node_header(be, type_id, fn.loc)
	bin_emit_optional_identifier(be, fn.id)
	bw_bool(be, fn.async)
	bw_bool(be, fn.generator)
	bw_u32(be, u32(len(fn.params)))
	for param in fn.params { bin_emit_param(be, param) }
	bin_emit_function_body(be, fn.body)
}

bin_emit_param :: proc(be: ^BinaryEmitter, param: FunctionParameter) {
	if param.readonly || param.override_ || param.accessibility != .None || (param.pattern == nil && param.default_val != nil) {
		bin_type_function_param(be, param)
		bw_u8(be, u8(BinValType.NullNode))
		return
	}
	bin_emit_pattern(be, param.pattern)
	if def, ok := param.default_val.(^Expression); ok && def != nil {
		bw_u8(be, u8(BinValType.Node))
		bin_emit_expression(be, def)
	} else {
		bw_u8(be, u8(BinValType.NullNode))
	}
}

bin_emit_class :: proc(be: ^BinaryEmitter, type_id: BinNodeType, class: ^$T) {
	bin_type_class_fields(be, class)
	bin_node_header(be, type_id, class.loc)
	bin_emit_optional_identifier(be, class.id)
	if sc, ok := class.super_class.?; ok && sc != nil {
		bw_u8(be, u8(BinValType.Node))
		bin_emit_expression(be, sc)
	} else {
		bw_u8(be, u8(BinValType.NullNode))
	}
	bin_node_header(be, .ClassBody, class.body.loc)
	bw_u32(be, u32(len(class.body.body)))
	for elem in class.body.body {
		bin_emit_class_element(be, elem)
	}
}

bin_emit_class_element :: proc(be: ^BinaryEmitter, elem: ClassElement) {
	if elem.kind == .IndexSignature {
		bin_emit_signature(be, elem.typing.index_signature)
		return
	}
	if elem.typing.annotation != nil || elem.abstract || elem.optional || elem.definite || elem.readonly || elem.override_ ||
	   elem.accessibility != .None || elem.is_accessor || len(elem.decorators) != 0 {
		bin_type_class_element(be, elem)
		return
	}
	switch elem.kind {
	case .IndexSignature: unreachable()
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
	case .Field:
		bin_node_header(be, .PropertyDefinition, elem.loc)
		bw_bool(be, elem.computed)
		flags := u8(elem.static)
		if elem.declare {
			flags |= 2
			be.version = max(be.version, BINARY_VERSION_DECLARED_FIELDS)
		}
		bw_u8(be, flags)
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

// Append the errors section to the buffer. Must be called after
// bin_emit_program and before bin_emit_finalize so the section lands
// between the node stream and the string table.
//
// Layout per error (v4):
//   u32 start         — byte offset, inclusive
//   u32 end           — byte offset, exclusive (== start for point reports)
//   u16 code          — ErrorCode numeric value (0 = .None / legacy)
//   u8  severity      — Severity numeric value (0 = .Error, 1 = .Warning)
//   u8  _pad          — reserved, must be 0
//   u32 msg_len       — UTF-8 byte length
//   u8  msg[msg_len]  — UTF-8 message, no NUL terminator
//
// Total fixed prefix: 16 bytes per error; followed by the variable
// message bytes. No alignment padding between consecutive entries.
//
// Format-version history:
//   v3 → v4: added {code:u16, severity:u8, _pad:u8} after `end`. The
//   JS decoder (npm/kessel/binary-reader.js) hard-checks the version
//   header and decodes the new fields. Bump in lockstep — mismatched
//   versions throw at decode time, not at parse time.
bin_emit_errors :: proc(be: ^BinaryEmitter, errors: []ParseError) {
	be.errors_off = u32(be.pos)
	be.error_count = u32(len(errors))
	for err in errors {
		bw_u32(be, err.start)
		bw_u32(be, err.end)
		bw_u16(be, u16(err.code))
		bw_u8(be, u8(err.severity))
		bw_u8(be, 0)  // _pad
		msg_bytes := transmute([]u8)err.message
		bw_u32(be, u32(len(msg_bytes)))
		be_ensure(be, len(msg_bytes))
		copy(be.buf[be.pos:], msg_bytes)
		be.pos += len(msg_bytes)
	}
}

bin_emit_finalize :: proc(be: ^BinaryEmitter) {
	if be.version >= BINARY_VERSION_TYPES {
		// Keeping the mode next to the table preserves every node and diagnostic offset.
		bw_bool(be, be.ts_shape)
		// Keep a later version (v9 hashbang) that already implies this byte.
		be.version = max(be.version, BINARY_VERSION_SOURCE_SHAPE)
	}
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

	// Write 24-byte header at offset 0.
	// Layout (all little-endian u32):
	//   0  magic            0x4B455354 ('KEST')
	//   4  version          minimum compatible decoder version
	//   8  node_count
	//  12  string_table_off
	//  16  errors_off       (0 if bin_emit_errors was never called)
	//  20  error_count
	write_u32 :: #force_inline proc(buf: []u8, off: int, v: u32) {
		buf[off + 0] = u8(v)
		buf[off + 1] = u8(v >> 8)
		buf[off + 2] = u8(v >> 16)
		buf[off + 3] = u8(v >> 24)
	}
	write_u32(be.buf[:], 0,  u32(0x4B455354))     // magic 'KEST'
	write_u32(be.buf[:], 4,  be.version)
	write_u32(be.buf[:], 8,  be.node_count)
	write_u32(be.buf[:], 12, string_table_off)
	write_u32(be.buf[:], 16, be.errors_off)
	write_u32(be.buf[:], 20, be.error_count)
}
