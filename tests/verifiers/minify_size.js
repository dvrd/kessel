'use strict';

// Output sizes of `kessel minify` and of the pinned oxc-minify, raw and gzip
// (zlib level 6 per file, summed), on ten benchmark files or the whole corpus.
//
//   node tests/verifiers/minify_size.js [--corpus] [--out DIR] [--only kessel|oxc]
//
// Each run prints four rows: Kessel default, Kessel --mangle-names, Oxc
// default and Oxc with function and class names kept. With --out, every
// output is written to DIR/<row>/<file> for comparison.

const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const { execFileSync } = require('node:child_process');

const root = path.resolve(__dirname, '../..');
const args = process.argv.slice(2);
const flag = name => { const at = args.indexOf(name); return at >= 0 ? args[at + 1] : null; };
const out = flag('--out');
const only = flag('--only');
const binary = flag('--binary') || path.join(root, 'bin', 'kessel');
const ten = ['typescript.js', 'antd.js', 'babel.js', 'three.module.js', 'react-dom.dev.js', 'd3.js', 'lodash.js',
  'vue.global.js', 'jquery.js', 'react.dev.js'];
const files = args.includes('--corpus')
  ? [...require('./verify_real_world_inputs').readChecksums().keys()] : ten;

const kessel = flags => file => execFileSync(binary, ['minify', file, ...flags], { maxBuffer: 1 << 28 });
const oxc = options => file => {
  const { minifySync } = require('../../bench/node_modules/oxc-minify');
  return Buffer.from(minifySync(file, fs.readFileSync(file, 'utf8'), options).code);
};
const keep = { function: true, class: true };
const rows = {
  'kessel-default': kessel([]),
  'kessel-mangle-names': kessel(['--mangle-names']),
  'oxc-default': oxc({}),
  'oxc-keep-names': oxc({ mangle: { keepNames: keep, toplevel: false }, compress: { keepNames: keep, dropDebugger: false } }),
};

for (const [row, run] of Object.entries(rows)) {
  if (only && !row.startsWith(only)) continue;
  let raw = 0, gzip = 0;
  for (const relative of files) {
    const output = run(path.join(root, 'bench/real_world', relative));
    raw += output.length;
    gzip += zlib.gzipSync(output, { level: 6 }).length;
    if (out) {
      fs.mkdirSync(path.join(out, row), { recursive: true });
      fs.writeFileSync(path.join(out, row, relative.replace(/\//g, '__')), output);
    }
  }
  console.log(row.padEnd(20) + String(files.length).padStart(4) + ' files  raw ' + String(raw).padStart(9) +
    '  gzip ' + String(gzip).padStart(9));
}
