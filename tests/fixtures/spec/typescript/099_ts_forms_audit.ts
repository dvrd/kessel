// TIER-1-AUDIT: exhaustive TS form fixture for codegen round-trip.
// Each block exercises one TSType / TS-declaration form the roadmap
// flagged as Tier 1.1 / 1.2. The verifier diff is the source of truth:
// any form that parses but doesn't round-trip is a real codegen gap.

// ------------------------------------------------------------------
// Tier 1.1 — TS declarations
// ------------------------------------------------------------------

// interface
interface IShape<T extends object = {}> extends Base<T> {
  readonly id: string;
  size?: number;
  resize(w: number, h: number): void;
  get area(): number;
  set area(value: number);
  [index: number]: T;
  (): T;
  new (init: T): IShape<T>;
}

// type alias with generics, defaults, constraints
type AliasA<T, U extends keyof T = "id"> = { value: T; key: U };

// const enum + plain enum + string enum
enum Color { Red, Green = 2, Blue }
const enum Flag { On = 1 << 0, Off = 1 << 1 }
enum Direction { Up = "UP", Down = "DOWN" }

// module declarations: plain namespace, declare module, nested chain
namespace Plain { export const X = 1; }
declare module "ambient-pkg" {
  export function init(opts: { debug: boolean }): void;
  export const VERSION: string;
}
namespace OuterNs.InnerNs.LeafNs { export const TAG = "x"; }

// import-equals
import alias = OuterNs.InnerNs;

// export assignment
export = alias;

// namespace export declaration (TS-specific)
export as namespace KesselGlobal;

// ------------------------------------------------------------------
// Tier 1.2 — TS type forms
// ------------------------------------------------------------------

// TSFunctionType / TSConstructorType
type Fn1 = <T>(x: T) => T;
type Fn2 = abstract new <T>(init: T) => Container<T>;

// TSTypeLiteral with index / call / construct signatures
type Lit1 = { x: number; readonly y?: string; (z: number): void };

// TSConditionalType / TSInferType
type ReturnTypeOf<T> = T extends (...args: any[]) => infer R ? R : never;

// TSTypeQuery
const fnRef = (x: number) => x;
type FnRefType = typeof fnRef;

// TSTypeOperator: keyof / unique / readonly
type Keys = keyof IShape<{}>;
type ReadonlyArr = readonly number[];
declare const sym: unique symbol;

// TSIndexedAccessType
type ValueOfIShape = IShape<{}>["id"];

// TSMappedType
type Partial2<T> = { [K in keyof T]?: T[K] };
type ReadonlyMap<T> = { readonly [K in keyof T]: T[K] };
type RemoveReadonly<T> = { -readonly [K in keyof T]-?: T[K] };
type AsString<T> = { [K in keyof T as `prefix_${string & K}`]: T[K] };

// TSLiteralType / TSTemplateLiteralType
type Lit2 = "literal" | 42 | true | null | -1n;
type Template = `hello ${string}-${number}`;

// TSTypePredicate
function isShape<T extends object>(x: unknown): x is IShape<T> {
  return typeof x === "object";
}
function asserter(x: unknown): asserts x is string {
  if (typeof x !== "string") throw new Error("not string");
}

// TSImportType
type Imp = import("ambient-pkg").init;
type ImpGen<T> = import("ambient-pkg").Foo<T>;

// TSInstantiationExpression
const make = Array<number>;
const make2 = (<T>(x: T) => x)<string>;

class Container<T> {
  constructor(public value: T) {}
}
class Base<T> { kind: T | undefined; }
