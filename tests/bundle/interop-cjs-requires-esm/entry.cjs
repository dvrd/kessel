console.log('entry');
const esm = require('./lib.mjs');
console.log(Object.keys(esm).sort(), esm.default, esm.named, esm.count);
esm.bump();
// The namespace is live.
console.log(esm.count, require('./lib.mjs') === esm);
const { helper } = require('./dep.mjs');
console.log(helper());
module.exports = { named: esm.named };
