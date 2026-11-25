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
	Object_Spread, Rest_Pair,
	Async, Async_Super, Async_Await, Async_Generator, Async_Iterator, Async_Delegate,
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
	class_computed: map[u32]bool,           // Anonymous classes named by a computed key.
	super_done:    map[^Expression]bool,    // `super(...)` calls that already carry initializers.
	weak_checked:  bool,
	async_arguments: map[u32]bool,          // Free uses of `arguments`; true inside a function.
	async_targets: map[u32]string,          // `new.target` offsets to their capture binding.
	async_supers:  map[u32]string,          // `super` offsets to their reference maker.
	async_block_functions: map[u32]bool,    // Functions declared in a block of sloppy code.
	async_marks:   map[rawptr]bool,         // `await` and `yield` nodes of lowered async generators.
	async_loops_done: bool,                 // Every `for await` in a function has been rewritten.
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
	.Object_Spread        = {"Object", "Reflect"},
	.Rest_Pair            = {"Object", "Reflect", "Symbol", "String"},
	.Async                = {"Promise"},
	.Async_Super          = {"Reflect"},
	.Async_Await          = {},
	.Async_Generator      = {"Promise", "Symbol"},
	.Async_Iterator       = {"Promise", "Symbol", "Object", "TypeError"},
	.Async_Delegate       = {"Symbol", "TypeError"},
}

// Helpers a helper calls. Its text names them `$0`, `$1`, in this order, and
// asking for the helper asks for them too.
TRANSFORM_HELPER_USES := [TransformHelper][]TransformHelper{
	.Decorate = {}, .Decorate_Param = {}, .Decorate_Metadata = {},
	.Define_Field = {}, .Prop_Key = {}, .Set_Name = {}, .Take_Member = {},
	.Private_Init = {}, .Private_Brand = {}, .Private_Get = {}, .Private_Set = {},
	.Private_Method = {}, .Private_Accessor_Get = {}, .Private_Accessor_Set = {},
	.Private_Readonly = {}, .Private_In = {},
	.Object_Spread = {}, .Rest_Pair = {},
	.Async = {}, .Async_Super = {}, .Async_Await = {},
	.Async_Generator = {.Async_Await},
	.Async_Iterator  = {},
	.Async_Delegate  = {.Async_Await, .Async_Iterator},
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
	.Object_Spread        = "spread",
	.Rest_Pair            = "rest",
	.Async                = "async",
	.Async_Super          = "super_ref",
	.Async_Await          = "await",
	.Async_Generator      = "async_generator",
	.Async_Iterator       = "async_iterator",
	.Async_Delegate       = "async_delegate",
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
	.Object_Spread = `(target, source) {
  if (source === null || source === void 0) return target;
  var from = Object(source);
  var keys = Reflect.ownKeys(from);
  for (var i = 0; i < keys.length; i++) {
    var own = Object.getOwnPropertyDescriptor(from, keys[i]);
    if (!own || !own.enumerable) continue;
    var copy = { value: from[keys[i]], enumerable: true, configurable: true, writable: true };
    Object.defineProperty(target, keys[i], copy);
  }
  return target;
}`,
	.Rest_Pair = `(source, excluded) {
  var step = 0;
  var pair = {};
  pair[Symbol.iterator] = function () {
    return pair;
  };
  pair.next = function () {
    step += 1;
    if (step === 1) return { value: source, done: false };
    if (step > 2) return { value: void 0, done: true };
    var from = Object(source);
    var rest = {};
    var names = [];
    for (var n = 0; n < excluded.length; n++) names.push(String(excluded[n]));
    var keys = Reflect.ownKeys(from);
    for (var i = 0; i < keys.length; i++) {
      if (names.indexOf(keys[i]) >= 0) continue;
      var own = Object.getOwnPropertyDescriptor(from, keys[i]);
      if (!own || !own.enumerable) continue;
      var copy = { value: from[keys[i]], enumerable: true, configurable: true, writable: true };
      Object.defineProperty(rest, keys[i], copy);
    }
    return { value: rest, done: false };
  };
  return pair;
}`,
	// Drives a generator as the body of an async function. `await` is a
	// `yield`: the value is resolved as a promise and its outcome is sent
	// back in. The generator is created inside the promise, so an error in
	// a parameter rejects instead of being thrown at the caller.
	.Async = `(self, args, body) {
  return new Promise(function (resolve, reject) {
    var generator = body.apply(self, args);
    function step(method, value) {
      var result;
      var awaited;
      try {
        result = generator[method](value);
      } catch (error) {
        reject(error);
        return;
      }
      if (result.done) {
        resolve(result.value);
        return;
      }
      try {
        awaited = Promise.resolve(result.value);
      } catch (error) {
        step("throw", error);
        return;
      }
      awaited.then(fulfilled, rejected);
    }
    function fulfilled(value) {
      step("next", value);
    }
    function rejected(error) {
      step("throw", error);
    }
    step("next", void 0);
  });
}`,
	// `super[key]` as an object that can be read, assigned and updated, for
	// code that moved into a function where `super` cannot be written.
	.Async_Super = `(read, write) {
  return function (key) {
    var name = Reflect.ownKeys({ [key]: 0 })[0];
    return {
      get value() {
        return read(name);
      },
      set value(next) {
        write(name, next);
      },
    };
  };
}`,
	// What an async generator yields to its driver in order to wait for a
	// value. `delegated` marks the result of a call that `yield*` forwarded.
	.Async_Await = `(value, delegated) {
  this.value = value;
  this.delegated = delegated;
}`,
	// Drives a generator as the body of an async generator. Requests wait in
	// a queue and are served one at a time. A yielded $0 is awaited and its
	// outcome sent back in; any other yielded value answers the request.
	// `return(value)` awaits the value before the generator sees it, as the
	// suspended `yield` would.
	.Async_Generator = `(self, args, body) {
  var generator = body.apply(self, args);
  var queue = [];
  var started = false;
  var busy = false;
  var finished = false;
  var facade = {};
  function settle(value, done) {
    busy = false;
    queue.shift().resolve({ value: value, done: done });
  }
  function fail(error) {
    busy = false;
    queue.shift().reject(error);
  }
  function wait(value, fulfilled, rejected) {
    var awaited;
    try {
      awaited = Promise.resolve(value);
    } catch (error) {
      rejected(error);
      return;
    }
    awaited.then(fulfilled, rejected);
  }
  function step(method, value) {
    var result;
    try {
      result = generator[method](value);
    } catch (error) {
      finished = true;
      fail(error);
      return;
    }
    if (result.done) {
      finished = true;
      settle(result.value, true);
      return;
    }
    var out = result.value;
    if (!(out instanceof $0)) {
      settle(out, false);
      return;
    }
    var again = out.delegated && queue[0].method === "return" ? "return" : "next";
    wait(out.value, resume(again), resume("throw"));
  }
  function resume(method) {
    return function (value) {
      step(method, value);
      drain();
    };
  }
  function ended(head) {
    finished = true;
    if (head.method === "next") {
      settle(void 0, true);
    } else if (head.method === "throw") {
      fail(head.value);
    } else {
      busy = true;
      wait(head.value, function (value) {
        settle(value, true);
        drain();
      }, function (error) {
        fail(error);
        drain();
      });
    }
  }
  function drain() {
    while (queue.length > 0 && !busy) {
      var head = queue[0];
      if (finished || !started && head.method !== "next") {
        ended(head);
      } else {
        started = true;
        busy = true;
        if (head.method === "return") wait(head.value, resume("return"), resume("throw"));
        else step(head.method, head.value);
      }
    }
  }
  function enqueue(method) {
    return function (value) {
      return new Promise(function (resolve, reject) {
        queue.push({ method: method, value: value, resolve: resolve, reject: reject });
        drain();
      });
    };
  }
  facade.next = enqueue("next");
  facade.throw = enqueue("throw");
  facade.return = enqueue("return");
  facade[Symbol.asyncIterator] = function () {
    return facade;
  };
  return facade;
}`,
	// The async iterator of a value, or its sync iterator behind promises,
	// as a record: `next` is read once, `close` and `fail` answer with
	// nothing when the iterator has no such method and with a boxed result
	// when it has, and `check` insists on an object.
	.Async_Iterator = `(iterable) {
  var method = iterable[Symbol.asyncIterator];
  var sync = method === void 0 || method === null;
  var iterator = sync ? iterable[Symbol.iterator]() : method.call(iterable);
  if (Object(iterator) !== iterator) throw new TypeError("The iterator is not an object");
  var next = iterator.next;
  function check(result) {
    if (Object(result) !== result) throw new TypeError("The iterator result is not an object");
    return result;
  }
  function unwrap(result, closes) {
    var done = check(result).done;
    return Promise.resolve(result.value).then(function (value) {
      return { value: value, done: done };
    }, function (error) {
      if (closes && !done && iterator.return) iterator.return();
      throw error;
    });
  }
  function call(name, absent) {
    return function (value) {
      var given = arguments.length > 0 ? [value] : [];
      var member = name === "next" ? next : iterator[name];
      if (member === void 0 || member === null) {
        if (!sync) return void 0;
        return { value: absent(value) };
      }
      if (!sync) return { value: member.apply(iterator, given) };
      try {
        return { value: unwrap(member.apply(iterator, given), name !== "return") };
      } catch (error) {
        return { value: Promise.reject(error) };
      }
    };
  }
  var step = call("next");
  return {
    check: check,
    next: function (value) {
      return step(value).value;
    },
    close: call("return", function (value) {
      return Promise.resolve({ value: value, done: true });
    }),
    fail: call("throw", function () {
      if (iterator.return) iterator.return();
      return Promise.reject(new TypeError("The iterator does not provide a throw method"));
    }),
  };
}`,
	// The iterator `yield*` delegates to inside an async generator. Each
	// request is forwarded to the source and answered in two steps: first a
	// $0 for the driver to wait on, then the awaited result itself.
	.Async_Delegate = `(iterable) {
  var source = $1(iterable);
  var waiting = false;
  var closing = false;
  var facade = {};
  function pump(promise) {
    waiting = true;
    return { value: new $0(promise, true), done: false };
  }
  function result(value) {
    waiting = false;
    if (closing) throw new TypeError("The iterator does not provide a throw method");
    return source.check(value);
  }
  facade.next = function (value) {
    return waiting ? result(value) : pump(source.next(value));
  };
  facade.throw = function (error) {
    if (waiting) {
      waiting = false;
      throw error;
    }
    var thrown = source.fail(error);
    if (thrown) return pump(thrown.value);
    closing = true;
    var closed = source.close();
    return pump(closed ? closed.value : void 0);
  };
  facade.return = function (value) {
    if (waiting) return result(value);
    var closed = source.close(value);
    return closed ? pump(closed.value) : { value: value, done: true };
  };
  facade[Symbol.iterator] = function () {
    return facade;
  };
  return facade;
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
	state.class_computed = make(map[u32]bool, 8, state.allocator)
	state.super_done = make(map[^Expression]bool, 8, state.allocator)
	state.async_targets = make(map[u32]string, 8, state.allocator)
	state.async_supers = make(map[u32]string, 8, state.allocator)
	state.async_marks = make(map[rawptr]bool, 8, state.allocator)
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
		// No helper uses itself, directly or through another, so this ends.
		for used in TRANSFORM_HELPER_USES[helper] { transform_helper(cg, used) }
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
			text := strings.trim_space(line) if cg.cfg.minified else line
			for used, index in TRANSFORM_HELPER_USES[helper] {
				assert(index < 2)
				assert(state.helpers[used] != "")
				text, _ = strings.replace_all(
					text, "$0" if index == 0 else "$1", state.helpers[used], context.temp_allocator,
				)
			}
			cg_str(cg, text)
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
