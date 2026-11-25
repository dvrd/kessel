package kessel

import "core:mem"
import "core:strings"

// An explicit stack bounds formatting work on deeply nested configuration data.
// Unsupported expressions cause the entire statement to be copied from source.
FormatDataFrame :: struct {
	object: ^ObjectExpression,
	array: ^ArrayExpression,
	index, count: int,
	previous_end: u32,
	fill: bool,
}

@(private)
format_data_statement :: proc(
	parts: ^[dynamic]FormatPart,
	statement: ^Statement,
	source: string,
	options: FormatOptions,
	alloc: mem.Allocator,
) -> bool {
	value: ^Expression
	declaration: ^VariableDeclaration
	#partial switch node in statement^ {
	case ^VariableDeclaration: declaration = node
	case ^ExportNamedDeclaration:
		decl, present := node.declaration.?
		if !present || decl == nil { return false }
		declaration, _ = decl^.(^VariableDeclaration)
		if declaration == nil { return false }
		format_text(parts, "export ")
	case ^ExportDefaultDeclaration:
		if node.declaration == nil { return false }
		value, _ = node.declaration^.(^Expression)
		format_text(parts, "export default ")
	case: return false
	}
	if declaration != nil {
		if len(declaration.declarations) != 1 || declaration.declare { return false }
		binding := &declaration.declarations[0]
		id, named := binding.id.(^Identifier)
		if !named || binding.definite { return false }
		value, _ = binding.init.?
		#partial switch declaration.kind {
		case .Const: format_text(parts, "const ")
		case .Let: format_text(parts, "let ")
		case .Var: format_text(parts, "var ")
		case: return false
		}
		format_text(parts, id.name)
		if ann, typed := id.type_annotation.?; typed {
			type_name := format_data_type_name(ann.type_annotation, source)
			if type_name == "" { return false }
			format_text(parts, ": ")
			format_text(parts, type_name)
		}
		format_text(parts, " =")
		format_data_assignment_line(parts)
	}
	if value == nil { return false }
	if !format_data_initializer(parts, value, source, options, alloc) { return false }
	format_text(parts, ";")
	return true
}

// An assertion applies to the expression on its left. Walk down to the data
// literal, then emit the assertions from the innermost to the outermost.
@(private="file")
format_data_initializer :: proc(
	parts: ^[dynamic]FormatPart,
	expr: ^Expression,
	source: string,
	options: FormatOptions,
	alloc: mem.Allocator,
) -> bool {
	assert(expr != nil)
	suffixes: [FORMAT_GROUP_DEPTH_MAX]struct { operator, name: string }
	count := 0
	value := expr
	for value != nil {
		operator: string
		type_node: ^TSType
		#partial switch node in value^ {
		case ^ObjectExpression, ^ArrayExpression:
			if !format_data_parts(parts, value, source, options, alloc) { return false }
			for count > 0 {
				count -= 1
				format_text(parts, suffixes[count].operator)
				format_text(parts, suffixes[count].name)
			}
			return true
		case ^TSAsExpression:
			value, operator, type_node = node.expression, " as ", node.type_annotation
		case ^TSSatisfiesExpression:
			value, operator, type_node = node.expression, " satisfies ", node.type_annotation
		case: return false
		}
		if count == len(suffixes) { return false }
		name := format_data_type_name(type_node, source)
		if name == "" { return false }
		suffixes[count] = {operator, name}
		count += 1
	}
	return false
}

@(private="file")
format_data_assignment_line :: proc(parts: ^[dynamic]FormatPart) {
	line := FormatPart{kind = .Line, text = " ", indent = true}
	append(parts, FormatPart{kind = .Group}, line, FormatPart{kind = .End})
}

@(private="file")
format_data_type_name :: proc(t: ^TSType, source: string) -> string {
	if t == nil { return "" }
	loc := get_ts_type_loc(t)
	if loc == nil { return "" }
	name := source[loc.start:loc.end]
	// Keep qualified names and array suffixes only when already in canonical
	// form. Complex types retain their original statement until they have a printer.
	base := name
	for strings.has_suffix(base, "[]") { base = base[:len(base)-2] }
	expect_start := true
	for ch in base {
		if expect_start {
			if !is_id_start_codepoint(u32(ch)) { return "" }
			expect_start = false
		} else if ch == '.' {
			expect_start = true
		} else if !is_id_cont_codepoint(u32(ch)) { return "" }
	}
	if expect_start { return "" }
	return name
}

@(private="file")
format_data_atom :: proc(
	expr: ^Expression,
	options: FormatOptions,
	alloc: mem.Allocator,
) -> string {
	#partial switch node in expr^ {
	case ^Identifier: return node.name
	case ^BooleanLiteral: return "true" if node.value else "false"
	case ^NullLiteral: return "null"
	case ^NumericLiteral: return node.raw
	case ^BigIntLiteral: return node.raw
	case ^StringLiteral:
		if strings.contains_any(node.raw, "\r\n\u2028\u2029") { return "" }
		return format_string(node.raw, options.single_quote, alloc)
	}
	return ""
}

@(private="file")
format_data_number :: proc(expr: ^Expression) -> bool {
	if expr == nil { return false }
	#partial switch node in expr^ {
	case ^NumericLiteral: return true
	case ^UnaryExpression:
		if node.operator != .Plus && node.operator != .Minus { return false }
		_, number := node.argument^.(^NumericLiteral)
		return number
	}
	return false
}

@(private="file")
format_data_open_array :: proc(array: ^ArrayExpression) -> (frame: FormatDataFrame, force: bool) {
	frame = {array = array, count = len(array.elements), fill = true}
	// Rows of arrays or objects with several entries each retain separate lines.
	rows := len(array.elements) > 1
	first_array := false
	for element, i in array.elements {
		value, present := element.?
		if !present || value == nil { frame.fill = false; rows = false; continue }
		frame.fill = frame.fill && format_data_number(value)
		#partial switch node in value^ {
		case ^ArrayExpression:
			if i == 0 { first_array = true }
			rows = rows && first_array && len(node.elements) > 1
		case ^ObjectExpression: rows = rows && !first_array && len(node.properties) > 1
		case: rows = false
		}
	}
	return frame, rows
}

@(private="file")
format_data_parts :: proc(
	parts: ^[dynamic]FormatPart,
	root: ^Expression,
	source: string,
	options: FormatOptions,
	alloc: mem.Allocator,
) -> bool {
	frames: [FORMAT_GROUP_DEPTH_MAX-1]FormatDataFrame
	depth := 0
	value := root
	for {
		if value != nil {
			frame: FormatDataFrame
			bracket, space := "", ""
			force := false
			#partial switch node in value^ {
			case ^ObjectExpression:
				frame = {object = node, count = len(node.properties)}
				bracket = "{"
				if options.bracket_spacing { space = " " }
				if frame.count > 0 {
					head := source[node.loc.start:node.properties[0].loc.start]
					force = strings.contains_any(head, "\r\n\u2028\u2029")
				}
			case ^ArrayExpression:
				frame, force = format_data_open_array(node)
				bracket = "["
			case ^SpreadElement: format_text(parts, "..."); value = node.argument; continue
			case ^UnaryExpression:
				if !format_data_number(value) { return false }
				format_text(parts, "-" if node.operator == .Minus else "+")
				value = node.argument
				continue
			case:
				text := format_data_atom(value, options, alloc)
				if text == "" { return false }
				format_text(parts, text)
			}
			value = nil
			if bracket != "" {
				format_text(parts, bracket)
				if frame.count == 0 { format_text(parts, "}" if frame.object != nil else "]") }
				else {
					if depth == len(frames) { return false }
					frames[depth] = frame
					depth += 1
					append(parts, FormatPart{kind = .Forced_Group if force else .Group})
					append(parts, FormatPart{kind = .Line, text = space, indent = true})
				}
			}
		}
		if depth == 0 { break }
		frame := &frames[depth-1]
		if frame.index == frame.count {
			format_data_close(parts, frame, options)
			depth -= 1
			continue
		}
		ok: bool
		value, ok = format_data_item(parts, frame, source, options, alloc)
		if !ok { return false }
		frame.index += 1
	}
	return true
}

@(private="file")
format_data_item :: proc(
	parts: ^[dynamic]FormatPart,
	frame: ^FormatDataFrame,
	source: string,
	options: FormatOptions,
	alloc: mem.Allocator) -> (^Expression,
	bool,
) {
	assert(frame.index < frame.count)
	loc: Loc
	prop: ^Property
	value: ^Expression
	if frame.object != nil {
		prop = &frame.object.properties[frame.index]
		loc = prop.loc
		if prop.kind != .Init { return nil, false }
		value = prop.value
	} else {
		value, _ = frame.array.elements[frame.index].?
		if value != nil { loc = get_expression_loc(value) }
	}
	if frame.index > 0 {
		format_text(parts, ",")
		separator := FormatPart{kind = .Line, text = " ", indent = true}
		if frame.fill { separator.kind = .Fill_Line }
		if frame.previous_end > 0 && frame.previous_end <= loc.start {
			gap := source[frame.previous_end:loc.start]
			if format_has_blank_line(gap) { separator.kind = .Blank_Line }
		}
		append(parts, separator)
	}
	frame.previous_end = loc.end
	if prop == nil || prop.key == nil { return value, true }
	key := format_data_atom(prop.key, options, alloc)
	if key == "" { return nil, false }
	if !prop.computed {
		literal, quoted := prop.key^.(^StringLiteral)
		if quoted && format_identifier_key(literal.raw) {
			key = literal.raw[1:len(literal.raw)-1]
		}
	}
	if prop.computed { format_text(parts, "[") }
	format_text(parts, key)
	if prop.computed { format_text(parts, "]") }
	if prop.shorthand { return nil, true }
	if value == nil { return nil, false }
	format_text(parts, ":")
	#partial switch _ in value^ {
	case ^Identifier, ^StringLiteral, ^NullLiteral, ^BigIntLiteral, ^UnaryExpression,
	     ^ObjectExpression, ^ArrayExpression:
		key_width := format_width(key) + (2 if prop.computed else 0)
		if key_width > int(options.tab_width) + 2 {
			format_data_assignment_line(parts)
			return value, true
		}
	}
	format_text(parts, " ")
	return value, true
}

@(private="file")
format_data_close :: proc(
	parts: ^[dynamic]FormatPart,
	frame: ^FormatDataFrame,
	options: FormatOptions,
) {
	assert(frame.count > 0)
	last_hole := frame.array != nil && frame.array.elements[frame.count-1] == nil
	if last_hole { format_text(parts, ",") }
	else if options.trailing_comma { append(parts, FormatPart{kind = .If_Break, text = ","}) }
	space := " " if frame.object != nil && options.bracket_spacing else ""
	append(parts, FormatPart{kind = .Line, text = space}, FormatPart{kind = .End})
	format_text(parts, "}" if frame.object != nil else "]")
}
