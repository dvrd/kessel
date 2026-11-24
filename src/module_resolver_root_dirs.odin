package kessel

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Anchor inherited entries where they were declared. TypeScript expands
// ${configDir} using the consuming configuration even in an extended file.
@(private)
module_resolver_tsconfig_roots :: proc(
	value: json.Value, origin, project_dir: string, allocator: mem.Allocator,
) -> ([]string, ModuleResolveError) {
	if _, cleared := value.(json.Null); cleared { return nil, .None }
	entries, ok := value.(json.Array)
	if !ok { return nil, .Invalid_TSConfig }
	roots, err := make([]string, len(entries), allocator)
	if err != nil { return nil, .Allocation_Error }
	for entry, i in entries {
		raw, valid := entry.(json.String)
		if !valid || strings.contains_rune(string(raw), 0) { return nil, .Invalid_TSConfig }
		path := string(raw)
		if strings.contains_rune(path, '\\') {
			path, _ = strings.replace_all(path, "\\", "/", allocator)
		}
		base := origin
		if strings.has_prefix(path, "${configDir}") {
			path = strings.trim_left(strings.trim_prefix(path, "${configDir}"), "/")
			base = project_dir
		}
		if filepath.is_abs(path) { base = "" }
		roots[i], err = filepath.join({base, path}, allocator)
		if err != nil { return nil, .Allocation_Error }
	}
	return roots, .None
}

@(private)
module_resolver_tsconfig_root_path :: proc(
	specifier, candidate: string, options: ModuleResolveOptions, allocator: mem.Allocator,
	browser_probe: ^ModuleBrowserMapping,
) -> (string, ModuleResolveError) {
	if strings.contains_rune(options.typescript_config, 0) { return "", .Invalid_TSConfig }
	config, err := module_resolver_tsconfig_load(options.typescript_config, allocator)
	if err != .None { return "", err }
	roots, ok := config.root_dirs.?
	if !ok || len(roots) == 0 { return "", .None }
	path, clean_err := filepath.clean(candidate, allocator)
	if clean_err != nil { return "", .Allocation_Error }
	directory_only := filepath.is_separator(specifier[len(specifier)-1])
	longest, match := -1, -1
	for root, i in roots {
		end := module_resolver_root_prefix(path, root, directory_only)
		// Absolute requests retain their lexical spelling. Relative requests can
		// already have a realpath importer when a workspace is symlinked.
		if end < 0 && !options.preserve_symlinks && os.is_directory(root) {
			canonical, abs_err := filepath.abs(root, allocator)
			if abs_err != nil { return "", .IO_Error }
			end = module_resolver_root_prefix(path, canonical, directory_only)
		}
		if end > longest { longest, match = end, i }
	}
	if match < 0 { return "", .None }
	result, probe := module_resolver_root_candidate(path, directory_only, options, allocator, browser_probe)
	if probe != .Not_Found { return result, probe }
	suffix := path[min(len(path), longest):]
	for root, i in roots {
		if i == match { continue }
		other, join_err := filepath.join({root, suffix}, allocator)
		if join_err != nil { return "", .Allocation_Error }
		result, probe = module_resolver_root_candidate(other, directory_only, options, allocator, browser_probe)
		if probe != .Not_Found { return result, probe }
	}
	return "", .None
}

@(private="file")
module_resolver_root_prefix :: proc(path, root: string, directory_only: bool) -> int {
	assert(len(root) > 0)
	if !strings.has_prefix(path, root) { return -1 }
	end := len(root)
	if len(path) == end && !directory_only { return -1 }
	if filepath.is_separator(root[end-1]) { return end }
	if len(path) > end && !filepath.is_separator(path[end]) { return -1 }
	return end + 1
}

@(private="file")
module_resolver_root_candidate :: proc(
	path: string, directory_only: bool, options: ModuleResolveOptions,
	allocator: mem.Allocator, browser_probe: ^ModuleBrowserMapping,
) -> (string, ModuleResolveError) {
	if !directory_only {
		extension := filepath.ext(path)
		if len(extension) > 0 && (extension in options.extension_alias || extension[1:] in options.extension_alias) {
			file, err := module_resolver_extension_alias(path, options.extension_alias, allocator, browser_probe)
			if err != .Not_Found || !os.is_directory(path) { return file, err }
		} else {
			file, err := module_resolver_root_file(path, allocator, browser_probe)
			if err != .Not_Found { return file, err }
		}
	}
	if !os.is_directory(path) { return "", .Not_Found }
	manifest, err := module_resolver_package_config(path, allocator)
	if err != .None { return "", err }
	fields := [?]string{"typings", "types", "main"}
	for field in fields {
		entry, found := module_manifest_member(manifest, field).(string)
		if !found || entry == "" { continue }
		target, join_err := module_resolver_tsconfig_base(path, entry, allocator)
		if join_err != nil { return "", .Allocation_Error }
		suffixs := [?]string{".ts", ".tsx", ".cts", ".mts"}
		for suffix in suffixs {
			if strings.has_suffix(target, suffix) && os.is_file(target) { return target, .None }
		}
		file, probe := module_resolver_root_file(target, allocator, browser_probe)
		if probe != .Not_Found { return file, probe }
		if os.is_directory(target) {
			file, probe = module_resolver_root_index(target, allocator, browser_probe)
			if probe != .Not_Found { return file, probe }
		}
		break
	}
	return module_resolver_root_index(path, allocator, browser_probe)
}

@(private="file")
module_resolver_root_index :: proc(path: string, allocator: mem.Allocator, browser_probe: ^ModuleBrowserMapping) -> (string, ModuleResolveError) {
	index, err := filepath.join({path, "index"}, allocator)
	if err != nil { return "", .Allocation_Error }
	return module_resolver_root_file(index, allocator, browser_probe)
}

// TypeScript first substitutes a recognized extension, then appends source
// extensions to the whole filename. A physical CSS asset must not hide a
// virtual declaration such as theme.d.css.ts.
@(private="file")
module_resolver_root_file :: proc(path: string, allocator: mem.Allocator, browser_probe: ^ModuleBrowserMapping) -> (string, ModuleResolveError) {
	extension := filepath.ext(path)
	declarations := [?]string{".d.ts", ".d.cts", ".d.mts"}
	for declaration in declarations {
		if strings.has_suffix(path, declaration) { extension = declaration; break }
	}
	if extension != "" {
		stem := strings.trim_suffix(path, extension)
		file, err := module_resolver_tsconfig_replace_extension(stem, extension, allocator, browser_probe)
		if err != .Not_Found { return file, err }
	}
	return module_resolver_probe_extensions(path, {".ts", ".tsx", ".d.ts", ".js", ".jsx"}, allocator, browser_probe)
}

@(private)
module_resolver_tsconfig_replace_extension :: proc(stem, extension: string, allocator: mem.Allocator, browser_probe: ^ModuleBrowserMapping) -> (string, ModuleResolveError) {
	suffixes: []string
	switch extension {
	case ".d.ts", ".ts", ".js": suffixes = {".ts", ".tsx", ".d.ts", ".js", ".jsx"}
	case ".tsx", ".jsx": suffixes = {".tsx", ".ts", ".d.ts", ".jsx", ".js"}
	case ".mts", ".mjs", ".d.mts": suffixes = {".mts", ".d.mts", ".mjs"}
	case ".cts", ".cjs", ".d.cts": suffixes = {".cts", ".d.cts", ".cjs"}
	case ".json": suffixes = {".d.json.ts", ".json"}
	case:
		declaration, err := strings.concatenate({".d", extension, ".ts"}, allocator)
		if err != nil { return "", .Allocation_Error }
		suffixes = {declaration}
	}
	return module_resolver_probe_extensions(stem, suffixes, allocator, browser_probe)
}
