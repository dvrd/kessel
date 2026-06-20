package kessel

import "core:fmt"
import "core:strings"

// ============================================================================
// Expressions
// ============================================================================

// Expression parsing with precedence climbing
// ES2025 Precedence (from lowest to highest):
Precedence :: enum {
	None,            // Not an operator - breaks the loop immediately
	Comma,           // ,
	Spread,          // ...
	Yield,           // yield
	Assignment,      // = += -= etc.
	Conditional,     // ? :
	LogicalOr,       // ||
	NullishCoalescing, // ?? (ES2020) - between || and &&
	LogicalAnd,      // &&
	BitwiseOr,       // |
	BitwiseXor,      // ^
	BitwiseAnd,      // &
	Equality,        // == != === !==
	Relational,      // < > <= >= in instanceof
	Shift,           // << >> >>>
	Additive,        // + -
	Multiplicative,  // * / %
	Exponentiation,  // **
	Unary,           // ! ~ - + typeof void delete
	Update,          // ++ --
	LeftHandSide,    // new call member
	Primary,         // literals, identifiers, ( ), [ ], { }
}

// Static precedence table for O(1) token-to-precedence lookup
// Initialized once at startup using a procedure with #init directive
precedence_table: [len(TokenType)]Precedence

@(init)
init_precedence_table :: proc "contextless" () {
	for i in 0..<len(precedence_table) { precedence_table[i] = .None }
	precedence_table[TokenType.Comma]       = .Comma
	precedence_table[TokenType.Dot3]        = .Spread
	precedence_table[TokenType.Arrow]       = .Assignment
	precedence_table[TokenType.Question]    = .Conditional
	precedence_table[TokenType.LogicalOr]   = .LogicalOr
	precedence_table[TokenType.Nullish]     = .NullishCoalescing
	precedence_table[TokenType.LogicalAnd]  = .LogicalAnd
	precedence_table[TokenType.BitOr]       = .BitwiseOr
	precedence_table[TokenType.BitXor]      = .BitwiseXor
	precedence_table[TokenType.BitAnd]      = .BitwiseAnd
	precedence_table[TokenType.Eq]          = .Equality
	precedence_table[TokenType.NotEq]       = .Equality
	precedence_table[TokenType.EqStrict]    = .Equality
	precedence_table[TokenType.NotEqStrict] = .Equality
	precedence_table[TokenType.LAngle]      = .Relational
	precedence_table[TokenType.RAngle]      = .Relational
	precedence_table[TokenType.LEq]         = .Relational
	precedence_table[TokenType.GEq]         = .Relational
	precedence_table[TokenType.In]          = .Relational
	precedence_table[TokenType.Instanceof]  = .Relational
	precedence_table[TokenType.LShift]      = .Shift
	precedence_table[TokenType.RShift]      = .Shift
	precedence_table[TokenType.URShift]     = .Shift
	precedence_table[TokenType.Plus]        = .Additive
	precedence_table[TokenType.Minus]       = .Additive
	precedence_table[TokenType.Mul]         = .Multiplicative
	precedence_table[TokenType.Div]         = .Multiplicative
	precedence_table[TokenType.Mod]         = .Multiplicative
	precedence_table[TokenType.Pow]         = .Exponentiation
	precedence_table[TokenType.Assign]          = .Assignment
	precedence_table[TokenType.AssignAdd]       = .Assignment
	precedence_table[TokenType.AssignSub]       = .Assignment
	precedence_table[TokenType.AssignMul]       = .Assignment
	precedence_table[TokenType.AssignDiv]       = .Assignment
	precedence_table[TokenType.AssignMod]       = .Assignment
	precedence_table[TokenType.AssignPow]       = .Assignment
	precedence_table[TokenType.AssignLShift]    = .Assignment
	precedence_table[TokenType.AssignRShift]    = .Assignment
	precedence_table[TokenType.AssignURShift]   = .Assignment
	precedence_table[TokenType.AssignBitAnd]    = .Assignment
	precedence_table[TokenType.AssignBitOr]     = .Assignment
	precedence_table[TokenType.AssignBitXor]    = .Assignment
	precedence_table[TokenType.AssignLogicalAnd] = .Assignment
	precedence_table[TokenType.AssignLogicalOr]  = .Assignment
	precedence_table[TokenType.AssignNullish]    = .Assignment
}

// Fast O(1) precedence lookup using precomputed table
precedence_for_token :: #force_inline proc(t: TokenType) -> Precedence {
	return precedence_table[t]
}

// Identifier-like tokens accepted by parse_unary_expr's identifier fast-path:
// plain Identifier plus the contextual keywords whose lex tokens always
// resolve to an IdentifierReference here (Get / Set / From / Of / As / Let /
// Static / Constructor / Using). The previous 10-clause OR chain compiled to
// 10 token-type compares per parse_unary_expr call - hit on every Identifier
// expression in the program. A single table load + nz-test replaces it.
is_id_like_for_unary_table: [len(TokenType)]bool

@(init)
init_is_id_like_for_unary_table :: proc "contextless" () {
	is_id_like_for_unary_table[TokenType.Identifier]  = true
	is_id_like_for_unary_table[TokenType.Get]         = true
	is_id_like_for_unary_table[TokenType.Set]         = true
	is_id_like_for_unary_table[TokenType.From]        = true
	is_id_like_for_unary_table[TokenType.Of]          = true
	is_id_like_for_unary_table[TokenType.As]          = true
	is_id_like_for_unary_table[TokenType.Let]         = true
	is_id_like_for_unary_table[TokenType.Static]      = true
	is_id_like_for_unary_table[TokenType.Constructor] = true
	is_id_like_for_unary_table[TokenType.Using]       = true
}

is_id_like_for_unary :: #force_inline proc(t: TokenType) -> bool {
	return is_id_like_for_unary_table[t]
}

// Parse expression using precedence climbing (efficient Pratt-style parsing)
// Parse full expression including comma operator
// Full expression including comma operator: AssignmentExpr (, AssignmentExpr)*
parse_expression :: proc(p: ^Parser) -> ^Expression {
	return parse_expr_with_prec(p, .Comma)
}

// Single assignment expression (no comma). Used for:
// - function arguments, array elements, object property values
// - for-in/of right-hand side
// - ternary branches
parse_assignment_expression :: proc(p: ^Parser) -> ^Expression {
	return parse_expr_with_prec(p, .Assignment)
}

// parse_expr_yield_lhs_restricted enforces §14.4 / §15.5: a bare (non-
// parenthesised) YieldExpression cannot be the operand of a conditional /
// binary / logical / coalescing operator. Returns true when the caller must
// stop and return `left` as-is. Extracted from parse_expr_with_prec to keep
// that proc under the 70-line limit; called #force_inline so the hot path
// codegen is unchanged. The common (non-yield) case is a single type-assert
// then an immediate `false` return.
parse_expr_yield_lhs_restricted :: proc(p: ^Parser, left: ^Expression) -> bool {
	_, is_yield := left.(^YieldExpression)
	if !is_yield {
		return false
	}
	// Detect whether the YieldExpression was parenthesised. With
	// --preserve-parens off, `(yield n)` is stripped to a bare
	// YieldExpression node; we recover the paren context by scanning
	// backwards from the span start, identical to the `**` and `??` checks.
	yield_start := int(loc_from_expr(left).start)
	if is_paren_wrapped_at(p, yield_start) {
		return false
	}
	next_prec := precedence_for_token(p.cur_type)
	// §12.6 ASI: a LineTerminator between the YieldExpression and the next
	// operator token ends the statement. The next operator starts the next
	// statement (Babel `es2015/yield/regexp`: `yield<nl>/ 1 /g` is `yield;`
	// then a regex, not a binary chain). OXC + V8 + SpiderMonkey apply ASI.
	if cur_has_newline(p) {
		return true
	}
	// .Conditional (5) and above covers ?, ||, &&, ??, |, ^, &, ==, <, <<,
	// +, *, ** etc. All forbidden as yield LHS without parens. Assignment
	// operators (.Assignment=4) are below the threshold - let them through
	// so parse_assignment_expr can validate the target (`(yield) = 1`).
	if int(next_prec) >= int(Precedence.Conditional) {
		report_error_coded(p, .K3011_AwaitYieldExpressionContextRestricted,
			"'yield' expression cannot be used as an operand of a conditional or binary operator")
	}
	// Stop for all operators EXCEPT comma (sequence) and assignment (target
	// validation needed in parse_assignment_expr).
	is_assign_like := int(next_prec) == int(Precedence.Assignment)
	if p.cur_type != .Comma && !is_assign_like {
		return true
	}
	return false
}

// parse_expr_ts_type_postfix consumes a chain of TypeScript `expr as Type`
// and `expr satisfies Type` postfixes, wrapping `left` in TSAsExpression /
// TSSatisfiesExpression nodes. In a JS file the operator is reported as a
// TS-only construct but still parsed for error recovery. Extracted from
// parse_expr_with_prec; called #force_inline to preserve hot-path codegen.
parse_expr_ts_type_postfix :: proc(p: ^Parser, left: ^Expression) -> ^Expression {
	left := left
	for is_token(p, .As) || is_token(p, .Satisfies) {
		if !allow_ts_mode(p) {
			if is_token(p, .Satisfies) {
				report_error_coded(p, .K4053_TSOnlyInJS, "Type satisfaction expressions can only be used in TypeScript files")
			} else {
				report_error_coded(p, .K4053_TSOnlyInJS, "Type assertions can only be used in TypeScript files")
			}
		}
		if is_token(p, .As) {
			eat(p)
			ts_type := parse_ts_type(p)
			as_expr, as_expr_e := new_expr(p, TSAsExpression)
			as_expr.loc = loc_from_expr(left)
			as_expr.expression = left
			as_expr.type_annotation = ts_type
			as_expr.loc.end = prev_end_offset(p)
			left = as_expr_e
		} else {
			eat(p)
			ts_type := parse_ts_type(p)
			sat_expr, sat_expr_e := new_expr(p, TSSatisfiesExpression)
			sat_expr.loc = loc_from_expr(left)
			sat_expr.expression = left
			sat_expr.type_annotation = ts_type
			sat_expr.loc.end = prev_end_offset(p)
			left = sat_expr_e
		}
	}
	return left
}

parse_expr_with_prec :: proc(p: ^Parser, min_prec: Precedence) -> ^Expression {
	prev_private_in_allowed := p.ctx.private_in_allowed
	p.ctx.private_in_allowed = int(min_prec) <= int(Precedence.Relational)
	left := parse_unary_expr(p)
	p.ctx.private_in_allowed = prev_private_in_allowed
	if left == nil {
		return nil
	}

	// §14.4 / §15.5 - YieldExpression cannot be the subject of binary,
	// logical, coalescing, or conditional operators (unless parenthesised).
	// The guard returns true when the caller must stop and return `left`.
	if #force_inline parse_expr_yield_lhs_restricted(p, left) {
		return left
	}

	// TypeScript: `expr as Type` and `expr satisfies Type` (TS-only)
	left = #force_inline parse_expr_ts_type_postfix(p, left)

	for {
		if left == nil {
			return nil
		}
		cur_type := p.cur_type

		// Skip 'in' as binary op when parsing for-loop init
		if p.ctx.no_in && cur_type == .In {
			break
		}

		op_prec := precedence_for_token(cur_type)

		// Fast exit: non-operator tokens have .None precedence → immediate break
		if op_prec < min_prec {
			break
		}

		// Handle special operator-like tokens
		if op_prec == .Assignment {
			if cur_type == .Arrow {
				// ECMA-262 §15.3 Restricted Production:
				//   ArrowFunction : ArrowParameters [no LineTerminator here] => ConciseBody
				// A LineTerminator between the parameters and `=>` fails the
				// production. Report it but still parse the arrow so the rest of
				// the expression parses cleanly (the arrow body carries the
				// `=>` span regardless).
				if cur_has_newline(p) {
					report_error_coded(p, .K2040_UnexpectedToken, "Unexpected line terminator before '=>' (restricted production)")
				}
				// `({}=>0)` — bare ObjectExpression followed by `=>` inside a
				// paren group is not valid CoverParenthesizedExpression form.
				// V8 rejects: "Malformed arrow function parameter list".
				// Only reject when the object has NO properties and was not
				// preceded by `)` (which would mean `({}) =>` form).
				if left != nil {
					if obj, is_obj := left^.(^ObjectExpression); is_obj && len(obj.properties) == 0 {
						// Check if there's a `)` between the `}` and `=>`.
						if p.lexer != nil {
							arrow_off := int(cur_offset(p))
							has_rparen := false
							i := arrow_off - 1
							for i >= 0 {
								ch := p.lexer.source_bytes[i]
								if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { i -= 1; continue }
								if ch == ')' { has_rparen = true }
								break
							}
							if !has_rparen {
								report_error_coded(p, .K2040_UnexpectedToken, "Malformed arrow function parameter list")
							}
						}
					}
				}
				left = parse_arrow_function(p, left)
				continue
			}
			if is_assignment_operator(cur_type) {
				// `/=` on a new line is ambiguous: it could be compound
				// assignment division or a regex `/=.../`. After expressions
				// that cannot be valid assignment targets (YieldExpression,
				// literals, etc.), treat the new-line `/=` as a statement
				// boundary and break out of the infix loop so ASI fires.
				// When the LHS IS a valid assignment target (e.g. an
				// Identifier `x` followed by `\r/=-1`), `/=` is the legitimate
				// AssignmentOperator and we must NOT break — ASI would split
				// the statement into `x;` and a stranded `/= -1` (test262
				// language/expressions/compound-assignment/div-whitespace.js).
				if cur_type == .AssignDiv && cur_has_newline(p) {
					if !is_valid_assignment_target(left, false) {
						break
					}
				}
				left = parse_assignment_expr(p, left)
				continue
			}
		}

		if _, is_arrow := left.(^ArrowFunctionExpression); is_arrow {
			// ArrowFunction is an AssignmentExpression, but the ES grammar only
			// admits it where an AssignmentExpression is expected. It cannot be
			// used directly as the head of `?:` or a binary/logical expression;
			// callers must write `(() => {}) || x` to promote it through a
			// ParenthesizedExpression. Parameter parens in `() => {}` do not count.
			if left != p.last_paren_expr && int(op_prec) >= int(Precedence.Conditional) {
				report_error_coded(p, .K3062_OperatorPrecedenceParens, "Arrow function cannot be used as an unparenthesized operand")
			}
		}

		if op_prec == .Conditional {
			left = parse_conditional_expr(p, left)
			continue
		}

		// Trailing comma in parenthesized expression: don't consume comma before )
		if cur_type == .Comma && is_next_token(p, .RParen) {
			// §15.3.1 - A trailing comma after a rest element `...x` in
			// `(...x, ) => body` is a SyntaxError. Check before eating.
			if _, is_spread := left.(^SpreadElement); is_spread {
				report_error_coded(p, .K3041_RestForm, "Rest element may not have a trailing comma")
			}
			eat(p)
			break
		}

		// Comma operator → SequenceExpression
		if cur_type == .Comma {
			seq, seq_e := new_expr(p, SequenceExpression)
			seq.loc = loc_from_expr(left)
			// Cap bumped from 4 → 8 (S23). Profile on monaco: 1254 grow events
			// for sequence expressions with >4 commas. Common in `for (i = 0,
			// j = 0, k = 0; ...)` and minified `(a, b, c, d, e)` chains.
			seq.expressions = make([dynamic]^Expression, 0, 8, p.allocator)
			bump_append(&seq.expressions, left)
			for match_token(p, .Comma) {
				expr := parse_assignment_expression(p)
				if expr == nil { break }
				bump_append(&seq.expressions, expr)
			}
			seq.loc.end = prev_end_offset(p)
			left = seq_e
			continue
		}

		// Binary/logical operator
		// §13.6.1 - ExponentiationExpression : UnaryExpression `**`
		// ExponentiationExpression. The grammar specifically disallows an
		// unparenthesized UnaryExpression as the base, so `-3 ** 2`,
		// `!x ** 2`, `typeof x ** 2`, `delete o.x ** 2` etc. are all
		// SyntaxErrors. `(-3) ** 2` and `-(3 ** 2)` are legal because the
		// parentheses promote the inner UnaryExpression to a
		// PrimaryExpression (or because the unary applies to the whole
		// `**` form). Detect by inspecting the raw source span of the
		// left operand - a leading `(` means paren-wrapped.
		if cur_type == .Pow && left != nil {
			check_pow_unparenthesized_operand(p, left, cur_type)
		}

		eat(p)
		// `**` is the only right-associative binary operator (ECMA-262
		// §13.6): `2 ** 3 ** 2` must parse as `2 ** (3 ** 2)`. For
		// right-associativity the RHS is parsed at the operator's own
		// binding power (so a following `**` at the same precedence is
		// absorbed into the right operand); every other operator is
		// left-associative and parses its RHS one level tighter.
		next_min_prec := op_prec if cur_type == .Pow else Precedence(int(op_prec) + 1)

		// Track `in`-RHS context so PrivateIdentifier in primary-expr
		// position is rejected for `#x in #y` while staying legal for
		// `(#x in y)` (parens reset the flag in parse_primary_expr).
		prev_in_in_rhs := p.ctx.in_in_rhs
		if cur_type == .In { p.ctx.in_in_rhs = true }
		// Slice 14: scope_skip is tracked by the checker now
		// (CheckerContext.scope_skip), set by ck_walk_expr's
		// BinaryExpression / LogicalExpression cases for the duration
		// of operand-walks. The parser does not participate.
		right := parse_expr_with_prec(p, next_min_prec)
		p.ctx.in_in_rhs = prev_in_in_rhs
		if right == nil {
			report_error_coded(p, .K2020_ExpectedExpression, "Expected expression after operator")
			return left
		}

		if _, is_arrow := right.(^ArrowFunctionExpression); is_arrow {
			paren_wrapped := is_paren_wrapped_at(p, int(loc_from_expr(right).start))
			if !paren_wrapped {
				report_error_coded(p, .K3062_OperatorPrecedenceParens, "Arrow function cannot be used as an unparenthesized operand")
			}
		}

		// §14.4 - YieldExpression cannot be the right-hand operand of any
		// binary or logical operator (it has assignment-expression precedence).
		// Exception: a parenthesised `(yield n)` promotes the expression to
		// primary-expression level; with --preserve-parens off the wrapper
		// is stripped, so we detect the paren by scanning backwards from the
		// yield's span start, mirroring the `**` unary check above.
		if _, is_yield := right.(^YieldExpression); is_yield && cur_type != .Comma {
			yield_start := int(loc_from_expr(right).start)
			paren_wrapped := is_paren_wrapped_at(p, yield_start)
			if !paren_wrapped {
				// Structural parse error: see the LHS-form rationale
				// above. YieldExpression has assignment-expression
				// precedence and the binary-operator grammar rejects it.
				report_error_coded(p, .K3011_AwaitYieldExpressionContextRestricted,
					"'yield' expression cannot be the right-hand side of a binary operator")
			}
		}

		// §13.4 - `??` cannot be mixed with `&&`/`||` without parentheses.
		check_nullish_logical_mixing(p, left, right, cur_type)

		// Logical operators
		if cur_type == .LogicalOr || cur_type == .LogicalAnd || cur_type == .Nullish {
			logical, logical_e := new_expr(p, LogicalExpression)
			logical.loc = loc_from_expr(left)
			logical.operator = token_to_logical_op(cur_type)
			logical.left = left
			logical.right = right
			logical.loc.end = prev_end_offset(p)

			left = logical_e
			continue
		}

		// Regular binary operator
		binary, binary_e := new_expr(p, BinaryExpression)
		binary.loc = loc_from_expr(left)
		binary.operator = token_to_binary_op(cur_type)
		binary.left = left
		binary.right = right
		binary.loc.end = prev_end_offset(p)

		left = binary_e
	}

	return left
}

// check_nullish_logical_mixing enforces §13.4: nullish coalescing `??`
// cannot be combined with `&&` or `||` (in either operand position)
// without parentheses, and vice versa. Parenthesised sub-expressions are
// exempt (`(a && b) ?? c`, `a ?? (b || c)`). Cold diagnostic path lifted
// out of parse_expr_with_prec's infix loop as pure code motion.
check_nullish_logical_mixing :: proc(p: ^Parser, left: ^Expression, right: ^Expression, cur_type: TokenType) {
	if cur_type == .Nullish {
		if le, ok := left.(^LogicalExpression); ok &&
		   (le.operator == .And || le.operator == .Or) {
			paren_ok := is_paren_wrapped_at(p, int(le.loc.start))
			if !paren_ok {
				report_error_coded(p, .K3062_OperatorPrecedenceParens, "Nullish coalescing operator cannot be directly combined with '&&' or '||' operators without parentheses")
			}
		}
		if le, ok := right.(^LogicalExpression); ok &&
		   (le.operator == .And || le.operator == .Or) {
			paren_ok := is_paren_wrapped_at(p, int(le.loc.start))
			if !paren_ok {
				report_error_coded(p, .K3062_OperatorPrecedenceParens, "Nullish coalescing operator cannot be directly combined with '&&' or '||' operators without parentheses")
			}
		}
	} else if cur_type == .LogicalOr || cur_type == .LogicalAnd {
		if le, ok := left.(^LogicalExpression); ok &&
		   le.operator == .NullishCoalescing {
			paren_ok := is_paren_wrapped_at(p, int(le.loc.start))
			if !paren_ok {
				report_error_coded(p, .K3062_OperatorPrecedenceParens, "'&&' and '||' operators cannot be directly combined with '??' operator without parentheses")
			}
		}
		// Mirror check for the RIGHT operand: `0 || 0 ?? true` parses
		// the right-hand side at NullishCoalescing precedence (higher
		// than LogicalOr), producing `0 || (?? 0 true)`. Without this
		// the inner ?? slips past the spec rule. Test262: language/
		// expressions/coalesce/cannot-chain-head-with-logical-or.js.
		if le, ok := right.(^LogicalExpression); ok &&
		   le.operator == .NullishCoalescing {
			paren_ok := is_paren_wrapped_at(p, int(le.loc.start))
			if !paren_ok {
				report_error_coded(p, .K3062_OperatorPrecedenceParens, "'&&' and '||' operators cannot be directly combined with '??' operator without parentheses")
			}
		}
	}
}

// check_pow_unparenthesized_operand enforces §13.6.1: an unparenthesized
// UnaryExpression (or AwaitExpression) cannot be the left operand of `**`.
// Cold diagnostic path lifted out of parse_expr_with_prec's infix loop as
// pure code motion (the `cur_type == .Pow` dispatch stays in the caller).
check_pow_unparenthesized_operand :: proc(p: ^Parser, left: ^Expression, cur_type: TokenType) {
	_, is_unary := left.(^UnaryExpression)
	_, is_await := left.(^AwaitExpression)
	if is_unary || is_await {
		lhs_loc := loc_from_expr(left)
		lhs_start := lhs_loc.start
		lhs_end   := lhs_loc.end
		// Without --preserve-parens the UnaryExpression's span is
		// [unary_op, end) and the optional `(` lives one byte before.
		// Walk backwards over insignificant whitespace to detect it.
		paren_wrapped := is_paren_wrapped_at(p, int(lhs_start))
		// Found a '(' before the unary. Verify it closes
		// *before* the '**' - i.e. the ')' sits between the
		// UnaryExpression's end and the '**' token. If the ')'
		// is missing (or after '**') the '(' wraps the whole
		// binary expression, not just the unary operand:
		//   (-5) ** 6   → ')' at 3, before '**' at 5 → wrapped
		//   (-5 ** 6)   → ')' at 8, after  '**' at 4 → NOT
		if paren_wrapped {
			// Walk forward from lhs_end over whitespace looking
			// for ')'. Must appear before the current token (the '**').
			closing := false
			j := int(lhs_end)
			pow_off := int(cur_offset(p))
			for j < pow_off {
				ch := p.lexer.source_bytes[j]
				if ch == ')' { closing = true; break }
				if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { j += 1; continue }
				break
			}
			if !closing { paren_wrapped = false }
		}
		if !paren_wrapped {
			report_error_coded(p, .K3062_OperatorPrecedenceParens, "Unparenthesized unary expression cannot appear as the left operand of '**'")
		}
	}
}

// parse_unary_prefix_op parses a §13.5 prefix UnaryExpression
// (`+` / `-` / `~` / `!` / `typeof` / `void` / `delete` <UnaryExpression>).
// Lifted out of parse_unary_expr's dispatch switch as pure code motion: the
// operator token is still current on entry, and the helper always returns.
parse_unary_prefix_op :: proc(p: ^Parser) -> ^Expression {
	current := snap_current(p)
	eat(p)
	argument := parse_unary_expr(p)
	if argument == nil {
		report_error_coded(p, .K2020_ExpectedExpression, "Expected expression after unary operator")
		return nil
	}
	// §13.5 UnaryExpression : <op> UnaryExpression. YieldExpression
	// is at AssignmentExpression precedence - the spec disallows it as
	// the operand of a unary operator. Catches `void yield`, `!yield`,
	// `typeof yield`, `delete yield`, `+yield`, `-yield`, `~yield` in a
	// generator body. (`yield` outside a generator is an Identifier,
	// which IS a valid UnaryExpression operand, so the check is fine.)
	// A parenthesised `(yield)` promotes the expression to primary-
	// expression level; with --preserve-parens off the wrapper is
	// stripped, so we detect the paren by scanning backwards from
	// the yield's span start, mirroring the binary-op checks above.
	// (Test262 / OXC parity: `void (yield)` inside a generator is
	// legal; only the bare-yield form is rejected.)
	if y, is_yield := argument.(^YieldExpression); is_yield {
		yield_start := int(y.loc.start)
		paren_wrapped := is_paren_wrapped_at(p, yield_start)
		if !paren_wrapped {
			report_error_coded(p, .K3011_AwaitYieldExpressionContextRestricted,
				"'yield' expression cannot be the operand of a unary operator")
		}
	}
	if _, is_arrow := argument.(^ArrowFunctionExpression); is_arrow {
		paren_wrapped := is_paren_wrapped_at(p, int(loc_from_expr(argument).start))
		if !paren_wrapped {
			report_error_coded(p, .K3062_OperatorPrecedenceParens, "Arrow function cannot be used as an unparenthesized operand")
		}
	}
	unary, unary_e := new_expr(p, UnaryExpression)
	unary.loc = loc_from_token(&current)
	unary.operator = token_to_unary_op(current.type)
	unary.argument = argument
	unary.prefix = true
	unary.loc.end = prev_end_offset(p)
	// §13.5.1.1 — `delete o.#priv` is a SyntaxError. PrivateNames
	// have no observable [[Configurable]] state and the spec rejects
	// the form outright. Promoted from the semantic checker
	// (ck_check_unary_delete_private) so parser-only snaps reject the
	// class/elements/syntax/early-errors/delete cluster.
	if unary.operator == .Delete {
		// Check both direct MemberExpression and ChainExpression-wrapped MemberExpression.
		delete_arg := unary.argument
		if chain, is_chain := delete_arg.(^ChainExpression); is_chain && chain != nil {
			delete_arg = chain.expression
		}
		if me, is_member := delete_arg.(^MemberExpression); is_member && me != nil && me.property != nil {
			if _, is_private := me.property^.(^PrivateIdentifier); is_private {
				report_error_coded_span(p, .K3032_PrivateNameInvalid, u32(unary.loc.start), u32(unary.loc.start), "Private fields cannot be deleted")
			}
		}
		// §13.5.1.1 — in strict mode, `delete IdentifierReference`
		// is a SyntaxError (the bare identifier cannot reference a
		// configurable property). The argument must be a plain Identifier
		// at this point; --preserve-parens off strips the paren wrapper
		// so `delete (x)` and `delete x` both reach here.
		if p.ctx.strict_mode {
			if _, is_id := unary.argument.(^Identifier); is_id {
				report_error_coded_span(p, .K3051_StrictModeProhibited, u32(unary.loc.start), u32(unary.loc.start), "Deleting an unqualified identifier is not allowed in strict mode")
			}
		}
	}
	return unary_e
}

// parse_unary_prefix_update parses a §13.4 prefix UpdateExpression
// (`++` / `--` <UnaryExpression>). Lifted out of parse_unary_expr's dispatch
// switch as pure code motion: the operator token is still current on entry,
// and the helper always returns.
parse_unary_prefix_update :: proc(p: ^Parser) -> ^Expression {
	current := snap_current(p)
	eat(p)
	argument := parse_unary_expr(p)
	if argument == nil {
		// ECMA-262 §12.4.1 - prefix UpdateExpression requires a
		// UnaryExpression operand. `++;` / `--;` (no operand) and
		// `x\n++;` / `x\n--;` (line terminator splits postfix into
		// `x;` + bare `++;`) must be rejected. Test262 fixtures:
		//   language/asi/S7.9_A5.1_T1.js               // x \n ++;
		//   language/asi/S7.9_A5.3_T1.js               // x \n --;
		//   language/expressions/postfix-increment/    // (4 tests)
		//   language/expressions/postfix-decrement/    // (4 tests)
		op := "++" if current.type == .PlusPlus else "--"
		msg := fmt.tprintf("Unexpected token after prefix '%s'", op)
		report_error_coded(p, .K2040_UnexpectedToken, msg)
		return nil
	}
	update, update_e := new_expr(p, UpdateExpression)
	update.loc = loc_from_token(&current)
	update.operator = .Increment if current.type == .PlusPlus else .Decrement
	update.argument = argument
	update.prefix = true
	update.loc.end = prev_end_offset(p)
	if !is_simple_assignment_target(argument, !p.ctx.strict_mode) {
		report_error_coded(p, .K2050_InvalidLHS, "Invalid left-hand side expression in prefix operation")
	}
	// §13.4.4 — in strict mode `++` / `--` may not target an
	// IdentifierReference whose name is `eval` or `arguments`.
	// Promoted from the semantic checker
	// (ck_check_strict_update_eval_arguments).
	if p.ctx.strict_mode {
		if id, is_id := argument.(^Identifier); is_id && id != nil && is_eval_or_arguments(id.name) {
			msg := fmt.tprintf("Update of '%s' is not allowed in strict mode", id.name)
			report_error_coded_span(p, .K3051_StrictModeProhibited, u32(id.loc.start), u32(id.loc.start), msg)
		}
	}
	return update_e
}

// Merged unary + update + left-hand-side to reduce call depth (5→3 frames)
parse_unary_expr :: proc(p: ^Parser) -> ^Expression {
	#partial switch p.cur_type {
	case .Plus, .Minus, .BitNot, .Not, .Typeof, .Void, .Delete:
		return parse_unary_prefix_op(p)

	case .PlusPlus, .MinusMinus:
		return parse_unary_prefix_update(p)

	case .Await:
		// ECMA-262 §15.8 - `await` is only valid as an AwaitExpression
		// inside an async function (or at module top level, handled via
		// the separate top-level-await detector below). In a non-async,
		// non-module context `await` is just an IdentifierReference -
		// `function f(await) { return await; }`, `await: 1;` (label),
		// `class await {}` (binding name) all need to fall through to
		// the identifier path. Mirror the `yield` handling: when the
		// lookahead is unambiguously NOT the start of an argument
		// (semicolon, operator, terminator), fall through. Otherwise
		// keep the long-standing diagnostic for `await expr` typos.
	if !p.ctx.in_async && !p.ctx.in_async_params {
		at_module_top := !p.ctx.in_function && !p.ctx.in_field_init
		// In a Module file, `await` at top level (or any nested
		// non-function scope) is the AwaitExpression keyword - TLA.
		// Identifier fall-through only applies to Script source code.
		// Class field initializers are NOT TLA context even in modules.
		in_module_file := false
		if st, have := p.force_source_type.(SourceType); have && st == .Module {
			in_module_file = true
		}
		// Lazy pre-scan: TLA (top-level `await expr`) is module-only.
		ensure_module_syntax_resolved(p)
		if p.has_module_syntax {
			in_module_file = true
		}
		if p.ctx.in_static_block {
			// §15.7.5 — `await` as AwaitExpression inside a class
			// static block is a SyntaxError. The static block runs
			// under [~Await], so `await expr` has no valid meaning.
			report_error_coded(p, .K3011_AwaitYieldExpressionContextRestricted,
				"'await' is not allowed in a class static block")
		} else if p.ctx.in_ts_namespace {
			// TS namespace body is not an async context. `await` is
			// an identifier, not a keyword, even in module-mode files.
			if yield_next_is_expression_argument(p) {
				report_error_coded(p, .K3011_AwaitYieldExpressionContextRestricted,
					"'await' is only allowed within async functions and at the top levels of modules")
			}
			break
		} else if at_module_top && in_module_file {
			// TLA - fall through to AwaitExpression parse below.
		} else if !at_module_top {
			// Inside a non-async function in script: `await` is an
			// identifier. Fall through unless the next token clearly
			// continues as an expression argument (typo case).
			if !yield_next_is_expression_argument(p) {
				break
			}
			report_error_coded(p, .K3011_AwaitYieldExpressionContextRestricted,
				"'await' is only allowed within async functions and at the top levels of modules")
		} else {
			// At top level in Script (or auto-detect with no module
			// syntax yet seen). `await: 1;` (label), `await;` (bare
			// ref), `let await = 1;` etc. all want the identifier
			// path. Same lookahead heuristic as the in-function case.
			if !yield_next_is_expression_argument(p) {
				break
			}
		}
	}
		// §14.13.1 LabelIdentifier - in async context, "await" is a
		// reserved word, so `await:` as a LabelledStatement head is a
		// SyntaxError.
		if p.ctx.in_async && p.lexer != nil {
			ensure_nxt(p)
		}
		if p.ctx.in_async && p.lexer != nil && p.lexer.nxt.kind == .Colon {
			report_error_coded(p, .K3010_AwaitYieldAsBindingName,
				"'await' cannot be used as a label identifier in an async function")
		}
		// Top-level `await` is Module syntax. When the caller pinned
		// `--source-type=script` it's a SyntaxError.
		if !p.ctx.in_function {
			if st, have := p.force_source_type.(SourceType); have && st == .Script {
				report_error_coded(p, .K3022_ModuleSyntaxInScript, "Top-level 'await' is only valid in module code")
			}
		}
		// ECMA-262 §15.8.1 / §15.9.1 / §15.6.1 - "It is a Syntax Error if
		// FormalParameters (or CoverCallExpressionAndAsyncArrowHead)
		// Contains AwaitExpression is true." An AwaitExpression in a
		// parameter default of any async function-like form is forbidden
		// even though the body itself is async - params are evaluated in
		// the outer context.
		// §15.6.1 / §15.8.1 / §15.9.1 "AwaitExpression in formal
		// parameters" early error: `p.ctx.in_async_params` is set by
		// parse_function_params before calling parse_function_params.
		if p.ctx.in_async_params {
			report_error_coded(p, .K3011_AwaitYieldExpressionContextRestricted,
				"'await' expression is not allowed in formal parameters of an async function")
		}
		current := snap_current(p)
		eat(p)
		prev_private_in_allowed := p.ctx.private_in_allowed
		p.ctx.private_in_allowed = false
		argument := parse_unary_expr(p)
		p.ctx.private_in_allowed = prev_private_in_allowed
		if argument == nil {
			// `await` without an operand. Legal only as an
			// IdentifierReference, which is forbidden in async context
			// anyway. Report and synthesise an identifier so the parse
			// tree stays structurally valid; the earlier
			// "await outside of async function" check at the top of
			// this branch already covers non-async contexts.
			if p.ctx.in_async || p.ctx.in_async_params || !p.ctx.in_function {
				report_error_coded(p, .K2020_ExpectedExpression, "'await' expression requires an operand")
			}
			id, id_e := new_expr(p, Identifier)
			id.loc = loc_from_token(&current)
			// source-slice (current.value), not literal.
			// String literals are RODATA-pointing and break raw_transfer.
			id.name = current.value
			id.loc.end = current.end
			return id_e
		}
		await, await_e := new_expr(p, AwaitExpression)
		await.loc = loc_from_token(&current)
		await.argument = argument
		await.loc.end = prev_end_offset(p)
		// Top-level await is module syntax
		if !p.ctx.in_function {
			p.has_module_syntax = true
		}
		return await_e

	case .Dot3:
		current := snap_current(p)
		eat(p)
		argument := parse_unary_expr(p)
		if argument == nil { return nil }
		spread, spread_e := new_expr(p, SpreadElement)
		spread.loc = loc_from_token(&current)
		spread.argument = argument
		spread.loc.end = prev_end_offset(p)
		return spread_e

	case .Yield:
		// ECMA-262 §15.5 - YieldExpression is only grammatically
		// valid inside a GeneratorBody. Outside a generator `yield`
		// is an IdentifierReference (in sloppy mode) or a strict-
		// reserved word flagged by the binding checks. We still catch
		// the common `yield expr` mistake in a non-generator: if the
		// lookahead unambiguously starts an AssignmentExpression
		// argument (no newline, no operator / postfix / call /
		// terminator that could continue `yield` as an identifier)
		// we emit the "only allowed in a generator body" error and
		// still parse as YieldExpression for recovery. Otherwise we
		// fall through to the identifier path so `yield;`, `yield(1)`,
		// `yield.x`, `yield + 1`, `yield || 1`, `yield?1:2`,
		// `` yield`t` `` all behave as OXC / Acorn expect.
		if p.ctx.in_generator {
			return parse_yield_expr(p)
		}
		// §15.5.1 - inside a generator's FormalParameters, even bare
		// `yield` (no argument) is a YieldExpression and a SyntaxError.
		// parse_yield_expr's own in_generator_params check fires the
		// diagnostic; we just have to commit to the YieldExpression
		// production here so it actually runs.
		if p.ctx.in_generator_params {
			return parse_yield_expr(p)
		}
		if yield_next_is_expression_argument(p) {
			report_error_coded(p, .K3011_AwaitYieldExpressionContextRestricted,
				"'yield' expression is only allowed in a generator body")
			return parse_yield_expr(p)
		}
		// Fall through - `yield` is parsed as IdentifierReference by
		// parse_left_hand_side_expr → parse_primary_expr (line 5577).
	}

	// Common path: primary expression + optional postfix ++ / -- (inlined parse_update_expr)
	// Fast-path: identifier → member/call chain (covers ~60% of expressions)
	expr: ^Expression
	if is_id_like_for_unary(p.cur_type) {
		// ECMA-262 §12.7.2 - escaped-ReservedWord in IdentifierReference
		// position. This fast-path bypasses parse_primary_expr, so the
		// same check that lives on the slow path has to run here too.
		report_escaped_reserved_word(p)
		// §12.6.1.1 strict-mode IdentifierReference reservation.
		if p.ctx.strict_mode {
			if is_strict_reserved_word(p.cur_type) || is_strict_reserved_name(cur_value(p)) {
				msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", cur_value(p))
				report_error_coded(p, .K3050_StrictModeReserved, msg)
			}
		}
		// Escaped `async` before `function` is SyntaxError (fast path).
		if cur_has_escape(p) && cur_value_eq(p, "async") {
			nxt := peek_token(p)
			if nxt.type == .Function && !nxt.had_line_terminator {
				report_error_coded(p, .K3015_KeywordContainsEscape, "'async' keyword must not contain Unicode escape sequences")
			}
		}
		// §15.7.10 / §15.7.5 — `arguments` as IdentifierReference is
		// forbidden in class field initializers and class static blocks.
		// Gate on context flags FIRST: the string compare is only worth
		// running when we're in one of those rare scopes. Real-world JS
		// is overwhelmingly outside any class-field / class-static-block
		// context, so the early-out hits ~100% of the hot path.
		if (p.ctx.in_static_block || p.ctx.in_field_init) && cur_value_eq(p, "arguments") {
			if p.ctx.in_static_block {
				report_error_coded(p, .K3031_StaticBlockOrFieldInitRestriction, "'arguments' is not allowed in a class static block")
			} else {
				report_error_coded(p, .K3031_StaticBlockOrFieldInitRestriction, "'arguments' cannot appear in a class field initializer")
			}
		}
		// §16.2 / §15.7.5 — `await` as IdentifierReference in async /
		// async-params / class-static-block context is enforced by the
		// semantic checker (ck_check_identifier_await_reserved). The
		// has_escape flag is propagated to ^Identifier below so the checker
		// can match the parser's narrow gating (only escaped forms reach
		// this code path with cooked name "await"; non-escaped `await`
		// lexes as `.Await` and parses as AwaitExpression).
		id_has_escape := cur_has_escape(p)
		// §12.1.1 - `enum` is a FutureReservedWord that is ALWAYS
		// reserved. The lexer emits it as .Identifier (contextual for
		// TS enum decls). Mirrors the check in parse_primary_expr.
		if !cur_has_escape(p) && cur_value_eq(p, "enum") {
			report_error_coded(p, .K4054_EnumInvalid, "'enum' is a reserved word")
		}
		// Inline identifier parse + LHS tail. Pull only the fields we need
		// out of the current token before eat() advances - the FastToken
		// bytes and was showing up in the parse_unary_expr profile when this
		// fast path runs once per identifier in the program.
		// The lexer only stores byte
		
		// offsets; line / column are computed lazily by `report_error` via
		// `offset_to_line_col` when an error is actually emitted. Reading
		// them here returned permanent 0, then we'd write 0 back into
		// `id.loc.{line,column}` - four wasted memory ops per identifier on
		// the hot path. Skip the loads, leave the Loc fields zero-initialised.
		id_offset := cur_offset(p)
		id_value  := cur_value(p)
		eat(p)
		id, id_e := new_expr(p, Identifier)
		id.loc.start = id_offset
		id.loc.end   = prev_end_offset(p)
		id.name = id_value
		id.has_escape = id_has_escape
		expr = id_e
		// Inline LHS tail loop (member access, calls)
		expr = parse_lhs_tail(p, expr, true)
	} else {
		expr = parse_left_hand_side_expr(p)
	}
	if expr == nil { return nil }

	// ECMA-262 §12.4 Restricted Production: no LineTerminator between the
	// LHS and postfix `++`/`--`. If there's a newline, ASI inserts a
	// semicolon so the operator starts the next statement as a prefix op.
	if (p.cur_type == .PlusPlus || p.cur_type == .MinusMinus) && !cur_has_newline(p) {
		current := snap_current(p)
		eat(p)
		update, update_e := new_expr(p, UpdateExpression)
		update.loc = loc_from_expr(expr)
		update.operator = .Increment if current.type == .PlusPlus else .Decrement
		update.argument = expr
		update.prefix = false
		update.loc.end = prev_end_offset(p)
		if !is_simple_assignment_target(expr, !p.ctx.strict_mode) {
			report_error_coded(p, .K2050_InvalidLHS, "Invalid left-hand side expression in postfix operation")
		}
		// §13.4.4 — strict-mode `++` / `--` cannot target eval / arguments.
		if p.ctx.strict_mode {
			if id, is_id := expr.(^Identifier); is_id && id != nil && is_eval_or_arguments(id.name) {
				msg := fmt.tprintf("Update of '%s' is not allowed in strict mode", id.name)
				report_error_coded_span(p, .K3051_StrictModeProhibited, u32(id.loc.start), u32(id.loc.start), msg)
			}
		}
		return update_e
	}

	return expr
}

// LHS tail: member access, computed access, calls, tagged templates, optional chaining
// Fast-exit table for parse_lhs_tail: true for tokens that continue a
// LHS expression (member access, call, tagged template, optional chain,
// TS instantiation). The common case (bare identifier, literal, etc.)
// exits via a single table load instead of falling through 7+ switch
// comparisons.
is_lhs_continuation_table: [len(TokenType)]bool

@(init)
init_is_lhs_continuation_table :: proc "contextless" () {
	is_lhs_continuation_table[TokenType.Dot]           = true
	is_lhs_continuation_table[TokenType.OptionalChain]  = true
	is_lhs_continuation_table[TokenType.LBracket]       = true
	is_lhs_continuation_table[TokenType.LParen]         = true
	is_lhs_continuation_table[TokenType.TemplateHead]    = true
	is_lhs_continuation_table[TokenType.Template]        = true
	is_lhs_continuation_table[TokenType.Not]             = true  // TS non-null assertion
	is_lhs_continuation_table[TokenType.LAngle]          = true  // TS type args
	is_lhs_continuation_table[TokenType.LShift]          = true  // TS nested type args
}

parse_lhs_tail :: #force_inline proc(p: ^Parser, start_expr: ^Expression, allow_call: bool) -> ^Expression {
	expr := start_expr
	chain_start: Loc
	is_chain := false
	for {
		// Fast exit: ~60% of expressions are bare identifiers with no
		// member/call tail. One table load replaces 7+ switch comparisons.
		if !is_lhs_continuation_table[p.cur_type] { break }
		#partial switch p.cur_type {
		case .Dot:
			if _, is_inst := expr^.(^TSInstantiationExpression); is_inst {
				report_error_coded(p, .K4062_InstantiationExprForm, "An instantiation expression cannot be followed by a property access")
			}
			eat(p)
			// §13.3.1 - MemberExpression `.` IdentifierName | PrivateIdentifier.
			// String / Number / template literals after `.` are SyntaxErrors.
			// Test262: language/expressions/property-accessors/non-identifier-name.js.
			if !is_identifier_like_token(p.cur_type) && p.cur_type != .PrivateIdentifier &&
			   !is_keyword_usable_as_property_name(p.cur_type) {
				report_error_coded(p, .K2021_ExpectedIdentifier, "Expected identifier after '.'")
				return expr
			}
			// `.in` / `.instanceof` etc.: the lexer's can_start_regex set
			// includes these as regex-starters (they're operators in most
			// contexts), so the next `/` was pre-fetched as a regex literal.
			// In property-access position (\`a.in / b\`) it's division. Relex
			// before consuming the property name. Test:
			// babel/core/uncategorised/326/input.ts (`a.in / b`).
			ensure_nxt(p)
			if (p.cur_type == .In || p.cur_type == .Instanceof) &&
			   p.lexer.nxt.kind == .RegularExpression {
				// Drop any "unterminated regex" lex error that came from
				// the speculative regex-lex.
				for len(p.lexer.lexer_errors) > 0 {
					last := p.lexer.lexer_errors[len(p.lexer.lexer_errors) - 1]
     ensure_nxt(p)
					if last.offset >= p.lexer.nxt.start {
						pop(&p.lexer.lexer_errors)
					} else { break }
				}
				ensure_nxt(p)
				p.lexer.offset = int(p.lexer.nxt.start)
				p.lexer.nxt = lex_slash_as_div(p.lexer)
				p.lexer.nxt_valid = true
			}
			prop := parse_identifier_name(p)
			member, member_e := new_expr(p, MemberExpression)
			member.loc = loc_from_expr(expr)
			// OXC includes the `(` in MemberExpression span when object was parenthesized.
			if p.pending_paren_start != max(u32) && p.pending_paren_start <= member.loc.start {
				member.loc.start = p.pending_paren_start
				p.pending_paren_start = max(u32)
			}
			member.object = expr
			// Check if this is a private identifier (starts with #)
			if len(prop.name) > 0 && prop.name[0] == '#' {
				// Create PrivateIdentifier, strip the # prefix
				pid, pid_e := new_expr(p, PrivateIdentifier)
				pid.loc = prop.loc
				pid.name = prop.name[1:]
				p.private_id_count += 1
				member.property = pid_e
				// Grammar: `PrivateName :: # IdentifierName` - there must be no
				// whitespace between `#` and the identifier. If `pid.name == ""`
				// the lexer saw only `#` with no following IdentifierName.
				if pid.name == "" {
					report_error_coded(p, .K3032_PrivateNameInvalid, "Private identifier must not have whitespace after '#'")
				}
				// §15.7.3 — `obj.#x` outside any class body cannot resolve;
				// inside a class, queue for end-of-body validation.
				if p.class_depth == 0 {
					report_error_coded(p, .K3032_PrivateNameInvalid, "Private name reference is not allowed outside of a class")
				} else if pid.name != "" {
					append(&p.pending_priv_refs, PendingPrivRef{name = pid.name, loc = pid.loc, depth = p.class_depth})
				}
				// §15.7.3 — `super.#name` is a SyntaxError.
				if expr != nil {
					if _, is_super := expr^.(^Super); is_super {
						report_error_coded(p, .K3032_PrivateNameInvalid, "Private fields cannot be accessed through 'super'")
					}
				}
			} else {
				// Create regular Identifier
				id, id_e := new_expr(p, Identifier)
				id.loc = prop.loc
				id.name = prop.name
				member.property = id_e
			}
			member.computed = false
			member.optional = false
			member.loc.end = prev_end_offset(p)
			expr = member_e
		case .OptionalChain:
			if !allow_call {
				return expr
			}
			if !is_chain {
				chain_start = loc_from_expr(expr)
				is_chain = true
				// ECMA-262 §13.3.10 — OptionalExpression chains only from
				// MemberExpression or CallExpression. The bare `new X` form
				// (no argument list) is a NewExpression and cannot be the
				// head of an optional chain (`new Foo?.()` is a SyntaxError).
				// However `new X(...)` IS a MemberExpression per the grammar:
				//   MemberExpression : new MemberExpression Arguments
				// so `new X(args)?.y` is legal and parses as `(new X(args))?.y`.
				// Distinguish by whether the NewExpression captured argument
				// tokens (arguments == nil ~= no `()` after the callee).
				if new_expr_node, is_new := expr^.(^NewExpression); is_new && new_expr_node.arguments == nil {
					report_error_coded(p, .K2040_UnexpectedToken, "Invalid optional chain from new expression")
				}
			}
			eat(p)
			if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) || is_token(p, .PrivateIdentifier) {
				if _, is_inst := expr^.(^TSInstantiationExpression); is_inst {
					report_error_coded(p, .K4062_InstantiationExprForm, "An instantiation expression cannot be followed by a property access")
				}
				is_private_chain := is_token(p, .PrivateIdentifier)
				prop := parse_identifier_name(p)
				member, member_e := new_expr(p, MemberExpression)
				member.loc = loc_from_expr(expr)
				member.object = expr
				// `obj?.#priv` - PrivateIdentifier on the RHS of an optional
				// chain is legal per the OptionalChain grammar (§13.3.10).
				if is_private_chain || (len(prop.name) > 0 && prop.name[0] == '#') {
					pid, pid_e := new_expr(p, PrivateIdentifier)
					pid.loc = prop.loc
					name := prop.name
					if len(name) > 0 && name[0] == '#' { name = name[1:] }
					pid.name = name
					p.private_id_count += 1
					member.property = pid_e
					// §15.7.3 — `obj?.#x` outside any class cannot resolve;
					// inside a class, queue for end-of-body validation.
					if p.class_depth == 0 {
						report_error_coded(p, .K3032_PrivateNameInvalid, "Private name reference is not allowed outside of a class")
					} else if pid.name != "" {
						append(&p.pending_priv_refs, PendingPrivRef{name = pid.name, loc = pid.loc, depth = p.class_depth})
					}
				} else {
					// Create regular Identifier
					ident, ident_e := new_expr(p, Identifier)
					ident.loc = prop.loc
					ident.name = prop.name
					member.property = ident_e
				}
				member.computed = false
				member.optional = true // ESTree: mark the `?.` site on the node it produced
				member.loc.end = prev_end_offset(p)
				expr = member_e
			} else if is_token(p, .LBracket) {
				if _, is_inst := expr^.(^TSInstantiationExpression); is_inst {
					report_error_coded(p, .K4062_InstantiationExprForm, "An instantiation expression cannot be followed by a property access")
				}
				eat(p)
				// Same Expression-not-AssignmentExpression rule as the
				// non-optional `[...]` case above. Optional-chain subscript
				// `obj?.[0, 1]` is legal too.
				prev_no_in_opt := p.ctx.no_in
				p.ctx.no_in = false
				prop := parse_expression(p)
				p.ctx.no_in = prev_no_in_opt
				if prop == nil { return nil }
				if !expect_token(p, .RBracket) { return nil }
				member, member_e := new_expr(p, MemberExpression)
				member.loc = loc_from_expr(expr)
				member.object = expr
				member.property = prop
				member.computed = true
				member.optional = true // ESTree: mark the `?.` site on the node it produced
				member.loc.end = prev_end_offset(p)
				expr = member_e
			} else if is_token(p, .LParen) {
				args := parse_arguments(p)
				call := new_node(p, CallExpression)
				call.loc = loc_from_expr(expr)
				call.callee = expr
				call.arguments = args
				call.optional = true // ESTree: mark the `?.` site on the node it produced
				call.loc.end = prev_end_offset(p)
				expr = expression_from(p, call)
			} else if is_open_angle_or_lshift(p) && (p.lang == .TS || p.lang == .TSX) {
				// `f?.<T>()` - optional-chain call with TS type arguments.
				// The type-arg list MUST be followed by `(args)` per babel /
				// OXC; otherwise it's a parse error. Build a CallExpression
				// with type_parameters inside the chain. Test:
				// babel/typescript/type-arguments/call-optional-chain/input.ts.
				targs := parse_ts_type_arguments(p)
				if !is_token(p, .LParen) {
					report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected '(' after type arguments in optional call")
					return expr
				}
				args := parse_arguments(p)
				call := new_node(p, CallExpression)
				call.loc = loc_from_expr(expr)
				call.callee = expr
				call.arguments = args
				call.type_parameters = targs
				call.optional = true // ESTree: mark the `?.` site on the node it produced
				call.loc.end = prev_end_offset(p)
				expr = expression_from(p, call)
			} else {
				report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token after ?.")
				return expr
			}
		case .LBracket:
			if _, is_inst := expr^.(^TSInstantiationExpression); is_inst {
				report_error_coded(p, .K4062_InstantiationExprForm, "An instantiation expression cannot be followed by a property access")
			}
			eat(p)
			// Consume pending_paren_start the same way the `.Dot` case
			// above does. When the object was parenthesized (`(expr)[0]`),
			// OXC extends the MemberExpression's start to the `(`. More
			// importantly, the stamp MUST be cleared here - otherwise it
			// leaks past this computed-member into sibling expressions and
			// later statements (observed on antd.js where a stray
			// `(a || b)[0]` expression dragged its paren-start into an
			// unrelated arrow function 83 UTF-16 units downstream).
			// We clear even when we don't actually widen the span (the
			// `paren_start > member.start` branch), because the stamp was
			// set for THIS member access by the outer `(expr)` parser; its
			// intent doesn't survive past us.
			saved_bracket_paren := p.pending_paren_start
			p.pending_paren_start = max(u32)
			// MemberExpression [ Expression ] - Expression includes the
			// comma operator, so `a[0, 1]` is legal (evaluates to a[1]).
			// Reset no_in inside `[...]` so `for (x[a in b]; ...)` parses.
			prev_no_in_sub := p.ctx.no_in
			p.ctx.no_in = false
			prop := parse_expression(p)
			p.ctx.no_in = prev_no_in_sub
			if prop == nil { return nil }
			if !expect_token(p, .RBracket) { return nil }
			mem2, mem2_e := new_expr(p, MemberExpression)
			mem2.loc = loc_from_expr(expr)
			if saved_bracket_paren != max(u32) && saved_bracket_paren <= mem2.loc.start {
				mem2.loc.start = saved_bracket_paren
			}
			mem2.object = expr
			mem2.property = prop
			mem2.computed = true
			mem2.optional = false
			mem2.loc.end = prev_end_offset(p)
			expr = mem2_e
		case .LParen:
			if !allow_call {
				return expr
			}
			// ASI guard: `(` on a new line after an ArrowFunctionExpression
			// with a block body should NOT continue as a call expression.
			// In TS mode, try_parse_ts_arrow_params builds the full arrow
			// inside parse_primary_expr; without this guard the `(` would
			// chain as `(() => { ... })(nextArrow)` instead of ASI-separating
			// into two statements. Matches OXC/V8 behavior.
			if cur_has_newline(p) {
				if _, is_arrow := expr^.(^ArrowFunctionExpression); is_arrow {
					return expr
				}
			}
			if _, is_arrow_call := expr^.(^ArrowFunctionExpression); is_arrow_call {
				if p.pending_paren_start == max(u32) {
					report_error_coded(p, .K2070_RequiredFormOrBinding, "Arrow function must be parenthesized before call")
				}
			}
			// §15.7.6 SuperCall: `super(...)` is only legal inside the
			// constructor of a derived class.
			if _, is_super := expr^.(^Super); is_super {
				if !p.ctx.in_derived_constructor {
					report_error_coded(p, .K3033_SuperInvalidContext, "'super' call is only allowed in the constructor of a derived class")
				}
			}
			// Save and clear pending_paren_start before parsing arguments.
			// The paren-start from the callee must not propagate into argument
			// sub-expressions (e.g. `(0,f)({prop: g(x)})` - g(x) must not
			// inherit the outer paren offset and shift its own start).
			saved_paren_start := p.pending_paren_start
			p.pending_paren_start = max(u32)
			args := parse_arguments(p)
			call := new_node(p, CallExpression)
			call.loc = loc_from_expr(expr)
			if saved_paren_start != max(u32) && saved_paren_start <= call.loc.start {
				call.loc.start = saved_paren_start
			}
			call.callee = expr
			call.arguments = args
			call.optional = false
			call.loc.end = prev_end_offset(p)
			expr = expression_from(p, call)
		case .TemplateHead, .Template:
			// ECMA-262 §13.3.5 - `TaggedTemplateExpression` is a SyntaxError
			// when the tag is an OptionalExpression: the grammar rule
			// `MemberExpression : MemberExpression TemplateLiteral` (and the
			// CallExpression form) cannot compose with optional chaining
			// because the runtime would have to handle `undefined?.foo\`t\``
			// which the spec explicitly forbids. Once we're inside an
			// optional chain (`is_chain`), any template tail is an error.
			if is_chain {
				report_error_coded(p, .K3068_OptionalChainTaggedTemplate, "Tagged template literals cannot appear in an optional chain")
			}
			tagged, tagged_e := new_expr(p, TaggedTemplateExpression)
			tagged.loc = loc_from_expr(expr)
			tagged.tag = expr
			// Tagged template literals don't enforce the strict-mode
			// LegacyOctal/\8/\9 escape rules on their quasi; invalid
			// escapes surface via `cooked: null` at the consumer. Pass
			// `tagged=true` so parse_template_literal skips the check.
			tagged.quasi = parse_template_literal(p, true)
			tagged.loc.end = prev_end_offset(p)
			expr = tagged_e
		case .Not:
			// TS non-null assertion `x!`. Only consume `!` as a postfix when
			// the next token can't start a new expression - otherwise `a!b` is
			// ambiguous. Safe next-tokens: operator/punct/terminator.
			// Before checking nxt, handle the regex/division ambiguity.
			// The lexer's can_start_regex saw `!` (prefix-NOT) and lexed
			// the next `/` as regex. In TS mode, postfix `!` (non-null
			// assertion) means `/` is division. Re-lex the lookahead.
   ensure_nxt(p)
			if p.lexer.nxt.kind == .RegularExpression && allow_ts_mode(p) {
				// Remove any "Unterminated regular expression" error that
				// the lexer emitted when it mis-lexed the `/` as regex.
				for len(p.lexer.lexer_errors) > 0 {
					last := p.lexer.lexer_errors[len(p.lexer.lexer_errors) - 1]
     ensure_nxt(p)
					if last.offset >= p.lexer.nxt.start {
						pop(&p.lexer.lexer_errors)
					} else { break }
				}
				ensure_nxt(p)
				p.lexer.offset = int(p.lexer.nxt.start)
				p.lexer.nxt = lex_slash_as_div(p.lexer)
				p.lexer.nxt_valid = true
			}
			ensure_nxt(p)
			nxt := p.lexer.nxt.kind
			allow := false
			#partial switch nxt {
			case .Dot, .OptionalChain, .LBracket, .LParen, .Comma, .Semi,
			     .RParen, .RBracket, .RBrace, .Assign, .AssignAdd, .AssignSub,
			     .AssignMul, .AssignDiv, .AssignMod, .AssignPow, .AssignLShift,
			     .AssignRShift, .AssignURShift, .AssignBitAnd, .AssignBitOr,
			     .AssignBitXor, .AssignLogicalAnd, .AssignLogicalOr,
			     .AssignNullish, .Plus, .Minus, .Mul, .Div, .Mod, .Pow,
			     .LogicalAnd, .LogicalOr, .Nullish, .BitAnd, .BitOr, .BitXor,
			     .LShift, .RShift, .URShift, .Eq, .NotEq, .EqStrict, .NotEqStrict,
			     .LAngle, .RAngle, .LEq, .GEq, .Question, .Colon,
			     .Arrow, .EOF, .In, .Instanceof, .As, .Satisfies, .Not,
			     .PlusPlus, .MinusMinus:
				allow = true
			}
			// ASI follower: if the next token is on a new line, consuming
			// `!` here is safe - the next token will trigger ASI in the
			// caller's statement-end check. Without this, `null!\nlet x =
			// 2` reported "Expected semicolon" because the `!` lookahead
			// saw `let` (an Identifier-like) and refused to consume.
   ensure_nxt(p)
			if !allow && (p.lexer.nxt.flags & FLAG_NEW_LINE) != 0 {
				allow = true
			}
			// IMPORTANT: in Odin `break` inside `switch` inside `for` exits
			// the SWITCH only. If we just `break`, the for-loop reruns with
			// p.cur_type still == .Not - infinite loop. Must exit the tail
			// walk (the `!` isn't ours; leave it for the caller's expression
			// parser to treat as an error or binary context).
			if !allow {
				if is_chain {
					chain := new_node(p, ChainExpression)
					chain.loc = chain_start
					chain.expression = expr
					chain.loc.end = prev_end_offset(p)
					return expression_from(p, chain)
				}
				return expr
			}
			eat(p) // consume `!`
			// After consuming `!` as a non-null assertion, the next token
			// may have been mis-lexed as regex (because `!` is in the
			// lexer's can_start_regex set for the prefix-NOT case). The
			// postfix assertion means `/` is always division here.
			if !allow_ts_mode(p) {
				report_error_coded(p, .K4053_TSOnlyInJS, "Non-null assertions can only be used in TypeScript files")
			}

			nn, nn_e := new_expr(p, TSNonNullExpression)
			nn.loc = loc_from_expr(expr)
			nn.expression = expr
			nn.loc.end = prev_end_offset(p)
			expr = nn_e
			continue
		case .LAngle, .LShift:
			if _, is_super := expr^.(^Super); is_super {
				report_error_coded(p, .K3033_SuperInvalidContext, "'super' can only be used with function calls or in property accesses")
			}
			// TS generic call / instantiation expression: `foo<T>(args)` or
			// `foo<T>` as a stand-alone TSInstantiationExpression. Only in
			// TS / TSX mode, and only via trial-parse because `<` is also
			// a binary operator. If the trial parses successfully AND the
			// token after `>` can legitimately follow type arguments (`(`,
			// `` ` ``, `.`, `?.`, `,`, `;`, etc.), commit; otherwise rollback
			// so the outer binary-expression parser handles the `<`.
			if p.lang != .TS && p.lang != .TSX {
				if is_chain {
					chain := new_node(p, ChainExpression)
					chain.loc = chain_start
					chain.expression = expr
					chain.loc.end = prev_end_offset(p)
					return expression_from(p, chain)
				}
				return expr
			}
			snap := lexer_snapshot(p)
			targs := parse_ts_type_arguments(p)
			// Decide: did the trial consume `<...>` cleanly and land on a
			// followable token? If not, rollback.
			// Two follow sets:
			//   * `call_follow` - `(` / template head: this is a generic call
			//     (CallExpression with type_parameters) or tagged template.
			//   * `inst_follow` - anything that can follow a complete
			//     expression but not start one (binary / postfix / chain
			//     terminators / etc.). Commits to TSInstantiationExpression.
			// Tokens that can plausibly start a NEW expression on the RHS
			// (Identifier, Number, String, `[`, `{`, ...) are deliberately NOT
			// followers, so `f<x> y` rolls back and is reported as a binary-
			// expression error rather than mis-committed as instantiation.
			call_follow := false
			inst_follow := false
			if targs != nil && len(p.errors) == snap.errors_len {
				#partial switch p.cur_type {
				case .LParen, .TemplateHead, .Template:
					call_follow = true
				case .Dot, .OptionalChain,
				     .Comma, .Semi, .RParen, .RBracket, .RBrace,
				     .EOF, .Colon, .Question,
				     .Eq, .NotEq, .EqStrict, .NotEqStrict,
				     .LogicalAnd, .LogicalOr, .Nullish,
				     .As, .Satisfies,
				     // Relational / equality operators (TSInstantiation
				     // followed by binary continuation: `a<b> instanceof C`,
				     // `a<b> in c`, `a<b> < c`, `a<b> >= c`).
				     .Instanceof, .In, .LAngle, .RAngle, .LEq, .GEq,
				     // Arithmetic / bitwise (`a<b> + c`, `a<b> | c`, `a<b> << c`).
				     .Plus, .Minus, .Mul, .Div, .Mod, .Pow,
				     .BitAnd, .BitOr, .BitXor,
				     .LShift, .RShift, .URShift,
				     // Compound assignment lands on whatever target shape
				     // the outer parser permits - `a<b> += c` is invalid in
				     // the spec (instantiation expr isn't an assignment
				     // target) but we still want to commit so the error fires
				     // at the outer level rather than mis-rolling back to a
				     // bogus comparison parse.
				     .AssignAdd, .AssignSub, .AssignMul, .AssignDiv, .AssignMod,
				     .AssignPow, .AssignLShift, .AssignRShift, .AssignURShift,
				     .AssignBitAnd, .AssignBitOr, .AssignBitXor,
				     .AssignLogicalAnd, .AssignLogicalOr, .AssignNullish:
					inst_follow = true
				}
				// ASI follower: when the next token sits on a new line, a
				// freshly-completed `f<T>` is the end-of-statement form
				// (TSInstantiationExpression) and the next line begins a
				// new statement. Without this, `const x = f<true>\nlet y
				// = 0` rolled back to a comparison parse. Test:
				// babel/typescript/type-arguments/instantiation-expression-asi/
				// input.ts.
				if !inst_follow && !call_follow && cur_has_newline(p) {
					inst_follow = true
				}
			}
			follow_ok := call_follow || inst_follow
			if !follow_ok {
				lexer_restore(p, snap)
				// Clear any phantom errors emitted by the speculative parse.
				if len(p.errors) > snap.errors_len {
					resize(&p.errors, snap.errors_len)
				}
				if is_chain {
					chain := new_node(p, ChainExpression)
					chain.loc = chain_start
					chain.expression = expr
					chain.loc.end = prev_end_offset(p)
					return expression_from(p, chain)
				}
				return expr
			}
			// `new Foo<T>(args)` callee parse: allow_call=false, the type
			// arguments belong to the outer NewExpression, not to us. Roll
			// back so parse_new_expression's own `parse_ts_type_arguments`
			// call picks them up. Same goes for the `(` follower (call_follow)
			// or any binary-style follower (inst_follow): in callee-of-new
			// position, `<T>` is unambiguously the new-expression's type
			// arguments.
			if !allow_call {
				lexer_restore(p, snap)
				if len(p.errors) > snap.errors_len {
					resize(&p.errors, snap.errors_len)
				}
				if is_chain {
					chain := new_node(p, ChainExpression)
					chain.loc = chain_start
					chain.expression = expr
					chain.loc.end = prev_end_offset(p)
					return expression_from(p, chain)
				}
				return expr
			}
			// Commit: if followed by `(` AND calls are allowed, it's a
			// CallExpression with type_parameters.
			if is_token(p, .LParen) && allow_call {
				saved_paren2 := p.pending_paren_start
				p.pending_paren_start = max(u32)
				args := parse_arguments(p)
				call := new_node(p, CallExpression)
				call.loc = loc_from_expr(expr)
				call.callee = expr
				call.arguments = args
				call.type_parameters = targs
				call.optional = false
				if saved_paren2 != max(u32) && saved_paren2 <= call.loc.start {
					call.loc.start = saved_paren2
				}
				call.loc.end = prev_end_offset(p)
				expr = expression_from(p, call)
				continue
			}
			// Stand-alone TSInstantiationExpression: `f<T>` with no
			// trailing `(args)`. The follower test above already verified
			// the next token can legitimately end / continue an expression,
			// so commit. Per OXC / Babel, when the inner is an optional
			// chain (`a?.b<c>`), the ChainExpression wraps the chain and
			// then TSInstantiationExpression wraps the ChainExpression.
			inner := expr
			inst_start := loc_from_expr(expr)
			if is_chain {
				chain := new_node(p, ChainExpression)
				chain.loc = chain_start
				chain.expression = expr
				chain.loc.end = prev_end_offset(p)
				inner = expression_from(p, chain)
				inst_start = chain.loc
				is_chain = false  // we just sealed the chain
			}
			inst, inst_e := new_expr(p, TSInstantiationExpression)
			inst.loc = inst_start
			inst.expression = inner
			inst.type_arguments = targs
			inst.loc.end = prev_end_offset(p)
			expr = inst_e
			continue
		case:
			if is_chain {
				// Wrap the entire optional chain in ChainExpression
				chain := new_node(p, ChainExpression)
				chain.loc = chain_start
				chain.expression = expr
				chain.loc.end = prev_end_offset(p)
				return expression_from(p, chain)
			}
			return expr
		}
	}
	if is_chain {
		// Wrap the entire optional chain in ChainExpression
		chain := new_node(p, ChainExpression)
		chain.loc = chain_start
		chain.expression = expr
		chain.loc.end = prev_end_offset(p)
		return expression_from(p, chain)
	}
	return expr
}

// parse_member_expr is parse_left_hand_side_expr with call-expressions
// disallowed. Used for the callee position of `new EXPR(args)`, where
// the first `(args)` must be attributed to the NewExpression, not to
// the callee as a CallExpression.
parse_member_expr :: proc(p: ^Parser) -> ^Expression {
	expr := parse_primary_expr(p)
	if expr == nil {
		return nil
	}
	return parse_lhs_tail(p, expr, false)
}

parse_left_hand_side_expr :: proc(p: ^Parser) -> ^Expression {
	expr := parse_primary_expr(p)
	if expr == nil {
		return nil
	}
	return parse_lhs_tail(p, expr, true)
}

parse_primary_literal_expr :: #force_inline proc(p: ^Parser, current: ^TokenSnap) -> ^Expression {
	#partial switch current.type {
	case .Null:
		eat(p)
		nl, nl_e := new_expr(p, NullLiteral)
		nl.loc = loc_from_token(current)
		nl.loc.end = prev_end_offset(p)
		return nl_e

	case .True, .False:
		eat(p)
		bl := new_node(p, BooleanLiteral)
		bl.loc = loc_from_token(current)
		bl.value = current.type == .True
		bl.loc.end = prev_end_offset(p)
		return expression_from(p, bl)

	case .Number:
		eat(p)
		num, num_e := new_expr(p, NumericLiteral)
		num.loc = loc_from_token(current)
		num.raw = current.value
		if val, ok := current.literal.(f64); ok {
			num.value = val
		}
		num.loc.end = prev_end_offset(p)
		// ECMA-262 Annex B.1.1 + §12.9.3.5 — LegacyOctalIntegerLiteral
		// (`0777`) and NonOctalDecimalIntegerLiteral (`078`) are
		// SyntaxErrors in strict mode.
		if p.ctx.strict_mode && is_legacy_zero_prefixed_integer(num.raw) {
			report_error_coded_span(p, .K3051_StrictModeProhibited, u32(num.loc.start), u32(num.loc.start), "Legacy octal literals are not allowed in strict mode")
		}
		return num_e

	case .String:
		eat(p)
		str, str_e := new_expr(p, StringLiteral)
		str.loc = loc_from_token(current)
		str.raw = current.value
		if val, ok := current.literal.(string); ok {
			str.value = val
		}
		str.loc.end = prev_end_offset(p)
		if p.ctx.strict_mode && string_raw_has_forbidden_escape(str.raw) {
			report_error_coded_span(p, .K3051_StrictModeProhibited, u32(str.loc.start), u32(str.loc.start), "Octal or \\8 / \\9 escape sequences are not allowed in strict mode")
		}
		return str_e

	case .BigInt:
		eat(p)
		big, big_e := new_expr(p, BigIntLiteral)
		big.loc = loc_from_token(current)
		big.raw = current.value
		big.value = current.value
		big.loc.end = prev_end_offset(p)
		return big_e

	case:
		return nil
	}
}

// async_paren_is_arrow_head decides whether `async (...)` begins an async
// arrow function rather than a call to an identifier named `async`. Pure
// source-byte lookahead: walk from the `(` after `async` to its matching
// `)` (tracking paren/bracket/brace depth, skipping string and comment
// content), then skip trailing trivia and look for `=>` -- or, in TS/TSX, a
// `: ReturnType =>` annotation. No lexer or parser state is mutated. Closes
// Test262 annexB/.../cover-callexpression-and-asyncarrowhead.js. Lifted
// verbatim from the `.Async` case of parse_primary_expr to honour the
// 70-line limit; the surrounding disambiguation control flow is unchanged.
async_paren_is_arrow_head :: proc(p: ^Parser, current: TokenSnap, next: Token) -> bool {
	if p.lexer == nil {
		return false
	}
	is_arrow_head := false
	src := p.lexer.source_bytes
	lparen_off := int(next.raw_end) - 1
	// `next.raw_end` is just past `(`, so `lparen_off` is
	// the `(` byte. Walk forward tracking nesting depth
	// over parens/brackets/braces; stop at the matching `)`.
	// Skip string / template content so embedded brackets
	// don't break the depth count.
	depth := 0
	i := lparen_off
	src_len := len(src)
	end_off := -1
	scan: for i < src_len {
		ch := src[i]
		switch ch {
		case '(', '[', '{':
			depth += 1
		case ')', ']', '}':
			depth -= 1
			if depth == 0 && ch == ')' {
				end_off = i
				break scan
			}
		case '"', '\'':
			quote := ch
			i += 1
			for i < src_len && src[i] != quote {
				if src[i] == '\\' && i + 1 < src_len { i += 1 }
				i += 1
			}
		case '/':
			// Bare `/` could be division or comment;
			// skip a single-line `//` so we don't read
			// `=>` from inside a comment.
			if i + 1 < src_len && src[i+1] == '/' {
				for i < src_len && src[i] != '\n' { i += 1 }
			} else if i + 1 < src_len && src[i+1] == '*' {
				i += 2
				for i + 1 < src_len && !(src[i] == '*' && src[i+1] == '/') { i += 1 }
				if i + 1 < src_len { i += 1 }
			}
		}
		i += 1
	}
	if end_off >= 0 {
		j := end_off + 1
		// Skip whitespace AND comments (Test262 has
		// `... ) /* f */ => /* g */ { ... }`).
		for j < src_len {
			ch := src[j]
			if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { j += 1; continue }
			if ch == '/' && j + 1 < src_len && src[j+1] == '/' {
				for j < src_len && src[j] != '\n' { j += 1 }
				continue
			}
			if ch == '/' && j + 1 < src_len && src[j+1] == '*' {
				j += 2
				for j + 1 < src_len && !(src[j] == '*' && src[j+1] == '/') { j += 1 }
				if j + 1 < src_len { j += 2 }
				continue
			}
			break
		}
		// TS / TSX async arrow with return type annotation:
		// `async (): T => body`. After the matching `)` the
		// next non-trivia byte is `:`; the type annotation
		// extends until the `=>` (skipping balanced
		// `<>` / `()` / `[]` / `{}` and string content).
		// Previously the lookahead bailed at the `:` and treated
		// `async (...)` as a plain CallExpression of `async`.
		// "Expected semicolon" cluster.
		// TS return-type lookahead. When inside a ternary
		// consequent AND there's no extra wrapping paren
		// before `async`, the `:` after `async(b)` is the
		// ternary's alt separator, NOT a return type.
		// `(async(b): T => ...)` inside parens is fine.
		skip_return_type := false
		if p.conditional_depth > 0 {
			// Check if `async` is shielded by outer parens.
			async_pos := int(current.start)
			shielded := false
			for k := async_pos - 1; k >= 0; k -= 1 {
				ch := src[k]
				if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { continue }
				if ch == '(' { shielded = true }
				break
			}
			skip_return_type = !shielded
		}
		if (p.lang == .TS || p.lang == .TSX) && !skip_return_type && j < src_len && src[j] == ':' {
			j += 1
			t_depth := 0
			ts_scan: for j < src_len {
				tch := src[j]
				switch tch {
				case '<', '(', '[', '{':
					t_depth += 1
				case '>', ')', ']', '}':
					if t_depth == 0 {
						// Hit a closer outside any nested
						// group - type ended without `=>`,
						// not an arrow head.
						break ts_scan
					}
					t_depth -= 1
				case '=':
					if t_depth == 0 && j + 1 < src_len && src[j+1] == '>' {
						is_arrow_head = true
						break ts_scan
					}
				case ',', ';':
					if t_depth == 0 { break ts_scan }
				case '"', '\'':
					quote := tch
					j += 1
					for j < src_len && src[j] != quote {
						if src[j] == '\\' && j + 1 < src_len { j += 1 }
						j += 1
					}
				case '/':
					if j + 1 < src_len && src[j+1] == '/' {
						for j < src_len && src[j] != '\n' { j += 1 }
					} else if j + 1 < src_len && src[j+1] == '*' {
						j += 2
						for j + 1 < src_len && !(src[j] == '*' && src[j+1] == '/') { j += 1 }
						if j + 1 < src_len { j += 1 }
					}
				}
				j += 1
			}
		} else if j + 1 < src_len && src[j] == '=' && src[j+1] == '>' {
			is_arrow_head = true
		}
	}
	return is_arrow_head
}

// parse_primary_import handles the `import` primary forms: dynamic
// `import(spec)`, `import.meta`, and the stage-3 phase imports
// `import.defer(spec)` / `import.source(spec)`. Static import is a
// SyntaxError in expression position. Split out of parse_primary_expr.
parse_primary_import :: proc(p: ^Parser) -> ^Expression {
	current := snap_current(p)
	// Check for dynamic import: import(specifier)
	if is_next_token(p, .LParen) {
		return parse_dynamic_import(p, "")
	}
	// Check for import.<property> forms:
	//   import.meta             - MetaProperty (§13.3.12)
	//   import.defer(specifier) - Phase Imports (stage-3, import-defer)
	//   import.source(specifier)- Phase Imports (stage-3, import-source)
	if is_next_token(p, .Dot) {
		eat(p) // consume import
		if !expect_token(p, .Dot) {
			return nil
		}
		meta_name := parse_identifier(p)

		// Phase-import call form: import.defer(...) / import.source(...).
		// Only matches when the property is a known phase AND the next
		// token is `(` - otherwise falls through to MetaProperty so an
		// error surfaces for the bare form.
		if is_token(p, .LParen) &&
		   (meta_name.name == "defer" || meta_name.name == "source") {
			// Hand off to parse_dynamic_import_tail so the import()
			// grammar (AssignmentExpression ,opt [, AssignmentExpression
			// ,opt ]) is shared. Start-loc is the `import` keyword
			// (current, before eat); the helper uses prev_end_offset for
			// the closing paren.
			return parse_dynamic_import_tail(p, loc_from_token(&current), meta_name.name)
		}

		// §Grammar Notation: the `meta` in `import.meta` must not
		// contain Unicode escape sequences.
		if meta_name.name == "meta" {
			// Check the raw source for escape sequences: parse_identifier
			// uses the cooked name but raw source may have \uXXXX.
			span_bytes := p.lexer.source_bytes[meta_name.loc.start:meta_name.loc.end]
			for b in span_bytes {
				if b == '\\' {
					report_error_coded(p, .K3023_ImportMetaOrDynamicImportInvalid, "'import.meta' property name must not contain Unicode escape sequences")
					break
				}
			}
		}
		// §13.3.12 - The only valid meta property for `import` is
		// `import.meta`.  `import.then`, `import.foo`, etc. are
		// SyntaxErrors.
		if meta_name.name != "meta" {
			msg := fmt.tprintf("The only valid meta property for import is import.meta (got 'import.%s')", meta_name.name)
			report_error_coded(p, .K3023_ImportMetaOrDynamicImportInvalid, msg)
		}
		meta_prop, meta_prop_e := new_expr(p, MetaProperty)
		meta_prop.loc = loc_from_token(&current)
		meta_prop.meta = Identifier{
			loc  = loc_from_token(&current),
			name = "import",
		}
		meta_prop.property = Identifier{
			loc  = meta_name.loc,
			name = meta_name.name,
		}
		meta_prop.loc.end = prev_end_offset(p)
		p.has_module_syntax = true
		// `import.meta` is Module syntax. In script sourceType it's a
		// SyntaxError per ECMA-262 §13.3.12.
		if st, have := p.force_source_type.(SourceType); have && st == .Script {
			report_error_coded(p, .K3022_ModuleSyntaxInScript, "'import.meta' is only valid in module code")
		}
		// Collect ESM import.meta record
		esm_import_meta := ESMImportMeta{
			start = meta_prop.loc.start,
			end = meta_prop.loc.end,
		}
		bump_append(&p.importMetas, esm_import_meta)
		return meta_prop_e
	}
	// Static import - not valid in expression context
	report_error_coded(p, .K2040_UnexpectedToken, "Unexpected import in expression context")
	return nil
}

// parse_primary_async handles a leading `async`: async function
// expression, async arrow (`async x =>`, `async (...) =>`, TS generic
// `async <T>(...) =>`), or `async` as a bare IdentifierReference.
// Split out of parse_primary_expr; still larger than the 70-line
// target and a candidate for further internal decomposition.
parse_primary_async :: proc(p: ^Parser) -> ^Expression {
	current := snap_current(p)
	// async function expression or arrow function
	// Lookahead to check what follows async
	next := peek_token(p)
	// ECMA-262 §15.8 / §15.9 Restricted Productions: no LineTerminator
	// between `async` and the following `function` / BindingIdentifier /
	// `(`. If there is one, the grammar rule fails and ASI treats `async`
	// as a bare IdentifierReference; the lookahead token starts a new
	// statement/expression.
	// §Grammar Notation: terminal symbols must not contain Unicode escape
	// sequences. `\u0061sync` is NOT the `async` keyword. Detect by
	// checking the token's has_escape flag.
	if current.has_escape {
		// Escaped async: `\u0061sync function f(){}` is a SyntaxError
		// because the `async` keyword must appear literally. Report and
		// fall through to treat it as an identifier.
		report_error_coded(p, .K3015_KeywordContainsEscape, "'async' keyword must not contain Unicode escape sequences")
		eat(p)
		ident, ident_e := new_expr(p, Identifier)
		ident.loc = loc_from_token(&current)
		// `"async"` is a compile-time literal whose `raw_data` lives in the
		// binary's RODATA segment - outside both the source-bytes range and
		// the parser arena range. raw_transfer's rewrite_string then writes
		// a garbage offset for the field, and the binary buffer surfaces
		// the Identifier with `name=""`. JSON path is correct (it just
		// prints the live Odin string), so the bug stayed silent until W5
		// extended verify_integration to walk Identifier names through every
		// reachable expression slot. Source slice is in-source, so
		// rewrite_string's source-base branch fires and produces a
		// well-formed offset.
		ident.name = current.value
		ident.loc.end = prev_end_offset(p)
		return ident_e
	}
	async_lt_break := next.had_line_terminator
	async_arrow_ctx_kw := false  // async <contextual-kw> => x
	if !async_lt_break && next.type == .Function {
		// async function() {} - function expression
		return parse_function_expression(p)
	} else if !async_lt_break && next.type != .Identifier && next.type != .LParen &&
	          is_identifier_like_token(next.type) {
		// `async <contextual-kw>`: ambiguous between async-arrow
		//   `async of => x`   (async arrow with `of` as binding)
		// and bare-async + for-of head
		//   `for await (async of x)`   (`async` is the LHS Identifier)
		// Disambiguate via SOURCE-BYTE lookahead: scan past the next
		// token to see whether the following non-whitespace bytes are
		// `=>`. If yes, commit to the arrow path; otherwise let the
		// `.Async`-as-Identifier fall-through below run, which keeps
		// the for-await-of test (head-lhs-async.js) parsing.
		if p.lexer != nil {
			src := p.lexer.source_bytes
			i := int(next.raw_end)
			src_len := len(src)
			for i < src_len {
				ch := src[i]
				if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { i += 1; continue }
				break
			}
			if i + 1 < src_len && src[i] == '=' && src[i+1] == '>' {
				async_arrow_ctx_kw = true
			}
		}
	}
	if !async_lt_break && (next.type == .Identifier || next.type == .LParen || async_arrow_ctx_kw ||
	   (allow_ts_mode(p) && next.type == .LAngle)) {
		// This might be an async arrow function: async x => x or async () => {}
		if next.type == .Identifier || async_arrow_ctx_kw {
			// async x => ...
			// Snapshot before consuming both tokens. If `=>` doesn't
			// follow the param identifier, roll back so only `async`
			// is consumed as a bare IdentifierReference. Without this,
			// `async functionX ()` loses `functionX` entirely.
			snap_async := lexer_snapshot(p)
			snap_errs := len(p.errors)
			eat(p) // consume async
			param_ident := parse_identifier(p)
			if is_token(p, .Arrow) {
				return parse_async_arrow_function(p, param_ident)
			}
			// Not an arrow — roll back to just after `async`, let the
			// LHS-tail / expression parser handle the next tokens.
			lexer_restore(p, snap_async)
			if len(p.errors) > snap_errs {
				resize(&p.errors, snap_errs)
			}
			eat(p) // re-consume only `async`
			ident, ident_e := new_expr(p, Identifier)
			ident.loc = loc_from_token(&current)
			ident.name = current.value
			ident.loc.end = prev_end_offset(p)
			return ident_e
		} else if next.type == .LParen {
			// `async (...)` is ambiguous: an async arrow head, OR a
			// regular call to `async`. Source-byte lookahead at the
			// matching `)` decides: if `=>` follows, it's an arrow;
			// otherwise treat `async` as a plain IdentifierReference
			// and let the LHS-tail parser build the CallExpression.
			// Test262: annexB/language/expressions/assignmenttargettype/
			// cover-callexpression-and-asyncarrowhead.js.
			is_arrow_head := async_paren_is_arrow_head(p, current, next)
			if is_arrow_head {
				eat(p) // consume async
				return parse_async_arrow_with_parens(p, current)
			}
			// Fall through: `async` will be re-parsed as a bare
			// IdentifierReference below; the LHS-tail loop then
			// consumes `(...)` as a CallExpression.
		} else if allow_ts_mode(p) && next.type == .LAngle {
			// TS async generic arrow: `async <T>(a: T): T => a`.
			// Trial-parse: consume `async`, parse `<T>` as type params,
			// then delegate to the paren-params path. On failure, roll
			// back and treat `async` as a plain identifier.
			snap := lexer_snapshot(p)
			eat(p) // consume async
			type_params := parse_ts_type_parameters(p)
			if is_token(p, .LParen) {
				arrow := parse_async_arrow_with_parens(p, current)
				if arrow != nil {
					// Attach the type parameters.
					if ae, ok := arrow^.(^ArrowFunctionExpression); ok && ae != nil {
						ae.type_parameters = type_params
					}
					if len(p.errors) == snap.errors_len {
						return arrow
					}
				}
			}
			lexer_restore(p, snap)
		}
	}
	// async as identifier
	eat(p)
	ident, ident_e := new_expr(p, Identifier)
	ident.loc = loc_from_token(&current)
	ident.name = current.value
	ident.loc.end = prev_end_offset(p)
	return ident_e
}

// parse_primary_lparen handles the `(` primary: empty-param arrow
// `() =>`, parenthesised expression, and the cover grammar that
// disambiguates arrow heads from grouping. Split out of
// parse_primary_expr; still larger than the 70-line target.
parse_primary_lparen :: proc(p: ^Parser) -> ^Expression {
	current := snap_current(p)
	// Check for arrow function with empty params: () => ...
	if is_next_token(p, .RParen) {
		// Potential empty arrow function params. In TS / TSX `(): T =>`
		// shape we need to drop into try_parse_ts_arrow_params so the
		// return-type annotation is consumed; defer the eat-pair to the
		// trial parser in that case.
		if allow_ts_mode(p) {
			// Peek past `()` to detect `: T =>`. Cheap byte-scan via
			// looks_like_ts_arrow_params (already does this for the
			// non-empty cases; the empty case lands here too because
			// the byte-scan doesn't depend on the token kind).
			if looks_like_ts_arrow_params(p) {
				if arrow := try_parse_ts_arrow_params(p, current); arrow != nil {
					return arrow
				}
			}
		}
		eat(p) // consume (
		eat(p) // consume )
		if is_token(p, .Arrow) {
			// This is () => ... - return a marker for empty params
			seq, seq_e := new_expr(p, SequenceExpression)
			seq.loc = loc_from_token(&current)
			seq.expressions = make([dynamic]^Expression, 0, 4, p.allocator)
			return seq_e
		}
		// Not an arrow, return nil (empty parens not valid expression)
		report_error_coded(p, .K2040_UnexpectedToken, "Empty parenthesized expression")
		return nil
	}

	// TS trial-parse (K4): `(x: T) => x`, `(...rest: T[]) => ...`, etc.
	// The `:Type` annotation on a parameter is not valid JS syntax inside
	// plain paren-grouping, so parse_expr_with_prec would fail. When in
	// TS / TSX mode and the `(` clearly opens arrow parameters (rest
	// marker, or `Identifier :`), trial-parse as function parameters and
	// build the arrow directly. On failure we roll back cleanly and fall
	// through to the normal paren-grouping path.
	if allow_ts_mode(p) && looks_like_ts_arrow_params(p) {
		if arrow := try_parse_ts_arrow_params(p, current); arrow != nil {
			return arrow
		}
	}

	// Regular parenthesized expression. Use Comma precedence to handle
	// (x, y) => ... arrow function case.
	// Record the `(` position BEFORE eating it. parse_arrow_function reads
	// pending_paren_start when the next token turns out to be `=>` so the
	// arrow span starts AT the paren, matching OXC/Acorn/Babel. A nested
	// `(` would overwrite the outer's stamp - harmless because the inner
	// is consumed and cleared before the outer reaches `=>`.
	paren_start := cur_loc(p).start
	eat(p)
	// Save and clear pending_paren_start so nested expressions don't use this paren.
	// We'll restore it below only if the next token is Arrow (for arrow function params).
	prev_pending_paren := p.pending_paren_start
	p.pending_paren_start = max(u32)
	prev_no_in := p.ctx.no_in
	p.ctx.no_in = false  // 'in' is always valid inside parentheses
	// Parens reset the in-RHS context so `(#x in y)` parses cleanly
	// even when the surrounding expression is the RHS of another `in`.
	prev_in_in_rhs := p.ctx.in_in_rhs
	p.ctx.in_in_rhs = false
	expr := parse_expr_with_prec(p, .Comma)
	p.ctx.in_in_rhs = prev_in_in_rhs
	p.ctx.no_in = prev_no_in
	if expr == nil {
		return nil
	}
	paren_expr_had_trailing_comma := false
	if p.lexer != nil && is_token(p, .RParen) {
		src := p.lexer.source_bytes
		k := int(cur_offset(p)) - 1
		for k >= 0 {
			c := src[k]
			if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
				k -= 1
				continue
			}
			paren_expr_had_trailing_comma = c == ','
			break
		}
	}
	if !expect_token(p, .RParen) {
		return nil
	}
	if paren_expr_had_trailing_comma && !is_token(p, .Arrow) {
		report_error_coded(p, .K3065_TrailingCommaInvalid, "Parenthesized expressions may not have a trailing comma")
	}
	if _, is_spread_expr := expr.(^SpreadElement); is_spread_expr && !is_token(p, .Arrow) {
		report_error_coded(p, .K3042_RestSpreadMisuse, "Expected `=>` after parenthesized rest parameter")
	}
	// Note: OXC/Acorn do NOT adjust the inner expression span to
	// include the parentheses in most cases. The parentheses are
	// syntactic, not semantic - the inner expression keeps its own
	// natural span. pending_paren_start handles the special cases
	// (arrow functions, call expressions).
	// Set pending_paren_start for this paren. Used by arrow function
	// parameters, CallExpressions, and MemberExpressions whose object
	// was parenthesized. OXC includes `(` in the span of calls,
	// member access, and arrow functions that follow `(expr)`.
	if is_token(p, .Arrow) || is_token(p, .LParen) || is_token(p, .Dot) ||
	   is_token(p, .LBracket) || is_token(p, .OptionalChain) {
		p.pending_paren_start = paren_start
	} else {
		p.pending_paren_start = prev_pending_paren
	}

	// EST-3 / OPT-3 `--preserve-parens`: wrap the inner expression in
	// a ParenthesizedExpression node matching Acorn/OXC's shape. Skip
	// when `=>` follows - that path is cover-for-arrow-params and the
	// downstream arrow builder expects the raw inner expression to
	// lower to FunctionParameter via expr_to_pattern.
	if p.preserve_parens && !is_token(p, .Arrow) {
		paren_node, paren_node_e := new_expr(p, ParenthesizedExpression)
		paren_node.loc.start = paren_start
		paren_node.loc.end = prev_end_offset(p)
		paren_node.expression = expr
		wrapped := paren_node_e
		p.last_paren_expr = wrapped
		return wrapped
	}
	// Stamp the bare inner expression as paren-wrapped so a subsequent
	// `=` triggers the AssignmentTargetType check in parse_assignment_expr.
	// Skip the stamp when `=>` follows: that path is the arrow-param
	// cover production, where the parens belong to the arrow's parameter
	// list, not to a value-grouping parenthesisation.
	if !is_token(p, .Arrow) {
		p.last_paren_expr = expr
		// SpreadElement/RestElement inside `(...)` without `=>`
		// is invalid — rest/spread in parens is only the
		// cover grammar for arrow function parameters.
		if expr_contains_spread(expr) {
			report_error_coded(p, .K3042_RestSpreadMisuse, "Unexpected spread/rest element outside of arrow parameters")
		}
	}
	return expr
}

// parse_primary_langle handles a leading `<`: TSX generic-arrow vs
// JSX element disambiguation, TS type assertions, and the JS error
// case. Split out of parse_primary_expr.
parse_primary_langle :: proc(p: ^Parser) -> ^Expression {
	current := snap_current(p)
	// Dispatch depends on language mode:
	//   TS  → TS type assertion `<Type>expr` or generic arrow
	//          `<T>(x) => x`. No JSX ambiguity in pure TS mode.
	//   TSX → Genuine ambiguity. OXC/TS-ESTree rule:
	//          * `<T,>` (trailing comma) → generic arrow.
	//          * `<T extends ...>` → try generic arrow.
	//          * `<Type>expr` type-assertions are FORBIDDEN in .tsx
	//            (use `expr as Type` instead). Fall through to JSX.
	//          * Anything else → JSX element / fragment.
	//   JSX → JSX element / fragment (no TS types).
	//   JS  → syntax error (comparison needs a LHS operand).
	if p.lang == .TSX {
		// TSX Phase C: try generic arrow when trailing comma
		// or `extends` follows the type parameter identifier.
		// A 2-token speculative peek (no consume): peek past `<`
		// to the first token; if it's an Identifier, peek again
		// to see what follows.
   ensure_nxt(p)
		nxt_kind := p.lexer.nxt.kind
		// Type-parameter modifiers (`const`, `in`) lex as keyword tokens,
		// not Identifier. `<const T ...>` and `<in T ...>` are
		// unambiguously type-parameter lists (no JSX element name is a
		// reserved word). `out` is contextual — still lexes as Identifier
		// and falls through to the existing path. Closes oxc-3443.tsx.
		if nxt_kind == .Const || nxt_kind == .In {
			lt_start := cur_loc(p)
			snap2 := lexer_snapshot(p)
			result := parse_ts_generic_arrow(p, lt_start)
			if result != nil && len(p.errors) == snap2.errors_len {
				return result
			}
			lexer_restore(p, snap2)
		}
		if nxt_kind == .Identifier {
			snap := lexer_snapshot(p)
			eat(p)  // consume `<`
			eat(p)  // consume the identifier
			after := p.cur_type
			lexer_restore(p, snap)
			// Trailing comma `<T,>` or `extends` / `=` signal → try
			// as generic arrow. On failure fall through to JSX.
			if after == .Comma || after == .Extends || after == .Assign {
				lt_start := cur_loc(p)
				snap2 := lexer_snapshot(p)
				result := parse_ts_generic_arrow(p, lt_start)
				if result != nil && len(p.errors) == snap2.errors_len {
					return result
				}
				lexer_restore(p, snap2)
			}
		}
		// Fall through to JSX (covers tags, fragments, and the
		// forbidden-in-TSX `<Type>expr` form which JSX will
		// reject as a malformed element).
		return parse_jsx_element_or_fragment(p)
	}
	if allow_jsx_mode(p) {  // .JSX only (not .TSX - handled above)
		return parse_jsx_element_or_fragment(p)
	}
	if allow_ts_mode(p) {
		// .mts/.cts early check: for the simple `<Identifier>`
		// case (no trailing comma, extends, or assign), report the
		// error HERE before parsing so it's always the first error
		// on the line (body errors come later). Only for .mts/.cts
		// path detection; explicit disallowAmbiguousJSXLike uses the
		// post-parse check inside parse_ts_lt_expression.
   ensure_nxt(p)
		if p.is_node_ts_module && p.lexer != nil && p.lexer.nxt.kind == .Identifier {
			snap := lexer_snapshot(p)
			eat(p)  // consume `<`
			eat(p)  // consume the identifier
			after := p.cur_type
			lexer_restore(p, snap)
			if after == .RAngle {
				report_error_coded_span(p, .K4053_TSOnlyInJS, u32(cur_offset(p)), u32(cur_offset(p)), "This syntax is reserved in files with the .mts or .cts extension. Add a trailing comma, as in `<T,>() => ...`")
			}
		}
		return parse_ts_lt_expression(p)
	}
	report_error_coded(p, .K2040_UnexpectedToken, "Unexpected '<' at expression start")
	return nil
}

// parse_primary_private_identifier handles a bare `#name` primary, valid
// only as the LHS of an `in` (ergonomic brand check); every other use is a
// SyntaxError. Queues the reference for end-of-class-body resolution.
parse_primary_private_identifier :: proc(p: ^Parser) -> ^Expression {
	current := snap_current(p)
	// ECMA-262 §13.2 - `#foo` may appear as a PrimaryExpression ONLY
	// when it is the LHS of an `in` operator (ES2022 ergonomic brand
	// check: `#foo in obj`). Every other primary-position use is a
	// SyntaxError, including class-field usages outside a class body
	// and use as an assignment target. `obj.#foo` / `this.#foo` are
	// member accesses - those don't come through here because
	// `parse_lhs_tail` consumes the `#foo` after `.` directly.
	// `#x in #y` (Test262 expressions/in/private-field-in-nested.js)
	// must reject the second `#y`: even though nxt.kind == .In here
	// (the OUTER `in` of `#x in #y in z`), this slot is the RHS of
	// the inner `in`, not its LHS. `in_in_rhs` distinguishes them.
	if p.lexer != nil { ensure_nxt(p) }
	invalid_position := p.ctx.in_in_rhs || p.ctx.no_in || !p.ctx.private_in_allowed ||
	                    (p.lexer != nil && p.lexer.nxt.kind != .In)
	if invalid_position {
		report_error_coded(p, .K2040_UnexpectedToken, "Private identifier can only appear as the LHS of an 'in' expression or as a class member")
	}
	// §15.7.3 — a PrivateIdentifier reference outside any class body
	// cannot resolve. Inside a class body, queue the reference for
	// validation at end-of-class-body (when the declared-name set is
	// known).
	// Private field reference: #x (used in expressions like #x in this)
	name := current.value
	if len(name) > 0 && name[0] == '#' {
		name = name[1:]
	}
	private_ref_loc := loc_from_token(&current)
	if p.class_depth == 0 {
		report_error_coded(p, .K3032_PrivateNameInvalid, "Private name reference is not allowed outside of a class")
	} else if name != "" {
		append(&p.pending_priv_refs, PendingPrivRef{name = name, loc = private_ref_loc, depth = p.class_depth})
	}
	pid, pid_e := new_expr(p, PrivateIdentifier)
	pid.loc = loc_from_token(&current)
	pid.name = name
	p.private_id_count += 1
	eat(p)
	pid.loc.end = prev_end_offset(p)
	return pid_e
}

// parse_primary_super handles a `super` primary: `super.prop` / `super[...]`
// member access and `super(...)` calls. Context legality is checked later.
parse_primary_super :: proc(p: ^Parser) -> ^Expression {
	current := snap_current(p)
	// §13.3.7 SuperProperty / §15.7.6 SuperCall shape check.
  ensure_nxt(p)
	if p.lexer.nxt.kind != .Dot && p.lexer.nxt.kind != .LBracket &&
	   p.lexer.nxt.kind != .LParen {
		report_error_coded(p, .K3033_SuperInvalidContext, "'super' can only be used with function calls or in property accesses")
	}
	// §13.3.7 SuperProperty requires [[HomeObject]] (→ in_method).
	// `super.x` / `super[x]` outside a method body is a SyntaxError.
  ensure_nxt(p)
	if (p.lexer.nxt.kind == .Dot || p.lexer.nxt.kind == .LBracket) && !p.ctx.in_method {
		report_error_coded(p, .K3033_SuperInvalidContext, "'super' property access is only valid inside a method")
	}
	eat(p)
	super, super_e := new_expr(p, Super)
	super.loc = loc_from_token(&current)
	super.loc.end = prev_end_offset(p)
	return super_e
}

// parse_primary_identifier handles an IdentifierReference primary: any
// contextual keyword usable as an identifier, plus the escaped-reserved /
// strict-reserved / `enum` / class-field `arguments` early errors. Hot path
// (every identifier expression), so the dispatch site calls it #force_inline.
parse_primary_identifier :: proc(p: ^Parser) -> ^Expression {
	current := snap_current(p)
	// All contextual keywords are valid identifiers in expression context.
	// TS keywords (type, interface, enum) lex as Identifier and are
	// handled via string-value check in parse_statement_or_declaration.
	// ECMA-262 §12.7.2: if the identifier arrived via \uXXXX escape and
	// its cooked StringValue matches a ReservedWord, IdentifierReference
	// is a Syntax Error (check runs before eat so loc is correct).
	report_escaped_reserved_word(p)
	// §12.1.1 - `enum` is a FutureReservedWord that is ALWAYS
	// reserved (all modes, strict and sloppy). The lexer emits
	// `enum` as .Identifier (contextual for TS enum decls), so
	// we must check by value here in expression position.
	if current.value == "enum" {
		report_error_coded(p, .K4054_EnumInvalid, "'enum' is a reserved word")
	}
	// §12.6.1.1 - strict-mode IdentifierReference cannot be "let" /
	// "yield" / "implements" / "interface" / "package" /
	// "private" / "protected" / "public" / "static". The lexer emits
	// .Let / .Static / .Yield as dedicated tokens and the rest as
	// .Identifier, so check both channels. `yield` inside a generator
	// and `await` inside async are handled by the dedicated keyword
	// paths earlier in parse_unary_expr - we only reach here for
	// sloppy-mode fall-through.
	if p.ctx.strict_mode {
		if is_strict_reserved_word(current.type) || is_strict_reserved_name(current.value) {
			msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", current.value)
			report_error_coded(p, .K3050_StrictModeReserved, msg)
		}
	}

	// §16.2 / §15.7.5 — `await` as IdentifierReference in async /
	// async-params / class-static-block context is enforced by the
	// semantic checker (ck_check_identifier_await_reserved). The
	// has_escape flag is propagated below to the Identifier so the
	// checker can match the parser's narrow gating.
	// Escaped `async` before `function` is SyntaxError. The lexer
	// emits `.Identifier` (not `.Async`) for `\u0061sync`, so the
	// `.Async` case's escape check doesn't fire.
	if current.has_escape && current.value == "async" {
		nxt := peek_token(p)
		if nxt.type == .Function && !nxt.had_line_terminator {
			report_error_coded(p, .K3015_KeywordContainsEscape, "'async' keyword must not contain Unicode escape sequences")
		}
	}
	eat(p)
	id, id_expr := new_expr(p, Identifier)
	id.loc = loc_from_token(&current)
	id.name = current.value
	id.has_escape = current.has_escape
	id.loc.end = prev_end_offset(p)
	// §15.7.10 / §15.7.5 — `arguments` as IdentifierReference is
	// forbidden in class field initializers and class static blocks
	// (the synthetic function does NOT bind `arguments`). Gate on the
	// rare-context flags FIRST so the string compare doesn't run on
	// every identifier in the hot path.
	if (p.ctx.in_static_block || p.ctx.in_field_init) && current.value == "arguments" {
		if p.ctx.in_static_block {
			report_error_coded(p, .K3031_StaticBlockOrFieldInitRestriction, "'arguments' is not allowed in a class static block")
		} else {
			report_error_coded(p, .K3031_StaticBlockOrFieldInitRestriction, "'arguments' cannot appear in a class field initializer")
		}
	}
	return id_expr
}

// parse_primary_at handles a leading `@` decorator that prefixes a class
// expression (`@dec class {}`), parsing the decorator list then the class.
parse_primary_at :: proc(p: ^Parser) -> ^Expression {
	current := snap_current(p)
	// Decorator on a class expression: `@dec class {}`. Same
	// `parse_decorators` walker as the statement-position decorated
	// class. Decorator-on-expression is the stage-3 form (only
	// applies to ClassExpression - nothing else accepts decorators).
	decorators := parse_decorators(p)
	if !is_token(p, .Class) {
		report_error_coded(p, .K2090_MalformedDecorator, "Decorators can only be applied to class expressions")
		return nil
	}
	cls := parse_class_expression(p)
	if cls != nil {
		if ce, ok := cls.(^ClassExpression); ok && ce != nil {
			ce.decorators = decorators
			if len(decorators) > 0 {
				ce.loc.start = decorators[0].loc.start
			}
		}
	}
	return cls
}

// parse_primary_regex handles a RegularExpression literal primary, building
// the RegExpLiteral node and routing the pattern through the validator.
parse_primary_regex :: proc(p: ^Parser) -> ^Expression {
	current := snap_current(p)
	eat(p)
	regex, regex_e := new_expr(p, RegExpLiteral)
	regex.loc = loc_from_token(&current)
	// Parse pattern and flags from token value (format: /pattern/flags)
	raw := current.value
	if len(raw) >= 2 && raw[0] == '/' {
		// Find the last / that separates pattern from flags
		last_slash := -1
		for i := len(raw) - 1; i >= 0; i -= 1 {
			if raw[i] == '/' {
				last_slash = i
				break
			}
		}
		if last_slash > 0 {
			regex.pattern = intern(p.interner, raw[1:last_slash])
			if last_slash + 1 < len(raw) {
				regex.flags = intern(p.interner, raw[last_slash + 1:])
			}
		}
	}
	regex.loc.end = prev_end_offset(p)
	return regex_e
}

// parse_primary_this builds a ThisExpression. `this` is common in method
// bodies, so the dispatch site calls it #force_inline to keep the original
// inline codegen.
parse_primary_this :: proc(p: ^Parser) -> ^Expression {
	current := snap_current(p)
	eat(p)
	this, this_e := new_expr(p, ThisExpression)
	this.loc = loc_from_token(&current)
	this.loc.end = prev_end_offset(p)
	return this_e
}

parse_primary_expr :: proc(p: ^Parser) -> ^Expression {
	current := snap_current(p)

	// Statement-only keywords that should never start a primary
	// expression (`(debugger)`, `(else)`, `(extends)`, ...). Without
	// this gate the LParen handler silently swallows the `(` and the
	// remainder is parsed as a lone DebuggerStatement, dropping the
	// inner expression on the floor and emitting no diagnostic.
	if is_keyword_not_expression_start(current.type) {
		msg := fmt.tprintf("Unexpected reserved word '%s'", cur_value(p))
		report_error_coded(p, .K2040_UnexpectedToken, msg)
		eat(p)
		return nil
	}

	#partial switch current.type {
	case .Import:
		return parse_primary_import(p)
	case .This:
		return #force_inline parse_primary_this(p)
	case .PrivateIdentifier:
		return parse_primary_private_identifier(p)
	case .Super:
		return parse_primary_super(p)
	case .Null, .True, .False, .Number, .String, .BigInt:
		return parse_primary_literal_expr(p, &current)

	case .Async:
		return parse_primary_async(p)
	case .Identifier, .Get, .Set, .From, .Of, .As, .Let, .Static, .Constructor,
	     .Assert, .Asserts, .Abstract, .Declare, .Readonly, .Override,
	     .Keyof, .Infer, .Is, .Satisfies, .Never, .Unique, .Namespace, .Module,
	     .Implements, .Require, .Package, .Private, .Protected, .Public,
	     .Accessor, .Target, .Await, .Yield:
		return #force_inline parse_primary_identifier(p)
	case .LParen:
		return #force_inline parse_primary_lparen(p)
	case .LBracket:
		return parse_array_expr(p)

	case .LBrace:
		return parse_object_expr(p)

	case .Function:
		return parse_function_expression(p)

	case .Class:
		return parse_class_expression(p)

	case .At:
		return parse_primary_at(p)
	case .New:
		return parse_new_expr(p)

	case .Template, .TemplateHead:
		return parse_template_literal(p, false)

	case .RegularExpression:
		return parse_primary_regex(p)
	case .LAngle:
		return parse_primary_langle(p)
	case:
		// Unknown token type
		return nil
	}
}

parse_array_expr :: proc(p: ^Parser) -> ^Expression {
	start := cur_loc(p)

	if !expect_token(p, .LBracket) {
		return nil
	}

	arr := new_node(p, ArrayExpression)
	arr.loc = start
	// Lazy alloc - empty array literals (`[]`) are common as default
	// values, accumulator initializers (`reduce((acc=[], x) => ...)`),
	// and explicit no-op cases. Defer the bump reservation until we
	// know there's at least one element.
	if !is_token(p, .RBracket) && !is_token(p, .EOF) {
		// Cap bumped from 8 → 16 (S23). Array literals with >8 elements
		// triggered 520 slow-path grows on monaco. Common in const-data
		// arrays (lookup tables, error-code lists, opcode tables).
		arr.elements = make([dynamic]Maybe(^Expression), 0, 16, p.allocator)
	}

	// Inside an ArrayExpression literal, `in` is always valid as a
	// binary operator - the enclosing §no_in flag (used to peek for
	// for-in/of heads) must NOT leak into element sub-expressions.
	// `for ([ x = 'x' in {} ] of y)` needs the inner `'x' in {}` to
	// parse as a binary expression, not bail at `in`.
	prev_no_in := p.ctx.no_in
	p.ctx.no_in = false
	defer p.ctx.no_in = prev_no_in
	// Slice 14: scope_skip is now tracked by the checker; the parser
	// no longer suppresses anything during element-walk.

	for !is_token(p, .RBracket) && !is_token(p, .EOF) {
		if match_token(p, .Comma) {
			// Sparse element
			bump_append(&arr.elements, nil)
			continue
		}

		if is_token(p, .Dot3) {
			// Spread element
			spread_start := cur_loc(p) // Capture location of ... before eating
			eat(p)
			arg := parse_assignment_expression(p)
			if arg != nil {
				spread, spread_e := new_expr(p, SpreadElement)
				spread.loc = spread_start // Use location of ... token
				spread.argument = arg
				spread.loc.end = prev_end_offset(p)
				bump_append(&arr.elements, Maybe(^Expression)(spread_e))
			}
		} else {
			elem := parse_assignment_expression(p)
			if elem != nil {
				// Track parenthesized non-simple elements for destructuring validation.
				// If this element was parenthesized (last_paren_expr matches) and
				// its inner is non-simple (Assignment, Array, Object), record it.
				if elem == p.last_paren_expr && elem != nil {
					is_non_simple := false
					#partial switch _ in elem^ {
					case ^AssignmentExpression, ^ArrayExpression, ^ObjectExpression:
						is_non_simple = true
					}
					if is_non_simple {
						bump_append(&p.pending_paren_patterns, loc_from_expr(elem).start)
					}
				}
				bump_append(&arr.elements, Maybe(^Expression)(elem))
			}
		}

		if !match_token(p, .Comma) {
			break
		}
	}

	if !expect_token(p, .RBracket) {
		return nil
	}

	arr.loc.end = prev_end_offset(p)
	return expression_from(p, arr)
}

// A Property qualifies as a literal `__proto__: ...` data property when:
//   - the key is a plain Identifier `__proto__` or a StringLiteral
//     whose value is `"__proto__"`,
//   - the property is NOT computed (`{ ["__proto__"]: x }` is fine),
//   - the kind is `.Init` (methods / getters / setters are fine),
//   - it is NOT a shorthand (`{ __proto__ }` references the local
//     binding, not the proto slot).
// Only literal-key init properties contribute to the §13.2.5.1
// duplicate-__proto__ early error.
property_is_literal_proto_init :: proc(prop: ^Property) -> bool {
	if prop == nil { return false }
	if prop.computed || prop.shorthand { return false }
	if prop.kind != .Init { return false }
	if prop.key == nil { return false }
	#partial switch k in prop.key^ {
	case ^Identifier:
		return k != nil && k.name == "__proto__"
	case ^StringLiteral:
		return k != nil && k.value == "__proto__"
	}
	return false
}

parse_object_expr :: proc(p: ^Parser) -> ^Expression {
	start := cur_loc(p)

	if !expect_token(p, .LBrace) {
		return nil
	}

	obj := new_node(p, ObjectExpression)
	obj.loc = start
	// Lazy alloc - empty object literals (`{}`) are common as default
	// argument values, options bags, factory return shapes, etc. Defer
	// the bump reservation until we know there's at least one property.
	if !is_token(p, .RBrace) && !is_token(p, .EOF) && !is_token(p, .Semi) {
		// Cap bumped from 4 → 8 (S23). Object literals with >4 properties
		// triggered 661 slow-path grows on monaco. Common in config objects
		// (`{ name, type, kind, value, span, comments }` etc).
		obj.properties = make([dynamic]Property, 0, 8, p.allocator)
	}

	// Inside an ObjectExpression literal, `in` is always valid as a
	// binary operator - same rule as parse_array_expr. Clear no_in so
	// `for ({a: 'x' in {}} of y)` works.
	prev_no_in := p.ctx.no_in
	p.ctx.no_in = false
	defer p.ctx.no_in = prev_no_in
	// Slice 14: scope_skip is now tracked by the checker; the parser
	// no longer suppresses anything during property-walk.

	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		// Skip stray semicolons (error recovery)
		for is_token(p, .Semi) {
			recovery_eat(p)
		}
		if is_token(p, .RBrace) || is_token(p, .EOF) {
			break
		}

		prop := parse_property(p)
		if prop != nil {
			// §13.2.5.1 duplicate `__proto__` is now enforced post-parse by
			// the semantic checker (ck_check_object_proto_dups), which can
			// distinguish ObjectExpression from ObjectPattern and suppresses
			// the diagnostic for destructuring assignment targets where
			// Annex B.3.1 makes duplicate __proto__ legal.
			bump_append(&obj.properties, prop^)
		}

		if !match_token(p, .Comma) {
			// Semicolons are not valid in object literals (spec §13.2.5).
			// Report the error and eat them for error recovery.
			if is_token(p, .Semi) {
				report_error_coded(p, .K2040_UnexpectedToken, "Unexpected ';' in object literal")
				for is_token(p, .Semi) {
					recovery_eat(p)
				}
			} else {
				break
			}
		}
		// Double comma: `{x: 0,,}` - object literals don't allow elisions.
		for is_token(p, .Comma) {
			report_error_coded(p, .K2070_RequiredFormOrBinding, "Property assignment expected")
			recovery_eat(p)
		}
		// Also skip stray semicolons after comma
		for is_token(p, .Semi) {
			recovery_eat(p)
		}
	}

	if !expect_token(p, .RBrace) {
		return nil
	}

	// §B.3.1 / §13.2.5.1 — duplicate `__proto__` in object literals.
	// Stash the error offset into pending_proto_dups instead of
	// reporting immediately.  If this ObjectExpression later gets
	// promoted to an ObjectPattern (via expr_to_pattern), the
	// entries are cleared — Annex B.3.1 makes duplicate __proto__
	// legal in destructuring patterns.  Any entries still pending
	// after parse_program finishes are reported as errors.
	{
		proto_seen := false
		for &prop in obj.properties {
			if !property_is_literal_proto_init(&prop) { continue }
			if proto_seen {
				dup_off := loc_from_expr(prop.key).start
				bump_append(&p.pending_proto_dups, dup_off)
				break
			}
			proto_seen = true
		}
	}

	obj.loc.end = prev_end_offset(p)
	return expression_from(p, obj)
}

// parse_object_accessor_value parses an object-literal getter / setter
// definition body (parameters, optional TS return-type annotation, and the
// function body, with the §15.4 accessor-shape and §15.5/§15.6/§15.8 strict
// param checks) and returns its FunctionExpression value, or nil on a parse
// error. Extracted from parse_property to keep that dispatcher shorter and to
// isolate the accessor-specific scoping (item 24). Behaviour-identical: the
// caller still owns the get/set kind decision and the if/else-if dispatch.
parse_object_accessor_value :: proc(p: ^Parser, is_setter, is_generator, is_async: bool, start: Loc, key: ^Expression) -> ^Expression {
	// Getter or setter: get x() { } or set x(v) { }
	// After parsing key, expect ( for method body
	if is_generator {
		report_error_coded(p, .K3012_AsyncGeneratorMisplaced,
			"An accessor cannot be a generator")
	}
	// Capture location of ( for the FunctionExpression
	fn_start := cur_loc(p)
	// Must be a method with () after key
	if !expect_token(p, .LParen) {
		return nil
	}
	// Parse params (getters have empty params, setters have one param).
	// §15.5.1 / §15.6.1 - yield-in-params guard for generator methods.
	// §15.8.1 - await-in-params guard for async accessors (rare but valid
	// syntactic reach via `async get`/`async set` in extended proposals;
	// keeps the invariant symmetric with method shorthand below).
	prev_gp_obj_acc := p.ctx.in_generator_params
	prev_ap_obj_acc := p.ctx.in_async_params
	prev_sb_obj_acc := p.ctx.in_static_block
	p.ctx.in_static_block = false
	p.ctx.in_generator_params = is_generator
	p.ctx.in_async_params = is_async
	// `super.x` is legal inside an object-literal accessor parameter
	// default (e.g. `{ get foo(x = super.bar()) {...} }`) because the
	// param scope inherits the method's [[HomeObject]]. Set in_method
	// BEFORE parse_function_params so the default-expression parse
	// sees it. Save / restore mirrors the body-side scoping.
	prev_in_method := p.ctx.in_method
	p.ctx.in_method = true
	prev_in_derived_ctor := p.ctx.in_derived_constructor
	p.ctx.in_derived_constructor = false
	params := parse_function_params(p)
	p.ctx.in_generator_params = prev_gp_obj_acc
	p.ctx.in_async_params = prev_ap_obj_acc
	p.ctx.in_static_block = prev_sb_obj_acc
	// Accessors always use UniqueFormalParameters (§14.3.1).
	parser_check_dup_params(p, params[:], start.start, true, false)
	if !expect_token(p, .RParen) {
		return nil
	}
	// TypeScript return type annotation on object-literal accessor.
	accessor_return_type: Maybe(^TSTypeAnnotation)
	if is_token(p, .Colon) && allow_ts_mode(p) {
		accessor_return_type = parse_ts_return_type_annotation(p)
	}
	body := parse_function_body(p)
	body_strict := p.last_body_strict
	p.ctx.in_method = prev_in_method
	p.ctx.in_derived_constructor = prev_in_derived_ctor

	// Getters / setters always have UniqueFormalParameters
	// (ECMA-262 §15.4.3 / §15.4.4).

	// §15.5.1 / §15.6.1 / §15.8.1 — ContainsUseStrict +
	// !IsSimpleParameterList for object-literal accessors. Setters
	// always have exactly one parameter (enforce_accessor_param_shape
	// above), so the only way the non-simple guard fires here is when
	// that lone setter param is a destructuring / default / rest form.
	if body_strict && !params_are_simple(params[:]) {
		report_error_coded_span(p, .K3052_UseStrictWithComplexParams, u32(fn_start.start), u32(fn_start.start), "Illegal 'use strict' directive in function with non-simple parameter list")
	}
	// §13.1.1 — retroactive strict-mode param check for
	// `set x(eval) { "use strict"; }` and friends.
	if body_strict && !p.ctx.strict_mode {
		report_strict_param_pattern_retro(p, params[:])
	}

	// §15.4.3 / §15.4.4 / §15.4.5 — PropertySetParameterList /
	// PropertyGetParameter enforce exact arity AND parameter shape:
	//   get  — zero parameters.
	//   set  — exactly one non-rest parameter, no default initializer.
	// Shared with the class-element accessor path. The default-initializer
	// two contexts emit the same diagnostic surface (object literals were
	// previously silent on `{ set foo(v=0) {} }` at parse time and the
	// checker had to fire the message in --show-semantic-errors mode).
	acc_key_loc: LexerLoc
	if key != nil {
		acc_key_loc = LexerLoc(get_expression_loc(key).start)
	} else {
		acc_key_loc = LexerLoc(fn_start.start)
	}
	enforce_accessor_param_shape(p, is_setter, params[:], acc_key_loc)

	fn, fn_e := new_expr(p, FunctionExpression)
	fn.loc = fn_start
	fn.params = params
	fn.body = body
	fn.generator = is_generator
	fn.async = is_async
	fn.return_type = accessor_return_type
	fn.loc.end = prev_end_offset(p)
	return fn_e
}

// parse_object_method_value parses an object-literal method-shorthand
// definition (optional TS type parameters, parameters, optional return-type
// annotation, and body, with the UniqueFormalParameters duplicate check and
// the §15.5/§15.6/§15.8 strict param checks) and returns its FunctionExpression
// value, or nil on a parse error. Extracted from parse_property to keep that
// dispatcher shorter (item 24). Behaviour-identical: the caller sets the
// .Method kind and owns the if/else-if dispatch.
parse_object_method_value :: proc(p: ^Parser, is_generator, is_async: bool, start: Loc) -> ^Expression {
	// Method shorthand: foo() {}
	// TS extension - generic method shorthand: foo<T>(a: T) { ... }
	// Mirrors the same dance parse_class_element does at the
	// `method_type_parameters` block.		// rejects in the "Expected }, got <" cluster (typescript
	// fixtures like assignEveryTypeToAny.ts and
	// optionalParameterRetainsNull.ts that use
	// `{ f<T>(x: T) { return x; } }` shape).
	// Capture location of ( (or `<`) for the FunctionExpression.
	fn_start := cur_loc(p)
	method_type_parameters: Maybe(^TSTypeParameterDeclaration)
	if allow_ts_mode(p) && is_open_angle_or_lshift(p) {
		method_type_parameters = parse_ts_type_parameters(p)
	}
	if !expect_token(p, .LParen) {
		return nil
	}
	// §15.5.1 / §15.6.1 - yield-in-params guard for generator methods.
	// §15.8.1 / §15.6.1 - await-in-params guard for async methods
	// (including async generator method shorthand `async *m() {}`).
	prev_gp_obj_meth := p.ctx.in_generator_params
	prev_ap_obj_meth := p.ctx.in_async_params
	// Static-block context does not extend into method parameters.
	prev_sb_obj_meth := p.ctx.in_static_block
	p.ctx.in_static_block = false
	p.ctx.in_generator_params = is_generator
	p.ctx.in_async_params = is_async
	// `super.x` in a default param of an object-literal method shorthand
	// is legal (param scope inherits [[HomeObject]]). Same async / gen
	// context the body runs under has to apply to the params too -
	// `await` and `yield` in default-param positions are gated by
	// in_async_params / in_generator_params (already set above).
	prev_in_generator := p.ctx.in_generator
	prev_in_async := p.ctx.in_async
	prev_in_method := p.ctx.in_method
	prev_in_derived_ctor := p.ctx.in_derived_constructor
	p.ctx.in_generator = is_generator
	p.ctx.in_async = is_async
	// Object-literal method shorthand - [[HomeObject]] is the object
	// literal. `super.x` is legal inside. Object methods are not
	// constructors, so `super(...)` is not legal.
	p.ctx.in_method = true
	p.ctx.in_derived_constructor = false
	params := parse_function_params(p)
	p.ctx.in_generator_params = prev_gp_obj_meth
	p.ctx.in_async_params = prev_ap_obj_meth
	p.ctx.in_static_block = prev_sb_obj_meth
	// Method shorthand always uses UniqueFormalParameters (§14.3.1).
	parser_check_dup_params(p, params[:], start.start, true, false)
	if !expect_token(p, .RParen) {
		return nil
	}
	// TS return-type annotation on plain method shorthand:
	//   const o = { method(): void { ... }, async return(v: R): Promise<...> {} }
	// Mirrors the same hook on the getter/setter branch a few lines
	// above. Without this the `:` after `)` was parsed as the start of
	// a property-key shape, ending the property and tripping `Expected
	// {`. Closes ~22 OXC corpus rejects in the "Expected {, got :"
	// cluster.
	method_return_type: Maybe(^TSTypeAnnotation)
	if is_token(p, .Colon) && allow_ts_mode(p) {
		method_return_type = parse_ts_return_type_annotation(p)
	}
	body := parse_function_body(p)
	body_strict := p.last_body_strict
	p.ctx.in_generator = prev_in_generator
	p.ctx.in_async = prev_in_async
	p.ctx.in_method = prev_in_method
	p.ctx.in_derived_constructor = prev_in_derived_ctor

	// Object-literal methods run under UniqueFormalParameters rules.

	// §15.5.1 / §15.6.1 / §15.8.1 — ContainsUseStrict +
	// !IsSimpleParameterList for object-literal methods.
	if body_strict && !params_are_simple(params[:]) {
		report_error_coded_span(p, .K3052_UseStrictWithComplexParams, u32(fn_start.start), u32(fn_start.start), "Illegal 'use strict' directive in function with non-simple parameter list")
	}
	// §13.1.1 — retroactive strict-mode param check (see the same
	// hook on parse_function_declaration above). Object-literal
	// method shorthand inherits the outer scope's strict_mode — it
	// does not implicitly become strict like class methods do.
	if body_strict && !p.ctx.strict_mode {
		report_strict_param_pattern_retro(p, params[:])
	}

	// §15.2.1.1 - BoundNames of FormalParameters vs LexicallyDeclaredNames.
  if !p.ast_only {
	check_params_vs_body_lex(p, params[:], body.body[:])
  }

	fn, fn_e := new_expr(p, FunctionExpression)
	fn.loc = fn_start
	fn.params = params
	fn.body = body
	fn.generator = is_generator
	fn.async = is_async
	fn.type_parameters = method_type_parameters
	fn.return_type = method_return_type
	fn.loc.end = prev_end_offset(p)
	return fn_e
}

parse_property :: proc(p: ^Parser) -> ^Property {
	start := cur_loc(p)

	computed := false
	key: ^Expression

	if is_token(p, .Dot3) {
		// Spread property: ...expr
		spread_start := cur_loc(p) // Capture location before eating the ...
		eat(p)
		arg := parse_assignment_expression(p)
		if arg == nil {
			return nil
		}

		// Wrap the argument in a SpreadElement
		spread, spread_e := new_expr(p, SpreadElement)
		spread.loc = spread_start // Use the location of the ... token, not the argument
		spread.argument = arg
		spread.loc.end = prev_end_offset(p)

		prop := new_node(p, Property)
		prop.loc = start
		prop.key = nil
		prop.value = spread_e
		prop.kind = .Init
		prop.computed = false
		prop.shorthand = false
		prop.loc.end = prev_end_offset(p)
		return prop
	}

	// Check for get/set keywords and generator/async modifiers
	is_getter := false
	is_setter := false
	is_generator := false
	is_async := false

	if is_token(p, .Get) || is_token(p, .Set) {
		// Only treat as getter/setter if followed by a property name (not : or ( directly).
		// Any keyword can be a property name (ES spec: PropertyName → IdentifierName).
		next := peek_token(p)
		if next.type == .Identifier || next.type == .String || next.type == .Number ||
		   next.type == .BigInt || next.type == .LBracket || next.type == .Mul ||
		   is_keyword_usable_as_property_name(next.type) {
			if is_token(p, .Get) {
				is_getter = true
			} else {
				is_setter = true
			}
			eat(p)
		}
	} else if is_token(p, .Async) {
		// Only treat as async if followed by a property name or `*`.
		// `{ async() {} }` is a method NAMED "async" (no async modifier),
		// not an async method with an empty name - LParen here exits the
		// async-modifier branch and falls through to the regular key path.
		next := peek_token(p)
		if next.type == .Identifier || next.type == .String || next.type == .Number ||
		   next.type == .BigInt || next.type == .LBracket || next.type == .Mul ||
		   is_keyword_usable_as_property_name(next.type) {
			// §15.8.1 Restricted Production - no LineTerminator between
			// `async` and the method name. With a newline, `async` is the
			// shorthand property name and what follows is the next member.
			if !next.had_line_terminator {
				eat(p)
				is_async = true
			}
		}
	}

	// Check for generator modifier (can come after async or before identifier)
	if is_token(p, .Mul) {
		eat(p)
		is_generator = true
		// After `*`, a property name must follow. `{ * }` is invalid.
		if is_token(p, .RBrace) || is_token(p, .Comma) || is_token(p, .RParen) {
			report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected method name after '*'")
			return nil
		}
	}

	// Parse key
	if match_token(p, .LBracket) {
		computed = true
		// `[` clears the for-head no_in restriction - see parse_class_element /
		// parse_object_pattern for the parallel resets.
		prev_no_in_prop := p.ctx.no_in
		p.ctx.no_in = false
		key = parse_assignment_expression(p)
		p.ctx.no_in = prev_no_in_prop
		if key == nil {
			return nil
		}
		if !expect_token(p, .RBracket) {
			return nil
		}
	} else if is_token(p, .BigInt) {
		// BigInt literal key: `{ 1n: value }`. The numeric value is
		// the string representation of the BigInt, per §13.2.3.1.
		current := snap_current(p)
		big, big_e := new_expr(p, BigIntLiteral)
		big.loc = loc_from_token(&current)
		big.raw = current.value
		if len(current.value) > 0 && current.value[len(current.value)-1] == 'n' {
			big.value = current.value[:len(current.value)-1]
		} else {
			big.value = current.value
		}
		big.loc.end = prev_end_offset(p)
		key = big_e
		eat(p)
	} else if is_token(p, .Identifier) || is_token(p, .String) || is_token(p, .Number) ||
	          is_keyword_usable_as_property_name(p.cur_type) {
		// Capture has_escape + name BEFORE parse_property_name consumes
		// the token. Used below if the property ends up shorthand
		// (§12.7.2: escaped ReservedWord in IdentifierReference position,
		// §12.6.1.1 in strict mode).
		key_tok_type := p.cur_type
		key_had_escape := cur_has_escape(p) && p.cur_type == .Identifier
		key_name := cur_value(p)
		key = parse_property_name(p)
		// Shorthand-only post-check. `{ foo }` = `{ foo: foo }` where the
		// value is an IdentifierReference to `foo`; `{ key: value }` and
		// `{ key() { ... } }` exit through earlier branches. Distinguish by
		// looking at the next token.
		if !is_token(p, .Colon) && !is_token(p, .LParen) {
			if key_had_escape && is_always_reserved_word_name(key_name) {
				msg := fmt.tprintf("Keyword '%s' must not contain escaped characters", key_name)
				report_error_coded(p, .K3015_KeywordContainsEscape, msg)
			}
			// Escaped strict-reserved word in BindingIdentifier position is
			// also forbidden by §12.7.2 (always, not just in strict mode):
			// `({ l\u0065t })`, `({ st\u0061tic })`, `({ yi\u0065ld })` are
			// SyntaxErrors regardless of enclosing strict / sloppy.
			if key_had_escape {
				if is_strict_reserved_name(key_name) ||
				   key_name == "let" || key_name == "static" ||
				   key_name == "yield" {
					msg := fmt.tprintf("Keyword '%s' must not contain escaped characters", key_name)
					report_error_coded(p, .K3015_KeywordContainsEscape, msg)
				}
			}
			// §12.6.1.1 strict-mode IdentifierReference reservation check
			// for shorthand-property names is enforced by the semantic
			// checker (ck_check_identifier_reference_strict via the
			// ObjectExpression walker's shorthand-Identifier visit).
			_ = key_tok_type
			_ = key_name
		}
	} else {
		return nil
	}

	// Determine property kind and parse value
	kind := PropertyKind.Init
	value: ^Expression
	shorthand := false

	if is_getter || is_setter {
		kind = .Set
		if is_getter {
			kind = .Get
		}
		value = parse_object_accessor_value(p, is_setter, is_generator, is_async, start, key)
		if value == nil {
			return nil
		}
	} else if is_token(p, .LParen) || (allow_ts_mode(p) && is_open_angle_or_lshift(p)) {
		kind = .Method
		value = parse_object_method_value(p, is_generator, is_async, start)
		if value == nil {
			return nil
		}
	} else if match_token(p, .Colon) {
		// Regular property with value. `async a: v` / `*a: v` are not valid
		// data properties; `async` and `*` only modify method definitions.
		if is_async || is_generator {
			report_error_coded(p, .K4032_ModifierMisplaced, "Object property modifier requires a method definition")
		}
		// Use Assignment precedence - comma separates properties, not expressions
		value = parse_expr_with_prec(p, .Assignment)
	} else if match_token(p, .Assign) {
		// Shorthand with default: { foo = defaultValue } - only legal as
		// CoverInitializedName inside a destructuring assignment cover
		// (§13.2.5.1 / §13.15.5.2). Parse permissively here; record the
		// offset in p.pending_cover_inits. expr_to_pattern clears the
		// entry when the ObjectExpression gets promoted to an
		// ObjectPattern; anything left after parse_program is a
		// SyntaxError.
		default_val := parse_expr_with_prec(p, .Assignment)
		assign := new_node(p, AssignmentExpression)
		assign.loc = start
		assign.operator = .Assign
		// shared the same ^Expression pointer with prop.key; raw_transfer
		// then walked that Expression union TWICE (once via prop.key, once
		// via assign.left), and the second walk dereferenced an
		// already-rewritten inner pointer (now an arena offset, not a real
		// pointer) and segfaulted. 
		// `({excludeEmptyString = false, message, name} = options)` triggers
		// the alias inside a destructuring cover.
		// Clone the inner Identifier into a fresh Expression union so each
		// AST slot owns its own node (matches ESTree shape - the JSON path
		// already emits two distinct Identifier objects at these positions).
		if key != nil {
			#partial switch k in key^ {
			case ^Identifier:
				if k != nil {
					cloned, cloned_e := new_expr(p, Identifier)
					cloned.loc = k.loc
					cloned.name = k.name
					assign.left = cloned_e
				} else {
					assign.left = key
				}
			case:
				// Non-Identifier keys (StringLiteral, NumericLiteral) cannot
				// legally be the LHS of CoverInitializedName, but the parse
				// is permissive here and expr_to_pattern / parse-program
				// emits the SyntaxError later. Keep the alias for those
				// shapes - they don't hit the raw-transfer crash because the
				// node never round-trips successfully anyway.
				assign.left = key
			}
		} else {
			assign.left = key
		}
		assign.right = default_val
		assign.loc.end = prev_end_offset(p)
		shorthand = true
		value = expression_from(p, assign)
		bump_append(&p.pending_cover_inits, start.start)
	} else {
		// Shorthand property: { foo } means { foo: foo }
		// Not valid for generators/getters/setters
		if is_generator || is_async {
			report_error_coded(p, .K3012_AsyncGeneratorMisplaced,
				"Generator/async shorthand property not allowed")
			return nil
		}
		// §13.2.5.1 PropertyDefinition shorthand only accepts an
		// IdentifierReference - computed `[expr]` and numeric / string
		// keys cannot stand alone. `({[x]})`, `({0})`, `({"foo"})` are
		// SyntaxErrors. Other key shapes (Identifier / contextual keyword)
		// fall through to the regular shorthand path.
		if computed {
			report_error_coded(p, .K2070_RequiredFormOrBinding, "Computed property name requires a value")
		} else if key != nil {
			#partial switch k in key^ {
			case ^NumericLiteral, ^StringLiteral, ^BigIntLiteral:
				report_error_coded(p, .K2070_RequiredFormOrBinding, "Numeric / string property name requires a value")
			case ^Identifier:
				// Shorthand binding name must be a valid IdentifierReference.
				// Hard reserved keywords (default, extends, class, function,
				// if, ...) cannot be used. Escaped-reserved variants are
				// caught at the IdentifierName branch above via the
				// has_escape pre-capture.
				if k != nil && is_always_reserved_word_name(k.name) {
					msg := fmt.tprintf("Reserved word '%s' is not a valid binding identifier", k.name)
					report_error_coded(p, .K3053_ReservedAsBindingIdentifier, msg)
				}
				// Contextually reserved: `yield` in generators, `await` in async/static blocks.
				if k != nil && k.name == "yield" && yield_is_reserved_here(p) {
					report_error_coded(p, .K3010_AwaitYieldAsBindingName, "'yield' is reserved as a binding name in a generator")
				}
				if k != nil && k.name == "await" && await_is_reserved_here(p) {
					report_error_coded(p, .K3010_AwaitYieldAsBindingName,
			"'await' cannot be used as a shorthand property identifier")
				}
				// §13.2.5.4 — ObjectLiteral PropertyDefinition shorthand
				// IdentifierReference is a CoverInitializedName candidate;
				// the AssignmentTargetType must be valid. In strict mode
				// strict-reserved names (let / static / yield / implements
				// / interface / package / private / protected / public) and
				// eval / arguments are NOT valid BindingIdentifiers, so the
				// shorthand fails. Promoted from the semantic checker
				// (ck_check_shorthand_property_strict_reserved).
				if k != nil && p.ctx.strict_mode {
					if is_eval_or_arguments(k.name) {
						msg := fmt.tprintf("'%s' cannot be used as a shorthand property identifier in strict mode", k.name)
						report_error_coded_span(p, .K3050_StrictModeReserved, u32(k.loc.start), u32(k.loc.start), msg)
					} else if is_strict_reserved_binding_name(k.name) {
						msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", k.name)
						report_error_coded_span(p, .K3050_StrictModeReserved, u32(k.loc.start), u32(k.loc.start), msg)
					}
				}
			}
		}
		shorthand = true
		value = key
	}

	prop := new_node(p, Property)
	prop.loc = start
	prop.key = key
	prop.value = value
	prop.kind = kind
	prop.computed = computed
	prop.shorthand = shorthand
	prop.loc.end = prev_end_offset(p)

	return prop
}

parse_property_name :: proc(p: ^Parser) -> ^Expression {
	current := snap_current(p)

	#partial switch current.type {
	case .Identifier:
		eat(p)
		ident, ident_e := new_expr(p, Identifier)
		ident.loc = loc_from_token(&current)
		ident.name = current.value
		ident.loc.end = prev_end_offset(p)
		return ident_e

	case .String:
		// §12.9.4.1 — check for octal/\8/\9 escapes in strict mode.
		if p.ctx.strict_mode && len(current.value) > 2 {
			check_strict_string_escapes(p, current.value, current.start)
		}
		eat(p)
		str, str_e := new_expr(p, StringLiteral)
		str.loc = loc_from_token(&current)
		str.raw = current.value
		if val, ok := current.literal.(string); ok {
			str.value = val
		}
		str.loc.end = prev_end_offset(p)
		return str_e

	case .BigInt:
		eat(p)
		big, big_e := new_expr(p, BigIntLiteral)
		big.loc = loc_from_token(&current)
		big.raw = current.value
		if len(current.value) > 0 && current.value[len(current.value)-1] == 'n' {
			big.value = current.value[:len(current.value)-1]
		} else {
			big.value = current.value
		}
		big.loc.end = prev_end_offset(p)
		return big_e

	case .Number:
		eat(p)
		num, num_e := new_expr(p, NumericLiteral)
		num.loc = loc_from_token(&current)
		num.raw = current.value
		if val, ok := current.literal.(f64); ok {
			num.value = val
		}
		num.loc.end = prev_end_offset(p)
		// §12.9.3.5 (Annex B.1.1) — LegacyOctalIntegerLiteral and
		// NonOctalDecimalIntegerLiteral are SyntaxErrors in strict mode.
		// Promoted from the semantic checker (ck_check_legacy_octal_number)
		// so parser-only snaps reject `"use strict"; 010;` /
		// `"use strict"; 078;` and friends. Only the primary-expression
		// numeric path needs the hook — object property keys (§13.2.5),
		// destructuring keys, and TS literal-type names go through other
		// branches that don't surface to runtime evaluation.
		if p.ctx.strict_mode && is_legacy_zero_prefixed_integer(num.raw) {
			report_error_coded_span(p, .K3051_StrictModeProhibited, u32(num.loc.start), u32(num.loc.start), "Legacy octal literals are not allowed in strict mode")
		}
		return num_e

	case:
		// All keywords can be used as property names in ES
		if is_keyword_usable_as_property_name(current.type) {
			eat(p)
			ident, ident_e := new_expr(p, Identifier)
			ident.loc = loc_from_token(&current)
			ident.name = current.value
			ident.loc.end = prev_end_offset(p)
			return ident_e
		}
		return nil
	}
}

parse_function_expression :: proc(p: ^Parser) -> ^Expression {
	// parse_function_declaration with is_expr=true returns a ^Statement
	// union wrapping an ^ExpressionStatement whose .expression is the
	// FunctionExpression (now boxed via expression_from). Extract it safely
	// via the union cast - the old transmute(^FunctionDeclaration)stmt was
	// undefined behavior that read the wrong struct layout.
	stmt := parse_function_declaration(p, true)
	if stmt == nil {
		return nil
	}
	expr_stmt, ok := stmt^.(^ExpressionStatement)
	if !ok {
		return nil
	}
	return expr_stmt.expression
}

parse_class_expression :: proc(p: ^Parser) -> ^Expression {
	start := cur_loc(p)
	eat(p) // consume class

	id: Maybe(BindingIdentifier)
	// In TS mode, `class implements Foo {}` has no name - `implements` is
	// the heritage clause keyword, not a class name. Don't consume it as
	// the identifier when the next token is a plausible interface name or
	// `{`. Same for `class extends Expr {}` which is already handled by
	// the `extends` path below.
	ensure_nxt(p)
	is_implements_keyword := (p.lang == .TS || p.lang == .TSX) &&
	                         is_token(p, .Identifier) && cur_value_eq(p, "implements") &&
	                         (p.lexer.nxt.kind == .Identifier || is_keyword_usable_as_property_name(p.lexer.nxt.kind) || p.lexer.nxt.kind == .LBrace)
	if can_be_binding_identifier(p.cur_type) && !is_implements_keyword {
		current := snap_current(p)
		name_tok_type := p.cur_type
		id = BindingIdentifier{
			loc  = loc_from_token(&current),
			name = current.value,
		}
		// §12.7.2 escaped-ReservedWord in BindingIdentifier position.
		// Class names are strict-mode-only (§15.7.1), so the strict-only
		// reservation list applies to escapes too. Check escapes FIRST
		// so the escaped-keyword diagnostic fires rather than the
		// plainer "reserved identifier" message.
		if cur_has_escape(p) {
			if is_always_reserved_word_name(current.value) ||
			   is_strict_reserved_name(current.value) ||
			   current.value == "let" || current.value == "static" ||
			   current.value == "yield" {
				msg := fmt.tprintf("Keyword '%s' must not contain escaped characters", current.value)
				report_error_coded(p, .K3015_KeywordContainsEscape, msg)
			}
		}
		// §15.7.1 strict-reserved / eval / arguments — class names
		// are always parsed in strict mode. Skip in TS mode (tsc/OXC allow).
		if !allow_ts_mode(p) && is_strict_reserved_binding_name(current.value) {
			report_error_coded(p, .K3030_ClassDeclarationStructure, fmt.tprintf("'%s' is a reserved identifier and cannot be a class name", current.value))
		}
		// §12.6.1.1 contextual `await` reservation.
		if current.value == "await" {
			if await_is_reserved_here(p) {
				report_error_coded(p, .K3010_AwaitYieldAsBindingName,
					"'await' cannot be used as a class name in module / async / static-block context")
			} else if st, have := p.force_source_type.(SourceType); have && st == .Module {
				report_error_coded(p, .K3010_AwaitYieldAsBindingName,
					"'await' cannot be used as a class name in module context")
			} else if p.in_module_top_level || p.has_module_syntax {
				report_error_coded(p, .K3010_AwaitYieldAsBindingName,
					"'await' cannot be used as a class name in module context")
			}
		}
		eat(p)
	}

	// TypeScript generic type parameters on class expression: `(class<T> {})`,
	// `(class C<T> {})`. Must come before the heritage clause, mirroring
	// parse_class_declaration. Closes OXC corpus "Expected {, got <" cluster
	type_parameters: Maybe(^TSTypeParameterDeclaration)
	if (p.lang == .TS || p.lang == .TSX) && is_token(p, .LAngle) {
		type_parameters = parse_ts_type_parameters(p)
	}

	super_class: Maybe(^Expression)
	// §15.7 - ClassExpression is always strict mode code.
	prev_strict_cls_expr := p.ctx.strict_mode
	p.ctx.strict_mode = true
	defer p.ctx.strict_mode = prev_strict_cls_expr
	super_type_arguments: Maybe(^TSTypeParameterInstantiation)
	if match_token(p, .Extends) {
		super_class = parse_left_hand_side_expr(p)
		if super_class == nil {
			report_error_coded(p, .K2020_ExpectedExpression, "Expected expression after 'extends'")
		}
		// OXC parses type arguments on class heritage in all modes.
		// In JS mode, only plain `<` — `<<` stays as left-shift.
		if (allow_ts_mode(p) && is_open_angle_or_lshift(p)) ||
		   (!allow_ts_mode(p) && is_token(p, .LAngle)) {
			super_type_arguments = parse_ts_type_arguments(p)
		}
		// Unparenthesised arrow functions are AssignmentExpressions, not
		// LeftHandSideExpressions. Parenthesised arrows are fine.
		if sc, have := super_class.(^Expression); have && sc != nil {
			if arrow, is_arrow := sc^.(^ArrowFunctionExpression); is_arrow && arrow != nil {
				arrow_start := int(arrow.loc.start)
				paren_wrapped := is_paren_wrapped_at(p, arrow_start)
				if !paren_wrapped {
					report_error_coded(p, .K3066_InvalidAssignmentOrBindingTarget, "Arrow function is not a valid class heritage expression")
				}
			}
		}
	}

	// TS: `class C extends Base implements I, J<T>` - same grammar as
	// parse_class_declaration. `implements` is a contextual keyword.
	implements_list: [dynamic]TSInterfaceHeritage
	if (p.lang == .TS || p.lang == .TSX) &&
	   is_token(p, .Identifier) && cur_value_eq(p, "implements") {
		eat(p)
		implements_list = parse_ts_heritage_list(p)
		if len(implements_list) == 0 {
			report_error_coded(p, .K4051_TSDeclarationStructure, "Expected interface name after 'implements'")
		}
	}

	// See parse_class_declaration for the rationale - same save/restore.
	prev_class_has_extends := p.ctx.class_has_extends
	p.ctx.class_has_extends = (super_class != nil)
	defer p.ctx.class_has_extends = prev_class_has_extends

	// Class expressions are never abstract — reset the flag so nested
	// class expressions inside abstract class methods don't inherit it.
	prev_class_is_abstract := p.ctx.class_is_abstract
	p.ctx.class_is_abstract = false
	defer p.ctx.class_is_abstract = prev_class_is_abstract

	body := parse_class_body(p)

	expr, expr_e := new_expr(p, ClassExpression)
	expr.loc = start
	expr.id = id
	expr.type_parameters = type_parameters
	expr.super_class = super_class
	expr.super_type_arguments = super_type_arguments
	expr.implements = implements_list
	expr.body = body
	expr.loc.end = prev_end_offset(p)

	return expr_e
}

parse_new_expr :: proc(p: ^Parser) -> ^Expression {
	start := cur_loc(p)
	eat(p) // consume new

	// new.target - MetaProperty
	if is_token(p, .Dot) {
		next := peek_token(p)
		if next.value == "target" {
			eat(p) // consume .
			target_tok := snap_current(p)
			eat(p) // consume target
			// ECMA-262 §13.3.12 / §15.2 - `new.target` is only valid inside
			// a non-arrow function body. Arrow functions inherit
			// [[NewTarget]] from their enclosing scope, so an arrow at
			// script top-level has no new.target either. Test262:
			// language/global-code/new.target-arrow.js.
			// §13.3.12 / §15.2 — `new.target` outside a function body.
			// Allowed in: non-arrow function bodies, class field initializers
			// (the field runs as part of the constructor), class static blocks,
			// and CommonJS files (the file is wrapped in a function).
			if !p.ctx.in_non_arrow_function && !p.ctx.in_field_init && !p.ctx.in_static_block && !p.is_commonjs {
				report_error_coded(p, .K3067_NewTargetOrTopLevelUsing, "'new.target' is only allowed inside functions")
			}
			meta, meta_e := new_expr(p, MetaProperty)
			meta.loc = start
			meta.meta = Identifier{loc = start, name = "new"}
			meta.property = Identifier{loc = loc_from_token(&target_tok), name = "target"}
			meta.loc.end = prev_end_offset(p)
			return meta_e
		}
	}

	// ECMA-262 §13.3.12 - `new import(x)` is a SyntaxError. The grammar
	// production NewExpression : `new` NewExpression has no arm that
	// reaches an ImportCall (`import(...)`). Catch it here at the start
	// so the diagnostic points at `import`, not somewhere downstream.
	// Same rule applies to phase-import call forms (§Phase Imports):
	//   `new import.defer(x)` / `new import.source(x)` are SyntaxErrors.
	// BUT `new import.meta()` is VALID syntax - it calls the MetaProperty
	// as a constructor (throws at runtime). Test262: language/expressions/
	// import.meta/import-meta-is-an-ordinary-object.js.
	if is_token(p, .Import) && p.lexer != nil {
  ensure_nxt(p)
		if p.lexer.nxt.kind == .LParen {
			report_error_coded(p, .K3023_ImportMetaOrDynamicImportInvalid, "Dynamic 'import()' cannot be invoked with 'new'")
		} else if p.lexer.nxt.kind == .Dot {
			// Source-byte lookahead past the `.` to see whether the
			// property name is the legal `meta` MetaProperty or one of
			// the phase-import call forms (`defer` / `source`).
   ensure_nxt(p)
			dot_off := int(p.lexer.nxt.end)
			src := p.lexer.source_bytes
			// Skip whitespace after the `.`.
			for dot_off < len(src) {
				ch := src[dot_off]
				if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { dot_off += 1; continue }
				break
			}
			is_meta := dot_off + 4 <= len(src) &&
			           src[dot_off]   == 'm' && src[dot_off+1] == 'e' &&
			           src[dot_off+2] == 't' && src[dot_off+3] == 'a'
			if !is_meta {
				report_error_coded(p, .K3023_ImportMetaOrDynamicImportInvalid, "Dynamic 'import()' cannot be invoked with 'new'")
			}
		}
	}

	callee := parse_member_expr(p)
	if callee == nil {
		report_error_coded(p, .K2020_ExpectedExpression, "Expected expression after 'new'")
		return nil
	}
	// §15.2.2 — `new await` in module context: `await` is reserved.
	// Promote from the checker so parser-only snaps catch it.
	if callee != nil {
		if callee_id, is_id := callee^.(^Identifier); is_id && callee_id.name == "await" {
			await_reserved := p.ctx.in_async || p.ctx.in_static_block
			if !await_reserved {
				if st, have := p.force_source_type.(SourceType); have && st == .Module { await_reserved = true }
				else if p.in_module_top_level || p.has_module_syntax { await_reserved = true }
			}
			if await_reserved {
				report_error_coded_span(p, .K3010_AwaitYieldAsBindingName, u32(callee_id.loc.start), u32(callee_id.loc.start), "Cannot use 'await' as an identifier in module / async context")
			}
		}
	}
	if _, is_super := callee^.(^Super); is_super {
		report_error_coded(p, .K3033_SuperInvalidContext, "'new super()' is not allowed")
	}
	// `new <T>Foo()` — legacy TS type assertion after `new` is ambiguous
	// with type parameters. OXC rejects this form. Only fire when the
	// `<T>` is the direct callee (not parenthesized: `new (<T>x)` is OK).
	if ta, is_ta := callee^.(^TSTypeAssertion); is_ta {
		// Check if the assertion starts right after `new ` (no parens).
		if p.lexer != nil && ta.loc.start == start.start + 4 {
			report_error_coded(p, .K4053_TSOnlyInJS, "Type assertion is not allowed after 'new'")
		}
	}

	// TS generic type arguments: `new Foo<string>()`.
	// Ambiguity: `new Date<A;` is `(new Date) < A;` (relational), NOT
	// `new Date<A>` (type args). Use speculative parse: try to parse
	// type arguments and accept only if the closing `>` is found.
	targs: Maybe(^TSTypeParameterInstantiation)
	if allow_ts_mode(p) && is_open_angle_or_lshift(p) {
		snap := lexer_snapshot(p)
		ta := parse_ts_type_arguments(p)
		// On success the current token is past the `>`. If the parse
		// failed (error was pushed), backtrack - the `<` is the less-than
		// operator and this is a relational expression.
		// Also backtrack when type args parsed OK but the next token
		// can't follow `new Expr<T>` - only `(` (call) and `.` / `[`
		// (member) are valid. Anything else (identifier, `;`, EOF, ...)
		// means `<` was relational. Fixes `new A < B > C`.
		parse_failed := len(p.errors) > snap.errors_len
		next_valid := p.cur_type == .LParen || p.cur_type == .Dot ||
		              p.cur_type == .LBracket || p.cur_type == .OptionalChain ||
		              p.cur_type == .Template || p.cur_type == .TemplateHead ||
		              p.cur_type == .Semi || p.cur_type == .EOF ||
		              p.cur_type == .RBrace || p.cur_type == .RParen ||
		              p.cur_type == .RBracket || p.cur_type == .Comma
		if parse_failed || !next_valid {
			lexer_restore(p, snap)
		} else {
			targs = ta
		}
	}

	args: [dynamic]^Expression
	if is_token(p, .LParen) {
		// Clear pending_paren_start before the arg list. When the callee was
		// itself parenthesised (`new (expr)(args)`), parse_primary_expr sets
		// pending_paren_start for the next consumer. parse_lhs_tail with
		// allow_call=false returns early without consuming it (leaving the
		// `(` for US to consume as NewExpression args), but this leaves the
		// stamp stuck. parse_arguments doesn't touch it either, so the stamp
		// then leaks into the following statement where the first
		// MemberExpression / CallExpression / arrow widens its start span
		// backwards to the paren position. Observed on d3.js as a 86-byte
		// span drift on the `return m.isIdentity ? ... : ...` ternary
		// directly after `const m = new (typeof DOMMatrix === "function" ?
		// DOMMatrix : WebKitCSSMatrix)(value + "");`.
		p.pending_paren_start = max(u32)
		args = parse_arguments(p)
	}

	new_, new__e := new_expr(p, NewExpression)
	new_.loc = start
	new_.callee = callee
	new_.arguments = args
	new_.type_parameters = targs
	new_.loc.end = prev_end_offset(p)

	return new__e
}

parse_arguments :: proc(p: ^Parser) -> [dynamic]^Expression {
	if !expect_token(p, .LParen) {
		return nil
	}

	// Inside function call arguments, the `in` operator is always allowed
	// even when we're in a for-init position (no_in=true). §13.16:
	// ArgumentList members are AssignmentExpressions, not restricted.
	// Fixes `for (a(b in c)[0] in d)` where `b in c` was rejected.
	saved_no_in := p.ctx.no_in
	p.ctx.no_in = false
	defer p.ctx.no_in = saved_no_in

	// Lazy allocation - zero-argument calls (`fn()`) are extremely common
	// (every method-chain step like `.map().filter().toArray()` has them)
	// and would otherwise burn a 32-byte bump-pool reservation per call
	// for an unused 4-pointer dynamic array. Defer the make until we know
	// the call has at least one argument.
	args: [dynamic]^Expression

	if !is_token(p, .RParen) {
		// Cap bumped from 4 → 8 (S23). Function calls with >4 args triggered
		// 945 slow-path grows on monaco. Many APIs take 5-8 args (e.g.
		// React.createElement(type, props, ...children) or fmt.Printf-style).
		args = make([dynamic]^Expression, 0, 8, p.allocator)
		for {
			// `(,)` and `(a,,b)` - elision is not allowed in Arguments
			// per §13.3.5. The grammar is `Arguments :: ( ArgumentList )`
			// with no holes. Test262: language/expressions/call/
			// S11.2.4_A1.3_T1.js (`f_arg(1,,2)`).
			if is_token(p, .Comma) {
				report_error_coded(p, .K2020_ExpectedExpression, "Argument expression expected")
				eat(p) // consume the stray comma so we don't loop
				continue
			}
			if is_token(p, .Dot3) {
				spread_start := cur_loc(p) // Capture location of ... before eating
				eat(p)
				arg := parse_assignment_expression(p)
				if arg != nil {
					if _, nested_spread := arg.(^SpreadElement); nested_spread {
						report_error_coded(p, .K3042_RestSpreadMisuse, "Spread argument cannot contain another spread element")
					}
					spread, spread_e := new_expr(p, SpreadElement)
					spread.loc = spread_start // Use location of ... token, not the argument
					spread.argument = arg
					spread.loc.end = prev_end_offset(p)
					bump_append(&args, spread_e)
				} else {
					// `...` in argument position must be followed by an
					// AssignmentExpression (the spread target). `fn(..., x)`
					// and `fn(...)` (empty) are both SyntaxErrors. Report so
					// the recovery verifier and error-reporting consumers
					// see the problem; parse continues at `,` / `)`.
					report_error_coded(p, .K2020_ExpectedExpression, "Expected expression after '...'")
				}
			} else {
				arg := parse_assignment_expression(p)
				if arg != nil {
					bump_append(&args, arg)
				}
			}

			if !match_token(p, .Comma) {
				break
			}
		}
	}

	if !expect_token(p, .RParen) {
		return nil
	}

	return args
}

// True when the token immediately following the current `yield`
// cleanly starts an AssignmentExpression argument -
// i.e. the user wrote `yield <expr>` rather than `yield;`,
// `yield + 1`, `yield.x`, `yield(x)`, `` yield`t` ``, etc. A
// line-terminator between `yield` and the next token triggers ASI
// and counts as no-argument. Used in non-generator contexts to
// distinguish the yield-expression form (SyntaxError) from `yield`
// used as an IdentifierReference.
yield_next_is_expression_argument :: proc(p: ^Parser) -> bool {
	nxt := peek_token(p)
	if nxt.had_line_terminator { return false }
	#partial switch nxt.type {
	// Statement / list terminators - no argument.
	case .Semi, .Comma, .Colon, .RParen, .RBracket, .RBrace, .EOF, .Invalid,
	// Binary / logical / coalescing operators - yield is LHS identifier.
	     .Plus, .Minus, .Mul, .Div, .Mod, .Pow,
	     .LShift, .RShift, .URShift,
	     .BitAnd, .BitOr, .BitXor,
	     .LogicalAnd, .LogicalOr, .Nullish,
	// Assignment operators - yield on the left of `=` / compound assigns.
	     .Assign, .AssignAdd, .AssignSub, .AssignMul, .AssignDiv,
	     .AssignMod, .AssignPow,
	     .AssignLShift, .AssignRShift, .AssignURShift,
	     .AssignBitAnd, .AssignBitOr, .AssignBitXor,
	     .AssignLogicalAnd, .AssignLogicalOr, .AssignNullish,
	// Comparisons / equality.
	     .Eq, .NotEq, .EqStrict, .NotEqStrict,
	     .LAngle, .RAngle, .LEq, .GEq,
	     .In, .Instanceof,
	// Ternary / arrow / postfix.
	     .Question, .Arrow,
	     .PlusPlus, .MinusMinus,
	// Member / call / tagged-template continuations.
	     .Dot, .OptionalChain, .LParen, .LBracket,
	     .Template, .TemplateHead:
		return false
	}
	// Everything else - identifiers, literals, `new`, `function`,
	// `class`, `this`, `super`, `typeof` / `void` / `delete`,
	// `!` / `~`, `{`, `/` regex (lexed as RegularExpression), etc.
	// - begins a fresh AssignmentExpression, so we read the
	// `yield` as yield-expression form.
	return true
}

parse_yield_expr :: proc(p: ^Parser) -> ^Expression {
	start := cur_loc(p)
	// ECMA-262 §15.5.1 - "It is a Syntax Error if FormalParameters
	// Contains YieldExpression is true." `yield` is not allowed inside
	// a generator's formal parameter defaults (the generator scope
	// only starts INSIDE the body). `p.ctx.in_generator_params` is set by
	// parse_function_params / parse_class_method before calling
	// parse_function_params.
	eat(p) // consume yield

	if p.ctx.in_generator_params {
		report_error_coded(p, .K3011_AwaitYieldExpressionContextRestricted,
			"'yield' expression is not allowed in formal parameters of a generator")
	}

	// ECMA-262 §15.5 Restricted Production: no LineTerminator between
	// `yield` and AssignmentExpression / `*`. If the next token has a
	// preceding newline, emit a bare `yield` expression; the rest starts
	// a new statement.
	has_newline := cur_has_newline(p)
	delegate := false
	if !has_newline {
		delegate = match_token(p, .Mul)
	}
	// `yield /re/` inside a generator: the lexer no longer treats `.Yield`
	// as a regex-start (see can_start_regex), so a leading `/` was
	// classified as Div. Re-lex on demand here so the AssignmentExpression
	// argument sees the regex literal.
	if !has_newline && (p.cur_type == .Div || p.cur_type == .AssignDiv) {
		if p.lexer != nil {
			relex_as_regex(p.lexer)
			ft := p.lexer.cur
			p.cur_type = ft.kind
		}
	}

	argument: Maybe(^Expression)
	if !has_newline && !is_token(p, .Semi) && !is_token(p, .RParen) && !is_token(p, .RBracket) && !is_token(p, .RBrace) && !is_token(p, .Comma) {
		argument = parse_assignment_expression(p)
	}

	// §15.5.5 - `yield*` (YieldExpression with delegate=true) requires
	// an AssignmentExpression operand. `yield*` without one is a SyntaxError.
	if delegate && argument == nil {
		report_error_coded(p, .K2020_ExpectedExpression, "'yield*' requires an operand")
	}

	yield, yield_e := new_expr(p, YieldExpression)
	yield.loc = start
	yield.argument = argument
	yield.delegate = delegate
	yield.loc.end = prev_end_offset(p)

	return yield_e
}

parse_template_literal :: proc(p: ^Parser, tagged: bool) -> ^Expression {
	start := cur_loc(p)
	current := snap_current(p)

	tmpl, tmpl_e := new_expr(p, TemplateLiteral)
	tmpl.loc = start
	// Adjust start to include the opening backtick (lexer sets token after backtick)
	if tmpl.loc.start > 0 {
		tmpl.loc.start -= 1
	}
	tmpl.quasis = make([dynamic]TemplateElement, 0, 4, p.allocator)
	tmpl.expressions = make([dynamic]^Expression, 0, 4, p.allocator)

	// Handle simple template: `hello`
	if current.type == .Template {
		elem := TemplateElement{
			loc  = loc_from_token(&current),
			tail = true,
			raw  = current.value,
		}
		if cooked, ok := current.literal.(string); ok {
			elem.cooked = cooked
		}
		bump_append(&tmpl.quasis, elem)
		eat(p)
		tmpl.loc.end = prev_end_offset(p) + 1 // Include closing backtick
		p.prev_token_end = tmpl.loc.end // Update for parent nodes
		// §12.9.6 octal / \\8 / \\9 escape in untagged template:
		// enforced by the semantic checker (ck_check_template_octal).
		// Untagged templates reject §12.9.6 invalid EscapeSequences in
		// ALL modes - truncated \xH, \uH, \u{bad}, legacy-octal, etc.
		if !tagged && untagged_template_raw_has_invalid_escape(elem.raw) {
			report_error_coded(p, .K1011_InvalidEscapeSequence, "Invalid escape sequence in template literal")
		}
		return tmpl_e
	}

	// Handle template with expressions: `hello ${name} world`
	if current.type == .TemplateHead {
		// First quasi: `hello ${
		elem := TemplateElement{
			loc  = loc_from_token(&current),
			tail = false,
			raw  = current.value,
		}
		if cooked, ok := current.literal.(string); ok {
			elem.cooked = cooked
		}
		bump_append(&tmpl.quasis, elem)
		eat(p) // consume TemplateHead

		// Template substitution bodies (`${...}`) are independent
		// AssignmentExpressions - the enclosing no_in must not leak.
		prev_no_in := p.ctx.no_in
		p.ctx.no_in = false
		defer p.ctx.no_in = prev_no_in

		// Parse embedded expressions and middle/tail parts
		for {
			// Parse expression
			expr := parse_assignment_expression(p)
			if expr != nil {
				bump_append(&tmpl.expressions, expr)
			}

			// Expect TemplateMiddle or TemplateTail
			tok := snap_current(p)
			if tok.type == .TemplateMiddle {
				mid := TemplateElement{
					loc  = loc_from_token(&tok),
					tail = false,
					raw  = tok.value,
				}
				if cooked, ok := tok.literal.(string); ok {
					mid.cooked = cooked
				}
				bump_append(&tmpl.quasis, mid)
				eat(p)
				// Continue to parse next expression
			} else if tok.type == .TemplateTail {
				tail := TemplateElement{
					loc  = loc_from_token(&tok),
					tail = true,
					raw  = tok.value,
				}
				if cooked, ok := tok.literal.(string); ok {
					tail.cooked = cooked
				}
				bump_append(&tmpl.quasis, tail)
				eat(p)
				break
			} else {
				report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected template literal continuation")
				return nil
			}
		}

		tmpl.loc.end = prev_end_offset(p) + 1 // Include closing backtick
		p.prev_token_end = tmpl.loc.end // Update for parent nodes
		// §12.9.6 octal / \\8 / \\9 escape in untagged template (multi-quasi
		// shape): enforced by the semantic checker (ck_check_template_octal).
		if !tagged {
			for q in tmpl.quasis {
				if untagged_template_raw_has_invalid_escape(q.raw) {
					report_error_coded(p, .K1011_InvalidEscapeSequence, "Invalid escape sequence in template literal")
					break
				}
			}
		}
		return expression_from(p, tmpl)
	}

	report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected template literal")
	return nil
}

// expr_to_pattern converts an Expression that's actually been parsed as the
// destructuring-target side of an arrow parameter default into the matching
// Pattern variant. Covers the simple targets required by real-world code
// (Identifier, ObjectExpression→ObjectPattern, ArrayExpression→ArrayPattern);
// returns `false` for anything else so the caller can emit a clean error
// rather than silently accepting invalid input.
// walk_arrow_cover_for_yield_await — §15.3.1 ArrowParameters Contains
// check. The cover expression `(x = yield, y = await foo)` was parsed
// under the surrounding generator/async context, so YieldExpression /
// AwaitExpression nodes appear inside it. When committing to arrow
// params, the [Yield] / [Await] grammar parameters of the cover
// production reject these nodes:
//   * (x = yield) => {}        in generator    → SyntaxError
//   * async (x = await y) => {}                → SyntaxError
// `disallow_yield` / `disallow_await` reflect the surrounding context
// the COVER expression was parsed in. The walker only needs to recurse
// into shapes that can legally hold default-value expressions; it does
// not descend into nested function literals (those introduce their own
// scope where yield/await can be legitimately bound).
walk_arrow_cover_for_yield_await :: proc(p: ^Parser, expr: ^Expression, disallow_yield, disallow_await: bool) {
	if expr == nil { return }
	#partial switch e in expr^ {
	case ^YieldExpression:
		if disallow_yield {
			report_error_coded_span(p, .K3011_AwaitYieldExpressionContextRestricted,
				u32(e.loc.start), u32(e.loc.start),
				"'yield' is not allowed in arrow function parameters")
		}
	case ^AwaitExpression:
		if disallow_await {
			report_error_coded_span(p, .K3011_AwaitYieldExpressionContextRestricted,
				u32(e.loc.start), u32(e.loc.start),
				"'await' is not allowed in arrow function parameters")
		}
	case ^SequenceExpression:
		for inner in e.expressions {
			walk_arrow_cover_for_yield_await(p, inner, disallow_yield, disallow_await)
		}
	case ^AssignmentExpression:
		walk_arrow_cover_for_yield_await(p, e.left, disallow_yield, disallow_await)
		walk_arrow_cover_for_yield_await(p, e.right, disallow_yield, disallow_await)
	case ^ArrayExpression:
		for el in e.elements {
			inner, has := el.?
			if !has || inner == nil { continue }
			walk_arrow_cover_for_yield_await(p, inner, disallow_yield, disallow_await)
		}
	case ^ObjectExpression:
		for prop in e.properties {
			if prop.computed && prop.key != nil {
				walk_arrow_cover_for_yield_await(p, prop.key, disallow_yield, disallow_await)
			}
			walk_arrow_cover_for_yield_await(p, prop.value, disallow_yield, disallow_await)
		}
	case ^SpreadElement:
		walk_arrow_cover_for_yield_await(p, e.argument, disallow_yield, disallow_await)
	case ^BinaryExpression:
		walk_arrow_cover_for_yield_await(p, e.left, disallow_yield, disallow_await)
		walk_arrow_cover_for_yield_await(p, e.right, disallow_yield, disallow_await)
	case ^LogicalExpression:
		walk_arrow_cover_for_yield_await(p, e.left, disallow_yield, disallow_await)
		walk_arrow_cover_for_yield_await(p, e.right, disallow_yield, disallow_await)
	case ^UnaryExpression:
		walk_arrow_cover_for_yield_await(p, e.argument, disallow_yield, disallow_await)
	case ^UpdateExpression:
		walk_arrow_cover_for_yield_await(p, e.argument, disallow_yield, disallow_await)
	case ^ConditionalExpression:
		walk_arrow_cover_for_yield_await(p, e.test, disallow_yield, disallow_await)
		walk_arrow_cover_for_yield_await(p, e.consequent, disallow_yield, disallow_await)
		walk_arrow_cover_for_yield_await(p, e.alternate, disallow_yield, disallow_await)
	case ^CallExpression:
		walk_arrow_cover_for_yield_await(p, e.callee, disallow_yield, disallow_await)
		for arg in e.arguments { walk_arrow_cover_for_yield_await(p, arg, disallow_yield, disallow_await) }
	case ^MemberExpression:
		walk_arrow_cover_for_yield_await(p, e.object, disallow_yield, disallow_await)
	case ^TaggedTemplateExpression:
		walk_arrow_cover_for_yield_await(p, e.tag, disallow_yield, disallow_await)
	case ^TemplateLiteral:
		for expr_part in e.expressions { walk_arrow_cover_for_yield_await(p, expr_part, disallow_yield, disallow_await) }
	}
}

// Deep-conversion of object/array destructuring internals (e.g. nested
// `{a: {b}} = {}`) is handled by later parse passes - this helper only needs
// to produce the outer Pattern wrapper.
// clear_pending_offsets_in_span removes every offset in `list` that falls
// within [span_start, span_end). When an ObjectExpression is promoted to an
// ObjectPattern, pending CoverInitializedName / duplicate-__proto__
// diagnostics whose offsets land inside the object become legal in pattern
// context (§13.2.5.1 / §13.15.5.2 / Annex B.3.1), so they are swallowed in
// place. Compacts the slice without allocating.
clear_pending_offsets_in_span :: proc(list: ^[dynamic]u32, span_start: u32, span_end: u32) {
	if len(list) == 0 { return }
	write := 0
	for off in list {
		if off >= span_start && off < span_end {
			continue
		}
		list[write] = off
		write += 1
	}
	resize(list, write)
}

// expr_to_pattern_object_rest converts an object-spread element (`{...x}`)
// into a RestElement ObjectPatternProperty and appends it to `op`, enforcing
// the §13.15.5 rest-last / no-trailing-comma / no-binding-pattern rules and the
// TS rest-argument restrictions. Extracted from expr_to_pattern_object to keep
// that loop body under the 70-line limit (item 24).
expr_to_pattern_object_rest :: proc(p: ^Parser, op: ^ObjectPattern, e: ^ObjectExpression, spread: ^SpreadElement, idx, prop_count: int) {
	// §13.15.5 Object destructuring: BindingRestProperty must be the last
	// element of the ObjectBindingPattern. `for ({...rest, b} of ...)` is a
	// SyntaxError.
	if idx != prop_count - 1 {
		report_error_coded(p, .K3040_RestNotLast, "Rest element must be last in object pattern")
	} else if p.lexer != nil {
		src := p.lexer.source_bytes
		search_start := int(spread.loc.end)
		search_end := int(e.loc.end)
		if search_end > len(src) { search_end = len(src) }
		for k := search_start; k < search_end; k += 1 {
			c := src[k]
			if c == '}' { break }
			if c == ',' {
				report_error_coded(p, .K3041_RestForm, "Rest property may not have a trailing comma")
				break
			}
		}
	}
	if _, is_array := spread.argument.(^ArrayExpression); is_array {
		report_error_coded(p, .K3041_RestForm, "Rest property may not be a binding pattern")
	}
	if _, is_object := spread.argument.(^ObjectExpression); is_object {
		report_error_coded(p, .K3041_RestForm, "Rest property may not be a binding pattern")
	}
	// TS `as T` on a rest argument: `{ ...{} as T}` is invalid because the
	// inner expression `{}` is not a valid assignment target. But `{ ...a as
	// T}` is valid (unwraps to `a`). Only check when there IS a TS assertion
	// wrapping a literal.
	if spread.argument != nil {
		has_ts_wrap := false
		unwrapped := spread.argument
		if ae, is_as := unwrapped^.(^TSAsExpression); is_as {
			unwrapped = ae.expression; has_ts_wrap = true
		}
		if ta, is_ta := unwrapped^.(^TSTypeAssertion); is_ta {
			unwrapped = ta.expression; has_ts_wrap = true
		}
		if has_ts_wrap && unwrapped != nil {
			if _, is_obj := unwrapped^.(^ObjectExpression); is_obj {
				report_error_coded(p, .K3042_RestSpreadMisuse, "Invalid rest operator's argument")
			}
			if _, is_arr := unwrapped^.(^ArrayExpression); is_arr {
				report_error_coded(p, .K3042_RestSpreadMisuse, "Invalid rest operator's argument")
			}
		}
	}
	inner, inner_ok := expr_to_pattern(p, spread.argument)
	if inner_ok {
		rest := new_node(p, RestElement)
		rest.loc = spread.loc
		rest.argument = inner
		pp := ObjectPatternProperty{
			loc = spread.loc,
			key = nil,
			value = rest,
		}
		bump_append(&op.properties, pp)
	}
}

// expr_to_pattern_object_prop converts one non-spread ObjectExpression.Property
// into an ObjectPatternProperty (value -> AssignmentPattern / nested pattern,
// key -> ObjectPatternPropertyKey). Returns ok=false for a malformed shorthand
// whose value is nil so the caller skips it. Extracted from
// expr_to_pattern_object (item 24).
expr_to_pattern_object_prop :: proc(p: ^Parser, prop: Property) -> (ObjectPatternProperty, bool) {
	// Convert value:
	//   - AssignmentExpression (x = default) -> AssignmentPattern
	//   - anything else -> recurse via expr_to_pattern
	// Special case shorthand `{x}` where key == value == Identifier: the
	// parser may point both at the same node; either path converts
	// correctly below.
	// Nil-guard: a malformed shorthand like `{ p: void }` (where `void`
	// has no argument because the next token is `}`) leaves prop.value
	// nil. The type assertion `prop.value.(^AssignmentExpression)` auto-
	// derefs and segfaults on nil. Skip the property; the upstream parse
	// error already explains what went wrong.
	if prop.value == nil { return {}, false }
	value_pat: Pattern
	if ae, is_assign := prop.value.(^AssignmentExpression); is_assign && ae.operator == .Assign {
		lhs_pat, lhs_ok := expr_to_pattern(p, ae.left)
		if lhs_ok {
			asn := new_node(p, AssignmentPattern)
			asn.loc = ae.loc
			asn.left = lhs_pat
			asn.right = ae.right
			value_pat = asn
		}
	} else {
		inner, inner_ok := expr_to_pattern(p, prop.value)
		if inner_ok {
			value_pat = inner
		}
	}

	// Convert key: Property.key is ^Expression (Identifier / StringLiteral
	// / NumericLiteral / computed Expression). Map to
	// ObjectPatternPropertyKey (IdentifierName / ^StringLiteral /
	// ^Expression).
	pp_key: Maybe(ObjectPatternPropertyKey)
	if prop.computed {
		pp_key = prop.key
	} else if prop.key != nil {
		#partial switch k in prop.key^ {
		case ^Identifier:
			pp_key = IdentifierName{loc = k.loc, name = k.name}
		case ^StringLiteral:
			pp_key = k
		case:
			// Numeric / other literal keys: store as ^Expression via computed.
			pp_key = prop.key
		}
	}
	return ObjectPatternProperty{
		loc = prop.loc,
		key = pp_key,
		value = value_pat,
		computed = prop.computed,
		shorthand = prop.shorthand,
	}, true
}

expr_to_pattern_object :: proc(p: ^Parser, e: ^ObjectExpression) -> (Pattern, bool) {
	// Convert each ObjectExpression.Property into an ObjectPatternProperty.
	// Previously this dropped properties on the floor - emitting an empty
	// `ObjectPattern { properties: [] }` for every arrow-function param of
	// the form `({a, b: c = 1, ...rest}) => ...`. Symptom: every nested
	// default string / identifier inside destructured arrow params was
	// invisible to downstream walkers (framer-motion.js, swagger-ui.js).
	// Clear any pending CoverInitializedName offsets that fall inside
	// this object's span - once promoted to an ObjectPattern, the
	// `{foo = init}` shorthand is legal (§13.2.5.1 / §13.15.5.2).
	clear_pending_offsets_in_span(&p.pending_cover_inits, e.loc.start, e.loc.end)
	// Clear any pending duplicate-__proto__ offsets that fall inside
	// this object's span — once promoted to an ObjectPattern,
	// Annex B.3.1 makes duplicate __proto__ legal.
	clear_pending_offsets_in_span(&p.pending_proto_dups, e.loc.start, e.loc.end)
	op := new_node(p, ObjectPattern)
	op.loc = e.loc
	op.properties = make([dynamic]ObjectPatternProperty, 0, len(e.properties), p.allocator)
	prev_nested := p.ctx.in_nested_pattern_convert
	p.ctx.in_nested_pattern_convert = true
	defer p.ctx.in_nested_pattern_convert = prev_nested
	prop_count := len(e.properties)
	for prop, idx in e.properties {
		// Spread element in object expression -> RestElement in pattern.
		// Detected by nil key + SpreadElement value (parse_object_expression
		// stashes the SpreadElement in the value slot with key=nil).
		if prop.key == nil {
			if spread, ok := prop.value.(^SpreadElement); ok {
				expr_to_pattern_object_rest(p, op, e, spread, idx, prop_count)
			}
			continue
		}

		pp, ok := expr_to_pattern_object_prop(p, prop)
		if ok {
			bump_append(&op.properties, pp)
		}
	}
	return op, true
}

// expr_to_pattern_array_rest converts an array-spread element (`[...x]`) into a
// RestElement, enforcing the §14.3.3 rest-last / no-trailing-comma / no-default
// rules. Returns the RestElement and ok=true when the inner conversion
// succeeds. Extracted from expr_to_pattern_array to keep that loop body under
// the 70-line limit (item 24).
expr_to_pattern_array_rest :: proc(p: ^Parser, e: ^ArrayExpression, spread: ^SpreadElement, idx: int) -> (Pattern, bool) {
	if idx != len(e.elements) - 1 {
		report_error_coded(p, .K3040_RestNotLast, "Rest element must be last in array pattern")
	} else if p.lexer != nil {
		src := p.lexer.source_bytes
		search_start := int(spread.loc.end)
		search_end := int(e.loc.end)
		if search_end > len(src) { search_end = len(src) }
		for k := search_start; k < search_end; k += 1 {
			c := src[k]
			if c == ']' { break }
			if c == ',' {
				report_error_coded(p, .K3041_RestForm, "Rest element may not have a trailing comma")
				break
			}
		}
	}
	inner_expr := spread.argument
	// `[...x = init]` - AssignmentExpression whose LHS is the rest target. The
	// cover keeps it legal as an ArrayExpression / SpreadElement; reject at
	// pattern conversion.
	if ae, is_ae := inner_expr^.(^AssignmentExpression); is_ae && ae.operator == .Assign {
		report_error_coded(p, .K3041_RestForm, "Rest element cannot have a default initializer")
		inner_expr = ae.left
	}
	inner, ok := expr_to_pattern(p, inner_expr)
	if !ok { return nil, false }
	rest := new_node(p, RestElement)
	rest.loc = spread.loc
	rest.argument = inner
	return rest, true
}

expr_to_pattern_array :: proc(p: ^Parser, e: ^ArrayExpression) -> (Pattern, bool) {
	// Convert each ArrayExpression.element into an ArrayPattern element.
	// Same empty-pattern bug as ObjectExpression above.
	ap := new_node(p, ArrayPattern)
	ap.loc = e.loc
	elems := make([]Maybe(Pattern), len(e.elements), p.allocator)
	prev_nested := p.ctx.in_nested_pattern_convert
	p.ctx.in_nested_pattern_convert = true
	defer p.ctx.in_nested_pattern_convert = prev_nested
	for i := 0; i < len(e.elements); i += 1 {
		elem, has_elem := e.elements[i].(^Expression)
		if !has_elem || elem == nil {
			continue // sparse hole - leave as nil Maybe
		}
		// Spread element -> RestElement. Per §14.3.3:
		//   * BindingRestElement must be LAST in the list (no trailing
		//     elements allowed).
		//   * BindingRestElement does NOT accept an Initializer, unlike
		//     the other BindingElements.
		//   * No TRAILING comma after BindingRestElement. The cover path
		//     parses ArrayExpression which legally drops a trailing comma
		//     into nothing; re-detect by scanning the source between the
		//     spread's end and the array's end for a `,`.
		if spread, is_spread := elem^.(^SpreadElement); is_spread {
			if rest, ok := expr_to_pattern_array_rest(p, e, spread, i); ok {
				elems[i] = rest
			}
			continue
		}
		// AssignmentExpression -> AssignmentPattern.
		if ae, is_assign := elem^.(^AssignmentExpression); is_assign && ae.operator == .Assign {
			lhs_pat, lhs_ok := expr_to_pattern(p, ae.left)
			if lhs_ok {
				asn := new_node(p, AssignmentPattern)
				asn.loc = ae.loc
				asn.left = lhs_pat
				asn.right = ae.right
				elems[i] = asn
			}
			continue
		}
		if p_inner, ok := expr_to_pattern(p, elem); ok {
			elems[i] = p_inner
		}
	}
	ap.elements = elems
	return ap, true
}

expr_to_pattern :: proc(p: ^Parser, expr: ^Expression) -> (Pattern, bool) {
	if expr == nil { return nil, false }
	#partial switch e in expr^ {
	case ^Identifier:
		id_ptr := new_node(p, Identifier)
		id_ptr^ = e^
		// §15.3.1 / §12.6.1.1 — in strict mode, an arrow function
		// parameter BindingIdentifier may not be `eval`, `arguments`, or
		// any strict-mode reserved name. Fires when the cover expression
		// is being committed as an arrow parameter (this conversion is
		// also used for assignment patterns, but those are reported via
		// the assignment LHS path).
		if p.ctx.strict_mode {
			if is_eval_or_arguments(e.name) {
				msg := fmt.tprintf("Binding identifier '%s' not allowed in strict mode", e.name)
				report_error_coded_span(p, .K3050_StrictModeReserved, u32(e.loc.start), u32(e.loc.start), msg)
			} else if is_strict_reserved_binding_name(e.name) {
				msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", e.name)
				report_error_coded_span(p, .K3050_StrictModeReserved, u32(e.loc.start), u32(e.loc.start), msg)
			}
		}
		return id_ptr, true
	case ^ObjectExpression:
		return expr_to_pattern_object(p, e)
	case ^ArrayExpression:
		return expr_to_pattern_array(p, e)
	case ^MemberExpression:
		// ESTree allows MemberExpression as a destructure target.
		return e, true
	case ^ParenthesizedExpression:
		// Parenthesized binding element. OXC with preserveParens=false
		// (our oracle mode) strips paren wrappers, so `((a)) => 0` is
		// accepted (the inner `(a)` becomes plain `a`). But nested cases
		// like `([(a)]) => {}` or `({ a: (b) }) => {}` are still rejected
		// because the paren wraps a binding INSIDE a destructuring pattern.
		// Gate: reject when we're inside a recursive array/object pattern
		// conversion (in_nested_pattern_convert is set by the Array/Object
		// cases above). Top-level paren-around-identifier is OK.
		if e == nil { return nil, false }
		if p.ctx.in_nested_pattern_convert {
			report_error_coded(p, .K3066_InvalidAssignmentOrBindingTarget, "Binding element cannot be parenthesized")
		}
		return expr_to_pattern(p, e.expression)
	case ^TSNonNullExpression:
		// `x!` as a destructure target in TS mode - unwrap.
		if e == nil { return nil, false }
		return expr_to_pattern(p, e.expression)
	case ^TSAsExpression:
		if e == nil { return nil, false }
		return expr_to_pattern(p, e.expression)
	case ^TSSatisfiesExpression:
		if e == nil { return nil, false }
		return expr_to_pattern(p, e.expression)
	case ^TSTypeAssertion:
		if e == nil { return nil, false }
		return expr_to_pattern(p, e.expression)
	}
	// Everything else that reached here (Literal, SequenceExpression,
	// CallExpression, BinaryExpression, UnaryExpression, ...) is NOT a
	// legal AssignmentTarget per §12.6.2.3 / §13.15.5.2.
	report_error_coded(p, .K3043_DestructuringInvalid, "Invalid destructuring assignment target")
	return nil, false
}

// §15.3.1 / §15.9.1 "ArrowParameters Contains YieldExpression /
// CoverCallExpressionAndAsyncArrowHead Contains AwaitExpression" early
// errors are now enforced by the semantic checker (^YieldExpression /
// ^AwaitExpression cases in ck_walk_expr) using ctx.in_params /
// ctx.params_is_arrow. The bespoke retroactive cover-walk that used to
// live here (scan_arrow_cover_for_yield_await + scan_arrow_params_for_yield_only
// + arrow_cover_walk_pattern + arrow_cover_walk_expr) was deleted as
// the regular checker walk now visits arrow params
// (including nested ObjectPattern computed keys + AssignmentPattern
// defaults via ck_walk_pattern) under in_params=true, params_is_arrow=true.
// pattern_contains_member_expression is still needed by the arrow-param
// validity check at parse_arrow_function (a parameter pattern that
// destructures into a MemberExpression is not a valid binding pattern).
pattern_contains_member_expression :: proc(pat: Pattern) -> bool {
	if pat == nil { return false }
	switch pp in pat {
	case ^MemberExpression:
		return true
	case ^AssignmentPattern:
		return pattern_contains_member_expression(pp.left)
	case ^ObjectPattern:
		for prop in pp.properties {
			if pattern_contains_member_expression(prop.value) { return true }
		}
	case ^ArrayPattern:
		for elem in pp.elements {
			if inner, have := elem.(Pattern); have {
				if pattern_contains_member_expression(inner) { return true }
			}
		}
	case ^RestElement:
		return pattern_contains_member_expression(pp.argument)
	case ^Identifier:
		return false
	}
	return false
}

// check_parenthesized_binding detects inner `(...)` wrapping a binding
// element inside an arrow parameter list. Works by walking each pattern
// recursively: for every leaf Identifier, check if the byte before its
// span start (skipping whitespace) is `(` and the byte after its span
// end is `)`, and those parens are not the outer arrow parens.
check_parenthesized_binding :: proc(p: ^Parser, params: []FunctionParameter, src: []u8, outer_paren: int) {
	for param in params {
		check_pattern_parens(p, param.pattern, src, outer_paren)
		// Default values: `(x = (y)) =>` — the (y) is a grouping
		// paren in expression context, not a binding paren. Skip.
	}
}

check_pattern_parens :: proc(p: ^Parser, pat: Pattern, src: []u8, outer_paren: int) {
	if pat == nil { return }
	switch pp in pat {
	case ^Identifier:
		check_span_for_inner_parens(p, int(pp.loc.start), int(pp.loc.end), src, outer_paren)
	case ^AssignmentPattern:
		// `(a) = []` — check the LHS pattern.
		check_pattern_parens(p, pp.left, src, outer_paren)
	case ^ArrayPattern:
		for elem in pp.elements {
			if inner, have := elem.(Pattern); have {
				check_pattern_parens(p, inner, src, outer_paren)
			}
		}
	case ^ObjectPattern:
		for prop in pp.properties {
			check_pattern_parens(p, prop.value, src, outer_paren)
		}
	case ^RestElement:
		check_pattern_parens(p, pp.argument, src, outer_paren)
	case ^MemberExpression:
		// Skip — MemberExpression as target is caught elsewhere.
	}
}

check_span_for_inner_parens :: proc(p: ^Parser, span_start, span_end: int, src: []u8, outer_paren: int) {
	// Walk backwards from span_start to find `(`.
	i := span_start - 1
	for i >= 0 {
		c := src[i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' { i -= 1; continue }
		if c == '(' && i != outer_paren {
			// Found an inner `(`. Now check for matching `)` after span_end.
			j := span_end
			for j < len(src) {
				d := src[j]
				if d == ' ' || d == '\t' || d == '\n' || d == '\r' { j += 1; continue }
				if d == ')' {
					report_error_coded(p, .K3066_InvalidAssignmentOrBindingTarget, "Binding element cannot be parenthesized")
				}
				break
			}
		}
		break
	}
}

// arrow_try_conditional_return_type handles the TS arrow-in-conditional
// speculative parse: when an arrow concise body is followed by `:` inside
// a ternary consequent, the `:` may begin a return-type annotation rather
// than the ternary colon. Pattern: `cond ? v => (params) : RetType => body
// : alt`. Returns the (possibly replaced) body; on a failed speculation it
// restores the lexer and trims any speculative errors.
arrow_try_conditional_return_type :: proc(p: ^Parser, body: ArrowFunctionBody) -> ArrowFunctionBody {
	body := body
	if allow_ts_mode(p) && p.conditional_depth > 0 && is_token(p, .Colon) {
		snap := lexer_snapshot(p)
		snap_errs := len(p.errors)
		eat(p) // consume `:`
		ret_type := parse_ts_type(p)
		committed := false
		if ret_type != nil && is_token(p, .Arrow) {
			// Try: build inner arrow `(params): RetType => body`.
			body_expr, _ := body.(^Expression)
			p.pending_paren_start = loc_from_expr(body_expr).start
			inner_arrow := parse_arrow_function(p, body_expr)
			// Only commit if the inner arrow succeeded AND a ternary
			// `:` still follows. OXC accepts `x ? y => e : z => e`
			// as a valid ternary; Babel rejects it. We match OXC.
			if inner_arrow != nil && len(p.errors) == snap_errs &&
			   is_token(p, .Colon) {
				if ia, ok := inner_arrow^.(^ArrowFunctionExpression); ok {
					ann := new_node(p, TSTypeAnnotation)
					ann.type_annotation = ret_type
					ia.return_type = ann
				}
				body = inner_arrow
				committed = true
			}
		}
		if !committed {
			lexer_restore(p, snap)
			if len(p.errors) > snap_errs {
				resize(&p.errors, snap_errs)
			}
		}
	}
	return body
}

// arrow_seq_element_to_param converts one element of a parenthesised
// arrow parameter sequence `(a, b, ...rest) => body` into a
// FunctionParameter and appends it. The enclosing for-loop in
// parse_arrow_function owns iteration ("push ifs up, fors down"); this
// leaf owns the per-element Expression->Pattern conversion and the
// associated §15.3.1 strict-mode / rest-placement diagnostics. A bare
// `return` here is the loop `continue` from the original inline switch.
arrow_seq_element_to_param :: proc(p: ^Parser, expr_ptr: ^Expression, param_index: int, expr_count: int, params: ^[dynamic]FunctionParameter) {
	#partial switch arg in expr_ptr^ {
	case ^Identifier:
		// §15.3.1 strict-mode checks for multi-param arrow.
		if p.ctx.strict_mode {
			if is_eval_or_arguments(arg.name) {
				report_error_coded_span(p, .K3050_StrictModeReserved, u32(arg.loc.start), u32(arg.loc.start), fmt.tprintf("Arrow parameter '%s' is not allowed in strict mode", arg.name))
			} else if is_strict_reserved_binding_name(arg.name) {
				report_error_coded_span(p, .K3050_StrictModeReserved, u32(arg.loc.start), u32(arg.loc.start), fmt.tprintf("'%s' is a reserved identifier in strict mode", arg.name))
			}
		}
		param_ident := new_node(p, Identifier)
		param_ident^ = arg^
		param := FunctionParameter{
			loc     = arg.loc,
			pattern = param_ident,
		}
		bump_append(params, param)
	case ^SpreadElement:
		// Rest parameter: (a, b, ...rest) => ... (multi-param case).
		if param_index != expr_count - 1 {
			report_error_coded(p, .K3040_RestNotLast, "Rest parameter must be last in arrow function parameters")
		}
		// The SpreadElement was built during the earlier
		// parse_unary_expr pass over the paren-group; its span
		// ALREADY covers `...<ident>` exactly. By the time we get
		// here, the arrow body has also been parsed, so calling
		// prev_end_offset(p) returns the BODY'S end - which was
		// stamped onto rest.loc.end, blowing the RestElement's
		// span out to cover the entire function (observed on chalk.js
		// `(model, level, type, ...arguments_) => { ... }` where
		// params[3].end jumped 458 bytes past the argument name).
		// Reuse the SpreadElement's own span instead.
		rest := new_node(p, RestElement)
		rest.loc = arg.loc
		ident_expr := arg.argument
		if ident_expr != nil {
			// Rest element argument can be a BindingIdentifier OR a
			// nested BindingPattern (ObjectPattern / ArrayPattern) per
			// §15.2.1 / §15.3.1 - BindingRestElement[Yield, Await]:
			//   ... BindingIdentifier
			//   ... BindingPattern
			// Route through expr_to_pattern so destructuring rest
			// targets like `(...rest)`, `(...[a, b])`, `(...{x, y})`
			// are all carried through. Test262 language/expressions/
			// arrow-function/scope-param-rest-elem-var-open.js.
			if pat, ok := expr_to_pattern(p, ident_expr); ok {
				rest.argument = pat
			} else {
				report_error_coded(p, .K3042_RestSpreadMisuse, "Expected identifier or pattern in rest parameter")
			}
		}
		// arg.loc already spans `...<ident>` - keep it as-is.
		param := FunctionParameter{
			loc     = arg.loc,
			pattern = rest,
		}
		bump_append(params, param)
	case ^ObjectExpression:
		// Convert ObjectExpression -> ObjectPattern via expr_to_pattern
		// so nested properties, defaults, and rest elements are all
		// carried through. The old path allocated an empty pattern,
		// silently dropping every destructured field in multi-arrow
		// params like `(a, {x=1}, b) => ...`.
		if pat, ok := expr_to_pattern(p, expr_ptr); ok {
			param := FunctionParameter{ loc = arg.loc, pattern = pat }
			bump_append(params, param)
		}
	case ^ArrayExpression:
		// Same fix as ObjectExpression above. The prior inline loop
		// only understood bare Identifier elements, dropping any
		// nested AssignmentExpression / SpreadElement / Pattern.
		if pat, ok := expr_to_pattern(p, expr_ptr); ok {
			param := FunctionParameter{ loc = arg.loc, pattern = pat }
			bump_append(params, param)
		}
	case ^AssignmentExpression:
		// Default parameter: `(a = 1, b = 2) => ...`. The sequence
		// parser sees `a = 1` as an AssignmentExpression (operator `=`)
		// which we convert into an ESTree AssignmentPattern whose
		// `left` is the identifier/pattern and `right` is the default
		// value. Previously this fell through to the "Expected
		// identifier" error branch - breaking 34+ real-world files
		// (chalk.js, zod.js, vue.global.js, tinymce.js, etc.) which
		// use default params on arrow functions.
		if arg.operator != .Assign {
			report_error_coded(p, .K3043_DestructuringInvalid, "Arrow parameter default must use '=' operator")
				return
		}
		assign_pat := new_node(p, AssignmentPattern)
		assign_pat.loc = arg.loc
		assign_pat.right = arg.right
		// Left side: Identifier, ObjectPattern (from ObjectExpression),
		// or ArrayPattern (from ArrayExpression). Convert via the same
		// Expression→Pattern promotion the outer arms use.
		lhs_pat, lhs_ok := expr_to_pattern(p, arg.left)
		if !lhs_ok {
			report_error_coded(p, .K2040_UnexpectedToken, "Invalid target in arrow parameter default")
				return
		}
		assign_pat.left = lhs_pat
		param := FunctionParameter{
			loc     = arg.loc,
			pattern = assign_pat,
		}
		bump_append(params, param)
	case:
		report_error_coded(p, .K2021_ExpectedIdentifier, "Expected identifier in arrow function parameters")
	}
}

// parse_arrow_function_body parses an arrow function's body — either a
// `{ ... }` block FunctionBody or a concise expression body — and reports
// whether the block form was used (drives ArrowFunctionExpression.expression).
// The async / generator / static-block context must already be configured by
// the caller (parse_arrow_function). Extracted as pure code motion to keep
// parse_arrow_function within the per-function line budget.
parse_arrow_function_body :: proc(p: ^Parser) -> (body: ArrowFunctionBody, is_block_body: bool) {
	// Capture block-vs-expression BEFORE consuming either: afterwards the
	// current token is no longer the '{' and the ESTree `expression` flag
	// would otherwise always read false.
	is_block_body = is_token(p, .LBrace)
	if is_block_body {
		// Block body - need to set in_function for return statement validation
		prev_in_function := p.ctx.in_function
		p.ctx.in_function = true
		// break/continue/labels don't cross arrow function boundaries.
		prev_in_loop_arrow := p.ctx.in_loop
		prev_in_switch_arrow := p.ctx.in_switch
		prev_label_floor_arrow := p.ctx.label_floor
		p.ctx.in_loop = false
		p.ctx.in_switch = false
		p.ctx.label_floor = len(p.label_stack)
		// §15.3.1: arrow block body is a function-scope.
		p.scope_fn_scope_next_block = true
		block_stmt := parse_block_statement(p)
		// Arrow block bodies support "use strict" directive prologues.
		// Retroactively check for forbidden escapes in prologue strings.
		if block_stmt != nil {
			if bs, ok := block_stmt^.(^BlockStatement); ok && bs != nil {
				check_arrow_body_strict_prologue(p, bs.body[:])
			}
		}
		p.ctx.in_function = prev_in_function
		p.ctx.in_loop = prev_in_loop_arrow
		p.ctx.in_switch = prev_in_switch_arrow
		resize(&p.label_stack, p.ctx.label_floor)
		p.ctx.label_floor = prev_label_floor_arrow
		// §15.3.1: arrow `{ FunctionBody }` is a function-scope, not a block-scope.
		if block_stmt != nil {
			// parse_block_statement returns ^Statement wrapping ^BlockStatement.
			// `cast(^BlockStatement)^Statement` here is the same UB class as Bug H:
			// the Statement union's 16-byte header was being read as the start of
			// BlockStatement's fields, so `body.body` iteration yielded garbage
			// pointers (e.g. 0x14). Crash symptom: SIGSEGV in
			// `get_statement_type_name` when emitting class methods that contain
			// arrow functions with block bodies (tone.js and 11 others).
			// Fix: extract the inner ^BlockStatement via union type assertion.
			if bs, ok := block_stmt^.(^BlockStatement); ok {
				body = bs
			}
		}
	} else {
		#partial switch p.cur_type {
		case .Semi, .Comma, .RParen, .RBracket, .RBrace, .EOF:
			report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token")
		}
		// Expression body - also set in_function so nested `await` / `yield`
		// / `return` within the expression are recognised as being inside
		// this arrow, not at module top level. Previously only the block-body
		// branch above did this, so `async () => expr_with_await` marked the
		// file as a Module (via the top-level-await detector in
		// parse_unary_expr `.Await`) even though the `await` was properly
		// scoped to the async arrow.
		prev_in_function := p.ctx.in_function
		p.ctx.in_function = true
		body = parse_assignment_expression(p)
		p.ctx.in_function = prev_in_function
		// TS arrow-in-conditional: when the concise body is a parenthesised
		// expression inside a ternary consequent and `:` follows, the `:`
		// might be a return-type annotation (not the ternary colon).
		// Pattern: `cond ? v => (params) : RetType => body : alt`.
		// Speculatively try `(params) : Type => body` as a nested arrow.
		body = arrow_try_conditional_return_type(p, body)
	}
	return
}

arrow_build_params :: proc(p: ^Parser, left: ^Expression, saved_paren_start: u32) -> [dynamic]FunctionParameter {
	// Convert left to parameters
	params := make([dynamic]FunctionParameter, 0, 4, p.allocator)

	if left != nil {
		// §15.3.1 CoverParenthesizedExpressionAndArrowParameterList:
		// double-parenthesized params like `((a)) => 0` are invalid.
		// Detect: if the arrow's group-paren start is known AND the
		// first non-whitespace byte after it is another `(`, AND
		// `left` is a simple expression (Identifier), then extra
		// parens were used. This avoids false positives on arrow
		// bodies like `v => (sum = v)` where `last_paren_expr`
		// is set by a parenthesized body expression.
		if saved_paren_start != max(u32) && p.lexer != nil {
			src := p.lexer.source_bytes
			ps := int(saved_paren_start)
			if ps + 1 < len(src) {
				i := ps + 1
				for i < len(src) && (src[i] == ' ' || src[i] == '\t' || src[i] == '\n' || src[i] == '\r') { i += 1 }
				if i < len(src) && src[i] == '(' {
					// Verify the left is simple (Identifier / Assignment pattern only)
					is_simple_param := false
					#partial switch _ in left^ {
					case ^Identifier: is_simple_param = true
					case ^AssignmentExpression: is_simple_param = true
					}
					if is_simple_param {
						report_error_coded_span(p, .K3066_InvalidAssignmentOrBindingTarget, u32(u32(i)), u32(u32(i)), "Invalid parenthesized assignment pattern")
					}
				}
			}
		}

		#partial switch e in left {
		case ^Identifier:
			// §15.3.1 - ArrowParameters BindingIdentifier checks.
			if p.ctx.strict_mode {
				if is_eval_or_arguments(e.name) {
					report_error_coded(p, .K3050_StrictModeReserved, fmt.tprintf("Arrow parameter '%s' is not allowed in strict mode", e.name))
				} else if is_strict_reserved_binding_name(e.name) {
					report_error_coded(p, .K3050_StrictModeReserved, fmt.tprintf("'%s' is a reserved identifier in strict mode", e.name))
				}
			}
			if e.name == "enum" {
				report_error_coded(p, .K4054_EnumInvalid, "'enum' is a reserved identifier")
			}
			if e.name == "await" && (p.ctx.in_async || p.ctx.in_static_block) {
				report_error_coded(p, .K3010_AwaitYieldAsBindingName,
					"'await' cannot be used as an arrow parameter in module / async / static-block context")
			} else if e.name == "await" {
				if st, have := p.force_source_type.(SourceType); have && st == .Module {
					report_error_coded(p, .K3010_AwaitYieldAsBindingName,
						"'await' cannot be used as an arrow parameter in module / async / static-block context")
				}
			}
			if e.name == "yield" && (p.ctx.in_generator || p.ctx.strict_mode) {
				report_error_coded(p, .K3010_AwaitYieldAsBindingName,
					"'yield' cannot be used as an arrow parameter in generator / strict context")
			}
			ident := new_node(p, Identifier)
			ident^ = e^
			param := FunctionParameter{
				loc     = e.loc,
				pattern = ident,
			}
			bump_append(&params, param)
		case ^AssignmentExpression:
			// Single-param default: `(x = 1) => ...` arrives as AssignmentExpression
			// when the parens don't produce a SequenceExpression (only one arg).
			if e.operator == .Assign {
				assign_pat := new_node(p, AssignmentPattern)
				assign_pat.loc = e.loc
				assign_pat.right = e.right
				lhs_pat, lhs_ok := expr_to_pattern(p, e.left)
				if lhs_ok {
					assign_pat.left = lhs_pat
					param := FunctionParameter{ loc = e.loc, pattern = assign_pat }
					bump_append(&params, param)
				}
			} else {
				report_error_coded(p, .K3043_DestructuringInvalid, "Arrow parameter default must use '=' operator")
			}
		case ^ObjectExpression:
			// Single destructure param: `({a, b}) => ...`. Route through
			// expr_to_pattern so the properties are carried across; previously
			// this allocated an empty ObjectPattern, silently dropping every
			// destructured binding (and every nested default value with it).
			if pat, ok := expr_to_pattern(p, left); ok {
				param := FunctionParameter{ loc = e.loc, pattern = pat }
				bump_append(&params, param)
			}
		case ^ArrayExpression:
			// Single destructure param: `([a, b]) => ...` - same fix as
			// ObjectExpression above.
			if pat, ok := expr_to_pattern(p, left); ok {
				param := FunctionParameter{ loc = e.loc, pattern = pat }
				bump_append(&params, param)
			}
		case ^SpreadElement:
			// Single rest parameter arrow: `(...rest) => body`. The paren
			// group parser handled `...strings` via parse_unary_expr, which
			// produced a ^SpreadElement wrapping the identifier. That slot was
			// previously uncovered in the single-param switch - the arrow was
			// built with `params: []`, silently dropping the rest binding
			// (observed on chalk.js `const chalk = (...strings) => ...` and
			// similar shapes across multiple frameworks). Promote the inner
			// argument to an Identifier pattern and wrap in a RestElement so
			// the emitter sees the ESTree-standard `{ type: "RestElement",
			// argument: Identifier }` shape.
			// §15.3 ArrowParameters - a top-level rest must be wrapped in
			// parens (`(...x) => x`). Bare `...x => x` is a SyntaxError
			// because `...x` isn't a legal expression on its own. Detect via
			// the byte preceding the SpreadElement.
			paren_wrapped_spread := false
			if p.lexer != nil {
				i := int(e.loc.start) - 1
				for i >= 0 {
					ch := p.lexer.source_bytes[i]
					if ch == '(' { paren_wrapped_spread = true; break }
					if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { i -= 1; continue }
					break
				}
			}
			if !paren_wrapped_spread {
				report_error_coded(p, .K3042_RestSpreadMisuse, "Rest parameter must be wrapped in parentheses")
			}
			inner := e.argument
			if inner != nil {
				inner_pat, ok := expr_to_pattern(p, inner)
				if ok {
					rest := new_node(p, RestElement)
					rest.loc = e.loc
					rest.argument = inner_pat
					param := FunctionParameter{ loc = e.loc, pattern = rest }
					bump_append(&params, param)
				} else {
					report_error_coded(p, .K3042_RestSpreadMisuse, "Invalid rest parameter target in arrow function")
				}
			}
		case ^SequenceExpression:
			if len(e.expressions) == 0 {
				// Empty parameters: () => ... (marker from parse_primary_expr)
				// params stays empty
			} else {
				// Multiple parameters: (a, b) => ...
				// Each element in the sequence should be an identifier (or pattern)
				for expr_ptr, param_index in e.expressions {
					// Nil entries arise during error recovery when a cover-expression
					// element fails to parse. Concrete shape: `([]?, {}) => {}` parses
					// `[]?` as ConditionalExpression whose consequent is missing
					// (next token is `,`, not an expression start), so parse_conditional_
					// expr returns nil and the sequence captures a nil pointer for that
					// slot. Without this guard, `expr_ptr^` segfaults.
					if expr_ptr == nil { continue }
					arrow_seq_element_to_param(p, expr_ptr, param_index, len(e.expressions), &params)
				}
			}
		}
	}
	// Post-switch: handle unrecognized param expressions (e.g. CallExpression).
	// These arise when e.g. a LT between `async` and `(params)` prevented
	// async-arrow detection so `async(foo)` became a CallExpression.
	if left != nil {
		#partial switch _ in left {
		case ^Identifier, ^AssignmentExpression, ^ObjectExpression,
		     ^ArrayExpression, ^SpreadElement, ^SequenceExpression:
			// These are valid arrow param forms, handled by the switch above.
		case:
			report_error_coded(p, .K3066_InvalidAssignmentOrBindingTarget, "Invalid expression for arrow function parameters")
		}
	}
	return params
}

parse_arrow_function :: proc(p: ^Parser, left: ^Expression, is_async := false) -> ^Expression {

	// §15.3.1 — ArrowParameters Contains check. The cover expression
	// was parsed under the surrounding generator/async context, so a
	// `yield` / `await` produced a real YieldExpression / AwaitExpression
	// instead of an identifier. When committing to arrow params, those
	// nodes are SyntaxErrors per the [Yield] / [Await] grammar params on
	// CoverParenthesizedExpressionAndArrowParameterList.
	if left != nil && (p.ctx.in_generator || p.ctx.in_async || is_async) {
		walk_arrow_cover_for_yield_await(p, left, p.ctx.in_generator, p.ctx.in_async || is_async)
	}
	start: Loc
	if left != nil {
		start = loc_from_expr(left)
		// If a `(` was opened immediately before this expression, use its
		// position as the arrow's start - matches ESTree/OXC/Acorn span
		// semantics (`(x, y) => ...` spans the entire parenthesised form).
		// A stamp of 0 means no paren was seen (bare identifier arrow
		// `x => ...`); in that case keep the identifier's own start.
		// Check if this is empty params - if so, don't adjust based on outer paren
		is_empty_params_local := false
		if seq, ok := left^.(^SequenceExpression); ok && len(seq.expressions) == 0 {
			is_empty_params_local = true
		}
		if !is_empty_params_local && p.pending_paren_start != max(u32) && p.pending_paren_start <= start.start {
			start.start = p.pending_paren_start
		}
	} else {
		start = cur_loc(p)
	}
	// Save for double-paren detection before clearing.
	saved_paren_start := p.pending_paren_start
	// For empty params, don't clear pending_paren_start yet - let CallExpression use it
	is_empty_params := false
	if left != nil {
		if seq, ok := left^.(^SequenceExpression); ok && len(seq.expressions) == 0 {
			is_empty_params = true
		}
	}
	if !is_empty_params {
		p.pending_paren_start = max(u32)
	}

	// left should be parameters (identifier or parenthesized expression)
	// nil left means empty params: () => ...
	eat(p) // consume =>

	// §15.3.1 Contains check is enforced by the semantic checker on the
	// finished AST: ck_walk_expr's ^ArrowFunctionExpression case sets
	// in_params=true, params_is_arrow=true around the params walk, and
	// ck_walk_pattern + the YieldExpression / AwaitExpression cases
	// emit the diagnostic. No retroactive cover-walk needed here.

	// Set async context for body parsing
	prev_async := p.ctx.in_async
	if is_async {
		p.ctx.in_async = true
	}
	// §15.3.4: ArrowFunction ConciseBody is parsed with [~Yield, ~Await]
	// (unless the arrow itself is async, in which case [~Yield, +Await]).
	// Arrow functions don't have their own [[Generator]] status, so
	// `yield` inside a non-generator arrow in a generator function is
	// just an identifier, not a YieldExpression. Reset `in_generator`
	// so the expression parser treats `yield` as an identifier.
	prev_in_generator := p.ctx.in_generator
	p.ctx.in_generator = false
	// Static block context does NOT propagate into arrow function bodies.
	prev_static_block_arrow := p.ctx.in_static_block
	p.ctx.in_static_block = false
	defer p.ctx.in_static_block = prev_static_block_arrow
	// Parse the body (block or concise-expression form) under the context
	// configured above.
	body, is_block_body := parse_arrow_function_body(p)

	p.ctx.in_async = prev_async
	p.ctx.in_generator = prev_in_generator

	// Convert left to parameters (nil left ⇒ empty params, empty-paren case).
	params := arrow_build_params(p, left, saved_paren_start)
	// if left is nil, params stays empty (empty parentheses case)

	// §15.2.1.1 — params vs body lex check for arrow functions.
	if bs, is_block := body.(^BlockStatement); is_block && bs != nil {
  if !p.ast_only {
		check_params_vs_body_lex(p, params[:], bs.body[:])
  }
	}

	arrow := new_node(p, ArrowFunctionExpression)
	arrow.loc = start
	arrow.params = params
	arrow.body = body
	arrow.expression = !is_block_body
	arrow.async = false
	arrow.loc.end = prev_end_offset(p)

	for param in params {
		if pattern_contains_member_expression(param.pattern) {
			report_error_coded(p, .K3066_InvalidAssignmentOrBindingTarget, "Member expression cannot be used as a binding target")
		}
	}

	parser_check_dup_params(p, params[:], start.start, p.ctx.strict_mode, true)

	// §15.3.1 — ContainsUseStrict + !IsSimpleParameterList for arrow
	// functions. Arrow concise (expression) bodies cannot contain a
	// directive, so only block bodies need the check. parse_block_statement
	// does NOT promote leading string-literal statements to a directive
	// prologue (only parse_function_body / parse_program do), so we sniff
	// body[0]'s ExpressionStatement.expression as a StringLiteral with
	// value == "use strict" — mirrors the checker's old
	// ck_check_arrow_strict_directive_with_nonsimple_params shape.
	if is_block_body {
		if arrow_body_lifts_strict(body) {
			if !params_are_simple(params[:]) {
				report_error_coded_span(p, .K3052_UseStrictWithComplexParams, u32(start.start), u32(start.start), "Illegal 'use strict' directive in function with non-simple parameter list")
			}
			// §13.1.1 — retroactive strict-mode binding check on
			// arrow params when the body promotes to strict and the
			// outer scope was NOT strict (the params were parsed in
			// sloppy mode). Catches `eval => {"use strict"}` etc.
			if !p.ctx.strict_mode {
				report_strict_param_pattern_retro(p, params[:])
			}
		}
	}

	// §14.1.2 - CoverParenthesizedExpressionAndArrowFormalParameters.
	// Parenthesized binding elements in arrow params (`(a, (b)) => 42`,
	// `([(a)]) => {}`, etc.) are rejected by both V8 and OXC.
	// Exception: `((a)) => 0` — OXC with preserveParens=false strips
	// the inner parens so a single-identifier param works. Skip the
	// byte-level paren check only when the param list is a single
	// plain identifier (the paren is just extra grouping).
	is_single_ident_param := len(params) == 1
	if is_single_ident_param {
		if _, ok := params[0].pattern.(^Identifier); !ok {
			is_single_ident_param = false
		}
	}
	if !is_single_ident_param && p.lexer != nil && len(params) > 0 {
		src := p.lexer.source_bytes
		outer_paren := int(start.start)
		check_parenthesized_binding(p, params[:], src, outer_paren)
	}

	// ArrowFunction params are always UniqueFormalParameters
	// (ECMA-262 §15.3.1). No sloppy-mode escape hatch - pass
	// strict_override=true so the duplicate-check fires even when the
	// outer function isn't strict.

	// §15.3.1 / §15.9.1 "ContainsUseStrict + !IsSimpleParameterList"
	// early error: enforced by the semantic checker
	// (ck_check_arrow_strict_directive_with_nonsimple_params).
	if is_block_body {
		// §15.3.1 / §15.9.1 - BoundNames(FormalParameters) ∩
		// LexicallyDeclaredNames(ArrowConciseBody) must be empty.
		// `(bar) => { let bar; }` and `async(bar) => { let bar; }`
		// are SyntaxErrors. Test262 language/expressions/{,async-}
		// arrow-function/early-errors-arrow-formals-body-duplicate.js.
	}

	return expression_from(p, arrow)
}

parse_conditional_expr :: proc(p: ^Parser, test: ^Expression) -> ^Expression {
	start := loc_from_expr(test)
	eat(p) // consume ?

	// §13.14 ConditionalExpression: the consequent branch (`? expr`) gets
	// [+In] regardless of the enclosing [?In] context. This allows
	// `for (true ? '' in obj : alt; ...)` where `in` inside the true
	// branch is a relational operator, not a for-in separator.
	prev_no_in := p.ctx.no_in
	p.ctx.no_in = false
	// Track that we're inside a ternary consequent so that
	// looks_like_ts_arrow_params suppresses the aggressive
	// byte-scan that can mistake the ternary `:` for a TS
	// arrow return-type annotation.
	p.conditional_depth += 1
	consequent := parse_assignment_expression(p)
	p.conditional_depth -= 1
	p.ctx.no_in = prev_no_in
	if consequent == nil {
		report_error_coded(p, .K2020_ExpectedExpression, "Expected expression after '?' in conditional expression")
		return nil
	}

	// TS arrow-in-conditional: `cond ? (params): RetType => body : alt`.
	// The `:` that the conditional expects may actually be a return-type
	// annotation on an arrow in the consequent position. Speculatively
	// try `(consequent): Type => body`; commit only if a ternary `:`
	// still follows. Only attempt when the consequent could plausibly be
	// arrow parameters (parenthesised expression, identifier, etc.).
	conseq_could_be_arrow := false
	if consequent != nil {
		#partial switch _ in consequent {
		case ^Identifier, ^AssignmentExpression, ^SequenceExpression,
		     ^ObjectExpression, ^ArrayExpression: conseq_could_be_arrow = true
		case: // ConditionalExpression, Literal, etc. - never arrow params
		}
	}
	if allow_ts_mode(p) && is_token(p, .Colon) && conseq_could_be_arrow {
		snap := lexer_snapshot(p)
		snap_errs := len(p.errors)
		eat(p) // consume `:`
		ret_type := parse_ts_type(p)
		committed := false
		if ret_type != nil && is_token(p, .Arrow) {
			p.pending_paren_start = start.start
			inner := parse_arrow_function(p, consequent)
			if inner != nil && len(p.errors) == snap_errs && is_token(p, .Colon) {
				if ia, ok := inner^.(^ArrowFunctionExpression); ok {
					ann := new_node(p, TSTypeAnnotation)
					ann.type_annotation = ret_type
					ia.return_type = ann
				}
				consequent = inner
				committed = true
			}
		}
		if !committed {
			lexer_restore(p, snap)
			if len(p.errors) > snap_errs { resize(&p.errors, snap_errs) }
		}
	}

	if !expect_token(p, .Colon) {
		return nil
	}

	alternate := parse_assignment_expression(p)
	if alternate == nil {
		report_error_coded(p, .K2020_ExpectedExpression, "Expected expression after ':' in conditional expression")
		return nil
	}

	cond, cond_e := new_expr(p, ConditionalExpression)
	cond.loc = start
	cond.test = test
	cond.consequent = consequent
	cond.alternate = alternate
	cond.loc.end = prev_end_offset(p)

	return cond_e
}

// is_valid_assignment_target returns true if `left` is a legal LHS for an
// AssignmentExpression. Per ECMA-262 §13.15:
//   * SimpleAssignmentTarget: Identifier / MemberExpression /
//     CallExpression-with-valid-target (rare) / TSNonNullExpression (x!)
//     / ParenthesizedExpression whose inner is also a valid target.
//   * AssignmentPattern (for `=`): ArrayExpression / ObjectExpression that
//     can be reinterpreted as a destructuring pattern.
// Other expressions (BinaryExpression, UnaryExpression, literals, etc.)
// are SyntaxErrors in assignment position (`1 + 2 = 3`, `-x = 5`, etc.).
// Returns true if `left` is an Array / Object literal (or paren-wrapper
// thereof) - the only shapes that legitimately need expr_to_pattern
// conversion on an AssignmentExpression. Plain Identifier / Member /
// Call (Annex B.3.4 sloppy) / TS-escape-hatch targets go through
// is_valid_assignment_target directly and skip the pattern walker.
is_destructure_target_candidate :: proc(expr: ^Expression) -> bool {
	if expr == nil { return false }
	#partial switch e in expr^ {
	case ^ArrayExpression, ^ObjectExpression:
		return true
	case ^ParenthesizedExpression:
		return e != nil && is_destructure_target_candidate(e.expression)
	}
	return false
}

// Returns true when `expr` is a CallExpression (possibly wrapped in
// ParenthesizedExpression / TS escape-hatches) - used by the strict-mode
// gate in parse_assignment_expr because Annex B.3.4 only allows
// `f() = x` in sloppy script.
is_call_expression_target :: proc(expr: ^Expression) -> bool {
	if expr == nil { return false }
	#partial switch e in expr^ {
	case ^CallExpression:
		return true
	case ^ParenthesizedExpression:
		return e != nil && is_call_expression_target(e.expression)
	case ^TSNonNullExpression, ^TSAsExpression, ^TSSatisfiesExpression, ^TSTypeAssertion:
		// TS escape hatches re-export AssignmentTargetType of their
		// expression - unwrap and recurse.
		#partial switch v in expr^ {
		case ^TSNonNullExpression:
			return v != nil && is_call_expression_target(v.expression)
		case ^TSAsExpression:
			return v != nil && is_call_expression_target(v.expression)
		case ^TSSatisfiesExpression:
			return v != nil && is_call_expression_target(v.expression)
		case ^TSTypeAssertion:
			return v != nil && is_call_expression_target(v.expression)
		}
	}
	return false
}

is_valid_assignment_target :: proc(expr: ^Expression, is_destructure: bool) -> bool {
	if expr == nil { return false }
	#partial switch e in expr^ {
	case ^Identifier, ^MemberExpression:
		return true
	case ^TSNonNullExpression:
		return is_valid_assignment_target(e.expression, is_destructure)
	case ^TSAsExpression:
		return is_valid_assignment_target(e.expression, is_destructure)
	case ^TSSatisfiesExpression:
		return is_valid_assignment_target(e.expression, is_destructure)
	case ^TSTypeAssertion:
		return is_valid_assignment_target(e.expression, is_destructure)
	case ^CallExpression:
		return false
	case ^ParenthesizedExpression:
		return is_valid_assignment_target(e.expression, is_destructure)
	case ^ArrayExpression, ^ObjectExpression:
		// Only valid as destructuring targets (operator must be `=`).
		return is_destructure
	}
	return false
}

// is_unparenthesized_ts_cast checks if an expression is a bare (unparenthesized)
// TS type assertion (as, satisfies, angle-bracket). Used to reject
// `foo as any = 10` while allowing `(foo as any) = 10`.
is_unparenthesized_ts_cast :: proc(expr: ^Expression) -> bool {
	if expr == nil { return false }
	#partial switch _ in expr^ {
	case ^TSAsExpression, ^TSSatisfiesExpression, ^TSTypeAssertion:
		return true
	}
	return false
}

// validate_destructure_target walks an assignment LHS that's being
// converted to a pattern. Inside array/object literals, parenthesized
// AssignmentExpressions and parenthesized non-Member expressions are
// invalid pattern elements. e.g. `[(a = 1)] = t` and `[([x])] = t`
// are rejected by OXC.
validate_destructure_target :: proc(p: ^Parser, expr: ^Expression) {
	if expr == nil { return }
	#partial switch e in expr^ {
	case ^ArrayExpression:
		if e == nil { return }
		for elem in e.elements {
			if inner, ok := elem.(^Expression); ok && inner != nil {
				validate_pattern_element(p, inner)
			}
		}
	case ^ObjectExpression:
		if e == nil { return }
		for prop in e.properties {
			if prop.value != nil {
				validate_pattern_element(p, prop.value)
			}
		}
	case ^ParenthesizedExpression:
		if e != nil { validate_destructure_target(p, e.expression) }
	}
}

validate_pattern_element :: proc(p: ^Parser, expr: ^Expression) {
	if expr == nil { return }

	// Without --preserve-parens, check pending_paren_patterns for this
	// element's start offset. If found, it was parenthesized and non-simple.
	if !p.preserve_parens && len(p.pending_paren_patterns) > 0 {
		expr_start := loc_from_expr(expr).start
		for off in p.pending_paren_patterns {
			if off == expr_start {
				report_error_coded_span(p, .K3066_InvalidAssignmentOrBindingTarget, u32(off), u32(off), "Invalid parenthesized assignment pattern")
				return
			}
		}
	}

	#partial switch e in expr^ {
	case ^ParenthesizedExpression:
		if e == nil { return }
		// Parenthesized non-Member expressions can't be pattern elements.
		inner := e.expression
		if inner != nil {
			#partial switch _ in inner^ {
			case ^Identifier, ^MemberExpression, ^TSNonNullExpression,
			     ^TSAsExpression, ^TSSatisfiesExpression, ^TSTypeAssertion:
				// These remain valid even when parenthesized at the pattern level.
			case:
				report_error_coded_span(p, .K3066_InvalidAssignmentOrBindingTarget, u32(e.loc.start), u32(e.loc.start), "Invalid parenthesized assignment pattern")
			}
		}
	case ^AssignmentExpression:
		if e == nil { return }
		// Default-value assignment in pattern: `[a = 1]`. Recurse into LHS.
		if e.operator == .Assign {
			validate_pattern_element(p, e.left)
		}
	case ^ArrayExpression, ^ObjectExpression:
		validate_destructure_target(p, expr)
	case ^SpreadElement:
		if e != nil { validate_pattern_element(p, e.argument) }
	}
}

// is_simple_assignment_target returns true if `expr` has the spec's
// SIMPLE AssignmentTargetType per §12.6.2.3 - i.e. it's a legal operand
// for UpdateExpression (`++` / `--`) and for `delete` in strict mode.
// Narrower than is_valid_assignment_target: ImportCall /
// ArrayExpression-as-destructure / ObjectExpression-as-destructure are
// all INVALID here. Paren-wrapped simple targets stay simple.
// sloppy_legacy_call: Annex B.3.4 extends AssignmentTargetType of
// CallExpression to SIMPLE in sloppy (non-strict) mode. Passing true
// lets `f()++` through in sloppy mode; strict-mode callers must pass
// false so the early error fires.
is_simple_assignment_target :: proc(expr: ^Expression, sloppy_legacy_call: bool) -> bool {
	if expr == nil { return false }
	#partial switch e in expr^ {
	case ^Identifier, ^MemberExpression,
	     ^TSNonNullExpression, ^TSAsExpression, ^TSSatisfiesExpression,
	     ^TSTypeAssertion:
		return true
	case ^CallExpression:
		return sloppy_legacy_call
	case ^ParenthesizedExpression:
		return is_simple_assignment_target(e.expression, sloppy_legacy_call)
	}
	return false
}

parse_assignment_expr :: proc(p: ^Parser, left: ^Expression) -> ^Expression {
	start := loc_from_expr(left)

	current := snap_current(p)
	op := token_to_assignment_op(current.type)

	// §12.10 / §13.15 ParenthesizedExpression AssignmentTargetType:
	// AssignmentTargetType of `(Expr)` = AssignmentTargetType of `Expr`.
	// ObjectLiteral / ArrayLiteral / ArrowFunction / AsyncArrowFunction
	// have AssignmentTargetType=invalid, so they're invalid as LHS even
	// though the same shape WITHOUT the parens converts to a valid
	// ObjectAssignmentPattern / ArrayAssignmentPattern. The pointer
	// equality check distinguishes `({}) = 1` (paren-wrapped, error)
	// from `{} = 1` (Pattern conversion, OK at expression position
	// like `({} = {a:1})`) and from `({}.x) = 1` (LHS-tail extended
	// to MemberExpression, OK).
	if left == p.last_paren_expr && left != nil {
		paren_invalid := false
		#partial switch _ in left^ {
		case ^ObjectExpression, ^ArrayExpression, ^ArrowFunctionExpression,
		     ^AssignmentExpression, ^SequenceExpression:
			paren_invalid = true
		}
		if paren_invalid {
			report_error_coded(p, .K3066_InvalidAssignmentOrBindingTarget, "Invalid left-hand side in assignment")
		}
	}
	// TS cast expressions are not valid as direct (unparenthesized) assignment
	// targets: `foo as any = 10` is invalid, but `(foo as any) = 10` is valid.
	// Use `last_paren_expr` to distinguish: if `left == last_paren_expr`,
	// the expression was wrapped in parens and is OK.
	if left != nil && left != p.last_paren_expr && is_unparenthesized_ts_cast(left) {
		report_error_coded(p, .K2050_InvalidLHS, "Invalid left-hand side in assignment expression.")
	}
	// General assignment-target validation. `(foo() as T) = 1` etc.
	// is_destructure=true allows `[a, b] = c` / `({a} = c)`; the
	// destructure-conversion path only kicks in for `=` operator.
	is_destructure := op == .Assign
	if left != nil && !is_valid_assignment_target(left, is_destructure) {
		report_error_coded(p, .K3066_InvalidAssignmentOrBindingTarget, "Cannot assign to this expression")
	}
	// Walk destructuring patterns to reject parenthesized non-targets
	// inside array/object pattern elements.
	if left != nil && is_destructure {
		validate_destructure_target(p, left)
	}
	// Clear the marker so it doesn't bleed into the RHS or the next
	// AssignmentExpression (e.g. `(a) = (b) = c` - the second `(b)`
	// re-stamps it before the second `=` runs).
	p.last_paren_expr = nil

	eat(p)

	right := parse_expr_with_prec(p, .Assignment)
	if right == nil {
		return nil
	}

	// Validate pattern conversion for = operator (destructuring assignment).
	// Only fire expr_to_pattern when the LHS is actually a destructure
	// candidate (Array / Object literal, or a paren-wrapped version);
	// otherwise CallExpression (§Annex B.3.4 `f() = x` in sloppy) and
	// TS-escape-hatch wrappers would trigger the "Invalid destructuring
	// assignment target" error added to expr_to_pattern's default arm.
	if op == .Assign && is_destructure_target_candidate(left) {
		_, _ = expr_to_pattern(p, left)
	}

	// LHS validity per §13.15. Only runs AFTER right is parsed so error
	// recovery keeps the full assignment tree structurally intact for
	// downstream consumers (emit, walker).
	if !is_valid_assignment_target(left, op == .Assign) {
		// ArrayExpression / ObjectExpression with compound operators
		// (+=, -=, etc.) are semantic errors, not structural ones -
		// OXC defers the check. All other invalid LHS patterns (e.g.
		// BinaryExpression `1 + 2 = 3`) are structural parse errors.
		is_semantic := false
		if op != .Assign && left != nil {
			#partial switch _ in left^ {
			case ^ArrayExpression, ^ObjectExpression:
				is_semantic = true
			case: // fall through
			}
		}
		if is_semantic {
			// §13.15.1 "Invalid LHS in destructured compound assignment":
			// enforced by the semantic checker (ck_check_assignment_invalid_lhs).
		} else {
			report_error_coded(p, .K3066_InvalidAssignmentOrBindingTarget, "Invalid left-hand side in assignment")
		}
	}
	// §13.15.1 - logical assignment operators (&&=, ||=, ??=) require a
	// SIMPLE assignment target. CallExpressions are NOT simple targets even
	// in sloppy mode for these operators (unlike plain `=` which has Annex
	// B.3.4 legacy relaxation for `f() = x`).
	is_logical_assign := op == .AssignLogicalAnd || op == .AssignLogicalOr || op == .AssignNullish
	if is_logical_assign && is_call_expression_target(left) {
		report_error_coded(p, .K2050_InvalidLHS, "Invalid left-hand side in assignment expression")
	}

	// ECMA-262 §13.15.1 — in strict mode it's a SyntaxError for the LHS
	// of an AssignmentExpression to be an IdentifierReference whose name
	// is `eval` or `arguments`. Applies at every target position inside a
	// destructuring pattern too: `[eval] = []`, `({x: arguments} = {})`,
	// and `[...eval] = []` are all SyntaxErrors. Promoted from the
	// semantic checker (ck_check_strict_eval_arguments_in_target).
	if p.ctx.strict_mode {
		report_strict_eval_arguments_in_target(p, left)
	}

	assign, assign_e := new_expr(p, AssignmentExpression)
	assign.loc = start
	assign.operator = op
	assign.left = left
	assign.right = right
	assign.loc.end = prev_end_offset(p)

	return assign_e
}

parse_identifier :: proc(p: ^Parser) -> Identifier {
	// Read loc / name from the lexer BEFORE eat advances. Saves the
	// 64 B Token snapshot copy that `current := snap_current(p)` was
	// doing once per identifier-name (called from member access, import
	// /export specifiers, JSX attribute names, dynamic imports, optional
	// chains, ~13 sites total). The string slice in cur_value(p)
	// points into the source bytes, which outlive eat(p).
	loc := cur_loc(p)
	name := cur_value(p)
	eat(p)
	return Identifier{loc = loc, name = name}
}

parse_identifier_name :: proc(p: ^Parser) -> Identifier {
	return parse_identifier(p)
}

parse_string_literal :: proc(p: ^Parser) -> StringLiteral {
	// Same shape as parse_identifier above: snapshot only the fields
	// we need before eat(p), avoiding the 64 B Token copy.
	loc := cur_loc(p)
	raw := cur_value(p)
	value := cur_literal(p).(string) or_else ""

	// §12.9.4.1 — in strict mode, numeric escape sequences other than
	// `\0` (not followed by a digit) are forbidden in string literals.
	// Check the raw token text for `\1`-`\9` or `\0[0-9]`.
	if p.ctx.strict_mode && len(raw) > 2 {
		check_strict_string_escapes(p, raw, loc.start)
	}

	eat(p)
	return StringLiteral{loc = loc, raw = raw, value = value}
}

// check_strict_string_escapes scans a raw string token for octal or \8/\9
// escape sequences that are illegal in strict mode.
check_strict_string_escapes :: proc(p: ^Parser, raw: string, offset: u32) {
	i := 1 // skip opening quote
	for i < len(raw) - 1 {
		if raw[i] == '\\' && i + 1 < len(raw) - 1 {
			next := raw[i + 1]
			if next >= '1' && next <= '9' {
				report_error_coded_span(p, .K3051_StrictModeProhibited, u32(offset + u32(i)), u32(offset + u32(i)), "Octal or \\8 / \\9 escape sequences are not allowed in strict mode")
				return
			}
			if next == '0' && i + 2 < len(raw) - 1 && raw[i + 2] >= '0' && raw[i + 2] <= '9' {
				report_error_coded_span(p, .K3051_StrictModeProhibited, u32(offset + u32(i)), u32(offset + u32(i)), "Octal or \\8 / \\9 escape sequences are not allowed in strict mode")
				return
			}
			// Skip escaped character
			i += 2
		} else {
			i += 1
		}
	}
}

