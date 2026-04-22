const key = "hello";
const obj = {
  [key]: 1,
  ["a" + "b"]: 2,
  [Symbol.iterator]() {}
};
