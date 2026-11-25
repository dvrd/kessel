#+build wasi

package playground

import "base:runtime"
import "core:encoding/json"
import "core:mem"
import mvirtual "core:mem/virtual"
import kessel "../../src"

// Each instance owns one input, one options block and one result. The JS
// binding copies or decodes the result before the next call, which releases
// the previous buffer.
INPUT_LIMIT :: 256 * 1024
// Tool options are a small JSON document or a list of lint rule settings.
OPTIONS_LIMIT :: 16 * 1024
LANGUAGE_COUNT :: 4
input: [INPUT_LIMIT]u8
options: [OPTIONS_LIMIT]u8
output: []u8
main :: proc() {}

#assert(INPUT_LIMIT <= int(max(i32)))
#assert(OPTIONS_LIMIT < INPUT_LIMIT)

@(export)
input_address :: proc "c" () -> uintptr { return uintptr(&input[0]) }

@(export)
input_limit :: proc "c" () -> u32 { return INPUT_LIMIT }

@(export)
options_address :: proc "c" () -> uintptr { return uintptr(&options[0]) }

@(export)
options_limit :: proc "c" () -> u32 { return OPTIONS_LIMIT }

@(export)
output_address :: proc "c" () -> uintptr { return uintptr(raw_data(output)) }

// One parsed input. WASI has linear memory instead of a virtual memory
// reservation, so the parser and every later pass borrow a heap buffer that
// lives exactly as long as the session.
Session :: struct {
	buffer: []u8,
	arena:  mvirtual.Arena,
	job:    kessel.ParseJob,
}

// What the code-producing tools answer with. The field names match the
// native library's reply so both bindings decode the same document.
CodeDiagnostic :: struct {
	start, end: u32,
	message:    string,
}
CodeOutput :: struct {
	output: string,
	errors: []CodeDiagnostic,
}

LintDiagnostic :: struct {
	start, end:              u32,
	code, severity, message: string,
	// Plugin-qualified rule name; absent on parser diagnostics.
	rule:                    string `json:"rule,omitempty"`,
}
LintOutput :: struct {
	diagnostics: []LintDiagnostic,
}

ToolError :: struct {
	code, message: string,
	offset:        Maybe(u32),
}

request_valid :: proc(length, language, options_length: u32) -> bool {
	if length > INPUT_LIMIT { return false }
	if language >= LANGUAGE_COUNT { return false }
	if options_length > OPTIONS_LIMIT { return false }
	return true
}

// Parse the input in place. The session must not move afterwards: the job
// points at the session's arena.
session_open :: proc(
	session: ^Session,
	length, language: u32,
	config: kessel.ParseConfig,
) -> bool {
	assert(request_valid(length, language, 0))
	assert(session.buffer == nil)
	labels := [LANGUAGE_COUNT]string{"input.js", "input.jsx", "input.ts", "input.tsx"}
	source := input[:length]

	buffer, err := make([]u8, int(kessel.arena_reserve_for_source(len(source))))
	if err != nil { return false }
	if mvirtual.arena_init_buffer(&session.arena, buffer) != nil {
		delete(buffer)
		return false
	}
	session.buffer = buffer

	session.job = kessel.ParseJob{
		config = config, source_path = labels[language], source = {data = source},
		opened = true, arena_ptr = &session.arena,
		arena_alloc = mvirtual.arena_allocator(&session.arena),
	}
	kessel.parse_job_resolve(&session.job)
	kessel.parse_job_run(&session.job)
	return true
}

session_close :: proc(session: ^Session) {
	assert(session.buffer != nil)
	mvirtual.arena_destroy(&session.arena)
	delete(session.buffer)
	session.buffer = nil
}

// Publish `value` as the JSON result and return its length. Zero tells the
// binding that the module ran out of memory.
reply :: proc(value: any) -> u32 {
	assert(output == nil)
	output = json.marshal(value, allocator = context.allocator) or_else nil
	return u32(len(output))
}

reply_error :: proc(code, message: string, offset: Maybe(u32) = nil) -> u32 {
	return reply(ToolError{code, message, offset})
}

reply_parser_errors :: proc(job: ^kessel.ParseJob) -> u32 {
	assert(len(job.parser.errors) > 0)
	errors := make([]CodeDiagnostic, len(job.parser.errors), job.arena_alloc)
	for err, index in job.parser.errors { errors[index] = {err.start, err.end, err.message} }
	return reply(CodeOutput{errors = errors})
}

release_output :: proc() {
	delete(output)
	output = nil
}

@(export)
parse_source :: proc "c" (length, language, semantics: u32) -> u32 {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	release_output()
	if !request_valid(length, language, 0) || semantics > 1 { return 0 }
	session: Session
	if !session_open(&session, length, language, {}) { return 0 }
	defer session_close(&session)
	job := &session.job
	if semantics == 1 { kessel.checker_run_for_job(job) }

	emitter: kessel.Emitter
	config := kessel.EmitConfig{
		compact = true, loc = true, range = true, error_format = "kessel",
		ts_shape = job.lang == .TS || job.lang == .TSX,
	}
	kessel.emitter_init(&emitter, config, int(length), context.allocator)
	defer kessel.emitter_destroy(&emitter)
	kessel.emit_job_json(&emitter, job)
	// The whole buffer changes hands so that release_output frees all of it.
	output = emitter.buf
	emitter.buf = nil
	assert(emitter.pos > 0)
	assert(emitter.pos <= len(output))
	return u32(emitter.pos)
}

@(export)
format_source :: proc "c" (
	length, language: u32,
	width, tab_width: i32,
	tabs, single, spacing, trailing, end_of_line: u32,
) -> u32 {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	release_output()
	endings := [4]string{"lf", "crlf", "cr", "auto"}
	if !request_valid(length, language, 0) { return 0 }
	if end_of_line >= len(endings) || max(tabs, single, spacing, trailing) > 1 { return 0 }
	settings := kessel.FormatOptions{
		print_width = width, tab_width = tab_width, end_of_line = endings[end_of_line],
		use_tabs = tabs == 1, single_quote = single == 1, bracket_spacing = spacing == 1,
		trailing_comma = trailing == 1,
	}
	if !kessel.format_options_valid(settings) { return 0 }
	session: Session
	if !session_open(&session, length, language, {}) { return 0 }
	defer session_close(&session)
	job := &session.job
	if len(job.parser.errors) > 0 {
		first := job.parser.errors[0]
		return reply_error("Invalid_Syntax", first.message, first.start)
	}
	return reply(kessel.format_program(job, settings))
}

// Lint with the rule settings in the options block: empty for the default
// rule set, otherwise the `name:level` lines or JSON object that
// kessel_lint_binary accepts. Parser diagnostics come first, as they do in
// the native bindings.
@(export)
lint_source :: proc "c" (length, language, options_length: u32) -> u32 {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	release_output()
	if !request_valid(length, language, options_length) { return 0 }
	overrides := make([dynamic]kessel.LintOverride, context.temp_allocator)
	if options_length > 0 {
		if !kessel.lint_parse_rules_text(string(options[:options_length]), &overrides) {
			return reply_error("Invalid_Request", "Invalid lint rule settings")
		}
	}
	session: Session
	config := kessel.lint_parse_config("input", {})
	if !session_open(&session, length, language, config) { return 0 }
	defer session_close(&session)
	job := &session.job

	linter := kessel.lint_run_for_job(job, {overrides = overrides[:]})
	count := len(job.parser.errors) + len(linter.diagnostics)
	diagnostics := make([dynamic]LintDiagnostic, 0, count, job.arena_alloc)
	for d in job.parser.errors {
		append(&diagnostics, LintDiagnostic{
			start = d.start, end = d.end, code = kessel.error_code_string(d.code),
			severity = kessel.severity_string(d.severity), message = d.message,
		})
	}
	for d in linter.diagnostics {
		append(&diagnostics, LintDiagnostic{
			start = d.start, end = d.end, code = kessel.lint_rule_code_string(d.lint_code),
			rule = kessel.lint_rule_qualified_name(d.lint_code, job.arena_alloc),
			severity = kessel.severity_string(d.severity), message = d.message,
		})
	}
	return reply(LintOutput{diagnostics[:]})
}

// Lower TypeScript and JSX to JavaScript. The options block holds the JSON
// form of kessel.TransformOptions. `define` is refused: its implementation
// reserves virtual memory, which this target does not have.
@(export)
transform_source :: proc "c" (length, language, options_length: u32) -> u32 {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	release_output()
	if !request_valid(length, language, options_length) { return 0 }
	settings: kessel.TransformOptions
	if options_length > 0 {
		text := options[:options_length]
		if json.unmarshal(text, &settings, .JSON, context.temp_allocator) != nil {
			return reply_error("Invalid_Request", "Could not decode transform options")
		}
	}
	if len(settings.define) != 0 || settings.source_map {
		return reply_error("Invalid_Request", "define and sourceMap are not available here")
	}
	session: Session
	if !session_open(&session, length, language, {preserve_parens = true}) { return 0 }
	defer session_close(&session)
	job := &session.job
	if len(job.parser.errors) != 0 { return reply_parser_errors(job) }

	cg: kessel.Codegen
	diagnostic := kessel.transform_generate(job, &cg, settings, nil)
	defer kessel.codegen_destroy(&cg, context.allocator)
	if diag, failed := diagnostic.?; failed {
		return reply(CodeOutput{errors = {{diag.loc.start, diag.loc.end, diag.what}}})
	}
	return reply(CodeOutput{output = string(cg.buf[:cg.pos])})
}

MinifyOptions :: struct {
	compress, mangle, mangle_names: bool,
}

// Minify with the JSON MinifyOptions in the options block.
@(export)
minify_source :: proc "c" (length, language, options_length: u32) -> u32 {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	release_output()
	if !request_valid(length, language, options_length) { return 0 }
	settings := MinifyOptions{compress = true, mangle = true}
	if options_length > 0 {
		text := options[:options_length]
		if json.unmarshal(text, &settings, .JSON, context.temp_allocator) != nil {
			return reply_error("Invalid_Request", "Could not decode minifier options")
		}
	}
	session: Session
	if !session_open(&session, length, language, {}) { return 0 }
	defer session_close(&session)
	job := &session.job
	if len(job.parser.errors) != 0 { return reply_parser_errors(job) }

	cg: kessel.Codegen
	kessel.codegen_print_job(job, &cg, {
		minified = true, compress = settings.compress, mangle = settings.mangle,
		mangle_names = settings.mangle_names,
	}, nil)
	defer kessel.codegen_destroy(&cg, context.allocator)
	return reply(CodeOutput{output = string(cg.buf[:cg.pos])})
}

// Emit the isolated declaration file of a TypeScript input.
@(export)
declaration_source :: proc "c" (length, language: u32) -> u32 {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	release_output()
	if !request_valid(length, language, 0) { return 0 }
	session: Session
	config := kessel.ParseConfig{preserve_parens = true, allow_legacy_module_names = true}
	if !session_open(&session, length, language, config) { return 0 }
	defer session_close(&session)

	// The emitter's working memory is unrelated to the size of the source, so
	// it grows on the heap instead of sharing the parser's fixed buffer.
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch, context.allocator, context.allocator)
	defer mem.dynamic_arena_destroy(&scratch)
	return reply(kessel.declarations_generate(&session.job, mem.dynamic_arena_allocator(&scratch)))
}
