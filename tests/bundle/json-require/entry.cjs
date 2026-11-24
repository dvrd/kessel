const data = require('./data.json');
const again = require('./data.json');
console.log(data.version, again === data, Array.isArray(require('./list.json')));
module.exports = data;
