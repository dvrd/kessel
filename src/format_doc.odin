package kessel

import "core:mem"
import "core:strings"

// A layout document in the style of Wadler's printer as refined by Prettier.
// The statement and expression printers build a tree of these nodes and
// format_doc_print chooses flat or broken layouts against the print width.
// Prettier's printer is the reference for every rule here, because matching
// its output byte-for-byte requires matching its measuring decisions.
FormatDocKind :: enum u8 {
	Text,
	Concat,
	Indent,
	Align,
	Group,
	Fill,
	If_Break,
	Indent_If_Break,
	Line,
	Line_Suffix,
	Line_Suffix_Boundary,
	Break_Parent,
}

FormatLineKind :: enum u8 {
	Normal, // A space when flat.
	Soft, // Nothing when flat.
	Hard, // Always a newline. Breaks every enclosing group.
	Literal, // A newline that resets to the root indentation.
}

FormatDocLabel :: enum u8 {
	None,
	Member_Chain,
}

FormatDoc :: struct {
	kind:        FormatDocKind,
	line:        FormatLineKind,
	label:       FormatDocLabel,
	// A group that must print broken, either by request or because it
	// contains a forced line break.
	broken:      bool,
	// Contains a forced break anywhere, including inside conditional groups.
	will_break:  bool,
	// Forces the enclosing group to break. A conditional group shields its
	// parent from the breaks inside its states.
	propagates:  bool,
	negate:      bool,
	conditional: bool, // Group whose parts are alternative states.
	align:       i32,
	group_id:    u32,
	text:        string,
	parts:       []Doc,
	contents:    Doc,
	flat:        Doc,
}

// A nil document prints nothing.
Doc :: ^FormatDoc

// Owns the arena that documents live in and hands out group identifiers.
FormatDocs :: struct {
	alloc:         mem.Allocator,
	group_id_last: u32,
}

doc_group_id :: proc(docs: ^FormatDocs) -> u32 {
	docs.group_id_last += 1
	return docs.group_id_last
}

FORMAT_ALIGN_DEDENT_TO_ROOT :: min(i32)

@(private = "file")
format_doc_line := FormatDoc {
	kind = .Line,
	line = .Normal,
}
@(private = "file")
format_doc_softline := FormatDoc {
	kind = .Line,
	line = .Soft,
}
@(private = "file")
format_doc_hardline := FormatDoc {
	kind       = .Line,
	line       = .Hard,
	will_break = true,
	propagates = true,
}
@(private = "file")
format_doc_literalline := FormatDoc {
	kind       = .Line,
	line       = .Literal,
	will_break = true,
	propagates = true,
}
@(private = "file")
format_doc_hardline_quiet := FormatDoc {
	kind = .Line,
	line = .Hard,
}
@(private = "file")
format_doc_break_parent := FormatDoc {
	kind       = .Break_Parent,
	will_break = true,
	propagates = true,
}
@(private = "file")
format_doc_boundary := FormatDoc {
	kind = .Line_Suffix_Boundary,
}

doc_line :: #force_inline proc() -> Doc {return &format_doc_line}
doc_softline :: #force_inline proc() -> Doc {return &format_doc_softline}
doc_hardline :: #force_inline proc() -> Doc {return &format_doc_hardline}
doc_literalline :: #force_inline proc() -> Doc {return &format_doc_literalline}
doc_break_parent :: #force_inline proc() -> Doc {return &format_doc_break_parent}
doc_line_suffix_boundary :: #force_inline proc() -> Doc {return &format_doc_boundary}

doc_text :: proc(docs: ^FormatDocs, text: string) -> Doc {
	if len(text) == 0 {return nil}
	doc := new(FormatDoc, docs.alloc)
	doc.kind = .Text
	doc.text = text
	return doc
}

@(private = "file")
doc_inherit :: #force_inline proc(doc: Doc, child: Doc) {
	if child == nil {return}
	doc.will_break = doc.will_break || child.will_break
	doc.propagates = doc.propagates || child.propagates
}

// Nil parts are dropped so that callers can pass optional pieces directly.
doc_concat :: proc(docs: ^FormatDocs, parts: ..Doc) -> Doc {
	count := 0
	last: Doc
	for part in parts {
		if part != nil {
			count += 1
			last = part
		}
	}
	if count == 0 {return nil}
	if count == 1 {return last}
	doc := new(FormatDoc, docs.alloc)
	doc.kind = .Concat
	doc.parts = make([]Doc, count, docs.alloc)
	index := 0
	for part in parts {
		if part == nil {continue}
		doc.parts[index] = part
		index += 1
		doc_inherit(doc, part)
	}
	assert(index == count)
	return doc
}

@(private = "file")
doc_wrap :: proc(docs: ^FormatDocs, kind: FormatDocKind, contents: Doc) -> Doc {
	doc := new(FormatDoc, docs.alloc)
	doc.kind = kind
	doc.contents = contents
	doc_inherit(doc, contents)
	return doc
}

doc_indent :: proc(docs: ^FormatDocs, contents: Doc) -> Doc {
	if contents == nil {return nil}
	return doc_wrap(docs, .Indent, contents)
}

doc_align :: proc(docs: ^FormatDocs, width: i32, contents: Doc) -> Doc {
	if contents == nil {return nil}
	doc := doc_wrap(docs, .Align, contents)
	doc.align = width
	return doc
}

doc_label :: proc(docs: ^FormatDocs, label: FormatDocLabel, contents: Doc) -> Doc {
	doc := new(FormatDoc, docs.alloc)
	doc.kind = .Concat
	doc.label = label
	if contents != nil {
		doc.parts = make([]Doc, 1, docs.alloc)
		doc.parts[0] = contents
		doc_inherit(doc, contents)
	}
	return doc
}

doc_group :: proc(
	docs: ^FormatDocs,
	contents: Doc,
	should_break := false,
	id: u32 = 0,
) -> Doc {
	doc := new(FormatDoc, docs.alloc)
	doc.kind = .Group
	doc.contents = contents
	doc.group_id = id
	doc_inherit(doc, contents)
	doc.broken = should_break || doc.propagates
	doc.will_break = doc.will_break || should_break
	doc.propagates = doc.broken
	return doc
}

// The printer tries each state flat in order and falls back to the last one
// broken. Breaks inside the states do not force the enclosing group.
doc_conditional_group :: proc(
	docs: ^FormatDocs,
	states: []Doc,
	should_break := false,
) -> Doc {
	assert(len(states) > 0)
	doc := new(FormatDoc, docs.alloc)
	doc.kind = .Group
	doc.conditional = true
	doc.parts = make([]Doc, len(states), docs.alloc)
	copy(doc.parts, states)
	doc.contents = states[0]
	doc.broken = should_break
	doc.propagates = should_break
	doc.will_break = should_break || (states[0] != nil && states[0].will_break)
	return doc
}

// Parts alternate between content and separator, starting with content.
doc_fill :: proc(docs: ^FormatDocs, parts: []Doc) -> Doc {
	doc := new(FormatDoc, docs.alloc)
	doc.kind = .Fill
	doc.parts = make([]Doc, len(parts), docs.alloc)
	copy(doc.parts, parts)
	for part in parts {doc_inherit(doc, part)}
	return doc
}

doc_if_break :: proc(
	docs: ^FormatDocs,
	break_contents: Doc,
	flat_contents: Doc = nil,
	group_id: u32 = 0,
) -> Doc {
	if break_contents == nil && flat_contents == nil {return nil}
	doc := new(FormatDoc, docs.alloc)
	doc.kind = .If_Break
	doc.contents = break_contents
	doc.flat = flat_contents
	doc.group_id = group_id
	doc_inherit(doc, break_contents)
	doc_inherit(doc, flat_contents)
	return doc
}

doc_indent_if_break :: proc(
	docs: ^FormatDocs,
	contents: Doc,
	group_id: u32,
	negate := false,
) -> Doc {
	if contents == nil {return nil}
	assert(group_id != 0)
	doc := doc_wrap(docs, .Indent_If_Break, contents)
	doc.group_id = group_id
	doc.negate = negate
	return doc
}

doc_line_suffix :: proc(docs: ^FormatDocs, contents: Doc) -> Doc {
	if contents == nil {return nil}
	return doc_wrap(docs, .Line_Suffix, contents)
}

doc_join :: proc(docs: ^FormatDocs, separator: Doc, items: []Doc) -> Doc {
	if len(items) == 0 {return nil}
	parts := make([dynamic]Doc, 0, len(items) * 2, docs.alloc)
	for item, index in items {
		if index > 0 {append(&parts, separator)}
		append(&parts, item)
	}
	return doc_concat(docs, ..parts[:])
}

// Source text spanning several lines keeps its own line structure. Each
// newline becomes a literal line so the printer tracks the column correctly.
doc_literal_text :: proc(docs: ^FormatDocs, text: string) -> Doc {
	if !strings.contains_any(text, "\r\n") {return doc_text(docs, text)}
	parts := make([dynamic]Doc, docs.alloc)
	start := 0
	for index := 0; index < len(text); index += 1 {
		char := text[index]
		if char != '\n' && char != '\r' {continue}
		append(&parts, doc_text(docs, text[start:index]), doc_literalline())
		if char == '\r' && index + 1 < len(text) && text[index + 1] == '\n' {index += 1}
		start = index + 1
	}
	append(&parts, doc_text(docs, text[start:]))
	return doc_concat(docs, ..parts[:])
}

// ---------------------------------------------------------------------------
// Printer
// ---------------------------------------------------------------------------

FormatMode :: enum u8 {
	Break,
	Flat,
}

@(private = "file")
FormatIndentCommand :: struct {
	kind:  enum u8 {
		Indent,
		Width,
	},
	width: i32,
}

// Alignment widths are kept apart from indentation levels so that tab
// indentation can turn a run of alignments into tabs once a real indent
// follows, exactly as Prettier does.
@(private = "file")
FormatIndent :: struct {
	value:  string,
	length: int,
	queue:  []FormatIndentCommand,
	root:   ^FormatIndent,
	// Most indents are plain levels, so each level caches its successor.
	child:  ^FormatIndent,
}

@(private = "file")
FormatCommand :: struct {
	indent: ^FormatIndent,
	doc:    Doc,
	mode:   FormatMode,
	offset: i32, // Parts of a fill that are already printed.
}

@(private = "file")
FormatDocPrinter :: struct {
	alloc:       mem.Allocator,
	options:     FormatOptions,
	newline:     string,
	out:         ^strings.Builder,
	out_floor:   int, // Trimming never reaches text written before the doc.
	position:    int,
	commands:    [dynamic]FormatCommand,
	suffixes:    [dynamic]FormatCommand,
	group_modes: [dynamic]u8, // 0 unset, 1 flat, 2 break; indexed by group id.
	remeasure:   bool,
	root:        ^FormatIndent,
}

@(private = "file")
format_indent_make :: proc(
	printer: ^FormatDocPrinter,
	parent: ^FormatIndent,
	command: FormatIndentCommand,
	dedent := false,
) -> ^FormatIndent {
	options := printer.options
	queue: []FormatIndentCommand
	if dedent {
		queue = parent.queue[:max(len(parent.queue) - 1, 0)]
	} else {
		queue = make([]FormatIndentCommand, len(parent.queue) + 1, printer.alloc)
		copy(queue, parent.queue)
		queue[len(parent.queue)] = command
	}
	value := strings.builder_make(printer.alloc)
	length, last_tabs, last_spaces := 0, 0, 0
	for item in queue {
		switch item.kind {
		case .Indent:
			if options.use_tabs {
				for _ in 0 ..< last_tabs + 1 {strings.write_byte(&value, '\t')}
				length += (last_tabs + 1) * int(options.tab_width)
			} else {
				for _ in 0 ..< last_spaces + int(options.tab_width) {
					strings.write_byte(&value, ' ')
				}
				length += last_spaces + int(options.tab_width)
			}
			last_tabs, last_spaces = 0, 0
		case .Width:
			last_tabs += 1
			last_spaces += int(item.width)
		}
	}
	for _ in 0 ..< last_spaces {strings.write_byte(&value, ' ')}
	length += last_spaces
	indent := new(FormatIndent, printer.alloc)
	indent^ = {
		value  = strings.to_string(value),
		length = length,
		queue  = queue,
		root   = parent.root,
	}
	return indent
}

@(private = "file")
format_indent_next :: proc(printer: ^FormatDocPrinter, parent: ^FormatIndent) -> ^FormatIndent {
	if parent.child == nil {
		parent.child = format_indent_make(printer, parent, {kind = .Indent})
	}
	return parent.child
}

@(private = "file")
format_indent_align :: proc(
	printer: ^FormatDocPrinter,
	parent: ^FormatIndent,
	width: i32,
) -> ^FormatIndent {
	if width == FORMAT_ALIGN_DEDENT_TO_ROOT {
		if parent.root != nil {return parent.root}
		return printer.root
	}
	if width == 0 {return parent}
	if width < 0 {return format_indent_make(printer, parent, {}, true)}
	return format_indent_make(printer, parent, {kind = .Width, width = width})
}

@(private = "file")
format_group_mode :: proc(printer: ^FormatDocPrinter, id: u32, fallback: FormatMode) -> FormatMode {
	if id == 0 {return fallback}
	if int(id) < len(printer.group_modes) {
		if printer.group_modes[id] == 2 {return .Break}
	}
	return .Flat
}

// Measures whether the next command fits on the current line when printed
// flat, continuing into the rest of the command stack up to the first line
// break that the surrounding layout will take.
@(private = "file")
format_doc_fits :: proc(
	printer: ^FormatDocPrinter,
	next: FormatCommand,
	rest: []FormatCommand,
	width: int,
	has_line_suffix: bool,
	must_be_flat: bool,
	scratch: ^[dynamic]FormatCommand,
) -> bool {
	remaining := width
	rest_index := len(rest)
	has_suffix := has_line_suffix
	clear(scratch)
	append(scratch, next)
	for remaining >= 0 {
		if len(scratch) == 0 {
			if rest_index == 0 {return true}
			rest_index -= 1
			append(scratch, rest[rest_index])
			continue
		}
		command := pop(scratch)
		doc, mode := command.doc, command.mode
		if doc == nil {continue}
		switch doc.kind {
		case .Text:
			remaining -= format_width(doc.text)
		case .Concat, .Fill:
			for index := len(doc.parts) - 1; index >= int(command.offset); index -= 1 {
				append(scratch, FormatCommand{doc = doc.parts[index], mode = mode})
			}
		case .Indent, .Align, .Indent_If_Break:
			append(scratch, FormatCommand{doc = doc.contents, mode = mode})
		case .Group:
			if must_be_flat && doc.broken {return false}
			group_mode := FormatMode.Break if doc.broken else mode
			contents := doc.contents
			if doc.conditional && group_mode == .Break {contents = doc.parts[len(doc.parts) - 1]}
			append(scratch, FormatCommand{doc = contents, mode = group_mode})
		case .If_Break:
			group_mode := format_group_mode(printer, doc.group_id, mode)
			contents := doc.contents if group_mode == .Break else doc.flat
			if contents != nil {append(scratch, FormatCommand{doc = contents, mode = mode})}
		case .Line:
			if mode == .Break || doc.line == .Hard || doc.line == .Literal {return true}
			if doc.line == .Normal {remaining -= 1}
		case .Line_Suffix:
			has_suffix = true
		case .Line_Suffix_Boundary:
			if has_suffix {return false}
		case .Break_Parent:
		}
	}
	return false
}

@(private = "file")
format_doc_trim :: proc(printer: ^FormatDocPrinter) {
	buffer := &printer.out.buf
	for len(buffer) > printer.out_floor {
		char := buffer[len(buffer) - 1]
		if char != ' ' && char != '\t' {break}
		pop(buffer)
		printer.position -= 1
	}
}

@(private = "file")
format_doc_print_group :: proc(
	printer: ^FormatDocPrinter,
	command: FormatCommand,
	scratch: ^[dynamic]FormatCommand,
) {
	doc, indent := command.doc, command.indent
	flat_passthrough := command.mode == .Flat && !printer.remeasure
	if flat_passthrough {
		mode := FormatMode.Break if doc.broken else FormatMode.Flat
		append(&printer.commands, FormatCommand{indent = indent, mode = mode, doc = doc.contents})
	} else {
		printer.remeasure = false
		next := FormatCommand{indent = indent, mode = .Flat, doc = doc.contents}
		remaining := int(printer.options.print_width) - printer.position
		has_suffix := len(printer.suffixes) > 0
		chosen := FormatCommand{indent = indent, mode = .Break, doc = doc.contents}
		rest := printer.commands[:]
		if !doc.broken &&
		   format_doc_fits(printer, next, rest, remaining, has_suffix, false, scratch) {
			chosen = next
		} else if doc.conditional {
			chosen.doc = doc.parts[len(doc.parts) - 1]
			if !doc.broken {
				for index in 1 ..< len(doc.parts) {
					state := FormatCommand{indent = indent, mode = .Flat, doc = doc.parts[index]}
					if format_doc_fits(
						printer,
						state,
						printer.commands[:],
						remaining,
						has_suffix,
						false,
						scratch,
					) {
						chosen = state
						break
					}
				}
			}
		}
		append(&printer.commands, chosen)
	}
	if doc.group_id != 0 {
		for len(printer.group_modes) <= int(doc.group_id) {append(&printer.group_modes, 0)}
		mode := printer.commands[len(printer.commands) - 1].mode
		printer.group_modes[doc.group_id] = 2 if mode == .Break else 1
	}
}

// A fill prints as many content parts per line as fit. Each separator breaks
// only when the content after it does not fit beside the content before it.
@(private = "file")
format_doc_print_fill :: proc(
	printer: ^FormatDocPrinter,
	command: FormatCommand,
	scratch: ^[dynamic]FormatCommand,
) {
	doc, indent := command.doc, command.indent
	parts := doc.parts[command.offset:]
	if len(parts) == 0 {return}
	remaining := int(printer.options.print_width) - printer.position
	has_suffix := len(printer.suffixes) > 0
	content_flat := FormatCommand{indent = indent, mode = .Flat, doc = parts[0]}
	content_break := FormatCommand{indent = indent, mode = .Break, doc = parts[0]}
	content_fits := format_doc_fits(
		printer,
		content_flat,
		nil,
		remaining,
		has_suffix,
		true,
		scratch,
	)
	if len(parts) == 1 {
		append(&printer.commands, content_flat if content_fits else content_break)
		return
	}
	space_flat := FormatCommand{indent = indent, mode = .Flat, doc = parts[1]}
	space_break := FormatCommand{indent = indent, mode = .Break, doc = parts[1]}
	if len(parts) == 2 {
		if content_fits {
			append(&printer.commands, space_flat, content_flat)
		} else {
			append(&printer.commands, space_break, content_break)
		}
		return
	}
	rest := command
	rest.offset += 2
	docs := FormatDocs{alloc = printer.alloc}
	pair := doc_concat(&docs, parts[0], parts[1], parts[2])
	pair_flat := FormatCommand{indent = indent, mode = .Flat, doc = pair}
	pair_fits := format_doc_fits(printer, pair_flat, nil, remaining, has_suffix, true, scratch)
	append(&printer.commands, rest)
	if pair_fits {
		append(&printer.commands, space_flat, content_flat)
	} else if content_fits {
		append(&printer.commands, space_break, content_flat)
	} else {
		append(&printer.commands, space_break, content_break)
	}
}

@(private = "file")
format_doc_print_line :: proc(printer: ^FormatDocPrinter, command: FormatCommand) {
	doc, indent := command.doc, command.indent
	if command.mode == .Flat {
		if doc.line == .Normal || doc.line == .Soft {
			if doc.line == .Normal {
				strings.write_byte(printer.out, ' ')
				printer.position += 1
			}
			return
		}
		// A forced break inside a flat group means that later groups on this
		// line must be measured again.
		printer.remeasure = true
	}
	if len(printer.suffixes) > 0 {
		append(&printer.commands, command)
		// The stack pops in reverse, so the first suffix must go on last.
		for index := len(printer.suffixes) - 1; index >= 0; index -= 1 {
			append(&printer.commands, printer.suffixes[index])
		}
		clear(&printer.suffixes)
		return
	}
	if doc.line == .Literal {
		strings.write_string(printer.out, printer.newline)
		printer.position = 0
		if indent.root != nil {
			strings.write_string(printer.out, indent.root.value)
			printer.position = indent.root.length
		}
	} else {
		format_doc_trim(printer)
		strings.write_string(printer.out, printer.newline)
		strings.write_string(printer.out, indent.value)
		printer.position = indent.length
	}
}

@(private = "file")
format_doc_print_step :: proc(
	printer: ^FormatDocPrinter,
	command: FormatCommand,
	scratch: ^[dynamic]FormatCommand,
) {
	doc, indent, mode := command.doc, command.indent, command.mode
	switch doc.kind {
	case .Text:
		strings.write_string(printer.out, doc.text)
		printer.position += format_width(doc.text)
	case .Concat:
		for index := len(doc.parts) - 1; index >= 0; index -= 1 {
			part := FormatCommand{indent = indent, mode = mode, doc = doc.parts[index]}
			append(&printer.commands, part)
		}
	case .Indent:
		next := format_indent_next(printer, indent)
		append(&printer.commands, FormatCommand{indent = next, mode = mode, doc = doc.contents})
	case .Align:
		next := format_indent_align(printer, indent, doc.align)
		append(&printer.commands, FormatCommand{indent = next, mode = mode, doc = doc.contents})
	case .Group:
		format_doc_print_group(printer, command, scratch)
	case .Fill:
		format_doc_print_fill(printer, command, scratch)
	case .If_Break:
		group_mode := format_group_mode(printer, doc.group_id, mode)
		contents := doc.contents if group_mode == .Break else doc.flat
		if contents != nil {
			append(&printer.commands, FormatCommand{indent = indent, mode = mode, doc = contents})
		}
	case .Indent_If_Break:
		group_mode := format_group_mode(printer, doc.group_id, mode)
		indented := (group_mode == .Break) != doc.negate
		next := format_indent_next(printer, indent) if indented else indent
		append(&printer.commands, FormatCommand{indent = next, mode = mode, doc = doc.contents})
	case .Line_Suffix:
		append(&printer.suffixes, FormatCommand{indent = indent, mode = mode, doc = doc.contents})
	case .Line_Suffix_Boundary:
		if len(printer.suffixes) > 0 {
			append(
				&printer.commands,
				FormatCommand{indent = indent, mode = mode, doc = &format_doc_hardline_quiet},
			)
		}
	case .Line:
		format_doc_print_line(printer, command)
	case .Break_Parent:
	}
}

// Appends the printed document to out and returns the final column.
format_doc_print :: proc(
	out: ^strings.Builder,
	doc: Doc,
	options: FormatOptions,
	start_column: int,
	newline: string,
	alloc: mem.Allocator,
) -> int {
	assert(format_options_valid(options))
	assert(start_column >= 0)
	printer := FormatDocPrinter {
		alloc     = alloc,
		options   = options,
		newline   = newline,
		out       = out,
		out_floor = len(out.buf),
		position  = start_column,
	}
	printer.commands = make([dynamic]FormatCommand, alloc)
	printer.suffixes = make([dynamic]FormatCommand, alloc)
	printer.group_modes = make([dynamic]u8, alloc)
	scratch := make([dynamic]FormatCommand, alloc)
	root := new(FormatIndent, alloc)
	printer.root = root
	append(&printer.commands, FormatCommand{indent = root, mode = .Break, doc = doc})
	for len(printer.commands) > 0 {
		command := pop(&printer.commands)
		if command.doc != nil {format_doc_print_step(&printer, command, &scratch)}
		if len(printer.commands) == 0 && len(printer.suffixes) > 0 {
			for index := len(printer.suffixes) - 1; index >= 0; index -= 1 {
				append(&printer.commands, printer.suffixes[index])
			}
			clear(&printer.suffixes)
		}
	}
	return printer.position
}
