const { events, mode } = globalThis.caseState;
function error(value) { throw value; }
function iterable(id, values) {
  return {
    [Symbol.iterator]() {
      let index = 0;
      return {
        next() {
          if (mode === "step" && id === "inner") error("step");
          return { value: values[index++], done: index > values.length };
        },
        return() { events.push("close-" + id); error("return-" + id); }
      };
    }
  };
}
await using cleanup = { [Symbol.asyncDispose || Symbol.for("Symbol.asyncDispose")]() {
  return Promise.resolve().then(() => { events.push("dispose"); throw "dispose"; });
} };
if (mode === "before") error(undefined);
const innerSource = iterable("inner", [undefined]);
const source = iterable("outer", [innerSource]);
export const [[a = mode === "default" ? error("default") : 4]] = source;
