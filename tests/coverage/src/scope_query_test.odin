// Scope queries by source position (src/scope_query.odin), called the way a
// compiler pass calls them: parse, build the semantic model, build the query
// index, then ask about identifiers found in the source.
//
// Method: each test locates identifiers by searching the source text for
// their n-th occurrence, so expectations read as "the 2nd `x`" instead of as
// raw offsets, and asserts which binding each one declares or refers to.
package coverage

import "core:strings"
import "core:testing"

import kessel "../../../src"

@(private = "file")
ScopeFixture :: struct {
	source: string,
	job:    kessel.ParseJob,
	model:  kessel.SemanticModel,
	query:  kessel.ScopeQuery,
}

@(private = "file")
scope_fixture_open :: proc(
	t: ^testing.T,
	fixture: ^ScopeFixture,
	source: string,
	lang := kessel.Lang.JS,
) -> bool {
	fixture.source = source
	config := kessel.ParseConfig{lang_override = lang}
	if !testing.expect(t, kessel.parse_job_open_inline(&fixture.job, source, config, "scope")) {
		return false
	}
	kessel.parse_job_run(&fixture.job)
	if !testing.expect_value(t, len(fixture.job.parser.errors), 0) { return false }
	allocator := fixture.job.arena_alloc
	fixture.model = kessel.semantic_build(fixture.job.program, source, lang, allocator)
	kessel.scope_query_init(&fixture.query, &fixture.model, allocator)
	return true
}

@(private = "file")
scope_fixture_close :: proc(fixture: ^ScopeFixture) {
	kessel.scope_query_destroy(&fixture.query)
	kessel.parse_job_close(&fixture.job)
}

// Span of the `occurrence`-th (1-based) appearance of `text` in the source.
@(private = "file")
scope_loc :: proc(fixture: ^ScopeFixture, text: string, occurrence: int) -> kessel.Loc {
	offset := 0
	for _ in 0..<occurrence {
		found := strings.index(fixture.source[offset:], text)
		assert(found >= 0)
		offset += found + 1
	}
	start := u32(offset - 1)
	return kessel.Loc{start = start, end = start + u32(len(text))}
}

// The binding declared by the n-th `text`.
@(private = "file")
declared :: proc(fixture: ^ScopeFixture, text: string, occurrence: int) -> kessel.SymbolId {
	loc := scope_loc(fixture, text, occurrence)
	return kessel.scope_query_symbol_declared_at(&fixture.query, loc)
}

// The binding the n-th `text` declares or refers to.
@(private = "file")
symbol_at :: proc(fixture: ^ScopeFixture, text: string, occurrence: int) -> kessel.SymbolId {
	return kessel.scope_query_symbol_at(&fixture.query, scope_loc(fixture, text, occurrence))
}

@(private = "file")
kind_of :: proc(fixture: ^ScopeFixture, id: kessel.SymbolId) -> kessel.SymbolKind {
	return kessel.semantic_symbol(&fixture.model, id).kind
}

// Start offset of the function enclosing the n-th `text`; `found` is false
// at the top level.
@(private = "file")
enclosing_start :: proc(
	fixture: ^ScopeFixture,
	text: string,
	occurrence: int,
) -> (start: u32, found: bool) {
	loc := scope_loc(fixture, text, occurrence)
	scope := kessel.scope_query_enclosing_function(&fixture.query, loc) or_return
	return kessel.semantic_scope(&fixture.model, scope).node_start, true
}

@(test)
test_scope_query_symbol_at_declaration_and_use :: proc(t: ^testing.T) {
	fixture: ScopeFixture
	// 1st x: outer declaration. 2nd x: parameter. 3rd x: use of the parameter.
	// 4th x: use of the outer binding. `g` is an undeclared global.
	source := "let x = 1; function f(x) { return x + g; } x;"
	if !scope_fixture_open(t, &fixture, source) { return }
	defer scope_fixture_close(&fixture)
	query := &fixture.query

	outer := declared(&fixture, "x", 1)
	param := declared(&fixture, "x", 2)
	testing.expect(t, outer != kessel.SYMBOL_UNRESOLVED)
	testing.expect(t, param != kessel.SYMBOL_UNRESOLVED)
	testing.expect(t, outer != param, "the parameter shadows the outer binding")
	testing.expect_value(t, kind_of(&fixture, outer), kessel.SymbolKind.Let)
	testing.expect_value(t, kind_of(&fixture, param), kessel.SymbolKind.Param)

	// A use is not a declaration, and the other way round.
	testing.expect_value(t, declared(&fixture, "x", 3), kessel.SYMBOL_UNRESOLVED)
	_, declaration_is_use := kessel.scope_query_reference_at(query, scope_loc(&fixture, "x", 1))
	testing.expect(t, !declaration_is_use)

	inner_ref, inner_found := kessel.scope_query_reference_at(query, scope_loc(&fixture, "x", 3))
	if testing.expect(t, inner_found) {
		testing.expect_value(t, inner_ref.resolved, param)
		testing.expect_value(t, inner_ref.kind, kessel.RefKind.Read)
	}
	// `symbol_at` answers for declarations and uses alike.
	testing.expect_value(t, symbol_at(&fixture, "x", 3), param)
	testing.expect_value(t, symbol_at(&fixture, "x", 4), outer)
	testing.expect_value(t, symbol_at(&fixture, "x", 2), param)
	// The 1st `f` is inside the word `function`; the 2nd is the name.
	function := symbol_at(&fixture, "f", 2)
	testing.expect_value(t, kessel.semantic_symbol(&fixture.model, function).name, "f")

	// A global is a reference that resolves to nothing.
	global, global_found := kessel.scope_query_reference_at(query, scope_loc(&fixture, "g", 1))
	if testing.expect(t, global_found) {
		testing.expect_value(t, global.resolved, kessel.SYMBOL_UNRESOLVED)
	}
	// A span that is not an identifier at all.
	testing.expect_value(t, symbol_at(&fixture, "return", 1), kessel.SYMBOL_UNRESOLVED)
}

@(test)
test_scope_query_bindings_and_references_of_a_name :: proc(t: ^testing.T) {
	fixture: ScopeFixture
	// `q` occurrences: 1-2 var declarations, 3 let, 4 use of the let, 5 write
	// and 6 read of the var.
	source := "var q = 1; var q = 2; { let q = 3; q; } q = q + w; w;"
	if !scope_fixture_open(t, &fixture, source) { return }
	defer scope_fixture_close(&fixture)
	query := &fixture.query

	// Two bindings named `q`: the var (declared twice) and the block's let.
	bindings := kessel.scope_query_bindings_named(query, "q", context.allocator)
	defer delete(bindings)
	if !testing.expect_value(t, len(bindings), 2) { return }
	var_binding, let_binding := bindings[0], bindings[1]
	testing.expect_value(t, kind_of(&fixture, var_binding), kessel.SymbolKind.Var)
	testing.expect_value(t, kind_of(&fixture, let_binding), kessel.SymbolKind.Let)
	// Both `var q` declarations are the same binding.
	testing.expect_value(t, declared(&fixture, "q", 1), var_binding)
	testing.expect_value(t, declared(&fixture, "q", 2), var_binding)
	testing.expect_value(t, declared(&fixture, "q", 3), let_binding)

	// Uses of the name, whatever they resolve to, in source order.
	named := kessel.scope_query_references_named(query, "q", context.allocator)
	defer delete(named)
	if testing.expect_value(t, len(named), 3) {
		testing.expect_value(t, named[0].resolved, let_binding)
		testing.expect_value(t, named[1].resolved, var_binding)
		testing.expect_value(t, named[1].kind, kessel.RefKind.Write)
		testing.expect_value(t, named[2].resolved, var_binding)
		testing.expect(t, named[0].start < named[1].start && named[1].start < named[2].start)
	}

	// Uses of one binding.
	var_uses := kessel.scope_query_references(query, var_binding, context.allocator)
	defer delete(var_uses)
	testing.expect_value(t, len(var_uses), 2)
	let_uses := kessel.scope_query_references(query, let_binding, context.allocator)
	defer delete(let_uses)
	testing.expect_value(t, len(let_uses), 1)

	// An undeclared name has uses and no binding.
	no_bindings := kessel.scope_query_bindings_named(query, "w", context.allocator)
	defer delete(no_bindings)
	testing.expect_value(t, len(no_bindings), 0)
	global_uses := kessel.scope_query_references_named(query, "w", context.allocator)
	defer delete(global_uses)
	testing.expect_value(t, len(global_uses), 2)
	unresolved := kessel.scope_query_references(query, kessel.SYMBOL_UNRESOLVED, context.allocator)
	defer delete(unresolved)
	testing.expect_value(t, len(unresolved), 0)
}

@(test)
test_scope_query_enclosing_function :: proc(t: ^testing.T) {
	fixture: ScopeFixture
	source := "top; function outer(a) { const inner = (b) => { deep; };" +
	          " class C { m() { method; } } }"
	if !scope_fixture_open(t, &fixture, source) { return }
	defer scope_fixture_close(&fixture)
	query := &fixture.query

	_, at_top := enclosing_start(&fixture, "top", 1)
	testing.expect(t, !at_top, "the top level is outside every function")

	outer_start := scope_loc(&fixture, "function outer", 1).start
	arrow_start := scope_loc(&fixture, "(b) =>", 1).start

	// A node in a function body, and a parameter, are enclosed by it.
	of_inner, inner_found := enclosing_start(&fixture, "inner", 1)
	testing.expect(t, inner_found)
	testing.expect_value(t, of_inner, outer_start)
	of_param, param_found := enclosing_start(&fixture, "a", 1)
	testing.expect(t, param_found)
	testing.expect_value(t, of_param, outer_start)

	// The innermost function wins, arrows included.
	of_deep, deep_found := enclosing_start(&fixture, "deep", 1)
	testing.expect(t, deep_found)
	testing.expect_value(t, of_deep, arrow_start)

	// A function does not enclose itself: the arrow's own span maps to
	// `outer`, and `outer`'s own span to nothing.
	arrow_scope, _ := kessel.scope_query_enclosing_function(query, scope_loc(&fixture, "deep", 1))
	arrow := kessel.semantic_scope(&fixture.model, arrow_scope)
	testing.expect_value(t, arrow.kind, kessel.ScopeKind.Function)
	arrow_loc := kessel.Loc{start = arrow.node_start, end = arrow.node_end}
	around_arrow, arrow_found := kessel.scope_query_enclosing_function(query, arrow_loc)
	if testing.expect(t, arrow_found) {
		outer := kessel.semantic_scope(&fixture.model, around_arrow)
		testing.expect_value(t, outer.node_start, outer_start)
		outer_loc := kessel.Loc{start = outer.node_start, end = outer.node_end}
		_, outer_has_parent := kessel.scope_query_enclosing_function(query, outer_loc)
		testing.expect(t, !outer_has_parent)
	}

	// A method is a function; the class around it is not.
	of_method, method_found := enclosing_start(&fixture, "method", 1)
	testing.expect(t, method_found)
	testing.expect(t, of_method > arrow.node_end, "the method, not the arrow or `outer`")
}

// What a JSX compiler asks: which binding does this tag or attribute
// expression refer to, and is it a component in scope or a global?
@(test)
test_scope_query_jsx_references :: proc(t: ^testing.T) {
	fixture: ScopeFixture
	source := "import { Card } from \"ui\"; const title = 1;" +
	          " const view = <Card title={title}><Missing/></Card>;"
	if !scope_fixture_open(t, &fixture, source, .JSX) { return }
	defer scope_fixture_close(&fixture)
	query := &fixture.query

	// 1st `Card`: the import. 2nd: the opening tag. 3rd: the closing tag.
	card := declared(&fixture, "Card", 1)
	testing.expect_value(t, kind_of(&fixture, card), kessel.SymbolKind.Import)
	testing.expect_value(t, symbol_at(&fixture, "Card", 2), card)

	// 1st `title`: the const. 2nd: the attribute name, which is not a
	// reference. 3rd: the expression inside the attribute.
	title := declared(&fixture, "title", 1)
	testing.expect(t, title != kessel.SYMBOL_UNRESOLVED)
	testing.expect_value(t, symbol_at(&fixture, "title", 2), kessel.SYMBOL_UNRESOLVED)
	testing.expect_value(t, symbol_at(&fixture, "title", 3), title)

	// A tag with no binding in scope is a reference that resolves to nothing.
	missing, found := kessel.scope_query_reference_at(query, scope_loc(&fixture, "Missing", 1))
	if testing.expect(t, found) {
		testing.expect_value(t, missing.resolved, kessel.SYMBOL_UNRESOLVED)
	}

	uses := kessel.scope_query_references(query, card, context.allocator)
	defer delete(uses)
	testing.expect(t, len(uses) >= 1, "the tag is a use of the import")
}
