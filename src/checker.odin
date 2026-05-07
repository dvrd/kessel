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
import "core:fmt"

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
// `source_type`: §16.2 — .Script vs .Module. Read by Import/Export
//   declaration cases (`import` / `export` are only valid in module
//   code; in script source any position is an error). Set once at the
//   top of check_program from `program.type`.
// `at_top_level`: §16.2.1 — ImportDeclaration / ExportDeclaration are
//   ModuleItems, only legal as direct children of `Program.body`. Set
//   to true at the top of check_program; ck_walk_stmt drops it to false
//   immediately on entry so any recursive walk into a child statement
//   (block bodies, function bodies, single-statement consequents, etc.)
//   sees a non-top-level position.
// `in_async`: are we inside an async function body? Set by ck_walk_function
//   when fn.async is true; arrows propagate via their own .async flag
//   (a non-async arrow inside an async fn resets `in_async` to false to
//   match the parser's existing behaviour at parse_arrow_function).
//   Read by class-name / arrow-param identifier checks: `await` as a
//   binding name in module/async context is a SyntaxError.
// `in_generator`: are we inside a generator function body? Same
//   propagation rules as in_async (arrows reset to false; arrows can't
//   be generators). Read by class-name / arrow-param identifier checks.
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
	source_type:           SourceType,
	at_top_level:          bool,
	in_async:              bool,
	in_generator:          bool,
	// scope_skip — set true while walking the immediate body of an
	// uncovered expression context (ArrayExpression elements,
	// ObjectExpression property values / computed keys, the right
	// operand of binary / logical / coalescing / shift / equality /
	// relational / additive / multiplicative / exponentiation
	// operators). The pre-session-21 parser-driven scope walker did
	// not recurse into these contexts, so any nested function /
	// arrow / class body inside them was unreachable for scope-clash
	// purposes; matches OXC's behaviour and keeps antd-style bundles
	// (heavy with arrow values inside object/array literals) at
	// parity. Read by `ck_run_scope_check` to skip the
	// scope_check_body invocation when set.
	scope_skip:            bool,
	// private_name_stack — stack of declared private-name sets, one
	// per enclosing class. Pushed by ck_walk_class on entry, popped on
	// exit. Used by ck_check_private_name_resolved to enforce §15.7.3
	// "every PrivateName reference must be declared in an enclosing
	// class". Mirrors parser.odin's `PrivateNameStack` machinery, now
	// migrated post-parse.
	private_name_stack: [dynamic]map[string]bool,
}

Checker :: struct {
	errors:    [dynamic]ParseError,
	allocator: mem.Allocator,
	// pending_parser — the active parser whose AST we're walking.
	// Set by `checker_run_for_job` for the lifetime of the
	// `check_program` walk, cleared after. Used by `ck_run_scope_check`
	// to call back into the parser-side scope_check_body helper
	// (which still owns the lex/var clash detection logic). Nil when
	// no parser is bound (e.g. direct check_program invocation from
	// tests); ck_run_scope_check is a no-op in that case.
	pending_parser: ^Parser,
	// scope_lex / scope_vars — reusable ScopeMap pair backing every
	// scope-check invocation. Cleared between bodies so each scope is
	// verified independently. Cap of 16 covers ≈95% of real-world
	// bodies without spilling into the hashmap path; larger scopes
	// promote to spill on first overflow and the spill map is also
	// retained across iterations via scope_map_clear. Mirrors the
	// allocation pattern parser.odin's old `verify_scopes` used.
	scope_lex:  ScopeMap,
	scope_vars: ScopeMap,
}

init_checker :: proc(alloc: mem.Allocator) -> Checker {
	return Checker{
		errors     = make([dynamic]ParseError, 0, 8, alloc),
		allocator  = alloc,
		scope_lex  = scope_map_make(16, alloc),
		scope_vars = scope_map_make(16, alloc),
	}
}

// ck_run_scope_check — invoke the parser-side scope_check_body helper
// against `body`, using the checker's reusable lex/var maps. The
// helper performs the §14.2.1 / §14.3.1.1 lex/var clash detection and
// emits diagnostics into the checker's error list (via scope_emit →
// checker_append_error). No-ops when:
//
//   * the bound parser is nil (no_op invocation path),
//   * the parser was launched in --ast-only mode (the OXC-parity
//     bench harness path),
//   * `ctx.scope_skip` is set (we're inside an uncovered expression
//     context that the parser-side walker also skipped),
//   * `body` has no scope-relevant statements (cheap fast-path
//     sharing the parser's `has_scope_relevant_stmt` predicate).
//
// The is_block_scope flag controls Annex B.3.2 sloppy-mode
// FunctionDeclaration semantics: true for genuine block scopes
// (catch / finally / for-body / nested blocks / switch-case-list),
// false for function bodies / arrow block bodies / static blocks
// (function-scope; sloppy plain FunctionDecl hoists as .Var).
@(private="file")
ck_run_scope_check :: proc(c: ^Checker, ctx: ^CheckerContext, body: []^Statement, is_block_scope: bool) {
	if c.pending_parser == nil { return }
	if c.pending_parser.ast_only { return }
	if ctx.scope_skip { return }
	if !has_scope_relevant_stmt(body) { return }
	scope_map_clear(&c.scope_lex)
	scope_map_clear(&c.scope_vars)
	scope_check_body(c.pending_parser, c, body, is_block_scope, &c.scope_lex, &c.scope_vars)
}

// check_program is the entry point for the semantic checker.
// Call after parse_program to validate early errors.
check_program :: proc(c: ^Checker, program: ^Program, lang: Lang = .JS) {
	if program == nil { return }
	ctx: CheckerContext
	ctx.labels = make([dynamic]CheckerLabel, 0, 4, c.allocator)
	ctx.private_name_stack = make([dynamic]map[string]bool, 0, 2, c.allocator)
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
	ctx.source_type  = program.type
	ctx.at_top_level = true
	// §14.3 — `using` / `await using` at top of a Script.
	ck_check_using_at_script_top(c, program)
	// §16.2.1 — duplicate-export check (TS / TSX only; JS mode is
	// reported by the parser-side `report_error_at` because the rule
	// is a parse-time structural error there).
	ck_check_export_dups(c, &ctx, program)
	// §16.2.2 — every non-re-export ExportSpecifier.local must reference
	// a name declared at module top level.
	ck_check_export_local_defined(c, program)
	// §14.2.1 / §14.3.1.1 — program-scope lex/var clash detection.
	// The Program body is function-scope (sloppy plain
	// FunctionDeclarations hoist as .Var; let/const/class are .Lexical).
	ck_run_scope_check(c, &ctx, program.body[:], false)
	for stmt in program.body {
		ck_walk_stmt(c, &ctx, stmt)
	}
	// Sanity: every push/pop must balance. Unbalanced means a walker bug.
	assert(ctx.iter_depth == 0)
	assert(ctx.switch_depth == 0)
	assert(len(ctx.labels) == 0)
	assert(ctx.label_floor == 0)
	assert(len(ctx.private_name_stack) == 0)
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
	// §14.2.1 / §14.3.1.1 — duplicate-binding scope analysis is folded
	// into the AST walk. The checker holds a transient pointer to the
	// parser for the lifetime of `check_program` so `ck_run_scope_check`
	// can invoke the parser-side `scope_check_body` helper at each
	// scope-bearing entry point. The pointer is cleared on exit so a
	// stale reference can't leak across jobs.
	c.pending_parser = &job.parser
	defer c.pending_parser = nil
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

// checker_append_error — package-level helper for code outside
// checker.odin that needs to write a diagnostic into the checker's
// error list. Used by parser.odin's scope-analysis machinery
// (scope_add, check_params_vs_body_lex, ...) which has been migrated
// to fire into the checker rather than directly into p.errors. A nil
// `c` is silently ignored — the parser passes `nil` when running in
// `--ast-only` mode where no checker is constructed.
checker_append_error :: proc(c: ^Checker, loc: LexerLoc, message: string) {
	if c == nil { return }
	bump_append(&c.errors, ParseError{loc = loc, message = message})
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
	in_async:              bool,
	in_generator:          bool,
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
		in_async               = ctx.in_async,
		in_generator           = ctx.in_generator,
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
	ctx.in_async               = saved.in_async
	ctx.in_generator           = saved.in_generator
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
	// §16.2.1 — only the IMMEDIATE call from `check_program` carries the
	// top-level marker. Save the snapshot for the Import / Export cases
	// to consult, then drop the flag for any recursive walk of children.
	was_top_level := ctx.at_top_level
	ctx.at_top_level = false
	defer ctx.at_top_level = was_top_level
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
		// §14.13.1 — duplicate label declared in scope.
		ck_check_label_redeclared(c, ctx, v.label.name, u32(v.label.loc.span.start))
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
		// §14.2.1 / §14.3.1.1 — block-scope lex/var clash detection.
		ck_run_scope_check(c, ctx, v.body[:], true)
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
		// §13.5 / §B.3.2 — plain FunctionDeclaration in iteration body.
		ck_check_single_stmt_function(c, v.body)
		ck_walk_stmt(c, ctx, v.body)
		ctx.iter_depth -= 1

	case ^DoWhileStatement:
		if v == nil { return }
		ctx.iter_depth += 1
		ck_check_single_stmt_function(c, v.body)
		ck_walk_stmt(c, ctx, v.body)
		ctx.iter_depth -= 1
		ck_walk_expr(c, ctx, v.test)

	case ^ForStatement:
		if v == nil { return }
		if e, have := v.init_expr.(^Expression); have && e != nil { ck_walk_expr(c, ctx, e) }
		if d, have := v.init_decl.(^VariableDeclaration); have && d != nil { ck_walk_var_decl(c, ctx, d) }
		if d, have := v.init_decl.(^VariableDeclaration); have && d != nil {
			ck_check_for_head_body_shadow(c, d, v.body, "loop")
		}
		if t, have := v.test.(^Expression); have && t != nil { ck_walk_expr(c, ctx, t) }
		if u, have := v.update.(^Expression); have && u != nil { ck_walk_expr(c, ctx, u) }
		ctx.iter_depth += 1
		ck_check_single_stmt_function(c, v.body)
		ck_walk_stmt(c, ctx, v.body)
		ctx.iter_depth -= 1

	case ^ForInStatement:
		if v == nil { return }
		ck_check_for_in_of_head(c, ctx, v.left_expr, v.left_decl, true)
		ck_check_for_in_of_init_eval_args(c, ctx, v.left_expr)
		if d, have := v.left_decl.(^VariableDeclaration); have && d != nil {
			ck_check_for_head_body_shadow(c, d, v.body, "in")
		}
		if e, have := v.left_expr.(^Expression); have && e != nil { ck_walk_expr(c, ctx, e) }
		if d, have := v.left_decl.(^VariableDeclaration); have && d != nil { ck_walk_var_decl(c, ctx, d) }
		ck_walk_expr(c, ctx, v.right)
		ctx.iter_depth += 1
		ck_check_single_stmt_function(c, v.body)
		ck_walk_stmt(c, ctx, v.body)
		ctx.iter_depth -= 1

	case ^ForOfStatement:
		if v == nil { return }
		ck_check_for_in_of_head(c, ctx, v.left_expr, v.left_decl, false)
		ck_check_for_in_of_init_eval_args(c, ctx, v.left_expr)
		if d, have := v.left_decl.(^VariableDeclaration); have && d != nil {
			ck_check_for_head_body_shadow(c, d, v.body, "of")
		}
		if e, have := v.left_expr.(^Expression); have && e != nil { ck_walk_expr(c, ctx, e) }
		if d, have := v.left_decl.(^VariableDeclaration); have && d != nil { ck_walk_var_decl(c, ctx, d) }
		ck_walk_expr(c, ctx, v.right)
		ctx.iter_depth += 1
		ck_check_single_stmt_function(c, v.body)
		ck_walk_stmt(c, ctx, v.body)
		ctx.iter_depth -= 1

	case ^SwitchStatement:
		if v == nil { return }
		ck_walk_expr(c, ctx, v.discriminant)
		ck_check_switch_default_dups(c, v)
		// §14.12.1 / §14.2.1 — switch-case-list block-scope lex/var
		// clash detection. SwitchStatement.cases share a single
		// LexicalEnvironment (the case-list is one Block per spec), so
		// we flatten the consequents and run scope_check_body once.
		// Allocate the flat slice in temp_allocator since it's not
		// retained beyond this call.
		if !ctx.scope_skip && c.pending_parser != nil && !c.pending_parser.ast_only {
			total := 0
			relevant := false
			for sc in v.cases {
				total += len(sc.consequent)
				if !relevant && has_scope_relevant_stmt(sc.consequent[:]) {
					relevant = true
				}
			}
			if total > 0 && relevant {
				flat := make([]^Statement, total, context.temp_allocator)
				i := 0
				for sc in v.cases {
					for s in sc.consequent {
						flat[i] = s
						i += 1
					}
				}
				ck_run_scope_check(c, ctx, flat, true)
			}
		}
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
			// §15.4.5 — catch clause parameter duplicate-name check
			// (§15.4.5 covers `catch ({a, a})` and the like).
			ck_check_catch_param_dups(c, h)
			// §15.4.5 — catch param vs body let/const redeclaration.
			ck_check_catch_param_body_shadow(c, h)
			// Catch parameter is a BindingIdentifier (or pattern containing
			// BindingIdentifiers). §13.1.1 strict-mode check applies.
			if ctx.strict_mode {
				if p_pat, have_p := h.param.(Pattern); have_p {
					ck_check_strict_param_pattern(c, p_pat)
				}
			}
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
		ck_check_single_stmt_function(c, v.body)
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
		ck_check_import_export_position(c, ctx, v.loc, false, was_top_level)
		if d, have := v.declaration.(^Declaration); have && d != nil {
			ck_walk_export_decl(c, ctx, d)
		}
		// ExportSpecifiers reference identifier names only — no break /
		// continue / labels possible inside.

	case ^ExportDefaultDeclaration:
		if v == nil || v.declaration == nil { return }
		ck_check_import_export_position(c, ctx, v.loc, false, was_top_level)
		#partial switch inner in v.declaration^ {
		case ^Expression:  if inner != nil { ck_walk_expr(c, ctx, inner) }
		case ^Declaration: if inner != nil { ck_walk_export_decl(c, ctx, inner) }
		}

	case ^ImportDeclaration:
		if v != nil {
			ck_check_import_export_position(c, ctx, v.loc, true, was_top_level)
			ck_walk_import_decl(c, ctx, v)
		}

	case ^ExportAllDeclaration:
		if v != nil {
			ck_check_import_export_position(c, ctx, v.loc, false, was_top_level)
		}

	case ^EmptyStatement, ^DebuggerStatement,
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

// ck_check_var_decl_lexical_dups — §14.3.1.1 — a LexicalDeclaration
// (`let` / `const` / `using` / `await using`) may not have BoundNames
// containing duplicates within a single declaration list. `let a, a;`
// and `const [x, x] = [1, 2];` are SyntaxErrors. NOT enforced for
// `var` declarations (Annex B.3.4.4 web-compat). The cross-declaration
// duplicate-name check (a let in one block clashing with a let in the
// same block from a different statement) lives in the scope-analysis
// machinery and is migrated separately in slice 13.
@(private="file")
ck_check_var_decl_lexical_dups :: proc(c: ^Checker, decl: ^VariableDeclaration) {
	if decl == nil { return }
	switch decl.kind {
	case .Let, .Const, .Using, .AwaitUsing:
		// fall through
	case .Var:
		return
	}
	names: [dynamic]string
	names.allocator = context.temp_allocator
	reserve(&names, 4)
	for d in decl.declarations { collect_bound_names(d.id, &names) }
	n := len(names)
	if n < 2 { return }
	for i := 1; i < n; i += 1 {
		for j := 0; j < i; j += 1 {
			if names[i] == names[j] {
				msg := fmt.tprintf("Identifier '%s' has already been declared", names[i])
				ck_report(c, u32(decl.loc.span.start), msg)
				return
			}
		}
	}
}

ck_walk_var_decl :: proc(c: ^Checker, ctx: ^CheckerContext, decl: ^VariableDeclaration) {
	if decl == nil { return }
	// §14.3.1.1 — per-declaration duplicate-name check (slice 11).
	ck_check_var_decl_lexical_dups(c, decl)
	// §13.1.1 — strict-mode BindingIdentifier check for declarator ids.
	// Recurses through ObjectPattern / ArrayPattern / AssignmentPattern
	// / RestElement so destructured names are checked too. Generic
	// flavour: `var let;` reports "'let' is a reserved identifier in
	// strict mode" and `var eval;` reports "'eval' cannot be used as a
	// binding name in strict mode" — matching parser.odin's old
	// parse_binding_identifier diagnostics. Runs FIRST (matching the
	// parser's parse-order) so the per-binding-id diagnostic appears
	// before the per-declaration `let`-as-lex diagnostic below.
	if ctx.strict_mode {
		for d in decl.declarations {
			ck_check_strict_binding_pattern(c, d.id, .Generic)
		}
	}
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
		// §15.3.1 / §15.9.1 — ContainsUseStrict + !IsSimpleParameterList
		// early error for arrow functions. Arrow block bodies don't carry
		// a populated `directives` array (parse_block_statement skips the
		// directive-prologue setup), so the helper checks the first body
		// statement's StringLiteral expression directly.
		ck_check_arrow_strict_directive_with_nonsimple_params(c, e)
		// Snapshot the OUTER async/generator context BEFORE ck_enter_function
		// resets it. Arrow params are evaluated under the COMBINED context:
		//   * `await` is reserved if the outer scope was async OR the arrow
		//     itself is async (per parser's await_is_reserved_here);
		//   * `yield` is reserved if the outer scope was a generator (arrows
		//     can't be generators themselves).
		outer_in_async := ctx.in_async
		outer_in_gen   := ctx.in_generator
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
		ctx.in_async        = outer_in_async || e.async
		ctx.in_generator    = outer_in_gen
		// §15.3.1 / §15.9.1 — ArrowFunction params are ALWAYS
		// UniqueFormalParameters, regardless of strict / sloppy or
		// simple / non-simple. Match parser.odin's old
		// `report_duplicate_param_names(params, true, true)` call by
		// passing is_strict = true (so the "in strict mode" message
		// fires) AND force_non_simple = true (to ensure the check runs
		// even when the params are simple).
		ck_check_duplicate_param_names(c, u32(e.loc.span.start), e.params[:], true, true)
		for pr in e.params {
			ck_check_arrow_param_pattern(c, ctx, pr.pattern)
			if ctx.strict_mode { ck_check_strict_param_pattern(c, pr.pattern) }
			ck_walk_pattern(c, ctx, pr.pattern)
			if d, have := pr.default_val.(^Expression); have && d != nil { ck_walk_expr(c, ctx, d) }
		}
		ctx.in_params       = prev_in_params
		ctx.params_is_arrow = prev_arrow_par
		ctx.in_async        = e.async
		ctx.in_generator    = false
		#partial switch body in e.body {
		case ^Expression:     if body != nil { ck_walk_expr(c, ctx, body) }
		case ^BlockStatement:
			if body != nil {
				// Arrow block body is function-scope (§15.3.1).
				ck_run_scope_check(c, ctx, body.body[:], false)
				for s in body.body { ck_walk_stmt(c, ctx, s) }
			}
		}
		ck_exit_function(ctx, saved)

	case ^ClassExpression:
		if e != nil { ck_walk_class(c, ctx, e) }

	case ^MemberExpression:
		if e == nil { return }
		ck_check_member_super_private(c, e)
		// §15.7.3 — PrivateIdentifier on the property side must be
		// declared in an enclosing class. Non-private property names are
		// IdentifierName literals — not subject to scope resolution.
		if !e.computed && e.property != nil {
			if pid, ok := e.property^.(^PrivateIdentifier); ok {
				ck_check_private_name_resolved(c, ctx, pid)
			}
		}
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
		// §15.7.3 — `#x in obj` is the only legal position for a bare
		// PrivateIdentifier. The name must still be declared in an
		// enclosing class. The general bare-PrivateIdentifier-as-expr
		// case is rejected at parse-time; only the `in`-form reaches
		// here as a valid AST shape.
		if e.operator == .In && e.left != nil {
			if pid, ok := e.left^.(^PrivateIdentifier); ok {
				ck_check_private_name_resolved(c, ctx, pid)
			}
		}
		ck_walk_expr(c, ctx, e.left)
		// The right operand of a binary op is in an uncovered
		// expression context: nested function / arrow / class bodies
		// here are not visited by the parser-driven walker for
		// duplicate-binding purposes (matches OXC + pre-session-21
		// shipped behaviour). Mirror by setting scope_skip while
		// walking the right operand.
		prev_skip := ctx.scope_skip
		ctx.scope_skip = true
		ck_walk_expr(c, ctx, e.right)
		ctx.scope_skip = prev_skip

	case ^LogicalExpression:
		if e == nil { return }
		ck_walk_expr(c, ctx, e.left)
		prev_skip := ctx.scope_skip
		ctx.scope_skip = true
		ck_walk_expr(c, ctx, e.right)
		ctx.scope_skip = prev_skip

	case ^AssignmentExpression:
		if e == nil { return }
		ck_check_assignment_invalid_lhs(c, e)
		// §13.15.1 — in strict mode, the LHS of any assignment may not
		// name `eval` or `arguments` (covers destructured forms via the
		// recursive helper).
		if ctx.strict_mode {
			ck_check_strict_eval_arguments_in_target(c, e.left)
		}
		ck_walk_expr(c, ctx, e.left)
		ck_walk_expr(c, ctx, e.right)

	case ^SequenceExpression:
		if e != nil { for s in e.expressions { ck_walk_expr(c, ctx, s) } }

	case ^ArrayExpression:
		if e == nil { return }
		// ArrayExpression interior is an uncovered context. Mirror the
		// pre-session-21 parser behaviour by suppressing the
		// scope-clash walk for any nested function / arrow / class
		// body inside.
		prev_skip := ctx.scope_skip
		ctx.scope_skip = true
		defer ctx.scope_skip = prev_skip
		for el in e.elements {
			if inner, have := el.(^Expression); have && inner != nil { ck_walk_expr(c, ctx, inner) }
		}

	case ^ObjectExpression:
		if e == nil { return }
		ck_check_object_proto_dups(c, e)
		// ObjectExpression interior is an uncovered context (same
		// rationale as ArrayExpression above).
		prev_skip := ctx.scope_skip
		ctx.scope_skip = true
		defer ctx.scope_skip = prev_skip
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
		ck_check_unary_delete_local(c, ctx, e)
		ck_walk_expr(c, ctx, e.argument)
	case ^UpdateExpression:
		if e == nil { return }
		// §13.4.4 — ++/-- on eval/arguments in strict mode is forbidden.
		ck_check_strict_update_eval_arguments(c, ctx, e.argument)
		ck_walk_expr(c, ctx, e.argument)
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
		if e != nil {
			ck_check_identifier_arguments(c, ctx, e)
			// §12.6.1.1 — strict-mode reserved word as IdentifierReference.
			ck_check_identifier_reference_strict(c, ctx, e)
			// §16.2 / §15.7.5 — escaped `await` in async / class-static-block.
			ck_check_identifier_await_reserved(c, ctx, e)
		}

	case ^PrivateIdentifier:
		// §15.7.3 — a bare PrivateIdentifier reaching expression position
		// is a parser-side structural error ("only the LHS of an 'in'
		// expression"); fire the resolution error too so the AST-level
		// diagnostic still reports. Mirrors parser.odin's `pn_walk_expr`
		// fall-through case for stray PrivateIdentifiers.
		if e != nil { ck_check_private_name_resolved(c, ctx, e) }

	// Leaf / literal-shape — nothing to walk for break/continue purposes:
	//   NullLiteral, BooleanLiteral, RegExpLiteral,
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
	// §15.2.1.1 — formal-parameter vs body let/const redeclaration.
	if !fn.no_body {
		ck_check_params_vs_body_lex(c, fn.params[:], fn.body.body[:])
	}
	// §15.1.1 / §15.5.1 / §15.6.1 / §15.8.1 — ContainsUseStrict +
	// !IsSimpleParameterList early error. Fires before the function-body
	// walk so the diagnostic anchors at the function start, matching the
	// parser's old anchor.
	ck_check_strict_directive_with_nonsimple_params(c, fn)
	// §15.7.1 — strict-mode function-name BindingIdentifier check
	// (`function eval(){}`, `function let(){}`, etc.). Done BEFORE
	// ck_enter_function so the OUTER strict_mode is what gates the
	// check (the body lifts strict mode for the body only). The check
	// runs only for FunctionExpression-as-expression / FunctionDecl
	// (kind == .Plain); class methods / accessors / static blocks /
	// constructors don't have their own BindingIdentifier name.
	if kind == .Plain {
		if id, have := fn.id.(BindingIdentifier); have {
			// Determine the strict-mode environment the function name
			// is parsed under. For FunctionExpression the name is in
			// the inner function's scope (so the function's OWN strict
			// flag matters). The walker has not yet lifted strict mode
			// for the body, so we check against the post-lift value
			// directly here.
			name_strict := ctx.strict_mode || (!fn.no_body && fn_body_lifts_strict(fn.body))
			name_in_async := ctx.in_async
			name_in_gen   := ctx.in_generator
			_ = name_in_async
			_ = name_in_gen
			if name_strict {
				if is_eval_or_arguments(id.name) {
					msg := fmt.tprintf("Function name '%s' is not allowed in strict mode", id.name)
					ck_report(c, u32(id.loc.span.start), msg)
				} else if is_strict_reserved_simple_name(id.name) {
					// `yield` as fn name in strict mode — parser-side
					// `report_error` already catches generator name clash;
					// strict-only reservation is checker-side.
					msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", id.name)
					ck_report(c, u32(id.loc.span.start), msg)
				}
			}
		}
	}
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
	// §15.5 / §15.6 — a function body's own async/generator-ness drives
	// whether `await` / `yield` are reserved INSIDE the body. Static
	// blocks reset both per §15.7.5 ("runs under [~Yield, ~Await]").
	switch kind {
	case .StaticBlock:
		ctx.in_async     = false
		ctx.in_generator = false
	case .Plain, .Method, .Constructor:
		ctx.in_async     = fn.async
		ctx.in_generator = fn.generator
	}
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
	// §15.5.1 / §15.6.1 / §15.8.1 — strict-mode parameter
	// BindingIdentifier check (`eval` / `arguments` / strict-reserved).
	// The lifted strict_mode is already applied for body context, but
	// param patterns are checked under that same strict context (the
	// parser tracked this with the post-body-prologue
	// `body_strict || p.strict_mode` rule). Generators / async / async-
	// generators inherit strict-flavoured uniqueness regardless.
	if ctx.strict_mode {
		for pr in fn.params { ck_check_strict_param_pattern(c, pr.pattern) }
	}
	// §15.5.1 / §15.6.1 / §15.8.1 — duplicate parameter names.
	params_simple := params_are_simple(fn.params[:])
	force_non_simple := !params_simple
	dup_strict := ctx.strict_mode || fn.async || fn.generator
	ck_check_duplicate_param_names(c, u32(fn.loc.span.start), fn.params[:], dup_strict, force_non_simple)
	for pr in fn.params {
		ck_walk_pattern(c, ctx, pr.pattern)
		if d, have := pr.default_val.(^Expression); have && d != nil { ck_walk_expr(c, ctx, d) }
	}
	ctx.in_params       = prev_in_params
	ctx.params_is_arrow = prev_arrow_par
	if !fn.no_body {
		// §14.2.1 / §14.3.1.1 — function-body lex/var clash detection.
		// Function bodies are function-scope (is_block_scope=false), so
		// sloppy plain FunctionDeclarations inside hoist as .Var per
		// §14.1.3 / Annex B.3.2. Static-block bodies and class-method
		// bodies share the same scoping rule.
		ck_run_scope_check(c, ctx, fn.body.body[:], false)
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
	// no class-body strict lift, no private-name visibility from THIS
	// class — the heritage clause cannot reference its own privates).
	if sc, have := cls.super_class.(^Expression); have && sc != nil {
		has_extends = true
		ck_walk_expr(c, ctx, sc)
	}
	// Push this class's declared private names onto the resolution
	// stack BEFORE walking the class body. Pop on exit. The push is
	// O(elements) but only fires for classes that actually declare
	// privates — the resulting set is small (~5–10 names per class on
	// real-world code).
	privates := ck_collect_class_private_names(cls.body, context.temp_allocator)
	append(&ctx.private_name_stack, privates)
	defer pop(&ctx.private_name_stack)
	// §15.7.1 — BindingIdentifier of a class is checked under strict
	// reservation rules (the class body is implicitly strict + the name
	// is in the enclosing TDZ with strict-reservation rules applied), so
	// `class let`, `class implements`, `class yield`, `class eval` etc.
	// are always SyntaxErrors. Migrated from parse_class_declaration /
	// parse_class_expression to keep the class-name check in a single
	// place. Note: `enum` as a class name stays a parser-side
	// `report_error` (it's a structural reservation, not strict-only).
	ck_check_class_name(c, ctx, cls)

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
	// §15.7.1 — private getter/setter static-mismatch (slice 11).
	ck_check_class_private_static_mismatch(c, cls)

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
// Slice 8 — "use strict" directive in non-simple-param list (§15.1.1
// / §15.3.1 / §15.5.1 / §15.6.1 / §15.8.1 / §15.9.1).
//
// All six function shapes (regular function declarations / expressions,
// class methods, object-literal methods, plain arrow functions, async
// arrow functions) shared the same parser-side check; the checker now
// covers them via two helpers (one for FunctionExpression-shaped nodes
// where the body's directive prologue is preserved, one for arrow
// functions where parse_block_statement drops the prologue array but
// the StringLiteral expression survives as body[0]).
// ============================================================================

// ck_check_strict_directive_with_nonsimple_params handles every non-arrow
// function shape (regular function decl/expr, class method, getter/setter,
// constructor, static block, object-literal method). Static blocks have
// no params so they trivially short-circuit on params_are_simple.
@(private="file")
ck_check_strict_directive_with_nonsimple_params :: proc(c: ^Checker, fn: ^FunctionExpression) {
	if fn == nil || fn.no_body { return }
	if !fn_body_lifts_strict(fn.body) { return }
	if params_are_simple(fn.params[:]) { return }
	ck_report(c, u32(fn.loc.span.start), "Illegal 'use strict' directive in function with non-simple parameter list")
}

// ck_check_arrow_strict_directive_with_nonsimple_params handles arrow
// function bodies. Arrow concise bodies (Expression bodies) cannot
// contain a directive prologue, so the check only fires for block
// bodies. parse_block_statement does NOT promote leading string-literal
// statements to directives (only parse_program / parse_function_body
// do), so we sniff body[0]'s ExpressionStatement.expression as a
// StringLiteral with value == "use strict". Matches the parser's
// post-hoc check shape (parse_arrow_function and parse_async_arrow_with_parens).
@(private="file")
ck_check_arrow_strict_directive_with_nonsimple_params :: proc(c: ^Checker, fn: ^ArrowFunctionExpression) {
	if fn == nil { return }
	block, is_block := fn.body.(^BlockStatement)
	if !is_block || block == nil || len(block.body) == 0 { return }
	es, eok := block.body[0]^.(^ExpressionStatement)
	if !eok || es == nil { return }
	str, sok := es.expression.(^StringLiteral)
	if !sok || str == nil { return }
	if str.value != "use strict" { return }
	if params_are_simple(fn.params[:]) { return }
	ck_report(c, u32(fn.loc.span.start), "Illegal 'use strict' directive in function with non-simple parameter list")
}

// ============================================================================
// Slice 9 — import/export position rules + invalid-LHS in compound
// assignment.
// ============================================================================

// §16.2 / §16.2.1 — ImportDeclaration / ExportDeclaration positioning.
// Two related rules:
//   * Source-type rule: in a Script Program, ANY position is invalid
//     (`import` and `export` are only valid in module code, regardless
//     of nesting).
//   * Top-level rule: in a Module Program, the declaration must appear
//     as a direct child of `Program.body` — not nested in a function
//     body, block, single-statement consequent, switch case, etc.
//
// `is_import` picks the diagnostic noun in the script-mode message.
// `was_top_level` is the snapshot of `ctx.at_top_level` taken at the
// start of the surrounding `ck_walk_stmt` call — it's true ONLY when
// the statement is being walked directly from `check_program`.
@(private="file")
ck_check_import_export_position :: proc(
	c: ^Checker,
	ctx: ^CheckerContext,
	loc: Loc,
	is_import: bool,
	was_top_level: bool,
) {
	if ctx.source_type == .Script {
		msg := "'export' is only valid in module code"
		if is_import { msg = "'import' is only valid in module code" }
		ck_report(c, u32(loc.span.start), msg)
		return
	}
	if !was_top_level {
		msg := "'export' declarations are only allowed at the top level of a module"
		if is_import { msg = "'import' declarations are only allowed at the top level of a module" }
		ck_report(c, u32(loc.span.start), msg)
	}
}

// §13.15.1 — "Invalid left-hand side in assignment" early error fired
// only for the destructuring-as-LHS-with-compound-operator case (e.g.
// `[a] += 1`, `({x} = e) **= 2`). Every OTHER invalid-LHS shape is a
// structural parse error reported by the parser via `report_error`.
// The parser fires this at parse_assignment_expr; the AST preserves
// AssignmentExpression.{left, operator}, so re-running
// `is_valid_assignment_target` post-parse reproduces the diagnostic.
@(private="file")
ck_check_assignment_invalid_lhs :: proc(c: ^Checker, e: ^AssignmentExpression) {
	if e == nil || e.left == nil { return }
	if e.operator == .Assign { return } // covered by parser-side report_error
	if is_valid_assignment_target(e.left, true) { return }
	// Only ArrayExpression / ObjectExpression LHS reach here as semantic
	// errors — every other invalid LHS is a parser-side structural error.
	#partial switch _ in e.left^ {
	case ^ArrayExpression, ^ObjectExpression:
		ck_report(c, u32(e.loc.span.start), "Invalid left-hand side in assignment")
	}
}

// ============================================================================
// Slice 10 — BindingIdentifier reservation rules for class names + arrow
// parameters. Strict-mode reserved-word handling for general
// IdentifierReference / BindingIdentifier positions across the rest of
// the AST is deferred to a future scope-analysis migration (parser-side
// scope_* + report_strict_* helpers).
// ============================================================================

// is_strict_reserved_simple_name returns true if `name` matches a
// strict-mode-reserved IdentifierName the AST exposes as a plain
// ^Identifier (i.e. one that the lexer cooked from a token type the
// parser couldn't already reject as a keyword). Mirrors parser.odin's
// `is_strict_reserved_word(token_type) || is_strict_reserved_name(name)`
// modulo lex-time information; the parser-side `let` / `static` / `yield`
// branch is folded in here. `await` and `enum` are checked separately by
// callers because they have their own diagnostic strings.
@(private="file")
is_strict_reserved_simple_name :: proc(name: string) -> bool {
	switch name {
	case "implements", "interface", "package", "private",
	     "protected", "public", "let", "static", "yield":
		return true
	}
	return false
}

// §15.7.1 — BindingIdentifier of a ClassExpression / ClassDeclaration
// is checked under strict-reservation rules. Reports as semantic errors:
//   * eval / arguments — `Class name 'NAME' is not allowed`
//   * strict-reserved word (let, static, yield, implements, interface,
//     package, private, protected, public) —
//     `'NAME' is a reserved identifier and cannot be a class name`
//   * await in module/async —
//     `'await' cannot be used as a class name in module / async context`
//
// `enum` as a class name stays a parser-side structural error
// (parse_class_declaration's `report_error`); not migrated.
@(private="file")
ck_check_class_name :: proc(c: ^Checker, ctx: ^CheckerContext, cls: ^ClassExpression) {
	if cls == nil { return }
	id, has_id := cls.id.(BindingIdentifier)
	if !has_id { return }
	loc := u32(id.loc.span.start)
	name := id.name

	if is_strict_reserved_simple_name(name) {
		msg := fmt.tprintf("'%s' is a reserved identifier and cannot be a class name", name)
		ck_report(c, loc, msg)
		return
	}
	if is_eval_or_arguments(name) {
		msg := fmt.tprintf("Class name '%s' is not allowed", name)
		ck_report(c, loc, msg)
		return
	}
	if name == "await" && (ctx.in_async || ctx.source_type == .Module) {
		ck_report(c, loc, "'await' cannot be used as a class name in module / async context")
	}
}

// Arrow parameter BindingIdentifier reservation rules (mirror of
// parse_arrow_function_with_parens' identifier-shape check at
// parser.odin lines 13918–13931). Reports as semantic errors:
//   * eval / arguments in strict mode —
//     `Arrow parameter 'NAME' is not allowed in strict mode`
//   * strict-reserved word in strict mode —
//     `'NAME' is a reserved identifier in strict mode`
//   * `enum` (always reserved) — `'enum' is a reserved identifier`
//   * `await` in module/async —
//     `'await' cannot be used as an arrow parameter in module / async context`
//   * `yield` in generator/strict —
//     `'yield' cannot be used as an arrow parameter in generator / strict context`
//
// Walks only the immediate identifier (no recursion into nested patterns;
// `({await} = ...) => ...` puts `await` in a nested ObjectPattern, where
// scope-bind machinery in the parser still owns the diagnostic).
@(private="file")
ck_check_arrow_param_pattern :: proc(c: ^Checker, ctx: ^CheckerContext, pat: Pattern) {
	if pat == nil { return }
	id, is_id := pat.(^Identifier)
	if !is_id || id == nil { return }
	name := id.name
	loc  := u32(id.loc.span.start)

	if ctx.strict_mode {
		if is_eval_or_arguments(name) {
			msg := fmt.tprintf("Arrow parameter '%s' is not allowed in strict mode", name)
			ck_report(c, loc, msg)
		} else if is_strict_reserved_simple_name(name) {
			msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", name)
			ck_report(c, loc, msg)
		}
	}
	if name == "enum" {
		ck_report(c, loc, "'enum' is a reserved identifier")
	}
	if name == "await" && (ctx.in_async || ctx.source_type == .Module) {
		ck_report(c, loc, "'await' cannot be used as an arrow parameter in module / async context")
	}
	if name == "yield" && (ctx.in_generator || ctx.strict_mode) {
		ck_report(c, loc, "'yield' cannot be used as an arrow parameter in generator / strict context")
	}
}

// ============================================================================
// Slice 11 — cheap finishing migrations.
//
// Local AST-only checks for which the checker walker already had the
// needed context after slices 5–10 (strict_mode, in_async, in_generator,
// source_type, at_top_level, in_params, function_depth) so the
// migrations are mechanical: drop the inline parser-side
// `report_semantic_error*` and reproduce the diagnostic by walking the
// finished AST.
//
// Coverage:
//   * §14.3 — `using` / `await using` at top of a Script (parser L1479)
//   * §14.13.1 — duplicate label declared in scope (parser L2254)
//   * §13.5 / §B.3.2 — plain FunctionDeclaration as a single-statement
//     iteration body (parser L2379)
//   * §13.7.5.1 — CallExpression as for-in/of LHS in strict
//     (parser L2883)
//   * §13.7.5.1 — only a single declaration in a for-in/of head
//     (parser L2924)
//   * §13.7.5.1 — for-in/of variable declaration may not have an
//     initializer (parser L2953)
//   * §13.5.1 — `delete IdentifierReference` in strict mode
//     (parser L10378)
//   * §15.4.5 — duplicate identifier in catch clause parameter
//     (parser L3548)
//   * §15.7.1 — private getter/setter static-mismatch (parser L4763)
//   * §15.5.1 / §15.6.1 / §15.8.1 — duplicate parameter name (parser
//     L5978; the lexical-decl dup variant at L6005 stays scope-tied)
//   * §15.5.1 / §15.6.1 / §15.8.1 — `eval` / `arguments` / strict-
//     reserved as parameter pattern in strict mode (parser L6398/L6402)
//   * §13.15.1 — `eval`/`arguments` as the target of a simple or
//     compound assignment in strict mode (parser L2891 + L14408 share
//     `report_strict_eval_arguments_in_target`)
//   * §13.4.4 — `eval`/`arguments` as the target of an Update
//     (`++`/`--`) in strict mode (parser L10411 + L10664)
//   * §13.1.1 / §15.7.1 — strict-reserved word + `eval`/`arguments` as
//     a BindingIdentifier in declaration positions: var/let/const
//     declarators, function names (parser L3743/L3778/L3966), function
//     parameters, catch param, etc. (parser L6650/L6732/L6739)
//   * §12.6.1.1 — strict-reserved word as IdentifierReference (parser
//     L10591/L11740/L12352).
//   * §16.2.2 — `eval`/`arguments` as ImportedBinding (parser L9123).
// ============================================================================

// ck_check_export_dups — §16.2.1 — ExportedNames of ModuleItemList
// must not contain duplicates. Walks Program.body once collecting
// exported names from the three Export forms, reporting any duplicate.
//
// The parser still owns the JS-mode duplicate-export error (it fires
// `report_error_at` so the diagnostic ALWAYS reports, regardless of
// `--show-semantic-errors`). The checker fires only in TS / TSX modes
// where the parser-side check was already gated semantic. This match
// OXC's behaviour: oxc_parser drops duplicate-export errors in TS mode
// because TS overload-signature / type-vs-value merging makes the
// surface-syntax "duplicate" benign in many cases; oxc_semantic resolves
// the rest. Kessel matches by deferring TS-mode reporting to pass 3.
//
// Module-only — Script-mode imports/exports are caught by
// ck_check_import_export_position. Script programs short-circuit here.
@(private="file")
ck_check_export_dups :: proc(c: ^Checker, ctx: ^CheckerContext, program: ^Program) {
	if program == nil { return }
	if program.type != .Module { return }
	if !(ctx.lang == .TS || ctx.lang == .TSX) { return }
	exported: map[string]u32
	exported.allocator = context.temp_allocator
	defer delete(exported)
	record :: proc(c: ^Checker, exported: ^map[string]u32, name: string, off: u32) {
		if name == "" { return }
		if _, exists := exported^[name]; exists {
			msg := fmt.tprintf("Duplicate exported name '%s'", name)
			ck_report(c, off, msg)
		} else {
			exported^[name] = off
		}
	}
	for stmt in program.body {
		if stmt == nil { continue }
		#partial switch v in stmt^ {
		case ^ExportNamedDeclaration:
			if v == nil { continue }
			if d, have := v.declaration.(^Declaration); have && d != nil {
				#partial switch inner in d^ {
				case ^VariableDeclaration:
					if inner == nil { break }
					for decl in inner.declarations {
						names: [dynamic]string
						names.allocator = context.temp_allocator
						reserve(&names, 4)
						collect_pattern_bound_names_list(decl.id, &names)
						for n in names {
							record(c, &exported, n, u32(decl.loc.span.start))
						}
					}
				case ^FunctionDeclaration:
					if inner == nil { break }
					// TS overload signature (no body): same name across
					// multiple declarations is the canonical TS overload
					// pattern. Only the implementation contributes a binding.
					if inner.no_body { break }
					if id, ok := inner.id.(BindingIdentifier); ok {
						record(c, &exported, id.name, u32(id.loc.span.start))
					}
				case ^ClassDeclaration:
					if inner == nil { break }
					if id, ok := inner.id.(BindingIdentifier); ok {
						record(c, &exported, id.name, u32(id.loc.span.start))
					}
				}
			}
			for spec in v.specifiers {
				switch en in spec.exported {
				case IdentifierName:
					record(c, &exported, en.name, u32(en.loc.span.start))
				case ^StringLiteral:
					if en != nil {
						record(c, &exported, en.value, u32(en.loc.span.start))
					}
				}
			}
		case ^ExportAllDeclaration:
			if v == nil { continue }
			if ns_name, has_ns := v.exported.(IdentifierName); has_ns {
				record(c, &exported, ns_name.name, u32(ns_name.loc.span.start))
			}
		}
	}
}

// ck_collect_module_top_level_names — §16.2.2 helper. Collects every
// VarDeclaredName / LexicallyDeclaredName at module top level (also
// counts ImportSpecifier locals — those are bindings the module
// exports can reference). Mirrors parser.odin's old
// `collect_module_top_level_names` helper which lived alongside
// `verify_export_locals` in the parser.
@(private="file")
ck_collect_module_top_level_names :: proc(body: []^Statement, names: ^map[string]bool) {
	for stmt in body {
		if stmt == nil { continue }
		#partial switch v in stmt^ {
		case ^VariableDeclaration:
			if v == nil { continue }
			for decl in v.declarations { collect_pattern_bound_names(decl.id, names) }
		case ^FunctionDeclaration:
			if v == nil { continue }
			if id, ok := v.id.(BindingIdentifier); ok { names[id.name] = true }
		case ^ClassDeclaration:
			if v == nil { continue }
			if id, ok := v.id.(BindingIdentifier); ok { names[id.name] = true }
		case ^ImportDeclaration:
			if v == nil { continue }
			for spec in v.specifiers {
				if spec == nil { continue }
				switch ss in spec^ {
				case ImportSpecifier:          names[ss.local.name] = true
				case ImportDefaultSpecifier:   names[ss.local.name] = true
				case ImportNamespaceSpecifier: names[ss.local.name] = true
				}
			}
		case ^ExportNamedDeclaration:
			if v == nil { continue }
			if d, have := v.declaration.(^Declaration); have && d != nil {
				#partial switch inner in d^ {
				case ^VariableDeclaration:
					if inner == nil { break }
					for decl in inner.declarations { collect_pattern_bound_names(decl.id, names) }
				case ^FunctionDeclaration:
					if inner == nil { break }
					if id, ok := inner.id.(BindingIdentifier); ok { names[id.name] = true }
				case ^ClassDeclaration:
					if inner == nil { break }
					if id, ok := inner.id.(BindingIdentifier); ok { names[id.name] = true }
				}
			}
		case ^TSInterfaceDeclaration: if v != nil { names[v.id.name] = true }
		case ^TSTypeAliasDeclaration: if v != nil { names[v.id.name] = true }
		case ^TSEnumDeclaration:      if v != nil { names[v.id.name] = true }
		case ^TSModuleDeclaration:
			if v != nil && v.id != nil {
				if ident, is_id := v.id.(^Identifier); is_id && ident != nil {
					names[ident.name] = true
				}
			}
		}
	}
}

// ck_check_export_local_defined — §16.2.2 — every ExportedBinding
// whose source is the module itself (i.e. NOT a `from "m"` re-export)
// must reference a name declared at module top level. `export { foo };`
// with no preceding declaration of `foo` is a SyntaxError.
//
// The parser still owns the structural sub-rule "a string literal
// cannot be used as an exported binding without `from`" — that's a
// shape error, not a name-resolution error.
@(private="file")
ck_check_export_local_defined :: proc(c: ^Checker, program: ^Program) {
	if program == nil { return }
	if program.type != .Module { return }
	names: map[string]bool
	names.allocator = context.temp_allocator
	defer delete(names)
	ck_collect_module_top_level_names(program.body[:], &names)
	for stmt in program.body {
		if stmt == nil { continue }
		export, is_export := stmt^.(^ExportNamedDeclaration)
		if !is_export || export == nil { continue }
		// Re-exports (`export ... from "m"`) refer to the source module's
		// table, not this module's local bindings.
		if _, from_source := export.source.(StringLiteral); from_source { continue }
		for spec in export.specifiers {
			local_name, ok := spec.local.(IdentifierName)
			if !ok { continue }
			if !(local_name.name in names) {
				msg := fmt.tprintf("Export '%s' is not defined in the module", local_name.name)
				ck_report(c, u32(local_name.loc.span.start), msg)
			}
		}
	}
}

// ck_check_using_at_script_top — §14.3 — `using` / `await using`
// declarations are NOT allowed at the top level of a Script. The check
// runs in `check_program` where source-type and top-level position are
// trivially knowable (no need to reach into ck_walk_stmt). We do NOT
// recurse into nested blocks: `using` inside a function body in a
// Script is fine; only top-level Script position is rejected.
@(private="file")
ck_check_using_at_script_top :: proc(c: ^Checker, program: ^Program) {
	if program == nil { return }
	if program.type != .Script { return }
	for stmt in program.body {
		if stmt == nil { continue }
		decl, ok := stmt^.(^VariableDeclaration)
		if !ok || decl == nil { continue }
		switch decl.kind {
		case .Using:
			ck_report(c, u32(decl.loc.span.start),
				"'using' declaration is not allowed at the top level of a script")
		case .AwaitUsing:
			ck_report(c, u32(decl.loc.span.start),
				"'await using' declaration is not allowed at the top level of a script")
		case .Var, .Let, .Const:
			// not a using-decl
		}
	}
}

// ck_check_label_redeclared — §14.13.1 — `LabelledStatement :
// LabelIdentifier : LabelledItem` is a SyntaxError if `LabelIdentifier`
// is already in the enclosing LabelSet for the current function. Called
// from the LabeledStatement branch of ck_walk_stmt BEFORE the new
// label is pushed.
@(private="file")
ck_check_label_redeclared :: proc(c: ^Checker, ctx: ^CheckerContext, name: string, off: u32) {
	if _, have := label_in_scope(ctx, name); have {
		msg := fmt.tprintf("Label '%s' has already been declared", name)
		ck_report(c, off, msg)
	}
}

// ck_check_single_stmt_function — §13.5 / §B.3.2 — a plain
// FunctionDeclaration is forbidden as a single-statement body in
// iteration / with statements. Async / generator FunctionDeclarations
// in single-statement positions are caught by the parser as structural
// errors (always invalid grammar). The Annex B carve-out for sloppy
// `if`-consequent / `if`-alternate is honoured by NOT calling this
// helper from the IfStatement walker.
//
// `body` is the single-statement body of an iteration / with /
// labelled-statement-in-iteration construct. The check unwraps any
// LabeledStatement layers (`label1: label2: function f() {}`) before
// inspecting the inner statement.
@(private="file")
ck_check_single_stmt_function :: proc(c: ^Checker, body: ^Statement) {
	s := body
	for s != nil {
		#partial switch v in s^ {
		case ^LabeledStatement:
			if v == nil { return }
			s = v.body
		case ^FunctionDeclaration:
			if v == nil { return }
			if v.async || v.generator { return } // parser-side syntax error
			ck_report(c, u32(v.loc.span.start),
				"Function declaration cannot appear in a single-statement context")
			return
		case:
			return
		}
	}
}

// scope_hoist_vars_no_parser — mirror of parser.odin's scope_hoist_vars
// but without the (unused) ^Parser parameter. Recursively walks blocks
// / loops / try-catch / if / labelled / with / switch bodies
// collecting `var` BoundNames into the passed-in ScopeMap. Function
// declarations are scope boundaries (their own VarScope) and are NOT
// recursed into, matching the parser's behaviour.
@(private="file")
scope_hoist_vars_no_parser :: proc(stmt: ^Statement, vars: ^ScopeMap) {
	if stmt == nil { return }
	#partial switch v in stmt^ {
	case ^VariableDeclaration:
		if v == nil || v.kind != .Var { return }
		names: [dynamic]string
		names.allocator = context.temp_allocator
		reserve(&names, 4)
		for decl in v.declarations { scope_collect_pattern(decl.id, &names) }
		for n in names {
			scope_map_set_first(vars, n, v.loc.span.start)
		}
	case ^BlockStatement:
		if v != nil { for inner in v.body { scope_hoist_vars_no_parser(inner, vars) } }
	case ^IfStatement:
		if v == nil { return }
		scope_hoist_vars_no_parser(v.consequent, vars)
		if alt, have := v.alternate.(^Statement); have { scope_hoist_vars_no_parser(alt, vars) }
	case ^WhileStatement:    if v != nil { scope_hoist_vars_no_parser(v.body, vars) }
	case ^DoWhileStatement:  if v != nil { scope_hoist_vars_no_parser(v.body, vars) }
	case ^ForStatement:      if v != nil { scope_hoist_vars_no_parser(v.body, vars) }
	case ^ForInStatement:    if v != nil { scope_hoist_vars_no_parser(v.body, vars) }
	case ^ForOfStatement:    if v != nil { scope_hoist_vars_no_parser(v.body, vars) }
	case ^LabeledStatement:  if v != nil { scope_hoist_vars_no_parser(v.body, vars) }
	case ^WithStatement:     if v != nil { scope_hoist_vars_no_parser(v.body, vars) }
	case ^TryStatement:
		if v == nil { return }
		for inner in v.block.body { scope_hoist_vars_no_parser(inner, vars) }
		if h, have := v.handler.(CatchClause); have {
			for inner in h.body.body { scope_hoist_vars_no_parser(inner, vars) }
		}
		if f, have := v.finalizer.(BlockStatement); have {
			for inner in f.body { scope_hoist_vars_no_parser(inner, vars) }
		}
	case ^SwitchStatement:
		if v == nil { return }
		for sc in v.cases {
			for inner in sc.consequent { scope_hoist_vars_no_parser(inner, vars) }
		}
	}
}

// scope_process_statement_no_parser — reduced version of
// parser.odin's scope_process_statement that only needs to populate
// `lex` (and `vars` for hoisting interactions) for the catch-body /
// fn-body shadowing checks. Drops the parser-side ^Parser dependency
// (no scope_add error reporting; the caller examines the resulting
// maps for clashes externally). Mirrors only the cases the checker
// needs: VariableDeclaration (let/const/using/await using → lex; var
// → vars), FunctionDeclaration (always lex), ClassDeclaration (lex).
@(private="file")
scope_process_statement_no_parser :: proc(stmt: ^Statement, lex, vars: ^ScopeMap, is_block_scope: bool) {
	if stmt == nil { return }
	#partial switch v in stmt^ {
	case ^VariableDeclaration:
		if v == nil { return }
		names: [dynamic]string
		names.allocator = context.temp_allocator
		reserve(&names, 4)
		for decl in v.declarations { scope_collect_pattern(decl.id, &names) }
		if v.kind == .Var {
			for n in names { scope_map_set_first(vars, n, v.loc.span.start) }
		} else {
			for n in names { scope_map_set(lex, n, v.loc.span.start) }
		}
	case ^BlockStatement:
		if v == nil { return }
		hoisted := scope_map_make(4)
		for inner in v.body { scope_hoist_vars_no_parser(inner, &hoisted) }
		for it in hoisted.items {
			scope_map_set_first(vars, it.name, it.at)
		}
	case ^FunctionDeclaration:
		if v == nil { return }
		if id, ok := v.id.(BindingIdentifier); ok {
			scope_map_set(lex, id.name, id.loc.span.start)
		}
	case ^ClassDeclaration:
		if v == nil { return }
		if id, ok := v.id.(BindingIdentifier); ok {
			scope_map_set(lex, id.name, id.loc.span.start)
		}
	case ^ImportDeclaration:
		if v == nil { return }
		for spec in v.specifiers {
			if spec == nil { continue }
			switch ss in spec^ {
			case ImportSpecifier:          scope_map_set(lex, ss.local.name, ss.local.loc.span.start)
			case ImportDefaultSpecifier:   scope_map_set(lex, ss.local.name, ss.local.loc.span.start)
			case ImportNamespaceSpecifier: scope_map_set(lex, ss.local.name, ss.local.loc.span.start)
			}
		}
	}
	_ = is_block_scope
}

// ck_check_for_head_body_shadow — §13.7 — "It is a Syntax Error if
// any element of the BoundNames of ForBinding also occurs in the
// VarDeclaredNames of Statement". For for-in / for-of / vanilla
// for-loop heads with a `let` / `const` / `using` declaration, the
// loop body's hoisted `var` names cannot collide with the head's
// bound names. Mirrors parser.odin's old inline check at parse-time
// (parse_for_statement); migrated to a post-parse walk so the parser
// stays a pure tree builder.
//
// `kind_str` selects the diagnostic noun: "in" / "of" / "loop".
@(private="file")
ck_check_for_head_body_shadow :: proc(c: ^Checker, decl: ^VariableDeclaration,
                                       body: ^Statement, kind_str: string) {
	if decl == nil || body == nil { return }
	// `var` heads don't trigger — they hoist into the same scope as the
	// body's vars, so the same name on both sides is legal.
	switch decl.kind {
	case .Let, .Const, .Using, .AwaitUsing:
		// fall through
	case .Var:
		return
	}
	head_names: [dynamic]string
	head_names.allocator = context.temp_allocator
	reserve(&head_names, 4)
	for d in decl.declarations {
		scope_collect_pattern(d.id, &head_names)
	}
	if len(head_names) == 0 { return }
	body_vars := scope_map_make(4)
	scope_hoist_vars_no_parser(body, &body_vars)
	for n in head_names {
		if off, have := scope_map_get(&body_vars, n); have {
			msg: string
			switch kind_str {
			case "in", "of":
				msg = fmt.tprintf("'%s' is already declared in for-%s head", n, kind_str)
			case:
				msg = fmt.tprintf("'%s' is already declared in for-loop head", n)
			}
			ck_report(c, off, msg)
		}
	}
}

// ck_check_catch_param_body_shadow — §15.4.5 — the catch parameter's
// BoundNames may not collide with LexicallyDeclaredNames of the catch
// body. `catch (e) { let e; }` is a SyntaxError. Mirrors parser.odin's
// old inline check (parse_catch_clause).
@(private="file")
ck_check_catch_param_body_shadow :: proc(c: ^Checker, h: CatchClause) {
	param, have := h.param.(Pattern)
	if !have || param == nil { return }
	param_names: [dynamic]string
	param_names.allocator = context.temp_allocator
	reserve(&param_names, 4)
	collect_pattern_bound_names_list(param, &param_names)
	if len(param_names) == 0 { return }
	body_lex := scope_map_make(4)
	body_vars := scope_map_make(4)
	for inner in h.body.body {
		scope_process_statement_no_parser(inner, &body_lex, &body_vars, true)
	}
	for n in param_names {
		if off, ok := scope_map_get(&body_lex, n); ok {
			msg := fmt.tprintf("Catch parameter '%s' cannot be redeclared with let/const in catch block", n)
			ck_report(c, off, msg)
		}
	}
}

// ck_check_params_vs_body_lex — §15.2.1.1 / §15.5.1 — BoundNames of
// FormalParameters may not occur in LexicallyDeclaredNames of
// FunctionBody. `function f(a) { const a = 1; }` is a SyntaxError.
// Mirrors parser.odin's old `check_params_vs_body_lex` proc; the
// caller passes the parsed param list and body slice directly so the
// checker doesn't need to introspect FunctionExpression internals.
@(private="file")
ck_check_params_vs_body_lex :: proc(c: ^Checker, params: []FunctionParameter, body: []^Statement) {
	if len(params) == 0 || len(body) == 0 { return }
	param_names: [dynamic]string
	param_names.allocator = context.temp_allocator
	reserve(&param_names, len(params)*2)
	for pr in params {
		scope_collect_pattern(pr.pattern, &param_names)
	}
	if len(param_names) == 0 { return }
	body_lex := scope_map_make(4)
	body_vars := scope_map_make(4)
	for stmt in body {
		scope_process_statement_no_parser(stmt, &body_lex, &body_vars, false)
	}
	for n in param_names {
		if off, have := scope_map_get(&body_lex, n); have {
			msg := fmt.tprintf("Formal parameter '%s' cannot be redeclared with let/const in function body", n)
			ck_report(c, off, msg)
		}
	}
}

// ck_check_for_in_of_head — bundle of three for-in/of head rules.
// `kind_str` is "in" or "of" for the diagnostic noun.
//
//   1. CallExpression as LHS in strict mode (Annex B.3.4 only relaxes
//      it in sloppy script).
//   2. At most one VariableDeclarator in the head.
//   3. No initializer in the head, except the Annex B sloppy-mode
//      `for (var x = INIT in y) ;` carve-out (single Var declarator,
//      Identifier binding, for-in form).
@(private="file")
ck_check_for_in_of_head :: proc(c: ^Checker, ctx: ^CheckerContext,
                                left_expr: Maybe(^Expression),
                                left_decl: Maybe(^VariableDeclaration),
                                is_in: bool) {
	kind_str := "of"
	if is_in { kind_str = "in" }
	if e, have := left_expr.(^Expression); have && e != nil {
		if ctx.strict_mode && is_call_expression_target(e) {
			msg := fmt.tprintf("Invalid left-hand side in for-%s loop", kind_str)
			ck_report(c, u32(loc_from_expr(e).span.start), msg)
		}
		return
	}
	decl, have_decl := left_decl.(^VariableDeclaration)
	if !have_decl || decl == nil { return }
	if len(decl.declarations) > 1 {
		msg := fmt.tprintf("Only a single declaration is allowed in a for-%s loop", kind_str)
		ck_report(c, u32(decl.loc.span.start), msg)
	}
	for_in_init_ok := is_in &&
	                  !ctx.strict_mode &&
	                  decl.kind == .Var &&
	                  len(decl.declarations) == 1
	if for_in_init_ok && len(decl.declarations) == 1 {
		if _, is_id := decl.declarations[0].id.(^Identifier); !is_id {
			for_in_init_ok = false
		}
	}
	if for_in_init_ok { return }
	for d in decl.declarations {
		if _, have_init := d.init.(^Expression); have_init {
			msg := fmt.tprintf("for-%s loop variable declaration may not have an initializer", kind_str)
			ck_report(c, u32(decl.loc.span.start), msg)
			return // one diagnostic per head, matching parser behaviour
		}
	}
}

// ck_check_unary_delete_local — §13.5.1 — in strict mode,
// `delete IdentifierReference` is a SyntaxError. The check peels
// ParenthesizedExpression layers (only present when --preserve-parens
// is on) so `delete (x)` is rejected too. Member access, computed,
// and arbitrary non-reference operands stay legal.
@(private="file")
ck_check_unary_delete_local :: proc(c: ^Checker, ctx: ^CheckerContext, e: ^UnaryExpression) {
	if e == nil || e.operator != .Delete || !ctx.strict_mode { return }
	if e.argument == nil { return }
	inner := e.argument
	for inner != nil {
		pe, is_paren := inner^.(^ParenthesizedExpression)
		if !is_paren || pe == nil { break }
		inner = pe.expression
	}
	if inner == nil { return }
	ident, is_id := inner^.(^Identifier)
	if !is_id || ident == nil { return }
	msg := fmt.tprintf("Deleting local variable '%s' is not allowed in strict mode", ident.name)
	ck_report(c, u32(e.loc.span.start), msg)
}

// ck_check_catch_param_dups — §15.4.5 — names introduced by a catch
// clause's binding pattern must be unique. `catch ({a, a}) {}` and
// `catch ([x, x]) {}` etc. are SyntaxErrors. Re-uses parser.odin's
// pattern-name collector.
@(private="file")
ck_check_catch_param_dups :: proc(c: ^Checker, h: CatchClause) {
	param, have := h.param.(Pattern)
	if !have || param == nil { return }
	names: [dynamic]string
	names.allocator = context.temp_allocator
	reserve(&names, 4)
	collect_pattern_bound_names_list(param, &names)
	for i := 0; i < len(names); i += 1 {
		for j := i + 1; j < len(names); j += 1 {
			if names[i] == names[j] {
				msg := fmt.tprintf("Identifier '%s' has already been declared in catch clause", names[i])
				ck_report(c, u32(h.loc.span.start), msg)
				return
			}
		}
	}
}

// ck_collect_class_private_names — build the set of declared
// PrivateIdentifier names for a class body. Used by ck_walk_class to
// push the set onto the private-name stack before walking elements.
// Mirrors parser.odin's `pn_collect_class_names`.
@(private="file")
ck_collect_class_private_names :: proc(body: ClassBody, alloc: mem.Allocator) -> map[string]bool {
	names: map[string]bool
	names.allocator = alloc
	for elem in body.body {
		if elem.key == nil { continue }
		if pid, ok := elem.key^.(^PrivateIdentifier); ok && pid != nil && len(pid.name) > 0 {
			names[pid.name] = true
		}
	}
	return names
}

// ck_private_name_in_scope — walk the private-name stack top-down
// (innermost class first) looking for `name`. Returns true if the
// name is declared in an enclosing class body.
@(private="file")
ck_private_name_in_scope :: proc(ctx: ^CheckerContext, name: string) -> bool {
	for i := len(ctx.private_name_stack) - 1; i >= 0; i -= 1 {
		if _, ok := ctx.private_name_stack[i][name]; ok { return true }
	}
	return false
}

// ck_check_private_name_resolved — §15.7.3 — every PrivateName
// reference (`obj.#x`, `#x in y`, bare `#x`) must be declared in an
// enclosing ClassBody. Empty-name PrivateIdentifiers (lone `#` from a
// malformed hashbang etc.) are skipped; the parser already reports a
// structural error there and the resolution check would only emit a
// duplicate diagnostic.
@(private="file")
ck_check_private_name_resolved :: proc(c: ^Checker, ctx: ^CheckerContext, pid: ^PrivateIdentifier) {
	if pid == nil || len(pid.name) == 0 { return }
	if ck_private_name_in_scope(ctx, pid.name) { return }
	msg := fmt.tprintf("Private field '#%s' must be declared in an enclosing class", pid.name)
	ck_report(c, u32(pid.loc.span.start), msg)
}

// ck_check_class_private_static_mismatch — §15.7.1 — a private getter /
// setter pair must have matching static-ness. `static get #f() {}`
// paired with `set #f(v) {}` is a SyntaxError because the private slot
// is shared across statics and instances and can't straddle.
//
// Walks `cls.body.body`, building a per-name accumulator of get/set
// static flags as elements are seen, then fires once per mismatch. The
// parser's shape is preserved verbatim — the check is purely AST-driven
// (no parse-time state needed).
@(private="file")
ck_check_class_private_static_mismatch :: proc(c: ^Checker, cls: ^ClassExpression) {
	if cls == nil { return }
	PrivateGetSet :: struct { has_get, has_set, get_static, set_static: bool, set_loc: u32 }
	seen: map[string]PrivateGetSet
	seen.allocator = context.temp_allocator
	defer delete(seen)
	for elem in cls.body.body {
		if elem.key == nil { continue }
		pid, is_priv := elem.key^.(^PrivateIdentifier)
		if !is_priv || pid == nil { continue }
		name := pid.name
		prev, _ := seen[name]
		switch elem.kind {
		case .Get:
			if prev.has_set && prev.set_static != elem.static {
				msg := fmt.tprintf("Private getter and setter for '#%s' must both be static or both be non-static", name)
				ck_report(c, u32(elem.loc.span.start), msg)
			}
			prev.has_get = true
			prev.get_static = elem.static
		case .Set:
			if prev.has_get && prev.get_static != elem.static {
				msg := fmt.tprintf("Private getter and setter for '#%s' must both be static or both be non-static", name)
				ck_report(c, u32(elem.loc.span.start), msg)
			}
			prev.has_set = true
			prev.set_static = elem.static
		case .Method, .Constructor, .StaticBlock:
			// Field/method/ctor/staticblock don't pair with get/set.
		}
		seen[name] = prev
	}
}

// ck_check_duplicate_param_names — §15.5.1 / §15.6.1 / §15.8.1.
// FunctionDeclaration / FunctionExpression / class method / object
// method (every non-arrow function) AND arrow with non-simple
// parameter list:
//   * Strict-mode bodies require UniqueFormalParameters even with a
//     simple parameter list.
//   * Generators / async / async-generators inherit
//     UniqueFormalParameters regardless of outer strict mode.
//   * Sloppy-mode regular functions with a non-simple parameter list
//     are also UniqueFormalParameters.
//
// `is_strict` mirrors the parser's `strict := p.strict_mode ||
// strict_override`; `force_non_simple` mirrors `force_when_non_simple
// && !params_are_simple(params)`. Callers from ck_walk_function pick
// the right combination based on the function flavour.
@(private="file")
ck_check_duplicate_param_names :: proc(c: ^Checker, fn_loc: u32,
                                       params: []FunctionParameter,
                                       is_strict: bool,
                                       force_non_simple: bool) {
	if len(params) == 0 { return }
	if !is_strict && !force_non_simple { return }
	names: [dynamic]string
	names.allocator = context.temp_allocator
	reserve(&names, 4)
	for pr in params { collect_bound_names(pr.pattern, &names) }
	n := len(names)
	if n < 2 { return }
	for i := 1; i < n; i += 1 {
		for j := 0; j < i; j += 1 {
			if names[i] == names[j] {
				msg: string
				if is_strict {
					msg = fmt.tprintf("Duplicate parameter name '%s' in strict mode", names[i])
				} else {
					msg = fmt.tprintf("Duplicate parameter name '%s' with non-simple parameter list", names[i])
				}
				ck_report(c, fn_loc, msg)
				return // one diagnostic per call site, matching parser
			}
		}
	}
}

// CkBindingFlavour selects the diagnostic phrasing for the
// strict-mode binding-identifier check below.
@(private="file")
CkBindingFlavour :: enum {
	Parameter,    // "Parameter name 'NAME' is not allowed in strict mode"
	Generic,      // "'NAME' cannot be used as a binding name in strict mode"
}

// ck_check_strict_binding_pattern — §13.1.1 / §15.5.1 / §15.6.1 /
// §15.8.1 — in strict mode, `eval` / `arguments` and the strict-
// reserved words (`let`, `static`, `yield`, `implements`, `interface`,
// `package`, `private`, `protected`, `public`) cannot appear as a
// BindingIdentifier. Recurses through Object / Array / Assignment /
// Rest patterns so destructured forms get the same check.
//
// `flavour` picks the eval/arguments diagnostic phrasing; the strict-
// reserved phrasing is shared. Mirrors parser.odin's split between
// `report_strict_param_pattern` (Parameter flavour) and
// `parse_binding_identifier`'s eval/arguments branch (Generic flavour).
@(private="file")
ck_check_strict_binding_pattern :: proc(c: ^Checker, pat: Pattern, flavour: CkBindingFlavour) {
	if pat == nil { return }
	switch v in pat {
	case ^Identifier:
		if v == nil { return }
		if is_eval_or_arguments(v.name) {
			msg: string
			switch flavour {
			case .Parameter:
				msg = fmt.tprintf("Parameter name '%s' is not allowed in strict mode", v.name)
			case .Generic:
				msg = fmt.tprintf("'%s' cannot be used as a binding name in strict mode", v.name)
			}
			ck_report(c, u32(v.loc.span.start), msg)
		} else if is_strict_reserved_simple_name(v.name) {
			msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", v.name)
			ck_report(c, u32(v.loc.span.start), msg)
		}
	case ^ObjectPattern:
		if v == nil { return }
		for prop in v.properties { ck_check_strict_binding_pattern(c, prop.value, flavour) }
	case ^ArrayPattern:
		if v == nil { return }
		for elem in v.elements {
			if inner, ok := elem.(Pattern); ok { ck_check_strict_binding_pattern(c, inner, flavour) }
		}
	case ^AssignmentPattern:
		if v == nil { return }
		ck_check_strict_binding_pattern(c, v.left, flavour)
	case ^RestElement:
		if v == nil { return }
		ck_check_strict_binding_pattern(c, v.argument, flavour)
	case ^MemberExpression:
		return
	}
}

// ck_check_strict_param_pattern — thin wrapper preserving the
// parameter-flavoured diagnostic for callers who want the old name.
@(private="file")
ck_check_strict_param_pattern :: proc(c: ^Checker, pat: Pattern) {
	ck_check_strict_binding_pattern(c, pat, .Parameter)
}

// ck_check_strict_eval_arguments_in_target — §13.15.1 — in strict
// mode, an assignment / for-in/of LHS may not name `eval` or
// `arguments` (covers the destructured forms by recursing through
// ArrayExpression / ObjectExpression / SpreadElement / nested
// AssignmentExpression default-init). Mirrors parser.odin's
// `report_strict_eval_arguments_in_target`.
@(private="file")
ck_check_strict_eval_arguments_in_target :: proc(c: ^Checker, expr: ^Expression) {
	if expr == nil { return }
	#partial switch e in expr^ {
	case ^Identifier:
		if e == nil { return }
		if is_eval_or_arguments(e.name) {
			msg := fmt.tprintf("Assignment to '%s' is not allowed in strict mode", e.name)
			ck_report(c, u32(e.loc.span.start), msg)
		}
	case ^ParenthesizedExpression:
		if e != nil { ck_check_strict_eval_arguments_in_target(c, e.expression) }
	case ^ArrayExpression:
		if e == nil { return }
		for elem in e.elements {
			if inner, ok := elem.(^Expression); ok && inner != nil {
				ck_check_strict_eval_arguments_in_target(c, inner)
			}
		}
	case ^ObjectExpression:
		if e == nil { return }
		for prop in e.properties {
			ck_check_strict_eval_arguments_in_target(c, prop.value)
		}
	case ^SpreadElement:
		if e != nil { ck_check_strict_eval_arguments_in_target(c, e.argument) }
	case ^AssignmentExpression:
		if e == nil { return }
		if e.operator == .Assign {
			ck_check_strict_eval_arguments_in_target(c, e.left)
		}
	}
}

// ck_check_strict_update_eval_arguments — §13.4.4 — in strict mode,
// `++`/`--` (prefix or postfix) may not be applied to `eval` or
// `arguments` IdentifierReference. Mirrors
// `report_strict_update_on_eval_or_arguments`.
@(private="file")
ck_check_strict_update_eval_arguments :: proc(c: ^Checker, ctx: ^CheckerContext, arg: ^Expression) {
	if !ctx.strict_mode || arg == nil { return }
	ident, is_id := arg^.(^Identifier)
	if !is_id || ident == nil { return }
	if is_eval_or_arguments(ident.name) {
		msg := fmt.tprintf("Update of '%s' is not allowed in strict mode", ident.name)
		ck_report(c, u32(ident.loc.span.start), msg)
	}
}

// ck_check_binding_identifier_strict — §13.1.1 / §15.7.1 — `eval` /
// `arguments` AND strict-reserved words (`let`, `static`, `yield`,
// `implements`, `interface`, `package`, `private`, `protected`,
// `public`) cannot serve as a BindingIdentifier in strict-mode code.
//
// `is_param` selects the parameter-flavoured diagnostic for `eval` /
// `arguments` (matching parser.odin's `report_strict_param_pattern`).
// Otherwise the generic binding-name diagnostic is used.
//
// Note: when called for a function name we use a function-name-flavoured
// diagnostic via the `is_function_name` flag (the parser said
// "Function name 'NAME' is not allowed in strict mode").
@(private="file")
CkBindingPosition :: enum {
	Generic,        // var/let/const declarator id, catch param, ImportSpecifier.local
	FunctionName,   // FunctionDeclaration.id / FunctionExpression.id
}

@(private="file")
ck_check_binding_identifier_strict :: proc(c: ^Checker, ctx: ^CheckerContext,
                                          name: string, off: u32,
                                          pos: CkBindingPosition = .Generic) {
	if !ctx.strict_mode { return }
	if is_eval_or_arguments(name) {
		msg: string
		switch pos {
		case .FunctionName:
			msg = fmt.tprintf("Function name '%s' is not allowed in strict mode", name)
		case .Generic:
			msg = fmt.tprintf("'%s' cannot be used as a binding name in strict mode", name)
		}
		ck_report(c, off, msg)
		return
	}
	if is_strict_reserved_simple_name(name) {
		msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", name)
		ck_report(c, off, msg)
	}
}

// ck_check_identifier_reference_strict — §12.6.1.1 — strict-mode
// IdentifierReference cannot be `let`, `static`, `yield`,
// `implements`, `interface`, `package`, `private`, `protected`,
// `public`. Fires for ^Identifier nodes encountered in expression
// position (ck_walk_expr's ^Identifier case). Note `await` reaches
// this proc only through escaped forms; the unescaped `.Await` token
// never produces an ^Identifier AST node.
@(private="file")
ck_check_identifier_reference_strict :: proc(c: ^Checker, ctx: ^CheckerContext, id: ^Identifier) {
	if !ctx.strict_mode || id == nil { return }
	if !is_strict_reserved_simple_name(id.name) { return }
	msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", id.name)
	ck_report(c, u32(id.loc.span.start), msg)
}

// ck_check_identifier_await_reserved — §16.2 / §15.7.5 — the cooked
// IdentifierName `await` cannot serve as an IdentifierReference in a
// context where `await` is reserved (async function body, async
// function params, class static block body). Plain (non-escaped)
// `await` always lexes as `.Await` and is parsed as AwaitExpression
// elsewhere; the only way this AST shape is reached with
// `name == "await"` is via an escaped form like `\u0061wait`, hence
// the `id.has_escape` gate (matches parser.odin's lex-time has_escape
// gating in parse_unary_expr's identifier fast-path and
// parse_primary_expr's fallback identifier branch).
//
// Module top-level is intentionally NOT a reserved context here — OXC
// (kessel's conformance oracle) accepts `let await = 1;` at module
// top-level binding positions, so the checker matches OXC.
@(private="file")
ck_check_identifier_await_reserved :: proc(c: ^Checker, ctx: ^CheckerContext, id: ^Identifier) {
	if id == nil || id.name != "await" { return }
	if !id.has_escape { return }
	if ctx.in_async || ctx.in_class_static_block {
		ck_report(c, u32(id.loc.span.start),
			"'await' is not allowed as an identifier in this context")
	}
}

// ck_check_import_specifier_local — §16.2.2 — ImportedBinding is a
// BindingIdentifier in strict mode (module code). `eval` and
// `arguments` are forbidden.
@(private="file")
ck_check_import_specifier_local :: proc(c: ^Checker, name: string, off: u32) {
	if is_eval_or_arguments(name) {
		msg := fmt.tprintf("'%s' cannot be used as an import binding name", name)
		ck_report(c, off, msg)
	}
}

// ck_walk_import_decl — visits each ImportSpecifierSpec to apply
// §16.2.2 to the binding-identifier `local` field. Called from the
// ImportDeclaration branch of ck_walk_stmt.
@(private="file")
ck_walk_import_decl :: proc(c: ^Checker, ctx: ^CheckerContext, decl: ^ImportDeclaration) {
	if decl == nil { return }
	for spec in decl.specifiers {
		if spec == nil { continue }
		switch s in spec^ {
		case ImportSpecifier:
			ck_check_import_specifier_local(c, s.local.name, u32(s.local.loc.span.start))
		case ImportDefaultSpecifier:
			ck_check_import_specifier_local(c, s.local.name, u32(s.local.loc.span.start))
		case ImportNamespaceSpecifier:
			ck_check_import_specifier_local(c, s.local.name, u32(s.local.loc.span.start))
		}
	}
}

// ck_check_for_in_of_init_eval_args — §13.7.5.1 — for-in/of LHS in
// strict mode may not name eval/arguments (covers destructured forms).
// Wrapper around ck_check_strict_eval_arguments_in_target gated on
// strict mode and the for-head LHS expression position.
@(private="file")
ck_check_for_in_of_init_eval_args :: proc(c: ^Checker, ctx: ^CheckerContext, left_expr: Maybe(^Expression)) {
	if !ctx.strict_mode { return }
	e, have := left_expr.(^Expression)
	if !have || e == nil { return }
	ck_check_strict_eval_arguments_in_target(c, e)
}

// ============================================================================
// Append helper — mirrors parser.odin's bump_append shape, but for the
// CheckerContext label stack which uses the checker's allocator.
// ============================================================================

@(private="file")
bump_append_ck :: proc(ctx: ^CheckerContext, label: CheckerLabel) {
	append(&ctx.labels, label)
}
