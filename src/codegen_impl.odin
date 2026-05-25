package kessel

// ============================================================================
// Codegen — per-node implementations.
// ============================================================================
//
// Split from `codegen.odin` to keep each file under ~500 LOC. Procedures
// here follow the dispatch order from `codegen.odin` so the two files can
// be read top-to-bottom together.
//
// Coverage goal: every Statement / Expression / Pattern / TS / JSX variant
// the parser can produce. Unknown / unhandled variants emit a syntactically
// distinguishable placeholder (`/*?Foo*/`) so a regression never silently
// produces wrong JavaScript.

// (no external imports — all helpers live in this package)

// ============================================================================
// Statements
// ============================================================================

gen_expression_statement :: proc(cg: ^Codegen, s: ^ExpressionStatement) {
	gen_expression(cg, s.expression, PREC_LOWEST)
	cg_byte(cg, ';')
}

gen_block_statement :: proc(cg: ^Codegen, s: ^BlockStatement) {
	cg_byte(cg, '{')
	if len(s.body) == 0 { cg_byte(cg, '}'); return }
	cg_newline(cg)
	cg.depth += 1
	for i in 0..<len(s.body) {
		gen_statement(cg, s.body[i]^)
		cg_newline(cg)
	}
	cg.depth -= 1
	cg_byte(cg, '}')
}

gen_return_statement :: proc(cg: ^Codegen, s: ^ReturnStatement) {
	cg_str(cg, "return")
	if arg, ok := s.argument.?; ok {
		cg_hard_space(cg)
		gen_expression(cg, arg, PREC_LOWEST)
	}
	cg_byte(cg, ';')
}

gen_break_statement :: proc(cg: ^Codegen, s: ^BreakStatement) {
	cg_str(cg, "break")
	if lbl, ok := s.label.?; ok {
		cg_hard_space(cg)
		cg_str(cg, lbl.name)
	}
	cg_byte(cg, ';')
}

gen_continue_statement :: proc(cg: ^Codegen, s: ^ContinueStatement) {
	cg_str(cg, "continue")
	if lbl, ok := s.label.?; ok {
		cg_hard_space(cg)
		cg_str(cg, lbl.name)
	}
	cg_byte(cg, ';')
}

gen_labeled_statement :: proc(cg: ^Codegen, s: ^LabeledStatement) {
	cg_str(cg, s.label.name)
	cg_byte(cg, ':')
	cg_space(cg)
	gen_statement(cg, s.body^)
}

gen_if_statement :: proc(cg: ^Codegen, s: ^IfStatement) {
	cg_str(cg, "if")
	cg_space(cg)
	cg_byte(cg, '(')
	gen_expression(cg, s.test, PREC_LOWEST)
	cg_byte(cg, ')')
	cg_space(cg)
	gen_statement(cg, s.consequent^)
	if alt, ok := s.alternate.?; ok {
		cg_space(cg)
		cg_str(cg, "else")
		cg_hard_space(cg)
		gen_statement(cg, alt^)
	}
}

gen_switch_statement :: proc(cg: ^Codegen, s: ^SwitchStatement) {
	cg_str(cg, "switch")
	cg_space(cg)
	cg_byte(cg, '(')
	gen_expression(cg, s.discriminant, PREC_LOWEST)
	cg_byte(cg, ')')
	cg_space(cg)
	cg_byte(cg, '{')
	cg_newline(cg)
	cg.depth += 1
	for c in s.cases {
		if t, ok := c.test.?; ok {
			cg_str(cg, "case ")
			gen_expression(cg, t, PREC_LOWEST)
			cg_byte(cg, ':')
		} else {
			cg_str(cg, "default:")
		}
		cg_newline(cg)
		cg.depth += 1
		for st in c.consequent {
			gen_statement(cg, st^)
			cg_newline(cg)
		}
		cg.depth -= 1
	}
	cg.depth -= 1
	cg_byte(cg, '}')
}

gen_while_statement :: proc(cg: ^Codegen, s: ^WhileStatement) {
	cg_str(cg, "while")
	cg_space(cg)
	cg_byte(cg, '(')
	gen_expression(cg, s.test, PREC_LOWEST)
	cg_byte(cg, ')')
	cg_space(cg)
	gen_statement(cg, s.body^)
}

gen_do_while_statement :: proc(cg: ^Codegen, s: ^DoWhileStatement) {
	cg_str(cg, "do")
	cg_space(cg)
	gen_statement(cg, s.body^)
	cg_space(cg)
	cg_str(cg, "while")
	cg_space(cg)
	cg_byte(cg, '(')
	gen_expression(cg, s.test, PREC_LOWEST)
	cg_str(cg, ");")
}

gen_for_statement :: proc(cg: ^Codegen, s: ^ForStatement) {
	cg_str(cg, "for")
	cg_space(cg)
	cg_byte(cg, '(')
	if v, ok := s.init_decl.?; ok {
		gen_variable_declaration(cg, v, false)
	} else if v, ok := s.init_expr.?; ok {
		gen_expression(cg, v, PREC_LOWEST)
	}
	cg_byte(cg, ';')
	if t, ok := s.test.?; ok { cg_space(cg); gen_expression(cg, t, PREC_LOWEST) }
	cg_byte(cg, ';')
	if u, ok := s.update.?; ok { cg_space(cg); gen_expression(cg, u, PREC_LOWEST) }
	cg_byte(cg, ')')
	cg_space(cg)
	gen_statement(cg, s.body^)
}

gen_for_in_statement :: proc(cg: ^Codegen, s: ^ForInStatement) {
	cg_str(cg, "for")
	cg_space(cg)
	cg_byte(cg, '(')
	if v, ok := s.left_decl.?; ok {
		gen_variable_declaration(cg, v, false)
	} else if v, ok := s.left_expr.?; ok {
		gen_expression(cg, v, PREC_LOWEST)
	}
	cg_str(cg, " in ")
	gen_expression(cg, s.right, PREC_LOWEST)
	cg_byte(cg, ')')
	cg_space(cg)
	gen_statement(cg, s.body^)
}

gen_for_of_statement :: proc(cg: ^Codegen, s: ^ForOfStatement) {
	cg_str(cg, "for")
	if s.await { cg_str(cg, " await") }
	cg_space(cg)
	cg_byte(cg, '(')
	if v, ok := s.left_decl.?; ok {
		gen_variable_declaration(cg, v, false)
	} else if v, ok := s.left_expr.?; ok {
		gen_expression(cg, v, PREC_LOWEST)
	}
	cg_str(cg, " of ")
	gen_expression(cg, s.right, PREC_ASSIGN)
	cg_byte(cg, ')')
	cg_space(cg)
	gen_statement(cg, s.body^)
}

gen_with_statement :: proc(cg: ^Codegen, s: ^WithStatement) {
	cg_str(cg, "with")
	cg_space(cg)
	cg_byte(cg, '(')
	gen_expression(cg, s.object, PREC_LOWEST)
	cg_byte(cg, ')')
	cg_space(cg)
	gen_statement(cg, s.body^)
}

gen_throw_statement :: proc(cg: ^Codegen, s: ^ThrowStatement) {
	cg_str(cg, "throw ")
	gen_expression(cg, s.argument, PREC_LOWEST)
	cg_byte(cg, ';')
}

gen_try_statement :: proc(cg: ^Codegen, s: ^TryStatement) {
	cg_str(cg, "try")
	cg_space(cg)
	block := s.block
	gen_block_statement(cg, &block)
	if h, ok := s.handler.?; ok {
		cg_space(cg)
		cg_str(cg, "catch")
		if p, pok := h.param.?; pok {
			cg_space(cg)
			cg_byte(cg, '(')
			gen_pattern(cg, p)
			cg_byte(cg, ')')
		}
		cg_space(cg)
		hb := h.body
		gen_block_statement(cg, &hb)
	}
	if fin, ok := s.finalizer.?; ok {
		cg_space(cg)
		cg_str(cg, "finally")
		cg_space(cg)
		gen_block_statement(cg, &fin)
	}
}

gen_function_declaration :: proc(cg: ^Codegen, s: ^FunctionDeclaration) {
	name := ""
	if id, ok := s.id.?; ok { name = id.name }
	gen_function_expression_like(cg, s.async, s.generator, name, s.params[:], s.body, s.no_body, s.type_parameters, s.return_type, true)
}

gen_variable_declaration :: proc(cg: ^Codegen, s: ^VariableDeclaration, with_semicolon: bool) {
	switch s.kind {
	case .Var:   cg_str(cg, "var")
	case .Let:   cg_str(cg, "let")
	case .Const: cg_str(cg, "const")
	case .Using: cg_str(cg, "using")
	case .AwaitUsing: cg_str(cg, "await using")
	}
	cg_hard_space(cg)
	for i in 0..<len(s.declarations) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		d := s.declarations[i]
		gen_pattern(cg, d.id)
		if init, ok := d.init.?; ok {
			cg_space(cg)
			cg_byte(cg, '=')
			cg_space(cg)
			gen_expression(cg, init, PREC_ASSIGN)
		}
	}
	if with_semicolon { cg_byte(cg, ';') }
}

gen_class_declaration :: proc(cg: ^Codegen, s: ^ClassDeclaration) {
	name := ""
	if id, ok := s.id.?; ok { name = id.name }
	gen_class_like(cg, name, s.super_class, s.body, s.type_parameters, s.super_type_arguments, s.implements)
}

gen_import_declaration :: proc(cg: ^Codegen, s: ^ImportDeclaration) {
	cg_str(cg, "import ")
	first := true
	// Default + namespace specifiers (each appears at most once).
	for spec in s.specifiers {
		switch v in spec^ {
		case ImportDefaultSpecifier:
			if !first { cg_str(cg, ", ") }
			cg_str(cg, v.local.name)
			first = false
		case ImportNamespaceSpecifier:
			if !first { cg_str(cg, ", ") }
			cg_str(cg, "* as ")
			cg_str(cg, v.local.name)
			first = false
		case ImportSpecifier:
			// emitted in the `{...}` group below
		}
	}
	// Named specifiers.
	any_named := false
	for spec in s.specifiers {
		if _, ok := spec^.(ImportSpecifier); ok { any_named = true; break }
	}
	if any_named {
		if !first { cg_str(cg, ", ") }
		cg_byte(cg, '{')
		first_named := true
		for spec in s.specifiers {
			v, ok := spec^.(ImportSpecifier)
			if !ok { continue }
			if !first_named { cg_str(cg, ", ") } else { cg_space(cg) }
			first_named = false
			if v.imported.name != v.local.name {
				cg_str(cg, v.imported.name)
				cg_str(cg, " as ")
				cg_str(cg, v.local.name)
			} else {
				cg_str(cg, v.local.name)
			}
		}
		cg_space(cg)
		cg_byte(cg, '}')
		first = false
	}
	if !first { cg_str(cg, " from ") }
	gen_string_quoted(cg, s.source.value)
	cg_byte(cg, ';')
}

// Emit either side of `export { local as exported }`. ExportSpecifierName is
// `IdentifierName | ^StringLiteral` (ES2022 string-literal exports).
gen_export_specifier_name :: proc(cg: ^Codegen, n: ExportSpecifierName) {
	switch v in n {
	case IdentifierName:   cg_str(cg, v.name)
	case ^StringLiteral:   gen_string_literal(cg, v)
	}
}

// True when the two sides resolve to the same identifier (no `as`).
export_name_eq :: proc(a, b: ExportSpecifierName) -> bool {
	ai, aok := a.(IdentifierName)
	bi, bok := b.(IdentifierName)
	if aok && bok { return ai.name == bi.name }
	return false
}

gen_export_named_declaration :: proc(cg: ^Codegen, s: ^ExportNamedDeclaration) {
	cg_str(cg, "export ")
	if decl_ptr, ok := s.declaration.?; ok {
		gen_statement(cg, decl_to_stmt(decl_ptr^))
		return
	}
	cg_byte(cg, '{')
	for i in 0..<len(s.specifiers) {
		if i > 0 { cg_str(cg, ", ") } else { cg_space(cg) }
		sp := s.specifiers[i]
		if export_name_eq(sp.local, sp.exported) {
			gen_export_specifier_name(cg, sp.local)
		} else {
			gen_export_specifier_name(cg, sp.local)
			cg_str(cg, " as ")
			gen_export_specifier_name(cg, sp.exported)
		}
	}
	cg_space(cg)
	cg_byte(cg, '}')
	if src, ok := s.source.?; ok {
		cg_str(cg, " from ")
		gen_string_quoted(cg, src.value)
	}
	cg_byte(cg, ';')
}

gen_export_default_declaration :: proc(cg: ^Codegen, s: ^ExportDefaultDeclaration) {
	cg_str(cg, "export default ")
	switch v in s.declaration^ {
	case ^Declaration:
		gen_statement(cg, decl_to_stmt(v^))
	case ^Expression:
		gen_expression(cg, v, PREC_ASSIGN)
		cg_byte(cg, ';')
	}
}

gen_export_all_declaration :: proc(cg: ^Codegen, s: ^ExportAllDeclaration) {
	cg_str(cg, "export * ")
	if name, ok := s.exported.?; ok {
		cg_str(cg, "as ")
		cg_str(cg, name.name)
		cg_byte(cg, ' ')
	}
	cg_str(cg, "from ")
	gen_string_quoted(cg, s.source.value)
	cg_byte(cg, ';')
}

// ============================================================================
// TS declaration stubs — emit a marker so the build links cleanly.
// Real coverage is a follow-up; round-trip tests will skip TS-only files.
// ============================================================================

gen_ts_interface_declaration   :: proc(cg: ^Codegen, s: ^TSInterfaceDeclaration)   { cg_str(cg, "/*interface*/") }
gen_ts_type_alias_declaration  :: proc(cg: ^Codegen, s: ^TSTypeAliasDeclaration)   { cg_str(cg, "/*type-alias*/") }
gen_ts_enum_declaration        :: proc(cg: ^Codegen, s: ^TSEnumDeclaration)        { cg_str(cg, "/*enum*/") }
gen_ts_module_declaration      :: proc(cg: ^Codegen, s: ^TSModuleDeclaration)      { cg_str(cg, "/*module*/") }
gen_ts_import_equals           :: proc(cg: ^Codegen, s: ^TSImportEqualsDeclaration) { cg_str(cg, "/*import-equals*/") }
gen_ts_export_assignment       :: proc(cg: ^Codegen, s: ^TSExportAssignment)       { cg_str(cg, "/*export-assignment*/") }
gen_ts_namespace_export        :: proc(cg: ^Codegen, s: ^TSNamespaceExportDeclaration) { cg_str(cg, "/*namespace-export*/") }
