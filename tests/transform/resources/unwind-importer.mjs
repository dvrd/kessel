import assert from "node:assert/strict";

for (const [mode, primary, order] of [
  ["before", undefined, []],
  ["default", "default", ["close-inner", "close-outer"]],
  ["step", "step", ["close-outer"]],
  ["normal-close", "return-inner", ["close-inner", "close-outer"]]
]) {
  const events = [];
  globalThis.caseState = { mode, events };
  await assert.rejects(import("./unwind.mjs?" + mode), error => {
    assert.equal(error.name, "SuppressedError");
    assert.equal(error.error, "dispose");
    assert.equal(error.suppressed, primary);
    return true;
  });
  assert.deepEqual(events, [...order, "dispose"]);
}
delete globalThis.caseState;
console.log("module unwinding passed");
