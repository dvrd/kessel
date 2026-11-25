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
	for _ in 0..<limit {
		if pending == 0 { break }
		pending -= 1
		frame := frames[pending]
		#partial switch n in frame.node^ {
		case ^NumericLiteral:
			if minify_legacy_octal(n.raw) { return {}, false }
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

// `010` is eight in sloppy code and `08` is eight in decimal. The parsed value
// of these legacy spellings is not relied on; they print as written.
minify_legacy_octal :: proc(raw: string) -> bool {
	return len(raw) > 1 && raw[0] == '0' && raw[1] >= '0' && raw[1] <= '9'
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
	text = minify_number_exponent(text)
	roundtrip, ok := strconv.parse_f64(text)
	if !ok || transmute(u64)roundtrip != transmute(u64)value { return "" }
	return text
}

// `1e+21` is `1e21` and `1e-06` is `1e-6`. The text is edited in place.
minify_number_exponent :: proc(text: string) -> string {
	bytes := transmute([]byte)text
	mark := -1
	for char, index in bytes { if char == 'e' { mark = index } }
	if mark < 0 { return text }
	read, write := mark + 1, mark + 1
	if read < len(bytes) && bytes[read] == '-' { read += 1; write += 1 }
	if read < len(bytes) && bytes[read] == '+' { read += 1 }
	for read + 1 < len(bytes) && bytes[read] == '0' { read += 1 }
	for read < len(bytes) { bytes[write] = bytes[read]; read += 1; write += 1 }
	return string(bytes[:write])
}

// Rewrite a decimal spelling as digits and a power of ten: `1000000` is `1e6`,
// `0.00025` is `25e-5` and `0.5` is `.5`. Returns the input when no form is shorter.
minify_number_compact :: proc(buffer: []byte, text: string) -> string {
	digits: [40]byte
	count, exponent, index := 0, 0, 0
	negative := len(text) > 0 && text[0] == '-'
	if negative { index = 1 }
	seen_point := false
	for index < len(text) && count < len(digits) {
		char := text[index]
		if char == '.' && !seen_point {
			seen_point = true
		} else if char >= '0' && char <= '9' {
			if count != 0 || char != '0' { digits[count] = char; count += 1 }
			if seen_point { exponent -= 1 }
		} else {
			break
		}
		index += 1
	}
	// Only plain decimals are rewritten. An exponent or an over-long input stays.
	if index != len(text) || count == 0 || 3 + count + 5 > len(buffer) { return text }
	for count > 1 && digits[count-1] == '0' { count -= 1; exponent += 1 }
	best := text
	scratch: [64]byte
	// Candidate 1: `.digits` for a value below one with no leading fractional zeros.
	if exponent == -count && count + 2 <= len(scratch) {
		length := 0
		if negative { scratch[length] = '-'; length += 1 }
		scratch[length] = '.'; length += 1
		copy(scratch[length:], digits[:count]); length += count
		if length < len(best) { copy(buffer, scratch[:length]); best = string(buffer[:length]) }
	}
	// Candidate 2: `digits e exponent`.
	if exponent != 0 {
		length := 0
		if negative { scratch[length] = '-'; length += 1 }
		copy(scratch[length:], digits[:count]); length += count
		scratch[length] = 'e'; length += 1
		power: [8]byte
		spelled := strconv.write_int(power[:], i64(exponent), 10)
		copy(scratch[length:], spelled); length += len(spelled)
		if length < len(best) { copy(buffer, scratch[:length]); best = string(buffer[:length]) }
	}
	return best
}

minify_expression :: proc(cg: ^Codegen, expr: ^Expression, parent_prec: int) -> bool {
	value: MinifyConstant
	#partial switch n in expr^ {
	case ^BooleanLiteral: value = minify_boolean(n.value, n.value ? 4 : 5)
	case ^NumericLiteral:
		if minify_legacy_octal(n.raw) { return false }
		value = {number = n.value, bytes = len(n.raw)}
	case ^BinaryExpression, ^UnaryExpression, ^ParenthesizedExpression:
		folded, ok := minify_constant(expr)
		if !ok { return false }
		value = folded
	case: return false
	}
	buffer: [64]byte
	text: string
	compact: [64]byte
	if value.boolean {
		text = value.number == 0 ? "!1" : "!0"
	} else {
		text = minify_number_text(buffer[:], value.number)
		if len(text) == 0 { return false }
		shorter := minify_number_compact(compact[:], text)
		// Accept the power-of-ten spelling only when it reads back as the same double.
		roundtrip, ok := strconv.parse_f64(shorter)
		if ok && transmute(u64)roundtrip == transmute(u64)value.number { text = shorter }
	}
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

// The terminator of a block's last statement is redundant before `}`. An
// empty statement is the exception: its `;` is the whole statement.
minify_trim_terminator :: proc(cg: ^Codegen, statements: []^Statement) {
	if !cg.cfg.compact_syntax || len(statements) == 0 { return }
	if cg.pos == 0 || cg.buf[cg.pos-1] != ';' { return }
	current := statements[len(statements)-1]
	for _ in 0..<cg.pos {
		#partial switch v in current^ {
		case ^EmptyStatement: return
		case ^IfStatement:      current = v.alternate.? or_else v.consequent
		case ^ForStatement:     current = v.body
		case ^ForInStatement:   current = v.body
		case ^ForOfStatement:   current = v.body
		case ^WhileStatement:   current = v.body
		case ^WithStatement:    current = v.body
		case ^LabeledStatement: current = v.body
		case:
			cg.pos -= 1
			return
		}
	}
}

minify_block_follows :: proc(cg: ^Codegen, stmt: ^Statement) -> bool {
	_, block := stmt^.(^BlockStatement)
	return cg.cfg.compact_syntax && block
}

// `var{a}=b` and `let[a]=b` need no space after the keyword.
minify_pattern_follows :: proc(cg: ^Codegen, declaration: ^VariableDeclaration) -> bool {
	if !cg.cfg.compact_syntax || len(declaration.declarations) == 0 { return false }
	plain := declaration.kind == .Var || declaration.kind == .Let || declaration.kind == .Const
	if !plain { return false }
	#partial switch _ in declaration.declarations[0].id {
	case ^ObjectPattern, ^ArrayPattern: return true
	}
	return false
}

// `(a)=>a` can be written `a=>a` when the parameter is a plain identifier.
minify_arrow_bare_parameter :: proc(cg: ^Codegen, arrow: ^ArrowFunctionExpression) -> bool {
	if !cg.cfg.compact_syntax || len(arrow.params) != 1 { return false }
	if arrow.type_parameters != nil || arrow.return_type != nil { return false }
	parameter := arrow.params[0]
	if parameter.default_val != nil || parameter.accessibility != .None { return false }
	if parameter.readonly { return false }
	id, plain := parameter.pattern.(^Identifier)
	return plain && id.type_annotation == nil && !id.optional
}

// Whether the printed operand certainly begins with punctuation. A constant
// operand may be replaced by its folded value, which can begin with a digit,
// so only spellings that survive folding count.
minify_starts_with_punctuation :: proc(cg: ^Codegen, expr: ^Expression) -> bool {
	current := expr
	for depth in 0..<64 {
		if current == nil { return false }
		#partial switch v in current^ {
		case ^StringLiteral, ^TemplateLiteral, ^ArrayExpression, ^ObjectExpression, ^RegExpLiteral:
			return true
		case ^BooleanLiteral:
			// Printed as `!0` or `!1` when it is the whole operand.
			return depth == 0 && cg.cfg.fold_constants
		case ^UnaryExpression:
			#partial switch v.operator {
			case .LogicalNot: return true
			case .Minus, .BitwiseNot:
				// `-5` stays `-5` and `~5` folds to `-6`. A nested operand could fold to a digit.
				_, literal := v.argument^.(^NumericLiteral)
				if literal { return true }
				_, constant := minify_constant(current)
				return !constant
			}
			return false
		case ^BinaryExpression:
			if _, constant := minify_constant(current); constant { return false }
			current = v.left
		case ^UpdateExpression:
			if v.prefix { return true }
			current = v.argument
		case ^LogicalExpression:        current = v.left
		case ^ConditionalExpression:    current = v.test
		case ^AssignmentExpression:     current = v.left
		case ^MemberExpression:         current = v.object
		case ^CallExpression:           current = v.callee
		case ^TaggedTemplateExpression: current = v.tag
		case ^SequenceExpression:
			if len(v.expressions) == 0 { return false }
			current = v.expressions[0]
		case: return false
		}
	}
	return false
}

// A keyword needs no space before punctuation: `return!0`, `case"a":`.
minify_keyword_space :: proc(cg: ^Codegen, operand: ^Expression) {
	if cg.cfg.compact_syntax && minify_starts_with_punctuation(cg, operand) { return }
	cg_byte(cg, ' ')
}
