// The [~In] restriction of a for-statement head stops at every production that
// is not parameterised by [In]: function bodies, parameter lists, class field
// initializers and class static blocks. Kessel used to carry it into arrow
// block bodies, parameter defaults, field initializers and static blocks, and
// rejected each of these loops. V8 accepts all of them.
for (var f = () => { return "a" in o; }, i = 0; i < 1; i++) {}
for (var f = x => { "a" in o; }; ;) {}
for (var f = async () => { return "a" in o; }; ;) {}
for (var f = async x => { "a" in o; }; ;) {}
for (var f = async (a = "a" in o) => { "a" in o; }; ;) {}
for (var f = () => () => { "a" in o; }; ;) {}
for (var f = function (a = "a" in o) { return "a" in o; }; ;) {}
for (var f = { m(a = "a" in o) {}, set s(a = "a" in o) {} }; ;) {}
for (var c = class { x = "a" in o; static y = "a" in o; }; ;) {}
for (var c = class { static { "a" in o; } }; ;) {}
for (var c = class { m(a = "a" in o) {} constructor(b = "a" in o) {} }; ;) {}
for (var f = () => { if ("a" in o) {} for (var k in o) {} var y = "a" in o; }; ;) {}
for (var f = () => { class C { x = "a" in o; } function g(a = "a" in o) {} }; ;) {}
for (f = () => { "a" in o; }; ;) {}
for (let f = () => { "a" in o; }; ;) {}
for (var f = c ? () => { "a" in o; } : () => { "b" in o; }; ;) {}
for (var f = () => { "a" in o; } in {}) {}
