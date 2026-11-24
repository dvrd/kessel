#+build wasi

package playground

import "base:runtime"
import "core:encoding/json"
import mvirtual "core:mem/virtual"
import kessel "../../src"

// Each instance owns one input and one result. The JS binding copies or decodes
// the result before the next call, which releases the previous emitter buffer.
INPUT_LIMIT :: 256 * 1024
input: [INPUT_LIMIT]u8
output: []u8
main :: proc() {}

@(export)
input_address :: proc "c" () -> uintptr { return uintptr(&input[0]) }

@(export)
input_limit :: proc "c" () -> u32 { return INPUT_LIMIT }

@(export)
output_address :: proc "c" () -> uintptr { return uintptr(raw_data(output)) }

@(export)
parse_source :: proc "c" (length, language, semantics: u32) -> u32 {
	context = runtime.default_context()
	return run_source(length, language, semantics, nil)
}

@(export)
format_source :: proc "c" (length, language: u32, width, tab_width: i32, tabs, single, spacing, trailing, end_of_line: u32) -> u32 {
	context = runtime.default_context()
	endings := [4]string{"lf", "crlf", "cr", "auto"}
	if end_of_line >= len(endings) || max(tabs, single, spacing, trailing) > 1 { return 0 }
	options := kessel.FormatOptions{
		print_width = width, tab_width = tab_width, end_of_line = endings[end_of_line],
		use_tabs = tabs == 1, single_quote = single == 1, bracket_spacing = spacing == 1, trailing_comma = trailing == 1,
	}
	if !kessel.format_options_valid(options) { return 0 }
	return run_source(length, language, 0, &options)
}

run_source :: proc(length, language, semantics: u32, format: ^kessel.FormatOptions) -> u32 {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	delete(output)
	output = nil
	labels := [4]string{"input.js", "input.jsx", "input.ts", "input.tsx"}
	if length > INPUT_LIMIT || language >= len(labels) || semantics > 1 { return 0 }

	// WASI has linear memory instead of a virtual memory reservation. The
	// parser and checker borrow a buffer arena for the lifetime of this call.
	source := input[:length]
	buffer, err := make([]u8, int(kessel.arena_reserve_for_source(len(source))))
	if err != nil { return 0 }
	defer delete(buffer)
	arena: mvirtual.Arena
	if mvirtual.arena_init_buffer(&arena, buffer) != nil { return 0 }
	defer mvirtual.arena_destroy(&arena)
	job := kessel.ParseJob{
		source_path = labels[language], source = {data = source}, opened = true,
		arena_ptr = &arena, arena_alloc = mvirtual.arena_allocator(&arena),
	}
	kessel.parse_job_resolve(&job)
	kessel.parse_job_run(&job)
	if format != nil {
		if len(job.parser.errors) > 0 {
			first := job.parser.errors[0]
			error := struct {code, message: string, offset: u32}{"Invalid_Syntax", first.message, first.start}
			output = json.marshal(error, allocator = context.allocator) or_else nil
		} else {
			formatted := kessel.format_program(&job, format^)
			output = json.marshal(formatted, allocator = context.allocator) or_else nil
		}
		return u32(len(output))
	}
	if semantics == 1 { kessel.checker_run_for_job(&job) }

	emitter: kessel.Emitter
	config := kessel.EmitConfig{
		compact = true, loc = true, range = true, error_format = "kessel",
		ts_shape = job.lang == .TS || job.lang == .TSX,
	}
	kessel.emitter_init(&emitter, config, len(source), context.allocator)
	defer kessel.emitter_destroy(&emitter)
	kessel.emit_job_json(&emitter, &job)
	output = emitter.buf
	emitter.buf = nil
	assert(emitter.pos > 0)
	assert(emitter.pos <= len(output))
	return u32(emitter.pos)
}
