// `/` as ACTUAL division, not regex. Tokens immediately before are
// of the "operand" class: identifier, numeric literal, `)`, `]`, `++/--`
// suffix, or keywords `this`, `true`, `false`, `null`.
const a = 6 / 2;
const b = x / y;
const c = arr[0] / arr[1];
const d = (x + y) / 2;
const e = obj.count++ / 10;
