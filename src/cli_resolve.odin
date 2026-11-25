package kessel

import "core:encoding/json"
import "core:fmt"
import "core:strings"

CLI_RESOLVE_USAGE :: "Usage: kessel resolve <specifier> --from <file> [--require] [--browser] [--tsconfig <file>] [--condition <name>] [--exports-fields <json>] [--imports-fields <json>] [--main-field <name>] [--no-main-fields] [--module-dir <directory>] [--no-module-dirs] [--extension <suffix>] [--extension-alias <suffix=targets>] [--no-extensions] [--main-file <name>] [--no-main-files] [--alias <name=target>] [--preserve-symlinks] [--root <directory>] [--fallback <name=target>] [--fallback-ignore <name>] [--restriction <directory>] [--restriction-regex <pattern>] [--fully-specified] [--no-fully-specified] [--prefer-relative] [--prefer-absolute] [--resolve-to-context] [--explicit-conditions] [--tsconfig-references]"

@(private)
cli_resolve_module :: proc(args: []string) -> int {
	if len(args) == 0 {
		fmt.eprintln(CLI_RESOLVE_USAGE)
		return 2
	}
	if args[0] == "--help" || args[0] == "-h" {
		out_println(CLI_RESOLVE_USAGE)
		return 0
	}
	context.allocator = context.temp_allocator
	options := ModuleResolveOptions{mode = .Import}
	importer := cli_resolve_options(args[1:], &options)
	if importer == "" { return 2 }
	result, resolve_err := module_resolve(args[0], importer, options, context.allocator)
	if resolve_err != .None {
		fmt.eprintf("Error: %s (%v)\n", args[0], resolve_err)
		return 1
	}
	return cli_resolve_write(result)
}

@(private="file")
CliResolveLists :: struct {
	importer: string,
	conditions, main_fields, extensions, main_files, modules, roots: [dynamic]string,
	aliases: [dynamic]ModuleResolveAlias,
	fallback: [dynamic]ModuleResolveFallback,
	restrictions: [dynamic]ModuleResolveRestriction,
	extension_alias: map[string][]string,
}

@(private="file")
cli_resolve_options :: proc(args: []string, options: ^ModuleResolveOptions) -> string {
	lists: CliResolveLists
	lists.extension_alias = make(map[string][]string, context.temp_allocator)
	for i := 0; i < len(args); i += 1 {
		flag := args[i]
		if cli_resolve_switch(flag, options, &lists) { continue }
		if !cli_resolve_takes_value(flag) {
			fmt.eprintf("Error: unknown resolve option '%s'\n", flag)
			return ""
		}
		i += 1
		allows_empty := flag == "--extension" || flag == "--module-dir" || flag == "--main-field"
		if i == len(args) || (args[i] == "" && !allows_empty) {
			fmt.eprintf("Error: %s requires a value\n", flag)
			return ""
		}
		if !cli_resolve_value(flag, args[i], options, &lists) { return "" }
	}
	if lists.importer == "" {
		fmt.eprintln("Error: resolve requires --from <file>")
		return ""
	}
	options.conditions = lists.conditions[:]
	options.aliases = lists.aliases[:]
	options.roots = lists.roots[:]
	options.fallback = lists.fallback[:]
	options.restrictions = lists.restrictions[:]
	options.extension_alias = lists.extension_alias
	return lists.importer
}

// Flags without a value. A "--no-" flag sets an explicitly empty list, which
// differs from leaving the option at its default.
@(private="file")
cli_resolve_switch :: proc(flag: string, options: ^ModuleResolveOptions, lists: ^CliResolveLists) -> bool {
	switch flag {
	case "--require": options.mode = .Require
	case "--browser": options.browser = true
	case "--preserve-symlinks": options.preserve_symlinks = true
	case "--fully-specified": options.fully_specified = true
	case "--no-fully-specified": options.fully_specified = false
	case "--prefer-relative": options.prefer_relative = true
	case "--prefer-absolute": options.prefer_absolute = true
	case "--resolve-to-context": options.resolve_to_context = true
	case "--explicit-conditions": options.explicit_conditions = true
	case "--tsconfig-references": options.typescript_references = true
	case "--no-main-fields":
		clear(&lists.main_fields)
		options.main_fields = lists.main_fields[:]
	case "--no-extensions":
		clear(&lists.extensions)
		options.extensions = lists.extensions[:]
	case "--no-main-files":
		clear(&lists.main_files)
		options.main_files = lists.main_files[:]
	case "--no-module-dirs":
		clear(&lists.modules)
		options.modules = lists.modules[:]
	case: return false
	}
	return true
}

@(private="file")
cli_resolve_takes_value :: proc(flag: string) -> bool {
	switch flag {
	case "--from", "--tsconfig", "--condition", "--main-field", "--extension", "--main-file",
	     "--module-dir", "--alias", "--extension-alias", "--exports-fields", "--imports-fields",
	     "--root", "--fallback", "--fallback-ignore", "--restriction", "--restriction-regex":
		return true
	}
	return false
}

@(private="file")
cli_resolve_value :: proc(
	flag, value: string,
	options: ^ModuleResolveOptions,
	lists: ^CliResolveLists,
) -> bool {
	assert(cli_resolve_takes_value(flag))
	switch flag {
	case "--from": lists.importer = value
	case "--tsconfig": options.typescript_config = value
	case "--condition": append(&lists.conditions, value)
	case "--root": append(&lists.roots, value)
	case "--restriction": append(&lists.restrictions, ModuleResolveRestriction{path = value})
	case "--restriction-regex": append(&lists.restrictions, ModuleResolveRestriction{regex = value})
	case "--exports-fields", "--imports-fields":
		fields, ok := cli_resolve_manifest_fields(value)
		if !ok {
			fmt.eprintf("Error: %s requires a JSON array of keys or key paths\n", flag)
			return false
		}
		if flag == "--exports-fields" { options.exports_fields = fields }
		else { options.imports_fields = fields }
	case "--main-field":
		append(&lists.main_fields, value)
		options.main_fields = lists.main_fields[:]
	case "--module-dir":
		append(&lists.modules, value)
		options.modules = lists.modules[:]
	case "--extension":
		append(&lists.extensions, value)
		options.extensions = lists.extensions[:]
	case "--main-file":
		append(&lists.main_files, value)
		options.main_files = lists.main_files[:]
	case "--extension-alias":
		key, values, valid := cli_resolve_extension_alias(value)
		if !valid { return false }
		lists.extension_alias[key] = values
	case "--alias":
		alias, ok := cli_resolve_alias(value)
		if !ok { return false }
		append(&lists.aliases, alias)
	case "--fallback":
		alias, ok := cli_resolve_alias(value, "--fallback")
		if !ok { return false }
		append(&lists.fallback, ModuleResolveFallback{name = alias.name, target = alias.target, exact = alias.exact})
	case "--fallback-ignore":
		name := strings.trim_suffix(value, "$")
		append(&lists.fallback, ModuleResolveFallback{name = name, exact = name != value, ignore = true})
	}
	return true
}

@(private="file")
cli_resolve_manifest_fields :: proc(raw: string) -> ([][]string, bool) {
	items, ok := module_manifest_parse(raw, context.temp_allocator).(^ModuleManifestArray)
	if !ok { return nil, false }
	fields := make([][]string, len(items.elements), context.temp_allocator)
	for item, i in items.elements {
		#partial switch entry in item {
		case string:
			fields[i] = make([]string, 1, context.temp_allocator)
			fields[i][0] = entry
		case ^ModuleManifestArray:
			fields[i] = make([]string, len(entry.elements), context.temp_allocator)
			for part, j in entry.elements {
				key, valid := part.(string)
				if !valid { return nil, false }
				fields[i][j] = key
			}
		case: return nil, false
		}
	}
	return fields, true
}

@(private="file")
cli_resolve_alias :: proc(value: string, flag := "--alias") -> (ModuleResolveAlias, bool) {
	equals := strings.index_byte(value, '=')
	if equals < 1 || equals == len(value) - 1 {
		fmt.eprintf("Error: %s requires <name=target>\n", flag)
		return {}, false
	}
	pattern := value[:equals]
	name := strings.trim_suffix(pattern, "$")
	if name == "" {
		fmt.eprintf("Error: %s requires a non-empty name\n", flag)
		return {}, false
	}
	return {name, value[equals + 1:], name != pattern}, true
}

@(private="file")
cli_resolve_write :: proc(result: ModuleResolution) -> int {
	kind: string
	switch result.kind {
	case .File: kind = "file"
	case .Builtin: kind = "builtin"
	case .Ignored: kind = "ignored"
	}
	message := struct { kind, path: string }{kind, result.path}
	encoded, json_err := json.marshal(message)
	if json_err != nil {
		fmt.eprintln("Error: could not encode module resolution")
		return 1
	}
	out_println(string(encoded))
	return 0
}

@(private="file")
cli_resolve_extension_alias :: proc(value: string) -> (string, []string, bool) {
	separator := strings.index_byte(value, '=')
	if separator == 0 || value == "" {
		fmt.eprintln("Error: --extension-alias requires a source suffix")
		return "", nil, false
	}
	if separator < 0 { return value, nil, true }
	targets, err := strings.split(value[separator+1:], ",", context.temp_allocator)
	if err != nil {
		fmt.eprintln("Error: could not allocate extension aliases")
		return "", nil, false
	}
	return value[:separator], targets, true
}
