package kessel

import "core:math/bits"
import "core:slice"
import "core:strings"

// A block directive can sit beside a JS token or between JSX attributes without
// introducing a line break. Recording syntax boundaries avoids inserting into
// rendered JSX text, template chunks, strings or existing comments.
lint_suppression_boundaries :: proc(l: ^Linter, span: Loc) {
	if span.start >= span.end { return }
	assert(int(span.end) <= len(l.source))
	assert(int(span.end / 64) < len(l.suppression_marks))
	for offset in ([2]u32{span.start, span.end}) {
		l.suppression_marks[offset / 64] |= u64(1) << (offset % 64)
	}
}

// Resolve one rightmost marked offset per line after the walk. This avoids
// searching the line table twice for every node in the syntax tree.
lint_suppression_line_anchors :: proc(l: ^Linter, lines: []u32) -> []u32 {
	assert(len(lines) > 0)
	assert(lines[0] == 0)
	anchors := make([]u32, len(lines), l.allocator)
	for first, i in lines {
		last := lines[i+1]-1 if i+1 < len(lines) else u32(len(l.source))
		word := int(last / 64)
		mask := max(u64) >> (63 - last % 64)
		for ; word >= int(first / 64); word -= 1 {
			marked := l.suppression_marks[word] & mask
			if marked != 0 {
				offset := u32(word * 64) + u32(bits.log2(marked))
				// Zero means the line has no known insertion point.
				if offset >= first { anchors[i] = offset + 1 }
				break
			}
			mask = max(u64)
		}
	}
	return anchors
}


LintDirectiveKind :: enum { Disable, Enable, Line, Next_Line }

LintDirective :: struct {
	kind: LintDirectiveKind,
	comment, label: Loc,
	rule: string,
	used: bool,
}

LintDirectiveLine :: struct { line: int, rule: string }

LintDirectiveIndex :: struct {
	// Index zero means linting is enabled by default.
	entries: [dynamic]LintDirective,
	ranges: map[string][dynamic]int,
	lines: map[LintDirectiveLine]int,
	oxlint_line_ids: [dynamic]int,
	mode: LintConfigDialect,
	// Oxlint closes a qualified name by its exact spelling but matches its short name to diagnostics.
	qualified_names: map[string][dynamic]string,
	// Count the named overrides that differ from the latest blanket setting.
	exceptions: int,
}

lint_apply_disable_directives :: proc(l: ^Linter, lexer: ^Lexer, mode: LintConfigDialect) {
	report_unused := lint_rule_enabled(l, .L9001_UnusedDirective)
	if len(lexer.comments) == 0 || (len(l.diagnostics) == 0 && !report_unused) { return }
	context.allocator = l.allocator
	index := LintDirectiveIndex{mode=mode}
	for comment in lexer.comments {
		kind, names, ok := lint_parse_directive(comment.value)
		if !ok { continue }
		if len(index.entries) == 0 {
			index.entries = make([dynamic]LintDirective, 1)
			index.ranges = make(map[string][dynamic]int)
			index.lines = make(map[LintDirectiveLine]int)
		}
		if lexer.num_lines == 0 { build_line_table(lexer) }
		lint_index_directive(&index, lexer, comment, kind, names)
	}
	if len(index.entries) == 0 { return }
	line_hidden := lint_oxlint_line_mask(&index, lexer.source, l.diagnostics[:])
	kept := 0
	for diagnostic, i in l.diagnostics {
		name := lint_rule_info(diagnostic.lint_code).name
		line := lint_offset_to_line(lexer.line_offsets, diagnostic.start)
		hidden := lint_mark_range(&index, name, diagnostic.start, diagnostic.end)
		if line_hidden != nil && line_hidden[i] { hidden = true }
		for key in ([2]string{"", name}) {
			if entry := index.lines[{line, key}]; entry != 0 {
				index.entries[entry].used = true
				hidden = true
			}
		}
		if hidden { continue }
		l.diagnostics[kept] = diagnostic
		kept += 1
	}
	resize(&l.diagnostics, kept)
	if report_unused { lint_report_unused_directives(l, index.entries[1:], lexer.line_offsets, mode) }
}

lint_parse_directive :: proc(value: string) -> (LintDirectiveKind, string, bool) {
	text := strings.trim_space(value)
	if !strings.has_prefix(text, "eslint-") && !strings.has_prefix(text, "oxlint-") { return {}, "", false }
	text = text[len("eslint-"):]
	// A description begins at a pair of hyphens following whitespace.
	for at := 1; at + 1 < len(text); at += 1 {
		if text[at:at+2] == "--" && strings.trim_space(text[:at]) != text[:at] {
			text = strings.trim_space(text[:at])
			break
		}
	}
	keywords := [LintDirectiveKind]string{.Disable="disable", .Enable="enable", .Line="disable-line", .Next_Line="disable-next-line"}
	for keyword, kind in keywords {
		if !strings.has_prefix(text, keyword) { continue }
		tail := text[len(keyword):]
		if len(tail) > 0 && strings.trim_left_space(tail) == tail { continue }
		return kind, strings.trim_space(tail), true
	}
	return {}, "", false
}

// Oxlint disable-line only covers text before the comment. Disable-next-line
// covers the rest of the comment's last line and the following physical line.
// Index diagnostic starts once per requested rule so overlapping directives can
// all be marked used without rescanning the same statements for every comment.
@(private="file")
LintLineDiagnostic :: struct { start: u32, original, delta: int }

@(private="file")
lint_oxlint_line_mask :: proc(index: ^LintDirectiveIndex, source: string, diagnostics: []ParseError) -> []bool {
	if len(index.oxlint_line_ids) == 0 || len(diagnostics) == 0 { return nil }
	groups := make(map[string][dynamic]LintLineDiagnostic)
	for id in index.oxlint_line_ids { groups[index.entries[id].rule] = nil }
	for diagnostic, i in diagnostics {
		for rule in ([2]string{"", lint_rule_info(diagnostic.lint_code).name}) {
			if group, present := groups[rule]; present {
				append(&group, LintLineDiagnostic{start = diagnostic.start, original = i})
				groups[rule] = group
			}
		}
	}
	for _, group in groups {
		slice.sort_by(group[:], proc(a, b: LintLineDiagnostic) -> bool { return a.start < b.start })
	}
	// The reference directive syntax uses LF to delimit lines, independently
	// of ECMAScript's additional line terminators used for diagnostic positions.
	lines := make([dynamic]u32, 1)
	for byte, i in transmute([]u8)source { if byte == '\n' { append(&lines, u32(i+1)) } }
	for id in index.oxlint_line_ids {
		entry := &index.entries[id]
		group := groups[entry.rule][:]
		if len(group) == 0 { continue }
		span := lint_oxlint_line_span(entry, source, lines[:])
		first := lint_line_lower_bound(group, span.start)
		last := lint_line_lower_bound(group, span.end)
		if first == last { continue }
		assert(first < last)
		entry.used = true
		group[first].delta += 1
		if last < len(group) { group[last].delta -= 1 }
	}
	hidden := make([]bool, len(diagnostics))
	for _, group in groups {
		overlaps := 0
		for diagnostic in group {
			overlaps += diagnostic.delta
			assert(overlaps >= 0)
			if overlaps > 0 { hidden[diagnostic.original] = true }
		}
	}
	return hidden
}

@(private="file")
lint_line_lower_bound :: proc(group: []LintLineDiagnostic, offset: u32) -> int {
	lo, hi := 0, len(group)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if group[mid].start < offset { lo = mid + 1 } else { hi = mid }
	}
	return lo
}

@(private="file")
lint_oxlint_line_span :: proc(entry: ^LintDirective, source: string, lines: []u32) -> Loc {
	comment := entry.comment
	assert(comment.start + 2 <= comment.end)
	assert(comment.end <= u32(len(source)))
	if entry.kind == .Line {
		return {lines[lint_offset_to_line(lines, comment.start)], comment.start + 2}
	}
	assert(entry.kind == .Next_Line)
	start := comment.end
	if source[comment.start + 1] == '*' { start -= 2 }
	end := u32(len(source))
	line := lint_offset_to_line(lines, start)
	if line + 1 < len(lines) {
		if line + 2 < len(lines) { end = lines[line + 2] }
		for end > lines[line + 1] && (source[end-1] == '\n' || source[end-1] == '\r') { end -= 1 }
	}
	return {start, end}
}

lint_index_directive :: proc(index: ^LintDirectiveIndex, lexer: ^Lexer, comment: Comment, kind: LintDirectiveKind, names: string) {
	span := Loc{comment.start, comment.end}
	line := lint_offset_to_line(lexer.line_offsets, comment.start)
	if kind == .Next_Line { line = lint_offset_to_line(lexer.line_offsets, comment.end) + 1 }
	if names == "" {
		label := span
		if kind == .Enable && index.mode == .Oxlint {
			label.start += 2
			label.end = label.start + u32(len(comment.value))
			assert(label.end <= span.end)
		}
		lint_add_directive(index, {kind=kind, comment=span, label=label}, line)
		return
	}
	// Names and comments are slices of the original UTF-8 source. Keep byte
	// positions even when whitespace or text preceding a rule is non-ASCII.
	rest := names
	for part in strings.split_by_byte_iterator(&rest, ',') {
		name := strings.trim_space(part)
		if name != "" {
			start := u32(uintptr(raw_data(name)) - uintptr(raw_data(lexer.source)))
			label := Loc{start, start + u32(len(name))}
			slash := strings.last_index_byte(name, '/')
			rule := name[slash+1:]
			if rule == "" { continue }
			if index.mode == .Oxlint && (kind == .Disable || kind == .Enable) { rule = name }
			lint_add_directive(index, {kind=kind, comment=span, label=label, rule=rule}, line)
		}
	}
}

lint_add_directive :: proc(index: ^LintDirectiveIndex, directive: LintDirective, line: int) {
	id := len(index.entries)
	append(&index.entries, directive)
	if directive.kind == .Line || directive.kind == .Next_Line {
		if index.mode == .Oxlint { append(&index.oxlint_line_ids, id) }
		else { index.lines[{line, directive.rule}] = id }
		return
	}
	if index.mode == .Oxlint {
		lint_add_oxlint_transition(index, id)
		return
	}
	all, named := index.ranges[""], index.ranges[directive.rule]
	global, prior := 0, 0
	if len(all) > 0 { global = all[len(all)-1] }
	prior = global
	if len(named) > 0 { prior = max(prior, named[len(named)-1]) }
	disabling := directive.kind == .Disable
	// The sentinel is an enabled interval even though Disable has enum value zero.
	prior_disabled := prior != 0 && index.entries[prior].kind == .Disable
	if directive.rule == "" {
		if prior_disabled == disabling && index.exceptions == 0 { return }
		index.exceptions = 0
	} else {
		if prior_disabled == disabling { return }
		global_disabled := global != 0 && index.entries[global].kind == .Disable
		if disabling == global_disabled { index.exceptions -= 1 } else { index.exceptions += 1 }
		assert(index.exceptions >= 0)
	}
	index.entries[id].used = !disabling
	append(&named, id)
	index.ranges[directive.rule] = named
}

// Each spelling has at most one open range. A repeated disable leaves the first one open.
lint_add_oxlint_transition :: proc(index: ^LintDirectiveIndex, id: int) {
	entry := &index.entries[id]
	ids := index.ranges[entry.rule]
	open := len(ids) % 2 == 1
	if entry.kind == .Enable && !open { return }
	if entry.kind == .Disable && open { entry.used = true; return }
	entry.used = entry.kind == .Enable
	if len(ids) == 0 {
		slash := strings.last_index_byte(entry.rule, '/')
		if slash >= 0 {
			if index.qualified_names == nil { index.qualified_names = make(map[string][dynamic]string) }
			short := entry.rule[slash+1:]
			names := index.qualified_names[short]
			append(&names, entry.rule)
			index.qualified_names[short] = names
		}
	}
	append(&ids, id)
	index.ranges[entry.rule] = ids
}

// Find the first transition after the diagnostic starts. Using byte positions
// keeps statements on opposite sides of the same comment independent.
lint_directive_boundary :: proc(entries: []LintDirective, ids: []int, offset: u32) -> int {
	low, high := 0, len(ids)
	for low < high {
		middle := low + (high-low)/2
		if entries[ids[middle]].comment.end <= offset { low = middle+1 } else { high = middle }
	}
	return low
}

lint_mark_range :: proc(index: ^LintDirectiveIndex, rule: string, start, end: u32) -> bool {
	if index.mode == .Oxlint {
		hidden := lint_mark_oxlint_range(index, "", start, end)
		if lint_mark_oxlint_range(index, rule, start, end) { hidden = true }
		for name in index.qualified_names[rule] {
			if lint_mark_oxlint_range(index, name, start, end) { hidden = true }
		}
		return hidden
	}
	active := 0
	overlap := 0
	for key in ([2]string{"", rule}) {
		ids := index.ranges[key]
		boundary := lint_directive_boundary(index.entries[:], ids[:], start)
		if boundary > 0 { active = max(active, ids[boundary-1]) }
		// A diagnostic covering a whole construct can overlap a disabled
		// range even when its first token precedes that range.
		for id in ids[boundary:] {
			entry := index.entries[id]
			if entry.comment.end >= end { break }
			if entry.kind == .Disable {
				overlap = id
				break
			}
		}
	}
	if active != 0 && index.entries[active].kind == .Disable {
		index.entries[active].used = true
		return true
	}
	if overlap > 0 { index.entries[overlap].used = true }
	return overlap > 0
}

// Transitions alternate between opening and closing a range. Mark every overlapping
// opening so one diagnostic can account for both a blanket and a named suppression.
lint_mark_oxlint_range :: proc(index: ^LintDirectiveIndex, key: string, start, end: u32) -> bool {
	ids := index.ranges[key]
	if len(ids) == 0 { return false }
	boundary := lint_directive_boundary(index.entries[:], ids[:], start)
	first := boundary - boundary % 2
	hidden := false
	for i := first; i < len(ids); i += 2 {
		opening := &index.entries[ids[i]]
		if opening.comment.end >= end { break }
		if i+1 < len(ids) && index.entries[ids[i+1]].comment.start <= start { continue }
		opening.used = true
		hidden = true
	}
	return hidden
}

lint_report_unused_directives :: proc(l: ^Linter, entries: []LintDirective, lines: []u32, mode: LintConfigDialect) {
	for first := 0; first < len(entries); {
		limit := first + 1
		for limit < len(entries) && entries[limit].comment == entries[first].comment { limit += 1 }
		group := entries[first:limit]
		first = limit
		if group[0].kind == .Enable && mode == .Oxlint {
			for entry in group {
				if !entry.used { lint_report(l, entry.label.start, entry.label.end, .L9001_UnusedDirective, "unused lint enable directive") }
			}
			continue
		}
		used := 0
		for entry in group { if entry.used { used += 1 } }
		message := "unused lint enable directive" if group[0].kind == .Enable else "unused lint disable directive"
		if used == 0 {
			loc := group[0].comment
			lint_report(l, loc.start, loc.end, .L9001_UnusedDirective, message)
			if .Suggestion in l.fix_kinds && group[0].kind != .Enable {
				l.fixes[{.L9001_UnusedDirective, loc}] = lint_fix_directive_comment(l, loc, lines)
			}
		} else {
			for entry, i in group {
				if entry.used { continue }
				lint_report(l, entry.label.start, entry.label.end, .L9001_UnusedDirective, message)
				if .Suggestion in l.fix_kinds && entry.kind != .Enable {
					// A run of unused names shares one edit. Keep separators between retained names.
					if i > 0 && !group[i-1].used { continue }
					line_limit := i + 1
					for line_limit < len(group) && !group[line_limit].used { line_limit += 1 }
					span := Loc{entry.label.start, group[line_limit-1].label.end}
					if i == 0 { span.end = group[line_limit].label.start } else { span.start = group[i-1].label.end }
					l.fixes[{.L9001_UnusedDirective, entry.label}] = {span, lint_fix_line_breaks(l, span)}
				}
			}
		}
	}
}
