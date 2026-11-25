package kessel

import "core:slice"
import "core:strings"

// A declaration that can be deleted when nothing live refers to its binding:
// a function declaration, or a plain `var`/`let`/`const` declarator whose
// initializer has no effect when evaluated.
MangleCandidate :: struct {
	scope: ScopeId, // Scope the declaration text is in.
	decl:  u32,     // Offset of the declared identifier.
	span:  Loc,     // The function or the initializer. Empty without an initializer.
}

// Whether evaluating the expression can be observed. Only forms that neither
// read a binding nor call anything count, so the answer needs no scope model.
// Chains (`a.b`, `a()`, `a + b`) are never pure here, which also keeps the
// recursion within the parser's nesting limit.
//
// A call or `new` marked `/* @__PURE__ */` is the exception: its author states
// that nothing observes the call when its result is unused. Its arguments are
// still evaluated, so they have to be pure themselves.
compress_pure :: proc(expr: ^Expression, pure_calls: map[u32]bool) -> bool {
	if expr == nil { return false }
	is_primitive :: proc(expr: ^Expression) -> bool {
		#partial switch _ in expr^ {
		case ^NumericLiteral, ^StringLiteral, ^BooleanLiteral, ^NullLiteral: return true
		}
		return false
	}
	#partial switch v in expr^ {
	case ^NumericLiteral, ^StringLiteral, ^BooleanLiteral, ^NullLiteral, ^RegExpLiteral, ^BigIntLiteral:
		return true
	case ^TemplateLiteral:         return len(v.expressions) == 0
	case ^FunctionExpression:      return true
	case ^ArrowFunctionExpression: return true
	case ^ParenthesizedExpression: return compress_pure(v.expression, pure_calls)
	case ^CallExpression:
		if v.optional || !pure_calls[v.loc.start] || !compress_pure_callee(v.callee) { return false }
		for argument in v.arguments {
			if !compress_pure(argument, pure_calls) { return false }
		}
		return true
	case ^NewExpression:
		if !pure_calls[v.loc.start] || !compress_pure_callee(v.callee) { return false }
		for argument in v.arguments {
			if !compress_pure(argument, pure_calls) { return false }
		}
		return true
	case ^UnaryExpression:
		#partial switch v.operator {
		case .Void, .LogicalNot, .Minus, .Plus, .BitwiseNot, .Typeof: return is_primitive(v.argument)
		}
	case ^ArrayExpression:
		for element in v.elements {
			if inner, ok := element.?; ok && !compress_pure(inner, pure_calls) { return false }
		}
		return true
	case ^ObjectExpression:
		// A shorthand property reads a binding and a spread runs getters.
		for &property in v.properties {
			if property.computed || property.shorthand { return false }
			if !compress_pure(property.value, pure_calls) { return false }
		}
		return true
	}
	return false
}

// The callee of a call marked pure: a name, or plain property accesses on one.
compress_pure_callee :: proc(callee: ^Expression) -> bool {
	current := callee
	// A member chain is as deep as it is long, so it is followed in a loop.
	for current != nil {
		#partial switch v in current^ {
		case ^Identifier: return true
		case ^MemberExpression:
			if v.computed || v.optional { return false }
			current = v.object
		case: return false
		}
	}
	return false
}

// Record where the expression after each `/* @__PURE__ */` comment begins.
mangle_collect_pure_calls :: proc(job: ^ParseJob, uses: ^MangleUses) {
	source := job.source.data
	for comment in job.lexer.comments {
		if comment.type != .Block { continue }
		marked := strings.contains(comment.value, "@__PURE__")
		marked ||= strings.contains(comment.value, "#__PURE__")
		if !marked { continue }
		offset := comment.end
		for offset < u32(len(source)) {
			char := source[offset]
			if char != ' ' && char != '\t' && char != '\n' && char != '\r' { break }
			offset += 1
		}
		uses.pure_calls[offset] = true
	}
}

// Called by the semantic walk for each declarator outside a loop head. A
// `for` head keeps its declaration: `for (var k in o)` assigns the binding.
mangle_note_declarator :: proc(
	uses: ^MangleUses, scope: ScopeId, declaration: ^VariableDeclaration, id: Pattern,
	init: Maybe(^Expression),
) {
	if declaration.declare { return }
	// Disposing a `using` resource is an effect of the declaration itself.
	if declaration.kind != .Var && declaration.kind != .Let && declaration.kind != .Const { return }
	name, plain := id.(^Identifier)
	if !plain || name == nil { return }
	candidate := MangleCandidate{scope = scope, decl = name.loc.start}
	if value, has_init := init.?; has_init {
		if !compress_pure(value, uses.pure_calls) { return }
		candidate.span = get_expression_loc(value)
	}
	append(&uses.candidates, candidate)
}

// Called by the semantic walk for each named function declaration.
mangle_note_function :: proc(uses: ^MangleUses, scope: ScopeId, name: u32, function: Loc) {
	assert(function.start <= name)
	assert(name < function.end)
	append(&uses.candidates, MangleCandidate{scope = scope, decl = name, span = function})
}

MinifyUnused :: struct {
	// Declaration offsets of the bindings to delete.
	dead: map[u32]bool,
	// Indexed by symbol: the symbol's binding is deleted.
	dead_symbols: []bool,
	// Deleted declarations that are not inside another deleted declaration.
	count: int,
}

// Which candidate bindings may be deleted at all, by canonical symbol. Every
// declaration of the binding has to be a candidate, so that deleting them
// deletes the whole binding.
unused_eligible :: proc(
	model: ^SemanticModel, uses: ^MangleUses, module: bool, canon: []SymbolId,
	by_offset: map[u32]SymbolId,
) -> []bool {
	alloc := model.alloc
	declared := make([]u32, len(model.symbols), alloc)
	noted := make([]u32, len(model.symbols), alloc)
	refused := make([]bool, len(model.symbols), alloc)
	for index in 1..<len(model.symbols) { declared[canon[index]] += 1 }
	for candidate in uses.candidates {
		id, found := by_offset[candidate.decl]
		if !found || id == SYMBOL_UNRESOLVED { continue }
		symbol := &model.symbols[id]
		binding := canon[id]
		noted[binding] += 1
		keep := symbol.kind != .Var && symbol.kind != .Let && symbol.kind != .Const &&
			symbol.kind != .Function
		// Other scripts, `eval` and `with` can reach these without a reference.
		keep ||= symbol.scope == SCOPE_ROOT && !module
		keep ||= uses.dynamic_scopes[symbol.scope] || uses.dynamic_scopes[symbol.decl_scope]
		keep ||= .Exported in symbol.flags || .Ambient in symbol.flags
		// A `var` that shares its spelling with a parameter or a catch parameter
		// assigns that other binding, and a JSX factory is used without being named.
		keep ||= uses.keep[symbol.name] || mangle_block_function(model, symbol)
		keep ||= model.symbols[binding].kinds != {symbol.kind}
		if keep { refused[binding] = true }
	}
	eligible := make([]bool, len(model.symbols), alloc)
	for index in 1..<len(model.symbols) {
		eligible[index] = noted[index] != 0 && noted[index] == declared[index] && !refused[index]
	}
	return eligible
}

// The innermost eligible candidate whose function or initializer contains each
// scope. A reference in such a scope disappears together with the candidate.
unused_owners :: proc(
	model: ^SemanticModel, uses: ^MangleUses, canon: []SymbolId, eligible: []bool,
	by_offset: map[u32]SymbolId,
) -> []SymbolId {
	candidates := uses.candidates[:]
	// Candidates of one scope do not overlap, so within a scope they are
	// ordered by where their span begins.
	slice.sort_by(candidates, proc(a, b: MangleCandidate) -> bool {
		return a.scope < b.scope || (a.scope == b.scope && a.span.start < b.span.start)
	})
	owners := make([]SymbolId, len(model.scopes), model.alloc)
	for index in 1..<len(model.scopes) {
		scope := &model.scopes[index]
		assert(int(scope.parent) < index)
		owners[index] = owners[scope.parent]
		// Last candidate of the parent scope that begins at or before this scope.
		low, high := 0, len(candidates)
		for low < high {
			middle := low + (high - low) / 2
			candidate := candidates[middle]
			before := candidate.scope < scope.parent ||
				(candidate.scope == scope.parent && candidate.span.start <= scope.node_start)
			if before { low = middle + 1 } else { high = middle }
		}
		if low == 0 { continue }
		candidate := candidates[low-1]
		if candidate.scope != scope.parent || scope.node_start >= candidate.span.end { continue }
		id, found := by_offset[candidate.decl]
		if found && id != SYMBOL_UNRESOLVED && eligible[canon[id]] { owners[index] = canon[id] }
	}
	return owners
}

// Mark every binding that a surviving reference reaches. References owned by
// a candidate count only once the candidate itself is reached, so a function
// used only by unused functions is unused as well.
unused_mark_live :: proc(
	model: ^SemanticModel, canon: []SymbolId, eligible: []bool, owners: []SymbolId,
) -> []bool {
	alloc := model.alloc
	live := make([]bool, len(model.symbols), alloc)
	// Group the targets of owned references by owner with a counting sort.
	starts := make([]u32, len(model.symbols) + 1, alloc)
	for ref in model.refs { starts[owners[ref.scope] + 1] += 1 }
	for index in 1..<len(starts) { starts[index] += starts[index-1] }
	targets := make([]SymbolId, len(model.refs), alloc)
	cursor := make([]u32, len(model.symbols), alloc)
	for ref in model.refs {
		owner := owners[ref.scope]
		targets[starts[owner] + cursor[owner]] = canon[ref.resolved]
		cursor[owner] += 1
	}
	pending := make([dynamic]SymbolId, 0, 64, alloc)
	// Owner zero holds the references outside every candidate: the roots.
	append(&pending, SYMBOL_UNRESOLVED)
	for index in 1..<len(model.symbols) {
		if !eligible[index] { live[index] = true }
	}
	// Each binding is pushed at most once, which bounds the loop.
	for len(pending) != 0 {
		owner := pop(&pending)
		for target in targets[starts[owner]:starts[owner+1]] {
			if target == SYMBOL_UNRESOLVED || live[target] { continue }
			live[target] = true
			append(&pending, target)
		}
	}
	return live
}

// Find the declarations nothing can reach and drop the references they
// contain from the model, so later passes see the program as it will print.
minify_unused :: proc(model: ^SemanticModel, uses: ^MangleUses, module: bool) -> MinifyUnused {
	alloc := model.alloc
	count := len(model.symbols)
	result := MinifyUnused{dead = make(map[u32]bool, alloc), dead_symbols = make([]bool, count, alloc)}
	if len(uses.candidates) == 0 { return result }
	canon := make([]SymbolId, count, alloc)
	by_offset := make(map[u32]SymbolId, alloc)
	for &symbol, index in model.symbols {
		if index == 0 { continue }
		found, shared := model.binding_index[{symbol.scope, symbol.name}]
		canon[index] = found if shared else SymbolId(index)
		// An Annex B block function has a second symbol at the same offset.
		// Such an offset maps to no symbol, so its bindings are never eligible.
		_, twice := by_offset[symbol.decl_start]
		by_offset[symbol.decl_start] = SYMBOL_UNRESOLVED if twice else SymbolId(index)
	}
	eligible := unused_eligible(model, uses, module, canon, by_offset)
	owners := unused_owners(model, uses, canon, eligible, by_offset)
	live := unused_mark_live(model, canon, eligible, owners)
	for index in 1..<count {
		if live[canon[index]] { continue }
		assert(eligible[canon[index]])
		result.dead[model.symbols[index].decl_start] = true
		result.dead_symbols[index] = true
		// A declaration inside a deleted one goes with it and is not visited.
		owner := owners[model.symbols[index].decl_scope]
		if owner == SYMBOL_UNRESOLVED || live[owner] { result.count += 1 }
	}
	if len(result.dead) == 0 { return result }
	write := 0
	for ref in model.refs {
		owner := owners[ref.scope]
		if owner != SYMBOL_UNRESOLVED && !live[owner] {
			if ref.resolved == SYMBOL_UNRESOLVED { continue }
			symbol := &model.symbols[ref.resolved]
			symbol.ref_count -= 1
			if ref.kind != .Write && !ref.discarded_update { symbol.read_count -= 1 }
			continue
		}
		model.refs[write] = ref
		write += 1
	}
	resize(&model.refs, write)
	return result
}
