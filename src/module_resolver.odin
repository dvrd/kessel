package kessel

import "core:mem"
import mvirtual "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

ModuleResolveMode :: enum { Require, Import }
ModulePackageRequest :: enum { Bare, Imports_Target }

ModuleResolveAlias :: struct {
	name: string,
	target: string,
	exact: bool,
}

ModuleResolveOptions :: struct {
	mode: ModuleResolveMode,
	conditions: []string,
	main_fields: Maybe([]string),
	exports_fields: Maybe([][]string),
	imports_fields: Maybe([][]string),
	modules: Maybe([]string),
	extensions: Maybe([]string),
	extension_alias: map[string][]string,
	main_files: Maybe([]string),
	aliases: []ModuleResolveAlias,
	typescript_config: string,
	preserve_symlinks: bool,
	browser: bool,
}

ModuleResolveKind :: enum { File, Builtin, Ignored }

ModuleResolution :: struct {
	kind: ModuleResolveKind,
	path: string,
}

ModuleResolveError :: enum {
	None,
	Invalid_Specifier,
	Invalid_Alias,
	Extension_Alias_Not_Found,
	Browser_Mapping_Cycle,
	Not_Found,
	Directory_Import,
	Invalid_Package_Config,
	Invalid_TSConfig,
	TSConfig_Not_Found,
	Invalid_Package_Target,
	Package_Path_Not_Exported,
	Package_Import_Not_Defined,
	IO_Error,
	Allocation_Error,
}

// Resolve filesystem paths, Node builtins, and packages. The caller owns
// the returned path or builtin name.
module_resolve :: proc(
	requested, importer: string,
	options: ModuleResolveOptions,
	allocator: mem.Allocator,
) -> (ModuleResolution, ModuleResolveError) {
	assert(allocator.procedure != nil)
	options := options
	if options.exports_fields == nil { options.exports_fields = [][]string{{"exports"}} }
	if options.imports_fields == nil { options.imports_fields = [][]string{{"imports"}} }
	if options.extensions == nil { options.extensions = []string{".js", ".json", ".node"} }
	if options.main_files == nil { options.main_files = []string{"index"} }
	if options.main_fields == nil {
		fields := []string{"main"}
		if options.browser { fields = {"browser", "module", "main"} }
		options.main_fields = fields
	}
	if !options.browser {
		return module_resolver_once(requested, importer, options, allocator)
	}
	return module_resolver_browser(requested, importer, options, allocator)
}

@(private)
module_resolver_once :: proc(
	requested, importer: string,
	options: ModuleResolveOptions,
	allocator: mem.Allocator,
	browser_probe: ^ModuleBrowserMapping = nil,
) -> (ModuleResolution, ModuleResolveError) {
	assert(allocator.procedure != nil)
	specifier := requested
	if specifier == "" || importer == "" { return {}, .Invalid_Specifier }
	if strings.contains_rune(specifier, 0) { return {}, .Invalid_Specifier }
	if strings.contains_rune(importer, 0) { return {}, .Invalid_Specifier }

	// Only the final filename needs to survive this resolution.
	scratch: mvirtual.Arena
	if err := mvirtual.arena_init_growing(&scratch); err != nil { return {}, .Allocation_Error }
	defer mvirtual.arena_destroy(&scratch)
	temp := mvirtual.arena_allocator(&scratch)
	if len(options.aliases) > 0 {
		mapped, map_err := module_resolver_alias(specifier, options.aliases, temp)
		if map_err != .None { return {}, map_err }
		specifier = mapped
	}
	name := strings.trim_prefix(specifier, "node:")
	if module_resolver_is_builtin(name) || module_resolver_is_prefixed_builtin(specifier) {
		owned, clone_err := strings.clone(specifier, allocator)
		if clone_err != nil { return {}, .Allocation_Error }
		return {kind = .Builtin, path = owned}, .None
	}
	if name != specifier { return {}, .Invalid_Specifier }

	start, err := module_resolver_importer_dir(importer, options.preserve_symlinks, temp)
	if err != .None { return {}, err }
	resolved: string
	if specifier[0] == '#' {
		mapped, map_err := module_resolver_imports(specifier, start, options, temp, browser_probe)
		if map_err != .None { return {}, map_err }
		if mapped.kind == .Builtin {
			name, clone_err := strings.clone(mapped.path, allocator)
			if clone_err != nil { return {}, .Allocation_Error }
			return {kind = .Builtin, path = name}, .None
		}
		resolved = mapped.path
	} else if filepath.is_abs(specifier) || module_resolver_is_relative(specifier) {
		target := specifier
		if !filepath.is_abs(target) {
			joined, join_err := filepath.join({start, target}, temp)
			if join_err != nil { return {}, .Allocation_Error }
			target = joined
		}
		if options.typescript_config != "" {
			resolved, err = module_resolver_tsconfig_root_path(specifier, target, options, temp, browser_probe)
		}
		if resolved == "" && err == .None {
			resolved, err = module_resolver_load_path(target, options, temp, browser_probe)
		}
	} else {
		if options.typescript_config != "" {
			resolved, err = module_resolver_tsconfig_path(specifier, options.typescript_config, temp)
		}
		if resolved == "" && err == .None {
			resolved, err = module_resolver_load_package(specifier, start, options, temp, browser_probe)
		}
	}
	if err != .None { return {}, err }
	return module_resolver_finish(resolved, options.preserve_symlinks, browser_probe, allocator)
}

@(private="file")
module_resolver_finish :: proc(
	resolved: string,
	preserve_symlinks: bool,
	browser_probe: ^ModuleBrowserMapping,
	allocator: mem.Allocator,
) -> (ModuleResolution, ModuleResolveError) {
	if browser_probe != nil && module_resolver_has_browser_mapping(browser_probe^) {
		if !browser_probe.ignored {
			scope, scope_err := strings.clone(browser_probe.scope, allocator)
			target, target_err := strings.clone(browser_probe.target, allocator)
			if scope_err != nil || target_err != nil { return {}, .Allocation_Error }
			browser_probe.scope = scope
			browser_probe.target = target
		}
		return {}, .None
	}
	assert(resolved != "")
	if preserve_symlinks {
		path, clean_err := filepath.clean(resolved, allocator)
		if clean_err != nil { return {}, .Allocation_Error }
		return {kind = .File, path = path}, .None
	}
	path, abs_err := filepath.abs(resolved, allocator)
	if abs_err != nil { return {}, .IO_Error }
	return {kind = .File, path = path}, .None
}

@(private)
module_resolver_alias :: proc(
	specifier: string,
	aliases: []ModuleResolveAlias,
	allocator: mem.Allocator,
) -> (string, ModuleResolveError) {
	for alias in aliases {
		if alias.name == "" || alias.target == "" || strings.contains_rune(alias.target, 0) {
			return "", .Invalid_Alias
		}
	}
	MAX_REWRITES :: 64
	visited: [MAX_REWRITES]string
	current := specifier
	for index in 0..<len(visited) {
		visited[index] = current
		next: string
		for alias in aliases {
			if current == alias.name {
				next = alias.target
				break
			}
			if alias.exact || !strings.has_prefix(current, alias.name) { continue }
			suffix := current[len(alias.name):]
			if len(suffix) == 0 || suffix[0] != '/' { continue }
			path, err := strings.concatenate({alias.target, suffix}, allocator)
			if err != nil { return "", .Allocation_Error }
			next = path
			break
		}
		if next == "" || next == current { return current, .None }
		for name in visited[:index] {
			if name == next { return "", .Invalid_Alias }
		}
		current = next
	}
	return "", .Invalid_Alias
}

@(private)
module_resolver_importer_dir :: proc(importer: string, preserve_symlinks: bool, allocator: mem.Allocator) -> (string, ModuleResolveError) {
	if !preserve_symlinks && os.is_file(importer) {
		actual, err := filepath.abs(importer, allocator)
		if err != nil { return "", .IO_Error }
		return filepath.dir(actual), .None
	}
	parent := filepath.dir(importer)
	if !filepath.is_abs(parent) {
		cwd, err := os.get_working_directory(allocator)
		if err != nil { return "", .IO_Error }
		path, join_err := filepath.join({cwd, parent}, allocator)
		if join_err != nil { return "", .Allocation_Error }
		parent = path
	}
	if !preserve_symlinks && os.is_directory(parent) {
		path, err := filepath.abs(parent, allocator)
		if err != nil { return "", .IO_Error }
		return path, .None
	}
	return parent, .None
}

@(private)
module_resolver_is_relative :: proc(path: string) -> bool {
	return path == "." || path == ".." ||
		strings.has_prefix(path, "./") || strings.has_prefix(path, "../")
}

@(private="file")
module_resolver_is_builtin :: proc(name: string) -> bool {
	switch name {
	case "assert", "assert/strict", "async_hooks", "buffer", "child_process",
		"cluster", "console", "constants", "crypto", "dgram", "diagnostics_channel",
		"dns", "dns/promises", "domain", "events", "fs", "fs/promises",
		"http", "http2", "https", "module", "net", "os", "path", "path/posix",
		"path/win32", "perf_hooks", "process", "punycode", "querystring",
		"readline", "readline/promises", "repl", "stream", "stream/consumers",
		"stream/promises", "stream/web", "string_decoder", "sys", "timers",
		"timers/promises", "tls", "trace_events", "tty", "url", "util",
		"util/types", "v8", "vm", "wasi", "worker_threads", "zlib":
		return true
	}
	return false
}

@(private="file")
module_resolver_is_prefixed_builtin :: proc(name: string) -> bool {
	switch name {
	case "node:sea", "node:sqlite", "node:test", "node:test/reporters":
		return true
	}
	return false
}

@(private="file")
module_resolver_load_path :: proc(
	path: string,
	options: ModuleResolveOptions,
	allocator: mem.Allocator,
	browser_probe: ^ModuleBrowserMapping = nil,
) -> (string, ModuleResolveError) {
	if options.mode == .Import {
		return module_resolver_check_mapped_path(path, options, allocator, browser_probe)
	}
	if file, err := module_resolver_load_file(path, options, allocator, browser_probe); err != .Not_Found {
		return file, err
	}
	if !os.is_directory(path) { return "", .Not_Found }
	return module_resolver_load_main(path, options, allocator, browser_probe = browser_probe)
}

@(private="file")
module_resolver_probe_file :: proc(path: string, allocator: mem.Allocator, browser_probe: ^ModuleBrowserMapping) -> ModuleResolveError {
	if browser_probe != nil {
		mapping, err := module_resolver_browser_lookup(filepath.dir(path), path, allocator)
		if err != .None { return err }
		if module_resolver_has_browser_mapping(mapping) {
			browser_probe^ = mapping
			return .None
		}
	}
	if os.is_file(path) { return .None }
	return .Not_Found
}

// Replace only an explicitly requested final suffix. Extensions appended by
// ordinary lookup and candidates produced by this map do not re-enter it.
@(private)
module_resolver_extension_alias :: proc(path: string, aliases: map[string][]string, allocator: mem.Allocator, browser_probe: ^ModuleBrowserMapping) -> (string, ModuleResolveError) {
	base := filepath.base(path)
	dot := strings.last_index_byte(base, '.')
	if dot <= 0 { return "", .Not_Found }
	extension := base[dot:]
	targets, found := aliases[extension]
	if !found { targets, found = aliases[extension[1:]] }
	if !found { return "", .Not_Found }
	stem := path[:len(path)-len(extension)]
	if file, err := module_resolver_probe_extensions(stem, targets, allocator, browser_probe); err != .Not_Found {
		return file, err
	}
	// An existing source filename excluded by the mapping cannot fall back
	// to itself. A missing filename can still denote a package or directory.
	if os.is_file(path) { return "", .Extension_Alias_Not_Found }
	return "", .Not_Found
}

@(private="file")
module_resolver_load_file :: proc(path: string, options: ModuleResolveOptions, allocator: mem.Allocator, browser_probe: ^ModuleBrowserMapping) -> (string, ModuleResolveError) {
	if len(options.extension_alias) > 0 {
		if result, err := module_resolver_extension_alias(path, options.extension_alias, allocator, browser_probe); err != .Not_Found {
			return result, err
		}
	}
	extensions := options.extensions.([]string)
	// An empty suffix puts the exact filename at its configured position.
	if !slice.contains(extensions, "") {
		if probe := module_resolver_probe_file(path, allocator, browser_probe); probe != .Not_Found {
			return path, probe
		}
	}
	return module_resolver_probe_extensions(path, extensions, allocator, browser_probe)
}

@(private)
module_resolver_probe_extensions :: proc(path: string, extensions: []string, allocator: mem.Allocator, browser_probe: ^ModuleBrowserMapping) -> (string, ModuleResolveError) {
	for extension in extensions {
		candidate, err := strings.concatenate({path, extension}, allocator)
		if err != nil { return "", .Allocation_Error }
		if probe := module_resolver_probe_file(candidate, allocator, browser_probe); probe != .Not_Found {
			return candidate, probe
		}
	}
	return "", .Not_Found
}

@(private="file")
module_resolver_load_index :: proc(path: string, options: ModuleResolveOptions, allocator: mem.Allocator, browser_probe: ^ModuleBrowserMapping) -> (string, ModuleResolveError) {
	for name in options.main_files.([]string) {
		candidate, err := filepath.join({path, name}, allocator)
		if err != nil { return "", .Allocation_Error }
		if file, probe := module_resolver_probe_extensions(candidate, options.extensions.([]string), allocator, browser_probe); probe != .Not_Found {
			return file, probe
		}
	}
	return "", .Not_Found
}

@(private)
module_resolver_package_config :: proc(path: string, allocator: mem.Allocator) -> (^ModuleManifestObject, ModuleResolveError) {
	context.allocator = allocator
	config, join_err := filepath.join({path, "package.json"}, allocator)
	if join_err != nil { return nil, .Allocation_Error }
	bytes, err := os.read_entire_file_from_path(config, allocator)
	if err == .Not_Exist { return nil, .None }
	if err != nil { return nil, .IO_Error }
	object, valid := module_manifest_parse(string(bytes), allocator).(^ModuleManifestObject)
	if !valid { return nil, .Invalid_Package_Config }
	return object, .None
}

@(private="file")
module_resolver_load_main :: proc(
	path: string,
	options: ModuleResolveOptions,
	allocator: mem.Allocator,
	config: ^ModuleManifestObject = nil,
	browser_probe: ^ModuleBrowserMapping = nil,
) -> (string, ModuleResolveError) {
	config := config
	if config == nil {
		loaded, err := module_resolver_package_config(path, allocator)
		if err != .None { return "", err }
		config = loaded
	}
	for field in options.main_fields.([]string) {
		entry, ok := module_manifest_member(config, field).(string)
		if !ok || entry == "" { continue }
		target, err := filepath.join({path, entry}, allocator)
		if err != nil { return "", .Allocation_Error }
		if result, file_err := module_resolver_load_file(target, options, allocator, browser_probe); file_err != .Not_Found {
			return result, file_err
		}
		if result, index_err := module_resolver_load_index(target, options, allocator, browser_probe); index_err != .Not_Found {
			return result, index_err
		}
	}
	return module_resolver_load_index(path, options, allocator, browser_probe)
}

@(private="file")
module_resolver_package_name :: proc(specifier: string) -> (name, subpath: string, valid: bool) {
	slash := strings.index_byte(specifier, '/')
	if specifier[0] == '@' {
		if slash < 2 || slash == len(specifier) - 1 { return "", "", false }
		offset := strings.index_byte(specifier[slash + 1:], '/')
		if offset == 0 { return "", "", false }
		slash = slash + 1 + offset if offset >= 0 else -1
	}
	name = specifier if slash < 0 else specifier[:slash]
	if len(name) == 0 || name[0] == '.' { return "", "", false }
	if strings.contains_any(name, "\\:%") { return "", "", false }
	if slash >= 0 { subpath = specifier[slash:] }
	return name, subpath, true
}

@(private)
module_resolver_package_scope :: proc(start: string, allocator: mem.Allocator) -> (string, ^ModuleManifestObject, ModuleResolveError) {
	directory := start
	for _ in 0..=len(start) {
		if filepath.base(directory) == "node_modules" { break }
		config, err := module_resolver_package_config(directory, allocator)
		if err != .None { return "", nil, err }
		if config != nil { return directory, config, .None }
		parent := filepath.dir(directory)
		if parent == directory || parent == "" || parent == "." { break }
		directory = parent
	}
	return "", nil, .None
}

@(private="file")
module_resolver_load_package :: proc(
	specifier, start: string,
	options: ModuleResolveOptions,
	allocator: mem.Allocator,
	browser_probe: ^ModuleBrowserMapping = nil,
	request: ModulePackageRequest = .Bare,
) -> (string, ModuleResolveError) {
	name, subpath, valid := module_resolver_package_name(specifier)
	if !valid { return "", .Invalid_Specifier }

	scope, own_config, scope_err := module_resolver_package_scope(start, allocator)
	if scope_err != .None { return "", scope_err }
	if own_name, ok := module_manifest_member(own_config, "name").(string); ok && own_name == name {
		if path, err := module_resolver_exports(own_config, scope, subpath, options, allocator, browser_probe); path != "" || err != .None {
			return path, err
		}
	}

	roots, configured := options.modules.?
	if !configured { roots = {"node_modules"} }
	// Exhaust each relative root along the importer ancestry before trying the
	// next one. An absolute directory names one location for every importer.
	for root in roots {
		absolute := filepath.is_abs(root)
		directory := start
		for _ in 0..=len(start) {
			if configured || filepath.base(directory) != "node_modules" {
				prefix := directory if !absolute else ""
				pkg, err := filepath.join({prefix, root, name}, allocator)
				if err != nil { return "", .Allocation_Error }
				path, probe := module_resolver_probe_package(pkg, subpath, options, request, allocator, browser_probe)
				if path != "" || probe != .None { return path, probe }
			}
			if absolute { break }
			parent := filepath.dir(directory)
			if parent == directory || parent == "" || parent == "." { break }
			directory = parent
		}
	}
	return "", .Not_Found
}

// An empty path without an error continues the search. Once exports selects
// a package, even a missing target is final and must shadow lower-priority roots.
@(private="file")
module_resolver_probe_package :: proc(
	pkg, subpath: string,
	options: ModuleResolveOptions,
	request: ModulePackageRequest,
	allocator: mem.Allocator,
	browser_probe: ^ModuleBrowserMapping,
) -> (string, ModuleResolveError) {
	is_package := os.is_directory(pkg)
	config: ^ModuleManifestObject
	if is_package {
		loaded, err := module_resolver_package_config(pkg, allocator)
		if err != .None { return "", err }
		config = loaded
		if path, probe := module_resolver_exports(config, pkg, subpath, options, allocator, browser_probe); path != "" || probe != .None {
			return path, probe
		}
	}

	if subpath == "" {
		// A directory claims its name in a configured root even when a sibling
		// file has an implicit suffix. Node CommonJS checks that file first.
		probe_as_file := !is_package if options.modules != nil else options.mode == .Require
		if request == .Bare && probe_as_file {
			if path, err := module_resolver_load_file(pkg, options, allocator, browser_probe); err != .Not_Found {
				return path, err
			}
		}
		if is_package {
			if path, err := module_resolver_load_main(pkg, options, allocator, config, browser_probe); err != .Not_Found {
				return path, err
			}
		}
	} else if is_package {
		target, join_err := filepath.join({pkg, subpath[1:]}, allocator)
		if join_err != nil { return "", .Allocation_Error }
		// Node resolves an external imports-map target as a package and exact
		// subpath, including when the original caller used require().
		if request == .Imports_Target {
			return module_resolver_check_mapped_path(target, options, allocator, browser_probe)
		}
		path, err := module_resolver_load_path(target, options, allocator, browser_probe)
		if err != .Not_Found && !(options.modules != nil && err == .Directory_Import) {
			return path, err
		}
	}
	if is_package && options.mode == .Import && options.modules == nil { return "", .Not_Found }
	return "", .None
}

@(private="file")
module_resolver_imports :: proc(
	specifier, start: string,
	options: ModuleResolveOptions,
	allocator: mem.Allocator,
	browser_probe: ^ModuleBrowserMapping = nil,
) -> (ModuleResolution, ModuleResolveError) {
	if specifier == "#" || strings.has_suffix(specifier, "/") {
		return {}, .Invalid_Specifier
	}
	scope, config, err := module_resolver_package_scope(start, allocator)
	if err != .None { return {}, err }
	target, target_err := module_resolver_read_map(config, scope, specifier, true, options, allocator)
	if target_err != .None { return {}, target_err }
	if target.external {
		if module_resolver_is_builtin(target.path) { return {kind = .Builtin, path = target.path}, .None }
		path, lookup_err := module_resolver_load_package(target.path, scope, options, allocator, browser_probe, .Imports_Target)
		return {kind = .File, path = path}, lookup_err
	}
	path, file_err := module_resolver_check_mapped_path(target.path, options, allocator, browser_probe)
	return {kind = .File, path = path}, file_err
}

@(private="file")
module_resolver_exports :: proc(
	config: ^ModuleManifestObject,
	package_dir, subpath: string,
	options: ModuleResolveOptions,
	allocator: mem.Allocator,
	browser_probe: ^ModuleBrowserMapping = nil,
) -> (string, ModuleResolveError) {
	export_key := "."
	if subpath != "" {
		key, err := strings.concatenate({".", subpath}, allocator)
		if err != nil { return "", .Allocation_Error }
		export_key = key
	}
	target, err := module_resolver_read_map(config, package_dir, export_key, false, options, allocator)
	if err != .None || target.path == "" { return "", err }
	assert(!target.external)
	return module_resolver_check_mapped_path(target.path, options, allocator, browser_probe)
}

@(private="file")
module_resolver_check_mapped_path :: proc(
	path: string,
	options: ModuleResolveOptions,
	allocator: mem.Allocator,
	browser_probe: ^ModuleBrowserMapping,
) -> (string, ModuleResolveError) {
	if len(options.extension_alias) > 0 {
		if result, err := module_resolver_extension_alias(path, options.extension_alias, allocator, browser_probe); err != .Not_Found {
			return result, err
		}
	}
	if probe := module_resolver_probe_file(path, allocator, browser_probe); probe != .Not_Found {
		return path, probe
	}
	if options.mode == .Import && os.is_directory(path) { return "", .Directory_Import }
	return "", .Not_Found
}

ModuleMapTarget :: struct {
	path: string,
	external: bool,
}

@(private="file")
module_resolver_read_map :: proc(
	config: ^ModuleManifestObject,
	package_dir, key: string,
	internal: bool,
	options: ModuleResolveOptions,
	allocator: mem.Allocator,
) -> (ModuleMapTarget, ModuleResolveError) {
	fields := options.exports_fields.([][]string) if !internal else options.imports_fields.([][]string)
	missing := ModuleResolveError.Package_Import_Not_Defined if internal else ModuleResolveError.None
	// The first present exports field owns the package. Private imports may
	// continue to the next field when an earlier table has no matching target.
	for field in fields {
		target := module_resolver_manifest_field(config, field)
		if target == nil { continue }
		if internal {
			if _, ok := target.(^ModuleManifestObject); !ok { continue }
		}
		selected, pattern, err := module_resolver_select_map(target, key, internal)
		mapped: ModuleMapTarget
		if err == .None {
			mapped, err = module_resolver_map_target(selected, package_dir, pattern, internal, options, allocator)
		}
		if internal && err == .Package_Path_Not_Exported { continue }
		return mapped, err
	}
	return {}, missing
}

@(private="file")
module_resolver_manifest_field :: proc(root: ^ModuleManifestObject, field: []string) -> ModuleManifestValue {
	if root == nil || len(field) == 0 { return nil }
	value: ModuleManifestValue = root
	for key in field {
		object, ok := value.(^ModuleManifestObject)
		if !ok { return nil }
		value = object.members[key]
	}
	return value
}

@(private="file")
module_resolver_select_map :: proc(target: ModuleManifestValue, requested: string, internal: bool) -> (ModuleManifestValue, Maybe(string), ModuleResolveError) {
	object, ok := target.(^ModuleManifestObject)
	if !ok {
		if !internal && requested == "." { return target, nil, .None }
		return nil, nil, .Package_Path_Not_Exported
	}
	has_subpaths := false
	has_conditions := false
	exact: ModuleManifestValue
	best: ModuleManifestValue
	best_prefix, best_length := -1, -1
	capture: string
	for key in object.order {
		if internal {
			if !strings.has_prefix(key, "#") { continue }
		} else {
			if !strings.has_prefix(key, ".") {
				has_conditions = true
				continue
			}
			has_subpaths = true
		}
		star := strings.index_byte(key, '*')
		if star < 0 {
			if key == requested && !strings.has_suffix(key, "/") { exact = object.members[key] }
			continue
		}
		if star < best_prefix || (star == best_prefix && len(key) < best_length) { continue }
		suffix := key[star + 1:]
		if strings.contains_rune(suffix, '*') { continue }
		if len(requested) < len(key) { continue }
		if !strings.has_prefix(requested, key[:star]) || !strings.has_suffix(requested, suffix) { continue }
		best, best_prefix, best_length = object.members[key], star, len(key)
		capture = requested[star:len(requested) - len(suffix)]
	}
	if has_subpaths && has_conditions { return nil, nil, .Invalid_Package_Config }
	if exact != nil { return exact, nil, .None }
	if best != nil { return best, capture, .None }
	if !internal && !has_subpaths && requested == "." { return target, nil, .None }
	return nil, nil, .Package_Path_Not_Exported
}

ModuleMapFrame :: struct {
	object: ^ModuleManifestObject,
	array: ^ModuleManifestArray,
	next: int,
	last_error: ModuleResolveError,
}

@(private="file")
module_resolver_map_target :: proc(
	target: ModuleManifestValue,
	package_dir: string,
	pattern: Maybe(string),
	internal: bool,
	options: ModuleResolveOptions,
	allocator: mem.Allocator,
) -> (ModuleMapTarget, ModuleResolveError) {
	parents: [128]ModuleMapFrame
	depth := 0
	next := target
	result: ModuleResolveError
	for next != nil || depth > 0 {
		if next != nil {
			frame: ModuleMapFrame
			#partial switch value in next {
			case string:
				path, err := module_resolver_map_path(value, package_dir, pattern, internal, allocator)
				if err != .Invalid_Package_Target { return path, err }
				result = err
			case ModuleManifestScalar:
				result = .Package_Path_Not_Exported if value == .Null else .Invalid_Package_Target
			case ^ModuleManifestObject:
				for key in value.order {
					if module_resolver_is_index_key(key) { return {}, .Invalid_Package_Config }
				}
				frame.object = value
			case ^ModuleManifestArray:
				if len(value.elements) == 0 {
					result = .Package_Path_Not_Exported
				} else {
					frame.array = value
				}
			case:
				result = .Invalid_Package_Target
			}
			if frame.object != nil || frame.array != nil {
				if depth == len(parents) { return {}, .Invalid_Package_Config }
				parents[depth] = frame
				depth += 1
			}
		}
		next = nil
		if depth == 0 { break }
		parent := &parents[depth - 1]
		if parent.array != nil {
			if result != .None { parent.last_error = result }
			if parent.next == len(parent.array.elements) {
				result = parent.last_error
				depth -= 1
				continue
			}
			next = parent.array.elements[parent.next]
			parent.next += 1
			result = .None
			continue
		}
		if result != .None || parent.next == len(parent.object.order) {
			depth -= 1
			continue
		}
		key := parent.object.order[parent.next]
		parent.next += 1
		if module_resolver_has_condition(key, options) { next = parent.object.members[key] }
	}
	return {}, result if result != .None else .Package_Path_Not_Exported
}

@(private="file")
module_resolver_is_index_key :: proc(key: string) -> bool {
	if len(key) == 0 || len(key) > 10 { return false }
	if key[0] == '0' { return len(key) == 1 }
	for digit in transmute([]byte)key {
		if digit < '0' || digit > '9' { return false }
	}
	value, ok := strconv.parse_u64(key, 10)
	return ok && value < u64(max(u32))
}

@(private="file")
module_resolver_has_condition :: proc(key: string, options: ModuleResolveOptions) -> bool {
	if key == "default" { return true }
	if key == "browser" && options.browser { return true }
	if key == "node" && !options.browser { return true }
	if key == "require" && options.mode == .Require { return true }
	if key == "import" && options.mode == .Import { return true }
	for condition in options.conditions {
		if key == condition { return true }
	}
	return false
}

@(private="file")
module_resolver_map_path :: proc(
	target, package_dir: string,
	pattern: Maybe(string),
	internal: bool,
	allocator: mem.Allocator,
) -> (ModuleMapTarget, ModuleResolveError) {
	local := strings.has_prefix(target, "./")
	path := target
	if local {
		path = target[2:]
		if !module_resolver_valid_export_path(path) { return {}, .Invalid_Package_Target }
	} else if !internal || strings.has_prefix(path, "/") || strings.has_prefix(path, "../") {
		return {}, .Invalid_Package_Target
	}
	if capture, matched := pattern.?; matched {
		if !module_resolver_valid_export_path(capture) { return {}, .Invalid_Specifier }
		path, _ = strings.replace_all(path, "*", capture, allocator)
		if path == "" { return {}, .Allocation_Error }
	}
	if !local {
		if path == "" || strings.contains_any(path, ":\\%?#") || strings.contains_rune(path, 0) {
			return {}, .Invalid_Package_Target
		}
		if _, _, valid := module_resolver_package_name(path); !valid { return {}, .Invalid_Package_Target }
		owned, err := strings.clone(path, allocator)
		if err != nil { return {}, .Allocation_Error }
		return {path = owned, external = true}, .None
	}
	joined, err := filepath.join({package_dir, path}, allocator)
	if err != nil { return {}, .Allocation_Error }
	return {path = joined}, .None
}

@(private="file")
module_resolver_valid_export_path :: proc(path: string) -> bool {
	if strings.contains_any(path, "\\%?#") || strings.contains_rune(path, 0) { return false }
	remaining := path
	for segment in strings.split_iterator(&remaining, "/") {
		if segment == "." || segment == ".." || strings.equal_fold(segment, "node_modules") {
			return false
		}
	}
	return true
}

// TypeScript resolves package-based configuration inheritance in ancestor
// node_modules directories independently of the bundler's package search list.
@(private)
module_resolver_tsconfig_package :: proc(specifier, start: string, allocator: mem.Allocator) -> (string, ModuleResolveError) {
	name, subpath, valid := module_resolver_package_name(specifier)
	if !valid { return "", .Invalid_TSConfig }
	directory := start
	for _ in 0..=len(start) {
		if filepath.base(directory) != "node_modules" {
			package_dir, join_err := filepath.join({directory, "node_modules", name}, allocator)
			if join_err != nil { return "", .Allocation_Error }
			if os.is_directory(package_dir) {
				result, err := module_resolver_tsconfig_package_at(package_dir, subpath, allocator)
				if err != .TSConfig_Not_Found { return result, err }
			}
		}
		parent := filepath.dir(directory)
		if parent == directory || parent == "" { break }
		directory = parent
	}
	return "", .TSConfig_Not_Found
}

@(private="file")
module_resolver_tsconfig_package_at :: proc(package_dir, subpath: string, allocator: mem.Allocator) -> (string, ModuleResolveError) {
	config, config_err := module_resolver_package_config(package_dir, allocator)
	if config_err != .None { return "", config_err }
	options := ModuleResolveOptions{mode = .Import, conditions = {"types"}, exports_fields = [][]string{{"exports"}}}
	if path, err := module_resolver_exports(config, package_dir, subpath, options, allocator); path != "" || err != .None {
		if err == .Not_Found || err == .Package_Path_Not_Exported { return "", .TSConfig_Not_Found }
		if err != .None { return "", err }
		if !strings.has_suffix(path, ".json") { return "", .TSConfig_Not_Found }
		return module_resolver_tsconfig_existing(path, allocator)
	}
	target := "tsconfig.json"
	if subpath != "" {
		target = subpath[1:]
	} else if config_path, ok := module_manifest_member(config, "tsconfig").(string); ok && config_path != "" {
		target = config_path
	}
	path, err := filepath.join({package_dir, target}, allocator)
	if err != nil { return "", .Allocation_Error }
	return module_resolver_tsconfig_existing(path, allocator)
}
