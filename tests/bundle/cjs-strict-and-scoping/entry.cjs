'use strict';
var shared = 'entry-var';
function helper() { return 'entry-helper'; }
const other = require('./other.cjs');
console.log(shared, helper(), other.read(), typeof globalThis.shared, typeof globalThis.helper);
module.exports = { shared };
