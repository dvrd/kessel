package kessel

import "core:mem"
import "core:strings"

// These observations affect whether a shorter local spelling can preserve runtime behavior.
MangleUses :: struct {
	keep: map[string]bool,
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
	case ^ArrowFunctionExpression: uses.keep[id.name] = true
	case ^FunctionExpression:     if node.id == nil { uses.keep[id.name] = true }
	case ^ClassExpression:        if node.id == nil { uses.keep[id.name] = true }
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
	available: [dynamic]string,
	next: u32,
}

// A leading underscore in multi-character names avoids all reserved keywords.
mangle_alias :: proc(alphabet: ^MangleAlphabet, index: int, alloc: mem.Allocator) -> string {
	if index < len(alphabet.available) { return alphabet.available[index] }
	assert(index == len(alphabet.available))
	letters := alphabet.first
	digits := string("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ$_0123456789")
	for _ in 0..=len(alphabet.reserved) {
		ordinal := alphabet.next
		alphabet.next += 1
		buf: [9]byte
		start := len(buf) - 1
		if ordinal < u32(len(letters)) {
			buf[start] = letters[ordinal]
		} else {
			ordinal -= u32(len(letters))
			for _ in 0..<6 {
				buf[start] = digits[ordinal % u32(len(digits))]
				ordinal /= u32(len(digits))
				start -= 1
				if ordinal == 0 { break }
				ordinal -= 1
			}
			buf[start] = '_'
		}
		name := string(buf[start:])
		if alphabet.reserved[name] { continue }
		owned := strings.clone(name, alloc)
		append(&alphabet.available, owned)
		return owned
	}
	panic("exhausted short name candidates")
}

mangle_prepare_jsx :: proc(job: ^ParseJob, options: PrintOptions, uses: ^MangleUses, alphabet: ^MangleAlphabet) {
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

minify_local_names :: proc(job: ^ParseJob, options: PrintOptions) -> map[u32]string {
	alloc := job.arena_alloc
	uses := MangleUses{make(map[string]bool, alloc), make(map[ScopeId]bool, alloc), make(map[u32]bool, alloc)}
	alphabet := MangleAlphabet{
		reserved = make(map[string]bool, alloc), available = make([dynamic]string, alloc),
		first = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ$_",
	}
	if job.lang == .JSX { mangle_prepare_jsx(job, options, &uses, &alphabet) }
	model := semantic_build(job.program, string(job.source.data), job.lang, alloc, mangle = &uses)
	shorthands := make([]int, len(model.symbols), alloc)
	for symbol, id in model.symbols {
		alphabet.reserved[symbol.name] = true
		// Separate parameter/body environments, repeated declarations, catch-var
		// initializers and Annex B function aliases can share a runtime binding.
		if model.binding_index[{symbol.scope, symbol.name}] != SymbolId(id) ||
		   symbol.kind == .CatchParam || symbol.kind == .Function || symbol.kind == .Class ||
		   (symbol.kind != .Param && .Param in symbol.kinds) { uses.keep[symbol.name] = true }
		if uses.shorthand[symbol.decl_start] { shorthands[id] += 1 }
	}
	for ref in model.refs {
		alphabet.reserved[ref.name] = true
		if ref.name == "eval" { mangle_protect_scope(&model, &uses, ref.scope) }
		if uses.shorthand[ref.start] { shorthands[ref.resolved] += 1 }
	}
	uses.keep["arguments"] = true
	uses.keep["eval"] = true
	uses.keep["__proto__"] = true
	names := make([]string, len(model.symbols), alloc)
	next := make([]int, len(model.scopes), alloc)
	renamed := make(map[u32]string, alloc)
	// Scopes are created parent-first. Siblings may reuse every alias that their
	// parent did not allocate. An original binding or free reference always reserves its name.
	for scope, index in model.scopes {
		if index == int(SCOPE_ROOT) { continue }
		next[index] = next[scope.parent]
		if uses.dynamic_scopes[ScopeId(index)] { continue }
		for id in scope.symbols {
			symbol := &model.symbols[id]
			if uses.keep[symbol.name] || len(symbol.name) < 2 || .Exported in symbol.flags { continue }
			eligible :: bit_set[SymbolKind]{.Var, .Let, .Const, .Param, .Using}
			if symbol.kind not_in eligible { continue }
			name := mangle_alias(&alphabet, next[index], alloc)
			savings := (1 + int(symbol.ref_count)) * (len(symbol.name) - len(name))
			if savings <= shorthands[id] * (len(symbol.name) + 1) { continue }
			names[id] = name
			renamed[symbol.decl_start] = name
			next[index] += 1
		}
	}
	for ref in model.refs {
		if name := names[ref.resolved]; name != "" { renamed[ref.start] = name }
	}
	return renamed
}
