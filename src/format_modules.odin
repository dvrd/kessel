package kessel

import "core:mem"
import mvirtual "core:mem/virtual"
import "core:strings"

FORMAT_SCRATCH_BLOCK_BYTES :: 1 << 20

// Formats a parsed program. Only complete statements are replaced. The gaps
// between them are copied from the original file, so directives, comments
// and unsupported syntax survive exactly.
//
// The result is checked before it is returned: it must parse, and formatting
// it again must change nothing. A statement that fails the second condition
// keeps its original text. Prettier's own output is not always stable, for
// example where an object that it expanded then counts as written expanded,
// and a formatter that is not idempotent cannot be trusted in a save hook.
format_program :: proc(job: ^ParseJob, options: FormatOptions) -> string {
	assert(len(job.parser.errors) == 0)
	assert(format_options_valid(options))
	source := string(job.source.data)
	count := len(job.program.body)
	first := format_pass(job, options, nil)
	if first.formatted == 0 { return source }
	// Text that formatting leaves alone is stable by definition.
	if first.text == source { return source }

	check: ParseJob
	buffer: []u8
	if !format_reparse_open(&check, &buffer, first.text, job) { return source }
	defer format_reparse_close(&check, buffer)
	parse_job_run(&check)
	if len(check.parser.errors) != 0 || len(check.program.body) != count { return source }
	second := format_pass(&check, options, nil)
	if second.text == first.text { return first.text }

	skip := make([]bool, count, job.arena_alloc)
	unstable := 0
	for index in 0..<count {
		before, after := first.spans[index], second.spans[index]
		was_formatted := before.end > before.start
		if was_formatted != (after.end > after.start) { return source }
		if !was_formatted { continue }
		if first.text[before.start:before.end] != second.text[after.start:after.end] {
			skip[index] = true
			unstable += 1
		}
	}
	// A difference outside every formatted statement has no known cause.
	if unstable == 0 { return source }
	third := format_pass(job, options, skip)
	if third.formatted == 0 { return source }
	return third.text
}

@(private="file")
FormatPass :: struct {
	text:      string,
	// Where each statement's formatted text lies in `text`. Statements that
	// kept their original text have an empty span.
	spans:     []Loc,
	formatted: int,
}

// The second parse needs an arena of its own. A native build reserves
// address space for it. WebAssembly has none to reserve and borrows a buffer.
@(private="file")
format_reparse_open :: proc(check: ^ParseJob, buffer: ^[]u8, text: string, original: ^ParseJob) -> bool {
	when ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32 {
		bytes, err := make([]u8, int(arena_reserve_for_source(len(text))))
		if err != nil { return false }
		buffer^ = bytes
		check^ = ParseJob{
			config = original.config, source_path = original.source_path,
			source = {data = transmute([]u8)text}, opened = true,
		}
		if mvirtual.arena_init_buffer(&check.arena, bytes) != nil {
			delete(bytes)
			buffer^ = nil
			return false
		}
		check.arena_ptr = &check.arena
		check.arena_alloc = mvirtual.arena_allocator(&check.arena)
		check.owns_arena = true
		parse_job_resolve(check)
		return true
	} else {
		return parse_job_open_inline(check, text, original.config, original.source_path)
	}
}

@(private="file")
format_reparse_close :: proc(check: ^ParseJob, buffer: []u8) {
	parse_job_close(check)
	if buffer != nil { delete(buffer) }
}

// One pass over the program. `skip` names statements that must keep their
// original text.
@(private="file")
format_pass :: proc(job: ^ParseJob, options: FormatOptions, skip: []bool) -> FormatPass {
	source := string(job.source.data)
	newline := format_line_ending(options.end_of_line, source)
	comments := job.lexer.comments[:]
	out := strings.builder_make(0, len(source), job.arena_alloc)
	spans := make([]Loc, len(job.program.body), job.arena_alloc)
	formatted := 0
	parts := make([dynamic]FormatPart, job.arena_alloc)
	tokens := make([dynamic]FastToken, job.arena_alloc)
	scanner: Lexer
	init_lexer(&scanner, "", job.arena_alloc, .Module)
	scanner.source = source
	scanner.source_bytes = job.source.data
	previous_end: u32
	previous_index := -2
	column := 0
	// Documents are many times larger than the text they describe. They live
	// in a scratch arena that is reset after every statement, because the
	// parse arena is sized for the tree alone.
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch, context.allocator, context.allocator, FORMAT_SCRATCH_BLOCK_BYTES, FORMAT_SCRATCH_BLOCK_BYTES / 4)
	defer mem.dynamic_arena_destroy(&scratch)
	scratch_alloc := mem.dynamic_arena_allocator(&scratch)
	printer: FormatContext
	format_context_init(&printer, source, options, job.arena_alloc, scratch_alloc)
	printer.typescript = job.lang == .TS || job.lang == .TSX
	printer.comments = comments
	printer.comment_stamps = make([]u32, len(comments), job.arena_alloc)
	for statement, index in job.program.body {
		if skip != nil && skip[index] { continue }
		module_list := false
		#partial switch node in statement^ {
		case ^ImportDeclaration, ^ExportAllDeclaration: module_list = true
		case ^ExportNamedDeclaration: module_list = node.declaration == nil
		// Prettier drops a stray `;`. Dropping a statement is not this
		// loop's job, so it keeps its text.
		case ^EmptyStatement: continue
		}
		loc := get_statement_loc(statement)
		if loc.end <= loc.start { continue }
		if format_is_ignored(comments, source, loc) { continue }
		clear(&parts)
		doc: Doc
		// Only the general printer places comments.
		commented := format_has_comment(comments, loc)
		if module_list {
			if commented { continue }
			clear(&tokens)
			scanner.offset = int(loc.start)
			for scanner.offset < int(loc.end) {
				token := lex_token(&scanner)
				if token.kind == .EOF || token.end > loc.end { break }
				append(&tokens, token)
			}
			if len(tokens) == 0 || tokens[len(tokens)-1].end != loc.end { continue }
			if !format_module_parts(&parts, tokens[:], source, options, job.arena_alloc) { continue }
		} else {
			mem.dynamic_arena_reset(&scratch)
			printed, ok := format_statement_doc(&printer, job.program, index)
			if ok {
				loc.end = format_statement_end(source, statement, loc)
				// The comments above and beside the statement print with
				// it, so that they take Prettier's spacing too.
				body := job.program.body[:]
				gap_start := previous_end
				if index > 0 && previous_index + 1 != index {
					gap_start = get_statement_loc(body[index-1]).end
				}
				next_start := u32(len(source))
				if index + 1 < len(body) { next_start = get_statement_loc(body[index+1]).start }
				around, covered, attached := format_statement_comments(
					&printer, gap_start, loc.start, loc.end, next_start, index > 0, index + 1 < len(body))
				if attached && gap_start <= loc.start && loc.end <= next_start {
					doc = format_with_comments(&printer, around, printed)
					loc = covered
				} else {
					printer.failed = false
					doc = printed
				}
			} else if commented || !format_data_statement(&parts, statement, source, options, job.arena_alloc) {
				// The data printer still covers typed declarations, which
				// the general printer does not print yet.
				continue
			}
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
		span_start := u32(len(out.buf))
		if doc != nil {
			column = format_doc_print(&out, doc, options, column, newline, scratch_alloc)
		} else {
			column = format_layout_write(&out, parts[:], options, column, newline)
		}
		spans[index] = {span_start, u32(len(out.buf))}
		formatted += 1
		previous_end = loc.end
		previous_index = index
	}
	if previous_index < 0 { return {text = source, spans = spans} }
	tail := source[previous_end:]
	if strings.trim_space(tail) == "" { strings.write_string(&out, newline) }
	else { strings.write_string(&out, tail) }
	return {text = strings.to_string(out), spans = spans, formatted = formatted}
}

// A top-level directive's span stops before its semicolon. The printed
// statement brings its own, so the original one must be consumed with it.
@(private="file")
format_statement_end :: proc(source: string, statement: ^Statement, loc: Loc) -> u32 {
	expression, is_expression := statement^.(^ExpressionStatement)
	if !is_expression || loc.end == 0 || source[loc.end-1] == ';' { return loc.end }
	if get_expression_loc(expression.expression).end != loc.end { return loc.end }
	index := int(loc.end)
	for index < len(source) && (source[index] == ' ' || source[index] == '\t') { index += 1 }
	if index < len(source) && source[index] == ';' { return u32(index + 1) }
	return loc.end
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
format_has_comment :: proc(comments: []Comment, loc: Loc) -> bool {
	index := codegen_comment_lower_bound(comments, loc.start)
	return index < len(comments) && comments[index].start < loc.end
}

// A `prettier-ignore` comment directly above a statement protects it.
@(private="file")
format_is_ignored :: proc(comments: []Comment, source: string, loc: Loc) -> bool {
	index := codegen_comment_lower_bound(comments, loc.start)
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
