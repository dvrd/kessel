package kessel

import "core:strings"

// Additive module-lexer records: everything es-module-lexer reports that the
// original scan did not (import type, clause end, call start, attribute pairs,
// facade detection) plus the CommonJS-versus-ESM format hint. The scan loop
// in module_lexer.odin records raw facts; module_lex_finish derives the rest
// once, after the token walk, so the hot loop stays branch-light.

// Ordinals equal es-module-lexer's `t` values. None marks TypeScript
// `import x = require()` records, which es-module-lexer cannot represent.
ModuleImportType :: enum u8 {
	None,
	Static,
	Dynamic,
	Import_Meta,
	Static_Source_Phase,
	Dynamic_Source_Phase,
	Static_Defer_Phase,
	Dynamic_Defer_Phase,
}

#assert(u8(ModuleImportType.Static) == 1)
#assert(u8(ModuleImportType.Import_Meta) == 3)
#assert(u8(ModuleImportType.Dynamic_Defer_Phase) == 7)

// One `key: 'value'` pair of an import attributes clause. Spans exclude the
// quotes of string keys and values, like ModuleDependency.request does.
ModuleImportAttribute :: struct {
	key: string,
	value: string,
	key_span: Loc,
	value_span: Loc,
}

// A hint, not a verdict: ESM when the source has static module syntax or
// import.meta (the same signal Node's syntax detection uses, minus top-level
// await), CJS when it has none of that but uses require(), module.exports or
// exports.x, Unknown otherwise.
ModuleFormat :: enum u8 { Unknown, ESM, CJS }

// Tracks `require (`, `module . exports` and `exports .` / `exports [` across
// consecutive tokens without lookahead.
ModuleLexCommonJSState :: enum u8 { Idle, Require, Module, Module_Dot, Exports }

@(private)
module_lex_import_type :: proc(
	kind: ModuleDependencyKind,
	phase: ModuleImportPhase,
) -> ModuleImportType {
	switch kind {
	case .Static, .Reexport:
		switch phase {
		case .Evaluation: return .Static
		case .Source: return .Static_Source_Phase
		case .Defer: return .Static_Defer_Phase
		}
	case .Dynamic:
		switch phase {
		case .Evaluation: return .Dynamic
		case .Source: return .Dynamic_Source_Phase
		case .Defer: return .Dynamic_Defer_Phase
		}
	case .Import_Meta:
		assert(phase == .Evaluation)
		return .Import_Meta
	case .Import_Equals:
		return .None
	}
	unreachable()
}

// Derive the per-record and module-level fields that need the whole scan.
@(private)
module_lex_finish :: proc(scan: ^ModuleLexScanner) -> ModuleLexError {
	result := &scan.result
	for &entry in result.dependencies {
		entry.import_type = module_lex_import_type(entry.kind, entry.phase)
		if entry.kind == .Dynamic || entry.kind == .Import_Meta {
			// Expressions have no optional semicolon to exclude.
			entry.clause_end = entry.statement.end
		}
		assert(entry.statement.start < entry.clause_end)
		assert(entry.clause_end <= entry.statement.end)
		if entry.kind == .Dynamic { assert(entry.arguments_start != nil) }
		if entry.kind != .Dynamic { assert(entry.arguments_start == nil) }
		if span, ok := entry.attributes.?; ok {
			if err := module_lex_attribute_entries(scan, &entry, span); err != .None { return err }
		}
	}
	result.facade = !scan.facade_broken
	result.has_commonjs_syntax = scan.commonjs_found
	if result.has_module_syntax {
		result.format = .ESM
	} else {
		result.format = .CJS if scan.commonjs_found else .Unknown
	}
	return .None
}

// Advance the CommonJS marker automaton by one token. Members (`a.require(`)
// and declarations (`function require(`) are not markers.
@(private)
module_lex_commonjs_step :: proc(scan: ^ModuleLexScanner, previous: TokenType) {
	if scan.commonjs_found { return }
	token := scan.lexer.cur
	state := scan.commonjs_state
	scan.commonjs_state = .Idle
	switch state {
	case .Idle:
	case .Require:
		if token.kind == .LParen { scan.commonjs_found = true }
		return
	case .Module:
		if token.kind == .Dot { scan.commonjs_state = .Module_Dot }
		return
	case .Module_Dot:
		if token_source(&scan.lexer, token) == "exports" { scan.commonjs_found = true }
		return
	case .Exports:
		if token.kind == .Dot || token.kind == .LBracket { scan.commonjs_found = true }
		return
	}
	length := token.end - token.start
	if length != 6 && length != 7 { return }
	if previous == .Dot || previous == .OptionalChain || previous == .Function { return }
	switch token_source(&scan.lexer, token) {
	case "require": scan.commonjs_state = .Require
	case "module": scan.commonjs_state = .Module
	case "exports": scan.commonjs_state = .Exports
	}
}

@(private)
module_lex_attributes_destroy :: proc(entry: ^ModuleDependency) {
	allocator := entry.attribute_entries.allocator
	for item in entry.attribute_entries {
		delete(item.key, allocator)
		delete(item.value, allocator)
	}
	delete(entry.attribute_entries)
	entry.attribute_entries = {}
}

// Decode the literal `key: 'value'` pairs of an attributes clause by lexing
// its span again. Static clauses are `{...}`; dynamic import options are
// `{ with: {...} }`. Anything else (a computed options object, a spread) is
// not statically known and yields no entries rather than an error.
@(private="file")
module_lex_attribute_entries :: proc(
	scan: ^ModuleLexScanner,
	entry: ^ModuleDependency,
	span: Loc,
) -> ModuleLexError {
	source := scan.lexer.source
	assert(span.start < span.end)
	assert(int(span.end) <= len(source))
	assert(len(entry.attribute_entries) == 0)
	sub: Lexer
	init_lexer(&sub, source[span.start:span.end], scan.lexer.allocator, .Module)
	sub.skip_regex_validation = true
	if entry.kind == .Dynamic {
		if sub.cur.kind != .LBrace { return .None }
		module_lex_advance(&sub)
		// The options key may be written `with`, `assert` or as a string.
		keyword := sub.cur.kind == .With || sub.cur.kind == .Assert
		quoted := sub.cur.kind == .String && module_lex_string(&sub) == "with"
		if !keyword && !quoted { return .None }
		module_lex_advance(&sub)
		if sub.cur.kind != .Colon { return .None }
		module_lex_advance(&sub)
	}
	if sub.cur.kind != .LBrace { return .None }
	module_lex_advance(&sub)
	entry.attribute_entries.allocator = scan.allocator
	complete, err := module_lex_attribute_list(&sub, entry, span.start)
	if err != .None || !complete { module_lex_attributes_destroy(entry) }
	return err
}

// Returns false when the list is not a plain sequence of literal pairs.
@(private="file")
module_lex_attribute_list :: proc(
	sub: ^Lexer,
	entry: ^ModuleDependency,
	base: u32,
) -> (complete: bool, err: ModuleLexError) {
	// Every pair consumes at least four bytes (`a:''`), which bounds the loop.
	pairs_max := len(sub.source) / 4 + 1
	for _ in 0..<pairs_max {
		if sub.cur.kind == .RBrace { return true, .None }
		if !module_lex_is_name(sub.cur.kind) { return false, .None }
		paired := module_lex_attribute_pair(sub, entry, base) or_return
		if !paired { return false, .None }
		if sub.cur.kind == .Comma {
			module_lex_advance(sub)
		} else {
			if sub.cur.kind != .RBrace { return false, .None }
		}
	}
	return false, .None
}

// Consume `key: 'value'` and append it. Returns false, leaving nothing
// allocated, when the tokens are not that shape.
@(private="file")
module_lex_attribute_pair :: proc(
	sub: ^Lexer,
	entry: ^ModuleDependency,
	base: u32,
) -> (paired: bool, err: ModuleLexError) {
	allocator := entry.attribute_entries.allocator
	assert(allocator.procedure != nil)
	assert(module_lex_is_name(sub.cur.kind))
	key_text, key_span := module_lex_export_name(sub)
	// The lexer recycles its literal slots, so own the key before advancing.
	key, key_err := strings.clone(key_text, allocator)
	if key_err != nil { return false, .Allocation_Error }
	module_lex_advance(sub)
	colon := sub.cur.kind == .Colon
	if colon { module_lex_advance(sub) }
	token := sub.cur
	if !colon || token.kind != .String || token.end - token.start < 2 {
		delete(key, allocator)
		return false, .None
	}
	value, value_err := strings.clone(module_lex_string(sub), allocator)
	if value_err != nil {
		delete(key, allocator)
		return false, .Allocation_Error
	}
	item := ModuleImportAttribute{
		key = key,
		value = value,
		key_span = {start = base + key_span.start, end = base + key_span.end},
		value_span = {start = base + token.start + 1, end = base + token.end - 1},
	}
	if _, append_err := append(&entry.attribute_entries, item); append_err != nil {
		delete(key, allocator)
		delete(value, allocator)
		return false, .Allocation_Error
	}
	module_lex_advance(sub)
	return true, .None
}
