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

/** Initial source type used by module/script-sensitive grammar. */
export type SourceType = 'script' | 'module' | 'unambiguous';

/**
 * Parse depth exposed by the npm binding.
 *
 * - `'ast'` is the fast default and matches the historical npm path:
 *   build the AST and return syntax diagnostics only.
 * - `'parse'` enables parser-owned scope and early-error checks.
 * - `'full'` also runs kessel's semantic checker and returns those
 *   diagnostics in the same `errors` array.
 */
export type ParseMode = 'ast' | 'parse' | 'full';

/**
 * Diagnostic severity.
 *
 * Today every diagnostic kessel emits is `'error'`; `'warning'` is
 * reserved for future opt-in lints (empty block, unreachable code,
 * sketchy regex patterns, `with` outside strict mode). The substrate
 * already supports it — see the `Severity` enum in `src/diagnostic.odin`.
 */
export type Severity = 'error' | 'warning';

/**
 * Stable, machine-readable identifier for a diagnostic, formatted
 * `K####` with a zero-padded numeric body.
 *
 * Numeric ranges:
 *  - `K1xxx` — lexer (invalid numeric literal, bad escape, etc.)
 *  - `K2xxx` — parser syntax (expected token, unexpected token, etc.)
 *  - `K3xxx` — ECMA-262 early errors (await/yield context, strict mode,
 *              duplicate keys, etc.)
 *  - `K4xxx` — TypeScript parser-level rules (modifier order, ambient
 *              context, overload chains, etc.)
 *
 * Codes are stable across releases — once published, the numeric body
 * never changes meaning. Tooling can safely match on them for
 * suppression, grouping, or editor squigglies. See `docs/diagnostics.md`
 * for the full catalogue.
 */
export type ErrorCode = `K${number}`;

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
  /**
   * Stable error code of the form `K####`. Present on every diagnostic
   * produced by a migrated call site (the vast majority since the
   * Phase 5 diagnostic rebuild). Absent on a handful of legacy /
   * un-migrated sites — consumers should treat absence as `undefined`,
   * not as a specific code.
   *
   * See {@link ErrorCode} for the numeric-range layout and
   * `docs/diagnostics.md` for the full catalogue.
   */
  code?: ErrorCode;
  /**
   * Severity of the diagnostic. Present on every diagnostic that has
   * a {@link code}; absent on the same legacy sites that omit `code`.
   *
   * Today every emitted diagnostic is `'error'`. `'warning'` is
   * reserved for future opt-in lints — see {@link Severity}.
   */
  severity?: Severity;
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
  /**
   * Force script or module parsing. The default `'unambiguous'` starts
   * as script and lets the parser promote to module on module syntax.
   */
  sourceType?: SourceType;
  /**
   * Refuse automatic script-to-module promotion when `sourceType` is
   * omitted or `'unambiguous'`.
   */
  strictSourceType?: boolean;
  /** Start in strict mode regardless of a directive prologue. */
  forceStrict?: boolean;
  /** Preserve parenthesized expressions as explicit AST nodes. */
  preserveParens?: boolean;
  /** Select how much non-syntactic parser/checker work to run. */
  mode?: ParseMode;
  /** Alias for `mode: 'full'`; runs the semantic checker. */
  showSemanticErrors?: boolean;
  /** Override `.d.ts` detection for synthetic filenames. */
  sourceIsDts?: boolean;
  /** Override CommonJS detection for synthetic filenames. */
  commonjs?: boolean;
  /** Match Babel's `disallowAmbiguousJSXLike` parser option. */
  disallowAmbiguousJSXLike?: boolean;
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
 * Asynchronously parse source off the calling thread and return an
 * ESTree-compatible AST. Uses libuv or a dedicated Node worker depending
 * on Koffi's stack configuration.
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

export interface CodegenOptions {
  filename?: string;
  lang?: Lang;
  sourceType?: Exclude<SourceType, 'unambiguous'>;
  minified?: boolean;
  sourceMap?: boolean;
}

export interface SourceMap {
  version: 3;
  file: string;
  sourceRoot: string;
  sources: string[];
  names: string[];
  sourcesContent?: string[];
  mappings: string;
}

export interface CodegenResult {
  code: string;
  map: SourceMap | null;
  errors: Array<{ message: string }>;
}

/** Print source from the parsed AST and optionally return a version 3 source map. */
export function codegen(source: string, options?: CodegenOptions): CodegenResult;

export interface LintOptions {
  lang?: Lang;
  rules?: Record<string, 'off' | 'warn' | 'error'>;
}

export interface LintDiagnostic extends Omit<ParseError, 'code' | 'severity'> {
  code: ErrorCode | `L${number}` | '';
  severity: Severity;
}

/** Run the built-in lint rules and return diagnostics with UTF-8 byte offsets. */
export function lintSync(
  filename: string,
  source: string,
  options?: LintOptions
): { diagnostics: LintDiagnostic[] };
