// ECMA-262 §15.5.1 — "It is a Syntax Error if FormalParameters
// Contains YieldExpression is true." A generator's FormalParameters
// are evaluated in the outer (non-generator) context, so the default
// initializer `x = yield 1` has no valid yield target; the grammar
// explicitly forbids YieldExpression here.
//
// Same rule (§15.6.1) extends to async generators and to generator
// methods (class and object-literal), all of which route through the
// same `in_generator_params` guard in parse_yield_expr.
function* g(x = yield 1) {}
