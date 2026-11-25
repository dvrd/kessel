/** @jsx ui.make */
/** @jsxFrag ui.fragment */
import assert from "node:assert/strict";
const ui = { fragment: Symbol(), make(type: unknown, props: unknown, ...children: unknown[]) { return [type, props, children]; } };
namespace Widgets {
  export let Current = "first";
  export function render() { return <Current />; }
}
assert.equal(Widgets.render()[0], "first");
Widgets.Current = "second";
assert.equal(Widgets.render()[0], "second");
namespace Local {
  export const ui = {
    fragment: "local fragment",
    make(tag: unknown) { return tag; }
  };
  export function render() { return <></>; }
  export function shadow(ui: typeof Local.ui) { return <></>; }
}
assert.equal(Local.render(), "local fragment");
assert.equal(Local.shadow({fragment: "parameter", make: tag => tag}), "parameter");
