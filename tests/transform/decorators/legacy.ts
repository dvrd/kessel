// Runtime contract for TypeScript experimental decorators. The log records
// when each decorator expression is evaluated and applied, what it receives,
// and what the class looks like afterwards. TypeScript 5.9.3, the pinned OXC
// transformer and both Kessel printers must print the same log.
const log: string[] = [];
const show = (value: unknown): string => {
  if (typeof value === "function") return "fn:" + (value.name || "anonymous");
  if (typeof value === "symbol") return value.toString();
  if (value === undefined) return "undefined";
  if (value !== null && typeof value === "object") return "{" + Object.keys(value).sort().join(",") + "}";
  return JSON.stringify(value);
};
function trace(label: string) {
  log.push("evaluate " + label);
  return function (...args: unknown[]): any {
    log.push("apply " + label + "(" + args.map(show).join(", ") + ")");
  };
}
function key(name: string): string {
  log.push("key " + name);
  return name;
}
const symbol = Symbol("tagged");

function replace(label: string) {
  return function <T extends new (...args: any[]) => object>(target: T): T {
    log.push("replace " + label + " " + target.name);
    return class Replaced extends target {
      static replacedBy = label;
    } as T;
  };
}

function readonly(target: object, name: string, descriptor: PropertyDescriptor): PropertyDescriptor {
  return { ...descriptor, writable: false };
}

function double(target: object, name: string, descriptor: PropertyDescriptor): void {
  const original = descriptor.value;
  descriptor.value = function (this: unknown, ...args: number[]) { return 2 * original.apply(this, args); };
}

@trace("class-outer")
@trace("class-inner")
class Order {
  @trace("static-field") static label = "order";
  @trace("field-a") @trace("field-b") first = 1;
  @trace("computed-field") [key("dynamic")] = 2;
  @trace("method")
  method(@trace("method-param-0") left: number, @trace("method-param-1") right: number): number { return left + right; }
  @trace("getter") get value(): number { return this.first; }
  set value(next: number) { this.first = next; }
  get late(): number { return 3; }
  @trace("late-setter") set late(@trace("late-param") next: number) {}
  @trace("static-method") static create(@trace("static-param") seed: number): Order { return new Order(seed); }
  @trace("symbol-method") [symbol](): void {}
  @trace("string-key") "quoted key"(): void {}
  @trace("numeric-key") 42(): void {}
  @trace("constant-computed") ["constant"](): void {}
  @trace("declared") declare ambient: number;
  constructor(@trace("constructor-param") public seed: number) {}
}
log.push("order " + Object.getOwnPropertyNames(Order.prototype).join(","));
log.push("instance " + JSON.stringify(Object.entries(Order.create(7)).sort()));

// A replaced class is what every reference inside the body sees afterwards,
// while static initializers still run against the original.
@replace("self")
class Self {
  static original: unknown = Self;
  static make(): Self { return new Self(); }
  me(): unknown { return Self; }
  shadow(Self: string): string { return Self; }
  nested(): unknown { return () => ({ Self }); }
}
log.push("self replaced " + (Self.name === "Replaced"));
log.push("self original differs " + (Self.original !== Self));
log.push("self original base " + (Object.getPrototypeOf(Self) === Self.original));
log.push("self make " + (Self.make() instanceof Self) + " " + (Self.make().constructor === Self));
log.push("self me " + (new Self().me() === Self));
log.push("self shadow " + new Self().shadow("parameter"));
log.push("self nested " + ((new Self().nested() as () => { Self: unknown })().Self === Self));

class Descriptors {
  @readonly fixed(): number { return 1; }
  @double twice(amount: number): number { return amount; }
  @readonly static fixedStatic(): number { return 2; }
}
log.push("descriptor writable " + Object.getOwnPropertyDescriptor(Descriptors.prototype, "fixed")!.writable);
log.push("descriptor static " + Object.getOwnPropertyDescriptor(Descriptors, "fixedStatic")!.writable);
log.push("descriptor double " + new Descriptors().twice(21));

// Block-scoped classes are decorated on every evaluation of the block.
const built: unknown[] = [];
for (const round of [1, 2]) {
  @trace("loop-class-" + round)
  class Loop {
    @trace("loop-key-" + round) [key("loop" + round)](): number { return round; }
    static round = Loop;
  }
  built.push(Loop, Loop.round);
}
log.push("loop distinct " + (built[0] !== built[2]) + " " + (built[0] === built[1]));

function recursive(depth: number): unknown[] {
  @trace("recursive-" + depth)
  class Level {
    @trace("recursive-key-" + depth) [key("level" + depth)](): number { return depth; }
    static inner = depth > 0 ? recursive(depth - 1) : [];
  }
  return [Object.getOwnPropertyNames(Level.prototype)[1], ...Level.inner];
}
log.push("recursive " + recursive(2).join(","));

@trace("derived")
class Derived extends Descriptors {
  constructor(@trace("derived-param") readonly amount: number) { super(); }
  @trace("override") override twice(value: number): number { return super.twice(value) + this.amount; }
}
log.push("derived " + new Derived(1).twice(4));

namespace Space {
  @trace("namespace-class")
  export class Inside {
    @trace("namespace-method") method(): typeof Inside { return Inside; }
  }
  export const same = new Inside().method() === Inside;
}
log.push("namespace " + Space.same + " " + (typeof Space.Inside));

console.log(log.join("\n"));
export {};
