package kessel

// Rules that compare references: loop counters, self assignments and calls
// of the non-callable global namespaces.

// for-direction: `for (i = 0; i < n; i--)` can never end by its own test.
lint_check_for_direction :: proc(l: ^Linter, v: ^ForStatement) {
	if v == nil || !lint_rule_enabled(l, .L2026_ForDirection) { return }
	test_expr, has_test := v.test.?
	update, has_update := v.update.?
	if !has_test || !has_update || test_expr == nil || update == nil { return }
	test, is_binary := test_expr^.(^BinaryExpression)
	if !is_binary || test == nil { return }
	counter := lint_identifier(test.left)
	on_left := counter != nil
	if !on_left { counter = lint_identifier(test.right) }
	if counter == nil { return }
	forward: bool
	#partial switch test.operator {
	case .Lt, .LtEq: forward = on_left
	case .Gt, .GtEq: forward = !on_left
	case: return
	}
	moves_forward, known := lint_update_direction(update, counter.name)
	if known && moves_forward != forward { lint_emit(l, test.loc, .L2026_ForDirection) }
}

lint_update_direction :: proc(update: ^Expression, counter: string) -> (forward, known: bool) {
	#partial switch node in update^ {
	case ^UpdateExpression:
		target := lint_identifier(lint_unparen(node.argument))
		if target == nil || target.name != counter { return false, false }
		return node.operator == .Increment, true
	case ^AssignmentExpression:
		target := lint_identifier(lint_unparen(node.left))
		if target == nil || target.name != counter || node.right == nil { return false, false }
		positive: bool
		#partial switch step in node.right^ {
		case ^NumericLiteral:
			if step.value == 0 { return false, false }
			positive = true
		case ^UnaryExpression:
			positive = step.operator != .Minus
		case:
			return false, false
		}
		#partial switch node.operator {
		case .AddAssign: return positive, true
		case .SubAssign: return !positive, true
		}
	}
	return false, false
}

// The member expression an expression denotes, looking through grouping,
// erased TypeScript wrappers and an optional chain.
lint_member_of :: proc(expr: ^Expression) -> ^MemberExpression {
	inner := lint_inner(expr)
	if inner == nil { return nil }
	#partial switch node in inner^ {
	case ^MemberExpression: return node
	case ^ChainExpression:
		if node.expression == nil { return nil }
		member, ok := node.expression^.(^MemberExpression)
		return member if ok else nil
	}
	return nil
}

lint_member_is_private :: proc(member: ^MemberExpression) -> bool {
	if member.computed || member.property == nil { return false }
	_, private := member.property^.(^PrivateIdentifier)
	return private
}

// Two references are compared link by link in a loop: member chains nest on
// the object side without limit, so there is one iteration per link and no
// recursion along the chain.
lint_same_reference :: proc(l: ^Linter, a, b: ^Expression) -> bool {
	left, right := lint_inner(a), lint_inner(b)
	for left != nil && right != nil {
		#partial switch first in left^ {
		case ^Super:
			_, same := right^.(^Super)
			return same
		case ^ThisExpression:
			_, same := right^.(^ThisExpression)
			return same
		case ^Identifier:
			second := lint_identifier(right)
			return second != nil && first.name == second.name
		}
		first, second := lint_member_of(left), lint_member_of(right)
		if first == nil || second == nil || !lint_same_member_link(l, first, second) { return false }
		left, right = lint_inner(first.object), lint_inner(second.object)
	}
	return false
}

// Whether two member accesses name the same property, leaving their objects
// to the caller. A computed key is an operand, bounded by the nesting limit.
lint_same_member_link :: proc(l: ^Linter, first, second: ^MemberExpression) -> bool {
	if l.options.self_assign_skip_props { return false }
	name, static := lint_static_property_name(first)
	other, other_static := lint_static_property_name(second)
	if static && other_static && name == other { return true }
	if first.computed != second.computed { return false }
	if first.computed { return lint_same_reference(l, first.property, second.property) }
	if lint_member_is_private(first) && lint_member_is_private(second) {
		return first.property^.(^PrivateIdentifier).name == second.property^.(^PrivateIdentifier).name
	}
	return false
}

lint_same_member :: proc(l: ^Linter, first, second: ^MemberExpression) -> bool {
	return lint_same_member_link(l, first, second) && lint_same_reference(l, first.object, second.object)
}

lint_check_self_assign :: proc(l: ^Linter, e: ^AssignmentExpression) {
	if e == nil || !lint_rule_enabled(l, .L2012_NoSelfAssign) { return }
	#partial switch e.operator {
	case .Assign, .AssignLogicalAnd, .AssignLogicalOr, .AssignNullish:
		lint_self_assign_pair(l, e.left, e.right)
	}
}

// Destructuring pairs each target with the value at the same position or
// under the same key. A spread on the right hides everything before it.
lint_self_assign_pair :: proc(l: ^Linter, target, value: ^Expression) {
	left := lint_unparen(target)
	if left == nil || value == nil { return }
	#partial switch pattern in left^ {
	case ^ArrayExpression:
		source := lint_unparen(value)
		array, is_array := source^.(^ArrayExpression)
		if !is_array { return }
		for index in 0..<min(len(pattern.elements), len(array.elements)) {
			item, has_item := array.elements[index].?
			if !has_item || item == nil { continue }
			if _, spread := item^.(^SpreadElement); spread { return }
			element, has_element := pattern.elements[index].?
			if !has_element || element == nil { continue }
			#partial switch _ in element^ {
			case ^AssignmentExpression, ^SpreadElement: continue
			}
			lint_self_assign_pair(l, element, item)
		}
		return
	case ^ObjectExpression:
		source := lint_inner(value)
		object, is_object := source^.(^ObjectExpression)
		if !is_object { return }
		first := 0
		for prop, index in object.properties {
			if prop.key == nil { first = index + 1 }
		}
		for binding in pattern.properties {
			if binding.key == nil { continue }
			for prop in object.properties[first:] { lint_self_assign_property(l, binding, prop) }
		}
		return
	}
	lint_self_assign_simple(l, left, value)
}

lint_self_assign_simple :: proc(l: ^Linter, left, value: ^Expression) {
	right := lint_unparen(value)
	if right == nil { return }
	if source := lint_identifier(right); source != nil {
		// A typed wrapper such as `(a as T) = a` still assigns `a` to itself.
		target := lint_identifier(lint_inner(left))
		if target != nil && target.name == source.name { lint_emit(l, lint_expr_loc(value), .L2012_NoSelfAssign) }
	}
	member, is_member := left^.(^MemberExpression)
	source := lint_member_of(right)
	if !is_member || member == nil || source == nil { return }
	if lint_same_member(l, source, member) { lint_emit(l, source.loc, .L2012_NoSelfAssign) }
}

lint_self_assign_property :: proc(l: ^Linter, binding, prop: Property) {
	if prop.key == nil || prop.kind == .Method || binding.value == nil || prop.value == nil { return }
	key, key_static := lint_property_static_name(prop.key, prop.computed)
	if !key_static { return }
	if binding.shorthand {
		// `{a} = {a}`: a default value makes the target a different node.
		target := lint_identifier(binding.value)
		source := lint_identifier(lint_unparen(prop.value))
		if target == nil || source == nil || key != target.name || source.name != target.name { return }
		lint_emit(l, prop.loc, .L2012_NoSelfAssign)
		return
	}
	if _, has_default := binding.value^.(^AssignmentExpression); has_default { return }
	name, static := lint_property_static_name(binding.key, binding.computed)
	if static && name == key { lint_self_assign_pair(l, binding.value, prop.value) }
}

// ---------------------------------------------------------------------------
// no-obj-calls
// ---------------------------------------------------------------------------

LintObjectCall :: struct { callee: ^Identifier, call: Loc }

// What a variable declarator binds: `simple` is false for a destructured name.
LintDeclaratorInit :: struct { init: ^Expression, simple, constant: bool }

LINT_GLOBAL_ALIAS_DEPTH_MAX :: 32

lint_is_namespace_global :: proc(name: string) -> bool {
	switch name {
	case "Atomics", "Intl", "JSON", "Math", "Reflect": return true
	}
	return false
}

lint_global_this_member :: proc(member: ^MemberExpression) -> (string, bool) {
	if !lint_is_specific_id(member.object, "globalThis") { return "", false }
	return lint_static_property_name(member)
}

lint_check_obj_calls :: proc(l: ^Linter, callee: ^Expression, call: Loc) {
	if callee == nil || !lint_rule_enabled(l, .L2020_NoObjCalls) { return }
	#partial switch node in callee^ {
	case ^Identifier:
		append(&l.object_calls, LintObjectCall{node, call})
	case ^MemberExpression:
		if name, ok := lint_global_this_member(node); ok && lint_is_namespace_global(name) {
			lint_emit(l, call, .L2020_NoObjCalls)
		}
	}
}

lint_record_pattern_names :: proc(l: ^Linter, pattern: Pattern, entry: LintDeclaratorInit) {
	switch node in pattern {
	case ^Identifier:        if node != nil { l.declarator_inits[node.loc.start] = entry }
	case ^AssignmentPattern: if node != nil { lint_record_pattern_names(l, node.left, entry) }
	case ^RestElement:       if node != nil { lint_record_pattern_names(l, node.argument, entry) }
	case ^ArrayPattern:
		if node == nil { return }
		for element in node.elements {
			if inner, ok := element.?; ok { lint_record_pattern_names(l, inner, entry) }
		}
	case ^ObjectPattern:
		if node == nil { return }
		for prop in node.properties { lint_record_pattern_names(l, prop.value, entry) }
	case ^MemberExpression:
	}
}

// Remember what each `var`/`let`/`const` name was initialized with, so a call
// through an alias (`const m = Math; m()`) can be traced to the global.
lint_record_declarator :: proc(l: ^Linter, decl: ^VariableDeclarator, kind: VariableKind) {
	needed := lint_rule_enabled(l, .L2020_NoObjCalls) || lint_rule_enabled(l, .L5006_BadReplaceAllArg) ||
		lint_rule_enabled(l, .L6006_NoThenable) || lint_rule_enabled(l, .L2056_NoShadowRestrictedNames) ||
		lint_rule_enabled(l, .L6009_PreferSetSize)
	if !needed { return }
	if l.declarator_inits == nil { l.declarator_inits = make(map[u32]LintDeclaratorInit, 16, l.allocator) }
	init, _ := decl.init.?
	_, simple := decl.id.(^Identifier)
	lint_record_pattern_names(l, decl.id, {init, simple, kind == .Const})
}

// Runs after scope analysis for the rules that need resolved references.
lint_parity_semantic :: proc(l: ^Linter, model: ^SemanticModel) {
	if lint_rule_enabled(l, .L2056_NoShadowRestrictedNames) || len(l.unassigned) > 0 {
		uses := lint_symbol_uses(model)
		lint_check_restricted_names(l, model, uses)
		lint_check_unassigned(l, model, uses)
	}
	pending := len(l.object_calls) + len(l.replace_all_calls) + len(l.then_references) + len(l.set_sizes)
	if pending == 0 { return }
	references := make(map[u32]SymbolId, len(model.refs), context.temp_allocator)
	for ref in model.refs { references[ref.start] = ref.resolved }
	lint_check_replace_all_aliases(l, model, references)
	lint_check_then_references(l, model, references)
	lint_check_set_size_references(l, model, references)
	for site in l.object_calls {
		name := lint_resolve_global_alias(l, model, references, site.callee)
		if lint_is_namespace_global(name) { lint_emit(l, site.call, .L2020_NoObjCalls) }
	}
}

// Follows `const a = JSON; const b = a;` back to the global it names. Returns
// "" when the chain ends at anything that is not a global.
lint_resolve_global_alias :: proc(
	l: ^Linter, model: ^SemanticModel, references: map[u32]SymbolId, start: ^Identifier,
) -> string {
	id := start
	for _ in 0..<LINT_GLOBAL_ALIAS_DEPTH_MAX {
		resolved, known := references[id.loc.start]
		if !known { return "" }
		if resolved == SYMBOL_UNRESOLVED { return id.name }
		entry, declared := l.declarator_inits[model.symbols[resolved].decl_start]
		if !declared { return "" }
		if !entry.simple { return id.name }
		if entry.init == nil { return "" }
		#partial switch init in entry.init^ {
		case ^Identifier:
			if init.name == id.name { return "" }
			id = init
			continue
		case ^MemberExpression:
			name, _ := lint_global_this_member(init)
			return name
		}
		return ""
	}
	return ""
}

// ---------------------------------------------------------------------------
// Rules decided per symbol once every reference is resolved.
// ---------------------------------------------------------------------------

LintSymbolUse :: struct { read, written: bool }

lint_symbol_uses :: proc(model: ^SemanticModel) -> []LintSymbolUse {
	uses := make([]LintSymbolUse, len(model.symbols), context.temp_allocator)
	for ref in model.refs {
		if ref.resolved == SYMBOL_UNRESOLVED { continue }
		use := &uses[ref.resolved]
		#partial switch ref.kind {
		case .Read:      use.read = true
		case .Write:     use.written = true
		case .ReadWrite: use.read, use.written = true, true
		}
	}
	return uses
}

lint_is_restricted_name :: proc(name: string) -> bool {
	switch name {
	case "Infinity", "NaN", "arguments", "eval", "undefined", "globalThis": return true
	}
	return false
}

// no-shadow-restricted-names: every declaration of such a name is reported.
// `var undefined;` that is never written keeps its meaning and is allowed.
lint_check_restricted_names :: proc(l: ^Linter, model: ^SemanticModel, uses: []LintSymbolUse) {
	if !lint_rule_enabled(l, .L2056_NoShadowRestrictedNames) { return }
	for symbol, offset in model.symbols[1:] {
		if !lint_is_restricted_name(symbol.name) { continue }
		if symbol.name == "globalThis" && l.options.restricted_names_skip_global_this { continue }
		if symbol.name == "undefined" {
			canonical := model.binding_index[{symbol.scope, symbol.name}]
			entry, declared := l.declarator_inits[symbol.decl_start]
			if declared && entry.simple && entry.init == nil && !uses[canonical].written { continue }
		}
		_ = offset
		lint_emit(l, {symbol.decl_start, symbol.decl_end}, .L2056_NoShadowRestrictedNames)
	}
}

// no-unassigned-vars: `let x;` that is read but never assigned.
lint_queue_unassigned :: proc(l: ^Linter, d: ^VariableDeclaration) {
	if d.kind == .Const || d.declare || !lint_rule_enabled(l, .L2057_NoUnassignedVars) { return }
	// A loop head assigns its binding on every iteration.
	top, is_stmt := l.ancestors[len(l.ancestors) - 1].(^Statement)
	if !is_stmt { return }
	if declaration, same := top^.(^VariableDeclaration); !same || declaration != d { return }
	for node in l.ancestors {
		stmt, ok := node.(^Statement)
		if !ok { continue }
		if _, ambient := stmt^.(^TSModuleDeclaration); ambient { return }
	}
	for decl in d.declarations {
		id, simple := decl.id.(^Identifier)
		if !simple || id == nil || decl.init != nil { continue }
		append(&l.unassigned, id)
	}
}

lint_check_unassigned :: proc(l: ^Linter, model: ^SemanticModel, uses: []LintSymbolUse) {
	if len(l.unassigned) == 0 { return }
	by_start := make(map[u32]SymbolId, len(model.symbols), context.temp_allocator)
	for symbol, offset in model.symbols[1:] { by_start[symbol.decl_start] = SymbolId(offset + 1) }
	for id in l.unassigned {
		declared, found := by_start[id.loc.start]
		if !found { continue }
		symbol := model.symbols[declared]
		use := uses[model.binding_index[{symbol.scope, symbol.name}]]
		if use.read && !use.written { lint_emit(l, lint_binding_loc(id), .L2057_NoUnassignedVars) }
	}
}
