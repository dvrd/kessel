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
cli_resolve_options :: proc(args: []string, options: ^ModuleResolveOptions) -> string {
	importer: string
	conditions, main_fields, extensions, main_files, modules: [dynamic]string
	aliases: [dynamic]ModuleResolveAlias
	roots: [dynamic]string
	fallback: [dynamic]ModuleResolveFallback
	restrictions: [dynamic]ModuleResolveRestriction
	extension_alias := make(map[string][]string, context.temp_allocator)
	for i := 0; i < len(args); i += 1 {
		flag := args[i]
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
			clear(&main_fields)
			options.main_fields = main_fields[:]
		case "--no-extensions":
			clear(&extensions)
			options.extensions = extensions[:]
		case "--no-main-files":
			clear(&main_files)
			options.main_files = main_files[:]
		case "--no-module-dirs":
			clear(&modules)
			options.modules = modules[:]
		case "--from", "--tsconfig", "--condition", "--main-field", "--extension", "--main-file", "--module-dir", "--alias", "--extension-alias", "--exports-fields", "--imports-fields",
		     "--root", "--fallback", "--fallback-ignore", "--restriction", "--restriction-regex":
			i += 1
			allows_empty := flag == "--extension" || flag == "--module-dir" || flag == "--main-field"
			if i == len(args) || (args[i] == "" && !allows_empty) {
				fmt.eprintf("Error: %s requires a value\n", flag)
				return ""
			}
			switch flag {
			case "--from": importer = args[i]
			case "--tsconfig": options.typescript_config = args[i]
			case "--condition": append(&conditions, args[i])
			case "--exports-fields", "--imports-fields":
				fields, ok := cli_resolve_manifest_fields(args[i])
				if !ok {
					fmt.eprintf("Error: %s requires a JSON array of keys or key paths\n", flag)
					return ""
				}
				if flag == "--exports-fields" { options.exports_fields = fields }
				else { options.imports_fields = fields }
			case "--main-field":
				append(&main_fields, args[i])
				options.main_fields = main_fields[:]
			case "--module-dir":
				append(&modules, args[i])
				options.modules = modules[:]
			case "--extension":
				append(&extensions, args[i])
				options.extensions = extensions[:]
			case "--extension-alias":
				key, values, valid := cli_resolve_extension_alias(args[i])
				if !valid { return "" }
				extension_alias[key] = values
			case "--main-file":
				append(&main_files, args[i])
				options.main_files = main_files[:]
			case "--alias":
				alias, ok := cli_resolve_alias(args[i])
				if !ok { return "" }
				append(&aliases, alias)
			case "--root": append(&roots, args[i])
			case "--fallback":
				alias, ok := cli_resolve_alias(args[i], "--fallback")
				if !ok { return "" }
				append(&fallback, ModuleResolveFallback{name = alias.name, target = alias.target, exact = alias.exact})
			case "--fallback-ignore":
				name := strings.trim_suffix(args[i], "$")
				append(&fallback, ModuleResolveFallback{name = name, exact = name != args[i], ignore = true})
			case "--restriction": append(&restrictions, ModuleResolveRestriction{path = args[i]})
			case "--restriction-regex": append(&restrictions, ModuleResolveRestriction{regex = args[i]})
			}
		case:
			fmt.eprintf("Error: unknown resolve option '%s'\n", flag)
			return ""
		}
	}
	if importer == "" {
		fmt.eprintln("Error: resolve requires --from <file>")
		return ""
	}
	options.conditions = conditions[:]
	options.aliases = aliases[:]
	options.roots = roots[:]
	options.fallback = fallback[:]
	options.restrictions = restrictions[:]
	options.extension_alias = extension_alias
	return importer
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
