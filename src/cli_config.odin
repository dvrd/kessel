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

package main

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
}

// Build a CliConfig with the documented defaults.
//
//   error_format = "kessel"  // legacy shape; --errors=oxc opts in
//   ast_type     = .Auto     // emitter resolves from parse Lang
//
// Every other field defaults to its zero value (false / nil).
cli_config_default :: proc() -> CliConfig {
	return CliConfig{
		error_format = "kessel",
		ast_type     = .Auto,
	}
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
