/**
 * format.js — render a ParseError as a human-readable codeframe.
 *
 * Separate subpath so callers that don't need rendered output (e.g.
 * tools that serialize errors as JSON) don't pay for the helper.
 *
 * Output shape:
 *
 *   app.tsx:3:14: Unterminated string literal
 *     2 | function greet() {
 *     3 |   return "hello
 *       |                ^
 *     4 | }
 */

'use strict';

/**
 * Render a single ParseError with one line of context above and below
 * (when available) and a caret under the error column.
 *
 * @param {object} error   ParseError with { message, filename, line, column }.
 * @param {string} source  The original source string passed to parseSync.
 * @returns {string}       Multi-line rendered codeframe.
 */
function formatError(error, source) {
  const { message, filename, line, column } = error;
  const lines = source.split('\n');

  // Header — VSCode / clang style so editors can click through.
  const header = `${filename}:${line}:${column}: ${message}`;

  // Gutter width scales with line-number magnitude.
  const lastLineNum = Math.min(line + 1, lines.length);
  const gutterWidth = String(lastLineNum).length;
  const gutter = (n) => String(n).padStart(gutterWidth) + ' | ';
  const blankGutter = ' '.repeat(gutterWidth) + ' | ';

  const out = [header];
  if (line > 1) out.push(gutter(line - 1) + (lines[line - 2] ?? ''));
  out.push(gutter(line) + (lines[line - 1] ?? ''));
  // Caret: column is 1-based, so column-1 spaces before the ^.
  out.push(blankGutter + ' '.repeat(Math.max(0, column - 1)) + '^');
  if (line < lines.length) out.push(gutter(line + 1) + (lines[line] ?? ''));

  return out.join('\n');
}

module.exports = { formatError };
