package kessel

import "core:fmt"
import "core:unicode"
import "core:unicode/utf8"

// Only a function that renders multiple times needs the same hook order on each render.
LintHookOwner :: enum { Top, Anonymous, Component, Ordinary, Callback, Class }
LintHookPath :: enum { Always, Conditional, Repeated, Unreachable }
LintHookBinding :: struct { name: string, owner: LintHookOwner, assignment_pattern: bool }
LintHookLabel :: struct { parent: ^LintHookLabel, name: string, breaks: u32 }
LintHookFrame :: struct {
	owner: LintHookOwner,
	name: string,
	inside_component: bool,
	async: bool,
	async_arrow: Loc,
	path: LintHookPath,
	returns: u32,
	breaks: u32,
	label: ^LintHookLabel,
}

lint_hook_name :: proc(name: string) -> bool {
	if len(name) < 3 || name[:3] != "use" { return false }
	if len(name) == 3 { return true }
	next, _ := utf8.decode_rune_in_string(name[3:])
	return unicode.is_upper(next) || ('0' <= next && next <= '9')
}

lint_hook_callee :: proc(callee: ^Expression) -> (name, namespace: string) {
	if callee == nil { return }
	#partial switch e in callee^ {
	case ^Identifier:
		return e.name, ""
	case ^MemberExpression:
		if e.computed || e.object == nil || e.property == nil { return }
		object, named := e.object^.(^Identifier)
		property, direct := e.property^.(^Identifier)
		if !named || !direct || len(object.name) == 0 { return }
		first, _ := utf8.decode_rune_in_string(object.name)
		if unicode.is_upper(first) { return property.name, object.name }
	}
	return
}

lint_hook_frame :: proc(parent: ^LintHookFrame, binding: LintHookBinding, explicit: string, async: bool) -> LintHookFrame {
	name := explicit if explicit != "" else binding.name
	owner := binding.owner
	if owner != .Class && name != "" {
		owner = .Ordinary
		if ('A' <= name[0] && name[0] <= 'Z') || lint_hook_name(name) { owner = .Component }
	}
	return {owner=owner, name=name, async=async, inside_component=parent.inside_component || owner == .Component}
}

lint_check_react_hook :: proc(l: ^Linter, frame: ^LintHookFrame, call: ^CallExpression) {
	name, namespace := lint_hook_callee(call.callee)
	if !lint_hook_name(name) { return }
	special_use := name == "use" && (namespace == "" || namespace == "React")
	loc := call.loc
	message: string
	switch frame.owner {
	case .Top:
		message = fmt.tprintf("React Hook %q cannot be called at the top level.", name)
	case .Class:
		message = fmt.tprintf("React Hook %q cannot be called in a class component.", name)
	case .Ordinary:
		loc = get_expression_loc(call.callee)
		message = fmt.tprintf("React Hook %q is called in function %q. Use a React component or a custom Hook.", name, frame.name)
	case .Callback:
		if special_use || !frame.inside_component { return }
		message = fmt.tprintf("React Hook %q cannot be called inside a callback.", name)
	case .Anonymous, .Component:
		if frame.async {
			if frame.async_arrow.end > frame.async_arrow.start { loc = frame.async_arrow }
			message = fmt.tprintf("React Hook %q cannot be called in an async function.", name)
		} else if !special_use {
			switch frame.path {
			case .Conditional:
				message = fmt.tprintf("React Hook %q is called conditionally. React Hooks must be called in the same order on every render.", name)
			case .Repeated:
				message = fmt.tprintf("React Hook %q may run more than once in a loop.", name)
			case .Always, .Unreachable:
			}
		}
	}
	if message != "" { lint_report(l, loc.start, loc.end, .L4107_RulesOfHooks, message) }
}

lint_walk_hook_expr :: proc(l: ^Linter, ctx: ^LintContext, expr: ^Expression, path: LintHookPath) {
	if ctx.hooks == nil { lint_walk_expr(l, ctx, expr); return }
	previous := ctx.hooks.path
	defer ctx.hooks.path = previous
	ctx.hooks.path = max(previous, path)
	lint_walk_expr(l, ctx, expr)
}

lint_walk_hook_stmt :: proc(l: ^Linter, ctx: ^LintContext, stmt: ^Statement, path: LintHookPath) {
	if ctx.hooks == nil { lint_walk_stmt(l, ctx, stmt, true); return }
	previous := ctx.hooks.path
	defer ctx.hooks.path = previous
	ctx.hooks.path = max(previous, path)
	lint_walk_stmt(l, ctx, stmt, true)
}

// A return in one branch bypasses all subsequent hooks. An exception alone does
// not complete a render. Function entry resets both the path and return count.
lint_walk_stmt_list :: proc(l: ^Linter, ctx: ^LintContext, body: []^Statement, path := LintHookPath.Always) {
	lint_check_no_unreachable(l, body)
	if ctx.hooks == nil {
		for stmt in body { lint_walk_stmt(l, ctx, stmt) }
		return
	}
	previous := ctx.hooks.path
	defer ctx.hooks.path = previous
	ctx.hooks.path = max(previous, path)
	for stmt in body {
		returns := ctx.hooks.returns
		breaks := ctx.hooks.breaks
		lint_walk_stmt(l, ctx, stmt)
		if cfg_is_terminator(stmt, l.allocator) { ctx.hooks.path = .Unreachable }
		else if returns != ctx.hooks.returns || breaks != ctx.hooks.breaks { ctx.hooks.path = max(ctx.hooks.path, .Conditional) }
	}
}

// A named break can skip hooks in the label's body. Calls after that body
// remain on the same path even if an inner block branched to the label.
lint_hook_label_body :: proc(l: ^Linter, ctx: ^LintContext, stmt: ^LabeledStatement) {
	if ctx.hooks == nil { lint_walk_stmt(l, ctx, stmt.body, true); return }
	frame := ctx.hooks
	label := LintHookLabel{parent=frame.label, name=stmt.label.name}
	frame.label = &label
	lint_walk_stmt(l, ctx, stmt.body, true)
	assert(frame.label == &label)
	assert(frame.breaks >= label.breaks)
	frame.breaks -= label.breaks
	frame.label = label.parent
}

lint_hook_break :: proc(frame: ^LintHookFrame, stmt: ^BreakStatement) {
	if frame == nil || stmt == nil || frame.path == .Unreachable { return }
	name, named := stmt.label.?
	if !named { return }
	for target := frame.label; target != nil; target = target.parent {
		if target.name == name.name {
			target.breaks += 1
			frame.breaks += 1
			return
		}
	}
}

// Paths that unconditionally throw never finish a render. Recognize straight-line
// blocks ending in a throw, stopping when an earlier statement could divert control.
lint_hook_opposite_path :: proc(frame: ^LintHookFrame, opposite: ^Statement) -> LintHookPath {
	if frame == nil { return .Conditional }
	for stmt := opposite; stmt != nil; {
		#partial switch v in stmt^ {
		case ^ThrowStatement: return .Always
		case ^BlockStatement:
			if v == nil || len(v.body) == 0 { return .Conditional }
			for item in v.body[:len(v.body)-1] {
				if item == nil { return .Conditional }
				#partial switch _ in item^ {
				case ^ExpressionStatement, ^VariableDeclaration, ^EmptyStatement:
				case: return .Conditional
				}
			}
			stmt = v.body[len(v.body)-1]
		case: return .Conditional
		}
	}
	return .Conditional
}

lint_hook_arguments :: proc(l: ^Linter, ctx: ^LintContext, call: ^CallExpression) {
	if ctx.hooks == nil {
		for arg in call.arguments { lint_walk_expr(l, ctx, arg) }
		return
	}
	name, namespace := lint_hook_callee(call.callee)
	binding := LintHookBinding{owner=.Callback}
	if (namespace == "" || namespace == "React") && (name == "memo" || name == "forwardRef") {
		binding.owner = .Component
	}
	for arg in call.arguments { lint_walk_expr(l, ctx, arg, binding) }
}
