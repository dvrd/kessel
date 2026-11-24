package kessel

// no-extra-boolean-cast and no-eval: rules decided by what surrounds a node.

// The index of the nearest ancestor of `index` that is not a parenthesized
// or optional-chain wrapper, or -1.
lint_real_parent :: proc(l: ^Linter, index: int) -> int {
	for parent := index - 1; parent >= 0; parent -= 1 {
		expr, is_expr := l.ancestors[parent].(^Expression)
		if !is_expr { return parent }
		#partial switch _ in expr^ {
		case ^ParenthesizedExpression, ^ChainExpression: continue
		}
		return parent
	}
	return -1
}

lint_is_not :: proc(node: LintNode) -> bool {
	expr, is_expr := node.(^Expression)
	if !is_expr { return false }
	unary, is_unary := expr^.(^UnaryExpression)
	return is_unary && unary.operator == .LogicalNot
}

// True when `test`, stripped of wrappers, is exactly the node at `loc`.
lint_is_test :: proc(test: ^Expression, loc: Loc) -> bool {
	inner := lint_unparen(lint_inner(test))
	return inner != nil && lint_expr_loc(inner) == loc
}

// A position whose value is converted to a boolean anyway: the first argument
// of Boolean(), a loop or branch test, or the operand of `!`.
lint_is_boolean_context :: proc(l: ^Linter, index: int) -> bool {
	parent := lint_real_parent(l, index)
	if parent < 0 { return false }
	loc := lint_expr_loc(l.ancestors[index].(^Expression))
	switch node in l.ancestors[parent] {
	case ^Statement:
		#partial switch stmt in node^ {
		case ^IfStatement:      return lint_is_test(stmt.test, loc)
		case ^WhileStatement:   return lint_is_test(stmt.test, loc)
		case ^DoWhileStatement: return lint_is_test(stmt.test, loc)
		case ^ForStatement:
			test, has_test := stmt.test.?
			return has_test && lint_is_test(test, loc)
		}
	case ^Expression:
		arguments: []^Expression
		#partial switch expr in node^ {
		case ^UnaryExpression:       return expr.operator == .LogicalNot
		case ^ConditionalExpression: return lint_is_test(expr.test, loc)
		case ^CallExpression:
			if !lint_is_specific_id(expr.callee, "Boolean") { return false }
			arguments = expr.arguments[:]
		case ^NewExpression:
			if !lint_is_specific_id(expr.callee, "Boolean") { return false }
			arguments = expr.arguments[:]
		}
		if len(arguments) == 0 { return false }
		if _, spread := arguments[0]^.(^SpreadElement); spread { return false }
		return lint_expr_loc(lint_unparen(arguments[0])) == loc
	case ^BlockStatement:
	}
	return false
}

// With enforceForInnerExpressions the operands of `&&` and `||` inherit the
// context of the whole logical expression.
lint_is_flagged_context :: proc(l: ^Linter, start: int) -> bool {
	for index := start; index >= 0; {
		if lint_is_boolean_context(l, index) { return true }
		if !l.options.boolean_cast_inner { return false }
		parent := lint_real_parent(l, index)
		if parent < 0 { return false }
		expr, is_expr := l.ancestors[parent].(^Expression)
		if !is_expr { return false }
		logical, is_logical := expr^.(^LogicalExpression)
		if !is_logical || logical.operator == .NullishCoalescing { return false }
		index = parent
	}
	return false
}

lint_check_extra_boolean_cast :: proc(l: ^Linter, expr: ^Expression) {
	if !lint_rule_enabled(l, .L2042_NoExtraBooleanCast) { return }
	top := len(l.ancestors) - 1
	#partial switch node in expr^ {
	case ^CallExpression:
		if lint_is_specific_id(node.callee, "Boolean") && lint_is_flagged_context(l, top) {
			lint_emit(l, node.loc, .L2042_NoExtraBooleanCast)
		}
	case ^UnaryExpression:
		if node.operator != .LogicalNot { return }
		parent := lint_real_parent(l, top)
		if parent < 0 || !lint_is_not(l.ancestors[parent]) || !lint_is_flagged_context(l, parent) { return }
		lint_emit(l, lint_expr_loc(l.ancestors[parent].(^Expression)), .L2042_NoExtraBooleanCast)
	}
}

// no-eval: a direct call always counts. An optional call `eval?.()` is an
// indirect eval and is reported only when indirect calls are not allowed.
lint_check_no_eval :: proc(l: ^Linter, e: ^CallExpression) {
	if e == nil || !lint_rule_enabled(l, .L4008_NoEval) { return }
	if e.optional && !l.options.eval_no_indirect { return }
	if lint_is_specific_id(e.callee, "eval") { lint_emit(l, lint_expr_loc(e.callee), .L4008_NoEval) }
}

// With allowIndirect off, every reference to the global `eval` is reported,
// including `window.eval` and `globalThis["eval"]` through any number of
// self-referencing hops such as `window.window`.
lint_check_eval_reference :: proc(l: ^Linter, id: ^Identifier) {
	if !l.options.eval_no_indirect || !lint_rule_enabled(l, .L4008_NoEval) { return }
	switch id.name {
	case "eval", "global", "window", "globalThis":
	case: return
	}
	if !lint_global_defined(&l.globals, id.name) { return }
	if id.name == "eval" {
		lint_report_if_global(l, id, id.loc, .L4008_NoEval)
		return
	}
	index := lint_real_parent(l, len(l.ancestors) - 1)
	for index >= 0 {
		expr, is_expr := l.ancestors[index].(^Expression)
		if !is_expr { return }
		member, is_member := expr^.(^MemberExpression)
		if !is_member { return }
		name, static := lint_static_property_name(member)
		if !static { return }
		if name == "eval" {
			lint_report_if_global(l, id, lint_expr_loc(member.property), .L4008_NoEval)
			return
		}
		if name != id.name { return }
		index = lint_real_parent(l, index)
	}
}

// no-unused-expressions: an expression statement must do something. Calls,
// assignments, `await`, `yield`, `delete` and `void` count as doing something.
lint_expression_is_unused :: proc(l: ^Linter, expr: ^Expression) -> bool {
	if expr == nil { return false }
	switch node in expr^ {
	case ^BooleanLiteral, ^NullLiteral, ^NumericLiteral, ^BigIntLiteral, ^RegExpLiteral, ^StringLiteral,
	     ^SequenceExpression, ^FunctionExpression, ^ArrayExpression, ^MemberExpression, ^MetaProperty,
	     ^ObjectExpression, ^TemplateLiteral, ^ArrowFunctionExpression, ^ClassExpression,
	     ^BinaryExpression, ^ThisExpression, ^Identifier:
		return true
	case ^ChainExpression:
		inner := node.expression
		if inner == nil { return false }
		#partial switch element in inner^ {
		case ^CallExpression:      return false
		case ^TSNonNullExpression: return lint_expression_is_unused(l, element.expression)
		}
		return true
	case ^AssignmentExpression, ^AwaitExpression, ^NewExpression, ^ImportExpression, ^Super,
	     ^CallExpression, ^UpdateExpression, ^TSSatisfiesExpression, ^YieldExpression:
		return false
	case ^ConditionalExpression:
		if !l.options.unused_allow_ternary { return true }
		return lint_expression_is_unused(l, node.alternate) || lint_expression_is_unused(l, node.consequent)
	case ^LogicalExpression:
		if !l.options.unused_allow_short_circuit { return true }
		return lint_expression_is_unused(l, node.right)
	case ^ParenthesizedExpression:   return lint_expression_is_unused(l, node.expression)
	case ^TaggedTemplateExpression:  return !l.options.unused_allow_tagged
	case ^UnaryExpression:           return node.operator != .Delete && node.operator != .Void
	case ^JSXElement, ^JSXFragment:  return l.options.unused_enforce_jsx
	case ^TSAsExpression:            return lint_expression_is_unused(l, node.expression)
	case ^TSTypeAssertion:           return lint_expression_is_unused(l, node.expression)
	case ^TSNonNullExpression:       return lint_expression_is_unused(l, node.expression)
	case ^TSInstantiationExpression: return lint_expression_is_unused(l, node.expression)
	case ^PrivateIdentifier, ^SpreadElement, ^JSXText, ^JSXExpressionContainer, ^JSXEmptyExpression,
	     ^JSXSpreadChild:
	}
	return false
}

// The statement list that directly contains the statement being visited, when
// that list can start with a directive prologue.
lint_prologue_body :: proc(l: ^Linter) -> []^Statement {
	if len(l.ancestors) < 2 { return l.program_body }
	switch node in l.ancestors[len(l.ancestors) - 2] {
	case ^Statement:
		#partial switch parent in node^ {
		case ^FunctionDeclaration: return parent.body.body[:]
		case ^TSModuleDeclaration:
			body, has_body := parent.body.?
			if !has_body || body == nil { return nil }
			if block, is_block := body^.(^TSModuleBlock); is_block && block != nil { return block.body[:] }
		}
	case ^Expression:
		#partial switch parent in node^ {
		case ^FunctionExpression:
			if l.static_blocks[parent] { return nil }
			return parent.body.body[:]
		case ^ArrowFunctionExpression:
			if block, is_block := parent.body.(^BlockStatement); is_block && block != nil { return block.body[:] }
		}
	case ^BlockStatement:
	}
	return nil
}

lint_is_string_statement :: proc(stmt: ^Statement) -> bool {
	if stmt == nil { return false }
	expression, ok := stmt^.(^ExpressionStatement)
	if !ok || expression == nil || expression.expression == nil { return false }
	_, is_string := expression.expression^.(^StringLiteral)
	return is_string
}

// A directive is a string statement preceded only by other string statements
// at the start of a program, function or namespace body.
lint_is_directive :: proc(l: ^Linter, v: ^ExpressionStatement) -> bool {
	if v.directive != "" { return true }
	if v.expression == nil { return false }
	if _, is_string := v.expression^.(^StringLiteral); !is_string { return false }
	for stmt in lint_prologue_body(l) {
		if stmt == nil { return false }
		if candidate, ok := stmt^.(^ExpressionStatement); ok && candidate == v { return true }
		if !lint_is_string_statement(stmt) { return false }
	}
	return false
}

lint_check_unused_expression :: proc(l: ^Linter, v: ^ExpressionStatement) {
	if !lint_rule_enabled(l, .L4006_NoUnusedExpressions) || lint_is_directive(l, v) { return }
	if !lint_expression_is_unused(l, v.expression) { return }
	// The parser starts a template-literal statement after its backtick.
	loc := v.loc
	loc.start = min(loc.start, lint_expr_loc(v.expression).start)
	lint_emit(l, loc, .L4006_NoUnusedExpressions)
}
