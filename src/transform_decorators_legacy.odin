package kessel

// TypeScript experimental ("legacy") decorators.
//
// A decorated class keeps its body. Decorators are applied by statements that
// follow it, in TypeScript's order: instance members, static members, then the
// constructor's parameter decorators together with the class decorators.
//
//     let key, alias;
//     let C = class C { static { alias = this; } [key = k()]() {} };
//     decorate([d], C.prototype, key, null);
//     C = alias = decorate([c], C);
//
// A class decorator may replace the class. Code inside the body must then see
// the replacement, but the inner name binding of a class is immutable, so
// those references are renamed to an alias that is assigned twice.

TransformExport :: enum u8 { None, Named, Default }

LegacyMember :: struct {
	element:    ^ClassElement,
	decorators: []Decorator,
	params:     []FunctionParameter, // Parameters to scan for decorators.
	key_temp:   string,              // Holds a computed key between definition and decoration.
	metadata:   MemberMetadata,
}

LegacyClass :: struct {
	class:       ^ClassExpression,
	members:     [dynamic]LegacyMember,
	decorators:  []Decorator,
	constructor: []FunctionParameter,
	name:        string,
	alias:       string,
	rebinds:     bool, // The class decorators may replace the binding.
	anonymous:   bool,
	temps:       [dynamic]string, // Declared once, ahead of the class.
	lowered:     ^LoweredClass,   // Set when the class was also lowered for the target.
	metadata:    MemberMetadata,
}

// Class declarations reach the printer through three paths. Each asks here
// first; false means the class has nothing to lower and prints as written.
transform_class_declaration :: proc(
	cg: ^Codegen, class: ^ClassExpression, export: TransformExport,
) -> bool {
	state := cg.transform
	if state == nil || class == nil || class.declare { return false }
	lowers := state.target < .ES2022
	// Accessor fields become a getter and a setter before decorators are
	// planned, so a decorator on one is applied to that pair.
	class_desugar_accessors(cg, class)
	if !lowers { class_register(cg, class) }
	plan := LegacyClass{class = class}
	plan.members.allocator = state.allocator
	plan.temps.allocator = state.allocator
	decorated := state.decorators == .Legacy && legacy_class_plan(cg, &plan)
	if cg.strip_diag != nil { return decorated }
	if !decorated {
		if !lowers { return false }
		if class.id == nil { return class_default_anonymous(cg, class) }
		info := class_lower(cg, class, "")
		info.emitted = true
		return class_declaration_emit(cg, info, export)
	}
	// Decorated members are planned first, while the fields are still in the
	// class; lowering then removes the fields and the plan keeps their keys.
	legacy_class_names(cg, &plan, export)
	if lowers {
		plan.lowered = class_lower(cg, class, "")
		plan.lowered.emitted = true
	}
	legacy_class_emit(cg, &plan, export)
	return true
}

// `export default class { ... }` has no binding to call its static part on,
// so it is exported as the value of the lowered class expression.
class_default_anonymous :: proc(cg: ^Codegen, class: ^ClassExpression) -> bool {
	state := cg.transform
	if !class_needs_lowering(cg, class) { return false }
	state.class_names[class.loc.start] = "default"
	cg_module_keyword(cg, "export default ")
	gen_expression(cg, transform_expression(state, class), PREC_ASSIGN)
	cg_byte(cg, ';')
	return true
}

transform_export_named_class :: proc(cg: ^Codegen, s: ^ExportNamedDeclaration) -> bool {
	if cg.transform == nil { return false }
	declaration, present := s.declaration.?
	if !present || declaration == nil { return false }
	class, is_class := declaration^.(^ClassDeclaration)
	if !is_class { return false }
	return transform_class_declaration(cg, &class.expr, .Named)
}

transform_export_default_class :: proc(cg: ^Codegen, s: ^ExportDefaultDeclaration) -> bool {
	if cg.transform == nil { return false }
	switch value in s.declaration^ {
	case ^Declaration:
		if class, is_class := value^.(^ClassDeclaration); is_class {
			return transform_class_declaration(cg, &class.expr, .Default)
		}
	case ^Expression:
		if class, is_class := value^.(^ClassExpression); is_class {
			return transform_class_declaration(cg, class, .Default)
		}
	}
	return false
}

// TypeScript rejects decorators on class expressions and on their members.
// Printing them unchanged would leave syntax that no engine runs.
transform_legacy_class_expression :: proc(cg: ^Codegen, class: ^ClassExpression) {
	plan := LegacyClass{class = class}
	plan.members.allocator = cg.transform.allocator
	if legacy_class_plan(cg, &plan) {
		cg_strip_unsupported(cg, class.loc, "legacy decorators are not valid on a class expression")
	}
}

transform_param_decorators :: proc(cg: ^Codegen, param: FunctionParameter) -> []Decorator {
	table := cg.transform.job.parser.param_decorators
	if table == nil { return nil }
	key := param.loc.start
	if param.modifier_start != 0 && param.modifier_start < key { key = param.modifier_start }
	return table[key][:]
}

legacy_params_decorated :: proc(cg: ^Codegen, params: []FunctionParameter) -> bool {
	for param in params {
		if len(transform_param_decorators(cg, param)) != 0 { return true }
	}
	return false
}

// Collects what must be applied and reports the shapes TypeScript itself rejects.
legacy_class_plan :: proc(cg: ^Codegen, plan: ^LegacyClass) -> (decorated: bool) {
	class := plan.class
	plan.decorators = class.decorators[:]
	decorated = len(plan.decorators) != 0
	for &element, index in class.body.body {
		function: ^FunctionExpression
		if value, present := element.value.?; present && value != nil && element.kind != .Field {
			function, _ = value^.(^FunctionExpression)
		}
		params: []FunctionParameter
		if function != nil { params = function.params[:] }
		if element.kind == .Constructor {
			if function != nil && !function.no_body && legacy_params_decorated(cg, params) {
				plan.constructor = params
				decorated = true
			}
			continue
		}
		member := LegacyMember{
			element = &element, decorators = element.decorators[:], params = params,
		}
		if element.kind == .Get || element.kind == .Set {
			if !legacy_accessor_merge(cg, class, index, &member) { continue }
		}
		if len(member.decorators) == 0 && !legacy_params_decorated(cg, member.params) { continue }
		decorated = true
		if !legacy_member_supported(cg, &element, function) { continue }
		append(&plan.members, member)
	}
	return decorated
}

// TypeScript applies one decoration to a get/set pair, where the first of the
// two is declared: the decorators of whichever accessor has them, then the
// setter's parameter decorators. False when the partner already covered it.
legacy_accessor_merge :: proc(
	cg: ^Codegen, class: ^ClassExpression, index: int, member: ^LegacyMember,
) -> bool {
	other := legacy_accessor_partner(class, index)
	if other < 0 { return true }
	partner := &class.body.body[other]
	if len(partner.decorators) != 0 && len(member.decorators) != 0 {
		what := "decorators cannot be applied to both accessors of a property"
		cg_strip_unsupported(cg, member.element.loc, what)
		return false
	}
	if other < index { return false }
	if len(member.decorators) == 0 { member.decorators = partner.decorators[:] }
	if partner.kind == .Set {
		member.params = nil
		if value, present := partner.value.?; present && value != nil {
			if function, ok := value^.(^FunctionExpression); ok {
				member.params = function.params[:]
			}
		}
	}
	return true
}

// False for members whose decorators TypeScript drops or which were reported.
legacy_member_supported :: proc(
	cg: ^Codegen, element: ^ClassElement, function: ^FunctionExpression,
) -> bool {
	#partial switch element.kind {
	case .StaticBlock, .IndexSignature, .Constructor: return false
	}
	// Overload signatures and abstract members have no property to decorate.
	if element.abstract { return false }
	if function != nil && function.no_body { return false }
	if _, private := element.key^.(^PrivateIdentifier); private {
		what := "legacy decorators cannot be applied to a private member"
		cg_strip_unsupported(cg, element.loc, what)
		return false
	}
	if element.declare && element.computed && !legacy_key_is_constant(element.key) {
		cg_strip_unsupported(cg, element.loc, "a decorated declared field needs a constant key")
		return false
	}
	return true
}

legacy_key_is_constant :: proc(key: ^Expression) -> bool {
	#partial switch value in key^ {
	case ^StringLiteral, ^NumericLiteral: return true
	case ^TemplateLiteral: return len(value.expressions) == 0
	}
	return false
}

// Index of the other accessor of the same property, or -1. Computed keys are
// compared only when constant, because TypeScript pairs accessors by name.
legacy_accessor_partner :: proc(class: ^ClassExpression, index: int) -> int {
	element := class.body.body[index]
	name, named := legacy_key_name(element)
	if !named { return -1 }
	wanted := ClassElementKind.Set if element.kind == .Get else ClassElementKind.Get
	for other, other_index in class.body.body {
		if other_index == index || other.kind != wanted || other.static != element.static {
			continue
		}
		other_name, other_named := legacy_key_name(other)
		if other_named && other_name == name { return other_index }
	}
	return -1
}

legacy_key_name :: proc(element: ClassElement) -> (name: string, named: bool) {
	#partial switch key in element.key^ {
	case ^Identifier:    if !element.computed { return key.name, true }
	case ^StringLiteral: return key.value, true
	}
	return "", false
}

legacy_class_names :: proc(cg: ^Codegen, plan: ^LegacyClass, export: TransformExport) {
	state := cg.transform
	class := plan.class
	plan.rebinds = len(plan.decorators) != 0 || plan.constructor != nil
	if id, named := class.id.?; named {
		plan.name = id.name
	} else {
		assert(export == .Default)
		plan.anonymous = true
		plan.name = codegen_fresh_runtime_binding(cg, "default")
	}
	for &member in plan.members {
		element := member.element
		if !element.computed || legacy_key_is_constant(element.key) { continue }
		member.key_temp = codegen_fresh_runtime_binding(cg, "key")
		append(&plan.temps, member.key_temp)
		at := loc_from_expr(element.key).start
		temp := transform_identifier(state, member.key_temp, at)
		element.key = transform_assignment(state, temp, element.key, at)
	}
	if plan.rebinds && !plan.anonymous { legacy_class_alias(cg, plan) }
	if plan.alias != "" { append(&plan.temps, plan.alias) }
	if state.emit_metadata {
		scope := metadata_scope(cg, plan)
		for &member in plan.members { member.metadata = metadata_for_member(&scope, member) }
		if plan.rebinds { plan.metadata = metadata_for_class(&scope) }
	}
}

// Renames every value reference to the class from inside its own body.
legacy_class_alias :: proc(cg: ^Codegen, plan: ^LegacyClass) {
	state := cg.transform
	class := plan.class
	id := class.id.? or_else unreachable()
	model := transform_model(cg)
	target := SYMBOL_UNRESOLVED
	for symbol, index in model.symbols {
		if symbol.decl_start == id.loc.start && symbol.name == id.name { target = SymbolId(index) }
	}
	if target == SYMBOL_UNRESOLVED { return }
	for ref in model.refs {
		if ref.resolved != target || ref.kind == .Type { continue }
		if ref.start < class.body.loc.start || ref.start >= class.body.loc.end { continue }
		if plan.alias == "" { plan.alias = codegen_fresh_runtime_binding(cg, "class") }
		if cg.renamed == nil { cg.renamed = make(map[u32]string, 8, state.allocator) }
		cg.renamed[ref.start] = plan.alias
	}
}

// Static initializers run before the outer binding exists, so the first thing
// the class does is publish itself through the alias.
legacy_alias_block :: proc(state: ^TransformState, class: ^ClassExpression, alias: string) {
	at := class.body.loc.start
	this := new(ThisExpression, state.allocator)
	this.loc = {at, at}
	statement := new(ExpressionStatement, state.allocator)
	statement^ = {
		loc = {at, at},
		expression = transform_assignment(
			state, transform_identifier(state, alias, at), transform_expression(state, this), at,
		),
	}
	wrapped := new(Statement, state.allocator)
	wrapped^ = statement
	block := new(FunctionExpression, state.allocator)
	block.loc = {at, at}
	block.body.loc = {at, at}
	block.body.body = make([dynamic]^Statement, 0, 1, state.allocator)
	append(&block.body.body, wrapped)
	elements := make([dynamic]ClassElement, 0, len(class.body.body) + 1, state.allocator)
	append(&elements, ClassElement{
		loc = {at, at}, kind = .StaticBlock, value = transform_expression(state, block),
	})
	append(&elements, ..class.body.body[:])
	class.body.body = elements
}

legacy_class_emit :: proc(cg: ^Codegen, plan: ^LegacyClass, export: TransformExport) {
	class := plan.class
	class_declaration_before(cg, plan.lowered)
	legacy_class_temporaries(cg, plan)
	binds := plan.rebinds || plan.anonymous
	// A target without static blocks has no static initializers either, so
	// nothing can read the alias before the class expression has a value.
	static_blocks := cg.transform.target >= .ES2022
	if binds {
		cg_str(cg, "let ")
		cg_str(cg, plan.name)
		cg_infix_operator(cg, "=")
		if plan.alias != "" && !static_blocks {
			cg_str(cg, plan.alias)
			cg_infix_operator(cg, "=")
		}
		// A property definition names an anonymous class "default", as the export would.
		if plan.anonymous { cg_str(cg, "{default:"); cg_space(cg) }
	} else if export == .Named {
		cg_module_keyword(cg, "export ")
	} else if export == .Default {
		cg_module_keyword(cg, "export default ")
	}
	class.decorators = nil
	for &element in class.body.body { element.decorators = nil }
	if plan.alias != "" && static_blocks { legacy_alias_block(cg.transform, class, plan.alias) }
	if cg.sm != nil { sourcemap_record(cg.sm, u32(cg.pos), class.loc.start) }
	gen_class_like(
		cg, "" if plan.anonymous else plan.name, class.super_class, class.body,
		class.type_parameters, class.super_type_arguments, class.implements,
	)
	if plan.anonymous { cg_str(cg, "}.default") }
	if binds { cg_byte(cg, ';') }
	// Static initializers run before any decorator is applied.
	class_declaration_after(cg, plan.lowered, plan.name)
	for static in ([2]bool{false, true}) {
		for member in plan.members {
			if member.element.static == static { legacy_member_emit(cg, plan, member) }
		}
	}
	if plan.rebinds { legacy_class_decorate(cg, plan) }
	if binds && export != .None {
		cg_newline(cg)
		cg_module_keyword(cg, "export {")
		cg_space(cg)
		cg_str(cg, plan.name)
		if export == .Default { cg_str(cg, " as default") }
		cg_space(cg)
		cg_str(cg, "};")
	}
}

// Block-scoped, so each evaluation of the enclosing block gets fresh ones.
legacy_class_temporaries :: proc(cg: ^Codegen, plan: ^LegacyClass) {
	if len(plan.temps) == 0 { return }
	for temp, index in plan.temps {
		cg_str(cg, "let " if index == 0 else ",")
		if index != 0 { cg_space(cg) }
		cg_str(cg, temp)
	}
	cg_byte(cg, ';')
	cg_newline(cg)
}

legacy_decorator_list :: proc(
	cg: ^Codegen, decorators: []Decorator, params: []FunctionParameter, metadata: MemberMetadata,
) {
	first := true
	cg_byte(cg, '[')
	for decorator in decorators {
		if !first { cg_byte(cg, ','); cg_space(cg) }
		first = false
		gen_expression(cg, decorator.expression, PREC_ASSIGN)
	}
	for param, index in params {
		for decorator in transform_param_decorators(cg, param) {
			if !first { cg_byte(cg, ','); cg_space(cg) }
			first = false
			cg_str(cg, transform_helper(cg, .Decorate_Param))
			cg_byte(cg, '(')
			legacy_param_index(cg, params, index)
			cg_byte(cg, ',')
			cg_space(cg)
			gen_expression(cg, decorator.expression, PREC_ASSIGN)
			cg_byte(cg, ')')
		}
	}
	// Every list has a decorator before the metadata, so the entries lead with a comma.
	assert(!first)
	metadata_emit(cg, metadata)
	cg_byte(cg, ']')
}

// A leading `this` parameter is erased and does not count.
legacy_param_index :: proc(cg: ^Codegen, params: []FunctionParameter, index: int) {
	position := index
	if id, ok := params[0].pattern.(^Identifier); ok && id.name == "this" { position -= 1 }
	assert(position >= 0)
	buffer: [20]byte
	digits := len(buffer)
	for {
		digits -= 1
		buffer[digits] = byte('0' + position % 10)
		position /= 10
		if position == 0 { break }
	}
	cg_str(cg, string(buffer[digits:]))
}

legacy_member_emit :: proc(cg: ^Codegen, plan: ^LegacyClass, member: LegacyMember) {
	element := member.element
	cg_newline(cg)
	cg_indent(cg)
	if cg.sm != nil { sourcemap_record(cg.sm, u32(cg.pos), element.loc.start) }
	cg_str(cg, transform_helper(cg, .Decorate))
	cg_byte(cg, '(')
	legacy_decorator_list(cg, member.decorators, member.params, member.metadata)
	cg_byte(cg, ',')
	cg_space(cg)
	cg_str(cg, plan.name)
	if !element.static { cg_str(cg, ".prototype") }
	cg_byte(cg, ',')
	cg_space(cg)
	if member.key_temp != "" {
		cg_str(cg, member.key_temp)
	} else if id, plain := element.key^.(^Identifier); plain && !element.computed {
		gen_string_quoted(cg, id.name)
	} else {
		gen_expression(cg, element.key, PREC_ASSIGN)
	}
	cg_byte(cg, ',')
	cg_space(cg)
	// A field has no descriptor to read; null asks the helper to look one up.
	cg_str(cg, "void 0" if element.kind == .Field else "null")
	cg_str(cg, ");")
}

legacy_class_decorate :: proc(cg: ^Codegen, plan: ^LegacyClass) {
	cg_newline(cg)
	cg_indent(cg)
	cg_str(cg, plan.name)
	cg_infix_operator(cg, "=")
	if plan.alias != "" {
		cg_str(cg, plan.alias)
		cg_infix_operator(cg, "=")
	}
	cg_str(cg, transform_helper(cg, .Decorate))
	cg_byte(cg, '(')
	legacy_decorator_list(cg, plan.decorators, plan.constructor, plan.metadata)
	cg_byte(cg, ',')
	cg_space(cg)
	cg_str(cg, plan.name)
	cg_str(cg, ");")
}
