package kessel

// A numeric accessor and a quoted accessor can bind the same property. Retain
// the numeric syntax when either declaration supplies it. Negative keys need quotes.
@(private)
dts_print_accessor_name :: proc(cg: ^Codegen, name: string, numeric: bool) {
	if numeric && len(name) > 0 && name[0] != '-' {
		cg_str(cg, name)
	} else {
		dts_print_object_key(cg, name)
	}
}

DeclarationAccessorTypeRelation :: enum { Same, Different, Unresolved }
DeclarationIntrinsicTypes :: struct {
	keywords: bit_set[TSKeywordKind; u16],
	booleans: bit_set[enum { True, False }; u8],
}

@(private)
dts_setter_annotation :: proc(pattern: Pattern) -> Maybe(^TSTypeAnnotation) {
	pattern := pattern
	if assignment, ok := pattern.(^AssignmentPattern); ok { pattern = assignment.left }
	#partial switch binding in pattern {
	case ^Identifier: return binding.type_annotation
	case ^ObjectPattern: return binding.type_annotation
	case ^ArrayPattern: return binding.type_annotation
	}
	return nil
}

// An annotated setter may accept a different type from the one the getter
// returns. Collapsing the pair to a property would discard the write contract.
@(private)
dts_typed_accessors :: proc(
	state: ^DeclarationEmit, name: string, numeric: bool, read: ^TSType,
	parameter: ^FunctionParameter, write: ^TSType,
) -> bool {
	cg := &state.writer
	switch dts_accessor_type_relation(state, read, write) {
	case .Same:
		// The single-file emitter retains dependencies of both annotations.
		pos, line_start := cg.pos, cg.at_line_start
		gen_ts_type(cg, write)
		cg.pos, cg.at_line_start = pos, line_start
		return false
	case .Different:
		dts_error(state, "TS9009", "At least one accessor must have an explicit type annotation with --isolatedDeclarations.", parameter.loc)
	case .Unresolved:
		// Imported and other checker-dependent types can differ in the consuming
		// project. Keeping both signatures lets its type checker resolve them.
		cg_str(cg, " get "); dts_print_accessor_name(cg, name, numeric)
		cg_str(cg, "(): "); gen_ts_type(cg, read)
		cg_str(cg, "; set "); dts_print_accessor_name(cg, name, numeric)
		cg_byte(cg, '('); dts_parameter(state, parameter^, true, 0)
		cg_str(cg, ");")
	}
	return true
}

@(private)
dts_accessor_type_relation :: proc(state: ^DeclarationEmit, read, write: ^TSType) -> DeclarationAccessorTypeRelation {
	// Compare array element types iteratively. A recursive array alias can lead
	// back to the same pair, in which case preserve both original signatures.
	left, right := read, write
	seen: map[[2]^TSType]bool
	for {
		read_root, read_alias := dts_accessor_type_root(state, left)
		write_root, write_alias := dts_accessor_type_root(state, right)
		if read_root == nil || write_root == nil { return .Unresolved }
		if read_root == write_root { return .Same }

		left_element := dts_accessor_array_element(state, read_root)
		right_element := dts_accessor_array_element(state, write_root)
		if left_element == nil || right_element == nil {
			_, read_union := read_root^.(^TSUnionType)
			_, write_union := write_root^.(^TSUnionType)
			named_union := (read_union && read_alias) || (write_union && write_alias)
			return dts_accessor_root_relation(state, read_root, write_root, named_union, left_element != nil || right_element != nil)
		}
		pair := [2]^TSType{read_root, write_root}
		if pair in seen { return .Unresolved }
		seen[pair] = true
		left, right = left_element, right_element
	}
}

@(private)
dts_accessor_array_element :: proc(state: ^DeclarationEmit, ty: ^TSType) -> ^TSType {
	if array, ok := ty^.(^TSArrayType); ok { return array.element_type }
	ref, named := ty^.(^TSTypeReference)
	if !named { return nil }
	args, generic := ref.type_parameters.?
	if !generic || len(args.params) != 1 { return nil }
	name, plain := ref.type_name^.(^Identifier)
	if !plain || name.name != "Array" { return nil }
	if dts_reference_is_local(state, {name.name, name.loc, false}) { return nil }
	if len(dts_lookup(state, name.name, .Type)) > 0 { return nil }
	return args.params[0]
}

// A local interface or class has a declaration identity. An imported type can
// alias any type in another file, so its identity must remain unresolved here.
@(private)
dts_accessor_object_identity :: proc(state: ^DeclarationEmit, ty: ^TSType) -> (string, bool) {
	if _, literal := ty^.(^TSTypeLiteral); literal { return "", true }
	ref, named := ty^.(^TSTypeReference)
	if !named || ref.type_parameters != nil { return "", false }
	name, plain := ref.type_name^.(^Identifier)
	if !plain || dts_reference_is_local(state, {name.name, name.loc, false}) { return "", false }
	for index in dts_lookup(state, name.name, .Type) {
		#partial switch _ in state.items[index].statement {
		case ^TSInterfaceDeclaration, ^ClassDeclaration: return name.name, true
		}
	}
	return name.name, false
}

@(private)
dts_accessor_root_relation :: proc(state: ^DeclarationEmit, read, write: ^TSType, named_union, one_array: bool) -> DeclarationAccessorTypeRelation {
	a, intrinsic_a := dts_accessor_intrinsics(state, read)
	b, intrinsic_b := dts_accessor_intrinsics(state, write)
	if intrinsic_a && intrinsic_b {
		if a != b { return .Different }
		// Two named unions keep their own identity even with identical members.
		if named_union && (card(a.keywords) + card(a.booleans) > 1) { return .Different }
		return .Same
	}
	left, object_a := dts_accessor_object_identity(state, read)
	right, object_b := dts_accessor_object_identity(state, write)
	if left != "" && left == right { return .Same }
	if object_a && object_b { return .Different }
	if intrinsic_a && (object_b || one_array) { return .Different }
	if intrinsic_b && (object_a || one_array) { return .Different }
	if one_array && (object_a || object_b) { return .Different }
	return .Unresolved
}

// Expand transparent parentheses and local, non-generic aliases. A repeated
// declaration cannot add information, so stop when the input's alias bound is reached.
@(private)
dts_accessor_type_root :: proc(state: ^DeclarationEmit, ty: ^TSType) -> (root: ^TSType, from_alias: bool) {
	current := ty
	for aliases := 0; current != nil && aliases <= len(state.items); {
		#partial switch t in current^ {
		case ^TSParenthesizedType:
			current = t.type_annotation
		case ^TSTypeReference:
			id, plain := t.type_name^.(^Identifier)
			if !plain || t.type_parameters != nil { return current, from_alias }
			if dts_reference_is_local(state, {id.name, id.loc, false}) { return current, from_alias }
			matches := dts_lookup(state, id.name, .Type)
			if len(matches) != 1 { return current, from_alias }
			item := &state.items[matches[0]]
			// The alias's dependencies are looked up in its declaration region.
			if item.region != state.region { return nil, from_alias }
			alias, found := item.statement.(^TSTypeAliasDeclaration)
			if !found || alias.type_parameters != nil { return current, from_alias }
			from_alias = true
			current = alias.type_annotation
			aliases += 1
		case: return current, from_alias
		}
	}
	return nil, from_alias
}

@(private)
dts_accessor_intrinsics :: proc(state: ^DeclarationEmit, root: ^TSType) -> (DeclarationIntrinsicTypes, bool) {
	result: DeclarationIntrinsicTypes
	pending := make([dynamic]^TSType, 0, 1)
	append(&pending, root)
	seen: map[^TSType]bool
	for len(pending) > 0 {
		ty, _ := dts_accessor_type_root(state, pop(&pending))
		if ty == nil { return {}, false }
		#partial switch t in ty^ {
		case ^TSKeywordType:
			if t.kind == .Intrinsic || t.kind == .This { return {}, false }
			if t.kind == .Boolean {
				result.booleans += {.True, .False}
			} else { result.keywords += {t.kind} }
		case ^TSLiteralType:
			node, boolean := t.literal^.(^BooleanLiteral)
			if !boolean { return {}, false }
			if node.value { result.booleans += {.True} } else { result.booleans += {.False} }
		case ^TSUnionType:
			// A recursive alias through a union cannot be resolved in isolation.
			if ty in seen { return {}, false }
			seen[ty] = true
			append(&pending, ..t.types[:])
		case: return {}, false
		}
	}
	if .Any in result.keywords { return {keywords = {.Any}}, true }
	if .Unknown in result.keywords { return {keywords = {.Unknown}}, true }
	if card(result.keywords) + card(result.booleans) > 1 { result.keywords -= {.Never} }
	return result, true
}
