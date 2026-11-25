/** @jsx ui.make @jsxFrag ui.fragment */
import assert from "node:assert/strict";
// @jsx ignoredAfterFirstStatement
const ui = { fragment: Symbol(), make(type: unknown, props: unknown, ...children: unknown[]) { return [type, props, children]; } };
const custom = <>{...["A", "B"]}{false}{null}</>;
assert.deepEqual(custom, [ui.fragment, null, ["A", "B", false, null]]);
const props = <div attr="&amp;&copy;&#x1F642;" empty="" tag={<span />} prior={1} {...{ prior: 2 }} />;
assert.deepEqual(props, ["div", { attr: "&©🙂", empty: "", tag: ["span", null, []], prior: 2 }, []]);
assert.deepEqual(<div> &unknown; &amp &amp; &#xDFFF; </div>, ["div", null, [" &unknown; &amp & &#xDFFF; "]]);
function divide() {
  const numeric = { valueOf() { return 4; } };
  const Ref = { Widget: numeric };
  return 8 / (<Ref.Widget />)[0];
}
assert.equal(divide(), 2);
assert.equal(Number.isNaN(8 / <div />), true);
