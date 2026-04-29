package main

// DoD prototype: validate whether SoA AST representation actually
// delivers the predicted ~12 % wall-time savings on this codebase.
//
// Methodology: build the same logical AST in two representations,
// measuring the time to ALLOCATE + INITIALIZE the nodes. No lex, no
// parse logic — just AST construction. This isolates the cost SoA
// targets from everything else in the pipeline.
//
// Each test run constructs a synthetic AST with N expression nodes:
//
//                     Binary(+)
//                    /         \
//                   *           Call
//                  / \         /    \
//                Id   Id     Id    [Id, Member]
//                            ^^    ^^^
//                            callee args
//                                      \
//                                    Member.x
//
// Repeat M times to total ~500K nodes (matches typescript.js parse load).
//
// Compare:
//   * AoS (Odin union of pointers, arena-allocated, kessel-style)
//   * SoA (tags[]u8, data[]Data16, names[]u32, extra[]u32, Zig-style)
//
// Build:
//   odin build bench/dod_proto/proto.odin -file -o:speed -no-bounds-check -out:bench/dod_proto/proto
//
// Run:
//   ./bench/dod_proto/proto <iterations>

import "core:fmt"
import "core:mem"
import mvirtual "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:time"

// ============================================================================
// Implementation A: AoS (pointer + arena), kessel-style
// ============================================================================

ExprAOS :: union {
	^IdentifierAOS,
	^BinaryAOS,
	^MemberAOS,
	^CallAOS,
}

IdentifierAOS :: struct {
	name:  string,
	start: u32,
	end:   u32,
}                          // 16+8 = 24 B + 8 B union ptr/tag = 32 B effective

BinaryAOS :: struct {
	op:    u8,
	_pad:  [3]u8,
	left:  ExprAOS,
	right: ExprAOS,
	start: u32,
	end:   u32,
}                          // 4+16+16+8 = 44 B (align padded to 48)

MemberAOS :: struct {
	object: ExprAOS,
	prop:   string,
	start:  u32,
	end:    u32,
}                          // 16+16+8 = 40 B

CallAOS :: struct {
	callee: ExprAOS,
	args:   []ExprAOS,        // raw slice (we manage lifetime in arena)
	start:  u32,
	end:    u32,
}                          // 16+16+8 = 40 B

// AoS builder: allocate nodes in an arena.
//
// At each non-leaf depth picks a shape from {Binary, Member, Call} so
// every recursive level produces an interior node. Leaves are
// Identifiers. Tree size grows as ~3^depth (Call has 3 children:
// callee + 2 args; Binary has 2; Member has 1).
build_aos :: proc(allocator: mem.Allocator, depth, branch: int) -> ExprAOS {
	if depth <= 0 {
		id := new(IdentifierAOS, allocator)
		id.name = "x"
		id.start = u32(depth)
		id.end = u32(depth) + 1
		return id
	}
	switch branch % 3 {
	case 0:
		// Binary
		b := new(BinaryAOS, allocator)
		b.op = '+'
		b.left = build_aos(allocator, depth - 1, branch + 1)
		b.right = build_aos(allocator, depth - 1, branch + 2)
		b.start = 0
		b.end = u32(depth)
		return b
	case 1:
		// Member chain
		m := new(MemberAOS, allocator)
		m.object = build_aos(allocator, depth - 1, branch + 1)
		m.prop = "field"
		m.start = 0
		m.end = u32(depth)
		return m
	case:
		// Call with 2 args
		c := new(CallAOS, allocator)
		c.callee = build_aos(allocator, depth - 1, branch + 1)
		args := make([]ExprAOS, 2, allocator)
		args[0] = build_aos(allocator, depth - 1, branch + 2)
		args[1] = build_aos(allocator, depth - 1, branch + 3)
		c.args = args
		c.start = 0
		c.end = u32(depth)
		return c
	}
}

// AoS traversal: walk the tree and accumulate a checksum (so the
// compiler can't optimize the build away).
walk_aos :: proc(node: ExprAOS) -> u64 {
	#partial switch v in node {
	case ^IdentifierAOS:
		return u64(v.start) + u64(v.end)
	case ^BinaryAOS:
		return u64(v.start) + walk_aos(v.left) + walk_aos(v.right)
	case ^MemberAOS:
		return u64(v.start) + walk_aos(v.object)
	case ^CallAOS:
		acc := u64(v.start) + walk_aos(v.callee)
		for a in v.args { acc += walk_aos(a) }
		return acc
	}
	return 0
}

// ============================================================================
// Implementation B: SoA (Zig-style tags/data/extra), step #5 design
// ============================================================================

NodeTag :: enum u8 {
	IDENT,    // data.lhs = name index in `names`,    data.rhs = unused
	BINARY,   // data.lhs = left index,               data.rhs = right index
	MEMBER,   // data.lhs = object index,             data.rhs = prop name index
	CALL,     // data.lhs = callee index,             data.rhs = extra start
	          //                                                  (extra[start] = arg count, then arg indices)
}

NodeData :: struct {
	lhs: u32,
	rhs: u32,
}                          // 8 B per node

Span :: struct {
	start: u32,
	end:   u32,
}                          // 8 B per node

// Pre-allocated raw buffers (Zig-style): fixed capacity, manual length
// tracker. Eliminates the per-append capacity check and allocator
// vtable traffic that `[dynamic]T` incurs. The parser estimates the
// upper bound (e.g. from token count) once at init.
AstSOA :: struct {
	tags:     []NodeTag,
	tags_len: int,
	data:     []NodeData,
	data_len: int,
	spans:    []Span,
	spans_len: int,
	names:    []string,
	names_len: int,
	extra:    []u32,
	extra_len: int,
}

ast_soa_init :: proc(ast: ^AstSOA, alloc: mem.Allocator, cap: int) {
	ast.tags  = make([]NodeTag,  cap, alloc)
	ast.data  = make([]NodeData, cap, alloc)
	ast.spans = make([]Span,     cap, alloc)
	ast.names = make([]string,   cap, alloc)
	ast.extra = make([]u32,      cap, alloc)
}

soa_alloc_node :: #force_inline proc(ast: ^AstSOA, tag: NodeTag, lhs, rhs: u32, span: Span) -> u32 {
	idx := ast.tags_len
	ast.tags[idx]  = tag
	ast.data[idx]  = NodeData{lhs = lhs, rhs = rhs}
	ast.spans[idx] = span
	ast.tags_len  = idx + 1
	ast.data_len  = idx + 1
	ast.spans_len = idx + 1
	return u32(idx)
}

soa_intern_name :: #force_inline proc(ast: ^AstSOA, s: string) -> u32 {
	idx := ast.names_len
	ast.names[idx] = s
	ast.names_len = idx + 1
	return u32(idx)
}

soa_push_extra :: #force_inline proc(ast: ^AstSOA, v: u32) {
	ast.extra[ast.extra_len] = v
	ast.extra_len += 1
}

// Mirror of build_aos for the SoA representation.
build_soa :: proc(ast: ^AstSOA, depth, branch: int) -> u32 {
	if depth <= 0 {
		name_idx := soa_intern_name(ast, "x")
		return soa_alloc_node(ast, .IDENT, name_idx, 0,
			Span{start = u32(depth), end = u32(depth) + 1})
	}
	switch branch % 3 {
	case 0:
		left := build_soa(ast, depth - 1, branch + 1)
		right := build_soa(ast, depth - 1, branch + 2)
		return soa_alloc_node(ast, .BINARY, left, right, Span{start = 0, end = u32(depth)})
	case 1:
		obj := build_soa(ast, depth - 1, branch + 1)
		prop := soa_intern_name(ast, "field")
		return soa_alloc_node(ast, .MEMBER, obj, prop, Span{start = 0, end = u32(depth)})
	case:
		callee := build_soa(ast, depth - 1, branch + 1)
		a0 := build_soa(ast, depth - 1, branch + 2)
		a1 := build_soa(ast, depth - 1, branch + 3)
		// Encode args list in `extra`: [count, idx0, idx1, ...]
		args_start := u32(ast.extra_len)
		soa_push_extra(ast, u32(2))
		soa_push_extra(ast, a0)
		soa_push_extra(ast, a1)
		return soa_alloc_node(ast, .CALL, callee, args_start, Span{start = 0, end = u32(depth)})
	}
	return 0
}

walk_soa :: proc(ast: ^AstSOA, idx: u32) -> u64 {
	tag := ast.tags[idx]
	d := ast.data[idx]
	span := ast.spans[idx]
	switch tag {
	case .IDENT:
		return u64(span.start) + u64(span.end)
	case .BINARY:
		return u64(span.start) + walk_soa(ast, d.lhs) + walk_soa(ast, d.rhs)
	case .MEMBER:
		return u64(span.start) + walk_soa(ast, d.lhs)
	case .CALL:
		acc := u64(span.start) + walk_soa(ast, d.lhs)
		count := ast.extra[d.rhs]
		for i in u32(0)..<count {
			acc += walk_soa(ast, ast.extra[d.rhs + 1 + i])
		}
		return acc
	}
	return 0
}

soa_node_count :: proc(ast: ^AstSOA) -> int { return ast.tags_len }

// ============================================================================
// Bench harness
// ============================================================================

main :: proc() {
	iterations := 50
	if len(os.args) >= 2 {
		if n, ok := strconv.parse_int(os.args[1]); ok { iterations = n }
	}
	depth := 12  // ~yields ~5K nodes per tree (verify below)
	if len(os.args) >= 3 {
		if n, ok := strconv.parse_int(os.args[2]); ok { depth = n }
	}
	trees_per_iter := 100  // total ~500K nodes per iter

	// Estimate node count once
	{
		arena: mvirtual.Arena
		_ = mvirtual.arena_init_static(&arena, 1024 * 1024 * 1024)
		defer mvirtual.arena_destroy(&arena)
		alloc := mvirtual.arena_allocator(&arena)
		ast: AstSOA
		ast_soa_init(&ast, alloc, 1024 * 1024)
		for t in 0..<trees_per_iter { _ = build_soa(&ast, depth, t) }
		fmt.printf("Synthetic load: depth=%d, trees/iter=%d, nodes/iter=%d, names=%d, extra-entries=%d\n",
			depth, trees_per_iter, ast.tags_len, ast.names_len, ast.extra_len)
	}

	aos_durs := make([dynamic]time.Duration, context.allocator)
	soa_durs := make([dynamic]time.Duration, context.allocator)
	defer delete(aos_durs)
	defer delete(soa_durs)

	for it in 0..<iterations {
		// AoS run — fresh arena per iter so allocations are not amortized.
		{
			arena: mvirtual.Arena
			_ = mvirtual.arena_init_static(&arena, 1024 * 1024 * 1024)
			defer mvirtual.arena_destroy(&arena)
			alloc := mvirtual.arena_allocator(&arena)
			start := time.tick_now()
			checksum: u64 = 0
			for t in 0..<trees_per_iter {
				root := build_aos(alloc, depth, t)
				checksum += walk_aos(root)
			}
			elapsed := time.tick_since(start)
			append(&aos_durs, elapsed)
			if it == 0 { fmt.printf("AoS checksum: %d\n", checksum) }
		}
		// SoA run — ONE arena, ONE Ast for all trees in the iter (mirrors
		// the real-world case where a single parser builds one Ast).
		{
			arena: mvirtual.Arena
			_ = mvirtual.arena_init_static(&arena, 1024 * 1024 * 1024)
			defer mvirtual.arena_destroy(&arena)
			alloc := mvirtual.arena_allocator(&arena)
			start := time.tick_now()
			checksum: u64 = 0
			ast: AstSOA
			ast_soa_init(&ast, alloc, 4 * 1024 * 1024)  // pre-allocate 4M slots
			roots := make([]u32, trees_per_iter, alloc)
			for t in 0..<trees_per_iter {
				roots[t] = build_soa(&ast, depth, t)
			}
			for r in roots {
				checksum += walk_soa(&ast, r)
			}
			elapsed := time.tick_since(start)
			append(&soa_durs, elapsed)
			if it == 0 { fmt.printf("SoA checksum: %d  (nodes=%d)\n", checksum, ast.tags_len) }
		}
	}

	// Stats
	report :: proc(name: string, durs: []time.Duration) -> f64 {
		us_per_iter := make([]f64, len(durs), context.temp_allocator)
		for d, i in durs { us_per_iter[i] = f64(time.duration_microseconds(d)) }
		// Compute min/median
		// (sort manually — simple bubble for the small N)
		for i in 0..<len(us_per_iter) {
			for j in i+1..<len(us_per_iter) {
				if us_per_iter[j] < us_per_iter[i] {
					us_per_iter[i], us_per_iter[j] = us_per_iter[j], us_per_iter[i]
				}
			}
		}
		min_v := us_per_iter[0]
		med_v := us_per_iter[len(us_per_iter) / 2]
		max_v := us_per_iter[len(us_per_iter) - 1]
		fmt.printf("%-6s  min=%9.1f us  med=%9.1f us  max=%9.1f us\n", name, min_v, med_v, max_v)
		return med_v
	}

	fmt.println("\nResults:")
	aos_med := report("AoS",  aos_durs[:])
	soa_med := report("SoA",  soa_durs[:])

	delta := (soa_med - aos_med) / aos_med * 100
	speedup := aos_med / soa_med
	fmt.printf("\nSoA vs AoS:  %+.1f %% Δ time   (%.3fx speedup)\n", delta, speedup)
	fmt.printf("If positive Δ → SoA is SLOWER. If negative → SoA is faster.\n")
}
