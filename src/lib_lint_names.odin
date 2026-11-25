package kessel

import "core:mem"
import "core:strings"

// The name a rule goes by in configuration files and disable directives:
// `no-debugger` for core ESLint rules and `plugin/rule` for the others, for
// example `unicorn/no-thenable` or `typescript/no-namespace`. The plugin
// spelling is oxlint's, which lint_rule_split_name also accepts on input.
// Shared by the native library and the WebAssembly module so that both
// bindings report the same names.
lint_rule_qualified_name :: proc(rule: LintRule, allocator: mem.Allocator) -> string {
	assert(rule != .None)
	name := lint_rule_info(rule).name
	assert(name != "")
	plugin := lint_rule_plugin(rule)
	assert(plugin != "")
	if plugin == "eslint" { return name }
	return strings.concatenate({plugin, "/", name}, allocator)
}
