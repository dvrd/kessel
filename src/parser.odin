package kessel

import "core:mem"
import "core:fmt"
import "core:strings"

// ============================================================================
// Token Access (cached in Parser for zero-overhead reads)
// ============================================================================

// Hot path inlined: whitespace skip + single-char + identifier dispatch.
// Cold tokens (strings, numbers, operators) fall through to lex_token.
advance_token :: #force_inline proc(p: ^Parser) {
	a := p.lexer
	p.prev_token_end = a.cur.end
	if a.nxt_valid {
		a.cur = a.nxt
		a.nxt_valid = false
	} else {
		lex_token_inline(a)
	}
	a.lit_write_idx ~= 1
	p.cur_type = a.cur.kind
}

// Fast contextual keyword check: compares cur token's source span
// against a keyword string. Avoids creating a string slice when the
// token length doesn't match (early exit on u32 arithmetic).
cur_value_eq :: #force_inline proc(p: ^Parser, keyword: string) -> bool {
	ft := p.lexer.cur
	// Escaped identifiers have cooked names shorter than raw span.
	// Fall back to cur_value which handles the cooked name correctly.
	if (ft.flags & FLAG_HAS_ESCAPE) != 0 { return cur_value(p) == keyword }
	if ft.end - ft.start != u32(len(keyword)) { return false }
	return p.lexer.source[ft.start:ft.end] == keyword
}

// Ensure nxt is populated. Called by all lookahead / peek sites.
// If nxt is already valid (from a prior peek), this is a no-op.
ensure_nxt :: #force_inline proc(p: ^Parser) {
	a := p.lexer
	if !a.nxt_valid {
		a.nxt = lex_token(a)
		a.nxt_valid = true
	}
}

peek_token :: #force_inline proc(p: ^Parser) -> Token {
	if p.lexer != nil {
		ensure_nxt(p)
		ft := p.lexer.nxt
		tok: Token
		tok.type = ft.kind
		tok.loc = LexerLoc(ft.start)
		tok.raw_end = ft.end
		tok.had_line_terminator = (ft.flags & FLAG_NEW_LINE) != 0
		if ft.kind < .LBrace && ft.kind != .EOF && ft.start < ft.end {
			tok.value = p.lexer.source[ft.start:ft.end]
		}
		return tok
	}
	return Token{type = .EOF}
}

// Prime the parser's cached cur_type from the lexer's current token.
prime_token_cache :: proc(p: ^Parser) {
	if p.lexer != nil {
		p.cur_type = p.lexer.cur.kind
	} else {
		p.cur_type = .EOF
	}
}

// ============================================================================
// Bump allocator - zero-dispatch arena for AST node allocations
// ============================================================================

BumpPool :: struct {
	base:           [^]u8,
	offset:         int,
	capacity:       int,
	overflow_count: int,  // Track fallbacks to backing allocator
}

bump_init :: proc(pool: ^BumpPool, backing: mem.Allocator, capacity: int) {
	// Defensive: if the backing allocator can't satisfy the requested
	// capacity (e.g. caller's arena is sized smaller than the pool's
	// chosen floor), retry at progressively smaller sizes so we always
	// produce a usable bump pool. Without this fallback bump_alloc
	// would dereference a nil base on the first AST allocation - a
	// segfault that surfaced on bench/real_world/batch3/snabbdom.js when
	// the microbench arena floor (256 KB) was smaller than the pool's
	// 1 MB floor for tiny files.
	cap := capacity
	raw, err := mem.alloc_bytes(cap, 16, backing)
	for (err != nil || raw_data(raw) == nil) && cap > 4096 {
		cap /= 2
		raw, err = mem.alloc_bytes(cap, 16, backing)
	}
	pool.base = raw_data(raw)
	pool.offset = 0
	pool.capacity = cap if pool.base != nil else 0
}

bump_alloc :: #force_inline proc(pool: ^BumpPool, size: int, align: int) -> rawptr {
	mask := align - 1
	aligned := (pool.offset + mask) & ~mask
	new_offset := aligned + size
	if new_offset > pool.capacity {
		pool.overflow_count += 1
		return nil // caller must fall back
	}
	ptr := rawptr(uintptr(pool.base) + uintptr(aligned))
	pool.offset = new_offset
	return ptr
}

// ============================================================================
// Fast generic append for [dynamic]T arrays
// ============================================================================
// Odin's runtime `_append_elem` is `#force_no_inline` and takes
// `size_of_elem: int` as a runtime parameter. That means the
// `mem_copy_non_overlapping(data, arg_ptr, size_of_elem)` call inside it
// can't be specialised by LLVM - it falls through to a system `memmove`
// call even when copying a single 8-byte pointer. Profile evidence on
// monaco.js: 86 % of `_append_elem` samples are inside `_platform_memmove`,
// for elements that are typically 8-16 B.
// `bump_append` is a generic, `#force_inline` replacement that lets the
// compiler specialise the element copy per type T. For T = ^Statement
// (8 B), the inner store collapses to a single STR instruction; for T =
// FunctionParameter (~80 B), the store becomes a small fixed memcpy that
// LLVM can also inline when size is statically known.
// The grow path delegates to the standard `append()` so we don't have to
// reimplement realloc/copy logic. That's the slow path; the common case
// (cap headroom available) is the fully-inlined fast path.
// Use `bump_append(&arr, item)` exactly like `bump_append(&arr, item)`.
bump_append :: #force_inline proc(arr: ^[dynamic]$T, item: T) {
	raw := (^Raw_Dynamic_Array)(arr)
	if raw.cap < raw.len + 1 {
		// Slow path: capacity exhausted, fall back to runtime append which
		// will reserve+grow. Rare for pre-sized arrays.
		append(arr, item)
		return
	}
	// Fast path: typed store + length increment, fully inline.
	data := ([^]T)(raw.data)
	data[raw.len] = item
	raw.len += 1
}

// Internal: Odin's runtime Raw_Dynamic_Array layout, exposed for the
// fast-path append above. Mirrors `base/runtime/dynamic_array_internal.odin`.
Raw_Dynamic_Array :: struct {
	data:      rawptr,
	len:       int,
	cap:       int,
	allocator: mem.Allocator,
}

// PendingPrivRef — captured at every PrivateIdentifier reference site.
// Resolved at end of parse_class_body against the just-parsed elements.
// Unresolved ones bubble up to the enclosing class body's queue.
PendingPrivRef :: struct {
	name:  string,
	loc:   Loc,
	depth: int,  // class_depth at which the reference was made
}

// Stack-scoped context flags. Set on entry to a new grammar scope
// (function, class, loop, etc.) and restored on exit. All booleans
// except label_floor (int).
ParseContext :: struct {
	in_function:              bool,
	in_non_arrow_function:    bool,
	in_generator:             bool,
	in_async:                 bool,
	in_loop:                  bool,
	in_switch:                bool,
	strict_mode:              bool,
	in_static_block:          bool,
	in_field_init:            bool,
	in_ts_namespace:          bool,
	in_ts_module_block:       bool,
	in_case_clause:           bool,
	in_method:                bool,
	in_generator_params:      bool,
	in_async_params:          bool,
	in_derived_constructor:   bool,
	class_has_extends:        bool,
	class_is_abstract:        bool,
	no_in:                    bool,
	in_in_rhs:                bool,
	private_in_allowed:       bool,
	in_nested_pattern_convert: bool,
	in_ambient:               bool,
	label_floor:              int,
}

Parser :: struct {
	// ---- Cache-line 0: hottest fields (accessed every token) ----
	// Lexer reference (per-parser, thread-safe for parallel parsing)
	lexer: ^Lexer,
	// Token type — checked on EVERY is_token() call. Placed before
	// Placed at struct top for cache line 0 locality with the lexer pointer.
	cur_type: TokenType,
	// End offset of the LAST consumed token.
	prev_token_end: u32,

	// Remembered `(` position for arrow-function parameter parens - used
	// when a parenthesized expression turns out to be arrow-function
	// parameters. ESTree spans the full `(x, y) => ...` starting AT the
	// opening paren, not at the first parameter. Set by parse_primary_expr
	// when it opens a `(` that could be an arrow param list; consumed (and
	// cleared) by parse_arrow_function. max(u32) = "unset" sentinel so
	// position 0 (file start) is a valid stamped value.
	pending_paren_start: u32,

	// Pointer to the most recent expression that came directly out of a
	// `(...)` group (i.e. ParenthesizedExpression with the parens stripped
	// in the default --no-preserve-parens shape). Used by
	// parse_assignment_expr to enforce §12.10 / §13.15:
	// AssignmentTargetType(ParenthesizedExpression) = AssignmentTargetType
	// of the inner expression - which means a paren-wrapped ObjectLiteral /
	// ArrayLiteral / ArrowFunction / etc. is INVALID as the LHS of `=`,
	// even when the bare inner form would be valid as an
	// ObjectAssignmentPattern / ArrayAssignmentPattern. Test262
	// language/expressions/assignmenttargettype/{direct-arrowfunction-1,
	// direct-asyncarrowfunction-1, parenthesized-primaryexpression-
	// objectliteral}.js. Set by parse_primary_expr's LParen branch on
	// successful `(...)` parse; the LHS-tail loop in parse_lhs_tail
	// implicitly invalidates the marker by producing a NEW wrapping
	// expression (MemberExpression / CallExpression / ...), so a check via
	// pointer equality `left == p.last_paren_expr` distinguishes the bare
	// paren-wrapped form from `({}.x)` etc.
	last_paren_expr: ^Expression,

	// Allocator for AST allocations (used for [dynamic] arrays)
	allocator: mem.Allocator,

	// Source length - used for pre-sizing heuristics
	source_len: int,

	// Fast bump pool for AST nodes (bypasses allocator dispatch)
	node_pool: BumpPool,

	// Stack-scoped parse context — these fields are saved on entry to
	// a new scope (function, class, loop, etc.) and restored on exit.
	// Grouped into a struct for documentation; future work may pass
	// this by value to eliminate save/restore boilerplate.
	ctx: ParseContext,

	errors: [dynamic]ParseError,

	interner: ^StringInterner,

	// When true, the NEXT parse_block_statement scope check uses
	// is_block_scope=false (function-scope semantics). Auto-cleared
	// after the block. Set by arrow block-body and static-block
	// parsers so var+function coexistence is accepted.
	scope_fn_scope_next_block: bool,

	// Most-recent call to `parse_function_body` set this to true iff the
	// body's directive prologue contained a literal `"use strict"`. Used
	// by the immediately-surrounding caller (function-decl / expr / class-
	// method / object-method) to retroactively validate its FormalParameters
	// under StrictFormalParameters rules (ECMA-262 §15.2.1): reject duplicate
	// parameter names. Must be read before any other parse call since
	// nested bodies clobber it.
	last_body_strict: bool,

	// Stack of LabelIdentifier names currently in scope from enclosing
	// LabelledStatement nodes. Labels do NOT cross function boundaries
	// (ECMA-262 §14.13 - LabelSet is per-function), so entering a
	// function body saves the current floor, stretches it to
	// len(label_stack) so outer labels are invisible, and restores on
	// exit. Only slots in [label_floor..len) are visible to the current
	// function; push appends past the floor, pop truncates back.
	// Used for:
	//   * §14.13.1 - duplicate-label rejection
	//   * §14.14.1 / §14.14.2 - `break label` / `continue label` must
	//     target a LabelledStatement that IS in scope.
	//   * §14.8.1 - `continue label` additionally requires the target
	//     label to name an IterationStatement (directly or via a chain of
	//     LabelledStatements). `label_is_iteration` is a parallel stack
	//     recording exactly that per-label bit; computed eagerly at push
	//     time via a lexer-snapshot scan over `Identifier :` chains.
	label_stack: [dynamic]string,
	label_is_iteration: [dynamic]bool,

	// Depth counter for nested classes. Incremented on entry to
	// parse_class_body, decremented on exit. Used to enforce §15.7.3
	// PrivateName references (`#x`, `obj.#x`, `#x in y`) outside any
	// class body — if class_depth == 0, the reference cannot resolve.
	class_depth: int,

	// Per-class-body pending private-name reference list. Populated as
	// we encounter `#x` / `obj.#x` / `obj?.#x` references during the
	// class body parse. At end of parse_class_body we collect declared
	// names from the elements and validate (or bubble unresolved ones
	// up to the enclosing class).
	pending_priv_refs: [dynamic]PendingPrivRef,

	// Language mode - controls JSX / TS syntax admissibility.
	//   .JS  : plain JavaScript. `<` at expression start → syntax error.
	//   .JSX : JS + JSX. `<` at expression start → JSX element.
	//   .TS  : TypeScript, no JSX. `<` at expression start → type
	//          assertion `<Type>expr` or generic arrow `<T>(x)=>x`.
	//   .TSX : TS + JSX. `<` is ambiguous; OXC rule: assertion is
	//          forbidden, generic arrow requires trailing comma.
	lang:            Lang,

	// Depth counter for nested ConditionalExpression consequent branches.
	// Incremented while parsing the consequent of `? ...`, decremented
	// after. Used by looks_like_ts_arrow_params to suppress the aggressive
	// byte-level `)...:...=>` scan that can misinterpret a ternary `:`
	// as a TS arrow return-type annotation.
	conditional_depth: int,

	// TS: depth counter for contexts where conditional types are suppressed.
	// When > 0, parse_ts_type will NOT parse `extends ... ? ... : ...` as a
	// conditional type. Used by the infer-with-constraints speculative
	// parse (TS 4.7+) to match OXC / TypeScript behaviour.
	ts_disallow_conditional_types: int,
	ts_in_conditional_extends:     int,  // >0 when inside a conditional type's extends clause (for infer validation)
	ts_in_type_arguments:          int,  // >0 when inside <...> type arguments (suppress ? JSDoc errors)

	// Depth counter for TS object/interface type literal bodies. When > 0,
	// type-argument `<T>` on a newline is NOT consumed as postfix (it starts
	// a new generic call/construct signature member).
	ts_in_type_literal: int,

	// True while parsing elements of a TS tuple type `[T?, U, ...V]`.
	// Suppresses the JSDoc-nullable `?` consumption in parse_ts_postfix
	// so that postfix `?` is reserved for TSOptionalType instead.
	ts_in_tuple_type: bool,

	// CLI `--source-type` override. When set, disables the auto-upgrade
	// from Script to Module that parse_program normally performs when it
	// sees top-level import / export / import.meta. The caller passes the
	// requested SourceType directly to parse_program; this flag just tells
	// parse_program to leave it alone. nil = unambiguous (auto-detect).
	force_source_type: Maybe(SourceType),

	// CLI `--show-semantic-errors` (OPT-6). When true, parse_program runs
	// CLI `--force-strict`. When true, parse_program starts with
	// strict_mode on, bypassing the directive-prologue detection. Used
	// by test262's `onlyStrict` fixtures so the harness can enforce
	// strict-mode early-errors without having to patch the source.
	force_strict: bool,

	// Pending CoverInitializedName offsets (§13.2.5.1). Every
	// `{ ident = init }` shorthand-with-default appends its start
	// offset; expr_to_pattern (when the ObjectExpression gets promoted
	// to an ObjectPattern) removes the entries for that object. At the
	// end of parse_program any remaining entries are reported - the
	// form is only legal INSIDE a destructuring cover.
	pending_cover_inits: [dynamic]u32,

	// Pending parenthesized-inside-pattern offsets. When an array/object
	// literal element is parenthesized AND the inner expression is a
	// non-simple form (AssignmentExpression, ArrayExpression, ObjectExpression),
	// the inner expression's start offset is recorded here. On destructuring
	// conversion these positions fire "Invalid parenthesized assignment pattern".
	pending_paren_patterns: [dynamic]u32,

	// Pending duplicate-__proto__ offsets (§13.2.5.1 / §B.3.1). Every
	// ObjectExpression with a second `__proto__: ...` init property
	// appends the duplicate key's start offset here. expr_to_pattern
	// (when the ObjectExpression gets promoted to an ObjectPattern)
	// removes entries for that object, because Annex B.3.1 makes
	// duplicate __proto__ legal in destructuring patterns. At the end
	// of parse_program any remaining entries are reported.
	pending_proto_dups: [dynamic]u32,

	// CLI `--preserve-parens`. When true, every genuine `(expr)` paren-
	// grouping wraps its inner expression in a ParenthesizedExpression
	// node. Off by default for byte-identical legacy output. Does NOT
	// wrap arrow-param covers (`(x, y) =>`), call / new argument lists,
	// or control-flow headers - only the expression-position case.
	preserve_parens:   bool,

	// Per-parse counters used by `verify_private_names` to short-circuit
	// the §15.7.3 AllPrivateIdentifiersValid walk. The walker is a
	// recursive visitor over the entire AST; on real-world JS that
	// contains no PrivateIdentifier (which is the overwhelming majority,
	// including TypeScript, lodash, jQuery, React, etc.) it accounts for
	// >10 % of total parse time without ever firing a check. Bumped at
	// every PrivateIdentifier-emitting site (member access, optional
	// chain, bare-LHS-of-`in`, class-element key); when zero at end of
	// parse, the walker is skipped entirely. §15.7.5 (no `arguments`
	// inside a class field initializer) is checked inline at field-
	// initializer parse time so it does NOT depend on this walker.
	private_id_count: u32,

	// True while parsing the declaration of `export default function ...`
	// or `export default class ...`. Used to suppress OXC-parity checks
	// that OXC doesn't enforce in the default-export position (e.g.
	// `export default function *yield() {}` is accepted by OXC).
	in_export_default: bool,

	// True for `.d.ts` declaration files. They parse as TS, but ambient
	// declaration-file relaxations (for example `const x;`) must not leak
	// into normal `.ts` / `.tsx` source.
	source_is_dts:   bool,

	// True for `.cjs` / `.cts` files (and inline sources tagged commonjs).
	// CommonJS wraps the file in a `function(exports, require, ...)` body
	// at runtime, so a top-level `return` is grammatically legal. Without
	// this flag the parser would emit "'return' outside of function".
	is_commonjs:     bool,

	// True for `.cts` / `.mts` files. In these node-module TS files,
	// generic arrow `<T>() => ...` is reserved syntax (TSX-like rule).
	// Requires either a trailing comma `<T,>` or constraint `<T extends>`.
	is_node_ts_module: bool,

	// Explicit Babel option `disallowAmbiguousJSXLike`. Rejects `<T>x`
	// type assertions and ambiguous `<T>() => ...` generic arrows.
	// Auto-enabled for .mts/.cts via is_node_ts_module; this field
	// captures the explicit opt-in for other extensions.
	disallow_ambiguous_jsx_like: bool,

	// Track if module syntax was detected (import/export or import.meta)
	has_module_syntax: bool,

	// Lazy module-syntax pre-scan cache. The pre-scan inspects the
	// source for top-level import/export and is only needed in the rare
	// case where a parsing decision depends on whether the file is a
	// module BEFORE the parser has reached the import/export token.
	// True examples: top-level `await` / `for await` / `using` / `await
	// using` in auto-detect JS files. The lexer's keyword tokenisation
	// does NOT need this (it always emits .Await regardless).
	// Default false. The first call to ensure_module_syntax_resolved
	// runs the SIMD pre-scan and sets this to true. CJS bundles
	// (typescript.js, lodash, jquery, ...) never trigger any of those
	// constructs and so never pay the scan cost — ~17 ms saved on a
	// 9 MB CJS bundle vs the pre-this-commit unconditional pre-scan.
	module_pre_scan_done: bool,

	// True only when parsing at the top level of a Module body - the position
	// where ImportDeclaration and ExportDeclaration are legal (§16.2.1).
	// Set from the explicit --source-type=module pin. Cleared on entry to
	// any function body (via in_function) or via statement_depth > 0.
	in_module_top_level: bool,

	// Incremented when entering any Block statement (not function body).
	// Used together with in_module_top_level to reject import/export in
	// block positions without saving/restoring in parse_block_statement.
	block_depth: int,

	// ESM module record arrays (populated when module-record flag is enabled)
	staticImports:  [dynamic]ESMStaticImport,
	staticExports:  [dynamic]ESMStaticExport,
	dynamicImports: [dynamic]ESMDynamicImport,
	importMetas:    [dynamic]ESMImportMeta,

	// Reusable ScopeMap pair for inline scope checking at each
	// scope-bearing parse exit (BlockStatement, SwitchStatement,
	// FunctionBody, Program). Cleared between scopes.
	scope_lex:  ScopeMap,
	scope_vars: ScopeMap,

	// `ast_only` switches off all scope tracking, duplicate-binding
	// detection, and exported-name dedup. The parser still produces
	// a complete ESTree-compatible AST and reports syntactic errors
	// (mismatched braces, invalid expressions, etc.) but skips the
	// semantic / scope-level checks that OXC's parser also defers to its
	// `oxc_semantic` pass.
	// Used by the `microbench parse --ast-only` benchmark mode to compare
	// against OXC's `Parser::new().parse()` (which does the same deferral)
	// on equal terms. Test262 / TS / JSX / negative gates leave it OFF
	// so all conformance work runs as today; this flag is bench-only.
	ast_only: bool,

	// Optional instrumentation for parser profiling
	profile_enabled: bool,
	profile:         ParserProfile,

	// Shared guardrails for malformed input. Kept out of the hot field
	// prefix so the parser's allocation and token fields retain their
	// cache-line layout.
	resource_budget: ParseResourceBudget,
}

ParserProfile :: struct {
	get_current_calls:      u64,
	next_calls:             u64,
	peek_calls:             u64,
	is_calls:               u64,
	expect_calls:           u64,
	node_allocs:            u64,
	node_alloc_bytes:       u64,
	expr_wrapper_allocs:    u64,
	stmt_wrapper_allocs:    u64,
	identifier_allocs:      u64,
	member_expr_allocs:     u64,
	call_expr_allocs:       u64,
	binary_expr_allocs:     u64,
	logical_expr_allocs:    u64,
	property_allocs:        u64,
	object_expr_allocs:     u64,
	array_expr_allocs:      u64,
	interner_hits:          u64,
	interner_misses:        u64,
	errors_reported:        u64,
	expression_fallbacks:   u64,
	recovery_tokens_eaten:  u64,
}

// Parse error structure. `start` and `end` are byte offsets into the
// source. For single-point reports (the common case before token-aware
// spans landed) callers set start == end; report_error / report_error_at
// helpers below do the right thing. Token-aware spans (start < end)
// come from report_error_span and from the parser's primary report_error
// which now reads both ends off the current FastToken.
//
// `code` and `severity` were added in the Phase 1 diagnostics work.
// Both default to their zero value (`.None` / `.Error`) so the 600+
// pre-existing call sites that don't yet pass a code still compile and
// behave identically to before. Migration is opt-in: new sites use the
// `_coded` variants of the report helpers below, and we sweep batches
// of legacy sites in follow-up commits (see `src/diagnostic.odin`).
ParseError :: struct {
	start:    u32,
	end:      u32,
	message:  string,
	code:     ErrorCode,   // .None for legacy / un-migrated call sites
	severity: Severity,    // .Error is the zero value
}

// String interner for identifier deduplication (lazy init)
StringInterner :: struct {
	allocator:    mem.Allocator,
	entries:      map[string]string,
	capacity_hint: int,
	initialized:  bool,
}

// Any keyword can be used as a property name in object literals and as method/field names.
// ES spec: PropertyName can be IdentifierName, which includes all keywords.
is_keyword_usable_as_property_name :: #force_inline proc(t: TokenType) -> bool {
	#partial switch t {
	case .Identifier,  // includes TS contextual keywords: type, interface, enum
	     .Get, .Set, .Async, .Static, .Let, .Of, .From, .As, .Constructor, .Accessor,
	     .Yield, .Await, .If, .Else, .For, .While, .Do, .Switch, .Case,
	     .Assert, .Asserts, .Abstract, .Declare, .Readonly, .Override,
	     .Keyof, .Infer, .Is, .Satisfies, .Never, .Unique, .Namespace, .Module,
	     .Implements, .Require, .Package, .Private, .Protected, .Public, .Target, .Using,
	     .Default, .Break, .Continue, .Return, .Throw, .Try, .Catch, .Finally,
	     .Function, .Class, .Var, .Const, .New, .Delete, .Typeof, .Void,
	     .In, .Instanceof, .Extends, .Super, .This, .With, .Debugger,
	     .Import, .Export, .True, .False, .Null:
		return true
	case:
		return false
	}
}

// Token types that can stand in for a BindingIdentifier per §12.6.1.1.
// Strict reserved words (Identifier + contextual keywords). Excludes
// hard reserved keywords (`extends`, `class`, `function`, `if`, `for`,
// `var`, `const`, `return`, etc.) which can never be a binding name.
// Caller is still expected to do strict-mode reservation checks (let,
// yield, await, eval, arguments, package, private, ...).
can_be_binding_identifier :: #force_inline proc(t: TokenType) -> bool {
	#partial switch t {
	case .Identifier,
	     .Get, .Set, .Async, .Static, .Let, .Of, .From, .As, .Constructor, .Accessor,
	     .Yield, .Await,
	     .Assert, .Asserts, .Abstract, .Declare, .Readonly, .Override,
	     .Keyof, .Infer, .Is, .Satisfies, .Never, .Unique, .Namespace, .Module,
	     .Implements, .Require, .Package, .Private, .Protected, .Public, .Target, .Using,
	     .Type, .Interface, .Enum:
		return true
	case:
		return false
	}
}

init_interner :: proc(i: ^StringInterner, alloc: mem.Allocator, capacity_hint: int = 0) {
	i.allocator = alloc
	i.capacity_hint = capacity_hint
}

intern :: proc(i: ^StringInterner, s: string) -> string {
	if !i.initialized {
		if i.capacity_hint > 0 {
			i.entries = make(map[string]string, i.capacity_hint, i.allocator)
		} else {
			i.entries = make(map[string]string, i.allocator)
		}
		i.initialized = true
	}
	if existing, ok := i.entries[s]; ok {
		return existing
	}

	bytes, _ := mem.alloc_bytes(len(s), allocator=i.allocator)
	copy(bytes, s)
	interned := string(bytes)
	i.entries[interned] = interned
	return interned
}


// Language mode. Used to gate JSX and TS syntax at parse-dispatch sites.
// Default .JSX preserves legacy behaviour: every file accepts JSX. Callers
// that know the file extension or user intent should pass the real mode.
Lang :: enum u8 {
	JS,   // plain JavaScript, no JSX
	JSX,  // JavaScript + JSX - legacy Kessel default
	TS,   // TypeScript, no JSX
	TSX,  // TypeScript + JSX
}

// Helpers - branch once on lang, let the compiler inline.
allow_jsx_mode :: #force_inline proc(p: ^Parser) -> bool {
	return p.lang == .JSX || p.lang == .TSX
}

allow_ts_mode :: #force_inline proc(p: ^Parser) -> bool {
	return p.lang == .TS || p.lang == .TSX
}

init_parser :: proc(p: ^Parser, lexer: ^Lexer, alloc: mem.Allocator, lang: Lang = .JSX, source_is_dts := false) {
	p.allocator = alloc
	p.source_len = len(lexer.source)
	p.resource_budget = parse_resource_budget_default()
	p.errors = make([dynamic]ParseError, alloc)
	p.pending_cover_inits = make([dynamic]u32, 0, 4, alloc)
	p.pending_proto_dups = make([dynamic]u32, 0, 4, alloc)
	p.pending_paren_patterns = make([dynamic]u32, 0, 4, alloc)
	p.pending_priv_refs = make([dynamic]PendingPrivRef, 0, 0, alloc)
	// Heuristic: ~1 scope-bearing node per ~512 bytes of source on average
	// real-world JS (functions / arrows / blocks). Pre-size so the typical
	// big bundle (typescript.js ~9 MB) doesn't realloc more than 1-2 times.
	scope_cap := 16
	if p.source_len > 4096 {
		scope_cap = p.source_len / 512
	}
	// Reusable ScopeMap pair for inline scope checking at each parse
	// scope exit (block, switch, function body, program).
	p.scope_lex  = scope_map_make(scope_cap, alloc)
	p.scope_vars = scope_map_make(scope_cap, alloc)

	// Bump pool: scale with source size.
	// Non-minified production JS emits ~25-30 bytes of AST per byte of
	// source once dynamic-array headers, Expression / Statement wrappers,
	// and per-Property / FunctionParameter records are counted. The
	// previous formula (20× source with a 256 KB threshold) sized tiny-
	// to-medium files exactly at 20×, which overflowed bench/real_world/
	// batch2/preact.js (11 KB source needed 225 K pool, formula gave 225 K
	// → 1924 fallbacks to the backing allocator). Three bands:
	//   <1 KB   : 32 KB flat floor. AST barely uses 3 KB but reserving 32 KB
	//             gives headroom for arrays and avoids the cliff where the
	//             pool cap exactly equals usage.
	//   <64 KB  : 30× source + 32 KB padding. Worst-case dense file is
	//             about 24× (e.g. dayjs.js: 7 KB source, 170 K pool used);
	//             30× + headroom keeps every file in this band overflow-free.
	//   ≥64 KB  : 15× source. antd / typescript stay around 6-7× used so
	//             this is a comfortable upper bound; mmap of an unused
	//             reservation is cheap on macOS / Linux.
	pool_size: int
	if p.source_len < 1024 {
		pool_size = 32 * 1024
	} else if p.source_len < 64 * 1024 {
		pool_size = p.source_len * 30 + 32 * 1024
	} else {
		pool_size = p.source_len * 32
	}
	bump_init(&p.node_pool, alloc, pool_size)

	p.ctx.in_function = false
	p.ctx.in_generator = false
	p.ctx.in_async = false
	p.ctx.in_loop = false
	p.ctx.in_switch = false
	// strict_mode starts sloppy; parse_program promotes it via the
	// directive-prologue pass or when p.force_strict is set.
	p.ctx.strict_mode = false
	p.ctx.in_method = false
	p.ctx.in_generator_params = false
	p.ctx.in_async_params = false
	p.ctx.in_derived_constructor = false
	p.ctx.class_has_extends = false
	p.label_stack = make([dynamic]string, 0, 4, alloc)
	p.label_is_iteration = make([dynamic]bool, 0, 4, alloc)
	p.ctx.label_floor = 0
	p.lang = lang
	p.source_is_dts = source_is_dts
	p.has_module_syntax = false
	p.private_id_count = 0
	p.pending_paren_start = max(u32) // sentinel: "no `(` pending"

	// Initialize interner - pre-allocate capacity based on source size
	// Small files: minimal map; large files: ~1 unique identifier per 30 bytes
	interner_cap := 64
	if p.source_len > 4096 {
		interner_cap = p.source_len / 30
	}
	interner := new(StringInterner, alloc)
	init_interner(interner, alloc, interner_cap)
	p.interner = interner

	p.lexer = lexer

	// Prime token cache
	prime_token_cache(p)
}


// Returns true if the body contains at least one statement whose presence
// at the top level of a scope contributes work to scope_check_body's lex /
// var / Annex-B clash detection. ExpressionStatement / ReturnStatement /
// EmptyStatement / IfStatement / WhileStatement / ForStatement / etc. are
// all NO-OPs from scope_process_statement's perspective - their union arms
// fall through. Skipping the push for trivial bodies avoids ~5-10 % per-
// callback overhead on real-world bundles like antd.js where most arrow
// bodies are `() => jsx` or `() => { return jsx }` and have nothing to
// verify. The walk is O(N) over the body once at parse-exit, vs the
// scope_check_body call's O(N) + ScopeMap allocations and per-stmt
// switch dispatch - net positive for any body that's more than ~3 stmts.
// CORRECTNESS: BlockStatement is included because scope_process_statement's
// BlockStatement arm calls scope_hoist_vars to extract `var` from nested
// blocks / loops / if-bodies into the outer scope (§14.2.1 hoist), so a
// body whose only statement is `{ var f; }` still needs verification.
has_scope_relevant_stmt :: proc(body: []^Statement) -> bool {
	for stmt in body {
		if stmt == nil { continue }
		#partial switch _ in stmt^ {
		case ^VariableDeclaration,
		     ^FunctionDeclaration,
		     ^ClassDeclaration,
		     ^ImportDeclaration,
		     ^ExportNamedDeclaration,
		     ^ExportDefaultDeclaration,
		     ^BlockStatement,
		     ^ForStatement,
		     ^ForInStatement,
		     ^ForOfStatement:
			return true
		}
	}
	return false
}

new_node :: #force_inline proc(p: ^Parser, $T: typeid) -> ^T {
	if p.profile_enabled {
			p.profile.node_allocs += 1
			p.profile.node_alloc_bytes += u64(size_of(T))
			when T == Expression {
				p.profile.expr_wrapper_allocs += 1
			}
			when T == Statement {
				p.profile.stmt_wrapper_allocs += 1
			}
			when T == Identifier {
				p.profile.identifier_allocs += 1
			}
			when T == MemberExpression {
				p.profile.member_expr_allocs += 1
			}
			when T == CallExpression {
				p.profile.call_expr_allocs += 1
			}
			when T == BinaryExpression {
				p.profile.binary_expr_allocs += 1
			}
			when T == LogicalExpression {
				p.profile.logical_expr_allocs += 1
			}
			when T == Property {
				p.profile.property_allocs += 1
			}
			when T == ObjectExpression {
				p.profile.object_expr_allocs += 1
			}
			when T == ArrayExpression {
			p.profile.array_expr_allocs += 1
		}
	}
	// Try bump pool first (no function-pointer dispatch)
	// Memory from virtual arena is pre-zeroed by OS - skip explicit zero-init
	ptr := bump_alloc(&p.node_pool, size_of(T), align_of(T))
	if ptr != nil {
		return transmute(^T)ptr
	}
	result, _ := mem.new(T, p.allocator)
	return result
}

statement_from :: proc(p: ^Parser, stmt_ptr: ^$T) -> ^Statement {
	if stmt_ptr == nil {
		return nil
	}
	result := new_node(p, Statement)
	result^ = stmt_ptr
	return result
}

// Check if an expression (or SequenceExpression) contains a SpreadElement.
// Used to reject `(b, ...a)` without `=>` — rest/spread in parens is only
// valid as arrow parameter cover grammar.
expr_contains_spread :: proc(expr: ^Expression) -> bool {
	if expr == nil { return false }
	if _, ok := expr^.(^SpreadElement); ok { return true }
	if seq, ok := expr^.(^SequenceExpression); ok {
		for e in seq.expressions {
			if _, s := e^.(^SpreadElement); s { return true }
		}
	}
	return false
}

expression_from :: #force_inline proc(p: ^Parser, expr_ptr: ^$T) -> ^Expression {
	if expr_ptr == nil {
		return nil
	}
	expr := new_node(p, Expression)
	expr^ = expr_ptr
	return expr
}

// Combined alloc: node T + Expression wrapper in one bump, returns ^Expression
// Saves one allocation for the very common pattern: alloc node + wrap.
// Round `v` up to the next multiple of `align` (must be a power of two).
// Used by new_expr / new_stmt to pre-compute alignment padding between the
// concrete node and its union wrapper, so the single bump_alloc reservation
// actually covers the wrapper after alignment. Without this the wrapper can
// overrun the allocation by up to (align_of(Wrapper) - 1) bytes, clobbering
// the first field(s) of the *next* bump-pool allocation.
// Observed symptom (before fix): `f(a.b, false, this)` emitted the `false`
// argument as `{ type: "Unknown", start: 0, end: 0 }` because the
// BooleanLiteral's Expression wrapper overflowed its 36-byte reservation by
// 4 bytes, smashing the first half of the subsequent `new_node(ThisExpression)`
// allocation. Only literals whose `size_of(T)` % `align_of(Expression)` != 0
// were affected, which is why it showed up in the narrow window of
// `BooleanLiteral, <next-alloc>` pairs.
round_up_to :: #force_inline proc(v, align: uintptr) -> uintptr {
	return (v + align - 1) & ~(align - 1)
}

new_expr :: #force_inline proc(p: ^Parser, $T: typeid) -> (^T, ^Expression) {
	// Reserve the padding between node and wrapper inside total_size so the
	// bump region actually spans both.
	node_end := round_up_to(uintptr(size_of(T)), uintptr(align_of(Expression)))
	total_size := int(node_end) + size_of(Expression)
	align := max(align_of(T), align_of(Expression))
	ptr := bump_alloc(&p.node_pool, total_size, align)
	if ptr != nil {
		node := transmute(^T)ptr
		wrap := transmute(^Expression)(uintptr(ptr) + node_end)
		wrap^ = node
		return node, wrap
	}
	node, _ := mem.new(T, p.allocator)
	expr := new_node(p, Expression)
	expr^ = node
	return node, expr
}

new_stmt :: #force_inline proc(p: ^Parser, $T: typeid) -> (^T, ^Statement) {
	// Same alignment-aware layout as new_expr - see comment there for why.
	node_end := round_up_to(uintptr(size_of(T)), uintptr(align_of(Statement)))
	total_size := int(node_end) + size_of(Statement)
	align := max(align_of(T), align_of(Statement))
	ptr := bump_alloc(&p.node_pool, total_size, align)
	if ptr != nil {
		node := transmute(^T)ptr
		wrap := transmute(^Statement)(uintptr(ptr) + node_end)
		wrap^ = node
		return node, wrap
	}
	node, _ := mem.new(T, p.allocator)
	stmt := new_node(p, Statement)
	stmt^ = node
	return node, stmt
}

// Report an error
// `LexerLoc` carries only `offset` now. Line / column are computed at
// print time by `parse_error_line_column` (helper at the bottom of the
// file) so we don't pay for them on the hot path of every successful
// parse. The lazy line-table build still lives there, gated on the
// first time anyone asks for line info.
// await_using_starts_decl decides whether `await using ...` at the
// current position starts an AwaitUsingDeclaration (returns true) or
// is an `await` expression with `using` as the operand (returns false).
// Uses a 3-token lookahead via lexer snapshot/restore: advances past
// `await` and `using`, checks the third token, then rewinds.
// ensure_module_syntax_resolved makes sure p.has_module_syntax is
// authoritative for the current parser state. Called lazily from the
// (rare) places where a parsing decision depends on whether the file
// is a module BEFORE the parser has reached an import/export token.
// Idempotent: the first call runs the SIMD pre-scan; subsequent calls
// hit the module_pre_scan_done cache and return immediately.
// Skips the scan when the answer is already known:
//   * --source-type forced — the answer doesn't depend on source.
//   * has_module_syntax already true — a parser-side write (parsing
//     an import/export token) beat us to it.
//   * TS / TSX file — the TS-mode path doesn't currently consult the
//     pre-scan; .d.ts files always allow await as identifier anyway.
//   * No lexer attached (defensive; happens only in the test harness).
// Cost on bench/real_world/typescript.js (9 MB CJS bundle): zero.
// The bench files don't use top-level await / for-await / using, so
// none of the lazy entry points fire.
ensure_module_syntax_resolved :: #force_inline proc(p: ^Parser) {
	if p.module_pre_scan_done { return }
	if p.has_module_syntax {
		p.module_pre_scan_done = true
		return
	}
	if _, have := p.force_source_type.(SourceType); have {
		p.module_pre_scan_done = true
		return
	}
	if allow_ts_mode(p) || p.lexer == nil {
		p.module_pre_scan_done = true
		return
	}
	pre_scan_for_module_syntax(p)
	p.module_pre_scan_done = true
}

// pre_scan_for_module_syntax does a fast byte-level scan of the source
// to detect top-level `import` or `export` tokens. Sets
// `p.has_module_syntax = true` if found, so that the main parse knows
// upfront that `await` is a keyword (not an identifier).
// The scan is a SIMD-accelerated state machine:
//   - Outer loop uses simd_find_module_pre_scan_candidate to skip 16
//     boring bytes at a time on ARM64 NEON; the inner state machine
//     only fires on bytes in {/, ', ", `, {, }, i, e}.
//   - Comment / string / template skipping reuses the existing
//     simd_skip_line_comment / simd_skip_block_comment / simd_find_string_end
//     helpers from the lexer hot path.
//   - Tracks brace depth so import/export inside function bodies is
//     ignored.
//   - Matches `import` and `export` as whole words at depth 0.
// Runs in O(n) time with no allocation. On bench/real_world/typescript.js
// (9 MB CJS bundle, no top-level module syntax — worst case for the
// pre-scan) this is ~3× faster than the byte-by-byte scalar version that
// shipped in f0c1201. Together with the unchanged main parse, the file
// returns from kessel’s `< OXC` regime measured in s25 (geo-mean ~0.93×).
pre_scan_for_module_syntax :: proc(p: ^Parser) {
	src := p.lexer.source_bytes
	n := len(src)
	i := 0
	depth := 0  // brace depth

	for i < n {
		// Skip the (vast majority of) non-candidate bytes via SIMD. After
		// this jump we either land on a candidate or reach end-of-source.
		i = simd_find_module_pre_scan_candidate(src, i)
		if i >= n { return }
		c := src[i]

		// Comments — reuse the lexer's SIMD skippers.
		if c == '/' && i + 1 < n {
			next := src[i+1]
			if next == '/' {
				end, _ := simd_skip_line_comment(src, i + 2)
				i = end
				continue
			}
			if next == '*' {
				end, _ := simd_skip_block_comment(src, i + 2)
				i = end
				continue
			}
			// Bare `/` (division or regex). Advance past and continue.
			i += 1
			continue
		}

		// Strings — simd_find_string_end finds the next quote / backslash.
		if c == '\'' || c == '"' {
			quote := c
			i += 1
			for i < n {
				pos, found_quote, _ := simd_find_string_end(src[i:], quote)
				i += pos
				if i >= n { break }
				if found_quote { i += 1; break }
				// Backslash: skip the backslash + the escaped byte.
				i += 2
			}
			continue
		}

		// Template literals — same shape as string skipping. We don't
		// track ${...} nesting because at depth 0 the body of a template
		// can't validly contain a top-level `export` / `import`; even if
		// it did somehow appear via interpolation it would be inside an
		// expression, raising depth via `{`.
		if c == '`' {
			i += 1
			for i < n {
				pos, found_bt, _ := simd_find_string_end(src[i:], '`')
				i += pos
				if i >= n { break }
				if found_bt { i += 1; break }
				i += 2
			}
			continue
		}

		// Brace depth.
		if c == '{' { depth += 1; i += 1; continue }
		if c == '}' { if depth > 0 { depth -= 1 }; i += 1; continue }

		// Keyword candidates (`i` / `e`). Only at depth 0.
		if depth == 0 {
			if c == 'e' && i + 6 <= n &&
			   src[i+1] == 'x' && src[i+2] == 'p' && src[i+3] == 'o' &&
			   src[i+4] == 'r' && src[i+5] == 't' &&
			   (i + 6 >= n || !is_id_continue_byte(src[i+6])) &&
			   (i == 0 || !is_id_continue_byte(src[i-1])) {
				p.has_module_syntax = true
				return
			}
			if c == 'i' && i + 6 <= n &&
			   src[i+1] == 'm' && src[i+2] == 'p' && src[i+3] == 'o' &&
			   src[i+4] == 'r' && src[i+5] == 't' &&
			   (i + 6 >= n || !is_id_continue_byte(src[i+6])) &&
			   (i == 0 || !is_id_continue_byte(src[i-1])) {
				// `import(` is dynamic import — module syntax.
				// `import.` is import.meta — module syntax.
				// `import "x"` / `import 'x'` / `import {` / `import *` — static import.
				// `import x` — default import.
				// Exception: `new import(` is a SyntaxError, not module syntax.
				// Check preceding non-whitespace for `new`.
				preceded_by_new := false
				if i >= 3 {
					k := i - 1
					for k >= 0 && (src[k] == ' ' || src[k] == '\t' ||
					               src[k] == '\n' || src[k] == '\r') { k -= 1 }
					if k >= 2 && src[k] == 'w' && src[k-1] == 'e' && src[k-2] == 'n' &&
					   (k-2 == 0 || !is_id_continue_byte(src[k-3])) {
						preceded_by_new = true
					}
				}
				if !preceded_by_new && i + 6 < n {
					p.has_module_syntax = true
					return
				}
			}
		}
		i += 1
	}
}

// Quick byte-level check: is this byte a valid IdentifierPart ASCII char?
// Used by pre_scan_for_module_syntax for word-boundary detection.
is_id_continue_byte :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
	       (c >= '0' && c <= '9') || c == '_' || c == '$'
}

// Declaration if and only if the third token is a BindingIdentifier
// with no preceding LineTerminator. Anything else - `[`, `.`, `(`,
// `` ` ``, `?`, `;`, `in`, `instanceof`, `of`, operators - means
// `using` is an expression-position identifier.
await_using_starts_decl :: proc(p: ^Parser) -> bool {
	snap := lexer_snapshot(p)
	advance_token(p) // consume `await`  → cur=`using`
	advance_token(p) // consume `using`  → cur=third token
	third_type := p.cur_type
	third_lt := cur_has_newline(p)
	lexer_restore(p, snap)
	// A LineTerminator between `using` and the binding breaks the
	// restricted production.
	if third_lt { return false }
	// The token must be a BindingIdentifier - an Identifier or a
	// contextual keyword that can serve as one.
	return third_type == .Identifier || can_be_binding_identifier(third_type)
}

// using_starts_decl decides whether `using ...` at the current position
// starts a UsingDeclaration (returns true) or is a plain Identifier
// expression where `using` is just a name (returns false).
// 2-token lookahead: a UsingDeclaration must be followed by a
// BindingIdentifier with no preceding LineTerminator. Without that,
// `using` is just an Identifier (e.g. `export default using;` or
// `using;` as an expression statement).
// Note: this is the non-for-head form. Inside a for-init, the caller
// must additionally disambiguate `for (using of ...)` between
// `for (<expr> of <iter>)` and `for (using <name=of> ;)` — see the
// inline logic in parse_for_statement.
using_starts_decl :: proc(p: ^Parser) -> bool {
	nxt := peek_token(p)
	if nxt.had_line_terminator { return false }
	return nxt.type == .Identifier || can_be_binding_identifier(nxt.type)
}

// report_error surfaces a diagnostic at the CURRENT token. The span is
// [cur.start, cur.end), so the error covers the whole offending token
// instead of a single byte — callers that just need a caret keep the
// caret at .start; renderers that want an underline get the full extent
// for free. End-of-source errors trivially collapse to start == end.
report_error :: proc(p: ^Parser, message: string) {
	bump_append(&p.errors, ParseError{
		start   = cur_offset(p),
		end     = cur_raw_end(p),
		message = message,
	})
	if p.profile_enabled {
		p.profile.errors_reported += 1
	}
}

// report_error_at reports at an explicit single-point offset (start == end).
// Used by call sites that already have a known offset (e.g. saved from a
// prior token boundary) but no matching end — a future pass can widen
// these by passing a real span via report_error_span.
report_error_at :: #force_inline proc(p: ^Parser, loc: LexerLoc, message: string) {
	bump_append(&p.errors, ParseError{start = u32(loc), end = u32(loc), message = message})
}

// report_error_span is the explicit-span variant. Prefer this whenever a
// caller has both ends of the offending range.
report_error_span :: #force_inline proc(p: ^Parser, start, end: u32, message: string) {
	bump_append(&p.errors, ParseError{start = start, end = end, message = message})
}

// report_error_coded is the code-carrying variant of `report_error`.
// Spans the current token (same as `report_error`) and attaches both
// a stable `ErrorCode` and the severity from the message table. The
// `message` argument is the FINAL wording shown to the user — callers
// that want the canonical wording read it from `error_info(code).default_message`;
// callers that quote source text build a richer string here and still
// pass the code so tooling can group / suppress / look it up.
report_error_coded :: proc(p: ^Parser, code: ErrorCode, message: string) {
	info := error_info(code)
	bump_append(&p.errors, ParseError{
		start    = cur_offset(p),
		end      = cur_raw_end(p),
		message  = message,
		code     = code,
		severity = info.severity,
	})
	if p.profile_enabled {
		p.profile.errors_reported += 1
	}
}

// report_error_coded_span is the explicit-span + code variant. Use this
// when both ends of the offending range are known (e.g. a saved token
// span from before a recovery rollback) and a stable code applies.
report_error_coded_span :: #force_inline proc(p: ^Parser, code: ErrorCode, start, end: u32, message: string) {
	info := error_info(code)
	bump_append(&p.errors, ParseError{
		start    = start,
		end      = end,
		message  = message,
		code     = code,
		severity = info.severity,
	})
}

enable_profiling :: proc(p: ^Parser) {
	if p == nil {
		return
	}
	p.profile_enabled = true
	p.profile = {}
}

get_profile :: proc(p: ^Parser) -> ParserProfile {
	if p == nil {
		return {}
	}
	return p.profile
}

get_bump_stats :: proc(p: ^Parser) -> (used: int, capacity: int, overflow_count: int) {
	if p == nil { return 0, 0, 0 }
	return p.node_pool.offset, p.node_pool.capacity, p.node_pool.overflow_count
}

// Expect a specific token type. Phase 3: emits a coded
// K2002_ExpectedToken diagnostic and uses source-aware token formatting
// for the "got" side, so a missing `}` before `foo` now reads
// `Expected '}', got identifier 'foo'` instead of the previous
// `Expected }, got identifier`.
expect_token :: #force_inline proc(p: ^Parser, t: TokenType) -> bool {
	if p.cur_type != t {
		msg := fmt.tprintf(
			"Expected %s, got %s",
			format_expected_token(t),
			format_actual_token(p),
		)
		report_error_coded(p, .K2002_ExpectedToken, msg)
		return false
	}
	skip_token(p)
	return true
}

// Advance without returning old token - avoids 58-byte struct copy
// Use for match_token and discard sites where old token isn't needed
skip_token :: #force_inline proc(p: ^Parser) {
	advance_token(p)
}

is_token :: #force_inline proc(p: ^Parser, t: TokenType) -> bool {
	return p.cur_type == t
}

is_next_token :: #force_inline proc(p: ^Parser, t: TokenType) -> bool {
	if p.lexer != nil {
		ensure_nxt(p)
		return p.lexer.nxt.kind == t
	}
	return false
}

// Check if next token is an Identifier with a specific string value.
// Used for TS contextual keywords (type, interface, enum) that lex as Identifier.
is_next_identifier_value :: #force_inline proc(p: ^Parser, value: string) -> bool {
	if p.lexer == nil { return false }
	ensure_nxt(p)
	nxt := p.lexer.nxt
	if nxt.kind != .Identifier { return false }
	if nxt.end - nxt.start != u32(len(value)) { return false }
	return p.lexer.source[nxt.start:nxt.end] == value
}

match_token :: #force_inline proc(p: ^Parser, t: TokenType) -> bool {
	if p.cur_type == t {
		skip_token(p)
		return true
	}
	return false
}

eat :: #force_inline proc(p: ^Parser) {
	advance_token(p)
}


// ============================================================================
// Automatic Semicolon Insertion (ASI)
// ============================================================================

// can_insert_semicolon checks if ASI is allowed according to ECMAScript spec.
// Matches OXC's implementation: any line terminator before the current token,
// or current token is `}` or EOF, triggers ASI. Continuation tokens (`(`, `[`,
// etc.) are NOT suppressed here - the expression parser's LHS-tail loop
// handles them by breaking on `had_line_terminator` before consuming call /
// member-access / tagged-template continuations.
can_insert_semicolon :: #force_inline proc(p: ^Parser) -> bool {
	if cur_has_newline(p) {
		return true
	}
	if p.cur_type == .RBrace || p.cur_type == .EOF {
		return true
	}
	return false
}

// expect_close_paren_or_recover — expects `)`. When NOT in strict mode
// and `{` follows (the `)` was forgotten before a body), silently
// recover. OXC's parser infers missing `)` in sloppy-mode fixtures
// like missingCloseParenStatements.ts. Strict-mode fixtures (which
// include the SkippedTokens negative suite) keep the strict error.
expect_close_paren_or_recover :: #force_inline proc(p: ^Parser) -> bool {
	if p.cur_type == .RParen {
		skip_token(p)
		return true
	}
	// TS sloppy-mode recovery: `{` after condition → infer missing `)`.
	// Only in TS mode to avoid breaking JS must-reject fixtures (e.g.
	// 002_missing_closing_paren.js). OXC's parser infers the missing `)`
	// for TS fixtures like missingCloseParenStatements.ts.
	if allow_ts_mode(p) && !p.ctx.strict_mode && p.cur_type == .LBrace {
		return true
	}
	msg := fmt.tprintf(
		"Expected %s, got %s",
		format_expected_token(.RParen),
		format_actual_token(p),
	)
	report_error_coded(p, .K2002_ExpectedToken, msg)
	return false
}

// expect_semicolon_or_asi expects a semicolon or allows ASI
expect_semicolon_or_asi :: #force_inline proc(p: ^Parser) -> bool {
	if p.cur_type == .Semi {
		advance_token(p)
		return true
	}
	if can_insert_semicolon(p) {
		return true
	}
	report_error_coded(p, .K2010_ExpectedSemicolon, "Expected semicolon")
	return false
}

// match_semicolon_or_asi_export - like match_semicolon_or_asi but with
// permissive ASI for export/import declarations. These are statements, not
// expressions - `[` or `(` on the next line can't be a continuation.
// Treats any line terminator as ASI, regardless of the next token.
match_semicolon_or_asi_export :: #force_inline proc(p: ^Parser) -> bool {
	if p.cur_type == .Semi { advance_token(p); return true }
	if cur_has_newline(p) { return true }
	if p.cur_type == .RBrace || p.cur_type == .EOF { return true }
	return false
}

// match_semicolon_or_asi tries to match a semicolon or allows ASI (for optional cases)
match_semicolon_or_asi :: #force_inline proc(p: ^Parser) -> bool {
	if p.cur_type == .Semi {
		advance_token(p)
		return true
	}
	return can_insert_semicolon(p)
}

string_literal_can_be_directive :: #force_inline proc(p: ^Parser) -> bool {
	ensure_nxt(p)
	nxt := p.lexer.nxt
	if nxt.kind == .Semi || nxt.kind == .RBrace || nxt.kind == .EOF {
		return true
	}
	if (nxt.flags & FLAG_NEW_LINE) != 0 {
		#partial switch nxt.kind {
		case .LBracket, .LParen, .Template, .TemplateHead, .Plus, .Minus, .Div, .Dot,
		     .LAngle:  // `<` continues as relational binary (OXC matches)
			return false
		}
		return true
	}
	return false
}

// ============================================================================
// Entry Point - Parse Program
// ============================================================================

parse_program_item :: proc(p: ^Parser, body: ^[dynamic]^Statement, start_offset: int) {
	// §Explicit Resource Management — `using` / `await using` at the
	// top level of a Script is a SyntaxError (§14.3). Migrated to the
	// semantic checker (ck_check_using_at_script_top); the parser stays
	// permissive (it builds the VariableDeclaration node either way).

	// Catch stray tokens that aren't valid statement starts (dangling
	// `else`, orphan `}`, etc.) with a dedicated diagnostic rather than
	// letting error recovery silently eat them. `.Else` only arrives here
	// when it didn't match a preceding `if`; `.RBrace` at top-level is an
	// unmatched closing brace; `.Catch`/`.Finally` without a preceding
	// `try` are equally stray.
	#partial switch p.cur_type {
	case .Else:
		report_error_coded(p, .K2040_UnexpectedToken, "Unexpected 'else' without matching 'if'")
		recovery_eat(p)
		if !is_token(p, .EOF) { _ = parse_statement_or_declaration(p) }
		return
	case .RBrace:
		report_error_coded(p, .K2040_UnexpectedToken, "Unexpected '}' \u2014 unmatched closing brace")
		recovery_eat(p)
		return
	case .Catch, .Finally:
		report_error_coded(p, .K2040_UnexpectedToken, "Unexpected 'catch' or 'finally' without matching 'try'")
		recovery_eat(p)
		if !is_token(p, .EOF) { _ = parse_statement_or_declaration(p) }
		return
	}

	stmt := parse_statement_or_declaration(p)
	if stmt != nil {
		append(body, stmt)
		// .d.ts files: only declarations are allowed at the top level.
		// OXC reports "A 'declare' modifier is required for a top level
		// declaration in a .d.ts file" for non-declaration statements.
		if p.source_is_dts {
			report_dts_non_declaration(p, stmt)
		}
		return
	}

	// Try to parse as expression statement (e.g., dynamic import)
	if !is_token(p, .EOF) && int(cur_offset(p)) == start_offset {
		// Still at same position, try expression
		expr_stmt := parse_expression_statement(p)
		if expr_stmt != nil {
			append(body, expr_stmt)
			return
		}

		// Error recovery: we are stuck - consume tokens aggressively.
		// Report the unexpected-token error on the first stuck iteration
		// so test262 negative fixtures that expect a parse-phase SyntaxError
		// get one (e.g. `{} * 1`, `x\n++`, bare `*`, etc.).
		// Suppress the extra diagnostic when a prior error was already
		// emitted at the same token offset (e.g. "Expected expression after
		// operator" from inside a broken initializer).
		stuck_count := 0
		for !is_token(p, .EOF) && int(cur_offset(p)) == start_offset {
			if stuck_count == 0 {
				recovery_report_unexpected_token_top_level(p)
			}
			stuck_count += 1
			if stuck_count > PARSER_RECOVERY_STUCK_TOKEN_LIMIT {
				// Emergency: force consume and break
				recovery_eat(p)
				break
			}
			// Try to skip to a safe token
			if recovery_is_statement_sync_token(p) {
				recovery_eat(p)
				break
			}
			recovery_eat(p)
		}
		return
	}

	// Error recovery: consume token to avoid infinite loop
	if !is_token(p, .EOF) {
		recovery_eat(p)
	}
}

// .d.ts file: reject non-declaration statements at top level.
// OXC reports these as parser errors. The check is intentionally
// conservative — only known statement types are flagged; unrecognised
// AST variants fall through silently.
report_dts_non_declaration :: proc(p: ^Parser, stmt: ^Statement) {
	if stmt == nil { return }
	stmt_loc := dts_stmt_loc(stmt)
	#partial switch _ in stmt^ {
	// Pure statements — always illegal in .d.ts.  Declarations
	// (VariableDeclaration, FunctionDeclaration, ClassDeclaration, etc.)
	// are implicitly ambient in .d.ts, so `declare` is optional.
	case ^ExpressionStatement, ^BlockStatement,
	     ^DebuggerStatement, ^WithStatement, ^ReturnStatement,
	     ^LabeledStatement, ^BreakStatement, ^ContinueStatement,
	     ^IfStatement, ^SwitchStatement, ^ThrowStatement,
	     ^TryStatement, ^WhileStatement, ^DoWhileStatement,
	     ^ForStatement, ^ForInStatement, ^ForOfStatement:
		report_error_coded_span(p, .K4050_AmbientContextRestriction, u32(stmt_loc), u32(stmt_loc), "Statements are not allowed in declaration files")
	}
}

// Extract the start offset from any Statement variant's .loc field.
dts_stmt_loc :: proc(stmt: ^Statement) -> u32 {
	if stmt == nil { return 0 }
	#partial switch v in stmt^ {
	case ^ExpressionStatement:  if v != nil { return v.loc.start }
	case ^BlockStatement:       if v != nil { return v.loc.start }
	case ^EmptyStatement:       if v != nil { return v.loc.start }
	case ^DebuggerStatement:    if v != nil { return v.loc.start }
	case ^WithStatement:        if v != nil { return v.loc.start }
	case ^ReturnStatement:      if v != nil { return v.loc.start }
	case ^LabeledStatement:     if v != nil { return v.loc.start }
	case ^BreakStatement:       if v != nil { return v.loc.start }
	case ^ContinueStatement:    if v != nil { return v.loc.start }
	case ^IfStatement:          if v != nil { return v.loc.start }
	case ^SwitchStatement:      if v != nil { return v.loc.start }
	case ^ThrowStatement:       if v != nil { return v.loc.start }
	case ^TryStatement:         if v != nil { return v.loc.start }
	case ^WhileStatement:       if v != nil { return v.loc.start }
	case ^DoWhileStatement:     if v != nil { return v.loc.start }
	case ^ForStatement:         if v != nil { return v.loc.start }
	case ^ForInStatement:       if v != nil { return v.loc.start }
	case ^ForOfStatement:       if v != nil { return v.loc.start }
	case ^VariableDeclaration:  if v != nil { return v.loc.start }
	case ^FunctionDeclaration:  if v != nil { return v.loc.start }
	case ^ClassDeclaration:     if v != nil { return v.loc.start }
	}
	return 0
}

parse_program :: proc(p: ^Parser, source_type: SourceType) -> ^Program {
	program := new_node(p, Program)
	// Program span always starts at byte 0 (even if the source begins with a
	// shebang, comments, or whitespace) to match ESTree/OXC/Acorn semantics.
	// `cur_loc` would return the start of the FIRST token, which skips over
	// leading comments and shebang lines.
	program.loc = Loc{start = 0, end = 0}
	program.type = source_type

	// --force-strict (CLI) opts into strict mode regardless of the body's
	// directive prologue. Set here (not in init_parser) because main.odin
	// flips p.force_strict AFTER init_parser has already zeroed
	// p.ctx.strict_mode. Used by the Test262 runner for `flags: [onlyStrict]`
	// fixtures.
	if p.force_strict {
		p.ctx.strict_mode = true
	}

	// §16.2.1 - Module code is always strict mode (§16.2.2).
	if fs, have := p.force_source_type.(SourceType); have && fs == .Module {
		p.ctx.strict_mode = true
	}

	// §16.2.1 - ImportDeclaration and ExportDeclaration are ModuleItems,
	// only legal at the top level of a Module body. Set the flag when we
	// know upfront (--source-type=module pin) that this is a Module, so
	// the nested-position check fires correctly during the parse.
	if fs, have := p.force_source_type.(SourceType); have && fs == .Module {
		p.in_module_top_level = true
	}

	// Module-syntax pre-scan was previously called UNCONDITIONALLY
	// here. For a 9 MB CJS bundle with no module syntax (e.g.
	// bench/real_world/typescript.js) the scan ran the entire 9 MB —
	// ~18 ms regression vs the s25 baseline. The scan is now triggered
	// LAZILY by ensure_module_syntax_resolved, called only from the
	// four constructs whose validity depends on the answer being
	// available BEFORE the parser reaches an explicit import/export
	// token: top-level `await`, `for await`, `using`, `await using`.
	// CJS bundles don't use any of those, so they pay zero pre-scan
	// cost — restoring the s25-era 0.93×-of-OXC performance regime.

	_ = p.lexer
	// Pre-size body based on source length: ~1 top-level statement per 50 bytes
	body_cap := 16
	if p.source_len > 4096 {
		body_cap = p.source_len / 50
	}
	program.body = make([dynamic]^Statement, 0, body_cap, p.allocator)
	program.directives = make([dynamic]Directive, 0, 2, p.allocator)

	// Parse body
	no_progress_count := 0
	for !is_token(p, .EOF) {
		loop_start_offset := int(cur_offset(p))

		if is_token(p, .String) && string_literal_can_be_directive(p) {
			// Check for "use strict" directive.
			// §11.1.1 — directive prologues must be exact string literals
			// with no escape sequences. `'use\x20strict'` decodes to
			// "use strict" but is NOT a valid directive because the raw
			// source contains an escape sequence.
			current := snap_current(p)
			has_escape := strings.contains(current.value, "\\") 
			if current.literal == "use strict" && !has_escape {
				p.ctx.strict_mode = true
				// Retroactive check: string literals in the directive
				// prologue BEFORE "use strict" must not contain legacy
				// octal escapes (\0-\7) or \8/\9 (ES2021 §12.9.4.1).
				check_retroactive_strict_escapes(p, program.body[:])
				directive := Directive{
					loc   = loc_from_token(&current),
					value = StringLiteral{
						loc   = loc_from_token(&current),
						value = "use strict",
						raw   = current.value,
					},
					raw = current.value,
				}
				bump_append(&program.directives, directive)
				// Also emit as ExpressionStatement in body (ESTree compat). Mark
				// the ExpressionStatement as a directive prologue via its `directive`
				// field so the emitter writes ESTree's `directive: "use strict"`.
				str_lit, str_lit_e := new_expr(p, StringLiteral)
				str_lit.loc = loc_from_token(&current)
				str_lit.value = current.literal.(string) or_else ""
				str_lit.raw = current.value
				expr_stmt, expr_stmt_s := new_stmt(p, ExpressionStatement)
				expr_stmt.loc = directive.loc
				expr_stmt.expression = str_lit_e
				expr_stmt.directive = "use strict"
				bump_append(&program.body, expr_stmt_s)
				eat(p)
				match_semicolon_or_asi(p)
				expr_stmt.loc.end = prev_end_offset(p)
			} else {
				parse_program_item(p, &program.body, loop_start_offset)
			}
		} else {
			parse_program_item(p, &program.body, loop_start_offset)
		}

		if int(cur_offset(p)) == loop_start_offset {
			no_progress_count += 1
			if no_progress_count > p.resource_budget.error_recovery_iterations {
				report_error_coded(p, .K2080_ParserBudgetExceeded, "Maximum parsing iterations exceeded - possible infinite loop")
				break
			}
		} else {
			no_progress_count = 0
		}
	}

	// Program.end covers the ENTIRE source (including any trailing whitespace
	// after the last token). OXC/Acorn/Babel all end Program at source.length
	// in .js / .jsx mode; `prev_end_offset` would stop at the last consumed
	// token, which may be earlier when the file has trailing newlines or
	// comments.
	program.loc.end = u32(p.source_len)

	// OXC-TS quirk: in .ts / .tsx mode OXC sets program.start = body[0].start
	// (skipping leading comments/whitespace), while still ending at source.length.
	// Mirror that behaviour here so the deep-compare against OXC matches; no
	// effect on .js / .jsx where program.start stays 0.
	if (p.lang == .TS || p.lang == .TSX) && len(program.body) > 0 {
		first_loc := get_statement_loc(program.body[0])
		if first_loc.start != 0 || first_loc.end != 0 {
			program.loc.start = first_loc.start
		}
	}

	// Auto-detect module vs script sourceType: any top-level import/export makes
	// this a module per ECMA-262 §16.2. We do this after parse so the body is
	// already populated; callers that want to force a source type can still pass
	// `.Module` explicitly (upgrade-only - we never downgrade Module → Script).
	// Also detects import.meta which requires module context.
	// Matches OXC / Acorn / Babel auto-detection behaviour.
	// Skip auto-upgrade entirely when the caller pinned a SourceType via
	// --source-type=script. Module remains Module always.
	if p.force_source_type != nil {
		// Already set to the forced value at program.type = source_type above.
	} else if source_type == .Script {
		if p.has_module_syntax {
			program.type = .Module
		} else {
			for stmt in program.body {
				if stmt == nil { continue }
				#partial switch _ in stmt^ {
				case ^ImportDeclaration, ^ExportNamedDeclaration,
				     ^ExportDefaultDeclaration, ^ExportAllDeclaration,
				     ^TSExportAssignment:
					program.type = .Module
					break
				}
				if program.type == .Module { break }
			}
		}
	}

	// ECMA-262 §B.1.3: Annex B HTML-like comments (`<!--`, `-->`) are
	// ONLY valid in script source. The lexer skips them eagerly while
	// `is_module_mode` is false, so when the file turns out to be a Module
	// (auto-promoted via top-level import/export, or via `export = X` in
	// TS) the comments need a retroactive rejection. Anchor at the offset
	// of the FIRST skipped HTML comment to match OXC's diagnostic location.
	if program.type == .Module && p.lexer != nil && p.lexer.html_comment_skipped {
		report_error_coded_span(p, .K2040_UnexpectedToken, u32(p.lexer.html_comment_offset), u32(p.lexer.html_comment_offset), "HTML comments are not allowed in modules")
	}

	// §16.2.2 ExportedBindings resolution: `export { foo };` (no `from`)
	// must refer to a binding actually declared in the module. This runs
	// after source-type is finalized so we skip the check for scripts
	// (they're already diagnosed by the module-syntax-in-script gate).
	// `ast_only` skips this and the duplicate-binding pass below to match
	// what OXC's parser does (it defers all of these to oxc_semantic).
	if !p.ast_only {
		verify_export_locals(p, program)

		// TS2309 — `export =` cannot coexist with other exports.
		if allow_ts_mode(p) {
			report_ts2309_export_assignment(p, program.body[:])
		}

	}

	// §13.2.5.1 CoverInitializedName: any ObjectExpression that parsed
	// with a `{ ident = init }` shorthand but didn't get promoted to
	// an ObjectPattern (via expr_to_pattern) is a SyntaxError. Reported
	// after all expr_to_pattern calls have had a chance to clear their
	// entries from p.pending_cover_inits.
	for off in p.pending_cover_inits {
		bump_append(&p.errors, ParseError{
			start   = off,
			end     = off,
			message = "Invalid shorthand property initializer",
		})
	}
	// §13.2.5.1 duplicate __proto__ in object literal: any entries
	// still pending here are genuine ObjectExpressions that didn't get
	// promoted to ObjectPattern by expr_to_pattern. Report them.
	for off in p.pending_proto_dups {
		bump_append(&p.errors, ParseError{
			start   = off,
			end     = off,
			message = "Redefinition of __proto__ property",
		})
	}

	// TS2391 / TS2389 — top-level function overload chain validation.
	// Mirrors report_ts_overload_chain_errors for class methods.
	if allow_ts_mode(p) && !p.ctx.in_ambient && !p.source_is_dts {
		report_ts_function_overload_errors(p, program.body[:])
	}

	// §15.7.3 AllPrivateIdentifiersValid — every PrivateIdentifier
	// reference must resolve to a PrivateName declared by some lexically
	// enclosing ClassBody. Migrated to the semantic checker
	// (ck_check_private_name_resolved + per-class push/pop in
	// ck_walk_class). The parser stays permissive.

	// Drain lexer-side diagnostics (invalid numeric separators, bad
	// BigInt literals, etc.) into p.errors. The lexer couldn't report
	// directly because error reporting needs line/col lazy-lookup off
	// the Parser; this is the first point after parse where we're sure
	// the lexer has seen every token.
	if p.lexer != nil && len(p.lexer.lexer_errors) > 0 {
		for lex_err in p.lexer.lexer_errors {
			// Propagate the lexer's code + severity into the parser's
			// error list so JSON / pretty / binary emitters all see
			// the same K-code regardless of which pass produced the
			// diagnostic. `error_info` provides the severity since
			// LexerError doesn't carry one (lexer-side warnings are
			// not yet a thing).
			info := error_info(lex_err.code)
			err := ParseError{
				start    = lex_err.offset,
				end      = lex_err.offset,
				message  = lex_err.message,
				code     = lex_err.code,
				severity = info.severity,
			}
			bump_append(&p.errors, err)
		}
	}

	// §14.2.1 — program-level lex/var clash check.

	// TS declaration conflict check — catches cross-kind redeclarations
	// (class+class, class+enum, type+type, enum+var, etc.) that the
	// standard scope check skips in TS mode.
	check_ts_scope_conflicts(p, program.body[:])

	// §14.2.1 — program-level lex/var clash check.
	parser_scope_check(p, program.body[:], false)

	return program
}

// Retroactive octal/\8/\9 check for directive-prologue strings that
// precede "use strict" at program level. Called once when "use strict"
// is encountered. Uses the same string_raw_has_forbidden_escape helper
// that the function-body prologue check uses.
check_retroactive_strict_escapes :: proc(p: ^Parser, body: []^Statement) {
	for stmt in body {
		es, ok := stmt^.(^ExpressionStatement)
		if !ok { continue }
		expr := es.expression
		if expr == nil { continue }
		sl, is_str := expr^.(^StringLiteral)
		if !is_str { continue }
		if string_raw_has_forbidden_escape(sl.raw) {
			report_error_coded_span(p, .K3051_StrictModeProhibited, u32(sl.loc.start), u32(sl.loc.start), "Octal or \\8 / \\9 escape sequences are not allowed in strict mode")
		}
	}
}

// check_arrow_body_strict_prologue — scans an arrow function's block body
// for a "use strict" directive prologue. If found, retroactively checks
// all preceding prologue strings for forbidden escape sequences, and also
// checks strings AFTER the directive in the prologue. Mirrors the function-
// body prologue logic in parse_function_body.
check_arrow_body_strict_prologue :: proc(p: ^Parser, body: []^Statement) {
	// Find "use strict" in the directive prologue.
	use_strict_idx := -1
	for stmt, i in body {
		if stmt == nil { break }
		es, ok := stmt^.(^ExpressionStatement)
		if !ok { break } // first non-ExpressionStatement ends prologue
		expr := es.expression
		if expr == nil { break }
		sl, is_str := expr^.(^StringLiteral)
		if !is_str { break } // first non-string-literal expr ends prologue
		if sl.value == "use strict" && !strings.contains(sl.raw, "\\") {
			use_strict_idx = i
			break
		}
	}
	if use_strict_idx < 0 { return }

	// Check ALL prologue strings (before and after directive) for forbidden escapes.
	for stmt, i in body {
		if stmt == nil { break }
		es, ok := stmt^.(^ExpressionStatement)
		if !ok { break }
		expr := es.expression
		if expr == nil { break }
		sl, is_str := expr^.(^StringLiteral)
		if !is_str { break }
		if i == use_strict_idx { continue } // skip the directive itself
		if string_raw_has_forbidden_escape(sl.raw) {
			report_error_coded_span(p, .K3051_StrictModeProhibited, u32(sl.loc.start), u32(sl.loc.start), "Octal or \\8 / \\9 escape sequences are not allowed in strict mode")
		}
	}
}

// ============================================================================
// Async Arrow Function Helpers
// ============================================================================

parse_async_arrow_function :: proc(p: ^Parser, param: Identifier) -> ^Expression {
	start := param.loc

	if param.name == "await" {
		report_error_coded(p, .K3010_AwaitYieldAsBindingName,
			"'await' cannot be used as an async arrow parameter")
	}
	if cur_has_newline(p) {
		report_error_coded(p, .K3064_LineTerminatorRestricted, "Line terminator not permitted before '=>'")
	}
	eat(p) // consume =>

	prev_async := p.ctx.in_async
	p.ctx.in_async = true

	// Parse body. Capture block-vs-expression BEFORE consuming the body,
	// so the ESTree `expression` flag reflects the source shape.
	is_block_body := is_token(p, .LBrace)
	body: ArrowFunctionBody
	if is_block_body {
		// Block body - need to set in_function for return statement validation
		prev_in_function := p.ctx.in_function
		p.ctx.in_function = true
		// break/continue/labels don't cross arrow function boundaries.
		prev_in_loop_a2 := p.ctx.in_loop
		prev_in_switch_a2 := p.ctx.in_switch
		prev_label_floor_a2 := p.ctx.label_floor
		p.ctx.in_loop = false
		p.ctx.in_switch = false
		p.ctx.label_floor = len(p.label_stack)
		// §15.3.1: arrow block body is a function-scope.
		p.scope_fn_scope_next_block = true
		block_stmt := parse_block_statement(p)
		p.ctx.in_function = prev_in_function
		p.ctx.in_loop = prev_in_loop_a2
		p.ctx.in_switch = prev_in_switch_a2
		resize(&p.label_stack, p.ctx.label_floor)
		p.ctx.label_floor = prev_label_floor_a2
		// §15.3.1: arrow `{ FunctionBody }` is a function-scope, not a block-scope.
		if block_stmt != nil {
			// Same Bug-H class as the multi-param arrow arm above. Extract the
			// inner ^BlockStatement via type assertion, not a raw pointer cast.
			if bs, ok := block_stmt^.(^BlockStatement); ok {
				body = bs
			}
		}
	} else {
		// in_function fix - see parse_arrow_function for rationale.
		prev_in_function := p.ctx.in_function
		p.ctx.in_function = true
		body = parse_assignment_expression(p)
		p.ctx.in_function = prev_in_function
	}

	p.ctx.in_async = prev_async

	// Create single param
	params := make([dynamic]FunctionParameter, 0, 1, p.allocator)
	param_ident := new_node(p, Identifier)
	param_ident^ = param
	fn_param := FunctionParameter{
		loc     = param.loc,
		pattern = param_ident,
	}
	bump_append(&params, fn_param)

	arrow, arrow_e := new_expr(p, ArrowFunctionExpression)
	arrow.loc = start
	arrow.params = params
	arrow.body = body
	arrow.expression = !is_block_body
	arrow.async = true
	arrow.loc.end = prev_end_offset(p)

	parser_check_dup_params(p, params[:], start.start, p.ctx.strict_mode, true)

	// §15.9.1 - BoundNames(params) ∩ LexicallyDeclaredNames(body)
	// must be empty. `async bar => { let bar; }` is a SyntaxError.
	if is_block_body {
	}

	return arrow_e
}

parse_async_arrow_with_parens :: proc(p: ^Parser, async_tok: TokenSnap) -> ^Expression {
	async_tok := async_tok  // re-bind to a mutable local; Odin parameters aren't addressable
	start := loc_from_token(&async_tok)

	// Parse parenthesized parameter list
	if !expect_token(p, .LParen) {
		return nil
	}

	// §15.9.1 - CoverCallExpressionAndAsyncArrowHead Contains
	// AwaitExpression is a SyntaxError. Flag the params window so the
	// await-expression constructor reports on entry.
	prev_in_async_params := p.ctx.in_async_params
	p.ctx.in_async_params = true
	params := parse_function_params(p)
	report_parameter_modifiers_disallowed(p, params[:])
	p.ctx.in_async_params = prev_in_async_params

	if !expect_token(p, .RParen) {
		return nil
	}

	// §15.9.1 final clause: "All early error rules for
	// ArrowFormalParameters and their derived productions also apply to
	// CoverCallExpressionAndAsyncArrowHead when that production covers
	// an AsyncArrowHead" / yield-in-arrow-params: enforced by the
	// semantic checker (^YieldExpression / ^AwaitExpression cases under
	// ctx.in_params=true).

	// Optional TS return-type annotation: `async (): Promise<T> => body`,
	// or with a type predicate `async (x): x is T => body`.
	// In TS / TSX the `:` after the param list opens a TSTypeAnnotation
	// before the `=>`. parse_ts_return_type_annotation handles both plain
	// types and TypePredicate forms (`x is T`, `asserts x`, `asserts x is T`).
	// plus the async-arrow type-predicate
	// follow-up (#18).
	async_return_type: Maybe(^TSTypeAnnotation)
	if (p.lang == .TS || p.lang == .TSX) && is_token(p, .Colon) {
		async_return_type = parse_ts_return_type_annotation(p)
	}

	if !is_token(p, .Arrow) {
		expect_token(p, .Arrow)
		return nil
	}
	if cur_has_newline(p) {
		report_error_coded(p, .K3064_LineTerminatorRestricted, "Line terminator not permitted before '=>'")
	}
	eat(p)

	prev_async := p.ctx.in_async
	p.ctx.in_async = true

	// Parse body. Capture block-vs-expression before consuming.
	is_block_body := is_token(p, .LBrace)
	body: ArrowFunctionBody
	if is_block_body {
		// Block body - need to set in_function for return statement validation
		prev_in_function := p.ctx.in_function
		p.ctx.in_function = true
		// break/continue/labels don't cross arrow function boundaries.
		prev_in_loop_a3 := p.ctx.in_loop
		prev_in_switch_a3 := p.ctx.in_switch
		prev_label_floor_a3 := p.ctx.label_floor
		p.ctx.in_loop = false
		p.ctx.in_switch = false
		p.ctx.label_floor = len(p.label_stack)
		// §15.3.1: arrow block body is a function-scope.
		p.scope_fn_scope_next_block = true
		block_stmt := parse_block_statement(p)
		p.ctx.in_function = prev_in_function
		p.ctx.in_loop = prev_in_loop_a3
		p.ctx.in_switch = prev_in_switch_a3
		resize(&p.label_stack, p.ctx.label_floor)
		p.ctx.label_floor = prev_label_floor_a3
		// §15.3.1: arrow `{ FunctionBody }` is a function-scope, not a block-scope.
		if block_stmt != nil {
			// Same Bug-H class as the other two arrow-function arms above.
			// Extract the inner ^BlockStatement via type assertion, not a raw
			// pointer cast. prettier.js is the third-site canary.
			if bs, ok := block_stmt^.(^BlockStatement); ok {
				body = bs
			}
		}
	} else {
		#partial switch p.cur_type {
		case .Semi, .Comma, .RParen, .RBracket, .RBrace, .EOF:
			report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token")
		}
		// Same in_function fix as parse_arrow_function's expression arm:
		// without this, a nested `await` inside an async arrow's expression
		// body (e.g. `async () => (<x title={await f()}/>)`) falls into the
		// top-level-await detector in parse_unary_expr `.Await` and spuriously
		// promotes the whole file to `sourceType: "module"`.
		prev_in_function := p.ctx.in_function
		p.ctx.in_function = true
		body = parse_assignment_expression(p)
		p.ctx.in_function = prev_in_function
	}

	p.ctx.in_async = prev_async

	arrow, arrow_e := new_expr(p, ArrowFunctionExpression)
	arrow.loc = start
	arrow.params = params
	arrow.body = body
	arrow.expression = !is_block_body
	arrow.async = true
	if rt, ok := async_return_type.?; ok { arrow.return_type = rt }
	arrow.loc.end = prev_end_offset(p)

	parser_check_dup_params(p, params[:], start.start, p.ctx.strict_mode, true)

	// §15.9.1 - BoundNames(params) ∩ LexicallyDeclaredNames(body)
	// must be empty. `async(bar) => { let bar; }` is the canonical
	// case. Test262 language/expressions/async-arrow-function/
	// early-errors-arrow-formals-body-duplicate.js.
	if is_block_body {
		if bs, ok := body.(^BlockStatement); ok && bs != nil {
   if !p.ast_only {
			check_params_vs_body_lex(p, params[:], bs.body[:])
   }
		}
	}

	// §15.9.1 — ContainsUseStrict + !IsSimpleParameterList early error
	// for async arrows. Mirror the synchronous-arrow shape:
	// arrow_body_lifts_strict sniffs body[0] because parse_block_statement
	// doesn't promote prologue directives.
	if is_block_body {
		if arrow_body_lifts_strict(body) {
			if !params_are_simple(params[:]) {
				report_error_coded_span(p, .K3052_UseStrictWithComplexParams, u32(start.start), u32(start.start), "Illegal 'use strict' directive in function with non-simple parameter list")
			}
			if !p.ctx.strict_mode {
				report_strict_param_pattern_retro(p, params[:])
			}
		}
	}

	return arrow_e
}

// ============================================================================
// Dynamic Import Helper
// ============================================================================

parse_dynamic_import :: proc(p: ^Parser, phase: string) -> ^Expression {
	start := cur_loc(p)

	eat(p) // consume import

	return parse_dynamic_import_tail(p, start, phase)
}

// Shared tail of import(), import.defer(), import.source(). Assumes the
// `import` keyword (and optional `.defer` / `.source` property) has already
// been consumed; `start` points at the `import` keyword, cur is `(`.
parse_dynamic_import_tail :: proc(p: ^Parser, start: Loc, phase: string) -> ^Expression {
	// consume (
	if !is_token(p, .LParen) {
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected ( after import")
		return nil
	}
	eat(p)

	// §13.3.10 ImportCall: the specifier AssignmentExpression is
	// mandatory. `import()` and `import.defer()` are SyntaxErrors.
	if is_token(p, .RParen) {
		report_error_coded(p, .K2020_ExpectedExpression, "'import()' requires a specifier")
		eat(p)
		import_expr, import_expr_e := new_expr(p, ImportExpression)
		import_expr.loc = start
		import_expr.phase = phase
		import_expr.loc.end = prev_end_offset(p)
		return import_expr_e
	}

	// §13.3.10: spread (`...x`) is not allowed. ImportCall uses
	// AssignmentExpression directly, not Arguments, so the rest-element
	// production never reaches it.
	if is_token(p, .Dot3) {
		report_error_coded(p, .K3023_ImportMetaOrDynamicImportInvalid, "'...' is not allowed in 'import()' call")
		eat(p) // consume ... and keep parsing so recovery stays reasonable
	}

	// §13.3.10: ImportCall arguments are AssignmentExpression[+In].
	prev_no_in := p.ctx.no_in
	p.ctx.no_in = false
	specifier := parse_assignment_expression(p)
	if specifier == nil {
		p.ctx.no_in = prev_no_in
		return nil
	}

	// ImportCall (§13.3.10):
	//   import( AssignmentExpression ,opt )
	//   import( AssignmentExpression , AssignmentExpression ,opt )
	// Accept trailing comma after the specifier, plus the optional
	// second argument (import attributes object) with its own optional
	// trailing comma. Phase-import proposal does not currently allow a
	// second argument, but accepting it here degrades gracefully - the
	// spec will either adopt the same shape or reject at a later stage.
	options: ^Expression = nil
	if match_token(p, .Comma) {
		if !is_token(p, .RParen) {
			if is_token(p, .Dot3) {
				report_error_coded(p, .K3023_ImportMetaOrDynamicImportInvalid, "'...' is not allowed in 'import()' call")
				eat(p)
			}
			options = parse_assignment_expression(p)
			if match_token(p, .Comma) {
				// Trailing comma after second argument — TS-only rejection.
				if is_token(p, .RParen) && allow_ts_mode(p) {
					report_error_coded(p, .K3065_TrailingCommaInvalid, "Trailing comma not allowed")
				}
			}
		} else if allow_ts_mode(p) {
			// TS1009 — trailing comma in import() is rejected in TS.
			// The ES spec (§13.3.10) allows it but TSC/OXC don't.
			report_error_coded(p, .K3065_TrailingCommaInvalid, "Trailing comma not allowed")
		}
	}

	p.ctx.no_in = prev_no_in

	// consume )
	if !is_token(p, .RParen) {
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected ) after import specifier")
		return nil
	}
	eat(p)

	import_expr, import_expr_e := new_expr(p, ImportExpression)
	import_expr.loc = start
	import_expr.source = specifier
	import_expr.options = options
	import_expr.phase = phase
	import_expr.loc.end = prev_end_offset(p)

	// Collect ESM dynamic import record.
	// NOTE: dynamic `import()` expressions are valid in both Scripts and
	// Modules per ECMA-262, so they do NOT imply module syntax. Only static
	// `import`/`export` declarations (and top-level `await`/`import.meta`)
	// flip has_module_syntax - matches OXC/Acorn/Babel behaviour.
	esm_dynamic := ESMDynamicImport{
		start = import_expr.loc.start,
		end = import_expr.loc.end,
		moduleRequest = {
			start = 0,
			end = 0,
		},
	}
	// Try to extract module request span from the specifier if it's a string literal
	if spec_expr, ok := specifier^.(^StringLiteral); ok {
		esm_dynamic.moduleRequest.start = spec_expr.loc.start
		esm_dynamic.moduleRequest.end = spec_expr.loc.end
	}
	bump_append(&p.dynamicImports, esm_dynamic)

	return import_expr_e
}

// ============================================================================
// Import Attributes (Phase 1)
// ============================================================================

parse_import_attributes :: proc(p: ^Parser) -> [dynamic]ImportAttribute {
	attributes := make([dynamic]ImportAttribute, 0, 4, p.allocator)
	if !is_token(p, .With) && !is_token(p, .Assert) { return attributes }
	// §16.2.2 - `assert` has a [no LineTerminator here] restriction.
	// A newline before `assert` triggers ASI and the token belongs to the
	// next statement. `with` does NOT have this restriction.
	if is_token(p, .Assert) && cur_has_newline(p) { return attributes }
	eat(p)
	if !expect_token(p, .LBrace) { return attributes }
	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		attr_start := cur_loc(p)
		key: IdentifierName
		if is_token(p, .String) {
			current := snap_current(p)
			key = IdentifierName{loc = loc_from_token(&current), name = current.literal.(string) or_else current.value}
			eat(p)
		} else {
			id := parse_identifier_name(p)
			key = IdentifierName{loc = id.loc, name = id.name}
		}
		if !expect_token(p, .Colon) { break }
		// §16.2.2 - attribute values must be string literals.
		if !is_token(p, .String) {
			report_error_coded(p, .K2070_RequiredFormOrBinding, "Only string literals are allowed as import attribute values")
		}
		value := parse_string_literal(p)
		// End must cover the value literal - `attr_start` captured only
		// the key's token span at entry (cur_loc), and was never extended
		// past the value. The previous shape `{ loc = attr_start, ... }` left
		// `loc.end` equal to the key's end, so `type: "json"` reported
		// end=39 (key) instead of end=47 (value).
		attr_loc := attr_start
		attr_loc.end = value.loc.end
		// £16.2.2 ImportDeclaration with Attributes: duplicate attribute keys
		// are a SyntaxError. Check before appending.
		for prev in attributes {
			if prev.key.name == key.name {
				msg := fmt.tprintf("Duplicate import attribute key '%s'", key.name)
				bump_append(&p.errors, ParseError{start = attr_loc.start, end = attr_loc.end, message = msg})
				break
			}
		}
		bump_append(&attributes, ImportAttribute{loc = attr_loc, key = key, value = value})
		if !match_token(p, .Comma) { break }
	}
	expect_token(p, .RBrace)
	return attributes
}

// Decorator : @ DecoratorMemberExpression | @ DecoratorCallExpression
//            | @ DecoratorParenthesizedExpression
// DecoratorMemberExpression : IdentifierReference
//                            | DecoratorMemberExpression . IdentifierName
//                            | DecoratorMemberExpression . PrivateIdentifier
// DecoratorCallExpression : DecoratorMemberExpression Arguments
// DecoratorParenthesizedExpression : ( Expression )
// The grammar deliberately excludes computed `[...]` member access. Pre
// happily ate `@dec["method"]()` as one decorator and starved the
// following class element. parse_decorator_expression below honours the
// restricted grammar so `@dec ["method"]() {}` parses as decorator +
// computed-key method.
parse_decorator_expression :: proc(p: ^Parser) -> ^Expression {
	start := cur_loc(p)
	expr: ^Expression
	if is_token(p, .LParen) {
		eat(p)
		expr = parse_expression(p)
		expect_token(p, .RParen)
	} else if allow_ts_mode(p) && is_token(p, .New) {
		// TS experimental decorators allow `@new x class C {}`. Parse
		// the full NewExpression so OXC-parity fixtures pass. TS1497
		// ("Expression must be enclosed in parentheses") is semantic.
		expr = parse_new_expr(p)
	} else if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
		expr = expression_from(p, new_identifier_from_cur(p))
		eat(p)
		// Dotted chain - allows identifiers, keywords-as-property, AND
		// private identifiers (`@C.#dec`, `@C.#self.#dec`). Reject
		// computed access by stopping at non-`.`.
		for is_token(p, .Dot) {
			eat(p)
			if is_token(p, .PrivateIdentifier) {
				// Private field access: `@obj.#priv`
				prop_id := new_identifier_from_cur(p)
				eat(p)
				mem := new_node(p, MemberExpression)
				mem.loc = start
				mem.object = expr
				mem.property = expression_from(p, prop_id)
				mem.computed = false
				mem.optional = false
				mem.loc.end = prev_end_offset(p)
				expr = expression_from(p, mem)
			} else if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
				prop_id := new_identifier_from_cur(p)
				eat(p)
				mem := new_node(p, MemberExpression)
				mem.loc = start
				mem.object = expr
				mem.property = expression_from(p, prop_id)
				mem.computed = false
				mem.optional = false
				mem.loc.end = prev_end_offset(p)
				expr = expression_from(p, mem)
			} else {
				report_error_coded(p, .K2090_MalformedDecorator, "Expected identifier after '.' in decorator")
				break
			}
		}
	} else {
		// Don't emit a new error - downstream emits "Decorators can
		// only be applied to class expressions" / "Expected class after
		// decorator" which already covers the malformed-decorator case
		// and is the message the negative-fixtures gate locks in.
		return nil
	}
	// TS type arguments are handled inside the loop below, together with
	// calls and member accesses, so the decorator expression supports
	// `@a.b<T>(x).c` etc.
	type_arguments: Maybe(^TSTypeParameterInstantiation)

	// Post-member suffix loop: calls, member accesses, and TS type args.
	// The TC39 stage 3 grammar limits decorators to
	//   @member.chain | @member.chain(args) | @(expr)
	// but TypeScript (and OXC/Babel) use LeftHandSideExpression which
	// allows `@foo().bar`, `@foo().bar()`, `@a.b<T>(x).c`, etc.
	// We match OXC's permissive parse to avoid rejecting real-world TS.
	for {
		if is_token(p, .LParen) {
			args := parse_arguments(p)
			call := new_node(p, CallExpression)
			call.loc = start
			call.callee = expr
			call.arguments = args
			call.optional = false
			call.type_parameters = type_arguments
			call.loc.end = prev_end_offset(p)
			expr = expression_from(p, call)
			type_arguments = nil // consumed
		} else if is_token(p, .Dot) {
			eat(p)
			if is_token(p, .PrivateIdentifier) || is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
				prop_id := new_identifier_from_cur(p)
				eat(p)
				mem := new_node(p, MemberExpression)
				mem.loc = start
				mem.object = expr
				mem.property = expression_from(p, prop_id)
				mem.computed = false
				mem.optional = false
				mem.loc.end = prev_end_offset(p)
				expr = expression_from(p, mem)
			} else {
				report_error_coded(p, .K2090_MalformedDecorator, "Expected identifier after '.' in decorator")
				break
			}
		} else if allow_ts_mode(p) && is_open_angle_or_lshift(p) {
			type_arguments = parse_ts_type_arguments(p)
			// Type arguments not followed by `(` are dangling — e.g.
			// `@g<number> class C {}`. OXC's parser accepts this without
			// error; tsc reports TS1146 (semantic). Don't error — just
			// break out of the suffix loop and let the type_arguments
			// dangle (they'll be ignored in the AST).
			if !is_token(p, .LParen) && !is_token(p, .Dot) && !cur_has_newline(p) {
				break
			}
		} else if allow_ts_mode(p) && is_token(p, .OptionalChain) {
			// Optional chaining in TS decorator: `@x?.y`, `@x?.y()`,
			// `@x?.["y"]`, `@x?.()`. OXC's parser accepts these;
			// tsc reports TS1497 (semantic).
			eat(p) // consume ?.
			if is_token(p, .LParen) {
				// Optional call: `@x?.()`
				args := parse_arguments(p)
				call := new_node(p, CallExpression)
				call.loc = start
				call.callee = expr
				call.arguments = args
				call.optional = true
				call.loc.end = prev_end_offset(p)
				expr = expression_from(p, call)
			} else if is_token(p, .LBracket) {
				// Optional computed: `@x?.["y"]`
				eat(p) // consume [
				prop := parse_expression(p)
				expect_token(p, .RBracket)
				mem := new_node(p, MemberExpression)
				mem.loc = start
				mem.object = expr
				mem.property = prop
				mem.computed = true
				mem.optional = true
				mem.loc.end = prev_end_offset(p)
				expr = expression_from(p, mem)
			} else if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
				// Optional member: `@x?.y`
				prop_id := new_identifier_from_cur(p)
				eat(p)
				mem := new_node(p, MemberExpression)
				mem.loc = start
				mem.object = expr
				mem.property = expression_from(p, prop_id)
				mem.computed = false
				mem.optional = true
				mem.loc.end = prev_end_offset(p)
				expr = expression_from(p, mem)
			} else {
				break
			}
		} else if allow_ts_mode(p) && (is_token(p, .Template) || is_token(p, .TemplateHead)) {
			// Tagged template in TS decorator: `@x\`\``, `@x.y\`\`()`.
			// OXC's parser accepts these; tsc reports TS1497 (semantic).
			tagged, tagged_e := new_expr(p, TaggedTemplateExpression)
			tagged.loc = loc_from_expr(expr)
			tagged.tag = expr
			tagged.quasi = parse_template_literal(p, true)
			tagged.loc.end = prev_end_offset(p)
			expr = tagged_e
		} else if allow_ts_mode(p) && is_token(p, .Not) && !cur_has_newline(p) {
			// TS non-null assertion postfix: `@x!`, `@x.y!`.
			eat(p)
			nna, nna_e := new_expr(p, TSNonNullExpression)
			nna.loc = start
			nna.expression = expr
			nna.loc.end = prev_end_offset(p)
			expr = nna_e
		} else {
			break
		}
	}
	return expr
}

parse_decorators :: proc(p: ^Parser) -> [dynamic]Decorator {
	// Lazy alloc - the parser calls parse_decorators on entry to every
	// class declaration, class element, and function declaration. The
	// overwhelming majority of real-world JS contains no decorators at
	// all, so the unconditional 32-byte make() per call burned through
	// the bump pool with nothing to show for it. Defer to the first `@`.
	decorators: [dynamic]Decorator
	if !is_token(p, .At) {
		return decorators
	}
	decorators = make([dynamic]Decorator, 0, 4, p.allocator)
	for is_token(p, .At) {
		start := cur_loc(p)
		eat(p)
		expr := parse_decorator_expression(p)
		d := Decorator{loc = start, expression = expr}
		d.loc.end = prev_end_offset(p)
		bump_append(&decorators, d)
	}
	return decorators
}

parse_decorated_class :: proc(p: ^Parser) -> ^Statement {
	decorators := parse_decorators(p)
	if is_token(p, .Export) {
		// Peek ahead: if there are decorators AFTER `export` or
		// `export default` too, it's a SyntaxError - decorators may
		// appear either before `export` or after, not both.
		// Check by peeking for `@` after `export [default]`.
  ensure_nxt(p)
		nxt := p.lexer.nxt
		has_post_export_dec := nxt.kind == .At
		if !has_post_export_dec && nxt.kind == .Default {
			// Need to look 2 tokens ahead: `export default @`.
			snap := lexer_snapshot(p)
			eat(p) // export
			eat(p) // default
			has_post_export_dec = is_token(p, .At)
			lexer_restore(p, snap)
		}
		if has_post_export_dec {
			report_error_coded(p, .K4064_DecoratorInvalid, "Decorators may not appear after 'export' or 'export default' if they also appear before 'export'")
		}
		stmt := parse_export_declaration(p)
		if stmt != nil {
			decorators_attached := false
			#partial switch s in stmt^ {
			case ^ExportNamedDeclaration:
				if decl, ok := s.declaration.(^Declaration); ok && decl != nil {
					if cd, ok2 := decl^.(^ClassDeclaration); ok2 {
						cd.expr.decorators = decorators
						decorators_attached = true
					}
				}
			case ^ExportDefaultDeclaration:
				if decl, ok := s.declaration.(^Declaration); ok && decl != nil {
					if cd, ok2 := decl^.(^ClassDeclaration); ok2 {
						cd.expr.decorators = decorators
						decorators_attached = true
					}
				}
			}
			if !decorators_attached && len(decorators) > 0 {
				report_error_coded(p, .K4064_DecoratorInvalid, "Decorators are not valid here")
			}
		}
		return stmt
	}
	// `abstract class` after decorator - consume `abstract` and set the
	// flag, mirroring the statement-level `.Abstract` → `.Class` path.
	is_abstract_class := false
	if is_token(p, .Abstract) {
		if is_next_token(p, .Class) && !peek_token(p).had_line_terminator {
			is_abstract_class = true
			eat(p) // consume `abstract`
		}
	}
	if !is_token(p, .Class) {
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected class after decorator")
		return nil
	}
	prev_abs := p.ctx.class_is_abstract
	if is_abstract_class { p.ctx.class_is_abstract = true }
	stmt := parse_class_declaration(p)
	p.ctx.class_is_abstract = prev_abs  // prevent leak to next class
	if stmt != nil {
		#partial switch s in stmt^ {
		case ^ClassDeclaration:
			s.expr.decorators = decorators
			if is_abstract_class { s.expr.abstract = true }
			if len(decorators) > 0 { s.expr.loc.start = decorators[0].loc.start }
		}
	}
	return stmt
}

// ============================================================================
// Utility Functions
// ============================================================================

// Fast accessors - read directly from FastToken, no Token struct copy
cur_offset :: #force_inline proc(p: ^Parser) -> u32 {
	return p.lexer.cur.start
}

// is_paren_wrapped_at reports whether the source byte immediately before
// `span_start` (skipping insignificant whitespace) is an opening paren `(`.
// With --preserve-parens off, a parenthesised operand's AST span starts at the
// inner expression rather than the `(`, so a backward source scan is the only
// way to recover the paren context. Returns false when there is no lexer or
// `span_start` is at (or before) the start of source.
is_paren_wrapped_at :: proc(p: ^Parser, span_start: int) -> bool {
	if p.lexer == nil { return false }
	if span_start <= 0 { return false }
	i := span_start - 1
	for i >= 0 {
		ch := p.lexer.source_bytes[i]
		if ch == '(' { return true }
		if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { i -= 1; continue }
		break
	}
	return false
}

// prev_end_offset returns the end offset of the LAST consumed token. Use this
// for `loc.end` to match ESTree/OXC/Acorn/Babel span semantics, which
// END a node at the last character of its last token - excluding any trailing
// whitespace, newlines, or comments that precede the NEXT token.
// Example: for `export * from "./a";\nconst x = 1;`, the ExportAllDeclaration
// must span [0, 20) - through the `;`, not including the `\n`. `cur_offset`
// after parsing the export would be 21 (start of `const`); `prev_end_offset`
// correctly returns 20.
prev_end_offset :: #force_inline proc(p: ^Parser) -> u32 {
	return p.prev_token_end
}

cur_value :: #force_inline proc(p: ^Parser) -> string {
	ft := p.lexer.cur
	if (ft.kind == .Identifier || ft.kind == .PrivateIdentifier) && (ft.flags & FLAG_HAS_ESCAPE) != 0 {
		if p.lexer.lit_offset[p.lexer.lit_write_idx ~ 1] == ft.start && p.lexer.lit_type[p.lexer.lit_write_idx ~ 1] == .Identifier {
			if s, ok := p.lexer.lit_value[p.lexer.lit_write_idx ~ 1].(string); ok { return s }
		}
	}
	if ft.start < ft.end { return p.lexer.source[ft.start:ft.end] }
	return ""
}

cur_loc :: #force_inline proc(p: ^Parser) -> Loc {
	ft := p.lexer.cur
	return Loc{start = ft.start, end = ft.end}
}

cur_raw_end :: #force_inline proc(p: ^Parser) -> u32 {
	return p.lexer.cur.end
}

cur_has_newline :: #force_inline proc(p: ^Parser) -> bool {
	return (p.lexer.cur.flags & FLAG_NEW_LINE) != 0
}

cur_has_escape :: #force_inline proc(p: ^Parser) -> bool {
	return (p.lexer.cur.flags & FLAG_HAS_ESCAPE) != 0
}

cur_literal :: #force_inline proc(p: ^Parser) -> LiteralValue {
	ft := p.lexer.cur
	if p.lexer.lit_offset[p.lexer.lit_write_idx ~ 1] == ft.start && p.lexer.lit_type[p.lexer.lit_write_idx ~ 1] != .None {
		return p.lexer.lit_value[p.lexer.lit_write_idx ~ 1]
	}
	if ft.kind == .String && ft.end - ft.start >= 2 {
		return LiteralValue(p.lexer.source[ft.start+1:ft.end-1])
	}
	return nil
}

// TokenSnap — lightweight snapshot of the current token for callers that
// need to capture token state before eat(). 48 bytes vs Token's 72 bytes,
// and reads directly from the lexer (FastToken + literal store) rather
// than an inflated Token copy.
TokenSnap :: struct {
	value:      string,       // 16B — raw source or cooked name
	start:      u32,          // 4B  — byte offset of token start
	end:        u32,          // 4B  — byte offset past last char (raw_end)
	type:       TokenType,    // 1B
	has_escape: bool,         // 1B — FLAG_HAS_ESCAPE from FastToken
	literal:    LiteralValue, // 24B — parsed literal (nil for non-literals)
}

snap_current :: #force_inline proc(p: ^Parser) -> TokenSnap {
	return TokenSnap{
		value      = cur_value(p),
		start      = cur_offset(p),
		end        = cur_raw_end(p),
		type       = p.cur_type,
		has_escape = cur_has_escape(p),
		literal    = cur_literal(p),
	}
}

loc_from_snap :: #force_inline proc(s: ^TokenSnap) -> Loc {
	return Loc{start = s.start, end = s.end}
}

loc_from_token :: proc{loc_from_token_impl, loc_from_snap}

loc_from_token_impl :: #force_inline proc(t: ^Token) -> Loc {
	// Prefer t.raw_end: it's the true source-byte end from the FastToken,
	// which is correct even when .value has been replaced by the cooked
	// identifier name (escaped identifiers: source `C\u00e9` occupies 7 bytes
	// but cooked .value is 3 bytes UTF-8 - computing end from `offset +
	// len(value)` underestimated by 4, breaking span comparisons against OXC
	// for every \uXXXX identifier).
	// Fall back to the old `offset + len(value)` for Tokens that predate
	// raw_end population (raw_end stays 0 until set by advance_token /
	// prime_token_cache / peek_token). This keeps the compile-time zero-init
	// safe for synthetic Tokens constructed outside the lexer pipeline.
	// `t.loc.line` / `t.loc.column` are NEVER written by the lexer or
	// parser - they're computed lazily by `report_error` from `offset` via
	// `offset_to_line_col`. Reading them here returned permanent 0, then
	// we'd write 0 into `Loc.{line,column}` - four wasted memory ops per
	// `loc_from_token` call (called on every AST node from a current-token
	// span). Leave the Loc's line / column zero-initialised.
	end := u32(int(t.loc) + len(t.value))
	if t.raw_end != 0 && t.raw_end > u32(t.loc) {
		end = t.raw_end
	}
	return Loc{start = u32(t.loc), end = end}
}

// Extract loc from any Expression variant. All variants have `loc` as first field.
loc_from_expr :: #force_inline proc(e: ^Expression) -> Loc {
	if e == nil { return {} }
	#partial switch v in e {
	case ^Identifier:             return v.loc
	case ^NumericLiteral:          return v.loc
	case ^StringLiteral:           return v.loc
	case ^BooleanLiteral:          return v.loc
	case ^NullLiteral:             return v.loc
	case ^ThisExpression:           return v.loc
	case ^Super:                    return v.loc
	case ^ArrayExpression:          return v.loc
	case ^ObjectExpression:         return v.loc
	case ^FunctionExpression:       return v.loc
	case ^ArrowFunctionExpression:  return v.loc
	case ^MemberExpression:         return v.loc
	case ^CallExpression:           return v.loc
	case ^ChainExpression:          return v.loc
	case ^NewExpression:            return v.loc
	case ^ConditionalExpression:    return v.loc
	case ^UnaryExpression:          return v.loc
	case ^BinaryExpression:         return v.loc
	case ^LogicalExpression:        return v.loc
	case ^AssignmentExpression:     return v.loc
	case ^UpdateExpression:         return v.loc
	case ^SpreadElement:            return v.loc
	case ^YieldExpression:          return v.loc
	case ^AwaitExpression:          return v.loc
	case ^ImportExpression:         return v.loc
	case ^MetaProperty:             return v.loc
	case ^BigIntLiteral:            return v.loc
	case ^RegExpLiteral:            return v.loc
	case ^TemplateLiteral:          return v.loc
	case ^TaggedTemplateExpression: return v.loc
	case ^SequenceExpression:       return v.loc
	case ^ClassExpression:          return v.loc
	case ^PrivateIdentifier:        return v.loc
	case ^ParenthesizedExpression:  return v.loc
	}
	return {}
}

// Set the start offset of an expression's span. Matches loc_from_expr variants.

token_to_unary_op :: proc(t: TokenType) -> UnaryOperator {
	#partial switch t {
	case .Plus:      return .Plus
	case .Minus:     return .Minus
	case .BitNot:    return .BitwiseNot
	case .Not: return .LogicalNot
	case .Typeof:    return .Typeof
	case .Void:      return .Void
	case .Delete:    return .Delete
	}
	return .Minus // Default
}

token_to_binary_op :: proc(t: TokenType) -> BinaryOperator {
	#partial switch t {
	case .Plus:         return .Add
	case .Minus:        return .Sub
	case .Mul:          return .Mul
	case .Div:          return .Div
	case .Mod:          return .Mod
	case .Pow:          return .Pow
	case .BitOr:        return .BitOr
	case .BitXor:       return .BitXor
	case .BitAnd:       return .BitAnd
	case .LShift:       return .ShiftLeft
	case .RShift:       return .ShiftRight
	case .URShift:      return .ShiftRightUnsigned
	case .Eq:           return .Eq
	case .NotEq:        return .NotEq
	case .EqStrict:     return .StrictEq
	case .NotEqStrict:  return .StrictNotEq
	case .LAngle:       return .Lt
	case .RAngle:       return .Gt
	case .LEq:          return .LtEq
	case .GEq:          return .GtEq
	case .In:           return .In
	case .Instanceof:  return .Instanceof
	}
	return .Add // Default
}

token_to_assignment_op :: proc(t: TokenType) -> AssignmentOperator {
	#partial switch t {
	case .Assign:           return .Assign
	case .AssignAdd:        return .AddAssign
	case .AssignSub:        return .SubAssign
	case .AssignMul:        return .MulAssign
	case .AssignDiv:        return .DivAssign
	case .AssignMod:        return .ModAssign
	case .AssignPow:        return .PowAssign
	case .AssignLShift:     return .ShiftLeftAssign
	case .AssignRShift:     return .ShiftRightAssign
	case .AssignURShift:    return .ShiftRightUAssign
	case .AssignBitAnd:     return .BitAndAssign
	case .AssignBitOr:      return .BitOrAssign
	case .AssignBitXor:     return .BitXorAssign
	case .AssignLogicalAnd: return .AssignLogicalAnd
	case .AssignLogicalOr:  return .AssignLogicalOr
	case .AssignNullish:    return .AssignNullish
	}
	return .Assign // Default
}

token_to_logical_op :: proc(t: TokenType) -> LogicalOperator {
	#partial switch t {
	case .LogicalOr:  return .Or
	case .LogicalAnd: return .And
	case .Nullish:    return .NullishCoalescing
	}
	return .Or // Default
}
