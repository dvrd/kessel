// use-isnan (L2018): comparing to NaN with === is always false.
function bad(x) {
  if (x === NaN) {
    return "never";
  }
  if (NaN !== x) {
    return "always";
  }
  return "ok";
}
