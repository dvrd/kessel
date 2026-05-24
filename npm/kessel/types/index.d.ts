/**
 * TypeScript declarations for @dvrdlibs/kessel.
 *
 * The AST shape follows the ESTree spec for plain JavaScript fragments
 * (we reuse `@types/estree`'s `Program` node). When parsing TypeScript
 * or JSX, the runtime AST contains additional node types — `TSTypeAnnotation`,
 * `TSAsExpression`, `JSXElement`, decorators, etc. — that aren't in the
 * ESTree spec. Those nodes exist at runtime; narrow them with `node.type`
 * if you need to handle them in strongly-typed traversal.
 */

import type { Program } from 'estree';

/** Language grammar used by the parser. */
export type Lang = 'js' | 'jsx' | 'ts' | 'tsx';

/** A parse-time diagnostic. */
export interface ParseError {
  /** Human-readable error message. */
  message: string;
  /**
   * The filename passed to `parseSync`. Echoed verbatim so callers can
   * format errors as `filename:line:column` without threading the
   * filename through separately.
   */
  filename: string;
  /**
   * Byte offset into the source where the error was reported. The parser
   * tracks errors as single-point locations, so `start` and `end` are
   * currently the same value.
   *
   * Computed in UTF-8 bytes by the Odin parser. For source containing
   * characters outside the Basic Multilingual Plane, this may differ
   * from a JS string index by 1 or more positions per non-BMP character.
   */
  start: number;
  /**
   * End offset of the error span. Equals `start` until token-aware
   * spans land in a future release.
   */
  end: number;
  /** 1-based line number derived from `start`. */
  line: number;
  /** 1-based column number derived from `start`. */
  column: number;
}

/** Result envelope returned by {@link parseSync}. */
export interface ParseResult {
  /**
   * The ESTree-compatible AST. Typed as the standard `Program` from
   * `@types/estree`; runtime nodes may include TS- or JSX-specific types
   * that aren't part of that spec (narrow via `node.type`).
   */
  program: Program;
  /** Parse-time errors. Empty array on success. */
  errors: ParseError[];
}

/** Options accepted by {@link parseSync}. */
export interface ParseOptions {
  /**
   * Override the language detected from the filename extension.
   *
   * Default detection:
   * - `.js` / `.mjs` / `.cjs` → `'js'`
   * - `.jsx`                  → `'jsx'`
   * - `.ts` / `.mts` / `.cts` → `'ts'`
   * - `.tsx`                  → `'tsx'`
   */
  lang?: Lang;
}

/**
 * Synchronously parse `source` and return an ESTree-compatible AST.
 *
 * Goes through a single FFI call into `libkessel`; no subprocess, no
 * JSON, no async boundary. Safe to call from synchronous code paths.
 *
 * @param filename Path or synthetic name. Drives language detection
 *                 unless overridden by `options.lang`.
 * @param source   UTF-8 source code to parse.
 * @param options  Optional parse options.
 */
export function parseSync(
  filename: string,
  source: string,
  options?: ParseOptions
): ParseResult;
