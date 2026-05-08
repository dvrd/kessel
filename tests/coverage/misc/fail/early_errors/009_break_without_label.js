// ECMA-262 §13.9.1 — BreakStatement must either be inside an
// IterationStatement / SwitchStatement, or target an enclosing
// LabelledStatement. Neither holds here → SyntaxError.
break;
