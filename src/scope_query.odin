package kessel

// ============================================================================
// scope_query.odin — questions about bindings, asked by source position
// ============================================================================
//
// `semantic_build` (semantic.odin) produces the scope tree, one Symbol per
// declaration and one Ref per identifier use. This module answers the
// questions a compiler asks of that model while it walks the typed AST:
//
//   model := semantic_build(job.program, source, job.lang, allocator)
//   query: ScopeQuery
//   scope_query_init(&query, &model, allocator)
//   defer scope_query_destroy(&query)
//
//   symbol := scope_query_symbol_at(&query, identifier.loc)     // decl or use
//   uses   := scope_query_references(&query, symbol)            // every use
//   scope, inside := scope_query_enclosing_function(&query, node.loc)
//
// Nodes are named by their `Loc`, because that is what the model records:
// a Symbol stores the span of its binding identifier and a Ref the span of
// the identifier that uses it. So "the symbol declared by this node" takes
// the `loc` of the identifier being declared (`function f` -> the `f`), not
// of the whole declaration. The one exception is a TypeScript enum member,
// which the model records under the span of the whole member (`A = 1`).
// A JSX tag name that refers to a binding (`<Foo/>`) is a reference like any
// other, under the span of its JSXIdentifier.
//
// Redeclarations. `var x; var x;` and `function f(){} function f(){}` yield
// one Symbol per declaration, but every use resolves to the first one, which
// is the binding. Queries return that binding, so two declarations of one
// variable give the same SymbolId.
//
// Cost. `init` sorts the declarations and the references by position once,
// O(n log n). A lookup by position is then a binary search; a lookup by name
// or by symbol scans the model once.

import "core:mem"
import "core:slice"

ScopeQuery :: struct {
	model:            ^SemanticModel,
	// Symbol ids ordered by decl_start; index 0 of the model (the
	// "unresolved" sentinel) is left out.
	symbols_by_start: []SymbolId,
	// Indices into `model.refs`, ordered by Ref.start.
	refs_by_start:    []u32,
	allocator:        mem.Allocator,
}

// Build the position index for `model`. The model must outlive the query and
// must not change while the query is in use.
scope_query_init :: proc(query: ^ScopeQuery, model: ^SemanticModel, allocator: mem.Allocator) {
	assert(query != nil)
	assert(model != nil)
	assert(len(model.symbols) >= 1) // the sentinel

	symbols := make([]SymbolId, len(model.symbols) - 1, allocator)
	for &id, index in symbols { id = SymbolId(index + 1) }
	refs := make([]u32, len(model.refs), allocator)
	for &ref_index, index in refs { ref_index = u32(index) }

	query^ = ScopeQuery{
		model            = model,
		symbols_by_start = symbols,
		refs_by_start    = refs,
		allocator        = allocator,
	}
	// The comparison procedures cannot capture `model`, so sort keyed copies.
	scope_query_sort_symbols(query)
	scope_query_sort_refs(query)
}

scope_query_destroy :: proc(query: ^ScopeQuery) {
	assert(query != nil)
	delete(query.symbols_by_start, query.allocator)
	delete(query.refs_by_start, query.allocator)
	query^ = {}
}

// The binding declared by the identifier at `loc`, or SYMBOL_UNRESOLVED when
// no declaration has exactly that span.
scope_query_symbol_declared_at :: proc(query: ^ScopeQuery, loc: Loc) -> SymbolId {
	model := query.model
	low, high := 0, len(query.symbols_by_start)
	for low < high {
		middle := low + (high - low) / 2
		if model.symbols[query.symbols_by_start[middle]].decl_start < loc.start {
			low = middle + 1
		} else {
			high = middle
		}
	}
	// Several symbols can start at one offset (a value and a type declared
	// by the same identifier), so check every candidate at this start.
	for index in low..<len(query.symbols_by_start) {
		id := query.symbols_by_start[index]
		symbol := &model.symbols[id]
		if symbol.decl_start != loc.start { break }
		if symbol.decl_end == loc.end { return scope_query_binding(query, id) }
	}
	return SYMBOL_UNRESOLVED
}

// The reference made by the identifier at `loc`. `found` is false when no
// identifier use has exactly that span. A found reference to a global or an
// undeclared name has `resolved == SYMBOL_UNRESOLVED`.
scope_query_reference_at :: proc(query: ^ScopeQuery, loc: Loc) -> (ref: ^Ref, found: bool) {
	model := query.model
	low, high := 0, len(query.refs_by_start)
	for low < high {
		middle := low + (high - low) / 2
		if model.refs[query.refs_by_start[middle]].start < loc.start {
			low = middle + 1
		} else {
			high = middle
		}
	}
	for index in low..<len(query.refs_by_start) {
		candidate := &model.refs[query.refs_by_start[index]]
		if candidate.start != loc.start { break }
		if candidate.end == loc.end { return candidate, true }
	}
	return nil, false
}

// The binding the identifier at `loc` declares or refers to; a declaration
// wins when the span is both. SYMBOL_UNRESOLVED when the span is neither, or
// is a use of a global.
scope_query_symbol_at :: proc(query: ^ScopeQuery, loc: Loc) -> SymbolId {
	if declared := scope_query_symbol_declared_at(query, loc); declared != SYMBOL_UNRESOLVED {
		return declared
	}
	if ref, found := scope_query_reference_at(query, loc); found { return ref.resolved }
	return SYMBOL_UNRESOLVED
}

// Every binding named `name`, in source order: shadowing declarations in
// different scopes are different bindings; redeclarations of one binding
// are listed once. The caller owns the result.
scope_query_bindings_named :: proc(
	query: ^ScopeQuery,
	name: string,
	allocator: mem.Allocator,
) -> []SymbolId {
	bindings := make([dynamic]SymbolId, allocator)
	for id in query.symbols_by_start {
		if query.model.symbols[id].name != name { continue }
		// A redeclaration maps to an earlier symbol, already listed.
		if scope_query_binding(query, id) == id { append(&bindings, id) }
	}
	return bindings[:]
}

// Every use of the name `name`, in source order, whatever it resolves to;
// uses of an undeclared global are included. The caller owns the result.
scope_query_references_named :: proc(
	query: ^ScopeQuery,
	name: string,
	allocator: mem.Allocator,
) -> []^Ref {
	references := make([dynamic]^Ref, allocator)
	for ref_index in query.refs_by_start {
		ref := &query.model.refs[ref_index]
		if ref.name == name { append(&references, ref) }
	}
	return references[:]
}

// Every use that resolves to `symbol`, in source order. The caller owns the
// result. `symbol` is a binding as returned by the queries above.
scope_query_references :: proc(
	query: ^ScopeQuery,
	symbol: SymbolId,
	allocator: mem.Allocator,
) -> []^Ref {
	assert(int(symbol) < len(query.model.symbols))
	references := make([dynamic]^Ref, allocator)
	if symbol == SYMBOL_UNRESOLVED { return references[:] }
	for ref_index in query.refs_by_start {
		ref := &query.model.refs[ref_index]
		if ref.resolved == symbol { append(&references, ref) }
	}
	return references[:]
}

// The innermost scope whose node contains the byte at `offset`.
scope_query_scope_at :: proc(query: ^ScopeQuery, offset: u32) -> ScopeId {
	model := query.model
	assert(len(model.scopes) >= 1)
	scope := SCOPE_ROOT
	// Each step moves to a child, and children have larger ids than their
	// parent, so the scope count bounds the descent.
	for _ in 0..<len(model.scopes) {
		inner := scope
		inner_size := max(u32)
		for child in model.scopes[scope].children {
			node := &model.scopes[child]
			if offset < node.node_start || node.node_end <= offset { continue }
			// Sibling scopes are normally disjoint. Should two contain the
			// offset, the smaller one is the more specific answer.
			if size := node.node_end - node.node_start; size < inner_size {
				inner, inner_size = child, size
			}
		}
		if inner == scope { break }
		assert(inner > scope)
		scope = inner
	}
	return scope
}

// The scope of the innermost function (or arrow function) that encloses the
// node at `loc`. A function does not enclose itself: for the `loc` of a
// function this is the function around it. `found` is false at the top
// level, outside every function. The returned scope's `node_start` /
// `node_end` are the enclosing function's span. A class static block is not
// a function and is looked through.
scope_query_enclosing_function :: proc(
	query: ^ScopeQuery,
	loc: Loc,
) -> (scope: ScopeId, found: bool) {
	model := query.model
	assert(loc.start <= loc.end)
	current := scope_query_scope_at(query, loc.start)
	for _ in 0..<len(model.scopes) {
		candidate := &model.scopes[current]
		if candidate.kind == .Function {
			contains := candidate.node_start <= loc.start && loc.end <= candidate.node_end
			is_self := candidate.node_start == loc.start && candidate.node_end == loc.end
			if contains && !is_self { return current, true }
		}
		if current == SCOPE_ROOT { break }
		parent := model.scopes[current].parent
		assert(parent < current)
		current = parent
	}
	return SCOPE_ROOT, false
}

// The symbol uses of `id`'s name resolve to in `id`'s scope: `id` itself, or
// the first declaration when `id` is a redeclaration. Type-level symbols are
// not bindings in the model's index and stand for themselves.
@(private = "file")
scope_query_binding :: proc(query: ^ScopeQuery, id: SymbolId) -> SymbolId {
	symbol := &query.model.symbols[id]
	key := SemanticBindingKey{scope = symbol.scope, name = symbol.name}
	if symbol.kind == .TypeAlias || symbol.kind == .Interface { return id }
	if .TypeOnly in symbol.flags { return id }
	if binding, found := query.model.binding_index[key]; found { return binding }
	return id
}

@(private = "file")
ScopeQuerySortKey :: struct {
	start: u32,
	index: u32,
}

@(private = "file")
scope_query_sort_key_before :: proc(a, b: ScopeQuerySortKey) -> bool {
	if a.start != b.start { return a.start < b.start }
	return a.index < b.index
}

@(private = "file")
scope_query_sort_symbols :: proc(query: ^ScopeQuery) {
	keys := make([]ScopeQuerySortKey, len(query.symbols_by_start), query.allocator)
	defer delete(keys, query.allocator)
	for &key, index in keys {
		id := query.symbols_by_start[index]
		key = ScopeQuerySortKey{start = query.model.symbols[id].decl_start, index = u32(id)}
	}
	slice.sort_by(keys, scope_query_sort_key_before)
	for key, index in keys { query.symbols_by_start[index] = SymbolId(key.index) }
}

@(private = "file")
scope_query_sort_refs :: proc(query: ^ScopeQuery) {
	keys := make([]ScopeQuerySortKey, len(query.refs_by_start), query.allocator)
	defer delete(keys, query.allocator)
	for &key, index in keys {
		ref_index := query.refs_by_start[index]
		key = ScopeQuerySortKey{start = query.model.refs[ref_index].start, index = ref_index}
	}
	slice.sort_by(keys, scope_query_sort_key_before)
	for key, index in keys { query.refs_by_start[index] = key.index }
}
