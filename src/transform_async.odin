package kessel

// Async functions for targets before ES2017.
//
// The body moves into a generator, where every `await` is a `yield`, and a
// helper drives the generator from a promise:
//
//     async function f(a, b = 1) {        function f(p) {
//       return (await a) + b;               return run(this, arguments, function* (a, b = 1) {
//     }                                       return (yield a) + b;
//                                           });
//                                         }
//
// The parameters move with the body. An error in a default value or a
// pattern then rejects the promise, as it does in an async function, and a
// `var` in the body still shares its binding with a parameter of the same
// name. The outer function keeps as many plain parameters as the original
// had before its first default or rest, so `length` is unchanged; `name` is
// unchanged because the outer function stands where the original stood.
//
// A generator has its own `this` and `arguments`, and cannot contain `super`
// or see the `new.target` around an arrow. `this` and, for an ordinary
// function, `arguments` are handed to the generator by the helper. What an
// arrow takes from its surroundings is captured in the outer arrow, before
// the generator starts:
//
//     async (a) => arguments[0] + a       (p) => {
//                                           var args = arguments;
//                                           return run(void 0, [p], function* (a) {
//                                             return args[0] + a;
//                                           });
//                                         }
//
// `super.x` is reached through a reference object made by two arrows that
// still stand in the method: `ref("x").value` reads and writes the property
// with the method's own `this`, in every position a property can stand.
//
// The function is rewritten in place when it is first offered to the
// printer; its `await`s and captured names are replaced as they print.

AsyncScan :: struct {
	cg:        ^Codegen,
	root:      rawptr,         // The function being lowered.
	arrow:     bool,           // The root takes `arguments` and `new.target` from outside.
	method:    bool,           // The root may contain `super`.
	fields:    [dynamic]Loc,   // Class field initializers around the current node.
	generator: bool,           // The root is an async generator; its suspensions are marked.
	arrows:    int,            // Arrows between the root and the current node.
	uses_this: bool,
	arguments: string,         // Capture bindings; empty until one is needed.
	target:    string,
	super:     string,
}

// One step for an expression at a target without async functions. Functions
// are rewritten in place; nil means the expression prints as it now is.
async_lower_expression :: proc(cg: ^Codegen, expr: ^Expression) -> ^Expression {
	state := cg.transform
	assert(state.target < .ES2018)
	#partial switch node in expr^ {
	case ^FunctionExpression:
		async_function(cg, node, false)
	case ^ArrowFunctionExpression:
		async_arrow(cg, node)
	case ^ObjectExpression:
		// Methods are printed without passing through the expression rules.
		for property in node.properties {
			if property.kind != .Method || property.value == nil { continue }
			if function, ok := property.value^.(^FunctionExpression); ok {
				async_function(cg, function, true)
			}
		}
	case ^ClassExpression:
		async_class_members(cg, node)
	case ^YieldExpression:
		if state.async_marks[rawptr(node)] { return async_generator_yield(cg, node) }
	case ^AwaitExpression:
		if state.async_marks[rawptr(node)] {
			return async_generator_await(cg, node.argument, node.loc)
		}
		// Outside a function it is a top-level await, which the caller refuses.
		if state.target >= .ES2017 || !target_inside_function(cg, node.loc.start) { return nil }
		yield := new(YieldExpression, state.allocator)
		yield^ = {loc = node.loc, argument = node.argument}
		return transform_expression(state, yield)
	case ^MemberExpression:
		return async_super_member(cg, node)
	case ^CallExpression:
		return async_super_call(cg, node)
	case ^NewExpression:
		return async_super_new(cg, node)
	case ^MetaProperty:
		if name, captured := state.async_targets[node.loc.start]; captured {
			return transform_identifier(state, name, node.loc.end)
		}
	}
	return nil
}

// An async function declared in a block is scoped to the block. An ordinary
// function declared there is, in sloppy code, also assigned to a `var` of the
// enclosing function when the block runs, so the lowered declaration would
// be visible, and replace a binding, where the original was not.
async_declaration :: proc(cg: ^Codegen, function: ^FunctionExpression) {
	state := cg.transform
	if function == nil || !function.async { return }
	if state.target >= (TransformTarget.ES2018 if function.generator else .ES2017) { return }
	if id, named := function.id.?; named {
		if state.async_block_functions == nil {
			model := transform_model(cg)
			state.async_block_functions = make(map[u32]bool, 8, state.allocator)
			for symbol in model.symbols {
				if .Function not_in symbol.kinds { continue }
				scope := model.scopes[symbol.decl_scope]
				if scope.strict { continue }
				if scope.kind == .Block || scope.kind == .Switch {
					state.async_block_functions[symbol.decl_start] = true
				}
			}
		}
		if state.async_block_functions[id.loc.start] {
			what := "an async function declared in a block of sloppy code cannot be lowered"
			cg_strip_unsupported(cg, function.loc, what)
			return
		}
	}
	async_function(cg, function, false)
}

async_class_members :: proc(cg: ^Codegen, class: ^ClassExpression) {
	if cg.transform.target >= .ES2018 { return }
	for element in class.body.body {
		if element.kind != .Method { continue }
		value, present := element.value.?
		if !present || value == nil { continue }
		if function, ok := value^.(^FunctionExpression); ok { async_function(cg, function, true) }
	}
}

// Rewrites an async function, declaration or method in place.
async_function :: proc(cg: ^Codegen, function: ^FunctionExpression, method: bool) {
	state := cg.transform
	if function == nil || !function.async || function.no_body { return }
	// Async generators arrived one edition after async functions.
	if state.target >= (TransformTarget.ES2018 if function.generator else .ES2017) { return }
	scan := AsyncScan{cg = cg, root = function, method = method, generator = function.generator}
	box: Expression = function
	if !async_scan_run(&scan, &box) { return }
	at := function.body.loc.start
	directives := async_directive_count(function.body.body[:])
	generator := new(FunctionExpression, state.allocator)
	generator^ = {loc = function.loc, params = function.params, generator = true}
	generator.body.loc = function.body.loc
	generator.body.body = make(
		[dynamic]^Statement, 0, len(function.body.body) - directives, state.allocator,
	)
	append(&generator.body.body, ..function.body.body[directives:])

	// A directive governs the outer function too, which decides what `this`
	// is when the caller passed none.
	body := make([dynamic]^Statement, 0, directives + 2, state.allocator)
	append(&body, ..function.body.body[:directives])
	if captures := async_captures(&scan, at); captures != nil { append(&body, captures) }
	arguments := transform_identifier(state, "arguments", at)
	driver := TransformHelper.Async_Generator if function.generator else .Async
	run := async_run(cg, driver, class_this(state, at), arguments, generator, at)
	append(&body, async_return(state, run, at))

	function.async = false
	function.generator = false
	function.params = async_placeholders(cg, function.params[:], at, nil)
	function.body.loc = {at, at}
	function.body.body = body
	assert(!function.async)
	assert(!function.generator)
	assert(generator.generator)
}

// The statements of a directive prologue, which the parser marks.
async_directive_count :: proc(body: []^Statement) -> int {
	for statement, index in body {
		if statement == nil { return index }
		expression, plain := statement^.(^ExpressionStatement)
		if !plain || expression.directive == "" { return index }
	}
	return len(body)
}

// Rewrites an async arrow function in place.
async_arrow :: proc(cg: ^Codegen, arrow: ^ArrowFunctionExpression) {
	state := cg.transform
	if arrow == nil || !arrow.async || state.target >= .ES2017 { return }
	scan := AsyncScan{cg = cg, root = arrow, arrow = true}
	box: Expression = arrow
	if !async_scan_run(&scan, &box) { return }
	at := arrow.loc.start
	generator := new(FunctionExpression, state.allocator)
	generator^ = {loc = arrow.loc, params = arrow.params, generator = true}
	switch body in arrow.body {
	case ^BlockStatement:
		generator.body.loc = body.loc
		generator.body.body = body.body
	case ^Expression:
		generator.body.loc = loc_from_expr(body)
		generator.body.body = make([dynamic]^Statement, 0, 1, state.allocator)
		append(&generator.body.body, async_return(state, body, generator.body.loc.start))
	}

	// The arrow has no `arguments` of its own to forward, so it passes on
	// exactly the values it was called with.
	passed := new(ArrayExpression, state.allocator)
	passed.loc = {at, at}
	passed.elements = make([dynamic]Maybe(^Expression), 0, len(arrow.params), state.allocator)
	arrow.params = async_placeholders(cg, arrow.params[:], at, passed)
	// `this` is in its temporal dead zone in a derived constructor before
	// `super()` returns, so an arrow that never reads it must not either.
	receiver := class_this(state, at) if scan.uses_this else target_void(state, {at, at})
	run := async_run(cg, .Async, receiver, transform_expression(state, passed), generator, at)
	arrow.async = false
	captures := async_captures(&scan, at)
	if captures == nil {
		arrow.body = run
		arrow.expression = true
		return
	}
	block := new(BlockStatement, state.allocator)
	block.loc = {at, at}
	block.body = make([dynamic]^Statement, 0, 2, state.allocator)
	append(&block.body, captures, async_return(state, run, at))
	arrow.body = block
	arrow.expression = false
}

// The parameters of the outer function: one plain name for each parameter
// that counts towards `length`. With `passed`, the function is an arrow and
// must also name what it forwards, including any arguments beyond those.
async_placeholders :: proc(
	cg: ^Codegen, params: []FunctionParameter, at: u32, passed: ^ArrayExpression,
) -> [dynamic]FunctionParameter {
	state := cg.transform
	outer := make([dynamic]FunctionParameter, 0, len(params) + 1, state.allocator)
	// A TypeScript `this` parameter is erased and never counted.
	written := params
	if len(written) > 0 {
		if id, plain := written[0].pattern.(^Identifier); plain && id.name == "this" {
			written = written[1:]
		}
	}
	counted := 0
	for param in written {
		if _, rest := param.pattern.(^RestElement); rest || param.default_val != nil { break }
		counted += 1
	}
	remaining := len(written) > counted
	for _ in 0..<counted {
		name := codegen_fresh_runtime_binding(cg, "p")
		pattern := transform_identifier(state, name, at)^.(^Identifier)
		append(&outer, FunctionParameter{loc = {at, at}, pattern = pattern})
		if passed != nil { append(&passed.elements, transform_identifier(state, name, at)) }
	}
	if passed != nil && remaining {
		name := codegen_fresh_runtime_binding(cg, "rest")
		rest := new(RestElement, state.allocator)
		rest^ = {loc = {at, at}, argument = transform_identifier(state, name, at)^.(^Identifier)}
		append(&outer, FunctionParameter{loc = {at, at}, pattern = rest})
		spread := new(SpreadElement, state.allocator)
		spread^ = {loc = {at, at}, argument = transform_identifier(state, name, at)}
		append(&passed.elements, transform_expression(state, spread))
	}
	return outer
}

async_run :: proc(
	cg: ^Codegen, driver: TransformHelper, receiver, arguments: ^Expression,
	generator: ^FunctionExpression, at: u32,
) -> ^Expression {
	state := cg.transform
	assert(generator.generator)
	assert(!generator.async)
	body := transform_expression(state, generator)
	return class_helper_call(cg, driver, {receiver, arguments, body}, at)
}

async_return :: proc(state: ^TransformState, value: ^Expression, at: u32) -> ^Statement {
	assert(value != nil)
	node := new(ReturnStatement, state.allocator)
	node^ = {loc = {at, at}, argument = value}
	statement := new(Statement, state.allocator)
	statement^ = node
	return statement
}

// `var args = arguments, target = new.target, ref = make(...);` for what the
// scan found, or nil when the generator needs nothing from outside.
async_captures :: proc(scan: ^AsyncScan, at: u32) -> ^Statement {
	cg := scan.cg
	state := cg.transform
	if scan.arguments == "" && scan.target == "" && scan.super == "" { return nil }
	declaration := new(VariableDeclaration, state.allocator)
	declaration.loc = {at, at}
	declaration.kind = .Var
	declaration.declarations = make([dynamic]VariableDeclarator, 0, 3, state.allocator)
	bind :: proc(
		state: ^TransformState, declaration: ^VariableDeclaration, name: string, value: ^Expression,
		at: u32,
	) {
		id := transform_identifier(state, name, at)^.(^Identifier)
		append(&declaration.declarations, VariableDeclarator{loc = {at, at}, id = id, init = value})
	}
	if scan.arguments != "" {
		bind(state, declaration, scan.arguments, transform_identifier(state, "arguments", at), at)
	}
	if scan.target != "" {
		meta := new(MetaProperty, state.allocator)
		free := transform_free_offset(cg.source, at)
		meta^ = {
			loc = {free, free},
			meta = {loc = {free, free}, name = "new"},
			property = {loc = {free, free}, name = "target"},
		}
		bind(state, declaration, scan.target, transform_expression(state, meta), at)
	}
	if scan.super != "" {
		read := async_super_arrow(cg, at, false)
		write := async_super_arrow(cg, at, true)
		made := class_helper_call(cg, .Async_Super, {read, write}, at)
		bind(state, declaration, scan.super, made, at)
	}
	statement := new(Statement, state.allocator)
	statement^ = declaration
	return statement
}

// `(key) => super[key]` or `(key, value) => super[key] = value`. An arrow
// keeps the `super` and the `this` of the method it stands in.
async_super_arrow :: proc(cg: ^Codegen, at: u32, write: bool) -> ^Expression {
	state := cg.transform
	// Not on a `super` of the source, which the printer would replace.
	free := transform_free_offset(cg.source, at)
	parent := new(Super, state.allocator)
	parent.loc = {free, free}
	key := codegen_fresh_runtime_binding(cg, "key")
	arrow := new(ArrowFunctionExpression, state.allocator)
	arrow^ = {loc = {at, at}, expression = true}
	arrow.params = make([dynamic]FunctionParameter, 0, 2, state.allocator)
	append(&arrow.params, FunctionParameter{
		loc = {at, at}, pattern = transform_identifier(state, key, at)^.(^Identifier),
	})
	member := target_member(
		state, transform_expression(state, parent), transform_identifier(state, key, at), true,
		{free, free},
	)
	if !write {
		arrow.body = member
		return transform_expression(state, arrow)
	}
	value := codegen_fresh_runtime_binding(cg, "value")
	append(&arrow.params, FunctionParameter{
		loc = {at, at}, pattern = transform_identifier(state, value, at)^.(^Identifier),
	})
	arrow.body = target_assign(state, member, transform_identifier(state, value, at), {free, free})
	return transform_expression(state, arrow)
}

// `super.x` in a lowered function becomes `ref("x").value`.
async_super_member :: proc(cg: ^Codegen, node: ^MemberExpression) -> ^Expression {
	state := cg.transform
	if node.object == nil || node.property == nil { return nil }
	parent, is_super := node.object^.(^Super)
	if !is_super { return nil }
	name, captured := state.async_supers[parent.loc.start]
	if !captured { return nil }
	at := node.loc.end
	key := node.property
	if !node.computed {
		id, plain := key^.(^Identifier)
		assert(plain)
		key = class_string(state, id.name, at)
	}
	reference := target_call(state, transform_identifier(state, name, at), {key}, node.loc)
	return target_member(state, reference, transform_identifier(state, "value", at), false, node.loc)
}

// `super.m(a)` calls the method with the receiver of the method around it:
// `ref("m").value.call(this, a)`.
async_super_call :: proc(cg: ^Codegen, node: ^CallExpression) -> ^Expression {
	state := cg.transform
	if node.callee == nil || len(state.async_supers) == 0 { return nil }
	member, is_member := target_unwrap(cg, node.callee)^.(^MemberExpression)
	if !is_member { return nil }
	method := async_super_member(cg, member)
	if method == nil { return nil }
	at := node.loc.end
	call := new(CallExpression, state.allocator)
	call^ = node^
	call.optional = false
	name := transform_identifier(state, "call", at)
	call.callee = target_member(state, method, name, false, node.loc)
	call.arguments = make([dynamic]^Expression, 0, len(node.arguments) + 1, state.allocator)
	append(&call.arguments, class_this(state, at))
	append(&call.arguments, ..node.arguments[:])
	return transform_expression(state, call)
}

// `new super.x()` constructs the property. Its replacement contains a call,
// which would take the arguments of `new` unless the callee is grouped.
async_super_new :: proc(cg: ^Codegen, node: ^NewExpression) -> ^Expression {
	state := cg.transform
	if node.callee == nil || len(state.async_supers) == 0 { return nil }
	base := node.callee
	for base != nil {
		member, is_member := base^.(^MemberExpression)
		if !is_member { break }
		base = member.object
	}
	if base == nil { return nil }
	parent, is_super := base^.(^Super)
	if !is_super || !(parent.loc.start in state.async_supers) { return nil }
	group := new(ParenthesizedExpression, state.allocator)
	group^ = {loc = loc_from_expr(node.callee), expression = node.callee}
	created := new(NewExpression, state.allocator)
	created^ = node^
	created.callee = transform_expression(state, group)
	return transform_expression(state, created)
}

// ----------------------------------------------------------------------------
// The scan: what one function takes from its surroundings.
// ----------------------------------------------------------------------------

// Walks the function, through arrows but not into ordinary functions, which
// have a `this`, `arguments` and `super` of their own. False, with a
// diagnostic, for a shape that cannot be lowered. The walker loops along
// operator, member and call chains, so their length does not matter.
async_scan_run :: proc(scan: ^AsyncScan, root: ^Expression) -> bool {
	cg := scan.cg
	assert(scan.root != nil)
	if cg.strip_diag != nil { return false }
	// The model must describe the tree as written, before any of it moves.
	async_index_arguments(cg)
	scan.fields = make([dynamic]Loc, 0, 4, context.temp_allocator)
	visitor := AstVisitor{user = scan, enter = async_scan_enter, leave = async_scan_leave}
	status := ast_walk_expression_tree(root, visitor, context.temp_allocator)
	if status == .DepthExceeded || status == .OutOfMemory {
		what := "this async function nests too deeply to lower"
		cg_strip_unsupported(cg, loc_from_expr(root), what)
	}
	if status == .Completed { assert(len(scan.fields) == 0) }
	return cg.strip_diag == nil
}

// Every free use of `arguments`, and whether a function around it supplies one.
async_index_arguments :: proc(cg: ^Codegen) {
	state := cg.transform
	if state.async_arguments != nil { return }
	model := transform_model(cg)
	state.async_arguments = make(map[u32]bool, 8, state.allocator)
	for ref in model.refs {
		if ref.name != "arguments" || ref.resolved != SYMBOL_UNRESOLVED { continue }
		state.async_arguments[ref.start] = model.scopes[ref.scope].implicit_arguments
	}
}

// A field initializer runs as a method of its own: its `this`, `super` and
// `new.target` are not those of the function around the class.
async_scan_owns :: proc(scan: ^AsyncScan, offset: u32) -> bool {
	for range in scan.fields {
		if range.start <= offset && offset < range.end { return false }
	}
	return true
}

async_scan_field :: proc(element: ^ClassElement) -> (range: Loc, found: bool) {
	if element.kind != .Field { return {}, false }
	value, present := element.value.?
	if !present || value == nil { return {}, false }
	return loc_from_expr(value), true
}

async_scan_leave :: proc(user: rawptr, node: AstNode) {
	scan := cast(^AsyncScan)user
	#partial switch value in node {
	case ^ClassElement:
		if _, found := async_scan_field(value); found { pop(&scan.fields) }
	case ^ArrowFunctionExpression:
		if rawptr(value) != scan.root { scan.arrows -= 1 }
	}
}

async_scan_enter :: proc(user: rawptr, node: AstNode) -> AstWalkAction {
	scan := cast(^AsyncScan)user
	cg := scan.cg
	state := cg.transform
	#partial switch value in node {
	case ^FunctionExpression:
		return .Continue if rawptr(value) == scan.root else .Skip
	case ^ArrowFunctionExpression:
		if rawptr(value) != scan.root { scan.arrows += 1 }
	case ^AwaitExpression:
		// One in a nested async arrow belongs to that arrow.
		if scan.generator && scan.arrows == 0 { state.async_marks[rawptr(value)] = true }
	case ^YieldExpression:
		if scan.generator && scan.arrows == 0 { state.async_marks[rawptr(value)] = true }
	case ^ReturnStatement:
		if scan.generator && scan.arrows == 0 { async_generator_return(cg, value) }
	case ^ClassElement:
		if range, found := async_scan_field(value); found { append(&scan.fields, range) }
	case ^ThisExpression:
		if async_scan_owns(scan, value.loc.start) { scan.uses_this = true }
	case ^Identifier:
		async_scan_arguments(scan, value)
	case ^MetaProperty:
		at := value.loc.start
		if !scan.arrow || value.meta.name != "new" || !async_scan_owns(scan, at) { break }
		// An outer arrow that was lowered first has already captured it.
		if at in state.async_targets { break }
		if scan.target == "" { scan.target = codegen_fresh_runtime_binding(cg, "target") }
		state.async_targets[at] = scan.target
	case ^Super:
		at := value.loc.start
		if !async_scan_owns(scan, at) { break }
		// A super property is read, written and called with the method's `this`.
		scan.uses_this = true
		// An outer function that was lowered first has already captured it.
		if at in state.async_supers { break }
		if scan.super == "" { scan.super = codegen_fresh_runtime_binding(cg, "super") }
		state.async_supers[at] = scan.super
	case ^CallExpression:
		async_scan_call(scan, value)
	case ^UnaryExpression:
		if value.operator == .Delete && async_scan_is_super(scan, value.argument) {
			what := "delete of a super property in an async function cannot be lowered"
			cg_strip_unsupported(cg, value.loc, what)
		}
	case ^TaggedTemplateExpression:
		if async_scan_is_super(scan, value.tag) {
			what := "a super property as a template tag in an async function cannot be lowered"
			cg_strip_unsupported(cg, value.loc, what)
		}
	}
	return .Stop if cg.strip_diag != nil else .Continue
}

async_scan_is_super :: proc(scan: ^AsyncScan, expr: ^Expression) -> bool {
	if expr == nil { return false }
	inner := target_unwrap(scan.cg, expr)
	if inner == nil { return false }
	member, is_member := inner^.(^MemberExpression)
	if !is_member || member.object == nil { return false }
	parent, is_super := member.object^.(^Super)
	return is_super && async_scan_owns(scan, parent.loc.start)
}

async_scan_arguments :: proc(scan: ^AsyncScan, id: ^Identifier) {
	cg := scan.cg
	state := cg.transform
	if !scan.arrow || id.name != "arguments" { return }
	at := id.loc.start
	supplied, free := state.async_arguments[at]
	if !free { return }
	if !supplied {
		// Capturing it would read a global, or fail, where the arrow might not.
		what := "arguments outside a function in an async arrow function cannot be lowered"
		cg_strip_unsupported(cg, id.loc, what)
		return
	}
	// An outer arrow that was lowered first has already captured it.
	if cg.renamed != nil && at in cg.renamed { return }
	if scan.arguments == "" { scan.arguments = codegen_fresh_runtime_binding(cg, "arguments") }
	if cg.renamed == nil { cg.renamed = make(map[u32]string, 8, state.allocator) }
	cg.renamed[at] = scan.arguments
}

async_scan_call :: proc(scan: ^AsyncScan, call: ^CallExpression) {
	cg := scan.cg
	if call.callee == nil { return }
	at := call.loc.start
	#partial switch callee in call.callee^ {
	case ^Super:
		if scan.arrow && async_scan_owns(scan, at) {
			what := "a super call in an async arrow function cannot be lowered"
			cg_strip_unsupported(cg, call.loc, what)
		}
	case ^Identifier:
		// Code given to a direct eval can name `super` and `arguments`, where
		// no rewrite reaches it.
		if callee.name != "eval" || !(scan.arrow || scan.method) { return }
		what := "a direct eval in an async method or arrow function cannot be lowered"
		cg_strip_unsupported(cg, call.loc, what)
	}
}
