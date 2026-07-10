// no-self-compare (L2017) passing: distinct operands, including similar-looking
// but different member chains, are fine.
function check(a, b, obj) {
  if (a === b) {
    return "eq";
  }
  if (obj.count > obj.limit) {
    return "over";
  }
  if (obj.a.b !== obj.a.c) {
    return "diff";
  }
  return "ok";
}
