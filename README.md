# Kessel

A JavaScript / TypeScript / JSX / TSX parser written in [Odin](https://odin-lang.org/) that emits ESTree-compatible JSON ASTs. Targets ES2015–ES2025 syntax with zero runtime dependencies.

Kessel ships in two consumption modes — a standalone CLI and an npm package. Pick whichever fits your call site:

- **CLI** (`bin/kessel`) for shell pipelines, batch parsing, editor integrations.
- **npm package** (`@dvrdlibs/kessel`) for in-process Node.js use via a synchronous FFI binding — no subprocess, no JSON serialization.

## Conformance

Tracked via a port of OXC's coverage harness (`tests/coverage/`) against the standard JS/TS conformance corpora.

| Suite | Positive (parses valid input) | Negative (rejects invalid input) |
|---|---|---|
| test262 | **100.00%** (47 114 / 47 114) | **100.00%** (4 588 / 4 588) |
| Babel | **100.00%** (2 232 / 2 232) | **100.00%** (1 702 / 1 702) |
| TypeScript | **100.00%** (10 773 / 10 773) | **100.00%** (1 629 / 1 629) |
| ESTree | **100.00%** (39 / 39) | — |
| Misc | **100.00%** (88 / 88) | **100.00%** (274 / 274) |

100% positive AND negative on every suite — kessel never fails on valid input
and matches the reference parser on every invalid input in the corpora.

## Language Support

| Feature | Status |
|---|---|
| ES2015–ES2025 | ✅ Full syntax support |
| TypeScript | ✅ Types, interfaces, enums, namespaces, decorators, generics |
| JSX | ✅ Elements, fragments, spread attributes, expression containers |
| TSX | ✅ Type arguments on JSX elements, generic components |
| Decorators (stage 3) | ✅ Member chains, call expressions, type arguments |
| Import attributes (`with`) | ✅ |
| `using` / `await using` | ✅ |

## Codegen

Kessel can emit JavaScript / TypeScript source back from an AST. The same
binary that parses your code can round-trip it through `bin/kessel codegen`
(pretty or `--minified`). The gate compares the ASTs from the original and
regenerated source with positions and comment metadata removed.

Both modes preserve license notices and optimizer annotations attached to
supported calls and functions. Dynamic imports retain webpack, Vite, and
Turbopack hints in both modes. Pretty output also preserves ordinary comments
between statements and class members, around object literal properties, and
inside argument lists for calls, constructors, and dynamic imports. Empty
argument lists, class bodies, static blocks, and object literals retain their comments.

Latest completed optimized round-trip run

| Corpus | Round-trip pass | Known divergences |
|---|---:|---:|
| Spec (in-tree) | 253 / 253 | 0 |
| ESTree | 39 / 39 | 0 |
| Babel | 2 636 / 2 636 | 0 |
| test262 | 44 186 / 44 186 | 0 |
| TypeScript | 17 004 / 17 004 | 0 |

`task test:codegen:full` prints each runnable fixture in both pretty and
minified modes. Both outputs must reparse to the original AST. Known
divergences are tracked in `tests/baselines/codegen_known_failures.txt`.

## Installation

### CLI

Requires [Odin](https://odin-lang.org/docs/install/) (dev-2026-04 or later) and [Task](https://taskfile.dev/).

```bash
task build                    # Release binary → bin/kessel
task build:debug              # Debug binary with bounds checks
task install                  # Symlink bin/kessel into ~/.local/bin
```

### Node.js (npm)

```bash
npm install @dvrdlibs/kessel
```

The install pulls only the platform-specific native binary that matches your host (one of `darwin-arm64`, `darwin-x64`, `linux-arm64`, `linux-x64`, `win32-x64`). The other sub-packages stay on the registry, unfetched. TypeScript declarations ship in the package.

## Usage

### CLI

```bash
# Parse a file — AST as JSON to stdout
bin/kessel parse app.js
bin/kessel parse app.ts --lang=ts
bin/kessel parse component.tsx --lang=tsx

# Compact JSON
bin/kessel parse app.js --compact

# Multi-file parallel parse
bin/kessel parse src/*.js --workers 8 --out-dir tmp/ast

# Tokenize
bin/kessel lex app.js

# Scan module requests and export names
bin/kessel module-lex app.js

# Inspect a regular expression pattern
bin/kessel regexp '(?<word>[a-z]+)' --flags u

# Resolve a package or TypeScript alias from an importing file
bin/kessel resolve lodash --from src/app.js --require
bin/kessel resolve '@app/utils' --from src/app.ts --tsconfig tsconfig.json

# Codegen — emit source back from the AST
bin/kessel codegen app.js
bin/kessel codegen app.js --minified

# Minify JS and JSX expressions and shorten local binding names
bin/kessel minify app.js --sourcemap
bin/kessel minify app.js --no-mangle
bin/kessel minify view.jsx --jsx-pragma=ui.create --jsx-pragma-frag=ui.Fragment

# Lint — walk the AST and report lint diagnostics
bin/kessel lint app.js
bin/kessel lint --list-rules
bin/kessel lint src/*.ts --rule no-console:error --rule eqeqeq:warn
bin/kessel lint app.js --format=json          # also: unix, github, compact, checkstyle
bin/kessel lint app.js --config kessel.lint.json
bin/kessel lint --watch src/*.ts

# Strip TypeScript types and lower supported runtime declarations
bin/kessel strip-types app.ts

# Lower TSX to JavaScript using React.createElement
bin/kessel transform app.tsx --jsx=classic
bin/kessel transform app.tsx --jsx=automatic --jsx-import-source=preact

# Benchmark
bin/kessel microbench parse app.js --iterations 500
bin/kessel microbench parse app.js --iterations 500 --ast-only

# Long-lived server mode (reads paths from stdin, writes framed JSON)
bin/kessel server --compact
```

`kessel fmt <file>` prints JavaScript in the layout of Prettier 3.8.3. It formats
declarations, functions, arrow functions, classes, calls, member chains,
operators, objects, arrays, template literals, destructuring, control flow and
module syntax. Comments between statements, class members, object properties
and switch cases move with the code around them. In TypeScript files it also
formats data declarations with simple type names, qualified names and array
types, including chained assertions such as `as const satisfies Project.Config`.

Use `--print-width 60 --single-quote` to wrap at 60 columns and prefer single
quotes. The defaults are 80 columns and two-space indentation. Use
`--trailing-comma all|es5|none` and `--end-of-line lf|crlf|cr|auto` as in
Prettier. The editor detects the document's line endings automatically.

A statement keeps its original source when the formatter cannot yet print it
as Prettier would. That covers other TypeScript syntax, JSX, decorators,
comments inside an expression or a parameter list, and `prettier-ignore`
targets. A statement also keeps its source when Prettier's layout for it would
change on a second run, so formatting a file twice never changes it. The
output is parsed again before it is returned.

Add `--watch` to `lint`, `fmt`, or `transform` to run once and repeat after saves.
The CLI polls the named paths, including files replaced by an editor's atomic save.
Shell globs select their files when the command starts.
Lint also tracks its explicit or discovered configs and their `extends` chain.
Fixing a syntax error or restoring a missing file triggers another run. Results go
to their usual output streams. JSON lint output emits one array per completed pass.
Use Ctrl-C to stop.

### TypeScript declaration files

Run `kessel dts src/api.ts > api.d.ts` to emit an experimental single-file
declaration. Kessel follows public signatures to the imports and local types
they use, and removes function bodies and unrelated private declarations.
It supports functions, overloads, typed and literal bindings, classes, enums,
interfaces, aliases, namespaces, and re-exports. Diagnostics on stderr give the code and
UTF-8 byte range. A failed emit exits with status 1 and writes no declarations.
Class index signatures and nested or merged namespaces retain private types used
by public signatures. Computed interface and type-literal members can refer to
local or imported keys.

Types are taken from annotations, or inferred the way TypeScript's
`isolatedDeclarations` mode allows: literals, `as` assertions, `as const` arrays
and objects, object literals, function and arrow expressions, a single direct
`return`, parameter defaults, enum constants, and paired accessors. Anything
that needs a type checker is reported with TypeScript's `TS90xx` code instead
of being guessed.

Known differences from TypeScript 5.9.3:

- A file with a parse error or an early error (for example `super` outside a
  method) fails with `Invalid_Syntax` and emits nothing. TypeScript's
  single-file emitter skips those checks and still emits declarations.
- When a file is already rejected, TypeScript sometimes adds diagnostics that
  come from its type checker, such as TS9007 on an arrow function nested in a
  call, TS4094 for mixins, or TS9039 for private names. Kessel reports the
  primary error only.
- Property assignments to a function (`fn.prop = value`) are diagnosed at the
  top level of a file or namespace, not inside nested statements or expressions.
- A generic function type used as a type argument and escapes in template
  literal types are printed by the shared code generator without TypeScript's
  parentheses and escape sequences.

The experimental `module-lex` command emits JSON with imports, re-exports,
`import.meta`, source and defer imports, and export names. Export records
include the local binding when available, including aliased, destructured, and
multiple variable bindings. The scanner also recognizes common TypeScript
declaration exports and external `import = require(...)` declarations.
Spans use UTF-8 byte offsets.

`resolve` prints a JSON object with `kind` and `path`. It uses ESM lookup by
default. Pass `--require` for CommonJS, repeat `--condition` to add package
conditions, or repeat `--main-field` to set the order of legacy entry fields
such as `module` and `main`. Repeat `--alias name=target` for explicit module
aliases. A trailing `$` on a name makes the alias match only that specifier.
Use `--no-main-fields` to skip legacy manifest entries and try directory entry names directly.
Projects with custom package directories can repeat `--module-dir`. For example,
`--module-dir vendor --module-dir node_modules` checks every ancestor's
`vendor` directory before looking in `node_modules`. Absolute directories are
checked once. Use `--no-module-dirs` to disable package directory lookup.
For CommonJS lookups and legacy package entries, repeat `--extension` to set
the suffix order and `--main-file` to set directory entry names. For example,
`--extension .ts --extension .js --main-file index` tries `index.ts` before
`index.js` in a directory. Pass `--no-extensions` or `--no-main-files` to
disable the corresponding search. Relative ESM imports and explicit package
export and import targets still require exact paths.
Use `--exports-fields '["exports",["tooling","public"]]'` to select the first
present package export map. Use `--imports-fields '[["tooling","private"],"imports"]'`
to search private import maps in order. A nested array names a path in
`package.json`. An empty list disables that map lookup.
An explicit suffix can opt into substitution. For example,
`--extension-alias .js=.ts,.js` resolves a request for `./entry.js` to
`entry.ts` first, then `entry.js`. The order also applies to explicit package
entry paths. An empty replacement tries the filename without its suffix.

The enhanced-resolve lookup options are available too. `--root <directory>`
looks a server-relative request such as `/assets/logo.js` up below each root
before the filesystem root, or after it with `--prefer-absolute`.
`--prefer-relative` tries a bare request beside the importer before package
lookup. `--fallback name=target` is tried only after a request failed. Repeat
a name for several targets, and use `--fallback-ignore name` to report the
request as ignored. `--restriction <directory>` and `--restriction-regex
<pattern>` hide candidate files outside them, so lookup continues with the next
candidate. `--fully-specified` and `--no-fully-specified` override whether a
request must name its file exactly, which defaults to the Node rule of the
mode. `--resolve-to-context` resolves a directory. `--explicit-conditions`
selects package map targets with the given `--condition` names and `default`
only. `--tsconfig-references` lets a project listed under `references` supply
the paths for the files below it.

Pass `--browser` for the browser export condition and package browser field
remaps. An ignored module produces `{"kind":"ignored","path":""}`.
An explicit `--tsconfig` adds TypeScript path
aliases and bundler-style source extension lookup for mapped targets. With
`rootDirs: ["src", "generated"]`, a relative import of `./theme.css` from
`src/app.ts` can resolve to `generated/theme.d.css.ts`. Kessel checks the
import’s physical directory first, then the other roots in declaration order.

`regexp` accepts a pattern without slash delimiters and emits a JSON tree.
Use the `root`, `first_child`, and `next_sibling` indices to traverse it. Index
zero marks an absent link. Node spans use UTF-8 byte offsets.

Errors are pretty-printed (rustc-style) by default with stable K-codes
(`K1xxx` lexer, `K2xxx`/`K3xxx` parser, `K4xxx` TypeScript-specific). Pass
`--json` for machine-readable output, or set `KESSEL_COLOR=0` /
`--color=false` to disable ANSI color.

### Node.js

```js
const { parseSync, parseAsync } = require('@dvrdlibs/kessel');

const { program, errors } = parseSync(
  'Counter.tsx',
  'export const Counter = ({ initial = 0 }: { initial?: number }) => <button>{initial}</button>;'
);

// Non-blocking: runs on the libuv worker pool, off the main event loop.
const { program: p2, errors: e2 } = await parseAsync('app.ts', src);
```

Each error carries a stable `code` (e.g. `K3010`) and `severity` field for
programmatic handling. Full API and visitor helpers documented in
[`npm/kessel/README.md`](npm/kessel/README.md).

### Odin package

Kessel is one Odin package (`src/`). Import it and you get the typed AST in
process, without JSON and without a subprocess:

```odin
import kessel "path/to/kessel/src"

State :: struct {
    query:     ^kessel.ScopeQuery,
    positions: ^kessel.SourcePositions,
}

compile :: proc(source: string) -> bool {
    // Parse. The job owns one arena holding the whole AST; `parse_job_close`
    // releases all of it, so AST pointers are valid until then.
    job: kessel.ParseJob
    config := kessel.ParseConfig{lang_override = kessel.Lang.JSX}
    if !kessel.parse_job_open_inline(&job, source, config, "app.jsx") { return false }
    defer kessel.parse_job_close(&job)
    kessel.parse_job_run(&job)
    if len(job.parser.errors) != 0 { return false }   // start/end are byte offsets

    // `#!...` first line, if any.
    if hashbang, present := job.program.hashbang.?; present { _ = hashbang.value }

    // Scopes: bindings and references, queried by the `loc` of a node.
    model := kessel.semantic_build(job.program, source, job.lang, job.arena_alloc)
    query: kessel.ScopeQuery
    kessel.scope_query_init(&query, &model, job.arena_alloc)
    defer kessel.scope_query_destroy(&query)

    // Byte offsets -> 1-based line, 0-based UTF-16 column, and back.
    positions: kessel.SourcePositions
    if !kessel.source_positions_init(&positions, source, context.allocator) { return false }
    defer kessel.source_positions_destroy(&positions)

    // Walk the tree. `.Skip` leaves out a subtree, `.Stop` ends the walk.
    state := State{query = &query, positions = &positions}
    status := kessel.ast_walk(job.program, {user = &state, enter = enter}, context.allocator)
    return status == .Completed
}

enter :: proc(user: rawptr, node: kessel.AstNode) -> kessel.AstWalkAction {
    state := cast(^State)user
    #partial switch n in node {
    case ^kessel.JSXElement:
        where_ := kessel.source_position_at(state.positions, n.loc.start)
        function, inside := kessel.scope_query_enclosing_function(state.query, n.loc)
        _, _, _ = where_, function, inside
    case ^kessel.JSXText:
        _ = n.value                       // entity-decoded; n.raw is the source text
    case ^kessel.JSXSpreadChild:
        _ = n.expression                  // `{...xs}` as a child
    case ^kessel.Identifier:
        symbol := kessel.scope_query_symbol_at(state.query, n.loc)
        _ = symbol                        // SYMBOL_UNRESOLVED for a global
    case ^kessel.FunctionParameter:
        view := kessel.function_parameter_view(n)   // {target, default_value}
        _ = view
    case ^kessel.TSTypeAnnotation:
        return .Skip                      // not interested in types
    }
    return .Continue
}
```

| API | File | What it gives you |
|---|---|---|
| `parse_job_open_inline`, `parse_job_run`, `parse_job_close` | `src/parse_job.odin` | `job.program`, `job.parser.errors`; one arena per job |
| `Program.hashbang` | `src/ast.odin` | The `#!` line as `Maybe(Hashbang)` |
| `ast_walk`, `ast_walk_statement_tree`, `ast_walk_expression_tree`, `ast_node_loc` | `src/ast_walk.odin` | Enter/leave over typed `AstNode`s. Depth-bounded (`PARSE_RESOURCE_AST_DEPTH`, 512); long `a + b + ...` and `a.b().c` chains use a loop, not the stack |
| `function_parameter_view` | `src/function_parameter.odin` | Target and default of a parameter, however the parser stored it |
| `semantic_build` | `src/semantic.odin` | Scope tree, symbols, references |
| `scope_query_symbol_at`, `scope_query_references`, `scope_query_bindings_named`, `scope_query_enclosing_function`, ... | `src/scope_query.odin` | Which binding an identifier or JSX tag declares or uses; all uses of a binding; the function around a node |
| `source_position_at`, `source_offset_at` | `src/positions.odin` | Byte offset <-> (line, UTF-16 column); CRLF, CR, U+2028/9, BOM and astral characters handled |
| `sourcemap_builder_*` | `src/sourcemap_builder.odin` | Source Map v3: sources, names, mappings in any order, JSON out |
| `jsx_decode_entities` | `src/jsx_entities.odin` | The decoder behind `JSXText.value` |

Conventions worth knowing: every `Loc` and diagnostic span is a UTF-8 byte
offset (the JSON emitter converts to UTF-16; use `source_position_at` to do
the same); source-map lines and columns are 0-based while
`source_position_at` lines are 1-based; strings in the AST point into the
source or the job's arena and die with the job.

[`tests/library/consumer`](tests/library/consumer/main.odin) is a complete
program using all of the above; `task test:library` builds it and checks its
output against oxc-parser, Babel and `source-map-js`. The same task compiles
and runs the snippet above, so it cannot drift from the API.

### CLI Flags

| Flag | Description |
|---|---|
| `--compact` | Minified JSON output |
| `--lang=js\|jsx\|ts\|tsx` | Override language detection |
| `--source-type=script\|module` | Force source type (default: auto-detect) |
| `--loc` | Emit ESTree `loc` (line/column) on every node |
| `--range` | Emit ESLint-style `range: [start, end]` |
| `--preserve-parens` | Wrap `(expr)` in ParenthesizedExpression nodes |
| `--show-semantic-errors` | Run the semantic checker (pass 3) |
| `--max-depth=N` | Reject source nested deeper than `N` levels with one `K2081` diagnostic instead of risking a stack overflow. Default 512. Operator, member and call chains (`a+b+c`, `a.b.c`, `a()()`) do not count and may be arbitrarily long |
| `--ast-only` | Skip semantic checks (for benchmarking) |
| `--ast-type=js\|ts\|auto` | Force ESTree shape (JS or TS fields) |
| `--module-record` | Emit static import/export module record |
| `--json` | Emit errors as JSON instead of the pretty renderer |
| `--color=<bool>` | Force color on/off (overrides `KESSEL_COLOR` env) |

### Linting (`kessel lint`)

Built-in rules walk the finished AST as pass 4 (opt-in). Most correctness
rules are default-on; style/restriction rules are default-off and enabled
explicitly. Every rule is addressable by its ESLint-style kebab-case name.
Use `kessel lint --list-rules` to see the registered names, codes, and defaults.
`task lint:parity:report` compares registered names against the pinned oxlint
rule inventory.

In `.oxlintrc.json`, `"plugins": ["react"]` enables
`react/exhaustive-deps` at the correctness category's severity (warning by
default). Set `"categories": { "pedantic": "warn" }` to enable
`react/rules-of-hooks` as well. An override can enable the plugin for a file
glob. Rule-specific settings take precedence over the category defaults.

Enable `react/rules-of-hooks` to flag hook calls in ordinary functions, loops,
or branches that can skip a hook between renders. For example,
`kessel lint View.tsx --rule react/rules-of-hooks:warn` reports a conditional
`useEffect` call. Setting the rule in a workspace's `.oxlintrc.json` also
enables the diagnostic on unsaved buffers in the development extension.

Enable `react/exhaustive-deps` to check dependencies captured by `useEffect`,
`useLayoutEffect`, `useMemo`, `useCallback` and `useImperativeHandle`. A missing
dependency highlights the array. In the editor, its related locations point to
the values read by the callback. To check custom hooks as well, use a rule
setting such as `["warn", { "additionalHooks": "^useRemoteEffect$" }]`.
Pass both `--fix-suggestions` and `--fix-dangerously` to add missing entries
and remove duplicate or unnecessary dependencies. These edits can change when
an effect runs. For an inline `useMemo` or `useCallback` with no array, Kessel
can create one from the values the callback reads.

| Flag | Description |
|---|---|
| `--rule <name>:off\|warn\|error` | Override a rule's severity (repeatable) |
| `--config <file>`, `-c <file>` | Use one configuration for every input |
| `--disable-nested-config` | Use the discovered root configuration for every input |
| `--fix` | Remove debugger statements, apply safe strict equality comparisons, and convert eligible `let` declarations to `const` |
| `--fix-suggestions` | Remove reported unused disable comments and unused rule names |
| `--fix-dangerously` | Allow strict equality edits that may change coercion behavior |
| `--format=<fmt>` | Output format: `default`, `json`, `unix`, `github`, `compact`, `checkstyle`, `gitlab`, `junit` |
| `--quiet` | Report errors only — warnings are neither printed nor counted toward the exit code |
| `--max-warnings <N>` | Return non-zero only if the warning total exceeds `N` (CI gate) |
| `--deny\|--warn\|--allow <name>` | Shorthand for `--rule name:error\|warn\|off` |

By default kessel is stricter than ESLint: **any** diagnostic (error or
warning) yields a non-zero exit. `--quiet` and `--max-warnings` opt into the
looser ESLint-style policy where warnings are tolerated.

Kessel searches upward from the working directory for `kessel.lint.json` or
`.oxlintrc.json`. The Kessel file takes priority when both exist in one
directory. Each input within that project uses its nearest configuration.
A nested configuration can inherit the root settings through `extends`.
An explicit CLI rule level takes priority over matching file overrides.

The assignment rules resolve each name to its declaration. For example,
`no-import-assign` flags writes to an imported namespace, including
`Reflect.set(ns, key, value)`. A function parameter also named `ns` has
its own binding. `no-const-assign` covers both `const` and `using`.
Enable `no-undef` for unresolved names in JavaScript and JSX.

Use `globals` to declare names supplied by your application. A `readonly`
name can be read, and `no-global-assign` reports writes to it. A `writable`
name can also be reassigned. Use `env` to load host globals such as Node's
`process`, the browser's `document`, or Jest's `describe`. Both fields
work in per-file overrides.

Enable `prefer-const` to find `let` bindings that are never reassigned.
Set `["warn", {"destructuring": "all", "ignoreReadBeforeAssign": true}]`
to report a destructuring pattern only when all its bindings qualify and
skip variables read before initialization. The fixer changes the keyword
when every binding in the declaration can use `const`. A separate first
assignment or a direct `eval` in scope keeps the declaration editable by hand.

Fix modes operate on each file's enabled rules. For example,
`kessel lint --fix -D eqeqeq app.js` changes `1 == 2` to `1 === 2`.
Use `--fix-suggestions --report-unused-disable-directives` to clean up
suppressions. Combine all three flags to apply all available edits.
Kessel reparses each edit pass and reports diagnostics at their final
locations. Input with syntax errors is preserved. The CLI replaces each
changed file atomically, follows symlinks, and skips replacement if it
would split a hard link.

With `--format=json`, stderr contains one array for the entire invocation.
Each linted file has a `messages` array. A syntax error carries `fatal: true`
and a null `ruleId`. The exit status still reflects `--max-warnings`.

Both filenames support the rules, ignores and overrides shown below. Kessel
recognizes rule names listed by `kessel lint --list-rules` and accepts string
levels, numeric levels from 0 to 2, and single-element severity arrays. The
`eqeqeq` rule also accepts `["warn", "smart"]` for literal, `typeof`, and
null comparisons, or `["error", "always", {"null": "ignore"}]` for a
null-specific exception. The `null` setting accepts `always`, `ignore`,
and `never`.

A rule name may carry its oxlint plugin, as in `unicorn/no-new-array`,
`oxc/erasing-op` or `@typescript-eslint/no-this-alias`. In an `.oxlintrc.json`,
`categories` and `plugins` select rules the way oxlint does: `correctness` is on
at `warn` unless the file changes it, the other categories are off, and the
`typescript`, `unicorn` and `oxc` plugins are active unless `plugins` lists
others. A category only switches on rules whose diagnostics match the pinned
oxlint on every compared upstream fixture (`tests/lint/upstream_parity.json`).
Every other rule still needs its own entry under `rules`. `kessel.lint.json`
and runs without a config keep Kessel's own defaults.

Enable `no-console` to report reads, calls, and assignments to statically named
properties on the global console. For example, `["warn", {"allow": ["warn",
"error"]}]` permits those two methods. Locally declared and imported consoles are exempt.
With `--fix-suggestions`, Kessel can remove a standalone call and its arguments.
Removing a call used as a value also requires `--fix-dangerously`.

```json
{
  "ignorePatterns": ["dist", "*.min.js"],
  "env": { "browser": true },
  "globals": { "APP_VERSION": "readonly" },
  "rules": { "eqeqeq": "error", "no-console": "warn", "no-debugger": "off" },
  "overrides": [
    { "files": ["*.test.js"], "env": { "jest": true }, "rules": { "no-debugger": "error" } }
  ]
}
```

Glob patterns in `ignorePatterns` support `*` (any run, including `/`) and `?`
(one character), matched against the project-relative path and the basename; a literal name
like `dist` matches an exact path, basename, prefix, or interior segment. Each
`overrides` block layers its `rules` on top of the base rules for files matching
one of its `files` globs (more specific wins). An `"extends": "./base.json"`
key (string or array) inherits one or more parent configs first, resolved
relative to the config file, so the child's own settings override them.
For `.oxlintrc.json`, define top-level `globals` and `env` in the selected
file. Like the pinned oxlint, Kessel inherits parent rules and matching
overrides while taking those two top-level fields from the child. Standard
ECMAScript globals are available even with an empty environment. When two
hosts disagree about writability, Kessel uses the alphabetically first
matching host. For example, AMD and PhantomJS disagree on `require`.
Set its access in `globals` to get the same result across tools.

Lint accepts both `eslint-` and `oxlint-` comment directives. For example, a
next-line directive can name a rule and explain why the line is exempt.

```js
// oxlint-disable-next-line no-console -- print the CLI result
console.log(x);

/* eslint-disable no-debugger */
debugger;
/* eslint-enable no-debugger */
```

A bare `// oxlint-disable` opens a range for all rules. `disable-line` and
`disable-next-line` apply to one line. With `.oxlintrc.json`, a bare `enable`
closes the blanket range, and a named `enable` closes the range opened with
that rule name. Both ranges can be active at once. With `kessel.lint.json`
or standalone defaults, a bare `enable` restores all rules.

Pass `--report-unused-disable-directives` to see warnings for unused directives
and unused names within a directive. Set the level with
`--report-unused-disable-directives-severity off|warn|error` or the
`options.reportUnusedDisableDirectives` field in `kessel.lint.json`.


## Tests

```bash
task test                     # Primary gate — coverage + unit (~12s)
task test:quick               # Fast dev loop — unit + regression (~8s)
task test:release             # Zero-tolerance pre-release chain (~13 min)
```

| Command | What it tests |
|---|---|
| `task test:coverage` | 62K fixtures across test262/Babel/TS/ESTree/misc (24 Odin test procs) |
| `task test:unit` | 291 positive-fixture golden-output tests |
| `task test:regression` | 11 structural regression checks |
| `task test:real` | 467 real-world JS files — no crashes, no unexpected errors |
| `task test:estree` | String-escape decoding parity vs reference parser |
| `task test:fuzz` | 100 random valid programs, diff vs reference |
| `task test:fuzz:invalid` | 300 mutated/invalid inputs — no crashes or hangs |
| `task test:codegen` | Spec-corpus round-trip: parse → codegen → re-parse → AST equality (~2s) |
| `task test:codegen:full` | Pretty and minified round trips across spec, ESTree, Babel, test262, and TypeScript (~73K fixtures) |
| `task test:watch` | CLI watch lifecycle, atomic saves, configuration changes, error recovery, and autofix |
| `task test:format` | Statement, expression, comment, module and data-literal formatting against Prettier 3.8.3 fixtures, idempotence, source preservation, and CLI errors |
| `task test:format:real` | Check that formatted files in the 467-file release corpus retain their syntax tree and comments and stay unchanged on a second pass |
| `task test:transform:reference` | Execute classic and automatic JSX fixtures and compare runtime behavior with the pinned OXC transformer |
| `task test:bench:regression` | 10 curated files vs baselines, fails on >5% regression |
| `task test:conformance:report` | Print conformance summary from snap files |

To compare formatter output directly with an installed Prettier 3.8.3, set
`KESSEL_PRETTIER` to its absolute package directory and run `task test:format`.

### OXC Oracle

Diff, fuzz, and benchmark comparisons use a pinned OXC oracle. The Rust
comparison binaries read the local checkout at `../oxc`, which must be at the
full SHA recorded in `OXC_ORACLE.json`; `task bench:oxc:verify` checks this
before rebuilding. The same manifest records the exact npm `oxc-parser`
version expected by JS-side deep-diff and fuzz checks.

The `commit:` header inside coverage snapshots is the vendored corpus
reference for that suite, not the local OXC checkout pin.

## Architecture

Three-pass pipeline:

1. **Lexer** (`src/lexer.odin`) — SIMD-accelerated tokenizer. Two-token lookahead. Cross-platform SIMD via Odin's `core:simd` (NEON on ARM64, SSE2 on x86-64, scalar fallback elsewhere). 16-byte `FastToken` by value. Cache-line-tuned hot fields.

2. **Parser** (`src/parser.odin`) — Hand-written Pratt recursive descent. Arena-only allocation. Builds the AST and enforces the subset of ECMA-262 / TypeScript early errors that belong at parser level (overload chains, ambient restrictions, accessor shapes, etc.). Does not implement TypeScript type-system checks — those are downstream.

3. **Semantic Checker** (`src/checker.odin`) — Walks the finished AST. Enforces ECMA-262 early errors (break/continue context, label scoping, duplicate bindings, strict-mode restrictions, etc.). Opt-in via `--show-semantic-errors`.

### Implementation notes

- **SIMD lexer** — cross-platform 128-bit SIMD (SSE2 on x86-64, NEON on ARM64, scalar fallback elsewhere) via Odin's portable `core:simd`, for string scanning, identifier scanning, whitespace, and comment skipping.
- **Arena-only memory** — single bump allocator, no malloc during parse, no GC.
- **16-byte FastToken** — passed by value between lexer and parser, fits in a register pair.
- **Perfect-hash keyword lookup** — 268-entry table, O(1) with 3-byte verification.
- **Lazy two-token lookahead** — `nxt` is only lexed on demand, eliminating a 16-byte copy on roughly 90% of advances.
- **Apple Silicon QoS pinning** — P-core bias via `pthread_set_qos_class_self_np`.

### Source Layout

| File | Purpose |
|---|---|
| `src/parser.odin` | Pratt parser core: `Parser` struct, arena, string interner, scope maps, entry points |
| `src/parser_expr.odin` | Expressions section (Pratt precedence climbing) |
| `src/parser_stmt.odin` | Statements + Declarations sections |
| `src/parser_module.odin` | Module Import/Export + scope verification + TS declaration-conflict checking |
| `src/parser_ts_types.odin` | TypeScript type parsing |
| `src/parser_jsx.odin` | JSX / TSX parsing |
| `src/checker.odin` | AST-walker semantic checker (pass 3) |
| `src/emitter.odin` | ESTree JSON emitter with owned state |
| `src/binary_emitter.odin` | Compact binary AST emitter (consumed by the npm package) |
| `src/codegen.odin` | AST → JS source emitter (incl. `--minified`) |
| `src/diagnostic.odin` | K-code diagnostics model (codes + severity) |
| `src/diagnostic_render.odin` | Pretty (rustc-style) error renderer |
| `src/lexer.odin` | SIMD lexer, two-token lookahead |
| `src/regex.odin` | ES2025 §22.2.1 regex pattern validator |
| `src/regex_ast.odin` | Regexp tree, character values, and syntax diagnostics |
| `src/module_lexer.odin` | AST-free module dependency and export scan |
| `src/module_resolver*.odin` | Node, browser, and TypeScript module resolution |
| `src/ast.odin` | All AST struct/union definitions |
| `src/raw_transfer.odin` | Zero-copy binary AST buffer wire format |
| `src/main.odin` | CLI dispatch + worker pool + server mode |
| `src/lib_exports.odin` | Shared-library exports for the npm FFI |
| `src/sourcemap.odin` | Source map for the printer's own output |
| `src/sourcemap_builder.odin` | Source Map v3 builder (sources, names, mappings) and the shared VLQ encoder |
| `src/ast_walk.odin` | Typed, depth-bounded AST walk with enter/leave |
| `src/function_parameter.odin` | One view of a parameter's target and default value |
| `src/scope_query.odin` | Scope queries by source position, on top of `src/semantic.odin` |
| `src/positions.odin` | Byte offset <-> line / UTF-16 column |
| `src/simd.odin` | Cross-platform SIMD intrinsics |
| `src/parse_job.odin` | Source → parsed Program deep module |
| `src/token.odin` | `TokenType` enum, `FastToken`, `LiteralValue` |
| `src/unicode_tables.odin` | ID_Start / ID_Continue range tables |
| `src/cli_config.odin` | `CliConfig` struct + flag parser |
| `src/source_io*.odin` | Cross-platform source reader (mmap on POSIX, stub on Windows) |
| `src/qos_darwin.odin` | Apple Silicon QoS P-core pinning |

## Roadmap

Kessel is the first piece of a broader JS/TS toolchain. The parser and
semantic checker pass the pinned conformance suites. The latest printer
results are in the [codegen section](#codegen).

| Phase | Surface | Status |
|---|---|---|
| 1 | SIMD lexer | ✅ Complete |
| 2 | Pratt parser (ES2015–ES2025, TS, JSX/TSX) | ✅ Complete |
| 3 | Semantic checker (ECMA-262 early errors) | ✅ Complete |
| — | Codegen + source maps + binary/raw-transfer emitters | Implemented, codegen parity in progress |
| 4 | **Linter (`kessel lint`)** | 🚧 Built-in lint rules with a pinned oxlint parity inventory |
| 5 | Transformer (`kessel transform`, `transformSync`) | TypeScript lowering, classic and automatic JSX runtimes, and build-time global replacements. Target lowering, decorators, and React Refresh remain open. |
| 6 | Semantic model · CFG · resolver · module lexer · regexp AST | In progress |
| 7 | Formatter (`kessel fmt`, `formatSync`) | Prints JavaScript statements, expressions and classes in Prettier 3.8.3's layout, with comments that stand between list items. TypeScript syntax, JSX layout, decorators and comments inside expressions remain open and keep their source. |
| 8 | Minifier + mangler (`kessel minify`, `minifySync`) | Experimental. Folds JS and JSX numeric and boolean expressions, joins adjacent declarations, and shortens local JS and JSX bindings. Preserves JSX tag semantics and factory pragmas. TypeScript retains its binding names and initializer expressions for type inference. |
| 9 | Isolated declarations (`kessel dts`, `isolatedDeclarationSync`) | Experimental. Compared with TypeScript 5.9.3 on its whole compiler and conformance fixture directories; every emitter difference is recorded in `tests/baselines/dts_typescript_differences.txt`. Files with early errors are rejected, and checker-dependent secondary diagnostics are not reproduced. |
| 10 | Bundler + language server | The local VS Code extension shows diagnostics, offers fixes and rule-specific suppressions, applies safe fixes on save, and formats module declarations and data literals. Bundling remains planned. |

Run `task build:vscode` to create an installable VSIX for your platform.
Run `task test:vscode` to exercise the installed extension in a disposable VS Code profile.

### Browser playground

Build the standalone playground with `task build:wasm` using Odin and `wasm-ld`.
Serve it with `python3 -m http.server 8080 --bind 127.0.0.1 --directory bin/playground`
and open `http://localhost:8080`. The files in `bin/playground/` can also be served
from any static host. The browser worker parses JS, JSX, TS and TSX locally and
displays the same ESTree JSON and optional semantic diagnostics as the CLI.
The Formatted tab previews the native formatter and downloads the result
as a source file. Each document can contain up to 256 KiB of UTF-8. Downloads
include the complete result when the preview is truncated.

To embed the parser, copy `parser.mjs` and `kessel.wasm` together and use the module
in a browser or worker with Web Crypto. Each instance can parse multiple documents.

```js
import { createParser } from './parser.mjs';

const bytes = await (await fetch('./kessel.wasm')).arrayBuffer();
const parser = createParser(await WebAssembly.compile(bytes));
const tree = parser.parse('const id: number = 1;', { language: 'ts', semanticErrors: true });
const formatted = parser.format("export{type Id}from'./model';", { language: 'ts', singleQuote: true });
```

The formatter accepts the same layout options as the Node SDK. Syntax errors
carry code `Invalid_Syntax` and an `offset` in UTF-8 bytes.
`task test:wasm` checks parser and formatter output, UTF-8 limits and repeated calls.
For the UI test, run `npm ci --prefix playground`, install the pinned browser with
`(cd playground && npx playwright install --only-shell chromium)`, then run
`task test:wasm:browser`.

**Mission:** full feature parity with the entire [OXC suite](https://oxc.rs)
— parser, linter, transformer, formatter, minifier, resolver, isolated
declarations, semantic analysis, and Node/WASM bindings. The exhaustive
component-by-component breakdown of all remaining work lives in `HANDOFF.md`
under "OXC Suite Parity — Master Roadmap".

The transformer's first capability, `kessel strip-types`, erases TypeScript
syntax from TS/TSX input (type annotations, generics, interfaces, type aliases, `as` / `satisfies`
/ non-null / type-assertion expressions, type-only imports/exports, `declare`,
class-member modifiers, abstract/overload members). It also lowers supported
runtime constructs such as enums, namespaces, and parameter properties. Namespace
exports share an object across merged declarations. Files whose only ES module
declarations erase retain their module scope through an empty export. When an ES
module uses TypeScript's `import = require()` syntax, the generated JavaScript
uses Node's `createRequire(import.meta.url)` to resolve the dependency. In derived
constructors, parameter-property assignments run after `super()` initializes
the instance.

Use a repeatable `--define` option to replace globals at build time.

```sh
kessel transform app.tsx --jsx=classic --define 'process.env.NODE_ENV="production"' --define '__DEV__=false'
```

Each value is a JavaScript expression. Kessel resolves names after TypeScript
and JSX lowering, so function parameters and other local bindings keep their
values. A rule for `import.meta.env.*` supplies a fallback for static property
accesses. An exact property rule takes precedence. A key such as `typeof DEBUG`
replaces the entire `typeof` expression.

Pass `--lower-using` to lower `using` and `await using` for older runtimes.
The generated code registers disposers as declarations execute and releases them
in reverse order when a block, loop iteration, function, or module exits.
Top-level resources keep ES module exports live during initialization and cleanup.

Pass `--optimize-const-enums` to `kessel transform` to inline constant enum
member reads and omit local enum objects when all uses were replaced.
Exported enums retain their runtime object. The default keeps runtime enums.

`kessel transform` supports the same TypeScript lowering and preserves JSX by
default. Pass `--jsx=classic` for `React.createElement`. Set the factory and
fragment bindings with `--jsx-pragma=ui.make` and `--jsx-pragma-frag=ui.Fragment`,
or with leading `@jsx` and `@jsxFrag` comments. Use `--sourcemap` for an inline
source map, `--jsx-no-pure` to omit pure-call annotations, and
`--jsx-allow-namespaces` to emit namespaced tags as strings.

Use `--jsx=automatic` to generate imports from `react/jsx-runtime` in ES
modules and `require` calls in scripts. Select another runtime with
`--jsx-import-source=preact` or a leading `@jsxImportSource` comment. A
leading `@jsxRuntime classic` or `@jsxRuntime automatic` can override the
selected runtime for one file.

Add `--jsx-development` to either runtime to record the original filename,
line, and column for each element. Automatic mode uses `jsxDEV` from
`jsx-dev-runtime`. Classic mode supplies the `__source` and `__self` props.

## Releases

The npm package is published automatically on every push to `main` whose conventional-commit subject implies a real change:

- `feat:` / `refactor:` → minor bump
- `feat!:` / `refactor!:` / `BREAKING CHANGE` → major bump
- `fix:` / `perf:` / `chore:` / etc. → patch bump
- Docs-only and CI-only commits don't trigger a release

Pull requests targeting `main` run the full local release gate on GitHub Actions.
The release workflow repeats the gate on the revision it will publish. It
downloads the 467 checksum-pinned real-world inputs and compares the candidate
and reference parser on the same runner. The npm checks parse the same corpus
through both asynchronous execution paths.

The pipeline (`.github/workflows/release.yml`) builds and smoke-tests the CLI
for all five targets and uploads the executables as Actions artifacts. It also
builds the native libraries, publishes the five `@dvrdlibs/kessel-<target>` sub-packages with Sigstore provenance, then publishes the main `@dvrdlibs/kessel` package with `optionalDependencies` pinned to the same version. If any sub-package fails to publish, the main package stays at its previous version and users are unaffected.

Manual override: `gh workflow run Release --repo dvrd/kessel`.

## Attribution

Kessel uses [OXC](https://github.com/oxc-project/oxc) extensively as a
reference implementation and comparison oracle. The conformance harness in
`tests/coverage/` is a port of OXC's coverage tooling, and the regression,
deep-diff, fuzz, and benchmark checks compare Kessel against pinned OXC parser
artifacts.

Kessel is an independent Odin implementation and does not depend on OXC at
runtime. OXC is MIT-licensed; see the OXC project for its source and license.

## License

MIT
