package kessel

// Per-module scan of the link AST: import/export tables, dependency records
// for require() and import(), and the expression slots the emitter rewrites.
// The link AST is plain JavaScript, so TypeScript and JSX nodes never occur.

BundleScan :: struct {
	g:         ^BundleGraph,
	module:    ^BundleModule,
	statement: i32,
	depth:     int,
	// Zero while outside every function; arrows count for `await` only,
	// because an arrow keeps the enclosing `this`.
	function_depth: int,
	this_depth:     int,
	try_depth:      int, // inside a try block, where a failing require() is caught
	too_deep:       bool,
}

bundle_scan_module :: proc(g: ^BundleGraph, module: ^BundleModule) {
	assert(module.job != nil)
	assert(module.job.program != nil)
	model := &module.model
	for ref in model.refs {
		if ref.resolved != SYMBOL_UNRESOLVED { continue }
		switch ref.name {
		case "require": module.free_cjs[ref.start] = true
		case "module", "exports": module.uses_commonjs_objects = true
		}
	}
	scan := BundleScan{g = g, module = module}
	body := module.job.program.body[:]
	for statement, index in body {
		scan.statement = i32(index)
		bundle_scan_top_level(&scan, statement)
		bundle_walk_statement(&scan, statement)
	}
	if scan.too_deep {
		bundle_error(g, module, nil, "expression nesting exceeds %d levels", BUNDLE_AST_DEPTH_MAX)
	}
	if module.kind == .ESM { bundle_scan_parts(module, body) }
}

@(private="file")
bundle_scan_record :: proc(
	scan: ^BundleScan,
	kind: BundleRecordKind,
	specifier: string,
	loc: Loc,
	node: ^Expression,
) -> i32 {
	append(&scan.module.records, BundleRecord{
		kind = kind, specifier = specifier, loc = loc, statement = scan.statement,
		target = BUNDLE_UNRESOLVED, node = node,
		optional = kind == .Require && scan.try_depth > 0,
	})
	return i32(len(scan.module.records) - 1)
}

@(private="file")
bundle_scan_export :: proc(scan: ^BundleScan, exported: string, value: BundleExport) {
	module := scan.module
	if _, duplicate := module.exports[exported]; duplicate {
		bundle_error(scan.g, module, value.loc.start, "duplicate export '%s'", exported)
		return
	}
	module.exports[exported] = value
	append(&module.export_order, exported)
}

@(private="file")
bundle_export_specifier_name :: proc(name: ExportSpecifierName) -> string {
	switch value in name {
	case IdentifierName: return value.name
	case ^StringLiteral: return value.value
	}
	return ""
}

@(private="file")
bundle_scan_top_level :: proc(scan: ^BundleScan, statement: ^Statement) {
	module := scan.module
	#partial switch node in statement^ {
	case ^ImportDeclaration:
		if node.phase != "" {
			bundle_error(scan.g, module, node.loc.start,
				"'import %s' is not supported by the bundler", node.phase)
		}
		record := bundle_scan_record(scan, .Import, node.source.value, node.loc, nil)
		for item in node.specifiers {
			switch specifier in item^ {
			case ImportDefaultSpecifier:
				module.imports[specifier.local.name] = {record, "default"}
			case ImportNamespaceSpecifier: module.imports[specifier.local.name] = {record, "*"}
			case ImportSpecifier:
				module.imports[specifier.local.name] = {record, specifier.imported.name}
			}
		}
	case ^ExportAllDeclaration:
		record := bundle_scan_record(scan, .Import, node.source.value, node.loc, nil)
		if alias, named := node.exported.?; named {
			bundle_scan_export(scan, alias.name, {record, "*", node.loc})
		} else {
			append(&module.stars, record)
		}
	case ^ExportNamedDeclaration:
		bundle_scan_named_export(scan, node)
	case ^ExportDefaultDeclaration:
		if node.declaration == nil || node.declaration^ == nil {
			// The printer needs a value to bind; refuse rather than guess.
			bundle_error(scan.g, module, node.loc.start,
				"this default export has no value the bundler can bind")
			return
		}
		local := BUNDLE_DEFAULT_LOCAL
		if declaration, ok := node.declaration^.(^Declaration); ok {
			#partial switch inner in declaration^ {
			case ^FunctionDeclaration:
				if id, named := inner.id.?; named { local = id.name }
			case ^ClassDeclaration:
				if id, named := inner.id.?; named { local = id.name }
			}
		}
		bundle_scan_export(scan, "default", {-1, local, node.loc})
	}
}

@(private="file")
bundle_scan_named_export :: proc(scan: ^BundleScan, node: ^ExportNamedDeclaration) {
	if source, has_source := node.source.?; has_source {
		record := bundle_scan_record(scan, .Import, source.value, node.loc, nil)
		for &specifier in node.specifiers {
			exported := bundle_export_specifier_name(specifier.exported)
			bundle_scan_export(scan, exported,
				{record, bundle_export_specifier_name(specifier.local), specifier.loc})
		}
		return
	}
	for &specifier in node.specifiers {
		exported := bundle_export_specifier_name(specifier.exported)
		bundle_scan_export(scan, exported,
			{-1, bundle_export_specifier_name(specifier.local), specifier.loc})
	}
	declaration, has_declaration := node.declaration.?
	if !has_declaration { return }
	#partial switch inner in declaration^ {
	case ^FunctionDeclaration:
		if id, named := inner.id.?; named {
			bundle_scan_export(scan, id.name, {-1, id.name, id.loc})
		}
	case ^ClassDeclaration:
		if id, named := inner.id.?; named {
			bundle_scan_export(scan, id.name, {-1, id.name, id.loc})
		}
	case ^VariableDeclaration:
		names := make([dynamic]^Identifier, scan.g.alloc)
		for declarator in inner.declarations {
			bundle_pattern_identifiers(declarator.id, &names, 0)
		}
		for id in names { bundle_scan_export(scan, id.name, {-1, id.name, id.loc}) }
	}
}

// Binding identifiers of a declaration pattern. Patterns nest only as deep as
// the parser allowed, and the depth guard keeps this walk bounded regardless.
bundle_pattern_identifiers :: proc(pattern: Pattern, out: ^[dynamic]^Identifier, depth: int) {
	if depth > BUNDLE_AST_DEPTH_MAX { return }
	switch node in pattern {
	case ^Identifier:        if node != nil { append(out, node) }
	case ^AssignmentPattern:
		if node != nil { bundle_pattern_identifiers(node.left, out, depth + 1) }
	case ^RestElement:
		if node != nil { bundle_pattern_identifiers(node.argument, out, depth + 1) }
	case ^ObjectPattern:
		if node != nil {
			for property in node.properties {
				bundle_pattern_identifiers(property.value, out, depth + 1)
			}
		}
	case ^ArrayPattern:
		if node != nil {
			for element in node.elements {
				if inner, present := element.(Pattern); present {
					bundle_pattern_identifiers(inner, out, depth + 1)
				}
			}
		}
	case ^MemberExpression:
	}
}

// ----------------------------------------------------------------------------
// AST walk. Recursion follows the tree the parser built; `depth` turns a
// pathological input into a diagnostic instead of a stack overflow.
// ----------------------------------------------------------------------------

@(private="file")
bundle_walk_statements :: proc(scan: ^BundleScan, statements: []^Statement) {
	for statement in statements { bundle_walk_statement(scan, statement) }
}

@(private="file")
bundle_walk_declaration :: proc(scan: ^BundleScan, declaration: ^VariableDeclaration) {
	if declaration == nil { return }
	if declaration.kind == .AwaitUsing && scan.function_depth == 0 {
		scan.module.has_top_level_await = true
	}
	for declarator in declaration.declarations {
		bundle_walk_pattern(scan, declarator.id)
		if init, ok := declarator.init.?; ok { bundle_walk_expression(scan, init) }
	}
}

@(private="file")
bundle_walk_statement :: proc(scan: ^BundleScan, statement: ^Statement) {
	if statement == nil { return }
	if scan.depth > BUNDLE_AST_DEPTH_MAX { scan.too_deep = true; return }
	scan.depth += 1
	defer scan.depth -= 1
	#partial switch node in statement^ {
	case ^ExpressionStatement: bundle_walk_expression(scan, node.expression)
	case ^BlockStatement:      bundle_walk_statements(scan, node.body[:])
	case ^VariableDeclaration: bundle_walk_declaration(scan, node)
	case ^FunctionDeclaration: bundle_walk_function(scan, &node.expr)
	case ^ClassDeclaration:    bundle_walk_class(scan, &node.expr)
	case ^IfStatement:
		bundle_walk_expression(scan, node.test)
		bundle_walk_statement(scan, node.consequent)
		if alternate, ok := node.alternate.?; ok { bundle_walk_statement(scan, alternate) }
	case ^WhileStatement:
		bundle_walk_expression(scan, node.test)
		bundle_walk_statement(scan, node.body)
	case ^DoWhileStatement:
		bundle_walk_statement(scan, node.body)
		bundle_walk_expression(scan, node.test)
	case ^ForStatement:
		if init, ok := node.init_expr.?; ok { bundle_walk_expression(scan, init) }
		if init, ok := node.init_decl.?; ok { bundle_walk_declaration(scan, init) }
		if test, ok := node.test.?; ok { bundle_walk_expression(scan, test) }
		if update, ok := node.update.?; ok { bundle_walk_expression(scan, update) }
		bundle_walk_statement(scan, node.body)
	case ^ForInStatement:
		if left, ok := node.left_expr.?; ok { bundle_walk_expression(scan, left) }
		if left, ok := node.left_decl.?; ok { bundle_walk_declaration(scan, left) }
		bundle_walk_expression(scan, node.right)
		bundle_walk_statement(scan, node.body)
	case ^ForOfStatement:
		if node.await && scan.function_depth == 0 { scan.module.has_top_level_await = true }
		if left, ok := node.left_expr.?; ok { bundle_walk_expression(scan, left) }
		if left, ok := node.left_decl.?; ok { bundle_walk_declaration(scan, left) }
		bundle_walk_expression(scan, node.right)
		bundle_walk_statement(scan, node.body)
	case ^SwitchStatement:
		bundle_walk_expression(scan, node.discriminant)
		for switch_case in node.cases {
			if test, ok := switch_case.test.?; ok { bundle_walk_expression(scan, test) }
			bundle_walk_statements(scan, switch_case.consequent[:])
		}
	case ^ReturnStatement:
		if argument, ok := node.argument.?; ok { bundle_walk_expression(scan, argument) }
	case ^ThrowStatement:   bundle_walk_expression(scan, node.argument)
	case ^TryStatement:
		scan.try_depth += 1
		bundle_walk_statements(scan, node.block.body[:])
		scan.try_depth -= 1
		if handler, ok := node.handler.?; ok {
			if param, has_param := handler.param.?; has_param { bundle_walk_pattern(scan, param) }
			bundle_walk_statements(scan, handler.body.body[:])
		}
		if finalizer, ok := node.finalizer.?; ok { bundle_walk_statements(scan, finalizer.body[:]) }
	case ^WithStatement:
		bundle_walk_expression(scan, node.object)
		bundle_walk_statement(scan, node.body)
	case ^LabeledStatement: bundle_walk_statement(scan, node.body)
	case ^ExportNamedDeclaration:
		if declaration, ok := node.declaration.?; ok { bundle_walk_exported(scan, declaration) }
	case ^ExportDefaultDeclaration:
		switch inner in node.declaration^ {
		case ^Expression:  bundle_walk_expression(scan, inner)
		case ^Declaration: bundle_walk_exported(scan, inner)
		}
	}
}

@(private="file")
bundle_walk_exported :: proc(scan: ^BundleScan, declaration: ^Declaration) {
	#partial switch inner in declaration^ {
	case ^FunctionDeclaration: bundle_walk_function(scan, &inner.expr)
	case ^ClassDeclaration:    bundle_walk_class(scan, &inner.expr)
	case ^VariableDeclaration: bundle_walk_declaration(scan, inner)
	}
}

// Patterns carry expressions in defaults and computed keys.
@(private="file")
bundle_walk_pattern :: proc(scan: ^BundleScan, pattern: Pattern) {
	if scan.depth > BUNDLE_AST_DEPTH_MAX { scan.too_deep = true; return }
	scan.depth += 1
	defer scan.depth -= 1
	switch node in pattern {
	case ^Identifier:
	case ^AssignmentPattern:
		bundle_walk_pattern(scan, node.left)
		bundle_walk_expression(scan, node.right)
	case ^RestElement: bundle_walk_pattern(scan, node.argument)
	case ^ObjectPattern:
		for property in node.properties {
			if key, has_key := property.key.?; has_key && property.computed {
				if expression, ok := key.(^Expression); ok {
					bundle_walk_expression(scan, expression)
				}
			}
			bundle_walk_pattern(scan, property.value)
		}
	case ^ArrayPattern:
		for element in node.elements {
			if inner, present := element.(Pattern); present { bundle_walk_pattern(scan, inner) }
		}
	case ^MemberExpression:
		bundle_walk_expression(scan, node.object)
		if node.computed { bundle_walk_expression(scan, node.property) }
	}
}

@(private="file")
bundle_walk_parameters :: proc(scan: ^BundleScan, parameters: []FunctionParameter) {
	for parameter in parameters {
		bundle_walk_pattern(scan, parameter.pattern)
		if value, ok := parameter.default_val.?; ok { bundle_walk_expression(scan, value) }
	}
}

@(private="file")
bundle_walk_function :: proc(scan: ^BundleScan, function: ^FunctionExpression) {
	// A call inside a function runs later, outside any try block that
	// happens to enclose the function's definition.
	try_depth := scan.try_depth
	scan.try_depth = 0
	scan.function_depth += 1
	scan.this_depth += 1
	bundle_walk_parameters(scan, function.params[:])
	bundle_walk_statements(scan, function.body.body[:])
	scan.this_depth -= 1
	scan.function_depth -= 1
	scan.try_depth = try_depth
}

@(private="file")
bundle_walk_class :: proc(scan: ^BundleScan, class: ^ClassExpression) {
	// The heritage clause, decorators and computed keys evaluate in the
	// enclosing scope; member values have their own `this`.
	if super_class, ok := class.super_class.?; ok { bundle_walk_expression(scan, super_class) }
	for decorator in class.decorators { bundle_walk_expression(scan, decorator.expression) }
	for element in class.body.body {
		for decorator in element.decorators { bundle_walk_expression(scan, decorator.expression) }
		if element.computed { bundle_walk_expression(scan, element.key) }
		value, has_value := element.value.?
		if !has_value || value == nil { continue }
		scan.function_depth += 1
		scan.this_depth += 1
		block, is_block := value^.(^FunctionExpression)
		if is_block && element.kind == .StaticBlock {
			bundle_walk_statements(scan, block.body.body[:])
		} else {
			bundle_walk_expression(scan, value)
		}
		scan.this_depth -= 1
		scan.function_depth -= 1
	}
}

@(private="file")
bundle_walk_call :: proc(scan: ^BundleScan, slot: ^Expression, call: ^CallExpression) {
	module := scan.module
	if callee, ok := call.callee^.(^Identifier); ok {
		module.callees[callee.loc.start] = true
		if callee.name == "eval" && module.direct_eval == nil {
			module.direct_eval = callee.loc.start
		}
		if module.free_cjs[callee.loc.start] && !call.optional {
			if len(call.arguments) == 1 {
				if literal, is_literal := call.arguments[0]^.(^StringLiteral); is_literal {
					bundle_scan_record(scan, .Require, literal.value, call.loc, slot)
					return
				}
			}
			bundle_warning(scan.g, module, call.loc.start,
				"this require() call is not a string literal and stays unbundled")
		}
	}
	bundle_walk_expression(scan, call.callee)
	for argument in call.arguments { bundle_walk_expression(scan, argument) }
}

@(private="file")
bundle_walk_expression :: proc(scan: ^BundleScan, slot: ^Expression) {
	if slot == nil { return }
	if scan.depth > BUNDLE_AST_DEPTH_MAX { scan.too_deep = true; return }
	scan.depth += 1
	defer scan.depth -= 1
	module := scan.module
	// Long `a + b + c` chains nest on the left. Iterate down that spine so
	// thousands of operands do not consume thousands of stack frames.
	slot := slot
	for {
		#partial switch node in slot^ {
		case ^BinaryExpression:
			bundle_walk_expression(scan, node.right)
			slot = node.left
			continue
		case ^LogicalExpression:
			bundle_walk_expression(scan, node.right)
			slot = node.left
			continue
		}
		break
	}
	if slot == nil { return }
	#partial switch node in slot^ {
	case ^ThisExpression:
		if scan.this_depth == 0 { append(&module.this_nodes, slot) }
	case ^MetaProperty:
		if node.meta.name == "import" { module.has_import_meta = true }
	case ^AwaitExpression:
		if scan.function_depth == 0 { module.has_top_level_await = true }
		bundle_walk_expression(scan, node.argument)
	case ^ImportExpression:
		literal, is_literal := node.source^.(^StringLiteral)
		if is_literal && node.phase == "" {
			bundle_scan_record(scan, .Dynamic, literal.value, node.loc, slot)
		} else {
			bundle_warning(scan.g, module, node.loc.start,
				"this import() call is not a string literal and stays unbundled")
			bundle_walk_expression(scan, node.source)
		}
		bundle_walk_expression(scan, node.options)
	case ^CallExpression: bundle_walk_call(scan, slot, node)
	case ^FunctionExpression: bundle_walk_function(scan, node)
	case ^ClassExpression:    bundle_walk_class(scan, node)
	case ^ArrowFunctionExpression:
		try_depth := scan.try_depth
		scan.try_depth = 0
		scan.function_depth += 1
		bundle_walk_parameters(scan, node.params[:])
		switch body in node.body {
		case ^Expression:     bundle_walk_expression(scan, body)
		case ^BlockStatement: if body != nil { bundle_walk_statements(scan, body.body[:]) }
		}
		scan.function_depth -= 1
		scan.try_depth = try_depth
	case:
		bundle_walk_children(scan, slot)
	}
}

// Nodes with nothing to record: visit their operands.
@(private="file")
bundle_walk_children :: proc(scan: ^BundleScan, slot: ^Expression) {
	module := scan.module
	#partial switch node in slot^ {
	case ^NewExpression:
		bundle_walk_expression(scan, node.callee)
		for argument in node.arguments { bundle_walk_expression(scan, argument) }
	case ^TaggedTemplateExpression:
		if tag, ok := node.tag^.(^Identifier); ok { module.callees[tag.loc.start] = true }
		bundle_walk_expression(scan, node.tag)
		bundle_walk_expression(scan, node.quasi)
	case ^TemplateLiteral:
		for expression in node.expressions { bundle_walk_expression(scan, expression) }
	case ^AssignmentExpression:
		bundle_walk_expression(scan, node.left)
		bundle_walk_expression(scan, node.right)
	case ^UpdateExpression:      bundle_walk_expression(scan, node.argument)
	case ^UnaryExpression:       bundle_walk_expression(scan, node.argument)
	case ^SpreadElement:         bundle_walk_expression(scan, node.argument)
	case ^ChainExpression:       bundle_walk_expression(scan, node.expression)
	case ^ParenthesizedExpression: bundle_walk_expression(scan, node.expression)
	case ^YieldExpression:
		if argument, ok := node.argument.?; ok { bundle_walk_expression(scan, argument) }
	case ^MemberExpression:
		bundle_walk_expression(scan, node.object)
		if node.computed { bundle_walk_expression(scan, node.property) }
	case ^ConditionalExpression:
		bundle_walk_expression(scan, node.test)
		bundle_walk_expression(scan, node.consequent)
		bundle_walk_expression(scan, node.alternate)
	case ^SequenceExpression:
		for expression in node.expressions { bundle_walk_expression(scan, expression) }
	case ^ArrayExpression:
		for element in node.elements {
			if inner, present := element.(^Expression); present {
				bundle_walk_expression(scan, inner)
			}
		}
	case ^ObjectExpression:
		for property in node.properties {
			if property.computed { bundle_walk_expression(scan, property.key) }
			bundle_walk_expression(scan, property.value)
		}
	}
}

// ----------------------------------------------------------------------------
// Statement parts for tree shaking.
// ----------------------------------------------------------------------------

// Top-level statement spans are disjoint and ordered, so a binary search
// places any offset in its statement.
@(private="file")
bundle_part_at :: proc(parts: []BundlePart, offset: u32) -> int {
	lo, hi := 0, len(parts)
	for lo < hi {
		mid := (lo + hi) / 2
		if parts[mid].loc.end <= offset { lo = mid + 1 } else { hi = mid }
	}
	if lo < len(parts) && parts[lo].loc.start <= offset { return lo }
	return -1
}

@(private="file")
bundle_scan_parts :: proc(module: ^BundleModule, body: []^Statement) {
	alloc := module.job.arena_alloc
	model := &module.model
	parts := make([]BundlePart, len(body), alloc)
	annotations := bundle_pure_annotations(module)
	for statement, index in body {
		parts[index] = {
			loc = get_statement_loc(statement),
			declares = make([dynamic]string, alloc),
			uses = make([dynamic]string, alloc),
			side_effects = bundle_statement_has_effects(module, statement, annotations),
		}
		if _, is_default := statement^.(^ExportDefaultDeclaration); is_default {
			if module.exports["default"].name == BUNDLE_DEFAULT_LOCAL {
				append(&parts[index].declares, BUNDLE_DEFAULT_LOCAL)
			}
		}
	}
	for symbol in model.symbols[1:] {
		if symbol.scope != SCOPE_ROOT { continue }
		index := bundle_part_at(parts, symbol.decl_start)
		assert(index >= 0, "a root binding is declared outside every top-level statement")
		append(&parts[index].declares, symbol.name)
	}
	for ref in model.refs {
		if ref.resolved == SYMBOL_UNRESOLVED { continue }
		if model.symbols[ref.resolved].scope != SCOPE_ROOT { continue }
		index := bundle_part_at(parts, ref.start)
		assert(index >= 0, "a reference lies outside every top-level statement")
		append(&parts[index].uses, ref.name)
	}
	for &part, index in parts {
		for name in part.declares {
			if name not_in module.declared { module.declared[name] = make([dynamic]i32, alloc) }
			append(&module.declared[name], i32(index))
		}
	}
	module.parts = parts
}
