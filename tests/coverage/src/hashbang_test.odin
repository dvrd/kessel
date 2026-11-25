// `Program.hashbang`: the `#!...` line as a field of the typed AST, and its
// encoding in the compact binary AST the npm package decodes.
//
// Method: parse inline sources as a library consumer does and read the
// field; then run the binary emitter on the same job and read the version
// from the buffer header, to pin that only programs with a hashbang move to
// wire version 9 while every other program keeps the version it had.
package coverage

import "core:testing"

import kessel "../../../src"

@(private = "file")
HashbangCase :: struct {
	source: string,
	value:  string,
	end:    u32,
}

@(test)
test_program_hashbang_field :: proc(t: ^testing.T) {
	cases := [?]HashbangCase{
		{"#!/usr/bin/env node\nx;", "/usr/bin/env node", 19},
		{"#!/usr/bin/env node", "/usr/bin/env node", 19},     // no line terminator
		{"#!node --flag\r\nx;", "node --flag", 13},           // CRLF
		{"#!a\u2028x;", "a", 3},                              // U+2028 ends it too
		{"#!\nx;", "", 2},                                    // empty hashbang
	}
	for hashbang_case in cases {
		job: kessel.ParseJob
		opened := kessel.parse_job_open_inline(&job, hashbang_case.source, {}, "hashbang.js")
		if !testing.expect(t, opened) { continue }
		defer kessel.parse_job_close(&job)
		kessel.parse_job_run(&job)
		testing.expect_value(t, len(job.parser.errors), 0)
		hashbang, present := job.program.hashbang.?
		if !testing.expectf(t, present, "%q: hashbang missing", hashbang_case.source) { continue }
		testing.expect_value(t, hashbang.value, hashbang_case.value)
		// The span covers `#!` and the text, not the line terminator.
		testing.expect_value(t, hashbang.loc, kessel.Loc{start = 0, end = hashbang_case.end})
	}
}

@(test)
test_program_without_hashbang :: proc(t: ^testing.T) {
	// `#!` anywhere but at offset 0 is not a hashbang; after a byte order
	// mark it is an error, as in the specification and in OXC.
	sources := [?]string{"x;", "", " #!/bin/sh\nx;", "x;\n#!/bin/sh", "\ufeff#!/bin/sh\nx;"}
	for source in sources {
		job: kessel.ParseJob
		opened := kessel.parse_job_open_inline(&job, source, {}, "plain.js")
		if !testing.expect(t, opened) { continue }
		defer kessel.parse_job_close(&job)
		kessel.parse_job_run(&job)
		_, present := job.program.hashbang.?
		testing.expectf(t, !present, "%q: unexpected hashbang", source)
	}
}

// Wire version stored at byte 4 of a finalized binary AST buffer.
@(private = "file")
binary_version :: proc(t: ^testing.T, source: string, label: string) -> u32 {
	job: kessel.ParseJob
	if !testing.expect(t, kessel.parse_job_open_inline(&job, source, {}, label)) { return 0 }
	defer kessel.parse_job_close(&job)
	kessel.parse_job_run(&job)

	emitter: kessel.BinaryEmitter
	ts_shape := kessel.allow_ts_mode(&job.parser)
	kessel.binary_emitter_init(&emitter, source, context.allocator, job.parser.allocator, ts_shape)
	defer kessel.binary_emitter_destroy(&emitter, context.allocator)
	kessel.bin_emit_program(&emitter, job.program)
	kessel.bin_emit_errors(&emitter, job.parser.errors[:])
	kessel.bin_emit_finalize(&emitter)

	buffer := emitter.buf[:emitter.pos]
	if !testing.expect(t, len(buffer) >= kessel.BINARY_HEADER_SIZE) { return 0 }
	return u32(buffer[4]) | u32(buffer[5]) << 8 | u32(buffer[6]) << 16 | u32(buffer[7]) << 24
}

@(test)
test_binary_version_moves_only_with_a_hashbang :: proc(t: ^testing.T) {
	// Without a hashbang the version is what it was before v9 existed, so a
	// reader that predates v9 still decodes these buffers.
	plain_js := binary_version(t, "x;", "a.js")
	plain_ts := binary_version(t, "let x: T;", "a.ts")
	testing.expect_value(t, plain_js, kessel.BINARY_VERSION_DIAGNOSTICS)
	testing.expect_value(t, plain_ts, kessel.BINARY_VERSION_SOURCE_SHAPE)
	// With one, JavaScript and TypeScript alike are v9.
	hashbang_js := binary_version(t, "#!/bin/sh\nx;", "a.js")
	hashbang_ts := binary_version(t, "#!/bin/sh\nlet x: T;", "a.ts")
	testing.expect_value(t, hashbang_js, kessel.BINARY_VERSION_HASHBANG)
	testing.expect_value(t, hashbang_ts, kessel.BINARY_VERSION_HASHBANG)
}
