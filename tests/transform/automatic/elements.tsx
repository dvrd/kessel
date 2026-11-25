const events: string[] = [];
function evaluated(name: string, value: unknown) {
  events.push(name);
  return value;
}
const props = { key: "spread", id: 3 };
const item = <card key={evaluated("key", "explicit")} {...evaluated("props", props)}
  title={evaluated("title", "card")}>{evaluated("child", "text")}</card>;
const fallback = <card {...evaluated("spread", props)} key={evaluated("last key", "last")}>x</card>;
const fragment = <>{/* omitted */}<i />{"second"}{...["third"]}</>;
const singleSpread = <s>{...["first", "second"]}</s>;
const empty = <s>{/* omitted */}</s>;
const duplicate = <s key={evaluated("discarded key", 0)} key={evaluated("final key", 2)} />;
const Child = () => null;
const __kessel_jsx_1 = 12;
const nested = (() => {
  const __kessel_jsx_runtime_1 = 10;
  return <Child value={__kessel_jsx_1 + __kessel_jsx_runtime_1} />;
})();
if (events.join(",") !== "props,title,child,key,spread,last key,final key") throw Error("evaluation order");
if (item.helper !== "jsx" || item.key !== "explicit" || item.props.key !== "spread") throw Error("key");
if (fallback.helper !== "createElement" || fallback.key !== "last" || fallback.props.children !== "x") throw Error("fallback");
if (fragment.helper !== "jsxs" || fragment.tag !== "Fragment" || fragment.props.children.length !== 3) throw Error("fragment");
if (singleSpread.helper !== "jsx" || singleSpread.props.children.join(",") !== "first,second") throw Error("spread child");
if ("children" in empty.props || duplicate.key !== 2 || nested.tag !== Child || nested.props.value !== 22) throw Error("props");
console.log(JSON.stringify([globalThis.loads, events, item, fallback, fragment, singleSpread, empty]));
