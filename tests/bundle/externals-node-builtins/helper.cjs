const path = require('path');
const { basename } = require('node:path');
exports.helper = (file) => basename(file) + ':' + path.extname(file) + ':' + typeof require.resolve;
