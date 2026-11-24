// Runtime contract for React Fast Refresh instrumentation. The verifier
// supplies $RefreshReg$ and $RefreshSig$ recorders and a minimal "react"
// package, runs this module, and compares what the runtime was told with the
// pinned OXC transformer: every registration, every signature with its hash,
// force-reset flag and custom Hooks, and the report each render makes.
import React, { useState, useEffect, useReducer, useRef, useCallback, memo, forwardRef } from "react";
import * as Hooks from "./hooks.mjs";
import { useCustom, withTheme, styled } from "./hooks.mjs";

type Props = { label?: string };

export function Counter({ label }: Props) {
  const [count, setCount] = useState<number>(0);
  const [state, dispatch] = useReducer((value: number) => value + 1, 10);
  const ref = useRef(null);
  useEffect(() => {}, []);
  const custom = useCustom(count);
  return <output>{label}{count}{state}{custom}</output>;
}

function helper(): number { return 1; }
function Plain() { return <p>{helper()}</p>; }
const Arrow = () => <span />;
const Expression = function () { return null; };
const Body = () => useState("expression body")[0];
const Curried = () => () => { useCustom(1); return null; };
const Memoized = memo(() => <b />);
const Forwarded = forwardRef(function Inner(props: Props, ref: unknown) {
  const [value] = useState(() => 1);
  return <i>{value}</i>;
});
const Both = React.memo(React.forwardRef((props: Props, ref: unknown) => { Hooks.useNamespaced(); return <u />; }));
const Themed = withTheme(Plain);
const StyledBox = styled.div`color: red;`;
const Factory = Hooks.make();
const notComponent = () => <a />;
const Constant = 5;
let Assigned;
Assigned = () => <em />;
var First = () => null, Second = () => null;

function useLocalState(initial: number) {
  const [value, setValue] = React.useState(initial);
  useEffect(() => {});
  return value;
}
const useDerived = () => { const base = useLocalState(2); return base * 2; };
export const Derived = () => { const value = useDerived(); return <s>{value}</s>; };

function Nested() {
  function Child() { const [open] = useState(false); return open ? null : <li />; }
  const handler = useCallback(function named() { return useCustom(3); }, []);
  if (handler) {
    const Deep = () => { useLocalState(4); return null; };
    return <ul><Child /><Deep /></ul>;
  }
  return null;
}

function Shadowed() {
  function useInner() { return 1; }
  const first = useInner();
  // @ts-expect-error A Hook that only exists as a global is not a binding of this file.
  const second = typeof useGlobalHook === "function" ? useGlobalHook() : 0;
  const { a, b: [c] } = Hooks.useShape({ a: 1 });
  return <div>{first}{second}{a}{c}</div>;
}

function Optional() {
  const value = Hooks?.useNamespaced?.();
  const other = useCustom?.(5);
  return <q>{value}{other}</q>;
}

class Legacy extends React.Component {
  static Row = () => { useCustom(6); return null; };
  method() { return useCustom(7); }
  render() { return null; }
}
const table = {
  Cell: () => { useCustom(8); return null; },
  Head: function () { useCustom(9); return null; },
};
const picked = Constant > 1 ? () => { useCustom(11); return null; } : null;
export const Wrapped = withTheme(memo(() => { const theme = useCustom(12); return <hr />; }), "dark");
export default memo(function Page() { useCustom(13); return <main><StyledBox /><Factory /></main>; });

// Rendering makes each function report itself to its signature handle.
const render = (type: any, ...args: unknown[]) => (typeof type === "function" ? type(...args) : undefined);
for (const type of [Counter, Plain, Arrow, Expression, Body, Curried, Curried(), Derived, Nested, Shadowed, Optional,
  Legacy.Row, table.Cell, table.Head, picked, First, Second, Assigned, notComponent]) render(type, {});
