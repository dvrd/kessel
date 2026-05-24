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
   * Byte offset into the source where the error span starts.
   *
   * Computed in UTF-8 bytes by the Odin parser. For source containing
   * characters outside the Basic Multilingual Plane, this may differ
   * from a JS string index by 1 or more positions per non-BMP character.
   */
  start: number;
  /**
   * Byte offset where the error span ends (exclusive). For errors
   * reported at the current token, `end` is the byte after the last
   * character of that token; renderers can underline `[start, end)` to
   * highlight the entire offending range instead of a single caret.
   * For diagnostics reported at a known single point (some legacy call
   * sites and lexer-side errors), `end === start`.
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
 * JSON, no async boundary. Blocks the Node event loop for the duration
 * of the parse — use {@link parseAsync} when that matters (long parses,
 * concurrent fan-out, server request handlers).
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

/**
 * Asynchronously parse `source` on a libuv worker thread and return an
 * ESTree-compatible AST.
 *
 * Same signature and return shape as {@link parseSync}, but the native
 * parse runs off the Node main thread via koffi's `.async()`. The event
 * loop stays responsive during the parse and concurrent calls fan out
 * across libuv's worker pool (default 4 threads; raise with the
 * `UV_THREADPOOL_SIZE` environment variable for more parallelism).
 *
 * Throughput notes:
 *  - One-shot parseAsync is marginally slower than parseSync because of
 *    a small thread-handoff overhead (~10-50µs).
 *  - For N concurrent parses on M-core hosts, parseAsync scales close to
 *    `min(N, UV_THREADPOOL_SIZE)` until the pool saturates.
 *  - The post-parse JS work (binary AST decode + error enrichment) still
 *    runs on the awaiting thread; only the native parse itself is
 *    offloaded.
 *
 * @param filename Path or synthetic name. Drives language detection
 *                 unless overridden by `options.lang`.
 * @param source   UTF-8 source code to parse.
 * @param options  Optional parse options.
 */
export function parseAsync(
  filename: string,
  source: string,
  options?: ParseOptions
): Promise<ParseResult>;
