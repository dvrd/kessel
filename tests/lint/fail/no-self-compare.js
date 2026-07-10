// no-self-compare (L2017): comparing a value to itself is almost always a bug.
function check(x, obj) {
  if (x === x) {
    return "nan?";
  }
  if (obj.count > obj.count) {
    return "never";
  }
  return "ok";
}
