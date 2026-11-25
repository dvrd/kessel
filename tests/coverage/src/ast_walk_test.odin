// The typed AST walk (src/ast_walk.odin), driven the way a library consumer
// drives it: parse inline source, hand `ast_walk` a visitor, read back what
// the visitor recorded.
//
// Method: the visitor writes a trace — one token per `enter` (`+Kind`) and
// per `leave` (`-Kind`) — and tests compare it with the expected trace. A
// trace pins the visit order, the enter/leave pairing and the node kinds in
// one string, so any change in traversal shows up as a readable diff.
package coverage

import "core:mem/virtual"
import "core:path/filepath"
import "core:reflect"
import "core:slice"
import "core:strings"
import "core:testing"

import kessel "../../../src"

@(private = "file")
Trace :: struct {
	out:          strings.Builder,
	// Enter callbacks seen so far, and the count at which to act.
	entered:      int,
	act_at:       int,
	action:       kessel.AstWalkAction,
	// Open nodes: must be zero again when a walk completes.
	balance:      int,
	skip_pending: bool,
}

// Short names for the node kinds the tests look at; everything else is `?`
// so that an unexpected kind is visible without listing all of them.
@(private = "file")
trace_name :: proc(node: kessel.AstNode) -> string {
	#partial switch n in node {
	case ^kessel.Program:                 return "Program"
	case ^kessel.ExpressionStatement:     return "ExprStmt"
	case ^kessel.VariableDeclaration:     return "VarDecl"
	case ^kessel.VariableDeclarator:      return "Declarator"
	case ^kessel.FunctionDeclaration:     return "FnDecl"
	case ^kessel.FunctionExpression:      return "FnExpr"
	case ^kessel.ArrowFunctionExpression: return "Arrow"
	case ^kessel.FunctionParameter:       return "Param"
	case ^kessel.FunctionBody:            return "Body"
	case ^kessel.BlockStatement:          return "Block"
	case ^kessel.ReturnStatement:         return "Return"
	case ^kessel.BindingIdentifier:       return "Name"
	case ^kessel.Identifier:              return n.name
	case ^kessel.NumericLiteral:          return n.raw
	case ^kessel.StringLiteral:           return "Str"
	case ^kessel.BinaryExpression:        return "Bin"
	case ^kessel.LogicalExpression:       return "Logical"
	case ^kessel.MemberExpression:        return "Member"
	case ^kessel.CallExpression:          return "Call"
	case ^kessel.ArrayExpression:         return "Array"
	case ^kessel.ObjectPattern:           return "ObjPat"
	case ^kessel.ObjectPatternProperty:   return "PatProp"
	case ^kessel.IdentifierName:          return "Key"
	case ^kessel.AssignmentPattern:       return "AssignPat"
	case ^kessel.JSXElement:              return "JSXElement"
	case ^kessel.JSXOpeningElement:       return "Opening"
	case ^kessel.JSXClosingElement:       return "Closing"
	case ^kessel.JSXIdentifier:           return "JSXName"
	case ^kessel.JSXAttribute:            return "Attr"
	case ^kessel.JSXText:                 return "Text"
	case ^kessel.JSXExpressionContainer:  return "Container"
	case ^kessel.JSXSpreadChild:          return "SpreadChild"
	case ^kessel.TSTypeAnnotation:        return "Annotation"
	case ^kessel.TSKeywordType:           return "Keyword"
	}
	return "?"
}

@(private = "file")
trace_enter :: proc(user: rawptr, node: kessel.AstNode) -> kessel.AstWalkAction {
	trace := cast(^Trace)user
	trace.entered += 1
	strings.write_string(&trace.out, " +")
	strings.write_string(&trace.out, trace_name(node))
	if trace.entered == trace.act_at && trace.action != .Continue {
		// A skipped node is left right away without having been opened.
		trace.skip_pending = trace.action == .Skip
		return trace.action
	}
	trace.balance += 1
	return .Continue
}

@(private = "file")
trace_leave :: proc(user: rawptr, node: kessel.AstNode) {
	trace := cast(^Trace)user
	if trace.skip_pending { trace.skip_pending = false } else { trace.balance -= 1 }
	strings.write_string(&trace.out, " -")
	strings.write_string(&trace.out, trace_name(node))
}

// Parse `source`, walk it, return the trace. `act_at` (1-based, 0 = never)
// makes the visitor return `action` from that `enter` call.
@(private = "file")
trace_walk :: proc(
	t: ^testing.T,
	source: string,
	lang: kessel.Lang,
	act_at := 0,
	action := kessel.AstWalkAction.Continue,
	depth_max: u32 = kessel.PARSE_RESOURCE_AST_DEPTH,
) -> (text: string, status: kessel.AstWalkStatus, balance: int) {
	job: kessel.ParseJob
	config := kessel.ParseConfig{lang_override = lang}
	if !testing.expect(t, kessel.parse_job_open_inline(&job, source, config, "walk")) { return }
	defer kessel.parse_job_close(&job)
	kessel.parse_job_run(&job)
	if !testing.expectf(t, len(job.parser.errors) == 0, "%q does not parse", source) { return }

	trace := Trace{act_at = act_at, action = action}
	strings.builder_init(&trace.out, context.temp_allocator)
	visitor := kessel.AstVisitor{user = &trace, enter = trace_enter, leave = trace_leave}
	status = kessel.ast_walk(job.program, visitor, context.allocator, depth_max)
	return strings.trim_left(strings.to_string(trace.out), " "), status, trace.balance
}

@(test)
test_ast_walk_order_and_pairing :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text, status, balance := trace_walk(t, "const x = f(1)[y];", .JS)
	testing.expect_value(t, status, kessel.AstWalkStatus.Completed)
	testing.expect_value(t, balance, 0)
	testing.expect_value(
		t, text,
		"+Program +VarDecl +Declarator +x -x +Member +Call +f -f +1 -1 -Call +y -y -Member" +
		" -Declarator -VarDecl -Program",
	)
}

// Function and arrow parameters are reported the same way although the
// parser stores their defaults differently: Param, then target, then default.
@(test)
test_ast_walk_parameters_are_uniform :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// Identical for both forms; `AssignPat` appears only for the default
	// nested inside the destructuring pattern.
	PARAMETERS :: "+Param +a -a +1 -1 -Param" +
	              " +Param +ObjPat +PatProp +Key -Key +AssignPat +b -b +2 -2 -AssignPat" +
	              " -PatProp -ObjPat -Param"
	function, _, _ := trace_walk(t, "function f(a = 1, {b = 2}) {}", .JS)
	testing.expect_value(
		t, function,
		"+Program +FnDecl +Name -Name " + PARAMETERS + " +Body -Body -FnDecl -Program",
	)
	arrow, _, _ := trace_walk(t, "(a = 1, {b = 2}) => {};", .JS)
	testing.expect_value(
		t, arrow,
		"+Program +ExprStmt +Arrow " + PARAMETERS + " +Block -Block -Arrow -ExprStmt -Program",
	)
}

@(test)
test_ast_walk_jsx_and_types :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	jsx, status, balance := trace_walk(t, "<a b=\"c\">t{x}{...ys}</a>;", .JSX)
	testing.expect_value(t, status, kessel.AstWalkStatus.Completed)
	testing.expect_value(t, balance, 0)
	testing.expect_value(
		t, jsx,
		"+Program +ExprStmt +JSXElement +Opening +JSXName -JSXName +Attr +JSXName -JSXName" +
		" +Str -Str -Attr -Opening +Text -Text +Container +x -x -Container" +
		" +SpreadChild +ys -ys -SpreadChild +Closing +JSXName -JSXName -Closing" +
		" -JSXElement -ExprStmt -Program",
	)
	typed, _, _ := trace_walk(t, "let n: number = 1;", .TS)
	testing.expect_value(
		t, typed,
		"+Program +VarDecl +Declarator +n +Annotation +Keyword -Keyword -Annotation -n" +
		" +1 -1 -Declarator -VarDecl -Program",
	)
}

// `.Skip` leaves out the children but still calls `leave`; `.Stop` ends the
// walk with no further callback at all.
@(test)
test_ast_walk_skip_and_stop :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := "f(1); g(2);"
	// Enter #3 is the first CallExpression.
	skipped, status, balance := trace_walk(t, source, .JS, 3, .Skip)
	testing.expect_value(t, status, kessel.AstWalkStatus.Completed)
	testing.expect_value(t, balance, 0)
	testing.expect_value(
		t, skipped,
		"+Program +ExprStmt +Call -Call -ExprStmt" +
		" +ExprStmt +Call +g -g +2 -2 -Call -ExprStmt -Program",
	)
	stopped, stop_status, _ := trace_walk(t, source, .JS, 4, .Stop)
	testing.expect_value(t, stop_status, kessel.AstWalkStatus.Stopped)
	testing.expect_value(t, stopped, "+Program +ExprStmt +Call +f")

	// Skipping or stopping in the middle of a left-associative chain: the
	// chain is `((a + b) + c) + d`, entered outermost first.
	chain := "a + b + c + d;"
	skipped_link, _, chain_balance := trace_walk(t, chain, .JS, 4, .Skip)
	testing.expect_value(t, chain_balance, 0)
	testing.expect_value(
		t, skipped_link,
		"+Program +ExprStmt +Bin +Bin -Bin +d -d -Bin -ExprStmt -Program",
	)
	stopped_link, link_status, _ := trace_walk(t, chain, .JS, 5, .Stop)
	testing.expect_value(t, link_status, kessel.AstWalkStatus.Stopped)
	testing.expect_value(t, stopped_link, "+Program +ExprStmt +Bin +Bin +Bin")
}

// Nesting is bounded; a left-associative chain is not nesting.
@(test)
test_ast_walk_depth_bound :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// Program > ExprStmt > Array > Array > Array > Array > x : 7 levels.
	nested := "[[[[x]]]];"
	_, fits, _ := trace_walk(t, nested, .JS, 0, .Continue, 7)
	testing.expect_value(t, fits, kessel.AstWalkStatus.Completed)
	partial, exceeded, _ := trace_walk(t, nested, .JS, 0, .Continue, 6)
	testing.expect_value(t, exceeded, kessel.AstWalkStatus.DepthExceeded)
	// The node past the bound is never offered; every node that was entered
	// is still left, so a visitor that pushes and pops stays balanced.
	testing.expect_value(t, partial,
		"+Program +ExprStmt +Array +Array +Array +Array -Array -Array -Array -Array -ExprStmt -Program")

	// Program > ExprStmt > chain > operand: 4 levels for any chain length,
	// and for mixed member / call / binary / logical chains.
	_, flat, _ := trace_walk(t, "a + b + c + d + e + f + g + h;", .JS, 0, .Continue, 4)
	testing.expect_value(t, flat, kessel.AstWalkStatus.Completed)
	_, mixed, _ := trace_walk(t, "a.b().c.d()(1) + e && f;", .JS, 0, .Continue, 4)
	testing.expect_value(t, mixed, kessel.AstWalkStatus.Completed)
}

@(private = "file")
Count :: struct {
	enters: int,
	leaves: int,
	binary: int,
}

@(private = "file")
count_enter :: proc(user: rawptr, node: kessel.AstNode) -> kessel.AstWalkAction {
	count := cast(^Count)user
	count.enters += 1
	if _, is_binary := node.(^kessel.BinaryExpression); is_binary { count.binary += 1 }
	return .Continue
}

@(private = "file")
count_leave :: proc(user: rawptr, node: kessel.AstNode) {
	(cast(^Count)user).leaves += 1
}

// A million-term chain must be walked at the default depth without native
// recursion: every link is entered and left exactly once.
@(test)
test_ast_walk_million_term_chain :: proc(t: ^testing.T) {
	TERMS :: 1_000_000
	source := strings.builder_make(0, 2 * TERMS + 8)
	defer strings.builder_destroy(&source)
	strings.write_string(&source, "x=a")
	for _ in 1..<TERMS { strings.write_string(&source, "+a") }

	job: kessel.ParseJob
	text := strings.to_string(source)
	if !testing.expect(t, kessel.parse_job_open_inline(&job, text, {}, "chain.js")) { return }
	defer kessel.parse_job_close(&job)
	kessel.parse_job_run(&job)
	if !testing.expect_value(t, len(job.parser.errors), 0) { return }

	count: Count
	visitor := kessel.AstVisitor{user = &count, enter = count_enter, leave = count_leave}
	status := kessel.ast_walk(job.program, visitor, context.allocator)
	testing.expect_value(t, status, kessel.AstWalkStatus.Completed)
	testing.expect_value(t, count.binary, TERMS - 1)
	// Program, statement, assignment, `x`, TERMS operands, TERMS - 1 operators.
	testing.expect_value(t, count.enters, 4 + TERMS + TERMS - 1)
	testing.expect_value(t, count.leaves, count.enters)
}

// True when a value of `type` starts with a `Loc`: its first field is
// `loc: Loc`, or is an embedded struct (`using expr: FunctionExpression`)
// that starts with one.
@(private = "file")
starts_with_loc :: proc(type: typeid) -> bool {
	current := type
	// Embedding is one level deep today; the bound keeps this a loop.
	for _ in 0..<4 {
		fields := reflect.struct_fields_zipped(current)
		if len(fields) == 0 || fields[0].offset != 0 { return false }
		if fields[0].name == "loc" { return fields[0].type.id == typeid_of(kessel.Loc) }
		current = fields[0].type.id
	}
	return false
}

// `ast_node_loc` reads the span through the node pointer. That is only
// sound if every variant of AstNode is a pointer to a struct that starts
// with `loc: Loc`; check it for all of them.
@(test)
test_ast_node_loc_layout :: proc(t: ^testing.T) {
	node_info := reflect.type_info_base(type_info_of(kessel.AstNode))
	union_info, is_union := node_info.variant.(^reflect.Type_Info_Union)
	if !testing.expect(t, is_union) { return }
	// One variant per node kind the walk reports; a truncated list must
	// not make the loop below pass vacuously.
	testing.expect_value(t, len(union_info.variants), AST_NODE_KIND_COUNT)
	for variant in union_info.variants {
		variant_info := reflect.type_info_base(variant)
		pointer_info, is_pointer := variant_info.variant.(^reflect.Type_Info_Pointer)
		if !testing.expectf(t, is_pointer, "%v is not a pointer", variant) { continue }
		has_loc := starts_with_loc(pointer_info.elem.id)
		testing.expectf(t, has_loc, "%v does not start with a Loc", variant)
	}

	job: kessel.ParseJob
	opened := kessel.parse_job_open_inline(&job, "  foo(bar);", {}, "loc.js")
	if !testing.expect(t, opened) { return }
	defer kessel.parse_job_close(&job)
	kessel.parse_job_run(&job)
	statement := job.program.body[0].(^kessel.ExpressionStatement)
	call := statement.expression.(^kessel.CallExpression)
	testing.expect_value(t, kessel.ast_node_loc(statement), kessel.Loc{start = 2, end = 11})
	testing.expect_value(t, kessel.ast_node_loc(call), kessel.Loc{start = 2, end = 10})
	testing.expect_value(t, kessel.ast_node_loc(nil), kessel.Loc{})
}

// Update together with the AstNode union in src/ast_walk.odin.
@(private = "file")
AST_NODE_KIND_COUNT :: 149

@(private = "file")
Reached :: struct {
	// One key per visited node: `start << 32 | end`. Sorted after the walk
	// so that "was a node with exactly this span visited" is a binary
	// search; cheaper than a hash set at corpus scale.
	spans:  [dynamic]u64,
	enters: int,
	leaves: int,
}

@(private = "file")
reached_key :: proc(start, end: u32) -> u64 {
	return u64(start) << 32 | u64(end)
}

@(private = "file")
reached_enter :: proc(user: rawptr, node: kessel.AstNode) -> kessel.AstWalkAction {
	reached := cast(^Reached)user
	reached.enters += 1
	loc := kessel.ast_node_loc(node)
	append(&reached.spans, reached_key(loc.start, loc.end))
	return .Continue
}

@(private = "file")
reached_span :: proc(reached: ^Reached, start, end: u32) -> bool {
	_, found := slice.binary_search(reached.spans[:], reached_key(start, end))
	return found
}

@(private = "file")
reached_leave :: proc(user: rawptr, node: kessel.AstNode) {
	(cast(^Reached)user).leaves += 1
}

// Completeness, checked against an independent walker. The semantic pass
// (src/semantic.odin) has its own traversal and records the span of every
// identifier it declares or resolves. If `ast_walk` skipped any subtree that
// holds code, some of those spans would never be offered to the visitor.
// (A declaration's span is the binding identifier's, except for enum
// members, where it is the member's; both are nodes the walk reports.)
// Run over every must-parse fixture of the misc, Babel and TypeScript
// corpora: JavaScript, JSX and TypeScript syntax in all its corners.
@(test)
test_ast_walk_reaches_every_binding_and_reference :: proc(t: ^testing.T) {
	root := find_kessel_root()
	if !testing.expect(t, root != "") { return }
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) { return }
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	vendor := filepath.join({root, "tests", "vendor"}, allocator) or_else ""

	suites := [?][]Fixture{
		load_misc(root, allocator),
		load_babel(vendor, allocator),
		load_typescript(vendor, allocator),
	}
	files, missed := 0, 0
	for fixtures in suites {
		for fixture in fixtures {
			if fixture.should_fail { continue }
			checked, missing := walk_reaches_model(t, fixture)
			if checked { files += 1 }
			missed += missing
		}
	}
	testing.expect_value(t, missed, 0)
	// The corpora hold thousands of must-parse fixtures; a loader that
	// silently returned nothing must not make this test pass.
	testing.expectf(t, files > 5000, "only %d fixtures were checked", files)
}

// Returns whether the fixture parsed cleanly and was checked, and how many
// spans of the semantic model the walk failed to reach.
@(private = "file")
walk_reaches_model :: proc(t: ^testing.T, fixture: Fixture) -> (checked: bool, missing: int) {
	config := kessel.ParseConfig{
		lang_override               = fixture.lang,
		source_type_override        = fixture.source_type,
		force_strict                = fixture.force_strict,
		source_is_dts_override      = fixture.source_is_dts,
		is_commonjs_override        = fixture.is_commonjs,
		disallow_ambiguous_jsx_like = fixture.disallow_ambiguous_jsx_like,
	}
	job: kessel.ParseJob
	if !kessel.parse_job_open_inline(&job, fixture.code, config, fixture.rel) { return }
	defer kessel.parse_job_close(&job)
	kessel.parse_job_run(&job)
	if job.program == nil || len(job.parser.errors) != 0 { return }

	reached := Reached{spans = make([dynamic]u64, job.arena_alloc)}
	visitor := kessel.AstVisitor{user = &reached, enter = reached_enter, leave = reached_leave}
	status := kessel.ast_walk(job.program, visitor, context.allocator)
	if status == .DepthExceeded { return }
	testing.expectf(t, status == .Completed, "%s: status %v", fixture.rel, status)
	testing.expectf(t, reached.enters == reached.leaves, "%s: unbalanced walk", fixture.rel)
	slice.sort(reached.spans[:])

	model := kessel.semantic_build(job.program, fixture.code, fixture.lang, job.arena_alloc)
	for ref in model.refs {
		if reached_span(&reached, ref.start, ref.end) { continue }
		missing += 1
		if missing <= 3 {
			testing.expectf(
				t, false, "%s: reference `%s` at %d not reached", fixture.rel, ref.name, ref.start,
			)
		}
	}
	for symbol in model.symbols[1:] {
		if reached_span(&reached, symbol.decl_start, symbol.decl_end) { continue }
		missing += 1
		if missing <= 3 {
			testing.expectf(
				t, false, "%s: declaration `%s` at %d not reached",
				fixture.rel, symbol.name, symbol.decl_start,
			)
		}
	}
	return true, missing
}
