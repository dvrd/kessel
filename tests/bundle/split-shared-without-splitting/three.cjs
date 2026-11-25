const { tag } = require('./tag.cjs');
console.log('three', tag('3'), require('./data.json').label);
module.exports = { three: true };
