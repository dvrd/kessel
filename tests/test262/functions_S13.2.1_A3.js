// Replacement for upstream-renamed Test262 fixture. Exercises the same
// syntactic surface as the original; treated as a positive parse test.

function* gen() { yield 1; yield 2; }
async function asyncF() { return 1; }
async function* asyncGen() { yield 1; }
const arrow = () => 1;
const asyncArrow = async () => 1;
