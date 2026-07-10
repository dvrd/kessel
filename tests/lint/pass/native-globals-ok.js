// Passing counterparts for use-isnan (L2018), no-new-native-nonconstructor
// (L2019), and no-obj-calls (L2020): correct usages of each.
function ok(x) {
  if (Number.isNaN(x)) {
    return "nan";
  }
  const s = Symbol("x");
  const n = BigInt(9);
  const big = new Map();
  const r = Math.max(1, 2) + JSON.stringify({ n }) .length + Reflect.ownKeys(big).length;
  return s.toString() + n + r;
}
