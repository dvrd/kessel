// ECMA-262 §15.9.1 — "It is a Syntax Error if
// CoverCallExpressionAndAsyncArrowHead Contains AwaitExpression is
// true." An async arrow's FormalParameters are the CoverCallExpression
// parse of the `( ... )` before the `=>`; they're evaluated in the
// caller's context, so an AwaitExpression in a parameter default can't
// target the arrow's own async body. Acorn and Babel both reject.
async (x = await 1) => x;
