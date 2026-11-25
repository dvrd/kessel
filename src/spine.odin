// ============================================================================
// spine.odin — iterative traversal of left-associative expression chains
// ============================================================================
//
// The parser builds four kinds of expression in a loop rather than by
// recursion, so their length is not limited by ParseConfig.max_depth:
//
//   BinaryExpression.left     a + b + c + ...
//   LogicalExpression.left    a && b && c && ...
//   MemberExpression.object   a.b.c. ...   a[0][1] ...
//   CallExpression.callee     a()()() ...
//
// A million-term concatenation is valid code (generated tables, bundled
// string builders), and its tree is a million nodes deep along exactly
// these four edges. A walker that recursed along them would need one
// stack frame per term. Every other edge of the tree is covered by the
// parser's nesting limit, so these four are the only ones a walker has
// to handle without recursion.
//
// ExprSpine flattens such a chain: `nodes` holds the chain from the
// outermost node inward and `leaf` is the first operand that is not
// itself a chain node. A recursive visit
//
//   visit(n):  enter(n); visit(child(n)); leave(n)
//
// becomes, with identical ordering of side effects,
//
//   for n in nodes { enter(n) }
//   visit(leaf)
//   #reverse for n in nodes { leave(n) }
//
// where `leave` still recurses into the node's other operands (right
// operand, computed property, call arguments); those are bounded by the
// parser's nesting limit.

package kessel

import "base:runtime"

// Chains up to this length are flattened into storage inside the
// ExprSpine itself. Real code rarely chains deeper (the 467-file
// real-world corpus peaks in the low hundreds on a handful of files),
// and 32 pointers keep the struct at a few hundred bytes of stack.
EXPR_SPINE_INLINE_COUNT :: 32

// Upper bound on a chain. Every chain node occupies at least 16 bytes of
// arena, so 2^30 links would need 16 GiB of AST: a longer chain cannot
// come from the parser, and hitting the bound means the tree is cyclic
// or corrupt. The bound is 2^30 rather than 2^31 so that it fits in `int`
// on 32-bit targets (the wasm playground).
EXPR_SPINE_COUNT_MAX :: 1 << 30

#assert(EXPR_SPINE_COUNT_MAX <= max(i32))

#assert(EXPR_SPINE_INLINE_COUNT > 0)
#assert(EXPR_SPINE_INLINE_COUNT < EXPR_SPINE_COUNT_MAX)

ExprSpine :: struct {
	// Chain nodes, outermost first. Points into `inline_nodes` or into a
	// heap block; never copy an opened ExprSpine.
	nodes: []^Expression,
	// First operand below the chain that is not a chain node. May be nil
	// on a tree truncated by error recovery.
	leaf:  ^Expression,

	inline_nodes: [EXPR_SPINE_INLINE_COUNT]^Expression,
	heap_backed:  bool,
	allocator:    runtime.Allocator,
}

// expr_spine_child returns the operand a chain continues through, and
// whether `expr` is a chain node at all. `child` may be nil for a chain
// node whose operand was lost to error recovery.
expr_spine_child :: #force_inline proc(expr: ^Expression) -> (child: ^Expression, is_chain: bool) {
	if expr == nil { return nil, false }
	#partial switch e in expr^ {
	case ^BinaryExpression:
		if e == nil { return nil, false }
		return e.left, true
	case ^LogicalExpression:
		if e == nil { return nil, false }
		return e.left, true
	case ^MemberExpression:
		if e == nil { return nil, false }
		return e.object, true
	case ^CallExpression:
		if e == nil { return nil, false }
		return e.callee, true
	}
	return nil, false
}

// expr_is_spine_node reports whether a walker must hand `expr` to an
// ExprSpine loop instead of recursing into its chain operand.
expr_is_spine_node :: #force_inline proc(expr: ^Expression) -> bool {
	_, is_chain := expr_spine_child(expr)
	return is_chain
}

// expr_spine_leaf walks to the bottom of the chain without recording it.
// For walkers that only need the innermost operand.
expr_spine_leaf :: proc(top: ^Expression) -> ^Expression {
	current := top
	for _ in 0 ..< EXPR_SPINE_COUNT_MAX {
		child, is_chain := expr_spine_child(current)
		if !is_chain { return current }
		current = child
	}
	panic("expression chain exceeds EXPR_SPINE_COUNT_MAX: cyclic tree")
}

// expr_spine_open flattens the chain starting at `top` into `spine`.
// `top` need not be a chain node: the result is then zero nodes and
// leaf == top. Chains longer than EXPR_SPINE_INLINE_COUNT take one heap
// block of `count` pointers from `allocator`; this is the only
// allocation, it is sized exactly, and expr_spine_close releases it.
//
// Returns false only when that allocation fails. `spine` is then empty
// (no nodes, nil leaf) and the caller must skip the chain; it must not
// fall back to recursion.
expr_spine_open :: proc(
	spine: ^ExprSpine,
	top: ^Expression,
	allocator := context.allocator,
) -> bool {
	assert(spine != nil)
	spine.nodes       = nil
	spine.leaf        = nil
	spine.heap_backed = false
	spine.allocator   = allocator

	// Pass 1: fill the inline storage and keep counting past it.
	count := 0
	current := top
	for count < EXPR_SPINE_COUNT_MAX {
		child, is_chain := expr_spine_child(current)
		if !is_chain { break }
		if count < EXPR_SPINE_INLINE_COUNT { spine.inline_nodes[count] = current }
		count += 1
		current = child
	}
	assert(count < EXPR_SPINE_COUNT_MAX, "expression chain is cyclic")
	spine.leaf = current

	if count <= EXPR_SPINE_INLINE_COUNT {
		spine.nodes = spine.inline_nodes[:count]
		return true
	}

	// Pass 2: the chain is long; copy it into one exactly-sized block.
	nodes, alloc_error := make([]^Expression, count, allocator)
	if alloc_error != nil {
		spine.leaf = nil
		return false
	}
	current = top
	for index in 0 ..< count {
		nodes[index] = current
		child, is_chain := expr_spine_child(current)
		assert(is_chain)
		current = child
	}
	assert(current == spine.leaf)
	spine.nodes       = nodes
	spine.heap_backed = true
	return true
}

// expr_spine_close releases the heap block of a long chain. Safe to call
// after a failed open and safe to call twice.
expr_spine_close :: proc(spine: ^ExprSpine) {
	assert(spine != nil)
	if spine.heap_backed {
		delete(spine.nodes, spine.allocator)
		spine.heap_backed = false
	}
	spine.nodes = nil
	spine.leaf  = nil
}
