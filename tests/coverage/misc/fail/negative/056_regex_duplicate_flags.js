// ECMA-262 §22.2.1 — RegExp flags may appear at most once per literal.
// The lexer validates at scan time so the diagnostic carries the exact
// offset of the duplicate.
const r = /abc/gg;
