package kessel

import "core:strings"

// Lowering of the ES2022 class features for an older target: public fields,
// private names, `#x in o` and static blocks. They are lowered together
// because each is defined in terms of the others.
//
//     class C extends B {                 let x = new WeakMap();
//       #x = 1;                           class C extends B {
//       y = this.#x;                        constructor(...args) {
//       static z = 2;                         super(...args);
//       static { ready(this); }               init(this, x, 1);
//     }                                       define(this, "y", get(this, x));
//                                           }
//                                           static __static() {
//                                             delete this.__static;
//                                             define(this, "z", 2);
//                                             (() => { ready(this); })();
//                                             return this;
//                                           }
//                                         }
//                                         C.__static();
//
// Instance initializers run in the constructor, right after `super(...)`
// returns, where `this` and `super` mean what they meant in the initializer.
// A constructor binding that would capture a name the initializers use is
// renamed. Static initializers and blocks run in one static method, called
// once when the class has been created, so `this` and `super` again need no
// rewriting; the method removes itself first.
//
// Private state lives in WeakMaps and WeakSets that belong to one evaluation
// of the class: they are `let` bindings next to a class declaration, and a
// class expression that needs them is wrapped in an arrow function. A class
// defined in a loop therefore never shares them with an earlier iteration.
// Private methods stay in the class body under a generated public name, so
// they keep `super`; the static method takes them out before anything runs.

ClassFields :: enum u8 { Define, Assign }

ClassPrivateKind :: enum u8 { Field, Method, Accessor }

ClassPrivate :: struct {
	name:    string, // Without the `#`.
	kind:    ClassPrivateKind,
	static:  bool,
	storage: string, // Field: its WeakMap. Method: the function. Accessor: its descriptor.
	hidden:  string, // Method or accessor: the public key it keeps in the class body.
}

ClassTempKind :: enum u8 { Plain, Weak_Map, Weak_Set }

ClassTemp :: struct {
	name: string,
	kind: ClassTempKind,
}

LoweredClass :: struct {
	class:        ^ClassExpression,
	constructor:  Loc, // The written constructor; empty when there is none.
	privates:     [dynamic]ClassPrivate,
	brand:        string, // WeakSet of instances, when there are private methods.
	static_brand: string,
	temps:        [dynamic]ClassTemp,
	instance:     [dynamic]^Expression, // Initializer expressions, in order.
	initializers: [dynamic]Loc,         // Source ranges of field initializers.
	static_key:   string,               // Name of the static method, or empty.
	lowered:      bool,
	emitted:      bool, // The statement or expression around the class has been produced.
	wraps_super:  bool, // Initializers are attached to each `super(...)` call.
}

// Every class is recorded, lowered or not, so a `super(...)` call or a
// private name can be attributed to the innermost class around its offset.
class_register :: proc(
	cg: ^Codegen, class: ^ClassExpression) -> (info: ^LoweredClass, fresh: bool,
) {
	state := cg.transform
	if existing, known := state.classes[class.body.loc.start]; known { return existing, false }
	info = new(LoweredClass, state.allocator)
	info.class = class
	info.privates.allocator = state.allocator
	info.temps.allocator = state.allocator
	info.instance.allocator = state.allocator
	info.initializers.allocator = state.allocator
	state.classes[class.body.loc.start] = info
	append(&state.class_list, info)
	for element in class.body.body {
		if element.kind != .Constructor { continue }
		if value, present := element.value.?; present && value != nil {
			if function, ok := value^.(^FunctionExpression); ok && !function.no_body {
				info.constructor = function.loc
			}
		}
	}
	return info, true
}

class_needs_lowering :: proc(cg: ^Codegen, class: ^ClassExpression) -> bool {
	for element in class.body.body {
		if cg.cfg.strip_types && class_element_erased(element) { continue }
		if element.kind == .Field || element.kind == .StaticBlock { return true }
		if element.key != nil {
			if _, private := element.key^.(^PrivateIdentifier); private { return true }
		}
	}
	return false
}

// Lowers the class in place. `name` is the name the class would be given by
// its context when it has none of its own, or empty.
class_lower :: proc(cg: ^Codegen, class: ^ClassExpression, name: string) -> ^LoweredClass {
	state := cg.transform
	assert(state.target < .ES2022)
	if existing, known := state.classes[class.body.loc.start]; known { return existing }
	class_desugar_accessors(cg, class)
	info, _ := class_register(cg, class)
	if !class_needs_lowering(cg, class) { return info }
	// The model must describe the tree as written, before any of it moves.
	transform_model(cg)
	info.lowered = true
	class_collect_privates(cg, info)
	work := ClassWork{cg = cg, info = info}
	work.statics.allocator = state.allocator
	work.pending_keys.allocator = state.allocator
	work.elements = make([dynamic]ClassElement, 0, len(class.body.body) + 2, state.allocator)
	for &element in class.body.body { class_lower_element(&work, &element) }
	class_add_static_method(&work, name)
	class.body.body = work.elements
	class_add_constructor_work(cg, info)
	return info
}

ClassWork :: struct {
	cg:           ^Codegen,
	info:         ^LoweredClass,
	elements:     [dynamic]ClassElement,
	statics:      [dynamic]^Statement,  // Body of the static method.
	pending_keys: [dynamic]^Expression, // Field keys still to be evaluated in the class body.
}

class_collect_privates :: proc(cg: ^Codegen, info: ^LoweredClass) {
	for element in info.class.body.body {
		if cg.cfg.strip_types && class_element_erased(element) { continue }
		if element.key == nil { continue }
		key, private := element.key^.(^PrivateIdentifier)
		if !private { continue }
		kind := ClassPrivateKind.Field
		#partial switch element.kind {
		case .Method:    kind = .Method
		case .Get, .Set: kind = .Accessor
		}
		// The two halves of an accessor share one entry.
		if kind == .Accessor && class_private_find(info, key.name) != nil { continue }
		entry := ClassPrivate{name = key.name, kind = kind, static = element.static}
		entry.storage = codegen_fresh_runtime_binding(cg, "private")
		if kind == .Field {
			append(&info.temps, ClassTemp{entry.storage, .Weak_Map})
		} else {
			entry.hidden = codegen_fresh_runtime_binding(cg, "member")
			append(&info.temps, ClassTemp{entry.storage, .Plain})
			brand := &info.static_brand if element.static else &info.brand
			if brand^ == "" {
				brand^ = codegen_fresh_runtime_binding(cg, "brand")
				append(&info.temps, ClassTemp{brand^, .Weak_Set})
			}
		}
		append(&info.privates, entry)
	}
}

class_private_find :: proc(info: ^LoweredClass, name: string) -> ^ClassPrivate {
	for &entry in info.privates {
		if entry.name == name { return &entry }
	}
	return nil
}

class_lower_element :: proc(work: ^ClassWork, element: ^ClassElement) {
	cg := work.cg
	state := cg.transform
	if cg.cfg.strip_types && class_element_erased(element^) {
		append(&work.elements, element^)
		return
	}
	at := element.loc.start
	private: ^ClassPrivate
	if element.key != nil {
		if key, is_private := element.key^.(^PrivateIdentifier); is_private {
			private = class_private_find(work.info, key.name)
			assert(private != nil)
		}
	}
	switch element.kind {
	case .Field:
		class_lower_field(work, element, private)
		return
	case .StaticBlock:
		// An arrow called at once keeps `this` and gives the block its own scope.
		if value, present := element.value.?; present && value != nil {
			function := value^.(^FunctionExpression)
			arrow := new(ArrowFunctionExpression, state.allocator)
			block := new(BlockStatement, state.allocator)
			block^ = {loc = function.body.loc, body = function.body.body}
			arrow^ = {loc = {at, at}, body = block}
			call := target_call(state, transform_expression(state, arrow), nil, {at, at})
			append(&work.statics, class_statement(state, call, at))
		}
		return
	case .Constructor:
		append(&work.elements, element^)
		return
	case .Method, .Get, .Set, .IndexSignature:
	}
	kept := element^
	if private != nil {
		kept.key = transform_identifier(state, private.hidden, at)
		kept.computed = false
	}
	class_attach_pending_keys(work, &kept)
	append(&work.elements, kept)
}

// A computed field key is evaluated where the field was, among the other
// computed keys of the class. With the field gone, its evaluation moves into
// the key of the next member that stays.
class_attach_pending_keys :: proc(work: ^ClassWork, element: ^ClassElement) {
	if len(work.pending_keys) == 0 { return }
	state := work.cg.transform
	at := element.loc.start
	own := element.key
	if !element.computed {
		if id, plain := own^.(^Identifier); plain { own = class_string(state, id.name, at) }
	}
	sequence := new(SequenceExpression, state.allocator)
	sequence.loc = {at, at}
	sequence.expressions = make(
		[dynamic]^Expression, 0, len(work.pending_keys) + 1, state.allocator,
	)
	append(&sequence.expressions, ..work.pending_keys[:])
	append(&sequence.expressions, own)
	clear(&work.pending_keys)
	element.key = transform_expression(state, sequence)
	element.computed = true
}

class_lower_field :: proc(work: ^ClassWork, element: ^ClassElement, private: ^ClassPrivate) {
	cg := work.cg
	state := cg.transform
	info := work.info
	at := element.loc.start
	loc := Loc{at, at}
	key: ^Expression
	label := ""
	if private != nil {
		label = strings.concatenate({"#", private.name}, state.allocator)
	} else {
		key, label = class_field_key(work, element)
	}
	value, initialized := element.value.?
	if initialized && value != nil {
		append(&info.initializers, loc_from_expr(value))
		value = class_named_value(cg, value, key, label, at)
	} else {
		// Under assignment semantics a field without a value leaves no trace.
		if private == nil && state.class_fields == .Assign { return }
		value = target_void(state, loc)
	}
	this := new(ThisExpression, state.allocator)
	this.loc = loc
	target := transform_expression(state, this)
	init: ^Expression
	switch {
	case private != nil:
		store := transform_identifier(state, private.storage, at)
		init = class_helper_call(cg, .Private_Init, {target, store, value}, at)
	case state.class_fields == .Assign:
		computed := true
		if id, plain := element.key^.(^Identifier); plain && !element.computed {
			key = transform_identifier(state, id.name, at)
			computed = false
		}
		init = target_assign(state, target_member(state, target, key, computed, loc), value, loc)
	case:
		init = class_helper_call(cg, .Define_Field, {target, key, value}, at)
	}
	if element.static {
		append(&work.statics, class_statement(state, init, at))
	} else {
		append(&info.instance, init)
	}
}

// The key of a public field as an expression that can be evaluated again for
// every instance, and its text when that is known.
class_field_key :: proc(
	work: ^ClassWork, element: ^ClassElement) -> (key: ^Expression, label: string,
) {
	cg := work.cg
	state := cg.transform
	at := element.loc.start
	if !element.computed {
		#partial switch node in element.key^ {
		case ^Identifier:    return class_string(state, node.name, at), node.name
		case ^StringLiteral: return element.key, node.value
		}
		return element.key, ""
	}
	if legacy_key_is_constant(element.key) { return element.key, "" }
	// Evaluated once, with the conversion to a property key that the class
	// definition would have performed.
	temp := codegen_fresh_runtime_binding(cg, "key")
	append(&work.info.temps, ClassTemp{temp, .Plain})
	converted := class_helper_call(cg, .Prop_Key, {element.key}, at)
	store := target_assign(state, transform_identifier(state, temp, at), converted, {at, at})
	append(&work.pending_keys, store)
	return transform_identifier(state, temp, at), ""
}

// A function or class without a name takes the name of the field it
// initializes. A property definition names it the same way.
class_named_value :: proc(
	cg: ^Codegen, value, key: ^Expression, label: string, at: u32,
) -> ^Expression {
	state := cg.transform
	inner := target_unwrap(cg, value)
	anonymous := false
	#partial switch node in inner^ {
	case ^ArrowFunctionExpression: anonymous = true
	case ^FunctionExpression:      anonymous = node.id == nil
	case ^ClassExpression:         anonymous = node.id == nil
	}
	if !anonymous { return value }
	name := key
	if name == nil || label != "" { name = class_string(state, label, at) }
	if class, is_class := inner^.(^ClassExpression); is_class && label != "" {
		state.class_names[class.loc.start] = label
	}
	object := new(ObjectExpression, state.allocator)
	object.loc = {at, at}
	object.properties = make([dynamic]Property, 0, 1, state.allocator)
	append(
		&object.properties,
		Property{loc = {at, at}, key = name, value = value, kind = .Init, computed = true},
	)
	return target_member(state, transform_expression(state, object), name, true, {at, at})
}

class_string :: proc(state: ^TransformState, value: string, at: u32) -> ^Expression {
	node := new(StringLiteral, state.allocator)
	node^ = {loc = {at, at}, value = value}
	return transform_expression(state, node)
}

class_statement :: proc(state: ^TransformState, expression: ^Expression, at: u32) -> ^Statement {
	node := new(ExpressionStatement, state.allocator)
	node^ = {loc = {at, at}, expression = expression}
	statement := new(Statement, state.allocator)
	statement^ = node
	return statement
}

class_helper_call :: proc(
	cg: ^Codegen, helper: TransformHelper, arguments: []^Expression, at: u32,
) -> ^Expression {
	state := cg.transform
	callee := transform_identifier(state, transform_helper(cg, helper), at)
	return target_call(state, callee, arguments, {at, at})
}

class_this :: proc(state: ^TransformState, at: u32) -> ^Expression {
	node := new(ThisExpression, state.allocator)
	node.loc = {at, at}
	return transform_expression(state, node)
}

// Appends the static method that finishes the class: it removes itself,
// names an anonymous class, collects the private methods, and runs the
// static initializers and blocks in order.
class_add_static_method :: proc(work: ^ClassWork, name: string) {
	cg := work.cg
	state := cg.transform
	info := work.info
	class := info.class
	at := class.body.loc.start
	captures := false
	for entry in info.privates { captures ||= entry.kind != .Field }
	named := name != "" && class.id == nil
	if len(work.statics) == 0 && len(work.pending_keys) == 0 && !captures && !named { return }
	info.static_key = codegen_fresh_runtime_binding(cg, "static")
	body := make(
		[dynamic]^Statement, 0, len(work.statics) + len(info.privates) + 4, state.allocator,
	)
	own := target_member(
		state,
		class_this(state, at),
		transform_identifier(state, info.static_key, at),
		false,
		{at, at},
	)
	remove := new(UnaryExpression, state.allocator)
	remove^ = {loc = {at, at}, operator = .Delete, argument = own, prefix = true}
	append(&body, class_statement(state, transform_expression(state, remove), at))
	if named {
		arguments := [2]^Expression{class_this(state, at), class_string(state, name, at)}
		append(
			&body, class_statement(state, class_helper_call(cg, .Set_Name, arguments[:], at), at),
		)
	}
	class_static_captures(work, &body)
	if info.static_brand != "" {
		arguments := [2]^Expression{
			class_this(state, at), transform_identifier(state, info.static_brand, at),
		}
		append(
			&body,
			class_statement(state, class_helper_call(cg, .Private_Brand, arguments[:], at), at),
		)
	}
	append(&body, ..work.statics[:])
	result := new(ReturnStatement, state.allocator)
	result^ = {loc = {at, at}, argument = class_this(state, at)}
	returned := new(Statement, state.allocator)
	returned^ = result
	append(&body, returned)
	function := new(FunctionExpression, state.allocator)
	function.loc = {at, at}
	function.body = {loc = {at, at}, body = body}
	method := ClassElement{
		loc = {at, at}, kind = .Method, static = true,
		key = transform_identifier(state, info.static_key, at),
		value = transform_expression(state, function),
	}
	class_attach_pending_keys(work, &method)
	append(&work.elements, method)
}

// Takes each private method and accessor out of the class body, where it
// was defined under a generated name, and keeps it in its binding.
class_static_captures :: proc(work: ^ClassWork, body: ^[dynamic]^Statement) {
	cg := work.cg
	state := cg.transform
	info := work.info
	at := info.class.body.loc.start
	for entry in info.privates {
		if entry.kind == .Field { continue }
		holder := class_this(state, at)
		if !entry.static {
			prototype := transform_identifier(state, "prototype", at)
			holder = target_member(state, holder, prototype, false, {at, at})
		}
		label := strings.concatenate({"#", entry.name}, state.allocator)
		arguments := [3]^Expression{
			holder, class_string(state, entry.hidden, at), class_string(state, label, at),
		}
		taken := class_helper_call(cg, .Take_Member, arguments[:], at)
		store := target_assign(
			state, transform_identifier(state, entry.storage, at), taken, {at, at},
		)
		append(body, class_statement(state, store, at))
	}
}

// Puts the instance initializers where the constructor runs them.
class_add_constructor_work :: proc(cg: ^Codegen, info: ^LoweredClass) {
	state := cg.transform
	class := info.class
	at := class.body.loc.start
	if info.brand != "" {
		arguments := [2]^Expression{
			class_this(state, at), transform_identifier(state, info.brand, at),
		}
		inject_at(&info.instance, 0, class_helper_call(cg, .Private_Brand, arguments[:], at))
	}
	if len(info.instance) == 0 { return }
	derived := class.super_class != nil
	constructor: ^FunctionExpression
	for element in class.body.body {
		if element.kind != .Constructor { continue }
		if value, present := element.value.?; present && value != nil {
			if function, ok := value^.(^FunctionExpression); ok && !function.no_body {
				constructor = function
			}
		}
	}
	if constructor == nil {
		class_synthesize_constructor(cg, info, derived)
		return
	}
	class_rename_captures(cg, info, constructor.loc)
	// Parameter properties are assigned after the fields, as TypeScript does
	// when fields are defined; the printer would otherwise put them first.
	for &param in constructor.params {
		if param.accessibility == .None && !param.readonly && !param.override_ { continue }
		id, plain := param.pattern.(^Identifier)
		if !plain { continue }
		param.accessibility = .None
		param.readonly = false
		param.override_ = false
		target := target_member(
			state, class_this(state, at), transform_identifier(state, id.name, at), false, {at, at},
		)
		value := transform_identifier_exact(state, id.name, id.loc.start)
		append(&info.instance, target_assign(state, target, value, {at, at}))
	}
	if derived {
		info.wraps_super = true
		return
	}
	body := &constructor.body
	directives := min(len(body.directives), len(body.body))
	statements := make([dynamic]^Statement, 0, len(body.body) + len(info.instance), state.allocator)
	append(&statements, ..body.body[:directives])
	for init in info.instance { append(&statements, class_statement(state, init, body.loc.start)) }
	append(&statements, ..body.body[directives:])
	body.body = statements
}

class_synthesize_constructor :: proc(cg: ^Codegen, info: ^LoweredClass, derived: bool) {
	state := cg.transform
	class := info.class
	at := class.body.loc.start
	function := new(FunctionExpression, state.allocator)
	function.loc = {at, at}
	function.body.loc = {at, at}
	function.body.body = make([dynamic]^Statement, 0, len(info.instance) + 1, state.allocator)
	if derived {
		// `constructor(...args) { super(...args); ... }`
		name := codegen_fresh_runtime_binding(cg, "args")
		rest := new(RestElement, state.allocator)
		rest^ = {loc = {at, at}, argument = transform_identifier(state, name, at)^.(^Identifier)}
		function.params = make([dynamic]FunctionParameter, 0, 1, state.allocator)
		append(&function.params, FunctionParameter{loc = {at, at}, pattern = rest})
		spread := new(SpreadElement, state.allocator)
		spread^ = {loc = {at, at}, argument = transform_identifier(state, name, at)}
		parent := new(Super, state.allocator)
		parent.loc = {at, at}
		call := target_call(
			state,
			transform_expression(state, parent),
			{transform_expression(state, spread)},
			{at, at},
		)
		// This call is complete as written; the rule for `super(...)` skips it.
		state.super_done[call] = true
		append(&function.body.body, class_statement(state, call, at))
	}
	for init in info.instance { append(&function.body.body, class_statement(state, init, at)) }
	element := ClassElement{
		loc = {at, at}, kind = .Constructor,
		key = transform_identifier(state, "constructor", at),
		value = transform_expression(state, function),
	}
	inject_at(&class.body.body, 0, element)
}

// A field initializer is written in the class scope and now runs inside the
// constructor. A parameter or local of the constructor with a name the
// initializers read would capture that read, so the binding is renamed.
class_rename_captures :: proc(cg: ^Codegen, info: ^LoweredClass, constructor: Loc) {
	state := cg.transform
	model := transform_model(cg)
	read := make(map[string]bool, 16, context.temp_allocator)
	for ref in model.refs {
		for range in info.initializers {
			if ref.start < range.start || ref.start >= range.end { continue }
			// A name bound inside the initializer itself is not read from outside.
			if ref.resolved != SYMBOL_UNRESOLVED {
				declared := model.symbols[ref.resolved].decl_start
				if declared >= range.start && declared < range.end { continue }
			}
			read[ref.name] = true
		}
	}
	if len(read) == 0 { return }
	for symbol, index in model.symbols {
		if symbol.decl_start < constructor.start || symbol.decl_start >= constructor.end {
			continue
		}
		if !read[symbol.name] { continue }
		inside := false
		for range in info.initializers {
			inside ||= symbol.decl_start >= range.start && symbol.decl_start < range.end
		}
		if inside { continue }
		fresh := codegen_fresh_runtime_binding(cg, "local")
		if cg.renamed == nil { cg.renamed = make(map[u32]string, 8, state.allocator) }
		cg.renamed[symbol.decl_start] = fresh
		for ref in model.refs {
			if ref.resolved == SymbolId(index) { cg.renamed[ref.start] = fresh }
		}
	}
}

// `accessor x = v` is a private field with a getter and a setter over it:
//
//     #storage = v;
//     get x() { return this.#storage; }
//     set x(value) { this.#storage = value; }
//
// The keyword belongs to the decorators proposal and to no edition, so it is
// rewritten for every named target and wherever decorators are lowered.
class_desugar_accessors :: proc(cg: ^Codegen, class: ^ClassExpression) {
	state := cg.transform
	if state.target == .ESNext && state.decorators != .Legacy { return }
	found := false
	for element in class.body.body { found ||= element.is_accessor && element.kind == .Field }
	if !found { return }
	elements := make([dynamic]ClassElement, 0, len(class.body.body) + 4, state.allocator)
	for element in class.body.body {
		if !element.is_accessor || element.kind != .Field || class_element_erased(element) {
			append(&elements, element)
			continue
		}
		_, private := element.key^.(^PrivateIdentifier)
		if private || (element.computed && !legacy_key_is_constant(element.key)) {
			what := "an accessor field with a private or computed name cannot be lowered"
			cg_strip_unsupported(cg, element.loc, what)
			append(&elements, element)
			continue
		}
		class_desugar_accessor(cg, element, &elements)
	}
	class.body.body = elements
}

class_desugar_accessor :: proc(
	cg: ^Codegen, element: ClassElement, elements: ^[dynamic]ClassElement,
) {
	state := cg.transform
	loc := element.loc
	at := loc.start
	storage := codegen_fresh_runtime_binding(cg, "accessor")
	private_name :: proc(state: ^TransformState, name: string, loc: Loc) -> ^Expression {
		node := new(PrivateIdentifier, state.allocator)
		node^ = {loc = loc, name = name}
		return transform_expression(state, node)
	}
	slot :: proc(state: ^TransformState, name: string, loc: Loc) -> ^Expression {
		// The span lies inside the class, which is how the name is resolved.
		node := new(MemberExpression, state.allocator)
		node^ = {
			loc = loc,
			object = class_this(state, loc.start),
			property = private_name(state, name, loc),
		}
		return transform_expression(state, node)
	}
	field := ClassElement{
		loc = loc, kind = .Field, static = element.static, key = private_name(state, storage, loc),
	}
	if value, present := element.value.?; present && value != nil {
		// A function without a name is named after the accessor, not its storage.
		label := ""
		#partial switch key in element.key^ {
		case ^Identifier:    if !element.computed { label = key.name }
		case ^StringLiteral: label = key.value
		}
		named := value
		if label != "" { named = class_named_value(cg, value, nil, label, at) }
		field.value = named
	}
	append(elements, field)

	class_accessor_pair(cg, element, storage, elements)
}

// The getter and setter of a lowered accessor field, over its storage.
class_accessor_pair :: proc(
	cg: ^Codegen, element: ClassElement, storage: string, elements: ^[dynamic]ClassElement,
) {
	state := cg.transform
	loc := element.loc
	at := loc.start
	slot :: proc(state: ^TransformState, name: string, loc: Loc) -> ^Expression {
		// The span lies inside the class, which is how the name is resolved.
		private := new(PrivateIdentifier, state.allocator)
		private^ = {loc = loc, name = name}
		node := new(MemberExpression, state.allocator)
		node^ = {
			loc = loc, object = class_this(state, loc.start),
			property = transform_expression(state, private),
		}
		return transform_expression(state, node)
	}
	getter := new(FunctionExpression, state.allocator)
	getter.loc = loc
	getter.body.loc = {at, at}
	getter.body.body = make([dynamic]^Statement, 0, 1, state.allocator)
	result := new(ReturnStatement, state.allocator)
	result^ = {loc = {at, at}, argument = slot(state, storage, loc)}
	returned := new(Statement, state.allocator)
	returned^ = result
	append(&getter.body.body, returned)
	get := element
	get.kind = .Get
	get.is_accessor = false
	get.value = transform_expression(state, getter)
	get.typing = {}
	append(elements, get)

	setter := new(FunctionExpression, state.allocator)
	setter.loc = loc
	setter.body.loc = {at, at}
	name := codegen_fresh_runtime_binding(cg, "value")
	parameter := transform_identifier(state, name, at)^.(^Identifier)
	setter.params = make([dynamic]FunctionParameter, 0, 1, state.allocator)
	append(
		&setter.params,
		FunctionParameter{loc = {at, at}, pattern = parameter},
	)
	store := target_assign(
		state, slot(state, storage, loc), transform_identifier(state, name, at), loc,
	)
	setter.body.body = make([dynamic]^Statement, 0, 1, state.allocator)
	append(&setter.body.body, class_statement(state, store, at))
	set := element
	set.kind = .Set
	set.is_accessor = false
	set.decorators = nil
	set.value = transform_expression(state, setter)
	set.typing = {}
	append(elements, set)
}
