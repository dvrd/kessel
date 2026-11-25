// A parenthesized identifier or member expression is a valid target inside a
// destructuring assignment (ECMA-262 13.15.1). Tools that keep parentheses
// in the tree (lint, transform) must not reject it as a binding element.
let a, b, o = {};
({ k: (a) } = { k: 1 });
[(b)] = [2];
({ k: (o.p) } = { k: 3 });
for ([(a)] of [[4]]) { b = a; }
