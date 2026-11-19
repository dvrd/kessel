'use strict';

const { createHash } = require('node:crypto');
const { readFileSync, readdirSync } = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const corpus = path.resolve(root, process.argv[2] || 'bench/real_world');
const manifest = readFileSync(path.join(root, 'tests/baselines/real_world.sha256'), 'utf8');
const files = new Map(manifest.trimEnd().split('\n').map(line => [line.slice(66), line.slice(0, 64)]));

try {
  const directories = [''];
  for (const directory of directories) {
    for (const entry of readdirSync(path.join(corpus, directory), { withFileTypes: true })) {
      const relative = directory ? `${directory}/${entry.name}` : entry.name;
      if (entry.isDirectory()) {
        directories.push(relative);
        continue;
      }
      if (!entry.isFile() || !/\.m?js$/.test(entry.name)) continue;
      const expected = files.get(relative);
      if (!expected) throw new Error(`Unexpected fixture: ${relative}`);
      const actual = createHash('sha256').update(readFileSync(path.join(corpus, relative))).digest('hex');
      if (actual !== expected) throw new Error(`Fixture checksum mismatch: ${relative}`);
      files.delete(relative);
    }
  }
  if (files.size) throw new Error(`Missing fixture: ${files.keys().next().value}`);
  console.log('Real-world corpus matches the pinned fixture manifest.');
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
