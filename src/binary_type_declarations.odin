package kessel

BIN_SIGNATURE_KIND := [TSMethodSignatureKind]string{.Method = "method", .Get = "get", .Set = "set"}
BIN_MODULE_KIND := [TSModuleKind]string{.Namespace = "namespace", .Module = "module", .Global = "global"}

bin_field_members :: proc(be: ^BinaryEmitter, key: string, members: []^TSSignature) {
	bin_field_array(be, key, len(members))
	for sig in members { bin_emit_signature(be, sig) }
}

bin_emit_signature :: proc(be: ^BinaryEmitter, sig: ^TSSignature) {
	switch v in sig^ {
	case TSPropertySignature:
		bin_record(be, "TSPropertySignature", v.loc)
		bin_field_expr(be, "key", v.key)
		bin_field_bool(be, "computed", v.computed)
		bin_field_bool(be, "optional", v.optional)
		bin_field_bool(be, "readonly", v.readonly)
		bin_field_annotation(be, "typeAnnotation", v.type_annotation)
		bin_field(be, .Null, "accessibility")
		bin_field_bool(be, "static", false)
	case TSMethodSignature:
		bin_record(be, "TSMethodSignature", v.loc)
		bin_field_expr(be, "key", v.key)
		bin_field_bool(be, "computed", v.computed)
		bin_field_bool(be, "optional", v.optional)
		bin_field_text(be, "kind", BIN_SIGNATURE_KIND[v.kind])
		bin_field_generics(be, v.type_parameters)
		bin_field_ts_params(be, "params", v.params[:])
		bin_field_annotation(be, "returnType", v.return_type)
		bin_field(be, .Null, "accessibility")
		bin_field_bool(be, "readonly", false)
		bin_field_bool(be, "static", false)
	case TSCallSignatureDeclaration:
		bin_record(be, "TSCallSignatureDeclaration", v.loc)
		bin_field_generics(be, v.type_parameters)
		bin_field_ts_params(be, "params", v.params[:])
		bin_field_annotation(be, "returnType", v.return_type)
	case TSConstructSignatureDeclaration:
		bin_record(be, "TSConstructSignatureDeclaration", v.loc)
		bin_field_generics(be, v.type_parameters)
		bin_field_ts_params(be, "params", v.params[:])
		bin_field_annotation(be, "returnType", v.return_type)
	case TSIndexSignature:
		bin_record(be, "TSIndexSignature", v.loc)
		bin_field_ts_params(be, "parameters", v.parameters[:])
		bin_field_annotation(be, "typeAnnotation", v.type_annotation)
		bin_field_bool(be, "readonly", v.readonly)
		bin_field_bool(be, "static", v.static_)
	}
	bin_fields_end(be)
}

bin_field_ts_params :: proc(be: ^BinaryEmitter, key: string, params: []TSFunctionParam) {
	bin_field_array(be, key, len(params))
	for &param in params { bin_emit_pattern(be, param.pattern, &param) }
}

bin_type_interface :: proc(be: ^BinaryEmitter, decl: ^TSInterfaceDeclaration) {
	bin_record(be, "TSInterfaceDeclaration", decl.loc)
	bin_field(be, .Node, "id")
	bin_type_identifier(be, decl.id.loc, decl.id.name)
	bin_field_generics(be, decl.type_parameters)
	bin_field_array(be, "extends", len(decl.extends))
	for base in decl.extends {
		bin_record(be, "TSInterfaceHeritage", base.loc)
		bin_field_expr(be, "expression", base.expression)
		bin_field_type_args(be, base.type_parameters)
		bin_fields_end(be)
	}
	bin_field(be, .Node, "body")
	bin_record(be, "TSInterfaceBody", decl.body.loc)
	bin_field_members(be, "body", decl.body.body[:])
	bin_fields_end(be)
	bin_field_bool(be, "declare", decl.declare)
	bin_fields_end(be)
}

bin_type_alias :: proc(be: ^BinaryEmitter, decl: ^TSTypeAliasDeclaration) {
	bin_record(be, "TSTypeAliasDeclaration", decl.loc)
	bin_field(be, .Node, "id")
	bin_type_identifier(be, decl.id.loc, decl.id.name)
	bin_field_generics(be, decl.type_parameters)
	bin_field_type(be, "typeAnnotation", decl.type_annotation)
	bin_field_bool(be, "declare", decl.declare)
	bin_fields_end(be)
}

bin_type_enum :: proc(be: ^BinaryEmitter, decl: ^TSEnumDeclaration) {
	bin_record(be, "TSEnumDeclaration", decl.loc)
	bin_field(be, .Node, "id")
	bin_type_identifier(be, decl.id.loc, decl.id.name)
	bin_field(be, .Node, "body")
	bin_record(be, "TSEnumBody", decl.body.loc)
	bin_field_array(be, "members", len(decl.body.members))
	for member in decl.body.members {
		bin_record(be, "TSEnumMember", member.loc)
		bin_field_expr(be, "id", member.id)
		bin_field_expr(be, "initializer", member.initializer.? or_else nil)
		bin_field_bool(be, "computed", false)
		bin_fields_end(be)
	}
	bin_fields_end(be)
	bin_field_bool(be, "declare", decl.declare)
	bin_field_bool(be, "const", decl.const_)
	bin_fields_end(be)
}

bin_type_module :: proc(be: ^BinaryEmitter, decl: ^TSModuleDeclaration) {
	bin_record(be, "TSModuleDeclaration", decl.loc)
	bin_field_bool(be, "declare", decl.declare)
	bin_field_bool(be, "global", decl.global)
	bin_field_text(be, "kind", BIN_MODULE_KIND[decl.kind])
	bin_field(be, .Node, "id")
	chain: [dynamic]^Expression
	defer delete(chain)
	node := decl
	for {
		append(&chain, node.id)
		body, ok := node.body.?
		if !ok { break }
		nested, dotted := body^.(^TSModuleDeclaration)
		if !dotted { break }
		node = nested
	}
	first := get_expression_loc(chain[0]).start
	for i := len(chain) - 1; i > 0; i -= 1 {
		bin_record(be, "TSQualifiedName", {first, get_expression_loc(chain[i]).end})
		bin_field(be, .Node, "left")
	}
	bin_emit_expression(be, chain[0])
	for i := 1; i < len(chain); i += 1 {
		bin_field_expr(be, "right", chain[i])
		bin_fields_end(be)
	}
	if body, ok := node.body.?; ok {
		block := body^.(^TSModuleBlock)
		bin_field(be, .Node, "body")
		bin_record(be, "TSModuleBlock", block.loc)
		bin_field_array(be, "body", len(block.body))
		for stmt in block.body { bin_emit_statement(be, stmt) }
		bin_fields_end(be)
	} else { bin_field(be, .Null, "body") }
	bin_fields_end(be)
}

bin_type_import_equals :: proc(be: ^BinaryEmitter, decl: ^TSImportEqualsDeclaration) {
	bin_record(be, "TSImportEqualsDeclaration", decl.loc)
	bin_field(be, .Node, "id")
	bin_type_identifier(be, decl.id.loc, decl.id.name)
	bin_field_text(be, "importKind", "type" if decl.import_kind == .Type else "value")
	switch ref in decl.module_reference {
	case ^Expression: bin_field_type_name(be, "moduleReference", ref)
	case ^TSExternalModuleReference:
		bin_field(be, .Node, "moduleReference")
		bin_record(be, "TSExternalModuleReference", ref.loc)
		bin_field(be, .Node, "expression")
		bin_emit_string_child(be, ref.expression.loc, ref.expression.value, ref.expression.raw)
		bin_fields_end(be)
	}
	bin_fields_end(be)
}

// A rest parameter owns its type annotation. Ordinary parameters store it on
// the identifier. Both parser representations occur in declaration signatures.
bin_type_rest :: proc(be: ^BinaryEmitter, rest: ^RestElement, annotation: Maybe(^TSTypeAnnotation), loc: Loc) {
	bin_record(be, "RestElement", loc)
	bin_field(be, .Node, "argument")
	ann := annotation
	if id, plain := rest.argument.(^Identifier); plain {
		if ann == nil { ann = id.type_annotation }
		name_loc := id.loc
		if ty, typed := ann.?; typed && name_loc.end > ty.loc.start {
			// The parser extends the binding through its annotation. The
			// identifier child retains just its original token, including escapes.
			raw := be.source[id.loc.start:ty.loc.start]
			if len(raw) >= len(id.name) && raw[:len(id.name)] == id.name {
				name_loc.end = name_loc.start + u32(len(id.name))
			} else {
				lexer: Lexer
				init_lexer(&lexer, raw, be.scratch, .Module)
				name_loc.end = name_loc.start + u32(lex_token(&lexer).end)
			}
		}
		bin_type_identifier(be, name_loc, id.name)
	} else { bin_emit_pattern(be, rest.argument) }
	bin_field_annotation(be, "typeAnnotation", ann)
	bin_field_bool(be, "optional", false)
	bin_field_array(be, "decorators", 0)
	bin_field(be, .Null, "value")
	bin_fields_end(be)
}

bin_type_function :: proc(be: ^BinaryEmitter, name: string, fn: ^FunctionExpression) {
	bin_record(be, name, fn.loc)
	if id, ok := fn.id.?; ok {
		bin_field(be, .Node, "id")
		bin_type_identifier(be, id.loc, id.name)
	} else { bin_field(be, .Null, "id") }
	bin_field_bool(be, "async", fn.async)
	bin_field_bool(be, "generator", fn.generator)
	bin_field_bool(be, "expression", false)
	bin_field_bool(be, "declare", fn.declare)
	bin_field_generics(be, fn.type_parameters)
	bin_field_array(be, "params", len(fn.params))
	for param in fn.params { bin_type_function_param(be, param) }
	bin_field_annotation(be, "returnType", fn.return_type)
	if fn.no_body { bin_field(be, .Null, "body") } else {
		bin_field(be, .Node, "body")
		bin_emit_function_body(be, fn.body)
	}
	bin_fields_end(be)
}

bin_type_function_param :: proc(be: ^BinaryEmitter, param: FunctionParameter) {
	property := param.accessibility != .None || param.readonly || param.override_
	if property {
		bin_record(be, "TSParameterProperty", {param.modifier_start, param.loc.end})
		access := ([4]string{"", "public", "private", "protected"})
		if param.accessibility == .None { bin_field(be, .Null, "accessibility") } else {
			bin_field_text(be, "accessibility", access[int(param.accessibility)])
		}
		bin_field_bool(be, "readonly", param.readonly)
		bin_field_bool(be, "override", param.override_)
		bin_field_array(be, "decorators", 0)
		bin_field(be, .Node, "parameter")
	}
	if def, ok := param.default_val.?; ok && def != nil {
		bin_node_header(be, .AssignmentPattern, {get_pattern_loc(param.pattern).start, get_expression_loc(def).end})
		bin_emit_pattern(be, param.pattern)
		bin_emit_expression(be, def)
	} else { bin_emit_pattern(be, param.pattern) }
	if property { bin_fields_end(be) }
}

// Prefix records attach optional TypeScript fields to an existing fixed-layout
// node. The base record keeps its original representation and node depth.
bin_extra :: proc(be: ^BinaryEmitter) {
	be.version = max(be.version, BINARY_VERSION_TYPES)
	bw_u8(be, u8(BinNodeType.TypedPrefix))
}

bin_field_decorators :: proc(be: ^BinaryEmitter, decorators: []Decorator) {
	bin_field_array(be, "decorators", len(decorators))
	for deco in decorators {
		bin_record(be, "Decorator", deco.loc)
		bin_field_expr(be, "expression", deco.expression)
		bin_fields_end(be)
	}
}

bin_type_class_fields :: proc(be: ^BinaryEmitter, c: ^ClassExpression) {
	if c.type_parameters == nil && c.super_type_arguments == nil && len(c.implements) == 0 && !c.abstract && !c.declare && len(c.decorators) == 0 { return }
	bin_extra(be)
	bin_field_generics(be, c.type_parameters)
	bin_field_type_args(be, c.super_type_arguments, "superTypeArguments")
	bin_field_bool(be, "declare", c.declare)
	bin_field_bool(be, "abstract", c.abstract)
	bin_field_decorators(be, c.decorators[:])
	bin_field_array(be, "implements", len(c.implements))
	for base in c.implements {
		bin_record(be, "TSClassImplements", base.loc)
		bin_field_expr(be, "expression", base.expression)
		bin_field_type_args(be, base.type_parameters)
		bin_fields_end(be)
	}
	bin_fields_end(be)
}

bin_type_class_element :: proc(be: ^BinaryEmitter, el: ClassElement) {
	name := "MethodDefinition"
	if el.kind == .Field {
		name = "PropertyDefinition"
		if el.is_accessor { name = "AccessorProperty" }
		if el.abstract { name = "TSAbstractAccessorProperty" if el.is_accessor else "TSAbstractPropertyDefinition" }
	} else if el.abstract { name = "TSAbstractMethodDefinition" }
	bin_record(be, name, el.loc)
	bin_field_expr(be, "key", el.key)
	bin_field_expr(be, "value", el.value.? or_else nil)
	bin_field_decorators(be, el.decorators[:])
	bin_field_bool(be, "computed", el.computed)
	bin_field_bool(be, "static", el.static)
	bin_field_bool(be, "optional", el.optional)
	bin_field_bool(be, "override", el.override_)
	access := [4]string{"", "public", "private", "protected"}
	if el.accessibility == .None { bin_field(be, .Null, "accessibility") } else {
		bin_field_text(be, "accessibility", access[int(el.accessibility)])
	}
	if el.kind == .Field {
		bin_field_bool(be, "readonly", el.readonly)
		bin_field_bool(be, "declare", el.declare)
		bin_field_bool(be, "definite", el.definite)
		bin_field_annotation(be, "typeAnnotation", el.typing.annotation)
	} else {
		kinds := [ClassElementKind]string{.Method="method", .Get="get", .Set="set", .Constructor="constructor", .Field="", .StaticBlock="", .IndexSignature=""}
		bin_field_text(be, "kind", kinds[el.kind])
	}
	bin_fields_end(be)
}
