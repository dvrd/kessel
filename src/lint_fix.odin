package kessel

import "base:runtime"
import "core:fmt"
import "core:os"
import win32 "core:sys/windows"
import "core:sys/posix"
import "core:path/filepath"
import "core:slice"
import "core:strings"

LintFixKind :: enum u8 { Fix, Suggestion, Dangerous }
LintFixKinds :: bit_set[LintFixKind; u8]
LintFixKey :: struct { rule: LintRule, diagnostic: Loc }
LintEdit :: struct { span: Loc, replacement: string }
LintSuggestionKey :: struct { fix: LintFixKey, message: string }
LintSuggestion :: struct { edit: LintEdit, title: string }
LintFixResult :: struct { output: []u8, changed: bool }

// Parse every revision, including the last one, before giving it to a caller.
// The original string is borrowed. A changed result owns its output.
lint_fix_source :: proc(source, label: string, config: ParseConfig, settings: LintSettings, kinds: LintFixKinds) -> (LintFixResult, bool) {
	assert(kinds != {})
	MAX_PASSES :: 10
	result: LintFixResult
	current := source
	parse_config := lint_parse_config(label, config)
	for pass in 0..=MAX_PASSES {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		job: ParseJob
		if !parse_job_open_inline(&job, current, parse_config, label) {
			delete(result.output)
			return {}, false
		}
		defer parse_job_close(&job)
		parse_job_run(&job)
		if len(job.parser.errors) > 0 {
			delete(result.output)
			return {}, pass == 0
		}
		if pass == MAX_PASSES { return result, true }
		l := lint_run_for_job(&job, settings, kinds)
		next := lint_fix_apply(&l)
		if !next.changed { return result, true }
		delete(result.output)
		result = next
		current = string(result.output)
	}
	unreachable()
}

lint_fix_apply :: proc(l: ^Linter) -> LintFixResult {
	if len(l.fixes) == 0 { return {} }
	edits := make([dynamic]LintEdit, 0, len(l.fixes), l.allocator)
	// Suppression runs before this lookup. A disabled diagnostic cannot edit source.
	for d in l.diagnostics {
		edit, ok := l.fixes[{d.lint_code, {d.start, d.end}}]
		if !ok { continue }
		assert(edit.span.start < edit.span.end)
		assert(int(edit.span.end) <= len(l.source))
		append(&edits, edit)
	}
	if len(edits) == 0 { return {} }
	slice.sort_by(edits[:], proc(a, b: LintEdit) -> bool {
		if a.span.start != b.span.start { return a.span.start < b.span.start }
		if a.span.end != b.span.end { return a.span.end < b.span.end }
		return a.replacement < b.replacement
	})
	// Source order determines conflicts. A later pass can revisit a skipped edit.
	size := len(l.source)
	end: u32
	kept := 0
	for edit in edits {
		if edit.span.start < end { continue }
		size += len(edit.replacement) - int(edit.span.end - edit.span.start)
		end = edit.span.end
		edits[kept] = edit
		kept += 1
	}
	output := make([]u8, size)
	at := 0
	end = 0
	for edit in edits[:kept] {
		at += copy(output[at:], l.source[end:edit.span.start])
		at += copy(output[at:], edit.replacement)
		end = edit.span.end
	}
	at += copy(output[at:], l.source[end:])
	assert(at == size)
	return {output, true}
}

lint_fix_debugger :: proc(l: ^Linter, loc: Loc, required_body: bool) {
	key := LintFixKey{.L2001_NoDebugger, loc}
	text := l.source[loc.start:loc.end]
	if !strings.has_prefix(text, "debugger") { return }
	keyword_end := loc.start + len("debugger")
	if len(text) > len("debugger") && (strings.contains(text, "/") || codegen_has_line_break(text)) {
		// Keep intervening line breaks and comments, including lint directives.
		l.fixes[key] = {{loc.start, keyword_end}, ""}
		return
	}
	lint_fix_remove_statement(l, key, loc, required_body)
}

lint_fix_remove_statement :: proc(l: ^Linter, key: LintFixKey, loc: Loc, required_body: bool) {
	if required_body {
		l.fixes[key] = {loc, "{}"}
		return
	}
	before := strings.trim_right_space(l.source[:loc.start])
	after := strings.trim_left_space(l.source[loc.end:])
	replacement := ""
	if len(after) > 0 && after[0] != '}' {
		// Keep an empty statement when deletion might join expressions, expose
		// a directive prologue, or leave another comment hiding the next token.
		protected := len(before) == 0 || before[len(before)-1] == ';' || before[len(before)-1] == '{'
		if !protected || strings.index_byte("\"'/([`+-.<!?", after[0]) >= 0 {
			replacement = ";"
		}
	}
	l.fixes[key] = {loc, replacement}
}

// Resolve the final symlink too on systems where abs only expands the path.
lint_fix_target :: proc(file: string) -> (resolved: string, err: os.Error) {
	target := filepath.abs(file, context.temp_allocator) or_return
	for _ in 0..<40 {
		info := os.lstat(target, context.temp_allocator) or_return
		if info.type == .Regular { return target, nil }
		if info.type != .Symlink { return "", .Invalid_Path }
		link := os.read_link(target, context.temp_allocator) or_return
		if filepath.is_abs(link) { target = link; continue }
		target = filepath.join({filepath.dir(target), link}, context.temp_allocator) or_return
	}
	return "", .Invalid_Path
}

lint_fix_file :: proc(file: string, config: ParseConfig, settings: LintSettings, kinds: LintFixKinds) -> os.Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	target := lint_fix_target(file) or_return
	info := os.stat(target, context.temp_allocator) or_return
	data := os.read_entire_file(target, context.allocator) or_return
	defer delete(data)
	result, ok := lint_fix_source(string(data), file, config, settings, kinds)
	if !ok { return .Invalid_File }
	if !result.changed { return nil }
	defer delete(result.output)
	// Stage the complete edit in the target directory for an atomic rename.
	temp := os.create_temp_file(filepath.dir(target), ".kessel-fix-*") or_return
	name, alloc_err := strings.clone(os.name(temp), context.temp_allocator)
	if alloc_err != nil { os.close(temp); return alloc_err }
	renamed := false
	defer {
		if temp != nil { os.close(temp) }
		if !renamed { os.remove(name) }
	}
	if err := os.fchmod(temp, {.Read_User, .Write_User}); err != nil { return err }
	written := os.write(temp, result.output) or_return
	if written != len(result.output) { return .Short_Write }
	if err := lint_fix_file_metadata(target, temp, info.mode); err != nil { return err }
	if err := os.sync(temp); err != nil { return err }
	closed := os.close(temp)
	temp = nil
	if closed != nil { return closed }
	current := os.stat(target, context.temp_allocator) or_return
	if !os.same_file(info, current) || info.mode != current.mode { return .Invalid_File }
	latest := os.read_entire_file(target, context.allocator) or_return
	defer delete(latest)
	if string(data) != string(latest) { return .Invalid_File }
	resolved := lint_fix_target(file) or_return
	if resolved != target { return .Invalid_File }
	if err := os.rename(name, target); err != nil { return err }
	renamed = true
	return nil
}

lint_fix_directive_comment :: proc(l: ^Linter, loc: Loc, lines: []u32) -> LintEdit {
	first := lines[lint_offset_to_line(lines, loc.start)]
	following := lint_offset_to_line(lines, loc.end) + 1
	limit := u32(len(l.source))
	if following < len(lines) { limit = lines[following] }
	if strings.trim_space(l.source[first:loc.start]) == "" && strings.trim_space(l.source[loc.end:limit]) == "" {
		return {{first, limit}, ""}
	}
	// A block comment can separate two tokens or introduce an ASI line break.
	breaks := lint_fix_line_breaks(l, loc)
	if breaks != "" { return {loc, breaks} }
	if loc.start > 0 && int(loc.end) < len(l.source) {
		prev, next := l.source[loc.start-1], l.source[loc.end]
		if prev > ' ' && next > ' ' { return {loc, " "} }
	}
	return {loc, ""}
}

lint_fix_line_breaks :: proc(l: ^Linter, span: Loc) -> string {
	bytes := transmute([]u8)l.source[span.start:span.end]
	breaks := make([dynamic]u8, 0, 0, l.allocator)
	for i := 0; i < len(bytes); i += 1 {
		if bytes[i] == '\r' || bytes[i] == '\n' {
			append(&breaks, bytes[i])
		} else if bytes[i] == 0xE2 && is_ls_ps_at(bytes, i) {
			append(&breaks, ..bytes[i:i+3])
			i += 2
		}
	}
	return string(breaks[:])
}

// A directory rename cannot update the other names of a multiply linked inode.
lint_fix_file_metadata :: proc(target: string, temp: ^os.File, mode: os.Permissions) -> os.Error {
	original := os.open(target, {.Read, .Write}) or_return
	defer os.close(original)
	links: u64 = 1
	when ODIN_OS == .Windows {
		info: win32.BY_HANDLE_FILE_INFORMATION
		if !win32.GetFileInformationByHandle(win32.HANDLE(os.fd(original)), &info) { return .Invalid_File }
		links = u64(info.nNumberOfLinks)
	} else when ODIN_OS == .Darwin || ODIN_OS == .Linux || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
		source, dest: posix.stat_t
		if posix.fstat(posix.FD(os.fd(original)), &source) != .OK { return .Invalid_File }
		if posix.fstat(posix.FD(os.fd(temp)), &dest) != .OK { return .Invalid_File }
		links = u64(source.st_nlink)
		if source.st_uid != dest.st_uid || source.st_gid != dest.st_gid {
			if err := os.fchown(temp, int(source.st_uid), int(source.st_gid)); err != nil { return err }
		}
	}
	if links != 1 {
		fmt.eprintf("Cannot replace %s because it has %d hard links.\n", target, links)
		return .Unsupported
	}
	when ODIN_OS == .Darwin {
		if !lint_fix_copy_attributes(original, temp) { return .Invalid_File }
	}
	return os.fchmod(temp, mode & (os.Permissions_Execute_All + os.Permissions_Read_Write_All))
}
