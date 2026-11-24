package kessel

@(private)
dts_enum :: proc(state: ^DeclarationEmit, decl: ^TSEnumDeclaration) {
	if state.enums.allocator.procedure == nil {
		model := semantic_build(state.job.program, state.writer.source, state.job.lang, context.allocator, enum_constants = &state.enums)
		state.enum_scopes = model.enum_declarations
		state.external_enum_members = make(map[SemanticBindingKey]bool)
	}
	scope := state.enum_scopes[decl.loc.start]
	cg := &state.writer
	if decl.const_ { cg_str(cg, "const ") }
	cg_str(cg, "enum "); cg_str(cg, decl.id.name); cg_str(cg, " {")
	for member, i in decl.body.members {
		if i != 0 { cg_byte(cg, ',') }
		cg_newline(cg); cg.depth += 1
		gen_expression(cg, member.id, PREC_ASSIGN)
		name, valid := enum_member_name(member.id)
		if init, ok := member.initializer.?; ok && dts_enum_external(state, init, scope, decl.id.name) {
			state.external_enum_members[{scope, name}] = true
			dts_error(state, "TS9020", "Enum member initializers must be computable without references to external symbols with --isolatedDeclarations.", get_expression_loc(member.id))
		}
		if valid {
			#partial switch value in state.enums.values[{scope, name}] {
			case f64:
				buf: [64]byte
				cg_str(cg, " = "); cg_str(cg, enum_number_string(buf[:], value))
			case string: cg_str(cg, " = "); gen_string_quoted(cg, value)
			}
		}
		cg.depth -= 1
	}
	cg_newline(cg); cg_byte(cg, '}')
}

@(private)
dts_enum_external :: proc(state: ^DeclarationEmit, expr: ^Expression, scope: ScopeId, owner: string) -> bool {
	pending: [dynamic]^Expression
	append(&pending, expr)
	for len(pending) > 0 {
		node := pop(&pending)
		#partial switch e in node^ {
		case ^Identifier:
			if state.external_enum_members[{scope, e.name}] { return true }
			if state.enums.values[{scope, e.name}] != nil { continue }
			for index in dts_lookup(state, e.name, .Either) {
				item := state.items[index]
				if d, ok := item.statement.(^VariableDeclaration); ok && d.kind == .Const {
					if init, has := d.declarations[item.part].init.?; has && dts_primitive_type(init) != "" { return true }
				}
			}
		case ^MemberExpression:
			id, name, known := enum_static_member(e)
			if known && id.name == owner && state.external_enum_members[{scope, name}] { return true }
			if known && id.name != owner {
				for index in dts_lookup(state, id.name, .Either) { if _, is_enum := state.items[index].statement.(^TSEnumDeclaration); is_enum { return true } }
			}
		case ^ParenthesizedExpression: append(&pending, e.expression)
		case ^UnaryExpression: append(&pending, e.argument)
		case ^BinaryExpression: append(&pending, e.left, e.right)
		case ^TemplateLiteral: append(&pending, ..e.expressions[:])
		}
	}
	return false
}
