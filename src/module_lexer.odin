package kessel

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import mvirtual "core:mem/virtual"
import "core:strings"

@(private)
cli_module_lex :: proc(path: string) -> int {
	buffer, read_ok := source_read(path)
	if !read_ok {
		fmt.eprintf("Error: could not read %s\n", path)
		return 1
	}
	defer source_release(buffer)
	result, lex_err := module_lex_dependencies(string(buffer.data), context.allocator)
	if lex_err != .None {
		fmt.eprintf("Error: could not scan %s (%v)\n", path, lex_err)
		return 1
	}
	defer module_lex_destroy(&result)
	encoded, json_err := json.marshal(result, {use_enum_names = true}, allocator = context.temp_allocator)
	if json_err != nil {
		fmt.eprintln("Error: could not encode module records")
		return 1
	}
	out_println(string(encoded))
	return 0
}

ModuleDependencyKind :: enum { Static, Reexport, Dynamic, Import_Meta, Import_Equals }
ModuleImportPhase :: enum { Evaluation, Source, Defer }
ModuleDependency :: struct {
	kind: ModuleDependencyKind,
	phase: ModuleImportPhase,
	statement: Loc,
	request: Loc,
	attributes: Maybe(Loc),
	type_only: bool,
	name: Maybe(string),
	// Additive es-module-lexer equivalents, see module_lexer_records.odin.
	import_type: ModuleImportType,
	// End of the specifier or its attributes clause: `statement` without the
	// optional semicolon. Equals statement.end for dynamic imports.
	clause_end: u32,
	// Offset of the `(` of a dynamic import call, nil for every other kind.
	arguments_start: Maybe(u32),
	attribute_entries: [dynamic]ModuleImportAttribute,
}

ModuleLexExport :: struct {
	name: string,
	span: Loc,
	local_name: Maybe(string),
	local_span: Maybe(Loc),
	type_only: bool,
	// True when the name is written as a string literal; `span` and
	// `local_span` then exclude the quotes, which sit one byte either side.
	name_is_string: bool,
	local_is_string: bool,
}

ModuleLexName :: struct {
	text: string,
	span: Loc,
}

ModuleLexResult :: struct {
	dependencies: [dynamic]ModuleDependency,
	exports: [dynamic]ModuleLexExport,
	has_module_syntax: bool,
	// True when the module holds only import declarations, `export ... from`
	// and `export {...}` lists: nothing that evaluates in the module itself.
	facade: bool,
	has_commonjs_syntax: bool,
	format: ModuleFormat,
}

ModuleLexError :: enum { None, Invalid_Syntax, Depth_Limit, Source_Too_Large, Allocation_Error }

ModuleLexFrame :: struct {
	close: TokenType,
	control: bool,
	import_index: Maybe(int),
	argument_end: u32,
	literal_end: u32,
}

// `export @decorator class Name {}`: the decorator is an arbitrary expression,
// so the main loop scans it and the class name is taken when `class` arrives.
ModuleLexDecorated :: enum u8 { None, Named, Default }

ModuleLexScanner :: struct {
	lexer: Lexer,
	result: ModuleLexResult,
	allocator: mem.Allocator,
	bindings: ModuleLexBindings,
	facade_broken: bool,
	decorated: ModuleLexDecorated,
	// End of the last token module_lex_import consumed without recording a call.
	consumed_end: u32,
	commonjs_found: bool,
	commonjs_state: ModuleLexCommonJSState,
}

// Scan module dependencies without building an AST. Spans are UTF-8 byte
// offsets. A dynamic request has a name only when its first argument is a
// single string literal. The caller owns the result and its decoded names.
module_lex_dependencies :: proc(source: string, allocator: mem.Allocator) -> (ModuleLexResult, ModuleLexError) {
	assert(allocator.procedure != nil)
	if u64(len(source)) > u64(max(u32)) { return {}, .Source_Too_Large }
	scratch: mvirtual.Arena
	if err := mvirtual.arena_init_growing(&scratch); err != nil { return {}, .Allocation_Error }
	defer mvirtual.arena_destroy(&scratch)
	scan: ModuleLexScanner
	scan.allocator = allocator
	scan.result.dependencies.allocator = allocator
	scan.result.exports.allocator = allocator
	init_lexer(&scan.lexer, source, mvirtual.arena_allocator(&scratch), .Module)
	scan.lexer.skip_regex_validation = true
	err := module_lex_scan(&scan)
	if err != .None {
		module_lex_destroy(&scan.result)
		return {}, err
	}
	return scan.result, .None
}

module_lex_destroy :: proc(result: ^ModuleLexResult) {
	allocator := result.dependencies.allocator
	for &item in result.dependencies {
		if name, ok := item.name.?; ok { delete(name, allocator) }
		module_lex_attributes_destroy(&item)
	}
	delete(result.dependencies)
	for item in result.exports {
		delete(item.name, allocator)
		if local, ok := item.local_name.?; ok { delete(local, allocator) }
	}
	delete(result.exports)
	result^ = {}
}

@(private)
module_lex_advance :: proc(l: ^Lexer) {
	assert(!l.nxt_valid)
	l.cur = lex_token(l)
	l.lit_write_idx ~= 1
}

@(private)
module_lex_string :: proc(l: ^Lexer) -> string {
	token := l.cur
	assert(token.kind == .String)
	slot := l.lit_write_idx ~ 1
	if l.lit_offset[slot] == token.start && l.lit_type[slot] == .String {
		if value, ok := l.lit_value[slot].(string); ok { return value }
	}
	if token.end - token.start < 2 { return "" }
	return l.source[token.start + 1 : token.end - 1]
}

@(private="file")
module_lex_add :: proc(scan: ^ModuleLexScanner, item: ModuleDependency) -> ModuleLexError {
	entry := item
	if name, ok := entry.name.?; ok {
		owned, err := strings.clone(name, scan.allocator)
		if err != nil { return .Allocation_Error }
		entry.name = owned
	}
	_, err := append(&scan.result.dependencies, entry)
	if err == nil { return .None }
	if name, ok := entry.name.?; ok { delete(name, scan.allocator) }
	return .Allocation_Error
}

@(private="file")
module_lex_scan :: proc(scan: ^ModuleLexScanner) -> ModuleLexError {
	MAX_DEPTH :: 512
	l := &scan.lexer
	frames: [MAX_DEPTH]ModuleLexFrame
	depth := 0
	previous := TokenType.EOF
	statement_follows := false
	control_keyword := false
	for l.cur.kind != .EOF {
		closed_import: Maybe(int)
		if statement_follows && (l.cur.kind == .Div || l.cur.kind == .AssignDiv) {
			relex_as_regex(l)
		}
		token := l.cur
		member := previous == .Dot || previous == .OptionalChain
		statement_follows = !member && module_lex_operand_follows(token.kind)
		control_paren := control_keyword && token.kind == .LParen
		control_keyword = !member && module_lex_control(token.kind)
		if token.kind == .Invalid { return .Invalid_Syntax }
		if err := module_lex_binding_step(scan, depth, previous); err != .None { return err }
		module_lex_commonjs_step(scan, previous)

		if token.kind == .Import && !member {
			pending, err := module_lex_import(scan, depth == 0)
			if err != .None { return err }
			if pending == nil {
				if depth > 0 { module_lex_note_consumed(scan, &frames[depth - 1], token.start) }
				previous = .Import
				continue
			}
			if depth == len(frames) { return .Depth_Limit }
			frames[depth] = {close = .RParen, import_index = pending}
			depth += 1
			module_lex_advance(l)
			entry := &scan.result.dependencies[pending.?]
			entry.request.start = module_lex_start(l.cur)
			if l.cur.kind == .String { frames[depth - 1].literal_end = l.cur.end }
			previous = .LParen
			continue
		}
		if token.kind == .Export && depth == 0 && !member {
			if err := module_lex_export(scan); err != .None { return err }
			previous = .Export
			continue
		}
		if token.kind == .Class && depth == 0 && scan.decorated != .None {
			if err := module_lex_decorated_class(scan); err != .None { return err }
			previous = .Class
			continue
		}
		if depth > 0 {
			frame := &frames[depth - 1]
			if index, ok := frame.import_index.?; ok {
				if err := module_lex_argument(scan, frame, index); err != .None { return err }
			}
			if token.kind == frame.close {
				closed_import = frame.import_index
				statement_follows = frame.control
				depth -= 1
				if depth > 0 { module_lex_note_nested_end(scan, &frames[depth - 1], token) }
			}
		}
		// Only declarations handled above and empty statements keep a facade.
		if token.kind != .Semi { scan.facade_broken = true }
		if close, ok := module_lex_close_for(token.kind); ok {
			if depth == len(frames) { return .Depth_Limit }
			// `control` means a statement may follow the closing token, so a
			// `/` there starts a regular expression: after `if (x)` and after
			// the `}` of a block, but not after `(x)` or an object literal.
			block := token.kind == .LBrace && module_lex_opens_block(previous)
			frames[depth] = {close = close, control = control_paren || block}
			depth += 1
		}
		previous = token.kind
		module_lex_advance(l)
		if index, ok := closed_import.?; ok {
			if err := module_lex_finish_call(scan, index); err != .None { return err }
		}
	}
	if depth != 0 || len(l.lexer_errors) != 0 { return .Invalid_Syntax }
	module_lex_remove_methods(scan)
	return module_lex_finish(scan)
}

@(private="file")
module_lex_note_nested_end :: proc(scan: ^ModuleLexScanner, parent: ^ModuleLexFrame, token: FastToken) {
	index, ok := parent.import_index.?
	if !ok { return }
	entry := &scan.result.dependencies[index]
	if parent.argument_end == 0 {
		entry.request.end = module_lex_end(token)
	} else {
		module_lex_extend_attributes(entry, token)
	}
}

// `import.meta` and friends are consumed whole by module_lex_import, so the
// argument tracking of an enclosing `import(...)` never sees their tokens.
// Report them as one operand: `import(import.meta.url)` has a request.
@(private="file")
module_lex_note_consumed :: proc(scan: ^ModuleLexScanner, parent: ^ModuleLexFrame, start: u32) {
	assert(start < scan.consumed_end)
	operand := FastToken{start = start, end = scan.consumed_end, kind = .Identifier}
	module_lex_note_nested_end(scan, parent, operand)
}

@(private="file")
module_lex_start :: proc(token: FastToken) -> u32 {
	if token.kind == .Template || token.kind == .TemplateHead { return token.start - 1 }
	return token.start
}

@(private="file")
module_lex_end :: proc(token: FastToken) -> u32 {
	if token.kind == .Template || token.kind == .TemplateTail { return token.end + 1 }
	return token.end
}

@(private="file")
module_lex_close_for :: proc(kind: TokenType) -> (TokenType, bool) {
	#partial switch kind {
	case .LBrace: return .RBrace, true
	case .LBracket: return .RBracket, true
	case .LParen: return .RParen, true
	case .TemplateHead: return .TemplateTail, true
	}
	return .EOF, false
}

// Keywords the lexer does not already treat as regex context but after which
// an operand, not a division, follows: `do` and `else` start a statement,
// and `yield` / `await` are operators in module code, where neither can be
// an identifier.
@(private="file")
module_lex_operand_follows :: proc(kind: TokenType) -> bool {
	#partial switch kind {
	case .Do, .Else, .Yield, .Await:
		return true
	}
	return false
}

// Whether a `{` after `previous` opens a statement block or function body
// rather than an object literal. `:` stays an expression context: it is far
// more often a property value or a conditional than a label.
@(private="file")
module_lex_opens_block :: proc(previous: TokenType) -> bool {
	#partial switch previous {
	case .RParen, .Semi, .LBrace, .RBrace, .Arrow, .Else, .Do, .Try, .Finally, .EOF:
		return true
	}
	return false
}

@(private="file")
module_lex_control :: proc(kind: TokenType) -> bool {
	#partial switch kind {
	case .If, .While, .For, .With, .Catch, .Switch:
		return true
	}
	return false
}

@(private="file")
module_lex_import :: proc(scan: ^ModuleLexScanner, top_level: bool) -> (Maybe(int), ModuleLexError) {
	l := &scan.lexer
	keyword := l.cur
	scan.consumed_end = keyword.end
	module_lex_advance(l)
	// Everything but a top-level import declaration is an expression.
	declaration := top_level && l.cur.kind != .LParen && l.cur.kind != .Dot && l.cur.kind != .Colon
	if !declaration { scan.facade_broken = true }
	if l.cur.kind == .LParen {
		return module_lex_dynamic_record(scan, keyword.start, .Evaluation)
	}
	if l.cur.kind == .Dot {
		module_lex_advance(l)
		member := token_source(l, l.cur)
		if member == "meta" {
			entry := ModuleDependency{
				kind = .Import_Meta,
				statement = {start = keyword.start, end = l.cur.end},
			}
			scan.result.has_module_syntax = true
			scan.consumed_end = l.cur.end
			err := module_lex_add(scan, entry)
			module_lex_advance(l)
			return nil, err
		}
		if member == "source" || member == "defer" {
			scan.consumed_end = l.cur.end
			module_lex_advance(l)
			if l.cur.kind == .LParen {
				phase := ModuleImportPhase.Source if member == "source" else ModuleImportPhase.Defer
				return module_lex_dynamic_record(scan, keyword.start, phase)
			}
		}
		return nil, .None
	}
	if !top_level || l.cur.kind == .Colon { return nil, .None }
	scan.result.has_module_syntax = true
	return nil, module_lex_import_declaration(scan, keyword.start)
}

@(private="file")
module_lex_dynamic_record :: proc(scan: ^ModuleLexScanner, start: u32, phase: ModuleImportPhase) -> (Maybe(int), ModuleLexError) {
	assert(scan.lexer.cur.kind == .LParen)
	entry := ModuleDependency{
		kind = .Dynamic,
		phase = phase,
		statement = {start = start},
		arguments_start = scan.lexer.cur.start,
	}
	index := len(scan.result.dependencies)
	return index, module_lex_add(scan, entry)
}

@(private="file")
module_lex_import_declaration :: proc(scan: ^ModuleLexScanner, start: u32) -> ModuleLexError {
	l := &scan.lexer
	contextual := token_source(l, l.cur)
	type_only := false
	phase := ModuleImportPhase.Evaluation
	if contextual == "type" || contextual == "source" || contextual == "defer" {
		module_lex_advance(l)
		if l.cur.kind == .From {
			module_lex_advance(l)
			if l.cur.kind == .String {
				return module_lex_static_name(scan, .Static, start, false, .Evaluation)
			}
		}
		switch contextual {
		case "type": type_only = l.cur.kind != .Comma
		case "source":
			if l.cur.kind == .Identifier || l.cur.kind == .From { phase = .Source }
		case "defer":
			if l.cur.kind == .Mul { phase = .Defer }
		}
	}
	return module_lex_static(scan, .Static, start, type_only, phase)
}

@(private="file")
module_lex_export :: proc(scan: ^ModuleLexScanner) -> ModuleLexError {
	l := &scan.lexer
	keyword := l.cur
	scan.result.has_module_syntax = true
	scan.decorated = .None
	module_lex_advance(l)
	type_only := token_source(l, l.cur) == "type"
	if type_only { module_lex_advance(l) }
	#partial switch l.cur.kind {
	case .LBrace:
		start := len(scan.result.exports)
		err := module_lex_export_list(scan, type_only)
		if err != .None { return err }
		if l.cur.kind != .From { return .None }
		for &entry in scan.result.exports[start:] {
			if name, ok := entry.local_name.?; ok { delete(name, scan.allocator) }
			entry.local_name, entry.local_span = nil, nil
			entry.local_is_string = false
		}
		return module_lex_static(scan, .Reexport, keyword.start, type_only)
	case .Mul:
		module_lex_advance(l)
		if l.cur.kind == .As {
			module_lex_advance(l)
			if !module_lex_is_name(l.cur.kind) { return .Invalid_Syntax }
			if err := module_lex_add_export(scan, type_only); err != .None { return err }
			module_lex_advance(l)
		}
		return module_lex_static(scan, .Reexport, keyword.start, type_only)
	case .Import:
		scan.facade_broken = true
		module_lex_advance(l)
		if !can_be_binding_identifier(l.cur.kind) { return .Invalid_Syntax }
		name, span := module_lex_export_name(l)
		if err := module_lex_append_export(scan, name, span, type_only, ModuleLexName{name, span}); err != .None {
			return err
		}
		module_lex_advance(l)
		return module_lex_import_equals(scan, keyword.start, type_only)
	case .Default:
		scan.facade_broken = true
		name, span := module_lex_export_name(l)
		module_lex_advance(l)
		if l.cur.kind == .At { scan.decorated = .Default }
		local := module_lex_function_or_class_name(l)
		return module_lex_append_export(scan, name, span, type_only, local)
	}
	scan.facade_broken = true
	if l.cur.kind == .At {
		scan.decorated = .Named
		return .None
	}
	return module_lex_declaration_export(scan, type_only)
}

// Record the class that ends an `export @decorator` or
// `export default @decorator` declaration.
@(private="file")
module_lex_decorated_class :: proc(scan: ^ModuleLexScanner) -> ModuleLexError {
	assert(scan.lexer.cur.kind == .Class)
	assert(scan.decorated != .None)
	named := scan.decorated == .Named
	scan.decorated = .None
	local, has_name := module_lex_function_or_class_name(&scan.lexer).?
	if !has_name { return .None }
	if named { return module_lex_append_export(scan, local.text, local.span, false, local) }
	// The default record was appended when `default` was seen, without a
	// local name; nothing can have been exported since.
	assert(len(scan.result.exports) > 0)
	entry := &scan.result.exports[len(scan.result.exports) - 1]
	assert(entry.local_name == nil)
	owned, err := strings.clone(local.text, scan.allocator)
	if err != nil { return .Allocation_Error }
	entry.local_name, entry.local_span = owned, local.span
	return .None
}

@(private="file")
module_lex_export_list :: proc(scan: ^ModuleLexScanner, type_only: bool) -> ModuleLexError {
	l := &scan.lexer
	module_lex_advance(l)
	for l.cur.kind != .RBrace {
		if !module_lex_is_name(l.cur.kind) { return .Invalid_Syntax }
		name, span := module_lex_export_name(l)
		item_type_only := type_only
		module_lex_advance(l)
		if name == "type" && l.cur.kind != .As && module_lex_is_name(l.cur.kind) {
			name, span = module_lex_export_name(l)
			item_type_only = true
			module_lex_advance(l)
		}
		local := ModuleLexName{name, span}
		if l.cur.kind == .As {
			module_lex_advance(l)
			if !module_lex_is_name(l.cur.kind) { return .Invalid_Syntax }
			name, span = module_lex_export_name(l)
			module_lex_advance(l)
		}
		if err := module_lex_append_export(scan, name, span, item_type_only, local); err != .None { return err }
		if l.cur.kind == .RBrace { break }
		if l.cur.kind != .Comma { return .Invalid_Syntax }
		module_lex_advance(l)
	}
	module_lex_advance(l)
	return .None
}

@(private="file")
module_lex_declaration_export :: proc(scan: ^ModuleLexScanner, type_only: bool) -> ModuleLexError {
	l := &scan.lexer
	if type_only { return module_lex_export_binding_name(scan, true) }

	is_type_only := token_source(l, l.cur) == "declare"
	if is_type_only { module_lex_advance(l) }
	if token_source(l, l.cur) == "abstract" { module_lex_advance(l) }
	if l.cur.kind == .Const || l.cur.kind == .Let || l.cur.kind == .Var {
		kind := l.cur.kind
		module_lex_advance(l)
		if kind == .Const && token_source(l, l.cur) == "enum" {
			module_lex_advance(l)
			return module_lex_export_binding_name(scan, is_type_only)
		}
		scan.bindings.mode = .Binding
		scan.bindings.type_only = is_type_only
		return .None
	}
	switch token_source(l, l.cur) {
	case "interface":
		module_lex_advance(l)
		return module_lex_export_binding_name(scan, true)
	case "enum", "namespace", "module":
		module_lex_advance(l)
		return module_lex_export_binding_name(scan, is_type_only)
	}
	local := module_lex_function_or_class_name(l)
	if name, ok := local.?; ok {
		return module_lex_append_export(scan, name.text, name.span, is_type_only, name)
	}
	return .None
}

@(private="file")
module_lex_export_binding_name :: proc(scan: ^ModuleLexScanner, type_only: bool) -> ModuleLexError {
	l := &scan.lexer
	if !can_be_binding_identifier(l.cur.kind) { return .None }
	name, span := module_lex_export_name(l)
	module_lex_advance(l)
	return module_lex_append_export(scan, name, span, type_only, ModuleLexName{name, span})
}

@(private="file")
module_lex_function_or_class_name :: proc(l: ^Lexer) -> Maybe(ModuleLexName) {
	if l.cur.kind == .Async {
		module_lex_advance(l)
		if l.cur.kind != .Function || l.cur.flags & FLAG_NEW_LINE != 0 { return nil }
	}
	kind := l.cur.kind
	if kind != .Function && kind != .Class { return nil }
	module_lex_advance(l)
	if kind == .Function && l.cur.kind == .Mul { module_lex_advance(l) }
	// `class extends Base {}` and TypeScript's `class implements Shape {}`
	// are anonymous: neither keyword can name a class in module code.
	anonymous := l.cur.kind == .Extends || token_source(l, l.cur) == "implements"
	if anonymous || !can_be_binding_identifier(l.cur.kind) { return nil }
	name, span := module_lex_export_name(l)
	module_lex_advance(l)
	return ModuleLexName{name, span}
}

@(private)
module_lex_is_name :: proc(kind: TokenType) -> bool {
	// ModuleExportName accepts IdentifierName, including literal keywords.
	if kind == .Null || kind == .True || kind == .False { return true }
	return kind == .String || (.Break <= kind && kind <= .Identifier)
}

@(private)
module_lex_export_name :: proc(l: ^Lexer) -> (string, Loc) {
	token := l.cur
	if token.kind == .String {
		return module_lex_string(l), {start = token.start + 1, end = token.end - 1}
	}
	slot := l.lit_write_idx ~ 1
	if l.lit_offset[slot] == token.start && l.lit_type[slot] == .Identifier {
		if value, ok := l.lit_value[slot].(string); ok { return value, {start = token.start, end = token.end} }
	}
	return token_source(l, token), {start = token.start, end = token.end}
}

@(private="file")
module_lex_add_export :: proc(scan: ^ModuleLexScanner, type_only: bool) -> ModuleLexError {
	name, span := module_lex_export_name(&scan.lexer)
	return module_lex_append_export(scan, name, span, type_only)
}

@(private="file")
module_lex_append_export :: proc(
	scan: ^ModuleLexScanner,
	name: string,
	span: Loc,
	type_only: bool,
	local: Maybe(ModuleLexName) = nil,
) -> ModuleLexError {
	owned, clone_err := strings.clone(name, scan.allocator)
	if clone_err != nil { return .Allocation_Error }
	entry := ModuleLexExport{name = owned, span = span, type_only = type_only}
	entry.name_is_string = module_lex_span_quoted(scan.lexer.source, span)
	if binding, ok := local.?; ok {
		entry.local_is_string = module_lex_span_quoted(scan.lexer.source, binding.span)
		local_name, err := strings.clone(binding.text, scan.allocator)
		if err != nil {
			delete(owned, scan.allocator)
			return .Allocation_Error
		}
		entry.local_name, entry.local_span = local_name, binding.span
	}
	_, err := append(&scan.result.exports, entry)
	if err == nil { return .None }
	delete(owned, scan.allocator)
	if local_name, ok := entry.local_name.?; ok { delete(local_name, scan.allocator) }
	return .Allocation_Error
}

@(private="file")
module_lex_static :: proc(scan: ^ModuleLexScanner, kind: ModuleDependencyKind, start: u32, type_only: bool, phase: ModuleImportPhase = .Evaluation) -> ModuleLexError {
	l := &scan.lexer
	if kind == .Static && l.cur.kind == .String { return module_lex_static_name(scan, kind, start, type_only, phase) }
	braces: int
	for l.cur.kind != .EOF && l.cur.kind != .Semi {
		#partial switch l.cur.kind {
		case .LBrace: braces += 1
		case .RBrace: braces -= 1
		case .Assign:
			if braces == 0 && kind == .Static { return module_lex_import_equals(scan, start, type_only) }
		case .From:
			if braces == 0 {
				module_lex_advance(l)
				if l.cur.kind == .From { continue }
				if l.cur.kind != .String { return .Invalid_Syntax }
				return module_lex_static_name(scan, kind, start, type_only, phase)
			}
		}
		module_lex_advance(l)
	}
	return .Invalid_Syntax
}

@(private="file")
module_lex_import_equals :: proc(scan: ^ModuleLexScanner, start: u32, type_only: bool) -> ModuleLexError {
	l := &scan.lexer
	scan.facade_broken = true
	if l.cur.kind != .Assign { return .Invalid_Syntax }
	module_lex_advance(l)
	if !module_lex_is_name(l.cur.kind) { return .Invalid_Syntax }
	require := token_source(l, l.cur) == "require"
	module_lex_advance(l)
	if require && l.cur.kind == .LParen {
		module_lex_advance(l)
		if l.cur.kind != .String { return .Invalid_Syntax }
		source := l.cur
		entry := ModuleDependency{
			kind = .Import_Equals,
			statement = {start = start},
			request = {start = source.start + 1, end = source.end - 1},
			name = module_lex_string(l),
			type_only = type_only,
		}
		module_lex_advance(l)
		if l.cur.kind != .RParen { return .Invalid_Syntax }
		entry.statement.end = l.cur.end
		entry.clause_end = l.cur.end
		module_lex_advance(l)
		if l.cur.kind == .Semi {
			entry.statement.end = l.cur.end
			module_lex_advance(l)
		}
		return module_lex_add(scan, entry)
	}
	for l.cur.kind == .Dot {
		module_lex_advance(l)
		if !module_lex_is_name(l.cur.kind) { return .Invalid_Syntax }
		module_lex_advance(l)
	}
	if l.cur.kind == .Semi { module_lex_advance(l) }
	return .None
}

@(private="file")
module_lex_static_name :: proc(scan: ^ModuleLexScanner, kind: ModuleDependencyKind, start: u32, type_only: bool, phase: ModuleImportPhase = .Evaluation) -> ModuleLexError {
	l := &scan.lexer
	source := l.cur
	entry := ModuleDependency{
		kind = kind,
		phase = phase,
		statement = {start = start, end = source.end},
		request = {start = source.start + 1, end = source.end - 1},
		name = module_lex_string(l),
		type_only = type_only,
		clause_end = source.end,
	}
	module_lex_advance(l)
	// Only the legacy `assert` keyword carries [no LineTerminator here]; a
	// `with` clause may start on the next line (ECMA-262 WithClause).
	same_line := l.cur.flags & FLAG_NEW_LINE == 0
	if l.cur.kind == .With || (l.cur.kind == .Assert && same_line) {
		module_lex_advance(l)
		if l.cur.kind != .LBrace { return .Invalid_Syntax }
		block_start := l.cur.start
		module_lex_advance(l)
		for l.cur.kind != .RBrace {
			if l.cur.kind == .EOF || l.cur.kind == .Invalid { return .Invalid_Syntax }
			module_lex_advance(l)
		}
		entry.attributes = Loc{start = block_start, end = l.cur.end}
		entry.statement.end = l.cur.end
		entry.clause_end = l.cur.end
		module_lex_advance(l)
	}
	if l.cur.kind == .Semi {
		entry.statement.end = l.cur.end
		module_lex_advance(l)
	}
	return module_lex_add(scan, entry)
}

@(private="file")
module_lex_argument :: proc(scan: ^ModuleLexScanner, frame: ^ModuleLexFrame, index: int) -> ModuleLexError {
	l := &scan.lexer
	entry := &scan.result.dependencies[index]
	if l.cur.kind == .RParen { entry.statement.end = l.cur.end }
	if frame.argument_end != 0 {
		if l.cur.kind != .Comma && l.cur.kind != .RParen { module_lex_extend_attributes(entry, l.cur) }
		return .None
	}
	if l.cur.kind == .Comma || l.cur.kind == .RParen {
		if entry.request.end == 0 && l.cur.kind == .Comma { return .Invalid_Syntax }
		frame.argument_end = entry.request.end
		if entry.request.end != frame.literal_end && entry.name != nil {
			delete(entry.name.?, scan.allocator)
			entry.name = nil
		}
		return .None
	}
	entry.request.end = module_lex_end(l.cur)
	if entry.request.start == module_lex_start(l.cur) && frame.literal_end != 0 {
		name, err := strings.clone(module_lex_string(l), scan.allocator)
		if err != nil { return .Allocation_Error }
		entry.name = name
	}
	return .None
}


@(private="file")
module_lex_extend_attributes :: proc(entry: ^ModuleDependency, token: FastToken) {
	if span, ok := entry.attributes.?; ok {
		entry.attributes = Loc{start = span.start, end = module_lex_end(token)}
	} else {
		entry.attributes = Loc{start = module_lex_start(token), end = module_lex_end(token)}
	}
}


@(private="file")
module_lex_finish_call :: proc(scan: ^ModuleLexScanner, index: int) -> ModuleLexError {
	entry := &scan.result.dependencies[index]
	next := scan.lexer.cur
	if next.kind == .LBrace && (next.flags & FLAG_NEW_LINE == 0 || entry.request.end == 0) {
		// A method named import has a body after its parameter list.
		entry.statement.end = 0
		return .None
	}
	if entry.request.end == 0 { return .Invalid_Syntax }
	return .None
}

@(private="file")
module_lex_remove_methods :: proc(scan: ^ModuleLexScanner) {
	length := 0
	for entry in scan.result.dependencies {
		if entry.statement.end == 0 {
			if name, ok := entry.name.?; ok { delete(name, scan.allocator) }
			continue
		}
		scan.result.dependencies[length] = entry
		length += 1
	}
	resize(&scan.result.dependencies, length)
}

ModuleLexBindingMode :: enum { Inactive, Binding, After, Type, Initializer }
ModuleLexPatternMode :: enum { Key, After_Key, Key_Colon, Binding, After, Initializer }

ModuleLexPattern :: struct {
	depth: int,
	close: TokenType,
	mode: ModuleLexPatternMode,
	key: ModuleLexName,
	shorthand: bool,
}

// Binding patterns share the scanner's delimiter depth. The expression scan
// remains active inside initializers and computed keys, including imports.
ModuleLexBindings :: struct {
	mode: ModuleLexBindingMode,
	type_only: bool,
	type_angles: int,
	initializer_type_end: u32,
	patterns: [512]ModuleLexPattern,
	pattern_count: int,
}

@(private="file")
module_lex_binding_step :: proc(scan: ^ModuleLexScanner, depth: int, previous: TokenType) -> ModuleLexError {
	bindings := &scan.bindings
	if bindings.mode == .Inactive { return .None }
	if bindings.pattern_count != 0 { return module_lex_pattern_step(scan, depth) }
	if depth != 0 { return .None }
	token := scan.lexer.cur
	kind := token.kind
	if token.start < bindings.initializer_type_end { return .None }
	if bindings.mode == .Initializer && kind == .LAngle {
		bindings.initializer_type_end = module_lex_generic_end(&scan.lexer, previous)
		if bindings.initializer_type_end != 0 { return .None }
	}
	if bindings.mode == .Binding {
		if err := module_lex_take_binding(scan, depth); err != .None { return err }
		bindings.mode = .After
		return .None
	}
	if bindings.mode == .Type {
		module_lex_type_angles(bindings, kind)
		if bindings.type_angles != 0 { return .None }
	}
	#partial switch kind {
	case .Semi, .Export: bindings.mode = .Inactive
	case .Comma: bindings.mode = .Binding
	case .Assign:
		if bindings.mode != .Initializer { bindings.mode = .Initializer }
	case .Colon:
		if bindings.mode == .After { bindings.mode = .Type }
	case .As, .Satisfies:
		if bindings.mode == .Initializer && previous != .Dot && previous != .OptionalChain {
			bindings.mode = .Type
		}
	case:
		if token.flags & FLAG_NEW_LINE != 0 &&
		   module_lex_expression_can_end(previous) && !module_lex_expression_continues(kind) {
			bindings.mode = .Inactive
		}
	}
	return .None
}

// Probe only the bounded type list and keep the real lexer cursor intact.
@(private="file")
module_lex_generic_end :: proc(l: ^Lexer, previous: TokenType) -> u32 {
	probe := l^
	probe.template_stack = {}
	probe.template_stack.allocator = l.allocator
	probe.lexer_errors = {}
	probe.lexer_errors.allocator = l.allocator
	probe.comments = {}
	probe.collect_comments = false
	angles := 1
	closes: [64]TokenType
	depth := 0
	for _ in 0..<256 {
		module_lex_advance(&probe)
		token := probe.cur
		if token.kind == .EOF || token.kind == .Invalid || token.kind == .Semi { return 0 }
		if depth > 0 && token.kind == closes[depth - 1] {
			depth -= 1
			continue
		}
		if close, ok := module_lex_close_for(token.kind); ok {
			if depth == len(closes) { return 0 }
			closes[depth] = close
			depth += 1
			continue
		}
		if depth != 0 { continue }
		#partial switch token.kind {
		case .Assign:
			if previous != .Assign && previous != .Arrow { return 0 }
		case .LAngle: angles += 1
		case .RAngle: angles -= 1
		case .RShift: angles -= 2
		case .URShift: angles -= 3
		}
		if angles > 0 { continue }
		if angles < 0 { return 0 }
		module_lex_advance(&probe)
		if probe.cur.kind == .LParen || probe.cur.kind == .OptionalChain ||
		   probe.cur.kind == .Template || probe.cur.kind == .TemplateHead {
			return token.end
		}
		return 0
	}
	return 0
}

@(private="file")
module_lex_type_angles :: proc(bindings: ^ModuleLexBindings, kind: TokenType) {
	#partial switch kind {
	case .LAngle: bindings.type_angles += 1
	case .RAngle: bindings.type_angles = max(0, bindings.type_angles - 1)
	case .RShift: bindings.type_angles = max(0, bindings.type_angles - 2)
	case .URShift: bindings.type_angles = max(0, bindings.type_angles - 3)
	}
}

@(private="file")
module_lex_take_binding :: proc(scan: ^ModuleLexScanner, depth: int) -> ModuleLexError {
	l := &scan.lexer
	if l.cur.kind == .LBracket || l.cur.kind == .LBrace {
		bindings := &scan.bindings
		if bindings.pattern_count == len(bindings.patterns) { return .Depth_Limit }
		object := l.cur.kind == .LBrace
		pattern := ModuleLexPattern{
			depth = depth + 1,
			close = .RBrace if object else .RBracket,
			mode = .Key if object else .Binding,
		}
		bindings.patterns[bindings.pattern_count] = pattern
		bindings.pattern_count += 1
		return .None
	}
	if !can_be_binding_identifier(l.cur.kind) { return .Invalid_Syntax }
	name, span := module_lex_export_name(l)
	return module_lex_append_export(scan, name, span, scan.bindings.type_only, ModuleLexName{name, span})
}

@(private="file")
module_lex_pattern_step :: proc(scan: ^ModuleLexScanner, depth: int) -> ModuleLexError {
	bindings := &scan.bindings
	pattern := &bindings.patterns[bindings.pattern_count - 1]
	if depth != pattern.depth { return .None }
	kind := scan.lexer.cur.kind
	if pattern.mode == .After_Key {
		if kind == .Colon {
			pattern.mode = .Binding
			return .None
		}
		if !pattern.shorthand { return .Invalid_Syntax }
		key := pattern.key
		if err := module_lex_append_export(scan, key.text, key.span, bindings.type_only, key); err != .None { return err }
		pattern.mode = .After
	}
	if kind == pattern.close {
		bindings.pattern_count -= 1
		return .None
	}
	if kind == .Comma {
		pattern.mode = .Key if pattern.close == .RBrace else .Binding
		return .None
	}
	switch pattern.mode {
	case .Key:
		return module_lex_pattern_key(scan, pattern)
	case .Key_Colon:
		if kind != .Colon { return .Invalid_Syntax }
		pattern.mode = .Binding
	case .Binding:
		if kind == .Dot3 { return .None }
		pattern.mode = .After
		return module_lex_take_binding(scan, depth)
	case .After:
		if kind != .Assign { return .Invalid_Syntax }
		pattern.mode = .Initializer
	case .Initializer:
	case .After_Key:
		unreachable()
	}
	return .None
}

@(private="file")
module_lex_pattern_key :: proc(scan: ^ModuleLexScanner, pattern: ^ModuleLexPattern) -> ModuleLexError {
	l := &scan.lexer
	#partial switch l.cur.kind {
	case .Dot3: pattern.mode = .Binding
	case .LBracket: pattern.mode = .Key_Colon
	case:
		if !module_lex_is_name(l.cur.kind) && l.cur.kind != .Number && l.cur.kind != .BigInt {
			return .Invalid_Syntax
		}
		text, span := module_lex_export_name(l)
		pattern.key = {text, span}
		pattern.shorthand = can_be_binding_identifier(l.cur.kind)
		pattern.mode = .After_Key
	}
	return .None
}

@(private="file")
module_lex_expression_can_end :: proc(kind: TokenType) -> bool {
	#partial switch kind {
	case .RBrace, .RBracket, .RParen, .Number, .BigInt, .String, .RegularExpression,
	     .Template, .TemplateTail, .True, .False, .Null, .This, .Super, .PlusPlus, .MinusMinus:
		return true
	}
	return can_be_binding_identifier(kind)
}

@(private="file")
module_lex_expression_continues :: proc(kind: TokenType) -> bool {
	#partial switch kind {
	case .LParen, .LBracket, .Dot, .OptionalChain, .Template, .TemplateHead,
	     .Question, .Colon, .As, .Satisfies, .Not,
	     .Plus, .Minus, .Mul, .Div, .Mod, .Pow, .LShift, .RShift, .URShift,
	     .BitAnd, .BitOr, .BitXor, .LogicalAnd, .LogicalOr, .Nullish,
	     .LAngle, .RAngle, .LEq, .GEq, .Eq, .NotEq, .EqStrict, .NotEqStrict,
	     .In, .Instanceof:
		return true
	}
	return is_assignment_operator(kind)
}

// A string-literal export name is recorded without its quotes, so the quote
// bytes sit directly outside the span. An identifier name can never have a
// quote on both sides: `'a'b'c'` is not a valid specifier.
@(private="file")
module_lex_span_quoted :: proc(source: string, span: Loc) -> bool {
	assert(span.start <= span.end)
	assert(int(span.end) <= len(source))
	if span.start == 0 || int(span.end) == len(source) { return false }
	quote := source[span.start - 1]
	if quote != '\'' && quote != '"' { return false }
	return source[span.end] == quote
}
