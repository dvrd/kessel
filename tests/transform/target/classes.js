// Runtime contract for lowering the ES2022 class features: public fields,
// private names, `#x in o` and static blocks. The file is plain JavaScript,
// so the log Node prints for it as written is the specification, and every
// lowered output must print the same log.
const log = [];
const note = (label, value) => { log.push(label); return value; };
const show = value => {
  if (typeof value === "function") return "fn:" + value.name;
  if (typeof value === "symbol") return value.toString();
  if (typeof value === "bigint") return value + "n";
  if (typeof value === "undefined") return "undefined";
  if (Array.isArray(value)) return "[" + value.map(show).join(",") + "]";
  if (typeof value === "object" && value !== null) return "{" + Object.keys(value).join(",") + "}";
  return JSON.stringify(value);
};
const record = (label, compute) => {
  let outcome;
  try { outcome = show(compute()); } catch (error) { outcome = "throws " + error.constructor.name; }
  log.push(label + " = " + outcome);
};
const own = (target, key) => {
  const d = Object.getOwnPropertyDescriptor(target, key);
  return d ? [d.writable, d.enumerable, d.configurable].join("/") : "missing";
};

// --- Public instance fields ----------------------------------------------
const tag = Symbol("tag");
const counted = { toString() { note("key converted"); return "converted"; } };
class Fields {
  first = note("first", 1);
  second = this.first + 1;
  empty;
  "quoted key" = 3;
  42 = 4;
  [note("computed key", "dynamic")] = 5;
  [tag] = 6;
  [counted] = 7;
  arrow = () => this.second;
  named = function () {};
  inner = class {};
  kept = function original() {};
  [note("method key", "method")]() { return "method"; }
  last = Object.keys(this).length;
}
record("fields created", () => "class");
record("fields values", () => { const o = new Fields(); return [o.first, o.second, o.empty, o["quoted key"], o[42], o.dynamic, o[tag], o.converted, o.arrow(), o.last]; });
record("fields second instance", () => Object.keys(new Fields()));
record("fields names", () => { const o = new Fields(); return [o.arrow.name, o.named.name, o.inner.name, o.kept.name]; });
record("fields descriptor", () => own(new Fields(), "empty") + " " + own(new Fields(), "first"));
record("fields not on prototype", () => Object.getOwnPropertyNames(Fields.prototype));

// Fields are defined, not assigned: an inherited setter is not called.
class Watched { set value(next) { note("setter called"); } get value() { return "inherited"; } }
class Shadow extends Watched { value = "own"; other; }
record("fields define semantics", () => { const o = new Shadow(); return [o.value, own(o, "value"), "other" in o]; });

// An initializer reads the scope of the class, not of the constructor.
const scoped = "outer";
var hoisted = "outer var";
class Scope {
  fromOuter = scoped;
  fromVar = hoisted;
  viaArrow = () => scoped;
  constructor(scoped, extra) {
    var hoisted = "constructor var";
    let unrelated = scoped + extra;
    this.parameter = scoped;
    this.local = hoisted;
    this.sum = unrelated;
    this.shorthand = { scoped, hoisted };
  }
}
record("fields scope", () => { const o = new Scope("param", "!"); return [o.fromOuter, o.fromVar, o.viaArrow(), o.parameter, o.local, o.sum, o.shorthand.scoped, o.shorthand.hoisted]; });

// --- Derived classes -----------------------------------------------------
class Parent {
  constructor(...args) { note("parent constructor " + args.join(",")); this.args = args; }
  greet() { return "parent"; }
}
class NoConstructor extends Parent { field = note("derived field", this.args.length); viaSuper = super.greet(); }
record("derived implicit", () => { const o = new NoConstructor(1, 2); return [o.field, o.viaSuper, o.args]; });
class Explicit extends Parent {
  field = note("explicit field", "f");
  constructor(mode) {
    note("before super");
    if (mode === "arrow") { const call = () => super("arrow"); call(); }
    else if (mode === "expression") { const self = super("expression"); note("super returned this " + (self === this)); }
    else super("plain");
    note("after super " + this.field);
  }
}
record("derived plain", () => new Explicit("plain").field);
record("derived arrow", () => new Explicit("arrow").field);
record("derived expression", () => new Explicit("expression").field);
class Returns { constructor(target) { return target; } }
class Stamp extends Returns { #mark = "marked"; visible = 1; static read(o) { return o.#mark; } static has(o) { return #mark in o; } }
record("return override", () => { const plain = {}; new Stamp(plain); return [Stamp.read(plain), plain.visible, Stamp.has(plain), Stamp.has({})]; });
record("return override twice", () => { const plain = {}; new Stamp(plain); new Stamp(plain); });

// --- Static fields and blocks --------------------------------------------
class StaticBase { static inherited = "base"; static describe() { return "describe " + this.name; } }
class Statics extends StaticBase {
  static a = note("static a", 1);
  static { note("block one " + this.a + " " + (this === Statics)); var local = "scoped to the block"; this.fromBlock = local; }
  static b = this.a + 1;
  static viaSuper = super.describe();
  static viaName = Statics.a + Statics.b;
  static { note("block two " + typeof local + " " + this.b); }
  static method() { return "method"; }
  static called = this.method();
  static [note("static key", "computed")] = "c";
  static empty;
  instance = Statics.b;
}
record("statics values", () => [Statics.a, Statics.b, Statics.fromBlock, Statics.viaSuper, Statics.viaName, Statics.called, Statics.computed, Statics.empty, new Statics().instance]);
record("statics keys", () => Object.keys(Statics));
record("statics inherited", () => [Statics.inherited, Object.prototype.hasOwnProperty.call(Statics, "inherited"), own(Statics, "a")]);
class Renamed { static name = "custom"; static length = 9; }
record("statics name field", () => [Renamed.name, Renamed.length, own(Renamed, "name")]);
class SelfMade { static instance = new SelfMade(); value = 1; static { note("made " + SelfMade.instance.value); } }
record("statics self instance", () => SelfMade.instance.value);

// An anonymous class keeps the name its context gives it.
const Bound = class { static mark = 1; };
let Assigned; Assigned = class { static mark = 2; };
const holder = { Property: class { static mark = 3; }, "string key": class { static mark = 4; } };
const fromDefault = (Parameter = class { static mark = 5; }) => Parameter;
class Holder { Field = class { static mark = 6; }; static Static = class { static mark = 7; }; }
const { Destructured = class { static mark = 8; } } = {};
const Unnamed = [class { static mark = 9; }][0];
const Keeps = class Own { static mark = 10; static self = Own; };
record("names", () => [Bound.name, Assigned.name, holder.Property.name, holder["string key"].name, fromDefault().name, new Holder().Field.name, Holder.Static.name, Destructured.name, Unnamed.name, Keeps.name, Keeps.self === Keeps]);
record("names own", () => [own(Bound, "name"), Object.getOwnPropertyNames(Bound).sort()]);

// --- Private fields ------------------------------------------------------
class Counter {
  #count = 0;
  #label;
  static #created = 0;
  constructor(label) { this.#label = label; Counter.#created += 1; }
  get count() { return this.#count; }
  bump() { return [this.#count++, ++this.#count, this.#count--, --this.#count, this.#count += 10, this.#count **= 2, this.#count >>= 1]; }
  logic() { this.#label ||= note("or assigned", "x"); this.#label &&= this.#label + "!"; let none = { c: this }; none.c.#label ??= note("nullish assigned", "y"); return this.#label; }
  clear() { this.#label = null; this.#label ??= "filled"; this.#label ||= "unused"; return this.#label; }
  order() { return note("object", this).#count = note("value", 5); }
  compound() { return note("object", this).#count += note("operand", 1); }
  static created() { return Counter.#created; }
  static peek(other) { return other.#count; }
  static poke(other) { other.#count = 1; }
  static has(other) { return #count in other; }
  static optional(other) { return [other?.#count, other?.#label.length]; }
  big() { const box = new Big(); return box.step(); }
}
class Big { #n = BigInt(10); step() { return [this.#n++, ++this.#n, this.#n]; } }
record("private bump", () => new Counter("a").bump());
record("private logic", () => new Counter("").logic());
record("private clear", () => new Counter("z").clear());
record("private order", () => new Counter("o").order());
record("private compound", () => new Counter("o").compound());
record("private static", () => Counter.created());
record("private bigint", () => new Counter("b").big());
record("private foreign read", () => Counter.peek({}));
record("private foreign write", () => Counter.poke({}));
record("private in", () => [Counter.has(new Counter("i")), Counter.has({}), Counter.has(Counter), Counter.has(() => 1)]);
record("private in primitive", () => Counter.has(1));
record("private in null", () => Counter.has(null));
record("private optional", () => [Counter.optional(null), Counter.optional(new Counter("four"))]);
record("private hidden", () => { const c = new Counter("h"); return [Object.keys(c), Object.getOwnPropertyNames(c), JSON.stringify(c)]; });

// --- Private methods and accessors ---------------------------------------
class Machine extends Parent {
  #state = "idle";
  early = this.#describe();
  #describe() { return "state " + this.#state + " via " + super.greet(); }
  *#steps() { yield this.#state; yield "done"; }
  get #view() { return this.#state.toUpperCase(); }
  set #view(next) { this.#state = next.toLowerCase(); }
  get #readOnly() { return "read"; }
  set #writeOnly(next) { this.#state = next; }
  static #registry = [];
  static #register(machine) { Machine.#registry.push(machine); return Machine.#registry.length; }
  static get #size() { return Machine.#registry.length; }
  static { Machine.#register(new Machine()); }
  run() {
    this.#view = "RUNNING";
    return [this.#describe(), this.#view, [...this.#steps()], this.#describe === this.#describe, this.#describe.name, Machine.#size];
  }
  call(other) { return other.#describe(); }
  detach() { const fn = this.#describe; return fn.call(this); }
  optional(other) { return [other?.#describe(), this.#missingSafe?.(), other?.#view]; }
  get #missingSafe() { return undefined; }
  assign() { this.#describe = 1; }
  readOnly() { this.#readOnly = 1; }
  writeOnly() { return this.#writeOnly; }
  static register(machine) { return Machine.#register(machine); }
  static steal() { return this.#register; }
  static check(o) { return [#describe in o, #view in o, #register in o, #size in Machine]; }
}
record("methods early", () => new Machine().early);
record("methods run", () => new Machine().run());
record("methods detach", () => new Machine().detach());
record("methods foreign", () => new Machine().call({}));
record("methods optional", () => { const m = new Machine(); return [m.optional(null), m.optional(m)]; });
record("methods assign", () => new Machine().assign());
record("methods read only", () => new Machine().readOnly());
record("methods write only", () => new Machine().writeOnly());
record("methods static", () => Machine.register(null));
record("methods static subclass", () => { class Sub extends Machine {} return Sub.steal(); });
record("methods check", () => Machine.check(new Machine()));
record("methods hidden", () => [Object.getOwnPropertyNames(Machine.prototype).sort(), Object.getOwnPropertyNames(Machine).sort()]);

// --- Private names as assignment targets ---------------------------------
class Targets {
  #a = 0; #b = 0; static #s = 0;
  set #sink(values) { note("sink " + values.join("+")); }
  spread(other) {
    [this.#a, note("target", other).#b = note("default", 9), ...this.#sink] = note("source", [1, undefined, 3, 4]);
    return [this.#a, other.#b];
  }
  object() { ({ x: this.#b, y: { z: Targets.#s } } = { x: 5, y: { z: 6 } }); return [this.#b, Targets.#s]; }
  loops(other) {
    const seen = [];
    for (this.#a of [7, 8]) seen.push(this.#a);
    for (other.#b in { key: 1 }) seen.push(other.#b);
    return seen;
  }
  foreign() { [({}).#a] = [1]; }
}
record("targets array", () => new Targets().spread(new Targets()));
record("targets object", () => new Targets().object());
record("targets loops", () => new Targets().loops(new Targets()));
record("targets foreign", () => new Targets().foreign());

// --- Nesting, shadowing and repeated evaluation --------------------------
class Outer {
  #value = "outer";
  static Inner = class {
    #value = "inner";
    read(outer) { return [this.#value, outer.#secret()]; }
  };
  #secret() { return this.#value; }
  nested() { const read = () => { const deep = function (self) { return self.#value; }; return deep(this); }; return read(); }
}
record("nested shadow", () => new Outer.Inner().read(new Outer()));
record("nested functions", () => new Outer().nested());
const made = [];
for (const round of [1, 2, 3]) {
  class Loop { #id = round; static #made = round * 10; id() { return this.#id; } static made() { return Loop.#made; } static owns(o) { return #id in o; } }
  made.push(Loop, new Loop());
}
record("loop isolation", () => [made[1].id(), made[3].id(), made[0].made(), made[4].made(), made[0].owns(made[1]), made[0].owns(made[3]), made[4].owns(made[5])]);
const factory = seed => class { #seed = seed; static #kind = "k" + seed; get() { return this.#seed; } static kind() { return this.#kind; } static same(o) { return #seed in o; } };
const One = factory(1), Two = factory(2);
record("expression isolation", () => [new One().get(), new Two().get(), One.kind(), Two.kind(), One.same(new One()), One.same(new Two()), One.name]);
function build(depth) {
  class Level { #depth = depth; static below = depth > 0 ? build(depth - 1) : null; depth() { return this.#depth; } }
  return Level;
}
record("recursive evaluation", () => { const top = build(2); return [new top().depth(), new top.below().depth(), new top.below.below().depth()]; });
class Order {
  static { note("order static start"); }
  [note("order key one", "a")] = note("order field a");
  static [note("order key two", "b")] = note("order static b");
  #p = note("order private field");
  [note("order key three", "c")]() {}
  static { note("order static end"); }
  constructor() { note("order constructor"); }
}
record("order", () => { new Order(); return "done"; });

console.log(log.join("\n"));
export {};
