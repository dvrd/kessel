package kessel

// ============================================================================
// function_parameter.odin — one view of a parameter and its default value
// ============================================================================
//
// The parser stores a parameter default in one of two places, depending on
// which path parsed the parameter list:
//
//   pattern = `a`, default_val = `1`
//       function f(a = 1) {}      function expressions, methods, accessors,
//       async (a = 1) => 0        constructors; and arrows that are parsed as
//       (a: T = 1) => 0           a parameter list from the start: async
//       <T,>(a = 1) => 0          arrows and, in TypeScript, arrows with type
//       (a = 1): T => 0           annotations, type parameters or a return type
//
//   pattern = AssignmentPattern{left = `a`, right = `1`}, default_val = nil
//       (a = 1) => 0              arrows first parsed as a parenthesised
//       ({a} = {}) => 0           expression and then reinterpreted
//
// Emitted ESTree is the same for both (an AssignmentPattern); only the typed
// AST differs, and a reader that tests one form silently misses the other.
// Readers that care about defaults go through `function_parameter_view`
// instead. `ast_walk` does, so a visitor sees target-then-default for every
// parameter.
//
// Why a view and not one stored form: the two forms are read at 27
// `.default_val` sites in 12 files and written at 11 `FunctionParameter{}`
// construction sites in the parser, and `FunctionParameter`'s layout is
// part of the raw transfer format. tests/coverage/src/function_parameter_test.odin
// pins which form each syntax produces, so a later unification shows up
// there first.

FunctionParameterView :: struct {
	// What the argument is bound to: an identifier, a destructuring pattern,
	// or a rest element. Never the parameter-level AssignmentPattern.
	target:        Pattern,
	// The default initializer, or nil when the parameter has none.
	default_value: ^Expression,
}

function_parameter_view :: proc(parameter: ^FunctionParameter) -> FunctionParameterView {
	assert(parameter != nil)
	if default_value, present := parameter.default_val.?; present {
		return FunctionParameterView{target = parameter.pattern, default_value = default_value}
	}
	if assignment, is_assignment := parameter.pattern.(^AssignmentPattern); is_assignment {
		if assignment != nil {
			return FunctionParameterView{target = assignment.left, default_value = assignment.right}
		}
	}
	return FunctionParameterView{target = parameter.pattern, default_value = nil}
}

// True when the parameter has a default initializer, in either form.
function_parameter_has_default :: proc(parameter: ^FunctionParameter) -> bool {
	return function_parameter_view(parameter).default_value != nil
}
