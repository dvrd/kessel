// Replacement for upstream-renamed Test262 fixture. Exercises the same
// syntactic surface as the original; treated as a positive parse test.

// `with` statement requires sloppy mode (no "use strict").
var o = { a: 1 };
with (o) { var x = a; }
