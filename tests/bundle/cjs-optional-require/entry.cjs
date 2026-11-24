// The usual probe for an optional dependency: the failure is caught.
let optional;
try {
  optional = require('kessel-fixture-package-that-is-not-installed');
} catch (error) {
  optional = error.code;
}
function later() {
  try { return require('./present.cjs'); } catch { return null; }
}
let nested = 'unset';
try {
  nested = (() => 'arrow body is not a probe')();
} finally {
  console.log(optional, later().ok, nested);
}
module.exports = { optional };
