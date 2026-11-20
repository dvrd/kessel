'use strict';

const { readFileSync } = require('node:fs');
const { isDeepStrictEqual } = require('node:util');

function readOutput(filename) {
  const text = readFileSync(filename, 'utf8');
  // Pretty-printed AST JSON ends at the first unindented closing brace.
  const end = text.indexOf('\n}\n');
  if (end < 0) throw new Error('Missing AST JSON');
  return {
    ast: JSON.parse(text.slice(0, end + 2)),
    diagnostics: text.slice(end + 2),
  };
}

try {
  const actual = readOutput(process.argv[2]);
  const expected = readOutput(process.argv[3]);
  process.exitCode = isDeepStrictEqual(actual, expected) ? 0 : 1;
} catch {
  process.exitCode = 1;
}
