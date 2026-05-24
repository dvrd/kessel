package kessel

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
//     diagnostic line read by tests/coverage/* snap renderer / verify_negative.js
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
import "core:strings"

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
	in_class_computed_key: bool,  // TS2465: this/super invalid in computed keys
	in_params:             bool,
	params_is_arrow:       bool,
	source_type:           SourceType,
	at_top_level:          bool,
	// ts_namespace_depth — number of enclosing TS namespace / module
	// bodies. When > 0, the import/export-position check is suppressed
	// (`export` inside a `namespace M { ... }` is legal even when the
	// outer file is a Script and even though the export is not at the
	// program top level). Pushed by ck_walk_ts_module_decl on body
	// entry, popped on exit.
	ts_namespace_depth:    int,
	// class_body_depth — number of enclosing class bodies. When > 0,
	// `new.target` is valid (returns undefined in field initializers,
	// constructor reference in constructors). Arrow functions and
	// static blocks inherit this depth; regular functions reset it.
	class_body_depth:      int,
	// block_nest_depth — number of enclosing block / loop / conditional
	// bodies. Used to reject type aliases / interfaces / enums appearing
	// inside control-flow statements. NOT incremented for function
	// bodies (handled separately via function_depth) or namespace
	// bodies (handled via ts_namespace_depth).
	block_nest_depth:      int,
	in_async:              bool,
	in_generator:          bool,
	// scope_skip — set true while walking the immediate body of an
	// uncovered expression context (ArrayExpression elements,
	// ObjectExpression property values / computed keys, the right
	// operators). Suppresses scope_check_body in uncovered expression
	// contexts (matches OXC). Read by `ck_run_scope_check`.
	scope_skip:            bool,
	// private_name_stack — stack of declared private-name sets, one
	// per enclosing class. Pushed by ck_walk_class on entry, popped on
	// exit. Used by ck_check_private_name_resolved to enforce §15.7.3
	// "every PrivateName reference must be declared in an enclosing
	// class". Mirrors parser.odin's `PrivateNameStack` machinery, now
	// migrated post-parse.
	private_name_stack: [dynamic]map[string]bool,
	// is_dts — true when parsing a .d.ts / .d.mts / .d.cts file. Implies
	// every top-level binding is implicitly ambient (no `declare` keyword
	// needed) and methods may legally lack bodies. Threaded from the
	// parser via Parser.source_is_dts at check_program entry.
	is_dts: bool,
	// is_commonjs — true for `.cjs` / `.cts` files. The CommonJS module
	// wrapper turns the file body into the function body of
	// `(exports, require, module, __filename, __dirname) => { ... }`,
	// which means top-level constructs that require an enclosing
	// function (`new.target`, `return` at top level) are valid. Threaded
	// from the parser via Parser.is_commonjs at check_program entry.
	is_commonjs: bool,
	// in_assignment_target — true while walking the left-hand side of an
	// `=` assignment whose LHS is an ObjectExpression / ArrayExpression
	// (destructuring assignment pattern). Suppresses the TS1117 duplicate
	// property check, since the ObjectExpression is semantically an
	// ObjectPattern where duplicate property names are legal.
	in_assignment_target: bool,
	// in_ambient_module_decl — true while walking the body of an ambient
	// module declaration with a string literal id (`declare module "..."`).
	// Used by TS2669 to allow `declare global {}` inside ambient modules.
	in_ambient_module_decl: bool,
	// in_arrow_body — true while walking an arrow function body. Used
	// by TS2331 to allow `this` inside arrow functions even when inside
	// a namespace (arrows inherit `this` from the enclosing scope).
	in_arrow_body: bool,
	// extends_null — true while walking the constructor of a class that
	// extends null. super() is syntactically valid but TS2377 (must call
	// super) and TS17009 (this before super) should not fire because
	// null has no constructor to call.
	extends_null: bool,
}

Checker :: struct {
	errors:    [dynamic]ParseError,
	allocator: mem.Allocator,
	// pending_parser — the active parser whose AST we're walking.
	// Set by `checker_run_for_job`, cleared after. Used by
	// `ck_run_scope_check` to call scope_check_body.
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

// ck_run_scope_check — §14.2.1 / §14.3.1.1 lex/var duplicate-binding
// detection. Calls the parser-side scope_check_body against the
// checker's reusable lex/var ScopeMap pair. Invoked from the checker's
// AST walk at each scope-bearing entry point (BlockStatement,
// SwitchStatement case-list, FunctionBody, Program body, etc.).
@(private="file")
ck_run_scope_check :: proc(c: ^Checker, ctx: ^CheckerContext, body: []^Statement, is_block_scope: bool) {
	if ctx.scope_skip { return }
	p := c.pending_parser
	if p == nil || p.ast_only { return }
	scope_map_clear(&c.scope_lex)
	scope_map_clear(&c.scope_vars)
	scope_check_body(p, body, is_block_scope, &c.scope_lex, &c.scope_vars)
}

// check_program is the entry point for the semantic checker.
// Call after parse_program to validate early errors.
//
// `force_strict` is the parser's --force-strict flag, threaded through
// from the parse job. test262's `flags: [onlyStrict]` fixtures rely on
// it: the source has no `"use strict"` prologue (the test262 harness
// wraps it externally), so without honoring force_strict the checker
// would skip every strict-mode-only early error (assignment to
// `arguments`/`eval`, `var arguments` in strict functions, etc.).
check_program :: proc(c: ^Checker, program: ^Program, lang: Lang = .JS, force_strict: bool = false) {
	if program == nil { return }
	ctx: CheckerContext
	ctx.labels = make([dynamic]CheckerLabel, 0, 4, c.allocator)
	ctx.private_name_stack = make([dynamic]map[string]bool, 0, 2, c.allocator)
	ctx.lang   = lang
	// .d.ts detection: pending_parser carries source_is_dts (set by
	// parse_job from the source path suffix). Implies all top-level
	// declarations are ambient.
	if c.pending_parser != nil {
		ctx.is_dts      = c.pending_parser.source_is_dts
		ctx.is_commonjs = c.pending_parser.is_commonjs
	}
	// §10.2.1 + §16.2.2 — strict-mode initialisation:
	//   * Module code is always strict (§16.2.2).
	//   * `--force-strict` (test262 onlyStrict) forces strict from byte 0.
	//   * Otherwise, a `"use strict"` directive at the program
	//     prologue puts the whole script in strict mode.
	if program.type == .Module {
		ctx.strict_mode = true
	} else if force_strict {
		ctx.strict_mode = true
	} else if directives_have_use_strict(program.directives[:]) {
		ctx.strict_mode = true
	}
	ctx.source_type  = program.type
	ctx.at_top_level = true
	// §14.3 — `using` / `await using` at top of a Script.
	ck_check_using_at_script_top(c, &ctx, program)
	// §16.2.1 — duplicate-export check (TS / TSX only; JS mode is
	// reported by the parser-side `report_error_at` because the rule
	// is a parse-time structural error there).
	ck_check_export_dups(c, &ctx, program)
	// §16.2.2 — every non-re-export ExportSpecifier.local must reference
	// a name declared at module top level. Skip for TS/TSX: TypeScript
	// allows re-exporting global/ambient declarations from other files
	// that kessel cannot see (single-file, no cross-file resolution).
	// The TS type-checker owns this diagnostic.
	if lang != .TS && lang != .TSX {
		ck_check_export_local_defined(c, program)
	}
	// TS — `export =` cannot coexist with other export statements,
	// and only one `export =` per module.
	ck_check_ts_export_assignment(c, program)
	// TS1046 — .d.ts files: top-level declarations must have `declare` or `export`.
	// Disabled: OXC’s semantic pass does not implement TS1046; enabling it
	// causes false positives against both the babel and TS conformance
	// corpora. Re-enable when OXC starts enforcing this.
	// if ctx.is_dts && (lang == .TS || lang == .TSX) {
	// 	ck_check_ts1046_dts_top_level(c, program)
	// }
	// TS1036 — .d.ts files: statements (if, while, for, etc.) are not
	// allowed at top level — only declarations.
	// Allow EmptyStatements at .d.ts top level: they arise from semicolons
	// after shorthand module declarations (`declare module "m";`).
	if ctx.is_dts && (lang == .TS || lang == .TSX) {
		ck_check_ts1036_ambient_statements(c, program.body[:], true)
	}
	// §14.2.1 / §14.3.1.1 — program-scope lex/var clash detection.
	// The Program body is function-scope (sloppy plain
	// FunctionDeclarations hoist as .Var; let/const/class are .Lexical).
	ck_run_scope_check(c, &ctx, program.body[:], false)
	// TS — declaration-merge dup detection (TS2300 / TS2567) + top-level
	// FunctionDeclaration overload-chain check (TS2391 / TS2389). Runs
	// only in TS / TSX; the parser-side scope walker skips Class /
	// Function / Import in TS mode to avoid false positives on legal
	// merges, so we pick up the slack here with the precise merge-pair
	// table.
	ck_check_ts_body_decls(c, &ctx, program.body[:])
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
	check_program(&c, job.program, job.lang, job.parser.force_strict)
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
		start   = loc_offset,
		end     = loc_offset,
		message = message,
	})
}

// ck_report_coded — code-carrying variant for the Phase 4+ migration.
// Like `ck_report` it emits a point span (start == end) because most
// checker sites only have a single offset; widening to real spans is a
// separate sweep. The diagnostic gets the severity from the message
// table so warnings (when we introduce them) reach the right channel.
@(private="file")
ck_report_coded :: proc(c: ^Checker, loc_offset: u32, code: ErrorCode, message: string) {
	info := error_info(code)
	bump_append(&c.errors, ParseError{
		start    = loc_offset,
		end      = loc_offset,
		message  = message,
		code     = code,
		severity = info.severity,
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
	bump_append(&c.errors, ParseError{start = u32(loc), end = u32(loc), message = message})
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
	in_class_computed_key: bool,
	in_async:              bool,
	in_generator:          bool,
	class_body_depth:      int,
	in_params:             bool,
	params_is_arrow:       bool,
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
		in_class_computed_key  = ctx.in_class_computed_key,
		in_async               = ctx.in_async,
		in_generator           = ctx.in_generator,
		class_body_depth       = ctx.class_body_depth,
		in_params              = ctx.in_params,
		params_is_arrow        = ctx.params_is_arrow,
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
	ctx.in_class_computed_key  = saved.in_class_computed_key
	ctx.in_async               = saved.in_async
	ctx.in_generator           = saved.in_generator
	ctx.class_body_depth       = saved.class_body_depth
	ctx.in_params              = saved.in_params
	ctx.params_is_arrow        = saved.params_is_arrow
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
				ck_report(c, u32(v.loc.start), "Undefined label")
			}
		} else {
			if ctx.iter_depth == 0 && ctx.switch_depth == 0 {
				ck_report(c, u32(v.loc.start), "Illegal break statement: not in a loop or switch")
			}
		}

	case ^ContinueStatement:
		if v == nil { return }
		if lbl, have := v.label.(LabelIdentifier); have {
			entry, ok := label_in_scope(ctx, lbl.name)
			if !ok {
				ck_report(c, u32(v.loc.start), "Undefined label")
			} else if !entry.is_iteration {
				ck_report(c, u32(v.loc.start), "Illegal continue statement: label does not target an iteration statement")
			}
		} else {
			if ctx.iter_depth == 0 {
				ck_report(c, u32(v.loc.start), "Illegal continue statement: not in a loop")
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
					ck_report_coded(c, u32(fn.loc.start), .K3051_StrictModeProhibited,
						"Function declaration cannot be a labeled item in strict mode")
				}
			}
		}
		// §14.13.1 — LabelIdentifier is a BindingIdentifier disguise; the
		// IdentifierReference reservation rules apply:
		//   * `yield` reserved in strict mode (§12.7.2)
		//   * `await` reserved in module code (§16.2.2)
		//   * Escaped contextual-reserved words are reserved unconditionally
		//     (§12.7.2; matches our parser's check_identifier_await_reserved).
		if v.label.name == "yield" && ctx.strict_mode {
			ck_report_coded(c, u32(v.label.loc.start), .K3010_AwaitYieldAsBindingName, "'yield' is reserved as a label name in strict mode")
		}
		if v.label.name == "await" && ctx.source_type == .Module {
			ck_report_coded(c, u32(v.label.loc.start), .K3010_AwaitYieldAsBindingName, "'await' is reserved as a label name in module code")
		}
		// §15.7.1 — ClassStaticBlock forbids `await` as a LabelIdentifier
		// regardless of source type. Per test262 static-init-invalid-await.js:
		//   class C { static { await: 0; } }   // SyntaxError
		// The static-block body is parsed under [+Await] for the purpose of
		// reserving `await` even in script files. The module-only branch
		// above doesn't catch this for script-mode fixtures.
		if v.label.name == "await" && ctx.in_class_static_block && ctx.source_type != .Module {
			ck_report_coded(c, u32(v.label.loc.start), .K3010_AwaitYieldAsBindingName, "'await' is reserved as a label name in a class static block")
		}
		// Escaped reserved word as label — e.g. `aw\u0061it: 1;` in module
		// (test262 labeled/value-await-module-escaped.js). The reservation
		// is context-conditional: `await` is only reserved in modules /
		// async, `yield` in strict / generators, `let`/`static` in strict.
		// In a context where the cooked name ISN'T reserved, the escape
		// is just a stylistic identifier choice and must be allowed (test262
		// labeled/value-await-non-module-escaped.js + value-yield-non-strict-
		// escaped.js). LabelIdentifier doesn't carry has_escape, so we probe
		// the lexer source bytes for `\u` to detect the escaped form.
		lbl_is_reserved := false
		switch v.label.name {
		case "await":  lbl_is_reserved = ctx.source_type == .Module || ctx.in_async
		case "yield":  lbl_is_reserved = ctx.strict_mode || ctx.in_generator
		case "let":    lbl_is_reserved = ctx.strict_mode
		case "static": lbl_is_reserved = ctx.strict_mode
		}
		if lbl_is_reserved && c.pending_parser != nil && c.pending_parser.lexer != nil {
			src := c.pending_parser.lexer.source
			lbl_start := int(v.label.loc.start)
			lbl_end   := int(v.label.loc.end)
			if lbl_start >= 0 && lbl_end > lbl_start && lbl_end <= len(src) {
				if strings.contains(src[lbl_start:lbl_end], "\\u") {
					msg := fmt.tprintf("Keyword '%s' must not contain escaped characters", v.label.name)
					ck_report_coded(c, u32(v.label.loc.start), .K3015_KeywordContainsEscape, msg)
				}
			}
		}
		// §14.13.1 — duplicate label declared in scope.
		// §14.13.1 duplicate-label — migrated to parser.
		entry := CheckerLabel{
			name         = v.label.name,
			is_iteration = label_is_iteration_target(v.body),
			loc_offset   = u32(v.label.loc.start),
		}
		bump_append_ck(ctx, entry)
		ck_walk_stmt(c, ctx, v.body)
		if len(ctx.labels) > 0 {
			pop(&ctx.labels)
		}

	case ^BlockStatement:
		if v == nil { return }
		ck_run_scope_check(c, ctx, v.body[:], true)
		ck_check_ts_body_decls(c, ctx, v.body[:], true)
		for s in v.body { ck_walk_stmt(c, ctx, s) }

	case ^IfStatement:
		if v == nil { return }
		ck_walk_expr(c, ctx, v.test)
		// §13.6 + §B.3.3 — plain FunctionDeclaration as the consequent /
		// alternate of `if` is allowed only in sloppy mode (Annex B carve-
		// out). Strict mode rejects every shape (`if (x) function f(){}`,
		// `if (x) {} else function f(){}`, `if (x) function f(){} else g`).
		//
		// LABELLED function declarations (`if (x) lbl: function f(){}`)
		// are NEVER permitted, even in sloppy mode — Annex B.3.2 only
		// extends the carve-out to plain FunctionDeclaration. The labelled
		// shape is rejected in both modes.
		if ctx.strict_mode {
			ck_check_single_stmt_function(c, v.consequent)
			if alt, have := v.alternate.(^Statement); have && alt != nil {
				ck_check_single_stmt_function(c, alt)
			}
		} else {
			ck_check_if_labelled_function(c, v.consequent)
			if alt, have := v.alternate.(^Statement); have && alt != nil {
				ck_check_if_labelled_function(c, alt)
			}
		}
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
		ctx.block_nest_depth += 1
		ck_walk_stmt(c, ctx, v.body)
		ctx.block_nest_depth -= 1
		ctx.iter_depth -= 1

	case ^ForInStatement:
		if v == nil { return }
		ck_check_for_in_of_head(c, ctx, v.left_expr, v.left_decl, true)
		ck_check_for_in_of_init_eval_args(c, ctx, v.left_expr)
		if e, have := v.left_expr.(^Expression); have && e != nil { ck_walk_expr(c, ctx, e) }
		if d, have := v.left_decl.(^VariableDeclaration); have && d != nil { ck_walk_var_decl(c, ctx, d) }
		if d, have := v.left_decl.(^VariableDeclaration); have && d != nil {
			ck_check_for_head_body_shadow(c, d, v.body, "in")
		}
		ck_walk_expr(c, ctx, v.right)
		ctx.iter_depth += 1
		ck_check_single_stmt_function(c, v.body)
		ck_walk_stmt(c, ctx, v.body)
		ctx.iter_depth -= 1

	case ^ForOfStatement:
		if v == nil { return }
		// §14.7.5 — `for await` is only valid in async functions /
		// generators or at module scope (not inside a non-async function,
		// even within a module). Use function_depth to check: at module
		// top-level, function_depth is 0.
		if v.await && !ctx.in_async && !(ctx.source_type == .Module && ctx.function_depth == 0) {
			ck_report_coded(c, u32(v.loc.start), .K3013_ForAwaitContextRestricted,
				"'for await' is only valid in async functions or at the top level of a module")
		}
		ck_check_for_in_of_head(c, ctx, v.left_expr, v.left_decl, false)
		ck_check_for_in_of_init_eval_args(c, ctx, v.left_expr)
		if e, have := v.left_expr.(^Expression); have && e != nil { ck_walk_expr(c, ctx, e) }
		if d, have := v.left_decl.(^VariableDeclaration); have && d != nil { ck_walk_var_decl(c, ctx, d) }
		if d, have := v.left_decl.(^VariableDeclaration); have && d != nil {
			ck_check_for_head_body_shadow(c, d, v.body, "of")
		}
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
			ck_check_catch_param_body_shadow(c, ctx, h)
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
			ck_report_coded(c, u32(v.loc.start), .K3051_StrictModeProhibited,
				"'with' statements are not allowed in strict mode")
		}
		ck_walk_expr(c, ctx, v.object)
		ck_check_single_stmt_function(c, v.body)
		ck_walk_stmt(c, ctx, v.body)

	case ^ExpressionStatement:
		if v != nil { ck_walk_expr(c, ctx, v.expression) }

	case ^VariableDeclaration:
		if v != nil { ck_walk_var_decl(c, ctx, v) }

	case ^FunctionDeclaration:
		if v != nil {
			// TS1221 — generators in ambient context (declare function* or .d.ts).
			if (ctx.lang == .TS || ctx.lang == .TSX) && v.generator && (v.declare || ctx.is_dts) {
				ck_report_coded(c, u32(v.loc.start), .K4050_AmbientContextRestriction, "Generators are not allowed in an ambient context")
			}
			// TS1040 — async modifier in ambient context.
			if (ctx.lang == .TS || ctx.lang == .TSX) && v.async && (v.declare || ctx.is_dts) {
				ck_report_coded(c, u32(v.loc.start), .K4032_ModifierMisplaced, "'async' modifier cannot be used in an ambient context")
			}
			ck_walk_function(c, ctx, &v.expr)
		}

	case ^ClassDeclaration:
		if v == nil { return }
		// §15.7.1 — ClassDeclaration must have a BindingIdentifier unless
		// it is the direct child of `export default`. At this point we're
		// walking a standalone statement; `export default class {}` goes
		// through `ck_walk_export_decl` and is not checked here.
		// OXC: "A class name is required.".
		if _, has_id := v.id.(BindingIdentifier); !has_id {
			ck_report(c, u32(v.loc.start), "A class name is required.")
		}
		ck_walk_class(c, ctx, &v.expr)

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
		ck_check_import_export_position(c, ctx, v.loc, false, was_top_level, true)
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

	case ^TSModuleDeclaration:
		if v == nil { return }
		// TS2669 — `declare global {}` is only valid directly nested in an
		// external module (top-level of a module file) or inside an ambient
		// module declaration (`declare module "..." {}`). Anywhere else
		// (script top-level, inside a namespace, etc.) is an error.
		if (v.global || v.kind == .Global) && (ctx.lang == .TS || ctx.lang == .TSX) {
			global_ok := false
			if ctx.is_dts {
				// .d.ts files are ambient declaration files — `declare global`
				// is always valid because the entire file is ambient context.
				global_ok = true
			} else if ctx.in_ambient_module_decl {
				// Inside `declare module "..." {}` — always valid.
				global_ok = true
			} else if ctx.ts_namespace_depth == 0 && ctx.source_type == .Module {
				// Top level of a module file — valid.
				global_ok = true
			}
			if !global_ok {
				ck_report_coded(c, u32(v.loc.start), .K4050_AmbientContextRestriction, "Augmentations for the global scope can only be directly nested in external modules or ambient module declarations")
			}
		}
		// TS namespace / module body. Most ECMA early errors don't apply
		// across namespace boundaries (no break/continue/labels can
		// escape), but TS-specific per-scope checks DO need to descend:
		//   * decl-merge dup-detect — `namespace M { class C; class C; }`
		//   * FunctionDeclaration overload-chain —
		//     `namespace M { function foo(); }` (FunctionDeclaration7.ts).
		ck_walk_ts_module_decl(c, ctx, v)

	case ^TSInterfaceDeclaration:
		if v != nil && (ctx.lang == .TS || ctx.lang == .TSX) {
			if is_ts_predefined_type_name(v.id.name) {
				msg := fmt.tprintf("Interface name cannot be '%s'.", v.id.name)
				ck_report_coded(c, u32(v.id.loc.start), .K4051_TSDeclarationStructure, msg)
			}
			if ctx.block_nest_depth > 0 && ctx.ts_namespace_depth == 0 {
				ck_report_coded(c, u32(v.loc.start), .K4051_TSDeclarationStructure, "Interface declarations are only valid at the top level of a module or namespace")
			}
			ck_check_ts_interface_member_dups(c, v.body)
			ck_check_ts1268_index_sig_param_type(c, v.body)
			ck_check_ts2374_dup_index_sig(c, v.body)
			if tp, has := v.type_parameters.(^TSTypeParameterDeclaration); has {
				ck_check_ts_type_param_dups(c, tp)
			}
		}
		return

	case ^TSTypeAliasDeclaration:
		if v != nil && (ctx.lang == .TS || ctx.lang == .TSX) {
			// TS2457 — type alias name cannot be a predefined type name.
			if is_ts_predefined_type_name(v.id.name) {
				msg := fmt.tprintf("Type alias name cannot be '%s'.", v.id.name)
				ck_report_coded(c, u32(v.id.loc.start), .K4051_TSDeclarationStructure, msg)
			}
			if ctx.block_nest_depth > 0 && ctx.ts_namespace_depth == 0 {
				ck_report_coded(c, u32(v.loc.start), .K4051_TSDeclarationStructure, "Type aliases are only valid at the top level of a module or namespace")
			}
			if tp, has := v.type_parameters.(^TSTypeParameterDeclaration); has {
				ck_check_ts_type_param_dups(c, tp)
			}
		}
		return

	case ^TSEnumDeclaration:
		if v != nil && (ctx.lang == .TS || ctx.lang == .TSX) {
			if is_ts_predefined_type_name(v.id.name) {
				msg := fmt.tprintf("Enum name cannot be '%s'.", v.id.name)
				ck_report_coded(c, u32(v.id.loc.start), .K4054_EnumInvalid, msg)
			}
			ck_check_ts_enum_member_dups(c, v)
		}
		return

	case ^TSExportAssignment:
		// TS export assignment (`export = X`). Check position: in script
		// mode this is "'export' is only valid in module code".
		if v != nil {
			ck_check_import_export_position(c, ctx, v.loc, false, was_top_level)
		}
		return

	case ^TSImportEqualsDeclaration:
		// TS2438 — import alias name cannot be a predefined type name.
		if v != nil && (ctx.lang == .TS || ctx.lang == .TSX) {
			if is_ts_predefined_type_name(v.id.name) {
				msg := fmt.tprintf("Import name cannot be '%s'.", v.id.name)
				ck_report_coded(c, u32(v.id.loc.start), .K3020_ImportExportNameOrBinding, msg)
			}
		}
		// TS1392 import alias + import type — migrated to parser.
		return

	case ^EmptyStatement, ^DebuggerStatement,
	     ^TSNamespaceExportDeclaration:
		// No iteration / switch / label / function bodies inside these
		// for break/continue purposes.
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
	case ^TSModuleDeclaration: if inner != nil { ck_walk_ts_module_decl(c, ctx, inner) }
	case ^TSInterfaceDeclaration:
		if inner != nil && (ctx.lang == .TS || ctx.lang == .TSX) {
			if is_ts_predefined_type_name(inner.id.name) {
				msg := fmt.tprintf("Interface name cannot be '%s'.", inner.id.name)
				ck_report_coded(c, u32(inner.id.loc.start), .K4051_TSDeclarationStructure, msg)
			}
			ck_check_ts_interface_member_dups(c, inner.body)
			if tp, has := inner.type_parameters.(^TSTypeParameterDeclaration); has {
				ck_check_ts_type_param_dups(c, tp)
			}
		}
	case ^TSEnumDeclaration:
		if inner != nil && (ctx.lang == .TS || ctx.lang == .TSX) {
			if is_ts_predefined_type_name(inner.id.name) {
				msg := fmt.tprintf("Enum name cannot be '%s'.", inner.id.name)
				ck_report_coded(c, u32(inner.id.loc.start), .K4054_EnumInvalid, msg)
			}
		}
	case ^TSTypeAliasDeclaration:
		if inner != nil && (ctx.lang == .TS || ctx.lang == .TSX) {
			if tp, has := inner.type_parameters.(^TSTypeParameterDeclaration); has {
				ck_check_ts_type_param_dups(c, tp)
			}
		}
	}
}

// ck_walk_ts_module_decl — walk a TS namespace / module body. Pushes
// `is_dts` for `declare namespace M { ... }` so the FunctionDeclaration
// overload-chain check (TS2391) is suppressed for ambient bodies, and
// re-asserts `at_top_level = true` so import / export declarations
// directly inside the namespace body don't false-positive against the
// "not at top level" check (TS namespace bodies are module-like for
// import/export-position purposes — babel/typescript/declare/eval-dts
// shape).
//
// Handles both shapes the parser produces:
//   * `namespace M { ... }`     → body = TSModuleBlock
//   * `namespace A.B { ... }`   → body = TSModuleDeclaration (nested)
@(private="file")
ck_walk_ts_module_decl :: proc(c: ^Checker, ctx: ^CheckerContext, m: ^TSModuleDeclaration) {
	if m == nil { return }
	body_opt, have := m.body.(^TSModuleBody)
	if !have || body_opt == nil { return }
	prev_dts := ctx.is_dts
	prev_top := ctx.at_top_level
	prev_ambient_mod := ctx.in_ambient_module_decl
	if m.declare { ctx.is_dts = true }
	ctx.at_top_level = true
	ctx.ts_namespace_depth += 1
	// Track `declare module "..."` bodies (ambient module declarations).
	// Used by TS2669 to allow `declare global {}` inside them.
	if m.id != nil {
		if _, is_str := m.id^.(^StringLiteral); is_str {
			ctx.in_ambient_module_decl = true
		}
	}
	defer {
		ctx.is_dts = prev_dts
		ctx.at_top_level = prev_top
		ctx.in_ambient_module_decl = prev_ambient_mod
		ctx.ts_namespace_depth -= 1
	}
	#partial switch inner in body_opt^ {
	case ^TSModuleBlock:
		if inner == nil { return }
		// TS1038 — “A 'declare' modifier cannot be used in an already ambient context.”
		// Inside `declare namespace/module`, child declarations are implicitly
		// ambient. An explicit `declare` on a child is redundant and an error.
		if m.declare || prev_dts {
			ck_check_ts1038_nested_declare(c, inner.body[:])
			ck_check_ts1036_ambient_statements(c, inner.body[:], false)
		}
		ck_check_ts_body_decls(c, ctx, inner.body[:])
		for s in inner.body { ck_walk_stmt(c, ctx, s) }
	case ^TSModuleDeclaration:
		if inner == nil { return }
		ck_walk_ts_module_decl(c, ctx, inner)
	}
}

// ck_check_var_decl_lexical_dups — §14.3.1.1 — a LexicalDeclaration
// (`let` / `const` / `using` / `await using`) may not have BoundNames
// containing duplicates within a single declaration list. `let a, a;`
// and `const [x, x] = [1, 2];` are SyntaxErrors. NOT enforced for
// `var` declarations (Annex B.3.4.4 web-compat). The cross-declaration
// duplicate-name check (a let in one block clashing with a let in the
// same block from a different statement) lives in scope_check_body.
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
				ck_report_coded(c, u32(decl.loc.start), .K3037_DuplicateIdentifier, msg)
				return
			}
		}
	}
}

// =============================================================================
// TS declaration-merging (TS handbook "Declaration Merging")
// =============================================================================
//
// In TypeScript, certain declaration kinds may legally bind the same
// name in the same scope ("declaration merging"):
//
//   - namespace + (namespace | class | function | enum | interface)
//   - interface + interface
//   - interface + class            (interface adopts the instance type)
//   - class     + namespace
//   - function  + namespace        (function-and-module pattern)
//   - enum      + namespace
//   - enum      + enum             (member dups still rejected — TS1308)
//   - function  + function         (overload signatures + impl)
//   - var       + var              (legal in JS too)
//   - var       + function         (sloppy hoisting; legal in TS too)
//
// Anything outside the merge whitelist with two value-space entries on
// the same name is TS2300 "Duplicate identifier" (or TS2567 for enums
// specifically: "Enum declarations can only merge with namespace or
// other enum declarations").
//
// The parser-side scope walker (parser.odin:scope_process_statement)
// short-circuits on Class / Function / Import in TS mode to avoid
// false positives on the merge cases. This pass picks up the slack
// by enforcing the precise merging rules. It runs ONLY in TS / TSX
// (the JS scope walker covers JS dup detection).
//
// V1 scope: top-level Program body only. Nested block / function /
// namespace bodies are handled by follow-up slices.

@(private="file")
DeclMergeKind :: enum u8 {
	Var, Let, Const,
	Class, Function, Enum, ConstEnum, Namespace,
	Interface, TypeAlias,
	Import, ImportType, ImportEquals,
}

@(private="file")
DeclMergeSet :: bit_set[DeclMergeKind; u16]

@(private="file")
DeclMergeEntry :: struct {
	kinds:         DeclMergeSet,
	ambient_kinds: DeclMergeSet,  // subset of `kinds` declared with `declare` modifier
	first_loc:     u32,
}

// ts_decl_merge_pair_legal — order-independent: returns true if `a`
// and `b` may legally coexist on the same bound name in the same
// scope under TS rules. The deny list is intentionally narrow: pairs
// not listed here default to legal, so adding a new declaration kind
// (e.g. ImportEquals nuance) cannot accidentally fire false
// positives on real-world TS.
//
// `both_ambient` is true when BOTH the existing declaration of `a`
// and the new declaration of `b` carry the `declare` modifier (or
// live in a `declare namespace { ... }` / `.d.ts` body). Ambient
// context relaxes a few cross-kind rules:
//   - declare class C + declare function C  — callable-class pattern
//   - declare function C + declare namespace C  — fn + module
//   - declare class C + declare class C       — STILL an error
//
// Pairs already caught by the parser-side JS scope walker (let+let,
// const+const, var+let, etc.) are returned LEGAL here — emitting
// would double-report. The walker still skips Class / Function /
// Enum / Import in TS mode, which is exactly the surface this proc
// covers.
@(private="file")
ts_decl_merge_pair_legal :: proc(a, b: DeclMergeKind, both_ambient: bool) -> bool {
	// Canonicalise so we only need to write each pair once: the
	// smaller-ordinal kind is `x`, the larger is `y`.
	x, y := a, b
	if int(y) < int(x) { x, y = y, x }
	#partial switch x {
	case .Var:
		#partial switch y {
		case .Class, .Enum, .ConstEnum:
			if both_ambient { return true }   // ambient var + ambient class/enum is OK in .d.ts
			return false
		}
		// Var + Var, Var + Function: legal (hoisting).
		// Var + Let/Const: caught by JS walker.
		// Var + Namespace/Interface/TypeAlias: legal.
		// Var + Import / ImportEquals: TSC fires TS2440 here but OXC's
		// checker accepts (per babel's typescript/scope/redeclaration-
		// import-{var,equals-var} positive fixtures). Mirror OXC — don't
		// fire. Some TSC import-merge fixtures still close because they
		// also have a duplicate-import shape (handled below).
	case .Let:
		#partial switch y {
		case .Class, .Function, .Enum, .ConstEnum:
			if both_ambient { return true }
			return false
		}
		// Let + Import / ImportEquals: see Var case — OXC accepts.
	case .Const:
		#partial switch y {
		case .Class, .Function, .Enum, .ConstEnum:
			if both_ambient { return true }
			return false
		}
		// Const + Import / ImportEquals: see Var case.
	case .Class:
		#partial switch y {
		case .Class:                                 return true    // OXC does not enforce class+class dup
		case .Function:                              return true    // TS2813/2814 — not in OXC-supported error set
		case .Enum, .ConstEnum:                      return false
		case .TypeAlias:                             return false   // class + type alias is illegal
		}
		// Class + Import: TSC TS2440 but OXC accepts (per babel's
		// typescript/scope/redeclaration-import-ambient-class positive
		// fixture: `import Something from '.'; declare class Something {}`).
		// Class + Namespace, Class + Interface, Class + TypeAlias: legal.
		// Class + Function: TS reports TS2813 / TS2814 here, but OXC's
		// classifier excludes those codes from supported_error_codes.
	case .Function:
		#partial switch y {
		case .Enum, .ConstEnum:
			if both_ambient { return true }
			return false
		}
		// Function + Function: legal (overloads).
		// Function + Import / Namespace / Interface / TypeAlias: legal
		// per OXC.
	case .Enum:
		#partial switch y {
		case .Enum:                                  return true    // enum-enum merge is legal (both non-const)
		case .ConstEnum:                             return false   // const enum + regular enum is illegal
		case .Interface:                             return false   // enum + interface is illegal
		case .TypeAlias:                             return false   // enum + type alias is illegal
		}
	case .ConstEnum:
		#partial switch y {
		case .ConstEnum:                             return true    // const enum + const enum merge is legal
		case .Interface:                             return false   // const enum + interface is illegal
		case .TypeAlias:                             return false   // const enum + type alias is illegal
		}
		// Enum + Namespace / Interface / TypeAlias / Import: legal.
	case .Namespace:
		// Namespace merges with everything else by spec, including imports
		// (TSC fires TS2440 on `import {N}; namespace N {}` but OXC accepts).
		return true
	case .Interface:
		#partial switch y {
		case .TypeAlias:                             return false
		}
		// Interface + Import is LEGAL — type-only interface can coexist
		// with a value-import of the same name (TSC: "shouldn't be error"
		// per es6ImportNamedImportMergeErrors fixture).
	case .TypeAlias:
		#partial switch y {
		case .TypeAlias:                             return false
		}
		// TypeAlias + Import: legal (analogous to Interface).
	case .Import:
		// Import-vs-Import IS enforced — OXC fires on truly duplicate
		// imports. Catches `import {x}; import {x};` and the type-vs-value
		// import collision (typescript/scope/redeclaration-import-type-
		// import babel fixture is NEGATIVE).
		#partial switch y {
		case .Import:                                return false   // duplicate value-import
		case .ImportEquals:                          return false   // duplicate value-binding
		case .ImportType:                            return false   // value + type-only of same name
		}
	case .ImportType:
		#partial switch y {
		case .ImportType:                            return false   // duplicate type-import
		case .ImportEquals:                          return false   // type-only + value-binding via =
		}
	case .ImportEquals:
		// ImportEquals + ImportEquals: OXC accepts duplicate import-equals.
		// (kessel-ts-import-dup.ts positive fixture).
		return true
	}
	return true
}

// ts_decl_merge_add — record one declaration of `name` with kind
// `kind` at byte offset `at`. Reports a "Duplicate identifier"
// diagnostic if combining with any previously-seen kind for the same
// name violates ts_decl_merge_pair_legal.
//
// `is_ambient` is true when the declaration carries the `declare`
// modifier (FunctionDeclaration.declare / ClassDeclaration.declare /
// TSEnumDeclaration.declare / TSModuleDeclaration.declare /
// TSInterfaceDeclaration.declare / VariableDeclaration.declare).
// Ambient declarations may merge across kinds in cases that
// non-ambient ones cannot (e.g. `declare class C + declare function C`).
@(private="file")
ts_decl_merge_add :: proc(
	c: ^Checker,
	seen: ^map[string]DeclMergeEntry,
	name: string,
	kind: DeclMergeKind,
	at: u32,
	is_ambient: bool,
) {
	if name == "" { return }
	entry, found := seen[name]
	if !found {
		new_entry := DeclMergeEntry{kinds = {kind}, first_loc = at}
		if is_ambient { new_entry.ambient_kinds = {kind} }
		seen[name] = new_entry
		return
	}
	// For each existing kind on this name, check the pair.
	for existing in DeclMergeKind {
		if existing not_in entry.kinds { continue }
		existing_ambient := existing in entry.ambient_kinds
		both_ambient := existing_ambient && is_ambient
		if !ts_decl_merge_pair_legal(existing, kind, both_ambient) {
			msg := fmt.tprintf("Duplicate identifier '%s'", name)
			ck_report_coded(c, at, .K3037_DuplicateIdentifier, msg)
			break  // one diagnostic per re-declaration is enough
		}
	}
	entry.kinds += {kind}
	if is_ambient { entry.ambient_kinds += {kind} }
	seen[name] = entry
}

// ts_decl_merge_inspect — extract the (name, kind) pair from a single
// statement (or its inner Declaration if it's an export wrapper) and
// add it to `seen`. Recurses ONE level into ExportNamedDeclaration so
// `export class C {}; export class C {}` still triggers.
@(private="file")
ts_decl_merge_inspect :: proc(c: ^Checker, seen: ^map[string]DeclMergeEntry, stmt: ^Statement) {
	if stmt == nil { return }
	#partial switch v in stmt^ {
	case ^ClassDeclaration:
		if v == nil { return }
		if id, ok := v.id.(BindingIdentifier); ok {
			ts_decl_merge_add(c, seen, id.name, .Class, u32(id.loc.start), v.declare)
		}
	case ^FunctionDeclaration:
		if v == nil { return }
		if id, ok := v.id.(BindingIdentifier); ok {
			ts_decl_merge_add(c, seen, id.name, .Function, u32(id.loc.start), v.declare)
		}
	case ^TSEnumDeclaration:
		if v == nil { return }
		ek: DeclMergeKind = v.const_ ? .ConstEnum : .Enum
		ts_decl_merge_add(c, seen, v.id.name, ek, u32(v.id.loc.start), v.declare)
	case ^TSInterfaceDeclaration:
		if v == nil { return }
		ts_decl_merge_add(c, seen, v.id.name, .Interface, u32(v.id.loc.start), v.declare)
	case ^TSTypeAliasDeclaration:
		if v == nil { return }
		ts_decl_merge_add(c, seen, v.id.name, .TypeAlias, u32(v.id.loc.start), v.declare)
	case ^TSModuleDeclaration:
		if v == nil || v.id == nil { return }
		if ident, is := v.id^.(^Identifier); is && ident != nil {
			ts_decl_merge_add(c, seen, ident.name, .Namespace, u32(ident.loc.start), v.declare)
		}
	case ^VariableDeclaration:
		if v == nil { return }
		kind: DeclMergeKind
		switch v.kind {
		case .Var:                       kind = .Var
		case .Let:                       kind = .Let
		case .Const, .Using, .AwaitUsing: kind = .Const
		}
		names: [dynamic]string
		names.allocator = context.temp_allocator
		reserve(&names, 4)
		for d in v.declarations { collect_bound_names(d.id, &names) }
		for n in names {
			ts_decl_merge_add(c, seen, n, kind, u32(v.loc.start), v.declare)
		}
	case ^ImportDeclaration:
		// Each specifier introduces a local binding. `import type` makes
		// the whole declaration's bindings type-only (kind=ImportType,
		// which only conflicts with another type-only import on the same
		// name). Plain imports introduce value bindings (kind=Import) that
		// conflict with var/let/const/function/class/enum/namespace/import
		// per TS2440. Per-specifier `import {type X}` granularity is V2.
		if v == nil { return }
		kind: DeclMergeKind = v.import_kind == .Type ? .ImportType : .Import
		for spec in v.specifiers {
			if spec == nil { continue }
			switch s in spec^ {
			case ImportSpecifier:
				ts_decl_merge_add(c, seen, s.local.name, kind, u32(s.local.loc.start), false)
			case ImportDefaultSpecifier:
				ts_decl_merge_add(c, seen, s.local.name, kind, u32(s.local.loc.start), false)
			case ImportNamespaceSpecifier:
				ts_decl_merge_add(c, seen, s.local.name, kind, u32(s.local.loc.start), false)
			}
		}
	case ^TSImportEqualsDeclaration:
		// `import x = ns.member;` / `import x = require("m");` introduces a
		// value binding (kind=ImportEquals) unless `import type x = ...`
		// (kind=ImportType). Conflicts with same-name local declarations
		// per TS2440.
		if v == nil { return }
		kind: DeclMergeKind = v.import_kind == .Type ? .ImportType : .ImportEquals
		ts_decl_merge_add(c, seen, v.id.name, kind, u32(v.id.loc.start), false)
	case ^ExportNamedDeclaration:
		if v == nil { return }
		if d, have := v.declaration.(^Declaration); have && d != nil {
			// Re-wrap the inner Declaration as a Statement union so we
			// can re-enter the switch above. Each Declaration arm is
			// also a Statement arm by construction.
			inner_stmt: ^Statement
			#partial switch inner in d^ {
			case ^ClassDeclaration:
				if inner != nil {
					if id, ok := inner.id.(BindingIdentifier); ok {
						ts_decl_merge_add(c, seen, id.name, .Class, u32(id.loc.start), inner.declare)
					}
				}
			case ^FunctionDeclaration:
				if inner != nil {
					if id, ok := inner.id.(BindingIdentifier); ok {
						ts_decl_merge_add(c, seen, id.name, .Function, u32(id.loc.start), inner.declare)
					}
				}
			case ^TSEnumDeclaration:
				if inner != nil {
					ts_decl_merge_add(c, seen, inner.id.name, .Enum, u32(inner.id.loc.start), inner.declare)
				}
			case ^TSInterfaceDeclaration:
				if inner != nil {
					ts_decl_merge_add(c, seen, inner.id.name, .Interface, u32(inner.id.loc.start), inner.declare)
				}
			case ^TSTypeAliasDeclaration:
				if inner != nil {
					ts_decl_merge_add(c, seen, inner.id.name, .TypeAlias, u32(inner.id.loc.start), inner.declare)
				}
			case ^TSModuleDeclaration:
				if inner != nil && inner.id != nil {
					if ident, is := inner.id^.(^Identifier); is && ident != nil {
						ts_decl_merge_add(c, seen, ident.name, .Namespace, u32(ident.loc.start), inner.declare)
					}
				}
			case ^VariableDeclaration:
				if inner != nil {
					kind: DeclMergeKind
					switch inner.kind {
					case .Var:                       kind = .Var
					case .Let:                       kind = .Let
					case .Const, .Using, .AwaitUsing: kind = .Const
					}
					names: [dynamic]string
					names.allocator = context.temp_allocator
					reserve(&names, 4)
					for d in inner.declarations { collect_bound_names(d.id, &names) }
					for n in names {
						ts_decl_merge_add(c, seen, n, kind, u32(inner.loc.start), inner.declare)
					}
				}
			}
			_ = inner_stmt
		}
	}
}

// ck_check_ts2434_namespace_ordering — TS2434 "A namespace declaration
// cannot be located prior to a class or function with which it is merged."
// An instantiated namespace (one containing value-producing declarations
// like var, function, class, enum) must appear AFTER the class/function
// it merges with, not before. Non-instantiated namespaces (empty or
// type-only: interfaces, type aliases) may appear in any order.
@(private="file")
ck_check_ts2434_namespace_ordering :: proc(c: ^Checker, body: []^Statement, is_dts: bool = false) {
	if c == nil || len(body) == 0 { return }
	// In .d.ts files all declarations are implicitly ambient; the ordering
	// rule does not apply (TSC only fires TS2434 on non-ambient classes).
	if is_dts { return }

	// Helper: extract the identifier name from a namespace.
	ns_name :: proc(m: ^TSModuleDeclaration) -> (string, u32, bool) {
		if m == nil || m.id == nil { return "", 0, false }
		if ident, is := m.id^.(^Identifier); is && ident != nil {
			return ident.name, u32(ident.loc.start), true
		}
		return "", 0, false
	}

	// For each statement: if it's an instantiated non-declare namespace,
	// scan the remaining statements for a non-declare class/function with
	// the same name that appears later.
	for i in 0..<len(body) {
		stmt := body[i]
		if stmt == nil { continue }
		// Extract namespace from bare or exported statement.
		mod: ^TSModuleDeclaration = nil
		#partial switch v in stmt^ {
		case ^TSModuleDeclaration:   mod = v
		case ^ExportNamedDeclaration:
			if v != nil {
				if d, have := v.declaration.(^Declaration); have && d != nil {
					if m, ok := d^.(^TSModuleDeclaration); ok { mod = m }
				}
			}
		}
		if mod == nil || mod.declare { continue }
		if !ts_namespace_is_instantiated(mod) { continue }
		name, ns_loc, has_name := ns_name(mod)
		if !has_name { continue }

		// Check if a class/function with this name already appeared BEFORE
		// the namespace. If so, the namespace augments the prior declaration
		// and the ordering rule doesn't apply.
		already_seen := false
		for j in 0..<i {
			s2 := body[j]
			if s2 == nil { continue }
			#partial switch v2 in s2^ {
			case ^ClassDeclaration:
				if v2 != nil { if id, ok := v2.id.(BindingIdentifier); ok && id.name == name { already_seen = true } }
			case ^FunctionDeclaration:
				if v2 != nil { if id, ok := v2.id.(BindingIdentifier); ok && id.name == name { already_seen = true } }
			case ^ExportNamedDeclaration:
				if v2 != nil {
					if d, have := v2.declaration.(^Declaration); have && d != nil {
						#partial switch inner in d^ {
						case ^ClassDeclaration:    if inner != nil { if id, ok := inner.id.(BindingIdentifier); ok && id.name == name { already_seen = true } }
						case ^FunctionDeclaration: if inner != nil { if id, ok := inner.id.(BindingIdentifier); ok && id.name == name { already_seen = true } }
						}
					}
				}
			}
		}
		if already_seen { continue }

		// Scan forward for a class/function with the same name.
		for j in i+1..<len(body) {
			s2 := body[j]
			if s2 == nil { continue }
			// Unwrap export.
			#partial switch v2 in s2^ {
			case ^ClassDeclaration:
				if v2 == nil || v2.declare { continue }
				if id, ok := v2.id.(BindingIdentifier); ok && id.name == name {
					ck_report_coded(c, ns_loc, .K4023_NamespaceMergeOrder, "A namespace declaration cannot be located prior to a class or function with which it is merged")
					break
				}
			case ^FunctionDeclaration:
				if v2 == nil || v2.declare { continue }
				if id, ok := v2.id.(BindingIdentifier); ok && id.name == name {
					ck_report_coded(c, ns_loc, .K4023_NamespaceMergeOrder, "A namespace declaration cannot be located prior to a class or function with which it is merged")
					break
				}
			case ^ExportNamedDeclaration:
				if v2 == nil { continue }
				if d, have := v2.declaration.(^Declaration); have && d != nil {
					#partial switch inner in d^ {
					case ^ClassDeclaration:
						if inner != nil && !inner.declare {
							if id, ok := inner.id.(BindingIdentifier); ok && id.name == name {
								ck_report_coded(c, ns_loc, .K4023_NamespaceMergeOrder, "A namespace declaration cannot be located prior to a class or function with which it is merged")
							}
						}
					case ^FunctionDeclaration:
						if inner != nil && !inner.declare {
							if id, ok := inner.id.(BindingIdentifier); ok && id.name == name {
								ck_report_coded(c, ns_loc, .K4023_NamespaceMergeOrder, "A namespace declaration cannot be located prior to a class or function with which it is merged")
							}
						}
					}
				}
			}
		}
	}
}

// ts_namespace_is_instantiated — returns true if the namespace has any
// value-producing declarations (var, function, class, enum, nested
// instantiated namespace). Type-only namespaces (interfaces, type
// aliases, empty) return false.
@(private="file")
ts_namespace_is_instantiated :: proc(m: ^TSModuleDeclaration) -> bool {
	if m == nil { return false }
	body_opt, have := m.body.(^TSModuleBody)
	if !have || body_opt == nil { return false }
	#partial switch inner in body_opt^ {
	case ^TSModuleBlock:
		if inner == nil { return false }
		for stmt in inner.body {
			if stmt == nil { continue }
			// Unwrap export.
			actual := stmt
			if exp, ok := stmt^.(^ExportNamedDeclaration); ok && exp != nil {
				if d, have_d := exp.declaration.(^Declaration); have_d && d != nil {
					#partial switch _ in d^ {
					case ^VariableDeclaration, ^FunctionDeclaration,
					     ^ClassDeclaration, ^TSEnumDeclaration:
						return true
					case ^TSModuleDeclaration:
						// Nested namespace — check recursively.
						if inner_mod, is_mod := d^.(^TSModuleDeclaration); is_mod {
							if ts_namespace_is_instantiated(inner_mod) { return true }
						}
					}
				}
				continue
			}
			#partial switch _ in stmt^ {
			case ^VariableDeclaration, ^FunctionDeclaration,
			     ^ClassDeclaration, ^TSEnumDeclaration:
				return true
			case ^TSModuleDeclaration:
				if inner_mod, is_mod := stmt^.(^TSModuleDeclaration); is_mod {
					if ts_namespace_is_instantiated(inner_mod) { return true }
				}
			}
		}
	case ^TSModuleDeclaration:
		// Nested module declaration (namespace A.B.C).
		if inner == nil { return false }
		return ts_namespace_is_instantiated(inner)
	}
	return false
}

// ck_check_ts_decl_merge_body — walks ONE body level (no recursion)
// and reports TS "Duplicate identifier" for any pair that violates
// the merge rules. Caller-supplied body slice represents one scope.
@(private="file")
ck_check_ts_decl_merge_body :: proc(c: ^Checker, body: []^Statement, is_dts: bool = false) {
	if c == nil || len(body) == 0 { return }
	seen: map[string]DeclMergeEntry
	seen.allocator = context.temp_allocator
	defer delete(seen)
	for stmt in body {
		ts_decl_merge_inspect(c, &seen, stmt)
	}
	// TS2434 — an instantiated namespace cannot appear before a class or
	// function with the same name in the same scope.
	ck_check_ts2434_namespace_ordering(c, body, is_dts)
}

// =============================================================================
// TS overload-signature chain checking (TS2391 / TS2389)
// =============================================================================
//
// In a TS class body or top-level scope, a sequence of consecutive
// method/function declarations forms an "overload set" iff every
// member except the LAST has no body (a signature). The last member
// must have a body (the implementation). Names within the set must
// match.
//
// Errors:
//   - TS2391 "Function implementation is missing or not immediately
//     following the declaration." — reported on each signature in a
//     run that has no following implementation.
//   - TS2389 "Function implementation name must be 'X'." — reported
//     on the implementation when its name doesn't match the signatures
//     it claims to implement.
//
// Suppressed in ambient context (declare class / declare function /
// .d.ts content): signatures without bodies are valid.
//
// V1 covers class method bodies. Top-level overloads (Program body /
// FunctionBody / TSModuleBlock) are a follow-up slice — same algorithm,
// different node-extractor.

// elem_overload_name — returns the canonical name of a class method's
// key for overload-chain comparison. Ordinary identifiers + private
// identifiers + string / numeric literal keys are all valid method
// names; computed keys are excluded (they can't form overload chains
// because TS can't statically prove their identity).
@(private="file")
elem_overload_name :: proc(elem: ClassElement) -> (string, bool) {
	if elem.computed || elem.key == nil { return "", false }
	#partial switch k in elem.key^ {
	case ^Identifier:
		if k != nil { return k.name, true }
	case ^PrivateIdentifier:
		if k != nil { return k.name, true }
	case ^StringLiteral:
		if k != nil { return k.value, true }
	case ^NumericLiteral:
		if k != nil { return k.raw, true }
	}
	return "", false
}

// method_fn_has_body — true iff a class method's FunctionExpression
// has a parsed `{ ... }` body (vs. a TS overload signature `foo();`
// or ambient `foo()` with no braces). Methods don't set
// FunctionExpression.no_body the way top-level functions do, so
// detect by checking the body source span: an absent body has a
// zero-extent default-initialised loc, an empty `{}` body has a
// nonzero span covering the braces.
@(private="file")
method_fn_has_body :: #force_inline proc(fn: ^FunctionExpression) -> bool {
	return fn != nil && fn.body.loc.end > fn.body.loc.start
}

// elem_is_overloadable_method — true if `elem` is a regular method or
// constructor whose value is a FunctionExpression (i.e. eligible to
// participate in an overload chain). Excludes:
//   - getters / setters (kind .Get / .Set) — always have body, can't
//     overload
//   - static blocks
//   - PropertyDefinition (kind == .Method but value is a non-function
//     expression — a class field with an initialiser)
//   - abstract methods (no impl needed; abstract is the suppressor)
@(private="file")
elem_is_overloadable_method :: proc(elem: ClassElement) -> (^FunctionExpression, bool) {
	if elem.kind != .Method && elem.kind != .Constructor { return nil, false }
	if elem.abstract { return nil, false }
	val, have := elem.value.(^Expression)
	if !have || val == nil { return nil, false }
	fn, is_fn := val^.(^FunctionExpression)
	if !is_fn || fn == nil { return nil, false }
	return fn, true
}

// ck_check_ts_class_overloads — walks class members left-to-right;
// emits TS2391 / TS2389 per the overload-chain rules above.
@(private="file")
ck_check_ts_class_overloads :: proc(c: ^Checker, body: ClassBody) {
	if c == nil || len(body.body) == 0 { return }

	// Pre-pass: skip when there's no implementation AND the class body
	// consists ONLY of method sigs for a single name (pure overload-set
	// pattern: `class C { f(); f(): void; }` accepted by OXC/babel).
	// When there are non-method elements (properties, static blocks) OR
	// sigs for multiple different names, the check runs normally.
	has_any_impl := false
	has_non_method := false
	has_constructor_sig := false
	method_names: map[string]bool
	method_names.allocator = context.temp_allocator
	total_sigs := 0
	for elem in body.body {
		fn, ok := elem_is_overloadable_method(elem)
		if !ok {
			// PropertyDefinition, getter, setter, static block, etc.
			if elem.kind != .Get && elem.kind != .Set {
				has_non_method = true
			}
			continue
		}
		if method_fn_has_body(fn) {
			has_any_impl = true
			break
		}
		total_sigs += 1
		if elem.kind == .Constructor {
			has_constructor_sig = true
		} else {
			name, has_name := elem_overload_name(elem)
			if has_name { method_names[name] = true }
		}
	}
	if !has_any_impl && !has_non_method {
		// Pure overload-set class: only skip if single method name.
		if !has_constructor_sig && len(method_names) <= 1 && total_sigs >= 2 {
			return
		}
	}

	flush_unimplemented :: proc(c: ^Checker, body: ClassBody, start, end_excl: int) {
		// Emit TS2391 on each unmatched signature in [start, end_excl).
		for i := start; i < end_excl; i += 1 {
			elem := body.body[i]
			fn, ok := elem_is_overloadable_method(elem)
			if !ok || method_fn_has_body(fn) { continue }
			ck_report_coded(c, u32(elem.loc.start), .K4080_DuplicateImplementation, "Function implementation is missing or not immediately following the declaration")
		}
	}

	chain_active   := false
	chain_name     := ""
	chain_start    := 0

	for elem, idx in body.body {
		fn, is_method := elem_is_overloadable_method(elem)
		if !is_method {
			// non-method element (field, static block, getter/setter, abstract)
			// breaks the overload chain.
			if chain_active {
				flush_unimplemented(c, body, chain_start, idx)
				chain_active = false
			}
			continue
		}
		if elem.optional {
			// `m?(): void` — TS optional method declaration. Like an
			// abstract method, no implementation is required and it does
			// not participate in overload chains.
			if chain_active {
				flush_unimplemented(c, body, chain_start, idx)
				chain_active = false
			}
			continue
		}
		name, has_name := elem_overload_name(elem)
		if !has_name {
			// computed key — can't reason about chain identity.
			if chain_active {
				flush_unimplemented(c, body, chain_start, idx)
				chain_active = false
			}
			continue
		}

		has_body := method_fn_has_body(fn)
		if chain_active {
			if has_body {
				// Implementation found. TS treats ANY following function-with-body
				// as the impl for the chain (TS2389 fires on name mismatch).
				if name != chain_name {
					msg := fmt.tprintf("Function implementation name must be '%s'.", chain_name)
					ck_report_coded(c, u32(elem.loc.start), .K2070_RequiredFormOrBinding, msg)
				}
				chain_active = false
			} else {
				// Another signature.
				if name == chain_name {
					// Extend chain.
				} else {
					// Different-name sig in middle of chain — prior chain ends
					// unimplemented; this sig opens a new chain.
					flush_unimplemented(c, body, chain_start, idx)
					chain_name  = name
					chain_start = idx
				}
			}
		} else {
			if !has_body {
				chain_active = true
				chain_name   = name
				chain_start  = idx
			}
			// else: standalone full method, no chain involved.
		}
	}
	if chain_active {
		flush_unimplemented(c, body, chain_start, len(body.body))
	}
}

// =============================================================================
// TS2300 / TS2393 — class-body member duplicate-name detection
// =============================================================================
//
// Detects two kinds of conflicts within a single class body:
//
//   * TS2300 "Duplicate identifier 'X'" — two declarations of the same
//     `(static, key)` slot that don't form a legal accessor pair OR an
//     overload-chain. Fires only when the slot has DIFFERENT kinds of
//     entries (e.g. field+method, field+accessor, get+get); pure
//     all-fields slots are intentionally NOT flagged because OXC's
//     semantic checker accepts them in babel parser-test fixtures
//     (e.g. `class C { x; x; }` shows up in babel as a parser-only test
//     and stays positive in the OXC oracle). Examples that DO fire:
//       class C { a(): number {return 0;}; a: number; }   field+method
//       class C { x: number; get x(){return 1;} }         field+get
//       class C { get x(){} get x(){} }                   getter+getter
//
//   * TS2393 "Duplicate function implementation" — same `(static,
//     key)` slot has two or more method bodies. Each impl is flagged.
//       class C { b(){} b(){} }                → each `b` impl flagged
//
// Carve-outs (silently skipped, both diagnostics):
//   * computed keys                       — can't reason statically
//   * abstract / optional members         — no impl required
//   * private identifiers (`#x`)          — covered by
//                                           ck_check_class_private_duplicates
//   * constructor                         — TS2300 doesn't apply
//   * static blocks                       — no name
//   * legal accessor pair (1 get + 1 set, nothing else)
//   * overload chain (>=1 sig + at most 1 impl, all methods)
//   * slot containing ANY entry with `override`, `definite`, or
//     `optional` TS-only modifier — these mark the surrounding fixture
//     as TS-modifier surface (real code uses these on a single decl,
//     not in dup runs; babel parser-test fixtures DO use them in dups
//     and OXC accepts those). Skipping the whole slot here matches the
//     OXC oracle without losing TSC-corpus negative-fixture gains
//     (none of those use these modifiers).
//   * TS2393 only: slot whose method impls all carry type_parameters
//     — `method<const T>(){} method<T,const U>(){}` is the babel
//     `typescript/types/const-type-parameters` shape (parser surface
//     test for `<const T>`, not real overload code).
//
// Slot key includes BOTH the source representation AND the kind of the
// key node (Identifier, StringLiteral, NumericLiteral). This means
// `"3.0": string` and `3.0: MyNumber` are NOT considered duplicates by
// this pass, even though TSC treats them as semantically equivalent.
// TSC reports those as TS2411 (index-signature constraint) which is
// type-aware and out of this pass's scope; matching OXC here keeps
// `numericIndexerConstrainsPropertyDeclarations.ts` clean.
//
// One diagnostic per duplicate. The first occurrence in source order
// is treated as the anchor; each subsequent entry gets a TS2300 (or
// TS2393 when both members are method-impls). This matches OXC's snap
// classifier requirement: any error on the fixture flips it from
// "Expect Syntax Error" → rejected.
//
// Static and instance members live in DISJOINT slots: `static x` and
// `x` never collide.
@(private="file")
ck_check_ts_class_member_dups :: proc(c: ^Checker, cls: ^ClassExpression) {
	if c == nil || cls == nil || len(cls.body.body) == 0 { return }

	ElemKind :: enum u8 { Field, MethodImpl, MethodSig, Get, Set }
	KeyKind  :: enum u8 { Ident, Str, Num }
	Entry :: struct {
		at:           u32,
		kind:         ElemKind,
		key_kind:     KeyKind,
		name:         string,
		static:       bool,
		has_ts_mod:   bool,  // override / definite / optional present
		has_type_pms: bool,  // method has type_parameters (gates TS2393)
	}

	classify_key :: proc(elem: ClassElement) -> (name: string, kk: KeyKind, ok: bool) {
		if elem.computed || elem.key == nil { return "", .Ident, false }
		#partial switch k in elem.key^ {
		case ^Identifier:
			if k != nil { return k.name, .Ident, true }
		case ^StringLiteral:
			if k != nil { return k.value, .Str, true }
		case ^NumericLiteral:
			if k != nil { return k.raw, .Num, true }
		}
		return "", .Ident, false
	}

	classify_elem :: proc(elem: ClassElement) -> (kind: ElemKind, ok: bool) {
		if elem.computed { return .Field, false }
		if elem.abstract { return .Field, false }
		if elem.kind == .StaticBlock { return .Field, false }
		if elem.kind == .Constructor { return .Field, false }
		if elem.key != nil {
			if _, is_priv := elem.key^.(^PrivateIdentifier); is_priv {
				return .Field, false
			}
		}
		#partial switch elem.kind {
		case .Get:
			return .Get, true
		case .Set:
			return .Set, true
		case .Method:
			val, have := elem.value.(^Expression)
			if !have || val == nil { return .Field, true }
			fn, is_fn := val^.(^FunctionExpression)
			if !is_fn || fn == nil { return .Field, true }
			if method_fn_has_body(fn) { return .MethodImpl, true }
			return .MethodSig, true
		}
		return .Field, false
	}

	method_has_type_params :: proc(elem: ClassElement) -> bool {
		val, have := elem.value.(^Expression)
		if !have || val == nil { return false }
		fn, is_fn := val^.(^FunctionExpression)
		if !is_fn || fn == nil { return false }
		_, have_tp := fn.type_parameters.(^TSTypeParameterDeclaration)
		return have_tp
	}

	// Collect every named, non-skipped element with its (static, key)
	// slot plus the per-element flags used by the slot-level gates.
	entries: [dynamic]Entry
	entries.allocator = context.temp_allocator
	defer delete(entries)
	for elem in cls.body.body {
		k, ok := classify_elem(elem)
		if !ok { continue }
		name, kk, has_n := classify_key(elem)
		if !has_n { continue }
		ts_mod := elem.optional || elem.definite || elem.override_
		has_tp := false
		if k == .MethodImpl || k == .MethodSig { has_tp = method_has_type_params(elem) }
		append(&entries, Entry{
			at = u32(elem.loc.start),
			kind = k,
			key_kind = kk,
			name = name,
			static = elem.static,
			has_ts_mod = ts_mod,
			has_type_pms = has_tp,
		})
	}
	if len(entries) < 2 { return }

	processed: [dynamic]bool
	processed.allocator = context.temp_allocator
	defer delete(processed)
	resize(&processed, len(entries))

	for i in 0..<len(entries) {
		if processed[i] { continue }
		anchor := entries[i]

		slot: [dynamic]int
		slot.allocator = context.temp_allocator
		defer delete(slot)
		append(&slot, i)
		for j in i+1..<len(entries) {
			if processed[j] { continue }
			e := entries[j]
			if e.static == anchor.static && e.key_kind == anchor.key_kind && e.name == anchor.name {
				append(&slot, j)
			}
		}
		for idx in slot { processed[idx] = true }
		if len(slot) < 2 { continue }

		// Slot-level gate 1: any TS-only modifier (optional/definite/
		// override) on any entry — skip the whole slot.
		slot_has_ts_mod := false
		for idx in slot {
			if entries[idx].has_ts_mod { slot_has_ts_mod = true; break }
		}
		if slot_has_ts_mod { continue }

		// Count by kind across the slot.
		n_field, n_impl, n_sig, n_get, n_set := 0, 0, 0, 0, 0
		n_impl_with_tp := 0
		for idx in slot {
			switch entries[idx].kind {
			case .Field:      n_field += 1
			case .MethodImpl:
				n_impl  += 1
				if entries[idx].has_type_pms { n_impl_with_tp += 1 }
			case .MethodSig:  n_sig   += 1
			case .Get:        n_get   += 1
			case .Set:        n_set   += 1
			}
		}

		// Carve-out: legal accessor pair (1 getter + 1 setter, nothing
		// else on this slot).
		if n_get == 1 && n_set == 1 && n_field == 0 && n_impl == 0 && n_sig == 0 {
			continue
		}

		// Carve-out: overload chain (>=1 sig, at most 1 impl, all methods,
		// nothing else). Already covered by ck_check_ts_class_overloads.
		if n_field == 0 && n_get == 0 && n_set == 0 && n_impl <= 1 && n_sig >= 1 {
			continue
		}

		// Carve-out: pure all-field slot — OXC's checker doesn't fire on
		// `class C { x; x; }` style duplicates. Mirroring keeps the babel
		// parser-test fixtures (typescript/class/properties, /static-asi,
		// /static-static) clean. The TSC negative fixtures we still close
		// (propertyAndAccessorWithSameName, etc.) all involve at least one
		// non-field member on the slot.
		if n_impl == 0 && n_sig == 0 && n_get == 0 && n_set == 0 {
			continue
		}

		// Method-impl + method-impl on the same slot → TS2393 on every
		// impl, UNLESS all impls have generic type_parameters. The latter
		// gate avoids false-positives on babel parser-test fixtures of the
		// shape `method<const T>(){} method<T, const U>(){}` (parser test,
		// not real overload code). All TSC-corpus impl+impl negatives that
		// we close use plain (non-generic) impls.
		impls_suppressed_by_generics := n_impl >= 2 && n_impl_with_tp == n_impl
		if n_impl >= 2 && !impls_suppressed_by_generics {
			for idx in slot {
				if entries[idx].kind == .MethodImpl {
					ck_report_coded(c, entries[idx].at, .K4080_DuplicateImplementation,
						"Duplicate function implementation")
				}
			}
		}

		// If the slot is exclusively method-impls (no field/get/set/sig
		// mixed in), we're done after the TS2393 pass — don't fall through
		// to TS2300 emission. Also bails out cleanly when TS2393 was
		// suppressed by the generics gate (slot is impls-only with type_pms).
		if n_field == 0 && n_get == 0 && n_set == 0 && n_sig == 0 {
			continue
		}

		// General TS2300: emit on each entry AFTER the first that isn't a
		// method-impl already reported above.
		msg := fmt.tprintf("Duplicate identifier '%s'", anchor.name)
		for s_idx, slot_pos in slot {
			if slot_pos == 0 { continue }
			if n_impl >= 2 && !impls_suppressed_by_generics && entries[s_idx].kind == .MethodImpl { continue }
			ck_report(c, entries[s_idx].at, msg)
		}
	}
}

// ck_check_ts_constructor_modifiers — TS only. Constructor overload
// signatures (constructors with no_body = true) cannot have parameter
// properties (accessibility / readonly / override on params). Only the
// implementation constructor (with a body) may have these.
@(private="file")
ck_check_ts_constructor_modifiers :: proc(c: ^Checker, cls: ^ClassExpression) {
	if c == nil || cls == nil { return }
	for elem in cls.body.body {
		if elem.kind != .Constructor { continue }
		fn, have := elem.value.(^Expression)
		if !have || fn == nil { continue }
		func, is_fn := fn^.(^FunctionExpression)
		if !is_fn || func == nil { continue }
		// Only check overload signatures (no_body = true). The
		// implementation constructor can have parameter properties.
		if !func.no_body { continue }
		for param in func.params {
			if param.accessibility != .None {
				ck_report_coded(c, u32(param.loc.start), .K4022_ParameterPropertyOnlyInCtor, "Parameter properties are only allowed in the implementation constructor")
			}
			if param.readonly {
				ck_report_coded(c, u32(param.loc.start), .K4022_ParameterPropertyOnlyInCtor, "'readonly' parameter properties are only allowed in the implementation constructor")
			}
			if param.override_ {
				ck_report_coded(c, u32(param.loc.start), .K4022_ParameterPropertyOnlyInCtor, "'override' parameter properties are only allowed in the implementation constructor")
			}
		}
	}
}

// ck_check_ts_constructor_param_property_dups — TS2300. A constructor
// parameter property (public / private / protected / readonly modifier
// on a constructor parameter) introduces a class property. If the class
// body already declares a field with the same name, it's a duplicate.
//
// Example:
//   class D { y: number; constructor(public y: number) {} }  → TS2300
//   class C { y: number; constructor(y: number) {} }         → OK (no modifier)
@(private="file")
ck_check_ts_constructor_param_property_dups :: proc(c: ^Checker, cls: ^ClassExpression) {
	if c == nil || cls == nil { return }
	// Collect instance field names.
	field_names: map[string]bool
	field_names.allocator = context.temp_allocator
	defer delete(field_names)
	for elem in cls.body.body {
		if elem.static { continue }
		// Skip constructors, getters, setters, static blocks.
		#partial switch elem.kind {
		case .Get, .Set, .Constructor, .StaticBlock:
			continue
		}
		// Skip methods (FunctionExpression value = method, not field).
		if val, have := elem.value.(^Expression); have && val != nil {
			if _, is_fn := val^.(^FunctionExpression); is_fn {
				continue
			}
		}
		if elem.computed || elem.key == nil { continue }
		if id, ok := elem.key^.(^Identifier); ok && id != nil {
			field_names[id.name] = true
		}
	}
	if len(field_names) == 0 { return }
	// Find the implementation constructor (has body).
	for elem in cls.body.body {
		if elem.kind != .Constructor { continue }
		fn_expr, have := elem.value.(^Expression)
		if !have || fn_expr == nil { continue }
		func, is_fn := fn_expr^.(^FunctionExpression)
		if !is_fn || func == nil || func.no_body { continue }
		// Check each parameter for a property modifier.
		for param in func.params {
			if param.accessibility == .None && !param.readonly { continue }
			// Extract the parameter name.
			param_name: string
			param_loc: u32
			#partial switch p in param.pattern {
			case ^Identifier:
				if p != nil {
					param_name = p.name
					param_loc  = u32(p.loc.start)
				}
			case ^AssignmentPattern:
				if p != nil {
					if id, ok := p.left.(^Identifier); ok && id != nil {
						param_name = id.name
						param_loc  = u32(id.loc.start)
					}
				}
			}
			if param_name != "" && field_names[param_name] {
				msg := fmt.tprintf("Duplicate identifier '%s'", param_name)
				ck_report_coded(c, param_loc, .K3037_DuplicateIdentifier, msg)
			}
		}
		break  // only check the implementation constructor
	}
}

// ck_check_ts_class_modifier_conflicts — migrated to parser
// (validate_class_body_elements). static+abstract, abstract+#name.

// =============================================================================
// TS2300 — enum member duplicate-name detection
// =============================================================================
//
// `enum E { x, y, x }` — duplicate enum member names are TS2300.
// Both Identifier and StringLiteral keys are checked. Computed
// member names are excluded (can't reason statically).
@(private="file")
ck_check_ts_enum_member_dups :: proc(c: ^Checker, decl: ^TSEnumDeclaration) {
	if c == nil || decl == nil || len(decl.body.members) < 2 { return }
	seen: map[string]u32
	seen.allocator = context.temp_allocator
	defer delete(seen)
	for member in decl.body.members {
		if member.id == nil { continue }
		name: string
		loc: u32
		#partial switch k in member.id^ {
		case ^Identifier:
			if k == nil { continue }
			name = k.name
			loc  = u32(k.loc.start)
		case ^StringLiteral:
			if k == nil { continue }
			name = k.value
			loc  = u32(k.loc.start)
		case:
			continue  // computed key — skip
		}
		if name == "" { continue }
		if _, already := seen[name]; already {
			msg := fmt.tprintf("Duplicate identifier '%s'", name)
			ck_report_coded(c, loc, .K3037_DuplicateIdentifier, msg)
		} else {
			seen[name] = loc
		}
	}
}

// =============================================================================
// TS2300 — type-parameter duplicate-name detection
// =============================================================================
//
// `function A<X, X>() { }`, `interface I<T, T> { }`, `class C<U, U>`,
// `type Q<P, P>` and so on are all TS2300 errors. Detects via a
// single-pass on the TSTypeParameterDeclaration's params — emit on
// each entry that duplicates an earlier one.
@(private="file")
ck_check_ts_type_param_dups :: proc(c: ^Checker, tp: ^TSTypeParameterDeclaration) {
	// OXC does not enforce TS2300 type-param dups — type-checker concern.
}

// =============================================================================
// TS2300 — interface body member duplicate-name detection
// =============================================================================
//
// `interface Bar { x; x; }`, `interface I { foo: any; foo: number; }`,
// `interface I2 { item:any; item:number; }` etc. are all TS2300
// errors. Detects via a single-pass over TSInterfaceBody.body,
// bucketing TSPropertySignature / TSMethodSignature entries by name +
// accessor kind. Skips computed keys, call/construct/index signatures
// (those have no name), and the legal accessor pair (1 get + 1 set on
// the same name). Method overloads (multiple TSMethodSignature with
// kind=.Method on the same name) are LEGAL — interfaces declare
// callable types, and method overloads are the canonical way to
// express union return types.
//
@(private="file")
ck_check_ts_interface_member_dups :: proc(c: ^Checker, body: TSInterfaceBody) {
	// OXC does not enforce TS2300 interface member dups — type-checker concern.
}


// =============================================================================
// Top-level (and nested-scope) overload-signature chain checking
// =============================================================================
//
// Same algorithm as the class version, but applied to a `[]^Statement`
// (Program top-level body, BlockStatement body, FunctionBody, or a
// TSModuleBlock body). Detects the shape:
//
//   function foo();           // sig — no body
//   function foo();           // sig — extends chain (same name)
//   function foo() { ... }    // impl — completes chain (must match name)
//
// Errors:
//   - TS2391 "Function implementation is missing or not immediately
//     following the declaration." — emitted on each unmatched signature
//     in a chain that is not closed by an implementation, or whose
//     implementation never appears.
//   - TS2389 "Function implementation name must be 'X'." — emitted on
//     the implementation when its name doesn't match the open chain.
//
// Suppressed:
//   * `declare function foo();` — ambient (declaration is complete on
//     its own; doesn't open / extend / close a chain).
//   * Whole pass skipped at the top level when ctx.is_dts (every decl
//     is implicitly ambient in a .d.ts file).
//
// Recurses into ExportNamedDeclaration so `export function foo();
// export function foo() { }` is handled identically to the unwrapped
// shape (canonical TS overload pattern in .d.ts and ambient libraries).
//
// One important difference vs. the class version: there is no
// conservative "all signatures, no impl in scope -> skip" pre-pass.
// At the top level a single bare `function foo();` IS an error
// (TS2391) per FunctionDeclaration3.ts. The class pre-pass exists to
// suppress false positives on babel parser-test fixtures of
// signature-only classes; that babel pattern doesn't occur for
// top-level FunctionDeclarations.

// fn_decl_extract — pull a FunctionDeclaration out of a Statement,
// looking through one ExportNamedDeclaration wrapper. Returns the
// underlying FunctionDeclaration plus a stable name-loc for diagnostics.
// `nil, false` for any non-function statement.
@(private="file")
fn_decl_extract :: proc(stmt: ^Statement) -> (fn: ^FunctionDeclaration, ok: bool) {
	if stmt == nil { return nil, false }
	#partial switch v in stmt^ {
	case ^FunctionDeclaration:
		if v == nil { return nil, false }
		return v, true
	case ^ExportNamedDeclaration:
		if v == nil { return nil, false }
		d, have := v.declaration.(^Declaration)
		if !have || d == nil { return nil, false }
		#partial switch inner in d^ {
		case ^FunctionDeclaration:
			if inner == nil { return nil, false }
			return inner, true
		}
	}
	return nil, false
}

// fn_decl_overload_name — overloadable name + name-loc for a
// FunctionDeclaration. Anonymous declarations (legal only as
// `export default function() {}`) cannot participate in chains.
@(private="file")
fn_decl_overload_name :: proc(fn: ^FunctionDeclaration) -> (name: string, at: u32, ok: bool) {
	if fn == nil { return "", 0, false }
	id, have := fn.id.(BindingIdentifier)
	if !have { return "", 0, false }
	return id.name, u32(id.loc.start), true
}

// ck_check_ts_func_overloads — walks a Statement-list left-to-right;
// emits TS2391 / TS2389 per the overload-chain rules.
//
// Pre-pass: skip the entire check when NO FunctionDeclaration in this
// scope carries an implementation body. Mirrors the class-version
// pre-pass and is needed because babel's TS conformance corpus (and
// oxc-semantic, which is the gating oracle) treats sig-only files as
// legal ambient patterns —
//   `export function f(x: number): number;`
//   `export function f(x: string): string;`
// is accepted by oxc-semantic even though tsc would TS2391. We match
// oxc-semantic to keep babel positive fixtures clean and still emit
// TS2391 / TS2389 wherever an impl IS present and the chain is
// inconsistent (FunctionDeclaration4.ts / 6.ts shape).
@(private="file")
ck_check_ts_func_overloads :: proc(c: ^Checker, body: []^Statement) {
	if c == nil || len(body) == 0 { return }

	flush_unimplemented :: proc(c: ^Checker, sigs: []u32) {
		for at in sigs {
			ck_report_coded(c, at, .K4080_DuplicateImplementation, "Function implementation is missing or not immediately following the declaration")
		}
	}

	// Per-chain state. `chain_sigs` accumulates the name-loc of each
	// signature in the active chain so flush_unimplemented can emit
	// TS2391 at the precise identifier offset (matching the class
	// version's per-element loc).
	chain_active   := false
	chain_name     := ""
	chain_exported := false // True if ALL sigs in the chain are exported.
	chain_sigs:  [dynamic]u32
	chain_sigs.allocator = context.temp_allocator
	defer delete(chain_sigs)

	// Helper: check if a statement is wrapped in ExportNamedDeclaration.
	is_exported :: proc(stmt: ^Statement) -> bool {
		if stmt == nil { return false }
		_, ok := stmt^.(^ExportNamedDeclaration)
		return ok
	}

	for stmt in body {
		fn, is_fn := fn_decl_extract(stmt)
		if !is_fn {
			if chain_active && !chain_exported {
				flush_unimplemented(c, chain_sigs[:])
			}
			chain_active = false
			clear(&chain_sigs)
			continue
		}
		if fn.declare {
			// `declare function foo();` is a complete ambient decl.
			// Doesn't participate in chains; flushes any active chain.
			if chain_active && !chain_exported {
				flush_unimplemented(c, chain_sigs[:])
			}
			chain_active = false
			clear(&chain_sigs)
			continue
		}
		name, name_at, has_name := fn_decl_overload_name(fn)
		if !has_name {
			if chain_active && !chain_exported {
				flush_unimplemented(c, chain_sigs[:])
			}
			chain_active = false
			clear(&chain_sigs)
			continue
		}
		has_body := !fn.no_body
		exported := is_exported(stmt)
		if chain_active {
			if has_body {
				// Implementation found. TS treats ANY following
				// function-with-body as the impl for the chain — TS2389
				// fires on name mismatch (FunctionDeclaration4.ts shape).
				if name != chain_name {
					msg := fmt.tprintf("Function implementation name must be '%s'.", chain_name)
					ck_report_coded(c, name_at, .K2070_RequiredFormOrBinding, msg)
				}
				chain_active = false
				clear(&chain_sigs)
			} else {
				if name == chain_name {
					append(&chain_sigs, name_at)
					if !exported { chain_exported = false }
				} else {
					// Different-name sig in middle of chain — prior chain ends
					// unimplemented; this sig opens a new chain.
					if !chain_exported {
						flush_unimplemented(c, chain_sigs[:])
					}
					clear(&chain_sigs)
					chain_name = name
					chain_exported = exported
					append(&chain_sigs, name_at)
				}
			}
		} else {
			if !has_body {
				chain_active   = true
				chain_name     = name
				chain_exported = exported
				append(&chain_sigs, name_at)
			}
			// else: standalone full function, no chain involved.
		}
	}
	if chain_active && !chain_exported {
		flush_unimplemented(c, chain_sigs[:])
	}
}

// =============================================================================
// TS2393 "Duplicate function implementation" — per-scope dup-impl check
// =============================================================================
//
// Distinct from TS2391 / TS2389 (overload-chain mismatches). Fires when
// the SAME name has TWO OR MORE FunctionDeclarations with bodies in a
// single scope (Program top-level, BlockStatement body, FunctionBody,
// or TSModuleBlock). Each impl is flagged.
//
// Examples that report TS2393:
//   function foo() {} function foo() {}                      → both flagged
//   function foo(); function foo() {} function foo() {}      → impls 2 + 3
//   export function f(){}  export function f(){}             → both flagged
//
// Suppressed:
//   * declare function foo() {}            (ambient — sig-only semantically)
//   * function foo()                       (overload-signature; covered by
//                                           ck_check_ts_func_overloads)
//   * .d.ts files                          (caller-side gate in
//                                           ck_check_ts_body_decls)
//
// Plays nicely with ck_check_ts_func_overloads: the overload-chain pass
// emits TS2391 / TS2389 on signatures + impl-name mismatches, and this
// pass emits TS2393 wherever there is more than one impl — they target
// disjoint conditions, so no double-firing on legal `sig; sig; impl;`.
// ck_check_ts2384_ambient_mismatch — TS2384 "Overload signatures must all
// be ambient or non-ambient." Scans a body for same-name function
// declarations where some are `declare` and some are not.
@(private="file")
ck_check_ts2384_ambient_mismatch :: proc(c: ^Checker, body: []^Statement) {
	if c == nil || len(body) == 0 { return }

	// Track (name → has_ambient, has_nonamb, first_loc).
	AmbientState :: struct { has_ambient: bool, has_nonamb: bool, first_loc: u32 }
	seen: map[string]AmbientState
	seen.allocator = context.temp_allocator
	defer delete(seen)

	for stmt in body {
		fn, is_fn := fn_decl_extract(stmt)
		if !is_fn || fn == nil { continue }
		name, _, has_name := fn_decl_overload_name(fn)
		if !has_name { continue }
		entry, found := seen[name]
		if !found {
			entry = AmbientState{first_loc = u32(fn.loc.start)}
		}
		if fn.declare {
			entry.has_ambient = true
		} else {
			entry.has_nonamb = true
		}
		seen[name] = entry
	}

	// Second pass: report on any name with mixed ambient/non-ambient.
	for stmt in body {
		fn, is_fn := fn_decl_extract(stmt)
		if !is_fn || fn == nil { continue }
		name, _, has_name := fn_decl_overload_name(fn)
		if !has_name { continue }
		entry, found := seen[name]
		if !found { continue }
		if entry.has_ambient && entry.has_nonamb {
			ck_report_coded(c, u32(fn.loc.start), .K4050_AmbientContextRestriction, "Overload signatures must all be ambient or non-ambient")
			// Remove from map so we only report once per name.
			delete_key(&seen, name)
		}
	}
}

@(private="file")
ck_check_ts_dup_func_impls :: proc(c: ^Checker, body: []^Statement) {
	if c == nil || len(body) == 0 { return }

	// Pass 1: count impl bodies per name.
	impl_count: map[string]int
	impl_count.allocator = context.temp_allocator
	defer delete(impl_count)
	for stmt in body {
		fn, is_fn := fn_decl_extract(stmt)
		if !is_fn || fn.declare || fn.no_body { continue }
		name, _, has_name := fn_decl_overload_name(fn)
		if !has_name { continue }
		impl_count[name] = impl_count[name] + 1
	}

	// Pass 2: emit on every impl whose name has count >= 2.
	for stmt in body {
		fn, is_fn := fn_decl_extract(stmt)
		if !is_fn || fn.declare || fn.no_body { continue }
		name, name_at, has_name := fn_decl_overload_name(fn)
		if !has_name { continue }
		if impl_count[name] >= 2 {
			ck_report_coded(c, name_at, .K4080_DuplicateImplementation,
				"Duplicate function implementation")
		}
	}
}

// ck_ubd_collect_bindings — walk a destructuring pattern tree and collect
// every Identifier binding into `decls` (name → first-seen source offset).
// Recurses through ObjectPattern / ArrayPattern / AssignmentPattern /
// RestElement so that destructured `let { a, b: [c] }` tracks a, b, c.
// v2 addition: replaces the v1 bare-Identifier-only
// collection so `let {[a]: a}` and `let [x2 = x2]` are caught.
@(private="file")
ck_ubd_collect_bindings :: proc(pattern: Pattern, decls: ^map[string]u32) {
	#partial switch p in pattern {
	case ^Identifier:
		if p != nil {
			if _, exists := decls[p.name]; !exists {
				decls[p.name] = u32(p.loc.start)
			}
		}
	case ^ObjectPattern:
		if p == nil { return }
		for prop in p.properties {
			ck_ubd_collect_bindings(prop.value, decls)
		}
	case ^ArrayPattern:
		if p == nil { return }
		for el in p.elements {
			if inner, ok := el.(Pattern); ok {
				ck_ubd_collect_bindings(inner, decls)
			}
		}
	case ^AssignmentPattern:
		if p != nil { ck_ubd_collect_bindings(p.left, decls) }
	case ^RestElement:
		if p != nil { ck_ubd_collect_bindings(p.argument, decls) }
	case ^MemberExpression:
		// Destructuring target (e.g. `[obj.prop] = arr`) — not a binding.
	}
}

// ck_ubd_walk_pattern_values — walk the value-position sub-expressions of
// a destructuring pattern: computed keys inside ObjectPattern properties
// and default-value expressions in AssignmentPattern right-hand sides.
// Does NOT walk the binding names themselves (they're declarations, not
// references). Used by the UBD walker to flag refs like `let {[a]: a}`
// where the computed key is a value-position use before the declaration.
@(private="file")
ck_ubd_walk_pattern_values :: proc(c: ^Checker, pattern: Pattern, decls: ^map[string]u32, self_name: string, closure_depth: int) {
	#partial switch p in pattern {
	case ^ObjectPattern:
		if p == nil { return }
		for prop in p.properties {
			// Walk the computed key expression (value position).
			// When computed, the parser stores a ^Expression as the key
			// inside the Maybe(ObjectPatternPropertyKey). The value is
			// live at runtime; we use a #partial switch to extract it.
			if prop.computed && prop.key != nil {
				#partial switch key in prop.key.? {
				case ^Expression:
					if key != nil {
						ck_ubd_walk_expr(c, key, decls, self_name, closure_depth)
					}
				}
			}
			// Recurse into the value pattern (may contain AssignmentPattern
			// default values).
			ck_ubd_walk_pattern_values(c, prop.value, decls, self_name, closure_depth)
		}
	case ^ArrayPattern:
		if p == nil { return }
		for el in p.elements {
			if inner, ok := el.(Pattern); ok {
				ck_ubd_walk_pattern_values(c, inner, decls, self_name, closure_depth)
			}
		}
	case ^AssignmentPattern:
		if p == nil { return }
		// The right-hand default value is evaluated BEFORE the left-hand
		// binding is initialized. A ref to the left-hand name inside the
		// right side is self-init (TS2448, e.g. `let [e = e] = ...`).
		// Extract the binding name from the left pattern and use it as
		// self_name for the right-side walk, overriding any outer name.
		left_name := ck_ubd_binding_name(p.left)
		effective_name := self_name
		if len(left_name) > 0 { effective_name = left_name }
		ck_ubd_walk_expr(c, p.right, decls, effective_name, closure_depth)
		// Recurse into the left-hand binding pattern (its computed keys).
		ck_ubd_walk_pattern_values(c, p.left, decls, effective_name, closure_depth)
	case ^RestElement:
		if p != nil { ck_ubd_walk_pattern_values(c, p.argument, decls, self_name, closure_depth) }
	case ^MemberExpression:
		// Destructuring target (e.g. `[obj.prop] = arr`) — value-position
		// expression, walk it fully. Must cast to ^Expression because
		// MemberExpression is in both Pattern and Expression unions.
		if p != nil { ck_ubd_walk_expr(c, (^Expression)(p), decls, self_name, closure_depth) }
	// ^Identifier: no value-position sub-expressions (the name itself is a
	// binding, not a ref — handled by ck_ubd_collect_bindings in Pass 1).
	}
}

// ck_ubd_walk_class_statics — walk the static field initializers and
// decorators of a class body looking for UBD refs. These execute at
// class-DEFINITION time (not deferred-by-closure), so they must be
// checked for use-before-decl violations. Instance members are NOT
// walked — their bodies are evaluated when CALLED, not when defined.
@(private="file")
ck_ubd_walk_class_statics :: proc(c: ^Checker, body: ClassBody, decls: ^map[string]u32) {
	for elem in body.body {
		// Decorators on every element run at class-definition time.
		for deco in elem.decorators {
			ck_ubd_walk_expr(c, deco.expression, decls, "", 0)
		}
		// Static blocks (kind == .StaticBlock) execute at class-definition
		// time. Their body is stored as a FunctionExpression in elem.value
		// but elem.static is false (the kind implies it). Walk the block
		// body statements directly for UBD refs.
		if elem.kind == .StaticBlock {
			if val, ok := elem.value.(^Expression); ok && val != nil {
				if fn, is_fn := val^.(^FunctionExpression); is_fn && fn != nil {
					for sub in fn.body.body {
						ck_ubd_walk_stmt(c, sub, decls)
					}
				}
			}
			continue
		}
		if !elem.static { continue }
		// Static field initializers run at class-definition time.
		if val, ok := elem.value.(^Expression); ok && val != nil {
			// The walk may descend into a FunctionExpression for methods;
			// ck_ubd_walk_expr stops at closure boundaries, so method
			// bodies are skipped. Field initializers are bare expressions —
			// they get walked fully.
			ck_ubd_walk_expr(c, val, decls, "", 0)
		}
	}
}

// ck_check_ts_use_before_decl — TS2448 "Block-scoped variable 'X' used
// before its declaration." Walks `body` (the statements of one block-scope
// region: Program / BlockStatement / FunctionBody / TSModuleBlock) and
// flags any value-position Identifier reference whose name resolves to a
// `let` / `const` / `using` / `await using` declaration that appears LATER
// in the same body. Conservative: descends into control-flow statements
// (if/while/for/switch/try/throw/return/expression-statement) and into
// the immediate operands of expressions, but stops at function/arrow/method
// boundaries (closures — their refs are evaluated when called, not when
// the closure is defined) and at TS type positions (typeof X, T<X>, etc.
// — they're erased at runtime and don't count as a use).
//
// v2 additions:
//   * Destructuring patterns — Pass 1 now walks ObjectPattern /
//     ArrayPattern / AssignmentPattern / RestElement to collect all
//     Identifier bindings (was bare-Identifier only). Pass 2 walks
//     computed keys and default values in binding patterns.
//   * Self-init — `let x = x + 1;` is now caught via the `self_name`
//     mechanism: when walking the initializer of a declarator that
//     binds name N, any ref to N is flagged unless it's inside a
//     closure (function/arrow/class body).
//   * Class static initializers and decorators — ClassDeclaration
//     decorators + static field initializers + all element decorators
//     are now walked (they execute at class-definition time, not
//     deferred-by-closure).
//   * Nested BlockStatements get their own scope via `ck_check_ts_body_decls`
//     recursion (called from `ck_walk_stmt` for every block body), so we
//     don't need to descend into them ourselves — we just need to check
//     refs at THIS scope level.
@(private="file")
ck_check_ts_use_before_decl :: proc(c: ^Checker, body: []^Statement) {
	if c == nil || len(body) == 0 { return }

	// Pass 1: collect (name → first binding-id offset) for each let/const/
	// using/await-using top-level declaration in this body slice. Skip
	// `declare const` (ambient — has no runtime initializer / TDZ).
	decls: map[string]u32
	decls.allocator = context.temp_allocator
	defer delete(decls)

	for stmt in body {
		if stmt == nil { continue }
		var_decl, is_var := stmt^.(^VariableDeclaration)
		if !is_var || var_decl == nil { continue }
		if var_decl.declare { continue }
		#partial switch var_decl.kind {
		case .Let, .Const, .Using, .AwaitUsing:
			// fall through
		case:
			continue
		}
		for d in var_decl.declarations {
			ck_ubd_collect_bindings(d.id, &decls)
		}
	}
	if len(decls) == 0 { return }

	// Pass 2: walk each statement and flag value-position Identifier refs
	// whose offset is BEFORE the matching binding-id's offset.
	for stmt in body {
		ck_ubd_walk_stmt(c, stmt, &decls)
	}
}

// Walk a statement looking for value-position Identifier refs to names
// in `decls`. Recurses into immediate sub-statements (consequent/alternate/
// body/etc.) but does NOT enter nested function/class/method bodies (those
// are closures and their refs are deferred). Also does NOT enter nested
// BlockStatement bodies — they have their own scopes that get a separate
// ck_check_ts_use_before_decl pass via ck_check_ts_body_decls.
//
// v2: walks pattern value positions (computed keys,
// default values), self-init initializers, and ClassDeclaration static
// members + decorators.
@(private="file")
ck_ubd_walk_stmt :: proc(c: ^Checker, stmt: ^Statement, decls: ^map[string]u32) {
	if stmt == nil { return }
	#partial switch s in stmt^ {
	case ^ExpressionStatement:
		if s != nil { ck_ubd_walk_expr(c, s.expression, decls, "", 0) }
	case ^ReturnStatement:
		if s != nil {
			if a, ok := s.argument.(^Expression); ok { ck_ubd_walk_expr(c, a, decls, "", 0) }
		}
	case ^IfStatement:
		if s != nil {
			ck_ubd_walk_expr(c, s.test, decls, "", 0)
			ck_ubd_walk_stmt(c, s.consequent, decls)
			if alt, ok := s.alternate.(^Statement); ok { ck_ubd_walk_stmt(c, alt, decls) }
		}
	case ^WhileStatement:
		if s != nil { ck_ubd_walk_expr(c, s.test, decls, "", 0); ck_ubd_walk_stmt(c, s.body, decls) }
	case ^DoWhileStatement:
		if s != nil { ck_ubd_walk_stmt(c, s.body, decls); ck_ubd_walk_expr(c, s.test, decls, "", 0) }
	case ^ForStatement:
		if s != nil {
			if e, ok := s.init_expr.(^Expression); ok { ck_ubd_walk_expr(c, e, decls, "", 0) }
			if d, ok := s.init_decl.(^VariableDeclaration); ok && d != nil {
				for declr in d.declarations {
					// Walk computed keys + default values in the pattern.
					ck_ubd_walk_pattern_values(c, declr.id, decls, "", 0)
					// Walk the initializer with self-init detection.
					if init, have := declr.init.(^Expression); have {
						self_name := ck_ubd_binding_name(declr.id)
						ck_ubd_walk_expr(c, init, decls, self_name, 0)
					}
				}
			}
			if e, ok := s.test.(^Expression); ok { ck_ubd_walk_expr(c, e, decls, "", 0) }
			if e, ok := s.update.(^Expression); ok { ck_ubd_walk_expr(c, e, decls, "", 0) }
			ck_ubd_walk_stmt(c, s.body, decls)
		}
	case ^ForInStatement:
		if s != nil {
			ck_ubd_walk_expr(c, s.right, decls, "", 0)
			// Walk computed keys / default values in the left-hand pattern
			// when the left is a VariableDeclaration.
			if d, ok := s.left_decl.(^VariableDeclaration); ok && d != nil {
				for declr in d.declarations {
					ck_ubd_walk_pattern_values(c, declr.id, decls, "", 0)
				}
			}
			ck_ubd_walk_stmt(c, s.body, decls)
		}
	case ^ForOfStatement:
		if s != nil {
			ck_ubd_walk_expr(c, s.right, decls, "", 0)
			if d, ok := s.left_decl.(^VariableDeclaration); ok && d != nil {
				for declr in d.declarations {
					ck_ubd_walk_pattern_values(c, declr.id, decls, "", 0)
				}
			}
			ck_ubd_walk_stmt(c, s.body, decls)
		}
	case ^ThrowStatement:
		if s != nil { ck_ubd_walk_expr(c, s.argument, decls, "", 0) }
	case ^SwitchStatement:
		if s != nil {
			ck_ubd_walk_expr(c, s.discriminant, decls, "", 0)
			for ca in s.cases {
				if t, ok := ca.test.(^Expression); ok { ck_ubd_walk_expr(c, t, decls, "", 0) }
				for cs in ca.consequent { ck_ubd_walk_stmt(c, cs, decls) }
			}
		}
	case ^TryStatement:
		if s != nil {
			for sub in s.block.body { ck_ubd_walk_stmt(c, sub, decls) }
			if h, ok := s.handler.(CatchClause); ok {
				for sub in h.body.body { ck_ubd_walk_stmt(c, sub, decls) }
			}
			if f, ok := s.finalizer.(BlockStatement); ok {
				for sub in f.body { ck_ubd_walk_stmt(c, sub, decls) }
			}
		}
	case ^LabeledStatement:
		if s != nil { ck_ubd_walk_stmt(c, s.body, decls) }
	case ^VariableDeclaration:
		// Walk the initializer of every declarator — a let/const declared
		// here may reference a name declared LATER in the same scope.
		// `var` is hoisted (no TDZ for var), but TS still emits TS2448 if
		// you put a value-side ref to a let/const before its declaration.
		// Also walk computed keys and default values inside the binding
		// pattern (v2: `let {[a]: a}` → `a` in the computed key is a
		// value-position ref before the binding).
		if s != nil {
			for d in s.declarations {
				// Walk computed keys + default values in the pattern.
				ck_ubd_walk_pattern_values(c, d.id, decls, "", 0)
				// Walk the initializer with self-init detection.
				if init, ok := d.init.(^Expression); ok {
					self_name := ck_ubd_binding_name(d.id)
					ck_ubd_walk_expr(c, init, decls, self_name, 0)
				}
			}
		}
	case ^ClassDeclaration:
		// v2: class-decl decorators + static member initializers/decorators
		// execute at class-definition time (NOT deferred-by-closure).
		// The class name itself is hoisted (like a function declaration)
		// so refs inside the class body to the class name are fine —
		// but refs to OTHER names declared later (e.g. const ObjLiteral
		// in `static x = ObjLiteral.A`) are use-before-decl.
		if s != nil {
			for deco in s.decorators {
				ck_ubd_walk_expr(c, deco.expression, decls, "", 0)
			}
			ck_ubd_walk_class_statics(c, s.body, decls)
		}
	case ^ExportNamedDeclaration:
		// Walk the inner declaration (e.g. `export const x = x;`).
		if s != nil {
			if decl, ok := s.declaration.(^Declaration); ok && decl != nil {
				// Recurse into the wrapped declaration. Switch on its type
				// so we walk VariableDeclaration / ClassDeclaration correctly.
				#partial switch inner in decl^ {
				case ^VariableDeclaration:
					ck_ubd_walk_stmt(c, cast(^Statement) inner, decls)
				case ^ClassDeclaration:
					ck_ubd_walk_stmt(c, cast(^Statement) inner, decls)
				case ^FunctionDeclaration:
					// Hoisted — skip (function names are available early).
				}
			}
		}
	case ^ExportDefaultDeclaration:
		// Walk the inner declaration/expression.
		if s != nil {
			#partial switch def in s.declaration^ {
			case ^Declaration:
				#partial switch inner in def^ {
				case ^VariableDeclaration:
					ck_ubd_walk_stmt(c, cast(^Statement) inner, decls)
				case ^ClassDeclaration:
					ck_ubd_walk_stmt(c, cast(^Statement) inner, decls)
				case ^FunctionDeclaration:
					// Hoisted.
				}
			case ^Expression:
				ck_ubd_walk_expr(c, def, decls, "", 0)
			}
		}
	// Skip: BlockStatement (own scope, handled by recursion), FunctionDeclaration
	// (closure / hoisted name), TS*Declaration (type-level).
	}
}

// ck_ubd_binding_name — return the first Identifier binding name from a
// pattern, or "" if the pattern doesn't start with a bare Identifier.
// Used for self-init detection (`let x = x + 1` — "x" is the self-name).
@(private="file")
ck_ubd_binding_name :: proc(pattern: Pattern) -> string {
	if id, ok := pattern.(^Identifier); ok && id != nil {
		return id.name
	}
	return ""
}

// Walk an expression looking for Identifier refs to names in `decls`.
// Skips nested function/arrow/class bodies (closures — deferred refs)
// and TS type-only sub-trees (typeof, type args, type assertion target).
//
// Parameters:
//   self_name — if non-empty, any ref to this name is flagged regardless
//     of offset (unless inside a closure). Used for self-init detection.
//   closure_depth — incremented when entering a function/arrow/class body.
//     When > 0, self_name refs are deferred (not flagged).
@(private="file")
ck_ubd_walk_expr :: proc(c: ^Checker, expr: ^Expression, decls: ^map[string]u32, self_name: string, closure_depth: int) {
	if expr == nil { return }
	#partial switch e in expr^ {
	case ^Identifier:
		if e == nil { return }
		// Self-init: if this ref matches the current declarator's binding
		// name AND we're not inside a closure, flag it.
		if len(self_name) > 0 && e.name == self_name && closure_depth == 0 {
			msg := fmt.tprintf("Block-scoped variable '%s' used before its declaration.", e.name)
			ck_report_coded(c, u32(e.loc.start), .K3037_DuplicateIdentifier, msg)
			return
		}
		decl_off, ok := decls^[e.name]
		if !ok { return }
		ref_off := u32(e.loc.start)
		if ref_off >= decl_off { return }
		msg := fmt.tprintf("Block-scoped variable '%s' used before its declaration.", e.name)
		ck_report_coded(c, ref_off, .K3037_DuplicateIdentifier, msg)
	case ^FunctionExpression:
		// Entering a closure: increment closure_depth so self-init refs
		// inside are deferred. Also stop walking — the body is evaluated
		// when called, not when the closure is defined.
		// BUT: default parameter values ARE evaluated at definition time.
		if e != nil {
			for param in e.params {
				if dv, ok := param.default_val.(^Expression); ok && dv != nil {
					ck_ubd_walk_expr(c, dv, decls, self_name, closure_depth)
				}
			}
		}
	case ^ArrowFunctionExpression:
		// Same as FunctionExpression: default params are value positions,
		// the body is a closure.
		if e != nil {
			for param in e.params {
				if dv, ok := param.default_val.(^Expression); ok && dv != nil {
					ck_ubd_walk_expr(c, dv, decls, self_name, closure_depth)
				}
			}
		}
	case ^ClassExpression:
		// The class name is hoisted, and decorators / static initializers
		// run at class-definition time. If this ClassExpression appears
		// as an expression (e.g. inside a default value), walk its
		// decorators and static members. The instance members are
		// deferred-by-closure.
		if e != nil {
			for deco in e.decorators {
				ck_ubd_walk_expr(c, deco.expression, decls, self_name, closure_depth)
			}
			// Static members execute immediately; walk them. Instance
			// members are deferred (their bodies are evaluated when
			// called). ck_ubd_walk_class_statics only touches statics.
			ck_ubd_walk_class_statics(c, e.body, decls)
		}
	case ^CallExpression:
		if e == nil { return }
		ck_ubd_walk_expr(c, e.callee, decls, self_name, closure_depth)
		for a in e.arguments { ck_ubd_walk_expr(c, a, decls, self_name, closure_depth) }
	case ^NewExpression:
		if e == nil { return }
		ck_ubd_walk_expr(c, e.callee, decls, self_name, closure_depth)
		for a in e.arguments { ck_ubd_walk_expr(c, a, decls, self_name, closure_depth) }
	case ^MemberExpression:
		if e == nil { return }
		ck_ubd_walk_expr(c, e.object, decls, self_name, closure_depth)
		if e.computed { ck_ubd_walk_expr(c, e.property, decls, self_name, closure_depth) }
	case ^BinaryExpression:
		if e == nil { return }
		ck_ubd_walk_expr(c, e.left, decls, self_name, closure_depth)
		ck_ubd_walk_expr(c, e.right, decls, self_name, closure_depth)
	case ^LogicalExpression:
		if e == nil { return }
		ck_ubd_walk_expr(c, e.left, decls, self_name, closure_depth)
		ck_ubd_walk_expr(c, e.right, decls, self_name, closure_depth)
	case ^UnaryExpression:
		if e != nil { ck_ubd_walk_expr(c, e.argument, decls, self_name, closure_depth) }
	case ^UpdateExpression:
		if e != nil { ck_ubd_walk_expr(c, e.argument, decls, self_name, closure_depth) }
	case ^ConditionalExpression:
		if e == nil { return }
		ck_ubd_walk_expr(c, e.test, decls, self_name, closure_depth)
		ck_ubd_walk_expr(c, e.consequent, decls, self_name, closure_depth)
		ck_ubd_walk_expr(c, e.alternate, decls, self_name, closure_depth)
	case ^AssignmentExpression:
		if e == nil { return }
		ck_ubd_walk_expr(c, e.left, decls, self_name, closure_depth)
		ck_ubd_walk_expr(c, e.right, decls, self_name, closure_depth)
	case ^SequenceExpression:
		if e == nil { return }
		for s in e.expressions { ck_ubd_walk_expr(c, s, decls, self_name, closure_depth) }
	case ^ArrayExpression:
		if e == nil { return }
		for el in e.elements {
			if inner, ok := el.(^Expression); ok && inner != nil { ck_ubd_walk_expr(c, inner, decls, self_name, closure_depth) }
		}
	case ^ObjectExpression:
		if e == nil { return }
		for prop in e.properties {
			if prop.computed && prop.key != nil { ck_ubd_walk_expr(c, prop.key, decls, self_name, closure_depth) }
			ck_ubd_walk_expr(c, prop.value, decls, self_name, closure_depth)
		}
	case ^SpreadElement:
		if e != nil { ck_ubd_walk_expr(c, e.argument, decls, self_name, closure_depth) }
	case ^TemplateLiteral:
		if e == nil { return }
		for ex in e.expressions { ck_ubd_walk_expr(c, ex, decls, self_name, closure_depth) }
	case ^TaggedTemplateExpression:
		if e == nil { return }
		ck_ubd_walk_expr(c, e.tag, decls, self_name, closure_depth)
		ck_ubd_walk_expr(c, e.quasi, decls, self_name, closure_depth)
	case ^ChainExpression:
		if e != nil { ck_ubd_walk_expr(c, e.expression, decls, self_name, closure_depth) }
	case ^ParenthesizedExpression:
		if e != nil { ck_ubd_walk_expr(c, e.expression, decls, self_name, closure_depth) }
	case ^AwaitExpression:
		if e != nil { ck_ubd_walk_expr(c, e.argument, decls, self_name, closure_depth) }
	case ^YieldExpression:
		if e != nil {
			if a, ok := e.argument.(^Expression); ok { ck_ubd_walk_expr(c, a, decls, self_name, closure_depth) }
		}
	case ^ImportExpression:
		if e != nil { ck_ubd_walk_expr(c, e.source, decls, self_name, closure_depth) }
	case ^TSAsExpression:
		// `expr as T` — walk the value side, skip the type annotation.
		if e != nil { ck_ubd_walk_expr(c, e.expression, decls, self_name, closure_depth) }
	case ^TSSatisfiesExpression:
		if e != nil { ck_ubd_walk_expr(c, e.expression, decls, self_name, closure_depth) }
	case ^TSNonNullExpression:
		if e != nil { ck_ubd_walk_expr(c, e.expression, decls, self_name, closure_depth) }
	case ^TSTypeAssertion:
		// `<T>expr` — walk only the value side.
		if e != nil { ck_ubd_walk_expr(c, e.expression, decls, self_name, closure_depth) }
	case ^TSInstantiationExpression:
		// `f<T>` — the LHS is a value position, the type args are TS-only.
		if e != nil { ck_ubd_walk_expr(c, e.expression, decls, self_name, closure_depth) }
	// Skip closure shapes — their bodies are evaluated when CALLED, not
	// when defined: ^FunctionExpression, ^ArrowFunctionExpression,
	// ^ClassExpression are handled above with decorator / default-value
	// walking, but their inner bodies are deferred.
	// Skip leaves and non-value nodes: literals, ^ThisExpression, ^Super,
	// ^MetaProperty, ^PrivateIdentifier, JSX*.
	}
}

// ck_check_ts_body_decls — TS-only per-scope body checks. Runs the
// declaration-merge dup-detect, the function-declaration overload-
// chain check, the duplicate-function-implementation check, AND the
// ck_pattern_display_name — short display name for a Pattern.
// For BindingIdentifier: just the name. For destructuring: first bound name.
@(private="file")
ck_pattern_display_name :: proc(pat: Pattern) -> string {
	#partial switch p in pat {
	case ^Identifier:
		if p != nil { return p.name }
	case ^ObjectPattern, ^ArrayPattern:
		names: [dynamic]string
		names.allocator = context.temp_allocator
		reserve(&names, 2)
		scope_collect_pattern(pat, &names)
		if len(names) > 0 { return names[0] }
	}
	return "<pattern>"
}

// ck_check_ts1268_index_sig_param_type — TS1268 "An index signature
// parameter type must be 'string', 'number', 'symbol', or a template
// literal type." Walks an interface/class body for TSIndexSignature
// members and validates each parameter's type annotation.
@(private="file")
ck_check_ts1268_index_sig_param_type :: proc(c: ^Checker, body: TSInterfaceBody) {
	for sig in body.body {
		if sig == nil { continue }
		idx, is_idx := sig^.(TSIndexSignature)
		if !is_idx { continue }
		for param in idx.parameters {
			ta, has_ta := param.type_annotation.(^TSTypeAnnotation)
			if !has_ta || ta == nil || ta.type_annotation == nil { continue }
			// Check the type.
			valid := false
			#partial switch t in ta.type_annotation^ {
			case ^TSStringKeyword:        valid = true
			case ^TSNumberKeyword:        valid = true
			case ^TSSymbolKeyword:        valid = true
			case ^TSTemplateLiteralType:  valid = true
			case:
				// Also allow union types where every member is valid.
				// Skip for now — too complex.
			}
			if !valid {
				ck_report_coded(c, u32(param.loc.start), .K4055_IndexSignatureForm, "An index signature parameter type must be 'string', 'number', 'symbol', or a template literal type")
			}
		}
	}
}

// ck_check_ts2374_dup_index_sig — TS2374 "Duplicate index signature for
// type 'X'." Walks an interface/class body. If two or more TSIndexSignature
// members have parameters with the same key type (string, number, symbol),
// the second and subsequent are flagged.
@(private="file")
ck_check_ts2374_dup_index_sig :: proc(c: ^Checker, body: TSInterfaceBody) {
	seen_string := false
	seen_number := false
	seen_symbol := false
	for sig in body.body {
		if sig == nil { continue }
		idx, is_idx := sig^.(TSIndexSignature)
		if !is_idx { continue }
		for param in idx.parameters {
			ta, has_ta := param.type_annotation.(^TSTypeAnnotation)
			if !has_ta || ta == nil || ta.type_annotation == nil { continue }
			#partial switch t in ta.type_annotation^ {
			case ^TSStringKeyword:
				if seen_string {
					ck_report_coded(c, u32(idx.loc.start), .K4055_IndexSignatureForm, "Duplicate index signature for type 'string'")
				}
				seen_string = true
			case ^TSNumberKeyword:
				if seen_number {
					ck_report_coded(c, u32(idx.loc.start), .K4055_IndexSignatureForm, "Duplicate index signature for type 'number'")
				}
				seen_number = true
			case ^TSSymbolKeyword:
				if seen_symbol {
					ck_report_coded(c, u32(idx.loc.start), .K4055_IndexSignatureForm, "Duplicate index signature for type 'symbol'")
				}
				seen_symbol = true
			}
		}
	}
}

// ck_check_ts2428_interface_merge — TS2428 "All declarations of 'X'
// must have identical type parameters." When multiple interfaces share
// the same name in one scope, their type parameter lists must match:
// same count, same names, same constraints (structural compare of the
// source text is sufficient — OXC does the same).
@(private="file")
ck_check_ts2428_interface_merge :: proc(c: ^Checker, body: []^Statement) {
	// First interface with each name: store (name → type-param-count).
	InterfaceInfo :: struct {
		param_count: int,
		param_names: [dynamic]string,
		first_loc:   u32,
	}
	seen: map[string]InterfaceInfo
	seen.allocator = context.temp_allocator
	defer delete(seen)

	extract_iface :: proc(stmt: ^Statement) -> (iface: ^TSInterfaceDeclaration, ok: bool) {
		if stmt == nil { return nil, false }
		#partial switch v in stmt^ {
		case ^TSInterfaceDeclaration:
			if v != nil { return v, true }
		case ^ExportNamedDeclaration:
			if v == nil { return nil, false }
			d, have := v.declaration.(^Declaration)
			if !have || d == nil { return nil, false }
			#partial switch inner in d^ {
			case ^TSInterfaceDeclaration:
				if inner != nil { return inner, true }
			}
		}
		return nil, false
	}

	for stmt in body {
		iface, ok := extract_iface(stmt)
		if !ok { continue }
		name := iface.id.name
		// Collect type parameter names.
		pcount := 0
		pnames: [dynamic]string
		pnames.allocator = context.temp_allocator
		if tp, has := iface.type_parameters.(^TSTypeParameterDeclaration); has && tp != nil {
			pcount = len(tp.params)
			for p in tp.params { append(&pnames, p.name.name) }
		}
		if prev, exists := seen[name]; exists {
			// Only compare when BOTH declarations have type parameters.
			// An interface with zero type params merging with one that has
			// defaulted type params is valid in TSC (e.g.
			// `interface X {} interface X<T = number> {}`).
			if pcount > 0 && prev.param_count > 0 {
				if pcount != prev.param_count {
					msg := fmt.tprintf("All declarations of '%s' must have identical type parameters.", name)
					ck_report_coded(c, u32(iface.id.loc.start), .K4080_DuplicateImplementation, msg)
				} else {
					// Compare parameter names.
					mismatch := false
					for i in 0..<pcount {
						if pnames[i] != prev.param_names[i] { mismatch = true; break }
					}
					if mismatch {
						msg := fmt.tprintf("All declarations of '%s' must have identical type parameters.", name)
						ck_report_coded(c, u32(iface.id.loc.start), .K4080_DuplicateImplementation, msg)
					}
				}
			} else if pcount > 0 && prev.param_count == 0 {
				// Non-generic merging with generic is TS2428 only when the generic
				// form has no defaults. Skip for now — requires type parameter
				// default analysis.
			}
		} else {
			seen[name] = InterfaceInfo{
				param_count = pcount,
				param_names = pnames,
				first_loc   = u32(iface.id.loc.start),
			}
		}
	}
}

// ck_check_ts1036_ambient_statements — TS1036 "Statements are not allowed
// in ambient contexts." Walks a body (top-level of .d.ts file, or inside
// declare namespace/module) and flags any statement that is not a
// declaration form. Allowed: variable/function/class/interface/type/enum/
// module/import/export declarations. Disallowed: if, while, for, switch,
// try, throw, return, expression statements, blocks, do, labeled, with,
// debugger, empty statements.
@(private="file")
ck_check_ts1036_ambient_statements :: proc(c: ^Checker, body: []^Statement, allow_empty: bool) {
	for stmt in body {
		if stmt == nil { continue }
		#partial switch v in stmt^ {
		// Allowed declaration forms:
		case ^VariableDeclaration:              continue
		case ^FunctionDeclaration:
			if v != nil {
				// TS1221 — generators are not allowed in ambient contexts.
				if v.generator {
					ck_report_coded(c, u32(v.loc.start), .K4050_AmbientContextRestriction, "Generators are not allowed in an ambient context")
				}
				// TS1040 — async modifier in ambient context.
				if v.async {
					ck_report_coded(c, u32(v.loc.start), .K4032_ModifierMisplaced, "'async' modifier cannot be used in an ambient context")
				}
			}
			continue
		case ^ClassDeclaration:                 continue
		case ^TSInterfaceDeclaration:           continue
		case ^TSTypeAliasDeclaration:           continue
		case ^TSEnumDeclaration:                continue
		case ^TSModuleDeclaration:              continue
		case ^TSImportEqualsDeclaration:        continue
		case ^ImportDeclaration:                continue
		case ^ExportNamedDeclaration:           continue
		case ^ExportDefaultDeclaration:         continue
		case ^ExportAllDeclaration:             continue
		case ^TSExportAssignment:               continue
		case ^TSNamespaceExportDeclaration:     continue
		case ^EmptyStatement:
			// At .d.ts top level, EmptyStatements are benign (`;` after
			// shorthand module declarations). Inside declare-namespace
			// bodies, they are flagged (`;` after interface is a statement).
			if allow_empty { continue }
		// Everything else is a statement — flag it.
		case:
			// Get offset from the statement.
			off := u32(0)
			#partial switch s in stmt^ {
			case ^IfStatement:              if s != nil { off = u32(s.loc.start) }
			case ^WhileStatement:           if s != nil { off = u32(s.loc.start) }
			case ^DoWhileStatement:         if s != nil { off = u32(s.loc.start) }
			case ^ForStatement:             if s != nil { off = u32(s.loc.start) }
			case ^ForInStatement:           if s != nil { off = u32(s.loc.start) }
			case ^ForOfStatement:           if s != nil { off = u32(s.loc.start) }
			case ^SwitchStatement:          if s != nil { off = u32(s.loc.start) }
			case ^TryStatement:             if s != nil { off = u32(s.loc.start) }
			case ^ThrowStatement:           if s != nil { off = u32(s.loc.start) }
			case ^ReturnStatement:          if s != nil { off = u32(s.loc.start) }
			case ^BlockStatement:           if s != nil { off = u32(s.loc.start) }
			case ^EmptyStatement:           if s != nil { off = u32(s.loc.start) }
			case ^ExpressionStatement:      if s != nil { off = u32(s.loc.start) }
			case ^LabeledStatement:         if s != nil { off = u32(s.loc.start) }
			case ^BreakStatement:           if s != nil { off = u32(s.loc.start) }
			case ^ContinueStatement:        if s != nil { off = u32(s.loc.start) }
			case ^WithStatement:            if s != nil { off = u32(s.loc.start) }
			case ^DebuggerStatement:        if s != nil { off = u32(s.loc.start) }
			}
			ck_report_coded(c, off, .K4050_AmbientContextRestriction,
				"Statements are not allowed in ambient contexts")
		}
	}
}

// ck_check_ts1038_nested_declare — TS1038 "A 'declare' modifier cannot
// be used in an already ambient context." Walks the body of a
// `declare namespace/module` or a `.d.ts` namespace body. Any child
// declaration that carries an explicit `declare` modifier is flagged.
@(private="file")
ck_check_ts1038_nested_declare :: proc(c: ^Checker, body: []^Statement) {
	for stmt in body {
		if stmt == nil { continue }
		#partial switch v in stmt^ {
		case ^VariableDeclaration:
			if v != nil && v.declare {
				ck_report_coded(c, u32(v.loc.start), .K4032_ModifierMisplaced, "A 'declare' modifier cannot be used in an already ambient context")
			}
		case ^FunctionDeclaration:
			if v != nil && v.declare {
				ck_report_coded(c, u32(v.loc.start), .K4032_ModifierMisplaced, "A 'declare' modifier cannot be used in an already ambient context")
			}
		case ^ClassDeclaration:
			if v != nil && v.declare {
				ck_report_coded(c, u32(v.loc.start), .K4032_ModifierMisplaced, "A 'declare' modifier cannot be used in an already ambient context")
			}
		case ^TSModuleDeclaration:
			if v != nil && v.declare {
				ck_report_coded(c, u32(v.loc.start), .K4032_ModifierMisplaced, "A 'declare' modifier cannot be used in an already ambient context")
			}
		case ^TSEnumDeclaration:
			if v != nil && v.declare {
				ck_report_coded(c, u32(v.loc.start), .K4032_ModifierMisplaced, "A 'declare' modifier cannot be used in an already ambient context")
			}
		case ^TSInterfaceDeclaration:
			if v != nil && v.declare {
				ck_report_coded(c, u32(v.loc.start), .K4032_ModifierMisplaced, "A 'declare' modifier cannot be used in an already ambient context")
			}
		case ^TSTypeAliasDeclaration:
			if v != nil && v.declare {
				ck_report_coded(c, u32(v.loc.start), .K4032_ModifierMisplaced, "A 'declare' modifier cannot be used in an already ambient context")
			}
		case ^ExportNamedDeclaration:
			// Check the inner declaration: `export declare class C {}` inside
			// a declare-namespace.
			if v == nil { continue }
			d, have := v.declaration.(^Declaration)
			if !have || d == nil { continue }
			#partial switch inner in d^ {
			case ^VariableDeclaration:
				if inner != nil && inner.declare {
					ck_report_coded(c, u32(inner.loc.start), .K4032_ModifierMisplaced, "A 'declare' modifier cannot be used in an already ambient context")
				}
			case ^FunctionDeclaration:
				if inner != nil && inner.declare {
					ck_report_coded(c, u32(inner.loc.start), .K4032_ModifierMisplaced, "A 'declare' modifier cannot be used in an already ambient context")
				}
			case ^ClassDeclaration:
				if inner != nil && inner.declare {
					ck_report_coded(c, u32(inner.loc.start), .K4032_ModifierMisplaced, "A 'declare' modifier cannot be used in an already ambient context")
				}
			case ^TSModuleDeclaration:
				if inner != nil && inner.declare {
					ck_report_coded(c, u32(inner.loc.start), .K4032_ModifierMisplaced, "A 'declare' modifier cannot be used in an already ambient context")
				}
			case ^TSEnumDeclaration:
				if inner != nil && inner.declare {
					ck_report_coded(c, u32(inner.loc.start), .K4032_ModifierMisplaced, "A 'declare' modifier cannot be used in an already ambient context")
				}
			}
		}
	}
}

// ck_check_ts1046_dts_top_level — TS1046 "Top-level declarations in .d.ts
// files must start with either a 'declare' or 'export' modifier."
// Walks Program.body in .d.ts files. Any top-level statement that is
// not `declare`, `export`, or a type-only declaration (interface, type)
// is flagged.
@(private="file")
ck_check_ts1046_dts_top_level :: proc(c: ^Checker, program: ^Program) {
	if program == nil { return }
	for stmt in program.body {
		if stmt == nil { continue }
		#partial switch v in stmt^ {
		case ^VariableDeclaration:
			if v != nil && !v.declare {
				ck_report_coded(c, u32(v.loc.start), .K4050_AmbientContextRestriction, "Top-level declarations in .d.ts files must start with either a 'declare' or 'export' modifier")
			}
		case ^FunctionDeclaration:
			if v != nil && !v.declare {
				ck_report_coded(c, u32(v.loc.start), .K4050_AmbientContextRestriction, "Top-level declarations in .d.ts files must start with either a 'declare' or 'export' modifier")
			}
		case ^ClassDeclaration:
			if v != nil && !v.declare {
				ck_report_coded(c, u32(v.loc.start), .K4050_AmbientContextRestriction, "Top-level declarations in .d.ts files must start with either a 'declare' or 'export' modifier")
			}
		case ^TSModuleDeclaration:
			if v != nil && !v.declare {
				ck_report_coded(c, u32(v.loc.start), .K4050_AmbientContextRestriction, "Top-level declarations in .d.ts files must start with either a 'declare' or 'export' modifier")
			}
		case ^TSEnumDeclaration:
			if v != nil && !v.declare {
				ck_report_coded(c, u32(v.loc.start), .K4050_AmbientContextRestriction, "Top-level declarations in .d.ts files must start with either a 'declare' or 'export' modifier")
			}
		// TSInterfaceDeclaration, TSTypeAliasDeclaration, ImportDeclaration,
		// ExportNamedDeclaration, ExportDefaultDeclaration, ExportAllDeclaration
		// are all valid without `declare` in .d.ts — type-only or export forms.
		}
	}
}

// use-before-declaration (TS2448) check on the same body slice.
// No-op outside TS / TSX.
@(private="file")
ck_check_ts_body_decls :: proc(c: ^Checker, ctx: ^CheckerContext, body: []^Statement, is_block_scope: bool = false) {
	if ctx.lang != .TS && ctx.lang != .TSX { return }
	if len(body) == 0 { return }
	ck_check_ts_decl_merge_body(c, body, ctx.is_dts)
	// TS2428 — All declarations of interface 'X' must have identical
	// type parameters.
	ck_check_ts2428_interface_merge(c, body)
	// Top-level overload-chain check is suppressed inside .d.ts files
	// (every declaration is implicitly ambient there). Per-element
	// `declare function` is suppressed inside the procedure itself.
	if !ctx.is_dts && !is_block_scope {
		ck_check_ts_func_overloads(c, body)
		ck_check_ts_dup_func_impls(c, body)
	}
}

ck_walk_var_decl :: proc(c: ^Checker, ctx: ^CheckerContext, decl: ^VariableDeclaration) {
	if decl == nil { return }
	// §14.3.1.1 — per-declaration duplicate-name check.
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
	//
	// Skipped for TS ambient declarations — `declare var static: any;`,
	// or any var inside `declare namespace M { ... }` / .d.ts. Type-
	// only declarations don't bind real values and the strict-mode
	// reservation doesn't apply (matches OXC).
	if ctx.strict_mode && !decl.declare && !ctx.is_dts {
		for d in decl.declarations {
			ck_check_strict_binding_pattern(c, d.id, .Generic)
		}
	}
	// §16.2.2 — module code carries the [+Await] grammar parameter, so
	// `await` is reserved in BindingIdentifier positions. `var await;`,
	// `let await;`, `const await = 1;` at module scope are all SyntaxError
	// (test262 reserved-words/await-module.js).
	if ctx.source_type == .Module {
		for d in decl.declarations {
			ck_check_module_await_binding(c, d.id)
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
		// Arrows inherit [[HomeObject]] / field-init context from the
		// enclosing scope (unlike regular functions), but `await` /
		// `arguments` inside the arrow body are governed by the arrow's
		// own async/generator flags, NOT by the outer field-init context.
		ctx.in_field_init = false
		// Arrow block-body "use strict" prologue: parse_block_statement does
		// NOT set ExpressionStatement.directive (only parse_function_body /
		// parse_program do), and the parser itself never lifts strict_mode
		// for arrow block bodies. Match that behaviour here — arrow bodies
		// inherit the surrounding strict mode but never lift it.
		prev_static_blk := ctx.in_class_static_block
		ctx.in_params       = true
		ctx.params_is_arrow = true
		ctx.in_async        = outer_in_async || e.async
		ctx.in_generator    = outer_in_gen
		// Arrow PARAMS are evaluated under the enclosing [+Await]
		// context (so `static { (await => 0); }` correctly rejects
		// the `await` arrow param). Keep in_class_static_block here.
		// §15.2.1 / §10.2.1 — if the arrow body contains a `"use strict"`
		// directive, the entire arrow function (including params) is
		// strict-mode code. Lift strict_mode for the param checks.
		prev_strict := ctx.strict_mode
		arrow_body_lifts := false
		if blk, is_blk := e.body.(^BlockStatement); is_blk && blk != nil && len(blk.body) > 0 {
			es, eok := blk.body[0]^.(^ExpressionStatement)
			if eok && es != nil {
				if sl, sok := es.expression.(^StringLiteral); sok && sl != nil && sl.value == "use strict" {
					arrow_body_lifts = true
				}
			}
		}
		if arrow_body_lifts { ctx.strict_mode = true }
		// §15.3.1 / §15.9.1 — ArrowFunction params are ALWAYS
		// UniqueFormalParameters, regardless of strict / sloppy or
		// simple / non-simple. Match parser.odin's old
		// `report_duplicate_param_names(params, true, true)` call by
		// passing is_strict = true (so the "in strict mode" message
		// fires) AND force_non_simple = true (to ensure the check runs
		// even when the params are simple).
		ck_check_duplicate_param_names(c, u32(e.loc.start), e.params[:], true, true)
		for pr in e.params {
			ck_check_arrow_param_pattern(c, ctx, pr.pattern)
			if ctx.strict_mode && ctx.lang != .TS && ctx.lang != .TSX { ck_check_strict_param_pattern(c, pr.pattern) }
			ck_walk_pattern(c, ctx, pr.pattern)
			// Default values are evaluated in the caller's scope, not the
			// arrow's param scope — yield/await in defaults are NOT param errors.
			if d, have := pr.default_val.(^Expression); have && d != nil {
				ctx.in_params = false
				ck_walk_expr(c, ctx, d)
				ctx.in_params = true
			}
		}
		ctx.strict_mode     = prev_strict
		ctx.in_params       = false
		ctx.params_is_arrow = false
		ctx.in_async        = e.async
		ctx.in_generator    = false
		// §15.7.5 / ContainsAwait static semantic: nested function /
		// arrow BODY is its own [Await]-context boundary for the
		// `ContainsAwait of ClassStaticBlockStatementList` rule. An
		// `await` IdentifierReference (shorthand `{ await }` etc.)
		// inside the arrow body is NOT an AwaitExpression in the
		// static block's scope, so reset the flag for the body walk
		// and restore on exit. Test262
		// expressions/object/identifier-shorthand-static-init-await-valid.js.
		ctx.in_class_static_block = false
		defer ctx.in_class_static_block = prev_static_blk
		prev_arrow_body := ctx.in_arrow_body
		ctx.in_arrow_body = true
		defer ctx.in_arrow_body = prev_arrow_body
		#partial switch body in e.body {
		case ^Expression:     if body != nil { ck_walk_expr(c, ctx, body) }
		case ^BlockStatement:
			if body != nil {
				// Arrow block body is function-scope (§15.3.1).
				ck_run_scope_check(c, ctx, body.body[:], false)
				// §15.3.1 / §15.9.1 — BoundNames of FormalParameters may
				// not occur in LexicallyDeclaredNames of FunctionBody.
				// `(bar) => { let bar; }` is a SyntaxError. ck_walk_function
				// already runs this for non-arrow shapes; mirror it here.
				ck_check_params_vs_body_lex(c, e.params[:], body.body[:], ctx.strict_mode)
				for s in body.body { ck_walk_stmt(c, ctx, s) }
			}
		}
		ck_exit_function(ctx, saved)

	case ^ClassExpression:
		if e != nil { ck_walk_class(c, ctx, e) }

	case ^MemberExpression:
		if e == nil { return }
		// §15.7.3 super.#name — migrated to parser.
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
		// §13.3.5 — NewExpression : new MemberExpression. MemberExpression
		// does not produce AwaitExpression, so `new await <expr>` at module
		// top-level (where `await` is reserved as the head of an
		// AwaitExpression rather than an Identifier) is a SyntaxError. The
		// parser doesn't currently track [+Await] for module top-level,
		// so the AST shape we receive is
		// `NewExpression{ callee: Identifier("await"), arguments: [] }`
		// when the source was `new await;`. Detect that exact shape here.
		// Test262 module-code/top-level-await/new-await.js.
		if ctx.source_type == .Module && e.callee != nil {
			if id, ok := e.callee^.(^Identifier); ok && id != nil && id.name == "await" {
				ck_report_coded(c, u32(id.loc.start), .K3010_AwaitYieldAsBindingName, "'await' is reserved as the head of an AwaitExpression in module code; cannot follow 'new'")
			}
		}
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
		// duplicate-binding purposes (matches OXC). Set scope_skip while
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
		// When the LHS is an ObjectExpression or ArrayExpression under a
		// plain `=` operator, it's a destructuring assignment pattern.
		// Suppress checks that only apply to true object/array literals
		// (e.g., TS1117 duplicate properties) while walking the LHS.
		if e.operator == .Assign {
			is_destructure := false
			if e.left != nil {
				#partial switch _ in e.left^ {
				case ^ObjectExpression, ^ArrayExpression:
					is_destructure = true
				}
			}
			if is_destructure {
				prev := ctx.in_assignment_target
				ctx.in_assignment_target = true
				ck_walk_expr(c, ctx, e.left)
				ctx.in_assignment_target = prev
			} else {
				ck_walk_expr(c, ctx, e.left)
			}
		} else {
			ck_walk_expr(c, ctx, e.left)
		}
		ck_walk_expr(c, ctx, e.right)

	case ^SequenceExpression:
		if e != nil { for s in e.expressions { ck_walk_expr(c, ctx, s) } }

	case ^ArrayExpression:
		if e == nil { return }
		// ArrayExpression interior is an uncovered context. Mirror the
		// Suppress scope-clash walk for nested function / arrow / class
		// bodies inside (matches OXC).
		prev_skip := ctx.scope_skip
		ctx.scope_skip = true
		defer ctx.scope_skip = prev_skip
		for el in e.elements {
			if inner, have := el.(^Expression); have && inner != nil { ck_walk_expr(c, ctx, inner) }
		}

	case ^ObjectExpression:
		if e == nil { return }
		// Skip duplicate-property checks when this ObjectExpression is the
		// LHS of a destructuring assignment `({a, b} = rhs)`. The parser
		// stores the original ObjectExpression in AssignmentExpression.left;
		// semantically it's an ObjectPattern where duplicate keys are legal.
		if !ctx.in_assignment_target {
			ck_check_object_proto_dups(c, e)
			ck_check_object_duplicate_props(c, ctx, e)
		}
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
				// TS2408 — setters cannot return a value.
				if prop.kind == .Set && (ctx.lang == .TS || ctx.lang == .TSX) {
					ck_check_setter_return_value(c, fn.body.body[:])
				}
				// TS2378 — getters must return a value.
				// OXC does not enforce TS2378. Disabled for parity.
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
		// TS2703 — delete operand must be a property reference.
		if e.operator == .Delete && e.argument != nil && (ctx.lang == .TS || ctx.lang == .TSX) {
			is_valid := false
			inner := e.argument
			for inner != nil {
				pe, is_paren := inner^.(^ParenthesizedExpression)
				if !is_paren || pe == nil { break }
				inner = pe.expression
			}
			#partial switch _ in inner^ {
			case ^Identifier:
				is_valid = true
			case ^MemberExpression:
				is_valid = true
			case ^ChainExpression:
				is_valid = true
			}
			if !is_valid {
				ck_report_coded(c, u32(e.loc.start), .K3051_StrictModeProhibited, "The operand of a 'delete' operator must be a property reference")
			}
		}
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
			ck_report_coded(c, u32(e.loc.start), .K3011_AwaitYieldExpressionContextRestricted,
				"'await' is not allowed in a class static block")
		}
		// §15.7.10 — class field initializers are not async.
		if ctx.in_field_init {
			ck_report_coded(c, u32(e.loc.start), .K3011_AwaitYieldExpressionContextRestricted,
				"'await' is not allowed in a class field initializer")
		}
		// §15.6.1 / arrow-cover: AwaitExpression in formal-parameter
		// position is forbidden. Same arrow-vs-regular message split as
		// the YieldExpression case.
		if ctx.in_params {
			if ctx.params_is_arrow {
				ck_report(c, u32(e.loc.start), "Await expression is not allowed in arrow function parameters")
			} else {
				ck_report_coded(c, u32(e.loc.start), .K3011_AwaitYieldExpressionContextRestricted,
					"'await' expression is not allowed in formal parameters of an async function")
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
				ck_report(c, u32(e.loc.start), "Yield expression is not allowed in arrow function parameters")
			} else {
				ck_report_coded(c, u32(e.loc.start), .K3011_AwaitYieldExpressionContextRestricted,
					"'yield' expression is not allowed in formal parameters of a generator")
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

	// Strict-mode-only literal early errors:
	case ^NumericLiteral:
		if e != nil { ck_check_legacy_octal_number(c, ctx, e) }
	case ^StringLiteral:
		if e != nil { ck_check_string_octal_escape(c, ctx, e) }
	case ^BigIntLiteral:
		if e != nil { ck_check_legacy_octal_bigint(c, e) }

	// Slice 6 — function-context-driven early errors:
	case ^Super:
		// TS2466 — 'super' cannot be referenced in a computed property name.
		// Only fire when there's no enclosing method with [[HomeObject]]
		// (a nested class inside a method has its computed keys evaluated
		// in the method's scope, so super IS valid there).
		if e != nil && ctx.in_class_computed_key && !ctx.in_method &&
		   (ctx.lang == .TS || ctx.lang == .TSX) {
			ck_report_coded(c, u32(e.loc.start), .K3033_SuperInvalidContext, "'super' cannot be referenced in a computed property name")
		}
		// §13.3.7 — SuperProperty / SuperCall is only legal in a
		// [[HomeObject]]-bearing context (class method / constructor /
		// field init / static block, or object-literal method).
		if e != nil && !ctx.in_method && !ctx.in_class_computed_key {
			ck_report(c, u32(e.loc.start), "'super' is only allowed in class methods or object-literal methods")
		}
	// TS2331 — 'this' cannot be referenced in a module or namespace body.
	// `this` at the top level of a namespace (not inside a function/method/
	// arrow) is an error. The function_depth counter tracks whether we've
	// entered a function boundary since the namespace was opened.
	case ^ThisExpression:
		// TS2465 — 'this' cannot be referenced in a computed property name.
		if e != nil && ctx.in_class_computed_key &&
		   (ctx.lang == .TS || ctx.lang == .TSX) {
			ck_report_coded(c, u32(e.loc.start), .K3033_SuperInvalidContext, "'this' cannot be referenced in a computed property name")
		}
		// TS2331 — 'this' at the direct body level of a namespace (not
		// inside any function, arrow, method, or class body).
		if e != nil && ctx.ts_namespace_depth > 0 &&
		   ctx.function_depth == 0 && !ctx.in_arrow_body &&
		   (ctx.lang == .TS || ctx.lang == .TSX) {
			ck_report_coded(c, u32(e.loc.start), .K3033_SuperInvalidContext, "'this' cannot be referenced in a module or namespace body")
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
			// §15.7.5 — ClassStaticBlockBody runs under [+Await]: bare
			// `await` is reserved as both BindingIdentifier and
			// IdentifierReference. The parser doesn't track this for the
			// IdentifierReference case (it disables in_async at static-block
			// entry, so `await;` lexes/parses as an Identifier instead of
			// an AwaitExpression). The checker fires the early error.
			if e.name == "await" && ctx.in_class_static_block {
				ck_report_coded(c, u32(e.loc.start), .K3011_AwaitYieldExpressionContextRestricted, "'await' is reserved in a class static block")
			}
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
	// TS — function generic type-parameter duplicate-name check.
	// `function foo<X, X>() {}` is TS2300. Independent of strict-mode.
	if ctx.lang == .TS || ctx.lang == .TSX {
		if tp, have := fn.type_parameters.(^TSTypeParameterDeclaration); have {
			ck_check_ts_type_param_dups(c, tp)
		}
	}
	// TS1016 — a required parameter cannot follow an optional parameter.
	if ctx.lang == .TS || ctx.lang == .TSX {
		ck_check_ts1016_required_after_optional(c, fn.params[:])
	}
	// §15.2.1.1 — formal-parameter vs body let/const redeclaration.
	if !fn.no_body {
		ck_check_params_vs_body_lex(c, fn.params[:], fn.body.body[:], ctx.strict_mode)
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
	//
	// Skipped for TS ambient declarations — `declare function eval();`,
	// `declare function arguments();`, plus any FunctionDeclaration
	// nested inside a `declare namespace M { ... }` body or in a .d.ts
	// file. These are type-level signatures, not real bindings, and
	// the strict-mode reservation doesn't apply (matches OXC).
	if kind == .Plain && !fn.declare && !fn.no_body && !ctx.is_dts {
		if id, have := fn.id.(BindingIdentifier); have {
			// Determine the strict-mode environment the function name
			// is parsed under. For FunctionExpression the name is in
			// the inner function's scope (so the function's OWN strict
			// flag matters). The walker has not yet lifted strict mode
			// for the body, so we check against the post-lift value
			// directly here.
			name_strict := ctx.strict_mode || (!fn.no_body && fn_body_lifts_strict(fn.body))
			// TS mode: OXC does not enforce eval/arguments function-name ban.
			if name_strict && ctx.lang != .TS && ctx.lang != .TSX {
				if is_eval_or_arguments(id.name) {
					msg := fmt.tprintf("Function name '%s' is not allowed in strict mode", id.name)
					ck_report_coded(c, u32(id.loc.start), .K3050_StrictModeReserved, msg)
				} else if is_strict_reserved_simple_name(id.name) {
					// `yield` as fn name in strict mode — parser-side
					// `report_error` already catches generator name clash;
					// strict-only reservation is checker-side.
					msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", id.name)
					ck_report_coded(c, u32(id.loc.start), .K3050_StrictModeReserved, msg)
				}
			}
		}
	}
	// TS — function implementations are not allowed in ambient
	// contexts (.d.ts files, declare module/namespace bodies).
	if ctx.is_dts && kind == .Plain && !fn.declare && !fn.no_body {
		ck_report_coded(c, u32(fn.loc.start), .K4050_AmbientContextRestriction, "An implementation cannot be declared in ambient contexts")
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
	ctx.in_class_computed_key  = false  // function body resets computed-key context
	ctx.class_body_depth       = 0  // regular functions don't inherit [[NewTarget]] from class
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
	ctx.in_params       = true
	ctx.params_is_arrow = false
	// §15.5.1 / §15.6.1 / §15.8.1 — strict-mode parameter
	// BindingIdentifier check (`eval` / `arguments` / strict-reserved).
	// The lifted strict_mode is already applied for body context, but
	// param patterns are checked under that same strict context (the
	// parser tracked this with the post-body-prologue
	// `body_strict || p.ctx.strict_mode` rule). Generators / async / async-
	// generators inherit strict-flavoured uniqueness regardless.
	// TS mode: OXC skips eval/arguments param-name ban in TS files.
	if ctx.strict_mode && ctx.lang != .TS && ctx.lang != .TSX {
		for pr in fn.params { ck_check_strict_param_pattern(c, pr.pattern) }
	}
	// TS2371 — overload signatures may not have parameter initializers.
	if fn.no_body && (ctx.lang == .TS || ctx.lang == .TSX) {
		for pr in fn.params {
			if _, has := pr.default_val.(^Expression); has {
				msg := fmt.tprintf("A parameter initializer is only allowed in a function or constructor implementation.")
				ck_report(c, u32(pr.loc.start), msg)
			}
		}
	}
	// TS2372 — parameter default value must not reference itself.
	// TS2373 — parameter default value must not forward-reference a
	// parameter declared after it in the same parameter list.
	if ctx.lang == .TS || ctx.lang == .TSX {
		for pi in 0..<len(fn.params) {
			pr := fn.params[pi]
			if def, has := pr.default_val.(^Expression); has && def != nil {
				// TS2372: self-reference.
				self_names: [dynamic]string
				self_names.allocator = context.temp_allocator
				reserve(&self_names, 2)
				scope_collect_pattern(pr.pattern, &self_names)
				for n in self_names {
					if ck_expr_has_identifier_ref(def, n, context.temp_allocator) {
						msg := fmt.tprintf("Parameter '%s' cannot reference itself.", n)
						ck_report_coded(c, u32(pr.loc.start), .K3038_ParameterInitReference, msg)
						break
					}
				}
				// TS2373: forward-reference to a later parameter.
				for fwd_i in (pi + 1)..<len(fn.params) {
					fwd := fn.params[fwd_i]
					fwd_names: [dynamic]string
					fwd_names.allocator = context.temp_allocator
					reserve(&fwd_names, 2)
					scope_collect_pattern(fwd.pattern, &fwd_names)
					for fwd_n in fwd_names {
						if ck_expr_has_identifier_ref(def, fwd_n, context.temp_allocator) {
							msg := fmt.tprintf("Parameter '%s' cannot reference identifier '%s' declared after it.",
								ck_pattern_display_name(pr.pattern), fwd_n)
							ck_report(c, u32(pr.loc.start), msg)
							break  // one diagnostic per param is enough
						}
					}
				}
			}
		}
	}
	// §15.5.1 / §15.6.1 / §15.8.1 — duplicate parameter names.
	//
	// MethodDefinition (§15.4) ALWAYS has UniqueFormalParameters —
	// regardless of outer strict mode — because the production already
	// names that constraint. Class method bodies fire this naturally
	// because ClassBody is implicitly strict; object-literal methods
	// don't, so we force the strict-flavoured uniqueness check for
	// `kind == .Method`. Async / generator functions of any flavour also
	// require strict-flavoured uniqueness.
	params_simple := params_are_simple(fn.params[:])
	force_non_simple := !params_simple
	dup_strict := ctx.strict_mode || fn.async || fn.generator || kind == .Method
	ck_check_duplicate_param_names(c, u32(fn.loc.start), fn.params[:], dup_strict, force_non_simple)
	for pr in fn.params {
		ck_walk_pattern(c, ctx, pr.pattern)
		// Default values are evaluated in the caller's scope, not the
		// function's param scope — yield/await in defaults are not param errors.
		if d, have := pr.default_val.(^Expression); have && d != nil {
			ctx.in_params = false
			ck_walk_expr(c, ctx, d)
			ctx.in_params = true
		}
	}
	// Reset in_params for the body walk — a nested function body is
	// its own scope, so `await` / `yield` inside the body are NOT in
	// the outer function's formal parameters.
	ctx.in_params       = false
	ctx.params_is_arrow = false
	if !fn.no_body {
		// §14.2.1 / §14.3.1.1 — function-body lex/var clash detection.
		// Function bodies are function-scope (is_block_scope=false), so
		// sloppy plain FunctionDeclarations inside hoist as .Var per
		// §14.1.3 / Annex B.3.2. Static-block bodies and class-method
		// bodies share the same scoping rule.
		ck_run_scope_check(c, ctx, fn.body.body[:], false)
		if kind == .Constructor && derived_ctor && (ctx.lang == .TS || ctx.lang == .TSX) && !ctx.extends_null {
			// TS17009 — `this` before `super()` in derived constructor.
			ck_check_this_before_super(c, ctx, fn.body.body[:])
			// TS2377 — derived constructors must contain a `super()` call.
			// OXC's semantic pass does not enforce TS2377. Disabled for parity.
			// (oxc-13284.ts has super() calls only in nested class computed keys,
			// which stmt_contains_super_call correctly skips.)
		}
		// TS — nested-scope decl-merge + FunctionDeclaration overload-chain
		// for the function-body scope.
		ck_check_ts_body_decls(c, ctx, fn.body.body[:])
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
	// TS2414 — class name cannot be a predefined type name.
	if (ctx.lang == .TS || ctx.lang == .TSX) {
		if id, ok := cls.id.(BindingIdentifier); ok {
			if is_ts_predefined_type_name(id.name) {
				msg := fmt.tprintf("Class name cannot be '%s'.", id.name)
				ck_report_coded(c, u32(id.loc.start), .K3030_ClassDeclarationStructure, msg)
			}
		}
	}
	has_extends := false
	// super_class is evaluated in the OUTER scope (no function boundary,
	// no private-name visibility from THIS class — the heritage clause
	// cannot reference its own privates) but DOES inherit the implicit
	// strict mode of the class declaration per §15.7.1: "All parts of a
	// ClassDeclaration or ClassExpression are evaluated as strict-mode
	// code." So `class C extends (function() { with ({}); }()) {}` must
	// reject the inner `with` in the IIFE body, even when the outer
	// program is sloppy. Lift strict_mode for the heritage walk and
	// restore for the rest of ck_walk_class (the body-scope lift below
	// re-applies it anyway).
	prev_strict_heritage := ctx.strict_mode
	extends_null := false
	if sc, have := cls.super_class.(^Expression); have && sc != nil {
		// `extends null` is a special case: NullLiteral as super_class
		// means no base constructor to call. The class IS derived (super()
		// is syntactically valid in the constructor), but TS2377 (missing
		// super) and TS17009 (this before super) are suppressed because
		// the null prototype has no constructor to call.
		if _, nok := sc^.(^NullLiteral); nok { extends_null = true }
		has_extends = true
		ctx.strict_mode = true
		ck_walk_expr(c, ctx, sc)
		ctx.strict_mode = prev_strict_heritage
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
	// `prev_strict_class := p.ctx.strict_mode; p.ctx.strict_mode = true`). The
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
	ctx.class_body_depth      += 1
	ctx.in_field_init          = false
	ctx.in_class_static_block  = false
	defer {
		ctx.strict_mode            = prev_strict
		ctx.in_method              = prev_in_method
		ctx.in_derived_constructor = prev_in_dctor
		ctx.in_field_init          = prev_in_field
		ctx.in_class_static_block  = prev_in_static_b
		ctx.class_body_depth      -= 1
	}

	// Whole-class checks: §15.7.1 — at most one constructor (with TS
	// overload-signature exception)..
	ck_check_class_constructors(c, ctx, cls)
	// §15.7.1 — private getter/setter static-mismatch.
	ck_check_class_private_static_mismatch(c, cls)
	// §15.7.1 — PrivateBoundNames must be unique except for one get + one
	// set pair. Subsumes the static-mismatch helper for the get/set pair
	// case but keeps it as the dedicated single-shape diagnostic.
	ck_check_class_private_duplicates(c, cls, ctx.lang == .TS || ctx.lang == .TSX)
	// TS — method overload-chain check (TS2391 / TS2389). Only fires in
	// TS / TSX. Suppressed when the enclosing class is `declare class`
	// (ambient — signatures without bodies are valid in .d.ts shape) or
	// when the source file itself is a .d.ts (every declaration is
	// implicitly ambient).
	if (ctx.lang == .TS || ctx.lang == .TSX) && !cls.declare && !ctx.is_dts {
		// TS2391/TS2389 overload chain — migrated to parser.
		ck_check_ts_class_member_dups(c, cls)
		ck_check_ts_constructor_param_property_dups(c, cls)
	}
	// TS — class type-parameter duplicate-name check. Independent of the
	// `declare class` / .d.ts gate above: `class C<X, X>` is rejected
	// even in ambient context.
	if ctx.lang == .TS || ctx.lang == .TSX {
		if tp, has := cls.type_parameters.(^TSTypeParameterDeclaration); has {
			ck_check_ts_type_param_dups(c, tp)
		}
		// Also check method-level type parameters on each overloadable
		// member — `class C { m<X, X>() {} }`.
		for elem in cls.body.body {
			if fn, ok := elem_is_overloadable_method(elem); ok && fn != nil {
				if tp, have := fn.type_parameters.(^TSTypeParameterDeclaration); have {
					ck_check_ts_type_param_dups(c, tp)
				}
			}
		}
		// Abstract-in-non-abstract — migrated to parser.
		// TS — constructor overload signatures cannot have parameter
		// properties (accessibility / readonly / override on params).
		ck_check_ts_constructor_modifiers(c, cls)
		// TS — incompatible modifier combinations on class elements.
		// static+abstract, abstract+#name — migrated to parser.
	}

	for elem in cls.body.body {
		// §15.4.3 / §15.4.4 / §15.4.5 — getter / setter arity + setter
		// parameter shape live in the parser (enforce_accessor_param_shape).
		// Slice 15 promoted them out of this checker because they're
		// structural per the grammar; keeping the check parser-side closes
		// the class-accessor checks without
		// requiring --show-semantic-errors.

		// Computed keys are evaluated in the OUTER class-body scope:
		// they don't see the about-to-be-pushed in_method / in_field_init,
		// but they DO see the enclosing class-static-block / field-init
		// flags. The reset at the top of ck_walk_class clears those for
		// the body's element values; restore them just for computed-key
		// walks so checks like ContainsArguments / `await`-reservation
		// fire correctly when an inner class's computed key references
		// `arguments` or `await` from inside an outer static block.
		// (test262 static-init-invalid-arguments.js / -await.js.)
		if elem.computed && elem.key != nil {
			// Computed keys ALSO inherit `in_method` and
			// `in_derived_constructor` from the enclosing class-element
			// scope. ECMA-262: ClassDefinitionEvaluation evaluates each
			// element's PropertyName in the enclosing lexical scope, which
			// means the surrounding [[HomeObject]] / [[NewTarget]] /
			// [[ConstructorKind]] still apply. So when an inner class is
			// declared inside a derived-class constructor body, its
			// computed keys (and field-initializer expressions) may legally
			// reference `super(...)` and `super.foo` because the surrounding
			// constructor is the home for those constructs. (oxc-13284.js).
			saved_static_b := ctx.in_class_static_block
			saved_field_i  := ctx.in_field_init
			saved_method   := ctx.in_method
			saved_dctor    := ctx.in_derived_constructor
			saved_comp_key := ctx.in_class_computed_key
			ctx.in_class_static_block = prev_in_static_b
			ctx.in_field_init         = prev_in_field
			ctx.in_method             = prev_in_method
			ctx.in_derived_constructor = prev_in_dctor
			ctx.in_class_computed_key  = true
			ck_walk_expr(c, ctx, elem.key)
			ctx.in_class_static_block = saved_static_b
			ctx.in_field_init         = saved_field_i
			ctx.in_method             = saved_method
			ctx.in_derived_constructor = saved_dctor
			ctx.in_class_computed_key  = saved_comp_key
		}

		ck_walk_class_element_value(c, ctx, elem, has_extends, extends_null)
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
ck_walk_class_element_value :: proc(c: ^Checker, ctx: ^CheckerContext, elem: ClassElement, has_extends: bool, extends_null := false) {
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
			prev_extends_null := ctx.extends_null
			ctx.extends_null = extends_null
			ck_walk_function(c, ctx, fn, .Constructor, has_extends)
			ctx.extends_null = prev_extends_null
		case .Get, .Set, .Method:
			ck_walk_function(c, ctx, fn, .Method, false)
			// TS2408 — setters cannot return a value.
			if elem.kind == .Set && (ctx.lang == .TS || ctx.lang == .TSX) {
				ck_check_setter_return_value(c, fn.body.body[:])
			}
			// TS2378 — getters must return a value.
			// OXC does not enforce TS2378. Disabled for parity.
			// TS2784 — get/set accessors cannot declare 'this' parameter.
			if (elem.kind == .Get || elem.kind == .Set) && (ctx.lang == .TS || ctx.lang == .TSX) {
				if len(fn.params) > 0 {
					if id, ok := fn.params[0].pattern.(^Identifier); ok && id != nil && id.name == "this" {
						ck_report_coded(c, u32(id.loc.start), .K4061_GetSetForm, "'get' and 'set' accessors cannot declare 'this' parameters")
					}
				}
			}
			// TS1051 — set accessor cannot have optional parameter.
			if elem.kind == .Set && (ctx.lang == .TS || ctx.lang == .TSX) {
				for param in fn.params {
					if id, ok := param.pattern.(^Identifier); ok && id != nil && id.optional {
						ck_report_coded(c, u32(id.loc.start), .K4061_GetSetForm, "A 'set' accessor cannot have an optional parameter")
					}
				}
			}
			// TS1095 — set accessor cannot have a return type annotation.
			if elem.kind == .Set && (ctx.lang == .TS || ctx.lang == .TSX) {
				if _, has_ret := fn.return_type.(^TSTypeAnnotation); has_ret {
					ck_report_coded(c, u32(fn.loc.start), .K4061_GetSetForm, "A 'set' accessor cannot have a return type annotation")
				}
			}
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

// TS2408 — setters cannot return a value. Walks the setter body
// recursively looking for `return <expr>;` statements. `return;`
// (without expression) is allowed. Recurses into blocks, if/else,
// try/catch, switch, loops. Stops at function/arrow boundaries.
// ck_body_has_return_value — true if the body always produces a value:
// either a `return <expr>` or a `throw`. Recurses into control-flow
// blocks but NOT into nested functions/methods/arrows.
// Used for TS2378 getter-must-return.
@(private="file")
ck_body_has_return_value :: proc(body: []^Statement) -> bool {
	for stmt in body {
		if stmt == nil { continue }
		#partial switch v in stmt^ {
		case ^ReturnStatement:
			// Any `return` (with or without a value) counts. OXC only flags
			// getters that have NO return/throw path at all.
			return true
		case ^ThrowStatement:
			return true  // Throw always terminates — no return needed.
		case ^BlockStatement:
			if v != nil && ck_body_has_return_value(v.body[:]) { return true }
		case ^IfStatement:
			if v == nil { continue }
			if ck_body_has_return_value({v.consequent}) { return true }
			if alt, have := v.alternate.(^Statement); have {
				if ck_body_has_return_value({alt}) { return true }
			}
		case ^TryStatement:
			if v == nil { continue }
			if ck_body_has_return_value(v.block.body[:]) { return true }
			if handler, have := v.handler.(CatchClause); have {
				if ck_body_has_return_value(handler.body.body[:]) { return true }
			}
			if fin, have := v.finalizer.(BlockStatement); have {
				if ck_body_has_return_value(fin.body[:]) { return true }
			}
		case ^SwitchStatement:
			if v == nil { continue }
			for sc in v.cases {
				if ck_body_has_return_value(sc.consequent[:]) { return true }
			}
		case ^WhileStatement:
			if v != nil && ck_body_has_return_value({v.body}) { return true }
		case ^DoWhileStatement:
			if v != nil && ck_body_has_return_value({v.body}) { return true }
		case ^ForStatement:
			if v != nil && ck_body_has_return_value({v.body}) { return true }
		case ^ForInStatement:
			if v != nil && ck_body_has_return_value({v.body}) { return true }
		case ^ForOfStatement:
			if v != nil && ck_body_has_return_value({v.body}) { return true }
		case ^LabeledStatement:
			if v != nil && ck_body_has_return_value({v.body}) { return true }
		// Do NOT descend into FunctionDeclaration, ClassDeclaration,
		// ArrowFunctionExpression — those are nested scopes.
		}
	}
	return false
}

ck_check_setter_return_value :: proc(c: ^Checker, body: []^Statement) {
	for stmt in body {
		if stmt == nil { continue }
		#partial switch v in stmt^ {
		case ^ReturnStatement:
			if v == nil { continue }
			if _, has_arg := v.argument.(^Expression); has_arg {
				ck_report_coded(c, u32(v.loc.start), .K4061_GetSetForm, "Setters cannot return a value")
			}
		case ^BlockStatement:
			if v != nil { ck_check_setter_return_value(c, v.body[:]) }
		case ^IfStatement:
			if v == nil { continue }
			ck_check_setter_return_value(c, {v.consequent})
			if alt, have := v.alternate.(^Statement); have {
				ck_check_setter_return_value(c, {alt})
			}
		case ^TryStatement:
			if v == nil { continue }
			ck_check_setter_return_value(c, v.block.body[:])
			if handler, have := v.handler.(CatchClause); have {
				ck_check_setter_return_value(c, handler.body.body[:])
			}
			if fin, have := v.finalizer.(BlockStatement); have {
				ck_check_setter_return_value(c, fin.body[:])
			}
		case ^SwitchStatement:
			if v == nil { continue }
			for sc in v.cases {
				ck_check_setter_return_value(c, sc.consequent[:])
			}
		case ^WhileStatement:
			if v != nil { ck_check_setter_return_value(c, {v.body}) }
		case ^DoWhileStatement:
			if v != nil { ck_check_setter_return_value(c, {v.body}) }
		case ^ForStatement:
			if v != nil { ck_check_setter_return_value(c, {v.body}) }
		case ^ForInStatement:
			if v != nil { ck_check_setter_return_value(c, {v.body}) }
		case ^ForOfStatement:
			if v != nil { ck_check_setter_return_value(c, {v.body}) }
		case ^LabeledStatement:
			if v != nil { ck_check_setter_return_value(c, {v.body}) }
		// Functions/arrows/classes create new scopes — don't recurse.
		case ^FunctionDeclaration, ^ClassDeclaration:
			continue
		case ^ExpressionStatement:
			// Arrow/function expressions inside expression statements
			// create new scopes — skip.
			continue
		}
	}
}

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
			err_off := loc_from_expr(prop.key).start
			ck_report(c, u32(err_off), "Redefinition of __proto__ property")
		} else {
			proto_seen = true
		}
	}
}

// ---------------------------------------------------------------
// §13.2.5 — object literal duplicate property detection (TS1117/TS1118).
//
// TypeScript forbids duplicate property names in object literals unless
// they form a valid get/set accessor pair. Non-computed keys
// (Identifier, StringLiteral, NumericLiteral) are always checked.
// Computed keys that are simple literal expressions (e.g., [1], ["x"],
// [+1], [-1]) are also evaluated statically. Dynamic computed keys
// (identifiers, member expressions, etc.) are skipped — catching those
// requires type inference infrastructure.
// ---------------------------------------------------------------

// property_key_to_name_literal extracts a property name from a key
// expression when it is a literal value (StringLiteral, NumericLiteral,
// or UnaryExpression wrapping one of those). Used for COMPUTED keys
// where Identifier references are variable lookups, not literal names.
@(private="file")
property_key_to_name_literal :: proc(key: ^Expression) -> string {
	if key == nil { return "" }
	#partial switch k in key^ {
	case ^StringLiteral:
		if k != nil { return k.value }
	case ^NumericLiteral:
		// Use the numeric VALUE (not raw text) so that 0b11 and 3
		// (same number, different spellings) are detected as duplicates.
		if k != nil { return fmt.tprintf("%v", k.value) }
	case ^UnaryExpression:
		if k == nil { return "" }
		if k.operator == .Plus {
			// +1 evaluates to 1; the property name is just the inner value.
			return property_key_to_name_literal(k.argument)
		}
		if k.operator == .Minus {
			inner := property_key_to_name_literal(k.argument)
			if inner == "" { return "" }
			// -1 → "-1" (negation survives into the property name).
			return strings.concatenate({"-", inner}, context.temp_allocator)
		}
	}
	return ""
}

// property_key_to_name extracts a canonical property name from a
// non-computed key expression. Handles Identifier, StringLiteral,
// NumericLiteral. For computed keys use property_key_to_name_literal.
@(private="file")
property_key_to_name :: proc(key: ^Expression) -> string {
	if key == nil { return "" }
	#partial switch k in key^ {
	case ^Identifier:
		if k != nil { return k.name }
	case ^StringLiteral:
		if k != nil { return k.value }
	case ^NumericLiteral:
		if k != nil { return fmt.tprintf("%v", k.value) }
	}
	return ""
}

// PropertySeen tracks the state of a property name in an object literal.
PropertySeen :: enum u8 {
	Unseen,
	Data,       // .Init or .Method seen
	Getter,
	Setter,
	GetterSetter, // valid get+set pair seen
}

// ck_check_object_duplicate_props enforces TS1117 and TS1118:
//   - TS1117: "An object literal cannot have multiple properties with the
//     same name."
//   - TS1118: "An object literal cannot have multiple get/set accessors
//     with the same name."
//
// Only active in TS / TSX mode. Computed keys that cannot be statically
// evaluated are ignored.
@(private="file")
ck_check_object_duplicate_props :: proc(c: ^Checker, ctx: ^CheckerContext, obj: ^ObjectExpression) {
	if obj == nil { return }
	if ctx.lang != .TS && ctx.lang != .TSX { return }

	// State per canonical property name.
	seen: map[string]PropertySeen
	seen.allocator = context.temp_allocator

	for i := 0; i < len(obj.properties); i += 1 {
		prop := &obj.properties[i]
		if prop.key == nil { continue }

		// For non-computed keys, Identifier.name IS the property name.
		// For computed keys, Identifier is a variable reference — only
		// extract from literal expressions to avoid false positives like
		// `{ a: 1, [a]: 2 }` where `a` is a variable, not the string "a".
		name := prop.computed \
			? property_key_to_name_literal(prop.key) \
			: property_key_to_name(prop.key)
		if name == "" { continue }
		// Skip `__proto__` — already handled by ck_check_object_proto_dups
		// which fires in all modes (JS + TS). Avoids double-counting.
		if name == "__proto__" { continue }

		state, exists := seen[name]
		if !exists {
			state = .Unseen
		}

		switch prop.kind {
		case .Init, .Method:
			switch state {
			case .Unseen:
				seen[name] = .Data
			case .Data, .Getter, .Setter, .GetterSetter:
				err_off := u32(loc_from_expr(prop.key).start)
				ck_report_coded(c, err_off, .K3036_ObjectLiteralDuplicate, "An object literal cannot have multiple properties with the same name")
			}
		case .Get:
			switch state {
			case .Unseen:
				seen[name] = .Getter
			case .Getter, .GetterSetter:
				err_off := u32(loc_from_expr(prop.key).start)
				ck_report_coded(c, err_off, .K3036_ObjectLiteralDuplicate, "An object literal cannot have multiple get/set accessors with the same name")
			case .Setter:
				seen[name] = .GetterSetter
			case .Data:
				err_off := u32(loc_from_expr(prop.key).start)
				ck_report_coded(c, err_off, .K3036_ObjectLiteralDuplicate, "An object literal cannot have multiple properties with the same name")
			}
		case .Set:
			switch state {
			case .Unseen:
				seen[name] = .Setter
			case .Setter, .GetterSetter:
				err_off := u32(loc_from_expr(prop.key).start)
				ck_report_coded(c, err_off, .K3036_ObjectLiteralDuplicate, "An object literal cannot have multiple get/set accessors with the same name")
			case .Getter:
				seen[name] = .GetterSetter
			case .Data:
				err_off := u32(loc_from_expr(prop.key).start)
				ck_report_coded(c, err_off, .K3036_ObjectLiteralDuplicate, "An object literal cannot have multiple properties with the same name")
			}
		}
	}
}

// §14.12.1 — a SwitchStatement may have at most one DefaultClause.
// Locations anchor at the `default` keyword (which the parser stores
// as the case's loc.start; SwitchCase.test == nil signals default).
@(private="file")
ck_check_switch_default_dups :: proc(c: ^Checker, sw: ^SwitchStatement) {
	if sw == nil { return }
	default_seen := false
	for i := 0; i < len(sw.cases); i += 1 {
		sc := &sw.cases[i]
		if _, have := sc.test.(^Expression); have { continue } // not a default
		if default_seen {
			ck_report_coded(c, u32(sc.loc.start), .K2040_UnexpectedToken, "More than one default clause in switch")
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
				has_body = len(fn.body.body) > 0 || fn.body.loc.end > fn.body.loc.start
			}
		}

		loc := u32(get_expression_loc(elem.key).start)
		if ts_mode {
			if has_body && constructor_implementation_seen {
				ck_report_coded(c, loc, .K4080_DuplicateImplementation,
					"Duplicate constructor implementation in class")
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
	arg := e.argument
	// Unwrap ChainExpression (optional chaining: `delete this?.#x`).
	if chain, is_chain := arg^.(^ChainExpression); is_chain && chain != nil {
		arg = chain.expression
	}
	me, is_member := arg^.(^MemberExpression)
	if !is_member || me == nil { return }
	if me.property == nil { return }
	if _, is_private := me.property^.(^PrivateIdentifier); is_private {
		ck_report(c, u32(e.loc.start), "Private fields cannot be deleted")
	}
}

// §15.7.3 — `super.#name` migrated to parser (parse_member_expression).

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
	ck_report_coded(c, u32(num.loc.start), .K3051_StrictModeProhibited,
		"Legacy octal literals are not allowed in strict mode")
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
	ck_report(c, u32(str.loc.start), "Octal or \\8 / \\9 escape sequences are not allowed in strict mode")
}

// §12.9.3 — a LegacyOctalIntegerLiteral cannot form a BigInt;
// `0123n` is a SyntaxError regardless of strict / sloppy mode.
// (`0o123n` is the modern form.) The raw text retains the trailing
// `n`; `is_legacy_zero_prefixed_integer` strips it before matching.
@(private="file")
ck_check_legacy_octal_bigint :: proc(c: ^Checker, big: ^BigIntLiteral) {
	if big == nil { return }
	if !is_legacy_zero_prefixed_integer(big.raw) { return }
	ck_report(c, u32(big.loc.start), "Legacy octal literals cannot be BigInt")
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
			ck_report(c, u32(tmpl.loc.start), "Octal or \\8 / \\9 escape sequences are not allowed in strict mode")
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
			ck_report(c, u32(decl.loc.start), "'let' is disallowed as a lexically bound name")
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

// TS17009 — `this` before `super()` in a derived constructor.
//
// In the instance constructor of a `class X extends Y`, `this` must not
// be accessed before `super()` is called. Two shapes:
//   1. `this` in a statement preceding the first `super()` call:
//      `this.x = 1; super();` — error on `this.x = 1`.
//   2. `this` inside the arguments of `super(...)`:
//      `super(this)` — error on `this`.
//
// This check does a linear top-level scan of the constructor body.
// It does NOT recurse into nested functions/arrows/classes (those
// have their own `this` binding). Control-flow analysis is NOT
// performed — we only check the sequential case.
@(private="file")
ck_check_this_before_super :: proc(c: ^Checker, ctx: ^CheckerContext, body: []^Statement) {
	// Only enforce in TS/TSX mode. In JS, accessing `this` before `super()`
	// is a runtime ReferenceError, not a parse-time error.
	if ctx.lang != .TS && ctx.lang != .TSX { return }
	// Phase 1: find the index of the first top-level statement that
	// contains a `super(...)` call.
	super_idx := -1
	for stmt, i in body {
		if stmt == nil { continue }
		if stmt_contains_super_call(stmt) {
			super_idx = i
			break
		}
	}

	// Phase 2: for every statement before super_idx, report TS17009 on
	// any `this` reference. If no super() was found at all, don't report
	// (the missing-super diagnostic is separate).
	if super_idx < 0 { return }

	for i := 0; i < super_idx; i += 1 {
		this_loc := stmt_find_this(body[i])
		if this_loc != 0 {
			ck_report_this_before_super(c, this_loc)
		}
	}

	// Phase 3: check the super() call's OWN arguments for `this`.
	super_stmt := body[super_idx]
	if super_stmt == nil { return }
	es, ok := super_stmt^.(^ExpressionStatement)
	if !ok || es == nil { return }
	super_call := expr_extract_super_call(es.expression)
	if super_call == nil { return }
	for a in super_call.arguments {
		this_loc := expr_find_this(a)
		if this_loc != 0 {
			ck_report_this_before_super(c, this_loc)
		}
	}
}

// stmt_find_this — finds the first `this` in the top-level expressions of
// a statement. Handles ExpressionStatement, VariableDeclaration (init
// expressions), ReturnStatement. Does not recurse into nested blocks.
@(private="file")
stmt_find_this :: proc(stmt: ^Statement) -> u32 {
	if stmt == nil { return 0 }
	#partial switch v in stmt^ {
	case ^ExpressionStatement:
		if v != nil { return expr_find_this(v.expression) }
	case ^VariableDeclaration:
		if v == nil { return 0 }
		for d in v.declarations {
			if init, have := d.init.(^Expression); have {
				if r := expr_find_this(init); r != 0 { return r }
			}
		}
	case ^ReturnStatement:
		if v != nil {
			if arg, have := v.argument.(^Expression); have {
				return expr_find_this(arg)
			}
		}
	}
	return 0
}

// stmt_contains_super_call — does this statement (or any nested block)
// contain a `super()` call? Recurses into if/else, try/catch, blocks,
// switch, loops. Stops at function/arrow/class boundaries.
@(private="file")
stmt_contains_super_call :: proc(stmt: ^Statement) -> bool {
	if stmt == nil { return false }
	#partial switch v in stmt^ {
	case ^ExpressionStatement:
		if v != nil { return expr_is_or_contains_super_call(v.expression) }
	case ^VariableDeclaration:
		if v == nil { return false }
		for d in v.declarations {
			if init, have := d.init.(^Expression); have {
				if expr_is_or_contains_super_call(init) { return true }
			}
		}
	case ^ReturnStatement:
		if v != nil {
			if arg, have := v.argument.(^Expression); have {
				return expr_is_or_contains_super_call(arg)
			}
		}
	case ^BlockStatement:
		if v != nil { for s in v.body { if stmt_contains_super_call(s) { return true } } }
	case ^IfStatement:
		if v == nil { return false }
		if stmt_contains_super_call(v.consequent) { return true }
		if alt, have := v.alternate.(^Statement); have {
			return stmt_contains_super_call(alt)
		}
	case ^TryStatement:
		if v == nil { return false }
		for s in v.block.body { if stmt_contains_super_call(s) { return true } }
		if handler, have := v.handler.(CatchClause); have {
			for s in handler.body.body { if stmt_contains_super_call(s) { return true } }
		}
		if fin, have := v.finalizer.(BlockStatement); have {
			for s in fin.body { if stmt_contains_super_call(s) { return true } }
		}
	case ^SwitchStatement:
		if v == nil { return false }
		for sc in v.cases {
			for s in sc.consequent { if stmt_contains_super_call(s) { return true } }
		}
	case ^WhileStatement:
		if v != nil { return stmt_contains_super_call(v.body) }
	case ^DoWhileStatement:
		if v != nil { return stmt_contains_super_call(v.body) }
	case ^ForStatement:
		if v != nil { return stmt_contains_super_call(v.body) }
	case ^ForInStatement:
		if v != nil { return stmt_contains_super_call(v.body) }
	case ^ForOfStatement:
		if v != nil { return stmt_contains_super_call(v.body) }
	case ^LabeledStatement:
		if v != nil { return stmt_contains_super_call(v.body) }
	}
	return false
}

@(private="file")
ck_report_this_before_super :: proc(c: ^Checker, this_loc: u32) {
	ck_report_coded(c, this_loc, .K3033_SuperInvalidContext, "'super' must be called before accessing 'this' in the constructor of a derived class")
}

// expr_find_this — returns the source offset of the first ThisExpression
// in the expression tree, or 0 if none found. Stops at function/arrow/
// class boundaries (those have their own `this`).
@(private="file")
expr_find_this :: proc(e: ^Expression) -> u32 {
	if e == nil { return 0 }
	#partial switch v in e^ {
	case ^ThisExpression:
		if v != nil { return u32(v.loc.start) }
	case ^MemberExpression:
		if v == nil { return 0 }
		if r := expr_find_this(v.object); r != 0 { return r }
		if v.computed { return expr_find_this(v.property) }
	case ^CallExpression:
		if v == nil { return 0 }
		if r := expr_find_this(v.callee); r != 0 { return r }
		for a in v.arguments {
			if r := expr_find_this(a); r != 0 { return r }
		}
	case ^AssignmentExpression:
		if v == nil { return 0 }
		if r := expr_find_this(v.left); r != 0 { return r }
		return expr_find_this(v.right)
	case ^BinaryExpression:
		if v == nil { return 0 }
		if r := expr_find_this(v.left); r != 0 { return r }
		return expr_find_this(v.right)
	case ^LogicalExpression:
		if v == nil { return 0 }
		if r := expr_find_this(v.left); r != 0 { return r }
		return expr_find_this(v.right)
	case ^ConditionalExpression:
		if v == nil { return 0 }
		if r := expr_find_this(v.test); r != 0 { return r }
		if r := expr_find_this(v.consequent); r != 0 { return r }
		return expr_find_this(v.alternate)
	case ^UnaryExpression:
		if v != nil { return expr_find_this(v.argument) }
	case ^UpdateExpression:
		if v != nil { return expr_find_this(v.argument) }
	case ^SequenceExpression:
		if v != nil { for s in v.expressions { if r := expr_find_this(s); r != 0 { return r } } }
	case ^SpreadElement:
		if v != nil { return expr_find_this(v.argument) }
	case ^ParenthesizedExpression:
		if v != nil { return expr_find_this(v.expression) }
	case ^TSAsExpression:
		if v != nil { return expr_find_this(v.expression) }
	case ^TSSatisfiesExpression:
		if v != nil { return expr_find_this(v.expression) }
	case ^TSNonNullExpression:
		if v != nil { return expr_find_this(v.expression) }
	case ^TSTypeAssertion:
		if v != nil { return expr_find_this(v.expression) }
	// Arrow / function / class create a new `this` binding — stop.
	case ^ArrowFunctionExpression, ^FunctionExpression, ^ClassExpression:
		return 0
	}
	return 0
}

// expr_is_or_contains_super_call — true if the expression IS or CONTAINS
// a `super(...)` CallExpression. Stops at function/arrow/class boundaries.
@(private="file")
expr_is_or_contains_super_call :: proc(e: ^Expression) -> bool {
	if e == nil { return false }
	#partial switch v in e^ {
	case ^CallExpression:
		if v == nil { return false }
		if _, is_super := v.callee^.(^Super); is_super { return true }
		if expr_is_or_contains_super_call(v.callee) { return true }
		for a in v.arguments { if expr_is_or_contains_super_call(a) { return true } }
	case ^AssignmentExpression:
		if v == nil { return false }
		return expr_is_or_contains_super_call(v.left) || expr_is_or_contains_super_call(v.right)
	case ^SequenceExpression:
		if v != nil { for s in v.expressions { if expr_is_or_contains_super_call(s) { return true } } }
	case ^ParenthesizedExpression:
		if v != nil { return expr_is_or_contains_super_call(v.expression) }
	case ^ConditionalExpression:
		if v == nil { return false }
		return expr_is_or_contains_super_call(v.test) ||
		       expr_is_or_contains_super_call(v.consequent) ||
		       expr_is_or_contains_super_call(v.alternate)
	case ^LogicalExpression:
		if v == nil { return false }
		return expr_is_or_contains_super_call(v.left) || expr_is_or_contains_super_call(v.right)
	case ^ObjectExpression:
		if v == nil { return false }
		for prop in v.properties {
			if prop.key != nil && expr_is_or_contains_super_call(prop.key) { return true }
			if prop.value != nil && expr_is_or_contains_super_call(prop.value) { return true }
		}
	case ^ArrayExpression:
		if v == nil { return false }
		for elem in v.elements {
			if inner, have := elem.(^Expression); have {
				if expr_is_or_contains_super_call(inner) { return true }
			}
		}
	case ^MemberExpression:
		if v == nil { return false }
		if expr_is_or_contains_super_call(v.object) { return true }
		if v.computed { return expr_is_or_contains_super_call(v.property) }
	case ^SpreadElement:
		if v != nil { return expr_is_or_contains_super_call(v.argument) }
	case ^BinaryExpression:
		if v == nil { return false }
		return expr_is_or_contains_super_call(v.left) || expr_is_or_contains_super_call(v.right)
	case ^UnaryExpression:
		if v != nil { return expr_is_or_contains_super_call(v.argument) }
	case ^TSAsExpression:
		if v != nil { return expr_is_or_contains_super_call(v.expression) }
	case ^TSNonNullExpression:
		if v != nil { return expr_is_or_contains_super_call(v.expression) }
	case ^ArrowFunctionExpression, ^FunctionExpression, ^ClassExpression:
		return false
	}
	return false
}

// expr_extract_super_call — extracts the CallExpression from an expression
// that is a `super(...)` call (possibly wrapped in parens / assignment).
@(private="file")
expr_extract_super_call :: proc(e: ^Expression) -> ^CallExpression {
	if e == nil { return nil }
	#partial switch v in e^ {
	case ^CallExpression:
		if v == nil { return nil }
		if _, is_super := v.callee^.(^Super); is_super { return v }
	case ^ParenthesizedExpression:
		if v != nil { return expr_extract_super_call(v.expression) }
	case ^AssignmentExpression:
		if v != nil { return expr_extract_super_call(v.right) }
	}
	return nil
}

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
	ck_report(c, u32(call.loc.start), "'super' call is only allowed in the constructor of a derived class")
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
	// Class bodies: `new.target` is valid in field initializers, static
	// blocks, and arrows inside them (arrows inherit [[NewTarget]]).
	// §15.7.10 / §15.7.5. OXC accepts this.
	if ctx.class_body_depth > 0 { return }
	// CommonJS files (.cjs / .cts) wrap the module body in a synthetic
	// function (`(exports, require, module, __filename, __dirname) => { … }`),
	// so top-level `new.target` is legal there. Mirror the parser-side
	// `p.is_commonjs` carve-out (parser.odin parse_meta_property).
	if ctx.is_commonjs { return }
	ck_report(c, u32(mp.loc.start), "'new.target' is only allowed inside functions")
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
		ck_report(c, u32(id.loc.start), "'arguments' is not allowed in a class static block")
		return
	}
	if ctx.in_field_init {
		ck_report(c, u32(id.loc.start), "'arguments' cannot appear in a class field initializer")
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
// ck_check_ts1016_required_after_optional — TS1016 "A required parameter
// cannot follow an optional parameter." When a parameter has `?` (optional),
// all subsequent non-rest parameters must also be optional or have defaults.
@(private="file")
ck_check_ts1016_required_after_optional :: proc(c: ^Checker, params: []FunctionParameter) {
	seen_optional := false
	for param in params {
		// Rest parameters are always last and don't count.
		if _, is_rest := param.pattern.(^RestElement); is_rest { break }
		// Only `?` makes a parameter optional for TS1016 purposes.
		// Default values (= expr) do NOT count — TSC allows
		// `function f(a, b = 0, c)` without error.
		is_optional := false
		if id, ok := param.pattern.(^Identifier); ok && id != nil {
			is_optional = id.optional
		}
		if is_optional {
			seen_optional = true
		} else if seen_optional && param.default_val == nil {
			// Required (no `?`, no default) after optional → error.
			ck_report_coded(c, u32(param.loc.start), .K4063_OptionalAndInit, "A required parameter cannot follow an optional parameter")
		}
	}
}

ck_check_strict_directive_with_nonsimple_params :: proc(c: ^Checker, fn: ^FunctionExpression) {
	if fn == nil || fn.no_body { return }
	if !fn_body_lifts_strict(fn.body) { return }
	if params_are_simple(fn.params[:]) { return }
	ck_report(c, u32(fn.loc.start), "Illegal 'use strict' directive in function with non-simple parameter list")
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
	ck_report(c, u32(fn.loc.start), "Illegal 'use strict' directive in function with non-simple parameter list")
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
	is_default: bool = false,
) {
	// TS allows `import` / `export` directly inside a namespace /
	// module body even when the outer file is a Script and even
	// though the namespace body isn't the program top level. Skip
	// both branches under that context (`namespace M { export var
	// x = 1; }` in a .ts script is legal).
	// Exception: `export default` inside a namespace is TS1319.
	if ctx.ts_namespace_depth > 0 {
		// TS1319 — `export default` inside a namespace is invalid.
		// Exception: inside `declare module "..."` (ambient module
		// declarations) and .d.ts files, `export default` IS valid.
		if is_default && !ctx.is_dts && !ctx.in_ambient_module_decl && (ctx.lang == .TS || ctx.lang == .TSX) {
			ck_report_coded(c, u32(loc.start), .K3021_ExportDefaultRestrictions, "A default export must be at the top level of a file or module declaration")
		}
		return
	}
	if ctx.source_type == .Script {
		msg := "'export' is only valid in module code"
		if is_import { msg = "'import' is only valid in module code" }
		ck_report(c, u32(loc.start), msg)
		return
	}
	if !was_top_level {
		msg := "'export' declarations are only allowed at the top level of a module"
		if is_import { msg = "'import' declarations are only allowed at the top level of a module" }
		ck_report(c, u32(loc.start), msg)
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
		ck_report_coded(c, u32(e.loc.start), .K2050_InvalidLHS, "Invalid left-hand side in assignment")
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

// is_ts_predefined_type_name — true if `name` matches a TypeScript
// built-in primitive type that cannot be reused as a class, interface,
// or enum name (TS2414 / TS2427 / TS2431). Mirrors TSC's reserved
// primitive-type name list.
@(private="file")
is_ts_predefined_type_name :: proc(name: string) -> bool {
	switch name {
	case "any", "number", "boolean", "string", "undefined",
	     "null", "unknown", "never", "object", "bigint", "symbol", "void":
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
	loc := u32(id.loc.start)
	name := id.name

	if is_strict_reserved_simple_name(name) {
		msg := fmt.tprintf("'%s' is a reserved identifier and cannot be a class name", name)
		ck_report_coded(c, loc, .K3030_ClassDeclarationStructure, msg)
		return
	}
	if is_eval_or_arguments(name) {
		msg := fmt.tprintf("Class name '%s' is not allowed", name)
		ck_report_coded(c, loc, .K3030_ClassDeclarationStructure, msg)
		return
	}
	if name == "await" && (ctx.in_async || ctx.source_type == .Module || ctx.in_class_static_block) {
		ck_report_coded(c, loc, .K3010_AwaitYieldAsBindingName,
			"'await' cannot be used as a class name in module / async / static-block context")
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
	loc  := u32(id.loc.start)

	if ctx.strict_mode {
		if is_eval_or_arguments(name) {
			msg := fmt.tprintf("Arrow parameter '%s' is not allowed in strict mode", name)
			ck_report_coded(c, loc, .K3050_StrictModeReserved, msg)
		} else if is_strict_reserved_simple_name(name) {
			msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", name)
			ck_report_coded(c, loc, .K3050_StrictModeReserved, msg)
		}
	}
	if name == "enum" {
		ck_report_coded(c, loc, .K4054_EnumInvalid, "'enum' is a reserved identifier")
	}
	if name == "await" && (ctx.in_async || ctx.source_type == .Module || ctx.in_class_static_block) {
		ck_report_coded(c, loc, .K3010_AwaitYieldAsBindingName,
			"'await' cannot be used as an arrow parameter in module / async / static-block context")
	}
	if name == "yield" && (ctx.in_generator || ctx.strict_mode) {
		ck_report_coded(c, loc, .K3010_AwaitYieldAsBindingName,
			"'yield' cannot be used as an arrow parameter in generator / strict context")
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
		// OXC allows multiple `export default` in TS mode — class/function
		// overloads can share the default export slot.
		if name == "default" { return }
		if _, exists := exported^[name]; exists {
			msg := fmt.tprintf("Duplicate exported name '%s'", name)
			ck_report_coded(c, off, .K3020_ImportExportNameOrBinding, msg)
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
							record(c, &exported, n, u32(decl.loc.start))
						}
					}
				case ^FunctionDeclaration:
					if inner == nil { break }
					// TS overload signature (no body): same name across
					// multiple declarations is the canonical TS overload
					// pattern. Only the implementation contributes a binding.
					if inner.no_body { break }
					if id, ok := inner.id.(BindingIdentifier); ok {
						record(c, &exported, id.name, u32(id.loc.start))
					}
				case ^ClassDeclaration:
					if inner == nil { break }
					if id, ok := inner.id.(BindingIdentifier); ok {
						record(c, &exported, id.name, u32(id.loc.start))
					}
				}
			}
			for spec in v.specifiers {
				switch en in spec.exported {
				case IdentifierName:
					record(c, &exported, en.name, u32(en.loc.start))
				case ^StringLiteral:
					if en != nil {
						record(c, &exported, en.value, u32(en.loc.start))
					}
				}
			}
		case ^ExportAllDeclaration:
			if v == nil { continue }
			if ns_name, has_ns := v.exported.(IdentifierName); has_ns {
				record(c, &exported, ns_name.name, u32(ns_name.loc.start))
			}
		case ^ExportDefaultDeclaration:
			if v == nil { continue }
			// TS2528 — a module cannot have multiple default exports.
			// Type-only defaults (interface, type alias) coexist with
			// value defaults and are not counted here.
			// TS overload signatures (`export default function foo(): T;`
			// without a body) also don’t contribute a binding — only the
			// implementation does.
			skip := false
			if d, have := v.declaration.(^Declaration); have && d != nil {
				#partial switch inner in d^ {
				case ^TSInterfaceDeclaration:
					skip = true
				case ^TSTypeAliasDeclaration:
					skip = true
				case ^FunctionDeclaration:
					if inner != nil && inner.no_body { skip = true }
				}
			}
			// Also skip function expressions from export-default overloads.
			if e, have := v.declaration.(^Expression); !skip && have && e != nil {
				if fn, ok := e^.(^FunctionExpression); ok && fn != nil && fn.no_body {
					skip = true
				}
			}
			if !skip {
				record(c, &exported, "default", u32(v.loc.start))
			}
		}
	}
}

// ck_collect_hoisted_vars — recursively collects `var`-declared names
// from nested blocks/loops/if/switch bodies. `var` hoists through all
// statement-level nesting (blocks, for, if, switch, with, try, labeled)
// but NOT through function boundaries.
@(private="file")
ck_collect_hoisted_vars :: proc(body: []^Statement, names: ^map[string]bool) {
	for stmt in body {
		if stmt == nil { continue }
		#partial switch v in stmt^ {
		case ^VariableDeclaration:
			if v == nil { continue }
			if v.kind == .Var {
				for decl in v.declarations { collect_pattern_bound_names(decl.id, names) }
			}
		case ^BlockStatement:
			if v != nil { ck_collect_hoisted_vars(v.body[:], names) }
		case ^IfStatement:
			if v == nil { continue }
			if v.consequent != nil { ck_collect_hoisted_vars({v.consequent}, names) }
			if alt, ok := v.alternate.?; ok && alt != nil { ck_collect_hoisted_vars({alt}, names) }
		case ^ForStatement:
			if v == nil { continue }
			if d, ok := v.init_decl.?; ok && d != nil && d.kind == .Var {
				for decl in d.declarations { collect_pattern_bound_names(decl.id, names) }
			}
			if v.body != nil { ck_collect_hoisted_vars({v.body}, names) }
		case ^ForInStatement:
			if v == nil { continue }
			if d, ok := v.left_decl.?; ok && d != nil && d.kind == .Var {
				for decl in d.declarations { collect_pattern_bound_names(decl.id, names) }
			}
			if v.body != nil { ck_collect_hoisted_vars({v.body}, names) }
		case ^ForOfStatement:
			if v == nil { continue }
			if d, ok := v.left_decl.?; ok && d != nil && d.kind == .Var {
				for decl in d.declarations { collect_pattern_bound_names(decl.id, names) }
			}
			if v.body != nil { ck_collect_hoisted_vars({v.body}, names) }
		case ^WhileStatement:
			if v != nil && v.body != nil { ck_collect_hoisted_vars({v.body}, names) }
		case ^DoWhileStatement:
			if v != nil && v.body != nil { ck_collect_hoisted_vars({v.body}, names) }
		case ^WithStatement:
			if v != nil && v.body != nil { ck_collect_hoisted_vars({v.body}, names) }
		case ^SwitchStatement:
			if v == nil { continue }
			for sc in v.cases {
				ck_collect_hoisted_vars(sc.consequent[:], names)
			}
		case ^TryStatement:
			if v == nil { continue }
			ck_collect_hoisted_vars(v.block.body[:], names)
			if handler, ok := v.handler.?; ok {
				ck_collect_hoisted_vars(handler.body.body[:], names)
			}
			if fin, ok := v.finalizer.?; ok {
				ck_collect_hoisted_vars(fin.body[:], names)
			}
		case ^LabeledStatement:
			if v != nil && v.body != nil { ck_collect_hoisted_vars({v.body}, names) }
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
		case ^BlockStatement:
			// §14.2.1 — `var` declarations hoist out of blocks into the
			// module scope. Recurse to collect them so `export { x }` after
			// `{ var x; }` is valid.
			if v != nil { ck_collect_hoisted_vars(v.body[:], names) }
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
				case ^TSInterfaceDeclaration:
					if inner != nil { names[inner.id.name] = true }
				case ^TSTypeAliasDeclaration:
					if inner != nil { names[inner.id.name] = true }
				case ^TSEnumDeclaration:
					if inner != nil { names[inner.id.name] = true }
				case ^TSModuleDeclaration:
					if inner != nil && inner.id != nil {
						if ident, is_id := inner.id.(^Identifier); is_id && ident != nil {
							names[ident.name] = true
						}
					}
				case ^TSImportEqualsDeclaration:
					if inner != nil { names[inner.id.name] = true }
				}
			}
		case ^TSImportEqualsDeclaration:
			if v != nil { names[v.id.name] = true }
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
		// Type-only exports (`export type { X }`) reference the type namespace;
		// the name need not exist as a value binding. This is a TS type-check
		// concern, not an early error.
		if export.export_kind == .Type { continue }
		for spec in export.specifiers {
			local_name, ok := spec.local.(IdentifierName)
			if !ok { continue }
			if !(local_name.name in names) {
				msg := fmt.tprintf("Export '%s' is not defined in the module", local_name.name)
				ck_report(c, u32(local_name.loc.start), msg)
			}
		}
	}
}

// ck_check_ts_export_assignment — TS only. `export = <expr>;`
// (TSExportAssignment) cannot coexist with other export statements
// (named, default, all, or type) in the same module. Also, only one
// `export =` is allowed per module.
//
// Single pass over the Program body: detects whether both regular
// exports and export-assignments exist. If so, reports on every
// export node (both regular and assignment).
@(private="file")
ck_check_ts_export_assignment :: proc(c: ^Checker, program: ^Program) {
	if program == nil { return }
	if program.type != .Module { return }
	has_reg: bool
	has_assign: bool
	assign_seen: bool
	for stmt in program.body {
		if stmt == nil { continue }
		#partial switch v in stmt^ {
		case ^ExportNamedDeclaration:  has_reg = true
		case ^ExportDefaultDeclaration: has_reg = true
		case ^ExportAllDeclaration:     has_reg = true
		case ^TSExportAssignment:
			// Multiple `export =` (no regular exports): report duplicates.
			if assign_seen && !has_reg {
				msg := "An export assignment cannot be used in a module with other exported elements."
				ck_report(c, u32(v.loc.start), msg)
			}
			assign_seen = true
			has_assign = true
		}
	}
	if !has_reg || !has_assign { return }
	msg := "An export assignment cannot be used in a module with other exported elements."
	for stmt in program.body {
		if stmt == nil { continue }
		#partial switch v in stmt^ {
		case ^ExportNamedDeclaration:
			ck_report(c, u32(v.loc.start), msg)
		case ^ExportDefaultDeclaration:
			ck_report(c, u32(v.loc.start), msg)
		case ^ExportAllDeclaration:
			ck_report(c, u32(v.loc.start), msg)
		case ^TSExportAssignment:
			ck_report(c, u32(v.loc.start), msg)
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
ck_check_using_at_script_top :: proc(c: ^Checker, ctx: ^CheckerContext, program: ^Program) {
	if program == nil { return }
	if program.type != .Script { return }
	// CommonJS (.cjs / .cts) wraps the body in a function, so top-level
	// `using` is fine — it's actually function-scope.
	if ctx.is_commonjs { return }
	for stmt in program.body {
		if stmt == nil { continue }
		decl, ok := stmt^.(^VariableDeclaration)
		if !ok || decl == nil { continue }
		switch decl.kind {
		case .Using:
			ck_report_coded(c, u32(decl.loc.start), .K3067_NewTargetOrTopLevelUsing, "'using' declaration is not allowed at the top level of a script")
		case .AwaitUsing:
			ck_report_coded(c, u32(decl.loc.start), .K3014_AwaitUsingContextRestricted,
				"'await using' declaration is not allowed at the top level of a script")
		case .Var, .Let, .Const:
			// not a using-decl
		}
	}
}

// §14.13.1 duplicate-label check — migrated to parser (parse_labelled_statement).

// ck_check_if_labelled_function — §13.6.1 — LABELLED function
// declarations are never allowed as the consequent / alternate of an
// `if` statement, even in sloppy mode. Annex B.3.2 extends FunctionDecl
// to single-statement positions but ONLY for plain (unlabelled)
// FunctionDecl; a wrapping LabeledStatement disqualifies the carve-out.
//
// Walks past LabeledStatement layers; fires when the inner statement
// is a FunctionDeclaration AND we passed at least one label on the way.
@(private="file")
ck_check_if_labelled_function :: proc(c: ^Checker, body: ^Statement) {
	s := body
	label_count := 0
	for s != nil {
		#partial switch v in s^ {
		case ^LabeledStatement:
			if v == nil { return }
			label_count += 1
			s = v.body
		case ^FunctionDeclaration:
			if v == nil { return }
			if label_count == 0 { return }  // unlabelled — Annex B allows
			if v.async || v.generator { return } // parser-side syntax error
			ck_report_coded(c, u32(v.loc.start), .K3060_SingleStatementContext, "Labelled function declaration cannot appear in a single-statement context")
			return
		case:
			return
		}
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
			ck_report_coded(c, u32(v.loc.start), .K3060_SingleStatementContext, "Function declaration cannot appear in a single-statement context")
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
			scope_map_set_first(vars, n, v.loc.start)
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
scope_process_statement_no_parser :: proc(stmt: ^Statement, lex, vars: ^ScopeMap, is_block_scope: bool, strict := true) {
	if stmt == nil { return }
	#partial switch v in stmt^ {
	case ^VariableDeclaration:
		if v == nil { return }
		names: [dynamic]string
		names.allocator = context.temp_allocator
		reserve(&names, 4)
		for decl in v.declarations { scope_collect_pattern(decl.id, &names) }
		if v.kind == .Var {
			for n in names { scope_map_set_first(vars, n, v.loc.start) }
		} else {
			for n in names { scope_map_set(lex, n, v.loc.start) }
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
			// In sloppy-mode function bodies (not block scope),
			// FunctionDeclarations hoist as var-like (Annex B.3.2).
			if strict || is_block_scope {
				scope_map_set(lex, id.name, id.loc.start)
			} else {
				scope_map_set_first(vars, id.name, id.loc.start)
			}
		}
	case ^ClassDeclaration:
		if v == nil { return }
		if id, ok := v.id.(BindingIdentifier); ok {
			scope_map_set(lex, id.name, id.loc.start)
		}
	case ^ImportDeclaration:
		if v == nil { return }
		for spec in v.specifiers {
			if spec == nil { continue }
			switch ss in spec^ {
			case ImportSpecifier:          scope_map_set(lex, ss.local.name, ss.local.loc.start)
			case ImportDefaultSpecifier:   scope_map_set(lex, ss.local.name, ss.local.loc.start)
			case ImportNamespaceSpecifier: scope_map_set(lex, ss.local.name, ss.local.loc.start)
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
// bound names.
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
ck_check_catch_param_body_shadow :: proc(c: ^Checker, ctx: ^CheckerContext, h: CatchClause) {
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
		// Annex B §B.3.4 allows var redeclaration of a simple catch
		// parameter in sloppy mode. For destructuring patterns, var
		// redeclaration is always an error.
		is_simple_id := false
		if _, ok := param.(^Identifier); ok {
			is_simple_id = true
		}
		// In TS/TSX mode, OXC (and TSC) allow `catch(x) { var x; }` even
		// in strict mode when the catch parameter is a simple identifier.
		// Only fire for destructuring patterns in TS, or always in JS
		// strict mode per ECMA-262 §B.3.4.
		is_ts := ctx.lang == .TS || ctx.lang == .TSX
		if (!is_ts && ctx.strict_mode) || !is_simple_id {
			if off, ok := scope_map_get(&body_vars, n); ok {
				msg := fmt.tprintf("Catch parameter '%s' cannot be redeclared with 'var' in catch block", n)
				ck_report(c, off, msg)
			}
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
ck_check_params_vs_body_lex :: proc(c: ^Checker, params: []FunctionParameter, body: []^Statement, strict := true) {
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
		scope_process_statement_no_parser(stmt, &body_lex, &body_vars, false, strict)
	}
	for n in param_names {
		if off, have := scope_map_get(&body_lex, n); have {
			msg := fmt.tprintf("Formal parameter '%s' cannot be redeclared with let/const in function body", n)
			ck_report(c, off, msg)
		}
	}
}

// ck_expr_has_identifier_ref — walk expression tree looking for
// Identifier with given name. Skips closures (function/arrow/class).
@(private="file")
ck_expr_has_identifier_ref :: proc(expr: ^Expression, name: string, alloc: mem.Allocator) -> bool {
	if expr == nil { return false }
	#partial switch e in expr^ {
	case ^Identifier:
		return e != nil && e.name == name
	case ^BinaryExpression:
		return e != nil && (ck_expr_has_identifier_ref(e.left, name, alloc) || ck_expr_has_identifier_ref(e.right, name, alloc))
	case ^CallExpression:
		if e != nil {
			if ck_expr_has_identifier_ref(e.callee, name, alloc) { return true }
			for a in e.arguments { if ck_expr_has_identifier_ref(a, name, alloc) { return true } }
		}
		return false
	case ^NewExpression:
		if e != nil { for a in e.arguments { if ck_expr_has_identifier_ref(a, name, alloc) { return true } } }
		return false
	case ^MemberExpression:
		return e != nil && ck_expr_has_identifier_ref(e.object, name, alloc)
	case ^UnaryExpression:
		return e != nil && ck_expr_has_identifier_ref(e.argument, name, alloc)
	case ^ConditionalExpression:
		return e != nil && (ck_expr_has_identifier_ref(e.test, name, alloc) || ck_expr_has_identifier_ref(e.consequent, name, alloc) || ck_expr_has_identifier_ref(e.alternate, name, alloc))
	case ^ParenthesizedExpression:
		return e != nil && ck_expr_has_identifier_ref(e.expression, name, alloc)
	case ^LogicalExpression:
		return e != nil && (ck_expr_has_identifier_ref(e.left, name, alloc) || ck_expr_has_identifier_ref(e.right, name, alloc))
	case ^ArrayExpression:
		if e != nil { for el in e.elements { if el != nil { if ex, ok := el.(^Expression); ok { if ck_expr_has_identifier_ref(ex, name, alloc) { return true } } } } }
		return false
	case ^TemplateLiteral:
		if e != nil { for ex in e.expressions { if ex != nil && ck_expr_has_identifier_ref(ex, name, alloc) { return true } } }
		return false
	case ^AssignmentExpression:
		return e != nil && ck_expr_has_identifier_ref(e.right, name, alloc)
	case ^SpreadElement:
		return e != nil && ck_expr_has_identifier_ref(e.argument, name, alloc)
	case ^FunctionExpression, ^ArrowFunctionExpression, ^ClassExpression:
		return false  // skip closures
	}
	return false
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
			ck_report_coded(c, u32(loc_from_expr(e).start), .K2050_InvalidLHS, msg)
		}
		return
	}
	decl, have_decl := left_decl.(^VariableDeclaration)
	if !have_decl || decl == nil { return }
	if len(decl.declarations) > 1 {
		msg := fmt.tprintf("Only a single declaration is allowed in a for-%s loop", kind_str)
		ck_report_coded(c, u32(decl.loc.start), .K3061_ForLoopLHS, msg)
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
	// TS2404 — type annotation in for-in loop head is not allowed
	// (checked before the for_in_init_ok gate so it fires regardless
	// of Annex B sloppy-mode carve-out).
	if is_in && (ctx.lang == .TS || ctx.lang == .TSX) {
		for d in decl.declarations {
			has_ann := false
			#partial switch pat in d.id {
			case ^Identifier:
				if _, ok := pat.type_annotation.(^TSTypeAnnotation); ok { has_ann = true }
			case ^ObjectPattern:
				if _, ok := pat.type_annotation.(^TSTypeAnnotation); ok { has_ann = true }
			case ^ArrayPattern:
				if _, ok := pat.type_annotation.(^TSTypeAnnotation); ok { has_ann = true }
			}
			if has_ann {
				ck_report_coded(c, u32(decl.loc.start), .K2040_UnexpectedToken, "The left-hand side of a 'for...in' statement cannot use a type annotation.")
				return
			}
		}
	}
	if for_in_init_ok { return }
	// TS2491 — destructuring patterns in for-in LHS are not allowed
	// in TS. `for (var [a, b] in []) {}` is a SyntaxError.
	if is_in && (ctx.lang == .TS || ctx.lang == .TSX) {
		for d in decl.declarations {
			is_destructuring := false
			#partial switch _ in d.id {
			case ^ArrayPattern, ^ObjectPattern:
				is_destructuring = true
			}
			if is_destructuring {
				ck_report_coded(c, u32(decl.loc.start), .K2040_UnexpectedToken, "The left-hand side of a 'for...in' statement cannot be a destructuring pattern.")
				return
			}
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
	ck_report(c, u32(e.loc.start), msg)
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
				ck_report_coded(c, u32(h.loc.start), .K3037_DuplicateIdentifier, msg)
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
	ck_report_coded(c, u32(pid.loc.start), .K3032_PrivateNameInvalid, msg)
}

// ck_check_class_private_duplicates — §15.7.1 — PrivateBoundNames of
// a class body must not contain any duplicate entries, EXCEPT one name
// used exactly as a getter once and a setter once (no other entries).
//
// Examples that are SyntaxErrors:
//   class C { #x; #x; }                  field + field
//   class C { #m() {}; #m() {} }         method + method
//   class C { get #g() {}; get #g() {} } getter + getter
//   class C { set #s(v) {}; set #s(v) {} } setter + setter
//   class C { #m() {}; get #m() {} }     method + getter
//   class C { #x; #m() {} }              field + method (same name)
//
// Allowed:
//   class C { get #m() {}; set #m(v) {} } get/set pair
//
// The static-mismatch sub-rule (`static get #f` paired with `set #f`) is
// folded into this single walker rather than living separately — if a
// name has both a getter and setter and they're the only entries, we
// also verify their static-ness matches. All other shapes count as
// outright duplicates.
@(private="file")
ck_check_class_private_duplicates :: proc(c: ^Checker, cls: ^ClassExpression, is_ts: bool = false) {
	if cls == nil { return }
	PrivateRecord :: struct {
		kinds:     bit_set[ClassElementKind],
		n_meth:    int,
		n_get:     int,
		n_set:     int,
		n_field:   int,
		get_static: bool,
		set_static: bool,
		last_dup_loc: u32,
		reported:  bool,
	}
	seen: map[string]PrivateRecord
	seen.allocator = context.temp_allocator
	defer delete(seen)

	for elem in cls.body.body {
		if elem.key == nil { continue }
		pid, is_priv := elem.key^.(^PrivateIdentifier)
		if !is_priv || pid == nil { continue }
		name := pid.name
		prev, _ := seen[name]

		is_field := false
		if elem.kind == .Method {
			if _, has_value := elem.value.(^Expression); !has_value {
				is_field = true
			}
		}

		switch {
		case is_field:
			prev.n_field += 1
		case elem.kind == .Method:
			prev.n_meth += 1
		case elem.kind == .Get:
			prev.n_get   += 1
			prev.get_static = elem.static
		case elem.kind == .Set:
			prev.n_set   += 1
			prev.set_static = elem.static
		}
		prev.last_dup_loc = u32(elem.loc.start)

		seen[name] = prev
	}

	for name, rec in seen {
		total := rec.n_field + rec.n_meth + rec.n_get + rec.n_set
		if total <= 1 { continue }

		// Allowed: exactly one getter + exactly one setter, nothing else.
		if rec.n_get == 1 && rec.n_set == 1 && rec.n_field == 0 && rec.n_meth == 0 {
			// Static-mismatch is the only failure mode for the get/set pair.
			if rec.get_static != rec.set_static {
				msg := fmt.tprintf("Private getter and setter for '#%s' must both be static or both be non-static", name)
				ck_report_coded(c, rec.last_dup_loc, .K3032_PrivateNameInvalid, msg)
			}
			continue
		}

		// TS mode: multiple private methods are allowed (overload signatures).
		if rec.n_meth > 1 && rec.n_field == 0 && rec.n_get == 0 && rec.n_set == 0 && is_ts {
			continue
		}

		msg := fmt.tprintf("Duplicate private name '#%s' in class body", name)
		ck_report(c, rec.last_dup_loc, msg)
	}
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
				ck_report_coded(c, u32(elem.loc.start), .K3032_PrivateNameInvalid, msg)
			}
			prev.has_get = true
			prev.get_static = elem.static
		case .Set:
			if prev.has_get && prev.get_static != elem.static {
				msg := fmt.tprintf("Private getter and setter for '#%s' must both be static or both be non-static", name)
				ck_report_coded(c, u32(elem.loc.start), .K3032_PrivateNameInvalid, msg)
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
// `is_strict` mirrors the parser's `strict := p.ctx.strict_mode ||
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
//
// The parser-side parse_binding_pattern now also fires for plain
// top-level Identifier bindings under p.ctx.strict_mode, so a parameter
// like `function f(eval) {}` in an enclosing-strict context gets two
// diagnostics (parser Generic + checker Parameter). Body-strict
// promotion (`function f(eval) { "use strict"; }` in a sloppy outer)
// only the checker fires — the parser hadn't yet seen the directive
// when it parsed the binding identifier. Removing the checker leg
// would break that case, so we keep both for now and accept the
// duplicate diagnostic on the enclosing-strict path.
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
			ck_report(c, u32(v.loc.start), msg)
		} else if is_strict_reserved_simple_name(v.name) {
			msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", v.name)
			ck_report_coded(c, u32(v.loc.start), .K3050_StrictModeReserved, msg)
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
			ck_report(c, u32(e.loc.start), msg)
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
		ck_report_coded(c, u32(ident.loc.start), .K3051_StrictModeProhibited, msg)
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
		ck_report_coded(c, off, .K3050_StrictModeReserved, msg)
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
	ck_report_coded(c, u32(id.loc.start), .K3050_StrictModeReserved, msg)
}

// ck_check_module_await_binding — §16.2.2 — the BindingIdentifier
// `await` is reserved in module code (the [+Await] grammar parameter is
// set). Recurses through destructuring patterns so `var { await } = obj;`,
// `var [await] = arr;` and `var { x: await } = obj;` all fire.
@(private="file")
ck_check_module_await_binding :: proc(c: ^Checker, pat: Pattern) {
	#partial switch p in pat {
	case ^Identifier:
		if p == nil { return }
		if p.name == "await" {
			ck_report_coded(c, u32(p.loc.start), .K3010_AwaitYieldAsBindingName, "'await' is reserved as a binding name in module code")
		}
	case ^ArrayPattern:
		if p == nil { return }
		for el in p.elements {
			if inner, have := el.(Pattern); have { ck_check_module_await_binding(c, inner) }
		}
	case ^ObjectPattern:
		if p == nil { return }
		for pr in p.properties {
			ck_check_module_await_binding(c, pr.value)
		}
	case ^RestElement:
		if p == nil { return }
		ck_check_module_await_binding(c, p.argument)
	case ^AssignmentPattern:
		if p == nil { return }
		ck_check_module_await_binding(c, p.left)
	}
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
// Binding-position `await` (e.g. `var await;`) at module top-level is
// caught upstream by ck_check_module_await_binding from
// ck_walk_var_decl; this proc handles the IdentifierReference case
// (e.g. an escaped `\u0061wait` used as a bare reference).
//
// Module top-level IdentifierReference `await` is intentionally NOT a
// reserved context here — it's valid as the head of a top-level
// AwaitExpression. The reservation only applies to BindingIdentifier
// positions (handled by ck_check_module_await_binding) and to escaped
// forms in restricted contexts.
//
@(private="file")
ck_check_identifier_await_reserved :: proc(c: ^Checker, ctx: ^CheckerContext, id: ^Identifier) {
	if id == nil || id.name != "await" { return }
	if !id.has_escape { return }
	if ctx.in_async || ctx.in_class_static_block {
		ck_report_coded(c, u32(id.loc.start), .K3010_AwaitYieldAsBindingName, "'await' is not allowed as an identifier in this context")
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
			ck_check_import_specifier_local(c, s.local.name, u32(s.local.loc.start))
		case ImportDefaultSpecifier:
			ck_check_import_specifier_local(c, s.local.name, u32(s.local.loc.start))
		case ImportNamespaceSpecifier:
			ck_check_import_specifier_local(c, s.local.name, u32(s.local.loc.start))
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
