package kessel

import "core:math"

// The `oxc` plugin: mistakes that are almost certainly bugs.

lint_array_method_names := [?]string{
	"@@iterator", "at", "concat", "copyWithin", "entries", "every", "fill", "filter", "find",
	"findIndex", "findLast", "findLastIndex", "flat", "flatMap", "forEach", "groupBy", "includes",
	"indexOf", "join", "keys", "lastIndexOf", "map", "pop", "push", "reduce", "reduceRight",
	"reverse", "shift", "slice", "some", "sort", "splice", "toReversed", "toSorted", "toSpliced",
	"unshift", "values", "with",
}

lint_ancestor_expr :: proc(l: ^Linter, depth: int) -> ^Expression {
	node := lint_parent(l, depth)
	expr, ok := node.(^Expression)
	return expr if ok else nil
}

// The callee member of `a.b()`, looking through grouping and optional chains.
lint_method_call :: proc(e: ^CallExpression, method: string, arguments_min: int, arguments_max := max(int)) -> ^MemberExpression {
	if len(e.arguments) < arguments_min || len(e.arguments) > arguments_max { return nil }
	member := lint_member_of(e.callee)
	if member == nil { return nil }
	name, static := lint_static_property_name(member)
	return member if static && name == method else nil
}

// The range oxlint labels for a member's property: the name, or the key
// expression of a computed access.
lint_property_loc :: proc(member: ^MemberExpression) -> Loc {
	return lint_expr_loc(member.property)
}

lint_numeric_argument :: proc(arguments: []^Expression, index: int) -> (f64, bool) {
	if index >= len(arguments) || arguments[index] == nil { return 0, false }
	literal, ok := arguments[index]^.(^NumericLiteral)
	if !ok { return 0, false }
	return literal.value, true
}

// bad-array-method-on-arguments: `arguments.map(...)`.
lint_check_arguments_method :: proc(l: ^Linter, id: ^Identifier) {
	if id.name != "arguments" || !lint_rule_enabled(l, .L5001_BadArrayMethodOnArguments) { return }
	parent, grandparent := lint_ancestor_expr(l, 1), lint_ancestor_expr(l, 2)
	if parent == nil || grandparent == nil { return }
	member, is_member := parent^.(^MemberExpression)
	if !is_member { return }
	if _, is_call := grandparent^.(^CallExpression); !is_call { return }
	name, static := lint_static_property_name(member)
	if !static { return }
	for method in lint_array_method_names {
		if method == name { lint_emit(l, member.loc, .L5001_BadArrayMethodOnArguments); return }
	}
}

lint_check_oxc_call :: proc(l: ^Linter, e: ^CallExpression) {
	lint_check_char_at_comparison(l, e)
	lint_check_min_max(l, e)
	lint_check_replace_all(l, e)
	lint_check_number_argument(l, e)
}

// bad-char-at-comparison: charAt() returns one character, so comparing it
// with a longer string is always false.
lint_check_char_at_comparison :: proc(l: ^Linter, e: ^CallExpression) {
	if !lint_rule_enabled(l, .L5002_BadCharAtComparison) { return }
	if lint_method_call(e, "charAt", 1, 1) == nil { return }
	parent := lint_ancestor_expr(l, 1)
	if parent == nil { return }
	binary, is_binary := parent^.(^BinaryExpression)
	if !is_binary || !lint_binary_is_equality(binary.operator) { return }
	other := binary.right if lint_expr_loc(binary.left) == e.loc else binary.left
	text, is_string := other^.(^StringLiteral)
	if !is_string || len(text.value) < 2 { return }
	runes := 0
	for _ in text.value { runes += 1 }
	if runes != 1 { lint_emit(l, e.loc, .L5002_BadCharAtComparison) }
}

LintMinMax :: enum { None, Min, Max }

lint_min_max :: proc(e: ^CallExpression) -> (kind: LintMinMax, bound: f64) {
	member := lint_member_of(e.callee)
	if member == nil { return .None, 0 }
	object := lint_identifier(member.object)
	name, static := lint_static_property_name(member)
	if object == nil || object.name != "Math" || !static { return .None, 0 }
	// With no numeric argument the bound stays infinite and never decides.
	switch name {
	case "max": kind, bound = .Max, math.inf_f64(-1)
	case "min": kind, bound = .Min, math.inf_f64(1)
	case: return .None, 0
	}
	for argument in e.arguments {
		literal, is_number := argument^.(^NumericLiteral)
		if !is_number { continue }
		if kind == .Max { bound = max(bound, literal.value) } else { bound = min(bound, literal.value) }
	}
	return kind, bound
}

// bad-min-max-func: `Math.min(Math.max(x, 100), 0)` is always 0.
lint_check_min_max :: proc(l: ^Linter, e: ^CallExpression) {
	if !lint_rule_enabled(l, .L5004_BadMinMaxFunc) { return }
	outer, outer_bound := lint_min_max(e)
	if outer == .None { return }
	for argument in e.arguments {
		call, is_call := argument^.(^CallExpression)
		if !is_call { continue }
		inner, inner_bound := lint_min_max(call)
		constant := (outer == .Max && inner == .Min && outer_bound > inner_bound) ||
			(outer == .Min && inner == .Max && outer_bound < inner_bound)
		if constant { lint_emit(l, e.loc, .L5004_BadMinMaxFunc) }
	}
}

// The flags of a regular expression value: a literal or `new RegExp(p, "flags")`.
lint_regex_flags :: proc(expr: ^Expression) -> (flags: string, known: bool, alias: ^Identifier) {
	inner := lint_unparen(expr)
	if inner == nil { return "", false, nil }
	#partial switch node in inner^ {
	case ^RegExpLiteral: return node.flags, true, nil
	case ^Identifier:    return "", false, node
	case ^NewExpression:
		if !lint_is_specific_id(node.callee, "RegExp") { return "", false, nil }
		if len(node.arguments) <= 1 { return "", true, nil }
		#partial switch argument in node.arguments[1]^ {
		case ^StringLiteral: flags = argument.value
		case ^TemplateLiteral:
			if len(argument.expressions) != 0 || len(argument.quasis) != 1 { return "", false, nil }
			flags = argument.quasis[0].raw
		case: return "", false, nil
		}
		for char in flags {
			switch char {
			case 'd', 'g', 'i', 'm', 's', 'u', 'v', 'y':
			case: return "", false, nil
			}
		}
		return flags, true, nil
	}
	return "", false, nil
}

LintReplaceAll :: struct { argument: ^Identifier, property: Loc }

// bad-replace-all-arg: replaceAll throws for a regular expression without `g`.
lint_check_replace_all :: proc(l: ^Linter, e: ^CallExpression) {
	if !lint_rule_enabled(l, .L5006_BadReplaceAllArg) { return }
	if lint_method_call(e, "replaceAll", 1) == nil { return }
	if _, spread := e.arguments[0]^.(^SpreadElement); spread { return }
	member, direct := e.callee^.(^MemberExpression)
	flags, known, alias := lint_regex_flags(e.arguments[0])
	if alias != nil {
		// The variable's initializer is known only after scope analysis.
		if direct { append(&l.replace_all_calls, LintReplaceAll{alias, lint_property_loc(member)}) }
		return
	}
	if known && direct && !lint_has_flag(flags, 'g') { lint_emit(l, lint_property_loc(member), .L5006_BadReplaceAllArg) }
}

lint_has_flag :: proc(flags: string, flag: u8) -> bool {
	for index in 0..<len(flags) {
		if flags[index] == flag { return true }
	}
	return false
}

lint_check_replace_all_aliases :: proc(l: ^Linter, model: ^SemanticModel, references: map[u32]SymbolId) {
	for site in l.replace_all_calls {
		id := site.argument
		for _ in 0..<LINT_GLOBAL_ALIAS_DEPTH_MAX {
			resolved, found := references[id.loc.start]
			if !found || resolved == SYMBOL_UNRESOLVED { break }
			entry, declared := l.declarator_inits[model.symbols[resolved].decl_start]
			if !declared || entry.init == nil { break }
			flags, known, alias := lint_regex_flags(entry.init)
			if alias != nil { id = alias; continue }
			if known && !lint_has_flag(flags, 'g') { lint_emit(l, site.property, .L5006_BadReplaceAllArg) }
			break
		}
	}
}

// number-arg-out-of-range: radix and precision limits of Number methods.
lint_check_number_argument :: proc(l: ^Linter, e: ^CallExpression) {
	if !lint_rule_enabled(l, .L5008_NumberArgOutOfRange) { return }
	value, numeric := lint_numeric_argument(e.arguments[:], 0)
	member := lint_member_of(e.callee)
	if !numeric || member == nil { return }
	name, static := lint_static_property_name(member)
	if !static { return }
	low, high: f64
	switch name {
	case "toString":                 low, high = 2, 36
	case "toFixed", "toExponential": low, high = 0, 20
	case "toPrecision":              low, high = 1, 21
	case: return
	}
	in_range := value >= low && value <= high
	if !in_range { lint_emit(l, e.loc, .L5008_NumberArgOutOfRange) }
}

lint_binary_bad_sequence :: proc(e: ^BinaryExpression) -> bool {
	left, nested := e.left^.(^BinaryExpression)
	if !nested { return false }
	if lint_binary_is_equality(e.operator) && lint_binary_is_equality(left.operator) { return true }
	return lint_binary_is_compare(e.operator) && lint_binary_is_compare(left.operator)
}

lint_check_oxc_binary :: proc(l: ^Linter, e: ^BinaryExpression) {
	if e.left == nil || e.right == nil { return }
	// bad-comparison-sequence: `a < b < c` compares a boolean with c. Only the
	// outermost comparison of a chain is reported.
	if lint_rule_enabled(l, .L5003_BadComparisonSequence) && lint_binary_bad_sequence(e) {
		outermost := false
		search: for index := len(l.ancestors) - 2; index >= 0; index -= 1 {
			expr, is_expr := l.ancestors[index].(^Expression)
			if !is_expr { outermost = true; break }
			#partial switch parent in expr^ {
			case ^ParenthesizedExpression: outermost = true; break search
			case ^BinaryExpression:        if lint_binary_bad_sequence(parent) { break search }
			}
		}
		if outermost { lint_emit(l, e.loc, .L5003_BadComparisonSequence) }
	}
	if lint_rule_enabled(l, .L5005_BadObjectLiteralComparison) && lint_binary_is_equality(e.operator) {
		if lint_is_empty_literal(e.left, false) || lint_is_empty_literal(e.right, false) {
			lint_emit(l, e.loc, .L5005_BadObjectLiteralComparison)
		}
		if lint_is_empty_literal(e.left, true) || lint_is_empty_literal(e.right, true) {
			lint_emit(l, e.loc, .L5005_BadObjectLiteralComparison)
		}
	}
	if lint_rule_enabled(l, .L5011_ErasingOp) {
		#partial switch e.operator {
		case .Mul, .BitAnd:
			if lint_is_zero(e.left) { lint_emit(l, e.loc, .L5011_ErasingOp) }
			if lint_is_zero(e.right) { lint_emit(l, e.loc, .L5011_ErasingOp) }
		case .Div:
			if !lint_is_zero(e.right) && lint_is_zero(e.left) { lint_emit(l, e.loc, .L5011_ErasingOp) }
		}
	}
}

lint_is_empty_literal :: proc(expr: ^Expression, array: bool) -> bool {
	#partial switch node in expr^ {
	case ^ObjectExpression: return !array && len(node.properties) == 0
	case ^ArrayExpression:  return array && len(node.elements) == 0
	}
	return false
}

lint_is_zero :: proc(expr: ^Expression) -> bool {
	inner := lint_unparen(expr)
	if inner == nil { return false }
	literal, ok := inner^.(^NumericLiteral)
	return ok && abs(literal.value) < 2.220446049250313e-16
}

lint_check_oxc_new :: proc(l: ^Linter, e: ^NewExpression) {
	// missing-throw: `new Error()` as a statement of its own.
	if lint_rule_enabled(l, .L5007_MissingThrow) && lint_is_specific_id(e.callee, "Error") {
		if stmt, is_stmt := lint_parent(l).(^Statement); is_stmt {
			if _, expression := stmt^.(^ExpressionStatement); expression { lint_emit(l, e.loc, .L5007_MissingThrow) }
		}
	}
	// uninvoked-array-callback: `new Array(5).map(fn)` visits no element.
	if !lint_rule_enabled(l, .L5009_UninvokedArrayCallback) { return }
	if len(e.arguments) != 1 || !lint_is_specific_id(e.callee, "Array") { return }
	if _, numeric := lint_numeric_argument(e.arguments[:], 0); !numeric { return }
	parent, grandparent := lint_ancestor_expr(l, 1), lint_ancestor_expr(l, 2)
	if parent == nil || grandparent == nil { return }
	member, is_member := parent^.(^MemberExpression)
	call, is_call := grandparent^.(^CallExpression)
	if !is_member || !is_call || len(call.arguments) == 0 { return }
	#partial switch _ in call.arguments[0]^ {
	case ^FunctionExpression, ^ArrowFunctionExpression:
		lint_emit(l, lint_property_loc(member), .L5009_UninvokedArrayCallback)
	}
}

// ---------------------------------------------------------------------------
// double-comparisons and the "same expression" relation it relies on.
// ---------------------------------------------------------------------------

lint_chain_member :: proc(expr: ^Expression) -> ^MemberExpression {
	chain, is_chain := expr^.(^ChainExpression)
	if !is_chain || chain.expression == nil { return nil }
	member, ok := chain.expression^.(^MemberExpression)
	return member if ok else nil
}

lint_direct_member :: proc(expr: ^Expression) -> ^MemberExpression {
	member, ok := expr^.(^MemberExpression)
	return member if ok else nil
}

// Whether two expressions are certain to denote the same value. Narrower than
// structural equality: calls and other effects never count as the same.
lint_same_expression :: proc(l: ^Linter, a, b: ^Expression) -> bool {
	if a == nil || b == nil { return false }
	if !lint_compare_enter(l) { return false }
	defer l.compare_depth -= 1
	left_chain, right_chain := lint_chain_member(a), lint_chain_member(b)
	left_member, right_member := lint_direct_member(a), lint_direct_member(b)
	if left_chain != nil && right_member != nil { return lint_same_member_expression(l, left_chain, right_member) }
	if left_member != nil && right_chain != nil { return lint_same_member_expression(l, left_member, right_chain) }
	if left_chain != nil && right_chain != nil { return lint_same_member_expression(l, left_chain, right_chain) }
	if left_member != nil && right_member != nil { return lint_same_member_expression(l, left_member, right_member) }
	#partial switch left in a^ {
	case ^Super:
		_, same := b^.(^Super)
		return same
	case ^ThisExpression:
		_, same := b^.(^ThisExpression)
		return same
	case ^NullLiteral:
		_, same := b^.(^NullLiteral)
		return same
	case ^Identifier:
		right := lint_identifier(b)
		return right != nil && left.name == right.name
	case ^StringLiteral:
		#partial switch right in b^ {
		case ^StringLiteral:   return left.value == right.value
		case ^TemplateLiteral: return len(right.expressions) == 0 && len(right.quasis) == 1 && right.quasis[0].raw == left.value
		}
	case ^TemplateLiteral:
		#partial switch right in b^ {
		case ^StringLiteral:
			return len(left.expressions) == 0 && len(left.quasis) == 1 && left.quasis[0].raw == right.value
		case ^TemplateLiteral:
			if len(left.quasis) != len(right.quasis) || len(left.expressions) != len(right.expressions) { return false }
			for quasi, index in left.quasis {
				if quasi.raw != right.quasis[index].raw { return false }
			}
			for item, index in left.expressions {
				if !lint_same_expression(l, item, right.expressions[index]) { return false }
			}
			return true
		}
	case ^NumericLiteral:
		right, ok := b^.(^NumericLiteral)
		return ok && left.raw == right.raw
	case ^RegExpLiteral:
		right, ok := b^.(^RegExpLiteral)
		return ok && left.pattern == right.pattern && left.flags == right.flags
	case ^BooleanLiteral:
		right, ok := b^.(^BooleanLiteral)
		return ok && left.value == right.value
	case ^BinaryExpression:
		right, ok := b^.(^BinaryExpression)
		if !ok || left.operator != right.operator { return false }
		return lint_same_expression(l, lint_inner(left.left), lint_inner(right.left)) &&
			lint_same_expression(l, lint_inner(left.right), lint_inner(right.right))
	case ^UnaryExpression:
		right, ok := b^.(^UnaryExpression)
		if !ok || left.operator != right.operator { return false }
		return lint_same_expression(l, lint_inner(left.argument), lint_inner(right.argument))
	}
	return false
}

lint_same_member_expression :: proc(l: ^Linter, left, right: ^MemberExpression) -> bool {
	name, static := lint_static_property_name(left)
	other, other_static := lint_static_property_name(right)
	if static != other_static || (static && name != other) { return false }
	if !static && lint_member_is_private(left) && lint_member_is_private(right) {
		same := left.property^.(^PrivateIdentifier).name == right.property^.(^PrivateIdentifier).name
		return same && lint_same_expression(l, left.object, right.object)
	}
	if left.computed && right.computed && !static {
		if !lint_same_expression(l, lint_inner(left.property), lint_inner(right.property)) { return false }
	}
	return lint_same_expression(l, lint_inner(left.object), lint_inner(right.object))
}

lint_compare_inverse :: proc(operator: BinaryOperator) -> BinaryOperator {
	#partial switch operator {
	case .Lt:   return .Gt
	case .Gt:   return .Lt
	case .LtEq: return .GtEq
	case .GtEq: return .LtEq
	}
	return operator
}

// double-comparisons: `a == b || a < b` is `a <= b`.
lint_check_double_comparisons :: proc(l: ^Linter, e: ^LogicalExpression) {
	if !lint_rule_enabled(l, .L5010_DoubleComparisons) || e.left == nil || e.right == nil { return }
	left, left_binary := e.left^.(^BinaryExpression)
	right, right_binary := e.right^.(^BinaryExpression)
	if !left_binary || !right_binary { return }
	second: BinaryOperator
	if lint_same_expression(l, left.left, right.left) && lint_same_expression(l, left.right, right.right) {
		second = right.operator
	} else if lint_same_expression(l, left.left, right.right) && lint_same_expression(l, left.right, right.left) {
		second = right.operator if lint_binary_is_equality(right.operator) else lint_compare_inverse(right.operator)
	} else {
		return
	}
	first := left.operator
	equal :: proc(operator: BinaryOperator) -> bool { return operator == .Eq || operator == .StrictEq }
	simplifies := false
	switch e.operator {
	case .Or:
		simplifies = (equal(first) && (second == .Lt || second == .Gt)) ||
			((first == .Lt || first == .Gt) && equal(second)) ||
			(first == .Lt && second == .Gt) || (first == .Gt && second == .Lt)
	case .And:
		simplifies = (first == .LtEq && second == .GtEq) || (first == .GtEq && second == .LtEq)
	case .NullishCoalescing:
	}
	if simplifies { lint_emit(l, e.loc, .L5010_DoubleComparisons) }
}
