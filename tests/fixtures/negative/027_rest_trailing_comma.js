// ECMA-262 §15.1 / §15.3 — a trailing comma after a RestElement is
// a SyntaxError. The trailing-comma-in-FormalParameters allowance
// only applies to non-rest BindingElements.
const f = (...a,) => a;
function g(...args,) {}
