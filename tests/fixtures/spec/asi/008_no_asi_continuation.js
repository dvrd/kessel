// ASI MUST NOT apply where the next token CAN continue the expression.
// `a\n(b)` is `a(b)` (call expression spanning the newline), not
// `a;` + `(b);`.  Kessel must concatenate here.
const f = function() { return 42 }
const result = f
(42)
