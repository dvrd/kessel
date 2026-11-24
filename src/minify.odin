package kessel

import "core:math"
import "core:strconv"

// A boolean retains its JS type for strict equality. Its numeric field is ToNumber(value).
MinifyConstant :: struct {
	number: f64,
	boolean: bool,
	bytes: int,
}

minify_boolean :: proc(value: bool, bytes: int) -> MinifyConstant {
	return {number = value ? 1 : 0, boolean = true, bytes = bytes}
}

minify_truthy :: proc(value: MinifyConstant) -> bool {
	return value.number != 0 && !math.is_nan(value.number)
}

minify_unary :: proc(op: UnaryOperator, value: MinifyConstant) -> (MinifyConstant, bool) {
	size := value.bytes + 1
	#partial switch op {
	case .LogicalNot: return minify_boolean(!minify_truthy(value), size), true
	case .BitwiseNot: return {number = f64(~i32(enum_u32(value.number))), bytes = size}, true
	case .Minus:      return {number = -value.number, bytes = size}, true
	case .Plus:       return {number = value.number, bytes = size}, true
	}
	return {}, false
}

minify_binary :: proc(op: BinaryOperator, left, right: MinifyConstant) -> (MinifyConstant, bool) {
	spelling, _ := binop_text(op)
	size := left.bytes + len(spelling) + right.bytes
	a, b := left.number, right.number
	#partial switch op {
	case .Eq:          return minify_boolean(a == b, size), true
	case .NotEq:       return minify_boolean(a != b, size), true
	case .StrictEq:    return minify_boolean(left.boolean == right.boolean && a == b, size), true
	case .StrictNotEq: return minify_boolean(left.boolean != right.boolean || a != b, size), true
	case .Lt:          return minify_boolean(a < b, size), true
	case .LtEq:        return minify_boolean(a <= b, size), true
	case .Gt:          return minify_boolean(a > b, size), true
	case .GtEq:        return minify_boolean(a >= b, size), true
	case .Pow:
		// Transcendental powers can vary by JS engine. Fold only exact small integer powers.
		if math.trunc(a) != a || math.trunc(b) != b || b < 0 || b > 32 { return {}, false }
	}
	number, ok := js_number_binary(op, a, b)
	if op == .Pow && abs(number) >= (1 << 53) { return {}, false }
	return {number = number, bytes = size}, ok
}

// Evaluate a bounded subtree in postorder. A name, call, BigInt or other unknown
// operand leaves the expression in place with all its evaluation and exception behavior.
minify_constant :: proc(root: ^Expression) -> (MinifyConstant, bool) {
	Frame :: struct { node: ^Expression, visited: bool }
	limit :: 48
	frames: [limit]Frame
	values: [limit]MinifyConstant
	pending, count := 1, 0
	frames[0] = {root, false}
	for step in 0..<limit {
		if pending == 0 { break }
		pending -= 1
		frame := frames[pending]
		#partial switch n in frame.node^ {
		case ^NumericLiteral:
			values[count] = {number = n.value, bytes = len(n.raw)}
			count += 1
		case ^BooleanLiteral:
			values[count] = minify_boolean(n.value, n.value ? 4 : 5)
			count += 1
		case ^ParenthesizedExpression:
			frames[pending] = {n.expression, false}
			pending += 1
		case ^UnaryExpression:
			if frame.visited {
				assert(count >= 1)
				value, ok := minify_unary(n.operator, values[count-1])
				if !ok { return {}, false }
				values[count-1] = value
			} else {
				if pending + 2 > limit { return {}, false }
				frames[pending], frames[pending+1] = {frame.node, true}, {n.argument, false}
				pending += 2
			}
		case ^BinaryExpression:
			if frame.visited {
				assert(count >= 2)
				value, ok := minify_binary(n.operator, values[count-2], values[count-1])
				if !ok { return {}, false }
				count -= 1
				values[count-1] = value
			} else {
				if pending + 3 > limit { return {}, false }
				frames[pending], frames[pending+1], frames[pending+2] = {frame.node, true}, {n.right, false}, {n.left, false}
				pending += 3
			}
		case: return {}, false
		}
	}
	if pending != 0 { return {}, false }
	assert(count == 1)
	return values[0], true
}

minify_number_text :: proc(buffer: []byte, value: f64) -> string {
	if math.is_nan(value) || math.is_inf(value) { return "" }
	if value == 0 && math.sign_bit(value) { return "-0" }
	// Integer formatting avoids exponent punctuation and is exact up to 2^53.
	if abs(value) < (1 << 53) && value == math.trunc(value) {
		return strconv.write_int(buffer, i64(value), 10)
	}
	text := strconv.write_float(buffer, value, 'g', -1, 64)
	if len(text) > 0 && text[0] == '+' { text = text[1:] }
	roundtrip, ok := strconv.parse_f64(text)
	if !ok || transmute(u64)roundtrip != transmute(u64)value { return "" }
	return text
}

minify_expression :: proc(cg: ^Codegen, expr: ^Expression, parent_prec: int) -> bool {
	value: MinifyConstant
	#partial switch n in expr^ {
	case ^BooleanLiteral: value = minify_boolean(n.value, n.value ? 4 : 5)
	case ^BinaryExpression, ^UnaryExpression, ^ParenthesizedExpression:
		folded, ok := minify_constant(expr)
		if !ok { return false }
		value = folded
	case: return false
	}
	buffer: [64]byte
	text: string
	if value.boolean { text = value.number == 0 ? "!1" : "!0" }
	else { text = minify_number_text(buffer[:], value.number) }
	if len(text) == 0 { return false }
	// Retain grouping for a member receiver and for a unary left operand of **.
	group := parent_prec >= PREC_CALL || (parent_prec >= PREC_EXP && (text[0] == '-' || text[0] == '!'))
	separate := !group && text[0] == '-' && cg.pos > 0 && cg.buf[cg.pos-1] == '-'
	if len(text) + 2 * int(group) + int(separate) >= value.bytes { return false }
	if group { cg_byte(cg, '(') }
	if separate { cg_byte(cg, ' ') }
	if cg.sm != nil { sourcemap_record(cg.sm, u32(cg.pos), loc_from_expr(expr).start) }
	cg_str(cg, text)
	if group { cg_byte(cg, ')') }
	return true
}

// Only siblings in the same statement list may share a declaration keyword.
// An export, a label, a switch-case boundary or a single-statement loop body
// must retain its original binding visibility and control flow.
gen_statement_list_item :: proc(cg: ^Codegen, statements: []^Statement, index: int) {
	stmt := statements[index]
	if cg.cfg.join_declarations {
		if decl, ok := stmt^.(^VariableDeclaration); ok && !decl.declare && resource_kind(decl) == .None {
			before := index > 0 && minify_same_declaration(decl, statements[index-1])
			after := index + 1 < len(statements) && minify_same_declaration(decl, statements[index+1])
			if before || after {
				if before { cg_byte(cg, ',') }
				if cg.sm != nil {
					start := decl.declarations[0].loc.start if before else decl.loc.start
					sourcemap_record(cg.sm, u32(cg.pos), start)
				}
				if before {
					gen_variable_declarators(cg, decl, {}, false)
					if !after { cg_byte(cg, ';') }
				} else {
					gen_variable_declaration(cg, decl, false)
				}
				return
			}
		}
	}
	gen_statement(cg, stmt^)
}

minify_same_declaration :: proc(decl: ^VariableDeclaration, stmt: ^Statement) -> bool {
	next, ok := stmt^.(^VariableDeclaration)
	return ok && !next.declare && next.kind == decl.kind
}
