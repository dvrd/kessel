package coverage

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import kessel "../../../src"

@(test)
test_module_resolver_entry_points :: proc(t: ^testing.T) {
	allocator := context.temp_allocator
	root, mkdir_err := os.make_directory_temp("", "kessel-resolve-*", allocator)
	if !testing.expect_value(t, mkdir_err, nil) { return }
	defer testing.expect_value(t, os.remove_all(root), nil)
	paths := [?]ModuleResolverFixture{
		{"package.json", `{"name":"self","exports":{".":"./src/local.js","./nested":"./src/local.json"},"imports":{"#self":{"require":"./src/local.json","default":"./src/local.js"},"#files/*":"./src/*.js","#hidden":null,"#external":"entry","#nested/*":"@scope/pkg/*","#builtin":"fs/promises","#unsafe":"../outside"}}`},
		{"src/main.cjs", ""},
		{"src/local.js", ""},
		{"src/local.json", "{}"},
		{"src/directory/index.js", ""},
		{"node_modules/entry/package.json", `{"main":"lib"}`},
		{"node_modules/entry/lib/index.json", "{}"},
		{"node_modules/@scope/pkg/index.js", ""},
		{"node_modules/ordered.js", ""},
		{"node_modules/ordered/index.js", ""},
		{"node_modules/broken/package.json", "{broken}"},
		{"node_modules/mapped/package.json", `{"exports":"./index.js"}`},
		{"node_modules/mapped/index.js", ""},
		{"node_modules/conditional/package.json", `{"exports":{".":{"node":{"require":"./cjs.js"},"development":"./development.js","default":"./esm.js","import":"./unavailable.js"},"./nested":"./esm.js","./missing":"./esm","./hidden":null,"./unsafe":"./../src/local.js"}}`},
		{"node_modules/conditional/cjs.js", ""},
		{"node_modules/conditional/esm.js", ""},
		{"node_modules/conditional/development.js", ""},
		{"node_modules/pattern/package.json", `{"exports":{".":[42,{"other":"./nonexistent.js"},"./exact.js"],"./files/*":"./lib/*.js","./files/*.txt":"./lib/*.json","./files/exact":"./exact.js","./null":[null,"./exact.js"],"./blocked":[123,null],"./numeric":{"0":"./exact.js","default":"./exact.js"},"./missing":["./nonexistent.js","./exact.js"],"./invalid":[{"node":"../outside"},{}]}}`},
		{"node_modules/pattern/exact.js", ""},
		{"node_modules/pattern/lib/a.js", ""},
		{"node_modules/pattern/lib/a.json", ""},
		{"node_modules/mixed/package.json", `{"exports":{".":"./index.js","default":"./index.js"}}`},
	}
	if !write_module_resolver_fixtures(t, root, paths[:]) { return }
	importer, join_err := filepath.join({root, "src/main.cjs"}, allocator)
	if !testing.expect_value(t, join_err, nil) { return }
	cases := [?]struct {
		specifier: string,
		mode: kessel.ModuleResolveMode,
		path: string,
		err: kessel.ModuleResolveError,
	}{
		{"./local", .Require, "src/local.js", .None},
		{"./local", .Import, "", .Not_Found},
		{"./local.js", .Import, "src/local.js", .None},
		{"./directory", .Require, "src/directory/index.js", .None},
		{"./directory", .Import, "", .Directory_Import},
		{"entry", .Require, "node_modules/entry/lib/index.json", .None},
		{"entry", .Import, "node_modules/entry/lib/index.json", .None},
		{"self", .Import, "src/local.js", .None},
		{"self/nested", .Require, "src/local.json", .None},
		{"self/private", .Require, "", .Package_Path_Not_Exported},
		{"#self", .Import, "src/local.js", .None},
		{"#self", .Require, "src/local.json", .None},
		{"#files/local", .Import, "src/local.js", .None},
		{"#hidden", .Import, "", .Package_Import_Not_Defined},
		{"#undefined", .Require, "", .Package_Import_Not_Defined},
		{"#unsafe", .Import, "", .Invalid_Package_Target},
		{"#external", .Require, "node_modules/entry/lib/index.json", .None},
		{"#nested/index.js", .Import, "node_modules/@scope/pkg/index.js", .None},
		{"@scope/pkg", .Require, "node_modules/@scope/pkg/index.js", .None},
		{"@scope/pkg/index.js", .Import, "node_modules/@scope/pkg/index.js", .None},
		{"ordered", .Require, "node_modules/ordered.js", .None},
		{"broken", .Require, "", .Invalid_Package_Config},
		{"mapped", .Import, "node_modules/mapped/index.js", .None},
		{"conditional", .Require, "node_modules/conditional/cjs.js", .None},
		{"conditional", .Import, "node_modules/conditional/esm.js", .None},
		{"conditional/nested", .Import, "node_modules/conditional/esm.js", .None},
		{"conditional/missing", .Require, "", .Not_Found},
		{"conditional/hidden", .Require, "", .Package_Path_Not_Exported},
		{"conditional/esm.js", .Import, "", .Package_Path_Not_Exported},
		{"conditional/unsafe", .Import, "", .Invalid_Package_Target},
		{"mixed", .Import, "", .Invalid_Package_Config},
		{"pattern", .Import, "node_modules/pattern/exact.js", .None},
		{"pattern/", .Import, "", .Package_Path_Not_Exported},
		{"pattern/files/a", .Import, "node_modules/pattern/lib/a.js", .None},
		{"pattern/files/a.txt", .Import, "node_modules/pattern/lib/a.json", .None},
		{"pattern/files/exact", .Require, "node_modules/pattern/exact.js", .None},
		{"pattern/files/../a", .Require, "", .Invalid_Specifier},
		{"pattern/null", .Require, "node_modules/pattern/exact.js", .None},
		{"pattern/blocked", .Require, "", .Package_Path_Not_Exported},
		{"pattern/numeric", .Require, "", .Invalid_Package_Config},
		{"pattern/missing", .Require, "", .Not_Found},
		{"pattern/invalid", .Require, "", .Invalid_Package_Target},
		{"@scope", .Import, "", .Invalid_Specifier},
	}
	for fixture in cases {
		result, err := kessel.module_resolve(fixture.specifier, importer, {mode = fixture.mode}, allocator)
		testing.expectf(t, err == fixture.err, "%s in %v: want %v, got %v", fixture.specifier, fixture.mode, fixture.err, err)
		if err != .None || fixture.path == "" { continue }
		joined, join_err := filepath.join({root, fixture.path}, allocator)
		if !testing.expect_value(t, join_err, nil) { return }
		expected, abs_err := filepath.abs(joined, allocator)
		if !testing.expect_value(t, abs_err, nil) { return }
		testing.expect_value(t, result.kind, .File)
		testing.expect_value(t, result.path, expected)
	}
	development, development_err := kessel.module_resolve(
		"conditional", importer, {mode = .Import, conditions = {"development"}}, allocator)
	testing.expect_value(t, development_err, .None)
	testing.expect_value(t, filepath.base(development.path), "development.js")
	builtin, err := kessel.module_resolve("node:fs/promises", importer, {mode = .Import}, allocator)
	testing.expect_value(t, err, .None)
	testing.expect_value(t, builtin.kind, .Builtin)
	testing.expect_value(t, builtin.path, "node:fs/promises")
	alias, alias_err := kessel.module_resolve("#builtin", importer, {mode = .Import}, allocator)
	testing.expect_value(t, alias_err, .None)
	testing.expect_value(t, alias.kind, .Builtin)
	testing.expect_value(t, alias.path, "fs/promises")
}


ModuleResolverFixture :: struct {
	path: string,
	data: string,
}

write_module_resolver_fixtures :: proc(t: ^testing.T, root: string, paths: []ModuleResolverFixture) -> bool {
	allocator := context.temp_allocator
	for fixture in paths {
		path, join_err := filepath.join({root, fixture.path}, allocator)
		if !testing.expect_value(t, join_err, nil) { return false }
		parent := filepath.dir(path)
		if !os.is_directory(parent) {
			if !testing.expect_value(t, os.make_directory_all(parent), nil) { return false }
		}
		if !testing.expect_value(t, os.write_entire_file(path, transmute([]u8)fixture.data), nil) { return false }
	}
	return true
}

@(test)
test_module_resolver_typescript_config :: proc(t: ^testing.T) {
	allocator := context.temp_allocator
	root, mkdir_err := os.make_directory_temp("", "kessel-tsconfig-*", allocator)
	if !testing.expect_value(t, mkdir_err, nil) { return }
	defer testing.expect_value(t, os.remove_all(root), nil)
	paths := [?]ModuleResolverFixture{
		{"src/main.ts", ""},
		{"node_modules/plain/index.js", ""},
		{"node_modules/ts-policy/package.json", `{"tsconfig":"config/base.json"}`},
		{"node_modules/ts-policy/config/base.json", `{"compilerOptions":{"paths":{"policy":["./src/policy"]}}}`},
		{"node_modules/ts-policy/config/src/policy.ts", ""},
		{"cfg/base/tsconfig.json", `{
			// Resolve inherited paths from this configuration.
			"compilerOptions": {"paths": {
				"@app/*": ["./missing/*", "./src/*"],
				"@app/special": ["./src/exact.js"],
				"@app/components/*": ["./src/components/*"],
				"@tie/*": ["./src/first.ts"],
				"@tie/*.js": ["./src/second.ts"],
				"alias-esm": ["./src/esm.mjs"],
				"@cjs": ["./src/cjs.cjs"],
				"@directory": ["./src/folder"],
				"@escape": ["./src/a b.ts"],
			}, },
		}`},
		{"cfg/base/src/a.ts", ""},
		{"cfg/base/src/special.ts", ""},
		{"cfg/base/src/exact.ts", ""},
		{"cfg/base/src/exact.js", ""},
		{"cfg/base/src/esm.mts", ""},
		{"cfg/base/src/cjs.cts", ""},
		{"cfg/base/src/components/button.tsx", ""},
		{"cfg/base/src/first.ts", ""},
		{"cfg/base/src/second.ts", ""},
		{"cfg/base/src/a b.ts", ""},
		{"cfg/base/src/folder/index.ts", ""},
		{"cfg/override.json", `{"compilerOptions":{"paths":{"@app/*":["./alt/*"]}}}`},
		{"cfg/alt/a.ts", ""},
		{"cfg/child/tsconfig.json", `{"extends":"../base/tsconfig"}`},
		{"cfg/child/multiple.json", `{"extends":["../base/tsconfig","../override"]}`},
		{"cfg/child/base-url.json", `{"extends":"../base/tsconfig","compilerOptions":{"baseUrl":"../override-base"}}`},
		{"cfg/override-base/src/a.ts", ""},
		{"cfg/override-base/direct.ts", ""},
		{"cfg/base/virtual.json", `{"compilerOptions":{"rootDirs":["../../src","../../generated"]}}`},
		{"cfg/child/virtual.json", `{"extends":"../base/virtual"}`},
		{"cfg/child/clear.json", `{"extends":"../base/virtual","compilerOptions":{"rootDirs":[]}}`},
		{"generated/main.ts", ""},
		{"generated/message.tsx", ""},
		{"generated/layout.d.css.ts", ""},
		{"src/layout.css", ""},
		{"cfg/child/cycle.json", `{"extends":"./cycle"}`},
		{"cfg/child/missing-extends.json", `{"extends":"./missing"}`},
		{"cfg/child/invalid.json", `{"compilerOptions":{"paths":{"@**":[]}}}`},
		{"cfg/child/package.json", `{"extends":"ts-policy"}`},
	}
	if !write_module_resolver_fixtures(t, root, paths[:]) { return }
	importer, importer_err := filepath.join({root, "src/main.ts"}, allocator)
	if !testing.expect_value(t, importer_err, nil) { return }
	cases := [?]struct {
		config, specifier, path: string,
		err: kessel.ModuleResolveError,
	}{
		{"child/tsconfig", "@app/a", "cfg/base/src/a.ts", .None},
		{"child/tsconfig", "@app/special", "cfg/base/src/exact.js", .None},
		{"child/tsconfig", "@app/components/button", "cfg/base/src/components/button.tsx", .None},
		{"child/tsconfig", "@tie/file.js", "cfg/base/src/first.ts", .None},
		{"child/tsconfig", "alias-esm", "cfg/base/src/esm.mts", .None},
		{"child/tsconfig", "@cjs", "cfg/base/src/cjs.cts", .None},
		{"child/tsconfig", "@directory", "cfg/base/src/folder/index.ts", .None},
		{"child/tsconfig", "@escape", "cfg/base/src/a b.ts", .None},
		{"child/tsconfig", "plain", "node_modules/plain/index.js", .None},
		{"child/tsconfig", "@app/no-file", "", .Not_Found},
		{"child/multiple", "@app/a", "cfg/alt/a.ts", .None},
		{"child/multiple", "alias-esm", "", .Not_Found},
		{"child/base-url", "@app/a", "cfg/override-base/src/a.ts", .None},
		{"child/base-url", "direct", "cfg/override-base/direct.ts", .None},
		{"child/package", "policy", "node_modules/ts-policy/config/src/policy.ts", .None},
		{"child/virtual", "./main", "src/main.ts", .None},
		{"child/virtual", "./message.js", "generated/message.tsx", .None},
		{"child/virtual", "./layout.css", "generated/layout.d.css.ts", .None},
		{"child/clear", "./message.js", "", .Not_Found},
		{"child/cycle", "anything", "", .Invalid_TSConfig},
		{"child/invalid", "anything", "", .Invalid_TSConfig},
		{"child/missing", "anything", "", .TSConfig_Not_Found},
		{"child/missing-extends", "anything", "", .TSConfig_Not_Found},
	}
	for fixture in cases {
		filename, filename_err := strings.concatenate({fixture.config, ".json"}, allocator)
		if !testing.expect_value(t, filename_err, nil) { return }
		config, config_err := filepath.join({root, "cfg", filename}, allocator)
		if !testing.expect_value(t, config_err, nil) { return }
		result, err := kessel.module_resolve(fixture.specifier, importer, {
			mode = .Import,
			typescript_config = config,
		}, allocator)
		testing.expectf(t, err == fixture.err, "%s with %s: want %v, got %v", fixture.specifier, fixture.config, fixture.err, err)
		if err != .None { continue }
		path, join_err := filepath.join({root, fixture.path}, allocator)
		if !testing.expect_value(t, join_err, nil) { return }
		expected, abs_err := filepath.abs(path, allocator)
		if !testing.expect_value(t, abs_err, nil) { return }
		testing.expect_value(t, result.kind, .File)
		testing.expect_value(t, result.path, expected)
	}
}
