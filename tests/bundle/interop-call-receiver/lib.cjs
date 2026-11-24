'use strict';
function who() { return this === undefined ? 'undefined' : this === module.exports ? 'exports' : this; }
who.Maker = class { made = 'made'; };
exports.who = who;
exports.counter = 0;
exports.bump = function () { exports.counter += 1; };
