package coverage

import "core:testing"

import kessel "../../../src"

@(test)
test_module_lexer_dependencies :: proc(t: ^testing.T) {
	source := "/* import('ignored') */\n" +
	          "const object = { import() {}, export() {} };\n" +
	          "class C { import(a, b) {} }\n" +
	          "const text = \"export * from 'ignored'\";\n" +
	          "const pattern = /import('ignored')/;\n" +
	          "if (flag) /import('ignored')/.test(text);\n" +
	          "obj.import('ignored'); obj?.export;\n" +
	          "import '\\u0061';\n" +
	          "import from from 'default-binding';\n" +
	          "import { type as value, named } from 'b';\n" +
	          "export { value, named as \"string-name\" };\n" +
	          "export { named as next } from 'c';\n" +
	          "export * as namespace from 'd';\n" +
	          "const nested = import(build(import('inner')), { with: { type: 'json' } });\n" +
	          "const another = import('computed' + '.js');\n" +
	          "const templated = import(`item-${lookup('x', 'y')}`);\n" +
	          "import data from 'config' with { type: 'json' };\n" +
	          "import type { Options } from 'types';\n" +
	          "export type { Result } from 'types';\n" +
	          "export default function main() {}\n" +
	          "export async function * iterate() {}\n" +
	          "export class Store {}\n" +
	          "export const answer = 42;\n" +
	          "const meta = import.meta.url;\n"
	result, err := kessel.module_lex_dependencies(source, context.allocator)
	if !testing.expect_value(t, err, .None) { return }
	defer kessel.module_lex_destroy(&result)
	testing.expect_value(t, result.has_module_syntax, true)
	cases := [?]struct {
		kind: kessel.ModuleDependencyKind,
		raw, statement: string,
		name: Maybe(string),
	}{
		{.Static, "\\u0061", "import '\\u0061';", "a"},
		{.Static, "default-binding", "import from from 'default-binding';", "default-binding"},
		{.Static, "b", "import { type as value, named } from 'b';", "b"},
		{.Reexport, "c", "export { named as next } from 'c';", "c"},
		{.Reexport, "d", "export * as namespace from 'd';", "d"},
		{.Dynamic, "build(import('inner'))", "import(build(import('inner')), { with: { type: 'json' } })", nil},
		{.Dynamic, "'inner'", "import('inner')", "inner"},
		{.Dynamic, "'computed' + '.js'", "import('computed' + '.js')", nil},
		{.Dynamic, "`item-${lookup('x', 'y')}`", "import(`item-${lookup('x', 'y')}`)", nil},
		{.Static, "config", "import data from 'config' with { type: 'json' };", "config"},
		{.Static, "types", "import type { Options } from 'types';", "types"},
		{.Reexport, "types", "export type { Result } from 'types';", "types"},
		{.Import_Meta, "", "import.meta", nil},
	}
	if !testing.expect_value(t, len(result.dependencies), len(cases)) {
		for entry in result.dependencies {
			testing.expectf(t, false, "%v %q", entry.kind, source[entry.statement.start:entry.statement.end])
		}
		return
	}
	for expected, index in cases {
		entry := result.dependencies[index]
		testing.expect_value(t, entry.kind, expected.kind)
		testing.expect_value(t, source[entry.statement.start:entry.statement.end], expected.statement)
		testing.expect_value(t, source[entry.request.start:entry.request.end], expected.raw)
		testing.expect_value(t, entry.name, expected.name)
	}
	attribute_entries := [?]int{5, 9}
	for index in attribute_entries {
		entry := result.dependencies[index]
		if !testing.expect_value(t, entry.attributes != nil, true) { return }
		attributes := entry.attributes.?
		expected := "{ with: { type: 'json' } }" if index == 5 else "{ type: 'json' }"
		testing.expect_value(t, source[attributes.start:attributes.end], expected)
	}
	testing.expect_value(t, result.dependencies[10].type_only, true)
	testing.expect_value(t, result.dependencies[11].type_only, true)
	testing.expect_value(t, result.dependencies[2].type_only, false)
	exports := [?]string{"value", "string-name", "next", "namespace", "Result", "default", "iterate", "Store", "answer"}
	if !testing.expect_value(t, len(result.exports), len(exports)) { return }
	for name, index in exports {
		entry := result.exports[index]
		testing.expect_value(t, entry.name, name)
		testing.expect_value(t, source[entry.span.start:entry.span.end], name)
		testing.expect_value(t, entry.type_only, name == "Result")
	}
}

@(test)
test_module_lexer_script_and_invalid :: proc(t: ^testing.T) {
	result, err := kessel.module_lex_dependencies("const loaded = import('');", context.allocator)
	if !testing.expect_value(t, err, .None) { return }
	defer kessel.module_lex_destroy(&result)
	testing.expect_value(t, result.has_module_syntax, false)
	if !testing.expect_value(t, len(result.dependencies), 1) { return }
	testing.expect_value(t, result.dependencies[0].name, Maybe(string)(""))
	_, invalid := kessel.module_lex_dependencies("import('unterminated'", context.allocator)
	testing.expect_value(t, invalid, .Invalid_Syntax)
	_, no_request := kessel.module_lex_dependencies("import()", context.allocator)
	testing.expect_value(t, no_request, .Invalid_Syntax)
}


@(test)
test_module_lexer_import_phases :: proc(t: ^testing.T) {
	source := "import source bytes from 'wasm'; " +
	          "import defer * as ns from 'lazy'; " +
	          "import source from from 'keyword'; " +
	          "import source from 'ordinary-source'; " +
	          "import defer from 'ordinary-defer'; " +
	          "import type from 'ordinary-type'; " +
	          "const values = [import.source('other-wasm'), import.defer('other-lazy'), import('other')];"
	result, err := kessel.module_lex_dependencies(source, context.allocator)
	if !testing.expect_value(t, err, .None) { return }
	defer kessel.module_lex_destroy(&result)
	expected := [?]struct {name: string, phase: kessel.ModuleImportPhase}{
		{"wasm", .Source}, {"lazy", .Defer}, {"keyword", .Source},
		{"ordinary-source", .Evaluation}, {"ordinary-defer", .Evaluation}, {"ordinary-type", .Evaluation},
		{"other-wasm", .Source}, {"other-lazy", .Defer}, {"other", .Evaluation},
	}
	if !testing.expect_value(t, len(result.dependencies), len(expected)) { return }
	for item, index in expected {
		record := result.dependencies[index]
		testing.expect_value(t, record.name, Maybe(string)(item.name))
		testing.expect_value(t, record.phase, item.phase)
		testing.expect_value(t, record.type_only, false)
	}
}

@(test)
test_module_lexer_export_bindings :: proc(t: ^testing.T) {
	source := "export const [first,, {nested: leaf = import('leaf')}, ...rest] = contents, second = 2;\n" +
	          "export let {shorthand = 1, [key(import('key'))]: computed, 3: numeric, ...spread} = values;\n" +
	          "export const typed: Map<string, number> = load(), next = 4;\n" +
	          "export const generic = invoke<Map<string, number>, boolean>(), following = 8;\n" +
	          "export const compared = a < b, greater = d > (e);\n" +
	          "export const asi = 1\nconsume(1), unrelated = 2;\n" +
	          "export const continued =\n import('after-line'), another = 5;\n" +
	          "export {first as 'first-item'};\n" +
	          "export {remote as forwarded} from 'upstream';\n" +
	          "export * as namespace from 'namespace';\n" +
	          "export default async function * implementation() {}\n"
	result, err := kessel.module_lex_dependencies(source, context.allocator)
	if !testing.expect_value(t, err, .None) { return }
	defer kessel.module_lex_destroy(&result)
	expected := [?]struct {
		name: string,
		local: Maybe(string),
	}{
		{"first", "first"}, {"leaf", "leaf"}, {"rest", "rest"}, {"second", "second"},
		{"shorthand", "shorthand"}, {"computed", "computed"}, {"numeric", "numeric"}, {"spread", "spread"},
		{"typed", "typed"}, {"next", "next"}, {"generic", "generic"}, {"following", "following"},
		{"compared", "compared"}, {"greater", "greater"}, {"asi", "asi"}, {"continued", "continued"}, {"another", "another"},
		{"first-item", "first"}, {"forwarded", nil}, {"namespace", nil}, {"default", "implementation"},
	}
	if !testing.expect_value(t, len(result.exports), len(expected)) { return }
	for item, index in expected {
		entry := result.exports[index]
		testing.expect_value(t, entry.name, item.name)
		testing.expect_value(t, entry.local_name, item.local)
		testing.expect_value(t, source[entry.span.start:entry.span.end], item.name)
		if local, ok := item.local.?; ok {
			if !testing.expect_value(t, entry.local_span != nil, true) { return }
			span := entry.local_span.?
			testing.expect_value(t, source[span.start:span.end], local)
		} else {
			testing.expect_value(t, entry.local_span == nil, true)
		}
	}
	requests := [?]string{"leaf", "key", "after-line", "upstream", "namespace"}
	if !testing.expect_value(t, len(result.dependencies), len(requests)) { return }
	for name, index in requests {
		testing.expect_value(t, result.dependencies[index].name, Maybe(string)(name))
	}
}


@(test)
test_module_lexer_typescript_exports :: proc(t: ^testing.T) {
	source := "export type Alias<T> = {value: T}; " +
	          "export interface Interface { field: number } " +
	          "export declare const ambient: string; " +
	          "export enum Color { Red } " +
	          "export const enum Code { Ok } " +
	          "export namespace Group { export const hidden = 1; } " +
	          "export abstract class Base {} " +
	          "import local = Group.hidden; " +
	          "import type Declaration = require('types'); " +
	          "export import Value = require('library');"
	result, err := kessel.module_lex_dependencies(source, context.allocator)
	if !testing.expect_value(t, err, .None) { return }
	defer kessel.module_lex_destroy(&result)
	expected := [?]string{"Alias", "Interface", "ambient", "Color", "Code", "Group", "Base", "Value"}
	if !testing.expect_value(t, len(result.exports), len(expected)) { return }
	for name, index in expected {
		entry := result.exports[index]
		testing.expect_value(t, entry.name, name)
		testing.expect_value(t, entry.local_name, Maybe(string)(name))
		testing.expect_value(t, entry.type_only, index < 3)
	}
	if !testing.expect_value(t, len(result.dependencies), 2) { return }
	testing.expect_value(t, result.dependencies[0].kind, .Import_Equals)
	testing.expect_value(t, result.dependencies[0].name, Maybe(string)("types"))
	testing.expect_value(t, result.dependencies[0].type_only, true)
	testing.expect_value(t, result.dependencies[1].kind, .Import_Equals)
	testing.expect_value(t, result.dependencies[1].name, Maybe(string)("library"))
	testing.expect_value(t, result.dependencies[1].type_only, false)
}

// The fields below are the es-module-lexer equivalents: `t` (import_type),
// `se` (clause_end), `d` (arguments_start) and the quoted-name flags that
// turn `span` into es-module-lexer's quote-inclusive `s`/`e`. Each case
// names the exact source slice the field must delimit.
@(test)
test_module_lexer_reference_fields :: proc(t: ^testing.T) {
	source := "import a from 'a';\n" +
	          "import b from 'b' with { type: 'json' } ;\n" +
	          "export * from 'c'\n" +
	          "import source d from 'd';\n" +
	          "import defer * as e from 'e';\n" +
	          "f(import /* g */ ( 'g' ), import.source('h'), import.defer('i'));\n" +
	          "import.meta.url;\n" +
	          "import j = require('j');\n"
	result, err := kessel.module_lex_dependencies(source, context.allocator)
	if !testing.expect_value(t, err, .None) { return }
	defer kessel.module_lex_destroy(&result)
	expected := [?]struct {
		type: kessel.ModuleImportType,
		clause: string,
		arguments: Maybe(string),
	}{
		{.Static, "import a from 'a'", nil},
		{.Static, "import b from 'b' with { type: 'json' }", nil},
		{.Static, "export * from 'c'", nil},
		{.Static_Source_Phase, "import source d from 'd'", nil},
		{.Static_Defer_Phase, "import defer * as e from 'e'", nil},
		{.Dynamic, "import /* g */ ( 'g' )", "( 'g' )"},
		{.Dynamic_Source_Phase, "import.source('h')", "('h')"},
		{.Dynamic_Defer_Phase, "import.defer('i')", "('i')"},
		{.Import_Meta, "import.meta", nil},
		{.None, "import j = require('j')", nil},
	}
	if !testing.expect_value(t, len(result.dependencies), len(expected)) { return }
	for item, index in expected {
		entry := result.dependencies[index]
		testing.expect_value(t, entry.import_type, item.type)
		testing.expect_value(t, source[entry.statement.start:entry.clause_end], item.clause)
		if arguments, ok := item.arguments.?; ok {
			if !testing.expect_value(t, entry.arguments_start != nil, true) { return }
			testing.expect_value(t, source[entry.arguments_start.?:entry.clause_end], arguments)
		} else {
			testing.expect_value(t, entry.arguments_start == nil, true)
		}
	}
	// `statement` keeps its semicolon; only `clause_end` excludes it.
	testing.expect_value(t, source[result.dependencies[0].statement.end - 1], u8(';'))
	testing.expect_value(t, result.dependencies[2].statement.end, result.dependencies[2].clause_end)
}

@(test)
test_module_lexer_string_export_names :: proc(t: ^testing.T) {
	source := "export { a as 'b c', \"d\" as e, f as g, 'h' } from 'm';\n" +
	          "export * as \"i j\" from 'n';\n" +
	          "const k = 'l'; export { k as 'k', k };\n"
	result, err := kessel.module_lex_dependencies(source, context.allocator)
	if !testing.expect_value(t, err, .None) { return }
	defer kessel.module_lex_destroy(&result)
	expected := [?]struct {
		raw: string,
		name_is_string, local_is_string: bool,
	}{
		{"'b c'", true, false}, {"e", false, false}, {"g", false, false}, {"'h'", true, false},
		{"\"i j\"", true, false}, {"'k'", true, false}, {"k", false, false},
	}
	if !testing.expect_value(t, len(result.exports), len(expected)) { return }
	for item, index in expected {
		entry := result.exports[index]
		testing.expect_value(t, entry.name_is_string, item.name_is_string)
		testing.expect_value(t, entry.local_is_string, item.local_is_string)
		quote := u32(1) if entry.name_is_string else u32(0)
		testing.expect_value(t, source[entry.span.start - quote:entry.span.end + quote], item.raw)
	}
}

// Attribute pairs are decoded for literal clauses only; a computed options
// object is not statically known and must yield no pairs, not an error.
@(test)
test_module_lexer_attribute_entries :: proc(t: ^testing.T) {
	source := "import a from 'a' with { type: 'json', \"k\\u0065y\": 'v\\n' };\n" +
	          "import b from 'b'\nwith\n{ type: 'css', };\n" +
	          "import c from 'c' with {};\n" +
	          "import d from 'd' assert { type: 'json' };\n" +
	          "import e from 'e'\nassert\n{}\n" +
	          "import('f', { with: { type: 'json' } });\n" +
	          "import('g', { assert: { type: 'json', }, });\n" +
	          "import('h', options);\n" +
	          "import('i', { with: attributes });\n" +
	          "import('j', { ...spread });\n" +
	          "import('k', { 'with': { type: 'css' } });\n"
	result, err := kessel.module_lex_dependencies(source, context.allocator)
	if !testing.expect_value(t, err, .None) { return }
	defer kessel.module_lex_destroy(&result)
	Pair :: struct { key, value: string }
	expected := [?]struct {
		attributes: bool,
		pairs: []Pair,
	}{
		{true, {{"type", "json"}, {"key", "v\n"}}},
		{true, {{"type", "css"}}},
		{true, {}},
		{true, {{"type", "json"}}},
		{false, {}}, // `assert` after a line break is an expression statement
		{true, {{"type", "json"}}},
		{true, {{"type", "json"}}},
		{true, {}},
		{true, {}},
		{true, {}},
		{true, {{"type", "css"}}},
	}
	if !testing.expect_value(t, len(result.dependencies), len(expected)) { return }
	for item, index in expected {
		entry := result.dependencies[index]
		testing.expect_value(t, entry.attributes != nil, item.attributes)
		if !testing.expect_value(t, len(entry.attribute_entries), len(item.pairs)) { continue }
		for pair, pair_index in item.pairs {
			actual := entry.attribute_entries[pair_index]
			testing.expect_value(t, actual.key, pair.key)
			testing.expect_value(t, actual.value, pair.value)
		}
	}
	first := result.dependencies[0].attribute_entries
	testing.expect_value(t, source[first[0].key_span.start:first[0].key_span.end], "type")
	testing.expect_value(t, source[first[0].value_span.start:first[0].value_span.end], "json")
	testing.expect_value(t, source[first[1].key_span.start:first[1].key_span.end], "k\\u0065y")
	second := result.dependencies[1]
	testing.expect_value(t, source[second.statement.start:second.clause_end],
		"import b from 'b'\nwith\n{ type: 'css', }")
}

@(test)
test_module_lexer_facade_and_format :: proc(t: ^testing.T) {
	cases := [?]struct {
		source: string,
		facade, module_syntax, commonjs: bool,
		format: kessel.ModuleFormat,
	}{
		{"", true, false, false, .Unknown},
		{"// comment only\n", true, false, false, .Unknown},
		{"import 'a'; export * from 'b'; export { c } from 'c';;", true, true, false, .ESM},
		{"import a from 'a'; export { a, a as b };", true, true, false, .ESM},
		{"import a from 'a'; a();", false, true, false, .ESM},
		{"export const a = 1;", false, true, false, .ESM},
		{"export default 1;", false, true, false, .ESM},
		{"import('a');", false, false, false, .Unknown},
		{"import.meta;", false, true, false, .ESM},
		{"const a = require('a');", false, false, true, .CJS},
		{"module.exports = {};", false, false, true, .CJS},
		{"exports.a = 1;", false, false, true, .CJS},
		{"exports['a'] = 1;", false, false, true, .CJS},
		{"import a from 'a'; module.exports = a;", false, true, true, .ESM},
		// Members, declarations, strings and comments are not CommonJS use.
		{"loader.require('a'); a.module.exports; a.exports.b;", false, false, false, .Unknown},
		{"function require(a) {} const s = \"require('a')\"; // module.exports",
			false, false, false, .Unknown},
		{"typeof require; typeof module; const exports = 1;", false, false, false, .Unknown},
	}
	for item in cases {
		result, err := kessel.module_lex_dependencies(item.source, context.allocator)
		if !testing.expectf(t, err == .None, "%q: %v", item.source, err) { continue }
		defer kessel.module_lex_destroy(&result)
		source := item.source
		testing.expectf(t, result.facade == item.facade, "%q: facade", source)
		testing.expectf(t, result.has_module_syntax == item.module_syntax, "%q: module", source)
		testing.expectf(t, result.has_commonjs_syntax == item.commonjs, "%q: commonjs", source)
		testing.expectf(t, result.format == item.format, "%q: %v", source, result.format)
	}
}

// Regressions found by the es-module-lexer reference gate: operands the
// import-keyword path consumes whole, `/` after a statement block, and class
// names behind decorators or TypeScript's `implements`.
@(test)
test_module_lexer_scan_contexts :: proc(t: ^testing.T) {
	operands := "import(import.meta.url); import(a, import.meta);"
	result, err := kessel.module_lex_dependencies(operands, context.allocator)
	if !testing.expect_value(t, err, .None) { return }
	defer kessel.module_lex_destroy(&result)
	if !testing.expect_value(t, len(result.dependencies), 4) { return }
	first := result.dependencies[0]
	testing.expect_value(t, operands[first.request.start:first.request.end], "import.meta.url")
	testing.expect_value(t, first.attributes == nil, true)
	third := result.dependencies[2]
	testing.expect_value(t, operands[third.request.start:third.request.end], "a")
	if testing.expect_value(t, third.attributes != nil, true) {
		options := third.attributes.?
		testing.expect_value(t, operands[options.start:options.end], "import.meta")
	}

	blocks := "function a() {} /import('x')/.test(b);\n" +
	          "if (c) {} /import('y')/.test(d);\n" +
	          "for (;;) {} /import('z')/.test(e);\n" +
	          "f = {} / g / import('object-divisor');\n" +
	          "h = (i) / j / import('paren-divisor');\n" +
	          "function* k() { yield /import('yielded')/; }\n" +
	          "await /import('awaited')/.test(l);\n" +
	          "m.yield / n / import('member-divisor');\n"
	scanned, blocks_err := kessel.module_lex_dependencies(blocks, context.allocator)
	if !testing.expect_value(t, blocks_err, .None) { return }
	defer kessel.module_lex_destroy(&scanned)
	if !testing.expect_value(t, len(scanned.dependencies), 3) { return }
	testing.expect_value(t, scanned.dependencies[0].name, Maybe(string)("object-divisor"))
	testing.expect_value(t, scanned.dependencies[1].name, Maybe(string)("paren-divisor"))
	testing.expect_value(t, scanned.dependencies[2].name, Maybe(string)("member-divisor"))
}

@(test)
test_module_lexer_class_export_names :: proc(t: ^testing.T) {
	cases := [?]struct {
		source: string,
		name: string,
		local: Maybe(string),
	}{
		{"export @decorate(import('d'), /[)]/) class Named {}", "Named", "Named"},
		{"export /* a */ @first @second.member class Named {}", "Named", "Named"},
		{"export default @decorate class Named {}", "default", "Named"},
		{"export default @decorate class {}", "default", nil},
		{"export default @decorate class extends Base {}", "default", nil},
		{"export default class extends Base {}", "default", nil},
		{"export default class implements Shape {}", "default", nil},
		{"@decorate export class Named {}", "Named", "Named"},
	}
	for item in cases {
		result, err := kessel.module_lex_dependencies(item.source, context.allocator)
		if !testing.expectf(t, err == .None, "%q: %v", item.source, err) { continue }
		defer kessel.module_lex_destroy(&result)
		counted := len(result.exports) == 1
		if !testing.expectf(t, counted, "%q: export count", item.source) { continue }
		testing.expect_value(t, result.exports[0].name, item.name)
		testing.expect_value(t, result.exports[0].local_name, item.local)
		testing.expect_value(t, result.has_module_syntax, true)
	}
}
