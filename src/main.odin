package main

import "core:bufio"
import "core:fmt"
import "core:io"
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
stdout_writer_buf: [1 * 1024 * 1024]byte // Increased from 64KB to 1MB for JSON streaming
stdout_stream: io.Writer

// Compact JSON output mode — skip indentation and newlines
compact_json: bool

// Direct buffer mode — pre-allocated []byte, zero bufio overhead
use_direct_buf: bool
direct_buf: []byte
direct_pos: int

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
direct_reserve :: #force_inline proc(need: int) {
	if direct_pos + need <= len(direct_buf) {
		return
	}
	new_cap := max(len(direct_buf) * 2, direct_pos + need)
	new_buf := make([]byte, new_cap, context.allocator)
	mem.copy(raw_data(new_buf), raw_data(direct_buf), direct_pos)
	delete(direct_buf, context.allocator)
	direct_buf = new_buf
}

// Fast-path for static strings (no reflection overhead)
// In compact mode, strips all \n from strings
// Helper: write string to direct buffer, skipping newlines in compact mode
write_direct :: #force_inline proc(s: string) {
	direct_reserve(len(s))
	if compact_json {
		for i in 0..<len(s) {
			if s[i] != '\n' {
				direct_buf[direct_pos] = s[i]
				direct_pos += 1
			}
		}
	} else {
		mem.copy(&direct_buf[direct_pos], raw_data(s), len(s))
		direct_pos += len(s)
	}
}

out_s :: #force_inline proc(s: string) {
	if use_direct_buf {
		write_direct(s)
		return
	}
	init_stdout_writer()
	if compact_json && len(s) > 0 {
		has_nl := false
		for i in 0..<len(s) {
			if s[i] == '\n' { has_nl = true; break }
		}
		if has_nl {
			for i in 0..<len(s) {
				if s[i] != '\n' {
					bufio.writer_write_byte(&stdout_writer, s[i])
				}
			}
			return
		}
	}
	bufio.writer_write_string(&stdout_writer, s)
}

// wtf8_surrogate_at checks if bytes starting at s[i] form a 3-byte WTF-8
// encoding of a lone UTF-16 surrogate (U+D800–U+DFFF). Returns the decoded
// codepoint and true on match.
//
// ECMA-262 permits lone surrogates in string literals (the `value` of
// `'\uDEAD'` is a 1-character string whose single codepoint is U+DEAD).
// The lexer's append_utf8 encodes these in WTF-8 — valid UTF-8 it is not,
// because the Unicode Standard reserves 0xED 0xA0–0xBF 0x80–0xBF. Emitting
// those raw bytes to stdout produces JSON that JSON.parse normalises to
// U+FFFD (the replacement character), diverging from OXC which emits the
// surrogate as a JSON `\uXXXX` escape. We mirror OXC on emit.
//
// Triple layout:
//   byte0: 0xED
//   byte1: 0xA0..0xBF  (bit 5 = 1 ↔ high nibble of cp is 0xD8..0xDF)
//   byte2: 0x80..0xBF
// Decoded: cp = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F)
// Range:   0xD800..0xDFFF.
wtf8_surrogate_at :: #force_inline proc(s: string, i: int) -> (cp: u32, ok: bool) {
	if i + 2 >= len(s) { return 0, false }
	b0 := s[i]
	if b0 != 0xED { return 0, false }
	b1 := s[i + 1]
	if b1 < 0xA0 || b1 > 0xBF { return 0, false }
	b2 := s[i + 2]
	if b2 < 0x80 || b2 > 0xBF { return 0, false }
	cp = (u32(b0 & 0x0F) << 12) | (u32(b1 & 0x3F) << 6) | u32(b2 & 0x3F)
	return cp, true
}

// Escape a string for JSON without the surrounding quotes. Used when we
// need to splice escaped content inside a larger quoted string (e.g. the
// regex `raw` field `"/<pattern>/<flags>"`), so we can emit the opening
// quote, multiple escaped chunks, and the closing quote around them all.
out_string_inner :: proc(s: string) {
	if use_direct_buf {
		// Worst case: every byte escapes to `\u00xx` (6 bytes). WTF-8 surrogate
		// triples (3 bytes → 6-byte \uXXXX) stay inside that bound.
		direct_reserve(len(s) * 6)
		i := 0
		for i < len(s) {
			c := s[i]
			switch c {
			case '"':
				direct_buf[direct_pos] = '\\'; direct_buf[direct_pos+1] = '"'; direct_pos += 2
				i += 1
			case '\\':
				direct_buf[direct_pos] = '\\'; direct_buf[direct_pos+1] = '\\'; direct_pos += 2
				i += 1
			case '\n':
				direct_buf[direct_pos] = '\\'; direct_buf[direct_pos+1] = 'n'; direct_pos += 2
				i += 1
			case '\r':
				direct_buf[direct_pos] = '\\'; direct_buf[direct_pos+1] = 'r'; direct_pos += 2
				i += 1
			case '\t':
				direct_buf[direct_pos] = '\\'; direct_buf[direct_pos+1] = 't'; direct_pos += 2
				i += 1
			case:
				if c < 0x20 {
					tmp: [8]byte
					esc := fmt.bprintf(tmp[:], "\\u%04x", c)
					mem.copy(&direct_buf[direct_pos], raw_data(esc), len(esc))
					direct_pos += len(esc)
					i += 1
				} else if cp, ok := wtf8_surrogate_at(s, i); ok {
					// Lone surrogate: emit \uXXXX (lowercase hex matches OXC).
					tmp: [8]byte
					esc := fmt.bprintf(tmp[:], "\\u%04x", cp)
					mem.copy(&direct_buf[direct_pos], raw_data(esc), len(esc))
					direct_pos += len(esc)
					i += 3
				} else {
					direct_buf[direct_pos] = c
					direct_pos += 1
					i += 1
				}
			}
		}
		return
	}
	init_stdout_writer()
	i := 0
	for i < len(s) {
		c := s[i]
		switch c {
		case '"':  bufio.writer_write_string(&stdout_writer, "\\\""); i += 1
		case '\\': bufio.writer_write_string(&stdout_writer, "\\\\"); i += 1
		case '\n': bufio.writer_write_string(&stdout_writer, "\\n"); i += 1
		case '\r': bufio.writer_write_string(&stdout_writer, "\\r"); i += 1
		case '\t': bufio.writer_write_string(&stdout_writer, "\\t"); i += 1
		case:
			if c < 0x20 {
				tmp: [8]byte
				sx := fmt.bprintf(tmp[:], "\\u%04x", c)
				bufio.writer_write_string(&stdout_writer, sx)
				i += 1
			} else if cp, ok := wtf8_surrogate_at(s, i); ok {
				tmp: [8]byte
				sx := fmt.bprintf(tmp[:], "\\u%04x", cp)
				bufio.writer_write_string(&stdout_writer, sx)
				i += 3
			} else {
				bufio.writer_write_byte(&stdout_writer, c)
				i += 1
			}
		}
	}
}

// Escape a string for JSON: quotes, backslashes, control chars, lone
// surrogates. See `wtf8_surrogate_at` for the surrogate rationale.
out_string :: proc(s: string) {
	if use_direct_buf {
		// Worst case: 2 surrounding quotes + every byte escapes to `\u00xx`.
		direct_reserve(len(s) * 6 + 2)
		direct_buf[direct_pos] = '"'
		direct_pos += 1
		i := 0
		for i < len(s) {
			c := s[i]
			switch c {
			case '"':
				direct_buf[direct_pos] = '\\'; direct_buf[direct_pos+1] = '"'; direct_pos += 2
				i += 1
			case '\\':
				direct_buf[direct_pos] = '\\'; direct_buf[direct_pos+1] = '\\'; direct_pos += 2
				i += 1
			case '\n':
				direct_buf[direct_pos] = '\\'; direct_buf[direct_pos+1] = 'n'; direct_pos += 2
				i += 1
			case '\r':
				direct_buf[direct_pos] = '\\'; direct_buf[direct_pos+1] = 'r'; direct_pos += 2
				i += 1
			case '\t':
				direct_buf[direct_pos] = '\\'; direct_buf[direct_pos+1] = 't'; direct_pos += 2
				i += 1
			case:
				if c < 0x20 {
					tmp: [8]byte
					esc := fmt.bprintf(tmp[:], "\\u%04x", c)
					mem.copy(&direct_buf[direct_pos], raw_data(esc), len(esc))
					direct_pos += len(esc)
					i += 1
				} else if cp, ok := wtf8_surrogate_at(s, i); ok {
					tmp: [8]byte
					esc := fmt.bprintf(tmp[:], "\\u%04x", cp)
					mem.copy(&direct_buf[direct_pos], raw_data(esc), len(esc))
					direct_pos += len(esc)
					i += 3
				} else {
					direct_buf[direct_pos] = c
					direct_pos += 1
					i += 1
				}
			}
		}
		direct_buf[direct_pos] = '"'
		direct_pos += 1
		return
	}
	init_stdout_writer()
	bufio.writer_write_byte(&stdout_writer, '"')
	i := 0
	for i < len(s) {
		c := s[i]
		switch c {
		case '"':
			bufio.writer_write_string(&stdout_writer, "\\\""); i += 1
		case '\\':
			bufio.writer_write_string(&stdout_writer, "\\\\"); i += 1
		case '\n':
			bufio.writer_write_string(&stdout_writer, "\\n"); i += 1
		case '\r':
			bufio.writer_write_string(&stdout_writer, "\\r"); i += 1
		case '\t':
			bufio.writer_write_string(&stdout_writer, "\\t"); i += 1
		case:
			if c < 0x20 {
				tmp: [8]byte
				sx := fmt.bprintf(tmp[:], "\\u%04x", c)
				bufio.writer_write_string(&stdout_writer, sx)
				i += 1
			} else if cp, ok := wtf8_surrogate_at(s, i); ok {
				tmp: [8]byte
				sx := fmt.bprintf(tmp[:], "\\u%04x", cp)
				bufio.writer_write_string(&stdout_writer, sx)
				i += 3
			} else {
				bufio.writer_write_byte(&stdout_writer, c)
				i += 1
			}
		}
	}
	bufio.writer_write_byte(&stdout_writer, '"')
}

// Write bool as 'true' or 'false'
out_bool :: #force_inline proc(b: bool) {
	if use_direct_buf {
		direct_reserve(5)
		if b {
			direct_buf[direct_pos] = 't'; direct_buf[direct_pos+1] = 'r'; direct_buf[direct_pos+2] = 'u'; direct_buf[direct_pos+3] = 'e'; direct_pos += 4
		} else {
			direct_buf[direct_pos] = 'f'; direct_buf[direct_pos+1] = 'a'; direct_buf[direct_pos+2] = 'l'; direct_buf[direct_pos+3] = 's'; direct_buf[direct_pos+4] = 'e'; direct_pos += 5
		}
		return
	}
	init_stdout_writer()
	if b {
		bufio.writer_write_string(&stdout_writer, "true")
	} else {
		bufio.writer_write_string(&stdout_writer, "false")
	}
}

out_print :: proc(args: ..any) -> int {
	if use_direct_buf {
		// For AST emitter: all out_print calls use string args only
		// Just concatenate directly
		for arg in args {
			if v, ok := arg.(string); ok {
				write_direct(v)
			}
		}
		return 0
	}
	init_stdout_writer()
	return fmt.wprint(stdout_stream, ..args, flush=false)
}

out_println :: proc(args: ..any) -> int {
	if use_direct_buf {
		for arg in args {
			if v, ok := arg.(string); ok {
				write_direct(v)
			}
		}
		if !compact_json {
			direct_reserve(1)
			direct_buf[direct_pos] = '\n'
			direct_pos += 1
		}
		return 0
	}
	init_stdout_writer()
	if compact_json {
		return fmt.wprint(stdout_stream, ..args, flush=false)
	}
	return fmt.wprintln(stdout_stream, ..args, flush=false)
}

out_printf :: proc(format: string, args: ..any) -> int {
	if use_direct_buf {
		sb: strings.Builder
		strings.builder_init(&sb)
		fmt.sbprintf(&sb, format, ..args)
		s := strings.to_string(sb)
		write_direct(s)
		strings.builder_destroy(&sb)
		return len(s)
	}
	init_stdout_writer()
	return fmt.wprintf(stdout_stream, format, ..args, flush=false)
}

main :: proc() {
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
		parse_files := make([dynamic]string)
		parse_workers := 0
		parse_out_dir := ""
		parse_raw := false
		compact_json = false
		{
			i := 2
			for i < len(os.args) {
				arg := os.args[i]
				if arg == "--compact" {
					compact_json = true
				} else if arg == "--raw" {
					parse_raw = true
				} else if arg == "--workers" && i + 1 < len(os.args) {
					n, _ := strconv.parse_int(os.args[i+1])
					parse_workers = n
					i += 1
				} else if arg == "--out-dir" && i + 1 < len(os.args) {
					parse_out_dir = os.args[i+1]
					i += 1
				} else {
					append(&parse_files, arg)
				}
				i += 1
			}
		}
		if len(parse_files) == 1 {
			if parse_raw {
				if parse_out_dir != "" {
					base := filepath_base(parse_files[0])
					out_path := strings.concatenate({parse_out_dir, "/", base, ".bin"})
					parse_file_raw_to_disk(parse_files[0], out_path)
				} else {
					raw_transfer_file(parse_files[0], "")
				}
			} else {
				parse_file(parse_files[0])
			}
		} else if len(parse_files) > 1 {
			if parse_workers == 0 {
				parse_workers = os.get_processor_core_count()
				if parse_workers < 1 { parse_workers = 1 }
			}
			if parse_out_dir == "" { parse_out_dir = parse_raw ? "tmp/raw" : "tmp/ast" }
			parse_many(parse_files[:], parse_workers, parse_out_dir, parse_raw)
		}
		delete(parse_files)

	case "raw":
		// Produce raw transfer buffer — for testing/benchmarking the zero-copy path
		if len(os.args) < 3 {
			out_println("Usage: kessel raw <file> [--out file.bin]")
			flush_stdout_writer()
			os.exit(1)
		}
		raw_file := os.args[2]
		raw_out := ""
		if len(os.args) >= 5 && os.args[3] == "--out" {
			raw_out = os.args[4]
		}
		raw_transfer_file(raw_file, raw_out)

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
			out_println("Usage: kessel microbench parse <file> [--iterations N]")
			out_println("       kessel microbench lex <file> [--iterations N]")
			flush_stdout_writer()
			os.exit(1)
		}
		mb_sub := os.args[2]
		mb_file := os.args[3]
		mb_iters := 100
		if len(os.args) >= 6 && os.args[4] == "--iterations" {
			n, ok := strconv.parse_int(os.args[5])
			if ok { mb_iters = n }
		}
		switch mb_sub {
		case "parse":
			microbench_file(mb_file, mb_iters)
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



parse_file :: proc(file_path: string) {
	// Read file
	source, read_err := os.read_entire_file_from_path(file_path, context.allocator)
	if read_err != nil {
		out_printf("Error: Could not read file: %s\n", file_path)
		flush_stdout_writer()
		os.exit(1)
	}
	defer delete(source, context.allocator)
	
	// Create virtual arena for allocations (lazy commit via virtual memory)
	arena: mvirtual.Arena
	arena_size := uint(max(len(source) * 256, 16 * 1024 * 1024))
	err := mvirtual.arena_init_static(&arena, arena_size)
	if err != nil {
		fmt.eprintf("Error initializing arena: %v\n", err)
		os.exit(1)
	}
	defer mvirtual.arena_destroy(&arena)
	arena_alloc := mvirtual.arena_allocator(&arena)
	
	// Initialize optimized lexer with compact tokens + SIMD
	lex: Lexer
	init_lexer(&lex, string(source), arena_alloc)
	
	// Initialize parser with optimized lexer
	p: Parser
	init_parser(&p, &lex, arena_alloc)

	// Parse program
	program := parse_program(&p, .Script)
	
	// Output AST as JSON via direct buffer (zero bufio overhead)
	// Pre-allocate ~12× source size for JSON output (compact ≈ 9×, pretty ≈ 20×)
	est_size := max(len(source) * 20, 4096)  // generous: 20× source, min 4KB
	direct_buf = make([]byte, est_size, context.allocator)
	direct_pos = 0
	use_direct_buf = true

	out_s("{\n")
	print_program_ast(program, 1)
	out_s("}\n")

	// Single write to stdout for the JSON body first. Diagnostic lines
	// (parse errors, stats) must follow the JSON on separate lines so
	// downstream consumers can split on the first newline and JSON.parse
	// the line without stripping error preambles. Previously errors were
	// emitted through the bufio writer BEFORE this direct write; the
	// bufio writer only flushed at process exit, so its bytes actually
	// appeared on stdout AFTER the JSON bytes — and without the
	// intervening newline the JSON and the error header ran together
	// (…]}}}Parse errors (6):…), breaking every downstream JSON.parse.
	os.write(os.stdout, direct_buf[:direct_pos])

	// Now emit parse-error diagnostics through the bufio writer. They
	// will appear on subsequent lines of stdout; Statistics below go to
	// stderr as before.
	if len(p.errors) > 0 {
		out_printf("Parse errors (%d):\n", len(p.errors))
		for err in p.errors {
			out_printf("  Line %d, Column %d: %s\n", err.loc.line, err.loc.column, err.message)
		}
		flush_stdout_writer()
	}
	delete(direct_buf, context.allocator)
	direct_buf = nil
	use_direct_buf = false
	
	// Print statistics
	fmt.eprintf("\n--- Statistics ---\n")
	ratio := (arena.total_used * 100) / arena.total_reserved
	fmt.eprintf("Arena: used=%dB reserved=%dB ratio=%d%%\n", arena.total_used, arena.total_reserved, ratio)
	fmt.eprintf("Parse errors: %d\n", len(p.errors))
}

// ============================================================================
// Raw transfer: parse and produce binary AST buffer
// ============================================================================

raw_transfer_file :: proc(file_path: string, out_path: string) {
	source, read_err := os.read_entire_file_from_path(file_path, context.allocator)
	if read_err != nil {
		fmt.eprintf("Error: Could not read file: %s\n", file_path)
		os.exit(1)
	}
	defer delete(source, context.allocator)

	arena: mvirtual.Arena
	arena_size := uint(max(len(source) * 256, 16 * 1024 * 1024))
	err := mvirtual.arena_init_static(&arena, arena_size)
	if err != nil {
		fmt.eprintf("Error initializing arena: %v\n", err)
		os.exit(1)
	}
	defer mvirtual.arena_destroy(&arena)
	arena_alloc := mvirtual.arena_allocator(&arena)

	start := time.tick_now()
	result := produce_raw_buffer(string(source), &arena, arena_alloc)
	elapsed := time.tick_since(start)

	if out_path != "" {
		ok := write_raw_buffer(result, out_path)
		if !ok {
			fmt.eprintf("Error: Could not write to %s\n", out_path)
			os.exit(1)
		}
	}

	fmt.eprintf("Raw transfer: %s\n", file_path)
	fmt.eprintf("  Source:      %d bytes\n", len(source))
	fmt.eprintf("  Buffer:      %d bytes (%.1fx source)\n", len(result.buffer), f64(len(result.buffer)) / f64(max(len(source), 1)))
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

parse_file_to_disk :: proc(file_path: string, out_path: string) -> (ok: bool, file_size: int, error_count: int) {
	source, read_err := os.read_entire_file_from_path(file_path, context.allocator)
	if read_err != nil { return false, 0, 0 }
	defer delete(source, context.allocator)

	arena: mvirtual.Arena
	_ = mvirtual.arena_init_static(&arena, uint(max(len(source) * 256, 16 * 1024 * 1024)))
	defer mvirtual.arena_destroy(&arena)
	arena_alloc := mvirtual.arena_allocator(&arena)

	lex: Lexer
	init_lexer(&lex, string(source), arena_alloc)
	p: Parser
	init_parser(&p, &lex, arena_alloc)
	program := parse_program(&p, .Script)

	// Render AST JSON into a thread-local buffer. `direct_reserve` may grow
	// direct_buf during emission (reallocating and freeing the old slice),
	// so we can't cache the initial make() into a local and `defer delete`
	// it — that would double-free after grow. Instead, free whatever
	// direct_buf points to at the end.
	est_size := max(len(source) * 20, 4096)

	// Save/restore globals (direct_buf is global — use local override)
	prev_buf := direct_buf
	prev_pos := direct_pos
	prev_use := use_direct_buf
	direct_buf = make([]byte, est_size, context.allocator)
	direct_pos = 0
	use_direct_buf = true

	out_s("{\n")
	print_program_ast(program, 1)
	out_s("}\n")

	// Write to file
	_ = os.write_entire_file(out_path, direct_buf[:direct_pos])

	delete(direct_buf, context.allocator)
	direct_buf = prev_buf
	direct_pos = prev_pos
	use_direct_buf = prev_use

	return true, len(source), len(p.errors)
}

// ============================================================================
// parse_file_raw_to_disk: Parse and write raw binary buffer to a file. Thread-safe.
// ============================================================================

parse_file_raw_to_disk :: proc(file_path: string, out_path: string) -> (ok: bool, file_size: int, error_count: int) {
	source, read_err := os.read_entire_file_from_path(file_path, context.allocator)
	if read_err != nil { return false, 0, 0 }
	defer delete(source, context.allocator)

	arena: mvirtual.Arena
	arena_size := uint(max(len(source) * 256, 16 * 1024 * 1024))
	init_err := mvirtual.arena_init_static(&arena, arena_size)
	if init_err != nil { return false, 0, 0 }
	defer mvirtual.arena_destroy(&arena)
	arena_alloc := mvirtual.arena_allocator(&arena)

	result := produce_raw_buffer(string(source), &arena, arena_alloc)
	if !write_raw_buffer(result, out_path) {
		return false, 0, 0
	}
	return true, len(source), result.error_count
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
			success, bytes, errs = parse_file_raw_to_disk(ctx.files[i], out_path)
		} else {
			success, bytes, errs = parse_file_to_disk(ctx.files[i], out_path)
		}
		if success {
			ctx.parsed_count += 1
			ctx.total_bytes += bytes
			ctx.error_count += errs
		}
	}
}

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

parse_many :: proc(files: []string, n_workers: int, out_dir: string, write_raw: bool) {
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
	source, read_err := os.read_entire_file_from_path(file_path, context.allocator)
	if read_err != nil {
		out_printf("Error: Could not read file: %s\n", file_path)
		flush_stdout_writer()
		os.exit(1)
	}
	defer delete(source, context.allocator)
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

microbench_file :: proc(file_path: string, iterations: int) {
	// Read file once
	source, read_err := os.read_entire_file_from_path(file_path, context.allocator)
	if read_err != nil {
		out_printf("Error: Could not read file: %s\n", file_path)
		flush_stdout_writer()
		os.exit(1)
	}
	defer delete(source, context.allocator)
	
	file_size := len(source)
	
	// Allocate array for timing measurements
	durations := make([dynamic]time.Duration, context.allocator)
	defer delete(durations)
	
	// Pre-compute arena reservation based on source size
	// Small files: tight arena avoids mmap overhead for sub-microsecond parses
	// Large files: 128× source for AST + dynamic arrays
	arena_reserve := uint(len(source) * 128)
	if arena_reserve < 256 * 1024 {
		arena_reserve = 256 * 1024  // 256KB min (avoids 16MB mmap for tiny files)
	}

	// Single arena for all iterations — reset between runs (no mmap/munmap per iter)
	arena: mvirtual.Arena
	err := mvirtual.arena_init_static(&arena, arena_reserve)
	if err != nil {
		fmt.eprintf("Error initializing arena: %v\n", err)
		os.exit(1)
	}
	defer mvirtual.arena_destroy(&arena)
	arena_alloc := mvirtual.arena_allocator(&arena)

	// Warm-up run (1 iteration, not counted)
	{
		lex: Lexer
		init_lexer(&lex, string(source), arena_alloc)
		
		p: Parser
		init_parser(&p, &lex, arena_alloc)
		
		_ = parse_program(&p, .Script)
		mvirtual.arena_free_all(&arena)
	}
	
	// Main benchmark loop
	for i in 0..<iterations {
		start := time.tick_now()
		
		// Reset arena (real-world cost: always happens before a parse)
		mvirtual.arena_free_all(&arena)
		
		lex: Lexer
		init_lexer(&lex, string(source), arena_alloc)
		
		p: Parser
		init_parser(&p, &lex, arena_alloc)
		
		_ = parse_program(&p, .Script)
		
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
// AST Printing (JSON-like output)
// ============================================================================

print_indent :: proc(indent: int) {
	if compact_json { return }
	for i in 0..<indent {
		out_print("  ")
	}
}

// ESTree-compatible root node emission.
//
// Drifts closed here:
//   * type: "Script"/"Module" → type: "Program" + sourceType: "script"/"module".
//     Every standard ESTree parser (acorn, babel, espree, oxc) uses "Program"
//     as the root node type; "Script" was a Kessel-internal name that no
//     downstream consumer recognises.
//   * Add start/end: byte offsets covering the entire source. Acorn/OXC/Babel
//     all emit these; Kessel previously emitted no position info at all.
//   * hashbang: emit "hashbang" field with null when absent (OXC shape). The
//     lexer currently skips shebang lines without preserving content — we
//     still declare the field so consumers don't see it as "missing".
print_program_ast :: proc(program: ^Program, indent: int) {
	source_type_str := "script" if program.type == .Script else "module"
	print_indent(indent)
	out_s("\"type\": \"Program\",\n")
	print_indent(indent)
	emit_span_leading(program.loc, indent)
	out_s("\"sourceType\": \"")
	out_s(source_type_str)
	out_s("\",\n")
	print_indent(indent)
	out_s("\"hashbang\": null,\n")

	print_indent(indent)
	out_s("\"body\": [\n")

	for stmt, i in program.body {
		print_indent(indent + 1)
		out_s("{\n")
		print_statement_ast(stmt, indent + 2)
		print_indent(indent + 1)
		if i < len(program.body) - 1 {
			out_s("},\n")
		} else {
			out_s("}\n")
		}
	}

	print_indent(indent)
	out_s("]\n")
}

// emit_identifier_name_object writes a full `{"type":"Identifier","start":N,
// "end":N,"name":"..."}` object for an `IdentifierName` or `BindingIdentifier`
// value. Used wherever ESTree expects an Identifier node inline — e.g.
// ExportSpecifier.local, ImportSpecifier.imported, ClassDeclaration.id. Emits
// with the caller-supplied indent on each line; the opening `{` is written
// here, the closing `}` too. Callers handle leading field name and trailing
// comma.
emit_identifier_name_object :: proc(id: IdentifierName, indent: int) {
	out_s("{\n")
	print_indent(indent + 1)
	out_s("\"type\": \"Identifier\",\n")
	print_indent(indent + 1)
	emit_span_leading(id.loc, indent + 1)
	out_s("\"name\": ")
	out_string(id.name)
	out_s("\n")
	print_indent(indent)
	out_s("}")
}

// emit_binding_identifier_object is a convenience alias for BindingIdentifier,
// which has the same layout. Odin treats them as distinct types so we give it
// its own entry point rather than cast at every call site.
emit_binding_identifier_object :: proc(id: BindingIdentifier, indent: int) {
	out_s("{\n")
	print_indent(indent + 1)
	out_s("\"type\": \"Identifier\",\n")
	print_indent(indent + 1)
	emit_span_leading(id.loc, indent + 1)
	out_s("\"name\": ")
	out_string(id.name)
	out_s("\n")
	print_indent(indent)
	out_s("}")
}

// emit_string_literal_object writes a full ESTree Literal object for a
// StringLiteral value — used inline by ImportDeclaration.source and
// ExportAllDeclaration.source, which previously emitted a compact one-line
// `{"type":"Literal","value":"...","raw":"..."}` with no start/end.
emit_string_literal_object :: proc(s: StringLiteral, indent: int) {
	out_s("{\n")
	print_indent(indent + 1)
	out_s("\"type\": \"Literal\",\n")
	print_indent(indent + 1)
	emit_span_leading(s.loc, indent + 1)
	out_s("\"value\": ")
	out_string(s.value)
	out_s(",\n")
	print_indent(indent + 1)
	out_s("\"raw\": ")
	out_string(s.raw)
	out_s("\n")
	print_indent(indent)
	out_s("}")
}

// out_u32 writes an unsigned 32-bit integer to the output, fast-pathing through
// the direct buffer to avoid `strings.Builder` allocation in out_printf. Used
// on every single emitted node for start/end offsets — millions of calls on a
// large file — so the allocation-free path is worth the ~40 lines.
out_u32 :: #force_inline proc(n: u32) {
	if use_direct_buf {
		direct_reserve(10) // u32 max is 4,294,967,295 — 10 digits
		if n == 0 {
			direct_buf[direct_pos] = '0'
			direct_pos += 1
			return
		}
		v := n
		buf: [10]byte
		i := 0
		for v > 0 {
			buf[i] = byte('0' + v % 10)
			v /= 10
			i += 1
		}
		// buf holds digits in reverse; flip into direct_buf.
		for j := i - 1; j >= 0; j -= 1 {
			direct_buf[direct_pos] = buf[j]
			direct_pos += 1
		}
	} else {
		out_printf("%d", n)
	}
}

// emit_span_fields writes `,\n<indent>"start": N,\n<indent>"end": N` — a
// LEADING comma (no trailing one), designed to slot between the `"type": "X"`
// line and whatever the case emits next (which still starts with its own
// `,\n<indent>"field": ...`). This is the one-call-per-node invariant that
// closes the ESTree position-info drift uniformly.
//
// Accepts loc by value (16B) rather than by pointer so there's no risk of
// accidental mutation. Hot path: inlined. Invariant: start <= end (asserted;
// an inverted span is a parser bug and we'd rather crash than emit nonsense).
emit_span_fields :: #force_inline proc(loc: Loc, indent: int) {
	assert(loc.span.start <= loc.span.end)
	out_s(",\n")
	print_indent(indent)
	out_s("\"start\": ")
	out_u32(loc.span.start)
	out_s(",\n")
	print_indent(indent)
	out_s("\"end\": ")
	out_u32(loc.span.end)
}

// emit_span_leading writes `"start": N,\n<indent>"end": N,\n<indent>` — a
// TRAILING comma, used when the caller has JUST printed `"type": "X",\n` +
// print_indent(indent). Convenient for inline emitters (SwitchCase, Property,
// ImportSpecifier, CatchClause, Directive, etc.) that don't use `emit_span_fields`'s
// leading-comma pattern.
emit_span_leading :: #force_inline proc(loc: Loc, indent: int) {
	assert(loc.span.start <= loc.span.end)
	out_s("\"start\": ")
	out_u32(loc.span.start)
	out_s(",\n")
	print_indent(indent)
	out_s("\"end\": ")
	out_u32(loc.span.end)
	out_s(",\n")
	print_indent(indent)
}

// get_statement_loc / get_expression_loc / get_declaration_loc / get_pattern_loc
// extract the `loc: Loc` header that every AST struct shares as its first field.
// Returned by value; zero-allocation. Used by the top-level print_*_ast procs to
// emit start/end without threading a loc argument through every variant's case.
get_statement_loc :: proc(stmt: ^Statement) -> Loc {
	if stmt == nil { return Loc{} }
	#partial switch s in stmt^ {
	case ^ExpressionStatement:      return s.loc
	case ^EmptyStatement:            return s.loc
	case ^BlockStatement:            return s.loc
	case ^DebuggerStatement:         return s.loc
	case ^ReturnStatement:           return s.loc
	case ^BreakStatement:            return s.loc
	case ^ContinueStatement:         return s.loc
	case ^LabeledStatement:          return s.loc
	case ^IfStatement:                return s.loc
	case ^SwitchStatement:           return s.loc
	case ^WhileStatement:            return s.loc
	case ^DoWhileStatement:          return s.loc
	case ^ForStatement:              return s.loc
	case ^ForInStatement:            return s.loc
	case ^ForOfStatement:            return s.loc
	case ^WithStatement:             return s.loc
	case ^ThrowStatement:            return s.loc
	case ^TryStatement:              return s.loc
	case ^FunctionDeclaration:       return s.loc
	case ^VariableDeclaration:       return s.loc
	case ^ClassDeclaration:          return s.loc
	case ^ImportDeclaration:         return s.loc
	case ^ExportNamedDeclaration:    return s.loc
	case ^ExportDefaultDeclaration:  return s.loc
	case ^ExportAllDeclaration:      return s.loc
	}
	return Loc{}
}

get_expression_loc :: proc(expr: ^Expression) -> Loc {
	if expr == nil { return Loc{} }
	#partial switch e in expr^ {
	case ^NullLiteral:              return e.loc
	case ^BooleanLiteral:           return e.loc
	case ^NumericLiteral:           return e.loc
	case ^StringLiteral:            return e.loc
	case ^BigIntLiteral:            return e.loc
	case ^RegExpLiteral:            return e.loc
	case ^TemplateLiteral:          return e.loc
	case ^TaggedTemplateExpression: return e.loc
	case ^Identifier:                return e.loc
	case ^ThisExpression:            return e.loc
	case ^Super:                     return e.loc
	case ^ArrayExpression:           return e.loc
	case ^ObjectExpression:          return e.loc
	case ^FunctionExpression:        return e.loc
	case ^ArrowFunctionExpression:   return e.loc
	case ^ClassExpression:           return e.loc
	case ^MemberExpression:          return e.loc
	case ^CallExpression:            return e.loc
	case ^NewExpression:             return e.loc
	case ^ConditionalExpression:     return e.loc
	case ^UpdateExpression:          return e.loc
	case ^UnaryExpression:           return e.loc
	case ^BinaryExpression:          return e.loc
	case ^LogicalExpression:         return e.loc
	case ^AssignmentExpression:      return e.loc
	case ^SequenceExpression:        return e.loc
	case ^SpreadElement:             return e.loc
	case ^YieldExpression:           return e.loc
	case ^AwaitExpression:           return e.loc
	case ^ImportExpression:          return e.loc
	case ^MetaProperty:              return e.loc
	case ^PrivateIdentifier:         return e.loc
	}
	return Loc{}
}

get_declaration_loc :: proc(decl: ^Declaration) -> Loc {
	if decl == nil { return Loc{} }
	#partial switch d in decl^ {
	case ^FunctionDeclaration:       return d.loc
	case ^VariableDeclaration:       return d.loc
	case ^ClassDeclaration:          return d.loc
	case ^ImportDeclaration:         return d.loc
	case ^ExportNamedDeclaration:    return d.loc
	case ^ExportDefaultDeclaration:  return d.loc
	case ^ExportAllDeclaration:      return d.loc
	}
	return Loc{}
}

get_pattern_loc :: proc(pattern: Pattern) -> Loc {
	#partial switch p in pattern {
	case ^Identifier:         return p.loc
	case ^ObjectPattern:       return p.loc
	case ^ArrayPattern:        return p.loc
	case ^AssignmentPattern:   return p.loc
	case ^RestElement:         return p.loc
	case ^MemberExpression:    return p.loc
	}
	return Loc{}
}

// Emit a BlockStatement body as inline JSON fields ("type" + "body" array).
// Walks `block.body` via print_statement_ast on each inner statement, producing
// a valid ESTree BlockStatement shape. Used wherever the AST holds a
// BlockStatement by value (TryStatement.block, TryStatement.finalizer,
// CatchClause.body) rather than through a ^Statement union — casting to
// ^Statement would re-interpret the BlockStatement bytes as a union header
// and corrupt output (same UB class as Bug H).
print_block_statement_inline :: proc(block: ^BlockStatement, indent: int) {
	print_indent(indent)
	out_s("\"type\": \"BlockStatement\",\n")
	print_indent(indent)
	emit_span_leading(block.loc, indent)
	out_s("\"body\": [\n")
	for inner_stmt, i in block.body {
		print_indent(indent + 1)
		out_s("{\n")
		print_statement_ast(inner_stmt, indent + 2)
		print_indent(indent + 1)
		if i < len(block.body) - 1 {
			out_s("},\n")
		} else {
			out_s("}\n")
		}
	}
	print_indent(indent)
	out_s("]")
}

// Emit a FunctionBody as inline BlockStatement. FunctionBody differs from
// BlockStatement by carrying directives; we flatten the directives into the
// body array as expression statements the same way OXC does, which keeps
// the ESTree shape uniform for consumers.
print_function_body_inline :: proc(body: ^FunctionBody, indent: int) {
	print_indent(indent)
	out_s("\"type\": \"BlockStatement\",\n")
	print_indent(indent)
	emit_span_leading(body.loc, indent)
	out_s("\"body\": [\n")
	total := len(body.directives) + len(body.body)
	emitted := 0
	for dir, i in body.directives {
		print_indent(indent + 1)
		out_s("{\n")
		print_indent(indent + 2)
		out_s("\"type\": \"ExpressionStatement\",\n")
		print_indent(indent + 2)
		emit_span_leading(dir.loc, indent + 2)
		out_s("\"expression\": {\n")
		print_indent(indent + 3)
		out_s("\"type\": \"Literal\",\n")
		print_indent(indent + 3)
		emit_span_leading(dir.value.loc, indent + 3)
		out_s("\"value\": ")
		out_string(dir.value.value)
		out_s(",\n")
		print_indent(indent + 3)
		out_s("\"raw\": ")
		out_string(dir.value.raw)
		out_s("\n")
		print_indent(indent + 2)
		out_s("},\n")
		print_indent(indent + 2)
		out_s("\"directive\": ")
		out_string(dir.raw)
		out_s("\n")
		print_indent(indent + 1)
		emitted += 1
		if emitted < total { out_s("},\n") } else { out_s("}\n") }
		_ = i
	}
	for inner_stmt, i in body.body {
		print_indent(indent + 1)
		out_s("{\n")
		print_statement_ast(inner_stmt, indent + 2)
		print_indent(indent + 1)
		emitted += 1
		if emitted < total { out_s("},\n") } else { out_s("}\n") }
		_ = i
	}
	print_indent(indent)
	out_s("]")
}

// print_declaration_ast emits a ^Declaration by rebuilding a ^Statement whose
// union tag matches the inner variant. The previous `(^Statement)(decl)` cast
// preserved the pointer address but kept the ^Declaration tag ordinal — which
// disagrees with the ^Statement tag ordinal for the same variant, since
// Declaration has 7 variants and Statement has 25 (different ordinal
// positions). That made `print_statement_ast` dispatch on the wrong case:
// e.g. a VariableDeclaration (^Declaration tag 1) was read as a
// BlockStatement (^Statement tag 2), corrupting the whole subtree walk.
//
// Symptom: SIGSEGV inside `get_statement_type_name`'s type-switch when
// classes containing exported declarations were emitted (tone.js, mathjax.js,
// marked.js, etc.).
//
// Reassigning `stmt = d` (where d is the typed inner pointer) lets Odin
// compute the correct ^Statement tag at assignment time. This is the safe
// idiom for “convert between union types that share a variant”.
print_declaration_ast :: proc(decl: ^Declaration, indent: int) {
	if decl == nil { return }
	stmt: Statement
	#partial switch d in decl^ {
	case ^FunctionDeclaration:       stmt = d
	case ^VariableDeclaration:       stmt = d
	case ^ClassDeclaration:           stmt = d
	case ^ImportDeclaration:          stmt = d
	case ^ExportNamedDeclaration:     stmt = d
	case ^ExportDefaultDeclaration:   stmt = d
	case ^ExportAllDeclaration:       stmt = d
	case:
		// Unknown Declaration variant: emit a safe placeholder so the JSON
		// stays well-formed rather than silently skipping.
		print_indent(indent)
		out_s("\"type\": \"Unknown\"")
		return
	}
	print_statement_ast(&stmt, indent)
}

// print_variable_declaration_body emits the VariableDeclaration body fields
// (kind, declarations) starting with `,` — the caller has already written
// `"type": "VariableDeclaration"` and is positioned to continue the object.
//
// Extracted so for-in / for-of emit can reuse it on a ^VariableDeclaration
// directly, rather than casting the ^VariableDeclaration back through a
// fake ^Statement (which was UB: the cast would treat the VariableDeclaration
// struct as a Statement union header and dispatch on garbage bytes).
print_variable_declaration_body :: proc(s: ^VariableDeclaration, indent: int) {
	kind_str := "var"
	#partial switch s.kind {
	case .Let:   kind_str = "let"
	case .Const: kind_str = "const"
	}
	out_s(",\n")
	print_indent(indent)
	out_s("\"kind\": \"")
	out_s(kind_str)
	out_s("\",\n")
	print_indent(indent)
	out_s("\"declarations\": [\n")
	for decl, i in s.declarations {
		print_indent(indent + 1)
		out_s("{\n")
		print_indent(indent + 2)
		out_s("\"type\": \"VariableDeclarator\",\n")
		print_indent(indent + 2)
		emit_span_leading(decl.loc, indent + 2)
		out_s("\"id\": {\n")
		print_pattern_ast(decl.id, indent + 3)
		print_indent(indent + 2)
		out_s("},\n")
		print_indent(indent + 2)
		out_s("\"init\": ")
		if init, ok := decl.init.(^Expression); ok {
			out_s("{\n")
			print_expression_ast(init, indent + 3)
			print_indent(indent + 2)
			out_s("}")
		} else {
			out_s("null")
		}
		print_indent(indent + 1)
		if i < len(s.declarations) - 1 {
			out_s("},\n")
		} else {
			out_s("}\n")
		}
	}
	print_indent(indent)
	out_s("]")
}

// print_class_body_inline emits the inside of the `"body": { ... }` payload
// for ClassDeclaration and ClassExpression. The caller has already written
// the opening `{` and must emit the matching `}`. Shape:
//     "type": "ClassBody",
//     "body": [ <class_element>, ... ]
//
// Previously this path emitted an empty `[]` stub regardless of actual body
// contents, rendering strings/expressions inside class methods invisible to
// the JSON emitter (raw-transfer buffer had them correctly). See P1 in the
// HANDOFF for context.
print_class_body_inline :: proc(body: ^ClassBody, indent: int) {
	print_indent(indent)
	out_s("\"type\": \"ClassBody\",\n")
	print_indent(indent)
	emit_span_leading(body.loc, indent)
	if len(body.body) == 0 {
		out_s("\"body\": []\n")
		return
	}
	out_s("\"body\": [\n")
	for i in 0 ..< len(body.body) {
		elem := &body.body[i]
		print_indent(indent + 1)
		out_s("{\n")
		print_class_element_fields(elem, indent + 2)
		print_indent(indent + 1)
		if i < len(body.body) - 1 {
			out_s("},\n")
		} else {
			out_s("}\n")
		}
	}
	print_indent(indent)
	out_s("]\n")
}

// print_class_element_fields emits the fields of a single class element
// inside an already-opened `{`. The ESTree node type depends on the
// element's kind and the shape of its value:
//
//   * .StaticBlock                                 → "StaticBlock" (body only)
//   * .Constructor / .Get / .Set                   → "MethodDefinition"
//   * .Method with a FunctionExpression value      → "MethodDefinition"
//   * .Method with a non-function (or nil) value   → "PropertyDefinition"
//     (class field; `value` may be null)
//
// Known edge case: `field = function() {}` (a class field whose initializer
// is a non-arrow function expression) cannot be distinguished from a method
// by the current AST representation alone — the parser reuses .Method for
// fields. We accept the rare misclassification rather than bolt a
// parser-side kind field on in this pass. Arrow-valued fields
// (`field = () => ...`) are ArrowFunctionExpression, not
// FunctionExpression, so they take the PropertyDefinition path correctly.
print_class_element_fields :: proc(elem: ^ClassElement, indent: int) {
	// Unwrap Maybe(^Expression) once. value_expr is nil if the element has
	// no initializer (bare `x;` field) or if disambiguation failed.
	value_expr: ^Expression = nil
	value_is_function := false
	if v, ok := elem.value.(^Expression); ok && v != nil {
		value_expr = v
		#partial switch _ in v^ {
		case ^FunctionExpression:
			value_is_function = true
		}
	}

	// StaticBlock has a dedicated shape: only `body: [Statement]`. The
	// parser stashes its statements inside a FunctionExpression.body.body
	// (see parse_static_block), so we unwrap that container here.
	if elem.kind == .StaticBlock {
		print_class_element_static_block(value_expr, indent, elem.loc)
		return
	}

	is_method := value_is_function
	#partial switch elem.kind {
	case .Constructor, .Get, .Set:
		is_method = true
	}

	type_name := is_method ? "MethodDefinition" : "PropertyDefinition"
	print_indent(indent)
	out_s("\"type\": \"")
	out_s(type_name)
	out_s("\",\n")
	print_indent(indent)
	emit_span_leading(elem.loc, indent)

	// key: ^Expression. MethodDefinition and PropertyDefinition both carry
	// a non-null key (Identifier, PrivateIdentifier, Literal, or an
	// expression when `computed` is true).
	print_indent(indent)
	if elem.key != nil {
		out_s("\"key\": {\n")
		print_expression_ast(elem.key, indent + 1)
		out_s("\n")
		print_indent(indent)
		out_s("},\n")
	} else {
		out_s("\"key\": null,\n")
	}

	// value: Maybe(^Expression). null for uninitialised fields (`x;`).
	print_indent(indent)
	if value_expr != nil {
		out_s("\"value\": {\n")
		print_expression_ast(value_expr, indent + 1)
		out_s("\n")
		print_indent(indent)
		out_s("},\n")
	} else {
		out_s("\"value\": null,\n")
	}

	// kind is MethodDefinition-only per ESTree. PropertyDefinition has no
	// kind field — OXC confirms.
	if is_method {
		kind_str := "method"
		#partial switch elem.kind {
		case .Constructor:
			kind_str = "constructor"
		case .Get:
			kind_str = "get"
		case .Set:
			kind_str = "set"
		}
		print_indent(indent)
		out_s("\"kind\": \"")
		out_s(kind_str)
		out_s("\",\n")
	}

	print_indent(indent)
	out_s("\"computed\": ")
	out_bool(elem.computed)
	out_s(",\n")

	print_indent(indent)
	out_s("\"static\": ")
	out_bool(elem.static)
	out_s("\n")
}

// print_class_element_static_block emits a StaticBlock class element. The
// parser wraps the block's statement list inside a FunctionExpression.body
// (see parse_static_block in src/parser.odin); we unwrap that one level so
// the JSON matches OXC's `{"type":"StaticBlock","body":[<stmt>,...]}`.
print_class_element_static_block :: proc(value_expr: ^Expression, indent: int, static_loc: Loc) {
	print_indent(indent)
	out_s("\"type\": \"StaticBlock\",\n")
	print_indent(indent)
	emit_span_leading(static_loc, indent)

	stmts: ^[dynamic]^Statement = nil
	if value_expr != nil {
		#partial switch fe in value_expr^ {
		case ^FunctionExpression:
			stmts = &fe.body.body
		}
	}

	print_indent(indent)
	if stmts == nil || len(stmts^) == 0 {
		out_s("\"body\": []\n")
		return
	}
	out_s("\"body\": [\n")
	for j in 0 ..< len(stmts^) {
		print_indent(indent + 1)
		out_s("{\n")
		print_statement_ast(stmts[j], indent + 2)
		print_indent(indent + 1)
		if j < len(stmts^) - 1 {
			out_s("},\n")
		} else {
			out_s("}\n")
		}
	}
	print_indent(indent)
	out_s("]\n")
}

print_statement_ast :: proc(stmt: ^Statement, indent: int) {
	print_indent(indent)
	out_s("\"type\": \"")
	out_s(get_statement_type_name(stmt))
	out_s("\"")
	emit_span_fields(get_statement_loc(stmt), indent)

	#partial switch s in stmt^ {
	case ^ExpressionStatement:
		out_s(",\n")
		print_indent(indent)
		out_s("\"expression\": {\n")
		print_expression_ast(s.expression, indent + 1)
		print_indent(indent)
		out_s("}")

	case ^VariableDeclaration:
		print_variable_declaration_body(s, indent)

	case ^FunctionDeclaration:
		out_s(",\n")
		print_indent(indent)
		out_s("\"id\": {\n")
		if id, ok := s.expr.id.(BindingIdentifier); ok {
			print_indent(indent + 1)
			out_s("\"type\": \"Identifier\",\n")
			print_indent(indent + 1)
			emit_span_leading(id.loc, indent + 1)
			out_s("\"name\": ")
			out_string(id.name)
			out_s("\n")
		}
		print_indent(indent)
		out_s("},\n")
		print_indent(indent)
		out_s("\"generator\": ")
		out_bool(s.expr.generator)
		out_s(",\n")
		print_indent(indent)
		out_s("\"async\": ")
		out_bool(s.expr.async)
		out_s(",\n")
		print_indent(indent)
		out_s("\"params\": [")
		if len(s.expr.params) == 0 {
			out_s("]")
		} else {
			out_s("\n")
			for param, i in s.expr.params {
				print_indent(indent + 1)
				out_s("{\n")
				print_pattern_ast(param.pattern, indent + 2)
				out_s("\n")
				print_indent(indent + 1)
				if i < len(s.expr.params) - 1 { out_s("},\n") } else { out_s("}\n") }
			}
			print_indent(indent)
			out_s("]")
		}
		out_s(",\n")
		print_indent(indent)
		out_println("\"body\": {")
		fn_body := &s.expr.body
		print_function_body_inline(fn_body, indent + 1)
		out_s("\n")
		print_indent(indent)
		out_print("}")

	case ^BlockStatement:
		out_s(",\n")
		print_indent(indent)
		out_s("\"body\": [\n")
		for inner_stmt, i in s.body {
			print_indent(indent + 1)
			out_s("{\n")
			print_statement_ast(inner_stmt, indent + 2)
			print_indent(indent + 1)
			if i < len(s.body) - 1 {
				out_s("},\n")
			} else {
				out_s("}\n")
			}
		}
		print_indent(indent)
		out_s("]")

	case ^ReturnStatement:
		out_s(",\n")
		print_indent(indent)
		out_s("\"argument\": ")
		if arg, ok := s.argument.(^Expression); ok {
			out_s("{\n")
			print_expression_ast(arg, indent + 1)
			print_indent(indent)
			out_s("}")
		} else {
			out_s("null")
		}

	case ^IfStatement:
		out_s(",\n")
		print_indent(indent)
		out_s("\"test\": {\n")
		print_expression_ast(s.test, indent + 1)
		print_indent(indent)
		out_s("},\n")
		print_indent(indent)
		out_s("\"consequent\": {\n")
		print_statement_ast(s.consequent, indent + 1)
		print_indent(indent)
		out_s("},\n")
		print_indent(indent)
		out_s("\"alternate\": ")
		if alt, ok := s.alternate.(^Statement); ok {
			out_s("{\n")
			print_statement_ast(alt, indent + 1)
			print_indent(indent)
			out_s("}")
		} else {
			out_s("null")
		}

	case ^WhileStatement:
		out_println(",")
		print_indent(indent)
		out_println("\"test\": {")
		print_expression_ast(s.test, indent + 1)
		print_indent(indent)
		out_println("},")
		print_indent(indent)
		out_println("\"body\": {")
		print_statement_ast(s.body, indent + 1)
		print_indent(indent)
		out_print("}")

	case ^ForStatement:
		out_println(",")
		print_indent(indent)
		out_print("\"init\": ")
		if decl, ok := s.init_decl.(^VariableDeclaration); ok {
			// Do NOT cast ^VariableDeclaration to ^Statement — that was UB of the
			// same class as Bug H: the VariableDeclaration struct bytes would be
			// read as if they were a Statement union header, corrupting dispatch.
			// Symptom: SIGSEGV deep inside class methods containing
			// `for (let x = 0; ...; ...)` loops (e.g. tone.js, mathjax.js, etc.).
			out_println("{")
			print_indent(indent + 1)
			out_s("\"type\": \"VariableDeclaration\"")
			emit_span_fields(decl.loc, indent + 1)
			print_variable_declaration_body(decl, indent + 1)
			out_s("\n")
			print_indent(indent)
			out_println("},")
		} else if expr, ok := s.init_expr.(^Expression); ok {
			out_println("{")
			print_expression_ast(expr, indent + 1)
			print_indent(indent)
			out_println("},")
		} else {
			out_println("null,")
		}
		print_indent(indent)
		out_print("\"test\": ")
		if test_expr, ok := s.test.(^Expression); ok {
			out_println("{")
			print_expression_ast(test_expr, indent + 1)
			print_indent(indent)
			out_println("},")
		} else {
			out_println("null,")
		}
		print_indent(indent)
		out_print("\"update\": ")
		if upd_expr, ok := s.update.(^Expression); ok {
			out_println("{")
			print_expression_ast(upd_expr, indent + 1)
			print_indent(indent)
			out_println("},")
		} else {
			out_println("null,")
		}
		print_indent(indent)
		out_println("\"body\": {")
		print_statement_ast(s.body, indent + 1)
		print_indent(indent)
		out_print("}")

	case ^ClassDeclaration:
		out_println(",")
		print_indent(indent)
		out_print("\"id\": ")
		if id, ok := s.id.(BindingIdentifier); ok {
			out_s("{\n")
			print_indent(indent + 1)
			out_s("\"type\": \"Identifier\",\n")
			print_indent(indent + 1)
			emit_span_leading(id.loc, indent + 1)
			out_s("\"name\": ")
			out_string(id.name)
			out_s("\n")
			print_indent(indent)
			out_s("},\n")
		} else {
			out_s("null,\n")
		}
		print_indent(indent)
		out_print("\"superClass\": ")
		if super, ok := s.super_class.(^Expression); ok && super != nil {
			out_println("{")
			print_expression_ast(super, indent + 1)
			print_indent(indent)
			out_println("},")
		} else {
			out_println("null,")
		}
		print_indent(indent)
		out_println("\"body\": {")
		print_class_body_inline(&s.body, indent + 1)
		print_indent(indent)
		out_print("}")

	case ^TryStatement:
		out_println(",")
		print_indent(indent)
		out_println("\"block\": {")
		block := &s.block
		print_block_statement_inline(block, indent + 1)
		out_s("\n")
		print_indent(indent)
		out_println("},")
		print_indent(indent)
		out_print("\"handler\": ")
		if handler, ok := s.handler.(CatchClause); ok {
			out_println("{")
			print_indent(indent + 1)
			out_println("\"type\": \"CatchClause\",")
			print_indent(indent + 1)
			emit_span_leading(handler.loc, indent + 1)
			out_print("\"param\": ")
			if param, ok2 := handler.param.(Pattern); ok2 {
				out_println("{")
				print_pattern_ast(param, indent + 2)
				print_indent(indent + 1)
				out_println("},")
			} else {
				out_println("null,")
			}
			print_indent(indent + 1)
			out_println("\"body\": {")
			body := handler.body
			print_block_statement_inline(&body, indent + 2)
			out_s("\n")
			print_indent(indent + 1)
			out_println("}")
			print_indent(indent)
			out_println("},")
		} else {
			out_println("null,")
		}
		print_indent(indent)
		out_print("\"finalizer\": ")
		if fin, ok := s.finalizer.(BlockStatement); ok {
			out_println("{")
			print_block_statement_inline(&fin, indent + 1)
			out_s("\n")
			print_indent(indent)
			out_print("}")
		} else {
			out_print("null")
		}

	case ^ExportNamedDeclaration:
		out_println(",")
		print_indent(indent)
		out_print("\"declaration\": ")
		if decl, ok := s.declaration.(^Declaration); ok && decl != nil {
			out_println("{")
			print_declaration_ast(decl, indent + 1)
			print_indent(indent)
			out_println("},")
		} else {
			out_println("null,")
		}
		print_indent(indent)
		out_s("\"specifiers\": [")
		if len(s.specifiers) == 0 {
			out_s("],\n")
		} else {
			out_s("\n")
			for spec, i in s.specifiers {
				print_indent(indent + 1)
				out_s("{\n")
				print_indent(indent + 2)
				out_s("\"type\": \"ExportSpecifier\",\n")
				print_indent(indent + 2)
				emit_span_leading(spec.loc, indent + 2)
				out_s("\"local\": ")
				emit_identifier_name_object(spec.local, indent + 2)
				out_s(",\n")
				print_indent(indent + 2)
				out_s("\"exported\": ")
				emit_identifier_name_object(spec.exported, indent + 2)
				out_s("\n")
				print_indent(indent + 1)
				if i < len(s.specifiers) - 1 { out_s("},\n") } else { out_s("}\n") }
			}
			print_indent(indent)
			out_s("],\n")
		}
		print_indent(indent)
		out_s("\"source\": ")
		if src, ok := s.source.(StringLiteral); ok {
			out_s("{ \"type\": \"Literal\", \"value\": ")
			out_string(src.value)
			out_s(", \"raw\": ")
			out_string(src.raw)
			out_s(" }")
		} else {
			out_s("null")
		}

	case ^ExportDefaultDeclaration:
		out_println(",")
		print_indent(indent)
		out_s("\"declaration\": ")
		if def := s.declaration; def != nil {
			out_s("{\n")
			switch kind in def^ {
			case ^Declaration:
				if kind != nil {
					print_declaration_ast(kind, indent + 1)
				}
			case ^Expression:
				if kind != nil {
					print_expression_ast(kind, indent + 1)
				}
			}
			print_indent(indent)
			out_s("}")
		} else {
			out_s("null")
		}

	case ^ExportAllDeclaration:
		out_println(",")
		print_indent(indent)
		out_println("\"source\": {")
		print_indent(indent + 1)
		out_s("\"type\": \"Literal\",\n")
		print_indent(indent + 1)
		emit_span_leading(s.source.loc, indent + 1)
		out_s("\"value\": ")
		out_string(s.source.value)
		out_s(",\n")
		print_indent(indent + 1)
		out_s("\"raw\": ")
		out_string(s.source.raw)
		out_s("\n")
		print_indent(indent)
		out_print("}")

	case ^DoWhileStatement:
		out_println(",")
		print_indent(indent)
		out_println("\"body\": {")
		print_statement_ast(s.body, indent + 1)
		print_indent(indent)
		out_println("},")
		print_indent(indent)
		out_println("\"test\": {")
		print_expression_ast(s.test, indent + 1)
		print_indent(indent)
		out_print("}")

	case ^SwitchStatement:
		out_println(",")
		print_indent(indent)
		out_println("\"discriminant\": {")
		print_expression_ast(s.discriminant, indent + 1)
		print_indent(indent)
		out_println("},")
		print_indent(indent)
		out_s("\"cases\": [")
		if len(s.cases) == 0 {
			out_s("]")
		} else {
			out_s("\n")
			for c, i in s.cases {
				print_indent(indent + 1)
				out_s("{\n")
				print_indent(indent + 2)
				out_s("\"type\": \"SwitchCase\",\n")
				print_indent(indent + 2)
				emit_span_leading(c.loc, indent + 2)
				out_s("\"test\": ")
				if test_expr, ok := c.test.(^Expression); ok && test_expr != nil {
					out_s("{\n")
					print_expression_ast(test_expr, indent + 3)
					print_indent(indent + 2)
					out_s("},\n")
				} else {
					out_s("null,\n")
				}
				print_indent(indent + 2)
				out_s("\"consequent\": [")
				if len(c.consequent) == 0 {
					out_s("]\n")
				} else {
					out_s("\n")
					for cs, j in c.consequent {
						print_indent(indent + 3)
						out_s("{\n")
						print_statement_ast(cs, indent + 4)
						print_indent(indent + 3)
						if j < len(c.consequent) - 1 { out_s("},\n") } else { out_s("}\n") }
					}
					print_indent(indent + 2)
					out_s("]\n")
				}
				print_indent(indent + 1)
				if i < len(s.cases) - 1 { out_s("},\n") } else { out_s("}\n") }
			}
			print_indent(indent)
			out_s("]")
		}

	case ^ForInStatement:
		out_println(",")
		print_indent(indent)
		out_print("\"left\": ")
		if decl, ok := s.left_decl.(^VariableDeclaration); ok {
			out_println("{")
			print_indent(indent + 1)
			out_s("\"type\": \"VariableDeclaration\"")
			emit_span_fields(decl.loc, indent + 1)
			print_variable_declaration_body(decl, indent + 1)
			out_s("\n")
			print_indent(indent)
			out_println("},")
		} else if expr, ok := s.left_expr.(^Expression); ok {
			out_println("{")
			print_expression_ast(expr, indent + 1)
			print_indent(indent)
			out_println("},")
		} else {
			out_println("null,")
		}
		print_indent(indent)
		out_println("\"right\": {")
		print_expression_ast(s.right, indent + 1)
		print_indent(indent)
		out_println("},")
		print_indent(indent)
		out_println("\"body\": {")
		print_statement_ast(s.body, indent + 1)
		print_indent(indent)
		out_print("}")

	case ^ForOfStatement:
		out_println(",")
		print_indent(indent)
		out_print("\"left\": ")
		if decl, ok := s.left_decl.(^VariableDeclaration); ok {
			out_println("{")
			print_indent(indent + 1)
			out_s("\"type\": \"VariableDeclaration\"")
			emit_span_fields(decl.loc, indent + 1)
			print_variable_declaration_body(decl, indent + 1)
			out_s("\n")
			print_indent(indent)
			out_println("},")
		} else if expr, ok := s.left_expr.(^Expression); ok {
			out_println("{")
			print_expression_ast(expr, indent + 1)
			print_indent(indent)
			out_println("},")
		} else {
			out_println("null,")
		}
		print_indent(indent)
		out_println("\"right\": {")
		print_expression_ast(s.right, indent + 1)
		print_indent(indent)
		out_println("},")
		print_indent(indent)
		out_print("\"await\": ")
		if s.await {
			out_println("true,")
		} else {
			out_println("false,")
		}
		print_indent(indent)
		out_println("\"body\": {")
		print_statement_ast(s.body, indent + 1)
		print_indent(indent)
		out_print("}")
		// (pre-refactor dead code that emitted a second "await"/"body" pair
		// has been removed; it was unreachable after the body emit above.)

	case ^ThrowStatement:
		out_println(",")
		print_indent(indent)
		out_println("\"argument\": {")
		print_expression_ast(s.argument, indent + 1)
		print_indent(indent)
		out_print("}")

	case ^ImportDeclaration:
		out_println(",")
		print_indent(indent)
		out_s("\"specifiers\": [")
		if len(s.specifiers) == 0 {
			out_s("],\n")
		} else {
			out_s("\n")
			for spec_ptr, i in s.specifiers {
				print_indent(indent + 1)
				out_s("{\n")
				if spec_ptr != nil {
					switch v in spec_ptr^ {
					case ImportSpecifier:
						print_indent(indent + 2)
						out_s("\"type\": \"ImportSpecifier\",\n")
						print_indent(indent + 2)
						emit_span_leading(v.loc, indent + 2)
						out_s("\"local\": ")
						emit_binding_identifier_object(v.local, indent + 2)
						out_s(",\n")
						print_indent(indent + 2)
						out_s("\"imported\": ")
						emit_identifier_name_object(v.imported, indent + 2)
						out_s("\n")
					case ImportDefaultSpecifier:
						print_indent(indent + 2)
						out_s("\"type\": \"ImportDefaultSpecifier\",\n")
						print_indent(indent + 2)
						emit_span_leading(v.loc, indent + 2)
						out_s("\"local\": ")
						emit_binding_identifier_object(v.local, indent + 2)
						out_s("\n")
					case ImportNamespaceSpecifier:
						print_indent(indent + 2)
						out_s("\"type\": \"ImportNamespaceSpecifier\",\n")
						print_indent(indent + 2)
						emit_span_leading(v.loc, indent + 2)
						out_s("\"local\": ")
						emit_binding_identifier_object(v.local, indent + 2)
						out_s("\n")
					}
				}
				print_indent(indent + 1)
				if i < len(s.specifiers) - 1 { out_s("},\n") } else { out_s("}\n") }
			}
			print_indent(indent)
			out_s("],\n")
		}
		print_indent(indent)
		out_s("\"source\": ")
		emit_string_literal_object(s.source, indent)

	case ^BreakStatement:
		out_println(",")
		print_indent(indent)
		out_print("\"label\": null")

	case ^ContinueStatement:
		out_println(",")
		print_indent(indent)
		out_print("\"label\": null")

	case ^LabeledStatement:
		out_println(",")
		print_indent(indent)
		out_println("\"label\": {")
		print_indent(indent + 1)
		out_s("\"type\": \"Identifier\",\n")
		print_indent(indent + 1)
		emit_span_leading(s.label.loc, indent + 1)
		out_s("\"name\": ")
		out_string(s.label.name)
		out_s("\n")
		print_indent(indent)
		out_println("},")
		print_indent(indent)
		out_println("\"body\": {")
		print_statement_ast(s.body, indent + 1)
		print_indent(indent)
		out_print("}")

	case ^WithStatement:
		out_println(",")
		print_indent(indent)
		out_println("\"object\": {")
		print_expression_ast(s.object, indent + 1)
		print_indent(indent)
		out_println("},")
		print_indent(indent)
		out_println("\"body\": {")
		print_statement_ast(s.body, indent + 1)
		print_indent(indent)
		out_print("}")

	case ^EmptyStatement:
		// No additional fields

	case ^DebuggerStatement:
		// No additional fields

	case:
		out_s(",\n")
		print_indent(indent)
		out_s("\"[UNIMPLEMENTED]\": true")
	}
}

print_pattern_ast :: proc(pattern: Pattern, indent: int) {
	// MemberExpression delegates to print_expression_ast which has its own
	// span emission; every other pattern variant emits type + span here.
	#partial switch p in pattern {
	case ^Identifier:
		print_indent(indent)
		out_s("\"type\": \"Identifier\",\n")
		print_indent(indent)
		emit_span_leading(p.loc, indent)
		out_s("\"name\": ")
		out_string(p.name)
	case ^RestElement:
		// ESTree `RestElement { argument: Pattern }` — the `...x` inside
		// `[a, ...x]` or `{ a, ...x }`. Prior to this case the fallthrough
		// `case:` produced bare `null`, which the ArrayPattern.elements loop
		// wrapped in `{…}` — emitting invalid `{null}` JSON.
		print_indent(indent)
		out_s("\"type\": \"RestElement\",\n")
		print_indent(indent)
		emit_span_leading(p.loc, indent)
		out_s("\"argument\": {\n")
		print_pattern_ast(p.argument, indent + 1)
		out_s("\n")
		print_indent(indent)
		out_s("}")
	case ^AssignmentPattern:
		// ESTree `AssignmentPattern { left: Pattern, right: Expression }` —
		// the `x = 1` inside `{ x = 1 }` or `[x = 1]`. Same JSON-validity
		// rationale as RestElement above.
		print_indent(indent)
		out_s("\"type\": \"AssignmentPattern\",\n")
		print_indent(indent)
		emit_span_leading(p.loc, indent)
		out_s("\"left\": {\n")
		print_pattern_ast(p.left, indent + 1)
		out_s("\n")
		print_indent(indent)
		out_s("},\n")
		print_indent(indent)
		out_s("\"right\": {\n")
		print_expression_ast(p.right, indent + 1)
		out_s("\n")
		print_indent(indent)
		out_s("}")
	case ^MemberExpression:
		// Destructuring target like `({a} = obj, foo.bar = 1)`. ESTree emits
		// the MemberExpression inline in the pattern position. Rebuild a local
		// Expression union — we can't take `&pattern` (procedure parameter), so
		// allocate on the stack.
		expr: Expression = p
		print_expression_ast(&expr, indent)
	case ^ArrayPattern:
		print_indent(indent)
		out_s("\"type\": \"ArrayPattern\",\n")
		print_indent(indent)
		emit_span_leading(p.loc, indent)
		out_s("\"elements\": [")
		if len(p.elements) == 0 {
			out_s("]")
		} else {
			out_s("\n")
			for elem, i in p.elements {
				if e, ok := elem.(Pattern); ok {
					print_indent(indent + 1)
					out_s("{\n")
					print_pattern_ast(e, indent + 2)
					out_s("\n")
					print_indent(indent + 1)
					if i < len(p.elements) - 1 { out_s("},\n") } else { out_s("}\n") }
				} else {
					// Hole in destructuring (e.g. `[,,x]`) — ESTree emits `null`.
					print_indent(indent + 1)
					if i < len(p.elements) - 1 { out_s("null,\n") } else { out_s("null\n") }
				}
			}
			print_indent(indent)
			out_s("]")
		}
	case ^ObjectPattern:
		print_indent(indent)
		out_s("\"type\": \"ObjectPattern\",\n")
		print_indent(indent)
		emit_span_leading(p.loc, indent)
		out_s("\"properties\": [")
		if len(p.properties) == 0 {
			out_s("]")
		} else {
			out_s("\n")
			for prop, i in p.properties {
				// ESTree: `ObjectPattern.properties` is a heterogeneous list of
				// `Property` OR `RestElement`. Our parser stashes the rest element
				// as an `ObjectPatternProperty { key: nil, value: ^RestElement }`
				// because it reuses the same struct — but the emit must unwrap
				// it: emit a bare `RestElement`, NOT a `Property` wrapper with a
				// `RestElement` value. Detected by the prop.key being nil.
				if _, is_rest := prop.value.(^RestElement); is_rest {
					print_indent(indent + 1)
					out_s("{\n")
					print_pattern_ast(prop.value, indent + 2)
					out_s("\n")
					print_indent(indent + 1)
					if i < len(p.properties) - 1 { out_s("},\n") } else { out_s("}\n") }
					continue
				}
				print_indent(indent + 1)
				out_s("{\n")
				print_indent(indent + 2)
				out_s("\"type\": \"Property\",\n")
				print_indent(indent + 2)
				emit_span_leading(prop.loc, indent + 2)
				out_s("\"shorthand\": ")
				out_bool(prop.shorthand)
				out_s(",\n")
				print_indent(indent + 2)
				out_s("\"computed\": ")
				out_bool(prop.computed)
				out_s(",\n")
				print_indent(indent + 2)
				// Every remaining Pattern variant has a real emit case in
				// print_pattern_ast now (Identifier / ArrayPattern / ObjectPattern
				// / AssignmentPattern / MemberExpression), so wrapping in `{…}`
				// is always safe.
				out_s("\"value\": {\n")
				print_pattern_ast(prop.value, indent + 3)
				out_s("\n")
				print_indent(indent + 2)
				out_s("}\n")
				print_indent(indent + 1)
				if i < len(p.properties) - 1 { out_s("},\n") } else { out_s("}\n") }
			}
			print_indent(indent)
			out_s("]")
		}
	case:
		print_indent(indent)
		out_s("null")
	}
}

print_expression_ast :: proc(expr: ^Expression, indent: int) {
	// ESTree Literal short-circuit: collapse six OXC-style literal types into one.
	// ESTree spec uses a single "Literal" node for Numeric/String/Boolean/Null/BigInt/RegExp.
	// Every branch emits start/end via emit_span_fields or emit_span_leading so
	// downstream consumers get position info uniformly.
	#partial switch e in expr^ {
	case ^NumericLiteral:
		print_indent(indent)
		out_s("\"type\": \"Literal\",\n")
		print_indent(indent)
		emit_span_leading(e.loc, indent)
		out_s("\"value\": ")
		out_printf("%v,\n", e.value)
		print_indent(indent)
		out_s("\"raw\": ")
		out_string(e.raw)
		return

	case ^StringLiteral:
		print_indent(indent)
		out_s("\"type\": \"Literal\",\n")
		print_indent(indent)
		emit_span_leading(e.loc, indent)
		out_s("\"value\": ")
		out_string(e.value)
		out_s(",\n")
		print_indent(indent)
		out_s("\"raw\": ")
		out_string(e.raw)
		return

	case ^BooleanLiteral:
		print_indent(indent)
		out_s("\"type\": \"Literal\",\n")
		print_indent(indent)
		emit_span_leading(e.loc, indent)
		out_s("\"value\": ")
		out_bool(e.value)
		out_s(",\n")
		print_indent(indent)
		out_s("\"raw\": ")
		if e.value {
			out_s("\"true\"")
		} else {
			out_s("\"false\"")
		}
		return

	case ^NullLiteral:
		print_indent(indent)
		out_s("\"type\": \"Literal\",\n")
		print_indent(indent)
		emit_span_leading(e.loc, indent)
		out_s("\"value\": null,\n")
		print_indent(indent)
		out_s("\"raw\": \"null\"")
		return

	case ^BigIntLiteral:
		print_indent(indent)
		out_s("\"type\": \"Literal\",\n")
		print_indent(indent)
		emit_span_leading(e.loc, indent)
		out_s("\"value\": ")
		out_string(e.value)
		out_s(",\n")
		print_indent(indent)
		out_s("\"raw\": ")
		out_string(e.raw)
		out_s(",\n")
		print_indent(indent)
		out_s("\"bigint\": ")
		raw_without_n := e.raw
		if len(e.raw) > 0 && e.raw[len(e.raw)-1] == 'n' {
			raw_without_n = e.raw[:len(e.raw)-1]
		}
		out_string(raw_without_n)
		return

	case ^RegExpLiteral:
		print_indent(indent)
		out_s("\"type\": \"Literal\",\n")
		print_indent(indent)
		emit_span_leading(e.loc, indent)
		out_s("\"value\": null,\n")
		print_indent(indent)
		// Splice pattern/flags inside the quoted raw to get e.g. `"/\\D/g"`.
		// A naive out_s would leave literal backslashes unescaped and break
		// downstream JSON.parse; out_string_inner escapes each chunk without
		// emitting its own surrounding quotes.
		out_s("\"raw\": \"/")
		out_string_inner(e.pattern)
		out_s("/")
		out_string_inner(e.flags)
		out_s("\",\n")
		print_indent(indent)
		out_s("\"regex\": {\n")
		print_indent(indent + 1)
		out_s("\"pattern\": ")
		out_string(e.pattern)
		out_s(",\n")
		print_indent(indent + 1)
		out_s("\"flags\": ")
		out_string(e.flags)
		out_s("\n")
		print_indent(indent)
		out_s("}")
		return
	case:
	}

	print_indent(indent)
	out_s("\"type\": \"")
	out_s(get_expression_type_name(expr))
	out_s("\"")
	emit_span_fields(get_expression_loc(expr), indent)

	#partial switch e in expr^ {
	case ^Identifier:
		out_s(",\n")
		print_indent(indent)
		out_s("\"name\": ")
		out_string(e.name)

	case ^ThisExpression:
		// No additional fields

	case ^Super:
		// No additional fields — ESTree Super is a leaf node with only `type`.
		// Previously fell through to the `case:` UNIMPLEMENTED arm, producing
		// `{"type":"Super","[UNIMPLEMENTED]":true}` — invalid JSON-drift against
		// OXC, which emits plain `{"type":"Super"}`.

	case ^ArrayExpression:
		out_s(",\n")
		print_indent(indent)
		out_s("\"elements\": [\n")
		for elem, i in e.elements {
			if el, ok := elem.(^Expression); ok {
				print_indent(indent + 1)
				out_s("{\n")
				print_expression_ast(el, indent + 2)
				print_indent(indent + 1)
				if i < len(e.elements) - 1 {
					out_s("},\n")
				} else {
					out_s("}\n")
				}
			}
		}
		print_indent(indent)
		out_s("]")

	case ^ObjectExpression:
		out_s(",\n")
		print_indent(indent)
		out_s("\"properties\": [\n")
		for prop, i in e.properties {
			print_indent(indent + 1)
			out_s("{\n")
			print_indent(indent + 2)
			kind_str := "init"
			#partial switch prop.kind {
			case .Get: kind_str = "get"
			case .Set: kind_str = "set"
			case .Method: kind_str = "method"
			}
			out_s("\"kind\": \"")
			out_s(kind_str)
			out_s("\",\n")

			// Spread properties have nil key
			if prop.key != nil {
				print_indent(indent + 2)
				out_s("\"key\": {\n")
				print_expression_ast(prop.key, indent + 3)
				print_indent(indent + 2)
				out_s("},\n")
			} else {
				print_indent(indent + 2)
				out_s("\"key\": null,\n")
			}

			if prop.value != nil {
				print_indent(indent + 2)
				out_s("\"value\": {\n")
				print_expression_ast(prop.value, indent + 3)
				print_indent(indent + 2)
				out_s("}")
			} else {
				print_indent(indent + 2)
				out_s("\"value\": null")
			}

			print_indent(indent + 1)
			if i < len(e.properties) - 1 {
				out_s("},\n")
			} else {
				out_s("}\n")
			}
		}
		print_indent(indent)
		out_s("]")

	case ^BinaryExpression:
		out_s(",\n")
		print_indent(indent)
		op_str := binary_op_to_string(e.operator)
		out_s("\"operator\": \"")
		out_s(op_str)
		out_s("\",\n")
		print_indent(indent)
		out_s("\"left\": {\n")
		print_expression_ast(e.left, indent + 1)
		print_indent(indent)
		out_s("},\n")
		print_indent(indent)
		out_s("\"right\": {\n")
		print_expression_ast(e.right, indent + 1)
		print_indent(indent)
		out_s("}")

	case ^UnaryExpression:
		out_s(",\n")
		print_indent(indent)
		op_str := unary_op_to_string(e.operator)
		out_s("\"operator\": \"")
		out_s(op_str)
		out_s("\",\n")
		print_indent(indent)
		out_s("\"prefix\": ")
		out_bool(e.prefix)
		out_s(",\n")
		print_indent(indent)
		out_s("\"argument\": {\n")
		print_expression_ast(e.argument, indent + 1)
		print_indent(indent)
		out_s("}")

	case ^AssignmentExpression:
		out_s(",\n")
		print_indent(indent)
		op_str := assignment_op_to_string(e.operator)
		out_s("\"operator\": \"")
		out_s(op_str)
		out_s("\",\n")
		print_indent(indent)
		out_s("\"left\": {\n")
		print_expression_ast(e.left, indent + 1)
		print_indent(indent)
		out_s("},\n")
		print_indent(indent)
		out_s("\"right\": {\n")
		print_expression_ast(e.right, indent + 1)
		print_indent(indent)
		out_s("}")

	case ^CallExpression:
		out_s(",\n")
		print_indent(indent)
		out_s("\"callee\": {\n")
		print_expression_ast(e.callee, indent + 1)
		print_indent(indent)
		out_s("},\n")
		print_indent(indent)
		out_s("\"arguments\": [\n")
		for arg, i in e.arguments {
			print_indent(indent + 1)
			out_s("{\n")
			print_expression_ast(arg, indent + 2)
			print_indent(indent + 1)
			if i < len(e.arguments) - 1 {
				out_s("},\n")
			} else {
				out_s("}\n")
			}
		}
		print_indent(indent)
		out_s("]")

	case ^MemberExpression:
		out_s(",\n")
		print_indent(indent)
		out_s("\"computed\": ")
		out_bool(e.computed)
		out_s(",\n")
		print_indent(indent)
		out_s("\"object\": {\n")
		print_expression_ast(e.object, indent + 1)
		print_indent(indent)
		out_s("},\n")
		print_indent(indent)
		out_s("\"property\": {\n")
		print_expression_ast(e.property, indent + 1)
		print_indent(indent)
		out_s("}")

	case ^ConditionalExpression:
		out_s(",\n")
		print_indent(indent)
		out_s("\"test\": {\n")
		print_expression_ast(e.test, indent + 1)
		print_indent(indent)
		out_s("},\n")
		print_indent(indent)
		out_s("\"consequent\": {\n")
		print_expression_ast(e.consequent, indent + 1)
		print_indent(indent)
		out_s("},\n")
		print_indent(indent)
		out_s("\"alternate\": {\n")
		print_expression_ast(e.alternate, indent + 1)
		print_indent(indent)
		out_s("}")

	case ^FunctionExpression:
		out_s(",\n")
		print_indent(indent)
		out_s("\"generator\": ")
		out_bool(e.generator)
		out_s(",\n")
		print_indent(indent)
		out_s("\"async\": ")
		out_bool(e.async)
		out_s(",\n")
		print_indent(indent)
		out_s("\"params\": [")
		if len(e.params) == 0 {
			out_s("]")
		} else {
			out_s("\n")
			for param, i in e.params {
				print_indent(indent + 1)
				out_s("{\n")
				print_pattern_ast(param.pattern, indent + 2)
				out_s("\n")
				print_indent(indent + 1)
				if i < len(e.params) - 1 { out_s("},\n") } else { out_s("}\n") }
			}
			print_indent(indent)
			out_s("]")
		}
		out_s(",\n")
		print_indent(indent)
		out_println("\"body\": {")
		fn_body := &e.body
		print_function_body_inline(fn_body, indent + 1)
		out_s("\n")
		print_indent(indent)
		out_print("}")

	case ^ArrowFunctionExpression:
		out_s(",\n")
		print_indent(indent)
		out_s("\"expression\": ")
		out_bool(e.expression)
		out_s(",\n")
		print_indent(indent)
		out_s("\"async\": ")
		out_bool(e.async)
		out_s(",\n")
		print_indent(indent)
		out_s("\"params\": [")
		if len(e.params) == 0 {
			out_s("]")
		} else {
			out_s("\n")
			for param, i in e.params {
				print_indent(indent + 1)
				out_s("{\n")
				print_pattern_ast(param.pattern, indent + 2)
				out_s("\n")
				print_indent(indent + 1)
				if i < len(e.params) - 1 { out_s("},\n") } else { out_s("}\n") }
			}
			print_indent(indent)
			out_s("]")
		}
		out_s(",\n")
		print_indent(indent)
		out_s("\"body\": ")
		// ArrowFunctionBody is union { ^Expression, ^BlockStatement }. The
		// variant was previously emitted as a "..." placeholder due to the
		// pre-Bug-H transmute UB; post-fix we can switch cleanly on the tag.
		switch body in e.body {
		case ^Expression:
			out_s("{\n")
			print_expression_ast(body, indent + 1)
			print_indent(indent)
			out_s("}")
		case ^BlockStatement:
			out_s("{\n")
			print_block_statement_inline(body, indent + 1)
			out_s("\n")
			print_indent(indent)
			out_s("}")
		case:
			out_s("null")
		}

	case ^NewExpression:
		out_s(",\n")
		print_indent(indent)
		out_s("\"callee\": {\n")
		print_expression_ast(e.callee, indent + 1)
		print_indent(indent)
		out_s("},\n")
		print_indent(indent)
		out_s("\"arguments\": [\n")
		for arg, i in e.arguments {
			print_indent(indent + 1)
			out_s("{\n")
			print_expression_ast(arg, indent + 2)
			print_indent(indent + 1)
			if i < len(e.arguments) - 1 {
				out_s("},\n")
			} else {
				out_s("}\n")
			}
		}
		print_indent(indent)
		out_s("]")

	case ^TemplateLiteral:
		out_s(",\n")
		print_indent(indent)
		out_s("\"quasis\": [")
		if len(e.quasis) == 0 {
			out_s("],\n")
		} else {
			out_s("\n")
			for q, i in e.quasis {
				print_indent(indent + 1)
				out_s("{\n")
				print_indent(indent + 2)
				out_s("\"type\": \"TemplateElement\",\n")
				print_indent(indent + 2)
				emit_span_leading(q.loc, indent + 2)
				out_s("\"tail\": ")
				out_bool(q.tail)
				out_s(",\n")
				print_indent(indent + 2)
				out_s("\"value\": { \"raw\": ")
				out_string(q.raw)
				out_s(", \"cooked\": ")
				if cooked, ok := q.cooked.(string); ok {
					out_string(cooked)
				} else {
					out_s("null")
				}
				out_s(" }\n")
				print_indent(indent + 1)
				if i < len(e.quasis) - 1 { out_s("},\n") } else { out_s("}\n") }
			}
			print_indent(indent)
			out_s("],\n")
		}
		print_indent(indent)
		out_s("\"expressions\": [")
		if len(e.expressions) == 0 {
			out_s("]")
		} else {
			out_s("\n")
			for ex, i in e.expressions {
				print_indent(indent + 1)
				out_s("{\n")
				print_expression_ast(ex, indent + 2)
				print_indent(indent + 1)
				if i < len(e.expressions) - 1 { out_s("},\n") } else { out_s("}\n") }
			}
			print_indent(indent)
			out_s("]")
		}

	case ^TaggedTemplateExpression:
		out_s(",\n")
		print_indent(indent)
		out_s("\"tag\": {\n")
		print_expression_ast(e.tag, indent + 1)
		print_indent(indent)
		out_s("},\n")
		print_indent(indent)
		out_s("\"quasi\": {\n")
		print_expression_ast(e.quasi, indent + 1)
		print_indent(indent)
		out_s("}")

	case ^SpreadElement:
		out_s(",\n")
		print_indent(indent)
		out_s("\"argument\": {\n")
		print_expression_ast(e.argument, indent + 1)
		print_indent(indent)
		out_s("}")

	case ^UpdateExpression:
		out_s(",\n")
		print_indent(indent)
		op_str := ""
		switch e.operator {
		case .Increment: op_str = "++"
		case .Decrement: op_str = "--"
		}
		out_s("\"operator\": \"")
		out_s(op_str)
		out_s("\",\n")
		print_indent(indent)
		out_s("\"prefix\": ")
		out_bool(e.prefix)
		out_s(",\n")
		print_indent(indent)
		out_s("\"argument\": {\n")
		print_expression_ast(e.argument, indent + 1)
		print_indent(indent)
		out_s("}")

	case ^LogicalExpression:
		out_s(",\n")
		print_indent(indent)
		op_str := ""
		#partial switch e.operator {
		case .And: op_str = "&&"
		case .Or:  op_str = "||"
		case .NullishCoalescing: op_str = "??"
		}
		out_s("\"operator\": \"")
		out_s(op_str)
		out_s("\",\n")
		print_indent(indent)
		out_s("\"left\": {\n")
		print_expression_ast(e.left, indent + 1)
		print_indent(indent)
		out_s("},\n")
		print_indent(indent)
		out_s("\"right\": {\n")
		print_expression_ast(e.right, indent + 1)
		print_indent(indent)
		out_s("}")

	case ^SequenceExpression:
		out_s(",\n")
		print_indent(indent)
		out_s("\"expressions\": [\n")
		for expr_elem, i in e.expressions {
			print_indent(indent + 1)
			out_s("{\n")
			print_expression_ast(expr_elem, indent + 2)
			print_indent(indent + 1)
			if i < len(e.expressions) - 1 {
				out_s("},\n")
			} else {
				out_s("}\n")
			}
		}
		print_indent(indent)
		out_s("]")

	case ^YieldExpression:
		out_s(",\n")
		print_indent(indent)
		if arg, ok := e.argument.(^Expression); ok && arg != nil {
			out_s("\"argument\": {\n")
			print_expression_ast(arg, indent + 1)
			print_indent(indent)
			out_s("},\n")
		} else {
			out_s("\"argument\": null,\n")
		}
		print_indent(indent)
		out_s("\"delegate\": ")
		out_bool(e.delegate)

	case ^AwaitExpression:
		out_s(",\n")
		print_indent(indent)
		out_s("\"argument\": {\n")
		print_expression_ast(e.argument, indent + 1)
		print_indent(indent)
		out_s("}")

	case ^ImportExpression:
		out_s(",\n")
		print_indent(indent)
		out_s("\"source\": {\n")
		print_expression_ast(e.source, indent + 1)
		print_indent(indent)
		out_s("}")

	case ^MetaProperty:
		out_s(",\n")
		print_indent(indent)
		out_s("\"meta\": {\n")
		print_indent(indent + 1)
		out_s("\"type\": \"Identifier\",\n")
		print_indent(indent + 1)
		emit_span_leading(e.meta.loc, indent + 1)
		out_s("\"name\": \"import\"\n")
		print_indent(indent)
		out_s("},\n")
		print_indent(indent)
		out_s("\"property\": {\n")
		print_indent(indent + 1)
		out_s("\"type\": \"Identifier\",\n")
		print_indent(indent + 1)
		emit_span_leading(e.property.loc, indent + 1)
		out_s("\"name\": \"meta\"\n")
		print_indent(indent)
		out_s("}")

	case ^PrivateIdentifier:
		out_s(",\n")
		print_indent(indent)
		out_s("\"name\": ")
		out_string(e.name)

	case ^ClassExpression:
		out_s(",\n")
		print_indent(indent)
		if e.id != nil {
			id := e.id.(BindingIdentifier)
			out_s("\"id\": {\n")
			print_indent(indent + 1)
			out_s("\"type\": \"Identifier\",\n")
			print_indent(indent + 1)
			emit_span_leading(id.loc, indent + 1)
			out_s("\"name\": ")
			out_string(id.name)
			out_s("\n")
			print_indent(indent)
			out_s("},\n")
		}
		if super, ok := e.super_class.(^Expression); ok && super != nil {
			out_s("\"superClass\": {\n")
			print_expression_ast(super, indent + 1)
			print_indent(indent)
			out_s("},\n")
		}
		// ClassBody.body is a [dynamic]ClassElement. Delegate the full emit to
		// print_class_body_inline, which mirrors the ClassDeclaration path.
		out_s("\"body\": {\n")
		print_class_body_inline(&e.body, indent + 1)
		print_indent(indent)
		out_s("}\n")

	case:
		out_println(",")
		print_indent(indent)
		out_printf("\"[UNIMPLEMENTED]\": true")
	}
}

// ============================================================================
// Type Name Helpers
// ============================================================================

get_statement_type_name :: proc(stmt: ^Statement) -> string {
	if stmt == nil {
		return "nil"
	}
	switch s in stmt^ {
	case ^ExpressionStatement: return "ExpressionStatement"
	case ^EmptyStatement:      return "EmptyStatement"
	case ^BlockStatement:       return "BlockStatement"
	case ^DebuggerStatement:    return "DebuggerStatement"
	case ^ReturnStatement:      return "ReturnStatement"
	case ^BreakStatement:       return "BreakStatement"
	case ^ContinueStatement:    return "ContinueStatement"
	case ^LabeledStatement:     return "LabeledStatement"
	case ^IfStatement:          return "IfStatement"
	case ^SwitchStatement:      return "SwitchStatement"
	case ^WhileStatement:       return "WhileStatement"
	case ^DoWhileStatement:     return "DoWhileStatement"
	case ^ForStatement:         return "ForStatement"
	case ^ForInStatement:       return "ForInStatement"
	case ^ForOfStatement:       return "ForOfStatement"
	case ^WithStatement:        return "WithStatement"
	case ^ThrowStatement:       return "ThrowStatement"
	case ^TryStatement:         return "TryStatement"
	case ^FunctionDeclaration:  return "FunctionDeclaration"
	case ^VariableDeclaration:  return "VariableDeclaration"
	case ^ClassDeclaration:     return "ClassDeclaration"
	case ^ImportDeclaration:    return "ImportDeclaration"
	case ^ExportNamedDeclaration: return "ExportNamedDeclaration"
	case ^ExportDefaultDeclaration: return "ExportDefaultDeclaration"
	case ^ExportAllDeclaration: return "ExportAllDeclaration"
	}
	return "Unknown"
}

get_expression_type_name :: proc(expr: ^Expression) -> string {
	#partial switch e in expr^ {
	case ^NullLiteral:           return "NullLiteral"
	case ^BooleanLiteral:        return "BooleanLiteral"
	case ^NumericLiteral:        return "NumericLiteral"
	case ^StringLiteral:         return "StringLiteral"
	case ^BigIntLiteral:         return "BigIntLiteral"
	case ^RegExpLiteral:         return "RegExpLiteral"
	case ^TemplateLiteral:       return "TemplateLiteral"
	case ^TaggedTemplateExpression: return "TaggedTemplateExpression"
	case ^Identifier:            return "Identifier"
	case ^ThisExpression:        return "ThisExpression"
	case ^Super:                 return "Super"
	case ^ArrayExpression:       return "ArrayExpression"
	case ^ObjectExpression:      return "ObjectExpression"
	case ^FunctionExpression:    return "FunctionExpression"
	case ^ArrowFunctionExpression: return "ArrowFunctionExpression"
	case ^ClassExpression:       return "ClassExpression"
	case ^MemberExpression:      return "MemberExpression"
	case ^CallExpression:        return "CallExpression"
	case ^NewExpression:         return "NewExpression"
	case ^ConditionalExpression: return "ConditionalExpression"
	case ^UpdateExpression:      return "UpdateExpression"
	case ^UnaryExpression:       return "UnaryExpression"
	case ^BinaryExpression:      return "BinaryExpression"
	case ^LogicalExpression:     return "LogicalExpression"
	case ^AssignmentExpression:  return "AssignmentExpression"
	case ^SequenceExpression:    return "SequenceExpression"
	case ^SpreadElement:         return "SpreadElement"
	case ^YieldExpression:       return "YieldExpression"
	case ^AwaitExpression:       return "AwaitExpression"
	case ^ImportExpression:      return "ImportExpression"
	case ^MetaProperty:          return "MetaProperty"
	case ^PrivateIdentifier:     return "PrivateIdentifier"
	}
	return "Unknown"
}

unary_op_to_string :: proc(op: UnaryOperator) -> string {
	switch op {
	case .Minus:        return "-"
	case .Plus:         return "+"
	case .LogicalNot:   return "!"
	case .BitwiseNot:   return "~"
	case .Typeof:       return "typeof"
	case .Void:         return "void"
	case .Delete:       return "delete"
	}
	return "unknown"
}

binary_op_to_string :: proc(op: BinaryOperator) -> string {
	switch op {
	case .Add:                 return "+"
	case .Sub:                 return "-"
	case .Mul:                 return "*"
	case .Div:                 return "/"
	case .Mod:                 return "%"
	case .Pow:                 return "**"
	case .BitOr:               return "|"
	case .BitXor:              return "^"
	case .BitAnd:              return "&"
	case .ShiftLeft:           return "<<"
	case .ShiftRight:          return ">>"
	case .ShiftRightUnsigned:  return ">>>"
	case .Eq:                  return "=="
	case .NotEq:               return "!="
	case .StrictEq:            return "==="
	case .StrictNotEq:         return "!=="
	case .Lt:                  return "<"
	case .Gt:                  return ">"
	case .LtEq:                return "<="
	case .GtEq:                return ">="
	case .Instanceof:          return "instanceof"
	case .In:                  return "in"
	}
	return "unknown"
}

assignment_op_to_string :: proc(op: AssignmentOperator) -> string {
	switch op {
	case .Assign:              return "="
	case .AddAssign:           return "+="
	case .SubAssign:           return "-="
	case .MulAssign:           return "*="
	case .DivAssign:           return "/="
	case .ModAssign:           return "%="
	case .PowAssign:           return "**="
	case .ShiftLeftAssign:     return "<<="
	case .ShiftRightAssign:    return ">>="
	case .ShiftRightUAssign:   return ">>>="
	case .BitOrAssign:         return "|="
	case .BitXorAssign:        return "^="
	case .BitAndAssign:        return "&="
	case .AssignLogicalAnd:    return "&&="
	case .AssignLogicalOr:     return "||="
	case .AssignNullish:       return "??="
	}
	return "unknown"
}

// ============================================================================
// Lex Command (Tokenize)
// ============================================================================

lex_file :: proc(file_path: string) {
	// Read file
	source, read_err := os.read_entire_file_from_path(file_path, context.allocator)
	if read_err != nil {
		out_printf("Error: Could not read file: %s\n", file_path)
		flush_stdout_writer()
		os.exit(1)
	}
	defer delete(source, context.allocator)

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
	source, read_err := os.read_entire_file_from_path(file_path, context.allocator)
	if read_err != nil {
		fmt.eprintf("Error: Could not read file: %s\n", file_path)
		os.exit(1)
	}
	defer delete(source, context.allocator)
	
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
	source, read_err := os.read_entire_file_from_path(file_path, context.allocator)
	if read_err != nil {
		fmt.eprintf("Error: Could not read file: %s\n", file_path)
		os.exit(1)
	}
	defer delete(source, context.allocator)

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
