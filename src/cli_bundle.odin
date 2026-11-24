package kessel

// `kessel bundle` command line.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

CLI_BUNDLE_USAGE :: "Usage: kessel bundle <entry> [--outfile <file> | --outdir <directory>] [--format esm|cjs|iife] [--platform node|browser] [--external <name>] [--minify] [--sourcemap] [--global-name <name>] [--condition <name>] [--main-field <name>] [--tsconfig <file>] [--jsx=classic|automatic] [--jsx-factory <name>] [--jsx-fragment <name>] [--jsx-import-source=<name>] [--no-tree-shaking]"

@(private="file")
CLIBundleArguments :: struct {
	options: BundleOptions,
	outfile, outdir: string,
	externals, conditions, main_fields: [dynamic]string,
}

@(private)
cli_bundle :: proc(args: []string) -> int {
	if len(args) == 0 {
		fmt.eprintln(CLI_BUNDLE_USAGE)
		return 2
	}
	if args[0] == "--help" || args[0] == "-h" {
		out_println(CLI_BUNDLE_USAGE)
		return 0
	}
	arguments := CLIBundleArguments{options = {tree_shaking = true}}
	if !cli_bundle_arguments(args, &arguments) { return 2 }
	options := arguments.options
	options.externals = arguments.externals[:]
	options.conditions = arguments.conditions[:]
	options.main_fields = arguments.main_fields[:]

	graph: BundleGraph
	output, ok := bundle_run(&graph, options)
	defer bundle_destroy(&graph)
	for diagnostic in graph.diagnostics { cli_bundle_report(diagnostic) }
	if !ok { return 1 }
	return cli_bundle_write(arguments, output)
}

@(private="file")
cli_bundle_arguments :: proc(args: []string, arguments: ^CLIBundleArguments) -> bool {
	options := &arguments.options
	for i := 0; i < len(args); i += 1 {
		flag := args[i]
		value := ""
		// Both `--flag value` and `--flag=value` are accepted.
		if equals := strings.index_byte(flag, '='); equals > 0 && strings.has_prefix(flag, "--") {
			value = flag[equals + 1:]
			flag = flag[:equals]
		}
		switch flag {
		case "--minify":          options.minify = true
		case "--sourcemap":       options.source_map = true
		case "--no-tree-shaking": options.tree_shaking = false
		case "--outfile", "--outdir", "--format", "--platform", "--external", "--global-name",
		     "--condition", "--main-field", "--tsconfig", "--jsx", "--jsx-import-source",
		     "--jsx-factory", "--jsx-fragment":
			if value == "" {
				i += 1
				if i == len(args) {
					fmt.eprintf("Error: %s requires a value\n", flag)
					return false
				}
				value = args[i]
			}
			if !cli_bundle_value(arguments, flag, value) { return false }
		case:
			if strings.has_prefix(flag, "-") {
				fmt.eprintf("Error: unknown bundle option '%s'\n", args[i])
				return false
			}
			if options.entry != "" {
				fmt.eprintln("Error: bundle accepts exactly one entry file")
				return false
			}
			options.entry = args[i]
		}
	}
	if options.entry == "" {
		fmt.eprintln("Error: bundle requires an entry file")
		return false
	}
	if arguments.outfile != "" && arguments.outdir != "" {
		fmt.eprintln("Error: --outfile and --outdir cannot be combined")
		return false
	}
	if options.global_name != "" && options.format != .IIFE {
		fmt.eprintln("Error: --global-name requires --format iife")
		return false
	}
	return true
}

@(private="file")
cli_bundle_value :: proc(arguments: ^CLIBundleArguments, flag, value: string) -> bool {
	options := &arguments.options
	switch flag {
	case "--outfile":     arguments.outfile = value
	case "--outdir":      arguments.outdir = value
	case "--external":    append(&arguments.externals, value)
	case "--condition":   append(&arguments.conditions, value)
	case "--main-field":  append(&arguments.main_fields, value)
	case "--tsconfig":    options.tsconfig = value
	case "--jsx-import-source": options.jsx_import_source = value
	case "--jsx-factory", "--jsx-fragment":
		if !jsx_pragma_valid(value) {
			fmt.eprintf("Error: %s requires a binding such as h or React.createElement\n", flag)
			return false
		}
		if flag == "--jsx-factory" { options.jsx_factory = value } else { options.jsx_fragment = value }
	case "--global-name":
		if !bundle_is_identifier(value) {
			fmt.eprintln("Error: --global-name requires an identifier")
			return false
		}
		options.global_name = value
	case "--jsx":
		if value != "classic" && value != "automatic" {
			fmt.eprintln("Error: --jsx requires classic or automatic")
			return false
		}
		options.jsx = value
	case "--format":
		switch value {
		case "esm":  options.format = .ESM
		case "cjs":  options.format = .CJS
		case "iife": options.format = .IIFE
		case:
			fmt.eprintln("Error: --format requires esm, cjs, or iife")
			return false
		}
	case "--platform":
		switch value {
		case "node":    options.platform = .Node
		case "browser": options.platform = .Browser
		case:
			fmt.eprintln("Error: --platform requires node or browser")
			return false
		}
	}
	return true
}

@(private="file")
cli_bundle_report :: proc(diagnostic: BundleDiagnostic) {
	label := "error" if diagnostic.severity == .Error else "warning"
	switch {
	case diagnostic.path == "": fmt.eprintf("%s: %s\n", label, diagnostic.message)
	case diagnostic.line == 0:  fmt.eprintf("%s: %s: %s\n", diagnostic.path, label, diagnostic.message)
	case:
		fmt.eprintf("%s:%d:%d: %s: %s\n", diagnostic.path, diagnostic.line, diagnostic.column, label, diagnostic.message)
	}
}

@(private="file")
cli_bundle_write :: proc(arguments: CLIBundleArguments, output: BundleOutput) -> int {
	outfile := arguments.outfile
	if arguments.outdir != "" {
		base := filepath.stem(filepath.base(arguments.options.entry))
		extension := ".cjs" if arguments.options.format == .CJS else ".js"
		if arguments.options.format == .ESM { extension = ".mjs" }
		outfile = strings.concatenate({arguments.outdir, "/", base, extension}, context.temp_allocator)
	}
	if outfile == "" {
		// Without a destination there is nowhere to put a separate map file.
		if output.map_json != "" { fmt.eprintln("warning: --sourcemap needs --outfile or --outdir; no map was written") }
		out_printf("%s", output.code)
		return 0
	}
	if directory := filepath.dir(outfile); directory != "" && directory != "." && !os.is_dir(directory) {
		if err := os.make_directory_all(directory); err != nil {
			fmt.eprintf("Error: cannot create directory for '%s'\n", outfile)
			return 1
		}
	}
	code := output.code
	if output.map_json != "" {
		map_file := strings.concatenate({outfile, ".map"}, context.temp_allocator)
		if err := os.write_entire_file(map_file, transmute([]byte)output.map_json); err != nil {
			fmt.eprintf("Error: cannot write '%s'\n", map_file)
			return 1
		}
		code = strings.concatenate({code, "//# sourceMappingURL=", filepath.base(map_file), "\n"}, context.temp_allocator)
	}
	if err := os.write_entire_file(outfile, transmute([]byte)code); err != nil {
		fmt.eprintf("Error: cannot write '%s'\n", outfile)
		return 1
	}
	return 0
}
