/**
 * kessel-parser — oxc-parser-compatible shim backed by the Kessel CLI binary.
 *
 * Exposes a `parseSync(filename, source, options?)` function that matches
 * oxc-parser's signature so consumers can swap the two without code changes.
 *
 * Language detection: the `filename` extension controls the grammar:
 *   .js  .mjs  .cjs  → JavaScript (no JSX, no TS types)
 *   .jsx             → JavaScript + JSX
 *   .ts  .mts  .cts  → TypeScript
 *   .tsx             → TypeScript + JSX
 *
 * The returned object matches oxc-parser's shape:
 *   { program: Program, comments: Comment[], errors: ParseError[] }
 */

'use strict';

const { execSync, spawnSync } = require('child_process');
const path = require('path');
const os = require('os');
const fs = require('fs');

// Locate the kessel binary. Prefer a project-local `bin/kessel` (for
// development), then fall back to a bundled binary shipped with this package.
function findBinary() {
  // 1. Project root `bin/kessel` — for monorepo / local dev.
  const localBin = path.resolve(__dirname, '../../bin/kessel');
  if (fs.existsSync(localBin)) return localBin;

  // 2. Platform-specific bundled binary next to this file.
  const platform = process.platform;   // 'darwin' | 'linux' | 'win32'
  const arch     = process.arch;       // 'x64' | 'arm64'
  const bundled  = path.join(__dirname, 'bin', `kessel-${platform}-${arch}`);
  if (fs.existsSync(bundled)) return bundled;

  throw new Error(
    `kessel-parser: cannot locate Kessel binary.\n` +
    `Tried: ${localBin}\n` +
    `Tried: ${bundled}\n` +
    `Build from source: \`task build\` in the kessel repository.`
  );
}

const KESSEL_BIN = findBinary();

/**
 * parseSync — synchronously parse JavaScript / TypeScript source.
 *
 * @param {string} filename  File path or synthetic name (e.g. "test.ts").
 *                           Used only for language detection; the file is not
 *                           read from disk — `source` is the authoritative input.
 * @param {string} source    Source code to parse.
 * @param {object} [opts]    Options (subset of oxc-parser options):
 *   - sourceType: 'script' | 'module' | 'unambiguous'  (default: unambiguous)
 *   - preserveParens: boolean  (default: false)
 *   - loc: boolean             (default: false) — add {line,column} info
 *   - range: boolean           (default: false) — add [start,end] tuple
 * @returns {{ program: object, comments: object[], errors: object[] }}
 */
function parseSync(filename, source, opts = {}) {
  const bin = KESSEL_BIN;

  // Write source to a temp file so Kessel can read it with the right extension.
  const ext = path.extname(filename) || '.js';
  const tmp = path.join(os.tmpdir(), `kessel_${Date.now()}_${Math.random().toString(36).slice(2)}${ext}`);
  fs.writeFileSync(tmp, source, 'utf8');

  try {
    const args = ['parse', tmp, '--compact'];

    // Source type
    if (opts.sourceType && opts.sourceType !== 'unambiguous') {
      args.push(`--source-type=${opts.sourceType}`);
    }
    // Optional flags
    if (opts.preserveParens) args.push('--preserve-parens');
    if (opts.loc)            args.push('--loc');
    if (opts.range)          args.push('--range');

    const result = spawnSync(bin, args, {
      encoding: 'utf8',
      maxBuffer: 200 * 1024 * 1024,
      timeout:   30_000,
    });

    if (result.status !== 0 && !result.stdout) {
      throw new Error(`kessel exited ${result.status}: ${result.stderr || result.error}`);
    }

    // Kessel writes the JSON AST to stdout (first line when --compact).
    const rawJson = (result.stdout || '').split('\n')[0];
    if (!rawJson) {
      throw new Error(`kessel produced no JSON output. stderr: ${result.stderr}`);
    }

    const ast = JSON.parse(rawJson);

    // Extract the top-level error list from stderr statistics.
    const errors = parseErrors(result.stdout || '', result.stderr || '');

    // Shape the return value to match oxc-parser's interface.
    return {
      program:  ast,
      comments: ast.comments || [],
      errors,
    };
  } finally {
    try { fs.unlinkSync(tmp); } catch (_) {}
  }
}

/**
 * Parse structured errors from Kessel's stderr output.
 * Kessel emits errors in the JSON body as a top-level `errors` array when
 * `--errors=oxc` is passed, otherwise the error list appears in the
 * statistics block.
 */
function parseErrors(stdout, stderr) {
  // Try the JSON body first (errors array in program output).
  try {
    const line = stdout.split('\n')[0];
    if (line) {
      const ast = JSON.parse(line);
      if (Array.isArray(ast.errors)) return ast.errors;
    }
  } catch (_) {}

  // Fallback: parse the statistics line from stderr.
  const m = stderr.match(/Parse errors.*?:\s*(\d+)/);
  if (m && parseInt(m[1], 10) > 0) {
    return [{ message: `Parse errors: ${m[1]}` }];
  }
  return [];
}

module.exports = { parseSync };
