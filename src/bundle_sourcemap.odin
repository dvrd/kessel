package kessel

// Multi-source source maps for bundles. The printer records
// (bundle offset, link-source offset) pairs per module; this file carries
// them back through the transformer's map to the text the user wrote and
// through the minifier's map forward to the final output.

import "core:path/filepath"
import "core:slice"
import "core:strings"

// One mapped position: output offset `gen` came from offset `src` of the
// original text of `module`. `limit` is the end of the printed segment the
// mapping belongs to, so offsets past it (helpers, glue) stay unmapped.
BundleMapping :: struct {
	gen:    u32,
	limit:  u32,
	module: i32,
	src:    u32,
}

bundle_map_collect :: proc(
	g: ^BundleGraph,
	segments: []BundleSegment,
	shift: u32,
) -> []BundleMapping {
	mappings := make([dynamic]BundleMapping, g.alloc)
	for segment in segments {
		module := g.modules[segment.module]
		limit := shift + segment.base + segment.size
		for record in segment.records {
			original, mapped := bundle_original_offset(module, record.src_offset)
			if !mapped { continue }
			append(&mappings, BundleMapping{
				gen = shift + segment.base + record.gen_offset, limit = limit,
				module = segment.module, src = original,
			})
		}
	}
	// Segments are appended in output order, but the printer may record a
	// nested node before its parent's position.
	slice.stable_sort_by(mappings[:], proc(a, b: BundleMapping) -> bool { return a.gen < b.gen })
	return mappings[:]
}

// Re-express `outer` records (minified offset to bundle offset) as mappings
// into the original sources. The mapping in force at a bundle offset is the
// last one at or before it, provided the offset is still inside its segment.
bundle_map_compose :: proc(
	g: ^BundleGraph,
	inner: []BundleMapping,
	outer: []SourceMapRecord,
) -> []BundleMapping {
	if len(inner) == 0 { return nil }
	composed := make([dynamic]BundleMapping, 0, len(outer), g.alloc)
	for record in outer {
		lo, hi := 0, len(inner)
		for lo < hi {
			mid := (lo + hi) / 2
			if inner[mid].gen <= record.src_offset { lo = mid + 1 } else { hi = mid }
		}
		if lo == 0 { continue }
		source := inner[lo - 1]
		if record.src_offset >= source.limit { continue }
		append(&composed, BundleMapping{
			gen = record.gen_offset, limit = max(u32), module = source.module, src = source.src,
		})
	}
	slice.stable_sort_by(composed[:], proc(a, b: BundleMapping) -> bool { return a.gen < b.gen })
	return composed[:]
}

bundle_map_json :: proc(g: ^BundleGraph, mappings: []BundleMapping, code: string) -> string {
	// Sources are numbered in order of first appearance in the output.
	source_index := make(map[i32]int, g.alloc)
	sources := make([dynamic]i32, g.alloc)
	for mapping in mappings {
		if mapping.module not_in source_index {
			source_index[mapping.module] = len(sources)
			append(&sources, mapping.module)
		}
	}
	builder := strings.builder_make(g.alloc)
	strings.write_string(&builder, `{"version":3,"sources":[`)
	for module, index in sources {
		if index != 0 { strings.write_byte(&builder, ',') }
		write_json_string(&builder, bundle_map_source_path(g, g.modules[module]))
	}
	strings.write_string(&builder, `],"sourcesContent":[`)
	for module, index in sources {
		if index != 0 { strings.write_byte(&builder, ',') }
		write_json_string(&builder, g.modules[module].original)
	}
	strings.write_string(&builder, `],"names":[],"mappings":`)
	write_json_string(&builder, bundle_map_encode(g, mappings, code, sources[:], source_index))
	strings.write_byte(&builder, '}')
	return strings.to_string(builder)
}

// A map's `sources` are resolved against the map file's own location. Both
// paths are absolute, so the relative form is: one `..` per directory of the
// map's location below the common prefix, then the rest of the module path.
@(private="file")
bundle_map_source_path :: proc(g: ^BundleGraph, module: ^BundleModule) -> string {
	base := g.options.map_directory
	if base == "" || !filepath.is_abs(module.path) { return module.display }
	from := strings.split(strings.trim_suffix(base, "/"), "/", g.alloc)
	to := strings.split(module.path, "/", g.alloc)
	common := 0
	for common < len(from) && common < len(to) - 1 && from[common] == to[common] { common += 1 }
	builder := strings.builder_make(g.alloc)
	for _ in common..<len(from) { strings.write_string(&builder, "../") }
	for part, index in to[common:] {
		if index != 0 { strings.write_byte(&builder, '/') }
		strings.write_string(&builder, part)
	}
	return strings.to_string(builder)
}

@(private="file")
bundle_map_encode :: proc(
	g: ^BundleGraph,
	mappings: []BundleMapping,
	code: string,
	sources: []i32,
	source_index: map[i32]int,
) -> string {
	gen_lines := source_line_offsets(code, g.alloc)
	src_lines := make([][]u32, len(sources), g.alloc)
	src_positions := make([]SourceMapPosition, len(sources), g.alloc)
	for module, index in sources {
		src_lines[index] = source_line_offsets(g.modules[module].original, g.alloc)
	}

	builder := strings.builder_make(g.alloc)
	scratch := make([dynamic]byte, 0, 16, g.alloc)
	gen_position: SourceMapPosition
	previous_gen_line: u32 = 0
	previous_gen_col, previous_source, previous_src_line, previous_src_col: i64
	first_on_line := true
	for mapping in mappings {
		gen_line, gen_col := sourcemap_position_at(code, gen_lines, mapping.gen, &gen_position)
		for previous_gen_line < gen_line {
			strings.write_byte(&builder, ';')
			previous_gen_line += 1
			previous_gen_col = 0
			first_on_line = true
		}
		if !first_on_line { strings.write_byte(&builder, ',') }
		first_on_line = false
		source := source_index[mapping.module]
		text := g.modules[mapping.module].original
		src_line, src_col := sourcemap_position_at(text, src_lines[source], mapping.src,
			&src_positions[source])
		clear(&scratch)
		vlq_encode_into(&scratch, int(i64(gen_col) - previous_gen_col))
		vlq_encode_into(&scratch, int(i64(source) - previous_source))
		vlq_encode_into(&scratch, int(i64(src_line) - previous_src_line))
		vlq_encode_into(&scratch, int(i64(src_col) - previous_src_col))
		strings.write_bytes(&builder, scratch[:])
		previous_gen_col = i64(gen_col)
		previous_source = i64(source)
		previous_src_line = i64(src_line)
		previous_src_col = i64(src_col)
	}
	return strings.to_string(builder)
}
