package kessel

// ============================================================================
// sourcemap_builder.odin — Source Map v3 builder for library consumers
// ============================================================================
//
// Spec: https://tc39.es/source-map/
//
// `sourcemap.odin` maps Kessel's own printer output back to one source. A
// consumer that generates code itself (a framework compiler, a bundler)
// needs the general form: several sources, symbol names, and mappings it
// positions itself. This is that form, on the same VLQ encoder:
//
//   builder: SourceMapBuilder
//   sourcemap_builder_init(&builder, allocator)
//   defer sourcemap_builder_destroy(&builder)
//
//   builder.file = "out.js"
//   source, _ := sourcemap_builder_add_source(&builder, "src/app.jsx", source_text)
//   name, _   := sourcemap_builder_add_name(&builder, "render")
//   ok := sourcemap_builder_add_mapping(&builder, SourceMapMapping{
//       generated_line = 0, generated_column = 4,
//       source = source, original_line = 2, original_column = 8,
//       name = name,
//   })
//   json := sourcemap_builder_to_json(&builder, allocator)
//
// Conventions, as in the specification: lines and columns are 0-based and
// columns count UTF-16 code units. `source_position_at` (positions.odin)
// yields 1-based lines, so subtract one from its `line`.
//
// Mappings may be added in any order; they are sorted by generated position
// when the map is serialised (a stable sort, so mappings added for the same
// generated position keep their order). Adding them in generated order, the
// natural order for a printer, skips the sort.
//
// Strings (`file`, `source_root`, source names, source contents, names) are
// borrowed: the caller keeps them alive until the map has been serialised.

import "core:mem"
import "core:slice"
import "core:strings"

// A mapping without a source uses SOURCEMAP_NO_SOURCE and marks generated
// code that corresponds to no original position. A mapping without a symbol
// name uses SOURCEMAP_NO_NAME.
SOURCEMAP_NO_SOURCE :: max(u32)
SOURCEMAP_NO_NAME   :: max(u32)

// Largest line, column, source index or name index a mapping may carry.
// Deltas between two such values fit the VLQ encoder's 32-bit range with
// room to spare; real files are orders of magnitude below it.
SOURCEMAP_COORDINATE_MAX :: 1 << 30 - 1

SourceMapMapping :: struct {
	generated_line:   u32, // 0-based
	generated_column: u32, // 0-based, UTF-16 code units
	source:           u32, // index from sourcemap_builder_add_source, or SOURCEMAP_NO_SOURCE
	original_line:    u32, // 0-based; ignored without a source
	original_column:  u32, // 0-based, UTF-16 code units; ignored without a source
	name:             u32, // index from sourcemap_builder_add_name, or SOURCEMAP_NO_NAME
}

SourceMapBuilder :: struct {
	// Optional `file` and `sourceRoot` fields; omitted from the JSON when "".
	file:        string,
	source_root: string,

	sources:          [dynamic]string,
	sources_content:  [dynamic]Maybe(string),
	names:            [dynamic]string,
	name_indices:     map[string]u32,
	mappings:         [dynamic]SourceMapMapping,
	// True while every mapping was added at or after the previous one.
	mappings_ordered: bool,
	allocator:        mem.Allocator,
}

sourcemap_builder_init :: proc(builder: ^SourceMapBuilder, allocator: mem.Allocator) {
	assert(builder != nil)
	builder^ = SourceMapBuilder{
		sources          = make([dynamic]string, allocator),
		sources_content  = make([dynamic]Maybe(string), allocator),
		names            = make([dynamic]string, allocator),
		name_indices     = make(map[string]u32, allocator),
		mappings         = make([dynamic]SourceMapMapping, allocator),
		mappings_ordered = true,
		allocator        = allocator,
	}
}

sourcemap_builder_destroy :: proc(builder: ^SourceMapBuilder) {
	assert(builder != nil)
	delete(builder.sources)
	delete(builder.sources_content)
	delete(builder.names)
	delete(builder.name_indices)
	delete(builder.mappings)
	builder^ = {}
}

// Register a source file and return its index for `SourceMapMapping.source`.
// `content`, when given, is embedded as its `sourcesContent` entry. Each call
// adds an entry; register a file once and reuse the index.
sourcemap_builder_add_source :: proc(
	builder: ^SourceMapBuilder,
	name: string,
	content: Maybe(string) = nil,
) -> (index: u32, ok: bool) {
	assert(len(builder.sources) == len(builder.sources_content))
	if len(builder.sources) >= SOURCEMAP_COORDINATE_MAX { return 0, false }
	index = u32(len(builder.sources))
	if _, error := append(&builder.sources, name); error != nil { return 0, false }
	if _, error := append(&builder.sources_content, content); error != nil {
		pop(&builder.sources)
		return 0, false
	}
	return index, true
}

// Register a symbol name and return its index for `SourceMapMapping.name`.
// The same name always gets the same index.
sourcemap_builder_add_name :: proc(
	builder: ^SourceMapBuilder,
	name: string,
) -> (index: u32, ok: bool) {
	if existing, found := builder.name_indices[name]; found { return existing, true }
	if len(builder.names) >= SOURCEMAP_COORDINATE_MAX { return 0, false }
	index = u32(len(builder.names))
	if _, error := append(&builder.names, name); error != nil { return 0, false }
	builder.name_indices[name] = index
	return index, true
}

// Add one mapping. Returns false, adding nothing, when the mapping refers to
// a source or name that was not registered, names a symbol without a source
// (the format cannot express that), or carries a coordinate above
// SOURCEMAP_COORDINATE_MAX.
sourcemap_builder_add_mapping :: proc(
	builder: ^SourceMapBuilder,
	mapping: SourceMapMapping,
) -> bool {
	if mapping.generated_line > SOURCEMAP_COORDINATE_MAX { return false }
	if mapping.generated_column > SOURCEMAP_COORDINATE_MAX { return false }
	if mapping.source == SOURCEMAP_NO_SOURCE {
		if mapping.name != SOURCEMAP_NO_NAME { return false }
	} else {
		if int(mapping.source) >= len(builder.sources) { return false }
		if mapping.original_line > SOURCEMAP_COORDINATE_MAX { return false }
		if mapping.original_column > SOURCEMAP_COORDINATE_MAX { return false }
		if mapping.name != SOURCEMAP_NO_NAME {
			if int(mapping.name) >= len(builder.names) { return false }
		}
	}

	if count := len(builder.mappings); count > 0 {
		if sourcemap_mapping_before(mapping, builder.mappings[count - 1]) {
			builder.mappings_ordered = false
		}
	}
	_, error := append(&builder.mappings, mapping)
	return error == nil
}

// Serialise the map as Source Map v3 JSON. The result is allocated with
// `allocator` and owned by the caller. Sorts the builder's mappings in place
// when they were not added in generated order; the builder stays usable.
sourcemap_builder_to_json :: proc(builder: ^SourceMapBuilder, allocator: mem.Allocator) -> string {
	assert(len(builder.sources) == len(builder.sources_content))
	if !builder.mappings_ordered {
		slice.stable_sort_by(builder.mappings[:], sourcemap_mapping_before)
		builder.mappings_ordered = true
	}

	out := strings.builder_make(allocator)
	strings.write_string(&out, `{"version":3`)
	if builder.file != "" {
		strings.write_string(&out, `,"file":`)
		write_json_string(&out, builder.file)
	}
	if builder.source_root != "" {
		strings.write_string(&out, `,"sourceRoot":`)
		write_json_string(&out, builder.source_root)
	}

	strings.write_string(&out, `,"sources":[`)
	for source, index in builder.sources {
		if index > 0 { strings.write_byte(&out, ',') }
		write_json_string(&out, source)
	}
	strings.write_byte(&out, ']')

	has_content := false
	for content in builder.sources_content {
		if content != nil { has_content = true }
	}
	if has_content {
		strings.write_string(&out, `,"sourcesContent":[`)
		for content, index in builder.sources_content {
			if index > 0 { strings.write_byte(&out, ',') }
			if text, present := content.?; present {
				write_json_string(&out, text)
			} else {
				strings.write_string(&out, "null")
			}
		}
		strings.write_byte(&out, ']')
	}

	strings.write_string(&out, `,"names":[`)
	for name, index in builder.names {
		if index > 0 { strings.write_byte(&out, ',') }
		write_json_string(&out, name)
	}
	strings.write_string(&out, `],"mappings":"`)
	// Base64 VLQ digits, `,` and `;` need no JSON escaping.
	state: SourceMapSegmentState
	for mapping in builder.mappings { sourcemap_write_segment(&out, &state, mapping) }
	strings.write_string(&out, `"}`)
	return strings.to_string(out)
}

// Running state of the `mappings` encoder: every field of a segment is
// stored as a delta. The generated column restarts on each generated line;
// source, original position and name carry over the whole map.
SourceMapSegmentState :: struct {
	generated_line:   u32,
	generated_column: i64,
	source:           i64,
	original_line:    i64,
	original_column:  i64,
	name:             i64,
	line_has_segment: bool,
}

// Append one segment to `out`. Mappings must arrive in generated order.
sourcemap_write_segment :: proc(
	out: ^strings.Builder,
	state: ^SourceMapSegmentState,
	mapping: SourceMapMapping,
) {
	assert(mapping.generated_line >= state.generated_line)
	for state.generated_line < mapping.generated_line {
		strings.write_byte(out, ';')
		state.generated_line += 1
		state.generated_column = 0
		state.line_has_segment = false
	}
	if state.line_has_segment { strings.write_byte(out, ',') }
	state.line_has_segment = true

	sourcemap_write_vlq(out, i64(mapping.generated_column) - state.generated_column)
	state.generated_column = i64(mapping.generated_column)
	if mapping.source == SOURCEMAP_NO_SOURCE {
		assert(mapping.name == SOURCEMAP_NO_NAME)
		return
	}

	sourcemap_write_vlq(out, i64(mapping.source) - state.source)
	sourcemap_write_vlq(out, i64(mapping.original_line) - state.original_line)
	sourcemap_write_vlq(out, i64(mapping.original_column) - state.original_column)
	state.source          = i64(mapping.source)
	state.original_line   = i64(mapping.original_line)
	state.original_column = i64(mapping.original_column)
	if mapping.name == SOURCEMAP_NO_NAME { return }

	sourcemap_write_vlq(out, i64(mapping.name) - state.name)
	state.name = i64(mapping.name)
}

// One Base64 VLQ value: sign in the lowest bit, then 5 bits per digit, low
// bits first, with bit 6 of a digit marking that another digit follows.
sourcemap_write_vlq :: proc(out: ^strings.Builder, value: i64) {
	magnitude := u64(-value) if value < 0 else u64(value)
	assert(magnitude <= u64(max(u32)))
	remaining := magnitude << 1
	if value < 0 { remaining |= 1 }
	// 33 significant bits at most, so at most 7 digits.
	for _ in 0..<7 {
		digit := u8(remaining & 0x1f)
		remaining >>= 5
		if remaining != 0 { digit |= 0x20 }
		strings.write_byte(out, B64[digit])
		if remaining == 0 { return }
	}
	unreachable()
}

// Generated-position order; mappings at the same position compare equal.
sourcemap_mapping_before :: proc(a, b: SourceMapMapping) -> bool {
	if a.generated_line != b.generated_line { return a.generated_line < b.generated_line }
	return a.generated_column < b.generated_column
}
