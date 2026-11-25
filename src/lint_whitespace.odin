package kessel

import "core:slice"
import "core:unicode/utf8"

// no-irregular-whitespace: whitespace between tokens that is neither a space,
// a tab nor a line break. oxlint reports what its lexer skipped as trivia, so
// a character inside a string, a comment, a template, a regular expression or
// JSX text is never reported. The lexer supplies the candidates; the walk
// removes those that lie inside a token the parser re-read.

lint_irregular_init :: proc(l: ^Linter, offsets: []u32) {
	if len(offsets) == 0 || !lint_rule_enabled(l, .L2038_NoIrregularWhitespace) { return }
	sorted := slice.clone(offsets, l.allocator)
	slice.sort(sorted)
	l.irregular = slice.unique(sorted)
	l.irregular_inside = make([]bool, len(l.irregular), l.allocator)
}

// Marks the candidates within `loc` as part of a token.
lint_irregular_exclude :: proc(l: ^Linter, loc: Loc) {
	assert(len(l.irregular) == len(l.irregular_inside))
	low, high := 0, len(l.irregular)
	for low < high {
		middle := low + (high - low) / 2
		if l.irregular[middle] < loc.start { low = middle + 1 } else { high = middle }
	}
	for index := low; index < len(l.irregular) && l.irregular[index] < loc.end; index += 1 {
		l.irregular_inside[index] = true
	}
}

lint_irregular_report :: proc(l: ^Linter) {
	for start, index in l.irregular {
		if l.irregular_inside[index] || int(start) >= len(l.source) { continue }
		// A byte order mark opens the file; it is not whitespace in the program.
		if start == 0 && l.source[0] == 0xEF { continue }
		_, width := utf8.decode_rune_in_string(l.source[start:])
		lint_emit(l, {start, start + u32(width)}, .L2038_NoIrregularWhitespace)
	}
}
