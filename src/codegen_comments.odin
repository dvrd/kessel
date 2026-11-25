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
// between items that ends or spans a source line requires the enclosing list
// to use one line per item; other block comments are printed inline.
codegen_has_list_comments :: proc(cg: ^Codegen, items: []$T, end: u32) -> bool {
	if cg.comment_next >= end { return false }
	pending := cg.comments[cg.comment_cursor:]
	pending = pending[:codegen_comment_lower_bound(pending, end)]
	for item in items {
		if len(pending) == 0 { return false }
		loc := codegen_list_item_loc(item)
		if pending[0].start < loc.start {
			boundary := codegen_comment_lower_bound(pending, loc.start)
			if codegen_has_breaking_comments(cg, pending[:boundary]) { return true }
			pending = pending[boundary:]
		}
		if len(pending) > 0 && pending[0].start < loc.end {
			inside := codegen_comment_lower_bound(pending, loc.end)
			if codegen_has_breaking_tail(cg, pending[:inside], loc.end) { return true }
			pending = pending[inside:]
		}
	}
	return codegen_has_breaking_comments(cg, pending)
}

// Grouping parentheses that the AST does not record are not printed. A
// comment before such a closing parenthesis at the very end of an item
// therefore leaves the item and is printed after it, between the items. Any
// tail made only of parentheses and the trailing commas the printer drops is
// treated alike, printed or not, so that the layout chosen for the source is
// also the layout chosen for the output.
codegen_has_breaking_tail :: proc(cg: ^Codegen, inside: []Comment, item_end: u32) -> bool {
	tail_end := item_end
	for index := len(inside) - 1; index >= 0; index -= 1 {
		comment := inside[index]
		for offset in comment.end..<tail_end {
			switch cg.source[offset] {
			case ' ', '\t', '\n', '\r', '(', ')', ',':
			case: return false
			}
		}
		if codegen_has_breaking_comments(cg, inside[index:index + 1]) { return true }
		tail_end = comment.start
	}
	return false
}

codegen_has_breaking_comments :: proc(cg: ^Codegen, comments: []Comment) -> bool {
	for comment in comments {
		if codegen_comment_kind(comment) != .Ordinary { continue }
		if codegen_comment_breaks(cg.source, comment) { return true }
	}
	return false
}

// A comment that cannot share its line with the code around it: a line
// comment, a block comment over several lines, or a block comment that has a
// source line to itself. Printing keeps each of these properties, which is
// what makes a layout chosen from them stable when the output is printed again.
codegen_comment_breaks :: proc(source: string, comment: Comment) -> bool {
	if comment.type == .Line || codegen_has_line_break(comment.value) { return true }
	if !codegen_comment_ends_line(source, comment) { return false }
	_, begins_line := codegen_source_column(source, comment.start)
	return begins_line
}

codegen_list_item_loc :: #force_inline proc(item: $T) -> Loc {
	when T == ^Statement { return get_statement_loc(item) }
	else when T == ^TSSignature { return codegen_signature_loc(item) }
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

codegen_emit_leading_comments :: proc(cg: ^Codegen, items: []$T, start, end: u32) {
	if cg.comment_next >= end { return }
	boundary := end
	if len(items) > 0 { boundary = codegen_list_item_loc(items[0]).start }
	position := cg.pos
	codegen_emit_comment_gap(cg, start, boundary, false, before_item = len(items) > 0)
	if cg.pos != position && !cg.at_line_start { cg_newline(cg) }
}

codegen_end_item_line :: proc(
	cg: ^Codegen, items: []$T, item_index: int, end: u32, erased := false,
	insert_offset: ^int = nil,
) {
	position := cg.pos
	if cg.comment_next < end {
		boundary := end
		if item_index + 1 < len(items) {
			boundary = codegen_list_item_loc(items[item_index + 1]).start
		}
		start := codegen_list_item_loc(items[item_index]).end
		// Nothing was printed for an erased item, so nothing inside it has a home.
		if erased { codegen_skip_comments(cg, start) }
		before_item := item_index + 1 < len(items)
		codegen_emit_comment_gap(cg, start, boundary, !erased, insert_offset, before_item)
	}
	if erased && cg.pos == position { return }
	if cg.pos == position || !cg.at_line_start { cg_newline(cg) }
}

// Print every pending comment before `end`, one per line unless it trails the
// previous item on its source line. Comments that begin before `start` sat at
// a position inside the previous item that no printer site claimed; they
// trail that item so that they are kept and stay next to it.
//
// With `before_item` an item begins at `end`. Block comments that share its
// first line are left pending: the item prints them inline, in front of itself.
codegen_emit_comment_gap :: proc(
	cg: ^Codegen, start, end: u32, follows_statement: bool, insert_offset: ^int = nil,
	before_item := false,
) {
	last_source_end := start
	// Comments that shared a source line keep sharing one.
	joins := follows_statement
	for cg.comment_next < end {
		if before_item && codegen_comments_lead(cg, end) { break }
		comment := codegen_take_comment(cg)
		same_line := joins
		joins = comment.type == .Block
		if comment.start >= last_source_end {
			same_line &&= !codegen_has_line_break(cg.source[last_source_end:comment.start])
		} else if same_line {
			// A straggler that had a line to itself keeps one.
			_, begins_line := codegen_source_column(cg.source, comment.start)
			same_line = !begins_line
		}
		if !cg.at_line_start && cg.pos > 0 && cg.buf[cg.pos - 1] != '\n' {
			if same_line {
				cg_hard_space(cg)
			} else {
				cg_newline(cg)
			}
		}
		if insert_offset != nil && insert_offset^ < 0 && !same_line { insert_offset^ = cg.pos }
		codegen_emit_comment(cg, comment)
		last_source_end = max(last_source_end, comment.end)
	}
}

// True when the pending comment and every comment after it up to `end` is a
// block comment on the same source line as the token at `end`.
codegen_comments_lead :: proc(cg: ^Codegen, end: u32) -> bool {
	for index := cg.comment_cursor; index < len(cg.comments); index += 1 {
		comment := cg.comments[index]
		if comment.start >= end { return true }
		if comment.type != .Block || codegen_has_line_break(comment.value) { return false }
		after := codegen_skip_comment_whitespace(cg.source, int(comment.end))
		if codegen_has_line_break(cg.source[comment.end:after]) { return false }
		if u32(after) == end { return true }
		if index + 1 == len(cg.comments) { return false }
		if cg.comments[index + 1].start != u32(after) { return false }
	}
	return false
}

// Sentinel for "no ordinary comment is waiting": larger than any source offset
// a node can start at, so the printer's fast path is a single comparison.
CODEGEN_COMMENT_NONE :: max(u32)

// Pretty output owes the reader every ordinary comment. The cursor hands each
// one to exactly one printer site, in source order. Minified output drops
// ordinary comments, so its cursor never starts.
codegen_comments_begin :: proc(cg: ^Codegen, comments: []Comment) {
	cg.comments = comments
	cg.comment_cursor = 0
	cg.comment_next = CODEGEN_COMMENT_NONE
	if !cg.cfg.minified { codegen_comment_seek(cg) }
}

// Legal notices, annotations and source-map comments have their own rules.
codegen_comment_seek :: proc(cg: ^Codegen) {
	for cg.comment_cursor < len(cg.comments) {
		comment := cg.comments[cg.comment_cursor]
		// Comments are disjoint and sorted. An overlap is a repeated entry.
		repeated := cg.comment_cursor > 0 && comment.start < cg.comments[cg.comment_cursor - 1].end
		if !repeated && codegen_comment_kind(comment) == .Ordinary {
			cg.comment_next = comment.start
			return
		}
		cg.comment_cursor += 1
	}
	cg.comment_next = CODEGEN_COMMENT_NONE
}

codegen_take_comment :: proc(cg: ^Codegen) -> Comment {
	assert(cg.comment_cursor < len(cg.comments))
	comment := cg.comments[cg.comment_cursor]
	assert(comment.start == cg.comment_next)
	cg.comment_cursor += 1
	codegen_comment_seek(cg)
	return comment
}

// Drop the comments of syntax that produces no output, such as an erased type.
codegen_skip_comments :: proc(cg: ^Codegen, upto: u32) {
	for cg.comment_next < upto { codegen_take_comment(cg) }
}

// Print the pending comments that end at or before `upto` in front of the
// token about to be written. With `closing` the token is a closing delimiter:
// no space is owed after the last comment.
codegen_flush_comments :: proc(cg: ^Codegen, upto: u32, closing := false) {
	if cg.comment_next >= upto { return }
	mid_line := codegen_output_mid_line(cg)
	printed := false
	for cg.comment_next < upto {
		if cg.comments[cg.comment_cursor].end > upto { break }
		comment := codegen_take_comment(cg)
		codegen_flush_comment(cg, comment, mid_line)
		printed = true
	}
	if !printed { return }
	if cg.at_line_start {
		// The rest of the expression continues below the comment.
		if mid_line && !closing { codegen_continuation_indent(cg) }
	} else if !closing {
		cg_byte(cg, ' ')
	}
	if !mid_line { cg.comment_line_pos = cg.pos }
}

codegen_flush_comment :: proc(cg: ^Codegen, comment: Comment, mid_line: bool) {
	if cg.at_line_start {
		if mid_line { codegen_continuation_indent(cg) }
	} else if cg.pos > 0 {
		switch cg.buf[cg.pos - 1] {
		case ' ', '\t', '\n', '(', '[', '{', '<':
		case: cg_byte(cg, ' ')
		}
	}
	line_start := cg.at_line_start || codegen_output_at_line_start(cg)
	codegen_emit_comment(cg, comment)
	// A block comment that opens an output line and closed its source line
	// stays above what it describes. In the middle of a line it stays inline.
	if comment.type == .Block && line_start && codegen_comment_ends_line(cg.source, comment) {
		cg_newline(cg)
	}
}

// A comment that already ends its source line keeps the following token on
// the next line, which keeps documentation blocks above what they describe.
codegen_comment_ends_line :: proc(source: string, comment: Comment) -> bool {
	after := codegen_skip_comment_whitespace(source, int(comment.end))
	return codegen_has_line_break(source[comment.end:after])
}

codegen_continuation_indent :: proc(cg: ^Codegen) {
	assert(cg.at_line_start)
	cg.depth += 1
	cg_indent(cg)
	cg.depth -= 1
	cg.comment_continuation_pos = cg.pos
}

// False at the start of a statement line. True inside a line, and at the
// start of a continuation line: what follows there still continues the
// expression, whether its comments arrive in one flush or in several.
codegen_output_mid_line :: proc(cg: ^Codegen) -> bool {
	if cg.pos == cg.comment_continuation_pos { return true }
	return !codegen_output_at_line_start(cg)
}

// True when only indentation, or indentation and comments, has been written
// on the current output line. Comments printed by an earlier flush at the
// start of the line do not turn what follows into a continuation.
codegen_output_at_line_start :: proc(cg: ^Codegen) -> bool {
	if cg.pos == cg.comment_line_pos { return true }
	for index := cg.pos - 1; index >= 0; index -= 1 {
		switch cg.buf[index] {
		case ' ', '\t':
		case '\n': return true
		case: return false
		}
	}
	return true
}

// `return`, `throw`, `yield`, `async`, `using` and member modifiers end at a
// line break. A comment that reaches the output between such a keyword and
// the token at `first` could introduce one, so it moves in front of the
// keyword. Dropped grouping parentheses can also leave comments directly
// after `first`; those are in front of the same token.
//
// The caller's source mapping was recorded where the comments now begin.
// `anchor` is the source offset of the keyword, mapped again behind them.
codegen_hoist_comments :: proc(cg: ^Codegen, first, anchor: u32) {
	if cg.comment_next == CODEGEN_COMMENT_NONE { return }
	count, breaks := codegen_head_comments(cg, first)
	if !breaks { return }
	codegen_flush_count(cg, count)
	if cg.sm != nil {
		cg_indent(cg)
		sourcemap_record(cg.sm, u32(cg.pos), anchor)
	}
}

// Grouping that the printer adds goes around the whole node. Comments at
// the head of the node, including those inside source grouping that is not
// printed, go in front of it: that is where they are found when the output
// is read back, because the node then begins after them.
codegen_flush_head :: proc(cg: ^Codegen, first: u32) {
	if cg.comment_next == CODEGEN_COMMENT_NONE { return }
	count, _ := codegen_head_comments(cg, first)
	if count > 0 { codegen_flush_count(cg, count) }
}

// The pending comments in front of the first token of the node at `first`:
// those before `first`, and those after it that only blanks and opening
// parentheses separate from it. Reports whether any forces a line break.
codegen_head_comments :: proc(cg: ^Codegen, first: u32) -> (count: int, breaks: bool) {
	cursor := first
	for index := cg.comment_cursor; index < len(cg.comments); index += 1 {
		comment := cg.comments[index]
		if comment.start >= cursor {
			if !codegen_is_open_group(cg.source[cursor:comment.start]) { break }
			cursor = comment.end
		}
		count = index + 1 - cg.comment_cursor
		if codegen_comment_kind(comment) != .Ordinary { continue }
		breaks ||= comment.type == .Line || codegen_has_line_break(comment.value)
	}
	return
}

// Print the next `count` entries of the comment list that are ordinary.
codegen_flush_count :: proc(cg: ^Codegen, count: int) {
	mid_line := codegen_output_mid_line(cg)
	stop := cg.comment_cursor + count
	printed := false
	for cg.comment_cursor < stop && cg.comment_next != CODEGEN_COMMENT_NONE {
		codegen_flush_comment(cg, codegen_take_comment(cg), mid_line)
		printed = true
	}
	if !printed { return }
	if cg.at_line_start {
		if mid_line { codegen_continuation_indent(cg) }
	} else {
		cg_byte(cg, ' ')
	}
	if !mid_line { cg.comment_line_pos = cg.pos }
}

// Only spaces and opening parentheses: the text between a node's start and a
// comment that still precedes the node's first real token.
codegen_is_open_group :: proc(text: string) -> bool {
	for index := 0; index < len(text); index += 1 {
		switch text[index] {
		case ' ', '\t', '\n', '\r', '(':
		case: return false
		}
	}
	return true
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

// Where the comments that belong to the token at `next` begin: the first
// comment in [from, next) on a line of its own that is indented no deeper
// than that token. Returns `next` when every comment belongs to what precedes.
codegen_outdented_comment :: proc(cg: ^Codegen, from, next: u32) -> u32 {
	limit, _ := codegen_source_column(cg.source, next)
	first := codegen_comment_lower_bound(cg.comments, from)
	for comment in cg.comments[first:] {
		if comment.start >= next { break }
		if codegen_comment_kind(comment) != .Ordinary { continue }
		column, own_line := codegen_source_column(cg.source, comment.start)
		if own_line && column <= limit { return comment.start }
	}
	return next
}

// Bytes between the start of the line and `offset`, and whether they are all blank.
codegen_source_column :: proc(source: string, offset: u32) -> (column: int, blank: bool) {
	assert(u64(offset) <= u64(len(source)))
	blank = true
	for index := int(offset) - 1; index >= 0; index -= 1 {
		switch source[index] {
		case '\n', '\r': return
		case ' ', '\t':
		case: blank = false
		}
		column += 1
	}
	return
}

// The offset of the next token that is not a comma: past blanks and comments.
// After the last parameter of a list that is its closing parenthesis; after a
// computed key, its closing bracket.
//
// With `groups`, closing parentheses are passed too: grouping around the
// node that the AST does not record.
codegen_skip_trivia :: proc(source: string, start: u32, groups := false) -> u32 {
	offset := int(start)
	for offset < len(source) {
		offset = codegen_skip_comment_whitespace(source, offset)
		if offset >= len(source) { break }
		if source[offset] == ',' { offset += 1; continue }
		if groups && source[offset] == ')' { offset += 1; continue }
		if offset + 1 >= len(source) || source[offset] != '/' { break }
		if source[offset + 1] == '/' {
			for offset < len(source) {
				if source[offset] == '\n' || source[offset] == '\r' { break }
				offset += 1
			}
		} else if source[offset + 1] == '*' {
			close := strings.index(source[offset + 2:], "*/")
			if close < 0 { break }
			offset += close + 4
		} else {
			break
		}
	}
	return u32(offset)
}
