package kessel

import "core:encoding/json"
import "core:mem"
import "core:strings"

lint_console_options :: proc(options: []json.Value, allocator: mem.Allocator) -> (map[string]bool, bool) {
	if len(options) == 0 { return nil, true }
	if len(options) != 1 { return nil, false }
	object, ok := options[0].(json.Object)
	if !ok { return nil, false }
	if len(object) == 0 { return nil, true }
	names, valid := object["allow"].(json.Array)
	if !valid || len(object) != 1 { return nil, false }
	allowed := make(map[string]bool, len(names), allocator)
	for value in names {
		name, is_string := value.(json.String)
		if !is_string { return nil, false }
		allowed[string(name)] = true
	}
	return allowed, true
}

// Keep the receiver offset until semantic analysis has resolved its binding.
// Two identically spelled receivers on the same line can belong to different scopes.
lint_queue_console_member :: proc(l: ^Linter, member: ^MemberExpression) {
	assert(member != nil)
	if l.console_members == nil || member.object == nil || member.property == nil { return }
	receiver := semantic_runtime_expression(member.object)
	if receiver == nil { return }
	id, named := receiver^.(^Identifier)
	if !named || id == nil || id.name != "console" { return }
	span := get_expression_loc(member.property)
	name: string
	if member.computed {
		#partial switch property in member.property^ {
		case ^RegExpLiteral: name = l.source[span.start:span.end]
		case ^TemplateLiteral, ^StringLiteral:
			value, constant := lint_constant_string(member.property)
			if !constant { return }
			name = value
		case: return
		}
	} else {
		property, ok := member.property^.(^Identifier)
		if !ok || property == nil { return }
		name = property.name
	}
	if l.console_allow[name] { return }
	assert(id.loc.start < span.end)
	l.console_members[id.loc.start] = {member.loc.start, span.end}
}

LintConsolePosition :: enum { Statement, Required_Body, Arrow_Body, Value }

// A member read or write still gets a diagnostic. Only a direct call can be
// removed, and the shared fixer later admits edits for surviving diagnostics.
lint_fix_console_call :: proc(l: ^Linter, expression: ^Expression, span: Loc, position: LintConsolePosition) {
	if len(l.console_members) == 0 { return }
	inner := semantic_runtime_expression(expression)
	if inner == nil { return }
	call, invoked := inner^.(^CallExpression)
	if !invoked || call == nil { return }
	callee := semantic_runtime_expression(call.callee)
	if callee == nil { return }
	member, named := callee^.(^MemberExpression)
	if !named || member == nil { return }
	receiver := semantic_runtime_expression(member.object)
	if receiver == nil { return }
	id, valid := receiver^.(^Identifier)
	if !valid || id == nil { return }
	loc, found := l.console_members[id.loc.start]
	if !found || loc.end != get_expression_loc(member.property).end { return }
	key := LintFixKey{.L4037_NoConsole, loc}
	edit := LintEdit{span, "(void 0)"}
	if position == .Arrow_Body { edit = lint_console_arrow_edit(l.source, get_expression_loc(expression), span.end) }
	// Deleting an embedded directive could change warnings elsewhere in the file.
	first := codegen_comment_lower_bound(l.comments, edit.span.start)
	if first < len(l.comments) && l.comments[first].start < edit.span.end { return }
	switch position {
	case .Statement, .Required_Body: lint_fix_remove_statement(l, key, span, position == .Required_Body)
	case .Arrow_Body, .Value:
		// void 0 still means undefined when a local binding shadows that name.
		l.fixes[key] = edit
	}
}

// The parser can omit grouping nodes. Replacing only the call inside
// () => (call()) with {} would return a new object instead of undefined.
lint_console_arrow_edit :: proc(source: string, body: Loc, arrow_end: u32) -> LintEdit {
	assert(body.start < body.end)
	assert(body.end <= arrow_end)
	before := source[:body.start]
	after := strings.trim_space(source[body.end:arrow_end])
	for len(after) != 0 {
		before = strings.trim_right_space(before)
		if after[0] != ')' || len(before) == 0 || before[len(before)-1] != '(' {
			// A comment can separate the parentheses from the body. Keep it in place.
			return {body, "(void 0)"}
		}
		before = before[:len(before)-1]
		after = strings.trim_left_space(after[1:])
	}
	return {{u32(len(before)), arrow_end}, "{}"}
}
