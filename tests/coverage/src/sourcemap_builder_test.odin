// The Source Map v3 builder (src/sourcemap_builder.odin).
//
// Method: these tests pin the serialised form byte for byte against values
// worked out by hand from the specification, including the published example
// VLQ values, so the encoder is checked without trusting a decoder. The
// decoding direction — a real consumer reading the map back — is covered by
// tests/verifiers/verify_sourcemap_builder.js with `source-map-js`.
package coverage

import "core:strings"
import "core:testing"

import kessel "../../../src"

// VLQ values from the specification and the usual reference tables:
// 0 -> A, 1 -> C, -1 -> D, 15 -> e, 16 -> gB, -16 -> hB, 123 -> 2H,
// 2^30 - 1 (the largest coordinate) -> +/////B.
@(test)
test_sourcemap_vlq_values :: proc(t: ^testing.T) {
	Case :: struct { value: i64, want: string }
	cases := [?]Case{
		{0, "A"}, {1, "C"}, {-1, "D"}, {15, "e"}, {-15, "f"}, {16, "gB"}, {-16, "hB"},
		{123, "2H"}, {1 << 30 - 1, "+/////B"}, {-(1 << 30 - 1), "//////B"},
	}
	for vlq_case in cases {
		out := strings.builder_make()
		defer strings.builder_destroy(&out)
		kessel.sourcemap_write_vlq(&out, vlq_case.value)
		testing.expect_value(t, strings.to_string(out), vlq_case.want)
	}
}

@(test)
test_sourcemap_builder_serialises_v3 :: proc(t: ^testing.T) {
	builder: kessel.SourceMapBuilder
	kessel.sourcemap_builder_init(&builder, context.allocator)
	defer kessel.sourcemap_builder_destroy(&builder)

	builder.file = "out.js"
	first, first_ok := kessel.sourcemap_builder_add_source(&builder, "a.jsx", "let a;\n")
	second, second_ok := kessel.sourcemap_builder_add_source(&builder, "b \"q\".js")
	testing.expect(t, first_ok && second_ok)
	testing.expect_value(t, first, 0)
	testing.expect_value(t, second, 1)
	render, _ := kessel.sourcemap_builder_add_name(&builder, "render")
	again, _ := kessel.sourcemap_builder_add_name(&builder, "render")
	other, _ := kessel.sourcemap_builder_add_name(&builder, "state")
	testing.expect_value(t, render, 0)
	testing.expect_value(t, again, 0)
	testing.expect_value(t, other, 1)

	NONE :: kessel.SOURCEMAP_NO_NAME
	mappings := [?]kessel.SourceMapMapping{
		// Added out of order on purpose: line 2 before line 0.
		{2, 4, second, 1, 0, other},
		{0, 0, first, 0, 0, NONE},
		{0, 8, first, 0, 4, render},
		{0, 12, kessel.SOURCEMAP_NO_SOURCE, 0, 0, NONE},
		{2, 0, first, 3, 2, NONE},
	}
	for mapping in mappings {
		testing.expect(t, kessel.sourcemap_builder_add_mapping(&builder, mapping))
	}

	json := kessel.sourcemap_builder_to_json(&builder, context.allocator)
	defer delete(json)
	// Line 0: [0,0,0,0] [8,0,0,4,name 0] [4]; line 1 empty;
	// line 2: [0,0,+3,-2] [4,+1,-2,-2,name +1].
	want := `{"version":3,"file":"out.js","sources":["a.jsx","b \"q\".js"],` +
	        `"sourcesContent":["let a;\n",null],"names":["render","state"],` +
	        `"mappings":"AAAA,QAAIA,I;;AAGF,ICFFC"}`
	testing.expect_value(t, json, want)

	// Serialising again gives the same bytes: sorting is idempotent.
	second_json := kessel.sourcemap_builder_to_json(&builder, context.allocator)
	defer delete(second_json)
	testing.expect_value(t, second_json, want)
}

@(test)
test_sourcemap_builder_minimal_and_rejections :: proc(t: ^testing.T) {
	builder: kessel.SourceMapBuilder
	kessel.sourcemap_builder_init(&builder, context.allocator)
	defer kessel.sourcemap_builder_destroy(&builder)

	// No file, no source root, no content: those keys are left out.
	empty := kessel.sourcemap_builder_to_json(&builder, context.allocator)
	defer delete(empty)
	testing.expect_value(t, empty, `{"version":3,"sources":[],"names":[],"mappings":""}`)

	NONE :: kessel.SOURCEMAP_NO_NAME
	add :: kessel.sourcemap_builder_add_mapping
	// A source index that was never registered.
	testing.expect(t, !add(&builder, {0, 0, 0, 0, 0, NONE}))
	source, _ := kessel.sourcemap_builder_add_source(&builder, "a.js")
	// A name index that was never registered.
	testing.expect(t, !add(&builder, {0, 0, source, 0, 0, 7}))
	// A name without a source cannot be encoded.
	name, _ := kessel.sourcemap_builder_add_name(&builder, "n")
	testing.expect(t, !add(&builder, {0, 0, kessel.SOURCEMAP_NO_SOURCE, 0, 0, name}))
	// Coordinates above the limit.
	over := u32(kessel.SOURCEMAP_COORDINATE_MAX) + 1
	testing.expect(t, !add(&builder, {over, 0, source, 0, 0, NONE}))
	testing.expect(t, !add(&builder, {0, over, source, 0, 0, NONE}))
	testing.expect(t, !add(&builder, {0, 0, source, over, 0, NONE}))
	testing.expect(t, !add(&builder, {0, 0, source, 0, over, NONE}))
	testing.expect_value(t, len(builder.mappings), 0)

	// The limit itself is accepted and encodes.
	limit := u32(kessel.SOURCEMAP_COORDINATE_MAX)
	testing.expect(t, add(&builder, {0, limit, source, limit, limit, NONE}))
	builder.source_root = "/src"
	json := kessel.sourcemap_builder_to_json(&builder, context.allocator)
	defer delete(json)
	testing.expect_value(
		t, json,
		`{"version":3,"sourceRoot":"/src","sources":["a.js"],"names":["n"],` +
		`"mappings":"+/////BA+/////B+/////B"}`,
	)
}
