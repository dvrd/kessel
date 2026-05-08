#!/usr/bin/env node
// Conformance summary — reads the 10 committed snap files and prints
// a human-readable summary.
'use strict';
const fs = require('fs');
const path = require('path');

const SNAP_DIR = path.resolve(__dirname, '../coverage/snapshots');
const JSON_MODE = process.argv.includes('--json');

function parseSummary(content) {
  const lines = content.split('\n');
  const si = lines.findIndex(l => l.includes(' Summary:'));
  if (si < 0) return null;
  const m = lines[si].match(/^(\w+)_(\w+) Summary:/);
  if (!m) return null;
  const out = { tool: m[1], suite: m[2] };
  for (let i = si + 1; i < lines.length; i++) {
    const l = lines[i].trim(); if (!l) continue;
    let mm = l.match(/^AST Parsed\s*:\s*(\d+)\/(\d+)\s*\(([\d.]+)%\)/);
    if (mm) { out.astParsed = +mm[1]; out.astTotal = +mm[2]; out.astPct = +mm[3]; continue; }
    mm = l.match(/^Positive Passed:\s*(\d+)\/(\d+)\s*\(([\d.]+)%\)/);
    if (mm) { out.posPassed = +mm[1]; out.posTotal = +mm[2]; out.posPct = +mm[3]; continue; }
    mm = l.match(/^Negative Passed:\s*(\d+)\/(\d+)\s*\(([\d.]+)%\)/);
    if (mm) { out.negPassed = +mm[1]; out.negTotal = +mm[2]; out.negPct = +mm[3]; continue; }
    if (l.startsWith('Expect ') || (l.includes(':') && !l.includes('Passed:'))) break;
  }
  return out;
}

function load() {
  if (!fs.existsSync(SNAP_DIR)) { console.error('No snapshots found. Run task test first.'); return []; }
  const snaps = [];
  for (const e of fs.readdirSync(SNAP_DIR, { withFileTypes: true }).sort((a,b) => a.name.localeCompare(b.name))) {
    if (!e.isFile() || !e.name.endsWith('.snap')) continue;
    const s = parseSummary(fs.readFileSync(path.join(SNAP_DIR, e.name), 'utf8'));
    if (s) { s.file = e.name; snaps.push(s); }
  }
  return snaps;
}

function pct(n,d) { return d === 0 ? 'N/A' : (n/d*100).toFixed(2)+'%'; }

function human(snaps) {
  const by = {};
  for (const s of snaps) { if (!by[s.suite]) by[s.suite] = {}; by[s.suite][s.tool] = s; }
  const order = ['test262', 'babel', 'typescript', 'estree', 'misc'];
  const labels = { test262:'ES2025 Conformance (test262)', babel:'Babel Corpus', typescript:'TypeScript Corpus', estree:'ESTree Conformance', misc:'Misc Regression Museum' };
  console.log('Kessel Conformance Summary\n==========================\n');
  for (const suite of order) {
    const e = by[suite]; if (!e) continue;
    console.log((labels[suite]||suite)+':');
    for (const tool of ['parser', 'semantic']) {
      const s = e[tool]; if (!s) continue;
      const pos = s.posPassed !== undefined ? s.posPassed+'/'+s.posTotal+' ('+pct(s.posPassed,s.posTotal)+')' : (s.astParsed||0)+'/'+(s.astTotal||0)+' ('+pct(s.astParsed||0,s.astTotal||0)+')';
      const neg = s.negTotal > 0 ? '  |  negative '+s.negPassed+'/'+s.negTotal+' ('+pct(s.negPassed,s.negTotal)+')' : '';
      console.log('  '+tool.charAt(0).toUpperCase()+tool.slice(1)+':     '+pos+' positive'+neg);
    }
    console.log('');
  }
}

const snaps = load();
if (snaps.length === 0) process.exit(1);
JSON_MODE ? console.log(JSON.stringify(snaps,null,2)) : human(snaps);
