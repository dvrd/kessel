package kessel

import "core:strconv"
import "core:strings"


DeclarationMemberKey :: struct { property: DeclarationPropertyKey, static: bool }
DeclarationClassMember :: struct {
	getter, setter: ^FunctionExpression,
	overload, accessor_error, private_emitted: bool,
}

@(private)
dts_member_name :: proc(key: ^Expression) -> string {
	if key == nil { return "" }
	#partial switch k in key^ {
	case ^Identifier: return k.name
	case ^StringLiteral: return k.value
	}
	return ""
}

@(private)
dts_class :: proc(state: ^DeclarationEmit, s: ^ClassDeclaration) {
	cg := &state.writer
	if s.abstract { cg_str(cg, "abstract ") }
	cg_str(cg, "class")
	if id, ok := s.id.?; ok { cg_byte(cg, ' '); cg_str(cg, id.name) }
	dts_type_parameters(state, s.type_parameters, s.loc)
	gen_ts_type_parameter_declaration(cg, s.type_parameters)
	if base, ok := s.super_class.?; ok { dts_heritage(state, s, base) }
	for base, i in s.implements {
		cg_str(cg, " implements " if i == 0 else ", ")
		dts_reference(state, base.expression, false)
		gen_expression(cg, base.expression, PREC_CALL)
		gen_ts_type_arguments(cg, base.type_parameters)
	}
	cg_str(cg, " {"); cg_newline(cg); cg.depth += 1
	members := make(map[DeclarationMemberKey]DeclarationClassMember)
	private_names := false
	for el in s.body.body {
		if el.key == nil { continue }
		if _, private_name := el.key^.(^PrivateIdentifier); private_name { private_names = true; continue }
		name := dts_class_key(el)
		fn, callable := dts_method_value(el)
		if !callable { continue }
		entry := members[name]
		switch el.kind {
		case .Get: entry.getter = fn
		case .Set: entry.setter = fn
		case .Method, .Constructor: if fn.no_body { entry.overload = true }
		case .Field, .StaticBlock, .IndexSignature:
		}
		members[name] = entry
	}
	if private_names { cg_str(cg, "#private;"); cg_newline(cg) }
	for el in s.body.body {
		if el.kind == .Constructor { dts_parameter_properties(state, el) }
	}
	for el in s.body.body { dts_class_member(state, el, &members) }
	cg.depth -= 1; cg_byte(cg, '}')
}

// An extends clause must name its base. `extends null` and a dotted name are
// printed as written. For any other expression TypeScript declares a constant
// `<Class>_base` with the expression's inferred type and extends that.
@(private)
dts_heritage :: proc(state: ^DeclarationEmit, s: ^ClassDeclaration, base: ^Expression) {
	cg := &state.writer
	root := base
	for root != nil {
		member, property := root^.(^MemberExpression)
		if !property || member.computed { break }
		root = member.object
	}
	assert(root != nil)
	_, named := root^.(^Identifier)
	_, null := root^.(^NullLiteral)
	if named || (null && root == base) {
		state.private_owner = .Extends
		if id, ok := s.id.?; ok { state.private_name = id.name }
		dts_reference(state, base, true)
		state.private_owner = .Inferred
		cg_str(cg, " extends "); gen_expression(cg, base, PREC_CALL)
		gen_ts_type_arguments(cg, s.super_type_arguments)
		return
	}
	item := &state.items[state.current_item]
	type_start, errors_before := cg.pos, len(item.errors)
	inferred := dts_infer(state, base, false, 0)
	type_text := strings.clone(string(cg.buf[type_start:cg.pos]))
	cg.pos = type_start
	if !inferred || len(item.errors) != errors_before {
		// Whatever stopped the inference, the clause itself is the error. A
		// class expression is reported at its name or `class` keyword.
		resize(&item.errors, errors_before)
		span := get_expression_loc(base)
		if class, anonymous := base^.(^ClassExpression); anonymous {
			span = {class.loc.start, class.loc.start + u32(len("class"))}
			if id, has_name := class.id.?; has_name { span = id.loc }
		}
		dts_error(state, "TS9021", "Extends clause can't contain an expression with --isolatedDeclarations.", span)
		return
	}
	name := "default_base"
	if id, ok := s.id.?; ok { name = strings.concatenate({id.name, "_base"}) }
	bindings := &state.regions[state.region].bindings
	stem := name
	for suffix := 1; (name in bindings^); suffix += 1 {
		assert(suffix <= len(state.items) + 1) // Each taken name is a distinct binding.
		buffer: [24]byte
		name = strings.concatenate({stem, "_", strconv.write_int(buffer[:], i64(suffix), 10)})
	}
	item.preamble = strings.concatenate({"const ", name, ": ", type_text, ";"})
	cg_str(cg, " extends "); cg_str(cg, name)
	gen_ts_type_arguments(cg, s.super_type_arguments)
}

@(private)
dts_class_key :: proc(el: ClassElement) -> DeclarationMemberKey {
	return {dts_member_key(el.key, el.computed), el.static}
}

@(private)
dts_method_value :: proc(el: ClassElement) -> (^FunctionExpression, bool) {
	if el.kind == .Field || el.kind == .StaticBlock { return nil, false }
	if expr, ok := el.value.?; ok { if fn, method := expr^.(^FunctionExpression); method { return fn, true } }
	return nil, false
}

@(private)
dts_accessibility :: proc(cg: ^Codegen, access: ClassAccessibility) {
	if access == .Private { cg_str(cg, "private ") }
	if access == .Protected { cg_str(cg, "protected ") }
}

@(private)
dts_parameter_properties :: proc(state: ^DeclarationEmit, el: ClassElement) {
	fn, ok := dts_method_value(el)
	if !ok { return }
	cg := &state.writer
	for p in fn.params {
		if p.accessibility == .None && !p.readonly && !p.override_ { continue }
		pattern := p.pattern
		if assign, assigned := pattern.(^AssignmentPattern); assigned { pattern = assign.left }
		id, simple := pattern.(^Identifier)
		if !simple { continue }
		dts_accessibility(cg, p.accessibility)
		if p.readonly { cg_str(cg, "readonly ") }
		cg_str(cg, id.name)
		if id.optional { cg_byte(cg, '?') }
		if p.accessibility != .Private {
			cg_str(cg, ": ")
			init := p.default_val.? or_else nil
			if assign, assigned := p.pattern.(^AssignmentPattern); assigned { init = assign.right }
			// The property is always present, so only `?` adds undefined to it.
			state.private_owner = .Constructor
			dts_parameter_type(state, p, id.type_annotation, init, id.optional, true, id.loc, 0)
			state.private_owner = .Inferred
		}
		cg_byte(cg, ';'); cg_newline(cg)
	}
}

@(private)
dts_class_member :: proc(state: ^DeclarationEmit, el: ClassElement, members: ^map[DeclarationMemberKey]DeclarationClassMember) {
	if el.kind == .IndexSignature {
		gen_ts_signature(&state.writer, el.typing.index_signature)
		cg_byte(&state.writer, ';')
		cg_newline(&state.writer)
		return
	}
	if el.kind == .StaticBlock || el.key == nil { return }
	if _, private_name := el.key^.(^PrivateIdentifier); private_name { return }
	key := dts_class_key(el)
	entry := members^[key]
	fn, callable := dts_method_value(el)
	if callable && entry.overload && !fn.no_body { return }
	if el.accessibility == .Private && el.kind == .Method {
		// Every overload of a private method erases to the same bare name.
		if entry.private_emitted { return }
		entry.private_emitted = true
		members^[key] = entry
	}
	cg := &state.writer
	state.private_owner, state.private_name = dts_member_owner(el), dts_member_name(el.key)
	defer state.private_owner = .Inferred
	dts_accessibility(cg, el.accessibility)
	if el.static { cg_str(cg, "static ") }
	if el.abstract { cg_str(cg, "abstract ") }
	if el.readonly { cg_str(cg, "readonly ") }
	if el.is_accessor { cg_str(cg, "accessor ") }
	if el.kind == .Get { cg_str(cg, "get ") }
	if el.kind == .Set { cg_str(cg, "set ") }
	static_key := dts_property_key(state, el.key, el.computed)
	if !static_key && (el.kind != .Method || !dts_key_may_index(state, el.key)) { return }
	if el.optional { cg_byte(cg, '?') }
	loc := get_expression_loc(el.key)
	if el.computed { loc = dts_computed_span(state, loc) }
	// `static constructor()` is an error TypeScript still prints like a constructor.
	static_constructor := el.static && el.kind == .Method && !el.computed && state.private_name == "constructor"
	if (el.kind == .Constructor || static_constructor) && callable {
		cg_byte(cg, '(')
		if el.accessibility != .Private { dts_parameters(state, fn.params[:], 0) }
		cg_byte(cg, ')')
	} else if el.accessibility == .Private {
		// Private members still distinguish otherwise identical nominal classes.
		// Their types are erased, and a setter's parameter is always `value`.
		if el.kind == .Get { cg_str(cg, "()") }
		if el.kind == .Set { cg_str(cg, "(value)") }
	} else if el.kind == .Get || el.kind == .Set {
		dts_accessor(state, el, entry, loc, members)
	} else if callable {
		dts_method_signature(state, fn, loc, false, 0, false)
	} else if ty, ok := el.typing.annotation.?; ok {
		cg_str(cg, ": "); gen_ts_type(cg, ty.type_annotation)
	} else {
		init := el.value.? or_else nil
		kind := dts_primitive_type(init)
		literal := el.readonly && kind != "" && kind != "null" && kind != "undefined"
		cg_str(cg, " = " if literal && !el.optional else ": ")
		dynamic_template := false
		if init != nil { if e, ok := init^.(^TemplateLiteral); ok { dynamic_template = len(e.expressions) != 0 } }
		if (el.readonly && dynamic_template) || !dts_infer(state, init, literal, 0) {
			dts_error(state, "TS9012", "Property must have an explicit type annotation with --isolatedDeclarations.", loc)
		} else if el.optional && init != nil && dts_optional_inferred_field(init) { cg_str(cg, " | undefined") }
	}
	cg_byte(cg, ';'); cg_newline(cg)
}

@(private)
dts_member_owner :: proc(el: ClassElement) -> DeclarationPrivateOwner {
	switch el.kind {
	case .Constructor: return .Constructor
	case .Set: return .Accessor
	case .Get: return .StaticGetter if el.static else .Getter
	case .Method: return .StaticMethod if el.static else .Method
	case .Field: return .StaticProperty if el.static else .Property
	case .StaticBlock, .IndexSignature:
	}
	return .Inferred
}

@(private)
dts_accessor :: proc(state: ^DeclarationEmit, el: ClassElement, entry: DeclarationClassMember, loc: Loc, members: ^map[DeclarationMemberKey]DeclarationClassMember) {
	cg := &state.writer
	get_type, set_type: Maybe(^TSTypeAnnotation)
	set_pattern: Pattern
	if entry.getter != nil { get_type = entry.getter.return_type }
	if entry.setter != nil && len(entry.setter.params) > 0 {
		param := entry.setter.params[len(entry.setter.params) - 1]
		set_pattern = param.pattern
		set_type = dts_setter_annotation(set_pattern)
		if el.kind == .Set && set_type != nil {
			cg_byte(cg, '('); dts_parameter(state, param, true, 0); cg_byte(cg, ')')
			return
		}
	}
	chosen := get_type if get_type != nil else set_type
	if el.kind == .Get {
		cg_str(cg, "(): ")
	} else {
		cg_byte(cg, '('); gen_pattern(cg, set_pattern); cg_str(cg, ": ")
	}
	if ty, ok := chosen.?; ok { gen_ts_type(cg, ty.type_annotation) } else {
		expr: ^Expression
		body: []^Statement
		if entry.getter != nil {
			body = entry.getter.body.body[:]
			expr = dts_return_expression(body)
		}
		private_mark := dts_private_push(state, body)
		defer dts_private_pop(state, private_mark)
		if !dts_infer(state, expr, false, 0) && !entry.accessor_error {
			key := dts_class_key(el)
			reported := entry
			reported.accessor_error = true
			members^[key] = reported
			loc := loc
			if el.kind == .Set && entry.setter != nil && len(entry.setter.params) > 0 { loc = get_pattern_loc(entry.setter.params[0].pattern) }
			dts_error(state, "TS9009", "At least one accessor must have an explicit type annotation with --isolatedDeclarations.", loc)
		}
	}
	if el.kind == .Set { cg_byte(cg, ')') }
}

@(private)
dts_method_signature :: proc(state: ^DeclarationEmit, fn: ^FunctionExpression, loc: Loc, arrow: bool, depth: int, force_return: bool) {
	dts_signature(state, fn.params[:], fn.type_parameters, fn.return_type, dts_return_expression(fn.body.body[:]), fn.loc, loc, force_return || fn.async || fn.generator, arrow, depth, method = true, body = fn.body.body[:])
}

@(private)
dts_property_key :: proc(state: ^DeclarationEmit, key: ^Expression, computed: bool, inferred_object := false) -> bool {
	cg := &state.writer
	named := true
	if inferred_object {
		// An inferred object type spells literal names canonically: `"a"` as
		// `a`, `0x10` as `16`, and a computed literal without its brackets.
		if literal, known := dts_literal_key(key); known {
			dts_print_object_key(cg, literal)
			return true
		}
	}
	if computed {
		_, known := dts_literal_key(key)
		named = known || dts_global_symbol_member(state, key)
		if !named {
			loc := dts_computed_span(state, get_expression_loc(key))
			dts_error(state, "TS9038", "Computed property names on class or object literals cannot be inferred with --isolatedDeclarations.", loc)
		}
		// TypeScript keeps the binding of a name that could be an index key.
		// A literal-typed name is rejected without declaring its binding.
		if root := dts_entity_name_root(key); root != nil {
			if named || dts_key_may_index(state, key) { dts_reference(state, root, true) }
		}
		cg_byte(cg, '[')
	}
	gen_expression(cg, key, PREC_ASSIGN)
	if computed { cg_byte(cg, ']') }
	return named
}

DeclarationKeyType :: enum { Unknown, Index, Other }

// TypeScript reports TS9038 for a dynamic method name and still checks the
// method's signature when the name could act as an index signature key: a
// dotted name whose type is string, number, symbol, any, or unresolved. A
// name declared here with another type, or with one literal type, is not.
@(private)
dts_key_may_index :: proc(state: ^DeclarationEmit, key: ^Expression) -> bool {
	root := dts_entity_name_root(key)
	if root == nil { return false }
	if root != key { return true } // A property path has no local annotation to read.
	name := root^.(^Identifier).name
	for index in dts_lookup(state, name, .Value) {
		item := &state.items[index]
		#partial switch decl in item.statement {
		case ^FunctionDeclaration, ^ClassDeclaration, ^TSEnumDeclaration, ^TSModuleDeclaration:
			return false
		case ^VariableDeclaration:
			entry := decl.declarations[item.part]
			id, plain := entry.id.(^Identifier)
			if !plain { return true }
			if annotation, typed := id.type_annotation.?; typed {
				return dts_key_type(state, annotation.type_annotation) != .Other
			}
			init, has_init := entry.init.?
			if !has_init { return true }
			// A const literal has a literal type and names a real property.
			if decl.kind == .Const && dts_primitive_type(init) != "" { return false }
			if call, called := init^.(^CallExpression); called && decl.kind == .Const {
				if callee, named := call.callee^.(^Identifier); named && callee.name == "Symbol" {
					return false // `const k = Symbol()` is a unique symbol.
				}
			}
			return true
		}
	}
	return true
}

// Classify an annotation without a checker. A union indexes only when every
// member could, and it has more than one literal member.
@(private)
dts_key_type :: proc(state: ^DeclarationEmit, annotation: ^TSType) -> DeclarationKeyType {
	pending := make([dynamic]^TSType, 0, 4)
	append(&pending, annotation)
	members := 0
	literals := 0
	for len(pending) > 0 {
		ty, _ := dts_accessor_type_root(state, pop(&pending))
		if ty == nil { return .Unknown }
		members += 1
		#partial switch t in ty^ {
		case ^TSUnionType:
			members -= 1
			// A cyclic alias cannot grow the queue past the input's own size.
			if members + len(pending) > len(state.items) + 64 { return .Unknown }
			append(&pending, ..t.types[:])
		case ^TSKeywordType:
			#partial switch t.kind {
			case .String, .Number, .Symbol, .Any, .Never:
			case: return .Other
			}
		case ^TSLiteralType:
			#partial switch _ in t.literal^ {
			case ^StringLiteral, ^NumericLiteral, ^TemplateLiteral: literals += 1
			case: return .Other
			}
		case ^TSTemplateLiteralType:
		case ^TSTypeReference:
			// An interface or class type is never a property key. An unresolved
			// or imported name has an unknown type, which TypeScript accepts.
			if id, plain := t.type_name^.(^Identifier); plain {
				for index in dts_lookup(state, id.name, .Type) {
					#partial switch _ in state.items[index].statement {
					case ^TSInterfaceDeclaration, ^ClassDeclaration: return .Other
					}
				}
			}
			return .Unknown
		case: return .Other
		}
	}
	if members == 1 && literals == 1 { return .Other }
	return .Index
}

// A global well-known symbol can be named directly in a declaration file.
// Local bindings named Symbol or globalThis must still pass isolated-declaration checks.
@(private)
dts_global_symbol_member :: proc(state: ^DeclarationEmit, key: ^Expression) -> bool {
	if key == nil { return false }
	expr := key
	if chain, ok := expr^.(^ChainExpression); ok { expr = chain.expression }
	member, ok := expr^.(^MemberExpression)
	if !ok || member.computed { return false }
	if _, named := member.property^.(^Identifier); !named { return false }
	if base, plain := member.object^.(^Identifier); plain {
		return base.name == "Symbol" && !dts_shadows_global(state, "Symbol")
	}
	object, qualified := member.object^.(^MemberExpression)
	if !qualified || object.computed { return false }
	root, global := object.object^.(^Identifier)
	field, symbol := object.property^.(^Identifier)
	return global && symbol && root.name == "globalThis" && field.name == "Symbol" && !dts_shadows_global(state, "globalThis")
}

// A top-level `var` in a script is the global variable itself, so
// `var Symbol: SymbolConstructor` redeclares the global and does not hide it.
@(private)
dts_shadows_global :: proc(state: ^DeclarationEmit, name: string) -> bool {
	for index in dts_lookup(state, name, .Value) {
		item := &state.items[index]
		decl, variable := item.statement.(^VariableDeclaration)
		if variable && decl.kind == .Var && item.region == 0 && !state.module { continue }
		return true
	}
	return false
}

DeclarationLiteralKey :: union {string, f64}

@(private)
dts_literal_key :: proc(key: ^Expression) -> (DeclarationLiteralKey, bool) {
	assert(key != nil)
	#partial switch node in key^ {
	case ^StringLiteral: return node.value, true
	case ^NumericLiteral: return node.value, true
	case ^TemplateLiteral:
		if len(node.expressions) == 0 {
			assert(len(node.quasis) == 1)
			return node.quasis[0].cooked.? or_else node.quasis[0].raw, true
		}
	case ^UnaryExpression:
		if num, ok := node.argument^.(^NumericLiteral); ok {
			if node.operator == .Plus { return num.value, true }
			if node.operator == .Minus { return -num.value, true }
		}
	}
	return nil, false
}

// Inferred object types spell a computed literal as a property name. Negative
// numbers still need brackets and string names must be valid IdentifierNames.
@(private)
dts_print_object_key :: proc(cg: ^Codegen, key: DeclarationLiteralKey) {
	switch name in key {
	case string:
		valid := len(name) > 0
		for cp, offset in name {
			valid = is_id_start_codepoint(u32(cp)) if offset == 0 else is_id_cont_codepoint(u32(cp))
			if !valid { break }
		}
		if valid { cg_str(cg, name) } else { gen_string_quoted(cg, name) }
	case f64:
		if name < 0 { cg_byte(cg, '[') }
		buf: [64]byte
		cg_str(cg, enum_number_string(buf[:], name))
		if name < 0 { cg_byte(cg, ']') }
	}
}

@(private)
dts_object_accessor :: proc(state: ^DeclarationEmit, property: Property, key: DeclarationPropertyKey, entry: DeclarationObjectAccessor, literal: bool, depth: int) {
	cg := &state.writer
	if key.dynamic_start == 0 && entry.getter != nil && entry.setter != nil && len(entry.setter.params) > 0 {
		param := &entry.setter.params[len(entry.setter.params) - 1]
		get_type, read := entry.getter.return_type.?
		set_type, write := dts_setter_annotation(param.pattern).?
		if read && write {
			if dts_typed_accessors(state, key.name, entry.numeric, get_type.type_annotation, param, set_type.type_annotation) { return }
		}
	}
	cg_byte(cg, ' ')
	if key.dynamic_start != 0 {
		if literal { cg_str(cg, "readonly ") }
		if !dts_property_key(state, property.key, true) { return }
	} else {
		if entry.setter == nil { cg_str(cg, "readonly ") }
		dts_print_accessor_name(cg, key.name, entry.numeric)
	}
	cg_str(cg, ": ")
	ty: Maybe(^TSTypeAnnotation)
	expr: ^Expression
	getter_body: []^Statement
	if entry.getter != nil {
		ty = entry.getter.return_type
		if !literal { expr = dts_return_expression(entry.getter.body.body[:]) }
		getter_body = entry.getter.body.body[:]
	}
	private_mark := dts_private_push(state, getter_body)
	defer dts_private_pop(state, private_mark)
	loc := get_expression_loc(property.key)
	if property.computed { loc = dts_computed_span(state, loc) }
	if entry.setter != nil && len(entry.setter.params) > 0 {
		param := entry.setter.params[len(entry.setter.params) - 1]
		if ty == nil { ty = dts_setter_annotation(param.pattern) }
		if property.kind == .Set { loc = get_pattern_loc(param.pattern) }
	}
	if annotation, ok := ty.?; ok { gen_ts_type(cg, annotation.type_annotation) } else if !dts_infer(state, expr, false, depth + 1) {
		dts_error(state, "TS9009", "At least one accessor must have an explicit type annotation with --isolatedDeclarations.", loc)
	}
	cg_byte(cg, ';')
}

@(private)
dts_computed_span :: proc(state: ^DeclarationEmit, inner: Loc) -> Loc {
	source := state.writer.source
	comments := state.job.lexer.comments[:]
	assert(inner.start > 0)
	assert(int(inner.end) < len(source))
	loc := inner
	// The brackets can be separated from the expression by comments that
	// themselves contain brackets. Skip the parser's complete comment spans.
	if source[loc.start - 1] != '[' {
		before := codegen_comment_lower_bound(comments, loc.start)
		for loc.start > 0 {
			if before > 0 && comments[before - 1].end == loc.start {
				before -= 1
				loc.start = comments[before].start
				continue
			}
			if source[loc.start - 1] == '[' { break }
			loc.start -= 1
		}
	}
	if source[loc.end] != ']' {
		after := codegen_comment_lower_bound(comments, loc.end)
		for int(loc.end) < len(source) && source[loc.end] != ']' {
			if after < len(comments) && comments[after].start == loc.end {
				loc.end = comments[after].end
				after += 1
			} else { loc.end += 1 }
		}
	}
	assert(loc.start > 0)
	assert(int(loc.end) < len(source))
	return {loc.start - 1, loc.end + 1}
}

@(private)
dts_optional_inferred_field :: proc(init: ^Expression) -> bool {
	expr := init
	for expr != nil {
		#partial switch e in expr^ {
		case ^ParenthesizedExpression: expr = e.expression
		case ^TSAsExpression:
			if _, array := e.expression^.(^ArrayExpression); array { return dts_is_const_type(e.type_annotation) }
			if _, object := e.expression^.(^ObjectExpression); object { return dts_is_const_type(e.type_annotation) }
			return false
		case ^TSTypeAssertion: return false
		case: return dts_primitive_type(expr) != "undefined"
		}
	}
	return false
}
