package kessel

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import mvirtual "core:mem/virtual"
import "core:strings"
import "core:unicode/utf8"

RegexAstKind :: enum {
	Pattern, Alternative, Group, Character_Class, Character, Dot,
	Start_Assertion, End_Assertion, Boundary_Assertion,
	Character_Class_Escape, Property_Escape, Escape, Indexed_Reference,
	Named_Reference, Quantifier,
	Class_Range, Class_Intersection, Class_Subtraction, Class_String,
}

RegexGroupKind :: enum {
	Capture, Named_Capture, Noncapturing, Lookahead, Negative_Lookahead,
	Lookbehind, Negative_Lookbehind, Modifiers,
}

RegexAstFlag :: enum { Indices, Global, Ignore_Case, Multiline, Dot_All, Unicode, Unicode_Sets, Sticky }
RegexAstFlags :: bit_set[RegexAstFlag]

RegexRepeatBound :: struct {
	value: u64,
	digits: Loc,
	overflow: bool,
}

RegexRepeat :: struct {
	min: RegexRepeatBound,
	max: Maybe(RegexRepeatBound),
	greedy: bool,
}

RegexAstNode :: struct {
	kind: RegexAstKind,
	span: Loc,
	first_child, next_sibling: u32,
	group_kind: RegexGroupKind,
	capture_index: u32,
	name: Loc,
	property_value: Maybe(Loc),
	code_point: Maybe(u32),
	negative: bool,
	may_contain_strings: bool,
	repeat: RegexRepeat,
}

RegexAst :: struct {
	// Nodes use index zero for an absent link. Root points to the Pattern.
	nodes: [dynamic]RegexAstNode,
	root: u32,
	flags: RegexAstFlags,
	capture_count: u32,
	has_named_captures: bool,
}

RegexAstErrorKind :: enum { None, Invalid_Pattern, Invalid_Flags, Source_Too_Large, Depth_Limit, Allocation_Error }

RegexAstError :: struct {
	kind: RegexAstErrorKind,
	offset: u32,
	message: string,
}

RegexAstFrame :: struct {
	container, alternative, previous_term, last_term: u32,
}

RegexClassRelation :: enum { Union, Intersection, Subtraction }

RegexClassFrame :: struct {
	container, previous, last: u32,
	operands: u32,
	relation: RegexClassRelation,
	needs_operand: bool,
}

// Build a source-preserving tree from a regexp body without slash delimiters.
// Spans address UTF-8 bytes in the supplied pattern. The caller owns the
// node buffer and keeps the original pattern for access to source spellings.
regex_parse_ast :: proc(pattern, flags: string, allocator: mem.Allocator) -> (RegexAst, RegexAstError) {
	assert(allocator.procedure != nil)
	if u64(len(pattern)) >= u64(max(u32)) || u64(len(flags)) >= u64(max(u32)) {
		return {}, {kind = .Source_Too_Large}
	}
	parsed_flags, flag_err := regex_ast_flags(flags)
	if flag_err.kind != .None { return {}, flag_err }

	scratch: mvirtual.Arena
	if err := mvirtual.arena_init_growing(&scratch); err != nil { return {}, {kind = .Allocation_Error} }
	defer mvirtual.arena_destroy(&scratch)
	validation := regex_validate(
		transmute([]u8)pattern, 0, u32(len(pattern)),
		.Unicode in parsed_flags, .Unicode_Sets in parsed_flags,
		mvirtual.arena_allocator(&scratch),
		defer_v_string_negation = true,
	)
	if len(validation) != 0 {
		return {}, {kind = .Invalid_Pattern, offset = validation[0].offset, message = validation[0].message}
	}

	ast: RegexAst
	ast.flags = parsed_flags
	ast.capture_count, ast.has_named_captures = regex_ast_capture_summary(pattern, parsed_flags)
	ast.nodes.allocator = allocator
	if _, err := append(&ast.nodes, RegexAstNode{}); err != nil {
		return {}, {kind = .Allocation_Error}
	}
	err := regex_ast_scan(&ast, pattern)
	if err.kind != .None {
		regex_ast_destroy(&ast)
		return {}, err
	}
	return ast, {}
}

regex_ast_destroy :: proc(ast: ^RegexAst) {
	delete(ast.nodes)
	ast^ = {}
}

@(private="file")
regex_ast_flags :: proc(flags: string) -> (RegexAstFlags, RegexAstError) {
	if len(flags) > 8 { return {}, {kind = .Invalid_Flags, message = "Too many regexp flags"} }
	result: RegexAstFlags
	for ch, index in transmute([]byte)flags {
		flag: RegexAstFlag
		switch ch {
		case 'd': flag = .Indices
		case 'g': flag = .Global
		case 'i': flag = .Ignore_Case
		case 'm': flag = .Multiline
		case 's': flag = .Dot_All
		case 'u': flag = .Unicode
		case 'v': flag = .Unicode_Sets
		case 'y': flag = .Sticky
		case: return {}, {kind = .Invalid_Flags, offset = u32(index), message = "Unknown regexp flag"}
		}
		if flag in result {
			return {}, {kind = .Invalid_Flags, offset = u32(index), message = "Duplicate regexp flag"}
		}
		if (flag == .Unicode && .Unicode_Sets in result) || (flag == .Unicode_Sets && .Unicode in result) {
			return {}, {kind = .Invalid_Flags, offset = u32(index), message = "Conflicting Unicode flags"}
		}
		result += {flag}
	}
	return result, {}
}

@(private="file")
regex_ast_push :: proc(ast: ^RegexAst, node: RegexAstNode) -> (u32, RegexAstError) {
	if u64(len(ast.nodes)) >= u64(max(u32)) { return 0, {kind = .Source_Too_Large} }
	id := u32(len(ast.nodes))
	if _, err := append(&ast.nodes, node); err != nil { return 0, {kind = .Allocation_Error} }
	return id, {}
}

@(private="file")
regex_ast_new_alternative :: proc(ast: ^RegexAst, frame: ^RegexAstFrame, start: int) -> RegexAstError {
	node := RegexAstNode{kind = .Alternative, span = {start = u32(start)}}
	id, err := regex_ast_push(ast, node)
	if err.kind != .None { return err }
	if frame.alternative == 0 {
		ast.nodes[frame.container].first_child = id
	} else {
		ast.nodes[frame.alternative].next_sibling = id
	}
	frame.alternative = id
	frame.previous_term, frame.last_term = 0, 0
	return {}
}

@(private="file")
regex_ast_append_term :: proc(ast: ^RegexAst, frame: ^RegexAstFrame, node: RegexAstNode) -> (u32, RegexAstError) {
	id, err := regex_ast_push(ast, node)
	if err.kind != .None { return 0, err }
	if frame.last_term == 0 {
		ast.nodes[frame.alternative].first_child = id
	} else {
		ast.nodes[frame.last_term].next_sibling = id
	}
	frame.previous_term, frame.last_term = frame.last_term, id
	return id, {}
}

@(private="file")
regex_ast_scan :: proc(ast: ^RegexAst, pattern: string) -> RegexAstError {
	MAX_DEPTH :: 256
	root, root_err := regex_ast_push(ast, {kind = .Pattern, span = {end = u32(len(pattern))}})
	if root_err.kind != .None { return root_err }
	ast.root = root
	frames: [MAX_DEPTH]RegexAstFrame
	frames[0].container = root
	if err := regex_ast_new_alternative(ast, &frames[0], 0); err.kind != .None { return err }
	depth := 1
	next_capture: u32
	for cursor := 0; cursor < len(pattern); {
		frame := &frames[depth - 1]
		switch pattern[cursor] {
		case '|':
			ast.nodes[frame.alternative].span.end = u32(cursor)
			cursor += 1
			if err := regex_ast_new_alternative(ast, frame, cursor); err.kind != .None { return err }
		case '(':
			if depth == len(frames) { return {kind = .Depth_Limit, offset = u32(cursor)} }
			node, next, parse_err := regex_ast_group(pattern, cursor, &next_capture)
			if parse_err.kind != .None { return parse_err }
			cursor = next
			id, push_err := regex_ast_append_term(ast, frame, node)
			if push_err.kind != .None { return push_err }
			frames[depth] = {container = id}
			if err := regex_ast_new_alternative(ast, &frames[depth], cursor); err.kind != .None { return err }
			depth += 1
		case ')':
			if depth == 1 { return regex_ast_invalid(cursor, "Unmatched closing group") }
			ast.nodes[frame.alternative].span.end = u32(cursor)
			cursor += 1
			ast.nodes[frame.container].span.end = u32(cursor)
			depth -= 1
		case '[', '*', '+', '?', '{':
			next, err := regex_ast_special(ast, frame, pattern, cursor)
			if err.kind != .None { return err }
			cursor = next
		case:
			node, next, parse_err := regex_ast_atom(ast, pattern, cursor, false)
			if parse_err.kind != .None { return parse_err }
			cursor = next
			if err := regex_ast_append_atom(ast, frame, node); err.kind != .None { return err }
		}
	}
	if depth != 1 { return regex_ast_invalid(len(pattern), "Unterminated group") }
	ast.nodes[frames[0].alternative].span.end = u32(len(pattern))
	return {}
}

@(private="file")
regex_ast_special :: proc(ast: ^RegexAst, frame: ^RegexAstFrame, pattern: string, start: int) -> (int, RegexAstError) {
	if pattern[start] == '[' {
		id, push_err := regex_ast_append_term(ast, frame, {kind = .Character_Class, span = {start = u32(start)}})
		if push_err.kind != .None { return 0, push_err }
		return regex_ast_class(ast, id, pattern, start)
	}
	if pattern[start] == '{' && !regex_is_braced_quantifier(transmute([]u8)pattern, start, len(pattern)) {
		if .Unicode in ast.flags || .Unicode_Sets in ast.flags {
			return 0, regex_ast_invalid(start, "Unescaped regexp delimiter")
		}
		_, err := regex_ast_append_term(ast, frame, {kind = .Character, span = {u32(start), u32(start + 1)}, code_point = u32('{')})
		return start + 1, err
	}
	return regex_ast_quantifier(ast, frame, pattern, start)
}

@(private="file")
regex_ast_capture_summary :: proc(pattern: string, flags: RegexAstFlags) -> (count: u32, has_named: bool) {
	class_depth := 0
	for i := 0; i < len(pattern); i += 1 {
		switch pattern[i] {
		case '\\':
			i += 1
			if i + 1 < len(pattern) && class_depth > 0 && .Unicode_Sets in flags && pattern[i:i + 2] == "q{" {
				for i += 2; i < len(pattern) && pattern[i] != '}'; i += 1 {
					if pattern[i] == '\\' { i += 1 }
				}
			}
		case '[':
			if class_depth == 0 || .Unicode_Sets in flags { class_depth += 1 }
		case ']':
			if class_depth > 0 { class_depth -= 1 }
		case '(':
			if class_depth != 0 { continue }
			if i + 1 == len(pattern) || pattern[i + 1] != '?' {
				count += 1
			} else if i + 3 < len(pattern) && pattern[i + 2] == '<' && pattern[i + 3] != '=' && pattern[i + 3] != '!' {
				count += 1
				has_named = true
			}
		}
	}
	return count, has_named
}

@(private="file")
regex_ast_group :: proc(pattern: string, start: int, next_capture: ^u32) -> (RegexAstNode, int, RegexAstError) {
	group := RegexAstNode{kind = .Group, span = {start = u32(start)}}
	cursor := start + 1
	if cursor < len(pattern) && pattern[cursor] == '?' {
		cursor += 1
		if cursor == len(pattern) { return {}, 0, regex_ast_invalid(cursor, "Incomplete group prefix") }
		switch pattern[cursor] {
		case ':': group.group_kind = .Noncapturing
		case '=': group.group_kind = .Lookahead
		case '!': group.group_kind = .Negative_Lookahead
		case '<':
			cursor += 1
			if cursor == len(pattern) { return {}, 0, regex_ast_invalid(cursor, "Incomplete named group prefix") }
			switch pattern[cursor] {
			case '=': group.group_kind = .Lookbehind
			case '!': group.group_kind = .Negative_Lookbehind
			case:
				close := strings.index_byte(pattern[cursor:], '>')
				if close < 1 { return {}, 0, regex_ast_invalid(cursor, "Unterminated group name") }
				group.group_kind = .Named_Capture
				group.name = {u32(cursor), u32(cursor + close)}
				cursor += close
			}
		case 'i', 'm', 's', '-':
			close := strings.index_byte(pattern[cursor:], ':')
			if close < 1 { return {}, 0, regex_ast_invalid(cursor, "Invalid modifier group") }
			group.group_kind = .Modifiers
			group.name = {u32(cursor), u32(cursor + close)}
			cursor += close
		case: return {}, 0, regex_ast_invalid(cursor, "Unknown group prefix")
		}
		cursor += 1
	}
	if group.group_kind == .Capture || group.group_kind == .Named_Capture {
		next_capture^ += 1
		group.capture_index = next_capture^
	}
	return group, cursor, {}
}

@(private="file")
regex_ast_append_atom :: proc(ast: ^RegexAst, frame: ^RegexAstFrame, atom: RegexAstNode) -> RegexAstError {
	first, second := regex_ast_code_units(ast.flags, atom)
	if _, err := regex_ast_append_term(ast, frame, first); err.kind != .None { return err }
	if trailing, ok := second.?; ok {
		if _, err := regex_ast_append_term(ast, frame, trailing); err.kind != .None { return err }
	}
	return {}
}

// Legacy regexp grammar consumes UTF-16 code units. A source rune can
// produce two AST atoms sharing its UTF-8 span.
@(private="file")
regex_ast_code_units :: proc(flags: RegexAstFlags, atom: RegexAstNode) -> (RegexAstNode, Maybe(RegexAstNode)) {
	if .Unicode in flags || .Unicode_Sets in flags { return atom, nil }
	value, ok := atom.code_point.?
	if !ok || value <= 0xffff { return atom, nil }
	assert(atom.kind == .Character || atom.kind == .Escape)
	supplement := value - 0x10000
	leading := atom
	leading.code_point = u32(0xd800) + (supplement >> 10)
	trailing := atom
	trailing.kind = .Character
	if atom.kind == .Escape { trailing.span.start += 1 }
	trailing.code_point = u32(0xdc00) + (supplement & 0x3ff)
	return leading, trailing
}

@(private="file")
regex_ast_atom :: proc(ast: ^RegexAst, pattern: string, start: int, in_class: bool) -> (RegexAstNode, int, RegexAstError) {
	if pattern[start] == '\\' { return regex_ast_escape(ast, pattern, start, in_class) }
	kind := RegexAstKind.Character
	if !in_class {
		switch pattern[start] {
		case ']', '}':
			if .Unicode in ast.flags || .Unicode_Sets in ast.flags {
				return {}, 0, regex_ast_invalid(start, "Unescaped regexp delimiter")
			}
		case '.': kind = .Dot
		case '^': kind = .Start_Assertion
		case '$': kind = .End_Assertion
		}
	}
	code_point, width := utf8.decode_rune_in_string(pattern[start:])
	end := start + width
	node := RegexAstNode{kind = kind, span = {u32(start), u32(end)}}
	if kind == .Character { node.code_point = u32(code_point) }
	return node, end, {}
}

@(private="file")
regex_ast_escape :: proc(ast: ^RegexAst, pattern: string, start: int, in_class: bool) -> (RegexAstNode, int, RegexAstError) {
	if start + 1 == len(pattern) { return {}, 0, regex_ast_invalid(start, "Trailing regexp escape") }
	body := start + 1
	_, width := utf8.decode_rune_in_string(pattern[body:])
	end := body + width
	node := RegexAstNode{kind = .Escape, span = {start = u32(start)}}
	unicode := .Unicode in ast.flags || .Unicode_Sets in ast.flags
	switch pattern[body] {
	case 'b', 'B':
		if !in_class {
			node.kind = .Boundary_Assertion
			node.negative = pattern[body] == 'B'
		}
	case 'd', 'D', 's', 'S', 'w', 'W':
		node.kind = .Character_Class_Escape
		node.negative = pattern[body] < 'a'
	case 'p', 'P', 'q', 'k':
		name_end := regex_ast_escape_body(ast, &node, pattern, body, unicode, in_class)
		if name_end != 0 { end = name_end }
	case '0'..='9':
		end = regex_ast_digit_escape(ast, &node, pattern, body, unicode, in_class)
	case 'x', 'u':
		end = regex_ast_hex_end(pattern, body, unicode)
		if unicode && pattern[body] == 'u' && end - start == 6 && end + 6 <= len(pattern) && pattern[end:end + 2] == "\\u" {
			code, ok := regex_class_atom_codepoint(transmute([]u8)pattern, start, end + 6)
			if ok && code > 0xffff { end += 6 }
		}
	case 'c':
		if end < len(pattern) && ((pattern[end] | 0x20) >= 'a' && (pattern[end] | 0x20) <= 'z') { end += 1 }
	}
	node.span.end = u32(end)
	if node.kind == .Escape { node.code_point = regex_ast_escape_code_point(pattern, start, end, in_class) }
	return node, end, {}
}

@(private="file")
regex_ast_escape_code_point :: proc(pattern: string, start, end: int, in_class: bool) -> Maybe(u32) {
	body := start + 1
	ch := pattern[body]
	if ch >= '0' && ch <= '7' {
		value: u32
		for byte in transmute([]u8)pattern[body:end] { value = value * 8 + u32(byte - '0') }
		return value
	}
	if ch == 'c' && end - start == 3 { return u32(pattern[body + 1] & 0x1f) }
	if in_class && ch == 'b' { return u32(8) }
	if value, ok := regex_class_atom_codepoint(transmute([]u8)pattern, start, end); ok && ch < 0x80 {
		return value
	}
	value, _ := utf8.decode_rune_in_string(pattern[body:end])
	return u32(value)
}

@(private="file")
regex_ast_digit_escape :: proc(
	ast: ^RegexAst,
	node: ^RegexAstNode,
	pattern: string,
	body: int,
	unicode, in_class: bool,
) -> int {
	digit := pattern[body]
	if digit != '0' && !in_class {
		decimal, decimal_end := regex_ast_read_decimal(pattern, body)
		if !decimal.overflow && decimal.value <= u64(ast.capture_count) {
			node.kind = .Indexed_Reference
			node.capture_index = u32(decimal.value)
			return decimal_end
		}
	}
	end := body + 1
	if unicode || digit > '7' { return end }
	limit := body + (3 if digit <= '3' else 2)
	for end < len(pattern) && end < limit && pattern[end] >= '0' && pattern[end] <= '7' { end += 1 }
	return end
}

@(private="file")
regex_ast_escape_body :: proc(ast: ^RegexAst, node: ^RegexAstNode, pattern: string, body: int, unicode, in_class: bool) -> int {
	if body + 1 == len(pattern) { return 0 }
	close: u8
	switch pattern[body] {
	case 'k':
		if in_class || (!unicode && !ast.has_named_captures) || pattern[body + 1] != '<' { return 0 }
		node.kind, close = .Named_Reference, '>'
	case 'q':
		if !in_class || .Unicode_Sets not_in ast.flags || pattern[body + 1] != '{' { return 0 }
		node.kind, close = .Class_String, '}'
	case:
		if !unicode || pattern[body + 1] != '{' { return 0 }
		node.kind, close = .Property_Escape, '}'
		node.negative = pattern[body] == 'P'
	}
	for i := body + 2; i < len(pattern); i += 1 {
		if pattern[i] == '\\' && i + 1 < len(pattern) { i += 1; continue }
		if pattern[i] != close { continue }
		node.name = {u32(body + 2), u32(i)}
		if node.kind == .Property_Escape {
			if equals := strings.index_byte(pattern[body + 2:i], '='); equals >= 0 {
				value_start := body + 3 + equals
				node.name.end = u32(value_start - 1)
				node.property_value = Loc{u32(value_start), u32(i)}
			} else {
				node.may_contain_strings = is_property_of_strings(pattern[body + 2:i])
			}
		}
		return i + 1
	}
	node.kind = .Escape
	return 0
}

@(private="file")
regex_ast_hex_end :: proc(pattern: string, body: int, unicode: bool) -> int {
	end := body + 1
	if pattern[body] == 'u' && unicode && end < len(pattern) && pattern[end] == '{' {
		if close := strings.index_byte(pattern[end:], '}'); close > 0 { return end + close + 1 }
	}
	width := 2 if pattern[body] == 'x' else 4
	if end + width > len(pattern) { return end }
	for ch in transmute([]byte)pattern[end:end + width] {
		if (ch < '0' || ch > '9') && ((ch | 0x20) < 'a' || (ch | 0x20) > 'f') { return end }
	}
	return end + width
}

@(private="file")
regex_ast_class :: proc(ast: ^RegexAst, id: u32, pattern: string, start: int) -> (int, RegexAstError) {
	MAX_DEPTH :: 256
	frames: [MAX_DEPTH]RegexClassFrame
	frames[0] = {container = id}
	depth := 1
	cursor := regex_ast_open_class(ast, id, pattern, start)
	for cursor < len(pattern) {
		frame := &frames[depth - 1]
		if pattern[cursor] == ']' {
			if frame.needs_operand { return 0, regex_ast_invalid(cursor, "Missing Unicode set operand") }
			cursor += 1
			ast.nodes[frame.container].span.end = u32(cursor)
			if .Unicode_Sets in ast.flags {
				if err := regex_ast_class_finish(ast, frame); err.kind != .None { return 0, err }
			}
			depth -= 1
			if depth == 0 { return cursor, {} }
			continue
		}
		if .Unicode_Sets in ast.flags && pattern[cursor] == '[' {
			if err := regex_ast_class_operand(frame, cursor); err.kind != .None { return 0, err }
			if depth == len(frames) { return 0, {kind = .Depth_Limit, offset = u32(cursor)} }
			node, err := regex_ast_class_child(ast, frame, {kind = .Character_Class, span = {start = u32(cursor)}})
			if err.kind != .None { return 0, err }
			frames[depth] = {container = node}
			depth += 1
			cursor = regex_ast_open_class(ast, node, pattern, cursor)
			continue
		}
		if pattern[cursor] == '-' {
			next, range_err := regex_ast_class_range(ast, frame, pattern, cursor)
			if range_err.kind != .None { return 0, range_err }
			if next != cursor {
				cursor = next
				continue
			}
		}
		node, next, parse_err := regex_ast_class_atom(ast, pattern, cursor)
		if parse_err.kind != .None { return 0, parse_err }
		if node.kind == .Class_Intersection || node.kind == .Class_Subtraction {
			if err := regex_ast_class_relation(ast, frame, node.kind, cursor); err.kind != .None { return 0, err }
		} else {
			if err := regex_ast_class_operand(frame, cursor); err.kind != .None { return 0, err }
		}
		cursor = next
		first, second := regex_ast_code_units(ast.flags, node)
		child, push_err := regex_ast_class_child(ast, frame, first)
		if push_err.kind != .None { return 0, push_err }
		if trailing, ok := second.?; ok {
			if _, err := regex_ast_class_child(ast, frame, trailing); err.kind != .None { return 0, err }
		}
		if node.kind == .Class_String {
			if err := regex_ast_class_string(ast, child, pattern, node.name); err.kind != .None { return 0, err }
		}
	}
	return 0, regex_ast_invalid(start, "Unterminated character class")
}

@(private="file")
regex_ast_class_finish :: proc(ast: ^RegexAst, frame: ^RegexClassFrame) -> RegexAstError {
	class := &ast.nodes[frame.container]
	contains_strings := frame.relation == .Intersection
	for id := class.first_child; id != 0; id = ast.nodes[id].next_sibling {
		child := ast.nodes[id]
		if child.kind == .Class_Intersection || child.kind == .Class_Subtraction { continue }
		switch frame.relation {
		case .Union: contains_strings = contains_strings || child.may_contain_strings
		case .Intersection: contains_strings = contains_strings && child.may_contain_strings
		case .Subtraction: contains_strings = child.may_contain_strings
		}
		if frame.relation == .Subtraction { break }
	}
	if class.negative && contains_strings {
		return regex_ast_invalid(int(class.span.start), "Negated Unicode set may contain strings")
	}
	class.may_contain_strings = contains_strings
	return {}
}

@(private="file")
regex_ast_class_operand :: proc(frame: ^RegexClassFrame, cursor: int) -> RegexAstError {
	if frame.relation != .Union && !frame.needs_operand {
		return regex_ast_invalid(cursor, "Unicode set operands require an explicit operator")
	}
	frame.operands += 1
	frame.needs_operand = false
	return {}
}

@(private="file")
regex_ast_class_relation :: proc(ast: ^RegexAst, frame: ^RegexClassFrame, kind: RegexAstKind, cursor: int) -> RegexAstError {
	relation := RegexClassRelation.Intersection if kind == .Class_Intersection else RegexClassRelation.Subtraction
	if frame.relation == .Union {
		if frame.operands != 1 || ast.nodes[frame.last].kind == .Class_Range {
			return regex_ast_invalid(cursor, "Invalid left operand for Unicode set operator")
		}
		frame.relation = relation
	} else if frame.relation != relation || frame.needs_operand {
		return regex_ast_invalid(cursor, "Invalid Unicode set operator")
	}
	frame.needs_operand = true
	return {}
}

@(private="file")
regex_ast_class_string :: proc(ast: ^RegexAst, id: u32, pattern: string, span: Loc) -> RegexAstError {
	frame := RegexAstFrame{container = id}
	if err := regex_ast_new_alternative(ast, &frame, int(span.start)); err.kind != .None { return err }
	for cursor := int(span.start); cursor < int(span.end); {
		if pattern[cursor] == '|' {
			ast.nodes[frame.alternative].span.end = u32(cursor)
			cursor += 1
			if err := regex_ast_new_alternative(ast, &frame, cursor); err.kind != .None { return err }
			continue
		}
		node, next, parse_err := regex_ast_atom(ast, pattern[:span.end], cursor, true)
		if parse_err.kind != .None { return parse_err }
		cursor = next
		if _, err := regex_ast_append_term(ast, &frame, node); err.kind != .None { return err }
	}
	ast.nodes[frame.alternative].span.end = span.end
	for alt := ast.nodes[id].first_child; alt != 0; alt = ast.nodes[alt].next_sibling {
		first := ast.nodes[alt].first_child
		if first == 0 || ast.nodes[first].next_sibling != 0 {
			ast.nodes[id].may_contain_strings = true
			break
		}
	}
	return {}
}

@(private="file")
regex_ast_class_range :: proc(ast: ^RegexAst, frame: ^RegexClassFrame, pattern: string, start: int) -> (int, RegexAstError) {
	if frame.last == 0 || start + 1 == len(pattern) { return start, {} }
	if pattern[start + 1] == ']' { return start, {} }
	if .Unicode_Sets in ast.flags && (pattern[start + 1] == '-' || pattern[start + 1] == '[') { return start, {} }
	left := ast.nodes[frame.last]
	if left.kind != .Character && left.kind != .Escape { return start, {} }
	atom, next, parse_err := regex_ast_atom(ast, pattern, start + 1, true)
	if parse_err.kind != .None { return 0, parse_err }
	right, trailing := regex_ast_code_units(ast.flags, atom)
	if right.kind != .Character && right.kind != .Escape { return start, {} }
	if frame.relation != .Union { return 0, regex_ast_invalid(start, "Range cannot be a Unicode set operand") }
	if left.code_point != nil && right.code_point != nil && left.code_point.? > right.code_point.? {
		return 0, regex_ast_invalid(start, "Character class range is reversed")
	}

	right_id, right_err := regex_ast_push(ast, right)
	if right_err.kind != .None { return 0, right_err }
	range_id, range_err := regex_ast_push(ast, {
		kind = .Class_Range, span = {left.span.start, right.span.end}, first_child = frame.last,
	})
	if range_err.kind != .None { return 0, range_err }
	ast.nodes[frame.last].next_sibling = right_id
	if frame.previous == 0 {
		ast.nodes[frame.container].first_child = range_id
	} else {
		ast.nodes[frame.previous].next_sibling = range_id
	}
	frame.last = range_id
	if unit, ok := trailing.?; ok {
		if _, err := regex_ast_class_child(ast, frame, unit); err.kind != .None { return 0, err }
	}
	return next, {}
}

@(private="file")
regex_ast_class_atom :: proc(ast: ^RegexAst, pattern: string, start: int) -> (RegexAstNode, int, RegexAstError) {
	if .Unicode_Sets in ast.flags && start + 1 < len(pattern) {
		two := pattern[start:start + 2]
		if two == "&&" || two == "--" {
			kind := RegexAstKind.Class_Intersection if two == "&&" else RegexAstKind.Class_Subtraction
			return {kind = kind, span = {u32(start), u32(start + 2)}}, start + 2, {}
		}
	}
	return regex_ast_atom(ast, pattern, start, true)
}

@(private="file")
regex_ast_open_class :: proc(ast: ^RegexAst, id: u32, pattern: string, start: int) -> int {
	cursor := start + 1
	if cursor < len(pattern) && pattern[cursor] == '^' {
		ast.nodes[id].negative = true
		cursor += 1
	}
	return cursor
}

@(private="file")
regex_ast_class_child :: proc(ast: ^RegexAst, frame: ^RegexClassFrame, node: RegexAstNode) -> (u32, RegexAstError) {
	id, err := regex_ast_push(ast, node)
	if err.kind != .None { return 0, err }
	if frame.last == 0 {
		ast.nodes[frame.container].first_child = id
	} else {
		ast.nodes[frame.last].next_sibling = id
	}
	frame.previous, frame.last = frame.last, id
	return id, {}
}

@(private="file")
regex_ast_read_decimal :: proc(pattern: string, start: int) -> (RegexRepeatBound, int) {
	result := RegexRepeatBound{digits = {start = u32(start)}}
	end := start
	for end < len(pattern) && pattern[end] >= '0' && pattern[end] <= '9' {
		digit := u64(pattern[end] - '0')
		if result.value > (max(u64) - digit) / 10 {
			result.overflow = true
		}
		if !result.overflow { result.value = 10 * result.value + digit }
		end += 1
	}
	result.digits.end = u32(end)
	return result, end
}

@(private="file")
regex_ast_quantifier :: proc(ast: ^RegexAst, frame: ^RegexAstFrame, pattern: string, start: int) -> (int, RegexAstError) {
	if frame.last_term == 0 { return 0, regex_ast_invalid(start, "Quantifier without preceding term") }
	term := ast.nodes[frame.last_term]
	#partial switch term.kind {
	case .Quantifier, .Start_Assertion, .End_Assertion, .Boundary_Assertion:
		return 0, regex_ast_invalid(start, "Term cannot be quantified")
	}
	if term.kind == .Group {
		group := term.group_kind
		if group == .Lookbehind || group == .Negative_Lookbehind ||
		   ((group == .Lookahead || group == .Negative_Lookahead) &&
		    (.Unicode in ast.flags || .Unicode_Sets in ast.flags)) {
			return 0, regex_ast_invalid(start, "Assertion cannot be quantified in this mode")
		}
	}
	repeat, end := regex_ast_repeat(pattern, start)
	if max_bound, finite := repeat.max.?; finite {
		if regex_ast_bound_exceeds(repeat.min, max_bound, pattern) {
			return 0, regex_ast_invalid(start, "Quantifier minimum exceeds maximum")
		}
	}
	wrapper, err := regex_ast_push(ast, {
		kind = .Quantifier, span = {term.span.start, u32(end)},
		repeat = repeat, first_child = frame.last_term,
	})
	if err.kind != .None { return 0, err }
	if frame.previous_term == 0 {
		ast.nodes[frame.alternative].first_child = wrapper
	} else {
		ast.nodes[frame.previous_term].next_sibling = wrapper
	}
	frame.last_term = wrapper
	return end, {}
}

@(private="file")
regex_ast_repeat :: proc(pattern: string, start: int) -> (RegexRepeat, int) {
	repeat := RegexRepeat{greedy = true}
	end := start + 1
	switch pattern[start] {
	case '+': repeat.min.value = 1
	case '?': repeat.max = RegexRepeatBound{value = 1}
	case '{':
		repeat.min, end = regex_ast_read_decimal(pattern, end)
		if pattern[end] == ',' {
			end += 1
			if pattern[end] != '}' {
				maximum, max_end := regex_ast_read_decimal(pattern, end)
				repeat.max, end = maximum, max_end
			}
		} else {
			repeat.max = repeat.min
		}
		end += 1
	}
	if end < len(pattern) && pattern[end] == '?' {
		repeat.greedy = false
		end += 1
	}
	return repeat, end
}

@(private="file")
regex_ast_bound_exceeds :: proc(minimum, maximum: RegexRepeatBound, pattern: string) -> bool {
	if !minimum.overflow && !maximum.overflow { return minimum.value > maximum.value }
	if minimum.overflow != maximum.overflow { return minimum.overflow }
	left := strings.trim_left(pattern[minimum.digits.start:minimum.digits.end], "0")
	right := strings.trim_left(pattern[maximum.digits.start:maximum.digits.end], "0")
	if len(left) != len(right) { return len(left) > len(right) }
	return left > right
}

@(private="file")
regex_ast_invalid :: proc(offset: int, message: string) -> RegexAstError {
	return {kind = .Invalid_Pattern, offset = u32(offset), message = message}
}


@(private)
cli_regexp_ast :: proc(args: []string) -> int {
	if len(args) != 1 && (len(args) != 3 || args[1] != "--flags") {
		fmt.eprintln("Usage: kessel regexp <pattern> [--flags <flags>]")
		return 2
	}
	flags := ""
	if len(args) == 3 { flags = args[2] }
	ast, err := regex_parse_ast(args[0], flags, context.allocator)
	if err.kind != .None {
		fmt.eprintf("Error: %v at byte %d (%s)\n", err.kind, err.offset, err.message)
		return 1
	}
	defer regex_ast_destroy(&ast)
	encoded, json_err := json.marshal(ast, {use_enum_names = true}, allocator = context.temp_allocator)
	if json_err != nil {
		fmt.eprintln("Error: could not encode regexp tree")
		return 1
	}
	out_println(string(encoded))
	return 0
}
