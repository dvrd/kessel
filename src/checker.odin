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
// `strict_mode`: ECMA-262 §10.2.1 "strict mode code". Initially set from
//   the program prologue (or forced true for Module source-type / class
//   bodies / class field initializers). Function bodies push a new value
//   when their own prologue contains `"use strict"`. Read by every
//   strict-mode-only early error (with statement, legacy octal literal,
//   octal escape in string / template, function decl as labeled item).
// `in_tagged_template`: gate for octal-escape diagnostics inside template
//   literals. Tagged templates are exempt from the octal-escape ban
//   (§12.9.6) because the tag receives the raw spans verbatim. Set
//   around the .quasi walk in the ^TaggedTemplateExpression case.
// `function_depth`: number of enclosing non-arrow function bodies (§10.2.3).
//   `new.target` is valid iff this is > 0. Arrow functions inherit
//   [[NewTarget]] from their enclosing scope and do NOT increment.
// `in_method`: do we have a [[HomeObject]] in scope? Set inside class
//   methods (§15.7.3), class field initialisers (§15.7.10), class static
//   blocks (§15.7.5), and object-literal methods / accessors (§13.2.5).
//   Inherited by nested arrows; reset by nested non-arrow functions.
// `in_derived_constructor`: are we in the instance constructor body of a
//   class with `extends` (§15.7.6)? `super(...)` is valid only here.
//   Inherited by nested arrows; reset by nested non-arrow functions.
// `in_field_init`: are we evaluating a class field initialiser (§15.7.10)?
//   `arguments` as IdentifierReference is forbidden here. Inherited by
//   nested arrows; reset by nested non-arrow functions and by nested
//   ClassExpressions (which start their own scope).
// `in_class_static_block`: are we inside a class static block body
//   (§15.7.5)? `arguments` and the `await` IdentifierReference are
//   forbidden here. Inherited by arrows; reset by nested functions.
// `in_params`: are we walking a function's formal-parameter list?
//   YieldExpression / AwaitExpression nodes encountered here violate
//   §15.5.1 / §15.6.1 / §15.8.1 / §15.9.1 (FormalParameters Contains
//   YieldExpression / AwaitExpression is a SyntaxError). Cleared on
//   entry to the function BODY so yield/await inside the body fires
//   normally.
// `params_is_arrow`: discriminant for the param-shape diagnostic.
//   Arrow-param diagnostics use a slightly different message than
//   regular-function-param diagnostics; this flag picks the right one.
CheckerContext :: struct {
	iter_depth:            int,
	switch_depth:          int,
	labels:                [dynamic]CheckerLabel,
	label_floor:           int,
	lang:                  Lang,
	strict_mode:           bool,
	in_tagged_template:    bool,
	function_depth:        int,
	in_method:             bool,
	in_derived_constructor: bool,
	in_field_init:         bool,
	in_class_static_block: bool,
	in_params:             bool,
	params_is_arrow:       bool,
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
	// §10.2.1 + §16.2.2 — strict-mode initialisation:
	//   * Module code is always strict (§16.2.2).
	//   * Otherwise, a `"use strict"` directive at the program
	//     prologue puts the whole script in strict mode.
	if program.type == .Module {
		ctx.strict_mode = true
	} else if directives_have_use_strict(program.directives[:]) {
		ctx.strict_mode = true
	}
	for stmt in program.body {
		ck_walk_stmt(c, &ctx, stmt)
	}
	// Sanity: every push/pop must balance. Unbalanced means a walker bug.
	assert(ctx.iter_depth == 0)
	assert(ctx.switch_depth == 0)
	assert(len(ctx.labels) == 0)
	assert(ctx.label_floor == 0)
}

// directives_have_use_strict scans a directive prologue (Program- or
// FunctionBody-level) for the literal `"use strict"` token.
@(private="file")
directives_have_use_strict :: proc(dirs: []Directive) -> bool {
	for d in dirs {
		if d.value.value == "use strict" { return true }
	}
	return false
}

// fn_body_lifts_strict — does a function body's directive prologue
// contain a `"use strict"` directive?
//
// The parser DOES set `ExpressionStatement.directive` to the cooked
// string of any prologue directive (parse_program, parse_function_body)
// but it does NOT populate `FunctionBody.directives` — see
// parser.odin's empty `directives = make([dynamic]Directive, 0, 0, ...)`
// initialisations at lines 3938 / 4350. So we walk the body's leading
// ExpressionStatement-with-directive run.
@(private="file")
fn_body_lifts_strict :: proc(body: FunctionBody) -> bool {
	for stmt in body.body {
		if stmt == nil { return false }
		es, ok := stmt^.(^ExpressionStatement)
		if !ok || es == nil { return false }
		if es.directive == "" { return false } // prologue ended
		if es.directive == "use strict" { return true }
	}
	return false
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
//
// `strict_mode` is also threaded through the save: function bodies can
// LIFT strict mode (a `"use strict"` directive in the body sets the
// flag for the body's lexical scope only) but never lower it (a body
// inside an already-strict scope can't escape strict by lacking the
// directive). The save/restore pattern naturally implements both rules.
@(private="file")
CheckerScopeSave :: struct {
	iter_depth:            int,
	switch_depth:          int,
	label_floor:           int,
	label_len:             int,
	strict_mode:           bool,
	in_method:             bool,
	in_derived_constructor: bool,
	in_field_init:         bool,
	in_class_static_block: bool,
}

@(private="file")
ck_enter_function :: proc(ctx: ^CheckerContext) -> CheckerScopeSave {
	saved := CheckerScopeSave{
		iter_depth             = ctx.iter_depth,
		switch_depth           = ctx.switch_depth,
		label_floor            = ctx.label_floor,
		label_len              = len(ctx.labels),
		strict_mode            = ctx.strict_mode,
		in_method              = ctx.in_method,
		in_derived_constructor = ctx.in_derived_constructor,
		in_field_init          = ctx.in_field_init,
		in_class_static_block  = ctx.in_class_static_block,
	}
	ctx.iter_depth   = 0
	ctx.switch_depth = 0
	ctx.label_floor  = len(ctx.labels)
	return saved
}

@(private="file")
ck_exit_function :: proc(ctx: ^CheckerContext, saved: CheckerScopeSave) {
	ctx.iter_depth             = saved.iter_depth
	ctx.switch_depth           = saved.switch_depth
	ctx.label_floor            = saved.label_floor
	ctx.strict_mode            = saved.strict_mode
	ctx.in_method              = saved.in_method
	ctx.in_derived_constructor = saved.in_derived_constructor
	ctx.in_field_init          = saved.in_field_init
	ctx.in_class_static_block  = saved.in_class_static_block
	// Truncate any labels pushed inside the function body that weren't
	// popped (defensive — the LabeledStatement walker pops on exit, so
	// this should already be a no-op).
	resize(&ctx.labels, saved.label_len)
}

// CkFnKind — caller's classification of a non-arrow function body, so
// ck_walk_function can set up the [[HomeObject]] / constructor / static-
// block flags appropriately. Plain functions reset everything; class
// methods / static blocks lift the relevant flag for their body and
// rely on the save/restore to scrub it on exit (and on a nested plain
// function entry).
CkFnKind :: enum {
	Plain,
	Method,
	Constructor,
	StaticBlock,
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
		// §14.13.1 — in strict mode, a LabelledItem may not be a plain
		// FunctionDeclaration. Async / generator decls are syntax errors
		// regardless of strictness and stay a parser-side `report_error`.
		if ctx.strict_mode && v.body != nil {
			if fn, is_fn := v.body^.(^FunctionDeclaration); is_fn && fn != nil {
				if !fn.async && !fn.generator {
					ck_report(c, u32(fn.loc.span.start), "Function declaration cannot be a labeled item in strict mode")
				}
			}
		}
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
		// §14.11.1 — WithStatement is forbidden in strict mode.
		if ctx.strict_mode {
			ck_report(c, u32(v.loc.span.start), "'with' statements are not allowed in strict mode")
		}
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
	// §14.3.1.1 — BoundNames of a LexicalDeclaration must not contain
	// `"let"`. `var let;` stays legal (Annex B.3.4.4); `let let;` and
	// `const let;` are SyntaxErrors regardless of strict mode.
	ck_check_var_decl_let_binding(c, decl)
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
		// Arrow block-body "use strict" prologue: parse_block_statement does
		// NOT set ExpressionStatement.directive (only parse_function_body /
		// parse_program do), and the parser itself never lifts strict_mode
		// for arrow block bodies. Match that behaviour here — arrow bodies
		// inherit the surrounding strict mode but never lift it.
		prev_in_params  := ctx.in_params
		prev_arrow_par  := ctx.params_is_arrow
		ctx.in_params       = true
		ctx.params_is_arrow = true
		for pr in e.params {
			ck_walk_pattern(c, ctx, pr.pattern)
			if d, have := pr.default_val.(^Expression); have && d != nil { ck_walk_expr(c, ctx, d) }
		}
		ctx.in_params       = prev_in_params
		ctx.params_is_arrow = prev_arrow_par
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
		ck_check_super_call(c, ctx, e)
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
			// Walk COMPUTED keys (their inner expression can reference
			// arbitrary identifiers, including super/arguments/yield).
			// Non-computed keys are name-bearing — the inner ^Identifier
			// is a label, not an IdentifierReference, so walking it would
			// false-fire the slice-6 `arguments` check on `{arguments: 1}`.
			if prop.computed && prop.key != nil { ck_walk_expr(c, ctx, prop.key) }
			if prop.value == nil { continue }
			// §13.2.5.5 — object-literal methods / accessors carry an
			// [[HomeObject]], so `super.x` is legal inside their bodies.
			// Walk method-shaped values as `.Method` so in_method lifts;
			// regular `kind = .Init` properties walk as plain expressions.
			if prop.kind == .Init {
				ck_walk_expr(c, ctx, prop.value)
				continue
			}
			if fn, ok := prop.value^.(^FunctionExpression); ok && fn != nil {
				ck_walk_function(c, ctx, fn, .Method, false)
			} else {
				ck_walk_expr(c, ctx, prop.value)
			}
		}

	case ^SpreadElement:
		if e != nil { ck_walk_expr(c, ctx, e.argument) }

	case ^UnaryExpression:
		if e == nil { return }
		ck_check_unary_delete_private(c, e)
		ck_walk_expr(c, ctx, e.argument)
	case ^UpdateExpression:          if e != nil { ck_walk_expr(c, ctx, e.argument) }
	case ^ParenthesizedExpression:   if e != nil { ck_walk_expr(c, ctx, e.expression) }
	case ^AwaitExpression:
		if e == nil { return }
		// §15.7.5 — ClassStaticBlockBody Contains await is a SyntaxError.
		if ctx.in_class_static_block {
			ck_report(c, u32(e.loc.span.start), "'await' is not allowed in a class static block")
		}
		// §15.6.1 / arrow-cover: AwaitExpression in formal-parameter
		// position is forbidden. Same arrow-vs-regular message split as
		// the YieldExpression case.
		if ctx.in_params {
			if ctx.params_is_arrow {
				ck_report(c, u32(e.loc.span.start), "Await expression is not allowed in arrow function parameters")
			} else {
				ck_report(c, u32(e.loc.span.start), "'await' expression is not allowed in formal parameters of an async function")
			}
		}
		ck_walk_expr(c, ctx, e.argument)
	case ^YieldExpression:
		if e == nil { return }
		// §15.5.1 / arrow-cover: YieldExpression in formal-parameter
		// position is forbidden (the surrounding generator's scope
		// only starts inside the body). The two diagnostic strings
		// match the parser's existing arrow-vs-regular split.
		if ctx.in_params {
			if ctx.params_is_arrow {
				ck_report(c, u32(e.loc.span.start), "Yield expression is not allowed in arrow function parameters")
			} else {
				ck_report(c, u32(e.loc.span.start), "'yield' expression is not allowed in formal parameters of a generator")
			}
		}
		if a, have := e.argument.(^Expression); have && a != nil { ck_walk_expr(c, ctx, a) }
	case ^ChainExpression:           if e != nil { ck_walk_expr(c, ctx, e.expression) }
	case ^TaggedTemplateExpression:
		if e == nil { return }
		ck_walk_expr(c, ctx, e.tag)
		// §12.9.6 — tagged-template quasis receive raw spans verbatim
		// and are exempt from the legacy-octal / \8\9 escape ban. Set
		// the gate around the immediate quasi walk so a nested
		// (un-tagged) template literal in a substitution still fires.
		prev_tagged := ctx.in_tagged_template
		ctx.in_tagged_template = true
		ck_walk_expr(c, ctx, e.quasi)
		ctx.in_tagged_template = prev_tagged
	case ^TemplateLiteral:
		if e == nil { return }
		ck_check_template_octal(c, ctx, e)
		// Substitution expressions inside the template are NORMAL
		// expressions — they aren't covered by the tagged-template
		// quasi exemption. Reset the gate while walking them.
		prev_tagged := ctx.in_tagged_template
		ctx.in_tagged_template = false
		for s in e.expressions { ck_walk_expr(c, ctx, s) }
		ctx.in_tagged_template = prev_tagged
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

	// Strict-mode-only literal early errors (slice 5):
	case ^NumericLiteral:
		if e != nil { ck_check_legacy_octal_number(c, ctx, e) }
	case ^StringLiteral:
		if e != nil { ck_check_string_octal_escape(c, ctx, e) }
	case ^BigIntLiteral:
		if e != nil { ck_check_legacy_octal_bigint(c, e) }

	// Slice 6 — function-context-driven early errors:
	case ^Super:
		// §13.3.7 — SuperProperty / SuperCall is only legal in a
		// [[HomeObject]]-bearing context (class method / constructor /
		// field init / static block, or object-literal method).
		// Computed-key positions and outside any class/object method are
		// the rejected positions. The CallExpression case has already
		// filtered the `super(...)` shape via ck_check_super_call; this
		// case fires for the standalone `super` reference (i.e. when it
		// appears outside a CallExpression's callee position OR inside a
		// MemberExpression as object).
		if e != nil && !ctx.in_method {
			ck_report(c, u32(e.loc.span.start), "'super' is only allowed in class methods or object-literal methods")
		}
	case ^MetaProperty:
		if e != nil { ck_check_new_target(c, ctx, e) }
	case ^Identifier:
		if e != nil { ck_check_identifier_arguments(c, ctx, e) }

	// Leaf / literal-shape — nothing to walk for break/continue purposes:
	//   NullLiteral, BooleanLiteral, RegExpLiteral, PrivateIdentifier,
	//   ThisExpression, JSXText, JSXExpressionContainer (visited via
	//   JSXElement child walk), JSXEmptyExpression, JSXSpreadChild.
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
ck_walk_function :: proc(c: ^Checker, ctx: ^CheckerContext, fn: ^FunctionExpression,
                        kind: CkFnKind = .Plain, derived_ctor: bool = false) {
	if fn == nil { return }
	saved := ck_enter_function(ctx)
	// Reset the [[HomeObject]] / constructor / class-element flags. The
	// caller's request below restores any that the new body should keep
	// (e.g. a class method body sets in_method back to true). A nested
	// plain function inside a method body sees them all reset and
	// rejects `super.x` / `super(...)` / `arguments` / `await` correctly.
	ctx.in_method              = false
	ctx.in_derived_constructor = false
	ctx.in_field_init          = false
	ctx.in_class_static_block  = false
	switch kind {
	case .Plain:
		// no flag lifts — a regular function body has no special context
	case .Method:
		ctx.in_method = true
	case .Constructor:
		ctx.in_method              = true
		ctx.in_derived_constructor = derived_ctor
	case .StaticBlock:
		ctx.in_method             = true
		ctx.in_class_static_block = true
	}
	// All non-arrow function bodies (including class static blocks)
	// count for `new.target` purposes (§10.2.3). Arrow function entries
	// in ck_walk_expr deliberately do NOT increment this.
	ctx.function_depth += 1
	// §10.2.1 — a function body's `"use strict"` directive lifts strict
	// mode for the body's lexical scope. ck_exit_function restores the
	// outer flag so the lift is local to this function.
	if !fn.no_body && fn_body_lifts_strict(fn.body) {
		ctx.strict_mode = true
	}
	prev_in_params  := ctx.in_params
	prev_arrow_par  := ctx.params_is_arrow
	ctx.in_params       = true
	ctx.params_is_arrow = false
	for pr in fn.params {
		ck_walk_pattern(c, ctx, pr.pattern)
		if d, have := pr.default_val.(^Expression); have && d != nil { ck_walk_expr(c, ctx, d) }
	}
	ctx.in_params       = prev_in_params
	ctx.params_is_arrow = prev_arrow_par
	if !fn.no_body {
		for s in fn.body.body { ck_walk_stmt(c, ctx, s) }
	}
	ctx.function_depth -= 1
	ck_exit_function(ctx, saved)
}

// ck_walk_pattern visits the expression positions inside a binding
// Pattern (computed keys, AssignmentPattern.right defaults), so checks
// keyed off ^YieldExpression / ^AwaitExpression / ^Identifier still
// fire on `({x = yield 1} = ...)` etc. Patterns themselves are not
// expressions, so the regular ck_walk_expr never reaches them.
//
// Today this is called only from the params walk (so in_params is
// already true on entry). If a future slice needs to visit patterns
// from a non-param context (e.g. for-of left-hand destructuring), the
// caller is responsible for setting ctx.in_params accordingly.
@(private="file")
ck_walk_pattern :: proc(c: ^Checker, ctx: ^CheckerContext, pat: Pattern) {
	if pat == nil { return }
	switch pp in pat {
	case ^Identifier, ^MemberExpression:
		return
	case ^AssignmentPattern:
		if pp == nil { return }
		ck_walk_pattern(c, ctx, pp.left)
		ck_walk_expr(c, ctx, pp.right)
	case ^ObjectPattern:
		if pp == nil { return }
		for prop in pp.properties {
			// Computed key contains an arbitrary expression that can
			// reference yield / await; walk it. Non-computed keys are
			// IdentifierName / StringLiteral literals — nothing to walk.
			if prop.computed {
				if key_outer, have := prop.key.(ObjectPatternPropertyKey); have {
					if expr, ok := key_outer.(^Expression); ok && expr != nil {
						ck_walk_expr(c, ctx, expr)
					}
				}
			}
			ck_walk_pattern(c, ctx, prop.value)
		}
	case ^ArrayPattern:
		if pp == nil { return }
		for elem in pp.elements {
			if inner, have := elem.(Pattern); have {
				ck_walk_pattern(c, ctx, inner)
			}
		}
	case ^RestElement:
		if pp != nil { ck_walk_pattern(c, ctx, pp.argument) }
	}
}

@(private="file")
ck_walk_class :: proc(c: ^Checker, ctx: ^CheckerContext, cls: ^ClassExpression) {
	if cls == nil { return }
	has_extends := false
	// super_class is evaluated in the OUTER scope (no function boundary,
	// no class-body strict lift).
	if sc, have := cls.super_class.(^Expression); have && sc != nil {
		has_extends = true
		ck_walk_expr(c, ctx, sc)
	}
	// §15.7.1 — ClassBody is always strict-mode code (mirrors parser.odin
	// `prev_strict_class := p.strict_mode; p.strict_mode = true`). The
	// class body also opens a fresh class-element scope: `in_method`,
	// `in_field_init`, `in_class_static_block`, `in_derived_constructor`
	// from the enclosing context do NOT carry into class elements (the
	// elements set their own).
	prev_strict       := ctx.strict_mode
	prev_in_method    := ctx.in_method
	prev_in_dctor     := ctx.in_derived_constructor
	prev_in_field     := ctx.in_field_init
	prev_in_static_b  := ctx.in_class_static_block
	ctx.strict_mode            = true
	ctx.in_method              = false
	ctx.in_derived_constructor = false
	ctx.in_field_init          = false
	ctx.in_class_static_block  = false
	defer {
		ctx.strict_mode            = prev_strict
		ctx.in_method              = prev_in_method
		ctx.in_derived_constructor = prev_in_dctor
		ctx.in_field_init          = prev_in_field
		ctx.in_class_static_block  = prev_in_static_b
	}

	// Whole-class checks: §15.7.1 — at most one constructor (with TS
	// overload-signature exception). Migrated from parser.odin in slice 4.
	ck_check_class_constructors(c, ctx, cls)

	for elem in cls.body.body {
		// Per-element accessor early-error checks (§15.4.3 / §15.4.4 /
		// §15.4.5). Migrated from parser.odin in slice 3 — keeps the
		// parser to syntax errors only.
		ck_check_accessor(c, elem)

		// Computed keys are evaluated in the OUTER class-body scope:
		// they don't see the about-to-be-pushed in_method / in_field_init,
		// but they do see strict_mode = true (already set above).
		if elem.computed && elem.key != nil {
			ck_walk_expr(c, ctx, elem.key)
		}

		ck_walk_class_element_value(c, ctx, elem, has_extends)
	}
}

// ck_walk_class_element_value dispatches a ClassElement's value to the
// right walker based on element kind and value shape:
//
//   * .StaticBlock: value is a FunctionExpression with no params. Walk
//     as `.StaticBlock` so in_class_static_block + in_method are lifted
//     for the body.
//   * .Get / .Set: value is a FunctionExpression. Walk as `.Method`.
//   * .Constructor: value is a FunctionExpression. Walk as `.Constructor`
//     and pass `derived_ctor = has_extends` so super-call is permitted.
//   * .Method WITH FunctionExpression value: an actual method (regular
//     or shorthand). Walk as `.Method`.
//   * .Method WITHOUT a FunctionExpression value: a class field with an
//     initialiser expression (parser stores fields with kind=.Method and
//     the expression in elem.value — see parser.odin line 5342). Walk
//     the initialiser with in_field_init + in_method lifted, no function
//     entry (the field init runs in a synthetic non-async non-generator
//     function, but `new.target` and break/continue do not propagate so
//     we don't need a function_depth bump).
@(private="file")
ck_walk_class_element_value :: proc(c: ^Checker, ctx: ^CheckerContext, elem: ClassElement, has_extends: bool) {
	val, have := elem.value.(^Expression)
	if !have || val == nil { return }

	if elem.kind == .StaticBlock {
		if fn, ok := val^.(^FunctionExpression); ok && fn != nil {
			ck_walk_function(c, ctx, fn, .StaticBlock, false)
		}
		return
	}

	if fn, ok := val^.(^FunctionExpression); ok && fn != nil {
		switch elem.kind {
		case .Constructor:
			ck_walk_function(c, ctx, fn, .Constructor, has_extends)
		case .Get, .Set, .Method:
			ck_walk_function(c, ctx, fn, .Method, false)
		case .StaticBlock:
			unreachable() // handled above
		}
		return
	}

	// Field initialiser: value is a non-FunctionExpression Expression.
	prev_method := ctx.in_method
	prev_field  := ctx.in_field_init
	ctx.in_method     = true
	ctx.in_field_init = true
	defer {
		ctx.in_method     = prev_method
		ctx.in_field_init = prev_field
	}
	ck_walk_expr(c, ctx, val)
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
// Slice 5 — strict-mode-driven early errors and two strict-independent
// declaration-shape checks (`let` as lexical name; legacy-octal BigInt).
//
// Strict mode tracking lives on `CheckerContext.strict_mode`:
//   * Set to `true` initially when the program is `Module` source-type
//     (§16.2.2) or has a `"use strict"` directive in its prologue.
//   * Lifted by `ck_walk_function` when the function body's prologue
//     contains `"use strict"` (§10.2.1). Restored on function exit.
//   * Lifted unconditionally for the duration of a class body in
//     `ck_walk_class` (§15.7).
//   * Inherited (never lifted) into arrow function bodies, matching the
//     parser's behaviour. Block-body "use strict" prologues in arrows
//     are dropped on the floor by parse_block_statement.
// ============================================================================

// §12.9.3.5 — a NumericLiteral matching the LegacyOctalIntegerLiteral
// shape (`0` followed by decimal digits, no `x`/`o`/`b`/`.`/`e`/`n`)
// is a SyntaxError in strict mode. Re-uses the same shape detector
// the parser uses, kept in src/parser.odin so the lexer and checker
// agree on what a "legacy zero-prefixed integer" looks like.
@(private="file")
ck_check_legacy_octal_number :: proc(c: ^Checker, ctx: ^CheckerContext, num: ^NumericLiteral) {
	if num == nil { return }
	if !ctx.strict_mode { return }
	if !is_legacy_zero_prefixed_integer(num.raw) { return }
	ck_report(c, u32(num.loc.span.start), "Legacy octal literals are not allowed in strict mode")
}

// §12.9.4 — a StringLiteral whose raw source contains a
// LegacyOctalEscapeSequence (`\012`) or NonOctalDecimalEscapeSequence
// (`\8` / `\9`) is a SyntaxError in strict mode. The check fires for
// every string in strict scope, including the directive prologue
// itself (so `function f(){ "\1"; "use strict"; }` retroactively
// reports the offender, matching the parser's hand-rolled scan).
@(private="file")
ck_check_string_octal_escape :: proc(c: ^Checker, ctx: ^CheckerContext, str: ^StringLiteral) {
	if str == nil { return }
	if !ctx.strict_mode { return }
	if !string_raw_has_forbidden_escape(str.raw) { return }
	ck_report(c, u32(str.loc.span.start), "Octal or \\8 / \\9 escape sequences are not allowed in strict mode")
}

// §12.9.3 — a LegacyOctalIntegerLiteral cannot form a BigInt;
// `0123n` is a SyntaxError regardless of strict / sloppy mode.
// (`0o123n` is the modern form.) The raw text retains the trailing
// `n`; `is_legacy_zero_prefixed_integer` strips it before matching.
@(private="file")
ck_check_legacy_octal_bigint :: proc(c: ^Checker, big: ^BigIntLiteral) {
	if big == nil { return }
	if !is_legacy_zero_prefixed_integer(big.raw) { return }
	ck_report(c, u32(big.loc.span.start), "Legacy octal literals cannot be BigInt")
}

// §12.9.6 — inside an UNTAGGED template literal, no quasi may contain a
// LegacyOctalEscapeSequence or NonOctalDecimalEscapeSequence in strict
// mode. Tagged templates are exempt (the tag receives raw spans); the
// `ctx.in_tagged_template` flag short-circuits the check. The parser's
// behaviour is to fire ONCE per template (anchored at the template),
// not once per quasi.
@(private="file")
ck_check_template_octal :: proc(c: ^Checker, ctx: ^CheckerContext, tmpl: ^TemplateLiteral) {
	if tmpl == nil { return }
	if ctx.in_tagged_template { return }
	if !ctx.strict_mode { return }
	for q in tmpl.quasis {
		if string_raw_has_forbidden_escape(q.raw) {
			ck_report(c, u32(tmpl.loc.span.start), "Octal or \\8 / \\9 escape sequences are not allowed in strict mode")
			return
		}
	}
}

// §14.3.1.1 — BoundNames of a LexicalDeclaration must not contain
// `"let"`. Applies to `let`, `const`, `using`, `await using`. `var`
// declarations are exempt (Annex B.3.4.4). Always enforced; not
// strict-mode dependent.
//
// Re-uses parser.odin's `collect_bound_names`, which descends through
// every binding pattern shape (Identifier, Object/Array patterns,
// AssignmentPattern, RestElement) and writes the bound names into the
// passed-in `[dynamic]string`. The walker visits each declarator's
// initialiser separately, so we don't need to recurse here.
@(private="file")
ck_check_var_decl_let_binding :: proc(c: ^Checker, decl: ^VariableDeclaration) {
	if decl == nil { return }
	switch decl.kind {
	case .Let, .Const, .Using, .AwaitUsing:
		// fall through to scan
	case .Var:
		return
	}
	names: [dynamic]string
	names.allocator = c.allocator
	reserve(&names, 4)
	defer delete(names)
	for d in decl.declarations {
		collect_bound_names(d.id, &names)
	}
	for n in names {
		if n == "let" {
			ck_report(c, u32(decl.loc.span.start), "'let' is disallowed as a lexically bound name")
			return // one diagnostic per declaration matches parser behaviour
		}
	}
}

// ============================================================================
// Slice 6 — function-context-driven early errors.
//
// Context tracking lives on `CheckerContext.{function_depth, in_method,
// in_derived_constructor, in_field_init, in_class_static_block}`. See the
// CheckerContext field comments for who pushes/restores each flag.
// ============================================================================

// §15.7.6 / §13.3.7 — `super(...)` is only legal in the instance
// constructor body of a class declared with `extends` (or descendants
// thereof, via inherited [[ConstructorKind]]). Anywhere else (regular
// methods, non-derived constructors, top-level code) it's a SyntaxError.
// The diagnostic anchors at the call expression's open-paren-ish span
// start (matching the parser's old anchor at the `super(` token).
@(private="file")
ck_check_super_call :: proc(c: ^Checker, ctx: ^CheckerContext, call: ^CallExpression) {
	if call == nil || call.callee == nil { return }
	if _, is_super := call.callee^.(^Super); !is_super { return }
	if ctx.in_derived_constructor { return }
	ck_report(c, u32(call.loc.span.start), "'super' call is only allowed in the constructor of a derived class")
}

// §13.3.12 / §15.2 — `new.target` is only valid inside a non-arrow
// function body (arrow functions inherit [[NewTarget]] from the enclosing
// scope; at script top-level there is no [[NewTarget]] to inherit, so
// arrow-only nesting still rejects). The check fires when we encounter
// a MetaProperty whose meta = `new` and property = `target` outside any
// non-arrow function body (function_depth == 0).
@(private="file")
ck_check_new_target :: proc(c: ^Checker, ctx: ^CheckerContext, mp: ^MetaProperty) {
	if mp == nil { return }
	if mp.meta.name != "new" || mp.property.name != "target" { return }
	if ctx.function_depth > 0 { return }
	ck_report(c, u32(mp.loc.span.start), "'new.target' is only allowed inside functions")
}

// §15.7.5 / §15.7.10 — `arguments` as IdentifierReference is forbidden
// in two class-element-shaped scopes:
//
//   * a class field initializer (§15.7.10) — the synthetic field-init
//     function does NOT bind `arguments`. Diagnostic message reflects
//     the field-init context.
//   * a class static block body (§15.7.5 ContainsArguments) — same
//     reasoning, different message to match the parser's anchor text.
//
// `arguments` inside a NESTED function body resets the context (the
// nested function has its own `arguments` binding) — ck_walk_function
// resets in_field_init / in_class_static_block on entry. Arrows inherit.
//
// The walker only reaches ^Identifier through expression positions (not
// declaration `id` fields, which use Pattern), so the check fires for
// IdentifierReferences only.
@(private="file")
ck_check_identifier_arguments :: proc(c: ^Checker, ctx: ^CheckerContext, id: ^Identifier) {
	if id == nil || id.name != "arguments" { return }
	if ctx.in_class_static_block {
		ck_report(c, u32(id.loc.span.start), "'arguments' is not allowed in a class static block")
		return
	}
	if ctx.in_field_init {
		ck_report(c, u32(id.loc.span.start), "'arguments' cannot appear in a class field initializer")
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
