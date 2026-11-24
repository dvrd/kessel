package kessel

// ParseResourceBudget centralizes limits that protect parser-facing
// entrypoints from unbounded malformed input. A zero-valued field means
// "use the default" so older call sites can add the struct without
// changing behaviour.
ParseResourceBudget :: struct {
	// Maximum consecutive parser loop iterations without consuming input.
	error_recovery_iterations: int,

	// Maximum nesting depth. The parser enforces it at every recursive
	// grammar entry (see "Nesting depth limit" in parser.odin) and
	// reports K2081 beyond it, so consumers that walk the finished tree
	// recursively inherit a bound. Binary, logical, member and call
	// chains are exempt: they are built and walked iteratively.
	// ParseConfig.max_depth, when set, takes precedence over this field.
	ast_depth: int,

	// Maximum node-array length in compact binary AST consumers.
	binary_node_array_count: int,
}

PARSE_RESOURCE_ERROR_RECOVERY_ITERATIONS :: 10000
PARSE_RESOURCE_AST_DEPTH                 :: 512
PARSE_RESOURCE_BINARY_NODE_ARRAY_COUNT   :: 100000

// Upper bound accepted for a caller-supplied nesting limit. The limit is
// stack depth, so a caller that raises it must also supply the stack;
// the ceiling only keeps the countdown and its diagnostics well inside
// u32 and rejects obviously accidental values.
PARSE_DEPTH_MAX_CEILING :: 1 << 20

#assert(PARSE_RESOURCE_AST_DEPTH > 0)
#assert(PARSE_RESOURCE_AST_DEPTH <= PARSE_DEPTH_MAX_CEILING)

parse_resource_budget_default :: #force_inline proc() -> ParseResourceBudget {
	return ParseResourceBudget{
		error_recovery_iterations = PARSE_RESOURCE_ERROR_RECOVERY_ITERATIONS,
		ast_depth                 = PARSE_RESOURCE_AST_DEPTH,
		binary_node_array_count   = PARSE_RESOURCE_BINARY_NODE_ARRAY_COUNT,
	}
}

parse_resource_budget_normalize :: proc(budget: ParseResourceBudget) -> ParseResourceBudget {
	result := budget
	defaults := parse_resource_budget_default()
	if result.error_recovery_iterations <= 0 {
		result.error_recovery_iterations = defaults.error_recovery_iterations
	}
	if result.ast_depth <= 0 {
		result.ast_depth = defaults.ast_depth
	}
	if result.binary_node_array_count <= 0 {
		result.binary_node_array_count = defaults.binary_node_array_count
	}
	return result
}
