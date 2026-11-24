#+build !wasi

package kessel

// C ABI for the bundler. The request and the reply are JSON, like the other
// tool exports; the bundle itself never touches the file system on the way out.

import "base:runtime"
import "core:encoding/json"
import "core:strings"

// Field names are the wire format. Enumerations travel as strings so that an
// unknown value is a reported error rather than a silent default.
KesselBundleRequest :: struct {
	entry, format, platform: string,
	externals, conditions, main_fields: []string,
	tsconfig, global_name, map_directory: string,
	jsx, jsx_import_source, jsx_factory, jsx_fragment: string,
	jsx_development: bool,
	define: map[string]string,
	target, decorators: string,
	emit_decorator_metadata: bool,
	minify, source_map: bool,
	tree_shaking: Maybe(bool),
}

KesselBundleFile :: struct {
	name, code, map_json: string,
	entry: bool,
}

KesselBundleReply :: struct {
	outputs: []KesselBundleFile,
	diagnostics: []BundleDiagnostic,
}

@(export, link_name="kessel_bundle")
kessel_bundle :: proc "c" (request_ptr: [^]u8, request_len: i32) -> KesselParseResult {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	text, ok := kessel_tool_input(request_ptr, request_len)
	if !ok { return {} }
	request: KesselBundleRequest
	if err := json.unmarshal_string(text, &request, .JSON, context.temp_allocator); err != nil {
		return kessel_bundle_reply({}, {{severity = .Error, message = "could not decode bundle options"}})
	}
	options, problem := kessel_bundle_options(request)
	if problem != "" {
		return kessel_bundle_reply({}, {{severity = .Error, message = problem}})
	}
	graph: BundleGraph
	output, built := bundle_run(&graph, options)
	defer bundle_destroy(&graph)
	if !built { output = {} }
	return kessel_bundle_reply(output, graph.diagnostics[:])
}

@(private="file")
kessel_bundle_reply :: proc(output: BundleOutput, diagnostics: []BundleDiagnostic) -> KesselParseResult {
	files := make([]KesselBundleFile, len(output.files), context.temp_allocator)
	for file, index in output.files {
		files[index] = {name = file.name, code = file.code, map_json = file.map_json, entry = file.entry}
	}
	// Serialised before the graph that owns the strings is destroyed.
	return kessel_bundle_json(KesselBundleReply{outputs = files, diagnostics = diagnostics})
}

@(private="file")
kessel_bundle_json :: proc(reply: KesselBundleReply) -> KesselParseResult {
	builder := strings.builder_make(context.allocator)
	if err := json.marshal_to_builder(&builder, reply, {use_enum_names = true}); err != nil {
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

// Translate the request. The returned message is empty when it is valid.
@(private="file")
kessel_bundle_options :: proc(request: KesselBundleRequest) -> (options: BundleOptions, problem: string) {
	if request.entry == "" { return {}, "bundle requires an entry file" }
	options = BundleOptions{
		entry = request.entry, externals = request.externals, conditions = request.conditions,
		main_fields = request.main_fields, tsconfig = request.tsconfig,
		global_name = request.global_name, map_directory = request.map_directory,
		jsx = request.jsx, jsx_import_source = request.jsx_import_source,
		jsx_factory = request.jsx_factory, jsx_fragment = request.jsx_fragment,
		jsx_development = request.jsx_development, define = request.define,
		target = request.target, decorators = request.decorators,
		emit_decorator_metadata = request.emit_decorator_metadata,
		minify = request.minify, source_map = request.source_map,
		tree_shaking = request.tree_shaking.? or_else true,
	}
	switch request.format {
	case "", "esm": options.format = .ESM
	case "cjs":     options.format = .CJS
	case "iife":    options.format = .IIFE
	case:           return {}, "format must be esm, cjs or iife"
	}
	switch request.platform {
	case "", "node": options.platform = .Node
	case "browser":  options.platform = .Browser
	case:            return {}, "platform must be node or browser"
	}
	if options.jsx != "" && options.jsx != "classic" && options.jsx != "automatic" {
		return {}, "jsx must be classic or automatic"
	}
	for binding in ([2]string{options.jsx_factory, options.jsx_fragment}) {
		if binding != "" && !jsx_pragma_valid(binding) { return {}, "invalid JSX factory binding" }
	}
	if _, known := transform_target_parse(options.target); !known {
		return {}, "target must be es2015 to es2024, or esnext"
	}
	if options.decorators != "" && options.decorators != "legacy" {
		return {}, "decorators must be legacy"
	}
	if options.global_name != "" {
		if options.format != .IIFE { return {}, "globalName requires the iife format" }
		if !bundle_is_identifier(options.global_name) { return {}, "globalName must be an identifier" }
	}
	return options, ""
}
