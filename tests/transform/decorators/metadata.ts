// Runtime contract for emitDecoratorMetadata. Reflect.metadata is replaced by
// a recorder, so the log lists every design-time value in application order.
// TypeScript 5.9.3 with strictNullChecks, the pinned OXC transformer and both
// Kessel printers run this file; the verifier names the records on which the
// single-file transformers and the type checker cannot agree.
import { EventEmitter } from "node:events";
import type { Readable } from "node:stream";
import * as path from "node:path";
import * as nodeUrl from "node:url";

const log: string[] = [];
const show = (value: unknown): string => {
  if (Array.isArray(value)) return "[" + value.map(show).join(", ") + "]";
  if (typeof value === "function") return value.name;
  return String(value);
};
(Reflect as any).metadata = (key: string, value: unknown) => (target: any, property?: string | symbol) => {
  const owner = typeof target === "function" ? target.name : target.constructor.name + ".prototype";
  log.push(owner + (property === undefined ? "" : "." + String(property)) + " " + key + " " + show(value));
};
const d = (..._: unknown[]): any => undefined;

interface Shape { side: number }
interface Request { url: string }
type Alias = string;
enum Numeric { One, Two }
enum Textual { A = "a", B = `b` }
enum Mixed { Zero, Text = "text" }
const enum Constant { Value = 4 }
class Local { value = 1; }
namespace Scope { export class Inner {} export namespace Deep { export class Leaf {} } }

@d
class Fields<T, U extends Local> {
  @d text!: string;
  @d count!: number;
  @d flag!: boolean;
  @d big!: bigint;
  @d unique!: symbol;
  @d anything: any;
  @d unknownValue: unknown;
  @d nothing!: never;
  @d empty!: void;
  @d missing: undefined;
  @d nil!: null;
  @d plain!: object;
  @d list!: string[];
  @d tuple!: [string, number];
  @d readonlyList!: readonly Local[];
  @d call!: () => void;
  @d construct!: new () => Local;
  @d local!: Local;
  @d alias!: Alias;
  @d shape!: Shape;
  @d request!: Request;
  @d numeric!: Numeric;
  @d textual!: Textual;
  @d mixed!: Mixed;
  @d constant!: Constant;
  @d member!: Numeric.One;
  @d textMember!: Mixed.Text;
  @d inner!: Scope.Inner;
  @d leaf!: Scope.Deep.Leaf;
  @d emitter!: EventEmitter;
  @d readable!: Readable;
  @d parsed!: path.ParsedPath;
  @d url!: nodeUrl.URL;
  @d absent!: path.posix.missing.Type;
  @d generic!: T;
  @d bounded!: U;
  @d nullable!: string | null;
  @d optionalUnion!: string | undefined;
  @d either!: string | number;
  @d strings!: "a" | "b" | `c${number}`;
  @d numbers!: 1 | -2;
  @d yes!: true;
  @d sameClass!: Local | Local;
  @d sameImport!: EventEmitter | EventEmitter;
  @d classOrNull!: Local | null;
  @d both!: Local & Shape;
  @d neverUnion!: string | never;
  @d anyUnion!: string | any;
  @d unknownIntersection!: string & unknown;
  @d query!: typeof log;
  @d keys!: keyof Local;
  @d literalObject!: { x: number };
  @d promise!: Promise<string>;
  @d date!: Date;
  @d optional?: string;
  @d initialized = 1;
  @d self!: this;
  @d indexed!: Local["value"];
  @d conditional!: T extends string ? number : number;
  @d conditionalMixed!: T extends string ? number : string;
  @d grouped!: (string);
  @d bigLiteral!: 1n;
  @d own!: Fields<T, U>;
  @d static shared: Local;
}

@d
class Methods<T> {
  @d plain(first: string, second?: number, ...rest: Local[]): void {}
  @d restGeneric(...rest: Array<EventEmitter>): number { return 0; }
  @d restUntyped(...rest): string { return ""; }
  @d async annotated(): Promise<void> {}
  @d async inferred() {}
  @d receiver(this: Local, value) { return 1; }
  @d patterns(first = 1, { side }: Shape, [head]: string[], last: T): asserts first {}
  @d guard(value: any): value is string { return true; }
  @d *generator(): Generator<number> {}
  @d own<V>(value: V): V { return value; }
  @d get typedGetter(): string { return ""; }
  @d get paired() { return 0; }
  set paired(value: number) {}
  get late(): string { return ""; }
  @d set late(value: string) {}
  @d set lonely(value: Local) {}
  @d get untyped() { return 0; }
  parameter(@d first: string, second: Local) {}
  @d static build(seed: Numeric): Methods<unknown> { return new Methods(new EventEmitter(), new Local()); }
  constructor(@d emitter: EventEmitter, local: Local, private note?: string) {}
}

class Undecorated { constructor(first: string) {} @d method() {} }
@d class Overloaded { constructor(); constructor(first?: number) {} }
@d class Implicit extends Overloaded {}
@d class Empty {}

console.log(log.join("\n"));
