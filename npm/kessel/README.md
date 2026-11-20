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
offsets. The package also exposes `codegen` and `lintSync`. Codegen has known
round-trip differences in the broader conformance corpora, and the linter
uses Kessel's built-in rule set.

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

## Build from source

Requires [Odin](https://odin-lang.org/) and [Task](https://taskfile.dev/).

```bash
task build:lib   # → bin/libkessel.dylib (macOS) or bin/libkessel.so (Linux)
```

## License

MIT
