package kessel

// A loop head can supply an initializer. A later assignment can only serve as
// initialization when it executes in the same scope as the declaration.
SemanticLetDeclaration :: struct {
	declaration: ^VariableDeclaration,
	scope: ScopeId,
	loop_head: bool,
}
SemanticLetAssignment :: struct { target: ^Expression, scope: ScopeId }
SemanticLetUses :: struct {
	declarations: [dynamic]SemanticLetDeclaration,
	assignments: [dynamic]SemanticLetAssignment,
	eval_scopes: map[ScopeId]bool,
}

sem_note_let_expression :: proc(ctx: ^SemCtx, expr: ^Expression) {
	#partial switch e in expr^ {
	case ^ConditionalExpression, ^LogicalExpression, ^SequenceExpression, ^ArrayExpression:
		ctx.let_barrier = ctx.cur_scope
	case ^AssignmentExpression:
		if e == nil || e.operator != .Assign { return }
		if blocked, ok := ctx.let_barrier.?; ok && blocked == ctx.cur_scope { return }
		append(&ctx.let_uses.assignments, SemanticLetAssignment{e.left, ctx.cur_scope})
	case ^CallExpression:
		if e == nil || e.optional { return }
		callee := semantic_runtime_expression(e.callee)
		if callee == nil { return }
		id, ok := callee^.(^Identifier)
		if !ok || id == nil || id.name != "eval" { return }
		// Direct eval can write a visible binding without an identifier in this AST.
		scope := ctx.cur_scope
		for _ in 0..<len(ctx.model.scopes) {
			if ctx.let_uses.eval_scopes[scope] { break }
			ctx.let_uses.eval_scopes[scope] = true
			if scope == SCOPE_ROOT { break }
			scope = ctx.model.scopes[scope].parent
		}
	}
}
