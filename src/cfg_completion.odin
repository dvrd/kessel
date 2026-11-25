package kessel

import "core:mem"

// A statement may complete in several ways. A following statement executes
// only on Next. An empty set describes a path that never leaves the statement.
CfgExit :: enum u8 {Next, Return_Value, Return_Empty, Throw, Break, Continue, Unknown}
CfgPaths :: bit_set[CfgExit; u8]

CfgVisit :: struct {
	statement: ^Statement,
	body: []^Statement,
}

CfgStage :: enum u8 {
	Sequence, Alternative, Merge, Switch, Loop, Label, Try_Body, Catch_Body, Finally_Body,
}

CfgLoopTest :: enum u8 {Never, Maybe, Always}

CfgFlowFrame :: struct {
	stage: CfgStage,
	statement: ^Statement,
	remaining: []^Statement,
	paths: CfgPaths,
	// A finalizer can replace all transfers produced since entry into the try.
	jump_base, protected_end: int,
	case_index: int,
	has_default: bool,
	loop_test: CfgLoopTest,
	loop_pretest, loop_test_throws: bool,
}

CfgNamedJump :: struct { label: string, is_continue: bool }

CfgWalk :: struct {
	frames: []CfgFlowFrame,
	depth: int,
	jumps: [dynamic]CfgNamedJump,
}

// Statement lists used by switch and try can add one frame per syntax level.
// A fixed stack avoids consuming the native call stack in nested user code.
cfg_completion :: proc(root: CfgVisit, alloc: mem.Allocator) -> CfgPaths {
	frames: [2 * PARSE_RESOURCE_AST_DEPTH + 2]CfgFlowFrame = ---
	walk := CfgWalk{frames = frames[:], jumps = make([dynamic]CfgNamedJump, 0, 0, alloc)}
	defer delete(walk.jumps)
	current := root
	paths: CfgPaths
	visit: for {
		if walk.depth == len(frames) { return {.Next, .Unknown} }
		if cfg_flow_enter(&walk, &current, &paths) { continue }
		for walk.depth > 0 {
			if cfg_flow_resume(&walk, &current, &paths) { continue visit }
			walk.depth -= 1
		}
		return paths
	}
}

@(private="file")
cfg_expression_throws :: proc(expr: ^Expression) -> CfgPaths {
	if expr == nil { return {} }
	#partial switch node in expr^ {
	case ^BooleanLiteral, ^NumericLiteral, ^NullLiteral, ^StringLiteral, ^BigIntLiteral,
	     ^RegExpLiteral, ^FunctionExpression, ^ArrowFunctionExpression: return {}
	}
	return {.Throw}
}

@(private="file")
cfg_declaration_throws :: proc(declaration: ^VariableDeclaration) -> CfgPaths {
	assert(declaration != nil)
	// Resource registration and disposal can throw even with a literal initializer.
	if declaration.kind == .Using || declaration.kind == .AwaitUsing { return {.Throw} }
	for binding in declaration.declarations {
		if _, simple := binding.id.(^Identifier); !simple { return {.Throw} }
		if init, present := binding.init.?; present && .Throw in cfg_expression_throws(init) { return {.Throw} }
	}
	return {}
}

@(private)
cfg_loop_test :: proc(test: ^Expression) -> CfgLoopTest {
	if test != nil {
		if literal, ok := test^.(^BooleanLiteral); ok && literal != nil { return .Always if literal.value else .Never }
	}
	return .Maybe
}

@(private="file")
cfg_flow_enter :: proc(walk: ^CfgWalk, current: ^CfgVisit, paths: ^CfgPaths) -> bool {
	assert(walk.depth < len(walk.frames))
	frame := &walk.frames[walk.depth]
	frame^ = {statement = current.statement, jump_base = len(walk.jumps)}
	next: CfgVisit
	paths^ = {.Next}
	if current.statement == nil {
		if len(current.body) == 0 { return false }
		frame.stage, frame.remaining = .Sequence, current.body[1:]
		next.statement = current.body[0]
	} else {
		if statement_inner_nil(current.statement) { paths^ = {.Next, .Unknown}; return false }
		#partial switch node in current.statement^ {
		case ^BlockStatement: next.body = node.body[:]; frame.stage = .Merge
		case ^IfStatement:
			frame.stage, frame.paths = .Alternative, cfg_expression_throws(node.test)
			next.statement = node.consequent
		case ^SwitchStatement:
			frame.stage, frame.paths = .Switch, cfg_expression_throws(node.discriminant)
			if len(node.cases) == 0 { paths^ += frame.paths; return false }
			next.body = cfg_flow_case(frame, &node.cases[0])
		case ^TryStatement: frame.stage = .Try_Body; next.body = node.block.body[:]
		case ^LabeledStatement: frame.stage = .Label; next.statement = node.body
		case ^WithStatement: frame.stage, frame.paths = .Merge, {.Throw}; next.statement = node.body
		case ^WhileStatement, ^DoWhileStatement, ^ForStatement, ^ForInStatement, ^ForOfStatement:
			next.statement = cfg_flow_open_loop(frame)
			// The editor can supply an unfinished loop while its body is being typed.
			if statement_inner_nil(next.statement) { paths^ = {.Next, .Unknown}; return false }
			if frame.loop_pretest && frame.loop_test == .Never { paths^ += frame.paths; return false }
		case ^ReturnStatement:
			if arg, ok := node.argument.?; ok { paths^ = {.Return_Value}; paths^ += cfg_expression_throws(arg) }
			else { paths^ = {.Return_Empty} }
			return false
		case ^ThrowStatement: paths^ = {.Throw}; return false
		case ^BreakStatement:
			if label, ok := node.label.?; ok { append(&walk.jumps, CfgNamedJump{label.name, false}); paths^ = {} }
			else { paths^ = {.Break} }
			return false
		case ^ContinueStatement:
			if label, ok := node.label.?; ok { append(&walk.jumps, CfgNamedJump{label.name, true}); paths^ = {} }
			else { paths^ = {.Continue} }
			return false
		case ^EmptyStatement, ^FunctionDeclaration, ^DebuggerStatement: return false
		case ^ExpressionStatement: paths^ += cfg_expression_throws(node.expression); return false
		case ^VariableDeclaration: paths^ += cfg_declaration_throws(node); return false
		case: paths^ += {.Throw}; return false
		}
	}
	current^ = next
	walk.depth += 1
	return true
}

@(private="file")
cfg_flow_case :: proc(frame: ^CfgFlowFrame, clause: ^SwitchCase) -> []^Statement {
	assert(frame.stage == .Switch)
	if test, ok := clause.test.?; ok { frame.paths += cfg_expression_throws(test) }
	else { frame.has_default = true }
	frame.case_index += 1
	return clause.consequent[:]
}

@(private="file")
cfg_flow_open_loop :: proc(frame: ^CfgFlowFrame) -> ^Statement {
	assert(frame.statement != nil)
	frame.stage, frame.loop_pretest, frame.loop_test = .Loop, true, .Maybe
	test, update: ^Expression
	body: ^Statement
	#partial switch node in frame.statement^ {
	case ^ForStatement:
		body = node.body
		test, _ = node.test.?
		update, _ = node.update.?
		if init, ok := node.init_expr.?; ok { frame.paths += cfg_expression_throws(init) }
		if decl, ok := node.init_decl.?; ok && decl != nil { frame.paths += cfg_declaration_throws(decl) }
		if test == nil { frame.loop_test = .Always }
	case ^WhileStatement: test, body = node.test, node.body
	case ^DoWhileStatement: test, body, frame.loop_pretest = node.test, node.body, false
	case ^ForOfStatement: frame.paths = {.Throw}; return node.body
	case ^ForInStatement: frame.paths = {.Throw}; return node.body
	}
	if test != nil { frame.loop_test = cfg_loop_test(test) }
	test_throws := cfg_expression_throws(test)
	frame.loop_test_throws = .Throw in (test_throws + cfg_expression_throws(update))
	if frame.loop_pretest { frame.paths += test_throws }
	return body
}

// Remove only jumps produced inside this frame. Sibling branches and outer
// labels may have the same spelling without sharing a destination.
@(private="file")
cfg_take_jumps :: proc(walk: ^CfgWalk, base: int, label: string, is_continue: bool) -> bool {
	assert(base <= len(walk.jumps))
	write := base
	for jump in walk.jumps[base:] {
		if jump.label == label && jump.is_continue == is_continue { continue }
		walk.jumps[write] = jump
		write += 1
	}
	taken := write != len(walk.jumps)
	resize(&walk.jumps, write)
	return taken
}

@(private="file")
cfg_flow_close_loop :: proc(walk: ^CfgWalk, frame: ^CfgFlowFrame, paths: CfgPaths) -> CfgPaths {
	assert(frame.stage == .Loop)
	repeats := .Next in paths || .Continue in paths
	// Consecutive labels immediately before the loop all name this iteration.
	for i := walk.depth - 2; i >= 0; i -= 1 {
		parent := &walk.frames[i]
		if parent.stage != .Label { break }
		label := parent.statement^.(^LabeledStatement).label.name
		if cfg_take_jumps(walk, frame.jump_base, label, true) { repeats = true }
	}
	result := (paths - {.Break, .Continue, .Next}) + frame.paths
	if .Break in paths { result += {.Next} }
	if frame.loop_test != .Always && (frame.loop_pretest || repeats) { result += {.Next} }
	if repeats && frame.loop_test_throws { result += {.Throw} }
	return result
}

@(private="file")
cfg_flow_try :: proc(walk: ^CfgWalk, frame: ^CfgFlowFrame, next: ^CfgVisit, paths: ^CfgPaths) -> bool {
	node := frame.statement^.(^TryStatement)
	if frame.stage == .Finally_Body {
		if .Next in paths^ { paths^ = (paths^ - {.Next}) + frame.paths }
		else {
			// This finalizer never resumes the incoming return, throw or jump.
			assert(frame.protected_end <= len(walk.jumps))
			saved := copy(walk.jumps[frame.jump_base:], walk.jumps[frame.protected_end:])
			resize(&walk.jumps, frame.jump_base + saved)
		}
		return false
	}
	if frame.stage == .Try_Body {
		if handler, ok := node.handler.?; ok && .Throw in paths^ {
			frame.stage, frame.paths = .Catch_Body, paths^ - {.Throw}
			// Binding the caught exception through destructuring can itself throw.
			if pat, bound := handler.param.?; bound {
				if _, simple := pat.(^Identifier); !simple { frame.paths += {.Throw} }
			}
			next^ = {body = handler.body.body[:]}
			return true
		}
	} else {
		assert(frame.stage == .Catch_Body)
		paths^ += frame.paths
	}
	if finalizer, ok := node.finalizer.?; ok && (paths^ != {} || len(walk.jumps) > frame.jump_base) {
		frame.stage, frame.paths, frame.protected_end = .Finally_Body, paths^, len(walk.jumps)
		next^ = {body = finalizer.body[:]}
		return true
	}
	return false
}

@(private="file")
cfg_flow_resume :: proc(walk: ^CfgWalk, next: ^CfgVisit, paths: ^CfgPaths) -> bool {
	assert(walk.depth > 0)
	frame := &walk.frames[walk.depth-1]
	switch frame.stage {
	case .Sequence:
		frame.paths = (frame.paths - {.Next}) + paths^
		if .Next in paths^ && len(frame.remaining) > 0 {
			next^ = {statement = frame.remaining[0]}
			frame.remaining = frame.remaining[1:]
			return true
		}
		paths^ = frame.paths
	case .Alternative:
		frame.paths += paths^
		if alternate, ok := frame.statement^.(^IfStatement).alternate.?; ok {
			frame.stage, next^ = .Merge, {statement = alternate}
			return true
		}
		paths^ = frame.paths + {.Next}
	case .Merge: paths^ += frame.paths
	case .Label:
		label := frame.statement^.(^LabeledStatement).label.name
		if cfg_take_jumps(walk, frame.jump_base, label, false) { paths^ += {.Next} }
	case .Loop: paths^ = cfg_flow_close_loop(walk, frame, paths^)
	case .Switch:
		clauses := frame.statement^.(^SwitchStatement).cases[:]
		frame.paths += paths^ - {.Next}
		if frame.case_index < len(clauses) {
			next^ = {body = cfg_flow_case(frame, &clauses[frame.case_index])}
			return true
		}
		if .Break in frame.paths || !frame.has_default { paths^ += {.Next} }
		paths^ = (frame.paths + paths^) - {.Break}
	case .Try_Body, .Catch_Body, .Finally_Body: return cfg_flow_try(walk, frame, next, paths)
	}
	return false
}
