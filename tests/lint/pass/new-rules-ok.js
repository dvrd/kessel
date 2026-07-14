// All new rules should NOT fire on valid code.
for (var i = 0; i < 10; i++) { i; }
for (var j = 10; j > 0; j--) { j; }
if (typeof x === "string") { x; }
if (typeof x === "number") { x; }
try { x; } catch (e) { console.log(e); }
class Foo { set bar(val) { this._bar = val; } }
foo: for (var k = 0; k < 10; k++) { break foo; }
function* gen() { yield 1; }
class Child extends Parent { constructor() { super(); } }
var z = x ? 1 : 0;
