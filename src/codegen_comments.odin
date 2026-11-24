package kessel

import "core:mem"
import "core:strings"
import "core:unicode/utf8"

CodegenCommentKind :: enum { Ordinary, Legal, Source_Map, Pure, No_Side_Effects }
CodegenAnnotations :: bit_set[CodegenCommentKind; u8]

codegen_comment_kind :: proc(comment: Comment) -> CodegenCommentKind {
	content := strings.trim_space(comment.value)
	switch content {
	case "#__PURE__", "@__PURE__": return .Pure
	case "#__NO_SIDE_EFFECTS__", "@__NO_SIDE_EFFECTS__": return .No_Side_Effects
	}
	if len(content) > 1 && (content[0] == '#' || content[0] == '@') {
		if strings.has_prefix(strings.trim_space(content[1:]), "sourceMappingURL") { return .Source_Map }
	}
	if strings.has_prefix(comment.value, "!") ||
	   strings.contains(comment.value, "@license") ||
	   strings.contains(comment.value, "@preserve") {
		return .Legal
	}
	return .Ordinary
}

// The lexer provides comment spans in source order. Find the next token
// after each run of comments without rescanning the run for every marker.
codegen_index_annotations :: proc(cg: ^Codegen, comments: []Comment, allocator: mem.Allocator) {
	next_start, anchor := len(cg.source), len(cg.source)
	for index := len(comments) - 1; index >= 0; index -= 1 {
		comment := comments[index]
		after := codegen_skip_comment_whitespace(cg.source, int(comment.end))
		if after != next_start { anchor = after }
		next_start = int(comment.start)
		if anchor >= len(cg.source) { continue }
		annotation := codegen_comment_kind(comment)
		if annotation != .Pure && annotation != .No_Side_Effects { continue }
		if cg.annotations == nil {
			cg.annotations = make(map[u32]CodegenAnnotations, allocator)
		}
		cg.annotations[u32(anchor)] = cg.annotations[u32(anchor)] + {annotation}
	}
}

codegen_skip_comment_whitespace :: proc(source: string, start: int) -> int {
	offset := start
	for offset < len(source) {
		code_point, width := utf8.decode_rune_in_string(source[offset:])
		switch code_point {
		case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680,
		     0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
		case:
			if code_point < 0x2000 || code_point > 0x200A { return offset }
		}
		offset += width
	}
	return offset
}

codegen_emit_legal_comments :: proc(cg: ^Codegen, comments: []Comment, jsx_directives := false) {
	for comment in comments {
		if codegen_comment_kind(comment) != .Legal && !(jsx_directives && jsx_comment_has_pragma(comment)) { continue }
		codegen_emit_comment(cg, comment)
		if comment.type == .Block { cg_newline(cg) }
	}
}

codegen_emit_comment :: proc(cg: ^Codegen, comment: Comment) {
	switch comment.type {
	case .Line:
		cg_str(cg, "//")
		cg_str(cg, comment.value)
		// Keep the next statement outside the line comment in both modes.
		cg_byte(cg, '\n')
		cg.at_line_start = true
	case .Block:
		cg_str(cg, "/*")
		cg_str(cg, comment.value)
		cg_str(cg, "*/")
	}
}

codegen_comments_in_body :: proc(cg: ^Codegen, body: Loc) -> []Comment {
	if cg.cfg.minified || len(cg.comments) == 0 || body.start >= body.end { return nil }
	start := codegen_comment_lower_bound(cg.comments, body.start + 1)
	end := codegen_comment_lower_bound(cg.comments, body.end)
	return cg.comments[start:end]
}

codegen_comment_lower_bound :: proc(comments: []Comment, offset: u32) -> int {
	low, high := 0, len(comments)
	for low < high {
		middle := (low + high) / 2
		if comments[middle].start < offset { low = middle + 1 }
		else { high = middle }
	}
	return low
}

codegen_has_ordinary_comments :: proc(comments: []Comment) -> bool {
	for comment in comments {
		if codegen_comment_kind(comment) == .Ordinary { return true }
	}
	return false
}

// A nested expression or method prints its own comments. Only a comment
// between items requires the enclosing list to use multiple lines.
codegen_has_list_comments :: proc(items: []$T, comments: []Comment) -> bool {
	pending := comments
	for item in items {
		if len(pending) == 0 { return false }
		loc := codegen_list_item_loc(item)
		if pending[0].start < loc.start {
			boundary := codegen_comment_lower_bound(pending, loc.start)
			if codegen_has_ordinary_comments(pending[:boundary]) { return true }
			pending = pending[boundary:]
		}
		if len(pending) > 0 && pending[0].start < loc.end {
			pending = pending[codegen_comment_lower_bound(pending, loc.end):]
		}
	}
	return codegen_has_ordinary_comments(pending)
}

codegen_list_item_loc :: #force_inline proc(item: $T) -> Loc {
	when T == ^Statement { return get_statement_loc(item) }
	else when T == ^Expression { return loc_from_expr(item) }
	else { return item.loc }
}

// The AST spans the entire call. Locate the opening parenthesis in the gap
// after the callee or type arguments, skipping parentheses inside comments.
codegen_argument_comments :: proc(cg: ^Codegen, start, end: u32) -> []Comment {
	if len(cg.comments) == 0 || start >= end { return nil }
	first := codegen_comment_lower_bound(cg.comments, start)
	if first == len(cg.comments) || cg.comments[first].start >= end { return nil }
	last := first + codegen_comment_lower_bound(cg.comments[first:], end)
	comments := cg.comments[first:last]
	cursor := start
	for comment, index in comments {
		if strings.index_byte(cg.source[cursor:comment.start], '(') >= 0 { return comments[index:] }
		cursor = comment.end
	}
	return nil
}

// Bundlers read these directives at the dynamic import site. Keep them
// beside the same argument even when ordinary comments and spaces disappear.
codegen_emit_import_hints :: proc(cg: ^Codegen, comments: []Comment, start, end: u32, needs_comma: bool) {
	cursor := start
	comma := needs_comma
	first := codegen_comment_lower_bound(comments, start)
	for comment in comments[first:] {
		if comment.start >= end { break }
		if comma && strings.index_byte(cg.source[cursor:comment.start], ',') >= 0 {
			cg_byte(cg, ',')
			comma = false
		}
		if codegen_is_import_hint(comment) { codegen_emit_comment(cg, comment) }
		cursor = comment.end
	}
	if comma { cg_byte(cg, ',') }
}

codegen_is_import_hint :: proc(comment: Comment) -> bool {
	if codegen_comment_kind(comment) != .Ordinary { return false }
	text := strings.trim_space(comment.value)
	if strings.has_prefix(text, "@vite") { return true }
	BUNDLERS :: [?]string{"webpack", "turbopack"}
	for prefix in BUNDLERS {
		if len(text) > len(prefix) && strings.has_prefix(text, prefix) {
			ch := text[len(prefix)]
			return ch >= 'A' && ch <= 'Z'
		}
	}
	return false
}

codegen_emit_leading_comments :: proc(cg: ^Codegen, items: []$T, comments: []Comment, index: ^int, start, end: u32) {
	if len(comments) == 0 { return }
	boundary := end
	if len(items) > 0 { boundary = codegen_list_item_loc(items[0]).start }
	position := cg.pos
	codegen_emit_comment_gap(cg, comments, index, start, boundary, false)
	if cg.pos != position && !cg.at_line_start { cg_newline(cg) }
}

codegen_end_item_line :: proc(cg: ^Codegen, items: []$T, item_index: int, comments: []Comment, index: ^int, end: u32, erased := false, insert_offset: ^int = nil) {
	position := cg.pos
	if index^ < len(comments) {
		boundary := end
		if item_index + 1 < len(items) {
			boundary = codegen_list_item_loc(items[item_index + 1]).start
		}
		start := codegen_list_item_loc(items[item_index]).end
		codegen_emit_comment_gap(cg, comments, index, start, boundary, !erased, insert_offset)
	}
	if erased && cg.pos == position { return }
	if cg.pos == position || !cg.at_line_start { cg_newline(cg) }
}

// Only comments in the gap belong here. A nested body owns its own gaps.
codegen_emit_comment_gap :: proc(cg: ^Codegen, comments: []Comment, index: ^int, start, end: u32, follows_statement: bool, insert_offset: ^int = nil) {
	last_source_end := start
	if index^ < len(comments) && comments[index^].start < start {
		index^ += codegen_comment_lower_bound(comments[index^:], start)
	}
	for index^ < len(comments) && comments[index^].start < end {
		comment := comments[index^]
		index^ += 1
		if comment.start < start || comment.end > end { continue }
		if codegen_comment_kind(comment) != .Ordinary { continue }
		same_line := follows_statement && !codegen_has_line_break(cg.source[last_source_end:comment.start])
		if !cg.at_line_start && cg.pos > 0 && cg.buf[cg.pos - 1] != '\n' {
			if same_line {
				cg_hard_space(cg)
			} else {
				cg_newline(cg)
			}
		}
		if insert_offset != nil && insert_offset^ < 0 && !same_line { insert_offset^ = cg.pos }
		codegen_emit_comment(cg, comment)
		last_source_end = comment.end
	}
}

codegen_has_line_break :: proc(source: string) -> bool {
	for code_point in source {
		switch code_point {
		case '\r', '\n', 0x2028, 0x2029: return true
		}
	}
	return false
}

codegen_emit_annotation :: proc(cg: ^Codegen, offset: u32, annotation: CodegenCommentKind) {
	annotations, exists := cg.annotations[offset]
	if !exists || annotation not_in annotations { return }
	// Several nested expressions can share a starting offset.
	// Emit each marker once at the outermost eligible node.
	cg.annotations[offset] = annotations - {annotation}
	codegen_write_annotation(cg, offset, annotation)
}

codegen_write_annotation :: proc(cg: ^Codegen, offset: u32, annotation: CodegenCommentKind) {
	// After division, two adjacent slashes would start a line comment.
	if cg.pos != 0 && cg.buf[cg.pos-1] == '/' { cg_hard_space(cg) }
	#partial switch annotation {
	case .Pure: cg_str(cg, "/*#__PURE__*/")
	case .No_Side_Effects: cg_str(cg, "/*#__NO_SIDE_EFFECTS__*/")
	}
	cg_space(cg)
	sourcemap_record(cg.sm, u32(cg.pos), offset)
}

codegen_emit_expression_annotation :: proc(cg: ^Codegen, expr: ^Expression) {
	target := expr
	for target != nil {
		parenthesized, wrapped := target^.(^ParenthesizedExpression)
		if !wrapped || parenthesized == nil { break }
		target = parenthesized.expression
	}
	if target == nil { return }
	#partial switch _ in target^ {
	case ^CallExpression, ^NewExpression: codegen_emit_annotation(cg, loc_from_expr(expr).start, .Pure)
	case ^FunctionExpression, ^ArrowFunctionExpression: codegen_emit_annotation(cg, loc_from_expr(expr).start, .No_Side_Effects)
	}
}

codegen_emit_export_annotation :: proc(cg: ^Codegen, offset: u32, declaration: ^Declaration) {
	if declaration == nil { return }
	if _, is_function := declaration^.(^FunctionDeclaration); is_function {
		codegen_emit_annotation(cg, offset, .No_Side_Effects)
	}
}
