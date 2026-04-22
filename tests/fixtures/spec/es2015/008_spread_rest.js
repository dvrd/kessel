const arr = [1, 2, 3];
const copy = [...arr];
const merged = [...arr, 4, 5];
function sum(...nums) { return nums.reduce((a, b) => a + b, 0); }
sum(...arr);
