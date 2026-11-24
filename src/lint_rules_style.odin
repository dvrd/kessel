package kessel

// Small statement and expression rules outside oxlint's default set.

// no-empty: a block with neither statements nor comments, and a switch
// without cases. Function bodies are not blocks.
lint_check_no_empty :: proc(l: ^Linter, stmt: ^Statement) {
	if !lint_rule_enabled(l, .L1001_NoEmpty) { return }
	#partial switch node in stmt^ {
	case ^BlockStatement: lint_check_empty_block(l, node, false)
	case ^SwitchStatement:
		if len(node.cases) == 0 { lint_emit(l, node.loc, .L1001_NoEmpty) }
	case ^TryStatement:
		// The tree stores these three blocks by value, so the walk never
		// visits them as statements.
		lint_check_empty_block(l, &node.block, false)
		if handler, present := &node.handler.?; present { lint_check_empty_block(l, &handler.body, true) }
		if finalizer, present := &node.finalizer.?; present { lint_check_empty_block(l, finalizer, false) }
	}
}

lint_check_empty_block :: proc(l: ^Linter, block: ^BlockStatement, catch_body: bool) {
	if len(block.body) != 0 || (catch_body && l.options.empty_allow_catch) { return }
	if lint_has_comment_between(l, block.loc.start, block.loc.end) { return }
	lint_emit(l, block.loc, .L1001_NoEmpty)
}

// no-case-declarations reports the declaration keyword.
lint_check_case_declarations :: proc(l: ^Linter, v: ^SwitchStatement) {
	if !lint_rule_enabled(l, .L2025_NoCaseDeclarations) { return }
	for clause in v.cases {
		for stmt in clause.consequent {
			if stmt == nil { continue }
			#partial switch node in stmt^ {
			case ^FunctionDeclaration: lint_emit(l, {node.loc.start, node.loc.start + 8}, .L2025_NoCaseDeclarations)
			case ^ClassDeclaration:    lint_emit(l, {node.loc.start, node.loc.start + 5}, .L2025_NoCaseDeclarations)
			case ^VariableDeclaration:
				length: u32
				switch node.kind {
				case .Var:          continue
				case .Let:          length = 3
				case .Const, .Using: length = 5
				case .AwaitUsing:
					if len(node.declarations) == 0 { continue }
					end := node.declarations[0].loc.start
					for end > node.loc.start && lint_is_space(l.source[end - 1]) { end -= 1 }
					length = end - node.loc.start
				}
				lint_emit(l, {node.loc.start, node.loc.start + length}, .L2025_NoCaseDeclarations)
			}
		}
	}
}

// default-case-last reports the `default` keyword of a misplaced clause.
lint_check_default_case_last :: proc(l: ^Linter, v: ^SwitchStatement) {
	if v == nil || len(v.cases) < 2 || !lint_rule_enabled(l, .L4031_DefaultCaseLast) { return }
	for clause in v.cases[:len(v.cases) - 1] {
		if clause.test != nil { continue }
		lint_emit(l, {clause.loc.start, clause.loc.start + 7}, .L4031_DefaultCaseLast)
		return
	}
}

// no-new: `new Foo()` whose result is discarded. The range ends at the callee.
lint_check_no_new :: proc(l: ^Linter, e: ^NewExpression) {
	if !lint_rule_enabled(l, .L4103_NoNew) { return }
	for index := len(l.ancestors) - 2; index >= 0; index -= 1 {
		switch node in l.ancestors[index] {
		case ^Expression:
			if _, paren := node^.(^ParenthesizedExpression); paren { continue }
		case ^Statement:
			if _, statement := node^.(^ExpressionStatement); statement {
				lint_emit(l, {e.loc.start, lint_expr_loc(e.callee).end}, .L4103_NoNew)
			}
		case ^BlockStatement:
		}
		return
	}
}

lint_check_no_continue :: proc(l: ^Linter, v: ^ContinueStatement) {
	if !lint_rule_enabled(l, .L4047_NoContinue) { return }
	lint_emit(l, {v.loc.start, v.loc.start + 8}, .L4047_NoContinue)
}

lint_parent_is_statement :: proc(l: ^Linter) -> bool {
	for index := len(l.ancestors) - 2; index >= 0; index -= 1 {
		switch node in l.ancestors[index] {
		case ^Expression:
			if _, paren := node^.(^ParenthesizedExpression); paren { continue }
			return false
		case ^Statement:
			_, statement := node^.(^ExpressionStatement)
			return statement
		case ^BlockStatement:
			return false
		}
	}
	return false
}

lint_check_no_void :: proc(l: ^Linter, e: ^UnaryExpression) {
	if e.operator != .Void || !lint_rule_enabled(l, .L4045_NoVoid) { return }
	if l.options.void_allow_statement && lint_parent_is_statement(l) { return }
	lint_emit(l, e.loc, .L4045_NoVoid)
}

lint_label_body_allowed :: proc(l: ^Linter, body: ^Statement) -> bool {
	if body == nil { return false }
	if lint_is_loop(body) { return l.options.labels_allow_loop }
	if _, is_switch := body^.(^SwitchStatement); is_switch { return l.options.labels_allow_switch }
	return false
}

// no-labels reports the label of a labeled statement and of each jump to it.
lint_check_no_labels :: proc(l: ^Linter, stmt: ^Statement) {
	if !lint_rule_enabled(l, .L4100_NoLabels) { return }
	target: LabelIdentifier
	#partial switch node in stmt^ {
	case ^LabeledStatement:
		if !lint_label_body_allowed(l, node.body) { lint_emit(l, node.label.loc, .L4100_NoLabels) }
		return
	case ^BreakStatement:
		label, labelled := node.label.?
		if !labelled { return }
		target = label
	case ^ContinueStatement:
		label, labelled := node.label.?
		if !labelled { return }
		target = label
	case:
		return
	}
	for index := len(l.ancestors) - 2; index >= 0; index -= 1 {
		ancestor, is_stmt := l.ancestors[index].(^Statement)
		if !is_stmt { continue }
		labeled, is_labeled := ancestor^.(^LabeledStatement)
		if !is_labeled || labeled.label.name != target.name { continue }
		if lint_label_body_allowed(l, labeled.body) { return }
		break
	}
	lint_emit(l, target.loc, .L4100_NoLabels)
}

lint_assignment_of :: proc(expr: ^Expression) -> ^AssignmentExpression {
	if expr == nil { return nil }
	assignment, ok := expr^.(^AssignmentExpression)
	return assignment if ok else nil
}

// no-multi-assign: `a = b = c`, in a declaration, a class field or an assignment.
lint_check_no_multi_assign :: proc(l: ^Linter, e: ^AssignmentExpression) {
	if l.options.multi_assign_ignore_non_declaration || !lint_rule_enabled(l, .L4101_NoMultiAssign) { return }
	if chained := lint_assignment_of(e.right); chained != nil { lint_emit(l, chained.loc, .L4101_NoMultiAssign) }
}

lint_check_multi_assign_declaration :: proc(l: ^Linter, d: ^VariableDeclaration) {
	if !lint_rule_enabled(l, .L4101_NoMultiAssign) { return }
	for decl in d.declarations {
		init, has_init := decl.init.?
		if !has_init { continue }
		if chained := lint_assignment_of(init); chained != nil { lint_emit(l, chained.loc, .L4101_NoMultiAssign) }
	}
}

lint_check_multi_assign_field :: proc(l: ^Linter, elem: ClassElement) {
	if elem.kind != .Field || !lint_rule_enabled(l, .L4101_NoMultiAssign) { return }
	value, has_value := elem.value.?
	if !has_value { return }
	if chained := lint_assignment_of(value); chained != nil { lint_emit(l, chained.loc, .L4101_NoMultiAssign) }
}

// no-plusplus: with allowForLoopAfterthoughts, the update clause of a `for` is exempt.
lint_check_no_plusplus :: proc(l: ^Linter, e: ^UpdateExpression) {
	if !lint_rule_enabled(l, .L4048_NoPlusplus) { return }
	if l.options.plusplus_allow_for {
		for index := len(l.ancestors) - 2; index >= 0; index -= 1 {
			switch node in l.ancestors[index] {
			case ^Expression:
				#partial switch _ in node^ {
				case ^SequenceExpression, ^ParenthesizedExpression: continue
				}
			case ^Statement:
				if loop, is_for := node^.(^ForStatement); is_for && loop.update != nil { return }
			case ^BlockStatement:
			}
			break
		}
	}
	lint_emit(l, e.loc, .L4048_NoPlusplus)
}

lint_is_null :: proc(expr: ^Expression) -> bool {
	if expr == nil { return false }
	_, ok := expr^.(^NullLiteral)
	return ok
}

// no-eq-null: `x == null` and `x != null`.
lint_check_no_eq_null :: proc(l: ^Linter, e: ^BinaryExpression) {
	if !lint_rule_enabled(l, .L4003_NoDoubleEquals) { return }
	if e.operator != .Eq && e.operator != .NotEq { return }
	if lint_is_null(e.left) || lint_is_null(e.right) { lint_emit(l, e.loc, .L4003_NoDoubleEquals) }
}

// no-new-wrappers: a long expression is reported up to its callee only.
lint_check_no_new_wrappers :: proc(l: ^Linter, e: ^NewExpression) {
	if e == nil || !lint_rule_enabled(l, .L4011_NoNewWrappers) { return }
	callee := lint_identifier(e.callee)
	if callee == nil { return }
	switch callee.name {
	case "String", "Number", "Boolean", "Symbol":
	case: return
	}
	loc := e.loc
	if loc.end - loc.start > 24 { loc.end = callee.loc.end }
	lint_report_if_global(l, callee, loc, .L4011_NoNewWrappers)
}

lint_is_script_url :: proc(text: string) -> bool {
	prefix := "javascript:"
	if len(text) < len(prefix) { return false }
	for index in 0..<len(prefix) {
		char := text[index]
		if char >= 'A' && char <= 'Z' { char += 'a' - 'A' }
		if char != prefix[index] { return false }
	}
	return true
}

lint_check_no_script_url :: proc(l: ^Linter, expr: ^Expression) {
	if !lint_rule_enabled(l, .L4019_NoScriptUrl) { return }
	#partial switch node in expr^ {
	case ^StringLiteral:
		if lint_is_script_url(node.value) { lint_emit(l, node.loc, .L4019_NoScriptUrl) }
	case ^TemplateLiteral:
		if len(node.quasis) != 1 || !lint_is_script_url(node.quasis[0].raw) { return }
		if parent := lint_ancestor_expr(l, 1); parent != nil {
			if tagged, is_tagged := parent^.(^TaggedTemplateExpression); is_tagged && tagged.quasi == expr { return }
		}
		lint_emit(l, node.loc, .L4019_NoScriptUrl)
	}
}

// no-nonoctal-decimal-escape: `\8` and `\9` in a string literal. The scan
// reads the literal's source one character or one escape at a time, so an
// escaped backslash before a digit (`\\8`) is not a decimal escape.
lint_check_nonoctal_escape :: proc(l: ^Linter, e: ^StringLiteral) {
	if !lint_rule_enabled(l, .L2043_NoNonoctalDecimalEscape) { return }
	if e.loc.end - e.loc.start < 4 || int(e.loc.end) > len(l.source) { return }
	text := l.source[e.loc.start:e.loc.end]
	for index := 0; index + 1 < len(text); index += 1 {
		if text[index] != '\\' { continue }
		next := text[index + 1]
		// A line continuation ends the reference's pattern match.
		if next == '\n' { return }
		if next == '8' || next == '9' {
			start := e.loc.start + u32(index)
			lint_emit(l, {start, start + 2}, .L2043_NoNonoctalDecimalEscape)
		}
		index += 1
	}
}
