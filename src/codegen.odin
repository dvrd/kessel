package kessel

// ============================================================================
// Codegen — AST -> JavaScript/TypeScript source text emitter.
// ============================================================================
//
// Dual of `emitter.odin`: same node-kind switch, but the output is JS source
// text rather than ESTree JSON. The Codegen struct mirrors the Emitter's
// writer-buffer pattern so the two emitters share an aesthetic and can be
// reasoned about side-by-side.
//
// Output mode: minified=false (default) produces a readable pretty form with
// indentation and newlines; minified=true produces a compact single-line
// form suitable for piping to a minifier. The pretty form is NOT a
// formatter — it doesn't try to match the input's whitespace or comment
// layout. That belongs to a separate formatter pass.
//
// Operator precedence: every `gen_expression*` call carries a parent
// precedence; the child emits its own parentheses when its precedence is
// strictly lower than the parent's. This is the conventional Pratt-style
// reverse of parsing.
//
// Coverage: every Statement / Expression / Pattern / TS / JSX variant the
// parser can produce. Unknown / unhandled variants fall through to a
// `<unknown>` token so a bug in codegen never produces silently-wrong
// JavaScript — the output stays syntactically distinguishable.

import "core:fmt"
import "core:mem"
import "core:strings"

// ----------------------------------------------------------------------------
// Codegen state
// ----------------------------------------------------------------------------

CodegenConfig :: struct {
	fold_constants, join_declarations: bool,
	minified: bool,  // true: no indentation / newlines; false: pretty form
	indent:   string, // indent unit; default "\t" or "  "
	// Type-stripping mode (`kessel strip-types`). When set, TS-only syntax
	// (type annotations, generics, interfaces, `as`/`satisfies`, etc.) is
	// erased so the output is plain JavaScript. Default false — every
	// existing call site emits TS unchanged.
	strip_types: bool,
	optimize_const_enums, lower_using: bool,
	// Preserve the input's module scope when type erasure removes its imports and exports.
	strip_module: StripModuleKind,
	jsx: JSXOptions,
}

StripModuleKind :: enum { Script, ESM, ESM_With_Require }

// The first TypeScript construct whose runtime behavior the stripper cannot
// reproduce. The CLI reports it before writing any output.
StripDiagnostic :: struct {
	loc:  Loc,
	what: string,
}

// Pending operands and delimiters keep infix tree depth off the native stack.
CodegenInfixTask :: struct {
	kind: enum { Operand, Operator, Open, Close },
	expr: ^Expression,
	operator: string,
	precedence: int,
	ctx: CodegenExpressionContext,
}

Codegen :: struct {
	infix_work: [dynamic]CodegenInfixTask,
	renamed: map[u32]string, // Original binding and reference offsets to shorter local names.
	declaration_emit: ^DeclarationEmit, // Tracks references in public type signatures.
	cfg: CodegenConfig,
	source: string, // Borrowed source for syntax spelling omitted by the AST.

	// Output buffer. Grown by cg_reserve via doubling. Owned by Codegen;
	// codegen_destroy frees it.
	buf: []byte,
	pos: int,

	// Current indentation depth (number of cfg.indent units).
	depth: int,

	// True at the start of a line; controls whether the next textual
	// write prefixes itself with indentation in pretty mode.
	at_line_start: bool,
	comments: []Comment, // Borrowed for normal comments in pretty output.
	// First comment that no printer site has claimed, and its source start
	// (CODEGEN_COMMENT_NONE when none is waiting) for a one-compare fast path.
	comment_cursor: int,
	comment_next: u32,
	// Output offset just after comments that began a line; -1 when unset.
	comment_line_pos: int,
	// Output offset just after a continuation indent; -1 when unset.
	comment_continuation_pos: int,
	annotations: map[u32]CodegenAnnotations,

	// Source-map state. nil unless the caller opted in via
	// codegen_enable_sourcemap(). Borrowed; the caller owns the lifetime.
	// Recording mappings on the hot path is a single nil-check + append
	// per Statement; everything else (line/col conversion, VLQ encoding)
	// happens once at the end in sourcemap_to_json.
	sm: ^SourceMap,

	// First non-erasable TS construct hit during type-stripping (cfg.strip_types).
	// nil on success. See StripDiagnostic.
	strip_diag: Maybe(StripDiagnostic),
	param_properties_after_super: []string,
	jsx_omit_self: bool,
	runtime_scope: ^CodegenRuntimeScope,
	resource_helper: string,
	resource_proto_class: Maybe(u32),
	resource_scope: ResourceScope,
	module_resources: ModuleResources,
}

ConstructorKind :: enum { None, Base, Derived }

// Record the first non-erasable TS construct hit while type-stripping. Only
// the first is kept: the caller reports it and exits non-zero, so later hits
// would be noise.
cg_strip_unsupported :: proc(cg: ^Codegen, loc: Loc, what: string) {
	if _, ok := cg.strip_diag.?; ok { return }
	cg.strip_diag = StripDiagnostic{loc = loc, what = what}
}

// ----------------------------------------------------------------------------
// Operator precedence table (ESTree / TC39).
// Higher number binds tighter. Used to decide when to add parentheses.
// ----------------------------------------------------------------------------

PREC_LOWEST   :: 0
PREC_COMMA    :: 1   // SequenceExpression
PREC_ASSIGN   :: 2   // a = b, a += b, yield, arrow body in expr position
PREC_COND     :: 3   // ?:
PREC_NULLISH  :: 4   // ??
PREC_LOR      :: 5   // ||
PREC_LAND     :: 6   // &&
PREC_BOR      :: 7   // |
PREC_BXOR     :: 8   // ^
PREC_BAND     :: 9   // &
PREC_EQ       :: 10  // ==, !=, ===, !==
PREC_REL      :: 11  // <, <=, >, >=, in, instanceof
PREC_SHIFT    :: 12  // <<, >>, >>>
PREC_ADD      :: 13  // +, -
PREC_MUL      :: 14  // *, /, %
PREC_EXP      :: 15  // **
PREC_UNARY    :: 16  // !, ~, +x, -x, void, typeof, delete, await
PREC_UPDATE   :: 17  // ++, --
PREC_CALL     :: 18  // f(), x.y, x[y], new X()
PREC_PRIMARY  :: 19  // literals, identifiers, (expr), [], {}

// ----------------------------------------------------------------------------
// Lifecycle
// ----------------------------------------------------------------------------

PrintOptions :: struct {
	minified, compress, mangle: bool,
	pragma, pragma_frag: string,
}

// CLI and SDK use the same source spelling, binding decisions and source-map offsets.
codegen_print_job :: proc(job: ^ParseJob, cg: ^Codegen, options: PrintOptions, sm: ^SourceMap) {
	// Folding 1+2 to 3 in TypeScript changes the inferred declaration from number to 3.
	js_expressions := job.lang == .JS || job.lang == .JSX
	cfg := CodegenConfig{
		minified = options.minified, indent = "  ", join_declarations = options.compress,
		fold_constants = options.compress && js_expressions,
	}
	source := string(job.source.data)
	codegen_init(cg, cfg, source, context.allocator)
	if options.mangle && js_expressions { cg.renamed = minify_local_names(job, options) }
	if sm != nil {
		sourcemap_init(sm, source)
		codegen_enable_sourcemap(cg, sm)
	}
	if job.lexer.has_hashbang {
		cg_str(cg, "#!")
		cg_str(cg, job.lexer.hashbang_value)
		// A hashbang is a line comment, even when the rest of the output is compact.
		cg_byte(cg, '\n')
	}
	codegen_program(cg, job.program, job.lexer.comments[:], preserve_jsx = job.lang == .JSX || job.lang == .TSX)
	if !options.minified && (cg.pos == 0 || cg.buf[cg.pos-1] != '\n') { cg_byte(cg, '\n') }
}

codegen_init :: proc(cg: ^Codegen, cfg: CodegenConfig, source: string, alloc: mem.Allocator) {
	est := max(len(source), 4096)
	cg.infix_work    = make([dynamic]CodegenInfixTask, 0, 0, alloc)
	cg.renamed       = nil
	cg.declaration_emit = nil
	cg.cfg           = cfg
	cg.source        = source
	cg.buf           = make([]byte, est, alloc)
	cg.pos           = 0
	cg.depth         = 0
	cg.at_line_start = true
	cg.comments      = nil
	cg.comment_cursor = 0
	cg.comment_next  = CODEGEN_COMMENT_NONE
	cg.comment_line_pos = -1
	cg.comment_continuation_pos = -1
	cg.annotations   = nil
	cg.sm            = nil
	cg.strip_diag    = nil
	cg.param_properties_after_super = nil
	cg.jsx_omit_self = false
	cg.resource_helper = ""
	cg.resource_proto_class = nil
	cg.resource_scope = {}
	cg.module_resources = {}
	cg.runtime_scope    = nil
}

// Opt the codegen into source-map recording. After codegen_program
// returns, the caller can read `cg.sm.records` and pass them to
// sourcemap_to_json. Borrowed pointer; caller manages the SourceMap's
// lifetime.
codegen_enable_sourcemap :: proc(cg: ^Codegen, sm: ^SourceMap) {
	cg.sm = sm
}

codegen_destroy :: proc(cg: ^Codegen, alloc: mem.Allocator) {
	delete(cg.infix_work)
	cg.infix_work = nil
	if cg.annotations != nil { delete(cg.annotations) }
	if cg.buf != nil { delete(cg.buf, alloc) }
	cg.buf = nil
	cg.pos = 0
}

// ----------------------------------------------------------------------------
// Writer primitives
// ----------------------------------------------------------------------------

cg_reserve :: #force_inline proc(cg: ^Codegen, need: int) {
	if cg.pos + need <= len(cg.buf) { return }
	new_cap := max(len(cg.buf) * 2, cg.pos + need)
	new_buf := make([]byte, new_cap, context.allocator)
	mem.copy(raw_data(new_buf), raw_data(cg.buf), cg.pos)
	delete(cg.buf, context.allocator)
	cg.buf = new_buf
}

// Emit indentation when at the start of a line in pretty mode.
cg_indent :: proc(cg: ^Codegen) {
	if cg.cfg.minified { return }
	if !cg.at_line_start { return }
	unit := cg.cfg.indent
	if len(unit) == 0 { unit = "\t" }
	need := cg.depth * len(unit)
	cg_reserve(cg, need)
	for _ in 0..<cg.depth {
		mem.copy(&cg.buf[cg.pos], raw_data(unit), len(unit))
		cg.pos += len(unit)
	}
	cg.at_line_start = false
}

// Raw write of a single byte. Triggers indentation first.
cg_byte :: #force_inline proc(cg: ^Codegen, b: byte) {
	cg_indent(cg)
	cg_reserve(cg, 1)
	cg.buf[cg.pos] = b
	cg.pos += 1
}

// Raw write of a string. Triggers indentation first.
cg_str :: proc(cg: ^Codegen, s: string) {
	if len(s) == 0 { return }
	cg_indent(cg)
	cg_reserve(cg, len(s))
	mem.copy(&cg.buf[cg.pos], raw_data(s), len(s))
	cg.pos += len(s)
}

// Newline (or nothing in minified mode). After a newline the next write
// will re-indent.
cg_newline :: proc(cg: ^Codegen) {
	if cg.cfg.minified { return }
	cg_reserve(cg, 1)
	cg.buf[cg.pos] = '\n'
	cg.pos += 1
	cg.at_line_start = true
}

// Conditional space: emit ' ' in pretty mode, nothing in minified mode.
cg_space :: #force_inline proc(cg: ^Codegen) {
	if cg.cfg.minified { return }
	cg_byte(cg, ' ')
}

// Mandatory space between two identifier-like tokens (e.g. `return x`).
// Always emitted, even in minified mode, to preserve token boundaries.
cg_hard_space :: #force_inline proc(cg: ^Codegen) {
	cg_byte(cg, ' ')
}

// Decorator / modifier separator: emits a newline in pretty mode (so each
// decorator lands on its own line) and a single mandatory space in
// minified mode. Plain `cg_newline` collapses to nothing in minified
// output, which glues `@computed accessor` -> `@computedaccessor` and
// loses the token boundary on reparse.
cg_break_or_space :: #force_inline proc(cg: ^Codegen) {
	if cg.cfg.minified { cg_hard_space(cg) } else { cg_newline(cg) }
}

// Before a closing delimiter: print the comments that remain inside the group.
cg_close_comments :: #force_inline proc(cg: ^Codegen, upto: u32) {
	if cg.comment_next < upto { codegen_flush_comments(cg, upto, true) }
}

// Before the bracket that closes a computed key.
cg_close_key :: proc(cg: ^Codegen, key: ^Expression) {
	if cg.comment_next == CODEGEN_COMMENT_NONE { return }
	cg_close_comments(cg, codegen_skip_trivia(cg.source, loc_from_expr(key).end, groups = true))
}

// ----------------------------------------------------------------------------
// Top-level entry point
// ----------------------------------------------------------------------------

codegen_program :: proc(cg: ^Codegen, program: ^Program, comments: []Comment = nil, lowering_allocator: mem.Allocator = {}, preserve_jsx := false) {
	if program == nil { return }
	if cg.cfg.strip_types {
		allocator := lowering_allocator if lowering_allocator.procedure != nil else context.temp_allocator
		cg.runtime_scope = new(CodegenRuntimeScope, allocator)
		cg.runtime_scope^ = {
			program = program, allocator = allocator, needs_module_marker = cg.cfg.strip_module != .Script,
		}
		if cg.cfg.optimize_const_enums {
			cg.runtime_scope.enum_constants = new(EnumConstants, allocator)
			codegen_resolve_runtime_scopes(cg, cg.runtime_scope)
		}
	}
	codegen_index_annotations(cg, comments, context.allocator)
	// Late license comments may contain @jsx. Hoisting them would change the JSX factory.
	compact_jsx := preserve_jsx && cg.cfg.minified
	header_end := len(comments)
	if compact_jsx && len(program.body) != 0 {
		header_end = codegen_comment_lower_bound(comments, codegen_list_item_loc(program.body[0]).start)
	}
	codegen_emit_legal_comments(cg, comments[:header_end], compact_jsx)
	defer codegen_emit_legal_comments(cg, comments[header_end:])
	source_end := u32(len(cg.source))
	codegen_comments_begin(cg, comments)
	jsx_boundary, jsx_offset := -1, -1
	directives := 0
	jsx_prelude := cg.cfg.jsx.runtime == .Automatic || cg.cfg.jsx.development
	if jsx_prelude || cg.cfg.strip_module == .ESM_With_Require {
		directives = codegen_directive_count(program.body[:])
	}
	if jsx_prelude {
		jsx_boundary = directives
		for jsx_boundary < len(program.body) {
			item := program.body[jsx_boundary]^
			if _, imported := item.(^ImportDeclaration); !imported && strip_statement_has_runtime(item) { break }
			jsx_boundary += 1
		}
		if jsx_boundary == 0 {
			if !cg.cfg.minified && len(program.body) > 0 {
				header := jsx_file_header(comments, codegen_list_item_loc(program.body[0]).start)
				if len(header) > 0 {
					position := cg.pos
					codegen_emit_comment_gap(cg, 0, header[len(header) - 1].end, false)
					if cg.pos != position && !cg.at_line_start { cg_newline(cg) }
				}
			}
			jsx_offset = cg.pos
		}
	}
	if !cg.cfg.minified {
		codegen_emit_leading_comments(cg, program.body[:], 0, source_end)
	}
	// Directive prologue (e.g. "use strict") lives in BOTH `program.directives`
	// and as the leading ExpressionStatement of `program.body`. We emit only
	// from body[] to avoid duplicate output.
	module_kind := resource_list_kind(cg, program.body[:])
	for i in 0..<len(program.body) {
		if i == jsx_boundary && jsx_offset < 0 { jsx_offset = cg.pos }
		if cg.cfg.strip_module == .ESM_With_Require && i == directives {
			gen_strip_require_binding(cg)
		}
		need_asi_guard := false
		if cg.cfg.minified && i + 1 < len(program.body) {
			need_asi_guard = prev_stmt_can_continue_into_next(program.body[i]^, program.body[i+1]^)
		}
		if module_kind == .None {
			gen_statement_list_entry(cg, program.body[:], i)
		} else {
			gen_module_resource_item(cg, program.body[i], module_kind)
		}
		if !cg.cfg.minified {
			// Keep standalone comments attached to the next user statement.
			offset := &jsx_offset if i + 1 == jsx_boundary else nil
			codegen_end_item_line(cg, program.body[:], i, source_end, insert_offset = offset)
		} else if need_asi_guard {
			// Use a newline instead of `;` here — a `;` would reparse as
			// an additional EmptyStatement, lengthening the body by one
			// and breaking AST round-trip. A bare newline is a free ASI
			// separator that doesn't add a node.
			if cg.pos > 0 && cg.buf[cg.pos-1] != '\n' { cg_byte(cg, '\n') }
		}
	}
	if jsx_offset >= 0 { gen_jsx_runtime_imports(cg, jsx_offset) }
	if module_kind != .None { codegen_resource_dispose(cg, cg.resource_scope, cg.module_resources.completion) }
	gen_module_resource_unwind(cg)
	codegen_resource_helper(cg)
	gen_module_pattern_helper(cg)
	if cg.runtime_scope != nil && cg.runtime_scope.needs_module_marker {
		cg_str(cg, "export {};")
		cg_newline(cg)
	}
}

codegen_directive_count :: proc(statements: []^Statement) -> int {
	for statement, index in statements {
		expr, ok := statement^.(^ExpressionStatement)
		if !ok || expr.expression == nil { return index }
		literal, bare := expr.expression^.(^StringLiteral)
		if !bare || literal.loc.start != expr.loc.start { return index }
	}
	return len(statements)
}

// Record actual ESM syntax, including exports generated by namespace and enum lowering.
cg_module_keyword :: proc(cg: ^Codegen, keyword: string) {
	if cg.runtime_scope != nil { cg.runtime_scope.needs_module_marker = false }
	cg_str(cg, keyword)
}

// prev_stmt_can_continue_into_next reports whether the codegen output
// of `prev` (in minified form) could be glued onto `next`'s leading
// token and reparsed as a single expression. The only practical
// hazards we've hit are: `export default <FunctionExpression>` or
// `export default <ClassExpression>` followed by an expression
// statement whose first token is `(`, `[`, a backtick, etc. — the
// `)` / `]` / template would otherwise re-tokenise as a call /
// member-access / tagged-template on the function-expression.
prev_stmt_can_continue_into_next :: proc(prev, next: Statement) -> bool {
	// Only `export default <expression>` is at risk: a regular
	// FunctionDeclaration or ClassDeclaration is a Statement and the
	// parser cannot fold a following `(foo)` into it.
	ed, is_ed := prev.(^ExportDefaultDeclaration)
	if !is_ed || ed == nil || ed.declaration == nil { return false }
	#partial switch v in ed.declaration^ {
	case ^Expression:
		#partial switch _ in v^ {
		case ^FunctionExpression: // ok
		case ^ClassExpression:    // ok
		case:                     return false
		}
	case:
		return false
	}
	return stmt_starts_with_asi_hazard(next)
}

// stmt_starts_with_asi_hazard reports whether `stmt` begins with a
// token that, when glued directly onto a previous statement ending in
// `)` or `]` or `}`, would extend that statement instead of starting a
// new one. Used to decide whether the minifier must emit a separating
// `;` between adjacent statements.
stmt_starts_with_asi_hazard :: proc(stmt: Statement) -> bool {
	es, is_expr_stmt := stmt.(^ExpressionStatement)
	if !is_expr_stmt || es == nil || es.expression == nil { return false }
	#partial switch e in es.expression^ {
	case ^UnaryExpression:         return true
	case ^UpdateExpression:        return true
	case ^TemplateLiteral:         return true
	case ^TaggedTemplateExpression:return true
	case ^RegExpLiteral:           return true
	case ^ParenthesizedExpression: return true
	case ^ArrayExpression:         return true
	case ^CallExpression:          return true
	}
	return false
}

// ============================================================================
// Statement dispatch
// ============================================================================

// Type erasure prints nothing for a declaration without runtime behavior. Its
// comments describe syntax that is gone, so they go with it.
gen_statement_list_entry :: proc(cg: ^Codegen, statements: []^Statement, index: int) {
	gen_statement_list_item(cg, statements, index)
	if cg.comment_next == CODEGEN_COMMENT_NONE || !cg.cfg.strip_types { return }
	if strip_statement_has_runtime(statements[index]^) { return }
	codegen_skip_comments(cg, get_statement_loc(statements[index]).end)
}

gen_statement :: proc(cg: ^Codegen, stmt: Statement) {
	if cg.comment_next != CODEGEN_COMMENT_NONE {
		stmt_local := stmt
		codegen_flush_comments(cg, get_statement_loc(&stmt_local).start)
	}
	if cg.sm != nil {
		// Force indent before recording so the mapping points at the
		// statement keyword, not at the leading whitespace.
		cg_indent(cg)
		stmt_local := stmt
		cg_record_stmt_mapping(cg, &stmt_local)
	}
	if cg.cfg.lower_using {
		#partial switch _ in stmt {
		case ^LabeledStatement, ^ForStatement: if codegen_resource_for(cg, stmt) { return }
		}
	}
	switch s in stmt {
	case ^ExpressionStatement:        gen_expression_statement(cg, s)
	case ^EmptyStatement:             cg_byte(cg, ';')
	case ^BlockStatement:             gen_block_statement(cg, s)
	case ^DebuggerStatement:          cg_str(cg, "debugger;")
	case ^ReturnStatement:            gen_return_statement(cg, s)
	case ^BreakStatement:             gen_break_statement(cg, s)
	case ^ContinueStatement:          gen_continue_statement(cg, s)
	case ^LabeledStatement:           gen_labeled_statement(cg, s)
	case ^IfStatement:                gen_if_statement(cg, s)
	case ^SwitchStatement:            gen_switch_statement(cg, s)
	case ^WhileStatement:             gen_while_statement(cg, s)
	case ^DoWhileStatement:           gen_do_while_statement(cg, s)
	case ^ForStatement:               gen_for_statement(cg, s)
	case ^ForInStatement:             gen_for_in_statement(cg, s)
	case ^ForOfStatement:             gen_for_of_statement(cg, s)
	case ^WithStatement:              gen_with_statement(cg, s)
	case ^ThrowStatement:             gen_throw_statement(cg, s)
	case ^TryStatement:               gen_try_statement(cg, s)
	case ^FunctionDeclaration:        if !(cg.cfg.strip_types && (s.declare || s.no_body)) { gen_function_declaration(cg, s) }
	case ^VariableDeclaration:        if !(cg.cfg.strip_types && s.declare) { gen_variable_declaration(cg, s, true) }
	case ^ClassDeclaration:           if !(cg.cfg.strip_types && s.declare) { gen_class_declaration(cg, s) }
	case ^ImportDeclaration:          gen_import_declaration(cg, s)
	case ^ExportNamedDeclaration:     gen_export_named_declaration(cg, s)
	case ^ExportDefaultDeclaration:   gen_export_default_declaration(cg, s)
	case ^ExportAllDeclaration:       gen_export_all_declaration(cg, s)
	case ^TSInterfaceDeclaration:     if !cg.cfg.strip_types { gen_ts_interface_declaration(cg, s) }
	case ^TSTypeAliasDeclaration:     if !cg.cfg.strip_types { gen_ts_type_alias_declaration(cg, s) }
	case ^TSEnumDeclaration:          if cg.cfg.strip_types { gen_ts_enum_lowered(cg, s) } else { gen_ts_enum_declaration(cg, s) }
	case ^TSModuleDeclaration:        if cg.cfg.strip_types { gen_ts_module_declaration_stripped(cg, s) } else { gen_ts_module_declaration(cg, s) }
	case ^TSImportEqualsDeclaration:  if cg.cfg.strip_types { gen_ts_import_equals_lowered(cg, s) } else { gen_ts_import_equals(cg, s) }
	case ^TSExportAssignment:         if cg.cfg.strip_types { gen_ts_export_assignment_lowered(cg, s) } else { gen_ts_export_assignment(cg, s) }
	case ^TSNamespaceExportDeclaration: if !cg.cfg.strip_types { gen_ts_namespace_export(cg, s) }
	}
}

// ============================================================================
// Expression dispatch
// ============================================================================

CodegenExpressionContext :: bit_set[enum { Forbid_In, Nullish_Operand }; u8]

gen_expression :: proc(
	cg: ^Codegen, expr: ^Expression, parent_prec: int = PREC_LOWEST, ctx: CodegenExpressionContext = {},
) {
	value, child_ctx, close_paren := gen_expression_begin(cg, expr, parent_prec, ctx)
	if value == nil { return }
	gen_expression_raw(cg, value, child_ctx)
	if close_paren { cg_byte(cg, ')') }
}

// Both ordinary expressions and pending infix operands enter through this path
// so folding, grouping, source maps and TypeScript erasure stay in sync.
gen_expression_begin :: proc(
	cg: ^Codegen, expr: ^Expression, parent_prec: int, ctx: CodegenExpressionContext,
) -> (^Expression, CodegenExpressionContext, bool) {
	if expr == nil { return nil, {}, false }
	value := codegen_runtime_expression(cg, expr)
	if value == nil { return nil, {}, false }
	if cg.cfg.fold_constants && minify_expression(cg, value, parent_prec) { return nil, {}, false }
	prec := expression_precedence(value)
	need_paren := prec < parent_prec
	// The grammar forbids bare && and || operands of ?? regardless of precedence.
	if .Nullish_Operand in ctx && (prec == PREC_LOR || prec == PREC_LAND) { need_paren = true }
	if .Forbid_In in ctx && prec == PREC_REL {
		if binary, ok := value^.(^BinaryExpression); ok && binary.operator == .In { need_paren = true }
	}
	if cg.cfg.jsx.runtime != .Preserve && parent_prec >= PREC_CALL {
		// A lowered JSX receiver is a call, including in the callee of new.
		#partial switch _ in value^ { case ^JSXElement, ^JSXFragment: need_paren = true }
	}
	// Comments go in front of grouping that the printer adds. Grouping is not
	// part of the AST, so the output is read back with the comment before it.
	if cg.comment_next != CODEGEN_COMMENT_NONE {
		if need_paren {
			codegen_flush_head(cg, loc_from_expr(expr).start)
		} else {
			codegen_flush_comments(cg, loc_from_expr(expr).start)
		}
	}
	if need_paren { cg_byte(cg, '(') }
	// A comparison followed by a type assertion or JSX must lex as two '<' tokens.
	if cg.pos > 0 && cg.buf[cg.pos - 1] == '<' {
		#partial switch _ in value^ {
		case ^TSTypeAssertion, ^JSXElement, ^JSXFragment: cg_hard_space(cg)
		}
	}
	if cg.sm != nil {
		cg_indent(cg)
		sourcemap_record(cg.sm, u32(cg.pos), loc_from_expr(expr).start)
	}
	// Parentheses restore the full expression grammar inside a for initializer.
	child_ctx: CodegenExpressionContext
	if !need_paren && .Forbid_In in ctx { child_ctx = {.Forbid_In} }
	return value, child_ctx, need_paren
}

codegen_runtime_expression :: proc(cg: ^Codegen, expr: ^Expression) -> ^Expression {
	value := expr
	if !cg.cfg.strip_types { return value }
	for value != nil {
		#partial switch e in value^ {
		case ^TSAsExpression:            value = e.expression
		case ^TSSatisfiesExpression:     value = e.expression
		case ^TSNonNullExpression:       value = e.expression
		case ^TSTypeAssertion:           value = e.expression
		case ^TSInstantiationExpression: value = e.expression
		case: return value
		}
	}
	return value
}

gen_expression_raw :: proc(cg: ^Codegen, expr: ^Expression, ctx: CodegenExpressionContext = {}) {
	if len(cg.annotations) != 0 { codegen_emit_expression_annotation(cg, expr) }
	switch e in expr^ {
	case ^NullLiteral:                cg_str(cg, "null")
	case ^BooleanLiteral:             cg_str(cg, e.value ? "true" : "false")
	case ^NumericLiteral:             gen_numeric_literal(cg, e)
	case ^StringLiteral:              gen_string_literal(cg, e)
	case ^BigIntLiteral:              gen_bigint_literal(cg, e)
	case ^RegExpLiteral:              gen_regexp_literal(cg, e)
	case ^TemplateLiteral:            gen_template_literal(cg, e)
	case ^TaggedTemplateExpression:   gen_tagged_template(cg, e)
	case ^Identifier:                 gen_expression_identifier(cg, e)
	case ^PrivateIdentifier:          cg_byte(cg, '#'); cg_str(cg, e.name)
	case ^ThisExpression:             cg_str(cg, "this")
	case ^Super:                      cg_str(cg, "super")
	case ^ChainExpression:            gen_expression_raw(cg, e.expression)
	case ^ArrayExpression:            gen_array_expression(cg, e)
	case ^ObjectExpression:           gen_object_expression(cg, e)
	case ^FunctionExpression:         gen_function_expression(cg, e)
	case ^ArrowFunctionExpression:    gen_arrow_function(cg, e, ctx)
	case ^ClassExpression:            gen_class_expression(cg, e)
	case ^MemberExpression:           gen_member_expression(cg, e)
	case ^CallExpression:             gen_call_expression(cg, e)
	case ^NewExpression:              gen_new_expression(cg, e)
	case ^ConditionalExpression:      gen_conditional_expression(cg, e, ctx)
	case ^UpdateExpression:           gen_update_expression(cg, e)
	case ^UnaryExpression:            gen_unary_expression(cg, e)
	case ^BinaryExpression, ^LogicalExpression: gen_infix_expression(cg, expr, ctx)
	case ^AssignmentExpression:       gen_assignment_expression(cg, e, ctx)
	case ^SequenceExpression:         gen_sequence_expression(cg, e, ctx)
	case ^SpreadElement:              cg_str(cg, "..."); gen_expression(cg, e.argument, PREC_ASSIGN)
	case ^YieldExpression:            gen_yield_expression(cg, e, ctx)
	case ^AwaitExpression:            cg_str(cg, "await "); gen_expression(cg, e.argument, PREC_UNARY)
	case ^ImportExpression:           gen_import_expression(cg, e)
	case ^MetaProperty:               gen_meta_property(cg, e)
	case ^JSXElement:                 gen_jsx_element(cg, e)
	case ^JSXFragment:                gen_jsx_fragment(cg, e)
	case ^JSXText:                    cg_str(cg, e.value)
	case ^JSXExpressionContainer:     gen_jsx_expression_container(cg, e)
	case ^JSXEmptyExpression:         // empty
	case ^JSXSpreadChild:             cg_byte(cg, '{'); cg_str(cg, "..."); gen_expression(cg, e.expression, PREC_ASSIGN); cg_byte(cg, '}')
	case ^TSAsExpression:             if cg.cfg.strip_types { gen_expression_raw(cg, e.expression) } else { gen_ts_as_expression(cg, e) }
	case ^TSSatisfiesExpression:      if cg.cfg.strip_types { gen_expression_raw(cg, e.expression) } else { gen_ts_satisfies_expression(cg, e) }
	case ^TSNonNullExpression:        gen_expression(cg, e.expression, PREC_CALL); if !cg.cfg.strip_types { cg_byte(cg, '!') }
	case ^TSTypeAssertion:            if cg.cfg.strip_types { gen_expression_raw(cg, e.expression) } else { gen_ts_type_assertion(cg, e) }
	case ^TSInstantiationExpression:  if cg.cfg.strip_types { gen_expression_raw(cg, e.expression) } else { gen_ts_instantiation(cg, e) }
	case ^ParenthesizedExpression:
		cg_byte(cg, '(')
		gen_expression(cg, e.expression, PREC_LOWEST)
		cg_close_comments(cg, e.loc.end)
		cg_byte(cg, ')')
	}
}

// ----------------------------------------------------------------------------
// Precedence helper
// ----------------------------------------------------------------------------

expression_precedence :: proc(expr: ^Expression) -> int {
	if expr == nil { return PREC_LOWEST }
	switch e in expr^ {
	case ^NullLiteral, ^BooleanLiteral, ^NumericLiteral, ^StringLiteral,
	     ^BigIntLiteral, ^RegExpLiteral, ^TemplateLiteral, ^Identifier,
	     ^PrivateIdentifier, ^ThisExpression, ^Super, ^ArrayExpression,
	     ^ObjectExpression, ^ParenthesizedExpression, ^JSXElement,
	     ^JSXFragment, ^JSXText, ^JSXExpressionContainer,
	     ^JSXEmptyExpression, ^JSXSpreadChild, ^MetaProperty:
		return PREC_PRIMARY
	case ^FunctionExpression, ^ClassExpression:
		return PREC_PRIMARY
	case ^TaggedTemplateExpression, ^MemberExpression, ^CallExpression,
	     ^NewExpression, ^ChainExpression, ^ImportExpression:
		return PREC_CALL
	case ^UpdateExpression:
		return PREC_UPDATE
	case ^UnaryExpression, ^AwaitExpression:
		return PREC_UNARY
	case ^BinaryExpression:
		_, prec := binop_text(e.operator)
		return prec
	case ^LogicalExpression:
		switch e.operator {
		case .And:                return PREC_LAND
		case .Or:                 return PREC_LOR
		case .NullishCoalescing:  return PREC_NULLISH
		}
		return PREC_LOR
	case ^ConditionalExpression:
		return PREC_COND
	case ^AssignmentExpression, ^ArrowFunctionExpression, ^YieldExpression:
		return PREC_ASSIGN
	case ^SequenceExpression:
		return PREC_COMMA
	case ^SpreadElement:
		return PREC_ASSIGN
	case ^TSAsExpression, ^TSSatisfiesExpression, ^TSTypeAssertion:
		// kessel's parser binds `as` / `satisfies` / `<Type>x` tighter
		// than relational and binary operators (verified empirically:
		// `x < y as boolean` parses as `x < (y as boolean)`). Treat them
		// at unary level so the right operand of `<`, `+`, etc. does not
		// pick up spurious parens, while `(x as T).y` and `(x as T)(args)`
		// still get them because MemberExpression / CallExpression are
		// at PREC_CALL (higher than PREC_UNARY).
		return PREC_UNARY
	case ^TSInstantiationExpression:
		return PREC_CALL
	case ^TSNonNullExpression:
		// Postfix `!` is tighter than member access in TS, so it stays
		// at PREC_CALL just like `.` / `[]`.
		return PREC_CALL
	}
	return PREC_LOWEST
}

binop_precedence :: proc(op: string) -> int {
	switch op {
	case "**":                                          return PREC_EXP
	case "*", "/", "%":                                 return PREC_MUL
	case "+", "-":                                      return PREC_ADD
	case "<<", ">>", ">>>":                             return PREC_SHIFT
	case "<", "<=", ">", ">=", "in", "instanceof":      return PREC_REL
	case "==", "!=", "===", "!==":                      return PREC_EQ
	case "&":                                           return PREC_BAND
	case "^":                                           return PREC_BXOR
	case "|":                                           return PREC_BOR
	}
	return PREC_LOWEST
}

// ============================================================================
// Per-node procedures.
//
// Consolidated from the former codegen_{impl,helpers,expr,ts}.odin split:
// codegen lives in a single file, matching the one-file-per-pass convention
// of parser.odin / checker.odin / emitter.odin. The order tracks the
// dispatch tables above for grep-ability: statements, then patterns and
// shared function/class helpers, then expressions, then TypeScript.
// ============================================================================


// ============================================================================
// Statements
// ============================================================================

gen_expression_statement :: proc(cg: ^Codegen, s: ^ExpressionStatement) {
	// An ExpressionStatement whose leftmost token is `function`, `class`,
	// or `{` is ambiguous with FunctionDeclaration / ClassDeclaration /
	// BlockStatement. Wrap in parens so the re-parse picks the
	// Expression production.
	if expression_starts_with_ambiguous_token(cg, s.expression, .Statement) ||
	   expression_is_grouped_string(s) {
		cg_byte(cg, '(')
		gen_expression(cg, s.expression, PREC_LOWEST)
		cg_byte(cg, ')')
	} else {
		gen_expression(cg, s.expression, PREC_LOWEST)
	}
	cg_byte(cg, ';')
}

// `("use strict");` is an ordinary statement. Printed without its grouping
// it would become a directive and change the mode of the code after it.
expression_is_grouped_string :: proc(s: ^ExpressionStatement) -> bool {
	if s.expression == nil { return false }
	literal, is_string := s.expression^.(^StringLiteral)
	return is_string && literal.loc.start != s.loc.start
}

ExpressionStartContext :: enum { Statement, Arrow_Body, Default_Export }

// Statements and concise arrows can interpret a leading brace as a block.
// A function or class after "export default" is parsed as a declaration.
expression_starts_with_ambiguous_token :: proc(cg: ^Codegen, expr: ^Expression, position: ExpressionStartContext) -> bool {
	cur := expr
	for cur != nil {
		#partial switch e in cur^ {
		case ^FunctionExpression:        return position != .Arrow_Body
		case ^ClassExpression:           return position != .Arrow_Body
		case ^ObjectExpression:          return position != .Default_Export
		case ^CallExpression:            cur = e.callee
		case ^MemberExpression:          cur = e.object
		case ^TaggedTemplateExpression:  cur = e.tag
		case ^BinaryExpression:          cur = e.left
		case ^LogicalExpression:         cur = e.left
		case ^ConditionalExpression:     cur = e.test
		case ^AssignmentExpression:      cur = e.left
		case ^SequenceExpression:
			if len(e.expressions) == 0 { return false }
			cur = e.expressions[0]
		case ^UpdateExpression:
			if !e.prefix { cur = e.argument } else { return false }
		case ^TSAsExpression:            cur = e.expression
		case ^TSSatisfiesExpression:     cur = e.expression
		case ^TSNonNullExpression:       cur = e.expression
		case ^TSInstantiationExpression: cur = e.expression
		case ^TSTypeAssertion:
			if !cg.cfg.strip_types { return false }
			cur = e.expression
		case ^ChainExpression:           cur = e.expression
		case:
			return false
		}
	}
	return false
}

gen_block_statement :: proc(cg: ^Codegen, s: ^BlockStatement) {
	gen_statement_block(cg, s.body[:], s.loc)
}

gen_statement_block :: proc(cg: ^Codegen, statements: []^Statement, loc: Loc) {
	if cg.comment_next < loc.start { codegen_flush_comments(cg, loc.start) }
	cg_byte(cg, '{')
	comments := codegen_comments_in_body(cg, loc)
	if len(statements) == 0 && !codegen_has_ordinary_comments(comments) { cg_byte(cg, '}'); return }
	cg_newline(cg)
	cg.depth += 1
	codegen_emit_leading_comments(cg, statements, loc.start, loc.end)
	kind := resource_list_kind(cg, statements)
	start := 0
	if kind != .None {
		start = codegen_directive_count(statements)
		for i in 0..<start {
			gen_statement_list_entry(cg, statements, i)
			codegen_end_item_line(cg, statements, i, loc.end)
		}
	}
	outer := codegen_resource_open(cg, kind)
	for i in start..<len(statements) {
		gen_statement_list_entry(cg, statements, i)
		codegen_end_item_line(cg, statements, i, loc.end)
	}
	codegen_resource_close(cg, kind, outer)
	cg.depth -= 1
	cg_byte(cg, '}')
}

gen_return_statement :: proc(cg: ^Codegen, s: ^ReturnStatement) {
	if arg, ok := s.argument.?; ok {
		codegen_hoist_comments(cg, loc_from_expr(arg).start, s.loc.start)
	}
	cg_str(cg, "return")
	if arg, ok := s.argument.?; ok {
		cg_hard_space(cg)
		gen_expression(cg, arg, PREC_LOWEST)
	}
	cg_byte(cg, ';')
}

gen_break_statement :: proc(cg: ^Codegen, s: ^BreakStatement) {
	cg_str(cg, "break")
	if lbl, ok := s.label.?; ok {
		cg_hard_space(cg)
		cg_str(cg, lbl.name)
	}
	cg_byte(cg, ';')
}

gen_continue_statement :: proc(cg: ^Codegen, s: ^ContinueStatement) {
	cg_str(cg, "continue")
	if lbl, ok := s.label.?; ok {
		cg_hard_space(cg)
		cg_str(cg, lbl.name)
	}
	cg_byte(cg, ';')
}

gen_labeled_statement :: proc(cg: ^Codegen, s: ^LabeledStatement) {
	cg_str(cg, s.label.name)
	cg_byte(cg, ':')
	cg_space(cg)
	gen_statement(cg, s.body^)
}

gen_if_statement :: proc(cg: ^Codegen, s: ^IfStatement) {
	cg_str(cg, "if")
	cg_space(cg)
	cg_byte(cg, '(')
	gen_expression(cg, s.test, PREC_LOWEST)
	cg_close_comments(cg, get_statement_loc(s.consequent).start)
	cg_byte(cg, ')')
	cg_space(cg)
	gen_statement(cg, s.consequent^)
	if alt, ok := s.alternate.?; ok {
		cg_space(cg)
		cg_str(cg, "else")
		cg_hard_space(cg)
		gen_statement(cg, alt^)
	}
}

gen_switch_statement :: proc(cg: ^Codegen, s: ^SwitchStatement) {
	kind := ResourceKind.None
	if cg.cfg.lower_using {
		for arm in s.cases { kind = max(kind, resource_list_kind(cg, arm.consequent[:])) }
	}
	if kind != .None { cg_byte(cg, '{'); cg_newline(cg); cg.depth += 1 }
	outer := codegen_resource_open(cg, kind)
	cg_str(cg, "switch")
	cg_space(cg)
	cg_byte(cg, '(')
	gen_expression(cg, s.discriminant, PREC_LOWEST)
	cg_close_comments(cg, loc_from_expr(s.discriminant).end)
	cg_byte(cg, ')')
	cg_space(cg)
	cg_byte(cg, '{')
	cg_newline(cg)
	cg.depth += 1
	// The closing brace bounds the comments of the last case.
	body_end := s.loc.end - 1 if s.loc.end > 0 else 0
	codegen_emit_leading_comments(cg, s.cases[:], s.loc.start, body_end)
	for c, index in s.cases {
		next := body_end
		if index + 1 < len(s.cases) { next = s.cases[index + 1].loc.start }
		gen_switch_case(cg, c, next, index + 1 == len(s.cases))
	}
	cg.depth -= 1
	cg_byte(cg, '}')
	if kind != .None {
		cg_newline(cg)
		codegen_resource_close(cg, kind, outer)
		cg.depth -= 1
		cg_byte(cg, '}')
	}
}

// `next` is where the following case, or the closing brace, begins.
gen_switch_case :: proc(cg: ^Codegen, c: SwitchCase, next: u32, last: bool) {
	header_end := c.loc.start
	if t, ok := c.test.?; ok {
		cg_str(cg, "case ")
		gen_expression(cg, t, PREC_LOWEST)
		header_end = loc_from_expr(t).end
		cg_close_comments(cg, header_end)
		cg_byte(cg, ':')
	} else {
		cg_str(cg, "default:")
	}
	// Comments at the indentation of the next case describe that case. Before
	// the closing brace there is no next case to compare with.
	split := next
	if !last && cg.comment_next < next {
		from := header_end
		if len(c.consequent) > 0 {
			from = get_statement_loc(c.consequent[len(c.consequent) - 1]).end
		}
		split = codegen_outdented_comment(cg, from, next)
	}
	cg.depth += 1
	if cg.comment_next < split {
		boundary := split
		if len(c.consequent) > 0 { boundary = get_statement_loc(c.consequent[0]).start }
		codegen_emit_comment_gap(cg, header_end, boundary, true)
	}
	if !cg.at_line_start { cg_newline(cg) }
	for _, i in c.consequent {
		gen_statement_list_entry(cg, c.consequent[:], i)
		codegen_end_item_line(cg, c.consequent[:], i, split)
	}
	cg.depth -= 1
	if cg.comment_next < next {
		codegen_emit_comment_gap(cg, split, next, false)
		if !cg.at_line_start { cg_newline(cg) }
	}
}

gen_while_statement :: proc(cg: ^Codegen, s: ^WhileStatement) {
	cg_str(cg, "while")
	cg_space(cg)
	cg_byte(cg, '(')
	gen_expression(cg, s.test, PREC_LOWEST)
	cg_close_comments(cg, get_statement_loc(s.body).start)
	cg_byte(cg, ')')
	cg_space(cg)
	gen_statement(cg, s.body^)
}

gen_do_while_statement :: proc(cg: ^Codegen, s: ^DoWhileStatement) {
	cg_str(cg, "do")
	// `do <stmt> while (...)` — the body may be a block (`{...}`) or any
	// statement form. A bare identifier (e.g. `do keep(); while (true)`)
	// needs a hard separator from the `do` keyword; cg_space collapses
	// in minified mode and produces `dokeep()`.
	cg_hard_space(cg)
	gen_statement(cg, s.body^)
	cg_space(cg)
	cg_str(cg, "while")
	cg_space(cg)
	cg_byte(cg, '(')
	gen_expression(cg, s.test, PREC_LOWEST)
	cg_close_comments(cg, s.loc.end)
	cg_str(cg, ");")
}

gen_for_statement :: proc(cg: ^Codegen, s: ^ForStatement) {
	cg_str(cg, "for")
	cg_space(cg)
	cg_byte(cg, '(')
	if v, ok := s.init_decl.?; ok {
		gen_variable_declaration(cg, v, false, {.Forbid_In})
	} else if v, ok := s.init_expr.?; ok {
		gen_expression(cg, v, PREC_LOWEST, {.Forbid_In})
	}
	cg_byte(cg, ';')
	if t, ok := s.test.?; ok { cg_space(cg); gen_expression(cg, t, PREC_LOWEST) }
	cg_byte(cg, ';')
	if u, ok := s.update.?; ok { cg_space(cg); gen_expression(cg, u, PREC_LOWEST) }
	cg_close_comments(cg, get_statement_loc(s.body).start)
	cg_byte(cg, ')')
	cg_space(cg)
	gen_statement(cg, s.body^)
}

gen_for_in_statement :: proc(cg: ^Codegen, s: ^ForInStatement) {
	cg_str(cg, "for")
	cg_space(cg)
	cg_byte(cg, '(')
	if v, ok := s.left_decl.?; ok {
		gen_variable_declaration(cg, v, false, {.Forbid_In})
	} else if v, ok := s.left_expr.?; ok {
		gen_expression(cg, v, PREC_LOWEST)
	}
	cg_str(cg, " in ")
	gen_expression(cg, s.right, PREC_LOWEST)
	cg_close_comments(cg, get_statement_loc(s.body).start)
	cg_byte(cg, ')')
	cg_space(cg)
	gen_statement(cg, s.body^)
}

gen_for_of_statement :: proc(cg: ^Codegen, s: ^ForOfStatement) {
	if cg.cfg.lower_using {
		if decl, ok := s.left_decl.?; ok && resource_kind(decl) != .None {
			gen_resource_for_of(cg, s, decl)
			return
		}
	}
	cg_str(cg, "for")
	if s.await { cg_str(cg, " await") }
	cg_space(cg)
	cg_byte(cg, '(')
	if v, ok := s.left_decl.?; ok {
		gen_variable_declaration(cg, v, false)
	} else if v, ok := s.left_expr.?; ok {
		id, identifier := v^.(^Identifier)
		if !s.await && identifier && id != nil && id.name == "async" {
			// Plain for-of excludes the unescaped identifier in this position.
			cg_str(cg, "\\u0061sync")
		} else {
			gen_expression(cg, v, PREC_LOWEST)
		}
	}
	cg_str(cg, " of ")
	gen_expression(cg, s.right, PREC_ASSIGN)
	cg_close_comments(cg, get_statement_loc(s.body).start)
	cg_byte(cg, ')')
	cg_space(cg)
	gen_statement(cg, s.body^)
}

gen_with_statement :: proc(cg: ^Codegen, s: ^WithStatement) {
	cg_str(cg, "with")
	cg_space(cg)
	cg_byte(cg, '(')
	gen_expression(cg, s.object, PREC_LOWEST)
	cg_close_comments(cg, get_statement_loc(s.body).start)
	cg_byte(cg, ')')
	cg_space(cg)
	gen_statement(cg, s.body^)
}

gen_throw_statement :: proc(cg: ^Codegen, s: ^ThrowStatement) {
	codegen_hoist_comments(cg, loc_from_expr(s.argument).start, s.loc.start)
	cg_str(cg, "throw ")
	gen_expression(cg, s.argument, PREC_LOWEST)
	cg_byte(cg, ';')
}

gen_try_statement :: proc(cg: ^Codegen, s: ^TryStatement) {
	cg_str(cg, "try")
	cg_space(cg)
	block := s.block
	gen_block_statement(cg, &block)
	if h, ok := s.handler.?; ok {
		cg_space(cg)
		cg_str(cg, "catch")
		if p, pok := h.param.?; pok {
			cg_space(cg)
			cg_byte(cg, '(')
			gen_pattern(cg, p)
			cg_byte(cg, ')')
		}
		cg_space(cg)
		hb := h.body
		gen_block_statement(cg, &hb)
	}
	if fin, ok := s.finalizer.?; ok {
		cg_space(cg)
		cg_str(cg, "finally")
		cg_space(cg)
		gen_block_statement(cg, &fin)
	}
}

gen_function_declaration :: proc(cg: ^Codegen, s: ^FunctionDeclaration) {
	if len(cg.annotations) != 0 { codegen_emit_annotation(cg, s.loc.start, .No_Side_Effects) }
	// TS `declare function f(): void;` is a FunctionDeclaration with
	// declare=true and no body. The keyword must be preserved or the
	// regen loses its ambient marker (and a body-less function without
	// `declare` is a parse error).
	if s.declare && !cg.cfg.strip_types { cg_str(cg, "declare ") }
	name := ""
	if id, ok := s.id.?; ok { name = id.name }
	gen_function_expression_like(cg, s.async, s.generator, name, s.params[:], s.body, s.no_body, s.type_parameters, s.return_type, true)
}

gen_variable_declaration :: proc(
	cg: ^Codegen, s: ^VariableDeclaration, with_semicolon: bool, ctx: CodegenExpressionContext = {},
) {
	// TS `declare const X: T;` reaches codegen as a VariableDeclaration
	// with `declare = true` and no initializer. Emitting it without the
	// keyword regenerates `const X: T;`, which is an early error because
	// `const` requires an initializer outside of ambient context.
	if s.declare && !cg.cfg.strip_types { cg_str(cg, "declare ") }
	lower_resource := cg.cfg.lower_using && resource_kind(s) != .None
	if lower_resource && cg.resource_scope.name == "" {
		cg_strip_unsupported(cg, s.loc, "resource declaration requires a cleanup scope")
		return
	}
	// `using` ends at a line break. In a loop head no statement boundary has
	// printed the comments in front of the declaration yet.
	if cg.comment_next != CODEGEN_COMMENT_NONE {
		first := s.loc.start
		// A line break may separate `await` from `using`, but not `using`
		// from its binding: comments between the keywords go before both.
		if s.kind == .AwaitUsing { first = codegen_skip_trivia(cg.source, first + len("await")) }
		codegen_flush_comments(cg, first)
	}
	switch s.kind {
	case .Var:   cg_str(cg, "var")
	case .Let:   cg_str(cg, "let")
	case .Const: cg_str(cg, "const")
	case .Using: cg_str(cg, "const" if lower_resource else "using")
	case .AwaitUsing: cg_str(cg, "const" if lower_resource else "await using")
	}
	cg_hard_space(cg)
	gen_variable_declarators(cg, s, ctx, lower_resource)
	if with_semicolon { cg_byte(cg, ';') }
}

gen_variable_declarators :: proc(cg: ^Codegen, s: ^VariableDeclaration, ctx: CodegenExpressionContext, lower_resource: bool) {
	for i in 0..<len(s.declarations) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		d := s.declarations[i]
		gen_var_declarator_id(cg, d.id, d.definite)
		if init, ok := d.init.?; ok {
			cg_infix_operator(cg, "=")
			if lower_resource {
				codegen_resource_register(cg, resource_kind(s))
				name := ""
				if id, ok := d.id.(^Identifier); ok { name = id.name }
				gen_resource_named_value(cg, init, name)
				cg_byte(cg, ')')
			} else {
				gen_expression(cg, init, PREC_ASSIGN, ctx)
			}
		}
	}
}

gen_class_declaration :: proc(cg: ^Codegen, s: ^ClassDeclaration) {
	for d in s.decorators {
		gen_decorator(cg, d)
		cg_break_or_space(cg)
	}
	// TS ambient + abstract class modifiers. `declare class C { ... }`
	// and `abstract class C { ... }` both reach codegen as a
	// ClassDeclaration with the respective flag set. Forgetting either
	// drops the modifier and, for `declare`, regresses the AST shape
	// downstream consumers see.
	if s.declare  && !cg.cfg.strip_types { cg_str(cg, "declare ") }
	if s.abstract && !cg.cfg.strip_types { cg_str(cg, "abstract ") }
	name := ""
	if id, ok := s.id.?; ok { name = id.name }
	gen_class_like(cg, name, s.super_class, s.body, s.type_parameters, s.super_type_arguments, s.implements)
}

cg_name_is_quoted :: proc(cg: ^Codegen, start: u32) -> bool {
	if u64(start) >= u64(len(cg.source)) { return false }
	first := cg.source[start]
	return first == '\'' || first == '"'
}

gen_import_declaration :: proc(cg: ^Codegen, s: ^ImportDeclaration) {
	// Type-only imports (`import type ...`) are always elided under strip.
	if cg.cfg.strip_types && s.import_kind == .Type { return }
	cg_module_keyword(cg, "import ")
	if s.import_kind == .Type { cg_str(cg, "type ") }
	// Minified output still needs a separator after the phase keyword.
	if len(s.phase) > 0 { cg_str(cg, s.phase); cg_hard_space(cg) }
	first := true
	has_named_specifiers := false
	// Default + namespace specifiers (each appears at most once).
	for spec in s.specifiers {
		switch v in spec^ {
		case ImportDefaultSpecifier:
			if !first { cg_str(cg, ", ") }
			cg_str(cg, v.local.name)
			first = false
		case ImportNamespaceSpecifier:
			if !first { cg_str(cg, ", ") }
			cg_str(cg, "* as ")
			cg_str(cg, v.local.name)
			first = false
		case ImportSpecifier:
			has_named_specifiers = true
		}
	}
	named_open := false
	for spec in s.specifiers {
		v, ok := spec^.(ImportSpecifier)
		if !ok { continue }
		// A per-specifier type modifier precedes the imported name.
		type_only := v.loc.start < v.imported.loc.start
		if cg.cfg.strip_types && type_only { continue }
		if named_open {
			cg_str(cg, ", ")
		} else {
			if !first { cg_str(cg, ", ") }
			cg_byte(cg, '{')
			cg_space(cg)
			named_open = true
		}
		if cg.comment_next != CODEGEN_COMMENT_NONE { codegen_flush_comments(cg, v.loc.start) }
		if type_only { cg_str(cg, "type ") }
		quoted := cg_name_is_quoted(cg, v.imported.loc.start)
		if quoted {
			gen_string_quoted(cg, v.imported.name)
		} else {
			cg_str(cg, v.imported.name)
		}
		if quoted || v.imported.name != v.local.name {
			cg_str(cg, " as ")
			cg_str(cg, v.local.name)
		}
	}
	if named_open {
		cg_close_comments(cg, s.source.loc.start)
		cg_space(cg)
		cg_byte(cg, '}')
		first = false
	} else if has_named_specifiers || (first && s.import_kind == .Type) {
		// Keep the module request when type stripping leaves an empty clause.
		if !first { cg_str(cg, ", ") }
		cg_str(cg, "{}")
		first = false
	}
	if !first { cg_str(cg, " from ") }
	gen_string_quoted(cg, s.source.value)
	gen_import_attributes(cg, s.attributes)
	cg_byte(cg, ';')
}

// Emit `with { key: "value", ... }` import-attributes clause if any
// attributes are present. ES2025 import attributes (was: import assertions).
gen_import_attributes :: proc(cg: ^Codegen, attrs: [dynamic]ImportAttribute) {
	if len(attrs) == 0 { return }
	cg_str(cg, " with ")
	cg_byte(cg, '{')
	for i in 0..<len(attrs) {
		if i > 0 { cg_byte(cg, ',') }
		cg_space(cg)
		key := attrs[i].key
		if cg_name_is_quoted(cg, key.loc.start) {
			gen_string_quoted(cg, key.name)
		} else {
			cg_str(cg, key.name)
		}
		cg_byte(cg, ':')
		cg_space(cg)
		gen_string_quoted(cg, attrs[i].value.value)
	}
	cg_space(cg)
	cg_byte(cg, '}')
}

// Emit either side of `export { local as exported }`. ExportSpecifierName is
// `IdentifierName | ^StringLiteral` (ES2022 string-literal exports).
gen_export_specifier_name :: proc(cg: ^Codegen, n: ExportSpecifierName) {
	switch v in n {
	case IdentifierName:   cg_str(cg, v.name)
	case ^StringLiteral:   gen_string_literal(cg, v)
	}
}

// True when the two sides resolve to the same identifier (no `as`).
export_name_eq :: proc(a, b: ExportSpecifierName) -> bool {
	ai, aok := a.(IdentifierName)
	bi, bok := b.(IdentifierName)
	if aok && bok { return ai.name == bi.name }
	return false
}

// A declaration whose `export` wrapper disappears entirely under type
// stripping: an interface / type alias, or a `declare` function / var / class.
export_decl_is_erased :: proc(decl: Declaration) -> bool {
	#partial switch d in decl {
	case ^TSInterfaceDeclaration: return true
	case ^TSTypeAliasDeclaration: return true
	case ^FunctionDeclaration:    return d.declare || d.no_body
	case ^TSImportEqualsDeclaration: return d.import_kind == .Type
	case ^VariableDeclaration:    return d.declare
	case ^ClassDeclaration:       return d.declare
	}
	return false
}

gen_export_named_declaration :: proc(cg: ^Codegen, s: ^ExportNamedDeclaration) {
	// Erase type-only exports before emitting their keyword or annotation.
	if cg.cfg.strip_types {
		if s.export_kind == .Type { return }
		if alias := cg.runtime_scope.active_namespace; alias != "" {
			gen_runtime_namespace_export(cg, s, alias)
			return
		}
		if decl_ptr, ok := s.declaration.?; ok && decl_ptr != nil {
			if export_decl_is_erased(decl_ptr^) { return }
			if enum_decl, is_enum := decl_ptr^.(^TSEnumDeclaration); is_enum {
				gen_ts_enum_lowered(cg, enum_decl, exported = true)
				return
			}
			if namespace, is_namespace := decl_ptr^.(^TSModuleDeclaration); is_namespace {
				gen_ts_module_declaration_stripped(cg, namespace, exported = true)
				return
			}
		}
	}
	if len(cg.annotations) != 0 {
		if decl_ptr, ok := s.declaration.?; ok {
			codegen_emit_export_annotation(cg, s.loc.start, decl_ptr)
		}
	}
	cg_module_keyword(cg, "export ")
	// Declarations such as `export type X = T` print their own keyword.
	if s.export_kind == .Type {
		inner_supplies_type := false
		if decl_ptr, ok := s.declaration.?; ok && decl_ptr != nil {
			#partial switch _ in decl_ptr^ {
			case ^TSInterfaceDeclaration:    inner_supplies_type = true
			case ^TSTypeAliasDeclaration:    inner_supplies_type = true
			case ^TSEnumDeclaration:         inner_supplies_type = true
			case ^TSModuleDeclaration:       inner_supplies_type = true
			case ^FunctionDeclaration:       inner_supplies_type = true  // `declare function`
			case ^VariableDeclaration:       inner_supplies_type = true  // `declare const`
			case ^ClassDeclaration:          inner_supplies_type = true  // `declare class`
			}
		}
		if !inner_supplies_type { cg_str(cg, "type ") }
	}
	if decl_ptr, ok := s.declaration.?; ok {
		gen_statement(cg, decl_to_stmt(decl_ptr^))
		return
	}
	cg_byte(cg, '{')
	first := true
	for &sp in s.specifiers {
		type_only := export_specifier_is_type(&sp)
		if cg.cfg.strip_types && type_only { continue }
		if !first { cg_str(cg, ", ") } else { cg_space(cg) }
		first = false
		if cg.comment_next != CODEGEN_COMMENT_NONE { codegen_flush_comments(cg, sp.loc.start) }
		if type_only { cg_str(cg, "type ") }
		if export_name_eq(sp.local, sp.exported) {
			gen_export_specifier_name(cg, sp.local)
		} else {
			gen_export_specifier_name(cg, sp.local)
			cg_str(cg, " as ")
			gen_export_specifier_name(cg, sp.exported)
		}
	}
	if count := len(s.specifiers); count > 0 && cg.comment_next != CODEGEN_COMMENT_NONE {
		cg_close_comments(cg, codegen_skip_trivia(cg.source, s.specifiers[count - 1].loc.end))
	}
	cg_space(cg)
	cg_byte(cg, '}')
	if src, ok := s.source.?; ok {
		cg_str(cg, " from ")
		gen_string_quoted(cg, src.value)
		gen_import_attributes(cg, s.attributes)
	}
	cg_byte(cg, ';')
}

strip_default_export_is_erased :: proc(s: ^ExportDefaultDeclaration) -> bool {
	switch value in s.declaration^ {
	case ^Declaration:
		return export_decl_is_erased(value^)
	case ^Expression:
		if fn, ok := value^.(^FunctionExpression); ok { return fn.no_body }
	}
	return false
}

gen_export_default_declaration :: proc(cg: ^Codegen, s: ^ExportDefaultDeclaration) {
	if cg.cfg.strip_types && strip_default_export_is_erased(s) { return }
	if len(cg.annotations) != 0 {
		switch value in s.declaration^ {
		case ^Declaration:
			codegen_emit_export_annotation(cg, s.loc.start, value)
		case ^Expression:
			#partial switch _ in value^ {
			case ^FunctionExpression, ^ArrowFunctionExpression:
				codegen_emit_annotation(cg, s.loc.start, .No_Side_Effects)
			}
		}
	}
	cg_module_keyword(cg, "export default ")
	switch v in s.declaration^ {
	case ^Declaration:
		gen_statement(cg, decl_to_stmt(v^))
	case ^Expression:
		// An expression beginning with "function" or "class" must stay an
		// expression when reparsed, including when stripping TypeScript.
		group := expression_starts_with_ambiguous_token(cg, v, .Default_Export)
		if group { cg_byte(cg, '(') }
		gen_expression(cg, v, PREC_ASSIGN)
		if group { cg_byte(cg, ')') }
		cg_byte(cg, ';')
	}
}

gen_export_all_declaration :: proc(cg: ^Codegen, s: ^ExportAllDeclaration) {
	if cg.cfg.strip_types && s.export_kind == .Type { return }
	cg_module_keyword(cg, "export ")
	// `export type * from "x"` keeps the type-only marker on the
	// declaration's export_kind. Same drop bug as gen_export_named.
	if s.export_kind == .Type { cg_str(cg, "type ") }
	cg_str(cg, "* ")
	if name, ok := s.exported.?; ok {
		cg_str(cg, "as ")
		if cg_name_is_quoted(cg, name.loc.start) {
			gen_string_quoted(cg, name.name)
		} else {
			cg_str(cg, name.name)
		}
		cg_byte(cg, ' ')
	}
	cg_str(cg, "from ")
	gen_string_quoted(cg, s.source.value)
	gen_import_attributes(cg, s.attributes)
	cg_byte(cg, ';')
}

// ============================================================================
// TS declaration stubs — emit a marker so the build links cleanly.
// Real coverage is a follow-up; round-trip tests will skip TS-only files.
// ============================================================================

gen_ts_interface_declaration   :: proc(cg: ^Codegen, s: ^TSInterfaceDeclaration)   { gen_ts_interface_declaration_full(cg, s) }
gen_ts_type_alias_declaration  :: proc(cg: ^Codegen, s: ^TSTypeAliasDeclaration)   { gen_ts_type_alias_declaration_full(cg, s) }
gen_ts_enum_declaration        :: proc(cg: ^Codegen, s: ^TSEnumDeclaration)        { gen_ts_enum_declaration_full(cg, s) }
gen_ts_module_declaration      :: proc(cg: ^Codegen, s: ^TSModuleDeclaration)      { gen_ts_module_declaration_full(cg, s) }

gen_ts_import_equals           :: proc(cg: ^Codegen, s: ^TSImportEqualsDeclaration) { gen_ts_import_equals_full(cg, s) }
gen_ts_export_assignment       :: proc(cg: ^Codegen, s: ^TSExportAssignment)       { gen_ts_export_assignment_full(cg, s) }
gen_ts_namespace_export        :: proc(cg: ^Codegen, s: ^TSNamespaceExportDeclaration) { gen_ts_namespace_export_full(cg, s) }


// ============================================================================
// Codegen — shared helpers (patterns, function bodies, class bodies, TS types).
// ============================================================================

// gen_decorator emits `@Expr` with parens when the expression is not a
// bare DecoratorMemberExpression / DecoratorCallExpression. The legacy
// decorator grammar only allows `@Ident.foo.bar(args)` style chains
// bare; anything else — `@(foo + bar)`, `@(obj[key])`, `@(foo().bar)`,
// `@(arrow => x)` — must be wrapped, otherwise the regen reparses
// differently (or as a syntax error).
gen_decorator :: proc(cg: ^Codegen, d: Decorator) {
	cg_byte(cg, '@')
	if decorator_expr_is_bare(d.expression) {
		gen_expression(cg, d.expression, PREC_CALL)
		return
	}
	if d.expression != nil {
		loc := loc_from_expr(d.expression)
		// The decorator suffix parser does not retain grouping around
		// a parenthesized head, such as @(this.member)(arg).
		if loc.end == d.loc.end && u64(loc.start) < u64(len(cg.source)) && cg.source[loc.start] != '(' {
			gen_expression(cg, d.expression, PREC_LOWEST)
			return
		}
	}
	cg_byte(cg, '(')
	gen_expression(cg, d.expression, PREC_LOWEST)
	cg_byte(cg, ')')
}

// decorator_expr_is_bare reports whether `expr` is a member-chain or
// call-on-member-chain that fits the bare decorator grammar. Anything
// else needs `@(...)` parens.
decorator_expr_is_bare :: proc(expr: ^Expression) -> bool {
	if expr == nil { return false }
	cur := expr
	// Unwrap a leading CallExpression: `@foo.bar(args)` is allowed; the
	// callee must itself be a bare member chain.
	if ce, is_call := cur^.(^CallExpression); is_call {
		if ce.optional { return false }
		cur = ce.callee
	}
	// Now `cur` must be a bare member chain: Identifier, or a chain of
	// non-computed, non-optional MemberExpression ending in Identifier.
	for {
		#partial switch v in cur^ {
		case ^Identifier:
			return true
		case ^MemberExpression:
			if v.computed { return false }
			if v.optional { return false }
			cur = v.object
		case:
			return false
		}
	}
}

// ----------------------------------------------------------------------------
// Patterns (destructuring)
// ----------------------------------------------------------------------------

gen_pattern :: proc(cg: ^Codegen, p: Pattern, target := "") {
	if cg.comment_next != CODEGEN_COMMENT_NONE {
		codegen_flush_comments(cg, get_pattern_loc(p).start)
	}
	switch v in p {
	case ^Identifier:
		if target != "" { gen_runtime_property(cg, target, v.name) } else { gen_pattern_identifier(cg, v) }
	case ^ObjectPattern:      gen_object_pattern(cg, v, target)
	case ^ArrayPattern:       gen_array_pattern(cg, v, target)
	case ^AssignmentPattern:  gen_assignment_pattern(cg, v, target)
	case ^RestElement:        cg_str(cg, "..."); gen_pattern(cg, v.argument, target)
	case ^MemberExpression:   gen_member_expression(cg, v)
	}
}

gen_pattern_identifier :: proc(cg: ^Codegen, e: ^Identifier) {
	if len(cg.renamed) != 0 {
		if name, ok := cg.renamed[e.loc.start]; ok {
			if cg.sm != nil { sourcemap_record(cg.sm, u32(cg.pos), e.loc.start) }
			cg_str(cg, name)
			return
		}
	}
	cg_str(cg, e.name)
	if cg.cfg.strip_types { return }
	if e.optional { cg_byte(cg, '?') }
	if ta, ok := e.type_annotation.?; ok {
		cg_str(cg, ": ")
		gen_ts_type(cg, ta.type_annotation)
	}
}

// VariableDeclarator id emission. Like `gen_pattern`, but injects `!`
// between the identifier and its (optional) type annotation when the
// declarator carries TS `definite` (`var x!: T` definite-assignment
// assertion). The grammar only permits `!` after a bare Identifier, so
// the non-Identifier fallback is a safety net rather than valid syntax.
gen_var_declarator_id :: proc(cg: ^Codegen, id: Pattern, definite: bool) {
	if !definite || cg.cfg.strip_types {
		gen_pattern(cg, id)
		return
	}
	if id_node, ok := id.(^Identifier); ok {
		cg_str(cg, id_node.name)
		if id_node.optional { cg_byte(cg, '?') }
		cg_byte(cg, '!')
		if ta, ok2 := id_node.type_annotation.?; ok2 {
			cg_str(cg, ": ")
			gen_ts_type(cg, ta.type_annotation)
		}
		return
	}
	gen_pattern(cg, id)
	cg_byte(cg, '!')
}

gen_object_pattern :: proc(cg: ^Codegen, e: ^ObjectPattern, target := "") {
	cg_byte(cg, '{')
	if len(e.properties) == 0 {
		cg_byte(cg, '}')
	} else {
		cg_space(cg)
		for i in 0..<len(e.properties) {
			if i > 0 { cg_byte(cg, ','); cg_space(cg) }
			gen_object_pattern_property(cg, e.properties[i], target)
		}
		cg_close_comments(cg, codegen_pattern_close(e.loc, e.type_annotation))
		cg_space(cg)
		cg_byte(cg, '}')
	}
	// TS-position annotation lives on the ObjectPattern itself when the
	// pattern is not a bare Identifier. Mirror the Identifier branch in
	// gen_pattern_identifier so `function f({a, b}: Props)` round-trips.
	if cg.cfg.strip_types { return }
	if ta, ok := e.type_annotation.?; ok {
		cg_str(cg, ": ")
		gen_ts_type(cg, ta.type_annotation)
	}
}

gen_object_pattern_property :: proc(cg: ^Codegen, p: ObjectPatternProperty, target := "") {
	if cg.comment_next != CODEGEN_COMMENT_NONE { codegen_flush_comments(cg, p.loc.start) }
	if p.shorthand && target == "" {
		id := mangle_pattern_identifier(p.value) if len(cg.renamed) != 0 else nil
		if id == nil || cg.renamed[id.loc.start] == "" {
			gen_pattern(cg, p.value)
			return
		}
	}
	if key, ok := p.key.?; ok {
		if p.computed { cg_byte(cg, '[') }
		gen_object_pattern_key(cg, key)
		if p.computed { cg_byte(cg, ']') }
		cg_byte(cg, ':')
		cg_space(cg)
	}
	gen_pattern(cg, p.value, target)
}

gen_object_pattern_key :: proc(cg: ^Codegen, k: ObjectPatternPropertyKey) {
	switch v in k {
	case IdentifierName:   cg_str(cg, v.name)
	case ^StringLiteral:   gen_string_literal(cg, v)
	case ^NumericLiteral:  gen_numeric_literal(cg, v)
	case ^Expression:      gen_expression(cg, v, PREC_ASSIGN)
	}
}

gen_array_pattern :: proc(cg: ^Codegen, e: ^ArrayPattern, target := "") {
	cg_byte(cg, '[')
	for i in 0..<len(e.elements) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		if el, ok := e.elements[i].?; ok {
			gen_pattern(cg, el, target)
		}
	}
	// Preserve a trailing hole: in `[a, ,]` the last comma is the
	// element separator, not the elision marker, so the array has 2
	// elements. Without the extra comma we would emit `[a, ]` which
	// reparses as `[a]` and silently drops the hole.
	n := len(e.elements)
	if n > 0 {
		if _, ok := e.elements[n-1].?; !ok {
			cg_byte(cg, ',')
		}
	}
	cg_close_comments(cg, codegen_pattern_close(e.loc, e.type_annotation))
	cg_byte(cg, ']')
	// Same TS-position annotation as ObjectPattern: `function
	// f([a, b]: number[])` carries `: number[]` on the ArrayPattern.
	if cg.cfg.strip_types { return }
	if ta, ok := e.type_annotation.?; ok {
		cg_str(cg, ": ")
		gen_ts_type(cg, ta.type_annotation)
	}
}

// A destructuring pattern's span includes its type annotation. Comments in
// the annotation stay there; only those before it are inside the brackets.
codegen_pattern_close :: proc(loc: Loc, annotation: Maybe(^TSTypeAnnotation)) -> u32 {
	if typed, ok := annotation.?; ok && typed != nil { return typed.loc.start }
	return loc.end
}

gen_assignment_pattern :: proc(cg: ^Codegen, e: ^AssignmentPattern, target := "") {
	gen_pattern(cg, e.left, target)
	if cg.declaration_emit != nil { return }
	cg_infix_operator(cg, "=")
	gen_expression(cg, e.right, PREC_ASSIGN)
}

// ----------------------------------------------------------------------------
// Function shared
// ----------------------------------------------------------------------------

gen_function_param :: proc(cg: ^Codegen, p: FunctionParameter) {
	// A parameter-property modifier ends at a line break, so comments
	// between it and the name go in front of the modifier.
	if cg.comment_next != CODEGEN_COMMENT_NONE {
		codegen_flush_comments(cg, get_pattern_loc(p.pattern).start)
	}
	// Accessibility / readonly / override / parameter properties — emit
	// the minimum keywords so the output still parses; full TS shape is a
	// follow-up.
	if cg.cfg.strip_types {
		// Parameter properties are now lowered: the accessibility/readonly
		// keywords are stripped and `this.x = x;` is injected into the body
		// by gen_function_params_and_body. Just emit the bare parameter.
	} else {
		switch p.accessibility {
		case .None:      // nothing
		case .Public:    cg_str(cg, "public ")
		case .Private:   cg_str(cg, "private ")
		case .Protected: cg_str(cg, "protected ")
		}
		if p.override_ { cg_str(cg, "override ") }
		if p.readonly { cg_str(cg, "readonly ") }
	}
	gen_pattern(cg, p.pattern)
	if d, ok := p.default_val.?; ok {
		cg_infix_operator(cg, "=")
		gen_expression(cg, d, PREC_ASSIGN)
	}
}

gen_function_expression_like :: proc(
	cg: ^Codegen,
	async, generator: bool,
	name: string,
	params: []FunctionParameter,
	body: FunctionBody,
	no_body: bool,
	type_parameters: Maybe(^TSTypeParameterDeclaration),
	return_type: Maybe(^TSTypeAnnotation),
	is_decl: bool,
) {
	if async { cg_str(cg, "async ") }
	cg_str(cg, "function")
	if generator { cg_byte(cg, '*') }
	if len(name) > 0 {
		cg_hard_space(cg)
		cg_str(cg, name)
	}
	gen_function_params_and_body(cg, async, generator, params, body, no_body, type_parameters, return_type)
}

gen_function_params_and_body :: proc(
	cg: ^Codegen,
	async, generator: bool,
	params: []FunctionParameter,
	body: FunctionBody,
	no_body: bool,
	type_parameters: Maybe(^TSTypeParameterDeclaration),
	return_type: Maybe(^TSTypeAnnotation),
	constructor: ConstructorKind = .None,
) {
	outer_properties := cg.param_properties_after_super
	// An arrow inherits its enclosing constructor's receiver. Ordinary
	// functions and methods establish their own receiver, including in defaults.
	outer_omit_self := cg.jsx_omit_self
	cg.jsx_omit_self = constructor == .Derived
	defer cg.jsx_omit_self = outer_omit_self
	cg.param_properties_after_super = nil
	defer cg.param_properties_after_super = outer_properties
	gen_ts_type_parameter_declaration(cg, type_parameters)
	cg_byte(cg, '(')
	first_param := 0
	if cg.cfg.strip_types && len(params) > 0 {
		if id, ok := params[0].pattern.(^Identifier); ok && id.name == "this" {
			first_param = 1
		}
	}
	for i in first_param..<len(params) {
		if i > first_param { cg_byte(cg, ','); cg_space(cg) }
		gen_function_param(cg, params[i])
	}
	if len(params) > 0 && cg.comment_next != CODEGEN_COMMENT_NONE {
		cg_close_comments(cg, codegen_skip_trivia(cg.source, params[len(params) - 1].loc.end))
	}
	cg_byte(cg, ')')
	if rt, ok := return_type.?; ok && !cg.cfg.strip_types {
		cg_str(cg, ": ")
		gen_ts_type(cg, rt.type_annotation)
	}
	if no_body { cg_byte(cg, ';'); return }
	cg_close_comments(cg, body.loc.start)
	cg_space(cg)
	cg_byte(cg, '{')
	properties := codegen_parameter_properties(cg, params, constructor)
	if constructor == .Derived { cg.param_properties_after_super = properties[:] }
	comments := codegen_comments_in_body(cg, body.loc)
	if len(body.body) == 0 && len(properties) == 0 && !codegen_has_ordinary_comments(comments) { cg_byte(cg, '}'); return }
	cg_newline(cg)
	cg.depth += 1
	codegen_emit_leading_comments(cg, body.body[:], body.loc.start, body.loc.end)
	directive_count := min(len(body.directives), len(body.body))
	for i in 0..<directive_count {
		gen_statement_list_entry(cg, body.body[:], i)
		codegen_end_item_line(cg, body.body[:], i, body.loc.end)
	}
	if constructor == .Base {
		for name in properties {
			gen_parameter_property_assignment(cg, name)
			cg_byte(cg, ';')
			cg_newline(cg)
		}
	}
	kind := resource_list_kind(cg, body.body[directive_count:])
	outer := codegen_resource_open(cg, kind)
	for i in directive_count..<len(body.body) {
		gen_statement_list_entry(cg, body.body[:], i)
		codegen_end_item_line(cg, body.body[:], i, body.loc.end)
	}
	codegen_resource_close(cg, kind, outer)
	cg.depth -= 1
	cg_byte(cg, '}')
}

codegen_parameter_properties :: proc(cg: ^Codegen, params: []FunctionParameter, constructor: ConstructorKind) -> [dynamic]string {
	properties: [dynamic]string
	if !cg.cfg.strip_types || constructor == .None { return properties }
	properties.allocator = context.temp_allocator
	for param in params {
		if param.accessibility == .None && !param.readonly && !param.override_ { continue }
		if id, ok := param.pattern.(^Identifier); ok && id != nil {
			append(&properties, id.name)
		}
	}
	return properties
}

gen_parameter_property_assignment :: proc(cg: ^Codegen, name: string) {
	cg_str(cg, "this.")
	cg_str(cg, name)
	cg_infix_operator(cg, "=")
	cg_str(cg, name)
}

// ----------------------------------------------------------------------------
// Class shared
// ----------------------------------------------------------------------------

gen_class_like :: proc(
	cg: ^Codegen,
	name: string,
	super_class: Maybe(^Expression),
	body: ClassBody,
	type_parameters: Maybe(^TSTypeParameterDeclaration),
	super_type_arguments: Maybe(^TSTypeParameterInstantiation),
	implements_list: [dynamic]TSInterfaceHeritage,
) {
	_ = super_type_arguments
	cg_str(cg, "class")
	if len(name) > 0 { cg_hard_space(cg); cg_str(cg, name) }
	gen_ts_type_parameter_declaration(cg, type_parameters)
	if sc, ok := super_class.?; ok {
		cg_str(cg, " extends ")
		gen_expression(cg, sc, PREC_CALL)
		gen_ts_type_arguments(cg, super_type_arguments)
	}
	if len(implements_list) > 0 && !cg.cfg.strip_types {
		cg_str(cg, " implements ")
		for i in 0..<len(implements_list) {
			if i > 0 { cg_byte(cg, ','); cg_space(cg) }
			gen_expression(cg, implements_list[i].expression, PREC_CALL)
			gen_ts_type_arguments(cg, implements_list[i].type_parameters)
		}
	}
	cg_space(cg)
	gen_class_body(cg, body, super_class != nil)
}

gen_class_body :: proc(cg: ^Codegen, body: ClassBody, derived: bool) {
	if cg.comment_next < body.loc.start {
		// The caller has already written the space before the brace.
		codegen_flush_comments(cg, body.loc.start)
	}
	cg_byte(cg, '{')
	comments := codegen_comments_in_body(cg, body.loc)
	proto_name := cg.resource_proto_class == body.loc.start
	if !proto_name && len(body.body) == 0 && !codegen_has_ordinary_comments(comments) { cg_byte(cg, '}'); return }
	cg_newline(cg)
	cg.depth += 1
	if proto_name {
		// Object literals reserve __proto__ as a setter. Install the inferred
		// name before static fields, preserving class methods and accessors.
		cg_str(cg, "static {const O = ({}).constructor; if (O.getOwnPropertyDescriptor(this,'name').value === '') O.defineProperty(this,'name',{value:'__proto__'});}")
		cg_newline(cg)
	}
	codegen_emit_leading_comments(cg, body.body[:], body.loc.start, body.loc.end)
	for el, i in body.body {
		erased := cg.cfg.strip_types && class_element_erased(el)
		if !erased {
			// Comments that share the member's line come before its mapping.
			if cg.comment_next < el.loc.start { codegen_flush_comments(cg, el.loc.start) }
			if cg.sm != nil {
				cg_indent(cg)
				cg_record_class_element_mapping(cg, &body.body[i])
			}
			gen_class_element(cg, el, derived)
		}
		codegen_end_item_line(cg, body.body[:], i, body.loc.end, erased)
	}
	cg.depth -= 1
	cg_byte(cg, '}')
}

// A class member that type-stripping erases entirely because it carries no
// runtime: a declared field, an abstract member, or a bodyless method / constructor (a TS
// overload signature or ambient method declaration).
class_element_erased :: proc(el: ClassElement) -> bool {
	if el.kind == .IndexSignature { return true }
	if el.declare { return true }
	if el.abstract { return true }
	#partial switch el.kind {
	case .Method, .Constructor:
		if v, ok := el.value.?; ok {
			if fn, is_fn := v.(^FunctionExpression); is_fn {
				return fn.no_body
			}
		}
	}
	return false
}

gen_class_element :: proc(cg: ^Codegen, el: ClassElement, derived: bool) {
	for d in el.decorators {
		gen_decorator(cg, d)
		cg_break_or_space(cg)
	}
	// `async`, `accessor` and the TypeScript modifiers end at a line break.
	// A comment that followed the decorators on their own line stays in front
	// of the first modifier instead of drifting behind it.
	if cg.comment_next != CODEGEN_COMMENT_NONE {
		first := el.loc.start
		if count := len(el.decorators); count > 0 {
			first = codegen_skip_trivia(cg.source, el.decorators[count - 1].loc.end)
		}
		codegen_flush_comments(cg, first)
	}
	if el.declare { cg_str(cg, "declare ") }
	switch el.accessibility {
	case .None:      // nothing
	case .Public:    if !cg.cfg.strip_types { cg_str(cg, "public ") }
	case .Private:   if !cg.cfg.strip_types { cg_str(cg, "private ") }
	case .Protected: if !cg.cfg.strip_types { cg_str(cg, "protected ") }
	}
	if el.abstract  && !cg.cfg.strip_types { cg_str(cg, "abstract ") }
	if el.static    { cg_str(cg, "static ") }
	if el.override_ && !cg.cfg.strip_types { cg_str(cg, "override ") }
	if el.readonly  && !cg.cfg.strip_types { cg_str(cg, "readonly ") }
	if el.is_accessor { cg_str(cg, "accessor ") }
	switch el.kind {
	case .Method, .Field:
		raw_val, val_ok := el.value.?
		fn: ^FunctionExpression
		is_method := false
		if val_ok && el.kind == .Method {
			fn, is_method = raw_val.(^FunctionExpression)
		}
		if is_method {
			if fn.async { cg_str(cg, "async ") }
			if fn.generator { cg_byte(cg, '*') }
		}
		if el.computed { cg_byte(cg, '[') }
		gen_expression(cg, el.key, PREC_ASSIGN)
		if el.computed { cg_close_key(cg, el.key); cg_byte(cg, ']') }
		if el.optional && !cg.cfg.strip_types { cg_byte(cg, '?') }
		if el.definite && !cg.cfg.strip_types { cg_byte(cg, '!') }
		if ta, ok := el.typing.annotation.?; ok && !cg.cfg.strip_types {
			cg_str(cg, ": ")
			gen_ts_type(cg, ta.type_annotation)
		}
		if is_method {
			gen_function_params_and_body(cg, fn.async, fn.generator, fn.params[:], fn.body, fn.no_body, fn.type_parameters, fn.return_type)
			return
		}
		// PropertyDefinition path. Optional initializer + terminating `;`.
		if val_ok {
			outer_omit_self := cg.jsx_omit_self
			cg.jsx_omit_self = false
			defer cg.jsx_omit_self = outer_omit_self
			cg_infix_operator(cg, "=")
			gen_expression(cg, raw_val, PREC_ASSIGN)
		}
		cg_byte(cg, ';')
	case .Get:
		cg_str(cg, "get ")
		if el.computed { cg_byte(cg, '[') }
		gen_expression(cg, el.key, PREC_ASSIGN)
		if el.computed { cg_close_key(cg, el.key); cg_byte(cg, ']') }
		if val, ok := el.value.?; ok {
			if fn, is_fn := val.(^FunctionExpression); is_fn {
				gen_function_params_and_body(cg, false, false, fn.params[:], fn.body, fn.no_body, nil, fn.return_type)
				return
			}
		}
		cg_str(cg, "() {}")
	case .Set:
		cg_str(cg, "set ")
		if el.computed { cg_byte(cg, '[') }
		gen_expression(cg, el.key, PREC_ASSIGN)
		if el.computed { cg_close_key(cg, el.key); cg_byte(cg, ']') }
		if val, ok := el.value.?; ok {
			if fn, is_fn := val.(^FunctionExpression); is_fn {
				gen_function_params_and_body(cg, false, false, fn.params[:], fn.body, fn.no_body, nil, fn.return_type)
				return
			}
		}
		cg_str(cg, "() {}")
	case .Constructor:
		gen_expression(cg, el.key, PREC_ASSIGN)
		if val, ok := el.value.?; ok {
			if fn, is_fn := val.(^FunctionExpression); is_fn {
				constructor := derived ? ConstructorKind.Derived : ConstructorKind.Base
				gen_function_params_and_body(cg, fn.async, fn.generator, fn.params[:], fn.body, fn.no_body, fn.type_parameters, fn.return_type, constructor)
				return
			}
		}
		cg_str(cg, "() {}")
	case .IndexSignature:
		gen_ts_signature(cg, el.typing.index_signature)
		cg_byte(cg, ';')
	case .StaticBlock:
		outer_omit_self := cg.jsx_omit_self
		cg.jsx_omit_self = false
		defer cg.jsx_omit_self = outer_omit_self
		cg_str(cg, "static ")
		if v, ok := el.value.?; ok {
			if fn, is_fn := v.(^FunctionExpression); is_fn {
				gen_statement_block(cg, fn.body.body[:], fn.body.loc)
				return
			}
		}
		cg_str(cg, "{}")
	}
}

// ----------------------------------------------------------------------------
// Declaration -> Statement conversion for ExportNamedDeclaration.declaration.
// ----------------------------------------------------------------------------

decl_to_stmt :: proc(d: Declaration) -> Statement {
	switch v in d {
	case ^FunctionDeclaration:        return v
	case ^VariableDeclaration:        return v
	case ^ClassDeclaration:           return v
	case ^ImportDeclaration:          return v
	case ^ExportNamedDeclaration:     return v
	case ^ExportDefaultDeclaration:   return v
	case ^ExportAllDeclaration:       return v
	case ^TSInterfaceDeclaration:     return v
	case ^TSTypeAliasDeclaration:     return v
	case ^TSEnumDeclaration:          return v
	case ^TSModuleDeclaration:        return v
	case ^TSImportEqualsDeclaration:  return v
	}
	return nil
}

// ----------------------------------------------------------------------------
// TS types — minimal coverage so TypeScript files round-trip without crash.
// ----------------------------------------------------------------------------

gen_ts_type :: proc(cg: ^Codegen, ty: ^TSType) {
	if ty == nil { cg_str(cg, "any"); return }
	if cg.declaration_emit != nil { dts_track_type(cg.declaration_emit, ty) }
	if cg.comment_next != CODEGEN_COMMENT_NONE {
		codegen_flush_comments(cg, get_ts_type_loc(ty).start)
	}
	switch v in ty^ {
	case ^TSKeywordType:      cg_str(cg, TS_KEYWORD_SOURCE[v.kind])
	case ^TSTypeReference:
		gen_expression(cg, v.type_name, PREC_CALL)
		gen_ts_type_arguments(cg, v.type_parameters)
	case ^TSUnionType:
		if len(v.types) == 1 { cg_str(cg, "| ") }
		for i in 0..<len(v.types) {
			if i > 0 { cg_str(cg, " | ") }
			gen_ts_type(cg, v.types[i])
		}
	case ^TSIntersectionType:
		if len(v.types) == 1 { cg_str(cg, "& ") }
		for i in 0..<len(v.types) {
			if i > 0 { cg_str(cg, " & ") }
			gen_ts_type(cg, v.types[i])
		}
	case ^TSArrayType:
		gen_ts_type(cg, v.element_type)
		cg_str(cg, "[]")
	case ^TSTupleType:
		cg_byte(cg, '[')
		for i in 0..<len(v.element_types) {
			if i > 0 { cg_byte(cg, ','); cg_space(cg) }
			gen_ts_type(cg, v.element_types[i])
		}
		cg_close_comments(cg, v.loc.end)
		cg_byte(cg, ']')
	case ^TSFunctionType:        gen_ts_function_type(cg, v)
	case ^TSConstructorType:     gen_ts_constructor_type(cg, v)
	case ^TSTypeLiteral:         gen_ts_type_literal(cg, v)
	case ^TSConditionalType:     gen_ts_conditional_type(cg, v)
	case ^TSInferType:           gen_ts_infer_type(cg, v)
	case ^TSTypeQuery:           gen_ts_type_query(cg, v)
	case ^TSTypeOperator:        gen_ts_type_operator(cg, v)
	case ^TSIndexedAccessType:   gen_ts_indexed_access_type(cg, v)
	case ^TSMappedType:          gen_ts_mapped_type(cg, v)
	case ^TSLiteralType:         gen_ts_literal_type(cg, v)
	case ^TSTemplateLiteralType: gen_ts_template_literal_type(cg, v)
	case ^TSParenthesizedType:
		cg_byte(cg, '(')
		gen_ts_type(cg, v.type_annotation)
		cg_close_comments(cg, v.loc.end)
		cg_byte(cg, ')')
	case ^TSRestType:
		cg_str(cg, "...")
		gen_ts_type(cg, v.type_annotation)
	case ^TSOptionalType:
		gen_ts_type(cg, v.type_annotation)
		cg_byte(cg, '?')
	case ^TSNamedTupleMember:
		element_type := v.element_type
		// A named rest element stores the rest wrapper around its type.
		// The printer puts the spread before the label.
		if element_type != nil {
			if rest, ok := element_type^.(^TSRestType); ok && rest != nil {
				cg_str(cg, "...")
				element_type = rest.type_annotation
			}
		}
		cg_str(cg, v.label.name)
		if v.optional { cg_byte(cg, '?') }
		cg_str(cg, ": ")
		gen_ts_type(cg, element_type)
	case ^TSTypePredicate:    gen_ts_type_predicate(cg, v)
	case ^TSImportType:       gen_ts_import_type_full(cg, v)
	}
}


// ============================================================================
// Codegen — expression-side per-node implementations.
// ============================================================================


// ----------------------------------------------------------------------------
// Literals
// ----------------------------------------------------------------------------

gen_numeric_literal :: proc(cg: ^Codegen, e: ^NumericLiteral) {
	if len(e.raw) > 0 { cg_str(cg, e.raw); return }
	buf: [64]byte
	s := fmt.bprintf(buf[:], "%g", e.value)
	cg_str(cg, s)
}

gen_bigint_literal :: proc(cg: ^Codegen, e: ^BigIntLiteral) {
	if len(e.raw) > 0 { cg_str(cg, e.raw); return }
	cg_str(cg, e.value)
	cg_byte(cg, 'n')
}

gen_regexp_literal :: proc(cg: ^Codegen, e: ^RegExpLiteral) {
	cg_byte(cg, '/')
	cg_str(cg, e.pattern)
	cg_byte(cg, '/')
	cg_str(cg, e.flags)
}

gen_string_literal :: proc(cg: ^Codegen, e: ^StringLiteral) {
	if len(e.raw) > 0 { cg_str(cg, e.raw); return }
	gen_string_quoted(cg, e.value)
}

// Re-quote an arbitrary string as a JS string literal (double-quoted).
gen_string_quoted :: proc(cg: ^Codegen, s: string, suffix: string = "") {
	cg_byte(cg, '"')
	gen_string_content(cg, s)
	if suffix != "" { gen_string_content(cg, suffix) }
	cg_byte(cg, '"')
}

gen_string_content :: proc(cg: ^Codegen, s: string) {
	for i in 0..<len(s) {
		c := s[i]
		switch c {
		case '"':  cg_byte(cg, '\\'); cg_byte(cg, '"')
		case '\\': cg_byte(cg, '\\'); cg_byte(cg, '\\')
		case '\n': cg_byte(cg, '\\'); cg_byte(cg, 'n')
		case '\r': cg_byte(cg, '\\'); cg_byte(cg, 'r')
		case '\t': cg_byte(cg, '\\'); cg_byte(cg, 't')
		case:
			if c < 0x20 {
				tmp: [8]byte
				esc := fmt.bprintf(tmp[:], "\\u%04x", c)
				cg_str(cg, esc)
			} else {
				cg_byte(cg, c)
			}
		}
	}
}

gen_template_literal :: proc(cg: ^Codegen, e: ^TemplateLiteral) {
	cg_byte(cg, '`')
	for i in 0..<len(e.quasis) {
		cg_str(cg, e.quasis[i].raw)
		if i < len(e.expressions) {
			cg_str(cg, "${")
			gen_expression(cg, e.expressions[i], PREC_LOWEST)
			if i + 1 < len(e.quasis) { cg_close_comments(cg, e.quasis[i + 1].loc.start) }
			cg_byte(cg, '}')
		}
	}
	cg_byte(cg, '`')
}

gen_tagged_template :: proc(cg: ^Codegen, e: ^TaggedTemplateExpression) {
	gen_chain_operand(cg, e.tag)
	gen_expression(cg, e.quasi, PREC_CALL)
}

// ----------------------------------------------------------------------------
// Compound expressions
// ----------------------------------------------------------------------------

gen_array_expression :: proc(cg: ^Codegen, e: ^ArrayExpression) {
	cg_byte(cg, '[')
	if cg.comment_next < e.loc.end && gen_commented_array(cg, e) {
		cg_byte(cg, ']')
		return
	}
	for i in 0..<len(e.elements) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		if el, ok := e.elements[i].?; ok {
			gen_expression(cg, el, PREC_ASSIGN)
		}
	}
	// Preserve a trailing hole: `[1, ,]` is a 2-element array (1 + hole),
	// but `[1, ]` reparses as `[1]`. Emit the extra comma so the hole
	// survives the round-trip.
	n := len(e.elements)
	if n > 0 {
		if _, ok := e.elements[n-1].?; !ok {
			cg_byte(cg, ',')
		}
	}
	cg_close_comments(cg, e.loc.end)
	cg_byte(cg, ']')
}

// Comments between elements read best with one element per line. A hole has
// no span to hang a comment on, so arrays with holes keep the compact form.
gen_commented_array :: proc(cg: ^Codegen, e: ^ArrayExpression) -> bool {
	for element in e.elements {
		if _, present := element.?; !present { return false }
	}
	// A present Maybe(^Expression) has the representation of its pointer.
	#assert(size_of(Maybe(^Expression)) == size_of(^Expression))
	elements := transmute([]^Expression)e.elements[:]
	if !codegen_has_list_comments(cg, elements, e.loc.end) { return false }
	gen_commented_list(cg, elements, e.loc)
	return true
}

gen_object_expression :: proc(cg: ^Codegen, e: ^ObjectExpression) {
	cg_byte(cg, '{')
	if codegen_has_list_comments(cg, e.properties[:], e.loc.end) {
		gen_commented_list(cg, e.properties[:], e.loc)
		cg_byte(cg, '}')
		return
	}
	if len(e.properties) == 0 {
		cg_close_comments(cg, e.loc.end)
		cg_byte(cg, '}')
		return
	}
	cg_space(cg)
	for i in 0..<len(e.properties) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_property(cg, e.properties[i])
	}
	cg_close_comments(cg, e.loc.end)
	cg_space(cg)
	cg_byte(cg, '}')
}

gen_commented_list :: proc(cg: ^Codegen, items: []$T, loc: Loc) {
	cg_newline(cg)
	cg.depth += 1
	codegen_emit_leading_comments(cg, items, loc.start, loc.end)
	for item, index in items {
		when T == Property { gen_property(cg, item) }
		else { gen_expression(cg, item, PREC_ASSIGN) }
		if index + 1 < len(items) { cg_byte(cg, ',') }
		codegen_end_item_line(cg, items, index, loc.end)
	}
	cg.depth -= 1
}

gen_property :: proc(cg: ^Codegen, p: Property) {
	if _, ok := p.value.(^SpreadElement); ok {
		gen_expression(cg, p.value, PREC_ASSIGN)
		return
	}
	// `async` ends at a line break: comments before the property precede it.
	if cg.comment_next != CODEGEN_COMMENT_NONE { codegen_flush_comments(cg, p.loc.start) }
	switch p.kind {
	case .Init:
		if p.shorthand {
			value := p.value
			if fallback, ok := value.(^AssignmentExpression); ok { value = fallback.left }
			if identifier, ok := value.(^Identifier); ok && (codegen_property_reference(cg, identifier) != "" || (len(cg.renamed) != 0 && cg.renamed[identifier.loc.start] != "")) {
				cg_str(cg, identifier.name)
				cg_byte(cg, ':')
				cg_space(cg)
			}
			gen_expression(cg, p.value, PREC_ASSIGN)
			return
		}
		if p.computed { cg_byte(cg, '[') }
		gen_expression(cg, p.key, PREC_ASSIGN)
		if p.computed { cg_close_key(cg, p.key); cg_byte(cg, ']') }
		cg_byte(cg, ':')
		cg_space(cg)
		gen_expression(cg, p.value, PREC_ASSIGN)
	case .Method:
		fn_for_prefix, _ := p.value.(^FunctionExpression)
		if fn_for_prefix != nil {
			if fn_for_prefix.async { cg_str(cg, "async ") }
			if fn_for_prefix.generator { cg_byte(cg, '*') }
		}
		if p.computed { cg_byte(cg, '[') }
		gen_expression(cg, p.key, PREC_ASSIGN)
		if p.computed { cg_close_key(cg, p.key); cg_byte(cg, ']') }
		if fn_for_prefix != nil {
			gen_function_params_and_body(cg, fn_for_prefix.async, fn_for_prefix.generator, fn_for_prefix.params[:], fn_for_prefix.body, fn_for_prefix.no_body, fn_for_prefix.type_parameters, fn_for_prefix.return_type)
		}
	case .Get:
		cg_str(cg, "get ")
		if p.computed { cg_byte(cg, '[') }
		gen_expression(cg, p.key, PREC_ASSIGN)
		if p.computed { cg_close_key(cg, p.key); cg_byte(cg, ']') }
		if fn, is_fn := p.value.(^FunctionExpression); is_fn {
			gen_function_params_and_body(cg, false, false, fn.params[:], fn.body, fn.no_body, nil, fn.return_type)
		}
	case .Set:
		cg_str(cg, "set ")
		if p.computed { cg_byte(cg, '[') }
		gen_expression(cg, p.key, PREC_ASSIGN)
		if p.computed { cg_close_key(cg, p.key); cg_byte(cg, ']') }
		if fn, is_fn := p.value.(^FunctionExpression); is_fn {
			gen_function_params_and_body(cg, false, false, fn.params[:], fn.body, fn.no_body, nil, fn.return_type)
		}
	}
}

gen_function_expression :: proc(cg: ^Codegen, e: ^FunctionExpression) {
	name := ""
	if id, ok := e.id.?; ok { name = id.name }
	gen_function_expression_like(cg, e.async, e.generator, name, e.params[:], e.body, e.no_body, e.type_parameters, e.return_type, false)
}

gen_arrow_function :: proc(cg: ^Codegen, e: ^ArrowFunctionExpression, ctx: CodegenExpressionContext) {
	if e.async { cg_str(cg, "async ") }
	// TS generic arrow: `<T>(x: T) => x`. Without this, the type-parameter
	// list is silently erased, which breaks both round-trip equality and
	// the semantic meaning when a downstream consumer reads typeParameters
	// off the AST and we round-trip via codegen.
	gen_ts_type_parameter_declaration(cg, e.type_parameters)
	cg_byte(cg, '(')
	for i in 0..<len(e.params) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_function_param(cg, e.params[i])
	}
	if len(e.params) > 0 && cg.comment_next != CODEGEN_COMMENT_NONE {
		cg_close_comments(cg, codegen_skip_trivia(cg.source, e.params[len(e.params) - 1].loc.end))
	}
	cg_byte(cg, ')')
	if rt, ok := e.return_type.?; ok && !cg.cfg.strip_types {
		cg_str(cg, ": ")
		gen_ts_type(cg, rt.type_annotation)
	}
	cg_space(cg)
	cg_str(cg, "=>")
	cg_space(cg)
	switch body in e.body {
	case ^Expression:
		// A leading object literal can also be the receiver of a member access.
		if expression_starts_with_ambiguous_token(cg, body, .Arrow_Body) {
			cg_byte(cg, '(')
			gen_expression(cg, body, PREC_ASSIGN)
			cg_byte(cg, ')')
		} else {
			gen_expression(cg, body, PREC_ASSIGN, ctx)
		}
	case ^BlockStatement: gen_block_statement(cg, body)
	}
}

gen_class_expression :: proc(cg: ^Codegen, e: ^ClassExpression) {
	// Class expressions can carry decorators in the legacy decorators
	// proposal (`var x = @dec class Foo {}`). Emit them in source order
	// before the `class` keyword; omitting them drops information that
	// breaks AST round-trip.
	for d in e.decorators {
		gen_decorator(cg, d)
		cg_hard_space(cg)
	}
	name := ""
	if id, ok := e.id.?; ok { name = id.name }
	gen_class_like(cg, name, e.super_class, e.body, e.type_parameters, e.super_type_arguments, e.implements)
}

gen_member_expression :: proc(cg: ^Codegen, e: ^MemberExpression) {
	if cg.cfg.optimize_const_enums && gen_inlined_enum_member(cg, e) { return }
	obj_start := cg.pos
	gen_chain_operand(cg, e.object)
	// A chain broken over lines often carries a comment before the dot.
	// Comments inside the brackets of a computed access stay inside them.
	if cg.comment_next != CODEGEN_COMMENT_NONE && !e.computed {
		codegen_flush_comments(cg, loc_from_expr(e.property).start)
	}
	if e.computed {
		if e.optional { cg_str(cg, "?.") }
		cg_byte(cg, '[')
		gen_expression(cg, e.property, PREC_LOWEST)
		cg_close_comments(cg, e.loc.end)
		cg_byte(cg, ']')
	} else {
		// A bare decimal-integer object (`1`, `100`) immediately
		// followed by `.` re-lexes as a float (`1.`), so `1.toString()`
		// is a SyntaxError. Emit a separating space so the member `.`
		// stays a member `.`. Hex/octal/binary/exponent/float forms
		// already carry a disambiguating char and re-lex fine. The
		// optional `?.` form is also safe — the `?` terminates the
		// number. ECMA-262 §12.9.3 / §13.3.
		if !e.optional {
			if _, is_num := codegen_runtime_expression(cg, e.object)^.(^NumericLiteral); is_num {
				bare_int := cg.pos > obj_start
				for i in obj_start..<cg.pos {
					c := cg.buf[i]
					if !(c >= '0' && c <= '9') && c != '_' {
						bare_int = false
						break
					}
				}
				if bare_int { cg_byte(cg, ' ') }
			}
		}
		cg_byte(cg, e.optional ? '?' : '.')
		if e.optional { cg_byte(cg, '.') }
		gen_expression_raw(cg, e.property)
	}
}

// The object of a member access, the callee of a call or the tag of a
// template. An optional chain ends where its grouping ends: `(a?.b).c` reads
// `c` even when `a` is nullish, and `a?.b.c` does not. The grouping is kept.
gen_chain_operand :: proc(cg: ^Codegen, operand: ^Expression) {
	if operand != nil {
		if _, is_chain := operand^.(^ChainExpression); is_chain {
			cg_byte(cg, '(')
			gen_expression(cg, operand, PREC_LOWEST)
			cg_byte(cg, ')')
			return
		}
	}
	gen_expression(cg, operand, PREC_CALL)
}

gen_call_expression :: proc(cg: ^Codegen, e: ^CallExpression) {
	properties: []string
	if len(cg.param_properties_after_super) > 0 && e.callee != nil {
		if _, is_super := e.callee^.(^Super); is_super {
			properties = cg.param_properties_after_super
			cg_byte(cg, '(')
		}
	}
	gen_chain_operand(cg, e.callee)
	if e.optional { cg_str(cg, "?.") }
	gen_call_arguments(cg, e)
	if len(properties) > 0 {
		// Use a sequence so assignments follow the successful super call,
		// even when the result is used within another expression.
		for name in properties {
			cg_byte(cg, ',')
			cg_space(cg)
			gen_parameter_property_assignment(cg, name)
		}
		cg_byte(cg, ',')
		cg_space(cg)
		cg_str(cg, "this)")
	}
}

gen_new_expression :: proc(cg: ^Codegen, e: ^NewExpression) {
	cg_str(cg, "new ")
	// The `new` callee grammar is MemberExpression | NewExpression — a
	// CallExpression callee needs explicit parens, otherwise
	// `new f()()` parses as `(new f)()` (call on the new), not the
	// intended `new (f())()`.
	if new_callee_needs_group(e.callee) {
		cg_byte(cg, '(')
		gen_expression(cg, e.callee, PREC_LOWEST)
		cg_byte(cg, ')')
	} else {
		gen_expression(cg, e.callee, PREC_CALL)
	}
	gen_call_arguments(cg, e)
}

// The arguments of `new` attach to the first call on the callee's left spine:
// `new (a().b)()` constructs the member, `new a().b()` calls it. An optional
// chain may not be a `new` callee at all without grouping.
new_callee_needs_group :: proc(callee: ^Expression) -> bool {
	current := callee
	for current != nil {
		#partial switch e in current^ {
		case ^CallExpression, ^ImportExpression, ^ChainExpression: return true
		case ^MemberExpression:           current = e.object
		case ^TaggedTemplateExpression:   current = e.tag
		case ^TSNonNullExpression:        current = e.expression
		case ^TSInstantiationExpression:  current = e.expression
		case: return false
		}
	}
	return false
}

gen_call_arguments :: proc(cg: ^Codegen, call: $T) {
	gen_ts_type_arguments(cg, call.type_parameters)
	gen_argument_list(cg, call.arguments[:], call.loc)
}

gen_argument_list :: proc(cg: ^Codegen, args: []^Expression, loc: Loc) {
	cg_byte(cg, '(')
	if codegen_has_list_comments(cg, args, loc.end) {
		gen_commented_list(cg, args, loc)
	} else {
		for arg, index in args {
			if index > 0 { cg_byte(cg, ','); cg_space(cg) }
			gen_expression(cg, arg, PREC_ASSIGN)
		}
		cg_close_comments(cg, loc.end)
	}
	cg_byte(cg, ')')
}

gen_conditional_expression :: proc(cg: ^Codegen, e: ^ConditionalExpression, ctx: CodegenExpressionContext) {
	gen_expression(cg, e.test, PREC_COND + 1, ctx)
	cg_space(cg)
	cg_byte(cg, '?')
	cg_space(cg)
	// The consequent admits an unparenthesized in operator even in a for initializer.
	if conditional_consequent_needs_group(cg, e.consequent) {
		cg_byte(cg, '(')
		gen_expression(cg, e.consequent, PREC_ASSIGN)
		cg_byte(cg, ')')
	} else {
		gen_expression(cg, e.consequent, PREC_ASSIGN)
	}
	cg_space(cg)
	cg_byte(cg, ':')
	cg_space(cg)
	gen_expression(cg, e.alternate, PREC_ASSIGN, ctx)
}

// After `?`, `async (a): T => a : b` reads as the call `async(a)` followed by
// the alternate. Only grouping makes it an arrow with a return type.
conditional_consequent_needs_group :: proc(cg: ^Codegen, consequent: ^Expression) -> bool {
	if cg.cfg.strip_types || consequent == nil { return false }
	arrow, is_arrow := consequent^.(^ArrowFunctionExpression)
	if !is_arrow || !arrow.async { return false }
	_, typed := arrow.return_type.?
	return typed
}

// Separate adjacent signs so the lexer cannot merge them into ++ or --.
cg_prefix_operator :: proc(cg: ^Codegen, op: string) {
	sign := op[0]
	if (sign == '+' || sign == '-') && cg.pos > 0 && cg.buf[cg.pos - 1] == sign {
		cg_hard_space(cg)
	}
	cg_str(cg, op)
}

gen_update_expression :: proc(cg: ^Codegen, e: ^UpdateExpression) {
	op := ""
	switch e.operator {
	case .Increment: op = "++"
	case .Decrement: op = "--"
	}
	if e.prefix {
		cg_prefix_operator(cg, op)
		gen_expression(cg, e.argument, PREC_UPDATE)
	} else {
		gen_expression(cg, e.argument, PREC_UPDATE)
		cg_str(cg, op)
	}
}

gen_unary_expression :: proc(cg: ^Codegen, e: ^UnaryExpression) {
	op := ""
	word := false
	switch e.operator {
	case .Minus:      op = "-"
	case .Plus:       op = "+"
	case .LogicalNot: op = "!"
	case .BitwiseNot: op = "~"
	case .Typeof:     op = "typeof"; word = true
	case .Void:       op = "void";   word = true
	case .Delete:     op = "delete"; word = true
	}
	cg_prefix_operator(cg, op)
	if word { cg_hard_space(cg) }
	gen_expression(cg, e.argument, PREC_UNARY)
}

gen_infix_expression :: proc(cg: ^Codegen, expr: ^Expression, ctx: CodegenExpressionContext) {
	// Other expression kinds can reenter this printer, e.g. through a call argument.
	base := len(cg.infix_work)
	gen_infix_schedule(cg, expr, ctx)
	for len(cg.infix_work) > base {
		task := pop(&cg.infix_work)
		switch task.kind {
		case .Open:     cg_byte(cg, '(')
		case .Close:    cg_byte(cg, ')')
		case .Operator: cg_infix_operator(cg, task.operator)
		case .Operand:
			value, child_ctx, close_paren := gen_expression_begin(cg, task.expr, task.precedence, task.ctx)
			if value == nil { continue }
			if close_paren { append(&cg.infix_work, CodegenInfixTask{kind = .Close}) }
			#partial switch _ in value^ {
			case ^BinaryExpression, ^LogicalExpression:
				gen_infix_schedule(cg, value, child_ctx)
			case:
				gen_expression_raw(cg, value, child_ctx)
			}
		}
	}
	assert(len(cg.infix_work) == base)
}

gen_infix_schedule :: proc(cg: ^Codegen, expr: ^Expression, ctx: CodegenExpressionContext) {
	left, right: ^Expression
	operator: string
	precedence: int
	power := false
	operand_ctx := ctx
	#partial switch node in expr^ {
	case ^BinaryExpression:
		left, right = node.left, node.right
		operator, precedence = binop_text(node.operator)
		power = node.operator == .Pow
	case ^LogicalExpression:
		left, right = node.left, node.right
		switch node.operator {
		case .Or:  operator, precedence = "||", PREC_LOR
		case .And: operator, precedence = "&&", PREC_LAND
		case .NullishCoalescing:
			operator, precedence = "??", PREC_NULLISH
			operand_ctx += {.Nullish_Operand}
		}
	case: unreachable()
	}
	// Push in reverse print order. Only exponentiation groups to the right.
	right_prec := precedence if power else precedence + 1
	append(&cg.infix_work, CodegenInfixTask{kind = .Operand, expr = right, precedence = right_prec, ctx = operand_ctx})
	append(&cg.infix_work, CodegenInfixTask{kind = .Operator, operator = operator})
	if power && left_needs_paren_for_exp(left) {
		append(&cg.infix_work, CodegenInfixTask{kind = .Close})
		append(&cg.infix_work, CodegenInfixTask{kind = .Operand, expr = left, precedence = PREC_LOWEST})
		append(&cg.infix_work, CodegenInfixTask{kind = .Open})
	} else {
		// `(a ** b) ** c` needs its grouping: without it the right side binds first.
		left_prec := precedence + 1 if power else precedence
		append(&cg.infix_work, CodegenInfixTask{kind = .Operand, expr = left, precedence = left_prec, ctx = operand_ctx})
	}
}

// Preserve lexical boundaries around word operators and after a TS postfix '!'.
cg_infix_operator :: proc(cg: ^Codegen, op: string) {
	word := op == "in" || op == "instanceof"
	after_bang := op[0] == '=' && cg.pos > 0 && cg.buf[cg.pos - 1] == '!'
	if word || after_bang { cg_hard_space(cg) } else { cg_space(cg) }
	cg_str(cg, op)
	if word { cg_hard_space(cg) } else { cg_space(cg) }
}

// left_needs_paren_for_exp — true when `expr` cannot legally appear as
// the bare left operand of `**`. The exponentiation production accepts
// only UpdateExpression on the left; UnaryExpression (including `-x`,
// `!x`, `void x`, etc.) and AwaitExpression must be parenthesized.
left_needs_paren_for_exp :: proc(expr: ^Expression) -> bool {
	if expr == nil { return false }
	#partial switch _ in expr^ {
	case ^UnaryExpression:   return true
	case ^AwaitExpression:   return true
	}
	return false
}

binop_text :: proc(op: BinaryOperator) -> (string, int) {
	switch op {
	case .Add:                 return "+",          PREC_ADD
	case .Sub:                 return "-",          PREC_ADD
	case .Mul:                 return "*",          PREC_MUL
	case .Div:                 return "/",          PREC_MUL
	case .Mod:                 return "%",          PREC_MUL
	case .Pow:                 return "**",         PREC_EXP
	case .BitOr:               return "|",          PREC_BOR
	case .BitXor:              return "^",          PREC_BXOR
	case .BitAnd:              return "&",          PREC_BAND
	case .ShiftLeft:           return "<<",         PREC_SHIFT
	case .ShiftRight:          return ">>",         PREC_SHIFT
	case .ShiftRightUnsigned:  return ">>>",        PREC_SHIFT
	case .Eq:                  return "==",         PREC_EQ
	case .NotEq:               return "!=",         PREC_EQ
	case .StrictEq:            return "===",        PREC_EQ
	case .StrictNotEq:         return "!==",        PREC_EQ
	case .Lt:                  return "<",          PREC_REL
	case .LtEq:                return "<=",         PREC_REL
	case .Gt:                  return ">",          PREC_REL
	case .GtEq:                return ">=",         PREC_REL
	case .Instanceof:          return "instanceof", PREC_REL
	case .In:                  return "in",         PREC_REL
	}
	return "+", PREC_ADD
}

gen_assignment_expression :: proc(cg: ^Codegen, e: ^AssignmentExpression, ctx: CodegenExpressionContext) {
	gen_expression(cg, e.left, PREC_CALL)
	cg_infix_operator(cg, assign_op_text(e.operator))
	gen_expression(cg, e.right, PREC_ASSIGN, ctx)
}

assign_op_text :: proc(op: AssignmentOperator) -> string {
	switch op {
	case .Assign:            return "="
	case .AddAssign:         return "+="
	case .SubAssign:         return "-="
	case .MulAssign:         return "*="
	case .DivAssign:         return "/="
	case .ModAssign:         return "%="
	case .PowAssign:         return "**="
	case .ShiftLeftAssign:   return "<<="
	case .ShiftRightAssign:  return ">>="
	case .ShiftRightUAssign: return ">>>="
	case .BitOrAssign:       return "|="
	case .BitXorAssign:      return "^="
	case .BitAndAssign:      return "&="
	case .AssignLogicalAnd:  return "&&="
	case .AssignLogicalOr:   return "||="
	case .AssignNullish:     return "??="
	}
	return "="
}

gen_sequence_expression :: proc(cg: ^Codegen, e: ^SequenceExpression, ctx: CodegenExpressionContext) {
	for i in 0..<len(e.expressions) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_expression(cg, e.expressions[i], PREC_ASSIGN, ctx)
	}
}

gen_yield_expression :: proc(cg: ^Codegen, e: ^YieldExpression, ctx: CodegenExpressionContext) {
	if arg, ok := e.argument.?; ok && !e.delegate {
		codegen_hoist_comments(cg, loc_from_expr(arg).start, e.loc.start)
	}
	cg_str(cg, "yield")
	if e.delegate { cg_byte(cg, '*') }
	if arg, ok := e.argument.?; ok {
		cg_hard_space(cg)
		gen_expression(cg, arg, PREC_ASSIGN, ctx)
	}
}

gen_import_expression :: proc(cg: ^Codegen, e: ^ImportExpression) {
	cg_str(cg, "import")
	if len(e.phase) > 0 { cg_byte(cg, '.'); cg_str(cg, e.phase) }
	values := [2]^Expression{e.source, e.options}
	args := values[:2 if e.options != nil else 1]
	if cg.cfg.minified {
		comments := codegen_argument_comments(cg, e.loc.start, e.loc.end)
		if len(comments) > 0 {
			gen_compact_import_arguments(cg, args, comments, e.loc)
			return
		}
	}
	gen_argument_list(cg, args, e.loc)
}

gen_compact_import_arguments :: proc(cg: ^Codegen, args: []^Expression, comments: []Comment, loc: Loc) {
	cg_byte(cg, '(')
	start := loc.start
	for argument, index in args {
		span := loc_from_expr(argument)
		codegen_emit_import_hints(cg, comments, start, span.start, index > 0)
		gen_expression(cg, argument, PREC_ASSIGN)
		start = span.end
	}
	codegen_emit_import_hints(cg, comments, start, loc.end, false)
	cg_byte(cg, ')')
}

gen_meta_property :: proc(cg: ^Codegen, e: ^MetaProperty) {
	cg_str(cg, e.meta.name)
	cg_byte(cg, '.')
	cg_str(cg, e.property.name)
}

// ----------------------------------------------------------------------------
// JSX
// ----------------------------------------------------------------------------

gen_jsx_element :: proc(cg: ^Codegen, e: ^JSXElement) {
	if cg.cfg.jsx.runtime != .Preserve {
		gen_jsx_runtime(cg, e.loc.start, e.opening_element, e.children[:])
		return
	}
	cg_byte(cg, '<')
	alias := gen_jsx_name(cg, e.opening_element.name)
	// TS-in-JSX generic type arguments: `<Foo<T> />`. The opening element
	// carries them; without this emission, the type args are dropped and
	// the round-trip diff shows `openingElement.typeArguments` only on
	// the original AST.
	gen_ts_type_arguments(cg, e.opening_element.type_arguments)
	for a in e.opening_element.attributes {
		cg_byte(cg, ' ')
		if cg.comment_next != CODEGEN_COMMENT_NONE {
			switch attribute in a {
			case JSXAttribute:        codegen_flush_comments(cg, attribute.loc.start)
			case ^JSXSpreadAttribute: codegen_flush_comments(cg, attribute.loc.start)
			}
		}
		gen_jsx_attr(cg, a)
	}
	// Children are text: a comment still pending there would become content.
	cg_close_comments(cg, e.opening_element.loc.end)
	if e.opening_element.self_closing {
		cg_str(cg, " />")
		return
	}
	cg_byte(cg, '>')
	for c in e.children {
		gen_jsx_child(cg, c)
	}
	cg_str(cg, "</")
	if cl, ok := e.closing_element.?; ok {
		gen_jsx_name(cg, cl.name, alias)
		cg_close_comments(cg, cl.loc.end)
	}
	cg_byte(cg, '>')
}

gen_jsx_fragment :: proc(cg: ^Codegen, e: ^JSXFragment) {
	if cg.cfg.jsx.runtime != .Preserve {
		gen_jsx_runtime(cg, e.loc.start, nil, e.children[:])
		return
	}
	cg_str(cg, "<>")
	for c in e.children {
		gen_jsx_child(cg, c)
	}
	cg_str(cg, "</>")
}

gen_jsx_expression_container :: proc(cg: ^Codegen, e: ^JSXExpressionContainer) {
	cg_byte(cg, '{')
	gen_expression(cg, e.expression, PREC_ASSIGN)
	cg_close_comments(cg, e.loc.end)
	cg_byte(cg, '}')
}

// A closing tag refers to its opening tag. It has its own source position but
// does not add a second lexical read to the semantic model.
gen_jsx_binding_name :: proc(cg: ^Codegen, id: JSXIdentifier, opening_alias: string) -> string {
	alias := opening_alias
	if alias == "" && len(cg.renamed) != 0 { alias = cg.renamed[id.loc.start] }
	if alias != "" { sourcemap_record(cg.sm, u32(cg.pos), id.loc.start) }
	cg_str(cg, alias if alias != "" else id.name)
	return alias
}

gen_jsx_name :: proc(cg: ^Codegen, name: JSXElementName, opening_alias := "") -> string {
	switch n in name {
	case JSXIdentifier:        return gen_jsx_binding_name(cg, n, opening_alias)
	case ^JSXMemberExpression: return gen_jsx_member(cg, n, opening_alias)
	case ^JSXNamespacedName:
		cg_str(cg, n.namespace.name)
		cg_byte(cg, ':')
		cg_str(cg, n.name.name)
	}
	return ""
}

gen_jsx_member :: proc(cg: ^Codegen, m: ^JSXMemberExpression, opening_alias: string) -> string {
	alias: string
	switch o in m.object {
	case JSXIdentifier:        alias = gen_jsx_binding_name(cg, o, opening_alias)
	case ^JSXMemberExpression: alias = gen_jsx_member(cg, o, opening_alias)
	}
	cg_byte(cg, '.')
	cg_str(cg, m.property.name)
	return alias
}

gen_jsx_attr :: proc(cg: ^Codegen, a: JSXAttributeItem) {
	switch v in a {
	case JSXAttribute:
		gen_jsx_attr_name(cg, v.name)
		if val, ok := v.value.?; ok {
			cg_byte(cg, '=')
			gen_expression(cg, val, PREC_ASSIGN)
		}
	case ^JSXSpreadAttribute:
		cg_str(cg, "{...")
		gen_expression(cg, v.argument, PREC_ASSIGN)
		cg_byte(cg, '}')
	}
}

gen_jsx_attr_name :: proc(cg: ^Codegen, n: JSXAttributeName) {
	switch v in n {
	case JSXIdentifier:        cg_str(cg, v.name)
	case ^JSXNamespacedName:
		cg_str(cg, v.namespace.name)
		cg_byte(cg, ':')
		cg_str(cg, v.name.name)
	}
}

gen_jsx_child :: proc(cg: ^Codegen, c: JSXChild) {
	switch v in c {
	case ^JSXElement:              gen_jsx_element(cg, v)
	case ^JSXFragment:             gen_jsx_fragment(cg, v)
	case ^JSXText:                 cg_str(cg, v.value)
	case ^JSXExpressionContainer:  gen_jsx_expression_container(cg, v)
	case ^JSXSpreadChild:          cg_byte(cg, '{'); cg_str(cg, "..."); gen_expression(cg, v.expression, PREC_ASSIGN); cg_byte(cg, '}')
	}
}

// ----------------------------------------------------------------------------
// TS expressions
// ----------------------------------------------------------------------------

gen_ts_as_expression        :: proc(cg: ^Codegen, e: ^TSAsExpression)        { gen_expression(cg, e.expression, PREC_UNARY); cg_str(cg, " as "); gen_ts_type(cg, e.type_annotation) }
gen_ts_satisfies_expression :: proc(cg: ^Codegen, e: ^TSSatisfiesExpression) { gen_expression(cg, e.expression, PREC_UNARY); cg_str(cg, " satisfies "); gen_ts_type(cg, e.type_annotation) }
gen_ts_type_assertion       :: proc(cg: ^Codegen, e: ^TSTypeAssertion)       { cg_byte(cg, '<'); gen_ts_type(cg, e.type_annotation); cg_byte(cg, '>'); gen_expression(cg, e.expression, PREC_UNARY) }
gen_ts_instantiation        :: proc(cg: ^Codegen, e: ^TSInstantiationExpression) { gen_ts_instantiation_full(cg, e) }


// ============================================================================
// Codegen — TypeScript constructs.
//
// Real source emission for every TS form the parser produces. Replaces the
// placeholder `/*marker*/` stubs that previously lived in codegen_impl.odin.
//
// The procs here are split into three layers:
//
//   1. `gen_ts_type_parameter_declaration` / `gen_ts_type_arguments` /
//      `gen_ts_heritage_args` — small helpers shared by declarations,
//      signatures, and expressions.
//
//   2. Top-level TS declarations (interface, type alias, enum, module,
//      import-equals, export-assignment, namespace export). Each emits a
//      full statement that round-trips through `kessel parse --lang=ts`
//      and lands on the same AST.
//
//   3. Interface/object-type member signatures (property, method, call,
//      construct, index). Used by interface bodies and `TSTypeLiteral`.
//
// Hot-path note: codegen is not on the steady-state parse path. These
// procs prioritize correctness and round-trip fidelity over per-byte
// micro-optimization.
// ============================================================================


// ----------------------------------------------------------------------------
// Type parameters / arguments
// ----------------------------------------------------------------------------

gen_ts_type_parameter_declaration :: proc(
	cg: ^Codegen,
	decl: Maybe(^TSTypeParameterDeclaration),
) {
	if cg.cfg.strip_types { return }
	d, ok := decl.?
	if !ok || d == nil || len(d.params) == 0 { return }
	// A generic function type can immediately follow a type assertion's '<'.
	if cg.pos > 0 && cg.buf[cg.pos - 1] == '<' { cg_hard_space(cg) }
	cg_byte(cg, '<')
	for i in 0..<len(d.params) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_ts_type_parameter(cg, d.params[i])
	}
	cg_close_comments(cg, d.loc.end)
	cg_byte(cg, '>')
}

gen_ts_type_parameter :: proc(cg: ^Codegen, p: TSTypeParameter) {
	if cg.comment_next != CODEGEN_COMMENT_NONE { codegen_flush_comments(cg, p.loc.start) }
	if p.const_ { cg_str(cg, "const ") }
	if p.in_    { cg_str(cg, "in ") }
	if p.out    { cg_str(cg, "out ") }
	cg_str(cg, p.name.name)
	if c, ok := p.constraint.?; ok {
		cg_str(cg, " extends ")
		gen_ts_type(cg, c)
	}
	if d, ok := p.default_.?; ok {
		cg_str(cg, " = ")
		gen_ts_type(cg, d)
	}
}

gen_ts_type_arguments :: proc(
	cg: ^Codegen,
	args: Maybe(^TSTypeParameterInstantiation),
) {
	if cg.cfg.strip_types { return }
	a, ok := args.?
	if !ok || a == nil { return }
	if len(a.params) == 0 {
		// The parser accepts JSDoc-only spellings such as <?> without a type node.
		if a.loc.start < a.loc.end && u64(a.loc.end) <= u64(len(cg.source)) {
			if cg.comment_next < a.loc.start { codegen_flush_comments(cg, a.loc.start) }
			cg_str(cg, cg.source[a.loc.start:a.loc.end])
			// The copied text already contains its comments.
			codegen_skip_comments(cg, a.loc.end)
		}
		return
	}
	cg_byte(cg, '<')
	for i in 0..<len(a.params) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_ts_type(cg, a.params[i])
	}
	cg_close_comments(cg, a.loc.end)
	cg_byte(cg, '>')
}


// ----------------------------------------------------------------------------
// TS function-type / method-signature parameter lists
// ----------------------------------------------------------------------------

gen_ts_function_params :: proc(cg: ^Codegen, params: []TSFunctionParam) {
	cg_byte(cg, '(')
	for i in 0..<len(params) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_ts_function_param(cg, params[i])
	}
	cg_byte(cg, ')')
}

gen_ts_function_param :: proc(cg: ^Codegen, p: TSFunctionParam) {
	pattern := p.pattern
	assignment, has_default := pattern.(^AssignmentPattern)
	if has_default && assignment != nil { pattern = assignment.left }
	gen_pattern(cg, pattern)
	if p.optional { cg_byte(cg, '?') }
	if ta, ok := p.type_annotation.?; ok {
		cg_str(cg, ": ")
		gen_ts_type(cg, ta.type_annotation)
	}
	if has_default && assignment != nil {
		cg_str(cg, " = ")
		gen_expression(cg, assignment.right, PREC_ASSIGN)
	}
}


// ----------------------------------------------------------------------------
// Member signatures (interface bodies and object-type literals)
// ----------------------------------------------------------------------------

gen_ts_signature :: proc(cg: ^Codegen, sig: ^TSSignature) {
	if sig == nil { return }
	if cg.declaration_emit != nil && !dts_track_signature(cg.declaration_emit, sig) { return }
	switch v in sig^ {
	case TSPropertySignature:
		if v.readonly { cg_str(cg, "readonly ") }
		if v.computed { cg_byte(cg, '[') }
		gen_expression(cg, v.key, PREC_ASSIGN)
		if v.computed { cg_close_key(cg, v.key); cg_byte(cg, ']') }
		if v.optional { cg_byte(cg, '?') }
		if ta, ok := v.type_annotation.?; ok {
			cg_str(cg, ": ")
			gen_ts_type(cg, ta.type_annotation)
		}

	case TSMethodSignature:
		switch v.kind {
		case .Method: // nothing
		case .Get:    cg_str(cg, "get ")
		case .Set:    cg_str(cg, "set ")
		}
		if v.computed { cg_byte(cg, '[') }
		gen_expression(cg, v.key, PREC_ASSIGN)
		if v.computed { cg_close_key(cg, v.key); cg_byte(cg, ']') }
		if v.optional { cg_byte(cg, '?') }
		gen_ts_type_parameter_declaration(cg, v.type_parameters)
		gen_ts_function_params(cg, v.params[:])
		if rt, ok := v.return_type.?; ok {
			cg_str(cg, ": ")
			gen_ts_type(cg, rt.type_annotation)
		}

	case TSCallSignatureDeclaration:
		gen_ts_type_parameter_declaration(cg, v.type_parameters)
		gen_ts_function_params(cg, v.params[:])
		if rt, ok := v.return_type.?; ok {
			cg_str(cg, ": ")
			gen_ts_type(cg, rt.type_annotation)
		}

	case TSConstructSignatureDeclaration:
		cg_str(cg, "new ")
		gen_ts_type_parameter_declaration(cg, v.type_parameters)
		gen_ts_function_params(cg, v.params[:])
		if rt, ok := v.return_type.?; ok {
			cg_str(cg, ": ")
			gen_ts_type(cg, rt.type_annotation)
		}

	case TSIndexSignature:
		if v.static_  { cg_str(cg, "static ") }
		if v.readonly { cg_str(cg, "readonly ") }
		cg_byte(cg, '[')
		for i in 0..<len(v.parameters) {
			if i > 0 { cg_byte(cg, ','); cg_space(cg) }
			gen_ts_function_param(cg, v.parameters[i])
		}
		cg_byte(cg, ']')
		if ta, ok := v.type_annotation.?; ok {
			cg_str(cg, ": ")
			gen_ts_type(cg, ta.type_annotation)
		}
	}
}

gen_ts_signature_list :: proc(cg: ^Codegen, members: []^TSSignature, loc: Loc) {
	cg_byte(cg, '{')
	if len(members) == 0 && cg.comment_next >= loc.end { cg_byte(cg, '}'); return }
	cg_newline(cg)
	cg.depth += 1
	codegen_emit_leading_comments(cg, members, loc.start, loc.end)
	for i in 0..<len(members) {
		cg_indent(cg)
		// Comments that share the member's line come before its modifiers.
		if cg.comment_next != CODEGEN_COMMENT_NONE {
			codegen_flush_comments(cg, codegen_signature_loc(members[i]).start)
		}
		gen_ts_signature(cg, members[i])
		cg_byte(cg, ';')
		codegen_end_item_line(cg, members, i, loc.end)
	}
	cg.depth -= 1
	cg_indent(cg)
	cg_byte(cg, '}')
}

codegen_signature_loc :: proc(signature: ^TSSignature) -> Loc {
	switch value in signature^ {
	case TSPropertySignature:             return value.loc
	case TSMethodSignature:               return value.loc
	case TSCallSignatureDeclaration:      return value.loc
	case TSConstructSignatureDeclaration: return value.loc
	case TSIndexSignature:                return value.loc
	}
	return {}
}


// ----------------------------------------------------------------------------
// Top-level declarations
// ----------------------------------------------------------------------------

gen_ts_interface_declaration_full :: proc(cg: ^Codegen, s: ^TSInterfaceDeclaration) {
	if s.declare { cg_str(cg, "declare ") }
	cg_str(cg, "interface ")
	cg_str(cg, s.id.name)
	gen_ts_type_parameter_declaration(cg, s.type_parameters)
	if len(s.extends) > 0 {
		cg_str(cg, " extends ")
		for i in 0..<len(s.extends) {
			if i > 0 { cg_byte(cg, ','); cg_space(cg) }
			gen_expression(cg, s.extends[i].expression, PREC_CALL)
			gen_ts_type_arguments(cg, s.extends[i].type_parameters)
		}
	}
	cg_space(cg)
	gen_ts_signature_list(cg, s.body.body[:], s.body.loc)
}

gen_ts_type_alias_declaration_full :: proc(cg: ^Codegen, s: ^TSTypeAliasDeclaration) {
	if s.declare { cg_str(cg, "declare ") }
	cg_str(cg, "type ")
	cg_str(cg, s.id.name)
	gen_ts_type_parameter_declaration(cg, s.type_parameters)
	cg_str(cg, " = ")
	gen_ts_type(cg, s.type_annotation)
	cg_byte(cg, ';')
}

gen_ts_enum_declaration_full :: proc(cg: ^Codegen, s: ^TSEnumDeclaration) {
	if s.declare { cg_str(cg, "declare ") }
	if s.const_  { cg_str(cg, "const ") }
	cg_str(cg, "enum ")
	cg_str(cg, s.id.name)
	cg_space(cg)
	cg_byte(cg, '{')
	body := s.body.loc
	if len(s.body.members) == 0 && cg.comment_next >= body.end { cg_byte(cg, '}'); return }
	cg_newline(cg)
	cg.depth += 1
	codegen_emit_leading_comments(cg, s.body.members[:], body.start, body.end)
	for i in 0..<len(s.body.members) {
		cg_indent(cg)
		m := s.body.members[i]
		gen_expression(cg, m.id, PREC_ASSIGN)
		if init, ok := m.initializer.?; ok {
			cg_str(cg, " = ")
			gen_expression(cg, init, PREC_ASSIGN)
		}
		cg_byte(cg, ',')
		codegen_end_item_line(cg, s.body.members[:], i, body.end)
	}
	cg.depth -= 1
	cg_indent(cg)
	cg_byte(cg, '}')
}

// Lower each declaration to an IIFE that extends the enum's shared object.
gen_ts_enum_lowered :: proc(cg: ^Codegen, s: ^TSEnumDeclaration, exported := false, namespace := "", guard_initializer := false) {
	if s == nil { return }
	// `declare enum` erases entirely in strip-types mode.
	if s.declare { return }
	if cg.cfg.optimize_const_enums && !exported && namespace == "" && cg.runtime_scope.enum_constants.erased[s.loc.start] { return }
	name := s.id.name
	alias, scope := codegen_open_enum(cg, s)
	defer codegen_close_runtime_scope(cg, scope)
	// A module may export a merged enum only once.
	if exported {
		if scope == SCOPE_ROOT {
			cg_module_keyword(cg, "export ")
		} else if !cg.runtime_scope.emitted_exports[scope] {
			cg.runtime_scope.emitted_exports[scope] = true
			cg_module_keyword(cg, "export ")
		}
	}
	// `var Name;`
	cg_str(cg, "var ")
	cg_str(cg, name)
	cg_byte(cg, ';')
	cg_newline(cg)
	cg_indent(cg)
	if guard_initializer { gen_module_resource_try(cg) }
	// `(function(Name) {`
	cg_str(cg, "(function(")
	cg_str(cg, alias)
	cg_str(cg, ") {")
	cg_newline(cg)
	cg.depth += 1
	previous: Maybe(string)
	for member in s.body.members {
		key, valid := enum_member_name(member.id)
		if !valid { continue }
		gen_runtime_property(cg, alias, key)
		cg_str(cg, " = ")
		if init, has_initializer := member.initializer.?; has_initializer {
			gen_expression(cg, init, PREC_ASSIGN)
		} else if last, has_previous := previous.?; has_previous {
			gen_runtime_property(cg, alias, last)
			cg_str(cg, " + 1")
		} else {
			cg_byte(cg, '0')
		}
		cg_byte(cg, ';')
		cg_newline(cg)
		gen_enum_reverse_mapping(cg, alias, key)
		cg_newline(cg)
		previous = key
	}
	cg.depth -= 1
	cg_indent(cg)
	gen_runtime_scope_invocation(cg, name, namespace)
	if guard_initializer { gen_module_resource_catch(cg) }
}

gen_runtime_property :: proc(cg: ^Codegen, object, key: string) {
	cg_str(cg, object)
	cg_byte(cg, '[')
	gen_string_quoted(cg, key)
	cg_byte(cg, ']')
}

// The forward assignment evaluates the initializer once. Only numbers
// have reverse entries, including when the initializer is computed.
gen_enum_reverse_mapping :: proc(cg: ^Codegen, enum_name, key: string) {
	cg_str(cg, "if (typeof ")
	gen_runtime_property(cg, enum_name, key)
	cg_str(cg, " === \"number\") ")
	cg_str(cg, enum_name)
	cg_byte(cg, '[')
	gen_runtime_property(cg, enum_name, key)
	cg_str(cg, "] = ")
	gen_string_quoted(cg, key)
	cg_byte(cg, ';')
}

enum_member_name :: proc(id: ^Expression) -> (name: string, valid: bool) {
	if id == nil { return "", false }
	#partial switch value in id^ {
	case ^Identifier: if value != nil { return value.name, true }
	case ^StringLiteral: if value != nil { return value.value, true }
	case ^TemplateLiteral:
		if value != nil && len(value.expressions) == 0 && len(value.quasis) == 1 {
			quasi := value.quasis[0]
			return quasi.cooked.? or_else quasi.raw, true
		}
	}
	return "", false
}

gen_ts_module_declaration_full :: proc(cg: ^Codegen, s: ^TSModuleDeclaration) {
	if s.declare { cg_str(cg, "declare ") }
	switch s.kind {
	case .Namespace: cg_str(cg, "namespace ")
	case .Module:    cg_str(cg, "module ")
	case .Global:
		// `declare global { ... }` (or bare `global { ... }` inside a
		// module declaration) carries the keyword itself as the
		// declaration name on the parser side. Emit the keyword and the
		// body, but skip the id — emitting it again would produce
		// `global global { ... }`, which is invalid syntax.
		cg_str(cg, "global")
		body_opt, has_body := s.body.?
		if !has_body || body_opt == nil { cg_byte(cg, ';'); return }
		cg_space(cg)
		switch b in body_opt^ {
		case ^TSModuleBlock:
			cg_byte(cg, '{')
			if len(b.body) == 0 { cg_byte(cg, '}'); return }
			cg_newline(cg)
			cg.depth += 1
			for stmt in b.body {
				gen_statement(cg, stmt^)
				cg_newline(cg)
			}
			cg.depth -= 1
			cg_byte(cg, '}')
		case ^TSModuleDeclaration:
			gen_ts_module_declaration_full(cg, b)
		}
		return
	}
	gen_ts_module_id_and_body(cg, s.id, s.body)
}

// Emit the id and the trailing body of a TSModuleDeclaration without the
// leading `declare` / `namespace` / `module` / `global` keyword. Used both
// for the top-level declaration and recursively for nested
// `namespace A.B.C { ... }` chains, which the parser desugars into a chain
// of TSModuleDeclaration nodes. Emitting the keyword again at each level
// would produce `namespace A.namespace B.namespace C { ... }`, which is
// not valid TypeScript.
gen_ts_module_id_and_body :: proc(
	cg: ^Codegen,
	id: ^Expression,
	body_raw: Maybe(^TSModuleBody),
) {
	gen_expression(cg, id, PREC_CALL)
	body_opt, has_body := body_raw.?
	if !has_body || body_opt == nil { cg_byte(cg, ';'); return }
	// `namespace Outer.Inner { ... }` flattens to a chain of
	// TSModuleDeclaration nodes joined by `.`, not by ` { `. Emitting an
	// unconditional space here would produce `Outer .Inner` with a
	// stray space before the dot — it still parses but adds visual
	// noise and may trip strict deep-equal walkers downstream.
	switch b in body_opt^ {
	case ^TSModuleBlock:
		cg_space(cg)
		cg_byte(cg, '{')
		if len(b.body) == 0 { cg_byte(cg, '}'); return }
		cg_newline(cg)
		cg.depth += 1
		for i in 0..<len(b.body) {
			cg_indent(cg)
			gen_statement(cg, b.body[i]^)
			cg_newline(cg)
		}
		cg.depth -= 1
		cg_indent(cg)
		cg_byte(cg, '}')
	case ^TSModuleDeclaration:
		cg_byte(cg, '.')
		gen_ts_module_id_and_body(cg, b.id, b.body)
	}
}

gen_ts_import_equals_full :: proc(cg: ^Codegen, s: ^TSImportEqualsDeclaration) {
	cg_str(cg, "import ")
	if s.import_kind == .Type { cg_str(cg, "type ") }
	cg_str(cg, s.id.name)
	cg_str(cg, " = ")
	gen_ts_import_equals_reference(cg, s.module_reference)
	cg_byte(cg, ';')
}

gen_ts_import_equals_reference :: proc(cg: ^Codegen, reference: TSModuleReference) {
	switch r in reference {
	case ^Expression:
		gen_expression(cg, r, PREC_CALL)
	case ^TSExternalModuleReference:
		name := "require"
		if cg.runtime_scope != nil && cg.runtime_scope.require_alias != "" {
			name = cg.runtime_scope.require_alias
		}
		cg_str(cg, name)
		cg_byte(cg, '(')
		gen_string_literal(cg, r.expression)
		cg_byte(cg, ')')
	}
}

gen_ts_export_assignment_full :: proc(cg: ^Codegen, s: ^TSExportAssignment) {
	cg_str(cg, "export = ")
	gen_expression(cg, s.expression, PREC_ASSIGN)
	cg_byte(cg, ';')
}

// gen_ts_import_equals_lowered emits `import X = require("m")` as
// `const X = require("m");` in strip-types mode. Type-only import-equals
// are erased entirely.
gen_ts_import_equals_lowered :: proc(cg: ^Codegen, s: ^TSImportEqualsDeclaration) {
	if s == nil { return }
	if s.import_kind == .Type { return }
	cg_str(cg, "const ")
	cg_str(cg, s.id.name)
	cg_str(cg, " = ")
	gen_ts_import_equals_reference(cg, s.module_reference)
	cg_byte(cg, ';')
}

// gen_ts_export_assignment_lowered emits `export = X` as
// `module.exports = X;` in strip-types mode.
gen_ts_export_assignment_lowered :: proc(cg: ^Codegen, s: ^TSExportAssignment) {
	if s == nil { return }
	cg_str(cg, "module.exports = ")
	gen_expression(cg, s.expression, PREC_ASSIGN)
	cg_byte(cg, ';')
}

gen_ts_namespace_export_full :: proc(cg: ^Codegen, s: ^TSNamespaceExportDeclaration) {
	cg_str(cg, "export as namespace ")
	cg_str(cg, s.id.name)
	cg_byte(cg, ';')
}


// ----------------------------------------------------------------------------
// TSType — extended forms not handled by gen_ts_type's short branches
// ----------------------------------------------------------------------------

gen_ts_function_type :: proc(cg: ^Codegen, t: ^TSFunctionType) {
	gen_ts_type_parameter_declaration(cg, t.type_parameters)
	gen_ts_function_params(cg, t.params[:])
	cg_str(cg, " => ")
	gen_ts_type(cg, t.return_type.type_annotation)
}

gen_ts_constructor_type :: proc(cg: ^Codegen, t: ^TSConstructorType) {
	if t.abstract_ { cg_str(cg, "abstract ") }
	cg_str(cg, "new ")
	gen_ts_type_parameter_declaration(cg, t.type_parameters)
	gen_ts_function_params(cg, t.params[:])
	cg_str(cg, " => ")
	gen_ts_type(cg, t.return_type.type_annotation)
}

gen_ts_type_literal :: proc(cg: ^Codegen, t: ^TSTypeLiteral) {
	gen_ts_signature_list(cg, t.members[:], t.loc)
}

gen_ts_conditional_type :: proc(cg: ^Codegen, t: ^TSConditionalType) {
	gen_ts_type(cg, t.check_type)
	cg_str(cg, " extends ")
	gen_ts_type(cg, t.extends_type)
	cg_str(cg, " ? ")
	gen_ts_type(cg, t.true_type)
	cg_str(cg, " : ")
	gen_ts_type(cg, t.false_type)
}

gen_ts_infer_type :: proc(cg: ^Codegen, t: ^TSInferType) {
	cg_str(cg, "infer ")
	cg_str(cg, t.type_parameter.name.name)
	if c, ok := t.type_parameter.constraint.?; ok {
		cg_str(cg, " extends ")
		gen_ts_type(cg, c)
	}
}

gen_ts_type_query :: proc(cg: ^Codegen, t: ^TSTypeQuery) {
	cg_str(cg, "typeof ")
	gen_expression(cg, t.expr_name, PREC_CALL)
	gen_ts_type_arguments(cg, t.type_parameters)
}

gen_ts_type_operator :: proc(cg: ^Codegen, t: ^TSTypeOperator) {
	cg_str(cg, t.operator)
	// `keyof T`, `readonly T[]`, `unique symbol` — all word operators.
	// Minified mode strips a plain cg_space, gluing the operator into
	// the following type name (`keyofT`) and turning a TSTypeOperator
	// into a TSTypeReference on reparse.
	cg_hard_space(cg)
	gen_ts_type(cg, t.type_annotation)
}

gen_ts_indexed_access_type :: proc(cg: ^Codegen, t: ^TSIndexedAccessType) {
	gen_ts_type(cg, t.object_type)
	cg_byte(cg, '[')
	gen_ts_type(cg, t.index_type)
	cg_close_comments(cg, t.loc.end)
	cg_byte(cg, ']')
}

gen_ts_mapped_type :: proc(cg: ^Codegen, t: ^TSMappedType) {
	cg_byte(cg, '{')
	cg_space(cg)
	switch t.readonly {
	case .None:   // nothing
	case .Plus:   cg_str(cg, "+readonly ")
	case .Minus:  cg_str(cg, "-readonly ")
	case .True:   cg_str(cg, "readonly ")
	}
	cg_byte(cg, '[')
	cg_str(cg, t.type_parameter.name.name)
	if c, ok := t.type_parameter.constraint.?; ok {
		cg_str(cg, " in ")
		gen_ts_type(cg, c)
	}
	if nt, ok := t.name_type.?; ok {
		cg_str(cg, " as ")
		gen_ts_type(cg, nt)
	}
	cg_byte(cg, ']')
	switch t.optional {
	case .None:   // nothing
	case .Plus:   cg_str(cg, "+?")
	case .Minus:  cg_str(cg, "-?")
	case .True:   cg_byte(cg, '?')
	}
	if ta, ok := t.type_annotation.?; ok {
		cg_str(cg, ": ")
		gen_ts_type(cg, ta)
	}
	cg_byte(cg, ';')
	cg_space(cg)
	cg_byte(cg, '}')
}

gen_ts_literal_type :: proc(cg: ^Codegen, t: ^TSLiteralType) {
	gen_expression(cg, t.literal, PREC_ASSIGN)
}

gen_ts_template_literal_type :: proc(cg: ^Codegen, t: ^TSTemplateLiteralType) {
	cg_byte(cg, '`')
	for i in 0..<len(t.quasis) {
		// The raw text keeps the escapes. The cooked text of `\t` is a tab, and
		// of `\r\n` a line break that the template would then normalize.
		cg_str(cg, t.quasis[i].raw)
		if i < len(t.types) {
			cg_str(cg, "${")
			gen_ts_type(cg, t.types[i])
			cg_byte(cg, '}')
		}
	}
	cg_byte(cg, '`')
}

gen_ts_type_predicate :: proc(cg: ^Codegen, t: ^TSTypePredicate) {
	if t.asserts { cg_str(cg, "asserts ") }
	gen_expression(cg, t.parameter_name, PREC_CALL)
	if ta, ok := t.type_annotation.?; ok {
		cg_str(cg, " is ")
		gen_ts_type(cg, ta.type_annotation)
	}
}

gen_ts_import_type_full :: proc(cg: ^Codegen, t: ^TSImportType) {
	if t.is_typeof { cg_str(cg, "typeof ") }
	cg_str(cg, "import(")
	gen_ts_type(cg, t.argument)
	if options := ts_import_type_options(t); options != nil {
		cg_byte(cg, ',')
		cg_space(cg)
		gen_expression(cg, options, PREC_ASSIGN)
	}
	cg_byte(cg, ')')
	if q, ok := t.qualifier.?; ok {
		cg_byte(cg, '.')
		gen_expression(cg, q, PREC_CALL)
	}
	gen_ts_type_arguments(cg, t.type_parameters)
}

gen_ts_instantiation_full :: proc(cg: ^Codegen, e: ^TSInstantiationExpression) {
	gen_expression(cg, e.expression, PREC_CALL)
	gen_ts_type_arguments(cg, e.type_arguments)
}
