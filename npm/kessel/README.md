# @dvrdlibs/kessel

Fast JavaScript/TypeScript/JSX/TSX parser. ESTree-compatible ASTs via native shared library.

**8% faster than OXC** at the npm boundary (measured on lodash.js).

## Install

```bash
npm install @dvrdlibs/kessel
```

On install, npm pulls only the platform-specific native binary that matches
your host (one of `darwin-arm64`, `darwin-x64`, `linux-arm64`, `linux-x64`,
`win32-x64`). The other four sub-packages stay untouched on the registry.

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

| File | kessel | oxc-parser | acorn | @babel/parser |
|---|---|---|---|---|
| lodash.js (531KB) | **3.6ms** | 3.9ms | 5.3ms | 8.1ms |
| jquery.js (279KB) | **3.9ms** | 3.8ms | 5.6ms | 7.4ms |

Measured with 50 iterations, min time, Node.js v25, Apple M1 Max.

## How it works

1. Source → native shared library (`libkessel`) via [koffi](https://koffi.dev) FFI
2. Parser produces AST in arena memory (zero allocations during parse)
3. Binary emitter writes compact AST buffer (7× smaller than JSON)
4. JS reader decodes buffer into ESTree objects via DataView (11× faster than JSON.parse)

No process spawn. No JSON serialization. One function call.

## Build from source

Requires [Odin](https://odin-lang.org/) and [Task](https://taskfile.dev/).

```bash
task build:lib   # → bin/libkessel.dylib (macOS) or bin/libkessel.so (Linux)
```

## License

MIT
