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

import lexer "./lexer"
import parser "./parser"
import ast "./ast"

// ============================================================================
// Main Entry Point
// ============================================================================

stdout_writer_initialized := false
stdout_writer: bufio.Writer
stdout_writer_buf: [1 * 1024 * 1024]byte // Increased from 64KB to 1MB for JSON streaming
stdout_stream: io.Writer

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

// Fast-path for static strings (no reflection overhead)
out_s :: #force_inline proc(s: string) {
	init_stdout_writer()
	bufio.writer_write_string(&stdout_writer, s)
}

// Fast-path for single bytes
out_byte :: #force_inline proc(b: byte) {
	init_stdout_writer()
	bufio.writer_write_byte(&stdout_writer, b)
}

// Escape a string for JSON: quotes, backslashes, control chars
out_string :: proc(s: string) {
	init_stdout_writer()
	bufio.writer_write_byte(&stdout_writer, '"')
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch c {
		case '"':
			bufio.writer_write_string(&stdout_writer, "\\\"")
		case '\\':
			bufio.writer_write_string(&stdout_writer, "\\\\")
		case '\n':
			bufio.writer_write_string(&stdout_writer, "\\n")
		case '\r':
			bufio.writer_write_string(&stdout_writer, "\\r")
		case '\t':
			bufio.writer_write_string(&stdout_writer, "\\t")
		case:
			if c < 0x20 {
				tmp: [8]byte
				s := fmt.bprintf(tmp[:], "\\u%04x", c)
				bufio.writer_write_string(&stdout_writer, s)
			} else {
				bufio.writer_write_byte(&stdout_writer, c)
			}
		}
	}
	bufio.writer_write_byte(&stdout_writer, '"')
}

// Write integer as decimal ASCII (no allocation)
out_int :: proc(n: int) {
	init_stdout_writer()
	tmp: [24]byte
	s := strconv.write_int(tmp[:], i64(n), 10)
	bufio.writer_write_string(&stdout_writer, s)
}

// Write bool as 'true' or 'false'
out_bool :: #force_inline proc(b: bool) {
	init_stdout_writer()
	if b {
		bufio.writer_write_string(&stdout_writer, "true")
	} else {
		bufio.writer_write_string(&stdout_writer, "false")
	}
}

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
	if len(os.args) < 2 {
		print_usage()
		flush_stdout_writer()
		os.exit(1)
	}

	command := os.args[1]

	switch command {
	case "parse":
		if len(os.args) < 3 {
			out_println("Error: parse command requires a file path")
			out_println("Usage: kessel parse <js-file>")
			flush_stdout_writer()
			os.exit(1)
		}
		file_path := os.args[2]
		parse_file(file_path)

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
		if len(os.args) < 3 {
			out_println("Error: microbench requires a file path")
			out_println("Usage: kessel microbench <file> [--iterations N]")
			flush_stdout_writer()
			os.exit(1)
		}
		file_path := os.args[2]
		iterations := 1000
		if len(os.args) >= 5 && os.args[3] == "--iterations" {
			n, ok := strconv.parse_int(os.args[4])
			if ok {
				iterations = n
			}
		}
		microbench_file(file_path, iterations)
		
	case "help", "-h", "--help":
		print_usage()

	case "parse-many":
		if len(os.args) < 3 {
			out_println("Usage: kessel parse-many <file1> [file2...] [--workers N]")
			os.flush(os.stdout)
			os.exit(1)
		}
		files := make([dynamic]string)
		workers := 0
		i := 2
		for i < len(os.args) {
			arg := os.args[i]
			if arg == "--workers" && i + 1 < len(os.args) {
				n, _ := strconv.parse_int(os.args[i+1])
				workers = n
				i += 2
				continue
			}
			append(&files, arg)
			i += 1
		}
		if workers == 0 {
			workers = 8
			if workers == 0 { workers = 8 }
		}
		parse_many(files[:], workers)
		delete(files)

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
	out_println("  parse <file>                    Parse a JavaScript file and output AST as JSON")
	out_println("  lex <file>                      Tokenize a JavaScript file and output tokens")
	out_println("  microbench <file> [--iterations N]  Run parse in-process loop (default 1000 iters)")
	out_println("  test                            Run lexer debug test")
	out_println("  help                            Show this help message")
	out_println("  version                         Show version information")
	out_println("")
	out_println("Examples:")
	out_println("  kessel parse app.js")
	out_println("  kessel lex src/index.js")
	out_println("  kessel microbench app.js --iterations 5000")
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
	
	// Create growing virtual arena for allocations (64KB initial block, lazy commit)
	arena: mvirtual.Arena
	err := mvirtual.arena_init_growing(&arena, reserved=64*1024)
	if err != nil {
		fmt.eprintf("Error initializing arena: %v\n", err)
		os.exit(1)
	}
	defer mvirtual.arena_destroy(&arena)
	arena_alloc := mvirtual.arena_allocator(&arena)
	
	fmt.eprintf("Arena initialized with 64KB reserved block (lazy commit)\n")
	
	// Initialize optimized lexer with compact tokens + SIMD
	lex: lexer.LexerAdapter
	lexer.init_adapter(&lex, string(source), arena_alloc)
	
	// Initialize parser with optimized lexer
	p: parser.Parser
	parser.init_parser_adapter(&p, &lex, arena_alloc)

	// Parse program
	program := parser.parse_program(&p, .Script)
	
	// Check for errors
	if len(p.errors) > 0 {
		out_printf("Parse errors (%d):\n", len(p.errors))
		for err in p.errors {
			out_printf("  Line %d, Column %d: %s\n", err.loc.line, err.loc.column, err.message)
		}
	}
	
	// Output AST as JSON-like structure
	out_println("{")
	print_program_ast(program, 1)
	out_println("}")
	
	// Print statistics
	fmt.eprintf("\n--- Statistics ---\n")
	ratio := (arena.total_used * 100) / arena.total_reserved
	fmt.eprintf("Arena: used=%dB reserved=%dB ratio=%d%%\n", arena.total_used, arena.total_reserved, ratio)
	fmt.eprintf("Parse errors: %d\n", len(p.errors))
}

// ============================================================================
// ============================================================================
// parse_file_quiet: Parse without JSON output, return stats
// ============================================================================

parse_file_quiet :: proc(file_path: string) -> (bool, int, int) {
	source, read_err := os.read_entire_file_from_path(file_path, context.allocator)
	if read_err != nil { return false, 0, 0 }
	defer delete(source, context.allocator)
	file_size := len(source)
	arena: mvirtual.Arena
	_ = mvirtual.arena_init_growing(&arena, reserved=64*1024)
	defer mvirtual.arena_destroy(&arena)
	arena_alloc := mvirtual.arena_allocator(&arena)
	lex: lexer.LexerAdapter
	lexer.init_adapter(&lex, string(source), arena_alloc)
	p: parser.Parser
	parser.init_parser_adapter(&p, &lex, arena_alloc)
	_ = parser.parse_program(&p, .Script)
	return true, file_size, len(p.errors)
}

// ============================================================================
// parse_many: Multi-file parsing with static work division
// ============================================================================

ParseWorkerCtx :: struct {
	files: []string,
	start_idx: int,
	end_idx: int,
	parsed_count: int,
	error_count: int,
	total_bytes: int,
}

worker_proc :: proc(data: rawptr) {
	ctx := (^ParseWorkerCtx)(data)
	for i in ctx.start_idx..<ctx.end_idx {
		success, bytes, errs := parse_file_quiet(ctx.files[i])
		if success {
			ctx.parsed_count += 1
			ctx.total_bytes += bytes
			ctx.error_count += errs
		}
	}
}

parse_many :: proc(files: []string, n_workers: int) {
	if len(files) == 0 {
		out_println("No files to parse.")
		return
	}

	// Pre-initialize all thread-unsafe lazy-init global tables.
	// Without this, workers race initializing CHAR_CLASS_TABLE and keyword_hash_table_2.
	lexer.ensure_keyword_hash()
	lexer.init_char_class_table()

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
			start_idx = start,
			end_idx = end,
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
	os.flush(os.stdout)
}
// Microbench Command (in-process parse measurements)
// ============================================================================

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
	
	// Warm-up run (1 iteration, not counted)
	{
		arena: mvirtual.Arena
		_ = mvirtual.arena_init_growing(&arena, reserved=64*1024)
		defer mvirtual.arena_destroy(&arena)
		arena_alloc := mvirtual.arena_allocator(&arena)
		
		lex: lexer.LexerAdapter
		lexer.init_adapter(&lex, string(source), arena_alloc)
		
		p: parser.Parser
		parser.init_parser_adapter(&p, &lex, arena_alloc)
		
		_ = parser.parse_program(&p, .Script)
	}
	
	// Main benchmark loop
	for i in 0..<iterations {
		start := time.tick_now()
		
		arena: mvirtual.Arena
		_ = mvirtual.arena_init_growing(&arena, reserved=64*1024)
		defer mvirtual.arena_destroy(&arena)
		arena_alloc := mvirtual.arena_allocator(&arena)
		
		lex: lexer.LexerAdapter
		lexer.init_adapter(&lex, string(source), arena_alloc)
		
		p: parser.Parser
		parser.init_parser_adapter(&p, &lex, arena_alloc)
		
		_ = parser.parse_program(&p, .Script)
		
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
	for i in 0..<indent {
		out_print("  ")
	}
}

print_program_ast :: proc(program: ^ast.Program, indent: int) {
	print_indent(indent)
	type_str := "Script" if program.type == .Script else "Module"
	out_s("\"type\": \"")
	out_s(type_str)
	out_s("\",\n")

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

print_statement_ast :: proc(stmt: ^ast.Statement, indent: int) {
	print_indent(indent)
	out_s("\"type\": \"")
	out_s(get_statement_type_name(stmt))
	out_s("\"")

	#partial switch s in stmt^ {
	case ^ast.ExpressionStatement:
		out_s(",\n")
		print_indent(indent)
		out_s("\"expression\": {\n")
		print_expression_ast(s.expression, indent + 1)
		print_indent(indent)
		out_s("}")

	case ^ast.VariableDeclaration:
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
			out_s("\"id\": {\n")
			print_pattern_ast(decl.id, indent + 3)
			print_indent(indent + 2)
			out_s("},\n")
			print_indent(indent + 2)
			out_s("\"init\": ")
			if init, ok := decl.init.(^ast.Expression); ok {
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

	case ^ast.FunctionDeclaration:
		out_s(",\n")
		print_indent(indent)
		out_s("\"id\": {\n")
		if id, ok := s.expr.id.(ast.BindingIdentifier); ok {
			print_indent(indent + 1)
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

	case ^ast.BlockStatement:
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

	case ^ast.ReturnStatement:
		out_s(",\n")
		print_indent(indent)
		out_s("\"argument\": ")
		if arg, ok := s.argument.(^ast.Expression); ok {
			out_s("{\n")
			print_expression_ast(arg, indent + 1)
			print_indent(indent)
			out_s("}")
		} else {
			out_s("null")
		}

	case ^ast.IfStatement:
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
		if alt, ok := s.alternate.(^ast.Statement); ok {
			out_s("{\n")
			print_statement_ast(alt, indent + 1)
			print_indent(indent)
			out_s("}")
		} else {
			out_s("null")
		}

	case ^ast.WhileStatement:
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

	case ^ast.ForStatement:
		out_println(",")
		print_indent(indent)
		out_print("\"init\": ")
		if decl, ok := s.init_decl.(^ast.VariableDeclaration); ok {
			out_println("{")
			print_statement_ast((^ast.Statement)(decl), indent + 1)
			print_indent(indent)
			out_println("},")
		} else if expr, ok := s.init_expr.(^ast.Expression); ok {
			out_println("{")
			print_expression_ast(expr, indent + 1)
			print_indent(indent)
			out_println("},")
		} else {
			out_println("null,")
		}
		print_indent(indent)
		out_print("\"test\": ")
		if test_expr, ok := s.test.(^ast.Expression); ok {
			out_println("{")
			print_expression_ast(test_expr, indent + 1)
			print_indent(indent)
			out_println("},")
		} else {
			out_println("null,")
		}
		print_indent(indent)
		out_print("\"update\": ")
		if upd_expr, ok := s.update.(^ast.Expression); ok {
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

	case ^ast.ClassDeclaration:
		out_println(",")
		print_indent(indent)
		out_print("\"id\": ")
		if id, ok := s.id.(ast.BindingIdentifier); ok {
			out_s("{\n")
			print_indent(indent + 1)
			out_s("\"type\": \"Identifier\",\n")
			print_indent(indent + 1)
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
		if super, ok := s.super_class.(^ast.Expression); ok && super != nil {
			out_println("{")
			print_expression_ast(super, indent + 1)
			print_indent(indent)
			out_println("},")
		} else {
			out_println("null,")
		}
		print_indent(indent)
		out_print("\"body\": { ... }")

	case ^ast.TryStatement:
		out_println(",")
		print_indent(indent)
		out_println("\"block\": { ... },")
		print_indent(indent)
		out_print("\"handler\": ")
		if handler, ok := s.handler.(ast.CatchClause); ok {
			out_println("{")
			print_indent(indent + 1)
			out_println("\"type\": \"CatchClause\",")
			print_indent(indent + 1)
			out_print("\"param\": ")
			if param, ok2 := handler.param.(ast.Pattern); ok2 {
				out_println("{")
				print_pattern_ast(param, indent + 2)
				print_indent(indent + 1)
				out_println("},")
			} else {
				out_println("null,")
			}
			print_indent(indent + 1)
			out_println("\"body\": { ... }")
			print_indent(indent)
			out_println("},")
		} else {
			out_println("null,")
		}
		print_indent(indent)
		out_print("\"finalizer\": ")
		if fin, ok := s.finalizer.(ast.BlockStatement); ok {
			out_println("{")
			print_statement_ast((^ast.Statement)(&fin), indent + 1)
			print_indent(indent)
			out_print("}")
		} else {
			out_print("null")
		}

	case ^ast.ExportNamedDeclaration:
		out_println(",")
		print_indent(indent)
		out_print("\"specifiers\": [ ... ]")

	case ^ast.ExportDefaultDeclaration:
		out_println(",")
		print_indent(indent)
		out_print("\"declaration\": { ... }")

	case ^ast.ExportAllDeclaration:
		out_println(",")
		print_indent(indent)
		out_print("\"source\": { ... }")

	case ^ast.DoWhileStatement:
		out_println(",")
		print_indent(indent)
		out_println("\"body\": {")
		print_statement_ast(s.body, indent + 1)
		print_indent(indent)
		out_println("},")
		print_indent(indent)
		out_print("\"test\": { ... }")

	case ^ast.SwitchStatement:
		out_println(",")
		print_indent(indent)
		out_print("\"discriminant\": { ... },\n")
		print_indent(indent)
		out_print("\"cases\": [ ... ]")

	case ^ast.ForInStatement:
		out_println(",")
		print_indent(indent)
		out_print("\"left\": ")
		if decl, ok := s.left_decl.(^ast.VariableDeclaration); ok {
			out_println("{")
			print_statement_ast((^ast.Statement)(decl), indent + 1)
			print_indent(indent)
			out_println("},")
		} else if expr, ok := s.left_expr.(^ast.Expression); ok {
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

	case ^ast.ForOfStatement:
		out_println(",")
		print_indent(indent)
		out_print("\"left\": ")
		if decl, ok := s.left_decl.(^ast.VariableDeclaration); ok {
			out_println("{")
			print_statement_ast((^ast.Statement)(decl), indent + 1)
			print_indent(indent)
			out_println("},")
		} else if expr, ok := s.left_expr.(^ast.Expression); ok {
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
		print_indent(indent)
		out_print("\"await\": false,\n")
		print_indent(indent)
		out_print("\"body\": { ... }")

	case ^ast.ThrowStatement:
		out_println(",")
		print_indent(indent)
		out_print("\"argument\": { ... }")

	case ^ast.ImportDeclaration:
		out_println(",")
		print_indent(indent)
		out_print("\"specifiers\": [ ... ],\n")
		print_indent(indent)
		out_print("\"source\": { ... }")

	case ^ast.BreakStatement:
		out_println(",")
		print_indent(indent)
		out_print("\"label\": null")

	case ^ast.ContinueStatement:
		out_println(",")
		print_indent(indent)
		out_print("\"label\": null")

	case ^ast.LabeledStatement:
		out_println(",")
		print_indent(indent)
		out_print("\"label\": { ... },\n")
		print_indent(indent)
		out_print("\"body\": { ... }")

	case ^ast.WithStatement:
		out_println(",")
		print_indent(indent)
		out_print("\"object\": { ... },\n")
		print_indent(indent)
		out_print("\"body\": { ... }")

	case ^ast.EmptyStatement:
		// No additional fields

	case ^ast.DebuggerStatement:
		// No additional fields

	case:
		out_s(",\n")
		print_indent(indent)
		out_s("\"[UNIMPLEMENTED]\": true")
	}
}

print_pattern_ast :: proc(pattern: ast.Pattern, indent: int) {
	#partial switch p in pattern {
	case ^ast.Identifier:
		print_indent(indent)
		out_s("\"type\": \"Identifier\",\n")
		print_indent(indent)
		out_s("\"name\": ")
		out_string(p.name)
	case ^ast.ArrayPattern:
		print_indent(indent)
		out_s("\"type\": \"ArrayPattern\",\n")
		print_indent(indent)
		out_s("\"elements\": [\n")
		for elem, i in p.elements {
			if e, ok := elem.(ast.Pattern); ok {
				print_pattern_ast(e, indent + 1)
				if i < len(p.elements) - 1 {
					out_s(",\n")
				}
			}
		}
		print_indent(indent)
		out_s("]")
	case ^ast.ObjectPattern:
		print_indent(indent)
		out_s("\"type\": \"ObjectPattern\",\n")
		print_indent(indent)
		out_s("\"properties\": [ ... ]\n") // Simplified for now
	case:
		print_indent(indent)
		out_s("null")
	}
}

print_expression_ast :: proc(expr: ^ast.Expression, indent: int) {
	print_indent(indent)
	out_s("\"type\": \"")
	out_s(get_expression_type_name(expr))
	out_s("\"")

	#partial switch e in expr^ {
	case ast.Identifier:
		out_s(",\n")
		print_indent(indent)
		out_s("\"name\": ")
		out_string(e.name)

	case ast.NumericLiteral:
		out_s(",\n")
		print_indent(indent)
		out_s("\"value\": ")
		out_printf("%v,\n", e.value)
		print_indent(indent)
		out_s("\"raw\": ")
		out_string(e.raw)

	case ast.StringLiteral:
		out_s(",\n")
		print_indent(indent)
		out_s("\"value\": ")
		out_string(e.value)

	case ast.BooleanLiteral:
		out_s(",\n")
		print_indent(indent)
		out_s("\"value\": ")
		out_bool(e.value)

	case ast.NullLiteral:
		// No additional fields

	case ast.ThisExpression:
		// No additional fields

	case ast.ArrayExpression:
		out_s(",\n")
		print_indent(indent)
		out_s("\"elements\": [\n")
		for elem, i in e.elements {
			if el, ok := elem.(^ast.Expression); ok {
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

	case ast.ObjectExpression:
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

	case ast.BinaryExpression:
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

	case ast.UnaryExpression:
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

	case ast.AssignmentExpression:
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

	case ast.CallExpression:
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

	case ast.MemberExpression:
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

	case ast.ConditionalExpression:
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

	case ast.FunctionExpression:
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
		out_s("\"params\": [ ... ],\n")
		print_indent(indent)
		out_s("\"body\": { ... }")

	case ast.ArrowFunctionExpression:
		out_s(",\n")
		print_indent(indent)
		out_s("\"expression\": ")
		out_bool(e.expression)
		out_s(",\n")
		print_indent(indent)
		out_s("\"async\": ")
		out_bool(e.async)

	case ast.NewExpression:
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

	case ast.TemplateLiteral:
		out_s(",\n")
		print_indent(indent)
		out_s("\"quasis\": [ ... ],\n")
		print_indent(indent)
		out_s("\"expressions\": [ ... ]")

	case ast.TaggedTemplateExpression:
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

	case ast.SpreadElement:
		out_s(",\n")
		print_indent(indent)
		out_s("\"argument\": {\n")
		print_expression_ast(e.argument, indent + 1)
		print_indent(indent)
		out_s("}")

	case ast.BigIntLiteral:
		out_s(",\n")
		print_indent(indent)
		out_s("\"value\": ")
		out_string(e.value)
		out_s(",\n")
		print_indent(indent)
		out_s("\"raw\": ")
		out_string(e.raw)

	case ast.RegExpLiteral:
		out_s(",\n")
		print_indent(indent)
		out_s("\"pattern\": ")
		out_string(e.pattern)
		out_s(",\n")
		print_indent(indent)
		out_s("\"flags\": ")
		out_string(e.flags)

	case ast.UpdateExpression:
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

	case ast.LogicalExpression:
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

	case ast.SequenceExpression:
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

	case ast.YieldExpression:
		out_s(",\n")
		print_indent(indent)
		if arg, ok := e.argument.(^ast.Expression); ok && arg != nil {
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

	case ast.AwaitExpression:
		out_s(",\n")
		print_indent(indent)
		out_s("\"argument\": {\n")
		print_expression_ast(e.argument, indent + 1)
		print_indent(indent)
		out_s("}")

	case ast.ImportExpression:
		out_s(",\n")
		print_indent(indent)
		out_s("\"source\": {\n")
		print_expression_ast(e.source, indent + 1)
		print_indent(indent)
		out_s("}")

	case ast.MetaProperty:
		out_s(",\n")
		print_indent(indent)
		out_s("\"meta\": {\n")
		print_indent(indent + 1)
		out_s("\"type\": \"Identifier\",\n")
		print_indent(indent + 1)
		out_s("\"name\": \"import\"\n")
		print_indent(indent)
		out_s("},\n")
		print_indent(indent)
		out_s("\"property\": {\n")
		print_indent(indent + 1)
		out_s("\"type\": \"Identifier\",\n")
		print_indent(indent + 1)
		out_s("\"name\": \"meta\"\n")
		print_indent(indent)
		out_s("}")

	case ast.PrivateIdentifier:
		out_s(",\n")
		print_indent(indent)
		out_s("\"name\": ")
		out_string(e.name)

	case ast.ClassExpression:
		out_s(",\n")
		print_indent(indent)
		if e.id != nil {
			id := e.id.(ast.BindingIdentifier)
			out_s("\"id\": {\n")
			print_indent(indent + 1)
			out_s("\"type\": \"Identifier\",\n")
			print_indent(indent + 1)
			out_s("\"name\": ")
			out_string(id.name)
			out_s("\n")
			print_indent(indent)
			out_s("},\n")
		}
		if super, ok := e.super_class.(^ast.Expression); ok && super != nil {
			out_s("\"superClass\": {\n")
			print_expression_ast(super, indent + 1)
			print_indent(indent)
			out_s("},\n")
		}
		out_s("\"body\": { ... }\n")

	case:
		out_println(",")
		print_indent(indent)
		out_printf("\"[UNIMPLEMENTED]\": true")
	}
}

// ============================================================================
// Type Name Helpers
// ============================================================================

get_statement_type_name :: proc(stmt: ^ast.Statement) -> string {
	if stmt == nil {
		return "nil"
	}
	switch s in stmt^ {
	case ^ast.ExpressionStatement: return "ExpressionStatement"
	case ^ast.EmptyStatement:      return "EmptyStatement"
	case ^ast.BlockStatement:       return "BlockStatement"
	case ^ast.DebuggerStatement:    return "DebuggerStatement"
	case ^ast.ReturnStatement:      return "ReturnStatement"
	case ^ast.BreakStatement:       return "BreakStatement"
	case ^ast.ContinueStatement:    return "ContinueStatement"
	case ^ast.LabeledStatement:     return "LabeledStatement"
	case ^ast.IfStatement:          return "IfStatement"
	case ^ast.SwitchStatement:      return "SwitchStatement"
	case ^ast.WhileStatement:       return "WhileStatement"
	case ^ast.DoWhileStatement:     return "DoWhileStatement"
	case ^ast.ForStatement:         return "ForStatement"
	case ^ast.ForInStatement:       return "ForInStatement"
	case ^ast.ForOfStatement:       return "ForOfStatement"
	case ^ast.WithStatement:        return "WithStatement"
	case ^ast.ThrowStatement:       return "ThrowStatement"
	case ^ast.TryStatement:         return "TryStatement"
	case ^ast.FunctionDeclaration:  return "FunctionDeclaration"
	case ^ast.VariableDeclaration:  return "VariableDeclaration"
	case ^ast.ClassDeclaration:     return "ClassDeclaration"
	case ^ast.ImportDeclaration:    return "ImportDeclaration"
	case ^ast.ExportNamedDeclaration: return "ExportNamedDeclaration"
	case ^ast.ExportDefaultDeclaration: return "ExportDefaultDeclaration"
	case ^ast.ExportAllDeclaration: return "ExportAllDeclaration"
	}
	return "Unknown"
}

get_expression_type_name :: proc(expr: ^ast.Expression) -> string {
	#partial switch e in expr^ {
	case ast.NullLiteral:           return "NullLiteral"
	case ast.BooleanLiteral:        return "BooleanLiteral"
	case ast.NumericLiteral:        return "NumericLiteral"
	case ast.StringLiteral:         return "StringLiteral"
	case ast.BigIntLiteral:         return "BigIntLiteral"
	case ast.RegExpLiteral:         return "RegExpLiteral"
	case ast.TemplateLiteral:       return "TemplateLiteral"
	case ast.TaggedTemplateExpression: return "TaggedTemplateExpression"
	case ast.Identifier:            return "Identifier"
	case ast.ThisExpression:        return "ThisExpression"
	case ast.Super:                 return "Super"
	case ast.ArrayExpression:       return "ArrayExpression"
	case ast.ObjectExpression:      return "ObjectExpression"
	case ast.FunctionExpression:    return "FunctionExpression"
	case ast.ArrowFunctionExpression: return "ArrowFunctionExpression"
	case ast.ClassExpression:       return "ClassExpression"
	case ast.MemberExpression:      return "MemberExpression"
	case ast.CallExpression:        return "CallExpression"
	case ast.NewExpression:         return "NewExpression"
	case ast.ConditionalExpression: return "ConditionalExpression"
	case ast.UpdateExpression:      return "UpdateExpression"
	case ast.UnaryExpression:       return "UnaryExpression"
	case ast.BinaryExpression:      return "BinaryExpression"
	case ast.LogicalExpression:     return "LogicalExpression"
	case ast.AssignmentExpression:  return "AssignmentExpression"
	case ast.SequenceExpression:    return "SequenceExpression"
	case ast.SpreadElement:         return "SpreadElement"
	case ast.YieldExpression:       return "YieldExpression"
	case ast.AwaitExpression:       return "AwaitExpression"
	case ast.ImportExpression:      return "ImportExpression"
	case ast.MetaProperty:          return "MetaProperty"
	case ast.PrivateIdentifier:     return "PrivateIdentifier"
	}
	return "Unknown"
}

unary_op_to_string :: proc(op: ast.UnaryOperator) -> string {
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

binary_op_to_string :: proc(op: ast.BinaryOperator) -> string {
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

assignment_op_to_string :: proc(op: ast.AssignmentOperator) -> string {
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

	// Create growing virtual arena for allocations (64KB initial block, lazy commit)
	arena: mvirtual.Arena
	err := mvirtual.arena_init_growing(&arena, reserved=64*1024)
	if err != nil {
		fmt.eprintf("Error initializing arena: %v\n", err)
		os.exit(1)
	}
	defer mvirtual.arena_destroy(&arena)
	arena_alloc := mvirtual.arena_allocator(&arena)

	// Initialize optimized lexer
	lex: lexer.LexerAdapter
	lexer.init_adapter(&lex, string(source), arena_alloc)

	// Tokenize and print
	out_println("[")

	token_count := 0
	for {
		tok := lexer.get_current_adapter(&lex)

		if tok.type == .EOF {
			break
		}

		if token_count > 0 {
			out_println(",")
		}

		out_printf("  {{\"type\": \"%s\", \"value\": ", lexer.get_token_name(tok.type))

		// Escape string value for JSON
		escaped := tok.value
		escaped, _ = strings.replace_all(escaped, "\\", "\\\\")
		escaped, _ = strings.replace_all(escaped, "\"", "\\\"")
		escaped, _ = strings.replace_all(escaped, "\n", "\\n")
		escaped, _ = strings.replace_all(escaped, "\t", "\\t")
		escaped, _ = strings.replace_all(escaped, "\r", "\\r")
		out_printf("\"%s\", ", escaped)
		out_printf("\"loc\": {{\"line\": %d, \"column\": %d}}, ", tok.loc.line, tok.loc.column)
		out_printf("\"lt\": %v}}", tok.had_line_terminator)

		token_count += 1
		lexer.next_adapter(&lex)
	}

	// Print optimization stats
	stats := lexer.get_stats(&lex)
	fmt.eprintf("\n--- Optimization Stats ---\n")
	fmt.eprintf("Tokens created: %d\n", stats.tokens_created)
	fmt.eprintf("SIMD chunks: %d\n", stats.simd_chunks_processed)
	fmt.eprintf("Scalar fallbacks: %d\n", stats.scalar_fallbacks)

	out_println()
	out_println("]")
	fmt.eprintf("\nTotal tokens: %d\n", token_count)
}

