package kessel

import "base:runtime"
import "core:fmt"
import mvirtual "core:mem/virtual"

CLILintOptions :: struct {
	cli: CliConfig,
	overrides: []LintOverride,
	config_path, format: string,
	quiet, nested_config: bool,
	max_warnings: int,
	fix_kinds: LintFixKinds,
}

CLITransformOptions :: struct {
	cli: CliConfig,
	options: TransformOptions,
	command: string,
}

CLIFileCommand :: union {CLILintOptions, FormatOptions, CLITransformOptions}

cli_run_files :: proc(files: []string, command: CLIFileCommand, continuous: bool) -> int {
	if !continuous { return cli_run_files_once(files, command, nil) }
	if len(files) == 0 { fmt.eprintln("Error: --watch requires an input file"); return 2 }
	// Each pass discovers its dependencies afresh. Removed extends entries
	// and config paths are released before the next pass starts.
	for {
		watch := FileWatch{paths = make(map[string]FileWatchStamp), allocator = context.allocator}
		for file in files { file_watch_add(&watch, file) }
		status := cli_run_files_once(files, command, &watch)
		flush_stdout_writer()
		if lint, ok := command.(CLILintOptions); !ok || lint.format == "default" {
			fmt.eprintf("watch: run finished (exit %d), waiting for changes\n", status)
		}
		file_watch_wait(&watch)
		for path in watch.paths { delete(path, watch.allocator) }
		delete(watch.paths)
	}
}

@(private="file")
cli_run_files_once :: proc(files: []string, command: CLIFileCommand, watch: ^FileWatch) -> int {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	scratch: mvirtual.Arena
	if watch != nil {
		if err := mvirtual.arena_init_growing(&scratch); err != nil {
			fmt.eprintln("Error: could not allocate memory for the watch run")
			return 2
		}
		context.allocator = mvirtual.arena_allocator(&scratch)
	}
	defer if watch != nil { mvirtual.arena_destroy(&scratch) }
	switch options in command {
	case CLILintOptions: return cli_lint_files(files, options, watch)
	case FormatOptions:
		assert(len(files) == 1)
		return format_file(files[0], options)
	case CLITransformOptions:
		assert(len(files) == 1)
		return transform_file(files[0], options.cli, options.options, options.command)
	}
	return 2
}

@(private="file")
cli_lint_files :: proc(files: []string, options: CLILintOptions, watch: ^FileWatch) -> int {
	had_errors := false
	configs: LintConfigStore
	if !lint_config_store_init(&configs, options.config_path, options.nested_config, watch) { return 2 }
	lint_warn_count := 0
	eff_buf := make([dynamic]LintOverride)
	defer delete(eff_buf)
	json_report: [dynamic]u8
	defer delete(json_report)
	if options.format == "json" {
		json_report = make([dynamic]u8, 0, 1024)
		append(&json_report, '[')
	}
	fix_kinds := options.fix_kinds
	if fix_kinds == {.Dangerous} { fix_kinds += {.Fix} }
	for file in files {
		settings, ignored, ok := lint_config_select(&configs, file, options.overrides, &eff_buf)
		if !ok { return 2 }
		if ignored { continue }
		if fix_kinds != {} {
			if err := lint_fix_file(file, parse_config_from_cli(options.cli), settings, fix_kinds); err != nil {
				fmt.eprintf("Error: could not fix %s (%v)\n", file, err)
				return 2
			}
			// Read the post-fix revision next. Our own atomic write needs no second pass.
			if watch != nil { watch.paths[file] = file_watch_stamp(file) }
		}
		diagnostics, read_ok := lint_file(file, options.cli, settings, options.format, options.quiet, &lint_warn_count, &json_report)
		if !read_ok && watch == nil { return 1 }
		if diagnostics || !read_ok { had_errors = true }
	}
	if options.format == "json" {
		append(&json_report, ']')
		fmt.eprintln(string(json_report[:]))
	}
	// Warning-failure policy (kessel is stricter than ESLint by default):
	//   --max-warnings N : fail iff the warning total exceeds N.
	//   --quiet          : warnings neither print nor fail; only errors fail.
	//   (neither)        : any warning fails the run, like any other diagnostic.
	if options.max_warnings >= 0 {
		if lint_warn_count > options.max_warnings {
			if options.format != "json" {
				fmt.eprintf("Error: too many warnings (%d, max allowed %d)\n", lint_warn_count, options.max_warnings)
			}
			had_errors = true
		}
	} else if !options.quiet && lint_warn_count > 0 {
		had_errors = true
	}
	return 1 if had_errors else 0
}
