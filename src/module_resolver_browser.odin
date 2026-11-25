package kessel

import "core:mem"
import mvirtual "core:mem/virtual"
import "core:path/filepath"
import "core:strings"

ModuleBrowserRequest :: struct {
	specifier, importer: string,
}

ModuleBrowserMapping :: struct {
	scope, target: string,
	ignored: bool,
}

@(private)
module_resolver_browser :: proc(
	specifier, importer: string,
	options: ModuleResolveOptions,
	allocator: mem.Allocator,
) -> (ModuleResolution, ModuleResolveError) {
	if specifier == "" || importer == "" || strings.contains_rune(specifier, 0) || strings.contains_rune(importer, 0) {
		return {}, .Invalid_Specifier
	}
	scratch: mvirtual.Arena
	if err := mvirtual.arena_init_growing(&scratch); err != nil { return {}, .Allocation_Error }
	defer mvirtual.arena_destroy(&scratch)
	temp := mvirtual.arena_allocator(&scratch)

	request := ModuleBrowserRequest{specifier, importer}
	seen: [64]ModuleBrowserRequest
	// Alias and browser-field targets are configuration. When the caller asked
	// for fullySpecified, only the request as written must name its file exactly.
	step_options := options
	for index in 0..<len(seen) {
		mapped, alias_err := module_resolver_alias(request.specifier, options.aliases, temp)
		if alias_err != .None { return {}, alias_err }
		if mapped != request.specifier && step_options.fully_specified != nil {
			step_options.fully_specified = false
		}
		request.specifier = mapped
		for visited in seen[:index] {
			if visited == request { return {}, .Browser_Mapping_Cycle }
		}
		seen[index] = request

		result, replacement, err := module_resolver_browser_step(request, step_options, temp)
		if err != .None { return {}, err }
		if replacement.ignored { return {kind = .Ignored}, .None }
		if replacement.target == "" {
			path, clone_err := strings.clone(result.path, allocator)
			if clone_err != nil { return {}, .Allocation_Error }
			return {kind = result.kind, path = path}, .None
		}

		anchor, join_err := filepath.join({replacement.scope, "package.json"}, temp)
		if join_err != nil { return {}, .Allocation_Error }
		request = {replacement.target, anchor}
		if step_options.fully_specified != nil { step_options.fully_specified = false }
	}
	return {}, .Browser_Mapping_Cycle
}

@(private="file")
module_resolver_browser_step :: proc(
	request: ModuleBrowserRequest,
	options: ModuleResolveOptions,
	allocator: mem.Allocator,
) -> (ModuleResolution, ModuleBrowserMapping, ModuleResolveError) {
	start, start_err := module_resolver_importer_dir(request.importer, options.preserve_symlinks, allocator)
	if start_err != .None { return {}, {}, start_err }
	replacement, map_err := module_resolver_browser_lookup(start, request.specifier, allocator)
	if map_err != .None { return {}, {}, map_err }
	if module_resolver_has_browser_mapping(replacement) { return {}, replacement, .None }

	node_options := options
	node_options.aliases = nil
	resolved, err := module_resolver_once(request.specifier, request.importer, node_options, allocator, &replacement)
	if err == .None && module_resolver_has_browser_mapping(replacement) { return {}, replacement, .None }
	if err != .None || resolved.kind != .File { return resolved, {}, err }
	replacement, map_err = module_resolver_browser_lookup(filepath.dir(resolved.path), resolved.path, allocator)
	return resolved, replacement, map_err
}

@(private)
module_resolver_browser_lookup :: proc(
	start, specifier: string,
	allocator: mem.Allocator,
) -> (ModuleBrowserMapping, ModuleResolveError) {
	scope, config, err := module_resolver_package_scope(start, allocator)
	if err != .None { return {}, err }
	mapping, ok := module_manifest_member(config, "browser").(^ModuleManifestObject)
	if !ok { return {}, .None }

	key, key_err := module_resolver_browser_key(scope, start, specifier, allocator)
	if key_err != .None { return {}, key_err }
	if key == "" { return {}, .None }
	entry, listed := mapping.members[key]
	if !listed && strings.has_prefix(key, "./") {
		// Packages also write file keys without the leading "./". Bundlers
		// accept both spellings, and so does enhanced-resolve.
		entry = mapping.members[key[2:]]
	}
	#partial switch value in entry {
	case bool:
		if !value { return {ignored = true}, .None }
	case string:
		target := value
		if strings.contains_rune(target, 0) { return {}, .Invalid_Package_Target }
		if target != key { return {scope = scope, target = target}, .None }
	}
	return {}, .None
}

@(private)
module_resolver_has_browser_mapping :: proc(mapping: ModuleBrowserMapping) -> bool {
	return mapping.ignored || mapping.target != ""
}

@(private="file")
module_resolver_browser_key :: proc(scope, start, specifier: string, allocator: mem.Allocator) -> (string, ModuleResolveError) {
	path := specifier
	if module_resolver_is_relative(specifier) {
		joined, err := filepath.join({start, specifier}, allocator)
		if err != nil { return "", .Allocation_Error }
		path = joined
	}
	if !filepath.is_abs(path) { return specifier, .None }
	relative, rel_err := filepath.rel(scope, path, allocator)
	if rel_err != nil || relative == ".." || strings.has_prefix(relative, ".." + filepath.SEPARATOR_STRING) {
		return "", .None
	}
	when ODIN_OS == .Windows { relative, _ = strings.replace_all(relative, "\\", "/", allocator) }
	key, err := strings.concatenate({"./", relative}, allocator)
	if err != nil { return "", .Allocation_Error }
	return key, .None
}
