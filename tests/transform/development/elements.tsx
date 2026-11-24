function capture(tag, key, staticChildren, source, hasSelf, self) {
  const result = [tag, key ?? null, staticChildren, source ?? null, hasSelf, self?.label ?? null];
  records.push(result);
  return result;
}
const records: unknown[] = [];
globalThis.recordClassic = (tag, props) => capture(tag, props?.key, null, props?.__source,
  Object.hasOwn(props ?? {}, "__self"), props?.__self);
const React = { createElement: globalThis.recordClassic, Fragment: "fragment" };
globalThis.recordDev = capture;
const __kessel_jsx_filename_1 = "user binding";
const prefix = "🌺"; const first = <unicode key={prefix} />;
const fragment = <><one/><two/></>;
const fallback = <fallback {...{ x: 1 }} key="last" />;
class Base {
  constructor(value: unknown) { this.label = "instance"; }
}
class Child extends Base {
  constructor(value = <parameter/>) {
    const inherited = () => <arrow/>;
    function own() { return <own/>; }
    super(<before>{inherited()}</before>);
    own.call({ label: "function" });
    const after = <after/>;
    class Inner {
      label = "field";
      node = <field/>;
      static { const node = <block/>; }
    }
    new Inner();
  }
  render() { return <method/>; }
}
new Child().render();
if (__kessel_jsx_filename_1 !== "user binding") throw Error("filename shadowing");
console.log(JSON.stringify(records));
