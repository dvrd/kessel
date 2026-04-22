// ECMA-262 \u00a715.8 \u2014 No LineTerminator between `async` and
// ArrowParameters. `async\n(x) => x` must parse as `async; (x) => x`
// (ExpressionStatement `async` followed by arrow on next line).
//
// POSITIVE variant: same-line works.
const f = async (x) => x + 1;
const g = async () => 42;
