# @dvrdlibs/kessel

JavaScript / TypeScript / JSX / TSX parser. Emits ESTree-compatible ASTs via a native shared library bound through [koffi](https://koffi.dev). Synchronous, in-process — no subprocess, no JSON serialization.

## Install

```bash
npm install @dvrdlibs/kessel
```

The package requires Node.js 18 or later. CommonJS and ESM can use the same
package exports. To deploy or roll back to a specific verified release, pin it
and commit the resulting lockfile:

```bash
npm install --save-exact @dvrdlibs/kessel@0.21.0
```

The install pulls only the platform-specific native binary that matches your host. The other sub-packages stay on the registry, unfetched.

TypeScript declarations ship inside the package under `types/` and are wired up via the `exports` map — no separate `@types/...` install needed.

| Sub-package | Platform | Binary |
|---|---|---|
| `@dvrdlibs/kessel-darwin-arm64` | macOS, Apple Silicon | `libkessel.dylib` |
| `@dvrdlibs/kessel-darwin-x64`   | macOS, Intel         | `libkessel.dylib` |
| `@dvrdlibs/kessel-linux-arm64`  | Linux, aarch64       | `libkessel.so`    |
| `@dvrdlibs/kessel-linux-x64`    | Linux, x86_64        | `libkessel.so`    |
| `@dvrdlibs/kessel-win32-x64`    | Windows, x86_64      | `libkessel.dll`   |


## Usage

```js
const { parseSync, parseAsync } = require('@dvrdlibs/kessel');

// Blocking — returns the result directly.
const { program, errors } = parseSync('app.js', 'const x = 1 + 2;');
console.log(program.body[0].type); // "VariableDeclaration"

// Non-blocking — native parse runs on a libuv worker thread, event
// loop stays responsive, concurrent calls fan out across the pool.
const { program: p2 } = await parseAsync('app.js', 'const y = 3 + 4;');
```

### Language detection

The filename extension determines the grammar:

| Extension | Grammar |
|---|---|
| `.js`, `.mjs`, `.cjs` | JavaScript |
| `.jsx` | JavaScript + JSX |
| `.ts`, `.mts`, `.cts` | TypeScript |
| `.tsx` | TypeScript + JSX |

The AST uses the ESTree `Program.sourceType` values `script` and `module`
for all extensions, including `.cjs` and `.cts`.

Override with the `lang` option:

```js
parseSync('file.js', source, { lang: 'tsx' });
```

Request stricter parser/checker work with `mode`:

```js
parseSync('file.ts', source, { mode: 'full', sourceType: 'module' });
```

### API

The parser returns an ESTree-compatible AST and diagnostics with UTF-8 byte
offsets. The package also exposes the experimental `codegen` printer and
`lintSync`, which checks source against Kessel's built-in rule set. The linter
honors `eslint-` and `oxlint-` directive comments. Pass
`{ reportUnusedDisableDirectives: "warn" }` to report unused comments or
rule names as `L9001`. The option also accepts `"off"` and `"error"`. Use
`{ rules: { eqeqeq: ["error", "smart"] } }` to allow loose comparisons of
like literals, `typeof` results, and null. With `"always"`, a third entry
can specify `{ null: "ignore" }` or `{ null: "never" }`. Diagnostics point
at the equality operator.

Use `{ rules: { "no-console": ["warn", { allow: ["warn", "error"] }] } }`
to report other statically named methods and properties on the global console.
The check respects local bindings and applies to reads, calls, and assignments.
With `fixSuggestions: true`, Kessel can remove a standalone call and its arguments.
Set `fixDangerously: true` as well to replace calls used as values with `void 0`.

The `getter-return` rule checks paths through conditionals, loops, switches
and exception handlers. It covers class and object getters and property
descriptors passed to the global `Object` and `Reflect` methods. Set
`["warn", { allowImplicit: true }]` to allow a bare `return`. Reaching the
end of the getter still produces a diagnostic. Kessel project configs can
check TypeScript getters. Oxlint configs delegate them to TypeScript.

`no-fallthrough` accepts a trailing `// falls through` or `/* fallthrough */`
before the next switch clause, including a comment inside the clause's sole
block. Set `commentPattern` to customize the case-insensitive pattern,
`allowEmptyCase` to permit blank lines between grouped labels, or
`reportUnusedFallthroughComment` to flag an annotation on a case that exits.
The native pattern matcher supports anchors, alternation, character classes
and repetition. It rejects Rust regex constructs such as scoped flag changes
and Unicode property escapes.

The `prefer-const` rule accepts `["warn", { destructuring: "all",
ignoreReadBeforeAssign: true }]`. With `fix: true`, the binding changes
the `let` keyword when all names in the declaration qualify.

Pass `{ fix: true }` to apply safe edits in memory. Use `fixSuggestions`
with unused-directive reporting to clean up suppressions, and
`fixDangerously` to allow changes to equality coercion. When an edit is
applied, `lintSync` returns the revised source in `output` and diagnostics
for that revision. A clean input returns only `diagnostics`.

Pass `{ includeSuppressions: true }` to get the registered rule name and
an available line directive edit in `diagnostic.suppression`. The edit uses
UTF-8 byte offsets. Parser errors and unused directives have no suppression action.

To preview safe edits, pass `{ includeFixes: true }`. Each fixable diagnostic
has a `fix` with `start` and `end` UTF-8 byte offsets and replacement `text`.
For example, a `prefer-const` warning highlights the variable name, while its
fix replaces only the `let` keyword. The offsets refer to `output` when
returned and to the input otherwise.

Pass `workspaceRoot` as an absolute directory to apply the CLI's project
configuration to an in-memory buffer. Relative filenames resolve against
that directory. A project using `.oxlintrc.json` pairs named and blanket
disable comments with their corresponding enable comments, including when
applying fixes. Explicit rule settings take precedence over config files.
Project `globals` and `env` apply to unsaved buffers as well. For example,
with `"env": {"node": true}` and `"globals": {"APP_VERSION": "readonly"}`,
`no-undef` recognizes `process` and `no-global-assign` flags a write to
`APP_VERSION`.

TypeScript class fields with a `declare` modifier carry `declare: true` in
the AST. Function and class names, labels, the two parts of `import.meta`
and `new.target`, and module names and sources carry their own UTF-8 byte
ranges. Quoted module names are string literals with their original `raw` text.

The exported `./binary-reader` accepts wire versions 3 through 8. Version 8
records whether to include TypeScript fields, so modules written entirely in
JavaScript syntax still carry `importKind` and `exportKind` in TS mode. Version 7
carries TypeScript declarations, annotations, type arguments and modifiers.
JavaScript trees that only require child name and module source ranges use
version 6. Simpler JavaScript trees can use version 4. The decoder still
accepts archived version 5 buffers containing declared class fields.

```ts
type ParseOptions = {
  lang?: 'js' | 'jsx' | 'ts' | 'tsx';
  sourceType?: 'script' | 'module' | 'unambiguous';
  strictSourceType?: boolean;
  forceStrict?: boolean;
  preserveParens?: boolean;
  mode?: 'ast' | 'parse' | 'full';
  showSemanticErrors?: boolean;
  sourceIsDts?: boolean;
  commonjs?: boolean;
  disallowAmbiguousJSXLike?: boolean;
};

type ParseResult = {
  program: ESTree.Program;
  errors: Array<{
    message: string;
    filename: string;
    start: number;       // UTF-8 byte offset
    end: number;         // exclusive; > start for token-aware spans
    line: number;        // 1-based
    column: number;      // 1-based, UTF-8 byte column
  }>;
};

function parseSync(
  filename: string,
  source: string,
  opts?: ParseOptions,
): ParseResult;

function parseAsync(
  filename: string,
  source: string,
  opts?: ParseOptions,
): Promise<ParseResult>;
```

#### When to reach for `parseAsync`

`parseAsync` runs the parser off the calling thread, which helps when a large
parse would delay other work in a server or editor. It normally schedules
parses on libuv's worker pool. Kessel raises Koffi's async stack to 2 MiB
before loading the native library. If another package already locked Koffi's
configuration with a smaller stack, Kessel uses a dedicated Node worker and
processes the fallback queue serially.

For small one-off parses on a synchronous code path, `parseSync` avoids the
worker handoff.

### Module and regexp tools

These experimental APIs expose the module scanner, resolver, and regexp tree.

```js
const { scanModuleSync, resolveModuleSync, parseRegExpSync } = require('@dvrdlibs/kessel');

const moduleInfo = scanModuleSync("export const [value] = input; import('./lazy.js');");
const resolved = resolveModuleSync('@app/utils', '/project/src/main.ts', {
  tsconfig: '/project/tsconfig.json',
  conditions: ['development'],
});
const regexp = parseRegExpSync('(?<word>[a-z]+)', 'u');
```

Module and regexp spans are UTF-8 byte offsets. The resolver returns a file,
builtin, or ignored module. Tool failures throw an error with a machine-readable
`code` and a byte `offset` where available.

The resolver searches `node_modules` by default. Set `modules` to a directory
or an ordered array of directories to change package lookup. For example,
`modules: ['vendor', 'node_modules']` searches `vendor` at each ancestor of the
importer before searching `node_modules`. Absolute directories are checked once.
An empty array disables directory lookup for bare packages. Relative imports,
builtins and package self-references still resolve.
Use `mainFields` to select a legacy manifest field or an ordered list of fields.
An empty list skips manifest entries and tries the configured directory entry names.
Use `exportsFields` and `importsFields` for alternate package maps. For example,
`{ exportsFields: [['tooling', 'public'], 'exports'] }` selects the first
present field. A missing private import may resolve in a later `importsFields`
map. Both options accept an empty list to disable that lookup.
Package conditions are tried in manifest order. If a key occurs twice, its last
value is used at the original position, following Node's package resolution.

CommonJS lookup and legacy package entries accept ordered `extensions` and
`mainFiles` arrays. For example, `{ mode: 'require', extensions: ['.ts', '.js'],
mainFiles: ['entry', 'index'] }` tries `entry.ts`, `entry.js`, `index.ts`, and
`index.js` in a directory. An empty array disables the corresponding search.
Use `extensionAlias: { '.js': ['.ts', '.js'] }` to resolve an explicit
`./entry.js` request to a TypeScript source file first. The resolver tries
replacement suffixes in order for relative paths and explicit package targets.

The enhanced-resolve lookup options are `roots`, `preferAbsolute`,
`preferRelative`, `fallback`, `restrictions`, `fullySpecified`,
`resolveToContext`, `explicitConditions` and `tsconfigReferences`. For example,
`{ roots: ['/srv/public'], fallback: [{ name: 'buffer', target: false }],
restrictions: [{ path: '/srv' }, { regex: '\\.(js|ts)$' }] }` looks
`/assets/a.js` up below the root, reports an unresolved `buffer` as ignored,
and skips candidate files outside `/srv` or with another extension.
`fullySpecified` defaults to the Node rule of the mode: exact for `import`,
extension and directory lookup for `require`. `resolveToContext` returns a
directory with kind `file`.

An empty string in `extensions` tries the exact filename at that position.
Relative ESM imports and explicit package export and import targets use exact paths
by default. Supplying a `tsconfig` with `rootDirs` enables TypeScript source
and declaration lookup for relative paths within those roots. For example,
`rootDirs: ['src', 'generated']` lets `src/app.ts` resolve `./theme.css` to
`generated/theme.d.css.ts`. Inherited roots are relative to the declaring config.
A root starting with `${configDir}` is relative to the consuming config.

### Isolated TypeScript declarations

`isolatedDeclarationSync(filename, source)` returns `{ output, errors }`. It
uses the native parser and emits signatures for exported declarations and their
local dependencies. It accepts TypeScript, TSX, MTS and CTS sources.

```js
const { isolatedDeclarationSync } = require('@dvrdlibs/kessel');
const result = isolatedDeclarationSync('api.ts', 'export const limit: number = 8;');
// result.output is "export declare const limit: number;\n".
```

Each diagnostic carries `code`, `message`, and half-open UTF-8 byte offsets
`start` and `end`. On errors, `output` is empty. The experimental emitter covers
annotated signatures, overloads, classes, enums, literal inference, type aliases,
interfaces, and nested or merged namespaces. It retains private types in class
index signatures and tracks local and imported keys in computed interface and
type-literal members. Inferred object accessors preserve JavaScript property keys,
so `[+1]` and `["+1"]` remain distinct. When paired accessors use different
imported type names, the declaration retains both signatures for the consumer
to type-check. Some computed class members and inferred types remain in development.

### Formatting

`formatSync(filename, source, options?)` returns a string. The filename selects
the JavaScript or TypeScript grammar. JavaScript statements, expressions and
classes print in the layout of Prettier 3.8.3, as do comments that stand between
statements, class members, object properties and switch cases. In TypeScript
files, data declarations may carry simple annotations such as
`as const satisfies Project.Config`. A statement retains its original spelling
when it uses other TypeScript syntax, JSX, decorators, a comment inside an
expression or a `prettier-ignore` directive, or when Prettier's layout for it
would change on a second run. Formatting the result again returns it unchanged.
A parse error throws a `SyntaxError` with a UTF-8 byte `offset`.

```js
const { formatSync } = require('@dvrdlibs/kessel');
formatSync('entry.ts', "import{type Item,id}from'./model';", { singleQuote: true });
// "import { type Item, id } from './model';\n"
```

Defaults are `printWidth: 80`, `tabWidth: 2`, `useTabs: false`, `singleQuote: false`,
`bracketSpacing: true`, `trailingComma: 'all'` and `endOfLine: 'lf'`. Tab width accepts 0–16 columns.
For generated line breaks, `endOfLine` accepts `'lf'`, `'crlf'`, `'cr'` or
`'auto'`. The editor uses `'auto'`, which chooses CRLF or CR from the first
carriage return in the input and otherwise uses LF. Copied regions retain their
original bytes, including line breaks inside tagged templates.
For module lists and data literals, both `'all'` and `'es5'` add a comma after the last item of a
broken list, and `'none'` omits it.

### Source generation

`minifySync(filename, source, options?)` returns `{ code, map, errors }`.
It folds JS and JSX numeric and boolean expressions, joins adjacent declarations,
and shortens local JS and JSX bindings. TypeScript retains its binding names and initializer expressions.
JSX output preserves component tags and file-level factory directives. If the JSX
compiler receives its classic factory or fragment binding through external configuration,
pass the same names in `jsx: { pragma, pragmaFrag }` (CLI flags `--jsx-pragma` and
`--jsx-pragma-frag`).
Set `compress` or `mangle` to `false` to disable either pass. Request a source
map with `sourceMap: true`. Syntax errors include UTF-8 byte offsets.

```js
const { minifySync } = require('@dvrdlibs/kessel');
const result = minifySync('sum.js', 'function sum(longInput) { return longInput + 6 * 7; }');
console.log(result.code); // function sum(a){return a+42;}
```

`transformSync(filename, source, options)` lowers TypeScript, preserves JSX by
default, and returns `{ code, map, errors }`. Set `jsx: 'classic'` to lower JSX
to `React.createElement`. A custom runtime can supply its own factory and fragment.

```js
const { transformSync } = require('@dvrdlibs/kessel');
const result = transformSync('view.tsx', 'export const view = <><Card /></>;', {
  jsx: { runtime: 'classic', pragma: 'ui.make', pragmaFrag: 'ui.Fragment' },
  sourceMap: true,
});
```

Pass `define` to replace globals after TypeScript and JSX lowering. Each
value contains JavaScript source, including the quotes around string literals.

```js
const { code } = transformSync('app.js', 'console.log(process.env.NODE_ENV)', {
  define: { 'process.env.NODE_ENV': '"production"' },
});
```

Local bindings keep their original meaning. Dotted names match static property
accesses. Exact rules take precedence over `import.meta` property wildcards
such as `import.meta.env.*`. Values are expanded once at each use. A value
that is invalid at a replacement site produces a transform diagnostic.
Assignments keep their original target when a replacement is a literal.
A `with` body or a sloppy function containing direct `eval` keeps its dynamic
name lookups.

`target` lowers syntax newer than an ECMAScript edition, from `'es2015'` to
`'es2024'`. Kessel lowers exponentiation, optional catch binding, optional
chaining, nullish coalescing, logical assignment and numeric separators.
Newer syntax it cannot lower, such as class fields below `es2022` or async
functions below `es2017`, is reported in `errors` and no code is returned.

```js
transformSync('read.ts', 'export const read = (a?: Box) => a?.value ?? 0;', { target: 'es2019' });
```

`decorator: { legacy: true }` lowers TypeScript experimental decorators, in
TypeScript's evaluation order. `emitDecoratorMetadata` adds the `design:type`,
`design:paramtypes` and `design:returntype` records derived from annotations.
Without a type checker a type alias is recorded as `Object`. Standard
decorators are printed as written.

`jsx.refresh` adds React Fast Refresh registrations and Hook signatures, with
the same options as OXC: `refreshReg`, `refreshSig` and `emitFullSignatures`.

The classic runtime honors leading `@jsx` and `@jsxFrag` comments. Set
`pure: false` inside the JSX options when the factory itself has side effects.
`throwIfNamespace: false` allows namespaced tags. A JSX prop named `__proto__`
is emitted as an own property. Transform diagnostics include UTF-8 byte spans.

Set `jsx: 'automatic'` to use React’s production JSX runtime. For a custom
runtime, pass `jsx: { runtime: 'automatic', importSource: 'preact' }`.
Generated modules import the helpers they use. Scripts load them with
`require`. A leading `@jsxImportSource` comment overrides the package for one
file, and `@jsxRuntime` switches between automatic and classic lowering.

Pass `development: true` inside either runtime’s JSX options to include the
original filename and one-based line and column. Automatic mode calls
`jsxDEV` from the package’s `jsx-dev-runtime` entry point.

Set `explicitResourceManagement` to `true` to lower `using` and `await using`.
The transform emits a local disposal helper in files that acquire resources.
On engines without the well-known disposal symbols, resources can implement
`Symbol.for("Symbol.dispose")` and `Symbol.for("Symbol.asyncDispose")`.

Use `typescript: { optimizeConstEnums: true }` to inline constant enum member
reads. Local enums erase when every use can be replaced. Exported enums and
enums with computed runtime initializers keep their object.

`codegen(source, { filename, minified, sourceMap })` returns
`{ code, map, errors }`. Both output modes preserve license notices and
supported optimizer annotations, including webpack, Vite, and Turbopack hints
on dynamic imports. Pretty output also preserves comments between statements
and class members, around object literal properties, and inside call,
constructor, and dynamic import argument lists.

### Bundling

`bundleSync(options)` bundles a module graph from disk and returns the result
in memory; nothing is written.

```js
const { bundleSync } = require('@dvrdlibs/kessel');

const result = bundleSync({
  entry: 'src/main.ts',            // or an array of entries
  format: 'esm',                   // 'esm' | 'cjs' | 'iife'
  platform: 'browser',             // 'node' | 'browser'
  define: { 'process.env.NODE_ENV': '"production"' },
  external: ['react'],
  minify: true,
  sourceMap: true,
  outdir: 'dist',                  // only makes source-map paths relative to it
});
if (result.errors.length) throw new Error(result.errors[0].message);
for (const file of result.outputs) {
  // file.fileName is null when there is a single output and you name it.
}
```

The result is `{ code, map, outputs, errors, warnings }`. `outputs` lists every
file as `{ fileName, code, map, entry }`; `code` and `map` are those of the
first one. A build with errors has no outputs. Diagnostics are
`{ severity, file, line, column, message }` with one-based positions in the
file you wrote, also for TypeScript and JSX inputs.

Other options: `splitting` (a chunk per `import()` target), `conditions`,
`mainFields`, `tsconfig`, `globalName` (iife), `treeShaking`, `target`,
`decorator: { legacy, emitDecoratorMetadata }` and `jsx` (`'classic'`,
`'automatic'`, or `{ runtime, pragma, pragmaFrag, importSource, development }`).
Several entries and `splitting` produce several files and require `'esm'`.

ES modules are scope-hoisted with live bindings and TDZ intact; CommonJS and
lazily loaded modules keep a wrapper and start where they are first imported.
Constructs the bundler cannot express, such as top-level await outside an
entry or direct `eval` in an ES module, are reported in `errors`.

### Rendering errors

A small subpath ships a codeframe renderer for human-readable output —
separate so JSON-only callers don't pay for it:

```js
const { parseSync } = require('@dvrdlibs/kessel');
const { formatError } = require('@dvrdlibs/kessel/format');

const src = 'function greet() {\n  return "hello\n}';
const { errors } = parseSync('app.js', src);
errors.forEach(e => console.error(formatError(e, src)));
```

Output:

```
app.js:3:2: Expected '}' at end of function body
  2 |   return "hello
  3 | }
    |  ^
```

## How it works

1. Source → native shared library (`libkessel`) via [koffi](https://koffi.dev) FFI
2. Parser produces the AST in arena memory (no allocations during parse)
3. A compact binary emitter writes the AST into a single buffer
4. JS reader decodes the buffer into ESTree objects via `DataView`

No process spawn. No JSON serialization. One function call.

## Editor diagnostics and safe fixes

The experimental `kessel-language-server` reads LSP messages on standard
input and writes replies on standard output. In an editor with a generic
language client, use the following command for JavaScript, JSX, TypeScript,
and TSX buffers.

```sh
./node_modules/.bin/kessel-language-server --stdio
```

The server checks unsaved text using the workspace's `kessel.lint.json`
or `.oxlintrc.json`, including nested configs, overrides, and ignores.
It reports parser and lint diagnostics as you type. Editors can request
`quickfix` for a selected warning or `source.fixAll.kessel` to apply all
safe fixes to the open buffer. A `textDocument/formatting` request formats
module declarations and data literals using the open buffer and the editor's
indentation settings.
With `react/exhaustive-deps` enabled, the Quick Fix menu offers edits to the
reported dependency list. SDK clients can request the same proposed edits
with `lintSync(filename, source, { includeSuggestions: true, rules })`.
Editor rule overrides go in `initializationOptions.rules` or `settings.kessel.rules`.

## Build from source

Requires [Odin](https://odin-lang.org/) and [Task](https://taskfile.dev/).

```bash
task build:lib   # → bin/libkessel.dylib (macOS) or bin/libkessel.so (Linux)
```

## License

MIT
