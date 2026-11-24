// A library consumer parses many files in one process, so a parse job must
// give back everything it took when it is closed.
//
// Method: run whole jobs (open inline, parse, close) with a tracking
// allocator installed as `context.allocator` and require that nothing
// remains allocated afterwards. Only the job's virtual-memory arena may
// hold parser data, and closing the job releases it. Each source exercises
// one part of the parser that keeps side tables next to the AST.
package coverage

import "core:mem"
import "core:testing"

import kessel "../../../src"

@(test)
test_parse_job_releases_everything :: proc(t: ^testing.T) {
	Case :: struct { source: string, lang: kessel.Lang }
	cases := [?]Case{
		{"const x = 1;", .JS},
		// The module record: static imports and exports, dynamic imports
		// and import.meta each have their own table.
		{"import a, { b as c } from \"m\"; import * as n from \"n\";", .JS},
		{"export const a = 1; export { a as b }; export * from \"m\"; export default a;", .JS},
		{"const p = import(\"m\"); const u = import.meta.url;", .JS},
		{"import { Card } from \"ui\"; export const v = <Card t=\"&amp;\">{...xs}</Card>;", .JSX},
		{"import type { T } from \"t\"; export type U = T; export enum E { A = 1 }", .TS},
		// Errors and recovery allocate diagnostics.
		{"import { from \"m\"; let = ;", .JS},
	}

	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)

	for parse_case in cases {
		// Scoped so that the tracking allocator is the context allocator for
		// the whole life of the job and for nothing else.
		{
			context.allocator = mem.tracking_allocator(&tracker)
			job: kessel.ParseJob
			config := kessel.ParseConfig{lang_override = parse_case.lang}
			opened := kessel.parse_job_open_inline(&job, parse_case.source, config, "memory")
			if opened {
				kessel.parse_job_run(&job)
				kessel.parse_job_close(&job)
			}
		}
		testing.expectf(
			t, tracker.current_memory_allocated == 0,
			"%q: %d bytes still allocated after parse_job_close",
			parse_case.source, tracker.current_memory_allocated,
		)
		// Start the next case from zero so one leak is reported once.
		mem.tracking_allocator_clear(&tracker)
	}
}
