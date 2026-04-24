// ECMA-262 §13.3.12 / §15.2 — `new.target` is only valid inside a
// function / method / constructor body. At script / module top level
// (outside any function) it's a SyntaxError.
const t = new.target;
