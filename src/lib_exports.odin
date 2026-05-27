package kessel

// ============================================================================
// Shared library exports — C-compatible API for embedding kessel.
//
// Build: odin build src -build-mode:shared -out:libkessel.dylib -o:speed -no-bounds-check
//
// Exports:
//   kessel_parse_binary(src, src_len, lang) -> KesselParseResult{handle, buf_ptr, buf_len}
//   kessel_parse_binary_v2(src, src_len, filename, filename_len, options...) -> KesselParseResult
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
import "core:mem"

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

@(private="file")
kessel_lang_from_i32 :: proc(lang: i32) -> Maybe(Lang) {
	switch lang {
	case 0: return .JS
	case 1: return .JSX
	case 2: return .TS
	case 3: return .TSX
	case:   return nil
	}
}

@(private="file")
kessel_source_type_from_i32 :: proc(source_type: i32) -> Maybe(SourceType) {
	switch source_type {
	case 0: return .Script
	case 1: return .Module
	case:   return nil
	}
}

@(private="file")
kessel_bool_from_i32 :: #force_inline proc(v: i32) -> bool {
	return v != 0
}

@(private="file")
kessel_maybe_bool_from_i32 :: proc(v: i32) -> Maybe(bool) {
	switch v {
	case 0: return false
	case 1: return true
	case:   return nil
	}
}

@(private="file")
kessel_parse_binary_with_config :: proc(source: string, label: string, config: ParseConfig, show_semantic_errors: bool) -> KesselParseResult {
	context = runtime.default_context()

	job: ParseJob
	if !parse_job_open_inline(&job, source, config, label) {
		return KesselParseResult{handle = nil, buf_ptr = nil, buf_len = 0}
	}
	defer parse_job_close(&job)
	parse_job_run(&job)
	if show_semantic_errors {
		checker_run_for_job(&job)
	}

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

@(export, link_name="kessel_parse_binary")
kessel_parse_binary :: proc "c" (
	source_ptr: [^]u8,
	source_len: i32,
	lang: i32,         // 0=JS, 1=JSX, 2=TS, 3=TSX
) -> KesselParseResult {
	context = runtime.default_context()

	source := string(source_ptr[:source_len])

	config := ParseConfig{
		lang_override = kessel_lang_from_i32(lang),
		ast_only      = true,
	}

	return kessel_parse_binary_with_config(source, "lib", config, false)
}

@(export, link_name="kessel_parse_binary_v2")
kessel_parse_binary_v2 :: proc "c" (
	source_ptr: [^]u8,
	source_len: i32,
	filename_ptr: [^]u8,
	filename_len: i32,
	options_version: i32,                 // currently 1; higher versions are backward-compatible prefixes
	lang: i32,                            // -1=path detect, 0=JS, 1=JSX, 2=TS, 3=TSX
	source_type: i32,                     // -1=unambiguous, 0=script, 1=module
	strict_source_type: i32,
	force_strict: i32,
	preserve_parens: i32,
	ast_only: i32,
	show_semantic_errors: i32,
	source_is_dts: i32,                   // -1=path detect, 0=false, 1=true
	is_commonjs: i32,                     // -1=path detect, 0=false, 1=true
	disallow_ambiguous_jsx_like: i32,
) -> KesselParseResult {
	context = runtime.default_context()

	_ = options_version

	source := string(source_ptr[:source_len])
	label := "lib"
	if filename_ptr != nil && filename_len > 0 {
		label = string(filename_ptr[:filename_len])
	}

	config := ParseConfig{
		lang_override                  = kessel_lang_from_i32(lang),
		source_type_override           = kessel_source_type_from_i32(source_type),
		strict_source_type             = kessel_bool_from_i32(strict_source_type),
		force_strict                   = kessel_bool_from_i32(force_strict),
		preserve_parens                = kessel_bool_from_i32(preserve_parens),
		ast_only                       = kessel_bool_from_i32(ast_only),
		source_is_dts_override         = kessel_maybe_bool_from_i32(source_is_dts),
		is_commonjs_override           = kessel_maybe_bool_from_i32(is_commonjs),
		disallow_ambiguous_jsx_like    = kessel_bool_from_i32(disallow_ambiguous_jsx_like),
	}

	return kessel_parse_binary_with_config(source, label, config, kessel_bool_from_i32(show_semantic_errors))
}

@(export, link_name="kessel_free_result")
kessel_free_result :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	if handle == nil { return }
	result := cast(^LibResult)handle
	delete(result.buf)
	free(result)
}

// ============================================================================
// Codegen FFI — source-to-source with optional source map.
// ============================================================================
//
// Mirrors `kessel codegen` on the CLI. Takes source text, parses it,
// runs codegen, optionally records a v3 source map, returns up to two
// owned byte buffers (generated code + map JSON) plus a single handle
// for the JS caller to pass back to kessel_free_codegen_result.
//
// JS wire layout (struct KesselCodegenResult, 48 bytes):
//   handle    void*    8
//   code_ptr  void*    8
//   code_len  int32    4 (+ 4 padding)
//   map_ptr   void*    8
//   map_len   int32    4 (+ 4 padding)
//   ok        int32    4 (+ 4 padding)  — 0 on parse failure, code/map empty.

LibCodegenResult :: struct {
	code_buf: [dynamic]u8,
	map_buf:  [dynamic]u8,
}

KesselCodegenResult :: struct {
	handle:   rawptr,
	code_ptr: rawptr,
	code_len: i32,
	map_ptr:  rawptr,
	map_len:  i32,
	ok:       i32,
}

// kessel_codegen(
//   src_ptr, src_len           — source text
//   filename_ptr, filename_len — used in source map `file`/`sources`
//   lang                       — 0=js 1=jsx 2=ts 3=tsx (auto from name if -1)
//   source_type                — 0=script 1=module
//   minified                   — 0/1 — compact one-line output
//   want_sourcemap             — 0/1 — also build a map
// )
@(export, link_name="kessel_codegen")
kessel_codegen :: proc "c" (
	src_ptr: [^]u8, src_len: i32,
	filename_ptr: [^]u8, filename_len: i32,
	lang: i32,
	source_type: i32,
	minified: i32,
	want_sourcemap: i32,
) -> KesselCodegenResult {
	context = runtime.default_context()
	if src_ptr == nil || src_len < 0 { return KesselCodegenResult{} }
	source := string((cast([^]u8) src_ptr)[:src_len])
	filename := "input"
	if filename_ptr != nil && filename_len > 0 {
		filename = string((cast([^]u8) filename_ptr)[:filename_len])
	}

	// Parse setup: mirrors parse_job_run on a freshly built ParseConfig.
	cfg := ParseConfig{}
	if l, ok := kessel_lang_from_i32(lang).?; ok { cfg.lang_override = l }
	if st, ok := kessel_source_type_from_i32(source_type).?; ok { cfg.source_type_override = st }

	job: ParseJob
	if !parse_job_open_inline(&job, source, cfg, filename) {
		return KesselCodegenResult{}
	}
	defer parse_job_close(&job)
	parse_job_run(&job)
	if len(job.parser.errors) > 0 {
		return KesselCodegenResult{}
	}

	result := new(LibCodegenResult)

	// Codegen.
	cg_cfg := CodegenConfig{minified = kessel_bool_from_i32(minified), indent = "  "}
	cg: Codegen
	codegen_init(&cg, cg_cfg, len(source), context.allocator)
	defer codegen_destroy(&cg, context.allocator)

	sm: SourceMap
	want_sm := kessel_bool_from_i32(want_sourcemap)
	if want_sm {
		if job.parser.lexer.num_lines == 0 {
			build_line_table(job.parser.lexer)
		}
		line_offsets := job.parser.lexer.line_offsets[:job.parser.lexer.num_lines]
		sourcemap_init(&sm, source, line_offsets)
		codegen_enable_sourcemap(&cg, &sm)
	}
	defer if want_sm { sourcemap_destroy(&sm) }

	if job.lexer.has_hashbang {
		cg_str(&cg, "#!")
		cg_str(&cg, job.lexer.hashbang_value)
		cg_newline(&cg)
	}
	codegen_program(&cg, job.program)
	if !cg_cfg.minified && (cg.pos == 0 || cg.buf[cg.pos-1] != '\n') {
		cg_byte(&cg, '\n')
	}

	// Copy generated code into an owned dynamic buffer the LibResult
	// can free. We can't hand out cg.buf directly because codegen_destroy
	// frees it on the deferred path.
	result.code_buf = make([dynamic]u8, cg.pos)
	mem.copy(raw_data(result.code_buf), raw_data(cg.buf), cg.pos)

	if want_sm {
		map_json := sourcemap_to_json(
			&sm,
			filename,
			filename,
			string(cg.buf[:cg.pos]),
			true,
		)
		result.map_buf = make([dynamic]u8, len(map_json))
		mem.copy(raw_data(result.map_buf), raw_data(map_json), len(map_json))
		delete(map_json)
	}

	return KesselCodegenResult{
		handle   = rawptr(result),
		code_ptr = rawptr(raw_data(result.code_buf)),
		code_len = i32(len(result.code_buf)),
		map_ptr  = rawptr(raw_data(result.map_buf)) if len(result.map_buf) > 0 else nil,
		map_len  = i32(len(result.map_buf)),
		ok       = 1,
	}
}

@(export, link_name="kessel_free_codegen_result")
kessel_free_codegen_result :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	if handle == nil { return }
	result := cast(^LibCodegenResult)handle
	delete(result.code_buf)
	delete(result.map_buf)
	free(result)
}
