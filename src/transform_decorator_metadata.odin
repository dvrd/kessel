package kessel

// Design-time type metadata for legacy decorators (emitDecoratorMetadata).
//
// Each decorated member also records "design:type", "design:paramtypes" and
// "design:returntype" through Reflect.metadata. The values are constructors
// derived from the type annotations alone, the way TypeScript derives them
// with strictNullChecks when it compiles one file in isolation:
//
//   - a keyword or literal type names its global constructor;
//   - a reference to a class in scope is that class;
//   - a reference to an interface, alias, type parameter or type-only import
//     is Object, and an enum is Number, String or Object by its members;
//   - any other name may or may not exist at run time, so it is read behind a
//     typeof guard and falls back to Object.
//
// Without a type checker an alias is never expanded, so `type Id = string`
// records Object where the full compiler records String.

MetadataKind :: enum u8 { Undefined, Global, Guarded }

MetadataType :: struct {
	kind:      MetadataKind,
	name:      string,      // Global: the identifier to print.
	reference: ^Expression, // Guarded: the entity name as written.
	temps:     []string,    // Guarded: one binding per guard step.
}

MetadataScope :: struct {
	cg:          ^Codegen,
	plan:        ^LegacyClass,
	scope:       ScopeId, // Where the names in annotations are looked up.
	type_params: [2]Maybe(^TSTypeParameterDeclaration),
}

MemberMetadata :: struct {
	type:        Maybe(MetadataType),
	params:      Maybe([]MetadataType),
	return_type: Maybe(MetadataType),
}

METADATA_OBJECT :: MetadataType{kind = .Global, name = "Object"}

metadata_global :: proc(name: string) -> MetadataType { return {kind = .Global, name = name} }

metadata_scope :: proc(cg: ^Codegen, plan: ^LegacyClass) -> MetadataScope {
	model := transform_model(cg)
	scope := MetadataScope{cg = cg, plan = plan}
	scope.type_params[0] = plan.class.type_parameters
	for candidate, index in model.scopes {
		if candidate.kind == .Class && candidate.node_start == plan.class.loc.start {
			scope.scope = ScopeId(index)
		}
	}
	return scope
}

metadata_for_class :: proc(scope: ^MetadataScope) -> (result: MemberMetadata) {
	for element in scope.plan.class.body.body {
		if element.kind != .Constructor { continue }
		function := metadata_function(element)
		if function == nil || function.no_body { continue }
		result.params = metadata_params(scope, function.params[:])
		return
	}
	return
}

metadata_for_member :: proc(
	scope: ^MetadataScope, member: LegacyMember) -> (result: MemberMetadata,
) {
	element := member.element
	function := metadata_function(element^)
	scope.type_params[1] = function.type_parameters if function != nil else nil
	defer scope.type_params[1] = nil
	switch element.kind {
	case .Field:
		result.type = metadata_annotation(scope, element.typing.annotation)
	case .Method:
		assert(function != nil)
		result.type = metadata_global("Function")
		result.params = metadata_params(scope, function.params[:])
		if annotation, annotated := function.return_type.?; annotated {
			result.return_type = metadata_type(scope, annotation.type_annotation)
		} else if function.async {
			result.return_type = metadata_global("Promise")
		} else {
			result.return_type = MetadataType{kind = .Undefined}
		}
	case .Get, .Set:
		getter, setter := metadata_accessors(scope.plan.class, element)
		annotation: Maybe(^TSTypeAnnotation)
		params: []FunctionParameter
		if setter != nil {
			params = setter.params[:]
			if len(params) != 0 { annotation = metadata_param_annotation(params[0].pattern) }
		}
		if getter != nil && annotation == nil { annotation = getter.return_type }
		result.type = metadata_annotation(scope, annotation)
		result.params = metadata_params(scope, params)
	case .Constructor, .StaticBlock, .IndexSignature:
		unreachable()
	}
	return
}

metadata_function :: proc(element: ClassElement) -> ^FunctionExpression {
	if element.kind == .Field { return nil }
	value, present := element.value.?
	if !present || value == nil { return nil }
	function, _ := value^.(^FunctionExpression)
	return function
}

// The accessor type comes from the setter's parameter, else the getter's result.
metadata_accessors :: proc(
	class: ^ClassExpression, element: ^ClassElement) -> (getter, setter: ^FunctionExpression,
) {
	own := metadata_function(element^)
	if element.kind == .Get { getter = own } else { setter = own }
	for &other, index in class.body.body {
		if &other != element { continue }
		partner := legacy_accessor_partner(class, index)
		if partner < 0 { break }
		function := metadata_function(class.body.body[partner])
		if element.kind == .Get { setter = function } else { getter = function }
	}
	return
}

metadata_params :: proc(scope: ^MetadataScope, params: []FunctionParameter) -> []MetadataType {
	types := make([dynamic]MetadataType, 0, len(params), scope.cg.transform.allocator)
	for param, index in params {
		if id, ok := param.pattern.(^Identifier); ok && index == 0 && id.name == "this" { continue }
		append(&types, metadata_param(scope, param))
	}
	return types[:]
}

metadata_param :: proc(scope: ^MetadataScope, param: FunctionParameter) -> MetadataType {
	if rest, variadic := param.pattern.(^RestElement); variadic { return metadata_rest(scope, rest) }
	return metadata_annotation(scope, metadata_param_annotation(param.pattern))
}

metadata_param_annotation :: proc(pattern: Pattern) -> Maybe(^TSTypeAnnotation) {
	#partial switch node in pattern {
	case ^Identifier:    return node.type_annotation
	case ^ObjectPattern: return node.type_annotation
	case ^ArrayPattern:  return node.type_annotation
	}
	return nil
}

// A rest parameter records its element type: `...rest: T[]` or `Array<T>`.
metadata_rest :: proc(scope: ^MetadataScope, rest: ^RestElement) -> MetadataType {
	node, annotated := metadata_param_annotation(rest.argument).?
	if !annotated || node.type_annotation == nil { return METADATA_OBJECT }
	#partial switch type in node.type_annotation^ {
	case ^TSArrayType:
		return metadata_type(scope, type.element_type)
	case ^TSTypeReference:
		if arguments, generic := type.type_parameters.?; generic && len(arguments.params) != 0 {
			return metadata_type(scope, arguments.params[0])
		}
	}
	return METADATA_OBJECT
}

metadata_annotation :: proc(
	scope: ^MetadataScope, annotation: Maybe(^TSTypeAnnotation),
) -> MetadataType {
	node, annotated := annotation.?
	if !annotated || node == nil { return METADATA_OBJECT }
	return metadata_type(scope, node.type_annotation)
}

metadata_type :: proc(scope: ^MetadataScope, type: ^TSType) -> MetadataType {
	if type == nil { return METADATA_OBJECT }
	#partial switch node in type^ {
	case ^TSKeywordType:         return metadata_keyword(node.kind)
	case ^TSFunctionType, ^TSConstructorType: return metadata_global("Function")
	case ^TSArrayType, ^TSTupleType:          return metadata_global("Array")
	case ^TSTemplateLiteralType: return metadata_global("String")
	case ^TSParenthesizedType:   return metadata_type(scope, node.type_annotation)
	case ^TSLiteralType:         return metadata_literal(node.literal)
	case ^TSTypeReference:       return metadata_reference(scope, node.type_name)
	case ^TSUnionType:           return metadata_combine(scope, node.types[:], false)
	case ^TSIntersectionType:    return metadata_combine(scope, node.types[:], true)
	case ^TSConditionalType:
		return metadata_combine(scope, []^TSType{node.true_type, node.false_type}, false)
	case ^TSTypeOperator:
		if node.operator == "readonly" { return metadata_type(scope, node.type_annotation) }
	case ^TSTypePredicate:
		return MetadataType{kind = .Undefined} if node.asserts else metadata_global("Boolean")
	}
	return METADATA_OBJECT
}

metadata_keyword :: proc(kind: TSKeywordKind) -> MetadataType {
	switch kind {
	case .Void, .Undefined, .Never, .Null: return {kind = .Undefined}
	case .Boolean: return metadata_global("Boolean")
	case .String:  return metadata_global("String")
	case .Number:  return metadata_global("Number")
	case .BigInt:  return metadata_global("BigInt")
	case .Symbol:  return metadata_global("Symbol")
	case .Any, .Unknown, .Object, .This, .Intrinsic:
	}
	return METADATA_OBJECT
}

metadata_literal :: proc(literal: ^Expression) -> MetadataType {
	if literal == nil { return METADATA_OBJECT }
	#partial switch _ in literal^ {
	case ^StringLiteral, ^TemplateLiteral:  return metadata_global("String")
	case ^NumericLiteral, ^UnaryExpression: return metadata_global("Number")
	case ^BigIntLiteral:  return metadata_global("BigInt")
	case ^BooleanLiteral: return metadata_global("Boolean")
	case ^NullLiteral:    return {kind = .Undefined}
	}
	return METADATA_OBJECT
}

// TypeScript's rule for unions, intersections and conditional types: one
// constructor only when every constituent serializes to the same one.
metadata_combine :: proc(
	scope: ^MetadataScope, types: []^TSType, intersection: bool,
) -> MetadataType {
	result: Maybe(MetadataType)
	for type in types {
		constituent := type
		for constituent != nil {
			group, grouped := constituent^.(^TSParenthesizedType)
			if !grouped { break }
			constituent = group.type_annotation
		}
		if constituent == nil { return METADATA_OBJECT }
		if keyword, is_keyword := constituent^.(^TSKeywordType); is_keyword {
			#partial switch keyword.kind {
			case .Never:
				if intersection { return {kind = .Undefined} }
				continue
			case .Unknown:
				if !intersection { return METADATA_OBJECT }
				continue
			case .Any:
				return METADATA_OBJECT
			}
		}
		serialized := metadata_type(scope, constituent)
		if serialized.kind == .Global && serialized.name == "Object" { return METADATA_OBJECT }
		if previous, seen := result.?; seen {
			if !metadata_equal(scope.cg, previous, serialized) { return METADATA_OBJECT }
		} else {
			result = serialized
		}
	}
	return result.? or_else MetadataType{kind = .Undefined}
}

metadata_equal :: proc(cg: ^Codegen, left, right: MetadataType) -> bool {
	if left.kind != right.kind { return false }
	switch left.kind {
	case .Undefined: return true
	case .Global:    return left.name == right.name
	case .Guarded:
		a, b := loc_from_expr(left.reference), loc_from_expr(right.reference)
		return cg.source[a.start:a.end] == cg.source[b.start:b.end]
	}
	return false
}

metadata_reference :: proc(scope: ^MetadataScope, name: ^Expression) -> MetadataType {
	if name == nil { return METADATA_OBJECT }
	root := name
	segments := 1
	for {
		member, qualified := root^.(^MemberExpression)
		if !qualified { break }
		root = member.object
		segments += 1
	}
	id, plain := root^.(^Identifier)
	if !plain { return METADATA_OBJECT }
	for declaration in scope.type_params {
		params, generic := declaration.?
		if !generic { continue }
		for param in params.params {
			if param.name.name == id.name { return METADATA_OBJECT }
		}
	}
	kinds, type_only, symbol, found := metadata_lookup(transform_model(scope.cg), scope.scope, id.name)
	if found {
		if type_only || kinds - {.Interface, .TypeAlias} == {} { return METADATA_OBJECT }
		if segments == 1 {
			if .Class in kinds { return metadata_global(id.name) }
			if .Enum in kinds { return metadata_enum(scope.cg, symbol, "") }
		}
		// `Enum.Member` is the type of that one member.
		if member, dotted := name^.(^MemberExpression); dotted && segments == 2 && .Enum in kinds {
			if property, named := member.property^.(^Identifier); named && !member.computed {
				return metadata_enum(scope.cg, symbol, property.name)
			}
		}
	}
	// One binding for the guarded value, and one for each object read on the
	// way to a name with more than two segments.
	temps := make([]string, max(1, segments - 1), scope.cg.transform.allocator)
	for &temp in temps {
		temp = codegen_fresh_runtime_binding(scope.cg, "type")
		append(&scope.plan.temps, temp)
	}
	return {kind = .Guarded, reference = name, temps = temps}
}

// The innermost scope that declares the name decides, counting declarations
// that exist only as types. The value lookup of the semantic model skips those.
metadata_lookup :: proc(
	model: ^SemanticModel, start: ScopeId, name: string,
) -> (kinds: bit_set[SymbolKind; u16], type_only: bool, symbol: SymbolId, found: bool) {
	scope := start
	for _ in 0..<len(model.scopes) {
		candidates := [2]ScopeId{scope, model.namespace_exports[scope] or_else scope}
		type_only = true
		for candidate, index in candidates {
			if index == 1 && candidate == scope { break }
			for id in model.scopes[candidate].symbols {
				info := model.symbols[id]
				if info.name != name { continue }
				found = true
				kinds += info.kinds
				if .TypeOnly not_in info.flags { type_only = false }
				if info.kind == .Class || info.kind == .Enum || symbol == SYMBOL_UNRESOLVED { symbol = id }
			}
		}
		if found || scope == SCOPE_ROOT { return }
		scope = model.scopes[scope].parent
	}
	return
}

// Number when no member is a string, String when all are, otherwise Object.
// A member without an initializer, or with a computed one, is a number.
metadata_enum :: proc(cg: ^Codegen, symbol: SymbolId, only: string) -> MetadataType {
	strings, numbers := 0, 0
	for declaration in cg.transform.enums.declarations {
		if declaration.symbol != symbol { continue }
		for member in declaration.node.body.members {
			name, valid := enum_member_name(member.id)
			if only != "" && (!valid || name != only) { continue }
			textual := false
			if initializer, present := member.initializer.?; present && initializer != nil {
				#partial switch _ in codegen_runtime_expression(cg, initializer)^ {
				case ^StringLiteral, ^TemplateLiteral: textual = true
				}
			}
			if textual { strings += 1 } else { numbers += 1 }
		}
	}
	if strings == 0 { return metadata_global("Number") }
	if numbers == 0 { return metadata_global("String") }
	return METADATA_OBJECT
}

metadata_emit :: proc(cg: ^Codegen, metadata: MemberMetadata) {
	if type, present := metadata.type.?; present {
		metadata_emit_entry(cg, "design:type")
		metadata_emit_type(cg, type)
		cg_byte(cg, ')')
	}
	if params, present := metadata.params.?; present {
		metadata_emit_entry(cg, "design:paramtypes")
		cg_byte(cg, '[')
		for param, index in params {
			if index != 0 { cg_byte(cg, ','); cg_space(cg) }
			metadata_emit_type(cg, param)
		}
		cg_str(cg, "])")
	}
	if type, present := metadata.return_type.?; present {
		metadata_emit_entry(cg, "design:returntype")
		metadata_emit_type(cg, type)
		cg_byte(cg, ')')
	}
}

metadata_emit_entry :: proc(cg: ^Codegen, key: string) {
	cg_byte(cg, ',')
	cg_space(cg)
	cg_str(cg, transform_helper(cg, .Decorate_Metadata))
	cg_byte(cg, '(')
	gen_string_quoted(cg, key)
	cg_byte(cg, ',')
	cg_space(cg)
}

metadata_emit_type :: proc(cg: ^Codegen, type: MetadataType) {
	switch type.kind {
	case .Undefined: cg_str(cg, "void 0")
	case .Global:    cg_str(cg, type.name)
	case .Guarded:
		// typeof (t = typeof A !== "undefined" && A.B) === "function" ? t : Object
		outer := type.temps[0]
		cg_str(cg, "typeof (")
		cg_str(cg, outer)
		cg_infix_operator(cg, "=")
		metadata_emit_guard(cg, type.reference, type.temps[1:])
		cg_str(cg, ") === \"function\" ? ")
		cg_str(cg, outer)
		cg_str(cg, " : Object")
	}
}

// Reads a dotted name without throwing when any prefix is missing:
//     typeof A !== "undefined" && (t = A.B) !== void 0 && t.C
metadata_emit_guard :: proc(cg: ^Codegen, name: ^Expression, temps: []string) {
	segments := make([dynamic]string, 0, 4, context.temp_allocator)
	current := name
	for {
		member, qualified := current^.(^MemberExpression)
		if !qualified { break }
		append(&segments, member.property^.(^Identifier).name)
		current = member.object
	}
	root := current^.(^Identifier).name
	assert(len(temps) == max(0, len(segments) - 1))
	cg_str(cg, "typeof ")
	cg_str(cg, root)
	cg_str(cg, " !== \"undefined\" && ")
	object := root
	// Segments were collected from the last name to the first.
	for index := len(segments) - 1; index > 0; index -= 1 {
		temp := temps[len(segments) - 1 - index]
		cg_byte(cg, '(')
		cg_str(cg, temp)
		cg_infix_operator(cg, "=")
		cg_str(cg, object)
		cg_byte(cg, '.')
		cg_str(cg, segments[index])
		cg_str(cg, ") !== void 0 && ")
		object = temp
	}
	cg_str(cg, object)
	if len(segments) != 0 {
		cg_byte(cg, '.')
		cg_str(cg, segments[0])
	}
}
