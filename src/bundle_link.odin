package kessel

// Linking: decide which modules must be wrapped, resolve every imported name
// to the binding it finally denotes, and reject what cannot be linked.

import "core:slice"

bundle_link :: proc(g: ^BundleGraph) {
	bundle_link_wrap(g)
	for module in g.modules {
		bundle_link_check_module(g, module)
		if module.kind != .ESM { continue }
		for local in module.imports { bundle_link_import(g, module, local) }
		bundle_link_check_writes(g, module)
		bundle_export_names(g, module)
	}
}

// A CommonJS module is always wrapped. An ES module is wrapped when it is
// loaded lazily, and laziness spreads along static imports: a dependency of a
// lazy module must not run before that module is first asked for.
@(private="file")
bundle_link_wrap :: proc(g: ^BundleGraph) {
	pending := make([dynamic]i32, g.alloc)
	for module in g.modules {
		if module.kind == .CJS { module.wrap = .CJS } else if module.lazy { module.wrap = .ESM }
		if module.wrap != .None { append(&pending, module.index) }
	}
	// Each module enters the list at most once, when its wrap first changes.
	for len(pending) > 0 {
		module := g.modules[pop(&pending)]
		for record in module.records {
			if record.kind != .Import || record.target < 0 { continue }
			target := g.modules[record.target]
			if target.wrap != .None { continue }
			assert(target.kind == .ESM)
			target.wrap = .ESM
			append(&pending, target.index)
		}
	}
}

@(private="file")
bundle_link_check_module :: proc(g: ^BundleGraph, module: ^BundleModule) {
	if module.has_top_level_await {
		// A module that awaits lets its siblings run in the meantime. A
		// single-file bundle is sequential, so only the entry, which runs
		// last, keeps its order.
		if module.index != 0 || module.wrap != .None {
			bundle_error(g, module, nil, "top-level await is only supported in the entry module")
		} else if g.options.format != .ESM {
			bundle_error(g, module, nil, "top-level await requires the esm output format")
		}
	}
	if module.has_import_meta && g.options.format != .ESM {
		bundle_error(g, module, nil, "import.meta is not available in the %v output format", g.options.format)
	}
	for star in module.stars {
		record := module.records[star]
		if record.target == BUNDLE_EXTERNAL {
			if module.index != 0 || module.wrap != .None || g.options.format != .ESM {
				bundle_error(g, module, record.loc.start,
					"'export *' from an external module is only supported in an esm entry module")
			}
		} else if record.target >= 0 && g.modules[record.target].kind == .CJS {
			bundle_error(g, module, record.loc.start, "'export *' from a CommonJS module is not supported")
		}
	}
	if module.index == 0 && module.wrap == .ESM && len(module.export_order) + len(module.stars) != 0 {
		bundle_error(g, module, nil, "an entry module with exports cannot also be required or imported dynamically")
	}
}

@(private="file")
bundle_link_import :: proc(g: ^BundleGraph, module: ^BundleModule, local: string) {
	target := bundle_import_target(g, module, local)
	if target.kind != .Missing && target.kind != .Ambiguous { return }
	binding := module.imports[local]
	record := module.records[binding.record]
	// The transformer keeps imports it cannot prove to be types. An unused
	// one that resolves to nothing was a type; a used one is a real error.
	if module.typescript && target.kind == .Missing && !bundle_root_name_used(module, local) { return }
	reason := "is ambiguous in" if target.kind == .Ambiguous else "is not exported by"
	bundle_error(g, module, record.loc.start, "'%s' %s '%s'", binding.name, reason, record.specifier)
}

@(private="file")
bundle_root_name_used :: proc(module: ^BundleModule, name: string) -> bool {
	id, found := module.model.binding_index[{SCOPE_ROOT, name}]
	return found && module.model.symbols[id].ref_count != 0
}

// An import binding is read-only. After hoisting it would be an ordinary
// variable, so an assignment that must throw would silently succeed.
@(private="file")
bundle_link_check_writes :: proc(g: ^BundleGraph, module: ^BundleModule) {
	model := &module.model
	for ref in model.refs {
		if ref.kind == .Read || ref.resolved == SYMBOL_UNRESOLVED { continue }
		symbol := model.symbols[ref.resolved]
		if symbol.scope != SCOPE_ROOT || symbol.kind != .Import { continue }
		bundle_error(g, module, ref.start, "cannot assign to import '%s'", ref.name)
	}
}

bundle_import_target :: proc(g: ^BundleGraph, module: ^BundleModule, local: string) -> BundleTarget {
	if cached, found := module.import_targets[local]; found { return cached }
	binding, is_import := module.imports[local]
	assert(is_import)
	record := module.records[binding.record]
	target: BundleTarget
	if binding.name == "*" {
		target = bundle_namespace_target(g, record.target, module.index, binding.record)
	} else {
		target = bundle_resolve_export(g, record.target, binding.name, module.index, binding.record, 0)
	}
	module.import_targets[local] = target
	return target
}

@(private="file")
bundle_namespace_target :: proc(g: ^BundleGraph, target, via_module, via_record: i32) -> BundleTarget {
	if target == BUNDLE_EXTERNAL { return {.External, target, "*", via_module, via_record} }
	assert(target >= 0)
	if g.modules[target].kind == .CJS { return {.Property, target, "", via_module, via_record} }
	return {.Namespace, target, "", via_module, via_record}
}

// Follow `name` exported by `target` to its final home. Recursion mirrors the
// re-export chain; BUNDLE_RESOLVE_DEPTH_MAX bounds it and the per-module
// `resolving` set stops `export *` cycles.
bundle_resolve_export :: proc(g: ^BundleGraph, target: i32, name: string, via_module, via_record: i32, depth: int) -> BundleTarget {
	if target == BUNDLE_EXTERNAL { return {.External, target, name, via_module, via_record} }
	assert(target >= 0)
	module := g.modules[target]
	if module.kind == .CJS { return {.Property, target, name, via_module, via_record} }
	if module.wrap == .ESM {
		// Consumers read a lazy module through its namespace getters. Only
		// existence is checked here; the getter resolves the rest in place.
		inner := bundle_resolve_hoisted(g, module, name, depth)
		if inner.kind == .Missing || inner.kind == .Ambiguous { return inner }
		return {.Property, target, name, via_module, via_record}
	}
	return bundle_resolve_hoisted(g, module, name, depth)
}

// The home of `name` as seen from inside ES module `module`, ignoring whether
// that module is wrapped. Wrapped modules use it to build their getters.
bundle_resolve_hoisted :: proc(g: ^BundleGraph, module: ^BundleModule, name: string, depth: int) -> BundleTarget {
	assert(module.kind == .ESM)
	if cached, found := module.resolved[name]; found { return cached }
	if depth > BUNDLE_RESOLVE_DEPTH_MAX || module.resolving[name] { return {kind = .Missing} }
	module.resolving[name] = true
	defer delete_key(&module.resolving, name)
	result := BundleTarget{kind = .Missing}
	if exported, explicit := module.exports[name]; explicit {
		if exported.record >= 0 {
			record := module.records[exported.record]
			if exported.name == "*" {
				result = bundle_namespace_target(g, record.target, module.index, exported.record)
			} else {
				result = bundle_resolve_export(g, record.target, exported.name, module.index, exported.record, depth + 1)
			}
		} else if binding, is_import := module.imports[exported.name]; is_import {
			record := module.records[binding.record]
			if binding.name == "*" {
				result = bundle_namespace_target(g, record.target, module.index, binding.record)
			} else {
				result = bundle_resolve_export(g, record.target, binding.name, module.index, binding.record, depth + 1)
			}
		} else if _, bound := module.model.binding_index[{SCOPE_ROOT, exported.name}]; bound {
			result = {kind = .Symbol, module = module.index, name = exported.name}
		} else if exported.name == BUNDLE_DEFAULT_LOCAL {
			result = {kind = .Symbol, module = module.index, name = exported.name}
		}
	} else if name != "default" {
		result = bundle_resolve_star(g, module, name, depth)
	}
	// A miss can be an artefact of the cycle guard further up the stack, so
	// only definite answers are remembered.
	if result.kind != .Missing { module.resolved[name] = result }
	return result
}

// `export *` offers a name when exactly one binding answers to it. Two
// different bindings make the name ambiguous, which ES modules treat as absent
// from the namespace and as an error when imported by name.
@(private="file")
bundle_resolve_star :: proc(g: ^BundleGraph, module: ^BundleModule, name: string, depth: int) -> BundleTarget {
	found := BundleTarget{kind = .Missing}
	external_star := i32(-1)
	for star in module.stars {
		record := module.records[star]
		if record.target == BUNDLE_EXTERNAL {
			if external_star < 0 { external_star = star }
			continue
		}
		if record.target < 0 || g.modules[record.target].kind == .CJS { continue }
		candidate := bundle_resolve_export(g, record.target, name, module.index, star, depth + 1)
		if candidate.kind == .Missing { continue }
		if candidate.kind == .Ambiguous { return candidate }
		if found.kind == .Missing {
			found = candidate
		} else if found.kind != candidate.kind || found.module != candidate.module || found.name != candidate.name {
			return {kind = .Ambiguous}
		}
	}
	if found.kind == .Missing && external_star >= 0 {
		// Nothing bundled exports the name, so it can only come from the
		// external module.
		return {.External, BUNDLE_EXTERNAL, name, module.index, external_star}
	}
	return found
}

// Every name an ES module exports, sorted like a module namespace object.
// Names that only exist as types in a TypeScript source are dropped.
bundle_export_names :: proc(g: ^BundleGraph, module: ^BundleModule) -> []string {
	assert(module.kind == .ESM)
	if module.export_names_done { return module.export_names }
	module.export_names_done = true
	candidates := make(map[string]bool, g.alloc)
	for name in module.export_order { candidates[name] = true }
	// Breadth-first over `export *` edges; each module is expanded once.
	visited := make(map[i32]bool, g.alloc)
	queue := make([dynamic]i32, g.alloc)
	append(&queue, module.index)
	visited[module.index] = true
	for head := 0; head < len(queue); head += 1 {
		current := g.modules[queue[head]]
		if current != module {
			for name in current.export_order {
				if name != "default" { candidates[name] = true }
			}
		}
		for star in current.stars {
			next := current.records[star].target
			if next < 0 || visited[next] || g.modules[next].kind != .ESM { continue }
			visited[next] = true
			append(&queue, next)
		}
	}
	names := make([dynamic]string, g.alloc)
	for name in candidates {
		target := bundle_resolve_hoisted(g, module, name, 0)
		_, explicit := module.exports[name]
		if target.kind == .Missing && explicit && !module.typescript {
			bundle_error(g, module, module.exports[name].loc.start, "export '%s' does not resolve to a binding", name)
		}
		if target.kind == .Missing || target.kind == .Ambiguous { continue }
		append(&names, name)
	}
	slice.sort(names[:])
	module.export_names = names[:]
	return module.export_names
}
