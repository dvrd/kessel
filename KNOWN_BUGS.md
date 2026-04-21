# Known bugs

Bugs discovered during the OXC-compared deep verification pass. Each is a
real divergence between Kessel and OXC ESTree output.

## Bug D — `ArrowFunctionExpression.expression` flag always true

For `const g = () => { return 1; };` (block body), OXC sets `expression:
false`. Kessel always writes `expression: true` at offset 64 of the
ArrowFunctionExpression struct, regardless of the body kind.

**Where**: `parse_arrow_function` (grep for `ArrowFunctionExpression` in
`src/parser.odin`). Likely the parser sets the flag before detecting the
body is a block.

**Impact**: downstream consumers that dispatch on `expression` cannot
distinguish expression-body arrows from block-body arrows.

## Bug E — StringLiteral values are not escape-decoded

For `"[\\x20\\t]"` in source, OXC returns `value: "[\x20\t]"` (decoded:
space + tab). Kessel returns `value: "[\\x20\\t]"` (raw source bytes).

**Where**: `lex_string` / string cook path in `src/lexer.odin`. The
`.value` field is populated from raw source bytes instead of the cooked
(escape-decoded) form. `.raw` is correct.

**Impact**: jquery.js shows ~30 mismatches, all of this shape. Any tool
that consumes `value` gets wrong data.

## Bug F — `parse_export_default` transmute UB

```odin
decl := parse_function_declaration(p, true)
if decl != nil {
    def = transmute(^ExportDefaultDef)decl   // UB
}
```

`decl` is a `^Statement` union; transmuting to `^ExportDefaultDef` reads
the wrong struct layout. Same class as Bug G (TryStatement, fixed) and
the FunctionExpression UB (fixed). Not yet triggered by a specific test
but a latent crash waiting to happen.

**Where**: `src/parser.odin`, `parse_export_default` around line 2462.

**Fix sketch**: extract via `decl^.(^ExpressionStatement)` then access
`.expression` (same pattern as `parse_function_expression`).

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
