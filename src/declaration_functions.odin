package kessel

import "core:strings"

@(private)
dts_function :: proc(state: ^DeclarationEmit, fn: ^FunctionDeclaration, statement: Loc) {
	cg := &state.writer
	cg_str(cg, "function ")
	location := Loc{statement.start, statement.start + 6}
	if id, ok := fn.id.?; ok { cg_str(cg, id.name); location = id.loc }
	state.private_owner = .Function
	body := fn.body.body[:]
	dts_signature(state, {
		params = fn.params[:], generics = fn.type_parameters, result = fn.return_type,
		returned = dts_return_expression(body), body = body, scope = fn.loc, location = location,
		requires_annotation = fn.async || fn.generator,
	}, 0)
	state.private_owner = .Inferred
	cg_byte(cg, ';')
}

// TypeScript infers from a body whose only return statement is a direct child
// of the function block. A return nested in another statement leaves the type
// unknown. Like TypeScript, a bare `return;` before the candidate is ignored.
@(private)
dts_return_expression :: proc(body: []^Statement) -> ^Expression {
	candidate: ^Expression
	for stmt in body {
		assert(stmt != nil)
		if ret, direct := stmt^.(^ReturnStatement); direct {
			if candidate != nil { return nil }
			candidate = ret.argument.? or_else nil
		} else if dts_contains_return(stmt) {
			return nil
		}
	}
	return candidate
}

// Nested functions and classes own their return statements, so the walk only
// descends through statements that share the enclosing function's body.
@(private)
dts_contains_return :: proc(root: ^Statement) -> bool {
	assert(root != nil)
	pending: [dynamic]^Statement
	append(&pending, root)
	for len(pending) > 0 {
		stmt := pop(&pending)
		#partial switch s in stmt^ {
		case ^ReturnStatement: return true
		case ^BlockStatement: append(&pending, ..s.body[:])
		case ^LabeledStatement: append(&pending, s.body)
		case ^WhileStatement: append(&pending, s.body)
		case ^DoWhileStatement: append(&pending, s.body)
		case ^ForStatement: append(&pending, s.body)
		case ^ForInStatement: append(&pending, s.body)
		case ^ForOfStatement: append(&pending, s.body)
		case ^WithStatement: append(&pending, s.body)
		case ^IfStatement:
			append(&pending, s.consequent)
			if alternate, ok := s.alternate.?; ok { append(&pending, alternate) }
		case ^SwitchStatement:
			for clause in s.cases { append(&pending, ..clause.consequent[:]) }
		case ^TryStatement:
			append(&pending, ..s.block.body[:])
			if handler, ok := s.handler.?; ok { append(&pending, ..handler.body.body[:]) }
			if finalizer, ok := s.finalizer.?; ok { append(&pending, ..finalizer.body[:]) }
		}
	}
	return false
}

// Everything a signature is printed from. `returned` is the expression a
// missing return type may be inferred from; `location` is where a missing one
// is reported; `scope` is the span in which the parameters are in scope.
DeclarationSignature :: struct {
	params: []FunctionParameter,
	generics: Maybe(^TSTypeParameterDeclaration),
	result: Maybe(^TSTypeAnnotation),
	returned: ^Expression,
	body: []^Statement,
	scope, location: Loc,
	requires_annotation, arrow, method: bool,
	arrow_node: ^ArrowFunctionExpression,
}

@(private)
dts_signature :: proc(state: ^DeclarationEmit, sig: DeclarationSignature, depth: int) {
	cg := &state.writer
	private_mark := dts_private_push(state, sig.body)
	defer dts_private_pop(state, private_mark)
	params, generics := sig.params, sig.generics
	dts_type_parameters(state, generics, sig.scope)
	for p in params { dts_parameter_scope(state, p.pattern, sig.scope) }
	// Diagnose the return type before parameters, including for anonymous functions.
	offset := cg.pos
	if ty, ok := sig.result.?; ok {
		gen_ts_type(cg, ty.type_annotation)
	} else if sig.requires_annotation || !dts_infer(state, sig.returned, false, depth + 1) {
		if sig.method {
			dts_diagnose(state, .TS9008, sig.location)
		} else {
			error_span := sig.location
			if sig.arrow_node != nil { error_span = dts_arrow_error_span(state, sig.arrow_node) }
			dts_diagnose(state, .TS9007, error_span)
		}
	}
	return_type := strings.clone(string(cg.buf[offset:cg.pos]))
	cg.pos = offset
	gen_ts_type_parameter_declaration(cg, generics)
	cg_byte(cg, '(')
	dts_parameters(state, params, depth)
	cg_str(cg, ") => " if sig.arrow else "): ")
	cg_str(cg, return_type)
}

// A multiline block reports through the end of the arrow token's line. Comments
// between the arrow and the brace can themselves contain an arrow spelling.
@(private)
dts_arrow_error_span :: proc(state: ^DeclarationEmit, arrow: ^ArrowFunctionExpression) -> Loc {
	body, block := arrow.body.(^BlockStatement)
	if !block { return arrow.loc }
	source := state.writer.source
	comments := state.job.lexer.comments[:]
	limit := body.loc.start
	comment := codegen_comment_lower_bound(comments, limit)
	for limit > arrow.loc.start {
		found := strings.last_index(source[arrow.loc.start:limit], "=>")
		if found < 0 { break }
		token := arrow.loc.start + u32(found)
		for comment > 0 && comments[comment - 1].start > token { comment -= 1 }
		if comment > 0 && comments[comment - 1].end > token {
			limit = comments[comment - 1].start
			comment -= 1
			continue
		}
		for c, offset in source[token + 2:body.loc.end] {
			if c == '\n' || c == '\r' || c == 0x2028 || c == 0x2029 { return {arrow.loc.start, token + 2 + u32(offset)} }
		}
		break
	}
	return arrow.loc
}

@(private)
dts_parameters :: proc(state: ^DeclarationEmit, params: []FunctionParameter, depth: int) {
	cg := &state.writer
	last_required := -1
	for p, i in params {
		if p.default_val != nil { continue }
		#partial switch v in p.pattern {
		case ^AssignmentPattern, ^RestElement: continue
		case ^Identifier: if v.optional { continue }
		}
		last_required = i
	}
	for p, i in params {
		if i != 0 { cg_str(cg, ", ") }
		dts_parameter(state, p, i > last_required, depth)
	}
}

@(private)
dts_parameter :: proc(state: ^DeclarationEmit, parameter: FunctionParameter, trailing: bool, depth: int) {
	cg := &state.writer
	pattern := parameter.pattern
	init := parameter.default_val.? or_else nil
	if assignment, ok := pattern.(^AssignmentPattern); ok { pattern, init = assignment.left, assignment.right }
	if rest, ok := pattern.(^RestElement); ok { cg_str(cg, "..."); pattern = rest.argument }
	annotation: Maybe(^TSTypeAnnotation)
	optional := parameter.optional_destructuring
	location := get_pattern_loc(pattern)
	#partial switch p in pattern {
	case ^Identifier:
		cg_str(cg, p.name)
		annotation = p.type_annotation
		optional = p.optional
	case ^ObjectPattern:
		state.private_parameter = dts_pattern_text(state, p.loc, p.type_annotation)
		dts_pattern_references(state, pattern)
		state.private_parameter = ""
		local := p^
		annotation = p.type_annotation
		local.type_annotation = nil
		gen_pattern(cg, &local)
	case ^ArrayPattern:
		state.private_parameter = dts_pattern_text(state, p.loc, p.type_annotation)
		dts_pattern_references(state, pattern)
		state.private_parameter = ""
		local := p^
		annotation = p.type_annotation
		local.type_annotation = nil
		gen_pattern(cg, &local)
	case: dts_error(state, "Unsupported_Declaration", "This parameter pattern is not supported yet.", location); return
	}
	if optional || (init != nil && trailing) { cg_byte(cg, '?') }
	cg_str(cg, ": ")
	dts_parameter_type(state, parameter, annotation, init, optional, trailing, location, depth)
}

// A pattern's span includes its annotation. Its own text ends before that.
@(private)
dts_pattern_text :: proc(
	state: ^DeclarationEmit, loc: Loc, annotation: Maybe(^TSTypeAnnotation),
) -> string {
	end := loc.end
	if ty, ok := annotation.?; ok && ty.loc.start > loc.start && ty.loc.start < loc.end {
		end = ty.loc.start
	}
	assert(loc.start <= end)
	return state.writer.source[loc.start:end]
}

// Print a parameter's declared or inferred type. A parameter that callers may
// omit while a later one is required, and an optional parameter property, both
// read as `T | undefined`, so the union is made explicit in the declaration.
@(private)
dts_parameter_type :: proc(
	state: ^DeclarationEmit, parameter: FunctionParameter, annotation: Maybe(^TSTypeAnnotation),
	init: ^Expression, optional, trailing: bool, location: Loc, depth: int,
) {
	cg := &state.writer
	property := parameter.accessibility != .None || parameter.readonly || parameter.override_
	implicit_undefined := init != nil && !trailing
	if init == nil && optional && property { implicit_undefined = true }
	// TypeScript reports the whole parameter, including its property modifiers.
	span := parameter.loc
	if parameter.modifier_start != 0 { span.start = parameter.modifier_start }
	assert(span.start <= span.end)
	// A destructuring pattern never takes its type from a default value.
	binding := parameter.pattern
	if assignment, assigned := binding.(^AssignmentPattern); assigned { binding = assignment.left }
	_, object_pattern := binding.(^ObjectPattern)
	_, array_pattern := binding.(^ArrayPattern)
	destructured := object_pattern || array_pattern
	type_start := cg.pos
	if ty, ok := annotation.?; ok {
		if id, named := binding.(^Identifier); named { state.private_parameter = id.name }
		gen_ts_type(cg, ty.type_annotation)
		state.private_parameter = ""
	} else if init == nil && implicit_undefined {
		dts_diagnose(state, .TS9025, span)
		return
	} else if destructured && implicit_undefined {
		dts_diagnose(state, .TS9025, span)
		return
	} else if destructured || !dts_infer(state, init, false, depth + 1) {
		// With no type to extend, the implicit `| undefined` is the error.
		if implicit_undefined {
			dts_diagnose(state, .TS9025, span)
			return
		}
		// Without an initializer the whole parameter is reported, including
		// its modifiers and its `...` or `?` marker.
		error_location := span
		if init != nil { error_location = dts_expression_span(state, init) }
		dts_diagnose(state, .TS9011, error_location)
	}
	if implicit_undefined {
		dts_parameter_undefined(state, annotation, init, span, type_start)
	}
}

// TypeScript binds named properties first, then resolves computed property names.
// Both forms can denote the same public property. Diagnose it only once.
@(private)
dts_function_assignments :: proc(state: ^DeclarationEmit) {
	seen := make(map[[2]string]bool)
	computed: [dynamic]^MemberExpression
	// Assignments are found anywhere in the region's own statements, such as
	// inside an `if` or a call argument, but not inside nested functions.
	for member in dts_scan_region(state, state.region).assignments {
		if dts_entity_name_root(member.object) == nil { continue }
		name, direct := dts_assigned_name(member)
		if direct {
			dts_report_assignment(state, &seen, member, name)
		} else if member.computed {
			append(&computed, member)
		}
	}
	for member in computed {
		if name, resolved := dts_computed_key(state, member.property); resolved {
			dts_report_assignment(state, &seen, member, name)
		}
	}
}

@(private)
dts_assigned_name :: proc(member: ^MemberExpression) -> (name: string, direct: bool) {
	assert(member.property != nil)
	if !member.computed {
		id, named := member.property^.(^Identifier)
		if named { return id.name, true }
		return "", false
	}
	#partial switch key in member.property^ {
	case ^StringLiteral: return key.value, true
	case ^NumericLiteral: return dts_numeric_key(key.value), true
	}
	return "", false
}

// Resolve `fn` or `ns.inner.fn` to the declarations it names. Later names are
// exports of a namespace. For a property assignment the first name must be
// declared in this region, since TypeScript binds such assignments in the
// function's own container; a `lexical` lookup also searches enclosing regions.
@(private)
dts_resolve_entity :: proc(
	state: ^DeclarationEmit, target: ^Expression, lexical := false,
) -> []int {
	names: [dynamic]string
	current := target
	for current != nil {
		#partial switch node in current^ {
		case ^MemberExpression:
			id, named := node.property^.(^Identifier)
			if node.computed || !named { return nil }
			append(&names, id.name)
			current = node.object
			continue
		case ^Identifier: append(&names, node.name)
		case: return nil
		}
		break
	}
	if len(names) == 0 { return nil }
	candidates := state.regions[state.region].bindings[names[len(names) - 1]][:]
	if lexical { candidates = dts_lookup(state, names[len(names) - 1], .Either) }
	#reverse for segment in names[:len(names) - 1] {
		exported: [dynamic]int
		for index in candidates {
			child := state.items[index].child
			if child == 0 { continue }
			append(&exported, ..state.exports[{state.regions[child].symbol, segment}][:])
		}
		candidates = exported[:]
	}
	return candidates
}

@(private)
dts_report_assignment :: proc(
	state: ^DeclarationEmit, seen: ^map[[2]string]bool, member: ^MemberExpression, name: string,
) {
	target := get_expression_loc(member.object)
	key := [2]string{state.writer.source[target.start:target.end], name}
	if key in seen^ { return }
	seen^[key] = true
	function := -1
	for index in dts_resolve_entity(state, member.object) {
		item := &state.items[index]
		if !item.selected { continue }
		if item.child != 0 {
			symbol := state.regions[item.child].symbol
			for declared in state.exports[{symbol, name}] {
				if dts_declares_value(state.items[declared].statement) { return }
			}
		}
		if dts_public_function(item) && function < 0 { function = index }
	}
	if function < 0 { return }
	state.current_item = function
	dts_diagnose(state, .TS9023, member.loc)
}

@(private)
dts_public_function :: proc(item: ^DeclarationItem) -> bool {
	#partial switch decl in item.statement {
	case ^FunctionDeclaration: return true
	case ^VariableDeclaration:
		v := decl.declarations[item.part]
		binding, simple := v.id.(^Identifier)
		init, exists := v.init.?
		if !simple || binding.type_annotation != nil || !exists { return false }
		#partial switch _ in init^ { case ^ArrowFunctionExpression, ^FunctionExpression: return true }
	}
	return false
}

@(private)
dts_numeric_key :: proc(value: f64) -> string {
	buffer: [64]byte
	return strings.clone(enum_number_string(buffer[:], value))
}

// Resolve only name expressions with a statically known literal type. Follow
// object properties from the base outwards. A spread can hide an earlier key.
@(private)
dts_computed_key :: proc(state: ^DeclarationEmit, expr: ^Expression) -> (string, bool) {
	current := expr
	path: [dynamic]string
	readonly, literal := false, false
	// Alias cycles have no literal type. Bound both cycles and inference depth.
	for step := 0; current != nil && step < 128; step += 1 {
		#partial switch e in current^ {
		case ^MemberExpression:
			key, named := e.property^.(^Identifier)
			if e.computed || !named { return "", false }
			append(&path, key.name)
			current = e.object
		case ^Identifier:
			current, literal = dts_binding_initializer(state, e.name)
			readonly = false
		case ^ParenthesizedExpression: current = e.expression
		case ^TSAsExpression:
			if dts_is_const_type(e.type_annotation) {
				current, readonly, literal = e.expression, true, true
			} else if ty, exact := e.type_annotation^.(^TSLiteralType); exact {
				current, literal = ty.literal, true
			} else { return "", false }
		case ^ObjectExpression:
			if len(path) == 0 { return "", false }
			current = dts_static_property(e, pop(&path))
			literal = readonly
		case ^StringLiteral: return e.value, literal && len(path) == 0
		case ^NumericLiteral: return dts_numeric_key(e.value), literal && len(path) == 0
		case ^UnaryExpression:
			number, numeric := e.argument^.(^NumericLiteral)
			if numeric && e.operator == .Minus { return dts_numeric_key(-number.value), literal && len(path) == 0 }
			return "", false
		case: return "", false
		}
	}
	return "", false
}

@(private)
dts_binding_initializer :: proc(state: ^DeclarationEmit, name: string) -> (^Expression, bool) {
	for index in dts_lookup(state, name, .Either) {
		item := state.items[index]
		decl, variable := item.statement.(^VariableDeclaration)
		if !variable { continue }
		entry := decl.declarations[item.part]
		id, plain := entry.id.(^Identifier)
		if !plain { continue }
		if annotation, typed := id.type_annotation.?; typed {
			if ty, literal := annotation.type_annotation^.(^TSLiteralType); literal { return ty.literal, true }
			return nil, false
		}
		return entry.init.? or_else nil, decl.kind == .Const
	}
	return nil, false
}

@(private)
dts_static_property :: proc(object: ^ObjectExpression, name: string) -> ^Expression {
	for i := len(object.properties) - 1; i >= 0; i -= 1 {
		p := object.properties[i]
		if p.key == nil || p.value == nil { return nil }
		if _, spread := p.value^.(^SpreadElement); spread { return nil }
		if p.computed {
			if _, known := p.key^.(^StringLiteral); !known { return nil }
		}
		if dts_member_name(p.key) == name && p.kind == .Init { return p.value }
	}
	return nil
}

@(private)
dts_parameter_undefined :: proc(state: ^DeclarationEmit, annotation: Maybe(^TSTypeAnnotation), init: ^Expression, parameter: Loc, type_start: int) {
	cg := &state.writer
	ty: ^TSType
	group := false
	if a, typed := annotation.?; typed { ty = a.type_annotation } else {
		assert(init != nil)
		#partial switch e in init^ {
		case ^TSAsExpression: ty = e.type_annotation
		case ^TSTypeAssertion: ty = e.type_annotation
		case ^ArrowFunctionExpression, ^FunctionExpression: group = true
		}
	}
	if ty != nil {
		if dts_type_has_undefined(ty) { return }
		#partial switch t in ty^ {
		case ^TSFunctionType, ^TSConstructorType, ^TSConditionalType: group = true
		case ^TSTypeReference:
			id, plain := t.type_name^.(^Identifier)
			if plain && id.name != "const" {
				if annotation == nil {
					dts_diagnose(state, .TS9011, t.loc)
					return
				}
				for index in dts_lookup(state, id.name, .Either) {
					if alias, ok := state.items[index].statement.(^TSTypeAliasDeclaration); ok && dts_type_has_undefined(alias.type_annotation) { return }
				}
				declared := len(dts_lookup(state, id.name, .Type)) != 0
				if !declared && !dts_type_name_is_local(state, id) { return }
				dts_diagnose(state, .TS9025, parameter)
				return
			}
		}
	} else if init != nil && dts_primitive_type(init) == "undefined" { return }
	if group {
		text := strings.clone(string(cg.buf[type_start:cg.pos]))
		cg.pos = type_start
		cg_byte(cg, '('); cg_str(cg, text); cg_byte(cg, ')')
	}
	cg_str(cg, " | undefined")
}

@(private)
dts_type_has_undefined :: proc(ty: ^TSType) -> bool {
	types: [dynamic]^TSType
	append(&types, ty)
	for len(types) > 0 {
		node := pop(&types)
		#partial switch t in node^ {
		case ^TSKeywordType: if t.kind == .Undefined { return true }
		case ^TSUnionType: append(&types, ..t.types[:])
		case ^TSParenthesizedType: append(&types, t.type_annotation)
		}
	}
	return false
}
