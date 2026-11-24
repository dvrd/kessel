package kessel

import "core:mem"
import "core:strings"

// The general statement and expression printer. Every rule is a port of the
// corresponding Prettier rule, because the goal is byte-identical output.
// Anything this printer does not know how to print sets `failed`, and the
// caller then keeps the statement's original source text.

// Node categories in Prettier's vocabulary. Parenthesis and layout rules ask
// about the kind of the parent, so each path entry records one.
FormatNodeKind :: enum u8 {
	Root,
	Program,
	Block,
	Expression_Statement,
	Return,
	Throw,
	If,
	While,
	Do_While,
	For,
	For_In,
	For_Of,
	Switch,
	Switch_Case,
	Labeled,
	Try,
	Catch_Clause,
	With,
	Variable_Declaration,
	Variable_Declarator,
	Function_Declaration,
	Function_Expression,
	Arrow_Function,
	Class_Declaration,
	Class_Expression,
	Class_Method,
	Class_Property,
	Export_Default,
	Export_Named,
	Property,
	Object_Method,
	Object,
	Array,
	Object_Pattern,
	Array_Pattern,
	Assignment_Pattern,
	Rest_Element,
	Member,
	Call,
	New,
	Import_Expression,
	Conditional,
	Binary,
	Logical,
	Assignment,
	Sequence,
	Unary,
	Update,
	Await,
	Yield,
	Spread,
	Template,
	Tagged_Template,
	Identifier,
	String,
	Number,
	Literal,
	This,
	Super,
	Meta_Property,
	Private_Name,
	TS_As,
	TS_Satisfies,
	TS_Non_Null,
	TS_Type_Assertion,
	TS_Instantiation,
	JSX,
	Other,
}

// The property of the parent that holds the node.
FormatKey :: enum u8 {
	None,
	Body,
	Expression,
	Callee,
	Arguments,
	Object,
	Property,
	Left,
	Right,
	Test,
	Consequent,
	Alternate,
	Argument,
	Init,
	Update,
	Id,
	Key,
	Value,
	Elements,
	Expressions,
	Properties,
	Tag,
	Quasi,
	Super_Class,
	Declaration,
	Declarations,
	Discriminant,
	Params,
	Param,
	Cases,
	Block,
	Handler,
	Finalizer,
	Label,
}

FormatPathEntry :: struct {
	kind:       FormatNodeKind,
	key:        FormatKey,
	// The expression is the head of an optional chain. The parser wraps it in
	// a ChainExpression, which Prettier's reference AST does not have.
	chain_root: bool,
	expr:       ^Expression,
	stmt:       ^Statement,
	node:       rawptr,
}

FormatAssignLayout :: enum u8 {
	None,
	Only_Left,
	Break_After_Operator,
	Never_Break_After_Operator,
	Fluid,
	Break_Lhs,
	Chain,
	Chain_Tail,
	Chain_Tail_Arrow_Chain,
}

// Options that a parent passes to the printer of one child.
FormatArgs :: struct {
	expand_first_arg: bool,
	expand_last_arg:  bool,
	layout:           FormatAssignLayout,
}

FORMAT_DEPTH_MAX :: 200

FormatContext :: struct {
	using docs:  FormatDocs,
	source:      string,
	options:     FormatOptions,
	// Prettier's TypeScript parsers keep the quotes of numeric keys.
	typescript:  bool,
	// Every comment of the file in source order, and the number of them
	// that the current statement's document prints.
	comments:    []Comment,
	comments_printed: int,
	// One stamp per comment: the statement that last printed it. A printer
	// may run twice over the same list, and each comment must count once.
	comment_stamps: []u32,
	comment_stamp:  u32,
	path:        [dynamic]FormatPathEntry,
	// Set when the statement uses syntax this printer does not cover.
	failed:      bool,
	// Set when an argument printed for hugging turns out to need a break
	// that hugging forbids. The call printer then lays out all arguments.
	bailout:     bool,
	// Arguments print once in their normal form, however many layouts the
	// call printer goes on to try. This keeps nested callbacks linear.
	arg_cache:   map[rawptr]Doc,
	// The object pattern that is a function's only parameter. It leaves its
	// braces to the parameter list's group.
	hug_pattern: rawptr,
}

// `persistent` holds the path and the cache for the whole file. `scratch`
// holds the documents of one statement, and the caller resets it between
// statements so that a large file never holds more than one statement's
// documents at a time.
format_context_init :: proc(
	f: ^FormatContext,
	source: string,
	options: FormatOptions,
	persistent: mem.Allocator,
	scratch: mem.Allocator,
) {
	f^ = {}
	f.alloc = scratch
	f.source = source
	f.options = options
	// The full capacity is reserved up front, so entries never move and
	// printers may hold pointers to them across nested prints.
	f.path = make([dynamic]FormatPathEntry, 0, FORMAT_DEPTH_MAX, persistent)
	f.arg_cache = make(map[rawptr]Doc, 16, persistent)
	append(&f.path, FormatPathEntry{kind = .Root})
}

format_fail :: proc(f: ^FormatContext) -> Doc {
	f.failed = true
	return nil
}

format_path_push :: proc(f: ^FormatContext, entry: FormatPathEntry) -> bool {
	if len(f.path) >= FORMAT_DEPTH_MAX {
		f.failed = true
		return false
	}
	append(&f.path, entry)
	return true
}

format_path_pop :: proc(f: ^FormatContext) {
	assert(len(f.path) > 1)
	pop(&f.path)
}

// Level 0 is the node being printed, 1 its parent, and so on. Levels beyond
// the root return the root entry, whose kind matches nothing.
format_path_at :: proc(f: ^FormatContext, level: int) -> ^FormatPathEntry {
	assert(level >= 0)
	index := len(f.path) - 1 - level
	if index < 0 {index = 0}
	return &f.path[index]
}

format_parent :: #force_inline proc(f: ^FormatContext) -> ^FormatPathEntry {
	return format_path_at(f, 1)
}

// Shorthand builders. Layout code reads best when it stays close to the
// shape of the document it builds.
ft :: #force_inline proc(f: ^FormatContext, text: string) -> Doc {
	return doc_text(f, text)
}

fc :: #force_inline proc(f: ^FormatContext, parts: ..Doc) -> Doc {
	return doc_concat(f, ..parts)
}

fg :: #force_inline proc(f: ^FormatContext, parts: ..Doc) -> Doc {
	return doc_group(f, doc_concat(f, ..parts))
}

fi :: #force_inline proc(f: ^FormatContext, parts: ..Doc) -> Doc {
	return doc_indent(f, doc_concat(f, ..parts))
}

// ---------------------------------------------------------------------------
// Source text queries
// ---------------------------------------------------------------------------

@(private = "file")
format_is_newline :: #force_inline proc(char: u8) -> bool {
	return char == '\n' || char == '\r'
}

format_has_newline_in_range :: proc(text: string, start, end: u32) -> bool {
	assert(start <= end)
	for index in start ..< min(end, u32(len(text))) {
		if format_is_newline(text[index]) {return true}
	}
	return false
}

@(private = "file")
format_skip_chars :: proc(text: string, start: int, chars: string) -> int {
	index := start
	for index < len(text) && strings.index_byte(chars, text[index]) >= 0 {index += 1}
	return index
}

@(private = "file")
format_skip_inline_comment :: proc(text: string, start: int) -> int {
	if start + 1 < len(text) && text[start] == '/' && text[start + 1] == '*' {
		for index := start + 2; index + 1 < len(text); index += 1 {
			if text[index] == '*' && text[index + 1] == '/' {return index + 2}
		}
	}
	return start
}

@(private = "file")
format_skip_trailing_comment :: proc(text: string, start: int) -> int {
	if start + 1 < len(text) && text[start] == '/' && text[start + 1] == '/' {
		index := start
		for index < len(text) && !format_is_newline(text[index]) {index += 1}
		return index
	}
	return start
}

@(private = "file")
format_skip_newline :: proc(text: string, start: int) -> int {
	if start >= len(text) {return start}
	if text[start] == '\r' && start + 1 < len(text) && text[start + 1] == '\n' {
		return start + 2
	}
	if format_is_newline(text[start]) {return start + 1}
	if strings.has_prefix(text[start:], " ") || strings.has_prefix(text[start:], " ") {
		return start + 3
	}
	return start
}

format_has_newline_after :: proc(text: string, start: int) -> bool {
	index := format_skip_chars(text, start, " \t")
	return format_skip_newline(text, index) != index
}

// True when a blank line follows the line that the offset ends on. Prettier
// keeps at most one blank line between statements, members and arguments.
format_is_next_line_empty :: proc(text: string, end: u32) -> bool {
	previous := -1
	index := int(end)
	for index != previous {
		previous = index
		index = format_skip_chars(text, index, ",; \t")
		index = format_skip_inline_comment(text, index)
		index = format_skip_chars(text, index, " \t")
	}
	index = format_skip_trailing_comment(text, index)
	index = format_skip_newline(text, index)
	return format_has_newline_after(text, index)
}

// The offset of the next character that is neither whitespace nor comment.
format_next_code_index :: proc(text: string, start: u32) -> int {
	previous := -1
	index := int(start)
	for index != previous {
		previous = index
		index = format_skip_chars(text, index, " \t")
		index = format_skip_inline_comment(text, index)
		index = format_skip_trailing_comment(text, index)
		index = format_skip_newline(text, index)
	}
	return index
}

// ---------------------------------------------------------------------------
// Document queries
// ---------------------------------------------------------------------------

doc_will_break :: #force_inline proc(doc: Doc) -> bool {
	return doc != nil && doc.will_break
}

doc_can_break :: proc(doc: Doc) -> bool {
	if doc == nil {return false}
	switch doc.kind {
	case .Line:
		return true
	case .Text, .Break_Parent, .Line_Suffix_Boundary:
		return false
	case .Concat, .Fill:
		for part in doc.parts {
			if doc_can_break(part) {return true}
		}
		return false
	case .Group, .Indent, .Align, .Indent_If_Break, .Line_Suffix:
		return doc_can_break(doc.contents)
	case .If_Break:
		return doc_can_break(doc.contents) || doc_can_break(doc.flat)
	}
	return false
}

// The text of a document made only of text, as Prettier's cleanDoc would
// merge it. The second result is false for any other document.
doc_plain_text :: proc(f: ^FormatContext, doc: Doc) -> (string, bool) {
	if doc == nil {return "", true}
	if doc.kind == .Text {return doc.text, true}
	if doc.kind != .Concat {return "", false}
	out := strings.builder_make(f.alloc)
	for part in doc.parts {
		text, plain := doc_plain_text(f, part)
		if !plain {return "", false}
		strings.write_string(&out, text)
	}
	return strings.to_string(out), true
}

// Replaces every optional line break with its flat form.
doc_remove_lines :: proc(f: ^FormatContext, doc: Doc) -> Doc {
	if doc == nil {return nil}
	switch doc.kind {
	case .Text, .Break_Parent, .Line_Suffix_Boundary:
		return doc
	case .Line:
		if doc.line == .Normal {return ft(f, " ")}
		if doc.line == .Soft {return nil}
		return doc
	case .If_Break:
		return doc_remove_lines(f, doc.flat)
	case .Concat:
		parts := make([]Doc, len(doc.parts), f.alloc)
		for part, index in doc.parts {parts[index] = doc_remove_lines(f, part)}
		result := doc_concat(f, ..parts)
		if doc.label != .None {return doc_label(f, doc.label, result)}
		return result
	case .Fill:
		parts := make([]Doc, len(doc.parts), f.alloc)
		for part, index in doc.parts {parts[index] = doc_remove_lines(f, part)}
		return doc_fill(f, parts)
	case .Indent:
		return doc_indent(f, doc_remove_lines(f, doc.contents))
	case .Align:
		return doc_align(f, doc.align, doc_remove_lines(f, doc.contents))
	case .Indent_If_Break:
		return doc_indent_if_break(f, doc_remove_lines(f, doc.contents), doc.group_id, doc.negate)
	case .Line_Suffix:
		return doc_line_suffix(f, doc_remove_lines(f, doc.contents))
	case .Group:
		if doc.conditional {
			states := make([]Doc, len(doc.parts), f.alloc)
			for part, index in doc.parts {states[index] = doc_remove_lines(f, part)}
			return doc_conditional_group(f, states, doc.broken)
		}
		return doc_group(f, doc_remove_lines(f, doc.contents), doc.broken, doc.group_id)
	}
	return doc
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

// Builds the document for one top-level statement, or returns false when the
// statement must keep its original text.
format_statement_doc :: proc(
	f: ^FormatContext,
	program: ^Program,
	index: int,
) -> (
	doc: Doc,
	ok: bool,
) {
	assert(index < len(program.body))
	assert(len(f.path) == 1)
	f.failed = false
	f.bailout = false
	f.comments_printed = 0
	f.comment_stamp += 1
	clear(&f.arg_cache)
	format_path_push(f, FormatPathEntry{kind = .Program, node = program})
	defer format_path_pop(f)
	statement := program.body[index]
	if format_is_directive_at(f, program.body[:], index) {
		doc = format_directive(f, statement)
	} else {
		doc = format_stmt(f, statement, .Body)
	}
	// A comment that no printer placed would be lost. The statement then
	// keeps its original text.
	loc := get_statement_loc(statement)
	if f.comments_printed != len(format_comments_in(f, loc.start, loc.end)) {f.failed = true}
	return doc, !f.failed && doc != nil
}
