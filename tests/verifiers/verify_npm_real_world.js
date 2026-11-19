'use strict';

const { readFileSync } = require('node:fs');
const { createRequire } = require('node:module');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const binding = path.join(root, 'npm/kessel/index.js');
if (process.argv.includes('--preload-koffi')) createRequire(binding)('koffi').load(null);
const { parseAsync } = require(binding);
const corpus = path.join(root, 'bench/real_world');
const files = readFileSync(path.join(root, 'tests/baselines/real_world.sha256'), 'utf8')
  .trimEnd().split('\n').map(line => line.slice(66));

async function verify() {
  for (const relative of files) {
    const filename = path.join(corpus, relative);
    if (process.argv.includes('--verbose')) console.error(`Parsing ${relative}`);
    const { program, errors } = await parseAsync(filename, readFileSync(filename, 'utf8'));
    if (program.type !== 'Program' || errors.length > 0) {
      throw new Error(`Unexpected npm parse result for ${relative}: ${JSON.stringify(errors.slice(0, 3))}`);
    }
  }
  console.log(`npm parsed all ${files.length} pinned real-world files`);
}

verify().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
