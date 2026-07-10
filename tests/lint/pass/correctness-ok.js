// Negative space for the M5 correctness rules: none of these must fire.
// Assignment inside a larger condition (not a bare test) is the safe idiom.
while ((m = re.exec(s)) !== null) {
  use(m);
}
if (a instanceof b) {
  ok();
}
if (value === 0) {
  ok();
}
x = y;
obj.a = obj.b;
const good = new Promise((resolve) => resolve(1));
const also = new Promise(function (resolve) {
  resolve(2);
});
