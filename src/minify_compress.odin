package kessel

import "core:mem"

// Syntax-level compression. Every rewrite keeps the order in which operands
// are evaluated, so getters, calls and exceptions happen exactly as before.
// The pass edits the tree in place before printing; identifiers keep their
// source offsets, so the mangler's offset-keyed aliases still apply.
MinifyCompressor :: struct {
	alloc: mem.Allocator,
	// Offsets of reads of the global `undefined`. Nil when `with` or a direct
	// eval could give the name another meaning.
	undefined_reads: map[u32]bool,
	// Declaration offsets of `const` bindings that are never assigned and that
	// no direct eval can reach. Spelling them `let` cannot be observed.
	constants: map[u32]bool,
	// Zero at the top level, where the value of the last statement is visible
	// to `eval` and to the embedder.
	function_depth: u32,
}

COMPRESS_SEQUENCE_MAX :: 1024
COMPRESS_JOIN_SMALL :: 64
// A chain of guards folds into nested conditionals. Parsers and printers
// recurse once per level, so the chain length is bounded.
COMPRESS_CONDITIONAL_DEPTH_MAX :: 32

minify_compress_program :: proc(c: ^MinifyCompressor, program: ^Program) {
	assert(c.function_depth == 0)
	compress_statement_list(c, &program.body, codegen_directive_count(program.body[:]), false)
	assert(c.function_depth == 0)
}

compress_new_expression :: proc(c: ^MinifyCompressor, node: $T) -> ^Expression {
	expr := new(Expression, c.alloc)
	expr^ = node
	return expr
}

compress_is_lexical_declaration :: proc(stmt: ^Statement) -> bool {
	#partial switch v in stmt^ {
	case ^VariableDeclaration: return v.kind != .Var
	case ^FunctionDeclaration, ^ClassDeclaration, ^ImportDeclaration, ^ExportNamedDeclaration,
	     ^ExportDefaultDeclaration, ^ExportAllDeclaration, ^TSInterfaceDeclaration,
	     ^TSTypeAliasDeclaration, ^TSEnumDeclaration, ^TSModuleDeclaration,
	     ^TSImportEqualsDeclaration, ^TSExportAssignment, ^TSNamespaceExportDeclaration:
		return true
	}
	return false
}

// True when a following `else` would attach to an `if` inside this statement.
compress_ends_with_open_if :: proc(stmt: ^Statement) -> bool {
	current := stmt
	for current != nil {
		#partial switch v in current^ {
		case ^IfStatement:
			alternate, has_alternate := v.alternate.?
			if !has_alternate { return true }
			current = alternate
		case ^WhileStatement:   current = v.body
		case ^ForStatement:     current = v.body
		case ^ForInStatement:   current = v.body
		case ^ForOfStatement:   current = v.body
		case ^WithStatement:    current = v.body
		case ^LabeledStatement: current = v.body
		case: return false
		}
	}
	return false
}

// `if (a) { b; }` needs no braces. A lexical declaration needs its block, and
// an `if` without `else` needs it when the outer statement has an `else`.
compress_body :: proc(c: ^MinifyCompressor, body: ^Statement, before_else: bool) {
	block, is_block := body^.(^BlockStatement)
	if !is_block { return }
	if len(block.body) == 0 {
		empty := new(EmptyStatement, c.alloc)
		empty.loc = block.loc
		body^ = empty
		return
	}
	if len(block.body) != 1 { return }
	inner := block.body[0]
	if compress_is_lexical_declaration(inner) { return }
	if before_else && compress_ends_with_open_if(inner) { return }
	body^ = inner^
}

compress_statement_expression :: proc(stmt: ^Statement) -> ^Expression {
	statement, ok := stmt^.(^ExpressionStatement)
	if !ok || statement.directive != "" { return nil }
	return statement.expression
}

compress_return_argument :: proc(stmt: ^Statement) -> ^Expression {
	statement, ok := stmt^.(^ReturnStatement)
	if !ok { return nil }
	return statement.argument.? or_else nil
}

compress_throw_argument :: proc(stmt: ^Statement) -> ^Expression {
	statement, ok := stmt^.(^ThrowStatement)
	if !ok { return nil }
	return statement.argument
}

// Operand kinds that need parentheses beside `&&` or `||`.
compress_logical_parens :: proc(expr: ^Expression, operator: LogicalOperator, right: bool) -> int {
	#partial switch v in expr^ {
	case ^ConditionalExpression, ^AssignmentExpression, ^SequenceExpression,
	     ^ArrowFunctionExpression, ^YieldExpression:
		return 1
	case ^LogicalExpression:
		if v.operator == .NullishCoalescing { return 1 }
		if v.operator == .Or && operator == .And { return 1 }
		if v.operator == .And && operator == .Or { return 0 }
		// The printer may group a right operand of equal precedence.
		return 1 if right else 0
	}
	return 0
}

compress_conditional_depth :: proc(expr: ^Expression) -> int {
	depth := 0
	current := expr
	for depth <= COMPRESS_CONDITIONAL_DEPTH_MAX {
		node, ok := current^.(^ConditionalExpression)
		if !ok { break }
		depth += 1
		current = node.alternate
	}
	return depth
}

compress_conditional :: proc(
	c: ^MinifyCompressor, test, yes, no: ^Expression, loc: Loc,
) -> ^Expression {
	node := new(ConditionalExpression, c.alloc)
	node.loc = loc
	node.test, node.consequent, node.alternate = test, yes, no
	// `!a ? b : c` is `a ? c : b`.
	if negated, ok := test^.(^UnaryExpression); ok && negated.operator == .LogicalNot {
		node.test, node.consequent, node.alternate = negated.argument, no, yes
	}
	return compress_new_expression(c, node)
}

// `if (a) b;` becomes `a && b;` and `if (!a) b;` becomes `a || b;` when that
// is not longer. Returns nil when the statement form is shorter.
compress_guard :: proc(c: ^MinifyCompressor, test, effect: ^Expression, loc: Loc) -> ^Expression {
	left, operator := test, LogicalOperator.And
	saved := 2
	if negated, ok := test^.(^UnaryExpression); ok && negated.operator == .LogicalNot {
		left, operator = negated.argument, .Or
		saved = 3
	}
	parens := compress_logical_parens(left, operator, false)
	parens += compress_logical_parens(effect, operator, true)
	if saved < 2 * parens { return nil }
	node := new(LogicalExpression, c.alloc)
	node.loc = loc
	node.operator, node.left, node.right = operator, left, effect
	return compress_new_expression(c, node)
}

compress_if :: proc(c: ^MinifyCompressor, stmt: ^Statement, v: ^IfStatement) {
	alternate, has_alternate := v.alternate.?
	compress_body(c, v.consequent, has_alternate)
	if has_alternate {
		compress_body(c, alternate, false)
		if _, empty := alternate^.(^EmptyStatement); empty {
			v.alternate = nil
			has_alternate = false
			compress_body(c, v.consequent, false)
		}
	}
	if !has_alternate {
		if _, empty := v.consequent^.(^EmptyStatement); empty && c.function_depth > 0 {
			statement := new(ExpressionStatement, c.alloc)
			statement.loc, statement.expression = v.loc, v.test
			stmt^ = statement
			return
		}
		effect := compress_statement_expression(v.consequent)
		if effect == nil || c.function_depth == 0 { return }
		guard := compress_guard(c, v.test, effect, v.loc)
		if guard == nil { return }
		statement := new(ExpressionStatement, c.alloc)
		statement.loc, statement.expression = v.loc, guard
		stmt^ = statement
		return
	}
	// An inner `if` may have lost its own `else` above or in an earlier visit.
	// Without braces this statement's `else` would attach to it.
	if compress_ends_with_open_if(v.consequent) {
		block := new(BlockStatement, c.alloc)
		block.loc = get_statement_loc(v.consequent)
		block.body = make([dynamic]^Statement, 0, 1, c.alloc)
		inner := new(Statement, c.alloc)
		inner^ = v.consequent^
		append(&block.body, inner)
		v.consequent^ = block
		return
	}
	yes, no := compress_statement_expression(v.consequent), compress_statement_expression(alternate)
	if yes != nil && no != nil {
		statement := new(ExpressionStatement, c.alloc)
		statement.loc, statement.expression = v.loc, compress_conditional(c, v.test, yes, no, v.loc)
		stmt^ = statement
		return
	}
	yes, no = compress_return_argument(v.consequent), compress_return_argument(alternate)
	if yes != nil && no != nil {
		statement := new(ReturnStatement, c.alloc)
		statement.loc, statement.argument = v.loc, compress_conditional(c, v.test, yes, no, v.loc)
		stmt^ = statement
		return
	}
	yes, no = compress_throw_argument(v.consequent), compress_throw_argument(alternate)
	if yes != nil && no != nil {
		statement := new(ThrowStatement, c.alloc)
		statement.loc, statement.argument = v.loc, compress_conditional(c, v.test, yes, no, v.loc)
		stmt^ = statement
	}
}

// Whether every name bound by the pattern is a never-assigned constant.
compress_pattern_constant :: proc(c: ^MinifyCompressor, pattern: Pattern) -> bool {
	switch v in pattern {
	case ^Identifier:        return c.constants[v.loc.start]
	case ^AssignmentPattern: return compress_pattern_constant(c, v.left)
	case ^RestElement:       return compress_pattern_constant(c, v.argument)
	case ^ObjectPattern:
		for property in v.properties {
			if !compress_pattern_constant(c, property.value) { return false }
		}
		return true
	case ^ArrayPattern:
		for element in v.elements {
			if inner, ok := element.?; ok && !compress_pattern_constant(c, inner) { return false }
		}
		return true
	case ^MemberExpression: return false
	}
	return false
}

compress_variable_declaration :: proc(c: ^MinifyCompressor, declaration: ^VariableDeclaration) {
	if declaration == nil || declaration.declare { return }
	unassigned := declaration.kind == .Const
	for &declarator in declaration.declarations {
		compress_pattern(c, declarator.id)
		if init, ok := declarator.init.?; ok { compress_value(c, init) }
		unassigned &&= compress_pattern_constant(c, declarator.id)
	}
	// `let` is two bytes shorter and joins with neighboring `let` declarations.
	if unassigned { declaration.kind = .Let }
}

compress_declaration :: proc(c: ^MinifyCompressor, declaration: ^Declaration) {
	if declaration == nil { return }
	#partial switch v in declaration^ {
	case ^FunctionDeclaration: compress_function(c, &v.expr)
	case ^VariableDeclaration: compress_variable_declaration(c, v)
	case ^ClassDeclaration:    compress_class(c, &v.expr)
	}
}

compress_loop :: proc(c: ^MinifyCompressor, body: ^Statement) {
	compress_statement(c, body)
	compress_body(c, body, false)
}

compress_for_each :: proc(
	c: ^MinifyCompressor, declaration: Maybe(^VariableDeclaration), target: Maybe(^Expression),
	right: ^Expression, body: ^Statement,
) {
	if value, ok := declaration.?; ok { compress_variable_declaration(c, value) }
	if value, ok := target.?; ok { compress_target(c, value) }
	compress_value(c, right)
	compress_loop(c, body)
}

compress_statement :: proc(c: ^MinifyCompressor, stmt: ^Statement) {
	if stmt == nil { return }
	#partial switch v in stmt^ {
	case ^ExpressionStatement:
		if v.directive == "" { compress_value(c, v.expression) }
	case ^BlockStatement: compress_statement_list(c, &v.body, 0, false)
	case ^ReturnStatement:
		if argument, ok := v.argument.?; ok {
			compress_value(c, argument)
			if compress_is_void_zero(argument) { v.argument = nil }
		}
	case ^LabeledStatement: compress_statement(c, v.body)
	case ^IfStatement:
		compress_value(c, v.test)
		compress_statement(c, v.consequent)
		if alternate, ok := v.alternate.?; ok { compress_statement(c, alternate) }
		compress_if(c, stmt, v)
	case ^SwitchStatement:
		compress_value(c, v.discriminant)
		for &item in v.cases {
			if test, ok := item.test.?; ok { compress_value(c, test) }
			compress_statement_list(c, &item.consequent, 0, false)
		}
	case ^WhileStatement:
		compress_value(c, v.test)
		compress_loop(c, v.body)
	case ^DoWhileStatement:
		compress_loop(c, v.body)
		compress_value(c, v.test)
	case ^ForStatement:
		if declaration, ok := v.init_decl.?; ok { compress_variable_declaration(c, declaration) }
		if init, ok := v.init_expr.?; ok { compress_value(c, init) }
		if test, ok := v.test.?; ok { compress_value(c, test) }
		if update, ok := v.update.?; ok { compress_value(c, update) }
		compress_loop(c, v.body)
	case ^ForInStatement: compress_for_each(c, v.left_decl, v.left_expr, v.right, v.body)
	case ^ForOfStatement: compress_for_each(c, v.left_decl, v.left_expr, v.right, v.body)
	case ^WithStatement:
		compress_value(c, v.object)
		compress_loop(c, v.body)
	case ^ThrowStatement: compress_value(c, v.argument)
	case ^TryStatement:
		compress_statement_list(c, &v.block.body, 0, false)
		if v.handler != nil {
			handler := &v.handler.(CatchClause)
			if param, has_param := handler.param.?; has_param { compress_pattern(c, param) }
			compress_statement_list(c, &handler.body.body, 0, false)
		}
		if v.finalizer != nil {
			finalizer := &v.finalizer.(BlockStatement)
			compress_statement_list(c, &finalizer.body, 0, false)
		}
	case ^FunctionDeclaration: compress_function(c, &v.expr)
	case ^VariableDeclaration: compress_variable_declaration(c, v)
	case ^ClassDeclaration:    compress_class(c, &v.expr)
	case ^ExportNamedDeclaration:
		if declaration, ok := v.declaration.?; ok { compress_declaration(c, declaration) }
	case ^ExportDefaultDeclaration:
		if v.declaration == nil { return }
		switch inner in v.declaration^ {
		case ^Declaration: compress_declaration(c, inner)
		case ^Expression:  compress_value(c, inner)
		}
	}
}

compress_terminates :: proc(stmt: ^Statement) -> bool {
	#partial switch v in stmt^ {
	case ^ReturnStatement, ^ThrowStatement, ^BreakStatement, ^ContinueStatement: return true
	case ^BlockStatement: return len(v.body) != 0 && compress_terminates(v.body[len(v.body)-1])
	}
	return false
}

// `if (a) { return b; } else { c; }` needs no `else`: the statements after a
// jump only run when the test fails. Declarations keep their block scope.
compress_flatten_else :: proc(c: ^MinifyCompressor, list: ^[dynamic]^Statement, first: int) {
	for index := first; index < len(list); index += 1 {
		branch, is_if := list[index]^.(^IfStatement)
		if !is_if { continue }
		alternate, has_alternate := branch.alternate.?
		if !has_alternate || !compress_terminates(branch.consequent) { continue }
		if block, is_block := alternate^.(^BlockStatement); is_block {
			scoped := false
			for statement in block.body { scoped ||= compress_is_lexical_declaration(statement) }
			if scoped { continue }
			inject_at(list, index + 1, ..block.body[:])
		} else {
			if compress_is_lexical_declaration(alternate) { continue }
			inject_at(list, index + 1, alternate)
		}
		branch.alternate = nil
		compress_body(c, branch.consequent, false)
	}
}

// `if (a) return b; return c;` becomes `return a ? b : c;`, last pair first so
// a chain of guards folds into one expression.
compress_merge_returns :: proc(c: ^MinifyCompressor, list: ^[dynamic]^Statement, first: int) {
	for index := len(list) - 2; index >= first; index -= 1 {
		branch, is_if := list[index]^.(^IfStatement)
		if !is_if || branch.alternate != nil { continue }
		yes := compress_return_argument(branch.consequent)
		no := compress_return_argument(list[index+1])
		if yes == nil || no == nil { continue }
		if compress_conditional_depth(no) >= COMPRESS_CONDITIONAL_DEPTH_MAX { continue }
		statement := new(ReturnStatement, c.alloc)
		statement.loc = {branch.loc.start, get_statement_loc(list[index+1]).end}
		statement.argument = compress_conditional(c, branch.test, yes, no, statement.loc)
		list[index]^ = statement
		ordered_remove(list, index + 1)
	}
}

compress_sequence :: proc(c: ^MinifyCompressor, left, right: ^Expression) -> ^Expression {
	sequence, is_sequence := left^.(^SequenceExpression)
	if !is_sequence {
		sequence = new(SequenceExpression, c.alloc)
		sequence.loc = get_expression_loc(left)
		sequence.expressions = make([dynamic]^Expression, 0, 4, c.alloc)
		append(&sequence.expressions, left)
	}
	if tail, nested := right^.(^SequenceExpression); nested {
		append(&sequence.expressions, ..tail.expressions[:])
	} else {
		append(&sequence.expressions, right)
	}
	sequence.loc.end = get_expression_loc(right).end
	return compress_new_expression(c, sequence)
}

compress_sequence_length :: proc(expr: ^Expression) -> int {
	sequence, is_sequence := expr^.(^SequenceExpression)
	return len(sequence.expressions) if is_sequence else 1
}

// Adjacent expression statements become one comma expression, and a leading
// expression moves into the `return`, `throw`, `if` or `switch` that follows.
// The statement count drops, which lets an enclosing block lose its braces.
compress_join_expressions :: proc(c: ^MinifyCompressor, list: ^[dynamic]^Statement, first: int) {
	write := first
	pending: ^ExpressionStatement
	for read in first..<len(list) {
		stmt := list[read]
		slot: ^^Expression
		#partial switch v in stmt^ {
		case ^ExpressionStatement:
			if v.directive == "" { slot = &v.expression }
		case ^ReturnStatement:
			// Maybe(^T) is stored as the pointer itself.
			#assert(size_of(Maybe(^Expression)) == size_of(^Expression))
			if v.argument != nil { slot = cast(^^Expression)&v.argument }
		case ^ThrowStatement:  slot = &v.argument
		case ^IfStatement:     slot = &v.test
		case ^SwitchStatement: slot = &v.discriminant
		}
		fits := false
		if pending != nil && slot != nil {
			length := compress_sequence_length(pending.expression) + compress_sequence_length(slot^)
			fits = length <= COMPRESS_SEQUENCE_MAX
		}
		statement, is_expression := stmt^.(^ExpressionStatement)
		if fits {
			joined := compress_sequence(c, pending.expression, slot^)
			if is_expression {
				pending.expression = joined
				pending.loc.end = statement.loc.end
				continue
			}
			slot^ = joined
			write -= 1
		}
		pending = statement if is_expression && slot != nil else nil
		list[write] = stmt
		write += 1
	}
	resize(list, write)
}

// A block that declares nothing block-scoped is only grouping. A leading
// string statement keeps its block, since unwrapped it could become a directive.
compress_flatten_blocks :: proc(list: ^[dynamic]^Statement, first: int) {
	for index := first; index < len(list); index += 1 {
		block, is_block := list[index]^.(^BlockStatement)
		if !is_block { continue }
		scoped := false
		for statement in block.body { scoped ||= compress_is_lexical_declaration(statement) }
		if scoped { continue }
		if len(block.body) != 0 {
			if expr := compress_statement_expression(block.body[0]); expr != nil {
				if _, is_string := expr^.(^StringLiteral); is_string { continue }
			} else if _, is_expression := block.body[0]^.(^ExpressionStatement); is_expression {
				continue
			}
		}
		ordered_remove(list, index)
		inject_at(list, index, ..block.body[:])
		index += len(block.body) - 1
	}
}

compress_statement_list :: proc(
	c: ^MinifyCompressor, list: ^[dynamic]^Statement, first: int, function_body: bool,
) {
	assert(first >= 0)
	assert(first <= len(list))
	for index in first..<len(list) { compress_statement(c, list[index]) }
	compress_flatten_blocks(list, first)
	compress_flatten_else(c, list, first)
	if function_body && len(list) > first {
		// Falling off the end of a function also returns undefined.
		last, ok := list[len(list)-1]^.(^ReturnStatement)
		if ok && last.argument == nil { pop(list) }
	}
	compress_merge_returns(c, list, first)
	compress_join_expressions(c, list, first)
}

compress_function :: proc(c: ^MinifyCompressor, function: ^FunctionExpression) {
	if function == nil || function.no_body { return }
	for &parameter in function.params {
		compress_pattern(c, parameter.pattern)
		if value, ok := parameter.default_val.?; ok { compress_value(c, value) }
	}
	c.function_depth += 1
	first := min(len(function.body.directives), len(function.body.body))
	first = max(first, codegen_directive_count(function.body.body[:]))
	compress_statement_list(c, &function.body.body, first, true)
	c.function_depth -= 1
}

compress_arrow :: proc(c: ^MinifyCompressor, arrow: ^ArrowFunctionExpression) {
	for &parameter in arrow.params {
		compress_pattern(c, parameter.pattern)
		if value, ok := parameter.default_val.?; ok { compress_value(c, value) }
	}
	c.function_depth += 1
	defer c.function_depth -= 1
	switch body in arrow.body {
	case ^Expression: compress_value(c, body)
	case ^BlockStatement:
		compress_statement_list(c, &body.body, codegen_directive_count(body.body[:]), true)
		// `() => { return a; }` is `() => a`.
		if len(body.body) != 1 { return }
		if argument := compress_return_argument(body.body[0]); argument != nil {
			arrow.body = argument
			arrow.expression = true
		}
	}
}

compress_class :: proc(c: ^MinifyCompressor, class: ^ClassExpression) {
	if class == nil { return }
	// `extends` takes a left-hand-side expression, which `void 0` is not.
	if super_class, ok := class.super_class.?; ok { compress_expression(c, super_class) }
	for &element in class.body.body {
		if element.computed && element.key != nil { compress_value(c, element.key) }
		value, has_value := element.value.?
		if !has_value || value == nil { continue }
		// A field initializer runs as a method of the class or instance.
		c.function_depth += 1
		compress_value(c, value)
		c.function_depth -= 1
	}
}

compress_pattern :: proc(c: ^MinifyCompressor, pattern: Pattern) {
	switch v in pattern {
	case ^Identifier:
	case ^AssignmentPattern:
		compress_pattern(c, v.left)
		compress_value(c, v.right)
	case ^ObjectPattern:
		for &property in v.properties {
			if key, has_key := property.key.?; has_key && property.computed {
				if expr, ok := key.(^Expression); ok { compress_value(c, expr) }
			}
			compress_pattern(c, property.value)
		}
	case ^ArrayPattern:
		for element in v.elements {
			if inner, ok := element.?; ok { compress_pattern(c, inner) }
		}
	case ^RestElement: compress_pattern(c, v.argument)
	case ^MemberExpression: compress_member(c, v)
	}
}

compress_is_void_zero :: proc(expr: ^Expression) -> bool {
	unary, ok := expr^.(^UnaryExpression)
	if !ok || unary.operator != .Void { return false }
	_, literal := unary.argument^.(^NumericLiteral)
	return literal
}

// A position whose value is read. `undefined` there can be spelled `void 0`
// without extra parentheses.
compress_value :: proc(c: ^MinifyCompressor, expr: ^Expression) {
	if expr == nil { return }
	compress_expression(c, expr)
	id, is_identifier := expr^.(^Identifier)
	if !is_identifier || !c.undefined_reads[id.loc.start] { return }
	assert(id.name == "undefined")
	zero := new(NumericLiteral, c.alloc)
	zero.loc, zero.value, zero.raw = id.loc, 0, "0"
	unary := new(UnaryExpression, c.alloc)
	unary.loc, unary.operator, unary.prefix = id.loc, .Void, true
	unary.argument = compress_new_expression(c, zero)
	expr^ = unary
}

compress_identifier_name :: proc(name: string) -> bool {
	if len(name) == 0 || (name[0] >= '0' && name[0] <= '9') { return false }
	for char in transmute([]byte)name {
		switch char {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_', '$':
		case: return false
		}
	}
	return true
}

compress_member :: proc(c: ^MinifyCompressor, member: ^MemberExpression) {
	compress_expression(c, member.object)
	compress_member_property(c, member)
}

// The part of a member access that is not its receiver.
compress_member_property :: proc(c: ^MinifyCompressor, member: ^MemberExpression) {
	if !member.computed { return }
	compress_value(c, member.property)
	// `a["b"]` is `a.b`.
	literal, is_string := member.property^.(^StringLiteral)
	if !is_string || !compress_identifier_name(literal.value) { return }
	id := new(Identifier, c.alloc)
	id.loc, id.name = literal.loc, literal.value
	member.property = compress_new_expression(c, id)
	member.computed = false
}

// Both operands of `typeof a === "b"` are strings, so `==` compares the same way.
compress_typeof_comparison :: proc(binary: ^BinaryExpression) {
	if binary.operator != .StrictEq && binary.operator != .StrictNotEq { return }
	is_string :: proc(expr: ^Expression) -> bool {
		#partial switch v in expr^ {
		case ^StringLiteral: return true
		case ^UnaryExpression: return v.operator == .Typeof
		}
		return false
	}
	if !is_string(binary.left) || !is_string(binary.right) { return }
	binary.operator = .Eq if binary.operator == .StrictEq else .NotEq
}

// Join two literals written with the same quote. The raw spellings concatenate
// without re-escaping anything.
compress_join_strings :: proc(c: ^MinifyCompressor, left, right: ^StringLiteral) -> ^StringLiteral {
	if len(left.raw) < 2 || len(right.raw) < 2 || left.raw[0] != right.raw[0] { return nil }
	// Each join copies both operands. Appending many short literals to a long
	// one would copy the long one every time, so a join must be small or must
	// add at least a sixteenth of what it copies. Total work stays linear.
	small := len(left.raw) + len(right.raw) <= COMPRESS_JOIN_SMALL
	if !small && len(right.raw) * 16 < len(left.raw) { return nil }
	raw := make([]byte, len(left.raw) + len(right.raw) - 2, c.alloc)
	copy(raw, left.raw[:len(left.raw)-1])
	copy(raw[len(left.raw)-1:], right.raw[1:])
	value := make([]byte, len(left.value) + len(right.value), c.alloc)
	copy(value, left.value)
	copy(value[len(left.value):], right.value)
	joined := new(StringLiteral, c.alloc)
	joined.loc = {left.loc.start, right.loc.end}
	joined.raw, joined.value = string(raw), string(value)
	return joined
}

// `"a" + "b"` is `"ab"`. `x + "a" + "b"` is `x + "ab"`: the left sum is already
// a string (or has thrown) when the second literal is appended.
compress_string_concatenation :: proc(
	c: ^MinifyCompressor, expr: ^Expression, binary: ^BinaryExpression,
) {
	if binary.operator != .Add { return }
	right, right_string := binary.right^.(^StringLiteral)
	if !right_string { return }
	if left, left_string := binary.left^.(^StringLiteral); left_string {
		if joined := compress_join_strings(c, left, right); joined != nil { expr^ = joined }
		return
	}
	inner, nested := binary.left^.(^BinaryExpression)
	if !nested || inner.operator != .Add { return }
	middle, middle_string := inner.right^.(^StringLiteral)
	if !middle_string { return }
	joined := compress_join_strings(c, middle, right)
	if joined == nil { return }
	inner.right = compress_new_expression(c, joined)
	inner.loc.end = binary.loc.end
	expr^ = inner
}

// An assignment target is written, not read.
compress_target :: proc(c: ^MinifyCompressor, expr: ^Expression) {
	if expr == nil { return }
	#partial switch v in expr^ {
	case ^Identifier:
	case ^ArrayExpression:
		for element in v.elements {
			if inner, ok := element.?; ok { compress_target(c, inner) }
		}
	case ^ObjectExpression:
		for &property in v.properties {
			if property.computed && property.key != nil { compress_value(c, property.key) }
			if !property.shorthand { compress_target(c, property.value) }
		}
	case ^AssignmentExpression:
		compress_target(c, v.left)
		compress_value(c, v.right)
	case ^SpreadElement:           compress_target(c, v.argument)
	case ^ParenthesizedExpression: compress_target(c, v.expression)
	case: compress_expression(c, expr)
	}
}

compress_jsx_children :: proc(c: ^MinifyCompressor, children: []JSXChild) {
	for child in children {
		#partial switch v in child {
		case ^JSXElement:
			for item in v.opening_element.attributes {
				switch attribute in item {
				case JSXAttribute:
					if value, ok := attribute.value.?; ok { compress_expression(c, value) }
				case ^JSXSpreadAttribute: compress_value(c, attribute.argument)
				}
			}
			compress_jsx_children(c, v.children[:])
		case ^JSXFragment:            compress_jsx_children(c, v.children[:])
		case ^JSXExpressionContainer: compress_value(c, v.expression)
		case ^JSXSpreadChild:         compress_value(c, v.expression)
		}
	}
}

compress_arguments :: proc(c: ^MinifyCompressor, callee: ^Expression, arguments: []^Expression) {
	compress_expression(c, callee)
	for argument in arguments { compress_value(c, argument) }
}

// Whether the chain operand of a link is read as a value, so that `void 0`
// may stand there. A receiver, a callee and the left operand of `**` are not.
compress_chain_operand_is_value :: proc(node: ^Expression) -> bool {
	#partial switch v in node^ {
	case ^BinaryExpression:  return v.operator != .Pow
	case ^LogicalExpression: return true
	}
	return false
}

// `a + b + c`, `a && b`, `a.b.c` and `a()()` nest along their left operand
// without limit: the parser builds them in a loop. Visit such a chain with an
// explicit list, innermost link first, exactly as recursion would return.
compress_chain :: proc(c: ^MinifyCompressor, expr: ^Expression) {
	assert(expr_is_spine_node(expr))
	spine: ExprSpine = ---
	// Without the list the chain is left as written, which is always valid.
	if !expr_spine_open(&spine, expr) { return }
	defer expr_spine_close(&spine)
	assert(len(spine.nodes) > 0)
	if compress_chain_operand_is_value(spine.nodes[len(spine.nodes)-1]) {
		compress_value(c, spine.leaf)
	} else {
		compress_expression(c, spine.leaf)
	}
	#reverse for node in spine.nodes {
		#partial switch v in node^ {
		case ^BinaryExpression:
			compress_value(c, v.right)
			compress_typeof_comparison(v)
			compress_string_concatenation(c, node, v)
		case ^LogicalExpression: compress_value(c, v.right)
		case ^MemberExpression:  compress_member_property(c, v)
		case ^CallExpression:
			for argument in v.arguments { compress_value(c, argument) }
		case: unreachable()
		}
	}
}

// Visit operands. A callee, member receiver, tag, `delete` operand and the
// left operand of `**` keep their spelling: `void 0` would need parentheses
// there, or would change what `delete` reports.
compress_expression :: proc(c: ^MinifyCompressor, expr: ^Expression) {
	if expr == nil { return }
	#partial switch v in expr^ {
	case ^TemplateLiteral:
		for item in v.expressions { compress_value(c, item) }
	case ^TaggedTemplateExpression:
		compress_expression(c, v.tag)
		compress_expression(c, v.quasi)
	case ^ChainExpression: compress_expression(c, v.expression)
	case ^ArrayExpression:
		for element in v.elements {
			if inner, ok := element.?; ok { compress_value(c, inner) }
		}
	case ^ObjectExpression:
		for &property in v.properties {
			if property.computed && property.key != nil { compress_value(c, property.key) }
			if !property.shorthand { compress_value(c, property.value) }
		}
	case ^FunctionExpression:      compress_function(c, v)
	case ^ArrowFunctionExpression: compress_arrow(c, v)
	case ^ClassExpression:         compress_class(c, v)
	case ^MemberExpression, ^CallExpression, ^BinaryExpression, ^LogicalExpression:
		compress_chain(c, expr)
	case ^NewExpression:           compress_arguments(c, v.callee, v.arguments[:])
	case ^ConditionalExpression:
		compress_value(c, v.test)
		compress_value(c, v.consequent)
		compress_value(c, v.alternate)
	case ^UpdateExpression: compress_target(c, v.argument)
	case ^UnaryExpression:
		if v.operator == .Delete {
			compress_expression(c, v.argument)
		} else {
			compress_value(c, v.argument)
		}
	case ^AssignmentExpression:
		compress_target(c, v.left)
		compress_value(c, v.right)
	case ^SequenceExpression:
		for item in v.expressions { compress_value(c, item) }
	case ^SpreadElement: compress_value(c, v.argument)
	case ^YieldExpression:
		if argument, ok := v.argument.?; ok { compress_value(c, argument) }
	case ^AwaitExpression: compress_value(c, v.argument)
	case ^ImportExpression:
		compress_value(c, v.source)
		compress_value(c, v.options)
	case ^JSXElement:
		element: JSXChild = v
		compress_jsx_children(c, {element})
	case ^JSXFragment:             compress_jsx_children(c, v.children[:])
	case ^JSXExpressionContainer:  compress_value(c, v.expression)
	case ^ParenthesizedExpression: compress_value(c, v.expression)
	}
}
