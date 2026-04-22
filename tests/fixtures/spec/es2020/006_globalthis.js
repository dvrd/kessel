const g = globalThis;
globalThis.x = 42;
const hasIt = "x" in globalThis;
