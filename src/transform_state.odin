package kessel

import "core:mem"
import "core:strings"

// Shared state for the lowering transforms that run while the printer walks
// the tree: decorators, target lowering and React Refresh. The printer holds
// one pointer to it, nil unless a lowering was requested, so every hook in
// codegen.odin costs a single nil check on the ordinary printing path.

TransformDecorators :: enum u8 { Preserve, Legacy, Standard }

// Helpers are emitted as hoisted function declarations at the end of the
// program, once, and only when a lowering used them. Each gets a binding
// that cannot collide with a name in the source.
TransformHelper :: enum u8 {
	Decorate, Decorate_Param, Decorate_Metadata,
	Define_Field, Prop_Key, Set_Name, Take_Member,
	Private_Init, Private_Brand, Private_Get, Private_Set, Private_Method,
	Private_Accessor_Get, Private_Accessor_Set, Private_Readonly, Private_In,
}

TransformState :: struct {
	job:           ^ParseJob,
	allocator:     mem.Allocator,
	decorators:    TransformDecorators,
	emit_metadata: bool,
	helpers:       [TransformHelper]string, // Empty until the helper is first used.
	model:         ^SemanticModel,          // Built on first use; most files never need it.
	enums:         EnumConstants,           // Enum declarations found while building the model.
	target:        TransformTarget,
	temp_scopes:   [dynamic][dynamic]string, // Per open function body; the program is first.
	// Identifier offsets bound to a declaration in the file.
	local_refs:    map[u32]bool,
	math_checked:  bool,
	refresh:       RefreshOptions,
	class_fields:  ClassFields,
	classes:       map[u32]^LoweredClass,   // By the offset of the class body.
	class_list:    [dynamic]^LoweredClass,
	class_names:   map[u32]string,          // Contextual names of anonymous class expressions.
	super_done:    map[^Expression]bool,    // `super(...)` calls that already carry initializers.
	weak_checked:  bool,
}

// Reads of intrinsics inside a helper resolve in module scope, so a source
// binding with the same name would silently replace the intrinsic.
TRANSFORM_HELPER_GLOBALS := [TransformHelper][]string{
	.Decorate          = {"Object", "Reflect"},
	.Decorate_Param    = {},
	.Decorate_Metadata = {"Reflect"},
	.Define_Field         = {"Object"},
	.Prop_Key             = {"Reflect"},
	.Set_Name             = {"Object"},
	.Take_Member          = {"Object"},
	.Private_Init         = {"TypeError"},
	.Private_Brand        = {"TypeError"},
	.Private_Get          = {"TypeError"},
	.Private_Set          = {"TypeError"},
	.Private_Method       = {"TypeError"},
	.Private_Accessor_Get = {"TypeError"},
	.Private_Accessor_Set = {"TypeError"},
	.Private_Readonly     = {"TypeError"},
	.Private_In           = {"TypeError"},
}

TRANSFORM_HELPER_KINDS := [TransformHelper]string{
	.Decorate          = "decorate",
	.Decorate_Param    = "param",
	.Decorate_Metadata = "metadata",
	.Define_Field         = "define",
	.Prop_Key             = "key_of",
	.Set_Name             = "name",
	.Take_Member          = "take",
	.Private_Init         = "private_init",
	.Private_Brand        = "private_brand",
	.Private_Get          = "private_get",
	.Private_Set          = "private_set",
	.Private_Method       = "private_method",
	.Private_Accessor_Get = "private_getter",
	.Private_Accessor_Set = "private_setter",
	.Private_Readonly     = "private_readonly",
	.Private_In           = "private_in",
}

// Every line ends a statement or opens or closes a block, so the compact
// printer can join the trimmed lines without changing the token stream.
TRANSFORM_HELPER_BODIES := [TransformHelper]string{
	.Decorate = `(decorators, target, key, desc) {
  var c = arguments.length;
  var r = desc;
  if (c < 3) r = target;
  else if (desc === null) r = desc = Object.getOwnPropertyDescriptor(target, key);
  if (typeof Reflect === "object" && typeof Reflect.decorate === "function") {
    r = Reflect.decorate(decorators, target, key, desc);
  } else {
    for (var i = decorators.length - 1; i >= 0; i--) {
      var d = decorators[i];
      if (d) r = (c < 3 ? d(r) : c > 3 ? d(target, key, r) : d(target, key)) || r;
    }
  }
  if (c > 3 && r) Object.defineProperty(target, key, r);
  return r;
}`,
	.Decorate_Param = `(index, decorator) {
  return function (target, key) {
    decorator(target, key, index);
  };
}`,
	.Decorate_Metadata = `(key, value) {
  if (typeof Reflect === "object" && typeof Reflect.metadata === "function") {
    return Reflect.metadata(key, value);
  }
}`,
	.Define_Field = `(target, key, value) {
  var field = { value: value, enumerable: true, configurable: true, writable: true };
  Object.defineProperty(target, key, field);
  return value;
}`,
	.Prop_Key = `(value) {
  return Reflect.ownKeys({ [value]: 0 })[0];
}`,
	.Set_Name = `(target, name) {
  var own = Object.getOwnPropertyDescriptor(target, "name");
  var unnamed = own && own.value === "";
  if (unnamed) Object.defineProperty(target, "name", { value: name, configurable: true });
}`,
	.Take_Member = `(target, key, name) {
  var member = Object.getOwnPropertyDescriptor(target, key);
  delete target[key];
  var rename = function (callee, text) {
    if (callee) Object.defineProperty(callee, "name", { value: text, configurable: true });
  };
  if ("value" in member) {
    rename(member.value, name);
    return member.value;
  }
  rename(member.get, "get " + name);
  rename(member.set, "set " + name);
  return member;
}`,
	.Private_Init = `(target, store, value) {
  if (store.has(target)) throw new TypeError("Cannot initialize a private field twice");
  store.set(target, value);
  return value;
}`,
	.Private_Brand = `(target, brand) {
  if (brand.has(target)) throw new TypeError("Cannot initialize private methods twice");
  brand.add(target);
}`,
	.Private_Get = `(target, store) {
  if (!store.has(target)) throw new TypeError("Cannot read an absent private member");
  return store.get(target);
}`,
	.Private_Set = `(target, store, value) {
  if (!store.has(target)) throw new TypeError("Cannot write an absent private member");
  store.set(target, value);
  return value;
}`,
	.Private_Method = `(target, brand, method) {
  if (!brand.has(target)) throw new TypeError("Cannot read an absent private member");
  return method;
}`,
	.Private_Accessor_Get = `(target, brand, accessor) {
  if (!brand.has(target)) throw new TypeError("Cannot read an absent private member");
  if (!accessor.get) throw new TypeError("The private accessor was defined without a getter");
  return accessor.get.call(target);
}`,
	.Private_Accessor_Set = `(target, brand, accessor, value) {
  if (!brand.has(target)) throw new TypeError("Cannot write an absent private member");
  if (!accessor.set) throw new TypeError("The private accessor was defined without a setter");
  accessor.set.call(target, value);
  return value;
}`,
	.Private_Readonly = `(target, brand, value) {
  if (!brand.has(target)) throw new TypeError("Cannot write an absent private member");
  throw new TypeError("A private method is not writable");
}`,
	.Private_In = `(store, target) {
  if (target === null || typeof target !== "object" && typeof target !== "function") {
    throw new TypeError("Cannot use 'in' to look for a private member in a non-object");
  }
  return store.has(target);
}`,
}

transform_state_init :: proc(
	job: ^ParseJob, cg: ^Codegen, options: TransformOptions) -> Maybe(StripDiagnostic,
) {
	assert(job != nil)
	assert(cg.transform == nil)
	decorators: TransformDecorators
	switch options.decorators {
	case "", "preserve": decorators = .Preserve
	case "legacy":       decorators = .Legacy
	case "standard":     decorators = .Standard
	case: return StripDiagnostic{what = "expected decorators mode preserve, legacy, or standard"}
	}
	if options.emit_decorator_metadata && decorators != .Legacy {
		return StripDiagnostic{what = "decorator metadata requires legacy decorators"}
	}
	if decorators == .Standard {
		return StripDiagnostic{what = "standard decorators are not lowered yet"}
	}
	switch options.class_fields {
	case "", "define", "assign":
	case: return StripDiagnostic{what = "expected class fields mode define or assign"}
	}
	target, known := transform_target_parse(options.target)
	if !known {
		return StripDiagnostic{what = "expected a target from es2015 to es2024, or esnext"}
	}
	refresh := RefreshOptions{
		enabled = options.refresh, emit_full_signatures = options.refresh_full_signatures,
		reg = options.refresh_reg if options.refresh_reg != "" else "$RefreshReg$",
		sig = options.refresh_sig if options.refresh_sig != "" else "$RefreshSig$",
	}
	bindings_valid := refresh_binding_valid(refresh.reg) && refresh_binding_valid(refresh.sig)
	if refresh.enabled && !bindings_valid {
		return StripDiagnostic{what = "invalid React Refresh runtime binding"}
	}
	if decorators == .Preserve && target == .ESNext && !refresh.enabled { return nil }
	state := new(TransformState, job.arena_alloc)
	state^ = {
		job = job, allocator = job.arena_alloc, target = target, refresh = refresh,
		decorators = decorators, emit_metadata = options.emit_decorator_metadata,
	}
	state.class_fields = .Assign if options.class_fields == "assign" else .Define
	state.classes = make(map[u32]^LoweredClass, 8, state.allocator)
	state.class_list = make([dynamic]^LoweredClass, 0, 8, state.allocator)
	state.class_names = make(map[u32]string, 8, state.allocator)
	state.super_done = make(map[^Expression]bool, 8, state.allocator)
	state.temp_scopes = make([dynamic][dynamic]string, 0, 8, state.allocator)
	append(&state.temp_scopes, make([dynamic]string, 0, 4, state.allocator))
	cg.transform = state
	return nil
}

transform_helper :: proc(cg: ^Codegen, helper: TransformHelper) -> string {
	state := cg.transform
	assert(state != nil)
	if state.helpers[helper] == "" {
		state.helpers[helper] = codegen_fresh_runtime_binding(cg, TRANSFORM_HELPER_KINDS[helper])
		for name in TRANSFORM_HELPER_GLOBALS[helper] {
			if codegen_resource_root_binding(cg, name) {
				what := "a top-level binding shadows a global the lowering helpers need"
				cg_strip_unsupported(cg, {}, what)
			}
		}
	}
	return state.helpers[helper]
}

// Function declarations hoist, so the helpers are callable from the first statement.
transform_finish_program :: proc(cg: ^Codegen) {
	state := cg.transform
	if state == nil { return }
	assert(len(state.temp_scopes) == 1)
	target_declare_temps(cg, state.temp_scopes[0][:])
	for name, helper in state.helpers {
		if name == "" { continue }
		cg_str(cg, "function ")
		cg_str(cg, name)
		remaining := TRANSFORM_HELPER_BODIES[helper]
		for line in strings.split_iterator(&remaining, "\n") {
			cg_str(cg, strings.trim_space(line) if cg.cfg.minified else line)
			cg_newline(cg)
		}
	}
}

transform_model :: proc(cg: ^Codegen) -> ^SemanticModel {
	state := cg.transform
	assert(state != nil)
	if state.model == nil {
		state.model = new(SemanticModel, state.allocator)
		enum_constants_init(&state.enums, state.allocator, len(cg.source))
		state.model^ = semantic_build(
			state.job.program, cg.source, state.job.lang, state.allocator,
			enum_constants = &state.enums,
		)
	}
	return state.model
}

// Synthesized nodes sit at the start of the construct they replace, with an
// empty span, so no comment or annotation lookup can match them.
transform_expression :: proc(state: ^TransformState, node: ^$T) -> ^Expression {
	expression := new(Expression, state.allocator)
	expression^ = node
	return expression
}

// The printer looks identifiers up by their source offset to rename them or
// to qualify them with a namespace. A synthesized identifier must never
// share an offset with one from the source, so it sits on the nearest byte
// at or before `at` that cannot begin an identifier.
transform_identifier :: proc(state: ^TransformState, name: string, at: u32) -> ^Expression {
	source := string(state.job.source.data)
	return transform_identifier_exact(state, name, transform_free_offset(source, at))
}

// For a synthesized use of a source binding, placed on the binding's own
// declaration so the printer resolves it as it would any other use.
transform_identifier_exact :: proc(state: ^TransformState, name: string, at: u32) -> ^Expression {
	assert(name != "")
	node := new(Identifier, state.allocator)
	node^ = {loc = {at, at}, name = name}
	return transform_expression(state, node)
}

transform_free_offset :: proc(source: string, at: u32) -> u32 {
	if u64(at) >= u64(len(source)) { return u32(len(source)) }
	for offset := int(at); offset >= 0; offset -= 1 {
		if !transform_starts_identifier(source[offset]) { return u32(offset) }
	}
	// The file begins with an identifier that runs up to `at`. The end of
	// the file is the one offset where nothing can start.
	return u32(len(source))
}

transform_starts_identifier :: proc(c: u8) -> bool {
	switch c {
	case 'a'..='z', 'A'..='Z', '_', '$', '\\': return true
	}
	return c >= 0x80
}

transform_assignment :: proc(
	state: ^TransformState, target, value: ^Expression, at: u32,
) -> ^Expression {
	assert(target != nil)
	assert(value != nil)
	node := new(AssignmentExpression, state.allocator)
	node^ = {loc = {at, at}, operator = .Assign, left = target, right = value}
	return transform_expression(state, node)
}

// Every expression the printer emits passes through here once, after type
// erasure, so a lowering can substitute an equivalent tree before it prints.
transform_lower_expression :: proc(cg: ^Codegen, expr: ^Expression) -> ^Expression {
	state := cg.transform
	assert(state != nil)
	assert(expr != nil)
	if class, is_class := expr^.(^ClassExpression); is_class {
		if state.decorators == .Legacy { transform_legacy_class_expression(cg, class) }
		if state.target >= .ES2022 && state.classes[class.body.loc.start] == nil {
			class_desugar_accessors(cg, class)
			class_register(cg, class)
		}
	}
	// After the first diagnostic nothing is written, so lowering can stop.
	if state.target == .ESNext || cg.strip_diag != nil { return expr }
	// A rule may produce syntax that an older target lowers again: `a ??= b`
	// becomes `a ?? (a = b)` and then a conditional. Three steps is the longest chain.
	value := expr
	for _ in 0..<4 {
		lowered := target_lower(cg, value)
		if lowered == nil { break }
		value = lowered
	}
	return value
}
