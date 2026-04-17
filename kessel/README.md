# Kessel

Fast JavaScript Parser written in Odin - inspired by OXC.

## Features

- ⚡ Arena-based memory allocation (O(1) alloc/free)
- 🎯 Hand-written recursive descent parser
- 📦 String interning for identifiers
- 🔧 Two-phase parsing (parse → semantic analysis)
- 📊 JSON AST output
- 📝 Tokenizer with detailed location info

## Building

```bash
./build.sh release    # Release build (optimized)
./build.sh debug      # Debug build
```

Or manually:
```bash
odin build src -out:kessel -o:speed  # Release
odin build src -out:kessel -debug    # Debug
```

## Usage

### Parse a JavaScript file
```bash
./kessel parse app.js
```

### Tokenize a JavaScript file
```bash
./kessel lex app.js
# or
./kessel tokenize app.js
```

### Show help
```bash
./kessel help
```

## Example Output

```bash
$ ./kessel parse example.js
{
  "type": "Script",
  "body": [
    {
      "type": "VariableDeclaration",
      "kind": "let",
      ...
    }
  ]
}

--- Statistics ---
Arena used: 24576 bytes
Parse errors: 0
```

## Architecture

```
kessel/
├── src/
│   ├── main.odin          # CLI entry point
│   ├── lexer/
│   │   ├── token.odin     # Token definitions
│   │   └── lexer.odin     # Lexer implementation
│   ├── parser/
│   │   └── parser.odin    # Recursive descent parser
│   └── ast/
│       └── ast.odin       # AST node definitions
├── build.sh               # Build script
└── README.md
```

## Performance Philosophy

Like OXC, Kessel uses:

1. **Arena Allocation**: All AST nodes allocated in a contiguous memory region
2. **String Interning**: Identifiers deduplicated for fast comparison
3. **Zero-Copy**: Source text borrowed, not copied
4. **SIMD-Ready**: Lexer designed for SIMD whitespace skipping
5. **Two-Phase Parsing**: Fast parse first, optional semantic analysis second

## Project Goals

- [x] Basic lexer with all JS token types
- [x] Recursive descent parser
- [x] JSON AST output
- [ ] Full ECMAScript 2024 support
- [ ] TypeScript support
- [ ] Source maps
- [ ] Transformer
- [ ] Minifier
- [ ] Linter

## License

MIT
