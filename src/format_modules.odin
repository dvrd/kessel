package kessel

import "core:mem"
import "core:strings"
// Used only by the wasm32 build, where the check arena lives in a fixed buffer.
@(require) import mvirtual "core:mem/virtual"

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
format_reparse_open :: proc(
	check: ^ParseJob,
	buffer: ^[]u8,
	text: string,
	original: ^ParseJob,
) -> bool {
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

// The working state of one pass over a program.
@(private="file")
FormatPassState :: struct {
	job:            ^ParseJob,
	options:        FormatOptions,
	source:         string,
	newline:        string,
	out:            strings.Builder,
	parts:          [dynamic]FormatPart,
	tokens:         [dynamic]FastToken,
	scanner:        Lexer,
	printer:        FormatContext,
	// Documents are many times larger than the text they describe. They live
	// in a scratch arena that is reset after every statement, because the
	// parse arena is sized for the tree alone.
	scratch:        mem.Dynamic_Arena,
	// The source offset up to which text has been written, the index of the
	// last statement that was formatted, and the output column.
	previous_end:   u32,
	previous_index: int,
	column:         int,
}

// One pass over the program. `skip` names statements that must keep their
// original text.
@(private="file")
format_pass :: proc(job: ^ParseJob, options: FormatOptions, skip: []bool) -> FormatPass {
	source := string(job.source.data)
	comments := job.lexer.comments[:]
	state := FormatPassState {
		job = job, options = options, source = source,
		newline = format_line_ending(options.end_of_line, source),
		previous_index = -2,
	}
	state.out = strings.builder_make(0, len(source), job.arena_alloc)
	state.parts = make([dynamic]FormatPart, job.arena_alloc)
	state.tokens = make([dynamic]FastToken, job.arena_alloc)
	init_lexer(&state.scanner, "", job.arena_alloc, .Module)
	state.scanner.source = source
	state.scanner.source_bytes = job.source.data
	block := FORMAT_SCRATCH_BLOCK_BYTES
	mem.dynamic_arena_init(&state.scratch, context.allocator, context.allocator, block, block / 4)
	defer mem.dynamic_arena_destroy(&state.scratch)
	scratch_alloc := mem.dynamic_arena_allocator(&state.scratch)
	format_context_init(&state.printer, source, options, job.arena_alloc, scratch_alloc)
	state.printer.typescript = job.lang == .TS || job.lang == .TSX
	state.printer.dot_ts = strings.has_suffix(job.source_path, ".ts")
	state.printer.jsx = job.lang == .JSX || job.lang == .TSX
	state.printer.comments = comments
	state.printer.param_decorators = job.parser.param_decorators
	state.printer.comment_stamps = make([]u32, len(comments), job.arena_alloc)
	spans := make([]Loc, len(job.program.body), job.arena_alloc)
	formatted := 0
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
		if class, is_class := statement^.(^ClassDeclaration); is_class && class.expr.abstract {
			// The printed class brings its own `abstract`.
			loc.start, _ = format_class_abstract_start(source, loc.start)
		}
		if format_is_ignored(comments, source, loc) { continue }
		clear(&state.parts)
		doc: Doc
		if module_list {
			if !format_pass_module(&state, loc) { continue }
		} else {
			ok: bool
			doc, ok = format_pass_statement(&state, index, &loc)
			if !ok { continue }
		}
		spans[index] = format_pass_emit(&state, index, loc, doc)
		formatted += 1
	}
	if state.previous_index < 0 { return {text = source, spans = spans} }
	tail := source[state.previous_end:]
	if strings.trim_space(tail) == "" { strings.write_string(&state.out, state.newline) }
	else { strings.write_string(&state.out, tail) }
	return {text = strings.to_string(state.out), spans = spans, formatted = formatted}
}

// Fills `parts` for an import or export list. Only the general printer
// places comments, so a commented list keeps its text.
@(private="file")
format_pass_module :: proc(state: ^FormatPassState, loc: Loc) -> bool {
	if format_has_comment(state.job.lexer.comments[:], loc) { return false }
	clear(&state.tokens)
	state.scanner.offset = int(loc.start)
	for state.scanner.offset < int(loc.end) {
		token := lex_token(&state.scanner)
		if token.kind == .EOF || token.end > loc.end { break }
		append(&state.tokens, token)
	}
	count := len(state.tokens)
	if count == 0 || state.tokens[count-1].end != loc.end { return false }
	alloc := state.job.arena_alloc
	return format_module_parts(&state.parts, state.tokens[:], state.source, state.options, alloc)
}

// Builds the document for any other statement, or fills `parts` through the
// data printer, which still covers typed declarations. `loc` grows to cover
// the comments that print with the statement.
@(private="file")
format_pass_statement :: proc(state: ^FormatPassState, index: int, loc: ^Loc) -> (Doc, bool) {
	job, source := state.job, state.source
	body := job.program.body[:]
	statement := body[index]
	mem.dynamic_arena_reset(&state.scratch)
	printed, ok := format_statement_doc(&state.printer, job.program, index)
	if !ok {
		if format_has_comment(job.lexer.comments[:], loc^) { return nil, false }
		alloc := job.arena_alloc
		return nil, format_data_statement(&state.parts, statement, source, state.options, alloc)
	}
	loc.end = format_statement_end(source, statement, loc^)
	// The comments above and beside the statement print with it, so that
	// they take Prettier's spacing too.
	gap_start := state.previous_end
	if index > 0 && state.previous_index + 1 != index {
		gap_start = get_statement_loc(body[index-1]).end
	}
	next_start := u32(len(source))
	if index + 1 < len(body) { next_start = get_statement_loc(body[index+1]).start }
	comment_end := format_statement_comment_end(&state.printer, statement, loc^)
	has_next := index + 1 < len(body)
	around, covered, attached := format_statement_comments(
		&state.printer, gap_start, loc.start, comment_end, next_start, index > 0, has_next)
	if attached && gap_start <= loc.start && loc.end <= next_start {
		covered.end = max(covered.end, loc.end)
		loc^ = covered
		return format_with_comments(&state.printer, around, printed), true
	}
	// A comment inside the statement's span prints only with those around it.
	if len(format_comments_in(&state.printer, comment_end, loc.end)) > 0 { return nil, false }
	state.printer.failed = false
	return printed, true
}

// Writes the gap before a statement and then the statement. Returns where
// the statement's text lies in the output.
@(private="file")
format_pass_emit :: proc(state: ^FormatPassState, index: int, loc: Loc, doc: Doc) -> Loc {
	out, newline := &state.out, state.newline
	gap := state.source[state.previous_end:loc.start]
	if state.previous_index + 1 == index && strings.trim_space(gap) == "" {
		strings.write_string(out, newline)
		if format_has_blank_line(gap) { strings.write_string(out, newline) }
		state.column = 0
	} else {
		strings.write_string(out, gap)
		line := max(strings.last_index_byte(gap, '\n'), strings.last_index_byte(gap, '\r')) + 1
		if line > 0 { state.column = 0 }
		state.column += format_width(gap[line:])
	}
	start := u32(len(out.buf))
	if doc != nil {
		alloc := mem.dynamic_arena_allocator(&state.scratch)
		state.column = format_doc_print(out, doc, state.options, state.column, newline, alloc)
	} else {
		parts := state.parts[:]
		state.column = format_layout_write(out, parts, state.options, state.column, newline)
	}
	state.previous_end = loc.end
	state.previous_index = index
	return {start, u32(len(out.buf))}
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
format_module_parts :: proc(
	parts: ^[dynamic]FormatPart,
	tokens: []FastToken,
	source: string,
	options: FormatOptions,
	alloc: mem.Allocator,
) -> bool {
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
				kind := FormatPart{kind = .Line if breakable else .Text}.kind
				append(parts, FormatPart{kind = kind, text = bracket_space, indent = true})
			}
		case .RBrace:
			if prev != .LBrace {
				if breakable && options.trailing_comma {
					append(parts, FormatPart{kind = .If_Break, text = ","})
				}
				kind := FormatPart{kind = .Line if breakable else .Text}.kind
				append(parts, FormatPart{kind = kind, text = bracket_space})
				if breakable { append(parts, FormatPart{kind = .End}) }
			}
			append(parts, FormatPart{kind = .Text, text = "}"})
			breakable = false
		case .Comma:
			if next != .RBrace {
				append(parts, FormatPart{kind = .Text, text = ","})
				if next != .LBrace {
					kind := FormatPart{kind = .Line if breakable else .Text}.kind
					append(parts, FormatPart{kind = kind, text = " ", indent = true})
				}
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
