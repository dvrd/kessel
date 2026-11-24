console.log('entry start', typeof module, typeof exports, this === module.exports);
const math = require('./math.cjs');
const { name } = require('./name.cjs');
const again = require('./math.cjs');
console.log(math.add(2, 3), name, again === math, math.calls());
exports.sum = math.add(1, 1);
module.exports.name = name;
