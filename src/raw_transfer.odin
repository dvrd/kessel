package kessel

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

// STRING_ARENA_FLAG is the high bit of a string offset. Set when the string's
// backing bytes live in the arena (e.g. a Bug E escape-decoded cooked string)
// rather than in the source text. Readers mask this bit off and pick the right
// byte region:
//
//   bit 31 = 0 → offset relative to source_base, length bytes inside source
//   bit 31 = 1 → offset relative to buffer base (arena), length bytes inside buffer
//
// The flag is 0x8000_0000 specifically so it can't collide with a legitimate
// source offset — JS source files larger than 2 GB would break other assumptions
// in the raw transfer format (u32 offsets for dynamic arrays, etc.) long before
// this bit would be needed for source.
STRING_ARENA_FLAG :: u32(0x8000_0000)

// Thread-local region bounds used by rewrite_string to distinguish source-slice
// strings from arena-slice cooked strings. Set at the top of rewrite_ast_pointers
// before the recursive descent and read from every rewrite_string call site.
// Thread-local because parse_many spawns N workers, each rewriting a different
// arena+source pair concurrently; a file-global would race between workers.
//
// This is a deliberate TigerStyle concession: the alternative is threading
// two extra uintptr args through 17 rewrite_* functions for what is purely
// contextual info, and the scope here is tight — set-once at the entry point,
// read-only in leaves, cleared at function exit.
@(thread_local) tl_source_base: uintptr
@(thread_local) tl_source_end:  uintptr
@(thread_local) tl_arena_base:  uintptr

ptr_to_offset :: #force_inline proc(base: uintptr, ptr: rawptr) -> u32 {
	if ptr == nil { return 0 }
	return u32(uintptr(ptr) - base)
}

rewrite_ast_pointers :: proc(program: ^Program, base: uintptr, source: string) {
	source_base := uintptr(raw_data(source))
	tl_source_base = source_base
	tl_source_end  = source_base + uintptr(len(source))
	tl_arena_base  = base
	defer {
		// Clear thread-locals to catch any stale use after return — a later
		// rewrite_string call with these zeroed would produce an obviously
		// broken u32 offset rather than silently reading neighbouring data.
		tl_source_base = 0
		tl_source_end  = 0
		tl_arena_base  = 0
	}
	rewrite_program(program, base, source_base)
}

// ============================================================================
// Per-node rewriters
// ============================================================================

rewrite_ptr :: #force_inline proc(field: ^rawptr, base: uintptr) {
	if field^ != nil {
		offset := u32(uintptr(field^) - base)
		(^u32)(field)^ = offset
	}
}

// Helper: rewrite a string field in-place to (offset, len)
// String in Odin = {ptr: rawptr, len: int} = 16 bytes
// We rewrite to {offset: u32, len: u32} in the first 8 bytes.
//
// Offset encoding: the high bit discriminates source vs arena origin
// (see STRING_ARENA_FLAG doc). `source_base` is accepted as an argument for
// API compatibility with the 17 call sites but is cross-checked against the
// thread-local region bounds so a mis-plumbed call site fails fast rather
// than silently producing a wrong offset.
rewrite_string :: #force_inline proc(field: ^string, source_base: uintptr) {
	s := field^
	if len(s) == 0 {
		(^[2]u32)(field)^ = {0, 0}
		return
	}
	ptr := uintptr(raw_data(s))
	length := u32(len(s))
	if ptr >= tl_source_base && ptr < tl_source_end {
		// Common case: slice into the source text. Offset fits in 31 bits because
		// source sizes over 2 GB would break other u32 offsets in the format.
		offset := u32(ptr - tl_source_base)
		(^[2]u32)(field)^ = {offset, length}
	} else {
		// Arena-allocated cooked string (e.g. Bug E escape-decoded). Rewrite as
		// a buffer-relative offset with STRING_ARENA_FLAG set so readers know
		// to read from the buffer rather than from source.
		offset := u32(ptr - tl_arena_base) | STRING_ARENA_FLAG
		(^[2]u32)(field)^ = {offset, length}
	}
}

rewrite_maybe_string :: #force_inline proc(field: ^Maybe(string), source_base: uintptr) {
	if _, ok := field^.(string); ok {
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

rewrite_expr_field :: #force_inline proc(expr: ^Expression, field_addr: rawptr, base: uintptr, source_base: uintptr) {
	if expr == nil { return }
	rewrite_expression(expr, base, source_base)  // recurse into contents
	rewrite_union_ptr(expr, base)                // rewrite union's inner ptr
	rewrite_ptr((^rawptr)(field_addr), base)     // rewrite the field itself
}

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

// Helper: rewrite the embedded `name` string of a Maybe(BindingIdentifier)
// in place when the Maybe is set. Used for ClassExpression.id and
// FunctionExpression.id (and via `using expr` for ClassDeclaration /
// FunctionDeclaration). The Maybe layout is:
//
//   {BindingIdentifier{loc, name: string} <value>, tag: u8 <padded>}
//
// so the value bytes start at the field's address, and we can overlay a
// ^BindingIdentifier on `field` when the tag is set. The tag byte itself
// is left untouched.
rewrite_maybe_binding_id_name :: #force_inline proc(field: ^Maybe(BindingIdentifier), source_base: uintptr) {
	if _, ok := field.?; ok {
		bi := (^BindingIdentifier)(field)
		rewrite_string(&bi.name, source_base)
	}
}

// ============================================================================
// Expression rewriter
// ============================================================================

rewrite_expression :: proc(expr: ^Expression, base: uintptr, source_base: uintptr) {
	if expr == nil { return }
	
	// First rewrite the union pointer itself is not needed — the parent does that.
	// We need to rewrite the INNER fields of whichever variant it holds.
	
	// Complete switch (no #partial, no default): the Odin compiler now
	// enforces that every variant of `Expression :: union { ... }` in
	// src/ast.odin has an explicit case here. A new AST variant fails the
	// build instead of silently leaving its pointers un-rewritten in the
	// binary buffer — the dropped-variant bug class noted for ChainExpression
	// and TSInstantiationExpression below.
	switch v in expr {
	case ^Identifier:
		rewrite_identifier(v, base, source_base)
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
		rewrite_maybe_expr(&v.argument, base, source_base)
	case ^AwaitExpression:
		rewrite_expr_field(v.argument, &v.argument, base, source_base)
	case ^ImportExpression:
		rewrite_expr_field(v.source, &v.source, base, source_base)
	case ^MetaProperty:
		rewrite_string(&v.meta.name, source_base)
		rewrite_string(&v.property.name, source_base)
	// ChainExpression (S26 W3). Wraps a ^Expression that's a Member or
	// Call expression with `optional: true`. Sibling latent gap: the JSON
	// path emits these correctly, but the binary path's switch fell
	// through to the default and left the inner pointer un-rewritten on
	// every optional-chain (`a?.b`, `a?.()`).
	case ^ChainExpression:
		rewrite_expr_field(v.expression, &v.expression, base, source_base)
	// JSX expression variants (S26 W3). Each one is the entry point for
	// either a JSX subtree (Element/Fragment) or a leaf-level child
	// (Text/ExpressionContainer/EmptyExpression/SpreadChild). The JSX
	// walker section below mirrors the TSType walker pattern: bottom-up
	// helpers, dispatch from this position. Before this commit, the four
	// most common React-shaped expressions silently left their inner
	// pointers un-rewritten in the binary buffer.
	case ^JSXElement:
		rewrite_jsx_element(v, base, source_base)
	case ^JSXFragment:
		rewrite_jsx_fragment(v, base, source_base)
	case ^JSXText:
		rewrite_string(&v.value, source_base)
		rewrite_string(&v.raw, source_base)
	case ^JSXExpressionContainer:
		rewrite_expr_field(v.expression, &v.expression, base, source_base)
	case ^JSXEmptyExpression:
		// no pointer fields beyond loc
	case ^JSXSpreadChild:
		rewrite_expr_field(v.expression, &v.expression, base, source_base)
	// TS expression variants. Reach into the TSType walker for type-annotation
	// slots. Without these, TS-bearing expressions in the binary buffer
	// leave the wrapped expression and type pointers unrewritten.
	case ^TSAsExpression:
		rewrite_expr_field(v.expression, &v.expression, base, source_base)
		rewrite_ts_type_field(v.type_annotation, &v.type_annotation, base, source_base)
	case ^TSSatisfiesExpression:
		rewrite_expr_field(v.expression, &v.expression, base, source_base)
		rewrite_ts_type_field(v.type_annotation, &v.type_annotation, base, source_base)
	case ^TSNonNullExpression:
		rewrite_expr_field(v.expression, &v.expression, base, source_base)
	case ^TSTypeAssertion:
		rewrite_ts_type_field(v.type_annotation, &v.type_annotation, base, source_base)
		rewrite_expr_field(v.expression, &v.expression, base, source_base)
	// TSInstantiationExpression (`foo<number>`). Wraps an inner ^Expression
	// plus a ^TSTypeParameterInstantiation. It was the lone Expression union
	// variant still missing from this switch, so its two pointers fell through
	// to the default and stayed un-rewritten in the binary buffer — the same
	// silently-dropped-variant bug class documented for ChainExpression above.
	case ^TSInstantiationExpression:
		rewrite_expr_field(v.expression, &v.expression, base, source_base)
		if v.type_arguments != nil {
			rewrite_ts_type_parameter_instantiation(v.type_arguments, base, source_base)
			rewrite_ptr((^rawptr)(&v.type_arguments), base)
		}
	case ^ParenthesizedExpression:
		// Pure ESTree wrapper — emitted only under --preserve-parens but
		// the variant exists in the union and would otherwise be silently
		// skipped here, leaving the inner expression's pointer unrewritten.
		rewrite_expr_field(v.expression, &v.expression, base, source_base)
	}
}

// ============================================================================
// Statement rewriter
// ============================================================================

rewrite_statement :: proc(stmt: ^Statement, base: uintptr, source_base: uintptr) {
	if stmt == nil { return }
	
	// Complete switch (no #partial, no default): the Odin compiler enforces that
	// every variant of `Statement :: union { ... }` in src/ast.odin has an explicit
	// case here. A new AST variant fails the build instead of silently leaving its
	// pointers un-rewritten in the binary buffer.
	switch v in stmt {
	case ^ExpressionStatement:
		rewrite_expr_field(v.expression, &v.expression, base, source_base)
	case ^BlockStatement:
		rewrite_statement_array(&v.body, base, source_base)
	case ^EmptyStatement:
	case ^DebuggerStatement:
	case ^ReturnStatement:
		rewrite_maybe_expr(&v.argument, base, source_base)
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
		rewrite_stmt_field(v.body, &v.body, base, source_base)
	case ^IfStatement:
		rewrite_expr_field(v.test, &v.test, base, source_base)
		rewrite_stmt_field(v.consequent, &v.consequent, base, source_base)
		rewrite_maybe_stmt(&v.alternate, base, source_base)
	case ^SwitchStatement:
		rewrite_expr_field(v.discriminant, &v.discriminant, base, source_base)
		for i in 0..<len(v.cases) {
			c := &v.cases[i]
			rewrite_maybe_expr(&c.test, base, source_base)
			rewrite_statement_array(&c.consequent, base, source_base)
		}
		rewrite_dynamic_header(&v.cases, base, len(v.cases))
	case ^WhileStatement:
		rewrite_expr_field(v.test, &v.test, base, source_base)
		rewrite_stmt_field(v.body, &v.body, base, source_base)
	case ^DoWhileStatement:
		rewrite_stmt_field(v.body, &v.body, base, source_base)
		rewrite_expr_field(v.test, &v.test, base, source_base)
	case ^ForStatement:
		// init_decl/init_expr hold pointers stored as the union variant the
		// parser chose (^VariableDeclaration vs ^Expression). Reinterpret
		// each as the right pointer kind via cast — vet prefers cast over
		// transmute for pointer-like types.
		if init_ptr := (^rawptr)(&v.init_decl)^; init_ptr != nil {
			rewrite_statement(cast(^Statement)init_ptr, base, source_base)
			(^u32)(&v.init_decl)^ = ptr_to_offset(base, init_ptr)
		}
		if init_ptr := (^rawptr)(&v.init_expr)^; init_ptr != nil {
			rewrite_expression(cast(^Expression)init_ptr, base, source_base)
			rewrite_union_ptr(cast(^Expression)init_ptr, base)
			(^u32)(&v.init_expr)^ = ptr_to_offset(base, init_ptr)
		}
		rewrite_maybe_expr(&v.test, base, source_base)
		rewrite_maybe_expr(&v.update, base, source_base)
		rewrite_stmt_field(v.body, &v.body, base, source_base)
	case ^ForInStatement:
		if ptr := (^rawptr)(&v.left_decl)^; ptr != nil {
			rewrite_statement(cast(^Statement)ptr, base, source_base)
			(^u32)(&v.left_decl)^ = ptr_to_offset(base, ptr)
		}
		if ptr := (^rawptr)(&v.left_expr)^; ptr != nil {
			rewrite_expression(cast(^Expression)ptr, base, source_base)
			rewrite_union_ptr(cast(^Expression)ptr, base)
			(^u32)(&v.left_expr)^ = ptr_to_offset(base, ptr)
		}
		rewrite_expr_field(v.right, &v.right, base, source_base)
		rewrite_stmt_field(v.body, &v.body, base, source_base)
	case ^ForOfStatement:
		if ptr := (^rawptr)(&v.left_decl)^; ptr != nil {
			rewrite_statement(cast(^Statement)ptr, base, source_base)
			(^u32)(&v.left_decl)^ = ptr_to_offset(base, ptr)
		}
		if ptr := (^rawptr)(&v.left_expr)^; ptr != nil {
			rewrite_expression(cast(^Expression)ptr, base, source_base)
			rewrite_union_ptr(cast(^Expression)ptr, base)
			(^u32)(&v.left_expr)^ = ptr_to_offset(base, ptr)
		}
		rewrite_expr_field(v.right, &v.right, base, source_base)
		rewrite_stmt_field(v.body, &v.body, base, source_base)
	case ^WithStatement:
		rewrite_expr_field(v.object, &v.object, base, source_base)
		rewrite_stmt_field(v.body, &v.body, base, source_base)
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
	// TS Statement variants (S26 W3). Same partial-switch position as the
	// JS variants; reach into the TSType walker for type-annotation slots
	// and into the JS expr/stmt walkers for the embedded id / module-body
	// surfaces. Without these, every TS-typed top-level construct
	// (interface / type / enum / namespace) leaves its inner pointers
	// un-rewritten in the binary buffer, so a downstream consumer reading
	// `id.name`, `extends[i].expression`, enum members, or a nested
	// namespace body hits absolute arena addresses outside the buffer.
	case ^TSInterfaceDeclaration:
		rewrite_string(&v.id.name, source_base)
		rewrite_maybe_ts_type_parameter_declaration(&v.type_parameters, base, source_base)
		rewrite_ts_interface_heritage_array(&v.extends, base, source_base)
		rewrite_ts_signature_array(&v.body.body, base, source_base)
	case ^TSTypeAliasDeclaration:
		rewrite_string(&v.id.name, source_base)
		rewrite_maybe_ts_type_parameter_declaration(&v.type_parameters, base, source_base)
		rewrite_ts_type_field(v.type_annotation, &v.type_annotation, base, source_base)
	case ^TSEnumDeclaration:
		rewrite_string(&v.id.name, source_base)
		rewrite_ts_enum_body(&v.body, base, source_base)
	case ^TSModuleDeclaration:
		rewrite_ts_module_declaration(v, base, source_base)
	case ^TSImportEqualsDeclaration:
		rewrite_string(&v.id.name, source_base)
		rewrite_ts_module_reference(&v.module_reference, base, source_base)
	case ^TSExportAssignment:
		rewrite_expr_field(v.expression, &v.expression, base, source_base)
	case ^TSNamespaceExportDeclaration:
		rewrite_string(&v.id.name, source_base)
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
	dir_len := len(p.directives)
	for i in 0..<dir_len {
		rewrite_string(&p.directives[i].value.value, source_base)
		rewrite_string(&p.directives[i].value.raw, source_base)
		rewrite_string(&p.directives[i].raw, source_base)
	}
	rewrite_dynamic_header(rawptr(&p.directives), base, dir_len)

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

// Identifier carries a Maybe(^TSTypeAnnotation) that's set on TS-typed
// bindings (`(v: T)`, `let x: T`, class field keys with annotations) and
// nil on plain JS identifiers. Walk both surfaces uniformly.
rewrite_identifier :: #force_inline proc(v: ^Identifier, base: uintptr, source_base: uintptr) {
	rewrite_string(&v.name, source_base)
	rewrite_maybe_ts_type_annotation(&v.type_annotation, base, source_base)
}

rewrite_binding_pattern :: proc(pat: ^Pattern, base: uintptr, source_base: uintptr) {
	if pat == nil { return }
	#partial switch v in pat^ {
	case ^Identifier:
		rewrite_identifier(v, base, source_base)
	case ^ObjectPattern:
		rewrite_dynamic_header(&v.properties, base, len(v.properties))
		// S26 W4b: ObjectPattern grew a `type_annotation: Maybe(^TSTypeAnnotation)`
		// slot to capture `function f({a, b}: T)` annotations the parser
		// previously dropped on the floor. Walk it through the binary path.
		rewrite_maybe_ts_type_annotation(&v.type_annotation, base, source_base)
	case ^ArrayPattern:
		// elements is []Maybe(Pattern) — slice, not dynamic
		// S26 W4b: same type_annotation slot as ObjectPattern.
		rewrite_maybe_ts_type_annotation(&v.type_annotation, base, source_base)
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
		rewrite_maybe_expr(&p.default_val, base, source_base)
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
	// Optional name (`function foo() {}` vs `function() {}`). The string
	// `name` slot lives inside the Maybe payload and points into source;
	// without this rewrite, named FunctionExpression / FunctionDeclaration
	// nodes leave a raw source ptr in the binary buffer.
	rewrite_maybe_binding_id_name(&f.id, source_base)
	rewrite_maybe_ts_type_parameter_declaration(&f.type_parameters, base, source_base)
	rewrite_function_params(&f.params, base, source_base)
	rewrite_function_body(&f.body, base, source_base)
	rewrite_maybe_ts_type_annotation(&f.return_type, base, source_base)
}

rewrite_arrow_function :: proc(f: ^ArrowFunctionExpression, base: uintptr, source_base: uintptr) {
	rewrite_maybe_ts_type_parameter_declaration(&f.type_parameters, base, source_base)
	rewrite_function_params(&f.params, base, source_base)
	rewrite_maybe_ts_type_annotation(&f.return_type, base, source_base)
	#partial switch body in f.body {
	case ^Expression:
		// Expression-form body (e.g. `x => x+1`). Recurse + rewrite the
		// expression union's own ptr, then rewrite the outer ^Expression
		// pointer stored in the arrow body's union.
		rewrite_expr_field(body, &f.body, base, source_base)
	case ^BlockStatement:
		// Block-form body (e.g. `x => { return x+1 }`). BlockStatement is
		// a concrete struct (not a union), so walk its fields and rewrite
		// the outer pointer directly.
		rewrite_statement_array(&body.body, base, source_base)
		rewrite_ptr((^rawptr)(&f.body), base)
	}
}

// =============================================================================
// TypeScript walker (S26 W2-alt)
//
// Walks every TS-typed slot reachable from class / function / arrow node
// surfaces and from the TS-bearing Expression union variants. Built
// bottom-up: the master rewrite_ts_type partial-switches on the TSType
// union, helpers handle the recurring container shapes (TSTypeAnnotation,
// TSTypeParameterDeclaration / Instantiation, TSFunctionParam, TSSignature,
// TSInterfaceHeritage), and field-level wrappers mirror the JS-side
// rewrite_expr_field / rewrite_maybe_expr conventions.
//
// Used by both W2-alt (class/function/identifier slots, TS-bearing
// Expression variants) and W3 (TSInterfaceDeclaration /
// TSTypeAliasDeclaration top-level slots that point into the type tree).
// =============================================================================

rewrite_ts_type_field :: #force_inline proc(t: ^TSType, field_addr: rawptr, base: uintptr, source_base: uintptr) {
	if t == nil { return }
	rewrite_ts_type(t, base, source_base)
	rewrite_union_ptr(t, base)             // TSType is a union of pointer variants
	rewrite_ptr((^rawptr)(field_addr), base) // outer ^TSType field
}

rewrite_maybe_ts_type :: #force_inline proc(field: ^Maybe(^TSType), base: uintptr, source_base: uintptr) {
	if t, ok := field.?; ok {
		rewrite_ts_type(t, base, source_base)
		rewrite_union_ptr(t, base)
		rewrite_ptr((^rawptr)(field), base)
	}
}

rewrite_ts_type_array :: proc(arr: ^[dynamic]^TSType, base: uintptr, source_base: uintptr) {
	for i in 0..<len(arr) {
		slot := &arr[i]
		rewrite_ts_type_field(slot^, slot, base, source_base)
	}
	rewrite_dynamic_header(arr, base, len(arr))
}

// ^TSTypeAnnotation wraps a single ^TSType. Walk that, then the parent's
// pointer slot is rewritten by the *_field / *_maybe wrapper variants.
rewrite_ts_type_annotation :: proc(a: ^TSTypeAnnotation, base: uintptr, source_base: uintptr) {
	if a == nil { return }
	rewrite_ts_type_field(a.type_annotation, &a.type_annotation, base, source_base)
}

rewrite_ts_type_annotation_field :: #force_inline proc(a: ^TSTypeAnnotation, field_addr: rawptr, base: uintptr, source_base: uintptr) {
	if a == nil { return }
	rewrite_ts_type_annotation(a, base, source_base)
	rewrite_ptr((^rawptr)(field_addr), base)
}

rewrite_maybe_ts_type_annotation :: #force_inline proc(field: ^Maybe(^TSTypeAnnotation), base: uintptr, source_base: uintptr) {
	if a, ok := field.?; ok {
		rewrite_ts_type_annotation(a, base, source_base)
		rewrite_ptr((^rawptr)(field), base)
	}
}

// TSTypeParameter is an embedded value type (not a pointer) inside
// TSTypeParameterDeclaration.params, TSInferType.type_parameter, and
// TSMappedType.type_parameter. Walk in place.
rewrite_ts_type_parameter :: proc(p: ^TSTypeParameter, base: uintptr, source_base: uintptr) {
	rewrite_string(&p.name.name, source_base)
	rewrite_maybe_ts_type(&p.constraint, base, source_base)
	rewrite_maybe_ts_type(&p.default_, base, source_base)
}

rewrite_ts_type_parameter_declaration :: proc(d: ^TSTypeParameterDeclaration, base: uintptr, source_base: uintptr) {
	if d == nil { return }
	for i in 0..<len(d.params) {
		rewrite_ts_type_parameter(&d.params[i], base, source_base)
	}
	rewrite_dynamic_header(&d.params, base, len(d.params))
}

rewrite_maybe_ts_type_parameter_declaration :: #force_inline proc(field: ^Maybe(^TSTypeParameterDeclaration), base: uintptr, source_base: uintptr) {
	if d, ok := field.?; ok {
		rewrite_ts_type_parameter_declaration(d, base, source_base)
		rewrite_ptr((^rawptr)(field), base)
	}
}

rewrite_ts_type_parameter_instantiation :: proc(inst: ^TSTypeParameterInstantiation, base: uintptr, source_base: uintptr) {
	if inst == nil { return }
	rewrite_ts_type_array(&inst.params, base, source_base)
}

rewrite_maybe_ts_type_parameter_instantiation :: #force_inline proc(field: ^Maybe(^TSTypeParameterInstantiation), base: uintptr, source_base: uintptr) {
	if inst, ok := field.?; ok {
		rewrite_ts_type_parameter_instantiation(inst, base, source_base)
		rewrite_ptr((^rawptr)(field), base)
	}
}

// TSFunctionParam is a value type embedded in TSFunctionType.params /
// TSConstructorType.params / TS*Signature.params arrays.
rewrite_ts_function_param :: proc(p: ^TSFunctionParam, base: uintptr, source_base: uintptr) {
	rewrite_binding_pattern(&p.pattern, base, source_base)
	rewrite_maybe_ts_type_annotation(&p.type_annotation, base, source_base)
}

rewrite_ts_function_param_array :: proc(arr: ^[dynamic]TSFunctionParam, base: uintptr, source_base: uintptr) {
	for i in 0..<len(arr) {
		rewrite_ts_function_param(&arr[i], base, source_base)
	}
	rewrite_dynamic_header(arr, base, len(arr))
}

// TSSignature is a value-typed union held as ^TSSignature in
// TSTypeLiteral.members / TSInterfaceBody.body. The pointer addresses a
// union value with the variant struct stored inline at offset 0; we
// type-assert the tag, then overlay a typed pointer on the same address
// to walk the inline struct in place.
rewrite_ts_signature :: proc(s: ^TSSignature, base: uintptr, source_base: uintptr) {
	if s == nil { return }
	#partial switch _ in s^ {
	case TSPropertySignature:
		ps := (^TSPropertySignature)(s)
		rewrite_expr_field(ps.key, &ps.key, base, source_base)
		rewrite_maybe_ts_type_annotation(&ps.type_annotation, base, source_base)
	case TSMethodSignature:
		ms := (^TSMethodSignature)(s)
		rewrite_expr_field(ms.key, &ms.key, base, source_base)
		rewrite_maybe_ts_type_parameter_declaration(&ms.type_parameters, base, source_base)
		rewrite_ts_function_param_array(&ms.params, base, source_base)
		rewrite_maybe_ts_type_annotation(&ms.return_type, base, source_base)
	case TSCallSignatureDeclaration:
		cs := (^TSCallSignatureDeclaration)(s)
		rewrite_maybe_ts_type_parameter_declaration(&cs.type_parameters, base, source_base)
		rewrite_ts_function_param_array(&cs.params, base, source_base)
		rewrite_maybe_ts_type_annotation(&cs.return_type, base, source_base)
	case TSConstructSignatureDeclaration:
		cs := (^TSConstructSignatureDeclaration)(s)
		rewrite_maybe_ts_type_parameter_declaration(&cs.type_parameters, base, source_base)
		rewrite_ts_function_param_array(&cs.params, base, source_base)
		rewrite_maybe_ts_type_annotation(&cs.return_type, base, source_base)
	case TSIndexSignature:
		ix := (^TSIndexSignature)(s)
		rewrite_ts_function_param_array(&ix.parameters, base, source_base)
		rewrite_maybe_ts_type_annotation(&ix.type_annotation, base, source_base)
	}
}

rewrite_ts_signature_array :: proc(arr: ^[dynamic]^TSSignature, base: uintptr, source_base: uintptr) {
	for i in 0..<len(arr) {
		slot := &arr[i]
		if slot^ != nil {
			rewrite_ts_signature(slot^, base, source_base)
			rewrite_ptr((^rawptr)(slot), base) // ^TSSignature in the array slot
		}
	}
	rewrite_dynamic_header(arr, base, len(arr))
}

rewrite_ts_interface_heritage :: proc(h: ^TSInterfaceHeritage, base: uintptr, source_base: uintptr) {
	rewrite_expr_field(h.expression, &h.expression, base, source_base)
	rewrite_maybe_ts_type_parameter_instantiation(&h.type_parameters, base, source_base)
}

rewrite_ts_interface_heritage_array :: proc(arr: ^[dynamic]TSInterfaceHeritage, base: uintptr, source_base: uintptr) {
	for i in 0..<len(arr) {
		rewrite_ts_interface_heritage(&arr[i], base, source_base)
	}
	rewrite_dynamic_header(arr, base, len(arr))
}

// Master TSType union walker. Keyword variants have only `loc` and need
// no rewrites; compound variants recurse via the helpers above. The case
// list mirrors src/ast.odin's `TSType :: union { ... }` declaration order.
rewrite_ts_type :: proc(t: ^TSType, base: uintptr, source_base: uintptr) {
	if t == nil { return }
	#partial switch v in t {
	// Keywords — no pointer fields beyond loc
	case ^TSAnyKeyword, ^TSBigIntKeyword, ^TSBooleanKeyword, ^TSIntrinsicKeyword,
	     ^TSNeverKeyword, ^TSNullKeyword, ^TSNumberKeyword, ^TSObjectKeyword,
	     ^TSStringKeyword, ^TSSymbolKeyword, ^TSUndefinedKeyword, ^TSUnknownKeyword,
	     ^TSVoidKeyword, ^TSThisType:
		// nothing to walk
	case ^TSTypeReference:
		rewrite_expr_field(v.type_name, &v.type_name, base, source_base)
		rewrite_maybe_ts_type_parameter_instantiation(&v.type_parameters, base, source_base)
	case ^TSUnionType:
		rewrite_ts_type_array(&v.types, base, source_base)
	case ^TSIntersectionType:
		rewrite_ts_type_array(&v.types, base, source_base)
	case ^TSArrayType:
		rewrite_ts_type_field(v.element_type, &v.element_type, base, source_base)
	case ^TSTupleType:
		rewrite_ts_type_array(&v.element_types, base, source_base)
	case ^TSFunctionType:
		rewrite_maybe_ts_type_parameter_declaration(&v.type_parameters, base, source_base)
		rewrite_ts_function_param_array(&v.params, base, source_base)
		rewrite_ts_type_annotation_field(v.return_type, &v.return_type, base, source_base)
	case ^TSConstructorType:
		rewrite_maybe_ts_type_parameter_declaration(&v.type_parameters, base, source_base)
		rewrite_ts_function_param_array(&v.params, base, source_base)
		rewrite_ts_type_annotation_field(v.return_type, &v.return_type, base, source_base)
	case ^TSTypeLiteral:
		rewrite_ts_signature_array(&v.members, base, source_base)
	case ^TSConditionalType:
		rewrite_ts_type_field(v.check_type,   &v.check_type,   base, source_base)
		rewrite_ts_type_field(v.extends_type, &v.extends_type, base, source_base)
		rewrite_ts_type_field(v.true_type,    &v.true_type,    base, source_base)
		rewrite_ts_type_field(v.false_type,   &v.false_type,   base, source_base)
	case ^TSInferType:
		rewrite_ts_type_parameter(&v.type_parameter, base, source_base)
	case ^TSTypeQuery:
		rewrite_expr_field(v.expr_name, &v.expr_name, base, source_base)
		rewrite_maybe_ts_type_parameter_instantiation(&v.type_parameters, base, source_base)
	case ^TSTypeOperator:
		rewrite_string(&v.operator, source_base)
		rewrite_ts_type_field(v.type_annotation, &v.type_annotation, base, source_base)
	case ^TSIndexedAccessType:
		rewrite_ts_type_field(v.object_type, &v.object_type, base, source_base)
		rewrite_ts_type_field(v.index_type,  &v.index_type,  base, source_base)
	case ^TSMappedType:
		rewrite_ts_type_parameter(&v.type_parameter, base, source_base)
		rewrite_maybe_ts_type(&v.name_type,       base, source_base)
		rewrite_maybe_ts_type(&v.type_annotation, base, source_base)
	case ^TSLiteralType:
		rewrite_expr_field(v.literal, &v.literal, base, source_base)
	case ^TSTemplateLiteralType:
		for i in 0..<len(v.quasis) {
			q := &v.quasis[i]
			rewrite_maybe_string(&q.cooked, source_base)
			rewrite_string(&q.raw, source_base)
		}
		rewrite_dynamic_header(&v.quasis, base, len(v.quasis))
		rewrite_ts_type_array(&v.types, base, source_base)
	case ^TSParenthesizedType:
		rewrite_ts_type_field(v.type_annotation, &v.type_annotation, base, source_base)
	case ^TSRestType:
		rewrite_ts_type_field(v.type_annotation, &v.type_annotation, base, source_base)
	case ^TSOptionalType:
		rewrite_ts_type_field(v.type_annotation, &v.type_annotation, base, source_base)
	case ^TSNamedTupleMember:
		rewrite_string(&v.label.name, source_base)
		rewrite_ts_type_field(v.element_type, &v.element_type, base, source_base)
	case ^TSTypePredicate:
		rewrite_expr_field(v.parameter_name, &v.parameter_name, base, source_base)
		rewrite_maybe_ts_type_annotation(&v.type_annotation, base, source_base)
	case ^TSImportType:
		rewrite_ts_type_field(v.argument, &v.argument, base, source_base)
		rewrite_maybe_expr(&v.qualifier, base, source_base)
		rewrite_maybe_ts_type_parameter_instantiation(&v.type_parameters, base, source_base)
	}
}

// =============================================================================
// TS Statement helpers (S26 W3)
//
// `rewrite_statement` now dispatches into TSInterfaceDeclaration /
// TSTypeAliasDeclaration / TSEnumDeclaration / TSModuleDeclaration. The
// interface / type-alias paths reuse the existing TSType walker directly;
// the enum and module paths need their own helpers because TSEnumBody /
// TSModuleBody hold member structs that aren't reachable from any other
// surface.
// =============================================================================

rewrite_ts_enum_body :: proc(b: ^TSEnumBody, base: uintptr, source_base: uintptr) {
	for i in 0..<len(b.members) {
		m := &b.members[i]
		rewrite_expr_field(m.id, &m.id, base, source_base)
		rewrite_maybe_expr(&m.initializer, base, source_base)
	}
	rewrite_dynamic_header(&b.members, base, len(b.members))
}

// TSModuleDeclaration walker, factored out because the body field can
// recursively hold another TSModuleDeclaration (`namespace A.B.C {}`
// desugars to a chain of nested module declarations) and we want a
// single entry point for both the top-level and recursive cases.
rewrite_ts_module_declaration :: proc(m: ^TSModuleDeclaration, base: uintptr, source_base: uintptr) {
	rewrite_expr_field(m.id, &m.id, base, source_base)
	rewrite_maybe_ts_module_body(&m.body, base, source_base)
}

// TSModuleBody is `union { ^TSModuleBlock, ^TSModuleDeclaration }` —
// pointer variants only, same shape as Expression / Statement at the
// memory level (`{inner_ptr: 8, tag: 1, pad: 7}`). Walk the inner
// struct, then collapse the union ptr.
rewrite_ts_module_body :: proc(b: ^TSModuleBody, base: uintptr, source_base: uintptr) {
	if b == nil { return }
	#partial switch v in b^ {
	case ^TSModuleBlock:
		rewrite_statement_array(&v.body, base, source_base)
	case ^TSModuleDeclaration:
		rewrite_ts_module_declaration(v, base, source_base)
	}
}

rewrite_maybe_ts_module_body :: #force_inline proc(field: ^Maybe(^TSModuleBody), base: uintptr, source_base: uintptr) {
	if b, ok := field.?; ok {
		rewrite_ts_module_body(b, base, source_base)
		rewrite_union_ptr(b, base)
		rewrite_ptr((^rawptr)(field), base)
	}
}

// TSModuleReference :: union { ^Expression, ^TSExternalModuleReference } —
// `import X = A.B.C` (Identifier/MemberExpression in the ^Expression arm) and
// `import X = require("m")` (^TSExternalModuleReference whose `expression` is the
// require()'d ^StringLiteral). The field is an inline union value with the same
// memory shape as Expression (`{inner_ptr: 8, tag: 1, pad: 7}`): walk the inner
// node, then collapse the union's inner ptr in place.
rewrite_ts_module_reference :: proc(field: ^TSModuleReference, base: uintptr, source_base: uintptr) {
	#partial switch v in field^ {
	case ^Expression:
		rewrite_expression(v, base, source_base)
		rewrite_union_ptr(v, base)
	case ^TSExternalModuleReference:
		if v.expression != nil {
			rewrite_string(&v.expression.value, source_base)
			rewrite_string(&v.expression.raw, source_base)
			rewrite_ptr((^rawptr)(&v.expression), base)
		}
	}
	rewrite_union_ptr(field, base)
}

// =============================================================================
// JSX walker (S26 W3)
//
// Walks every JSX-typed slot reachable from the JSX expression-union
// variants (JSXElement, JSXFragment, JSXText, JSXExpressionContainer,
// JSXEmptyExpression, JSXSpreadChild). Built bottom-up: leaf helpers
// (rewrite_jsx_identifier, rewrite_jsx_member_expression,
// rewrite_jsx_namespaced_name) feed the union helpers (rewrite_jsx_*_name
// for the three name-shaped unions; rewrite_jsx_attribute_item for the
// attribute union; rewrite_jsx_child for the child union), and the
// public entry points rewrite_jsx_element / rewrite_jsx_fragment are
// dispatched from rewrite_expression's switch above.
//
// The JSX-side unions are a mix of value-typed variants (JSXIdentifier
// inside JSXElementName / JSXMemberObject / JSXAttributeName, JSXAttribute
// inside JSXAttributeItem) and pointer-typed variants. Value-typed
// variants are walked in place via a `(^T)(union_addr)` overlay, mirroring
// the rewrite_ts_signature pattern; pointer-typed variants follow the
// rewrite_union_ptr + rewrite_ptr pattern used by rewrite_expr_field.
// =============================================================================

rewrite_jsx_identifier :: #force_inline proc(id: ^JSXIdentifier, source_base: uintptr) {
	rewrite_string(&id.name, source_base)
}

// JSXMemberObject :: union { JSXIdentifier (value), ^JSXMemberExpression }.
// The union value lives at the supplied address; on tag 0 the JSXIdentifier
// is overlaid in place, on tag 1 the inner ^JSXMemberExpression is walked
// and its slot collapsed.
rewrite_jsx_member_object :: proc(obj: ^JSXMemberObject, base: uintptr, source_base: uintptr) {
	#partial switch v in obj^ {
	case JSXIdentifier:
		rewrite_jsx_identifier((^JSXIdentifier)(obj), source_base)
	case ^JSXMemberExpression:
		rewrite_jsx_member_expression(v, base, source_base)
		rewrite_union_ptr(obj, base)
	}
}

rewrite_jsx_member_expression :: proc(m: ^JSXMemberExpression, base: uintptr, source_base: uintptr) {
	if m == nil { return }
	rewrite_jsx_member_object(&m.object, base, source_base)
	rewrite_jsx_identifier(&m.property, source_base)
}

rewrite_jsx_namespaced_name :: proc(n: ^JSXNamespacedName, source_base: uintptr) {
	if n == nil { return }
	rewrite_jsx_identifier(&n.namespace, source_base)
	rewrite_jsx_identifier(&n.name, source_base)
}

// JSXElementName :: union { JSXIdentifier (value), ^JSXMemberExpression,
// ^JSXNamespacedName }. Used by JSXOpeningElement.name and
// JSXClosingElement.name.
rewrite_jsx_element_name :: proc(n: ^JSXElementName, base: uintptr, source_base: uintptr) {
	#partial switch v in n^ {
	case JSXIdentifier:
		rewrite_jsx_identifier((^JSXIdentifier)(n), source_base)
	case ^JSXMemberExpression:
		rewrite_jsx_member_expression(v, base, source_base)
		rewrite_union_ptr(n, base)
	case ^JSXNamespacedName:
		rewrite_jsx_namespaced_name(v, source_base)
		rewrite_union_ptr(n, base)
	}
}

// JSXAttributeName :: union { JSXIdentifier (value), ^JSXNamespacedName }.
rewrite_jsx_attribute_name :: proc(n: ^JSXAttributeName, base: uintptr, source_base: uintptr) {
	#partial switch v in n^ {
	case JSXIdentifier:
		rewrite_jsx_identifier((^JSXIdentifier)(n), source_base)
	case ^JSXNamespacedName:
		rewrite_jsx_namespaced_name(v, source_base)
		rewrite_union_ptr(n, base)
	}
}

// JSXAttributeItem :: union { JSXAttribute (value), ^JSXSpreadAttribute }.
// Stored inline in the [dynamic]JSXAttributeItem array — the union value
// lives directly in the array slot.
rewrite_jsx_attribute_item :: proc(it: ^JSXAttributeItem, base: uintptr, source_base: uintptr) {
	#partial switch v in it^ {
	case JSXAttribute:
		a := (^JSXAttribute)(it)
		rewrite_jsx_attribute_name(&a.name, base, source_base)
		rewrite_maybe_expr(&a.value, base, source_base)
	case ^JSXSpreadAttribute:
		rewrite_expr_field(v.argument, &v.argument, base, source_base)
		rewrite_union_ptr(it, base)
	}
}

rewrite_jsx_attribute_array :: proc(arr: ^[dynamic]JSXAttributeItem, base: uintptr, source_base: uintptr) {
	for i in 0..<len(arr) {
		rewrite_jsx_attribute_item(&arr[i], base, source_base)
	}
	rewrite_dynamic_header(arr, base, len(arr))
}

// JSXChild :: union { ^JSXElement, ^JSXFragment, ^JSXText,
// ^JSXExpressionContainer, ^JSXSpreadChild } — all-pointer variants. Same
// memory shape as Expression / Statement; walk the inner struct, then
// collapse the slot's inner ptr via rewrite_union_ptr.
rewrite_jsx_child :: proc(c: ^JSXChild, base: uintptr, source_base: uintptr) {
	#partial switch v in c^ {
	case ^JSXElement:
		rewrite_jsx_element(v, base, source_base)
		rewrite_union_ptr(c, base)
	case ^JSXFragment:
		rewrite_jsx_fragment(v, base, source_base)
		rewrite_union_ptr(c, base)
	case ^JSXText:
		rewrite_string(&v.value, source_base)
		rewrite_string(&v.raw, source_base)
		rewrite_union_ptr(c, base)
	case ^JSXExpressionContainer:
		rewrite_expr_field(v.expression, &v.expression, base, source_base)
		rewrite_union_ptr(c, base)
	case ^JSXSpreadChild:
		rewrite_expr_field(v.expression, &v.expression, base, source_base)
		rewrite_union_ptr(c, base)
	}
}

rewrite_jsx_child_array :: proc(arr: ^[dynamic]JSXChild, base: uintptr, source_base: uintptr) {
	for i in 0..<len(arr) {
		rewrite_jsx_child(&arr[i], base, source_base)
	}
	rewrite_dynamic_header(arr, base, len(arr))
}

rewrite_jsx_opening_element :: proc(o: ^JSXOpeningElement, base: uintptr, source_base: uintptr) {
	if o == nil { return }
	rewrite_jsx_element_name(&o.name, base, source_base)
	rewrite_jsx_attribute_array(&o.attributes, base, source_base)
}

rewrite_jsx_closing_element :: proc(c: ^JSXClosingElement, base: uintptr, source_base: uintptr) {
	if c == nil { return }
	rewrite_jsx_element_name(&c.name, base, source_base)
}

rewrite_jsx_element :: proc(e: ^JSXElement, base: uintptr, source_base: uintptr) {
	if e == nil { return }
	rewrite_jsx_opening_element(e.opening_element, base, source_base)
	rewrite_ptr((^rawptr)(&e.opening_element), base)
	rewrite_jsx_child_array(&e.children, base, source_base)
	if ce, ok := e.closing_element.?; ok {
		rewrite_jsx_closing_element(ce, base, source_base)
		rewrite_ptr((^rawptr)(&e.closing_element), base)
	}
}

rewrite_jsx_fragment :: proc(f: ^JSXFragment, base: uintptr, source_base: uintptr) {
	if f == nil { return }
	// opening_fragment / closing_fragment are inline value structs holding
	// only `loc` — nothing to rewrite. Walk children only.
	rewrite_jsx_child_array(&f.children, base, source_base)
}

// Walk a [dynamic]Decorator slot. Each Decorator is `{loc, expression: ^Expression}`;
// the expression slot is rewritten via the standard expr-field walker, then the
// outer dynamic-array header is collapsed last (rewriting the header overwrites
// the data ptr, so all element walks must happen first).
rewrite_decorator_array :: proc(arr: ^[dynamic]Decorator, base: uintptr, source_base: uintptr) {
	for i in 0..<len(arr) {
		d := &arr[i]
		rewrite_expr_field(d.expression, &d.expression, base, source_base)
	}
	rewrite_dynamic_header(arr, base, len(arr))
}

rewrite_class_expression :: proc(c: ^ClassExpression, base: uintptr, source_base: uintptr) {
	// Optional class name (`class Foo {}` vs `class {}`). Same fix as
	// FunctionExpression.id — `name` slices into source, must be rewritten.
	rewrite_maybe_binding_id_name(&c.id, source_base)
	rewrite_maybe_ts_type_parameter_declaration(&c.type_parameters, base, source_base)
	rewrite_maybe_expr(&c.super_class, base, source_base)
	// Class-level decorators (`@dec class Foo {}`).
	rewrite_decorator_array(&c.decorators, base, source_base)
	rewrite_ts_interface_heritage_array(&c.implements, base, source_base)
	for i in 0..<len(c.body.body) {
		elem := &c.body.body[i]
		rewrite_expr_field(elem.key, &elem.key, base, source_base)
		rewrite_maybe_expr(&elem.value, base, source_base)
		rewrite_maybe_ts_type_annotation(&elem.type_annotation, base, source_base)
		// Per-element decorators (`@bound method() {}`, `@dec field;`).
		rewrite_decorator_array(&elem.decorators, base, source_base)
	}
	rewrite_dynamic_header(&c.body.body, base, len(c.body.body))
}

rewrite_array_expression :: proc(a: ^ArrayExpression, base: uintptr, source_base: uintptr) {
	for i in 0..<len(a.elements) {
		if elem, ok := a.elements[i].(^Expression); ok {
			rewrite_expression(elem, base, source_base)
			rewrite_union_ptr(elem, base)
			// Rewrite the Maybe slot itself
			rewrite_ptr((^rawptr)(&a.elements[i]), base)
		}
	}
	rewrite_dynamic_header(&a.elements, base, len(a.elements))
}

rewrite_object_expression :: proc(o: ^ObjectExpression, base: uintptr, source_base: uintptr) {
	for i in 0..<len(o.properties) {
		prop := &o.properties[i]
		// Shorthand `{a}` parses with `prop.value = prop.key` — both
		// fields hold the SAME ^Expression union pointer (see
		// parse_property's shorthand branch in src/parser.odin). The
		// previous unconditional double-rewrite walked the SAME union
		// twice; the second pass tried to dereference the already-rewritten
		// inner pointer (now an arena offset, not a real pointer) and
		// segfaulted. Surfaced via S26 W5b walking sucrase.js / d3.js /
		// yup.js / zod.js / and ~25 other batch2/batch3 files. Detect
		// pointer equality BEFORE the first rewrite, then mirror the
		// resulting offset to `prop.value`'s slot.
		same_node := prop.value == prop.key
		rewrite_expr_field(prop.key, &prop.key, base, source_base)
		if same_node {
			(^u32)(&prop.value)^ = (^u32)(&prop.key)^
		} else {
			rewrite_expr_field(prop.value, &prop.value, base, source_base)
		}
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
	if _, ok := d.declaration.(^Declaration); ok {
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

// Build a raw transfer buffer from an ALREADY-PARSED job. Inherits the
// job's lang / source-type / strict / preserve-parens / .d.ts resolution.
produce_raw_buffer_from_job :: proc(job: ^ParseJob) -> RawTransferResult {
	assert(job.opened)
	assert(job.program != nil, "produce_raw_buffer_from_job: parse_job_run must be called first")

	arena := job.arena_ptr
	source := string(job.source.data)

	// Get arena base pointer — all allocations are offsets from here
	base := uintptr(arena.curr_block.base)
	used := int(arena.total_used)

	// Rewrite all pointers to offsets
	rewrite_ast_pointers(job.program, base, source)

	// Build header
	program_offset := ptr_to_offset(base, job.program)
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
		error_count = len(job.parser.errors),
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
