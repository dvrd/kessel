package kessel

import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"

EnumConstant :: union { f64, string }
EnumConstantDeclaration :: struct {
	node: ^TSEnumDeclaration,
	members: ScopeId,
	symbol: SymbolId,
}

EnumConstants :: struct {
	allocator: mem.Allocator,
	declarations: [dynamic]EnumConstantDeclaration,
	reads: map[u32]string,             // Identifier use offset to the member being read.
	scopes: map[SymbolId]ScopeId,       // Merged declarations share their member scope.
	values: map[SemanticBindingKey]EnumConstant,
	inlined: map[u32]EnumConstant,
	erased: map[u32]bool,
	string_bytes_left: i64,
}

enum_constants_init :: proc(table: ^EnumConstants, alloc: mem.Allocator, source_length: int) {
	table^ = {
		allocator = alloc, declarations = make([dynamic]EnumConstantDeclaration, alloc),
		reads = make(map[u32]string, alloc), scopes = make(map[SymbolId]ScopeId, alloc),
		values = make(map[SemanticBindingKey]EnumConstant, alloc),
		inlined = make(map[u32]EnumConstant, alloc), erased = make(map[u32]bool, alloc),
		// A chain of string additions can double at every member. Keep the
		// original computation when folding would expand the input excessively.
		string_bytes_left = max(i64(64 * 1024), 8 * i64(source_length)),
	}
}

enum_static_member :: proc(member: ^MemberExpression) -> (id: ^Identifier, name: string, ok: bool) {
	if member.object == nil || member.property == nil { return }
	id, ok = member.object^.(^Identifier)
	if !ok { return }
	if member.computed {
		str, literal := member.property^.(^StringLiteral)
		if literal { return id, str.value, true }
	} else if prop, named := member.property^.(^Identifier); named {
		return id, prop.name, true
	}
	return nil, "", false
}

enum_constants_note_read :: proc(table: ^EnumConstants, member: ^MemberExpression) {
	if id, name, ok := enum_static_member(member); ok { table.reads[id.loc.start] = name }
}

// Resolve through the semantic model so shadowed bindings cannot acquire the
// enclosing enum's values. Keep a runtime object if a use escapes inlining.
enum_constants_resolve :: proc(table: ^EnumConstants, model: ^SemanticModel) {
	if len(table.declarations) == 0 { return }
	eligible := make(map[ScopeId]bool, table.allocator)
	keep := make(map[ScopeId]bool, table.allocator)
	opaque := make(map[ScopeId]bool, table.allocator)
	for declaration in table.declarations {
		table.scopes[declaration.symbol] = declaration.members
		if declaration.node.const_ { eligible[declaration.members] = true }
		if .Exported in model.symbols[declaration.symbol].flags { keep[declaration.members] = true }
		if !enum_constants_evaluate_members(table, model, declaration) {
			keep[declaration.members] = true
			opaque[declaration.members] = true
		}
	}
	for ref in model.refs {
		scope, found := table.scopes[ref.resolved]
		if !found || !eligible[scope] { continue }
		if member, read := table.reads[ref.start]; read && table.values[{scope, member}] != nil { continue }
		keep[scope] = true
		opaque[scope] = true
	}
	for ref in model.refs {
		scope, found := table.scopes[ref.resolved]
		if !found || !eligible[scope] || opaque[scope] { continue }
		member, read := table.reads[ref.start]
		if !read { continue }
		value := table.values[{scope, member}]
		if value == nil { continue }
		if str, literal := value.(string); literal && !enum_reserve_string(table, str) {
			keep[scope] = true
			continue
		}
		table.inlined[ref.start] = value
	}
	for declaration in table.declarations {
		if declaration.node.const_ && !keep[declaration.members] {
			table.erased[declaration.node.loc.start] = true
		}
	}
}

enum_constants_evaluate_members :: proc(table: ^EnumConstants, model: ^SemanticModel, declaration: EnumConstantDeclaration) -> bool {
	all_known := true
	previous: EnumConstant = f64(-1)
	for member in declaration.node.body.members {
		name, valid := enum_member_name(member.id)
		value: EnumConstant
		if expr, explicit := member.initializer.?; explicit {
			value = enum_constant_expression(table, model, declaration.members, expr, 0)
		} else if numeric, ok := previous.(f64); ok { value = numeric + 1 }
		if valid && value != nil {
			table.values[{declaration.members, name}] = value
		} else { all_known = false }
		previous = value
	}
	return all_known
}

enum_constant_expression :: proc(table: ^EnumConstants, model: ^SemanticModel, scope: ScopeId, expr: ^Expression, depth: u32) -> EnumConstant {
	// Non-constant or deeply nested expressions keep the original runtime evaluation.
	if expr == nil || depth >= PARSE_RESOURCE_AST_DEPTH { return nil }
	#partial switch node in expr^ {
	case ^NumericLiteral: return node.value
	case ^StringLiteral: return node.value
	case ^ParenthesizedExpression: return enum_constant_expression(table, model, scope, node.expression, depth + 1)
	case ^Identifier:
		if value, known := table.values[{scope, node.name}]; known { return value }
		if semantic_lookup(model, scope, node.name) == SYMBOL_UNRESOLVED {
			if node.name == "Infinity" { return math.INF_F64 }
			if node.name == "NaN" { return math.QNAN_F64 }
		}
	case ^MemberExpression:
		if id, name, ok := enum_static_member(node); ok {
			symbol := semantic_lookup(model, scope, id.name)
			if members, found := table.scopes[symbol]; found { return table.values[{members, name}] }
		}
	case ^UnaryExpression:
		value := enum_constant_expression(table, model, scope, node.argument, depth + 1)
		if number, numeric := value.(f64); numeric {
			#partial switch node.operator {
			case .Minus: return -number
			case .Plus: return number
			case .BitwiseNot: return f64(~i32(enum_u32(number)))
			}
		}
	case ^BinaryExpression:
		left := enum_constant_expression(table, model, scope, node.left, depth + 1)
		if left == nil { return nil }
		right := enum_constant_expression(table, model, scope, node.right, depth + 1)
		if right == nil { return nil }
		return enum_constant_binary(table, node.operator, left, right)
	case ^TemplateLiteral:
		builder := strings.builder_make(0, 16, table.allocator)
		for quasi, index in node.quasis {
			text := quasi.cooked.? or_else quasi.raw
			if !enum_reserve_string(table, text) { return nil }
			strings.write_string(&builder, text)
			if index == len(node.expressions) { break }
			value := enum_constant_expression(table, model, scope, node.expressions[index], depth + 1)
			if value == nil { return nil }
			if !enum_constant_write_string(table, &builder, value) { return nil }
		}
		return strings.to_string(builder)
	}
	return nil
}

enum_u32 :: proc(number: f64) -> u32 {
	if math.is_inf(number) || math.is_nan(number) { return 0 }
	value := js_number_remainder(math.trunc(number), f64(0x1_0000_0000))
	if value < 0 { value += 0x1_0000_0000 }
	return u32(value)
}

enum_constant_binary :: proc(table: ^EnumConstants, op: BinaryOperator, left, right: EnumConstant) -> EnumConstant {
	a, a_number := left.(f64)
	b, b_number := right.(f64)
	if !a_number || !b_number {
		if op != .Add { return nil }
		builder := strings.builder_make(0, 16, table.allocator)
		if !enum_constant_write_string(table, &builder, left) { return nil }
		if !enum_constant_write_string(table, &builder, right) { return nil }
		return strings.to_string(builder)
	}
	if value, ok := js_number_binary(op, a, b); ok { return value }
	return nil
}

// Numeric operators shared by TypeScript enums and JavaScript constant folding.
js_number_binary :: proc(op: BinaryOperator, a, b: f64) -> (value: f64, ok: bool) {
	#partial switch op {
	case .Add: return a + b, true
	case .Sub: return a - b, true
	case .Mul: return a * b, true
	case .Div: return a / b, true
	case .Mod: return js_number_remainder(a, b), true
	case .Pow:
		// ECMAScript propagates a NaN exponent and treats unit magnitudes
		// raised to infinity as indeterminate, unlike the platform pow.
		if math.is_nan(b) { return b, true }
		if math.is_inf(b) && abs(a) == 1 { return math.nan_f64(), true }
		return math.pow(a, b), true
	case .ShiftLeft: return f64(i32(enum_u32(a) << (enum_u32(b) & 31))), true
	case .ShiftRight: return f64(i32(enum_u32(a)) >> (enum_u32(b) & 31)), true
	case .ShiftRightUnsigned: return f64(enum_u32(a) >> (enum_u32(b) & 31)), true
	case .BitOr: return f64(i32(enum_u32(a) | enum_u32(b))), true
	case .BitAnd: return f64(i32(enum_u32(a) & enum_u32(b))), true
	case .BitXor: return f64(i32(enum_u32(a) ~ enum_u32(b))), true
	}
	return 0, false
}

// Subtract binary multiples of the divisor. Forming a rounded quotient first
// loses the low bits for cases such as 1e308 % 3 on the pinned Odin toolchain.
js_number_remainder :: proc(dividend, divisor: f64) -> f64 {
	if math.is_nan(dividend) || math.is_nan(divisor) || math.is_inf(dividend) || divisor == 0 {
		return math.nan_f64()
	}
	magnitude := abs(divisor)
	remainder := abs(dividend)
	if remainder < magnitude || math.is_inf(divisor) { return dividend }
	left, left_exp := math.frexp(remainder)
	right, right_exp := math.frexp(magnitude)
	shift := left_exp - right_exp
	if left < right { shift -= 1 }
	assert(shift >= 0)
	assert(shift <= 2097) // Exponents range from -1074 to 1023 in binary64.
	multiple := math.ldexp(magnitude, shift)
	for _ in 0..=shift {
		if remainder >= multiple { remainder -= multiple }
		if remainder < magnitude { break }
		multiple *= 0.5
	}
	return math.copy_sign(remainder, dividend)
}

enum_reserve_string :: proc(table: ^EnumConstants, text: string) -> bool {
	size := i64(len(text))
	if size > table.string_bytes_left { return false }
	table.string_bytes_left -= size
	return true
}

enum_constant_write_string :: proc(table: ^EnumConstants, builder: ^strings.Builder, value: EnumConstant) -> bool {
	buf: [64]byte
	text: string
	switch v in value {
	case string: text = v
	case f64: text = enum_number_string(buf[:], v)
	case: panic("expected an enum constant")
	}
	if !enum_reserve_string(table, text) { return false }
	strings.write_string(builder, text)
	return true
}

// JS uses decimal for exponents from -6 through 20 and omits exponent padding.
enum_number_string :: proc(buffer: []byte, value: f64) -> string {
	if value == 0 { return "0" }
	if math.is_nan(value) { return "NaN" }
	if math.is_inf(value, 1) { return "Infinity" }
	if math.is_inf(value, -1) { return "-Infinity" }
	magnitude := abs(value)
	format := byte('f') if magnitude >= 1e-6 && magnitude < 1e21 else byte('e')
	text := strconv.write_float(buffer, value, format, -1, 64, {})
	if format == 'e' {
		exponent := strings.index_byte(text, 'e') + 2
		if exponent < len(text) - 1 && buffer[exponent] == '0' {
			copy(buffer[exponent:], buffer[exponent + 1:len(text)])
			return string(buffer[:len(text) - 1])
		}
	}
	return text
}

gen_inlined_enum_member :: proc(cg: ^Codegen, member: ^MemberExpression) -> bool {
	id, _, named := enum_static_member(member)
	if !named { return false }
	value, known := cg.runtime_scope.enum_constants.inlined[id.loc.start]
	if !known { return false }
	// Group the replacement so numeric receivers, unary minus before **,
	// and a string at the start of a directive prologue retain their meaning.
	cg_byte(cg, '(')
	switch v in value {
	case string: gen_string_quoted(cg, v)
	case f64:
		buf: [64]byte
		switch {
		case math.is_nan(v): cg_str(cg, "0/0")
		case math.is_inf(v, 1): cg_str(cg, "1/0")
		case math.is_inf(v, -1): cg_str(cg, "-1/0")
		case v == 0 && math.sign_bit(v): cg_str(cg, "-0")
		case: cg_str(cg, enum_number_string(buf[:], v))
		}
	case: panic("expected an inlined enum value")
	}
	cg_byte(cg, ')')
	return true
}
