// Negative space: distinct names + nested-scope reuse are NOT redeclares.
var a = 1;
var b = 2;
function f() { var a = 3; return a; }
console.log(a, b, f());
