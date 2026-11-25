// Async generators and `for await` below ES2018. As in async.js, the log Node
// prints for the file as written is the specification for every lowered
// output, and a line that ends in a tag can be left out for a reference
// transformer that cannot run it.
const log = [];
const note = label => (log.push(label), label);
const later = value => new Promise(resolve => setTimeout(() => resolve(value), 1));
const failing = label => new Promise((resolve, reject) => setTimeout(() => reject(new RangeError(label)), 1));
const show = result => (result.done ? "done " : "value ") + JSON.stringify(result.value);
const outcome = async (label, compute) => {
  try { log.push(label + " = " + JSON.stringify(await compute())); } catch (error) { log.push(label + " rejects " + error.constructor.name + (error instanceof TypeError ? "" : " " + error.message)); }
};
const ticks = (label, promise) => new Promise(done => {
  let count = 0, settled = false;
  const finish = () => { settled = true; };
  promise.then(finish, finish);
  const turn = () => { if (settled) { log.push(label + " settled at tick " + count); done(); } else { count += 1; Promise.resolve().then(turn); } };
  turn();
});
const collect = async iterable => { const seen = []; for await (const item of iterable) seen.push(item); return seen; };

// ---- The protocol: values in and out, completion, and what the body sees.
async function* counter(from, to) {
  note("counter starts with " + arguments.length + " arguments");
  for (let i = from; i <= to; i += 1) { const sent = yield i; if (sent) note("counter received " + sent); }
  return "finished";
}
const owner = {
  name: "owner",
  async *method(a) { yield this.name; yield await later(a); yield* [later("delegated"), "plain"]; return arguments.length; },
  async *arrows() { const read = async () => [this.name, arguments[0]]; yield await read(); },
};
async function protocol() {
  const run = counter(1, 3);
  note("made, nothing ran yet");
  await outcome("first next", async () => show(await run.next("ignored")));
  await outcome("second next", async () => show(await run.next("hello")));
  await outcome("third next", async () => show(await run.next()));
  await outcome("return value", async () => show(await run.next()));
  await outcome("after completion", async () => show(await run.next()));
  await outcome("iterates itself", async () => run[Symbol.asyncIterator]() === run);
  await outcome("method", () => collect(owner.method("awaited", "extra")));
  await outcome("method return value", async () => { const made = owner.method(1, 2, 3); let last; do { last = await made.next(); } while (!last.done); return last.value; });
  await outcome("arrow in a generator", () => collect(owner.arrows("argument")));
  await outcome("yield awaits a promise", () => collect((async function* () { yield later("resolved"); yield Promise.resolve("ready"); })()));
  await outcome("yield of a rejection is caught inside", () => collect((async function* () { try { yield failing("inside"); } catch (error) { yield "caught " + error.message; } })()));
  await outcome("return awaits a promise", async () => show(await (async function* () { return later("returned"); })().next()));
  await outcome("return of a rejection is caught inside", () => collect((async function* () { try { return failing("returned"); } catch (error) { yield "caught " + error.message; } })()));
  await outcome("body throws", async () => { const made = (async function* () { yield 1; throw new SyntaxError("body"); })(); await made.next(); try { await made.next(); } catch (error) { return [error.message, show(await made.next())]; } });
}

// ---- A parameter that fails throws at the call, before any promise exists.
async function* defaulted(a = (() => { throw new TypeError("default"); })()) { yield a; }
async function parameters() {
  try { defaulted(); note("call returned"); } catch (error) { note("call threw " + error.message); }
  await outcome("parameter given", () => collect(defaulted("given")));
}

// ---- Requests made while the generator runs wait their turn.
async function* slow() { try { note("slow starts"); yield await later("a"); note("slow resumes"); yield "b"; yield "c"; } finally { note("slow cleans up"); } }
async function queueing() {
  const run = slow();
  const pending = [run.next(), run.next(), run.return("stopped"), run.next(), run.throw(new RangeError("late"))];
  pending.forEach((promise, index) => promise.then(result => note("request " + index + " " + show(result)), error => note("request " + index + " rejects " + error.message)));
  await Promise.allSettled(pending);
}

// ---- return() and throw() at the start, at a yield and after the end.
async function* guarded(label) {
  try { yield label + " first"; yield label + " second"; }
  catch (error) { note(label + " caught " + error.message); yield label + " recovered"; }
  finally { note(label + " finally"); await null; note(label + " finally resumed"); }
  return label + " end";
}
async function stopping() {
  let run = guarded("unstarted");
  await outcome("return before start", async () => [show(await run.return("early")), show(await run.next())]);
  run = guarded("unstarted throw");
  await outcome("throw before start", async () => { try { await run.throw(new RangeError("early")); } catch (error) { return [error.message, show(await run.next())]; } });
  run = guarded("yielded");
  await outcome("return at a yield", async () => [show(await run.next()), show(await run.return("stop")), show(await run.next())]);
  run = guarded("thrown");
  await outcome("throw at a yield", async () => [show(await run.next()), show(await run.throw(new RangeError("into"))), show(await run.next())]);
  run = guarded("promised");
  await outcome("return awaits its value", async () => [show(await run.next()), show(await run.return(later("awaited stop")))]);
  run = guarded("rejected");
  await outcome("return of a rejection throws inside", async () => [show(await run.next()), show(await run.return(failing("stop"))), show(await run.next())]); // [rejected]
  run = guarded("ended");
  await outcome("after the end", async () => { for await (const item of run) {} const stopped = show(await run.return(later("again"))); try { await run.throw(new RangeError("over")); } catch (error) { return [stopped, error.message]; } });
  const stubborn = (async function* () { try { yield 1; } finally { yield "from finally"; note("stubborn continues"); } })();
  await outcome("yield in finally", async () => [show(await stubborn.next()), show(await stubborn.return("asked")), show(await stubborn.next())]);
}

// ---- yield* over async and sync sources.
const manual = (label, results, methods = {}) => {
  let index = 0;
  const iterator = { next(sent) { note(label + " next " + JSON.stringify(sent)); return results[index++]; } };
  if (methods.return) iterator.return = value => { note(label + " return " + JSON.stringify(value)); return methods.return(value); };
  if (methods.throw) iterator.throw = error => { note(label + " throw " + error.message); return methods.throw(error); };
  return { [Symbol.asyncIterator]() { note(label + " opened"); return iterator; } };
};
async function delegation() {
  await outcome("yield* of an async generator", () => collect((async function* () { const got = yield* counter(1, 2); yield "inner returned " + got; })()));
  await outcome("yield* of a sync iterable", () => collect((async function* () { yield* [1, later(2), Promise.resolve(3)]; })()));
  await outcome("yield* passes values through unawaited", async () => {
    const promise = Promise.resolve("inner");
    const run = (async function* () { return yield* manual("raw", [{ value: promise, done: false }, later({ value: "end", done: true })]); })();
    const first = await run.next("unused");
    return [first.value === promise, show(await run.next("sent"))];
  });
  await outcome("yield* forwards return", async () => { // [forward]
    const run = (async function* () { try { yield* manual("closed", [{ value: 1, done: false }], { return: value => later({ value: "inner " + value, done: true }) }); } finally { note("outer finally"); } })(); // [forward]
    return [show(await run.next()), show(await run.return("stop")), show(await run.next())]; // [forward]
  }); // [forward]
  await outcome("yield* return that continues", async () => {
    const run = (async function* () { yield* manual("stubborn", [{ value: 1, done: false }, { value: 3, done: true }], { return: () => ({ value: 2, done: false }) }); yield "after"; })();
    return [show(await run.next()), show(await run.return("stop")), show(await run.next()), show(await run.next())];
  });
  await outcome("yield* forwards throw", async () => {
    const run = (async function* () { const got = yield* manual("thrower", [{ value: 1, done: false }], { throw: error => ({ value: "handled " + error.message, done: true }) }); yield got; })();
    return [show(await run.next()), show(await run.throw(new RangeError("sent")))];
  });
  await outcome("yield* without a throw method", async () => { // [nothrow]
    const run = (async function* () { yield* manual("plain", [{ value: 1, done: false }], { return: () => later({}) }); })(); // [nothrow]
    await run.next(); // [nothrow]
    try { await run.throw(new RangeError("sent")); } catch (error) { return error.constructor.name; } // [nothrow]
  }); // [nothrow]
  await outcome("yield* without a return method", async () => {
    const run = (async function* () { yield* manual("open", [{ value: 1, done: false }]); })();
    return [show(await run.next()), show(await run.return("stop"))];
  });
  await outcome("yield* of a failing next", async () => {
    const run = (async function* () { try { yield* manual("broken", [failing("next")], { return: () => ({}) }); } catch (error) { yield "caught " + error.message; } })();
    return show(await run.next());
  });
  await outcome("yield* of a bad result", () => collect((async function* () { yield* manual("bad", [7]); })()));
  await outcome("yield* of a sync generator, stopped", async () => { // [forward]
    function* inner() { try { yield later("one"); yield "two"; } finally { note("sync inner finally"); } } // [forward]
    const run = (async function* () { yield* inner(); })(); // [forward]
    return [show(await run.next()), show(await run.return(later("stop"))), show(await run.next())]; // [forward]
  }); // [forward]
}

// ---- for await.
const source = (label, items, closing) => {
  let index = 0;
  const iterator = { next() { note(label + " next"); return index < items.length ? later({ value: items[index++], done: false }) : later({ value: "ignored", done: true }); } };
  if (closing) iterator.return = function (...given) { note(label + " return with " + given.length + " arguments"); return closing(); };
  return { [Symbol.asyncIterator]: () => iterator };
};
async function loops() {
  await outcome("over an async generator", () => collect(counter(1, 3)));
  await outcome("over a sync iterable", () => collect(["plain", later("promised"), Promise.resolve("ready")]));
  await outcome("over a source without return", () => collect(source("simple", [1, 2])));
  await outcome("break closes", async () => { for await (const item of source("broken", [1, 2, 3], () => later({}))) { if (item === 2) break; } return "left"; });
  await outcome("return closes", () => (async () => { for await (const item of source("returned", [1, 2], () => ({}))) return item; })());
  await outcome("throw closes and wins", async () => { for await (const item of source("thrown", [1], () => { throw new RangeError("from return"); })) throw new SyntaxError("from body"); });
  await outcome("a failing close surfaces", async () => { for await (const item of source("closing", [1], () => failing("close"))) break; });
  await outcome("a bad close result", async () => { for await (const item of source("badclose", [1], () => later(5))) break; }); // [badresult]
  await outcome("continue does not close", async () => { const seen = []; for await (const item of source("continued", [1, 2, 3], () => ({}))) { if (item === 2) continue; seen.push(item); } return seen; });
  await outcome("a failing next does not close", async () => { const broken = source("failing", [], () => ({})); broken[Symbol.asyncIterator]().next = () => failing("next"); for await (const item of broken) note("unreachable"); });
  await outcome("a bad result", async () => { for await (const item of { [Symbol.asyncIterator]: () => ({ next: () => 5 }) }) note("unreachable"); }); // [badresult]
  await outcome("a null async iterator method", () => collect({ [Symbol.asyncIterator]: null, [Symbol.iterator]: () => ["fallback"][Symbol.iterator]() }));
  await outcome("next is read once", async () => { let reads = 0; const iterator = { get next() { reads += 1; let n = 0; return () => ({ value: n, done: n++ === 2 }); } }; for await (const item of { [Symbol.asyncIterator]: () => iterator }); return reads; }); // [once]
  await outcome("values are not awaited", async () => { const promise = Promise.resolve(1); for await (const item of { [Symbol.asyncIterator]: () => ({ next: () => ({ value: promise, done: false }) }) }) return item === promise; });
  await outcome("heads", async () => {
    const seen = [], box = {};
    for await (const [a, { b = "default" }] of [[1, {}], later([2, { b: 3 }])]) seen.push(a, b);
    for await (var hoisted of ["var"]);
    for await (box.member of [later("member")]);
    for await ([box.first, ...box.rest] of [[1, 2, 3]]);
    let assigned; for await (assigned of ["let"]);
    return [seen, hoisted, box, assigned];
  });
  await outcome("bindings per iteration", async () => { const made = []; for await (const item of [1, 2, 3]) { made.push(() => item); } return made.map(read => read()); });
  await outcome("body may redeclare", async () => { const seen = []; for await (const item of [1]) { const item = "inner"; seen.push(item); } return seen; }); // [redeclare]
  await outcome("labels", async () => {
    const seen = [];
    outer: for await (const a of source("outer", [1, 2, 3], () => ({}))) {
      inner: for await (const b of source("inner", [1, 2], () => ({}))) { if (b === 2) continue outer; if (a === 3) break outer; seen.push(a * 10 + b); }
    }
    return seen;
  });
  await outcome("in a generator", () => collect((async function* () { for await (const item of [later(1), 2]) { yield item * 2; } })()));
  await outcome("stopped from outside", async () => {
    const run = (async function* () { for await (const item of source("consumer", [1, 2], () => later({}))) yield item; })();
    return [show(await run.next()), show(await run.return("stop"))];
  });
  await outcome("sync source with a rejected value", async () => { function* inner() { try { yield failing("value"); yield "unreachable"; } finally { note("sync source closed after a rejection"); } } try { for await (const item of inner()) note("unreachable"); } catch (error) { return error.message; } }); // [syncclose]
  await outcome("sync source closes on break", async () => { function* inner() { try { yield 1; yield 2; } finally { note("sync source finally"); } } for await (const item of inner()) break; return "left"; });
}

// ---- Microtask timing.
async function timing() {
  await ticks("next of an empty generator", (async function* () {})().next());
  await ticks("next to a yield", (async function* () { yield 1; })().next());
  await ticks("next to a yielded promise", (async function* () { yield Promise.resolve(1); })().next());
  await ticks("next to a return", (async function* () { return 1; })().next());
  await ticks("next to an await then a yield", (async function* () { await 1; yield 1; })().next());
  await ticks("return on a new generator", (async function* () {})().return(1)); // [ticks]
  await ticks("throw on a new generator", (async function* () {})().throw(new Error("x")));
  await ticks("yield* of an array", (async function* () { yield* [1]; })().next());
  await ticks("yield* of a generator", (async function* () { yield* (async function* () { yield 1; })(); })().next());
  await ticks("for await over an array", (async () => { for await (const item of [1, 2]); })());
  await ticks("for await over a generator", (async () => { for await (const item of (async function* () { yield 1; })()); })());
  await ticks("for await with a break", (async () => { for await (const item of (async function* () { yield 1; })()) break; })()); // [ticks]
}

// ---- name and length. An async generator function has a prototype of its own
// either way; the lowered one is an ordinary function or method.
async function* declared(a, b = 1) {}
const expression = async function* (a, b, c) {};
class Shapes extends Object { async *method(a) { yield super.toString === Object.prototype.toString; yield* super.constructor.keys({ k: a }); } static async *fixed() {} }
async function shapes() {
  for (const [label, value] of [["declared", declared], ["expression", expression], ["method", Shapes.prototype.method], ["static", Shapes.fixed], ["object method", owner.method]]) {
    log.push(label + ": name " + JSON.stringify(value.name) + ", length " + value.length);
  }
  await outcome("super in a generator method", () => collect(new Shapes().method("x")));
}

async function main() {
  await protocol();
  await parameters();
  await queueing(); // [queue]
  await stopping();
  await delegation();
  await loops();
  await timing();
  await shapes();
}
main().then(() => console.log(log.join("\n")), error => { console.log(log.join("\n")); console.log("FAILED " + error.stack); process.exitCode = 1; });
