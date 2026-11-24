// Node has no `require` in an ES module; bundlers accept it and bundle the
// target. The expected output is therefore written by hand.
console.log('before require');
const data = require('./data.cjs');
export const value = data.value;
export const base = require('node:path').basename('/a/b.txt');
export const kind = typeof require;
