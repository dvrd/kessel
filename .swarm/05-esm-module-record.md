TASK: Implement the ESM Module Record that OXC returns alongside the AST: `hasModuleSyntax`, `staticImports`, `staticExports`, `dynamicImports`, `importMetas`. Behind a `--module-record` CLI flag. Adds a top-level `"module": { ... }` object to the emitted JSON.

## Context
OXC's `parseSync` returns a `module` object alongside the `program` AST. Bundlers and plugins use it to avoid a second AST walk:
```json
{
  "program": { ... },
  "module": {
    "hasModuleSyntax": true,
    "staticImports": [
      { "start": 0, "end": 20, "moduleRequest": { "value": "react", "start": 16, "end": 23 },
        "entries": [ { "importName": { "kind": "Default", "name": "React" },
                       "localName": { "value": "React", "start": 7, "end": 12 } } ] }
    ],
    "staticExports": [
      { "start": 0, "end": 22, "entries": [ { "exportName": { "kind": "Name", "name": "foo" },
                                               "localName": { "kind": "Name", "name": "foo" } } ] }
    ],
    "dynamicImports": [ { "start": 10, "end": 28, "moduleRequest": { "start": 18, "end": 25 } } ],
    "importMetas": [ { "start": 5, "end": 16 } ]
  }
}
```

Kessel already has `p.has_module_syntax` (src/parser.odin L202, set at L3313 for top-level await, L3599 for import.meta). Import/export declaration parsers already set it implicitly via top-level import/export detection (src/parser.odin L738-).

What's missing: the parser doesn't collect spans. We need to extend `Parser` with 4 new arrays and populate them at the parse sites. Then extend main.odin to emit the module record when the flag is on.

## Exact scope
Allowed edits:
- `src/ast.odin` — add 4 record structs (`ESMStaticImport`, `ESMStaticExport`, `ESMDynamicImport`, `ESMImportMeta`) matching the shape above. Keep simple: just spans + optional string (moduleRequest.value) + a slice of sub-entries for named/default imports.
- `src/parser.odin` — add 4 `[dynamic]` fields on `Parser` struct next to `has_module_syntax`; populate in:
  - `parse_import_declaration` (L2677)
  - `parse_export_declaration` / `parse_export_default` / `parse_export_named` / `parse_export_all` (L2847, L2900, L2980, L2947)
  - `parse_dynamic_import` (L4986)
  - The `import.meta` MetaProperty branch (L3580-3599)
  - Set `has_module_syntax = true` at every non-dynamic import/export site too (explicit, not relying on post-parse detection).
- `src/main.odin` — CLI flag `--module-record`, when enabled, emit a `"module": { ... }` object after the `"program": ...` object in the output JSON.

Forbidden:
- All other src files.
- Any change to fixtures/verifiers/baselines. Default-off, so no regression.

## Requirements
1. CLI flag `--module-record` defaults to off. When off, output is byte-identical to today.
2. When on and source is a module with any imports/exports/import.meta:
   - `hasModuleSyntax: true`
   - Each static `import X from "m"` adds one entry to `staticImports` with `start`/`end` of the whole declaration, `moduleRequest.value = "m"` plus span of the string literal, and `entries` listing each specifier with `importName.kind` (`"Default"`, `"Namespace"`, `"Name"`) and `localName`.
   - Each `export ...` adds to `staticExports`. `export default X` produces one entry with `exportName.kind = "Default"`. `export { a, b as c }` produces entries per specifier. `export * from "m"` produces one entry with `exportName.kind = "Namespace"` and `moduleRequest` set.
   - Each `import("m")` expression adds to `dynamicImports` with span + argument span.
   - Each `import.meta` expression adds to `importMetas` with span.
3. Emit order: module record ALWAYS follows the program object, before any `"errors": [...]` / closing brace. See main.odin L646 area for where the AST is emitted and where errors come in.
4. If `hasModuleSyntax` is `false`, emit `module` with all empty arrays (matches OXC).

## Verification
Run these in order:

1. `task build` — exits 0.
2. Default-off byte compat: `./bin/kessel tests/fixtures/basic/001_empty.js` output before and after must be byte-identical. (Use the same approach as EST-LOC task — `task test:nodes` green is a good proxy.)
3. `--module-record` smoke tests:
   ```bash
   echo 'import React from "react"; import * as R from "r"; import { a, b as c } from "x";' \
     | ./bin/kessel --stdin --module-record 2>/dev/null \
     | python3 -c "import sys,json; d=json.load(sys.stdin); m=d['module']; print(m['hasModuleSyntax'], len(m['staticImports']))"
   ```
   — must print `True 3`.
4. ```bash
   echo 'export default 1; export { x }; export * from "y";' \
     | ./bin/kessel --stdin --module-record 2>/dev/null \
     | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['module']['staticExports']))"
   ```
   — must print `3`.
5. ```bash
   echo 'const p = import("./m"); const url = import.meta.url;' \
     | ./bin/kessel --stdin --module-record 2>/dev/null \
     | python3 -c "import sys,json; d=json.load(sys.stdin); m=d['module']; print(len(m['dynamicImports']), len(m['importMetas']))"
   ```
   — must print `1 1`.
6. `task test:unit` — full pass.
7. `task test:real` — must stay at 467/467.
8. `task test:regression` — 11/11 pass.

## Hard constraints
- Do NOT change the default output shape. With the flag off, existing consumers must see no change.
- Do NOT allocate the 4 arrays unless the flag is on, OR use the Parser's existing allocator (typically arena) — either is fine as long as the default-off path is zero-cost in the JSON output.
- Do NOT compute the module record inside `print_program_ast`. Keep the program emitter pure and emit module record as a separate block in `main` after `print_program_ast`.
- Do NOT create git commits.
- Reuse `emit_span_fields` / `emit_span_leading` and the existing indentation helpers. Do NOT hand-roll JSON.

## Final report
- File(s) changed with a one-line summary per file.
- Full stdout of verification steps 3, 4, 5.
- Confirmation `task test:real` stayed at 467/467.
- Any edge cases left for follow-up (e.g. `export let x = 1` — the exports array should still include `x` with `exportName.kind = "Name"`; if this is not done, note it).
