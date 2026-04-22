// TS index signature — `[k: KeyType]: ValueType` inside an interface /
// type literal. ESTree/TS: TSIndexSignature.parameters + .typeAnnotation.
interface Dict {
  [key: string]: number;
}
type ReadonlyMap = {
  readonly [id: number]: string;
};
