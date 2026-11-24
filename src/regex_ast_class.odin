package kessel

// Character classes for the regexp tree builder. See regex_ast.odin for the
// overall shape.
//
// Two grammars share the `[`…`]` brackets:
//   regex_ast_class_legacy  ClassContents: atoms and `a-z` ranges. Used without
//                           flags and with `u`. `[` inside is a literal.
//   regex_ast_class_sets    ClassSetExpression (`v` flag): nested classes,
//                           `\q{…}` strings, `&&` and `--`, and a much smaller
//                           set of characters that may appear unescaped.

RegexClassFrame :: struct {
	container, previous, last: u32,
	operands: u32,
	relation: RegexClassRelation,
	needs_operand: bool,
	// The last member closed an Annex B `\d-a` group, so a following `-` cannot
	// make it the low end of a range.
	sealed: bool,
}

@(private="file")
regex_ast_is_class_character :: proc(node: RegexAstNode) -> bool {
	return node.kind == .Character || node.kind == .Escape
}

@(private="file")
regex_ast_open_class :: proc(ast: ^RegexAst, id: u32, pattern: string, start: int) -> int {
	assert(pattern[start] == '[')
	cursor := start + 1
	if cursor < len(pattern) && pattern[cursor] == '^' {
		ast.nodes[id].negative = true
		cursor += 1
	}
	return cursor
}

@(private="file")
regex_ast_class_child :: proc(
	ast: ^RegexAst,
	frame: ^RegexClassFrame,
	node: RegexAstNode,
) -> (u32, RegexAstError) {
	id, err := regex_ast_push(ast, node)
	if err.kind != .None { return 0, err }
	if frame.last == 0 {
		ast.nodes[frame.container].first_child = id
	} else {
		ast.nodes[frame.last].next_sibling = id
	}
	frame.previous, frame.last = frame.last, id
	frame.sealed = false
	return id, {}
}

// Append a member, splitting an astral character into its two code units when
// the pattern has no `u`/`v` flag.
@(private="file")
regex_ast_class_member :: proc(
	p: ^RegexAstParser,
	frame: ^RegexClassFrame,
	node: RegexAstNode,
) -> (u32, RegexAstError) {
	first, second := regex_ast_code_units(p, node)
	id, err := regex_ast_class_child(p.ast, frame, first)
	if err.kind != .None { return 0, err }
	if trailing, ok := second.?; ok {
		_, trailing_err := regex_ast_class_child(p.ast, frame, trailing)
		if trailing_err.kind != .None { return 0, trailing_err }
	}
	return id, {}
}

// ClassAtom of the legacy grammar: any character except `]`, or an escape.
@(private="file")
regex_ast_class_atom :: proc(p: ^RegexAstParser, start: int) -> (RegexAstNode, int, RegexAstError) {
	if p.pattern[start] == '\\' { return regex_ast_escape(p, start, true) }
	return regex_ast_source_character(p.pattern, start, .Character)
}

@(private)
regex_ast_class_legacy :: proc(p: ^RegexAstParser, id: u32, start: int) -> (int, RegexAstError) {
	ast, pattern := p.ast, p.pattern
	assert(!p.unicode_sets)
	frame := RegexClassFrame{container = id}
	for cursor := regex_ast_open_class(ast, id, pattern, start); cursor < len(pattern); {
		if pattern[cursor] == ']' {
			ast.nodes[id].span.end = u32(cursor + 1)
			return cursor + 1, {}
		}
		if pattern[cursor] == '-' {
			next, range_err := regex_ast_class_range(p, &frame, cursor)
			if range_err.kind != .None { return 0, range_err }
			if next != cursor {
				cursor = next
				continue
			}
		}
		node, next, parse_err := regex_ast_class_atom(p, cursor)
		if parse_err.kind != .None { return 0, parse_err }
		assert(next > cursor)
		cursor = next
		if _, err := regex_ast_class_member(p, &frame, node); err.kind != .None { return 0, err }
	}
	return 0, regex_ast_invalid(start, "Unterminated character class")
}

// Handle the `-` at `start` as `ClassAtom - ClassAtom`. Returns `start`
// unchanged when the `-` is an ordinary member (first, last, or after a range).
//
// When either side is a class escape such as `\d`, UnicodeMode rejects the
// pattern and Annex B keeps all three as members: `[\d-a]` is `\d`, `-`, `a`.
// The right-hand atom is consumed either way, so `[\d-a-z]` holds no range.
@(private="file")
regex_ast_class_range :: proc(
	p: ^RegexAstParser,
	frame: ^RegexClassFrame,
	start: int,
) -> (int, RegexAstError) {
	ast, pattern := p.ast, p.pattern
	if frame.last == 0 || frame.sealed { return start, {} }
	if start + 1 == len(pattern) || pattern[start + 1] == ']' { return start, {} }
	left := ast.nodes[frame.last]
	if left.kind == .Class_Range { return start, {} }
	atom, next, parse_err := regex_ast_class_atom(p, start + 1)
	if parse_err.kind != .None { return 0, parse_err }
	right, trailing := regex_ast_code_units(p, atom)
	if !regex_ast_is_class_character(left) || !regex_ast_is_class_character(right) {
		if p.unicode { return 0, regex_ast_invalid(start, "Character class escape in a range") }
		dash := RegexAstNode{
			kind = .Character, span = {u32(start), u32(start + 1)}, code_point = u32('-'),
		}
		if _, err := regex_ast_class_child(ast, frame, dash); err.kind != .None { return 0, err }
		if _, err := regex_ast_class_member(p, frame, atom); err.kind != .None { return 0, err }
		frame.sealed = true
		return next, {}
	}
	if err := regex_ast_class_make_range(ast, frame, right, start); err.kind != .None {
		return 0, err
	}
	if unit, ok := trailing.?; ok {
		if _, err := regex_ast_class_child(ast, frame, unit); err.kind != .None { return 0, err }
	}
	return next, {}
}

// Replace the last member (the low end) with a Class_Range that owns it and
// the high end. `dash` is the offset of the `-`, used for diagnostics.
@(private="file")
regex_ast_class_make_range :: proc(
	ast: ^RegexAst,
	frame: ^RegexClassFrame,
	right: RegexAstNode,
	dash: int,
) -> RegexAstError {
	left := ast.nodes[frame.last]
	assert(regex_ast_is_class_character(left))
	assert(regex_ast_is_class_character(right))
	assert(left.next_sibling == 0)
	if left.code_point.? > right.code_point.? {
		return regex_ast_invalid(dash, "Character class range is reversed")
	}
	right_id, right_err := regex_ast_push(ast, right)
	if right_err.kind != .None { return right_err }
	range_id, range_err := regex_ast_push(ast, {
		kind = .Class_Range, span = {left.span.start, right.span.end}, first_child = frame.last,
	})
	if range_err.kind != .None { return range_err }
	ast.nodes[frame.last].next_sibling = right_id
	if frame.previous == 0 {
		ast.nodes[frame.container].first_child = range_id
	} else {
		ast.nodes[frame.previous].next_sibling = range_id
	}
	frame.last = range_id
	return {}
}

// ClassSetSyntaxCharacter: never a literal in a `v`-mode class.
@(private="file")
regex_ast_is_set_syntax_character :: proc(ch: u8) -> bool {
	switch ch {
	case '(', ')', '[', ']', '{', '}', '/', '-', '\\', '|': return true
	}
	return false
}

// ClassSetReservedDoublePunctuator starts at `start`: the same reserved
// punctuator twice. `&&` is included; the caller takes operators first.
@(private="file")
regex_ast_is_double_punctuator :: proc(pattern: string, start: int) -> bool {
	if start + 1 >= len(pattern) || pattern[start] != pattern[start + 1] { return false }
	switch pattern[start] {
	case '&', '!', '#', '$', '%', '*', '+', ',', '.', ':', ';', '<', '=', '>', '?', '@', '^', '`':
		return true
	case '~':
		return true
	}
	return false
}

// ClassSetCharacter: a literal that is not reserved, or a single-character
// escape. Used for range ends and inside `\q{…}`.
@(private="file")
regex_ast_set_character :: proc(
	p: ^RegexAstParser,
	start: int,
) -> (RegexAstNode, int, RegexAstError) {
	pattern := p.pattern
	if pattern[start] == '\\' {
		node, next, err := regex_ast_escape(p, start, true)
		if err.kind != .None { return {}, 0, err }
		if node.kind != .Escape {
			return {}, 0, regex_ast_invalid(start, "Expected a single character")
		}
		return node, next, {}
	}
	if regex_ast_is_set_syntax_character(pattern[start]) {
		return {}, 0, regex_ast_invalid(start, "Unescaped syntax character in a Unicode set")
	}
	if regex_ast_is_double_punctuator(pattern, start) {
		return {}, 0, regex_ast_invalid(start, "Reserved double punctuator in a Unicode set")
	}
	return regex_ast_source_character(pattern, start, .Character)
}

@(private)
regex_ast_class_sets :: proc(p: ^RegexAstParser, id: u32, start: int) -> (int, RegexAstError) {
	ast, pattern := p.ast, p.pattern
	assert(p.unicode_sets)
	frames: [REGEX_AST_DEPTH_MAX]RegexClassFrame
	frames[0] = {container = id}
	depth := 1
	for cursor := regex_ast_open_class(ast, id, pattern, start); cursor < len(pattern); {
		frame := &frames[depth - 1]
		switch {
		case pattern[cursor] == ']':
			cursor += 1
			err := regex_ast_class_finish(ast, frame, cursor)
			if err.kind != .None { return 0, err }
			depth -= 1
			if depth == 0 { return cursor, {} }
		case pattern[cursor] == '[':
			if depth == len(frames) { return 0, {kind = .Depth_Limit, offset = u32(cursor)} }
			if err := regex_ast_class_operand(frame, cursor); err.kind != .None { return 0, err }
			nested := RegexAstNode{kind = .Character_Class, span = {start = u32(cursor)}}
			node, err := regex_ast_class_child(ast, frame, nested)
			if err.kind != .None { return 0, err }
			frames[depth] = {container = node}
			depth += 1
			cursor = regex_ast_open_class(ast, node, pattern, cursor)
		case regex_ast_is_set_operator(pattern, cursor):
			err := regex_ast_class_operator(p, frame, cursor)
			if err.kind != .None { return 0, err }
			cursor += 2
		case:
			next, err := regex_ast_set_member(p, frame, cursor)
			if err.kind != .None { return 0, err }
			assert(next > cursor)
			cursor = next
		}
	}
	return 0, regex_ast_invalid(start, "Unterminated character class")
}

@(private="file")
regex_ast_is_set_operator :: proc(pattern: string, start: int) -> bool {
	if start + 1 >= len(pattern) { return false }
	two := pattern[start:start + 2]
	return two == "&&" || two == "--"
}

// One ClassSetOperand or ClassSetRange that starts with something other than `[`.
@(private="file")
regex_ast_set_member :: proc(
	p: ^RegexAstParser,
	frame: ^RegexClassFrame,
	start: int,
) -> (int, RegexAstError) {
	pattern := p.pattern
	if err := regex_ast_class_operand(frame, start); err.kind != .None { return 0, err }
	if start + 2 < len(pattern) && pattern[start:start + 3] == "\\q{" {
		return regex_ast_class_string(p, frame, start)
	}
	node: RegexAstNode
	next: int
	err: RegexAstError
	if pattern[start] == '\\' {
		// `\d` and `\p{…}` are operands too, so any class escape is allowed here.
		node, next, err = regex_ast_escape(p, start, true)
	} else {
		node, next, err = regex_ast_set_character(p, start)
	}
	if err.kind != .None { return 0, err }
	if _, push_err := regex_ast_class_child(p.ast, frame, node); push_err.kind != .None {
		return 0, push_err
	}
	// A single `-` after a character makes a range; `--` is the subtraction operator.
	ranged := next < len(pattern) && pattern[next] == '-' &&
	          !regex_ast_is_set_operator(pattern, next)
	if !ranged { return next, {} }
	if node.kind != .Escape && node.kind != .Character {
		return 0, regex_ast_invalid(next, "Character class escape in a range")
	}
	if frame.relation != .Union {
		return 0, regex_ast_invalid(next, "Range cannot be a Unicode set operand")
	}
	if next + 1 == len(pattern) { return 0, regex_ast_invalid(next, "Unterminated range") }
	right, range_end, right_err := regex_ast_set_character(p, next + 1)
	if right_err.kind != .None { return 0, right_err }
	if range_err := regex_ast_class_make_range(p.ast, frame, right, next); range_err.kind != .None {
		return 0, range_err
	}
	return range_end, {}
}

// Close the class in `frame`; `end` is the offset past its `]`.
@(private="file")
regex_ast_class_finish :: proc(ast: ^RegexAst, frame: ^RegexClassFrame, end: int) -> RegexAstError {
	if frame.needs_operand {
		return regex_ast_invalid(end - 1, "Missing Unicode set operand")
	}
	class := &ast.nodes[frame.container]
	class.span.end = u32(end)
	class.class_relation = frame.relation
	// MayContainStrings: a union does if any member does, an intersection only
	// if every member does, and a subtraction if its first member does.
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

// Account for an operand that starts at `cursor`. Inside `&&` or `--`
// expressions every operand must follow an operator.
@(private="file")
regex_ast_class_operand :: proc(frame: ^RegexClassFrame, cursor: int) -> RegexAstError {
	if frame.relation != .Union && !frame.needs_operand {
		return regex_ast_invalid(cursor, "Unicode set operands require an explicit operator")
	}
	frame.operands += 1
	frame.needs_operand = false
	return {}
}

// Record the `&&` or `--` at `cursor`. The two operators cannot mix, and the
// left side must be exactly one operand that is not a range.
@(private="file")
regex_ast_class_operator :: proc(
	p: ^RegexAstParser,
	frame: ^RegexClassFrame,
	cursor: int,
) -> RegexAstError {
	pattern := p.pattern
	intersection := pattern[cursor] == '&'
	relation := RegexClassRelation.Intersection if intersection else RegexClassRelation.Subtraction
	if frame.relation == .Union {
		if frame.operands != 1 || p.ast.nodes[frame.last].kind == .Class_Range {
			return regex_ast_invalid(cursor, "Invalid left operand for Unicode set operator")
		}
		frame.relation = relation
	} else if frame.relation != relation || frame.needs_operand {
		return regex_ast_invalid(cursor, "Invalid Unicode set operator")
	}
	// ClassIntersection: `&&` [lookahead ≠ `&`] ClassSetOperand.
	if intersection && cursor + 2 < len(pattern) && pattern[cursor + 2] == '&' {
		return regex_ast_invalid(cursor + 2, "Unexpected '&' after '&&'")
	}
	frame.needs_operand = true
	kind := RegexAstKind.Class_Intersection if intersection else RegexAstKind.Class_Subtraction
	operator := RegexAstNode{kind = kind, span = {u32(cursor), u32(cursor + 2)}}
	_, err := regex_ast_class_child(p.ast, frame, operator)
	return err
}

// `\q{a|bc}`: a Class_String whose children are Alternative nodes, one per
// string, each holding the string's characters.
@(private="file")
regex_ast_class_string :: proc(
	p: ^RegexAstParser,
	class_frame: ^RegexClassFrame,
	start: int,
) -> (int, RegexAstError) {
	ast, pattern := p.ast, p.pattern
	node := RegexAstNode{kind = .Class_String, span = {start = u32(start)}}
	id, push_err := regex_ast_class_child(ast, class_frame, node)
	if push_err.kind != .None { return 0, push_err }
	frame := RegexAstFrame{container = id}
	body := start + 3
	if err := regex_ast_new_alternative(ast, &frame, body); err.kind != .None { return 0, err }
	many := false // Some string is empty or longer than one character.
	length := 0
	for cursor := body; cursor < len(pattern); {
		if pattern[cursor] == '|' || pattern[cursor] == '}' {
			ast.nodes[frame.alternative].span.end = u32(cursor)
			many = many || length != 1
			length = 0
			cursor += 1
			if pattern[cursor - 1] == '}' {
				ast.nodes[id].span.end = u32(cursor)
				ast.nodes[id].name = {u32(body), u32(cursor - 1)}
				ast.nodes[id].may_contain_strings = many
				return cursor, {}
			}
			err := regex_ast_new_alternative(ast, &frame, cursor)
			if err.kind != .None { return 0, err }
			continue
		}
		character, next, parse_err := regex_ast_set_character(p, cursor)
		if parse_err.kind != .None { return 0, parse_err }
		assert(next > cursor)
		cursor = next
		length += 1
		_, err := regex_ast_append_term(ast, &frame, character)
		if err.kind != .None { return 0, err }
	}
	return 0, regex_ast_invalid(start, "Unterminated class string")
}
