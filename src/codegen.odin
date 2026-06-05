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

	// Source-map state. nil unless the caller opted in via
	// codegen_enable_sourcemap(). Borrowed; the caller owns the lifetime.
	// Recording mappings on the hot path is a single nil-check + append
	// per Statement; everything else (line/col conversion, VLQ encoding)
	// happens once at the end in sourcemap_to_json.
	sm: ^SourceMap,
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
	cg.sm            = nil
}

// Opt the codegen into source-map recording. After codegen_program
// returns, the caller can read `cg.sm.records` and pass them to
// sourcemap_to_json. Borrowed pointer; caller manages the SourceMap's
// lifetime.
codegen_enable_sourcemap :: proc(cg: ^Codegen, sm: ^SourceMap) {
	cg.sm = sm
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

// Decorator / modifier separator: emits a newline in pretty mode (so each
// decorator lands on its own line) and a single mandatory space in
// minified mode. Plain `cg_newline` collapses to nothing in minified
// output, which glues `@computed accessor` -> `@computedaccessor` and
// loses the token boundary on reparse.
cg_break_or_space :: #force_inline proc(cg: ^Codegen) {
	if cg.cfg.minified { cg_hard_space(cg) } else { cg_newline(cg) }
}

// ----------------------------------------------------------------------------
// Top-level entry point
// ----------------------------------------------------------------------------

codegen_program :: proc(cg: ^Codegen, program: ^Program) {
	if program == nil { return }
	// Directive prologue (e.g. "use strict") lives in BOTH `program.directives`
	// and as the leading ExpressionStatement of `program.body`. We emit only
	// from body[] to avoid duplicate output.
	for i in 0..<len(program.body) {
		need_asi_guard := false
		if cg.cfg.minified && i + 1 < len(program.body) {
			need_asi_guard = prev_stmt_can_continue_into_next(program.body[i]^, program.body[i+1]^)
		}
		gen_statement(cg, program.body[i]^)
		if !cg.cfg.minified {
			cg_newline(cg)
		} else if need_asi_guard {
			// Use a newline instead of `;` here — a `;` would reparse as
			// an additional EmptyStatement, lengthening the body by one
			// and breaking AST round-trip. A bare newline is a free ASI
			// separator that doesn't add a node.
			if cg.pos > 0 && cg.buf[cg.pos-1] != '\n' { cg_byte(cg, '\n') }
		}
	}
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

gen_statement :: proc(cg: ^Codegen, stmt: Statement) {
	if cg.sm != nil {
		// Force indent before recording so the mapping points at the
		// statement keyword, not at the leading whitespace.
		cg_indent(cg)
		stmt_local := stmt
		cg_record_stmt_mapping(cg, &stmt_local)
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
	case ^Identifier:                 gen_pattern_identifier(cg, e)
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
	if expression_needs_statement_paren(s.expression) {
		cg_byte(cg, '(')
		gen_expression(cg, s.expression, PREC_LOWEST)
		cg_byte(cg, ')')
	} else {
		gen_expression(cg, s.expression, PREC_LOWEST)
	}
	cg_byte(cg, ';')
}

// True when the expression's first emitted token would be parsed as the
// start of a non-Expression production if it appeared at statement start.
// Walks leftmost descendants — the ambiguity propagates through call /
// member / binary / sequence / etc. since those keep `function`/`class`/`{`
// as the first token of the whole statement.
expression_needs_statement_paren :: proc(expr: ^Expression) -> bool {
	cur := expr
	for cur != nil {
		#partial switch e in cur^ {
		case ^FunctionExpression:        return true
		case ^ClassExpression:           return true
		case ^ObjectExpression:          return true
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
		case ^ChainExpression:           cur = e.expression
		case:
			return false
		}
	}
	return false
}

gen_block_statement :: proc(cg: ^Codegen, s: ^BlockStatement) {
	cg_byte(cg, '{')
	if len(s.body) == 0 { cg_byte(cg, '}'); return }
	cg_newline(cg)
	cg.depth += 1
	for i in 0..<len(s.body) {
		gen_statement(cg, s.body[i]^)
		cg_newline(cg)
	}
	cg.depth -= 1
	cg_byte(cg, '}')
}

gen_return_statement :: proc(cg: ^Codegen, s: ^ReturnStatement) {
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
	cg_str(cg, "switch")
	cg_space(cg)
	cg_byte(cg, '(')
	gen_expression(cg, s.discriminant, PREC_LOWEST)
	cg_byte(cg, ')')
	cg_space(cg)
	cg_byte(cg, '{')
	cg_newline(cg)
	cg.depth += 1
	for c in s.cases {
		if t, ok := c.test.?; ok {
			cg_str(cg, "case ")
			gen_expression(cg, t, PREC_LOWEST)
			cg_byte(cg, ':')
		} else {
			cg_str(cg, "default:")
		}
		cg_newline(cg)
		cg.depth += 1
		for st in c.consequent {
			gen_statement(cg, st^)
			cg_newline(cg)
		}
		cg.depth -= 1
	}
	cg.depth -= 1
	cg_byte(cg, '}')
}

gen_while_statement :: proc(cg: ^Codegen, s: ^WhileStatement) {
	cg_str(cg, "while")
	cg_space(cg)
	cg_byte(cg, '(')
	gen_expression(cg, s.test, PREC_LOWEST)
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
	cg_str(cg, ");")
}

gen_for_statement :: proc(cg: ^Codegen, s: ^ForStatement) {
	cg_str(cg, "for")
	cg_space(cg)
	cg_byte(cg, '(')
	if v, ok := s.init_decl.?; ok {
		gen_variable_declaration(cg, v, false)
	} else if v, ok := s.init_expr.?; ok {
		gen_expression(cg, v, PREC_LOWEST)
	}
	cg_byte(cg, ';')
	if t, ok := s.test.?; ok { cg_space(cg); gen_expression(cg, t, PREC_LOWEST) }
	cg_byte(cg, ';')
	if u, ok := s.update.?; ok { cg_space(cg); gen_expression(cg, u, PREC_LOWEST) }
	cg_byte(cg, ')')
	cg_space(cg)
	gen_statement(cg, s.body^)
}

gen_for_in_statement :: proc(cg: ^Codegen, s: ^ForInStatement) {
	cg_str(cg, "for")
	cg_space(cg)
	cg_byte(cg, '(')
	if v, ok := s.left_decl.?; ok {
		gen_variable_declaration(cg, v, false)
	} else if v, ok := s.left_expr.?; ok {
		gen_expression(cg, v, PREC_LOWEST)
	}
	cg_str(cg, " in ")
	gen_expression(cg, s.right, PREC_LOWEST)
	cg_byte(cg, ')')
	cg_space(cg)
	gen_statement(cg, s.body^)
}

gen_for_of_statement :: proc(cg: ^Codegen, s: ^ForOfStatement) {
	cg_str(cg, "for")
	if s.await { cg_str(cg, " await") }
	cg_space(cg)
	cg_byte(cg, '(')
	if v, ok := s.left_decl.?; ok {
		gen_variable_declaration(cg, v, false)
	} else if v, ok := s.left_expr.?; ok {
		gen_expression(cg, v, PREC_LOWEST)
	}
	cg_str(cg, " of ")
	gen_expression(cg, s.right, PREC_ASSIGN)
	cg_byte(cg, ')')
	cg_space(cg)
	gen_statement(cg, s.body^)
}

gen_with_statement :: proc(cg: ^Codegen, s: ^WithStatement) {
	cg_str(cg, "with")
	cg_space(cg)
	cg_byte(cg, '(')
	gen_expression(cg, s.object, PREC_LOWEST)
	cg_byte(cg, ')')
	cg_space(cg)
	gen_statement(cg, s.body^)
}

gen_throw_statement :: proc(cg: ^Codegen, s: ^ThrowStatement) {
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
	// TS `declare function f(): void;` is a FunctionDeclaration with
	// declare=true and no body. The keyword must be preserved or the
	// regen loses its ambient marker (and a body-less function without
	// `declare` is a parse error).
	if s.declare { cg_str(cg, "declare ") }
	name := ""
	if id, ok := s.id.?; ok { name = id.name }
	gen_function_expression_like(cg, s.async, s.generator, name, s.params[:], s.body, s.no_body, s.type_parameters, s.return_type, true)
}

gen_variable_declaration :: proc(cg: ^Codegen, s: ^VariableDeclaration, with_semicolon: bool) {
	// TS `declare const X: T;` reaches codegen as a VariableDeclaration
	// with `declare = true` and no initializer. Emitting it without the
	// keyword regenerates `const X: T;`, which is an early error because
	// `const` requires an initializer outside of ambient context.
	if s.declare { cg_str(cg, "declare ") }
	switch s.kind {
	case .Var:   cg_str(cg, "var")
	case .Let:   cg_str(cg, "let")
	case .Const: cg_str(cg, "const")
	case .Using: cg_str(cg, "using")
	case .AwaitUsing: cg_str(cg, "await using")
	}
	cg_hard_space(cg)
	for i in 0..<len(s.declarations) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		d := s.declarations[i]
		gen_var_declarator_id(cg, d.id, d.definite)
		if init, ok := d.init.?; ok {
			cg_space(cg)
			cg_byte(cg, '=')
			cg_space(cg)
			gen_expression(cg, init, PREC_ASSIGN)
		}
	}
	if with_semicolon { cg_byte(cg, ';') }
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
	if s.declare  { cg_str(cg, "declare ") }
	if s.abstract { cg_str(cg, "abstract ") }
	name := ""
	if id, ok := s.id.?; ok { name = id.name }
	gen_class_like(cg, name, s.super_class, s.body, s.type_parameters, s.super_type_arguments, s.implements)
}

gen_import_declaration :: proc(cg: ^Codegen, s: ^ImportDeclaration) {
	cg_str(cg, "import ")
	if s.import_kind == .Type { cg_str(cg, "type ") }
	// Source-phase / defer-phase imports (`import source x from "m"`,
	// `import defer x from "m"`) need a HARD space between the phase
	// keyword and the binding identifier — the minified `cg_space`
	// collapses to nothing and produces `import sourcex` which the
	// parser then reads as a single identifier.
	if len(s.phase) > 0 { cg_str(cg, s.phase); cg_hard_space(cg) }
	first := true
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
			// emitted in the `{...}` group below
		}
	}
	// Named specifiers.
	any_named := false
	for spec in s.specifiers {
		if _, ok := spec^.(ImportSpecifier); ok { any_named = true; break }
	}
	if any_named {
		if !first { cg_str(cg, ", ") }
		cg_byte(cg, '{')
		first_named := true
		for spec in s.specifiers {
			v, ok := spec^.(ImportSpecifier)
			if !ok { continue }
			if !first_named { cg_str(cg, ", ") } else { cg_space(cg) }
			first_named = false
			if v.imported.name != v.local.name {
				cg_str(cg, v.imported.name)
				cg_str(cg, " as ")
				cg_str(cg, v.local.name)
			} else {
				cg_str(cg, v.local.name)
			}
		}
		cg_space(cg)
		cg_byte(cg, '}')
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
		cg_str(cg, attrs[i].key.name)
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

gen_export_named_declaration :: proc(cg: ^Codegen, s: ^ExportNamedDeclaration) {
	cg_str(cg, "export ")
	// `export type { A } from "x"`, `export type * from "x"`, and the
	// inner type-alias / interface / enum / module forms all carry the
	// `type` modifier on the declaration itself. The `type` keyword on
	// the export wrapper is only needed when no inner declaration
	// supplies it — i.e. the specifier-only export form. Emitting it
	// before TSInterfaceDeclaration / TSTypeAliasDeclaration produces
	// `export type interface I {}` / `export type type X = ...`, both
	// of which are SyntaxErrors.
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
	for i in 0..<len(s.specifiers) {
		if i > 0 { cg_str(cg, ", ") } else { cg_space(cg) }
		sp := s.specifiers[i]
		if export_name_eq(sp.local, sp.exported) {
			gen_export_specifier_name(cg, sp.local)
		} else {
			gen_export_specifier_name(cg, sp.local)
			cg_str(cg, " as ")
			gen_export_specifier_name(cg, sp.exported)
		}
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

gen_export_default_declaration :: proc(cg: ^Codegen, s: ^ExportDefaultDeclaration) {
	cg_str(cg, "export default ")
	switch v in s.declaration^ {
	case ^Declaration:
		gen_statement(cg, decl_to_stmt(v^))
	case ^Expression:
		gen_expression(cg, v, PREC_ASSIGN)
		// Function and class *expressions* in default-export position are
		// declaration-shaped at the source level (closing `}` ends the
		// statement). Emitting `;` after them produces two statements on
		// re-parse — the declaration plus a stray EmptyStatement — which
		// breaks AST round-trip. Only assign-expression forms need `;`.
		needs_semi := true
		#partial switch _ in v^ {
		case ^FunctionExpression: needs_semi = false
		case ^ClassExpression:    needs_semi = false
		}
		if needs_semi { cg_byte(cg, ';') }
	}
}

gen_export_all_declaration :: proc(cg: ^Codegen, s: ^ExportAllDeclaration) {
	cg_str(cg, "export ")
	// `export type * from "x"` keeps the type-only marker on the
	// declaration's export_kind. Same drop bug as gen_export_named.
	if s.export_kind == .Type { cg_str(cg, "type ") }
	cg_str(cg, "* ")
	if name, ok := s.exported.?; ok {
		cg_str(cg, "as ")
		cg_str(cg, name.name)
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
	} else {
		cg_byte(cg, '(')
		gen_expression(cg, d.expression, PREC_LOWEST)
		cg_byte(cg, ')')
	}
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

gen_pattern :: proc(cg: ^Codegen, p: Pattern) {
	switch v in p {
	case ^Identifier:         gen_pattern_identifier(cg, v)
	case ^ObjectPattern:      gen_object_pattern(cg, v)
	case ^ArrayPattern:       gen_array_pattern(cg, v)
	case ^AssignmentPattern:  gen_assignment_pattern(cg, v)
	case ^RestElement:        cg_str(cg, "..."); gen_pattern(cg, v.argument)
	case ^MemberExpression:   gen_member_expression(cg, v)
	}
}

gen_pattern_identifier :: proc(cg: ^Codegen, e: ^Identifier) {
	cg_str(cg, e.name)
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
	if !definite {
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

gen_object_pattern :: proc(cg: ^Codegen, e: ^ObjectPattern) {
	cg_byte(cg, '{')
	if len(e.properties) == 0 {
		cg_byte(cg, '}')
	} else {
		cg_space(cg)
		for i in 0..<len(e.properties) {
			if i > 0 { cg_byte(cg, ','); cg_space(cg) }
			gen_object_pattern_property(cg, e.properties[i])
		}
		cg_space(cg)
		cg_byte(cg, '}')
	}
	// TS-position annotation lives on the ObjectPattern itself when the
	// pattern is not a bare Identifier. Mirror the Identifier branch in
	// gen_pattern_identifier so `function f({a, b}: Props)` round-trips.
	if ta, ok := e.type_annotation.?; ok {
		cg_str(cg, ": ")
		gen_ts_type(cg, ta.type_annotation)
	}
}

gen_object_pattern_property :: proc(cg: ^Codegen, p: ObjectPatternProperty) {
	if p.shorthand {
		gen_pattern(cg, p.value)
		return
	}
	if key, ok := p.key.?; ok {
		if p.computed { cg_byte(cg, '[') }
		gen_object_pattern_key(cg, key)
		if p.computed { cg_byte(cg, ']') }
		cg_byte(cg, ':')
		cg_space(cg)
	}
	gen_pattern(cg, p.value)
}

gen_object_pattern_key :: proc(cg: ^Codegen, k: ObjectPatternPropertyKey) {
	switch v in k {
	case IdentifierName:   cg_str(cg, v.name)
	case ^StringLiteral:   gen_string_literal(cg, v)
	case ^NumericLiteral:  gen_numeric_literal(cg, v)
	case ^Expression:      gen_expression(cg, v, PREC_ASSIGN)
	}
}

gen_array_pattern :: proc(cg: ^Codegen, e: ^ArrayPattern) {
	cg_byte(cg, '[')
	for i in 0..<len(e.elements) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		if el, ok := e.elements[i].?; ok {
			gen_pattern(cg, el)
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
	cg_byte(cg, ']')
	// Same TS-position annotation as ObjectPattern: `function
	// f([a, b]: number[])` carries `: number[]` on the ArrayPattern.
	if ta, ok := e.type_annotation.?; ok {
		cg_str(cg, ": ")
		gen_ts_type(cg, ta.type_annotation)
	}
}

gen_assignment_pattern :: proc(cg: ^Codegen, e: ^AssignmentPattern) {
	gen_pattern(cg, e.left)
	cg_space(cg)
	cg_byte(cg, '=')
	cg_space(cg)
	gen_expression(cg, e.right, PREC_ASSIGN)
}

// ----------------------------------------------------------------------------
// Function shared
// ----------------------------------------------------------------------------

gen_function_param :: proc(cg: ^Codegen, p: FunctionParameter) {
	// Accessibility / readonly / override / parameter properties — emit
	// the minimum keywords so the output still parses; full TS shape is a
	// follow-up.
	switch p.accessibility {
	case .None:      // nothing
	case .Public:    cg_str(cg, "public ")
	case .Private:   cg_str(cg, "private ")
	case .Protected: cg_str(cg, "protected ")
	}
	if p.readonly { cg_str(cg, "readonly ") }
	gen_pattern(cg, p.pattern)
	if d, ok := p.default_val.?; ok {
		cg_space(cg)
		cg_byte(cg, '=')
		cg_space(cg)
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
) {
	gen_ts_type_parameter_declaration(cg, type_parameters)
	cg_byte(cg, '(')
	for i in 0..<len(params) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_function_param(cg, params[i])
	}
	cg_byte(cg, ')')
	if rt, ok := return_type.?; ok {
		cg_str(cg, ": ")
		gen_ts_type(cg, rt.type_annotation)
	}
	if no_body { cg_byte(cg, ';'); return }
	cg_space(cg)
	cg_byte(cg, '{')
	if len(body.body) == 0 { cg_byte(cg, '}'); return }
	cg_newline(cg)
	cg.depth += 1
	// Directive prologue (e.g. "use strict") is already present at the
	// front of body.body[] as an ExpressionStatement; emitting it from
	// body.directives too would duplicate output. See codegen_program.
	for i in 0..<len(body.body) {
		gen_statement(cg, body.body[i]^)
		cg_newline(cg)
	}
	cg.depth -= 1
	cg_byte(cg, '}')
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
	if len(implements_list) > 0 {
		cg_str(cg, " implements ")
		for i in 0..<len(implements_list) {
			if i > 0 { cg_byte(cg, ','); cg_space(cg) }
			gen_expression(cg, implements_list[i].expression, PREC_CALL)
			gen_ts_type_arguments(cg, implements_list[i].type_parameters)
		}
	}
	cg_space(cg)
	cg_byte(cg, '{')
	if len(body.body) == 0 { cg_byte(cg, '}'); return }
	cg_newline(cg)
	cg.depth += 1
	for i in 0..<len(body.body) {
		el := body.body[i]
		if cg.sm != nil {
			// Force the indent before recording so the mapping points at
			// the first non-whitespace column (e.g. the method key /
			// modifier keyword) rather than at the leading spaces.
			cg_indent(cg)
			cg_record_class_element_mapping(cg, &body.body[i])
		}
		gen_class_element(cg, el)
		cg_newline(cg)
	}
	cg.depth -= 1
	cg_byte(cg, '}')
}

gen_class_element :: proc(cg: ^Codegen, el: ClassElement) {
	for d in el.decorators {
		gen_decorator(cg, d)
		cg_break_or_space(cg)
	}
	switch el.accessibility {
	case .None:      // nothing
	case .Public:    cg_str(cg, "public ")
	case .Private:   cg_str(cg, "private ")
	case .Protected: cg_str(cg, "protected ")
	}
	if el.abstract  { cg_str(cg, "abstract ") }
	if el.static    { cg_str(cg, "static ") }
	if el.override_ { cg_str(cg, "override ") }
	if el.readonly  { cg_str(cg, "readonly ") }
	if el.is_accessor { cg_str(cg, "accessor ") }
	switch el.kind {
	case .Method:
		// ClassElementKind.Method covers both MethodDefinition AND
		// PropertyDefinition: if the value is a FunctionExpression it's
		// a method; otherwise it's a field initializer (`x = 1;` or `x;`).
		// Mirrors the emitter's class-element dispatch.
		//
		// Disambiguation for `name = function id() {}`: a real method's
		// FunctionExpression value is anonymous (no `.id`). A non-nil
		// `.id` proves the source had `=` + a named function expression,
		// so this slot is a PropertyDefinition, not a MethodDefinition.
		raw_val, val_ok := el.value.?
		fn: ^FunctionExpression
		is_method := false
		if val_ok {
			if f, ok := raw_val.(^FunctionExpression); ok {
				_, has_id := f.id.?
				if !has_id {
					fn = f
					is_method = true
				}
			}
		}
		if is_method {
			if fn.async { cg_str(cg, "async ") }
			if fn.generator { cg_byte(cg, '*') }
		}
		if el.computed { cg_byte(cg, '[') }
		gen_expression(cg, el.key, PREC_ASSIGN)
		if el.computed { cg_byte(cg, ']') }
		if el.optional { cg_byte(cg, '?') }
		if el.definite { cg_byte(cg, '!') }
		if ta, ok := el.type_annotation.?; ok {
			cg_str(cg, ": ")
			gen_ts_type(cg, ta.type_annotation)
		}
		if is_method {
			gen_function_params_and_body(cg, fn.async, fn.generator, fn.params[:], fn.body, fn.no_body, fn.type_parameters, fn.return_type)
			return
		}
		// PropertyDefinition path. Optional initializer + terminating `;`.
		if val_ok {
			cg_space(cg)
			cg_byte(cg, '=')
			cg_space(cg)
			gen_expression(cg, raw_val, PREC_ASSIGN)
		}
		cg_byte(cg, ';')
	case .Get:
		cg_str(cg, "get ")
		if el.computed { cg_byte(cg, '[') }
		gen_expression(cg, el.key, PREC_ASSIGN)
		if el.computed { cg_byte(cg, ']') }
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
		if el.computed { cg_byte(cg, ']') }
		if val, ok := el.value.?; ok {
			if fn, is_fn := val.(^FunctionExpression); is_fn {
				gen_function_params_and_body(cg, false, false, fn.params[:], fn.body, fn.no_body, nil, fn.return_type)
				return
			}
		}
		cg_str(cg, "() {}")
	case .Constructor:
		cg_str(cg, "constructor")
		if val, ok := el.value.?; ok {
			if fn, is_fn := val.(^FunctionExpression); is_fn {
				gen_function_params_and_body(cg, fn.async, fn.generator, fn.params[:], fn.body, fn.no_body, fn.type_parameters, fn.return_type)
				return
			}
		}
		cg_str(cg, "() {}")
	case .StaticBlock:
		// Parser stores the static block as a FunctionExpression with no
		// params; body.body holds the statements. See parse_static_block.
		cg_str(cg, "static ")
		cg_byte(cg, '{')
		if v, ok := el.value.?; ok {
			if fn, is_fn := v.(^FunctionExpression); is_fn && len(fn.body.body) > 0 {
				cg_newline(cg)
				cg.depth += 1
				for i in 0..<len(fn.body.body) {
					gen_statement(cg, fn.body.body[i]^)
					cg_newline(cg)
				}
				cg.depth -= 1
			}
		}
		cg_byte(cg, '}')
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
	switch v in ty^ {
	case ^TSKeywordType:      cg_str(cg, TS_KEYWORD_SOURCE[v.kind])
	case ^TSTypeReference:
		gen_expression(cg, v.type_name, PREC_CALL)
		gen_ts_type_arguments(cg, v.type_parameters)
	case ^TSUnionType:
		for i in 0..<len(v.types) {
			if i > 0 { cg_str(cg, " | ") }
			gen_ts_type(cg, v.types[i])
		}
	case ^TSIntersectionType:
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
		cg_byte(cg, ')')
	case ^TSRestType:
		cg_str(cg, "...")
		gen_ts_type(cg, v.type_annotation)
	case ^TSOptionalType:
		gen_ts_type(cg, v.type_annotation)
		cg_byte(cg, '?')
	case ^TSNamedTupleMember:
		cg_str(cg, v.label.name)
		cg_str(cg, ": ")
		gen_ts_type(cg, v.element_type)
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
gen_string_quoted :: proc(cg: ^Codegen, s: string) {
	cg_byte(cg, '"')
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
	cg_byte(cg, '"')
}

gen_template_literal :: proc(cg: ^Codegen, e: ^TemplateLiteral) {
	cg_byte(cg, '`')
	for i in 0..<len(e.quasis) {
		cg_str(cg, e.quasis[i].raw)
		if i < len(e.expressions) {
			cg_str(cg, "${")
			gen_expression(cg, e.expressions[i], PREC_LOWEST)
			cg_byte(cg, '}')
		}
	}
	cg_byte(cg, '`')
}

gen_tagged_template :: proc(cg: ^Codegen, e: ^TaggedTemplateExpression) {
	gen_expression(cg, e.tag, PREC_CALL)
	gen_expression(cg, e.quasi, PREC_CALL)
}

// ----------------------------------------------------------------------------
// Compound expressions
// ----------------------------------------------------------------------------

gen_array_expression :: proc(cg: ^Codegen, e: ^ArrayExpression) {
	cg_byte(cg, '[')
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
	cg_byte(cg, ']')
}

gen_object_expression :: proc(cg: ^Codegen, e: ^ObjectExpression) {
	cg_byte(cg, '{')
	if len(e.properties) == 0 { cg_byte(cg, '}'); return }
	cg_space(cg)
	for i in 0..<len(e.properties) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_property(cg, e.properties[i])
	}
	cg_space(cg)
	cg_byte(cg, '}')
}

gen_property :: proc(cg: ^Codegen, p: Property) {
	if _, ok := p.value.(^SpreadElement); ok {
		gen_expression(cg, p.value, PREC_ASSIGN)
		return
	}
	switch p.kind {
	case .Init:
		if p.shorthand {
			gen_expression(cg, p.value, PREC_ASSIGN)
			return
		}
		if p.computed { cg_byte(cg, '[') }
		gen_expression(cg, p.key, PREC_ASSIGN)
		if p.computed { cg_byte(cg, ']') }
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
		if p.computed { cg_byte(cg, ']') }
		if fn_for_prefix != nil {
			gen_function_params_and_body(cg, fn_for_prefix.async, fn_for_prefix.generator, fn_for_prefix.params[:], fn_for_prefix.body, fn_for_prefix.no_body, fn_for_prefix.type_parameters, fn_for_prefix.return_type)
		}
	case .Get:
		cg_str(cg, "get ")
		if p.computed { cg_byte(cg, '[') }
		gen_expression(cg, p.key, PREC_ASSIGN)
		if p.computed { cg_byte(cg, ']') }
		if fn, is_fn := p.value.(^FunctionExpression); is_fn {
			gen_function_params_and_body(cg, false, false, fn.params[:], fn.body, fn.no_body, nil, fn.return_type)
		}
	case .Set:
		cg_str(cg, "set ")
		if p.computed { cg_byte(cg, '[') }
		gen_expression(cg, p.key, PREC_ASSIGN)
		if p.computed { cg_byte(cg, ']') }
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

gen_arrow_function :: proc(cg: ^Codegen, e: ^ArrowFunctionExpression) {
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
	cg_byte(cg, ')')
	if rt, ok := e.return_type.?; ok {
		cg_str(cg, ": ")
		gen_ts_type(cg, rt.type_annotation)
	}
	cg_space(cg)
	cg_str(cg, "=>")
	cg_space(cg)
	switch body in e.body {
	case ^Expression:
		// `() => {foo: 1}` parses as a block with a labeled statement, not
		// an object literal. Wrap ObjectExpression bodies in parens so the
		// re-parse round-trips to the same Expression.
		if _, is_obj := body^.(^ObjectExpression); is_obj {
			cg_byte(cg, '(')
			gen_expression(cg, body, PREC_ASSIGN)
			cg_byte(cg, ')')
		} else {
			gen_expression(cg, body, PREC_ASSIGN)
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
	obj_start := cg.pos
	gen_expression(cg, e.object, PREC_CALL)
	if e.computed {
		if e.optional { cg_str(cg, "?.") }
		cg_byte(cg, '[')
		gen_expression(cg, e.property, PREC_LOWEST)
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
			if _, is_num := e.object.(^NumericLiteral); is_num {
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

gen_call_expression :: proc(cg: ^Codegen, e: ^CallExpression) {
	gen_expression(cg, e.callee, PREC_CALL)
	if e.optional { cg_str(cg, "?.") }
	gen_ts_type_arguments(cg, e.type_parameters)
	cg_byte(cg, '(')
	for i in 0..<len(e.arguments) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_expression(cg, e.arguments[i], PREC_ASSIGN)
	}
	cg_byte(cg, ')')
}

gen_new_expression :: proc(cg: ^Codegen, e: ^NewExpression) {
	cg_str(cg, "new ")
	// The `new` callee grammar is MemberExpression | NewExpression — a
	// CallExpression callee needs explicit parens, otherwise
	// `new f()()` parses as `(new f)()` (call on the new), not the
	// intended `new (f())()`.
	if _, is_call := e.callee^.(^CallExpression); is_call {
		cg_byte(cg, '(')
		gen_expression(cg, e.callee, PREC_LOWEST)
		cg_byte(cg, ')')
	} else {
		gen_expression(cg, e.callee, PREC_CALL)
	}
	gen_ts_type_arguments(cg, e.type_parameters)
	cg_byte(cg, '(')
	for i in 0..<len(e.arguments) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_expression(cg, e.arguments[i], PREC_ASSIGN)
	}
	cg_byte(cg, ')')
}

gen_conditional_expression :: proc(cg: ^Codegen, e: ^ConditionalExpression) {
	gen_expression(cg, e.test, PREC_COND + 1)
	cg_space(cg)
	cg_byte(cg, '?')
	cg_space(cg)
	gen_expression(cg, e.consequent, PREC_ASSIGN)
	cg_space(cg)
	cg_byte(cg, ':')
	cg_space(cg)
	gen_expression(cg, e.alternate, PREC_ASSIGN)
}

gen_update_expression :: proc(cg: ^Codegen, e: ^UpdateExpression) {
	op := ""
	switch e.operator {
	case .Increment: op = "++"
	case .Decrement: op = "--"
	}
	if e.prefix {
		cg_str(cg, op)
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
	cg_str(cg, op)
	if word { cg_hard_space(cg) }
	gen_expression(cg, e.argument, PREC_UNARY)
}

gen_binary_expression :: proc(cg: ^Codegen, e: ^BinaryExpression) {
	op, prec := binop_text(e.operator)
	// Spec: ExponentiationExpression's left operand is restricted to
	// UpdateExpression — a UnaryExpression / AwaitExpression on the
	// left of `**` is a syntax error unless parenthesized. Normal
	// precedence comparison would let `await x ** y` through because
	// PREC_UNARY > PREC_EXP, but the parse re-rejects it. Force parens
	// on the left when the operator is `**` and the left is a prefix
	// form that cannot legally appear there bare.
	if op == "**" && left_needs_paren_for_exp(e.left) {
		cg_byte(cg, '(')
		gen_expression(cg, e.left, PREC_LOWEST)
		cg_byte(cg, ')')
	} else {
		gen_expression(cg, e.left, prec)
	}
	// Word operators (`in`, `instanceof`) MUST be separated from the
	// surrounding identifiers / private names. Symbolic operators (`+`,
	// `**`, `<<`, etc.) can elide the spaces in minified mode because
	// the lexer will retokenise correctly without them.
	word_op := op == "in" || op == "instanceof"
	if word_op { cg_hard_space(cg) } else { cg_space(cg) }
	cg_str(cg, op)
	if word_op { cg_hard_space(cg) } else { cg_space(cg) }
	// Right-assoc only for **; everything else is left-assoc, so bump on right.
	right_prec := prec + 1
	if op == "**" { right_prec = prec }
	gen_expression(cg, e.right, right_prec)
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

gen_logical_expression :: proc(cg: ^Codegen, e: ^LogicalExpression) {
	op := ""
	prec := PREC_LOR
	switch e.operator {
	case .Or:                 op = "||"; prec = PREC_LOR
	case .And:                op = "&&"; prec = PREC_LAND
	case .NullishCoalescing:  op = "??"; prec = PREC_NULLISH
	}
	gen_expression(cg, e.left, prec)
	cg_space(cg)
	cg_str(cg, op)
	cg_space(cg)
	gen_expression(cg, e.right, prec + 1)
}

gen_assignment_expression :: proc(cg: ^Codegen, e: ^AssignmentExpression) {
	gen_expression(cg, e.left, PREC_CALL)
	cg_space(cg)
	cg_str(cg, assign_op_text(e.operator))
	cg_space(cg)
	gen_expression(cg, e.right, PREC_ASSIGN)
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

gen_sequence_expression :: proc(cg: ^Codegen, e: ^SequenceExpression) {
	for i in 0..<len(e.expressions) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_expression(cg, e.expressions[i], PREC_ASSIGN)
	}
}

gen_yield_expression :: proc(cg: ^Codegen, e: ^YieldExpression) {
	cg_str(cg, "yield")
	if e.delegate { cg_byte(cg, '*') }
	if arg, ok := e.argument.?; ok {
		cg_hard_space(cg)
		gen_expression(cg, arg, PREC_ASSIGN)
	}
}

gen_import_expression :: proc(cg: ^Codegen, e: ^ImportExpression) {
	cg_str(cg, "import")
	if len(e.phase) > 0 { cg_byte(cg, '.'); cg_str(cg, e.phase) }
	cg_byte(cg, '(')
	gen_expression(cg, e.source, PREC_ASSIGN)
	if e.options != nil {
		cg_byte(cg, ',')
		cg_space(cg)
		gen_expression(cg, e.options, PREC_ASSIGN)
	}
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
	cg_byte(cg, '<')
	gen_jsx_name(cg, e.opening_element.name)
	// TS-in-JSX generic type arguments: `<Foo<T> />`. The opening element
	// carries them; without this emission, the type args are dropped and
	// the round-trip diff shows `openingElement.typeArguments` only on
	// the original AST.
	gen_ts_type_arguments(cg, e.opening_element.type_arguments)
	for a in e.opening_element.attributes {
		cg_byte(cg, ' ')
		gen_jsx_attr(cg, a)
	}
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
		gen_jsx_name(cg, cl.name)
	}
	cg_byte(cg, '>')
}

gen_jsx_fragment :: proc(cg: ^Codegen, e: ^JSXFragment) {
	cg_str(cg, "<>")
	for c in e.children {
		gen_jsx_child(cg, c)
	}
	cg_str(cg, "</>")
}

gen_jsx_expression_container :: proc(cg: ^Codegen, e: ^JSXExpressionContainer) {
	cg_byte(cg, '{')
	gen_expression(cg, e.expression, PREC_ASSIGN)
	cg_byte(cg, '}')
}

gen_jsx_name :: proc(cg: ^Codegen, name: JSXElementName) {
	switch n in name {
	case JSXIdentifier:        cg_str(cg, n.name)
	case ^JSXMemberExpression: gen_jsx_member(cg, n)
	case ^JSXNamespacedName:
		cg_str(cg, n.namespace.name)
		cg_byte(cg, ':')
		cg_str(cg, n.name.name)
	}
}

gen_jsx_member :: proc(cg: ^Codegen, m: ^JSXMemberExpression) {
	switch o in m.object {
	case JSXIdentifier:        cg_str(cg, o.name)
	case ^JSXMemberExpression: gen_jsx_member(cg, o)
	}
	cg_byte(cg, '.')
	cg_str(cg, m.property.name)
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
	d, ok := decl.?
	if !ok || d == nil || len(d.params) == 0 { return }
	cg_byte(cg, '<')
	for i in 0..<len(d.params) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_ts_type_parameter(cg, d.params[i])
	}
	cg_byte(cg, '>')
}

gen_ts_type_parameter :: proc(cg: ^Codegen, p: TSTypeParameter) {
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
	a, ok := args.?
	if !ok || a == nil || len(a.params) == 0 { return }
	cg_byte(cg, '<')
	for i in 0..<len(a.params) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_ts_type(cg, a.params[i])
	}
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
	gen_pattern(cg, p.pattern)
	if p.optional { cg_byte(cg, '?') }
	if ta, ok := p.type_annotation.?; ok {
		cg_str(cg, ": ")
		gen_ts_type(cg, ta.type_annotation)
	}
}


// ----------------------------------------------------------------------------
// Member signatures (interface bodies and object-type literals)
// ----------------------------------------------------------------------------

gen_ts_signature :: proc(cg: ^Codegen, sig: ^TSSignature) {
	if sig == nil { return }
	switch v in sig^ {
	case TSPropertySignature:
		if v.readonly { cg_str(cg, "readonly ") }
		if v.computed { cg_byte(cg, '[') }
		gen_expression(cg, v.key, PREC_ASSIGN)
		if v.computed { cg_byte(cg, ']') }
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
		if v.computed { cg_byte(cg, ']') }
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

gen_ts_signature_list :: proc(cg: ^Codegen, members: []^TSSignature) {
	cg_byte(cg, '{')
	if len(members) == 0 { cg_byte(cg, '}'); return }
	cg_newline(cg)
	cg.depth += 1
	for i in 0..<len(members) {
		cg_indent(cg)
		gen_ts_signature(cg, members[i])
		cg_byte(cg, ';')
		cg_newline(cg)
	}
	cg.depth -= 1
	cg_indent(cg)
	cg_byte(cg, '}')
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
	gen_ts_signature_list(cg, s.body.body[:])
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
	if len(s.body.members) == 0 { cg_byte(cg, '}'); return }
	cg_newline(cg)
	cg.depth += 1
	for i in 0..<len(s.body.members) {
		cg_indent(cg)
		m := s.body.members[i]
		gen_expression(cg, m.id, PREC_ASSIGN)
		if init, ok := m.initializer.?; ok {
			cg_str(cg, " = ")
			gen_expression(cg, init, PREC_ASSIGN)
		}
		cg_byte(cg, ',')
		cg_newline(cg)
	}
	cg.depth -= 1
	cg_indent(cg)
	cg_byte(cg, '}')
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
	switch r in s.module_reference {
	case ^Expression:
		gen_expression(cg, r, PREC_CALL)
	case ^TSExternalModuleReference:
		cg_str(cg, "require(")
		gen_string_literal(cg, r.expression)
		cg_byte(cg, ')')
	}
	cg_byte(cg, ';')
}

gen_ts_export_assignment_full :: proc(cg: ^Codegen, s: ^TSExportAssignment) {
	cg_str(cg, "export = ")
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
	gen_ts_signature_list(cg, t.members[:])
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
		if c, ok := t.quasis[i].cooked.?; ok {
			cg_str(cg, c)
		} else {
			cg_str(cg, t.quasis[i].raw)
		}
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
