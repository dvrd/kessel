package main

import "core:bufio"
import "core:fmt"
import "core:io"
import "core:math"
import "core:mem"
import mvirtual "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "core:strconv"
import "core:thread"


// ============================================================================
// Main Entry Point
// ============================================================================

stdout_writer_initialized := false
stdout_writer: bufio.Writer
stdout_writer_buf: [1 * 1024 * 1024]byte // 1MB for JSON streaming
stdout_stream: io.Writer

// AstType drives the --ast-type CLI flag and lives on CliConfig (see
// src/cli_config.odin). Defined here as a tiny enum so cli_config.odin
// doesn't have to forward-declare it.
//   .Auto - emitter resolves ts_shape from parse Lang ({TS, TSX} -> true)
//   .JS   - force EmitConfig.ts_shape = false
//   .TS   - force EmitConfig.ts_shape = true
AstType :: enum { Auto, JS, TS }

// HashbangInfo carries ES2023 hashbang metadata from the lexer to the emitter.
HashbangInfo :: struct {
	value: string,
	start: u32,
	end:   u32,
}

init_stdout_writer :: proc() {
	if stdout_writer_initialized {
		return
	}
	bufio.writer_init_with_buf(&stdout_writer, os.to_stream(os.stdout), stdout_writer_buf[:])
	stdout_stream = bufio.writer_to_writer(&stdout_writer)
	stdout_writer_initialized = true
}

flush_stdout_writer :: proc() {
	if !stdout_writer_initialized {
		return
	}
	bufio.writer_flush(&stdout_writer)
	os.flush(os.stdout)
}

// direct_reserve ensures direct_buf has at least `need` unused bytes starting
// at direct_pos. Grows by doubling (at minimum to fit `direct_pos + need`)
// when the current allocation would overflow. Kessel's JSON output was sized
// at 20× source; class-heavy files can exceed that once ClassBody elements
// emit in full, so every direct-mode write path routes through this check.
//
// The grow path is O(n) but doubling amortises to O(1) per byte written.
// Callers MUST reserve BEFORE indexing direct_buf so indexed writes never
// touch freed memory (the old backing slice is released after copy).

// CLI-side stdout helpers. Used by banner / help / lex JSON output /
// server framing / parse stats / error messages. They always write to
// the stdout bufio writer; the AST emitter uses its own emit_* helpers
// (src/emitter.odin) that write to e.buf.
//
// Pre-#6 out_println had a `compact_json` branch that stripped the
// trailing newline. That branch was dead in practice — the AST emitter
// no longer routes through these helpers (since #2), and no test or
// downstream consumer relies on compact lex/banner output. Dropping
// it removes the last reader of the compact_json global from the
// stdout helpers.

out_print :: proc(args: ..any) -> int {
	init_stdout_writer()
	return fmt.wprint(stdout_stream, ..args, flush=false)
}

out_println :: proc(args: ..any) -> int {
	init_stdout_writer()
	return fmt.wprintln(stdout_stream, ..args, flush=false)
}

out_printf :: proc(format: string, args: ..any) -> int {
	init_stdout_writer()
	return fmt.wprintf(stdout_stream, format, ..args, flush=false)
}

main :: proc() {
	// Apple Silicon scheduler biases threads to P-cores or E-cores by
	// QoS class. CLI tools default to QOS_CLASS_DEFAULT, which can land
	// on E-cores under load. Pin to USER_INTERACTIVE (the foreground-UI
	// tier) so the parser stays on P-cores. No-op on non-Darwin.
	//
	// Set BEFORE any benchmark timing or production parsing so the
	// scheduler hint applies to all subsequent work in this process.
	pin_to_p_core()

	if len(os.args) < 2 {
		print_usage()
		flush_stdout_writer()
		os.exit(1)
	}

	command := os.args[1]

	switch command {
	case "parse":
		if len(os.args) < 3 {
			out_println("Error: parse command requires at least one file")
			out_println("Usage: kessel parse <file> [--compact]")
			out_println("       kessel parse <files...> [--workers N]")
			flush_stdout_writer()
			os.exit(1)
		}
		cli := cli_config_default()
		parse_files := make([dynamic]string)
		parse_workers := 0
		parse_out_dir := ""
		parse_raw := false
		i := 2
		for i < len(os.args) {
			// Try CliConfig flags first; cli_try_parse_flag advances i.
			if cli_try_parse_flag(&cli, os.args, &i) { continue }
			// Parse-subcommand-specific flags
			arg := os.args[i]
			switch {
			case arg == "--raw":
				parse_raw = true
				i += 1
			case arg == "--workers" && i + 1 < len(os.args):
				n, _ := strconv.parse_int(os.args[i+1])
				parse_workers = n
				i += 2
			case arg == "--out-dir" && i + 1 < len(os.args):
				parse_out_dir = os.args[i+1]
				i += 2
			case:
				append(&parse_files, arg)
				i += 1
			}
		}
		if len(parse_files) == 1 {
			if parse_raw {
				if parse_out_dir != "" {
					base := filepath_base(parse_files[0])
					out_path := strings.concatenate({parse_out_dir, "/", base, ".bin"})
					parse_file_raw_to_disk(parse_files[0], out_path, cli)
				} else {
					raw_transfer_file(parse_files[0], "", cli)
				}
			} else {
				parse_file(parse_files[0], cli)
			}
		} else if len(parse_files) > 1 {
			if parse_workers == 0 {
				parse_workers = os.get_processor_core_count()
				if parse_workers < 1 { parse_workers = 1 }
			}
			if parse_out_dir == "" { parse_out_dir = parse_raw ? "tmp/raw" : "tmp/ast" }
			parse_many(parse_files[:], parse_workers, parse_out_dir, parse_raw, cli)
		}
		delete(parse_files)

	case "raw":
		// Produce raw transfer buffer - for testing/benchmarking the zero-copy path
		if len(os.args) < 3 {
			out_println("Usage: kessel raw <file> [--out file.bin] [--lang=js|jsx|ts|tsx]")
			flush_stdout_writer()
			os.exit(1)
		}
		cli := cli_config_default()
		raw_file := os.args[2]
		raw_out := ""
		i := 3
		for i < len(os.args) {
			if cli_try_parse_flag(&cli, os.args, &i) { continue }
			arg := os.args[i]
			if arg == "--out" && i + 1 < len(os.args) {
				raw_out = os.args[i+1]
				i += 2
			} else {
				fmt.eprintf("Error: unrecognised flag '%s' for `kessel raw`\n", arg)
				os.exit(2)
			}
		}
		raw_transfer_file(raw_file, raw_out, cli)

	case "lex", "tokenize":
		if len(os.args) < 3 {
			out_println("Error: lex command requires a file path")
			out_println("Usage: kessel lex <js-file>")
			flush_stdout_writer()
			os.exit(1)
		}
		file_path := os.args[2]
		lex_file(file_path)

	case "microbench":
		if len(os.args) < 4 {
			out_println("Usage: kessel microbench parse <file> [--iterations N] [--ast-only]")
			out_println("       kessel microbench lex <file> [--iterations N]")
			flush_stdout_writer()
			os.exit(1)
		}
		cli := cli_config_default()
		mb_sub := os.args[2]
		mb_file := os.args[3]
		mb_iters := 100
		mb_ast_only := false
		// Scan optional flags after the file path. Order-independent.
		// CliConfig flags pass through cli_try_parse_flag; bench-specific
		// flags (--iterations, --ast-only) are handled inline.
		i := 4
		for i < len(os.args) {
			if cli_try_parse_flag(&cli, os.args, &i) { continue }
			arg := os.args[i]
			if arg == "--iterations" && i + 1 < len(os.args) {
				if n, ok := strconv.parse_int(os.args[i+1]); ok { mb_iters = n }
				i += 2
			} else if arg == "--ast-only" {
				// Apples-to-apples comparison vs OXC's parser-only bench:
				// disables verify_scopes / verify_export_locals / duplicate-
				// param / strict-param / catch-clause-clash / param-vs-body
				// checks. OXC defers all of these to oxc_semantic; the
				// bench harness for OXC never invokes the semantic pass.
				mb_ast_only = true
				i += 1
			} else {
				i += 1
			}
		}
		switch mb_sub {
		case "parse":
			microbench_file(mb_file, mb_iters, mb_ast_only, cli)
		case "lex":
			microbench_lex(mb_file, mb_iters)
		case:
			out_printf("Unknown microbench subcommand: %s\n", mb_sub)
			out_println("Subcommands: parse, lex")
			flush_stdout_writer()
			os.exit(1)
		}

	case "profile":
		if len(os.args) < 4 {
			out_println("Usage: kessel profile parse <file> [--iterations N]")
			out_println("       kessel profile lex <file> [--iterations N]")
			flush_stdout_writer()
			os.exit(1)
		}
		pr_sub := os.args[2]
		pr_file := os.args[3]
		pr_iters := 100
		if len(os.args) >= 6 && os.args[4] == "--iterations" {
			n, ok := strconv.parse_int(os.args[5])
			if ok { pr_iters = n }
		}
		switch pr_sub {
		case "parse":
			profile_parser_file(pr_file, pr_iters)
		case "lex":
			profile_lex_file(pr_file, pr_iters)
		case:
			out_printf("Unknown profile subcommand: %s\n", pr_sub)
			out_println("Subcommands: parse, lex")
			flush_stdout_writer()
			os.exit(1)
		}

	case "server":
		// Server mode parses CLI flags ONCE at startup and applies the
		// resulting CliConfig to every subsequent file in the request
		// stream. Pre-#6 the server case had no flag parser despite the
		// doc-comment claiming flags are sticky - `kessel server
		// --compact` silently ignored every flag. Fixed for free here.
		cli := cli_config_default()
		i := 2
		for i < len(os.args) {
			if cli_try_parse_flag(&cli, os.args, &i) { continue }
			fmt.eprintf("Error: unrecognised flag '%s' for `kessel server`\n", os.args[i])
			os.exit(2)
		}
		run_server_mode(cli)

	case "help", "-h", "--help":
		print_usage()


	case "version", "-v", "--version":
		out_println("kessel version 0.1.0")

	case:
		out_printf("Unknown command: %s\n", command)
		print_usage()
		flush_stdout_writer()
		os.exit(1)
	}
	flush_stdout_writer()
}

print_usage :: proc() {
	out_println("Kessel - Fast JavaScript Parser")
	out_println("")
	out_println("Usage: kessel <command> [options]")
	out_println("")
	out_println("Commands:")
	out_println("  parse <file> [--compact]        Parse and output AST as JSON to stdout")
	out_println("  parse <files...> [--out-dir D] [--workers N]")
	out_println("      Parallel parse, write AST JSON per file (default: tmp/ast/)")
	out_println("  parse <file> --raw [--out-dir D]  Write single-file raw buffer (binary)")
	out_println("  parse <files...> --raw [--out-dir D] [--workers N]")
	out_println("      Parallel parse, write raw binary per file (default: tmp/raw/)")
	out_println("  lex <file>                      Tokenize and output tokens as JSON")
	out_println("  microbench parse <file> [--iterations N]  Parse benchmark (default 100)")
	out_println("  microbench lex <file> [--iterations N]    Lex benchmark (default 100)")
	out_println("  profile parse <file> [--iterations N]     Parser profile with stats (default 100)")
	out_println("  profile lex <file> [--iterations N]       Lexer profile with stats (default 100)")
	out_println("  help                            Show this help message")
	out_println("  version                         Show version")
	out_println("")
	out_println("Examples:")
	out_println("  kessel parse app.js")
	out_println("  kessel parse src/*.js --workers 4")
	out_println("  kessel microbench parse app.js --iterations 5000")
	out_println("  kessel microbench lex app.js --iterations 2000")
}

// ============================================================================
// Parse Command
// ============================================================================

// Server mode — long-lived subprocess that reads file paths from stdin
// and writes AST JSON framed by sentinels to stdout. Eliminates the
// per-call spawn overhead of the CLI shim path without the C-ABI /
// NAPI complexity.
//
// Protocol:
//   Request:  one file path per line (UTF-8, LF-terminated, no JSON).
//             Empty line or EOF closes the server.
//   Response: AST JSON followed by a sentinel line:
//               <json body>\n
//               <kessel-statistics-and-errors>\n
//               @@KESSEL_END\n
//             The client reads until the sentinel, then re-uses the
//             subprocess for the next parse.
//
// CLI flags from the invoking `kessel server ...` command are sticky —
// they apply to every subsequent request. A client that needs to vary
// flags per file can either send a new file path (flags persist) or
// tear down and restart the subprocess.
//
// Invocation example:
//   $ kessel server --compact
//   /tmp/a.js
//   { ...compact AST... }
//   Parse errors: 0
//   @@KESSEL_END
//   /tmp/b.ts
//   ...
SERVER_SENTINEL :: "@@KESSEL_END"

run_server_mode :: proc(cli: CliConfig) {
	buf := make([]byte, 65536, context.allocator)
	defer delete(buf, context.allocator)
	line_buf := make([dynamic]u8, 0, 1024, context.allocator)
	defer delete(line_buf)

	for {
		// Read a newline-delimited path from stdin. Done inline because
		// core:bufio.Reader over os.stdin has some platform quirks on the
		// Odin vendor; os.read returns raw bytes and we do our own split.
		clear(&line_buf)
		at_eof := false
		read_err: os.Error
		for {
			n: int
			n, read_err = os.read(os.stdin, buf[:1])
			if n <= 0 || read_err != nil {
				at_eof = true
				break
			}
			if buf[0] == '\n' { break }
			if buf[0] != '\r' { append(&line_buf, buf[0]) }
		}
		if at_eof && len(line_buf) == 0 { return }
		path := string(line_buf[:])
		if len(path) == 0 { continue }

		parse_file(path, cli)
		out_printf("\n%s\n", SERVER_SENTINEL)
		flush_stdout_writer()
		if at_eof { return }
	}
}

parse_file :: proc(file_path: string, cli: CliConfig) {
	// Open the parse job (ParseJob owns source + arena + lexer + parser;
	// see src/parse_job.odin).
	job: ParseJob
	if !parse_job_open(&job, file_path, parse_config_from_cli(cli)) {
		out_printf("Error: Could not read file: %s\n", file_path)
		flush_stdout_writer()
		os.exit(1)
	}
	defer parse_job_close(&job)
	parse_job_run(&job)
	// Pass 3 (semantic checker) is opt-in via --show-semantic-errors so
	// `kessel parse` matches OXC's parser-only `parseSync` API by default.
	// Today the checker enforces break / continue + label scoping (§13.9.1,
	// §13.9.2, §14.13.1, §14.8.1); more checks migrate from parser.odin in
	// subsequent slices. Errors are appended to job.parser.errors so the
	// existing emitter and `Parse errors: N` diagnostic line don't need to
	// know about pass 3.
	if cli.show_semantic_errors { checker_run_for_job(&job) }

	// Construct a per-call Emitter. Owns its writer buffer, UTF-16 table,
	// and line-offsets borrow. Each parse_file call is single-threaded
	// (workers go through parse_file_to_disk), but the Emitter pattern
	// makes the state explicit so server mode and tests get the same
	// shape without ambient globals. See src/emitter.odin.
	e: Emitter
	emitter_init(&e, emit_config_from_cli(cli, job.lang), len(job.source.data), context.allocator)
	defer emitter_destroy(&e, context.allocator)

	emitter_build_utf16(&e, job.source.data, context.allocator)
	if e.cfg.loc {
		build_line_table(&job.lexer)
		emitter_adopt_lines(&e, job.lexer.line_offsets)
	}

	// Body of the JSON output: "{\n" + Program + [module record] + [errors] + "\n}\n".
	emit_raw(&e, "{\n")
	hb_info: Maybe(HashbangInfo)
	if job.lexer.has_hashbang {
		hb_info = HashbangInfo{value = job.lexer.hashbang_value, start = job.lexer.hashbang_start, end = job.lexer.hashbang_end}
	}
	emit_program(&e, job.program, 1, job.lexer.comments[:], hb_info)

	if e.cfg.module_record {
		emit_module_record(&e, &job.parser, 1)
	}

	emit_errors(&e, &job.parser, 1)

	emit_raw(&e, "\n}\n")

	// Single write to stdout for the JSON body first. Diagnostic lines
	// (parse errors, stats) must follow the JSON on separate lines so
	// downstream consumers can split on the first newline and JSON.parse
	// the line without stripping error preambles.
	//
	// In --compact mode emit_raw strips every `\n` from its input, so the
	// trailing `"\n}\n"` becomes a bare `}` and the parse-error preamble
	// can run into it. Guarantee a terminator unconditionally: if the
	// last emitted byte isn't already `\n`, append one before flushing.
	if e.pos == 0 || e.buf[e.pos-1] != '\n' {
		emit_reserve(&e, 1)
		e.buf[e.pos] = '\n'
		e.pos += 1
	}
	os.write(os.stdout, e.buf[:e.pos])

	// Parse-error diagnostics on stderr. Bypass the emitter (which writes
	// to its buffer, already flushed to stdout above). Print to stdout via
	// fmt.printf so they appear on subsequent lines as intended.
	if len(job.parser.errors) > 0 {
		if job.parser.lexer != nil && job.parser.lexer.num_lines == 0 {
			build_line_table(job.parser.lexer)
		}
		fmt.printf("Parse errors (%d):\n", len(job.parser.errors))
		for err in job.parser.errors {
			line: u32 = 0
			col:  u32 = 0
			if job.parser.lexer != nil {
				line, col = offset_to_line_col(job.parser.lexer.line_offsets, u32(err.loc))
			}
			fmt.printf("  Line %d, Column %d: %s\n", line, col, err.message)
		}
	}

	// Stats
	arena := job.arena_ptr^
	fmt.eprintf("\n--- Statistics ---\n")
	ratio := (arena.total_used * 100) / arena.total_reserved
	fmt.eprintf("Arena: used=%dB reserved=%dB ratio=%d%%\n", arena.total_used, arena.total_reserved, ratio)
	fmt.eprintf("Parse errors: %d\n", len(job.parser.errors))
}

// ============================================================================
// Raw transfer: parse and produce binary AST buffer
// ============================================================================

raw_transfer_file :: proc(file_path: string, out_path: string, cli: CliConfig) {
	// All flag threading (lang, source-type, strict, preserve-parens,
	// .d.ts) flows through ParseJob now - matches the JSON path exactly.
	// Previously this used the standalone produce_raw_buffer which only
	// accepted `lang`, silently ignoring every other flag.
	job: ParseJob
	if !parse_job_open(&job, file_path, parse_config_from_cli(cli)) {
		fmt.eprintf("Error: Could not read file: %s\n", file_path)
		os.exit(1)
	}
	defer parse_job_close(&job)

	// Time the parse + rewrite for the diagnostic banner. Measured at
	// the call site (not inside parse_job_run) so the bench loop pays no
	// time.tick_now() overhead it doesn't ask for.
	start := time.tick_now()
	parse_job_run(&job)
	if cli.show_semantic_errors { checker_run_for_job(&job) }
	result := produce_raw_buffer_from_job(&job)
	elapsed := time.tick_since(start)

	if out_path != "" {
		ok := write_raw_buffer(result, out_path)
		if !ok {
			fmt.eprintf("Error: Could not write to %s\n", out_path)
			os.exit(1)
		}
	}

	source_len := len(job.source.data)
	fmt.eprintf("Raw transfer: %s\n", file_path)
	fmt.eprintf("  Source:      %d bytes\n", source_len)
	fmt.eprintf("  Buffer:      %d bytes (%.1fx source)\n", len(result.buffer), f64(len(result.buffer)) / f64(max(source_len, 1)))
	fmt.eprintf("  Program at:  offset %d\n", result.header.program_offset)
	fmt.eprintf("  Parse errors: %d\n", result.error_count)
	fmt.eprintf("  Time:        %.3f ms\n", f64(time.duration_microseconds(elapsed)) / 1000.0)
	if out_path != "" {
		fmt.eprintf("  Written to:  %s (%d bytes = header %d + buffer %d)\n",
			out_path, size_of(RawTransferHeader) + len(result.buffer),
			size_of(RawTransferHeader), len(result.buffer))
	}
}

// ============================================================================
// parse_file_to_disk: Parse and write AST JSON to a file. Thread-safe.
// ============================================================================

parse_file_to_disk :: proc(file_path: string, out_path: string, cli: CliConfig) -> (ok: bool, file_size: int, error_count: int) {
	job: ParseJob
	if !parse_job_open(&job, file_path, parse_config_from_cli(cli)) { return false, 0, 0 }
	defer parse_job_close(&job)
	parse_job_run(&job)
	if cli.show_semantic_errors { checker_run_for_job(&job) }

	// Each worker constructs its own Emitter - thread-safe by
	// construction. The pre-#2 save / restore dance over a global
	// `direct_buf` is gone.
	e: Emitter
	emitter_init(&e, emit_config_from_cli(cli, job.lang), len(job.source.data), context.allocator)
	defer emitter_destroy(&e, context.allocator)

	emitter_build_utf16(&e, job.source.data, context.allocator)
	if e.cfg.loc {
		build_line_table(&job.lexer)
		emitter_adopt_lines(&e, job.lexer.line_offsets)
	}

	emit_raw(&e, "{\n")
	emit_program(&e, job.program, 1)
	if e.cfg.module_record {
		emit_module_record(&e, &job.parser, 1)
	}
	emit_raw(&e, "}\n")

	_ = os.write_entire_file(out_path, e.buf[:e.pos])

	return true, len(job.source.data), len(job.parser.errors)
}

// ============================================================================
// parse_file_raw_to_disk: Parse and write raw binary buffer to a file. Thread-safe.
// ============================================================================

parse_file_raw_to_disk :: proc(file_path: string, out_path: string, cli: CliConfig) -> (ok: bool, file_size: int, error_count: int) {
	job: ParseJob
	if !parse_job_open(&job, file_path, parse_config_from_cli(cli)) { return false, 0, 0 }
	defer parse_job_close(&job)
	parse_job_run(&job)
	if cli.show_semantic_errors { checker_run_for_job(&job) }

	result := produce_raw_buffer_from_job(&job)
	if !write_raw_buffer(result, out_path) {
		return false, 0, 0
	}
	return true, len(job.source.data), result.error_count
}

// ============================================================================
// parse_many: Multi-file parsing with static work division
// ============================================================================

ParseWorkerCtx :: struct {
	files: []string,
	out_dir: string,
	start_idx: int,
	end_idx: int,
	parsed_count: int,
	error_count: int,
	total_bytes: int,
	write_raw: bool,
	// Snapshot of CLI options taken at parse_many entry. Each worker
	// reads its own copy; no shared mutable state. Pre-#6 workers read
	// process globals, which made the multi-file path silently drop
	// every per-call flag (--source-type, --force-strict, ...).
	cli: CliConfig,
}

worker_proc :: proc(data: rawptr) {
	ctx := (^ParseWorkerCtx)(data)
	for i in ctx.start_idx..<ctx.end_idx {
		base := filepath_base(ctx.files[i])
		ext := ".json"
		if ctx.write_raw { ext = ".bin" }
		out_path := strings.concatenate({ctx.out_dir, "/", base, ext})
		success: bool
		bytes: int
		errs: int
		if ctx.write_raw {
			success, bytes, errs = parse_file_raw_to_disk(ctx.files[i], out_path, ctx.cli)
		} else {
			success, bytes, errs = parse_file_to_disk(ctx.files[i], out_path, ctx.cli)
		}
		if success {
			ctx.parsed_count += 1
			ctx.total_bytes += bytes
			ctx.error_count += errs
		}
	}
}

// Map a file path to a Lang mode based on its extension. Returns .JSX as
// a permissive default so anything we can't classify (stdin, no extension,
// weird suffix) keeps today's JSX-everywhere behaviour. Tighter modes (.JS,
// .TS) are opt-in via explicit extension or the --lang flag.
//
//   .ts / .mts / .cts / .d.ts → Lang.TS   (no JSX)
//   .tsx                      → Lang.TSX  (TS + JSX)
//   .jsx                      → Lang.JSX
//   .js / .mjs / .cjs / other → Lang.JS   (no JSX — matches OXC;
//                                         callers needing JSX pass
//                                         --lang=jsx explicitly)
detect_lang_from_path :: proc(path: string) -> Lang {
	// Longest suffixes first - check .d.ts before .ts.
	if strings.has_suffix(path, ".d.ts") { return .TS }
	if strings.has_suffix(path, ".tsx")  { return .TSX }
	if strings.has_suffix(path, ".jsx")  { return .JSX }
	if strings.has_suffix(path, ".ts")   { return .TS }
	if strings.has_suffix(path, ".mts")  { return .TS }
	if strings.has_suffix(path, ".cts")  { return .TS }
	return .JS
}

// Parse a --lang=<mode> CLI value into a Lang. Returns (lang, ok). `ok=false`
// if the user typed something unrecognised; caller should error and exit.
parse_lang_flag :: proc(value: string) -> (Lang, bool) {
	switch value {
	case "js":   return .JS,  true
	case "jsx":  return .JSX, true
	case "ts":   return .TS,  true
	case "tsx":  return .TSX, true
	}
	return .JSX, false
}

// (resolve_lang dropped in #6: the only consumer was itself; lang
// resolution now lives in src/parse_job.odin parse_job_resolve, which
// uses ParseConfig.lang_override.)

// Extract filename without directory from a path
filepath_base :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			return path[i+1:]
		}
	}
	return path
}

// Create directory and all parents (like mkdir -p)
mkdir_p :: proc(path: string) {
	for i in 0..<len(path) {
		if path[i] == '/' && i > 0 {
			os.make_directory(path[:i])
		}
	}
	os.make_directory(path)
}

parse_many :: proc(files: []string, n_workers: int, out_dir: string, write_raw: bool, cli: CliConfig) {
	if len(files) == 0 {
		out_println("No files to parse.")
		return
	}

	// Create output directory (recursive)
	mkdir_p(out_dir)

	// Pre-initialize thread-unsafe global tables before spawning workers.
	init_char_class_table()

	start_time := time.tick_now()
	actual_workers := n_workers
	if actual_workers > len(files) { actual_workers = len(files) }
	if actual_workers < 1 { actual_workers = 1 }
	threads := make([]^thread.Thread, actual_workers)
	defer {
		for t in threads {
			thread.join(t)
			thread.destroy(t)
		}
		delete(threads)
	}
	contexts := make([]ParseWorkerCtx, actual_workers)
	defer delete(contexts)
	files_per_worker := len(files) / actual_workers
	remainder := len(files) % actual_workers
	for i in 0..<actual_workers {
		start := i * files_per_worker
		if i < remainder { start += i } else { start += remainder }
		end := start + files_per_worker
		if i < remainder { end += 1 }
		contexts[i] = ParseWorkerCtx{
			files = files,
			out_dir = out_dir,
			start_idx = start,
			end_idx = end,
			write_raw = write_raw,
			cli = cli,
		}
		threads[i] = thread.create_and_start_with_data(&contexts[i], worker_proc)
	}
	for t in threads {
		thread.join(t)
	}
	elapsed := time.tick_since(start_time)
	elapsed_ms := f64(elapsed) / 1_000_000.0
	total_parsed := 0
	total_bytes := 0
	total_errors := 0
	for c in contexts {
		total_parsed += c.parsed_count
		total_bytes += c.total_bytes
		total_errors += c.error_count
	}
	out_printf("parse-many summary:\n")
	out_printf("  Files: %d\n", total_parsed)
	out_printf("  Bytes: %d (%.2f MB)\n", total_bytes, f64(total_bytes) / 1e6)
	out_printf("  Errors: %d\n", total_errors)
	out_printf("  Time: %.2f ms\n", elapsed_ms)
	if elapsed_ms > 0 {
		throughput_mb := (f64(total_bytes) / 1e6) / (elapsed_ms / 1000)
		throughput_files := f64(total_parsed) / (elapsed_ms / 1000)
		out_printf("  Throughput: %.2f MB/s, %.1f files/s\n", throughput_mb, throughput_files)
	}
	out_printf("  Workers: %d\n", actual_workers)
	out_printf("  Output:  %s/\n", out_dir)
	os.flush(os.stdout)
}
// Microbench Command (in-process parse measurements)
// ============================================================================

// Lexer-only microbench: tokenize without parsing.
// Measures lexer dispatch + token emission in isolation.
// Fast-path lex-only benchmark (uses lex_token, same as parser)
microbench_lex :: proc(file_path: string, iterations: int) {
	src_buf, src_ok := source_read(file_path, context.allocator)
	if !src_ok {
		out_printf("Error: Could not read file: %s\n", file_path)
		flush_stdout_writer()
		os.exit(1)
	}
	defer source_release(src_buf, context.allocator)
	source := src_buf.data
	file_size := len(source)

	// Warm-up
	{
		arena: mvirtual.Arena
		_ = mvirtual.arena_init_static(&arena, uint(max(file_size * 128, 16 * 1024 * 1024)))
		defer mvirtual.arena_destroy(&arena)
		alloc := mvirtual.arena_allocator(&arena)
		lex: Lexer
		init_lexer(&lex, string(source), alloc)
		for { ft := lex_token(&lex); if ft.kind == .EOF { break } }
	}

	durations := make([dynamic]time.Duration, context.allocator)
	defer delete(durations)

	token_count: int = 0
	for i in 0..<iterations {
		start := time.tick_now()

		arena: mvirtual.Arena
		_ = mvirtual.arena_init_static(&arena, uint(max(file_size * 128, 16 * 1024 * 1024)))
		defer mvirtual.arena_destroy(&arena)
		alloc := mvirtual.arena_allocator(&arena)

		lex: Lexer
		init_start := time.tick_now()
		init_lexer(&lex, string(source), alloc)
		init_elapsed := time.tick_since(init_start)
		if i == 0 {
			out_printf("Init time: %.3f us\n", f64(time.duration_microseconds(init_elapsed)))
			flush_stdout_writer()
		}

		tc := 0
		for {
			ft := lex_token(&lex)
			if ft.kind == .EOF { break }
			tc += 1
		}

		elapsed := time.tick_since(start)
		append(&durations, elapsed)
		if i == 0 { token_count = tc }
	}

	microseconds := make([dynamic]f64, context.allocator)
	defer delete(microseconds)
	for d in durations { append(&microseconds, f64(time.duration_microseconds(d))) }

	// Sort for percentiles
	for i in 0..<len(microseconds) {
		for j in i+1..<len(microseconds) {
			if microseconds[j] < microseconds[i] {
				microseconds[i], microseconds[j] = microseconds[j], microseconds[i]
			}
		}
	}

	min_us := microseconds[0]
	max_us := microseconds[len(microseconds)-1]
	sum: f64 = 0
	for v in microseconds { sum += v }
	mean_us := sum / f64(len(microseconds))

	out_printf("Lex-fast: %s (%d bytes, %d tokens)\n", file_path, file_size, token_count)
	out_printf("Iterations: %d\n", iterations)
	out_printf("Min:  %.3f us\n", min_us)
	out_printf("Mean: %.3f us\n", mean_us)
	out_printf("Max:  %.3f us\n", max_us)
	flush_stdout_writer()
}

microbench_file :: proc(file_path: string, iterations: int, ast_only: bool, cli: CliConfig) {
	// Pre-read file size for the bench-tight arena formula. parse_job
	// opens it again below (mmap on POSIX is cheap); doing it twice
	// keeps the size-aware reservation logic in this file rather than
	// pushing a bench-shaped knob into ParseJob's contract. The actual
	// source bytes for parsing flow through job.source.
	probe, probe_ok := source_read(file_path, context.allocator)
	if !probe_ok {
		out_printf("Error: Could not read file: %s\n", file_path)
		flush_stdout_writer()
		os.exit(1)
	}
	file_size := len(probe.data)
	source_release(probe, context.allocator)

	// Allocate array for timing measurements
	durations := make([dynamic]time.Duration, context.allocator)
	defer delete(durations)

	// Pre-compute arena reservation based on source size
	// Small files: tight arena avoids mmap overhead for sub-microsecond parses
	// Large files: 128× source for AST + dynamic arrays
	arena_reserve := uint(file_size * 128)
	if arena_reserve < 256 * 1024 {
		arena_reserve = 256 * 1024  // 256KB min (avoids 16MB mmap for tiny files)
	}

	// Single arena for all iterations - reset between runs (no mmap/munmap per iter)
	arena: mvirtual.Arena
	err := mvirtual.arena_init_static(&arena, arena_reserve)
	if err != nil {
		fmt.eprintf("Error initializing arena: %v\n", err)
		os.exit(1)
	}
	defer mvirtual.arena_destroy(&arena)

	// One job for the whole bench. Borrowed arena lets us reset between
	// iterations without paying mmap/munmap; the job re-inits lexer +
	// parser fresh on every parse_job_run. ast_only is bench-only and
	// rides ParseConfig now.
	cfg := parse_config_from_cli(cli)
	cfg.ast_only = ast_only

	job: ParseJob
	if !parse_job_open_borrowed_arena(&job, file_path, cfg, &arena) {
		fmt.eprintf("Error: Could not read file: %s\n", file_path)
		os.exit(1)
	}
	defer parse_job_close(&job)

	// Warm-up run (1 iteration, not counted). reset_arena drops the
	// warm-up's allocations so the timed loop starts from a clean arena.
	parse_job_run(&job)
	parse_job_reset_arena(&job)

	// Main benchmark loop. The arena reset is performed BEFORE the timer
	// starts — in OXC's bench harness the arena (`Allocator`) is dropped
	// AFTER `elapsed = start.elapsed()`, so the deallocation cost is not
	// counted. Kessel's `mem.virtual` arena zero-fills its memory on
	// reset (~57 MB on typescript.js, ~2 ms at memcpy bandwidth); putting
	// it inside the timer was apples-to-oranges. Excluding it here gives
	// a fair Parser::new() + parse() vs init_lexer + init_parser +
	// parse_program comparison.
	for i in 0..<iterations {
		// Excluded from timing: arena teardown (mirrors OXC's drop-after-
		// elapsed). Real-world parse-once-and-exit doesn't pay this either.
		parse_job_reset_arena(&job)

		start := time.tick_now()
		parse_job_run(&job)
		elapsed := time.tick_since(start)
		append(&durations, elapsed)
	}

	// Convert durations to microseconds for analysis
	microseconds := make([dynamic]f64, context.allocator)
	defer delete(microseconds)

	for d in durations {
		append(&microseconds, f64(time.duration_microseconds(d)))
	}

	// Calculate statistics
	total_us := f64(0)
	min_us := microseconds[0]
	max_us := microseconds[0]

	for us in microseconds {
		total_us += us
		if us < min_us {
			min_us = us
		}
		if us > max_us {
			max_us = us
		}
	}

	mean_us := total_us / f64(len(microseconds))

	// Sort for percentiles
	slice.sort(microseconds[:])

	p50_us := percentile(microseconds[:], 50)
	p95_us := percentile(microseconds[:], 95)
	p99_us := percentile(microseconds[:], 99)

	total_ms := total_us / 1000.0

	// Output results
	out_printf("Microbench: %s (%d bytes)\n", file_path, file_size)
	out_printf("Iterations: %d\n", iterations)
	out_printf("Total time:  %.2f ms\n", total_ms)
	out_printf("Mean:        %.3f us\n", mean_us)
	out_printf("Min:         %.3f us\n", min_us)
	out_printf("Max:         %.3f us\n", max_us)
	out_printf("P50:         %.3f us\n", p50_us)
	out_printf("P95:         %.3f us\n", p95_us)
	out_printf("P99:         %.3f us\n", p99_us)
}

percentile :: proc(sorted_values: []f64, p: f64) -> f64 {
	if len(sorted_values) == 0 {
		return 0
	}
	if len(sorted_values) == 1 {
		return sorted_values[0]
	}

	idx := (p / 100.0) * f64(len(sorted_values) - 1)
	lower := int(idx)
	upper := lower + 1

	if upper >= len(sorted_values) {
		return sorted_values[len(sorted_values) - 1]
	}

	fraction := idx - f64(lower)
	return sorted_values[lower] * (1.0 - fraction) + sorted_values[upper] * fraction
}

// ============================================================================
// Lex Command (Tokenize)
// ============================================================================

lex_file :: proc(file_path: string) {
	src_buf, src_ok := source_read(file_path, context.allocator)
	if !src_ok {
		out_printf("Error: Could not read file: %s\n", file_path)
		flush_stdout_writer()
		os.exit(1)
	}
	defer source_release(src_buf, context.allocator)
	source := src_buf.data

	// Create virtual arena for allocations (lazy commit via virtual memory)
	arena: mvirtual.Arena
	err := mvirtual.arena_init_static(&arena, uint(max(len(source) * 256, 16 * 1024 * 1024)))
	if err != nil {
		fmt.eprintf("Error initializing arena: %v\n", err)
		os.exit(1)
	}
	defer mvirtual.arena_destroy(&arena)
	arena_alloc := mvirtual.arena_allocator(&arena)

	// Initialize lexer
	lex: Lexer
	init_lexer(&lex, string(source), arena_alloc)

	// Build line table for line/column reporting
	build_line_table(&lex)

	// Tokenize and print
	out_println("[")

	token_count := 0
	for {
		ft := lex.cur
		if ft.kind == .EOF { break }

		if token_count > 0 {
			out_println(",")
		}

		// Get source text
		value := token_source(&lex, ft)

		// Get line/column
		line, col := offset_to_line_col(lex.line_offsets, ft.start)

		// Line terminator flag
		has_lt := (ft.flags & FLAG_NEW_LINE) != 0

		out_printf("  {{\"type\": \"%s\", \"value\": ", get_token_name(ft.kind))

		// Escape string value for JSON
		escaped := value
		escaped, _ = strings.replace_all(escaped, "\\", "\\\\")
		escaped, _ = strings.replace_all(escaped, "\"", "\\\"")
		escaped, _ = strings.replace_all(escaped, "\n", "\\n")
		escaped, _ = strings.replace_all(escaped, "\t", "\\t")
		escaped, _ = strings.replace_all(escaped, "\r", "\\r")
		out_printf("\"%s\", ", escaped)
		out_printf("\"loc\": {{\"line\": %d, \"column\": %d}}, ", line, col)
		out_printf("\"lt\": %v}}", has_lt)

		token_count += 1

		// Advance: shift nxt→cur, lex new nxt
		lex.cur = lex.nxt
		if lex.cur.kind != .EOF {
			lex.nxt = lex_token(&lex)
		}
	}

	out_println()
	out_println("]")
	fmt.eprintf("\nTotal tokens: %d\n", token_count)
}


// ============================================================================
// Profile Parser Command
// ============================================================================

profile_parser_file :: proc(file_path: string, iterations: int) {
	src_buf, src_ok := source_read(file_path, context.allocator)
	if !src_ok {
		fmt.eprintf("Error: Could not read file: %s\n", file_path)
		os.exit(1)
	}
	defer source_release(src_buf, context.allocator)
	source := src_buf.data

	file_size := len(source)
	full_us := make([dynamic]f64, context.allocator)
	lex_us := make([dynamic]f64, context.allocator)
	defer delete(full_us)
	defer delete(lex_us)

	profile := ParserProfile{}
	profile_errors := 0
	profile_bump_used := 0
	profile_bump_cap := 0
	profile_bump_overflow := 0

	for i in 0..<iterations {
		arena: mvirtual.Arena
		_ = mvirtual.arena_init_static(&arena, uint(max(file_size * 256, 16 * 1024 * 1024)))
		defer mvirtual.arena_destroy(&arena)
		alloc := mvirtual.arena_allocator(&arena)

		lex_start := time.tick_now()
		lex_only: Lexer
		init_lexer(&lex_only, string(source), alloc)
		for { ft := lex_token(&lex_only); if ft.kind == .EOF { break } }
		append(&lex_us, f64(time.duration_microseconds(time.tick_since(lex_start))))

		arena_parse: mvirtual.Arena
		_ = mvirtual.arena_init_static(&arena_parse, uint(max(file_size * 256, 16 * 1024 * 1024)))
		defer mvirtual.arena_destroy(&arena_parse)
		parse_alloc := mvirtual.arena_allocator(&arena_parse)

		full_start := time.tick_now()

		lex: Lexer
		init_lexer(&lex, string(source), parse_alloc)

		p: Parser
		init_parser(&p, &lex, parse_alloc)
		if i == 0 {
			enable_profiling(&p)
		}
		program := parse_program(&p, .Script)

		full_dur := f64(time.duration_microseconds(time.tick_since(full_start)))
		append(&full_us, full_dur)

		if i == 0 {
			profile = get_profile(&p)
			profile_errors = len(p.errors)
			profile_bump_used, profile_bump_cap, profile_bump_overflow = get_bump_stats(&p)
		}
	}

	// Sort for percentiles
	// Simple insertion sort for small arrays
	for i in 1..<len(full_us) {
		key := full_us[i]
		j := i - 1
		for j >= 0 && full_us[j] > key {
			full_us[j+1] = full_us[j]
			j -= 1
		}
		full_us[j+1] = key
	}
	for i in 1..<len(lex_us) {
		key := lex_us[i]
		j := i - 1
		for j >= 0 && lex_us[j] > key {
			lex_us[j+1] = lex_us[j]
			j -= 1
		}
		lex_us[j+1] = key
	}

	p50_idx := min(len(full_us) - 1, len(full_us) / 2)
	lex_p50 := lex_us[p50_idx]
	full_p50 := full_us[p50_idx]
	parser_est := full_p50 - lex_p50
	parser_pct := (parser_est / max(full_p50, 1.0)) * 100.0

	fmt.eprintf("Parser profile: %s (%d bytes)\n", file_path, file_size)
	fmt.eprintf("Iterations: %d\n", iterations)
	fmt.eprintf("Lex P50:          %.3f us\n", lex_p50)
	fmt.eprintf("Full parse P50:   %.3f us\n", full_p50)
	fmt.eprintf("Parser est P50:   %.3f us (full - lex, %.1f%%)\n", parser_est, parser_pct)
	fmt.eprintf("Profile sample:   1 parser run\n")
	fmt.eprintf("  AST node allocs:      %d\n", profile.node_allocs)
	fmt.eprintf("  AST node bytes:       %d\n", profile.node_alloc_bytes)
	fmt.eprintf("  expr wrappers:        %d (%d bytes, %.1f%% of allocs)\n",
		profile.expr_wrapper_allocs,
		profile.expr_wrapper_allocs * u64(size_of(Expression)),
		(f64(profile.expr_wrapper_allocs) / f64(max(profile.node_allocs, 1))) * 100.0)
	fmt.eprintf("  stmt wrappers:        %d (%d bytes, %.1f%% of allocs)\n",
		profile.stmt_wrapper_allocs,
		profile.stmt_wrapper_allocs * u64(size_of(Statement)),
		(f64(profile.stmt_wrapper_allocs) / f64(max(profile.node_allocs, 1))) * 100.0)
	fmt.eprintf("  identifiers:          %d\n", profile.identifier_allocs)
	fmt.eprintf("  member exprs:         %d\n", profile.member_expr_allocs)
	fmt.eprintf("  call exprs:           %d\n", profile.call_expr_allocs)
	fmt.eprintf("  binary exprs:         %d\n", profile.binary_expr_allocs)
	fmt.eprintf("  logical exprs:        %d\n", profile.logical_expr_allocs)
	fmt.eprintf("  properties:           %d\n", profile.property_allocs)
	fmt.eprintf("  object exprs:         %d\n", profile.object_expr_allocs)
	fmt.eprintf("  array exprs:          %d\n", profile.array_expr_allocs)
	fmt.eprintf("  interner hits:        %d\n", profile.interner_hits)
	fmt.eprintf("  interner misses:      %d\n", profile.interner_misses)
	fmt.eprintf("  get_current calls:    %d\n", profile.get_current_calls)
	fmt.eprintf("  next calls:           %d\n", profile.next_calls)
	fmt.eprintf("  peek calls:           %d\n", profile.peek_calls)
	fmt.eprintf("  is calls:             %d\n", profile.is_calls)
	fmt.eprintf("  expect calls:         %d\n", profile.expect_calls)
	fmt.eprintf("  expr fallbacks:       %d\n", profile.expression_fallbacks)
	fmt.eprintf("  recovery tokens eaten:%d\n", profile.recovery_tokens_eaten)
	fmt.eprintf("  parse errors:         %d\n", profile_errors)

	// Bump pool diagnostics
	fmt.eprintf("  bump pool used:       %d / %d (%.1f%%)\n", profile_bump_used, profile_bump_cap, f64(profile_bump_used) / f64(max(profile_bump_cap, 1)) * 100.0)
	fmt.eprintf("  bump pool overflows:  %d\n", profile_bump_overflow)

	wrapper_bytes := profile.expr_wrapper_allocs * u64(size_of(Expression)) + profile.stmt_wrapper_allocs * u64(size_of(Statement))
	fmt.eprintf("  wrapper byte share:   %.1f%%\n", (f64(wrapper_bytes) / f64(max(profile.node_alloc_bytes, 1))) * 100.0)

	fmt.eprintf("  Expression union:     %d B\n", size_of(Expression))
	fmt.eprintf("  Statement union:      %d B\n", size_of(Statement))
	fmt.eprintf("  MemberExpression:     %d B\n", size_of(MemberExpression))
	fmt.eprintf("  CallExpression:       %d B\n", size_of(CallExpression))
	fmt.eprintf("  BinaryExpression:     %d B\n", size_of(BinaryExpression))
	fmt.eprintf("  LogicalExpression:    %d B\n", size_of(LogicalExpression))
	fmt.eprintf("  Identifier:           %d B\n", size_of(Identifier))
	fmt.eprintf("  ObjectExpression:     %d B\n", size_of(ObjectExpression))
	fmt.eprintf("  ArrayExpression:      %d B\n", size_of(ArrayExpression))
	fmt.eprintf("  FunctionExpression:   %d B\n", size_of(FunctionExpression))
	fmt.eprintf("  ClassExpression:      %d B\n", size_of(ClassExpression))

	lookahead := f64(profile.get_current_calls + profile.next_calls + profile.peek_calls + profile.is_calls + profile.expect_calls)
	consume := f64(profile.next_calls)
	fmt.eprintf("  lookahead/consume:    %.2f x\n", lookahead / max(consume, 1.0))
	fmt.eprintf("Linux samply: samply record ./kessel_bin microbench parse %s --iterations 1\n", file_path)
}

profile_lex_file :: proc(file_path: string, iterations: int) {
	src_buf, src_ok := source_read(file_path, context.allocator)
	if !src_ok {
		fmt.eprintf("Error: Could not read file: %s\n", file_path)
		os.exit(1)
	}
	defer source_release(src_buf, context.allocator)
	source := src_buf.data

	file_size := len(source)
	durations := make([dynamic]f64, context.allocator)
	defer delete(durations)

	token_count := 0

	// Warm-up
	{
		arena: mvirtual.Arena
		_ = mvirtual.arena_init_static(&arena, uint(max(file_size * 128, 16 * 1024 * 1024)))
		defer mvirtual.arena_destroy(&arena)
		alloc := mvirtual.arena_allocator(&arena)
		lex: Lexer
		init_lexer(&lex, string(source), alloc)
		for { ft := lex_token(&lex); if ft.kind == .EOF { break } }
	}

	for i in 0..<iterations {
		arena: mvirtual.Arena
		_ = mvirtual.arena_init_static(&arena, uint(max(file_size * 128, 16 * 1024 * 1024)))
		defer mvirtual.arena_destroy(&arena)
		alloc := mvirtual.arena_allocator(&arena)

		start := time.tick_now()
		lex: Lexer
		init_lexer(&lex, string(source), alloc)
		tc := 0
		for { ft := lex_token(&lex); if ft.kind == .EOF { break }; tc += 1 }
		append(&durations, f64(time.duration_microseconds(time.tick_since(start))))
		if i == 0 { token_count = tc }
	}

	// Sort
	for i in 1..<len(durations) {
		key := durations[i]
		j := i - 1
		for j >= 0 && durations[j] > key { durations[j+1] = durations[j]; j -= 1 }
		durations[j+1] = key
	}

	min_us := durations[0]
	max_us := durations[len(durations)-1]
	sum: f64 = 0
	for v in durations { sum += v }
	mean_us := sum / f64(len(durations))
	p50 := durations[len(durations) / 2]

	bytes_per_token := f64(file_size) / f64(max(token_count, 1))
	throughput_mb := f64(file_size) / min_us  // bytes/us = MB/s

	fmt.eprintf("Lex profile: %s (%d bytes, %d tokens)\n", file_path, file_size, token_count)
	fmt.eprintf("Iterations: %d\n", iterations)
	fmt.eprintf("Min:  %.3f us\n", min_us)
	fmt.eprintf("Mean: %.3f us\n", mean_us)
	fmt.eprintf("P50:  %.3f us\n", p50)
	fmt.eprintf("Max:  %.3f us\n", max_us)
	fmt.eprintf("Throughput:     %.1f MB/s\n", throughput_mb)
	fmt.eprintf("Bytes/token:    %.1f\n", bytes_per_token)
	fmt.eprintf("ns/token (min): %.1f\n", min_us * 1000.0 / f64(max(token_count, 1)))
}
