const sum = ((1 + 2) as number) * 3;
const asserted = (<number>(2 + 3)) * 4;
const conditional = ((true ? 1 : 2) satisfies number) + 4;
const makeObject = () => <{ value: number }>{ value: 6 };
if (sum !== 9 || asserted !== 20 || conditional !== 5 || makeObject().value !== 6) {
  throw new Error("type erasure changed expression grouping");
}

function missing(): { node?: { value: number } } | undefined { return undefined; }
if (missing()?.node!.value !== undefined) throw new Error("optional chain stopped early");
let caught = false;
try {
  void (missing()?.node as { value: number }).value;
} catch {
  caught = true;
}
if (!caught) throw new Error("optional chain crossed parentheses");
if (1!.toString() !== "1") throw new Error("numeric member receiver");
