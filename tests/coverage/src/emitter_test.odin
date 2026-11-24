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

// A raw reader follows arena-relative offsets through the import options and its object.
@(test)
test_raw_import_type_options :: proc(t: ^testing.T) {
	job: kessel.ParseJob
	source := `type T = typeof import("pkg", { with: { type: "json" } }).Entry;`
	if !testing.expect(t, kessel.parse_job_open_inline(&job, source, {}, "import.ts")) { return }
	defer kessel.parse_job_close(&job)
	kessel.parse_job_run(&job)
	if !testing.expect(t, len(job.parser.errors) == 0 && len(job.program.body) == 1) { return }

	alias := job.program.body[0]^.(^kessel.TSTypeAliasDeclaration)
	import_type := alias.type_annotation^.(^kessel.TSImportType)
	if !testing.expect(t, import_type.has_options && import_type.is_typeof) { return }
	full := cast(^kessel.TSImportTypeWithOptions)import_type
	expression := full.options
	object := expression^.(^kessel.ObjectExpression)
	if !testing.expect(t, len(object.properties) == 1) { return }
	property := &object.properties[0]
	value := property.value
	base := uintptr(job.arena_ptr.curr_block.base)
	raw := kessel.produce_raw_buffer_from_job(&job)
	testing.expect_value(t, raw.header.version, u32(1))
	testing.expect_value(t, (^u32)(&full.options)^, u32(uintptr(expression) - base))
	testing.expect_value(t, (^u32)(expression)^, u32(uintptr(object) - base))
	testing.expect_value(t, (^u32)(&property.value)^, u32(uintptr(value) - base))
}
