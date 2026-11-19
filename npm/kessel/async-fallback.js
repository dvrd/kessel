'use strict';

const { Worker } = require('node:worker_threads');

let current;
let nextId = 0;

const PARSE_OPTION_KEYS = [
  'lang', 'sourceType', 'strictSourceType', 'forceStrict', 'preserveParens',
  'mode', 'showSemanticErrors', 'sourceIsDts', 'commonjs', 'disallowAmbiguousJSXLike',
];

function startWorker() {
  const worker = new Worker(require.resolve('./parse-worker'));
  const pending = new Map();
  const state = { worker, pending };

  worker.on('message', ({ id, result, error }) => {
    const request = pending.get(id);
    if (!request) return;
    pending.delete(id);
    if (pending.size === 0) worker.unref();
    if (error) request.reject(error);
    else request.resolve(result);
  });
  function stop(error) {
    if (current === state) current = undefined;
    for (const request of pending.values()) request.reject(error);
    pending.clear();
  }
  worker.once('error', stop);
  worker.once('exit', code => stop(new Error(`Kessel parser worker exited with code ${code}`)));
  return state;
}

function parseOnWorker(filename, source, options, maxPending) {
  return new Promise((resolve, reject) => {
    const transferableOptions = {};
    for (const key of PARSE_OPTION_KEYS) {
      if (options?.[key] !== undefined) transferableOptions[key] = options[key];
    }

    const { worker, pending } = current ||= startWorker();
    if (pending.size >= maxPending) {
      reject(new Error('Kessel parser worker queue is full'));
      return;
    }

    const id = nextId++;
    pending.set(id, { resolve, reject });
    worker.ref();
    try {
      worker.postMessage({ id, filename, source, options: transferableOptions });
    } catch (error) {
      pending.delete(id);
      if (pending.size === 0) worker.unref();
      reject(error);
    }
  });
}

module.exports = { parseOnWorker };
