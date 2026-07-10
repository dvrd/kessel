// Passing counterparts for no-prototype-builtins (L2024) and
// no-case-declarations (L2025): the safe .call form, and case bodies that use a
// block scope or only `var`.
function has(obj, key) {
  return Object.prototype.hasOwnProperty.call(obj, key);
}
function pick(x) {
  switch (x) {
    case 1: {
      let a = 1;
      return a;
    }
    case 2:
      var b = 2;
      return b;
    default:
      return 0;
  }
}
