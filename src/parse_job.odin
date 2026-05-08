// ============================================================================
// parse_job.odin — "source to parsed Program" deep module
// ============================================================================
//
// One module owns the full setup chain that every CLI / server / bench /
// test caller used to repeat by hand:
//
//   read source → reserve arena → init lexer (with source-type) → init
//   parser (with lang, .d.ts, force_source_type, force_strict,
//   preserve_parens, ast_only) → parse_program
//
// Before this module the chain lived in five different shapes across
// `parse_file`, `parse_file_to_disk`, `raw_transfer_file`,
// `parse_file_raw_to_disk`, `produce_raw_buffer`, the bench loops, and
// the server loop. The variants quietly disagreed on which CLI flags
// they honoured: `--raw` ignored `--source-type`, `--force-strict`,
// `--preserve-parens` and `.d.ts` detection; the multi-file worker path
// ignored the same set; `produce_raw_buffer` hard-coded `.Script` and
// JSX-default lang. Centralising the chain here is what fixes those
// bugs - every caller now goes through `parse_job_open_*` +
// `parse_job_run`, so flag handling is single-sourced.
//
// Why a job (mutable struct) and not a free function? Three callers
// need access to intermediate state AFTER parse_program returns:
//
//   * The JSON emitter reads lex.has_hashbang / lex.comments,
//     p.errors, p.lexer.line_offsets, arena.total_used.
//   * The raw-transfer rewriter needs the live arena pointer to
//     compute offsets.
//   * Benches need to reset and replay the arena across N iterations
//     without paying the mmap cost each time.
//
// Returning a tuple `(program, lexer, parser, arena)` from a free proc
// would require the caller to re-stitch ownership; the job struct
// captures it once.
//
// Three open variants cover the three lifetime patterns:
//
//   parse_job_open(job, path, config)
//     * Reads source via source_read (mmap on POSIX, heap fallback).
//     * Reserves a sized arena.
//     * Job owns BOTH source and arena; close releases both.
//
//   parse_job_open_inline(job, source, config, label)
//     * Source is a borrowed string (test harness, server-future,
//       in-memory caller).
//     * Reserves a sized arena. Job owns the arena, NOT the source.
//
//   parse_job_open_borrowed_arena(job, path, config, arena)
//     * Caller-managed arena (microbench: one arena reused across N
//       iterations to keep mmap cost out of the timed loop).
//     * Job owns the source, NOT the arena. parse_job_reset_arena
//       calls arena_free_all between iterations.
//
// What stays out of this module (handled by later deepening passes):
//
//   * JSON emission, raw rewriting, error printing - these read the
//     job's outputs but produce their own bytes (#2 ESTree emission,
//     future deepening of raw_transfer).
//   * CLI option flow - the job takes a snapshot via
//     `parse_config_from_cli` from a CliConfig built by the CLI flag
//     parser (src/cli_config.odin).
//   * Semantic checking - opt-in via `checker_run_for_job(&job)` after
//     `parse_job_run`. Pass 3 is intentionally OUT of the parse pipeline
//     so that `kessel parse` stays parser-only by default (matches OXC's
//     `parseSync`). The CLI's --show-semantic-errors flag wires it in.
//
// Test surface: callers can drive `parse_job_open_inline` +
// `parse_job_run` and assert against `job.program` / `job.parser.errors`
// without going through a CLI shim or a temp file.

package kessel

import "core:mem"
import mvirtual "core:mem/virtual"
import "core:strings"

// ============================================================================
// ParseConfig — caller intent, immutable per job
// ============================================================================
//
// A snapshot of the CLI flags that affect parsing (NOT emission). Server
// mode and worker threads hold one of these and reuse it per request,
// guaranteeing stable behaviour. Built from a CliConfig via
// `parse_config_from_cli` or constructed directly by tests.
ParseConfig :: struct {
	// Lang override from --lang=js|jsx|ts|tsx. Wins over path detection.
	lang_override: Maybe(Lang),

	// --source-type=script|module. nil = unambiguous (auto-detect).
	source_type_override: Maybe(SourceType),

	// --strict-source-type: refuse to auto-upgrade Script -> Module on
	// implicit module syntax. When source_type_override is nil this
	// promotes the default to Script.
	strict_source_type: bool,

	// --force-strict: parser starts strict regardless of directive
	// prologue. Used by Test262 onlyStrict fixtures.
	force_strict: bool,

	// --preserve-parens: wrap `(expr)` in ParenthesizedExpression nodes
	// (Acorn / OXC extension; not in ESTree core).
	preserve_parens: bool,

	// Bench-only: skip scope tracking, duplicate-binding detection,
	// post-parse verify_scopes. Matches OXC's permissive default and
	// gives a fair Parser::new() + parse() comparison.
	ast_only: bool,

	// Override .d.ts detection for inline sources where the path is
	// synthetic. nil = use path suffix (.d.ts / .d.mts / .d.cts).
	source_is_dts_override: Maybe(bool),

	// Override CommonJS detection for inline sources where the path is
	// synthetic. nil = use path suffix (.cjs / .cts). CommonJS files are
	// wrapped in a function at runtime, so top-level `return` is legal.
	is_commonjs_override:   Maybe(bool),
}

// Snapshot a CliConfig into a ParseConfig. Called once per parse job
// (and once per request in server mode). Decouples the parse path from
// CLI flag plumbing so worker threads see a stable view that can't
// race on shared state.
//
// Pre-#6 this read 5 process globals; post-#6 it reads the explicit
// `cli` argument. ast_only is set per-call by the bench harness;
// `--show-semantic-errors` is read directly by `main.odin` to invoke
// `checker_run_for_job` after the parser finishes — it doesn't flow
// through ParseConfig. Default `kessel parse` stays parser-only and
// matches OXC's `parseSync`.
parse_config_from_cli :: proc(cli: CliConfig) -> ParseConfig {
	return ParseConfig{
		lang_override          = cli.lang_override,
		source_type_override   = cli.source_type_override,
		strict_source_type     = cli.strict_source_type,
		force_strict           = cli.force_strict,
		preserve_parens        = cli.preserve_parens,
		ast_only               = false,
		source_is_dts_override = nil,
	}
}

// ============================================================================
// ParseJob — owns the lifetime of one parse
// ============================================================================
//
// Field grouping (top-down by phase, matching TigerStyle ordering):
//
//   1. Inputs  — config, source path / bytes, ownership flags.
//   2. Arena   — reserve + allocator + ownership flag.
//   3. Resolved — lang, source_is_dts, initial_source_type. Computed
//      once at open time; consumed by run.
//   4. Outputs — lexer, parser, program, elapsed. Populated by run.
//
// Public accessors: callers read `job.program`, `job.parser`, `job.lexer`,
// `job.arena`, `job.elapsed` directly. There are no getters - the struct
// IS the interface.
ParseJob :: struct {
	// Inputs
	config:      ParseConfig,
	source_path: string,         // "" for inline / synthetic
	source:      SourceBuffer,
	owns_source: bool,           // false for inline (borrowed bytes)

	// Arena
	arena:       mvirtual.Arena,
	arena_ptr:   ^mvirtual.Arena, // points at &arena OR at borrowed arena
	arena_alloc: mem.Allocator,
	owns_arena:  bool,           // false for borrowed-arena (bench)

	// Resolved at open time (consumed by run)
	lang:                Lang,
	source_is_dts:       bool,
	is_commonjs:         bool,
	initial_source_type: SourceType,
	lex_source_type:     SourceType,

	// Outputs (zeroed at open, populated by run)
	lexer:   Lexer,
	parser:  Parser,
	program: ^Program,

	// Lifecycle bit so close is idempotent.
	opened: bool,
}

// ============================================================================
// Internal helpers — lang / dts / source-type resolution
// ============================================================================
//
// Centralised so every entry point gets the same rules. Previously each
// of the four parse_* procs in main.odin spelled these out, with subtle
// drift (e.g. raw paths missed the .d.mts / .d.cts suffixes).

@(private="file")
resolve_dts_from_path :: proc(path: string) -> bool {
	return strings.has_suffix(path, ".d.ts") ||
	       strings.has_suffix(path, ".d.mts") ||
	       strings.has_suffix(path, ".d.cts")
}

// CommonJS files are wrapped in a function at runtime; top-level `return`
// is grammatically legal. The `.cjs` and `.cts` suffixes are the canonical
// signals.
@(private="file")
resolve_commonjs_from_path :: proc(path: string) -> bool {
	return strings.has_suffix(path, ".cjs") ||
	       strings.has_suffix(path, ".cts")
}

// Pick the SourceType the lexer is initialised with. The lexer needs
// this BEFORE the first prefetched token so Annex B HTML-like comments
// (`<!--`, `-->`) - legal only in script source per ECMA-262 §B.1.3 -
// are gated correctly.
@(private="file")
resolve_lex_source_type :: proc(cfg: ParseConfig) -> SourceType {
	if st, ok := cfg.source_type_override.?; ok { return st }
	return .Script
}

// Pick the SourceType passed to parse_program. Same rule as the lexer
// today, but kept as a separate helper because the eventual semantic
// checker may want to diverge (e.g. promote Script -> Module post-parse
// rather than at the lexer entry point).
@(private="file")
resolve_initial_source_type :: proc(cfg: ParseConfig) -> SourceType {
	if st, ok := cfg.source_type_override.?; ok { return st }
	if cfg.strict_source_type { return .Script }
	return .Script
}

// Standard arena reservation formula. Used by every owned-arena open
// path. The 256x source headroom matches the existing parse_file /
// parse_file_to_disk / raw_transfer_file shape; bench paths use a
// tighter formula and pass a borrowed arena.
@(private="file")
arena_reserve_for_source :: proc(source_len: int) -> uint {
	return uint(max(source_len * 256, 16 * 1024 * 1024))
}

// ============================================================================
// open / run / close — the public lifecycle
// ============================================================================

// Open a job over a file path. Reads the source (mmap on POSIX, heap
// fallback) and reserves a fresh arena sized for the file. Returns
// false on read failure - callers report their own context-appropriate
// error message and exit, matching the existing per-call-site behaviour.
//
// On success the job owns BOTH source and arena; both are released by
// parse_job_close.
parse_job_open :: proc(job: ^ParseJob, path: string, config: ParseConfig) -> bool {
	src_buf, src_ok := source_read(path, context.allocator)
	if !src_ok { return false }

	job^ = ParseJob{
		config       = config,
		source_path  = path,
		source       = src_buf,
		owns_source  = true,
		owns_arena   = true,
		opened       = true,
	}

	// Arena reservation. arena_init_static may fail (out-of-VA, kernel
	// rejection); we surface that as a job-open failure so the caller
	// can decide to exit vs continue (e.g. workers might log-and-skip).
	if err := mvirtual.arena_init_static(&job.arena, arena_reserve_for_source(len(job.source.data))); err != nil {
		source_release(job.source, context.allocator)
		job.opened = false
		return false
	}
	job.arena_ptr   = &job.arena
	job.arena_alloc = mvirtual.arena_allocator(&job.arena)

	parse_job_resolve(job)
	return true
}

// Open a job over an inline source string. Used by tests, the future
// in-memory server protocol, and any caller that already has the bytes
// in hand. The source bytes are BORROWED - the caller is responsible
// for keeping them alive until parse_job_close.
//
// `label` is the synthetic path used for diagnostics and lang detection
// (pass e.g. "<test>.ts" to route through TS grammar).
parse_job_open_inline :: proc(job: ^ParseJob, source: string, config: ParseConfig, label := "<inline>") -> bool {
	job^ = ParseJob{
		config      = config,
		source_path = label,
		source      = SourceBuffer{ data = transmute([]u8)source, mapped = false },
		owns_source = false,
		owns_arena  = true,
		opened      = true,
	}

	if err := mvirtual.arena_init_static(&job.arena, arena_reserve_for_source(len(job.source.data))); err != nil {
		job.opened = false
		return false
	}
	job.arena_ptr   = &job.arena
	job.arena_alloc = mvirtual.arena_allocator(&job.arena)

	parse_job_resolve(job)
	return true
}

// Open a job with a CALLER-MANAGED arena. Used by microbench so the
// arena (and its mmap reservation) survives across iterations; the
// bench loop calls parse_job_reset_arena between runs to free_all
// without paying the mmap/munmap round-trip.
//
// Source is read from `path` and owned by the job. Arena is borrowed
// and NOT freed by close.
parse_job_open_borrowed_arena :: proc(job: ^ParseJob, path: string, config: ParseConfig, arena: ^mvirtual.Arena) -> bool {
	src_buf, src_ok := source_read(path, context.allocator)
	if !src_ok { return false }

	job^ = ParseJob{
		config       = config,
		source_path  = path,
		source       = src_buf,
		owns_source  = true,
		arena_ptr    = arena,
		arena_alloc  = mvirtual.arena_allocator(arena),
		owns_arena   = false,
		opened       = true,
	}

	parse_job_resolve(job)
	return true
}

// Resolve lang / dts / source-type from the path + config. Single
// source of truth - keeps the four entry points consistent.
@(private="file")
parse_job_resolve :: proc(job: ^ParseJob) {
	// Lang: explicit override wins, else extension.
	if l, ok := job.config.lang_override.?; ok {
		job.lang = l
	} else {
		job.lang = detect_lang_from_path(job.source_path)
	}

	// .d.ts: explicit override wins, else path suffix. The override
	// matters for inline sources whose synthetic label has no .d.ts
	// suffix even when the caller wants ambient relaxations.
	if dts, have := job.config.source_is_dts_override.?; have {
		job.source_is_dts = dts
	} else {
		job.source_is_dts = resolve_dts_from_path(job.source_path)
	}

	// CommonJS detection mirrors the .d.ts path — explicit override wins,
	// else file extension. .cjs/.cts files have a function wrapper at
	// runtime so top-level `return` is grammatically legal.
	if cjs, have := job.config.is_commonjs_override.?; have {
		job.is_commonjs = cjs
	} else {
		job.is_commonjs = resolve_commonjs_from_path(job.source_path)
	}

	job.lex_source_type     = resolve_lex_source_type(job.config)
	job.initial_source_type = resolve_initial_source_type(job.config)
}

// Run the parse. Initialises lexer + parser, threads the config flags
// onto the parser struct, calls parse_program. After return the job's
// lexer / parser / program / elapsed fields are populated. The arena
// and source remain owned by the job; close releases them.
//
// Idempotent only via reset_arena: calling run twice on the same job
// without resetting will leak the previous parse's allocations into
// the arena. That's fine for benches (they reset between iterations),
// not fine for general use. The single-shot CLI paths call run exactly
// once per open.
parse_job_run :: proc(job: ^ParseJob) {
	source_str := string(job.source.data)

	// Lexer first - it needs source_type up front to gate Annex B
	// HTML-like comments on the very first prefetched token.
	init_lexer(&job.lexer, source_str, job.arena_alloc, job.lex_source_type)

	// Parser - lang and source_is_dts at construction; everything else
	// gets set on the struct AFTER init_parser zeroes it (matching the
	// existing parse_file behaviour, which init_parser's own comment
	// at parser.odin:1514 calls out).
	init_parser(&job.parser, &job.lexer, job.arena_alloc, job.lang, job.source_is_dts)

	// Per-call config that init_parser doesn't take as args. Order
	// preserved for diff-readability vs the previous parse_file body.
	if st, ok := job.config.source_type_override.?; ok {
		job.parser.force_source_type = st
	} else if job.config.strict_source_type {
		job.parser.force_source_type = .Script
	}
	job.parser.force_strict     = job.config.force_strict
	job.parser.preserve_parens  = job.config.preserve_parens
	job.parser.ast_only         = job.config.ast_only
	job.parser.is_commonjs      = job.is_commonjs

	job.program = parse_program(&job.parser, job.initial_source_type)
}

// Reset the arena between bench iterations. Only valid for jobs opened
// via parse_job_open_borrowed_arena (where the arena outlives the
// per-iteration parse).
//
// Asserts owns_arena = false because resetting a job-owned arena would
// invalidate the lexer/parser the job still holds references to without
// any way to detect the dangling state.
parse_job_reset_arena :: proc(job: ^ParseJob) {
	assert(job.opened)
	assert(!job.owns_arena, "parse_job_reset_arena requires a borrowed arena")
	mvirtual.arena_free_all(job.arena_ptr)
	// Drop references into the freed arena. The next parse_job_run will
	// re-init lexer + parser fresh.
	job.lexer   = {}
	job.parser  = {}
	job.program = nil
}

// Release everything the job owns. Idempotent - safe to call from a
// `defer` even after open failure.
parse_job_close :: proc(job: ^ParseJob) {
	if !job.opened { return }
	if job.owns_arena { mvirtual.arena_destroy(&job.arena) }
	if job.owns_source { source_release(job.source, context.allocator) }
	job.opened = false
}
