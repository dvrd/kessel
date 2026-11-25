package kessel

// ============================================================================
// ast_walk.odin — typed, depth-bounded AST traversal for library consumers
// ============================================================================
//
//   Counter :: struct { calls: int }
//   count_calls :: proc(user: rawptr, node: AstNode) -> AstWalkAction {
//       counter := cast(^Counter)user
//       #partial switch n in node {
//       case ^CallExpression:   counter.calls += 1
//       case ^FunctionExpression: return .Skip   // do not look inside
//       }
//       return .Continue
//   }
//
//   counter: Counter
//   status := ast_walk(job.program, {user = &counter, enter = count_calls}, allocator)
//
// Order. Depth-first, children in source order. `enter` is called before a
// node's children and `leave` after them.
//
// Control. `enter` returns what happens next:
//   .Continue  visit the node's children, then call `leave` for it.
//   .Skip      do not visit its children; `leave` is still called for it, so
//              a visitor that pushes in `enter` and pops in `leave` stays
//              balanced.
//   .Stop      end the walk now. No further callback is made, `leave`
//              included, and the walk returns .Stopped.
//
// Nodes. `AstNode` is a union of pointers to the concrete AST structs, so a
// visitor switches on the node type directly and sees a `^JSXElement` the
// same way whether it is an expression or a JSX child. The pointers address
// the parse arena; they are valid until the job is closed.
//
// Directives. `"use strict"` is reported once, as the ExpressionStatement
// the parser keeps in the body (its `directive` field is set). The separate
// `directives` lists on Program and FunctionBody repeat it and are not
// walked.
//
// Parameters. A parameter is reported as a `^FunctionParameter` followed by
// its binding target and then its default value, for functions and arrows
// alike (see `function_parameter_view`). `^AssignmentPattern` is reported
// only for defaults nested inside a destructuring pattern.
//
// Spans. `ast_node_loc(node)` gives the `Loc` (UTF-8 byte offsets) of any
// node; `source_position_at` (positions.odin) turns it into a line and
// column.
//
// Bounds. Nesting deeper than `depth_max` ends the walk with .DepthExceeded
// instead of overflowing the native stack. `leave` is still called for every
// node that was entered, so a visitor that pushes and pops stays balanced;
// the same holds for .OutOfMemory. The default, AST_WALK_DEPTH_DEFAULT,
// walks any tree the parser accepts at its default `max_depth`: the walk
// counts nodes while the parser counts syntactic levels, and one level can
// be several nodes deep. A caller that raises `ParseConfig.max_depth` should
// pass AST_WALK_NODES_PER_LEVEL times that value. Left-associative chains — `a + b + c + ...`,
// `a && b && ...`, `a.b.c...`, `f()()()...` and mixes of them — are walked
// with a loop and count as one level however long they are, so a
// machine-generated million-term expression is fine. That loop keeps one
// pointer per chain link, allocated from `allocator`; a failed allocation
// ends the walk with .OutOfMemory.

import "core:mem"

// How many nodes deep one syntactic nesting level of the parser can be.
// The deepest measured shape is a class in a method in a class: class,
// class body, method, function, block make 5 nodes per parser level
// (tests/coverage/src/ast_walk_test.odin measures 40 shapes). 8 leaves
// headroom for shapes the measurement does not list.
AST_WALK_NODES_PER_LEVEL :: 8
AST_WALK_DEPTH_DEFAULT   :: AST_WALK_NODES_PER_LEVEL * PARSE_RESOURCE_AST_DEPTH

#assert(AST_WALK_NODES_PER_LEVEL >= 5)

AstWalkAction :: enum u8 {
	Continue,
	Skip,
	Stop,
}

AstWalkStatus :: enum u8 {
	Completed,     // every node was offered to the visitor
	Stopped,       // the visitor returned .Stop
	DepthExceeded, // nesting went past `depth_max`; the walk is incomplete
	OutOfMemory,   // the chain stack could not grow; the walk is incomplete
}

AstVisitor :: struct {
	// Passed back to both callbacks.
	user:  rawptr,
	// Either callback may be nil.
	enter: proc(user: rawptr, node: AstNode) -> AstWalkAction,
	leave: proc(user: rawptr, node: AstNode),
}

// Every node kind the walk reports.
AstNode :: union {
	^Program,
	// Statements and declarations.
	^ExpressionStatement, ^EmptyStatement, ^BlockStatement, ^DebuggerStatement,
	^ReturnStatement, ^BreakStatement, ^ContinueStatement, ^LabeledStatement,
	^IfStatement, ^SwitchStatement, ^WhileStatement, ^DoWhileStatement,
	^ForStatement, ^ForInStatement, ^ForOfStatement, ^WithStatement,
	^ThrowStatement, ^TryStatement, ^FunctionDeclaration, ^VariableDeclaration,
	^ClassDeclaration, ^ImportDeclaration, ^ExportNamedDeclaration,
	^ExportDefaultDeclaration, ^ExportAllDeclaration, ^TSInterfaceDeclaration,
	^TSTypeAliasDeclaration, ^TSEnumDeclaration, ^TSModuleDeclaration,
	^TSImportEqualsDeclaration, ^TSExportAssignment, ^TSNamespaceExportDeclaration,
	// Parts of statements.
	^VariableDeclarator, ^SwitchCase, ^CatchClause, ^LabelIdentifier,
	^ImportSpecifier, ^ImportDefaultSpecifier, ^ImportNamespaceSpecifier,
	^ImportAttribute, ^ExportSpecifier,
	// Expressions.
	^NullLiteral, ^BooleanLiteral, ^NumericLiteral, ^StringLiteral, ^BigIntLiteral,
	^RegExpLiteral, ^TemplateLiteral, ^TaggedTemplateExpression, ^Identifier,
	^PrivateIdentifier, ^ThisExpression, ^Super, ^ChainExpression, ^ArrayExpression,
	^ObjectExpression, ^FunctionExpression, ^ArrowFunctionExpression, ^ClassExpression,
	^MemberExpression, ^CallExpression, ^NewExpression, ^ConditionalExpression,
	^UpdateExpression, ^UnaryExpression, ^BinaryExpression, ^LogicalExpression,
	^AssignmentExpression, ^SequenceExpression, ^SpreadElement, ^YieldExpression,
	^AwaitExpression, ^ImportExpression, ^MetaProperty, ^ParenthesizedExpression,
	^TSAsExpression, ^TSSatisfiesExpression, ^TSNonNullExpression, ^TSTypeAssertion,
	^TSInstantiationExpression,
	// Parts of expressions, functions and classes.
	^TemplateElement, ^Property, ^FunctionParameter, ^FunctionBody, ^ClassBody,
	^ClassElement, ^Decorator, ^BindingIdentifier, ^IdentifierName,
	// Patterns that are not also expressions.
	^ObjectPattern, ^ObjectPatternProperty, ^ArrayPattern, ^AssignmentPattern, ^RestElement,
	// JSX.
	^JSXElement, ^JSXFragment, ^JSXText, ^JSXExpressionContainer, ^JSXEmptyExpression,
	^JSXSpreadChild, ^JSXOpeningElement, ^JSXClosingElement, ^JSXOpeningFragment,
	^JSXClosingFragment, ^JSXAttribute, ^JSXSpreadAttribute, ^JSXIdentifier,
	^JSXMemberExpression, ^JSXNamespacedName,
	// TypeScript types.
	^TSKeywordType, ^TSTypeReference, ^TSUnionType, ^TSIntersectionType, ^TSArrayType,
	^TSTupleType, ^TSFunctionType, ^TSConstructorType, ^TSTypeLiteral, ^TSConditionalType,
	^TSInferType, ^TSTypeQuery, ^TSIndexedAccessType, ^TSMappedType, ^TSTypeOperator,
	^TSLiteralType, ^TSTemplateLiteralType, ^TSParenthesizedType, ^TSRestType,
	^TSOptionalType, ^TSNamedTupleMember, ^TSTypePredicate, ^TSImportType,
	// Parts of TypeScript declarations and types.
	^TSTypeAnnotation, ^TSTypeParameterDeclaration, ^TSTypeParameter,
	^TSTypeParameterInstantiation, ^TSFunctionParam, ^TSPropertySignature,
	^TSMethodSignature, ^TSCallSignatureDeclaration, ^TSConstructSignatureDeclaration,
	^TSIndexSignature, ^TSInterfaceBody, ^TSInterfaceHeritage, ^TSEnumBody, ^TSEnumMember,
	^TSModuleBlock, ^TSExternalModuleReference,
}

// Source span of any node. Every struct in `AstNode` starts with its `loc`
// field and the union holds only pointers, so the span is read through the
// pointer without a switch over the node kinds.
// tests/coverage/src/ast_walk_test.odin checks that layout for every variant.
ast_node_loc :: proc(node: AstNode) -> Loc {
	node := node
	pointer := (cast(^^Loc)&node)^
	if node == nil || pointer == nil { return Loc{} }
	return pointer^
}
#assert(offset_of(Identifier, loc) == 0)
#assert(offset_of(FunctionDeclaration, loc) == 0)
#assert(offset_of(JSXElement, loc) == 0)

// Walk a whole program. `allocator` backs the chain stack described above
// and is released before returning.
ast_walk :: proc(
	program: ^Program,
	visitor: AstVisitor,
	allocator: mem.Allocator,
	depth_max: u32 = AST_WALK_DEPTH_DEFAULT,
) -> AstWalkStatus {
	walker: AstWalker
	ast_walker_init(&walker, visitor, allocator, depth_max)
	defer ast_walker_destroy(&walker)
	if program != nil && ast_walk_open(&walker, program) {
		for statement in program.body { ast_walk_statement(&walker, statement) }
		ast_walk_close(&walker, program)
	}
	assert(walker.depth == 0)
	return walker.status
}

// Walk one statement and everything below it.
ast_walk_statement_tree :: proc(
	statement: ^Statement,
	visitor: AstVisitor,
	allocator: mem.Allocator,
	depth_max: u32 = AST_WALK_DEPTH_DEFAULT,
) -> AstWalkStatus {
	walker: AstWalker
	ast_walker_init(&walker, visitor, allocator, depth_max)
	defer ast_walker_destroy(&walker)
	ast_walk_statement(&walker, statement)
	assert(walker.depth == 0)
	return walker.status
}

// Walk one expression and everything below it.
ast_walk_expression_tree :: proc(
	expression: ^Expression,
	visitor: AstVisitor,
	allocator: mem.Allocator,
	depth_max: u32 = AST_WALK_DEPTH_DEFAULT,
) -> AstWalkStatus {
	walker: AstWalker
	ast_walker_init(&walker, visitor, allocator, depth_max)
	defer ast_walker_destroy(&walker)
	ast_walk_expression(&walker, expression)
	assert(walker.depth == 0)
	return walker.status
}

// ----------------------------------------------------------------------------
// Walker state
// ----------------------------------------------------------------------------

@(private = "file")
AstWalker :: struct {
	visitor:   AstVisitor,
	// .Completed while the walk is still running.
	status:    AstWalkStatus,
	depth:     u32,
	depth_max: u32,
	// Left-associative chain links that were entered and await their
	// remaining children. Shared by nested chains as a stack.
	chain:     [dynamic]^Expression,
}

@(private = "file")
ast_walker_init :: proc(
	walker: ^AstWalker,
	visitor: AstVisitor,
	allocator: mem.Allocator,
	depth_max: u32,
) {
	assert(depth_max > 0)
	walker^ = AstWalker{
		visitor   = visitor,
		status    = .Completed,
		depth_max = depth_max,
		chain     = make([dynamic]^Expression, allocator),
	}
}

@(private = "file")
ast_walker_destroy :: proc(walker: ^AstWalker) {
	assert(len(walker.chain) == 0)
	delete(walker.chain)
}

// Offer `node` to the visitor and go one level deeper. Returns true when the
// node's children are to be visited; the caller then owes an ast_walk_close.
// Every recursive path through this file passes through here, which is what
// bounds the native stack.
@(private = "file")
ast_walk_open :: proc(walker: ^AstWalker, node: AstNode) -> bool {
	if walker.status != .Completed { return false }
	if walker.depth >= walker.depth_max {
		walker.status = .DepthExceeded
		return false
	}
	if !ast_walk_enter(walker, node) { return false }
	walker.depth += 1
	return true
}

@(private = "file")
ast_walk_close :: proc(walker: ^AstWalker, node: AstNode) {
	assert(walker.depth > 0)
	walker.depth -= 1
	ast_walk_leave(walker, node)
}

// The callbacks alone, without a depth change: used directly for the links
// of a chain after the first, which share the first link's level.
@(private = "file")
ast_walk_enter :: proc(walker: ^AstWalker, node: AstNode) -> bool {
	if walker.status != .Completed { return false }
	action := AstWalkAction.Continue
	if walker.visitor.enter != nil { action = walker.visitor.enter(walker.visitor.user, node) }
	switch action {
	case .Continue:
		return true
	case .Skip:
		ast_walk_leave(walker, node)
	case .Stop:
		walker.status = .Stopped
	}
	return false
}

@(private = "file")
ast_walk_leave :: proc(walker: ^AstWalker, node: AstNode) {
	// A visitor that asked to stop gets no further callback. A walk cut
	// short by depth or memory still closes what it opened.
	if walker.status == .Stopped { return }
	if walker.visitor.leave != nil { walker.visitor.leave(walker.visitor.user, node) }
}

// A node without children.
@(private = "file")
ast_walk_leaf :: proc(walker: ^AstWalker, node: AstNode) {
	if ast_walk_open(walker, node) { ast_walk_close(walker, node) }
}

// ----------------------------------------------------------------------------
// Statements
// ----------------------------------------------------------------------------

@(private = "file")
ast_walk_statement :: proc(walker: ^AstWalker, statement: ^Statement) {
	if statement == nil || statement_inner_nil(statement) { return }
	switch s in statement^ {
	case ^ExpressionStatement:
		if ast_walk_open(walker, s) {
			ast_walk_expression(walker, s.expression)
			ast_walk_close(walker, s)
		}
	case ^EmptyStatement:    ast_walk_leaf(walker, s)
	case ^DebuggerStatement: ast_walk_leaf(walker, s)
	case ^BlockStatement:    ast_walk_block(walker, s)
	case ^ReturnStatement:
		if ast_walk_open(walker, s) {
			if argument, present := s.argument.?; present { ast_walk_expression(walker, argument) }
			ast_walk_close(walker, s)
		}
	case ^ThrowStatement:
		if ast_walk_open(walker, s) {
			ast_walk_expression(walker, s.argument)
			ast_walk_close(walker, s)
		}
	case ^BreakStatement:
		if ast_walk_open(walker, s) {
			if label, present := &s.label.?; present { ast_walk_leaf(walker, label) }
			ast_walk_close(walker, s)
		}
	case ^ContinueStatement:
		if ast_walk_open(walker, s) {
			if label, present := &s.label.?; present { ast_walk_leaf(walker, label) }
			ast_walk_close(walker, s)
		}
	case ^LabeledStatement, ^IfStatement, ^SwitchStatement, ^WhileStatement,
	     ^DoWhileStatement, ^ForStatement, ^ForInStatement, ^ForOfStatement,
	     ^WithStatement, ^TryStatement:
		ast_walk_control_statement(walker, statement)
	case ^FunctionDeclaration:          ast_walk_function_declaration(walker, s)
	case ^VariableDeclaration:          ast_walk_variable_declaration(walker, s)
	case ^ClassDeclaration:             ast_walk_class_declaration(walker, s)
	case ^ImportDeclaration:            ast_walk_import_declaration(walker, s)
	case ^ExportNamedDeclaration:       ast_walk_export_named(walker, s)
	case ^ExportDefaultDeclaration:     ast_walk_export_default(walker, s)
	case ^ExportAllDeclaration:         ast_walk_export_all(walker, s)
	case ^TSInterfaceDeclaration:       ast_walk_ts_interface(walker, s)
	case ^TSTypeAliasDeclaration:       ast_walk_ts_type_alias(walker, s)
	case ^TSEnumDeclaration:            ast_walk_ts_enum(walker, s)
	case ^TSModuleDeclaration:          ast_walk_ts_module(walker, s)
	case ^TSImportEqualsDeclaration:    ast_walk_ts_import_equals(walker, s)
	case ^TSExportAssignment:
		if ast_walk_open(walker, s) {
			ast_walk_expression(walker, s.expression)
			ast_walk_close(walker, s)
		}
	case ^TSNamespaceExportDeclaration:
		if ast_walk_open(walker, s) {
			ast_walk_identifier(walker, &s.id)
			ast_walk_close(walker, s)
		}
	}
}

@(private = "file")
ast_walk_statements :: proc(walker: ^AstWalker, statements: []^Statement) {
	for statement in statements { ast_walk_statement(walker, statement) }
}

@(private = "file")
ast_walk_block :: proc(walker: ^AstWalker, block: ^BlockStatement) {
	if block == nil { return }
	if ast_walk_open(walker, block) {
		ast_walk_statements(walker, block.body[:])
		ast_walk_close(walker, block)
	}
}

@(private = "file")
ast_walk_control_statement :: proc(walker: ^AstWalker, statement: ^Statement) {
	#partial switch s in statement^ {
	case ^LabeledStatement:
		if ast_walk_open(walker, s) {
			ast_walk_leaf(walker, &s.label)
			ast_walk_statement(walker, s.body)
			ast_walk_close(walker, s)
		}
	case ^IfStatement:
		if ast_walk_open(walker, s) {
			ast_walk_expression(walker, s.test)
			ast_walk_statement(walker, s.consequent)
			if alternate, present := s.alternate.?; present {
				ast_walk_statement(walker, alternate)
			}
			ast_walk_close(walker, s)
		}
	case ^SwitchStatement:
		if ast_walk_open(walker, s) {
			ast_walk_expression(walker, s.discriminant)
			for &switch_case in s.cases { ast_walk_switch_case(walker, &switch_case) }
			ast_walk_close(walker, s)
		}
	case ^WhileStatement:
		if ast_walk_open(walker, s) {
			ast_walk_expression(walker, s.test)
			ast_walk_statement(walker, s.body)
			ast_walk_close(walker, s)
		}
	case ^DoWhileStatement:
		if ast_walk_open(walker, s) {
			ast_walk_statement(walker, s.body)
			ast_walk_expression(walker, s.test)
			ast_walk_close(walker, s)
		}
	case ^WithStatement:
		if ast_walk_open(walker, s) {
			ast_walk_expression(walker, s.object)
			ast_walk_statement(walker, s.body)
			ast_walk_close(walker, s)
		}
	case ^ForStatement, ^ForInStatement, ^ForOfStatement:
		ast_walk_loop_statement(walker, statement)
	case ^TryStatement:
		ast_walk_try(walker, s)
	}
}

@(private = "file")
ast_walk_loop_statement :: proc(walker: ^AstWalker, statement: ^Statement) {
	#partial switch s in statement^ {
	case ^ForStatement:
		if !ast_walk_open(walker, s) { return }
		if declaration, present := s.init_decl.?; present {
			ast_walk_variable_declaration(walker, declaration)
		}
		if init, present := s.init_expr.?; present { ast_walk_expression(walker, init) }
		if test, present := s.test.?; present { ast_walk_expression(walker, test) }
		if update, present := s.update.?; present { ast_walk_expression(walker, update) }
		ast_walk_statement(walker, s.body)
		ast_walk_close(walker, s)
	case ^ForInStatement:
		if !ast_walk_open(walker, s) { return }
		if declaration, present := s.left_decl.?; present {
			ast_walk_variable_declaration(walker, declaration)
		}
		if left, present := s.left_expr.?; present { ast_walk_expression(walker, left) }
		ast_walk_expression(walker, s.right)
		ast_walk_statement(walker, s.body)
		ast_walk_close(walker, s)
	case ^ForOfStatement:
		if !ast_walk_open(walker, s) { return }
		if declaration, present := s.left_decl.?; present {
			ast_walk_variable_declaration(walker, declaration)
		}
		if left, present := s.left_expr.?; present { ast_walk_expression(walker, left) }
		ast_walk_expression(walker, s.right)
		ast_walk_statement(walker, s.body)
		ast_walk_close(walker, s)
	}
}

@(private = "file")
ast_walk_switch_case :: proc(walker: ^AstWalker, switch_case: ^SwitchCase) {
	if !ast_walk_open(walker, switch_case) { return }
	if test, present := switch_case.test.?; present { ast_walk_expression(walker, test) }
	ast_walk_statements(walker, switch_case.consequent[:])
	ast_walk_close(walker, switch_case)
}

@(private = "file")
ast_walk_try :: proc(walker: ^AstWalker, statement: ^TryStatement) {
	if !ast_walk_open(walker, statement) { return }
	ast_walk_block(walker, &statement.block)
	if handler, present := &statement.handler.?; present {
		if ast_walk_open(walker, handler) {
			if param, bound := handler.param.?; bound { ast_walk_pattern(walker, param) }
			ast_walk_block(walker, &handler.body)
			ast_walk_close(walker, handler)
		}
	}
	if finalizer, present := &statement.finalizer.?; present {
		ast_walk_block(walker, finalizer)
	}
	ast_walk_close(walker, statement)
}

// ----------------------------------------------------------------------------
// Declarations
// ----------------------------------------------------------------------------

@(private = "file")
ast_walk_declaration :: proc(walker: ^AstWalker, declaration: ^Declaration) {
	if declaration == nil { return }
	switch d in declaration^ {
	case ^FunctionDeclaration:       ast_walk_function_declaration(walker, d)
	case ^VariableDeclaration:       ast_walk_variable_declaration(walker, d)
	case ^ClassDeclaration:          ast_walk_class_declaration(walker, d)
	case ^ImportDeclaration:         ast_walk_import_declaration(walker, d)
	case ^ExportNamedDeclaration:    ast_walk_export_named(walker, d)
	case ^ExportDefaultDeclaration:  ast_walk_export_default(walker, d)
	case ^ExportAllDeclaration:      ast_walk_export_all(walker, d)
	case ^TSInterfaceDeclaration:    ast_walk_ts_interface(walker, d)
	case ^TSTypeAliasDeclaration:    ast_walk_ts_type_alias(walker, d)
	case ^TSEnumDeclaration:         ast_walk_ts_enum(walker, d)
	case ^TSModuleDeclaration:       ast_walk_ts_module(walker, d)
	case ^TSImportEqualsDeclaration: ast_walk_ts_import_equals(walker, d)
	}
}

@(private = "file")
ast_walk_variable_declaration :: proc(walker: ^AstWalker, declaration: ^VariableDeclaration) {
	if declaration == nil || !ast_walk_open(walker, declaration) { return }
	for &declarator in declaration.declarations {
		if !ast_walk_open(walker, &declarator) { continue }
		ast_walk_pattern(walker, declarator.id)
		if init, present := declarator.init.?; present { ast_walk_expression(walker, init) }
		ast_walk_close(walker, &declarator)
	}
	ast_walk_close(walker, declaration)
}

@(private = "file")
ast_walk_function_declaration :: proc(walker: ^AstWalker, declaration: ^FunctionDeclaration) {
	if declaration == nil || !ast_walk_open(walker, declaration) { return }
	ast_walk_function_parts(walker, &declaration.expr)
	ast_walk_close(walker, declaration)
}

@(private = "file")
ast_walk_class_declaration :: proc(walker: ^AstWalker, declaration: ^ClassDeclaration) {
	if declaration == nil || !ast_walk_open(walker, declaration) { return }
	ast_walk_class_parts(walker, &declaration.expr)
	ast_walk_close(walker, declaration)
}

@(private = "file")
ast_walk_import_declaration :: proc(walker: ^AstWalker, declaration: ^ImportDeclaration) {
	if declaration == nil || !ast_walk_open(walker, declaration) { return }
	for specifier in declaration.specifiers {
		if specifier == nil { continue }
		switch &s in specifier^ {
		case ImportSpecifier:
			if ast_walk_open(walker, &s) {
				ast_walk_leaf(walker, &s.imported)
				ast_walk_leaf(walker, &s.local)
				ast_walk_close(walker, &s)
			}
		case ImportDefaultSpecifier:
			if ast_walk_open(walker, &s) {
				ast_walk_leaf(walker, &s.local)
				ast_walk_close(walker, &s)
			}
		case ImportNamespaceSpecifier:
			if ast_walk_open(walker, &s) {
				ast_walk_leaf(walker, &s.local)
				ast_walk_close(walker, &s)
			}
		}
	}
	ast_walk_leaf(walker, &declaration.source)
	ast_walk_import_attributes(walker, declaration.attributes[:])
	ast_walk_close(walker, declaration)
}

@(private = "file")
ast_walk_import_attributes :: proc(walker: ^AstWalker, attributes: []ImportAttribute) {
	for &attribute in attributes {
		if !ast_walk_open(walker, &attribute) { continue }
		ast_walk_leaf(walker, &attribute.key)
		ast_walk_leaf(walker, &attribute.value)
		ast_walk_close(walker, &attribute)
	}
}

@(private = "file")
ast_walk_export_name :: proc(walker: ^AstWalker, name: ^ExportSpecifierName) {
	switch &n in name^ {
	case IdentifierName: ast_walk_leaf(walker, &n)
	case ^StringLiteral: if n != nil { ast_walk_leaf(walker, n) }
	}
}

@(private = "file")
ast_walk_export_named :: proc(walker: ^AstWalker, declaration: ^ExportNamedDeclaration) {
	if declaration == nil || !ast_walk_open(walker, declaration) { return }
	if inner, present := declaration.declaration.?; present { ast_walk_declaration(walker, inner) }
	for &specifier in declaration.specifiers {
		if !ast_walk_open(walker, &specifier) { continue }
		ast_walk_export_name(walker, &specifier.local)
		ast_walk_export_name(walker, &specifier.exported)
		ast_walk_close(walker, &specifier)
	}
	if source, present := &declaration.source.?; present { ast_walk_leaf(walker, source) }
	ast_walk_import_attributes(walker, declaration.attributes[:])
	ast_walk_close(walker, declaration)
}

@(private = "file")
ast_walk_export_default :: proc(walker: ^AstWalker, declaration: ^ExportDefaultDeclaration) {
	if declaration == nil || !ast_walk_open(walker, declaration) { return }
	if declaration.declaration != nil {
		switch inner in declaration.declaration^ {
		case ^Declaration: ast_walk_declaration(walker, inner)
		case ^Expression:  ast_walk_expression(walker, inner)
		}
	}
	ast_walk_close(walker, declaration)
}

@(private = "file")
ast_walk_export_all :: proc(walker: ^AstWalker, declaration: ^ExportAllDeclaration) {
	if declaration == nil || !ast_walk_open(walker, declaration) { return }
	if exported, present := &declaration.exported.?; present { ast_walk_leaf(walker, exported) }
	ast_walk_leaf(walker, &declaration.source)
	ast_walk_import_attributes(walker, declaration.attributes[:])
	ast_walk_close(walker, declaration)
}

// ----------------------------------------------------------------------------
// Functions and classes
// ----------------------------------------------------------------------------

// Children shared by FunctionExpression and FunctionDeclaration.
@(private = "file")
ast_walk_function_parts :: proc(walker: ^AstWalker, function: ^FunctionExpression) {
	if name, present := &function.id.?; present { ast_walk_leaf(walker, name) }
	if parameters, present := function.type_parameters.?; present {
		ast_walk_ts_type_parameters(walker, parameters)
	}
	ast_walk_parameters(walker, function.params[:])
	if annotation, present := function.return_type.?; present {
		ast_walk_ts_annotation(walker, annotation)
	}
	if function.no_body { return }
	if ast_walk_open(walker, &function.body) {
		ast_walk_statements(walker, function.body.body[:])
		ast_walk_close(walker, &function.body)
	}
}

@(private = "file")
ast_walk_parameters :: proc(walker: ^AstWalker, parameters: []FunctionParameter) {
	for &parameter in parameters {
		if !ast_walk_open(walker, &parameter) { continue }
		view := function_parameter_view(&parameter)
		ast_walk_pattern(walker, view.target)
		if view.default_value != nil { ast_walk_expression(walker, view.default_value) }
		ast_walk_close(walker, &parameter)
	}
}

@(private = "file")
ast_walk_arrow :: proc(walker: ^AstWalker, arrow: ^ArrowFunctionExpression) {
	if !ast_walk_open(walker, arrow) { return }
	if parameters, present := arrow.type_parameters.?; present {
		ast_walk_ts_type_parameters(walker, parameters)
	}
	ast_walk_parameters(walker, arrow.params[:])
	if annotation, present := arrow.return_type.?; present {
		ast_walk_ts_annotation(walker, annotation)
	}
	switch body in arrow.body {
	case ^Expression:     ast_walk_expression(walker, body)
	case ^BlockStatement: ast_walk_block(walker, body)
	}
	ast_walk_close(walker, arrow)
}

@(private = "file")
ast_walk_decorators :: proc(walker: ^AstWalker, decorators: []Decorator) {
	for &decorator in decorators {
		if !ast_walk_open(walker, &decorator) { continue }
		ast_walk_expression(walker, decorator.expression)
		ast_walk_close(walker, &decorator)
	}
}

// Children shared by ClassExpression and ClassDeclaration.
@(private = "file")
ast_walk_class_parts :: proc(walker: ^AstWalker, class: ^ClassExpression) {
	ast_walk_decorators(walker, class.decorators[:])
	if name, present := &class.id.?; present { ast_walk_leaf(walker, name) }
	if parameters, present := class.type_parameters.?; present {
		ast_walk_ts_type_parameters(walker, parameters)
	}
	if super_class, present := class.super_class.?; present {
		ast_walk_expression(walker, super_class)
	}
	if arguments, present := class.super_type_arguments.?; present {
		ast_walk_ts_type_arguments(walker, arguments)
	}
	for &heritage in class.implements { ast_walk_ts_heritage(walker, &heritage) }
	if !ast_walk_open(walker, &class.body) { return }
	for &element in class.body.body { ast_walk_class_element(walker, &element) }
	ast_walk_close(walker, &class.body)
}

// A static block is a ClassElement of kind .StaticBlock whose `value` is a
// FunctionExpression holding the block's statements.
@(private = "file")
ast_walk_class_element :: proc(walker: ^AstWalker, element: ^ClassElement) {
	if !ast_walk_open(walker, element) { return }
	ast_walk_decorators(walker, element.decorators[:])
	if element.kind == .IndexSignature {
		ast_walk_ts_signature(walker, element.typing.index_signature)
	} else {
		ast_walk_expression(walker, element.key)
		if annotation, present := element.typing.annotation.?; present {
			ast_walk_ts_annotation(walker, annotation)
		}
		if value, present := element.value.?; present { ast_walk_expression(walker, value) }
	}
	ast_walk_close(walker, element)
}

// ----------------------------------------------------------------------------
// Expressions
// ----------------------------------------------------------------------------

// The child a left-associative chain continues through, or nil when
// `expression` is not a chain link.
@(private = "file")
ast_walk_chain_child :: proc(expression: ^Expression) -> ^Expression {
	#partial switch e in expression^ {
	case ^BinaryExpression:  return e.left
	case ^LogicalExpression: return e.left
	case ^MemberExpression:  return e.object
	case ^CallExpression:    return e.callee
	}
	return nil
}

// The children of a chain link other than the one the chain continues
// through. They are ordinary subtrees and may recurse.
@(private = "file")
ast_walk_chain_rest :: proc(walker: ^AstWalker, expression: ^Expression) {
	#partial switch e in expression^ {
	case ^BinaryExpression:  ast_walk_expression(walker, e.right)
	case ^LogicalExpression: ast_walk_expression(walker, e.right)
	case ^MemberExpression:  ast_walk_expression(walker, e.property)
	case ^CallExpression:
		if arguments, present := e.type_parameters.?; present {
			ast_walk_ts_type_arguments(walker, arguments)
		}
		for argument in e.arguments { ast_walk_expression(walker, argument) }
	}
}

// Walk an expression. A left-associative chain is descended with a loop:
// each link is entered on the way down and remembered on `walker.chain`,
// then on the way back up its remaining children are visited and it is
// left. The whole chain costs one level of depth and no native recursion.
@(private = "file")
ast_walk_expression :: proc(walker: ^AstWalker, expression: ^Expression) {
	chain_base := len(walker.chain)
	current := expression
	for current != nil && !expression_inner_nil(current) {
		next := ast_walk_chain_child(current)
		if next == nil || expression_inner_nil(next) {
			// Not a link (or a malformed one): an ordinary node.
			ast_walk_expression_node(walker, current)
			break
		}
		if _, error := append(&walker.chain, current); error != nil {
			walker.status = .OutOfMemory
			break
		}
		node := ast_node_from_expression(current)
		is_first := len(walker.chain) == chain_base + 1
		entered := ast_walk_open(walker, node) if is_first else ast_walk_enter(walker, node)
		if !entered {
			pop(&walker.chain)
			break
		}
		current = next
	}

	for len(walker.chain) > chain_base {
		link := pop(&walker.chain)
		ast_walk_chain_rest(walker, link)
		node := ast_node_from_expression(link)
		is_first := len(walker.chain) == chain_base
		if is_first { ast_walk_close(walker, node) } else { ast_walk_leave(walker, node) }
	}
	assert(len(walker.chain) == chain_base)
}

// Enter one expression node, visit all of its children, leave it.
@(private = "file")
ast_walk_expression_node :: proc(walker: ^AstWalker, expression: ^Expression) {
	#partial switch e in expression^ {
	case ^ArrowFunctionExpression: ast_walk_arrow(walker, e); return
	case ^JSXElement:              ast_walk_jsx_element(walker, e); return
	case ^JSXFragment:             ast_walk_jsx_fragment(walker, e); return
	case ^JSXExpressionContainer:  ast_walk_jsx_container(walker, e); return
	case ^JSXSpreadChild:          ast_walk_jsx_spread_child(walker, e); return
	case ^Identifier:              ast_walk_identifier(walker, e); return
	}
	node := ast_node_from_expression(expression)
	if !ast_walk_open(walker, node) { return }
	ast_walk_expression_children(walker, expression)
	ast_walk_close(walker, node)
}

@(private = "file")
ast_walk_identifier :: proc(walker: ^AstWalker, identifier: ^Identifier) {
	if identifier == nil || !ast_walk_open(walker, identifier) { return }
	if annotation, present := identifier.type_annotation.?; present {
		ast_walk_ts_annotation(walker, annotation)
	}
	ast_walk_close(walker, identifier)
}

@(private = "file")
ast_walk_expression_children :: proc(walker: ^AstWalker, expression: ^Expression) {
	#partial switch e in expression^ {
	case ^TemplateLiteral:
		// Quasis and expressions alternate in the source.
		for &quasi, index in e.quasis {
			ast_walk_leaf(walker, &quasi)
			if index < len(e.expressions) { ast_walk_expression(walker, e.expressions[index]) }
		}
	case ^TaggedTemplateExpression:
		ast_walk_expression(walker, e.tag)
		ast_walk_expression(walker, e.quasi)
	case ^ChainExpression:         ast_walk_expression(walker, e.expression)
	case ^ParenthesizedExpression: ast_walk_expression(walker, e.expression)
	case ^SpreadElement:           ast_walk_expression(walker, e.argument)
	case ^AwaitExpression:         ast_walk_expression(walker, e.argument)
	case ^UpdateExpression:        ast_walk_expression(walker, e.argument)
	case ^UnaryExpression:         ast_walk_expression(walker, e.argument)
	case ^YieldExpression:
		if argument, present := e.argument.?; present { ast_walk_expression(walker, argument) }
	case ^ArrayExpression:
		for element in e.elements {
			if value, present := element.?; present { ast_walk_expression(walker, value) }
		}
	case ^ObjectExpression:
		for &property in e.properties {
			if !ast_walk_open(walker, &property) { continue }
			ast_walk_expression(walker, property.key)
			// A shorthand `{a}` stores the same identifier as key and value.
			if property.value != property.key { ast_walk_expression(walker, property.value) }
			ast_walk_close(walker, &property)
		}
	case ^FunctionExpression: ast_walk_function_parts(walker, e)
	case ^ClassExpression:    ast_walk_class_parts(walker, e)
	case ^SequenceExpression:
		for item in e.expressions { ast_walk_expression(walker, item) }
	case ^ConditionalExpression:
		ast_walk_expression(walker, e.test)
		ast_walk_expression(walker, e.consequent)
		ast_walk_expression(walker, e.alternate)
	case ^AssignmentExpression:
		ast_walk_expression(walker, e.left)
		ast_walk_expression(walker, e.right)
	case ^NewExpression:
		ast_walk_expression(walker, e.callee)
		if arguments, present := e.type_parameters.?; present {
			ast_walk_ts_type_arguments(walker, arguments)
		}
		for argument in e.arguments { ast_walk_expression(walker, argument) }
	case ^ImportExpression:
		ast_walk_expression(walker, e.source)
		ast_walk_expression(walker, e.options)
	case ^MetaProperty:
		ast_walk_identifier(walker, &e.meta)
		ast_walk_identifier(walker, &e.property)
	case:
		ast_walk_expression_children_rest(walker, expression)
	}
}

// Chain links that were not walked as a chain (a nil or malformed chain
// child), and the TypeScript expression wrappers.
@(private = "file")
ast_walk_expression_children_rest :: proc(walker: ^AstWalker, expression: ^Expression) {
	#partial switch e in expression^ {
	case ^BinaryExpression, ^LogicalExpression, ^MemberExpression, ^CallExpression:
		ast_walk_expression(walker, ast_walk_chain_child(expression))
		ast_walk_chain_rest(walker, expression)
	case ^TSAsExpression:
		ast_walk_expression(walker, e.expression)
		ast_walk_ts_type(walker, e.type_annotation)
	case ^TSSatisfiesExpression:
		ast_walk_expression(walker, e.expression)
		ast_walk_ts_type(walker, e.type_annotation)
	case ^TSNonNullExpression:
		ast_walk_expression(walker, e.expression)
	case ^TSTypeAssertion:
		ast_walk_ts_type(walker, e.type_annotation)
		ast_walk_expression(walker, e.expression)
	case ^TSInstantiationExpression:
		ast_walk_expression(walker, e.expression)
		ast_walk_ts_type_arguments(walker, e.type_arguments)
	}
	// Everything else is a leaf: literals, `this`, `super`, private names,
	// JSX text and the empty JSX expression.
}

@(private = "file")
ast_node_from_expression :: proc(expression: ^Expression) -> AstNode {
	switch e in expression^ {
	case ^NullLiteral:               return e
	case ^BooleanLiteral:            return e
	case ^NumericLiteral:            return e
	case ^StringLiteral:             return e
	case ^BigIntLiteral:             return e
	case ^RegExpLiteral:             return e
	case ^TemplateLiteral:           return e
	case ^TaggedTemplateExpression:  return e
	case ^Identifier:                return e
	case ^PrivateIdentifier:         return e
	case ^ThisExpression:            return e
	case ^Super:                     return e
	case ^ChainExpression:           return e
	case ^ArrayExpression:           return e
	case ^ObjectExpression:          return e
	case ^FunctionExpression:        return e
	case ^ArrowFunctionExpression:   return e
	case ^ClassExpression:           return e
	case ^MemberExpression:          return e
	case ^CallExpression:            return e
	case ^NewExpression:             return e
	case ^ConditionalExpression:     return e
	case ^UpdateExpression:          return e
	case ^UnaryExpression:           return e
	case ^BinaryExpression:          return e
	case ^LogicalExpression:         return e
	case ^AssignmentExpression:      return e
	case ^SequenceExpression:        return e
	case ^SpreadElement:             return e
	case ^YieldExpression:           return e
	case ^AwaitExpression:           return e
	case ^ImportExpression:          return e
	case ^MetaProperty:              return e
	case ^JSXElement:                return e
	case ^JSXFragment:               return e
	case ^JSXText:                   return e
	case ^JSXExpressionContainer:    return e
	case ^JSXEmptyExpression:        return e
	case ^JSXSpreadChild:            return e
	case ^TSAsExpression:            return e
	case ^TSSatisfiesExpression:     return e
	case ^TSNonNullExpression:       return e
	case ^TSTypeAssertion:           return e
	case ^TSInstantiationExpression: return e
	case ^ParenthesizedExpression:   return e
	}
	return nil
}

// ----------------------------------------------------------------------------
// Patterns
// ----------------------------------------------------------------------------

@(private = "file")
ast_walk_pattern :: proc(walker: ^AstWalker, pattern: Pattern) {
	switch p in pattern {
	case ^Identifier: ast_walk_identifier(walker, p)
	case ^ObjectPattern:
		if p == nil || !ast_walk_open(walker, p) { return }
		for &property in p.properties { ast_walk_pattern_property(walker, &property) }
		if annotation, present := p.type_annotation.?; present {
			ast_walk_ts_annotation(walker, annotation)
		}
		ast_walk_close(walker, p)
	case ^ArrayPattern:
		if p == nil || !ast_walk_open(walker, p) { return }
		for element in p.elements {
			if inner, present := element.?; present { ast_walk_pattern(walker, inner) }
		}
		if annotation, present := p.type_annotation.?; present {
			ast_walk_ts_annotation(walker, annotation)
		}
		ast_walk_close(walker, p)
	case ^AssignmentPattern:
		if p == nil || !ast_walk_open(walker, p) { return }
		ast_walk_pattern(walker, p.left)
		ast_walk_expression(walker, p.right)
		ast_walk_close(walker, p)
	case ^RestElement:
		if p == nil || !ast_walk_open(walker, p) { return }
		ast_walk_pattern(walker, p.argument)
		ast_walk_close(walker, p)
	case ^MemberExpression:
		// An assignment target such as `[a.b] = c`: walked as the expression
		// it is. The visitor receives the node itself, not this slot.
		if p == nil { return }
		slot: Expression = p
		ast_walk_expression(walker, &slot)
	}
}

@(private = "file")
ast_walk_pattern_property :: proc(walker: ^AstWalker, property: ^ObjectPatternProperty) {
	if !ast_walk_open(walker, property) { return }
	if key, present := &property.key.?; present {
		switch &k in key^ {
		case IdentifierName: ast_walk_leaf(walker, &k)
		case ^StringLiteral: if k != nil { ast_walk_leaf(walker, k) }
		case ^NumericLiteral: if k != nil { ast_walk_leaf(walker, k) }
		case ^Expression:    ast_walk_expression(walker, k)
		}
	}
	ast_walk_pattern(walker, property.value)
	ast_walk_close(walker, property)
}

// ----------------------------------------------------------------------------
// JSX
// ----------------------------------------------------------------------------

@(private = "file")
ast_walk_jsx_element :: proc(walker: ^AstWalker, element: ^JSXElement) {
	if element == nil || !ast_walk_open(walker, element) { return }
	if opening := element.opening_element; opening != nil && ast_walk_open(walker, opening) {
		ast_walk_jsx_name(walker, &opening.name)
		if arguments, present := opening.type_arguments.?; present {
			ast_walk_ts_type_arguments(walker, arguments)
		}
		for &attribute in opening.attributes { ast_walk_jsx_attribute(walker, &attribute) }
		ast_walk_close(walker, opening)
	}
	ast_walk_jsx_children(walker, element.children[:])
	if closing, present := element.closing_element.?; present && closing != nil {
		if ast_walk_open(walker, closing) {
			ast_walk_jsx_name(walker, &closing.name)
			ast_walk_close(walker, closing)
		}
	}
	ast_walk_close(walker, element)
}

@(private = "file")
ast_walk_jsx_fragment :: proc(walker: ^AstWalker, fragment: ^JSXFragment) {
	if fragment == nil || !ast_walk_open(walker, fragment) { return }
	ast_walk_leaf(walker, &fragment.opening_fragment)
	ast_walk_jsx_children(walker, fragment.children[:])
	ast_walk_leaf(walker, &fragment.closing_fragment)
	ast_walk_close(walker, fragment)
}

@(private = "file")
ast_walk_jsx_children :: proc(walker: ^AstWalker, children: []JSXChild) {
	for child in children {
		switch c in child {
		case ^JSXElement:             ast_walk_jsx_element(walker, c)
		case ^JSXFragment:            ast_walk_jsx_fragment(walker, c)
		case ^JSXText:                if c != nil { ast_walk_leaf(walker, c) }
		case ^JSXExpressionContainer: ast_walk_jsx_container(walker, c)
		case ^JSXSpreadChild:         ast_walk_jsx_spread_child(walker, c)
		}
	}
}

@(private = "file")
ast_walk_jsx_container :: proc(walker: ^AstWalker, container: ^JSXExpressionContainer) {
	if container == nil || !ast_walk_open(walker, container) { return }
	ast_walk_expression(walker, container.expression)
	ast_walk_close(walker, container)
}

@(private = "file")
ast_walk_jsx_spread_child :: proc(walker: ^AstWalker, spread: ^JSXSpreadChild) {
	if spread == nil || !ast_walk_open(walker, spread) { return }
	ast_walk_expression(walker, spread.expression)
	ast_walk_close(walker, spread)
}

@(private = "file")
ast_walk_jsx_attribute :: proc(walker: ^AstWalker, attribute: ^JSXAttributeItem) {
	switch &a in attribute^ {
	case JSXAttribute:
		if !ast_walk_open(walker, &a) { return }
		switch &name in a.name {
		case JSXIdentifier:      ast_walk_leaf(walker, &name)
		case ^JSXNamespacedName: ast_walk_jsx_namespaced(walker, name)
		}
		if value, present := a.value.?; present { ast_walk_expression(walker, value) }
		ast_walk_close(walker, &a)
	case ^JSXSpreadAttribute:
		if a == nil || !ast_walk_open(walker, a) { return }
		ast_walk_expression(walker, a.argument)
		ast_walk_close(walker, a)
	}
}

@(private = "file")
ast_walk_jsx_name :: proc(walker: ^AstWalker, name: ^JSXElementName) {
	switch &n in name^ {
	case JSXIdentifier:        ast_walk_leaf(walker, &n)
	case ^JSXNamespacedName:   ast_walk_jsx_namespaced(walker, n)
	case ^JSXMemberExpression: ast_walk_jsx_member(walker, n)
	}
}

@(private = "file")
ast_walk_jsx_namespaced :: proc(walker: ^AstWalker, name: ^JSXNamespacedName) {
	if name == nil || !ast_walk_open(walker, name) { return }
	ast_walk_leaf(walker, &name.namespace)
	ast_walk_leaf(walker, &name.name)
	ast_walk_close(walker, name)
}

// `a.b.c` nests to the left like a member expression, but tag names are
// short in practice and each level is depth-checked, so this recurses.
@(private = "file")
ast_walk_jsx_member :: proc(walker: ^AstWalker, member: ^JSXMemberExpression) {
	if member == nil || !ast_walk_open(walker, member) { return }
	switch &object in member.object {
	case JSXIdentifier:        ast_walk_leaf(walker, &object)
	case ^JSXMemberExpression: ast_walk_jsx_member(walker, object)
	}
	ast_walk_leaf(walker, &member.property)
	ast_walk_close(walker, member)
}

// ----------------------------------------------------------------------------
// TypeScript declarations
// ----------------------------------------------------------------------------

@(private = "file")
ast_walk_ts_interface :: proc(walker: ^AstWalker, declaration: ^TSInterfaceDeclaration) {
	if declaration == nil || !ast_walk_open(walker, declaration) { return }
	ast_walk_leaf(walker, &declaration.id)
	if parameters, present := declaration.type_parameters.?; present {
		ast_walk_ts_type_parameters(walker, parameters)
	}
	for &heritage in declaration.extends { ast_walk_ts_heritage(walker, &heritage) }
	if ast_walk_open(walker, &declaration.body) {
		for signature in declaration.body.body { ast_walk_ts_signature(walker, signature) }
		ast_walk_close(walker, &declaration.body)
	}
	ast_walk_close(walker, declaration)
}

@(private = "file")
ast_walk_ts_heritage :: proc(walker: ^AstWalker, heritage: ^TSInterfaceHeritage) {
	if !ast_walk_open(walker, heritage) { return }
	ast_walk_expression(walker, heritage.expression)
	if arguments, present := heritage.type_parameters.?; present {
		ast_walk_ts_type_arguments(walker, arguments)
	}
	ast_walk_close(walker, heritage)
}

@(private = "file")
ast_walk_ts_type_alias :: proc(walker: ^AstWalker, declaration: ^TSTypeAliasDeclaration) {
	if declaration == nil || !ast_walk_open(walker, declaration) { return }
	ast_walk_leaf(walker, &declaration.id)
	if parameters, present := declaration.type_parameters.?; present {
		ast_walk_ts_type_parameters(walker, parameters)
	}
	ast_walk_ts_type(walker, declaration.type_annotation)
	ast_walk_close(walker, declaration)
}

@(private = "file")
ast_walk_ts_enum :: proc(walker: ^AstWalker, declaration: ^TSEnumDeclaration) {
	if declaration == nil || !ast_walk_open(walker, declaration) { return }
	ast_walk_leaf(walker, &declaration.id)
	if ast_walk_open(walker, &declaration.body) {
		for &member in declaration.body.members {
			if !ast_walk_open(walker, &member) { continue }
			ast_walk_expression(walker, member.id)
			if initializer, present := member.initializer.?; present {
				ast_walk_expression(walker, initializer)
			}
			ast_walk_close(walker, &member)
		}
		ast_walk_close(walker, &declaration.body)
	}
	ast_walk_close(walker, declaration)
}

// `namespace a.b.c {}` nests one declaration per name; each is depth-checked.
@(private = "file")
ast_walk_ts_module :: proc(walker: ^AstWalker, declaration: ^TSModuleDeclaration) {
	if declaration == nil || !ast_walk_open(walker, declaration) { return }
	ast_walk_expression(walker, declaration.id)
	if body, present := declaration.body.?; present && body != nil {
		switch inner in body^ {
		case ^TSModuleBlock:
			if inner != nil && ast_walk_open(walker, inner) {
				ast_walk_statements(walker, inner.body[:])
				ast_walk_close(walker, inner)
			}
		case ^TSModuleDeclaration:
			ast_walk_ts_module(walker, inner)
		}
	}
	ast_walk_close(walker, declaration)
}

@(private = "file")
ast_walk_ts_import_equals :: proc(walker: ^AstWalker, declaration: ^TSImportEqualsDeclaration) {
	if declaration == nil || !ast_walk_open(walker, declaration) { return }
	ast_walk_identifier(walker, &declaration.id)
	switch reference in declaration.module_reference {
	case ^Expression: ast_walk_expression(walker, reference)
	case ^TSExternalModuleReference:
		if reference != nil && ast_walk_open(walker, reference) {
			if reference.expression != nil { ast_walk_leaf(walker, reference.expression) }
			ast_walk_close(walker, reference)
		}
	}
	ast_walk_close(walker, declaration)
}

// ----------------------------------------------------------------------------
// TypeScript types
// ----------------------------------------------------------------------------

@(private = "file")
ast_walk_ts_annotation :: proc(walker: ^AstWalker, annotation: ^TSTypeAnnotation) {
	if annotation == nil || !ast_walk_open(walker, annotation) { return }
	ast_walk_ts_type(walker, annotation.type_annotation)
	ast_walk_close(walker, annotation)
}

@(private = "file")
ast_walk_ts_type_parameters :: proc(walker: ^AstWalker, parameters: ^TSTypeParameterDeclaration) {
	if parameters == nil || !ast_walk_open(walker, parameters) { return }
	for &parameter in parameters.params { ast_walk_ts_type_parameter(walker, &parameter) }
	ast_walk_close(walker, parameters)
}

@(private = "file")
ast_walk_ts_type_parameter :: proc(walker: ^AstWalker, parameter: ^TSTypeParameter) {
	if !ast_walk_open(walker, parameter) { return }
	ast_walk_leaf(walker, &parameter.name)
	if constraint, present := parameter.constraint.?; present {
		ast_walk_ts_type(walker, constraint)
	}
	if default_type, present := parameter.default_.?; present {
		ast_walk_ts_type(walker, default_type)
	}
	ast_walk_close(walker, parameter)
}

@(private = "file")
ast_walk_ts_type_arguments :: proc(walker: ^AstWalker, arguments: ^TSTypeParameterInstantiation) {
	if arguments == nil || !ast_walk_open(walker, arguments) { return }
	for type in arguments.params { ast_walk_ts_type(walker, type) }
	ast_walk_close(walker, arguments)
}

@(private = "file")
ast_walk_ts_params :: proc(walker: ^AstWalker, parameters: []TSFunctionParam) {
	for &parameter in parameters {
		if !ast_walk_open(walker, &parameter) { continue }
		ast_walk_pattern(walker, parameter.pattern)
		if annotation, present := parameter.type_annotation.?; present {
			ast_walk_ts_annotation(walker, annotation)
		}
		ast_walk_close(walker, &parameter)
	}
}

// The parts every callable type and signature has, in source order.
@(private = "file")
ast_walk_ts_callable :: proc(
	walker: ^AstWalker,
	type_parameters: Maybe(^TSTypeParameterDeclaration),
	parameters: []TSFunctionParam,
	return_type: Maybe(^TSTypeAnnotation),
) {
	if declared, present := type_parameters.?; present {
		ast_walk_ts_type_parameters(walker, declared)
	}
	ast_walk_ts_params(walker, parameters)
	if annotation, present := return_type.?; present { ast_walk_ts_annotation(walker, annotation) }
}

@(private = "file")
ast_walk_ts_signature :: proc(walker: ^AstWalker, signature: ^TSSignature) {
	if signature == nil { return }
	switch &s in signature^ {
	case TSPropertySignature:
		if !ast_walk_open(walker, &s) { return }
		ast_walk_expression(walker, s.key)
		if annotation, present := s.type_annotation.?; present {
			ast_walk_ts_annotation(walker, annotation)
		}
		ast_walk_close(walker, &s)
	case TSMethodSignature:
		if !ast_walk_open(walker, &s) { return }
		ast_walk_expression(walker, s.key)
		ast_walk_ts_callable(walker, s.type_parameters, s.params[:], s.return_type)
		ast_walk_close(walker, &s)
	case TSCallSignatureDeclaration:
		if !ast_walk_open(walker, &s) { return }
		ast_walk_ts_callable(walker, s.type_parameters, s.params[:], s.return_type)
		ast_walk_close(walker, &s)
	case TSConstructSignatureDeclaration:
		if !ast_walk_open(walker, &s) { return }
		ast_walk_ts_callable(walker, s.type_parameters, s.params[:], s.return_type)
		ast_walk_close(walker, &s)
	case TSIndexSignature:
		if !ast_walk_open(walker, &s) { return }
		ast_walk_ts_callable(walker, nil, s.parameters[:], s.type_annotation)
		ast_walk_close(walker, &s)
	}
}

@(private = "file")
ast_walk_ts_type :: proc(walker: ^AstWalker, type: ^TSType) {
	if type == nil { return }
	node := ast_node_from_ts_type(type)
	if node == nil || !ast_walk_open(walker, node) { return }
	ast_walk_ts_type_children(walker, type)
	ast_walk_close(walker, node)
}

@(private = "file")
ast_walk_ts_types :: proc(walker: ^AstWalker, types: []^TSType) {
	for type in types { ast_walk_ts_type(walker, type) }
}

@(private = "file")
ast_walk_ts_type_children :: proc(walker: ^AstWalker, type: ^TSType) {
	#partial switch t in type^ {
	case ^TSTypeReference:
		ast_walk_expression(walker, t.type_name)
		if arguments, present := t.type_parameters.?; present {
			ast_walk_ts_type_arguments(walker, arguments)
		}
	case ^TSUnionType:         ast_walk_ts_types(walker, t.types[:])
	case ^TSIntersectionType:  ast_walk_ts_types(walker, t.types[:])
	case ^TSTupleType:         ast_walk_ts_types(walker, t.element_types[:])
	case ^TSArrayType:         ast_walk_ts_type(walker, t.element_type)
	case ^TSParenthesizedType: ast_walk_ts_type(walker, t.type_annotation)
	case ^TSRestType:          ast_walk_ts_type(walker, t.type_annotation)
	case ^TSOptionalType:      ast_walk_ts_type(walker, t.type_annotation)
	case ^TSTypeOperator:      ast_walk_ts_type(walker, t.type_annotation)
	case ^TSLiteralType:       ast_walk_expression(walker, t.literal)
	case ^TSInferType:         ast_walk_ts_type_parameter(walker, &t.type_parameter)
	case ^TSFunctionType:
		ast_walk_ts_callable(walker, t.type_parameters, t.params[:], t.return_type)
	case ^TSConstructorType:
		ast_walk_ts_callable(walker, t.type_parameters, t.params[:], t.return_type)
	case ^TSTypeLiteral:
		for member in t.members { ast_walk_ts_signature(walker, member) }
	case ^TSConditionalType:
		ast_walk_ts_type(walker, t.check_type)
		ast_walk_ts_type(walker, t.extends_type)
		ast_walk_ts_type(walker, t.true_type)
		ast_walk_ts_type(walker, t.false_type)
	case ^TSIndexedAccessType:
		ast_walk_ts_type(walker, t.object_type)
		ast_walk_ts_type(walker, t.index_type)
	case ^TSNamedTupleMember:
		ast_walk_leaf(walker, &t.label)
		ast_walk_ts_type(walker, t.element_type)
	case:
		ast_walk_ts_type_children_rest(walker, type)
	}
}

@(private = "file")
ast_walk_ts_type_children_rest :: proc(walker: ^AstWalker, type: ^TSType) {
	#partial switch t in type^ {
	case ^TSTypeQuery:
		ast_walk_expression(walker, t.expr_name)
		if arguments, present := t.type_parameters.?; present {
			ast_walk_ts_type_arguments(walker, arguments)
		}
	case ^TSMappedType:
		ast_walk_ts_type_parameter(walker, &t.type_parameter)
		if name_type, present := t.name_type.?; present { ast_walk_ts_type(walker, name_type) }
		if annotation, present := t.type_annotation.?; present {
			ast_walk_ts_type(walker, annotation)
		}
	case ^TSTemplateLiteralType:
		for &quasi, index in t.quasis {
			ast_walk_leaf(walker, &quasi)
			if index < len(t.types) { ast_walk_ts_type(walker, t.types[index]) }
		}
	case ^TSTypePredicate:
		ast_walk_expression(walker, t.parameter_name)
		if annotation, present := t.type_annotation.?; present {
			ast_walk_ts_annotation(walker, annotation)
		}
	case ^TSImportType:
		ast_walk_ts_type(walker, t.argument)
		ast_walk_expression(walker, ts_import_type_options(t))
		if qualifier, present := t.qualifier.?; present { ast_walk_expression(walker, qualifier) }
		if arguments, present := t.type_parameters.?; present {
			ast_walk_ts_type_arguments(walker, arguments)
		}
	}
	// TSKeywordType is a leaf.
}

@(private = "file")
ast_node_from_ts_type :: proc(type: ^TSType) -> AstNode {
	switch t in type^ {
	case ^TSKeywordType:         if t != nil { return t }
	case ^TSTypeReference:       if t != nil { return t }
	case ^TSUnionType:           if t != nil { return t }
	case ^TSIntersectionType:    if t != nil { return t }
	case ^TSArrayType:           if t != nil { return t }
	case ^TSTupleType:           if t != nil { return t }
	case ^TSFunctionType:        if t != nil { return t }
	case ^TSConstructorType:     if t != nil { return t }
	case ^TSTypeLiteral:         if t != nil { return t }
	case ^TSConditionalType:     if t != nil { return t }
	case ^TSInferType:           if t != nil { return t }
	case ^TSTypeQuery:           if t != nil { return t }
	case ^TSIndexedAccessType:   if t != nil { return t }
	case ^TSMappedType:          if t != nil { return t }
	case ^TSTypeOperator:        if t != nil { return t }
	case ^TSLiteralType:         if t != nil { return t }
	case ^TSTemplateLiteralType: if t != nil { return t }
	case ^TSParenthesizedType:   if t != nil { return t }
	case ^TSRestType:            if t != nil { return t }
	case ^TSOptionalType:        if t != nil { return t }
	case ^TSNamedTupleMember:    if t != nil { return t }
	case ^TSTypePredicate:       if t != nil { return t }
	case ^TSImportType:          if t != nil { return t }
	}
	return nil
}
