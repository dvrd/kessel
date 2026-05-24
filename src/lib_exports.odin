package kessel

// ============================================================================
// Shared library exports — C-compatible API for embedding kessel.
//
// Build: odin build src -build-mode:shared -out:libkessel.dylib -o:speed -no-bounds-check
//
// Exports:
//   kessel_parse_binary(src, src_len, lang) -> KesselParseResult{handle, buf_ptr, buf_len}
//   kessel_free_result(handle)
//
// The returned buffer is the compact binary AST (same format as --binary).
// Caller passes it to the JS binary-reader.js for decoding.
//
// THREADING MODEL — every call is fully self-contained:
//   * No thread-local state, no module-global state.
//   * `kessel_parse_binary` may run on any thread (e.g. a libuv worker
//     thread when invoked via koffi's .async() from the npm package's
//     parseAsync).
//   * `kessel_free_result(handle)` may run on any thread, INCLUDING a
//     different thread than the one that produced `handle` — the
//     allocation lives on the C heap (`runtime.heap_allocator`), which
//     is process-global and thread-safe.
//   * Concurrent calls only touch read-only data (the lookup tables
//     populated by `@(init)` procs at library load).
// ============================================================================

import "base:runtime"

// Owning handle. Holds the binary buffer alive until the caller passes
// its rawptr address back to kessel_free_result. Embedded inside the
// allocation rather than referenced by a TLS slot so that parse and free
// can cross thread boundaries (required for the npm parseAsync flow,
// which runs the parse on a libuv worker and frees from the main
// thread).
LibResult :: struct {
	buf:     [dynamic]u8,
	buf_ptr: [^]u8,
	buf_len: int,
}

// Wire-shaped return record. Layout intentionally matches the koffi
// `koffi.struct('KesselParseResult', ...)` declaration on the JS side:
//   handle   void*    8 bytes
//   buf_ptr  void*    8 bytes
//   buf_len  int32    4 bytes  (+ 4 bytes tail padding for natural alignment)
// Total: 24 bytes.
//
// On x86_64 SysV (Linux / macOS) the struct exceeds two eightbytes, so
// the ABI returns it via a hidden out-pointer first argument. On AArch64
// AAPCS it travels in x0/x1/x2. On Windows x64 it goes via a hidden
// out-pointer for any struct > 8 bytes. Odin's C-ABI lowering and koffi's
// struct-return decoder agree on all three, so callers see a normal
// struct value either way.
KesselParseResult :: struct {
	handle:  rawptr,
	buf_ptr: [^]u8,
	buf_len: i32,
}

@(export, link_name="kessel_parse_binary")
kessel_parse_binary :: proc "c" (
	source_ptr: [^]u8,
	source_len: i32,
	lang: i32,         // 0=JS, 1=JSX, 2=TS, 3=TSX
) -> KesselParseResult {
	context = runtime.default_context()

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
		return KesselParseResult{handle = nil, buf_ptr = nil, buf_len = 0}
	}
	defer parse_job_close(&job)
	parse_job_run(&job)

	// Emit binary. Errors are written between the node stream and the
	// string table so the JS decoder can surface real parse diagnostics
	// instead of always seeing an empty errors[] array.
	be: BinaryEmitter
	binary_emitter_init(&be, source, context.allocator)
	bin_emit_program(&be, job.program)
	bin_emit_errors(&be, job.parser.errors[:])
	bin_emit_finalize(&be)

	// Heap-allocate the handle so it survives past the function return
	// regardless of which thread eventually frees it. Both allocations
	// (the LibResult container and the [dynamic]u8 buffer) live on the
	// process-global heap (runtime.heap_allocator).
	result := new(LibResult, context.allocator)
	result.buf = be.buf
	result.buf_ptr = raw_data(be.buf[:])
	result.buf_len = be.pos

	// Strings table backing for the emitter is local; the buf was moved
	// into `result` above, so only the auxiliary collections need a free.
	delete(be.strings)
	delete(be.string_map)

	return KesselParseResult{
		handle  = rawptr(result),
		buf_ptr = result.buf_ptr,
		buf_len = i32(result.buf_len),
	}
}

@(export, link_name="kessel_free_result")
kessel_free_result :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	if handle == nil { return }
	result := cast(^LibResult)handle
	delete(result.buf)
	free(result)
}
