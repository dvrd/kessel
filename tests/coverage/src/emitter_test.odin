// Batch parsing must release each source's UTF-16 offset table before moving on.
package coverage

import "core:mem"
import "core:testing"

import kessel "../../../src"

@(test)
test_emitter_releases_unicode_offsets :: proc(t: ^testing.T) {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	allocator := mem.tracking_allocator(&tracker)

	emitter: kessel.Emitter
	kessel.emitter_init(&emitter, {}, 0, allocator)
	sources := [?]string{"é", "𐐀", "ascii", "é"}
	for source in sources {
		kessel.emitter_build_utf16(&emitter, transmute([]byte)source)
		if source == "ascii" {
			testing.expect_value(t, tracker.current_memory_allocated, i64(len(emitter.buf)))
		}
	}
	// Growth must also use the emitter's allocator.
	kessel.emit_reserve(&emitter, 8192)
	kessel.emitter_destroy(&emitter)
	kessel.emitter_destroy(&emitter)
	testing.expect_value(t, tracker.current_memory_allocated, i64(0))
}
