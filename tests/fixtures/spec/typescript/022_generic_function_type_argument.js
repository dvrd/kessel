// A generic function type as a type argument keeps its two angle brackets apart.
type A = X< <T>() => T>;
let b: Array< <T>(x: T) => T>;
const c = f< <T>() => T>(1);
type D = X<new <T>() => T>;
type E = import("m").Modifier< <T>(x: T) => T>;
