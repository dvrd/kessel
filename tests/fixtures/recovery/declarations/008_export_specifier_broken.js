// Export specifier list with a malformed entry mid-list.
const a = 1;
const b = 2;
const c = 3;
export { a, as , b, c };
const anchor_after_error = 1;
