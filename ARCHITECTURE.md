# Kessel Architecture

> Fast JavaScript Parser written in Odin — inspired by OXC.

## Overview

Kessel parses JavaScript through a multi-stage pipeline optimized for speed and memory efficiency:

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Source    │───▶│    Lexer    │───▶│   Tokens    │───▶│   Parser    │───▶│     AST     │
│   (.js)     │    │             │    │   (SoA)     │    │  (Recursive │    │  (Arena)    │
│             │    │ SIMD + Regex│    │  Compact    │    │   Descent)  │    │             │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
                                                                                   │
                                                                                   ▼
                                                                            ┌─────────────┐
                                                                            │   Printer   │
                                                                            │  (JSON out) │
                                                                            └─────────────┘
```

## Pipeline Stages

### 1. Source Input
Raw JavaScript source code is read from file or stdin. The source text is borrowed (zero-copy), not duplicated.

### 2. Lexical Analysis (Lexer)
**Files:** `src/lexer/lexer.odin`, `src/lexer/lexer_optimized.odin`

The lexer transforms source code into a stream of tokens using:
- **SIMD-accelerated whitespace skipping** (`src/lexer/simd.odin`) — uses NEON on ARM64 (SSE2/AVX2 paths not implemented)
- **Context-aware regex matching** — distinguishes `/` (division) from `/.../` (regex literal) based on parser context
- **Perfect hash table for keywords** (`src/lexer/keyword_hash.odin`) — O(1) keyword lookup
- **String interning** — identifiers are deduplicated for fast comparison

**Token Types:**
- Literals: `NumericLiteral`, `StringLiteral`, `BooleanLiteral`, `NullLiteral`, `BigIntLiteral`, `RegExpLiteral`, `TemplateLiteral`
- Keywords: `let`, `const`, `function`, `class`, `if`, `while`, etc.
- Punctuators: `+`, `-`, `*`, `/`, `=`, `=>`, etc.
- Context-sensitive: `>` (operator vs generic type start in TS mode)

### 3. Token Storage (Structure of Arrays)
**Files:** `src/lexer/token_compact.odin`, `src/lexer/token.odin`

Instead of traditional array-of-structs, Kessel uses **SoA (Structure of Arrays)** for cache efficiency:

```odin
TokenSoA :: struct {
    types:   [dynamic]TokenType,    // 1 byte each (padded to 4)
    offsets: [dynamic]u32,          // 4 bytes - source offset
    lines:   [dynamic]u32,          // 4 bytes - line number
    cols:    [dynamic]u16,          // 2 bytes - column
    lengths: [dynamic]u16,          // 2 bytes - token length
}
```

Benefits:
- **Cache locality**: SoA reduces token size 4.75x vs traditional AoS layout (per token_compact.odin comment)
- **Compact representation**: ~16 bytes/token vs ~76 bytes traditional (per token_compact.odin)
- **Prefetcher-friendly**: Linear memory access patterns

### 4. Syntactic Analysis (Parser)
**File:** `src/parser/parser.odin`

Recursive descent parser implementing ECMAScript grammar:

```
Expression (lowest precedence)
    ▼
AssignmentExpression
    ▼
ConditionalExpression (ternary)
    ▼
LogicalORExpression
    ▼
LogicalANDExpression
    ▼
BitwiseORExpression
    ▼
...
    ▼
UnaryExpression
    ▼
UpdateExpression (++, --)
    ▼
LeftHandSideExpression (call, member, new)
    ▼
PrimaryExpression (literals, identifiers, this, super, groups)
```

**Key Features:**
- **Pratt parsing** for operator precedence
- **Automatic Semicolon Insertion (ASI)** — handles optional semicolons per ECMAScript spec
- **Single-pass recursive descent parse** with inline error recovery
- **Error recovery**: Synchronizes on statement boundaries to report multiple errors

### 5. AST Generation
**File:** `src/ast/ast.odin`

All AST nodes are allocated in a contiguous arena:

```odin
NodeType :: enum {
    // Expressions
    NullLiteral, BooleanLiteral, NumericLiteral, ...
    // Statements
    ExpressionStatement, IfStatement, WhileStatement, ...
    // Declarations
    FunctionDeclaration, VariableDeclaration, ...
    // Module
    ImportDeclaration, ExportNamedDeclaration, ...
}

Program :: struct {
    type: NodeType,
    body: []Statement,
}
```

**Identifier Distinction (OXC-style):**
- `BindingIdentifier` — variable declarations (`let x`, `function f`)
- `IdentifierReference` — variable usage (`x = 1`, `foo()`)
- `IdentifierName` — property names (`obj.prop`, `{key: value}`)
- `LabelIdentifier` — loop/switch labels

### 6. JSON Printer
**File:** `src/main.odin` (print functions)

Traverses AST and outputs JSON with source location information:

```json
{
  "type": "Program",
  "body": [
    {
      "type": "VariableDeclaration",
      "kind": "let",
      "declarations": [...]
    }
  ]
}
```

## Key Design Decisions

### 1. Arena Allocator
All allocations happen in a pre-sized memory arena:

```odin
arena: mem.Arena
backing := make([]byte, estimate_arena_size(source_len))
mem.arena_init(&arena, backing)
arena_alloc := mem.arena_allocator(&arena)
```

**Why:**
- O(1) allocation (bump pointer)
- O(1) deallocation (free entire arena at once)
- Perfect cache locality for tree traversals
- No fragmentation

### 2. SoA Token Storage
Tokens stored in parallel arrays rather than array of structs:

```
Traditional:  [Token{Type, Span, Context}] [Token{Type, Span, Context}] ...
SoA:          [Type, Type, Type...] [Span, Span, Span...] [Context, Context...]
              ^ sequential access = cache prefetcher happy
```

### 3. Context-Aware Regex
JavaScript's `/` is ambiguous (division vs regex). The lexer uses parser state:

```odin
// If previous token can precede a regex, `/pattern/` is valid
RegexAllowed :: enum {
    Never,      // After identifier, number, closing paren/bracket/brace
    Sometimes,  // Context-dependent
    Always,     // After operator, open paren, statement start
}
```

### 4. Automatic Semicolon Insertion (ASI)
Implements ECMAScript's [automatic semicolon insertion rules](https://tc39.es/ecma262/#sec-automatic-semicolon-insertion):

```javascript
// Input
return
a + b

// Parsed as (newline before operand triggers ASI)
return;
a + b;
```

ASI triggers on:
- Newline followed by `}`, end of file, or specific tokens
- Restricted productions (postfix `++`/`--`, `continue`/`break`/`return`/`throw` with newline)

## File Structure

```
kessel/
├── src/
│   ├── main.odin              # CLI entry, parse/lex commands, JSON output
│   ├── lexer/
│   │   ├── lexer.odin         # Base lexer implementation
│   │   ├── lexer_optimized.odin  # SIMD + optimized paths
│   │   ├── token.odin         # Token definitions (traditional)
│   │   ├── token_compact.odin # SoA token storage
│   │   ├── keyword_hash.odin  # Perfect hash table for keywords
│   │   ├── simd.odin          # SIMD whitespace scanning
│   │   └── lexer_adapter.odin # Unified lexer interface
│   ├── parser/
│   │   └── parser.odin        # Recursive descent parser (~3980 lines)
│   └── ast/
│       └── ast.odin           # AST node definitions
├── tests/
│   ├── fixtures/              # Test cases organized by feature
│   └── run_tests.sh           # Test runner
└── lib/
    └── kessel_binding.js      # Node.js FFI bindings
```

## Extending the Parser

### Adding a New Expression Type

1. **Add node type to `src/ast/ast.odin`:**

```odin
NodeType :: enum {
    // ... existing types
    MyNewExpression,  // Add here
}

MyNewExpression :: struct {
    loc:   Loc,
    field: SomeType,
}

// Add to Expression union
Expression :: union {
    // ... existing expressions
    ^MyNewExpression,
}
```

2. **Add lexer token if needed (`src/lexer/token.odin`):**

```odin
TokenType :: enum {
    // ... existing tokens
    MyNewKeyword,  // Add if new syntax keyword
}

// Add to perfect hash table in keyword_hash.odin
```

3. **Add parsing logic in `src/parser/parser.odin`:**

Find the appropriate precedence level and add parsing:

```odin
// In parse_expression at the right precedence level
case .MyNewKeyword:
    return parse_my_new_expression(p)

// Or in primary expression parsing
case .MyNewKeyword:
    return parse_my_new_expression(p)
```

4. **Implement the parse function:**

```odin
parse_my_new_expression :: proc(p: ^Parser) -> ^Expression {
    loc := p.current.loc
    advance(p)  // consume keyword
    
    // Parse required components
    field := parse_required_component(p)
    
    // Create AST node (arena-allocated)
    expr := new_expression(p, MyNewExpression)
    expr.field = field
    
    return expr
}
```

5. **Add JSON output in `src/main.odin`:**

```odin
case ^ast.MyNewExpression:
    fmt.println("    {")
    fmt.printf("      \\"type\\": \\"MyNewExpression\\",\n")
    fmt.printf("      \\"field\\": ...\n")
    fmt.println("    }")
```

6. **Add test case in `tests/fixtures/`:**

Create `tests/fixtures/expressions/my_new_expression.js` with examples.

## Performance Characteristics

| Metric | Value |
|--------|-------|
| Lexer throughput | See docs/PROFILING.md for measured baselines |
| Parse throughput | See docs/PROFILING.md for measured baselines |
| Memory | 4MB floor for small files, scales at 256x source_len (see docs/PROFILING.md) |
| Token size | ~16 bytes (SoA compact) |
| AST node overhead | Varies by node type (unions) |

## Limitations

- **No TypeScript support** (planned)
- **No JSX support** (planned)
- **No strict mode validation** — parses strict mode code but doesn't validate restrictions
- **No early error checking** — some ECMAScript early errors not yet implemented

## See Also

- **docs/OXC_COMPARISON.md** — Detailed comparison of Kessel vs OXC approaches (dispatch, arena allocation, AST representation, configuration, safety)
- **docs/PROFILING.md** — Benchmarking infrastructure, measured baselines, profiling workflow
- **docs/ARCH_AUDIT.md** — Verification trail: what was verified, what was stale, what was wrong

## References

- [ECMAScript 2024 Specification](https://tc39.es/ecma262/)
- [OXC Parser](https://github.com/oxc-project/oxc) — inspiration for architecture
- [Odin Programming Language](https://odin-lang.org/)
