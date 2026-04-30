package main

// DoD prototype v3: REALISTIC interleaved load.
//
// proto2 measured pure AST construction. That overstates the SoA win
// because production parsers don't just allocate nodes — they
// interleave AST allocation with: source-byte reads, keyword compares,
// token snapshots, span saves. All of those compete with SoA's
// contiguous arrays for L1d / L2.
//
// proto3 keeps the same recursive build pattern as proto2 but adds
// realistic per-node "other work" between allocations:
//
//   1. Source-byte read from a 1.7 MB buffer (simulates span lookup)
//   2. 8-byte string compare against a literal (simulates keyword check)
//   3. 64-byte token-shape write to a parallel array (simulates
//      token snapshot in advance_token)
//   4. Light arithmetic (simulates source position bookkeeping)
//
// If SoA's win on pure construction was 7.5 % (proto2 current measure),
// proto3 will show how much of that survives when surrounding work
// is competing for cache.

import "core:fmt"
import "core:mem"
import mvirtual "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:time"

// ============================================================================
// Shared bump pool (matches kessel's bump_alloc exactly)
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
// Realistic-work simulator
// ============================================================================
//
// Token shape mirrors kessel's post-S24 ParserToken (~64 B):
//   type (1 B) + flags (1 B) + pad (2 B) + start (4 B) + raw_end (4 B)
//   + value (16 B string) + literal (32 B union) + had_line_terminator (1 B)
//   + has_escape (1 B) = 60 B + pad → 64 B
ParserTokenShape :: struct #packed {
	type_:                u8,         // 1 B
	flags:                u8,         // 1 B
	_pad:                 [2]u8,      // 2 B
	start:                u32,        // 4 B
	raw_end:              u32,        // 4 B
	value:                string,     // 16 B
	literal:              [32]u8,     // 32 B (simulates literal union)
	had_line_terminator:  bool,       // 1 B
	has_escape:           bool,       // 1 B
	_pad2:                [2]u8,      // 2 B
}                                  // = 64 B packed
#assert(size_of(ParserTokenShape) == 64)

Sim :: struct {
	source:        []u8,         // 1.7 MB source buffer
	tokens:        []ParserTokenShape,  // parallel token array
	tokens_len:    int,
	checksum:      u64,
}

// Per-node "other work": source read + keyword compare + token write +
// arithmetic. Returns a value derived from the work so the optimizer
// can't elide it.
//
// Toggle the SIM_LIGHT compile-time constant to disable the token write
// (leaves only source-byte reads + arithmetic).
SIM_LIGHT :: #config(SIM_LIGHT, false)
SIM_NONE  :: #config(SIM_NONE,  false)

sim_per_node :: #force_inline proc(s: ^Sim, depth, branch: int) -> u32 {
	when SIM_NONE { return u32(depth) + u32(branch) }
	// 1. Source-byte read at a depth-derived offset (cache-line crossing)
	off := (uint(depth * 1031 + branch * 257) * 64) & uint(len(s.source) - 64)
	src := s.source
	b0 := u32(src[off])
	b1 := u32(src[off + 1])
	b2 := u32(src[off + 2])
	b3 := u32(src[off + 3])

	// 2. Eight-byte keyword compare (mirrors lookup_keyword_by_letter)
	kw_match := u32(0)
	if b0 == 'i' && b1 == 'f' { kw_match = 1 }
	else if b0 == 'f' && b1 == 'o' && b2 == 'r' { kw_match = 2 }
	else if b0 == 'v' && b1 == 'a' && b2 == 'r' { kw_match = 3 }

	// 3. 64-byte token-shape write (mirrors advance_token snapshot)
	when !SIM_LIGHT {
		if s.tokens_len < len(s.tokens) {
			t := &s.tokens[s.tokens_len]
			t.type_ = u8(branch & 0xff)
			t.flags = u8(depth & 0xff)
			t.start = u32(off)
			t.raw_end = u32(off) + 4
			t.value = ""
			t.had_line_terminator = (depth & 1) == 0
			t.has_escape = false
			s.tokens_len += 1
		}
	}

	// 4. Light arithmetic (simulates span bookkeeping). Keep it visible.
	return b0 + (b1 << 8) + (b2 << 16) + (b3 << 24) + kw_match
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
	t := transmute(^T)ptr
	t^ = T{}
	return t
}

build_aos :: proc(pool: ^BumpPool, sim: ^Sim, depth, branch: int) -> ExprAOS {
	w := sim_per_node(sim, depth, branch)
	sim.checksum += u64(w)

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
		b.left = build_aos(pool, sim, depth - 1, branch + 1)
		b.right = build_aos(pool, sim, depth - 1, branch + 2)
		b.start = 0
		b.end = u32(depth)
		return b
	case 1:
		m := bump_new_aos(pool, MemberAOS)
		m.object = build_aos(pool, sim, depth - 1, branch + 1)
		m.prop = "field"
		m.start = 0
		m.end = u32(depth)
		return m
	case:
		c := bump_new_aos(pool, CallAOS)
		c.callee = build_aos(pool, sim, depth - 1, branch + 1)
		args_ptr := bump_alloc(pool, 2 * size_of(ExprAOS), align_of(ExprAOS))
		args := (transmute([^]ExprAOS)args_ptr)[:2]
		args[0] = build_aos(pool, sim, depth - 1, branch + 2)
		args[1] = build_aos(pool, sim, depth - 1, branch + 3)
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
	ast.extra = make([]u32,      cap * 4, alloc)
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

build_soa :: proc(ast: ^AstSOA, sim: ^Sim, depth, branch: int) -> u32 {
	w := sim_per_node(sim, depth, branch)
	sim.checksum += u64(w)

	if depth <= 0 {
		ni := soa_intern_name(ast, "x")
		return soa_alloc_node(ast, .IDENT, ni, 0, Span{u32(depth), u32(depth) + 1})
	}
	switch branch % 3 {
	case 0:
		l := build_soa(ast, sim, depth - 1, branch + 1)
		r := build_soa(ast, sim, depth - 1, branch + 2)
		return soa_alloc_node(ast, .BINARY, l, r, Span{0, u32(depth)})
	case 1:
		o := build_soa(ast, sim, depth - 1, branch + 1)
		p := soa_intern_name(ast, "field")
		return soa_alloc_node(ast, .MEMBER, o, p, Span{0, u32(depth)})
	case:
		c := build_soa(ast, sim, depth - 1, branch + 1)
		a0 := build_soa(ast, sim, depth - 1, branch + 2)
		a1 := build_soa(ast, sim, depth - 1, branch + 3)
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

	// Read the synthetic source corpus (real bytes, real cache pressure).
	source_bytes, read_err := os.read_entire_file_from_path("bench/dod_proto/expr_corpus.js", context.allocator)
	if read_err != nil {
		fmt.eprintln("error: bench/dod_proto/expr_corpus.js not found")
		os.exit(1)
	}
	defer delete(source_bytes)
	fmt.printf("Source corpus: %d bytes\n", len(source_bytes))

	// Pre-size the tokens array to a generous bound.
	max_tokens := 8 * 1024 * 1024

	// Estimate node count from a dry run
	{
		arena: mvirtual.Arena
		_ = mvirtual.arena_init_static(&arena, 1024 * 1024 * 1024)
		defer mvirtual.arena_destroy(&arena)
		alloc := mvirtual.arena_allocator(&arena)
		ast: AstSOA
		ast_soa_init(&ast, alloc, 8 * 1024 * 1024)
		sim: Sim
		sim.source = source_bytes
		sim.tokens = make([]ParserTokenShape, max_tokens, alloc)
		for t in 0..<trees_per_iter { _ = build_soa(&ast, &sim, depth, t) }
		fmt.printf("Synthetic load: depth=%d, trees/iter=%d, nodes/iter=%d, sim_tokens/iter=%d\n",
			depth, trees_per_iter, ast.tags_len, sim.tokens_len)
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
			sim: Sim
			sim.source = source_bytes
			sim.tokens = make([]ParserTokenShape, max_tokens, alloc)
			start := time.tick_now()
			checksum: u64 = 0
			for t in 0..<trees_per_iter {
				root := build_aos(&pool, &sim, depth, t)
				checksum += walk_aos(root)
			}
			elapsed := time.tick_since(start)
			append(&aos_durs, elapsed)
			if it == 0 { fmt.printf("AoS/bump checksum: %d  bump_used=%d  sim_chk=%d  tokens=%d\n",
				checksum, pool.offset, sim.checksum, sim.tokens_len) }
		}
		// SoA run
		{
			arena: mvirtual.Arena
			_ = mvirtual.arena_init_static(&arena, 1024 * 1024 * 1024)
			defer mvirtual.arena_destroy(&arena)
			alloc := mvirtual.arena_allocator(&arena)
			sim: Sim
			sim.source = source_bytes
			sim.tokens = make([]ParserTokenShape, max_tokens, alloc)
			start := time.tick_now()
			checksum: u64 = 0
			ast: AstSOA
			ast_soa_init(&ast, alloc, 8 * 1024 * 1024)
			roots := make([]u32, trees_per_iter, alloc)
			for t in 0..<trees_per_iter { roots[t] = build_soa(&ast, &sim, depth, t) }
			for r in roots { checksum += walk_soa(&ast, r) }
			elapsed := time.tick_since(start)
			append(&soa_durs, elapsed)
			if it == 0 { fmt.printf("SoA      checksum: %d  nodes=%d  sim_chk=%d  tokens=%d\n",
				checksum, ast.tags_len, sim.checksum, sim.tokens_len) }
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

	fmt.println("\nResults (with realistic interleaved work):")
	aos_med := report("AoS/bump", aos_durs[:])
	soa_med := report("SoA",      soa_durs[:])
	delta := (soa_med - aos_med) / aos_med * 100
	speedup := aos_med / soa_med
	fmt.printf("\nSoA vs AoS/bump:  %+.1f %% \u0394 time   (%.3fx speedup)\n", delta, speedup)
}
