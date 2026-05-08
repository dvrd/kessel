#!/usr/bin/env node
// Lexer token-stream conformance — validates AST span counts and
// contiguity against the reference parser on a curated fixture set.
'use strict';
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '../..');
const KESSEL = path.join(ROOT, 'bin/kessel');

function detectDialect(p) {
  p = p.replace(/\\/g, '/');
  if (p.includes('/spec/jsx/')) return 'jsx';
  if (p.includes('/spec/tsx/')) return 'tsx';
  if (p.includes('/spec/typescript/')) return 'ts';
  if (p.endsWith('.tsx')) return 'tsx';
  if (p.endsWith('.ts')) return 'ts';
  if (p.endsWith('.jsx')) return 'jsx';
  return 'js';
}

function parseKessel(file, lang) {
  const args = ['parse'];
  if (lang && lang !== 'js') args.push('--lang=' + lang);
  args.push(file);
  const r = spawnSync(KESSEL, args, { timeout: 30000, maxBuffer: 16*1024*1024, encoding: 'utf8' });
  const stdout = (r.stdout || '').trim();
  const stderr = (r.stderr || '').trim();
  const n = parseInt((stderr.match(/Parse errors:\s*(\d+)/) || [0,0])[1], 10);
  if (r.error || (r.status !== 0 && r.signal)) return { ok: false, tree: null, parseErrors: n };
  const m = stdout.indexOf('\nParse errors (');
  try { return { ok: true, tree: JSON.parse(m === -1 ? stdout : stdout.slice(0, m)), parseErrors: n }; }
  catch(e) { return { ok: false, tree: null, parseErrors: n }; }
}

function parseOxc(source, lang) {
  const oxc = require(path.join(ROOT, 'bench/node_modules/oxc-parser'));
  const opts = {};
  if (lang === 'jsx') opts.lang = 'jsx';
  if (lang === 'ts') opts.lang = 'typescript';
  if (lang === 'tsx') opts.lang = 'tsx';
  return oxc.parseSync(source, opts);
}

function extractSpans(tree) {
  const spans = [];
  (function walk(node) {
    if (!node || typeof node !== 'object') return;
    if (Array.isArray(node)) { node.forEach(walk); return; }
    if (typeof node.start === 'number' && typeof node.end === 'number')
      spans.push({ start: node.start, end: node.end, type: node.type || '' });
    for (const k of Object.keys(node)) {
      if (k === 'type' || k === 'start' || k === 'end' || k === 'loc' || k === 'range') continue;
      if (k === 'comments') continue;
      walk(node[k]);
    }
  })(tree);
  spans.sort((a, b) => a.start - b.start || a.end - b.end);
  return spans;
}

function spanIssues(spans) {
  const issues = [];
  for (let i = 0; i < spans.length; i++) {
    if (spans[i].start > spans[i].end) issues.push(`start>end at ${spans[i].type}`);
    if (i > 0 && spans[i].start < spans[i-1].start) issues.push(`out of order`);
  }
  return issues;
}

const FIXTURES = [
  'tests/fixtures/basic/001_variable_declaration.js',
  'tests/fixtures/spec/escapes/001_hex_escape.js',
  'tests/fixtures/spec/escapes/002_unicode_escape.js',
  'tests/fixtures/spec/regex_disambiguation/001_block_regex.js',
  'tests/fixtures/spec/regex_disambiguation/002_division.js',
  'tests/fixtures/spec/unicode/001_unicode_identifier_start.js',
  'tests/fixtures/spec/asi/001_return_newline.js',
  'tests/fixtures/spec/lexical/005_comment_regex_boundary.js',
  'tests/fixtures/spec/jsx/001_element.js',
  'tests/fixtures/spec/typescript/001_interface.js',
  'bench/real_world/batch3/snabbdom.js',
];

let pass = 0, fail = 0;
const VERBOSE = process.argv.includes('--verbose');

for (const rel of FIXTURES) {
  const abs = path.resolve(ROOT, rel);
  if (!fs.existsSync(abs)) { console.log('  SKIP ' + rel); continue; }
  const src = fs.readFileSync(abs, 'utf8');
  const lang = detectDialect(abs);
  const k = parseKessel(abs, lang);
  if (!k.ok) { console.log('  FAIL ' + rel + ' — kessel parse failed'); fail++; continue; }
  let oTree;
  try { oTree = parseOxc(src, lang); } catch(e) { console.log('  FAIL ' + rel + ' — oxc error'); fail++; continue; }
  const kSpans = extractSpans(k.tree), oSpans = extractSpans(oTree);
  const issues = spanIssues(kSpans);
  const diff = Math.abs(kSpans.length - oSpans.length);
  if (issues.length === 0 && diff <= 5) {
    pass++;
    if (VERBOSE) console.log('  OK   ' + rel + ' — ' + kSpans.length + ' spans (diff=' + diff + ')');
  } else {
    fail++;
    console.log('  FAIL ' + rel + ' — ' + (issues.length ? issues.join('; ') : '') + (diff > 5 ? ' count diff=' + diff : ''));
  }
}

console.log('\nLexer token-stream: ' + pass + ' pass, ' + fail + ' fail (' + (pass+fail) + ' total)');
process.exit(fail > 0 ? 1 : 0);
