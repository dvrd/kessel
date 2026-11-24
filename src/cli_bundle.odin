package kessel

// `kessel bundle` command line.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

CLI_BUNDLE_USAGE :: `Usage: kessel bundle <entry> [options]
  --outfile <file> | --outdir <directory>   where to write (default: stdout)
  --format esm|cjs|iife                     output format (default: esm)
  --platform node|browser                   resolution and builtins (default: node)
  --external <name>                         leave a module unbundled; repeatable, trailing * allowed
  --minify                                  minify the bundle
  --sourcemap                               write <outfile>.map
  --global-name <name>                      iife: assign the entry's exports to this global
  --condition <name>                        extra package.json exports condition; repeatable
  --main-field <name>                       package.json entry fields in order; repeatable
  --tsconfig <file>                         resolve tsconfig paths
  --jsx=classic|automatic                   JSX runtime (default: classic)
  --jsx-factory <name> --jsx-fragment <name> --jsx-import-source=<name> --jsx-development
  --define NAME=EXPRESSION                  replace a global or member name; repeatable
  --target es2015..es2024                   lower newer syntax in the inputs
  --decorators legacy [--emit-decorator-metadata]   lower TypeScript experimental decorators
  --no-tree-shaking                         keep unused statements and modules`

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
	if outfile := cli_bundle_outfile(arguments); outfile != "" {
		// The output file may not exist yet, so build its path lexically.
		directory := filepath.dir(outfile)
		if !filepath.is_abs(directory) {
			if cwd, err := os.get_working_directory(context.temp_allocator); err == nil {
				directory = strings.concatenate({cwd, "/", directory}, context.temp_allocator)
			}
		}
		if cleaned, err := filepath.clean(directory, context.temp_allocator); err == nil {
			options.map_directory = cleaned
		}
	}

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
		case "--jsx-development": options.jsx_development = true
		case "--emit-decorator-metadata": options.emit_decorator_metadata = true
		case "--outfile", "--outdir", "--format", "--platform", "--external", "--global-name",
		     "--condition", "--main-field", "--tsconfig", "--jsx", "--jsx-import-source",
		     "--jsx-factory", "--jsx-fragment", "--define", "--target", "--decorators":
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
	case "--define":
		// Split at the first '=': the expression may contain more of them.
		separator := strings.index_byte(value, '=')
		if separator <= 0 || separator + 1 == len(value) {
			fmt.eprintln("Error: --define requires NAME=EXPRESSION")
			return false
		}
		if options.define == nil { options.define = make(map[string]string) }
		options.define[value[:separator]] = value[separator + 1:]
	case "--target":
		if _, known := transform_target_parse(value); !known {
			fmt.eprintln("Error: --target requires es2015 to es2024, or esnext")
			return false
		}
		options.target = value
	case "--decorators":
		if value != "legacy" {
			fmt.eprintln("Error: --decorators requires legacy")
			return false
		}
		options.decorators = value
	case "--jsx-factory", "--jsx-fragment":
		if !jsx_pragma_valid(value) {
			fmt.eprintf("Error: %s requires a binding such as h or React.createElement\n", flag)
			return false
		}
		if flag == "--jsx-factory" {
			options.jsx_factory = value
		} else {
			options.jsx_fragment = value
		}
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
	case diagnostic.line == 0:
		fmt.eprintf("%s: %s: %s\n", diagnostic.path, label, diagnostic.message)
	case:
		fmt.eprintf("%s:%d:%d: %s: %s\n", diagnostic.path, diagnostic.line, diagnostic.column,
			label, diagnostic.message)
	}
}

// --outdir names the file after the entry, with the extension Node needs to
// load the chosen format.
@(private="file")
cli_bundle_outfile :: proc(arguments: CLIBundleArguments) -> string {
	if arguments.outdir == "" { return arguments.outfile }
	base := filepath.stem(filepath.base(arguments.options.entry))
	extension := ".js"
	switch arguments.options.format {
	case .ESM:  extension = ".mjs"
	case .CJS:  extension = ".cjs"
	case .IIFE: extension = ".js"
	}
	return strings.concatenate({arguments.outdir, "/", base, extension}, context.temp_allocator)
}

@(private="file")
cli_bundle_write :: proc(arguments: CLIBundleArguments, output: BundleOutput) -> int {
	outfile := cli_bundle_outfile(arguments)
	if outfile == "" {
		// Without a destination there is nowhere to put a separate map file.
		if output.map_json != "" {
			fmt.eprintln("warning: --sourcemap needs --outfile or --outdir; no map was written")
		}
		out_printf("%s", output.code)
		return 0
	}
	directory := filepath.dir(outfile)
	if directory != "" && directory != "." && !os.is_dir(directory) {
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
		code = strings.concatenate({code, "//# sourceMappingURL=", filepath.base(map_file), "\n"},
			context.temp_allocator)
	}
	if err := os.write_entire_file(outfile, transmute([]byte)code); err != nil {
		fmt.eprintf("Error: cannot write '%s'\n", outfile)
		return 1
	}
	return 0
}
