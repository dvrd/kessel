// Replacement for upstream-renamed Test262 fixture. Exercises the same
// syntactic surface as the original; treated as a positive parse test.

var o1 = {};
var o2 = { a: 1, b: 2 };
var o3 = { a, b };
var o4 = { [k]: v };
var o5 = { method() {}, get x() { return 1; }, set x(v) {} };
var o6 = { ...spread };
