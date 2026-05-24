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
 * (when available) and a caret (or underline) under the error span.
 *
 * Uses the token-aware span `[start, end)` (binary format v3) to size
 * the marker: single-point reports (`end === start`) render as one
 * caret; token-spanning reports render as `^~~~~` covering the full
 * token width. The underline never spills onto adjacent lines — if
 * the span crosses a newline we truncate to the rest of the start line.
 *
 * @param {object} error   ParseError with { message, filename, line, column, start, end }.
 * @param {string} source  The original source string passed to parseSync.
 * @returns {string}       Multi-line rendered codeframe.
 */
function formatError(error, source) {
  const { message, filename, line, column, start = 0, end = 0 } = error;
  const lines = source.split('\n');

  // Header — VSCode / clang style so editors can click through.
  const header = `${filename}:${line}:${column}: ${message}`;

  // Gutter width scales with line-number magnitude.
  const lastLineNum = Math.min(line + 1, lines.length);
  const gutterWidth = String(lastLineNum).length;
  const gutter = (n) => String(n).padStart(gutterWidth) + ' | ';
  const blankGutter = ' '.repeat(gutterWidth) + ' | ';

  // Marker width: `end - start` in bytes, clamped to the remainder of
  // the start line so a multi-line span doesn't overflow the caret row.
  // Falls back to 1 (single caret) for single-point reports.
  const lineText = lines[line - 1] ?? '';
  const remainingOnLine = Math.max(0, lineText.length - (column - 1));
  const rawWidth = Math.max(1, Math.min(end - start, remainingOnLine));
  const marker = rawWidth <= 1 ? '^' : '^' + '~'.repeat(rawWidth - 1);

  const out = [header];
  if (line > 1) out.push(gutter(line - 1) + (lines[line - 2] ?? ''));
  out.push(gutter(line) + lineText);
  // Caret / underline: column is 1-based, so column-1 spaces before the marker.
  out.push(blankGutter + ' '.repeat(Math.max(0, column - 1)) + marker);
  if (line < lines.length) out.push(gutter(line + 1) + (lines[line] ?? ''));

  return out.join('\n');
}

module.exports = { formatError };
