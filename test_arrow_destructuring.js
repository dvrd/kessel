// Test arrow function destructuring with default values
const f = ({ x = 10 }) => x;
const g = ([a = 5]) => a;

// Also test nested destructuring
const h = ({ a: { b = 20 } = {} } = {}) => b;
const i = ([[c = 30]] = []) => c;

// Test mixed destructuring
const j = ({ x = 1, y: z = 2 }) => x + z;
const k = ([a, b = 4, ...rest]) => rest.length;