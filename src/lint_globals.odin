package kessel

import "core:encoding/json"
import "core:strconv"
import "core:strings"

LintGlobalAccess :: enum u8 { Off, Readonly, Writable }
LintGlobalNames :: map[string]LintGlobalAccess

LintEnvironmentSelection :: struct {
	// Mentioned environments can be disabled by a later config layer.
	mentioned, enabled: u64,
	explicit: bool,
}

LintGlobalConfig :: struct {
	names: LintGlobalNames,
	env: LintEnvironmentSelection,
}

LintGlobalSettings :: struct {
	names, environment: LintGlobalNames,
	oxlint: bool,
}

lint_globals_parse :: proc(object: json.Object) -> (config: LintGlobalConfig, ok: bool) {
	if value, found := object["globals"]; found {
		names, valid := value.(json.Object)
		if !valid { return {}, false }
		config.names = make(LintGlobalNames, len(names))
		for name, setting in names {
			#partial switch v in setting {
			case json.Boolean: config.names[name] = .Writable if v else .Readonly
			case json.String:
				switch string(v) {
				case "readonly", "readable": config.names[name] = .Readonly
				case "writable", "writeable": config.names[name] = .Writable
				case "off": config.names[name] = .Off
				case: return {}, false
				}
			case: return {}, false
			}
		}
	}
	if value, found := object["env"]; found {
		flags, valid := value.(json.Object)
		if !valid { return {}, false }
		config.env.explicit = true
		for name, setting in flags {
			enabled, boolean := setting.(json.Boolean)
			if !boolean { return {}, false }
			bit := lint_environment_bit(name)
			config.env.mentioned |= bit
			if enabled { config.env.enabled |= bit }
		}
	}
	return config, true
}

lint_global_names_merge :: proc(target: ^LintGlobalNames, layer: LintGlobalNames) {
	if len(layer) == 0 { return }
	if target^ == nil { target^ = make(LintGlobalNames, len(layer)) }
	for name, value in layer { target^[name] = value }
}

lint_environment_merge :: proc(target: ^LintEnvironmentSelection, layer: LintEnvironmentSelection) {
	target.enabled = (target.enabled &~ layer.mentioned) | layer.enabled
	target.mentioned |= layer.mentioned
	target.explicit ||= layer.explicit
}

lint_environment_data :: proc() -> (environments, groups: string) {
	MARKER :: "\n[environments]\n"
	data: string = LINT_ENVIRONMENT_DATA
	start := strings.index(data, MARKER)
	assert(start >= 0)
	data = data[start + len(MARKER):]
	names, ok := strings.split_iterator(&data, "\n")
	assert(ok)
	header, present := strings.split_iterator(&data, "\n")
	assert(present && header == "[globals]")
	return names, data
}

lint_environment_bit :: proc(name: string) -> u64 {
	names, _ := lint_environment_data()
	bit: u64 = 1
	for environment in strings.split_iterator(&names, " ") {
		if environment == name { return bit }
		bit <<= 1
	}
	return 0
}

// Each group has the same access flags for all its names. Shared environment
// combinations are expanded only once per project store, including per-file overrides.
lint_environment_globals :: proc(store: ^LintConfigStore, enabled: u64) -> LintGlobalNames {
	mask := enabled | 1 // The first environment contains the standard builtins.
	if cached, ok := store.environments[mask]; ok { return cached }
	if store.environments == nil { store.environments = make(map[u64]LintGlobalNames) }
	names := make(LintGlobalNames)
	_, data := lint_environment_data()
	for row in strings.split_lines_iterator(&data) {
		if len(row) == 0 { continue }
		fields := row
		present_hex, _ := strings.split_iterator(&fields, " ")
		writable_hex, _ := strings.split_iterator(&fields, " ")
		present, valid := strconv.parse_u64_of_base(present_hex, 16)
		assert(valid)
		matching := present & mask
		if matching == 0 { continue }
		writable, parsed := strconv.parse_u64_of_base(writable_hex, 16)
		assert(parsed)
		// Builtins precede host names. The first matching host in the catalog
		// resolves the few globals with conflicting host mutability.
		first := matching & (~matching + 1)
		access := LintGlobalAccess.Readonly
		if writable & first != 0 { access = .Writable }
		for name in strings.split_iterator(&fields, " ") { names[name] = access }
	}
	store.environments[mask] = names
	return names
}

lint_global_defined :: proc(settings: ^LintGlobalSettings, name: string) -> bool {
	if value, explicit := settings.names[name]; explicit {
		if value != .Off { return true }
		// Oxlint still recognizes an environment-provided name for no-undef
		// when its explicit global entry disables assignment checking.
		if !settings.oxlint { return false }
	}
	if settings.environment != nil { return settings.environment[name] != .Off }
	return lint_is_known_global(name)
}

lint_global_readonly :: proc(settings: ^LintGlobalSettings, name: string) -> bool {
	if value, explicit := settings.names[name]; explicit { return value == .Readonly }
	if settings.environment != nil { return settings.environment[name] == .Readonly }
	return lint_is_readonly_global(name)
}
