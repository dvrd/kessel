#+build !wasi

package kessel

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import mvirtual "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"

KesselToolError :: struct {
	code: string,
	message: string,
	offset: Maybe(u32),
}

@(private="file")
kessel_tool_json :: proc(value: any) -> KesselParseResult {
	builder := strings.builder_make(context.allocator)
	if err := json.marshal_to_builder(&builder, value, {use_enum_names = true}); err != nil {
		strings.builder_destroy(&builder)
		return {}
	}
	if u64(len(builder.buf)) > u64(max(i32)) {
		strings.builder_destroy(&builder)
		return {}
	}
	result, err := new(LibResult, context.allocator)
	if err != nil {
		strings.builder_destroy(&builder)
		return {}
	}
	result.buf = builder.buf
	result.buf_ptr = raw_data(builder.buf[:])
	result.buf_len = len(builder.buf)
	return {handle = rawptr(result), buf_ptr = result.buf_ptr, buf_len = i32(result.buf_len)}
}

@(private="file")
kessel_tool_error :: proc(code: any, message: string, offset: Maybe(u32) = nil) -> KesselParseResult {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return kessel_tool_json(KesselToolError{fmt.tprintf("%v", code), message, offset})
}

kessel_tool_input :: proc(pointer: [^]u8, length: i32) -> (string, bool) {
	if length < 0 { return "", false }
	if length == 0 { return "", true }
	if pointer == nil { return "", false }
	return string(pointer[:length]), true
}

@(export, link_name="kessel_module_lex")
kessel_module_lex :: proc "c" (source_ptr: [^]u8, source_len: i32) -> KesselParseResult {
	context = runtime.default_context()
	source, ok := kessel_tool_input(source_ptr, source_len)
	if !ok { return {} }
	value, err := module_lex_dependencies(source, context.allocator)
	if err != .None {
		return kessel_tool_error(err, "Could not scan module dependencies")
	}
	defer module_lex_destroy(&value)
	return kessel_tool_json(value)
}

@(export, link_name="kessel_regex_ast")
kessel_regex_ast :: proc "c" (
	pattern_ptr: [^]u8,
	pattern_len: i32,
	flags_ptr: [^]u8,
	flags_len: i32,
) -> KesselParseResult {
	context = runtime.default_context()
	pattern, pattern_ok := kessel_tool_input(pattern_ptr, pattern_len)
	flags, flags_ok := kessel_tool_input(flags_ptr, flags_len)
	if !pattern_ok || !flags_ok { return {} }
	value, err := regex_parse_ast(pattern, flags, context.allocator)
	if err.kind != .None {
		return kessel_tool_error(err.kind, err.message, err.offset)
	}
	defer regex_ast_destroy(&value)
	return kessel_tool_json(value)
}

KesselResolveRequest :: struct {
	specifier, importer: string,
	require_mode: bool,
	options: ModuleResolveOptions,
}

@(export, link_name="kessel_resolve_module")
kessel_resolve_module :: proc "c" (request_ptr: [^]u8, request_len: i32) -> KesselParseResult {
	context = runtime.default_context()
	input, ok := kessel_tool_input(request_ptr, request_len)
	if !ok { return {} }

	scratch: mvirtual.Arena
	if err := mvirtual.arena_init_growing(&scratch); err != nil { return {} }
	defer mvirtual.arena_destroy(&scratch)
	temp := mvirtual.arena_allocator(&scratch)
	request: KesselResolveRequest
	if err := json.unmarshal_string(input, &request, .JSON, temp); err != nil {
		return kessel_tool_error("Invalid_Request", "Could not decode resolver options")
	}
	request.options.mode = .Require if request.require_mode else .Import
	result, err := module_resolve(request.specifier, request.importer, request.options, temp)
	if err != .None { return kessel_tool_error(err, "Could not resolve module") }
	return kessel_tool_json(result)
}

KesselCodeDiagnostic :: struct {
	start, end: u32,
	message: string,
}

KesselCodeOutput :: struct {
	output, map_json: string,
	errors: []KesselCodeDiagnostic,
}

@(export, link_name="kessel_format")
kessel_format :: proc "c" (
	filename_ptr: [^]u8, filename_len: i32,
	source_ptr: [^]u8, source_len: i32,
	options_ptr: [^]u8, options_len: i32,
) -> KesselParseResult {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	filename, file_ok := kessel_tool_input(filename_ptr, filename_len)
	source, source_ok := kessel_tool_input(source_ptr, source_len)
	settings, settings_ok := kessel_tool_input(options_ptr, options_len)
	if !file_ok || !source_ok || !settings_ok { return {} }
	job: ParseJob
	if !parse_job_open_inline(&job, source, {}, filename) { return {} }
	defer parse_job_close(&job)
	options := format_options_default()
	if err := json.unmarshal_string(settings, &options, .JSON, job.arena_alloc); err != nil || !format_options_valid(options) {
		return kessel_tool_error("Invalid_Request", "Invalid formatter options")
	}
	parse_job_run(&job)
	if len(job.parser.errors) > 0 {
		err := job.parser.errors[0]
		return kessel_tool_error("Invalid_Syntax", err.message, err.start)
	}
	return kessel_tool_json(format_program(&job, options))
}

@(export, link_name="kessel_isolated_declaration")
kessel_isolated_declaration :: proc "c" (filename_ptr: [^]u8, filename_len: i32, source_ptr: [^]u8, source_len: i32) -> KesselParseResult {
	context = runtime.default_context()
	filename, file_ok := kessel_tool_input(filename_ptr, filename_len)
	source, source_ok := kessel_tool_input(source_ptr, source_len)
	if !file_ok || !source_ok { return {} }
	job: ParseJob
	if !parse_job_open_inline(&job, source, {preserve_parens = true, allow_legacy_module_names = true}, filename) { return {} }
	defer parse_job_close(&job)
	parse_job_run(&job)
	scratch: mvirtual.Arena
	if mvirtual.arena_init_growing(&scratch) != nil { return {} }
	defer mvirtual.arena_destroy(&scratch)
	return kessel_tool_json(declarations_generate(&job, mvirtual.arena_allocator(&scratch)))
}

@(export, link_name="kessel_transform")
kessel_transform :: proc "c" (
	filename_ptr: [^]u8, filename_len: i32,
	source_ptr: [^]u8, source_len: i32,
	options_ptr: [^]u8, options_len: i32,
) -> KesselParseResult {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	filename, file_ok := kessel_tool_input(filename_ptr, filename_len)
	source, source_ok := kessel_tool_input(source_ptr, source_len)
	settings, settings_ok := kessel_tool_input(options_ptr, options_len)
	if !file_ok || !source_ok || !settings_ok { return {} }
	job: ParseJob
	if !parse_job_open_inline(&job, source, {preserve_parens = true}, filename) { return {} }
	defer parse_job_close(&job)
	options: TransformOptions
	if err := json.unmarshal_string(settings, &options, .JSON, context.temp_allocator); err != nil {
		return kessel_tool_error("Invalid_Request", "Could not decode transform options")
	}
	parse_job_run(&job)
	if len(job.parser.errors) != 0 { return kessel_tool_parser_errors(&job) }
	cg: Codegen
	sm: SourceMap
	map_out := &sm if options.source_map else nil
	diagnostic := transform_generate(&job, &cg, options, map_out)
	defer codegen_destroy(&cg, context.allocator)
	defer if map_out != nil { sourcemap_destroy(map_out) }
	if diag, failed := diagnostic.?; failed {
		return kessel_tool_json(KesselCodeOutput{errors = {{diag.loc.start, diag.loc.end, diag.what}}})
	}
	return kessel_tool_generated_code(&cg, map_out, filename)
}

@(export, link_name="kessel_minify")
kessel_minify :: proc "c" (
	filename_ptr: [^]u8, filename_len: i32,
	source_ptr: [^]u8, source_len: i32,
	options_ptr: [^]u8, options_len: i32,
) -> KesselParseResult {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	filename, file_ok := kessel_tool_input(filename_ptr, filename_len)
	source, source_ok := kessel_tool_input(source_ptr, source_len)
	settings, settings_ok := kessel_tool_input(options_ptr, options_len)
	if !file_ok || !source_ok || !settings_ok { return {} }
	options: struct { compress, mangle, mangle_names, source_map: bool, pragma, pragma_frag: string }
	if err := json.unmarshal_string(settings, &options, .JSON, context.temp_allocator); err != nil {
		return kessel_tool_error("Invalid_Request", "Could not decode minifier options")
	}
	for value in ([2]string{options.pragma, options.pragma_frag}) {
		if value != "" && !jsx_pragma_valid(value) { return kessel_tool_error("Invalid_Request", "Invalid JSX pragma binding") }
	}
	job: ParseJob
	if !parse_job_open_inline(&job, source, {}, filename) { return {} }
	defer parse_job_close(&job)
	parse_job_run(&job)
	if len(job.parser.errors) != 0 { return kessel_tool_parser_errors(&job) }
	cg: Codegen
	sm: SourceMap
	map_out := &sm if options.source_map else nil
	codegen_print_job(&job, &cg, {minified = true, compress = options.compress, mangle = options.mangle,
		mangle_names = options.mangle_names,
		pragma = options.pragma, pragma_frag = options.pragma_frag}, map_out)
	defer codegen_destroy(&cg, context.allocator)
	defer if map_out != nil { sourcemap_destroy(map_out) }
	return kessel_tool_generated_code(&cg, map_out, filename)
}

kessel_tool_parser_errors :: proc(job: ^ParseJob) -> KesselParseResult {
	output := KesselCodeOutput{errors = make([]KesselCodeDiagnostic, len(job.parser.errors), job.arena_alloc)}
	for err, i in job.parser.errors { output.errors[i] = {err.start, err.end, err.message} }
	return kessel_tool_json(output)
}

kessel_tool_generated_code :: proc(cg: ^Codegen, sm: ^SourceMap, filename: string) -> KesselParseResult {
	output := KesselCodeOutput{output = string(cg.buf[:cg.pos])}
	if sm != nil { output.map_json = sourcemap_to_json(sm, filename, filename, output.output, true) }
	defer if output.map_json != "" { delete(output.map_json) }
	return kessel_tool_json(output)
}

@(export, link_name="kessel_lint_fix")
kessel_lint_fix :: proc "c" (
	filename_ptr: [^]u8, filename_len: i32,
	source_ptr: [^]u8, source_len: i32,
	options_ptr: [^]u8, options_len: i32,
) -> KesselParseResult {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	filename, file_ok := kessel_tool_input(filename_ptr, filename_len)
	source, source_ok := kessel_tool_input(source_ptr, source_len)
	settings, settings_ok := kessel_tool_input(options_ptr, options_len)
	if !file_ok || !source_ok || !settings_ok { return {} }
	options: KesselLintOptions
	if err := json.unmarshal_string(settings, &options, .JSON, context.temp_allocator); err != nil {
		return kessel_tool_error("Invalid_Request", "Invalid lint fix options")
	}
	kinds := kessel_lint_fix_kinds(&options)
	if kinds == {} { return kessel_tool_error("Invalid_Request", "Missing lint fix mode") }
	overrides := make([dynamic]LintOverride, context.temp_allocator)
	if !lint_parse_rules_text(options.rules, &overrides) {
		return kessel_tool_error("Invalid_Request", "Invalid lint rule settings")
	}
	config := ParseConfig{lang_override = kessel_lang_from_i32(options.lang)}
	result, ok := lint_fix_source(source, filename, config, {overrides=overrides[:]}, kinds)
	if !ok { return kessel_tool_error("Invalid_Edit", "Could not produce valid lint output") }
	defer delete(result.output)
	response: struct {output: Maybe(string)}
	if result.changed { response.output = string(result.output) }
	return kessel_tool_json(response)
}

KesselLintOptions :: struct {
	lang: i32,
	fix, suggestions, dangerous, include_fixes, include_suggestions, include_suppressions: bool,
	rules, workspace: string,
}

kessel_lint_fix_kinds :: proc(options: ^KesselLintOptions) -> LintFixKinds {
	kinds: LintFixKinds
	if options.fix { kinds += {.Fix} }
	if options.suggestions { kinds += {.Suggestion} }
	if options.dangerous { kinds += {.Dangerous} }
	if kinds == {.Dangerous} { kinds += {.Fix} }
	return kinds
}

KesselDiagnosticFix :: struct { start, end: u32, text: string }
KesselDiagnosticSuggestion :: struct { start, end: u32, text, title: string }
KesselSuppression :: struct {
	rule: string,
	line: Maybe(KesselDiagnosticFix) `json:"line,omitempty"`,
}
KesselProjectDiagnostic :: struct {
	start, end: u32,
	code, severity, message: string,
	suppression: Maybe(KesselSuppression) `json:"suppression,omitempty"`,
	fix: Maybe(KesselDiagnosticFix) `json:"fix,omitempty"`,
	suggestion: Maybe(KesselDiagnosticSuggestion) `json:"suggestion,omitempty"`,
	related: []LintDependencyNote `json:"related,omitempty"`,
}
KesselProjectLint :: struct { diagnostics: []KesselProjectDiagnostic, output: Maybe(string) }

kessel_lint_project_rules :: proc(options: ^KesselLintOptions, file: string, rules: ^[dynamic]LintOverride, scratch: ^mvirtual.Arena) -> (settings: LintSettings, ignored, ok: bool) {
	context.allocator = mvirtual.arena_allocator(scratch)
	if options.workspace == "" {
		if !lint_parse_rules_text(options.rules, rules) { return {}, false, false }
		return {overrides=rules[:]}, false, true
	}
	root, err := filepath.abs(options.workspace, context.allocator)
	if err != nil || !os.is_dir(root) { return {}, false, false }
	store: LintConfigStore
	if !lint_config_store_open(&store, root, "", true) { return {}, false, false }
	overrides := make([dynamic]LintOverride)
	if !lint_parse_rules_text(options.rules, &overrides) { return {}, false, false }
	return lint_config_select(&store, file, overrides[:], rules)
}

@(export, link_name="kessel_lint_project")
kessel_lint_project :: proc "c" (
	filename_ptr: [^]u8, filename_len: i32, source_ptr: [^]u8, source_len: i32,
	options_ptr: [^]u8, options_len: i32,
) -> KesselParseResult {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	filename, file_ok := kessel_tool_input(filename_ptr, filename_len)
	source, source_ok := kessel_tool_input(source_ptr, source_len)
	settings, settings_ok := kessel_tool_input(options_ptr, options_len)
	if !file_ok || !source_ok || !settings_ok { return {} }
	options: KesselLintOptions
	if err := json.unmarshal_string(settings, &options, .JSON, context.temp_allocator); err != nil {
		return kessel_tool_error("Invalid_Request", "Could not decode project lint options")
	}
	if options.workspace != "" && (!filepath.is_abs(options.workspace) || !filepath.is_abs(filename)) {
		return kessel_tool_error("Invalid_Request", "Project lint requires absolute paths")
	}
	scratch: mvirtual.Arena
	if err := mvirtual.arena_init_growing(&scratch); err != nil { return {} }
	defer mvirtual.arena_destroy(&scratch)
	rules := make([dynamic]LintOverride, mvirtual.arena_allocator(&scratch))
	lint_settings, ignored, ok := kessel_lint_project_rules(&options, filename, &rules, &scratch)
	if !ok { return kessel_tool_error("Invalid_Config", "Could not load project lint configuration") }
	response: KesselProjectLint
	if ignored { return kessel_tool_json(response) }
	config := ParseConfig{lang_override = kessel_lang_from_i32(options.lang)}
	fixed: LintFixResult
	defer delete(fixed.output)
	if kinds := kessel_lint_fix_kinds(&options); kinds != {} {
		fixed, ok = lint_fix_source(source, filename, config, lint_settings, kinds)
		if !ok { return kessel_tool_error("Invalid_Edit", "Could not produce valid lint output") }
		if fixed.changed { source = string(fixed.output); response.output = source }
	}
	job: ParseJob
	if !parse_job_open_inline(&job, source, lint_parse_config(filename, config), filename) { return {} }
	defer parse_job_close(&job)
	parse_job_run(&job)
	response.diagnostics = kessel_project_diagnostics(&job, lint_settings, &options)
	return kessel_tool_json(response)
}

kessel_project_diagnostics :: proc(job: ^ParseJob, settings: LintSettings, options: ^KesselLintOptions) -> []KesselProjectDiagnostic {
	kinds: LintFixKinds
	if options.include_fixes && len(job.parser.errors) == 0 { kinds = {.Fix} }
	suppression_edits := options.include_suppressions && len(job.parser.errors) == 0
	suggest_edits := options.include_suggestions && len(job.parser.errors) == 0
	linter := lint_run_for_job(job, settings, kinds, suppression_edits, suggest_edits)
	anchors: []u32
	if suppression_edits && len(linter.diagnostics) > 0 {
		if job.lexer.num_lines == 0 { build_line_table(&job.lexer) }
		anchors = lint_suppression_line_anchors(&linter, job.lexer.line_offsets)
	}
	diagnostics := kessel_lint_diagnostics(job, &linter)
	result := make([]KesselProjectDiagnostic, len(diagnostics), job.arena_alloc)
	for d, i in diagnostics {
		code := lint_rule_code_string(d.lint_code) if d.lint_code != .None else error_code_string(d.code)
		result[i] = { start=d.start, end=d.end, code=code, severity=severity_string(d.severity), message=d.message }
		if d.lint_code == .L4108_ExhaustiveDeps {
			if notes, ok := linter.dependency_notes[{d.start,d.end}]; ok && notes.message == d.message {
				result[i].related = notes.uses
			}
		}
		if suppression_edits && d.lint_code != .None && d.lint_code != .L9001_UnusedDirective {
			line := lint_offset_to_line(job.lexer.line_offsets, d.start)
			result[i].suppression = kessel_project_suppression(anchors, line, d.lint_code)
		}
		key := LintFixKey{d.lint_code, {d.start, d.end}}
		if choice, ok := linter.suggestions[{key, d.message}]; ok {
			edit := choice.edit
			result[i].suggestion = {edit.span.start, edit.span.end, edit.replacement, choice.title}
		}
		if edit, ok := linter.fixes[key]; ok {
			assert(edit.span.start < edit.span.end)
			assert(int(edit.span.end) <= len(linter.source))
			result[i].fix = {edit.span.start, edit.span.end, edit.replacement}
		}
	}
	return result
}

kessel_project_suppression :: proc(anchors: []u32, line: int, rule: LintRule) -> KesselSuppression {
	assert(line >= 0)
	assert(line < len(anchors))
	anchor := anchors[line]
	directive := "disable-line"
	if anchor == 0 && line > 0 {
		anchor = anchors[line-1]
		directive = "disable-next-line"
	}
	result := KesselSuppression{rule=lint_rule_info(rule).name}
	if anchor != 0 {
		result.line = {anchor-1, anchor-1, fmt.tprintf(" /* oxlint-%s %s */", directive, result.rule)}
	}
	return result
}
