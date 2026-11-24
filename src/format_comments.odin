package kessel

import "core:strings"

// Comments that stand between the items of a list: statements in a block,
// members of a class, properties of an object and cases of a switch. Each
// such comment attaches to a neighbouring item by Prettier's default rule and
// prints before or after it. A comment anywhere else in a statement is not
// printed, and the statement then keeps its original text, because the
// printer counts the comments it prints against the comments it was given.

// The comment documents that surround one list item.
FormatItemComments :: struct {
	leading:  Doc,
	trailing: Doc,
}

@(private = "file")
FormatTrailingState :: struct {
	is_block:        bool,
	has_line_suffix: bool,
}

@(private = "file")
format_has_newline_before :: proc(text: string, start: u32) -> bool {
	index := int(start) - 1
	for index >= 0 && (text[index] == ' ' || text[index] == '\t') {index -= 1}
	return index >= 0 && (text[index] == '\n' || text[index] == '\r')
}

@(private = "file")
format_skip_newline_backwards :: proc(text: string, index: int) -> int {
	if index < 0 {return index}
	if text[index] == '\n' {
		if index > 0 && text[index - 1] == '\r' {return index - 2}
		return index - 1
	}
	if text[index] == '\r' {return index - 1}
	return index
}

@(private = "file")
format_is_previous_line_empty :: proc(text: string, start: u32) -> bool {
	index := int(start) - 1
	for index >= 0 && (text[index] == ' ' || text[index] == '\t') {index -= 1}
	index = format_skip_newline_backwards(text, index)
	for index >= 0 && (text[index] == ' ' || text[index] == '\t') {index -= 1}
	return format_skip_newline_backwards(text, index) != index
}

// A block comment whose every line starts with `*` is re-indented to the
// position it prints at. Any other comment keeps its text.
@(private = "file")
format_comment_contents :: proc(f: ^FormatContext, comment: Comment) -> Doc {
	raw := f.source[comment.start:comment.end]
	if strings.has_prefix(raw, "//") {return ft(f, strings.trim_right_space(raw))}
	if !strings.has_prefix(raw, "/*") || !strings.has_suffix(raw, "*/") || len(raw) < 4 {
		return format_fail(f)
	}
	value := raw[2:len(raw) - 2]
	normalized, _ := strings.replace_all(value, "\r\n", "\n", f.alloc)
	normalized, _ = strings.replace_all(normalized, "\r", "\n", f.alloc)
	lines := strings.split(normalized, "\n", f.alloc)
	indentable := len(lines) > 1
	for line, index in lines {
		// Prettier tests `*` + value + `*`, so the first and last lines pass
		// through their delimiters' stars.
		trimmed := strings.trim_left_space(line)
		if index == 0 {continue}
		if index == len(lines) - 1 && trimmed == "" {continue}
		if !strings.has_prefix(trimmed, "*") {indentable = false}
	}
	if !indentable {return fc(f, ft(f, "/*"), doc_literal_text(f, value), ft(f, "*/"))}
	parts := make([dynamic]Doc, f.alloc)
	append(&parts, ft(f, "/*"))
	for line, index in lines {
		if index == 0 {
			append(&parts, ft(f, strings.trim_right_space(line)))
			continue
		}
		append(&parts, doc_hardline(), ft(f, " "))
		if index < len(lines) - 1 {
			append(&parts, ft(f, strings.trim_space(line)))
		} else {
			append(&parts, ft(f, strings.trim_left_space(line)))
		}
	}
	append(&parts, ft(f, "*/"))
	return fc(f, ..parts[:])
}

@(private = "file")
format_comment_is_block :: proc(f: ^FormatContext, comment: Comment) -> bool {
	return strings.has_prefix(f.source[comment.start:comment.end], "/*")
}

@(private = "file")
format_leading_comment :: proc(f: ^FormatContext, comment: Comment) -> Doc {
	contents := format_comment_contents(f, comment)
	separator := doc_hardline()
	if format_comment_is_block(f, comment) {
		if !format_has_newline_after(f.source, int(comment.end)) {
			separator = ft(f, " ")
		} else if !format_has_newline_before(f.source, comment.start) {
			separator = doc_line()
		}
	}
	// One blank line after the comment survives.
	index := int(comment.end)
	for index < len(f.source) && (f.source[index] == ' ' || f.source[index] == '\t') {index += 1}
	blank: Doc
	if index < len(f.source) {
		after := index
		if f.source[index] == '\r' && index + 1 < len(f.source) && f.source[index + 1] == '\n' {
			after = index + 2
		} else if f.source[index] == '\n' || f.source[index] == '\r' {
			after = index + 1
		}
		if format_has_newline_after(f.source, after) {blank = doc_hardline()}
	}
	return fc(f, contents, separator, blank)
}

@(private = "file")
format_trailing_comment :: proc(
	f: ^FormatContext,
	comment: Comment,
	state: ^FormatTrailingState,
) -> Doc {
	contents := format_comment_contents(f, comment)
	is_block := format_comment_is_block(f, comment)
	previous := state^
	state.is_block = is_block
	state.has_line_suffix = true
	if (previous.has_line_suffix && !previous.is_block) ||
	   format_has_newline_before(f.source, comment.start) {
		// A comment on its own line after the item stays on its own line.
		blank := doc_hardline() if format_is_previous_line_empty(f.source, comment.start) else nil
		return doc_line_suffix(f, fc(f, doc_hardline(), blank, contents))
	}
	if !is_block || previous.has_line_suffix {
		suffix := doc_line_suffix(f, fc(f, ft(f, " "), contents))
		return fc(f, suffix, nil if is_block else doc_break_parent())
	}
	state.has_line_suffix = false
	return fc(f, ft(f, " "), contents)
}

@(private = "file")
format_is_inline_space :: proc(text: string) -> bool {
	for index in 0 ..< len(text) {
		if text[index] != ' ' && text[index] != '\t' {return false}
	}
	return true
}

// A `//` comment that follows `after` on the same line.
format_comment_is_inline_line :: proc(f: ^FormatContext, comment: Comment, after: u32) -> bool {
	if !strings.has_prefix(f.source[comment.start:comment.end], "//") {return false}
	if !format_comment_is_supported(f, comment) {return false}
	return format_is_inline_space(f.source[after:comment.start])
}

// True when a comment lies in one of the gaps around the items of a list,
// as opposed to inside an item.
format_gaps_have_comments :: proc(
	f: ^FormatContext,
	bounds: FormatListBounds,
	starts, ends: []u32,
) -> bool {
	for gap in 0 ..= len(starts) {
		low := bounds.open if gap == 0 else ends[gap - 1]
		high := bounds.close if gap == len(starts) else starts[gap]
		if low < high && len(format_comments_in(f, low, high)) > 0 {return true}
	}
	return false
}

// True when every comment in the range is a block comment with code before
// and after it on its line.
format_comments_are_inline_blocks :: proc(f: ^FormatContext, start, end: u32) -> bool {
	for comment in format_comments_in(f, start, end) {
		if !format_comment_is_block(f, comment) {return false}
		if format_has_newline_before(f.source, comment.start) {return false}
		if format_has_newline_after(f.source, int(comment.end)) {return false}
	}
	return true
}

// Counts a comment as printed, once per statement however often it prints.
format_comment_mark :: proc(f: ^FormatContext, comment: Comment) {
	index := codegen_comment_lower_bound(f.comments, comment.start)
	assert(index < len(f.comments) && f.comments[index].start == comment.start)
	if f.comment_stamps[index] == f.comment_stamp {return}
	f.comment_stamps[index] = f.comment_stamp
	f.comments_printed += 1
}

// Decides whether a comment in the gap between two items leads the next
// item. Otherwise it trails the previous item or, with no item on either
// side, dangles. `high` is where the next item starts. The second result is
// false for a placement that Prettier resolves with a rule that is not
// ported.
@(private = "file")
format_comment_leads_next :: proc(
	f: ^FormatContext,
	in_gap: []Comment,
	position: int,
	high: u32,
	has_previous, has_next: bool,
	has_head: bool,
) -> (
	to_next: bool,
	placed: bool,
) {
	comment := in_gap[position]
	// Comments that share a line are placed together: the line counts as
	// the comment's own when the first of them starts it, and as ending
	// when the last of them ends it. Prettier looks back only past an item
	// and ahead only towards one.
	line_start := comment.start
	if has_previous {
		for index := position - 1; index >= 0; index -= 1 {
			if !format_is_inline_space(f.source[in_gap[index].end:line_start]) {break}
			line_start = in_gap[index].start
		}
	}
	line_end := comment.end
	if has_next {
		for index := position + 1; index < len(in_gap); index += 1 {
			if !format_is_inline_space(f.source[line_end:in_gap[index].start]) {break}
			line_end = in_gap[index].end
		}
	}
	own_line := format_has_newline_before(f.source, line_start)
	end_of_line := format_has_newline_after(f.source, int(line_end))
	// Prettier attaches other comments after a head to the head.
	if has_head && !(own_line && has_next) {return false, false}
	if own_line {return has_next, true}
	if end_of_line {return !has_previous && has_next, true}
	if has_previous && has_next {
		// Code on both sides of the comment's line. The comment leads the
		// next item when only spaces and other comments separate the two,
		// and trails the previous item otherwise.
		gap_end := high
		for index := len(in_gap) - 1; index >= position; index -= 1 {
			if !format_is_inline_space(f.source[in_gap[index].end:gap_end]) {return false, true}
			gap_end = in_gap[index].start
		}
		return true, true
	}
	return has_next, true
}

// The comments around one top-level statement: those above it that lead it
// and those after it that trail it. `gap_start` is where the previous
// statement ends and `next_start` where the next one begins. The comments
// between that belong to a neighbour are left alone. Returns the span of
// source that the comments and the statement cover together.
format_statement_comments :: proc(
	f: ^FormatContext,
	gap_start, statement_start, statement_end, next_start: u32,
	has_previous, has_next: bool,
) -> (
	comments: FormatItemComments,
	covered: Loc,
	ok: bool,
) {
	covered = {statement_start, statement_end}
	leading := make([dynamic]Doc, f.alloc)
	before := format_comments_in(f, gap_start, statement_start)
	for comment, position in before {
		to_next, placed := format_comment_leads_next(
			f,
			before,
			position,
			statement_start,
			has_previous,
			true,
			false,
		)
		if !placed {return {}, covered, false}
		if !to_next {
			// It trails the previous statement, and so must every comment
			// before it.
			if len(leading) > 0 {return {}, covered, false}
			continue
		}
		if !format_comment_is_supported(f, comment) {return {}, covered, false}
		if len(leading) == 0 {covered.start = comment.start}
		append(&leading, format_leading_comment(f, comment))
	}
	trailing := make([dynamic]Doc, f.alloc)
	state: FormatTrailingState
	after := format_comments_in(f, statement_end, next_start)
	for comment, position in after {
		to_next, placed := format_comment_leads_next(
			f,
			after,
			position,
			next_start,
			true,
			has_next,
			false,
		)
		if !placed {return {}, covered, false}
		if to_next {break}
		if !format_comment_is_supported(f, comment) {return {}, covered, false}
		append(&trailing, format_trailing_comment(f, comment, &state))
		covered.end = comment.end
	}
	comments.leading = fc(f, ..leading[:])
	comments.trailing = fc(f, ..trailing[:])
	return comments, covered, !f.failed
}

// The comments that lie wholly inside [start, end).
format_comments_in :: proc(f: ^FormatContext, start, end: u32) -> []Comment {
	if start >= end {return nil}
	first := codegen_comment_lower_bound(f.comments, start)
	last := first
	for last < len(f.comments) && f.comments[last].end <= end {last += 1}
	return f.comments[first:last]
}

// Attaches the comments in the gaps of a list. `bounds` delimits the list
// inside its container, and `starts` and `ends` are the spans of its items
// in order. Returns the comment documents for each item and, for a
// list without items, the document of the comments left dangling.
format_list_comments :: proc(
	f: ^FormatContext,
	bounds: FormatListBounds,
	starts, ends: []u32,
) -> (
	items: []FormatItemComments,
	dangling: Doc,
) {
	assert(len(starts) == len(ends))
	count := len(starts)
	open, close := bounds.open, bounds.close
	items = make([]FormatItemComments, count, f.alloc)
	if open >= close || len(format_comments_in(f, open, close)) == 0 {return items, nil}
	leading := make([][dynamic]Doc, count, f.alloc)
	trailing := make([][dynamic]Doc, count, f.alloc)
	states := make([]FormatTrailingState, count, f.alloc)
	loose := make([dynamic]Doc, f.alloc)
	for gap in 0 ..= count {
		low := open if gap == 0 else ends[gap - 1]
		high := close if gap == count else starts[gap]
		in_gap := format_comments_in(f, low, high)
		has_previous, has_next := gap > 0, gap < count
		for comment, position in in_gap {
			if !format_comment_is_supported(f, comment) {
				f.failed = true
				return items, nil
			}
			to_leading, placed := format_comment_leads_next(
				f,
				in_gap,
				position,
				high,
				has_previous,
				has_next,
				gap == 0 && bounds.has_head,
			)
			if !placed {
				f.failed = true
				return items, nil
			}
			format_comment_mark(f, comment)
			if to_leading {
				if leading[gap] == nil {leading[gap] = make([dynamic]Doc, f.alloc)}
				append(&leading[gap], format_leading_comment(f, comment))
			} else if has_previous {
				if trailing[gap - 1] == nil {trailing[gap - 1] = make([dynamic]Doc, f.alloc)}
				append(&trailing[gap - 1], format_trailing_comment(f, comment, &states[gap - 1]))
			} else {
				append(&loose, format_comment_contents(f, comment))
			}
		}
	}
	for index in 0 ..< count {
		if leading[index] != nil {items[index].leading = fc(f, ..leading[index][:])}
		if trailing[index] != nil {items[index].trailing = fc(f, ..trailing[index][:])}
	}
	if len(loose) > 0 {dangling = doc_join(f, doc_hardline(), loose[:])}
	return items, dangling
}

// Ignore directives make Prettier copy the next node from the source, and a
// JSDoc type cast in front of a parenthesis keeps that parenthesis. Neither
// is ported, so such comments leave the statement as written.
@(private = "file")
format_comment_is_supported :: proc(f: ^FormatContext, comment: Comment) -> bool {
	raw := f.source[comment.start:comment.end]
	if len(raw) < 2 || raw[0] != '/' {return false}
	body := raw[2:]
	if strings.has_suffix(body, "*/") {body = body[:len(body) - 2]}
	if strings.trim_space(body) == "prettier-ignore" {return false}
	if strings.has_prefix(raw, "/**") {
		if strings.contains(raw, "@type") || strings.contains(raw, "@satisfies") {
			next := format_next_code_index(f.source, comment.end)
			if next < len(f.source) && f.source[next] == '(' {return false}
		}
	}
	return true
}

// Block comments that sit on one line between an operator and the value
// after it, as in `x = /*#__PURE__*/ make()`. They lead the value. Returns
// nil when the range holds no comment, and fails the statement when it holds
// a comment in any other position.
format_inline_leading_comments :: proc(f: ^FormatContext, start, end: u32) -> Doc {
	in_range := format_comments_in(f, start, end)
	if len(in_range) == 0 {return nil}
	parts := make([dynamic]Doc, f.alloc)
	for comment, position in in_range {
		supported := format_comment_is_supported(f, comment) && format_comment_is_block(f, comment)
		supported = supported && !format_has_newline_before(f.source, comment.start)
		// Only spaces and further comments may separate it from the value.
		next := end if position == len(in_range) - 1 else in_range[position + 1].start
		supported = supported && format_is_inline_space(f.source[comment.end:next])
		if !supported {return format_fail(f)}
		format_comment_mark(f, comment)
		append(&parts, format_comment_contents(f, comment), ft(f, " "))
	}
	return fc(f, ..parts[:])
}

// Block comments that follow a value on its line and precede the token that
// ends the statement, as in `state = 2 /* Ready */;`. They trail the value.
format_inline_trailing_comments :: proc(f: ^FormatContext, start, end: u32) -> Doc {
	in_range := format_comments_in(f, start, end)
	if len(in_range) == 0 {return nil}
	parts := make([dynamic]Doc, f.alloc)
	previous := start
	for comment in in_range {
		supported := format_comment_is_supported(f, comment) && format_comment_is_block(f, comment)
		supported = supported && format_is_inline_space(f.source[previous:comment.start])
		if !supported {return format_fail(f)}
		format_comment_mark(f, comment)
		append(&parts, ft(f, " "), format_comment_contents(f, comment))
		previous = comment.end
	}
	// The statement's own terminator must follow on the same line.
	rest := strings.trim_left(f.source[previous:end], " \t")
	if rest != ";" {return format_fail(f)}
	return fc(f, ..parts[:])
}

// True when the span starts and ends with the given delimiters.
format_is_delimited :: proc(f: ^FormatContext, loc: Loc, open, close: u8) -> bool {
	if loc.end < loc.start + 2 || int(loc.end) > len(f.source) {return false}
	return f.source[loc.start] == open && f.source[loc.end - 1] == close
}

format_with_comments :: proc(f: ^FormatContext, comments: FormatItemComments, doc: Doc) -> Doc {
	if comments.leading == nil && comments.trailing == nil {return doc}
	return fc(f, comments.leading, doc, comments.trailing)
}
