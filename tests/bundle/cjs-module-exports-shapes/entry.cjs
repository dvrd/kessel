const fn = require('./function.cjs');
const cls = require('./class.cjs');
const prim = require('./primitive.cjs');
const reassigned = require('./reassigned.cjs');
const viaThis = require('./this.cjs');
const nul = require('./null.cjs');
console.log(fn(), fn.extra, new cls().kind, prim, reassigned.kept, reassigned.lost, viaThis.fromThis, nul);
console.log(typeof require, typeof require('./function.cjs'), __filename.length > 0, typeof __dirname);
module.exports = { fn, prim };
