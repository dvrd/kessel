package kessel

import "core:encoding/json"

LintNullEquality :: enum { Always, Ignore, Never }
LintEqualityOptions :: struct { smart: bool, null_rule: LintNullEquality }
LintEqualityOperand :: enum { Other, Typeof, Null, Boolean, Number, BigInt, String, Regexp, Template }

lint_equality_options :: proc(options: []json.Value) -> (LintEqualityOptions, bool) {
	settings: LintEqualityOptions
	if len(options) == 0 { return settings, true }
	if len(options) > 2 { return {}, false }
	mode, ok := options[0].(json.String)
	if !ok { return {}, false }
	switch string(mode) {
	case "smart": settings.smart = true
	case "always":
	case "allow-null": settings.null_rule = .Ignore
	case: return {}, false
	}
	if len(options) == 2 {
		extra, is_object := options[1].(json.Object)
		if !is_object { return {}, false }
		for key, value in extra {
			if key != "null" { return {}, false }
			choice, is_string := value.(json.String)
			if !is_string { return {}, false }
			switch string(choice) {
			case "always": settings.null_rule = .Always
			case "never": settings.null_rule = .Never
			case "ignore": settings.null_rule = .Ignore
			case: return {}, false
			}
		}
	}
	return settings, true
}

lint_equality_operand :: proc(expr: ^Expression) -> LintEqualityOperand {
	// Grouping does not change what kind of value an operand produces.
	expr := lint_unparen(expr)
	if expr == nil { return .Other }
	#partial switch v in expr^ {
	case ^UnaryExpression: if v != nil && v.operator == .Typeof { return .Typeof }
	case ^NullLiteral: return .Null
	case ^BooleanLiteral: return .Boolean
	case ^NumericLiteral: return .Number
	case ^BigIntLiteral: return .BigInt
	case ^StringLiteral: return .String
	case ^RegExpLiteral: return .Regexp
	case ^TemplateLiteral: return .Template
	}
	return .Other
}

lint_check_eqeqeq :: proc(l: ^Linter, e: ^BinaryExpression) {
	if e == nil || !lint_rule_enabled(l, .L1003_Eqeqeq) { return }
	EQUALITY_OPERATORS :: bit_set[BinaryOperator]{.Eq, .NotEq, .StrictEq, .StrictNotEq}
	if e.operator not_in EQUALITY_OPERATORS { return }
	left, right := lint_equality_operand(e.left), lint_equality_operand(e.right)
	null_check := left == .Null || right == .Null
	spelling, message: string
	#partial switch e.operator {
	case .StrictEq, .StrictNotEq:
		if !null_check || l.equality.null_rule != .Never { return }
		if e.operator == .StrictEq { spelling, message = "===", "expected '==' and instead saw '==='" }
		else { spelling, message = "!==", "expected '!=' and instead saw '!=='" }
	case .Eq, .NotEq:
		if null_check && l.equality.null_rule != .Always { return }
		if l.equality.smart {
			if null_check || left == .Typeof || right == .Typeof { return }
			if left == right && left != .Other { return }
		}
		if e.operator == .Eq { spelling, message = "==", "expected '===' and instead saw '=='" }
		else { spelling, message = "!=", "expected '!==' and instead saw '!='" }
	case: return
	}
	loc := lint_equality_operator_span(l.source, e, spelling)
	lint_report(l, loc.start, loc.end, .L1003_Eqeqeq, message)
	if .Fix not_in l.fix_kinds || len(spelling) != 2 { return }
	if l.source[loc.start:loc.end] != spelling { return }
	// A typeof result can still trigger object coercion on the other operand.
	known_primitive :: bit_set[LintEqualityOperand]{.Typeof, .Null, .Boolean, .Number, .BigInt, .String, .Template}
	safe := left == right && left != .Other
	if left == .Typeof && right in known_primitive { safe = true }
	if right == .Typeof && left in known_primitive { safe = true }
	if !safe && .Dangerous not_in l.fix_kinds { return }
	replacement := "===" if e.operator == .Eq else "!=="
	l.fixes[{.L1003_Eqeqeq, loc}] = {loc, replacement}
}

// The gap can contain discarded parentheses and comments containing the same
// operator. Skipping comment tokens keeps diagnostics on the executable token.
lint_equality_operator_span :: proc(source: string, e: ^BinaryExpression, spelling: string) -> Loc {
	left := get_expression_loc(e.left)
	right := get_expression_loc(e.right)
	if left.end > right.start || int(right.start) > len(source) { return e.loc }
	bytes := transmute([]u8)source[:right.start]
	for i := int(left.end); i + len(spelling) <= len(bytes); {
		if source[i:i+2] == "/*" { i, _ = simd_skip_block_comment(bytes, i+2); continue }
		if source[i:i+2] == "//" { i, _ = simd_skip_line_comment(bytes, i+2); continue }
		if source[i:i+len(spelling)] == spelling { return {u32(i), u32(i+len(spelling))} }
		i += 1
	}
	return e.loc
}
