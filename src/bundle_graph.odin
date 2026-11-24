package kessel

// Module graph construction: read, lower, parse and scan every module that
// the entry reaches, resolving each dependency record on the way.

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"

BundleSideEffects :: enum u8 { Unknown, None, Listed }

BundlePackage :: struct {
	directory:    string,
	type_module:  bool,
	side_effects: BundleSideEffects,
	patterns:     []string, // files that do have side effects when Listed
}

// A browser `false` mapping replaces a module with an empty CommonJS object.
BUNDLE_IGNORED_PREFIX :: "\x00ignored:"

// The module list doubles as the work queue: loading module i appends the
// modules it reaches, and bundle_module_add refuses to grow past the bound.
bundle_graph_load :: proc(g: ^BundleGraph) {
	entry, abs_err := filepath.abs(g.options.entry, g.alloc)
	if abs_err != nil || !os.is_file(entry) {
		bundle_error(g, nil, nil, "cannot read entry file '%s'", g.options.entry)
		return
	}
	bundle_module_add(g, entry)
	for index := 0; index < len(g.modules); index += 1 {
		assert(index < BUNDLE_MODULES_MAX)
		module := g.modules[index]
		if !bundle_module_load(g, module) { continue }
		for &record in module.records { bundle_record_resolve(g, module, &record) }
	}
}

@(private="file")
bundle_module_add :: proc(g: ^BundleGraph, path: string) -> i32 {
	if existing, found := g.by_path[path]; found { return existing }
	if len(g.modules) == BUNDLE_MODULES_MAX {
		bundle_error(g, nil, nil, "the module graph exceeds %d modules", BUNDLE_MODULES_MAX)
		return BUNDLE_UNRESOLVED
	}
	module := new(BundleModule, g.alloc)
	module.index = i32(len(g.modules))
	module.path = path
	ignored := strings.has_prefix(path, BUNDLE_IGNORED_PREFIX)
	module.display = bundle_display_path(g, path[len(BUNDLE_IGNORED_PREFIX):] if ignored else path)
	module.records = make([dynamic]BundleRecord, g.alloc)
	module.imports = make(map[string]BundleImport, g.alloc)
	module.exports = make(map[string]BundleExport, g.alloc)
	module.export_order = make([dynamic]string, g.alloc)
	module.stars = make([dynamic]i32, g.alloc)
	module.this_nodes = make([dynamic]^Expression, g.alloc)
	module.callees = make(map[u32]bool, g.alloc)
	module.free_cjs = make(map[u32]bool, g.alloc)
	module.resolved = make(map[string]BundleTarget, g.alloc)
	module.resolving = make(map[string]bool, g.alloc)
	module.import_targets = make(map[string]BundleTarget, g.alloc)
	module.declared = make(map[string][dynamic]i32, g.alloc)
	module.names = make(map[string]string, g.alloc)
	append(&g.modules, module)
	g.by_path[path] = module.index
	return module.index
}

@(private="file")
bundle_module_load :: proc(g: ^BundleGraph, module: ^BundleModule) -> bool {
	if strings.has_prefix(module.path, BUNDLE_IGNORED_PREFIX) {
		module.source = "module.exports = {};\n"
		module.original = ""
		module.transform_records = make([]SourceMapRecord, 1, g.alloc)
		return bundle_module_parse(g, module, .CJS)
	}
	bytes, read_err := os.read_entire_file_from_path(module.path, g.alloc)
	if read_err != nil {
		bundle_error(g, module, nil, "cannot read file")
		return false
	}
	g.source_bytes += len(bytes)
	if g.source_bytes > BUNDLE_SOURCE_BYTES_MAX {
		bundle_error(g, module, nil, "the bundle input exceeds %d bytes", BUNDLE_SOURCE_BYTES_MAX)
		return false
	}
	module.original = string(bytes)
	module.source = module.original
	extension := filepath.ext(module.path)
	package_info := bundle_package_for(g, filepath.dir(module.path))
	module.side_effect_free = bundle_package_side_effect_free(package_info, module.path)
	module.node_mode = extension == ".mjs" || extension == ".mts" || package_info.type_module
	switch extension {
	case ".json":
		return bundle_module_load_json(g, module)
	case ".js", ".mjs", ".cjs":
	case ".jsx", ".ts", ".tsx", ".mts", ".cts":
		module.typescript = extension != ".jsx"
		if !bundle_module_transform(g, module) { return false }
	case:
		bundle_error(g, module, nil, "no loader is configured for '%s' files", extension)
		return false
	}
	kind: Maybe(BundleModuleKind)
	switch {
	case extension == ".mjs" || extension == ".mts": kind = .ESM
	case extension == ".cjs" || extension == ".cts": kind = .CJS
	case package_info.type_module:                    kind = .ESM
	}
	return bundle_module_parse(g, module, kind)
}

// JSON text is a JavaScript expression except for one case: an object
// literal treats a "__proto__" key as the prototype, JSON.parse does not.
@(private="file")
bundle_module_load_json :: proc(g: ^BundleGraph, module: ^BundleModule) -> bool {
	if !json.is_valid(transmute([]byte)module.original, .JSON, true) {
		bundle_error(g, module, nil, "invalid JSON")
		return false
	}
	builder := strings.builder_make(g.alloc)
	strings.write_string(&builder, "module.exports = ")
	prefix := strings.builder_len(builder)
	if strings.contains(module.original, "__proto__") {
		strings.write_string(&builder, "JSON.parse(")
		write_json_string(&builder, module.original)
		strings.write_string(&builder, ")")
	} else {
		strings.write_string(&builder, strings.trim_space(module.original))
	}
	strings.write_string(&builder, ";\n")
	module.source = strings.to_string(builder)
	module.transform_records = make([]SourceMapRecord, 2, g.alloc)
	module.transform_records[1] = {gen_offset = u32(prefix), src_offset = 0}
	// A JSON default import is always the parsed value, whatever keys it has.
	module.node_mode = true
	return bundle_module_parse(g, module, .CJS)
}

// Lower TypeScript and JSX with the existing transformer. The linker only
// ever sees its JavaScript output; the transformer's map leads back.
@(private="file")
bundle_module_transform :: proc(g: ^BundleGraph, module: ^BundleModule) -> bool {
	if resolve_dts_from_path(module.path) {
		module.source = ""
		module.transform_records = make([]SourceMapRecord, 1, g.alloc)
		return true
	}
	job: ParseJob
	if !parse_job_open_inline(&job, module.original, {preserve_parens = true}, module.path) {
		bundle_error(g, module, nil, "out of memory while parsing")
		return false
	}
	defer parse_job_close(&job)
	parse_job_run(&job)
	if len(job.parser.errors) != 0 {
		for err in job.parser.errors { bundle_error(g, module, err.start, "%s", err.message) }
		return false
	}
	for statement in job.program.body {
		if alias, ok := statement^.(^TSImportEqualsDeclaration); ok {
			bundle_error(g, module, alias.loc.start, "TypeScript 'import x = require()' is not supported by the bundler")
			return false
		}
		if assignment, ok := statement^.(^TSExportAssignment); ok {
			bundle_error(g, module, assignment.loc.start, "TypeScript 'export =' is not supported by the bundler")
			return false
		}
	}
	options := TransformOptions{}
	if job.lang == .JSX || job.lang == .TSX {
		options.jsx = g.options.jsx if g.options.jsx != "" else "classic"
		options.import_source = g.options.jsx_import_source
		options.pragma = g.options.jsx_factory
		options.pragma_frag = g.options.jsx_fragment
	}
	cg: Codegen
	sm: SourceMap
	diagnostic := transform_generate(&job, &cg, options, &sm)
	defer codegen_destroy(&cg, context.allocator)
	defer sourcemap_destroy(&sm)
	if failure, failed := diagnostic.?; failed {
		// The transformer names the construct it cannot lower.
		bundle_error(g, module, nil, "%s", failure.what)
		return false
	}
	module.source = strings.clone(string(cg.buf[:cg.pos]), g.alloc)
	records := make([]SourceMapRecord, len(sm.records), g.alloc)
	copy(records, sm.records[:])
	module.transform_records = records
	return true
}

// Parse the link source. A file is an ES module when its name or package
// says so, or when it uses module syntax; everything else is CommonJS, which
// is what Node would do with it.
@(private="file")
bundle_module_parse :: proc(g: ^BundleGraph, module: ^BundleModule, forced: Maybe(BundleModuleKind)) -> bool {
	config := ParseConfig{lang_override = .JS}
	if kind, known := forced.?; known {
		if kind == .ESM { config.source_type_override = .Module } else { config.is_commonjs_override = true }
	}
	bundle_module_parse_once(g, module, config)
	if _, known := forced.?; !known && len(module.job.parser.errors) != 0 {
		// A top-level `return` is legal only in CommonJS. Retry before reporting.
		parse_job_close(module.job)
		config.is_commonjs_override = true
		bundle_module_parse_once(g, module, config)
	}
	job := module.job
	if len(job.parser.errors) != 0 {
		for err in job.parser.errors { bundle_error(g, module, err.start, "%s", err.message) }
		return false
	}
	module.kind = .ESM if job.program.type == .Module else .CJS
	if kind, known := forced.?; known { module.kind = kind }
	module.has_hashbang = job.lexer.has_hashbang
	module.model = semantic_build(job.program, module.source, .JS, job.arena_alloc)
	bundle_scan_module(g, module)
	return true
}

@(private="file")
bundle_module_parse_once :: proc(g: ^BundleGraph, module: ^BundleModule, config: ParseConfig) {
	module.job = new(ParseJob, g.alloc)
	opened := parse_job_open_inline(module.job, module.source, config, "bundle-module.js")
	assert(opened, "the parse arena could not be reserved")
	parse_job_run(module.job)
}

@(private="file")
bundle_package_for :: proc(g: ^BundleGraph, directory: string) -> BundlePackage {
	if cached, found := g.packages[directory]; found { return cached }
	info := BundlePackage{}
	scope, config, err := module_resolver_package_scope(directory, g.alloc)
	if err == .None && config != nil {
		info.directory = scope
		if kind, ok := module_manifest_member(config, "type").(string); ok { info.type_module = kind == "module" }
		#partial switch value in module_manifest_member(config, "sideEffects") {
		case bool:
			if !value { info.side_effects = .None }
		case ^ModuleManifestArray:
			info.side_effects = .Listed
			patterns := make([dynamic]string, g.alloc)
			for element in value.elements {
				if pattern, ok := element.(string); ok { append(&patterns, pattern) }
			}
			info.patterns = patterns[:]
		}
	}
	g.packages[directory] = info
	return info
}

@(private="file")
bundle_package_side_effect_free :: proc(info: BundlePackage, path: string) -> bool {
	switch info.side_effects {
	case .Unknown: return false
	case .None:    return true
	case .Listed:
		relative := strings.trim_prefix(strings.trim_prefix(path, info.directory), "/")
		for pattern in info.patterns {
			if bundle_glob_match(strings.trim_prefix(pattern, "./"), relative) { return false }
		}
		return true
	}
	return false
}

// `sideEffects` globs: `*` stays inside one path segment, `**` crosses
// segments, and a pattern without a slash matches a file name at any depth.
// Iterative backtracking over the most recent star keeps the work bounded by
// len(pattern) * len(text).
bundle_glob_match :: proc(pattern, text: string) -> bool {
	text := text
	if !strings.contains_rune(pattern, '/') { text = filepath.base(text) }
	p, t := 0, 0
	star_p, star_t := -1, -1
	star_deep := false
	for t < len(text) {
		if p < len(pattern) && pattern[p] == '*' {
			star_deep = p + 1 < len(pattern) && pattern[p + 1] == '*'
			p += 2 if star_deep else 1
			if star_deep && p < len(pattern) && pattern[p] == '/' { p += 1 }
			star_p, star_t = p, t
		} else if p < len(pattern) && pattern[p] == text[t] {
			p += 1
			t += 1
		} else if star_p >= 0 && (star_deep || text[star_t] != '/') {
			star_t += 1
			p, t = star_p, star_t
		} else {
			return false
		}
	}
	for p < len(pattern) && pattern[p] == '*' { p += 1 }
	return p == len(pattern)
}

bundle_is_external :: proc(g: ^BundleGraph, specifier: string) -> bool {
	if strings.contains(specifier, "://") || strings.has_prefix(specifier, "data:") { return true }
	for pattern in g.options.externals {
		if pattern == specifier { return true }
		if strings.has_suffix(pattern, "*") && strings.has_prefix(specifier, pattern[:len(pattern) - 1]) { return true }
		// Marking a package external also covers its subpaths.
		if strings.has_prefix(specifier, pattern) && len(specifier) > len(pattern) && specifier[len(pattern)] == '/' {
			return true
		}
	}
	return false
}

BUNDLE_EXTENSIONS := []string{".js", ".json", ".ts", ".tsx", ".jsx", ".mjs", ".cjs", ".mts", ".cts"}

@(private="file")
bundle_record_resolve :: proc(g: ^BundleGraph, module: ^BundleModule, record: ^BundleRecord) {
	record.target = BUNDLE_UNRESOLVED
	if bundle_is_external(g, record.specifier) {
		record.target = BUNDLE_EXTERNAL
		return
	}
	// TypeScript sources import the emitted name of a sibling source file.
	alias := make(map[string][]string, g.alloc)
	alias[".js"] = []string{".js", ".ts", ".tsx"}
	alias[".jsx"] = []string{".jsx", ".tsx"}
	alias[".mjs"] = []string{".mjs", ".mts"}
	alias[".cjs"] = []string{".cjs", ".cts"}
	options := ModuleResolveOptions{
		mode = .Require if record.kind == .Require else .Import,
		conditions = g.options.conditions,
		browser = g.options.platform == .Browser,
		typescript_config = g.options.tsconfig,
		extensions = BUNDLE_EXTENSIONS,
		extension_alias = alias,
	}
	if len(g.options.main_fields) != 0 { options.main_fields = g.options.main_fields }
	result, err := module_resolve(record.specifier, module.path, options, g.alloc)
	relative := module_resolver_is_relative(record.specifier) || filepath.is_abs(record.specifier)
	if err != .None && options.mode == .Import && relative {
		// Bundled sources routinely omit the extension that Node's ES loader
		// requires. Probe for it the way a CommonJS request would.
		options.mode = .Require
		result, err = module_resolve(record.specifier, module.path, options, g.alloc)
	}
	if err != .None {
		bundle_error(g, module, record.loc.start, "could not resolve '%s' (%v)", record.specifier, err)
		return
	}
	switch result.kind {
	case .Builtin:
		if g.options.platform == .Browser {
			bundle_error(g, module, record.loc.start,
				"'%s' is a Node builtin; mark it external to bundle for the browser", record.specifier)
			return
		}
		record.target = BUNDLE_EXTERNAL
	case .Ignored:
		key := strings.concatenate({BUNDLE_IGNORED_PREFIX, result.path}, g.alloc)
		record.target = bundle_module_add(g, key)
	case .File:
		record.target = bundle_module_add(g, result.path)
	}
	if record.target >= 0 && record.kind != .Import { g.modules[record.target].lazy = true }
}
