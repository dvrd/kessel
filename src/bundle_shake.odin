package kessel

// Tree shaking and evaluation order.
//
// Side-effect analysis is deliberately conservative: a statement is removable
// only when evaluating it provably runs no user code. Anything the analysis
// does not recognise counts as an effect and is kept.

BundleEffects :: struct {
	module:      ^BundleModule,
	annotations: map[u32]CodegenAnnotations,
	unresolved:  map[u32]bool, // offsets of references to free (global) names
}

// The printer already knows how to attach `/* @__PURE__ */` comments to the
// node that follows them; reuse its index instead of re-deriving the rule.
bundle_pure_annotations :: proc(module: ^BundleModule) -> BundleEffects {
	alloc := module.job.arena_alloc
	cg := Codegen{source = module.source}
	codegen_index_annotations(&cg, module.job.lexer.comments[:], alloc)
	effects := BundleEffects{module = module, annotations = cg.annotations}
	effects.unresolved = make(map[u32]bool, alloc)
	for ref in module.model.refs {
		if ref.resolved == SYMBOL_UNRESOLVED { effects.unresolved[ref.start] = true }
	}
	return effects
}

bundle_statement_has_effects :: proc(
	module: ^BundleModule,
	statement: ^Statement,
	effects: BundleEffects,
) -> bool {
	effects := effects
	#partial switch node in statement^ {
	case ^ImportDeclaration, ^ExportAllDeclaration, ^EmptyStatement, ^FunctionDeclaration:
		return false
	case ^ExpressionStatement:
		if node.directive != "" { return false }
		return !bundle_expression_pure(&effects, node.expression, 0)
	case ^VariableDeclaration: return bundle_declaration_has_effects(&effects, node)
	case ^ClassDeclaration:    return !bundle_class_pure(&effects, &node.expr, 0)
	case ^ExportNamedDeclaration:
		declaration, has_declaration := node.declaration.?
		if !has_declaration { return false }
		#partial switch inner in declaration^ {
		case ^FunctionDeclaration: return false
		case ^VariableDeclaration: return bundle_declaration_has_effects(&effects, inner)
		case ^ClassDeclaration:    return !bundle_class_pure(&effects, &inner.expr, 0)
		}
		return true
	case ^ExportDefaultDeclaration:
		switch inner in node.declaration^ {
		case ^Expression: return !bundle_expression_pure(&effects, inner, 0)
		case ^Declaration:
			#partial switch declaration in inner^ {
			case ^FunctionDeclaration: return false
			case ^ClassDeclaration:    return !bundle_class_pure(&effects, &declaration.expr, 0)
			}
		}
		return true
	}
	return true
}

@(private="file")
bundle_declaration_has_effects :: proc(
	effects: ^BundleEffects,
	declaration: ^VariableDeclaration,
) -> bool {
	// Disposal runs user code when the scope exits.
	if declaration.kind == .Using || declaration.kind == .AwaitUsing { return true }
	for declarator in declaration.declarations {
		// Destructuring reads properties, which can run getters.
		if _, simple := declarator.id.(^Identifier); !simple { return true }
		if init, ok := declarator.init.?; ok {
			if !bundle_expression_pure(effects, init, 0) { return true }
		}
	}
	return false
}

@(private="file")
bundle_class_pure :: proc(effects: ^BundleEffects, class: ^ClassExpression, depth: int) -> bool {
	if len(class.decorators) != 0 { return false }
	if super_class, ok := class.super_class.?; ok {
		if !bundle_expression_pure(effects, super_class, depth + 1) { return false }
	}
	for element in class.body.body {
		if len(element.decorators) != 0 || element.kind == .StaticBlock { return false }
		if element.computed && !bundle_expression_primitive(element.key) { return false }
		if !element.static || element.kind != .Field { continue }
		if value, ok := element.value.?; ok && value != nil {
			if !bundle_expression_pure(effects, value, depth + 1) { return false }
		}
	}
	return true
}

// A literal whose conversion to a property key or operand runs no code.
@(private="file")
bundle_expression_primitive :: proc(expression: ^Expression) -> bool {
	if expression == nil { return false }
	#partial switch node in expression^ {
	case ^NullLiteral, ^BooleanLiteral, ^NumericLiteral, ^StringLiteral, ^BigIntLiteral: return true
	case ^TemplateLiteral: return len(node.expressions) == 0
	}
	return false
}

@(private="file")
bundle_global_is_pure :: proc(name: string) -> bool {
	switch name {
	case "undefined", "NaN", "Infinity", "globalThis", "Object", "Array", "String", "Number",
	     "Boolean", "Symbol", "BigInt", "Math", "JSON", "Reflect", "Proxy", "Map", "Set",
	     "WeakMap", "WeakSet", "Promise", "Date", "RegExp", "Function", "Error", "TypeError",
	     "RangeError", "SyntaxError", "ReferenceError", "EvalError", "URIError", "ArrayBuffer",
	     "DataView", "Uint8Array", "Int8Array", "Uint16Array", "Int16Array", "Uint32Array",
	     "Int32Array", "Float32Array", "Float64Array", "console", "parseInt", "parseFloat",
	     "isNaN", "isFinite":
		return true
	}
	return false
}

@(private="file")
bundle_expression_pure :: proc(
	effects: ^BundleEffects,
	expression: ^Expression,
	depth: int,
) -> bool {
	if expression == nil { return true }
	// Too deep to analyse is treated as an effect, which is always safe.
	if depth > BUNDLE_AST_DEPTH_MAX { return false }
	next := depth + 1
	#partial switch node in expression^ {
	case ^NullLiteral, ^BooleanLiteral, ^NumericLiteral, ^StringLiteral, ^BigIntLiteral,
	     ^RegExpLiteral,
	     ^FunctionExpression, ^ArrowFunctionExpression, ^ThisExpression, ^MetaProperty:
		return true
	case ^Identifier:
		// Reading an undeclared global throws a ReferenceError.
		return !effects.unresolved[node.loc.start] || bundle_global_is_pure(node.name)
	case ^TemplateLiteral:
		for inner in node.expressions {
			if !bundle_expression_primitive(inner) { return false }
		}
		return true
	case ^ParenthesizedExpression: return bundle_expression_pure(effects, node.expression, next)
	case ^ClassExpression:         return bundle_class_pure(effects, node, next)
	case ^UnaryExpression:
		#partial switch node.operator {
		case .Typeof:
			if _, is_identifier := node.argument^.(^Identifier); is_identifier { return true }
			return bundle_expression_pure(effects, node.argument, next)
		case .Void, .LogicalNot: return bundle_expression_pure(effects, node.argument, next)
		case .Minus, .Plus, .BitwiseNot: return bundle_expression_primitive(node.argument)
		}
		return false
	case ^BinaryExpression, ^LogicalExpression:
		return bundle_chain_pure(effects, expression, next)
	case ^ConditionalExpression:
		return bundle_expression_pure(effects, node.test, next) &&
			bundle_expression_pure(effects, node.consequent, next) &&
			bundle_expression_pure(effects, node.alternate, next)
	case ^SequenceExpression, ^ArrayExpression, ^ObjectExpression, ^CallExpression, ^NewExpression:
		return bundle_compound_pure(effects, expression, next)
	}
	return false
}

// `a === b === c` and `a && b && c` nest on the left without limit, so the
// left operands are checked in a loop. The bound is the node count of the tree.
@(private="file")
bundle_chain_pure :: proc(effects: ^BundleEffects, expression: ^Expression, next: int) -> bool {
	current := expression
	for _ in 0..<EXPR_SPINE_COUNT_MAX {
		#partial switch node in current^ {
		case ^LogicalExpression:
			if !bundle_expression_pure(effects, node.right, next) { return false }
			current = node.left
			continue
		case ^BinaryExpression:
			if node.operator == .StrictEq || node.operator == .StrictNotEq {
				if !bundle_expression_pure(effects, node.right, next) { return false }
				current = node.left
				continue
			}
			// Other operators convert their operands, which can call valueOf.
			if node.operator == .In || node.operator == .Instanceof { return false }
			return bundle_expression_primitive(node.left) && bundle_expression_primitive(node.right)
		}
		return bundle_expression_pure(effects, current, next)
	}
	return false
}

// Expressions made of a list of operands: pure when every operand is, a
// spread (which runs an iterator) is absent, and a call is annotated.
@(private="file")
bundle_compound_pure :: proc(effects: ^BundleEffects, expression: ^Expression, next: int) -> bool {
	#partial switch node in expression^ {
	case ^SequenceExpression:
		for inner in node.expressions {
			if !bundle_expression_pure(effects, inner, next) { return false }
		}
		return true
	case ^ArrayExpression:
		for element in node.elements {
			inner, present := element.(^Expression)
			if !present { continue }
			if _, spread := inner^.(^SpreadElement); spread { return false }
			if !bundle_expression_pure(effects, inner, next) { return false }
		}
		return true
	case ^ObjectExpression:
		for property in node.properties {
			if _, spread := property.value^.(^SpreadElement); spread { return false }
			if property.computed && !bundle_expression_primitive(property.key) { return false }
			if !bundle_expression_pure(effects, property.value, next) { return false }
		}
		return true
	case ^CallExpression:
		if .Pure not_in effects.annotations[node.loc.start] { return false }
		for argument in node.arguments {
			if _, spread := argument^.(^SpreadElement); spread { return false }
			if !bundle_expression_pure(effects, argument, next) { return false }
		}
		return true
	case ^NewExpression:
		if .Pure not_in effects.annotations[node.loc.start] { return false }
		for argument in node.arguments {
			if _, spread := argument^.(^SpreadElement); spread { return false }
			if !bundle_expression_pure(effects, argument, next) { return false }
		}
		return true
	}
	return false
}

// ----------------------------------------------------------------------------
// Liveness.
// ----------------------------------------------------------------------------

@(private="file")
BundleShakeKind :: enum u8 { Module, Part, Name, Target }

@(private="file")
BundleShakeItem :: struct {
	kind:   BundleShakeKind,
	module: i32,
	part:   i32,
	name:   string,
	target: BundleTarget,
}

// Mark what the bundle keeps. Work items are processed from an explicit
// stack; every item either flips a flag from false to true or is dropped, so
// the loop ends after at most one pass over each module, part and binding.
bundle_shake :: proc(g: ^BundleGraph) {
	work := make([dynamic]BundleShakeItem, g.alloc)
	entry := g.modules[0]
	append(&work, BundleShakeItem{kind = .Module, module = 0})
	if entry.kind == .ESM {
		for name in bundle_export_names(g, entry) {
			append(&work,
				BundleShakeItem{kind = .Target, target = bundle_resolve_hoisted(g, entry, name, 0)})
		}
		// CommonJS and IIFE consumers receive the entry's namespace object.
		// A named IIFE global gets one even when the entry exports nothing.
		wanted := g.options.global_name != ""
		if g.options.format == .CJS { wanted = len(entry.export_names) != 0 }
		if g.options.format != .ESM && wanted && entry.wrap == .None {
			entry.needs_namespace = true
		}
	}
	for len(work) > 0 {
		item := pop(&work)
		switch item.kind {
		case .Module: bundle_shake_module(g, &work, item.module)
		case .Part:   bundle_shake_part(g, &work, item.module, item.part)
		case .Name:   bundle_shake_name(g, &work, item.module, item.name)
		case .Target: bundle_shake_target(g, &work, item.target)
		}
	}
}

@(private="file")
bundle_shake_module :: proc(g: ^BundleGraph, work: ^[dynamic]BundleShakeItem, index: i32) {
	if index < 0 { return }
	module := g.modules[index]
	if module.included { return }
	module.included = true
	if module.wrap != .None {
		// A wrapped module is kept whole, so everything it can reach is too.
		for record in module.records {
			append(work, BundleShakeItem{kind = .Module, module = record.target})
		}
		if module.kind != .ESM { return }
		for local in module.imports {
			append(work,
				BundleShakeItem{kind = .Target, target = bundle_import_target(g, module, local)})
		}
		for name in bundle_export_names(g, module) {
			inner := bundle_resolve_hoisted(g, module, name, 0)
			if inner.kind != .Symbol {
				append(work, BundleShakeItem{kind = .Target, target = inner})
			}
		}
		return
	}
	for part, part_index in module.parts {
		if part.side_effects || !g.options.tree_shaking {
			append(work, BundleShakeItem{kind = .Part, module = index, part = i32(part_index)})
		}
	}
	for record in module.records {
		if record.kind != .Import || record.target < 0 { continue }
		if g.modules[record.target].side_effect_free && g.options.tree_shaking { continue }
		append(work, BundleShakeItem{kind = .Module, module = record.target})
	}
}

@(private="file")
bundle_shake_part :: proc(
	g: ^BundleGraph,
	work: ^[dynamic]BundleShakeItem,
	index,
	part_index: i32,
) {
	module := g.modules[index]
	part := &module.parts[part_index]
	if part.live { return }
	part.live = true
	// Using any binding of a module means the module is evaluated, so its
	// side effects must run as well.
	append(work, BundleShakeItem{kind = .Module, module = index})
	for name in part.uses {
		append(work, BundleShakeItem{kind = .Name, module = index, name = name})
	}
	for record in module.records {
		if record.statement == part_index && record.kind != .Import {
			append(work, BundleShakeItem{kind = .Module, module = record.target})
		}
	}
}

@(private="file")
bundle_shake_name :: proc(
	g: ^BundleGraph,
	work: ^[dynamic]BundleShakeItem,
	index: i32,
	name: string,
) {
	module := g.modules[index]
	if name in module.imports {
		append(work,
			BundleShakeItem{kind = .Target, target = bundle_import_target(g, module, name)})
		return
	}
	for part in module.declared[name] {
		if !module.parts[part].live {
			append(work, BundleShakeItem{kind = .Part, module = index, part = part})
		}
	}
}

@(private="file")
bundle_shake_target :: proc(
	g: ^BundleGraph,
	work: ^[dynamic]BundleShakeItem,
	target: BundleTarget,
) {
	switch target.kind {
	case .Missing, .Ambiguous:
	case .Symbol:
		append(work, BundleShakeItem{kind = .Name, module = target.module, name = target.name})
	case .Namespace:
		module := g.modules[target.module]
		append(work, BundleShakeItem{kind = .Module, module = target.module})
		append(work, BundleShakeItem{kind = .Module, module = target.via_module})
		if module.wrap != .None || module.needs_namespace { return }
		module.needs_namespace = true
		for name in bundle_export_names(g, module) {
			append(work, BundleShakeItem{kind = .Target, target = bundle_resolve_hoisted(g, module,
				name, 0)})
		}
	case .Property, .External:
		// The importing record must bind the interop object where it runs.
		g.modules[target.via_module].records[target.via_record].used = true
		append(work, BundleShakeItem{kind = .Module, module = target.module})
		append(work, BundleShakeItem{kind = .Module, module = target.via_module})
	}
}

// ----------------------------------------------------------------------------
// Evaluation order.
// ----------------------------------------------------------------------------

BundleEventKind :: enum u8 {
	Code, // print the hoisted statements of `module`
	Init, // start the wrapped module that `record` of `module` imports
}

BundleEvent :: struct {
	kind:   BundleEventKind,
	module: i32,
	record: i32,
}

@(private="file")
BundleOrderFrame :: struct {
	module: i32,
	next:   int,
}

// ES evaluation order: a depth-first post-order over static imports in source
// order. The traversal passes through modules that tree shaking dropped,
// because a kept module may only be reachable through one of them. The
// explicit stack holds each module at most once.
bundle_order :: proc(g: ^BundleGraph) {
	entry := g.modules[0]
	bundle_order_check_namespaces(g)
	if entry.wrap == .None {
		stack := make([dynamic]BundleOrderFrame, g.alloc)
		append(&stack, BundleOrderFrame{module = 0})
		entry.visit_state = 1
		for len(stack) > 0 {
			assert(len(stack) <= len(g.modules))
			frame := &stack[len(stack) - 1]
			module := g.modules[frame.module]
			descended := false
			for frame.next < len(module.records) && !descended {
				record_index := frame.next
				frame.next += 1
				descended = bundle_order_record(g, &stack, module, i32(record_index))
			}
			if descended { continue }
			if module.included {
				append(&g.order, BundleEvent{kind = .Code, module = module.index})
			}
			module.visit_state = 2
			pop(&stack)
		}
	}
	// Lazy ES modules still import their externals at the top of the file.
	for module in g.modules {
		if module.wrap != .ESM || !module.included { continue }
		for record in module.records {
			if record.kind == .Import && record.target == BUNDLE_EXTERNAL {
				bundle_external_for(g, record.specifier)
			}
		}
	}
}

// A namespace object lists its export names up front. The names an external
// module contributes through `export *` cannot be listed, so such a module can
// be imported by name but not as a whole. An ESM entry needs no namespace
// object of its own and re-exports the star as-is.
@(private="file")
bundle_order_check_namespaces :: proc(g: ^BundleGraph) {
	for module in g.modules {
		materialized := module.needs_namespace || module.wrap == .ESM
		if !module.included || module.kind != .ESM || !materialized { continue }
		if len(bundle_external_stars(g, module)) != 0 {
			bundle_error(g, module, nil,
				"cannot build a namespace object: the module uses 'export *' from an external")
		}
	}
}

// Returns true when the traversal pushed a hoisted dependency to visit first.
@(private="file")
bundle_order_record :: proc(
	g: ^BundleGraph,
	stack: ^[dynamic]BundleOrderFrame,
	module: ^BundleModule,
	record_index: i32,
) -> bool {
	record := module.records[record_index]
	if record.kind != .Import { return false }
	if record.target == BUNDLE_EXTERNAL {
		if module.included { bundle_external_for(g, record.specifier) }
		return false
	}
	target := g.modules[record.target]
	if target.wrap != .None {
		if module.included && target.included {
			append(&g.order,
				BundleEvent{kind = .Init, module = module.index, record = record_index})
		}
		return false
	}
	if target.visit_state != 0 { return false }
	target.visit_state = 1
	append(stack, BundleOrderFrame{module = target.index})
	return true
}

bundle_external_for :: proc(g: ^BundleGraph, specifier: string) -> ^BundleExternalImport {
	index, found := g.external_index[specifier]
	if !found {
		index = i32(len(g.externals))
		append(&g.externals, BundleExternalImport{
			specifier = specifier,
			names = make(map[string]string, g.alloc),
			order = make([dynamic]string, g.alloc),
		})
		g.external_index[specifier] = index
	}
	return &g.externals[index]
}
