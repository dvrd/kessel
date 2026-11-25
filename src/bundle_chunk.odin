package kessel

// Chunks: which output file holds which module, and the per-file state the
// printer accumulates. See the design note in bundle.odin for why a module
// imported across files is wrapped rather than hoisted.

import "core:fmt"
import "core:path/filepath"
import "core:strings"

BundleChunk :: struct {
	index:   i32,
	entry:   i32, // user entry in this chunk, or -1
	modules: [dynamic]i32,
	name:    string, // output file name; "" while the build has a single file
	exports: map[string]bool, // bindings other chunks import from this one

	// Saved copies of the graph's current-chunk state.
	externals:      [dynamic]BundleExternalImport,
	external_index: map[string]i32,
	order:          [dynamic]BundleEvent,
	interop_used:   [dynamic]string,
	chunk_imports:  map[string]i32,
	helpers_used:   bit_set[BundleHelper; u16],

	body:     string,
	segments: []BundleSegment,
}

// Make `index` the chunk that ordering and printing act on.
bundle_chunk_enter :: proc(g: ^BundleGraph, index: i32) {
	chunk := &g.chunks[index]
	g.current = index
	g.externals = chunk.externals
	g.external_index = chunk.external_index
	g.order = chunk.order
	g.interop_used = chunk.interop_used
	g.chunk_imports = chunk.chunk_imports
	g.helpers.used = chunk.helpers_used
}

bundle_chunk_leave :: proc(g: ^BundleGraph) {
	chunk := &g.chunks[g.current]
	chunk.externals = g.externals
	chunk.external_index = g.external_index
	chunk.order = g.order
	chunk.interop_used = g.interop_used
	chunk.chunk_imports = g.chunk_imports
	chunk.helpers_used = g.helpers.used
}

// Group modules by the set of roots that reach them. A root is a user entry
// or, with splitting, the target of a dynamic import. Each root costs one
// pass over the edges, so the work is bounded by roots * records.
bundle_chunks_assign :: proc(g: ^BundleGraph) {
	roots := make([dynamic]i32, g.alloc)
	is_root := make([]bool, len(g.modules), g.alloc)
	for entry in g.entries {
		append(&roots, entry)
		is_root[entry] = true
	}
	if g.options.splitting {
		for module in g.modules {
			for record in module.records {
				if record.kind != .Dynamic || record.target < 0 { continue }
				if is_root[record.target] { continue }
				is_root[record.target] = true
				append(&roots, record.target)
			}
		}
	}
	words := (len(roots) + 63) / 64
	reach := make([]u64, words * len(g.modules), g.alloc)
	pending := make([dynamic]i32, g.alloc)
	for root, bit in roots {
		append(&pending, root)
		reach[int(root) * words + bit / 64] |= 1 << uint(bit % 64)
		for len(pending) > 0 {
			module := g.modules[pop(&pending)]
			for record in module.records {
				// With splitting a dynamic import starts a root of its own.
				if record.target < 0 { continue }
				if record.kind == .Dynamic && g.options.splitting { continue }
				slot := &reach[int(record.target) * words + bit / 64]
				if slot^ & (1 << uint(bit % 64)) != 0 { continue }
				slot^ |= 1 << uint(bit % 64)
				append(&pending, record.target)
			}
		}
	}
	by_key := make(map[string]i32, g.alloc)
	for module in g.modules {
		bits := reach[int(module.index) * words:][:words]
		module.root_key = strings.clone(string(([^]u8)(raw_data(bits))[:words * 8]), g.alloc)
		index, found := by_key[module.root_key]
		if !found {
			index = i32(len(g.chunks))
			by_key[module.root_key] = index
			append(&g.chunks, bundle_chunk_make(g, index))
		}
		module.chunk = index
		append(&g.chunks[index].modules, module.index)
		if module.is_entry { bundle_chunk_set_entry(g, &g.chunks[index], module) }
	}
	for module in g.modules {
		for record in module.records {
			if record.kind != .Import || record.target < 0 { continue }
			target := g.modules[record.target]
			if target.chunk != module.chunk { target.cross_chunk = true }
		}
	}
	if len(g.chunks) > 1 && g.options.format != .ESM {
		bundle_error(g, nil, nil, "a build with more than one output file requires the esm format")
	}
}

@(private="file")
bundle_chunk_make :: proc(g: ^BundleGraph, index: i32) -> BundleChunk {
	return {
		index = index, entry = -1,
		modules = make([dynamic]i32, g.alloc),
		exports = make(map[string]bool, g.alloc),
		externals = make([dynamic]BundleExternalImport, g.alloc),
		external_index = make(map[string]i32, g.alloc),
		order = make([dynamic]BundleEvent, g.alloc),
		interop_used = make([dynamic]string, g.alloc),
		chunk_imports = make(map[string]i32, g.alloc),
	}
}

@(private="file")
bundle_chunk_set_entry :: proc(g: ^BundleGraph, chunk: ^BundleChunk, module: ^BundleModule) {
	if chunk.entry >= 0 {
		// Two entries reached by exactly the same roots import each other.
		// Their code would have to share one file and both be its entry.
		bundle_error(g, module, nil, "entries that import each other are not supported: '%s'",
			g.modules[chunk.entry].display)
		return
	}
	chunk.entry = module.index
}

bundle_imported_across_chunks :: proc(g: ^BundleGraph, module: ^BundleModule) -> bool {
	return module.cross_chunk
}

// Name every output file. A build with one chunk and a hoisted entry leaves
// the name to the caller. Names are unique within the output directory.
bundle_chunks_name :: proc(g: ^BundleGraph) {
	if len(g.chunks) == 1 && len(g.entries) == 1 { return }
	taken := make(map[string]bool, g.alloc)
	// Entry files first, so that they keep the name the user expects.
	for entry in g.entries {
		module := g.modules[entry]
		name := bundle_file_name(g, &taken, filepath.stem(filepath.base(module.path)))
		chunk := &g.chunks[module.chunk]
		// A wrapped entry gets a small file of its own that starts it; the
		// chunk that defines it is named like any other.
		if module.wrap == .None { chunk.name = name }
		g.entry_files[entry] = name
	}
	for &chunk in g.chunks {
		if chunk.name != "" { continue }
		stem := bundle_path_stem(g, g.modules[chunk.modules[0]].path)
		chunk.name = bundle_file_name(g, &taken, fmt.aprintf("chunk-%s", stem, allocator = g.alloc))
	}
	g.runtime_name = bundle_file_name(g, &taken, "chunk-runtime")
}

@(private="file")
bundle_file_name :: proc(g: ^BundleGraph, taken: ^map[string]bool, stem: string) -> string {
	// At most len(taken) names are in use, so one of that many plus one
	// numbered candidates is free.
	for suffix in 0..=len(taken) {
		name := fmt.aprintf("%s.mjs", stem, allocator = g.alloc)
		if suffix != 0 { name = fmt.aprintf("%s-%d.mjs", stem, suffix + 1, allocator = g.alloc) }
		if taken[name] { continue }
		taken[name] = true
		return name
	}
	panic("no free file name within the proven bound")
}

// Mention a binding that module `owner` defines at file scope. When the
// mention is printed into another chunk, that chunk imports the binding and
// the owner's chunk exports it.
bundle_chunk_ref :: proc(g: ^BundleGraph, owner: ^BundleModule, name: string) -> string {
	assert(name != "")
	if owner.chunk != g.current {
		g.chunk_imports[name] = owner.chunk
		g.chunks[owner.chunk].exports[name] = true
	}
	return name
}

bundle_wrapper_ref :: proc(g: ^BundleGraph, module: ^BundleModule) -> string {
	return bundle_chunk_ref(g, module, module.wrapper_name)
}

bundle_namespace_ref :: proc(g: ^BundleGraph, module: ^BundleModule) -> string {
	return bundle_chunk_ref(g, module, module.namespace_name)
}
