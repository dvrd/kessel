package kessel

// ParseResourceBudget centralizes limits that protect parser-facing
// entrypoints from unbounded malformed input. A zero-valued field means
// "use the default" so older call sites can add the struct without
// changing behaviour.
ParseResourceBudget :: struct {
	// Maximum consecutive parser loop iterations without consuming input.
	error_recovery_iterations: int,

	// Maximum AST recursion depth tolerated by consumers that walk the
	// finished tree recursively. The Odin parser does not yet enforce
	// this at every grammar entry; binary decode and future walkers share
	// the value so the limit has one published source.
	ast_depth: int,

	// Maximum node-array length in compact binary AST consumers.
	binary_node_array_count: int,
}

PARSE_RESOURCE_ERROR_RECOVERY_ITERATIONS :: 10000
PARSE_RESOURCE_AST_DEPTH                 :: 512
PARSE_RESOURCE_BINARY_NODE_ARRAY_COUNT   :: 100000

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
