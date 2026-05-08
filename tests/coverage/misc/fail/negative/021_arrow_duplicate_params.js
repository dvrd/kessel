// ECMA-262 §15.3.1 — ArrowFunction's ArrowParameters are always
// UniqueFormalParameters, regardless of strict or sloppy mode. Plain
// or destructured, any duplicate BoundName is a SyntaxError.
const f = (a, a) => a;
const g = ({x}, x) => x;
