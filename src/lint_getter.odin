package kessel

import "core:encoding/json"

lint_getter_options :: proc(options: []json.Value) -> (bool, bool) {
	if len(options) == 0 { return false, true }
	if len(options) != 1 { return false, false }
	object, ok := options[0].(json.Object)
	if !ok { return false, false }
	if len(object) == 0 { return false, true }
	allow, valid := object["allowImplicit"].(json.Boolean)
	return bool(allow), len(object) == 1 && valid
}

// Getters that throw or never finish do not return undefined. A bare return
// is a separate exit because allowImplicit admits it but still rejects falling off the end.
lint_getter_function :: proc(l: ^Linter, value: ^Expression) {
	if value == nil || !lint_rule_enabled(l, .L2046_GetterReturn) { return }
	expr := semantic_runtime_expression(value)
	if expr == nil { return }
	body: []^Statement
	loc: Loc
	#partial switch fn in expr^ {
	case ^FunctionExpression:
		if fn == nil || fn.no_body { return }
		body, loc = fn.body.body[:], fn.loc
	case ^ArrowFunctionExpression:
		if fn == nil { return }
		block, ok := fn.body.(^BlockStatement)
		if !ok || block == nil { return }
		body, loc = block.body[:], fn.loc
	case: return
	}
	paths := cfg_completion({body = body}, l.allocator)
	if .Unknown in paths { return }
	if .Next in paths || (!l.getter_allow_implicit && .Return_Empty in paths) {
		info := lint_rule_info(.L2046_GetterReturn)
		lint_report(l, loc.start, loc.end, .L2046_GetterReturn, info.default_message)
	}
}

@(private="file")
lint_getter_key :: proc(key: ^Expression, computed: bool) -> string {
	if key == nil { return "" }
	if !computed {
		if id, ok := key^.(^Identifier); ok && id != nil { return id.name }
	}
	name, ok := lint_constant_string(key)
	return name if ok else ""
}

// defineProperty takes one descriptor. defineProperties and create take a map
// of descriptors. Other arguments can contain ordinary methods named get.
LintGetterDescriptors :: struct { object: ^ObjectExpression, multiple: bool }

lint_queue_getter_descriptors :: proc(l: ^Linter, call: ^CallExpression) {
	assert(call != nil)
	if len(call.arguments) < 2 { return }
	callee := semantic_runtime_expression(call.callee)
	if callee == nil { return }
	member, ok := callee^.(^MemberExpression)
	if !ok || member == nil { return }
	base := semantic_runtime_expression(member.object)
	if base == nil { return }
	receiver, named := base^.(^Identifier)
	if !named || receiver == nil || (receiver.name != "Object" && receiver.name != "Reflect") { return }
	method := lint_getter_key(member.property, member.computed)
	index := 1
	switch method {
	case "defineProperty": index = 2
	case "create", "defineProperties": if receiver.name != "Object" { return }
	case: return
	}
	if index >= len(call.arguments) { return }
	// Spread arguments make the position of the descriptor unknown.
	for argument in call.arguments[:index] {
		if argument != nil { if _, spread := argument^.(^SpreadElement); spread { return } }
	}
	value := semantic_runtime_expression(call.arguments[index])
	if value == nil { return }
	object, known := value^.(^ObjectExpression)
	if !known || object == nil { return }
	if l.getter_descriptors == nil { l.getter_descriptors = make(map[u32]LintGetterDescriptors, l.allocator) }
	l.getter_descriptors[receiver.loc.start] = {object, index == 1}
}

lint_getter_check_descriptors :: proc(l: ^Linter, entry: LintGetterDescriptors) {
	assert(entry.object != nil)
	if !entry.multiple { lint_getter_descriptor(l, entry.object); return }
	for property in entry.object.properties {
		if property.kind != .Init { continue }
		value := semantic_runtime_expression(property.value)
		if value == nil { continue }
		if descriptor, ok := value^.(^ObjectExpression); ok && descriptor != nil { lint_getter_descriptor(l, descriptor) }
	}
}

@(private="file")
lint_getter_descriptor :: proc(l: ^Linter, object: ^ObjectExpression) {
	assert(object != nil)
	for property in object.properties {
		if property.kind != .Init && property.kind != .Method { continue }
		if lint_getter_key(property.key, property.computed) == "get" {
			lint_getter_function(l, property.value)
		}
	}
}
