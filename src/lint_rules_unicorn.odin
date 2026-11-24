package kessel

import "core:strings"

// The `unicorn` plugin.

// `Promise.<method>(single argument)` written without optional chaining or
// a computed property. Returns the callee member.
lint_promise_method_call :: proc(e: ^CallExpression, methods: []string) -> ^MemberExpression {
	if e.optional || len(e.arguments) != 1 { return nil }
	member := lint_member_of(e.callee)
	if member == nil || member.optional || member.computed { return nil }
	object := lint_identifier(lint_inner(member.object))
	if object == nil || object.name != "Promise" { return nil }
	name, static := lint_static_property_name(member)
	if !static { return nil }
	for method in methods {
		if method == name { return member }
	}
	return nil
}

lint_check_unicorn_call :: proc(l: ^Linter, e: ^CallExpression) {
	lint_check_await_in_promise_methods(l, e)
	lint_check_single_promise(l, e)
	lint_check_remove_event_listener(l, e)
	lint_check_thenable_call(l, e)
}

// no-await-in-promise-methods: `Promise.all([await a])` reports each `await`.
lint_check_await_in_promise_methods :: proc(l: ^Linter, e: ^CallExpression) {
	if !lint_rule_enabled(l, .L6001_NoAwaitInPromiseMethods) { return }
	if lint_promise_method_call(e, {"all", "allSettled", "any", "race"}) == nil { return }
	if _, spread := e.arguments[0]^.(^SpreadElement); spread { return }
	list := lint_unparen(e.arguments[0])
	array, is_array := list^.(^ArrayExpression)
	if !is_array { return }
	for element in array.elements {
		item, present := element.?
		if !present || item == nil { continue }
		if _, spread := item^.(^SpreadElement); spread { continue }
		inner := lint_unparen(item)
		if await, is_await := inner^.(^AwaitExpression); is_await {
			lint_emit(l, {await.loc.start, await.loc.start + 5}, .L6001_NoAwaitInPromiseMethods)
		}
	}
}

// no-single-promise-in-promise-methods: `Promise.all([one])`.
lint_check_single_promise :: proc(l: ^Linter, e: ^CallExpression) {
	if !lint_rule_enabled(l, .L6005_NoSinglePromiseInPromiseMethods) { return }
	member := lint_promise_method_call(e, {"all", "any", "race"})
	if member == nil { return }
	if _, spread := e.arguments[0]^.(^SpreadElement); spread { return }
	list := lint_inner(e.arguments[0])
	array, is_array := list^.(^ArrayExpression)
	if !is_array || len(array.elements) != 1 { return }
	only, present := array.elements[0].?
	if !present || only == nil { return }
	if _, spread := only^.(^SpreadElement); spread { return }
	lint_emit(l, lint_property_loc(member), .L6005_NoSinglePromiseInPromiseMethods)
}

// no-invalid-remove-event-listener: a fresh function or a bound function can
// never be the listener that was added.
lint_check_remove_event_listener :: proc(l: ^Linter, e: ^CallExpression) {
	if e.optional || len(e.arguments) < 2 || !lint_rule_enabled(l, .L6003_NoInvalidRemoveEventListener) { return }
	member := lint_member_of(e.callee)
	if member == nil || member.computed { return }
	property := lint_identifier(member.property)
	if property == nil || property.name != "removeEventListener" { return }
	if _, spread := e.arguments[0]^.(^SpreadElement); spread { return }
	listener := e.arguments[1]
	#partial switch node in listener^ {
	case ^FunctionExpression, ^ArrowFunctionExpression:
	case ^CallExpression:
		bound := lint_member_of(node.callee)
		if bound == nil || bound.computed { return }
		name := lint_identifier(bound.property)
		if name == nil || name.name != "bind" { return }
	case:
		return
	}
	lint_emit(l, property.loc, .L6003_NoInvalidRemoveEventListener)
}

// no-new-array: `new Array(n)` is ambiguous between a length and an element.
lint_check_new_array :: proc(l: ^Linter, e: ^NewExpression) {
	if len(e.arguments) != 1 || !lint_rule_enabled(l, .L6004_NoNewArray) { return }
	callee := lint_identifier(e.callee)
	if callee != nil && callee.name == "Array" { lint_emit(l, e.loc, .L6004_NoNewArray) }
}

lint_await_is_unnecessary :: proc(expr: ^Expression) -> bool {
	if expr == nil { return false }
	#partial switch node in expr^ {
	case ^ArrayExpression, ^ArrowFunctionExpression, ^AwaitExpression, ^BinaryExpression,
	     ^ClassExpression, ^FunctionExpression, ^JSXElement, ^JSXFragment, ^BooleanLiteral,
	     ^NullLiteral, ^NumericLiteral, ^BigIntLiteral, ^RegExpLiteral, ^StringLiteral,
	     ^TemplateLiteral, ^UnaryExpression, ^UpdateExpression:
		return true
	case ^SequenceExpression:
		return len(node.expressions) > 0 && lint_await_is_unnecessary(node.expressions[len(node.expressions) - 1])
	case ^ParenthesizedExpression:
		return lint_await_is_unnecessary(node.expression)
	}
	return false
}

// no-unnecessary-await: awaiting a value that cannot be a promise.
lint_check_unnecessary_await :: proc(l: ^Linter, e: ^AwaitExpression) {
	if !lint_rule_enabled(l, .L6007_NoUnnecessaryAwait) || !lint_await_is_unnecessary(e.argument) { return }
	lint_emit(l, {e.loc.start, e.loc.start + 5}, .L6007_NoUnnecessaryAwait)
}

// no-useless-fallback-in-spread: `{...(a || {})}` spreads nothing extra.
lint_check_fallback_in_spread :: proc(l: ^Linter, e: ^LogicalExpression) {
	if e.operator == .And || !lint_rule_enabled(l, .L6008_NoUselessFallbackInSpread) { return }
	fallback := lint_unparen(e.right)
	if fallback == nil { return }
	object, is_object := fallback^.(^ObjectExpression)
	if !is_object || len(object.properties) != 0 { return }
	spread: ^SpreadElement
	for index := len(l.ancestors) - 2; index >= 0; index -= 1 {
		expr, is_expr := l.ancestors[index].(^Expression)
		if !is_expr { return }
		if _, paren := expr^.(^ParenthesizedExpression); paren { continue }
		if spread == nil {
			found, is_spread := expr^.(^SpreadElement)
			if !is_spread { return }
			spread = found
			continue
		}
		if _, in_object := expr^.(^ObjectExpression); in_object { lint_emit(l, spread.loc, .L6008_NoUselessFallbackInSpread) }
		return
	}
}

// no-empty-file: nothing but empty statements, and no triple-slash directive.
lint_statement_is_empty :: proc(stmt: ^Statement) -> bool {
	if stmt == nil { return true }
	#partial switch node in stmt^ {
	case ^EmptyStatement: return true
	case ^BlockStatement:
		for inner in node.body {
			if !lint_statement_is_empty(inner) { return false }
		}
		return true
	}
	return false
}

LINT_EMPTY_FILE_RANGE_MAX :: 100

lint_check_empty_file :: proc(l: ^Linter, program: ^Program) {
	if !lint_rule_enabled(l, .L6002_NoEmptyFile) { return }
	for stmt, index in program.body {
		if lint_statement_is_empty(stmt) { continue }
		// The reference keeps directives apart from the body, so a file that
		// holds only "use strict" still counts as empty.
		if !lint_is_string_statement(stmt) { return }
		for earlier in program.body[:index] {
			if !lint_is_string_statement(earlier) { return }
		}
	}
	for comment in l.comments {
		if comment.type == .Line && strings.has_prefix(comment.value, "/") { return }
	}
	lint_emit(l, {0, min(u32(len(l.source)), LINT_EMPTY_FILE_RANGE_MAX)}, .L6002_NoEmptyFile)
}

// ---------------------------------------------------------------------------
// no-thenable
// ---------------------------------------------------------------------------

LintThenReference :: struct { id: ^Identifier }

// A key or name expression that evaluates to "then". An identifier is decided
// after scope analysis, from the string its declaration was initialized with.
lint_check_then_expression :: proc(l: ^Linter, expr: ^Expression) {
	if expr == nil { return }
	#partial switch node in expr^ {
	case ^StringLiteral:
		if node.value == "then" { lint_emit(l, node.loc, .L6006_NoThenable) }
	case ^TemplateLiteral:
		if len(node.expressions) == 0 && len(node.quasis) == 1 && node.quasis[0].raw == "then" {
			lint_emit(l, node.loc, .L6006_NoThenable)
		}
	case ^Identifier:
		append(&l.then_references, LintThenReference{node})
	}
}

lint_check_then_key :: proc(l: ^Linter, key: ^Expression, computed: bool) {
	if key == nil { return }
	if id := lint_identifier(key); id != nil && !computed {
		if id.name == "then" { lint_emit(l, id.loc, .L6006_NoThenable) }
		return
	}
	lint_check_then_expression(l, key)
}

lint_check_thenable_object :: proc(l: ^Linter, e: ^ObjectExpression) {
	if !lint_rule_enabled(l, .L6006_NoThenable) { return }
	for prop in e.properties { lint_check_then_key(l, prop.key, prop.computed) }
}

lint_check_thenable_class :: proc(l: ^Linter, cls: ^ClassExpression) {
	if !lint_rule_enabled(l, .L6006_NoThenable) { return }
	for elem in cls.body.body {
		#partial switch elem.kind {
		case .StaticBlock, .IndexSignature: continue
		}
		lint_check_then_key(l, elem.key, elem.computed)
	}
}

lint_is_static_method :: proc(callee: ^Expression, objects: []string, method: string) -> bool {
	if callee == nil { return false }
	member, is_member := callee^.(^MemberExpression)
	if !is_member || member.optional { return false }
	object := lint_identifier(lint_inner(member.object))
	name, static := lint_static_property_name(member)
	if object == nil || !static || name != method { return false }
	for candidate in objects {
		if candidate == object.name { return true }
	}
	return false
}

lint_check_thenable_call :: proc(l: ^Linter, e: ^CallExpression) {
	if e.optional || len(e.arguments) == 0 || !lint_rule_enabled(l, .L6006_NoThenable) { return }
	if _, spread := e.arguments[0]^.(^SpreadElement); spread { return }
	if len(e.arguments) >= 3 && lint_is_static_method(e.callee, {"Reflect", "Object"}, "defineProperty") {
		if _, spread := e.arguments[1]^.(^SpreadElement); !spread { lint_check_then_expression(l, e.arguments[1]) }
	}
	if len(e.arguments) != 1 || !lint_is_static_method(e.callee, {"Object"}, "fromEntries") { return }
	entries, is_array := e.arguments[0]^.(^ArrayExpression)
	if !is_array { return }
	for element in entries.elements {
		item, present := element.?
		if !present || item == nil { continue }
		pair, is_pair := item^.(^ArrayExpression)
		if !is_pair || len(pair.elements) == 0 { continue }
		key, has_key := pair.elements[0].?
		if !has_key || key == nil { continue }
		if _, spread := key^.(^SpreadElement); spread { continue }
		lint_check_then_expression(l, key)
	}
}

lint_check_thenable_assignment :: proc(l: ^Linter, e: ^AssignmentExpression) {
	if !lint_rule_enabled(l, .L6006_NoThenable) { return }
	target := lint_unparen(e.left)
	if target == nil { return }
	member, is_member := target^.(^MemberExpression)
	if !is_member { return }
	if member.computed {
		lint_check_then_expression(l, member.property)
	} else if property := lint_identifier(member.property); property != nil && property.name == "then" {
		lint_emit(l, member.loc, .L6006_NoThenable)
	}
}

lint_check_thenable_pattern :: proc(l: ^Linter, pattern: Pattern) {
	switch node in pattern {
	case ^Identifier:
		if node != nil && node.name == "then" { lint_emit(l, lint_binding_loc(node), .L6006_NoThenable) }
	case ^AssignmentPattern: if node != nil { lint_check_thenable_pattern(l, node.left) }
	case ^RestElement:       if node != nil { lint_check_thenable_pattern(l, node.argument) }
	case ^ArrayPattern:
		if node == nil { return }
		for element in node.elements {
			if inner, ok := element.?; ok { lint_check_thenable_pattern(l, inner) }
		}
	case ^ObjectPattern:
		if node == nil { return }
		for prop in node.properties { lint_check_thenable_pattern(l, prop.value) }
	case ^MemberExpression:
	}
}

lint_check_thenable_export :: proc(l: ^Linter, v: ^ExportNamedDeclaration) {
	if !lint_rule_enabled(l, .L6006_NoThenable) { return }
	if declaration, present := v.declaration.?; present && declaration != nil {
		#partial switch node in declaration^ {
		case ^VariableDeclaration:
			for decl in node.declarations { lint_check_thenable_pattern(l, decl.id) }
		case ^FunctionDeclaration:
			if id, named := node.id.?; named && id.name == "then" { lint_emit(l, id.loc, .L6006_NoThenable) }
		case ^ClassDeclaration:
			if id, named := node.id.?; named && id.name == "then" { lint_emit(l, id.loc, .L6006_NoThenable) }
		}
	}
	for spec in v.specifiers {
		name, loc := lint_export_name(spec.exported)
		if name == "then" { lint_emit(l, loc, .L6006_NoThenable) }
	}
}

lint_check_then_references :: proc(l: ^Linter, model: ^SemanticModel, references: map[u32]SymbolId) {
	for site in l.then_references {
		resolved, found := references[site.id.loc.start]
		if !found || resolved == SYMBOL_UNRESOLVED { continue }
		entry, declared := l.declarator_inits[model.symbols[resolved].decl_start]
		if !declared || !entry.simple || entry.init == nil { continue }
		text, is_string := entry.init^.(^StringLiteral)
		if is_string && text.value == "then" { lint_emit(l, text.loc, .L6006_NoThenable) }
	}
}

// ---------------------------------------------------------------------------
// prefer-set-size
// ---------------------------------------------------------------------------

LintSetSize :: struct { id: ^Identifier, property: Loc }

lint_is_new_set :: proc(expr: ^Expression) -> bool {
	if expr == nil { return false }
	created, is_new := expr^.(^NewExpression)
	if !is_new { return false }
	callee := lint_identifier(created.callee)
	return callee != nil && callee.name == "Set"
}

// `[...set].length` and `Array.from(set).length`.
lint_check_set_size :: proc(l: ^Linter, e: ^MemberExpression) {
	if e.computed || e.optional || !lint_rule_enabled(l, .L6009_PreferSetSize) { return }
	property := lint_identifier(e.property)
	if property == nil || property.name != "length" { return }
	converted := lint_unparen(e.object)
	if converted == nil { return }
	source: ^Expression
	#partial switch node in converted^ {
	case ^ArrayExpression:
		if len(node.elements) != 1 { return }
		only, present := node.elements[0].?
		if !present || only == nil { return }
		spread, is_spread := only^.(^SpreadElement)
		if !is_spread { return }
		source = spread.argument
	case ^CallExpression:
		if node.optional || len(node.arguments) != 1 { return }
		callee := lint_member_of(node.callee)
		if callee == nil || callee.optional || callee.computed { return }
		object := lint_identifier(lint_inner(callee.object))
		name, static := lint_static_property_name(callee)
		if object == nil || object.name != "Array" || !static || name != "from" { return }
		if _, spread := node.arguments[0]^.(^SpreadElement); spread { return }
		source = node.arguments[0]
	case:
		return
	}
	source = lint_inner(source)
	if source == nil { return }
	if lint_is_new_set(source) {
		lint_emit(l, property.loc, .L6009_PreferSetSize)
	} else if id := lint_identifier(source); id != nil {
		// Whether the name is a `const` holding `new Set()` is known after scope analysis.
		append(&l.set_sizes, LintSetSize{id, property.loc})
	}
}

lint_check_set_size_references :: proc(l: ^Linter, model: ^SemanticModel, references: map[u32]SymbolId) {
	for site in l.set_sizes {
		resolved, found := references[site.id.loc.start]
		if !found || resolved == SYMBOL_UNRESOLVED { continue }
		entry, declared := l.declarator_inits[model.symbols[resolved].decl_start]
		if !declared || !entry.simple || !entry.constant { continue }
		if lint_is_new_set(entry.init) { lint_emit(l, site.property, .L6009_PreferSetSize) }
	}
}

// ---------------------------------------------------------------------------
// no-useless-length-check
// ---------------------------------------------------------------------------

lint_flatten_logical :: proc(out: ^[dynamic]^Expression, node: ^LogicalExpression) {
	// The left spine of `a && b && c` is unbounded, so it is followed in a
	// loop. Right operands nest within the parser's limit and may recurse.
	links := make([dynamic]^LogicalExpression, 0, 4, context.temp_allocator)
	current := node
	for {
		append(&links, current)
		inner := lint_unparen(current.left)
		nested, is_logical := inner^.(^LogicalExpression)
		if !is_logical || nested.operator != node.operator { break }
		current = nested
	}
	append(out, links[len(links) - 1].left)
	#reverse for link in links {
		inner := lint_unparen(link.right)
		if nested, is_logical := inner^.(^LogicalExpression); is_logical && nested.operator == node.operator {
			lint_flatten_logical(out, nested)
		} else {
			append(out, link.right)
		}
	}
}

LintLengthOperand :: enum { Other, Length_Check, Method_Call, Abort }

// Classifies one operand: `name.length <op> 0` or `name.method()`. `Abort`
// mirrors the places where the reference gives up on the whole pair.
lint_length_operand :: proc(expr: ^Expression, every: bool) -> (kind: LintLengthOperand, name: string, matches: bool, loc: Loc) {
	inner := lint_unparen(expr)
	if inner == nil { return .Other, "", false, {} }
	#partial switch node in inner^ {
	case ^BinaryExpression:
		target := lint_inner(node.left)
		if target == nil { return .Abort, "", false, {} }
		member, is_member := target^.(^MemberExpression)
		if !is_member { return .Abort, "", false, {} }
		object := lint_identifier(lint_inner(member.object))
		if object == nil { return .Abort, "", false, {} }
		operator_fits := node.operator == .StrictEq if every else (node.operator == .StrictNotEq || node.operator == .Gt)
		property, static := lint_static_property_name(member)
		zero, is_number := node.right^.(^NumericLiteral)
		matches = operator_fits && static && property == "length" && is_number && zero.raw == "0"
		return .Length_Check, object.name, matches, node.loc
	case ^CallExpression:
		member := lint_member_of(node.callee)
		if member == nil { return .Abort, "", false, {} }
		object := lint_identifier(lint_inner(member.object))
		property, static := lint_static_property_name(member)
		if object == nil || !static { return .Abort, "", false, {} }
		matches = property == ("every" if every else "some") && !node.optional
		return .Method_Call, object.name, matches, node.loc
	}
	return .Other, "", false, {}
}

// `array.length === 0 || array.every(f)` and `array.length > 0 && array.some(f)`:
// the method already gives that answer for an empty array.
lint_check_useless_length :: proc(l: ^Linter, e: ^LogicalExpression) {
	if e.operator == .NullishCoalescing || !lint_rule_enabled(l, .L6010_NoUselessLengthCheck) { return }
	operands := make([dynamic]^Expression, 0, 4, context.temp_allocator)
	lint_flatten_logical(&operands, e)
	every := e.operator == .Or
	for index in 1..<len(operands) {
		first, name, first_fits, first_loc := lint_length_operand(operands[index - 1], every)
		second, other, second_fits, second_loc := lint_length_operand(operands[index], every)
		if first == .Abort || second == .Abort || first == second { continue }
		if first == .Other || second == .Other || !first_fits || !second_fits || name != other { continue }
		lint_emit(l, first_loc if first == .Length_Check else second_loc, .L6010_NoUselessLengthCheck)
	}
}
