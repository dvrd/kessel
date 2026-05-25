package kessel

import "core:fmt"
import "core:strings"

// ============================================================================
// Pretty diagnostic renderer — rustc-style, optionally colored.
//
// Output shape (one diagnostic):
//
//   error[K3011]: 'await' is only allowed within async functions and at the top levels of modules
//     --> demo.mjs:2:3
//      |
//    2 |   await fetch('/');
//      |   ^^^^^
//      = note: see TS1308
//
// Multiple diagnostics print as separate blocks separated by blank lines.
//
// Color: caller-controlled via the `use_color` bool. Resolution of that
// bool from KESSEL_COLOR + --color happens in src/cli_config.odin so the
// renderer stays pure (no env / fd peeking inside the hot loop). ANSI
// codes follow the rustc / clang palette: red+bold for `error`, yellow+bold
// for `warning`, bold for the code, dim for the gutter / note prefix,
// no color on source text.
//
// Writes to stderr so the JSON path (if any) on stdout stays clean.
// Zero new dependencies — just `core:fmt` and `core:strings`.
// ============================================================================

// Static buffer used for caret-padding / caret-bar runs. Sized to handle
// any source-line offset we realistically render (single source line caps
// at int max but typical worst-case is a minified bundle on one line —
// 100KB+). A static 65536-byte buffer covers every real-world case in a
// single write; longer runs fall back to a chunked loop that's still
// O(n/CHUNK) eprintf calls instead of O(n).
@(private="file") REPEAT_CHUNK_SIZE :: 4096
@(private="file") repeat_space_chunk: [REPEAT_CHUNK_SIZE]byte = #partial { 0 = ' ' }
@(private="file") repeat_caret_chunk: [REPEAT_CHUNK_SIZE]byte = #partial { 0 = '^' }
@(private="file") repeat_chunks_initialized := false

@(private="file")
ensure_repeat_chunks :: proc() {
	if repeat_chunks_initialized { return }
	for i in 0..<REPEAT_CHUNK_SIZE {
		repeat_space_chunk[i] = ' '
		repeat_caret_chunk[i] = '^'
	}
	repeat_chunks_initialized = true
}

@(private="file")
emit_repeated :: proc(b: byte, n: int) {
	if n <= 0 { return }
	ensure_repeat_chunks()
	src: ^[REPEAT_CHUNK_SIZE]byte = b == '^' ? &repeat_caret_chunk : &repeat_space_chunk
	remaining := n
	for remaining > 0 {
		k := min(remaining, REPEAT_CHUNK_SIZE)
		fmt.eprint(string(src[:k]))
		remaining -= k
	}
}

// ANSI escape sequences. Kept inline (not constants) so a future caller
// can build a different palette without restructuring the renderer.
@(private="file") ANSI_RESET     :: "\x1b[0m"
@(private="file") ANSI_BOLD      :: "\x1b[1m"
@(private="file") ANSI_DIM       :: "\x1b[2m"
@(private="file") ANSI_RED       :: "\x1b[31m"
@(private="file") ANSI_YELLOW    :: "\x1b[33m"
@(private="file") ANSI_BLUE      :: "\x1b[34m"
@(private="file") ANSI_BOLD_RED  :: "\x1b[1;31m"
@(private="file") ANSI_BOLD_YELLOW :: "\x1b[1;33m"

// render_pretty_diagnostics writes a rustc-style block per diagnostic
// to stderr. Caller passes the source bytes, the file path (for the
// `-->` header), the line-offset table, the diagnostic list, and
// whether to use ANSI colors. Writes nothing when the list is empty.
render_pretty_diagnostics :: proc(
	source:       string,
	path:         string,
	line_offsets: []u32,
	errors:       []ParseError,
	use_color:    bool,
) {
	if len(errors) == 0 { return }

	for err, idx in errors {
		if idx > 0 { fmt.eprintln() }
		render_one(source, path, line_offsets, err, use_color)
	}
}

// render_one prints a single diagnostic block.
@(private="file")
render_one :: proc(
	source:       string,
	path:         string,
	line_offsets: []u32,
	err:          ParseError,
	use_color:    bool,
) {
	info := error_info(err.code)
	sev  := severity_string(err.severity)
	code := error_code_string(err.code)

	line, col := offset_to_line_col(line_offsets, err.start)
	end_line, end_col := offset_to_line_col(line_offsets, err.end if err.end > err.start else err.start + 1)

	// --- Header line: `error[K3011]: message` ---
	//
	// Colors:
	//   `error` / `warning` — bold + red / yellow
	//   `[K####]`            — bold (no color)
	//   `: message`          — plain
	sev_color := ""
	if use_color {
		switch err.severity {
		case .Error:   sev_color = ANSI_BOLD_RED
		case .Warning: sev_color = ANSI_BOLD_YELLOW
		}
	}
	if use_color {
		if len(code) > 0 {
			fmt.eprintf("%s%s%s%s[%s]%s: %s\n",
				sev_color, sev, ANSI_RESET,
				ANSI_BOLD, code, ANSI_RESET,
				err.message)
		} else {
			fmt.eprintf("%s%s%s: %s\n", sev_color, sev, ANSI_RESET, err.message)
		}
	} else {
		if len(code) > 0 {
			fmt.eprintf("%s[%s]: %s\n", sev, code, err.message)
		} else {
			fmt.eprintf("%s: %s\n", sev, err.message)
		}
	}

	// --- Location line: `  --> path:line:col` ---
	if use_color {
		fmt.eprintf("  %s-->%s %s:%d:%d\n", ANSI_BLUE, ANSI_RESET, path, line, col)
	} else {
		fmt.eprintf("  --> %s:%d:%d\n", path, line, col)
	}

	// --- Source snippet + caret ---
	render_snippet(source, line_offsets, line, col, end_line, end_col, use_color)

	// --- Hint and TS-code notes ---
	//   `  = hint: ...` and `  = note: see TS####`
	if len(info.hint) > 0 {
		if use_color {
			fmt.eprintf("  %s=%s %shint%s: %s\n",
				ANSI_BLUE, ANSI_RESET, ANSI_BOLD, ANSI_RESET, info.hint)
		} else {
			fmt.eprintf("  = hint: %s\n", info.hint)
		}
	}
	if len(info.ts_code) > 0 {
		if use_color {
			fmt.eprintf("  %s=%s %snote%s: see %s\n",
				ANSI_BLUE, ANSI_RESET, ANSI_BOLD, ANSI_RESET, info.ts_code)
		} else {
			fmt.eprintf("  = note: see %s\n", info.ts_code)
		}
	}
}

// render_snippet draws the source-line gutter + caret for the diagnostic
// span. Single-line spans get a contiguous caret underline; multi-line
// spans show start + ellipsis + end.
@(private="file")
render_snippet :: proc(
	source:       string,
	line_offsets: []u32,
	start_line:   u32,
	start_col:    u32,
	end_line:     u32,
	end_col:      u32,
	use_color:    bool,
) {
	gutter_w := digit_count(end_line)
	if gutter_w < 2 { gutter_w = 2 }

	// Divider (blank gutter, on its own line).
	emit_gutter(gutter_w, "", use_color)
	fmt.eprintf("\n")

	if start_line == end_line {
		render_source_line(source, line_offsets, start_line, gutter_w, use_color)
		under_w := int(end_col) - int(start_col)
		if under_w < 1 { under_w = 1 }
		caret_pad := int(start_col) - 1
		emit_gutter(gutter_w, "", use_color)
		fmt.eprintf(" ")
		emit_repeated(' ', caret_pad)
		if use_color { fmt.eprintf("%s", ANSI_BOLD_RED) }
		emit_repeated('^', under_w)
		if use_color { fmt.eprintf("%s", ANSI_RESET) }
		fmt.eprintf("\n")
	} else {
		render_source_line(source, line_offsets, start_line, gutter_w, use_color)
		line_len := source_line_len(source, line_offsets, start_line)
		under_w := int(line_len) - int(start_col) + 1
		if under_w < 1 { under_w = 1 }
		caret_pad := int(start_col) - 1
		emit_gutter(gutter_w, "", use_color)
		fmt.eprintf(" ")
		emit_repeated(' ', caret_pad)
		if use_color { fmt.eprintf("%s", ANSI_BOLD_RED) }
		emit_repeated('^', under_w)
		if use_color { fmt.eprintf("%s", ANSI_RESET) }
		fmt.eprintf("\n")
		if end_line > start_line + 1 {
			emit_gutter(gutter_w, "...", use_color)
			fmt.eprintf("\n")
		}
		render_source_line(source, line_offsets, end_line, gutter_w, use_color)
		emit_gutter(gutter_w, "", use_color)
		fmt.eprintf(" ")
		if use_color { fmt.eprintf("%s", ANSI_BOLD_RED) }
		end_carets := int(end_col) - 1
		if end_carets < 1 { end_carets = 1 }
		emit_repeated('^', end_carets)
		if use_color { fmt.eprintf("%s", ANSI_RESET) }
		fmt.eprintf("\n")
	}
}

// emit_gutter writes the `   |` (or `   | <suffix>`) prefix shared by
// every snippet line. `suffix` is appended after the bar (e.g. "..."
// for the elision row). The gutter itself renders dim when colored.
@(private="file")
emit_gutter :: proc(width: int, suffix: string, use_color: bool) {
	for _ in 0..<width { fmt.eprintf(" ") }
	if use_color {
		fmt.eprintf("%s |%s", ANSI_DIM, ANSI_RESET)
	} else {
		fmt.eprintf(" |")
	}
	if len(suffix) > 0 {
		fmt.eprintf(" %s", suffix)
	}
}

// render_source_line prints `<n> | <source-line text>\n`. Pads the
// line number with spaces (NOT zero-pad — Odin's `%*d` zero-pads).
@(private="file")
render_source_line :: proc(source: string, line_offsets: []u32, line: u32, gutter_w: int, use_color: bool) {
	if int(line) < 1 || int(line) > len(line_offsets) { return }
	start := line_offsets[line-1]
	end: u32
	if int(line) < len(line_offsets) {
		end = line_offsets[line]
	} else {
		end = u32(len(source))
	}
	for end > start && (source[end-1] == '\n' || source[end-1] == '\r') {
		end -= 1
	}
	text := source[start:end]

	num_str := fmt.tprintf("%d", line)
	pad := gutter_w - len(num_str)
	emit_repeated(' ', pad)
	if use_color {
		fmt.eprintf("%s%s |%s ", ANSI_DIM, num_str, ANSI_RESET)
	} else {
		fmt.eprintf("%s | ", num_str)
	}
	// Fast path: print the source slice in one write if it has no tabs
	// (the common case). Tabs need rewriting to spaces, so they take a
	// chunked path that still avoids the per-character syscall.
	if strings.contains_rune(text, '\t') {
		// Build a tab-rewritten copy in chunks so we don't allocate.
		buf: [REPEAT_CHUNK_SIZE]byte
		n := 0
		for i in 0..<len(text) {
			c := text[i]
			if c == '\t' { c = ' ' }
			buf[n] = c
			n += 1
			if n == REPEAT_CHUNK_SIZE {
				fmt.eprint(string(buf[:n]))
				n = 0
			}
		}
		if n > 0 { fmt.eprint(string(buf[:n])) }
	} else {
		fmt.eprint(text)
	}
	fmt.eprintf("\n")
}

@(private="file")
source_line_len :: proc(source: string, line_offsets: []u32, line: u32) -> u32 {
	if int(line) < 1 || int(line) > len(line_offsets) { return 0 }
	start := line_offsets[line-1]
	end: u32
	if int(line) < len(line_offsets) {
		end = line_offsets[line]
	} else {
		end = u32(len(source))
	}
	for end > start && (source[end-1] == '\n' || source[end-1] == '\r') {
		end -= 1
	}
	return end - start
}

@(private="file")
digit_count :: proc(n: u32) -> int {
	if n < 10      { return 1 }
	if n < 100     { return 2 }
	if n < 1000    { return 3 }
	if n < 10000   { return 4 }
	if n < 100000  { return 5 }
	if n < 1000000 { return 6 }
	return 7
}

// Referenced explicitly so `strings` stays imported for future helpers.
@(private="file")
_unused :: proc() { _ = strings.Builder{} }
