import assert from "node:assert/strict";
const calls: string[] = [];
const React = {
  Fragment: Symbol("fragment"),
  createElement(tag: unknown, props: unknown, ...children: unknown[]) {
    return { tag, props, children };
  }
};
const Widget = {};
const ui = { nested: { Widget } };
const shared = { id: "shared" };
const mark = (value: string) => (calls.push(value), value);
const tree = <>
  <article aria-label="A &amp; B" ok data-id={mark("attribute")} {...shared} id="last">
    First &lt;line&gt;
    second&#x21;
    {mark("expression")}{/* omitted */}
    <ui.nested.Widget ref={Widget} />
  </article>
  <Widget<number> {...shared} />
  <my-widget title="\literal" />
</>;
assert.equal(tree.tag, React.Fragment);
assert.equal(tree.props, null);
assert.equal(tree.children.length, 3);
const [article, widget, custom] = tree.children;
assert.deepEqual(article.props, { "aria-label": "A & B", ok: true, "data-id": "attribute", id: "last" });
assert.deepEqual(article.children, ["First <line> second!", "expression", { tag: Widget, props: { ref: Widget }, children: [] }]);
assert.equal(widget.tag, Widget);
assert.equal(widget.props, shared);
assert.equal(custom.tag, "my-widget");
assert.equal(custom.props.title, "\\literal");
assert.deepEqual(calls, ["attribute", "expression"]);
let reads = 0;
const getters = <Widget prior {...{ get value() { reads++; return 7; } }} />;
assert.equal(reads, 0);
assert.equal(getters.props.value, 7);
assert.equal(reads, 1);
assert.equal((<Widget {...{}} {...{}} />).props, null);
