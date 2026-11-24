exports.done = false;
const b = require('./b.cjs');
exports.seenB = b.done;
exports.done = true;
