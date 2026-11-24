package kessel

import "core:strings"

// Syntax lowering for an ECMAScript target.
//
// The printer offers every expression to transform_lower_expression before
// it prints. A rule answers with an equivalent tree built from older syntax;
// the printer then handles grouping, source maps and the rule's operands,
// which pass through here again when their turn comes.
//
// A value that must be read twice is kept in a temporary. Temporaries are
// `var` bindings declared at the end of the enclosing function body, or of
// the program. Each is written and then read within one expression, with no
// user code in between, so sharing a binding between activations is safe.

TransformTarget :: enum u16 {
	ES2015 = 2015, ES2016, ES2017, ES2018, ES2019, ES2020, ES2021, ES2022, ES2023, ES2024,
	ESNext = 9999,
}

transform_target_parse :: proc(name: string) -> (target: TransformTarget, valid: bool) {
	switch strings.to_lower(name, context.temp_allocator) {
	case "", "esnext": return .ESNext, true
	case "es2015", "es6": return .ES2015, true
	case "es2016": return .ES2016, true
	case "es2017": return .ES2017, true
	case "es2018": return .ES2018, true
	case "es2019": return .ES2019, true
	case "es2020": return .ES2020, true
	case "es2021": return .ES2021, true
	case "es2022": return .ES2022, true
	case "es2023": return .ES2023, true
	case "es2024": return .ES2024, true
	}
	return .ESNext, false
}

// Syntax the target lacks and no rule lowers. Emitting it unchanged would
// produce a file the target cannot parse, so the transform stops instead.
target_require :: proc(cg: ^Codegen, loc: Loc, since: TransformTarget, what: string) {
	if cg.transform.target >= since { return }
	cg_strip_unsupported(cg, loc, what)
}

target_declare_temps :: proc(cg: ^Codegen, temps: []string) {
	if len(temps) == 0 { return }
	cg_indent(cg)
	for temp, index in temps {
		cg_str(cg, "var " if index == 0 else ",")
		if index != 0 { cg_space(cg) }
		cg_str(cg, temp)
	}
	cg_byte(cg, ';')
	cg_newline(cg)
}

// A fresh binding, used at `at`, which is the end of the expression being
// lowered: no identifier of the source starts there, so the printer cannot
// mistake the temporary for a renamed or namespace-qualified reference.
target_temp :: proc(cg: ^Codegen, at: u32) -> ^Expression {
	state := cg.transform
	assert(len(state.temp_scopes) > 0)
	name := codegen_fresh_runtime_binding(cg, "t")
	append(&state.temp_scopes[len(state.temp_scopes) - 1], name)
	return transform_identifier(state, name, at)
}

// True when reading the expression again cannot run code or see a new value.
target_is_stable :: proc(cg: ^Codegen, expr: ^Expression) -> bool {
	#partial switch node in expr^ {
	case ^ThisExpression, ^Super: return true
	case ^Identifier:
		// A global may be an accessor on the global object, so only a
		// binding declared in the file is known to be a plain read.
		state := cg.transform
		if state.local_refs == nil { target_index_local_refs(cg) }
		return state.local_refs[node.loc.start]
	}
	return false
}

target_index_local_refs :: proc(cg: ^Codegen) {
	state := cg.transform
	model := transform_model(cg)
	ambient := make(map[u32]bool, context.temp_allocator)
	target_collect_ambient(state.job.program.body[:], false, &ambient)
	state.local_refs = make(map[u32]bool, len(model.refs), state.allocator)
	for ref in model.refs {
		if ref.resolved == SYMBOL_UNRESOLVED { continue }
		if ambient[model.symbols[ref.resolved].decl_start] { continue }
		state.local_refs[ref.start] = true
	}
}

// `declare` describes a global that exists elsewhere, possibly as an accessor,
// so reading it is not known to be free. Declarations are found at the top
// level and inside namespaces; everything in a `declare namespace` is ambient.
target_collect_ambient :: proc(statements: []^Statement, all: bool, ambient: ^map[u32]bool) {
	for statement in statements {
		if statement == nil { continue }
		declaration := statement^
		if exported, ok := declaration.(^ExportNamedDeclaration); ok {
			inner, present := exported.declaration.?
			if !present || inner == nil { continue }
			declaration = decl_to_stmt(inner^)
		}
		#partial switch node in declaration {
		case ^VariableDeclaration:
			if !node.declare && !all { continue }
			for declarator in node.declarations {
				if id, plain := declarator.id.(^Identifier); plain { ambient[id.loc.start] = true }
			}
		case ^FunctionDeclaration:
			if id, named := node.id.?; named && (node.declare || all) {
				ambient[id.loc.start] = true
			}
		case ^ClassDeclaration:
			if id, named := node.id.?; named && (node.declare || all) {
				ambient[id.loc.start] = true
			}
		case ^TSModuleDeclaration:
			// Nesting of namespaces is bounded by the parser's depth limit.
			body, present := node.body.?
			if !present || body == nil { continue }
			if block, is_block := body^.(^TSModuleBlock); is_block {
				target_collect_ambient(block.body[:], all || node.declare, ambient)
			}
		}
	}
}

target_is_literal :: proc(expr: ^Expression) -> bool {
	#partial switch _ in expr^ {
	case ^StringLiteral, ^NumericLiteral, ^BooleanLiteral, ^NullLiteral, ^BigIntLiteral: return true
	}
	return false
}

// Removes grouping and erased TypeScript wrappers, which never change the value.
target_unwrap :: proc(cg: ^Codegen, expr: ^Expression) -> ^Expression {
	value := expr
	for value != nil {
		value = codegen_runtime_expression(cg, value)
		group, grouped := value^.(^ParenthesizedExpression)
		if !grouped { break }
		value = group.expression
	}
	return value
}

// ----------------------------------------------------------------------------
// Tree builders. Every node carries the span of the expression it replaces.
// ----------------------------------------------------------------------------

target_void :: proc(state: ^TransformState, loc: Loc) -> ^Expression {
	zero := new(NumericLiteral, state.allocator)
	zero^ = {loc = loc, value = 0, raw = "0"}
	node := new(UnaryExpression, state.allocator)
	node^ = {
		loc = loc, operator = .Void, argument = transform_expression(state, zero), prefix = true,
	}
	return transform_expression(state, node)
}

target_null :: proc(state: ^TransformState, loc: Loc) -> ^Expression {
	node := new(NullLiteral, state.allocator)
	node.loc = loc
	return transform_expression(state, node)
}

target_binary :: proc(
	state: ^TransformState, operator: BinaryOperator, left, right: ^Expression, loc: Loc,
) -> ^Expression {
	node := new(BinaryExpression, state.allocator)
	node^ = {loc = loc, operator = operator, left = left, right = right}
	return transform_expression(state, node)
}

target_logical :: proc(
	state: ^TransformState, operator: LogicalOperator, left, right: ^Expression, loc: Loc,
) -> ^Expression {
	node := new(LogicalExpression, state.allocator)
	node^ = {loc = loc, operator = operator, left = left, right = right}
	return transform_expression(state, node)
}

target_conditional :: proc(
	state: ^TransformState, test, consequent, alternate: ^Expression, loc: Loc,
) -> ^Expression {
	node := new(ConditionalExpression, state.allocator)
	node^ = {loc = loc, test = test, consequent = consequent, alternate = alternate}
	return transform_expression(state, node)
}

target_assign :: proc(state: ^TransformState, target, value: ^Expression, loc: Loc) -> ^Expression {
	node := new(AssignmentExpression, state.allocator)
	node^ = {loc = loc, operator = .Assign, left = target, right = value}
	return transform_expression(state, node)
}

target_member :: proc(
	state: ^TransformState, object, property: ^Expression, computed: bool, loc: Loc,
) -> ^Expression {
	node := new(MemberExpression, state.allocator)
	node^ = {loc = loc, object = object, property = property, computed = computed}
	return transform_expression(state, node)
}

target_call :: proc(
	state: ^TransformState, callee: ^Expression, arguments: []^Expression, loc: Loc,
) -> ^Expression {
	node := new(CallExpression, state.allocator)
	node^ = {loc = loc, callee = callee}
	node.arguments = make([dynamic]^Expression, 0, len(arguments), state.allocator)
	append(&node.arguments, ..arguments)
	return transform_expression(state, node)
}

// `value === null || value === void 0`, where the first read may also store it.
target_nullish_test :: proc(
	state: ^TransformState, first, again: ^Expression, loc: Loc,
) -> ^Expression {
	is_null := target_binary(state, .StrictEq, first, target_null(state, loc), loc)
	is_undefined := target_binary(state, .StrictEq, again, target_void(state, loc), loc)
	return target_logical(state, .Or, is_null, is_undefined, loc)
}

// Evaluates the expression once and returns the two ways to read it: the
// first read, which stores the value when a temporary is needed, and the rest.
target_capture :: proc(cg: ^Codegen, expr: ^Expression, loc: Loc) -> (first, again: ^Expression) {
	if target_is_stable(cg, target_unwrap(cg, expr)) { return expr, expr }
	temp := target_temp(cg, loc.end)
	return target_assign(cg.transform, temp, expr, loc), temp
}

// ----------------------------------------------------------------------------
// Rules
// ----------------------------------------------------------------------------

// One step of lowering. Returns nil when no rule applies or a rule reported
// a shape it cannot lower.
target_lower :: proc(cg: ^Codegen, expr: ^Expression) -> ^Expression {
	state := cg.transform
	target := state.target
	if target < .ES2022 {
		if lowered := class_lower_expression(cg, expr); lowered != nil { return lowered }
	}
	#partial switch node in expr^ {
	case ^LogicalExpression:
		if node.operator == .NullishCoalescing && target < .ES2020 {
			return target_nullish(cg, node)
		}
	case ^ChainExpression:
		if target < .ES2020 { return target_chain(cg, node.expression, node.loc, false) }
	case ^UnaryExpression:
		if node.operator == .Delete && target < .ES2020 {
			if chain, optional := target_unwrap(cg, node.argument)^.(^ChainExpression); optional {
				return target_chain(cg, chain.expression, node.loc, true)
			}
		}
	case ^CallExpression:
		if target < .ES2020 { target_reject_grouped_chain(cg, node.callee) }
	case ^TaggedTemplateExpression:
		if target < .ES2020 { target_reject_grouped_chain(cg, node.tag) }
	case ^AssignmentExpression:
		#partial switch node.operator {
		case .AssignLogicalOr, .AssignLogicalAnd, .AssignNullish:
			if target < .ES2021 { return target_logical_assignment(cg, node) }
		case .PowAssign:
			if target < .ES2016 { return target_power_assignment(cg, node) }
		}
	case ^BinaryExpression:
		if node.operator == .Pow && target < .ES2016 {
			return target_power(cg, node.left, node.right, node.loc)
		}
	case ^NumericLiteral:
		if target < .ES2021 && strings.contains_rune(node.raw, '_') {
			plain := new(NumericLiteral, state.allocator)
			plain^ = node^
			plain.raw, _ = strings.remove_all(node.raw, "_", state.allocator)
			return transform_expression(state, plain)
		}
	case ^BigIntLiteral:
		target_require(cg, node.loc, .ES2020, "BigInt literals cannot be lowered")
		if target < .ES2021 && strings.contains_rune(node.raw, '_') {
			plain := new(BigIntLiteral, state.allocator)
			plain^ = node^
			plain.raw, _ = strings.remove_all(node.raw, "_", state.allocator)
			return transform_expression(state, plain)
		}
	case:
		target_check_unsupported(cg, expr)
	}
	return nil
}

// `a ?? b` becomes `a !== null && a !== void 0 ? a : b`.
target_nullish :: proc(cg: ^Codegen, node: ^LogicalExpression) -> ^Expression {
	state := cg.transform
	// `a ?? b ?? c` nests one conditional inside the test of the next. The
	// parser does not bound the length of such a chain, so this rule does.
	links := 0
	for left := node.left; left != nil; links += 1 {
		inner, chained := left^.(^LogicalExpression)
		if !chained || inner.operator != .NullishCoalescing { break }
		if links >= TARGET_NESTING_MAX {
			cg_strip_unsupported(cg, node.loc, "this ?? chain is too long to lower")
			return nil
		}
		left = inner.left
	}
	first, again := target_capture(cg, node.left, node.loc)
	not_null := target_binary(state, .StrictNotEq, first, target_null(state, node.loc), node.loc)
	defined := target_binary(state, .StrictNotEq, again, target_void(state, node.loc), node.loc)
	test := target_logical(state, .And, not_null, defined, node.loc)
	return target_conditional(state, test, again, node.right, node.loc)
}

// A call or tagged template applied to a parenthesized optional chain keeps
// the chain's receiver as `this`. The conditional that replaces the chain
// would lose it, and no rule here rebuilds it.
target_reject_grouped_chain :: proc(cg: ^Codegen, callee: ^Expression) {
	if callee == nil { return }
	inner := target_unwrap(cg, callee)
	if inner == codegen_runtime_expression(cg, callee) { return }
	if _, chain := inner^.(^ChainExpression); chain {
		what := "a call on a parenthesized optional chain cannot be lowered"
		cg_strip_unsupported(cg, loc_from_expr(callee), what)
	}
}

// The longest run of `??` or `?.` links one expression may lower. Each link
// becomes one level of nesting in the output, and the printer and every
// later consumer handle nesting by recursion.
TARGET_NESTING_MAX :: 256

TargetChainLink :: struct {
	node:     ^Expression,
	optional: bool,
}

// Lowers `a?.b.c?.(d)` to nested conditionals. Each `?.` tests everything to
// its left once; the rest of the chain continues from the tested value.
//
//     (t = a) === null || t === void 0 ? void 0
//         : (u = t.b.c) === null || u === void 0 ? void 0 : u.call(t.b, d)
//
// `delete a?.b` yields true, not undefined, when the chain short-circuits.
target_chain :: proc(cg: ^Codegen, root: ^Expression, loc: Loc, deleting: bool) -> ^Expression {
	state := cg.transform
	links := make([dynamic]TargetChainLink, 0, 8, context.temp_allocator)
	base := root
	for base != nil {
		base = codegen_runtime_expression(cg, base)
		#partial switch node in base^ {
		case ^MemberExpression:
			append(&links, TargetChainLink{base, node.optional})
			base = node.object
			continue
		case ^CallExpression:
			append(&links, TargetChainLink{base, node.optional})
			base = node.callee
			continue
		}
		break
	}
	assert(base != nil)
	optional_links := 0
	for link in links { optional_links += int(link.optional) }
	if optional_links > TARGET_NESTING_MAX {
		cg_strip_unsupported(cg, loc, "this optional chain is too long to lower")
		return nil
	}
	tests := make([dynamic]^Expression, 0, 4, context.temp_allocator)
	current := base
	receiver: ^Expression // `this` for the next call, once its callee was stored.
	for index := len(links) - 1; index >= 0; index -= 1 {
		link := links[index]
		call, is_call := link.node^.(^CallExpression)
		if link.optional {
			first, again: ^Expression
			if is_call { first, again, receiver = target_chain_callee(cg, current, loc) }
			if first == nil { first, again = target_capture(cg, current, loc) }
			append(&tests, target_nullish_test(state, first, again, loc))
			current = again
		}
		if is_call {
			current = target_chain_call(cg, call, current, receiver, loc)
			receiver = nil
		} else {
			member := new(MemberExpression, state.allocator)
			member^ = link.node^.(^MemberExpression)^
			member.object = current
			member.optional = false
			current = transform_expression(state, member)
		}
	}
	assert(len(tests) > 0)
	result := current
	short_circuit := target_void(state, loc)
	if deleting {
		delete_node := new(UnaryExpression, state.allocator)
		delete_node^ = {loc = loc, operator = .Delete, argument = current, prefix = true}
		result = transform_expression(state, delete_node)
		truth := new(BooleanLiteral, state.allocator)
		truth^ = {loc = loc, value = true}
		short_circuit = transform_expression(state, truth)
	}
	for index := len(tests) - 1; index >= 0; index -= 1 {
		result = target_conditional(state, tests[index], short_circuit, result, loc)
	}
	return result
}

// For `object.method?.(...)` the method is stored for the test, and the call
// must still receive `object` as `this`. Returns nil reads when the callee is
// not a property access and an ordinary capture is enough.
target_chain_callee :: proc(
	cg: ^Codegen, callee: ^Expression, loc: Loc) -> (first, again, receiver: ^Expression,
) {
	state := cg.transform
	member, is_member := target_unwrap(cg, callee)^.(^MemberExpression)
	if !is_member {
		target_reject_grouped_chain(cg, callee)
		return nil, nil, nil
	}
	object := member.object
	object_first := object
	if _, is_super := target_unwrap(cg, object)^.(^Super); is_super {
		this := new(ThisExpression, state.allocator)
		this.loc = {loc.end, loc.end}
		receiver = transform_expression(state, this)
	} else {
		object_first, receiver = target_capture(cg, object, loc)
	}
	stored := new(MemberExpression, state.allocator)
	stored^ = member^
	stored.object = object_first
	temp := target_temp(cg, loc.end)
	return target_assign(state, temp, transform_expression(state, stored), loc), temp, receiver
}

target_chain_call :: proc(
	cg: ^Codegen, call: ^CallExpression, callee, receiver: ^Expression, loc: Loc,
) -> ^Expression {
	state := cg.transform
	node := new(CallExpression, state.allocator)
	node^ = call^
	node.optional = false
	node.callee = callee
	if receiver != nil {
		name := transform_identifier(state, "call", loc.end)
		node.callee = target_member(state, callee, name, false, loc)
		node.arguments = make([dynamic]^Expression, 0, len(call.arguments) + 1, state.allocator)
		append(&node.arguments, receiver)
		append(&node.arguments, ..call.arguments[:])
	} else if id, plain := callee^.(^Identifier); plain && id.name == "eval" && call.optional {
		// `eval?.(x)` is an indirect eval. A bare `eval(x)` would be a direct one.
		zero := new(NumericLiteral, state.allocator)
		zero^ = {loc = loc, value = 0, raw = "0"}
		sequence := new(SequenceExpression, state.allocator)
		sequence.loc = loc
		sequence.expressions = make([dynamic]^Expression, 0, 2, state.allocator)
		append(&sequence.expressions, transform_expression(state, zero), callee)
		node.callee = transform_expression(state, sequence)
	}
	return transform_expression(state, node)
}

// Splits an assignment target into a first read, which evaluates the object
// and key once, and a second reference to the same property for the write.
target_reference :: proc(
	cg: ^Codegen, target: ^Expression, loc: Loc) -> (read, write: ^Expression, ok: bool,
) {
	state := cg.transform
	value := target_unwrap(cg, target)
	#partial switch node in value^ {
	case ^Identifier:
		return value, value, true
	case ^MemberExpression:
		object_first, object_again := target_capture(cg, node.object, loc)
		key_first, key_again := node.property, node.property
		if node.computed && !target_is_literal(target_unwrap(cg, node.property)) {
			key_first, key_again = target_capture(cg, node.property, loc)
		}
		read = target_member(state, object_first, key_first, node.computed, node.loc)
		write = target_member(state, object_again, key_again, node.computed, node.loc)
		return read, write, true
	}
	cg_strip_unsupported(cg, loc, "this assignment target cannot be lowered")
	return target, target, false
}

// `a.b ||= c` becomes `(t = a).b || (t.b = c)`.
target_logical_assignment :: proc(cg: ^Codegen, node: ^AssignmentExpression) -> ^Expression {
	state := cg.transform
	read, write, ok := target_reference(cg, node.left, node.loc)
	if !ok { return nil }
	operator: LogicalOperator
	#partial switch node.operator {
	case .AssignLogicalOr:  operator = .Or
	case .AssignLogicalAnd: operator = .And
	case .AssignNullish:    operator = .NullishCoalescing
	case: unreachable()
	}
	store := target_assign(state, write, node.right, node.loc)
	return target_logical(state, operator, read, store, node.loc)
}

// `a ** b` becomes `Math.pow(a, b)`, which is the same operation on numbers.
// BigInt operands, which Math.pow rejects, postdate every target this applies to.
target_power :: proc(cg: ^Codegen, left, right: ^Expression, loc: Loc) -> ^Expression {
	state := cg.transform
	if !state.math_checked {
		state.math_checked = true
		for symbol in transform_model(cg).symbols {
			if symbol.name == "Math" {
				what := "a binding named Math prevents lowering the ** operator"
				cg_strip_unsupported(cg, loc, what)
			}
		}
	}
	at := loc.end
	math := transform_identifier(state, "Math", at)
	pow := transform_identifier(state, "pow", at)
	return target_call(state, target_member(state, math, pow, false, loc), {left, right}, loc)
}

target_power_assignment :: proc(cg: ^Codegen, node: ^AssignmentExpression) -> ^Expression {
	state := cg.transform
	read, write, ok := target_reference(cg, node.left, node.loc)
	if !ok { return nil }
	// The target is resolved before its value is read, as in the original.
	return target_assign(state, read, target_power(cg, write, node.right, node.loc), node.loc)
}

// Newer syntax that passes through expressions and has no lowering rule.
target_check_unsupported :: proc(cg: ^Codegen, expr: ^Expression) {
	target := cg.transform.target
	if target >= .ES2022 { return }
	#partial switch node in expr^ {
	case ^ArrowFunctionExpression:
		if node.async { target_require(cg, node.loc, .ES2017, "async functions cannot be lowered") }
		for param in node.params {
			target_check_pattern(cg, param.pattern)
			class_note_pattern_names(cg, param.pattern, param.default_val)
		}
	case ^AwaitExpression:
		target_require(cg, node.loc, .ES2017, "await cannot be lowered")
		if !target_inside_function(cg, node.loc.start) {
			target_require(cg, node.loc, .ES2022, "top-level await cannot be lowered")
		}
	case ^ImportExpression:
		target_require(cg, node.loc, .ES2020, "dynamic import cannot be lowered")
	case ^MetaProperty:
		if node.meta.name == "import" {
			target_require(cg, node.loc, .ES2020, "import.meta cannot be lowered")
		}
	case ^ObjectExpression:
		for property in node.properties {
			if _, spread := property.value^.(^SpreadElement); spread {
				target_require(cg, property.loc, .ES2018, "object spread cannot be lowered")
			}
		}
	case ^RegExpLiteral:
		if strings.contains_rune(node.flags, 's') {
			target_require(cg, node.loc, .ES2018, "the regular expression flag s cannot be lowered")
		}
		if strings.contains_rune(node.flags, 'd') {
			target_require(cg, node.loc, .ES2022, "the regular expression flag d cannot be lowered")
		}
		// A textual test: it may also match inside a character class, where
		// refusing is merely cautious.
		if strings.contains(node.pattern, "(?<") {
			what := "named groups and lookbehind in a regular expression cannot be lowered"
			target_require(cg, node.loc, .ES2018, what)
		}
		if strings.contains(node.pattern, "\\p{") || strings.contains(node.pattern, "\\P{") {
			what := "Unicode property escapes in a regular expression cannot be lowered"
			target_require(cg, node.loc, .ES2018, what)
		}
	}
}

target_inside_function :: proc(cg: ^Codegen, offset: u32) -> bool {
	for scope in transform_model(cg).scopes {
		if scope.kind != .Function && scope.kind != .StaticBlock { continue }
		if scope.node_start <= offset && offset < scope.node_end { return true }
	}
	return false
}


// Every function except an arrow passes through here before it prints.
transform_function_check :: proc(
	cg: ^Codegen, async, generator: bool, params: []FunctionParameter, loc: Loc,
) {
	if cg.transform == nil { return }
	if async { target_require(cg, loc, .ES2017, "async functions cannot be lowered") }
	if async && generator { target_require(cg, loc, .ES2018, "async generators cannot be lowered") }
	for param in params {
		target_check_pattern(cg, param.pattern)
		class_note_pattern_names(cg, param.pattern, param.default_val)
	}
}

// Temporaries created while a function body prints are declared when it
// closes. Those of parameter initializers belong to the enclosing scope,
// because a body's `var` is not visible from the parameter list.
transform_function_open :: proc(cg: ^Codegen) {
	state := cg.transform
	if state == nil { return }
	append(&state.temp_scopes, make([dynamic]string, 0, 4, state.allocator))
}

transform_function_close :: proc(cg: ^Codegen) {
	state := cg.transform
	if state == nil { return }
	assert(len(state.temp_scopes) > 1)
	target_declare_temps(cg, pop(&state.temp_scopes)[:])
}

// Object rest in a binding pattern arrived with object spread in ES2018.
target_check_pattern :: proc(cg: ^Codegen, pattern: Pattern) {
	if cg.transform.target >= .ES2018 { return }
	switch node in pattern {
	case ^ObjectPattern:
		for property in node.properties {
			if rest, is_rest := property.value.(^RestElement); is_rest {
				cg_strip_unsupported(cg, rest.loc, "object rest cannot be lowered")
			} else {
				target_check_pattern(cg, property.value)
			}
		}
	case ^ArrayPattern:
		for element in node.elements {
			if inner, present := element.?; present { target_check_pattern(cg, inner) }
		}
	case ^AssignmentPattern: target_check_pattern(cg, node.left)
	case ^RestElement:       target_check_pattern(cg, node.argument)
	case ^Identifier, ^MemberExpression:
	}
}

// Import and export forms that arrived after ES2015.
target_check_module_statement :: proc(cg: ^Codegen, stmt: Statement) {
	what_names :: "string names in import and export lists cannot be lowered"
	#partial switch node in stmt {
	case ^ExportAllDeclaration:
		if name, renamed := node.exported.?; renamed {
			target_require(cg, node.loc, .ES2020, "export * as cannot be lowered")
			if cg_name_is_quoted(cg, name.loc.start) {
				cg_strip_unsupported(cg, node.loc, what_names)
			}
		}
	case ^ExportNamedDeclaration:
		for specifier in node.specifiers {
			_, local_text := specifier.local.(^StringLiteral)
			_, exported_text := specifier.exported.(^StringLiteral)
			if local_text || exported_text { cg_strip_unsupported(cg, specifier.loc, what_names) }
		}
		if len(node.attributes) != 0 {
			cg_strip_unsupported(cg, node.loc, "import attributes cannot be lowered")
		}
	case ^ImportDeclaration:
		for item in node.specifiers {
			if item == nil { continue }
			if specifier, named := item^.(ImportSpecifier); named {
				if cg_name_is_quoted(cg, specifier.imported.loc.start) {
					cg_strip_unsupported(cg, specifier.loc, what_names)
				}
			}
		}
		if len(node.attributes) != 0 {
			cg_strip_unsupported(cg, node.loc, "import attributes cannot be lowered")
		}
	}
}

// Statements have no replacement tree; the few rules that concern them edit
// the statement in place before it prints.
transform_lower_statement :: proc(cg: ^Codegen, stmt: Statement) {
	state := cg.transform
	if state == nil || state.target == .ESNext { return }
	// Explicit resource management is newer than every edition a target can name.
	resource: ^VariableDeclaration
	#partial switch node in stmt {
	case ^VariableDeclaration: resource = node
	case ^ForStatement:        resource = node.init_decl.? or_else nil
	case ^ForOfStatement:      resource = node.left_decl.? or_else nil
	}
	if resource != nil && resource_kind(resource) != .None && !cg.cfg.lower_using {
		what := "using declarations cannot be lowered without --lower-using"
		cg_strip_unsupported(cg, resource.loc, what)
	}
	if state.target >= .ES2022 { return }
	target_check_module_statement(cg, stmt)
	#partial switch node in stmt {
	case ^ForStatement:
		if declaration, declared := node.init_decl.?; declared {
			for declarator in declaration.declarations {
				target_check_pattern(cg, declarator.id)
				class_note_pattern_names(cg, declarator.id, declarator.init)
			}
		}
	case ^TryStatement:
		// `catch {` becomes `catch (unused) {`.
		handler, present := &node.handler.?
		if present && handler.param == nil && state.target < .ES2019 {
			unused := codegen_fresh_runtime_binding(cg, "unused")
			handler.param = transform_identifier(state, unused, handler.loc.start)^.(^Identifier)
		}
		if present { if param, bound := handler.param.?; bound { target_check_pattern(cg, param) } }
	case ^VariableDeclaration:
		for declarator in node.declarations {
			target_check_pattern(cg, declarator.id)
			class_note_pattern_names(cg, declarator.id, declarator.init)
		}
	case ^ForInStatement:
		if target, written := node.left_expr.?; written { class_lower_private_targets(cg, target) }
		if declaration, declared := node.left_decl.?; declared {
			for declarator in declaration.declarations { target_check_pattern(cg, declarator.id) }
		}
	case ^ForOfStatement:
		if target, written := node.left_expr.?; written { class_lower_private_targets(cg, target) }
		if node.await { target_require(cg, node.loc, .ES2018, "for await cannot be lowered") }
		if declaration, declared := node.left_decl.?; declared {
			for declarator in declaration.declarations { target_check_pattern(cg, declarator.id) }
		}
	}
}
