// Node.js module patterns
const fs = require('fs');
const path = require('path');

function readConfig(filePath) {
  const fullPath = path.resolve(__dirname, filePath);
  return JSON.parse(fs.readFileSync(fullPath, 'utf8'));
}

module.exports = { readConfig };
module.exports.default = readConfig;
exports.version = '1.0.0';
