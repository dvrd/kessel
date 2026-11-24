package kessel

import "core:strings"

LintRegExpCall :: struct {
	location: Loc,
	callee_start: u32,
	pattern, flags: string,
}

@(private)
lint_queue_regexp_call :: proc(l: ^Linter, location: Loc, callee: ^Expression, arguments: []^Expression) {
	if !lint_rule_enabled(l, .L4106_NoUselessBackreference) { return }
	if callee == nil || len(arguments) < 1 { return }
	name, ok := callee^.(^Identifier)
	if !ok || name == nil || name.name != "RegExp" { return }
	pattern, constant := lint_constant_string(arguments[0])
	if !constant || !strings.contains(pattern, "\\") { return }
	flags := ""
	if len(arguments) > 1 {
		flags, constant = lint_constant_string(arguments[1])
		if !constant { return }
	}
	bump_append(&l.regexp_calls, LintRegExpCall{location, name.loc.start, pattern, flags})
}

@(private)
lint_constant_string :: proc(expression: ^Expression) -> (string, bool) {
	value := expression
	for _ in 0..<512 {
		if value == nil { return "", false }
		#partial switch item in value^ {
		case ^StringLiteral: return item.value, true
		case ^TemplateLiteral:
			if len(item.expressions) == 0 && len(item.quasis) == 1 {
				if cooked, ok := item.quasis[0].cooked.?; ok { return cooked, true }
			}
			return "", false
		case ^ParenthesizedExpression: value = item.expression
		case: return "", false
		}
	}
	return "", false
}

@(private)
lint_check_regexp_calls :: proc(l: ^Linter, model: ^SemanticModel) {
	global_calls := make(map[u32]bool, l.allocator)
	for ref in model.refs {
		if ref.name == "RegExp" && ref.resolved == SYMBOL_UNRESOLVED {
			global_calls[ref.start] = true
		}
	}
	for call in l.regexp_calls {
		if global_calls[call.callee_start] {
			lint_check_regexp_backreferences(l, call.location, call.pattern, call.flags)
		}
	}
}

LintRegExpAncestor :: struct {
	parent, depth: u32,
}

LintBackreferenceIssue :: enum { None, Nested, Disjunctive, Forward, Backward, Negative_Lookaround }

@(private)
lint_check_regexp_backreferences :: proc(l: ^Linter, location: Loc, pattern, flags: string, pattern_start: u32 = 0) {
	if !strings.contains(pattern, "\\") { return }
	tree, err := regex_parse_ast(pattern, flags, l.allocator)
	if err.kind != .None { return }
	defer regex_ast_destroy(&tree)
	if tree.capture_count == 0 { return }
	has_reference := false
	for node in tree.nodes[1:] {
		if node.kind == .Indexed_Reference || node.kind == .Named_Reference {
			has_reference = true
			break
		}
	}
	if !has_reference { return }

	ancestors := make([]LintRegExpAncestor, len(tree.nodes), l.allocator)
	lint_regexp_index_ancestors(ancestors, &tree)
	captures := make([]u32, int(tree.capture_count) + 1, l.allocator)
	named := make(map[string][dynamic]u32, l.allocator)
	for index in 1..<len(tree.nodes) {
		node := tree.nodes[index]
		if node.kind != .Group || node.capture_index == 0 { continue }
		captures[node.capture_index] = u32(index)
		if node.group_kind == .Named_Capture {
			key := pattern[node.name.start:node.name.end]
			groups := named[key]
			if groups.allocator.procedure == nil { groups.allocator = l.allocator }
			bump_append(&groups, u32(index))
			named[key] = groups
		}
	}
	for index in 1..<len(tree.nodes) {
		node := tree.nodes[index]
		id := u32(index)
		issue: LintBackreferenceIssue
		#partial switch node.kind {
		case .Indexed_Reference:
			issue = lint_regexp_backreference_issue(&tree, ancestors, id, captures[node.capture_index])
		case .Named_Reference:
			key := pattern[node.name.start:node.name.end]
			for group in named[key] {
				issue = lint_regexp_backreference_issue(&tree, ancestors, id, group)
				if issue == .None { break }
			}
		}
		if issue != .None {
			start, end := location.start, location.end
			if pattern_start != 0 {
				start, end = pattern_start + node.span.start, pattern_start + node.span.end
			}
			lint_report(l, start, end, .L4106_NoUselessBackreference, lint_regexp_backreference_message(issue))
		}
	}
}

@(private="file")
lint_regexp_index_ancestors :: proc(ancestors: []LintRegExpAncestor, tree: ^RegexAst) {
	for current := tree.root; current != 0; {
		node := tree.nodes[current]
		if node.first_child != 0 {
			ancestors[node.first_child] = {parent = current, depth = ancestors[current].depth + 1}
			current = node.first_child
			continue
		}
		for current != 0 && tree.nodes[current].next_sibling == 0 {
			current = ancestors[current].parent
		}
		if current != 0 {
			sibling := tree.nodes[current].next_sibling
			ancestors[sibling] = ancestors[current]
			current = sibling
		}
	}
}

@(private="file")
lint_regexp_backreference_issue :: proc(tree: ^RegexAst, ancestors: []LintRegExpAncestor, reference, capture: u32) -> LintBackreferenceIssue {
	if capture == 0 { return .None }
	left, right := reference, capture
	capture_branch: u32
	negative := false
	for left != right {
		if ancestors[left].depth >= ancestors[right].depth {
			left = ancestors[left].parent
			if left == right { break }
		}
		if ancestors[right].depth > ancestors[left].depth {
			capture_branch = right
			negative = negative || lint_regexp_negative_lookaround(tree.nodes[right])
			right = ancestors[right].parent
		}
	}
	if left == capture { return .Nested }
	if capture_branch != 0 && tree.nodes[capture_branch].kind == .Alternative { return .Disjunctive }
	backward := lint_regexp_matches_backward(tree, ancestors, left)
	ref_span, cap_span := tree.nodes[reference].span, tree.nodes[capture].span
	if backward && cap_span.end <= ref_span.start { return .Backward }
	if !backward && ref_span.end <= cap_span.start { return .Forward }
	if negative { return .Negative_Lookaround }
	return .None
}

@(private="file")
lint_regexp_negative_lookaround :: proc(node: RegexAstNode) -> bool {
	return node.kind == .Group && (node.group_kind == .Negative_Lookahead || node.group_kind == .Negative_Lookbehind)
}

@(private="file")
lint_regexp_matches_backward :: proc(tree: ^RegexAst, ancestors: []LintRegExpAncestor, root: u32) -> bool {
	for id := root; id != 0; id = ancestors[id].parent {
		node := tree.nodes[id]
		if node.kind != .Group { continue }
		#partial switch node.group_kind {
		case .Lookbehind, .Negative_Lookbehind: return true
		case .Lookahead, .Negative_Lookahead: return false
		}
	}
	return false
}

@(private="file")
lint_regexp_backreference_message :: proc(issue: LintBackreferenceIssue) -> string {
	switch issue {
	case .Nested: return "backreference appears inside its own capture group"
	case .Disjunctive: return "backreference points to a capture in another alternative"
	case .Forward: return "backreference appears before its capture group"
	case .Backward: return "backreference appears after its capture group in a lookbehind"
	case .Negative_Lookaround: return "backreference points to a capture in a negative lookaround"
	case .None: unreachable()
	}
	unreachable()
}
