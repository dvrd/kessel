package kessel

// Bundle assembly. The body (wrapped module definitions, namespace objects,
// then module code in evaluation order) is printed first because printing
// decides which runtime helpers, interop objects and external bindings exist;
// the header that declares them is generated afterwards and prepended.

import "core:fmt"
import "core:slice"
import "core:strings"

bundle_emit :: proc(g: ^BundleGraph) -> BundleOutput {
	// Bodies first: printing a chunk is what discovers the bindings it needs
	// from other chunks, and therefore what those chunks must export.
	runtime_used: bit_set[BundleHelper; u16]
	for &chunk in g.chunks {
		if !bundle_chunk_included(g, &chunk) { continue }
		bundle_chunk_enter(g, chunk.index)
		bundle_emit_body(g, &chunk)
		bundle_chunk_leave(g)
		runtime_used += chunk.helpers_used
	}
	files := make([dynamic]BundleFile, g.alloc)
	split := len(g.chunks) > 1
	// A wrapped entry is started from a file of its own, which imports the
	// initializer from the chunk that defines the entry.
	for index in g.entries {
		entry := g.modules[index]
		if !split || entry.wrap == .None { continue }
		g.chunks[entry.chunk].exports[entry.wrapper_name] = true
		if entry.wrap == .ESM { g.chunks[entry.chunk].exports[entry.namespace_name] = true }
	}
	for &chunk in g.chunks {
		if !bundle_chunk_included(g, &chunk) { continue }
		bundle_chunk_enter(g, chunk.index)
		file := bundle_emit_file(g, &chunk, split)
		bundle_chunk_leave(g)
		append(&files, file)
	}
	if split {
		bundle_emit_facades(g, &files)
		append(&files, bundle_emit_runtime(g, runtime_used))
	}
	return {files = files[:]}
}

@(private="file")
bundle_chunk_included :: proc(g: ^BundleGraph, chunk: ^BundleChunk) -> bool {
	for index in chunk.modules {
		if g.modules[index].included { return true }
	}
	return false
}

// Print everything of the current chunk that does not depend on what other
// chunks will ask of it.
@(private="file")
bundle_emit_body :: proc(g: ^BundleGraph, chunk: ^BundleChunk) {
	e := BundleEmit{g = g}
	e.body = strings.builder_make(g.alloc)
	e.segments = make([dynamic]BundleSegment, g.alloc)
	for index in chunk.modules {
		module := g.modules[index]
		if module.included && module.wrap != .None { bundle_emit_wrapped(&e, module) }
	}
	bundle_emit_namespaces(&e, chunk)
	for event in g.order {
		module := g.modules[event.module]
		switch event.kind {
		case .Init:
			strings.write_string(&e.body, bundle_init_text(g, module, module.records[event.record]))
			strings.write_byte(&e.body, '\n')
		case .Code:
			fmt.sbprintf(&e.body, "// %s\n", module.display)
			bundle_print_module(&e, module, 0)
		}
	}
	// In a single file a wrapped entry is started by that file. With several
	// files it gets a file of its own, so loading the chunk never runs it.
	if chunk.entry >= 0 {
		entry := g.modules[chunk.entry]
		if entry.wrap == .None || len(g.chunks) == 1 { bundle_emit_tail(&e, entry) }
	}
	chunk.body = strings.to_string(e.body)
	chunk.segments = e.segments[:]
}

// Put the header that the body turned out to need in front of it, add the
// exports other chunks asked for, then validate or minify the file.
@(private="file")
bundle_emit_file :: proc(g: ^BundleGraph, chunk: ^BundleChunk, split: bool) -> BundleFile {
	e := BundleEmit{g = g, segments = make([dynamic]BundleSegment, g.alloc)}
	append(&e.segments, ..chunk.segments)
	entry: ^BundleModule
	if chunk.entry >= 0 && g.modules[chunk.entry].wrap == .None { entry = g.modules[chunk.entry] }
	if chunk.entry >= 0 && len(g.chunks) == 1 { entry = g.modules[chunk.entry] }

	header := strings.builder_make(g.alloc)
	bundle_emit_header(&e, &header, chunk, entry, split)
	shift := u32(strings.builder_len(header))
	strings.write_string(&header, chunk.body)
	if len(chunk.exports) != 0 {
		names := make([dynamic]string, g.alloc)
		for name in chunk.exports { append(&names, name) }
		slice.sort(names[:])
		bundle_template(&header, "export { @0 };\n", strings.join(names[:], ", ", g.alloc))
	}
	if g.options.format == .IIFE { strings.write_string(&header, "})();\n") }
	output := BundleFile{name = chunk.name, code = strings.to_string(header), entry = entry != nil}
	bundle_emit_finish(&e, &output, shift)
	return output
}

@(private="file")
bundle_emit_finish :: proc(e: ^BundleEmit, output: ^BundleFile, shift: u32) {
	g := e.g
	mappings: []BundleMapping
	if g.options.source_map { mappings = bundle_map_collect(g, e.segments[:], shift) }
	if g.options.minify {
		output.code, mappings = bundle_emit_minify(e, output.code, shift, mappings)
	} else {
		bundle_emit_validate(e, output.code, shift)
	}
	if g.error_count == 0 && g.options.source_map && len(mappings) != 0 {
		output.map_json = bundle_map_json(g, mappings, output.code)
	}
}

// A wrapped entry's own file: it loads the chunk that defines the entry and
// starts it. The entry cannot have exports here; linking rejected that.
@(private="file")
bundle_emit_facades :: proc(g: ^BundleGraph, files: ^[dynamic]BundleFile) {
	for index in g.entries {
		entry := g.modules[index]
		if entry.wrap == .None { continue }
		builder := strings.builder_make(g.alloc)
		if entry.has_hashbang { fmt.sbprintf(&builder, "#!%s\n", entry.job.lexer.hashbang_value) }
		bundle_template(&builder, "import { @0 } from \"./@1\";\n", entry.wrapper_name,
			g.chunks[entry.chunk].name)
		if entry.wrap == .CJS {
			fmt.sbprintf(&builder, "export default %s();\n", entry.wrapper_name)
		} else {
			bundle_template(&builder, "import { @0 } from \"./@1\";\n", entry.namespace_name,
				g.chunks[entry.chunk].name)
			bundle_emit_lazy_entry(g, &builder, entry)
		}
		append(files, BundleFile{
			name = g.entry_files[index], code = strings.to_string(builder), entry = true,
		})
	}
}

// Start a wrapped ES entry and pass its exports on. CommonJS and IIFE output
// hand over the live namespace. ESM output exports copies, which linking has
// checked to be bindings that never change.
@(private="file")
bundle_emit_lazy_entry :: proc(g: ^BundleGraph, builder: ^strings.Builder, entry: ^BundleModule) {
	helpers := &g.helpers
	names := bundle_export_names(g, entry)
	if g.options.format != .ESM {
		wanted := len(names) != 0 if g.options.format == .CJS else g.options.global_name != ""
		if !wanted {
			fmt.sbprintf(builder, "%s();\n", entry.wrapper_name)
			return
		}
		helpers.used += {.ToCommonJS, .CopyProps, .DefProp, .Namespace}
		prefix := "module.exports =" if g.options.format == .CJS else "return"
		fmt.sbprintf(builder, "%s %s(%s());\n", prefix, helpers.names[.ToCommonJS],
			entry.wrapper_name)
		return
	}
	fmt.sbprintf(builder, "%s();\n", entry.wrapper_name)
	specifiers := make([dynamic]string, g.alloc)
	for name in names {
		binding := bundle_unique_name(g, "export_value")
		accessor := strings.builder_make(g.alloc)
		bundle_write_accessor(&accessor, name)
		fmt.sbprintf(builder, "var %s = %s%s;\n", binding, entry.namespace_name,
			strings.to_string(accessor))
		exported := strings.builder_make(g.alloc)
		if bundle_is_identifier(name) {
			strings.write_string(&exported, name)
		} else {
			write_json_string(&exported, name)
		}
		append(&specifiers,
			fmt.aprintf("%s as %s", binding, strings.to_string(exported), allocator = g.alloc))
	}
	if len(specifiers) != 0 {
		bundle_template(builder, "export { @0 };\n", strings.join(specifiers[:], ", ", g.alloc))
	}
}

// The helpers every chunk shares. They live in one file so that the interop
// caches inside them are the same objects for every importer.
@(private="file")
bundle_emit_runtime :: proc(g: ^BundleGraph, used: bit_set[BundleHelper; u16]) -> BundleFile {
	builder := strings.builder_make(g.alloc)
	g.helpers.used = used
	bundle_emit_helper_text(g, &builder)
	names := make([dynamic]string, g.alloc)
	for helper in BundleHelper {
		if helper in used { append(&names, g.helpers.names[helper]) }
	}
	if len(names) != 0 {
		bundle_template(&builder, "export { @0 };\n", strings.join(names[:], ", ", g.alloc))
	}
	return {name = g.runtime_name, code = strings.to_string(builder)}
}

// Write `template`, replacing `@0`..`@9` with the matching argument. The
// formatter in core:fmt gives braces a meaning, which JavaScript text is full of.
bundle_template :: proc(builder: ^strings.Builder, template: string, args: ..string) {
	for i := 0; i < len(template); i += 1 {
		c := template[i]
		if c == '@' && i + 1 < len(template) && template[i + 1] >= '0' && template[i + 1] <= '9' {
			index := int(template[i + 1] - '0')
			assert(index < len(args))
			strings.write_string(builder, args[index])
			i += 1
		} else {
			strings.write_byte(builder, c)
		}
	}
}

@(private="file")
bundle_emit_wrapped :: proc(e: ^BundleEmit, module: ^BundleModule) {
	g := e.g
	helpers := &g.helpers
	fmt.sbprintf(&e.body, "// %s\n", module.display)
	if module.wrap == .CJS {
		helpers.used += {.CommonJS}
		bundle_template(&e.body, "var @0 = @1(function (exports, module) {\n", module.wrapper_name,
			helpers.names[.CommonJS])
		bundle_print_module(e, module, 1)
		strings.write_string(&e.body, "});\n")
		return
	}
	helpers.used += {.ESM, .Export, .Namespace, .DefProp}
	fmt.sbprintf(&e.body, "var %s = %s();\n", module.namespace_name, helpers.names[.Namespace])
	bundle_template(&e.body, "var @0 = @1(function () {\n", module.wrapper_name,
		helpers.names[.ESM])
	// Getters first: a module that imports this one in a cycle may read the
	// namespace while the body below is still running.
	fmt.sbprintf(&e.body, "  %s(%s, ", helpers.names[.Export], module.namespace_name)
	bundle_write_export_getters(g, &e.body, module, "  ")
	strings.write_string(&e.body, ");\n")
	for record in module.records {
		if record.kind != .Import || record.target < 0 { continue }
		assert(g.modules[record.target].wrap != .None, "a lazy module's dependencies are lazy")
		fmt.sbprintf(&e.body, "  %s\n", bundle_init_text(g, module, record))
	}
	bundle_print_module(e, module, 1)
	bundle_template(&e.body, "}, @0);\n", module.namespace_name)
}

// Namespace objects of hoisted modules exist before any module code runs, as
// they do in a real module graph: a cyclic importer may hold one early, and
// reading a not-yet-initialised export through it must throw a TDZ error
// rather than find `undefined`.
@(private="file")
bundle_emit_namespaces :: proc(e: ^BundleEmit, chunk: ^BundleChunk) {
	g := e.g
	helpers := &g.helpers
	for index in chunk.modules {
		module := g.modules[index]
		if !module.included || module.wrap != .None || !module.needs_namespace { continue }
		helpers.used += {.Export, .Namespace, .DefProp}
		fmt.sbprintf(&e.body, "var %s = %s(%s(), ", module.namespace_name, helpers.names[.Export],
			helpers.names[.Namespace])
		bundle_write_export_getters(g, &e.body, module, "")
		strings.write_string(&e.body, ");\n")
		if module.is_entry && g.options.format == .CJS {
			helpers.used += {.ToCommonJS, .CopyProps, .DefProp, .Namespace}
			fmt.sbprintf(&e.body, "module.exports = %s(%s);\n", helpers.names[.ToCommonJS],
				module.namespace_name)
		}
	}
}

@(private="file")
bundle_emit_tail :: proc(e: ^BundleEmit, entry: ^BundleModule) {
	g := e.g
	helpers := &g.helpers
	if entry.wrap != .None {
		call := fmt.aprintf("%s()", entry.wrapper_name, allocator = g.alloc)
		if entry.wrap == .ESM {
			bundle_emit_lazy_entry(g, &e.body, entry)
			return
		}
		switch {
		case g.options.format == .ESM:    fmt.sbprintf(&e.body, "export default %s;\n", call)
		case g.options.format == .CJS:    fmt.sbprintf(&e.body, "module.exports = %s;\n", call)
		case g.options.global_name != "": fmt.sbprintf(&e.body, "return %s;\n", call)
		case:                             fmt.sbprintf(&e.body, "%s;\n", call)
		}
		return
	}
	if g.options.format == .IIFE {
		if g.options.global_name != "" && entry.needs_namespace {
			helpers.used += {.ToCommonJS, .CopyProps, .DefProp, .Namespace}
			fmt.sbprintf(&e.body, "return %s(%s);\n", helpers.names[.ToCommonJS],
				entry.namespace_name)
		}
		return
	}
	if g.options.format != .ESM { return }
	specifiers := make([dynamic]string, g.alloc)
	for name in bundle_export_names(g, entry) {
		target := bundle_resolve_hoisted(g, entry, name, 0)
		text := bundle_target_text(g, target, false)
		if !bundle_is_identifier(text) {
			// An export clause names bindings. A CommonJS property is copied
			// into one; it is a snapshot, which is all CommonJS can offer.
			binding := bundle_unique_name(g, "export_value")
			fmt.sbprintf(&e.body, "var %s = %s;\n", binding, text)
			text = binding
		}
		exported := name
		if !bundle_is_identifier(name) {
			quoted := strings.builder_make(g.alloc)
			write_json_string(&quoted, name)
			exported = strings.to_string(quoted)
		}
		if text == exported { append(&specifiers, text) } else {
			append(&specifiers, fmt.aprintf("%s as %s", text, exported, allocator = g.alloc))
		}
	}
	if len(specifiers) != 0 {
		bundle_template(&e.body, "export { @0 };\n", strings.join(specifiers[:], ", ", g.alloc))
	}
	// `export *` is transitive, so a star reached through bundled modules is
	// re-exported by the entry as well. Explicit exports still take precedence.
	for specifier in bundle_external_stars(g, entry) {
		strings.write_string(&e.body, "export * from ")
		write_json_string(&e.body, specifier)
		strings.write_string(&e.body, ";\n")
	}
}

@(private="file")
bundle_emit_header :: proc(
	e: ^BundleEmit,
	header: ^strings.Builder,
	chunk: ^BundleChunk,
	entry: ^BundleModule, // nil for a chunk that only defines modules
	split: bool,
) {
	g := e.g
	if entry != nil && entry.has_hashbang {
		fmt.sbprintf(header, "#!%s\n", entry.job.lexer.hashbang_value)
	}
	switch g.options.format {
	case .ESM:
	case .CJS: strings.write_string(header, "\"use strict\";\n")
	case .IIFE:
		if g.options.global_name != "" { fmt.sbprintf(header, "var %s = ", g.options.global_name) }
		// A function, not an arrow: the bundle's `this` must be undefined.
		strings.write_string(header, "(function () {\n\"use strict\";\n")
	}
	if g.options.format == .ESM { bundle_emit_external_imports(g, header) }
	bundle_emit_file_paths(g, header, chunk)
	if split {
		bundle_emit_chunk_imports(g, header)
	} else {
		bundle_emit_helper_text(g, header)
	}
	if g.options.format != .ESM { bundle_emit_external_requires(g, header) }
	// An interop object is bound where its importer runs. A module earlier in
	// a cycle can read through it before that; Node hands such a reader
	// `undefined` for every CommonJS export, and an empty object does the same.
	interop := make([dynamic]string, g.alloc)
	for name in g.interop_used {
		append(&interop, fmt.aprintf("%s = {{}}", name, allocator = g.alloc))
	}
	if len(interop) != 0 {
		fmt.sbprintf(header, "var %s;\n", strings.join(interop[:], ", ", g.alloc))
	}
}

// Imports of the current chunk from the runtime chunk and from the chunks
// that define the modules it mentions, one statement per file, sorted so the
// output does not depend on map iteration order.
@(private="file")
bundle_emit_chunk_imports :: proc(g: ^BundleGraph, header: ^strings.Builder) {
	bundle_helpers_close(g)
	names := make([dynamic]string, g.alloc)
	for helper in BundleHelper {
		if helper in g.helpers.used { append(&names, g.helpers.names[helper]) }
	}
	if len(names) != 0 {
		bundle_template(header, "import { @0 } from \"./@1\";\n",
			strings.join(names[:], ", ", g.alloc), g.runtime_name)
	}
	for &other in g.chunks {
		clear(&names)
		for name, owner in g.chunk_imports {
			if owner == other.index { append(&names, name) }
		}
		if len(names) == 0 { continue }
		slice.sort(names[:])
		bundle_template(header, "import { @0 } from \"./@1\";\n",
			strings.join(names[:], ", ", g.alloc), other.name)
	}
}

// CommonJS code may read __filename and __dirname. After bundling the only
// file there is to name is the bundle, which is what CommonJS output gives for
// free; ESM output for Node derives the same values from import.meta.url.
@(private="file")
bundle_emit_file_paths :: proc(g: ^BundleGraph, header: ^strings.Builder, chunk: ^BundleChunk) {
	if g.options.format == .CJS { return }
	user: ^BundleModule
	for index in chunk.modules {
		module := g.modules[index]
		if !module.included || user != nil { continue }
		for ref in module.model.refs {
			if ref.resolved != SYMBOL_UNRESOLVED { continue }
			if ref.name == "__filename" || ref.name == "__dirname" { user = module; break }
		}
	}
	if user == nil { return }
	if g.options.format != .ESM || g.options.platform != .Node {
		bundle_warning(g, user, nil,
			"__filename and __dirname are not defined in this output format")
		return
	}
	to_path := bundle_unique_name(g, "__fileURLToPath")
	directory := bundle_unique_name(g, "__pathDirname")
	bundle_template(header, `import { fileURLToPath as @0 } from "node:url";
import { dirname as @1 } from "node:path";
var __filename = @0(import.meta.url);
var __dirname = @1(__filename);
`, to_path, directory)
}

@(private="file")
bundle_emit_external_imports :: proc(g: ^BundleGraph, header: ^strings.Builder) {
	for &external in g.externals {
		named := make([dynamic]string, g.alloc)
		namespace := ""
		for name in external.order {
			binding := external.names[name]
			switch {
			case name == "*":        namespace = binding
			case name == binding:    append(&named, name)
			case bundle_is_identifier(name):
				append(&named, fmt.aprintf("%s as %s", name, binding, allocator = g.alloc))
			case:
				quoted := strings.builder_make(g.alloc)
				write_json_string(&quoted, name)
				append(&named, fmt.aprintf("%s as %s", strings.to_string(quoted), binding,
					allocator = g.alloc))
			}
		}
		if namespace != "" {
			fmt.sbprintf(header, "import * as %s from ", namespace)
			write_json_string(header, external.specifier)
			strings.write_string(header, ";\n")
		}
		if len(named) != 0 {
			bundle_template(header, "import { @0 } from ", strings.join(named[:], ", ", g.alloc))
		} else if namespace == "" {
			strings.write_string(header, "import ")
		} else {
			continue
		}
		write_json_string(header, external.specifier)
		strings.write_string(header, ";\n")
	}
}

// Outside ESM output an external is loaded with require(), in import order,
// before any bundled code: the closest match to hoisted import declarations.
@(private="file")
bundle_emit_external_requires :: proc(g: ^BundleGraph, header: ^strings.Builder) {
	for &external in g.externals {
		bound := false
		for name, slot in external.interop_names {
			if name == "" { continue }
			bound = true
			fmt.sbprintf(header, "var %s = %s(require(", name, g.helpers.names[.ToESM])
			write_json_string(header, external.specifier)
			fmt.sbprintf(header, "), %d, 1);\n", slot)
		}
		if !bound {
			strings.write_string(header, "require(")
			write_json_string(header, external.specifier)
			strings.write_string(header, ");\n")
		}
	}
}

// Helpers that the generated glue needs beyond the ones printing asked for.
@(private="file")
bundle_helpers_close :: proc(g: ^BundleGraph) {
	helpers := &g.helpers
	for &external in g.externals {
		bound := external.interop_names[0] != "" || external.interop_names[1] != ""
		if g.options.format != .ESM && bound {
			helpers.used += {.ToESM, .CopyProps, .DefProp}
		}
	}
}

@(private="file")
bundle_emit_helper_text :: proc(g: ^BundleGraph, header: ^strings.Builder) {
	bundle_helpers_close(g)
	helpers := &g.helpers
	n := helpers.names
	used := helpers.used
	if .DefProp in used { fmt.sbprintf(header, "var %s = Object.defineProperty;\n", n[.DefProp]) }
	if .CopyProps in used {
		// Getters, not copies: a CommonJS module may assign exports later.
		bundle_template(header, `var @0 = (to, from) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of Object.getOwnPropertyNames(from)) {
      if (!Object.prototype.hasOwnProperty.call(to, key)) {
        let descriptor = Object.getOwnPropertyDescriptor(from, key);
        @1(to, key, { get: () => from[key], enumerable: !descriptor || descriptor.enumerable });
      }
    }
  }
  return to;
};
`, n[.CopyProps], n[.DefProp])
	}
	if .Namespace in used {
		bundle_template(header,
			"var @0 = () => @1(Object.create(null), Symbol.toStringTag, { value: \"Module\" });\n",
			n[.Namespace], n[.DefProp])
	}
	if .Export in used {
		bundle_template(header, `var @0 = (target, all) => {
  for (var name in all) @1(target, name, { get: all[name], enumerable: true });
  return Object.freeze(target);
};
`, n[.Export], n[.DefProp])
	}
	bundle_emit_wrapper_helpers(g, header)
	bundle_emit_interop_helpers(g, header)
}

@(private="file")
bundle_emit_wrapper_helpers :: proc(g: ^BundleGraph, header: ^strings.Builder) {
	n := g.helpers.names
	used := g.helpers.used
	if .CommonJS in used {
		// Like Node, forget a module whose body threw so a later require retries it.
		bundle_template(header, `var @0 = (fn, module) => () => {
  if (!module) {
    module = { exports: {} };
    try {
      fn.call(module.exports, module.exports, module);
    } catch (error) {
      module = void 0;
      throw error;
    }
  }
  return module.exports;
};
`, n[.CommonJS])
	}
	if .ESM in used {
		// Like an ES module, remember an evaluation error and rethrow it.
		bundle_template(header, `var @0 = (fn, namespace, state, failure) => () => {
  if (state === 2) throw failure;
  if (!state) {
    state = 1;
    try {
      fn();
    } catch (error) {
      state = 2;
      failure = error;
      throw error;
    }
  }
  return namespace;
};
`, n[.ESM])
	}
}

@(private="file")
bundle_emit_interop_helpers :: proc(g: ^BundleGraph, header: ^strings.Builder) {
	helpers := &g.helpers
	n := helpers.names
	used := helpers.used
	if .ToESM in used {
		// One namespace per CommonJS module and mode, so every importer sees
		// the same object. A default export is module.exports unless the
		// importer honours the __esModule convention and the module sets it.
		// Node also exposes module.exports under that very name.
		// An external loaded with require() may turn out to be an ES module;
		// Node then hands back its namespace, which is used as it is.
		bundle_template(header, `var @0 = [new WeakMap(), new WeakMap()];
var @1 = (value, nodeMode, external) => {
  if (external && value != null && value[Symbol.toStringTag] === "Module") return value;
  var keyed = value !== null && (typeof value === "object" || typeof value === "function");
  var cache = @2[nodeMode ? 1 : 0];
  var result = keyed ? cache.get(value) : void 0;
  if (result) return result;
  result = value != null ? Object.create(Object.getPrototypeOf(value)) : {};
  if (nodeMode || !value || !value.__esModule) @3(result, "default", { value, enumerable: true });
  if (nodeMode) @3(result, "module.exports", { value, enumerable: true });
  @4(result, value);
  if (keyed) cache.set(value, result);
  return result;
};
`, helpers.esm_cache, n[.ToESM], helpers.esm_cache, n[.DefProp], n[.CopyProps])
	}
	if .ToCommonJS in used {
		// What require() of an ES module returns in Node: the namespace
		// itself, or, when there is a default export, a namespace-shaped copy
		// flagged with __esModule so transpiled importers find the default.
		// A "module.exports" export overrides both.
		bundle_template(header, `var @0 = new WeakMap();
var @1 = (namespace) => {
  if ("module.exports" in namespace) return namespace["module.exports"];
  if (!("default" in namespace)) return namespace;
  var result = @0.get(namespace);
  if (!result) {
    result = @2(@3(), "__esModule", { value: true, enumerable: true });
    result = Object.freeze(@4(result, namespace));
    @0.set(namespace, result);
  }
  return result;
};
`, helpers.cjs_cache, n[.ToCommonJS], n[.DefProp], n[.Namespace], n[.CopyProps])
	}
	if .Dynamic in used {
		// import() of a bundled module: asynchronous like the real thing, and
		// defined here so that no module-local `Promise` can intercept it.
		bundle_template(header, "var @0 = (load) => Promise.resolve().then(load);\n", n[.Dynamic])
	}
	if .Require in used {
		if g.options.format == .ESM && g.options.platform == .Node {
			bundle_template(header, `import { createRequire as @0 } from "node:module";
var @1 = @0(import.meta.url);
`, helpers.create_require, n[.Require])
		} else {
			bundle_template(header, `var @0 = typeof require !== "undefined" ? require : (name) => {
  throw new Error('Dynamic require of "' + name + '" is not supported');
};
`, n[.Require])
		}
	}
}

// Parse the finished bundle and run the early-error checker over it. An
// error is located in the module whose printed text contains it.
@(private="file")
bundle_emit_reparse :: proc(e: ^BundleEmit, code: string, shift: u32, job: ^ParseJob) -> bool {
	g := e.g
	// The bundle nests its inputs a few levels deeper than they were written
	// (a wrapper function, a call around it). An input at the parser's limit
	// must still validate.
	config := ParseConfig{lang_override = .JS, max_depth = PARSE_RESOURCE_AST_DEPTH + 16}
	if g.options.format == .ESM { config.source_type_override = .Module }
	if !parse_job_open_inline(job, code, config, "bundle.js") {
		bundle_error(g, nil, nil, "out of memory while checking the bundle")
		return false
	}
	parse_job_run(job)
	if len(job.parser.errors) == 0 { checker_run_for_job(job) }
	for err in job.parser.errors {
		owner: ^BundleModule
		for segment in e.segments {
			start := shift + segment.base
			inside := start <= err.start && err.start < start + segment.size
			if inside { owner = g.modules[segment.module] }
		}
		// Every input passed the same checks on its own, so this is either
		// sloppy-mode syntax that strict bundle code cannot hold or a bundler bug.
		bundle_error(g, owner, nil,
			"the bundle is not valid JavaScript at output offset %d: %s (bundled code is strict)",
			err.start, err.message)
	}
	return len(job.parser.errors) == 0
}

// The last line of defence against a silently wrong bundle: what was printed
// must parse and pass the early-error checker, or nothing is written.
@(private="file")
bundle_emit_validate :: proc(e: ^BundleEmit, code: string, shift: u32) {
	job: ParseJob
	bundle_emit_reparse(e, code, shift, &job)
	parse_job_close(&job)
}

// Minify by running the existing minifier over the finished bundle, then
// carry each of its mappings through the bundle's own.
@(private="file")
bundle_emit_minify :: proc(
	e: ^BundleEmit,
	code: string,
	shift: u32,
	mappings: []BundleMapping,
) -> (string, []BundleMapping) {
	g := e.g
	job: ParseJob
	defer parse_job_close(&job)
	if !bundle_emit_reparse(e, code, shift, &job) { return code, mappings }
	cg: Codegen
	sm: SourceMap
	codegen_print_job(&job, &cg, {minified = true, compress = true, mangle = true}, &sm)
	minified := strings.clone(string(cg.buf[:cg.pos]), g.alloc)
	composed := bundle_map_compose(g, mappings, sm.records[:])
	return minified, composed
}
