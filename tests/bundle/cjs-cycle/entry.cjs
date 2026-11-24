const a = require('./a.cjs');
const b = require('./b.cjs');
console.log('entry', a.done, b.done, a.seenB, b.seenA);
module.exports = { a, b };
