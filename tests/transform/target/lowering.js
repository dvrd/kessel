// Runtime contract for target lowering. The file is plain JavaScript, so Node
// runs it as written and that log is the specification. Every lowered output,
// for each target and printer mode, must print exactly the same log.
// It uses only syntax that ES2015 has or that Kessel lowers.
const log = [];
const note = (label, value) => { log.push(label); return value; };
const show = value => {
  if (typeof value === "function") return "fn:" + value.name;
  if (typeof value === "number" && isNaN(value)) return "NaN";
  if (typeof value === "undefined") return "undefined";
  if (typeof value === "object" && value !== null) return "object";
  return JSON.stringify(value);
};
const record = (label, compute) => {
  let outcome;
  try { outcome = show(compute()); } catch (error) { outcome = "throws " + error.constructor.name; }
  log.push(label + " = " + outcome);
};
// Reads and writes of every property are visible in the log.
const watched = (name, fields) => {
  const store = Object.assign({}, fields);
  return new Proxy(store, {
    get(target, key) { if (typeof key === "string") log.push(name + ".get " + key); return target[key]; },
    set(target, key, value) { log.push(name + ".set " + key + " " + show(value)); target[key] = value; return true; },
    deleteProperty(target, key) { log.push(name + ".delete " + key); return delete target[key]; },
  });
};
var __kessel_t_1 = "user binding";
var __kessel_t_2 = "another user binding";

// --- Nullish coalescing --------------------------------------------------
for (const value of [0, "", false, NaN, null, undefined, "text"]) {
  record("nullish " + show(value), () => value ?? "fallback");
}
record("nullish reads once", () => note("left", null) ?? note("right", 1));
record("nullish skips right", () => note("left", 0) ?? note("right", 1));
record("nullish chain", () => note("a", undefined) ?? note("b", null) ?? note("c", "c") ?? note("d", "d"));
record("nullish grouped or", () => (note("a", 0) || note("b", null)) ?? note("c", "c"));
record("nullish in arithmetic", () => 1 + (null ?? 2) * 3);
record("nullish member", () => watched("box", { empty: null, full: 5 }).empty ?? "none");
record("nullish global", () => typeof (globalThis.missingGlobal ?? "absent"));
{
  let reads = 0;
  Object.defineProperty(globalThis, "accessorGlobal", { configurable: true, get() { reads += 1; return null; } });
  record("nullish accessor global", () => (accessorGlobal ?? "fallback") + " after " + reads + " read");
  record("chain accessor global", () => String(accessorGlobal?.x) + " after " + reads + " reads");
  delete globalThis.accessorGlobal;
}
record("nullish undeclared", () => undeclaredName ?? 1);

// --- Optional chaining ---------------------------------------------------
const tree = { leaf: { value: 7, method() { return this === tree.leaf ? "leaf" : "lost"; } }, none: null, zero: 0,
  method() { return this === tree ? "tree" : "lost"; }, list: [10, 20] };
record("chain member", () => tree?.leaf.value);
record("chain null base", () => tree.none?.value);
record("chain undefined base", () => tree.absent?.value.deeper.still);
record("chain falsy base", () => tree.zero?.toFixed(1));
record("chain computed", () => tree?.["leaf"]?.["value"]);
record("chain call", () => tree?.method());
record("chain optional call", () => tree.method?.());
record("chain missing call", () => tree.absent?.(note("argument", 1)));
record("chain nested call", () => tree.leaf?.method?.());
record("chain call then member", () => tree.leaf.method?.().length);
record("chain grouped", () => (tree.none?.value).deeper);
record("chain grouped callee member", () => (tree.method)?.());
record("chain non-function", () => tree.zero?.());
record("chain skips key", () => tree.none?.[note("key", "k")]);
record("chain skips arguments", () => tree.none?.method(note("argument", 1)).more[note("later", 2)]);
record("chain evaluates key once", () => tree?.list?.[note("index", 1)]);
record("chain function base", () => (() => tree)()?.leaf?.value);
record("chain long", () => tree?.leaf?.method?.()?.length?.toString()?.length);
record("chain object once", () => watched("root", { next: watched("next", { end: 3 }) }).next?.end);
record("chain receiver once", () => watched("host", { run() { return "ran"; } }).run?.());
record("chain in template", () => `${tree?.leaf?.value}/${tree.none?.value}`);
record("chain typeof", () => typeof tree.none?.value);
record("chain indirect eval", () => { const local = "inner"; return eval?.("typeof local"); });
record("chain new target", () => new (tree?.leaf?.constructor)().constructor === Object);
record("delete chain null", () => delete tree.none?.value);
record("delete chain value", () => { const holder = watched("holder", { inner: { x: 1 } }); return delete holder?.inner; });
record("delete chain grouped", () => { const holder = { inner: { x: 1 } }; return [delete (holder?.inner), "inner" in holder].join(); });
class Base { greet() { return "base " + this.name; } get nothing() { return undefined; } }
class Child extends Base {
  constructor() { super(); this.name = "child"; }
  viaSuper() { return [super.greet?.(), super.missing?.(), super.nothing?.x, this?.name].join("|"); }
}
record("chain super", () => new Child().viaSuper());
function recursive(depth) {
  const node = { depth, child: depth > 0 ? { run(inner) { return this === node.child ? inner : "lost"; } } : null };
  return node.child?.run(recursive(depth - 1)) ?? "end" + depth;
}
record("chain recursion", () => recursive(3));
function defaults(first = tree.none?.value ?? note("default", "defaulted"), second = first?.length) { return first + second; }
record("chain in defaults", () => defaults());
function* stepper(source) { const taken = (yield source?.first) ?? (yield "second"); return taken?.done ?? "finished"; }
record("chain in generator", () => { const run = stepper({ first: 1 }); return [run.next().value, run.next(null).value, run.next({}).value].join(); });

// --- Logical assignment --------------------------------------------------
for (const [name, start] of [["zero", 0], ["null", null], ["undefined", undefined], ["one", 1], ["empty", ""]]) {
  record("or-assign " + name, () => { let slot = start; slot ||= "set"; return slot; });
  record("and-assign " + name, () => { let slot = start; slot &&= "set"; return slot; });
  record("nullish-assign " + name, () => { let slot = start; slot ??= "set"; return slot; });
}
record("or-assign member skips", () => { const o = watched("o", { x: 1 }); return o.x ||= note("value", 2); });
record("or-assign member writes", () => { const o = watched("o", { x: 0 }); return o.x ||= note("value", 2); });
record("and-assign member", () => { const o = watched("o", { x: 1 }); return o.x &&= note("value", 2); });
record("nullish-assign member", () => { const o = watched("o", { x: null }); return o.x ??= note("value", 2); });
record("assign object once", () => (note("object", watched("o", {}))).x ??= 5);
record("assign key once", () => { const o = watched("o", { k: 0 }); return o[note("key", "k")] ||= 9; });
record("assign object and key once", () => note("object", watched("o", { k: 1 }))[note("key", "k")] &&= note("value", 3));
record("assign literal key", () => { const o = watched("o", {}); o["lit"] ??= 1; o[0] ??= 2; return o.lit + o[0]; });
record("assign names function", () => { let named; named ??= function () {}; let arrow = 0; arrow ||= () => {}; return named.name + "," + arrow.name; });
record("assign const skipped", () => { const fixed = 1; fixed ||= 2; return fixed; });
record("assign const written", () => { const fixed = 0; fixed ||= 2; return fixed; });
record("assign nested", () => { let a = null, b = 0, c = 1; a ??= b ||= c &&= 4; return [a, b, c].join(); });
record("assign value", () => { let slot; return (slot ??= 3) + (slot ||= 4) + (slot &&= 5); });
class Counter extends Base {
  constructor() { super(); this.count = 0; }
  get nothing() { return super.nothing; }
  bump() { super.extra ??= 1; super.extra &&= super.extra + 1; return this.extra; }
}
record("assign super", () => new Counter().bump());

// --- Exponentiation ------------------------------------------------------
record("power", () => 2 ** 10);
record("power associativity", () => 2 ** 3 ** 2);
record("power grouped base", () => (-2) ** 2);
record("power grouped left", () => (2 ** 3) ** 2);
record("power precedence", () => 2 * 3 ** 2 + -(2 ** 2));
record("power order", () => note("base", 2) ** note("exponent", 3));
record("power coercion", () => "3" ** "2" + NaN ** 0);
record("power assign", () => { let slot = 3; slot **= 2; return slot; });
record("power assign member", () => { const o = watched("o", { x: 2 }); o.x **= note("exponent", 5); return o.x; });
record("power assign computed", () => { const o = watched("o", { k: 2 }); return note("object", o)[note("key", "k")] **= 3; });

// --- Numeric separators --------------------------------------------------
record("separators", () => [1_000_000, 0xFF_FF, 0b1010_0101, 0o7_7, 1_0.5_5, 1e1_0, .5_5].join());

// --- Optional catch binding ----------------------------------------------
record("catch without binding", () => { try { throw new Error("x"); } catch { return "caught"; } });
record("catch nested", () => { try { try { null.x; } catch { throw new RangeError(); } } catch (error) { return error.constructor.name; } });

record("user bindings", () => __kessel_t_1 + ", " + __kessel_t_2);
console.log(log.join("\n"));
