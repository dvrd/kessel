package kessel

// ============================================================================
// N-API addon — direct V8 object construction from the AST.
//
// Build: odin build src -build-mode:shared -out:kessel.node -o:speed -no-bounds-check
// Usage: const { parseSync } = require('./kessel.node');
//
// One walk of the AST, creating V8 objects inline via N-API calls.
// No serialization, no binary buffer, no JS-side decode.
// ============================================================================

import "core:mem"
import "base:runtime"
import mvirtual "core:mem/virtual"
import "core:strings"
import "core:fmt"

// ============================================================================
// N-API type definitions — opaque pointers matching js_native_api_types.h
// ============================================================================

napi_env           :: rawptr
napi_value         :: rawptr
napi_callback_info :: rawptr
napi_status        :: i32
napi_callback      :: proc "c" (env: napi_env, info: napi_callback_info) -> napi_value

NAPI_AUTO_LENGTH :: max(uint)

// ============================================================================
// N-API function imports — resolved at load time from the Node.js host
// ============================================================================

// The N-API addon is Mac-only today. It links against `system:System`
// (the macOS framework whose dynamic-lookup behavior, combined with the
// `-undefined dynamic_lookup` linker flag, lets N-API symbols be
// resolved at load time from the Node.js host process). Windows and
// Linux have no equivalent, and on Windows the bare "system" token
// leaks into link.exe args as `system.obj` (LNK1181). The koffi FFI
// path in lib_exports.odin is the cross-platform shipping binding;
// this file is an alternative experimental interface.
when ODIN_BUILD_MODE == .Dynamic && ODIN_OS == .Darwin {

foreign import napi_host "system:System"

@(default_calling_convention="c")
foreign napi_host {
	napi_create_object          :: proc(env: napi_env, result: ^napi_value) -> napi_status ---
	napi_create_array_with_length :: proc(env: napi_env, length: uint, result: ^napi_value) -> napi_status ---
	napi_set_named_property     :: proc(env: napi_env, object: napi_value, utf8name: cstring, value: napi_value) -> napi_status ---
	napi_set_element            :: proc(env: napi_env, object: napi_value, index: u32, value: napi_value) -> napi_status ---
	napi_create_string_utf8     :: proc(env: napi_env, str: [^]u8, length: uint, result: ^napi_value) -> napi_status ---
	napi_create_double          :: proc(env: napi_env, value: f64, result: ^napi_value) -> napi_status ---
	napi_create_uint32          :: proc(env: napi_env, value: u32, result: ^napi_value) -> napi_status ---
	napi_create_int32           :: proc(env: napi_env, value: i32, result: ^napi_value) -> napi_status ---
	napi_get_null               :: proc(env: napi_env, result: ^napi_value) -> napi_status ---
	napi_get_boolean            :: proc(env: napi_env, value: bool, result: ^napi_value) -> napi_status ---
	napi_get_undefined          :: proc(env: napi_env, result: ^napi_value) -> napi_status ---
	napi_create_function        :: proc(env: napi_env, utf8name: cstring, length: uint, cb: napi_callback, data: rawptr, result: ^napi_value) -> napi_status ---
	napi_get_cb_info            :: proc(env: napi_env, cbinfo: napi_callback_info, argc: ^uint, argv: [^]napi_value, this_arg: ^napi_value, data: ^rawptr) -> napi_status ---
	napi_get_value_string_utf8  :: proc(env: napi_env, value: napi_value, buf: [^]u8, bufsize: uint, result: ^uint) -> napi_status ---
	napi_typeof                 :: proc(env: napi_env, value: napi_value, result: ^i32) -> napi_status ---
	napi_throw_error            :: proc(env: napi_env, code: cstring, msg: cstring) -> napi_status ---
}

// ============================================================================
// N-API helpers — thin wrappers for common patterns
// ============================================================================

NapiCtx :: struct {
	env:          napi_env,
	null_val:     napi_value,
	true_val:     napi_value,
	false_val:    napi_value,
	undef_val:    napi_value,
	// Pre-interned property name strings (avoid repeated napi_create_string
	// for "type", "start", "end" which appear on every node)
	str_type:     napi_value,
	str_start:    napi_value,
	str_end:      napi_value,
}

napi_init_ctx :: proc "c" (env: napi_env) -> NapiCtx {
	ctx: NapiCtx
	ctx.env = env
	napi_get_null(env, &ctx.null_val)
	napi_get_boolean(env, true, &ctx.true_val)
	napi_get_boolean(env, false, &ctx.false_val)
	napi_get_undefined(env, &ctx.undef_val)
	return ctx
}

@(private="file")
napi_str :: #force_inline proc "contextless" (env: napi_env, s: string) -> napi_value {
	v: napi_value
	if len(s) == 0 {
		napi_create_string_utf8(env, nil, 0, &v)
	} else {
		napi_create_string_utf8(env, raw_data(s), uint(len(s)), &v)
	}
	return v
}

@(private="file")
napi_cstr :: #force_inline proc "contextless" (env: napi_env, s: cstring) -> napi_value {
	v: napi_value
	napi_create_string_utf8(env, cast([^]u8)s, NAPI_AUTO_LENGTH, &v)
	return v
}

@(private="file")
napi_u32 :: #force_inline proc "contextless" (env: napi_env, n: u32) -> napi_value {
	v: napi_value
	napi_create_uint32(env, n, &v)
	return v
}

@(private="file")
napi_f64 :: #force_inline proc "contextless" (env: napi_env, n: f64) -> napi_value {
	v: napi_value
	napi_create_double(env, n, &v)
	return v
}

@(private="file")
napi_bool :: #force_inline proc "contextless" (ctx: ^NapiCtx, b: bool) -> napi_value {
	return ctx.true_val if b else ctx.false_val
}

@(private="file")
napi_obj :: #force_inline proc "contextless" (env: napi_env) -> napi_value {
	v: napi_value
	napi_create_object(env, &v)
	return v
}

@(private="file")
napi_arr :: #force_inline proc "contextless" (env: napi_env, len: uint) -> napi_value {
	v: napi_value
	napi_create_array_with_length(env, len, &v)
	return v
}

@(private="file")
set :: #force_inline proc "contextless" (env: napi_env, obj: napi_value, key: cstring, val: napi_value) {
	napi_set_named_property(env, obj, key, val)
}

// Set "type", "start", "end" on a node object — the three fields every node has.
@(private="file")
set_node_base :: #force_inline proc "contextless" (env: napi_env, obj: napi_value, type_name: cstring, loc: Loc) {
	set(env, obj, "type", napi_cstr(env, type_name))
	set(env, obj, "start", napi_u32(env, loc.start))
	set(env, obj, "end", napi_u32(env, loc.end))
}

// ============================================================================
// AST → V8 object walk
// ============================================================================

napi_emit_program :: proc "contextless" (ctx: ^NapiCtx, program: ^Program) -> napi_value {
	env := ctx.env
	obj := napi_obj(env)
	set_node_base(env, obj, "Program", program.loc)
	set(env, obj, "sourceType", napi_cstr(env, "module" if program.type == .Module else "script"))

	// body
	body := napi_arr(env, uint(len(program.body)))
	for stmt, i in program.body {
		napi_set_element(env, body, u32(i), napi_emit_statement(ctx, stmt))
	}
	set(env, obj, "body", body)
	return obj
}

napi_emit_statement :: proc "contextless" (ctx: ^NapiCtx, stmt: ^Statement) -> napi_value {
	if stmt == nil { return ctx.null_val }
	env := ctx.env

	#partial switch s in stmt^ {
	case ^ExpressionStatement:
		if s == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "ExpressionStatement", s.loc)
		set(env, obj, "expression", napi_emit_expression(ctx, s.expression))
		return obj
	case ^BlockStatement:
		if s == nil { return ctx.null_val }
		return napi_emit_block(ctx, s)
	case ^EmptyStatement:
		if s == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "EmptyStatement", s.loc)
		return obj
	case ^DebuggerStatement:
		if s == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "DebuggerStatement", s.loc)
		return obj
	case ^ReturnStatement:
		if s == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "ReturnStatement", s.loc)
		if arg, ok := s.argument.?; ok && arg != nil {
			set(env, obj, "argument", napi_emit_expression(ctx, arg))
		} else {
			set(env, obj, "argument", ctx.null_val)
		}
		return obj
	case ^IfStatement:
		if s == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "IfStatement", s.loc)
		set(env, obj, "test", napi_emit_expression(ctx, s.test))
		set(env, obj, "consequent", napi_emit_statement(ctx, s.consequent))
		if alt, ok := s.alternate.?; ok && alt != nil {
			set(env, obj, "alternate", napi_emit_statement(ctx, alt))
		} else {
			set(env, obj, "alternate", ctx.null_val)
		}
		return obj
	case ^WhileStatement:
		if s == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "WhileStatement", s.loc)
		set(env, obj, "test", napi_emit_expression(ctx, s.test))
		set(env, obj, "body", napi_emit_statement(ctx, s.body))
		return obj
	case ^DoWhileStatement:
		if s == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "DoWhileStatement", s.loc)
		set(env, obj, "test", napi_emit_expression(ctx, s.test))
		set(env, obj, "body", napi_emit_statement(ctx, s.body))
		return obj
	case ^ForStatement:
		if s == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "ForStatement", s.loc)
		if d, ok := s.init_decl.?; ok && d != nil {
			set(env, obj, "init", napi_emit_var_decl(ctx, d))
		} else if e, ok := s.init_expr.?; ok && e != nil {
			set(env, obj, "init", napi_emit_expression(ctx, e))
		} else {
			set(env, obj, "init", ctx.null_val)
		}
		if t, ok := s.test.?; ok && t != nil {
			set(env, obj, "test", napi_emit_expression(ctx, t))
		} else {
			set(env, obj, "test", ctx.null_val)
		}
		if u, ok := s.update.?; ok && u != nil {
			set(env, obj, "update", napi_emit_expression(ctx, u))
		} else {
			set(env, obj, "update", ctx.null_val)
		}
		set(env, obj, "body", napi_emit_statement(ctx, s.body))
		return obj
	case ^ForInStatement:
		if s == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "ForInStatement", s.loc)
		if d, ok := s.left_decl.?; ok && d != nil {
			set(env, obj, "left", napi_emit_var_decl(ctx, d))
		} else if e, ok := s.left_expr.?; ok && e != nil {
			set(env, obj, "left", napi_emit_expression(ctx, e))
		} else {
			set(env, obj, "left", ctx.null_val)
		}
		set(env, obj, "right", napi_emit_expression(ctx, s.right))
		set(env, obj, "body", napi_emit_statement(ctx, s.body))
		return obj
	case ^ForOfStatement:
		if s == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "ForOfStatement", s.loc)
		set(env, obj, "await", napi_bool(ctx, s.await))
		if d, ok := s.left_decl.?; ok && d != nil {
			set(env, obj, "left", napi_emit_var_decl(ctx, d))
		} else if e, ok := s.left_expr.?; ok && e != nil {
			set(env, obj, "left", napi_emit_expression(ctx, e))
		} else {
			set(env, obj, "left", ctx.null_val)
		}
		set(env, obj, "right", napi_emit_expression(ctx, s.right))
		set(env, obj, "body", napi_emit_statement(ctx, s.body))
		return obj
	case ^ThrowStatement:
		if s == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "ThrowStatement", s.loc)
		set(env, obj, "argument", napi_emit_expression(ctx, s.argument))
		return obj
	case ^TryStatement:
		if s == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "TryStatement", s.loc)
		set(env, obj, "block", napi_emit_block_stmt(ctx, s.block))
		if handler, ok := s.handler.?; ok {
			h := napi_obj(env)
			set_node_base(env, h, "CatchClause", handler.loc)
			if param, pok := handler.param.?; pok {
				set(env, h, "param", napi_emit_pattern(ctx, param))
			} else {
				set(env, h, "param", ctx.null_val)
			}
			set(env, h, "body", napi_emit_block_stmt(ctx, handler.body))
			set(env, obj, "handler", h)
		} else {
			set(env, obj, "handler", ctx.null_val)
		}
		if fin, ok := s.finalizer.?; ok {
			set(env, obj, "finalizer", napi_emit_block_stmt(ctx, fin))
		} else {
			set(env, obj, "finalizer", ctx.null_val)
		}
		return obj
	case ^SwitchStatement:
		if s == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "SwitchStatement", s.loc)
		set(env, obj, "discriminant", napi_emit_expression(ctx, s.discriminant))
		cases := napi_arr(env, uint(len(s.cases)))
		for c, i in s.cases {
			co := napi_obj(env)
			set_node_base(env, co, "SwitchCase", c.loc)
			if t, ok := c.test.?; ok && t != nil {
				set(env, co, "test", napi_emit_expression(ctx, t))
			} else {
				set(env, co, "test", ctx.null_val)
			}
			cons := napi_arr(env, uint(len(c.consequent)))
			for cs, j in c.consequent { napi_set_element(env, cons, u32(j), napi_emit_statement(ctx, cs)) }
			set(env, co, "consequent", cons)
			napi_set_element(env, cases, u32(i), co)
		}
		set(env, obj, "cases", cases)
		return obj
	case ^LabeledStatement:
		if s == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "LabeledStatement", s.loc)
		label := napi_obj(env)
		set_node_base(env, label, "Identifier", s.label.loc)
		set(env, label, "name", napi_str(env, s.label.name))
		set(env, obj, "label", label)
		set(env, obj, "body", napi_emit_statement(ctx, s.body))
		return obj
	case ^BreakStatement:
		if s == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "BreakStatement", s.loc)
		if label, ok := s.label.(LabelIdentifier); ok {
			l := napi_obj(env)
			set_node_base(env, l, "Identifier", label.loc)
			set(env, l, "name", napi_str(env, label.name))
			set(env, obj, "label", l)
		} else {
			set(env, obj, "label", ctx.null_val)
		}
		return obj
	case ^ContinueStatement:
		if s == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "ContinueStatement", s.loc)
		if label, ok := s.label.(LabelIdentifier); ok {
			l := napi_obj(env)
			set_node_base(env, l, "Identifier", label.loc)
			set(env, l, "name", napi_str(env, label.name))
			set(env, obj, "label", l)
		} else {
			set(env, obj, "label", ctx.null_val)
		}
		return obj
	case ^WithStatement:
		if s == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "WithStatement", s.loc)
		set(env, obj, "object", napi_emit_expression(ctx, s.object))
		set(env, obj, "body", napi_emit_statement(ctx, s.body))
		return obj
	case ^VariableDeclaration:
		if s == nil { return ctx.null_val }
		return napi_emit_var_decl(ctx, s)
	case ^FunctionDeclaration:
		if s == nil { return ctx.null_val }
		return napi_emit_function(ctx, "FunctionDeclaration", s)
	case ^ClassDeclaration:
		if s == nil { return ctx.null_val }
		return napi_emit_class(ctx, "ClassDeclaration", s)
	case ^ImportDeclaration:
		if s == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "ImportDeclaration", s.loc)
		specs := napi_arr(env, uint(len(s.specifiers)))
		for spec, i in s.specifiers {
			if spec == nil { napi_set_element(env, specs, u32(i), ctx.null_val); continue }
			switch ss in spec^ {
			case ImportSpecifier:
				so := napi_obj(env)
				set_node_base(env, so, "ImportSpecifier", ss.loc)
				imp := napi_obj(env)
				set_node_base(env, imp, "Identifier", ss.imported.loc)
				set(env, imp, "name", napi_str(env, ss.imported.name))
				set(env, so, "imported", imp)
				loc := napi_obj(env)
				set_node_base(env, loc, "Identifier", ss.local.loc)
				set(env, loc, "name", napi_str(env, ss.local.name))
				set(env, so, "local", loc)
				napi_set_element(env, specs, u32(i), so)
			case ImportDefaultSpecifier:
				so := napi_obj(env)
				set_node_base(env, so, "ImportDefaultSpecifier", ss.loc)
				loc := napi_obj(env)
				set_node_base(env, loc, "Identifier", ss.local.loc)
				set(env, loc, "name", napi_str(env, ss.local.name))
				set(env, so, "local", loc)
				napi_set_element(env, specs, u32(i), so)
			case ImportNamespaceSpecifier:
				so := napi_obj(env)
				set_node_base(env, so, "ImportNamespaceSpecifier", ss.loc)
				loc := napi_obj(env)
				set_node_base(env, loc, "Identifier", ss.local.loc)
				set(env, loc, "name", napi_str(env, ss.local.name))
				set(env, so, "local", loc)
				napi_set_element(env, specs, u32(i), so)
			}
		}
		set(env, obj, "specifiers", specs)
		src := napi_obj(env)
		set_node_base(env, src, "Literal", s.source.loc)
		set(env, src, "value", napi_str(env, s.source.value))
		set(env, obj, "source", src)
		return obj
	case ^ExportNamedDeclaration:
		if s == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "ExportNamedDeclaration", s.loc)
		if decl, ok := s.declaration.?; ok && decl != nil {
			set(env, obj, "declaration", napi_emit_declaration(ctx, decl))
		} else {
			set(env, obj, "declaration", ctx.null_val)
		}
		specs := napi_arr(env, uint(len(s.specifiers)))
		set(env, obj, "specifiers", specs)
		if src_lit, ok := s.source.?; ok {
			set(env, obj, "source", napi_str(env, src_lit.value))
		} else {
			set(env, obj, "source", ctx.null_val)
		}
		return obj
	case ^ExportDefaultDeclaration:
		if s == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "ExportDefaultDeclaration", s.loc)
		if s.declaration != nil {
			switch d in s.declaration^ {
			case ^Declaration: set(env, obj, "declaration", napi_emit_declaration(ctx, d))
			case ^Expression:  set(env, obj, "declaration", napi_emit_expression(ctx, d))
			}
		} else {
			set(env, obj, "declaration", ctx.null_val)
		}
		return obj
	case ^ExportAllDeclaration:
		if s == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "ExportAllDeclaration", s.loc)
		set(env, obj, "source", napi_str(env, s.source.value))
		if exported, ok := s.exported.?; ok {
			set(env, obj, "exported", napi_str(env, exported.name))
		} else {
			set(env, obj, "exported", ctx.null_val)
		}
		return obj
	}
	return ctx.null_val
}

napi_emit_expression :: proc "contextless" (ctx: ^NapiCtx, expr: ^Expression) -> napi_value {
	if expr == nil { return ctx.null_val }
	env := ctx.env

	#partial switch e in expr^ {
	case ^Identifier:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "Identifier", e.loc)
		set(env, obj, "name", napi_str(env, e.name))
		return obj
	case ^NullLiteral:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "Literal", e.loc)
		set(env, obj, "value", ctx.null_val)
		return obj
	case ^BooleanLiteral:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "Literal", e.loc)
		set(env, obj, "value", napi_bool(ctx, e.value))
		return obj
	case ^NumericLiteral:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "Literal", e.loc)
		set(env, obj, "value", napi_f64(env, e.value))
		set(env, obj, "raw", napi_str(env, e.raw))
		return obj
	case ^StringLiteral:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "Literal", e.loc)
		set(env, obj, "value", napi_str(env, e.value))
		set(env, obj, "raw", napi_str(env, e.raw))
		return obj
	case ^ThisExpression:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "ThisExpression", e.loc)
		return obj
	case ^ArrayExpression:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "ArrayExpression", e.loc)
		elems := napi_arr(env, uint(len(e.elements)))
		for elem, i in e.elements {
			if c, ok := elem.?; ok && c != nil {
				napi_set_element(env, elems, u32(i), napi_emit_expression(ctx, c))
			} else {
				napi_set_element(env, elems, u32(i), ctx.null_val)
			}
		}
		set(env, obj, "elements", elems)
		return obj
	case ^ObjectExpression:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "ObjectExpression", e.loc)
		props := napi_arr(env, uint(len(e.properties)))
		for prop, i in e.properties {
			napi_set_element(env, props, u32(i), napi_emit_property(ctx, prop))
		}
		set(env, obj, "properties", props)
		return obj
	case ^MemberExpression:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "MemberExpression", e.loc)
		set(env, obj, "computed", napi_bool(ctx, e.computed))
		set(env, obj, "optional", napi_bool(ctx, e.optional))
		set(env, obj, "object", napi_emit_expression(ctx, e.object))
		set(env, obj, "property", napi_emit_expression(ctx, e.property))
		return obj
	case ^CallExpression:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "CallExpression", e.loc)
		set(env, obj, "optional", napi_bool(ctx, e.optional))
		set(env, obj, "callee", napi_emit_expression(ctx, e.callee))
		args := napi_arr(env, uint(len(e.arguments)))
		for arg, i in e.arguments { napi_set_element(env, args, u32(i), napi_emit_expression(ctx, arg)) }
		set(env, obj, "arguments", args)
		return obj
	case ^NewExpression:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "NewExpression", e.loc)
		set(env, obj, "callee", napi_emit_expression(ctx, e.callee))
		args := napi_arr(env, uint(len(e.arguments)))
		for arg, i in e.arguments { napi_set_element(env, args, u32(i), napi_emit_expression(ctx, arg)) }
		set(env, obj, "arguments", args)
		return obj
	case ^BinaryExpression:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "BinaryExpression", e.loc)
		bin_ops := [BinaryOperator]string{
			.Add="+", .Sub="-", .Mul="*", .Div="/", .Mod="%", .Pow="**",
			.BitOr="|", .BitXor="^", .BitAnd="&",
			.ShiftLeft="<<", .ShiftRight=">>", .ShiftRightUnsigned=">>>",
			.Eq="==", .NotEq="!=", .StrictEq="===", .StrictNotEq="!==",
			.Lt="<", .Gt=">", .LtEq="<=", .GtEq=">=",
			.Instanceof="instanceof", .In="in",
		}
		set(env, obj, "operator", napi_str(env, bin_ops[e.operator]))
		set(env, obj, "left", napi_emit_expression(ctx, e.left))
		set(env, obj, "right", napi_emit_expression(ctx, e.right))
		return obj
	case ^LogicalExpression:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "LogicalExpression", e.loc)
		op: string
		#partial switch e.operator {
		case .And: op = "&&"
		case .Or:  op = "||"
		case .NullishCoalescing: op = "??"
		}
		set(env, obj, "operator", napi_str(env, op))
		set(env, obj, "left", napi_emit_expression(ctx, e.left))
		set(env, obj, "right", napi_emit_expression(ctx, e.right))
		return obj
	case ^AssignmentExpression:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "AssignmentExpression", e.loc)
		asgn_ops := [AssignmentOperator]string{
			.Assign="=", .AddAssign="+=", .SubAssign="-=", .MulAssign="*=",
			.DivAssign="/=", .ModAssign="%=", .PowAssign="**=",
			.ShiftLeftAssign="<<=", .ShiftRightAssign=">>=", .ShiftRightUAssign=">>>=",
			.BitAndAssign="&=", .BitOrAssign="|=", .BitXorAssign="^=",
			.AssignLogicalAnd="&&=", .AssignLogicalOr="||=", .AssignNullish="??=",
		}
		set(env, obj, "operator", napi_str(env, asgn_ops[e.operator]))
		set(env, obj, "left", napi_emit_expression(ctx, e.left))
		set(env, obj, "right", napi_emit_expression(ctx, e.right))
		return obj
	case ^UnaryExpression:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "UnaryExpression", e.loc)
		unary_ops := [UnaryOperator]string{
			.Minus="-", .Plus="+", .LogicalNot="!", .BitwiseNot="~",
			.Typeof="typeof", .Void="void", .Delete="delete",
		}
		set(env, obj, "operator", napi_str(env, unary_ops[e.operator]))
		set(env, obj, "prefix", napi_bool(ctx, e.prefix))
		set(env, obj, "argument", napi_emit_expression(ctx, e.argument))
		return obj
	case ^UpdateExpression:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "UpdateExpression", e.loc)
		op: string
		switch e.operator {
		case .Increment: op = "++"
		case .Decrement: op = "--"
		}
		set(env, obj, "operator", napi_str(env, op))
		set(env, obj, "prefix", napi_bool(ctx, e.prefix))
		set(env, obj, "argument", napi_emit_expression(ctx, e.argument))
		return obj
	case ^ConditionalExpression:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "ConditionalExpression", e.loc)
		set(env, obj, "test", napi_emit_expression(ctx, e.test))
		set(env, obj, "consequent", napi_emit_expression(ctx, e.consequent))
		set(env, obj, "alternate", napi_emit_expression(ctx, e.alternate))
		return obj
	case ^SpreadElement:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "SpreadElement", e.loc)
		set(env, obj, "argument", napi_emit_expression(ctx, e.argument))
		return obj
	case ^FunctionExpression:
		if e == nil { return ctx.null_val }
		return napi_emit_function(ctx, "FunctionExpression", e)
	case ^ArrowFunctionExpression:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "ArrowFunctionExpression", e.loc)
		set(env, obj, "async", napi_bool(ctx, e.async))
		set(env, obj, "expression", napi_bool(ctx, e.expression))
		params := napi_arr(env, uint(len(e.params)))
		for p, i in e.params { napi_set_element(env, params, u32(i), napi_emit_pattern(ctx, p.pattern)) }
		set(env, obj, "params", params)
		switch b in e.body {
		case ^Expression:    set(env, obj, "body", napi_emit_expression(ctx, b))
		case ^BlockStatement: if b != nil { set(env, obj, "body", napi_emit_block(ctx, b)) } else { set(env, obj, "body", ctx.null_val) }
		}
		return obj
	case ^ClassExpression:
		if e == nil { return ctx.null_val }
		return napi_emit_class(ctx, "ClassExpression", e)
	case ^SequenceExpression:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "SequenceExpression", e.loc)
		exprs := napi_arr(env, uint(len(e.expressions)))
		for ex, i in e.expressions { napi_set_element(env, exprs, u32(i), napi_emit_expression(ctx, ex)) }
		set(env, obj, "expressions", exprs)
		return obj
	case ^YieldExpression:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "YieldExpression", e.loc)
		set(env, obj, "delegate", napi_bool(ctx, e.delegate))
		if arg, ok := e.argument.?; ok && arg != nil {
			set(env, obj, "argument", napi_emit_expression(ctx, arg))
		} else {
			set(env, obj, "argument", ctx.null_val)
		}
		return obj
	case ^AwaitExpression:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "AwaitExpression", e.loc)
		set(env, obj, "argument", napi_emit_expression(ctx, e.argument))
		return obj
	case ^TemplateLiteral:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "TemplateLiteral", e.loc)
		quasis := napi_arr(env, uint(len(e.quasis)))
		for q, i in e.quasis {
			qo := napi_obj(env)
			set_node_base(env, qo, "TemplateElement", q.loc)
			set(env, qo, "tail", napi_bool(ctx, q.tail))
			val := napi_obj(env)
			set(env, val, "raw", napi_str(env, q.raw))
			if cooked, ok := q.cooked.?; ok {
				set(env, val, "cooked", napi_str(env, cooked))
			} else {
				set(env, val, "cooked", ctx.null_val)
			}
			set(env, qo, "value", val)
			napi_set_element(env, quasis, u32(i), qo)
		}
		set(env, obj, "quasis", quasis)
		exprs := napi_arr(env, uint(len(e.expressions)))
		for ex, i in e.expressions { napi_set_element(env, exprs, u32(i), napi_emit_expression(ctx, ex)) }
		set(env, obj, "expressions", exprs)
		return obj
	case ^ChainExpression:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "ChainExpression", e.loc)
		set(env, obj, "expression", napi_emit_expression(ctx, e.expression))
		return obj
	case ^ImportExpression:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "ImportExpression", e.loc)
		set(env, obj, "source", napi_emit_expression(ctx, e.source))
		return obj
	case ^MetaProperty:
		if e == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "MetaProperty", e.loc)
		meta := napi_obj(env)
		set_node_base(env, meta, "Identifier", e.meta.loc)
		set(env, meta, "name", napi_str(env, e.meta.name))
		set(env, obj, "meta", meta)
		prop := napi_obj(env)
		set_node_base(env, prop, "Identifier", e.property.loc)
		set(env, prop, "name", napi_str(env, e.property.name))
		set(env, obj, "property", prop)
		return obj
	}
	return ctx.null_val
}

// ============================================================================
// Helpers
// ============================================================================

@(private="file")
napi_emit_block :: proc "contextless" (ctx: ^NapiCtx, block: ^BlockStatement) -> napi_value {
	env := ctx.env
	obj := napi_obj(env)
	set_node_base(env, obj, "BlockStatement", block.loc)
	body := napi_arr(env, uint(len(block.body)))
	for s, i in block.body { napi_set_element(env, body, u32(i), napi_emit_statement(ctx, s)) }
	set(env, obj, "body", body)
	return obj
}

@(private="file")
napi_emit_block_stmt :: proc "contextless" (ctx: ^NapiCtx, block: BlockStatement) -> napi_value {
	env := ctx.env
	obj := napi_obj(env)
	set_node_base(env, obj, "BlockStatement", block.loc)
	body := napi_arr(env, uint(len(block.body)))
	for s, i in block.body { napi_set_element(env, body, u32(i), napi_emit_statement(ctx, s)) }
	set(env, obj, "body", body)
	return obj
}

@(private="file")
napi_emit_var_decl :: proc "contextless" (ctx: ^NapiCtx, s: ^VariableDeclaration) -> napi_value {
	env := ctx.env
	obj := napi_obj(env)
	set_node_base(env, obj, "VariableDeclaration", s.loc)
	var_kinds := [?]cstring{"var", "let", "const", "using", "await using"}
	set(env, obj, "kind", napi_cstr(env, var_kinds[s.kind]))
	decls := napi_arr(env, uint(len(s.declarations)))
	for d, i in s.declarations {
		decl_obj := napi_obj(env)
		set_node_base(env, decl_obj, "VariableDeclarator", d.loc)
		set(env, decl_obj, "id", napi_emit_pattern(ctx, d.id))
		if init, ok := d.init.(^Expression); ok && init != nil {
			set(env, decl_obj, "init", napi_emit_expression(ctx, init))
		} else {
			set(env, decl_obj, "init", ctx.null_val)
		}
		napi_set_element(env, decls, u32(i), decl_obj)
	}
	set(env, obj, "declarations", decls)
	return obj
}

@(private="file")
napi_emit_function :: proc "contextless" (ctx: ^NapiCtx, type_name: cstring, fn: ^FunctionExpression) -> napi_value {
	env := ctx.env
	obj := napi_obj(env)
	set_node_base(env, obj, type_name, fn.loc)
	if bid, ok := fn.id.(BindingIdentifier); ok {
		id := napi_obj(env)
		set_node_base(env, id, "Identifier", bid.loc)
		set(env, id, "name", napi_str(env, bid.name))
		set(env, obj, "id", id)
	} else {
		set(env, obj, "id", ctx.null_val)
	}
	set(env, obj, "async", napi_bool(ctx, fn.async))
	set(env, obj, "generator", napi_bool(ctx, fn.generator))
	params := napi_arr(env, uint(len(fn.params)))
	for p, i in fn.params { napi_set_element(env, params, u32(i), napi_emit_pattern(ctx, p.pattern)) }
	set(env, obj, "params", params)
	body_obj := napi_obj(env)
	set_node_base(env, body_obj, "BlockStatement", fn.body.loc)
	body := napi_arr(env, uint(len(fn.body.body)))
	for s, i in fn.body.body { napi_set_element(env, body, u32(i), napi_emit_statement(ctx, s)) }
	set(env, body_obj, "body", body)
	set(env, obj, "body", body_obj)
	return obj
}

@(private="file")
napi_emit_class :: proc "contextless" (ctx: ^NapiCtx, type_name: cstring, class: ^$T) -> napi_value {
	env := ctx.env
	obj := napi_obj(env)
	set_node_base(env, obj, type_name, class.loc)
	if bid, ok := class.id.(BindingIdentifier); ok {
		id := napi_obj(env)
		set_node_base(env, id, "Identifier", bid.loc)
		set(env, id, "name", napi_str(env, bid.name))
		set(env, obj, "id", id)
	} else {
		set(env, obj, "id", ctx.null_val)
	}
	if sc, ok := class.super_class.?; ok && sc != nil {
		set(env, obj, "superClass", napi_emit_expression(ctx, sc))
	} else {
		set(env, obj, "superClass", ctx.null_val)
	}
	cb := napi_obj(env)
	set_node_base(env, cb, "ClassBody", class.body.loc)
	elems := napi_arr(env, uint(len(class.body.body)))
	set(env, cb, "body", elems)
	set(env, obj, "body", cb)
	return obj
}

@(private="file")
napi_emit_property :: proc "contextless" (ctx: ^NapiCtx, prop: Property) -> napi_value {
	env := ctx.env
	obj := napi_obj(env)
	set_node_base(env, obj, "Property", prop.loc)
	prop_kinds := [?]cstring{"init", "get", "set"}
	set(env, obj, "kind", napi_cstr(env, prop_kinds[prop.kind]))
	set(env, obj, "computed", napi_bool(ctx, prop.computed))
	set(env, obj, "shorthand", napi_bool(ctx, prop.shorthand))
	set(env, obj, "key", napi_emit_expression(ctx, prop.key))
	set(env, obj, "value", napi_emit_expression(ctx, prop.value))
	return obj
}

@(private="file")
napi_emit_declaration :: proc "contextless" (ctx: ^NapiCtx, decl: ^Declaration) -> napi_value {
	if decl == nil { return ctx.null_val }
	#partial switch d in decl^ {
	case ^FunctionDeclaration: return napi_emit_function(ctx, "FunctionDeclaration", d)
	case ^VariableDeclaration: return napi_emit_var_decl(ctx, d)
	case ^ClassDeclaration:    return napi_emit_class(ctx, "ClassDeclaration", d)
	}
	return ctx.null_val
}

napi_emit_pattern :: proc "contextless" (ctx: ^NapiCtx, pat: Pattern) -> napi_value {
	env := ctx.env
	#partial switch p in pat {
	case ^Identifier:
		if p == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "Identifier", p.loc)
		set(env, obj, "name", napi_str(env, p.name))
		return obj
	case ^ObjectPattern:
		if p == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "ObjectPattern", p.loc)
		props := napi_arr(env, uint(len(p.properties)))
		set(env, obj, "properties", props)
		return obj
	case ^ArrayPattern:
		if p == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "ArrayPattern", p.loc)
		elems := napi_arr(env, uint(len(p.elements)))
		for elem, i in p.elements {
			if e, ok := elem.?; ok {
				napi_set_element(env, elems, u32(i), napi_emit_pattern(ctx, e))
			} else {
				napi_set_element(env, elems, u32(i), ctx.null_val)
			}
		}
		set(env, obj, "elements", elems)
		return obj
	case ^AssignmentPattern:
		if p == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "AssignmentPattern", p.loc)
		set(env, obj, "left", napi_emit_pattern(ctx, p.left))
		set(env, obj, "right", napi_emit_expression(ctx, p.right))
		return obj
	case ^RestElement:
		if p == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "RestElement", p.loc)
		set(env, obj, "argument", napi_emit_pattern(ctx, p.argument))
		return obj
	case ^MemberExpression:
		if p == nil { return ctx.null_val }
		obj := napi_obj(env)
		set_node_base(env, obj, "MemberExpression", p.loc)
		set(env, obj, "computed", napi_bool(ctx, p.computed))
		set(env, obj, "object", napi_emit_expression(ctx, p.object))
		set(env, obj, "property", napi_emit_expression(ctx, p.property))
		return obj
	}
	return ctx.null_val
}

// ============================================================================
// N-API addon entry point — parseSync(filename, source)
// ============================================================================

@(export, link_name="napi_parse_sync")
napi_parse_sync :: proc "c" (env: napi_env, info: napi_callback_info) -> napi_value {
	context = runtime.default_context()

	// Get arguments: parseSync(filename, source)
	argc: uint = 2
	argv: [2]napi_value
	napi_get_cb_info(env, info, &argc, raw_data(argv[:]), nil, nil)

	if argc < 2 {
		napi_throw_error(env, nil, "parseSync requires (filename, source)")
		return nil
	}

	fname_buf: [512]u8
	fname_len: uint
	napi_get_value_string_utf8(env, argv[0], raw_data(fname_buf[:]), 512, &fname_len)
	filename := string(fname_buf[:fname_len])

	src_len: uint
	napi_get_value_string_utf8(env, argv[1], nil, 0, &src_len)

	// Allocate and read source
	src_buf := make([]u8, src_len + 1)
	defer delete(src_buf)
	napi_get_value_string_utf8(env, argv[1], raw_data(src_buf), src_len + 1, &src_len)
	source := string(src_buf[:src_len])

	lang := Lang.JS
	if strings.has_suffix(filename, ".tsx") { lang = .TSX }
	else if strings.has_suffix(filename, ".ts") || strings.has_suffix(filename, ".mts") || strings.has_suffix(filename, ".cts") { lang = .TS }
	else if strings.has_suffix(filename, ".jsx") { lang = .JSX }

	config := ParseConfig{ lang_override = lang, ast_only = true }
	job: ParseJob
	if !parse_job_open_inline(&job, source, config, "napi") {
		napi_throw_error(env, nil, "Failed to open parse job")
		return nil
	}
	defer parse_job_close(&job)
	parse_job_run(&job)

	ctx := napi_init_ctx(env)
	program := napi_emit_program(&ctx, job.program)

	result := napi_obj(env)
	set(env, result, "program", program)
	errors := napi_arr(env, 0)
	set(env, result, "errors", errors)
	return result
}

// Module init — called by Node.js when require('./kessel.node') is invoked.
@(export, link_name="napi_register_module_v1")
napi_register_module_v1 :: proc "c" (env: napi_env, exports: napi_value) -> napi_value {
	fn: napi_value
	napi_create_function(env, "parseSync", NAPI_AUTO_LENGTH, napi_parse_sync, nil, &fn)
	napi_set_named_property(env, exports, "parseSync", fn)
	return exports
}

} // when ODIN_BUILD_MODE == .Dynamic && ODIN_OS == .Darwin
