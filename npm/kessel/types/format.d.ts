/**
 * Codeframe renderer for ParseError.
 *
 * Separate subpath (`@dvrdlibs/kessel/format`) so consumers that
 * serialize errors as JSON don't pull in the renderer.
 */

import type { ParseError } from './index';

/**
 * Render a single ParseError as a multi-line codeframe with one line of
 * context above and below the error (when available) and a caret under
 * the error column. Format mimics clang / VS Code's diagnostic style so
 * editors can click through `filename:line:column`.
 *
 * @param error  A `ParseError` returned by `parseSync`.
 * @param source The original source string passed to `parseSync`.
 * @returns      Multi-line rendered string.
 *
 * @example
 *   import { parseSync } from '@dvrdlibs/kessel';
 *   import { formatError } from '@dvrdlibs/kessel/format';
 *
 *   const { errors } = parseSync('app.tsx', src);
 *   errors.forEach(e => console.error(formatError(e, src)));
 */
export function formatError(error: ParseError, source: string): string;
