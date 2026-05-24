# @dvrdlibs/kessel

JavaScript / TypeScript / JSX / TSX parser. Emits ESTree-compatible ASTs via a native shared library bound through [koffi](https://koffi.dev). Synchronous, in-process — no subprocess, no JSON serialization.

## Install

```bash
npm install @dvrdlibs/kessel
```

The install pulls only the platform-specific native binary that matches your host. The other sub-packages stay on the registry, unfetched.

| Sub-package | Platform | Binary |
|---|---|---|
| `@dvrdlibs/kessel-darwin-arm64` | macOS, Apple Silicon | `libkessel.dylib` |
| `@dvrdlibs/kessel-darwin-x64`   | macOS, Intel         | `libkessel.dylib` |
| `@dvrdlibs/kessel-linux-arm64`  | Linux, aarch64       | `libkessel.so`    |
| `@dvrdlibs/kessel-linux-x64`    | Linux, x86_64        | `libkessel.so`    |
| `@dvrdlibs/kessel-win32-x64`    | Windows, x86_64      | `libkessel.dll`   |

## Usage

```js
const { parseSync } = require('@dvrdlibs/kessel');

const { program, errors } = parseSync('app.js', 'const x = 1 + 2;');
console.log(program.body[0].type); // "VariableDeclaration"
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

### API

```ts
function parseSync(
  filename: string,
  source: string,
  opts?: { lang?: 'js' | 'jsx' | 'ts' | 'tsx' }
): { program: ESTree.Program, errors: Array<{ message: string }> }
```

## Performance

Measured with 50 iterations, min time, Node.js v25, Apple M1 Max:

| File | Size | Parse time |
|---|---|---|
| lodash.js  | 531 KB | 3.6 ms |
| jquery.js  | 279 KB | 3.9 ms |

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
