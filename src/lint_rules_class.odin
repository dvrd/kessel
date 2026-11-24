package kessel

// Rules about classes, accessors, generators and jump statements.

LintSeenMember :: struct { loc: Loc, static, private, accessor: bool, kind: ClassElementKind }

// no-dupe-class-members: one table per class keyed by name alone. A member is
// compared with the latest earlier member of that name, as the reference does.
lint_check_dupe_class_members :: proc(l: ^Linter, cls: ^ClassExpression) {
	if cls == nil || !lint_rule_enabled(l, .L2004_NoDupeClassMembers) { return }
	seen := make(map[string]LintSeenMember, len(cls.body.body), context.temp_allocator)
	for elem in cls.body.body {
		if elem.key == nil { continue }
		#partial switch elem.kind {
		case .Constructor, .StaticBlock, .IndexSignature: continue
		}
		name: string
		private := false
		if id, is_private := elem.key^.(^PrivateIdentifier); is_private {
			name, private = id.name, true
		} else {
			static_name, known := lint_property_static_name(elem.key, elem.computed)
			if !known { continue }
			name = static_name
		}
		if elem.kind != .Field {
			// Overload signatures declare no member of their own.
			value, has_value := elem.value.?
			if has_value && value != nil {
				if fn, is_fn := value^.(^FunctionExpression); is_fn && fn.no_body { continue }
			}
		}
		accessor := elem.kind == .Get || elem.kind == .Set
		current := LintSeenMember{lint_key_loc(l, elem.key), elem.static, private, accessor, elem.kind}
		previous, repeated := seen[name]
		seen[name] = current
		if !repeated || previous.static != current.static || previous.private != current.private { continue }
		if previous.accessor && current.accessor && previous.kind != current.kind { continue }
		lint_emit(l, previous.loc, .L2004_NoDupeClassMembers)
	}
}

// Setter functions are remembered by address so a `return value` statement
// can tell whether the function around it is one.
lint_mark_setter :: proc(l: ^Linter, value: ^Expression) {
	if value == nil || !lint_rule_enabled(l, .L2030_NoSetterReturn) { return }
	fn, is_fn := value^.(^FunctionExpression)
	if !is_fn || fn == nil { return }
	if l.setters == nil { l.setters = make(map[rawptr]bool, 8, l.allocator) }
	l.setters[fn] = true
}

// The tree stores a static block as a function. Rules that treat function
// bodies specially (directive prologues) need to tell the two apart.
lint_mark_static_block :: proc(l: ^Linter, elem: ClassElement) {
	if elem.kind != .StaticBlock { return }
	value, has_value := elem.value.?
	if !has_value || value == nil { return }
	block, is_block := value^.(^FunctionExpression)
	if !is_block || block == nil { return }
	if l.static_blocks == nil { l.static_blocks = make(map[rawptr]bool, 4, l.allocator) }
	l.static_blocks[block] = true
}

lint_check_no_setter_return :: proc(l: ^Linter, elem: ClassElement) {
	if elem.kind != .Set { return }
	if value, ok := elem.value.?; ok { lint_mark_setter(l, value) }
}

// no-setter-return: the nearest enclosing function decides. The search goes on
// past a setter, so a setter nested in a setter reports twice like the reference.
lint_check_setter_return :: proc(l: ^Linter, v: ^ReturnStatement) {
	if len(l.setters) == 0 || v.argument == nil { return }
	for index := len(l.ancestors) - 2; index >= 0; index -= 1 {
		switch node in l.ancestors[index] {
		case ^Statement:
			if _, declaration := node^.(^FunctionDeclaration); declaration { return }
		case ^Expression:
			#partial switch fn in node^ {
			case ^ArrowFunctionExpression: return
			case ^FunctionExpression:
				if !l.setters[fn] { return }
				lint_emit(l, v.loc, .L2030_NoSetterReturn)
			}
		case ^BlockStatement:
		}
	}
}

// require-yield: an empty generator is allowed. The range is the name when
// the function has one. The walk counts the yields it met inside the body.
lint_check_require_yield :: proc(l: ^Linter, fn: ^FunctionExpression, has_yield: bool) {
	if has_yield || !fn.generator || fn.no_body || len(fn.body.body) == 0 { return }
	if !lint_rule_enabled(l, .L2033_RequireYield) { return }
	loc := fn.loc
	if id, named := fn.id.?; named { loc = id.loc }
	lint_emit(l, loc, .L2033_RequireYield)
}

// no-prototype-builtins reports the member expression that names the method.
lint_check_prototype_builtins :: proc(l: ^Linter, e: ^CallExpression) {
	if e == nil || !lint_rule_enabled(l, .L2024_NoPrototypeBuiltins) { return }
	member := lint_member_of(e.callee)
	if member == nil { return }
	name, static := lint_static_property_name(member)
	if !static { return }
	switch name {
	case "hasOwnProperty", "isPrototypeOf", "propertyIsEnumerable":
		lint_emit(l, member.loc, .L2024_NoPrototypeBuiltins)
	}
}

// ---------------------------------------------------------------------------
// no-unsafe-finally
// ---------------------------------------------------------------------------

LintJumpKind :: enum { Break, Continue, Return_Throw }

lint_is_loop :: proc(stmt: ^Statement) -> bool {
	#partial switch _ in stmt^ {
	case ^WhileStatement, ^DoWhileStatement, ^ForStatement, ^ForInStatement, ^ForOfStatement: return true
	}
	return false
}

// True for the node that ends the search: the jump cannot leave it.
lint_jump_boundary :: proc(node: LintNode, kind: LintJumpKind) -> bool {
	switch inner in node {
	case ^Expression:
		#partial switch _ in inner^ {
		case ^FunctionExpression, ^ArrowFunctionExpression, ^ClassExpression: return true
		}
	case ^Statement:
		#partial switch _ in inner^ {
		case ^FunctionDeclaration, ^ClassDeclaration: return true
		case ^SwitchStatement: return kind == .Break
		}
		if lint_is_loop(inner) { return kind != .Return_Throw }
	case ^BlockStatement:
	}
	return false
}

// A jump out of a `finally` block discards the completion of its `try`. A
// labelled jump is safe when its label is itself inside the block.
lint_check_unsafe_finally :: proc(l: ^Linter, stmt: ^Statement) {
	if !lint_rule_enabled(l, .L4024_NoUnsafeFinally) { return }
	kind := LintJumpKind.Return_Throw
	label := ""
	#partial switch node in stmt^ {
	case ^BreakStatement:
		if target, labelled := node.label.?; labelled { label = target.name } else { kind = .Break }
	case ^ContinueStatement:
		kind = .Continue
		if target, labelled := node.label.?; labelled { label = target.name }
	case ^ReturnStatement, ^ThrowStatement:
	case: return
	}
	label_inside := false
	for index := len(l.ancestors) - 2; index >= 0; index -= 1 {
		node := l.ancestors[index]
		if lint_jump_boundary(node, kind) { return }
		if index > 0 && label != "" {
			if parent, is_stmt := l.ancestors[index - 1].(^Statement); is_stmt {
				labeled, is_labeled := parent^.(^LabeledStatement)
				if is_labeled && labeled.label.name == label { label_inside = true }
			}
		}
		if _, finalizer := node.(^BlockStatement); finalizer {
			if label != "" && label_inside { return }
			lint_emit(l, get_statement_loc(stmt), .L4024_NoUnsafeFinally)
			return
		}
	}
}

// ---------------------------------------------------------------------------
// no-unsafe-optional-chaining
// ---------------------------------------------------------------------------

// Reports every optional chain whose `undefined` result would reach a use
// that throws on undefined.
lint_optional_short_circuit :: proc(l: ^Linter, expr: ^Expression) {
	inner := lint_inner(expr)
	// `a && b && c` nests on the left without limit: follow that spine in a
	// loop. Only `&&` passes its left value through.
	for inner != nil {
		logical, is_logical := inner^.(^LogicalExpression)
		if !is_logical { break }
		lint_optional_short_circuit(l, logical.right)
		if logical.operator != .And { return }
		inner = lint_inner(logical.left)
	}
	if inner == nil { return }
	#partial switch node in inner^ {
	case ^AwaitExpression:
		lint_optional_short_circuit(l, node.argument)
	case ^ConditionalExpression:
		lint_optional_short_circuit(l, node.consequent)
		lint_optional_short_circuit(l, node.alternate)
	case ^SequenceExpression:
		if len(node.expressions) > 0 { lint_optional_short_circuit(l, node.expressions[len(node.expressions) - 1]) }
	case ^ChainExpression:
		lint_emit(l, node.loc, .L2035_NoUnsafeOptionalChaining)
	}
}

lint_optional_arithmetic :: proc(l: ^Linter, expr: ^Expression) {
	if l.options.optional_chain_arithmetic { lint_optional_short_circuit(l, expr) }
}

lint_is_destructuring :: proc(expr: ^Expression) -> bool {
	inner := lint_unparen(expr)
	if inner == nil { return false }
	#partial switch _ in inner^ {
	case ^ArrayExpression, ^ObjectExpression: return true
	}
	return false
}

lint_pattern_is_destructuring :: proc(pattern: Pattern) -> bool {
	#partial switch _ in pattern {
	case ^ArrayPattern, ^ObjectPattern: return true
	}
	return false
}

lint_check_optional_chain_expr :: proc(l: ^Linter, expr: ^Expression) {
	if !lint_rule_enabled(l, .L2035_NoUnsafeOptionalChaining) { return }
	#partial switch node in expr^ {
	case ^CallExpression:
		if !node.optional { lint_optional_short_circuit(l, node.callee) }
	case ^MemberExpression:
		if !node.optional { lint_optional_short_circuit(l, node.object) }
	case ^TaggedTemplateExpression:
		lint_optional_short_circuit(l, node.tag)
	case ^NewExpression:
		lint_optional_short_circuit(l, node.callee)
	case ^AssignmentExpression:
		if lint_is_destructuring(node.left) { lint_optional_short_circuit(l, node.right) }
		#partial switch node.operator {
		case .AddAssign, .SubAssign, .MulAssign, .DivAssign, .ModAssign, .PowAssign:
			lint_optional_arithmetic(l, node.right)
		}
	case ^BinaryExpression:
		#partial switch node.operator {
		case .In, .Instanceof:
			lint_optional_short_circuit(l, node.right)
		case .Add, .Sub, .Mul, .Div, .Mod, .Pow:
			lint_optional_arithmetic(l, node.left)
			lint_optional_arithmetic(l, node.right)
		}
	case ^UnaryExpression:
		if node.operator == .Minus || node.operator == .Plus { lint_optional_arithmetic(l, node.argument) }
	case ^ClassExpression:
		if super, ok := node.super_class.?; ok { lint_optional_short_circuit(l, super) }
	case ^ArrayExpression:
		for element in node.elements {
			item, present := element.?
			if !present || item == nil { continue }
			if spread, ok := item^.(^SpreadElement); ok { lint_optional_short_circuit(l, spread.argument) }
		}
	}
}

lint_check_optional_chain_default :: proc(l: ^Linter, pattern: ^AssignmentPattern) {
	if !lint_rule_enabled(l, .L2035_NoUnsafeOptionalChaining) { return }
	if lint_pattern_is_destructuring(pattern.left) { lint_optional_short_circuit(l, pattern.right) }
}

lint_check_optional_chain_stmt :: proc(l: ^Linter, stmt: ^Statement) {
	if !lint_rule_enabled(l, .L2035_NoUnsafeOptionalChaining) { return }
	#partial switch node in stmt^ {
	case ^ForOfStatement:   lint_optional_short_circuit(l, node.right)
	case ^WithStatement:    lint_optional_short_circuit(l, node.object)
	case ^ClassDeclaration:
		if super, ok := node.super_class.?; ok { lint_optional_short_circuit(l, super) }
	case ^VariableDeclaration:
		for decl in node.declarations {
			init, has_init := decl.init.?
			if has_init && lint_pattern_is_destructuring(decl.id) { lint_optional_short_circuit(l, init) }
		}
	}
}

// ---------------------------------------------------------------------------
// no-useless-rename
// ---------------------------------------------------------------------------

lint_pattern_key_name :: proc(key: ObjectPatternPropertyKey) -> (string, bool) {
	switch node in key {
	case IdentifierName:  return node.name, true
	case ^StringLiteral:  return node.value, true
	case ^NumericLiteral: return lint_number_name(lint_numeric_value(node)), true
	case ^Expression:     return lint_property_static_name(node, true)
	}
	return "", false
}

// `{a: a}` in a declaration or parameter.
lint_check_rename_pattern :: proc(l: ^Linter, pattern: ^ObjectPattern) {
	if l.options.rename_ignore_destructuring || !lint_rule_enabled(l, .L4027_NoUselessRename) { return }
	for prop in pattern.properties {
		key, has_key := prop.key.?
		if !has_key || prop.shorthand || prop.computed { continue }
		name, static := lint_pattern_key_name(key)
		if !static { continue }
		target: ^Identifier
		#partial switch value in prop.value {
		case ^Identifier: target = value
		case ^AssignmentPattern:
			if value != nil { target, _ = value.left.(^Identifier) }
		}
		if target != nil && target.name == name { lint_emit(l, prop.loc, .L4027_NoUselessRename) }
	}
}

// `({a: a} = b)`: the object literal on the left is an assignment target.
lint_check_rename_target :: proc(l: ^Linter, expr: ^Expression) {
	target := lint_unparen(expr)
	if target == nil { return }
	#partial switch node in target^ {
	case ^ArrayExpression:
		for element in node.elements {
			if item, present := element.?; present { lint_check_rename_target(l, item) }
		}
	case ^SpreadElement:
		lint_check_rename_target(l, node.argument)
	case ^ObjectExpression:
		for prop in node.properties {
			if prop.value == nil { continue }
			lint_check_rename_target(l, prop.value)
			if prop.key == nil || prop.shorthand || l.options.rename_ignore_destructuring { continue }
			name, static := lint_property_static_name(prop.key, prop.computed)
			if !static { continue }
			binding := lint_unparen(prop.value)
			if assignment, has_default := binding^.(^AssignmentExpression); has_default {
				binding = lint_unparen(assignment.left)
			}
			id := lint_identifier(binding)
			if id != nil && id.name == name { lint_emit(l, prop.loc, .L4027_NoUselessRename) }
		}
	}
}

lint_export_name :: proc(name: ExportSpecifierName) -> (string, Loc) {
	switch node in name {
	case IdentifierName: return node.name, node.loc
	case ^StringLiteral: return node.value, node.loc
	}
	return "", {}
}

lint_check_rename_module :: proc(l: ^Linter, stmt: ^Statement) {
	if !lint_rule_enabled(l, .L4027_NoUselessRename) { return }
	#partial switch node in stmt^ {
	case ^ImportDeclaration:
		if l.options.rename_ignore_import { return }
		for item in node.specifiers {
			if item == nil { continue }
			spec, named := item^.(ImportSpecifier)
			if !named || spec.imported.loc == spec.local.loc { continue }
			if spec.imported.name == spec.local.name { lint_emit(l, spec.local.loc, .L4027_NoUselessRename) }
		}
	case ^ExportNamedDeclaration:
		if l.options.rename_ignore_export { return }
		for spec in node.specifiers {
			local, local_loc := lint_export_name(spec.local)
			exported, exported_loc := lint_export_name(spec.exported)
			if local_loc != exported_loc && local == exported { lint_emit(l, local_loc, .L4027_NoUselessRename) }
		}
	}
}
