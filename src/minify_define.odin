package kessel

import "core:strings"

// `kessel minify --define NAME=EXPRESSION`. The transformer's define pass
// rewrites program text, so the definitions are applied to the source first
// and the result is parsed again. The compressor then sees the replacement
// values as ordinary literals and removes the branches they decide.
//
// Returns "" on success, with `defined` open on the rewritten source, or a
// message saying why the definitions could not be applied.
minify_define_job :: proc(
	job: ^ParseJob, defined: ^ParseJob, values: map[string]string,
) -> string {
	assert(len(values) != 0)
	assert(job.program != nil)
	if job.lang == .TS || job.lang == .TSX {
		return "--define is not supported for TypeScript input; run `kessel transform --define` first"
	}
	source := string(job.source.data)
	script := job.program.type == .Script
	cg: Codegen
	cfg := CodegenConfig{minified = true, strip_module = .Script if script else .ESM}
	codegen_init(&cg, cfg, source, context.allocator)
	defer codegen_destroy(&cg, context.allocator)
	cg_str(&cg, source)
	if diagnostic, failed := transform_define_apply(job, &cg, values).?; failed {
		return strings.clone(diagnostic.what)
	}
	// The second parse reads this text for as long as its tree is in use.
	text := strings.clone(string(cg.buf[:cg.pos]))
	config := job.config
	config.lang_override = job.lang
	config.source_type_override = SourceType.Script if script else SourceType.Module
	config.is_commonjs_override = job.is_commonjs
	if !parse_job_open_inline(defined, text, config, job.source_path) {
		return "cannot open the source after applying --define"
	}
	parse_job_run(defined)
	if len(defined.parser.errors) != 0 {
		parse_job_close(defined)
		return "the source is not valid after applying --define"
	}
	return ""
}

// Parse `--define NAME=EXPRESSION` or `--define=NAME=EXPRESSION` at `index`
// and advance past it. Returns false when the argument has no name or value.
cli_parse_define :: proc(args: []string, index: ^int, defines: ^map[string]string) -> bool {
	assert(index^ < len(args))
	argument := args[index^]
	if argument == "--define" {
		index^ += 1
		if index^ >= len(args) { return false }
		argument = args[index^]
	} else {
		argument = strings.trim_prefix(argument, "--define=")
	}
	separator := strings.index_byte(argument, '=')
	if separator <= 0 || separator + 1 == len(argument) { return false }
	if defines^ == nil { defines^ = make(map[string]string, context.allocator) }
	defines[argument[:separator]] = argument[separator + 1:]
	index^ += 1
	return true
}
