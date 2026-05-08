// ECMA-262 §15.8.1 — "It is a Syntax Error if FormalParameters
// Contains AwaitExpression is true." Async function parameters run
// outside the async function environment, so the default initializer
// `x = await 1` has no valid await target. The same rule (§15.6.1)
// extends to AsyncGeneratorDeclaration / AsyncGeneratorMethod and to
// async class / object-literal methods; all routes share the
// `in_async_params` guard in parse_unary_expr.
async function f(x = await 1) {}
