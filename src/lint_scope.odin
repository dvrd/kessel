package kessel

import "core:fmt"

// Top-level names, parameters, catch bindings and imports retain the existing
// unused-variable policy. Erased TypeScript declarations have no runtime reads.
lint_scope_pass :: proc(l: ^Linter, model: ^SemanticModel, lang: Lang, undef, unused, shadow: bool) {
	if undef && lang != .TS && lang != .TSX {
		for ref in model.refs {
			if ref.resolved != SYMBOL_UNRESOLVED || ref.typeof_operand { continue }
			if ref.name == "arguments" && model.scopes[ref.scope].implicit_arguments { continue }
			if lint_global_defined(&l.globals, ref.name) { continue }
			lint_report(l, ref.start, ref.end, .L2006_NoUndef, fmt.tprintf("'%s' is not defined", ref.name))
		}
	}
	if !unused && !shadow { return }
	for &symbol, offset in model.symbols[1:] {
		if symbol.scope == SCOPE_ROOT || .TypeOnly in symbol.flags { continue }
		if symbol.kind == .EnumMember || symbol.kind == .Interface || symbol.kind == .TypeAlias { continue }
		// All declarations of a merged binding share its canonical reference counts.
		if model.binding_index[{symbol.scope, symbol.name}] != SymbolId(offset + 1) { continue }
		scope := &model.scopes[symbol.scope]
		if unused && lint_unused_local(&symbol, scope) {
			lint_report(l, symbol.decl_start, symbol.decl_end, .L2007_NoUnusedVars,
				fmt.tprintf("'%s' is declared but never used", symbol.name))
		}
		if !shadow { continue }
		outer := semantic_lookup(model, scope.parent, symbol.name)
		if outer != SYMBOL_UNRESOLVED && outer != SymbolId(offset + 1) {
			if scope.kind == .FunctionBody && .Param in symbol.kinds && model.symbols[outer].kind == .Param { continue }
			lint_report(l, symbol.decl_start, symbol.decl_end, .L2008_NoShadow,
				fmt.tprintf("'%s' shadows a variable in an outer scope", symbol.name))
		}
	}
}

lint_unused_local :: proc(symbol: ^Symbol, scope: ^Scope) -> bool {
	if symbol.read_count != 0 || .Exported in symbol.flags { return false }
	if len(symbol.name) > 0 && symbol.name[0] == '_' { return false }
	if scope.kind == .FunctionName || (scope.kind == .Class && symbol.kind == .Class) { return false }
	return .Param not_in symbol.kinds && .CatchParam not_in symbol.kinds && .Import not_in symbol.kinds
}

// lint_is_known_global reports whether `name` is a standard global / host builtin, so
// no-undef does not flag it. Conservative superset of the ECMAScript intrinsics
// plus common Node and DOM globals.
lint_is_known_global :: proc(name: string) -> bool {
	switch name {
	case "undefined", "NaN", "Infinity", "globalThis", "arguments", "eval":
		return true
	case "Object", "Function", "Array", "String", "Number", "Boolean", "Symbol",
	     "BigInt", "Math", "JSON", "Date", "RegExp", "Map", "Set", "WeakMap",
	     "WeakSet", "WeakRef", "Proxy", "Reflect", "Promise", "ArrayBuffer",
	     "SharedArrayBuffer", "DataView", "Atomics", "Intl":
		return true
	case "Error", "TypeError", "RangeError", "SyntaxError", "ReferenceError",
	     "EvalError", "URIError", "AggregateError":
		return true
	case "Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array",
	     "Uint16Array", "Int32Array", "Uint32Array", "Float32Array",
	     "Float64Array", "BigInt64Array", "BigUint64Array":
		return true
	case "parseInt", "parseFloat", "isNaN", "isFinite", "encodeURIComponent",
	     "decodeURIComponent", "encodeURI", "decodeURI", "structuredClone",
	     "queueMicrotask":
		return true
	case "console", "setTimeout", "setInterval", "clearTimeout", "clearInterval",
	     "setImmediate", "fetch", "window", "document", "navigator",
	     "location", "history", "localStorage", "sessionStorage", "alert",
	     "URL", "URLSearchParams", "Headers", "Request", "Response", "Blob",
	     "FormData", "AbortController", "Event", "CustomEvent", "performance":
		return true
	case "require", "module", "exports", "process", "global", "Buffer",
	     "__dirname", "__filename":
		return true
	}
	return false
}
