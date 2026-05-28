package kessel

// ============================================================================
// Codegen — expression-side per-node implementations.
// ============================================================================

import "core:fmt"

// ----------------------------------------------------------------------------
// Literals
// ----------------------------------------------------------------------------

gen_numeric_literal :: proc(cg: ^Codegen, e: ^NumericLiteral) {
	if len(e.raw) > 0 { cg_str(cg, e.raw); return }
	buf: [64]byte
	s := fmt.bprintf(buf[:], "%g", e.value)
	cg_str(cg, s)
}

gen_bigint_literal :: proc(cg: ^Codegen, e: ^BigIntLiteral) {
	if len(e.raw) > 0 { cg_str(cg, e.raw); return }
	cg_str(cg, e.value)
	cg_byte(cg, 'n')
}

gen_regexp_literal :: proc(cg: ^Codegen, e: ^RegExpLiteral) {
	cg_byte(cg, '/')
	cg_str(cg, e.pattern)
	cg_byte(cg, '/')
	cg_str(cg, e.flags)
}

gen_string_literal :: proc(cg: ^Codegen, e: ^StringLiteral) {
	if len(e.raw) > 0 { cg_str(cg, e.raw); return }
	gen_string_quoted(cg, e.value)
}

// Re-quote an arbitrary string as a JS string literal (double-quoted).
gen_string_quoted :: proc(cg: ^Codegen, s: string) {
	cg_byte(cg, '"')
	for i in 0..<len(s) {
		c := s[i]
		switch c {
		case '"':  cg_byte(cg, '\\'); cg_byte(cg, '"')
		case '\\': cg_byte(cg, '\\'); cg_byte(cg, '\\')
		case '\n': cg_byte(cg, '\\'); cg_byte(cg, 'n')
		case '\r': cg_byte(cg, '\\'); cg_byte(cg, 'r')
		case '\t': cg_byte(cg, '\\'); cg_byte(cg, 't')
		case:
			if c < 0x20 {
				tmp: [8]byte
				esc := fmt.bprintf(tmp[:], "\\u%04x", c)
				cg_str(cg, esc)
			} else {
				cg_byte(cg, c)
			}
		}
	}
	cg_byte(cg, '"')
}

gen_template_literal :: proc(cg: ^Codegen, e: ^TemplateLiteral) {
	cg_byte(cg, '`')
	for i in 0..<len(e.quasis) {
		cg_str(cg, e.quasis[i].raw)
		if i < len(e.expressions) {
			cg_str(cg, "${")
			gen_expression(cg, e.expressions[i], PREC_LOWEST)
			cg_byte(cg, '}')
		}
	}
	cg_byte(cg, '`')
}

gen_tagged_template :: proc(cg: ^Codegen, e: ^TaggedTemplateExpression) {
	gen_expression(cg, e.tag, PREC_CALL)
	gen_expression(cg, e.quasi, PREC_CALL)
}

// ----------------------------------------------------------------------------
// Compound expressions
// ----------------------------------------------------------------------------

gen_array_expression :: proc(cg: ^Codegen, e: ^ArrayExpression) {
	cg_byte(cg, '[')
	for i in 0..<len(e.elements) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		if el, ok := e.elements[i].?; ok {
			gen_expression(cg, el, PREC_ASSIGN)
		}
	}
	// Preserve a trailing hole: `[1, ,]` is a 2-element array (1 + hole),
	// but `[1, ]` reparses as `[1]`. Emit the extra comma so the hole
	// survives the round-trip.
	n := len(e.elements)
	if n > 0 {
		if _, ok := e.elements[n-1].?; !ok {
			cg_byte(cg, ',')
		}
	}
	cg_byte(cg, ']')
}

gen_object_expression :: proc(cg: ^Codegen, e: ^ObjectExpression) {
	cg_byte(cg, '{')
	if len(e.properties) == 0 { cg_byte(cg, '}'); return }
	cg_space(cg)
	for i in 0..<len(e.properties) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_property(cg, e.properties[i])
	}
	cg_space(cg)
	cg_byte(cg, '}')
}

gen_property :: proc(cg: ^Codegen, p: Property) {
	if _, ok := p.value.(^SpreadElement); ok {
		gen_expression(cg, p.value, PREC_ASSIGN)
		return
	}
	switch p.kind {
	case .Init:
		if p.shorthand {
			gen_expression(cg, p.value, PREC_ASSIGN)
			return
		}
		if p.computed { cg_byte(cg, '[') }
		gen_expression(cg, p.key, PREC_ASSIGN)
		if p.computed { cg_byte(cg, ']') }
		cg_byte(cg, ':')
		cg_space(cg)
		gen_expression(cg, p.value, PREC_ASSIGN)
	case .Method:
		fn_for_prefix, _ := p.value.(^FunctionExpression)
		if fn_for_prefix != nil {
			if fn_for_prefix.async { cg_str(cg, "async ") }
			if fn_for_prefix.generator { cg_byte(cg, '*') }
		}
		if p.computed { cg_byte(cg, '[') }
		gen_expression(cg, p.key, PREC_ASSIGN)
		if p.computed { cg_byte(cg, ']') }
		if fn_for_prefix != nil {
			gen_function_params_and_body(cg, fn_for_prefix.async, fn_for_prefix.generator, fn_for_prefix.params[:], fn_for_prefix.body, fn_for_prefix.no_body, fn_for_prefix.type_parameters, fn_for_prefix.return_type)
		}
	case .Get:
		cg_str(cg, "get ")
		if p.computed { cg_byte(cg, '[') }
		gen_expression(cg, p.key, PREC_ASSIGN)
		if p.computed { cg_byte(cg, ']') }
		if fn, is_fn := p.value.(^FunctionExpression); is_fn {
			gen_function_params_and_body(cg, false, false, fn.params[:], fn.body, fn.no_body, nil, fn.return_type)
		}
	case .Set:
		cg_str(cg, "set ")
		if p.computed { cg_byte(cg, '[') }
		gen_expression(cg, p.key, PREC_ASSIGN)
		if p.computed { cg_byte(cg, ']') }
		if fn, is_fn := p.value.(^FunctionExpression); is_fn {
			gen_function_params_and_body(cg, false, false, fn.params[:], fn.body, fn.no_body, nil, fn.return_type)
		}
	}
}

gen_function_expression :: proc(cg: ^Codegen, e: ^FunctionExpression) {
	name := ""
	if id, ok := e.id.?; ok { name = id.name }
	gen_function_expression_like(cg, e.async, e.generator, name, e.params[:], e.body, e.no_body, e.type_parameters, e.return_type, false)
}

gen_arrow_function :: proc(cg: ^Codegen, e: ^ArrowFunctionExpression) {
	if e.async { cg_str(cg, "async ") }
	// TS generic arrow: `<T>(x: T) => x`. Without this, the type-parameter
	// list is silently erased, which breaks both round-trip equality and
	// the semantic meaning when a downstream consumer reads typeParameters
	// off the AST and we round-trip via codegen.
	gen_ts_type_parameter_declaration(cg, e.type_parameters)
	cg_byte(cg, '(')
	for i in 0..<len(e.params) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_function_param(cg, e.params[i])
	}
	cg_byte(cg, ')')
	if rt, ok := e.return_type.?; ok {
		cg_str(cg, ": ")
		gen_ts_type(cg, rt.type_annotation)
	}
	cg_space(cg)
	cg_str(cg, "=>")
	cg_space(cg)
	switch body in e.body {
	case ^Expression:
		// `() => {foo: 1}` parses as a block with a labeled statement, not
		// an object literal. Wrap ObjectExpression bodies in parens so the
		// re-parse round-trips to the same Expression.
		if _, is_obj := body^.(^ObjectExpression); is_obj {
			cg_byte(cg, '(')
			gen_expression(cg, body, PREC_ASSIGN)
			cg_byte(cg, ')')
		} else {
			gen_expression(cg, body, PREC_ASSIGN)
		}
	case ^BlockStatement: gen_block_statement(cg, body)
	}
}

gen_class_expression :: proc(cg: ^Codegen, e: ^ClassExpression) {
	// Class expressions can carry decorators in the legacy decorators
	// proposal (`var x = @dec class Foo {}`). Emit them in source order
	// before the `class` keyword; omitting them drops information that
	// breaks AST round-trip.
	for d in e.decorators {
		gen_decorator(cg, d)
		cg_hard_space(cg)
	}
	name := ""
	if id, ok := e.id.?; ok { name = id.name }
	gen_class_like(cg, name, e.super_class, e.body, e.type_parameters, e.super_type_arguments, e.implements)
}

gen_member_expression :: proc(cg: ^Codegen, e: ^MemberExpression) {
	gen_expression(cg, e.object, PREC_CALL)
	if e.computed {
		if e.optional { cg_str(cg, "?.") }
		cg_byte(cg, '[')
		gen_expression(cg, e.property, PREC_LOWEST)
		cg_byte(cg, ']')
	} else {
		cg_byte(cg, e.optional ? '?' : '.')
		if e.optional { cg_byte(cg, '.') }
		gen_expression_raw(cg, e.property)
	}
}

gen_call_expression :: proc(cg: ^Codegen, e: ^CallExpression) {
	gen_expression(cg, e.callee, PREC_CALL)
	if e.optional { cg_str(cg, "?.") }
	gen_ts_type_arguments(cg, e.type_parameters)
	cg_byte(cg, '(')
	for i in 0..<len(e.arguments) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_expression(cg, e.arguments[i], PREC_ASSIGN)
	}
	cg_byte(cg, ')')
}

gen_new_expression :: proc(cg: ^Codegen, e: ^NewExpression) {
	cg_str(cg, "new ")
	// The `new` callee grammar is MemberExpression | NewExpression — a
	// CallExpression callee needs explicit parens, otherwise
	// `new f()()` parses as `(new f)()` (call on the new), not the
	// intended `new (f())()`.
	if _, is_call := e.callee^.(^CallExpression); is_call {
		cg_byte(cg, '(')
		gen_expression(cg, e.callee, PREC_LOWEST)
		cg_byte(cg, ')')
	} else {
		gen_expression(cg, e.callee, PREC_CALL)
	}
	gen_ts_type_arguments(cg, e.type_parameters)
	cg_byte(cg, '(')
	for i in 0..<len(e.arguments) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_expression(cg, e.arguments[i], PREC_ASSIGN)
	}
	cg_byte(cg, ')')
}

gen_conditional_expression :: proc(cg: ^Codegen, e: ^ConditionalExpression) {
	gen_expression(cg, e.test, PREC_COND + 1)
	cg_space(cg)
	cg_byte(cg, '?')
	cg_space(cg)
	gen_expression(cg, e.consequent, PREC_ASSIGN)
	cg_space(cg)
	cg_byte(cg, ':')
	cg_space(cg)
	gen_expression(cg, e.alternate, PREC_ASSIGN)
}

gen_update_expression :: proc(cg: ^Codegen, e: ^UpdateExpression) {
	op := ""
	switch e.operator {
	case .Increment: op = "++"
	case .Decrement: op = "--"
	}
	if e.prefix {
		cg_str(cg, op)
		gen_expression(cg, e.argument, PREC_UPDATE)
	} else {
		gen_expression(cg, e.argument, PREC_UPDATE)
		cg_str(cg, op)
	}
}

gen_unary_expression :: proc(cg: ^Codegen, e: ^UnaryExpression) {
	op := ""
	word := false
	switch e.operator {
	case .Minus:      op = "-"
	case .Plus:       op = "+"
	case .LogicalNot: op = "!"
	case .BitwiseNot: op = "~"
	case .Typeof:     op = "typeof"; word = true
	case .Void:       op = "void";   word = true
	case .Delete:     op = "delete"; word = true
	}
	cg_str(cg, op)
	if word { cg_hard_space(cg) }
	gen_expression(cg, e.argument, PREC_UNARY)
}

gen_binary_expression :: proc(cg: ^Codegen, e: ^BinaryExpression) {
	op, prec := binop_text(e.operator)
	// Spec: ExponentiationExpression's left operand is restricted to
	// UpdateExpression — a UnaryExpression / AwaitExpression on the
	// left of `**` is a syntax error unless parenthesized. Normal
	// precedence comparison would let `await x ** y` through because
	// PREC_UNARY > PREC_EXP, but the parse re-rejects it. Force parens
	// on the left when the operator is `**` and the left is a prefix
	// form that cannot legally appear there bare.
	if op == "**" && left_needs_paren_for_exp(e.left) {
		cg_byte(cg, '(')
		gen_expression(cg, e.left, PREC_LOWEST)
		cg_byte(cg, ')')
	} else {
		gen_expression(cg, e.left, prec)
	}
	// Word operators (`in`, `instanceof`) MUST be separated from the
	// surrounding identifiers / private names. Symbolic operators (`+`,
	// `**`, `<<`, etc.) can elide the spaces in minified mode because
	// the lexer will retokenise correctly without them.
	word_op := op == "in" || op == "instanceof"
	if word_op { cg_hard_space(cg) } else { cg_space(cg) }
	cg_str(cg, op)
	if word_op { cg_hard_space(cg) } else { cg_space(cg) }
	// Right-assoc only for **; everything else is left-assoc, so bump on right.
	right_prec := prec + 1
	if op == "**" { right_prec = prec }
	gen_expression(cg, e.right, right_prec)
}

// left_needs_paren_for_exp — true when `expr` cannot legally appear as
// the bare left operand of `**`. The exponentiation production accepts
// only UpdateExpression on the left; UnaryExpression (including `-x`,
// `!x`, `void x`, etc.) and AwaitExpression must be parenthesized.
left_needs_paren_for_exp :: proc(expr: ^Expression) -> bool {
	if expr == nil { return false }
	#partial switch _ in expr^ {
	case ^UnaryExpression:   return true
	case ^AwaitExpression:   return true
	}
	return false
}

binop_text :: proc(op: BinaryOperator) -> (string, int) {
	switch op {
	case .Add:                 return "+",          PREC_ADD
	case .Sub:                 return "-",          PREC_ADD
	case .Mul:                 return "*",          PREC_MUL
	case .Div:                 return "/",          PREC_MUL
	case .Mod:                 return "%",          PREC_MUL
	case .Pow:                 return "**",         PREC_EXP
	case .BitOr:               return "|",          PREC_BOR
	case .BitXor:              return "^",          PREC_BXOR
	case .BitAnd:              return "&",          PREC_BAND
	case .ShiftLeft:           return "<<",         PREC_SHIFT
	case .ShiftRight:          return ">>",         PREC_SHIFT
	case .ShiftRightUnsigned:  return ">>>",        PREC_SHIFT
	case .Eq:                  return "==",         PREC_EQ
	case .NotEq:               return "!=",         PREC_EQ
	case .StrictEq:            return "===",        PREC_EQ
	case .StrictNotEq:         return "!==",        PREC_EQ
	case .Lt:                  return "<",          PREC_REL
	case .LtEq:                return "<=",         PREC_REL
	case .Gt:                  return ">",          PREC_REL
	case .GtEq:                return ">=",         PREC_REL
	case .Instanceof:          return "instanceof", PREC_REL
	case .In:                  return "in",         PREC_REL
	}
	return "+", PREC_ADD
}

gen_logical_expression :: proc(cg: ^Codegen, e: ^LogicalExpression) {
	op := ""
	prec := PREC_LOR
	switch e.operator {
	case .Or:                 op = "||"; prec = PREC_LOR
	case .And:                op = "&&"; prec = PREC_LAND
	case .NullishCoalescing:  op = "??"; prec = PREC_NULLISH
	}
	gen_expression(cg, e.left, prec)
	cg_space(cg)
	cg_str(cg, op)
	cg_space(cg)
	gen_expression(cg, e.right, prec + 1)
}

gen_assignment_expression :: proc(cg: ^Codegen, e: ^AssignmentExpression) {
	gen_expression(cg, e.left, PREC_CALL)
	cg_space(cg)
	cg_str(cg, assign_op_text(e.operator))
	cg_space(cg)
	gen_expression(cg, e.right, PREC_ASSIGN)
}

assign_op_text :: proc(op: AssignmentOperator) -> string {
	switch op {
	case .Assign:            return "="
	case .AddAssign:         return "+="
	case .SubAssign:         return "-="
	case .MulAssign:         return "*="
	case .DivAssign:         return "/="
	case .ModAssign:         return "%="
	case .PowAssign:         return "**="
	case .ShiftLeftAssign:   return "<<="
	case .ShiftRightAssign:  return ">>="
	case .ShiftRightUAssign: return ">>>="
	case .BitOrAssign:       return "|="
	case .BitXorAssign:      return "^="
	case .BitAndAssign:      return "&="
	case .AssignLogicalAnd:  return "&&="
	case .AssignLogicalOr:   return "||="
	case .AssignNullish:     return "??="
	}
	return "="
}

gen_sequence_expression :: proc(cg: ^Codegen, e: ^SequenceExpression) {
	for i in 0..<len(e.expressions) {
		if i > 0 { cg_byte(cg, ','); cg_space(cg) }
		gen_expression(cg, e.expressions[i], PREC_ASSIGN)
	}
}

gen_yield_expression :: proc(cg: ^Codegen, e: ^YieldExpression) {
	cg_str(cg, "yield")
	if e.delegate { cg_byte(cg, '*') }
	if arg, ok := e.argument.?; ok {
		cg_hard_space(cg)
		gen_expression(cg, arg, PREC_ASSIGN)
	}
}

gen_import_expression :: proc(cg: ^Codegen, e: ^ImportExpression) {
	cg_str(cg, "import")
	if len(e.phase) > 0 { cg_byte(cg, '.'); cg_str(cg, e.phase) }
	cg_byte(cg, '(')
	gen_expression(cg, e.source, PREC_ASSIGN)
	if e.options != nil {
		cg_byte(cg, ',')
		cg_space(cg)
		gen_expression(cg, e.options, PREC_ASSIGN)
	}
	cg_byte(cg, ')')
}

gen_meta_property :: proc(cg: ^Codegen, e: ^MetaProperty) {
	cg_str(cg, e.meta.name)
	cg_byte(cg, '.')
	cg_str(cg, e.property.name)
}

// ----------------------------------------------------------------------------
// JSX
// ----------------------------------------------------------------------------

gen_jsx_element :: proc(cg: ^Codegen, e: ^JSXElement) {
	cg_byte(cg, '<')
	gen_jsx_name(cg, e.opening_element.name)
	// TS-in-JSX generic type arguments: `<Foo<T> />`. The opening element
	// carries them; without this emission, the type args are dropped and
	// the round-trip diff shows `openingElement.typeArguments` only on
	// the original AST.
	gen_ts_type_arguments(cg, e.opening_element.type_arguments)
	for a in e.opening_element.attributes {
		cg_byte(cg, ' ')
		gen_jsx_attr(cg, a)
	}
	if e.opening_element.self_closing {
		cg_str(cg, " />")
		return
	}
	cg_byte(cg, '>')
	for c in e.children {
		gen_jsx_child(cg, c)
	}
	cg_str(cg, "</")
	if cl, ok := e.closing_element.?; ok {
		gen_jsx_name(cg, cl.name)
	}
	cg_byte(cg, '>')
}

gen_jsx_fragment :: proc(cg: ^Codegen, e: ^JSXFragment) {
	cg_str(cg, "<>")
	for c in e.children {
		gen_jsx_child(cg, c)
	}
	cg_str(cg, "</>")
}

gen_jsx_expression_container :: proc(cg: ^Codegen, e: ^JSXExpressionContainer) {
	cg_byte(cg, '{')
	gen_expression(cg, e.expression, PREC_ASSIGN)
	cg_byte(cg, '}')
}

gen_jsx_name :: proc(cg: ^Codegen, name: JSXElementName) {
	switch n in name {
	case JSXIdentifier:        cg_str(cg, n.name)
	case ^JSXMemberExpression: gen_jsx_member(cg, n)
	case ^JSXNamespacedName:
		cg_str(cg, n.namespace.name)
		cg_byte(cg, ':')
		cg_str(cg, n.name.name)
	}
}

gen_jsx_member :: proc(cg: ^Codegen, m: ^JSXMemberExpression) {
	switch o in m.object {
	case JSXIdentifier:        cg_str(cg, o.name)
	case ^JSXMemberExpression: gen_jsx_member(cg, o)
	}
	cg_byte(cg, '.')
	cg_str(cg, m.property.name)
}

gen_jsx_attr :: proc(cg: ^Codegen, a: JSXAttributeItem) {
	switch v in a {
	case JSXAttribute:
		gen_jsx_attr_name(cg, v.name)
		if val, ok := v.value.?; ok {
			cg_byte(cg, '=')
			gen_expression(cg, val, PREC_ASSIGN)
		}
	case ^JSXSpreadAttribute:
		cg_str(cg, "{...")
		gen_expression(cg, v.argument, PREC_ASSIGN)
		cg_byte(cg, '}')
	}
}

gen_jsx_attr_name :: proc(cg: ^Codegen, n: JSXAttributeName) {
	switch v in n {
	case JSXIdentifier:        cg_str(cg, v.name)
	case ^JSXNamespacedName:
		cg_str(cg, v.namespace.name)
		cg_byte(cg, ':')
		cg_str(cg, v.name.name)
	}
}

gen_jsx_child :: proc(cg: ^Codegen, c: JSXChild) {
	switch v in c {
	case ^JSXElement:              gen_jsx_element(cg, v)
	case ^JSXFragment:             gen_jsx_fragment(cg, v)
	case ^JSXText:                 cg_str(cg, v.value)
	case ^JSXExpressionContainer:  gen_jsx_expression_container(cg, v)
	case ^JSXSpreadChild:          cg_byte(cg, '{'); cg_str(cg, "..."); gen_expression(cg, v.expression, PREC_ASSIGN); cg_byte(cg, '}')
	}
}

// ----------------------------------------------------------------------------
// TS expressions
// ----------------------------------------------------------------------------

gen_ts_as_expression        :: proc(cg: ^Codegen, e: ^TSAsExpression)        { gen_expression(cg, e.expression, PREC_UNARY); cg_str(cg, " as "); gen_ts_type(cg, e.type_annotation) }
gen_ts_satisfies_expression :: proc(cg: ^Codegen, e: ^TSSatisfiesExpression) { gen_expression(cg, e.expression, PREC_UNARY); cg_str(cg, " satisfies "); gen_ts_type(cg, e.type_annotation) }
gen_ts_type_assertion       :: proc(cg: ^Codegen, e: ^TSTypeAssertion)       { cg_byte(cg, '<'); gen_ts_type(cg, e.type_annotation); cg_byte(cg, '>'); gen_expression(cg, e.expression, PREC_UNARY) }
gen_ts_instantiation        :: proc(cg: ^Codegen, e: ^TSInstantiationExpression) { gen_ts_instantiation_full(cg, e) }
