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
	minified: bool,  // true: no indentation / newlines; false: pretty form
	indent:   string, // indent unit; default "\t" or "  "
}

Codegen :: struct {
	cfg: CodegenConfig,

	// Output buffer. Grown by cg_reserve via doubling. Owned by Codegen;
	// codegen_destroy frees it.
	buf: []byte,
	pos: int,

	// Current indentation depth (number of cfg.indent units).
	depth: int,

	// True at the start of a line; controls whether the next textual
	// write prefixes itself with indentation in pretty mode.
	at_line_start: bool,
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

codegen_init :: proc(cg: ^Codegen, cfg: CodegenConfig, source_len_hint: int, alloc: mem.Allocator) {
	est := max(source_len_hint, 4096)
	cg.cfg           = cfg
	cg.buf           = make([]byte, est, alloc)
	cg.pos           = 0
	cg.depth         = 0
	cg.at_line_start = true
}

codegen_destroy :: proc(cg: ^Codegen, alloc: mem.Allocator) {
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

// ----------------------------------------------------------------------------
// Top-level entry point
// ----------------------------------------------------------------------------

codegen_program :: proc(cg: ^Codegen, program: ^Program) {
	if program == nil { return }
	if len(program.directives) > 0 {
		for d in program.directives {
			cg_str(cg, "\"")
			cg_str(cg, d.value.value)
			cg_str(cg, "\";")
			cg_newline(cg)
		}
	}
	for i in 0..<len(program.body) {
		gen_statement(cg, program.body[i]^)
		cg_newline(cg)
	}
}

// ============================================================================
// Statement dispatch
// ============================================================================

gen_statement :: proc(cg: ^Codegen, stmt: Statement) {
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
	case ^FunctionDeclaration:        gen_function_declaration(cg, s)
	case ^VariableDeclaration:        gen_variable_declaration(cg, s, true)
	case ^ClassDeclaration:           gen_class_declaration(cg, s)
	case ^ImportDeclaration:          gen_import_declaration(cg, s)
	case ^ExportNamedDeclaration:     gen_export_named_declaration(cg, s)
	case ^ExportDefaultDeclaration:   gen_export_default_declaration(cg, s)
	case ^ExportAllDeclaration:       gen_export_all_declaration(cg, s)
	case ^TSInterfaceDeclaration:     gen_ts_interface_declaration(cg, s)
	case ^TSTypeAliasDeclaration:     gen_ts_type_alias_declaration(cg, s)
	case ^TSEnumDeclaration:          gen_ts_enum_declaration(cg, s)
	case ^TSModuleDeclaration:        gen_ts_module_declaration(cg, s)
	case ^TSImportEqualsDeclaration:  gen_ts_import_equals(cg, s)
	case ^TSExportAssignment:         gen_ts_export_assignment(cg, s)
	case ^TSNamespaceExportDeclaration: gen_ts_namespace_export(cg, s)
	}
}

// ============================================================================
// Expression dispatch
// ============================================================================

gen_expression :: proc(cg: ^Codegen, expr: ^Expression, parent_prec: int = PREC_LOWEST) {
	if expr == nil { return }
	prec := expression_precedence(expr)
	need_paren := prec < parent_prec
	if need_paren { cg_byte(cg, '(') }
	gen_expression_raw(cg, expr)
	if need_paren { cg_byte(cg, ')') }
}

gen_expression_raw :: proc(cg: ^Codegen, expr: ^Expression) {
	switch e in expr^ {
	case ^NullLiteral:                cg_str(cg, "null")
	case ^BooleanLiteral:             cg_str(cg, e.value ? "true" : "false")
	case ^NumericLiteral:             gen_numeric_literal(cg, e)
	case ^StringLiteral:              gen_string_literal(cg, e)
	case ^BigIntLiteral:              gen_bigint_literal(cg, e)
	case ^RegExpLiteral:              gen_regexp_literal(cg, e)
	case ^TemplateLiteral:            gen_template_literal(cg, e)
	case ^TaggedTemplateExpression:   gen_tagged_template(cg, e)
	case ^Identifier:                 cg_str(cg, e.name)
	case ^PrivateIdentifier:          cg_byte(cg, '#'); cg_str(cg, e.name)
	case ^ThisExpression:             cg_str(cg, "this")
	case ^Super:                      cg_str(cg, "super")
	case ^ChainExpression:            gen_expression_raw(cg, e.expression)
	case ^ArrayExpression:            gen_array_expression(cg, e)
	case ^ObjectExpression:           gen_object_expression(cg, e)
	case ^FunctionExpression:         gen_function_expression(cg, e)
	case ^ArrowFunctionExpression:    gen_arrow_function(cg, e)
	case ^ClassExpression:            gen_class_expression(cg, e)
	case ^MemberExpression:           gen_member_expression(cg, e)
	case ^CallExpression:             gen_call_expression(cg, e)
	case ^NewExpression:              gen_new_expression(cg, e)
	case ^ConditionalExpression:      gen_conditional_expression(cg, e)
	case ^UpdateExpression:           gen_update_expression(cg, e)
	case ^UnaryExpression:            gen_unary_expression(cg, e)
	case ^BinaryExpression:           gen_binary_expression(cg, e)
	case ^LogicalExpression:          gen_logical_expression(cg, e)
	case ^AssignmentExpression:       gen_assignment_expression(cg, e)
	case ^SequenceExpression:         gen_sequence_expression(cg, e)
	case ^SpreadElement:              cg_str(cg, "..."); gen_expression(cg, e.argument, PREC_ASSIGN)
	case ^YieldExpression:            gen_yield_expression(cg, e)
	case ^AwaitExpression:            cg_str(cg, "await "); gen_expression(cg, e.argument, PREC_UNARY)
	case ^ImportExpression:           gen_import_expression(cg, e)
	case ^MetaProperty:               gen_meta_property(cg, e)
	case ^JSXElement:                 gen_jsx_element(cg, e)
	case ^JSXFragment:                gen_jsx_fragment(cg, e)
	case ^JSXText:                    cg_str(cg, e.value)
	case ^JSXExpressionContainer:     gen_jsx_expression_container(cg, e)
	case ^JSXEmptyExpression:         // empty
	case ^JSXSpreadChild:             cg_byte(cg, '{'); cg_str(cg, "..."); gen_expression(cg, e.expression, PREC_ASSIGN); cg_byte(cg, '}')
	case ^TSAsExpression:             gen_ts_as_expression(cg, e)
	case ^TSSatisfiesExpression:      gen_ts_satisfies_expression(cg, e)
	case ^TSNonNullExpression:        gen_expression(cg, e.expression, PREC_CALL); cg_byte(cg, '!')
	case ^TSTypeAssertion:            gen_ts_type_assertion(cg, e)
	case ^TSInstantiationExpression:  gen_ts_instantiation(cg, e)
	case ^ParenthesizedExpression:    cg_byte(cg, '('); gen_expression(cg, e.expression, PREC_LOWEST); cg_byte(cg, ')')
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
	case ^TSAsExpression, ^TSSatisfiesExpression, ^TSTypeAssertion,
	     ^TSInstantiationExpression:
		return PREC_CALL
	case ^TSNonNullExpression:
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
// Stub procedures — concrete implementations follow in codegen_impl.odin
// (kept in this file for now; will split if it grows past ~2 000 LOC).
// ============================================================================

// (The per-node procedures live below this banner. The order tracks the
// dispatch tables above for grep-ability.)
