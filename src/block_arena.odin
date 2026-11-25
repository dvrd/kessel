// block_arena.odin — a growing arena over a caller-supplied allocator.
//
// A parse job given an allocator (parse_job_open_inline's `backing`) takes
// all of its memory from it in blocks and returns every block on close. The
// arena must survive that allocator refusing a block: the refusal is how a
// parse runs out of memory, and the allocation guard (alloc_guard.odin)
// turns it into a K2085 diagnostic. core:mem's Dynamic_Arena does not
// survive it in the Odin release Kessel is built with: after a refused
// block it keeps handing out addresses inside the missing block. This arena
// changes no state until the backing allocator has said yes.
//
// Layout. Each block starts with a BlockArenaHeader; the headers form a
// singly linked list, so tracking blocks needs no further allocation (a
// dynamic array of block pointers would itself have to grow, and could
// fail, in the middle of handling a failure). Requests larger than a
// quarter of a block get a block of their own so the current block is not
// abandoned half used. Freeing a single allocation is a no-op; everything
// goes back to the backing allocator in block_arena_destroy.

package kessel

import "core:mem"

BlockArena :: struct {
	backing:    mem.Allocator,
	block_size: int, // bytes per ordinary block, header included
	blocks:     ^BlockArenaHeader, // most recent first
	cursor:     uintptr, // next free byte in `blocks`, 0 when there is none
	end:        uintptr, // one past the last usable byte of `blocks`
}

@(private = "file")
BlockArenaHeader :: struct {
	next: ^BlockArenaHeader,
	size: int, // bytes requested from the backing allocator, header included
}

BLOCK_ARENA_ALIGNMENT_MAX :: 64

// Allocations are aligned after the header, so its size only has to leave
// room for that within the padding a dedicated block reserves.
#assert(size_of(BlockArenaHeader) <= BLOCK_ARENA_ALIGNMENT_MAX)

block_arena_init :: proc(arena: ^BlockArena, backing: mem.Allocator, block_size: int) {
	assert(backing.procedure != nil)
	assert(block_size > 4 * size_of(BlockArenaHeader))
	arena^ = BlockArena{backing = backing, block_size = block_size}
}

block_arena_allocator :: proc(arena: ^BlockArena) -> mem.Allocator {
	assert(arena.backing.procedure != nil)
	return mem.Allocator{procedure = block_arena_proc, data = arena}
}

// Return every block to the backing allocator. The arena can be used again
// afterwards; it starts empty.
block_arena_destroy :: proc(arena: ^BlockArena) {
	header := arena.blocks
	// Each iteration releases one block; the list is finite because every
	// block was added exactly once.
	for header != nil {
		next := header.next
		size := header.size
		assert(size >= size_of(BlockArenaHeader))
		mem.free_with_size(header, size, arena.backing)
		header = next
	}
	arena.blocks = nil
	arena.cursor = 0
	arena.end = 0
}

@(private = "file")
block_arena_proc :: proc(
	allocator_data: rawptr, mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr, old_size: int,
	loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	arena := (^BlockArena)(allocator_data)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		return block_arena_alloc(arena, size, alignment)
	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil { return block_arena_alloc(arena, size, alignment) }
		if size <= old_size { return mem.byte_slice(old_memory, size), nil }
		data, err := block_arena_alloc(arena, size, alignment)
		if err != nil { return nil, err }
		mem.copy(raw_data(data), old_memory, old_size)
		return data, nil
	case .Free:
		return nil, nil
	case .Free_All:
		block_arena_destroy(arena)
		return nil, nil
	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Free, .Free_All,
				.Query_Features}
		}
		return nil, nil
	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, .Mode_Not_Implemented
}

// `size` zeroed bytes aligned to `alignment`, or .Out_Of_Memory with the
// arena unchanged.
@(private = "file")
block_arena_alloc :: proc(arena: ^BlockArena, size, alignment: int) -> ([]byte, mem.Allocator_Error) {
	assert(size >= 0)
	assert(alignment > 0 && alignment <= BLOCK_ARENA_ALIGNMENT_MAX)
	assert(mem.is_power_of_two(uintptr(alignment)))
	if size == 0 { return nil, nil }
	if arena.cursor != 0 {
		start := mem.align_forward_uintptr(arena.cursor, uintptr(alignment))
		if start <= arena.end && uintptr(size) <= arena.end - start {
			arena.cursor = start + uintptr(size)
			data := mem.byte_slice(rawptr(start), size)
			mem.zero_slice(data)
			return data, nil
		}
	}
	// A request that would waste most of a block gets a block of its own,
	// and the current block stays in use.
	dedicated := size > arena.block_size / 4
	block_size := arena.block_size
	if dedicated { block_size = size_of(BlockArenaHeader) + alignment + size }
	block, err := mem.alloc_bytes(block_size, BLOCK_ARENA_ALIGNMENT_MAX, arena.backing)
	if err != nil || raw_data(block) == nil { return nil, .Out_Of_Memory }
	assert(len(block) == block_size)

	header := (^BlockArenaHeader)(raw_data(block))
	header.size = block_size
	header.next = arena.blocks
	arena.blocks = header
	body := uintptr(raw_data(block)) + size_of(BlockArenaHeader)
	start := mem.align_forward_uintptr(body, uintptr(alignment))
	block_end := uintptr(raw_data(block)) + uintptr(block_size)
	assert(start + uintptr(size) <= block_end)
	// A dedicated block is full; ordinary requests keep using the current one.
	if !dedicated {
		arena.cursor = start + uintptr(size)
		arena.end = block_end
	}
	data := mem.byte_slice(rawptr(start), size)
	mem.zero_slice(data)
	return data, nil
}
