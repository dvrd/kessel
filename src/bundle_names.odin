package kessel

// Name allocation for the bundle scope.
//
// Hoisting puts the top-level bindings of many modules into one scope, so
// each needs a name that is unique there. Three hazards decide whether a
// binding may keep its source name:
//   • another bundle-scope binding already has it;
//   • some module reads a global of that name, which the binding would hide;
//   • an importer mentions the binding inside a scope that declares the same
//     name locally, which would capture the rewritten reference.
// Invented names (`x$1`, `require_x`, helpers) additionally avoid every name
// declared in any nested scope, so they can be mentioned anywhere.

import "core:fmt"
import "core:strings"

BundleNames :: struct {
	taken:  map[string]bool,
	free:   map[string]bool,
	nested: map[string]bool,
}

BundleHelper :: enum u8 {
	DefProp, CopyProps, Namespace, Export, CommonJS, ESM, ToESM, ToCommonJS, Require,
}

BundleHelpers :: struct {
	used:  bit_set[BundleHelper; u16],
	names: [BundleHelper]string,
	esm_cache, cjs_cache, create_require: string,
}

// A place where an importer mentions a hoisted binding of another module.
@(private="file")
BundleSite :: struct {
	module: i32,
	scope:  ScopeId,
}

@(private="file")
BundleSiteKey :: struct {
	module: i32,
	name:   string,
}

bundle_names_assign :: proc(g: ^BundleGraph) {
	names := &g.names
	names.taken = make(map[string]bool, g.alloc)
	names.free = make(map[string]bool, g.alloc)
	names.nested = make(map[string]bool, g.alloc)
	for reserved in ([]string{"arguments", "eval", "undefined", "require", "module", "exports"}) {
		names.free[reserved] = true
	}
	for module in g.modules {
		if module.job == nil { continue }
		for ref in module.model.refs {
			if ref.resolved == SYMBOL_UNRESOLVED { names.free[ref.name] = true }
		}
		for symbol in module.model.symbols[1:] {
			if symbol.scope != SCOPE_ROOT || module.wrap != .None { names.nested[symbol.name] = true }
		}
	}
	helper_names := [BundleHelper]string{
		.DefProp = "__defProp", .CopyProps = "__copyProps", .Namespace = "__namespace",
		.Export = "__export", .CommonJS = "__commonJS", .ESM = "__esm", .ToESM = "__toESM",
		.ToCommonJS = "__toCommonJS", .Require = "__require",
	}
	for name, helper in helper_names { g.helpers.names[helper] = bundle_unique_name(g, name) }
	g.helpers.esm_cache = bundle_unique_name(g, "__esmCache")
	g.helpers.cjs_cache = bundle_unique_name(g, "__cjsCache")
	g.helpers.create_require = bundle_unique_name(g, "__createRequire")

	sites := bundle_names_sites(g)
	// The entry is module zero, so its bindings get first claim on their names.
	for module in g.modules {
		if !module.included { continue }
		stem := bundle_path_stem(g, module.path)
		switch module.wrap {
		case .CJS:
			module.wrapper_name = bundle_unique_name(g, fmt.aprintf("require_%s", stem, allocator = g.alloc))
		case .ESM:
			module.wrapper_name = bundle_unique_name(g, fmt.aprintf("init_%s", stem, allocator = g.alloc))
		case .None:
			bundle_names_roots(g, module, sites)
		}
		if module.kind != .ESM { continue }
		module.namespace_name = bundle_unique_name(g, fmt.aprintf("%s_exports", stem, allocator = g.alloc))
		module.default_name = bundle_unique_name(g, fmt.aprintf("%s_default", stem, allocator = g.alloc))
	}
}

@(private="file")
bundle_names_sites :: proc(g: ^BundleGraph) -> map[BundleSiteKey][dynamic]BundleSite {
	sites := make(map[BundleSiteKey][dynamic]BundleSite, g.alloc)
	for module in g.modules {
		if !module.included || module.wrap != .None { continue }
		model := &module.model
		for ref in model.refs {
			if ref.resolved == SYMBOL_UNRESOLVED || ref.name not_in module.imports { continue }
			if model.symbols[ref.resolved].scope != SCOPE_ROOT { continue }
			target := bundle_import_target(g, module, ref.name)
			if target.kind != .Symbol { continue }
			key := BundleSiteKey{target.module, target.name}
			if key not_in sites { sites[key] = make([dynamic]BundleSite, g.alloc) }
			append(&sites[key], BundleSite{module.index, ref.scope})
		}
	}
	return sites
}

@(private="file")
bundle_names_roots :: proc(g: ^BundleGraph, module: ^BundleModule, sites: map[BundleSiteKey][dynamic]BundleSite) {
	model := &module.model
	for id in model.scopes[SCOPE_ROOT].symbols {
		symbol := model.symbols[id]
		if symbol.name in module.names || symbol.name in module.imports { continue }
		keep := !g.names.taken[symbol.name] && !g.names.free[symbol.name]
		if keep {
			for site in sites[{module.index, symbol.name}] {
				importer := &g.modules[site.module].model
				shadow := semantic_lookup(importer, site.scope, symbol.name)
				if shadow != SYMBOL_UNRESOLVED && importer.symbols[shadow].scope != SCOPE_ROOT {
					keep = false
					break
				}
			}
		}
		if keep {
			g.names.taken[symbol.name] = true
			module.names[symbol.name] = symbol.name
		} else {
			module.names[symbol.name] = bundle_unique_name(g, symbol.name, 1)
		}
	}
}

// Return `base`, or `base$N` for the smallest N from `first` that is safe to
// mention in every scope of the bundle. The search is bounded by the number
// of names in existence: one of that many plus one candidates must be free.
bundle_unique_name :: proc(g: ^BundleGraph, base: string, first := 0) -> string {
	names := &g.names
	limit := len(names.taken) + len(names.free) + len(names.nested) + 2
	for suffix in first..=first + limit {
		candidate := base
		if suffix != 0 { candidate = fmt.aprintf("%s$%d", base, suffix, allocator = g.alloc) }
		if names.taken[candidate] || names.free[candidate] || names.nested[candidate] { continue }
		names.taken[candidate] = true
		return candidate
	}
	panic("no free bundle name within the proven bound")
}

// The interop object through which ES importers read CommonJS module
// `module`. Importers that follow Node's rules and importers that honour
// `__esModule` see different default exports, so each mode has its own object.
bundle_interop_name :: proc(g: ^BundleGraph, module: ^BundleModule, node_mode: bool) -> string {
	slot := 1 if node_mode else 0
	if module.interop_names[slot] == "" {
		stem := bundle_path_stem(g, module.path)
		module.interop_names[slot] = bundle_unique_name(g, fmt.aprintf("import_%s", stem, allocator = g.alloc))
	}
	return module.interop_names[slot]
}

bundle_external_interop_name :: proc(g: ^BundleGraph, external: ^BundleExternalImport, node_mode: bool) -> string {
	slot := 1 if node_mode else 0
	if external.interop_names[slot] == "" {
		stem := bundle_path_stem(g, external.specifier)
		external.interop_names[slot] = bundle_unique_name(g, fmt.aprintf("import_%s", stem, allocator = g.alloc))
	}
	return external.interop_names[slot]
}

// The bundle-scope binding for `name` imported from an external module.
bundle_external_binding :: proc(g: ^BundleGraph, external: ^BundleExternalImport, name: string) -> string {
	if binding, found := external.names[name]; found { return binding }
	base := name
	switch {
	case name == "*":       base = fmt.aprintf("%s_ns", bundle_path_stem(g, external.specifier), allocator = g.alloc)
	case name == "default": base = fmt.aprintf("%s_default", bundle_path_stem(g, external.specifier), allocator = g.alloc)
	case !bundle_is_identifier(name): base = "external_export"
	}
	binding := bundle_unique_name(g, base)
	external.names[name] = binding
	append(&external.order, name)
	return binding
}

bundle_is_identifier :: proc(name: string) -> bool {
	if name == "" { return false }
	for i in 0..<len(name) {
		c := name[i]
		letter := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$' || c >= 0x80
		if !letter && !(i > 0 && c >= '0' && c <= '9') { return false }
	}
	return true
}

// `.name` for identifier names, `["name"]` otherwise.
bundle_write_accessor :: proc(builder: ^strings.Builder, name: string) {
	if bundle_is_identifier(name) {
		strings.write_byte(builder, '.')
		strings.write_string(builder, name)
	} else {
		strings.write_byte(builder, '[')
		write_json_string(builder, name)
		strings.write_byte(builder, ']')
	}
}
