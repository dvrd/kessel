package kessel

// ============================================================================
// Control-Flow Graph (Phase 7) — basic-block construction with typed edges.
//
// Builds a CFG from a function body (or program body). Each basic block is a
// sequence of statements with no internal branches. Edges connect blocks with
// typed labels (Normal, Jump, CondTrue, CondFalse, Error, Finalize).
//
// The CFG enables flow-dependent lint rules: no-unreachable (proper),
// no-fallthrough (proper), getter-return, no-unsafe-finally,
// consistent-return, no-useless-return, require-yield, and
// array-callback-return.
//
// Memory: all arrays live in the provided allocator (arena-only, no free).
// ============================================================================

import "core:mem"

// BlockId is a dense index into the blocks array.
BlockId :: distinct u32
BLOCK_ENTRY :: BlockId(0)
BLOCK_EXIT  :: BlockId(1)

// EdgeKind classifies how control transfers between blocks.
EdgeKind :: enum u8 {
	Normal,      // sequential fall-through
	Jump,        // unconditional jump (break, continue, return, throw)
	CondTrue,    // conditional branch — true arm
	CondFalse,   // conditional branch — false arm
	Error,       // exceptional edge (throw, implicit error)
	Finalize,    // finally block entry
	Unreachable, // edge to unreachable code
}

// Edge connects two basic blocks.
Edge :: struct {
	from: BlockId,
	to:   BlockId,
	kind: EdgeKind,
}

// BasicBlock is a sequence of statement indices with no internal branches.
BasicBlock :: struct {
	stmts:     [dynamic]u32,   // indices into the statement list
	reachable: bool,           // set during reachability analysis
}

// CFG is the control-flow graph for one function/program body.
CFG :: struct {
	blocks: [dynamic]BasicBlock,
	edges:  [dynamic]Edge,
	alloc:  mem.Allocator,
}

// cfg_build constructs a CFG from a list of statements (function body or
// program body). Returns a CFG with entry block (0) and exit block (1).
cfg_build :: proc(body: []^Statement, alloc: mem.Allocator) -> CFG {
	g := CFG{
		blocks = make([dynamic]BasicBlock, 2, 16, alloc),
		edges  = make([dynamic]Edge, 0, 16, alloc),
		alloc  = alloc,
	}
	// Block 0 = entry, block 1 = exit. Both start with empty stmt lists.
	g.blocks[0] = BasicBlock{stmts = make([dynamic]u32, 0, 8, alloc), reachable = true}
	g.blocks[1] = BasicBlock{stmts = make([dynamic]u32, 0, 0, alloc), reachable = false}

	cur := BLOCK_ENTRY
	for i in 0..<len(body) {
		s := body[i]
		if s == nil { continue }
		append(&g.blocks[cur].stmts, u32(i))
		if cfg_is_terminator(s, alloc) {
			// This statement terminates the block. Create a new block for
			// any subsequent statements (which are unreachable).
			if i + 1 < len(body) {
				next := cfg_new_block(&g)
				cfg_add_edge(&g, cur, BLOCK_EXIT, .Jump)
				cur = next
				// Mark as unreachable — no edge leads here.
			} else {
				cfg_add_edge(&g, cur, BLOCK_EXIT, .Jump)
			}
			continue
		}
		// If/while/for create branches — for now, just add the stmt to the
		// current block. A full CFG would split here. This basic version is
		// enough for no-unreachable.
	}
	// If the last block didn't terminate, add a normal edge to exit.
	if len(g.blocks[cur].stmts) > 0 || cur == BLOCK_ENTRY {
		last_terminated := false
		if len(g.blocks[cur].stmts) > 0 {
			last_idx := g.blocks[cur].stmts[len(g.blocks[cur].stmts) - 1]
			if int(last_idx) < len(body) && body[last_idx] != nil {
				last_terminated = cfg_is_terminator(body[last_idx], alloc)
			}
		}
		if !last_terminated {
			cfg_add_edge(&g, cur, BLOCK_EXIT, .Normal)
		}
	}
	// Reachability analysis: BFS from entry.
	cfg_compute_reachability(&g)
	return g
}

// cfg_new_block appends a new empty block and returns its id.
cfg_new_block :: proc(g: ^CFG) -> BlockId {
	id := BlockId(len(g.blocks))
	append(&g.blocks, BasicBlock{
		stmts = make([dynamic]u32, 0, 4, g.alloc),
		reachable = false,
	})
	return id
}

// cfg_add_edge adds a directed edge.
cfg_add_edge :: proc(g: ^CFG, from, to: BlockId, kind: EdgeKind) {
	append(&g.edges, Edge{from = from, to = to, kind = kind})
}

// cfg_first_terminator lets statement-list consumers query reachability
// without allocating a graph when they only need its first abrupt exit.
cfg_first_terminator :: proc(body: []^Statement, alloc: mem.Allocator) -> (index: int, found: bool) {
	for statement, statement_index in body {
		if cfg_is_terminator(statement, alloc) { return statement_index, true }
	}
	return 0, false
}

// Ordinary statements keep their fast path. Compound statements need to resolve
// transfers to nested loops, switches, labels and exception handlers.
cfg_is_terminator :: proc(s: ^Statement, alloc: mem.Allocator) -> bool {
	if statement_inner_nil(s) { return false }
	#partial switch node in s^ {
	case ^ReturnStatement, ^ThrowStatement, ^BreakStatement, ^ContinueStatement: return true
	case ^IfStatement: if node.alternate == nil { return false }
	case ^WhileStatement: if cfg_loop_test(node.test) != .Always { return false }
	case ^ForStatement:
		if test, present := node.test.?; present && cfg_loop_test(test) != .Always { return false }
	case ^BlockStatement: if len(node.body) == 0 { return false }
	case ^SwitchStatement:
		has_default := false
		for clause in node.cases { if clause.test == nil { has_default = true; break } }
		if !has_default { return false }
	case ^DoWhileStatement, ^TryStatement, ^LabeledStatement, ^WithStatement:
	case: return false
	}
	return .Next not_in cfg_completion({statement = s}, alloc)
}

// cfg_compute_reachability marks all blocks reachable from BLOCK_ENTRY via BFS.
cfg_compute_reachability :: proc(g: ^CFG) {
	if len(g.blocks) == 0 { return }
	g.blocks[BLOCK_ENTRY].reachable = true
	// Simple BFS using a queue in the temp allocator.
	queue := make([dynamic]BlockId, 0, len(g.blocks), context.temp_allocator)
	append(&queue, BLOCK_ENTRY)
	for len(queue) > 0 {
		cur := queue[0]
		ordered_remove(&queue, 0)
		for e in g.edges {
			if e.from == cur && !g.blocks[e.to].reachable {
				g.blocks[e.to].reachable = true
				append(&queue, e.to)
			}
		}
	}
}

// cfg_has_unreachable_stmts reports whether any block in the CFG is
// unreachable and contains statements (dead code).
cfg_has_unreachable_stmts :: proc(g: ^CFG) -> (unreachable_stmt_idx: u32, found: bool) {
	for i in 2..<len(g.blocks) { // skip entry (0) and exit (1)
		blk := &g.blocks[i]
		if !blk.reachable && len(blk.stmts) > 0 {
			return blk.stmts[0], true
		}
	}
	return 0, false
}
