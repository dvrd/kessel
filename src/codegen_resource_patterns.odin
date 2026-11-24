package kessel

// A later default or computed key can observe an earlier live export in the
// same pattern. Bind names one at a time at module scope while each operation
// that can invoke user code is protected by the module's cleanup.
gen_module_resource_pattern :: proc(cg: ^Codegen, pat: Pattern, keyword, value: string, exported: bool) {
	assert(value != "")
	if cg.module_resources.pattern == "" {
		cg.module_resources.pattern = codegen_fresh_runtime_binding(cg, "pattern")
		cg.module_resources.pattern_factory = codegen_fresh_runtime_binding(cg, "patterns")
		// An earlier failure can enter the module unwinder before this initializer.
		cg_str(cg, "var ")
		cg_str(cg, cg.module_resources.pattern)
		cg_infix_operator(cg, "=")
		cg_str(cg, cg.module_resources.pattern_factory)
		cg_str(cg, "();")
		cg_newline(cg)
	}
	switch p in pat {
	case ^Identifier:
		gen_module_binding(cg, keyword, p.name, value, exported, p.loc)
		cg_newline(cg)
	case ^AssignmentPattern:
		gen_module_resource_try(cg)
		cg_str(cg, "if (")
		cg_str(cg, value)
		cg_str(cg, " === void 0) ")
		cg_str(cg, value)
		cg_infix_operator(cg, "=")
		name := ""
		if id, ok := p.left.(^Identifier); ok { name = id.name }
		gen_resource_named_value(cg, p.right, name)
		gen_module_value_end(cg)
		gen_module_resource_pattern(cg, p.left, keyword, value, exported)
	case ^RestElement: gen_module_resource_pattern(cg, p.argument, keyword, value, exported)
	case ^ArrayPattern: gen_module_array_pattern(cg, p, keyword, value, exported)
	case ^ObjectPattern: gen_module_object_pattern(cg, p, keyword, value, exported)
	case ^MemberExpression: cg_strip_unsupported(cg, p.loc, "member expression in a binding pattern")
	}
}

gen_module_pattern_temp :: proc(cg: ^Codegen, kind: string) -> string {
	temp := codegen_fresh_runtime_binding(cg, kind)
	cg_str(cg, "let ")
	cg_str(cg, temp)
	cg_byte(cg, ';')
	cg_newline(cg)
	return temp
}

gen_module_pattern_operation :: proc(cg: ^Codegen, target, operation, source: string) {
	if target == "" { gen_module_resource_try(cg) } else { gen_module_value_start(cg, target) }
	cg_str(cg, cg.module_resources.pattern)
	cg_byte(cg, '.')
	cg_str(cg, operation)
	cg_byte(cg, '(')
	cg_str(cg, source)
}

gen_module_array_pattern :: proc(cg: ^Codegen, pattern: ^ArrayPattern, keyword, value: string, exported: bool) {
	iter := gen_module_pattern_temp(cg, "iterator")
	gen_module_pattern_operation(cg, iter, "open", value)
	cg_byte(cg, ')')
	gen_module_value_end(cg)
	for element in pattern.elements {
		child, present := element.?
		if !present {
			gen_module_pattern_operation(cg, "", "step", iter)
			cg_str(cg, ",false)")
			gen_module_value_end(cg)
			continue
		}
		target := gen_module_pattern_temp(cg, "element")
		if _, rest := child.(^RestElement); rest {
			gen_module_pattern_operation(cg, target, "tail", iter)
			cg_byte(cg, ')')
		} else {
			gen_module_pattern_operation(cg, target, "step", iter)
			cg_str(cg, ",true)")
		}
		gen_module_value_end(cg)
		gen_module_resource_pattern(cg, child, keyword, target, exported)
	}
	gen_module_pattern_operation(cg, "", "close", iter)
	cg_byte(cg, ')')
	gen_module_value_end(cg)
}

gen_module_object_pattern :: proc(cg: ^Codegen, pattern: ^ObjectPattern, keyword, value: string, exported: bool) {
	gen_module_pattern_operation(cg, "", "requireObject", value)
	cg_byte(cg, ')')
	gen_module_value_end(cg)
	keys := make([dynamic]string, cg.runtime_scope.allocator)
	for property in pattern.properties {
		temp := gen_module_pattern_temp(cg, "property")
		if key, present := property.key.?; present {
			key_name := gen_module_pattern_temp(cg, "key")
			gen_module_pattern_operation(cg, key_name, "key", "")
			switch k in key {
			case IdentifierName: gen_string_quoted(cg, k.name)
			case ^StringLiteral: gen_string_literal(cg, k)
			case ^NumericLiteral: gen_numeric_literal(cg, k)
			case ^Expression: gen_expression(cg, k, PREC_ASSIGN)
			}
			cg_byte(cg, ')')
			gen_module_value_end(cg)
			append(&keys, key_name)
			gen_module_value_start(cg, temp)
			cg_str(cg, value)
			cg_byte(cg, '[')
			cg_str(cg, key_name)
			cg_byte(cg, ']')
		} else {
			gen_module_pattern_operation(cg, temp, "rest", value)
			cg_str(cg, ",[")
			for key_name, i in keys {
				if i != 0 { cg_byte(cg, ',') }
				cg_str(cg, key_name)
			}
			cg_str(cg, "])")
		}
		gen_module_value_end(cg)
		gen_module_resource_pattern(cg, property.value, keyword, temp, exported)
	}
}

gen_module_pattern_helper :: proc(cg: ^Codegen) {
	if cg.module_resources.pattern_factory == "" { return }
	cg_str(cg, "function ")
	cg_str(cg, cg.module_resources.pattern_factory)
	codegen_resource_helper_body(cg, MODULE_PATTERN_HELPER_BODY)
}

// IteratorClose preserves a pre-existing throw. IteratorStepValue marks the
// iterator done if next(), done, or value throws, including inside nested patterns.
MODULE_PATTERN_HELPER_BODY :: `() {
  const active = [];
  function object(value) {
    if (globalThis.Object(value) !== value) throw new globalThis.TypeError("Expected an object");
    return value;
  }
  function open(value) {
    const iterator = object(value[globalThis.Symbol.iterator]());
    const record = { iterator, next: iterator.next, done: false };
    active.push(record);
    return record;
  }
  function step(record, read) {
    if (record.done) return;
    record.done = true;
    const result = object(globalThis.Reflect.apply(record.next, record.iterator, []));
    if (result.done) return;
    const value = read ? result.value : void 0;
    record.done = false;
    return value;
  }
  function tail(record) {
    const values = [];
    while (!record.done) {
      const value = step(record, true);
      if (!record.done) values.push(value);
    }
    return values;
  }
  function close(record) {
    active.pop();
    if (record.done) return;
    const method = record.iterator.return;
    if (method != null) object(globalThis.Reflect.apply(method, record.iterator, []));
  }
  function abort() {
    while (active.length) {
      try { close(active[active.length - 1]); } catch {}
    }
  }
  function key(value) { return globalThis.Reflect.ownKeys({ [value]: 0 })[0]; }
  function requireObject(value) {
    if (value == null) throw new globalThis.TypeError("Cannot destructure null or undefined");
  }
  function rest(source, excluded) {
    const value = globalThis.Object(source);
    const result = {};
    for (const key of globalThis.Reflect.ownKeys(value)) {
      if (excluded.includes(key)) continue;
      if (globalThis.Object.prototype.propertyIsEnumerable.call(value, key)) {
        globalThis.Object.defineProperty(result, key, { value: value[key], enumerable: true, writable: true, configurable: true });
      }
    }
    return result;
  }
  return { open, step, tail, close, abort, key, requireObject, rest };
}`
