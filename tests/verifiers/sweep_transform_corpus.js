'use strict';

// Robustness sweep over the pinned real-world corpus; not part of any gate.
//
//     node tests/verifiers/sweep_transform_corpus.js bin/kessel 2015 --target=es2015
//     node tests/verifiers/sweep_transform_corpus.js bin/kessel latest --react-refresh
//
// Every file is transformed with the given flags. An output must parse with
// acorn at the stated grammar level; a refusal must be a diagnostic on stderr
// with nothing on stdout. Prints one JSON summary and exits non-zero when a
// file crashed the transformer or produced output the grammar rejects.
const fs = require('fs'), path = require('path'), { spawnSync } = require('child_process');
const acorn = require('../../bench/node_modules/acorn');
const [, , binary, level, ...flags] = process.argv;
const root = path.resolve(__dirname, '../../bench/real_world');
const files = [];
(function walk(dir) { for (const e of fs.readdirSync(dir, { withFileTypes: true })) { const p = path.join(dir, e.name); if (e.isDirectory()) walk(p); else files.push(p); } })(root);
let ok = 0, rejected = 0, crashed = 0, unparsable = 0, changed = 0; const reasons = {};
for (const file of files) {
  const r = spawnSync(binary, ['transform', file, ...flags], { encoding: 'utf8', maxBuffer: 1 << 28 });
  if (r.status === 1 && r.stdout === '' && /^error: /.test(r.stderr)) { rejected++; const m = r.stderr.trim().split(': ').pop(); reasons[m] = (reasons[m] || 0) + 1; continue; }
  if (r.status !== 0) { crashed++; console.log('CRASH', file, r.status, r.signal, r.stderr.slice(0, 200)); continue; }
  let parsed = false;
  for (const sourceType of ['module', 'script']) {
    try { acorn.parse(r.stdout, { ecmaVersion: level === 'latest' ? 'latest' : Number(level), sourceType, allowHashBang: true, allowReturnOutsideFunction: true }); parsed = true; break; } catch (e) { var last = e; }
  }
  if (!parsed) { unparsable++; console.log('UNPARSABLE', file, String(last).slice(0, 160)); continue; }
  if (/__kessel_t_|\$RefreshSig\$|Math\.pow/.test(r.stdout)) changed++;
  ok++;
}
console.log(JSON.stringify({ files: files.length, ok, changed, rejected, crashed, unparsable, reasons }));
process.exitCode = crashed || unparsable ? 1 : 0;
