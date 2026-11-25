package kessel

import "core:strings"
import "core:slice"
import "core:fmt"

lint_dependency_wants_edit :: proc(l: ^Linter) -> bool {
	return l.suggestions != nil || (.Dangerous in l.fix_kinds && .Suggestion in l.fix_kinds)
}

lint_dependency_store_edit :: proc(l: ^Linter, diagnostic: Loc, message, title: string, edit: LintEdit) {
	key := LintFixKey{.L4108_ExhaustiveDeps, diagnostic}
	if l.suggestions != nil { l.suggestions[{key, message}] = {edit, title} }
	if .Dangerous in l.fix_kinds && .Suggestion in l.fix_kinds {
		// Two warnings can highlight the same dependency list. After the first
		// edit, the next lint pass recomputes the remaining changes.
		if _, recorded := l.fixes[key]; !recorded { l.fixes[key] = edit }
	}
}

// Retain optional access from the captured expression. A dependency is
// evaluated during render, before the effect has a chance to guard its reads.
lint_dependency_write_capture :: proc(builder: ^strings.Builder, index: ^LintDependencyModel, name: string, ref: ^Ref) {
	assert(ref != nil)
	assert(strings.has_prefix(name, ref.name))
	strings.write_string(builder, ref.name)
	member := index.syntax.roots[ref.start]
	offset := len(ref.name)
	for offset < len(name) {
		assert(name[offset] == '.')
		end := strings.index_byte(name[offset+1:], '.')
		if end < 0 { end = len(name) } else { end += offset+1 }
		property := name[offset+1:end]
		optional := false
		if member != nil {
			key, named := member.property^.(^Identifier)
			if named && key.name == property {
				optional = member.optional
				member = index.syntax.parents[member]
			} else {
				member = nil
			}
		}
		strings.write_string(builder, "?." if optional else ".")
		strings.write_string(builder, property)
		offset = end
	}
}

// Replacing just the closing bracket preserves comments, elisions, trailing
// commas and the evaluation order of the existing array elements.
lint_dependency_fix_missing :: proc(l: ^Linter, index: ^LintDependencyModel, literal: ^ArrayExpression, missing: map[string]LintDependencyCapture, message: string) {
	assert(literal != nil)
	array := literal.loc
	assert(len(missing) > 0)
	assert(int(array.end) <= len(l.source))
	if array.end <= array.start + 1 { return }
	close := array.end - 1
	if l.source[array.start] != '[' || l.source[close] != ']' { return }
	cursor := lint_dependency_before(l, array.start, close)
	assert(cursor > array.start)
	builder := strings.builder_make(l.allocator)
	switch l.source[cursor-1] {
	case '[':
	case ',': if cursor == close { strings.write_byte(&builder, ' ') }
	case: strings.write_string(&builder, ", ")
	}
	lint_dependency_write_names(&builder, index, missing)
	strings.write_byte(&builder, ']')
	lint_dependency_store_edit(l, array, message, "Add missing Hook dependencies", {{close, array.end}, strings.to_string(builder)})
}

// An omitted list runs a memo every render. Include the callback's actual
// captures in the new list so subsequent renders observe changing values.
lint_dependency_fix_omitted :: proc(l: ^Linter, index: ^LintDependencyModel, call: ^CallExpression, render: ScopeId, body: Loc, message: string) {
	assert(len(call.arguments) == 1)
	close := call.loc.end - 1
	if l.source[close] != ')' { return }
	cursor := lint_dependency_before(l, call.loc.start, close)
	assert(cursor > call.loc.start)
	uses := lint_dependency_collect(l, index, render, body, nil)
	builder := strings.builder_make(l.allocator)
	if l.source[cursor-1] == ',' {
		if cursor == close { strings.write_byte(&builder, ' ') }
	} else {
		strings.write_string(&builder, ", ")
	}
	strings.write_byte(&builder, '[')
	lint_dependency_write_names(&builder, index, uses.missing)
	strings.write_string(&builder, "])")
	lint_dependency_store_edit(l, call.loc, message, "Add a Hook dependency list", {{close, call.loc.end}, strings.to_string(builder)})
}

lint_dependency_write_names :: proc(builder: ^strings.Builder, index: ^LintDependencyModel, missing: map[string]LintDependencyCapture) {
	// Render-time property reads can invoke getters. Keep new reads in the
	// callback's order, with a deterministic tie-breaker for destructuring.
	Read :: struct { name: string, reference: ^Ref }
	reads := make([dynamic]Read, 0, len(missing), index.model.alloc)
	for name, capture in missing {
		// A captured receiver already covers its properties. Adding the child
		// would evaluate it even when the callback guards a nullable receiver.
		dot := strings.last_index_byte(name, '.')
		if dot >= 0 && lint_dependency_covered(missing, name[:dot]) { continue }
		append(&reads, Read{name, capture.reference})
	}
	slice.sort_by(reads[:], proc(a, b: Read) -> bool {
		if a.reference.start != b.reference.start { return a.reference.start < b.reference.start }
		return a.name < b.name
	})
	for read, i in reads {
		if i > 0 { strings.write_string(builder, ", ") }
		lint_dependency_write_capture(builder, index, read.name, read.reference)
	}
}

lint_dependency_before :: proc(l: ^Linter, start, end: u32) -> u32 {
	cursor := end
	i := codegen_comment_lower_bound(l.comments, end)
	for cursor > start {
		cursor = start + u32(len(strings.trim_right_space(l.source[start:cursor])))
		if i == 0 || l.comments[i-1].end != cursor { break }
		i -= 1
		cursor = l.comments[i].start
	}
	return cursor
}

lint_dependency_after :: proc(l: ^Linter, start, end: u32) -> u32 {
	cursor := start
	i := codegen_comment_lower_bound(l.comments, start)
	for cursor < end {
		cursor = end - u32(len(strings.trim_left_space(l.source[cursor:end])))
		if i == len(l.comments) || l.comments[i].start != cursor { break }
		cursor = l.comments[i].end
		i += 1
	}
	return cursor
}

// Keep both array elisions and comments when removing a reported entry. If
// the parser elided grouping parentheses, leave the source intact until we
// can account for the delimiters around that entry.
lint_dependency_report_removable :: proc(l: ^Linter, diagnostic: Loc, array: ^ArrayExpression, i: int, message: string) {
	lint_dependency_report(l, diagnostic, message)
	if !lint_dependency_wants_edit(l) { return }
	value, ok := array.elements[i].?
	assert(ok)
	loc := get_expression_loc(value)
	comment := codegen_comment_lower_bound(l.comments, loc.start)
	if comment < len(l.comments) && l.comments[comment].start < loc.end { return }
	left := lint_dependency_before(l, array.loc.start, loc.start)
	right := lint_dependency_after(l, loc.end, array.loc.end)
	assert(left > array.loc.start && right < array.loc.end)
	before, after := l.source[left-1], l.source[right]
	if before != '[' && before != ',' { return }
	if after != ']' && after != ',' { return }
	edit := LintEdit{span=loc}
	if after == ',' {
		edit.span.end = right + 1
		if comment < len(l.comments) && l.comments[comment].start < right {
			edit.replacement = l.source[loc.end:right]
		}
	} else if i > 0 && before == ',' {
		// Removing a final value after a hole must retain the hole's comma.
		if _, previous := array.elements[i-1].?; previous {
			edit.span.start = left - 1
			if comment > 0 && l.comments[comment-1].start >= left {
				edit.replacement = l.source[left:loc.start]
			}
		}
	}
	title := "Remove this Hook dependency"
	text := l.source[loc.start:loc.end]
	if l.suggestions != nil && len(text) <= 48 && !codegen_has_line_break(text) {
		title = fmt.tprintf("Remove `%s` from Hook dependencies", text)
	}
	lint_dependency_store_edit(l, diagnostic, message, title, edit)
}
