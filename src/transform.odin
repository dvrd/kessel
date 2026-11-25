package kessel

import "core:strings"

TransformOptions :: struct {
	define: map[string]string,
	jsx, pragma, pragma_frag, import_source: string,
	minified, source_map, allow_namespaces, omit_pure, development: bool,
	optimize_const_enums, lower_using: bool,
	decorators: string, // "", "preserve", "legacy" or "standard"
	emit_decorator_metadata: bool,
	target: string, // "es2015" to "es2024", or "esnext"; empty means esnext
	class_fields: string, // "define" (default) or "assign", for fields lowered below ES2022
	refresh, refresh_full_signatures: bool,
	refresh_reg, refresh_sig: string, // Runtime bindings; $RefreshReg$ and $RefreshSig$ when empty
}

// The caller owns the codegen buffer and optional source map. All lowering
// metadata is valid for the lifetime of the parse job.
transform_generate :: proc(job: ^ParseJob, cg: ^Codegen, options: TransformOptions, sm: ^SourceMap) -> Maybe(StripDiagnostic) {
	cfg := CodegenConfig{
		strip_types = true, strip_module = strip_types_module_kind(job),
		minified = options.minified, indent = "  ",
		optimize_const_enums = options.optimize_const_enums, lower_using = options.lower_using,
	}
	source := string(job.source.data)
	codegen_init(cg, cfg, source, context.allocator)
	if sm != nil {
		sourcemap_init(sm, source)
		codegen_enable_sourcemap(cg, sm)
	}
	if diagnostic := transform_state_init(job, cg, options); diagnostic != nil { return diagnostic }
	if options.jsx != "" && options.jsx != "preserve" && options.jsx != "classic" && options.jsx != "automatic" {
		return StripDiagnostic{what = "expected JSX mode preserve, classic, or automatic"}
	}
	if job.source_is_dts {
		return transform_define_apply(job, cg, options.define)
	}
	if options.jsx == "classic" || options.jsx == "automatic" {
		limit := u32(len(source))
		if len(job.program.body) > 0 { limit = codegen_list_item_loc(job.program.body[0]).start }
		jsx, diag := transform_jsx_options(options, job.lexer.comments[:], limit)
		if diag != nil { return diag }
		jsx.filename = job.source_path
		cg.cfg.jsx = jsx
	}
	if !job.source_is_dts { transform_refresh_program(cg, job.program, job.lexer.comments[:]) }
	if job.lexer.has_hashbang {
		cg_str(cg, "#!")
		cg_str(cg, job.lexer.hashbang_value)
		cg_byte(cg, '\n')
	}
	codegen_program(cg, job.program, job.lexer.comments[:], job.arena_alloc,
		preserve_jsx = cg.cfg.jsx.runtime == .Preserve && (job.lang == .JSX || job.lang == .TSX))
	if !options.minified && (cg.pos == 0 || cg.buf[cg.pos-1] != '\n') { cg_byte(cg, '\n') }
	if cg.strip_diag == nil { return transform_define_apply(job, cg, options.define) }
	return cg.strip_diag
}

transform_jsx_options :: proc(options: TransformOptions, comments: []Comment, limit: u32) -> (JSXOptions, Maybe(StripDiagnostic)) {
	jsx := JSXOptions{
		runtime = .Automatic if options.jsx == "automatic" else .Classic,
		import_source = options.import_source if options.import_source != "" else "react",
		pragma = options.pragma if options.pragma != "" else "React.createElement",
		pragma_frag = options.pragma_frag if options.pragma_frag != "" else "React.Fragment",
		allow_namespaces = options.allow_namespaces, omit_pure = options.omit_pure, development = options.development,
	}
	for comment in comments {
		if comment.end > limit { break }
		content := comment.value
		for line in strings.split_lines_iterator(&content) {
			words := strings.trim_left(line, " \t*")
			for token in strings.fields_iterator(&words) {
				directive := strings.trim_left(token, "*")
				if !jsx_pragma_directive(directive) { continue }
				value, present := strings.fields_iterator(&words)
				if !present { break }
				loc := Loc{start = comment.start, end = comment.end}
				switch directive {
				case "@jsxRuntime":
					if value == "automatic" { jsx.runtime = .Automatic }
					if value == "classic" { jsx.runtime = .Classic }
				case "@jsxImportSource": jsx.import_source = value
				case:
					if !jsx_pragma_valid(value) { return {}, StripDiagnostic{loc, "invalid JSX pragma binding"} }
					if directive == "@jsx" { jsx.pragma = value } else { jsx.pragma_frag = value }
				}
			}
		}
	}
	if !jsx_pragma_valid(jsx.pragma) || !jsx_pragma_valid(jsx.pragma_frag) {
		return {}, StripDiagnostic{what = "invalid JSX pragma binding"}
	}
	return jsx, nil
}

jsx_pragma_valid :: proc(value: string) -> bool {
	if value == "" || value[len(value)-1] == '.' { return false }
	root := true
	remaining := value
	for name in strings.split_iterator(&remaining, ".") {
		if name == "" { return false }
		if root && name == "import" {
			if value != "import.meta" && !strings.has_prefix(value, "import.meta.") { return false }
		} else if root && name != "this" && (is_always_reserved_word_name(name) || is_strict_reserved_name(name) || name == "await") {
			return false
		}
		for ch, index in name {
			if index == 0 {
				if !is_id_start_codepoint(u32(ch)) { return false }
			} else if !is_id_cont_codepoint(u32(ch)) { return false }
		}
		root = false
	}
	return true
}
