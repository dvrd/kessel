package kessel

import "core:strings"
import "core:unicode/utf8"

FormatOptions :: struct {
	print_width:     i32,
	tab_width:       i32,
	use_tabs:        bool,
	single_quote:    bool,
	bracket_spacing: bool,
	trailing_comma:  bool,
	// Prettier's "es5" setting: no trailing comma after function parameters
	// and call arguments. The default is "all".
	trailing_comma_es5: bool,
	end_of_line:     string,
}

format_options_default :: proc() -> FormatOptions {
	return {
		print_width = 80,
		tab_width = 2,
		bracket_spacing = true,
		trailing_comma = true,
		end_of_line = "lf",
	}
}

format_options_valid :: proc(options: FormatOptions) -> bool {
	switch options.end_of_line {
	case "lf", "cr", "crlf", "auto":
		return options.print_width > 0 && 0 <= options.tab_width && options.tab_width <= 16
	}
	return false
}

// Prettier's auto setting examines the first CR. An input without CR uses LF.
format_line_ending :: proc(option, source: string) -> string {
	switch option {
	case "crlf": return "\r\n"
	case "cr": return "\r"
	case "auto":
		index := strings.index_byte(source, '\r')
		if index >= 0 {
			if index + 1 < len(source) && source[index + 1] == '\n' { return "\r\n" }
			return "\r"
		}
	}
	return "\n"
}

// A group chooses a flat or broken layout. Lines indent relative to the line
// where the group opened, so a nested object can fit on its own line.
FormatPart :: struct {
	kind: enum {Text, Group, Forced_Group, End, Line, Blank_Line, Fill_Line, If_Break},
	text: string,
	indent: bool,
}

format_width :: proc(text: string) -> int {
	if !simd_has_multibyte(transmute([]u8)text) { return len(text) }
	_, _, width := utf8.grapheme_count(text)
	return width
}

FORMAT_GROUP_DEPTH_MAX :: 256

format_text :: #force_inline proc(parts: ^[dynamic]FormatPart, text: string) {
	append(parts, FormatPart{kind = .Text, text = text})
}

// Include the suffix following the closing delimiter up to the next available
// break. That accounts for semicolons, commas and module source clauses.
format_group_fits :: proc(parts: []FormatPart, remaining: int, parent_broken: bool) -> bool {
	width := remaining
	depth := 1
	for part in parts {
		switch part.kind {
		case .Group: if depth > 0 { depth += 1 }
		case .Forced_Group, .Blank_Line: return depth == 0 && width >= 0
		case .End: if depth > 0 { depth -= 1 }
		case .If_Break: if depth == 0 && parent_broken { width -= len(part.text) }
		case .Line, .Fill_Line:
			if depth == 0 { return width >= 0 }
			width -= len(part.text)
		case .Text: width -= format_width(part.text)
		}
		if width < 0 { return false }
	}
	return width >= 0
}

format_fill_fits :: proc(parts: []FormatPart, remaining: int) -> bool {
	width := remaining
	for part in parts {
		#partial switch part.kind {
		case .Text, .If_Break: width -= format_width(part.text)
		case: return width >= 0
		}
		if width < 0 { return false }
	}
	return width >= 0
}

format_layout_write :: proc(
	out: ^strings.Builder,
	parts: []FormatPart,
	options: FormatOptions,
	start_column: int,
	newline: string,
) -> int {
	assert(format_options_valid(options))
	groups: [FORMAT_GROUP_DEPTH_MAX]struct { broken: bool, base_indent: int }
	depth, indent := 0, 0
	column := start_column
	for part, index in parts {
		broken := depth > 0 && groups[depth-1].broken
		switch part.kind {
		case .Group, .Forced_Group:
			assert(depth < len(groups))
			can_break := depth == 0 || broken
			remaining := int(options.print_width) - column
			fits := !can_break || format_group_fits(parts[index+1:], remaining, broken)
			groups[depth] = {part.kind == .Forced_Group || !fits, indent}
			depth += 1
		case .End:
			assert(depth > 0)
			depth -= 1
		case .If_Break:
			if broken { strings.write_string(out, part.text); column += len(part.text) }
		case .Line, .Blank_Line, .Fill_Line:
			assert(depth > 0)
			if part.kind == .Fill_Line && broken {
				remaining := int(options.print_width) - column - len(part.text)
				broken = !format_fill_fits(parts[index+1:], remaining)
			}
			if broken {
				strings.write_string(out, newline)
				if part.kind == .Blank_Line { strings.write_string(out, newline) }
				indent = groups[depth-1].base_indent
				if part.indent { indent += 1 }
				column = indent * int(options.tab_width)
				if options.use_tabs { for _ in 0..<indent { strings.write_byte(out, '\t') } }
				else { for _ in 0..<column { strings.write_byte(out, ' ') } }
			} else {
				strings.write_string(out, part.text)
				column += len(part.text)
			}
		case .Text:
			strings.write_string(out, part.text)
			column += format_width(part.text)
		}
	}
	assert(depth == 0)
	return column
}
