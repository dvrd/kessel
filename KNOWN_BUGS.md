# Known bugs

Divergences between Kessel and OXC ESTree output discovered during the
deep verification pass. Fixed items are listed at the bottom with their
commit hashes; open items are tracked here.

## d3.js `execSync` SIGSEGV (pre-existing)

`kessel raw bench/real_world/d3.js` crashes with SIGSEGV when invoked
via Node's `child_process.execSync`, but succeeds when run from a shell.
Reproduces on the baseline handoff commit, so it is not a regression
from the current fix series.

**Repro**:
```
node -e 'require("child_process").execSync("./bin/kessel raw bench/real_world/d3.js --out /tmp/d.bin", {stdio:"ignore"})'
```

**Suspected area**: arena allocation / mmap under spawned processes with
different RLIMIT defaults, or an Odin runtime `os.flush(os.stdout)` path
that aborts when stdio is detached. Needs `lldb` attach to investigate.

**Workaround**: `verify_integration.js` users can exclude d3.js from the
sample set until this is root-caused.

## Pre-existing parse failures in 28/467 real-world files

`task test:real` reports 28 parse-error files. These are present on the
baseline handoff commit. Not tracked individually here because they're
a separate investigation. See HANDOFF.md for the current list.

## 12 SIGSEGV files during JSON emit (surfaced by P1 in ClassBody emit)

Enabling full ClassBody JSON emit revealed another Bug-H-class latent
transmute: `./bin/kessel parse <file>` crashes with SIGSEGV for tone.js,
mathjax.js, marked.js, chartjs.js, quill.js, embla.js, mapbox.js,
openlayers.js, framer-motion.js, lit-html.js, petite-vue.js, prettier.js.

Stack trace (tone.js, always reproducible):

```
frame #0: main::get_statement_type_name + 88   (reading union tag from bad ^Statement)
frame #1: main::print_statement_ast + 128
frame #2: main::print_block_statement_inline + 280
frame #3..8: print_expression_ast / print_function_body_inline (nested)
frame #9: main::print_class_element_fields + 836
frame #10: main::print_class_body_inline + 416
```

4 same-class bugs were fixed this session (I-1 through I-4 in HANDOFF.md);
at least one more transmute site remains. Audit candidate:

```
grep -rn 'transmute\|(\^Statement)(\|(\^Declaration)(\|(\^Expression)(' src/parser.odin src/main.odin
```

Bisection within a single file is unreliable (the crashing region depends
on the exact prefix boundary). lldb attach is the way.

---

## Fixed (session after f8ea96a)

- **I-1: `parse_static_block` transmute(^BlockStatement)**. Static block
  bodies emitted as `[]` regardless of contents. Fix: extract via
  `block_stmt^.(^BlockStatement)`.
  Guard: `tests/fixtures/regression/001_static_block_body.js`.
- **I-2: `parse_for` for-in/of `left_decl` transmute(^VariableDeclaration)**.
  Corrupted for-in/of declaration pointer. Fix: type assertion.
  Guard: `tests/fixtures/regression/003_class_for_in_of.js`.
- **I-3: ForStatement / ForIn / ForOf `(^Statement)(decl)` cast in emit**.
  Caused SIGSEGV inside class methods with `for (let i = 0; ...)` (tone.js
  family, pre-I-1/I-2 fixes). Fix: extracted `print_variable_declaration_body`;
  emit VariableDeclaration inline.
  Guard: `tests/fixtures/regression/002_class_for_statement.js`.
- **I-4: ExportNamedDeclaration / ExportDefaultDeclaration cross-union cast**.
  `(^Declaration)(^Statement)` and `(^Statement)(^Declaration)` both wrong:
  different tag ordinal spaces (7 vs 25 variants). Exports emitted as
  `"type": "Unknown"`. Fix: `print_declaration_ast` rebuilds a Statement via
  variant assignment so Odin computes the correct tag; parser side likewise
  allocates a fresh `^Declaration` and reassigns the inner variant.
  Guard: `tests/fixtures/regression/004_export_declarations.js`.
- **I-5: ClassBody JSON emit stub** (P1 this session). Methods / fields /
  getters / setters / constructors / static blocks now emit full ESTree
  (MethodDefinition / PropertyDefinition / StaticBlock).
  Guard: `tests/fixtures/regression/005_class_body_full_emit.js`.
- **I-6: `direct_buf` fixed 20× source overflow**. Full class emit exceeds
  the static estimate. Fix: `direct_reserve` grows by doubling before every
  direct-mode write; worker path free-after-grow fixed.
  Guard: `tests/fixtures/regression/006_direct_buf_grow.js`.

All six guarded by `task test:regression` (structural OXC-cross-reference)
**and** `task test:unit` (bit-exact JSON comparison). Each regression check
has been validated by reverting the specific fix and confirming the check
fails.

## Fixed (earlier sessions)

- **Bug H** (577c237): three arrow-function builders stored a
  `^BlockStatement` in an `^Expression` field via
  `transmute(^Expression)block_stmt`. `rewrite_arrow_function` then
  silently corrupted the BlockStatement's `loc.span.*` by treating
  the first 8 bytes as a union pointer. Fix: new
  `ArrowFunctionBody :: union { ^Expression, ^BlockStatement }`, three
  parser sites switched to direct assignment, `rewrite_arrow_function`
  dispatches on the tag.
- **Bug E** (9935fa8): `lex_string` published raw source bytes as
  `StringLiteral.value`, so `"\x20\t"` produced the 4-char source
  string instead of the decoded space+tab. Fix: escape-decode in
  `lex_string_scalar` (ECMA-262 §12.9.4) into an arena-allocated
  dynamic buffer, publish via `last_lit_*`, dispatch in
  `advance_token`/`prime_token_cache`. Verified against
  `tests/fixtures/edge/string_escapes.js` (15/15) and jquery.js.

- **Bug A** (5d1f49…b80382e): `lex_hex` / `lex_binary` / `lex_octal`
  tokenized the literal but never computed its value. `0xff` parsed as
  `value: 0` instead of `255`. Fix: decode digits and populate
  `last_lit_value` like `lex_number` does for decimals.
- **Bug B** (432c102): `new X(args)` produced NewExpression with a
  CallExpression callee instead of X itself. Fix: `parse_member_expr`
  via `parse_lhs_tail(allow_call=false)` for the new-callee position.
- **Bug C** (N/A — verifier spec error): reported as kessel-side
  `computed=true` on plain object properties, actually caused by wrong
  stride in the verifier (40 vs real 48 because `PropertyKind` enum is
  8 bytes in Odin).
- **Bug D** (857647a): `ArrowFunctionExpression.expression` always
  `true`. Fix: capture `is_block_body := is_token(.LBrace)` BEFORE
  parsing the body, then use `!is_block_body`.
- **Bug F** (857647a): `parse_export_default` transmute UB. Fix: allocate
  ExportDefaultDef and box via union assignment; extract function-form
  expression via `stmt^.(^ExpressionStatement).expression`.
- **Bug G** (77531f4): `parse_try_statement` / `parse_catch_clause`
  transmute UB on block/finalizer/catch-body — silently truncated the
  block to empty. Fix: extract `^BlockStatement` via union cast.
- **Function expression UB** (432c102): `parse_function_expression` did
  `transmute(^FunctionDeclaration)stmt`, and `parse_function_declaration`
  boxed via `(^Expression)(expr)` pointer cast instead of
  `expression_from(p, expr)`. Fixed together.

## Related tooling fixes (in 9935fa8)

- `tests/verify_raw_deep.js` was silently unusable: literal `[ ... ]` /
  `{ ... }` placeholders in the JSON emitter broke `JSON.parse`, and
  literal type names weren't normalized against OXC's `"Literal"`.
  Both fixed; verifier now runs green on fixtures.
- `tests/verify_string_escapes.js` added: walks Kessel's truncated JSON
  and OXC's full ESTree in parallel, pairs strings by `raw`, compares
  `value` after escape decoding. Use for string-escape regressions.
- `tests/fixtures/edge/string_escapes.js` added: 15 escape patterns
  covering every shape in ECMA-262 §12.9.4.
