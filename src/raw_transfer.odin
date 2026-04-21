package main

// ============================================================================
// Raw Transfer — zero-copy AST buffer for cross-language consumption
//
// After parsing, the AST lives in a contiguous arena (bump pool + dynamic
// arrays). This module rewrites all native pointers to u32 offsets relative
// to the arena base, producing a flat byte buffer that any language can read
// with a DataView — zero serialization, zero JS object creation.
//
// Memory layout of the buffer:
//   [bump pool (AST nodes)] [dynamic array data] [... unused ...]
//
// Pointer encoding: ptr → u32 offset from base (0 = nil)
// String encoding:  string{ptr,len} → {u32 offset_in_source, u32 len}
// Dynamic array:    [dynamic]T{ptr,len,cap,alloc} → {u32 data_offset, u32 len}
// Union (^T):       {u64 ptr, u8 tag, pad} → {u32 offset, u8 tag, pad}
// Maybe(^T):        ptr (nil=0) → u32 offset (0=nil)
// ============================================================================

import "core:mem"
import "core:os"
import mvirtual "core:mem/virtual"

// Metadata written at the end of the buffer so the consumer knows where to start
RawTransferHeader :: struct {
	magic:           u32,  // 0x4B455353 ("KESS")
	version:         u32,  // 1
	program_offset:  u32,  // offset of Program node from base
	source_len:      u32,  // length of original source text
	total_bytes:     u32,  // total used bytes in buffer (excluding header)
}

RAW_TRANSFER_MAGIC :: u32(0x4B455353)
RAW_TRANSFER_VERSION :: u32(1)

// Convert a native pointer to a u32 offset relative to base.
// Returns 0 for nil pointers.
ptr_to_offset :: #force_inline proc(base: uintptr, ptr: rawptr) -> u32 {
	if ptr == nil { return 0 }
	return u32(uintptr(ptr) - base)
}

// Rewrite all pointer fields in the AST to offsets relative to arena base.
// After this call, the arena memory is a self-contained buffer.
rewrite_ast_pointers :: proc(program: ^Program, base: uintptr, source: string) {
	source_base := uintptr(raw_data(source))
	rewrite_program(program, base, source_base)
}

// ============================================================================
// Per-node rewriters
// ============================================================================

// Helper: rewrite a raw pointer field in-place
rewrite_ptr :: #force_inline proc(field: ^rawptr, base: uintptr) {
	if field^ != nil {
		offset := u32(uintptr(field^) - base)
		(^u32)(field)^ = offset
	}
}

// Helper: rewrite a string field in-place to (source_offset, len)
// String in Odin = {ptr: rawptr, len: int} = 16 bytes
// We rewrite to {offset: u32, len: u32} in the first 8 bytes
rewrite_string :: #force_inline proc(field: ^string, source_base: uintptr) {
	s := field^
	if len(s) == 0 {
		(^[2]u32)(field)^ = {0, 0}
		return
	}
	offset := u32(uintptr(raw_data(s)) - source_base)
	length := u32(len(s))
	(^[2]u32)(field)^ = {offset, length}
}

// Helper: rewrite a Maybe(string) — same layout as string, nil = empty
rewrite_maybe_string :: #force_inline proc(field: ^Maybe(string), source_base: uintptr) {
	if s, ok := field^.(string); ok {
		str_field := (^string)(field)
		rewrite_string(str_field, source_base)
	} else {
		(^[2]u32)(field)^ = {0, 0}
	}
}

// Helper: rewrite [dynamic]T — layout is {data: rawptr, len: int, cap: int, alloc: Allocator}
// We rewrite to {data_offset: u32, len: u32} in the first 8 bytes
rewrite_dynamic_header :: #force_inline proc(field: rawptr, base: uintptr, len_val: int) {
	// [dynamic]T layout: {data: rawptr(8), len: int(8), cap: int(8), alloc: Allocator(16)} = 40 bytes
	// We rewrite to:     {data_offset: u32(4), len: u32(4)} in the first 8 bytes
	// The remaining 32 bytes become dead but stay in the buffer.
	data_ptr := (^rawptr)(field)^
	offset := ptr_to_offset(base, data_ptr)
	(^u32)(field)^ = offset
	(^u32)(rawptr(uintptr(field) + 4))^ = u32(len_val)
}

// Helper: rewrite a union (Expression/Statement) in-place
// Union layout: {ptr: 8 bytes, tag: 1 byte, pad: 7 bytes}
// Rewrite to: {offset: u32, _pad: 4 bytes, tag: 1 byte, pad: 7 bytes}
rewrite_union_ptr :: #force_inline proc(field: rawptr, base: uintptr) {
	ptr := (^rawptr)(field)^
	if ptr != nil {
		offset := u32(uintptr(ptr) - base)
		(^u32)(field)^ = offset
	}
}

// Helper: fully rewrite an Expression field — recurse + union ptr + field ptr
rewrite_expr_field :: #force_inline proc(expr: ^Expression, field_addr: rawptr, base: uintptr, source_base: uintptr) {
	if expr == nil { return }
	rewrite_expression(expr, base, source_base)  // recurse into contents
	rewrite_union_ptr(expr, base)                // rewrite union's inner ptr
	rewrite_ptr((^rawptr)(field_addr), base)     // rewrite the field itself
}

// Helper: fully rewrite a Statement field — recurse + union ptr + field ptr  
rewrite_stmt_field :: #force_inline proc(stmt: ^Statement, field_addr: rawptr, base: uintptr, source_base: uintptr) {
	if stmt == nil { return }
	rewrite_statement(stmt, base, source_base)
	rewrite_union_ptr(stmt, base)
	rewrite_ptr((^rawptr)(field_addr), base)
}

// Helper: rewrite a Maybe(^Expression) field
rewrite_maybe_expr :: #force_inline proc(field: ^Maybe(^Expression), base: uintptr, source_base: uintptr) {
	if expr, ok := field.?; ok {
		rewrite_expression(expr, base, source_base)
		rewrite_union_ptr(expr, base)
		rewrite_ptr((^rawptr)(field), base)
	}
}

// Helper: rewrite a Maybe(^Statement) field
rewrite_maybe_stmt :: #force_inline proc(field: ^Maybe(^Statement), base: uintptr, source_base: uintptr) {
	if stmt, ok := field.?; ok {
		rewrite_statement(stmt, base, source_base)
		rewrite_union_ptr(stmt, base)
		rewrite_ptr((^rawptr)(field), base)
	}
}

// ============================================================================
// Expression rewriter
// ============================================================================

rewrite_expression :: proc(expr: ^Expression, base: uintptr, source_base: uintptr) {
	if expr == nil { return }
	
	// First rewrite the union pointer itself is not needed — the parent does that.
	// We need to rewrite the INNER fields of whichever variant it holds.
	
	#partial switch v in expr {
	case ^Identifier:
		rewrite_string(&v.name, source_base)
	case ^PrivateIdentifier:
		rewrite_string(&v.name, source_base)
	case ^NullLiteral:
		// no pointer fields
	case ^BooleanLiteral:
		// no pointer fields
	case ^NumericLiteral:
		rewrite_string(&v.raw, source_base)
	case ^StringLiteral:
		rewrite_string(&v.value, source_base)
		rewrite_string(&v.raw, source_base)
	case ^BigIntLiteral:
		rewrite_string(&v.value, source_base)
		rewrite_string(&v.raw, source_base)
	case ^RegExpLiteral:
		rewrite_string(&v.pattern, source_base)
		rewrite_string(&v.flags, source_base)
	case ^TemplateLiteral:
		rewrite_template_literal(v, base, source_base)
	case ^TaggedTemplateExpression:
		rewrite_expr_field(v.tag, &v.tag, base, source_base)  // the ^Expression itself
		rewrite_expr_field(v.quasi, &v.quasi, base, source_base)
	case ^ThisExpression:
		// no pointer fields
	case ^Super:
		// no pointer fields
	case ^SpreadElement:
		rewrite_expr_field(v.argument, &v.argument, base, source_base)
	case ^ArrayExpression:
		rewrite_array_expression(v, base, source_base)
	case ^ObjectExpression:
		rewrite_object_expression(v, base, source_base)
	case ^FunctionExpression:
		rewrite_function_expression(v, base, source_base)
	case ^ArrowFunctionExpression:
		rewrite_arrow_function(v, base, source_base)
	case ^ClassExpression:
		rewrite_class_expression(v, base, source_base)
	case ^MemberExpression:
		rewrite_expr_field(v.object, &v.object, base, source_base)
		rewrite_expr_field(v.property, &v.property, base, source_base)
	case ^CallExpression:
		rewrite_expr_field(v.callee, &v.callee, base, source_base)
		rewrite_expression_array(&v.arguments, base, source_base)
	case ^NewExpression:
		rewrite_expr_field(v.callee, &v.callee, base, source_base)
		rewrite_expression_array(&v.arguments, base, source_base)
	case ^ConditionalExpression:
		rewrite_expr_field(v.test, &v.test, base, source_base)
		rewrite_expr_field(v.consequent, &v.consequent, base, source_base)
		rewrite_expr_field(v.alternate, &v.alternate, base, source_base)
	case ^UpdateExpression:
		rewrite_expr_field(v.argument, &v.argument, base, source_base)
	case ^UnaryExpression:
		rewrite_expr_field(v.argument, &v.argument, base, source_base)
	case ^BinaryExpression:
		rewrite_expr_field(v.left, &v.left, base, source_base)
		rewrite_expr_field(v.right, &v.right, base, source_base)
	case ^LogicalExpression:
		rewrite_expr_field(v.left, &v.left, base, source_base)
		rewrite_expr_field(v.right, &v.right, base, source_base)
	case ^AssignmentExpression:
		rewrite_expr_field(v.left, &v.left, base, source_base)
		rewrite_expr_field(v.right, &v.right, base, source_base)
	case ^SequenceExpression:
		rewrite_expression_array(&v.expressions, base, source_base)
	case ^YieldExpression:
		if arg, ok := v.argument.?; ok {
			rewrite_expression(arg, base, source_base)
			rewrite_union_ptr(arg, base)
		}
	case ^AwaitExpression:
		rewrite_expr_field(v.argument, &v.argument, base, source_base)
	case ^ImportExpression:
		rewrite_expr_field(v.source, &v.source, base, source_base)
	case ^MetaProperty:
		rewrite_string(&v.meta.name, source_base)
		rewrite_string(&v.property.name, source_base)
	case:
		// Unknown expression type — skip
	}
}

// ============================================================================
// Statement rewriter
// ============================================================================

rewrite_statement :: proc(stmt: ^Statement, base: uintptr, source_base: uintptr) {
	if stmt == nil { return }
	
	#partial switch v in stmt {
	case ^ExpressionStatement:
		rewrite_expr_field(v.expression, &v.expression, base, source_base)
	case ^BlockStatement:
		rewrite_statement_array(&v.body, base, source_base)
	case ^EmptyStatement:
		// nothing
	case ^DebuggerStatement:
		// nothing
	case ^ReturnStatement:
		if arg, ok := v.argument.?; ok {
			rewrite_expression(arg, base, source_base)
			rewrite_union_ptr(arg, base)
		}
	case ^BreakStatement:
		if label, ok := v.label.(LabelIdentifier); ok {
			rewrite_string(&label.name, source_base)
		}
	case ^ContinueStatement:
		if label, ok := v.label.(LabelIdentifier); ok {
			rewrite_string(&label.name, source_base)
		}
	case ^LabeledStatement:
		rewrite_string(&v.label.name, source_base)
		rewrite_statement(v.body, base, source_base)
		rewrite_ptr((^rawptr)(&v.body), base)
	case ^IfStatement:
		rewrite_expr_field(v.test, &v.test, base, source_base)
		rewrite_statement(v.consequent, base, source_base)
		rewrite_ptr((^rawptr)(&v.consequent), base)
		if alt, ok := v.alternate.?; ok {
			rewrite_statement(alt, base, source_base)
			rewrite_ptr((^rawptr)(&v.alternate), base)
		}
	case ^SwitchStatement:
		rewrite_expr_field(v.discriminant, &v.discriminant, base, source_base)
		for i in 0..<len(v.cases) {
			c := &v.cases[i]
			if test, ok := c.test.?; ok {
				rewrite_expression(test, base, source_base)
				rewrite_union_ptr(test, base)
			}
			rewrite_statement_array(&c.consequent, base, source_base)
		}
		rewrite_dynamic_header(&v.cases, base, len(v.cases))
	case ^WhileStatement:
		rewrite_expr_field(v.test, &v.test, base, source_base)
		rewrite_statement(v.body, base, source_base)
		rewrite_ptr((^rawptr)(&v.body), base)
	case ^DoWhileStatement:
		rewrite_statement(v.body, base, source_base)
		rewrite_ptr((^rawptr)(&v.body), base)
		rewrite_expr_field(v.test, &v.test, base, source_base)
	case ^ForStatement:
		// init_decl/init_expr are transmuted ^Statement pointers (parser quirk)
		// Treat as ^Statement for rewriting
		if init_ptr := (^rawptr)(&v.init_decl)^; init_ptr != nil {
			rewrite_statement(transmute(^Statement)init_ptr, base, source_base)
			(^u32)(&v.init_decl)^ = ptr_to_offset(base, init_ptr)
		}
		if init_ptr := (^rawptr)(&v.init_expr)^; init_ptr != nil {
			rewrite_expression(transmute(^Expression)init_ptr, base, source_base)
			rewrite_union_ptr(transmute(^Expression)init_ptr, base)
			(^u32)(&v.init_expr)^ = ptr_to_offset(base, init_ptr)
		}
		if test, ok := v.test.?; ok {
			rewrite_expression(test, base, source_base)
			rewrite_union_ptr(test, base)
		}
		if upd, ok := v.update.?; ok {
			rewrite_expression(upd, base, source_base)
			rewrite_union_ptr(upd, base)
		}
		rewrite_statement(v.body, base, source_base)
		rewrite_ptr((^rawptr)(&v.body), base)
	case ^ForInStatement:
		if ptr := (^rawptr)(&v.left_decl)^; ptr != nil {
			rewrite_statement(transmute(^Statement)ptr, base, source_base)
			(^u32)(&v.left_decl)^ = ptr_to_offset(base, ptr)
		}
		if ptr := (^rawptr)(&v.left_expr)^; ptr != nil {
			rewrite_expression(transmute(^Expression)ptr, base, source_base)
			rewrite_union_ptr(transmute(^Expression)ptr, base)
			(^u32)(&v.left_expr)^ = ptr_to_offset(base, ptr)
		}
		rewrite_expr_field(v.right, &v.right, base, source_base)
		rewrite_statement(v.body, base, source_base)
		rewrite_ptr((^rawptr)(&v.body), base)
	case ^ForOfStatement:
		if ptr := (^rawptr)(&v.left_decl)^; ptr != nil {
			rewrite_statement(transmute(^Statement)ptr, base, source_base)
			(^u32)(&v.left_decl)^ = ptr_to_offset(base, ptr)
		}
		if ptr := (^rawptr)(&v.left_expr)^; ptr != nil {
			rewrite_expression(transmute(^Expression)ptr, base, source_base)
			rewrite_union_ptr(transmute(^Expression)ptr, base)
			(^u32)(&v.left_expr)^ = ptr_to_offset(base, ptr)
		}
		rewrite_expr_field(v.right, &v.right, base, source_base)
		rewrite_statement(v.body, base, source_base)
		rewrite_ptr((^rawptr)(&v.body), base)
	case ^WithStatement:
		rewrite_expr_field(v.object, &v.object, base, source_base)
		rewrite_statement(v.body, base, source_base)
		rewrite_ptr((^rawptr)(&v.body), base)
	case ^ThrowStatement:
		rewrite_expr_field(v.argument, &v.argument, base, source_base)
	case ^TryStatement:
		rewrite_statement_array(&v.block.body, base, source_base)
		if handler, ok := v.handler.(CatchClause); ok {
			rewrite_statement_array(&handler.body.body, base, source_base)
		}
		if finalizer, ok := v.finalizer.(BlockStatement); ok {
			rewrite_statement_array(&finalizer.body, base, source_base)
		}
	case ^VariableDeclaration:
		rewrite_variable_declaration(v, base, source_base)
	case ^FunctionDeclaration:
		rewrite_function_expression(&v.expr, base, source_base)
	case ^ClassDeclaration:
		rewrite_class_expression(&v.expr, base, source_base)
	case ^ImportDeclaration:
		rewrite_import_declaration(v, base, source_base)
	case ^ExportNamedDeclaration:
		rewrite_export_named(v, base, source_base)
	case ^ExportDefaultDeclaration:
		rewrite_ptr((^rawptr)(&v.declaration), base)
	case ^ExportAllDeclaration:
		// string fields in source
	case:
		// Unknown statement type
	}
}

// ============================================================================
// Array rewriters
// ============================================================================

rewrite_expression_array :: proc(arr: ^[dynamic]^Expression, base: uintptr, source_base: uintptr) {
	for i in 0..<len(arr) {
		rewrite_expression(arr[i], base, source_base)
		// Rewrite the pointer in the array slot itself
		rewrite_union_ptr(arr[i], base)
		// Rewrite the array slot (^Expression → offset)
		slot := &(raw_data(arr^))[i]
		rewrite_ptr((^rawptr)(slot), base)
	}
	rewrite_dynamic_header(arr, base, len(arr))
}

rewrite_statement_array :: proc(arr: ^[dynamic]^Statement, base: uintptr, source_base: uintptr) {
	for i in 0..<len(arr) {
		rewrite_statement(arr[i], base, source_base)
		rewrite_union_ptr(arr[i], base)
		slot := &(raw_data(arr^))[i]
		rewrite_ptr((^rawptr)(slot), base)
	}
	rewrite_dynamic_header(arr, base, len(arr))
}

// ============================================================================
// Compound rewriters
// ============================================================================

rewrite_program :: proc(p: ^Program, base: uintptr, source_base: uintptr) {
	// Rewrite directives
	dir_len := len(p.directives)
	for i in 0..<dir_len {
		rewrite_string(&p.directives[i].value.value, source_base)
		rewrite_string(&p.directives[i].value.raw, source_base)
		rewrite_string(&p.directives[i].raw, source_base)
	}
	rewrite_dynamic_header(rawptr(&p.directives), base, dir_len)

	// Rewrite body
	rewrite_statement_array(&p.body, base, source_base)
}

rewrite_template_literal :: proc(t: ^TemplateLiteral, base: uintptr, source_base: uintptr) {
	for i in 0..<len(t.quasis) {
		q := &t.quasis[i]
		rewrite_maybe_string(&q.cooked, source_base)
		rewrite_string(&q.raw, source_base)
	}
	rewrite_dynamic_header(&t.quasis, base, len(t.quasis))
	rewrite_expression_array(&t.expressions, base, source_base)
}

rewrite_variable_declaration :: proc(v: ^VariableDeclaration, base: uintptr, source_base: uintptr) {
	for i in 0..<len(v.declarations) {
		d := &v.declarations[i]
		rewrite_binding_pattern(&d.id, base, source_base)
		if init_expr, has_init := d.init.?; has_init {
			rewrite_expression(init_expr, base, source_base)
			rewrite_union_ptr(init_expr, base)
			// Rewrite the Maybe(^Expression) slot itself
			rewrite_ptr((^rawptr)(&d.init), base)
		}
	}
	rewrite_dynamic_header(&v.declarations, base, len(v.declarations))
}

rewrite_binding_pattern :: proc(pat: ^Pattern, base: uintptr, source_base: uintptr) {
	if pat == nil { return }
	#partial switch v in pat^ {
	case ^Identifier:
		rewrite_string(&v.name, source_base)
	case ^ObjectPattern:
		rewrite_dynamic_header(&v.properties, base, len(v.properties))
	case ^ArrayPattern:
		// elements is []Maybe(Pattern) — slice, not dynamic
	case ^AssignmentPattern:
		rewrite_expr_field(v.right, &v.right, base, source_base)
	}
	// Rewrite the Pattern union's own pointer field
	rewrite_union_ptr(pat, base)
}

rewrite_function_params :: proc(params: ^[dynamic]FunctionParameter, base: uintptr, source_base: uintptr) {
	for i in 0..<len(params) {
		p := &params[i]
		rewrite_binding_pattern(&p.pattern, base, source_base)
		if def, ok := p.default_val.(^Expression); ok {
			rewrite_expression(def, base, source_base)
			rewrite_union_ptr(def, base)
		}
	}
	rewrite_dynamic_header(params, base, len(params))
}

rewrite_function_body :: proc(body: ^FunctionBody, base: uintptr, source_base: uintptr) {
	for i in 0..<len(body.directives) {
		rewrite_string(&body.directives[i].raw, source_base)
	}
	rewrite_dynamic_header(&body.directives, base, len(body.directives))
	rewrite_statement_array(&body.body, base, source_base)
}

rewrite_function_expression :: proc(f: ^FunctionExpression, base: uintptr, source_base: uintptr) {
	rewrite_function_params(&f.params, base, source_base)
	rewrite_function_body(&f.body, base, source_base)
}

rewrite_arrow_function :: proc(f: ^ArrowFunctionExpression, base: uintptr, source_base: uintptr) {
	rewrite_function_params(&f.params, base, source_base)
	rewrite_expression(f.body, base, source_base)
	rewrite_union_ptr(f.body, base)
}

rewrite_class_expression :: proc(c: ^ClassExpression, base: uintptr, source_base: uintptr) {
	if sc, ok := c.super_class.(^Expression); ok {
		rewrite_expression(sc, base, source_base)
		rewrite_union_ptr(sc, base)
	}
	for i in 0..<len(c.body.body) {
		elem := &c.body.body[i]
		rewrite_expression(elem.key, base, source_base)
		rewrite_union_ptr(elem.key, base)
		if val, ok := elem.value.?; ok {
			rewrite_expression(val, base, source_base)
			rewrite_union_ptr(val, base)
		}
	}
	rewrite_dynamic_header(&c.body.body, base, len(c.body.body))
}

rewrite_array_expression :: proc(a: ^ArrayExpression, base: uintptr, source_base: uintptr) {
	for i in 0..<len(a.elements) {
		if elem, ok := a.elements[i].(^Expression); ok {
			rewrite_expression(elem, base, source_base)
			rewrite_union_ptr(elem, base)
		}
	}
	rewrite_dynamic_header(&a.elements, base, len(a.elements))
}

rewrite_object_expression :: proc(o: ^ObjectExpression, base: uintptr, source_base: uintptr) {
	for i in 0..<len(o.properties) {
		prop := &o.properties[i]
		rewrite_expression(prop.key, base, source_base)
		rewrite_union_ptr(prop.key, base)
		rewrite_expression(prop.value, base, source_base)
		rewrite_union_ptr(prop.value, base)
	}
	rewrite_dynamic_header(&o.properties, base, len(o.properties))
}

rewrite_import_declaration :: proc(d: ^ImportDeclaration, base: uintptr, source_base: uintptr) {
	for i in 0..<len(d.specifiers) {
		rewrite_ptr((^rawptr)(&d.specifiers[i]), base)
	}
	rewrite_dynamic_header(&d.specifiers, base, len(d.specifiers))
}

rewrite_export_named :: proc(d: ^ExportNamedDeclaration, base: uintptr, source_base: uintptr) {
	if decl, ok := d.declaration.(^Declaration); ok {
		rewrite_ptr((^rawptr)(&d.declaration), base)
	}
	rewrite_dynamic_header(&d.specifiers, base, len(d.specifiers))
}

// ============================================================================
// Public API — produce a raw transfer buffer from a parse result
// ============================================================================

RawTransferResult :: struct {
	buffer:     []u8,     // the raw arena bytes (pointer rewritten)
	header:     RawTransferHeader,
	source:     string,   // original source text (for string decoding)
	error_count: int,
}

// Parse a file and produce a raw transfer buffer.
// The returned buffer contains the full AST with pointers rewritten to offsets.
// The arena memory backing the buffer stays alive — caller must not free it
// until done reading.
produce_raw_buffer :: proc(source: string, arena: ^mvirtual.Arena, arena_alloc: mem.Allocator) -> RawTransferResult {
	// Parse
	lex: Lexer
	init_lexer(&lex, source, arena_alloc)

	p: Parser
	init_parser(&p, &lex, arena_alloc)
	program := parse_program(&p, .Script)
	error_count := len(p.errors)

	// Get arena base pointer — all allocations are offsets from here
	base := uintptr(arena.curr_block.base)
	used := int(arena.total_used)

	// Rewrite all pointers to offsets
	rewrite_ast_pointers(program, base, source)

	// Build header
	program_offset := ptr_to_offset(base, program)
	header := RawTransferHeader{
		magic          = RAW_TRANSFER_MAGIC,
		version        = RAW_TRANSFER_VERSION,
		program_offset = program_offset,
		source_len     = u32(len(source)),
		total_bytes    = u32(used),
	}

	// Return the arena memory as a byte slice
	buffer := ([^]u8)(arena.curr_block.base)[:used]

	return RawTransferResult{
		buffer      = buffer,
		header      = header,
		source      = source,
		error_count = error_count,
	}
}

// Write raw transfer buffer to a file: [header][arena bytes]
write_raw_buffer :: proc(result: RawTransferResult, path: string) -> bool {
	fd, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	if err != nil { return false }
	defer os.close(fd)

	// Write header
	header_bytes := transmute([size_of(RawTransferHeader)]u8)result.header
	os.write(fd, header_bytes[:])

	// Write arena buffer
	os.write(fd, result.buffer)

	return true
}
