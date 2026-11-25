package kessel

import "core:strings"

// Object rest and spread for targets before ES2018.
//
// Spread copies own enumerable properties into the object being built. The
// literal is cut at each spread, and the pieces are folded in order:
//
//     { a, ...b, c }      spread(spread({ a }, b), { c })
//
// Rest takes what a pattern did not name. The pattern is matched against a
// two-step iterator instead of the object: the first step yields the object
// for the named properties, and the second builds the rest, so the rest is
// taken after every named property was read, as the language specifies.
//
//     const { a, ...r } = o;      const [{ a }, r] = rest(o, ["a"]);
//
// This needs no temporary and evaluates the object once, in a declaration,
// an export, or an assignment. A parameter, a loop head and a catch clause
// first bind a plain name and declare the pattern from it in the body. Only
// a rest at the top of a pattern is lowered; a nested one is refused.

// One step for an expression at a target without object rest and spread.
// Functions and classes have their parameter patterns rewritten in place.
rest_lower_expression :: proc(cg: ^Codegen, expr: ^Expression) -> ^Expression {
	#partial switch node in expr^ {
	case ^AssignmentExpression:
		return rest_assignment(cg, node)
	case ^ObjectExpression:
		// Methods are printed without passing through the expression rules.
		for property in node.properties {
			if property.value == nil { continue }
			function, is_function := property.value^.(^FunctionExpression)
			if is_function { rest_function(cg, function) }
		}
		return spread_object(cg, node)
	case ^FunctionExpression:      rest_function(cg, node)
	case ^ArrowFunctionExpression: rest_arrow(cg, node)
	case ^ClassExpression:         rest_class_members(cg, node)
	}
	return nil
}

// The object pattern with a rest element at its top level, or nil.
rest_pattern :: proc(pattern: Pattern) -> ^ObjectPattern {
	object, is_object := pattern.(^ObjectPattern)
	if !is_object || len(object.properties) == 0 { return nil }
	_, has_rest := object.properties[len(object.properties) - 1].value.(^RestElement)
	return object if has_rest else nil
}

// Splits `{ a, b: c, ...r }` into `[{ a, b: c }, r]` and the list of keys the
// rest must leave out. False, with a diagnostic, for a computed key, whose
// value would have to be kept between the pattern and the rest.
rest_split :: proc(cg: ^Codegen, object: ^ObjectPattern) -> (
	pattern: Pattern, keys: ^Expression, ok: bool,
) {
	state := cg.transform
	at := object.loc.start
	rest := pop(&object.properties).value.(^RestElement)
	list := new(ArrayExpression, state.allocator)
	list.loc = {at, at}
	list.elements = make([dynamic]Maybe(^Expression), 0, len(object.properties), state.allocator)
	for property in object.properties {
		key, keyed := property.key.?
		if !keyed { continue }
		switch name in key {
		case IdentifierName:  append(&list.elements, class_string(state, name.name, at))
		case ^StringLiteral:  append(&list.elements, class_string(state, name.value, at))
		case ^NumericLiteral: append(&list.elements, transform_expression(state, name))
		case ^Expression:
			cg_strip_unsupported(
				cg, property.loc, "object rest after a computed key cannot be lowered",
			)
			return nil, nil, false
		}
	}
	pair := new(ArrayPattern, state.allocator)
	pair.loc = object.loc
	elements := make([]Maybe(Pattern), 2, state.allocator)
	elements[0] = Pattern(object)
	elements[1] = rest.argument
	pair.elements = elements
	return pair, transform_expression(state, list), true
}

rest_declaration :: proc(cg: ^Codegen, declaration: ^VariableDeclaration) {
	state := cg.transform
	if state.target >= .ES2018 { return }
	for &declarator in declaration.declarations {
		object := rest_pattern(declarator.id)
		init, initialized := declarator.init.?
		if object != nil && initialized && init != nil {
			pattern, keys, ok := rest_split(cg, object)
			if !ok { return }
			declarator.id = pattern
			declarator.init = class_helper_call(cg, .Rest_Pair, {init, keys}, object.loc.start)
		}
		target_check_pattern(cg, declarator.id)
	}
}

// `const <pattern> = <name>;` as a statement, to be lowered when it prints.
rest_bind :: proc(
	cg: ^Codegen, kind: VariableKind, pattern: Pattern, name: string, at: u32,
) -> ^Statement {
	state := cg.transform
	declaration := new(VariableDeclaration, state.allocator)
	declaration.loc = {at, at}
	declaration.kind = kind
	declaration.declarations = make([dynamic]VariableDeclarator, 0, 1, state.allocator)
	append(&declaration.declarations, VariableDeclarator{
		loc = {at, at}, id = pattern, init = transform_identifier(state, name, at),
	})
	statement := new(Statement, state.allocator)
	statement^ = declaration
	return statement
}

// A loop over `for (const { a, ...r } of xs) body` binds a plain name and
// declares the pattern in a block around the body. The body keeps a block of
// its own, because it may redeclare a name the head binds.
rest_loop_head :: proc(
	cg: ^Codegen,
	left_decl: ^Maybe(^VariableDeclaration), left_expr: ^Maybe(^Expression), body: ^^Statement,
) {
	state := cg.transform
	if state.target >= .ES2018 { return }
	first: ^Statement
	name: string
	at := get_statement_loc(body^).start
	if declaration, declared := left_decl^.?; declared {
		if len(declaration.declarations) != 1 { return }
		declarator := &declaration.declarations[0]
		if rest_pattern(declarator.id) == nil {
			target_check_pattern(cg, declarator.id)
			return
		}
		name = codegen_fresh_runtime_binding(cg, "item")
		first = rest_bind(cg, declaration.kind, declarator.id, name, at)
		declarator.id = transform_identifier(state, name, at)^.(^Identifier)
	} else if target, written := left_expr^.?; written {
		if !rest_is_target(cg, target) { return }
		name = codegen_fresh_runtime_binding(cg, "item")
		store := target_assign(state, target, transform_identifier(state, name, at), {at, at})
		first = class_statement(state, store, at)
		head := rest_bind(
			cg, .Const, transform_identifier(state, name, at)^.(^Identifier), name, at,
		)
		declaration := head^.(^VariableDeclaration)
		declaration.declarations[0].init = nil
		left_decl^ = declaration
		left_expr^ = nil
	} else {
		return
	}
	block := new(BlockStatement, state.allocator)
	block.loc = {at, at}
	block.body = make([dynamic]^Statement, 0, 2, state.allocator)
	inner := body^
	if _, is_block := inner^.(^BlockStatement); !is_block {
		wrapped := new(BlockStatement, state.allocator)
		wrapped.loc = {at, at}
		wrapped.body = make([dynamic]^Statement, 0, 1, state.allocator)
		append(&wrapped.body, inner)
		inner = new(Statement, state.allocator)
		inner^ = wrapped
	}
	append(&block.body, first, inner)
	outer := new(Statement, state.allocator)
	outer^ = block
	body^ = outer
}

rest_catch :: proc(cg: ^Codegen, handler: ^CatchClause) {
	state := cg.transform
	if state.target >= .ES2018 { return }
	param, bound := handler.param.?
	if !bound { return }
	if rest_pattern(param) == nil {
		target_check_pattern(cg, param)
		return
	}
	at := handler.body.loc.start
	name := codegen_fresh_runtime_binding(cg, "error")
	statements := make([dynamic]^Statement, 0, len(handler.body.body) + 1, state.allocator)
	append(&statements, rest_bind(cg, .Let, param, name, at))
	append(&statements, ..handler.body.body[:])
	handler.body.body = statements
	handler.param = transform_identifier(state, name, at)^.(^Identifier)
}

// A parameter `{ a, ...r }` becomes a plain parameter, and the pattern is
// declared from it at the start of the body. Later parameters must not have
// initializers, which could read the names the pattern binds.
rest_params :: proc(cg: ^Codegen, params: []FunctionParameter, body: ^FunctionBody) {
	state := cg.transform
	if state.target >= .ES2018 { return }
	bindings := make([dynamic]^Statement, 0, 2, context.temp_allocator)
	for &param, index in params {
		if rest_pattern(param.pattern) == nil {
			target_check_pattern(cg, param.pattern)
			continue
		}
		for later in params[index + 1:] {
			if later.default_val != nil {
				what := "object rest in a parameter before one with an initializer is not lowered"
				cg_strip_unsupported(cg, param.loc, what)
				return
			}
		}
		at := body.loc.start
		name := codegen_fresh_runtime_binding(cg, "param")
		append(&bindings, rest_bind(cg, .Var, param.pattern, name, at))
		param.pattern = transform_identifier(state, name, at)^.(^Identifier)
	}
	if len(bindings) == 0 { return }
	// The pattern is now bound by `var` when the body starts. A function
	// declared in the body under one of its names would be assigned over,
	// where a parameter of that name is replaced by the function.
	names := make(map[string]bool, 8, context.temp_allocator)
	for binding in bindings {
		rest_bound_names(binding^.(^VariableDeclaration).declarations[0].id, &names)
	}
	for statement in body.body {
		function, declared := statement^.(^FunctionDeclaration)
		if !declared { continue }
		if id, named := function.id.?; named && names[id.name] {
			what := "object rest in a parameter that a function in the body redeclares is not lowered"
			cg_strip_unsupported(cg, function.loc, what)
			return
		}
	}
	directives := min(len(body.directives), len(body.body))
	statements := make([dynamic]^Statement, 0, len(body.body) + len(bindings), state.allocator)
	append(&statements, ..body.body[:directives])
	append(&statements, ..bindings[:])
	append(&statements, ..body.body[directives:])
	body.body = statements
}

rest_function :: proc(cg: ^Codegen, function: ^FunctionExpression) {
	if function == nil || function.no_body { return }
	rest_params(cg, function.params[:], &function.body)
}

rest_arrow :: proc(cg: ^Codegen, arrow: ^ArrowFunctionExpression) {
	state := cg.transform
	if state.target >= .ES2018 { return }
	needed := false
	for param in arrow.params { needed ||= rest_pattern(param.pattern) != nil }
	if !needed {
		for param in arrow.params { target_check_pattern(cg, param.pattern) }
		return
	}
	body := FunctionBody{loc = arrow.loc}
	block: ^BlockStatement
	switch inner in arrow.body {
	case ^BlockStatement:
		block = inner
		body.loc = inner.loc
		body.body = inner.body
	case ^Expression:
		// The pattern needs a statement, so the expression is returned from a block.
		at := loc_from_expr(inner).start
		result := new(ReturnStatement, state.allocator)
		result^ = {loc = {at, at}, argument = inner}
		statement := new(Statement, state.allocator)
		statement^ = result
		body.body = make([dynamic]^Statement, 0, 2, state.allocator)
		append(&body.body, statement)
		block = new(BlockStatement, state.allocator)
		block.loc = {at, at}
		arrow.body = block
		arrow.expression = false
	}
	rest_params(cg, arrow.params[:], &body)
	block.body = body.body
}

// Methods are printed without passing through the expression rules, so the
// class or object that holds them lowers their parameters.
rest_class_members :: proc(cg: ^Codegen, class: ^ClassExpression) {
	if cg.transform.target >= .ES2018 { return }
	for element in class.body.body {
		if element.kind == .Field || element.kind == .StaticBlock { continue }
		value, present := element.value.?
		if !present || value == nil { continue }
		if function, ok := value^.(^FunctionExpression); ok { rest_function(cg, function) }
	}
}

// True when the expression is `{ ..., ...r }` used as an assignment target.
rest_is_target :: proc(cg: ^Codegen, target: ^Expression) -> bool {
	object, is_object := target_unwrap(cg, target)^.(^ObjectExpression)
	if !is_object || len(object.properties) == 0 { return false }
	_, spread := object.properties[len(object.properties) - 1].value^.(^SpreadElement)
	return spread
}

// A rest below the top of an assignment target is not lowered. Left alone it
// would be printed through the rule for spread, which builds a value.
rest_reject_nested :: proc(cg: ^Codegen, target: ^Expression, top: bool) {
	if target == nil { return }
	inner := target_unwrap(cg, target)
	#partial switch node in inner^ {
	case ^ObjectExpression:
		for property, index in node.properties {
			if property.value == nil { continue }
			if spread, is_spread := property.value^.(^SpreadElement); is_spread {
				if !top || index != len(node.properties) - 1 {
					cg_strip_unsupported(cg, spread.loc, "nested object rest cannot be lowered")
				}
				continue
			}
			rest_reject_nested(cg, property.value, false)
		}
	case ^ArrayExpression:
		for element in node.elements {
			if item, present := element.?; present { rest_reject_nested(cg, item, false) }
		}
	case ^AssignmentExpression: rest_reject_nested(cg, node.left, false)
	case ^SpreadElement:        rest_reject_nested(cg, node.argument, false)
	}
}

// `({ a, ...r } = o)` becomes `((s) => ([{ a }, r] = rest(s, ["a"]), s))(o)`.
// The arrow keeps the value of the assignment and needs no temporary.
rest_assignment :: proc(cg: ^Codegen, node: ^AssignmentExpression) -> ^Expression {
	state := cg.transform
	if state.target >= .ES2018 || node.operator != .Assign { return nil }
	left := target_unwrap(cg, node.left)
	#partial switch _ in left^ {
	case ^ObjectExpression, ^ArrayExpression:
	case: return nil
	}
	rest_reject_nested(cg, left, true)
	if cg.strip_diag != nil || !rest_is_target(cg, left) { return nil }
	object := left^.(^ObjectExpression)
	loc := node.loc
	at := loc.start
	text := cg.source[object.loc.start:min(object.loc.end, u32(len(cg.source)))]
	if strings.contains(text, "await") || strings.contains(text, "yield") {
		cg_strip_unsupported(
			cg, object.loc, "await or yield in a pattern with object rest cannot be lowered",
		)
		return nil
	}
	rest := pop(&object.properties).value^.(^SpreadElement)
	keys := new(ArrayExpression, state.allocator)
	keys.loc = {at, at}
	keys.elements = make([dynamic]Maybe(^Expression), 0, len(object.properties), state.allocator)
	for property in object.properties {
		if property.computed {
			cg_strip_unsupported(
				cg, property.loc, "object rest after a computed key cannot be lowered",
			)
			return nil
		}
		#partial switch key in property.key^ {
		case ^Identifier: append(&keys.elements, class_string(state, key.name, at))
		case:             append(&keys.elements, property.key)
		}
	}
	pair := new(ArrayExpression, state.allocator)
	pair.loc = object.loc
	pair.elements = make([dynamic]Maybe(^Expression), 0, 2, state.allocator)
	append(&pair.elements, left, rest.argument)
	source := codegen_fresh_runtime_binding(cg, "source")
	taken := class_helper_call(
		cg, .Rest_Pair,
		{transform_identifier(state, source, at), transform_expression(state, keys)}, at,
	)
	sequence := new(SequenceExpression, state.allocator)
	sequence.loc = loc
	sequence.expressions = make([dynamic]^Expression, 0, 2, state.allocator)
	append(
		&sequence.expressions, target_assign(state, transform_expression(state, pair), taken, loc),
	)
	append(&sequence.expressions, transform_identifier(state, source, at))
	arrow := new(ArrowFunctionExpression, state.allocator)
	arrow^ = {loc = {at, at}, body = transform_expression(state, sequence), expression = true}
	arrow.params = make([dynamic]FunctionParameter, 0, 1, state.allocator)
	append(&arrow.params, FunctionParameter{
		loc = {at, at}, pattern = transform_identifier(state, source, at)^.(^Identifier),
	})
	return target_call(state, transform_expression(state, arrow), {node.right}, loc)
}

// `{ a, ...b, c }` as a value. Returns nil when the literal has no spread.
spread_object :: proc(cg: ^Codegen, node: ^ObjectExpression) -> ^Expression {
	state := cg.transform
	if state.target >= .ES2018 { return nil }
	found := false
	for property in node.properties {
		if property.value == nil { continue }
		_, spread := property.value^.(^SpreadElement)
		found ||= spread
	}
	if !found { return nil }
	at := node.loc.start
	result: ^Expression
	piece: ^ObjectExpression
	open :: proc(state: ^TransformState, loc: Loc) -> ^ObjectExpression {
		piece := new(ObjectExpression, state.allocator)
		piece.loc = loc
		piece.properties = make([dynamic]Property, 0, 4, state.allocator)
		return piece
	}
	piece = open(state, node.loc)
	for property in node.properties {
		spread, is_spread := property.value^.(^SpreadElement)
		if !is_spread {
			if result != nil && !spread_property_copies(cg, property) { return nil }
			append(&piece.properties, property)
			continue
		}
		// Close the piece collected so far, then copy the spread value in.
		if result == nil {
			result = transform_expression(state, piece)
		} else if len(piece.properties) != 0 {
			result = class_helper_call(
				cg, .Object_Spread, {result, transform_expression(state, piece)}, at,
			)
		}
		piece = open(state, {at, at})
		result = class_helper_call(cg, .Object_Spread, {result, spread.argument}, at)
	}
	if len(piece.properties) != 0 {
		result = class_helper_call(
			cg, .Object_Spread, {result, transform_expression(state, piece)}, at,
		)
	}
	return result
}

// A property written after a spread reaches the result by being copied from
// a literal of its own. That is the same as defining it for a plain value or
// a method, but an accessor would be read instead of defined, and
// `__proto__: v` would set the prototype of the wrong object.
spread_property_copies :: proc(cg: ^Codegen, property: Property) -> bool {
	if property.kind == .Get || property.kind == .Set {
		cg_strip_unsupported(
			cg, property.loc, "an accessor after an object spread cannot be lowered",
		)
		return false
	}
	name := ""
	if !property.computed && !property.shorthand && property.key != nil {
		#partial switch key in property.key^ {
		case ^Identifier:    name = key.name
		case ^StringLiteral: name = key.value
		}
	}
	if name == "__proto__" {
		cg_strip_unsupported(cg, property.loc, "__proto__ after an object spread cannot be lowered")
		return false
	}
	return true
}

// The names a binding pattern declares. Patterns nest no deeper than the parser allows.
rest_bound_names :: proc(pattern: Pattern, names: ^map[string]bool) {
	switch node in pattern {
	case ^Identifier:        names[node.name] = true
	case ^ObjectPattern:
		for property in node.properties { rest_bound_names(property.value, names) }
	case ^ArrayPattern:
		for element in node.elements {
			if inner, present := element.?; present { rest_bound_names(inner, names) }
		}
	case ^AssignmentPattern: rest_bound_names(node.left, names)
	case ^RestElement:       rest_bound_names(node.argument, names)
	case ^MemberExpression:
	}
}
