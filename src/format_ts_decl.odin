package kessel

import "core:strings"

// TypeScript declarations: type aliases, interfaces, enums, namespaces and
// the import and export forms that only TypeScript has. Ports of Prettier's
// type-alias, interface, enum and module rules.

// A conditional type whose test names a generic type, as in
// `T extends Foo<infer U> ? U : never`.
@(private = "file")
format_conditional_has_generic_test :: proc(type: ^TSType) -> bool {
	inner := format_type_unwrap(type)
	if inner == nil {return false}
	conditional, is_conditional := inner^.(^TSConditionalType)
	if !is_conditional {return false}
	for operand in ([2]^TSType{conditional.check_type, conditional.extends_type}) {
		side := format_type_unwrap(operand)
		if side == nil {continue}
		#partial switch node in side^ {
		case ^TSTypeReference:
			if _, generic := node.type_parameters.?; generic {return true}
		case ^TSFunctionType:
			if _, generic := node.type_parameters.?; generic {return true}
		}
	}
	return false
}

// `type Name<T> = Type;`
format_type_alias :: proc(f: ^FormatContext, node: ^TSTypeAliasDeclaration) -> Doc {
	assert(format_path_at(f, 0).kind == .TS_Type_Alias)
	left := fc(
		f,
		ft(f, "declare ") if node.declare else nil,
		ft(f, "type "),
		ft(f, node.id.name),
		format_type_parameters(f, node.type_parameters),
	)
	layout := FormatAssignLayout.Fluid
	if format_conditional_has_generic_test(node.type_annotation) {
		layout = .Break_After_Operator
	} else if parameters, generic := node.type_parameters.?; generic && parameters != nil {
		// Several type parameters, one of them constrained or defaulted, break
		// before the type does.
		complex := false
		for param in parameters.params {
			_, constrained := param.constraint.?
			_, defaulted := param.default_.?
			complex = complex || constrained || defaulted
		}
		if complex && len(parameters.params) > 1 {layout = .Break_Lhs}
	}
	right := format_type(f, node.type_annotation, .Type_Annotation)
	return fc(f, format_assignment_render(f, layout, left, ft(f, " ="), right), ft(f, ";"))
}

// One `A.B<T>` of an `extends` or `implements` clause.
@(private = "file")
format_heritage :: proc(f: ^FormatContext, item: ^TSInterfaceHeritage) -> Doc {
	// Prettier prints the name as the expression it is, so a dotted name
	// that does not fit breaks like a member access.
	name := format_expr(f, item.expression, .Expression)
	return fc(f, name, format_type_arguments(f, item.type_parameters))
}

// True for a clause that names one dotted type without type arguments. Such
// a clause may move to a line of its own.
format_heritage_is_member :: proc(items: []TSInterfaceHeritage) -> bool {
	if len(items) == 0 {return false}
	if _, generic := items[0].type_parameters.?; generic {return false}
	return format_is_member(items[0].expression)
}

// An `extends` or `implements` clause of an interface or a class.
// `multiple` says that the declaration has more than one inherited type in
// all, and `indent_only` that the clauses indent as a group of their own.
format_heritage_clause :: proc(
	f: ^FormatContext,
	keyword: string,
	items: []TSInterfaceHeritage,
	multiple, indent_only: bool,
) -> Doc {
	if len(items) == 0 {return nil}
	printed := make([]Doc, len(items), f.alloc)
	for &item, index in items {printed[index] = format_heritage(f, &item)}
	list := doc_join(f, fc(f, ft(f, ","), doc_line()), printed)
	if multiple {
		return fc(f, doc_line(), ft(f, keyword), fg(f, fi(f, doc_line(), list)))
	}
	clause := fc(f, ft(f, keyword), ft(f, " "), list)
	if indent_only {return fc(f, doc_line(), doc_group(f, clause))}
	return fc(f, ft(f, " "), clause)
}

// `interface Name<T> extends A, B { … }`
format_interface :: proc(f: ^FormatContext, node: ^TSInterfaceDeclaration) -> Doc {
	assert(format_path_at(f, 0).kind == .TS_Interface)
	name := fc(f, ft(f, " "), ft(f, node.id.name), format_type_parameters(f, node.type_parameters))
	multiple := len(node.extends) > 1
	indent_only := multiple || format_heritage_is_member(node.extends[:])
	extends := format_heritage_clause(f, "extends", node.extends[:], multiple, indent_only)
	head := fc(f, name, extends)
	if indent_only {head = fg(f, name, doc_indent(f, extends))}
	return fc(
		f,
		ft(f, "declare ") if node.declare else nil,
		ft(f, "interface"),
		head,
		ft(f, " "),
		format_interface_body(f, &node.body),
	)
}

// `enum Name { A, B = 1 }`. The members always print one per line.
format_enum :: proc(f: ^FormatContext, node: ^TSEnumDeclaration) -> Doc {
	assert(format_path_at(f, 0).kind == .TS_Enum)
	body := node.body
	if !format_is_delimited(f, body.loc, '{', '}') {return format_fail(f)}
	count := len(body.members)
	starts := make([]u32, count, f.alloc)
	ends := make([]u32, count, f.alloc)
	for member, index in body.members {
		starts[index], ends[index] = member.loc.start, member.loc.end
	}
	bounds := FormatListBounds{open = body.loc.start + 1, close = body.loc.end - 1}
	comments, dangling := format_list_comments(f, bounds, starts, ends)
	// Prettier's layout of comments in an empty enum is not ported.
	if dangling != nil {return format_fail(f)}
	items := make([]FormatObjectItem, count, f.alloc)
	for &member, index in body.members {
		printed := format_with_comments(f, comments[index], format_enum_member(f, &member))
		items[index] = {printed, member.loc.end}
	}
	return fc(
		f,
		ft(f, "declare ") if node.declare else nil,
		ft(f, "const ") if node.const_ else nil,
		ft(f, "enum "),
		ft(f, node.id.name),
		ft(f, " "),
		format_object_body(f, items, true, true, false),
	)
}

@(private = "file")
format_enum_member :: proc(f: ^FormatContext, member: ^TSEnumMember) -> Doc {
	if member.id == nil {return format_fail(f)}
	name: Doc
	#partial switch id in member.id^ {
	case ^Identifier:
		if id.has_escape {return format_fail(f)}
		name = ft(f, id.name)
	case ^StringLiteral:
		name = format_string_literal(f, id)
	case:
		return format_fail(f)
	}
	initializer, initialized := member.initializer.?
	if !initialized || initializer == nil {return name}
	return fc(f, name, ft(f, " = "), format_expr(f, initializer, .Value))
}

// `namespace A.B { … }`, `module "name" { … }` and `declare global { … }`.
// The parser nests one declaration per dotted name.
format_ts_module :: proc(f: ^FormatContext, node: ^TSModuleDeclaration) -> Doc {
	assert(format_path_at(f, 0).kind == .TS_Module)
	name := strings.builder_make(f.alloc)
	innermost := node
	literal: ^StringLiteral
	for _ in 0 ..< FORMAT_DEPTH_MAX {
		if innermost.id == nil {return format_fail(f)}
		#partial switch id in innermost.id^ {
		case ^Identifier:
			if id.has_escape {return format_fail(f)}
			strings.write_string(&name, id.name)
		case ^StringLiteral:
			if innermost != node {return format_fail(f)}
			literal = id
		case:
			return format_fail(f)
		}
		body, has_body := innermost.body.?
		if !has_body || body == nil {break}
		nested, is_nested := body^.(^TSModuleDeclaration)
		if !is_nested || nested == nil {break}
		if literal != nil {return format_fail(f)}
		strings.write_byte(&name, '.')
		innermost = nested
	}
	keyword: string
	switch node.kind {
	case .Namespace: keyword = "namespace "
	case .Module: keyword = "module "
	case .Global: keyword = ""
	}
	id := ft(f, strings.to_string(name))
	if literal != nil {id = format_string_literal(f, literal)}
	head := fc(f, ft(f, "declare ") if node.declare else nil, ft(f, keyword), id)
	body, has_body := innermost.body.?
	if !has_body || body == nil {return fc(f, head, ft(f, ";"))}
	block, is_block := body^.(^TSModuleBlock)
	// A dotted name too deep to follow leaves a declaration here.
	if !is_block || block == nil {return format_fail(f)}
	if !format_path_push(f, {kind = .Block, key = .Body, node = block}) {return nil}
	defer format_path_pop(f)
	// TypeScript reads a prologue in a namespace body as directives.
	return fc(f, head, ft(f, " "), fg(f, format_block(f, block.body[:], true, block.loc)))
}

// `import a = b.c;` and `import a = require("m");`
format_import_equals :: proc(f: ^FormatContext, node: ^TSImportEqualsDeclaration) -> Doc {
	if node.id.has_escape {return format_fail(f)}
	reference: Doc
	switch target in node.module_reference {
	case ^Expression:
		reference = format_type_name(f, target)
	case ^TSExternalModuleReference:
		if target == nil || target.expression == nil {return format_fail(f)}
		path := format_string_literal(f, target.expression)
		reference = fc(f, ft(f, "require("), path, ft(f, ")"))
	}
	if reference == nil {return format_fail(f)}
	return fc(
		f,
		ft(f, "import "),
		ft(f, "type ") if node.import_kind == .Type else nil,
		ft(f, node.id.name),
		ft(f, " = "),
		reference,
		ft(f, ";"),
	)
}

// The statements that exist only in TypeScript. The path holds the
// statement's entry.
format_ts_statement :: proc(f: ^FormatContext, stmt: ^Statement) -> Doc {
	#partial switch node in stmt^ {
	case ^TSInterfaceDeclaration:
		return format_interface(f, node)
	case ^TSTypeAliasDeclaration:
		return format_type_alias(f, node)
	case ^TSEnumDeclaration:
		return format_enum(f, node)
	case ^TSModuleDeclaration:
		return format_ts_module(f, node)
	case ^TSImportEqualsDeclaration:
		return format_import_equals(f, node)
	case ^TSExportAssignment:
		value := format_expr(f, node.expression, .Expression)
		return fc(f, ft(f, "export = "), value, ft(f, ";"))
	case ^TSNamespaceExportDeclaration:
		if node.id.has_escape {return format_fail(f)}
		return fc(f, ft(f, "export as namespace "), ft(f, node.id.name), ft(f, ";"))
	}
	return format_fail(f)
}

// The same declarations behind `export`.
format_ts_declaration :: proc(f: ^FormatContext, declaration: ^Declaration) -> Doc {
	kind: FormatNodeKind
	#partial switch _ in declaration^ {
	case ^TSInterfaceDeclaration: kind = .TS_Interface
	case ^TSTypeAliasDeclaration: kind = .TS_Type_Alias
	case ^TSEnumDeclaration: kind = .TS_Enum
	case ^TSModuleDeclaration: kind = .TS_Module
	case ^TSImportEqualsDeclaration: kind = .Other
	case: return format_fail(f)
	}
	if !format_path_push(f, {kind = kind, key = .Declaration}) {return nil}
	defer format_path_pop(f)
	#partial switch node in declaration^ {
	case ^TSInterfaceDeclaration: return format_interface(f, node)
	case ^TSTypeAliasDeclaration: return format_type_alias(f, node)
	case ^TSEnumDeclaration: return format_enum(f, node)
	case ^TSModuleDeclaration: return format_ts_module(f, node)
	case ^TSImportEqualsDeclaration: return format_import_equals(f, node)
	}
	return format_fail(f)
}
