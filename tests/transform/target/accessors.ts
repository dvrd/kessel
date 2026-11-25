// Runtime contract for `accessor` fields, including a legacy decorator on
// one. No engine runs the keyword, so the recorded log is the reference; it
// was produced by Kessel and, with --reference, TypeScript 5.9.3 must agree
// on every record it can produce.
const log: string[] = [];
const record = (label: string, compute: () => unknown): void => {
  let outcome: string;
  try { outcome = JSON.stringify(compute()); } catch (error) { outcome = "throws " + (error as Error).constructor.name; }
  log.push(label + " = " + outcome);
};
function watch(target: any, key: string, descriptor: PropertyDescriptor): PropertyDescriptor {
  log.push("decorate " + key + " " + Object.keys(descriptor).sort().join());
  const { get, set } = descriptor;
  return {
    ...descriptor,
    get() { log.push("get " + key); return get!.call(this); },
    set(next) { log.push("set " + key); set!.call(this, next); },
  };
}
class Box {
  accessor plain = 1;
  @watch accessor watched = "w";
  accessor fn = () => 1;
  accessor "quoted" = 2;
  accessor ["constant"] = 3;
  accessor empty: number | undefined;
  constructor() { log.push("constructor " + this.plain + this.watched); }
}
class Derived extends Box {
  accessor extra = this.plain + 10;
  override accessor plain = 5;
}
const box = new Box();
record("update", () => { box.plain += 1; box.watched = "x"; return [box.plain, box.watched]; });
record("values", () => [box.fn.name, box.quoted, box.constant, box.empty === undefined]);
record("own keys", () => Object.keys(box));
record("prototype", () => Object.getOwnPropertyNames(Box.prototype));
record("descriptor", () => { const d = Object.getOwnPropertyDescriptor(Box.prototype, "plain")!; return [typeof d.get, typeof d.set, d.enumerable, d.configurable]; });
record("foreign receiver", () => Object.getOwnPropertyDescriptor(Box.prototype, "plain")!.get!.call({}));
record("derived", () => { const d = new Derived(); return [d.extra, d.plain]; });
const Expression = class { accessor value = 3; };
record("expression", () => [new Expression().value, Expression.name]);
class Shared { static accessor shared = "s"; static accessor count = 0; }
record("static", () => { Shared.shared += "!"; Shared.count++; return [Shared.shared, Shared.count, Object.keys(Shared)]; });
record("static foreign", () => { class Sub extends Shared {} return Sub.shared; });
console.log(log.join("\n"));
export {};
