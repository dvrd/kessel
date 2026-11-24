package kessel

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:text/regex"
import regex_common "core:text/regex/common"

// Bundler-oriented lookup options in the style of enhanced-resolve: server
// roots, fallbacks tried after a failed resolution, result restrictions, and
// TypeScript project references.

ModuleResolveFallback :: struct {
	name: string,
	target: string,
	// The name must equal the whole request rather than its first segments.
	exact: bool,
	// Report the request as ignored instead of resolving a target.
	ignore: bool,
}

// Exactly one member is set. A path admits itself and everything below it.
// A pattern is searched for in the candidate filename using core:text/regex
// syntax.
ModuleResolveRestriction :: struct {
	path: string,
	regex: string,
}

ModuleRestrictionMatcher :: struct {
	path: string,
	pattern: regex.Regular_Expression,
	is_pattern: bool,
	// Working memory for one match. It is released with the compiled patterns.
	scratch: mem.Allocator,
}

MODULE_RESOLVER_RESTRICTIONS_MAX :: 64

@(private)
module_resolver_compile_restrictions :: proc(
	restrictions: []ModuleResolveRestriction,
	allocator: mem.Allocator,
) -> ([]ModuleRestrictionMatcher, ModuleResolveError) {
	assert(len(restrictions) > 0)
	if len(restrictions) > MODULE_RESOLVER_RESTRICTIONS_MAX { return nil, .Invalid_Restriction }
	matchers, make_err := make([]ModuleRestrictionMatcher, len(restrictions), allocator)
	if make_err != nil { return nil, .Allocation_Error }
	for restriction, index in restrictions {
		has_path := restriction.path != ""
		has_pattern := restriction.regex != ""
		if has_path == has_pattern { return nil, .Invalid_Restriction }
		if has_path {
			if !filepath.is_abs(restriction.path) { return nil, .Invalid_Restriction }
			path, clean_err := filepath.clean(restriction.path, allocator)
			if clean_err != nil { return nil, .Allocation_Error }
			matchers[index] = {path = path}
			continue
		}
		pattern, pattern_err := regex.create(restriction.regex, {.No_Capture}, allocator, allocator)
		if pattern_err != nil { return nil, .Invalid_Restriction }
		matchers[index] = {pattern = pattern, is_pattern = true, scratch = allocator}
	}
	return matchers, .None
}

// Every restriction must admit the candidate. The candidate is the lexical
// path that was probed, before symbolic links are followed.
@(private)
module_resolver_restrictions_allow :: proc(
	path: string,
	matchers: []ModuleRestrictionMatcher,
) -> bool {
	for matcher in matchers {
		if matcher.is_pattern {
			// The matcher insists on room for every group even when none is captured.
			positions: [regex_common.MAX_CAPTURE_GROUPS][2]int
			groups: [regex_common.MAX_CAPTURE_GROUPS]string
			capture := regex.Capture{pos = positions[:], groups = groups[:]}
			_, matched := regex.match_with_preallocated_capture(
				matcher.pattern, path, &capture, matcher.scratch,
			)
			if !matched { return false }
		} else {
			if !module_resolver_path_contains(matcher.path, path) { return false }
		}
	}
	return true
}

@(private="file")
module_resolver_path_contains :: proc(parent, path: string) -> bool {
	if !strings.has_prefix(path, parent) { return false }
	if len(path) == len(parent) { return true }
	if strings.has_suffix(parent, filepath.SEPARATOR_STRING) { return true }
	return path[len(parent)] == filepath.SEPARATOR
}

// Resolve a relative or absolute filesystem request. Server-relative
// requests ("/assets/a.js") are tried below each configured root before the
// filesystem root, or after it when absolute paths are preferred.
@(private)
module_resolver_request_path :: proc(
	specifier, start: string,
	options: ModuleResolveOptions,
	temp: mem.Allocator,
	browser_probe: ^ModuleBrowserMapping,
) -> (string, ModuleResolveError) {
	specifier := specifier
	if options.mode == .Import {
		path, url_err := module_resolver_url_path(specifier, temp)
		if url_err != .None { return "", url_err }
		specifier = path
	}
	absolute := filepath.is_abs(specifier)
	use_roots := absolute && len(options.roots) > 0
	if use_roots && !options.prefer_absolute {
		if path := module_resolver_roots(specifier, start, options, temp, browser_probe); path != "" {
			return path, .None
		}
	}
	target := specifier
	if !absolute {
		joined, join_err := filepath.join({start, target}, temp)
		if join_err != nil { return "", .Allocation_Error }
		target = joined
	}
	resolved: string
	err: ModuleResolveError
	if options.typescript_config != "" {
		resolved, err = module_resolver_tsconfig_root_path(
			specifier, target, options, temp, browser_probe,
		)
	}
	if resolved == "" && err == .None {
		directory_only := specifier == "." || specifier == ".." || strings.has_suffix(specifier, "/")
		resolved, err = module_resolver_load_path(target, options, temp, browser_probe, directory_only)
	}
	if err != .None && use_roots && options.prefer_absolute {
		if path := module_resolver_roots(specifier, start, options, temp, browser_probe); path != "" {
			return path, .None
		}
	}
	return resolved, err
}

// Node's ES module loader reads a relative specifier as a URL. The query and
// fragment do not name the file, and percent escapes are decoded. Node
// rejects an encoded path separator and a malformed escape.
@(private)
module_resolver_url_path :: proc(
	specifier: string,
	allocator: mem.Allocator,
) -> (string, ModuleResolveError) {
	path := specifier
	if cut := strings.index_any(path, "?#"); cut >= 0 { path = path[:cut] }
	if path == "" { return "", .Invalid_Specifier }
	if !strings.contains_rune(path, '%') { return path, .None }
	decoded, make_err := make([]u8, len(path), allocator)
	if make_err != nil { return "", .Allocation_Error }
	length := 0
	for index := 0; index < len(path); index += 1 {
		unit := path[index]
		if unit == '%' {
			if index + 2 >= len(path) { return "", .Invalid_Specifier }
			high, low := hex_digit_val(path[index + 1]), hex_digit_val(path[index + 2])
			if high < 0 || low < 0 { return "", .Invalid_Specifier }
			unit = u8(high * 16 + low)
			if unit == '/' || unit == '\\' || unit == 0 { return "", .Invalid_Specifier }
			index += 2
		}
		decoded[length] = unit
		length += 1
	}
	return string(decoded[:length]), .None
}

// With prefer_relative a bare request names a sibling file before a package.
// An empty result sends the caller on to package lookup.
@(private)
module_resolver_request_sibling :: proc(
	specifier, start: string,
	options: ModuleResolveOptions,
	temp: mem.Allocator,
	browser_probe: ^ModuleBrowserMapping,
) -> string {
	assert(options.prefer_relative)
	target, join_err := filepath.join({start, specifier}, temp)
	if join_err != nil { return "" }
	directory_only := strings.has_suffix(specifier, "/")
	path, err := module_resolver_load_path(target, options, temp, browser_probe, directory_only)
	if err != .None { return "" }
	return path
}

// "/" alone names the importing directory when that directory is a root.
// Any other server-relative request is looked up below each root in order.
@(private="file")
module_resolver_roots :: proc(
	specifier, start: string,
	options: ModuleResolveOptions,
	temp: mem.Allocator,
	browser_probe: ^ModuleBrowserMapping,
) -> string {
	assert(len(options.roots) > 0)
	tail := strings.trim_left(specifier, "/")
	for root in options.roots {
		if !filepath.is_abs(root) { continue }
		directory := root
		if !options.preserve_symlinks && os.is_directory(root) {
			actual, abs_err := filepath.abs(root, temp)
			if abs_err != nil { continue }
			directory = actual
		}
		target := directory
		if tail == "" {
			cleaned, clean_err := filepath.clean(directory, temp)
			if clean_err != nil || cleaned != start { continue }
		} else {
			joined, join_err := filepath.join({directory, tail}, temp)
			if join_err != nil { continue }
			target = joined
		}
		directory_only := tail == "" || strings.has_suffix(tail, "/")
		path, err := module_resolver_load_path(target, options, temp, browser_probe, directory_only)
		if err == .None && path != "" { return path }
	}
	return ""
}

// Try each fallback whose name covers the failed request. The original
// failure is reported when no fallback target resolves.
@(private)
module_resolver_fallback :: proc(
	specifier, start: string,
	failure: ModuleResolveError,
	options: ModuleResolveOptions,
	temp: mem.Allocator,
	browser_probe: ^ModuleBrowserMapping,
) -> (ModuleResolution, ModuleResolveError) {
	assert(failure != .None)
	assert(len(options.fallback) > 0)
	retry := options
	// A fallback target is configuration, not an import written by a user,
	// so it may omit its extension even when imports must be fully specified.
	retry.fully_specified = false
	for entry in options.fallback {
		if entry.name == "" || strings.contains_rune(entry.target, 0) { return {}, .Invalid_Alias }
		tail, covered := module_resolver_fallback_tail(specifier, entry)
		if !covered { continue }
		if entry.ignore { return {kind = .Ignored}, .None }
		if entry.target == "" { return {}, .Invalid_Alias }
		// A target that covers the request would map it onto itself.
		if specifier == entry.target { continue }
		if strings.has_prefix(specifier, entry.target) && specifier[len(entry.target)] == '/' { continue }

		next := entry.target
		if tail != "" {
			// A file cannot contain the remaining segments of the request.
			if os.is_file(entry.target) { continue }
			joined, join_err := strings.concatenate({strings.trim_right(entry.target, "/"), "/", tail}, temp)
			if join_err != nil { return {}, .Allocation_Error }
			next = joined
		}
		if len(options.aliases) > 0 {
			mapped, map_err := module_resolver_alias(next, options.aliases, temp)
			if map_err != .None { return {}, map_err }
			next = mapped
		}
		result, err := module_resolver_request(next, start, retry, temp, browser_probe)
		if err == .None { return result, .None }
	}
	return {}, failure
}

@(private="file")
module_resolver_fallback_tail :: proc(
	specifier: string,
	entry: ModuleResolveFallback,
) -> (tail: string, covered: bool) {
	if specifier == entry.name { return "", true }
	if entry.exact || !strings.has_prefix(specifier, entry.name) { return "", false }
	rest := specifier[len(entry.name):]
	if rest[0] != '/' { return "", false }
	return strings.trim_left(rest, "/"), true
}

MODULE_RESOLVER_REFERENCES_MAX :: 256

// Select the configuration that governs an importing directory. A project
// listed under "references" owns the files below its paths base, which is its
// baseUrl when set and its own directory otherwise. References are read from
// the given file only. TypeScript does not inherit them through "extends".
@(private)
module_resolver_tsconfig_reference :: proc(
	filename, start: string,
	allocator: mem.Allocator,
) -> (string, ModuleResolveError) {
	assert(filename != "")
	context.allocator = allocator
	source, read_err := os.read_entire_file_from_path(filename, allocator)
	if read_err == .Not_Exist { return "", .TSConfig_Not_Found }
	if read_err != nil { return "", .IO_Error }
	config, parse_err := json.parse(source, .JSON5, false, allocator)
	if parse_err != nil { return "", .Invalid_TSConfig }
	root, root_ok := config.(json.Object)
	if !root_ok { return "", .Invalid_TSConfig }
	references, has_references := root["references"].(json.Array)
	if !has_references { return filename, .None }
	if len(references) > MODULE_RESOLVER_REFERENCES_MAX { return "", .Invalid_TSConfig }

	origin, dir_err := module_resolver_importer_dir(filename, true, allocator)
	if dir_err != .None { return "", dir_err }
	for reference in references {
		entry, entry_ok := reference.(json.Object)
		if !entry_ok { return "", .Invalid_TSConfig }
		relative, path_ok := entry["path"].(json.String)
		if !path_ok || strings.contains_rune(string(relative), 0) { return "", .Invalid_TSConfig }
		project, project_err := module_resolver_tsconfig_project(origin, string(relative), allocator)
		if project_err != .None { return "", project_err }
		options, load_err := module_resolver_tsconfig_load(project, allocator)
		if load_err != .None { return "", load_err }
		base := options.base_url if options.has_base_url else filepath.dir(project)
		if module_resolver_path_contains(base, start) { return project, .None }
	}
	return filename, .None
}

// A reference names a configuration file or a directory holding tsconfig.json.
@(private)
module_resolver_tsconfig_project :: proc(
	origin, relative: string,
	allocator: mem.Allocator,
) -> (string, ModuleResolveError) {
	base := origin if !filepath.is_abs(relative) else ""
	path, join_err := filepath.join({base, relative}, allocator)
	if join_err != nil { return "", .Allocation_Error }
	if os.is_directory(path) {
		nested, nested_err := filepath.join({path, "tsconfig.json"}, allocator)
		if nested_err != nil { return "", .Allocation_Error }
		path = nested
	}
	if !os.is_file(path) { return "", .TSConfig_Not_Found }
	return path, .None
}
