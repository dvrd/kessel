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
// Module Import/Export
// ============================================================================

// List variant of collect_pattern_bound_names. Used by the catch-clause
// duplicate-check which needs to see the same name twice (the map variant
// silently dedups).
collect_pattern_bound_names_list :: proc(pat: Pattern, out: ^[dynamic]string) {
	if pat == nil { return }
	switch v in pat {
	case ^Identifier:
		if v != nil { append(out, v.name) }
	case ^ObjectPattern:
		if v == nil { return }
		for prop in v.properties {
			collect_pattern_bound_names_list(prop.value, out)
		}
	case ^ArrayPattern:
		if v == nil { return }
		for elem in v.elements {
			if inner, ok := elem.(Pattern); ok {
				collect_pattern_bound_names_list(inner, out)
			}
		}
	case ^AssignmentPattern:
		if v == nil { return }
		collect_pattern_bound_names_list(v.left, out)
	case ^RestElement:
		if v == nil { return }
		collect_pattern_bound_names_list(v.argument, out)
	case ^MemberExpression:
		return
	}
}

// Collect BoundNames from a binding pattern. Handles the full pattern
// grammar (Identifier / ObjectPattern / ArrayPattern / AssignmentPattern /
// RestElement / MemberExpression destructuring target). Used by the
// post-parse export-local check to build the module-level binding set.
collect_pattern_bound_names :: proc(pat: Pattern, names: ^map[string]bool) {
	if pat == nil { return }
	switch v in pat {
	case ^Identifier:
		if v != nil { names[v.name] = true }
	case ^ObjectPattern:
		if v == nil { return }
		for prop in v.properties {
			collect_pattern_bound_names(prop.value, names)
		}
	case ^ArrayPattern:
		if v == nil { return }
		for elem in v.elements {
			if inner, ok := elem.(Pattern); ok {
				collect_pattern_bound_names(inner, names)
			}
		}
	case ^AssignmentPattern:
		if v == nil { return }
		collect_pattern_bound_names(v.left, names)
	case ^RestElement:
		if v == nil { return }
		collect_pattern_bound_names(v.argument, names)
	case ^MemberExpression:
		// MemberExpression as a destructure target introduces no new binding;
		// it writes to an existing property (`({x: obj.k} = ...)`).
		return
	}
}

// Collect names visible at the module top level for the purposes of
// ECMA-262 §16.2.2 "It is a Syntax Error if any element of the
// ExportedBindings of ModuleItemList does not also occur in either the
// VarDeclaredNames of ModuleItemList or the LexicallyDeclaredNames of
// ModuleItemList." We walk top-level statements only - nested var
// declarations inside a function body don't hoist out of the function.
collect_module_top_level_names :: proc(body: []^Statement, names: ^map[string]bool) {
	for stmt in body {
		if stmt == nil { continue }
		#partial switch v in stmt^ {
		case ^VariableDeclaration:
			if v == nil { continue }
			for decl in v.declarations {
				collect_pattern_bound_names(decl.id, names)
			}
		case ^FunctionDeclaration:
			if v == nil { continue }
			if id, ok := v.id.(BindingIdentifier); ok { names[id.name] = true }
		case ^ClassDeclaration:
			if v == nil { continue }
			if id, ok := v.id.(BindingIdentifier); ok { names[id.name] = true }
		case ^ImportDeclaration:
			if v == nil { continue }
			for spec in v.specifiers {
				if spec == nil { continue }
				switch ss in spec^ {
				case ImportSpecifier:
					names[ss.local.name] = true
				case ImportDefaultSpecifier:
					names[ss.local.name] = true
				case ImportNamespaceSpecifier:
					names[ss.local.name] = true
				}
			}
		case ^ExportNamedDeclaration:
			if v == nil { continue }
			// `export var x;`, `export function f()`, `export class C` - the
			// inner declaration still introduces module-level bindings.
			if d, have := v.declaration.(^Declaration); have && d != nil {
				switch inner in d^ {
				case ^VariableDeclaration:
					if inner == nil { break }
					for decl in inner.declarations {
						collect_pattern_bound_names(decl.id, names)
					}
				case ^FunctionDeclaration:
					if inner == nil { break }
					if id, ok := inner.id.(BindingIdentifier); ok { names[id.name] = true }
				case ^ClassDeclaration:
					if inner == nil { break }
					if id, ok := inner.id.(BindingIdentifier); ok { names[id.name] = true }
				case ^TSInterfaceDeclaration, ^TSTypeAliasDeclaration,
				     ^TSEnumDeclaration, ^TSModuleDeclaration,
				     ^TSImportEqualsDeclaration,
				     ^ImportDeclaration, ^ExportNamedDeclaration,
				     ^ExportDefaultDeclaration, ^ExportAllDeclaration:
					// Not bindable as ExportedBindings-targets for our purposes.
				}
			}
		case ^TSInterfaceDeclaration:
			if v != nil { names[v.id.name] = true }
		case ^TSTypeAliasDeclaration:
			if v != nil { names[v.id.name] = true }
		case ^TSEnumDeclaration:
			if v != nil { names[v.id.name] = true }
		case ^TSModuleDeclaration:
			if v != nil && v.id != nil {
				if ident, is_id := v.id.(^Identifier); is_id && ident != nil {
					names[ident.name] = true
				}
			}
		}
	}
}

// ECMA-262 §16.2.2 ExportDeclaration Early Errors:
//   • It is a Syntax Error if any element of the ExportedBindings of
//     ModuleItemList does not also occur in either the VarDeclaredNames or
//     LexicallyDeclaredNames of ModuleItemList.
//   • It is a Syntax Error if ReferencedBindings of NamedExports contains
//     any StringLiterals (i.e. `export { "foo" }` with no `from` clause).
// Called once from parse_program after the full body is known.
// §16.2.3 - IsStringWellFormedUnicode: a ModuleExportName string must
// not contain unpaired surrogates (U+D800..U+DFFF not in a valid pair).
// The decoded value is stored as UTF-8; surrogates are encoded as 3-byte
// sequences ed_a0_80..ed_bf_bf.
string_has_unpaired_surrogate :: proc(s: string) -> bool {
	i := 0
	for i < len(s) {
		b := s[i]
		if b < 0x80 {
			i += 1
		} else if b < 0xC0 {
			i += 1 // stray continuation byte
		} else if b < 0xE0 {
			i += 2
		} else if b < 0xF0 {
			// 3-byte sequence: check for surrogate range.
			if i + 2 < len(s) {
				cp := (u32(b & 0x0F) << 12) | (u32(s[i+1] & 0x3F) << 6) | u32(s[i+2] & 0x3F)
				if cp >= 0xD800 && cp <= 0xDFFF {
					return true
				}
			}
			i += 3
		} else {
			i += 4
		}
	}
	return false
}

verify_export_locals :: proc(p: ^Parser, program: ^Program) {
	// Only applies in Module context. Script mode is already forbidden
	// from containing `export` via the module-syntax-in-script check.
	if program.type != .Module { return }

	// §16.2.1 - ExportedNames of ModuleItemList must not contain duplicates.
	// Walk all export declarations and collect exported names, reporting
	// duplicates.
	exported := scope_map_make(16)
	for stmt in program.body {
		if stmt == nil { continue }
		#partial switch v in stmt^ {
		case ^ExportNamedDeclaration:
			if v == nil { continue }
			// `export <Decl>` (no specifiers, no `from`) - ExportedNames
			// of the declaration are derived from its BoundNames. We need
			// this branch separately so `export var a, a;` and
			// `export var [a, a] = [];` and `export function a() {}` /
			// `export class a {}` get caught alongside specifier-form
			// duplicates. Test262 staging/sm/module/duplicate-exported-
			// names-in-single-export-var-declaration.js.
			if decl_ptr, has_decl := v.declaration.?; has_decl && decl_ptr != nil {
				decl_names := make([dynamic]string, 0, 8, context.temp_allocator)
				decl_offs  := make([dynamic]u32, 0, 8, context.temp_allocator)
				#partial switch d in decl_ptr^ {
				case ^VariableDeclaration:
					if d != nil {
						for decl in d.declarations {
							prev_len := len(decl_names)
							collect_pattern_bound_names_list(decl.id, &decl_names)
							// Pad offsets so the list aligns with names.
							for _ in prev_len ..< len(decl_names) {
								bump_append(&decl_offs, decl.loc.start)
							}
						}
					}
				case ^FunctionDeclaration:
					if d != nil {
						// TS overload signature (no body): same name across
						// multiple declarations is the canonical TS overload
						// pattern. Only the implementation (the one with a
						// body) contributes a real binding for ExportedNames.
						if d.no_body && allow_ts_mode(p) {
						} else if id, ok := d.id.(BindingIdentifier); ok {
							bump_append(&decl_names, id.name)
							bump_append(&decl_offs, id.loc.start)
						}
					}
				case ^ClassDeclaration:
					if d != nil {
						if id, ok := d.id.(BindingIdentifier); ok {
							bump_append(&decl_names, id.name)
							bump_append(&decl_offs, id.loc.start)
						}
					}
				}
				for i in 0 ..< len(decl_names) {
					name := decl_names[i]
					if name == "" { continue }
					off := decl_offs[i]
					if _, exists := scope_map_get(&exported, name); exists {
						// JS mode — parser-side structural error.
						// TS mode — semantic-checker-only
						// (ck_check_export_dups). OXC's parser drops this
						// in TS too because of overload / type-vs-value merge
						// edge cases that oxc_semantic resolves later.
						if !allow_ts_mode(p) {
							msg := fmt.tprintf("Duplicate exported name '%s'", name)
							report_error_coded_span(p, .K3020_ImportExportNameOrBinding, u32(off), u32(off), msg)
						}
					} else {
						scope_map_set(&exported, name, off)
					}
				}
			}
			for spec in v.specifiers {
				var_name := ""
				var_off : u32 = 0
				switch exported_name in spec.exported {
				case IdentifierName:
					var_name = exported_name.name
					var_off = exported_name.loc.start
				case ^StringLiteral:
					if exported_name != nil {
						var_name = exported_name.value
						var_off = exported_name.loc.start
					}
				}
				if var_name != "" {
					if _, exists := scope_map_get(&exported, var_name); exists {
						if !allow_ts_mode(p) {
							msg := fmt.tprintf("Duplicate exported name '%s'", var_name)
							report_error_coded_span(p, .K3020_ImportExportNameOrBinding, u32(var_off), u32(var_off), msg)
						}
					} else {
						scope_map_set(&exported, var_name, var_off)
					}
				}
			}
		// ExportNamedDeclaration has no "default" name (that's ExportDefaultDeclaration)
		case ^ExportDefaultDeclaration:
			if v == nil { continue }
			// In TS mode, `export default` is allowed multiple times because
			// (1) `export default interface I {}` is type-space and doesn't
			// shadow a value default, and (2) TS surfaces this as a semantic
			// rather than a syntax error — OXC and Babel both accept the
			// duplicate. Skip the syntactic flag in TS / TSX modes.
			if allow_ts_mode(p) { continue }
			if _, exists := scope_map_get(&exported, "default"); exists {
				report_error_coded(p, .K2040_UnexpectedToken, "Duplicate exported name 'default'")
			} else { scope_map_set(&exported, "default", v.loc.start) }
		case ^ExportAllDeclaration:
			if v == nil { continue }
			// `export * as name from "m"` adds `name` to ExportedNames.
			if ns_name, has_ns := v.exported.(IdentifierName); has_ns {
				if _, exists := scope_map_get(&exported, ns_name.name); exists {
					if !allow_ts_mode(p) {
						msg := fmt.tprintf("Duplicate exported name '%s'", ns_name.name)
						report_error_coded_span(p, .K3020_ImportExportNameOrBinding, u32(ns_name.loc.start), u32(ns_name.loc.start), msg)
					}
				} else { scope_map_set(&exported, ns_name.name, ns_name.loc.start) }
			}
		}
	}
	// §16.2.2 "Export 'X' is not defined in the module" early error.
	// The string-literal-without-from rule is structural; the undeclared
	// name check was in the semantic checker but is now promoted to the
	// parser so parser-only snaps match OXC (test262 early-export-global,
	// early-export-unresolvable).
	// Collect all module-level declared names (Var + Lex + imports).
	// Skip when the program has parse errors — error recovery may produce
	// invalid specifiers that trigger false "not defined" reports.
	errors_before_export_check := len(p.errors)
	module_names: map[string]bool
	module_names.allocator = context.temp_allocator
	if !allow_ts_mode(p) && errors_before_export_check == 0 {
		// Only run for JS modules — TS has global augmentation, ambient
		// modules, etc. that make this check produce false positives.
		for stmt in program.body {
			if stmt == nil { continue }
			#partial switch v in stmt^ {
			case ^VariableDeclaration:
				if v == nil { continue }
				names := make([dynamic]string, 0, 4, context.temp_allocator)
				for d in v.declarations { scope_collect_pattern(d.id, &names) }
				for n in names { module_names[n] = true }
			case ^FunctionDeclaration:
				if v == nil { continue }
				if id, ok := v.id.(BindingIdentifier); ok { module_names[id.name] = true }
			case ^ClassDeclaration:
				if v == nil { continue }
				if id, ok := v.id.(BindingIdentifier); ok { module_names[id.name] = true }
			case ^ImportDeclaration:
				if v == nil { continue }
				for spec in v.specifiers {
					if spec == nil { continue }
					switch ss in spec^ {
					case ImportSpecifier: module_names[ss.local.name] = true
					case ImportDefaultSpecifier: module_names[ss.local.name] = true
					case ImportNamespaceSpecifier: module_names[ss.local.name] = true
					}
				}
			case ^ExportNamedDeclaration:
				if v == nil { continue }
				if d, have := v.declaration.(^Declaration); have && d != nil {
					#partial switch inner in d^ {
					case ^VariableDeclaration:
						if inner == nil { break }
						names := make([dynamic]string, 0, 4, context.temp_allocator)
						for decl in inner.declarations { scope_collect_pattern(decl.id, &names) }
						for n in names { module_names[n] = true }
					case ^FunctionDeclaration:
						if inner != nil { if id, ok := inner.id.(BindingIdentifier); ok { module_names[id.name] = true } }
					case ^ClassDeclaration:
						if inner != nil { if id, ok := inner.id.(BindingIdentifier); ok { module_names[id.name] = true } }
					}
				}
			case ^ExportDefaultDeclaration:
				module_names["default"] = true
				// `export default function foo(){}` also binds `foo`.
				if v != nil && v.declaration != nil {
					#partial switch dd in v.declaration^ {
					case ^Declaration:
						if dd != nil {
							#partial switch inner in dd^ {
							case ^FunctionDeclaration:
								if inner != nil { if id, ok := inner.id.(BindingIdentifier); ok { module_names[id.name] = true } }
							case ^ClassDeclaration:
								if inner != nil { if id, ok := inner.id.(BindingIdentifier); ok { module_names[id.name] = true } }
							}
						}
					case ^Expression:
						if dd != nil {
							#partial switch expr in dd^ {
							case ^FunctionExpression:
								if expr != nil { if id, ok := expr.id.(BindingIdentifier); ok { module_names[id.name] = true } }
							case ^ClassExpression:
								if expr != nil { if id, ok := expr.id.(BindingIdentifier); ok { module_names[id.name] = true } }
							}
						}
					}
				}
			}
			// Also hoist var names from nested blocks/loops/etc.
			hoisted_vars := scope_map_make(4)
			scope_hoist_vars(p, stmt, &hoisted_vars)
			for it in hoisted_vars.items { module_names[it.name] = true }
		}
	}

	for stmt in program.body {
		if stmt == nil { continue }
		export, is_export := stmt^.(^ExportNamedDeclaration)
		if !is_export || export == nil { continue }
		if _, from_source := export.source.(StringLiteral); from_source { continue }
		for spec in export.specifiers {
			if strlit, is_str := spec.local.(^StringLiteral); is_str && strlit != nil {
				err := ParseError{
					start   = strlit.loc.start,
					end     = strlit.loc.end,
					message = "A string literal cannot be used as an exported binding without `from`",
				}
				bump_append(&p.errors, err)
			} else if !allow_ts_mode(p) {
				// §16.2.2 — exported name must be in declared names.
				local_name := ""
				local_loc: u32 = 0
				if id, is_id := spec.local.(IdentifierName); is_id {
					local_name = id.name
					local_loc = id.loc.start
				}
				if local_name != "" && !module_names[local_name] {
					msg := fmt.tprintf("Export '%s' is not defined in the module", local_name)
					err := ParseError{start = local_loc, end = local_loc, message = msg}
					bump_append(&p.errors, err)
				}
			}
		}
	}
}

// ============================================================================
// OPT-6 - minimal scope / binding verification pass.
// ECMA-262 §14.2 / §14.3 / §16.1.1 LexicallyDeclaredNames rules: a
// LexicalDeclaration (let / const / class / function / import / using)
// cannot re-declare a name already bound in the same lexical scope, and
// a VariableStatement's BoundNames cannot clash with an enclosing
// lexically-bound name in the same scope.
// Kessel runs a single-pass parser; this helper walks the completed AST
// once after parsing and verifies each "body-scope" - Program,
// FunctionBody, BlockStatement, CatchClause, SwitchCase (switch block),
// ClassBody static block - for the common cross-statement clash cases
// the existing per-declaration dup check can't see. Full
// `showSemanticErrors` (closure capture, TDZ, etc.) remains an OPT-6
// follow-up; this pass is the MVP shipped in Session 9.

// Extract the BoundNames of a single Statement that contribute to the
// enclosing lexical scope. Returns the kind so the caller can
// distinguish var (hoisted, repeats allowed) from lexical (unique).
ScopeBindingKind :: enum {
	Var,
	Lexical,
	// Annex B.3.2 sloppy FunctionDeclaration inside a Block - a hybrid
	// that clashes with Lexical (same as Lexical would) and clashes
	// with Var (per §14.2.1 LexicallyDeclaredNames ∩ VarDeclaredNames),
	// but tolerates same-kind siblings per §B.3.3 (the `{ function f(){}
	// function f(){} }` sloppy carve-out).
	FunctionAnnexB,
}

// ScopeMap - small-vector + spill-to-hashmap structure used in place of
// `map[string]u32` for per-scope binding tracking. Real-world JS/TS
// bench files have tiny per-scope binding counts (median <8 per
// function body, top-level UMD wrappers have 1-30 entries) where the
// hashmap path's allocator + hasher + bucket-probe overhead dwarfs a
// flat linear scan. A flat array hits L1 in one or two lines and has
// zero allocator overhead per lookup. But large scopes do exist - the
// TypeScript compiler bundle has function bodies with hundreds of
// `var` declarations, where O(N2) linear scan is catastrophic. Above
// SCOPE_MAP_LINEAR_MAX we lazily promote to a `map[string]u32` and
// use it for all subsequent ops, keeping the items array as the
// source-of-truth for iteration so the cheaper data-locality scan is
// preserved for the common case.
SCOPE_MAP_LINEAR_MAX :: 32

ScopeMapEntry :: struct {
	name: string,
	at:   u32,
}
ScopeMap :: struct {
	items: [dynamic]ScopeMapEntry,
	spill: map[string]u32,  // populated lazily when items grows past SCOPE_MAP_LINEAR_MAX
}

scope_map_make :: #force_inline proc(cap: int, allocator := context.temp_allocator) -> ScopeMap {
	items := make([dynamic]ScopeMapEntry, 0, cap, allocator)
	return ScopeMap{items = items}
}

// Build the spill hashmap from the flat items list. Called once when the
// scope crosses the linear threshold; subsequent inserts append to items
// AND set the spill map.
scope_map_promote :: proc(m: ^ScopeMap) {
	m.spill = make(map[string]u32, len(m.items)*2, context.temp_allocator)
	for it in m.items {
		m.spill[it.name] = it.at
	}
}

scope_map_get :: #force_inline proc(m: ^ScopeMap, name: string) -> (u32, bool) {
	if len(m.spill) > 0 {
		at, have := m.spill[name]
		return at, have
	}
	for &it in m.items {
		if it.name == name { return it.at, true }
	}
	return 0, false
}

scope_map_set :: #force_inline proc(m: ^ScopeMap, name: string, at: u32) {
	if len(m.spill) > 0 {
		// Spill mode: source of truth is the hashmap, but keep items
		// in sync for ordered iteration via `for it in m.items`.
		if _, have := m.spill[name]; !have {
			m.spill[name] = at
			bump_append(&m.items, ScopeMapEntry{name = name, at = at})
		} else {
			m.spill[name] = at
			for &it in m.items {
				if it.name == name { it.at = at; break }
			}
		}
		return
	}
	for &it in m.items {
		if it.name == name { it.at = at; return }
	}
	bump_append(&m.items, ScopeMapEntry{name = name, at = at})
	if len(m.items) > SCOPE_MAP_LINEAR_MAX { scope_map_promote(m) }
}

scope_map_set_first :: #force_inline proc(m: ^ScopeMap, name: string, at: u32) {
	// Insert if absent; otherwise leave the first-seen offset intact. Used
	// for §13.3.2 var-list semantics where repeats are legal but only the
	// first offset matters for diagnostics.
	if len(m.spill) > 0 {
		if _, have := m.spill[name]; have { return }
		m.spill[name] = at
		bump_append(&m.items, ScopeMapEntry{name = name, at = at})
		return
	}
	for &it in m.items {
		if it.name == name { return }
	}
	bump_append(&m.items, ScopeMapEntry{name = name, at = at})
	if len(m.items) > SCOPE_MAP_LINEAR_MAX { scope_map_promote(m) }
}

// scope_emit — emits a scope-clash diagnostic into the active parser's
// error list. Nil p is a silent no-op so callers can run
// scope_check_body in --ast-only mode (no parser, no errors).
// Pre-slice-15 this routed through `checker_append_error` (the scope
// pass lived in the checker). Promotion moves the
// scope-emit destination back onto the parser so parser-only snaps
// pick up duplicate-binding diagnostics natively. Callers from the
// checker still pass the parser pointer (via c.pending_parser) so the
// errors flow into the same job.parser.errors stream the checker's
// other diagnostics merge into.
scope_emit :: #force_inline proc(p: ^Parser, at: u32, message: string) {
	if p == nil { return }
	bump_append(&p.errors, ParseError{start = at, end = at, message = message})
}

scope_add :: proc(p: ^Parser, lex, vars: ^ScopeMap, name: string, at: u32, kind: ScopeBindingKind) {
	switch kind {
	case .Lexical:
		if _, have := scope_map_get(lex, name); have {
			scope_emit(p, at, fmt.tprintf("'%s' has already been declared", name))
			return
		}
		if _, have := scope_map_get(vars, name); have {
			scope_emit(p, at, fmt.tprintf("Identifier '%s' has already been declared", name))
		}
		scope_map_set(lex, name, at)
	case .Var:
		if _, have := scope_map_get(lex, name); have {
			scope_emit(p, at, fmt.tprintf("Identifier '%s' has already been declared", name))
			return
		}
		// Repeats of the same var are legal (§13.3.2 - VarDeclaredNames
		// may contain repeats). Only record the first offset.
		scope_map_set_first(vars, name, at)
	case .FunctionAnnexB:
		// Annex B.3.2 FunctionDeclaration-in-Block. Sibling-FunctionDecls
		// with the same name are OK (§B.3.3), but clashes with any
		// lexical or var binding are errors.
		if _, have := scope_map_get(lex, name); have {
			// Silent on same-name previous FunctionDecl; error on
			// let/const/class. Distinguish by probing vars too: a
			// .FunctionAnnexB entry is also written into `vars` below,
			// while a .Lexical isn't. If the name is in `lex` but NOT
			// in `vars`, it came from let/const/class - clash.
			if _, vh := scope_map_get(vars, name); !vh {
				scope_emit(p, at, fmt.tprintf("'%s' has already been declared", name))
			}
			return
		}
		if _, have := scope_map_get(vars, name); have {
			// var-from-real-var before us. `{ var f; function f(){} }`
			// in sloppy rejects per Acorn / V8.
			scope_emit(p, at, fmt.tprintf("Identifier '%s' has already been declared", name))
			return
		}
		scope_map_set(lex, name, at)
		scope_map_set(vars, name, at)
	}
}

scope_collect_pattern :: proc(pat: Pattern, out: ^[dynamic]string) {
	if pat == nil { return }
	switch v in pat {
	case ^Identifier:
		if v != nil { append(out, v.name) }
	case ^ObjectPattern:
		if v == nil { return }
		for prop in v.properties { scope_collect_pattern(prop.value, out) }
	case ^ArrayPattern:
		if v == nil { return }
		for e in v.elements {
			if inner, ok := e.(Pattern); ok { scope_collect_pattern(inner, out) }
		}
	case ^AssignmentPattern:
		if v != nil { scope_collect_pattern(v.left, out) }
	case ^RestElement:
		if v != nil { scope_collect_pattern(v.argument, out) }
	case ^MemberExpression:
		return
	}
}

// Recursively hoist `var` VarDeclaredNames from nested Blocks/loops/if
// bodies into the parent scope. Used by scope_process_statement to
// implement the §14.2.1 early error: "It is a Syntax Error if any element
// of the LexicallyDeclaredNames of StatementList also occurs in the
// VarDeclaredNames of StatementList." `var` declarations hoist across block
// boundaries; `let`/`const`/`class` do NOT hoist and are excluded.
scope_hoist_vars :: proc(p: ^Parser, stmt: ^Statement, vars: ^ScopeMap) {
	if stmt == nil { return }
	#partial switch v in stmt^ {
	case ^VariableDeclaration:
		if v == nil || v.kind != .Var { return }
		names := make([dynamic]string, 0, 4, context.temp_allocator)
		for decl in v.declarations { scope_collect_pattern(decl.id, &names) }
		for n in names {
			scope_map_set_first(vars, n, v.loc.start)
		}
	case ^BlockStatement:
		if v == nil { return }
		for inner in v.body { scope_hoist_vars(p, inner, vars) }
	case ^IfStatement:
		if v == nil { return }
		scope_hoist_vars(p, v.consequent, vars)
		if alt, have := v.alternate.(^Statement); have { scope_hoist_vars(p, alt, vars) }
	case ^WhileStatement:
		if v != nil { scope_hoist_vars(p, v.body, vars) }
	case ^DoWhileStatement:
		if v != nil { scope_hoist_vars(p, v.body, vars) }
	case ^ForStatement:
		if v != nil {
			// for-loop init var is already collected as a sibling statement;
			// hoist vars from the body only.
			scope_hoist_vars(p, v.body, vars)
		}
	case ^ForInStatement:
		if v != nil { scope_hoist_vars(p, v.body, vars) }
	case ^ForOfStatement:
		if v != nil { scope_hoist_vars(p, v.body, vars) }
	case ^LabeledStatement:
		if v != nil { scope_hoist_vars(p, v.body, vars) }
	case ^WithStatement:
		if v != nil { scope_hoist_vars(p, v.body, vars) }
	case ^TryStatement:
		if v != nil {
			for inner in v.block.body { scope_hoist_vars(p, inner, vars) }
			if h, have := v.handler.(CatchClause); have {
				for inner in h.body.body { scope_hoist_vars(p, inner, vars) }
			}
			if f, have := v.finalizer.(BlockStatement); have {
				for inner in f.body { scope_hoist_vars(p, inner, vars) }
			}
		}
	case ^SwitchStatement:
		if v != nil {
			for c in v.cases {
				for inner in c.consequent { scope_hoist_vars(p, inner, vars) }
			}
		}
	// Function declarations do NOT hoist vars from inner bodies
	// (they have their own VarScope). FunctionDeclaration, ClassDeclaration,
	// FunctionExpression bodies, etc. are all scoping boundaries.
	}
}

// check_for_head_body_shadow — §14.7.4.1 / §14.7.5.1 — enforces that
// the BoundNames of a for-head LexicalDeclaration (let/const/using)
// collect_body_lex_names walks body statements and collects all
// LexicallyDeclaredNames into `lex`. Does NOT report errors (this is
// a silent collector for cross-scope clash detection). Only records
// let/const/class/import declarations at the TOP LEVEL of the body.
// Does NOT recurse into nested blocks — per the spec, LexicallyDeclaredNames
// of FunctionBody / Block only includes its own direct StatementList.
collect_body_lex_names :: proc(body: []^Statement, lex: ^ScopeMap, strict := true) {
	for stmt in body {
		if stmt == nil { continue }
		#partial switch v in stmt^ {
		case ^VariableDeclaration:
			if v == nil || v.kind == .Var { continue }
			names := make([dynamic]string, 0, 4, context.temp_allocator)
			for decl in v.declarations { scope_collect_pattern(decl.id, &names) }
			for n in names { scope_map_set(lex, n, v.loc.start) }
		case ^FunctionDeclaration:
			// In sloppy mode (non-strict function bodies), function
			// declarations hoist as var-like per Annex B.3.2, so they
			// are NOT LexicallyDeclaredNames. Only count them as
			// lexical in strict mode.
			if strict && v != nil {
				if id, ok := v.id.(BindingIdentifier); ok {
					scope_map_set(lex, id.name, id.loc.start)
				}
			}
		case ^ClassDeclaration:
			if v != nil {
				if id, ok := v.id.(BindingIdentifier); ok {
					scope_map_set(lex, id.name, id.loc.start)
				}
			}
		// Do NOT recurse into nested blocks, loops, ifs, etc.
		// LexicallyDeclaredNames only includes direct declarations.
		}
	}
}

// check_params_vs_body_lex — §15.2.1.1 / §15.5.1 — BoundNames of
// FormalParameters may not occur in LexicallyDeclaredNames of
// FunctionBody. `function f(a) { const a = 1; }` is a SyntaxError.
check_params_vs_body_lex :: proc(p: ^Parser, params: []FunctionParameter, body: []^Statement) {
	if len(params) == 0 || len(body) == 0 { return }
	param_names: [dynamic]string
	param_names.allocator = context.temp_allocator
	reserve(&param_names, len(params)*2)
	for pr in params {
		scope_collect_pattern(pr.pattern, &param_names)
	}
	if len(param_names) == 0 { return }
	body_lex := scope_map_make(4)
	// In sloppy mode, FunctionDeclarations in function bodies are var-hoisted
	// (Annex B.3.2), not lexical. Pass strict so they're only counted as
	// lexical in strict mode.
	collect_body_lex_names(body, &body_lex, p.ctx.strict_mode)
	for n in param_names {
		if off, have := scope_map_get(&body_lex, n); have {
			report_error_coded_span(p, .K3037_DuplicateIdentifier, u32(off), u32(off), fmt.tprintf("Formal parameter '%s' cannot be redeclared with let/const in function body", n))
		}
	}
}

// check_catch_param_dups — §14.15 — BoundNames of CatchParameter
// must be unique. Catches `catch ([x, x]) {}` etc.
check_catch_param_dups :: proc(p: ^Parser, param: Maybe(Pattern)) {
	pat, have := param.(Pattern)
	if !have || pat == nil { return }
	names: [dynamic]string
	names.allocator = context.temp_allocator
	reserve(&names, 4)
	scope_collect_pattern(pat, &names)
	seen := scope_map_make(4)
	for n in names {
		if off, exists := scope_map_get(&seen, n); exists {
			report_error_coded_span(p, .K3037_DuplicateIdentifier, u32(off), u32(off), fmt.tprintf("Identifier '%s' has already been declared in catch clause", n))
		} else {
			scope_map_set(&seen, n, 0)  // offset unused for duplicate check
		}
	}
}

// check_catch_param_body_shadow — §14.15.1 — BoundNames of
// CatchParameter may not occur in LexicallyDeclaredNames of Block.
// `catch (e) { let e; }` is a SyntaxError.
// Also: Annex B §B.3.4 — when the CatchParameter is a destructuring
// pattern (BindingPattern, not simple Identifier), `var` redeclaration
// of its BoundNames is also a SyntaxError.
check_catch_param_body_shadow :: proc(p: ^Parser, param: Maybe(Pattern), body: []^Statement) {
	pat, have := param.(Pattern)
	if !have || pat == nil { return }
	if len(body) == 0 { return }
	param_names: [dynamic]string
	param_names.allocator = context.temp_allocator
	reserve(&param_names, 4)
	scope_collect_pattern(pat, &param_names)
	if len(param_names) == 0 { return }

	// Check against lexical declarations (let/const/class).
	body_lex := scope_map_make(4)
	// Catch body is block-scope: function declarations are always lexical.
	collect_body_lex_names(body, &body_lex, true)
	for n in param_names {
		if off, have := scope_map_get(&body_lex, n); have {
			report_error_coded_span(p, .K3037_DuplicateIdentifier, u32(off), u32(off), fmt.tprintf("Catch parameter '%s' cannot be redeclared with let/const in catch block", n))
		}
	}

	// Annex B §B.3.4: when catch parameter is a BindingPattern (destructuring),
	// `var` redeclaration of its BoundNames is also an error. Simple Identifier
	// catch bindings allow `var` redeclaration per web-compat (§B.3.4 carve-out).
	is_destructuring := false
	#partial switch _ in pat {
	case ^ObjectPattern: is_destructuring = true
	case ^ArrayPattern:  is_destructuring = true
	}
	if is_destructuring {
		body_vars := scope_map_make(4)
		for stmt in body { scope_hoist_vars(p, stmt, &body_vars) }
		for n in param_names {
			if at, found := scope_map_get(&body_vars, n); found {
				scope_emit(p, at, fmt.tprintf("Identifier '%s' has already been declared", n))
			}
		}
	}
}

// Process one Statement and add its contributing lexical/var BoundNames
// to the scope maps. Nested scopes are NOT recursed here - the caller's
// walker handles that separately.
scope_process_statement :: proc(p: ^Parser, stmt: ^Statement, lex, vars: ^ScopeMap, is_block_scope: bool = false) {
	if stmt == nil { return }
	#partial switch v in stmt^ {
	case ^VariableDeclaration:
		if v == nil { return }
		kind: ScopeBindingKind = .Var
		if v.kind != .Var { kind = .Lexical }
		names := make([dynamic]string, 0, 4, context.temp_allocator)
		for decl in v.declarations { scope_collect_pattern(decl.id, &names) }
		for n in names { scope_add(p, lex, vars, n, v.loc.start, kind) }
	case ^BlockStatement:
		// §14.2.1 - Hoist `var` VarDeclaredNames from nested blocks into this
		// scope so lex/var clashes like `{ { var f; } let f; }` are detected.
		if v == nil { return }
		// Use a temporary vars map to collect only the hoisted var names,
		// then call scope_add for each so clash detection runs.
		hoisted := scope_map_make(4)
		for inner in v.body { scope_hoist_vars(p, inner, &hoisted) }
		for it in hoisted.items { scope_add(p, lex, vars, it.name, it.at, .Var) }
	case ^ForInStatement:
		// §14.7.5 — `for (let/const x in expr) { var x; }` is a SyntaxError.
		// The for-in head's let/const creates a containing block scope;
		// var declarations in the body hoist past the body's block but
		// collide with the head's lexical binding.
		if v == nil { return }
		if left_decl, ok := v.left_decl.(^VariableDeclaration); ok && left_decl != nil && left_decl.kind != .Var {
			head_names := make([dynamic]string, 0, 2, context.temp_allocator)
			for d in left_decl.declarations { scope_collect_pattern(d.id, &head_names) }
			body_vars := scope_map_make(4)
			scope_hoist_vars(p, v.body, &body_vars)
			for hn in head_names {
				if at, found := scope_map_get(&body_vars, hn); found {
					scope_emit(p, at, fmt.tprintf("Identifier '%s' has already been declared", hn))
				}
			}
		}
		// Also hoist vars from the body into the enclosing scope.
		hoisted_fi := scope_map_make(4)
		scope_hoist_vars(p, v.body, &hoisted_fi)
		for it in hoisted_fi.items { scope_add(p, lex, vars, it.name, it.at, .Var) }
	case ^ForOfStatement:
		// Same rule as ForInStatement above.
		if v == nil { return }
		if left_decl, ok := v.left_decl.(^VariableDeclaration); ok && left_decl != nil && left_decl.kind != .Var {
			head_names := make([dynamic]string, 0, 2, context.temp_allocator)
			for d in left_decl.declarations { scope_collect_pattern(d.id, &head_names) }
			body_vars := scope_map_make(4)
			scope_hoist_vars(p, v.body, &body_vars)
			for hn in head_names {
				if at, found := scope_map_get(&body_vars, hn); found {
					scope_emit(p, at, fmt.tprintf("Identifier '%s' has already been declared", hn))
				}
			}
		}
		hoisted_fo := scope_map_make(4)
		scope_hoist_vars(p, v.body, &hoisted_fo)
		for it in hoisted_fo.items { scope_add(p, lex, vars, it.name, it.at, .Var) }
	case ^ForStatement:
		// §14.7.4 — `for (let i = 0; ...) { var i; }` same pattern.
		if v == nil { return }
		if init_decl, ok := v.init_decl.(^VariableDeclaration); ok && init_decl != nil && init_decl.kind != .Var {
			head_names := make([dynamic]string, 0, 2, context.temp_allocator)
			for d in init_decl.declarations { scope_collect_pattern(d.id, &head_names) }
			body_vars := scope_map_make(4)
			scope_hoist_vars(p, v.body, &body_vars)
			for hn in head_names {
				if at, found := scope_map_get(&body_vars, hn); found {
					scope_emit(p, at, fmt.tprintf("Identifier '%s' has already been declared", hn))
				}
			}
		}
		hoisted_fs := scope_map_make(4)
		scope_hoist_vars(p, v.body, &hoisted_fs)
		for it in hoisted_fs.items { scope_add(p, lex, vars, it.name, it.at, .Var) }
	case ^FunctionDeclaration:
		if v == nil { return }
		// TS: function declarations can legitimately merge with same-
		// named classes / namespaces / interfaces / type aliases / enums
		// in the same module ("expando function", "function + namespace",
		// overload signatures with declare-class, etc.). The type
		// checker disambiguates which side a reference targets, so
		// parser-side dup detection produces too many false positives
		// in TS. Skip in TS mode entirely.
		if allow_ts_mode(p) { return }
		if id, ok := v.id.(BindingIdentifier); ok {
			// Annex B.3.2 / §14.1.3 / §16.1.7 / §16.2.1:
			//   - block scope: strict + sloppy-async/generator are .Lexical
			//     (sibling dups error). Sloppy plain Function -> .FunctionAnnexB.
			//   - module top level (§16.2.1.1): "At the top level of a Module,
			//     function declarations are treated like lexical declarations."
			//     Duplicates are SyntaxError -> .Lexical.
			//   - script / function-body top level: HoistableDeclarations are
			//     in VarDeclaredNames, NOT LexicallyDeclaredNames. Same-name
			//     duplicates are valid (re-binding the same hoisted slot) in
			//     both strict and sloppy modes.
			kind: ScopeBindingKind = .Var
			if is_block_scope {
				if !p.ctx.strict_mode && !v.async && !v.generator {
					kind = .FunctionAnnexB
				} else {
					kind = .Lexical
				}
			} else if p.in_module_top_level {
				// Module top-level: spec treats fn decls as lexical for the
				// duplicate check. parse_program runs the body scope check
				// with `in_module_top_level` still set when --source-type=
				// module is pinned; auto-detected modules upgrade after the
				// parse so the check there falls back to .Var (the semantic
				// checker still catches it via its own walk).
				kind = .Lexical
			}
			scope_add(p, lex, vars, id.name, id.loc.start, kind)
		}
	case ^ClassDeclaration:
		if v == nil { return }
		// TS: class declarations also participate in declaration
		// merging — same reasoning as FunctionDeclaration above.
		if allow_ts_mode(p) { return }
		if id, ok := v.id.(BindingIdentifier); ok {
			scope_add(p, lex, vars, id.name, id.loc.start, .Lexical)
		}
	case ^ImportDeclaration:
		if v == nil { return }
		// TS: imports can legitimately merge with same-named
		// FunctionDeclaration / ClassDeclaration / TSInterfaceDeclaration /
		// TSTypeAliasDeclaration etc. in the same module — the
		// type-checker resolves which side the reference targets. Skip
		// the scope-add in TS mode so the parser-side check doesn't
		// fire false positives on "expando function" patterns like
		// `import Foo from "x"; export function Foo() {}`. JS-mode
		// imports never have this carve-out.
		if allow_ts_mode(p) { return }
		for spec in v.specifiers {
			if spec == nil { continue }
			switch ss in spec^ {
			case ImportSpecifier:
				scope_add(p, lex, vars, ss.local.name, ss.local.loc.start, .Lexical)
			case ImportDefaultSpecifier:
				scope_add(p, lex, vars, ss.local.name, ss.local.loc.start, .Lexical)
			case ImportNamespaceSpecifier:
				scope_add(p, lex, vars, ss.local.name, ss.local.loc.start, .Lexical)
			}
		}
	case ^ExportNamedDeclaration:
		if v == nil { return }
		if d, have := v.declaration.(^Declaration); have && d != nil {
			switch inner in d^ {
			case ^VariableDeclaration:
				if inner == nil { break }
				kind: ScopeBindingKind = .Var
				if inner.kind != .Var { kind = .Lexical }
				names := make([dynamic]string, 0, 4, context.temp_allocator)
				for decl in inner.declarations { scope_collect_pattern(decl.id, &names) }
				for n in names { scope_add(p, lex, vars, n, inner.loc.start, kind) }
			case ^FunctionDeclaration:
				if inner == nil { break }
				if allow_ts_mode(p) { break }
				if id, ok := inner.id.(BindingIdentifier); ok {
					scope_add(p, lex, vars, id.name, id.loc.start, .Lexical)
				}
			case ^ClassDeclaration:
				if inner == nil { break }
				if allow_ts_mode(p) { break }
				if id, ok := inner.id.(BindingIdentifier); ok {
					scope_add(p, lex, vars, id.name, id.loc.start, .Lexical)
				}
			case ^TSInterfaceDeclaration, ^TSTypeAliasDeclaration,
			     ^TSEnumDeclaration, ^TSModuleDeclaration,
			     ^TSImportEqualsDeclaration,
			     ^ImportDeclaration, ^ExportNamedDeclaration,
			     ^ExportDefaultDeclaration, ^ExportAllDeclaration:
				// Types / nested decls - don't bind into the value scope
				// for dup-check purposes.
			}
		}
	case ^ExportDefaultDeclaration:
		// `export default function F() {}` / `export default class F {}`
		// - the name `F` is bound in the module scope as a lexical.
		// In TS, multiple `export default function foo` overload
		// signatures plus an implementation can coexist (and even merge
		// with an `interface Foo {}`), so skip the scope-add in TS
		// mode — same rationale as the FunctionDeclaration arm above.
		if v == nil { return }
		if allow_ts_mode(p) { return }
		if d := v.declaration; d != nil {
			#partial switch inner in d^ {
			case ^Declaration:
				if inner != nil {
					#partial switch decl in inner^ {
					case ^FunctionDeclaration:
						if decl != nil {
							if id, ok := decl.id.(BindingIdentifier); ok {
								scope_add(p, lex, vars, id.name, id.loc.start, .Lexical)
							}
						}
					case ^ClassDeclaration:
						if decl != nil {
							if id, ok := decl.id.(BindingIdentifier); ok {
								scope_add(p, lex, vars, id.name, id.loc.start, .Lexical)
							}
						}
					}
				}
			case ^Expression:
				// `export default function F(){}` stores a FunctionExpression.
				if inner != nil {
					#partial switch fn in inner^ {
					case ^FunctionExpression:
						if fn != nil {
							if id, ok := fn.id.(BindingIdentifier); ok {
								scope_add(p, lex, vars, id.name, id.loc.start, .Lexical)
							}
						}
					case ^ClassExpression:
						if fn != nil {
							if id, ok := fn.id.(BindingIdentifier); ok {
								scope_add(p, lex, vars, id.name, id.loc.start, .Lexical)
							}
						}
					}
				}
			}
		}
	}
}

// scope_check_body — run lex/var clash detection over one body.
// is_block_scope=true for BlockStatement / switch case-list;
// false for FunctionBody / ArrowFunction block body / static block.
scope_check_body :: #force_inline proc(p: ^Parser, body: []^Statement, is_block_scope: bool, lex, vars: ^ScopeMap) {
	for stmt in body {
		scope_process_statement(p, stmt, lex, vars, is_block_scope)
	}
}

// parser_scope_check — convenience wrapper that uses the parser's
// reusable ScopeMap pair. Called at each scope-bearing parse exit.
parser_scope_check :: proc(p: ^Parser, body: []^Statement, is_block_scope: bool) {
	if p.ast_only { return }
	scope_map_clear(&p.scope_lex)
	scope_map_clear(&p.scope_vars)
	scope_check_body(p, body, is_block_scope, &p.scope_lex, &p.scope_vars)
}

// parser_check_dup_params — §15.1 / §15.2.1 / §15.5.1 / §15.6.1 /
// §15.8.1 — duplicate formal parameter names.
// Strict mode: always reject duplicates.
// Sloppy mode: reject only when the parameter list is non-simple
// (has defaults, destructuring, or rest parameters).
// Arrow functions: always strict (implicit strict params).
parser_check_dup_params :: proc(p: ^Parser, params: []FunctionParameter, fn_loc: u32, is_strict, is_arrow: bool) {
	if p.ast_only { return }
	if len(params) < 2 && !has_destructured_param(params) { return }
	effective_strict := is_strict || is_arrow
	non_simple := is_non_simple_params(params)
	if !effective_strict && !non_simple { return }
	names := make([dynamic]string, 0, 8, context.temp_allocator)
	for pr in params { scope_collect_pattern(pr.pattern, &names) }
	n := len(names)
	if n < 2 { return }
	for i := 1; i < n; i += 1 {
		for j := 0; j < i; j += 1 {
			if names[i] == names[j] {
				if effective_strict {
					report_error_coded_span(p, .K3037_DuplicateIdentifier, u32(fn_loc), u32(fn_loc), fmt.tprintf("Duplicate parameter name '%s' in strict mode", names[i]))
				} else {
					report_error_coded_span(p, .K3037_DuplicateIdentifier, u32(fn_loc), u32(fn_loc), fmt.tprintf("Duplicate parameter name '%s' with non-simple parameter list", names[i]))
				}
				return
			}
		}
	}
}

// is_non_simple_params — §15.1 a parameter list is non-simple if any
// parameter has a default value, is destructured, or is a rest element.
is_non_simple_params :: proc(params: []FunctionParameter) -> bool {
	for pr in params {
		if _, has := pr.default_val.(^Expression); has { return true }
		#partial switch _ in pr.pattern {
		case ^ObjectPattern, ^ArrayPattern, ^RestElement, ^AssignmentPattern:
			return true
		}
	}
	return false
}

// has_destructured_param — true if any param is destructured (for the
// single-param case where we still need to check binding conflicts).
has_destructured_param :: proc(params: []FunctionParameter) -> bool {
	for pr in params {
		#partial switch _ in pr.pattern {
		case ^ObjectPattern, ^ArrayPattern:
			return true
		}
	}
	return false
}

// ============================================================================
// TS declaration conflict checking
// ============================================================================
// In TypeScript mode, standard lex/var scope checks are skipped for
// FunctionDeclaration, ClassDeclaration, and ImportDeclaration because
// TS allows declaration merging (function+namespace, class+namespace, etc.).
// However, certain cross-kind combinations are ALWAYS errors even in TS:
//   - class + class (no merge)
//   - class + enum, enum + class
//   - type alias + type alias (no merge)
//   - type alias + class, class + type alias
//   - type alias + enum, enum + type alias
//   - type alias + interface, interface + type alias? No: interface+type=error per OXC
//   - enum + let/var/const
//   - enum + function
//   - let/var/const + enum
//   - const enum + regular enum (and vice versa)
//   - import type + import value (same name)
// This function implements OXC's parser-level TS scope checks.

// TSBindingKind tracks what kind of TS declaration a name represents.
TSBindingKind :: enum u8 {
	Class,
	Enum,
	ConstEnum,
	TypeAlias,
	Interface,
	Function,
	VarLike,       // var, let, const
	ImportValue,
	ImportType,
	Namespace,
}

TSBindingEntry :: struct {
	name: string,
	at:   u32,
	kind: TSBindingKind,
}

// ts_conflicts returns true if two TS declarations of the same name are
// KNOWN to conflict. Conservative: only flags combinations that OXC's
// parser catches. Returns false (no conflict) for anything uncertain.
ts_conflicts :: proc(a, b: TSBindingKind) -> bool {
	// Class + Class: always error (no merge).
	if a == .Class && b == .Class { return true }
	// Class + Enum or Enum + Class: always error.
	if (a == .Class && (b == .Enum || b == .ConstEnum)) ||
	   ((a == .Enum || a == .ConstEnum) && b == .Class) { return true }
	// Class + TypeAlias or TypeAlias + Class: error (occupies type space).
	if (a == .Class && b == .TypeAlias) || (a == .TypeAlias && b == .Class) { return true }
	// TypeAlias + TypeAlias: always error (no merge).
	if a == .TypeAlias && b == .TypeAlias { return true }
	// TypeAlias + Enum or Enum + TypeAlias: error.
	if (a == .TypeAlias && (b == .Enum || b == .ConstEnum)) ||
	   ((a == .Enum || a == .ConstEnum) && b == .TypeAlias) { return true }
	// TypeAlias + Interface or Interface + TypeAlias: error (type space clash).
	if (a == .TypeAlias && b == .Interface) || (a == .Interface && b == .TypeAlias) { return true }
	// Enum + VarLike or VarLike + Enum: error (value space clash).
	if ((a == .Enum || a == .ConstEnum) && b == .VarLike) ||
	   (a == .VarLike && (b == .Enum || b == .ConstEnum)) { return true }
	// Enum + Function or Function + Enum: error.
	if ((a == .Enum || a == .ConstEnum) && b == .Function) ||
	   (a == .Function && (b == .Enum || b == .ConstEnum)) { return true }
	// Enum + Interface or Interface + Enum: error (type space clash).
	if ((a == .Enum || a == .ConstEnum) && b == .Interface) ||
	   (a == .Interface && (b == .Enum || b == .ConstEnum)) { return true }
	// ConstEnum + Enum (mismatched constness): error.
	if (a == .ConstEnum && b == .Enum) || (a == .Enum && b == .ConstEnum) { return true }
	// ImportType + ImportValue (same name): error per OXC/Babel.
	if (a == .ImportType && b == .ImportValue) || (a == .ImportValue && b == .ImportType) { return true }
	// Everything else: no known conflict. Scope-level TS2300 for
	// Class+Var, Function+Var, Class+Function varies by context and
	// TS allows many combinations that JS forbids (declaration merging,
	// namespace augmentation, etc.). Conservative: don't flag here.
	return false
}

// check_ts_scope_conflicts — walks a statement list and reports TS
// declaration-kind conflicts. Called on program body and namespace bodies.
check_ts_scope_conflicts :: proc(p: ^Parser, body: []^Statement) {
	if !allow_ts_mode(p) || p.ast_only { return }

	// Collect all top-level declaration names with their TS kind.
	entries := make([dynamic]TSBindingEntry, 0, 16, context.temp_allocator)

	for stmt in body {
		if stmt == nil { continue }
		// Unwrap ExportNamedDeclaration to get the inner declaration.
		inner_stmt := stmt
		#partial switch v in stmt^ {
		case ^ExportNamedDeclaration:
			if v != nil {
				if d, have := v.declaration.(^Declaration); have && d != nil {
					// Wrap inner declaration back as a Statement for uniform handling below.
					// Allocate a temp Statement on the stack.
					#partial switch inner in d^ {
					case ^ClassDeclaration:
						if inner != nil {
							if id, ok := inner.id.(BindingIdentifier); ok {
								append(&entries, TSBindingEntry{name = id.name, at = id.loc.start, kind = .Class})
							}
						}
					case ^FunctionDeclaration:
						if inner != nil {
							if id, ok := inner.id.(BindingIdentifier); ok {
								append(&entries, TSBindingEntry{name = id.name, at = id.loc.start, kind = .Function})
							}
						}
					case ^VariableDeclaration:
						if inner != nil {
							names := make([dynamic]string, 0, 4, context.temp_allocator)
							for decl in inner.declarations { scope_collect_pattern(decl.id, &names) }
							for n in names {
								append(&entries, TSBindingEntry{name = n, at = inner.loc.start, kind = .VarLike})
							}
						}
					case ^TSEnumDeclaration:
						if inner != nil {
							kind: TSBindingKind = inner.const_ ? .ConstEnum : .Enum
							append(&entries, TSBindingEntry{name = inner.id.name, at = inner.id.loc.start, kind = kind})
						}
					case ^TSInterfaceDeclaration:
						if inner != nil {
							append(&entries, TSBindingEntry{name = inner.id.name, at = inner.id.loc.start, kind = .Interface})
						}
					case ^TSTypeAliasDeclaration:
						if inner != nil {
							append(&entries, TSBindingEntry{name = inner.id.name, at = inner.id.loc.start, kind = .TypeAlias})
						}
					case ^TSModuleDeclaration:
						if inner != nil {
							// Get name from the id expression
							if inner.id != nil {
								if ident, ok := inner.id^.(^Identifier); ok && ident != nil {
									append(&entries, TSBindingEntry{name = ident.name, at = ident.loc.start, kind = .Namespace})
								}
							}
						}
					}
				}
			}
			continue
		}

		#partial switch v in inner_stmt^ {
		case ^ClassDeclaration:
			if v != nil {
				if id, ok := v.id.(BindingIdentifier); ok {
					append(&entries, TSBindingEntry{name = id.name, at = id.loc.start, kind = .Class})
				}
			}
		case ^FunctionDeclaration:
			if v != nil {
				if id, ok := v.id.(BindingIdentifier); ok {
					append(&entries, TSBindingEntry{name = id.name, at = id.loc.start, kind = .Function})
				}
			}
		case ^VariableDeclaration:
			if v != nil {
				names := make([dynamic]string, 0, 4, context.temp_allocator)
				for decl in v.declarations { scope_collect_pattern(decl.id, &names) }
				for n in names {
					append(&entries, TSBindingEntry{name = n, at = v.loc.start, kind = .VarLike})
				}
			}
		case ^TSEnumDeclaration:
			if v != nil {
				kind: TSBindingKind = v.const_ ? .ConstEnum : .Enum
				append(&entries, TSBindingEntry{name = v.id.name, at = v.id.loc.start, kind = kind})
			}
		case ^TSInterfaceDeclaration:
			if v != nil {
				append(&entries, TSBindingEntry{name = v.id.name, at = v.id.loc.start, kind = .Interface})
			}
		case ^TSTypeAliasDeclaration:
			if v != nil {
				append(&entries, TSBindingEntry{name = v.id.name, at = v.id.loc.start, kind = .TypeAlias})
			}
		case ^TSModuleDeclaration:
			if v != nil {
				if v.id != nil {
					if ident, ok := v.id^.(^Identifier); ok && ident != nil {
						append(&entries, TSBindingEntry{name = ident.name, at = ident.loc.start, kind = .Namespace})
					}
				}
			}
		case ^ImportDeclaration:
			if v != nil {
				kind: TSBindingKind = v.import_kind == .Type ? .ImportType : .ImportValue
				for spec in v.specifiers {
					if spec == nil { continue }
					switch ss in spec^ {
					case ImportSpecifier:
						append(&entries, TSBindingEntry{name = ss.local.name, at = ss.local.loc.start, kind = kind})
					case ImportDefaultSpecifier:
						append(&entries, TSBindingEntry{name = ss.local.name, at = ss.local.loc.start, kind = kind})
					case ImportNamespaceSpecifier:
						append(&entries, TSBindingEntry{name = ss.local.name, at = ss.local.loc.start, kind = kind})
					}
				}
			}
		}
	}

	// O(n^2) check for conflicts — fine because typical scope has <30 declarations.
	for i := 0; i < len(entries); i += 1 {
		for j := 0; j < i; j += 1 {
			if entries[i].name == entries[j].name {
				if ts_conflicts(entries[j].kind, entries[i].kind) {
					scope_emit(p, entries[i].at,
						fmt.tprintf("Identifier '%s' has already been declared", entries[i].name))
					break  // Only report once per duplicate
				}
			}
		}
	}
}

// Reset a ScopeMap so the caller's `lex` / `vars` pool can be reused for the
// next body. Keeps the items backing buffer (capacity) and the spill map's
// hashtable; just resets length / clears entries. Faster than re-allocation.
scope_map_clear :: #force_inline proc(m: ^ScopeMap) {
	resize(&m.items, 0)
	if len(m.spill) > 0 {
		clear(&m.spill)
	}
}

// Helper: Convert ExportSpecifierName to ESMExportNameEntry
convert_export_spec_name :: proc(name: ExportSpecifierName) -> ESMExportNameEntry {
	#partial switch n in name {
	case IdentifierName:
		return ESMExportNameEntry{
			kind = .Name,
			name = n.name,
			start = n.loc.start,
			end = n.loc.end,
		}
	case ^StringLiteral:
		return ESMExportNameEntry{
			kind = .Name,
			name = n.value,
			start = n.loc.start,
			end = n.loc.end,
		}
	}
	return ESMExportNameEntry{}
}

// Extract the local BindingIdentifier name from any ImportSpecifierSpec
// variant. Used by the ECMA-262 §16.2.2 BoundNames-uniqueness check.
// Returns "" when the specifier is malformed (so the duplicate scan
// naturally skips it).
import_spec_local_name :: proc(spec: ^ImportSpecifierSpec) -> string {
	if spec == nil { return "" }
	#partial switch s in spec {
	case ImportSpecifier:
		return s.local.name
	case ImportDefaultSpecifier:
		return s.local.name
	case ImportNamespaceSpecifier:
		return s.local.name
	}
	return ""
}

// Helper: Convert ImportSpecifierSpec to ESMNameEntry + ESMStaticImportEntry
collect_esm_import_entry :: proc(spec: ^ImportSpecifierSpec) -> ESMStaticImportEntry {
	entry := ESMStaticImportEntry{}

	#partial switch s in spec^ {
	case ImportDefaultSpecifier:
		// import X from "m" - X is the local binding
		entry.importName = ESMNameEntry{
			kind = .Default,
			name = "",
			start = 0,
			end = 0,
		}
		entry.localName = ESMNameEntry{
			kind = .Default,
			name = s.local.name,
			start = s.local.loc.start,
			end = s.local.loc.end,
		}
	case ImportNamespaceSpecifier:
		// import * as X from "m"
		entry.importName = ESMNameEntry{
			kind = .Namespace,
			name = "*",
			start = 0,
			end = 0,
		}
		entry.localName = ESMNameEntry{
			kind = .Namespace,
			name = s.local.name,
			start = s.local.loc.start,
			end = s.local.loc.end,
		}
	case ImportSpecifier:
		// import { x, y as z } from "m"
		entry.importName = ESMNameEntry{
			kind = .Name,
			name = s.imported.name,
			start = s.imported.loc.start,
			end = s.imported.loc.end,
		}
		entry.localName = ESMNameEntry{
			kind = .Name,
			name = s.local.name,
			start = s.local.loc.start,
			end = s.local.loc.end,
		}
	}
	return entry
}

// append_import_spec promotes a ^ImportSpecifier / ^ImportDefaultSpecifier /
// ^ImportNamespaceSpecifier to a ^ImportSpecifierSpec (union) via assignment,
// so the union variant tag is written correctly. Directly casting the
// pointer `(^ImportSpecifierSpec)(spec)` preserves the address but not the
// tag — the emitter's `switch v in spec_ptr^` then falls through to no
// matching case and emits `{}`. Same fix as print_declaration_ast.
append_import_spec :: proc(specs: ^[dynamic]^ImportSpecifierSpec, spec: $T, allocator: mem.Allocator) {
	u := new(ImportSpecifierSpec, allocator)
	u^ = spec^
	append(specs, u)
}

parse_import_declaration :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume import

	// Inside a TS namespace body, the parser may still descend into
	// parse_import_declaration (e.g. for malformed input). Any
	// downstream `p.has_module_syntax = true` writes there don't
	// reflect ES module syntax of the OUTER program. Save and restore
	// so the namespace body can't pollute the file's classification.
	restore_module_syntax := p.ctx.in_ts_namespace
	prev_module_syntax := p.has_module_syntax
	prev_pre_scan_done := p.module_pre_scan_done
	defer if restore_module_syntax {
		p.has_module_syntax    = prev_module_syntax
		p.module_pre_scan_done = prev_pre_scan_done
	}

	// §16.2 "import only valid in module code" early error: enforced by
	// the semantic checker (ck_check_import_export_position) consulting
	// program.type. The parser still builds a complete ImportDeclaration
	// AST node so downstream tooling has stable span info.

	decl := new_node(p, ImportDeclaration)
	decl.loc = start
	decl.specifiers = make([dynamic]^ImportSpecifierSpec, 0, 4, p.allocator)

	// Phase Imports stage-3: §16.2 ImportDeclaration extended with
	//   import defer * as ns from "x"
	//   import source x from "x"
	// `defer` and `source` are contextual keywords - lex as .Identifier
	// here. Detect by peeking the next token: `defer` must be followed
	// by `*` (NameSpaceImport-only per the import-defer proposal);
	// `source` must be followed by an Identifier (default binding).
	if p.cur_type == .Identifier && cur_value_eq(p, "defer") {
		if p.lexer != nil { ensure_nxt(p) }
		if p.lexer != nil && p.lexer.nxt.kind == .Mul {
			decl.phase = "defer"
			eat(p) // consume `defer`
		}
	} else if p.cur_type == .Identifier && cur_value_eq(p, "source") {
		if p.lexer != nil { ensure_nxt(p) }
		if p.lexer != nil && p.lexer.nxt.kind == .Identifier {
			decl.phase = "source"
			eat(p) // consume `source`
  ensure_nxt(p)
		} else if p.lexer != nil && p.lexer.nxt.kind == .From {
			snap := lexer_snapshot(p)
			eat(p) // consume `source`
			ensure_nxt(p)
			if p.lexer.nxt.kind == .From {
				decl.phase = "source"
			} else {
				lexer_restore(p, snap)
			}
		}
	}

	// TS `import type ...` - type-only import. `type` lexes as Identifier.
	// Disambiguate from `import type from "m"` (value import of default binding
	// named "type"): after `type`, the next token must be `{`, `*`, or an
	// identifier followed by `,`/`from` (but NOT `from` directly).
	if p.cur_type == .Identifier && cur_value_eq(p, "type") && allow_ts_mode(p) {
		// §12.7.2 - contextual keyword `type` must not use Unicode escapes.
		has_esc := cur_has_escape(p)
  ensure_nxt(p)
		nxt := p.lexer.nxt.kind
		if nxt == .LBrace || nxt == .Mul {
			if has_esc { report_error_coded(p, .K3015_KeywordContainsEscape, "Keyword 'type' must not contain escaped characters") }
			decl.import_kind = .Type
			eat(p) // consume `type`
		} else if nxt == .From || can_be_binding_identifier(nxt) {
			// Could be `import type Foo from "m"` (type-only default) or
			// `import type from "m"` (default import of "type"). Only flag as
			// type-only when the identifier after `type` is NOT `from`.
			// Exception: `import type from from "m"` — the first `from` is
			// the binding name and `type` is the type-only keyword. Detect
			// via 3-token lookahead: if nxt="from" and nxt+1="from", it's
			// the type-only form. Matches OXC.
   ensure_nxt(p)
			nxt_val := p.lexer.source[p.lexer.nxt.start:p.lexer.nxt.end]
			if nxt_val != "from" {
				if has_esc { report_error_coded(p, .K3015_KeywordContainsEscape, "Keyword 'type' must not contain escaped characters") }
				decl.import_kind = .Type
				eat(p) // consume `type`
			} else {
				// nxt is "from" — check if the token AFTER that is also "from".
				snap_tf := lexer_snapshot(p)
				advance_token(p) // consume `type` → cur="from" (binding)
				advance_token(p) // consume "from" → cur=third token
				// `import type from from "m"` or `import type from = require(...)`
				third_is_from := p.cur_type == .From ||
				                 (p.cur_type == .Identifier && cur_value_eq(p, "from")) ||
				                 p.cur_type == .Assign
				lexer_restore(p, snap_tf)
				if third_is_from {
					if has_esc { report_error_coded(p, .K3015_KeywordContainsEscape, "Keyword 'type' must not contain escaped characters") }
					decl.import_kind = .Type
					eat(p) // consume `type`
				}
			}
		}
	}

	// TS `import X = ...` / `import type X = ...` (TSImportEqualsDeclaration).
	// Detect by `Identifier` followed by `=`. The `import type X = ...` form is
	// also legal (type-only import-equals).
	// Check for TS import-equals: `import X = ...`. Also handles
	// `import await = ...` (await as binding name in non-module).
	if allow_ts_mode(p) && (p.cur_type == .Identifier || p.cur_type == .Await ||
	   p.cur_type == .Yield || p.cur_type == .From) &&
	   p.lexer != nil {
		ensure_nxt(p)
		if p.lexer.nxt.kind == .Assign {
			return parse_ts_import_equals(p, start, decl.import_kind)
		}
	}

	// Past the TS-import-equals fork — this IS an ES ImportDeclaration.
	// TS1147 — ES module imports are not allowed inside namespace bodies
	// (only import-equals aliases are valid there). Exception: string-named
	// module bodies (`declare module "m" { ... }`) where ES imports define
	// the module's public API.
	if p.ctx.in_ts_namespace && allow_ts_mode(p) && !p.ctx.in_ts_module_block {
		report_error_coded_span(p, .K3022_ModuleSyntaxInScript, u32(start.start), u32(start.start), "Import declarations in a namespace cannot reference a module")
	}
	// Flag module syntax now so it survives any error recovery below.
	// (The save/restore at the top of this function ensures the flag
	// only takes effect outside a TS namespace body.)
	p.has_module_syntax = true
	p.module_pre_scan_done = true

	if is_token(p, .String) {
		// import "module"
		decl.source = parse_string_literal(p)
	} else if is_token(p, .LBrace) {
		// Named imports: import { x, y } from "module"
		eat(p) // consume {

		for !is_token(p, .RBrace) && !is_token(p, .EOF) {
			if decl.import_kind == .Type && allow_ts_mode(p) &&
			   p.cur_type == .Identifier && cur_value_eq(p, "type") {
				// `import type { type ... }` — distinguish `type` as the
				// imported NAME from `type` as an inline-type MODIFIER.
				// When followed by `as <ident>` or `,` or `}`, `type` is
				// the name being imported (valid). When followed by another
				// identifier (not `as`), `type` is a modifier (invalid in
				// type-only imports). Matches OXC.
    ensure_nxt(p)
				nxt_kind := p.lexer.nxt.kind
				type_is_modifier := nxt_kind != .As && nxt_kind != .Comma &&
				                    nxt_kind != .RBrace
				// `type as }` — `as` is not followed by identifier, so
				// `type` is a modifier on `as`. Check: `as` + non-ident.
				if nxt_kind == .As {
					snap_t := lexer_snapshot(p)
					advance_token(p) // consume `type`
					advance_token(p) // consume `as`
					after_as := p.cur_type
					lexer_restore(p, snap_t)
					if after_as != .Identifier && !can_be_binding_identifier(after_as) &&
					   after_as != .String {
						type_is_modifier = true  // `type as }` → modifier
					}
				}
				if type_is_modifier {
					report_error_coded(p, .K4010_TypeOnlyImportExportInvalid, "The 'type' modifier cannot be used in a type-only import")
				}
			}
			spec := parse_import_specifier(p)
			if spec != nil {
				append_import_spec(&decl.specifiers, spec, p.allocator)
			}

			if !match_token(p, .Comma) {
				break
			}
		}

		if !expect_token(p, .RBrace) {
			return nil
		}

		if !expect_token(p, .From) {
			return nil
		}

		if !is_token(p, .String) {
			report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected string literal module specifier")
		}
		decl.source = parse_string_literal(p)
	} else if is_token(p, .Mul) {
		// Namespace import: import * as name from "module". Spec.start must
		// cover the leading `*` (OXC parity), not just the `name`.
		star_loc := cur_loc(p)
		eat(p)
		if !expect_token(p, .As) {
			return nil
		}
		local := parse_identifier(p)
		// §16.2.2 — `await` is reserved as a binding name in module code.
		// Import declarations are module syntax, so `await` always forbidden.
		if local.name == "await" {
			report_error_coded_span(p, .K3010_AwaitYieldAsBindingName, u32(local.loc.start), u32(local.loc.start), "'await' is reserved as a binding name in module code")
		}
		// Strict-mode reserved word as namespace import binding.
		if p.ctx.strict_mode && is_strict_reserved_name(local.name) &&
		   !(allow_ts_mode(p) && (p.ctx.in_ambient || p.source_is_dts)) {
			msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", local.name)
			report_error_coded_span(p, .K3050_StrictModeReserved, u32(local.loc.start), u32(local.loc.start), msg)
		}
		spec := new_node(p, ImportNamespaceSpecifier)
		spec.loc = star_loc
		spec.local = BindingIdentifier{
			loc  = local.loc,
			name = local.name,
		}
		spec.loc.end = prev_end_offset(p)
		append_import_spec(&decl.specifiers, spec, p.allocator)

		if !expect_token(p, .From) {
			return nil
		}

		if !is_token(p, .String) {
			report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected string literal module specifier")
		}
		decl.source = parse_string_literal(p)
	} else if is_token(p, .Identifier) || can_be_binding_identifier(p.cur_type) {
		// Default import: import name from "module" or import name, { x } from "module"
		local := parse_identifier(p)
		// §16.2.2 — `await` is reserved as a binding name in module code.
		if local.name == "await" {
			report_error_coded_span(p, .K3010_AwaitYieldAsBindingName, u32(local.loc.start), u32(local.loc.start), "'await' is reserved as a binding name in module code")
		}
		// Strict-mode reserved word as default import binding.
		if p.ctx.strict_mode && is_strict_reserved_name(local.name) &&
		   !(allow_ts_mode(p) && (p.ctx.in_ambient || p.source_is_dts)) {
			msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", local.name)
			report_error_coded_span(p, .K3050_StrictModeReserved, u32(local.loc.start), u32(local.loc.start), msg)
		}
		spec := new_node(p, ImportDefaultSpecifier)
		spec.loc = local.loc
		spec.local = BindingIdentifier{
			loc  = local.loc,
			name = local.name,
		}
		spec.loc.end = prev_end_offset(p)
		append_import_spec(&decl.specifiers, spec, p.allocator)

		// Check for comma followed by named imports
		if match_token(p, .Comma) {
			if decl.import_kind == .Type {
				report_error_coded(p, .K4010_TypeOnlyImportExportInvalid, "A type-only import cannot combine default and named bindings")
			}
			if is_token(p, .From) {
				report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected import specifier after comma")
			} else if is_token(p, .LBrace) {
				eat(p) // consume {

				for !is_token(p, .RBrace) && !is_token(p, .EOF) {
					if decl.import_kind == .Type && allow_ts_mode(p) &&
					   p.cur_type == .Identifier && cur_value_eq(p, "type") {
						// Same disambiguation as the primary named-import loop above.
      ensure_nxt(p)
						nxt_k := p.lexer.nxt.kind
						is_mod := nxt_k != .As && nxt_k != .Comma && nxt_k != .RBrace
						if nxt_k == .As {
							snap_c := lexer_snapshot(p)
							advance_token(p); advance_token(p)
							a_t := p.cur_type
							lexer_restore(p, snap_c)
							if a_t != .Identifier && !can_be_binding_identifier(a_t) && a_t != .String {
								is_mod = true
							}
						}
						if is_mod {
							report_error_coded(p, .K4010_TypeOnlyImportExportInvalid, "The 'type' modifier cannot be used in a type-only import")
						}
					}
					spec2 := parse_import_specifier(p)
					if spec2 != nil {
						append_import_spec(&decl.specifiers, spec2, p.allocator)
					}

					if !match_token(p, .Comma) {
						break
					}
				}

				if !expect_token(p, .RBrace) {
					return nil
				}
			} else if is_token(p, .Mul) {
				// import name, * as namespace from "module"
				eat(p)
				if !expect_token(p, .As) {
					return nil
				}
				local2 := parse_identifier(p)
				ns_spec := new_node(p, ImportNamespaceSpecifier)
				ns_spec.loc = local2.loc
				ns_spec.local = BindingIdentifier{
					loc  = local2.loc,
					name = local2.name,
				}
				ns_spec.loc.end = prev_end_offset(p)
				append_import_spec(&decl.specifiers, ns_spec, p.allocator)
			}
		}

		if !expect_token(p, .From) {
			return nil
		}

		if !is_token(p, .String) {
			report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected string literal module specifier")
		}
		decl.source = parse_string_literal(p)
	} else if allow_ts_mode(p) {
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected import source or specifier")
	}

	decl.attributes = parse_import_attributes(p)

	match_semicolon_or_asi(p)

	// ECMA-262 §16.2.2 - BoundNames of ImportClause must not contain any
	// duplicate entries. All specifier kinds (ImportSpecifier,
	// ImportDefaultSpecifier, ImportNamespaceSpecifier) contribute their
	// *local* name (after `as`, for the default / namespace case it's
	// just the bound identifier). Count is small in practice - the O(n2)
	// scan is faster than setting up a map.
	for i := 0; i < len(decl.specifiers); i += 1 {
		li := import_spec_local_name(decl.specifiers[i])
		if li == "" { continue }
		for j := 0; j < i; j += 1 {
			lj := import_spec_local_name(decl.specifiers[j])
			if li == lj {
				msg := fmt.tprintf("Duplicate import binding '%s'", li)
				report_error_coded(p, .K3037_DuplicateIdentifier, msg)
				break
			}
		}
	}

	decl.loc.end = prev_end_offset(p)

	// Collect ESM static import record
	p.has_module_syntax = true
	if len(decl.specifiers) > 0 {
		esm_import := ESMStaticImport{
			start = decl.loc.start,
			end = decl.loc.end,
			moduleRequest = {
				value = decl.source.value,
				start = decl.source.loc.start,
				end = decl.source.loc.end,
			},
			entries = make([dynamic]ESMStaticImportEntry, 0, len(decl.specifiers), p.allocator),
		}
		for spec in decl.specifiers {
			entry := collect_esm_import_entry(spec)
			bump_append(&esm_import.entries, entry)
		}
		bump_append(&p.staticImports, esm_import)
	}

	// Allocate Statement union and store the pointer
	stmt := new_node(p, Statement)
	stmt^ = (^ImportDeclaration)(decl)
	return stmt
}

// TS `import X = ModuleReference` / `import X = require("m")`.
// Caller (parse_import_declaration) has already consumed `import` and any
// optional `type` modifier; `start` points at `import`'s position and
// `import_kind` carries the type-only flag. Current token is the binding
// Identifier (verified by caller; `next` is `.Assign`).
// Module reference shapes (TypeScript 5 grammar):
//   * `Identifier`              - simple alias               (id)
//   * `Identifier (`.` Identifier)+` - qualified entity name (member chain)
//   * `require ( StringLiteral )` - external module reference
// We store the entity-name forms as a plain ^Expression (Identifier or
// MemberExpression chain) and let the emitter fold member chains into the
// ESTree TSQualifiedName shape - same trick parse_ts_module_declaration
// uses for `namespace A.B.C { ... }` ids.
parse_ts_import_equals :: proc(p: ^Parser, start: Loc, import_kind: ImportExportKind) -> ^Statement {
	decl := new_node(p, TSImportEqualsDeclaration)
	decl.loc = start
	decl.import_kind = import_kind

	// TS import-equals is module-level syntax. In explicit script mode,
	// report an error (matches Babel/OXC behavior).
	if st, have := p.force_source_type.(SourceType); have && st == .Script {
		report_error_coded_span(p, .K3022_ModuleSyntaxInScript, u32(start.start), u32(start.start), "'import' and 'export' may appear only with 'sourceType: module'")
	}

	// TS1392: `import type X = Y.Z` is invalid (namespace alias can't
	// use `import type`). `import type X = require("...")` IS valid.
	// We check the require case after parsing the module reference.
	// For now, flag it; we'll suppress below if it's require().
	type_alias_error := import_kind == .Type

	// Binding identifier.
	id_loc := cur_loc(p)
	id_name := cur_value(p)
	decl.id = Identifier{loc = id_loc, name = id_name}
	// Strict-mode reserved words as import-equals binding name.
	check_strict_ts_decl_name(p, id_name, id_loc)
	// `await` as binding in import-equals is forbidden in module code.
	if p.cur_type == .Await || id_name == "await" {
		await_reserved := await_is_reserved_here(p)
		if !await_reserved {
			if st, have := p.force_source_type.(SourceType); have && st == .Module {
				await_reserved = true
			} else if p.in_module_top_level || p.has_module_syntax {
				await_reserved = true
			}
		}
		if await_reserved {
			report_error_coded(p, .K3010_AwaitYieldAsBindingName,
			"'await' cannot be used as an identifier in module code")
		}
	}
	eat(p)  // consume id

	// `=`. The caller's `next == .Assign` check guarantees we hit it; using
	// expect_token still keeps the diagnostic stable if the lookahead changes.
	if !expect_token(p, .Assign) {
		return nil
	}

	// Module reference. `require` is a contextual keyword here - lex as
	// Identifier, distinguish by the token value + a `(` follow-up.
	// Legacy TS `import X = module("mod")` form (TS 0.x). Not supported
	// by modern TypeScript or OXC. Reject with a clear error.
	if p.cur_type == .Identifier && cur_value_eq(p, "module") && p.lexer != nil {
		ensure_nxt(p)
	}
	if p.cur_type == .Identifier && cur_value_eq(p, "module") &&
	   p.lexer != nil && p.lexer.nxt.kind == .LParen {
		report_error_coded(p, .K2040_UnexpectedToken, "'module(...)' in import-equals is not supported; use 'require(...)' instead")
		// Consume `module("...")` for recovery.
		eat(p) // module
		eat(p) // (
		if is_token(p, .String) { eat(p) } // "..."
		if is_token(p, .RParen) { eat(p) } // )
		match_semicolon_or_asi(p)
		decl.loc.end = prev_end_offset(p)
		return statement_from(p, decl)
	}
	if p.cur_type == .Identifier && cur_value_eq(p, "require") && p.lexer != nil {
		ensure_nxt(p)
	}
	if p.cur_type == .Identifier && cur_value_eq(p, "require") &&
	   p.lexer != nil && p.lexer.nxt.kind == .LParen {
		req_start := cur_loc(p)
		eat(p)  // consume `require`
		if !expect_token(p, .LParen) { return nil }
		if !is_token(p, .String) {
			report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected string literal in require() module reference")
			return nil
		}
		str := parse_string_literal(p)
		str_ptr := new_node(p, StringLiteral)
		str_ptr^ = str
		if !expect_token(p, .RParen) { return nil }
		ext := new_node(p, TSExternalModuleReference)
		ext.loc = req_start
		ext.expression = str_ptr
		ext.loc.end = prev_end_offset(p)
		decl.module_reference = ext
	} else {
		// Entity-name chain: parse a primary identifier, then any `.id` tail.
		// Mirrors parse_member_expr's non-computed dot path but kept inline so
		// we don't accidentally accept `[expr]`, calls, optional chains, etc.
		if p.cur_type != .Identifier {
			report_error_coded(p, .K2021_ExpectedIdentifier, "Expected identifier in import-equals module reference")
			return nil
		}
		head_loc := cur_loc(p)
		head, head_e := new_expr(p, Identifier)
		head.loc = head_loc
		head.name = cur_value(p)
		eat(p)
		current_expr := head_e
		for is_token(p, .Dot) {
			eat(p)  // consume `.`
			if p.cur_type != .Identifier && !is_keyword_usable_as_property_name(p.cur_type) &&
			   p.cur_type != .Await && p.cur_type != .Yield {
				report_error_coded(p, .K2021_ExpectedIdentifier, "Expected identifier after '.' in import-equals module reference")
				break
			}
			rhs_loc := cur_loc(p)
			rhs, rhs_e := new_expr(p, Identifier)
			rhs.loc = rhs_loc
			rhs.name = cur_value(p)
			eat(p)
			mem := new_node(p, MemberExpression)
			mem.loc = head_loc
			mem.object = current_expr
			rhs_expr := rhs_e
			mem.property = rhs_expr
			mem.computed = false
			mem.optional = false
			mem.loc.end = prev_end_offset(p)
			current_expr = expression_from(p, mem)
		}
		decl.module_reference = current_expr
	}

	// TS1392: emit now that we know the module reference type.
	// `import type X = require("...")` is valid; namespace alias is not.
	if type_alias_error {
		if _, is_require := decl.module_reference.(^TSExternalModuleReference); !is_require {
			report_error_coded_span(p, .K4010_TypeOnlyImportExportInvalid, u32(start.start), u32(start.start), "An import alias can not use 'import type'")
		}
	}

	match_semicolon_or_asi(p)
	decl.loc.end = prev_end_offset(p)

	stmt := new_node(p, Statement)
	stmt^ = (^TSImportEqualsDeclaration)(decl)
	return stmt
}

parse_import_specifier :: proc(p: ^Parser) -> ^ImportSpecifier {
	start := cur_loc(p)

	// TS per-specifier type modifier: `import { type x } from "m"`,
	// `import { type x as y } from "m"`, `import { type "a" as b } from "m"`.
	// Detect by `Identifier("type")` followed by something that can start
	// an imported-name (Identifier / String / kw-as-name) and is NOT `as`
	// or `,` / `}` (those would mean "type" is the imported name itself).
	// Closes the bulk of the 12-file "Expected }, got identifier" cluster
	// (typescript fixtures: arbitraryModuleNamespaceIdentifiers,
	// exportSpecifiers_js, etc.).
	if allow_ts_mode(p) && p.cur_type == .Identifier && cur_value_eq(p, "type") {
		ensure_nxt(p)
		if cur_has_escape(p) && p.lexer.nxt.kind == .As {
			report_error_coded(p, .K3015_KeywordContainsEscape, "Keyword 'type' must not contain escaped characters")
		}
  ensure_nxt(p)
		nxt := p.lexer.nxt.kind
		nxt_is_name := nxt == .Identifier || nxt == .String ||
		               is_keyword_usable_as_property_name(nxt)
		if nxt_is_name && nxt != .As {
			eat(p) // consume `type`
		} else if nxt == .As {
			// `import { type as }` / `import { type as as as }` - 4-token
			// lookahead (mirrors parse_export_named's identical pattern).
			snap := lexer_snapshot(p)
			eat(p) // consume `type`
			eat(p) // consume first `as`
			after := p.cur_type
			consume_type := false
			if after == .Comma || after == .RBrace || after == .From {
				consume_type = true
			} else if after == .As {
				// `type as as X` - peek past the second `as`.
				eat(p)
				after_as := p.cur_type
				if after_as == .Identifier || after_as == .String ||
				   is_keyword_usable_as_property_name(after_as) {
					consume_type = true
				}
			}
			lexer_restore(p, snap)
			if consume_type {
				eat(p) // commit: consume `type` modifier
			}
		}
	}

	imported: Identifier
	is_string_import := false
	if is_token(p, .String) {
		// `import { "str" as local } from "m"` - ModuleExportName string form.
		current := snap_current(p)
		val := current.literal.(string) or_else ""
		if string_has_unpaired_surrogate(val) {
			report_error_coded(p, .K3020_ImportExportNameOrBinding, "Import name string must not contain unpaired surrogates")
		}
		imported = Identifier{loc = loc_from_token(&current), name = val}
		is_string_import = true
		eat(p)
	} else if is_token(p, .Number) || is_token(p, .BigInt) {
		// Numeric / BigInt literals can't be ImportedBinding names.
		// `import { 0n as foo }` is a SyntaxError.
		report_error_coded(p, .K3020_ImportExportNameOrBinding, "Numeric or bigint literal cannot be an import name")
		current := snap_current(p)
		imported = Identifier{loc = loc_from_token(&current), name = current.value}
		eat(p)
	} else {
		imported = parse_identifier_name(p)
	}

	local := imported
	// When there's no alias, the imported name IS the local binding.
	// Check `await` in module context. `import` itself is module syntax,
	// so any import declaration implies module context regardless of
	// auto-detection state.
	if !is_string_import && !is_token(p, .As) {
		if imported.name == "await" {
			report_error_coded_span(p, .K3010_AwaitYieldAsBindingName, u32(imported.loc.start), u32(imported.loc.start), "'await' is reserved as a binding name in module code")
		} else if imported.name == "yield" {
			report_error_coded_span(p, .K3050_StrictModeReserved, u32(imported.loc.start), u32(imported.loc.start), "'yield' is reserved as a binding name in strict mode")
		}
	}
	if match_token(p, .As) {
		if is_token(p, .String) {
			report_error_coded(p, .K3020_ImportExportNameOrBinding, "Import binding name cannot be a string literal")
		}
		// Numeric / BigInt literals can't be ImportedBinding names.
		if is_token(p, .Number) || is_token(p, .BigInt) {
			report_error_coded(p, .K3020_ImportExportNameOrBinding, "Numeric or bigint literal cannot be an import binding name")
			current := snap_current(p)
			local = Identifier{loc = loc_from_token(&current), name = current.value}
			eat(p)
			spec := new_node(p, ImportSpecifier)
			spec.loc = start
			spec.imported = IdentifierName{loc = imported.loc, name = imported.name}
			spec.local = BindingIdentifier{loc = local.loc, name = local.name}
			spec.loc.end = prev_end_offset(p)
			return spec
		}
		// `await` / `yield` as the local binding name in module code
		// (which is always strict) is reserved.
		local_is_await := p.cur_type == .Await ||
		                  (p.cur_type == .Identifier && cur_value_eq(p, "await"))
		local_is_yield := p.cur_type == .Yield ||
		                  (p.cur_type == .Identifier && cur_value_eq(p, "yield"))
		local = parse_identifier(p)
		if local_is_await {
			report_error_coded_span(p, .K3010_AwaitYieldAsBindingName, u32(local.loc.start), u32(local.loc.start), "'await' is reserved as a binding name in module code")
		} else if local_is_yield {
			report_error_coded_span(p, .K3050_StrictModeReserved, u32(local.loc.start), u32(local.loc.start), "'yield' is reserved as a binding name in strict mode")
		}
	} else if is_string_import {
		// String import names MUST have `as local`.
		report_error_coded(p, .K2070_RequiredFormOrBinding, "String import names require 'as' binding")
	}

	spec := new_node(p, ImportSpecifier)
	spec.loc = start
	spec.imported = IdentifierName{
		loc  = imported.loc,
		name = imported.name,
	}
	spec.local = BindingIdentifier{
		loc  = local.loc,
		name = local.name,
	}
	spec.loc.end = prev_end_offset(p)

	// §16.2.2 — ImportedBinding `eval` / `arguments` early error.
	// Module code is always strict, so eval/arguments are forbidden.
	if is_eval_or_arguments(local.name) {
		report_error_coded(p, .K3020_ImportExportNameOrBinding,
			fmt.tprintf("'%s' cannot be used as an import binding name", local.name))
	}
	// Strict-mode reserved words as import binding name. Module code is
	// always strict; explicit strict-mode script imports are also covered.
	if p.ctx.strict_mode && is_strict_reserved_name(local.name) &&
	   !(allow_ts_mode(p) && (p.ctx.in_ambient || p.source_is_dts)) {
		msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", local.name)
		report_error_coded_span(p, .K3050_StrictModeReserved, u32(local.loc.start), u32(local.loc.start), msg)
	}
	// Always-reserved word as import binding stays a parser-side
	// structural error (`import { default }` etc).
	if is_always_reserved_word_name(local.name) {
		msg := fmt.tprintf("'%s' is a reserved word and cannot be used as an import binding", local.name)
		report_error_coded(p, .K3020_ImportExportNameOrBinding, msg)
	}
	// §16.2.2 - When no `as` clause, the ImportedBinding is the same
	// identifier as the ModuleExportName.  Reserved words are valid
	// ModuleExportNames (`import { default as x }`) but NOT valid
	// BindingIdentifiers (`import { default }`).  The check only fires
	// when local == imported (no `as`).
	if local.loc.start == imported.loc.start && !is_string_import {
		if is_always_reserved_word_name(local.name) {
			msg := fmt.tprintf("'%s' is a reserved word and cannot be used as an import binding", local.name)
			report_error_coded(p, .K3020_ImportExportNameOrBinding, msg)
		}
	}

	return spec
}

parse_export_declaration :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume export

	// See parse_import_declaration: namespace-body exports do not
	// classify the file as a module. Save/restore so downstream
	// `p.has_module_syntax = true` writes can't leak out.
	restore_module_syntax := p.ctx.in_ts_namespace
	prev_module_syntax := p.has_module_syntax
	prev_pre_scan_done := p.module_pre_scan_done
	defer if restore_module_syntax {
		p.has_module_syntax    = prev_module_syntax
		p.module_pre_scan_done = prev_pre_scan_done
	}

	// §16.2 "export only valid in module code" early error: enforced by
	// the semantic checker (ck_check_import_export_position).

	if is_token(p, .Export) {
		report_error_coded(p, .K4031_DuplicateModifier, "'export' modifier already seen")
		eat(p)
	}

	if match_token(p, .Default) {
		return parse_export_default(p, start)
	}

	if match_token(p, .Mul) {
		// TS1233 — `export * from "m"` inside a namespace body is invalid.
		if p.ctx.in_ts_namespace && allow_ts_mode(p) && !p.ctx.in_ts_module_block {
			report_error_coded_span(p, .K3022_ModuleSyntaxInScript, u32(start.start), u32(start.start), "Export declarations are not permitted in a namespace")
		}
		return parse_export_all(p, start, .Value)
	}

	if is_token(p, .LBrace) {
		// TS1233 — `export { ... }` and `export { ... } from "m"` inside a
		// non-ambient namespace body are invalid. Only `export <declaration>` is
		// allowed. In `declare namespace`, `export { x }` IS valid (re-export of
		// internal names). Exception: `export { x } from "m"` is always invalid
		// in any namespace (handled after parsing by checking .source).
		ns_export_named_start := start
		ns_check_export_named := p.ctx.in_ts_namespace && allow_ts_mode(p) && !p.ctx.in_ts_module_block
		result_named := parse_export_named(p, start, .Value)
		if ns_check_export_named && result_named != nil {
			// Check: if it has a `from` source OR we're in a non-ambient namespace.
			has_from := false
			if en, ok := result_named^.(^ExportNamedDeclaration); ok && en != nil {
				has_from = en.source != nil
			}
			if has_from {
				report_error_coded_span(p, .K3022_ModuleSyntaxInScript, u32(ns_export_named_start.start), u32(ns_export_named_start.start), "Export declarations are not permitted in a namespace")
			} else if !p.ctx.in_ambient {
				report_error_coded_span(p, .K3022_ModuleSyntaxInScript, u32(ns_export_named_start.start), u32(ns_export_named_start.start), "Export declarations are not permitted in a namespace")
			}
		}
		return result_named
	}

	// `export = <expr>;` - TS legacy CommonJS-style export assignment.
	// `=` here is NOT a binding-init; it's a sentinel that introduces a
	// single expression-form export. The trailing semicolon (or ASI) is
	// part of the declaration; the span includes it. TS-only syntax.
	if is_token(p, .Assign) {
		if !allow_ts_mode(p) {
			report_error_coded(p, .K4010_TypeOnlyImportExportInvalid,
				"'export =' is only allowed in TypeScript files")
		}
		// In explicit script mode, export-equals is module-level syntax.
		if st, have := p.force_source_type.(SourceType); have && st == .Script {
			report_error_coded_span(p, .K3022_ModuleSyntaxInScript, u32(start.start), u32(start.start), "'import' and 'export' may appear only with 'sourceType: module'")
		}
		// TS1203 — export assignment inside a namespace body.
		if p.ctx.in_ts_namespace && allow_ts_mode(p) && !p.ctx.in_ts_module_block {
			report_error_coded_span(p, .K3022_ModuleSyntaxInScript, u32(start.start), u32(start.start), "An export assignment cannot be used in a namespace")
		}
		eat(p) // consume `=`
		expr := parse_assignment_expression(p)
		if expr == nil {
			report_error_coded(p, .K2020_ExpectedExpression, "Expected expression after 'export ='")
		}
		if !match_semicolon_or_asi(p) {
			report_error_coded(p, .K2010_ExpectedSemicolon, "Expected semicolon after export assignment")
		}
		decl := new_node(p, TSExportAssignment)
		decl.loc = start; decl.expression = expr
		decl.loc.end = prev_end_offset(p)
		stmt := new_node(p, Statement); stmt^ = decl; return stmt
	}

	// Past the TS-export-assign fork — this IS an ES ExportDeclaration.
	// Flag module syntax now so error recovery can't lose it. (The
	// save/restore at the top of this function ensures the flag only
	// takes effect outside a TS namespace body — see fixture
	// spec/typescript/015_namespace_module which exercises the case.)
	p.has_module_syntax = true
	p.module_pre_scan_done = true

	// `export as namespace <Identifier>;` - TS UMD-style declaration. `as`
	// here is a contextual keyword; it lexes as a regular identifier in JS
	// mode but parse_export_declaration is only entered for `export`, so
	// the identifier `as` followed by identifier `namespace` is the cue.
	if p.cur_type == .As && allow_ts_mode(p) {
		nxt := peek_token(p)
		if nxt.type == .Identifier && nxt.value == "namespace" {
			// TS1235 — `export as namespace` is only valid at top level.
			if p.ctx.in_ts_namespace && !p.ctx.in_ts_module_block {
				report_error_coded_span(p, .K3022_ModuleSyntaxInScript, u32(start.start), u32(start.start), "Global module exports may only appear at top level")
			}
			eat(p) // consume `as`
			eat(p) // consume `namespace`
			cur := snap_current(p)
			id := Identifier{loc = loc_from_token(&cur), name = cur.value}
			eat(p) // consume identifier
			if !match_semicolon_or_asi(p) {
				report_error_coded(p, .K2010_ExpectedSemicolon, "Expected semicolon after 'export as namespace'")
			}
			decl := new_node(p, TSNamespaceExportDeclaration)
			decl.loc = start; decl.id = id
			decl.loc.end = prev_end_offset(p)
			stmt := new_node(p, Statement); stmt^ = decl; return stmt
		}
	}

	// `export type ...` - TS type-only export. Three forms:
	//   export type { A, B };          - named, no source
	//   export type { A } from "m";    - named, with source
	//   export type * from "m";        - export-all
	//   export type * as N from "m";   - export-all with namespace alias
	//   export type X = ...;           - type alias (handled by fall-through)
	//   export type X from ...;        - not valid; fall through to declaration parse
	// Detect the `{` / `*` lookahead and dispatch with export_kind=.Type.
	// `export type Identifier =` falls through to the declaration path,
	// which already handles type aliases via parse_statement_or_declaration.
	if p.cur_type == .Identifier && cur_value_eq(p, "type") && allow_ts_mode(p) {
		has_esc := cur_has_escape(p)
		nxt := peek_token(p)
		if nxt.type == .LBrace {
			if has_esc { report_error_coded(p, .K3015_KeywordContainsEscape, "Keyword 'type' must not contain escaped characters") }
			if p.ctx.in_ts_namespace && !p.ctx.in_ts_module_block {
				report_error_coded_span(p, .K3022_ModuleSyntaxInScript, u32(start.start), u32(start.start), "Export declarations are not permitted in a namespace")
			}
			eat(p) // consume `type`
			return parse_export_named(p, start, .Type)
		}
		if nxt.type == .Mul {
			if has_esc { report_error_coded(p, .K3015_KeywordContainsEscape, "Keyword 'type' must not contain escaped characters") }
			if p.ctx.in_ts_namespace && !p.ctx.in_ts_module_block {
				report_error_coded_span(p, .K3022_ModuleSyntaxInScript, u32(start.start), u32(start.start), "Export declarations are not permitted in a namespace")
			}
			eat(p) // consume `type`
			eat(p) // consume `*`
			return parse_export_all(p, start, .Type)
		}
	}

	// TS class-modifier keywords (`public`, `private`, `protected`, `static`)
	// can appear before `import` in legacy TS export-import forms like
	// `export public import a = x.c;`. They are no-ops syntactically.
	// Skip them so the downstream declaration parse sees `import`.
	if allow_ts_mode(p) {
		for (p.cur_type == .Identifier || p.cur_type == .Public || p.cur_type == .Private ||
		     p.cur_type == .Protected || p.cur_type == .Static) &&
		    (cur_value_eq(p, "public") || cur_value_eq(p, "private") ||
		     cur_value_eq(p, "protected") || cur_value_eq(p, "static")) &&
		    is_next_token(p, .Import) {
			eat(p)
		}
	}

	// After `export`, only `*`, `default`, `{`, or a declaration keyword
	// is valid. A bare string literal is always a SyntaxError.
	if is_token(p, .String) {
		report_error_coded(p, .K2040_UnexpectedToken, "Unexpected string literal after 'export'")
	}

	// Export declaration. parse_statement_or_declaration returns a ^Statement
	// union wrapping the underlying declaration variant. The previous code
	// cast that ^Statement pointer directly to ^Declaration, reinterpreting
	// the Statement union's tag bytes as a Declaration tag - different
	// ordinal spaces (Declaration: 7 variants, Statement: 25), so downstream
	// dispatch hit the wrong variant or "Unknown". Same UB class as Bug H.
	// Fix: allocate a fresh Declaration union and re-assign the inner variant
	// pointer so Odin computes the correct ^Declaration tag at assignment.
	// Mirrors parse_export_default's handling of ^ClassDeclaration below.
	decl := parse_statement_or_declaration(p)
	if decl == nil {
		return nil
	}

	decl_union := new_node(p, Declaration)
	export_kind := ImportExportKind.Value
	#partial switch v in decl^ {
	case ^FunctionDeclaration:
		decl_union^ = v
		// `declare` on the inner declaration marks it ambient (no body)
		// but the export itself stays `"value"` per ESTree — only an
		// explicit `export type X` modifier sets exportKind to "type".
	case ^VariableDeclaration:
		decl_union^ = v
		// §Explicit Resource Management - `export using x = ...` and
		// `export await using x = ...` are SyntaxErrors. Using
		// declarations must use the named-export form: `export { x }`.
		if v != nil && (v.kind == .Using || v.kind == .AwaitUsing) {
			report_error_coded(p, .K3021_ExportDefaultRestrictions, "Using declarations cannot be exported directly")
		}
	case ^ClassDeclaration:
		decl_union^ = v
		// §15.7.1 — named exports require a class name.
		// `export class {}` is invalid; must use `export default class {}`.
		if v != nil {
			if _, has_id := v.id.?; !has_id {
				report_error_coded_span(p, .K2070_RequiredFormOrBinding, u32(v.loc.start), u32(v.loc.start), "A class declaration without the 'default' modifier must have a name.")
			}
		}
	case ^ImportDeclaration:
		// `export import X from "..."` is invalid — only the TS
		// import-equals form `export import X = ...` is valid.
		report_error_coded(p, .K2040_UnexpectedToken, "Unexpected 'import' after 'export'. Only 'export import X = ...' (TypeScript) is valid here.")
		return nil
	case ^ExportNamedDeclaration:     decl_union^ = v
	case ^ExportDefaultDeclaration:   decl_union^ = v
	case ^ExportAllDeclaration:       decl_union^ = v
	case ^TSInterfaceDeclaration:
		decl_union^ = v
		export_kind = .Type
	case ^TSTypeAliasDeclaration:
		decl_union^ = v
		export_kind = .Type
	case ^TSEnumDeclaration:
		decl_union^ = v
		// `declare` doesn't lift the export to `type`; only an explicit
		// `export type` modifier does.
	case ^TSModuleDeclaration:
		decl_union^ = v
		// Same: `export declare namespace N {}` is a value-kind export.
	case ^TSImportEqualsDeclaration:  decl_union^ = v
	case:
		// After `export` (non-default), only declarations are valid.
		// Expression statements, empty statements, and other non-declaration
		// statement types are SyntaxErrors. `export default <expr>` is handled
		// by parse_export_default above.
		report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token")
		return nil
	}

	export_decl := new_node(p, ExportNamedDeclaration)
	export_decl.loc = start
	export_decl.declaration = decl_union
	export_decl.export_kind = export_kind
	export_decl.loc.end = prev_end_offset(p)

	// Allocate Statement union and store the pointer
	stmt := new_node(p, Statement)
	stmt^ = (^ExportNamedDeclaration)(export_decl)
	return stmt
}

parse_export_default :: proc(p: ^Parser, start: Loc) -> ^Statement {
	// TS1319 — `export default` inside a namespace is invalid.
	// Exception: inside string-named module declarations (`declare module "m" { ... }`).
	if p.ctx.in_ts_namespace && allow_ts_mode(p) && !p.ctx.in_ts_module_block {
		report_error_coded_span(p, .K3022_ModuleSyntaxInScript, u32(start.start), u32(start.start), "Export declarations are not permitted in a namespace")
	}

	// ExportDefaultDef is union { ^Declaration, ^Expression }. The old code
	// did transmute(^ExportDefaultDef)decl on a ^Statement union, which
	// reinterpreted 16 bytes of Statement-union layout as a 16-byte
	// ExportDefaultDef union - UB that happened to not crash only because
	// the union tag slots sometimes aligned. Same class as the FunctionExpression
	// and TryStatement UB fixes.
	def := new_node(p, ExportDefaultDef)

	if is_token(p, .Function) || (is_token(p, .Async) && is_next_token(p, .Function)) {
		// export default [async] function() {}  - parsed as expression form.
		// parse_function_declaration(is_expr=true) returns a ^Statement union
		// wrapping a ^ExpressionStatement whose .expression is the FunctionExpression.
		p.in_export_default = true
		fn_stmt := parse_function_declaration(p, true)
		p.in_export_default = false
		if fn_stmt != nil {
			if expr_stmt, ok := fn_stmt^.(^ExpressionStatement); ok {
				def^ = expr_stmt.expression
			}
		}
		// §16.2.3 - `export default function() {}` is the
		// HoistableDeclaration form, NOT an AssignmentExpression. So the
		// FunctionDeclaration ends at `}`; LHS-tail tokens that would
		// extend it as an expression (`()` call, `[x]` index, `.x`
		// member, `` `tag` ``, `=>` arrow, postfix `++`/`--`) make the
		// production fail. Whitespace / `;` / new statement starts (e.g.
		// `if`) are fine - the function-decl `}` already terminates the
		// declaration. Test262: language/module-code/parse-err-invoke-
		// anon-{fun,gen}-decl.js (`function() {}()`).
		// Only flag a continuation token as an error if it's on the
		// SAME line. A `(`, `[`, etc. on the NEXT line is a new
		// statement (ASI applies at the declaration boundary), not a
		// postfix extension of the function expression.
		if !cur_has_newline(p) {
			#partial switch p.cur_type {
			case .LParen, .LBracket, .Dot, .OptionalChain,
			     .Template, .TemplateHead, .Arrow,
			     .PlusPlus, .MinusMinus:
				report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token after 'export default function' declaration")
			}
		}
	} else if is_token(p, .Class) ||
	          is_token(p, .At) ||
	          (is_token(p, .Abstract) && is_next_token(p, .Class) && (p.lexer.nxt.flags & FLAG_NEW_LINE) == 0) {
		// `export default class {}` / `export default @dec class {}`
		// / `export default @dec abstract class {}`.
		cls_stmt := parse_statement_or_declaration(p)
		if cls_stmt != nil {
			if cls_decl, ok := cls_stmt^.(^ClassDeclaration); ok {
				decl_union := new_node(p, Declaration)
				decl_union^ = cls_decl
				def^ = decl_union
			}
		}
	} else if is_token(p, .Abstract) && is_next_token(p, .At) {
		// `export default abstract @dec class C {}` is INVALID. Decorators
		// must come before `abstract`, not after.
		report_error_coded(p, .K4033_DecoratorOrder, "Decorators must precede the 'abstract' modifier on a class declaration")
		cls_stmt := parse_statement_or_declaration(p)
		if cls_stmt != nil {
			if cls_decl, ok := cls_stmt^.(^ClassDeclaration); ok {
				decl_union := new_node(p, Declaration)
				decl_union^ = cls_decl
				def^ = decl_union
			}
		}
	} else if p.cur_type == .Identifier && cur_value_eq(p, "interface") &&
	          allow_ts_mode(p) {
		// `export default interface X { ... }` - TS-only form.
		// `export default interface {}` - anonymous interface is rejected.
  ensure_nxt(p)
		if !is_next_token(p, .Identifier) && !is_keyword_usable_as_property_name(p.lexer.nxt.kind) {
			report_error_coded(p, .K4051_TSDeclarationStructure, "Interface declaration must have a name")
		}
		iface_stmt := parse_ts_interface_declaration(p)
		if iface_stmt != nil {
			if iface, ok := iface_stmt^.(^TSInterfaceDeclaration); ok {
				decl_union := new_node(p, Declaration)
				decl_union^ = iface
				def^ = decl_union
			}
		}
	} else {
		// §16.2.3 ExportDeclaration: `export default` accepts only
		// AssignmentExpression, FunctionDeclaration, or ClassDeclaration.
		// LexicalDeclaration (`const`, `let`) and VariableStatement (`var`)
		// are NOT allowed after `export default`.
		if p.cur_type == .Const || p.cur_type == .Var ||
		   (p.cur_type == .Let && !cur_has_newline(p)) {
			report_error_coded(p, .K3021_ExportDefaultRestrictions, "'export default' cannot be followed by a variable declaration")
		}
		// `using` / `await using` may also appear as a plain expression
		// here — `using` is a contextual keyword, so `export default using;`
		// and `export default await using;` are valid expression forms
		// where `using` is just an Identifier. Use the same 3-token
		// lookahead helper as for-statement init parsing to distinguish
		// declaration form from expression form, instead of guessing from
		// the immediate next token only. Mirrors babel + OXC.
		if is_token(p, .Using) && using_starts_decl(p) {
			report_error_coded(p, .K3021_ExportDefaultRestrictions, "'export default' cannot be followed by a using declaration")
		}
		ensure_nxt(p)
		if is_token(p, .Await) && p.lexer.nxt.kind == .Using &&
		   (p.lexer.nxt.flags & FLAG_NEW_LINE) == 0 &&
		   await_using_starts_decl(p) {
			report_error_coded(p, .K3021_ExportDefaultRestrictions, "'export default' cannot be followed by a using declaration")
		}
		expr := parse_assignment_expression(p)
		if expr != nil {
			def^ = expr
		}
		if !match_semicolon_or_asi(p) && !cur_has_newline(p) {
			// `export default null null;` - second literal follows without separator.
			#partial switch p.cur_type {
			case .Null, .True, .False, .Number, .String, .BigInt:
				report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token following export default expression")
			}
		}
	}

	decl := new_node(p, ExportDefaultDeclaration)
	decl.loc = start
	decl.declaration = def
	decl.loc.end = prev_end_offset(p)

	// Collect ESM static export record for export default
	p.has_module_syntax = true
	esm_export := ESMStaticExport{
		start = decl.loc.start,
		end = decl.loc.end,
		entries = make([dynamic]ESMStaticExportEntry, 1, p.allocator),
	}
	esm_export.entries[0] = ESMStaticExportEntry{
		exportName = ESMExportNameEntry{
			kind = .Default,
			name = "default",
			start = start.start,
			end = start.end,
		},
		localName = ESMExportNameEntry{
			kind = .Default,
			name = "default",
			start = start.start,
			end = start.end,
		},
	}
	bump_append(&p.staticExports, esm_export)

	stmt := new_node(p, Statement)
	stmt^ = (^ExportDefaultDeclaration)(decl)
	return stmt
}

parse_export_all :: proc(p: ^Parser, start: Loc, export_kind: ImportExportKind) -> ^Statement {
	exported: Maybe(IdentifierName)

	if match_token(p, .As) {
		if is_token(p, .String) {
			// `export * as "str" from "m"` - ModuleExportName string form.
			current := snap_current(p)
			val := current.literal.(string) or_else ""
			if string_has_unpaired_surrogate(val) {
				report_error_coded(p, .K3020_ImportExportNameOrBinding, "Export name string must not contain unpaired surrogates")
			}
			name_loc := loc_from_token(&current)
			exported = IdentifierName{loc = name_loc, name = val}
			eat(p)
		} else {
			name := parse_identifier_name(p)
			exported = IdentifierName{
				loc  = name.loc,
				name = name.name,
			}
		}
	}

	if !expect_token(p, .From) {
		return nil
	}

	if !is_token(p, .String) {
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected string literal module specifier after 'from'")
	}
	source := parse_string_literal(p)

	decl := new_node(p, ExportAllDeclaration)
	decl.loc = start
	decl.source = source
	decl.exported = exported
	decl.export_kind = export_kind
	decl.attributes = parse_import_attributes(p)

	// Consume the trailing semicolon BEFORE stamping the span end so the
	// ExportAllDeclaration includes its own `;` - matches ESTree/OXC/Acorn
	// semantics. Export declarations are statements, not expressions -
	// they can't have member-access continuations. Use a permissive ASI:
	// any line terminator terminates the declaration (even before `[`).
	if !match_semicolon_or_asi_export(p) {
		report_error_coded(p, .K2010_ExpectedSemicolon, "Expected semicolon after export declaration")
	}
	decl.loc.end = prev_end_offset(p)

	// Collect ESM static export record for export * from
	p.has_module_syntax = true
	esm_export := ESMStaticExport{
		start = decl.loc.start,
		end = decl.loc.end,
		moduleRequest = {
			value = decl.source.value,
			start = decl.source.loc.start,
			end = decl.source.loc.end,
		},
		entries = make([dynamic]ESMStaticExportEntry, 1, p.allocator),
	}
	// Determine the export name based on presence of "as" clause
	export_name := "*"
	if v, ok := decl.exported.?; ok {
		export_name = v.name
	}
	esm_export.entries[0] = ESMStaticExportEntry{
		exportName = ESMExportNameEntry{
			kind = .Namespace,
			name = export_name,
			start = decl.source.loc.start,
			end = decl.source.loc.end,
		},
		localName = ESMExportNameEntry{
			kind = .Namespace,
			name = export_name,
			start = decl.source.loc.start,
			end = decl.source.loc.end,
		},
	}
	bump_append(&p.staticExports, esm_export)

	stmt := new_node(p, Statement)
	stmt^ = (^ExportAllDeclaration)(decl)
	return stmt
}

parse_export_named :: proc(p: ^Parser, start: Loc, export_kind: ImportExportKind) -> ^Statement {
	if !expect_token(p, .LBrace) {
		return nil
	}

	decl := new_node(p, ExportNamedDeclaration)
	decl.loc = start
	decl.export_kind = export_kind
	decl.specifiers = make([dynamic]ExportSpecifier, 0, 4, p.allocator)

	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		start_spec := cur_loc(p)

		// TS per-specifier type modifier: `export { type Foo }`,
		// `export { type Foo as Bar }`, `export { type "a" as "b" }`.
		// Same disambiguation as parse_import_specifier above - only consume
		// `type` when the following token can start a name AND isn't `as` /
		// `}` / `,` (which would mean "type" is the local name itself).
		if allow_ts_mode(p) && p.cur_type == .Identifier && cur_value_eq(p, "type") {
			ensure_nxt(p)
			if cur_has_escape(p) && p.lexer.nxt.kind == .As {
				report_error_coded(p, .K3015_KeywordContainsEscape, "Keyword 'type' must not contain escaped characters")
			}
   ensure_nxt(p)
			nxt := p.lexer.nxt.kind
			nxt_is_name := nxt == .Identifier || nxt == .String ||
			               is_keyword_usable_as_property_name(nxt)
			// Same disambiguation as import: `type` is a modifier only when
			// followed by a name that isn't `as`/`,`/`}`. When it IS a
			// modifier and the outer export is type-only, reject.
			type_is_modifier_export := nxt_is_name && nxt != .As
			if !type_is_modifier_export && nxt == .As {
				// `type as }` → modifier on `as`. Check token after `as`.
				snap_e := lexer_snapshot(p)
				advance_token(p) // type
				advance_token(p) // as
				after_as := p.cur_type
				lexer_restore(p, snap_e)
				if after_as != .Identifier && !can_be_binding_identifier(after_as) &&
				   after_as != .String {
					type_is_modifier_export = true
				}
			}
			if export_kind == .Type && type_is_modifier_export {
				report_error_coded(p, .K4010_TypeOnlyImportExportInvalid, "The 'type' modifier cannot be used in a type-only export")
			}
			if nxt_is_name && nxt != .As {
				eat(p) // consume `type`
			} else if nxt == .As {
				// `export { type as }` / `export { type as as if }`. 4-token
				// lookahead disambiguates whether `type` is a type modifier or
				// a local name. After `type as`, check the next token:
				//   `,` / `}` / `from` → `type` is modifier (`export { type as }`)
				//   `as` → look one more: if a valid name follows (`as if`,
				//          `as foo`), `type` is modifier; if `}` / `,` follows,
				//          `type` is the local name (`export { type as as }`).
				snap := lexer_snapshot(p)
				eat(p) // consume `type`
				eat(p) // consume first `as`
				after := p.cur_type
				consume_type := false
				if after == .Comma || after == .RBrace || after == .From {
					consume_type = true
				} else if after == .As {
					// `type as as X` - peek past the second `as`.
					eat(p) // consume second `as`
					after_as := p.cur_type
					if after_as == .Identifier || after_as == .String ||
					   is_keyword_usable_as_property_name(after_as) {
						consume_type = true
					}
				}
				lexer_restore(p, snap)
				if consume_type {
					eat(p)
				}
			}
		}

		// ES2022 allows either an identifier OR a string literal on either
		// side of `as`. Parse each slot independently.
		parse_spec_name :: proc(p: ^Parser) -> ExportSpecifierName {
			if is_token(p, .String) {
				current := snap_current(p)
				str_lit := new_node(p, StringLiteral)
				str_lit.loc = loc_from_token(&current)
				str_lit.value = current.literal.(string) or_else ""
				str_lit.raw = current.value
				// §16.2.3 - ModuleExportName : StringLiteral must be well-formed Unicode.
				if string_has_unpaired_surrogate(str_lit.value) {
					report_error_coded(p, .K3020_ImportExportNameOrBinding, "Export name string must not contain unpaired surrogates")
				}
				eat(p)
				return str_lit
			}
			// Numeric / BigInt literals are not valid export names.
			if is_token(p, .Number) || is_token(p, .BigInt) {
				report_error_coded(p, .K3020_ImportExportNameOrBinding, "Numeric or bigint literal cannot be an export name")
				current := snap_current(p)
				eat(p)
				return IdentifierName{loc = loc_from_token(&current), name = current.value}
			}
			id := parse_identifier_name(p)
			return IdentifierName{loc = id.loc, name = id.name}
		}

		local := parse_spec_name(p)
		exported := local
		has_as := match_token(p, .As)
		if has_as {
			exported = parse_spec_name(p)
		}

		spec := ExportSpecifier{
			loc = start_spec,
			local = local,
			exported = exported,
		}
		spec.loc.end = prev_end_offset(p)
		bump_append(&decl.specifiers, spec)

		if !match_token(p, .Comma) {
			break
		}
	}

	if !expect_token(p, .RBrace) {
		return nil
	}

	// §Grammar Notation: the `from` contextual keyword must appear literally.
	// Escaped form `\u0066rom` is lexed as .Identifier with has_escape=true.
	if is_token(p, .Identifier) && cur_value_eq(p, "from") {
		if cur_has_escape(p) {
			report_error_coded(p, .K3015_KeywordContainsEscape,
				"'from' keyword must not contain Unicode escape sequences")
		}
		// Treat the identifier 'from' as the From keyword for recovery.
		p.cur_type = .From
	}
	if match_token(p, .From) {
		if !is_token(p, .String) {
			report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected string literal module specifier")
		}
		decl.source = parse_string_literal(p)
		decl.attributes = parse_import_attributes(p)
	}

	if !match_semicolon_or_asi_export(p) {
		// `export {} null;` - unexpected token follows export clause on same line.
		report_error_coded(p, .K2010_ExpectedSemicolon, "Expected semicolon after export declaration")
	}

	// §16.2.3 ExportClause: `export { default }` without `as` is a
	// SyntaxError when the local name is a ReservedWord and there's no
	// `from` clause. With `from`, the local name is a ModuleExportName
	// string that doesn't bind locally, so re-exports are fine.
	if decl.source == nil {
		for spec in decl.specifiers {
			local_name: string
			#partial switch n in spec.local {
			case IdentifierName: local_name = n.name
			}
			exported_name: string
			#partial switch n in spec.exported {
			case IdentifierName: exported_name = n.name
			}
			if local_name == exported_name && local_name == "default" {
				report_error_coded(p, .K3020_ImportExportNameOrBinding, "Reserved word 'default' cannot be used as a local exported binding without 'as'")
			}
		}
	}

	decl.loc.end = prev_end_offset(p)

	// Collect ESM static export record for named exports
	p.has_module_syntax = true
	if len(decl.specifiers) > 0 {
		esm_export := ESMStaticExport{
			start = decl.loc.start,
			end = decl.loc.end,
			entries = make([dynamic]ESMStaticExportEntry, 0, len(decl.specifiers), p.allocator),
		}
		// Handle export * from "m" case
		if v, ok := decl.source.?; ok {
			esm_export.moduleRequest.value = v.value
			esm_export.moduleRequest.start = v.loc.start
			esm_export.moduleRequest.end = v.loc.end
		}
		for spec in decl.specifiers {
			entry := ESMStaticExportEntry{
				exportName = convert_export_spec_name(spec.exported),
				localName = convert_export_spec_name(spec.local),
			}
			bump_append(&esm_export.entries, entry)
		}
		bump_append(&p.staticExports, esm_export)
	}

	// Allocate Statement union and store the pointer
	stmt := new_node(p, Statement)
	stmt^ = (^ExportNamedDeclaration)(decl)
	return stmt
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
// JSX Parsing (Phase 2)
// ============================================================================

is_jsx_identifier_token :: proc(p: ^Parser) -> bool {
	return is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type)
}

parse_jsx_element_or_fragment :: proc(p: ^Parser) -> ^Expression {
	start := cur_loc(p)
	eat(p)
	// `</>` (lone closing fragment) at expression position has no
	// matching opening fragment. Reject.
	if is_token(p, .Div) {
		report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token: lone closing JSX fragment '</>'")
	}
	if is_token(p, .RAngle) {
		eat(p)
		// Opening fragment `<>` spans [<, >] inclusive of both angle brackets
		// (2 bytes) - matches OXC's JSXOpeningFragment.{start,end}.
		opening_loc := start
		opening_loc.end = u32(prev_end_offset(p))
		children := parse_jsx_children(p)
		// Closing fragment `</>` spans [<, >] - start is at the `<`, not after `</`.
		closing_start := cur_loc(p)
		expect_token(p, .LAngle); expect_token(p, .Div)
		expect_token(p, .RAngle)
		closing_loc := closing_start
		closing_loc.end = u32(prev_end_offset(p))
		frag, frag_e := new_expr(p, JSXFragment)
		frag.loc = start
		frag.opening_fragment = JSXOpeningFragment{loc = opening_loc}
		frag.children = children
		frag.closing_fragment = JSXClosingFragment{loc = closing_loc}
		frag.loc.end = prev_end_offset(p)
		return frag_e
	}
	name := parse_jsx_element_name(p)
	opening := parse_jsx_opening_element(p, start, name)
	if opening.self_closing {
		elem := new_node(p, JSXElement)
		elem.loc = start
		elem.opening_element = opening
		elem.children = make([dynamic]JSXChild, 0, 4, p.allocator)
		elem.loc.end = prev_end_offset(p)
		return expression_from(p, elem)
	}
	children := parse_jsx_children(p)
	closing := parse_jsx_closing_element(p, name)
	// Validate opening and closing tag names match. Only report when no
	// prior errors exist — during error recovery / ambiguity resolution,
	// tag names may be garbled and false positives are common.
	opening_name := jsx_element_name_string(name)
	closing_name := closing != nil ? jsx_element_name_string(closing.name) : ""
	if closing != nil && opening_name != closing_name &&
	   len(opening_name) > 0 && len(closing_name) > 0 && len(p.errors) == 0 {
		report_error_coded(p, .K3063_JSXInvalid, fmt.tprintf("Expected corresponding JSX closing tag for '%s'.", opening_name))
	}
	elem := new_node(p, JSXElement)
	elem.loc = start
	elem.opening_element = opening
	elem.children = children
	elem.closing_element = closing
	elem.loc.end = prev_end_offset(p)
	return expression_from(p, elem)
}

// Extract a string representation of a JSXElementName for tag matching.
// Returns the full qualified name including namespace / member parts so
// `<a:b></b>` and `<a.b></a>` are correctly detected as mismatches.
jsx_element_name_string :: proc(name: JSXElementName) -> string {
	switch n in name {
	case JSXIdentifier:
		return n.name
	case ^JSXNamespacedName:
		if n == nil { return "" }
		return fmt.tprintf("%s:%s", n.namespace.name, n.name.name)
	case ^JSXMemberExpression:
		if n == nil { return "" }
		obj_str := ""
		switch obj in n.object {
		case JSXIdentifier:
			obj_str = obj.name
		case ^JSXMemberExpression:
			if obj != nil {
				inner: JSXElementName = obj
				obj_str = jsx_element_name_string(inner)
			}
		}
		return fmt.tprintf("%s.%s", obj_str, n.property.name)
	}
	return ""
}

parse_jsx_element_name :: proc(p: ^Parser) -> JSXElementName {
	if !is_jsx_identifier_token(p) { return nil }
	ident := parse_jsx_identifier(p)
	if is_token(p, .Colon) {
		eat(p)
		name := parse_jsx_identifier(p)
		ns := new_node(p, JSXNamespacedName)
		ns.loc = ident.loc; ns.namespace = ident; ns.name = name
		ns.loc.end = prev_end_offset(p)
		return ns
	}
	if is_token(p, .Dot) {
		obj: JSXMemberObject = ident
		// Hyphens are not allowed in JSX member expression identifiers.
		if strings.contains(ident.name, "-") {
			report_error_coded(p, .K3063_JSXInvalid, "Identifiers in JSX cannot contain hyphens")
		}
		for is_token(p, .Dot) {
			eat(p)
			prop := parse_jsx_identifier(p)
			if strings.contains(prop.name, "-") {
				report_error_coded(p, .K3063_JSXInvalid, "Identifiers in JSX cannot contain hyphens")
			}
			member := new_node(p, JSXMemberExpression)
			member.loc = ident.loc; member.object = obj; member.property = prop
			member.loc.end = prev_end_offset(p)
			obj = member
		}
		#partial switch v in obj { case ^JSXMemberExpression: return v }
	}
	return ident
}

parse_jsx_identifier :: proc(p: ^Parser) -> JSXIdentifier {
	if !is_jsx_identifier_token(p) {
		report_error_coded(p, .K2021_ExpectedIdentifier, "Expected JSX identifier")
		return JSXIdentifier{}
	}
	start_loc := cur_loc(p)
	current := snap_current(p)
	name := current.value
	// JSX spec: Unicode escapes are not allowed in JSX tag names or
	// attribute names. `<\u0061>` is invalid — must write `<a>`.
	// OXC keeps the raw source for tag comparison, so `<\u0061></a>`
	// gets a "closing tag mismatch" error. Match by using the raw
	// source span as the identifier name when escapes are present.
	if cur_has_escape(p) && p.lexer != nil {
		raw := p.lexer.source[current.start:current.end]
		name = raw
	}
	eat(p)
	if is_token(p, .Minus) || is_token(p, .MinusMinus) {
		// JSXIdentifier per JSX spec: IdentifierStart IdentifierTail* where
		// IdentifierTail ∈ { IdentifierStart, DecimalDigit, `-` }. Trailing
		// hyphens (`<div->`, `<div-->`) and bare hyphen-terminated names
		// (`<div-/>`) are legal — the `-` is part of the name and a `>` /
		// `/>` / whitespace boundary closes the tag, not the identifier
		// mid-character.
		// `--` arrives from the JS lexer as a single MinusMinus token; we
		// split it into two `-` parts here. The other `--` shape (post/pre
		// decrement operator) cannot reach this code path — we're inside
		// a JSX tag-name parse, where decrement is grammatically impossible.
		parts := make([dynamic]string, 0, 4, p.allocator)
		bump_append(&parts, name)
		for is_token(p, .Minus) || is_token(p, .MinusMinus) {
			if is_token(p, .MinusMinus) {
				eat(p)
				bump_append(&parts, "--")
			} else {
				eat(p)
				bump_append(&parts, "-")
			}
			// After eating a hyphen, the lexer's prefetched cur was lexed
			// with `can_start_regex(.Minus) = true`, so a `/` byte was
			// classified as Regex (and likely emitted an Unterminated-regex
			// error if the source has only `/>`). Inside a JSX tag name
			// the `/` is a JSX self-close, never a regex — force-relex.
			jsx_relex_div_after_hyphen(p)
			if is_jsx_identifier_token(p) {
				c := snap_current(p)
				bump_append(&parts, c.value)
				eat(p)
			}
			// else: trailing hyphen(s) — next loop iter handles further `-`,
			// fall through ends the name otherwise.
		}
		sb: strings.Builder
		strings.builder_init(&sb, p.allocator)
		for part in parts { strings.write_string(&sb, part) }
		name = strings.to_string(sb)
	}
	result := JSXIdentifier{loc = start_loc, name = name}
	result.loc.end = prev_end_offset(p)
	return result
}

// jsx_relex_div_after_hyphen — fix-up helper called after eating a
// hyphen inside a JSX tag-name parse. If the lexer's cur was prefetched
// as Regex starting at the byte of `/`, drop the spurious lexer errors,
// rewind, and re-lex the slash as Div. Mirrors the relex-as-div pattern
// already used for `expr!.foo` (TS non-null) and tagged-template member
// chains in this file.
jsx_relex_div_after_hyphen :: proc(p: ^Parser) {
	if p.lexer == nil { return }
	if p.lexer.cur.kind != .RegularExpression { return }
	start := p.lexer.cur.start
	if int(start) >= len(p.lexer.source) { return }
	if p.lexer.source[int(start)] != '/' { return }

	// Drop any lexer errors recorded at or past this `/` — they're
	// the unterminated-regex artifacts we're undoing.
	for len(p.lexer.lexer_errors) > 0 {
		last := p.lexer.lexer_errors[len(p.lexer.lexer_errors)-1]
		if last.offset >= start { pop(&p.lexer.lexer_errors) } else { break }
	}

	p.lexer.offset = int(start)
	p.lexer.cur = lex_slash_as_div(p.lexer)
	// nxt is invalidated — will be lazily re-lexed on next peek.
	p.lexer.nxt_valid = false
	p.cur_type = p.lexer.cur.kind
}

parse_jsx_opening_element :: proc(p: ^Parser, start: Loc, name: JSXElementName) -> ^JSXOpeningElement {
	opening := new_node(p, JSXOpeningElement)
	opening.loc = start; opening.name = name

	// TSX: type arguments on the opening element - `<Foo<string> />`.
	// Must come after the element name, before attributes. The `<` here
	// starts a type argument list, not a nested JSX element, because the
	// element name just consumed the identifier and the next `<` cannot
	// be a valid attribute or `>` / `/`.
	if (p.lang == .TSX) && is_open_angle_or_lshift(p) {
		opening.type_arguments = parse_ts_type_arguments(p)
	}

	opening.attributes = make([dynamic]JSXAttributeItem, 0, 4, p.allocator)
	for !is_token(p, .RAngle) && !is_token(p, .Div) && !is_token(p, .EOF) {
		if is_token(p, .LBrace) {
			spread_start := cur_loc(p)
			eat(p); expect_token(p, .Dot3)
			expr := parse_assignment_expression(p)
			expect_token(p, .RBrace)
			spread := new_node(p, JSXSpreadAttribute)
			spread.loc = spread_start; spread.argument = expr
			spread.loc.end = prev_end_offset(p)
			bump_append(&opening.attributes, spread)
		} else if is_jsx_identifier_token(p) {
			attr_start := cur_loc(p)
			// Enable JSX string mode before scanning the attribute name.
			// The attribute value string (if any) gets scanned as `nxt`
			// during eat() inside parse_jsx_attribute_name, so the flag
			// must be active before that call. JSX §2.2: attribute values
			// in quotes can span multiple lines (unlike JS strings).
			p.lexer.jsx_string_mode = true
			attr_name := parse_jsx_attribute_name(p)
			attr_value: Maybe(^Expression)
			if is_token(p, .Assign) {
				eat(p)
				// Clear JSX string mode. For `attr="str"`, `cur` is the
				// already-lexed String token (correct). For `attr={expr}`,
				// `nxt` was lexed with jsx_string_mode still true during the
				// eat above - that token is inside a JS expression where
				// escapes MUST be honoured. Re-lex nxt so `\"` is processed
				// as a JS escape, not as a literal backslash + closing quote.
				p.lexer.jsx_string_mode = false
				ensure_nxt(p)
				if (is_token(p, .LBrace) || is_token(p, .LAngle)) &&
				   p.lexer.nxt.kind == .String {
					// nxt is a String token lexed from inside a `{expr}`
					// or `<elem>` with jsx_string_mode=true.  Rewind the
					// lexer to nxt's start and re-lex in normal JS mode so
					// escape sequences like `\"` are honoured.  Other token
					// types (Template, Number, etc.) are unaffected by the
					// flag and must NOT be re-lexed.
					ensure_nxt(p)
					p.lexer.offset = int(p.lexer.nxt.start)
					p.lexer.nxt_valid = false
				}
				if is_token(p, .String) {
					str := parse_string_literal(p)
					str_expr, str_expr_e := new_expr(p, StringLiteral); str_expr^ = str
					attr_value = str_expr_e
				} else if is_token(p, .LBrace) {
					container_start := cur_loc(p)
					// JSX attribute expression: `{expr}`. Use parse_expression
					// (not parse_assignment_expression) to allow the comma
					// operator: `{class1, class2}` is a SequenceExpression.
					// `attr={}` — empty expression container is invalid.
					if is_next_token(p, .RBrace) {
						report_error_coded(p, .K2070_RequiredFormOrBinding, "JSX attributes must only be assigned a non-empty expression")
					}
					eat(p); expr := parse_expression(p); expect_token(p, .RBrace)
					// TS18007: JSX expressions may not use the comma operator.
					if expr != nil {
						if _, is_seq := expr^.(^SequenceExpression); is_seq {
							report_error_coded(p, .K3063_JSXInvalid, "JSX expressions may not use the comma operator")
						}
					}
					container, container_e := new_expr(p, JSXExpressionContainer)
					container.loc = container_start; container.expression = expr
					container.loc.end = prev_end_offset(p)
					attr_value = container_e
				} else if is_token(p, .LAngle) {
					attr_value = parse_jsx_element_or_fragment(p)
				} else {
					// JSX attribute has `=` but no value expression.
					report_error_coded(p, .K2070_RequiredFormOrBinding, "JSX attributes must only be assigned a non-empty expression")
				}
			} else {
				// Boolean attribute (no `=`) - clear the JSX string flag.
				p.lexer.jsx_string_mode = false
			}
			attr: JSXAttribute
			attr.loc = attr_start; attr.name = attr_name; attr.value = attr_value
			attr.loc.end = prev_end_offset(p)
			bump_append(&opening.attributes, attr)
		} else { break }
	}
	if is_token(p, .Div) { eat(p); opening.self_closing = true }
	expect_token(p, .RAngle)
	opening.loc.end = prev_end_offset(p)
	return opening
}

parse_jsx_attribute_name :: proc(p: ^Parser) -> JSXAttributeName {
	ident := parse_jsx_identifier(p)
	if is_token(p, .Colon) {
		eat(p); name := parse_jsx_identifier(p)
		ns := new_node(p, JSXNamespacedName)
		ns.loc = ident.loc; ns.namespace = ident; ns.name = name
		ns.loc.end = prev_end_offset(p)
		return ns
	}
	return ident
}

parse_jsx_children :: proc(p: ^Parser) -> [dynamic]JSXChild {
	children := make([dynamic]JSXChild, 0, 4, p.allocator)
	for !is_token(p, .EOF) {
		prev_off := cur_offset(p)
		// ESTree requires JSXText slices between *every* pair of children,
		// including whitespace-only runs like the leading `\n    ` before a
		// `{expr}` or the closing `\n  ` before `</div>`. Without consuming
		// JSXText FIRST on every iteration, the lexer's whitespace skip
		// (which fires before returning `.LBrace` or `.LAngle`) eats those
		// bytes and the emitted AST is missing them entirely - observed on
		// interactions/006 where OXC emitted three children (JSXText,
		// JSXExpressionContainer, JSXText) but Kessel emitted only the
		// middle one. parse_jsx_text scans from prev_end_offset to the
		// next `<` / `{`, so it naturally grabs the leading run when the
		// current token is already one of those delimiters.
		if text := parse_jsx_text(p); text != nil && text.value != "" {
			// JSX spec: bare `>` is not allowed in text content — must
			// use `{'>'}` or `&gt;`. Only report when the parse is clean
			// (no prior errors) to avoid false positives during recovery.
			if len(p.errors) == 0 {
				for c in text.value {
					if c == '>' {
						report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token. Did you mean `{'>'}` or `&gt;`?")
						break
					}
					if c == '}' {
						report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token. Did you mean `{'}'}` or `&rbrace;`?")
						break
					}
				}
			}
			bump_append(&children, text)
		}
		if is_token(p, .LAngle) {
			if peek_token(p).type == .Div { break }
			nested := parse_jsx_element_or_fragment(p)
			if nested != nil {
				#partial switch v in nested^ {
				case ^JSXElement:  bump_append(&children, v)
				case ^JSXFragment: bump_append(&children, v)
				}
			}
		} else if is_token(p, .LBrace) {
			start := cur_loc(p)
			// JSXEmptyExpression spans between `{` and `}` (exclusive of both),
			// matching OXC. `{` is always 1 byte, so empty_start = start + 1.
			empty_start := start.start + 1
			eat(p)
			// Reset ternary depth across the JSX expression-container
			// boundary. Inside `{expr}` the surrounding ternary's `:` is
			// not in scope; otherwise looks_like_ts_arrow_params would
			// suppress its byte-scan and reject `{(): T => body}`-style
			// arrow returns inside JSX (swc-8243.tsx).
			prev_cond_depth := p.conditional_depth
			p.conditional_depth = 0
			expr: ^Expression = nil
			if !is_token(p, .RBrace) { expr = parse_assignment_expression(p) }
			p.conditional_depth = prev_cond_depth
			rbrace_start := u32(cur_offset(p))
			expect_token(p, .RBrace)
			container := new_node(p, JSXExpressionContainer)
			container.loc = start
			if expr != nil { container.expression = expr
			} else {
				empty, empty_e := new_expr(p, JSXEmptyExpression)
				empty.loc = Loc{start = empty_start, end = rbrace_start}
				container.expression = empty_e
			}
			container.loc.end = prev_end_offset(p)
			bump_append(&children, container)
		}
		// Progress guard: if no iteration advanced the cursor (e.g. malformed
		// input where parse_jsx_element_or_fragment returned without consuming,
		// or parse_jsx_text had nothing to scan), break instead of looping
		// forever. Fuzzed input without a proper JSX close tag would otherwise
		// spin here at O(∞).
		if cur_offset(p) == prev_off { break }
	}
	return children
}

parse_jsx_text :: proc(p: ^Parser) -> ^JSXText {
	// JSX text starts immediately after the previous token (a `>`, `}`, or
	// closing `/>`), NOT at the current token's start - the lexer may have
	// skipped leading whitespace that JSX semantics require preserved.
	// e.g. `<div>Before {expr} after</div>` - after parsing `{expr}`, the
	// leading space in ` after` must be kept (OXC does this).
	src := p.lexer.source
	text_start := int(prev_end_offset(p))
	// Safety: if prev_end_offset is beyond cur.start (shouldn't happen, but
	// defensive against lexer quirks), clamp to cur.start.
	if text_start > int(cur_offset(p)) { text_start = int(cur_offset(p)) }
	start := Loc{start = u32(text_start), end = u32(text_start)}
	off := text_start
	for off < len(src) {
		c := src[off]
		if c == '<' || c == '{' { break }
		off += 1
	}
	if off == text_start { return nil }
	value := src[text_start:off]
	// The lexer already advanced past the previous `>` or `}` and tried
	// to lex whatever followed as JavaScript tokens. If that content is
	// actually JSX text (e.g. `7x invalid-js-identifier`), the lexer may
	// have pushed spurious errors ("Identifier directly after number").
	// Remove any lexer errors whose offset falls inside the text region
	// we are re-claiming as JSXText.
	{
		text_end := u32(off)
		write := 0
		for i in 0..<len(p.lexer.lexer_errors) {
			e := p.lexer.lexer_errors[i]
			if e.offset < u32(text_start) || e.offset >= text_end {
				p.lexer.lexer_errors[write] = e
				write += 1
			}
		}
		resize(&p.lexer.lexer_errors, write)
	}
	p.lexer.offset = off
	p.lexer.cur = lex_token(p.lexer)
	p.lexer.lit_write_idx ~= 1  // toggle so cur_literal reads the slot just written
	p.lexer.nxt_valid = false
	p.cur_type = p.lexer.cur.kind
	text := new_node(p, JSXText)
	text.loc = start; text.value = value; text.raw = value
	text.loc.end = u32(off)
	return text
}

parse_jsx_closing_element :: proc(p: ^Parser, expected: JSXElementName) -> ^JSXClosingElement {
	start := cur_loc(p)
	expect_token(p, .LAngle); expect_token(p, .Div)
	name := parse_jsx_element_name(p)
	expect_token(p, .RAngle)
	closing := new_node(p, JSXClosingElement)
	closing.loc = start; closing.name = name
	closing.loc.end = prev_end_offset(p)
	return closing
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
