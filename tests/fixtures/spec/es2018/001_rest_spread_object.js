const { a, ...rest } = { a: 1, b: 2, c: 3 };
const copy = { ...rest };
const merged = { ...rest, d: 4 };
