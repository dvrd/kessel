exports.done = false;
const a = require('./a.cjs');
// a.cjs is half-finished: its partial exports are visible.
exports.seenA = a.done;
exports.done = true;
