package kessel

import "core:fmt"
import "core:strings"

// Shared helpers for the rules that track oxlint's diagnostics byte for byte.
//
// Each helper mirrors one primitive of the reference implementation so that a
// rule written against it selects the same nodes and the same ranges:
//   - lint_unparen / lint_inner     ~ without_parentheses / get_inner_expression
//   - lint_content_eq               ~ ContentEq (structure, not source text)
//   - lint_static_property_name     ~ MemberExpression::static_property_name
//   - lint_report_if_global         ~ a reference with no resolved symbol
//   - lint_parent                   ~ the parent of the node being visited

// LintNode is one entry of the ancestor stack kept by the walk. Statement and
// expression nodes are recorded, plus the block of a `finally` clause, which
// the tree stores by value. Properties, class members and switch cases have
// no entry, so rules that need them receive them directly.
LintNode :: union { ^Expression, ^Statement, ^BlockStatement }

// A report that is valid only when the identifier at `start` has no binding.
// Reports for one identifier form a list through `next` (-1 ends the list).
LintGlobalReport :: struct {
	loc:     Loc,
	rule:    LintRule,
	message: string,
	next:    i32,
}

LINT_ANCESTORS_INITIAL :: 64

lint_parity_init :: proc(l: ^Linter) {
	assert(l != nil)
	l.ancestors = make([dynamic]LintNode, 0, LINT_ANCESTORS_INITIAL, l.allocator)
	l.global_reports = make([dynamic]LintGlobalReport, 0, 0, l.allocator)
	l.global_heads = make(map[u32]i32, 0, l.allocator)
	l.object_calls = make([dynamic]LintObjectCall, 0, 0, l.allocator)
	l.replace_all_calls = make([dynamic]LintReplaceAll, 0, 0, l.allocator)
	l.then_references = make([dynamic]LintThenReference, 0, 0, l.allocator)
	l.unassigned = make([dynamic]^Identifier, 0, 0, l.allocator)
	l.set_sizes = make([dynamic]LintSetSize, 0, 0, l.allocator)
}

// lint_parent returns the ancestor `depth` levels above the node being
// visited. Depth 1 is the direct parent. Nil means the walk has no record.
lint_parent :: proc(l: ^Linter, depth := 1) -> LintNode {
	assert(depth >= 1)
	index := len(l.ancestors) - 1 - depth
	if index < 0 { return nil }
	return l.ancestors[index]
}

// The nearest ancestor expression that is not a parenthesized wrapper, or nil
// when a statement comes first.
lint_parent_expr :: proc(l: ^Linter) -> ^Expression {
	for index := len(l.ancestors) - 2; index >= 0; index -= 1 {
		expr, ok := l.ancestors[index].(^Expression)
		if !ok { return nil }
		if _, paren := expr^.(^ParenthesizedExpression); !paren { return expr }
	}
	return nil
}

lint_unparen :: proc(expr: ^Expression) -> ^Expression {
	current := expr
	for current != nil {
		paren, ok := current^.(^ParenthesizedExpression)
		if !ok || paren == nil { break }
		current = paren.expression
	}
	return current
}

// Strips parentheses and the TypeScript wrappers that vanish at runtime.
lint_inner :: proc(expr: ^Expression) -> ^Expression {
	current := expr
	for current != nil {
		#partial switch node in current^ {
		case ^ParenthesizedExpression:   current = node.expression
		case ^TSAsExpression:            current = node.expression
		case ^TSSatisfiesExpression:     current = node.expression
		case ^TSNonNullExpression:       current = node.expression
		case ^TSTypeAssertion:           current = node.expression
		case ^TSInstantiationExpression: current = node.expression
		case: return current
		}
	}
	return current
}

lint_identifier :: proc(expr: ^Expression) -> ^Identifier {
	if expr == nil { return nil }
	id, ok := expr^.(^Identifier)
	return id if ok else nil
}

lint_is_specific_id :: proc(expr: ^Expression, name: string) -> bool {
	id := lint_identifier(lint_inner(expr))
	return id != nil && id.name == name
}

// The property name when it is known without evaluation: `a.b`, `a["b"]` or
// a["b"] written as a template without substitutions. Private names have none.
lint_static_property_name :: proc(member: ^MemberExpression) -> (name: string, ok: bool) {
	if member == nil || member.property == nil { return "", false }
	if !member.computed {
		id := lint_identifier(member.property)
		if id == nil { return "", false }
		return id.name, true
	}
	#partial switch key in member.property^ {
	case ^StringLiteral:
		return key.value, true
	case ^TemplateLiteral:
		if len(key.expressions) == 0 && len(key.quasis) == 1 { return key.quasis[0].raw, true }
	case ^RegExpLiteral:
		return fmt.tprintf("/%s/%s", key.pattern, key.flags), true
	}
	return "", false
}

lint_expr_loc :: proc(expr: ^Expression) -> Loc {
	assert(expr != nil)
	return get_expression_loc(expr)
}

lint_emit :: proc(l: ^Linter, loc: Loc, rule: LintRule, message := "") {
	text := message if message != "" else lint_rule_info(rule).default_message
	lint_report(l, loc.start, loc.end, rule, text)
}

// Queue a report that applies only to the global binding of `id`. The scope
// pass decides later, once every declaration in the file is known.
lint_report_if_global :: proc(l: ^Linter, id: ^Identifier, loc: Loc, rule: LintRule, message := "") {
	assert(id != nil)
	next: i32 = -1
	if head, found := l.global_heads[id.loc.start]; found { next = head }
	text := message if message != "" else lint_rule_info(rule).default_message
	append(&l.global_reports, LintGlobalReport{loc, rule, text, next})
	l.global_heads[id.loc.start] = i32(len(l.global_reports) - 1)
}

lint_flush_global_reports :: proc(l: ^Linter, identifier_start: u32) {
	head, found := l.global_heads[identifier_start]
	if !found { return }
	// A reference is visited once, but guard against duplicate reference records.
	delete_key(&l.global_heads, identifier_start)
	for index := head; index >= 0; index = l.global_reports[index].next {
		report := l.global_reports[index]
		lint_report(l, report.loc.start, report.loc.end, report.rule, report.message)
	}
}

// Comments are sorted by position, so a binary search finds the first one
// that starts at or after `start`.
lint_has_comment_between :: proc(l: ^Linter, start, end: u32) -> bool {
	low, high := 0, len(l.comments)
	for low < high {
		middle := low + (high - low) / 2
		if l.comments[middle].start < start { low = middle + 1 } else { high = middle }
	}
	return low < len(l.comments) && l.comments[low].start < end
}

// ---------------------------------------------------------------------------
// Structural equality. Two expressions are equal when they have the same
// shape and the same names and values. Spans, raw spellings (`'a'` and "a",
// `1` and `1.0`) and whitespace are ignored. Parentheses are significant below
// the root, as they are in the reference implementation.
// ---------------------------------------------------------------------------

lint_content_eq :: proc(l: ^Linter, a, b: ^Expression) -> bool {
	if a == nil || b == nil { return a == b }
	#partial switch left in a^ {
	case ^Identifier:
		right, ok := b^.(^Identifier)
		return ok && left.name == right.name
	case ^PrivateIdentifier:
		right, ok := b^.(^PrivateIdentifier)
		return ok && left.name == right.name
	case ^ThisExpression:
		_, ok := b^.(^ThisExpression)
		return ok
	case ^Super:
		_, ok := b^.(^Super)
		return ok
	case ^NullLiteral:
		_, ok := b^.(^NullLiteral)
		return ok
	case ^BooleanLiteral:
		right, ok := b^.(^BooleanLiteral)
		return ok && left.value == right.value
	case ^NumericLiteral:
		right, ok := b^.(^NumericLiteral)
		return ok && left.value == right.value
	case ^StringLiteral:
		right, ok := b^.(^StringLiteral)
		return ok && left.value == right.value
	case ^BigIntLiteral:
		right, ok := b^.(^BigIntLiteral)
		return ok && left.value == right.value
	case ^RegExpLiteral:
		right, ok := b^.(^RegExpLiteral)
		return ok && left.pattern == right.pattern && left.flags == right.flags
	case ^ParenthesizedExpression:
		right, ok := b^.(^ParenthesizedExpression)
		return ok && lint_content_eq(l, left.expression, right.expression)
	case ^ChainExpression:
		right, ok := b^.(^ChainExpression)
		return ok && lint_content_eq(l, left.expression, right.expression)
	case ^MemberExpression:
		right, ok := b^.(^MemberExpression)
		if !ok || left.computed != right.computed || left.optional != right.optional { return false }
		return lint_content_eq(l, left.object, right.object) && lint_content_eq(l, left.property, right.property)
	case ^CallExpression:
		right, ok := b^.(^CallExpression)
		if !ok || left.optional != right.optional { return false }
		return lint_content_eq(l, left.callee, right.callee) &&
			lint_content_eq_list(l, left.arguments[:], right.arguments[:])
	case ^NewExpression:
		right, ok := b^.(^NewExpression)
		return ok && lint_content_eq(l, left.callee, right.callee) &&
			lint_content_eq_list(l, left.arguments[:], right.arguments[:])
	case ^UnaryExpression:
		right, ok := b^.(^UnaryExpression)
		return ok && left.operator == right.operator && lint_content_eq(l, left.argument, right.argument)
	case ^UpdateExpression:
		right, ok := b^.(^UpdateExpression)
		if !ok || left.operator != right.operator || left.prefix != right.prefix { return false }
		return lint_content_eq(l, left.argument, right.argument)
	case ^BinaryExpression:
		right, ok := b^.(^BinaryExpression)
		if !ok || left.operator != right.operator { return false }
		return lint_content_eq(l, left.left, right.left) && lint_content_eq(l, left.right, right.right)
	case ^LogicalExpression:
		right, ok := b^.(^LogicalExpression)
		if !ok || left.operator != right.operator { return false }
		return lint_content_eq(l, left.left, right.left) && lint_content_eq(l, left.right, right.right)
	case ^AssignmentExpression:
		right, ok := b^.(^AssignmentExpression)
		if !ok || left.operator != right.operator { return false }
		return lint_content_eq(l, left.left, right.left) && lint_content_eq(l, left.right, right.right)
	case ^ConditionalExpression:
		right, ok := b^.(^ConditionalExpression)
		if !ok { return false }
		return lint_content_eq(l, left.test, right.test) &&
			lint_content_eq(l, left.consequent, right.consequent) &&
			lint_content_eq(l, left.alternate, right.alternate)
	case ^SequenceExpression:
		right, ok := b^.(^SequenceExpression)
		return ok && lint_content_eq_list(l, left.expressions[:], right.expressions[:])
	case ^SpreadElement:
		right, ok := b^.(^SpreadElement)
		return ok && lint_content_eq(l, left.argument, right.argument)
	case ^AwaitExpression:
		right, ok := b^.(^AwaitExpression)
		return ok && lint_content_eq(l, left.argument, right.argument)
	case ^ArrayExpression:
		right, ok := b^.(^ArrayExpression)
		if !ok || len(left.elements) != len(right.elements) { return false }
		for element, index in left.elements {
			first, _ := element.?
			second, _ := right.elements[index].?
			if !lint_content_eq(l, first, second) { return false }
		}
		return true
	case ^TemplateLiteral:
		right, ok := b^.(^TemplateLiteral)
		if !ok || len(left.quasis) != len(right.quasis) { return false }
		for quasi, index in left.quasis {
			if quasi.raw != right.quasis[index].raw { return false }
		}
		return lint_content_eq_list(l, left.expressions[:], right.expressions[:])
	}
	return lint_content_eq_text(l, a, b)
}

lint_content_eq_list :: proc(l: ^Linter, a, b: []^Expression) -> bool {
	if len(a) != len(b) { return false }
	for item, index in a {
		if !lint_content_eq(l, item, b[index]) { return false }
	}
	return true
}

// Functions, classes, objects, JSX and typed wrappers are compared by their
// source with whitespace removed. Comments inside them make them differ, which
// errs toward reporting nothing.
lint_content_eq_text :: proc(l: ^Linter, a, b: ^Expression) -> bool {
	first, second := lint_expr_loc(a), lint_expr_loc(b)
	if int(first.end) > len(l.source) || int(second.end) > len(l.source) { return false }
	left, right := l.source[first.start:first.end], l.source[second.start:second.end]
	i, j := 0, 0
	for {
		for i < len(left) && lint_is_space(left[i]) { i += 1 }
		for j < len(right) && lint_is_space(right[j]) { j += 1 }
		if i == len(left) || j == len(right) { return i == len(left) && j == len(right) }
		if left[i] != right[j] { return false }
		i += 1
		j += 1
	}
}

lint_is_space :: proc(char: u8) -> bool {
	return char == ' ' || char == '\t' || char == '\n' || char == '\r'
}

// ---------------------------------------------------------------------------
// Plugins. A rule code range belongs to one oxlint plugin, so a qualified
// name such as `unicorn/no-thenable` or `@typescript-eslint/no-namespace`
// selects the rule of that plugin only.
// ---------------------------------------------------------------------------

lint_rule_plugin :: proc(rule: LintRule) -> string {
	#partial switch rule {
	case .L4107_RulesOfHooks, .L4108_ExhaustiveDeps: return "react"
	}
	code := u16(rule)
	switch {
	case code >= 3000 && code < 4000: return "typescript"
	case code >= 5000 && code < 6000: return "oxc"
	case code >= 6000 && code < 7000: return "unicorn"
	}
	return "eslint"
}

// Splits `plugin/rule` and maps the spellings ESLint and oxlint accept for a
// plugin to oxlint's canonical plugin name. A bare name has an empty plugin.
lint_rule_split_name :: proc(name: string) -> (plugin, rule: string) {
	slash := strings.last_index_byte(name, '/')
	if slash < 0 { return "", name }
	prefix := name[:slash]
	switch prefix {
	case "@typescript-eslint", "typescript-eslint", "typescript": prefix = "typescript"
	case "react-hooks", "react_hooks", "react":                 prefix = "react"
	case "eslint-plugin-unicorn", "unicorn":                     prefix = "unicorn"
	}
	return prefix, name[slash + 1:]
}

// A binding identifier's range covers its type annotation. Rules report the name.
lint_binding_loc :: proc(id: ^Identifier) -> Loc {
	if id.has_escape || id.type_annotation == nil { return id.loc }
	return {id.loc.start, id.loc.start + u32(len(id.name))}
}
