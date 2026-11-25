// Runtime contract for lowering object spread and object rest. The file is
// plain JavaScript, so the log Node prints for it as written is the
// specification, and every lowered output must print the same log.
const log = [];
const note = (label, value) => { log.push(label); return value; };
const show = value => {
  if (typeof value === "function") return "fn:" + value.name;
  if (typeof value === "symbol") return value.toString();
  if (typeof value === "undefined") return "undefined";
  if (Array.isArray(value)) return "[" + value.map(show).join(",") + "]";
  if (typeof value === "object" && value !== null) {
    return "{" + Reflect.ownKeys(value).map(key => String(key) + ":" + show(value[key])).join(",") + "}";
  }
  return JSON.stringify(value);
};
const record = (label, compute) => {
  let outcome;
  try { outcome = show(compute()); } catch (error) { outcome = "throws " + error.constructor.name; }
  log.push(label + " = " + outcome);
};
const tag = Symbol("tag");
// Reads of every property are visible in the log.
const watched = (name, fields) => new Proxy(fields, {
  ownKeys(target) { log.push(name + ".ownKeys"); return Reflect.ownKeys(target); },
  getOwnPropertyDescriptor(target, key) { log.push(name + ".describe " + String(key)); return Reflect.getOwnPropertyDescriptor(target, key); },
  get(target, key) { log.push(name + ".get " + String(key)); return target[key]; },
});
const hidden = Object.defineProperty({ seen: 1 }, "unseen", { value: 2, enumerable: false });
const inherited = Object.create({ fromPrototype: 1 }, { own: { value: 2, enumerable: true } });

// --- Spread --------------------------------------------------------------
record("spread only", () => ({ ...{ a: 1, b: 2 } }));
record("spread first", () => ({ ...{ a: 1 }, b: 2 }));
record("spread middle", () => ({ a: 0, ...{ a: 1, b: 2 }, b: 3, c: 4 }));
record("spread last", () => ({ a: 0, b: 0, ...{ b: 2 } }));
record("spread several", () => ({ ...{ a: 1 }, ...{ b: 2 }, ...{ a: 3 } }));
record("spread order", () => ({ a: note("a", 1), ...note("first", { b: 2 }), c: note("c", 3), ...note("second", { d: 4 }), e: note("e", 5) }));
record("spread nullish", () => ({ a: 1, ...null, ...undefined, b: 2 }));
record("spread primitives", () => ({ ...1, ...true, ..."hi", ...[7, 8] }));
record("spread symbols", () => ({ ...{ [tag]: 1, plain: 2 } }));
record("spread enumerable only", () => [{ ...hidden }, { ...inherited }]);
record("spread proxy", () => ({ before: 1, ...watched("source", { x: 1, y: 2 }), after: 2 }));
record("spread getter once", () => { let reads = 0; const source = { get value() { reads += 1; return reads; } }; const copy = { ...source }; return [copy.value, copy.value, reads, Object.getOwnPropertyDescriptor(copy, "value").writable]; });
record("spread proto key", () => { const copy = { ...JSON.parse('{"__proto__": {"polluted": true}}') }; return [Object.keys(copy), Object.getPrototypeOf(copy) === Object.prototype, copy.polluted]; });
record("spread setter not called", () => { const copy = { set x(value) { note("setter"); }, ...{ x: 1 } }; return Object.getOwnPropertyDescriptor(copy, "x").value; });
record("spread computed", () => ({ [note("key one", "k1")]: 1, ...{ z: 0 }, [note("key two", "k2")]: 2, ["z"]: 3 }));
record("spread methods", () => { const made = { ...{ a: 1 }, method() { return this.a; }, arrow: () => 2, shorthand: note }; return [made.method(), made.arrow(), made.method.name, made.arrow.name, made.shorthand === note]; });
record("spread nested", () => ({ outer: { ...{ inner: { ...{ deep: 1 } } } }, list: [{ ...{ item: 1 } }] }));
record("spread in call", () => Object.assign({}, { ...{ a: 1 } }, { ...{ b: 2 } }));
record("spread identity", () => { const source = { a: {} }; const copy = { ...source }; return [copy !== source, copy.a === source.a]; });

// --- Rest in declarations ------------------------------------------------
record("rest basic", () => { const { a, ...rest } = { a: 1, b: 2, c: 3 }; return [a, rest]; });
record("rest only", () => { const { ...all } = { a: 1, [tag]: 2 }; return all; });
record("rest renamed", () => { let { a: first, "quoted key": second, 3: third, ...rest } = { a: 1, "quoted key": 2, 3: 3, 4: 4, z: 5 }; return [first, second, third, rest]; });
record("rest defaults", () => { var { missing = note("default", 9), ...rest } = { present: 1 }; return [missing, rest]; });
record("rest order", () => { const { a, b, ...rest } = watched("object", { a: 1, b: 2, c: 3, d: 4 }); return [a, b, rest]; });
record("rest once", () => { const { a, ...rest } = note("source", { a: 1, b: 2 }); return rest; });
record("rest enumerable only", () => { const { ...copy } = hidden; const { ...flat } = inherited; return [copy, flat]; });
record("rest null", () => { const { ...rest } = null; return rest; });
record("rest undefined", () => { const { a, ...rest } = undefined; return rest; });
record("rest primitive", () => { const { length, ...characters } = "hey"; return [length, characters]; });
record("rest several", () => { const { a, ...first } = { a: 1, b: 2 }, plain = note("plain", 3), { b, ...second } = { a: 4, b: 5, c: 6 }; return [a, first, plain, b, second]; });
record("rest fresh object", () => { const source = { a: 1, b: {} }; const { ...copy } = source; return [copy !== source, copy.b === source.b, Object.getPrototypeOf(copy) === Object.prototype]; });
record("rest proto key", () => { const { a, ...rest } = JSON.parse('{"a": 1, "__proto__": {"polluted": true}}'); return [Object.keys(rest), rest.polluted]; });
record("rest in for", () => { const seen = []; for (let { step, ...other } = { step: 0, limit: 2 }; step < other.limit; step++) seen.push(step); return seen; });

// --- Rest in parameters --------------------------------------------------
function declared({ a, ...rest }, last) { return [a, rest, last, declared.length]; }
const expression = function ({ a = note("parameter default", 1), ...rest } = { b: 2 }) { return [a, rest]; };
const arrow = ({ a, ...rest }) => [a, rest];
const block = ({ a, ...rest }, other) => { const local = other; return [a, rest, local]; };
const holder = { method({ a, ...rest }) { return [a, rest, this === holder]; }, value: ({ ...all }) => all };
class Params {
  constructor({ id, ...options }) { this.id = id; this.options = options; }
  method({ a, ...rest }, ...more) { return [a, rest, more]; }
  static make({ kind, ...settings }) { return [kind, settings]; }
  set value({ a, ...rest }) { this.seen = [a, rest]; }
}
record("params declared", () => declared({ a: 1, b: 2 }, "last"));
record("params expression", () => [expression(), expression({ a: 5, c: 6 })]);
record("params arrow", () => [arrow({ a: 1, b: 2 }), block({ a: 3, c: 4 }, "other"), arrow.length]);
record("params object", () => [holder.method({ a: 1, b: 2 }), holder.value({ x: 1 })]);
record("params class", () => { const made = new Params({ id: 1, x: 2 }); made.value = { a: 3, b: 4 }; return [made.id, made.options, made.method({ a: 5, c: 6 }, 7, 8), Params.make({ kind: "k", on: true }), made.seen]; });
record("params null", () => arrow(null));
record("params arguments", () => (function ({ a, ...rest }) { return [arguments.length, arguments[0].a, rest]; })({ a: 1, b: 2 }, "extra"));

// --- Rest in loops, catch clauses and assignments -------------------------
record("loop of", () => { const seen = []; for (const { id, ...rest } of [{ id: 1, a: 2 }, { id: 3, b: 4 }]) seen.push([id, rest]); return seen; });
record("loop closures", () => { const read = []; for (const { id, ...rest } of [{ id: 1, a: 2 }, { id: 3, b: 4 }]) read.push(() => [id, rest]); return read.map(call => call()); });
record("loop shadow", () => { const seen = []; for (let { id, ...rest } of [{ id: 1, a: 2 }]) { let id = "inner"; seen.push([id, rest]); } return seen; });
record("loop var", () => { for (var { id, ...kept } of [{ id: 1, a: 2 }, { id: 3, b: 4 }]); return [id, kept]; });
record("loop in", () => { const seen = []; for (const { length, ...characters } in { ab: 1, c: 2 }) seen.push([length, characters]); return seen; });
record("loop expression", () => { let id, rest; const seen = []; for ({ id, ...rest } of [{ id: 1, a: 2 }, { id: 3 }]) seen.push([id, rest]); return [seen, id, rest]; });
record("catch", () => { try { throw Object.assign(new Error("boom"), { code: 7, detail: "d" }); } catch ({ message, ...rest }) { return [message, rest]; } });
record("assignment", () => { let a, rest; const source = { a: 1, b: 2 }; const value = ({ a, ...rest } = source); return [a, rest, value === source]; });
record("assignment targets", () => { const into = { list: [] }; ({ a: into.first, b: into.list[0], ...into.rest } = { a: 1, b: 2, c: 3 }); return into; });
record("assignment order", () => { let a, rest; ({ a = note("assignment default", 1), ...rest } = note("assignment source", watched("assigned", { b: 2 }))); return [a, rest]; });
record("assignment this", () => (function () { ({ a: this.a, ...this.rest } = { a: 1, b: 2 }); return this; }).call({}));
record("assignment statement", () => { let rest; ({ ...rest } = { z: 1 }); return rest; });
record("assignment null", () => { let rest; ({ ...rest } = null); return rest; });

console.log(log.join("\n"));
export {};
