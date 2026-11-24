// ============================================================================
// alloc_guard.odin — makes allocation failure during a parse visible
// ============================================================================
//
// The lexer and parser allocate from an arena and, like most arena code,
// ignore the error result: hundreds of `make` / `append` / `new` sites
// assume memory is there. That assumption breaks for a library consumer:
// the arena is a fixed reservation, or a caller-supplied allocator with its
// own limit, and input size is not under our control. An unnoticed failure
// is a nil dereference at best and a silently truncated AST at worst.
//
// Checking every site would touch the hot path everywhere and still miss
// the next site someone adds. Instead every allocation the lexer and parser
// make goes through this guard, which sits between them and the arena:
//
//   1. It latches `failed` the first time the backing allocator cannot
//      satisfy a request, and records where the lexer was. The parser turns
//      the latch into one K2085_OutOfMemory diagnostic (parser.odin,
//      parser_finish_memory), so a failure can never go unreported.
//
//   2. It keeps the parse supplied with memory while it winds down. The
//      parser stops consuming input as soon as it notices the latch, but
//      the call frames already on the stack still finish their nodes on
//      the way out, and each of those nodes must be real, distinct memory:
//      handing two frames the same sentinel node lets one read fields the
//      other wrote as a different type. After the latch a request is tried
//      against, in order: the backing allocator again (a smaller request
//      may still fit), the optional `fallback` allocator (parse_job points
//      it at memory that is independent of the exhausted arena), and the
//      small `reserve` inside the guard itself, which exists even when
//      every allocator fails from the first request.
//
// Only when all three are empty does a request return nil. For an AST node
// that is fatal by design (parser_alloc_node_slow panics). How much the
// wind-down needs grows with how deeply nested the parse was when memory
// ran out; tests/coverage/src/hardening_test.odin measures it.
//
// Cost on the path that matters: none for AST nodes, which come from the
// parser's bump pool without touching any allocator. Other allocations
// (dynamic array growth, cooked strings) already paid an indirect call into
// the arena; they now pay a second one and a compare. That was not
// benchmarked when this was written; see the commit message.
package kessel

import "core:mem"

// Sized for unwinding, not for parsing: once the latch is seen the lexer is
// halted, so the reserve only has to cover what the call frames already on
// the stack still allocate on their way out. In the allocation-failure
// sweeps the worst case, a sample with roughly 50 constructs open at once,
// took 3040 bytes; the tests assert the need stays inside half the reserve.
// Inline, so it cannot fail to exist; that also caps its size, since jobs
// live on callers' stacks.
ALLOC_GUARD_RESERVE_SIZE :: 16 * 1024
#assert(ALLOC_GUARD_RESERVE_SIZE % 16 == 0)

// Largest single request the reserve serves. It exists for AST nodes and
// the small arrays hanging off them; a big request (the node bump pool, a
// long list doubling its capacity) would drain it in one go and is refused
// instead. Callers of those already cope with a failed allocation: the
// pool falls back to per-node allocation, a list drops the element.
ALLOC_GUARD_PIECE_SIZE_MAX :: 1024

// Most the fallback allocator is asked for in one parse. The fallback is
// there to let a lost parse wind down, not to let it carry on past the
// arena's budget on borrowed memory.
ALLOC_GUARD_FALLBACK_SIZE_MAX :: 1024 * 1024
#assert(ALLOC_GUARD_PIECE_SIZE_MAX * 8 <= ALLOC_GUARD_RESERVE_SIZE)

AllocGuard :: struct {
	backing:      mem.Allocator,
	// Consulted after `backing` refuses a request; procedure nil = none.
	fallback:      mem.Allocator,
	fallback_used: int, // bytes, at most ALLOC_GUARD_FALLBACK_SIZE_MAX
	reserve_used:  int, // bytes, at most ALLOC_GUARD_RESERVE_SIZE
	// Latched on the first request the backing allocator refuses.
	failed:       bool,
	// Lexer cursor to sample when the latch trips (nil = not tracked), and
	// the sampled byte offset: roughly where in the source memory ran out.
	cursor:       ^int,
	failed_at:    int,
	// Emergency memory; u128 elements for 16-byte alignment. Last, so the
	// fields above share a cache line with whatever precedes the guard.
	reserve:      [ALLOC_GUARD_RESERVE_SIZE / 16]u128,
}

// Wrap `backing`. `guard` must stay at a stable address for as long as the
// returned allocator is in use. `fallback` may be left zero, `cursor` nil.
alloc_guard_init :: proc(
	guard: ^AllocGuard, backing: mem.Allocator, fallback: mem.Allocator, cursor: ^int,
) {
	assert(backing.procedure != nil)
	guard.fallback = fallback
	guard.fallback_used = 0
	// Field by field: the reserve needs no clearing (each piece is zeroed
	// when handed out), and parse_job_run may be called once per bench
	// iteration.
	guard.backing = backing
	guard.reserve_used = 0
	guard.failed = false
	guard.cursor = cursor
	guard.failed_at = 0
}

alloc_guard_allocator :: proc(guard: ^AllocGuard) -> mem.Allocator {
	return mem.Allocator{procedure = alloc_guard_proc, data = guard}
}

// The allocator behind a guard, or `allocator` itself when it is not one.
// For the rare caller that can do better than a failed request (it retries
// with a smaller size) and so must not trip the latch.
alloc_guard_unwrap :: proc(allocator: mem.Allocator) -> mem.Allocator {
	if allocator.procedure != alloc_guard_proc { return allocator }
	guard := (^AllocGuard)(allocator.data)
	assert(guard.backing.procedure != nil)
	return guard.backing
}

@(private="file")
alloc_guard_latch :: proc(guard: ^AllocGuard) {
	if guard.failed { return }
	guard.failed = true
	if guard.cursor != nil { guard.failed_at = guard.cursor^ }
}

alloc_guard_proc :: proc(
	allocator_data: rawptr, mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr, old_size: int,
	loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	guard := (^AllocGuard)(allocator_data)
	wants_memory := false
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		wants_memory = size > 0
	case .Free:
		// A reserve piece is not the backing allocator's to free.
		if alloc_guard_owns(guard, old_memory) { return nil, nil }
	}
	if wants_memory {
		// A block handed out by the reserve cannot be resized by the
		// backing allocator, which never saw it.
		if !alloc_guard_owns(guard, old_memory) {
			data, err := guard.backing.procedure(
				guard.backing.data, mode, size, alignment, old_memory, old_size, loc)
			if err == nil && raw_data(data) != nil { return data, nil }
		}
		alloc_guard_latch(guard)
		if guard.fallback.procedure != nil {
			data, err := alloc_guard_from_fallback(
				guard, size, alignment, old_memory, old_size, loc)
			if err == nil { return data, nil }
		}
		return alloc_guard_from_reserve(guard, size, alignment, old_memory, old_size)
	}
	return guard.backing.procedure(
		guard.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

// Fresh zeroed memory from the fallback allocator, carrying over the old
// contents for a resize. Never a resize in place: the old block belongs to
// whichever allocator produced it, which the guard does not track.
@(private="file")
alloc_guard_from_fallback :: proc(
	guard: ^AllocGuard, size, alignment: int, old_memory: rawptr, old_size: int,
	loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	assert(size > 0)
	assert(guard.fallback_used <= ALLOC_GUARD_FALLBACK_SIZE_MAX)
	if size > ALLOC_GUARD_FALLBACK_SIZE_MAX - guard.fallback_used { return nil, .Out_Of_Memory }
	data, err := guard.fallback.procedure(guard.fallback.data, .Alloc, size, alignment, nil, 0, loc)
	if err != nil { return nil, err }
	if raw_data(data) == nil { return nil, .Out_Of_Memory }
	guard.fallback_used += size
	if old_memory != nil && old_size > 0 {
		mem.copy(raw_data(data), old_memory, min(old_size, size))
	}
	return data, nil
}

@(private="file")
alloc_guard_owns :: proc(guard: ^AllocGuard, ptr: rawptr) -> bool {
	base := uintptr(&guard.reserve)
	return uintptr(ptr) >= base && uintptr(ptr) < base + ALLOC_GUARD_RESERVE_SIZE
}

// Bump-allocate `size` zeroed bytes from the reserve, carrying over the old
// contents for a resize. Out_Of_Memory once the reserve cannot fit it.
@(private="file")
alloc_guard_from_reserve :: proc(
	guard: ^AllocGuard, size, alignment: int, old_memory: rawptr, old_size: int,
) -> ([]byte, mem.Allocator_Error) {
	assert(size > 0)
	assert(guard.reserve_used <= ALLOC_GUARD_RESERVE_SIZE)
	if size > ALLOC_GUARD_PIECE_SIZE_MAX { return nil, .Out_Of_Memory }
	align := max(alignment, 1)
	assert(align & (align - 1) == 0)
	base := uintptr(&guard.reserve)
	unaligned := base + uintptr(guard.reserve_used)
	start := int(mem.align_forward_uintptr(unaligned, uintptr(align)) - base)
	if start > ALLOC_GUARD_RESERVE_SIZE { return nil, .Out_Of_Memory }
	if size > ALLOC_GUARD_RESERVE_SIZE - start { return nil, .Out_Of_Memory }
	piece := ([^]u8)(&guard.reserve)[start:start + size]
	guard.reserve_used = start + size
	mem.zero_slice(piece)
	if old_memory != nil && old_size > 0 {
		mem.copy(raw_data(piece), old_memory, min(old_size, size))
	}
	return piece, nil
}
