// A consumer of the Kessel package building a source map with
// `SourceMapBuilder`, for tests/verifiers/verify_sourcemap_builder.js.
//
// It prints one JSON object: `map` is the serialised Source Map v3 and
// `expected` lists the mappings that went in, sorted by generated position.
// The verifier decodes `map` with `source-map-js` and requires the decoded
// mappings to equal `expected` field for field, so the round trip is checked
// by a decoder that shares no code with the encoder.
//
// The mappings cover what a compiler emits: two sources (one with embedded
// content), deduplicated names, unmapped segments, segments added out of
// order, empty generated lines, negative deltas in every field, and columns
// beyond an astral character (columns are UTF-16 code units).
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import kessel "../../../src"

NONE :: kessel.SOURCEMAP_NO_NAME

Entry :: struct {
	generated_line:   u32,
	generated_column: u32,
	source:           string, // "" for an unmapped segment
	original_line:    u32,
	original_column:  u32,
	name:             string, // "" for no name
}

ENTRIES := [?]Entry{
	{5, 2, "src/b.js", 0, 0, ""},
	{0, 0, "src/a.jsx", 0, 0, ""},
	{0, 6, "src/a.jsx", 0, 6, "App"},
	{0, 40, "", 0, 0, ""},
	{1, 4, "src/a.jsx", 12, 30, "render"},
	{1, 9, "src/a.jsx", 2, 3, "App"},
	{1, 20, "src/b.js", 100, 0, "render"},
	{5, 0, "src/a.jsx", 3, 17, ""},
	{5, 300, "src/b.js", 99, 65537, "useState"},
	{9, 1, "", 0, 0, ""},
}

main :: proc() {
	builder: kessel.SourceMapBuilder
	kessel.sourcemap_builder_init(&builder, context.allocator)
	defer kessel.sourcemap_builder_destroy(&builder)

	builder.file = "out/bundle.js"
	builder.source_root = "/project"
	content := "const App = () => \"\U0001F600\";\n"
	source_a, a_ok := kessel.sourcemap_builder_add_source(&builder, "src/a.jsx", content)
	source_b, b_ok := kessel.sourcemap_builder_add_source(&builder, "src/b.js")
	if !a_ok || !b_ok { fail("add_source") }

	for entry in ENTRIES {
		mapping := kessel.SourceMapMapping{
			generated_line   = entry.generated_line,
			generated_column = entry.generated_column,
			source           = kessel.SOURCEMAP_NO_SOURCE,
			name             = NONE,
		}
		if entry.source != "" {
			mapping.source = source_a if entry.source == "src/a.jsx" else source_b
			mapping.original_line = entry.original_line
			mapping.original_column = entry.original_column
		}
		if entry.name != "" {
			name, name_ok := kessel.sourcemap_builder_add_name(&builder, entry.name)
			if !name_ok { fail("add_name") }
			mapping.name = name
		}
		if !kessel.sourcemap_builder_add_mapping(&builder, mapping) { fail("add_mapping") }
	}

	json := kessel.sourcemap_builder_to_json(&builder, context.allocator)
	defer delete(json)

	sorted := ENTRIES
	slice.stable_sort_by(sorted[:], proc(a, b: Entry) -> bool {
		if a.generated_line != b.generated_line { return a.generated_line < b.generated_line }
		return a.generated_column < b.generated_column
	})
	out := strings.builder_make()
	defer strings.builder_destroy(&out)
	strings.write_string(&out, `{"map":`)
	strings.write_string(&out, json)
	strings.write_string(&out, `,"content":`)
	kessel.write_json_string(&out, content)
	strings.write_string(&out, `,"expected":[`)
	for entry, index in sorted {
		if index > 0 { strings.write_byte(&out, ',') }
		fmt.sbprintf(
			&out, `[%d,%d,%q,%d,%d,%q]`,
			entry.generated_line, entry.generated_column, entry.source,
			entry.original_line, entry.original_column, entry.name,
		)
	}
	strings.write_string(&out, "]}")
	fmt.println(strings.to_string(out))
}

fail :: proc(step: string) -> ! {
	fmt.eprintfln("sourcemap_roundtrip: %s failed", step)
	os.exit(1)
}
