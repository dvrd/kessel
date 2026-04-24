// ECMA-262 §22.2.1 Step 3 — the `u` and `v` flags cannot both be set
// on the same RegExp. `v` is a strict superset of `u` for Unicode
// matching behaviour; the constructor raises SyntaxError if both
// appear.
const r = /abc/uv;
