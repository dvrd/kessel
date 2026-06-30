// no-shadow (L2008), default-off: inner `x` shadows the outer `x`.
var x = 1;
function f() {
  var x = 2;
  return x;
}
f();
console.log(x);
