#!/usr/bin/env node
// Deep JSON-level ESTree compliance check. Parses a file with Kessel AND with
// OXC's JS binding; walks both trees in parallel; reports every structural
// divergence (missing field, extra field, wrong type, wrong value).
//
// Why this exists: tests/verify_integration.js walks Kessel's raw binary
// buffer against OXC's JSON — great for validating the raw-transfer layout,
// but only 37 of Kessel's 57 emitted node types have raw-buffer walk cases.
// The remaining 20 (Class*, Import*, Export*, SwitchStatement, MetaProperty,
// PrivateIdentifier, RegExpLiteral, SequenceExpression, TaggedTemplateExpression,
// TemplateLiteral, YieldExpression, WithStatement, DebuggerStatement,
// BreakStatement, ContinueStatement, EmptyStatement, ImportExpression) are
// invisible to that gate — any drift in those types silently passes.
//
// This verifier has no such blind spot: it walks the JSON emitter's output
// against OXC's parseSync output by type name, for EVERY node in the tree.
//
// Usage: node tests/verify_json_deep.js <file.js> [--limit N]
//   --limit N: stop after N divergences (default 30) to keep output readable.
//
// Exit 0 on match, 1 on any divergence.

'use strict';
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
// Lazy-load the chosen reference parser so a missing dependency only breaks
// the suite that uses it.
function loadParser(kind) {
  const base = path.resolve(__dirname, '../../bench/node_modules');
  switch (kind) {
    case 'oxc':   return { parseSync: require(path.join(base, 'oxc-parser')).parseSync, kind };
    case 'acorn': return { parse: require(path.join(base, 'acorn')).parse, kind };
    case 'babel': return { parse: require(path.join(base, '@babel/parser')).parse, kind };
  }
}

const file = process.argv[2];
const limitArg = process.argv.indexOf('--limit');
const LIMIT = limitArg > 0 ? parseInt(process.argv[limitArg + 1], 10) : 30;
const parserArg = process.argv.indexOf('--parser');
const PARSER = parserArg > 0 ? process.argv[parserArg + 1] : 'oxc';
if (!file) {
  console.error('Usage: node verify_json_deep.js <file.js> [--limit N] [--parser oxc|acorn|babel]');
  process.exit(2);
}
if (!['oxc', 'acorn', 'babel'].includes(PARSER)) {
  console.error(`Unknown --parser "${PARSER}"; expected oxc|acorn|babel`);
  process.exit(2);
}

const KESSEL = path.resolve(__dirname, '../../bin/kessel');
const source = fs.readFileSync(file, 'utf8');
const name = path.basename(file);

// -----------------------------------------------------------------------------
// Normalisation: fields Kessel doesn't emit today (and we explicitly don't
// require parity on) get stripped from OXC's tree before compare. Each
// exclusion has a `reason` so we can see which gaps remain to close.
// -----------------------------------------------------------------------------
// Fields stripped regardless of reference parser — things Kessel intentionally
// doesn't emit today and which are variable across dialects.
const STRIP_FIELDS_GLOBAL = new Set([
  'loc',         // Babel always, acorn opt-in, OXC never. Kessel never.
  'decorators',  // OXC always emits [] even when empty.
  'optional',    // optional-chaining `optional: false` marker.
  'range',       // Acorn `ranges: true` option.
]);

// Extra stripping specific to one reference parser — these are parser-specific
// fields we don't expect Kessel to emit.
const STRIP_FIELDS_BY_PARSER = {
  oxc: new Set([]),
  acorn: new Set([
    // Import attributes spec — acorn emits `attributes: []` on every
    // import/export declaration. Kessel doesn't support the proposal.
    'attributes',
  ]),
  babel: new Set([
    'extra',           // Babel's literal-extras container.
    'innerComments', 'leadingComments', 'trailingComments',  // comment arrays.
    'directives',       // Babel splits directives into a separate array.
    'directive',        // on ExpressionStatement (differently placed in Babel).
    'errors',           // Babel error-recovery list.
    'interpreter',      // shebang container.
    'method',           // Babel differs; Kessel matches OXC.
    'importKind', 'exportKind',  // Babel Flow/TS marker.
    'assertions',       // older name for import attributes.
    'attributes',       // current name for import attributes.
    'exported',         // Babel only emits when non-null; Kessel always.
  ]),
};

// Fields Kessel emits that the reference parser doesn't — stripped from the
// KESSEL side so the compare doesn't flag them as "extra".
const KESSEL_STRIP_FIELDS_FOR_PARSER = {
  oxc:   new Set([]),
  acorn: new Set(['hashbang']),
  // Babel's normaliseBabelType produces Literal objects that preserve `raw`
  // (via extra.raw); keep them on the Kessel side so compare symmetrically.
  // `regex` is a Kessel-only field here — Babel's normalised Literal doesn't
  // include it, so strip it from Kessel to avoid an "extra" flag.
  babel: new Set(['hashbang', 'regex', 'exported']),
};

// ParenthesizedExpression is an OXC option (preserveParens). ESTree's original
// spec folds parentheses away; Acorn+Babel+Kessel all do that. OXC preserves
// them by default — when we see one, unwrap it to compare the inner expression
// with Kessel's unwrapped equivalent.
function unwrapParens(node) {
  if (node && node.type === 'ParenthesizedExpression' && node.expression) {
    return unwrapParens(node.expression);
  }
  return node;
}

// Per-type field stripping — these fields exist on specific node types in the
// reference parser but Kessel doesn't emit them. Organised by parser so we can
// see at a glance which gaps are dialect-specific.
const STRIP_FIELDS_BY_TYPE_PER_PARSER = {
  oxc: {
  // ImportDeclaration / Export*: OXC emits `attributes: []` (import attributes
  // proposal). Kessel doesn't emit the field. Tolerated.
  ImportDeclaration:        new Set(['attributes', 'phase']),
  ExportAllDeclaration:     new Set(['attributes']),
  ExportNamedDeclaration:   new Set(['attributes']),
  // ImportExpression: OXC emits `options` and `phase` fields from the newer
  // dynamic-import specs (import() second arg). Kessel doesn't support these.
  ImportExpression:         new Set(['options', 'phase']),
  // MetaProperty: OXC's children have `start`/`end` — we compare those. No extras.
  // RegExp in Literal: OXC emits `regex: {pattern, flags}` — Kessel does too.
  // Program: Kessel and OXC both emit `sourceType` and `hashbang` today.
  // No fields to strip. If `hashbang` content differs (Kessel emits null when
  // OXC emits the parsed shebang string), the compare flags it — correct
  // behaviour, since the lexer currently doesn't preserve the shebang.
  Program:                  new Set([]),
  // Identifier inside certain positions (e.g. ClassDeclaration.id) differs by
  // `typeAnnotation`/`optional` in OXC's TS-aware mode. Stripped; we don't
  // emit these.
  Identifier:               new Set(['typeAnnotation', 'optional']),
  // FunctionDeclaration/Expression: OXC emits `returnType`, `typeParameters`
  // for TS. Stripped.
  FunctionDeclaration:      new Set(['returnType', 'typeParameters', 'predicate']),
  FunctionExpression:       new Set(['returnType', 'typeParameters', 'predicate']),
  ArrowFunctionExpression:  new Set(['returnType', 'typeParameters']),
  MethodDefinition:         new Set(['typeParameters']),
  PropertyDefinition:       new Set(['typeAnnotation', 'readonly', 'declare', 'definite', 'accessibility']),
  ClassDeclaration:         new Set(['typeParameters', 'implements', 'abstract']),
  ClassExpression:          new Set(['typeParameters', 'implements', 'abstract']),
  VariableDeclaration:      new Set(['declare']),
  VariableDeclarator:       new Set(['definite']),
  // SwitchCase in OXC has no extras today.
  // CatchClause: no extras.
  },
  acorn: {
    // Acorn's ESTree shape is very close to Kessel's; nothing to strip per-type.
  },
  babel: {
    // Babel uses distinct types for numeric/string/boolean etc. — we'd need
    // type-level normalisation (e.g. NumericLiteral → Literal) rather than
    // field stripping. See `normalizeBabelType` below.
  },
};

// Per-type known drifts we explicitly allow (with a note). None today.
const IGNORE_PATH_PATTERNS = [
  // Add regex patterns for paths we want to silently skip.
];

function shouldIgnorePath(pathStr) {
  for (const re of IGNORE_PATH_PATTERNS) {
    if (re.test(pathStr)) return true;
  }
  return false;
}

// Normalise Babel's custom types back to ESTree's `Literal` so we can compare
// against Kessel's ESTree-style output without a 1:1 field diff.
function normalizeBabelType(node) {
  if (!node || typeof node !== 'object') return node;
  switch (node.type) {
    case 'NumericLiteral':
    case 'StringLiteral':
    case 'BooleanLiteral':
    case 'NullLiteral':
    case 'BigIntLiteral':
    case 'RegExpLiteral': {
      // Produce a new Literal-shaped object; preserve start/end.
      const raw = node.extra && node.extra.raw ? node.extra.raw : String(node.value);
      const value = node.type === 'NullLiteral' ? null : node.value;
      return { type: 'Literal', value, raw, start: node.start, end: node.end };
    }
    case 'DirectiveLiteral': {
      // Babel wraps directive string literals specially; downstream we'll skip
      // these since Babel emits Directive in a separate array too.
      return { type: 'Literal', value: node.value, raw: node.extra && node.extra.raw, start: node.start, end: node.end };
    }
    default: return node;
  }
}

function stripNode(node) {
  if (node == null || typeof node !== 'object') return node;
  if (Array.isArray(node)) return node.map(stripNode);
  node = unwrapParens(node);
  if (node == null || typeof node !== 'object') return node;
  if (PARSER === 'babel') node = normalizeBabelType(node);
  const type = node.type;
  const out = {};
  const perTypeStripAll = STRIP_FIELDS_BY_TYPE_PER_PARSER[PARSER] || {};
  const perTypeStrip = perTypeStripAll[type] || null;
  const parserStrip = STRIP_FIELDS_BY_PARSER[PARSER] || new Set();
  // RegExp Literal: ESTree's `value` for a regex is a RegExp object, which
  // isn't JSON-serializable. OXC emits `{}` (the JSON of an empty object
  // literal substitute); Acorn emits `null`; Kessel emits `null`. Both are
  // valid ESTree serialisations of an unrepresentable regex value — normalise
  // to `null` before compare so the two sides match.
  if (type === 'Literal' && node.regex && node.value && typeof node.value === 'object' && Object.keys(node.value).length === 0) {
    // Clone with value:null so stripNode recursion sees the normalised form.
    node = Object.assign({}, node, { value: null });
  }
  for (const key of Object.keys(node)) {
    if (STRIP_FIELDS_GLOBAL.has(key)) continue;
    if (parserStrip.has(key)) continue;
    if (perTypeStrip && perTypeStrip.has(key)) continue;
    out[key] = stripNode(node[key]);
  }
  return out;
}

// Symmetric strip on the Kessel side so Kessel-emitted fields that the
// reference parser doesn't produce (e.g. `hashbang` vs acorn) don't trigger
// "extra" errors.
function stripKesselForParser(node) {
  if (node == null || typeof node !== 'object') return node;
  if (Array.isArray(node)) return node.map(stripKesselForParser);
  const strip = KESSEL_STRIP_FIELDS_FOR_PARSER[PARSER] || new Set();
  const out = {};
  for (const key of Object.keys(node)) {
    if (strip.has(key)) continue;
    out[key] = stripKesselForParser(node[key]);
  }
  return out;
}

// -----------------------------------------------------------------------------
// Parse both sides.
// -----------------------------------------------------------------------------
function parseKessel(file) {
  const raw = execSync(`"${KESSEL}" parse "${file}" --compact`,
                       { encoding: 'utf8', maxBuffer: 200 * 1024 * 1024 });
  // Kessel appends statistics to stderr; stdout first line is the JSON.
  return JSON.parse(raw.split('\n')[0]);
}

// Each reference parser gives back a Program node. Acorn returns it directly,
// Babel wraps in `File { program: Program }`, OXC exposes it on `result.program`.
function parseReference(kind, src) {
  const parser = loadParser(kind);
  switch (kind) {
    case 'oxc':   return parser.parseSync(name, src).program;
    case 'acorn': return parser.parse(src, {
      ecmaVersion: 'latest',
      sourceType:  'module',  // acorn rejects top-level imports in script mode
      allowHashBang: true,
      allowReturnOutsideFunction: true,
      allowAwaitOutsideFunction: true,
      allowSuperOutsideMethod: true,
    });
    case 'babel': return parser.parse(src, {
      sourceType:       'unambiguous', // auto-detect module vs script
      allowImportExportEverywhere: true,
      allowReturnOutsideFunction: true,
      allowAwaitOutsideFunction: true,
      allowSuperOutsideMethod: true,
      errorRecovery:    true,
      ranges:           false,
      tokens:           false,
      createParenthesizedExpressions: false, // strip parens like Kessel does
      plugins: ['classProperties', 'classPrivateProperties', 'classPrivateMethods',
                'topLevelAwait', 'importAssertions', 'decorators-legacy'],
    }).program;
  }
}

let kTree, oTree;
try { kTree = stripKesselForParser(parseKessel(file)); }
catch (e) { console.error(`kessel parse failed: ${e.message}`); process.exit(2); }
try { oTree = stripNode(parseReference(PARSER, source)); }
catch (e) { console.error(`${PARSER} parse failed: ${e.message}`); process.exit(2); }

// -----------------------------------------------------------------------------
// Deep compare. `path` is a dotted/bracketed ESTree path like
//   body[0].declarations[0].init.value
// so divergences can be grep'd in the source file immediately.
// -----------------------------------------------------------------------------
let errors = 0;
let typesSeen = new Map(); // For coverage reporting.

function bump(type) {
  typesSeen.set(type, (typesSeen.get(type) || 0) + 1);
}

function report(p, msg) {
  if (shouldIgnorePath(p)) return;
  errors++;
  if (errors <= LIMIT) console.error(`  FAIL ${p}: ${msg}`);
}

function compare(k, o, p) {
  if (k === o) return;
  if (k == null && o == null) return;
  if (k == null || o == null) {
    report(p, `kessel=${JSON.stringify(k)} oxc=${JSON.stringify(o)}`);
    return;
  }
  if (typeof k !== typeof o) {
    report(p, `type mismatch: kessel=${typeof k} oxc=${typeof o}`);
    return;
  }
  if (typeof k !== 'object') {
    if (k !== o) report(p, `kessel=${JSON.stringify(k)} oxc=${JSON.stringify(o)}`);
    return;
  }
  if (Array.isArray(k) !== Array.isArray(o)) {
    report(p, `one side is array: kessel=${Array.isArray(k)} oxc=${Array.isArray(o)}`);
    return;
  }
  if (Array.isArray(k)) {
    if (k.length !== o.length) {
      report(`${p}.length`, `kessel=${k.length} oxc=${o.length}`);
    }
    const n = Math.min(k.length, o.length);
    for (let i = 0; i < n; i++) compare(k[i], o[i], `${p}[${i}]`);
    return;
  }
  // Object. If either has `type`, record the coverage.
  if (typeof k.type === 'string') bump(k.type);
  // Field-by-field compare. Field order doesn't matter in JSON.
  const kKeys = Object.keys(k);
  const oKeys = Object.keys(o);
  const allKeys = new Set([...kKeys, ...oKeys]);
  for (const key of allKeys) {
    const hasK = key in k;
    const hasO = key in o;
    if (hasK && !hasO) {
      // Kessel has a field the reference doesn't. Position info is tolerated
      // (some references skip start/end); everything else is a potential drift.
      if (key !== 'start' && key !== 'end') {
        report(`${p}.${key}`, `kessel has field "${key}" that ${PARSER} does not (extra)`);
      }
    } else if (!hasK && hasO) {
      report(`${p}.${key}`, `kessel missing field "${key}" (${PARSER} has ${JSON.stringify(o[key])?.slice(0, 60)})`);
    } else {
      compare(k[key], o[key], `${p}.${key}`);
    }
  }
}

compare(kTree, oTree, 'program');

console.log(`Verifying: ${name} (${source.length} bytes)`);
const types = [...typesSeen.entries()].sort((a, b) => b[1] - a[1]);
console.log(`  Node types compared: ${types.length}`);
for (const [t, c] of types.slice(0, 10)) console.log(`    ${t}: ${c}`);
if (types.length > 10) console.log(`    ... ${types.length - 10} more types`);
if (errors === 0) {
  console.log(`  ✅ Deep JSON compare passes vs ${PARSER}`);
  process.exit(0);
} else {
  console.log(`  ❌ ${errors} divergence(s) vs ${PARSER} (showing first ${Math.min(errors, LIMIT)})`);
  process.exit(1);
}
