// `declare namespace M { ... }` makes the body ambient. The
// overload-chain check is suppressed (TS2391 is not reported on
// `function foo();` here), and `export` directly inside the
// namespace body is legal even though the file is a Script.
declare namespace M {
  function foo(): void;
  export var x: number;
}
