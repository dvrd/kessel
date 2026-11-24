package coverage

import "core:os"
import "core:path/filepath"
import "core:testing"

import kessel "../../../src"

// Exercise the enhanced-resolve style options through the native entry point
// so the test runner's memory tracking covers their scratch allocations,
// including the compiled restriction patterns.
@(test)
test_module_resolver_lookup_options :: proc(t: ^testing.T) {
	allocator := context.temp_allocator
	root, mkdir_err := os.make_directory_temp("", "kessel-resolve-options-*", allocator)
	if !testing.expect_value(t, mkdir_err, nil) { return }
	defer testing.expect_value(t, os.remove_all(root), nil)
	paths := [?]ModuleResolverFixture{
		{"app/src/main.js", ""},
		{"app/src/sibling.js", ""},
		{"app/src/space name.js", ""},
		{"app/shims/buffer.js", ""},
		{"app/node_modules/themed/index.js", ""},
		{"app/node_modules/themed/index.css", ""},
		{"app/node_modules/dual/package.json", `{"exports":{"node":"./node.js","module-sync":"./sync.js","default":"./default.js"}}`},
		{"app/node_modules/dual/node.js", ""},
		{"app/node_modules/dual/sync.js", ""},
		{"app/node_modules/dual/default.js", ""},
		{"public/assets/logo.js", ""},
	}
	if !write_module_resolver_fixtures(t, root, paths[:]) { return }
	actual_root, root_err := filepath.abs(root, allocator)
	if !testing.expect_value(t, root_err, nil) { return }
	importer, _ := filepath.join({actual_root, "app/src/main.js"}, allocator)
	public, _ := filepath.join({actual_root, "public"}, allocator)
	shim, _ := filepath.join({actual_root, "app/shims/buffer.js"}, allocator)

	cases := [?]struct {
		specifier: string,
		options: kessel.ModuleResolveOptions,
		path: string,
		kind: kessel.ModuleResolveKind,
		err: kessel.ModuleResolveError,
	}{
		{"/assets/logo.js", {mode = .Require}, "", .File, .Not_Found},
		{"/assets/logo", {mode = .Require, roots = {public}}, "public/assets/logo.js", .File, .None},
		{"/assets", {roots = {public}, resolve_to_context = true}, "public/assets", .File, .None},
		{"sibling.js", {mode = .Require}, "", .File, .Not_Found},
		{"sibling.js", {mode = .Require, prefer_relative = true}, "app/src/sibling.js", .File, .None},
		{"./sibling", {mode = .Require, fully_specified = true}, "", .File, .Not_Found},
		{"./sibling", {mode = .Import, fully_specified = false}, "app/src/sibling.js", .File, .None},
		{"./sibling.js?raw#top", {mode = .Import}, "app/src/sibling.js", .File, .None},
		{"./space%20name.js", {mode = .Import}, "app/src/space name.js", .File, .None},
		{"./space%2Fname.js", {mode = .Import}, "", .File, .Invalid_Specifier},
		{"./sibling.js?raw", {mode = .Require}, "", .File, .Not_Found},
		{"./", {mode = .Require, main_files = []string{"sibling"}}, "app/src/sibling.js", .File, .None},
		{"buffer", {mode = .Require, fallback = {{name = "buffer", target = shim}}}, "", .Builtin, .None},
		{"absent", {mode = .Require, fallback = {{name = "absent", target = "nowhere"}, {name = "absent", target = shim}}},
			"app/shims/buffer.js", .File, .None},
		{"absent/x", {mode = .Require, fallback = {{name = "absent", target = shim, exact = true}}}, "", .File, .Not_Found},
		{"absent", {mode = .Require, fallback = {{name = "absent", ignore = true}}}, "", .Ignored, .None},
		{"themed", {mode = .Require, extensions = []string{".js", ".css"}, restrictions = {{regex = `\.css$`}}},
			"app/node_modules/themed/index.css", .File, .None},
		{"themed", {mode = .Require, restrictions = {{path = public}}}, "", .File, .Not_Found},
		{"themed", {mode = .Require, restrictions = {{path = "relative"}}}, "", .File, .Invalid_Restriction},
		{"themed", {mode = .Require, restrictions = {{regex = "("}}}, "", .File, .Invalid_Restriction},
		{"themed", {mode = .Require, restrictions = {{path = public, regex = "x"}}}, "", .File, .Invalid_Restriction},
		{"dual", {mode = .Import}, "app/node_modules/dual/node.js", .File, .None},
		{"dual", {mode = .Import, browser = true}, "app/node_modules/dual/default.js", .File, .None},
		{"dual", {mode = .Import, explicit_conditions = true}, "app/node_modules/dual/default.js", .File, .None},
		{"dual", {mode = .Import, explicit_conditions = true, conditions = {"module-sync"}},
			"app/node_modules/dual/sync.js", .File, .None},
		{"themed", {resolve_to_context = true}, "app/node_modules/themed", .File, .None},
	}
	for fixture in cases {
		result, err := kessel.module_resolve(fixture.specifier, importer, fixture.options, allocator)
		testing.expectf(t, err == fixture.err, "%s: want %v, got %v", fixture.specifier, fixture.err, err)
		if err != .None { continue }
		testing.expectf(t, result.kind == fixture.kind, "%s: want %v, got %v", fixture.specifier, fixture.kind, result.kind)
		if fixture.path == "" { continue }
		expected, join_err := filepath.join({actual_root, fixture.path}, allocator)
		if !testing.expect_value(t, join_err, nil) { return }
		testing.expectf(t, result.path == expected, "%s: want %s, got %s", fixture.specifier, expected, result.path)
	}
}
