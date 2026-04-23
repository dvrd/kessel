# kessel-parser

An `oxc-parser`-compatible JavaScript/TypeScript parser backed by [Kessel](../../README.md).

## Usage

```javascript
const { parseSync } = require('kessel-parser');

// Parse JavaScript
const { program, comments, errors } = parseSync('test.js', 'const x = 1 + 2;');

// Parse TypeScript
const tsResult = parseSync('component.tsx', `
  const Hello = <T,>(props: T) => <div>{props}</div>;
`, { preserveParens: false });

console.log(tsResult.program.body[0]); // VariableDeclaration
```

## API

### `parseSync(filename, source, options?)`

Synchronously parses `source` and returns an ESTree-compatible AST.

**Parameters**
| Param | Type | Description |
|-------|------|-------------|
| `filename` | `string` | Synthetic file path — used only for language detection from extension (`.js`, `.jsx`, `.ts`, `.tsx`). The file is not read from disk. |
| `source` | `string` | Source code to parse. |
| `options` | `object` | Optional parsing options (see below). |

**Options**
| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `sourceType` | `'script' \| 'module' \| 'unambiguous'` | `'unambiguous'` | Pin the ECMAScript `Program.sourceType`. |
| `preserveParens` | `boolean` | `false` | Emit `ParenthesizedExpression` wrappers (Acorn/OXC convention). |
| `loc` | `boolean` | `false` | Add `loc: { start: { line, column }, end: { line, column } }` to each node. |
| `range` | `boolean` | `false` | Add `range: [start, end]` tuple to each node. |

**Returns** `{ program: Program, comments: Comment[], errors: ParseError[] }`

## Supported Languages

| Extension | Grammar |
|-----------|---------|
| `.js`, `.mjs`, `.cjs` | JavaScript (ES2025, no JSX) |
| `.jsx` | JavaScript + JSX |
| `.ts`, `.mts`, `.cts` | TypeScript |
| `.tsx` | TypeScript + JSX |

## Binary

The package uses `../../bin/kessel` (project-local build) or a bundled
platform-specific binary in `bin/kessel-<platform>-<arch>`.

Build from source:
```bash
task build   # requires Odin compiler
```

## Compatibility

Output shape matches `oxc-parser@^0.127.0`. The main intentional difference is
that `comments` are embedded in `program.comments` rather than returned
separately from the parse result object — access them via
`result.program.comments`.

## Architecture note

This package calls the Kessel CLI binary via `spawnSync`. For maximum
throughput in production builds, consider the full NAPI binding (not yet
published) which amortizes process spawn overhead.
