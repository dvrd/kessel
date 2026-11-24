package kessel

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The selected configuration filename controls inheritance and suppression semantics.
LintConfigDialect :: enum { Kessel, Oxlint }

LintHookConfig :: struct {
	react: bool,
	correctness, pedantic: string,
}

// The `categories` and `plugins` keys of an .oxlintrc.json. A level is "off",
// "warn" or "error", or "" when the file does not mention the category.
LintCategoryConfig :: struct {
	levels: [LintCategory]string,
	// Oxlint enables these three plugins unless `plugins` lists others.
	plugins_listed: bool,
	typescript, unicorn, oxc: bool,
}

LintConfigLayer :: struct {
	rules: [dynamic]LintOverride,
	hooks: LintHookConfig,
	categories: LintCategoryConfig,
	globals: LintGlobalConfig,
	ignores: [dynamic]string,
	overrides: [dynamic]LintConfigOverride,
	parents: [dynamic]string,
	report_unused: Maybe(LintOverride),
}

LintProjectConfig :: struct {
	directory: string,
	hooks: LintHookConfig,
	categories: LintCategoryConfig,
	globals: LintGlobalConfig,
	dialect: LintConfigDialect,
	// Parents precede children. Globs run after all base settings.
	layers: []^LintConfigLayer,
}

// Projects may share one config through differently named symlinks.
LintProjectConfigKey :: struct { path: string, dialect: LintConfigDialect }

LintConfigStore :: struct {
	watch: ^FileWatch,
	root: ^LintProjectConfig,
	directory: string,
	nested: bool,
	configs: map[LintProjectConfigKey]^LintProjectConfig,
	layers: map[string]^LintConfigLayer,
	directories: map[string]string,
	environments: map[u64]LintGlobalNames,
	file_globals: LintGlobalNames,
}

lint_config_store_init :: proc(store: ^LintConfigStore, explicit: string, nested: bool, watch: ^FileWatch = nil) -> bool {
	cwd, err := os.getwd(context.allocator)
	if err != nil { return false }
	return lint_config_store_open(store, cwd, explicit, nested, watch)
}

lint_config_store_open :: proc(store: ^LintConfigStore, directory, explicit: string, nested: bool, watch: ^FileWatch = nil) -> bool {
	assert(store != nil)
	assert(filepath.is_abs(directory))
	store^ = { watch=watch, directory=directory, nested=nested && explicit == "", configs=make(map[LintProjectConfigKey]^LintProjectConfig),
		layers=make(map[string]^LintConfigLayer), directories=make(map[string]string) }
	path := explicit
	if path == "" { path = lint_config_discover(store, directory, "") }
	if path == "" { return true }
	config, ok := lint_config_load(store, path)
	if ok { store.root = config; store.directory = config.directory }
	return ok
}

// An editor buffer can live below directories that have never been saved.
// Resolve its existing ancestor so symlinked workspace paths still match config globs.
lint_config_input_path :: proc(input: string) -> string {
	path, err := filepath.abs(input, context.temp_allocator)
	if err == nil { return path }
	if !filepath.is_abs(input) { return input }
	ancestor := filepath.dir(input)
	for len(ancestor) > 0 {
		base, base_err := filepath.abs(ancestor, context.temp_allocator)
		if base_err == nil {
			suffix, rel_err := filepath.rel(ancestor, input, context.temp_allocator)
			if rel_err != .None { break }
			joined, join_err := filepath.join({base, suffix}, context.temp_allocator)
			if join_err == nil { return joined }
			break
		}
		parent := filepath.dir(ancestor)
		if len(parent) >= len(ancestor) { break }
		ancestor = parent
	}
	return input
}

// Cache both hits and misses along each ascent. Sibling inputs usually share
// directories, so each directory needs two filesystem probes at most.
lint_config_discover :: proc(store: ^LintConfigStore, start, boundary: string) -> string {
	visited: [dynamic]string
	defer delete(visited)
	result := ""
	dir := start
	for {
		if found, known := store.directories[dir]; known { result = found; break }
		append(&visited, dir)
		for name in ([2]string{"kessel.lint.json", ".oxlintrc.json"}) {
			candidate, err := filepath.join({dir, name}, context.temp_allocator)
			if err != nil { continue }
			file_watch_add(store.watch, candidate)
			if os.exists(candidate) {
				result = strings.clone(candidate)
				break
			}
		}
		if result != "" || dir == boundary { break }
		parent := filepath.dir(dir)
		if len(parent) >= len(dir) { break }
		dir = parent
	}
	for dir in visited { store.directories[dir] = result }
	return result
}

lint_config_for_file :: proc(store: ^LintConfigStore, input: string) -> (^LintProjectConfig, bool) {
	if !store.nested { return store.root, true }
	path := lint_config_input_path(input)
	relative, rel_err := filepath.rel(store.directory, path, context.temp_allocator)
	if rel_err != .None || relative == ".." || (len(relative) > 2 && relative[:2] == ".." && filepath.is_separator(relative[2])) {
		return store.root, true
	}
	// Directory keys remain in the store across calls, beyond this file's temp allocations.
	found := lint_config_discover(store, strings.clone(filepath.dir(path)), store.directory)
	if found == "" { return store.root, true }
	config, ok := lint_config_load(store, found)
	if !ok { return nil, false }
	if config != store.root && config.layers[len(config.layers)-1].report_unused != nil {
		fmt.eprintf("Error: reportUnusedDisableDirectives must be set in the root lint config: %s\n", found)
		return nil, false
	}
	return config, true
}

LintConfigFrame :: struct { path: string, layer: ^LintConfigLayer, remaining: int }

lint_config_load :: proc(store: ^LintConfigStore, requested: string) -> (^LintProjectConfig, bool) {
	file_watch_add(store.watch, requested)
	root, root_err := filepath.abs(requested, context.allocator)
	if root_err != nil { fmt.eprintf("Error: could not read lint config: %s\n", requested); return nil, false }
	key := LintProjectConfigKey{path=root}
	if filepath.base(requested) == ".oxlintrc.json" { key.dialect = .Oxlint }
	if config, ok := store.configs[key]; ok { return config, true }
	order: [dynamic]^LintConfigLayer
	seen := make(map[string]bool, context.temp_allocator)
	frames: [64]LintConfigFrame
	depth := 0
	path := root
	for {
		layer, ok := lint_config_read_layer(store, path)
		if !ok { return nil, false }
		append(&order, layer)
		seen[path] = true
		frames[depth] = {path, layer, len(layer.parents)}
		depth += 1
		for depth > 0 {
			frame := &frames[depth-1]
			if frame.remaining == 0 { depth -= 1; continue }
			frame.remaining -= 1
			parent := frame.layer.parents[frame.remaining]
			for ancestor in frames[:depth] {
				if ancestor.path == parent { fmt.eprintf("Error: cyclic lint config extends: %s\n", parent); return nil, false }
			}
			if seen[parent] { continue }
			if depth == len(frames) { fmt.eprintf("Error: lint config extends exceeds %d levels: %s\n", depth, parent); return nil, false }
			path = parent
			break
		}
		if depth == 0 { break }
	}
	for low := 0; low < len(order)/2; low += 1 {
		high := len(order)-1-low
		order[low], order[high] = order[high], order[low]
	}
	config := new(LintProjectConfig)
	config^ = {directory=filepath.dir(root), layers=order[:], dialect=key.dialect}
	if key.dialect == .Oxlint {
		for layer in config.layers {
			if layer.hooks.react { config.hooks.react = true }
			if layer.hooks.correctness != "" { config.hooks.correctness = layer.hooks.correctness }
			if layer.hooks.pedantic != "" { config.hooks.pedantic = layer.hooks.pedantic }
			lint_category_config_merge(&config.categories, layer.categories)
		}
		// Oxlint takes the selected file's top-level globals and env, even
		// when it inherits rules and per-file overrides from another file.
		config.globals = order[len(order)-1].globals
	} else {
		for layer in config.layers {
			lint_environment_merge(&config.globals.env, layer.globals.env)
			lint_global_names_merge(&config.globals.names, layer.globals.names)
		}
	}
	store.configs[key] = config
	return config, true
}

lint_config_read_layer :: proc(store: ^LintConfigStore, path: string) -> (^LintConfigLayer, bool) {
	if layer, cached := store.layers[path]; cached { return layer, true }
	data, read_error := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_error != nil { fmt.eprintf("Error: could not read lint config: %s\n", path); return nil, false }
	value, err := json.parse(data, parse_integers=true, allocator=context.allocator)
	obj, is_object := value.(json.Object)
	if err != .None || !is_object { fmt.eprintf("Error: invalid lint config: %s\n", path); return nil, false }
	layer := new(LintConfigLayer)
	if !lint_config_parse_fields(obj, layer) { fmt.eprintf("Error: invalid lint settings: %s\n", path); return nil, false }
	if parents, has_parents := obj["extends"]; has_parents {
		dir := filepath.dir(path)
		#partial switch v in parents {
		case json.String:
			if !lint_config_add_parent(store, layer, dir, string(v)) { return nil, false }
		case json.Array:
			for item in v {
				name, ok := item.(json.String)
				if !ok { fmt.eprintf("Error: expected lint config path in %s\n", path); return nil, false }
				if !lint_config_add_parent(store, layer, dir, string(name)) { return nil, false }
			}
		case:
			fmt.eprintf("Error: expected extends path or array in %s\n", path)
			return nil, false
		}
	}
	store.layers[path] = layer
	return layer, true
}

lint_config_add_parent :: proc(store: ^LintConfigStore, layer: ^LintConfigLayer, dir, name: string) -> bool {
	path := name
	if !filepath.is_abs(name) {
		joined, err := filepath.join({dir, name}, context.temp_allocator)
		if err != nil { return false }
		path = joined
	}
	file_watch_add(store.watch, path)
	absolute, err := filepath.abs(path)
	if err != nil || !os.is_file(absolute) { fmt.eprintf("Error: could not read extended lint config: %s\n", path); return false }
	append(&layer.parents, absolute)
	return true
}

lint_config_parse_fields :: proc(obj: json.Object, layer: ^LintConfigLayer) -> bool {
	globals, valid_globals := lint_globals_parse(obj)
	if !valid_globals { return false }
	layer.globals = globals
	layer.hooks.react = lint_config_react_plugin(obj)
	if categories, ok := obj["categories"].(json.Object); ok {
		layer.hooks.correctness, _ = lint_config_level(categories["correctness"])
		layer.hooks.pedantic, _ = lint_config_level(categories["pedantic"])
		for category in LintCategory {
			if category == .None { continue }
			layer.categories.levels[category], _ = lint_config_level(categories[lint_category_key(category)])
		}
	}
	lint_category_plugins(obj, &layer.categories)
	if options, found := obj["options"].(json.Object); found {
		if setting, present := options["reportUnusedDisableDirectives"]; present {
			level, is_string := setting.(json.String)
			if !is_string { return false }
			ov, valid := lint_override_from_level(.L9001_UnusedDirective, string(level))
			if !valid { return false }
			layer.report_unused = ov
		}
	}
	if value, present := obj["ignorePatterns"]; present {
		patterns, ok := value.(json.Array)
		if !ok { return false }
		for item in patterns {
			pattern, valid := item.(json.String)
			if !valid { return false }
			append(&layer.ignores, string(pattern))
		}
	}
	if value, present := obj["overrides"]; present {
		blocks, ok := value.(json.Array)
		if !ok { return false }
		for item in blocks {
			block, valid := lint_parse_override_block(item)
			if !valid { return false }
			append(&layer.overrides, block)
		}
	}
	if rules_v, has_rules := obj["rules"]; has_rules {
		rules, is_rules := rules_v.(json.Object)
		if !is_rules { return false }
		if !lint_parse_rules_object(rules, &layer.rules) { return false }
	}
	return true
}

lint_config_react_plugin :: proc(obj: json.Object) -> bool {
	plugins, ok := obj["plugins"].(json.Array)
	if !ok { return false }
	for plugin in plugins {
		name, named := plugin.(json.String)
		if !named { continue }
		switch string(name) {
		case "react", "react-hooks", "eslint-plugin-react", "eslint-plugin-react-hooks": return true
		}
	}
	return false
}

lint_category_key :: proc(category: LintCategory) -> string {
	switch category {
	case .Correctness: return "correctness"
	case .Suspicious:  return "suspicious"
	case .Pedantic:    return "pedantic"
	case .Perf:        return "perf"
	case .Style:       return "style"
	case .Restriction: return "restriction"
	case .Nursery:     return "nursery"
	case .None:
	}
	return ""
}

lint_category_plugins :: proc(obj: json.Object, config: ^LintCategoryConfig) {
	plugins, listed := obj["plugins"].(json.Array)
	if !listed { return }
	config.plugins_listed = true
	for plugin in plugins {
		name, named := plugin.(json.String)
		if !named { continue }
		switch string(name) {
		case "typescript", "@typescript-eslint": config.typescript = true
		case "unicorn":                          config.unicorn = true
		case "oxc":                              config.oxc = true
		}
	}
}

// A later file replaces the plugin list and each category it mentions.
lint_category_config_merge :: proc(target: ^LintCategoryConfig, layer: LintCategoryConfig) {
	for level, category in layer.levels {
		if level != "" { target.levels[category] = level }
	}
	if !layer.plugins_listed { return }
	target.plugins_listed = true
	target.typescript, target.unicorn, target.oxc = layer.typescript, layer.unicorn, layer.oxc
}

lint_category_plugin_enabled :: proc(config: LintCategoryConfig, plugin: string) -> bool {
	switch plugin {
	case "eslint":     return true
	case "typescript": return config.typescript || !config.plugins_listed
	case "unicorn":    return config.unicorn || !config.plugins_listed
	case "oxc":        return config.oxc || !config.plugins_listed
	}
	return false
}

// Oxlint runs the `correctness` category by default and each other category
// only when the config raises it. These defaults precede explicit rule
// settings. Rules without a recorded category keep Kessel's own default.
lint_config_category_defaults :: proc(rules: ^[dynamic]LintOverride, config: LintCategoryConfig) {
	for rule in LintRule {
		category := lint_rule_category(rule)
		if category == .None { continue }
		level := config.levels[category]
		enabled := level != "off" if level != "" else category == .Correctness
		if !lint_category_plugin_enabled(config, lint_rule_plugin(rule)) { enabled = false }
		if !enabled || level == "" {
			// An unmentioned category keeps each rule's own default severity.
			append(rules, LintOverride{rule = rule, enabled = enabled})
			continue
		}
		override, valid := lint_override_from_level(rule, level)
		assert(valid)
		append(rules, override)
	}
}

// Oxlint classifies exhaustive-deps as correctness and rules-of-hooks as
// pedantic. Category defaults precede rule-specific settings.
lint_config_hook_defaults :: proc(rules: ^[dynamic]LintOverride, hooks: LintHookConfig) {
	dependencies, ok := lint_override_from_level(.L4108_ExhaustiveDeps, hooks.correctness if hooks.correctness != "" else "warn")
	assert(ok)
	append(rules, dependencies)
	placement, valid := lint_override_from_level(.L4107_RulesOfHooks, hooks.pedantic if hooks.pedantic != "" else "off")
	assert(valid)
	append(rules, placement)
}

// Evaluate path globs against the selected project's directory, independent
// of which directory the caller used to invoke the linter.
lint_config_relative_path :: proc(config: ^LintProjectConfig, input: string) -> string {
	absolute := lint_config_input_path(input)
	relative, rel_err := filepath.rel(config.directory, absolute, context.temp_allocator)
	if rel_err != .None { return input }
	path, separator_err := filepath.replace_separators(relative, '/', context.temp_allocator)
	return path if separator_err == nil else relative
}

// Both the CLI and unsaved editor buffers select rules and ignores in the same order.
lint_config_select :: proc(store: ^LintConfigStore, file: string, overrides: []LintOverride, rules: ^[dynamic]LintOverride) -> (settings: LintSettings, ignored, ok: bool) {
	if lint_config_ignores_file(store.root, file) { return {}, true, true }
	config, valid := lint_config_for_file(store, file)
	if !valid { return {}, false, false }
	if config != store.root && lint_config_ignores_file(config, file) { return {}, true, true }
	settings.globals = lint_config_effective(store, config, file, overrides, rules)
	settings.overrides = rules[:]
	if config != nil { settings.dialect = config.dialect }
	return settings, false, true
}

lint_config_ignores_file :: proc(config: ^LintProjectConfig, input: string) -> bool {
	if config == nil { return false }
	path := lint_config_relative_path(config, input)
	for layer in config.layers {
		if lint_path_ignored(layer.ignores[:], path) { return true }
	}
	return false
}

lint_config_effective :: proc(store: ^LintConfigStore, config: ^LintProjectConfig, input: string, cli_rules: []LintOverride, rules: ^[dynamic]LintOverride) -> (globals: LintGlobalSettings) {
	clear(rules)
	if config != nil {
		globals.oxlint = config.dialect == .Oxlint
		globals.names = config.globals.names
		env := config.globals.env
		copied_globals := false
		path := lint_config_relative_path(config, input)
		react := config.hooks.react
		if globals.oxlint { lint_config_category_defaults(rules, config.categories) }
		if react { lint_config_hook_defaults(rules, config.hooks) }
		for layer in config.layers { append(rules, ..layer.rules[:]) }
		for layer in config.layers {
			for block in layer.overrides {
				if !lint_path_ignored(block.globs, path) { continue }
				if globals.oxlint && block.react && !react {
					lint_config_hook_defaults(rules, config.hooks)
					react = true
				}
				append(rules, ..block.rules)
				lint_environment_merge(&env, block.globals.env)
				if len(block.globals.names) == 0 { continue }
				if !copied_globals {
					clear(&store.file_globals)
					lint_global_names_merge(&store.file_globals, globals.names)
					copied_globals = true
				}
				lint_global_names_merge(&store.file_globals, block.globals.names)
			}
		}
		if copied_globals { globals.names = store.file_globals }
		if globals.oxlint || env.explicit { globals.environment = lint_environment_globals(store, env.enabled) }
	}
	if store.root != nil {
		for layer in store.root.layers {
			if setting, ok := layer.report_unused.?; ok { append(rules, setting) }
		}
	}
	append(rules, ..cli_rules)
	return
}
