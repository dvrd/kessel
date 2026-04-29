package main

// DoD prototype v2: FAIR comparison.
//
// v1 compared `mem.virtual.arena_allocator` (with mutex, vtable) against
// pre-allocated SoA arrays. Result: 2.2× SoA win.
//
// But kessel doesn't use the slow arena path for AST nodes — it has a
// custom bump pool (`bump_alloc`) that's just pointer arithmetic. So
// v1's AoS half was unfair to kessel's actual implementation.
//
// v2 uses the SAME bump-pool primitive for both AoS and SoA. This
// isolates the SoA structural win from the arena-vtable overhead.

import "core:fmt"
import "core:mem"
import mvirtual "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:time"

// ============================================================================
// Shared bump pool (matches kessel's `bump_alloc` exactly)
// ============================================================================

BumpPool :: struct {
	base:     [^]u8,
	offset:   int,
	capacity: int,
}

bump_init :: proc(pool: ^BumpPool, alloc: mem.Allocator, cap: int) {
	raw, _ := mem.alloc_bytes(cap, 16, alloc)
	pool.base = raw_data(raw)
	pool.offset = 0
	pool.capacity = cap
}

bump_alloc :: #force_inline proc(pool: ^BumpPool, size, align: int) -> rawptr {
	mask := align - 1
	aligned := (pool.offset + mask) & ~mask
	pool.offset = aligned + size
	return rawptr(uintptr(pool.base) + uintptr(aligned))
}

// ============================================================================
// AoS: pointer + Odin union, allocated via bump pool (fair to kessel)
// ============================================================================

ExprAOS :: union {
	^IdentifierAOS,
	^BinaryAOS,
	^MemberAOS,
	^CallAOS,
}

IdentifierAOS :: struct { name: string, start: u32, end: u32 }
BinaryAOS     :: struct { op: u8, _pad: [3]u8, left, right: ExprAOS, start, end: u32 }
MemberAOS     :: struct { object: ExprAOS, prop: string, start, end: u32 }
CallAOS       :: struct { callee: ExprAOS, args: []ExprAOS, start, end: u32 }

bump_new_aos :: #force_inline proc(pool: ^BumpPool, $T: typeid) -> ^T {
	ptr := bump_alloc(pool, size_of(T), align_of(T))
	// Zero-init (mirror what mem.new does)
	t := transmute(^T)ptr
	t^ = T{}
	return t
}

build_aos :: proc(pool: ^BumpPool, depth, branch: int) -> ExprAOS {
	if depth <= 0 {
		id := bump_new_aos(pool, IdentifierAOS)
		id.name = "x"
		id.start = u32(depth)
		id.end = u32(depth) + 1
		return id
	}
	switch branch % 3 {
	case 0:
		b := bump_new_aos(pool, BinaryAOS)
		b.op = '+'
		b.left = build_aos(pool, depth - 1, branch + 1)
		b.right = build_aos(pool, depth - 1, branch + 2)
		b.start = 0
		b.end = u32(depth)
		return b
	case 1:
		m := bump_new_aos(pool, MemberAOS)
		m.object = build_aos(pool, depth - 1, branch + 1)
		m.prop = "field"
		m.start = 0
		m.end = u32(depth)
		return m
	case:
		c := bump_new_aos(pool, CallAOS)
		c.callee = build_aos(pool, depth - 1, branch + 1)
		// Allocate args slice from bump pool
		args_ptr := bump_alloc(pool, 2 * size_of(ExprAOS), align_of(ExprAOS))
		args := (transmute([^]ExprAOS)args_ptr)[:2]
		args[0] = build_aos(pool, depth - 1, branch + 2)
		args[1] = build_aos(pool, depth - 1, branch + 3)
		c.args = args
		c.start = 0
		c.end = u32(depth)
		return c
	}
}

walk_aos :: proc(node: ExprAOS) -> u64 {
	#partial switch v in node {
	case ^IdentifierAOS: return u64(v.start) + u64(v.end)
	case ^BinaryAOS:     return u64(v.start) + walk_aos(v.left) + walk_aos(v.right)
	case ^MemberAOS:     return u64(v.start) + walk_aos(v.object)
	case ^CallAOS:
		acc := u64(v.start) + walk_aos(v.callee)
		for a in v.args { acc += walk_aos(a) }
		return acc
	}
	return 0
}

// ============================================================================
// SoA: Zig-style fixed-capacity buffers
// ============================================================================

NodeTag :: enum u8 { IDENT, BINARY, MEMBER, CALL }
NodeData :: struct { lhs, rhs: u32 }
Span :: struct { start, end: u32 }

AstSOA :: struct {
	tags:      []NodeTag,
	data:      []NodeData,
	spans:     []Span,
	names:     []string,
	extra:     []u32,
	tags_len:  int,
	names_len: int,
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
	ast.tags_len = idx + 1
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

build_soa :: proc(ast: ^AstSOA, depth, branch: int) -> u32 {
	if depth <= 0 {
		ni := soa_intern_name(ast, "x")
		return soa_alloc_node(ast, .IDENT, ni, 0, Span{u32(depth), u32(depth) + 1})
	}
	switch branch % 3 {
	case 0:
		l := build_soa(ast, depth - 1, branch + 1)
		r := build_soa(ast, depth - 1, branch + 2)
		return soa_alloc_node(ast, .BINARY, l, r, Span{0, u32(depth)})
	case 1:
		o := build_soa(ast, depth - 1, branch + 1)
		p := soa_intern_name(ast, "field")
		return soa_alloc_node(ast, .MEMBER, o, p, Span{0, u32(depth)})
	case:
		c := build_soa(ast, depth - 1, branch + 1)
		a0 := build_soa(ast, depth - 1, branch + 2)
		a1 := build_soa(ast, depth - 1, branch + 3)
		args_start := u32(ast.extra_len)
		soa_push_extra(ast, 2)
		soa_push_extra(ast, a0)
		soa_push_extra(ast, a1)
		return soa_alloc_node(ast, .CALL, c, args_start, Span{0, u32(depth)})
	}
	return 0
}

walk_soa :: proc(ast: ^AstSOA, idx: u32) -> u64 {
	tag := ast.tags[idx]
	d := ast.data[idx]
	span := ast.spans[idx]
	switch tag {
	case .IDENT:  return u64(span.start) + u64(span.end)
	case .BINARY: return u64(span.start) + walk_soa(ast, d.lhs) + walk_soa(ast, d.rhs)
	case .MEMBER: return u64(span.start) + walk_soa(ast, d.lhs)
	case .CALL:
		acc := u64(span.start) + walk_soa(ast, d.lhs)
		count := ast.extra[d.rhs]
		for i in u32(0)..<count { acc += walk_soa(ast, ast.extra[d.rhs + 1 + i]) }
		return acc
	}
	return 0
}

// ============================================================================
// Bench harness
// ============================================================================

main :: proc() {
	iterations := 30
	depth := 12
	if len(os.args) >= 2 { if n, ok := strconv.parse_int(os.args[1]); ok { iterations = n } }
	if len(os.args) >= 3 { if n, ok := strconv.parse_int(os.args[2]); ok { depth = n } }
	trees_per_iter := 100

	{
		arena: mvirtual.Arena
		_ = mvirtual.arena_init_static(&arena, 1024 * 1024 * 1024)
		defer mvirtual.arena_destroy(&arena)
		alloc := mvirtual.arena_allocator(&arena)
		ast: AstSOA
		ast_soa_init(&ast, alloc, 4 * 1024 * 1024)
		for t in 0..<trees_per_iter { _ = build_soa(&ast, depth, t) }
		fmt.printf("Synthetic load: depth=%d, trees/iter=%d, nodes/iter=%d\n",
			depth, trees_per_iter, ast.tags_len)
	}

	aos_durs := make([dynamic]time.Duration, context.allocator)
	soa_durs := make([dynamic]time.Duration, context.allocator)

	for it in 0..<iterations {
		// AoS run via bump pool (kessel-fair)
		{
			arena: mvirtual.Arena
			_ = mvirtual.arena_init_static(&arena, 2 * 1024 * 1024 * 1024)
			defer mvirtual.arena_destroy(&arena)
			alloc := mvirtual.arena_allocator(&arena)
			pool: BumpPool
			bump_init(&pool, alloc, 512 * 1024 * 1024)
			start := time.tick_now()
			checksum: u64 = 0
			for t in 0..<trees_per_iter {
				root := build_aos(&pool, depth, t)
				checksum += walk_aos(root)
			}
			elapsed := time.tick_since(start)
			append(&aos_durs, elapsed)
			if it == 0 { fmt.printf("AoS/bump checksum: %d  bump_used=%d\n", checksum, pool.offset) }
		}
		// SoA run
		{
			arena: mvirtual.Arena
			_ = mvirtual.arena_init_static(&arena, 1024 * 1024 * 1024)
			defer mvirtual.arena_destroy(&arena)
			alloc := mvirtual.arena_allocator(&arena)
			start := time.tick_now()
			checksum: u64 = 0
			ast: AstSOA
			ast_soa_init(&ast, alloc, 4 * 1024 * 1024)
			roots := make([]u32, trees_per_iter, alloc)
			for t in 0..<trees_per_iter { roots[t] = build_soa(&ast, depth, t) }
			for r in roots { checksum += walk_soa(&ast, r) }
			elapsed := time.tick_since(start)
			append(&soa_durs, elapsed)
			if it == 0 { fmt.printf("SoA      checksum: %d  nodes=%d\n", checksum, ast.tags_len) }
		}
	}

	report :: proc(name: string, durs: []time.Duration) -> f64 {
		us := make([]f64, len(durs), context.temp_allocator)
		for d, i in durs { us[i] = f64(time.duration_microseconds(d)) }
		for i in 0..<len(us) { for j in i+1..<len(us) { if us[j] < us[i] { us[i], us[j] = us[j], us[i] } } }
		fmt.printf("%-10s min=%9.1f us  med=%9.1f us  max=%9.1f us\n",
			name, us[0], us[len(us)/2], us[len(us)-1])
		return us[len(us)/2]
	}

	fmt.println("\nResults:")
	aos_med := report("AoS/bump", aos_durs[:])
	soa_med := report("SoA",      soa_durs[:])
	delta := (soa_med - aos_med) / aos_med * 100
	speedup := aos_med / soa_med
	fmt.printf("\nSoA vs AoS/bump:  %+.1f %% \u0394 time   (%.3fx speedup)\n", delta, speedup)
}
