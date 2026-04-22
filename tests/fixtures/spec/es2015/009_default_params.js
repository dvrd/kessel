function greet(name = "world") { return name; }
function point(x = 0, y = 0) { return { x, y }; }
const fn = (a, b = a * 2) => a + b;
