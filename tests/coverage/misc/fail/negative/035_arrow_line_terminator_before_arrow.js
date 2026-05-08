// ECMA-262 §15.3 Restricted Production:
//   ArrowFunction : ArrowParameters [no LineTerminator here] => ConciseBody
// A LineTerminator between the parameter list and `=>` breaks the
// production — the LHS is not a complete expression on its own because
// arrow parameters aren't a valid expression in other contexts, so the
// whole construct is rejected. Unlike `async [no LT] function` (which
// can safely ASI into two separate statements), there is no valid
// alternative parse for this shape.
(x)
=> x;
