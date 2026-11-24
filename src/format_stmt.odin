package kessel

// Statement printers. See format_print.odin for the conventions.

@(private = "file")
format_stmt_kind :: proc(stmt: ^Statement) -> FormatNodeKind {
	#partial switch _ in stmt^ {
	case ^ExpressionStatement: return .Expression_Statement
	case ^BlockStatement: return .Block
	case ^ReturnStatement: return .Return
	case ^ThrowStatement: return .Throw
	case ^IfStatement: return .If
	case ^WhileStatement: return .While
	case ^DoWhileStatement: return .Do_While
	case ^ForStatement: return .For
	case ^ForInStatement: return .For_In
	case ^ForOfStatement: return .For_Of
	case ^SwitchStatement: return .Switch
	case ^LabeledStatement: return .Labeled
	case ^TryStatement: return .Try
	case ^WithStatement: return .With
	case ^VariableDeclaration: return .Variable_Declaration
	case ^FunctionDeclaration: return .Function_Declaration
	case ^ClassDeclaration: return .Class_Declaration
	case ^ExportDefaultDeclaration: return .Export_Default
	case ^ExportNamedDeclaration: return .Export_Named
	}
	return .Other
}

format_stmt_is_empty :: proc(stmt: ^Statement) -> bool {
	if stmt == nil {return true}
	_, empty := stmt^.(^EmptyStatement)
	return empty
}

format_stmt_is_block :: proc(stmt: ^Statement) -> bool {
	if stmt == nil {return false}
	_, block := stmt^.(^BlockStatement)
	return block
}

format_stmt :: proc(f: ^FormatContext, stmt: ^Statement, key: FormatKey) -> Doc {
	if stmt == nil {return format_fail(f)}
	entry := FormatPathEntry {
		kind = format_stmt_kind(stmt),
		key  = key,
		stmt = stmt,
	}
	if !format_path_push(f, entry) {return nil}
	defer format_path_pop(f)
	#partial switch node in stmt^ {
	case ^ExpressionStatement:
		expression := format_expr(f, node.expression, .Expression)
		trailing := format_inline_trailing_comments(
			f,
			get_expression_loc(node.expression).end,
			node.loc.end,
		)
		return fc(f, expression, trailing, ft(f, ";"))
	case ^EmptyStatement:
		return ft(f, ";")
	case ^DebuggerStatement:
		return ft(f, "debugger;")
	case ^BlockStatement:
		return format_block(f, node.body[:], false, node.loc)
	case ^WithStatement:
		return format_fail(f)
	case ^ReturnStatement:
		argument, _ := node.argument.?
		return fc(f, ft(f, "return"), format_return_argument(f, argument))
	case ^ThrowStatement:
		return fc(f, ft(f, "throw"), format_return_argument(f, node.argument))
	case ^BreakStatement:
		if label, labeled := node.label.?; labeled {
			return fc(f, ft(f, "break "), ft(f, label.name), ft(f, ";"))
		}
		return ft(f, "break;")
	case ^ContinueStatement:
		if label, labeled := node.label.?; labeled {
			return fc(f, ft(f, "continue "), ft(f, label.name), ft(f, ";"))
		}
		return ft(f, "continue;")
	case ^LabeledStatement:
		if format_stmt_is_empty(node.body) {return fc(f, ft(f, node.label.name), ft(f, ":;"))}
		return fc(f, ft(f, node.label.name), ft(f, ": "), format_stmt(f, node.body, .Body))
	case ^IfStatement:
		return format_if(f, node)
	case ^WhileStatement:
		return fg(
			f,
			ft(f, "while ("),
			fg(f, fi(f, doc_softline(), format_expr(f, node.test, .Test)), doc_softline()),
			ft(f, ")"),
			format_clause(f, node.body, .Body),
		)
	case ^DoWhileStatement:
		return format_do_while(f, node)
	case ^ForStatement:
		return format_for(f, node)
	case ^ForInStatement:
		return format_for_in(f, node)
	case ^ForOfStatement:
		return format_for_of(f, node)
	case ^SwitchStatement:
		return format_switch(f, node)
	case ^TryStatement:
		return format_try(f, node)
	case ^VariableDeclaration:
		return format_variable_declaration(f, node)
	case ^FunctionDeclaration:
		return format_function(f, &node.expr, {})
	case ^ClassDeclaration:
		return format_class(f, &node.expr)
	case ^ExportNamedDeclaration:
		return format_export_named(f, node)
	case ^ExportDefaultDeclaration:
		return format_export_default(f, node)
	}
	return format_fail(f)
}

// A body statement prints after a space when it is a block and otherwise on
// its own indented line.
@(private = "file")
format_clause :: proc(
	f: ^FormatContext,
	body: ^Statement,
	key: FormatKey,
	force_space := false,
) -> Doc {
	clause := format_stmt(f, body, key)
	if format_stmt_is_empty(body) {return clause}
	if format_stmt_is_block(body) || force_space {return fc(f, ft(f, " "), clause)}
	return fi(f, doc_line(), clause)
}

@(private = "file")
format_if :: proc(f: ^FormatContext, node: ^IfStatement) -> Doc {
	opening := fg(
		f,
		ft(f, "if ("),
		fg(f, fi(f, doc_softline(), format_expr(f, node.test, .Test)), doc_softline()),
		ft(f, ")"),
		format_clause(f, node.consequent, .Consequent),
	)
	alternate, has_alternate := node.alternate.?
	if !has_alternate || alternate == nil {return opening}
	separator := ft(f, " ") if format_stmt_is_block(node.consequent) else doc_hardline()
	_, else_if := alternate^.(^IfStatement)
	return fc(
		f,
		opening,
		separator,
		ft(f, "else"),
		fg(f, format_clause(f, alternate, .Alternate, else_if)),
	)
}

@(private = "file")
format_do_while :: proc(f: ^FormatContext, node: ^DoWhileStatement) -> Doc {
	clause := format_clause(f, node.body, .Body)
	separator := ft(f, " ") if format_stmt_is_block(node.body) else doc_hardline()
	return fc(
		f,
		fg(f, ft(f, "do"), clause),
		separator,
		ft(f, "while ("),
		fg(f, fi(f, doc_softline(), format_expr(f, node.test, .Test)), doc_softline()),
		ft(f, ");"),
	)
}

@(private = "file")
format_for :: proc(f: ^FormatContext, node: ^ForStatement) -> Doc {
	body := format_clause(f, node.body, .Body)
	init_decl, has_decl := node.init_decl.?
	init_expr, has_expr := node.init_expr.?
	test, has_test := node.test.?
	update, has_update := node.update.?
	if !has_decl && !has_expr && !has_test && !has_update {
		return fg(f, ft(f, "for (;;)"), body)
	}
	init: Doc
	if has_decl && init_decl != nil {
		init = format_variable_declaration(f, init_decl)
	} else if has_expr && init_expr != nil {
		init = format_expr(f, init_expr, .Init)
	}
	test_doc: Doc
	if has_test && test != nil {test_doc = format_expr(f, test, .Test)}
	update_doc := doc_if_break(f, nil, doc_line())
	if has_update && update != nil {
		update_doc = fc(f, doc_line(), format_expr(f, update, .Update))
	}
	head := fi(f, doc_softline(), init, ft(f, ";"), doc_line(), test_doc, ft(f, ";"), update_doc)
	return fg(f, ft(f, "for ("), fg(f, head, doc_softline()), ft(f, ")"), body)
}

// The left side of a for-in or for-of loop is a declaration without a
// semicolon or an assignment target.
@(private = "file")
format_for_left :: proc(
	f: ^FormatContext,
	declaration: Maybe(^VariableDeclaration),
	expression: Maybe(^Expression),
) -> Doc {
	if decl, present := declaration.?; present && decl != nil {
		// The legacy `for (var a = 1 in b)` needs parentheses rules of its own.
		for declarator in decl.declarations {
			if _, has_init := declarator.init.?; has_init {return format_fail(f)}
		}
		return format_variable_declaration(f, decl)
	}
	if expr, present := expression.?; present && expr != nil {
		// The identifiers `let` and `async` need parentheses rules here
		// that are not ported yet.
		#partial switch target in expr^ {
		case ^Identifier:
			if target.name == "let" || target.name == "async" {return format_fail(f)}
		case ^MemberExpression, ^ObjectExpression, ^ArrayExpression:
		case:
			return format_fail(f)
		}
		return format_target(f, expr, .Left)
	}
	return format_fail(f)
}

@(private = "file")
format_for_in :: proc(f: ^FormatContext, node: ^ForInStatement) -> Doc {
	return fg(
		f,
		ft(f, "for ("),
		format_for_left(f, node.left_decl, node.left_expr),
		ft(f, " in "),
		format_expr(f, node.right, .Right),
		ft(f, ")"),
		format_clause(f, node.body, .Body),
	)
}

@(private = "file")
format_for_of :: proc(f: ^FormatContext, node: ^ForOfStatement) -> Doc {
	return fg(
		f,
		ft(f, "for await (" if node.await else "for ("),
		format_for_left(f, node.left_decl, node.left_expr),
		ft(f, " of "),
		format_expr(f, node.right, .Right),
		ft(f, ")"),
		format_clause(f, node.body, .Body),
	)
}

@(private = "file")
format_switch :: proc(f: ^FormatContext, node: ^SwitchStatement) -> Doc {
	head := fg(
		f,
		ft(f, "switch ("),
		fi(f, doc_softline(), format_expr(f, node.discriminant, .Discriminant)),
		doc_softline(),
		ft(f, ")"),
	)
	if len(node.cases) == 0 {return fc(f, head, ft(f, " {"), doc_hardline(), ft(f, "}"))}
	// The cases lie between the braces that follow the discriminant.
	paren := format_next_code_index(f.source, get_expression_loc(node.discriminant).end)
	brace := format_next_code_index(f.source, u32(paren + 1))
	if brace >= len(f.source) || f.source[brace] != '{' || node.loc.end < 1 {return format_fail(f)}
	starts := make([]u32, len(node.cases), f.alloc)
	ends := make([]u32, len(node.cases), f.alloc)
	for switch_case, index in node.cases {
		starts[index], ends[index] = switch_case.loc.start, switch_case.loc.end
	}
	bounds := FormatListBounds{open = u32(brace + 1), close = node.loc.end - 1, has_head = true}
	comments, _ := format_list_comments(f, bounds, starts, ends)
	parts := make([dynamic]Doc, f.alloc)
	for &switch_case, index in node.cases {
		if index > 0 {append(&parts, doc_hardline())}
		printed := format_switch_case(f, &switch_case)
		append(&parts, format_with_comments(f, comments[index], printed))
		last := index == len(node.cases) - 1
		if !last && format_is_next_line_empty(f.source, switch_case.loc.end) {
			append(&parts, doc_hardline())
		}
	}
	return fc(
		f,
		head,
		ft(f, " {"),
		fi(f, doc_hardline(), fc(f, ..parts[:])),
		doc_hardline(),
		ft(f, "}"),
	)
}

@(private = "file")
format_switch_case :: proc(f: ^FormatContext, node: ^SwitchCase) -> Doc {
	if !format_path_push(f, {kind = .Switch_Case, key = .Cases, node = node}) {return nil}
	defer format_path_pop(f)
	head := ft(f, "default:")
	if test, present := node.test.?; present && test != nil {
		head = fc(f, ft(f, "case "), format_expr(f, test, .Test), ft(f, ":"))
	}
	count := 0
	only: ^Statement
	for stmt in node.consequent {
		if format_stmt_is_empty(stmt) {continue}
		count += 1
		only = stmt
	}
	if count == 0 {return head}
	// The list starts after the colon. A comment on the colon's line belongs
	// to the test, which this printer does not attach comments to.
	colon := int(node.loc.start) + len("default")
	if test, present := node.test.?; present && test != nil {
		colon = format_next_code_index(f.source, get_expression_loc(test).end)
	} else {
		colon = format_next_code_index(f.source, u32(colon))
	}
	if colon >= len(f.source) || f.source[colon] != ':' {return format_fail(f)}
	bounds := FormatListBounds{open = u32(colon + 1), close = node.loc.end, has_head = true}
	list := format_stmt_list(f, node.consequent[:], .Consequent, false, bounds)
	if count == 1 && format_stmt_is_block(only) {return fc(f, head, ft(f, " "), list)}
	return fc(f, head, fi(f, doc_hardline(), list))
}

@(private = "file")
format_try :: proc(f: ^FormatContext, node: ^TryStatement) -> Doc {
	parts := make([dynamic]Doc, f.alloc)
	append(&parts, ft(f, "try "), format_block_child(f, node.block.body[:], .Block, node.block.loc))
	finalizer, has_finalizer := node.finalizer.?
	if handler, present := node.handler.?; present {
		if !format_path_push(f, {kind = .Catch_Clause, key = .Handler}) {return nil}
		append(&parts, ft(f, " catch "))
		if param, has_param := handler.param.?; has_param {
			append(&parts, ft(f, "("), format_pattern(f, param, .Param), ft(f, ") "))
		}
		// Only a handler that ends the statement may print as `{}`.
		body_key := FormatKey.Finalizer if has_finalizer else FormatKey.Body
		append(&parts, format_block_child(f, handler.body.body[:], body_key, handler.body.loc))
		format_path_pop(f)
	}
	if has_finalizer {
		block := format_block_child(f, finalizer.body[:], .Finalizer, finalizer.loc)
		append(&parts, ft(f, " finally "), block)
	}
	return fc(f, ..parts[:])
}

// Prints the block on top of the path. An empty block keeps its braces
// together only after the constructs for which Prettier does so. Every other
// empty block spans two lines.
format_block :: proc(f: ^FormatContext, body: []^Statement, directives: bool, loc: Loc) -> Doc {
	assert(format_path_at(f, 0).kind == .Block)
	// Comments attach by position, so the span must be exactly the braces.
	if !format_is_delimited(f, loc, '{', '}') {return format_fail(f)}
	bounds := FormatListBounds{open = loc.start + 1, close = loc.end - 1}
	list := format_stmt_list(f, body, .Body, directives, bounds)
	if list != nil {
		return fc(f, ft(f, "{"), fi(f, doc_hardline(), list), doc_hardline(), ft(f, "}"))
	}
	#partial switch format_parent(f).kind {
	case .Arrow_Function, .Function_Expression, .Function_Declaration, .Object_Method,
	     .Class_Method, .For, .While, .Do_While:
		return ft(f, "{}")
	case .Catch_Clause:
		// The handler of a try statement that has no finalizer.
		if format_path_at(f, 0).key == .Body {return ft(f, "{}")}
	}
	return fc(f, ft(f, "{"), doc_hardline(), ft(f, "}"))
}

// A block that is a fixed part of its parent rather than a statement.
@(private = "file")
format_block_child :: proc(
	f: ^FormatContext,
	body: []^Statement,
	key: FormatKey,
	loc: Loc,
) -> Doc {
	if !format_path_push(f, {kind = .Block, key = key}) {return nil}
	defer format_path_pop(f)
	return format_block(f, body, false, loc)
}

// A directive is a string statement in the prologue. The parser drops
// parentheses, so the source offsets tell a directive from `("text");`.
format_is_directive_at :: proc(f: ^FormatContext, body: []^Statement, index: int) -> bool {
	for position in 0 ..= index {
		stmt := body[position]
		if stmt == nil {return false}
		statement, is_expression := stmt^.(^ExpressionStatement)
		if !is_expression || statement.expression == nil {return false}
		literal, is_string := statement.expression^.(^StringLiteral)
		if !is_string || literal.loc.start != statement.loc.start {return false}
	}
	return true
}

format_directive :: proc(f: ^FormatContext, stmt: ^Statement) -> Doc {
	statement := stmt^.(^ExpressionStatement)
	literal := statement.expression^.(^StringLiteral)
	raw := literal.raw
	assert(len(raw) >= 2)
	content := raw[1:len(raw) - 1]
	// A directive's meaning depends on its exact characters, so only the
	// quotes may change, and only when the content contains none.
	for char in content {
		if char == '"' || char == '\'' {return fc(f, ft(f, raw), ft(f, ";"))}
		if char == '\n' || char == '\r' {return format_fail(f)}
	}
	quote := "'" if f.options.single_quote else "\""
	return fc(f, ft(f, quote), ft(f, content), ft(f, quote), ft(f, ";"))
}

// The part of a container that holds a list: after its opening token and
// before its closing one. Comments in that range attach to the list's items.
FormatListBounds :: struct {
	open, close: u32,
	// Something other than a list item comes before the first item, as the
	// test of a switch case does. Prettier attaches some comments to it.
	has_head:    bool,
}

// Statements separated by hard lines. One blank line survives wherever the
// source has at least one. Empty statements disappear.
format_stmt_list :: proc(
	f: ^FormatContext,
	body: []^Statement,
	key: FormatKey,
	directives: bool,
	bounds: FormatListBounds,
) -> Doc {
	has_comments := len(format_comments_in(f, bounds.open, bounds.close)) > 0
	starts := make([dynamic]u32, f.alloc)
	ends := make([dynamic]u32, f.alloc)
	for stmt in body {
		if format_stmt_is_empty(stmt) {
			// Prettier attaches comments to the `;` it then drops.
			if has_comments {return format_fail(f)}
			continue
		}
		loc := get_statement_loc(stmt)
		append(&starts, loc.start)
		append(&ends, loc.end)
	}
	comments, dangling := format_list_comments(f, bounds, starts[:], ends[:])
	if len(starts) == 0 {return dangling}
	parts := make([dynamic]Doc, f.alloc)
	prologue := directives
	item := 0
	for stmt, index in body {
		if format_stmt_is_empty(stmt) {continue}
		prologue = prologue && format_is_directive_at(f, body[index:], 0)
		printed: Doc
		if prologue {
			printed = format_directive(f, stmt)
		} else {
			printed = format_stmt(f, stmt, key)
		}
		append(&parts, format_with_comments(f, comments[item], printed))
		item += 1
		if item == len(starts) {break}
		append(&parts, doc_hardline())
		if format_is_next_line_empty(f.source, get_statement_loc(stmt).end) {
			append(&parts, doc_hardline())
		}
	}
	return fc(f, ..parts[:])
}

// A binary argument that breaks is wrapped in parentheses so that its
// continuation lines cannot be mistaken for separate statements.
@(private = "file")
format_return_argument :: proc(f: ^FormatContext, argument: ^Expression) -> Doc {
	if argument == nil {return ft(f, ";")}
	doc := format_expr(f, argument, .Argument)
	inner := format_expr_unwrap(argument)
	if inner == nil {return format_fail(f)}
	#partial switch _ in inner^ {
	case ^BinaryExpression, ^LogicalExpression:
		doc = fg(
			f,
			doc_if_break(f, ft(f, "(")),
			fi(f, doc_softline(), doc),
			doc_softline(),
			doc_if_break(f, ft(f, ")")),
		)
	}
	return fc(f, ft(f, " "), doc, ft(f, ";"))
}

format_variable_kind :: proc(kind: VariableKind) -> string {
	switch kind {
	case .Var: return "var"
	case .Let: return "let"
	case .Const: return "const"
	case .Using: return "using"
	case .AwaitUsing: return "await using"
	}
	return "var"
}

format_variable_declaration :: proc(f: ^FormatContext, node: ^VariableDeclaration) -> Doc {
	if node.declare || len(node.declarations) == 0 {return format_fail(f)}
	// A statement already has its entry. A loop head or an export pushes
	// one here, so that declarators always see the declaration above them.
	current := format_path_at(f, 0)
	in_loop_head := current.kind == .For || current.kind == .For_In || current.kind == .For_Of
	pushed := current.kind != .Variable_Declaration
	if pushed {
		key := FormatKey.Init if in_loop_head else FormatKey.Declaration
		if !format_path_push(f, {kind = .Variable_Declaration, key = key}) {return nil}
	}
	defer if pushed {format_path_pop(f)}
	format_path_at(f, 0).node = node
	has_value := false
	for declarator in node.declarations {
		if _, present := declarator.init.?; present {has_value = true}
	}
	parts := make([dynamic]Doc, f.alloc)
	append(&parts, ft(f, format_variable_kind(node.kind)), ft(f, " "))
	first := format_variable_declarator(f, &node.declarations[0])
	if len(node.declarations) == 1 {
		append(&parts, first)
	} else {
		append(&parts, doc_indent(f, first))
		rest := make([dynamic]Doc, f.alloc)
		separator := doc_hardline() if has_value && !in_loop_head else doc_line()
		for &declarator in node.declarations[1:] {
			append(&rest, ft(f, ","), separator, format_variable_declarator(f, &declarator))
		}
		append(&parts, fi(f, ..rest[:]))
	}
	if !in_loop_head {append(&parts, ft(f, ";"))}
	return fg(f, ..parts[:])
}

@(private = "file")
format_variable_declarator :: proc(f: ^FormatContext, node: ^VariableDeclarator) -> Doc {
	if node.definite {return format_fail(f)}
	if !format_path_push(f, {kind = .Variable_Declarator, key = .Declarations, node = node}) {
		return nil
	}
	defer format_path_pop(f)
	left := format_pattern(f, node.id, .Id)
	init, _ := node.init.?
	return format_assignment_like(
		f,
		FormatAssignment {
			kind = .Declarator,
			declarator = node,
			left = left,
			left_end = get_pattern_loc(node.id).end,
			right = init,
		},
	)
}

@(private = "file")
format_export_named :: proc(f: ^FormatContext, node: ^ExportNamedDeclaration) -> Doc {
	declaration, present := node.declaration.?
	if !present || declaration == nil || node.export_kind != .Value {return format_fail(f)}
	#partial switch inner in declaration^ {
	case ^VariableDeclaration:
		return fc(f, ft(f, "export "), format_variable_declaration(f, inner))
	case ^FunctionDeclaration:
		if !format_path_push(f, {kind = .Function_Declaration, key = .Declaration}) {return nil}
		defer format_path_pop(f)
		return fc(f, ft(f, "export "), format_function(f, &inner.expr, {}))
	case ^ClassDeclaration:
		if !format_path_push(f, {kind = .Class_Declaration, key = .Declaration}) {return nil}
		defer format_path_pop(f)
		return fc(f, ft(f, "export "), format_class(f, &inner.expr))
	}
	return format_fail(f)
}

@(private = "file")
format_export_default :: proc(f: ^FormatContext, node: ^ExportDefaultDeclaration) -> Doc {
	if node.declaration == nil {return format_fail(f)}
	switch inner in node.declaration^ {
	case ^Declaration:
		if inner == nil {return format_fail(f)}
		#partial switch declaration in inner^ {
		case ^FunctionDeclaration:
			if !format_path_push(f, {kind = .Function_Declaration, key = .Declaration}) {
				return nil
			}
			defer format_path_pop(f)
			return fc(f, ft(f, "export default "), format_function(f, &declaration.expr, {}))
		case ^ClassDeclaration:
			if !format_path_push(f, {kind = .Class_Declaration, key = .Declaration}) {return nil}
			defer format_path_pop(f)
			return fc(f, ft(f, "export default "), format_class(f, &declaration.expr))
		}
		return format_fail(f)
	case ^Expression:
		return fc(f, ft(f, "export default "), format_expr(f, inner, .Declaration), ft(f, ";"))
	}
	return format_fail(f)
}
