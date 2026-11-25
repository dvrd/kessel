package kessel

import "core:strings"

ResourceKind :: enum { None, Sync, Async }
ResourceScope :: struct { name: string, kind: ResourceKind }

resource_kind :: proc(declaration: ^VariableDeclaration) -> ResourceKind {
	if declaration.kind == .Using { return .Sync }
	if declaration.kind == .AwaitUsing { return .Async }
	return .None
}

resource_list_kind :: proc(cg: ^Codegen, statements: []^Statement) -> (kind: ResourceKind) {
	if !cg.cfg.lower_using { return .None }
	for statement in statements {
		if statement == nil { continue }
		if declaration, ok := statement^.(^VariableDeclaration); ok {
			kind = max(kind, resource_kind(declaration))
			if kind == .Async { break }
		}
	}
	return kind
}

codegen_resource_init :: proc(cg: ^Codegen, kind: ResourceKind) {
	if cg.resource_helper == "" { cg.resource_helper = codegen_fresh_runtime_binding(cg, "resources") }
	name := codegen_fresh_runtime_binding(cg, "scope")
	cg.resource_scope = {name, kind}
	cg_str(cg, "const ")
	cg_str(cg, name)
	cg_infix_operator(cg, "=")
	cg_str(cg, cg.resource_helper)
	cg_str(cg, "();")
	cg_newline(cg)
}

codegen_resource_open :: proc(cg: ^Codegen, kind: ResourceKind) -> (outer: ResourceScope) {
	outer = cg.resource_scope
	if kind == .None { return }
	codegen_resource_init(cg, kind)
	cg_str(cg, "try {")
	cg_newline(cg)
	cg.depth += 1
	return
}

codegen_resource_close :: proc(cg: ^Codegen, kind: ResourceKind, outer: ResourceScope) {
	if kind == .None { return }
	scope := cg.resource_scope
	cg.resource_scope = outer
	cg.depth -= 1
	// Catch and finally have independent lexical environments.
	name := codegen_fresh_runtime_binding(cg, "completion")
	cg_str(cg, "} catch (")
	cg_str(cg, name)
	cg_str(cg, ") {")
	cg_newline(cg)
	cg.depth += 1
	cg_str(cg, scope.name)
	cg_str(cg, ".fail(")
	cg_str(cg, name)
	cg_str(cg, ");")
	cg_newline(cg)
	cg.depth -= 1
	cg_str(cg, "} finally {")
	cg_newline(cg)
	cg.depth += 1
	codegen_resource_dispose(cg, scope, name)
	cg.depth -= 1
	cg_byte(cg, '}')
	cg_newline(cg)
}

codegen_resource_dispose :: proc(cg: ^Codegen, scope: ResourceScope, name: string) {
	if scope.kind == .Async {
		cg_str(cg, "const ")
		cg_str(cg, name)
		cg_infix_operator(cg, "=")
	}
	cg_str(cg, scope.name)
	cg_str(cg, ".dispose();")
	if scope.kind == .Async {
		cg_newline(cg)
		cg_str(cg, "if (")
		cg_str(cg, name)
		cg_str(cg, ") await ")
		cg_str(cg, name)
		cg_byte(cg, ';')
	}
	cg_newline(cg)
}

codegen_resource_register :: proc(cg: ^Codegen, kind: ResourceKind) {
	assert(kind != .None)
	assert(cg.resource_scope.name != "")
	cg_str(cg, cg.resource_scope.name)
	cg_str(cg, ".addAsync(" if kind == .Async else ".add(")
}

// An async declaration with a nullish value still establishes an await boundary.
// A sync fallback for await using ignores its return value, including thenables.
RESOURCE_HELPER_BODY :: `() {
  const stack = [];
  const empty = {};
  let completion = empty;
  function add(value, async) {
    if (value == null) {
      if (async) stack.push({ async });
      return value;
    }
    if (typeof value !== "object" && typeof value !== "function") throw new globalThis.TypeError("Object is not disposable");
    const symbols = globalThis.Symbol;
    let method;
    let fallback = false;
    if (async) method = value[symbols.asyncDispose || symbols.for("Symbol.asyncDispose")];
    if (method == null) {
      method = value[symbols.dispose || symbols.for("Symbol.dispose")];
      fallback = async;
    }
    if (typeof method !== "function") throw new globalThis.TypeError("Object is not disposable");
    stack.push({ value, method, async, fallback });
    return value;
  }
  function fail(error) {
    if (completion === empty) completion = error;
    else if (typeof globalThis.SuppressedError === "function") completion = new globalThis.SuppressedError(error, completion);
    else {
      const combined = new globalThis.Error();
      globalThis.Object.defineProperties(combined, {
        error: { value: error, writable: true, configurable: true },
        suppressed: { value: completion, writable: true, configurable: true },
        name: { value: "SuppressedError", writable: true, configurable: true }
      });
      completion = combined;
    }
  }
  function dispose() {
    let needsAwait = false;
    let hasAwaited = false;
    function next() {
      while (stack.length) {
        const item = stack[stack.length - 1];
        if (!item.async && needsAwait && !hasAwaited) {
          needsAwait = false;
          return globalThis.Promise.resolve().then(next);
        }
        stack.pop();
        if (!item.method) {
          needsAwait = true;
          continue;
        }
        try {
          const result = globalThis.Reflect.apply(item.method, item.value, []);
          if (item.async) {
            hasAwaited = true;
            return globalThis.Promise.resolve(item.fallback ? void 0 : result).then(next, rejected);
          }
        } catch (error) {
          if (item.fallback) {
            hasAwaited = true;
            return globalThis.Promise.reject(error).then(next, rejected);
          }
          fail(error);
        }
      }
      if (needsAwait && !hasAwaited) {
        return completion === empty ? globalThis.Promise.resolve() : globalThis.Promise.reject(completion);
      }
      if (completion !== empty) throw completion;
    }
    function rejected(error) { fail(error); return next(); }
    return next();
  }
  return { add(value) { return add(value, false); }, addAsync(value) { return add(value, true); }, fail, dispose };
}`

codegen_resource_helper :: proc(cg: ^Codegen) {
	if cg.resource_helper == "" { return }
	cg_str(cg, "function ")
	cg_str(cg, cg.resource_helper)
	codegen_resource_helper_body(cg, RESOURCE_HELPER_BODY)
}

codegen_resource_helper_body :: proc(cg: ^Codegen, body: string) {
	remaining := body
	for line in strings.split_iterator(&remaining, "\n") {
		cg_str(cg, strings.trim_space(line) if cg.cfg.minified else line)
		cg_newline(cg)
		if line == "() {" && codegen_resource_root_binding(cg, "globalThis") {
			codegen_resource_intrinsics(cg)
		}
	}
}

// Put the cleanup around the full labeled statement. Each label must still
// designate the loop itself when a continue targets it.
codegen_resource_for :: proc(cg: ^Codegen, stmt: Statement) -> bool {
	current := stmt
	for {
		label, ok := current.(^LabeledStatement)
		if !ok { break }
		current = label.body^
	}
	loop, ok := current.(^ForStatement)
	if !ok { return false }
	declaration, present := loop.init_decl.?
	if !present { return false }
	kind := resource_kind(declaration)
	if kind == .None { return false }
	cg_byte(cg, '{')
	cg_newline(cg)
	cg.depth += 1
	outer := codegen_resource_open(cg, kind)
	current = stmt
	for {
		label, labeled := current.(^LabeledStatement)
		if !labeled { break }
		cg_str(cg, label.label.name)
		cg_byte(cg, ':')
		cg_space(cg)
		current = label.body^
	}
	gen_for_statement(cg, loop)
	cg_newline(cg)
	codegen_resource_close(cg, kind, outer)
	cg.depth -= 1
	cg_byte(cg, '}')
	return true
}

gen_resource_for_of :: proc(cg: ^Codegen, loop: ^ForOfStatement, declaration: ^VariableDeclaration) {
	assert(len(declaration.declarations) == 1)
	kind := resource_kind(declaration)
	assert(kind != .None)
	// Keep the original lexical binding in the loop head. It is already
	// in its temporal dead zone while the iterable is being evaluated.
	pattern := declaration.declarations[0].id
	cg_str(cg, "for")
	if loop.await { cg_str(cg, " await") }
	cg_space(cg)
	cg_str(cg, "(const ")
	gen_pattern(cg, pattern)
	cg_str(cg, " of ")
	gen_expression(cg, loop.right, PREC_ASSIGN)
	cg_str(cg, ") {")
	cg_newline(cg)
	cg.depth += 1
	outer := codegen_resource_open(cg, kind)
	codegen_resource_register(cg, kind)
	gen_pattern(cg, pattern)
	cg_str(cg, ");")
	cg_newline(cg)
	gen_statement(cg, loop.body^)
	cg_newline(cg)
	codegen_resource_close(cg, kind, outer)
	cg.depth -= 1
	cg_byte(cg, '}')
}

// A module binding named globalThis can be uninitialized when the first resource
// is acquired. Use unshadowed host globals or the individual realm intrinsics.
codegen_resource_root_binding :: proc(cg: ^Codegen, name: string) -> bool {
	for symbol in cg.runtime_scope.symbols {
		if symbol.scope == SCOPE_ROOT && symbol.name == name { return true }
	}
	return false
}

codegen_resource_intrinsics :: proc(cg: ^Codegen) {
	cg_str(cg, "const globalThis = ")
	hosts := [?]string{"global", "self", "window"}
	for host in hosts {
		if codegen_resource_root_binding(cg, host) { continue }
		cg_str(cg, "typeof ")
		cg_str(cg, host)
		cg_str(cg, " === 'object' && ")
		cg_str(cg, host)
		cg_str(cg, " ? ")
		cg_str(cg, host)
		cg_str(cg, " : ")
	}
	cg_str(cg, "{Object,Symbol,Reflect,Promise,Error,TypeError,get SuppressedError(){return typeof SuppressedError === 'function' ? SuppressedError : void 0;}};")
	cg_newline(cg)
}
