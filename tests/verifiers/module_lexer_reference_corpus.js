'use strict';

// The sources the module-lexer reference gates run over, shared by
// verify_module_lexer_reference.js and verify_module_lexer_node.js so both
// judge exactly the same files.

const fs = require('node:fs');
const path = require('node:path');
const inlineCases = require('./module_lexer_reference_cases.js');

function walk(dir, accept, out) {
  // statSync follows symlinks: the corpora are symlinked shared checkouts.
  for (const name of fs.readdirSync(dir).sort()) {
    const file = path.join(dir, name);
    let stat;
    try { stat = fs.statSync(file); } catch { continue; }
    if (stat.isDirectory()) walk(file, accept, out);
    else if (stat.isFile() && accept(file)) out.push(file);
  }
  return out;
}

const isScript = file => /\.(js|mjs|cjs)$/.test(file);
const TEST262_DIRS = [
  'language/module-code', 'language/import', 'language/export',
  'language/expressions/dynamic-import', 'language/expressions/import.meta',
  'staging/source-phase-imports', 'staging/sm/module',
];
// Babel fixture directories that exercise module syntax, import attributes,
// dynamic import and the source/defer phases.
const BABEL_PATTERN = /module|import|export|dynamic|source-phase|defer|attributes|assert/i;

// Returns {corpus: [{key, read}]}. `key` is the path relative to the corpus
// root, which is what the allow-list is keyed by.
function collectCorpora(root, only) {
  const fromDisk = (base, accept) => walk(base, accept, []).map(file => ({
    key: path.relative(base, file), read: () => fs.readFileSync(file).toString('utf8'),
  }));
  const test262 = path.join(root, 'tests/vendor/test262/test');
  const corpora = {
    real_world: fromDisk(path.join(root, 'bench/real_world'), () => true),
    node_modules: fromDisk(path.join(root, 'bench/node_modules'), isScript),
    test262: TEST262_DIRS.flatMap(dir => fromDisk(path.join(test262, dir), isScript)
      .map(entry => ({ ...entry, key: `${dir}/${entry.key}` }))),
    babel: fromDisk(path.join(root, 'tests/vendor/babel'),
      file => /\/input\.(js|mjs)$/.test(file) && BABEL_PATTERN.test(file)),
    readme: inlineCases.map(item => ({ key: item.name, read: () => item.source })),
  };
  for (const name of Object.keys(corpora)) {
    if (only && only !== name) delete corpora[name];
  }
  return corpora;
}

module.exports = { collectCorpora };
