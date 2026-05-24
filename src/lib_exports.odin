package kessel

// ============================================================================
// Shared library exports — C-compatible API for embedding kessel.
//
// Build: odin build src -build-mode:shared -out:libkessel.dylib -o:speed -no-bounds-check
//
// Exports:
//   kessel_parse_binary(source, source_len, lang) → (buf_ptr, buf_len)
//   kessel_free_result(buf_ptr)
//
// The returned buffer is the compact binary AST (same format as --binary).
// Caller passes it to the JS binary-reader.js for decoding.
// ============================================================================

import "core:mem"
import mvirtual "core:mem/virtual"
import "base:runtime"
import "core:fmt"
import "core:os"

@(private="file")
dbg :: proc(msg: string) {
	fmt.fprintf(os.stderr, "[ODIN] %s\n", msg)
	os.flush(os.stderr)
}

// Result handle — keeps the arena alive until caller frees it.
LibResult :: struct {
	arena:    mvirtual.Arena,
	buf:      [dynamic]u8,
	buf_ptr:  [^]u8,
	buf_len:  int,
}

// Global results — simple pool. In production you'd use a handle map.
// For now, single-threaded usage with one outstanding result at a time.
@(thread_local)
lib_last_result: ^LibResult

@(export, link_name="kessel_parse_binary")
kessel_parse_binary :: proc "c" (
	source_ptr: [^]u8,
	source_len: i32,
	lang: i32,         // 0=JS, 1=JSX, 2=TS, 3=TSX
) -> (buf_ptr: [^]u8, buf_len: i32) {
	context = runtime.default_context()
	dbg(fmt.tprintf("enter source_len=%d lang=%d", source_len, lang))

	// Free previous result if any
	if lib_last_result != nil {
		dbg("freeing previous result")
		kessel_free_result_inner()
	}

	source := string(source_ptr[:source_len])

	// Determine language
	parse_lang: Lang
	switch lang {
	case 0: parse_lang = .JS
	case 1: parse_lang = .JSX
	case 2: parse_lang = .TS
	case 3: parse_lang = .TSX
	case:   parse_lang = .JSX
	}

	// Set up parse config
	config := ParseConfig{
		lang_override = parse_lang,
		ast_only = true,
	}

	dbg("opening parse job")
	// Parse
	job: ParseJob
	if !parse_job_open_inline(&job, source, config, "lib") {
		dbg("parse_job_open_inline failed")
		return nil, 0
	}
	defer parse_job_close(&job)
	dbg("running parse job")
	parse_job_run(&job)
	dbg(fmt.tprintf("parse done, errors=%d", len(job.parser.errors)))

	// Emit binary. Errors are written between the node stream and the
	// string table so the JS decoder can surface real parse diagnostics
	// instead of always seeing an empty errors[] array.
	be: BinaryEmitter
	binary_emitter_init(&be, source, context.allocator)
	dbg("emitter inited")
	bin_emit_program(&be, job.program)
	dbg(fmt.tprintf("emitted program, pos=%d", be.pos))
	bin_emit_errors(&be, job.parser.errors[:])
	dbg(fmt.tprintf("emitted errors, pos=%d errors_off=%d", be.pos, be.errors_off))
	bin_emit_finalize(&be)
	dbg(fmt.tprintf("finalized, pos=%d buf_len=%d", be.pos, len(be.buf)))

	// Store result
	result := new(LibResult, context.allocator)
	result.buf = be.buf
	result.buf_ptr = raw_data(be.buf[:])
	result.buf_len = be.pos
	lib_last_result = result
	dbg("result stored")

	// Don't destroy be — the buf is now owned by result
	delete(be.strings)
	delete(be.string_map)
	dbg("returning")

	return result.buf_ptr, i32(result.buf_len)
}

@(export, link_name="kessel_free_result")
kessel_free_result :: proc "c" () {
	context = runtime.default_context()
	kessel_free_result_inner()
}

@(private="file")
kessel_free_result_inner :: proc() {
	if lib_last_result == nil { return }
	delete(lib_last_result.buf)
	free(lib_last_result)
	lib_last_result = nil
}
