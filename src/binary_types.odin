package kessel

// TypeScript nodes share the native string table and byte offsets with the
// fixed-layout JavaScript records. Each field declares its wire representation.
BinaryField :: enum u8 { End, Node, Nodes, Text, Bool, Null }

bin_record :: proc(be: ^BinaryEmitter, name: string, loc: Loc) {
	be.version = max(be.version, BINARY_VERSION_TYPES)
	bin_node_header(be, .TypedRecord, loc)
	bw_string_ref(be, name)
}

bin_field :: proc(be: ^BinaryEmitter, kind: BinaryField, key: string) {
	bw_u8(be, u8(kind))
	bw_string_ref(be, key)
}

bin_fields_end :: proc(be: ^BinaryEmitter) { bw_u8(be, u8(BinaryField.End)) }

bin_field_text :: proc(be: ^BinaryEmitter, key, value: string) {
	bin_field(be, .Text, key)
	bw_string_ref(be, value)
}

bin_field_bool :: proc(be: ^BinaryEmitter, key: string, value: bool) {
	bin_field(be, .Bool, key)
	bw_bool(be, value)
}

bin_field_array :: proc(be: ^BinaryEmitter, key: string, count: int) {
	bin_field(be, .Nodes, key)
	bw_u32(be, u32(count))
}

bin_type_identifier :: proc(be: ^BinaryEmitter, loc: Loc, name: string, annotation: Maybe(^TSTypeAnnotation) = nil, optional := false) {
	bin_record(be, "Identifier", loc)
	bin_field_text(be, "name", name)
	bin_field_bool(be, "optional", optional)
	bin_field_array(be, "decorators", 0)
	bin_field_annotation(be, "typeAnnotation", annotation)
	bin_fields_end(be)
}

bin_field_annotation :: proc(be: ^BinaryEmitter, key: string, annotation: Maybe(^TSTypeAnnotation)) {
	ann, ok := annotation.?
	if !ok || ann == nil { bin_field(be, .Null, key); return }
	bin_field(be, .Node, key)
	bin_record(be, "TSTypeAnnotation", ann.loc)
	bin_field_type(be, "typeAnnotation", ann.type_annotation)
	bin_fields_end(be)
}

bin_field_type :: proc(be: ^BinaryEmitter, key: string, node: ^TSType) {
	if node == nil { bin_field(be, .Null, key); return }
	bin_field(be, .Node, key)
	bin_type(be, node)
}

bin_field_type_list :: proc(be: ^BinaryEmitter, key: string, types: []^TSType) {
	bin_field_array(be, key, len(types))
	for node in types { bin_type(be, node) }
}

bin_field_expr :: proc(be: ^BinaryEmitter, key: string, value: ^Expression) {
	if value == nil { bin_field(be, .Null, key); return }
	bin_field(be, .Node, key)
	bin_emit_expression(be, value)
}

bin_field_type_name :: proc(be: ^BinaryEmitter, key: string, expr: ^Expression) {
	if expr == nil { bin_field(be, .Null, key); return }
	bin_field(be, .Node, key)
	#partial switch name in expr^ {
	case ^Identifier: bin_type_identifier(be, name.loc, name.name)
	case ^MemberExpression:
		bin_record(be, "TSQualifiedName", name.loc)
		bin_field_type_name(be, "left", name.object)
		bin_field_type_name(be, "right", name.property)
		bin_fields_end(be)
	case: bin_emit_expression(be, expr)
	}
}

bin_field_generics :: proc(be: ^BinaryEmitter, params: Maybe(^TSTypeParameterDeclaration)) {
	decl, ok := params.?
	if !ok { bin_field(be, .Null, "typeParameters"); return }
	bin_field(be, .Node, "typeParameters")
	bin_record(be, "TSTypeParameterDeclaration", decl.loc)
	bin_field_array(be, "params", len(decl.params))
	for param in decl.params { bin_type_parameter(be, param) }
	bin_fields_end(be)
}

bin_type_parameter :: proc(be: ^BinaryEmitter, param: TSTypeParameter) {
	bin_record(be, "TSTypeParameter", param.loc)
	bin_field(be, .Node, "name")
	bin_type_identifier(be, param.name.loc, param.name.name)
	bin_field_type(be, "constraint", param.constraint.? or_else nil)
	bin_field_type(be, "default", param.default_.? or_else nil)
	bin_field_bool(be, "in", param.in_)
	bin_field_bool(be, "out", param.out)
	bin_field_bool(be, "const", param.const_)
	bin_fields_end(be)
}

bin_field_type_args :: proc(be: ^BinaryEmitter, args: Maybe(^TSTypeParameterInstantiation), key := "typeArguments") {
	v, ok := args.?
	if !ok { bin_field(be, .Null, key); return }
	bin_field(be, .Node, key)
	bin_record(be, "TSTypeParameterInstantiation", v.loc)
	bin_field_type_list(be, "params", v.params[:])
	bin_fields_end(be)
}

bin_field_modifier :: proc(be: ^BinaryEmitter, key: string, modifier: TSMappedTypeModifier) {
	switch modifier {
	case .None:
		if key == "optional" { bin_field_bool(be, key, false) } else { bin_field(be, .Null, key) }
	case .True: bin_field_bool(be, key, true)
	case .Plus: bin_field_text(be, key, "+")
	case .Minus: bin_field_text(be, key, "-")
	}
}

bin_type :: proc(be: ^BinaryEmitter, node: ^TSType) {
	if node == nil { bw_u8(be, u8(BinValType.NullNode)); return }
	switch t in node^ {
	case ^TSKeywordType: bin_record(be, TS_KEYWORD_ESTREE_TYPE[t.kind], t.loc)
	case ^TSTypeReference:
		bin_record(be, "TSTypeReference", t.loc)
		bin_field_type_name(be, "typeName", t.type_name)
		bin_field_type_args(be, t.type_parameters)
	case ^TSUnionType:
		bin_record(be, "TSUnionType", t.loc)
		bin_field_type_list(be, "types", t.types[:])
	case ^TSIntersectionType:
		bin_record(be, "TSIntersectionType", t.loc)
		bin_field_type_list(be, "types", t.types[:])
	case ^TSArrayType:
		bin_record(be, "TSArrayType", t.loc)
		bin_field_type(be, "elementType", t.element_type)
	case ^TSTupleType:
		bin_record(be, "TSTupleType", t.loc)
		bin_field_type_list(be, "elementTypes", t.element_types[:])
	case ^TSFunctionType:
		bin_record(be, "TSFunctionType", t.loc)
		bin_field_generics(be, t.type_parameters)
		bin_field_ts_params(be, "params", t.params[:])
		bin_field_annotation(be, "returnType", t.return_type)
	case ^TSConstructorType:
		bin_record(be, "TSConstructorType", t.loc)
		bin_field_generics(be, t.type_parameters)
		bin_field_ts_params(be, "params", t.params[:])
		bin_field_annotation(be, "returnType", t.return_type)
		bin_field_bool(be, "abstract", t.abstract_)
	case ^TSTypeLiteral:
		bin_record(be, "TSTypeLiteral", t.loc)
		bin_field_members(be, "members", t.members[:])
	case ^TSConditionalType:
		bin_record(be, "TSConditionalType", t.loc)
		bin_field_type(be, "checkType", t.check_type)
		bin_field_type(be, "extendsType", t.extends_type)
		bin_field_type(be, "trueType", t.true_type)
		bin_field_type(be, "falseType", t.false_type)
	case ^TSInferType:
		bin_record(be, "TSInferType", t.loc)
		bin_field(be, .Node, "typeParameter")
		bin_type_parameter(be, t.type_parameter)
	case ^TSTypeQuery:
		bin_record(be, "TSTypeQuery", t.loc)
		bin_field_type_name(be, "exprName", t.expr_name)
		bin_field_type_args(be, t.type_parameters)
	case ^TSIndexedAccessType:
		bin_record(be, "TSIndexedAccessType", t.loc)
		bin_field_type(be, "objectType", t.object_type)
		bin_field_type(be, "indexType", t.index_type)
	case ^TSMappedType, ^TSTypeOperator, ^TSLiteralType, ^TSTemplateLiteralType, ^TSParenthesizedType, ^TSOptionalType, ^TSRestType, ^TSNamedTupleMember, ^TSTypePredicate, ^TSImportType:
		bin_type_other(be, node)
	}
	bin_fields_end(be)
}

bin_type_other :: proc(be: ^BinaryEmitter, node: ^TSType) {
	#partial switch t in node^ {
	case ^TSMappedType:
		bin_record(be, "TSMappedType", t.loc)
		bin_field(be, .Node, "key")
		bin_type_identifier(be, t.type_parameter.name.loc, t.type_parameter.name.name)
		bin_field_type(be, "constraint", t.type_parameter.constraint.? or_else nil)
		bin_field_type(be, "nameType", t.name_type.? or_else nil)
		bin_field_type(be, "typeAnnotation", t.type_annotation.? or_else nil)
		bin_field_modifier(be, "optional", t.optional)
		bin_field_modifier(be, "readonly", t.readonly)
	case ^TSTypeOperator:
		bin_record(be, "TSTypeOperator", t.loc)
		bin_field_text(be, "operator", t.operator)
		bin_field_type(be, "typeAnnotation", t.type_annotation)
	case ^TSLiteralType:
		bin_record(be, "TSLiteralType", t.loc)
		bin_field_expr(be, "literal", t.literal)
	case ^TSTemplateLiteralType:
		bin_record(be, "TSTemplateLiteralType", t.loc)
		bin_field_array(be, "quasis", len(t.quasis))
		for q in t.quasis { bin_template_element(be, q) }
		bin_field_type_list(be, "types", t.types[:])
	case ^TSParenthesizedType:
		bin_record(be, "TSParenthesizedType", t.loc)
		bin_field_type(be, "typeAnnotation", t.type_annotation)
	case ^TSOptionalType:
		bin_record(be, "TSOptionalType", t.loc)
		bin_field_type(be, "typeAnnotation", t.type_annotation)
	case ^TSRestType:
		bin_record(be, "TSRestType", t.loc)
		bin_field_type(be, "typeAnnotation", t.type_annotation)
	case ^TSNamedTupleMember:
		bin_record(be, "TSNamedTupleMember", t.loc)
		bin_field(be, .Node, "label")
		bin_type_identifier(be, t.label.loc, t.label.name)
		bin_field_bool(be, "optional", t.optional)
		bin_field_type(be, "elementType", t.element_type)
	case ^TSTypePredicate:
		bin_record(be, "TSTypePredicate", t.loc)
		if id, named := t.parameter_name^.(^Identifier); named && id.name == "this" {
			bin_field(be, .Node, "parameterName")
			bin_record(be, "TSThisType", id.loc)
			bin_fields_end(be)
		} else { bin_field_type_name(be, "parameterName", t.parameter_name) }
		bin_field_annotation(be, "typeAnnotation", t.type_annotation)
		bin_field_bool(be, "asserts", t.asserts)
	case ^TSImportType:
		bin_record(be, "TSImportType", t.loc)
		if arg, literal := t.argument^.(^TSLiteralType); literal {
			bin_field_expr(be, "source", arg.literal)
		} else { bin_field_type(be, "source", t.argument) }
		bin_field(be, .Null, "options")
		bin_field_type_name(be, "qualifier", t.qualifier.? or_else nil)
		bin_field_type_args(be, t.type_parameters)
	case: unreachable()
	}
}
