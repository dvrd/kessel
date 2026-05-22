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

	// Free previous result if any
	if lib_last_result != nil {
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

	// Parse
	job: ParseJob
	if !parse_job_open_inline(&job, source, config, "lib") {
		return nil, 0
	}
	defer parse_job_close(&job)
	parse_job_run(&job)

	// Emit binary
	be: BinaryEmitter
	binary_emitter_init(&be, source, context.allocator)
	bin_emit_program(&be, job.program)
	bin_emit_finalize(&be)

	// Store result
	result := new(LibResult, context.allocator)
	result.buf = be.buf
	result.buf_ptr = raw_data(be.buf[:])
	result.buf_len = len(be.buf)
	lib_last_result = result

	// Don't destroy be — the buf is now owned by result
	delete(be.strings)
	delete(be.string_map)

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
