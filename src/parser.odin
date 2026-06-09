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
// Statements
// ============================================================================

parse_statement_or_declaration :: proc(p: ^Parser) -> ^Statement {
	// At statement start, `/` or `/=` must be a regex literal (not
	// division), because no LHS exists. Re-lex if the lexer's
	// previous-token-class heuristic guessed wrong (typical case after
	// `}` ends a block: lexer sees `}/.../` and would otherwise pick
	// AssignDiv from `}` as a regex-starting context).
	if p.cur_type == .Div || p.cur_type == .AssignDiv {
		if p.lexer != nil {
			relex_as_regex(p.lexer)
			// Update parser's cached token from the re-lexed result
			ft := p.lexer.cur
			p.cur_type = ft.kind
		}
	}

	#partial switch p.cur_type {
	case .Function:
		return parse_function_declaration(p)
	case .Async:
		// async function declaration or async expression.
		// ECMA-262 §15.8 Restricted Production: `async [no LineTerminator
		// here] function`. A LineTerminator between `async` and `function`
		// breaks the AsyncFunctionDeclaration rule - `async` is then a bare
		// IdentifierReference and the following `function` starts its own
		// FunctionDeclaration statement via ASI.
		// Grammar notation: terminal symbol `async` must NOT have Unicode
		// escapes. `\u0061sync function...` is a SyntaxError.
		if cur_has_escape(p) {
			report_error_coded(p, .K3015_KeywordContainsEscape, "'async' keyword must not contain Unicode escape sequences")
			return parse_expression_or_labeled_statement(p)
		}
		next_after_async := peek_token(p)
		if next_after_async.type == .Function && !next_after_async.had_line_terminator {
			return parse_function_declaration(p)
		}
		return parse_expression_or_labeled_statement(p)
	case .Class:
		return parse_class_declaration(p)
	case .Abstract:
		// `abstract class Foo { ... }` - consume `abstract` and set the flag
		// on the parsed class declaration. TS-only syntax.
		// ASI guard: `abstract\nclass` (newline between) is NOT an abstract
		// class — `abstract` is an expression statement and the class is
		// non-abstract. Matches OXC/TSC behavior (TSC reports TS2304 for the
		// standalone `abstract` identifier). Same semantics as `async\nfunction`.
		if is_next_token(p, .Class) && !peek_token(p).had_line_terminator {
			if !allow_ts_mode(p) {
				report_error_coded(p, .K4032_ModifierMisplaced, "'abstract' modifier is only allowed in TypeScript files")
			}
			eat(p) // consume `abstract`
			prev_abs := p.ctx.class_is_abstract
			p.ctx.class_is_abstract = true
			stmt := parse_class_declaration(p)
			p.ctx.class_is_abstract = prev_abs  // prevent leak to next class
			if stmt != nil {
				if cls, ok := stmt^.(^ClassDeclaration); ok { cls.expr.abstract = true }
			}
			return stmt
		}
		// Not followed by class - fall through to expression (treat `abstract`
		// as an identifier). Best to defer to the generic identifier path.
		return parse_expression_or_labeled_statement(p)
	case .At:
		return parse_decorated_class(p)
	case .Var:
		return parse_variable_declaration(p, nil, true)
	case .Let:
		// §14.3.1 - LexicalDeclaration : `let` BindingList. The
		// `let` keyword only starts a LexicalDeclaration when followed
		// by a BindingIdentifier / `[` / `{`. Otherwise it's an
		// IdentifierReference (sloppy script): `let = 4;`,
		// `let.x = 1;`, `let + 1`. Same `[lookahead ∉ { let [ }]`
		// rule as in for-head; mirror the conservative whitelist.
		nxt_let := peek_token(p)
		let_is_decl := false
		if nxt_let.type == .LBracket || nxt_let.type == .LBrace ||
		   is_identifier_like_token(nxt_let.type) {
			// §ASI restricted production: in sloppy mode, `let [LT] <identifier>`
			// triggers ASI so `let` is treated as an IdentifierReference (not a
			// declaration). e.g. `for (;;) let\nx = 1` is valid in sloppy mode.
			// IMPORTANT: `let [` and `let {` are ALWAYS declarations -
			// ExpressionStatement lookahead restriction prohibits `let [`
			// (§ExprStmt), and `let {` has no expression-statement reading
			// (V8 and OXC both parse `let\n{ a } = ...` as a declaration).
			// In strict mode, `let` is a keyword, so always a declaration.
			// In single-statement contexts (if/while/for/with consequent),
			// `let\n{` must also trigger ASI - lexical declarations are
			// forbidden there, so `let` is an identifier. block_depth > 0
			// signals we're inside such a context (set by parse_if_statement
			// et al. before calling parse_statement_or_declaration).
			is_let_asi := nxt_let.had_line_terminator && !p.ctx.strict_mode && !allow_ts_mode(p) &&
			              (nxt_let.type == .Identifier ||
			               (nxt_let.type == .LBrace && p.block_depth > 0))
			if !is_let_asi {
				let_is_decl = true
			}
		}
		// In strict mode `let` is itself a reserved word - always a
		// declaration there. The strict-mode binding-name check fires
		// downstream if the next token isn't valid.
		// In strict mode, `let` is a keyword. If the next token can start
		// a binding (Identifier, `[`, `{`), it's a declaration. Otherwise
			// (`let + 1`, `let.x`), parse as expression - the semantic checker
		// (or report_semantic_error) handles the strict-mode violation.
		if p.ctx.strict_mode && !let_is_decl {
			// Only force declaration if the next token looks like a binding.
			if nxt_let.type == .LBracket || nxt_let.type == .LBrace ||
			   is_identifier_like_token(nxt_let.type) {
				let_is_decl = true
			}
		}
		if let_is_decl {
			return parse_variable_declaration(p, nil, true)
		}
		// In TS mode, bare `let` without a binding is always an error because
		// TS treats `let` as a keyword. OXC also rejects this.
		// Inside TS namespace blocks, OXC's parser silently accepts bare
		// `let;` (TS1123 is semantic) — route through the declaration path
		// which handles the empty-list recovery.
		if allow_ts_mode(p) && (nxt_let.type == .EOF || nxt_let.type == .Semi ||
		   nxt_let.type == .RBrace) {
			if p.ctx.in_ts_namespace {
				return parse_variable_declaration(p, nil, true)
			}
			report_error_coded(p, .K2070_RequiredFormOrBinding, "'let' declaration requires a binding name")
		}
		return parse_expression_or_labeled_statement(p)
	case .Using:
		// `using x = ...` is a declaration; `using(...)` or `using.foo` or
		// `using[x]` is an expression. The spec uses BindingIdentifier (no
		// destructuring), so `[` and `{` do NOT trigger a declaration.
		// Also apply ASI-like treatment for newline before the identifier
		// (mirroring `let\n<id>` logic in sloppy mode).
		{
			nxt_using := peek_token(p)
			nxt_is_id := nxt_using.type == .Identifier ||
			             can_be_binding_identifier(nxt_using.type)
			// With a preceding newline, `using` is an identifier (not a decl).
			if nxt_is_id && !nxt_using.had_line_terminator {
				return parse_variable_declaration(p, nil, true)
			}
		}
		return parse_expression_or_labeled_statement(p)
	case .Const:
		// `const enum Foo { ... }` - TS enum with const modifier.
		// `enum` now lexes as Identifier, so check string value.
		if is_next_identifier_value(p, "enum") {
			return parse_ts_enum_declaration(p)
		}
		return parse_variable_declaration(p, nil, true)
	case .Await:
		if is_next_token(p, .Using) {
			// `await using` is the AwaitUsingDeclaration head, but ONLY if
			// the token after `using` is a BindingIdentifier (no line break).
			// Otherwise `using` is an identifier - the operand of `await`:
			//   `await using[x]`    → await (using[x])
			//   `await using.x`     → await (using.x)
			//   `await using(x)`    → await (using(x))
			//   `await using in foo` → await (using in foo)
			//   `await using`x``    → await (using`x`)
			// 3-token lookahead: save lexer state, lex past `using`, check
			// the third token, then restore.
			is_decl := await_using_starts_decl(p)
			if is_decl {
				return parse_variable_declaration(p, nil, true)
			}
		}
		return parse_expression_or_labeled_statement(p)
	case .Identifier:
		// §Grammar Notation: terminal symbols must not have Unicode escapes.
		// `\u0061sync function*` tries to write `async function*` with an
		// escaped keyword - this is a SyntaxError.
		if cur_has_escape(p) && cur_value_eq(p, "async") {
			// Peek ahead: if this looks like an async function / arrow, error.
			nxt := peek_token(p)
			if (nxt.type == .Function && !nxt.had_line_terminator) ||
			   (nxt.type == .Identifier && !nxt.had_line_terminator) ||
			   (nxt.type == .LParen && !nxt.had_line_terminator) {
				report_error_coded(p, .K3015_KeywordContainsEscape, "'async' keyword must not contain Unicode escape sequences")
			}
		}
		// TS contextual keywords: `type`, `interface`, `enum`, `declare` lex as Identifier
		// so that `var type = 1` and similar JS code parses correctly.
		// We check string value here at the statement level.
		val := cur_value(p)
		if val == "declare" && allow_ts_mode(p) {
			// Only treat as a declare declaration if the next token can start
			// a declaration AND is on the same line. A newline after `declare`
			// triggers ASI: `declare\nconst x = 1` is two statements, not
			// `declare const x = 1`. OXC and TSC both apply this rule.
			nxt := peek_token(p)
			is_decl_start := false
			if !nxt.had_line_terminator {
				#partial switch nxt.type {
				case .Function, .Class, .Abstract, .Import, .Const, .Let, .Var, .Async:
					is_decl_start = true
				case .Identifier:
					if nxt.value == "interface" || nxt.value == "type" ||
				   nxt.value == "enum" || nxt.value == "namespace" ||
				   nxt.value == "module" || nxt.value == "abstract" ||
				   nxt.value == "global" {
						is_decl_start = true
					}
				}
			}
			if is_decl_start {
				return parse_ts_declare_statement(p)
			}
			return parse_expression_or_labeled_statement(p)
		}
		if val == "interface" && allow_ts_mode(p) {
			// `interface Foo { ... }` — next token must be an identifier
			// (the interface name). In sloppy script, `interface` is a
			// contextual keyword and can be used as an identifier:
			// `interface = 1;`, `interface.foo`, `interface()`, etc.
			// A newline before the name triggers ASI: `interface\nFoo`
			// is two statements, not `interface Foo { }`. OXC / TSC agree.
			// JS keywords like `void`, `null`, etc. are not valid as
			// interface names — use can_be_binding_identifier (not
			// is_keyword_usable_as_property_name). OXC agrees.
			nxt_tok := peek_token(p)
			if !nxt_tok.had_line_terminator && can_be_binding_identifier(nxt_tok.type) {
				return parse_ts_interface_declaration(p)
			}
			return parse_expression_or_labeled_statement(p)
		}
		if val == "type" && allow_ts_mode(p) {
			// `type Foo = ...` - next token must be an identifier (the alias
			// name). TS allows contextual keywords like `abstract`, `module`,
			// `namespace`, etc. as type alias names.
			// A newline before the name triggers ASI: `type\nFoo = number`
			// is two statements. OXC / TSC agree.
			// JS keywords not valid as type alias names.
			nxt_tok := peek_token(p)
			if !nxt_tok.had_line_terminator && can_be_binding_identifier(nxt_tok.type) {
				return parse_ts_type_alias_declaration(p)
			}
			return parse_expression_or_labeled_statement(p)
		}
		if val == "enum" && allow_ts_mode(p) {
			return parse_ts_enum_declaration(p)
		}
		if val == "namespace" && allow_ts_mode(p) {
			// `namespace Foo { ... }` or `namespace A.B { ... }`
			// Newline before the name triggers ASI: `namespace\nFoo { }`
			// is two statements. OXC / TSC agree.
			nxt_ns := peek_token(p)
			if !nxt_ns.had_line_terminator && is_next_token(p, .Identifier) {
				return parse_ts_module_declaration(p, .Namespace)
			}
			return parse_expression_or_labeled_statement(p)
		}
		if val == "module" && allow_ts_mode(p) {
			// `module "external-name" { ... }` (quoted-name module) or
			// `module M { ... }` (bare-identifier module, equivalent to
			// namespace). TS allows both forms; the identifier form is the
			// legacy spelling of `namespace M { ... }`.
			// Newline before the name triggers ASI.
			nxt_mod := peek_token(p)
			if !nxt_mod.had_line_terminator && (is_next_token(p, .String) || is_next_token(p, .Identifier)) {
				return parse_ts_module_declaration(p, .Module)
			}
			return parse_expression_or_labeled_statement(p)
		}
		// `global { ... }` - TS global augmentation without `declare` prefix.
		// Appears at top level, inside namespaces, or inside ambient modules.
		if val == "global" && allow_ts_mode(p) && is_next_token(p, .LBrace) {
			stmt := parse_ts_global_declaration(p)
			if stmt != nil {
				if mod, ok := stmt^.(^TSModuleDeclaration); ok {
					mod.global = true
				}
			}
			return stmt
		}
		return parse_expression_or_labeled_statement(p)
	case .LBrace:
		return parse_block_statement(p)
	case .If:
		return parse_if_statement(p)
	case .While:
		return parse_while_statement(p)
	case .Do:
		return parse_do_while_statement(p)
	case .For:
		return parse_for_statement(p)
	case .Return:
		return parse_return_statement(p)
	case .Break:
		return parse_break_statement(p)
	case .Continue:
		return parse_continue_statement(p)
	case .Switch:
		return parse_switch_statement(p)
	case .Try:
		return parse_try_statement(p)
	case .Throw:
		return parse_throw_statement(p)
	case .Debugger:
		return parse_debugger_statement(p)
	case .With:
		return parse_with_statement(p)
	case .Semi:
		return parse_empty_statement(p)
	case .RBracket:
		report_error_coded(p, .K2040_UnexpectedToken, "Unexpected closing token")
		eat(p)
		return nil
	case .RParen:
		report_error_coded(p, .K2040_UnexpectedToken, "Unexpected closing token")
		eat(p)
		return nil
	case .Import:
		// Check if this is a dynamic import / import.meta. ImportCall
		// (`import(...)`) and MetaProperty (`import.meta`) are expression
		// productions, not declarations; dispatch them through the regular
		// ExpressionStatement path so they work at every statement position
		// (top-level, block, arrow body, labeled-stmt...). Returning nil here
		// used to let the block loop report "Invalid statement in block" for
		// `{ import('x')(); }` under source-type=script.
		if is_next_token(p, .LParen) || is_next_token(p, .Dot) {
			return parse_expression_or_labeled_statement(p)
		}
		// §16.2.1 ImportDeclaration / ExportDeclaration are ModuleItems,
		// only legal at the top level of a Module body.
		check_import_export_position(p, true)
		return parse_import_declaration(p)
	case .Export:
		// §16.2.1 — see .Import above.
		check_import_export_position(p, false)
		return parse_export_declaration(p)
	case:
		return parse_expression_or_labeled_statement(p)
	}
}

// §16.2.1 — ImportDeclaration and ExportDeclaration are ModuleItems,
// legal only at the top level of a Module body. Two failure modes:
//   1. Script source: import/export are not grammar productions at all.
//   2. Module source, nested position (inside a function body, block,
//      arrow body, etc.): the declaration is outside the top-level
//      ModuleItemList.
// The error is reported but parsing continues (permissive recovery).
check_import_export_position :: proc(p: ^Parser, is_import: bool) {
	// Script-mode: import/export are Module-only syntax.
	// Exception: TypeScript .cts/.cjs files allow import/export syntax
	// when compiled under a TS context (TS transpiles them; Node.js
	// handles the upgrade). `is_commonjs` is set by the harness for
	// .cjs sub-files within TS compilation units.
	if st, have := p.force_source_type.(SourceType); have && st == .Script {
		if p.lang != .TS && p.lang != .TSX && !p.is_node_ts_module && !p.is_commonjs {
			msg := "'export' is only valid in module code"
			if is_import { msg = "'import' is only valid in module code" }
			report_error_coded(p, .K3022_ModuleSyntaxInScript, msg)
			return
		}
	}
	// Module-mode with explicit pin: reject when not at top-level.
	if p.in_module_top_level && (p.ctx.in_function || p.block_depth > 0) {
		msg := "'export' declaration is only allowed at the top level of a module"
		if is_import { msg = "'import' declaration is only allowed at the top level of a module" }
		report_error_coded(p, .K3022_ModuleSyntaxInScript, msg)
	}

}

parse_block_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)

	if !expect_token(p, .LBrace) {
		return nil
	}

	block, block_stmt := new_stmt(p, BlockStatement)
	block.loc = start
	// Lazy alloc - empty blocks (`{}`) are common as no-op `else` arms,
	// catch-clause bodies, optional method bodies, etc. Defer the bump
	// reservation until we know there's at least one statement.
	if !is_token(p, .RBrace) && !is_token(p, .EOF) {
		// Pre-size: large files have bigger blocks on average.
		block_cap := 8 + (p.source_len >> 16)  // +1 per 64 KB
		block.body = make([dynamic]^Statement, 0, block_cap, p.allocator)
	}

	// A nested block introduces its own StatementList, so the
	// case-clause direct-child constraint no longer applies inside.
	// Also clear module-top-level: import/export are not allowed in blocks.
	prev_in_case_block := p.ctx.in_case_clause
	p.ctx.in_case_clause = false
	defer p.ctx.in_case_clause = prev_in_case_block
	// Track nesting depth for import/export position check.
	p.block_depth += 1
	defer p.block_depth -= 1
	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		prev_offset := int(cur_offset(p))
		stmt := parse_statement_or_declaration(p)
		if stmt != nil {
			bump_append(&block.body, stmt)
		} else if int(cur_offset(p)) == prev_offset {
			report_error_coded(p, .K2040_UnexpectedToken, "Invalid statement in block")
			eat(p)
		}
	}

	if !match_token(p, .RBrace) {
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected '}' at end of block")
	}

	block.loc.end = prev_end_offset(p)
	// §14.2.1 — inline lex/var clash check on this block's body.
	// is_block_scope=true: BlockStatement is its own lexical scope and
	// sloppy plain FunctionDeclarations follow Annex B.3.2. Two callers
	// §14.2.1 — scope check. When scope_fn_scope_next_block is set, the
	// block is being parsed as a function-scope body (arrow block body
	// per §15.3.1 or static block body per §15.7.5). In function scope,
	// var+function coexistence is legal, so use is_block_scope=false.
	is_block := !p.scope_fn_scope_next_block
	p.scope_fn_scope_next_block = false
	parser_scope_check(p, block.body[:], is_block)
	return block_stmt
}

parse_empty_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p)

	empty, empty_s := new_stmt(p, EmptyStatement)
	empty.loc = start
	empty.loc.end = prev_end_offset(p)
	return empty_s
}

parse_expression_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)

	// §12.6 - reserved words used as IdentifierReferences. When a
	// reserved keyword appears at statement position followed by `=`
	// (assignment operator), the intent is `keyword = value;` which
	// is always a SyntaxError because reserved words are not valid
	// IdentifierReferences. Test262:
	//   language/keywords/ident-ref-{case,default,delete,in,
	//     instanceof,new,typeof,void}.js
	// We also flag keywords that cannot start any expression at all
	// (`case`, `default`, `extends`, `in`, `instanceof`, etc.)
	// regardless of what follows.
	if is_keyword_not_expression_start(p.cur_type) {
		msg := fmt.tprintf("Unexpected reserved word '%s'", cur_value(p))
		report_error_coded(p, .K2040_UnexpectedToken, msg)
	} else if is_keyword_with_operand(p.cur_type) && is_next_token(p, .Assign) {
		// `delete = 1`, `new = 1`, `typeof = 1`, `void = 1` - the
		// keyword is being used as an assignment target, not as the
		// prefix operator it normally is.
		msg := fmt.tprintf("Unexpected reserved word '%s'", cur_value(p))
		report_error_coded(p, .K2040_UnexpectedToken, msg)
	}

	expr := parse_expression(p)
	if expr == nil {
		return nil
	}

	// Check for labeled statement: identifier:
	if is_token(p, .Colon) {
		#partial switch e in expr {
		case ^BooleanLiteral:
			// `false:`, `true:` - reserved words used as labels.
			// Only Identifiers can be LabelIdentifiers (§14.13.1).
			report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token ':'")
		case ^NullLiteral:
			// `null:` - same rule.
			report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token ':'")
		case ^NumericLiteral:
			// `0:` - numeric literal cannot be a label.
			report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token ':'")
		case ^StringLiteral:
			// `"x":` - string literal cannot be a label.
			report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token ':'")
		case ^ThisExpression:
			// `this:` - keyword cannot be a label.
			report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token ':'")
		case ^RegExpLiteral:
			report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token ':'")
		case ^TemplateLiteral:
			report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token ':'")
		case ^YieldExpression:
			// §14.13.1 — `yield` cannot be used as a LabelIdentifier inside
			// a GeneratorBody. The fixture reaches this branch only at
			// statement position so the check is not confused by
			// `? yield : yield` (ternary colon). Promoted to a structural
			// parse error in generator context: `yield` is a reserved
			// keyword in a GeneratorBody so the labelled-statement form
			// is grammatically impossible there. Outside a generator,
			// `yield:` is parsed but the colon arrival is unexpected
			// (the YieldExpression had no operand), still a parse error.
			if p.ctx.in_generator {
				report_error_coded(p, .K3010_AwaitYieldAsBindingName,
				"'yield' cannot be used as a label identifier in a generator function")
			} else {
				report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token ':'")
			}
		case ^Identifier:
			eat(p) // consume :

			// §13.2 — LabelIdentifier is subject to the same
			// strict-mode reservation as IdentifierReference. In strict
			// mode `yield: 1`, `let: 1`, `eval: 1`, etc. are SyntaxErrors
			// because the LabelIdentifier production is `Identifier` and
			// the Identifier in question is one of the strict-reserved
			if p.ctx.strict_mode {
				if is_eval_or_arguments(e.name) || is_strict_reserved_binding_name(e.name) {
					msg := fmt.tprintf("'%s' cannot be used as a label identifier in strict mode", e.name)
					report_error_coded_span(p, .K3050_StrictModeReserved, u32(e.loc.start), u32(e.loc.start), msg)
				}
			}
			// §12.1.1 — `await` is reserved as a LabelIdentifier in module code.
			if e.name == "await" {
				await_reserved := p.ctx.in_async || p.ctx.in_static_block
				if !await_reserved {
					if st, have := p.force_source_type.(SourceType); have && st == .Module { await_reserved = true }
					else if p.in_module_top_level || p.has_module_syntax { await_reserved = true }
				}
				if await_reserved {
					report_error_coded_span(p, .K3010_AwaitYieldAsBindingName, u32(e.loc.start), u32(e.loc.start), "'await' cannot be used as a label identifier in module / async context")
				}
			}

			labeled := new_node(p, LabeledStatement)
			labeled.loc = start
			labeled.label = LabelIdentifier{
				loc  = e.loc,
				name = e.name,
			}
			// §14.13.1 — duplicate labels within the same function are
			// a SyntaxError. Scan from label_floor (function boundary).
			for i := p.ctx.label_floor; i < len(p.label_stack); i += 1 {
				if p.label_stack[i] == e.name {
					report_error_coded(p, .K2060_DuplicateLabel, fmt.tprintf("Label '%s' has already been declared", e.name))
					break
				}
			}
			bump_append(&p.label_stack, e.name)
			// ECMA-262 §14.8.1 - `continue label` requires the target label
			// to name an IterationStatement (directly or via a chain of
			// LabelledStatements). Decide it eagerly here with a 1-pass
			// lexer-snapshot scan over `Identifier :` chains; nested
			// `continue foo;` inside the body can then check the flag
			// without any retroactive fix-up.
			bump_append(&p.label_is_iteration, label_chain_leads_to_iteration(p))
			p.block_depth += 1
			labeled.body = parse_statement_or_declaration(p)
			p.block_depth -= 1
			pop(&p.label_stack)
			pop(&p.label_is_iteration)
			labeled.loc.end = prev_end_offset(p)
			// ECMA-262 §14.13.1 - LabelledItem : FunctionDeclaration |
			// Statement. Statement excludes LexicalDeclaration,
			// ClassDeclaration, AsyncFunctionDeclaration,
			// GeneratorDeclaration, AsyncGeneratorDeclaration. Annex B.3.2
			// relaxes plain FunctionDeclaration in sloppy script.
			// Inline-check the immediate body kinds; we don't recurse
			// through nested labels here because the iteration-body /
			// if-body / etc. cases handle their own recursion via
			// report_statement_only_position with the right flag.
			if labeled.body != nil {
				#partial switch v in labeled.body^ {
				case ^VariableDeclaration:
					if v != nil {
						// OXC's parser catches const / using / await-using
						// as labeled items; `let` is handled differently by
						// OXC (ASI) so stays gated.
						if v.kind == .Const || v.kind == .Using || v.kind == .AwaitUsing {
							report_error_coded(p, .K3060_SingleStatementContext, "Lexical declaration cannot appear in a single-statement context")
						} else if v.kind == .Let {
							report_error_coded(p, .K3060_SingleStatementContext, "Lexical declaration cannot be a labeled item")
						}
					}
				case ^ClassDeclaration:
					report_error_coded(p, .K3030_ClassDeclarationStructure, "Class declaration cannot appear in a single-statement context")
				case ^FunctionDeclaration:
					if v != nil {
						if v.async || v.generator {
							report_error_coded(p, .K3012_AsyncGeneratorMisplaced,
								"Async / generator function declaration cannot be a labeled item")
						}
						// §14.13.1 — a plain FunctionDeclaration is a valid
						// LabelledItem only under Annex B.3.3, which the spec
						// gates on "NotInClassBody and StrictFormalParameters
						// is not strict". In strict mode the carve-out is
						// removed and \`label: function f() {}\` is a
						if p.ctx.strict_mode {
							report_error_coded(p, .K3051_StrictModeProhibited, "Function declarations cannot be labeled items in strict mode")
						}
					}
				}
			}

			return statement_from(p, labeled)
		}
	}

	expr_stmt, stmt := new_stmt(p, ExpressionStatement)
	expr_stmt.loc = start
	expr_stmt.expression = expr

	// ECMA-262 §12.10 - ExpressionStatement requires a `;` (or ASI). When
	// the next token isn't `;`, isn't preceded by a line terminator, and
	// isn't `}` or EOF, the parser must report a SyntaxError. Test262
	// negative fixtures rely on this:
	//   {1 2} 3                        // S7.9_A10_T8 - missing ; in block
	//   if (false) x = 1 else x = -1   // S7.9_A11_T4 - missing ; before else
	//   //comment\n line comment      // line-terminators - missing ;
	// ASI for `yield\n/regex/` and similar: when the expression statement
	// ends with a line terminator and the next token is `/`, the slash is
	// meant to start a regex on a new line, not continue as division.
	// Re-lex so the next statement parses as a regex literal.
	// `/=` (AssignDiv) is excluded — a regex never starts with `/=`, so
	// the lexer's original AssignDiv classification is always correct
	// even after a line terminator. Re-lexing `x\n/=-1` would turn the
	// AssignDiv into an unterminated regex (test262
	// language/expressions/compound-assignment/div-whitespace.js).
	if p.cur_type == .Div && cur_has_newline(p) {
		if p.lexer != nil {
			relex_as_regex(p.lexer)
			ft := p.lexer.cur
			p.cur_type = ft.kind
		}
	}
	expect_semicolon_or_asi(p)

	expr_stmt.loc.end = prev_end_offset(p)
	return stmt
}

parse_expression_or_labeled_statement :: proc(p: ^Parser) -> ^Statement {
	return parse_expression_statement(p)
}

// Enforce the §13.5 "StatementList accepts only Statement, not
// Declaration" rule for body positions in if / while / for / do-while.
// Per the grammar:
//   Statement does NOT include LexicalDeclaration, ClassDeclaration,
//   AsyncFunctionDeclaration, GeneratorDeclaration,
//   AsyncGeneratorDeclaration.
// Annex B.3.2 grants FunctionDeclaration one narrow carve-out - but
// only in sloppy-mode IfStatement consequent/alternate, never in
// iteration bodies. `allow_plain_function` selects between the two
// cases; callers in loops pass false, if-statement callers pass
// !strict_mode.
report_statement_only_position :: proc(p: ^Parser, stmt: ^Statement, allow_plain_function: bool) {
	if stmt == nil { return }
	#partial switch v in stmt^ {
	case ^VariableDeclaration:
		if v == nil { return }
		if v.kind == .Let || v.kind == .Const || v.kind == .Using || v.kind == .AwaitUsing {
			report_error_coded(p, .K3060_SingleStatementContext,
				"Lexical declaration cannot appear in a single-statement context")
		}
	case ^ClassDeclaration:
		report_error_coded(p, .K3030_ClassDeclarationStructure, "Class declaration cannot appear in a single-statement context")
	case ^FunctionDeclaration:
		if v == nil { return }
		if v.async || v.generator {
			report_error_coded(p, .K3012_AsyncGeneratorMisplaced,
				"Async / generator function declaration cannot appear in a single-statement context")
		}
		// Plain FunctionDeclaration in a single-statement context.
		// Annex B.3.2 web-compat: a sloppy IfStatement consequent /
		// alternate (or a LabelledStatement at StatementListItem level)
		// allows a plain FunctionDeclaration; iteration / with bodies do
		// not. The caller threads the right gate via allow_plain_function:
		//   * if statement consequent / alternate — !p.ctx.strict_mode
		//   * iteration / with body — always false
		//   * label inside iteration / if-body — false (recursive call)
		// The strict-mode case is the test262 cluster
		// language/statements/if/if-decl-*-strict.js etc.
		if !allow_plain_function {
			report_error_coded(p, .K3060_SingleStatementContext, "Function declarations are not allowed in a single-statement context")
		}
	case ^TSInterfaceDeclaration:
		if allow_ts_mode(p) {
			report_error_coded(p, .K4051_TSDeclarationStructure, "Interface declaration cannot appear in a single-statement context")
		}
	case ^TSTypeAliasDeclaration:
		if allow_ts_mode(p) {
			report_error_coded(p, .K4051_TSDeclarationStructure, "Type alias declaration cannot appear in a single-statement context")
		}
	case ^LabeledStatement:
		// Recurse through labels: `label1: label2: function f() {}` in
		// a single-statement position (iteration body, with body, ...)
		// must propagate the check to the innermost LabelledItem. Per
		// §13.5 / §B.3.2 / §B.3.3, a plain FunctionDeclaration is allowed
		// inside LabelledStatement only when the LabelledStatement itself
		// is at StatementListItem position; inside an iteration body, an
		// `if`-body, or a `with`-body the Annex B carve-out does NOT
		// apply - force allow_plain_function = false so the recursive
		// check rejects the inner FunctionDeclaration.
		if v == nil { return }
		report_statement_only_position(p, v.body, false)
	}
}

parse_if_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume if

	if !expect_token(p, .LParen) {
		return nil
	}

	// `if () ;` is a SyntaxError per §14.6 - the IfStatement grammar
	// requires a non-empty Expression in the head. parse_expression
	// returns nil for `)` without diagnosing, so we surface the error
	// here. Test262: language/statements/if/S12.5_A8.js.
	if is_token(p, .RParen) {
		report_error_coded(p, .K2020_ExpectedExpression, "Expected expression in `if` condition")
		eat(p) // consume `)` to keep the parser moving
		return nil
	}
	test := parse_expression(p)
	if test == nil {
		// If the condition expression failed to parse, report an error
		// rather than silently dropping the entire if-statement.
		if !is_token(p, .RParen) {
			report_error_coded(p, .K2020_ExpectedExpression, "Expected expression in 'if' condition")
		}
		return nil
	}
	// Spread/rest is not valid in the if-condition expression.
	if expr_contains_spread(test) {
		report_error_coded(p, .K3042_RestSpreadMisuse, "Unexpected spread/rest element in expression")
	}

	if !expect_close_paren_or_recover(p) {
		return nil
	}

	p.block_depth += 1
	consequent := parse_statement_or_declaration(p)
	p.block_depth -= 1
	if consequent == nil {
		report_error_coded(p, .K2022_ExpectedStatementBody, "Expected statement after 'if' condition")
	}
	report_statement_only_position(p, consequent, !p.ctx.strict_mode)

	if_, if__s := new_stmt(p, IfStatement)
	if_.loc = start
	if_.test = test
	if_.consequent = consequent

	if match_token(p, .Else) {
		p.block_depth += 1
		alt := parse_statement_or_declaration(p)
		p.block_depth -= 1
		if alt == nil {
			report_error_coded(p, .K2022_ExpectedStatementBody, "Expected statement after 'else'")
		}
		report_statement_only_position(p, alt, !p.ctx.strict_mode)
		if_.alternate = alt
	}

	// Note: detecting a *duplicate* `else` from here isn't safe - after an
	// inner if/else completes, the outer `else` (dangling-else rule) is a
	// valid continuation, and parse_if_statement can't see the outer
	// context. The stray-else case (`if (x) {} else {} else {}` at the
	// same nesting level) is caught by the top-level statement loop's
	// unknown-token recovery instead.

	if_.loc.end = prev_end_offset(p)
	return if__s
}

parse_while_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume while

	if !expect_token(p, .LParen) {
		return nil
	}

	test := parse_expression(p)
	if test == nil {
		return nil
	}

	if !expect_close_paren_or_recover(p) {
		return nil
	}

	prev_in_loop := p.ctx.in_loop
	p.ctx.in_loop = true
	p.block_depth += 1
	body := parse_statement_or_declaration(p)
	p.block_depth -= 1
	p.ctx.in_loop = prev_in_loop
	if body == nil {
		report_error_coded(p, .K2022_ExpectedStatementBody, "Expected statement after 'while' condition")
	}
	report_statement_only_position(p, body, false)

	while_, while__s := new_stmt(p, WhileStatement)
	while_.loc = start
	while_.test = test
	while_.body = body
	while_.loc.end = prev_end_offset(p)

	return while__s
}

parse_do_while_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume do

	prev_in_loop := p.ctx.in_loop
	p.ctx.in_loop = true
	p.block_depth += 1
	body := parse_statement_or_declaration(p)
	p.block_depth -= 1
	p.ctx.in_loop = prev_in_loop
	report_statement_only_position(p, body, false)

	if !expect_token(p, .While) {
		return nil
	}

	if !expect_token(p, .LParen) {
		return nil
	}

	test := parse_expression(p)
	if test == nil {
		return nil
	}

	// do-while: `)` precedes `;` (not `{`). In TS sloppy mode, also
	// recover when `;`, `}`, or EOF follows (the `)` was consumed by
	// a nested expression like `(a1 > 5)` in the while condition).
	if p.cur_type == .RParen {
		eat(p)
	} else if allow_ts_mode(p) && !p.ctx.strict_mode && (p.cur_type == .Semi || p.cur_type == .RBrace ||
	          p.cur_type == .EOF || p.cur_type == .LBrace) {
		// Silently recover.
	} else {
		if !expect_token(p, .RParen) {
			return nil
		}
	}

	match_token(p, .Semi) // Optional semicolon

	do_, do__s := new_stmt(p, DoWhileStatement)
	do_.loc = start
	do_.body = body
	do_.test = test
	do_.loc.end = prev_end_offset(p)

	return do__s
}

// parse_for_await_validate enforces the ECMA-262 §14.7.5 context restriction
// for a `for await` head: it is valid only inside an async function/generator
// body or at module top level, and never inside a class static block. Pure
// validation — emits diagnostics, consumes no tokens. Extracted from
// parse_for_statement to keep the for-head disambiguation readable.
parse_for_await_validate :: proc(p: ^Parser) {
	// TS18038 — `for await` inside a class static block is always
	// invalid, even when the block is nested inside an async function.
	if p.ctx.in_static_block {
		report_error_coded(p, .K3013_ForAwaitContextRestricted,
			"'for await' loops cannot be used inside a class static block")
	} else if !p.ctx.in_async {
		if p.ctx.in_function {
			report_error_coded(p, .K3013_ForAwaitContextRestricted,
				"'for await' is only valid in async functions or at the top level of a module")
		} else if allow_ts_mode(p) {
			// TS files: top-level `for await` is allowed — tsc and OXC
			// defer module-detection concerns to the type checker.
		} else if st, have := p.force_source_type.(SourceType); have && st == .Script {
			// Explicitly forced Script mode - reject unconditionally.
			report_error_coded(p, .K3013_ForAwaitContextRestricted,
				"Top-level 'for await' is only valid in module code")
		} else if !have {
			// Auto-detect: lazy pre-scan resolves whether the file is
			// a module before deciding. On files without import/export,
			// has_module_syntax stays false and we reject as Script.
			ensure_module_syntax_resolved(p)
			if !p.has_module_syntax {
				report_error_coded(p, .K3013_ForAwaitContextRestricted,
					"Top-level 'for await' is only valid in module code")
			}
		}
	}
}

// for_head_let_starts_decl reports whether a `let` at the for-head opens a
// ForDeclaration (§14.7.4 / §14.7.5). `let` is only a lexical-binding keyword
// when followed by `[`, `{`, or a BindingIdentifier; otherwise it is an
// IdentifierReference (`for (let in obj)`, `for (let.x in obj)`, ...). Consumes
// no tokens.
for_head_let_starts_decl :: proc(p: ^Parser) -> bool {
	if !is_token(p, .Let) { return false }
	nxt := peek_token(p)
	// Conservative whitelist of tokens that legally start a
	// LexicalBinding after `let`. Anything else falls through to
	// the expression-head path. is_identifier_like_token covers
	// every contextual keyword that's also a valid binding name
	// (`assert`, `abstract`, `declare`, ... plus the JS contextuals).
	return nxt.type == .LBracket || nxt.type == .LBrace ||
	       is_identifier_like_token(nxt.type)
}

// for_head_using_starts_decl reports whether a `using` at the for-head opens a
// using-declaration vs. an IdentifierReference. Mirrors the `let` rule, with an
// extra 3-token lookahead to disambiguate `for (using of ...)` plus a §12.7.2
// escaped-keyword check on the binding name. Consumes no tokens (every snapshot
// is restored); may emit K3015 for an escaped `of` binding name.
for_head_using_starts_decl :: proc(p: ^Parser) -> bool {
	if !is_token(p, .Using) { return false }
	result := false
	nxt_u := peek_token(p)
	// `for (using of ...)` is ambiguous: `of` after `using` can be
	// (a) the for-of keyword → LHS expression `using` of `iterable`,
	//     e.g. `for (using of of [])`, or
	// (b) a binding name `of` in a C-style for-init using-decl,
	//     e.g. `for (using of = reader();;)`.
	// Disambiguate with 3-token lookahead: if the token AFTER `of`
	// is `=` (initialiser), `,` (next declarator), `:` (TS type
	// annotation), or `;` (end of for-init), then `of` is a binding
	// name. Otherwise it's the for-of keyword.
	if nxt_u.type == .Of && !nxt_u.had_line_terminator {
		snap := lexer_snapshot(p)
		advance_token(p) // consume `using` → cur=`of`
		advance_token(p) // consume `of`    → cur=token after `of`
		after_of := p.cur_type
		lexer_restore(p, snap)
		result = after_of == .Assign || after_of == .Comma ||
		         after_of == .Semi || after_of == .Colon
	} else {
		result = (nxt_u.type == .Identifier || can_be_binding_identifier(nxt_u.type)) &&
		         !nxt_u.had_line_terminator
		// Escaped `of` identifier (`o\u0066`): ECMA-262 §12.7.2 says
		// keywords must not contain Unicode escapes. When the binding
		// name is an escaped-identifier whose cooked value is "of",
		// reject it — matches OXC / V8 behaviour.
		// Check by decoding the raw source span: if the nxt token has
		// an escape and its span is 2 chars wide when decoded to "of",
		// the identifier is an escaped keyword.
		ensure_nxt(p)
		if result && nxt_u.type == .Identifier &&
		   (p.lexer.nxt.flags & FLAG_HAS_ESCAPE) != 0 {
			// Read cooked value: advance into the token, check, restore.
			snap_u := lexer_snapshot(p)
			advance_token(p) // consume `using` → cur = escaped ident
			cooked_is_of := cur_value_eq(p, "of")
			lexer_restore(p, snap_u)
			if cooked_is_of {
				report_error_coded(p, .K3015_KeywordContainsEscape, "Keywords cannot contain escape characters")
			}
		}
	}
	return result
}

parse_for_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume for

	await := match_token(p, .Await)

	// ECMA-262 §14.7.5 - `for await (...)` is only valid where an
	// AwaitExpression would be: inside an AsyncFunctionBody /
	// AsyncGeneratorBody, or at Module top level. We track the same
	// predicate used for bare `await`: in_async allows it inside any
	// async function/generator; outside a function AND with module-
	// syntax auto-detection enabled, top-level await would be lifted,
	// but `for await` at script top-level is still invalid. Mirror the
	// plain-await rules.
	if await {
		parse_for_await_validate(p)
	}

	if !expect_token(p, .LParen) {
		return nil
	}

	// Check for for-in/for-of vs regular for
	// We need to look ahead to determine which type of for loop this is
	// Look for 'in' or 'of' after the left side

	left_expr: ^Expression
	left_decl: ^VariableDeclaration

	// §14.7.4 / §14.7.5 - in a for-head, `let` is only a ForDeclaration
	// keyword when followed by a BindingIdentifier / `[` / `{`. Per the
	// `[lookahead ∉ { let [ }]` rule and Acorn / V8 / OXC behaviour,
	// `for (let in obj)`, `for (let.x in obj)`, `for (let + 1; ...)` all
	// treat `let` as an IdentifierReference. Kessel was unconditionally
	// committing to a let-declaration, breaking those programs.
	let_starts_decl := for_head_let_starts_decl(p)
	// `using` in a for-head follows the same BindingIdentifier rule:
	// `for (using of of)` → expression; `for (using x of ...)` → decl.
	using_starts_decl := for_head_using_starts_decl(p)
	await_using_for_decl := false
	if is_token(p, .Await) && peek_token(p).type == .Using {
		using_after_await := peek_token(p)
		if using_after_await.had_line_terminator {
			report_error_coded(p, .K3014_AwaitUsingContextRestricted,
				"Line terminator not permitted between 'await' and 'using'")
		}
		await_using_for_decl = await_using_starts_decl(p)
	}
	// A using/await-using declaration in a for-init is NOT directly
	// inside the case clause, so clear the flag before parsing.
	prev_case_clause := p.ctx.in_case_clause
	p.ctx.in_case_clause = false
	defer p.ctx.in_case_clause = prev_case_clause

	if is_token(p, .Var) || (is_token(p, .Let) && let_starts_decl) || is_token(p, .Const) ||
	   (is_token(p, .Using) && using_starts_decl) || await_using_for_decl {
		// Variable declaration - parse it. parse_variable_declaration returns a
		// ^Statement union wrapping a ^VariableDeclaration; extract the inner
		// variant via type assertion. Prior code transmuted the union pointer
		// directly into a ^VariableDeclaration, reading the Statement union's
		// header bytes as if they were VariableDeclaration fields - same UB
		// class as Bug H. Symptom: the for-in/of emit would later cast back
		// via `(^Statement)(decl)` and dereference garbage, crashing deep
		// inside class method bodies (latent because class body emit was
		// previously a stub). left_expr was also transmuted here, but that
		// branch is dead - downstream only reads left_expr when left_decl is
		// nil, which never happens in this arm.
		// no_in gates `in` as a binary operator inside the declarator init
		// (§13.15.5 / §14.7.4). Without it `for (var x = 1 in y)` parses
		// the init as `1 in y` and the parser then expects a `;`. With
		// no_in, the init stops at `1`, the outer for-statement sees `in`,
		// and the Annex B.3.5 carve-out (sloppy-mode `for (var Id = init
		// in Expr)`) becomes reachable. Parenthesised sub-expressions
		// reset no_in inside the parens, so `for (var x = (a in b); ...)`
		// keeps working.
		prev_no_in := p.ctx.no_in
		p.ctx.no_in = true
		decl_stmt := parse_variable_declaration(p, nil, false, true)
		p.ctx.no_in = prev_no_in
		if decl_stmt != nil {
			if vd, ok := decl_stmt^.(^VariableDeclaration); ok {
				left_decl = vd
				// `for (var of of)` — `var of` as a declaration + `of` as
				// for-of keyword is ambiguous. `for (var of of of)` is OK
				// (3 `of`s: binding, keyword, iterator). Detect: single
				// declarator `of` with no init, `of` keyword, `)` iterator.
				if vd.kind == .Var && len(vd.declarations) == 1 && is_token(p, .Of) {
					d0 := vd.declarations[0]
					if ident, id_ok := d0.id.(^Identifier); id_ok && ident.name == "of" {
						if _, has_init := d0.init.(^Expression); !has_init {
							// Peek past the for-of `of` to see if `)` follows.
							if p.lexer != nil { ensure_nxt(p) }
						if p.lexer != nil && p.lexer.nxt.kind == .RParen {
								report_error_coded(p, .K2040_UnexpectedToken, "'for (var of of)' is ambiguous")
							}
						}
					}
				}
			}
		}
	} else if !is_token(p, .Semi) {
		// Special case: `for (await of ...)` in script mode - `await` is
		// an IdentifierReference used as the for-of LHS, not an
		// AwaitExpression. Detect by checking that next token is `of`.
		// Also match escaped `o\u0066` (lexed as .Identifier with cooked
		// value "of") — ECMA-262 §13.7.5.1 uses the StringValue of
		// the token, which resolves the escape. OXC and V8 agree.
  ensure_nxt(p)
		nxt_is_of := p.lexer != nil && p.lexer.nxt.kind == .Of
		// Also match escaped `o\u0066`: lexed as .Identifier, cooked to "of".
		if !nxt_is_of && p.lexer != nil {
			ensure_nxt(p)
		}
		if !nxt_is_of && p.lexer != nil &&
		   p.lexer.nxt.kind == .Identifier &&
		   (p.lexer.nxt.flags & FLAG_HAS_ESCAPE) != 0 {
			snap := lexer_snapshot(p)
			advance_token(p) // consume `await` → cur = escaped-of
			nxt_is_of = cur_value_eq(p, "of")
			lexer_restore(p, snap)
		}
		if is_token(p, .Await) && !p.ctx.in_async && nxt_is_of {
			cur := snap_current(p)
			id, id_e := new_expr(p, Identifier)
			id.loc = loc_from_token(&cur); id.name = cur.value
			eat(p)
			left_expr = id_e
		} else {
			// Parse as full expression (including comma) but stop at 'in'/'of'.
			// The no_in flag prevents 'in' from being consumed as binary operator.
			p.ctx.no_in = true
			left_expr = parse_expr_with_prec(p, .Comma)
			p.ctx.no_in = false
		}
	}

	// Escaped `of` keyword: `o\u0066` → .Identifier with cooked value
	// "of" and has_escape=true. OXC rejects as "Keywords cannot contain
	// escape characters".
	if p.cur_type == .Identifier && cur_has_escape(p) && cur_value_eq(p, "of") {
		report_error_coded(p, .K3015_KeywordContainsEscape, "Keywords cannot contain escape characters")
	}
	// Now check if this is for-in, for-of, or regular for
	if is_token(p, .In) || is_token(p, .Of) {
		// for-in or for-of
		is_in := is_token(p, .In)
		// §15.8.2 - `for await` is only legal with `of`, never `in`.
		if is_in && await {
			report_error_coded(p, .K3011_AwaitYieldExpressionContextRestricted, "'await' can only be used in conjunction with 'for...of' statements")
		}
		eat(p) // consume in/of
		// `for (x of /re/) {}` - after consuming the `of` keyword the next
		// token is the iterator expression. A leading `/` is the start of
		// a RegularExpressionLiteral here, but the lexer already classified
		// it as `.Div` because `.Of` is no longer in can_start_regex (would
		// otherwise mis-lex `var of=6; of/g/h;`). Relex on demand.
		if p.cur_type == .Div || p.cur_type == .AssignDiv {
			if p.lexer != nil {
				relex_as_regex(p.lexer)
				ft := p.lexer.cur
				p.cur_type = ft.kind
			}
		}

		// ECMA-262 §14.7.5.1 - for-in/of LeftHandSideExpression must have a
		// simple AssignmentTargetType. `a = 1` is an AssignmentExpression,
		// not a LeftHandSideExpression, so `for (a = 1 in b)` and
		// `for (a = 1 of b)` are both SyntaxErrors. The one historical
		// exception is Annex B.3.5: `for (var X = init in Expr) ...` (sloppy
		// mode, `var` only, `in` only - never `of`, never strict, never
		// `let`/`const`). Declarations carry their initializer on
		// VariableDeclarator.init, not as an AssignmentExpression wrapper,
		// so the Annex B case naturally reaches this point via `left_decl`
		// and bypasses the error.
		if left_expr != nil {
			if ae, is_ae := left_expr.(^AssignmentExpression); is_ae && ae != nil {
				kind_name := "of"
				if is_in { kind_name = "in" }
				msg := fmt.tprintf("Invalid left-hand side in for-%s loop", kind_name)
				report_error_coded(p, .K2050_InvalidLHS, msg)
			}
			// §14.7.5.1 - the LHS of a for-of head cannot be the literal
			// IdentifierReference `async` (avoids ambiguity with the
			// CoverCallExpressionAndAsyncArrowHead production: `async of xs`
			// is otherwise indistinguishable from `async (of xs)`). Per spec,
			// the rule is a source-text lookahead `[lookahead ∉ { async of }]`,
			// so it doesn't fire when `async` is escaped (`\u0061sync`) or
			// parenthesized (`(async)`). It also doesn't fire for
			// for-await-of (`for await (async of xs)` is legal).
			if !is_in && !await {
				if id, ok := left_expr.(^Identifier); ok && id != nil && id.name == "async" {
					// Source-text lookahead: only the bare unescaped `async`
					// identifier triggers. Detect escapes by scanning the raw
					// slice. Detect parens by looking FORWARD from the
					// identifier's end to the next non-whitespace byte: a `)`
					// there means the identifier was the body of a
					// CoverParenthesizedExpression (`(async)`), so the
					// lookahead doesn't fire. A backward-walk to `(` would
					// false-positive on the for-head's own opening paren.
					span_start := id.loc.start
					span_end := id.loc.end
					has_escape := false
					paren_wrapped := false
					if p.lexer != nil && int(span_end) <= len(p.lexer.source_bytes) {
						slice := p.lexer.source_bytes[span_start:span_end]
						for b in slice { if b == '\\' { has_escape = true; break } }
						i := int(span_end)
						src_len := len(p.lexer.source_bytes)
						for i < src_len {
							ch := p.lexer.source_bytes[i]
							if ch == ')' { paren_wrapped = true; break }
							if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { i += 1; continue }
							break
						}
					}
					if !has_escape && !paren_wrapped {
						report_error_coded(p, .K3012_AsyncGeneratorMisplaced,
							"The left-hand side of a for-of loop may not be 'async'")
					}
				}
			}
			// §14.7.5.1 - the LHS of a for-of head cannot start with
			// `let` (avoids ambiguity with `for (let x of ...)` which is
			// a for-of with a LetDeclaration). `for (let.foo of [])`,
			// `for (let().bar of [])` etc. are all SyntaxErrors.
			if !is_in {
				let_lhs := false
				if id, ok := left_expr.(^Identifier); ok && id != nil && id.name == "let" {
					let_lhs = true
				} else if mem, ok2 := left_expr.(^MemberExpression); ok2 && mem != nil {
					// `let.foo` or `let().bar` — check if the root is `let`.
					root := left_expr
					for {
						if m, ok3 := root.(^MemberExpression); ok3 && m != nil {
							root = m.object
						} else if c, ok4 := root.(^CallExpression); ok4 && c != nil {
							root = c.callee
						} else if t, ok5 := root.(^TaggedTemplateExpression); ok5 && t != nil {
							root = t.tag
						} else {
							break
						}
					}
					if rid, ok3 := root.(^Identifier); ok3 && rid != nil && rid.name == "let" {
						let_lhs = true
					}
				}
				if let_lhs {
					report_error_coded(p, .K3061_ForLoopLHS, "The left-hand side of a for-of loop may not start with 'let'")
				}
			}
			// §14.7.5.1 - the LHS expression must have a valid
			// AssignmentTargetType. `for (this of [])`, `for (1 of [])`,
			// `for ((a + b) of [])` are all SyntaxErrors. is_destructure
			// is true so Array / Object literals reinterpret as patterns.
			// CallExpression is allowed in sloppy script (§Annex B.3.4) and
			// the more general AssignmentTargetType handles the rest.
			if _, is_ae := left_expr.(^AssignmentExpression); !is_ae {
				if !is_valid_assignment_target(left_expr, true) {
					kind_name := "of"
					if is_in { kind_name = "in" }
					msg := fmt.tprintf("Invalid left-hand side in for-%s loop", kind_name)
					report_error_coded(p, .K2050_InvalidLHS, msg)
				}
				// CallExpression as for-in/of LHS in strict mode is
				// rejected by the semantic checker
				// (ck_check_for_in_of_head).
			}
			// §13.7.5.1 strict-mode eval/arguments as for-in/of LHS is
			// rejected by the semantic checker
			// (ck_check_for_in_of_init_eval_args).
			_ = left_expr
			// for-in/of LHS is an AssignmentTarget; when it's an object /
			// array literal it reinterprets as a destructuring pattern
			// (§13.15.5.2). Run expr_to_pattern to trigger the same
			// CoverInitializedName clearing path the regular
			// AssignmentExpression uses, so `for ({x = 1} of [{}])` stops
			// reporting "Invalid shorthand property initializer". Gate on
			// is_destructure_target_candidate so Annex B.3.4 `for (f() in x)`
			// in sloppy mode doesn't trip the pattern-walker's error arm.
			// TS2491 — for-in LHS cannot be a destructuring pattern in TS.
			// Check BEFORE expr_to_pattern so the LHS is still an
			// ArrayExpression / ObjectExpression. The ES spec allows it,
			// but TypeScript's compiler rejects it (TS2491).
			if is_in && allow_ts_mode(p) && is_destructure_target_candidate(left_expr) {
				report_error_coded(p, .K2040_UnexpectedToken, "The left-hand side of a 'for...in' statement cannot be a destructuring pattern.")
			}
			if is_destructure_target_candidate(left_expr) {
				_, _ = expr_to_pattern(p, left_expr)
			}
		}

		// ECMA-262 Annex B.3.5 gate. A VariableDeclaration in a for-in/of
		// head normally forbids initializers, but sloppy-mode `for (var
		// BindingIdentifier = AssignmentExpression in Expr) Statement`
		// survives for web-compat. Every other combination - strict mode,
		// `let`/`const`/`using`, for-of, multiple declarators, a
		// destructuring pattern, even a single declarator where the
		// binding is a BindingPattern - is a SyntaxError per the core
		// grammar restriction "It is a Syntax Error if DeclarationPart of
		// ForDeclaration has an Initializer."
		// Core grammar also only allows a SINGLE ForBinding /
		// ForDeclaration in the for-in/of head - no comma-list - so even
		// init-free `for (var x, y in z)` is a SyntaxError.
		if left_decl != nil {
			// §13.7.5.1 — `using` / `await using` is permitted only in
			// for-of heads (not for-in), which is a parse-time constraint.
			if is_in && (left_decl.kind == .Using || left_decl.kind == .AwaitUsing) {
				kn := "using"
				if left_decl.kind == .AwaitUsing { kn = "await using" }
				msg := fmt.tprintf("'%s' declaration is not allowed in a for-in loop", kn)
				report_error_coded(p, .K3061_ForLoopLHS, msg)
			}

			// TS2491 — for-in LHS cannot be a destructuring pattern in TS.
			// The ES spec allows ForBinding :: BindingPattern in for-in,
			// but TypeScript rejects it. Only fire in TS mode to avoid
			// breaking test262.
			if is_in && allow_ts_mode(p) && len(left_decl.declarations) >= 1 {
				d_id := left_decl.declarations[0].id
				is_pattern := false
				if _, ok := d_id.(^ArrayPattern); ok { is_pattern = true }
				if _, ok := d_id.(^ObjectPattern); ok { is_pattern = true }
				if is_pattern {
					report_error_coded_span(p, .K2040_UnexpectedToken, u32(left_decl.loc.start), u32(left_decl.loc.start), "The left-hand side of a 'for...in' statement cannot be a destructuring pattern.")
				}
			}

			// §13.7.5.1 — "only a single declarator" + "no initializer"
			// rules.
			// clusters.
			// Annex B.3.5 web-compat carve-out: a sloppy-mode
			// `for (var SimpleIdentifier = Expr in Expr) Statement` is
			// legal. Every other combination is a SyntaxError:
			//   * for-of always rejects init.
			//   * Strict mode for-in rejects init.
			//   * `let` / `const` / `using` / `await using` always reject.
			//   * Multiple declarators (`for (var a, b of x)`) always
			//     reject regardless of init.
			//   * Destructuring pattern + init always rejects.
			kind_str := "of"
			if is_in { kind_str = "in" }
			if len(left_decl.declarations) > 1 {
				msg := fmt.tprintf("Only a single declaration is allowed in a for-%s loop", kind_str)
				report_error_coded_span(p, .K3061_ForLoopLHS, u32(left_decl.loc.start), u32(left_decl.loc.start), msg)
			} else {
				annex_b_ok := is_in && !p.ctx.strict_mode &&
				              left_decl.kind == .Var &&
				              len(left_decl.declarations) == 1
				if annex_b_ok {
					if _, is_id := left_decl.declarations[0].id.(^Identifier); !is_id {
						annex_b_ok = false
					}
				}
				if !annex_b_ok {
					for d in left_decl.declarations {
						if _, have_init := d.init.(^Expression); have_init {
							msg := fmt.tprintf("for-%s loop variable declaration may not have an initializer", kind_str)
							report_error_coded_span(p, .K3061_ForLoopLHS, u32(left_decl.loc.start), u32(left_decl.loc.start), msg)
							break // one diagnostic per head, matching the checker
						}
					}
				}
			}

			// TS2404 — type annotation on for-in/of variable.
			// "The left-hand side of a 'for...in' statement cannot
			// use a type annotation."
			if allow_ts_mode(p) && len(left_decl.declarations) > 0 {
				d := left_decl.declarations[0]
				has_type_ann := false
				#partial switch b in d.id {
				case ^Identifier:  if b != nil { has_type_ann = b.type_annotation != nil }
				case ^ObjectPattern: if b != nil { has_type_ann = b.type_annotation != nil }
				case ^ArrayPattern:  if b != nil { has_type_ann = b.type_annotation != nil }
				}
				if has_type_ann {
					msg := fmt.tprintf("The left-hand side of a 'for...%s' statement cannot use a type annotation.", kind_str)
					report_error_coded_span(p, .K3061_ForLoopLHS, u32(left_decl.loc.start), u32(left_decl.loc.start), msg)
				}
			}
		}

		// §14.7.5 - for-in head accepts the full Expression (comma list
		// allowed); for-of head accepts AssignmentExpression only. Picking
		// the wrong production silently accepts `for (let x of [], [])`.
		right: ^Expression
		if is_in {
			right = parse_expression(p)
		} else {
			right = parse_assignment_expression(p)
		}
		if right == nil {
			return nil
		}

		if !expect_token(p, .RParen) {
			// Error recovery: skip to closing ) for malformed for-in/of
			for !is_token(p, .RParen) && !is_token(p, .EOF) {
				recovery_eat(p)
			}
			match_token(p, .RParen)
		}

		prev_in_loop := p.ctx.in_loop
		p.ctx.in_loop = true
		// Increment block_depth so import/export inside a for-in/of single-
		// statement body are rejected as nested positions (§16.2.1).
		p.block_depth += 1
		body := parse_statement_or_declaration(p)
		p.block_depth -= 1
		p.ctx.in_loop = prev_in_loop
		if body == nil {
			report_error_coded(p, .K2022_ExpectedStatementBody, "Expected statement after for-in/of head")
		}
		report_statement_only_position(p, body, false)

		if is_in {
			// for-in - use separate fields for declaration vs expression
			for_in, for_in_s := new_stmt(p, ForInStatement)
			for_in.loc = start
			if left_decl != nil {
				for_in.left_decl = left_decl
			} else {
				for_in.left_expr = left_expr
			}
			for_in.right = right
			for_in.body = body
			for_in.loc.end = prev_end_offset(p)
			return for_in_s
		} else {
			// for-of or for-await-of - use separate fields
			for_of, for_of_s := new_stmt(p, ForOfStatement)
			for_of.loc = start
			if left_decl != nil {
				for_of.left_decl = left_decl
			} else {
				for_of.left_expr = left_expr
			}
			for_of.right = right
			for_of.body = body
			for_of.await = await
			for_of.loc.end = prev_end_offset(p)
			return for_of_s
		}
	}

	// Regular for statement: for (init; test; update)
	// Track init as either declaration or expression
	init_decl: Maybe(^VariableDeclaration)
	init_expr: Maybe(^Expression)
	if left_decl != nil {
		init_decl = left_decl
	} else if left_expr != nil {
		init_expr = left_expr
	}

	if init_decl != nil {
		id, have_init := init_decl.(^VariableDeclaration)
		if have_init && id != nil {
			if id.kind == .Using || id.kind == .AwaitUsing {
				for decl in id.declarations {
					if _, have := decl.init.(^Expression); !have {
						report_error_coded(p, .K2070_RequiredFormOrBinding, "Using declarations must have an initializer")
					}
				}
			}
		}
	}

	if !expect_token(p, .Semi) {
		return nil
	}

	test: Maybe(^Expression)
	if !is_token(p, .Semi) {
		// Use Comma precedence to allow comma operator in test
		test = parse_expr_with_prec(p, .Comma)
	}

	if !expect_token(p, .Semi) {
		return nil
	}

	update: Maybe(^Expression)
	if !is_token(p, .RParen) {
		// Use Comma precedence to allow comma operator in update
		update = parse_expr_with_prec(p, .Comma)
	}

	if !expect_token(p, .RParen) {
		return nil
	}

	prev_in_loop := p.ctx.in_loop
	p.ctx.in_loop = true
	p.block_depth += 1
	body := parse_statement_or_declaration(p)
	p.block_depth -= 1
	p.ctx.in_loop = prev_in_loop
	if body == nil {
		report_error_coded(p, .K2022_ExpectedStatementBody, "Expected statement after for head")
	}
	report_statement_only_position(p, body, false)

	// `for await (;;)` / `for await (let i=0;;)` - await is only valid
	// with for-of, not regular for-statements.
	if await {
		report_error_coded(p, .K3011_AwaitYieldExpressionContextRestricted, "'await' can only be used in conjunction with 'for...of' statements")
	}

	for_, for__s := new_stmt(p, ForStatement)
	for_.loc = start
	for_.init_decl = init_decl
	for_.init_expr = init_expr
	for_.test = test
	for_.update = update
	for_.body = body
	for_.loc.end = prev_end_offset(p)

	return for__s
}

parse_return_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume return

	// ECMA-262 §14.10.1 Static Semantics: a `return` statement is only
	// valid inside a function/method body. OXC, Acorn, and Babel all
	// reject top-level `return`; we match (previously this was a deliberate
	// no-op, with the comment citing "imperfect nested tracking" - that
	// tracking has since been fixed as part of the async-arrow work, so
	// the check is safe to enable). The 467-file real-world corpus is
	// CommonJS-wrapped (`function(...){ return ... }`) so `in_function` is
	// true at every natural `return` site; bare top-level `return` only
	// shows up in spec-negative fixtures and mutated fuzz cases.
	if !p.ctx.in_function && !p.is_commonjs && !p.ctx.in_ambient {
		report_error_coded(p, .K2040_UnexpectedToken, "'return' outside of function")
	}
	// §15.7.5 ClassStaticBlockBody is parsed under [~Return]; the
	// outer in_function is set to true so new.target works, but a
	// literal `return` is forbidden by the grammar parameter.
	if p.ctx.in_static_block {
		report_error_coded(p, .K3031_StaticBlockOrFieldInitRestriction, "'return' is not allowed in a class static block")
	}

	argument: Maybe(^Expression)
	// ECMA-262 §12.10 Restricted Production: `return` followed by a
	// LineTerminator triggers ASI - the argument belongs to the NEXT
	// statement, not to this return. Check had_line_terminator on the
	// current token BEFORE deciding whether to parse an argument.
	if !is_token(p, .Semi) && !is_token(p, .RBrace) && !is_token(p, .EOF) && !cur_has_newline(p) {
		argument = parse_expression(p)
	}

	match_semicolon_or_asi(p)

	ret, ret_s := new_stmt(p, ReturnStatement)
	ret.loc = start
	ret.argument = argument
	ret.loc.end = prev_end_offset(p)

	return ret_s
}

// Linear scan of the in-function slice of p.label_stack. The stack is
// small in practice (nested-label depth is almost always 0-2 in real
// code), so the O(N) lookup beats any hash overhead. Only labels at or
// above `label_floor` are visible - labels below belong to enclosing
// functions and don't cross function boundaries.
label_in_scope :: proc(p: ^Parser, name: string) -> bool {
	for i := p.ctx.label_floor; i < len(p.label_stack); i += 1 {
		if p.label_stack[i] == name { return true }
	}
	return false
}

// `continue label` (ECMA-262 §14.8.1) requires `label` to name an
// IterationStatement that is ContainedIn the enclosing function. We track
// that per-label via `label_is_iteration`, parallel to `label_stack`, so
// this helper is just `label_in_scope` gated on the iteration bit.
label_iter_in_scope :: proc(p: ^Parser, name: string) -> bool {
	for i := p.ctx.label_floor; i < len(p.label_stack); i += 1 {
		if p.label_stack[i] == name { return p.label_is_iteration[i] }
	}
	return false
}

// Peek at the current (post-colon) token position to determine whether a
// LabelledStatement's label will ultimately precede an IterationStatement.
// Chases through any chain of `Identifier :` labels. Uses a lexer snapshot
// so the caller's parse state is unchanged. Covers:
//   `foo: for (...)`                 → true
//   `foo: while (...)` / `foo: do`   → true
//   `foo: bar: for (...)`            → true (outer + inner both)
//   `foo: { ... }`                   → false
//   `foo: if (x) ...`                → false
//   `foo: function () {}`            → false
label_chain_leads_to_iteration :: proc(p: ^Parser) -> bool {
	snap := lexer_snapshot(p)
	defer lexer_restore(p, snap)
	for {
		#partial switch p.cur_type {
		case .For, .While, .Do:
			return true
		case .Identifier, .Get, .Set, .From, .Of, .As, .Let, .Static,
		     .Assert, .Asserts, .Abstract, .Declare, .Readonly, .Override,
		     .Keyof, .Infer, .Is, .Satisfies, .Never, .Unique, .Namespace,
		     .Module, .Implements, .Require, .Package, .Private, .Protected,
		     .Public, .Accessor, .Target, .Await, .Yield, .Async, .Type:
			// A potential chained label: only treat as such when the very
			// next token is `:`. Otherwise we've reached an ordinary
			// expression / identifier-statement body - not iteration.
			if p.lexer == nil { return false }
			ensure_nxt(p)
			if p.lexer.nxt.kind != .Colon { return false }
			eat(p) // consume identifier
			eat(p) // consume colon
		case:
			return false
		}
	}
}

parse_break_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume break

	label: Maybe(LabelIdentifier)
	label_loc: LexerLoc
	// Label only if on same line (no LineTerminator between break and identifier)
	if is_token(p, .Identifier) && !cur_has_newline(p) {
		// LabelIdentifier is an Identifier position - escaped ReservedWord
		// (e.g. `break \u0069f;`) is a Syntax Error (§12.7.2).
		report_escaped_reserved_word(p)
		lbl_loc := cur_loc(p)
		label_loc = LexerLoc(lbl_loc.start)
		label = LabelIdentifier{
			loc  = lbl_loc,
			name = cur_value(p),
		}
		eat(p)
	}

	// ECMA-262 §13.9.1 — BreakStatement context check. Promoted from
	// the semantic checker (ck_walk_stmt's ^BreakStatement case) so
	// parser-only snaps reject the break-outside-loop / unknown-label
	// clusters in test262.
	//   * Unlabeled `break;` requires the parser to be inside an
	//     IterationStatement OR SwitchStatement. p.ctx.in_loop / p.ctx.in_switch
	//     track exactly that.
	//   * Labeled `break label;` requires `label` to name an enclosing
	//     LabelledStatement (any kind — the spec doesn't restrict to
	//     iteration). label_in_scope / label_floor handle function-boundary
	//     resets so `break outer;` can't escape out of a nested function.
	if lbl, have := label.(LabelIdentifier); have {
		if !label_in_scope(p, lbl.name) {
			msg := fmt.tprintf("Undefined label '%s'", lbl.name)
			report_error_coded_span(p, .K3055_LabelOrLoopControl, u32(label_loc), u32(label_loc), msg)
		}
	} else if !p.ctx.in_loop && !p.ctx.in_switch && !p.ctx.in_ambient {
		report_error_coded_span(p, .K3055_LabelOrLoopControl, u32(start.start), u32(start.start), "'break' must be inside a loop or switch")
	}

	// §14.9 - BreakStatement requires a `;` (or ASI).
	expect_semicolon_or_asi(p)

	break_, break__s := new_stmt(p, BreakStatement)
	break_.loc = start
	break_.label = label
	break_.loc.end = prev_end_offset(p)

	return break__s
}

parse_continue_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume continue

	// ECMA-262 §13.9.2 - `continue` only valid inside an IterationStatement.
	// Labeled form `continue label;` requires an enclosing LABELED
	// IterationStatement; we don't track labels yet, so we only enforce
	// the unlabeled case (matches how we handle `break` above).
	// See parse_break_statement for the tracking rationale.

	label: Maybe(LabelIdentifier)
	label_loc: LexerLoc
	// Label only if on same line (no LineTerminator between continue and identifier)
	if is_token(p, .Identifier) && !cur_has_newline(p) {
		// LabelIdentifier is an Identifier position - escaped ReservedWord
		// (e.g. `continue \u0069f;`) is a Syntax Error (§12.7.2).
		report_escaped_reserved_word(p)
		lbl_loc := cur_loc(p)
		label_loc = LexerLoc(lbl_loc.start)
		label = LabelIdentifier{
			loc  = lbl_loc,
			name = cur_value(p),
		}
		eat(p)
	}

	// ECMA-262 §13.9.2 — ContinueStatement context check. Promoted from
	// the semantic checker (ck_walk_stmt's ^ContinueStatement case).
	//   * Unlabeled `continue;` requires the parser to be inside an
	//     IterationStatement (NOT SwitchStatement — §13.9.2 says so).
	//   * Labeled `continue label;` requires `label` to name an enclosing
	//     LabelledStatement that contains an IterationStatement.
	//     label_iter_in_scope is the parser's parallel-bitset version of
	//     label_in_scope that gates on the per-label is_iteration flag.
	if lbl, have := label.(LabelIdentifier); have {
		if !label_in_scope(p, lbl.name) {
			msg := fmt.tprintf("Undefined label '%s'", lbl.name)
			report_error_coded_span(p, .K3055_LabelOrLoopControl, u32(label_loc), u32(label_loc), msg)
		} else if !label_iter_in_scope(p, lbl.name) {
			msg := fmt.tprintf("'continue' must target an iteration label, '%s' does not", lbl.name)
			report_error_coded_span(p, .K3055_LabelOrLoopControl, u32(label_loc), u32(label_loc), msg)
		}
	} else if !p.ctx.in_loop && !p.ctx.in_ambient {
		report_error_coded_span(p, .K3055_LabelOrLoopControl, u32(start.start), u32(start.start), "'continue' must be inside a loop")
	}

	// §14.8 - ContinueStatement requires a `;` (or ASI).
	expect_semicolon_or_asi(p)

	cont, cont_s := new_stmt(p, ContinueStatement)
	cont.loc = start
	cont.label = label
	cont.loc.end = prev_end_offset(p)

	return cont_s
}

parse_switch_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume switch

	if !expect_token(p, .LParen) {
		return nil
	}

	discriminant := parse_expression(p)
	if discriminant == nil {
		return nil
	}

	if !expect_token(p, .RParen) {
		return nil
	}

	if !expect_token(p, .LBrace) {
		return nil
	}

	switch_ := new_node(p, SwitchStatement)
	switch_.loc = start
	switch_.discriminant = discriminant
	switch_.cases = make([dynamic]SwitchCase, 0, 16, p.allocator)

	prev_in_switch := p.ctx.in_switch
	p.ctx.in_switch = true

	// §14.12.1 — at most one default clause.
	has_default := false
	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		prev_offset := int(cur_offset(p))
		case_ := parse_switch_case(p)
		if case_ != nil {
			// Default clause has `test == nil`.
			if _, has_test := case_.test.(^Expression); !has_test || case_.test == nil {
				if has_default {
					report_error_coded(p, .K2040_UnexpectedToken, "More than one default clause in switch")
				}
				has_default = true
			}
			bump_append(&switch_.cases, case_^)
		} else if int(cur_offset(p)) == prev_offset {
			eat(p)
		}
	}

	p.ctx.in_switch = prev_in_switch

	if !match_token(p, .RBrace) {
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected '}' at end of switch statement")
	}

	switch_.loc.end = prev_end_offset(p)
	// §14.12.1 - all SwitchCase consequents share a single block-scope
	// (the switch's StatementList). Flatten the per-case lists into one
	// slice and queue it for post-parse verification. Probe relevance
	// across all cases first; allocating the flat slice when nothing in
	// the switch declares anything would be pure overhead.
	relevant := false
	total := 0
	for c in switch_.cases {
		total += len(c.consequent)
		if !relevant && has_scope_relevant_stmt(c.consequent[:]) {
			relevant = true
		}
	}
	// §14.12.2 — inline lex/var clash check across all SwitchCase
	// consequents. They share a single block-scope (the switch's
	// CaseBlock). Flatten the per-case lists once and run the check.
	if !p.ast_only && total > 0 && relevant {
		flat := make([]^Statement, total, context.temp_allocator)
		i := 0
		for c in switch_.cases {
			for s in c.consequent {
				flat[i] = s
				i += 1
			}
		}
		parser_scope_check(p, flat, true)
	}
	return statement_from(p, switch_)
}

parse_switch_case :: proc(p: ^Parser) -> ^SwitchCase {
	start := cur_loc(p)

	test: Maybe(^Expression)

	if match_token(p, .Default) {
		test = nil
	} else if match_token(p, .Case) {
		// `case :` is a SyntaxError per §14.12: CaseClause :: `case`
		// Expression `:` StatementList. Without this guard
		// parse_expression returns nil for `:` and the `:` is silently
		// consumed by the next `expect_token(.Colon)` call. Test262:
		// language/statements/switch/S12.11_A3_T4.js.
		if is_token(p, .Colon) {
			report_error_coded(p, .K2020_ExpectedExpression, "Expected expression after 'case'")
			eat(p) // consume `:`
			return nil
		}
		test = parse_expression(p)
	} else {
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected 'case' or 'default' in switch")
		return nil
	}

	if !expect_token(p, .Colon) {
		return nil
	}

	case_ := new_node(p, SwitchCase)
	case_.loc = start
	case_.test = test
	case_.consequent = make([dynamic]^Statement, 0, 4, p.allocator)

	// Mark statements directly inside this CaseClause / DefaultClause
	// for the using / await-using placement check. Cleared on exit.
	prev_in_case_clause := p.ctx.in_case_clause
	p.ctx.in_case_clause = true
	defer p.ctx.in_case_clause = prev_in_case_clause
	// Track nesting for import/export position check.
	p.block_depth += 1
	defer p.block_depth -= 1

	for !is_token(p, .Case) && !is_token(p, .Default) && !is_token(p, .RBrace) && !is_token(p, .EOF) {
		prev_offset := int(cur_offset(p))
		stmt := parse_statement_or_declaration(p)
		if stmt != nil {
			bump_append(&case_.consequent, stmt)
		} else if int(cur_offset(p)) == prev_offset {
			eat(p)
		}
	}

	case_.loc.end = prev_end_offset(p)
	return case_
}

parse_try_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume try

	// parse_block_statement returns a ^Statement union wrapping a
	// ^BlockStatement. The old transmute(^BlockStatement)block read the
	// Statement union's 16 bytes as if they were the BlockStatement
	// struct - UB that silently truncated the block body.
	block := parse_block_statement(p)
	if block == nil {
		return nil
	}
	block_ptr, ok := block^.(^BlockStatement)
	if !ok {
		return nil
	}

	try_, try__s := new_stmt(p, TryStatement)
	try_.loc = start
	try_.block = block_ptr^

	if is_token(p, .Catch) {
		// CatchClause.start must point at the `catch` keyword, not at the
		// `(` or `{` that follows - matches OXC/Acorn/Babel. Capture the
		// position BEFORE consuming `catch` and pass it through.
		catch_start := cur_loc(p)
		eat(p) // consume `catch`
		handler := parse_catch_clause(p, catch_start)
		try_.handler = handler
	}

	if match_token(p, .Finally) {
		finalizer := parse_block_statement(p)
		if finalizer != nil {
			if fin_ptr, fin_ok := finalizer^.(^BlockStatement); fin_ok {
				try_.finalizer = fin_ptr^
			}
		}
	}

	if try_.handler == nil && try_.finalizer == nil {
		report_error_coded(p, .K2070_RequiredFormOrBinding, "Try statement must have catch or finally clause")
	}

	try_.loc.end = prev_end_offset(p)
	return try__s
}

parse_catch_clause :: proc(p: ^Parser, start: Loc) -> Maybe(CatchClause) {
	// `start` is the position of the `catch` keyword, already consumed by the
	// caller. We pass it in because the ESTree spec puts the CatchClause span
	// at the keyword, not the opening paren/brace that begins our local work.
	param: Maybe(Pattern)

	// Optional catch binding: try {} catch {} or try {} catch (e) {}.
	// `try {} catch () {}` (empty parens) is a SyntaxError per §14.15:
	// the catch parameter list either omits the parens entirely
	// (optional-catch-binding proposal) or contains exactly one
	// CatchParameter (BindingIdentifier or BindingPattern). Empty parens
	// are not the same as no parens.
	if is_token(p, .LParen) {
		eat(p)
		if is_token(p, .RParen) {
			report_error_coded(p, .K2070_RequiredFormOrBinding, "Catch parameter is missing")
		} else {
			param = parse_binding_pattern(p)
			// TS § catch-clause-types - the catch parameter may carry a
			// type annotation (`: any` or `: unknown` per TS rules; the
			// type-checker enforces the narrow set, the parser accepts
			// any TS type).			// "Expected ), got :" cluster (destructureCatchClause.ts and
			// friends use shapes like `catch ({ x }: unknown) { ... }`).
			if allow_ts_mode(p) && is_token(p, .Colon) {
				_ = parse_ts_type_annotation(p)
			}
		}
		if !expect_token(p, .RParen) {
			return nil
		}
	}

	// §14.15 - BoundNames of a CatchParameter must be unique. Walk
	// the pattern to collect names and check for duplicates.
	check_catch_param_dups(p, param)

	body := parse_block_statement(p)
	if body == nil {
		return nil
	}
	body_ptr, body_ok := body^.(^BlockStatement)
	if !body_ok {
		return nil
	}

	// §14.15.1 — catch parameter vs body lex/var redeclaration.
	check_catch_param_body_shadow(p, param, body_ptr.body[:])

	clause := CatchClause{
		loc   = start,
		param = param,
		body  = body_ptr^,
	}
	clause.loc.end = prev_end_offset(p)

	return clause
}

parse_throw_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume throw

	// ECMA-262 §14.14 Restricted Production - no LineTerminator between
	// `throw` and the argument expression. ASI does NOT apply to throw;
	// a bare `throw` with a newline before the argument is a SyntaxError.
	if cur_has_newline(p) {
		report_error_coded(p, .K2040_UnexpectedToken, "Illegal newline after 'throw'")
	}

	argument := parse_expression(p)
	if argument == nil {
		report_error_coded(p, .K2020_ExpectedExpression, "Expected expression after throw")
		return nil
	}

	match_semicolon_or_asi(p)

	throw_, throw__s := new_stmt(p, ThrowStatement)
	throw_.loc = start
	throw_.argument = argument
	throw_.loc.end = prev_end_offset(p)

	return throw__s
}

parse_debugger_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume debugger

	match_semicolon_or_asi(p)

	debugger, debugger_s := new_stmt(p, DebuggerStatement)
	debugger.loc = start
	debugger.loc.end = prev_end_offset(p)

	return debugger_s
}

parse_with_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume with

	// §14.11.1 — `with` statements are forbidden in strict mode.
	if p.ctx.strict_mode {
		report_error_coded_span(p, .K3051_StrictModeProhibited, u32(start.start), u32(start.start), "'with' statements are not allowed in strict mode")
	}

	if !expect_token(p, .LParen) {
		return nil
	}

	// §13.11 WithStatement : with ( Expression ) Statement - Expression
	// is the comma-operator production, so `with (a, b, c) ...` is
	// legal. Use parse_expression (which calls parse_expr_with_prec at
	// .Comma) rather than parse_assignment_expression. Test262
	// language/statements/with/scope-var-open.js exercises this with
	// `with (eval('var x = 1;'), probe = function(){...}, objectRecord)`.
	object := parse_expression(p)
	if object == nil {
		return nil
	}

	if !expect_close_paren_or_recover(p) {
		return nil
	}

	body := parse_statement_or_declaration(p)
	if body == nil {
		report_error_coded(p, .K2022_ExpectedStatementBody, "Expected statement after 'with' object")
	}
	// ECMA-262 §14.11.1 - WithStatement : with ( Expression ) Statement.
	// Statement excludes hoistable declarations (LexicalDeclaration,
	// ClassDeclaration, AsyncFunctionDeclaration, GeneratorDeclaration,
	// AsyncGeneratorDeclaration). Plain FunctionDeclaration is also banned
	// since `with` is itself strict-mode-illegal but in sloppy script the
	// body cannot be a Declaration form per the grammar.
	report_statement_only_position(p, body, false)

	with_, with__s := new_stmt(p, WithStatement)
	with_.loc = start
	with_.object = object
	with_.body = body
	with_.loc.end = prev_end_offset(p)

	return with__s
}

// ============================================================================
// Declarations
// ============================================================================

parse_function_declaration :: proc(p: ^Parser, is_expr := false, allow_no_body := false) -> ^Statement {
	start := cur_loc(p)
	// Handle async prefix
	async := false
	if is_token(p, .Async) {
		async = true
		eat(p) // consume async
	}

	if !is_token(p, .Function) {
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected function after async")
		return nil
	}

	eat(p) // consume function

	generator := match_token(p, .Mul)

	id: Maybe(BindingIdentifier)

	// For function names, only binding-identifier-capable tokens qualify.
	// Property-name keywords (null, true, false, if, enum, class, etc.)
	// are NOT valid as FunctionDeclaration / FunctionExpression names.
	has_name := is_token(p, .Identifier) || can_be_binding_identifier(p.cur_type)
	if !is_expr || has_name {
		if has_name {
			current := snap_current(p)
			id = BindingIdentifier{
				loc  = loc_from_token(&current),
				name = current.value,
			}
			// §15.8.1 / §15.5.1 / §15.9.1 - the BindingIdentifier of an
			// AsyncFunctionExpression / GeneratorExpression /
			// AsyncGeneratorExpression is parsed under [+Await] / [+Yield],
			// so `await` / `yield` cannot be used as the function name in
			// expression position. The Declaration form's binding is in the
			// enclosing context.
			if is_expr && async && current.value == "await" {
				report_error_coded(p, .K3010_AwaitYieldAsBindingName,
					"'await' cannot be used as the name of an async function expression")
			}
			// OXC catches `(function*yield(){})` and
			// `var x = function*yield(){}` etc. as parser-level errors,
			// but NOT `export default function *yield() {}`. Match OXC:
			// fire as a structural parse error unless we're in export-
			// default context (where the strict-mode reservation kicks in
			// at the semantic checker via
			// ck_check_binding_identifier_strict on the function name).
			if is_expr && generator && current.value == "yield" && !p.in_export_default {
				report_error_coded(p, .K3010_AwaitYieldAsBindingName,
					"'yield' cannot be used as the name of a generator function expression")
			}
			// §15.7.1 — in strict mode, `yield` is a reserved word and
			// cannot be used as a function name (either declaration or
			// expression). Class bodies are implicitly strict.
			if current.value == "yield" && p.ctx.strict_mode {
				report_error_coded(p, .K3050_StrictModeReserved, "'yield' is a reserved identifier in strict mode")
			}

			// §12.6.1.1 contextual reservation - `await` / `yield` as a
			// BindingIdentifier in the enclosing context. Fires for both
			// declaration and expression forms when the enclosing scope is
			// [+Await] / [+Yield] (covers `async function f() { function
			// await() {} }`, module-top-level `class await {}` etc).
			// FunctionExpression names live in the inner function's own
			// scope (§15.7.1: BindingIdentifier of FunctionExpression is
			// parsed under [~Yield, ~Await] when the function is a regular
			// non-async non-generator). So `function yield() {}` inside a
			// generator IS legal as long as the inner function is itself
			// not a generator. Skip the contextual check for plain
			// FunctionExpression names; the function-itself flags (async /
			// generator) drive the FunctionExpression-name check above.
			// §12.1.1 - `enum` is a FutureReservedWord that is always
			// reserved (§12.1.3), regardless of strict mode. It may appear
			// in can_be_binding_identifier for TS enum declarations, but it
			// can never serve as a function or class name in JS. The lexer
			// emits `enum` as .Identifier (contextual), so check by value.
			if current.value == "enum" {
				report_error_coded(p, .K4054_EnumInvalid, "'enum' is a reserved word and cannot be used as a function name")
			}
			if !is_expr {
				if current.value == "await" {
					await_reserved := await_is_reserved_here(p)
					if !await_reserved {
						if st, have := p.force_source_type.(SourceType); have && st == .Module { await_reserved = true }
						else if p.in_module_top_level || p.has_module_syntax { await_reserved = true }
					}
					if await_reserved {
						report_error_coded(p, .K3010_AwaitYieldAsBindingName,
			"'await' cannot be used as a function name in module / async context")
					}
				}
				// In generator context `yield` as a declaration name is a
				// parser-level error (OXC catches it).
				if current.value == "yield" {
					if p.ctx.in_generator || p.ctx.in_generator_params {
						report_error_coded(p, .K3010_AwaitYieldAsBindingName,
			"'yield' cannot be used as a function name in generator context")
					}
					// Strict-mode yield-as-decl-name is enforced by the
					// semantic checker.
				}
			}
			// Strict-mode FutureReservedWords as function name.
			// `implements`, `interface`, `package`, `private`,
			// `protected`, `public` — reserved in strict mode (§12.1.3).
			// Skip in ambient/d.ts — `declare function static()` is valid.
			// In JS, `static` is also reserved; in TS mode OXC allows it.
			if p.ctx.strict_mode && !p.ctx.in_ambient && !p.source_is_dts {
				is_reserved_fn_name := is_strict_reserved_name(current.value)
				// `static` is reserved in strict JS but not in TS.
				if !is_reserved_fn_name && !allow_ts_mode(p) {
					is_reserved_fn_name = current.value == "static" || current.value == "let" || current.value == "yield"
				}
				if is_reserved_fn_name {
					msg := fmt.tprintf("Function name '%s' is reserved in strict mode", current.value)
					report_error_coded(p, .K3050_StrictModeReserved, msg)
				}
			}
			eat(p)
		} else if !is_expr {
			report_error_coded(p, .K2070_RequiredFormOrBinding, "Function declaration requires a name")
		}
	}

	// TypeScript generic type parameters: `function foo<T, U>(...)`
	type_parameters: Maybe(^TSTypeParameterDeclaration)
	if is_token(p, .LAngle) && allow_ts_mode(p) { type_parameters = parse_ts_type_parameters(p) }

	if !expect_token(p, .LParen) {
		return nil
	}

	// §15.5.1 / §15.6.1 - mark FormalParameters of a generator so
	// parse_yield_expr can reject `yield` inside default initializers.
	// §15.8.1 - same for async function: `await` in a parameter default
	// is a SyntaxError. Save/restore to nest correctly when a generator /
	// async function declares parameters of another function type.
	prev_in_gen_params := p.ctx.in_generator_params
	prev_in_async_params := p.ctx.in_async_params
	// Static-block context does NOT extend into nested function parameters;
	// `method(x = await){}` inside a static block should not flag `await`.
	prev_static_block_params := p.ctx.in_static_block
	p.ctx.in_static_block = false
	p.ctx.in_generator_params = generator
	p.ctx.in_async_params = async
	// The outer generator/async context should NOT leak into a nested
	// non-generator non-async function's params. `function f(x = yield){}`
	// inside a generator has `yield` as IdentifierRef, not YieldExpression.
	prev_in_generator_param_outer := p.ctx.in_generator
	prev_in_async_param_outer := p.ctx.in_async
	if !generator { p.ctx.in_generator = false }
	if !async    { p.ctx.in_async = false }
	// §15.2.1 / §15.7 - set `in_function` before params so the
	// AwaitExpression / YieldExpression checks in parse_unary_expr see
	// that we are inside a function scope, preventing `await 1` in
	// non-async function params from being misinterpreted as TLA.
	prev_in_function_params := p.ctx.in_function
	p.ctx.in_function = true
	// `new.target` is legal in a parameter default of a regular
	// function (e.g. `function f(x = new.target) {}`); arrow params
	// are handled separately and inherit the outer flag.
	prev_in_non_arrow_params := p.ctx.in_non_arrow_function
	p.ctx.in_non_arrow_function = true
	params := parse_function_params(p)
	p.ctx.in_function = prev_in_function_params
	p.ctx.in_non_arrow_function = prev_in_non_arrow_params
	p.ctx.in_generator_params = prev_in_gen_params
	p.ctx.in_async_params = prev_in_async_params
	p.ctx.in_static_block = prev_static_block_params
	p.ctx.in_generator = prev_in_generator_param_outer
	p.ctx.in_async = prev_in_async_param_outer

	report_parameter_modifiers_disallowed(p, params[:])
	// §15.1 / §15.2.1 — duplicate formal parameter names.
	parser_check_dup_params(p, params[:], start.start, p.ctx.strict_mode, false)

	if !expect_token(p, .RParen) {
		// Error recovery: skip forward to the next `{` (start of the body)
		// or a clear statement terminator so we can still build a function
		// declaration around the intended body. Without this, a malformed
		// param list like `function f(a, b { ... }` leaked the body to the
		// top-level parser, and the `return` inside fired the new top-level
		// return diagnostic - a cascading false positive.
		for !is_token(p, .LBrace) && !is_token(p, .Semi) && !is_token(p, .EOF) {
			recovery_eat(p)
		}
	}

	// TypeScript return type annotation
	return_type: Maybe(^TSTypeAnnotation)
	if is_token(p, .Colon) && allow_ts_mode(p) {
		return_type = parse_ts_return_type_annotation(p)
	}

	prev_async := p.ctx.in_async
	p.ctx.in_async = async
	prev_gen := p.ctx.in_generator
	p.ctx.in_generator = generator
	// A nested function body starts a new scope that does NOT inherit
	// the enclosing async-param/generator-param flags. `function f()
	// { await }` inside an async arrow's parameter default is legal
	// because the nested function is NOT async.
	prev_in_async_params_body := p.ctx.in_async_params
	p.ctx.in_async_params = false
	prev_in_gen_params_body := p.ctx.in_generator_params
	p.ctx.in_generator_params = false
	// Regular (non-arrow) function declarations / expressions reset
	// `in_method` - they introduce their own (absent) [[HomeObject]], so
	// a nested `function foo() { super.x; }` inside a class method body
	// is a SyntaxError. Arrow functions keep inherited `in_method`.
	prev_in_method := p.ctx.in_method
	p.ctx.in_method = false
	// Same rule for `in_derived_constructor` - a regular function inside
	// a derived-class constructor gets its own (non-constructor)
	// function environment, so `super(...)` inside it is a SyntaxError.
	prev_in_derived_ctor := p.ctx.in_derived_constructor
	p.ctx.in_derived_constructor = false
	// Regular functions bind their own `arguments`, so class-field
	// initialiser `arguments` rejection stops propagating.
	prev_in_field_init_fn := p.ctx.in_field_init
	p.ctx.in_field_init = false

	// In declare / ambient-module context, allow no body (just a semicolon).
	// An ambient module body (`module "x" { function f(): void; }`) or a
	// `declare function f(): void;` both elide the implementation.
	// TS-A10: also allow a body-less declaration in plain TS mode to support
	// overload signatures:
	//   function foo(x: string): string;
	//   function foo(x: number): number;
	//   function foo(x: any): any { return x; }
	// We don't validate the overload set (implementation signature, shape
	// agreement, etc.) - the parser just keeps the syntax; a downstream type
	// checker owns the semantics. Gated on allow_ts_mode so pure JS keeps
	// rejecting bodyless function declarations.
	body: FunctionBody
	body_strict := false
	// Function EXPRESSIONS always require a body (TS overload signatures only
	// apply to function DECLARATIONS / class methods). `const x = function();`
	// is invalid even in TS mode.
	// Exception: `export default function foo(): T;` is parsed with is_expr=true
	// (expression form) but is semantically a declaration with overload signatures.
	// Allow no-body when in_export_default so TS overload sigs work.
	allow_no_body_here := (!is_expr || p.in_export_default) && (allow_no_body || p.ctx.in_ambient || allow_ts_mode(p))
	// Ambient function: `declare function f(): T;` (with or without
	// semicolon - ASI applies in .d.ts files where `export declare
	// function parse(...): Promise<R>` is followed by a newline and the
	// next top-level `export`). Three triggers for an empty body:
	//   1. explicit Semi
	//   2. Right brace (last decl in `declare module { ... }`)
	//   3. ASI: line-terminator before next token AND we're not at `{`
	is_no_body := false
	if allow_no_body_here {
		if is_token(p, .Semi) {
			is_no_body = true
			eat(p)
		} else if !is_token(p, .LBrace) &&
		          (is_token(p, .RBrace) || is_token(p, .EOF) ||
		           cur_has_newline(p)) {
			is_no_body = true
			// Don't consume - the outer parse_statement_or_declaration
			// loop expects to see the next-statement token unchanged.
		}
	}
	if is_no_body {
		body = FunctionBody{
			loc = cur_loc(p),
			body = make([dynamic]^Statement, 0, 4, p.allocator),
			directives = make([dynamic]Directive, 0, 0, p.allocator),
		}
	} else {
		// §14.1 — function body in ambient context is a SyntaxError.
		// Covers both `declare function f() {}` (explicit) and
		// `declare module { function f() {} }` (inherited ambient).
		if allow_no_body || p.ctx.in_ambient || p.source_is_dts {
			report_error_coded(p, .K4050_AmbientContextRestriction, "An implementation cannot be declared in ambient contexts")
		}
		body = parse_function_body(p)
		body_strict = p.last_body_strict
	}
	// Stash the no-body bit so downstream scope / dup-export checks can
	// recognise this as a TS overload signature / ambient declaration
	// and exempt it from the duplicate-binding rule. Threaded through
	// the local `is_ts_no_body` variable; consumed below where the
	// FunctionExpression / FunctionDeclaration is constructed.
	is_ts_no_body := is_no_body

	p.ctx.in_async = prev_async
	p.ctx.in_generator = prev_gen
	p.ctx.in_async_params = prev_in_async_params_body
	p.ctx.in_generator_params = prev_in_gen_params_body
	p.ctx.in_method = prev_in_method
	p.ctx.in_derived_constructor = prev_in_derived_ctor
	p.ctx.in_field_init = prev_in_field_init_fn

	// Retroactive StrictFormalParameters check: if either the enclosing
	// context was already strict or the body declared `"use strict"`, the
	// params must have no duplicate bound names. Non-simple parameter
	// lists (destructuring, default values, rest) additionally force the
	// UniqueFormalParameters rule even in sloppy mode (§15.1.2).
	// §15.5.1 GeneratorBody and §15.8.1 AsyncFunctionBody also require
	// UniqueFormalParameters unconditionally - pass strict_override=true
	// for them regardless of outer strict mode.
	strict_for_check := p.ctx.strict_mode || body_strict
	// §15.1.1 / §15.5.1 / §15.6.1 / §15.8.1 — FormalParameters
	// duplicate-name check. Async / generator function bodies have
	// UniqueFormalParameters even in sloppy mode (§15.5.1 / §15.8.1
	// say so explicitly); strict-mode bodies inherit it via
	// StrictFormalParameters (§15.2.1). Sloppy-mode regular functions
	// with a non-simple parameter list also fall under
	// UniqueFormalParameters (§15.1.2).
	// The eval/arguments + reserved-word + function-name strict checks
	// remain on the semantic checker side for now — they require
	// recursing into destructuring patterns and the parser-side surface
	// would duplicate ck_check_strict_binding_pattern wholesale.
	// Retroactive dup-param check: if the body just declared "use strict",
	// the earlier parser_check_dup_params (pre-body) was sloppy and may have
	// permitted simple duplicate params. Re-check with strict=true now.
	if body_strict {
		parser_check_dup_params(p, params[:], start.start, true, false)
	}

	// §15.1.1 / §15.5.1 / §15.6.1 / §15.8.1 — it is a SyntaxError if
	// the function body has a `"use strict"` directive AND the parameter
	// list is not simple.
	// The directive cannot promote params that have already been evaluated
	// (or contain destructuring / defaults), so the spec rejects the
	// combination outright.
	force_non_simple := !params_are_simple(params[:])
	if body_strict && force_non_simple {
		report_error_coded_span(p, .K3052_UseStrictWithComplexParams, u32(start.start), u32(start.start), "Illegal 'use strict' directive in function with non-simple parameter list")
	}
	// §13.1.1 — retroactive strict-mode binding check on params for
	// functions whose body opted into strict via a `"use strict"`
	// directive while the outer scope was sloppy. parse_binding_pattern
	// fired its strict-binding check at param-parse time, but only if
	// p.ctx.strict_mode was already true; the body-strict promotion happens
	// later, so we re-walk the params here. Gate on `!p.ctx.strict_mode`
	// (the OUTER state — parse_function_body restores p.ctx.strict_mode to
	// the pre-body value before returning) so enclosing-strict callers
	// don't double-fire.
	if body_strict && !p.ctx.strict_mode {
		report_strict_param_pattern_retro(p, params[:])
	}
	// §12.6.1.1 — in strict mode (outer or body-promoted), the
	// FunctionName BindingIdentifier may not be `eval` or `arguments`.
	// Async functions are always strict (§15.8.1). Generator functions
	// in strict context fire too. TS ambient (`declare`) functions are
	// exempt: they have no body and are erased at compile time.
	if id_v, has_id := id.?; has_id && (strict_for_check || async) && !p.ctx.in_ambient && !p.source_is_dts {
		if is_eval_or_arguments(id_v.name) {
			msg := fmt.tprintf("Function name '%s' is reserved in strict mode", id_v.name)
			report_error_coded_span(p, .K3050_StrictModeReserved, u32(id_v.loc.start), u32(id_v.loc.start), msg)
		}
	}
	// Retroactive strict-reserved function name check when body
	// promotes to strict and the outer scope was sloppy.
	// `function package() { 'use strict'; }` is a SyntaxError.
	if id_v, has_id := id.?; has_id && body_strict && !p.ctx.strict_mode && !p.ctx.in_ambient && !p.source_is_dts {
		is_reserved := is_strict_reserved_name(id_v.name)
		if !is_reserved && !allow_ts_mode(p) {
			is_reserved = id_v.name == "static" || id_v.name == "let" || id_v.name == "yield"
		}
		if is_reserved {
			msg := fmt.tprintf("Function name '%s' is reserved in strict mode", id_v.name)
			report_error_coded_span(p, .K3050_StrictModeReserved, u32(id_v.loc.start), u32(id_v.loc.start), msg)
		}
	}

	// §15.2.1.1 / §15.5.1 - It is a Syntax Error if any element of the
	// BoundNames of FormalParameters also occurs in the LexicallyDeclaredNames
	// of FunctionBody. e.g. `function f(a) { const a = 1; }` is SyntaxError.
	// Collect param names and check against body's lex declarations.
 if !p.ast_only {
	check_params_vs_body_lex(p, params[:], body.body[:])
 }

	// TS2371 — overload / ambient signatures may not have parameter defaults.
	// TS: parameter properties (public/private/protected/readonly) are only
	// allowed in the implementation constructor, not in overload signatures.
	if is_ts_no_body && allow_ts_mode(p) {
		for pr in params {
			if _, has := pr.default_val.(^Expression); has {
				report_error_coded_span(p, .K4022_ParameterPropertyOnlyInCtor, u32(pr.loc.start), u32(pr.loc.start), "A parameter initializer is only allowed in a function or constructor implementation")
			}
			if pr.accessibility != .None {
				report_error_coded_span(p, .K4022_ParameterPropertyOnlyInCtor, u32(pr.loc.start), u32(pr.loc.start), "Parameter properties are only allowed in the implementation constructor")
			}
			if pr.readonly {
				report_error_coded_span(p, .K4022_ParameterPropertyOnlyInCtor, u32(pr.loc.start), u32(pr.loc.start), "'readonly' parameter properties are only allowed in the implementation constructor")
			}
			if pr.override_ {
				report_error_coded_span(p, .K4022_ParameterPropertyOnlyInCtor, u32(pr.loc.start), u32(pr.loc.start), "'override' parameter properties are only allowed in the implementation constructor")
			}
		}
	}

	// TS1689 — binding pattern parameters with `?` (optional) are only valid
	// in overload / ambient signatures (no body). In implementation signatures
	// (with body), `[]?` and `{}?` are errors.
	if !is_ts_no_body && allow_ts_mode(p) {
		for pr in params {
			if pr.optional_destructuring {
				report_error_coded_span(p, .K4063_OptionalAndInit, u32(pr.loc.start), u32(pr.loc.start), "A binding pattern parameter cannot be optional in an implementation signature")
			}
		}
	}

	if is_expr {
		expr, expr_e := new_expr(p, FunctionExpression)
		expr.loc = start
		expr.id = id
		expr.params = params
		expr.body = body
		expr.generator = generator
		expr.async = async
		expr.type_parameters = type_parameters
		expr.return_type = return_type
		expr.no_body = is_ts_no_body
		expr.loc.end = prev_end_offset(p)

		// For function expressions, wrap in ExpressionStatement. The
		// .expression field is an ^Expression (a union ptr, not a raw ptr
		// to the concrete variant), so box via expression_from to get a
		// properly tagged union - a plain pointer cast produces a union
		// with tag=0 and corrupt contents on read.
		expr_stmt := new_node(p, ExpressionStatement)
		expr_stmt.loc = start
		expr_stmt.expression = expr_e
		expr_stmt.loc.end = prev_end_offset(p)

		stmt := new_node(p, Statement)
		stmt^ = expr_stmt
		return stmt
	}

	decl := new_node(p, FunctionDeclaration)
	decl.expr = {
		loc = start,
		id = id,
		params = params,
		body = body,
		generator = generator,
		async = async,
		type_parameters = type_parameters,
		return_type = return_type,
		no_body = is_ts_no_body,
	}
	decl.expr.loc.end = prev_end_offset(p)

	// Allocate Statement union and store the pointer
	stmt := new_node(p, Statement)
	stmt^ = (^FunctionDeclaration)(decl)
	return stmt
}

report_parameter_modifiers_disallowed :: proc(p: ^Parser, params: []FunctionParameter) {
	if !allow_ts_mode(p) { return }
	for fp in params {
		if fp.accessibility != .None || fp.readonly || fp.override_ {
			name := "public"
			if fp.accessibility == .Private { name = "private" }
			if fp.accessibility == .Protected { name = "protected" }
			if fp.readonly && fp.accessibility == .None { name = "readonly" }
			if fp.override_ && fp.accessibility == .None && !fp.readonly { name = "override" }
			report_error_coded(p, .K4032_ModifierMisplaced, fmt.tprintf("'%s' modifier cannot appear on a parameter", name))
		}
	}
}

parse_function_params :: proc(p: ^Parser) -> [dynamic]FunctionParameter {
	// Lazy alloc - zero-parameter functions are very common (callbacks,
	// arrows like `() => x`, getters / setters, etc.). Defer the bump
	// reservation until we know there's at least one parameter.
	params: [dynamic]FunctionParameter

	if is_token(p, .RParen) {
		return params
	}

	// Cap bumped from 3 → 8 (S23). Profile on monaco showed this was the
	// #1 slow-path source: 1465 grow events / parse for functions with
	// >3 params. cap=8 covers ~95th percentile of real-world function
	// arities; the 80B/param cost of the extra slots is dwarfed by the
	// runtime grow cost (50-100 ns per slow-path event).
	params = make([dynamic]FunctionParameter, 0, 8, p.allocator)
	for {
		// Trailing comma: if we see ')' after comma, stop
		if is_token(p, .RParen) {
			break
		}

		param := parse_function_param(p)
		if param != nil {
			bump_append(&params, param^)
		}

		// ECMA-262 §15.1 / §15.3 - no trailing comma is permitted after
		// a RestElement. The trailing-comma allowance applies to non-rest
		// BindingElements only. Detect via the just-parsed param's
		// pattern shape and report before consuming the stray comma.
		if param != nil {
			if _, is_rest := param.pattern.(^RestElement); is_rest {
				if is_token(p, .Comma) {
					// A rest parameter must be last. If followed by `,` and
					// then another param, it's a hard error. If followed by
					// `,` then `)`, it's a trailing-comma error.
     ensure_nxt(p)
					nxt := p.lexer.nxt.kind
					if nxt != .RParen && nxt != .EOF {
						report_error_coded(p, .K3040_RestNotLast, "A rest parameter must be last in a parameter list")
					} else if !p.ctx.in_ambient && !p.source_is_dts {
						report_error_coded(p, .K3041_RestForm, "A rest parameter or binding pattern may not have a trailing comma")
					}
				}
			}
		}

		if !match_token(p, .Comma) {
			break
		}
	}

	// TS1016 — "A required parameter cannot follow an optional parameter."
	// Migrated from the semantic checker to parser level so that
	// parser-only snaps reject the TS ParameterList cluster.
	if allow_ts_mode(p) {
		seen_optional := false
		for param in params {
			if _, is_rest := param.pattern.(^RestElement); is_rest { break }
			is_opt := false
			if id, ok := param.pattern.(^Identifier); ok && id != nil {
				is_opt = id.optional
			}
			if is_opt {
				seen_optional = true
			} else if seen_optional && param.default_val == nil {
				report_error_coded_span(p, .K4063_OptionalAndInit, u32(param.loc.start), u32(param.loc.start), "A required parameter cannot follow an optional parameter")
			}
		}
	}

	return params
}

parse_function_param :: proc(p: ^Parser) -> ^FunctionParameter {
	param := new_node(p, FunctionParameter)
	param.loc = cur_loc(p)

	// TS parameter decorators: `foo(@dec x: T)`. ES decorators (stage 3)
	// only permit `@dec` before class elements and class constructor
	// params; function params outside class bodies are rejected. Gate on
	// `p.class_depth > 0` so constructor-param decorators (legal per
	// ES2025) are accepted. Consume the decorator chain either way so
	// the parser stays alive on syntactically-valid-but-invalid-position
	// decorators rather than crashing in parse_binding_pattern.
	decorators_seen := false
	if allow_ts_mode(p) {
		for is_token(p, .At) {
			if !decorators_seen {
				decorators_seen = true
				if p.class_depth == 0 {
					report_error_coded(p, .K4064_DecoratorInvalid, "Decorators are not valid here")
				}
			}
			eat(p) // consume `@`
			// Decorator expression: identifier (optionally member-chained / called).
			// parse_left_hand_side_expr handles `dec`, `a.b`, `dec(args)`.
			_ = parse_left_hand_side_expr(p)
		}
		param.loc = cur_loc(p)
	}

	// TS "parameter properties" on constructors: access/readonly/override
	// modifiers before the binding. Save them on the FunctionParameter so
	// the emitter can wrap the param in TSParameterProperty when set.
	if allow_ts_mode(p) {
		mod_start := cur_loc(p).start  // position of first modifier (or binding if none)
		found_modifier := false
		param_access_order := -1
		param_readonly_order := -1
		param_override_order := -1
		param_mod_idx := 0
		for i := 0; i < 6; i += 1 {
			cur := p.cur_type
   ensure_nxt(p)
			nxt := p.lexer.nxt.kind
			// Only treat as modifier when followed by a plausible param-start
			// (identifier, contextual keyword as name, `...`, destructuring
			// opener). Otherwise the keyword IS the param name (e.g.
			// `(public) => ...`, rare but legal). Use
			// can_be_binding_identifier so contextual keywords like `is`,
			// `as`, `from` etc. are recognised after `readonly`.
			is_param_start := can_be_binding_identifier(nxt) || nxt == .Dot3 ||
			                  nxt == .LBrace || nxt == .LBracket
			if !is_param_start { break }
			consumed := false
			#partial switch cur {
			case .Override:
				param.override_ = true; param_override_order = param_mod_idx; param_mod_idx += 1; eat(p); consumed = true; found_modifier = true
			case .Identifier:
				val := cur_value(p)
				switch val {
				case "public":
					if param.accessibility != .None { report_error_coded(p, .K4031_DuplicateModifier, "Accessibility modifier already seen") }
					param.accessibility = .Public
					param_access_order = param_mod_idx; param_mod_idx += 1; eat(p); consumed = true; found_modifier = true
				case "private":
					if param.accessibility != .None { report_error_coded(p, .K4031_DuplicateModifier, "Accessibility modifier already seen") }
					param.accessibility = .Private
					param_access_order = param_mod_idx; param_mod_idx += 1; eat(p); consumed = true; found_modifier = true
				case "protected":
					if param.accessibility != .None { report_error_coded(p, .K4031_DuplicateModifier, "Accessibility modifier already seen") }
					param.accessibility = .Protected
					param_access_order = param_mod_idx; param_mod_idx += 1; eat(p); consumed = true; found_modifier = true
				case "readonly":
					param.readonly = true; param_readonly_order = param_mod_idx; param_mod_idx += 1; eat(p); consumed = true; found_modifier = true
				}
			}
			if !consumed { break }
		}
		if found_modifier {
			param.modifier_start = mod_start
		}
		// Modifier ordering: accessibility must precede readonly/override.
		if param_access_order >= 0 && param_readonly_order >= 0 && param_access_order > param_readonly_order {
			acc_name := "public"
			if param.accessibility == .Private { acc_name = "private" }
			if param.accessibility == .Protected { acc_name = "protected" }
			report_error_coded(p, .K4030_ModifierOrder, fmt.tprintf("'%s' modifier must precede 'readonly' modifier", acc_name))
		}
		if param_override_order >= 0 && param_readonly_order >= 0 && param_override_order > param_readonly_order {
			report_error_coded(p, .K4030_ModifierOrder, "'override' modifier must precede 'readonly' modifier")
		}
		if param_access_order >= 0 && param_override_order >= 0 && param_access_order > param_override_order {
			acc_name := "public"
			if param.accessibility == .Private { acc_name = "private" }
			if param.accessibility == .Protected { acc_name = "protected" }
			report_error_coded(p, .K4030_ModifierOrder, fmt.tprintf("'%s' modifier must precede 'override' modifier", acc_name))
		}
		param.loc = cur_loc(p)
	}

	// Check for rest parameter: ...identifier
	if match_token(p, .Dot3) {
		// Rest element - create RestElement as the pattern
		rest := new_node(p, RestElement)
		rest.loc = param.loc

		// Parse the argument (identifier or destructuring pattern)
		arg_pattern := parse_binding_pattern(p)
		rest.argument = arg_pattern

		// TS: type annotation on a rest parameter - `...args: T[]`.
		// Store on the inner Identifier so the emitter surfaces it;
		// extend the RestElement span to cover the annotation.
		if is_token(p, .Colon) && allow_ts_mode(p) {
			ann := parse_ts_type_annotation(p)
			if ident, ok := arg_pattern.(^Identifier); ok {
				ident.type_annotation = ann
				if ann != nil && ann.loc.end > ident.loc.end {
					ident.loc.end = ann.loc.end
				}
			}
		}
		rest.loc.end = prev_end_offset(p)

		// Store RestElement as the pattern
		param.pattern = rest
		// Rest parameters cannot have default values
		param.loc.end = prev_end_offset(p)
		return param
	}

	pattern: Pattern
	if p.cur_type == .This && allow_ts_mode(p) {
		if decorators_seen {
			report_error_coded(p, .K4064_DecoratorInvalid, "Decorators cannot be applied to 'this' parameters")
		}
		// TS `this` parameter: `function(this: T) {}` - specifies the
		// type of `this` inside the function. Not a real runtime param.
		ident := new_node(p, Identifier)
		ident.loc = cur_loc(p)
		ident.name = "this"
		eat(p)
		pattern = ident
	} else {
		pattern = parse_binding_pattern(p)
	}
	param.pattern = pattern

	// TypeScript: optional parameter marker `?` comes AFTER the name.
	// Only consume if followed by `:`, `,`, `)`, or `=` - not a ternary.
	// Gate on TS mode — in plain JS, `?` after a param is a syntax error.
	param_is_optional := false
	if allow_ts_mode(p) && is_token(p, .Question) {
		nxt := peek_token(p)
		if nxt.type == .Colon || nxt.type == .Comma || nxt.type == .RParen || nxt.type == .Assign {
			param_is_optional = true
			eat(p) // consume `?`
		}
	}

	// TypeScript type annotation on parameter. Identifier patterns store
	// the annotation on the Identifier itself (OXC convention). For
	// destructuring patterns (ObjectPattern, ArrayPattern, RestElement)
	// OXC stores it on the pattern node
	// slots to ObjectPattern + ArrayPattern. Pre-W4b the annotation was
	// parsed but silently dropped for these shapes; surfaced by 3
	// divergences on tsx/001 + tsx/002. AssignmentPattern carries it on
	// its inner left pattern. OXC also extends the pattern's span to
	// include the annotation; mirror that for parity with `id.end =
	// ann.end` on Identifier.
	if is_token(p, .Colon) && allow_ts_mode(p) {
		ann := parse_ts_type_annotation(p)
		#partial switch t in pattern {
		case ^Identifier:
			t.type_annotation = ann
			if ann != nil && ann.loc.end > t.loc.end {
				t.loc.end = ann.loc.end
			}
		case ^ObjectPattern:
			t.type_annotation = ann
			if ann != nil && ann.loc.end > t.loc.end {
				t.loc.end = ann.loc.end
			}
		case ^ArrayPattern:
			t.type_annotation = ann
			if ann != nil && ann.loc.end > t.loc.end {
				t.loc.end = ann.loc.end
			}
		case:
			// Other Pattern variants (AssignmentPattern, RestElement,
			// MemberExpression) don't carry the annotation directly today;
			// the inner Identifier or pattern picks it up via the relevant
			// recursive parse path. AssignmentPattern in particular is
			// always wrapping a typed inner pattern handled above.
		}
	}

	if match_token(p, .Assign) {
		default_expr := parse_assignment_expression(p)
		if default_expr == nil {
			report_error_coded(p, .K2020_ExpectedExpression, "Expected initializer expression after '='")
		} else {
			param.default_val = default_expr
		}
	}

	// TS: set the optional flag on the pattern identifier.
	if param_is_optional {
		if id, ok := param.pattern.(^Identifier); ok && id != nil {
			id.optional = true
		} else {
			param.optional_destructuring = true
		}
	}

	// TS: a parameter cannot have both `?` and a default initializer.
	if param_is_optional && param.default_val != nil {
		report_error_coded(p, .K4063_OptionalAndInit, "A parameter cannot have a question mark and an initializer")
	}

	param.loc.end = prev_end_offset(p)
	return param
}

parse_function_body :: proc(p: ^Parser) -> FunctionBody {
	start := cur_loc(p)

	if !expect_token(p, .LBrace) {
		return {}
	}

	// Lazy alloc - zero-statement function bodies (`function f() {}`) are
	// extremely common (interface stubs, no-op handlers, default callbacks).
	// Use a zero-cap make() so the dynamic-array header carries the correct
	// allocator field but we don't burn an actual reservation until the
	// first append. directives is rarely populated even on non-empty
	// bodies (only `"use strict"` and similar prologues touch it), so it
	// stays zero-cap unconditionally.
	body := FunctionBody{
		loc        = start,
		body       = make([dynamic]^Statement, 0, 4, p.allocator),
		directives = make([dynamic]Directive, 0, 0, p.allocator),
	}
	// If the body is non-empty, pre-grow the statement vector to its
	// typical capacity to avoid log-N realloc churn. Cap bumped from
	// 8 → 16 (S23): 430 functions on monaco had >8 statements, triggering
	// runtime grow. cap=16 covers most non-trivial function bodies.
	if !is_token(p, .RBrace) && !is_token(p, .EOF) {
		reserve(&body.body, 16)
	}

	prev_in_function := p.ctx.in_function
	prev_in_non_arrow := p.ctx.in_non_arrow_function
	prev_in_generator := p.ctx.in_generator
	prev_in_async := p.ctx.in_async
	prev_strict := p.ctx.strict_mode
	// Labels don't cross function boundaries (§14.13 - LabelSet is
	// per-function). Move the floor up to the current stack length so
	// outer labels are invisible for duplicate / break-target checks,
	// then restore. No copy; the parent labels stay in the backing store.
	prev_label_floor := p.ctx.label_floor
	p.ctx.label_floor = len(p.label_stack)
	// A FunctionBody is its own expression scope - the outer for-init
	// no_in restriction (set in parse_for_statement so Annex B.3.5
	// `for (var x = expr in y)` routes through the for-in arm) must
	// not leak into nested function bodies. Without this, a nested
	// `function() { if (a && "x" in y) {} }` inside a for-init's
	// declarator would reject the inner `in`.
	prev_no_in := p.ctx.no_in
	p.ctx.no_in = false
	// Static block context (§15.7.5) does NOT propagate into nested function
	// bodies: `class C { static { (() => { class await {} }); } }` is valid.
	prev_static_block_in_fb := p.ctx.in_static_block
	p.ctx.in_static_block = false
	// §15.7.10 — a nested function binds its own `arguments`, so the
	// class-field `arguments` ban stops here.
	prev_field_init_in_fb := p.ctx.in_field_init
	p.ctx.in_field_init = false
	// break/continue context does NOT cross function boundaries.
	// `while(1) { function f() { break; } }` is a SyntaxError.
	prev_in_loop_fb := p.ctx.in_loop
	prev_in_switch_fb := p.ctx.in_switch
	p.ctx.in_loop = false
	p.ctx.in_switch = false

	p.ctx.in_function = true
	p.ctx.in_non_arrow_function = true

	// Directive prologue tracking. Per ECMA-262 §14.1.1 the prologue is the
	// leading sequence of ExpressionStatement whose expression is an
	// unparenthesised StringLiteral. If any such directive is exactly the
	// string `use strict`, the whole FunctionBody is strict - including
	// params that were already parsed (retroactive duplicate-name check
	// runs in the caller).
	in_prologue := true
	body_use_strict := false
	prologue_raws := make([dynamic]^StringLiteral, 0, 2, context.temp_allocator)
	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		prev_offset := int(cur_offset(p))
		stmt := parse_statement_or_declaration(p)
		if stmt != nil {
			bump_append(&body.body, stmt)
			if in_prologue {
				es, es_ok := stmt^.(^ExpressionStatement)
				if es_ok && es != nil {
					str_lit, is_str := es.expression.(^StringLiteral)
					if is_str && str_lit != nil {
						// §11.1.1 — directive must be an exact string literal
						// with no escape sequences. Only set es.directive (and
						// strict mode) when the raw token contains no backslash.
						has_escape := strings.contains(str_lit.raw, "\\")
						if !has_escape {
							es.directive = str_lit.value
						}
						bump_append(&prologue_raws, str_lit)
						if str_lit.value == "use strict" && !has_escape {
							body_use_strict = true
							p.ctx.strict_mode = true
						}
					} else {
						in_prologue = false
					}
				} else {
					in_prologue = false
				}
			}
		} else if int(cur_offset(p)) == prev_offset {
			// Report unexpected token if not already covered by a prior error
			// at this position (same logic as parse_program_item recovery).
			recovery_report_unexpected_token(p)
			recovery_eat(p)
		}
	}

	// §12.9.4 Annex B.1.2 / §12.9.4.1 — if the function body's prologue
	// contains a "use strict" directive, EVERY prologue StringLiteral
	// (including those preceding the directive) is governed by strict
	// rules: forbidden LegacyOctalEscapeSequence / \8 / \9.
	if body_use_strict {
		for str_lit in prologue_raws {
			if str_lit != nil && string_raw_has_forbidden_escape(str_lit.raw) {
				report_error_coded_span(p, .K3051_StrictModeProhibited, u32(str_lit.loc.start), u32(str_lit.loc.start), "Octal or \\8 / \\9 escape sequences are not allowed in strict mode")
			}
		}
	}

	p.ctx.in_function = prev_in_function
	p.ctx.in_non_arrow_function = prev_in_non_arrow
	p.ctx.in_generator = prev_in_generator
	p.ctx.in_async = prev_in_async
	p.ctx.strict_mode = prev_strict
	p.ctx.no_in = prev_no_in
	p.ctx.in_static_block = prev_static_block_in_fb
	p.ctx.in_field_init = prev_field_init_in_fb
	p.ctx.in_loop = prev_in_loop_fb
	p.ctx.in_switch = prev_in_switch_fb
	// Restore the enclosing label floor. Labels pushed inside this body
	// should have been popped on their LabelledStatement exit; if not
	// (parse bail-out, etc.) truncate down so leftovers don't pollute
	// the parent scope.
	resize(&p.label_stack, p.ctx.label_floor)
	p.ctx.label_floor = prev_label_floor
	// Surface the directive-prologue result to the caller. `parse_function_
	// declaration` / `parse_function_expression` / class-method parse /
	// object-method parse read this immediately after the call to apply
	// ECMA-262 §15.2.1 StrictFormalParameters retro-checks on the params
	// they already captured. Must be read before any further parsing since
	// nested function bodies clobber the field.
	p.last_body_strict = body_use_strict

	if !match_token(p, .RBrace) {
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected '}' at end of function body")
	}

	body.loc.end = prev_end_offset(p)
	// §14.2.1 — function-body lex/var clash check.
	parser_scope_check(p, body.body[:], false)
	return body
}

parse_class_declaration :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume class

	id: Maybe(BindingIdentifier)
	if can_be_binding_identifier(p.cur_type) {
		current := snap_current(p)
		id = BindingIdentifier{
			loc  = loc_from_token(&current),
			name = current.value,
		}
		// ECMA-262 §15.7.1 - the ClassDeclaration / ClassExpression
		// BindingIdentifier is always parsed in strict mode (class
		// bodies are implicitly strict, and the name is in the
		// enclosing TDZ with strict-reservation rules applied). So
		// `class let`, `class implements`, `class yield`, `class eval`
		// etc. are always SyntaxErrors, regardless of enclosing strict
		// / sloppy setting.
		// §12.1.1 - `enum` is always reserved; never a valid class name.
		if current.value == "enum" {
			report_error_coded(p, .K3030_ClassDeclarationStructure, "'enum' is a reserved word and cannot be a class name")
		}
		// Escaped-ReservedWord in the BindingIdentifier position. Class
		// names are strict-mode-only, so `class l\u0065t` reaches the
		// strict-only branch too. Check escapes FIRST so the escaped-
		// keyword diagnostic fires rather than the plainer
		// "reserved identifier" message.
		if cur_has_escape(p) {
			if is_always_reserved_word_name(current.value) ||
			   is_strict_reserved_name(current.value) ||
			   current.value == "let" || current.value == "static" ||
			   current.value == "yield" {
				msg := fmt.tprintf("Keyword '%s' must not contain escaped characters", current.value)
				report_error_coded(p, .K3015_KeywordContainsEscape, msg)
			}
		}
		// §15.7.1 strict-reserved / eval / arguments — class names
		// are always parsed in strict mode, so the strict-binding
		// reservation list applies. Skip in TS mode — tsc and OXC
		// allow strict-reserved words as class names in TypeScript.
		if !allow_ts_mode(p) && is_strict_reserved_binding_name(current.value) {
			report_error_coded(p, .K3030_ClassDeclarationStructure, fmt.tprintf("'%s' is a reserved identifier and cannot be a class name", current.value))
		}
		// TS2414 — primitive type names cannot be class names.
		check_ts_primitive_decl_name(p, "Class", current.value, loc_from_token(&current))
		// §12.6.1.1 contextual `await` reservation — `await` as a
		// class name is reserved in async / static-block / module
		// context. Uses await_is_reserved_here and an explicit
		// module source-type fallback.
		if current.value == "await" {
			if await_is_reserved_here(p) {
				report_error_coded(p, .K3010_AwaitYieldAsBindingName,
					"'await' cannot be used as a class name in module / async / static-block context")
			} else if st, have := p.force_source_type.(SourceType); have && st == .Module {
				report_error_coded(p, .K3010_AwaitYieldAsBindingName,
					"'await' cannot be used as a class name in module context")
			} else if p.in_module_top_level || p.has_module_syntax {
				report_error_coded(p, .K3010_AwaitYieldAsBindingName,
					"'await' cannot be used as a class name in module context")
			}
		}
		eat(p)
	}

	// TypeScript generic type parameters: `class Box<T> { ... }`
	type_parameters: Maybe(^TSTypeParameterDeclaration)
	if is_token(p, .LAngle) && allow_ts_mode(p) { type_parameters = parse_ts_type_parameters(p) }

	super_class: Maybe(^Expression)
	// §15.7 - ClassDeclaration / ClassExpression are always strict mode code.
	// Set strict mode before parsing the heritage expression so that
	// `class C extends (function() { with({}); })()` correctly rejects
	// the `with` statement inside the heritage function expression.
	prev_strict_class := p.ctx.strict_mode
	p.ctx.strict_mode = true
	defer p.ctx.strict_mode = prev_strict_class
	super_type_arguments: Maybe(^TSTypeParameterInstantiation)
	if match_token(p, .Extends) {
		super_class = parse_left_hand_side_expr(p)
		if super_class == nil {
			report_error_coded(p, .K2020_ExpectedExpression, "Expected expression after 'extends'")
		}
		// TS: optional type arguments on the super class - `extends Foo<T, U>`.
		// parse_left_hand_side_expr stops at the `<` (it's not a JS infix op
		// in this position), so we have to parse the args here.
		// (JS + TS), matching checkJs / allowJs usage patterns.
		// In TS mode, `<<` (left-shift) is re-lexed as two `<` tokens
		// to support `Foo<<T>() => void>`. In JS mode, only plain `<`
		// triggers type-arg parsing — `<<` stays as left-shift.
		if (allow_ts_mode(p) && is_open_angle_or_lshift(p)) ||
		   (!allow_ts_mode(p) && is_token(p, .LAngle)) {
			super_type_arguments = parse_ts_type_arguments(p)
		}
		// §15.7.1 - ClassHeritage uses LeftHandSideExpression. Unparenthesised
		// arrow functions are AssignmentExpressions, not LeftHandSideExpressions.
		// `class C extends (() => {}){}` IS legal (paren promotes to primary);
		// `class C extends async () => {}{}` is a SyntaxError (no parens).
		if sc, have := super_class.(^Expression); have && sc != nil {
			if arrow, is_arrow := sc^.(^ArrowFunctionExpression); is_arrow && arrow != nil {
				// Check for parentheses via backward source scan.
				arrow_start := int(arrow.loc.start)
				paren_wrapped := is_paren_wrapped_at(p, arrow_start)
				if !paren_wrapped {
					report_error_coded(p, .K3066_InvalidAssignmentOrBindingTarget, "Arrow function is not a valid class heritage expression")
				}
			}
		}
	}

	// Thread "this class has an extends clause" through parse_class_body so
	// parse_class_element can enable `in_derived_constructor` only for the
	// instance constructor of a derived class. Saved / restored so nested
	// class declarations don't leak.
	prev_class_has_extends := p.ctx.class_has_extends
	p.ctx.class_has_extends = (super_class != nil)
	defer p.ctx.class_has_extends = prev_class_has_extends

	// Thread abstract status so validate_class_body can reject abstract
	// members in non-abstract classes. The `abstract` keyword was consumed
	// by the caller; p.ctx.class_is_abstract is set before we enter the body.
	prev_class_is_abstract := p.ctx.class_is_abstract
	defer p.ctx.class_is_abstract = prev_class_is_abstract

	// TS: `class X implements Y, Z<T>` - optional after `extends`. OXC emits
	// `implements: [TSClassImplements{expression, typeArguments}]`. Kessel's
	// ClassDeclaration already has an `implements` field; it was simply
	// never populated by the parser. We reuse parse_ts_heritage_list (same
	// grammar as interface-extends) because the ESTree heritage-entry
	// shape is identical.
	// `implements` is a contextual keyword (lexed as .Identifier in the
	// general case so `var implements = 1` still parses), so match by
	// value rather than token kind. Same pattern the lexer comment
	// mentions for `interface`.
	implements_list: [dynamic]TSInterfaceHeritage
	if (p.lang == .TS || p.lang == .TSX) &&
	   is_token(p, .Identifier) && cur_value_eq(p, "implements") {
		eat(p)
		implements_list = parse_ts_heritage_list(p)
		if len(implements_list) == 0 {
			report_error_coded(p, .K4051_TSDeclarationStructure, "Expected interface name after 'implements'")
		}
	}

	body := parse_class_body(p)

	// Allocate ClassDeclaration and Statement separately
	decl := new_node(p, ClassDeclaration)
	decl.expr = {
		loc                  = start,
		id                   = id,
		super_class          = super_class,
		super_type_arguments = super_type_arguments,
		body                 = body,
		type_parameters      = type_parameters,
		implements           = implements_list,
	}
	decl.expr.loc.end = prev_end_offset(p)

	// Allocate Statement union and store the pointer
	stmt := new_node(p, Statement)
	stmt^ = (^ClassDeclaration)(decl)

	return stmt
}

parse_class_body :: proc(p: ^Parser) -> ClassBody {
	start := cur_loc(p)

	if !expect_token(p, .LBrace) {
		return {}
	}

	// Track nesting for the parser-side private-name resolution gate.
	p.class_depth += 1
	defer p.class_depth -= 1

	// Snapshot the pending-ref boundary so refs added during this
	// class body's parse are scoped correctly. Refs declared in this
	// body resolve here; unresolved refs bubble to the outer class.
	pending_refs_before := len(p.pending_priv_refs)

	body := ClassBody{
		loc  = start,
		// Lazy alloc - zero-element class bodies (`class C {}`) appear in
		// declaration-style stubs / abstract definitions / TS-only shells.
		// Use a zero-cap make() so the allocator is set; reserve 8 only
		// when we know there's at least one element (or stray semicolon).
		body = make([dynamic]ClassElement, 0, 8, p.allocator),
	}
	// Cap bumped from 8 → 16 (S23): 323 classes on monaco had >8 elements,
	// triggering runtime grow. Class bodies tend to have many small members
	// (constructor + 5-15 methods + a few fields).
	if !is_token(p, .RBrace) && !is_token(p, .EOF) {
		reserve(&body.body, 16)
	}

	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		// Skip empty semicolons (valid class element separators in ES2022+)
		if is_token(p, .Semi) { eat(p); continue }

		prev_offset := int(cur_offset(p))
		elem := parse_class_element(p)
		if elem != nil {
			bump_append(&body.body, elem^)
		} else if int(cur_offset(p)) == prev_offset {
			// parse_class_element failed and didn't consume token - skip it to avoid infinite loop
			report_error_coded(p, .K2040_UnexpectedToken, "Invalid class element")
			recovery_eat(p)
		}
	}

	if !match_token(p, .RBrace) {
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected '}' at end of class body")
	}

	body.loc.end = prev_end_offset(p)
	report_ts_overload_chain_errors(p, body.body[:])
	report_private_class_member_errors(p, body.body[:], p.ctx.class_is_abstract)
	report_duplicate_class_member_errors(p, body.body[:])

	// §15.7.3 — resolve pending private-name references against the
	// declared names in this class body. Unresolved refs bubble up to
	// the enclosing class (added back to pending_priv_refs); if this is
	// the outermost class (depth becomes 0 after decrement), unresolved
	// refs are reported as errors.
	resolve_pending_private_refs(p, body.body[:], pending_refs_before)
	return body
}

// resolve_pending_private_refs — called at the end of parse_class_body
// to validate any PrivateName references that were queued during this
// body's parse (`pending_priv_refs[pending_refs_before:]`). References
// whose name is declared in `elements` are dropped (resolved). Others
// stay in the pending list to bubble up to the enclosing class. When
// the outermost class body finishes (class_depth would drop to 0 after
// the parse_class_body deferred decrement), any remaining unresolved
// refs are reported as syntax errors and the list is cleared.
resolve_pending_private_refs :: proc(p: ^Parser, elements: []ClassElement, pending_refs_before: int) {
	// Fast path: no refs queued during this body's parse and no
	// outstanding refs from inner classes — nothing to do. The vast
	// majority of class bodies fall here (real-world JS classes mostly
	// don't use private names at all).
	if len(p.pending_priv_refs) == 0 { return }

	declared: map[string]bool
	declared.allocator = context.temp_allocator
	defer delete(declared)

	for elem in elements {
		if elem.key == nil { continue }
		if pid, is_priv := elem.key.(^PrivateIdentifier); is_priv && pid != nil {
			if pid.name != "" { declared[pid.name] = true }
		}
	}

	write_idx := pending_refs_before
	for i in pending_refs_before..<len(p.pending_priv_refs) {
		ref := p.pending_priv_refs[i]
		if declared[ref.name] {
			continue  // resolved at this depth — drop
		}
		p.pending_priv_refs[write_idx] = ref
		write_idx += 1
	}
	resize(&p.pending_priv_refs, write_idx)

	// If this was the outermost class (class_depth is currently > 0
	// because the deferred decrement hasn't run yet — the deferred
	// statement runs AFTER us), any remaining unresolved refs at index
	// 0..pending_refs_before came from outside the outermost class and
	// would already be on the wrong side of the class_depth==0 gate.
	// Refs added at this depth (pending_refs_before..) that survived
	// the resolve are unresolved.
	if p.class_depth == 1 {
		// We were at depth 1; about to drop to 0. All pending refs are
		// unresolved — report them.
		for i in 0..<len(p.pending_priv_refs) {
			ref := p.pending_priv_refs[i]
			msg := fmt.tprintf("Private field '#%s' must be declared in an enclosing class", ref.name)
			report_error_coded_span(p, .K3032_PrivateNameInvalid, u32(ref.loc.start), u32(ref.loc.start), msg)
		}
		clear(&p.pending_priv_refs)
	}
}

// ECMA-262 §15.7.1 Static Semantics - a class body's PrivateBoundIdentifiers
// must be pairwise distinct UNLESS one is a getter and the other a setter
// with matching name (the get/set pair binds one slot). Also: the literal
// name `#constructor` is forbidden for any private member.
// Runs once per class body after every element has been parsed; walks
// elements, extracts each private key's name, and tracks per-name how
// many times it appeared as what kind. The rules:
//   * `#constructor` - always an error.
//   * `#x` + `#x` with both not being a getter/setter pair - error.
//   * `get #x` + `get #x` / `set #x` + `set #x` - error (duplicate accessor).
//   * `#x` (field / method) + `get|set #x` - error (mixed kinds).
//   * `static #x` + instance `#x` - error (private slot is shared
//     across the class; static vs instance doesn't change that).
// Resolve a ClassElement's static PropName for identifier / string /
// number keys. Returns "" for computed or unknown keys (for which the
// `prototype` check can't statically fire). Mirrors the same resolution
// that would happen on the emitter side: IdentifierName contributes its
// `name`, StringLiteral its `value`, NumericLiteral its canonical
// string form (via f64 value → string, so `0`, `0.0`, `0b0` all
// normalize to "0" for duplicate detection).
class_element_prop_name :: proc(key: ^Expression) -> string {
	if key == nil { return "" }
	#partial switch v in key^ {
	case ^Identifier:
		if v != nil { return v.name }
	case ^StringLiteral:
		if v != nil { return v.value }
	case ^NumericLiteral:
		if v != nil {
			// Canonical form: use the f64 value so `0`, `0.0`, `0b0` all
			// compare equal. fmt.tprintf produces the shortest exact form.
			return fmt.tprintf("%v", v.value)
		}
	}
	return ""
}

// TS2391 / TS2389 — overload-chain checking at parser level.
// Walks class members left-to-right looking for overload chains.
// Signatures (body-less methods) must be followed by an implementation.
// Suppressed in ambient context (declare class / .d.ts).
report_ts_overload_chain_errors :: proc(p: ^Parser, body: []ClassElement) {
	if !allow_ts_mode(p) || p.ctx.in_ambient || p.source_is_dts { return }
	if len(body) == 0 { return }

	// Pre-pass: skip pure-sig classes (no impl, single name, only methods).
	has_any_impl := false
	has_non_method := false
	has_ctor_sig := false
	name_count := 0
	last_name := ""
	for elem in body {
		if (elem.kind != .Method && elem.kind != .Constructor) || elem.abstract {
			if elem.kind != .Get && elem.kind != .Set { has_non_method = true }
			continue
		}
		val, have := elem.value.?; if !have || val == nil { has_non_method = true; continue }
		fn, is_fn := val^.(^FunctionExpression); if !is_fn || fn == nil { has_non_method = true; continue }
		if fn.body.loc.end > fn.body.loc.start {
			has_any_impl = true; break
		}
		if elem.kind == .Constructor { has_ctor_sig = true }
		else if !elem.computed && elem.key != nil {
			n := class_element_prop_name(elem.key)
			if n != "" && n != last_name { name_count += 1; last_name = n }
		}
	}
	if !has_any_impl && !has_non_method && !has_ctor_sig && name_count <= 1 {
		// Pure-sig class: no implementation, single name (or zero names).
		// If there's exactly ONE signature with ONE name AND only one method
		// total → error (ClassDeclaration9: `class C { foo(); }`).
		// If there are multiple sigs for the same name → valid overload pattern.
		if name_count == 0 { return }
		// Count total method sigs and check for modifiers.
		sig_count := 0
		has_modifier := false
		has_static_mismatch := false
		first_static_seen := false
		first_is_static := false
		for elem in body {
			if (elem.kind != .Method && elem.kind != .Constructor) || elem.abstract { continue }
			val, have := elem.value.?; if !have || val == nil { continue }
			fn, is_fn := val^.(^FunctionExpression); if !is_fn || fn == nil { continue }
			if fn.body.loc.end <= fn.body.loc.start {
				sig_count += 1
				// Accessibility modifiers or other decorations suggest this is
				// a deliberate overload/ambient pattern.
				if elem.accessibility != .None || elem.override_ { has_modifier = true }
				// Track static/instance mismatch — if sigs for the same
				// name have mixed static, that's not a valid overload.
				if !first_static_seen {
					first_is_static = elem.static
					first_static_seen = true
				} else if elem.static != first_is_static {
					has_static_mismatch = true
				}
			}
		}
		// Multiple sigs or modified sigs = overload signatures, valid.
		// BUT: static/instance mismatch within sigs is always an error.
		if (sig_count > 1 || has_modifier) && !has_static_mismatch { return }
		// Single sig, single name, no modifiers, no body = missing implementation.
		// Fall through to main pass which will report it.
	}

	// Main pass.
	chain_active := false
	chain_name := ""
	chain_static := false
	chain_start := 0

	for elem, idx in body {
		// Is this an overloadable method?
		if (elem.kind != .Method && elem.kind != .Constructor) || elem.abstract {
			if chain_active {
				report_overload_flush(p, body, chain_start, idx)
				chain_active = false
			}
			continue
		}
		// Class fields (kind=.Method but val is not FunctionExpression)
		// break the overload chain — they're non-method elements.
		val, have := elem.value.?;
		is_field := !have || val == nil
		fn: ^FunctionExpression
		is_fn: bool
		if !is_field {
			fn, is_fn = val^.(^FunctionExpression)
			if !is_fn || fn == nil { is_field = true }
		}
		if is_field {
			if chain_active {
				report_overload_flush(p, body, chain_start, idx)
				chain_active = false
			}
			continue
		}

		if elem.optional {
			if chain_active {
				report_overload_flush(p, body, chain_start, idx)
				chain_active = false
			}
			continue
		}

		name := ""
		has_name := false
		if elem.key != nil {
			if elem.computed {
				// Computed string literal keys: ["foo"]
				if sl, is_sl := elem.key^.(^StringLiteral); is_sl {
					name = sl.value; has_name = true
				}
			} else {
				n := class_element_prop_name(elem.key)
				if n != "" { name = n; has_name = true }
			}
		}
		if !has_name {
			if chain_active {
				report_overload_flush(p, body, chain_start, idx)
				chain_active = false
			}
			continue
		}

		has_body := fn.body.loc.end > fn.body.loc.start
		if chain_active {
			if has_body {
				if name != chain_name {
					report_error_coded(p, .K2070_RequiredFormOrBinding, fmt.tprintf("Function implementation name must be '%s'.", chain_name))
				}
				chain_active = false
			} else {
				if name != chain_name {
					report_overload_flush(p, body, chain_start, idx)
					chain_name = name
					chain_static = elem.static
					chain_start = idx
				}
			}
		} else {
			if !has_body {
				chain_active = true
				chain_name = name
				chain_static = elem.static
				chain_start = idx
			}
		}
	}
	if chain_active {
		report_overload_flush(p, body, chain_start, len(body))
	}
}

report_overload_flush :: proc(p: ^Parser, body: []ClassElement, start, end_excl: int) {
	for i := start; i < end_excl; i += 1 {
		elem := body[i]
		if (elem.kind != .Method && elem.kind != .Constructor) || elem.abstract { continue }
		val, have := elem.value.?; if !have || val == nil { continue }
		fn, is_fn := val^.(^FunctionExpression); if !is_fn || fn == nil { continue }
		if fn.body.loc.end > fn.body.loc.start { continue }
		report_error_coded_span(p, .K4080_DuplicateImplementation, u32(elem.loc.start), u32(elem.loc.start), "Function implementation is missing or not immediately following the declaration")
	}
}

// TS2309 — "An export assignment cannot be used in a module with other
// exported elements." Fires when `export = X` coexists with
// `export class/function/var/default/*/{ }` in the same module.
// Also catches duplicate `export =` when no regular exports exist.
// ts_enum_init_is_constant — check if an enum member initializer is a
// compile-time constant (numeric literal, string literal, unary +/-
// on numeric, reference to same-enum member, or binary ops on constants).
ts_enum_init_is_constant :: proc(init: ^Expression, member_names: ^map[string]bool) -> bool {
	if init == nil { return false }
	#partial switch v in init^ {
	case ^NumericLiteral: return true
	case ^StringLiteral: return true
	case ^Identifier:
		if v != nil && v.name in member_names^ { return true }
		return false
	case ^UnaryExpression:
		if v != nil && (v.operator == .Minus || v.operator == .Plus || v.operator == .BitwiseNot) {
			return ts_enum_init_is_constant(v.argument, member_names)
		}
	case ^BinaryExpression:
		if v != nil {
			#partial switch v.operator {
			case .BitOr, .BitAnd, .BitXor, .ShiftLeft, .ShiftRight,
			     .ShiftRightUnsigned, .Add, .Sub, .Mul, .Div, .Mod, .Pow:
				return ts_enum_init_is_constant(v.left, member_names) &&
				       ts_enum_init_is_constant(v.right, member_names)
			}
		}
	case ^ParenthesizedExpression:
		if v != nil { return ts_enum_init_is_constant(v.expression, member_names) }
	case ^MemberExpression:
		if v != nil && v.object != nil {
			if id, is_id := v.object^.(^Identifier); is_id && id != nil {
				return true
			}
		}
	case ^TemplateLiteral:
		if v != nil && len(v.expressions) == 0 { return true }
	}
	return false
}

report_ts2309_export_assignment :: proc(p: ^Parser, body: []^Statement) {
	has_assign := false
	has_regular := false
	assign_count := 0
	for stmt in body {
		if stmt == nil { continue }
		#partial switch v in stmt^ {
		case ^ExportNamedDeclaration:
			// Skip empty `export {};` (no specifiers, no declaration, no source)
			// — this is a module-type hint, not a real export.
			if v != nil {
				has_spec := len(v.specifiers) > 0
				_, has_decl := v.declaration.?; _ = has_decl
				_, has_src := v.source.?; _ = has_src
				if has_spec || has_decl || has_src {
					has_regular = true
				}
			}
		case ^ExportDefaultDeclaration: has_regular = true
		case ^ExportAllDeclaration:     has_regular = true
		case ^TSExportAssignment:
			has_assign = true
			assign_count += 1
		}
	}
	if !has_assign { return }
	if !has_regular && assign_count <= 1 { return }
	msg := "An export assignment cannot be used in a module with other exported elements."
	for stmt in body {
		if stmt == nil { continue }
		#partial switch v in stmt^ {
		case ^ExportNamedDeclaration:
			report_error_coded_span(p, .K3021_ExportDefaultRestrictions, u32(v.loc.start), u32(v.loc.start), msg)
		case ^ExportDefaultDeclaration:
			report_error_coded_span(p, .K3021_ExportDefaultRestrictions, u32(v.loc.start), u32(v.loc.start), msg)
		case ^ExportAllDeclaration:
			report_error_coded_span(p, .K3021_ExportDefaultRestrictions, u32(v.loc.start), u32(v.loc.start), msg)
		case ^TSExportAssignment:
			if has_regular || assign_count > 1 {
				report_error_coded_span(p, .K3021_ExportDefaultRestrictions, u32(v.loc.start), u32(v.loc.start), msg)
			}
		}
	}
}

// TS1221 / TS1040 — generators and async are forbidden in ambient contexts.
// OXC's parser catches these at parser level. The broader TS1036
// "Statements are not allowed in ambient contexts" is deferred to the
// checker because OXC doesn't enforce it at parser level for many
// statement types (break, return, with, etc.).
report_ts_ambient_function_errors :: proc(p: ^Parser, body: []^Statement) {
	for stmt in body {
		if stmt == nil { continue }
		#partial switch v in stmt^ {
		case ^FunctionDeclaration:
			if v != nil {
				if v.generator {
					report_error_coded_span(p, .K4050_AmbientContextRestriction, u32(v.loc.start), u32(v.loc.start), "Generators are not allowed in an ambient context")
				}
				if v.async {
					report_error_coded_span(p, .K4032_ModifierMisplaced, u32(v.loc.start), u32(v.loc.start), "'async' modifier cannot be used in an ambient context")
				}
			}
		case ^ExportNamedDeclaration:
			// Check exported functions too: `export async function f();`
			if v != nil {
				if decl_stmt, has := v.declaration.?; has && decl_stmt != nil {
					if fn, ok := decl_stmt^.(^FunctionDeclaration); ok && fn != nil {
						if fn.generator {
							report_error_coded_span(p, .K4050_AmbientContextRestriction, u32(fn.loc.start), u32(fn.loc.start), "Generators are not allowed in an ambient context")
						}
						if fn.async {
							report_error_coded_span(p, .K4032_ModifierMisplaced, u32(fn.loc.start), u32(fn.loc.start), "'async' modifier cannot be used in an ambient context")
						}
					}
				}
			}
		}
	}
}

// TS2391 / TS2389 — top-level function overload chain validation.
// Walks a statement list looking for consecutive FunctionDeclaration
// overload signatures. An overload chain is a sequence of body-less
// FunctionDeclarations with the same name, optionally followed by an
// implementation (with body). If the chain ends without an impl, or
// the impl has a different name, report the error.
report_ts_function_overload_errors :: proc(p: ^Parser, body: []^Statement) {
	if len(body) == 0 { return }

	chain_active := false
	chain_name := ""
	chain_start_loc: u32 = 0

	for stmt in body {
		if stmt == nil { continue }
		fn, is_fn := stmt^.(^FunctionDeclaration)
		if !is_fn || fn == nil {
			// Non-function statement breaks the chain.
			if chain_active {
				report_error_coded_span(p, .K4080_DuplicateImplementation, u32(chain_start_loc), u32(chain_start_loc), "Function implementation is missing or not immediately following the declaration")
				chain_active = false
			}
			continue
		}
		// Skip ambient / declare functions — they're allowed without bodies.
		if fn.declare { continue }
		has_body := !fn.no_body
		name := ""
		if id, has_id := fn.expr.id.?; has_id { name = id.name }
		if name == "" {
			if chain_active {
				report_error_coded_span(p, .K4080_DuplicateImplementation, u32(chain_start_loc), u32(chain_start_loc), "Function implementation is missing or not immediately following the declaration")
				chain_active = false
			}
			continue
		}

		if chain_active {
			if has_body {
				// Implementation found.
				if name != chain_name {
					// TS2389: impl name doesn't match overload chain.
					msg := fmt.tprintf("Function implementation name must be '%s'.", chain_name)
					report_error_coded_span(p, .K2070_RequiredFormOrBinding, u32(fn.expr.loc.start), u32(fn.expr.loc.start), msg)
				}
				chain_active = false
			} else {
				// Another signature.
				if name != chain_name {
					// Different name → flush old chain, start new.
					report_error_coded_span(p, .K4080_DuplicateImplementation, u32(chain_start_loc), u32(chain_start_loc), "Function implementation is missing or not immediately following the declaration")
					chain_name = name
					chain_start_loc = fn.expr.loc.start
				}
				// Same name: chain continues.
			}
		} else {
			if !has_body {
				// Start new chain.
				chain_active = true
				chain_name = name
				chain_start_loc = fn.expr.loc.start
			}
		}
	}
	// End of body — flush any pending chain.
	if chain_active {
		report_error_coded_span(p, .K4080_DuplicateImplementation, u32(chain_start_loc), u32(chain_start_loc), "Function implementation is missing or not immediately following the declaration")
	}

	// TS2384 — overload signatures must all be ambient or non-ambient.
	// Mixed `declare function foo()` and `function foo()` in same scope.
	{
		AmbState :: struct { has_ambient: bool, has_nonamb: bool }
		amb_seen: map[string]AmbState
		amb_seen.allocator = context.temp_allocator
		for stmt2 in body {
			if stmt2 == nil { continue }
			fn2, ok2 := stmt2^.(^FunctionDeclaration)
			if !ok2 || fn2 == nil { continue }
			name2 := ""
			if id2, has2 := fn2.expr.id.?; has2 { name2 = id2.name }
			if name2 == "" { continue }
			entry := amb_seen[name2] or_else AmbState{}
			if fn2.declare { entry.has_ambient = true }
			else { entry.has_nonamb = true }
			amb_seen[name2] = entry
		}
		for stmt2 in body {
			if stmt2 == nil { continue }
			fn2, ok2 := stmt2^.(^FunctionDeclaration)
			if !ok2 || fn2 == nil { continue }
			name2 := ""
			if id2, has2 := fn2.expr.id.?; has2 { name2 = id2.name }
			if name2 == "" { continue }
			entry := amb_seen[name2] or_else AmbState{}
			if entry.has_ambient && entry.has_nonamb {
				report_error_coded_span(p, .K4050_AmbientContextRestriction, u32(fn2.expr.loc.start), u32(fn2.expr.loc.start), "Overload signatures must all be ambient or non-ambient")
				delete_key(&amb_seen, name2)
			}
		}
	}

	// TS2393 — duplicate function implementation.
	// Two or more FunctionDeclarations with the same name AND a body
	// in the same scope is an error (each flagged).
	impl_count: map[string]int
	impl_count.allocator = context.temp_allocator
	for stmt2 in body {
		if stmt2 == nil { continue }
		fn2, ok2 := stmt2^.(^FunctionDeclaration)
		if !ok2 || fn2 == nil || fn2.declare || fn2.no_body { continue }
		name2 := ""
		if id2, has2 := fn2.expr.id.?; has2 { name2 = id2.name }
		if name2 == "" { continue }
		impl_count[name2] = (impl_count[name2] or_else 0) + 1
	}
	for stmt2 in body {
		if stmt2 == nil { continue }
		fn2, ok2 := stmt2^.(^FunctionDeclaration)
		if !ok2 || fn2 == nil || fn2.declare || fn2.no_body { continue }
		name2 := ""
		if id2, has2 := fn2.expr.id.?; has2 { name2 = id2.name }
		if name2 == "" { continue }
		if impl_count[name2] >= 2 {
			report_error_coded_span(p, .K4080_DuplicateImplementation,
				u32(fn2.expr.loc.start), u32(fn2.expr.loc.start),
				"Duplicate function implementation")
		}
	}
}

// report_duplicate_class_member_errors — detect duplicate PUBLIC class
// member names. Matches OXC's parser-level TS2300 / TS1117 checks:
//   * property + property → duplicate
//   * property + method → duplicate
//   * property + accessor → duplicate
//   * get + get (same static) → duplicate
//   * set + set (same static) → duplicate
//   * get + set → OK (complementary pair)
// Static and instance are separate namespaces. TS overload signatures
// (body-less methods) are excluded. Computed properties are excluded.
report_duplicate_class_member_errors :: proc(p: ^Parser, elems: []ClassElement) {
	if !allow_ts_mode(p) { return }  // JS uses the private-only check
	if p.ctx.in_ambient || p.source_is_dts { return }

	MemberSeen :: struct {
		has_get:                       bool,
		has_set:                       bool,
		has_prop:                      bool,  // property / field
		has_prop_init:                 bool,  // property with initializer (= value)
		has_method:                    bool,  // method with body (not overload sig)
		has_method_with_type_params:   bool,  // method body + type parameters
	}

	static_seen:   map[string]MemberSeen
	instance_seen: map[string]MemberSeen
	static_seen.allocator   = context.temp_allocator
	instance_seen.allocator = context.temp_allocator

	constructor_impl_count := 0

	for elem in elems {
		if elem.key == nil { continue }
		// Skip private identifiers — handled by report_private_class_member_errors.
		if _, is_priv := elem.key.(^PrivateIdentifier); is_priv { continue }

		name := ""
		has_name := false
		if elem.computed {
			// Computed keys: only check string literals (["foo"]).
			if sl, is_sl := elem.key^.(^StringLiteral); is_sl {
				name = sl.value
				has_name = true  // empty string is valid computed key
			} else {
				continue  // dynamic [expr] — can't check
			}
		} else {
			name = class_element_prop_name(elem.key)
			if name != "" { has_name = true }
		}
		if !has_name { continue }

		// TS duplicate constructor: multiple constructor implementations.
		// Overload signatures (no body) are fine.
		if elem.kind == .Constructor {
			if val, have := elem.value.?; have && val != nil {
				if fn, is_fn := val^.(^FunctionExpression); is_fn && fn != nil {
					has_body := fn.body.loc.end > fn.body.loc.start
					if has_body {
						constructor_impl_count += 1
						if constructor_impl_count > 1 {
							report_error_coded_span(p, .K4080_DuplicateImplementation,
								u32(elem.loc.start), u32(elem.loc.start),
								"Duplicate constructor implementations are not allowed")
						}
					}
				}
			}
			continue  // constructors don't enter the name map
		}

		// TS overload signatures (body-less methods): skip from dup map.
		// Override methods: skip (override can repeat with different modifiers).
		// Properties without initializers (kind=.Method, val=nil) must NOT
		// be treated as overloads — they're field declarations.
		if elem.kind == .Method {
			if elem.override_ { continue }
			is_overload := false
			if val, have := elem.value.?; have && val != nil {
				if fn, is_fn := val^.(^FunctionExpression); is_fn && fn != nil {
					if fn.body.loc.end <= fn.body.loc.start {
						is_overload = true  // body-less method sig
					}
				}
			}
			if is_overload { continue }
		}

		// Abstract members: skip (they have no body, handled by overload logic).
		if elem.abstract { continue }

		seen := elem.static ? &static_seen : &instance_seen
		prev := seen[name] or_else MemberSeen{}
		dup := false

		// Distinguish real methods from properties: kind=.Method is the
		// AST default for ALL class elements. A real method has a
		// FunctionExpression value; everything else is a property/field.
		is_real_method := false
		has_type_params := false
		if elem.kind == .Method {
			if v, hv := elem.value.?; hv && v != nil {
				if fn, ok := v^.(^FunctionExpression); ok {
					is_real_method = true
					if fn != nil {
						if tp, have_tp := fn.type_parameters.?; have_tp && tp != nil {
							has_type_params = true
						}
					}
				}
			}
		}

		switch {
		case elem.kind == .Get:
			if prev.has_get || prev.has_prop { dup = true }
			prev.has_get = true
		case elem.kind == .Set:
			if prev.has_set || prev.has_prop { dup = true }
			prev.has_set = true
		case is_real_method:
			// Method vs property/accessor = duplicate.
			if prev.has_get || prev.has_set || prev.has_prop { dup = true }
			// TS2393: Two methods with bodies (implementations) = duplicate
			// function implementation. Overload sigs are fine (they were
			// skipped above), but two real bodies means a true dup.
			// Skip when EITHER method has type parameters — different type
			// params may constitute valid generic overloads that OXC accepts.
			if prev.has_method && !has_type_params && !prev.has_method_with_type_params { dup = true }
			prev.has_method = true
			if has_type_params { prev.has_method_with_type_params = true }
		case elem.kind == .Constructor:
			// handled above
		case:
			// Property / field (including kind=.Method with non-FE value).
			// Property vs accessor or method = dup.
			// Property vs property: dup when BOTH have initializers
			// (e.g. `0 = 1; 0.0 = 2;`), OR when both are computed string
			// keys (["a"]: string; ["a"]: string;). Non-computed
			// declarations without initializers (x; x?: number;) are
			// valid TS redeclarations.
			has_init := false
			if v, hv := elem.value.?; hv && v != nil { has_init = true }
			if prev.has_get || prev.has_set || prev.has_method { dup = true }
			if has_init && prev.has_prop_init { dup = true }
			if elem.computed && prev.has_prop { dup = true }  // computed string dups
			// Numeric keys: `1; 1.0;` are dups even without initializers
			// (numeric normalization makes them the same property).
			is_numeric_key := false
			if elem.key != nil {
				if _, is_num := elem.key^.(^NumericLiteral); is_num { is_numeric_key = true }
			}
			if is_numeric_key && prev.has_prop { dup = true }
			prev.has_prop = true
			if has_init { prev.has_prop_init = true }
		}
		seen[name] = prev

		if dup {
			msg := fmt.tprintf("Duplicate identifier '%s'.", name)
			report_error_coded_span(p, .K3037_DuplicateIdentifier, u32(elem.loc.start), u32(elem.loc.start), msg)
		}
	}
}

// report_duplicate_interface_member_errors — TS1117: duplicate property
// names in interfaces / object type literals. Method signatures with
// the same name are allowed (overloads). Only property+property and
// property+accessor conflicts are flagged.
report_duplicate_interface_member_errors :: proc(p: ^Parser, members: []^TSSignature) {
	if !allow_ts_mode(p) { return }

	MemberSeen :: struct { has_prop: bool, has_get: bool, has_set: bool }
	seen: map[string]MemberSeen
	seen.allocator = context.temp_allocator

	for sig in members {
		if sig == nil { continue }
		key: ^Expression
		computed := false
		is_method := false
		kind := TSMethodSignatureKind.Method
		#partial switch s in sig^ {
		case TSPropertySignature:
			key = s.key; computed = s.computed
		case TSMethodSignature:
			key = s.key; computed = s.computed; is_method = true; kind = s.kind
		case:
			continue  // call/construct/index signatures don't have names
		}
		if key == nil { continue }
		if is_method && kind == .Method { continue }  // method overloads OK

		name := ""
		if computed {
			if sl, is_sl := key^.(^StringLiteral); is_sl { name = sl.value }
			else { continue }
		} else {
			name = class_element_prop_name(key)
		}
		if name == "" { continue }

		prev := seen[name] or_else MemberSeen{}
		dup := false
		switch kind {
		case .Get:
			if prev.has_get || prev.has_prop { dup = true }
			prev.has_get = true
		case .Set:
			if prev.has_set || prev.has_prop { dup = true }
			prev.has_set = true
		case .Method:
			// Already continued above for methods
		}
		if !is_method {
			// In interfaces/type literals, only NUMERIC key dups are errors
			// (e.g. `1; 1.0;` normalize to the same number). String/identifier
			// dups are valid TS declaration merging (`x: number; x: string;`).
			is_numeric := false
			if key != nil {
				if _, is_num := key^.(^NumericLiteral); is_num { is_numeric = true }
			}
			if is_numeric && prev.has_prop { dup = true }
			if prev.has_get || prev.has_set { dup = true }
			prev.has_prop = true
		}
		seen[name] = prev

		if dup {
			// Get the start offset from the key expression.
			loc := u32(0)
			if key != nil {
				#partial switch v in key^ {
				case ^Identifier: loc = v.loc.start
				case ^StringLiteral: loc = v.loc.start
				case ^NumericLiteral: loc = v.loc.start
				}
			}
			msg := fmt.tprintf("Duplicate identifier '%s'.", name)
			report_error_coded_span(p, .K3037_DuplicateIdentifier, u32(loc), u32(loc), msg)
		}
	}
}

report_private_class_member_errors :: proc(p: ^Parser, elems: []ClassElement, class_is_abstract := false) {
	PrivateSeen :: struct {
		has_get: bool,
		has_set: bool,
		has_other: bool,  // field or method
		get_static: bool,
		set_static: bool,
	}
	seen: map[string]PrivateSeen
	seen.allocator = p.allocator
	defer delete(seen)

	// §15.7.1 — track constructor bodies (JS only, TS defers to checker).
	constructor_count := 0

	// TS: abstract members in non-abstract class.
	if allow_ts_mode(p) && !class_is_abstract {
		for elem in elems {
			if elem.abstract {
				report_error_coded(p, .K2040_UnexpectedToken, "Abstract methods can only appear within an abstract class.")
				break  // one diagnostic per class
			}
		}
	}

	for elem in elems {
		if elem.key == nil { continue }

		// TS: static + abstract is invalid.
		if elem.static && elem.abstract && allow_ts_mode(p) {
			report_error_coded(p, .K4032_ModifierMisplaced, "'static' modifier cannot be used with 'abstract' modifier")
		}
		// TS1242 — constructors cannot be abstract.
		if elem.kind == .Constructor && elem.abstract && allow_ts_mode(p) {
			report_error_coded(p, .K4020_ConstructorTSModifier, "'abstract' modifier cannot appear on a constructor declaration")
		}

		// TS: abstract on a private identifier (#name) is invalid for
		// fields/properties. Private methods CAN be abstract.
		if elem.abstract && allow_ts_mode(p) {
			if _, is_priv := elem.key.(^PrivateIdentifier); is_priv {
				is_method := false
				if val, have := elem.value.?; have && val != nil {
					if _, is_fn := val^.(^FunctionExpression); is_fn {
						is_method = true
					}
				}
				if !is_method {
					report_error_coded(p, .K4021_PrivateNameWithModifier, "'abstract' modifier cannot be used with a private identifier")
				}
			}
		}

		// §15.7.1 - static ClassElement whose PropName is `"prototype"`
		// is a SyntaxError. Applies to every static kind: field, method,
		// getter, setter, accessor. Non-static `prototype` is legal.
		if elem.static && !elem.computed && !p.ctx.in_ambient {
			if class_element_prop_name(elem.key) == "prototype" {
				report_error_coded(p, .K3030_ClassDeclarationStructure, "Classes may not have a static member named 'prototype'")
			}
		}

		// §15.7.1 — at most one constructor. TS overload signatures
		// have `FunctionBody.loc.start == 0` (body ended with
		// `;`, `parse_function_body` was not called). Real
		// constructors have a non-zero body start (from `{`).
		// §15.7.1 "A class definition can have at most one constructor."
		// In TS mode, multiple constructor bodies are deferred to the
		// semantic checker (overload patterns are valid). In JS mode,
		// duplicate constructors are always a parse error.
		if !allow_ts_mode(p) && !elem.static && !elem.computed && elem.kind == .Constructor {
			if val, has_val := elem.value.?; has_val && val != nil {
				if fn, is_fn := val^.(^FunctionExpression); is_fn && fn != nil {
					if fn.body.loc.end > fn.body.loc.start {
						constructor_count += 1
						if constructor_count > 1 {
							report_error_coded(p, .K3034_ConstructorShape, "Multiple constructor implementations are not allowed")
						}
					}
				}
			}
		}

		pid, is_private := elem.key.(^PrivateIdentifier)
		if !is_private || pid == nil { continue }
		name := pid.name
		if name == "constructor" {
			report_error_coded(p, .K3030_ClassDeclarationStructure, "Class private member name cannot be '#constructor'")
			continue
		}
		// TS overload signatures (body-less methods/constructors): skip
		// from the dup map entirely so the implementation can be added
		// without false-flagging. Private fields (kind=.Method but val
		// is not FE) must NOT be skipped.
		if allow_ts_mode(p) && (elem.kind == .Method || elem.kind == .Constructor) {
			is_overload := false
			if val, has_val := elem.value.?; has_val && val != nil {
				if fn, is_fn := val^.(^FunctionExpression); is_fn && fn != nil {
					if len(fn.body.body) == 0 && len(fn.body.directives) == 0 {
						is_overload = true  // body-less method sig
					}
				}
			}
			if is_overload { continue }
		}
		prev, _ := seen[name]
		dup := false
		static_mismatch := false
		switch elem.kind {
		case .Get:
			if prev.has_get || prev.has_other { dup = true }
			if prev.has_set && prev.set_static != elem.static { static_mismatch = true }
			prev.has_get = true
			prev.get_static = elem.static
		case .Set:
			if prev.has_set || prev.has_other { dup = true }
			if prev.has_get && prev.get_static != elem.static { static_mismatch = true }
			prev.has_set = true
			prev.set_static = elem.static
		case .Method, .Constructor, .StaticBlock:
			if prev.has_get || prev.has_set || prev.has_other { dup = true }
			prev.has_other = true
		}
		seen[name] = prev
		// §15.7.1 — PrivateBoundIdentifiers must be pairwise distinct,
		// except a single get/set pair on the same name. TS body-less
		// overload signatures were skipped above and don't enter `seen`.
		if dup {
			msg := fmt.tprintf("Duplicate private name '#%s'", name)
			report_error_coded_span(p, .K3032_PrivateNameInvalid, u32(elem.loc.start), u32(elem.loc.start), msg)
		}
		// §15.7.1 — static and instance elements cannot share the same
		// private name.
		if static_mismatch {
			msg := fmt.tprintf("Duplicate private name '#%s'. Static and instance elements cannot share the same private name.", name)
			report_error_coded_span(p, .K3032_PrivateNameInvalid, u32(elem.loc.start), u32(elem.loc.start), msg)
		}
	}
}

// ClassMemberModifiers is the loose TS modifier prefix that may appear in
// front of a class member name: [accessibility] [static] [abstract]
// [override] [readonly] [declare]. The parser captures the set permissively
// (any order, matching OXC/typescript-eslint); an enforcing type-checker owns
// the remaining duplicate/ordering rules.
ClassMemberModifiers :: struct {
	static_:       bool,
	is_abstract:   bool,
	accessibility: ClassAccessibility,
	access_name:   string,
	is_readonly:   bool,
	is_override:   bool,
	is_declare:    bool,
}

// ClassModifierScan adds the transient order bookkeeping used only while
// scanning the prefix; only `mods` escapes to the caller.
ClassModifierScan :: struct {
	using mods:     ClassMemberModifiers,
	mod_order_idx:  int,
	access_order:   int,
	static_order:   int,
	readonly_order: int,
}

// class_modifier_set_access records an accessibility modifier (public /
// private / protected). A second accessibility modifier is reported but still
// consumed so the scan can continue past it.
class_modifier_set_access :: proc(p: ^Parser, st: ^ClassModifierScan, access: ClassAccessibility, name: string) -> bool {
	if st.accessibility == .None {
		st.accessibility = access; st.access_name = name; st.access_order = st.mod_order_idx
		eat(p); return true
	}
	report_error_coded(p, .K4031_DuplicateModifier, "Accessibility modifier already seen")
	eat(p)
	return true
}

// class_modifier_consume_ident handles the contextual-keyword modifiers that
// the lexer emits as plain Identifier tokens (not reserved words): the three
// accessibility keywords plus `readonly` and TS `declare`.
class_modifier_consume_ident :: proc(p: ^Parser, st: ^ClassModifierScan) -> bool {
	switch cur_value(p) {
	case "public":    return class_modifier_set_access(p, st, .Public, "public")
	case "private":   return class_modifier_set_access(p, st, .Private, "private")
	case "protected": return class_modifier_set_access(p, st, .Protected, "protected")
	case "readonly":
		if !st.is_readonly { st.is_readonly = true; st.readonly_order = st.mod_order_idx; eat(p); return true }
	case "declare":
		if !st.is_declare  { st.is_declare  = true; eat(p); return true }
	}
	return false
}

// class_modifier_consume applies one modifier token to `st` and reports
// whether it was consumed. `static` / `abstract` / `override` are reserved
// keyword tokens matched by kind; the rest are contextual identifiers.
class_modifier_consume :: proc(p: ^Parser, cur: TokenType, st: ^ClassModifierScan) -> bool {
	#partial switch cur {
	case .Static:
		if !st.static_     { st.static_     = true; st.static_order = st.mod_order_idx; eat(p); return true }
	case .Abstract:
		if !st.is_abstract { st.is_abstract = true; eat(p); return true }
	case .Override:
		if !st.is_override { st.is_override = true; eat(p); return true }
	case .Identifier:
		return class_modifier_consume_ident(p, st)
	}
	return false
}

// reject_adjacent_static_modifiers reproduces OXC's rejection of
// `static\nstatic <name>` when the second `static` and the name token sit on
// the same line (both read as modifiers → conflict). When the name is on a
// separate line OXC does ASI and accepts, so we peek two tokens ahead and only
// reject when the third token is on the same line as the second `static`.
reject_adjacent_static_modifiers :: proc(p: ^Parser) {
	if is_token(p, .Static) && p.lexer != nil {
		ensure_nxt(p)
	}
	if is_token(p, .Static) && p.lexer != nil && p.lexer.nxt.kind == .Static &&
	   (p.lexer.nxt.flags & FLAG_NEW_LINE) != 0 {
		snap_ss := lexer_snapshot(p)
		advance_token(p) // consume first `static`
		advance_token(p) // consume second `static` → cur = third token
		third_on_same_line := !cur_has_newline(p)
		third_type := p.cur_type
		lexer_restore(p, snap_ss)
		if third_on_same_line && third_type != .RBrace && third_type != .Semi &&
		   third_type != .EOF {
			eat(p)       // consume first `static` (field name)
			eat(p)       // consume second `static` (would-be modifier)
			report_error_coded(p, .K2010_ExpectedSemicolon, fmt.tprintf("Expected `;` but found `%s`", cur_value(p)))
		}
	}
}

// check_class_modifier_order enforces the OXC parser-level modifier ordering
// rules (accessibility before static/readonly, static before readonly) from
// the order indices recorded during the scan. TS-mode only.
check_class_modifier_order :: proc(p: ^Parser, st: ^ClassModifierScan) {
	if !allow_ts_mode(p) {
		return
	}
	if st.access_order >= 0 && st.static_order >= 0 && st.access_order > st.static_order {
		report_error_coded(p, .K4030_ModifierOrder, fmt.tprintf("'%s' modifier must precede 'static' modifier", st.access_name))
	}
	if st.access_order >= 0 && st.readonly_order >= 0 && st.access_order > st.readonly_order {
		report_error_coded(p, .K4030_ModifierOrder, fmt.tprintf("'%s' modifier must precede 'readonly' modifier", st.access_name))
	}
	if st.static_order >= 0 && st.readonly_order >= 0 && st.static_order > st.readonly_order {
		report_error_coded(p, .K4030_ModifierOrder, "'static' modifier must precede 'readonly' modifier")
	}
}

// parse_class_member_modifiers consumes the loose modifier prefix and returns
// the captured set. A modifier token is only treated as a modifier when the
// NEXT token plausibly continues the member signature — `( = ; , }` (and TS
// `< ! ? :`) mean the keyword is the member NAME (e.g. `readonly()`), and a
// LineTerminator triggers ASI (`public\n foo()` → field `public`). `static`
// is exempt from that ASI rule per the ES grammar.
parse_class_member_modifiers :: proc(p: ^Parser) -> ClassMemberModifiers {
	st: ClassModifierScan
	st.accessibility = .None
	st.access_order = -1
	st.static_order = -1
	st.readonly_order = -1
	for i := 0; i < 12; i += 1 {
		cur := p.cur_type
		ensure_nxt(p)
		nxt := p.lexer.nxt.kind
		is_member_start := nxt == .LParen || nxt == .Assign || nxt == .Semi ||
		                   nxt == .Comma || nxt == .RBrace ||
		                   (allow_ts_mode(p) && (nxt == .LAngle || nxt == .Not || nxt == .Question || nxt == .Colon))
		if is_member_start {
			break
		}
		ensure_nxt(p)
		if (p.lexer.nxt.flags & FLAG_NEW_LINE) != 0 && cur != .Static {
			break
		}
		consumed := class_modifier_consume(p, cur, &st)
		if consumed {
			st.mod_order_idx += 1
		} else {
			break
		}
	}
	reject_adjacent_static_modifiers(p)
	check_class_modifier_order(p, &st)
	return st.mods
}


// try_consume_ts_class_index_signature detects and consumes a TS index
// signature in a class body (`[s: string]: number`) when the `[` clearly
// opens one (`[ Identifier (: | ?:) ...`). Mirrors parse_ts_object_member's
// index-signature arm. Returns true when an index signature was consumed —
// the caller then drops the element (returns nil), matching the existing
// pattern for parser-intentionally-dropped elements (TS overload signatures
// don't materialize either). Returns false when the `[` is an ordinary
// computed property key; the lexer cursor is left untouched in that case so
// the caller can parse the computed key.
try_consume_ts_class_index_signature :: proc(p: ^Parser, accessibility: ClassAccessibility, access_name: string) -> bool {
	ensure_nxt(p)
	if !(allow_ts_mode(p) && p.lexer.nxt.kind == .Identifier) {
		return false
	}
	// Two-token lookahead: nxt is the identifier, nxt.nxt would be `:`.
	// We don't have a 2-tok-ahead helper, so snapshot+probe.
	snap := lexer_snapshot(p)
	eat(p)  // consume `[`
	eat(p)  // consume identifier
	ensure_nxt(p)
	is_index_sig := is_token(p, .Colon) ||
	                (is_token(p, .Question) && p.lexer.nxt.kind == .Colon)
	lexer_restore(p, snap)
	if !is_index_sig {
		return false
	}
	// Confirmed: parse and discard the index signature. Same shape
	// as parse_ts_object_member's index-signature arm.
	if accessibility != .None {
		report_error_coded(p, .K4032_ModifierMisplaced, fmt.tprintf("'%s' modifier cannot appear on an index signature", access_name))
	}
	eat(p)            // `[`
	eat(p)            // identifier
	if match_token(p, .Question) {
		report_error_coded(p, .K4063_OptionalAndInit, "An index signature parameter cannot have a question mark")
	}
	expect_token(p, .Colon)
	_ = parse_ts_type(p)
	expect_token(p, .RBracket)
	if is_token(p, .Colon) && allow_ts_mode(p) {
		_ = parse_ts_type_annotation(p)
	} else if allow_ts_mode(p) {
		report_error_coded(p, .K4055_IndexSignatureForm, "An index signature must have a type annotation")
	}
	match_semicolon_or_asi(p)
	return true
}

parse_class_element :: proc(p: ^Parser) -> ^ClassElement {
	decorators := parse_decorators(p)
	start := cur_loc(p)
	if len(decorators) > 0 { start.start = decorators[0].loc.start }

	// Check for static block: static { ... }
	if is_token(p, .Static) && is_next_token(p, .LBrace) {
		if len(decorators) > 0 {
			report_error_coded(p, .K4064_DecoratorInvalid, "Decorators are not valid here")
		}
		elem := parse_static_block(p, start)
		if elem != nil { elem.decorators = decorators }
		return elem
	}

	mods := parse_class_member_modifiers(p)
	static_       := mods.static_
	is_abstract   := mods.is_abstract
	accessibility := mods.accessibility
	access_name   := mods.access_name
	is_readonly   := mods.is_readonly
	is_override   := mods.is_override
	is_declare    := mods.is_declare

	kind := ClassElementKind.Method
	is_async := false
	is_generator := false
	computed := false
	is_private := false
	is_accessor := false

	// Check for `accessor` keyword (Stage-3 decorators auto-accessor):
	//   accessor PropertyName Initializer_opt
	// `accessor` is contextual - it's the auto-accessor keyword only when
	// the NEXT token can start a class element name AND there's no
	// LineTerminator between them. Otherwise it's a plain identifier name
	// (field, method, or get/set accessor name). The exclusion list
	// matches the Stage-3 grammar production:
	//   - LParen / Semi / RBrace → method/field named `accessor` itself
	//   - Assign / Comma           → field initializer or list `accessor = 42;`
	//   - LineTerminator           → ASI-style bare field `accessor\n a;`
	// Test262 staging/decorators/accessor-as-identifier.js.
	if is_token(p, .Accessor) {
		next := peek_token(p)
		next_starts_name := next.type != .LParen && next.type != .Semi &&
		                    next.type != .RBrace && next.type != .Assign &&
		                    next.type != .Comma
		// peek_token returns the next non-whitespace token; check its
		// had_line_terminator flag to detect ASI between `accessor` and
		// the next token. The peek result's flag reflects whether a LT
		// crossed BEFORE that token, which is exactly the ASI condition.
		next_on_same_line := !next.had_line_terminator
		if next_starts_name && next_on_same_line {
			is_accessor = true
			eat(p)
		}
	}

	// Check for async keyword
	if !is_accessor && is_token(p, .Async) {
		// Only treat `async` as a modifier if followed by something that
		// starts a method name AND there's no line terminator between them.
		// When `async` is followed by `(` or `<` it IS the method name
		// (e.g. `async() {}`, `async<T>() {}`).
		next := peek_token(p)
		looks_like_async_method := next.type == .Identifier || next.type == .PrivateIdentifier ||
			next.type == .LBracket || next.type == .String || next.type == .Number ||
			next.type == .BigInt || next.type == .Mul ||
			is_keyword_usable_as_property_name(next.type)
		if looks_like_async_method && !next.had_line_terminator {
			is_async = true
			eat(p) // consume async
		}
	}

	// Check for get/set accessor keywords. `get` / `set` are contextual
	// keywords - valid as plain class-member names too. The accessor
	// promotion fires only when the next token can begin a property name
	// (identifier, string, computed-name `[`, generator `*`, or any
	// keyword usable as a property name). Tokens like `=` (field init),
	// `:` (TS type annotation), `?` (TS optional field), `,` `;` `(` `}`
	// (separators / immediate body) keep `get` / `set` as the field name
	// (e.g. `public get = function() {}`, `set: boolean;`).
	if is_token(p, .Get) || is_token(p, .Set) {
		is_getter := is_token(p, .Get)
		next := peek_token(p)
		looks_like_accessor_name := next.type == .Identifier || next.type == .String ||
			next.type == .Number || next.type == .BigInt || next.type == .LBracket ||
			next.type == .Mul || next.type == .PrivateIdentifier ||
			is_keyword_usable_as_property_name(next.type)
		if looks_like_accessor_name {
			if is_getter {
				kind = .Get
			} else {
				kind = .Set
			}
			if is_async {
				report_error_coded(p, .K3012_AsyncGeneratorMisplaced,
					"'async' modifier cannot be used here")
			}
			eat(p) // consume get/set keyword
		}
	}

	// Check for generator method: *name()
	if !is_generator && is_token(p, .Mul) {
		is_generator = true
		eat(p) // consume *
	}

	// Parse method/property name
	key: ^Expression
	if is_token(p, .PrivateIdentifier) {
		// Private field or method: #field, #method
		current := snap_current(p)
		is_private = true
		// Accessibility modifiers are not allowed on private (#) fields.
		if accessibility != .None {
			report_error_coded(p, .K4021_PrivateNameWithModifier, "An accessibility modifier cannot be used with a private identifier")
		}

		// Create PrivateIdentifier (strip the # prefix)
		name := current.value
		if len(name) > 0 && name[0] == '#' {
			name = name[1:]
		}

		private_ident, private_ident_e := new_expr(p, PrivateIdentifier)
		private_ident.loc = loc_from_token(&current)
		private_ident.name = name
		key = private_ident_e
		p.private_id_count += 1
		eat(p)
	} else if is_token(p, .String) {
		// String key: `get 'trusting-append'()` / `'method-name'()`. ESTree emits
		// this as a Literal key, not an Identifier. Previously stuffed into
		// new_identifier which copied the quoted raw source into `name`,
		// hiding the real string from downstream walkers (ember.js etc.).
		current := snap_current(p)
		str_lit, str_lit_e := new_expr(p, StringLiteral)
		str_lit.loc = loc_from_token(&current)
		str_lit.value = current.literal.(string) or_else ""
		str_lit.raw = current.value
		key = str_lit_e
		eat(p)
		// String-literal key "constructor" promotes to Constructor kind,
		// same rules as the identifier path: no get/set, no async/generator,
		// and must be non-static.
		if str_lit.value == "constructor" &&
		   kind == .Method && !is_async && !is_generator && !static_ {
			kind = .Constructor
		}
		// §15.7.6 — string-literal "constructor" must not be get/set/async/generator.
		if !static_ && str_lit.value == "constructor" {
			if is_async { report_error_coded(p, .K3034_ConstructorShape, "Constructor can't be an async method") }
			if is_generator { report_error_coded(p, .K3034_ConstructorShape, "Constructor can't be a generator") }
		}
	} else if is_token(p, .Number) {
		// Numeric key: `1234()`. Similarly emit as NumericLiteral-backed Literal
		// rather than an Identifier whose name is the numeric text.
		current := snap_current(p)
		num_lit, num_lit_e := new_expr(p, NumericLiteral)
		num_lit.loc = loc_from_token(&current)
		num_lit.raw = current.value
		if v, ok := current.literal.(f64); ok {
			num_lit.value = v
		}
		key = num_lit_e
		eat(p)
	} else if is_token(p, .BigInt) {
		// BigInt key: `1n()`. Emit as BigIntLiteral per §13.2.3.
		current := snap_current(p)
		big, big_e := new_expr(p, BigIntLiteral)
		big.loc = loc_from_token(&current)
		big.raw = current.value
		if len(current.value) > 0 && current.value[len(current.value)-1] == 'n' {
			big.value = current.value[:len(current.value)-1]
		} else {
			big.value = current.value
		}
		big.loc.end = prev_end_offset(p)
		key = big_e
		eat(p)
	} else if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
		key_type_snap := p.cur_type
		key_value_snap := cur_value(p)
		key = expression_from(p, new_identifier_from_cur(p))
		eat(p)

		// Check if it's actually a constructor. Only promote to .Constructor
		// when no get/set modifier was seen - `get constructor() {}` is a
		// non-instance accessor named "constructor" and stays in its own
		// .Get / .Set kind so the post-parse §15.7.6 check below can flag
		// it as a SyntaxError.
		if (key_type_snap == .Constructor || (key_type_snap == .Identifier && key_value_snap == "constructor")) &&
		   kind == .Method && !is_async && !is_generator && !static_ {
			kind = .Constructor
		}
		// §15.7.6 ClassElement - a non-static method named "constructor"
		// must be a plain Method (not get / set / async / generator). Catch
		// the disallowed shapes here, where we still see the original
		// modifiers + the literal name.
		if !static_ && !is_private && !computed &&
		   (key_type_snap == .Constructor || (key_type_snap == .Identifier && key_value_snap == "constructor")) {
			if is_async {
				report_error_coded(p, .K3034_ConstructorShape, "Constructor can't be an async method")
			}
			if is_generator {
				report_error_coded(p, .K3012_AsyncGeneratorMisplaced,
					"Class constructor cannot be a generator method")
			}
			if kind == .Get {
				report_error_coded(p, .K3034_ConstructorShape, "Class constructor cannot be a getter")
			}
			if kind == .Set {
				report_error_coded(p, .K3034_ConstructorShape, "Class constructor cannot be a setter")
			}
		}
	} else if is_token(p, .LBracket) {
		// TS index signature in class body: `[s: string]: number`. Detect by
		// peeking `[ Identifier : ...`. The interface-body parser
		// (parse_ts_object_member) handles this; class bodies need the same
		// detection. Without it, `[s: string]` is misparsed as a computed
		// property key, choking on `:` while looking for `]`.
		// cluster. Skipped at the AST level for
		// now - the parser accepts the syntax, the corpus smoke gate passes,
		// and a proper TSIndexSignature class-element node can come in W7+
		// when the deep walker starts comparing class bodies.
		// Return nil so the class-body loop swallows the element without
		// erroring - mirrors the existing pattern for elements that the parser
		// intentionally drops (TS overload signatures don't materialize either).
		if try_consume_ts_class_index_signature(p, accessibility, access_name) {
			return nil
		}
		// Computed property: [expr]
		computed = true
		eat(p)
		// `[` opens a fresh expression context - the enclosing for-head
		// no_in restriction does not apply inside computed property keys.
		prev_no_in_cls := p.ctx.no_in
		p.ctx.no_in = false
		key = parse_assignment_expression(p)
		p.ctx.no_in = prev_no_in_cls
		// Array literal `[[]]` / `[[1,2]]` as computed class member key is
		// rejected by OXC. (Object literal `[{}]` is accepted.)
		if key != nil {
			if _, is_arr := key^.(^ArrayExpression); is_arr {
				report_error_coded(p, .K3030_ClassDeclarationStructure, "Array literal cannot be a computed class member name")
			}
		}
		if !expect_token(p, .RBracket) {
			return nil
		}
	} else {
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected method or property name")
		return nil
	}

	// (The generator `*` is parsed BEFORE the name above, around line
	// 4354. There's no `name *` form in JS / TS - a stray `*` here
	// belongs to the next class element, e.g. ASI-split
	// `async\n *foo() {}` where `async` is a bare field and `*foo` is a
	// generator method. Removing the post-name `*` consumption closes
	// the babel "async\n *a(){}" no-asi fixture.)

	// TS class field modifiers: `foo?:` (optional) or `foo!:` (definite assignment).
	// These appear BEFORE the `:` type annotation and coexist with it.
	field_optional := false
	field_definite := false
	if is_token(p, .Question) {
		// Consume `?` when we're clearly on a class field (next is `:` /
		// `=` / `;` / `,` / `}`) OR on an optional class method (`?(...)`
		// or `?<T>(...)`). The TS optional class member surface form
		// `class C { method?() {} }` previously left the `?` on the
		// cursor and tripped "Expected (, got ?" - closes the
		// 14-file cluster of that exact error. Mirrors the `?:` field
		// shape next to it.
  ensure_nxt(p)
		nxt := p.lexer.nxt.kind
		if nxt == .Colon || nxt == .Assign || nxt == .Semi ||
		   nxt == .Comma || nxt == .RBrace ||
		   nxt == .LParen || nxt == .LAngle {
			field_optional = true
			eat(p)
		}
	} else if is_token(p, .Not) {
		// `foo!:` / `foo!;` / `foo! = ...` - definite assignment assertion.
		// The `:` form pairs with a type annotation; the bare forms (`p!;`,
		// `p! = 1`, `p!,`) are TS shorthand for definite-without-annotation.
		// `.Not` = logical-not token.
  ensure_nxt(p)
		nxt := p.lexer.nxt.kind
		if nxt == .Colon || nxt == .Semi || nxt == .Assign ||
		   nxt == .Comma || nxt == .RBrace {
			field_definite = true
			eat(p)
		}
	}

	// TS class field type annotation: `foo: T`. Parsed before the field/method split.
	// Getters/setters must have `()` before any return type annotation —
	// `get x: T` is invalid (should be `get x(): T`).
	field_type_ann: Maybe(^TSTypeAnnotation)
	if is_token(p, .Colon) && allow_ts_mode(p) {
		if kind == .Get || kind == .Set {
			report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected `(` but found `:`")
		}
		field_type_ann = parse_ts_type_annotation(p)
	}

	// Check if this is a field (has = but no () ) or method. `.Colon` was
	// consumed above as part of the type annotation, so after that point the
	// next token is either `;`/`,`/`}` (bare field) or `=` (initializer).
	// ASI: a bare field with no explicit `;` / `=` ends at a line
	// terminator before the next class element. `class C { #x\n#y }`
	// must parse as two fields, not `#x` method missing `(`.
	is_field_by_asi := cur_has_newline(p) &&
	                    p.cur_type != .LParen &&
	                    p.cur_type != .Colon &&
	                    p.cur_type != .Question &&
	                    p.cur_type != .Not &&
	                    // In TS mode, `<` on the next line can start type
	                    // parameters for a method: `method\n<T>() {}`.
	                    !(allow_ts_mode(p) && is_open_angle_or_lshift(p))
	if !is_generator && (field_type_ann != nil || is_token(p, .Assign) || is_token(p, .Semi) || is_token(p, .Comma) || is_token(p, .RBrace) || is_field_by_asi) {
		// Class field with initializer or just declaration
		value: Maybe(^Expression)

		if match_token(p, .Assign) {
			// Class field initializer runs in a synthetic method with the
			// class as [[HomeObject]] - `super.x` is legal in this
			// position (ECMA-262 §15.7.5). But it is not a constructor, so
			// `super(...)` is not legal; reset `in_derived_constructor`.
			prev_in_method := p.ctx.in_method
			p.ctx.in_method = true
			prev_in_derived_ctor := p.ctx.in_derived_constructor
			p.ctx.in_derived_constructor = false
			// §15.7.10 ClassFieldDefinitionEvaluation: ClassFieldInitializer
			// is the body of a SYNTHETIC non-async, non-generator function.
			// `await` and `yield` MUST NOT be parsed as AwaitExpression /
			// YieldExpression here, even when the enclosing function is
			// async / generator. They become plain IdentifierReferences,
			// which are then accepted-or-rejected by the standard
			// reserved-word rules (`await` reserved in modules / static
			// blocks; `yield` reserved in strict). Test262 staging/sm/
			// fields/await-identifier-{script,module-3}.js.
			prev_in_async := p.ctx.in_async
			prev_in_generator := p.ctx.in_generator
			prev_in_async_params := p.ctx.in_async_params
			prev_in_generator_params := p.ctx.in_generator_params
			prev_in_field_init := p.ctx.in_field_init
			// §15.7.10 ClassFieldDefinitionEvaluation creates a new
			// function for the field initialiser. That function has
			// its own [~Await] scope — it does NOT inherit the
			// [~Await] from an enclosing static block. So `await`
			// as an identifier inside a nested class's field init
			// is valid: `class C { static { class D { x = await } } }`
			prev_in_static_block_fi := p.ctx.in_static_block
			p.ctx.in_async = false
			p.ctx.in_generator = false
			p.ctx.in_async_params = false
			p.ctx.in_generator_params = false
			p.ctx.in_field_init = true
			p.ctx.in_static_block = false
			init_expr := parse_assignment_expression(p)
			p.ctx.in_async = prev_in_async
			p.ctx.in_generator = prev_in_generator
			p.ctx.in_async_params = prev_in_async_params
			p.ctx.in_generator_params = prev_in_generator_params
			p.ctx.in_field_init = prev_in_field_init
			p.ctx.in_static_block = prev_in_static_block_fi
			p.ctx.in_method = prev_in_method
			p.ctx.in_derived_constructor = prev_in_derived_ctor
			if init_expr != nil {
				value = init_expr
				// TS: `declare` fields must not have initializers,
				// UNLESS both `declare` and `readonly` are present
				// (OXC allows `declare readonly x = 1;`).
				if (is_declare || p.ctx.in_ambient || p.source_is_dts) && !is_readonly {
					report_error_coded(p, .K4050_AmbientContextRestriction, "Initializers are not allowed in ambient contexts")
				}
				if is_abstract {
					report_error_coded(p, .K4060_AbstractMethodForm, "Abstract property cannot have an initializer")
				}
				// §15.7.10 "arguments in field initializer": enforced by
				// the semantic checker (ck_check_identifier_arguments),
				// which walks every ^Identifier reachable from the field
				// initializer expression with in_field_init = true.
			}
		}

		// §15.7.1 ClassElement - a non-computed FieldDefinition (with or
		// without an initializer) cannot be named "constructor". The
		// non-computed restriction matches the spec: `class { ['constructor'
		// ] = 1 }` is allowed because the key is computed.
		// OXC's parser skips this check for StringLiteral-keyed fields
		// with an access modifier — `public "constructor" = 0;` is
		// accepted, deferred to the type checker.  Identifier-keyed
		// `public constructor;` is still caught.
		if !computed {
			is_string_key := false
			if key != nil {
				if _, ok := key^.(^StringLiteral); ok { is_string_key = true }
			}
			skip := is_string_key && accessibility != .None
			if !skip {
				name := class_element_prop_name(key)
				if name == "constructor" {
					report_error_coded(p, .K3034_ConstructorShape, "Class field cannot be named 'constructor'")
				}
			}
		}

		// §15.7.1 ClassElement - FieldDefinition must be followed by `;` or
		// a line terminator. `field = 1 /* comment */ method(){}` (no newline
		// between initializer and next element) is a SyntaxError.
		// Use a stricter check than can_insert_semicolon: in a class body,
		// a newline before any token (including `[`) terminates the field.
		if is_token(p, .Semi) {
			eat(p)
		} else if !is_token(p, .RBrace) && !is_token(p, .EOF) && !cur_has_newline(p) {
			report_error_coded(p, .K2010_ExpectedSemicolon, "Expected semicolon or line terminator after class field")
		}

		elem := new_node(p, ClassElement)
		elem.loc = start
		elem.key = key
		elem.value = value
		elem.kind = kind  // Still .Method but value is not a function
		// Use the parsed `computed` flag so `static [propname]` fields
		// emit with computed=true - the §15.7.1 "static prototype" check
		// gates on !elem.computed, so the previous hardcoded `false` made
		// `class { static ['prototype'] = 42 }` falsely error.
		elem.computed = computed
		elem.static = static_
		elem.is_accessor = is_accessor
		elem.abstract = is_abstract
		elem.decorators = decorators
		elem.type_annotation = field_type_ann
		elem.optional = field_optional
		if is_accessor && field_optional {
			report_error_coded(p, .K4032_ModifierMisplaced, "An 'accessor' property cannot be declared optional")
		}
		elem.definite = field_definite
		elem.accessibility = accessibility
		elem.readonly = is_readonly
		elem.override_ = is_override

		elem.loc.end = prev_end_offset(p)
		return elem
	}

	// It's a method - parse parameters and body. TS allows generic methods
	// `foo<T>(x: T): T { ... }` - parse the optional <T,U,...> here, before
	// the `(`. Without this, `Expected (, got <` fires on every generic
	// class method. Same dance as
	// parse_function_declaration does at line 3810. Stored on the
	// FunctionExpression's type_parameters slot below.
	method_type_parameters: Maybe(^TSTypeParameterDeclaration)
	if is_token(p, .LAngle) && allow_ts_mode(p) {
		method_type_parameters = parse_ts_type_parameters(p)
	} else if is_token(p, .LAngle) && !allow_ts_mode(p) {
		// In JS mode, `<T>` after a method name is a comparison, not
		// type parameters. Report error and skip the angle-bracketed
		// content for recovery.
		report_error_coded(p, .K4053_TSOnlyInJS, "Type parameters are only allowed in TypeScript files")
		eat(p) // consume `<`
		depth := 1
		for depth > 0 && !is_token(p, .EOF) {
			if is_token(p, .LAngle) { depth += 1 }
			else if is_token(p, .RAngle) { depth -= 1 }
			if depth > 0 { eat(p) }
		}
		if is_token(p, .RAngle) { eat(p) }
	}

	if is_readonly {
		report_error_coded(p, .K4032_ModifierMisplaced, "'readonly' modifier can only appear on a property declaration")
	}
	if kind == .Constructor && is_override {
		report_error_coded(p, .K4020_ConstructorTSModifier, "'override' modifier cannot appear on a constructor declaration")
	}

	// Capture paren position for FunctionExpression start
	paren_loc := cur_loc(p)
	if !expect_token(p, .LParen) {
		return nil
	}

	// §15.5.1 / §15.6.1 - yield-in-params guard for generator methods.
	// §15.8.1 / §15.6.1 - await-in-params guard for async methods (same
	// rule for async generators). Same save/restore as
	// parse_function_declaration.
	prev_method_gen_params := p.ctx.in_generator_params
	prev_method_async_params := p.ctx.in_async_params
	p.ctx.in_generator_params = is_generator
	p.ctx.in_async_params = is_async
	// Static-block context does not extend into class method parameters.
	prev_static_block_mparams := p.ctx.in_static_block
	p.ctx.in_static_block = false
	// Class body is implicitly strict (§15.7.3); method parameter
	// parsing inherits strict mode so "yield" / "let" / etc. as param
	// defaults surface as strict-mode IdentifierReference errors
	// (§12.6.1.1).
	prev_strict_params := p.ctx.strict_mode
	p.ctx.strict_mode = true
	// `super.x` in a class method's default-param initializer is legal
	// (param scope inherits the method's [[HomeObject]]). Same
	// in_method = true save / restore as the body parsing below.
	prev_method_in_method := p.ctx.in_method
	p.ctx.in_method = true
	// `super(...)` in a derived constructor's default-param initializer
	// is accepted by OXC (the param scope inherits the constructor's
	// SuperCall eligibility). Set `in_derived_constructor` before params
	// so super-call checking in parse_assignment_expr picks it up.
	prev_ctor_params_derived := p.ctx.in_derived_constructor
	if kind == .Constructor && !static_ && p.ctx.class_has_extends {
		p.ctx.in_derived_constructor = true
	}
	params := parse_function_params(p)
	p.ctx.in_derived_constructor = prev_ctor_params_derived
	if allow_ts_mode(p) {
		for param in params {
			has_modifier := param.accessibility != .None || param.readonly || param.override_
			if has_modifier {
				if kind != .Constructor {
					report_error_coded(p, .K4022_ParameterPropertyOnlyInCtor, "Parameter property modifiers are only allowed in constructors")
				} else {
					if _, is_ident := param.pattern.(^Identifier); !is_ident {
						report_error_coded(p, .K3043_DestructuringInvalid, "A parameter property may not be declared using a binding pattern")
					}
				}
			}
		}
	}
	p.ctx.in_method = prev_method_in_method
	p.ctx.strict_mode = prev_strict_params
	p.ctx.in_generator_params = prev_method_gen_params
	p.ctx.in_async_params = prev_method_async_params
	p.ctx.in_static_block = prev_static_block_mparams
	// §15.5.1 / §15.6.1 — class methods are always strict.
	parser_check_dup_params(p, params[:], start.start, true, false)

	if !expect_token(p, .RParen) {
		return nil
	}

	// §15.4.3 / §15.4.4 / §15.4.5 — getter / setter arity + setter
	// parameter shape (rest / default initializer).
	if kind == .Get || kind == .Set {
		key_loc: LexerLoc
		if key != nil {
			key_loc = LexerLoc(get_expression_loc(key).start)
		} else {
			key_loc = LexerLoc(start.start)
		}
		enforce_accessor_param_shape(p, kind == .Set, params[:], key_loc)
	}

	// TypeScript return type annotation on method - stored on FunctionExpression.
	method_return_type: Maybe(^TSTypeAnnotation)
	if is_token(p, .Colon) && allow_ts_mode(p) {
		method_return_type = parse_ts_return_type_annotation(p)
	}
	if kind == .Constructor {
		if method_type_parameters != nil {
			report_error_coded(p, .K4020_ConstructorTSModifier, "Type parameters cannot appear on a constructor declaration")
		}
		if _, has_return_type := method_return_type.?; has_return_type {
			report_error_coded(p, .K4020_ConstructorTSModifier, "Type annotation cannot appear on a constructor declaration")
		}
		if is_declare {
			report_error_coded(p, .K4020_ConstructorTSModifier, "'declare' modifier cannot appear on a constructor declaration")
		}
	}
	// TS: getters cannot have type parameters. Setters cannot have type
	// parameters or a return type annotation.
	if allow_ts_mode(p) {
		if kind == .Get && method_type_parameters != nil {
			report_error_coded(p, .K4052_AccessorOrTypeParamForm, "A 'get' accessor cannot have type parameters")
		}
		if kind == .Set {
			if method_type_parameters != nil {
				report_error_coded(p, .K4052_AccessorOrTypeParamForm, "A 'set' accessor cannot have type parameters")
			}
			if _, has_return_type := method_return_type.?; has_return_type {
				report_error_coded(p, .K4052_AccessorOrTypeParamForm, "A 'set' accessor cannot have a return type annotation")
			}
		}
	}
	if is_declare && (kind == .Get || kind == .Set || kind == .Method) {
		report_error_coded(p, .K4032_ModifierMisplaced, "'declare' modifier cannot be used here")
	}

	// For abstract methods and for TS overload signatures there's no body
	// - just a semicolon. Overload signature (TS-A10):
	//   class C {
	//     get(x: string): string;
	//     get(x: number): number;
	//     get(x: any): any { return x; }
	//   }
	// The parser tolerates the syntax; semantics (overload set shape,
	// implementation agreement) are the type checker's job.
	body: FunctionBody
	// TS-mode ambient method: no `{` body. Three ways to identify it:
	//   1. explicit `;` terminator        (overload signature, declare class)
	//   2. ASI: line-terminator before next class element start (.d.ts files)
	//   3. immediately followed by `}` - last method in declare class.
	// Each branch leaves `body` empty. Test ts-conformance:
	//   bench/node_modules/oxc-parser/src-js/index.d.ts
	//     class ParseResult { get program(): T  /* no semi */
	//                         get module(): U
	//                       }
	is_overload_sig := allow_ts_mode(p) && is_token(p, .Semi)
	is_ambient_method := allow_ts_mode(p) && !is_token(p, .LBrace) &&
	                     (cur_has_newline(p) || is_token(p, .RBrace))
	if (is_abstract || is_overload_sig) && is_token(p, .Semi) {
		// Decorators cannot appear on overload signatures or abstract methods.
		// §15.2.1 early error: it is a Syntax Error if ClassElementKind of
		// ClassElement is not Property and the ClassElement has a decorator.
		if len(decorators) > 0 && (is_overload_sig || is_abstract) {
			report_error_coded(p, .K4064_DecoratorInvalid, "A decorator can only decorate a method implementation, not an overload")
		}
		match_semicolon_or_asi(p)
		// Leave body empty
	} else if is_ambient_method {
		// ASI / before-RBrace ambient method - don't consume any token,
		// the outer parse_class_element loop picks up where we left off.
		if len(decorators) > 0 {
			report_error_coded(p, .K4064_DecoratorInvalid, "A decorator can only decorate a method implementation, not an overload")
		}
		// Body stays empty.
	} else {
		if p.ctx.in_ambient {
			report_error_coded(p, .K4050_AmbientContextRestriction, "An implementation cannot be declared in ambient contexts")
		}
		// OXC reports abstract-with-body for non-constructor methods;
		// abstract constructors are accepted by OXC at parser level.
		if is_abstract && kind != .Constructor {
			name := class_element_prop_name(key)
			if name != "" {
				report_error_coded(p, .K4060_AbstractMethodForm, fmt.tprintf("Method '%s' cannot have an implementation because it is marked abstract", name))
			} else {
				report_error_coded(p, .K4060_AbstractMethodForm, "Method cannot have an implementation because it is marked abstract")
			}
		}
		// Parse body - set context flags
		prev_in_function := p.ctx.in_function
		prev_in_generator := p.ctx.in_generator
		prev_in_async := p.ctx.in_async
		prev_in_method := p.ctx.in_method
		prev_strict := p.ctx.strict_mode
		prev_in_derived_ctor := p.ctx.in_derived_constructor

		p.ctx.in_function = true
		p.ctx.in_generator = is_generator
		p.ctx.in_async = is_async
		// Class methods (including constructor / getter / setter) are
		// [[HomeObject]]-bearing contexts - `super.x` / `super[x]` is
		// lexically legal inside. Class bodies are ALSO implicitly strict
		// (ECMA-262 §15.7.3), so every method body parses under
		// strict-mode rules even without a `"use strict"` directive.
		p.ctx.in_method = true
		p.ctx.strict_mode = true
		// `super(...)` (SuperCall) is only legal in the instance constructor
		// of a class with `extends` (ECMA-262 §15.7.3). `static` methods
		// named `constructor` are ordinary static methods and don't qualify.
		p.ctx.in_derived_constructor = kind == .Constructor && !static_ && p.ctx.class_has_extends

		body = parse_function_body(p)

		p.ctx.in_function = prev_in_function
		p.ctx.in_generator = prev_in_generator
		p.ctx.in_async = prev_in_async
		p.ctx.in_method = prev_in_method
		p.ctx.strict_mode = prev_strict
		p.ctx.in_derived_constructor = prev_in_derived_ctor

		// Class methods always have UniqueFormalParameters — the
		// MethodDefinition production (§15.4) names the constraint, so
		// duplicates fire regardless of outer strict mode.

		// §15.5.1 / §15.6.1 / §15.8.1 — ContainsUseStrict +
		// !IsSimpleParameterList. A class method that has both a
		// `"use strict"` directive in its body AND a non-simple parameter
		// list is a SyntaxError. p.last_body_strict survives the
		// strict_mode restore above because parse_function_body sets it
		// just before returning.
		if p.last_body_strict && !params_are_simple(params[:]) {
			report_error_coded_span(p, .K3052_UseStrictWithComplexParams, u32(paren_loc.start), u32(paren_loc.start), "Illegal 'use strict' directive in function with non-simple parameter list")
		}

		// §15.4.3 / §15.4.4 / §15.4.5 — getter / setter arity + setter
		// parameter shape (rest / TS-mode initializer) are enforced inline
		// at parse time by enforce_accessor_param_shape (called above, right
		// after RParen). Slice 15 promoted this back to the parser because
		// these are STRUCTURAL grammar rules — OXC's parser-only pipeline
		// rejects them too, and gating behind --show-semantic-errors hid
		// the parity in the corpus comparison.

		// TS: abstract method must not have an implementation body.
		if is_abstract && len(body.body) > 0 {
			name := class_element_prop_name(key)
			if name != "" {
				report_error_coded(p, .K4060_AbstractMethodForm, fmt.tprintf("Method '%s' cannot have an implementation because it is marked abstract", name))
			} else {
				report_error_coded(p, .K4060_AbstractMethodForm, "Method cannot have an implementation because it is marked abstract")
			}
		}
	}

	// §15.2.1.1 - BoundNames of FormalParameters vs LexicallyDeclaredNames.

	// Create the method as a FunctionExpression
	fn_expr, fn_expr_e := new_expr(p, FunctionExpression)
	fn_expr.loc = paren_loc
	fn_expr.id = nil // Methods don't have names in their function expression
	fn_expr.params = params
	fn_expr.body = body
	fn_expr.generator = is_generator
	fn_expr.async = is_async
	fn_expr.type_parameters = method_type_parameters
	fn_expr.return_type = method_return_type
	// Mark overload signatures / abstract methods as no_body so the
	// checker can distinguish them from implementation methods.
	fn_expr.no_body = (is_overload_sig || is_ambient_method || is_abstract)

	// TS2371 / parameter property checks for overload / ambient methods.
	if fn_expr.no_body && allow_ts_mode(p) {
		for pr in params {
			if _, has := pr.default_val.(^Expression); has {
				report_error_coded_span(p, .K4022_ParameterPropertyOnlyInCtor, u32(pr.loc.start), u32(pr.loc.start), "A parameter initializer is only allowed in a function or constructor implementation")
			}
			if pr.accessibility != .None {
				report_error_coded_span(p, .K4022_ParameterPropertyOnlyInCtor, u32(pr.loc.start), u32(pr.loc.start), "Parameter properties are only allowed in the implementation constructor")
			}
			if pr.readonly {
				report_error_coded_span(p, .K4022_ParameterPropertyOnlyInCtor, u32(pr.loc.start), u32(pr.loc.start), "'readonly' parameter properties are only allowed in the implementation constructor")
			}
		}
	}
	fn_expr.loc.end = prev_end_offset(p)

	elem := new_node(p, ClassElement)
	elem.loc = start
	elem.key = key
	elem.value = fn_expr_e
	elem.kind = kind
	elem.computed = computed
	elem.static = static_
	elem.is_accessor = is_accessor
	elem.abstract = is_abstract
	elem.decorators = decorators
	elem.accessibility = accessibility
	elem.readonly = is_readonly
	elem.override_ = is_override
	// TS optional method: `m?(): void`. The `?` was consumed by the
	// shared field/method `?`/`!` parser higher in this proc, but only
	// the field-element branch propagated `field_optional` into
	// `elem.optional`. Mirror it for methods so downstream checks
	// (e.g. ck_check_ts_class_overloads) can distinguish optional
	// methods from overload signatures.
	elem.optional = field_optional

	elem.loc.end = prev_end_offset(p)
	return elem
}

// Parse ES2022 static block: static { ... }
parse_static_block :: proc(p: ^Parser, start: Loc) -> ^ClassElement {
	match_token(p, .Static) // consume static

	// Class static blocks run with the class as [[HomeObject]] - `super.x`
	// (class-static super) is legal inside. Save/restore so nested regular
	// functions inside still reset `in_method`.
	prev_in_method := p.ctx.in_method
	p.ctx.in_method = true
	defer p.ctx.in_method = prev_in_method
	// Static blocks are not constructors - `super(...)` is not legal here
	// even if the surrounding class has `extends`.
	prev_in_derived_ctor := p.ctx.in_derived_constructor
	p.ctx.in_derived_constructor = false
	defer p.ctx.in_derived_constructor = prev_in_derived_ctor
	// §15.7.5 - a static block is its own ClassStaticBlockBody function;
	// `new.target` and `return` are legal inside (§13.3.12 / §14.10).
	// Promote in_function so the new.target gate doesn't false-positive.
	// However, the static block is NOT a generator and NOT async - `yield`
	// and `await` from the enclosing function/generator do NOT propagate
	// (§15.7.5: ClassStaticBlockBody : ClassStaticBlockStatementList runs
	// under [~Yield, ~Await]). Reset both flags so a `function *g() {
	// class C { static { yield; } } }` correctly rejects the inner yield.
	prev_in_function_sb := p.ctx.in_function
	p.ctx.in_function = true
	defer p.ctx.in_function = prev_in_function_sb
	// Static block is a non-arrow function for new.target purposes.
	prev_in_non_arrow_sb := p.ctx.in_non_arrow_function
	p.ctx.in_non_arrow_function = true
	defer p.ctx.in_non_arrow_function = prev_in_non_arrow_sb
	prev_in_generator_sb := p.ctx.in_generator
	p.ctx.in_generator = false
	defer p.ctx.in_generator = prev_in_generator_sb
	prev_in_async_sb := p.ctx.in_async
	p.ctx.in_async = false
	defer p.ctx.in_async = prev_in_async_sb
	prev_in_static_block_sb := p.ctx.in_static_block
	p.ctx.in_static_block = true
	defer p.ctx.in_static_block = prev_in_static_block_sb
	// §15.7.5 - `break`/`continue` from the enclosing loop/switch do not
	// propagate into a static block. Reset the flags.
	prev_in_loop_sb := p.ctx.in_loop
	p.ctx.in_loop = false
	defer p.ctx.in_loop = prev_in_loop_sb
	prev_in_switch_sb := p.ctx.in_switch
	p.ctx.in_switch = false
	defer p.ctx.in_switch = prev_in_switch_sb
	// Labels don't cross static block boundaries (§15.7.5).
	prev_label_floor_sb := p.ctx.label_floor
	p.ctx.label_floor = len(p.label_stack)
	defer {
		resize(&p.label_stack, p.ctx.label_floor)
		p.ctx.label_floor = prev_label_floor_sb
	}
	// Class bodies (and therefore static blocks) are implicitly strict.
	prev_strict_sb := p.ctx.strict_mode
	p.ctx.strict_mode = true
	defer p.ctx.strict_mode = prev_strict_sb

	// Parse block statement. parse_block_statement returns a ^Statement
	// union wrapping a ^BlockStatement; extract the ^BlockStatement variant
	// via type assertion. The previous transmute read the union header as
	// if it were a BlockStatement struct - same UB class as Bug H, silently
	// zeroing `body` so static blocks emitted empty.
	// §15.7.5: ClassStaticBlockBody is a function-scope, not a block-scope.
	// var+function coexistence is legal here (V8/Babel agree).
	p.scope_fn_scope_next_block = true
	block_stmt := parse_block_statement(p)
	if block_stmt == nil {
		return nil
	}
	block, ok := block_stmt^.(^BlockStatement)
	if !ok {
		return nil
	}
	// §15.7.5: ClassStaticBlockBody is its own function-scope, not a block-scope.

	// Create a StaticBlock value (stored as a FunctionExpression with no params)
	static_block, static_block_e := new_expr(p, FunctionExpression)
	static_block.loc = start
	static_block.id = nil
	static_block.params = make([dynamic]FunctionParameter, 0, 0, p.allocator)
	static_block.body = FunctionBody{
		loc = block.loc,
		body = block.body,
	}
	static_block.generator = false
	static_block.async = false
	static_block.loc.end = prev_end_offset(p)

	elem := new_node(p, ClassElement)
	elem.loc = start
	elem.key = nil  // Static blocks don't have a key
	elem.value = static_block_e
	elem.kind = .StaticBlock
	elem.computed = false
	elem.static = false  // Not marked as static - the kind implies it

	elem.loc.end = prev_end_offset(p)
	return elem
}

// parse_var_decl_kind resolves the VariableKind for a variable / lexical
// declaration from the current token. `var` / `let` / `const` / `using` map
// directly; `await using` is recognised via two-token lookahead (and consumes
// the `await` here, leaving the parent to consume the `using`). Any other
// leading token falls back to kind_override (set when the head keyword was
// already consumed by the caller, e.g. a TS `declare` prefix). Returns ok =
// false after reporting K2023 when no kind can be determined.
parse_var_decl_kind :: proc(p: ^Parser, kind_override: Maybe(VariableKind)) -> (kind: VariableKind, ok: bool) {
	#partial switch p.cur_type {
	case .Var:
		kind = .Var
	case .Let:
		kind = .Let
	case .Const:
		kind = .Const
	case .Using:
		kind = .Using
	case .Await:
		if is_next_token(p, .Using) {
			kind = .AwaitUsing
			eat(p) // consume await
		} else {
			if k, have := kind_override.(VariableKind); have {
				kind = k
			} else {
				report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected var, let, const, using, or await using")
				return {}, false
			}
		}
	case:
		if k, have := kind_override.(VariableKind); have {
			kind = k
		} else {
			report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected var, let, or const")
			return {}, false
		}
	}
	return kind, true
}

parse_variable_declaration :: proc(p: ^Parser, kind_override: Maybe(VariableKind), consume_semi: bool, in_for := false, is_declare := false) -> ^Statement {
	start := cur_loc(p)

	kind, kind_ok := parse_var_decl_kind(p, kind_override)
	if !kind_ok {
		return nil
	}

	eat(p)

	// TS18054 — `await using` inside a class static block is invalid.
	// Static blocks run synchronously and `await` is not available.
	if kind == .AwaitUsing && p.ctx.in_static_block {
		report_error_coded(p, .K3014_AwaitUsingContextRestricted,
			"'await using' statements cannot be used inside a class static block")
	}

	// §14.3 — `using` / `await using` are not allowed at the top
	// level of a Script (only inside blocks / functions / modules).
	// Exceptions: `for (using x = ...)` is a for-loop init, not a
	// top-level statement, so skip when in_for.
	if !p.ctx.in_function && p.block_depth == 0 && !in_for && !p.is_commonjs && (kind == .Using || kind == .AwaitUsing) {
		if st, have := p.force_source_type.(SourceType); have && st == .Script {
			if kind == .AwaitUsing {
				report_error_coded(p, .K3014_AwaitUsingContextRestricted,
					"'await using' declaration is not allowed at the top level of a script")
			} else {
				report_error_coded(p, .K3067_NewTargetOrTopLevelUsing, "'using' declaration is not allowed at the top level of a script")
			}
		} else if !p.has_module_syntax {
			// Auto-detect: if no module syntax is present, treat as Script.
			if !p.in_module_top_level {
				// Not yet known to be a module — check lazily.
			}
		}
	}

	decl := new_node(p, VariableDeclaration)
	decl.loc = start
	decl.kind = kind

	// Error recovery: `var;` / `let;` / `const;` — bare keyword without
	// a binding name. Report one error and produce an empty declaration
	// instead of cascading. Matches OXC's single-error recovery.
	// Inside TS namespace blocks, OXC's parser silently accepts empty
	// declaration lists (TS1123 is semantic) — skip the parser error
	// to match OXC's classification for NonInitializedExportInInternalModule.
	if is_token(p, .Semi) || (is_token(p, .EOF) && !in_for) {
		if !(allow_ts_mode(p) && p.ctx.in_ts_namespace) {
			if kind == .Let {
				report_error_coded(p, .K2070_RequiredFormOrBinding, "'let' declaration requires a binding name")
			} else {
				report_error_coded(p, .K3043_DestructuringInvalid, "Expected binding pattern")
			}
		}
		decl.declarations = make([dynamic]VariableDeclarator, 0, 2, p.allocator)
		if consume_semi { match_semicolon_or_asi(p) }
		decl.loc.end = prev_end_offset(p)
		stmt := new_node(p, Statement); stmt^ = decl; return stmt
	}

	// Cap bumped from 2 → 4 (S23).
	decl.declarations = make([dynamic]VariableDeclarator, 0, 4, p.allocator)

	for {
		d := parse_variable_declarator(p, kind, in_for, is_declare)
		if d != nil {
			bump_append(&decl.declarations, d^)
		}

		if !match_token(p, .Comma) {
			break
		}
	}

	if consume_semi {
		// §14.3 - a VariableStatement / LexicalDeclaration ends with a
		// `;` (or ASI). `var x = ''''` (Test262 string/S8.4_A13_T3.js) and
		// `var\nlet x = 1` previously slid through with the lenient
		// match_*, leaving the parser to emit two valid statements when
		// the spec mandates a SyntaxError between them.
		// ASI for `let x\n/regex/`: after a complete VariableDeclarator with
		// no initializer, the next-line `/` cannot continue the declaration
		// as division (the binding has no value to divide). Per ASI rule 1
		// ("offending token is not allowed by any production"), insert a
		// semicolon. Relex the `/` as a regex so the next statement parses.
		// Test: babel/core/regression/2591/input.js (`let x\n/wow/;`).
		if p.cur_type == .Div && cur_has_newline(p) {
			relex_as_regex(p.lexer)
			ft := p.lexer.cur
			p.cur_type = ft.kind
		}
		expect_semicolon_or_asi(p)
	}

	// ECMA-262 §14.3.1.1 - a LexicalDeclaration's BoundNames list must not
	// contain duplicates. `let x = 1, x = 2;` / `const a, b, a;` / using /
	// await-using are all SyntaxErrors; `var` is explicitly exempted
	// (B.3.3 "VarDeclaredNames of a Script may contain repeats").
	// §14.3.1.1 also forbids BoundNames containing `"let"` for a
	// LexicalDeclaration - `let let;` / `const let;` are SyntaxErrors
	// in both strict and sloppy. The binding check lives here, not in
	// parse_binding_pattern, so `var let;` keeps working (B.3.4.4).
	if !is_declare && (kind == .Let || kind == .Const || kind == .Using || kind == .AwaitUsing) {
		// §14.3.1.1 — BoundNames of a LexicalDeclaration must not
		// contain `"let"` AND must not contain duplicates. `var` is
		// exempt (Annex B.3.3.1 "VarDeclaredNames of a Script may
		// One pass over collected BoundNames covers both rules: the
		// `let`-as-name check fires first because it has a more
		// specific diagnostic, and we early-return after either fires
		// to keep one diagnostic per declaration (matches the checker).
		names: [dynamic]string
		names.allocator = context.temp_allocator
		reserve(&names, 4)
		for d in decl.declarations { collect_bound_names(d.id, &names) }
		let_seen := false
		dup_name := ""
		dedup: map[string]bool
		dedup.allocator = context.temp_allocator
		reserve(&dedup, 4)
		for n in names {
			if n == "let" && !let_seen {
				let_seen = true
			}
			if _, have := dedup[n]; have {
				if dup_name == "" { dup_name = n }
			} else {
				dedup[n] = true
			}
		}
		if let_seen {
			report_error_coded_span(p, .K3050_StrictModeReserved, u32(decl.loc.start), u32(decl.loc.start), "'let' is disallowed as a lexically bound name")
		} else if dup_name != "" {
			msg := fmt.tprintf("Identifier '%s' has already been declared", dup_name)
			report_error_coded_span(p, .K3037_DuplicateIdentifier, u32(decl.loc.start), u32(decl.loc.start), msg)
		}
	}

	// §Explicit Resource Management - `using` / `await using` create
	// runtime disposal state, so TS forbids them in ambient contexts
	// (`declare namespace`, `declare module`, and `.d.ts`).
	if kind == .Using || kind == .AwaitUsing {
		if is_declare || p.ctx.in_ambient || p.source_is_dts {
			kn := "using"
			if kind == .AwaitUsing { kn = "await using" }
			msg := fmt.tprintf("'%s' declarations are not allowed in ambient contexts.", kn)
			report_error_coded(p, .K4050_AmbientContextRestriction, msg)
		}
	}

	// §Explicit Resource Management - the bindings of a `using` /
	// `await using` declaration must each be a BindingIdentifier; array /
	// object destructuring patterns are not allowed (`using [] = null;`,
	// `await using {} = null;`).
	if !is_declare && (kind == .Using || kind == .AwaitUsing) {
		for d in decl.declarations {
			if _, is_ident := d.id.(^Identifier); !is_ident {
				kn := "using"
				if kind == .AwaitUsing { kn = "await using" }
				msg := fmt.tprintf("'%s' declaration requires a binding identifier", kn)
				report_error_coded(p, .K2070_RequiredFormOrBinding, msg)
			}
		}
		// §Explicit Resource Management placement: `using` / `await using`
		// are forbidden as a direct child of a CaseClause / DefaultClause
		// StatementList ("AwaitUsingDeclaration is contained directly
		// within the StatementList of either a CaseClause or DefaultClause").
		// They're allowed inside a sub-block within the case clause.
		if p.ctx.in_case_clause {
			kn := "using"
			if kind == .AwaitUsing { kn = "await using" }
			msg := fmt.tprintf("'%s' declaration is not allowed directly inside a switch case clause", kn)
			report_error_coded(p, .K3060_SingleStatementContext, msg)
		}
	}

	// §14.3.3 `const` and §Explicit Resource Management `using` /
	// `await using` require an Initializer on every VariableDeclarator.
	// `const x;`, `using x;`, `await using x;` are all SyntaxErrors.
	// `in_for` skips the check so `for (const x of y)` / `for (using x
	// of y)` (where the binding is initialised by the loop iteration)
	// keeps working. `is_declare` for ambient TS (`declare const x;`)
	// also skips per TS rules. `let` allows no initializer.
	// OXC's parser rejects missing initializers in normal TS/TSX files too.
	// Ambient forms (`declare const x;`, `.d.ts` sources) and for-of/in
	// declaration heads still skip because the value is supplied externally.
	if !is_declare && !p.ctx.in_ambient && !p.source_is_dts && !in_for && (kind == .Const || kind == .Using || kind == .AwaitUsing) {
		kind_name: string
		switch kind {
		case .Const:       kind_name = "const"
		case .Using:       kind_name = "using"
		case .AwaitUsing:  kind_name = "await using"
		case .Let, .Var:   kind_name = ""
		}
		if kind_name != "" {
			for d in decl.declarations {
				if _, have := d.init.(^Expression); !have {
					msg := fmt.tprintf("Missing initializer in '%s' declaration", kind_name)
					report_error_coded(p, .K2070_RequiredFormOrBinding, msg)
				}
			}
		}
	}

	// A destructuring declaration needs an initializer unless the binding is
	// supplied by a for-in/of head.
	if !is_declare && !p.ctx.in_ambient && !p.source_is_dts && !in_for {
		for d in decl.declarations {
			if _, have := d.init.(^Expression); have { continue }
			if _, is_ident := d.id.(^Identifier); !is_ident {
				report_error_coded(p, .K3043_DestructuringInvalid, "Missing initializer in destructuring declaration")
			}
		}
	}

	decl.loc.end = prev_end_offset(p)
	stmt := new_node(p, Statement)
	stmt^ = decl
	return stmt
}

// Walk a binding pattern and append each bound identifier name, in
// source order, into `names`. Used by the LexicalDeclaration duplicate
// check and (later) by the strict-mode FormalParameters duplicate check.
collect_bound_names :: proc(pat: Pattern, names: ^[dynamic]string) {
	if id, ok := pat.(^Identifier); ok {
		if id != nil { append(names, id.name) }
		return
	}
	if op, ok := pat.(^ObjectPattern); ok {
		if op == nil { return }
		for prop in op.properties {
			collect_bound_names(prop.value, names)
		}
		return
	}
	if ap, ok := pat.(^ArrayPattern); ok {
		if ap == nil { return }
		for elem in ap.elements {
			if sub, ok2 := elem.(Pattern); ok2 {
				collect_bound_names(sub, names)
			}
		}
		return
	}
	if asp, ok := pat.(^AssignmentPattern); ok {
		if asp != nil { collect_bound_names(asp.left, names) }
		return
	}
	if re, ok := pat.(^RestElement); ok {
		if re != nil { collect_bound_names(re.argument, names) }
		return
	}
	// ^MemberExpression: destructuring-assignment target, not a binding.
}

// A FormalParameter is "simple" iff it's a plain Identifier with no
// default value, no destructuring, and not a rest element. ECMA-262
// §15.1.2 Static Semantics IsSimpleParameterList returns true only
// when EVERY parameter is simple. The moment any param is non-simple,
// UniqueFormalParameters applies regardless of strict/sloppy mode -
// duplicates in `function f(a, {a}) {}` are a SyntaxError even in
// sloppy script.
params_are_simple :: proc(params: []FunctionParameter) -> bool {
	for p in params {
		if _, has_def := p.default_val.(^Expression); has_def { return false }
		if _, is_id := p.pattern.(^Identifier); !is_id { return false }
	}
	return true
}

// arrow_body_lifts_strict — does an arrow function block body open with
// a "use strict" directive? Arrow bodies use parse_block_statement, which
// (unlike parse_function_body / parse_program) does NOT promote leading
// string-literal statements to a directive prologue. So we sniff body[0]
// for an ExpressionStatement whose expression is a StringLiteral with
// value == "use strict". Mirrors the checker's
// ck_check_arrow_strict_directive_with_nonsimple_params shape — used by
// parse_arrow_function for the §15.3.1 ContainsUseStrict +
// !IsSimpleParameterList early error.
arrow_body_lifts_strict :: proc(body: ArrowFunctionBody) -> bool {
	block, is_block := body.(^BlockStatement)
	if !is_block || block == nil || len(block.body) == 0 { return false }
	es, eok := block.body[0]^.(^ExpressionStatement)
	if !eok || es == nil { return false }
	str, sok := es.expression.(^StringLiteral)
	if !sok || str == nil { return false }
	return str.value == "use strict"
}

// report_strict_eval_arguments_in_target — §13.15.1 — walk an
// assignment LHS expression and emit a diagnostic for every Identifier
// position naming `eval` or `arguments` while p.ctx.strict_mode is true.
// Recurses through ParenthesizedExpression / ArrayExpression /
// ObjectExpression / SpreadElement / nested AssignmentExpression
// default-init so destructuring forms are covered:
//   `[eval] = []`, `({x: arguments} = {})`, `[...eval] = []`,
//   `[a = (eval = 1)] = []`.
// Mirrors ck_check_strict_eval_arguments_in_target.
report_strict_eval_arguments_in_target :: proc(p: ^Parser, expr: ^Expression) {
	if expr == nil { return }
	#partial switch e in expr^ {
	case ^Identifier:
		if e == nil { return }
		if is_eval_or_arguments(e.name) {
			msg := fmt.tprintf("Assignment to '%s' is not allowed in strict mode", e.name)
			report_error_coded_span(p, .K3050_StrictModeReserved, u32(e.loc.start), u32(e.loc.start), msg)
		}
	case ^ParenthesizedExpression:
		if e != nil { report_strict_eval_arguments_in_target(p, e.expression) }
	case ^ArrayExpression:
		if e == nil { return }
		for elem in e.elements {
			if inner, ok := elem.(^Expression); ok && inner != nil {
				report_strict_eval_arguments_in_target(p, inner)
			}
		}
	case ^ObjectExpression:
		if e == nil { return }
		for prop in e.properties {
			report_strict_eval_arguments_in_target(p, prop.value)
		}
	case ^SpreadElement:
		if e != nil { report_strict_eval_arguments_in_target(p, e.argument) }
	case ^AssignmentExpression:
		if e == nil { return }
		if e.operator == .Assign {
			report_strict_eval_arguments_in_target(p, e.left)
		}
	}
}

// is_strict_reserved_binding_name — unified predicate for the names
// kessel rejects as a BindingIdentifier in strict mode. Combines:
//   * §13.1.1 — "eval" / "arguments"
//   * §13.2 dedicated-token group — "let" / "static" / "yield"
//   * §13.2 lex-as-Identifier group — "implements" / "interface" /
//     "package" / "private" / "protected" / "public"
// Used by the body-strict retroactive parameter check below; the
// parse_binding_pattern path uses the more granular triplet of
// is_strict_reserved_word(token), is_strict_reserved_name(name),
// is_eval_or_arguments(name) because it has access to lex-time info.
is_strict_reserved_binding_name :: #force_inline proc(name: string) -> bool {
	n := len(name)
	// Fast length gate: eval=4, arguments=9, let=3, static=6, yield=5,
	// implements=10, interface=9, protected=9, package=7, private=7, public=6.
	if n < 3 || n > 10 { return false }
	switch name[0] {
	case 'e': return (n == 4 && name == "eval")
	case 'a': return (n == 9 && name == "arguments")
	case 'l': return (n == 3 && name == "let")
	case 's': return (n == 6 && name == "static")
	case 'y': return (n == 5 && name == "yield")
	case 'i': return name == "implements" || name == "interface"
	case 'p': return name == "package" || name == "private" ||
	                 name == "protected" || name == "public"
	}
	return false
}

// report_strict_param_pattern_retro — when a function body promotes
// to strict mode via a `"use strict"` directive AND the outer scope
// was sloppy, the params were parsed under p.ctx.strict_mode=false and so
// parse_binding_pattern's strict-binding check did NOT fire on them.
// Walk every BindingIdentifier reachable from the param patterns and
// emit the strict-mode-reserved diagnostic for each match. Mirrors
// the checker's ck_check_strict_param_pattern recursive walk.
// Caller must gate on `body_strict && !outer_strict` so the
// enclosing-strict path (already covered by parse_binding_pattern)
// doesn't double-fire.
report_strict_param_pattern_retro :: proc(p: ^Parser, params: []FunctionParameter) {
	for pr in params {
		walk_strict_param_binding(p, pr.pattern)
	}
}

walk_strict_param_binding :: proc(p: ^Parser, pat: Pattern) {
	if pat == nil { return }
	switch v in pat {
	case ^Identifier:
		if v == nil { return }
		if is_eval_or_arguments(v.name) {
			msg := fmt.tprintf("Parameter name '%s' is not allowed in strict mode", v.name)
			report_error_coded_span(p, .K3050_StrictModeReserved, u32(v.loc.start), u32(v.loc.start), msg)
		} else if is_strict_reserved_binding_name(v.name) {
			msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", v.name)
			report_error_coded_span(p, .K3050_StrictModeReserved, u32(v.loc.start), u32(v.loc.start), msg)
		}
	case ^ObjectPattern:
		if v == nil { return }
		for prop in v.properties { walk_strict_param_binding(p, prop.value) }
	case ^ArrayPattern:
		if v == nil { return }
		for elem in v.elements {
			if inner, ok := elem.(Pattern); ok { walk_strict_param_binding(p, inner) }
		}
	case ^AssignmentPattern:
		if v == nil { return }
		walk_strict_param_binding(p, v.left)
	case ^RestElement:
		if v == nil { return }
		walk_strict_param_binding(p, v.argument)
	case ^MemberExpression:
		return
	}
}

// check_strict_ts_decl_name — emit a strict-mode-reserved diagnostic
// when a TS declaration (interface, enum, type alias, namespace)
// uses a strict-reserved word as its name while in strict mode.
// Mirrors OXC's parser-level "The keyword 'X' is reserved" check.
// Skips ambient / .d.ts context (reserved words are valid there).
check_strict_ts_decl_name :: proc(p: ^Parser, name: string, loc: Loc) {
	if !p.ctx.strict_mode { return }
	if p.ctx.in_ambient || p.source_is_dts { return }
	// Only strict-reserved FutureReservedWords (implements, interface,
	// package, private, protected, public) are rejected here.
	// `eval`/`arguments` and `let`/`static`/`yield` are valid as TS
	// declaration names even in strict mode (OXC accepts them).
	if is_strict_reserved_name(name) {
		msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", name)
		report_error_coded_span(p, .K3050_StrictModeReserved, u32(loc.start), u32(loc.start), msg)
	}
}

// is_ts_primitive_type_name — returns true for built-in type names that
// cannot be used as class, interface, or enum names (TS2414/TS2427/TS2431).
// is_ts_primitive_type_name — built-in type names forbidden as
// class (TS2414), interface (TS2427), enum (TS2431), and type alias
// (TS2457) declaration names. OXC rejects: any, boolean, number,
// string, symbol, undefined.
is_ts_primitive_type_name :: #force_inline proc(name: string) -> bool {
	n := len(name)
	if n < 3 || n > 9 { return false }
	switch name {
	case "any", "boolean", "number", "string", "symbol", "undefined":
		return true
	}
	return false
}

// check_ts_primitive_decl_name — reject primitive type names as
// class/interface/enum declaration names. Mirrors OXC's
// TS2414/TS2427/TS2431 parser-level checks.
check_ts_primitive_decl_name :: proc(p: ^Parser, kind: string, name: string, loc: Loc) {
	if !allow_ts_mode(p) { return }
	if is_ts_primitive_type_name(name) {
		msg := fmt.tprintf("%s name cannot be '%s'", kind, name)
		report_error_coded_span(p, .K3030_ClassDeclarationStructure, u32(loc.start), u32(loc.start), msg)
	}
}

// Scan a FormalParameters list for duplicate binding names and report
// each duplicate. Callers decide when to run it:
//   * function / function expression - always safe to call; no-op in
//     sloppy mode when params are simple (B.3.1 allows dups there).
//   * class methods, object-literal methods, arrow functions - always
//     UniqueFormalParameters.
// is_this_param returns true if the given FunctionParameter has a
// pattern of ^Identifier with name "this" - the TS-only `this`
// parameter that specifies the type of `this` inside the function.
is_this_param :: #force_inline proc(fp: FunctionParameter) -> bool {
	id, is_id := fp.pattern.(^Identifier)
	return is_id && id != nil && id.name == "this"
}

// count_real_params returns the number of "real" runtime parameters,
// excluding a leading TS `this` parameter (type-only, not runtime).
count_real_params :: #force_inline proc(p: ^Parser, params: []FunctionParameter) -> int {
	n := len(params)
	if n > 0 && allow_ts_mode(p) && is_this_param(params[0]) {
		n -= 1
	}
	return n
}

// enforce_accessor_param_shape implements §15.4.3 (Getter), §15.4.4 (Setter
// arity), §15.4.5 (Setter parameter shape) at parse time. The arity and
// rest-parameter rules are STRUCTURAL per the grammar — a setter with rest
// or two params can't be a syntactically valid PropertySetParameterList —
// so they belong on the parser side and fire in both JS and TS mode.
// The "setter cannot have an initializer" rule is TYPESCRIPT-ONLY because
// the JS grammar (§15.4.5) routes through SingleNameBinding which permits
// `Initializer_opt`, so `set foo(v = null) {}` is legal JS (real-world
// example: three.js's Texture.image setter). Only the TS spec adds the
// extra restriction; OXC mirrors this gating, and we match here.
// Slice 15 (2026-05-07) promoted these checks from the semantic checker
// Diagnostic location convention matches OXC:
//   * arity errors anchor at the property key (so the underline lands on
//     `set foo` rather than `(`),
//   * setter param-shape errors anchor at the offending parameter.
// Used by both class-element parsing (parse_class_element) and
// object-literal accessor parsing (parse_property). Both call sites share
// the rule because §15.4 applies to both Class accessors and Object
// accessors.
enforce_accessor_param_shape :: proc(
	p: ^Parser,
	is_setter: bool,
	params: []FunctionParameter,
	key_loc: LexerLoc,
) {
	real_n := count_real_params(p, params)
	real_idx := 0
	if len(params) > 0 && allow_ts_mode(p) && is_this_param(params[0]) {
		real_idx = 1
	}
	if !is_setter {
		if real_n != 0 {
			report_error_coded_span(p, .K3035_GetterSetterParam, u32(key_loc), u32(key_loc),
				"Getter must not have any formal parameters")
		}
		return
	}
	if real_n != 1 {
		report_error_coded_span(p, .K2070_RequiredFormOrBinding, u32(key_loc), u32(key_loc), "Setter must have exactly one formal parameter")
		return
	}
	param := params[real_idx]
	param_loc := LexerLoc(param.loc.start)
	if _, is_rest := param.pattern.(^RestElement); is_rest {
		report_error_coded_span(p, .K3035_GetterSetterParam, u32(param_loc), u32(param_loc), "Setter parameter cannot be a rest element")
	}
	// TS-only: §15.4.5 + TS strictness forbid `set foo(v = ...) {}`. JS
	// permits it via SingleNameBinding's Initializer_opt; do not flag.
	if allow_ts_mode(p) {
		if _, has_default := param.default_val.(^Expression); has_default {
			report_error_coded_span(p, .K4061_GetSetForm, u32(param_loc), u32(param_loc),
				"A 'set' accessor cannot have an initializer")
		}
		// TS1051 — set accessor parameter cannot be optional.
		if id, ok := param.pattern.(^Identifier); ok && id != nil && id.optional {
			report_error_coded_span(p, .K4061_GetSetForm, u32(param_loc), u32(param_loc),
				"A 'set' accessor cannot have an optional parameter")
		}
	}
}

parse_variable_declarator :: proc(p: ^Parser, kind: VariableKind, in_for := false, is_declare := false) -> ^VariableDeclarator {
	start := cur_loc(p)

	pattern := parse_binding_pattern(p)

	// TS definite assignment assertion: `var x!: T`, `let y!: U[]`, etc.
	// The `!` appears between the binding pattern and the type annotation
	// `:` (NOT after the annotation, NOT before the `=` initializer). Same
	// `!:` syntax used on class fields, parsed identically there. Restricted
	// to plain Identifier bindings - TS spec disallows `!` on object/array
	// destructuring patterns.	// "Expected '=', ',', or ';' after variable binding" cluster
	definite := false
	if is_token(p, .Not) {
  ensure_nxt(p)
		nxt := p.lexer.nxt.kind
		if nxt == .Colon {
			if _, is_ident := pattern.(^Identifier); is_ident {
				definite = true
				eat(p) // consume `!`
			}
		}
	}

	// TypeScript type annotation. Identifier binding nodes carry the
	// annotation directly; ObjectPattern / ArrayPattern carry it on the
	// pattern slot so `const {a}: Props = ...` and
	// `const [x]: T[] = ...` round-trip correctly. OXC also extends the
	// binding node's `end` over the annotation — mirror that for span parity.
	has_type_ann := false
	if is_token(p, .Colon) && allow_ts_mode(p) {
		has_type_ann = true
		ann := parse_ts_type_annotation(p)
		#partial switch t in pattern {
		case ^Identifier:
			t.type_annotation = ann
			if ann != nil && ann.loc.end > t.loc.end {
				t.loc.end = ann.loc.end
			}
		case ^ObjectPattern:
			t.type_annotation = ann
			if ann != nil && ann.loc.end > t.loc.end {
				t.loc.end = ann.loc.end
			}
		case ^ArrayPattern:
			t.type_annotation = ann
			if ann != nil && ann.loc.end > t.loc.end {
				t.loc.end = ann.loc.end
			}
		}
	}

	// §14.3 / §14.7.5.1 - after the BindingIdentifier / BindingPattern
	// the only legal continuations are `=`, `,`, `;`, `in`, `of`, `)`,
	// `]`, `}`, EOF, or a line terminator (ASI). Anything else -
	// `var x += 1;`, `var x | y;`, `var x*1;`, `var x : T = ...` (TS, handled
	// above) - is a SyntaxError. Reporting here avoids the recovery path
	// silently swallowing the bad operator and salvaging a partial AST.
	if !cur_has_newline(p) {
		#partial switch p.cur_type {
		case .Assign, .Comma, .Semi, .In, .Of,
		     .RParen, .RBracket, .RBrace, .EOF: // legal
		case:
			report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected '=', ',', or ';' after variable binding")
		}
	}

	init: Maybe(^Expression)
	if match_token(p, .Assign) {
		// OXC rule: `declare const x: T = v` is an error (type ann + init),
		// but `declare const x = v` without type annotation is OK (TS infers).
		// .d.ts files are fully ambient - never error on const init there.
		// Inherited ambient (namespace) only errors for non-const kinds.
		if p.source_is_dts {
			if kind != .Const {
				report_error_coded(p, .K4050_AmbientContextRestriction, "Initializers are not allowed in ambient contexts")
			}
		} else {
			if is_declare && has_type_ann {
				report_error_coded(p, .K4050_AmbientContextRestriction, "Initializers are not allowed in ambient contexts")
			} else if is_declare && kind != .Const {
				report_error_coded(p, .K4050_AmbientContextRestriction, "Initializers are not allowed in ambient contexts")
			} else if p.ctx.in_ambient && kind != .Const {
				report_error_coded(p, .K4050_AmbientContextRestriction, "Initializers are not allowed in ambient contexts")
			}
		}
		init_expr := parse_assignment_expression(p)
		if init_expr == nil {
			// `var x = ;` / `let x = ;` etc. The `=` committed us to an
			// initializer, but the expression parser could not find one.
			// Report so the recovery verifier and editor-tooling see
			// the problem; the declarator still emits with init = nil
			// so the caller's for-statement / declaration parse can
			// continue from the next `;` / `,` / `)`.
			report_error_coded(p, .K2020_ExpectedExpression, "Expected initializer expression after '='")
		} else {
			init = init_expr
		}
	}
	// NOTE: `const x;` / `using x;` / `await using x;` missing-initializer
	// check now lives in parse_variable_declaration so every declarator
	// variant reports once (ambient / for-head special cases handled
	// there). The old per-declarator check here fired a duplicate error
	// for `const` in non-for / non-ambient contexts.

	decl := new_node(p, VariableDeclarator)
	decl.loc = start
	decl.id = pattern
	decl.init = init
	decl.definite = definite
	decl.loc.end = prev_end_offset(p)

	return decl
}

// Keywords that cannot validly start an ExpressionStatement. When one of
// these appears at the start of a statement, it's always an error (the
// dedicated statement parsers for these keywords are dispatched earlier in
// parse_statement). This catches `case = 1;`, `default = 1;`, etc.
// Keywords that CAN start expressions are excluded: `new X()`, `delete x`,
// `typeof x`, `void x`, `this`, `class {}`, `function() {}`, `super`,
// `import(...)`, `true`, `false`, `null`.
is_keyword_not_expression_start :: #force_inline proc(t: TokenType) -> bool {
	#partial switch t {
	case .Case, .Default, .Extends, .In, .Instanceof,
	     .Catch, .Finally, .Else, .With,
	     // Statement-only keywords that surface here when the parser
	     // walks an expression context but the source has e.g.
	     // `(debugger)`. Test262: language/statements/debugger/expression.
	     .Debugger:
		return true
	}
	return false
}

// is_identifier_like_token returns true for token types that may appear
// where an IdentifierReference / BindingIdentifier is expected. This is
// the union of `.Identifier` itself and every contextual keyword (TS or
// JS) that the lexer hands out as its own token type but which the
// grammar still accepts as an identifier reference. Mirrors the
// `case .Identifier, .Get, .Set, ...:` arm in `parse_unary_expr`.
is_identifier_like_token :: #force_inline proc(t: TokenType) -> bool {
	#partial switch t {
	case .Identifier, .Get, .Set, .From, .Of, .As, .Let, .Static,
	     .Async,
	     .Constructor, .Assert, .Asserts, .Abstract, .Declare, .Readonly,
	     .Override, .Keyof, .Infer, .Is, .Satisfies, .Never, .Unique,
	     .Namespace, .Module, .Implements, .Require, .Package, .Private,
	     .Protected, .Public, .Accessor, .Target, .Await, .Yield:
		return true
	}
	return false
}

// Keywords that normally start a prefix expression (`delete x`, `new X`,
// `typeof x`, `void x`) but cannot be used as IdentifierReferences.
// When followed by `=` at statement position, they're being used as
// assignment targets which is always invalid.
is_keyword_with_operand :: #force_inline proc(t: TokenType) -> bool {
	#partial switch t {
	case .Delete, .New, .Typeof, .Void:
		return true
	}
	return false
}

// is_reserved_word_for_binding classifies the ES-2024 ReservedWords that
// may NOT appear as a BindingIdentifier (variable / param / catch / label /
// class name). Contextual keywords (async / static / let / of / from / as /
// yield / await / type / interface / enum / ...) stay binding-legal
// because they lex as `.Identifier` in most contexts - this helper only
// names the tokens whose TokenType is itself a reserved keyword.
// Strict-mode extras (let, static, yield, implements, interface, package,
// private, protected, public) are intentionally NOT rejected here; the
// existing in-flight strict-mode handling already gates them.
is_reserved_word_for_binding :: #force_inline proc(t: TokenType) -> bool {
	#partial switch t {
	case .Class, .Function, .Var, .Const, .New, .Delete, .Typeof, .Void,
	     .In, .Instanceof, .Extends, .Super, .This, .With, .Debugger,
	     .Return, .Throw, .Try, .Catch, .Finally,
	     .If, .Else, .For, .While, .Do, .Switch, .Case,
	     .Break, .Continue, .Default,
	     .True, .False, .Null,
	     .Import, .Export:
		return true
	}
	return false
}

// ECMA-262 §13.2 FutureReservedWords that are only reserved in strict
// mode. Kessel's lexer emits `.Let`, `.Static`, `.Yield` as dedicated
// tokens (they're ES1 FutureReservedWords / BCP keywords), but
// `implements`, `interface`, `package`, `private`, `protected`,
// `public` all arrive as plain `.Identifier` so that sloppy-mode
// `var interface = 1;` keeps working. The strict-mode binding check
// therefore runs in two places: this predicate catches the
// dedicated-token group; `is_strict_reserved_name` catches the
// identifier-lexed group by source name.
is_strict_reserved_word :: #force_inline proc(t: TokenType) -> bool {
	#partial switch t {
	case .Let, .Static, .Yield:
		return true
	}
	return false
}

// Strict-mode FutureReservedWords that lex as plain `.Identifier`:
// used by parse_binding_pattern to gate `var implements = 1;` etc.
// when `p.ctx.strict_mode` is active.
is_strict_reserved_name :: #force_inline proc(name: string) -> bool {
	n := len(name)
	if n < 6 || n > 10 { return false }
	switch name[0] {
	case 'i':
		if n == 9 { return name == "interface" }
		if n == 10 { return name == "implements" }
	case 'p':
		if n == 6 { return name == "public" }
		if n == 7 { return name == "package" || name == "private" }
		if n == 9 { return name == "protected" }
	}
	return false
}

// `eval` and `arguments` are not keywords but are forbidden as binding
// identifiers in strict mode (ECMA-262 §13.1.1). The lexer emits them
// as plain .Identifier tokens, so the check happens on the string value.
is_eval_or_arguments :: #force_inline proc(name: string) -> bool {
	n := len(name)
	if n != 4 && n != 9 { return false }  // eval=4, arguments=9
	return name == "eval" || name == "arguments"
}

// `await` is a context-dependent reserved word per §12.6.1.1: only
// reserved when the enclosing context is [+Await] (AsyncFunctionBody,
// AsyncGeneratorBody, ModuleBody). Returns true when the parser is
// currently inside such a context, so `await` cannot be used as a
// BindingIdentifier / IdentifierReference / LabelIdentifier.
// Drop #force_inline: the lazy pre-scan path means this is no longer
// a tiny constant-time check. The function is called from ~12 sites,
// many of them rare; a single shared call-site keeps the icache cost
// flat and lets the lazy-scan slow path live in one place.
await_is_reserved_here :: proc(p: ^Parser) -> bool {
	// .d.ts declaration files allow `await` as an identifier everywhere.
	if p.source_is_dts { return false }
	// TS ambient declarations (`declare const await: any`) don't execute,
	// so `await` is not reserved there — even in module code. Matches OXC.
	if p.ctx.in_ambient { return false }
	if p.ctx.in_async || p.ctx.in_async_params { return true }
	// §15.7.5 - class static blocks run under [~Await]; `await` is
	// a reserved word within ClassStaticBlockBody.
	if p.ctx.in_static_block { return true }
	// TS namespace / module body is NOT an async context. `await` is
	// an identifier there, even if the file is a module.
	if p.ctx.in_ts_namespace { return false }
	// ECMA-262 §13.1 says `await` is reserved when the goal symbol is
	// Module. V8 and Babel enforce this. OXC does NOT — it accepts
	// `export var await;`, `export function await() {}`, `let await = 1;`
	// in module top-level binding positions. Kessel's conformance oracle
	// is OXC (`parseSync` from npm `oxc-parser`), so we match OXC here.
	// This means a NON-async, NON-static-block, NON-namespace context
	// outside the parameter / async-body never reserves await as an
	// identifier — it's only the keyword inside an actual async function
	// or in `await expr` expression position. The lazy module pre-scan
	// (ensure_module_syntax_resolved) is consequently NOT needed here:
	// removing the call also removes the only hot-path lazy-scan
	// trigger on real-world bundles, completing the s25-era
	// 0.93×-of-OXC perf restoration.
	return false
}

// `yield` is reserved in strict mode and inside any GeneratorBody /
// AsyncGeneratorBody (§12.6.1.1).
yield_is_reserved_here :: #force_inline proc(p: ^Parser) -> bool {
	return p.ctx.in_generator || p.ctx.in_generator_params || p.ctx.strict_mode
}

// ECMA-262 §12.7.2 - "A code point in a ReservedWord cannot be expressed
// by a \UnicodeEscapeSequence." When an IdentifierName written with a
// Unicode escape has a StringValue that matches a ReservedWord and is
// used in an Identifier position (BindingIdentifier / IdentifierReference
// / LabelIdentifier), the narrower `Identifier : IdentifierName but not
// ReservedWord` production fails. IdentifierName positions - member
// access (`obj.\u0069f`), property key (`{\u0069f:1}`), method name
// (`class C { \u0069f(){} }`), import/export specifier names - allow
// escaped reserved words and therefore must NOT call this helper.
// Always-reserved keywords (if / var / return / function / ...) are
// rejected unconditionally. Strict-only FutureReservedWords (let /
// static / yield / implements / interface / package / private /
// protected / public) are rejected only when `p.ctx.strict_mode` is on.
// `yield` / `await` additionally flip to reserved inside a generator /
// async body even in sloppy mode. Non-reserved contextual keywords
// (async / of / from / as / let-in-sloppy / ...) pass through.
is_always_reserved_word_name :: #force_inline proc(name: string) -> bool {
	n := len(name)
	if n < 2 || n > 10 { return false }
	// Dispatch on first byte + length. Each (byte, length) pair maps to
	// at most 1-2 keywords. This avoids the 37-way string switch that
	// Odin compiles as sequential string_eq calls.
	switch name[0] {
	case 'b': return n == 5 && name == "break"
	case 'c':
		if n == 4 { return name == "case" }
		if n == 5 { return name == "catch" || name == "class" || name == "const" }
		if n == 8 { return name == "continue" }
		return false
	case 'd':
		if n == 2 { return name == "do" }
		if n == 6 { return name == "delete" }
		if n == 7 { return name == "default" }
		if n == 8 { return name == "debugger" }
		return false
	case 'e':
		if n == 4 { return name == "else" || name == "enum" }
		if n == 6 { return name == "export" }
		if n == 7 { return name == "extends" }
		return false
	case 'f':
		if n == 3 { return name == "for" }
		if n == 5 { return name == "false" }
		if n == 7 { return name == "finally" }
		if n == 8 { return name == "function" }
		return false
	case 'i':
		if n == 2 { return name == "if" || name == "in" }
		if n == 6 { return name == "import" }
		if n == 10 { return name == "instanceof" }
		return false
	case 'n': return (n == 3 && name == "new") || (n == 4 && name == "null")
	case 'r': return n == 6 && name == "return"
	case 's': return (n == 5 && name == "super") || (n == 6 && name == "switch")
	case 't':
		if n == 3 { return name == "try" }
		if n == 4 { return name == "this" || name == "true" }
		if n == 5 { return name == "throw" }
		if n == 6 { return name == "typeof" }
		return false
	case 'v': return (n == 3 && name == "var") || (n == 4 && name == "void")
	case 'w': return (n == 4 && name == "with") || (n == 5 && name == "while")
	}
	return false
}

// Call BEFORE eating the identifier token - `report_error` uses the
// current token's offset for diagnostics, so the message points at the
// right source location. Non-current-token call sites (e.g. a stashed
// binding identifier consumed earlier) can still use this by passing
// a freshly-constructed Token and accepting the current-cursor offset
// fallback; in practice every caller reports pre-eat.
// Hot-path inline: 99 %+ of identifier parses have no escape, so the
// first guard returns immediately. Marking #force_inline lets the
// compiler keep the parser in registers across the call site without
// spilling for a function it almost never enters.
report_escaped_reserved_word :: #force_inline proc(p: ^Parser) {
	if !cur_has_escape(p) { return }
	if p.cur_type != .Identifier { return }
	report_escaped_reserved_word_slow(p)
}

report_escaped_reserved_word_slow :: proc(p: ^Parser) {
	name := cur_value(p)
	reserved := is_always_reserved_word_name(name)
	if !reserved && p.ctx.strict_mode {
		switch name {
		case "let", "static", "yield",
		     "implements", "interface", "package",
		     "private", "protected", "public":
			reserved = true
		}
	}
	if !reserved && p.ctx.in_generator && name == "yield" {
		reserved = true
	}
	if !reserved && name == "await" && await_is_reserved_here(p) {
		reserved = true
	}
	if reserved {
		msg := fmt.tprintf("Keyword '%s' must not contain escaped characters", name)
		report_error_coded(p, .K3015_KeywordContainsEscape, msg)
	}
}

// ECMA-262 §13.4.1 - in strict mode, the operand of an UpdateExpression
// must not be an IdentifierReference named `eval` or `arguments`.
// Helper shared by both prefix and postfix paths. No-op in sloppy mode
// or when the operand isn't a bare Identifier (member / call / etc.
// stay legal).
// Walk an AssignmentExpression's LHS and report any IdentifierReference
// or destructuring-target that's named `eval` or `arguments`. Per
// §13.15.1 / §13.5.1.1, these names are SyntaxErrors as assignment
// targets in strict mode. The walker descends the same shapes that
// expr_to_pattern accepts (ArrayExpression / ObjectExpression / spread /
// assignment-init) so a destructuring-assignment LHS is fully covered.
// Walk a function-parameter list and report §15.1.1 strict-mode
// violations: param names that are `eval`, `arguments`, or any strict-
// reserved word are SyntaxErrors. Used after parse_function_body when
// the body's directive prologue contained `"use strict"` or the
// enclosing context was strict.
// A numeric literal's raw source looks like a "0-prefixed integer" if
// it starts with `0` and the next character is a decimal digit. This
// covers both LegacyOctalIntegerLiteral (`0777`) and
// NonOctalDecimalIntegerLiteral (`078`, `090`). Modern prefixes
// (`0x`, `0o`, `0b`), floats (`0.5`, `0e10`), BigInt (`0n`), and the
// plain literal `0` are explicitly NOT matched. Strict mode forbids
// this whole shape (ECMA-262 Annex B.1.1).
is_legacy_zero_prefixed_integer :: proc(raw: string) -> bool {
	if len(raw) < 2 { return false }
	if raw[0] != '0' { return false }
	c := raw[1]
	return c >= '0' && c <= '9'
}

// Scan a StringLiteral's raw source for escape sequences that the
// spec forbids in strict code:
//   * LegacyOctalEscapeSequence: `\0` followed by another digit
//     (`\00`..`\07`, `\012`, `\377`), OR `\1`..`\7` (`\3`, `\123`).
//   * NonOctalDecimalEscapeSequence: `\8` or `\9`.
// `\0` alone (NUL escape) is legal in both modes and explicitly
// excluded by the spec; we only flag `\0` when the next char is a
// decimal digit, turning it into a LegacyOctalEscape of the form
// `\0<digit>...`.
// The `raw` input includes the enclosing quote characters; the scan
// tolerates them and any non-escape content. A `\\` consumes the next
// character (so `\\0` is a literal backslash followed by `0`, not a
// NUL escape).
// Walk an untagged TemplateLiteral raw body for §12.9.6 invalid
// EscapeSequences. Untagged templates (no MemberExpression tag
// precedes the backtick) reject every EscapeSequence kind that's
// illegal under the NoSubstitutionTemplate production:
//   * LegacyOctalEscapeSequence (\0-\7 with a trailing digit-ish)
//   * NonOctalDecimalEscapeSequence (\8, \9)
//   * HexEscapeSequence with fewer than 2 hex digits (\x0, \xZZ)
//   * UnicodeEscapeSequence fewer than 4 hex digits (\u00)
//   * \u{H+} missing `}` or non-hex
untagged_template_raw_has_invalid_escape :: proc(raw: string) -> bool {
	i := 0
	n := len(raw)
	for i < n {
		c := raw[i]
		if c != '\\' { i += 1; continue }
		if i + 1 >= n { return false }
		next := raw[i+1]
		switch next {
		case '8', '9':
			return true
		case '1', '2', '3', '4', '5', '6', '7':
			return true
		case '0':
			if i + 2 < n {
				d := raw[i+2]
				if d >= '0' && d <= '9' { return true }
			}
			i += 2
			continue
		case 'x':
			// Need exactly 2 hex digits after \x.
			if i + 3 >= n { return true }
			h1 := raw[i+2]
			h2 := raw[i+3]
			if !is_hex_digit(h1) || !is_hex_digit(h2) { return true }
			i += 4
			continue
		case 'u':
			if i + 2 >= n { return true }
			if raw[i+2] == '{' {
				// \u{H+} - at least one hex digit, terminated by `}`.
				j := i + 3
				digits := 0
				cp: u32 = 0
				for j < n && raw[j] != '}' {
					if !is_hex_digit(raw[j]) { return true }
					cp = cp * 16 + u32(hex_val_byte(raw[j]))
					digits += 1
					j += 1
				}
				if j >= n || digits == 0 { return true }
				// Codepoint must not exceed U+10FFFF.
				if cp > 0x10FFFF { return true }
				i = j + 1
				continue
			} else {
				// \uHHHH
				if i + 5 >= n { return true }
				for k := i + 2; k < i + 6; k += 1 {
					if !is_hex_digit(raw[k]) { return true }
				}
				i += 6
				continue
			}
		}
		i += 2
	}
	return false
}

is_hex_digit :: #force_inline proc(c: u8) -> bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

hex_val_byte :: #force_inline proc(c: u8) -> u8 {
	if c >= '0' && c <= '9' { return c - '0' }
	if c >= 'a' && c <= 'f' { return c - 'a' + 10 }
	if c >= 'A' && c <= 'F' { return c - 'A' + 10 }
	return 0
}

string_raw_has_forbidden_escape :: proc(raw: string) -> bool {
	i := 0
	n := len(raw)
	for i < n {
		c := raw[i]
		if c != '\\' { i += 1; continue }
		// Lone trailing backslash - leave to other diagnostics.
		if i + 1 >= n { return false }
		next := raw[i+1]
		switch next {
		case '8', '9':
			return true
		case '1', '2', '3', '4', '5', '6', '7':
			return true
		case '0':
			// `\0` alone is fine (CharacterEscapeSequence for null char).
			// `\0` followed by `0` is treated as `\0` + literal `0` per OXC
			// (escape-00.js positive fixture).
			// `\0` followed by any other digit (1-9) is forbidden.
			if i + 2 < n {
				d := raw[i+2]
				if d >= '1' && d <= '9' { return true }
			}
			i += 2
			continue
		}
		// Any other escape: consume the backslash + the following char
		// and resume. This correctly skips `\n`, `\t`, `\"`, `\\`,
		// `\xHH`, `\uHHHH`, `\u{H+}`, and line continuations.
		i += 2
	}
	return false
}

parse_binding_pattern :: proc(p: ^Parser) -> Pattern {
	if is_token(p, .LBrace) {
		return parse_object_pattern(p)
	}

	if is_token(p, .LBracket) {
		return parse_array_pattern(p)
	}

	// Reject reserved words in binding position (`var class = 1;`,
	// `let function = 2;`, etc.). Contextual keywords pass through
	// because they lex as `.Identifier`; only hard-reserved keyword
	// tokens trip this branch.
	if is_reserved_word_for_binding(p.cur_type) {
		msg := fmt.tprintf("'%s' is a reserved word and cannot be used as a binding name", cur_value(p))
		report_error_coded(p, .K3053_ReservedAsBindingIdentifier, msg)
		// Consume the keyword and return a placeholder identifier so the
		// rest of the declarator (init expression) still parses, keeping
		// error recovery tight. The identifier's name carries the raw
		// source so downstream emits see something stable.
		id_loc := cur_loc(p)
		id_name := cur_value(p)
		eat(p)
		ident := new_node(p, Identifier)
		ident.loc = id_loc
		ident.name = id_name
		return ident
	}

	// Strict-mode reserved words (`let`, `static`, `yield`, `implements`,
	// `interface`, `package`, `private`, `protected`, `public`) as a
	// BindingIdentifier are SyntaxErrors only in strict mode
	// (ECMA-262 §13.2). In sloppy script they remain valid binding
	// identifiers (`var let = 1;`). The strict-mode diagnostic is
	// promoted to the parser (mirrors
	// ck_check_strict_binding_pattern in the semantic checker) so
	// parser-only snaps reject `"use strict"; var yield;` etc.
	// Sloppy code falls through to the contextual-yield / await /
	// identifier branches below (e.g. `var yield = 1` inside a sloppy
	// generator reaches the contextual `.Yield` branch and reports a
	// structural error).
	// In TS ambient contexts (declare namespace/module, .d.ts), strict-mode
	// reserved words ARE allowed as identifiers.
	if p.ctx.strict_mode && is_strict_reserved_word(p.cur_type) &&
	   !(allow_ts_mode(p) && (p.ctx.in_ambient || p.source_is_dts)) {
		id_loc := cur_loc(p)
		id_name := cur_value(p)
		msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", id_name)
		report_error_coded_span(p, .K3050_StrictModeReserved, u32(id_loc.start), u32(id_loc.start), msg)
		eat(p)
		ident := new_node(p, Identifier)
		ident.loc = id_loc
		ident.name = id_name
		return ident
	}

	// Context-sensitive reserved words for bindings:
	//   * `yield` is reserved in a GeneratorBody / GeneratorDeclaration
	//     (ECMA-262 §13.2). `p.ctx.in_generator` carries exactly that
	//     context.
	//   * `await` is reserved in an AsyncFunction / AsyncGenerator /
	//     AsyncArrow / Module. We use `p.ctx.in_async` for the function
	//     forms; module top-level is covered by the caller that pins
	//     sourceType=module (future work).
	// Both tokens already have dedicated TokenTypes in Kessel's lexer,
	// so the check is a simple kind comparison.
	if (p.ctx.in_generator || p.ctx.in_generator_params) && p.cur_type == .Yield {
		report_error_coded(p, .K3010_AwaitYieldAsBindingName, "'yield' is reserved as a binding name in a generator")
		id_loc := cur_loc(p)
		id_name := cur_value(p)
		eat(p)
		ident := new_node(p, Identifier)
		ident.loc = id_loc
		ident.name = id_name
		return ident
	}
	// Plain `await` lexes as TokenType.Await; only escaped forms
	// (`\u0061wait`) reach Identifier with cur_value == "await". Gate
	// the string compare on has_escape so it stays off the hot path for
	// every ordinary identifier in a binding position.
	// §13.1 — `await` is reserved as a BindingIdentifier when the
	// enclosing goal symbol is Module (§16.2.2). Check both
	// await_is_reserved_here (async / static-block) AND explicit
	// module source-type.
	await_reserved_for_binding := await_is_reserved_here(p)
	if !await_reserved_for_binding {
		if st, have := p.force_source_type.(SourceType); have && st == .Module { await_reserved_for_binding = true }
		else if p.in_module_top_level || p.has_module_syntax { await_reserved_for_binding = true }
	}
	// .d.ts declaration files allow `await` as a binding name (tsc/OXC agree).
	if p.source_is_dts { await_reserved_for_binding = false }
	if (p.cur_type == .Await || (p.cur_type == .Identifier && cur_has_escape(p) && cur_value_eq(p, "await"))) && await_reserved_for_binding {
		report_error_coded(p, .K3010_AwaitYieldAsBindingName, "'await' is reserved as a binding name in this context")
		id_loc := cur_loc(p)
		id_name := cur_value(p)
		eat(p)
		ident := new_node(p, Identifier)
		ident.loc = id_loc
		ident.name = id_name
		return ident
	}

	// Identifiers and contextual keywords that can be used as binding names.
	// All contextual keywords are valid binding identifiers in JS.
	if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
		// ECMA-262 §12.7.2 - BindingIdentifier is an Identifier position,
		// so an escaped ReservedWord (cooked value matches a keyword) is a
		// Syntax Error regardless of strict-mode reservation. Runs before
		// eat so report_error points at the escaped token.
		report_escaped_reserved_word(p)
		id_loc := cur_loc(p)
		id_name := cur_value(p)
		// FutureReservedWords are never valid BindingIdentifiers. The
		// previous version called `is_always_reserved_word_name(id_name)`
		// here (a 36-way string switch on every binding identifier), but
		// kessel's lexer emits dedicated tokens for 35 of those 36 reserved
		// words - they're caught by `is_reserved_word_for_binding` at the
		// top of this function before we ever reach the identifier branch.
		// The only word from that list that arrives as `.Identifier` (with
		// `has_escape == false`) is `enum`, which kessel lexes as a TS
		// contextual identifier so `var enum = 1;` works in sloppy script.
		// Replacing the 36-way switch with a single equality check elides
		// up to 35 string compares per binding identifier in the bench
		// corpus (~50K bindings on monaco, parse_binding_pattern was
		// holding 33 of the 87 monaco `string_eq` profile samples).
		// has_escape == true takes the slow path via
		// `report_escaped_reserved_word(p)` already; we don't repeat the
		// full check here.
		id_has_escape := cur_has_escape(p)
		if !id_has_escape && id_name == "enum" {
			msg := fmt.tprintf("'%s' is a reserved word and cannot be used as a binding identifier", id_name)
			report_error_coded(p, .K3053_ReservedAsBindingIdentifier, msg)
		}
		// §13.1.1 strict-mode `eval` / `arguments` and strict-reserved
		// FutureReservedWords (lex-as-Identifier forms) as a
		// BindingIdentifier are SyntaxErrors. Promoted from the semantic
		// checker (ck_check_strict_binding_pattern) so parser-only snaps
		// reject the strict-mode-reserved-name binding clusters in
		// test262 / babel without --show-semantic-errors.
		// Both checks gate on p.ctx.strict_mode AND skip when the name has an
		// escape sequence — escaped reserved words already produced a
		// diagnostic via report_escaped_reserved_word above; firing again
		// would double-report the same source location. id_has_escape was
		// captured before eat(p) below because the parser then points at the
		// next token, not the binding identifier.
		// In TS ambient contexts (declare namespace/module, .d.ts),
		// strict-mode reserved words ARE allowed as identifiers.
		// Gate: same pattern as the token-type check above —
		// skip only when in ambient or .d.ts context.
		if p.ctx.strict_mode && !id_has_escape &&
		   !(allow_ts_mode(p) && (p.ctx.in_ambient || p.source_is_dts)) {
			if is_eval_or_arguments(id_name) {
				msg := fmt.tprintf("'%s' cannot be used as a binding name in strict mode", id_name)
				report_error_coded_span(p, .K3050_StrictModeReserved, u32(id_loc.start), u32(id_loc.start), msg)
			} else if is_strict_reserved_name(id_name) {
				msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", id_name)
				report_error_coded_span(p, .K3050_StrictModeReserved, u32(id_loc.start), u32(id_loc.start), msg)
			}
		}
		eat(p)
		ident := new_node(p, Identifier)
		ident.loc = id_loc
		ident.name = id_name
		return ident
	}

	report_error_coded(p, .K3043_DestructuringInvalid, "Expected binding pattern")
	return nil
}

parse_object_pattern :: proc(p: ^Parser) -> Pattern {
	start := cur_loc(p)

	if !expect_token(p, .LBrace) {
		return nil
	}

	obj := new_node(p, ObjectPattern)
	obj.loc = start
	// Lazy alloc - zero-element object patterns (`function f({}){}`) are
	// rare but cheap to skip for, and the surrounding parse_function_param
	// path is hot enough that a few avoided 32-byte reservations show up.
	if !is_token(p, .RBrace) && !is_token(p, .EOF) {
		obj.properties = make([dynamic]ObjectPatternProperty, 0, 4, p.allocator)
	}

	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		prop_start := cur_loc(p)

		// Check for rest element: ...identifier
		if match_token(p, .Dot3) {
			if !is_token(p, .Identifier) {
				report_error_coded(p, .K2021_ExpectedIdentifier, "Expected identifier after ... in object pattern")
				return nil
			}
			rl := cur_loc(p); rn := cur_value(p)
			rest := new_node(p, RestElement)
			rest.loc = prop_start
			rest_ident := new_node(p, Identifier)
			rest_ident.loc = rl
			rest_ident.name = rn
			rest.argument = rest_ident
			rest.loc.end = rl.end
			eat(p)

			rest_prop := ObjectPatternProperty{
				loc       = prop_start,
				key       = nil,
				value     = rest,
				shorthand = false,
			}
			bump_append(&obj.properties, rest_prop)

			// Rest element must be last
			if !is_token(p, .RBrace) {
				report_error_coded(p, .K3040_RestNotLast, "Rest element must be last in object pattern")
			}
			break
		}

		// Parse key
		key: Maybe(ObjectPatternPropertyKey)
		computed := false

		if is_token(p, .LBracket) {
			// Computed property: [expr] - same `[` no_in carve-out as in
			// parse_class_element / parse_property.
			computed = true
			eat(p)
			prev_no_in_op := p.ctx.no_in
			p.ctx.no_in = false
			expr_key := parse_assignment_expression(p)
			p.ctx.no_in = prev_no_in_op
			if expr_key != nil {
				key = (^Expression)(expr_key)
			}
			if !expect_token(p, .RBracket) {
				return nil
			}
		} else if is_token(p, .String) {
			// String key: `{ 'aria-label': x }`. Store as ^StringLiteral so
			// the emitter can render a Literal node - previously stuffed into
			// an IdentifierName whose `name` field contained the quoted raw
			// source (`'aria-label'` literally), producing an Identifier with
			// quoted name in the JSON and hiding the real string value from
			// every downstream string-walker.
			current := snap_current(p)
			str_lit := new_node(p, StringLiteral)
			str_lit.loc = loc_from_token(&current)
			str_lit.value = current.literal.(string) or_else ""
			str_lit.raw = current.value
			str_lit.loc.end = cur_offset(p) + u32(len(current.value))
			key = str_lit
			eat(p)
			// String-literal keys require `:` — they cannot be shorthand.
			// `{ "while" }` is invalid; must be `{ "while": binding }`.
			if !is_token(p, .Colon) {
				report_error_coded(p, .K3043_DestructuringInvalid, "Expected ':' after string property key in destructuring pattern")
			}
		} else if is_token(p, .Number) {
			// Numeric key: `{ 0: v, 1: w }` (§14.3.3 PropertyName :
			// NumericLiteral path). Must be followed by `:` - numeric
			// keys don't support shorthand.
			current := snap_current(p)
			num_lit := new_node(p, NumericLiteral)
			num_lit.loc = loc_from_token(&current)
			num_lit.raw = current.value
			if v, ok := current.literal.(f64); ok {
				num_lit.value = v
			}
			num_lit.loc.end = cur_offset(p) + u32(len(current.value))
			key = num_lit
			eat(p)
		} else if is_token(p, .BigInt) {
			// BigInt key: `{ 1n: v }` - same as numeric. Must be followed
			// by `:`. Stored as ^Expression (the computed-key variant of
			// the union) since ObjectPatternPropertyKey doesn't include
			// BigIntLiteral directly. ESTree emit treats BigIntLiteral
			// like other Literal kinds.
			current := snap_current(p)
			big, big_e := new_expr(p, BigIntLiteral)
			big.loc = loc_from_token(&current)
			big.raw = current.value
			if len(current.value) > 0 && current.value[len(current.value)-1] == 'n' {
				big.value = current.value[:len(current.value)-1]
			} else {
				big.value = current.value
			}
			big.loc.end = cur_offset(p) + u32(len(current.value))
			key = (^Expression)(big_e)
			eat(p)
		} else if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
			// Identifier or keyword used as key. When the property becomes
			// a shorthand binding (`{ foo }` = `{ foo: foo }`), the key
			// doubles as a BindingIdentifier - escaped-ReservedWord
			// (§12.7.2) must reject. Capture has_escape now, report below
			// only if the property ends up shorthand (explicit `key: val`
			// / `key = init` forms make the key an IdentifierName position,
			// where escapes stay legal).
			key_had_escape := cur_has_escape(p)
			id_name := IdentifierName{
				loc  = cur_loc(p),
				name = cur_value(p),
			}
			key = id_name
			eat(p)
			if key_had_escape && is_always_reserved_word_name(id_name.name) {
				// The cooked name is a ReservedWord; any later use as
				// shorthand or default-shorthand position is an error.
				// Shorthand always reaches the `else` / `.Assign` arm below;
				// explicit `:` forms exit via the type-annotated path and
				// don't fire. Gate the diagnostic by peeking.
				if !is_token(p, .Colon) {
					msg := fmt.tprintf("Keyword '%s' must not contain escaped characters", id_name.name)
					report_error_coded(p, .K3015_KeywordContainsEscape, msg)
				}
			}
		} else {
			report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected property key in object pattern")
			return nil
		}

		// Check for shorthand or value pattern
		if is_token(p, .Colon) {
			// { key: value }
			eat(p)

			// Parse value as pattern (identifiers and contextual keywords)
			if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
				// Reserved words cannot appear as binding targets in
				// destructuring patterns: `{ p: void }`, `{ p: null }` etc.
				if is_reserved_word_for_binding(p.cur_type) {
					report_error_coded(p, .K3053_ReservedAsBindingIdentifier,
						fmt.tprintf("Identifier expected. '%s' is a reserved word that cannot be used here", cur_value(p)))
				}
				// Strict-mode reserved words as object-pattern value binding.
				if p.ctx.strict_mode && !(allow_ts_mode(p) && (p.ctx.in_ambient || p.source_is_dts)) {
					if is_strict_reserved_binding_name(cur_value(p)) {
						msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", cur_value(p))
						report_error_coded(p, .K3050_StrictModeReserved, msg)
					}
				}
				vl := cur_loc(p); vn := cur_value(p)
				value_ident := new_node(p, Identifier)
				value_ident.loc = vl
				value_ident.name = vn
				eat(p)

				// Check for default value: { key: value = defaultValue }
				// Same no_in restore as parse_array_pattern: `for (let
				// {x = 'a' in {}} in ...)` needs `in` as a binary op
				// inside the default expression, not the for-in separator.
				if match_token(p, .Assign) {
					prev_no_in := p.ctx.no_in; p.ctx.no_in = false
					default_val := parse_assignment_expression(p)
					p.ctx.no_in = prev_no_in
					assign := new_node(p, AssignmentPattern)
					// AssignmentPattern.start is the start of the LHS pattern,
					// NOT the enclosing property key. For `{ key: value = 1 }`
					// OXC (and the ESTree spec) emits AssignmentPattern at
					// [value_start, default_end]; previously we inherited
					// prop_start (= key's start), which drifted every nested
					// destructuring span by the width of `key: ` - ~11 bytes
					// per hit on antd.js and other framework code.
					assign.loc = value_ident.loc
					assign.left = value_ident
					assign.right = default_val
					assign.loc.end = prev_end_offset(p)

					prop := ObjectPatternProperty{
						loc       = prop_start,
						key       = key,
						value     = assign,
						computed  = computed,
						shorthand = false,
					}
					prop.loc.end = prev_end_offset(p)
					bump_append(&obj.properties, prop)
				} else {
					prop := ObjectPatternProperty{
						loc       = prop_start,
						key       = key,
						value     = value_ident,
						computed  = computed,
						shorthand = false,
					}
					prop.loc.end = value_ident.loc.end
					bump_append(&obj.properties, prop)
				}
			} else if is_token(p, .LBrace) {
				// Nested object pattern (possibly with default)
				nested := parse_object_pattern(p)
				if nested == nil {
					return nil
				}
				val: Pattern = nested
				if match_token(p, .Assign) {
					prev_no_in := p.ctx.no_in; p.ctx.no_in = false
					default_val := parse_assignment_expression(p)
					p.ctx.no_in = prev_no_in
					assign := new_node(p, AssignmentPattern)
					// Same LHS-start rule as the identifier case above - the
					// nested pattern's own span is the start of the
					// AssignmentPattern, not the outer property's key.
					assign.loc = get_pattern_loc(nested)
					assign.left = nested
					assign.right = default_val
					assign.loc.end = prev_end_offset(p)
					val = assign
				}
				prop := ObjectPatternProperty{
					loc       = prop_start,
						key       = key,
					value     = val,
					computed  = computed,
						shorthand = false,
				}
				prop.loc.end = prev_end_offset(p)
				bump_append(&obj.properties, prop)
			} else if is_token(p, .LBracket) {
				// Nested array pattern (possibly with default)
				nested := parse_array_pattern(p)
				if nested == nil {
					return nil
				}
				val: Pattern = nested
				if match_token(p, .Assign) {
					prev_no_in := p.ctx.no_in; p.ctx.no_in = false
					default_val := parse_assignment_expression(p)
					p.ctx.no_in = prev_no_in
					assign := new_node(p, AssignmentPattern)
					// Same LHS-start rule - see nested-object case above.
					assign.loc = get_pattern_loc(nested)
					assign.left = nested
					assign.right = default_val
					assign.loc.end = prev_end_offset(p)
					val = assign
				}
				prop := ObjectPatternProperty{
					loc       = prop_start,
					key       = key,
					value     = val,
					computed  = computed,
					shorthand = false,
				}
				prop.loc.end = prev_end_offset(p)
				bump_append(&obj.properties, prop)
			} else {
				report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected pattern in object pattern value")
				return nil
			}
		} else if match_token(p, .Assign) {
			// { key = defaultValue } - shorthand with default
			prev_no_in := p.ctx.no_in; p.ctx.no_in = false
			default_val := parse_assignment_expression(p)
			p.ctx.no_in = prev_no_in
			// Create AssignmentPattern with key as left
			if k := key; k != nil {
				val := k.?  // unwrap Maybe
				#partial switch v in val {
				case IdentifierName:
					// §13.2.5.1 / §12.6.1.1 - a shorthand key in an object
					// pattern doubles as a BindingIdentifier; reserved
					// keywords (`default`, `extends`, `class`, ...) are not
					// legal binding names. Same gate fires for the bare
					// `{ default }` shorthand below.
					if is_always_reserved_word_name(v.name) {
						msg := fmt.tprintf("Reserved word '%s' is not a valid binding identifier", v.name)
						report_error_coded(p, .K3053_ReservedAsBindingIdentifier, msg)
					}
					// Strict-mode reserved words as shorthand-with-default binding.
					if p.ctx.strict_mode && !(allow_ts_mode(p) && (p.ctx.in_ambient || p.source_is_dts)) {
						if is_strict_reserved_binding_name(v.name) {
							msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", v.name)
							report_error_coded_span(p, .K3050_StrictModeReserved, u32(v.loc.start), u32(v.loc.start), msg)
						}
					}
					left_ident := new_node(p, Identifier)
					left_ident.loc = v.loc
					left_ident.name = v.name
					assign := new_node(p, AssignmentPattern)
					// Shorthand: prop_start == v.loc.start in practice
					// (the key IS the LHS), but spell it out through
					// left_ident.loc to stay consistent with the other three
					// AssignmentPattern sites in parse_object_pattern.
					assign.loc = left_ident.loc
					assign.left = left_ident
					assign.right = default_val
					assign.loc.end = prev_end_offset(p)

					prop := ObjectPatternProperty{
						loc       = prop_start,
						key       = key,
						value     = assign,
						computed  = computed,
						shorthand = true,
					}
					prop.loc.end = prev_end_offset(p)
					bump_append(&obj.properties, prop)
				}
			}
		} else {
			// Shorthand: { key } means { key: key }
			if k := key; k != nil {
				val := k.?  // unwrap Maybe
				#partial switch v in val {
				case IdentifierName:
					// Shorthand binding name must be a valid BindingIdentifier
					// (§13.2.5.1). See the §Assign branch above for the
					// rationale.
					if is_always_reserved_word_name(v.name) {
						msg := fmt.tprintf("Reserved word '%s' is not a valid binding identifier", v.name)
						report_error_coded(p, .K3053_ReservedAsBindingIdentifier, msg)
					}
					// Strict-mode reserved words as shorthand binding.
					if p.ctx.strict_mode && !(allow_ts_mode(p) && (p.ctx.in_ambient || p.source_is_dts)) {
						if is_strict_reserved_binding_name(v.name) {
							msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", v.name)
							report_error_coded_span(p, .K3050_StrictModeReserved, u32(v.loc.start), u32(v.loc.start), msg)
						}
					}
					// `yield` is reserved in generator bodies; `await` in async.
					if v.name == "yield" && yield_is_reserved_here(p) {
						report_error_coded(p, .K3010_AwaitYieldAsBindingName, "'yield' is reserved as a binding name in a generator")
					}
					if v.name == "await" {
						await_reserved := await_is_reserved_here(p)
						if !await_reserved {
							if st, have := p.force_source_type.(SourceType); have && st == .Module { await_reserved = true }
							else if p.in_module_top_level || p.has_module_syntax { await_reserved = true }
						}
						if await_reserved {
							report_error_coded(p, .K3010_AwaitYieldAsBindingName, "'await' is reserved as a binding name in this context")
						}
					}
					left_ident := new_node(p, Identifier)
					left_ident.loc = v.loc
					left_ident.name = v.name

					prop := ObjectPatternProperty{
						loc       = prop_start,
						key       = key,
						value     = left_ident,
						computed  = false,
						shorthand = true,
					}
					prop.loc.end = left_ident.loc.end
					bump_append(&obj.properties, prop)
				}
			}
		}

		if !match_token(p, .Comma) {
			break
		}
	}

	if !expect_token(p, .RBrace) {
		return nil
	}

	obj.loc.end = prev_end_offset(p)
	return obj
}

// Helper to create identifier from token info
new_identifier :: proc(p: ^Parser, tok: Token) -> ^Identifier {
	tok := tok
	ident := new_node(p, Identifier)
	ident.loc = loc_from_token(&tok)
	ident.name = tok.value
	return ident
}

// new_identifier_from_cur creates an Identifier from the current token without
// copying the 72-byte Token struct. Use before eat() when only loc + name
// are needed.
new_identifier_from_cur :: #force_inline proc(p: ^Parser) -> ^Identifier {
	ident := new_node(p, Identifier)
	ident.loc = cur_loc(p)
	ident.name = cur_value(p)
	return ident
}

parse_array_pattern :: proc(p: ^Parser) -> Pattern {
	start := cur_loc(p)

	if !expect_token(p, .LBracket) {
		return nil
	}

	arr := new_node(p, ArrayPattern)
	arr.loc = start

	// Use dynamic array for elements - each element is Maybe(Pattern)
	elements := make([dynamic]Maybe(Pattern), 0, 8, p.allocator)

	for !is_token(p, .RBracket) && !is_token(p, .EOF) {
		// Check for elision (hole): just a comma
		if is_token(p, .Comma) {
			// This is a hole in the array - add nil
			bump_append(&elements, Maybe(Pattern){})
			eat(p) // consume comma
			continue
		}

		// Check for rest element:
		//   BindingRestElement : ... BindingIdentifier
		//                      | ... BindingPattern   (§14.3.3)
		if is_token(p, .Dot3) {
			rest_start := cur_loc(p) // Capture location of ... before eating
			eat(p) // consume ...

			rest := new_node(p, RestElement)
			rest.loc = rest_start

			if is_token(p, .LBracket) {
				nested := parse_array_pattern(p)
				if nested == nil { return nil }
				rest.argument = nested
			} else if is_token(p, .LBrace) {
				nested := parse_object_pattern(p)
				if nested == nil { return nil }
				rest.argument = nested
			} else if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
				// Reserved words cannot be rest binding targets:
				// `[ ...void ]`, `[ ...null ]` etc.
				if is_reserved_word_for_binding(p.cur_type) {
					report_error_coded(p, .K3053_ReservedAsBindingIdentifier,
						fmt.tprintf("Identifier expected. '%s' is a reserved word that cannot be used here", cur_value(p)))
				}
				arl := cur_loc(p); arn := cur_value(p)
				eat(p)
				rest_ident := new_node(p, Identifier)
				rest_ident.loc = arl
				rest_ident.name = arn
				rest.argument = rest_ident
			} else {
				report_error_coded(p, .K2021_ExpectedIdentifier, "Expected identifier or pattern after ... in array pattern")
				return nil
			}
			rest.loc.end = prev_end_offset(p)

			bump_append(&elements, Maybe(Pattern)(rest))

			// Rest element must be last - and cannot take an Initializer
			// (§14.3.3: no `= default` on BindingRestElement).
			if !is_token(p, .RBracket) && !is_token(p, .EOF) {
				report_error_coded(p, .K3040_RestNotLast, "Rest element must be last in array pattern")
			}
			break
		}

		// Parse regular element
		if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
			// Simple identifier binding, possibly with default value.
			// Apply the reserved-binding check that parse_binding_pattern
			// runs for top-level bindings: `await` is reserved as a binding
			// name inside async / module / class-static-block contexts, and
			// `yield` is reserved inside generator bodies. Test262: language/
			// statements/variable/dstr/ary-ptrn-elem-id-static-init-await-
			// invalid.js (`class C { static { var [await] = []; } }`).
			// Plain `await` / `yield` use dedicated TokenTypes (.Await /
			// .Yield); only escaped forms reach .Identifier with the cooked
			// reserved-word value. Gate the string compares on has_escape
			// so they stay off the hot path for every ordinary identifier
			// in a destructuring binding.
			dstr_await_reserved := await_is_reserved_here(p)
			if !dstr_await_reserved {
				if st, have := p.force_source_type.(SourceType); have && st == .Module { dstr_await_reserved = true }
				else if p.in_module_top_level || p.has_module_syntax { dstr_await_reserved = true }
			}
			if (p.cur_type == .Await || (p.cur_type == .Identifier && cur_has_escape(p) && cur_value_eq(p, "await"))) &&
			   dstr_await_reserved {
				report_error_coded(p, .K3010_AwaitYieldAsBindingName, "'await' is reserved as a binding name in this context")
			}
			if (p.cur_type == .Yield || (p.cur_type == .Identifier && cur_has_escape(p) && cur_value_eq(p, "yield"))) &&
			   yield_is_reserved_here(p) {
				report_error_coded(p, .K3010_AwaitYieldAsBindingName, "'yield' is reserved as a binding name in this context")
			}
			// Strict-mode reserved words as array-pattern element binding.
			if p.ctx.strict_mode && !(allow_ts_mode(p) && (p.ctx.in_ambient || p.source_is_dts)) {
				if is_strict_reserved_binding_name(cur_value(p)) {
					msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", cur_value(p))
					report_error_coded(p, .K3050_StrictModeReserved, msg)
				}
			}
			eil := cur_loc(p); ein := cur_value(p)
			eat(p)
			ident := new_node(p, Identifier)
			ident.loc = eil
			ident.name = ein

			// Check for default value: [x = defaultValue]
			// Restore no_in=false inside the default expression so that
			// `for (let [x = 'a' in {}] in ...)` parses the `in` as
			// a binary operator in the default, not the for-in separator.
			if match_token(p, .Assign) {
				prev_no_in := p.ctx.no_in; p.ctx.no_in = false
				default_val := parse_assignment_expression(p)
				p.ctx.no_in = prev_no_in
				assign := new_node(p, AssignmentPattern)
				assign.loc = eil
				assign.left = ident
				assign.right = default_val
				assign.loc.end = prev_end_offset(p)
				bump_append(&elements, Maybe(Pattern)(assign))
			} else {
				bump_append(&elements, Maybe(Pattern)(ident))
			}
		} else if is_token(p, .LBrace) {
			// Nested object pattern, possibly with an Initializer:
			//   BindingElement : BindingPattern Initializer_opt  (§14.3.3)
			// Mirrors parse_object_pattern's nested-LBrace branch so
			// `[{x} = {x: 1}]` wraps in AssignmentPattern just like the
			// object-shorthand case does for `{a: {x} = {x: 1}}`.
			nested := parse_object_pattern(p)
			if nested == nil {
				return nil
			}
			val: Pattern = nested
			if match_token(p, .Assign) {
				prev_no_in := p.ctx.no_in; p.ctx.no_in = false
				default_val := parse_assignment_expression(p)
				p.ctx.no_in = prev_no_in
				assign := new_node(p, AssignmentPattern)
				assign.loc = get_pattern_loc(nested)
				assign.left = nested
				assign.right = default_val
				assign.loc.end = prev_end_offset(p)
				val = assign
			}
			bump_append(&elements, Maybe(Pattern)(val))
		} else if is_token(p, .LBracket) {
			// Nested array pattern, possibly with an Initializer.
			// Same spec rule as the LBrace branch above - closes the
			// Test262 language/statements/class/dstr/* cases where
			// `[[x, y, z] = [4, 5, 6]]` appears in a method parameter
			// list.
			nested := parse_array_pattern(p)
			if nested == nil {
				return nil
			}
			val: Pattern = nested
			if match_token(p, .Assign) {
				prev_no_in := p.ctx.no_in; p.ctx.no_in = false
				default_val := parse_assignment_expression(p)
				p.ctx.no_in = prev_no_in
				assign := new_node(p, AssignmentPattern)
				assign.loc = get_pattern_loc(nested)
				assign.left = nested
				assign.right = default_val
				assign.loc.end = prev_end_offset(p)
				val = assign
			}
			bump_append(&elements, Maybe(Pattern)(val))
		} else {
			report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected pattern in array pattern")
			return nil
		}

		if !match_token(p, .Comma) {
			break
		}
	}

	if !expect_token(p, .RBracket) {
		return nil
	}

	arr.elements = elements[:]
	arr.loc.end = prev_end_offset(p)
	return arr
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
