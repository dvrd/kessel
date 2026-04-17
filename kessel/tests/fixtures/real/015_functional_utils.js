// Functional programming utilities
const pipe = (...fns) => x => fns.reduce((v, f) => f(v), x);
const compose = (...fns) => x => fns.reduceRight((v, f) => f(v), x);
const curry = fn => (...args) =>
  args.length >= fn.length ? fn(...args) : curry(fn.bind(null, ...args));

const map = curry((fn, arr) => arr.map(fn));
const filter = curry((fn, arr) => arr.filter(fn));
const reduce = curry((fn, init, arr) => arr.reduce(fn, init));

const data = [1, 2, 3, 4, 5];
const result = pipe(
  filter(x => x > 2),
  map(x => x * 2),
  reduce((a, b) => a + b, 0)
)(data);
