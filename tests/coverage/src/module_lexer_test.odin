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
