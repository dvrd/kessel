// Arrow functions with destructuring params
const f = ({ a, b }) => a + b;
const g = ([x, y]) => x + y;
const h = ({ a: { b } }) => b;
const i = ([a, ...rest]) => rest;
const k = ([first, , third]) => first + third;
