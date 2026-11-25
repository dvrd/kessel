package kessel

// TypeScript types. Only types that Prettier prints exactly as written are
// covered: keywords, plain or dotted names without type arguments, and
// arrays of those. Unions, functions, generics and the rest have breaking
// rules of their own that are not ported, and a statement that uses one
// keeps its text.

// The text of a simple type, or "" for any other type.
format_simple_type_text :: proc(f: ^FormatContext, type: ^TSType) -> string {
	if type == nil {return ""}
	#partial switch _ in type^ {
	case ^TSKeywordType, ^TSTypeReference, ^TSArrayType:
	case: return ""
	}
	loc := get_ts_type_loc(type)
	if loc == nil || loc.end <= loc.start {return ""}
	text := f.source[loc.start:loc.end]
	base := text
	for len(base) > 2 && base[len(base) - 2:] == "[]" {base = base[:len(base) - 2]}
	expect_start := true
	for char in base {
		if char >= 0x80 {return ""}
		if expect_start {
			if !is_id_start_codepoint(u32(char)) {return ""}
			expect_start = false
		} else if char == '.' {
			expect_start = true
		} else if !is_id_cont_codepoint(u32(char)) {
			return ""
		}
	}
	if expect_start {return ""}
	return text
}

format_simple_type :: proc(f: ^FormatContext, type: ^TSType) -> Doc {
	text := format_simple_type_text(f, type)
	if text == "" {return format_fail(f)}
	return ft(f, text)
}

// `: Type` after a binding or a parameter list, or nil without annotation.
format_type_annotation :: proc(f: ^FormatContext, annotation: Maybe(^TSTypeAnnotation)) -> Doc {
	node, present := annotation.?
	if !present || node == nil {return nil}
	return fc(f, ft(f, ": "), format_simple_type(f, node.type_annotation))
}

// True for a return type that names a type, as opposed to a keyword.
// Prettier does not hug an arrow function that has one unless its body is a
// block with statements.
format_returns_type_reference :: proc(annotation: Maybe(^TSTypeAnnotation)) -> bool {
	node, present := annotation.?
	if !present || node == nil || node.type_annotation == nil {return false}
	_, reference := node.type_annotation^.(^TSTypeReference)
	return reference
}
