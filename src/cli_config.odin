// ============================================================================
// cli_config.odin — CLI option state, grouped and passed explicitly
// ============================================================================
//
// Pre-#6 the CLI option state lived as 12 separate process-global
// variables in main.odin. The CLI flag parser mutated them; the parse
// and emit modules read them via parse_config_from_globals /
// emit_config_from_globals. Multi-file workers and helper functions had
// to reason about ambient state, server mode made them sticky by design,
// and tests could not construct exact configurations without mutating
// the same globals.
//
// This module replaces those 12 globals with one CliConfig value. The
// CLI flag parser fills it; commands take it as a parameter; snapshot
// procs (parse_config_from_cli, emit_config_from_cli) read from it
// instead of from globals. A fresh `cli_config_default()` is built per
// command, so no state can leak between commands within one process.
//
// Bugs this fixes:
//   * `kessel server --compact` (and every other parse-flag combo)
//     now actually works. Pre-#6 the server case had no flag parser
//     despite the doc-comment claiming flags are sticky.
//   * Per-command default consistency. Pre-#6 only 3 of the 12 globals
//     were re-initialised at the top of `case "parse":`; the rest
//     could leak from a prior dispatch (irrelevant today because the
//     CLI exits after one command, but a real risk for any in-process
//     test driver or future REPL).
//   * Test surface. A test can now build a CliConfig directly and
//     call parse_file(path, cfg) without mutating any global.
//
// Scope intentionally NOT expanded: this is structural cleanup, not
// a CLI-library rewrite. The hand-rolled flag-parsing loop stays;
// each subcommand owns its command-specific flags (--workers,
// --out-dir, --raw, --iterations, etc.) outside the CliConfig.

package kessel

import "core:fmt"
import "core:os"
import "core:strings"

// ============================================================================
// CliConfig — every CLI option that affects parse / emit semantics
// ============================================================================
//
// Field grouping (top-down by audience):
//   1. Output mode      — read by emitter
//   2. ESTree shape     — read by emitter
//   3. Parse mode       — read by parse_job
//   4. Semantic checks  — read by parser today, checker tomorrow (#3)
//
// Fields with non-zero defaults are documented in cli_config_default.
// Other fields default to false / nil / "" and become "off" semantically.
CliConfig :: struct {
	// Output mode
	compact:              bool,         // --compact
	error_format:         string,       // --errors=kessel|oxc

	// ESTree shape
	emit_loc:             bool,         // --loc
	emit_range:           bool,         // --range
	emit_module_record:   bool,         // --module-record
	ast_type:             AstType,      // --ast-type=auto|js|ts

	// Parse mode
	lang_override:        Maybe(Lang),       // --lang=js|jsx|ts|tsx
	source_type_override: Maybe(SourceType), // --source-type=script|module|unambiguous
	strict_source_type:   bool,         // --strict-source-type
	force_strict:         bool,         // --force-strict
	preserve_parens:      bool,         // --preserve-parens

	// Semantic checks (currently dead — wires up in #3, the checker
	// migration). Kept here as a documented field so the CLI flag
	// continues to be accepted and the migration path is visible.
	show_semantic_errors: bool,         // --show-semantic-errors

	// Output / diagnostic surfaces.
	//
	// `kessel parse FILE` defaults to human-friendly rendering: pretty
	// diagnostics on stderr, no AST on stdout. Tooling that wants the
	// AST opts in with `--json`; tooling that wants the legacy stats
	// footer opts in with `--stats`. This mirrors rustc / tsc / biome /
	// ruff: human by default, machine when asked.
	emit_json:            bool,         // --json — print AST as JSON to stdout
	show_stats:           bool,         // --stats — print arena + error count to stderr

	// ANSI color in pretty diagnostics. Resolution order, highest wins:
	//   1. --color=true | --color=false  (CLI flag, strictest priority)
	//   2. KESSEL_COLOR=1 | KESSEL_COLOR=0  (env var)
	//   3. default: true
	// Invalid values at either level are a startup error — we do NOT
	// silently fall back, because silent fallback hides typos.
	color:                bool,         // resolved value, populated by cli_config_default
}

// Build a CliConfig with the documented defaults.
//
//   error_format = "kessel"  // legacy shape; --errors=oxc opts in
//   ast_type     = .Auto     // emitter resolves from parse Lang
//   color        = true      // overridable by KESSEL_COLOR=0 or --color=false
//
// `color` is resolved from the KESSEL_COLOR env var at this layer so
// every command starts with the env-aware value; --color= later in
// cli_try_parse_flag overrides it.
//
// Every other field defaults to its zero value (false / nil).
cli_config_default :: proc() -> CliConfig {
	return CliConfig{
		error_format = "kessel",
		ast_type     = .Auto,
		color        = resolve_color_from_env(),
	}
}

// resolve_color_from_env reads `KESSEL_COLOR` and returns the resolved
// default. Accepts only "1" (on) or "0" (off). Empty / unset returns
// the baseline default (`true`). Any other value is a startup error.
@(private="file")
resolve_color_from_env :: proc() -> bool {
	val, has := os.lookup_env("KESSEL_COLOR", context.temp_allocator)
	if !has || len(val) == 0 {
		return true
	}
	switch val {
	case "1": return true
	case "0": return false
	}
	fmt.eprintf("error: KESSEL_COLOR=%s is not valid (use 1 or 0)\n", val)
	os.exit(2)
}

// ============================================================================
// Flag parsing
// ============================================================================
//
// cli_try_parse_flag attempts to consume one CliConfig-relevant flag
// from `args[i^]`. Returns true if the flag was recognised (and
// advances i^ by 1 or 2 depending on whether the flag took a value).
// Returns false if the arg is not a CliConfig flag — caller handles
// it as command-specific (--workers, --out-dir, --iterations, ...) or
// positional.
//
// Exits with usage on a flag whose value fails to parse (--lang=foo,
// --source-type=foo, --ast-type=foo). This matches the pre-#6
// behaviour exactly; we do not let bad flag values silently slide.
cli_try_parse_flag :: proc(cfg: ^CliConfig, args: []string, i: ^int) -> bool {
	arg := args[i^]
	switch {
	case arg == "--compact":
		cfg.compact = true
		i^ += 1
		return true
	case arg == "--loc":
		cfg.emit_loc = true
		i^ += 1
		return true
	case arg == "--range":
		cfg.emit_range = true
		i^ += 1
		return true
	case arg == "--module-record":
		cfg.emit_module_record = true
		i^ += 1
		return true
	case arg == "--strict-source-type":
		cfg.strict_source_type = true
		i^ += 1
		return true
	case arg == "--force-strict":
		cfg.force_strict = true
		i^ += 1
		return true
	case arg == "--preserve-parens":
		cfg.preserve_parens = true
		i^ += 1
		return true
	case arg == "--json":
		// Print the JSON AST to stdout (the pre-2026-05 default).
		// Without this flag, `kessel parse FILE` prints only pretty
		// diagnostics on stderr — a clean human-facing default.
		cfg.emit_json = true
		i^ += 1
		return true
	case arg == "--stats":
		// Print the per-parse arena / error-count block on stderr
		// (the pre-2026-05 default). Useful when measuring memory
		// pressure or scripting against the trailing summary line.
		cfg.show_stats = true
		i^ += 1
		return true
	case strings.has_prefix(arg, "--color="):
		// Strict boolean. Only `true` / `false` are accepted; anything
		// else (including the legacy `auto`/`always`/`never` triplet)
		// is rejected so a typo doesn't silently fall through to the
		// wrong mode.
		val := arg[8:]
		switch val {
		case "true":  cfg.color = true
		case "false": cfg.color = false
		case:
			fmt.eprintf("error: --color=%s is not valid (use true or false)\n", val)
			os.exit(2)
		}
		i^ += 1
		return true
	case arg == "--color" || arg == "--no-color":
		// Reject the legacy short forms explicitly so they don't get
		// silently swallowed as positional filenames. The spec is
		// `--color=true|false` — nothing else.
		fmt.eprintf("error: %s is not valid (use --color=true or --color=false)\n", arg)
		os.exit(2)
	case arg == "--pretty":
		// Backwards-compat alias — pretty diagnostics are now the
		// default. Silently accept so existing scripts don't break.
		i^ += 1
		return true
	case arg == "--show-semantic-errors":
		// Opt-in pass 3 (semantic checker). When set, kessel runs
		// the AST walker in src/checker.odin after parse_job_run
		// and merges its findings into job.parser.errors. Without
		// the flag, kessel parse stays parser-only — mirroring
		// OXC's parseSync so the OXC corpus comparison stays
		// apples-to-apples (oxc_semantic is also a separate pass).
		// Today the checker enforces break / continue + label
		// scoping; more checks migrate slice-by-slice (#3).
		cfg.show_semantic_errors = true
		i^ += 1
		return true
	case strings.has_prefix(arg, "--errors="):
		cfg.error_format = arg[9:]
		i^ += 1
		return true
	case strings.has_prefix(arg, "--source-type="):
		val := arg[14:]
		switch val {
		case "script":      cfg.source_type_override = .Script
		case "module":      cfg.source_type_override = .Module
		case "unambiguous": cfg.source_type_override = nil
		case:
			fmt.eprintf("Error: unknown --source-type value '%s' (expected script|module|unambiguous)\n", val)
			os.exit(2)
		}
		i^ += 1
		return true
	case strings.has_prefix(arg, "--ast-type="):
		val := arg[11:]
		switch val {
		case "js":   cfg.ast_type = .JS
		case "ts":   cfg.ast_type = .TS
		case "auto": cfg.ast_type = .Auto
		case:
			fmt.eprintf("Error: unknown --ast-type value '%s' (expected js|ts|auto)\n", val)
			os.exit(2)
		}
		i^ += 1
		return true
	case strings.has_prefix(arg, "--lang="):
		val := arg[7:]
		l, ok := parse_lang_flag(val)
		if !ok {
			fmt.eprintf("Error: unknown --lang value '%s' (expected js|jsx|ts|tsx)\n", val)
			os.exit(2)
		}
		cfg.lang_override = l
		i^ += 1
		return true
	}
	return false
}
