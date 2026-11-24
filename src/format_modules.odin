package kessel

import "core:mem"
import "core:strings"

// Only replace complete, parsed statements. Copy gaps from the
// original file so directives, comments and unsupported syntax survive exactly.
format_program :: proc(job: ^ParseJob, options: FormatOptions) -> string {
	assert(len(job.parser.errors) == 0)
	assert(format_options_valid(options))
	source := string(job.source.data)
	newline := format_line_ending(options.end_of_line, source)
	comments := job.lexer.comments[:]
	out := strings.builder_make(0, len(source), job.arena_alloc)
	parts := make([dynamic]FormatPart, job.arena_alloc)
	tokens := make([dynamic]FastToken, job.arena_alloc)
	scanner: Lexer
	init_lexer(&scanner, "", job.arena_alloc, .Module)
	scanner.source = source
	scanner.source_bytes = job.source.data
	previous_end: u32
	previous_index := -2
	column := 0
	for statement, index in job.program.body {
		module_list := false
		#partial switch node in statement^ {
		case ^ImportDeclaration, ^ExportAllDeclaration: module_list = true
		case ^ExportNamedDeclaration: module_list = node.declaration == nil
		case ^VariableDeclaration, ^ExportDefaultDeclaration:
		case: continue
		}
		loc := get_statement_loc(statement)
		if format_preserve_comments(comments, source, loc) { continue }
		clear(&parts)
		if module_list {
			clear(&tokens)
			scanner.offset = int(loc.start)
			for scanner.offset < int(loc.end) {
				token := lex_token(&scanner)
				if token.kind == .EOF || token.end > loc.end { break }
				append(&tokens, token)
			}
			if len(tokens) == 0 || tokens[len(tokens)-1].end != loc.end { continue }
			if !format_module_parts(&parts, tokens[:], source, options, job.arena_alloc) { continue }
		} else if !format_data_statement(&parts, statement, source, options, job.arena_alloc) {
			continue
		}

		gap := source[previous_end:loc.start]
		if previous_index + 1 == index && strings.trim_space(gap) == "" {
			strings.write_string(&out, newline)
			if format_has_blank_line(gap) { strings.write_string(&out, newline) }
			column = 0
		} else {
			strings.write_string(&out, gap)
			line := max(strings.last_index_byte(gap, '\n'), strings.last_index_byte(gap, '\r')) + 1
			if line > 0 { column = 0 }
			column += format_width(gap[line:])
		}
		column = format_layout_write(&out, parts[:], options, column, newline)
		previous_end = loc.end
		previous_index = index
	}
	if previous_index < 0 { return source }
	tail := source[previous_end:]
	if strings.trim_space(tail) == "" { strings.write_string(&out, newline) }
	else { strings.write_string(&out, tail) }
	return strings.to_string(out)
}

@(private)
format_has_blank_line :: proc(gap: string) -> bool {
	lines := 0
	for char, i in gap {
		if char == '\n' || (char == '\r' && (i + 1 == len(gap) || gap[i+1] != '\n')) {
			lines += 1
			if lines == 2 { return true }
		}
	}
	return false
}

@(private="file")
format_preserve_comments :: proc(comments: []Comment, source: string, loc: Loc) -> bool {
	index := codegen_comment_lower_bound(comments, loc.start)
	if index < len(comments) && comments[index].start < loc.end { return true }
	start := loc.start
	for index > 0 {
		index -= 1
		comment := comments[index]
		if comment.end > start || strings.trim_space(source[comment.end:start]) != "" { break }
		if strings.trim_space(comment.value) == "prettier-ignore" { return true }
		start = comment.start
	}
	return false
}

// Token boundaries preserve distinctions the AST intentionally normalizes,
// including empty named imports and explicit aliases with identical names.
@(private="file")
format_module_parts :: proc(parts: ^[dynamic]FormatPart, tokens: []FastToken, source: string, options: FormatOptions, alloc: mem.Allocator) -> bool {
	bracket_space := " " if options.bracket_spacing else ""
	breakable := false
	for token, i in tokens {
		prev := tokens[i-1].kind if i > 0 else TokenType.EOF
		next := tokens[i+1].kind if i+1 < len(tokens) else TokenType.EOF
		raw := source[token.start:token.end]
		#partial switch token.kind {
		case .LBrace:
			append(parts, FormatPart{kind = .Text, text = " {"})
			breakable = format_list_breakable(tokens[i+1:], source, prev)
			if next != .RBrace {
				if breakable { append(parts, FormatPart{kind = .Group}) }
				append(parts, FormatPart{kind = .Line if breakable else .Text, text = bracket_space, indent = true})
			}
		case .RBrace:
			if prev != .LBrace {
				if breakable && options.trailing_comma { append(parts, FormatPart{kind = .If_Break, text = ","}) }
				append(parts, FormatPart{kind = .Line if breakable else .Text, text = bracket_space})
				if breakable { append(parts, FormatPart{kind = .End}) }
			}
			append(parts, FormatPart{kind = .Text, text = "}"})
			breakable = false
		case .Comma:
			if next != .RBrace {
				append(parts, FormatPart{kind = .Text, text = ","})
				if next != .LBrace { append(parts, FormatPart{kind = .Line if breakable else .Text, text = " ", indent = true}) }
			}
		case .Colon: append(parts, FormatPart{kind = .Text, text = ": "})
		case .Semi:
		case:
			if prev != .EOF && prev != .LBrace && prev != .Comma && prev != .Colon {
				append(parts, FormatPart{kind = .Text, text = " "})
			}
			if token.kind == .String {
				if strings.contains_any(raw, "\r\n\u2028\u2029") { return false }
				if next == .Colon && format_identifier_key(raw) { raw = raw[1:len(raw)-1] }
				else { raw = format_string(raw, options.single_quote, alloc) }
			}
			append(parts, FormatPart{kind = .Text, text = raw})
		}
	}
	append(parts, FormatPart{kind = .Text, text = ";"})
	return true
}

@(private="file")
format_list_breakable :: proc(items: []FastToken, source: string, preceding: TokenType) -> bool {
	for item, i in items {
		if item.kind == .RBrace { break }
		if item.kind == .Comma && i+1 < len(items) && items[i+1].kind != .RBrace { return true }
	}
	if preceding == .With || preceding == .Assert {
		if len(items) == 0 { return false }
		key := source[items[0].start:items[0].end]
		return key != "type" && key != "\"type\"" && key != "'type'"
	}
	return preceding == .Comma
}

@(private)
format_identifier_key :: proc(raw: string) -> bool {
	name := raw[1:len(raw)-1]
	for char, offset in name {
		if offset == 0 && !is_id_start_codepoint(u32(char)) { return false }
		if !is_id_cont_codepoint(u32(char)) { return false }
	}
	return len(name) > 0
}

@(private)
format_string :: proc(raw: string, prefer_single: bool, alloc: mem.Allocator) -> string {
	assert(len(raw) >= 2)
	value := raw[1:len(raw)-1]
	singles := strings.count(value, "'")
	doubles := strings.count(value, "\"")
	quote: u8 = '"'
	if singles < doubles || (singles == doubles && prefer_single) { quote = '\'' }
	if raw[0] == quote { return raw }

	out := strings.builder_make(0, len(raw), alloc)
	strings.write_byte(&out, quote)
	for i := 0; i < len(value); i += 1 {
		char := value[i]
		if char == '\\' && i+1 < len(value) {
			i += 1
			char = value[i]
			if char != '\'' && char != '"' { strings.write_byte(&out, '\\') }
		}
		if char == quote { strings.write_byte(&out, '\\') }
		strings.write_byte(&out, char)
	}
	strings.write_byte(&out, quote)
	return strings.to_string(out)
}
