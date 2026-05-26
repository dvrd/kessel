# @dvrdlibs/kessel

JavaScript / TypeScript / JSX / TSX parser. Emits ESTree-compatible ASTs via a native shared library bound through [koffi](https://koffi.dev). Synchronous, in-process — no subprocess, no JSON serialization.

## Install

```bash
npm install @dvrdlibs/kessel
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

Override with the `lang` option:

```js
parseSync('file.js', source, { lang: 'tsx' });
```

Request stricter parser/checker work with `mode`:

```js
parseSync('file.ts', source, { mode: 'full', sourceType: 'module' });
```

### API

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

`parseAsync` dispatches the native parse onto libuv's worker thread pool.
It is the right call when:

- The parse is large enough that blocking the Node event loop for its
  duration would hurt latency (server request handlers, editor tooling).
- You want to parse N files concurrently and let the pool schedule them.
  Throughput scales close to `min(N, UV_THREADPOOL_SIZE)`; raise
  `UV_THREADPOOL_SIZE` (default 4) to widen the pool.

For small one-off parses, `parseSync` is faster than `parseAsync` by the
thread-handoff overhead (~10-50µs) — prefer it when you're already on a
synchronous code path and concurrency isn't on the table.

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
