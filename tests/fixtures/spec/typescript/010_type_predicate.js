// TS type predicate: `x is T` return-type annotation for type guards.
// ESTree/TS: TSTypePredicate.parameterName + .typeAnnotation.
function isString(x: unknown): x is string {
  return typeof x === "string";
}
function asserts(x: unknown): asserts x is number {
  if (typeof x !== "number") throw new Error();
}
