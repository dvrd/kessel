// TIER-1.3-AUDIT: TS adornments threaded through JS nodes. Round-trips
// here cover every slot from `plans/oxc-substitution-roadmap.md` 1.3.
//
//   * typeAnnotation on identifiers / params / class members
//   * typeParameters on functions / classes / methods / arrows
//   * typeArguments on call / new / tagged-template expressions
//   * importKind / exportKind (`import type`, `import { type X }`)
//   * accessibility / readonly / override on class members
//   * `declare` keyword on every declaration kind
//   * Parameter properties (`constructor(public readonly x: T)`)
//   * Decorators (class + member + parameter)
//   * `?` optional on params and class members

// ------------------------------------------------------------------
// Imports: every kind / phase / specifier shape
// ------------------------------------------------------------------
import type Default from "mod-type";
import { type A, B, type C as CC } from "mod-named";
import type * as NS from "mod-star";
import "side-effect-only";

// ------------------------------------------------------------------
// Exports with `type` modifier
// ------------------------------------------------------------------
export type { A as A2 } from "mod-named";
export { type B as B2, CC as CC2 } from "mod-named";

// ------------------------------------------------------------------
// declare on every container kind
// ------------------------------------------------------------------
declare var dv: number;
declare let dl: string;
declare const dc: boolean;
declare function df(x: number): string;
declare class DC<T> { m(x: T): T; }
declare namespace DN { export const X: number; }
declare module "ambient" { export const Y: string; }

// ------------------------------------------------------------------
// Generic functions / calls / new with typeArguments
// ------------------------------------------------------------------
function generic<T, U extends T = T>(x: T, y: U): [T, U] { return [x, y]; }
const r1 = generic<string, "lit">("a", "lit");
const r2 = new Map<string, number>();
const r3 = tagged<number>`tag${42}`;
function tagged<T>(strings: TemplateStringsArray, ...vals: T[]): T[] { return vals; }

// ------------------------------------------------------------------
// Class with parameter properties + every adornment kind
// ------------------------------------------------------------------
function logged(target: any, key: string) {}
function paramDec(target: any, key: string, idx: number) {}

@logged
class Widget<T> extends Base<T> {
  public readonly id: string = "w";
  protected name?: string;
  private static counter: number = 0;
  override toString(): string { return this.id; }
  declare ambient: T;

  constructor(
    public readonly value: T,
    @paramDec private name2: string,
    protected readonly flags: number = 0,
  ) {
    super();
    Widget.counter++;
  }

  @logged
  static create<U>(v: U): Widget<U> {
    return new Widget<U>(v, "x", 0);
  }
}

class Base<T> { kind?: T; }

// ------------------------------------------------------------------
// Generic arrow + generic method with return type
// ------------------------------------------------------------------
const arrowGeneric = <T,>(x: T): T => x;
const inferReturn = <T,>(x: T) => x;
class WithMethods {
  m1<T>(x: T): T { return x; }
  async m2<T>(x: Promise<T>): Promise<T> { return await x; }
}
