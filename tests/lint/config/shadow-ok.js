// no-shadow clean: distinct names, no inner binding masks an outer one.
var x = 1;
function f() {
  var y = 2;
  return y + x;
}
f();
console.log(x);
