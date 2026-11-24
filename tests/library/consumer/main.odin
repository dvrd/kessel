// A small JSX "compiler front end" written against Kessel as an Odin
// package, the way a downstream framework uses it. It is the worked example
// behind the "Odin package" section of the README, kept compiling and
// correct by tests/verifiers/verify_library_consumer.js.
//
// Usage: consumer <file.jsx>
//
// For every JSX element in the file it prints the tag name, its position in
// editor coordinates, what the tag refers to, the function it sits in and
// its decoded string attributes; plus the hashbang and a source map with one
// mapping per element. The verifier compares all of it with oxc-parser and
// decodes the map with source-map-js.
//
// The API used, in order:
//   parse_job_open_inline / parse_job_run / parse_job_close   (parse_job.odin)
//   Program.hashbang                                          (ast.odin)
//   semantic_build, scope_query_*                             (scope_query.odin)
//   source_positions_*                                        (positions.odin)
//   ast_walk, ast_node_loc                                    (ast_walk.odin)
//   sourcemap_builder_*                                       (sourcemap_builder.odin)
package main

import "core:fmt"
import "core:os"
import "core:strings"

import kessel "../../../src"

// Everything the visitor needs, reached through `AstVisitor.user`.
Compiler :: struct {
	job:       ^kessel.ParseJob,
	model:     ^kessel.SemanticModel,
	query:     ^kessel.ScopeQuery,
	positions: ^kessel.SourcePositions,
	map_out:   ^kessel.SourceMapBuilder,
	source_id: u32,
	out:       strings.Builder,
	elements:  u32,
}

main :: proc() {
	if len(os.args) != 2 { fail("usage: consumer <file.jsx>") }
	bytes, read_error := os.read_entire_file_from_path(os.args[1], context.allocator)
	if read_error != nil { fail("cannot read the input file") }
	source := string(bytes)

	// 1. Parse. The job owns an arena that holds the whole AST.
	job: kessel.ParseJob
	config := kessel.ParseConfig{lang_override = kessel.Lang.JSX}
	if !kessel.parse_job_open_inline(&job, source, config, os.args[1]) { fail("open") }
	defer kessel.parse_job_close(&job)
	kessel.parse_job_run(&job)
	if len(job.parser.errors) != 0 { fail("the input has parse errors") }

	// 2. Scopes: the semantic model, then an index for queries by position.
	model := kessel.semantic_build(job.program, source, job.lang, job.arena_alloc)
	query: kessel.ScopeQuery
	kessel.scope_query_init(&query, &model, job.arena_alloc)
	defer kessel.scope_query_destroy(&query)

	// 3. Positions: byte offsets to lines and UTF-16 columns.
	positions: kessel.SourcePositions
	if !kessel.source_positions_init(&positions, source, context.allocator) { fail("positions") }
	defer kessel.source_positions_destroy(&positions)

	// 4. A source map for the code this "compiler" would emit.
	map_out: kessel.SourceMapBuilder
	kessel.sourcemap_builder_init(&map_out, context.allocator)
	defer kessel.sourcemap_builder_destroy(&map_out)
	map_out.file = "out.js"
	source_id, source_ok := kessel.sourcemap_builder_add_source(&map_out, "input.jsx", source)
	if !source_ok { fail("add_source") }

	compiler := Compiler{
		job = &job, model = &model, query = &query, positions = &positions,
		map_out = &map_out, source_id = source_id,
	}
	strings.builder_init(&compiler.out, context.allocator)
	defer strings.builder_destroy(&compiler.out)

	strings.write_string(&compiler.out, `{"hashbang":`)
	if hashbang, present := job.program.hashbang.?; present {
		kessel.write_json_string(&compiler.out, hashbang.value)
	} else {
		strings.write_string(&compiler.out, "null")
	}

	// 5. Walk. `enter` sees every node; this visitor acts on JSX elements.
	strings.write_string(&compiler.out, `,"elements":[`)
	visitor := kessel.AstVisitor{user = &compiler, enter = enter}
	status := kessel.ast_walk(job.program, visitor, context.allocator)
	fmt.sbprintf(&compiler.out, `],"status":%q,"map":`, fmt.tprint(status))

	map_json := kessel.sourcemap_builder_to_json(&map_out, context.allocator)
	defer delete(map_json)
	strings.write_string(&compiler.out, map_json)
	strings.write_byte(&compiler.out, '}')
	fmt.println(strings.to_string(compiler.out))
}

enter :: proc(user: rawptr, node: kessel.AstNode) -> kessel.AstWalkAction {
	compiler := cast(^Compiler)user
	element, is_element := node.(^kessel.JSXElement)
	if !is_element { return .Continue }
	name, is_identifier := element.opening_element.name.(kessel.JSXIdentifier)
	if !is_identifier { return .Continue }

	out := &compiler.out
	if compiler.elements > 0 { strings.write_byte(out, ',') }
	position := kessel.source_position_at(compiler.positions, name.loc.start)
	strings.write_string(out, `{"name":`)
	kessel.write_json_string(out, name.name)
	fmt.sbprintf(out, `,"line":%d,"column":%d`, position.line, position.column)

	// What does the tag refer to? An import or local component resolves to a
	// symbol; an intrinsic element such as `b` resolves to nothing.
	binding := "none"
	symbol := kessel.scope_query_symbol_at(compiler.query, name.loc)
	if symbol != kessel.SYMBOL_UNRESOLVED {
		binding = fmt.tprint(kessel.semantic_symbol(compiler.model, symbol).kind)
	}
	fmt.sbprintf(out, `,"binding":%q`, binding)

	// Which function is this element in?
	strings.write_string(out, `,"function":`)
	scope, inside := kessel.scope_query_enclosing_function(compiler.query, element.loc)
	if inside {
		start := kessel.semantic_scope(compiler.model, scope).node_start
		function_position := kessel.source_position_at(compiler.positions, start)
		fmt.sbprintf(out, `[%d,%d]`, function_position.line, function_position.column)
	} else {
		strings.write_string(out, "null")
	}

	// String attributes: `value` is entity-decoded, `raw` is the source text.
	strings.write_string(out, `,"attributes":{`)
	written := 0
	for attribute in element.opening_element.attributes {
		plain, is_plain := attribute.(kessel.JSXAttribute)
		if !is_plain { continue }
		key, key_is_identifier := plain.name.(kessel.JSXIdentifier)
		value, has_value := plain.value.?
		if !key_is_identifier || !has_value { continue }
		literal, is_string := value.(^kessel.StringLiteral)
		if !is_string { continue }
		if written > 0 { strings.write_byte(out, ',') }
		kessel.write_json_string(out, key.name)
		strings.write_byte(out, ':')
		kessel.write_json_string(out, literal.value)
		written += 1
	}
	strings.write_string(out, "}}")

	// One generated line per element, mapped back to the tag name. The map
	// counts lines from 0; `source_position_at` counts them from 1.
	name_id, name_ok := kessel.sourcemap_builder_add_name(compiler.map_out, name.name)
	mapping := kessel.SourceMapMapping{
		generated_line   = compiler.elements,
		generated_column = 0,
		source           = compiler.source_id,
		original_line    = position.line - 1,
		original_column  = position.column,
		name             = name_id,
	}
	if !name_ok || !kessel.sourcemap_builder_add_mapping(compiler.map_out, mapping) {
		return .Stop
	}
	compiler.elements += 1
	return .Continue
}

fail :: proc(message: string) -> ! {
	fmt.eprintfln("consumer: %s", message)
	os.exit(1)
}
