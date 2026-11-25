'use strict';

const path = require('node:path');
const { formatSync } = require('../index');

// The line diff gives up beyond this many inserted plus deleted lines and
// reports the changed region as one edit. The search costs O(lines * edits)
// time and O(edits^2) memory (about 4 MB at the bound), which keeps a
// completely reformatted bundle from stalling the editor.
const DIFF_EDITS_MAX = 1024;

// Offsets where lines begin, using the same terminators as DocumentText: LF,
// CRLF and a lone CR. A final entry holds the text length, so line `i` is
// `text.slice(starts[i], starts[i + 1])` and keeps its terminator.
function lineStarts(text) {
  const starts = [0];
  for (let offset = 0; offset < text.length; offset++) {
    const unit = text.charCodeAt(offset);
    if (unit === 10 || (unit === 13 && text.charCodeAt(offset + 1) !== 10)) starts.push(offset + 1);
  }
  if (starts[starts.length - 1] !== text.length) starts.push(text.length);
  return starts;
}

// Give equal lines equal numbers so the diff compares integers.
function internLines(text, starts, ids) {
  const lines = new Int32Array(starts.length - 1);
  for (let index = 0; index < lines.length; index++) {
    const line = text.slice(starts[index], starts[index + 1]);
    let id = ids.get(line);
    if (id === undefined) { id = ids.size; ids.set(line, id); }
    lines[index] = id;
  }
  return lines;
}

// Myers' greedy search for a shortest edit script between two line lists.
// `reach[max + k + 1]` is the furthest source line reached on diagonal k.
// Returns one snapshot of that table per round, which is what walking the
// script backwards needs, or null when the script exceeds DIFF_EDITS_MAX.
function shortestEditTrace(a, b) {
  const max = Math.min(a.length + b.length, DIFF_EDITS_MAX);
  const reach = new Int32Array(2 * max + 3);
  const trace = [];
  for (let edits = 0; edits <= max; edits++) {
    // Diagonals -edits - 1 through edits + 1 are all a round reads or writes.
    trace.push(reach.slice(max - edits, max + edits + 3));
    for (let k = -edits; k <= edits; k += 2) {
      const down = k === -edits || (k !== edits && reach[max + k] < reach[max + k + 2]);
      let x = down ? reach[max + k + 2] : reach[max + k] + 1;
      let y = x - k;
      while (x < a.length && y < b.length && a[x] === b[y]) { x++; y++; }
      reach[max + k + 1] = x;
      if (x >= a.length && y >= b.length) return trace;
    }
  }
  return null;
}

// Walk the edit script backwards and mark the lines it keeps.
function keptLines(a, b, trace) {
  const keptA = new Uint8Array(a.length), keptB = new Uint8Array(b.length);
  let x = a.length, y = b.length;
  for (let edits = trace.length - 1; edits >= 0; edits--) {
    const snapshot = trace[edits];
    const before = k => snapshot[k + edits + 1];
    const k = x - y;
    let previousX = 0, previousY = 0, snakeX = 0;
    if (edits > 0) {
      const down = k === -edits || (k !== edits && before(k - 1) < before(k + 1));
      previousX = down ? before(k + 1) : before(k - 1);
      previousY = previousX - (down ? k + 1 : k - 1);
      snakeX = down ? previousX : previousX + 1;
    }
    while (x > snakeX) { x--; y--; keptA[x] = 1; keptB[y] = 1; }
    x = previousX;
    y = previousY;
  }
  return { keptA, keptB };
}

// Maximal runs of changed lines as [sourceStart, sourceEnd, outputStart, outputEnd].
function changedRuns(a, b) {
  let head = 0;
  while (head < a.length && head < b.length && a[head] === b[head]) head++;
  let tailA = a.length, tailB = b.length;
  while (tailA > head && tailB > head && a[tailA - 1] === b[tailB - 1]) { tailA--; tailB--; }
  if (head === tailA && head === tailB) return [];
  const middleA = a.subarray(head, tailA), middleB = b.subarray(head, tailB);
  const trace = shortestEditTrace(middleA, middleB);
  if (!trace) return [[head, tailA, head, tailB]];
  const { keptA, keptB } = keptLines(middleA, middleB, trace);
  const runs = [];
  for (let i = 0, j = 0; i < middleA.length || j < middleB.length;) {
    if (i < middleA.length && j < middleB.length && keptA[i] && keptB[j]) { i++; j++; continue; }
    const run = [head + i, 0, head + j, 0];
    while (i < middleA.length && !keptA[i]) i++;
    while (j < middleB.length && !keptB[j]) j++;
    run[1] = head + i;
    run[3] = head + j;
    runs.push(run);
  }
  return runs;
}

// Edits bounded by complete lines, one per changed run, so clients keep the
// surrounding selections, unchanged lines are never rewritten, and no range
// starts inside a surrogate pair or a CRLF.
function lineEdits(source, output) {
  if (source === output) return [];
  const sourceStarts = lineStarts(source), outputStarts = lineStarts(output);
  const ids = new Map();
  const sourceLines = internLines(source, sourceStarts, ids);
  const outputLines = internLines(output, outputStarts, ids);
  return changedRuns(sourceLines, outputLines).map(([fromLine, toLine, outputFrom, outputTo]) => ({
    lines: [fromLine, toLine],
    start: sourceStarts[fromLine], end: sourceStarts[toLine],
    newText: output.slice(outputStarts[outputFrom], outputStarts[outputTo]),
  }));
}

function protocolEdit(content, edit) {
  return {
    range: { start: content.position(edit.start), end: content.position(edit.end) },
    newText: edit.newText,
  };
}

function applyEdits(source, edits) {
  let text = '', consumed = 0;
  for (const edit of edits) {
    text += source.slice(consumed, edit.start) + edit.newText;
    consumed = edit.end;
  }
  return text + source.slice(consumed);
}

// Lines the request covers, as a half-open interval. A selection that ends at
// column zero does not include that last line, which is how editors report a
// selection of whole lines.
function requestedLines(content, range) {
  const start = content.position(content.offset(range.start));
  const end = content.position(content.offset(range.end));
  if (end.line < start.line || (end.line === start.line && end.character < start.character)) {
    throw new Error('Invalid formatting range');
  }
  const wholeLines = end.character === 0 && end.line > start.line;
  return [start.line, wholeLines ? end.line : end.line + 1];
}

function formatted(doc, filename, options, formatSource) {
  if (!Number.isInteger(options?.tabSize) || typeof options.insertSpaces !== 'boolean') {
    throw new TypeError('Formatting requires an integer tabSize and a boolean insertSpaces');
  }
  const suffix = path.extname(filename ?? '').slice(1).replace(/^[cm](js|ts)$/, '$1');
  const label = suffix === doc.lang ? filename : 'document.' + doc.lang;
  const settings = { tabWidth: options.tabSize, useTabs: !options.insertSpaces, endOfLine: 'auto' };
  const format = text => formatSource(label, text, settings);
  try {
    return { output: format(doc.content.text), format };
  } catch (error) {
    // A buffer that does not parse is left alone; its diagnostics say why.
    if (error.code === 'Invalid_Syntax') return null;
    throw error;
  }
}

function formatDocument(doc, filename, options, formatSource = formatSync) {
  if (!doc) return [];
  const result = formatted(doc, filename, options, formatSource);
  if (!result) return [];
  return lineEdits(doc.content.text, result.output).map(edit => protocolEdit(doc.content, edit));
}

// The formatter works on whole programs, so a range request formats the
// document and keeps the changed runs that touch the requested lines. Mixing
// formatted and original lines is only returned when formatting that mixture
// gives the fully formatted document: a kept run then cannot have changed
// what the remaining lines mean. `formatSource` is a parameter so that the
// check can be exercised with a formatter that lacks that property.
function formatRange(doc, filename, range, options, formatSource = formatSync) {
  if (!doc) return [];
  const [firstLine, lineLimit] = requestedLines(doc.content, range);
  const result = formatted(doc, filename, options, formatSource);
  if (!result) return [];
  const edits = lineEdits(doc.content.text, result.output);
  const selected = edits.filter(({ lines: [fromLine, toLine] }) => fromLine === toLine
    ? firstLine <= fromLine && fromLine <= lineLimit
    : fromLine < lineLimit && firstLine < toLine);
  if (selected.length !== 0 && selected.length !== edits.length) {
    let settled;
    try { settled = result.format(applyEdits(doc.content.text, selected)); } catch { return []; }
    if (settled !== result.output) return [];
  }
  return selected.map(edit => protocolEdit(doc.content, edit));
}

module.exports = { formatDocument, formatRange };
