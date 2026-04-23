// TS-D: type parameter constraints (`T extends U`) and defaults
// (`T = U`), across every declaration kind that takes type
// parameters: generic functions, classes, interfaces, type aliases.
// Each TSTypeParameter must carry `constraint` and `default` fields
// (OXC emits both; null when absent). Also covers the `extends +
// default` combination and the variance markers `in` / `out`
// (TS 4.7 const / in / out) which Kessel parses but mostly surfaces
// as flags rather than separate nodes.
function identity<T>(x: T): T {
  return x;
}

function constrained<T extends string>(x: T): T {
  return x;
}

function defaulted<T = number>(x: T): T {
  return x;
}

function both<T extends object = {}>(x: T): T {
  return x;
}

class Container<T extends Record<string, unknown>, U = string> {
  constructor(public value: T, public key: U) {}
}

interface Pair<A extends unknown, B = A> {
  first: A;
  second: B;
}

type Tuple<A, B extends A = A> = [A, B];
