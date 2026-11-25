// Run as a script: sloppy mode, where `this` defaults to the global object
// and `arguments` is tied to the parameters.
var log = [];
var outcome = async function (label, compute) {
  try { log.push(label + " = " + JSON.stringify(await compute())); } catch (error) { log.push(label + " rejects " + error.constructor.name); }
};
async function mapped(a, b) { arguments[0] = "written"; b = "assigned"; await null; return [a, arguments[1], arguments.length]; }
async function unmapped(a, b = 1) { arguments[0] = "written"; await null; return [a, b, arguments.length]; }
async function globalThisDefault() { await null; return this === globalThis; }
async function strictInside() { "use strict"; await null; return this === undefined; }
async function boxed() { await null; return [typeof this, this instanceof Number, this === boxed.last, (boxed.last = this) == 5]; }
async function shadowed(arguments) { await null; return arguments; }
async function declaredInside() { var arguments = "local"; await null; return arguments; }
function outer(a) { var run = async () => { a = "changed"; await null; return [arguments[0], arguments.length]; }; return run("x", "y", "z"); }
function withEval() { return (async function (code) { await null; return eval(code); })("typeof arguments + arguments.length"); }
async function duplicate(a, a) { return a; }
var top = async () => typeof module + (await 1);
async function main() {
  await outcome("mapped arguments", () => mapped(1, 2, 3));
  await outcome("unmapped arguments", () => unmapped(1));
  await outcome("default this", () => globalThisDefault());
  await outcome("strict directive", () => strictInside());
  await outcome("boxed this", () => boxed.call(5));
  await outcome("parameter named arguments", () => shadowed("param"));
  await outcome("var named arguments", () => declaredInside("param"));
  await outcome("arrow shares mapped arguments", () => outer("first", "second"));
  await outcome("eval in a function", () => withEval());
  await outcome("duplicate parameters", () => duplicate(1, 2));
  await outcome("top-level arrow", () => top());
  { "use strict"; }
  await outcome("function-level declaration after use", () => late());
  async function late() { return "hoisted"; }
}
main().then(function () { console.log(log.join("\n")); });
