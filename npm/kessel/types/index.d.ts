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

/** The `#!...` line a script can start with, as on `Program.hashbang`. */
export interface Hashbang {
  type: 'Hashbang';
  /** The text after `#!`, up to the line terminator. */
  value: string;
  start: number;
  end: number;
}

/** Result envelope returned by {@link parseSync}. */
export interface ParseResult {
  /**
   * The ESTree-compatible AST. Typed as the standard `Program` from
   * `@types/estree`; runtime nodes may include TS- or JSX-specific types
   * that aren't part of that spec (narrow via `node.type`).
   *
   * `hashbang` is `null` unless the source starts with `#!`.
   */
  program: Program & { hashbang: Hashbang | null };
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

export interface FormatOptions {
  printWidth?: number;
  /** Indentation width in columns, from 0 to 16. */
  tabWidth?: number;
  useTabs?: boolean;
  singleQuote?: boolean;
  bracketSpacing?: boolean;
  trailingComma?: 'all' | 'es5' | 'none';
  /** Line ending for newly printed module declarations. */
  endOfLine?: 'lf' | 'crlf' | 'cr' | 'auto';
}

/** Emit a declaration file from one TypeScript source. Diagnostic spans use UTF-8 byte offsets. */
export function isolatedDeclarationSync(filename: string, source: string): {
  output: string;
  errors: { code: string; message: string; start: number; end: number }[];
};

/** Format module declarations and object or array data in variable declarations and default exports. Throws SyntaxError with a UTF-8 byte offset on parse failure. */
export function formatSync(filename: string, source: string, options?: FormatOptions): string;

export interface TransformOptions {
  /** Replace global expressions after TypeScript and JSX lowering. */
  define?: Record<string, string>;
  typescript?: { optimizeConstEnums?: boolean };
  explicitResourceManagement?: boolean;
  jsx?: 'preserve' | 'classic' | 'automatic' | {
    runtime: 'classic';
    pragma?: string;
    pragmaFrag?: string;
    development?: boolean;
    pure?: boolean;
    throwIfNamespace?: boolean;
    refresh?: boolean | ReactRefreshOptions;
  } | {
    runtime: 'automatic';
    importSource?: string;
    development?: boolean;
    pure?: boolean;
    throwIfNamespace?: boolean;
    refresh?: boolean | ReactRefreshOptions;
  };
  /**
   * Lower syntax newer than this ECMAScript edition: exponentiation, optional catch binding,
   * optional chaining, nullish coalescing, logical assignment and numeric separators.
   * Newer syntax with no lowering is reported in `errors`. Defaults to 'esnext'.
   */
  target?: 'es2015' | 'es2016' | 'es2017' | 'es2018' | 'es2019' | 'es2020' | 'es2021' | 'es2022' | 'es2023' | 'es2024' | 'esnext';
  /** Lower TypeScript experimental decorators. Without `legacy`, decorators are printed as written. */
  decorator?: { legacy?: boolean; emitDecoratorMetadata?: boolean };
  minified?: boolean;
  sourceMap?: boolean;
}

/** React Fast Refresh registration and Hook signatures. */
export interface ReactRefreshOptions {
  /** Runtime registration function. Defaults to `$RefreshReg$`. */
  refreshReg?: string;
  /** Runtime signature factory. Defaults to `$RefreshSig$`. */
  refreshSig?: string;
  /** Emit the readable Hook signature instead of its SHA-1 digest. */
  emitFullSignatures?: boolean;
}

export interface GeneratedCode {
  code: string;
  map: SourceMap | null;
  errors: Array<{ start: number; end: number; message: string }>;
}

/** Lower TypeScript and optionally JSX. Diagnostic spans use UTF-8 byte offsets. */
export function transformSync(filename: string, source: string, options?: TransformOptions): GeneratedCode;

export interface MinifyOptions {
  compress?: boolean;
  mangle?: boolean;
  /** Factory and fragment bindings supplied by the downstream JSX transform. */
  jsx?: { pragma?: string; pragmaFrag?: string };
  sourceMap?: boolean;
}

/** Compress source and shorten local JS and JSX bindings. Diagnostic spans use UTF-8 byte offsets. */
export function minifySync(filename: string, source: string, options?: MinifyOptions): GeneratedCode;

export type LintLevel = 'off' | 'allow' | 'warn' | 'error' | 'deny' | 0 | 1 | 2;
type LintSeveritySetting = LintLevel | readonly [LintLevel];
type LintGetterSetting = readonly [LintLevel, { allowImplicit?: boolean }];
type LintFallthroughSetting = readonly [LintLevel, {
  allowEmptyCase?: boolean;
  commentPattern?: string | null;
  reportUnusedFallthroughComment?: boolean;
}];
type LintPreferConstSetting = readonly [LintLevel, { destructuring?: 'any' | 'all'; ignoreReadBeforeAssign?: boolean }];
type LintConsoleSetting = readonly [LintLevel, { allow?: readonly string[] }];
type LintHookSetting = readonly [LintLevel, { additionalHooks?: string }];
type LintEqualitySetting =
  readonly [LintLevel, 'always' | 'smart' | 'allow-null', { null?: 'always' | 'ignore' | 'never' }?];
export type LintRuleSetting = LintSeveritySetting | LintEqualitySetting | LintPreferConstSetting | LintGetterSetting | LintFallthroughSetting | LintConsoleSetting | LintHookSetting;

export interface LintOptions {
  /** Resolve project config, overrides and ignores from this absolute directory. */
  workspaceRoot?: string;
  /** Attach individual safe edits to diagnostics for the returned revision. */
  includeFixes?: boolean;
  /** Attach optional edits for manual selection. Hook dependency edits can change when effects run. */
  includeSuggestions?: boolean;
  /** Include the registered rule name and an available line directive edit for lint diagnostics. */
  includeSuppressions?: boolean;
  fix?: boolean;
  fixSuggestions?: boolean;
  fixDangerously?: boolean;
  lang?: Lang;
  reportUnusedDisableDirectives?: 'off' | 'warn' | 'error';
  rules?: Record<string, LintRuleSetting> & {
    eqeqeq?: LintSeveritySetting | LintEqualitySetting;
    'prefer-const'?: LintSeveritySetting | LintPreferConstSetting;
    'getter-return'?: LintSeveritySetting | LintGetterSetting;
    'no-fallthrough'?: LintSeveritySetting | LintFallthroughSetting;
    'no-console'?: LintSeveritySetting | LintConsoleSetting;
    'exhaustive-deps'?: LintSeveritySetting | LintHookSetting;
    'react/exhaustive-deps'?: LintSeveritySetting | LintHookSetting;
    'react-hooks/exhaustive-deps'?: LintSeveritySetting | LintHookSetting;
  };
}

export interface LintDiagnostic extends Omit<ParseError, 'code' | 'severity'> {
  /** Locations of captured values when project diagnostics report a missing Hook dependency. */
  related?: Array<ByteSpan & { message: string }>;
  suppression?: { rule: string; line?: ByteSpan & { text: string } };
  code: ErrorCode | `L${number}` | '';
  severity: Severity;
  /** UTF-8 byte offsets into the linted source and the replacement text. */
  fix?: ByteSpan & { text: string };
  suggestion?: ByteSpan & { text: string; title: string };
}

/** Run the built-in lint rules and return diagnostics with UTF-8 byte offsets. */
export function lintSync(
  filename: string,
  source: string,
  options?: LintOptions
): { diagnostics: LintDiagnostic[]; output?: string };

/** A closed-open range measured in UTF-8 bytes. */
export interface ByteSpan {
  start: number;
  end: number;
}

export interface ModuleDependency {
  kind: 'Static' | 'Reexport' | 'Dynamic' | 'Import_Meta' | 'Import_Equals';
  phase: 'Evaluation' | 'Source' | 'Defer';
  statement: ByteSpan;
  request: ByteSpan;
  attributes: ByteSpan | null;
  name: string | null;
  type_only: boolean;
}

export interface ModuleExport {
  name: string;
  span: ByteSpan;
  local_name: string | null;
  local_span: ByteSpan | null;
  type_only: boolean;
}

export interface ModuleScanResult {
  dependencies: ModuleDependency[];
  exports: ModuleExport[];
  has_module_syntax: boolean;
}

/** Scan module syntax and bindings without building a JavaScript AST. */
export function scanModuleSync(source: string): ModuleScanResult;

export type RegExpNodeKind =
  | 'Pattern' | 'Alternative' | 'Group' | 'Character_Class' | 'Character' | 'Dot'
  | 'Start_Assertion' | 'End_Assertion' | 'Boundary_Assertion'
  | 'Character_Class_Escape' | 'Property_Escape' | 'Escape' | 'Indexed_Reference'
  | 'Named_Reference' | 'Quantifier' | 'Class_Range' | 'Class_Intersection'
  | 'Class_Subtraction' | 'Class_String';

export interface RegExpRepeatBound {
  /** Use the pattern slice in digits for values above Number.MAX_SAFE_INTEGER. */
  value: number;
  digits: ByteSpan;
  overflow: boolean;
}

export interface RegExpNode {
  kind: RegExpNodeKind;
  span: ByteSpan;
  first_child: number;
  next_sibling: number;
  group_kind: 'Capture' | 'Named_Capture' | 'Noncapturing' |
    'Lookahead' | 'Negative_Lookahead' | 'Lookbehind' | 'Negative_Lookbehind' | 'Modifiers';
  capture_index: number;
  name: ByteSpan;
  property_value: ByteSpan | null;
  /** A Unicode code point in u/v mode, otherwise a UTF-16 code unit. */
  code_point: number | null;
  negative: boolean;
  may_contain_strings: boolean;
  repeat: {
    min: RegExpRepeatBound;
    max: RegExpRepeatBound | null;
    greedy: boolean;
  };
}

export interface RegExpTree {
  nodes: RegExpNode[];
  /** Node index zero is reserved for absent links. */
  root: number;
  /** Bit mask in d, g, i, m, s, u, v, y order, from low to high. */
  flags: number;
  capture_count: number;
  has_named_captures: boolean;
}

/** Parse a regexp pattern without slash delimiters. Syntax errors carry a byte offset. */
export function parseRegExpSync(pattern: string, flags?: string): RegExpTree;

export interface ModuleResolveOptions {
  mode?: 'import' | 'require';
  tsconfig?: string;
  browser?: boolean;
  preserveSymlinks?: boolean;
  /** Ordered legacy package entry fields. An empty list goes straight to directory entry names. */
  mainFields?: string | readonly string[];
  /** Manifest fields for package exports. Nested arrays name a path through JSON objects. */
  exportsFields?: readonly (string | readonly string[])[];
  /** Manifest fields for private imports, searched in order. */
  importsFields?: readonly (string | readonly string[])[];
  /** Package directories in search order. Relative entries are searched up the importer ancestry. */
  modules?: string | readonly string[];
  /** Suffixes for implicit lookup, in order. Defaults to ['.js', '.json', '.node']. */
  extensions?: readonly string[];
  /** Replace an explicit filename suffix with candidate suffixes in order. */
  extensionAlias?: Readonly<Record<string, readonly string[]>>;
  /** Directory entry names, in order. Defaults to ['index']. */
  mainFiles?: readonly string[];
  conditions?: readonly string[];
  aliases?: readonly { name: string; target: string; exact?: boolean }[];
}

export type ModuleResolution =
  | { kind: 'file' | 'builtin'; path: string }
  | { kind: 'ignored'; path: '' };

/** Resolve a module from the given importing file. Errors include a code. */
export function resolveModuleSync(
  specifier: string,
  importer: string,
  options?: ModuleResolveOptions
): ModuleResolution;
