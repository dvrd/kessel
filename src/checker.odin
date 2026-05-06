package main

// ============================================================================
// Semantic Checker — Pass 3 of the kessel pipeline.
//
// Walks a finished AST and enforces ECMA-262 Early Errors that do NOT affect
// parsing decisions. The parser (pass 2) builds the tree permissively; this
// pass validates it.
//
// Architecture mirrors OXC's `oxc_semantic/src/checker/javascript.rs`:
// ancestor-walking checks rather than flag-threading during parse.
//
// First slice (this commit): break / continue context + label scoping.
//   • §13.9.1 — `break` only valid inside an IterationStatement, a
//     SwitchStatement, or a LabelledStatement that contains it.
//   • §13.9.2 — `continue` only valid inside an IterationStatement; the
//     labelled form additionally requires the target label to denote an
//     IterationStatement (§14.8.1).
//   • §14.13.1 — `break label;` / `continue label;` requires `label` to
//     name an enclosing LabelledStatement that is in scope. Labels do
//     NOT cross function boundaries (§14.13 — LabelSet is per-function).
//
// Future slices migrate the remaining inline checks out of parser.odin
// (super.x context, new.target context, duplicate __proto__ in object
// literal, strict-mode parameter validation, duplicate private members,
// duplicate parameter names, eval/arguments in strict mode, with statement
// in strict mode, duplicate exported names, ... — see parser.odin's
// report_semantic_error call sites).
//
// Implementation notes:
//   • Tree walker (recursive) modelled on the existing `pn_walk_*` family
//     in parser.odin (private-name verification). Recursion is bounded by
//     AST depth (typically <100 for real-world JS, <1000 even for the
//     deepest nesting we've measured in bench/real_world/).
//   • Errors are stored on the Checker (`c.errors`) and then appended to
//     `job.parser.errors` by `checker_run_for_job` so the existing emitter
//     and verifier infrastructure (`emit_errors`, the `Parse errors: N`
//     diagnostic line read by verify_test262_subset.js / verify_negative.js
//     / etc.) just works without further plumbing.
//   • Errors use ParseError so they share the existing diagnostic shape
//     (loc + message). The locations point at the offending keyword
//     (`break` / `continue`) or label identifier.
//   • Function / arrow / class-static-block boundaries reset the loop /
//     switch / label context (mirrors parser.odin lines 5681–5686).
//
// ============================================================================

import "core:mem"

// CheckerLabel — one label currently in scope.
//
// `is_iteration` records whether this label points at an
// IterationStatement (directly or via a chain of LabelledStatements).
// `continue label;` is only valid for iteration labels.
CheckerLabel :: struct {
	name:         string,
	is_iteration: bool,
	loc_offset:   u32, // for diagnostic targeting (unused today; kept for future "duplicate label" check)
}

// CheckerContext — mutable walker state. One context per parse; saves
// and restores around function / class-static-block boundaries.
//
// `iter_depth`: number of enclosing iteration statements (while / do /
//   for / for-in / for-of). break + continue (no label) consult this.
// `switch_depth`: number of enclosing switch statements. break (no label)
//   consults `iter_depth + switch_depth`.
// `label_floor`: index into `labels` below which labels are not visible.
//   Function entry pushes the floor to len(labels); function exit
//   restores it AND truncates labels back to that point.
// `lang`: the source language. Read by checks that branch on TS-mode
//   semantics (e.g. duplicate constructor: TS allows overload sigs to
//   repeat freely, only the SECOND implementation body is an error).
CheckerContext :: struct {
	iter_depth:   int,
	switch_depth: int,
	labels:       [dynamic]CheckerLabel,
	label_floor:  int,
	lang:         Lang,
}

Checker :: struct {
	errors:    [dynamic]ParseError,
	allocator: mem.Allocator,
}

init_checker :: proc(alloc: mem.Allocator) -> Checker {
	return Checker{
		errors    = make([dynamic]ParseError, 0, 8, alloc),
		allocator = alloc,
	}
}

// check_program is the entry point for the semantic checker.
// Call after parse_program to validate early errors.
check_program :: proc(c: ^Checker, program: ^Program, lang: Lang = .JS) {
	if program == nil { return }
	ctx: CheckerContext
	ctx.labels = make([dynamic]CheckerLabel, 0, 4, c.allocator)
	ctx.lang   = lang
	for stmt in program.body {
		ck_walk_stmt(c, &ctx, stmt)
	}
	// Sanity: every push/pop must balance. Unbalanced means a walker bug.
	assert(ctx.iter_depth == 0)
	assert(ctx.switch_depth == 0)
	assert(len(ctx.labels) == 0)
	assert(ctx.label_floor == 0)
}

// checker_run_for_job runs the checker against a parsed ParseJob and
// merges its findings into job.parser.errors so the existing emitter,
// `Parse errors: N` line, and verifier infrastructure don't need to
// change. Idempotent for already-checked jobs is NOT a goal — call once
// per parse_job_run.
checker_run_for_job :: proc(job: ^ParseJob) {
	if job == nil || job.program == nil { return }
	c := init_checker(job.arena_alloc)
	check_program(&c, job.program, job.lang)
	if len(c.errors) == 0 { return }
	for err in c.errors {
		bump_append(&job.parser.errors, err)
	}
}

// ============================================================================
// Helpers — error reporting + label resolution
// ============================================================================

@(private="file")
ck_report :: proc(c: ^Checker, loc_offset: u32, message: string) {
	bump_append(&c.errors, ParseError{
		loc     = LexerLoc(loc_offset),
		message = message,
	})
}

// label_is_iteration_target — does `stmt` (the body of a LabeledStatement)
// resolve to an IterationStatement, possibly through a chain of nested
// LabeledStatements? Per ECMA-262 §14.8.1 the LabelledItem of a label
// targeted by `continue label;` must be (or chain to) an iteration.
//
// Bounded loop: the chain length is at most the AST depth, which is
// already bounded by the parser. Each step either descends one
// LabelledStatement layer or returns. No recursion needed.
@(private="file")
label_is_iteration_target :: proc(stmt: ^Statement) -> bool {
	s := stmt
	for s != nil {
		#partial switch v in s^ {
		case ^WhileStatement, ^DoWhileStatement, ^ForStatement,
		     ^ForInStatement, ^ForOfStatement:
			return true
		case ^LabeledStatement:
			if v == nil { return false }
			s = v.body
		case:
			return false
		}
	}
	return false
}

// label_in_scope — does `name` refer to a LabelledStatement currently
// in scope (above the floor)?  Returns the matching label entry.
@(private="file")
label_in_scope :: proc(ctx: ^CheckerContext, name: string) -> (CheckerLabel, bool) {
	// Scan top-down so the innermost enclosing label wins (matters for
	// shadowing diagnostics in future slices; today every visible label
	// is unique within its function — duplicate-label check will land
	// in the next migration slice).
	for i := len(ctx.labels) - 1; i >= ctx.label_floor; i -= 1 {
		if ctx.labels[i].name == name {
			return ctx.labels[i], true
		}
	}
	return {}, false
}

// ck_enter_function — function-boundary push. Returns a snapshot to
// pass to ck_exit_function. Mirrors the `label_floor` save/restore
// pattern in parser.odin (parse_function_body).
@(private="file")
CheckerScopeSave :: struct {
	iter_depth:   int,
	switch_depth: int,
	label_floor:  int,
	label_len:    int,
}

@(private="file")
ck_enter_function :: proc(ctx: ^CheckerContext) -> CheckerScopeSave {
	saved := CheckerScopeSave{
		iter_depth   = ctx.iter_depth,
		switch_depth = ctx.switch_depth,
		label_floor  = ctx.label_floor,
		label_len    = len(ctx.labels),
	}
	ctx.iter_depth   = 0
	ctx.switch_depth = 0
	ctx.label_floor  = len(ctx.labels)
	return saved
}

@(private="file")
ck_exit_function :: proc(ctx: ^CheckerContext, saved: CheckerScopeSave) {
	ctx.iter_depth   = saved.iter_depth
	ctx.switch_depth = saved.switch_depth
	ctx.label_floor  = saved.label_floor
	// Truncate any labels pushed inside the function body that weren't
	// popped (defensive — the LabeledStatement walker pops on exit, so
	// this should already be a no-op).
	resize(&ctx.labels, saved.label_len)
}

// ============================================================================
// Statement walker
// ============================================================================

@(private="file")
ck_walk_stmt :: proc(c: ^Checker, ctx: ^CheckerContext, stmt: ^Statement) {
	if stmt == nil { return }
	switch v in stmt^ {
	case ^BreakStatement:
		if v == nil { return }
		if lbl, have := v.label.(LabelIdentifier); have {
			if entry, ok := label_in_scope(ctx, lbl.name); !ok {
				_ = entry
				ck_report(c, u32(v.loc.span.start), "Undefined label")
			}
		} else {
			if ctx.iter_depth == 0 && ctx.switch_depth == 0 {
				ck_report(c, u32(v.loc.span.start), "Illegal break statement: not in a loop or switch")
			}
		}

	case ^ContinueStatement:
		if v == nil { return }
		if lbl, have := v.label.(LabelIdentifier); have {
			entry, ok := label_in_scope(ctx, lbl.name)
			if !ok {
				ck_report(c, u32(v.loc.span.start), "Undefined label")
			} else if !entry.is_iteration {
				ck_report(c, u32(v.loc.span.start), "Illegal continue statement: label does not target an iteration statement")
			}
		} else {
			if ctx.iter_depth == 0 {
				ck_report(c, u32(v.loc.span.start), "Illegal continue statement: not in a loop")
			}
		}

	case ^LabeledStatement:
		if v == nil { return }
		entry := CheckerLabel{
			name         = v.label.name,
			is_iteration = label_is_iteration_target(v.body),
			loc_offset   = u32(v.label.loc.span.start),
		}
		bump_append_ck(ctx, entry)
		ck_walk_stmt(c, ctx, v.body)
		if len(ctx.labels) > 0 {
			pop(&ctx.labels)
		}

	case ^BlockStatement:
		if v == nil { return }
		for s in v.body { ck_walk_stmt(c, ctx, s) }

	case ^IfStatement:
		if v == nil { return }
		ck_walk_expr(c, ctx, v.test)
		ck_walk_stmt(c, ctx, v.consequent)
		if alt, have := v.alternate.(^Statement); have && alt != nil {
			ck_walk_stmt(c, ctx, alt)
		}

	case ^WhileStatement:
		if v == nil { return }
		ck_walk_expr(c, ctx, v.test)
		ctx.iter_depth += 1
		ck_walk_stmt(c, ctx, v.body)
		ctx.iter_depth -= 1

	case ^DoWhileStatement:
		if v == nil { return }
		ctx.iter_depth += 1
		ck_walk_stmt(c, ctx, v.body)
		ctx.iter_depth -= 1
		ck_walk_expr(c, ctx, v.test)

	case ^ForStatement:
		if v == nil { return }
		if e, have := v.init_expr.(^Expression); have && e != nil { ck_walk_expr(c, ctx, e) }
		if d, have := v.init_decl.(^VariableDeclaration); have && d != nil { ck_walk_var_decl(c, ctx, d) }
		if t, have := v.test.(^Expression); have && t != nil { ck_walk_expr(c, ctx, t) }
		if u, have := v.update.(^Expression); have && u != nil { ck_walk_expr(c, ctx, u) }
		ctx.iter_depth += 1
		ck_walk_stmt(c, ctx, v.body)
		ctx.iter_depth -= 1

	case ^ForInStatement:
		if v == nil { return }
		if e, have := v.left_expr.(^Expression); have && e != nil { ck_walk_expr(c, ctx, e) }
		if d, have := v.left_decl.(^VariableDeclaration); have && d != nil { ck_walk_var_decl(c, ctx, d) }
		ck_walk_expr(c, ctx, v.right)
		ctx.iter_depth += 1
		ck_walk_stmt(c, ctx, v.body)
		ctx.iter_depth -= 1

	case ^ForOfStatement:
		if v == nil { return }
		if e, have := v.left_expr.(^Expression); have && e != nil { ck_walk_expr(c, ctx, e) }
		if d, have := v.left_decl.(^VariableDeclaration); have && d != nil { ck_walk_var_decl(c, ctx, d) }
		ck_walk_expr(c, ctx, v.right)
		ctx.iter_depth += 1
		ck_walk_stmt(c, ctx, v.body)
		ctx.iter_depth -= 1

	case ^SwitchStatement:
		if v == nil { return }
		ck_walk_expr(c, ctx, v.discriminant)
		ck_check_switch_default_dups(c, v)
		ctx.switch_depth += 1
		for sc in v.cases {
			if t, have := sc.test.(^Expression); have && t != nil { ck_walk_expr(c, ctx, t) }
			for s in sc.consequent { ck_walk_stmt(c, ctx, s) }
		}
		ctx.switch_depth -= 1

	case ^ReturnStatement:
		if v == nil { return }
		if e, have := v.argument.(^Expression); have && e != nil { ck_walk_expr(c, ctx, e) }

	case ^ThrowStatement:
		if v != nil { ck_walk_expr(c, ctx, v.argument) }

	case ^TryStatement:
		if v == nil { return }
		for s in v.block.body { ck_walk_stmt(c, ctx, s) }
		if h, have := v.handler.(CatchClause); have {
			for s in h.body.body { ck_walk_stmt(c, ctx, s) }
		}
		if f, have := v.finalizer.(BlockStatement); have {
			for s in f.body { ck_walk_stmt(c, ctx, s) }
		}

	case ^WithStatement:
		if v == nil { return }
		ck_walk_expr(c, ctx, v.object)
		ck_walk_stmt(c, ctx, v.body)

	case ^ExpressionStatement:
		if v != nil { ck_walk_expr(c, ctx, v.expression) }

	case ^VariableDeclaration:
		if v != nil { ck_walk_var_decl(c, ctx, v) }

	case ^FunctionDeclaration:
		if v != nil { ck_walk_function(c, ctx, &v.expr) }

	case ^ClassDeclaration:
		if v != nil { ck_walk_class(c, ctx, &v.expr) }

	case ^ExportNamedDeclaration:
		if v == nil { return }
		if d, have := v.declaration.(^Declaration); have && d != nil {
			ck_walk_export_decl(c, ctx, d)
		}
		// ExportSpecifiers reference identifier names only — no break /
		// continue / labels possible inside.

	case ^ExportDefaultDeclaration:
		if v == nil || v.declaration == nil { return }
		#partial switch inner in v.declaration^ {
		case ^Expression:  if inner != nil { ck_walk_expr(c, ctx, inner) }
		case ^Declaration: if inner != nil { ck_walk_export_decl(c, ctx, inner) }
		}

	case ^EmptyStatement, ^DebuggerStatement,
	     ^ImportDeclaration, ^ExportAllDeclaration,
	     ^TSInterfaceDeclaration, ^TSTypeAliasDeclaration,
	     ^TSEnumDeclaration, ^TSModuleDeclaration,
	     ^TSImportEqualsDeclaration,
	     ^TSExportAssignment, ^TSNamespaceExportDeclaration:
		// No iteration / switch / label / function bodies inside these
		// for break/continue purposes. (TS namespace bodies CAN contain
		// statements but the parser builds them as Statements that
		// would be visited via TSModuleDeclaration's body in a future
		// slice; today these checks don't apply across TS namespace
		// boundaries.)
		return
	}
}

@(private="file")
ck_walk_export_decl :: proc(c: ^Checker, ctx: ^CheckerContext, d: ^Declaration) {
	if d == nil { return }
	#partial switch inner in d^ {
	case ^FunctionDeclaration: if inner != nil { ck_walk_function(c, ctx, &inner.expr) }
	case ^ClassDeclaration:    if inner != nil { ck_walk_class(c, ctx, &inner.expr) }
	case ^VariableDeclaration: if inner != nil { ck_walk_var_decl(c, ctx, inner) }
	}
}

@(private="file")
ck_walk_var_decl :: proc(c: ^Checker, ctx: ^CheckerContext, decl: ^VariableDeclaration) {
	if decl == nil { return }
	for d in decl.declarations {
		if init, have := d.init.(^Expression); have && init != nil {
			ck_walk_expr(c, ctx, init)
		}
	}
}

// ============================================================================
// Expression walker
// ============================================================================

@(private="file")
ck_walk_expr :: proc(c: ^Checker, ctx: ^CheckerContext, expr: ^Expression) {
	if expr == nil { return }
	#partial switch e in expr^ {
	case ^FunctionExpression:
		if e != nil { ck_walk_function(c, ctx, e) }

	case ^ArrowFunctionExpression:
		if e == nil { return }
		// Arrow function = function boundary for break/continue/labels.
		saved := ck_enter_function(ctx)
		for pr in e.params {
			if d, have := pr.default_val.(^Expression); have && d != nil { ck_walk_expr(c, ctx, d) }
		}
		#partial switch body in e.body {
		case ^Expression:     if body != nil { ck_walk_expr(c, ctx, body) }
		case ^BlockStatement: if body != nil { for s in body.body { ck_walk_stmt(c, ctx, s) } }
		}
		ck_exit_function(ctx, saved)

	case ^ClassExpression:
		if e != nil { ck_walk_class(c, ctx, e) }

	case ^MemberExpression:
		if e == nil { return }
		ck_check_member_super_private(c, e)
		ck_walk_expr(c, ctx, e.object)
		if e.computed && e.property != nil { ck_walk_expr(c, ctx, e.property) }

	case ^CallExpression:
		if e == nil { return }
		ck_walk_expr(c, ctx, e.callee)
		for a in e.arguments { ck_walk_expr(c, ctx, a) }

	case ^NewExpression:
		if e == nil { return }
		ck_walk_expr(c, ctx, e.callee)
		for a in e.arguments { ck_walk_expr(c, ctx, a) }

	case ^ConditionalExpression:
		if e == nil { return }
		ck_walk_expr(c, ctx, e.test)
		ck_walk_expr(c, ctx, e.consequent)
		ck_walk_expr(c, ctx, e.alternate)

	case ^BinaryExpression:
		if e == nil { return }
		ck_walk_expr(c, ctx, e.left)
		ck_walk_expr(c, ctx, e.right)

	case ^LogicalExpression:
		if e == nil { return }
		ck_walk_expr(c, ctx, e.left)
		ck_walk_expr(c, ctx, e.right)

	case ^AssignmentExpression:
		if e == nil { return }
		ck_walk_expr(c, ctx, e.left)
		ck_walk_expr(c, ctx, e.right)

	case ^SequenceExpression:
		if e != nil { for s in e.expressions { ck_walk_expr(c, ctx, s) } }

	case ^ArrayExpression:
		if e == nil { return }
		for el in e.elements {
			if inner, have := el.(^Expression); have && inner != nil { ck_walk_expr(c, ctx, inner) }
		}

	case ^ObjectExpression:
		if e == nil { return }
		ck_check_object_proto_dups(c, e)
		for prop in e.properties {
			// Computed key contains an expression; non-computed key is
			// an Identifier / literal — visit both so nested function
			// expressions inside computed keys are still walked.
			if prop.key != nil { ck_walk_expr(c, ctx, prop.key) }
			if prop.value != nil { ck_walk_expr(c, ctx, prop.value) }
		}

	case ^SpreadElement:
		if e != nil { ck_walk_expr(c, ctx, e.argument) }

	case ^UnaryExpression:
		if e == nil { return }
		ck_check_unary_delete_private(c, e)
		ck_walk_expr(c, ctx, e.argument)
	case ^UpdateExpression:          if e != nil { ck_walk_expr(c, ctx, e.argument) }
	case ^ParenthesizedExpression:   if e != nil { ck_walk_expr(c, ctx, e.expression) }
	case ^AwaitExpression:           if e != nil { ck_walk_expr(c, ctx, e.argument) }
	case ^YieldExpression:
		if e == nil { return }
		if a, have := e.argument.(^Expression); have && a != nil { ck_walk_expr(c, ctx, a) }
	case ^ChainExpression:           if e != nil { ck_walk_expr(c, ctx, e.expression) }
	case ^TaggedTemplateExpression:
		if e == nil { return }
		ck_walk_expr(c, ctx, e.tag)
		ck_walk_expr(c, ctx, e.quasi)
	case ^TemplateLiteral:
		if e != nil { for s in e.expressions { ck_walk_expr(c, ctx, s) } }
	case ^ImportExpression:
		if e == nil { return }
		ck_walk_expr(c, ctx, e.source)
		ck_walk_expr(c, ctx, e.options)

	case ^TSAsExpression:            if e != nil { ck_walk_expr(c, ctx, e.expression) }
	case ^TSSatisfiesExpression:     if e != nil { ck_walk_expr(c, ctx, e.expression) }
	case ^TSNonNullExpression:       if e != nil { ck_walk_expr(c, ctx, e.expression) }
	case ^TSTypeAssertion:           if e != nil { ck_walk_expr(c, ctx, e.expression) }
	case ^TSInstantiationExpression: if e != nil { ck_walk_expr(c, ctx, e.expression) }

	case ^JSXElement:
		if e == nil { return }
		if e.opening_element != nil {
			for attr in e.opening_element.attributes {
				ck_walk_jsx_attr(c, ctx, attr)
			}
		}
		for child in e.children {
			ck_walk_jsx_child(c, ctx, child)
		}

	case ^JSXFragment:
		if e == nil { return }
		for child in e.children {
			ck_walk_jsx_child(c, ctx, child)
		}

	// Leaf / literal-shape — nothing to walk for break/continue purposes:
	//   NullLiteral, BooleanLiteral, NumericLiteral, StringLiteral,
	//   BigIntLiteral, RegExpLiteral, Identifier, PrivateIdentifier,
	//   ThisExpression, Super, MetaProperty, JSXText,
	//   JSXExpressionContainer (visited via JSXElement child walk),
	//   JSXEmptyExpression, JSXSpreadChild.
	}
}

@(private="file")
ck_walk_jsx_child :: proc(c: ^Checker, ctx: ^CheckerContext, child: JSXChild) {
	#partial switch v in child {
	case ^JSXElement:
		if v == nil { return }
		if v.opening_element != nil {
			for attr in v.opening_element.attributes { ck_walk_jsx_attr(c, ctx, attr) }
		}
		for ch in v.children { ck_walk_jsx_child(c, ctx, ch) }
	case ^JSXFragment:
		if v == nil { return }
		for ch in v.children { ck_walk_jsx_child(c, ctx, ch) }
	case ^JSXExpressionContainer:
		if v != nil && v.expression != nil { ck_walk_expr(c, ctx, v.expression) }
	case ^JSXSpreadChild:
		if v != nil { ck_walk_expr(c, ctx, v.expression) }
	// ^JSXText is a leaf.
	}
}

@(private="file")
ck_walk_jsx_attr :: proc(c: ^Checker, ctx: ^CheckerContext, attr: JSXAttributeItem) {
	#partial switch a in attr {
	case JSXAttribute:
		// JSXAttribute.value is Maybe(^Expression). The Expression itself
		// may be a StringLiteral (literal attr value), JSXExpressionContainer
		// (curly-brace value), or JSXElement (nested element value). All are
		// covered by the regular Expression walker.
		if val, have := a.value.(^Expression); have && val != nil {
			ck_walk_expr(c, ctx, val)
		}
	case ^JSXSpreadAttribute:
		if a != nil && a.argument != nil { ck_walk_expr(c, ctx, a.argument) }
	}
}

// ============================================================================
// Function / class boundary walks
// ============================================================================

@(private="file")
ck_walk_function :: proc(c: ^Checker, ctx: ^CheckerContext, fn: ^FunctionExpression) {
	if fn == nil { return }
	saved := ck_enter_function(ctx)
	for pr in fn.params {
		if d, have := pr.default_val.(^Expression); have && d != nil { ck_walk_expr(c, ctx, d) }
	}
	if !fn.no_body {
		for s in fn.body.body { ck_walk_stmt(c, ctx, s) }
	}
	ck_exit_function(ctx, saved)
}

@(private="file")
ck_walk_class :: proc(c: ^Checker, ctx: ^CheckerContext, cls: ^ClassExpression) {
	if cls == nil { return }
	// super_class is evaluated in the OUTER scope (no function boundary).
	if sc, have := cls.super_class.(^Expression); have && sc != nil {
		ck_walk_expr(c, ctx, sc)
	}
	// Whole-class checks: §15.7.1 — at most one constructor (with TS
	// overload-signature exception). Migrated from parser.odin in slice 4.
	ck_check_class_constructors(c, ctx, cls)

	for elem in cls.body.body {
		// Per-element accessor early-error checks (§15.4.3 / §15.4.4 /
		// §15.4.5). Migrated from parser.odin in slice 3 — keeps the
		// parser to syntax errors only.
		ck_check_accessor(c, elem)

		// Computed keys are evaluated in the outer scope (no function boundary).
		if elem.computed && elem.key != nil {
			ck_walk_expr(c, ctx, elem.key)
		}
		// Element value:
		//   * Method body → ^FunctionExpression (boundary established by ck_walk_function).
		//   * Static block → ^FunctionExpression with no params, kind=.StaticBlock.
		//   * Field initializer → arbitrary expression. Break/continue
		//     can only appear inside a nested function body, which itself
		//     establishes a boundary, so an extra wrap here would be redundant.
		if v, have := elem.value.(^Expression); have && v != nil {
			ck_walk_expr(c, ctx, v)
		}
	}
}

// Validate getter / setter accessor arity + setter rest / initializer
// per ECMA-262 §15.4.3 (Getter), §15.4.4 (Setter arity),
// §15.4.5 (Setter parameter shape).
//
// A leading TS `this` parameter is a type-only declaration (TS
// extension; impossible in JS because `this` is a reserved word, so the
// parser would have already rejected it). Skip it for arity counting
// and addressing into the real parameter list.
//
// Diagnostic locations:
//   * Arity errors anchor at the property key (the `get foo` / `set foo`
//     identifier). For static blocks elem.key is nil but kind is
//     StaticBlock, not Get/Set, so the early `kind != Get/Set` guard
//     means we never read elem.key as nil here.
//   * Setter param shape errors anchor at the parameter span.
@(private="file")
ck_check_accessor :: proc(c: ^Checker, elem: ClassElement) {
	if elem.kind != .Get && elem.kind != .Set { return }

	// Get/Set elements always store a ^FunctionExpression in elem.value
	// (parse_method_body builds it). Defensive nil checks anyway.
	fn_expr, have_expr := elem.value.(^Expression)
	if !have_expr || fn_expr == nil { return }
	fn, is_fn := fn_expr^.(^FunctionExpression)
	if !is_fn || fn == nil { return }

	real_idx := 0
	real_n   := len(fn.params)
	if len(fn.params) > 0 {
		if id, is_id := fn.params[0].pattern.(^Identifier); is_id && id != nil && id.name == "this" {
			real_idx = 1
			real_n  -= 1
		}
	}

	key_loc: u32 = 0
	if elem.key != nil {
		key_loc = u32(get_expression_loc(elem.key).span.start)
	} else {
		key_loc = u32(elem.loc.span.start)
	}

	if elem.kind == .Get && real_n != 0 {
		ck_report(c, key_loc, "Getter must not have any formal parameters")
		return
	}
	if elem.kind == .Set {
		if real_n != 1 {
			ck_report(c, key_loc, "Setter must have exactly one formal parameter")
			return
		}
		param := fn.params[real_idx]
		param_loc := u32(param.loc.span.start)
		if _, is_rest := param.pattern.(^RestElement); is_rest {
			ck_report(c, param_loc, "Setter parameter cannot be a rest element")
		}
		if _, has_default := param.default_val.(^Expression); has_default {
			ck_report(c, param_loc, "A 'set' accessor cannot have an initializer.")
		}
	}
}

// ============================================================================
// Slice 4 — local AST-only early-error checks.
//
// Each helper looks at a single AST node (no ancestor context required
// beyond what the walker already tracks) and reports any §-conformance
// violations it finds. These checks were previously inline
// `report_semantic_error*` calls in src/parser.odin; the migration
// honours the architectural rule
//
//   * parser  = syntax errors
//   * checker = semantic / early errors
//
// so the parser stays a pure tree builder.
// ============================================================================

// §13.2.5.1 — an ObjectLiteral may not contain more than one
// PropertyDefinition whose PropertyName is the literal identifier /
// string `__proto__` and whose kind is `init`. Methods, getters,
// setters, computed keys, and the `{ __proto__ }` shorthand do not
// participate. The diagnostic anchors at the duplicate key (matching
// V8 / Acorn / OXC).
//
// Note: this check used to live in parser.odin behind a
// `pending_proto_dups` list because object literals could be promoted
// to ObjectPatterns (where Annex B.3.1 makes the duplicate legal).
// Post-parse the AST already distinguishes ObjectExpression from
// ObjectPattern, so the pending machinery is unnecessary here.
@(private="file")
ck_check_object_proto_dups :: proc(c: ^Checker, obj: ^ObjectExpression) {
	if obj == nil { return }
	proto_seen := false
	for i := 0; i < len(obj.properties); i += 1 {
		prop := &obj.properties[i]
		if !property_is_literal_proto_init(prop) { continue }
		if proto_seen {
			err_off := loc_from_expr(prop.key).span.start
			ck_report(c, u32(err_off), "Redefinition of __proto__ property")
		} else {
			proto_seen = true
		}
	}
}

// §14.12.1 — a SwitchStatement may have at most one DefaultClause.
// Locations anchor at the `default` keyword (which the parser stores
// as the case's loc.span.start; SwitchCase.test == nil signals default).
@(private="file")
ck_check_switch_default_dups :: proc(c: ^Checker, sw: ^SwitchStatement) {
	if sw == nil { return }
	default_seen := false
	for i := 0; i < len(sw.cases); i += 1 {
		sc := &sw.cases[i]
		if _, have := sc.test.(^Expression); have { continue } // not a default
		if default_seen {
			ck_report(c, u32(sc.loc.span.start), "More than one default clause in switch")
		} else {
			default_seen = true
		}
	}
}

// §15.7.1 — at most one constructor per class. Detect by name
// ("constructor") + non-static + non-computed + (kind == .Method or
// .Constructor). Static methods named "constructor" do NOT count.
//
// TS exception (handled when ctx.lang ∈ {.TS, .TSX}): TypeScript allows
// any number of overload-signature constructor declarations (empty
// body) preceding ONE implementation (non-empty body). Only a SECOND
// implementation is an error. This is the same rule the parser used to
// enforce inline; preserving it here matches OXC's typescript-eslint
// behaviour and keeps the corpus's "Duplicate constructor" cluster at
// zero kessel-only-rejects.
@(private="file")
ck_check_class_constructors :: proc(c: ^Checker, ctx: ^CheckerContext, cls: ^ClassExpression) {
	if cls == nil { return }
	ts_mode := ctx.lang == .TS || ctx.lang == .TSX
	constructor_seen := false
	constructor_implementation_seen := false
	for elem in cls.body.body {
		if elem.key == nil { continue }
		if elem.static || elem.computed { continue }
		if elem.kind != .Method && elem.kind != .Constructor { continue }
		if class_element_prop_name(elem.key) != "constructor" { continue }

		has_body := false
		if val_expr, vok := elem.value.(^Expression); vok && val_expr != nil {
			if fn, fok := val_expr^.(^FunctionExpression); fok && fn != nil {
				has_body = len(fn.body.body) > 0 || fn.body.loc.span.end > fn.body.loc.span.start
			}
		}

		loc := u32(get_expression_loc(elem.key).span.start)
		if ts_mode {
			if has_body && constructor_implementation_seen {
				ck_report(c, loc, "Duplicate constructor implementation in class")
			}
			if has_body { constructor_implementation_seen = true }
			constructor_seen = true
		} else {
			if constructor_seen {
				ck_report(c, loc, "Duplicate constructor in class")
			} else {
				constructor_seen = true
			}
		}
	}
}

// §13.5.1 — `delete o.#priv` / `delete this.#priv` is ALWAYS a
// SyntaxError, regardless of strict / sloppy mode. Private slots
// cannot be removed. Diagnostic anchors at the unary operator.
@(private="file")
ck_check_unary_delete_private :: proc(c: ^Checker, e: ^UnaryExpression) {
	if e == nil { return }
	if e.operator != .Delete { return }
	if e.argument == nil { return }
	me, is_member := e.argument^.(^MemberExpression)
	if !is_member || me == nil { return }
	if me.property == nil { return }
	if _, is_private := me.property^.(^PrivateIdentifier); is_private {
		ck_report(c, u32(e.loc.span.start), "Private fields cannot be deleted")
	}
}

// §15.7.3 — `super.#name` is a SyntaxError. PrivateNames may only be
// accessed via `this`, a local variable, or a computed member
// expression — never through `super`. The diagnostic anchors at the
// member expression (matching the original parser-side anchor).
@(private="file")
ck_check_member_super_private :: proc(c: ^Checker, e: ^MemberExpression) {
	if e == nil || e.object == nil || e.property == nil { return }
	if e.computed { return }
	if _, is_super := e.object^.(^Super); !is_super { return }
	if _, is_private := e.property^.(^PrivateIdentifier); is_private {
		ck_report(c, u32(e.loc.span.start), "Private fields cannot be accessed through 'super'")
	}
}

// ============================================================================
// Append helper — mirrors parser.odin's bump_append shape, but for the
// CheckerContext label stack which uses the checker's allocator.
// ============================================================================

@(private="file")
bump_append_ck :: proc(ctx: ^CheckerContext, label: CheckerLabel) {
	append(&ctx.labels, label)
}
