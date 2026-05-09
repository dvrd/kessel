// TS2391 — top-level overload-chain check fires when a sig run has
// at least one impl in the same scope but the impl name doesn't
// match. Conservative pre-pass: a single bare `function foo();` at
// top level is NOT reported (matches oxc-semantic), so we exercise
// the chain rule here with a sig + non-matching impl.
function foo();
function bar() {}
