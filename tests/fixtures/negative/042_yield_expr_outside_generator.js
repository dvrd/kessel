// ECMA-262 §15.5 — `YieldExpression` is grammatically valid only
// inside a GeneratorBody. At the top level of a script (sloppy mode,
// no enclosing `function*`) `yield expr` is a SyntaxError. The bare
// identifier `yield;` stays legal in sloppy code, so the rejection
// specifically targets the yield-expression form — the lookahead has
// to clearly want an AssignmentExpression argument (no newline, no
// operator / call / member continuation).
yield 1;
