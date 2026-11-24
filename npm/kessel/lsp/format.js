'use strict';

const path = require('node:path');
const { formatSync } = require('../index');

// Return one edit bounded by complete lines so clients keep the surrounding
// selections and never receive a range inside a surrogate pair or CRLF.
function changedLines(content, output) {
  const source = content.text;
  if (source === output) return [];
  let prefix = 0;
  const limit = Math.min(source.length, output.length);
  while (prefix < limit && source.charCodeAt(prefix) === output.charCodeAt(prefix)) prefix++;
  const start = content.lines[content.position(prefix).line];
  let end = source.length, outputEnd = output.length;
  while (end > start && outputEnd > start && source.charCodeAt(end - 1) === output.charCodeAt(outputEnd - 1)) {
    end--;
    outputEnd--;
  }
  const line = content.position(end).line;
  const boundary = end === content.lines[line] ? end : content.lines[line + 1] ?? source.length;
  return [{
    range: { start: content.position(start), end: content.position(boundary) },
    newText: output.slice(start, outputEnd + boundary - end),
  }];
}

function formatDocument(doc, filename, options) {
  if (!doc) return [];
  if (!Number.isInteger(options?.tabSize) || typeof options.insertSpaces !== 'boolean') {
    throw new TypeError('Formatting requires an integer tabSize and a boolean insertSpaces');
  }
  const suffix = path.extname(filename ?? '').slice(1).replace(/^[cm](js|ts)$/, '$1');
  const label = suffix === doc.lang ? filename : 'document.' + doc.lang;
  const source = doc.content.text;
  let output;
  try {
    output = formatSync(label, source, { tabWidth: options.tabSize, useTabs: !options.insertSpaces, endOfLine: 'auto' });
  } catch (error) {
    if (error.code === 'Invalid_Syntax') return [];
    throw error;
  }
  return changedLines(doc.content, output);
}

module.exports = { formatDocument };
