// no-dupe-args (L2022): two parameters share the name `a` (sloppy mode).
function add(a, b, a) {
  return a + b;
}
