'use strict';

const { parentPort } = require('node:worker_threads');
const { parseSync } = require('./index');

parentPort.on('message', ({ id, filename, source, options }) => {
  try {
    const result = parseSync(filename, source, options);
    parentPort.postMessage({ id, result });
  } catch (error) {
    parentPort.postMessage({ id, error });
  }
});
