package kessel

import "core:mem"
import "core:slice"
import "core:strings"

// These observations affect whether a shorter local spelling can preserve runtime behavior.
MangleUses :: struct {
	keep: map[string]bool,
	// Offsets of identifiers whose spelling names an anonymous function or class.
	named: map[u32]bool,
	dynamic_scopes: map[ScopeId]bool,
	shorthand: map[u32]bool,
}

mangle_protect_scope :: proc(model: ^SemanticModel, uses: ^MangleUses, scope: ScopeId) {
	current := scope
	for _ in 0..<len(model.scopes) {
		if uses.dynamic_scopes[current] { break }
		uses.dynamic_scopes[current] = true
		if current == SCOPE_ROOT { break }
		current = model.scopes[current].parent
	}
}

mangle_pattern_identifier :: proc(pattern: Pattern) -> ^Identifier {
	value := pattern
	if assignment, ok := value.(^AssignmentPattern); ok { value = assignment.left }
	return value.(^Identifier) or_else nil
}

// JavaScript infers an anonymous function or class name from its assignment target.
mangle_keep_inferred_name :: proc(uses: ^MangleUses, pattern: Pattern, right: ^Expression) {
	id, ok := pattern.(^Identifier)
	if !ok || right == nil { return }
	value := semantic_runtime_expression(right)
	#partial switch node in value^ {
	case ^ArrowFunctionExpression: uses.named[id.loc.start] = true
	case ^FunctionExpression:     if node.id == nil { uses.named[id.loc.start] = true }
	case ^ClassExpression:        if node.id == nil { uses.named[id.loc.start] = true }
	}
}

mangle_keep_assignment_name :: proc(uses: ^MangleUses, assign: ^AssignmentExpression) {
	if assign.left == nil { return }
	if id, ok := semantic_runtime_expression(assign.left)^.(^Identifier); ok {
		mangle_keep_inferred_name(uses, id, assign.right)
	}
}

MangleAlphabet :: struct {
	reserved: map[string]bool,
	first: string,
	next: u32,
}

// Letters in roughly descending frequency in minified JavaScript, so aliases
// reuse the bytes that keywords and property names already make common. This
// changes no lengths; gzip output on the benchmark inputs is 0.2% smaller.
MANGLE_FIRST :: "etnriaoscludfpmhg_vybxSCwTEDOkAjMNPFILRzBVHUWGKqJYXZQ$"
MANGLE_REST  :: "etnriaoscludfpmhg_vybxSCwTEDOkAjMNPFILRzBVHUWGKqJYXZQ$0123456789"
#assert(len(MANGLE_FIRST) == 54)
#assert(len(MANGLE_REST) == 64)

// Words that cannot be a binding in some context. Only spellings that the
// alias sequence can reach within four characters matter in practice.
mangle_word_reserved :: proc(name: string) -> bool {
	switch name {
	case "do", "if", "in", "of", "as", "for", "let", "new", "try", "var", "get", "set",
	     "case", "else", "enum", "eval", "null", "this", "true", "void", "with", "NaN",
	     "await", "break", "catch", "class", "const", "false", "super", "throw", "while",
	     "yield", "async", "delete", "export", "import", "public", "return", "static",
	     "switch", "typeof", "default", "extends", "finally", "package", "private",
	     "continue", "debugger", "function", "arguments", "interface", "protected",
	     "implements", "instanceof", "undefined", "Infinity":
		return true
	}
	return false
}

// Produce the next unreserved alias: all one-character names, then two, and so on.
mangle_next_alias :: proc(alphabet: ^MangleAlphabet, alloc: mem.Allocator) -> string {
	first, rest := alphabet.first, string(MANGLE_REST)
	for _ in 0..=len(alphabet.reserved) + 64 {
		ordinal := alphabet.next
		alphabet.next += 1
		buf: [8]byte
		count := 0
		buf[count] = first[ordinal % u32(len(first))]
		ordinal /= u32(len(first))
		count += 1
		for ordinal > 0 && count < len(buf) {
			ordinal -= 1
			buf[count] = rest[ordinal % u32(len(rest))]
			ordinal /= u32(len(rest))
			count += 1
		}
		assert(ordinal == 0)
		name := string(buf[:count])
		if alphabet.reserved[name] || mangle_word_reserved(name) { continue }
		return strings.clone(name, alloc)
	}
	panic("exhausted short name candidates")
}

mangle_prepare_jsx :: proc(
	job: ^ParseJob, options: PrintOptions, uses: ^MangleUses, alphabet: ^MangleAlphabet,
) {
	// A lowercase JSX tag denotes an intrinsic element. All aliases can be
	// used as either a component tag or an ordinary expression.
	alphabet.first = "ABCDEFGHIJKLMNOPQRSTUVWXYZ$_"
	uses.keep["React"] = true
	for path in ([2]string{options.pragma, options.pragma_frag}) {
		if path != "" { uses.keep[jsx_pragma_root(path)] = true }
	}
	limit := u32(len(job.source.data))
	if len(job.program.body) != 0 { limit = codegen_list_item_loc(job.program.body[0]).start }
	for comment in job.lexer.comments {
		if comment.end > limit { break }
		jsx_comment_has_pragma(comment, &uses.keep)
	}
	// An implicit free factory must also remain free after shortening other names.
	for name in uses.keep { alphabet.reserved[name] = true }
}

MangleState :: struct {
	model: ^SemanticModel,
	uses: ^MangleUses,
	canon: []SymbolId, // First declaration of the runtime binding that a symbol belongs to.
	keep: []bool,      // Indexed by canonical symbol: the original spelling stays.
	slot: []u32,       // Indexed by canonical symbol: one-based name slot, or zero.
	module: bool,      // A module's top-level bindings are private and can be renamed.
	live_scope: [dynamic]ScopeId,  // Pairs: a scope below the declaration that can see
	live_symbol: [dynamic]SymbolId, // or contains a use of the symbol.
}

MANGLE_ELIGIBLE :: bit_set[SymbolKind]{
	.Var, .Let, .Const, .Param, .Using, .CatchParam, .Function, .Class,
}

// A sloppy function declaration in a block also assigns a var in the enclosing
// function (Annex B), so one spelling denotes two bindings.
mangle_block_function :: proc(model: ^SemanticModel, symbol: ^Symbol) -> bool {
	if symbol.kind != .Function { return false }
	scope := &model.scopes[symbol.scope]
	#partial switch scope.kind {
	case .Function, .FunctionBody, .FunctionName, .Module: return false
	}
	return !scope.strict
}

// Names that must stay wherever they occur: a body var initialized from a
// same-named parameter, and a catch parameter that a var declaration may assign.
mangle_keep_shared_names :: proc(state: ^MangleState) {
	model, uses := state.model, state.uses
	vars := make(map[string]bool, model.alloc)
	for &symbol in model.symbols[1:] {
		if symbol.kind == .Var { vars[symbol.name] = true }
		if symbol.kind != .Param && .Param in symbol.kinds { uses.keep[symbol.name] = true }
	}
	for &symbol in model.symbols[1:] {
		if symbol.kind == .CatchParam && vars[symbol.name] { uses.keep[symbol.name] = true }
	}
	uses.keep["arguments"] = true
	uses.keep["eval"] = true
	uses.keep["__proto__"] = true
}

mangle_mark_kept :: proc(state: ^MangleState, keep_names: bool, shorthands: []int) {
	model, uses := state.model, state.uses
	for &symbol, index in model.symbols {
		if index == 0 { continue }
		id := SymbolId(index)
		canon, found := model.binding_index[{symbol.scope, symbol.name}]
		state.canon[index] = canon if found else id
		// Other scripts and the global object see a script's top-level names.
		keep := (symbol.scope == SCOPE_ROOT && !state.module) || uses.dynamic_scopes[symbol.scope]
		keep ||= symbol.kind not_in MANGLE_ELIGIBLE || .Exported in symbol.flags
		keep ||= uses.keep[symbol.name] || mangle_block_function(model, &symbol)
		if keep_names {
			keep ||= symbol.kind == .Function || symbol.kind == .Class
			keep ||= uses.named[symbol.decl_start]
		}
		// `{name}` becomes `{name:a}`. Keep the spelling when that costs more than it saves.
		savings := (1 + int(symbol.ref_count)) * (len(symbol.name) - 1)
		keep ||= shorthands[index] != 0 && savings <= shorthands[index] * (len(symbol.name) + 1)
		if keep { state.keep[state.canon[index]] = true }
	}
	if !keep_names { return }
	for ref in model.refs {
		if ref.resolved != SYMBOL_UNRESOLVED && uses.named[ref.start] {
			state.keep[state.canon[ref.resolved]] = true
		}
	}
}

// Record every scope between a use and the declaring scope. A binding declared
// inside one of those scopes must not take the same alias, or it would capture the use.
mangle_mark_live :: proc(state: ^MangleState, stamps: []SymbolId, symbol: SymbolId, from: ScopeId) {
	model := state.model
	home := model.symbols[symbol].scope
	scope := from
	for _ in 0..<len(model.scopes) {
		if scope == home { return }
		if stamps[scope] == symbol { return }
		if scope == SCOPE_ROOT { break }
		stamps[scope] = symbol
		append(&state.live_scope, scope)
		append(&state.live_symbol, symbol)
		scope = model.scopes[scope].parent
	}
	// The use is not lexically inside the declaring scope: an unusual alias. Leave it alone.
	state.keep[symbol] = true
}

mangle_collect_live :: proc(state: ^MangleState) {
	model := state.model
	alloc := model.alloc
	// Group references by canonical symbol with a counting sort.
	offsets := make([]u32, len(model.symbols) + 1, alloc)
	for ref in model.refs { offsets[state.canon[ref.resolved] + 1] += 1 }
	for index in 1..<len(offsets) { offsets[index] += offsets[index-1] }
	grouped := make([]ScopeId, len(model.refs), alloc)
	cursor := make([]u32, len(model.symbols), alloc)
	for ref in model.refs {
		symbol := state.canon[ref.resolved]
		grouped[offsets[symbol] + cursor[symbol]] = ref.scope
		cursor[symbol] += 1
	}
	// A redeclaration is spelled where it appears, so that scope sees the name too.
	first := make([]u32, len(model.symbols) + 1, alloc)
	for _, index in model.symbols { if index != 0 { first[state.canon[index] + 1] += 1 } }
	for index in 1..<len(first) { first[index] += first[index-1] }
	declared := make([]ScopeId, len(model.symbols), alloc)
	slice.fill(cursor, 0)
	for &symbol, index in model.symbols {
		if index == 0 { continue }
		canon := state.canon[index]
		declared[first[canon] + cursor[canon]] = symbol.decl_scope
		cursor[canon] += 1
	}
	// Walk one symbol at a time so a scope's stamp names the symbol being walked.
	stamps := make([]SymbolId, len(model.scopes), alloc)
	for index in 1..<len(model.symbols) {
		symbol := SymbolId(index)
		if state.canon[index] != symbol || state.keep[index] { continue }
		for scope in declared[first[index]:first[index+1]] {
			mangle_mark_live(state, stamps, symbol, scope)
		}
		for scope in grouped[offsets[index]:offsets[index+1]] {
			mangle_mark_live(state, stamps, symbol, scope)
		}
	}
}

// Scopes are created parent-first. A binding takes the lowest slot that no
// visible outer binding used inside this scope holds, so unrelated scopes share slots.
mangle_assign_slots :: proc(state: ^MangleState) -> u32 {
	model := state.model
	alloc := model.alloc
	starts := make([]u32, len(model.scopes) + 1, alloc)
	for scope in state.live_scope { starts[scope + 1] += 1 }
	for index in 1..<len(starts) { starts[index] += starts[index-1] }
	ordered := make([]SymbolId, len(state.live_symbol), alloc)
	cursor := make([]u32, len(model.scopes), alloc)
	for scope, index in state.live_scope {
		ordered[starts[scope] + cursor[scope]] = state.live_symbol[index]
		cursor[scope] += 1
	}
	taken := make([]u32, len(model.symbols) + 1, alloc)
	slots: u32 = 0
	for &scope, index in model.scopes {
		if (index == int(SCOPE_ROOT) && !state.module) || len(scope.symbols) == 0 { continue }
		// Scope zero must not look like an untouched slot.
		mark := u32(index) + 1
		for symbol in ordered[starts[index]:starts[index+1]] {
			if state.slot[symbol] != 0 && !state.keep[symbol] { taken[state.slot[symbol]-1] = mark }
		}
		// A body var that took a parameter's spelling would start with the parameter's value.
		if index != int(SCOPE_ROOT) && scope.kind == .FunctionBody {
			for symbol in model.scopes[scope.parent].symbols {
				if state.slot[symbol] != 0 { taken[state.slot[symbol]-1] = mark }
			}
		}
		next: u32 = 0
		for id in scope.symbols {
			if state.canon[id] != id || state.keep[id] { continue }
			for taken[next] == mark { next += 1 }
			taken[next] = mark
			state.slot[id] = next + 1
			next += 1
			slots = max(slots, next)
		}
	}
	return slots
}

MangleSlotUse :: struct { count: u32, slot: u32 }

// The most frequently written slots receive the shortest aliases.
mangle_name_slots :: proc(state: ^MangleState, alphabet: ^MangleAlphabet, slots: u32) -> []string {
	model := state.model
	alloc := model.alloc
	uses := make([]MangleSlotUse, slots, alloc)
	for &use, index in uses { use.slot = u32(index) }
	for &symbol, index in model.symbols {
		canon := state.canon[index] if index != 0 else SYMBOL_UNRESOLVED
		if canon == SYMBOL_UNRESOLVED || state.keep[canon] || state.slot[canon] == 0 { continue }
		uses[state.slot[canon]-1].count += 1 + symbol.ref_count
	}
	slice.sort_by(uses, proc(a, b: MangleSlotUse) -> bool {
		return a.count > b.count || (a.count == b.count && a.slot < b.slot)
	})
	names := make([]string, slots, alloc)
	for use in uses { names[use.slot] = mangle_next_alias(alphabet, alloc) }
	return names
}

mangle_reserve_names :: proc(state: ^MangleState, alphabet: ^MangleAlphabet) {
	model := state.model
	for &symbol, index in model.symbols {
		if index != 0 && state.keep[state.canon[index]] { alphabet.reserved[symbol.name] = true }
	}
	for ref in model.refs {
		if ref.resolved == SYMBOL_UNRESOLVED { alphabet.reserved[ref.name] = true }
	}
}

// The alias of the binding that `export { name }` refers to, or "" when it kept its name.
minify_export_alias :: proc(cg: ^Codegen, local: ExportSpecifierName) -> string {
	name, plain := local.(IdentifierName)
	if !plain || len(cg.renamed) == 0 { return "" }
	return cg.renamed[name.loc.start]
}

// A shorter spelling for a function or class name, when the mangler chose one.
minify_binding_name :: proc(cg: ^Codegen, id: BindingIdentifier) -> string {
	if len(cg.renamed) != 0 {
		if name, ok := cg.renamed[id.loc.start]; ok { return name }
	}
	return id.name
}

// Free reads of `undefined`, unless `with` or a direct eval can rebind the name.
minify_undefined_reads :: proc(model: ^SemanticModel, uses: ^MangleUses) -> map[u32]bool {
	if len(uses.dynamic_scopes) != 0 { return nil }
	reads := make(map[u32]bool, model.alloc)
	for ref in model.refs {
		if ref.resolved == SYMBOL_UNRESOLVED && ref.kind == .Read && ref.name == "undefined" {
			reads[ref.start] = true
		}
	}
	return reads
}

// `const` bindings with no assignment anywhere, outside scopes a direct eval can reach.
// Another script can assign a top-level binding of a script, so those stay.
minify_unassigned_constants :: proc(
	model: ^SemanticModel, uses: ^MangleUses, module: bool,
) -> map[u32]bool {
	written := make([]bool, len(model.symbols), model.alloc)
	for ref in model.refs {
		if ref.kind != .Read { written[ref.resolved] = true }
	}
	constants := make(map[u32]bool, model.alloc)
	for &symbol, index in model.symbols {
		if index == 0 || symbol.kind != .Const || written[index] { continue }
		if uses.dynamic_scopes[symbol.scope] || (symbol.scope == SCOPE_ROOT && !module) { continue }
		// A redeclaration is an early error, but stay with the first binding regardless.
		if model.binding_index[{symbol.scope, symbol.name}] != SymbolId(index) { continue }
		constants[symbol.decl_start] = true
	}
	return constants
}

// Analyze the parsed program once, compress it in place, then choose aliases.
// Compression never moves an identifier to another binding's scope, so the
// model of the original tree still describes the compressed one.
minify_prepare :: proc(job: ^ParseJob, options: PrintOptions) -> map[u32]string {
	alloc := job.arena_alloc
	uses := MangleUses{
		keep = make(map[string]bool, alloc), named = make(map[u32]bool, alloc),
		dynamic_scopes = make(map[ScopeId]bool, alloc), shorthand = make(map[u32]bool, alloc),
	}
	alphabet := MangleAlphabet{reserved = make(map[string]bool, alloc), first = MANGLE_FIRST}
	if job.lang == .JSX { mangle_prepare_jsx(job, options, &uses, &alphabet) }
	model := semantic_build(job.program, string(job.source.data), job.lang, alloc, mangle = &uses)
	for ref in model.refs {
		if ref.name == "eval" { mangle_protect_scope(&model, &uses, ref.scope) }
	}
	if options.compress {
		compressor := MinifyCompressor{
			alloc = alloc, undefined_reads = minify_undefined_reads(&model, &uses),
			constants = minify_unassigned_constants(&model, &uses, job.program.type == .Module),
		}
		minify_compress_program(&compressor, job.program)
	}
	if !options.mangle { return nil }
	return minify_local_names(&model, &uses, &alphabet, options, job.program.type == .Module)
}

minify_local_names :: proc(
	model: ^SemanticModel, uses: ^MangleUses, alphabet: ^MangleAlphabet, options: PrintOptions,
	module: bool,
) -> map[u32]string {
	alloc := model.alloc
	count := len(model.symbols)
	state := MangleState{
		model = model, uses = uses, module = module, canon = make([]SymbolId, count, alloc),
		keep = make([]bool, count, alloc), slot = make([]u32, count, alloc),
		live_scope = make([dynamic]ScopeId, alloc), live_symbol = make([dynamic]SymbolId, alloc),
	}
	shorthands := make([]int, count, alloc)
	for symbol, id in model.symbols { if uses.shorthand[symbol.decl_start] { shorthands[id] += 1 } }
	for ref in model.refs {
		if uses.shorthand[ref.start] { shorthands[ref.resolved] += 1 }
	}
	mangle_keep_shared_names(&state)
	mangle_mark_kept(&state, !options.mangle_names, shorthands)
	mangle_collect_live(&state)
	mangle_reserve_names(&state, alphabet)
	names := mangle_name_slots(&state, alphabet, mangle_assign_slots(&state))
	renamed := make(map[u32]string, alloc)
	change := 0
	for &symbol, index in model.symbols {
		canon := state.canon[index] if index != 0 else SYMBOL_UNRESOLVED
		if canon == SYMBOL_UNRESOLVED || state.keep[canon] { continue }
		assert(state.slot[canon] != 0)
		name := names[state.slot[canon]-1]
		renamed[symbol.decl_start] = name
		change += (len(name) - len(symbol.name)) * (1 + int(symbol.ref_count))
		change += shorthands[index] * (len(name) + 1)
	}
	// An input that already uses the shortest names can only get longer.
	if change >= 0 { return nil }
	for ref in model.refs {
		canon := state.canon[ref.resolved]
		if canon == SYMBOL_UNRESOLVED || state.keep[canon] { continue }
		renamed[ref.start] = names[state.slot[canon]-1]
	}
	return renamed
}
