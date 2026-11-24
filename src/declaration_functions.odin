package kessel

import "core:strings"

@(private)
dts_function :: proc(state: ^DeclarationEmit, fn: ^FunctionDeclaration, statement: Loc) {
	cg := &state.writer
	cg_str(cg, "function ")
	location := Loc{statement.start, statement.start + 6}
	if id, ok := fn.id.?; ok { cg_str(cg, id.name); location = id.loc }
	dts_signature(state, fn.params[:], fn.type_parameters, fn.return_type, dts_return_expression(fn.body.body[:]), fn.loc, location, fn.async || fn.generator, false, 0)
	cg_byte(cg, ';')
}

@(private)
dts_return_expression :: proc(body: []^Statement) -> ^Expression {
	if len(body) == 0 { return nil }
	ret, last := body[len(body) - 1]^.(^ReturnStatement)
	if !last { return nil }
	for stmt in body[:len(body) - 1] {
		#partial switch _ in stmt^ {
		case ^VariableDeclaration, ^FunctionDeclaration, ^ExpressionStatement, ^EmptyStatement, ^ClassDeclaration, ^TSInterfaceDeclaration, ^TSTypeAliasDeclaration:
		case: return nil
		}
	}
	return ret.argument.? or_else nil
}

@(private)
dts_signature :: proc(state: ^DeclarationEmit, params: []FunctionParameter, generics: Maybe(^TSTypeParameterDeclaration), result: Maybe(^TSTypeAnnotation), returned: ^Expression, scope, location: Loc, requires_annotation, arrow: bool, depth: int, method := false, arrow_node: ^ArrowFunctionExpression = nil) {
	cg := &state.writer
	dts_type_parameters(state, generics, scope)
	for p in params { dts_parameter_scope(state, p.pattern, scope) }
	// Diagnose the return type before parameters, including for anonymous functions.
	offset := cg.pos
	if ty, ok := result.?; ok {
		gen_ts_type(cg, ty.type_annotation)
	} else if requires_annotation || !dts_infer(state, returned, false, depth + 1) {
		if method {
			dts_error(state, "TS9008", "Method must have an explicit return type annotation with --isolatedDeclarations.", location)
		} else {
			error_span := location
			if arrow_node != nil { error_span = dts_arrow_error_span(state, arrow_node) }
			dts_error(state, "TS9007", "Function must have an explicit return type annotation with --isolatedDeclarations.", error_span)
		}
	}
	return_type := strings.clone(string(cg.buf[offset:cg.pos]))
	cg.pos = offset
	gen_ts_type_parameter_declaration(cg, generics)
	cg_byte(cg, '(')
	dts_parameters(state, params, depth)
	cg_str(cg, ") => " if arrow else "): ")
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
		local := p^
		annotation = p.type_annotation
		local.type_annotation = nil
		gen_pattern(cg, &local)
	case ^ArrayPattern:
		local := p^
		annotation = p.type_annotation
		local.type_annotation = nil
		gen_pattern(cg, &local)
	case: dts_error(state, "Unsupported_Declaration", "This parameter pattern is not supported yet.", location); return
	}
	if optional || (init != nil && trailing) { cg_byte(cg, '?') }
	cg_str(cg, ": ")
	type_start := cg.pos
	if ty, ok := annotation.?; ok { gen_ts_type(cg, ty.type_annotation) } else if !dts_infer(state, init, false, depth + 1) {
		if init != nil { location = get_expression_loc(init) }
		dts_error(state, "TS9011", "Parameter must have an explicit type annotation with --isolatedDeclarations.", location)
	}
	if init != nil && !trailing { dts_parameter_undefined(state, annotation, init, parameter.loc, type_start) }
}

// TypeScript binds named properties first, then resolves computed property names.
// Both forms can denote the same public property. Diagnose it only once.
@(private)
dts_function_assignments :: proc(state: ^DeclarationEmit) {
	seen := make(map[[2]string]bool)
	computed: [dynamic]^MemberExpression
	for stmt in state.regions[state.region].body {
		s, statement := stmt^.(^ExpressionStatement)
		if !statement { continue }
		assign, assignment := s.expression^.(^AssignmentExpression)
		if !assignment || assign.operator != .Assign { continue }
		member, property := assign.left^.(^MemberExpression)
		if !property { continue }
		base, plain := member.object^.(^Identifier)
		if !plain { continue }
		_, name, direct := enum_static_member(member)
		if !direct && member.computed {
			if number, numeric := member.property^.(^NumericLiteral); numeric {
				name, direct = dts_numeric_key(number.value), true
			}
		}
		if direct {
			dts_report_assignment(state, &seen, {base.name, name}, member.loc)
		} else if member.computed {
			append(&computed, member)
		}
	}
	for member in computed {
		if name, resolved := dts_computed_key(state, member.property); resolved {
			base := member.object^.(^Identifier)
			dts_report_assignment(state, &seen, {base.name, name}, member.loc)
		}
	}
}

@(private)
dts_report_assignment :: proc(state: ^DeclarationEmit, seen: ^map[[2]string]bool, key: [2]string, loc: Loc) {
	if key in seen^ { return }
	seen^[key] = true
	function := -1
	for index in dts_lookup(state, key[0], .Value) {
		item := &state.items[index]
		if !item.selected { continue }
		if item.child != 0 {
			symbol := state.regions[item.child].symbol
			for member in state.exports[{symbol, key[1]}] {
				if dts_declares_value(state.items[member].statement) { return }
			}
		}
		if dts_public_function(item) && function < 0 { function = index }
	}
	if function < 0 { return }
	state.current_item = function
	dts_error(state, "TS9023", "Assigning properties to functions without declaring them is not supported with --isolatedDeclarations. Add an explicit declaration for the properties assigned to this function.", loc)
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
					dts_error(state, "TS9011", "Parameter must have an explicit type annotation with --isolatedDeclarations.", t.loc)
					return
				}
				for index in dts_lookup(state, id.name, .Either) {
					if alias, ok := state.items[index].statement.(^TSTypeAliasDeclaration); ok && dts_type_has_undefined(alias.type_annotation) { return }
				}
				if len(dts_lookup(state, id.name, .Type)) == 0 && !dts_reference_is_local(state, {id.name, id.loc, false}) { return }
				dts_error(state, "TS9025", "Declaration emit for this parameter requires implicitly adding undefined to its type. This is not supported with --isolatedDeclarations.", parameter)
				return
			}
		}
	} else if dts_primitive_type(init) == "undefined" { return }
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
