// Async functions below ES2017. As in lowering.js, the log Node prints for the
// file as written is the specification for every lowered output. Each record
// is one line; records are written by code that runs in a known order, or
// carry the microtask tick at which a promise settled.
//
// A line that ends in a tag such as [field] can be left out together with the
// other lines of that tag. The verifier does so for a reference transformer
// that cannot run the tagged code, and says which and why.
const log = [];
const note = label => (log.push(label), label);
const later = value => new Promise(resolve => setTimeout(() => resolve(value), 1));
const failing = label => new Promise((resolve, reject) => setTimeout(() => reject(new RangeError(label)), 1));
const outcome = async (label, compute) => {
  try { log.push(label + " = " + JSON.stringify(await compute())); } catch (error) { log.push(label + " rejects " + error.constructor.name + " " + error.message); }
};
// Counts the microtask ticks until a promise settles, from the moment it is made.
const ticks = (label, promise) => new Promise(done => {
  let count = 0, settled = false;
  const finish = () => { settled = true; };
  promise.then(finish, finish);
  const turn = () => { if (settled) { log.push(label + " settled at tick " + count); done(); } else { count += 1; Promise.resolve().then(turn); } };
  turn();
});

// ---- Evaluation order: the body runs synchronously up to the first await.
async function ordered(name) {
  note(name + " body start");
  const first = await note(name + " operand");
  note(name + " after first await " + first);
  await null;
  note(name + " after second await");
  return name;
}
async function order() {
  note("before call");
  const one = ordered("one");
  note("between calls");
  const two = ordered("two");
  note("after calls");
  Promise.resolve().then(() => note("then callback queued after both calls"));
  await Promise.all([one, two]);
}

// ---- A parameter that fails rejects the promise; nothing is thrown at the caller.
const boom = label => { note("default evaluated " + label); throw new TypeError(label); };
async function defaulted(a = boom("declaration")) { note("unreachable"); }
const defaultedArrow = async (a = boom("arrow"), b) => { note("unreachable"); };
const destructured = async ({ inner }) => inner;
const holder = { async method(a, { b } = boom("method")) { note("unreachable"); } };
class Parameters { async method(first = boom("class"), ...others) { note("unreachable"); } static async fixed(a = note("static default"), b = a + "!") { return [a, b]; } }
async function parameters() {
  for (const [label, call] of [["declaration", () => defaulted()], ["arrow", () => defaultedArrow()],
    ["pattern", () => destructured(null)], ["method", () => holder.method(1)], ["class", () => new Parameters().method()]]) {
    let promise;
    try { promise = call(); note(label + " returned a promise " + (promise instanceof Promise)); } catch (error) { note(label + " threw at the call"); continue; }
    await outcome(label + " parameter", () => promise);
  }
  await outcome("defaults in order", () => Parameters.fixed());
  await outcome("defaults given", () => Parameters.fixed("x", "y"));
  await outcome("body throws before await", async () => { throw new SyntaxError("early"); });
  await outcome("body throws after await", async () => { await null; throw new SyntaxError("late"); });
}

// ---- this, arguments and new.target.
const receiver = {
  name: "receiver",
  async method(a, b) { await null; return [this.name, arguments.length, a, b, [...arguments].join("")]; },
  plain(a) { return (async (b) => { await null; return [this.name, arguments.length, arguments[0], a, b]; })("inner", "ignored"); },
  nested(a) { return (async () => { const read = () => arguments[0] + this.name; return (async () => (await null, read() + arguments.length))(); })(); },
  shorthand() { const run = async () => ({ arguments }); return run("unused"); }, // [shorthand]
  async own() { const pick = () => arguments[1]; await null; return pick(); },
};
function Construct() { this.made = (async () => { await null; return new.target === Construct; })(); } // [target]
function construct() { return (async () => new.target)(); }
async function target() { return [typeof new.target, await (async () => typeof new.target)()]; }
async function unbound() { return this === undefined; }
async function binding() {
  await outcome("method this and arguments", () => receiver.method(1, 2, 3));
  await outcome("arrow this and arguments", () => receiver.plain("outer", "extra"));
  await outcome("nested arrows", () => receiver.nested("deep"));
  await outcome("shorthand arguments", async () => Array.from((await receiver.shorthand("x", "y")).arguments)); // [shorthand]
  await outcome("arrow sees the method's arguments", () => receiver.own("a", "b"));
  await outcome("call receiver", () => receiver.method.call({ name: "other" }, 9));
  await outcome("strict this", () => unbound());
  await outcome("new.target in an arrow of a constructor", () => new Construct().made); // [target]
  await outcome("new.target in an arrow of a call", () => construct());
  await outcome("new.target in an async function", () => target());
}

// ---- super in methods, static methods, arrows and object literals.
class Base {
  constructor() { this.tag = "instance"; }
  greet(a) { return "base greet " + a + " as " + this.tag; }
  get value() { return "base value of " + this.tag; }
  set value(next) { note("base setter " + next + " on " + this.tag); }
  static make(a) { return "base make " + a + " on " + this.name; }
  static get count() { return this.stored || 0; }
  static set count(next) { this.stored = next; }
}
class Derived extends Base {
  async greet(a) { const before = super.greet(a); await null; return [before, super.greet(a + "!"), super.value]; }
  async computed(key) { await null; return super[key]("computed"); }
  async write() { super.value = "written"; await null; super["value"] = "again"; return Object.keys(this); }
  async arrows(a) { const run = async () => super.greet(await a); const plain = () => super.value; return [await run(), plain()]; }
  async missing() { return typeof super.absent; }
  async optional() { await null; return [super.absent?.(), super.greet?.("optional"), super.absent?.inner]; }
  async created() { return new super.constructor().tag; }
  static async make(a) { await null; return super.make(a); }
  static async counted() { super.count += 2; super.count++; await null; ++super.count; [super.count] = [super.count * 10]; return super.count; } // [update]
  static later = async () => super.make("field arrow"); // [field]
}
const parent = { describe(a) { return "parent " + a + " via " + this.label; } };
const child = { label: "child", async describe(a) { await null; return super.describe(a); }, __proto__: parent };
async function supers() {
  const derived = new Derived();
  await outcome("super call", () => derived.greet("hello"));
  await outcome("super computed", () => derived.computed("greet"));
  await outcome("super write", () => derived.write());
  await outcome("super in arrows", () => derived.arrows(later("awaited")));
  await outcome("super absent", () => derived.missing());
  await outcome("super optional", () => derived.optional());
  await outcome("super constructor", () => derived.created());
  await outcome("static super", () => Derived.make("static"));
  await outcome("static super update", () => Derived.counted()); // [update]
  await outcome("field arrow super", () => Derived.later()); // [field]
  await outcome("object super", () => child.describe("call"));
  // A derived constructor may make and call an arrow before super() returns.
  class Early extends Base { constructor() { const quiet = async () => "no this"; const made = quiet(); super(); this.made = made; this.loud = async () => this.tag; } } // [early]
  const early = new Early(); // [early]
  await outcome("arrow before super", () => early.made); // [early]
  await outcome("arrow after super", () => early.loud()); // [early]
}

// ---- name, length and what kind of function the result is.
async function declared(a, b, c) {}
async function withDefault(a, b = 1, c) {}
async function withRest(a, ...rest) {}
const expression = async function (a, { b }, [c]) {};
const named = async function inner(a) { return inner.name + inner.length; };
const arrow = async (a, b) => {};
const arrowDefault = async (a = 1, b) => {};
const arrowRest = async (...all) => all.length;
const members = { async method(a, b) {}, async [Symbol.iterator](a) {}, key: async function () {}, short: async a => {} };
class Shapes { async method(a) {} static async fixed(a, b = 2) {} }
class Hidden { async #hidden(a, b, c) {} static shape() { return new Hidden().#hidden; } } // [private]
function shape(label, value) {
  let constructible = true;
  try { Reflect.construct(Object, [], value); } catch (error) { constructible = false; }
  log.push(label + ": name " + JSON.stringify(value.name) + ", length " + value.length + ", own prototype " +
    Object.prototype.hasOwnProperty.call(value, "prototype") + ", constructible " + constructible);
}
async function shapes() {
  // A lowered declaration or function expression is an ordinary function: it
  // has a prototype and can be constructed. Arrows and methods are unchanged.
  shape("arrow", arrow); shape("arrow default", arrowDefault); shape("arrow rest", arrowRest);
  shape("object method", members.method); shape("symbol method", members[Symbol.iterator]); shape("arrow property", members.short);
  shape("class method", Shapes.prototype.method); shape("static method", Shapes.fixed);
  shape("private method", Hidden.shape()); // [private]
  for (const [label, value] of [["declared", declared], ["default", withDefault], ["rest", withRest], ["expression", expression],
    ["named expression", named], ["function property", members.key]]) {
    log.push(label + ": name " + JSON.stringify(value.name) + ", length " + value.length);
  }
  await outcome("named expression sees itself", () => named());
  await outcome("rest arrow", () => arrowRest(1, 2, 3));
}

// ---- Microtask timing of await and return.
const thenable = value => ({ then(resolve) { note("then called for " + value); resolve(value); } });
async function timing() {
  await ticks("empty function", (async () => {})());
  await ticks("await of a value", (async () => { await 1; })());
  await ticks("await of a promise", (async () => { await Promise.resolve(1); })());
  await ticks("two awaits", (async () => { await 1; await 2; })());
  await ticks("await of a thenable", (async () => { await thenable("awaited"); })());
  await ticks("return of a promise", (async () => Promise.resolve(1))());
  await ticks("return of a thenable", (async () => thenable("returned"))());
  await ticks("throw", (async () => { throw new Error("x"); })());
  await ticks("await of a rejection", (async () => { await Promise.reject(new Error("x")); })());
  await ticks("await of a rejection, caught", (async () => { try { await Promise.reject(new Error("x")); } catch (error) { return 1; } })());
  await outcome("thenable value", async () => (await thenable("a")) + (await thenable("b")));
  await outcome("rejected await", async () => { try { await failing("first"); } catch (error) { return "caught " + error.message + " then " + (await later("recovered")); } });
  await outcome("uncaught rejection", async () => { await failing("uncaught"); return "unreachable"; });
  await outcome("finally runs", async () => { try { return await later("tried"); } finally { note("finally after await"); await null; note("finally resumed"); } });
  await outcome("finally overrides", async () => { try { await failing("lost"); } finally { return "kept"; } });
}

// ---- await in every position of an expression and a statement.
async function positions() {
  const one = later(1), two = later(2), box = { list: [later("x")], async get() { return this.list; } };
  await outcome("operators", async () => [await one + await two, -await one, (await two) ** 3, typeof await one, !await later(0), await one < await two]);
  await outcome("grouping", async () => [(await one, await two), await (one, two), (await later(null)) ?? "default", (await later(box))?.list.length]);
  await outcome("conditional", async () => (await later(false)) ? "then" : (await later(true)) && (await later("else")));
  await outcome("call and member", async () => [(await box.get())[0] === box.list[0], await (await box.get())[0], Math.max(await one, ...[await two])]);
  await outcome("template and literals", async () => [`${await one}-${await two}`, { [await later("key")]: await later("value") }, [await one, , await two].length]);
  await outcome("assignment", async () => { let a = 0; const o = { n: 1 }; a += await one; o.n += await two; o[await later("m")] = a; [a = await later(7)] = []; return [a, o]; });
  await outcome("loops", async () => {
    const seen = [];
    for (let i = await later(0); i < await later(3); i += await later(1)) { if (i === 1) continue; seen.push(i); }
    for (const item of await later(["a", "b"])) seen.push(await later(item));
    for (const key in await later({ k: 1 })) seen.push(key);
    let n = 0; while (await later(n < 2)) n += 1;
    do { n += 1; } while (await later(n < 5));
    outer: for (const a of [1, 2]) { for (const b of [1, 2]) { if (await later(b === 2)) continue outer; if (a === 2) break outer; seen.push(a * 10 + b); } }
    return [seen, n];
  });
  await outcome("switch and labels", async () => { switch (await later("b")) { case await later("a"): return "a"; case await later("b"): return "b"; default: return "none"; } });
  await outcome("class heritage", async () => { class Local extends (await later(Base)) {} return new Local().tag; });
  await outcome("class method key", async () => { class Local { [await later("dynamic")]() { return "keyed"; } } return new Local().dynamic(); }); // [key]
  await outcome("class field key", async () => { class Local { static [await later("fixed")] = "static"; } return Local.fixed; }); // [field]
  await outcome("closures", async () => { const made = []; for (let i = 0; i < 3; i += 1) { await null; made.push(() => i); } return made.map(read => read()); });
  await outcome("delete and void", async () => { const o = { a: 1 }; return [delete o[await later("a")], void await one, o]; });
}

// ---- Bindings: a var in the body is the parameter; functions hoist.
async function sameName(a) { var a; return a; } // [var]
async function hoisted(a) { const before = typeof inner; await null; function inner() { return a; } return [before, inner()]; }
async function shadows(note) { await null; return typeof note; }
const counter = async function count(n) { return n === 0 ? "done" : count(n - 1); };
async function interleaved(name, delay) {
  const pick = async value => { for (let i = 0; i < delay; i += 1) await later(0); return value; };
  return ((await pick({ name }))?.name ?? "none") + "/" + (await pick(null))?.name;
}
async function bindings() {
  await outcome("var shares the parameter", () => sameName("kept")); // [var]
  await outcome("hoisted function", () => hoisted("seen"));
  await outcome("parameter shadows", () => shadows(1));
  await outcome("recursion", () => counter(3));
  await outcome("interleaved activations", () => Promise.all([interleaved("slow", 3), interleaved("fast", 0), interleaved("mid", 1)]));
  await outcome("async iife in a default", async (value = (async () => later("default"))()) => value);
}

async function main() {
  await order();
  await parameters();
  await binding();
  await supers();
  await shapes();
  await timing();
  await positions();
  await bindings();
}
main().then(() => console.log(log.join("\n")), error => { console.log(log.join("\n")); console.log("FAILED " + error.stack); process.exitCode = 1; });
