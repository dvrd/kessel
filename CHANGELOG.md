# Changelog

All notable changes to kessel will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-05-21

### Added
- Cross-platform SIMD lexer (SSE2 on x86-64, NEON on ARM64)
- Pratt recursive-descent parser — ES2015–ES2025, TypeScript, JSX, TSX
- Semantic checker (opt-in via `--show-semantic-errors`)
- ESTree JSON emitter (`kessel parse`)
- Compact binary AST emitter (`kessel parse --binary`) — 7× smaller than JSON
- Zero-copy raw transfer buffer (`kessel raw`)
- Multi-file parallel parse (`kessel parse *.js --workers N`)
- Server mode (`kessel server`) for long-lived subprocess usage
- Microbench + profile commands (`kessel microbench`, `kessel profile`)
- npm package (`kessel`) with native shared library binding via koffi FFI
- JS binary reader — 11× faster than JSON.parse
- AST visitor utility (`kessel/visitor`)
- OXC-style conformance harness (62K fixtures, 100% positive on all suites)
- 291 golden-output unit tests
- Performance regression gate (10 curated files)
- Differential fuzz testing vs reference parser

### Performance
- 8–19% faster than OXC's parser (raw parse, no serialization)
- 8% faster than OXC at the npm boundary (parse + binary + decode)
- 189 cycles/token on Apple M1 Max
- Arena-only memory (zero malloc during parse)
- 16-byte FastToken by value
- Perfect-hash keyword lookup
- Lazy two-token lookahead
- Apple Silicon QoS P-core pinning
