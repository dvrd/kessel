package kessel

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

// TypeScript's paths and baseUrl apply to non-relative specifiers. An empty
// result lets the caller continue ordinary package resolution.
@(private)
module_resolver_tsconfig_path :: proc(
	specifier, filename: string,
	allocator: mem.Allocator,
) -> (string, ModuleResolveError) {
	context.allocator = allocator
	if strings.contains_rune(filename, 0) { return "", .Invalid_TSConfig }
	options, config_err := module_resolver_tsconfig_load(filename, allocator)
	if config_err != .None { return "", config_err }
	paths_base := options.base_url
	if !options.has_base_url { paths_base = options.paths_base }

	if len(options.paths) > 0 {
		// The object map provides decoded values. The token stream supplies
		// their definition order for wildcard patterns with equal prefixes.
		cursor := json.make_parser(options.paths_source, .JSON5, false, allocator)
		if !module_resolver_json_member(&cursor, "compilerOptions", allocator) ||
		   !module_resolver_json_member(&cursor, "paths", allocator) { return "", .Invalid_TSConfig }
		capture, targets, select_err := module_resolver_tsconfig_select(&cursor, specifier, options.paths, allocator)
		if select_err != .None { return "", select_err }
		for target in targets {
			substitution := string(target.(json.String))
			path, path_err := module_resolver_tsconfig_expand(substitution, capture, paths_base, allocator)
			if path_err != .None { return "", path_err }
			switch filepath.ext(substitution) {
			case ".js", ".jsx", ".ts", ".tsx", ".cjs", ".mjs", ".cts", ".mts", ".json":
				if os.is_file(path) { return path, .None }
			}
			result, probe_err := module_resolver_tsconfig_probe(path, allocator)
			if result != "" || probe_err != .None { return result, probe_err }
		}
	}

	if options.has_base_url {
		path, path_err := filepath.join({options.base_url, specifier}, allocator)
		if path_err != nil { return "", .Allocation_Error }
		return module_resolver_tsconfig_probe(path, allocator)
	}
	return "", .None
}

ModuleTSConfigOptions :: struct {
	paths: json.Object,
	paths_source: string,
	paths_base: string,
	base_url: string,
	has_base_url: bool,
	root_dirs: Maybe([]string),
}

ModuleTSConfigFrame :: struct {
	filename, identity: string,
	own: ModuleTSConfigOptions,
	inherited: ModuleTSConfigOptions,
	parents: []string,
	next_parent: int,
}

@(private)
module_resolver_tsconfig_load :: proc(filename: string, allocator: mem.Allocator) -> (ModuleTSConfigOptions, ModuleResolveError) {
	MAX_CONFIG_DEPTH :: 64
	project_dir, dir_err := module_resolver_importer_dir(filename, true, allocator)
	if dir_err != .None { return {}, dir_err }
	entry, entry_err := module_resolver_tsconfig_read(filename, project_dir, allocator)
	if entry_err != .None { return {}, entry_err }
	frames: [MAX_CONFIG_DEPTH]ModuleTSConfigFrame
	frames[0] = entry
	cache := make(map[string]ModuleTSConfigOptions, allocator)
	depth := 1
	for depth > 0 {
		frame := &frames[depth - 1]
		if frame.next_parent == len(frame.parents) {
			combined := frame.inherited
			module_resolver_tsconfig_merge(&combined, frame.own)
			cache[frame.filename] = combined
			depth -= 1
			if depth == 0 { return combined, .None }
			module_resolver_tsconfig_merge(&frames[depth - 1].inherited, combined)
			continue
		}
		parent := frame.parents[frame.next_parent]
		frame.next_parent += 1
		target, target_err := module_resolver_tsconfig_parent(parent, filepath.dir(frame.filename), allocator)
		if target_err != .None { return {}, target_err }
		if cached, ok := cache[target]; ok {
			module_resolver_tsconfig_merge(&frame.inherited, cached)
			continue
		}
		if depth == len(frames) { return {}, .Invalid_TSConfig }
		next, next_err := module_resolver_tsconfig_read(target, project_dir, allocator)
		if next_err != .None { return {}, next_err }
		for index in 0..<depth {
			if frames[index].identity == next.identity { return {}, .Invalid_TSConfig }
		}
		frames[depth] = next
		depth += 1
	}
	unreachable()
}

@(private="file")
module_resolver_tsconfig_read :: proc(filename, project_dir: string, allocator: mem.Allocator) -> (ModuleTSConfigFrame, ModuleResolveError) {
	source, read_err := os.read_entire_file_from_path(filename, allocator)
	if read_err == .Not_Exist { return {}, .TSConfig_Not_Found }
	if read_err != nil { return {}, .IO_Error }
	path, path_err := filepath.abs(filename, allocator)
	if path_err != nil { return {}, .IO_Error }
	dir := filepath.dir(path)
	config, parse_err := json.parse(source, .JSON5, false, allocator)
	if parse_err != nil { return {}, .Invalid_TSConfig }
	root, root_ok := config.(json.Object)
	if !root_ok { return {}, .Invalid_TSConfig }
	origin, dir_err := module_resolver_importer_dir(filename, true, allocator)
	if dir_err != .None { return {}, dir_err }
	options, options_err := module_resolver_tsconfig_options(root, origin, project_dir, allocator)
	if options_err != .None { return {}, options_err }
	if options.paths != nil {
		options.paths_source = string(source)
		options.paths_base = dir
	}
	if options.has_base_url {
		base, base_err := module_resolver_tsconfig_base(dir, options.base_url, allocator)
		if base_err != nil { return {}, .Allocation_Error }
		options.base_url = base
	}
	parents, parents_err := module_resolver_tsconfig_parents(root, allocator)
	if parents_err != .None { return {}, parents_err }
	// One physical config can be reached through different workspace links.
	// Cache its anchored options by lexical location and detect cycles by identity.
	location, location_err := filepath.join({origin, filepath.base(filename)}, allocator)
	if location_err != nil { return {}, .Allocation_Error }
	return {filename = location, identity = path, own = options, parents = parents}, .None
}

@(private="file")
module_resolver_tsconfig_parents :: proc(root: json.Object, allocator: mem.Allocator) -> ([]string, ModuleResolveError) {
	value, exists := root["extends"]
	if !exists { return nil, .None }
	#partial switch value in value {
	case json.String:
		single, err := make([]string, 1, allocator)
		if err != nil { return nil, .Allocation_Error }
		single[0] = string(value)
		return single, .None
	case json.Array:
		parents, err := make([]string, len(value), allocator)
		if err != nil { return nil, .Allocation_Error }
		for item, index in value {
			text, ok := item.(json.String)
			if !ok { return nil, .Invalid_TSConfig }
			parents[index] = string(text)
		}
		return parents, .None
	case:
		return nil, .Invalid_TSConfig
	}
}

@(private="file")
module_resolver_tsconfig_merge :: proc(result: ^ModuleTSConfigOptions, source: ModuleTSConfigOptions) {
	assert(result != nil)
	if source.root_dirs != nil { result.root_dirs = source.root_dirs }
	if source.has_base_url {
		result.base_url = source.base_url
		result.has_base_url = true
	}
	if source.paths != nil {
		result.paths = source.paths
		result.paths_source = source.paths_source
		result.paths_base = source.paths_base
	}
}

@(private="file")
module_resolver_tsconfig_parent :: proc(parent, directory: string, allocator: mem.Allocator) -> (string, ModuleResolveError) {
	if parent == "" || strings.contains_rune(parent, 0) { return "", .Invalid_TSConfig }
	if filepath.is_abs(parent) { return module_resolver_tsconfig_existing(parent, allocator) }
	if !strings.has_prefix(parent, "./") && !strings.has_prefix(parent, "../") {
		return module_resolver_tsconfig_package(parent, directory, allocator)
	}
	path, err := filepath.join({directory, parent}, allocator)
	if err != nil { return "", .Allocation_Error }
	return module_resolver_tsconfig_existing(path, allocator)
}

@(private)
module_resolver_tsconfig_existing :: proc(candidate: string, allocator: mem.Allocator) -> (string, ModuleResolveError) {
	path := candidate
	if !os.is_file(path) && !strings.has_suffix(path, ".json") {
		path_with_extension, err := strings.concatenate({path, ".json"}, allocator)
		if err != nil { return "", .Allocation_Error }
		path = path_with_extension
	}
	if !os.is_file(path) { return "", .TSConfig_Not_Found }
	assert(filepath.is_abs(path))
	lexical, err := filepath.clean(path, allocator)
	if err != nil { return "", .Allocation_Error }
	return lexical, .None
}

@(private="file")
module_resolver_tsconfig_options :: proc(
	root: json.Object, origin, project_dir: string, allocator: mem.Allocator,
) -> (ModuleTSConfigOptions, ModuleResolveError) {
	options: ModuleTSConfigOptions
	value, exists := root["compilerOptions"]
	if !exists { return options, .None }
	raw, ok := value.(json.Object)
	if !ok { return {}, .Invalid_TSConfig }
	if base, has_base := raw["baseUrl"]; has_base {
		value, valid := base.(json.String)
		if !valid || strings.contains_rune(string(value), 0) { return {}, .Invalid_TSConfig }
		options.base_url = string(value)
		options.has_base_url = true
	}
	if roots, exists := raw["rootDirs"]; exists {
		list, err := module_resolver_tsconfig_roots(roots, origin, project_dir, allocator)
		if err != .None { return {}, err }
		options.root_dirs = list
	}
	if paths, has_paths := raw["paths"]; has_paths {
		table, valid := paths.(json.Object)
		if !valid { return {}, .Invalid_TSConfig }
		for pattern, value in table {
			if strings.count(pattern, "*") > 1 { return {}, .Invalid_TSConfig }
			targets, array_ok := value.(json.Array)
			if !array_ok || len(targets) == 0 { return {}, .Invalid_TSConfig }
			for target in targets {
				text, string_ok := target.(json.String)
				if !string_ok || text == "" || strings.contains_rune(string(text), 0) {
					return {}, .Invalid_TSConfig
				}
				if strings.count(string(text), "*") > 1 { return {}, .Invalid_TSConfig }
			}
		}
		options.paths = table
	}
	return options, .None
}

@(private)
module_resolver_tsconfig_base :: proc(directory, base_url: string, allocator: mem.Allocator) -> (string, mem.Allocator_Error) {
	if base_url == "" { return directory, nil }
	if filepath.is_abs(base_url) { return base_url, nil }
	return filepath.join({directory, base_url}, allocator)
}

// Position a JSON cursor at the named member's value. Store the last member
// to match the duplicate-key behavior of the decoded object.
@(private="file")
module_resolver_json_member :: proc(cursor: ^json.Parser, wanted: string, allocator: mem.Allocator) -> bool {
	if !json.allow_token(cursor, .Open_Brace) { return false }
	found: Maybe(json.Parser)
	for cursor.curr_token.kind != .Close_Brace {
		key, err := json.parse_object_key(cursor, allocator)
		if err != nil { return false }
		if json.parse_colon(cursor) != nil { return false }
		if key == wanted { found = cursor^ }
		if _, value_err := json.parse_value(cursor); value_err != nil { return false }
		if !json.allow_token(cursor, .Comma) { break }
	}
	if result, ok := found.?; ok {
		cursor^ = result
		return true
	}
	return false
}

@(private="file")
module_resolver_tsconfig_select :: proc(
	cursor: ^json.Parser,
	specifier: string,
	mappings: json.Object,
	allocator: mem.Allocator,
) -> (Maybe(string), json.Array, ModuleResolveError) {
	if targets, ok := mappings[specifier].(json.Array); ok && !strings.contains_rune(specifier, '*') {
		return nil, targets, .None
	}
	if !json.allow_token(cursor, .Open_Brace) { return nil, nil, .Invalid_TSConfig }
	prefix_length := -1
	best: json.Array
	capture: Maybe(string)
	for cursor.curr_token.kind != .Close_Brace {
		key, err := json.parse_object_key(cursor, allocator)
		if err != nil { return nil, nil, .Invalid_TSConfig }
		if json.parse_colon(cursor) != nil { return nil, nil, .Invalid_TSConfig }
		star := strings.index_byte(key, '*')
		if star > prefix_length {
			suffix := key[star + 1:]
			if len(specifier) >= len(key) - 1 && strings.has_prefix(specifier, key[:star]) &&
			   strings.has_suffix(specifier, suffix) {
				prefix_length = star
				best = mappings[key].(json.Array)
				capture = specifier[star:len(specifier) - len(suffix)]
			}
		}
		if _, value_err := json.parse_value(cursor); value_err != nil { return nil, nil, .Invalid_TSConfig }
		if !json.allow_token(cursor, .Comma) { break }
	}
	return capture, best, .None
}

@(private="file")
module_resolver_tsconfig_expand :: proc(
	target: string,
	capture: Maybe(string),
	base: string,
	allocator: mem.Allocator,
) -> (string, ModuleResolveError) {
	target := target
	if matched, ok := capture.?; ok {
		if star := strings.index_byte(target, '*'); star >= 0 {
			expanded, err := strings.concatenate({target[:star], matched, target[star + 1:]}, allocator)
			if err != nil { return "", .Allocation_Error }
			target = expanded
		}
	}
	if filepath.is_abs(target) { return target, .None }
	path, err := filepath.join({base, target}, allocator)
	if err != nil { return "", .Allocation_Error }
	return path, .None
}

@(private="file")
module_resolver_tsconfig_probe :: proc(path: string, allocator: mem.Allocator) -> (string, ModuleResolveError) {
	extension := filepath.ext(path)
	switch extension {
	case ".js", ".jsx", ".mjs", ".cjs":
		target := strings.trim_suffix(path, extension)
		file, err := module_resolver_tsconfig_replace_extension(target, extension, allocator, nil)
		if err == .Not_Found { return "", .None }
		return file, err
	}
	if extension != "" && os.is_file(path) { return path, .None }
	file, err := module_resolver_probe_suffixes(path, {".ts", ".tsx", ".d.ts", ".js", ".jsx", ""}, allocator)
	if file != "" || err != .None || !os.is_directory(path) { return file, err }
	index, join_err := filepath.join({path, "index"}, allocator)
	if join_err != nil { return "", .Allocation_Error }
	return module_resolver_probe_suffixes(index, {".ts", ".tsx", ".d.ts", ".js", ".jsx"}, allocator)
}

@(private="file")
module_resolver_probe_suffixes :: proc(path: string, suffixes: []string, allocator: mem.Allocator) -> (string, ModuleResolveError) {
	for suffix in suffixes {
		candidate, err := strings.concatenate({path, suffix}, allocator)
		if err != nil { return "", .Allocation_Error }
		if os.is_file(candidate) { return candidate, .None }
	}
	return "", .None
}
