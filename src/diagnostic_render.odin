package kessel

import "core:fmt"
import "core:strings"

// ============================================================================
// Pretty diagnostic renderer — rustc-style.
//
// Goal: print a diagnostic with the source line context and a caret,
// like rustc / tsc / oxc. Triggered by `--pretty`.
//
// Output shape (one diagnostic):
//
//   error[K3011]: 'await' is only allowed within async functions and at the top levels of modules
//     --> tests/fixtures/await.mjs:2:3
//      |
//    2 |   await fetch('/');
//      |   ^^^^^ here
//      |
//      = hint: `await` is only valid inside `async function` or at top-level of a Module
//      = note: see TS1308
//
// Multiple diagnostics print as separate blocks separated by blank lines.
// When stdout is not a TTY we emit ASCII fallbacks (no box-drawing) so
// the output stays diffable in CI logs.
//
// This is intentionally simple — no color, no fancy alignment beyond
// the line number gutter. Zero new dependencies (just `core:fmt` and
// `core:strings`, which the rest of kessel already uses).
//
// Performance note: pretty rendering is opt-in and only fires when a
// human is reading the output. It allocates into the parse-job's temp
// allocator (same as fmt.tprintf elsewhere in the parser) — no impact
// on the hot --compact / batch / --raw paths.
// ============================================================================

// render_pretty_diagnostics writes a rustc-style block per diagnostic
// to `w`. Caller passes the source bytes, the file path (for the
// `-->` header), the line-offset table (from the lexer), and the
// diagnostic list. Writes nothing when the list is empty.
//
// `use_box` controls the line-gutter style: true uses `|` and `-->`
// (ASCII — works everywhere); reserved for a future Unicode variant.
render_pretty_diagnostics :: proc(
	source:      string,
	path:        string,
	line_offsets: []u32,
	errors:      []ParseError,
) {
	if len(errors) == 0 { return }

	for err, idx in errors {
		if idx > 0 { fmt.eprintln() }
		render_one(source, path, line_offsets, err)
	}
}

// render_one prints a single diagnostic block. Factored out so the
// per-diagnostic shape is one contiguous routine.
@(private="file")
render_one :: proc(
	source:      string,
	path:        string,
	line_offsets: []u32,
	err:         ParseError,
) {
	info := error_info(err.code)
	sev  := severity_string(err.severity)
	code := error_code_string(err.code)

	line, col := offset_to_line_col(line_offsets, err.start)
	end_line, end_col := offset_to_line_col(line_offsets, err.end if err.end > err.start else err.start + 1)

	// Header: `error[K3011]: message`
	if len(code) > 0 {
		fmt.eprintf("%s[%s]: %s\n", sev, code, err.message)
	} else {
		fmt.eprintf("%s: %s\n", sev, err.message)
	}

	// Location: `  --> path:line:col`
	fmt.eprintf("  --> %s:%d:%d\n", path, line, col)

	// Source snippet + caret
	render_snippet(source, line_offsets, line, col, end_line, end_col)

	// Hint and TS-code notes (info-from-table)
	if len(info.hint) > 0 {
		fmt.eprintf("  = hint: %s\n", info.hint)
	}
	if len(info.ts_code) > 0 {
		fmt.eprintf("  = note: see %s\n", info.ts_code)
	}
}

// render_snippet draws the source-line gutter for the diagnostic span.
// For single-line spans the caret underlines the offending range.
// For multi-line spans the start line gets a left-caret marker and
// subsequent lines are elided (`...`); the end line gets a right-caret
// marker. A line-number gutter aligns to the widest line number.
@(private="file")
render_snippet :: proc(
	source:      string,
	line_offsets: []u32,
	start_line:  u32,
	start_col:   u32,
	end_line:    u32,
	end_col:     u32,
) {
	// Gutter width = the line-number digit count.
	gutter_w := digit_count(end_line)
	if gutter_w < 2 { gutter_w = 2 }

	// Blank divider before the snippet
	for _ in 0..<gutter_w { fmt.eprintf(" ") }
	fmt.eprintf(" |\n")

	if start_line == end_line {
		// Single-line: print the line + caret underneath
		render_source_line(source, line_offsets, start_line, gutter_w)
		// Caret line: `      |   ^^^^^ here`
		// col is 1-based; the underline width is end_col - start_col,
		// minimum 1 character.
		under_w := int(end_col) - int(start_col)
		if under_w < 1 { under_w = 1 }
		caret_pad := int(start_col) - 1
		for _ in 0..<gutter_w { fmt.eprintf(" ") }
		fmt.eprintf(" | ")
		for _ in 0..<caret_pad { fmt.eprintf(" ") }
		for _ in 0..<under_w   { fmt.eprintf("^") }
		fmt.eprintf("\n")
	} else {
		// Multi-line: show first line with caret to end-of-line, ellipsis,
		// then last line with caret from start-of-line.
		render_source_line(source, line_offsets, start_line, gutter_w)
		line_len := source_line_len(source, line_offsets, start_line)
		under_w := int(line_len) - int(start_col) + 1
		if under_w < 1 { under_w = 1 }
		caret_pad := int(start_col) - 1
		for _ in 0..<gutter_w { fmt.eprintf(" ") }
		fmt.eprintf(" | ")
		for _ in 0..<caret_pad { fmt.eprintf(" ") }
		for _ in 0..<under_w   { fmt.eprintf("^") }
		fmt.eprintf("\n")
		if end_line > start_line + 1 {
			for _ in 0..<gutter_w { fmt.eprintf(" ") }
			fmt.eprintf(" | ...\n")
		}
		render_source_line(source, line_offsets, end_line, gutter_w)
		for _ in 0..<gutter_w { fmt.eprintf(" ") }
		fmt.eprintf(" | ")
		// underline from column 1 to end_col
		for _ in 0..<(int(end_col) - 1) { fmt.eprintf("^") }
		if int(end_col) <= 1 { fmt.eprintf("^") }
		fmt.eprintf("\n")
	}
}

// render_source_line prints `<n> | <source line text>\n`. Handles
// tabs by replacing them with a single space (so caret alignment stays
// sensible without doing a full tab-stop computation).
@(private="file")
render_source_line :: proc(source: string, line_offsets: []u32, line: u32, gutter_w: int) {
	if int(line) < 1 || int(line) > len(line_offsets) { return }
	start := line_offsets[line-1]
	end: u32
	if int(line) < len(line_offsets) {
		end = line_offsets[line]
	} else {
		end = u32(len(source))
	}
	// Strip trailing \n / \r
	for end > start && (source[end-1] == '\n' || source[end-1] == '\r') {
		end -= 1
	}
	text := source[start:end]
	// Format the line number with space padding (NOT zero padding).
	// Odin's `%*d` zero-pads, so we build the string manually.
	num_str := fmt.tprintf("%d", line)
	pad := gutter_w - len(num_str)
	for _ in 0..<pad { fmt.eprintf(" ") }
	fmt.eprintf("%s | ", num_str)
	// Replace tabs with a single space for caret-alignment stability.
	for ch in text {
		if ch == '\t' { fmt.eprintf(" ") }
		else          { fmt.eprintf("%c", ch) }
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

// _suppress_unused — `strings` is imported for future use (Unicode
// width measurement, dim-color helpers). Reference it explicitly so
// the build doesn't whine about an unused import.
@(private="file")
_unused :: proc() { _ = strings.Builder{} }
