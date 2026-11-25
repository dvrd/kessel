package kessel

import "core:strings"

// Async generators and `for await` for targets before ES2018.
//
// An async generator becomes a function that hands a generator to a driver.
// The driver gives the caller an object with `next`, `throw` and `return`,
// keeps their requests in a queue, and runs the generator one request at a
// time. The generator tells the driver what it wants by what it yields:
//
//     await a          yield new Await(a)           wait, then send the outcome back in
//     yield a          yield yield new Await(a)     wait for `a`, then hand it to the caller
//     return a         return yield new Await(a)    wait for `a` inside any `try` around it
//     yield* a         yield* delegate(a)           an iterator that forwards each request
//
// These are the places where an async generator awaits, so a rejected
// operand is thrown at the same statement, inside the same `try` blocks.
//
// `for await (x of y) body` becomes a loop over a small record made from the
// iterator, which holds the `next` method read once and tells a missing
// `return` method from one that returned nothing:
//
//     {
//       var it = iterator(y), more, step, error;
//       try {
//         for (; more = !(step = it.check(await it.next())).done; more = false) {
//           const x = step.value;
//           body
//         }
//       } catch (caught) {
//         error = [caught];
//       } finally {
//         try {
//           more && (step = it.close()) && it.check(await step.value);
//         } finally {
//           if (error) throw error[0];
//         }
//       }
//     }
//
// `more` is true exactly while the body runs, so the iterator is closed when
// the body leaves early and not when `next` fails or reports the end. An
// error from the body wins over one from closing. The `await`s written here
// are ordinary nodes: in an async function below ES2017 they become `yield`,
// and in an async generator they are marked like any other.

// ----------------------------------------------------------------------------
// The marked nodes of an async generator, as they print.
// ----------------------------------------------------------------------------

// `yield new Await(value)`.
async_generator_await :: proc(cg: ^Codegen, value: ^Expression, loc: Loc) -> ^Expression {
	state := cg.transform
	assert(value != nil)
	at := loc.end
	made := new(NewExpression, state.allocator)
	made^ = {loc = loc, callee = transform_identifier(state, transform_helper(cg, .Async_Await), at)}
	made.arguments = make([dynamic]^Expression, 0, 1, state.allocator)
	append(&made.arguments, value)
	yield := new(YieldExpression, state.allocator)
	yield^ = {loc = loc, argument = transform_expression(state, made)}
	return transform_expression(state, yield)
}

async_generator_yield :: proc(cg: ^Codegen, node: ^YieldExpression) -> ^Expression {
	state := cg.transform
	yield := new(YieldExpression, state.allocator)
	yield^ = {loc = node.loc, delegate = node.delegate}
	value, present := node.argument.?
	if node.delegate {
		assert(present)
		yield.argument = class_helper_call(cg, .Async_Delegate, {value}, node.loc.end)
	} else {
		if !present || value == nil { value = target_void(state, node.loc) }
		yield.argument = async_generator_await(cg, value, node.loc)
	}
	return transform_expression(state, yield)
}

// `return value` waits for the value where it stands. The new `await` is
// marked at once, because the scan that marks the others has passed it.
async_generator_return :: proc(cg: ^Codegen, node: ^ReturnStatement) {
	state := cg.transform
	value, present := node.argument.?
	if !present || value == nil { return }
	await := new(AwaitExpression, state.allocator)
	await^ = {loc = loc_from_expr(value), argument = value}
	state.async_marks[rawptr(await)] = true
	node.argument = transform_expression(state, await)
}

// ----------------------------------------------------------------------------
// for await
// ----------------------------------------------------------------------------

AsyncLoops :: struct {
	cg:        ^Codegen,
	functions: int, // Functions around the current node.
}

// Rewrites every `for await` inside a function before anything prints. One
// at the top level of a module is left for the printer to refuse, with the
// top-level `await` it implies.
async_lower_loops :: proc(cg: ^Codegen, program: ^Program) {
	state := cg.transform
	if state == nil || state.target >= .ES2018 || program == nil { return }
	if !strings.contains(cg.source, "await") { return }
	pass := AsyncLoops{cg = cg}
	visitor := AstVisitor{user = &pass, enter = async_loops_enter, leave = async_loops_leave}
	status := ast_walk(program, visitor, context.temp_allocator)
	if status == .DepthExceeded || status == .OutOfMemory {
		cg_strip_unsupported(cg, {}, "this program nests too deeply to lower for await")
	}
	if status == .Completed { assert(pass.functions == 0) }
}

async_loops_leave :: proc(user: rawptr, node: AstNode) {
	pass := cast(^AsyncLoops)user
	#partial switch _ in node {
	case ^FunctionExpression, ^FunctionDeclaration, ^ArrowFunctionExpression:
		pass.functions -= 1
	}
}

// A statement is replaced through the node that holds it, so every node
// that holds statements offers its own.
async_loops_enter :: proc(user: rawptr, node: AstNode) -> AstWalkAction {
	pass := cast(^AsyncLoops)user
	#partial switch value in node {
	case ^FunctionExpression, ^FunctionDeclaration, ^ArrowFunctionExpression:
		pass.functions += 1
	case ^FunctionBody:
		for slot in value.body { async_loops_slot(pass, slot) }
	case ^BlockStatement:
		for slot in value.body { async_loops_slot(pass, slot) }
	case ^SwitchCase:
		for slot in value.consequent { async_loops_slot(pass, slot) }
	case ^IfStatement:
		async_loops_slot(pass, value.consequent)
		if alternate, present := value.alternate.?; present { async_loops_slot(pass, alternate) }
	case ^ForStatement:     async_loops_slot(pass, value.body)
	case ^ForInStatement:   async_loops_slot(pass, value.body)
	case ^ForOfStatement:   async_loops_slot(pass, value.body)
	case ^WhileStatement:   async_loops_slot(pass, value.body)
	case ^DoWhileStatement: async_loops_slot(pass, value.body)
	case ^WithStatement:    async_loops_slot(pass, value.body)
	}
	return .Stop if pass.cg.strip_diag != nil else .Continue
}

// Replaces the statement in `slot` when it is a `for await`, with or without
// labels. The labels stay on the loop, where `continue` needs them.
async_loops_slot :: proc(pass: ^AsyncLoops, slot: ^Statement) {
	cg := pass.cg
	if slot == nil || pass.functions == 0 { return }
	inner := slot
	for inner != nil {
		labeled, is_label := inner^.(^LabeledStatement)
		if !is_label { break }
		inner = labeled.body
	}
	if inner == nil { return }
	loop, is_loop := inner^.(^ForOfStatement)
	if !is_loop || !loop.await { return }
	if declaration, declared := loop.left_decl.?; declared {
		if resource_kind(declaration) != .None {
			what := "a using declaration in the head of for await cannot be lowered"
			cg_strip_unsupported(cg, loop.loc, what)
			return
		}
	}
	// The model must describe the tree as written, before any of it moves.
	transform_model(cg)
	names := AsyncLoopNames{
		iterator = codegen_fresh_runtime_binding(cg, "iterator"),
		more     = codegen_fresh_runtime_binding(cg, "more"),
		step     = codegen_fresh_runtime_binding(cg, "step"),
		error    = codegen_fresh_runtime_binding(cg, "error"),
	}
	inner^ = async_loop_for(cg, loop, names)
	kept := new(Statement, cg.transform.allocator)
	kept^ = slot^
	slot^ = async_loop_block(cg, loop, names, kept)
}

AsyncLoopNames :: struct {
	iterator, more, step, error: string,
}

async_loop_name :: proc(cg: ^Codegen, name: string, at: u32) -> ^Expression {
	return transform_identifier(cg.transform, name, at)
}

// `it.<method>(<arguments>)`.
async_loop_call :: proc(
	cg: ^Codegen, names: AsyncLoopNames, method: string, arguments: []^Expression, at: u32,
) -> ^Expression {
	state := cg.transform
	callee := target_member(
		state, async_loop_name(cg, names.iterator, at), transform_identifier(state, method, at),
		false, {at, at},
	)
	return target_call(state, callee, arguments, {at, at})
}

async_loop_await :: proc(cg: ^Codegen, value: ^Expression, at: u32) -> ^Expression {
	state := cg.transform
	await := new(AwaitExpression, state.allocator)
	// The span lies in the loop, and so in the function the loop is in.
	await^ = {loc = {at, at}, argument = value}
	return transform_expression(state, await)
}

async_loop_statement :: proc(state: ^TransformState, node: ^$T) -> ^Statement {
	statement := new(Statement, state.allocator)
	statement^ = node
	return statement
}

// `for (; more = !(step = it.check(await it.next())).done; more = false) { ... }`
async_loop_for :: proc(
	cg: ^Codegen, loop: ^ForOfStatement, names: AsyncLoopNames,
) -> ^ForStatement {
	state := cg.transform
	at := loop.loc.start
	loc := Loc{at, at}
	next := async_loop_await(cg, async_loop_call(cg, names, "next", nil, at), at)
	checked := async_loop_call(cg, names, "check", {next}, at)
	stored := new(ParenthesizedExpression, state.allocator)
	stored^ = {
		loc = loc,
		expression = target_assign(state, async_loop_name(cg, names.step, at), checked, loc),
	}
	done := target_member(
		state, transform_expression(state, stored), transform_identifier(state, "done", at), false, loc,
	)
	negated := new(UnaryExpression, state.allocator)
	negated^ = {loc = loc, operator = .LogicalNot, argument = done, prefix = true}
	off := new(BooleanLiteral, state.allocator)
	off^ = {loc = loc, value = false}

	value := target_member(
		state, async_loop_name(cg, names.step, at), transform_identifier(state, "value", at), false, loc,
	)
	body := new(BlockStatement, state.allocator)
	body.loc = loc
	body.body = make([dynamic]^Statement, 0, 2, state.allocator)
	if declaration, declared := loop.left_decl.?; declared {
		assert(len(declaration.declarations) == 1)
		declaration.declarations[0].init = value
		append(&body.body, async_loop_statement(state, declaration))
	} else if target, written := loop.left_expr.?; written {
		append(&body.body, class_statement(state, target_assign(state, target, value, loc), at))
	}
	append(&body.body, loop.body)

	result := new(ForStatement, state.allocator)
	result^ = {
		loc = loop.loc,
		test = target_assign(
			state, async_loop_name(cg, names.more, at), transform_expression(state, negated), loc,
		),
		update = target_assign(
			state, async_loop_name(cg, names.more, at), transform_expression(state, off), loc,
		),
		body = async_loop_statement(state, body),
	}
	return result
}

// The block around the loop: its bindings, and the `try` that closes the iterator.
async_loop_block :: proc(
	cg: ^Codegen, loop: ^ForOfStatement, names: AsyncLoopNames, kept: ^Statement,
) -> ^BlockStatement {
	state := cg.transform
	at := loop.loc.start
	loc := Loc{at, at}
	declaration := new(VariableDeclaration, state.allocator)
	declaration.loc = loc
	declaration.kind = .Var
	declaration.declarations = make([dynamic]VariableDeclarator, 0, 4, state.allocator)
	made := class_helper_call(cg, .Async_Iterator, {loop.right}, at)
	for name, index in ([4]string{names.iterator, names.more, names.step, names.error}) {
		id := async_loop_name(cg, name, at)^.(^Identifier)
		declarator := VariableDeclarator{loc = loc, id = id}
		if index == 0 { declarator.init = made }
		append(&declaration.declarations, declarator)
	}

	try := new(TryStatement, state.allocator)
	try.loc = loc
	try.block.loc = loc
	try.block.body = make([dynamic]^Statement, 0, 1, state.allocator)
	append(&try.block.body, kept)
	try.handler = async_loop_catch(cg, names, at)
	try.finalizer = async_loop_finally(cg, names, at)

	block := new(BlockStatement, state.allocator)
	block.loc = loc
	block.body = make([dynamic]^Statement, 0, 2, state.allocator)
	append(&block.body, async_loop_statement(state, declaration), async_loop_statement(state, try))
	return block
}

// `catch (caught) { error = [caught]; }`
async_loop_catch :: proc(cg: ^Codegen, names: AsyncLoopNames, at: u32) -> CatchClause {
	state := cg.transform
	loc := Loc{at, at}
	caught := codegen_fresh_runtime_binding(cg, "caught")
	boxed := new(ArrayExpression, state.allocator)
	boxed.loc = loc
	boxed.elements = make([dynamic]Maybe(^Expression), 0, 1, state.allocator)
	append(&boxed.elements, async_loop_name(cg, caught, at))
	store := target_assign(
		state, async_loop_name(cg, names.error, at), transform_expression(state, boxed), loc,
	)
	handler := CatchClause{loc = loc, param = async_loop_name(cg, caught, at)^.(^Identifier)}
	handler.body.loc = loc
	handler.body.body = make([dynamic]^Statement, 0, 1, state.allocator)
	append(&handler.body.body, class_statement(state, store, at))
	return handler
}

// `finally { try { more && (step = it.close()) && it.check(await step.value); }
//            finally { if (error) throw error[0]; } }`
async_loop_finally :: proc(cg: ^Codegen, names: AsyncLoopNames, at: u32) -> BlockStatement {
	state := cg.transform
	loc := Loc{at, at}
	closed := new(ParenthesizedExpression, state.allocator)
	closed^ = {
		loc = loc,
		expression = target_assign(
			state, async_loop_name(cg, names.step, at), async_loop_call(cg, names, "close", nil, at), loc,
		),
	}
	result := target_member(
		state, async_loop_name(cg, names.step, at), transform_identifier(state, "value", at), false, loc,
	)
	checked := async_loop_call(cg, names, "check", {async_loop_await(cg, result, at)}, at)
	close := target_logical(
		state, .And,
		target_logical(
			state, .And, async_loop_name(cg, names.more, at), transform_expression(state, closed), loc,
		),
		checked, loc,
	)

	zero := new(NumericLiteral, state.allocator)
	zero^ = {loc = loc, value = 0, raw = "0"}
	first := target_member(
		state, async_loop_name(cg, names.error, at), transform_expression(state, zero), true, loc,
	)
	throw := new(ThrowStatement, state.allocator)
	throw^ = {loc = loc, argument = first}
	rethrow := new(IfStatement, state.allocator)
	rethrow^ = {
		loc = loc, test = async_loop_name(cg, names.error, at),
		consequent = async_loop_statement(state, throw),
	}

	inner := new(TryStatement, state.allocator)
	inner.loc = loc
	inner.block.loc = loc
	inner.block.body = make([dynamic]^Statement, 0, 1, state.allocator)
	append(&inner.block.body, class_statement(state, close, at))
	settle := BlockStatement{loc = loc}
	settle.body = make([dynamic]^Statement, 0, 1, state.allocator)
	append(&settle.body, async_loop_statement(state, rethrow))
	inner.finalizer = settle

	finalizer := BlockStatement{loc = loc}
	finalizer.body = make([dynamic]^Statement, 0, 1, state.allocator)
	append(&finalizer.body, async_loop_statement(state, inner))
	return finalizer
}
