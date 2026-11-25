// Parenthesized simple targets inside a destructuring assignment are valid
// (ECMA-262 13.15.1). The linter parses with parentheses preserved.
let a, b, o = {}, c = { k: 1 }, e = [2];
({ k: (a) } = c);
[(b)] = e;
({ k: (o.p) } = c);
for ([(a)] of [e]) { b = a; }
console.log(a, b, o.p);
