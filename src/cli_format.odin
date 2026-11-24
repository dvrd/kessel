package kessel

import "core:fmt"
import "core:strconv"
import "core:strings"

CLI_FORMAT_USAGE :: "Usage: kessel fmt <file> [--watch] [--print-width N] [--tab-width N] [--use-tabs] [--single-quote] [--no-bracket-spacing] [--trailing-comma all|es5|none] [--end-of-line lf|crlf|cr|auto]"

@(private)
cli_format_file :: proc(args: []string) -> int {
	if len(args) == 1 && (args[0] == "--help" || args[0] == "-h") {
		out_println(CLI_FORMAT_USAGE)
		return 0
	}
	options := format_options_default()
	watch := false
	path: string
	for i := 0; i < len(args); i += 1 {
		flag := args[i]
		switch flag {
		case "--watch": watch = true
		case "--use-tabs": options.use_tabs = true
		case "--single-quote": options.single_quote = true
		case "--no-bracket-spacing": options.bracket_spacing = false
		case "--print-width", "--tab-width", "--trailing-comma", "--end-of-line":
			i += 1
			if i == len(args) { fmt.eprintln(CLI_FORMAT_USAGE); return 2 }
			if flag == "--end-of-line" { options.end_of_line = args[i]; continue }
			if flag == "--trailing-comma" {
				switch args[i] {
				case "all": options.trailing_comma, options.trailing_comma_es5 = true, false
				case "es5": options.trailing_comma, options.trailing_comma_es5 = true, true
				case "none": options.trailing_comma, options.trailing_comma_es5 = false, false
				case: fmt.eprintln(CLI_FORMAT_USAGE); return 2
				}
			} else {
				number, valid := strconv.parse_int(args[i], 10)
				if !valid || number < 0 || number > int(max(i32)) { fmt.eprintln(CLI_FORMAT_USAGE); return 2 }
				if flag == "--print-width" { options.print_width = i32(number) }
				else { options.tab_width = i32(number) }
			}
		case:
			if path != "" || strings.has_prefix(flag, "-") { fmt.eprintln(CLI_FORMAT_USAGE); return 2 }
			path = flag
		}
	}
	if path == "" || !format_options_valid(options) { fmt.eprintln(CLI_FORMAT_USAGE); return 2 }
	return cli_run_files({path}, options, watch)
}

format_file :: proc(path: string, options: FormatOptions) -> int {
	job: ParseJob
	if !parse_job_open(&job, path, {}) {
		fmt.eprintf("error: could not read file: %s\n", path)
		return 1
	}
	defer parse_job_close(&job)
	parse_job_run(&job)
	if len(job.parser.errors) != 0 {
		build_line_table(&job.lexer)
		render_pretty_diagnostics(job.lexer.source, path, job.lexer.line_offsets[:job.lexer.num_lines], job.parser.errors[:], false)
		return 1
	}
	out_print(format_program(&job, options))
	return 0
}
