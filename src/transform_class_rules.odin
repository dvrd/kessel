package kessel

import "core:strings"

// How a lowered class and the uses of its private names are printed. The
// class itself is rewritten in transform_class.odin; this file holds the
// rules the printer consults for each expression, and the statement forms.

// One step for an expression at a target without the ES2022 class features.
// Returns nil when nothing applies.
class_lower_expression :: proc(cg: ^Codegen, expr: ^Expression) -> ^Expression {
	state := cg.transform
	#partial switch node in expr^ {
	case ^ClassExpression:
		return class_expression(cg, expr, node)
	case ^CallExpression:
		if node.callee == nil { return nil }
		if _, is_super := node.callee^.(^Super); is_super {
			return class_super_call(cg, expr, node)
		}
		member, entry, info := class_private_member(cg, target_unwrap(cg, node.callee))
		if entry != nil {
			// `o.#m(a)` calls the method with `o` as its receiver.
			first, again := target_capture(cg, member.object, node.loc)
			method := class_private_read(cg, entry, info, first, node.loc)
			call := new(CallExpression, state.allocator)
			call^ = node^
			call.optional = false
			call.callee = target_member(
				state, method, transform_identifier(state, "call", node.loc.end), false, node.loc,
			)
			call.arguments = make([dynamic]^Expression, 0, len(node.arguments) + 1, state.allocator)
			append(&call.arguments, again)
			append(&call.arguments, ..node.arguments[:])
			return transform_expression(state, call)
		}
	case ^MemberExpression:
		if member, entry, info := class_private_member(cg, expr); entry != nil {
			return class_private_read(cg, entry, info, member.object, node.loc)
		}
	case ^AssignmentExpression:
		return class_private_assignment(cg, node)
	case ^UpdateExpression:
		return class_private_update(cg, node)
	case ^BinaryExpression:
		name, is_private := node.left^.(^PrivateIdentifier)
		if node.operator != .In || !is_private { return nil }
		entry, info := class_private_lookup(cg, name.name, node.loc.start)
		if entry == nil { return nil }
		store := class_private_brand(entry, info)
		arguments := [2]^Expression{transform_identifier(state, store, node.loc.end), node.right}
		return class_helper_call(cg, .Private_In, arguments[:], node.loc.end)
	case ^ChainExpression:
		// A private name inside an optional chain is reached through the
		// lowered form of the chain, even when the target has `?.`.
		if state.target >= .ES2020 && class_chain_has_private(cg, node.expression) {
			return target_chain(cg, node.expression, node.loc, false)
		}
	case ^TaggedTemplateExpression:
		if _, entry, _ := class_private_member(cg, target_unwrap(cg, node.tag)); entry != nil {
			what := "a private method used as a template tag cannot be lowered"
			cg_strip_unsupported(cg, node.loc, what)
		}
	case ^MetaProperty:
		if node.meta.name != "new" { return nil }
		for info in state.class_list {
			for range in info.initializers {
				if node.loc.start >= range.start && node.loc.start < range.end {
					what := "new.target in a field initializer cannot be lowered"
					cg_strip_unsupported(cg, node.loc, what)
				}
			}
		}
	case ^ObjectExpression:
		for property in node.properties {
			class_note_name(cg, property.key, property.value, property.computed)
		}
	}
	return nil
}

// Records the name an anonymous class takes from the binding or property it
// is the value of. The class may stop being a plain class expression when it
// is lowered, and would then no longer be named by its context.
class_note_name :: proc(cg: ^Codegen, key, value: ^Expression, computed := false) {
	if key == nil || value == nil || computed { return }
	class, is_class := target_unwrap(cg, value)^.(^ClassExpression)
	if !is_class || class.id != nil { return }
	#partial switch node in key^ {
	case ^Identifier:    cg.transform.class_names[class.loc.start] = node.name
	case ^StringLiteral: cg.transform.class_names[class.loc.start] = node.value
	}
}

class_note_pattern_names :: proc(cg: ^Codegen, pattern: Pattern, init: Maybe(^Expression)) {
	state := cg.transform
	if state.target >= .ES2022 { return }
	#partial switch node in pattern {
	case ^Identifier:
		value, present := init.?
		if !present || value == nil { return }
		class, is_class := target_unwrap(cg, value)^.(^ClassExpression)
		if is_class && class.id == nil { state.class_names[class.loc.start] = node.name }
	case ^AssignmentPattern:
		class_note_pattern_names(cg, node.left, node.right)
	case ^ObjectPattern:
		for property in node.properties { class_note_pattern_names(cg, property.value, nil) }
	case ^ArrayPattern:
		for element in node.elements {
			if inner, present := element.?; present { class_note_pattern_names(cg, inner, nil) }
		}
	}
}

// The innermost lowered class around `offset` that declares the private name.
class_private_lookup :: proc(
	cg: ^Codegen, name: string, offset: u32) -> (^ClassPrivate, ^LoweredClass,
) {
	best: ^LoweredClass
	found: ^ClassPrivate
	for info in cg.transform.class_list {
		range := info.class.loc
		if !info.lowered || offset < range.start || offset >= range.end { continue }
		entry := class_private_find(info, name)
		if entry == nil { continue }
		if best == nil || range.start >= best.class.loc.start {
			best = info
			found = entry
		}
	}
	return found, best
}

class_private_member :: proc(
	cg: ^Codegen, expr: ^Expression) -> (^MemberExpression, ^ClassPrivate, ^LoweredClass,
) {
	if expr == nil { return nil, nil, nil }
	member, is_member := expr^.(^MemberExpression)
	if !is_member || member.property == nil { return nil, nil, nil }
	name, is_private := member.property^.(^PrivateIdentifier)
	if !is_private { return nil, nil, nil }
	entry, info := class_private_lookup(cg, name.name, name.loc.start)
	return member, entry, info
}

class_chain_has_private :: proc(cg: ^Codegen, root: ^Expression) -> bool {
	current := root
	for current != nil {
		current = codegen_runtime_expression(cg, current)
		#partial switch node in current^ {
		case ^MemberExpression:
			if node.property != nil {
				if _, private := node.property^.(^PrivateIdentifier); private { return true }
			}
			current = node.object
			continue
		case ^CallExpression:
			current = node.callee
			continue
		}
		break
	}
	return false
}

// The set that proves an object has the private member: the WeakMap of a
// field, or the brand shared by the methods and accessors of the class.
class_private_brand :: proc(entry: ^ClassPrivate, info: ^LoweredClass) -> string {
	if entry.kind == .Field { return entry.storage }
	return info.static_brand if entry.static else info.brand
}

class_private_read :: proc(
	cg: ^Codegen, entry: ^ClassPrivate, info: ^LoweredClass, object: ^Expression, loc: Loc,
) -> ^Expression {
	state := cg.transform
	at := loc.end
	store := transform_identifier(state, entry.storage, at)
	brand := transform_identifier(state, class_private_brand(entry, info), at)
	switch entry.kind {
	case .Field:    return class_helper_call(cg, .Private_Get, {object, store}, at)
	case .Method:   return class_helper_call(cg, .Private_Method, {object, brand, store}, at)
	case .Accessor: return class_helper_call(cg, .Private_Accessor_Get, {object, brand, store}, at)
	}
	return nil
}

class_private_write :: proc(
	cg: ^Codegen, entry: ^ClassPrivate, info: ^LoweredClass, object, value: ^Expression, loc: Loc,
) -> ^Expression {
	state := cg.transform
	at := loc.end
	store := transform_identifier(state, entry.storage, at)
	brand := transform_identifier(state, class_private_brand(entry, info), at)
	switch entry.kind {
	case .Field:    return class_helper_call(cg, .Private_Set, {object, store, value}, at)
	case .Method:   return class_helper_call(cg, .Private_Readonly, {object, brand, value}, at)
	case .Accessor:
		return class_helper_call(cg, .Private_Accessor_Set, {object, brand, store, value}, at)
	}
	return nil
}

class_private_assignment :: proc(cg: ^Codegen, node: ^AssignmentExpression) -> ^Expression {
	state := cg.transform
	left := target_unwrap(cg, node.left)
	member, entry, info := class_private_member(cg, left)
	if entry == nil {
		if id, plain := left^.(^Identifier); plain {
			class_note_name(cg, left, node.right)
			_ = id
		} else if _, simple := left^.(^MemberExpression); !simple {
			class_lower_private_targets(cg, left)
		}
		return nil
	}
	loc := node.loc
	if node.operator == .Assign {
		return class_private_write(cg, entry, info, member.object, node.right, loc)
	}
	first, again := target_capture(cg, member.object, loc)
	logical: Maybe(LogicalOperator)
	binary: BinaryOperator
	#partial switch node.operator {
	case .AssignLogicalOr:   logical = .Or
	case .AssignLogicalAnd:  logical = .And
	case .AssignNullish:     logical = .NullishCoalescing
	case .AddAssign:         binary = .Add
	case .SubAssign:         binary = .Sub
	case .MulAssign:         binary = .Mul
	case .DivAssign:         binary = .Div
	case .ModAssign:         binary = .Mod
	case .PowAssign:         binary = .Pow
	case .ShiftLeftAssign:   binary = .ShiftLeft
	case .ShiftRightAssign:  binary = .ShiftRight
	case .ShiftRightUAssign: binary = .ShiftRightUnsigned
	case .BitOrAssign:       binary = .BitOr
	case .BitXorAssign:      binary = .BitXor
	case .BitAndAssign:      binary = .BitAnd
	}
	if operator, is_logical := logical.?; is_logical {
		// `o.#x ||= v` reads once and writes only when the read does not decide.
		read := class_private_read(cg, entry, info, first, loc)
		write := class_private_write(cg, entry, info, again, node.right, loc)
		return target_logical(state, operator, read, write, loc)
	}
	// `o.#x += v` is `set(t = o, get(t) + v)`: object, old value, operand, write.
	read := class_private_read(cg, entry, info, again, loc)
	sum := target_binary(state, binary, read, node.right, loc)
	return class_private_write(cg, entry, info, first, sum, loc)
}

// `o.#x++` keeps the old value in a temporary that is itself incremented,
// which applies the same numeric conversion as the original operator.
class_private_update :: proc(cg: ^Codegen, node: ^UpdateExpression) -> ^Expression {
	state := cg.transform
	member, entry, info := class_private_member(cg, target_unwrap(cg, node.argument))
	if entry == nil { return nil }
	loc := node.loc
	first, again := target_capture(cg, member.object, loc)
	value := target_temp(cg, loc.end)
	step := new(UpdateExpression, state.allocator)
	step^ = {loc = loc, operator = node.operator, argument = value, prefix = node.prefix}
	sequence := new(SequenceExpression, state.allocator)
	sequence.loc = loc
	sequence.expressions = make([dynamic]^Expression, 0, 4, state.allocator)
	append(
		&sequence.expressions,
		target_assign(state, value, class_private_read(cg, entry, info, first, loc), loc),
	)
	if node.prefix {
		append(
			&sequence.expressions,
			class_private_write(cg, entry, info, again, transform_expression(state, step), loc),
		)
	} else {
		old := target_temp(cg, loc.end)
		append(
			&sequence.expressions,
			target_assign(state, old, transform_expression(state, step), loc),
		)
		append(&sequence.expressions, class_private_write(cg, entry, info, again, value, loc))
		append(&sequence.expressions, old)
	}
	return transform_expression(state, sequence)
}

// A private name as a destructuring target, as in `[o.#x] = values`, cannot
// become a call. It becomes a property with a setter that performs the
// write; the object is evaluated where the target was, as an argument:
//
//     ((object) => ({ set value(next) { set(object, x, next); } }))(o).value
class_lower_private_targets :: proc(cg: ^Codegen, expr: ^Expression) {
	if expr == nil { return }
	state := cg.transform
	inner := target_unwrap(cg, expr)
	#partial switch node in inner^ {
	case ^MemberExpression:
		member, entry, info := class_private_member(cg, inner)
		if entry == nil { return }
		loc := node.loc
		at := loc.end
		object := codegen_fresh_runtime_binding(cg, "object")
		next := codegen_fresh_runtime_binding(cg, "value")
		write := class_private_write(
			cg, entry, info,
			transform_identifier(state, object, at), transform_identifier(state, next, at), loc,
		)
		setter := new(FunctionExpression, state.allocator)
		setter.loc = {at, at}
		setter.body.loc = {at, at}
		setter.params = make([dynamic]FunctionParameter, 0, 1, state.allocator)
		append(&setter.params, FunctionParameter{
			loc = {at, at}, pattern = transform_identifier(state, next, at)^.(^Identifier),
		})
		setter.body.body = make([dynamic]^Statement, 0, 1, state.allocator)
		append(&setter.body.body, class_statement(state, write, at))
		holder := new(ObjectExpression, state.allocator)
		holder.loc = {at, at}
		holder.properties = make([dynamic]Property, 0, 1, state.allocator)
		append(&holder.properties, Property{
			loc = {at, at}, kind = .Set,
			key = transform_identifier(state, "value", at),
			value = transform_expression(state, setter),
		})
		arrow := new(ArrowFunctionExpression, state.allocator)
		arrow^ = {loc = {at, at}, body = transform_expression(state, holder), expression = true}
		arrow.params = make([dynamic]FunctionParameter, 0, 1, state.allocator)
		append(&arrow.params, FunctionParameter{
			loc = {at, at}, pattern = transform_identifier(state, object, at)^.(^Identifier),
		})
		made := target_call(state, transform_expression(state, arrow), {member.object}, loc)
		inner^ = target_member(state, made, transform_identifier(state, "value", at), false, loc)^
	case ^ArrayExpression:
		for element in node.elements {
			if item, present := element.?; present { class_lower_private_targets(cg, item) }
		}
	case ^ObjectExpression:
		for property in node.properties { class_lower_private_targets(cg, property.value) }
	case ^AssignmentExpression: class_lower_private_targets(cg, node.left)
	case ^SpreadElement:        class_lower_private_targets(cg, node.argument)
	}
}

// `super(...)` in a constructor that has initializers becomes
// `(super(...), <initializers>, this)`.
class_super_call :: proc(cg: ^Codegen, expr: ^Expression, node: ^CallExpression) -> ^Expression {
	state := cg.transform
	if state.super_done[expr] { return nil }
	owner: ^LoweredClass
	for info in state.class_list {
		range := info.constructor
		if node.loc.start < range.start || node.loc.start >= range.end { continue }
		if owner == nil || range.start >= owner.constructor.start { owner = info }
	}
	if owner == nil || !owner.wraps_super { return nil }
	state.super_done[expr] = true
	sequence := new(SequenceExpression, state.allocator)
	sequence.loc = node.loc
	sequence.expressions = make([dynamic]^Expression, 0, len(owner.instance) + 2, state.allocator)
	append(&sequence.expressions, expr)
	append(&sequence.expressions, ..owner.instance[:])
	append(&sequence.expressions, class_this(state, node.loc.end))
	return transform_expression(state, sequence)
}

// `let a = new WeakMap(), b;` for the bindings one evaluation of the class owns.
class_temps_statement :: proc(cg: ^Codegen, info: ^LoweredClass) -> ^Statement {
	state := cg.transform
	at := info.class.loc.start
	declaration := new(VariableDeclaration, state.allocator)
	declaration.loc = {at, at}
	declaration.kind = .Let
	declaration.declarations = make(
		[dynamic]VariableDeclarator, 0, len(info.temps), state.allocator,
	)
	for temp in info.temps {
		declarator := VariableDeclarator{
			loc = {at, at}, id = transform_identifier(state, temp.name, at)^.(^Identifier),
		}
		if temp.kind != .Plain {
			constructor := "WeakMap" if temp.kind == .Weak_Map else "WeakSet"
			if !state.weak_checked {
				state.weak_checked = true
				for symbol in transform_model(cg).symbols {
					if symbol.name == "WeakMap" || symbol.name == "WeakSet" {
						what := "a binding named WeakMap or WeakSet prevents lowering private names"
						cg_strip_unsupported(cg, info.class.loc, what)
					}
				}
			}
			created := new(NewExpression, state.allocator)
			created^ = {loc = {at, at}, callee = transform_identifier(state, constructor, at)}
			declarator.init = transform_expression(state, created)
		}
		append(&declaration.declarations, declarator)
	}
	statement := new(Statement, state.allocator)
	statement^ = declaration
	return statement
}

// A class expression. One that needs bindings of its own is produced by an
// arrow function called at once, which keeps `this` and `arguments`.
class_expression :: proc(cg: ^Codegen, expr: ^Expression, class: ^ClassExpression) -> ^Expression {
	state := cg.transform
	if class.declare { return nil }
	info := class_lower(cg, class, state.class_names[class.loc.start] or_else "")
	if !info.lowered || info.emitted { return nil }
	info.emitted = true
	at := class.loc.start
	result := expr
	if info.static_key != "" {
		method := target_member(
			state, expr, transform_identifier(state, info.static_key, at), false, {at, at},
		)
		result = target_call(state, method, nil, {at, at})
	}
	if len(info.temps) == 0 { return result if result != expr else nil }
	class_reject_suspension(cg, class)
	returned := new(ReturnStatement, state.allocator)
	returned^ = {loc = {at, at}, argument = result}
	statement := new(Statement, state.allocator)
	statement^ = returned
	block := new(BlockStatement, state.allocator)
	block.loc = {at, at}
	block.body = make([dynamic]^Statement, 0, 2, state.allocator)
	append(&block.body, class_temps_statement(cg, info), statement)
	arrow := new(ArrowFunctionExpression, state.allocator)
	arrow^ = {loc = {at, at}, body = block}
	return target_call(state, transform_expression(state, arrow), nil, {at, at})
}

// The arrow that wraps a class expression cannot contain `await` or `yield`
// of the enclosing function. They can only occur in the heritage and in
// computed keys; the test is textual and may refuse more than it must.
class_reject_suspension :: proc(cg: ^Codegen, class: ^ClassExpression) {
	check :: proc(cg: ^Codegen, expr: ^Expression) {
		if expr == nil { return }
		loc := loc_from_expr(expr)
		if loc.end > u32(len(cg.source)) || loc.start >= loc.end { return }
		text := cg.source[loc.start:loc.end]
		if strings.contains(text, "await") || strings.contains(text, "yield") {
			what := "await or yield in the head of this class expression cannot be lowered"
			cg_strip_unsupported(cg, loc, what)
		}
	}
	if super, present := class.super_class.?; present { check(cg, super) }
	for element in class.body.body {
		if element.computed { check(cg, element.key) }
	}
}

// A class declaration that was lowered: its bindings, the class, and the
// call that runs its static part. Returns false when the class prints as is.
class_declaration_emit :: proc(cg: ^Codegen, info: ^LoweredClass, export: TransformExport) -> bool {
	if info == nil || !info.lowered { return false }
	class := info.class
	id := class.id.? or_else unreachable()
	class_declaration_before(cg, info)
	if export == .Named { cg_module_keyword(cg, "export ") }
	if export == .Default { cg_module_keyword(cg, "export default ") }
	if cg.sm != nil { sourcemap_record(cg.sm, u32(cg.pos), class.loc.start) }
	gen_class_like(
		cg, id.name, class.super_class, class.body,
		class.type_parameters, class.super_type_arguments, class.implements,
	)
	class_declaration_after(cg, info, id.name)
	return true
}

class_declaration_before :: proc(cg: ^Codegen, info: ^LoweredClass) {
	if info == nil || len(info.temps) == 0 { return }
	gen_statement(cg, class_temps_statement(cg, info)^)
	cg_newline(cg)
	cg_indent(cg)
}

class_declaration_after :: proc(cg: ^Codegen, info: ^LoweredClass, name: string) {
	if info == nil || info.static_key == "" { return }
	cg_newline(cg)
	cg_indent(cg)
	cg_str(cg, name)
	cg_byte(cg, '.')
	cg_str(cg, info.static_key)
	cg_str(cg, "();")
}
