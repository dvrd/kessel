package main

import "core:mem"
import "core:fmt"
import "core:strings"

// ============================================================================
// Token Access (cached in Parser for zero-overhead reads)
// ============================================================================

// Advance lexer: shift nxt → cur, lex new nxt. Writes minimal Token fields.
advance_token :: #force_inline proc(p: ^Parser) {
	if p.lexer != nil {
		a := p.lexer
		// Remember the end of the token we're about to consume. `a.cur` is the
		// current token BEFORE this advance - after the swap it will be gone.
		// `prev_token_end` lets `prev_end_offset` return the end of the last
		// consumed meaningful token (excluding trailing whitespace/comments),
		// which matches OXC/Acorn/Babel span semantics.
		p.prev_token_end = a.cur.end
		a.cur = a.nxt
		// Snapshot the literal slot that was written when a.nxt (now a.cur)
		// was lexed on the previous advance. The upcoming lex_token for the
		// NEW a.nxt will overwrite last_lit_* - we must capture it first or
		// we'll lose the cooked value and fall back to raw source for cur
		// (broke any string-with-escape followed by another cooking literal,
		// e.g. a string inside template `${...}`).
		//
		// `last_lit_*` is only ever written by the lexer for tokens that
		// carry a cooked value: numbers, strings, big ints, regex, the
		// template family, and escape-bearing identifiers (plain plus
		// PrivateIdentifier). For everything else - operators, punct,
		// keywords, plain identifiers - last_lit_* still holds whatever the
		// last literal-bearing lex run left there. Reading is safe because
		// every consumer below validates with `cur_lit_offset == ft.start`,
		// but the WRITES are pure waste for the ~80 %% of real-world tokens
		// that aren't literal-bearing. Gating saves three writes
		// (offset 4 B + value union ~24 B + type 1 B → padded to ~32 B) on
		// every non-literal advance - hundreds of thousands of skipped
		// stores per parse on monaco-class files.
		cur_kind := a.cur.kind
		cur_flags := a.cur.flags
		needs_lit_snapshot := cur_kind <= .TemplateTail ||
			((cur_flags & FLAG_HAS_ESCAPE) != 0 &&
			 (cur_kind == .Identifier || cur_kind == .PrivateIdentifier))
		if needs_lit_snapshot {
			a.cur_lit_offset = a.last_lit_offset
			a.cur_lit_value  = a.last_lit_value
			a.cur_lit_type   = a.last_lit_type
		}
		if cur_kind != .EOF {
			a.nxt = lex_token(a)
		} else {
			a.nxt = token_eof(u32(a.offset))
		}
		ft := a.cur
		p.cur_type = ft.kind
		p.cur_tok.type = ft.kind
		p.cur_tok.loc = LexerLoc(ft.start)
		p.cur_tok.raw_end = ft.end
		// Branchless: always write (avoids conditional branch per token)
		p.cur_tok.had_line_terminator = (ft.flags & FLAG_NEW_LINE) != 0
		p.cur_tok.has_escape = (ft.flags & FLAG_HAS_ESCAPE) != 0
		if ft.kind < .LBrace {
			p.cur_tok.value = a.source[ft.start:ft.end]
			if ft.kind == .String {
				if a.cur_lit_offset == ft.start && a.cur_lit_type == .String {
					p.cur_tok.literal = a.cur_lit_value
				} else if ft.end - ft.start >= 2 {
					p.cur_tok.literal = LiteralValue(a.source[ft.start+1:ft.end-1])
				} else {
					p.cur_tok.literal = LiteralValue(string(""))
				}
			} else if ft.kind <= .TemplateTail {
				if a.cur_lit_offset == ft.start && a.cur_lit_type != .None {
					p.cur_tok.literal = a.cur_lit_value
				}
			} else if ft.kind == .Identifier && (ft.flags & FLAG_HAS_ESCAPE) != 0 {
				// Escaped identifier - override the raw span with the cooked
				// (decoded) name published by lex_identifier_escaped. The raw
				// span is still the source text including \uXXXX; only the .value
				// used for AST emission changes. raw_end (set above) preserves
				// the true source end so loc_from_token still produces the
				// correct span. Mirrored in prime_token_cache and cur_value.
				if a.cur_lit_offset == ft.start && a.cur_lit_type == .Identifier {
					if s, ok := a.cur_lit_value.(string); ok {
						p.cur_tok.value = s
					}
				}
			} else if ft.kind == .PrivateIdentifier && (ft.flags & FLAG_HAS_ESCAPE) != 0 {
				// Escaped private identifier - same cooked-name swap as above.
				// lex_private_identifier_escaped publishes the cooked body WITH
				// the leading '#' so downstream parser code (which strips '#')
				// keeps working unchanged.
				if a.cur_lit_offset == ft.start && a.cur_lit_type == .Identifier {
					if s, ok := a.cur_lit_value.(string); ok {
						p.cur_tok.value = s
					}
				}
			}
		}
	}
}

// Peek at the NEXT token (1-ahead). Not cached.
peek_token :: #force_inline proc(p: ^Parser) -> Token {
	if p.lexer != nil {
		// Read directly from nxt
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

// Prime the parser's token cache. init_lexer has already captured the
// literal slot for cur (into cur_lit_*) before lexing nxt overwrote
// last_lit_*, so the lookup here mirrors advance_token's path.
prime_token_cache :: proc(p: ^Parser) {
	if p.lexer != nil {
		ft := p.lexer.cur
		p.cur_type = ft.kind
		p.cur_tok.type = ft.kind
		p.cur_tok.loc = LexerLoc(ft.start)
		p.cur_tok.raw_end = ft.end
		p.cur_tok.had_line_terminator = (ft.flags & FLAG_NEW_LINE) != 0
		p.cur_tok.has_escape = (ft.flags & FLAG_HAS_ESCAPE) != 0
		if ft.kind < .LBrace && ft.kind != .EOF && ft.start < ft.end {
			a := p.lexer
			p.cur_tok.value = a.source[ft.start:ft.end]
			if ft.kind == .String {
				if a.cur_lit_offset == ft.start && a.cur_lit_type == .String {
					p.cur_tok.literal = a.cur_lit_value
				} else if ft.end - ft.start >= 2 {
					p.cur_tok.literal = LiteralValue(a.source[ft.start+1:ft.end-1])
				}
			} else if ft.kind <= .TemplateTail {
				if a.cur_lit_offset == ft.start && a.cur_lit_type != .None {
					p.cur_tok.literal = a.cur_lit_value
				}
			} else if ft.kind == .Identifier && (ft.flags & FLAG_HAS_ESCAPE) != 0 {
				if a.cur_lit_offset == ft.start && a.cur_lit_type == .Identifier {
					if s, ok := a.cur_lit_value.(string); ok {
						p.cur_tok.value = s
					}
				}
			} else if ft.kind == .PrivateIdentifier && (ft.flags & FLAG_HAS_ESCAPE) != 0 {
				// Escaped private identifier - see advance_token for the
				// matching case and rationale (cooked name includes '#').
				if a.cur_lit_offset == ft.start && a.cur_lit_type == .Identifier {
					if s, ok := a.cur_lit_value.(string); ok {
						p.cur_tok.value = s
					}
				}
			}
		}
	} else {
		p.cur_type = .EOF
	}
}

peek_dispatch :: #force_inline proc(p: ^Parser) -> Token {
	return peek_token(p)
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
	// align up
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
//
// Odin's runtime `_append_elem` is `#force_no_inline` and takes
// `size_of_elem: int` as a runtime parameter. That means the
// `mem_copy_non_overlapping(data, arg_ptr, size_of_elem)` call inside it
// can't be specialised by LLVM - it falls through to a system `memmove`
// call even when copying a single 8-byte pointer. Profile evidence on
// monaco.js: 86 % of `_append_elem` samples are inside `_platform_memmove`,
// for elements that are typically 8-16 B.
//
// `bump_append` is a generic, `#force_inline` replacement that lets the
// compiler specialise the element copy per type T. For T = ^Statement
// (8 B), the inner store collapses to a single STR instruction; for T =
// FunctionParameter (~80 B), the store becomes a small fixed memcpy that
// LLVM can also inline when size is statically known.
//
// The grow path delegates to the standard `append()` so we don't have to
// reimplement realloc/copy logic. That's the slow path; the common case
// (cap headroom available) is the fully-inlined fast path.
//
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

// NOTE — the `ScopePending` struct + queue were deleted in slice 14
// when the parser-driven scope-clash pass moved into the semantic
// checker. The checker now finds scope-bearing bodies via its own
// recursive AST walk (no queue), invoking the parser's
// `scope_check_body` at each entry point. See checker.odin's
// `ck_run_scope_check` for the replacement.

// Parser represents the recursive descent parser
Parser :: struct {
	// Lexer reference (per-parser, thread-safe for parallel parsing)
	lexer: ^Lexer,

	// Cached current token - updated ONLY by advance_token()
	cur_tok:  Token,
	cur_type: TokenType,

	// End offset of the LAST consumed token. Used by `prev_end_offset` to
	// produce ESTree-correct span.end values that don't include trailing
	// whitespace or comments (which `cur_offset` would include because it
	// returns the start of the NEXT token). Updated at the top of
	// `advance_token` before the cur/nxt swap.
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

	// Error handling
	errors: [dynamic]ParseError,

	// String interner for identifiers
	interner: ^StringInterner,

	// Context flags
	in_function:     bool,
	// True when the lexical enclosing scope contains a non-arrow function
	// (FunctionDeclaration / FunctionExpression / Method / Generator /
	// AsyncFunction / class constructor). Arrow functions inherit
	// `[[NewTarget]]` from their enclosing scope rather than introducing
	// their own, so `new.target` inside `() => { new.target }` at script
	// top-level must still be a SyntaxError. Regular function entry
	// points save+set this flag; arrow entry points leave it untouched.
	in_non_arrow_function: bool,
	in_generator:    bool,
	in_async:        bool,
	in_loop:         bool,
	in_switch:       bool,
	strict_mode:     bool,

	// True when parsing a ClassStaticBlockBody (§15.7.5). Disables
	// `return`, `await`, `yield`, and `arguments` (the spec parameters
	// `[~Yield, +Await, ~Return]` plus an explicit `Contains await /
	// arguments / SuperCall` early error).
	in_static_block: bool,

	// True when parsing inside a TS namespace/module body. `await` is
	// not a keyword here even in module-mode files.
	in_ts_namespace: bool,

	// True when parsing a Statement directly inside a CaseClause /
	// DefaultClause StatementList. §Explicit Resource Management
	// forbids `using` / `await using` declarations in this position.
	in_case_clause: bool,

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
	label_floor: int,

	// Inside a [[HomeObject]]-bearing context - class method (instance,
	// static, getter, setter, constructor), class field initializer, class
	// static block, or object-literal method / accessor. `super.foo` and
	// `super[x]` are SyntaxErrors outside one of these. `super(...)` has a
	// further restriction (constructor of a derived class) - tracked by
	// `in_derived_constructor` so the bare `super` check here stays cheap.
	//
	// Nested arrow functions inherit `in_method` (lexical super); nested
	// regular FunctionExpression / FunctionDeclaration bodies reset it
	// (they introduce their own - absent - HomeObject).
	in_method:       bool,

	// Inside the FormalParameters of a GeneratorFunction /
	// GeneratorMethod / async generator. ECMA-262 §15.5.1 / §15.6.1 - "It
	// is a Syntax Error if FormalParameters Contains YieldExpression is
	// true." Set before parse_function_params and cleared after; the
	// yield-expression constructor consults it so we don't need a
	// post-parse AST walker.
	in_generator_params: bool,

	// Inside the FormalParameters of any async function-like form -
	// AsyncArrowFunction (§15.9.1: "It is a Syntax Error if
	// CoverCallExpressionAndAsyncArrowHead Contains AwaitExpression is
	// true."), AsyncFunctionDeclaration / AsyncFunctionExpression
	// (§15.8.1), AsyncMethod, AsyncGeneratorDeclaration /
	// AsyncGeneratorMethod (§15.6.1). The await-expression constructor
	// consults this flag so we don't need a post-parse AST walker.
	in_async_params: bool,

	// Inside the constructor of a class with an `extends` clause.
	// `super(...)` (SuperCall) is a SyntaxError outside such a
	// constructor (ECMA-262 §15.7.3 / §13.3.7). Arrow functions inherit
	// this (lexical super-call); every non-arrow function body resets it,
	// as do object-literal methods / getters / setters / static blocks /
	// field initializers and non-constructor class methods.
	in_derived_constructor: bool,

	// Set by parse_class_declaration / parse_class_expression before
	// recursing into parse_class_body, so parse_class_element can decide
	// whether the (instance, non-static) constructor body should enable
	// `in_derived_constructor`. Saved / restored across nested class
	// declarations so inner classes don't leak their extends state.
	class_has_extends: bool,

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

	// Depth counter for TS object/interface type literal bodies. When > 0,
	// type-argument `<T>` on a newline is NOT consumed as postfix (it starts
	// a new generic call/construct signature member).
	ts_in_type_literal: int,

	// True while parsing elements of a TS tuple type `[T?, U, ...V]`.
	// Suppresses the JSDoc-nullable `?` consumption in parse_ts_postfix
	// so that postfix `?` is reserved for TSOptionalType instead.
	ts_in_tuple_type: bool,

	// Disallow 'in' as binary operator (for for-loop init parsing)
	no_in:           bool,
	// True while parsing the RHS of an `in` operator. Used to reject
	// `#x in #y` (Test262: language/expressions/in/private-field-in-
	// nested.js): a PrivateIdentifier appearing in the RHS of `in`
	// is not a valid ShiftExpression. Reset on parens so `a in (#x in y)`
	// stays legal.
	in_in_rhs:       bool,

	// True when the current expression precedence can still consume `in`.
	// `#x` is only a valid primary expression as the left operand of that
	// `in`; in `1 + #x in obj`, the additive RHS is parsed above relational
	// precedence, so the following `in` belongs outside and `#x` is invalid.
	private_in_allowed: bool,

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

	// CLI `--preserve-parens`. When true, every genuine `(expr)` paren-
	// grouping wraps its inner expression in a ParenthesizedExpression
	// node. Off by default for byte-identical legacy output. Does NOT
	// wrap arrow-param covers (`(x, y) =>`), call / new argument lists,
	// or control-flow headers - only the expression-position case.
	preserve_parens:   bool,

	// When false (default), the parser skips validation-only early-error
	// checks (break/continue context, label scoping, super/new.target
	// context, duplicate bindings, strict-mode parameter checks, etc.).
	// These checks are deferred to the semantic checker pass. When true,
	// the parser enforces them inline - matching the pre-refactor
	// behaviour for backwards compatibility and standalone CLI use.
	check_semantics:   bool,

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

	// True while expr_to_pattern recurses into nested array/object elements.
	// Parenthesized binding elements (`(a)`) are rejected inside destructuring
	// patterns but allowed at the top level of arrow params (matching OXC
	// preserveParens=false semantics). Set before recursing into
	// ArrayExpression / ObjectExpression element conversions.
	in_nested_pattern_convert: bool,


	// Inside an ambient TS module / namespace body: every declaration is
	// implicitly `declare`-modified. Matches `declare module "x" { ... }`
	// semantics and also the string-named `module "x" { ... }` shortcut
	// (always ambient, no explicit declare needed). Propagates through
	// nested modules. Saved/restored around the body scan.
	in_ambient:      bool,

	// True for `.d.ts` declaration files. They parse as TS, but ambient
	// declaration-file relaxations (for example `const x;`) must not leak
	// into normal `.ts` / `.tsx` source.
	source_is_dts:   bool,

	// Track if module syntax was detected (import/export or import.meta)
	has_module_syntax: bool,

	// Lazy module-syntax pre-scan cache. The pre-scan inspects the
	// source for top-level import/export and is only needed in the rare
	// case where a parsing decision depends on whether the file is a
	// module BEFORE the parser has reached the import/export token.
	// True examples: top-level `await` / `for await` / `using` / `await
	// using` in auto-detect JS files. The lexer's keyword tokenisation
	// does NOT need this (it always emits .Await regardless).
	//
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

	// NOTE — in slice 14 the `scope_pending` queue, the
	// `pending_checker: ^Checker` bridge field, and the `scope_skip`
	// flag were all deleted from the Parser. The semantic checker now
	// drives the scope-clash pass directly: it walks the AST, calls
	// the parser's scope_check_body / scope_process_statement / scope_add
	// at each scope-bearing entry, and tracks the array/object-literal
	// scope-skipping context on its own CheckerContext.scope_skip
	// field. The parser stays free of any reference to the checker
	// (the scope_* helpers take ^Checker explicitly).
	//
	// CORRECTNESS NOTE preserved verbatim from the original
	// scope_skip comment: the parser's nested-arrow-in-array-literal
	// duplicate-let detection gap (intentional, matches pre-
	// session-21 shipped behaviour and OXC) is preserved by the
	// checker's scope_skip context flag.

	// `ast_only` switches off all scope tracking, duplicate-binding
	// detection, exported-name dedup, strict-reserved-name string checks,
	// and the post-parse `verify_scopes` walk. The parser still produces
	// a complete ESTree-compatible AST and reports syntactic errors
	// (mismatched braces, invalid expressions, etc.) but skips the
	// semantic / scope-level checks that OXC's parser also defers to its
	// `oxc_semantic` pass.
	//
	// Used by the `microbench parse --ast-only` benchmark mode to compare
	// against OXC's `Parser::new().parse()` (which does the same deferral)
	// on equal terms. Test262 / TS / JSX / negative gates leave it OFF
	// so all conformance work runs as today; this flag is bench-only.
	ast_only: bool,

	// Optional instrumentation for parser profiling
	profile_enabled: bool,
	profile:         ParserProfile,
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

// Parse error structure
ParseError :: struct {
	loc:     LexerLoc,
	message: string,
}

// String interner for identifier deduplication (lazy init)
StringInterner :: struct {
	allocator:    mem.Allocator,
	entries:      map[string]string,
	capacity_hint: int,
	initialized:  bool,
}

// Parse result

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

// Maximum iterations for error recovery to prevent infinite loops
MAX_ERROR_RECOVERY_ITERATIONS :: 10000

// Initialize string interner - map allocated lazily on first intern() call
init_interner :: proc(i: ^StringInterner, alloc: mem.Allocator, capacity_hint: int = 0) {
	i.allocator = alloc
	i.capacity_hint = capacity_hint
	// Map NOT allocated here - deferred to first intern() call
}

// Intern a string (lazy map init on first call)
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

	// Copy string with allocator
	bytes, _ := mem.alloc_bytes(len(s), allocator=i.allocator)
	copy(bytes, s)
	interned := string(bytes)
	i.entries[interned] = interned
	return interned
}



// Initialize parser with lexer
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
	p.errors = make([dynamic]ParseError, alloc)
	p.pending_cover_inits = make([dynamic]u32, 0, 4, alloc)
	// Heuristic: ~1 scope-bearing node per ~512 bytes of source on average
	// real-world JS (functions / arrows / blocks). Pre-size so the typical
	// big bundle (typescript.js ~9 MB) doesn't realloc more than 1-2 times.
	scope_cap := 16
	if p.source_len > 4096 {
		scope_cap = p.source_len / 512
	}
	// scope_pending queue removed in slice 14; the checker walks the AST
	// directly to find scope-bearing bodies.
	_ = scope_cap

	// Bump pool: scale with source size.
	//
	// Non-minified production JS emits ~25-30 bytes of AST per byte of
	// source once dynamic-array headers, Expression / Statement wrappers,
	// and per-Property / FunctionParameter records are counted. The
	// previous formula (20× source with a 256 KB threshold) sized tiny-
	// to-medium files exactly at 20×, which overflowed bench/real_world/
	// batch2/preact.js (11 KB source needed 225 K pool, formula gave 225 K
	// → 1924 fallbacks to the backing allocator). Three bands:
	//
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

	p.in_function = false
	p.in_generator = false
	p.in_async = false
	p.in_loop = false
	p.in_switch = false
	// strict_mode starts sloppy; parse_program promotes it via the
	// directive-prologue pass or when p.force_strict is set.
	p.strict_mode = false
	p.in_method = false
	p.in_generator_params = false
	p.in_async_params = false
	p.in_derived_constructor = false
	p.class_has_extends = false
	p.label_stack = make([dynamic]string, 0, 4, alloc)
	p.label_is_iteration = make([dynamic]bool, 0, 4, alloc)
	p.label_floor = 0
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
	// Propagate semantic-checking mode to the lexer so that regex-body
	// validation (a semantic concern) can be skipped in permissive mode.
	lexer.check_semantics = p.check_semantics

	// Prime token cache
	prime_token_cache(p)
}

// NOTE — `mark_last_scope_function_scope` was deleted in slice 14.
// Block-vs-function-scope is now decided by the checker's recursive
// walker at each entry point (ArrowFunctionExpression block bodies
// and class StaticBlock bodies are function-scope; ordinary
// BlockStatement bodies are block-scope) without needing a
// post-hoc re-stamp.

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
//
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
		     ^BlockStatement:
			return true
		}
	}
	return false
}

// Create a new node allocated from bump pool (zero-dispatch)
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
	// Fallback to arena allocator
	result, _ := mem.new(T, p.allocator)
	return result
}

// Helper to convert any statement node to ^Statement union
// Uses transmute with proper type handling
statement_from :: proc(p: ^Parser, stmt_ptr: ^$T) -> ^Statement {
	if stmt_ptr == nil {
		return nil
	}
	// Allocate a Statement from the arena and assign the concrete pointer
	result := new_node(p, Statement)
	result^ = stmt_ptr
	return result
}

// Helper to convert any expression node to ^Expression union
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
//
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

// Fast path for hot expression types - avoids allocation by using transmute
// Only safe when T is exactly one of the types in the Expression union

// Report an error
//
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
//
// Idempotent: the first call runs the SIMD pre-scan; subsequent calls
// hit the module_pre_scan_done cache and return immediately.
//
// Skips the scan when the answer is already known:
//   * --source-type forced — the answer doesn't depend on source.
//   * has_module_syntax already true — a parser-side write (parsing
//     an import/export token) beat us to it.
//   * TS / TSX file — the TS-mode path doesn't currently consult the
//     pre-scan; .d.ts files always allow await as identifier anyway.
//   * No lexer attached (defensive; happens only in the test harness).
//
// Cost on bench/real_world/typescript.js (9 MB CJS bundle): zero.
// The bench files don't use top-level await / for-await / using, so
// none of the lazy entry points fire.
@(private="file")
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
//
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
//
// Runs in O(n) time with no allocation. On bench/real_world/typescript.js
// (9 MB CJS bundle, no top-level module syntax — worst case for the
// pre-scan) this is ~3× faster than the byte-by-byte scalar version that
// shipped in f0c1201. Together with the unchanged main parse, the file
// returns from kessel’s `< OXC` regime measured in s25 (geo-mean ~0.93×).
@(private="file")
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
				pos, found_quote := simd_find_string_end(src[i:], quote)
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
				pos, found_bt := simd_find_string_end(src[i:], '`')
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
@(private="file")
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
	third_lt := p.cur_tok.had_line_terminator
	lexer_restore(p, snap)
	// A LineTerminator between `using` and the binding breaks the
	// restricted production.
	if third_lt { return false }
	// The token must be a BindingIdentifier - an Identifier or a
	// contextual keyword that can serve as one.
	return third_type == .Identifier || can_be_binding_identifier(third_type)
}

report_error :: proc(p: ^Parser, message: string) {
	err := ParseError{
		loc     = LexerLoc(cur_offset(p)),
		message = message,
	}
	bump_append(&p.errors, err)
	if p.profile_enabled {
		p.profile.errors_reported += 1
	}
}

// report_error_at is like report_error but at an explicit source offset.
report_error_at :: #force_inline proc(p: ^Parser, loc: LexerLoc, message: string) {
	bump_append(&p.errors, ParseError{loc = loc, message = message})
}

// NOTE — the parser-side `report_semantic_error` and
// `report_semantic_error_at` helpers were removed in slice 13e once
// the migration of every inline call to src/checker.odin completed.
// All early-error reporting now flows through ck_report (file-private
// to checker.odin) or `checker_append_error` (the package-level entry
// point used by the parser's verify_scopes machinery via
// p.pending_checker). The architectural rule — parser = syntax,
// checker = semantic — is now structurally enforced rather than
// convention-only.

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

// Get bump pool usage stats
get_bump_stats :: proc(p: ^Parser) -> (used: int, capacity: int, overflow_count: int) {
	if p == nil { return 0, 0, 0 }
	return p.node_pool.offset, p.node_pool.capacity, p.node_pool.overflow_count
}

// Expect a specific token type
expect_token :: #force_inline proc(p: ^Parser, t: TokenType) -> bool {
	if p.cur_type != t {
		msg := fmt.tprintf("Expected %v, got %v", get_token_name(t), get_token_name(p.cur_type))
		report_error(p, msg)
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

// Check if current token matches type - zero cost, just a field read
is_token :: #force_inline proc(p: ^Parser, t: TokenType) -> bool {
	return p.cur_type == t
}

// Check if next token matches type - reads from nxt (no indirection)
is_next_token :: #force_inline proc(p: ^Parser, t: TokenType) -> bool {
	if p.lexer != nil {
		return p.lexer.nxt.kind == t
	}
	return peek_token(p).type == t
}

// Check if next token is an Identifier with a specific string value.
// Used for TS contextual keywords (type, interface, enum) that lex as Identifier.
is_next_identifier_value :: #force_inline proc(p: ^Parser, value: string) -> bool {
	if p.lexer == nil { return false }
	nxt := p.lexer.nxt
	if nxt.kind != .Identifier { return false }
	if nxt.end - nxt.start != u32(len(value)) { return false }
	return p.lexer.source[nxt.start:nxt.end] == value
}

// Consume current token if it matches
match_token :: #force_inline proc(p: ^Parser, t: TokenType) -> bool {
	if p.cur_type == t {
		skip_token(p)
		return true
	}
	return false
}

// Consume current token (return value rarely used - prefer skip_token path)
eat :: #force_inline proc(p: ^Parser) {
	advance_token(p)
}

// Get current token - just return cached
get_current :: #force_inline proc(p: ^Parser) -> Token {
	return p.cur_tok
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
	if p.cur_tok.had_line_terminator {
		return true
	}
	if p.cur_type == .RBrace || p.cur_type == .EOF {
		return true
	}
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
	report_error(p, "Expected semicolon")
	return false
}

// match_semicolon_or_asi_export - like match_semicolon_or_asi but with
// permissive ASI for export/import declarations. These are statements, not
// expressions - `[` or `(` on the next line can't be a continuation.
// Treats any line terminator as ASI, regardless of the next token.
match_semicolon_or_asi_export :: #force_inline proc(p: ^Parser) -> bool {
	if p.cur_type == .Semi { advance_token(p); return true }
	if p.cur_tok.had_line_terminator { return true }
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
		report_error(p, "Unexpected 'else' without matching 'if'")
		eat(p)
		if !is_token(p, .EOF) { _ = parse_statement_or_declaration(p) }
		return
	case .RBrace:
		report_error(p, "Unexpected '}' \u2014 unmatched closing brace")
		eat(p)
		return
	case .Catch, .Finally:
		report_error(p, "Unexpected 'catch' or 'finally' without matching 'try'")
		eat(p)
		if !is_token(p, .EOF) { _ = parse_statement_or_declaration(p) }
		return
	}

	stmt := parse_statement_or_declaration(p)
	if stmt != nil {
		append(body, stmt)
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
				already_reported := len(p.errors) > 0 &&
					p.errors[len(p.errors)-1].loc == LexerLoc(cur_offset(p))
				// Closing tokens (`)`, `]`) can appear as orphans during error
				// recovery without being syntax errors in themselves. Only
				// report for tokens that genuinely cannot appear at statement
				// position and are not matching-closer artifacts.
				is_closer_orphan := p.cur_type == .RParen || p.cur_type == .RBracket
				if !already_reported && !is_closer_orphan {
					msg := fmt.tprintf("Unexpected token '%s'", cur_value(p))
					report_error(p, msg)
				}
			}
			stuck_count += 1
			if stuck_count > 100 {
				// Emergency: force consume and break
				eat(p)
				break
			}
			// Try to skip to a safe token
			if is_token(p, .Semi) || is_token(p, .RBrace) {
				eat(p)
				break
			}
			eat(p)
		}
		return
	}

	// Error recovery: consume token to avoid infinite loop
	if !is_token(p, .EOF) {
		eat(p)
	}
}

parse_program :: proc(p: ^Parser, source_type: SourceType) -> ^Program {
	program := new_node(p, Program)
	// Program span always starts at byte 0 (even if the source begins with a
	// shebang, comments, or whitespace) to match ESTree/OXC/Acorn semantics.
	// `cur_loc` would return the start of the FIRST token, which skips over
	// leading comments and shebang lines.
	program.loc = Loc{span = Span{start = 0, end = 0}}
	program.type = source_type

	// --force-strict (CLI) opts into strict mode regardless of the body's
	// directive prologue. Set here (not in init_parser) because main.odin
	// flips p.force_strict AFTER init_parser has already zeroed
	// p.strict_mode. Used by the Test262 runner for `flags: [onlyStrict]`
	// fixtures.
	if p.force_strict {
		p.strict_mode = true
	}

	// §16.2.1 - Module code is always strict mode (§16.2.2).
	if fs, have := p.force_source_type.(SourceType); have && fs == .Module {
		p.strict_mode = true
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
			// Check for "use strict" directive
			current := get_current(p)
			if current.literal == "use strict" {
				p.strict_mode = true
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
				str_lit := new_node(p, StringLiteral)
				str_lit.loc = loc_from_token(&current)
				str_lit.value = current.literal.(string) or_else ""
				str_lit.raw = current.value
				expr_stmt, expr_stmt_s := new_stmt(p, ExpressionStatement)
				expr_stmt.loc = directive.loc
				expr_stmt.expression = expression_from(p, str_lit)
				expr_stmt.directive = "use strict"
				bump_append(&program.body, expr_stmt_s)
				eat(p)
				match_semicolon_or_asi(p)
				expr_stmt.loc.span.end = prev_end_offset(p)
			} else {
				parse_program_item(p, &program.body, loop_start_offset)
			}
		} else {
			parse_program_item(p, &program.body, loop_start_offset)
		}

		if int(cur_offset(p)) == loop_start_offset {
			no_progress_count += 1
			if no_progress_count > MAX_ERROR_RECOVERY_ITERATIONS {
				report_error(p, "Maximum parsing iterations exceeded - possible infinite loop")
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
	program.loc.span.end = u32(p.source_len)

	// OXC-TS quirk: in .ts / .tsx mode OXC sets program.start = body[0].start
	// (skipping leading comments/whitespace), while still ending at source.length.
	// Mirror that behaviour here so the deep-compare against OXC matches; no
	// effect on .js / .jsx where program.start stays 0.
	if (p.lang == .TS || p.lang == .TSX) && len(program.body) > 0 {
		first_loc := get_statement_loc(program.body[0])
		if first_loc.span.start != 0 || first_loc.span.end != 0 {
			program.loc.span.start = first_loc.span.start
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
				     ^ExportDefaultDeclaration, ^ExportAllDeclaration:
					program.type = .Module
					break
				}
				if program.type == .Module { break }
			}
		}
	}

	// §16.2.2 ExportedBindings resolution: `export { foo };` (no `from`)
	// must refer to a binding actually declared in the module. This runs
	// after source-type is finalized so we skip the check for scripts
	// (they're already diagnosed by the module-syntax-in-script gate).
	//
	// `ast_only` skips this and the duplicate-binding pass below to match
	// what OXC's parser does (it defers all of these to oxc_semantic).
	if !p.ast_only {
		verify_export_locals(p, program)

		// §14.2.1 / §14.3.1.1 — the lex/var duplicate-binding scan now
		// fires from the semantic checker (checker_run_for_job sets
		// p.pending_checker before invoking verify_scopes, then clears
		// it on exit). The parser itself still BUILDS the scope_pending
		// queue at parse time so the checker doesn't have to recreate
		// the scope tree from the AST; only the diagnostic-emission step
		// is deferred. This matches OXC: oxc_parser builds scopes,
		// oxc_semantic runs the early-error checks.
	}

	// §13.2.5.1 CoverInitializedName: any ObjectExpression that parsed
	// with a `{ ident = init }` shorthand but didn't get promoted to
	// an ObjectPattern (via expr_to_pattern) is a SyntaxError. Reported
	// after all expr_to_pattern calls have had a chance to clear their
	// entries from p.pending_cover_inits.
	for off in p.pending_cover_inits {
		bump_append(&p.errors, ParseError{
			loc     = LexerLoc(off),
			message = "Invalid shorthand property initializer",
		})
	}
	// §13.2.5.1 duplicate __proto__ in object literal: migrated to
	// the semantic checker (slice 4) — ck_check_object_proto_dups walks
	// every ObjectExpression. The previous pending-list machinery is
	// no longer needed because the AST already distinguishes
	// ObjectExpression from ObjectPattern post-parse.

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
			err := ParseError{
				loc     = LexerLoc(lex_err.offset),
				message = lex_err.message,
			}
			bump_append(&p.errors, err)
		}
	}

	return program
}

// ============================================================================
// Statements
// ============================================================================

parse_statement_or_declaration :: proc(p: ^Parser) -> ^Statement {
	// At statement start, `/` must be regex (not division) - re-lex if needed
	if p.cur_type == .Div || p.cur_type == .AssignDiv {
		if p.lexer != nil {
			relex_as_regex(p.lexer)
			// Update parser's cached token from the re-lexed result
			ft := p.lexer.cur
			p.cur_type = ft.kind
			p.cur_tok.type = ft.kind
			p.cur_tok.loc = LexerLoc(ft.start)
			if ft.kind < .LBrace && ft.start < ft.end {
				p.cur_tok.value = p.lexer.source[ft.start:ft.end]
			}
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
		if p.cur_tok.has_escape {
			report_error(p, "'async' keyword must not contain Unicode escape sequences")
			return parse_expression_or_labeled_statement(p)
		}
		next_after_async := peek_dispatch(p)
		if next_after_async.type == .Function && !next_after_async.had_line_terminator {
			return parse_function_declaration(p)
		}
		return parse_expression_or_labeled_statement(p)
	case .Class:
		return parse_class_declaration(p)
	case .Abstract:
		// `abstract class Foo { ... }` - consume `abstract` and set the flag
		// on the parsed class declaration.
		if is_next_token(p, .Class) {
			eat(p) // consume `abstract`
			stmt := parse_class_declaration(p)
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
		nxt_let := peek_dispatch(p)
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
			is_let_asi := nxt_let.had_line_terminator && !p.strict_mode &&
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
		if p.strict_mode && !let_is_decl {
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
		if allow_ts_mode(p) && (nxt_let.type == .EOF || nxt_let.type == .Semi ||
		   nxt_let.type == .RBrace) {
			report_error(p, "'let' declaration requires a binding name")
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
		if p.cur_tok.has_escape && p.cur_tok.value == "async" {
			// Peek ahead: if this looks like an async function / arrow, error.
			nxt := peek_dispatch(p)
			if (nxt.type == .Function && !nxt.had_line_terminator) ||
			   (nxt.type == .Identifier && !nxt.had_line_terminator) ||
			   (nxt.type == .LParen && !nxt.had_line_terminator) {
				report_error(p, "'async' keyword must not contain Unicode escape sequences")
			}
		}
		// TS contextual keywords: `type`, `interface`, `enum`, `declare` lex as Identifier
		// so that `var type = 1` and similar JS code parses correctly.
		// We check string value here at the statement level.
		val := p.cur_tok.value
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
		report_error(p, "Unexpected closing token")
		eat(p)
		return nil
	case .RParen:
		report_error(p, "Unexpected closing token")
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
		// §16.2.1 ImportDeclaration not at module top level: enforced by
		// the semantic checker (ck_check_import_export_position) using its
		// own at_top_level tracker.
		return parse_import_declaration(p)
	case .Export:
		// §16.2.1 ExportDeclaration not at module top level: enforced by
		// the semantic checker (ck_check_import_export_position).
		return parse_export_declaration(p)
	case:
		return parse_expression_or_labeled_statement(p)
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
	prev_in_case_block := p.in_case_clause
	p.in_case_clause = false
	defer p.in_case_clause = prev_in_case_block
	// Track nesting depth for import/export position check.
	p.block_depth += 1
	defer p.block_depth -= 1
	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		prev_offset := int(cur_offset(p))
		stmt := parse_statement_or_declaration(p)
		if stmt != nil {
			bump_append(&block.body, stmt)
		} else if int(cur_offset(p)) == prev_offset {
			report_error(p, "Invalid statement in block")
			eat(p)
		}
	}

	if !match_token(p, .RBrace) {
		report_error(p, "Expected '}' at end of block")
	}

	block.loc.span.end = prev_end_offset(p)
	// Queue this block for post-parse scope verification. is_block_scope=true
	// is the genuine BlockStatement default (§14.2.1: an inner Block is its
	// own lexical scope, sloppy plain FunctionDecls follow Annex B.3.2). Two
	// callers re-stamp the just-pushed entry to is_block_scope=false:
	// parse_arrow_function (arrow block body is a function scope) and
	// parse_class_element's StaticBlock arm (a static block body is its own
	// function scope per §15.7.5). See those sites for the override.
	// Slice 14: the parser-side scope_pending push was removed. The
	// semantic checker walks ck_walk_stmt's BlockStatement case and
	// invokes scope_check_body for each block body in source order.
	return block_stmt
}

parse_empty_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p)

	empty := new_node(p, EmptyStatement)
	empty.loc = start
	empty.loc.span.end = prev_end_offset(p)
	return statement_from(p, empty)
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
	//
	// We also flag keywords that cannot start any expression at all
	// (`case`, `default`, `extends`, `in`, `instanceof`, etc.)
	// regardless of what follows.
	if is_keyword_not_expression_start(p.cur_type) {
		msg := fmt.tprintf("Unexpected reserved word '%s'", cur_value(p))
		report_error(p, msg)
	} else if is_keyword_with_operand(p.cur_type) && is_next_token(p, .Assign) {
		// `delete = 1`, `new = 1`, `typeof = 1`, `void = 1` - the
		// keyword is being used as an assignment target, not as the
		// prefix operator it normally is.
		msg := fmt.tprintf("Unexpected reserved word '%s'", cur_value(p))
		report_error(p, msg)
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
			report_error(p, "Unexpected token ':'")
		case ^NullLiteral:
			// `null:` - same rule.
			report_error(p, "Unexpected token ':'")
		case ^NumericLiteral:
			// `0:` - numeric literal cannot be a label.
			report_error(p, "Unexpected token ':'")
		case ^StringLiteral:
			// `"x":` - string literal cannot be a label.
			report_error(p, "Unexpected token ':'")
		case ^ThisExpression:
			// `this:` - keyword cannot be a label.
			report_error(p, "Unexpected token ':'")
		case ^RegExpLiteral:
			report_error(p, "Unexpected token ':'")
		case ^TemplateLiteral:
			report_error(p, "Unexpected token ':'")
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
			if p.in_generator {
				report_error(p, "'yield' cannot be used as a label identifier inside a generator function")
			} else {
				report_error(p, "Unexpected token ':'")
			}
		case ^Identifier:
			eat(p) // consume :

			labeled := new_node(p, LabeledStatement)
			labeled.loc = start
			labeled.label = LabelIdentifier{
				loc  = e.loc,
				name = e.name,
			}
			// §14.13.1 — duplicate-label check is enforced by the
			// semantic checker (ck_check_label_redeclared). Parser keeps
			// the label_stack so `continue label;` validation can
			// piggy-back on `label_chain_leads_to_iteration` below; the
			// duplicate-name check is dropped from here.
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
			labeled.loc.span.end = prev_end_offset(p)
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
							report_error(p, "Lexical declaration cannot appear in a single-statement context")
						} else if v.kind == .Let {
							report_error(p, "Lexical declaration cannot be a labeled item")
						}
					}
				case ^ClassDeclaration:
					report_error(p, "Class declaration cannot appear in a single-statement context")
				case ^FunctionDeclaration:
					if v != nil {
						if v.async || v.generator {
							report_error(p, "Async / generator function declaration cannot be a labeled item")
						}
						// §14.13.1 "plain function decl as labeled item in strict":
						// enforced by the semantic checker (ck_walk_stmt's
						// ^LabeledStatement case).
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
	//
	// ASI for `yield\n/regex/` and similar: when the expression statement
	// ends with a line terminator and the next token is `/` or `/=`, the
	// slash is meant to start a regex on a new line, not continue as
	// division. Re-lex so the next statement parses as a regex literal.
	if (p.cur_type == .Div || p.cur_type == .AssignDiv) && p.cur_tok.had_line_terminator {
		if p.lexer != nil {
			relex_as_regex(p.lexer)
			ft := p.lexer.cur
			p.cur_type = ft.kind
			p.cur_tok.type = ft.kind
			p.cur_tok.loc = LexerLoc(ft.start)
			p.cur_tok.raw_end = ft.end
			p.cur_tok.had_line_terminator = (ft.flags & FLAG_NEW_LINE) != 0
			if ft.kind == .RegularExpression {
				p.cur_tok.literal = p.lexer.cur_lit_value
			}
		}
	}
	expect_semicolon_or_asi(p)

	expr_stmt.loc.span.end = prev_end_offset(p)
	return stmt
}

parse_expression_or_labeled_statement :: proc(p: ^Parser) -> ^Statement {
	return parse_expression_statement(p)
}

// Enforce the §13.5 "StatementList accepts only Statement, not
// Declaration" rule for body positions in if / while / for / do-while.
// Per the grammar:
//
//   Statement does NOT include LexicalDeclaration, ClassDeclaration,
//   AsyncFunctionDeclaration, GeneratorDeclaration,
//   AsyncGeneratorDeclaration.
//
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
			msg := "Lexical declaration cannot appear in a single-statement context"
			report_error(p, msg)
		}
	case ^ClassDeclaration:
		report_error(p, "Class declaration cannot appear in a single-statement context")
	case ^FunctionDeclaration:
		if v == nil { return }
		if v.async || v.generator {
			report_error(p, "Async / generator function declaration cannot appear in a single-statement context")
		}
		// Plain FunctionDeclaration in a single-statement iteration /
		// with body is checked by the semantic checker
		// (ck_check_single_stmt_function), which honours Annex B.3.2's
		// sloppy IfStatement carve-out by simply not running on if /
		// labelled-statement-of-if positions.
		_ = allow_plain_function
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
		report_error(p, "Expected expression in `if` condition")
		eat(p) // consume `)` to keep the parser moving
		return nil
	}
	test := parse_expression(p)
	if test == nil {
		// If the condition expression failed to parse, report an error
		// rather than silently dropping the entire if-statement.
		if !is_token(p, .RParen) {
			report_error(p, "Expected expression in 'if' condition")
		}
		return nil
	}
	// Spread/rest is not valid in the if-condition expression.
	if expr_contains_spread(test) {
		report_error(p, "Unexpected spread/rest element in expression")
	}

	if !expect_token(p, .RParen) {
		return nil
	}

	p.block_depth += 1
	consequent := parse_statement_or_declaration(p)
	p.block_depth -= 1
	if consequent == nil {
		report_error(p, "Expected statement after 'if' condition")
	}
	report_statement_only_position(p, consequent, !p.strict_mode)

	if_ := new_node(p, IfStatement)
	if_.loc = start
	if_.test = test
	if_.consequent = consequent

	if match_token(p, .Else) {
		p.block_depth += 1
		alt := parse_statement_or_declaration(p)
		p.block_depth -= 1
		if alt == nil {
			report_error(p, "Expected statement after 'else'")
		}
		report_statement_only_position(p, alt, !p.strict_mode)
		if_.alternate = alt
	}

	// Note: detecting a *duplicate* `else` from here isn't safe - after an
	// inner if/else completes, the outer `else` (dangling-else rule) is a
	// valid continuation, and parse_if_statement can't see the outer
	// context. The stray-else case (`if (x) {} else {} else {}` at the
	// same nesting level) is caught by the top-level statement loop's
	// unknown-token recovery instead.

	if_.loc.span.end = prev_end_offset(p)
	return statement_from(p, if_)
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

	if !expect_token(p, .RParen) {
		return nil
	}

	prev_in_loop := p.in_loop
	p.in_loop = true
	p.block_depth += 1
	body := parse_statement_or_declaration(p)
	p.block_depth -= 1
	p.in_loop = prev_in_loop
	if body == nil {
		report_error(p, "Expected statement after 'while' condition")
	}
	report_statement_only_position(p, body, false)

	while_ := new_node(p, WhileStatement)
	while_.loc = start
	while_.test = test
	while_.body = body
	while_.loc.span.end = prev_end_offset(p)

	return statement_from(p, while_)
}

parse_do_while_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume do

	prev_in_loop := p.in_loop
	p.in_loop = true
	p.block_depth += 1
	body := parse_statement_or_declaration(p)
	p.block_depth -= 1
	p.in_loop = prev_in_loop
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

	if !expect_token(p, .RParen) {
		return nil
	}

	match_token(p, .Semi) // Optional semicolon

	do_ := new_node(p, DoWhileStatement)
	do_.loc = start
	do_.body = body
	do_.test = test
	do_.loc.span.end = prev_end_offset(p)

	return statement_from(p, do_)
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
		if !p.in_async && !p.in_static_block {
			if p.in_function {
				report_error(p, "'for await' outside of async function")
			} else if st, have := p.force_source_type.(SourceType); have && st == .Script {
				// Explicitly forced Script mode - reject unconditionally.
				report_error(p, "Top-level 'for await' is only valid in module code")
			} else if !have && !allow_ts_mode(p) {
				// Auto-detect JS file. Lazy pre-scan resolves whether the
				// file is a module before deciding (top-level for-await is
				// module-only). On CJS bundles the scan finds no
				// import/export so has_module_syntax stays false and we
				// reject as Script.
				ensure_module_syntax_resolved(p)
				if !p.has_module_syntax {
					report_error(p, "Top-level 'for await' is only valid in module code")
				}
			}
		}
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
	let_starts_decl := false
	if is_token(p, .Let) {
		nxt := peek_dispatch(p)
		// Conservative whitelist of tokens that legally start a
		// LexicalBinding after `let`. Anything else falls through to
		// the expression-head path. is_identifier_like_token covers
		// every contextual keyword that's also a valid binding name
		// (`assert`, `abstract`, `declare`, ... plus the JS contextuals).
		if nxt.type == .LBracket || nxt.type == .LBrace ||
		   is_identifier_like_token(nxt.type) {
			let_starts_decl = true
		}
	}
	// `using` in a for-head follows the same BindingIdentifier rule:
	// `for (using of of)` → expression; `for (using x of ...)` → decl.
	using_starts_decl := false
	if is_token(p, .Using) {
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
			using_starts_decl = after_of == .Assign || after_of == .Comma ||
			                    after_of == .Semi || after_of == .Colon
		} else {
			using_starts_decl = (nxt_u.type == .Identifier || can_be_binding_identifier(nxt_u.type)) &&
			                    !nxt_u.had_line_terminator
			// Escaped `of` identifier (`o\u0066`): ECMA-262 §12.7.2 says
			// keywords must not contain Unicode escapes. When the binding
			// name is an escaped-identifier whose cooked value is "of",
			// reject it — matches OXC / V8 behaviour.
			// Check by decoding the raw source span: if the nxt token has
			// an escape and its span is 2 chars wide when decoded to "of",
			// the identifier is an escaped keyword.
			if using_starts_decl && nxt_u.type == .Identifier &&
			   (p.lexer.nxt.flags & FLAG_HAS_ESCAPE) != 0 {
				// Read cooked value: advance into the token, check, restore.
				snap_u := lexer_snapshot(p)
				advance_token(p) // consume `using` → cur = escaped ident
				cooked_is_of := p.cur_tok.value == "of"
				lexer_restore(p, snap_u)
				if cooked_is_of {
					report_error(p, "Keywords cannot contain escape characters")
				}
			}
		}
	}
	await_using_for_decl := false
	if is_token(p, .Await) && peek_dispatch(p).type == .Using {
		using_after_await := peek_token(p)
		if using_after_await.had_line_terminator {
			report_error(p, "Line terminator not permitted between 'await' and 'using'")
		}
		await_using_for_decl = await_using_starts_decl(p)
	}
	// A using/await-using declaration in a for-init is NOT directly
	// inside the case clause, so clear the flag before parsing.
	prev_case_clause := p.in_case_clause
	p.in_case_clause = false
	defer p.in_case_clause = prev_case_clause

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
		//
		// no_in gates `in` as a binary operator inside the declarator init
		// (§13.15.5 / §14.7.4). Without it `for (var x = 1 in y)` parses
		// the init as `1 in y` and the parser then expects a `;`. With
		// no_in, the init stops at `1`, the outer for-statement sees `in`,
		// and the Annex B.3.5 carve-out (sloppy-mode `for (var Id = init
		// in Expr)`) becomes reachable. Parenthesised sub-expressions
		// reset no_in inside the parens, so `for (var x = (a in b); ...)`
		// keeps working.
		prev_no_in := p.no_in
		p.no_in = true
		decl_stmt := parse_variable_declaration(p, nil, false, true)
		p.no_in = prev_no_in
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
							if p.lexer != nil && p.lexer.nxt.kind == .RParen {
								report_error(p, "'for (var of of)' is ambiguous")
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
		nxt_is_of := p.lexer != nil && p.lexer.nxt.kind == .Of
		// Also match escaped `o\u0066`: lexed as .Identifier, cooked to "of".
		if !nxt_is_of && p.lexer != nil &&
		   p.lexer.nxt.kind == .Identifier &&
		   (p.lexer.nxt.flags & FLAG_HAS_ESCAPE) != 0 {
			snap := lexer_snapshot(p)
			advance_token(p) // consume `await` → cur = escaped-of
			nxt_is_of = p.cur_tok.value == "of"
			lexer_restore(p, snap)
		}
		if is_token(p, .Await) && !p.in_async && nxt_is_of {
			cur := get_current(p)
			id := new_node(p, Identifier)
			id.loc = loc_from_token(&cur); id.name = cur.value
			eat(p)
			left_expr = expression_from(p, id)
		} else {
			// Parse as full expression (including comma) but stop at 'in'/'of'.
			// The no_in flag prevents 'in' from being consumed as binary operator.
			p.no_in = true
			left_expr = parse_expr_with_prec(p, .Comma)
			p.no_in = false
		}
	}

	// Escaped `of` keyword: `o\u0066` → .Identifier with cooked value
	// "of" and has_escape=true. OXC rejects as "Keywords cannot contain
	// escape characters".
	if p.cur_type == .Identifier && p.cur_tok.has_escape && p.cur_tok.value == "of" {
		report_error(p, "Keywords cannot contain escape characters")
	}
	// Now check if this is for-in, for-of, or regular for
	if is_token(p, .In) || is_token(p, .Of) {
		// for-in or for-of
		is_in := is_token(p, .In)
		// §15.8.2 - `for await` is only legal with `of`, never `in`.
		if is_in && await {
			report_error(p, "'await' can only be used in conjunction with 'for...of' statements")
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
				p.cur_tok.type = ft.kind
				p.cur_tok.loc = LexerLoc(ft.start)
				if ft.kind < .LBrace && ft.start < ft.end {
					p.cur_tok.value = p.lexer.source[ft.start:ft.end]
				}
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
				report_error(p, msg)
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
					span_start := id.loc.span.start
					span_end := id.loc.span.end
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
						report_error(p, "The left-hand side of a for-of loop may not be 'async'")
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
					report_error(p, "The left-hand side of a for-of loop may not start with 'let'")
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
					report_error(p, msg)
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
		//
		// Core grammar also only allows a SINGLE ForBinding /
		// ForDeclaration in the for-in/of head - no comma-list - so even
		// init-free `for (var x, y in z)` is a SyntaxError.
		if left_decl != nil {
			// §13.7.5.1 — "only a single declarator" + "no initializer"
			// rules are checked by the semantic checker
			// (ck_check_for_in_of_head). Parser keeps the structural rule
			// below: `using` / `await using` is permitted only in for-of
			// heads (not for-in), which is a parse-time constraint.
			if is_in && (left_decl.kind == .Using || left_decl.kind == .AwaitUsing) {
				kn := "using"
				if left_decl.kind == .AwaitUsing { kn = "await using" }
				msg := fmt.tprintf("'%s' declaration is not allowed in a for-in loop", kn)
				report_error(p, msg)
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
				eat(p)
			}
			match_token(p, .RParen)
		}

		prev_in_loop := p.in_loop
		p.in_loop = true
		// Increment block_depth so import/export inside a for-in/of single-
		// statement body are rejected as nested positions (§16.2.1).
		p.block_depth += 1
		body := parse_statement_or_declaration(p)
		p.block_depth -= 1
		p.in_loop = prev_in_loop
		if body == nil {
			report_error(p, "Expected statement after for-in/of head")
		}
		report_statement_only_position(p, body, false)

		// §14.7.5.1 for-in/of head-vs-body shadowing is enforced by the
		// semantic checker (ck_check_for_head_body_shadow); the parser
		// stays permissive.

		if is_in {
			// for-in - use separate fields for declaration vs expression
			for_in := new_node(p, ForInStatement)
			for_in.loc = start
			if left_decl != nil {
				for_in.left_decl = left_decl
			} else {
				for_in.left_expr = left_expr
			}
			for_in.right = right
			for_in.body = body
			for_in.loc.span.end = prev_end_offset(p)
			return statement_from(p, for_in)
		} else {
			// for-of or for-await-of - use separate fields
			for_of := new_node(p, ForOfStatement)
			for_of.loc = start
			if left_decl != nil {
				for_of.left_decl = left_decl
			} else {
				for_of.left_expr = left_expr
			}
			for_of.right = right
			for_of.body = body
			for_of.await = await
			for_of.loc.span.end = prev_end_offset(p)
			return statement_from(p, for_of)
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
						report_error(p, "Using declarations must have an initializer")
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

	prev_in_loop := p.in_loop
	p.in_loop = true
	p.block_depth += 1
	body := parse_statement_or_declaration(p)
	p.block_depth -= 1
	p.in_loop = prev_in_loop
	if body == nil {
		report_error(p, "Expected statement after for head")
	}
	report_statement_only_position(p, body, false)

	// §14.7.4.1 for-loop head-vs-body shadowing is enforced by the
	// semantic checker (ck_check_for_head_body_shadow).

	// `for await (;;)` / `for await (let i=0;;)` - await is only valid
	// with for-of, not regular for-statements.
	if await {
		report_error(p, "'await' can only be used in conjunction with 'for...of' statements")
	}

	for_ := new_node(p, ForStatement)
	for_.loc = start
	for_.init_decl = init_decl
	for_.init_expr = init_expr
	for_.test = test
	for_.update = update
	for_.body = body
	for_.loc.span.end = prev_end_offset(p)

	return statement_from(p, for_)
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
	if !p.in_function {
		report_error(p, "'return' outside of function")
	}
	// §15.7.5 ClassStaticBlockBody is parsed under [~Return]; the
	// outer in_function is set to true so new.target works, but a
	// literal `return` is forbidden by the grammar parameter.
	if p.in_static_block {
		report_error(p, "'return' is not allowed in a class static block")
	}

	argument: Maybe(^Expression)
	// ECMA-262 §12.10 Restricted Production: `return` followed by a
	// LineTerminator triggers ASI - the argument belongs to the NEXT
	// statement, not to this return. Check had_line_terminator on the
	// current token BEFORE deciding whether to parse an argument.
	if !is_token(p, .Semi) && !is_token(p, .RBrace) && !is_token(p, .EOF) && !p.cur_tok.had_line_terminator {
		argument = parse_expression(p)
	}

	match_semicolon_or_asi(p)

	ret := new_node(p, ReturnStatement)
	ret.loc = start
	ret.argument = argument
	ret.loc.span.end = prev_end_offset(p)

	return statement_from(p, ret)
}

// Linear scan of the in-function slice of p.label_stack. The stack is
// small in practice (nested-label depth is almost always 0-2 in real
// code), so the O(N) lookup beats any hash overhead. Only labels at or
// above `label_floor` are visible - labels below belong to enclosing
// functions and don't cross function boundaries.
label_in_scope :: proc(p: ^Parser, name: string) -> bool {
	for i := p.label_floor; i < len(p.label_stack); i += 1 {
		if p.label_stack[i] == name { return true }
	}
	return false
}

// `continue label` (ECMA-262 §14.8.1) requires `label` to name an
// IterationStatement that is ContainedIn the enclosing function. We track
// that per-label via `label_is_iteration`, parallel to `label_stack`, so
// this helper is just `label_in_scope` gated on the iteration bit.
label_iter_in_scope :: proc(p: ^Parser, name: string) -> bool {
	for i := p.label_floor; i < len(p.label_stack); i += 1 {
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
			if p.lexer == nil || p.lexer.nxt.kind != .Colon { return false }
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
	// Label only if on same line (no LineTerminator between break and identifier)
	if is_token(p, .Identifier) && !p.cur_tok.had_line_terminator {
		// LabelIdentifier is an Identifier position - escaped ReservedWord
		// (e.g. `break \u0069f;`) is a Syntax Error (§12.7.2).
		report_escaped_reserved_word(p)
		label = LabelIdentifier{
			loc  = cur_loc(p),
			name = cur_value(p),
		}
		eat(p)
	}

	// ECMA-262 §13.9.1 Static Semantics: an unlabeled `break;` is only
	// valid inside an IterationStatement or SwitchStatement. Labeled
	// `break label;` is valid iff `label` names an enclosing
	// LabelledStatement (any kind - the spec doesn't restrict to
	// iteration). p.label_stack tracks exactly that set; it resets on
	// function boundaries so `break outer;` can't escape out of a
	// function expression.
	// Early-error checks for break (label scope, loop/switch context)
	// are deferred to the semantic checker pass.

	// §14.9 - BreakStatement requires a `;` (or ASI).
	expect_semicolon_or_asi(p)

	break_ := new_node(p, BreakStatement)
	break_.loc = start
	break_.label = label
	break_.loc.span.end = prev_end_offset(p)

	return statement_from(p, break_)
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
	// Label only if on same line (no LineTerminator between continue and identifier)
	if is_token(p, .Identifier) && !p.cur_tok.had_line_terminator {
		// LabelIdentifier is an Identifier position - escaped ReservedWord
		// (e.g. `continue \u0069f;`) is a Syntax Error (§12.7.2).
		report_escaped_reserved_word(p)
		label = LabelIdentifier{
			loc  = cur_loc(p),
			name = cur_value(p),
		}
		eat(p)
	}

	// Early-error checks for continue (loop context, label targets)
	// are deferred to the semantic checker pass.

	// §14.8 - ContinueStatement requires a `;` (or ASI).
	expect_semicolon_or_asi(p)

	cont := new_node(p, ContinueStatement)
	cont.loc = start
	cont.label = label
	cont.loc.span.end = prev_end_offset(p)

	return statement_from(p, cont)
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

	prev_in_switch := p.in_switch
	p.in_switch = true

	// §14.12.1 "more than one default clause" early error: enforced by
	// the semantic checker (ck_check_switch_default_dups). The parser
	// stays permissive and just appends every case it sees.
	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		prev_offset := int(cur_offset(p))
		case_ := parse_switch_case(p)
		if case_ != nil {
			bump_append(&switch_.cases, case_^)
		} else if int(cur_offset(p)) == prev_offset {
			eat(p)
		}
	}

	p.in_switch = prev_in_switch

	if !match_token(p, .RBrace) {
		report_error(p, "Expected '}' at end of switch statement")
	}

	switch_.loc.span.end = prev_end_offset(p)
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
	// Slice 14: the parser-side scope_pending push was removed. The
	// semantic checker walks ck_walk_stmt's SwitchStatement case and
	// invokes scope_check_body on the flattened consequents in source
	// order.
	_ = total
	_ = relevant
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
			report_error(p, "Expected expression after 'case'")
			eat(p) // consume `:`
			return nil
		}
		test = parse_expression(p)
	} else {
		report_error(p, "Expected 'case' or 'default' in switch")
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
	prev_in_case_clause := p.in_case_clause
	p.in_case_clause = true
	defer p.in_case_clause = prev_in_case_clause
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

	case_.loc.span.end = prev_end_offset(p)
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

	try_ := new_node(p, TryStatement)
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
		report_error(p, "Try statement must have catch or finally clause")
	}

	try_.loc.span.end = prev_end_offset(p)
	return statement_from(p, try_)
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
			report_error(p, "Catch parameter is missing")
		} else {
			param = parse_binding_pattern(p)
			// TS § catch-clause-types - the catch parameter may carry a
			// type annotation (`: any` or `: unknown` per TS rules; the
			// type-checker enforces the narrow set, the parser accepts
			// any TS type). Closes ≈16 OXC corpus rejects in the
			// "Expected ), got :" cluster (destructureCatchClause.ts and
			// friends use shapes like `catch ({ x }: unknown) { ... }`).
			if allow_ts_mode(p) && is_token(p, .Colon) {
				_ = parse_ts_type_annotation(p)
			}
		}
		if !expect_token(p, .RParen) {
			return nil
		}
	}

	// §14.15 - BoundNames of a CatchParameter must be unique. Catches
	// the destructuring cases `catch ([x, x]) {}` and `catch ({x: a, y:
	// a}) {}`. Use the existing collect helper (which dedups by map
	// §15.4.5 — catch parameter duplicate-name check is enforced by
	// the semantic checker (ck_check_catch_param_dups). Removed from
	// the parser; param is built unchanged below.
	_ = param

	body := parse_block_statement(p)
	if body == nil {
		return nil
	}
	body_ptr, body_ok := body^.(^BlockStatement)
	if !body_ok {
		return nil
	}

	// §14.15.1 catch parameter vs body let/const redeclaration is
	// enforced by the semantic checker (ck_check_catch_param_body_shadow).

	clause := CatchClause{
		loc   = start,
		param = param,
		body  = body_ptr^,
	}
	clause.loc.span.end = prev_end_offset(p)

	return clause
}

parse_throw_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume throw

	// ECMA-262 §14.14 Restricted Production - no LineTerminator between
	// `throw` and the argument expression. ASI does NOT apply to throw;
	// a bare `throw` with a newline before the argument is a SyntaxError.
	if p.cur_tok.had_line_terminator {
		report_error(p, "Illegal newline after 'throw'")
	}

	argument := parse_expression(p)
	if argument == nil {
		report_error(p, "Expected expression after throw")
		return nil
	}

	match_semicolon_or_asi(p)

	throw_ := new_node(p, ThrowStatement)
	throw_.loc = start
	throw_.argument = argument
	throw_.loc.span.end = prev_end_offset(p)

	return statement_from(p, throw_)
}

parse_debugger_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume debugger

	match_semicolon_or_asi(p)

	debugger := new_node(p, DebuggerStatement)
	debugger.loc = start
	debugger.loc.span.end = prev_end_offset(p)

	return statement_from(p, debugger)
}

parse_with_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume with

	// §14.11.1 "with-in-strict" early error: enforced by the semantic
	// checker (ck_walk_stmt's ^WithStatement case) using its own strict
	// mode tracker. The parser stays permissive on this in slice 5+.

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

	if !expect_token(p, .RParen) {
		return nil
	}

	body := parse_statement_or_declaration(p)
	if body == nil {
		report_error(p, "Expected statement after 'with' object")
	}
	// ECMA-262 §14.11.1 - WithStatement : with ( Expression ) Statement.
	// Statement excludes hoistable declarations (LexicalDeclaration,
	// ClassDeclaration, AsyncFunctionDeclaration, GeneratorDeclaration,
	// AsyncGeneratorDeclaration). Plain FunctionDeclaration is also banned
	// since `with` is itself strict-mode-illegal but in sloppy script the
	// body cannot be a Declaration form per the grammar.
	report_statement_only_position(p, body, false)

	with_ := new_node(p, WithStatement)
	with_.loc = start
	with_.object = object
	with_.body = body
	with_.loc.span.end = prev_end_offset(p)

	return statement_from(p, with_)
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
		report_error(p, "Expected function after async")
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
			current := get_current(p)
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
				report_error(p, "'await' cannot be used as the name of an async function expression")
			}
			// OXC catches `(function*yield(){})` and
			// `var x = function*yield(){}` etc. as parser-level errors,
			// but NOT `export default function *yield() {}`. Match OXC:
			// fire as a structural parse error unless we're in export-
			// default context (where the strict-mode reservation kicks in
			// at the semantic checker via
			// ck_check_binding_identifier_strict on the function name).
			if is_expr && generator && current.value == "yield" && !p.in_export_default {
				report_error(p, "'yield' cannot be used as the name of a generator function expression")
			}
			// §15.7.1 strict-mode `yield` as fn name (non-generator) is
			// enforced by the semantic checker (handled by
			// ck_walk_function's BindingIdentifier strict check).

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
				report_error(p, "'enum' is a reserved word and cannot be used as a function name")
			}
			if !is_expr {
				if current.value == "await" && await_is_reserved_here(p) {
					report_error(p, "'await' cannot be used as a function name in module / async context")
				}
				// In generator context `yield` as a declaration name is a
				// parser-level error (OXC catches it).
				if current.value == "yield" {
					if p.in_generator || p.in_generator_params {
						report_error(p, "'yield' cannot be used as a function name in generator context")
					}
					// Strict-mode yield-as-decl-name is enforced by the
					// semantic checker.
				}
			}
			eat(p)
		} else if !is_expr {
			report_error(p, "Function declaration requires a name")
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
	prev_in_gen_params := p.in_generator_params
	prev_in_async_params := p.in_async_params
	// Static-block context does NOT extend into nested function parameters;
	// `method(x = await){}` inside a static block should not flag `await`.
	prev_static_block_params := p.in_static_block
	p.in_static_block = false
	p.in_generator_params = generator
	p.in_async_params = async
	// The outer generator/async context should NOT leak into a nested
	// non-generator non-async function's params. `function f(x = yield){}`
	// inside a generator has `yield` as IdentifierRef, not YieldExpression.
	prev_in_generator_param_outer := p.in_generator
	prev_in_async_param_outer := p.in_async
	if !generator { p.in_generator = false }
	if !async    { p.in_async = false }
	// §15.2.1 / §15.7 - set `in_function` before params so the
	// AwaitExpression / YieldExpression checks in parse_unary_expr see
	// that we are inside a function scope, preventing `await 1` in
	// non-async function params from being misinterpreted as TLA.
	prev_in_function_params := p.in_function
	p.in_function = true
	// `new.target` is legal in a parameter default of a regular
	// function (e.g. `function f(x = new.target) {}`); arrow params
	// are handled separately and inherit the outer flag.
	prev_in_non_arrow_params := p.in_non_arrow_function
	p.in_non_arrow_function = true
	params := parse_function_params(p)
	p.in_function = prev_in_function_params
	p.in_non_arrow_function = prev_in_non_arrow_params
	p.in_generator_params = prev_in_gen_params
	p.in_async_params = prev_in_async_params
	p.in_static_block = prev_static_block_params
	p.in_generator = prev_in_generator_param_outer
	p.in_async = prev_in_async_param_outer

	report_parameter_modifiers_disallowed(p, params[:])

	if !expect_token(p, .RParen) {
		// Error recovery: skip forward to the next `{` (start of the body)
		// or a clear statement terminator so we can still build a function
		// declaration around the intended body. Without this, a malformed
		// param list like `function f(a, b { ... }` leaked the body to the
		// top-level parser, and the `return` inside fired the new top-level
		// return diagnostic - a cascading false positive.
		for !is_token(p, .LBrace) && !is_token(p, .Semi) && !is_token(p, .EOF) {
			eat(p)
		}
	}

	// TypeScript return type annotation
	return_type: Maybe(^TSTypeAnnotation)
	if is_token(p, .Colon) && allow_ts_mode(p) {
		return_type = parse_ts_return_type_annotation(p)
	}

	prev_async := p.in_async
	p.in_async = async
	prev_gen := p.in_generator
	p.in_generator = generator
	// A nested function body starts a new scope that does NOT inherit
	// the enclosing async-param/generator-param flags. `function f()
	// { await }` inside an async arrow's parameter default is legal
	// because the nested function is NOT async.
	prev_in_async_params_body := p.in_async_params
	p.in_async_params = false
	prev_in_gen_params_body := p.in_generator_params
	p.in_generator_params = false
	// Regular (non-arrow) function declarations / expressions reset
	// `in_method` - they introduce their own (absent) [[HomeObject]], so
	// a nested `function foo() { super.x; }` inside a class method body
	// is a SyntaxError. Arrow functions keep inherited `in_method`.
	prev_in_method := p.in_method
	p.in_method = false
	// Same rule for `in_derived_constructor` - a regular function inside
	// a derived-class constructor gets its own (non-constructor)
	// function environment, so `super(...)` inside it is a SyntaxError.
	prev_in_derived_ctor := p.in_derived_constructor
	p.in_derived_constructor = false

	// In declare / ambient-module context, allow no body (just a semicolon).
	// An ambient module body (`module "x" { function f(): void; }`) or a
	// `declare function f(): void;` both elide the implementation.
	//
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
	allow_no_body_here := allow_no_body || p.in_ambient || allow_ts_mode(p)
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
		           p.cur_tok.had_line_terminator) {
			is_no_body = true
			// Don't consume - the outer parse_statement_or_declaration
			// loop expects to see the next-statement token unchanged.
		}
	}
	if is_no_body {
		body = FunctionBody{
			loc = cur_loc(p),
			body = make([dynamic]^Statement, 0, 0, p.allocator),
			directives = make([dynamic]Directive, 0, 0, p.allocator),
		}
	} else {
		// §14.1 - an explicit `declare function f() {}` is a SyntaxError
		// (the body contradicts declare). But a function inside
		// `declare module "m" { function f() {} }` IS allowed by OXC.
		if allow_no_body {
			report_error(p, "An implementation cannot be declared in ambient contexts")
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

	p.in_async = prev_async
	p.in_generator = prev_gen
	p.in_async_params = prev_in_async_params_body
	p.in_generator_params = prev_in_gen_params_body
	p.in_method = prev_in_method
	p.in_derived_constructor = prev_in_derived_ctor

	// Retroactive StrictFormalParameters check: if either the enclosing
	// context was already strict or the body declared `"use strict"`, the
	// params must have no duplicate bound names. Non-simple parameter
	// lists (destructuring, default values, rest) additionally force the
	// UniqueFormalParameters rule even in sloppy mode (§15.1.2).
	// §15.5.1 GeneratorBody and §15.8.1 AsyncFunctionBody also require
	// UniqueFormalParameters unconditionally - pass strict_override=true
	// for them regardless of outer strict mode.
	strict_for_check := p.strict_mode || body_strict
	// §15.1.1 / §15.5.1 / §15.6.1 / §15.8.1 — strict-mode parameter
	// duplicate-name + eval/arguments + reserved-word + function name
	// strict checks are all enforced by the semantic checker. The
	// parser stays permissive (it builds the FunctionExpression with
	// the parameters and name unchanged).
	_ = strict_for_check
	_ = generator
	_ = async
	_ = id

	// §15.2.1.1 / §15.5.1 - It is a Syntax Error if any element of the
	// BoundNames of FormalParameters also occurs in the LexicallyDeclaredNames
	// of FunctionBody. e.g. `function f(a) { const a = 1; }` is SyntaxError.
	// Collect param names and check against body's lex declarations.

	if is_expr {
		expr := new_node(p, FunctionExpression)
		expr.loc = start
		expr.id = id
		expr.params = params
		expr.body = body
		expr.generator = generator
		expr.async = async
		expr.type_parameters = type_parameters
		expr.return_type = return_type
		expr.no_body = is_ts_no_body
		expr.loc.span.end = prev_end_offset(p)

		// For function expressions, wrap in ExpressionStatement. The
		// .expression field is an ^Expression (a union ptr, not a raw ptr
		// to the concrete variant), so box via expression_from to get a
		// properly tagged union - a plain pointer cast produces a union
		// with tag=0 and corrupt contents on read.
		expr_stmt := new_node(p, ExpressionStatement)
		expr_stmt.loc = start
		expr_stmt.expression = expression_from(p, expr)
		expr_stmt.loc.span.end = prev_end_offset(p)

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
	decl.expr.loc.span.end = prev_end_offset(p)

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
			report_error(p, fmt.tprintf("'%s' modifier cannot appear on a parameter.", name))
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
					nxt := p.lexer.nxt.kind
					if nxt != .RParen && nxt != .EOF {
						report_error(p, "A rest parameter must be last in a parameter list")
					} else if !p.in_ambient && !p.source_is_dts {
						report_error(p, "A rest parameter or binding pattern may not have a trailing comma.")
					}
				}
			}
		}

		if !match_token(p, .Comma) {
			break
		}
	}

	return params
}

parse_function_param :: proc(p: ^Parser) -> ^FunctionParameter {
	param := new_node(p, FunctionParameter)
	param.loc = cur_loc(p)

	// TS parameter decorators: `foo(@dec x: T)`. Consume any leading `@expr`
	// chain so the param parses; we don't yet attach the decorators to the
	// FunctionParameter / inner Identifier (OXC does, on the Identifier's
	// `decorators[]` field). Closes ~21 OXC corpus rejects in the
	// "Expected binding pattern" cluster (the immediate symptom is
	// parse_binding_pattern hitting `@`). Proper round-trip ATTACH is a
	// follow-on AST extension.
	decorators_seen := false
	if allow_ts_mode(p) {
		for is_token(p, .At) {
			decorators_seen = true
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
		mod_start := cur_loc(p).span.start  // position of first modifier (or binding if none)
		found_modifier := false
		param_access_order := -1
		param_readonly_order := -1
		param_override_order := -1
		param_mod_idx := 0
		for i := 0; i < 6; i += 1 {
			cur := p.cur_type
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
				val := p.cur_tok.value
				switch val {
				case "public":
					if param.accessibility != .None { report_error(p, "Accessibility modifier already seen.") }
					param.accessibility = .Public
					param_access_order = param_mod_idx; param_mod_idx += 1; eat(p); consumed = true; found_modifier = true
				case "private":
					if param.accessibility != .None { report_error(p, "Accessibility modifier already seen.") }
					param.accessibility = .Private
					param_access_order = param_mod_idx; param_mod_idx += 1; eat(p); consumed = true; found_modifier = true
				case "protected":
					if param.accessibility != .None { report_error(p, "Accessibility modifier already seen.") }
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
			report_error(p, fmt.tprintf("'%s' modifier must precede 'readonly' modifier.", acc_name))
		}
		if param_override_order >= 0 && param_readonly_order >= 0 && param_override_order > param_readonly_order {
			report_error(p, "'override' modifier must precede 'readonly' modifier.")
		}
		if param_access_order >= 0 && param_override_order >= 0 && param_access_order > param_override_order {
			acc_name := "public"
			if param.accessibility == .Private { acc_name = "private" }
			if param.accessibility == .Protected { acc_name = "protected" }
			report_error(p, fmt.tprintf("'%s' modifier must precede 'override' modifier.", acc_name))
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
				if ann != nil && ann.loc.span.end > ident.loc.span.end {
					ident.loc.span.end = ann.loc.span.end
				}
			}
		}
		rest.loc.span.end = prev_end_offset(p)

		// Store RestElement as the pattern
		param.pattern = rest
		// Rest parameters cannot have default values
		param.loc.span.end = prev_end_offset(p)
		return param
	}

	pattern: Pattern
	if p.cur_type == .This && allow_ts_mode(p) {
		if decorators_seen {
			report_error(p, "Decorators cannot be applied to 'this' parameters.")
		}
		// TS `this` parameter: `function(this: T) {}` - specifies the
		// type of `this` inside the function. Not a real runtime param.
		ident := new_node(p, Identifier)
		ident.loc = loc_from_token(&p.cur_tok)
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
	// OXC stores it on the pattern node - S26 W4b added the corresponding
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
			if ann != nil && ann.loc.span.end > t.loc.span.end {
				t.loc.span.end = ann.loc.span.end
			}
		case ^ObjectPattern:
			t.type_annotation = ann
			if ann != nil && ann.loc.span.end > t.loc.span.end {
				t.loc.span.end = ann.loc.span.end
			}
		case ^ArrayPattern:
			t.type_annotation = ann
			if ann != nil && ann.loc.span.end > t.loc.span.end {
				t.loc.span.end = ann.loc.span.end
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
			report_error(p, "Expected initializer expression after '='")
		} else {
			param.default_val = default_expr
		}
	}

	// TS: a parameter cannot have both `?` and a default initializer.
	if param_is_optional && param.default_val != nil {
		report_error(p, "A parameter cannot have a question mark and an initializer.")
	}

	param.loc.span.end = prev_end_offset(p)
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
		body       = make([dynamic]^Statement, 0, 0, p.allocator),
		directives = make([dynamic]Directive, 0, 0, p.allocator),
	}
	// If the body is non-empty, pre-grow the statement vector to its
	// typical capacity to avoid log-N realloc churn. Cap bumped from
	// 8 → 16 (S23): 430 functions on monaco had >8 statements, triggering
	// runtime grow. cap=16 covers most non-trivial function bodies.
	if !is_token(p, .RBrace) && !is_token(p, .EOF) {
		reserve(&body.body, 16)
	}

	prev_in_function := p.in_function
	prev_in_non_arrow := p.in_non_arrow_function
	prev_in_generator := p.in_generator
	prev_in_async := p.in_async
	prev_strict := p.strict_mode
	// Labels don't cross function boundaries (§14.13 - LabelSet is
	// per-function). Move the floor up to the current stack length so
	// outer labels are invisible for duplicate / break-target checks,
	// then restore. No copy; the parent labels stay in the backing store.
	prev_label_floor := p.label_floor
	p.label_floor = len(p.label_stack)
	// A FunctionBody is its own expression scope - the outer for-init
	// no_in restriction (set in parse_for_statement so Annex B.3.5
	// `for (var x = expr in y)` routes through the for-in arm) must
	// not leak into nested function bodies. Without this, a nested
	// `function() { if (a && "x" in y) {} }` inside a for-init's
	// declarator would reject the inner `in`.
	prev_no_in := p.no_in
	p.no_in = false
	// Static block context (§15.7.5) does NOT propagate into nested function
	// bodies: `class C { static { (() => { class await {} }); } }` is valid.
	prev_static_block_in_fb := p.in_static_block
	p.in_static_block = false

	p.in_function = true
	p.in_non_arrow_function = true

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
						es.directive = str_lit.value
						bump_append(&prologue_raws, str_lit)
						if str_lit.value == "use strict" {
							body_use_strict = true
							p.strict_mode = true
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
			already := len(p.errors) > 0 &&
			           p.errors[len(p.errors)-1].loc == LexerLoc(cur_offset(p))
			is_closer := p.cur_type == .RParen || p.cur_type == .RBracket
			if !already && !is_closer {
				msg := fmt.tprintf("Unexpected token '%s'", cur_value(p))
				report_error(p, msg)
			}
			eat(p)
		}
	}

	// §12.9.4 Annex B.1.2 / §12.9.4.1 - if the function body's prologue
	// contains a "use strict" directive, EVERY prologue StringLiteral
	// Retroactive octal / \8 / \9 scan over directive-prologue strings:
	// enforced by the semantic checker. ck_check_string_octal_escape
	// runs against EVERY StringLiteral in strict scope, including the
	// prologue strings (an ExpressionStatement.expression is still a
	// StringLiteral the walker visits). When the body lifts strict via
	// `"use strict"`, ck_walk_function sets ctx.strict_mode = true
	// before walking body.body, so prologue strings PRECEDING the
	// directive token still report correctly.

	p.in_function = prev_in_function
	p.in_non_arrow_function = prev_in_non_arrow
	p.in_generator = prev_in_generator
	p.in_async = prev_in_async
	p.strict_mode = prev_strict
	p.no_in = prev_no_in
	p.in_static_block = prev_static_block_in_fb
	// Restore the enclosing label floor. Labels pushed inside this body
	// should have been popped on their LabelledStatement exit; if not
	// (parse bail-out, etc.) truncate down so leftovers don't pollute
	// the parent scope.
	resize(&p.label_stack, p.label_floor)
	p.label_floor = prev_label_floor
	// Surface the directive-prologue result to the caller. `parse_function_
	// declaration` / `parse_function_expression` / class-method parse /
	// object-method parse read this immediately after the call to apply
	// ECMA-262 §15.2.1 StrictFormalParameters retro-checks on the params
	// they already captured. Must be read before any further parsing since
	// nested function bodies clobber the field.
	p.last_body_strict = body_use_strict

	if !match_token(p, .RBrace) {
		report_error(p, "Expected '}' at end of function body")
	}

	body.loc.span.end = prev_end_offset(p)
	// Queue this function body for post-parse scope verification.
	// is_block_scope=false: a FunctionBody is its own function-scope, so a
	// sloppy plain FunctionDeclaration inside it hoists as .Var (§14.1.3),
	// matching the semantics of the previous scope_recurse path. Skip the
	// queue when the body has nothing scope-relevant to check (typical
	// callback bodies like `() => { return jsx }`) or when scope_skip is
	// set by an enclosing uncovered expression context. Also skip in
	// --ast-only bench mode (verify_scopes is a no-op there).
	// Slice 14: the parser-side scope_pending push was removed. The
	// semantic checker walks ck_walk_function and invokes
	// scope_check_body on each function body in source order.
	return body
}

parse_class_declaration :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume class

	id: Maybe(BindingIdentifier)
	if can_be_binding_identifier(p.cur_type) {
		current := get_current(p)
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
			report_error(p, "'enum' is a reserved word and cannot be a class name")
		}
		// §15.7.1 strict-reserved / eval / arguments / await as class
		// name: enforced by the semantic checker (ck_check_class_name)
		// using its own in_async + source_type trackers.
		// Escaped-ReservedWord in the BindingIdentifier position. Class
		// names are strict-mode-only, so `class l\u0065t` reaches the
		// strict-only branch too.
		if p.cur_tok.has_escape {
			if is_always_reserved_word_name(current.value) ||
			   is_strict_reserved_name(current.value) ||
			   current.value == "let" || current.value == "static" ||
			   current.value == "yield" {
				msg := fmt.tprintf("Keyword '%s' must not contain escaped characters", current.value)
				report_error(p, msg)
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
	prev_strict_class := p.strict_mode
	p.strict_mode = true
	defer p.strict_mode = prev_strict_class
	super_type_arguments: Maybe(^TSTypeParameterInstantiation)
	if match_token(p, .Extends) {
		super_class = parse_left_hand_side_expr(p)
		if super_class == nil {
			report_error(p, "Expected expression after 'extends'")
		}
		// TS: optional type arguments on the super class - `extends Foo<T, U>`.
		// parse_left_hand_side_expr stops at the `<` (it's not a JS infix op
		// in this position), so we have to parse the args here. Closes 95+
		// OXC corpus rejects in the "Expected {, got <" cluster (S26 W6
		// phase 3 bug class #8). Same fix at the ClassExpression call site.
		// OXC parses type arguments on class heritage in all modes
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
				arrow_start := int(arrow.loc.span.start)
				paren_wrapped := false
				if p.lexer != nil && arrow_start > 0 {
					pi := arrow_start - 1
					for pi >= 0 {
						pch := p.lexer.source_bytes[pi]
						if pch == '(' { paren_wrapped = true; break }
						if pch == ' ' || pch == '\t' || pch == '\n' || pch == '\r' { pi -= 1; continue }
						break
					}
				}
				if !paren_wrapped {
					report_error(p, "Arrow function is not a valid class heritage expression")
				}
			}
		}
	}

	// Thread "this class has an extends clause" through parse_class_body so
	// parse_class_element can enable `in_derived_constructor` only for the
	// instance constructor of a derived class. Saved / restored so nested
	// class declarations don't leak.
	prev_class_has_extends := p.class_has_extends
	p.class_has_extends = (super_class != nil)
	defer p.class_has_extends = prev_class_has_extends

	// TS: `class X implements Y, Z<T>` - optional after `extends`. OXC emits
	// `implements: [TSClassImplements{expression, typeArguments}]`. Kessel's
	// ClassDeclaration already has an `implements` field; it was simply
	// never populated by the parser. We reuse parse_ts_heritage_list (same
	// grammar as interface-extends) because the ESTree heritage-entry
	// shape is identical.
	//
	// `implements` is a contextual keyword (lexed as .Identifier in the
	// general case so `var implements = 1` still parses), so match by
	// value rather than token kind. Same pattern the lexer comment
	// mentions for `interface`.
	implements_list: [dynamic]TSInterfaceHeritage
	if (p.lang == .TS || p.lang == .TSX) &&
	   is_token(p, .Identifier) && p.cur_tok.value == "implements" {
		eat(p)
		implements_list = parse_ts_heritage_list(p)
		if len(implements_list) == 0 {
			report_error(p, "Expected interface name after 'implements'")
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
	decl.expr.loc.span.end = prev_end_offset(p)

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

	body := ClassBody{
		loc  = start,
		// Lazy alloc - zero-element class bodies (`class C {}`) appear in
		// declaration-style stubs / abstract definitions / TS-only shells.
		// Use a zero-cap make() so the allocator is set; reserve 8 only
		// when we know there's at least one element (or stray semicolon).
		body = make([dynamic]ClassElement, 0, 0, p.allocator),
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
			report_error(p, "Invalid class element")
			eat(p)
		}
	}

	if !match_token(p, .RBrace) {
		report_error(p, "Expected '}' at end of class body")
	}

	body.loc.span.end = prev_end_offset(p)
	report_private_class_member_errors(p, body.body[:])
	return body
}

// ECMA-262 §15.7.1 Static Semantics - a class body's PrivateBoundIdentifiers
// must be pairwise distinct UNLESS one is a getter and the other a setter
// with matching name (the get/set pair binds one slot). Also: the literal
// name `#constructor` is forbidden for any private member.
//
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
// `name`, StringLiteral its `value`, NumericLiteral the source `raw`.
class_element_prop_name :: proc(key: ^Expression) -> string {
	if key == nil { return "" }
	#partial switch v in key^ {
	case ^Identifier:
		if v != nil { return v.name }
	case ^StringLiteral:
		if v != nil { return v.value }
	case ^NumericLiteral:
		if v != nil { return v.raw }
	}
	return ""
}

report_private_class_member_errors :: proc(p: ^Parser, elems: []ClassElement) {
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

	// §15.7.1 "at most one constructor" early error: enforced by the
	// semantic checker (ck_check_class_constructors). The remaining
	// loop body in this proc handles syntax-level concerns: the static
	// `prototype` ban (§15.7.1) and the post-parse private-name
	// duplicate map (Annex §15.7.6).

	for elem in elems {
		if elem.key == nil { continue }

		// §15.7.1 - static ClassElement whose PropName is `"prototype"`
		// is a SyntaxError. Applies to every static kind: field, method,
		// getter, setter, accessor. Non-static `prototype` is legal.
		if elem.static && !elem.computed && !p.in_ambient {
			if class_element_prop_name(elem.key) == "prototype" {
				report_error(p, "Classes may not have a static member named 'prototype'")
			}
		}

		// §15.7.1 duplicate-constructor early error (with TS
		// overload-signature exception) is enforced by the semantic
		// checker — ck_check_class_constructors walks the same
		// elements with the lang context the parser used to consult.

		pid, is_private := elem.key.(^PrivateIdentifier)
		if !is_private || pid == nil { continue }
		name := pid.name
		if name == "constructor" {
			report_error(p, "Class private member name cannot be '#constructor'")
			continue
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
		// NOTE: duplicate private class member detection is deferred
		// to the semantic checker (OXC's parser does not check this).
		_ = dup
		// §15.7.1 private getter/setter static-mismatch is enforced by
		// the semantic checker (ck_check_class_private_static_mismatch).
		_ = static_mismatch
	}
}

parse_class_element :: proc(p: ^Parser) -> ^ClassElement {
	decorators := parse_decorators(p)
	start := cur_loc(p)
	if len(decorators) > 0 { start.span.start = decorators[0].loc.span.start }

	// Check for static block: static { ... }
	if is_token(p, .Static) && is_next_token(p, .LBrace) {
		if len(decorators) > 0 {
			report_error(p, "Decorators are not valid here.")
		}
		elem := parse_static_block(p, start)
		if elem != nil { elem.decorators = decorators }
		return elem
	}

	// TS class-member modifiers form a LOOSE prefix in front of the name:
	//   [accessibility] [static] [abstract] [override] [readonly] <name...>
	// TypeScript itself allows these in a few orderings (e.g. static before
	// or after access modifier); we accept any order and consume duplicates
	// permissively, matching OXC/typescript-eslint leniency. The parser just
	// captures the set; an enforcing type-checker owns ordering / duplicate
	// rules.
	//
	// `public` / `private` / `protected` / `readonly` are lexed as plain
	// Identifier tokens (contextual keywords, not reserved) so we inspect
	// the string value; `static` / `abstract` / `override` ARE reserved
	// keyword tokens in Kessel's lexer and can be matched by kind.
	static_ := false
	is_abstract := false
	accessibility := ClassAccessibility.None
	access_name := ""
	is_readonly := false
	is_override := false
	is_declare := false

	// Track modifier order for validation.
	mod_order_idx := 0
	access_order := -1
	static_order := -1
	readonly_order := -1

	// Bounded scan. A modifier token is only a modifier if the NEXT token
	// is a plausible continuation of the member signature - not `(`, `=`,
	// `;`, `,`, `}` which indicate the keyword is being used AS the member
	// name (e.g. `readonly()` is a method named readonly).
	for i := 0; i < 12; i += 1 {
		cur := p.cur_type
		nxt := p.lexer.nxt.kind
		// When the NEXT token indicates the keyword is being used as
		// the member NAME rather than as a modifier prefix, break:
		//   ( = ; , }   - plain member-name-then-body/init/field
		//   <           - TS generic method `declare<T>(){}` (TS only)
		//   ! ? :       - TS definite/optional/annotation `abstract!:T`
		is_member_start := nxt == .LParen || nxt == .Assign || nxt == .Semi ||
		                   nxt == .Comma || nxt == .RBrace ||
		                   (allow_ts_mode(p) && (nxt == .LAngle || nxt == .Not || nxt == .Question || nxt == .Colon))
		if is_member_start {
			break
		}
		// ASI: when the next token sits on a new line, a bare modifier-
		// shaped identifier (`public\n private foo()`) is the FIELD NAME,
		// not a modifier on the next member. The legal class-element
		// production for `public` followed by a LineTerminator is the
		// PropertyDefinition `public;` - same ASI rule that lets
		// `accessor\n a;` parse as two fields. Test:
		// typescript/compiler/asiPublicPrivateProtected.ts.
		if (p.lexer.nxt.flags & FLAG_NEW_LINE) != 0 {
			break
		}

		consumed := false
		#partial switch cur {
		case .Static:
			if !static_       { static_       = true; static_order = mod_order_idx; eat(p); consumed = true }
		case .Abstract:
			if !is_abstract   { is_abstract   = true; eat(p); consumed = true }
		case .Override:
			if !is_override   { is_override   = true; eat(p); consumed = true }
		case .Identifier:
			val := p.cur_tok.value
			switch val {
			case "public":
				if accessibility == .None {
					accessibility = .Public; access_name = "public"; access_order = mod_order_idx; eat(p); consumed = true
				} else {
					report_error(p, "Accessibility modifier already seen.")
					eat(p); consumed = true
				}
			case "private":
				if accessibility == .None {
					accessibility = .Private; access_name = "private"; access_order = mod_order_idx; eat(p); consumed = true
				} else {
					report_error(p, "Accessibility modifier already seen.")
					eat(p); consumed = true
				}
			case "protected":
				if accessibility == .None {
					accessibility = .Protected; access_name = "protected"; access_order = mod_order_idx; eat(p); consumed = true
				} else {
					report_error(p, "Accessibility modifier already seen.")
					eat(p); consumed = true
				}
			case "readonly":
				if !is_readonly {
					is_readonly = true; readonly_order = mod_order_idx; eat(p); consumed = true
				}
			// TS §3.1 ambient class members - `declare prop: T;` /
			// `declare static x: T;` etc. Lexed as a plain Identifier
			// ("declare" is not a reserved word in Kessel's lexer), so
			// match it by string value. OXC accepts `declare` as a
			// class modifier in all modes (JS + TS), matching V8 / Babel.
			case "declare":
				if !is_declare {
					is_declare = true;          eat(p); consumed = true
				}
			}
		}
		if consumed { mod_order_idx += 1 }
		if !consumed { break }
	}

	// OXC rejects `static\nstatic <name>` when the second `static` and
	// the name token are on the same line — OXC reads both `static`
	// tokens as modifiers, producing a conflict. When the name is on a
	// SEPARATE line (`static\nstatic\na()`), OXC does ASI and accepts.
	// Match by peeking 2 tokens ahead: reject only when the token after
	// the second `static` is on the same line (no FLAG_NEW_LINE).
	if is_token(p, .Static) && p.lexer != nil && p.lexer.nxt.kind == .Static &&
	   (p.lexer.nxt.flags & FLAG_NEW_LINE) != 0 {
		snap_ss := lexer_snapshot(p)
		advance_token(p) // consume first `static`
		advance_token(p) // consume second `static` → cur = third token
		third_on_same_line := !p.cur_tok.had_line_terminator
		third_type := p.cur_type
		lexer_restore(p, snap_ss)
		// Only reject when the third token is on the same line as the
		// second `static` and is a plausible member-name start.
		if third_on_same_line && third_type != .RBrace && third_type != .Semi &&
		   third_type != .EOF {
			eat(p)       // consume first `static` (field name)
			eat(p)       // consume second `static` (would-be modifier)
			report_error(p, fmt.tprintf("Expected `;` but found `%s`", cur_value(p)))
		}
	}

	// Modifier ordering validation (OXC parser-level).
	if allow_ts_mode(p) {
		if access_order >= 0 && static_order >= 0 && access_order > static_order {
			report_error(p, fmt.tprintf("'%s' modifier must precede 'static' modifier.", access_name))
		}
		if access_order >= 0 && readonly_order >= 0 && access_order > readonly_order {
			report_error(p, fmt.tprintf("'%s' modifier must precede 'readonly' modifier.", access_name))
		}
		if static_order >= 0 && readonly_order >= 0 && static_order > readonly_order {
			report_error(p, "'static' modifier must precede 'readonly' modifier.")
		}
	}

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
		next := peek_dispatch(p)
		next_starts_name := next.type != .LParen && next.type != .Semi &&
		                    next.type != .RBrace && next.type != .Assign &&
		                    next.type != .Comma
		// peek_dispatch returns the next non-whitespace token; check its
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
		next := peek_dispatch(p)
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
		next := peek_dispatch(p)
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
				report_error(p, "'async' modifier cannot be used here.")
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
		current := get_current(p)
		is_private = true
		// Accessibility modifiers are not allowed on private (#) fields.
		if accessibility != .None {
			report_error(p, fmt.tprintf("An accessibility modifier cannot be used with a private identifier."))
		}

		// Create PrivateIdentifier (strip the # prefix)
		name := current.value
		if len(name) > 0 && name[0] == '#' {
			name = name[1:]
		}

		private_ident := new_node(p, PrivateIdentifier)
		private_ident.loc = loc_from_token(&current)
		private_ident.name = name
		key = expression_from(p, private_ident)
		p.private_id_count += 1
		eat(p)
	} else if is_token(p, .String) {
		// String key: `get 'trusting-append'()` / `'method-name'()`. ESTree emits
		// this as a Literal key, not an Identifier. Previously stuffed into
		// new_identifier which copied the quoted raw source into `name`,
		// hiding the real string from downstream walkers (ember.js etc.).
		current := get_current(p)
		str_lit := new_node(p, StringLiteral)
		str_lit.loc = loc_from_token(&current)
		str_lit.value = current.literal.(string) or_else ""
		str_lit.raw = current.value
		key = expression_from(p, str_lit)
		eat(p)
	} else if is_token(p, .Number) {
		// Numeric key: `1234()`. Similarly emit as NumericLiteral-backed Literal
		// rather than an Identifier whose name is the numeric text.
		current := get_current(p)
		num_lit := new_node(p, NumericLiteral)
		num_lit.loc = loc_from_token(&current)
		num_lit.raw = current.value
		if v, ok := current.literal.(f64); ok {
			num_lit.value = v
		}
		key = expression_from(p, num_lit)
		eat(p)
	} else if is_token(p, .BigInt) {
		// BigInt key: `1n()`. Emit as BigIntLiteral per §13.2.3.
		current := get_current(p)
		big := new_node(p, BigIntLiteral)
		big.loc = loc_from_token(&current)
		big.raw = current.value
		if len(current.value) > 0 && current.value[len(current.value)-1] == 'n' {
			big.value = current.value[:len(current.value)-1]
		} else {
			big.value = current.value
		}
		big.loc.span.end = prev_end_offset(p)
		key = expression_from(p, big)
		eat(p)
	} else if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
		current := get_current(p)
		key = expression_from(p, new_identifier(p, current))
		eat(p)

		// Check if it's actually a constructor. Only promote to .Constructor
		// when no get/set modifier was seen - `get constructor() {}` is a
		// non-instance accessor named "constructor" and stays in its own
		// .Get / .Set kind so the post-parse §15.7.6 check below can flag
		// it as a SyntaxError.
		if (current.type == .Constructor || (current.type == .Identifier && current.value == "constructor")) &&
		   kind == .Method && !is_async && !is_generator && !static_ {
			kind = .Constructor
		}
		// §15.7.6 ClassElement - a non-static method named "constructor"
		// must be a plain Method (not get / set / async / generator). Catch
		// the disallowed shapes here, where we still see the original
		// modifiers + the literal name.
		if !static_ && !is_private && !computed &&
		   (current.type == .Constructor || (current.type == .Identifier && current.value == "constructor")) {
			if is_async {
				report_error(p, "Constructor can't be an async method")
			}
			if is_generator {
				report_error(p, "Class constructor cannot be a generator method")
			}
			if kind == .Get {
				report_error(p, "Class constructor cannot be a getter")
			}
			if kind == .Set {
				report_error(p, "Class constructor cannot be a setter")
			}
		}
	} else if is_token(p, .LBracket) {
		// TS index signature in class body: `[s: string]: number`. Detect by
		// peeking `[ Identifier : ...`. The interface-body parser
		// (parse_ts_object_member) handles this; class bodies got the same
		// detection added here. Pre-fix: kessel saw `[` and tried to parse
		// `s` as a computed-property-key expression, then choked on `:` looking
		// for `]`. Closes 130+ OXC corpus rejects in the "Expected ], got :"
		// cluster (S26 W6 phase 3 bug class #10). Skipped at the AST level for
		// now - the parser accepts the syntax, the corpus smoke gate passes,
		// and a proper TSIndexSignature class-element node can come in W7+
		// when the deep walker starts comparing class bodies.
		if allow_ts_mode(p) && p.lexer.nxt.kind == .Identifier {
			// Two-token lookahead: nxt is the identifier, nxt.nxt would be `:`.
			// We don't have a 2-tok-ahead helper, so snapshot+probe.
			snap := lexer_snapshot(p)
			eat(p)  // consume `[`
			eat(p)  // consume identifier
			is_index_sig := is_token(p, .Colon) ||
			                (is_token(p, .Question) && p.lexer.nxt.kind == .Colon)
			lexer_restore(p, snap)
			if is_index_sig {
				// Confirmed: parse and discard the index signature. Same shape
				// as parse_ts_object_member's index-signature arm.
				if accessibility != .None {
					report_error(p, fmt.tprintf("'%s' modifier cannot appear on an index signature.", access_name))
				}
				eat(p)            // `[`
				eat(p)            // identifier
				if match_token(p, .Question) {
					report_error(p, "An index signature parameter cannot have a question mark.")
				}
				expect_token(p, .Colon)
				_ = parse_ts_type(p)
				expect_token(p, .RBracket)
				if is_token(p, .Colon) && allow_ts_mode(p) {
					_ = parse_ts_type_annotation(p)
				} else if allow_ts_mode(p) {
					report_error(p, "An index signature must have a type annotation.")
				}
				match_semicolon_or_asi(p)
				// Return nil so the class-body loop swallows the element
				// without erroring - mirrors the existing pattern for elements
				// that the parser intentionally drops (TS overload signatures
				// don't materialize either).
				return nil
			}
		}
		// Computed property: [expr]
		computed = true
		eat(p)
		// OXC rejects `[[` in computed class keys when the `[` is NOT
		// preceded by `get` / `set` (accessor methods). `set [[0,1]](v)`
		// is fine because `set` consumed the outer `[` in a different
		// parse path; but `[[]]()` without accessor triggers an error.
		if is_token(p, .LBracket) && kind != .Get && kind != .Set {
			report_error(p, "Unexpected token")
		}
		// `[` opens a fresh expression context - the enclosing for-head
		// no_in restriction does not apply inside computed property keys
		// (`for (C = class { set ['x' in y](v) {} }; ; )` is legal).
		prev_no_in_cls := p.no_in
		p.no_in = false
		key = parse_assignment_expression(p)
		p.no_in = prev_no_in_cls
		if !expect_token(p, .RBracket) {
			return nil
		}
	} else {
		report_error(p, "Expected method or property name")
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
		nxt := p.lexer.nxt.kind
		if nxt == .Colon || nxt == .Semi || nxt == .Assign ||
		   nxt == .Comma || nxt == .RBrace {
			field_definite = true
			eat(p)
		}
	}

	// TS class field type annotation: `foo: T`. Parsed before the field/method split.
	field_type_ann: Maybe(^TSTypeAnnotation)
	if is_token(p, .Colon) && allow_ts_mode(p) {
		field_type_ann = parse_ts_type_annotation(p)
	}

	// Check if this is a field (has = but no () ) or method. `.Colon` was
	// consumed above as part of the type annotation, so after that point the
	// next token is either `;`/`,`/`}` (bare field) or `=` (initializer).
	//
	// ASI: a bare field with no explicit `;` / `=` ends at a line
	// terminator before the next class element. `class C { #x\n#y }`
	// must parse as two fields, not `#x` method missing `(`.
	is_field_by_asi := p.cur_tok.had_line_terminator &&
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
			prev_in_method := p.in_method
			p.in_method = true
			prev_in_derived_ctor := p.in_derived_constructor
			p.in_derived_constructor = false
			// §15.7.10 ClassFieldDefinitionEvaluation: ClassFieldInitializer
			// is the body of a SYNTHETIC non-async, non-generator function.
			// `await` and `yield` MUST NOT be parsed as AwaitExpression /
			// YieldExpression here, even when the enclosing function is
			// async / generator. They become plain IdentifierReferences,
			// which are then accepted-or-rejected by the standard
			// reserved-word rules (`await` reserved in modules / static
			// blocks; `yield` reserved in strict). Test262 staging/sm/
			// fields/await-identifier-{script,module-3}.js.
			prev_in_async := p.in_async
			prev_in_generator := p.in_generator
			prev_in_async_params := p.in_async_params
			prev_in_generator_params := p.in_generator_params
			p.in_async = false
			p.in_generator = false
			p.in_async_params = false
			p.in_generator_params = false
			init_expr := parse_assignment_expression(p)
			p.in_async = prev_in_async
			p.in_generator = prev_in_generator
			p.in_async_params = prev_in_async_params
			p.in_generator_params = prev_in_generator_params
			p.in_method = prev_in_method
			p.in_derived_constructor = prev_in_derived_ctor
			if init_expr != nil {
				value = init_expr
				// TS: `declare` fields must not have initializers,
				// UNLESS both `declare` and `readonly` are present
				// (OXC allows `declare readonly x = 1;`).
				if (is_declare || p.in_ambient) && !is_readonly {
					report_error(p, "Initializers are not allowed in ambient contexts.")
				}
				if is_abstract {
					report_error(p, "Abstract property cannot have an initializer.")
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
		if !computed {
			name := class_element_prop_name(key)
			if name == "constructor" {
				report_error(p, "Class field cannot be named 'constructor'")
			}
		}

		// §15.7.1 ClassElement - FieldDefinition must be followed by `;` or
		// a line terminator. `field = 1 /* comment */ method(){}` (no newline
		// between initializer and next element) is a SyntaxError.
		// Use a stricter check than can_insert_semicolon: in a class body,
		// a newline before any token (including `[`) terminates the field.
		if is_token(p, .Semi) {
			eat(p)
		} else if !is_token(p, .RBrace) && !is_token(p, .EOF) && !p.cur_tok.had_line_terminator {
			report_error(p, "Expected semicolon or line terminator after class field")
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
		elem.definite = field_definite
		elem.accessibility = accessibility
		elem.readonly = is_readonly
		elem.override_ = is_override

		elem.loc.span.end = prev_end_offset(p)
		return elem
	}

	// It's a method - parse parameters and body. TS allows generic methods
	// `foo<T>(x: T): T { ... }` - parse the optional <T,U,...> here, before
	// the `(`. Pre-fix the parser jumped straight to expect_token(.LParen)
	// and reported `Expected (, got <` on every generic class method.
	// Closes 100+ OXC corpus rejects in the cluster of that exact error
	// message (S26 W6 phase 3 bug class #7). Mirrors the same dance
	// parse_function_declaration does at line 3810. Stored on the
	// FunctionExpression's type_parameters slot below.
	method_type_parameters: Maybe(^TSTypeParameterDeclaration)
	if is_token(p, .LAngle) && allow_ts_mode(p) {
		method_type_parameters = parse_ts_type_parameters(p)
	} else if is_token(p, .LAngle) && !allow_ts_mode(p) {
		// In JS mode, `<T>` after a method name is a comparison, not
		// type parameters. Report error and skip the angle-bracketed
		// content for recovery.
		report_error(p, "Type parameters are only allowed in TypeScript files")
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
		report_error(p, "'readonly' modifier can only appear on a property declaration")
	}
	if kind == .Constructor && is_override {
		report_error(p, "'override' modifier cannot appear on a constructor declaration")
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
	prev_method_gen_params := p.in_generator_params
	prev_method_async_params := p.in_async_params
	p.in_generator_params = is_generator
	p.in_async_params = is_async
	// Static-block context does not extend into class method parameters.
	prev_static_block_mparams := p.in_static_block
	p.in_static_block = false
	// Class body is implicitly strict (§15.7.3); method parameter
	// parsing inherits strict mode so "yield" / "let" / etc. as param
	// defaults surface as strict-mode IdentifierReference errors
	// (§12.6.1.1).
	prev_strict_params := p.strict_mode
	p.strict_mode = true
	// `super.x` in a class method's default-param initializer is legal
	// (param scope inherits the method's [[HomeObject]]). Same
	// in_method = true save / restore as the body parsing below.
	prev_method_in_method := p.in_method
	p.in_method = true
	params := parse_function_params(p)
	if allow_ts_mode(p) {
		for param in params {
			has_modifier := param.accessibility != .None || param.readonly || param.override_
			if has_modifier {
				if kind != .Constructor {
					report_error(p, "Parameter property modifiers are only allowed in constructors")
				} else {
					if _, is_ident := param.pattern.(^Identifier); !is_ident {
						report_error(p, "A parameter property may not be declared using a binding pattern")
					}
				}
			}
		}
	}
	p.in_method = prev_method_in_method
	p.strict_mode = prev_strict_params
	p.in_generator_params = prev_method_gen_params
	p.in_async_params = prev_method_async_params
	p.in_static_block = prev_static_block_mparams

	if !expect_token(p, .RParen) {
		return nil
	}

	// §15.4.3 / §15.4.4 / §15.4.5 — getter / setter arity + setter
	// parameter shape (rest / default initializer). Promoted from the
	// semantic checker to parser-side syntax errors in slice 15 because
	// these rules are structural per the grammar (a setter with rest can't
	// be a syntactically valid PropertySetParameterList). Matches OXC's
	// parser-only behavior and closes the class-accessor cluster of
	// oxc-only-rejects in the corpus.
	if kind == .Get || kind == .Set {
		key_loc: LexerLoc
		if key != nil {
			key_loc = LexerLoc(get_expression_loc(key).span.start)
		} else {
			key_loc = LexerLoc(start.span.start)
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
			report_error(p, "Type parameters cannot appear on a constructor declaration")
		}
		if _, has_return_type := method_return_type.?; has_return_type {
			report_error(p, "Type annotation cannot appear on a constructor declaration.")
		}
		if is_declare {
			report_error(p, "'declare' modifier cannot appear on a constructor declaration.")
		}
	}
	if is_declare && (kind == .Get || kind == .Set || kind == .Method) {
		report_error(p, "'declare' modifier cannot be used here.")
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
	                     (p.cur_tok.had_line_terminator || is_token(p, .RBrace))
	if (is_abstract || is_overload_sig) && is_token(p, .Semi) {
		// Decorators cannot appear on overload signatures or abstract methods.
		// §15.2.1 early error: it is a Syntax Error if ClassElementKind of
		// ClassElement is not Property and the ClassElement has a decorator.
		if len(decorators) > 0 && (is_overload_sig || is_abstract) {
			report_error(p, "A decorator can only decorate a method implementation, not an overload.")
		}
		match_semicolon_or_asi(p)
		// Leave body empty
	} else if is_ambient_method {
		// ASI / before-RBrace ambient method - don't consume any token,
		// the outer parse_class_element loop picks up where we left off.
		if len(decorators) > 0 {
			report_error(p, "A decorator can only decorate a method implementation, not an overload.")
		}
		// Body stays empty.
	} else {
		if p.in_ambient {
			report_error(p, "An implementation cannot be declared in ambient contexts")
		}
		// OXC reports abstract-with-body for non-constructor methods;
		// abstract constructors are accepted by OXC at parser level.
		if is_abstract && kind != .Constructor {
			name := class_element_prop_name(key)
			if name != "" {
				report_error(p, fmt.tprintf("Method '%s' cannot have an implementation because it is marked abstract.", name))
			} else {
				report_error(p, "Method cannot have an implementation because it is marked abstract.")
			}
		}
		// Parse body - set context flags
		prev_in_function := p.in_function
		prev_in_generator := p.in_generator
		prev_in_async := p.in_async
		prev_in_method := p.in_method
		prev_strict := p.strict_mode
		prev_in_derived_ctor := p.in_derived_constructor

		p.in_function = true
		p.in_generator = is_generator
		p.in_async = is_async
		// Class methods (including constructor / getter / setter) are
		// [[HomeObject]]-bearing contexts - `super.x` / `super[x]` is
		// lexically legal inside. Class bodies are ALSO implicitly strict
		// (ECMA-262 §15.7.3), so every method body parses under
		// strict-mode rules even without a `"use strict"` directive.
		p.in_method = true
		p.strict_mode = true
		// `super(...)` (SuperCall) is only legal in the instance constructor
		// of a class with `extends` (ECMA-262 §15.7.3). `static` methods
		// named `constructor` are ordinary static methods and don't qualify.
		p.in_derived_constructor = kind == .Constructor && !static_ && p.class_has_extends

		body = parse_function_body(p)

		p.in_function = prev_in_function
		p.in_generator = prev_in_generator
		p.in_async = prev_in_async
		p.in_method = prev_in_method
		p.strict_mode = prev_strict
		p.in_derived_constructor = prev_in_derived_ctor

		// Class methods always have UniqueFormalParameters; retro-check.
		// Pass strict_override=true because class bodies are implicitly
		// strict (§15.7.1) and the outer p.strict_mode has already been
		// restored above, so the strict-arm check needs the override to
		// actually fire on `class C { foo(a, a) {} }`.

		// §15.5.1 / §15.6.1 / §15.8.1 "ContainsUseStrict +
		// !IsSimpleParameterList" for class methods: enforced by the
		// semantic checker (ck_check_strict_directive_with_nonsimple_params).

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
				report_error(p, fmt.tprintf("Method '%s' cannot have an implementation because it is marked abstract.", name))
			} else {
				report_error(p, "Method cannot have an implementation because it is marked abstract.")
			}
		}
	}

	// §15.2.1.1 - BoundNames of FormalParameters vs LexicallyDeclaredNames.

	// Create the method as a FunctionExpression
	fn_expr := new_node(p, FunctionExpression)
	fn_expr.loc = paren_loc
	fn_expr.id = nil // Methods don't have names in their function expression
	fn_expr.params = params
	fn_expr.body = body
	fn_expr.generator = is_generator
	fn_expr.async = is_async
	fn_expr.type_parameters = method_type_parameters
	fn_expr.return_type = method_return_type
	fn_expr.loc.span.end = prev_end_offset(p)

	elem := new_node(p, ClassElement)
	elem.loc = start
	elem.key = key
	elem.value = expression_from(p, fn_expr)
	elem.kind = kind
	elem.computed = computed
	elem.static = static_
	elem.is_accessor = is_accessor
	elem.abstract = is_abstract
	elem.decorators = decorators
	elem.accessibility = accessibility
	elem.readonly = is_readonly
	elem.override_ = is_override

	elem.loc.span.end = prev_end_offset(p)
	return elem
}

// Parse ES2022 static block: static { ... }
parse_static_block :: proc(p: ^Parser, start: Loc) -> ^ClassElement {
	match_token(p, .Static) // consume static

	// Class static blocks run with the class as [[HomeObject]] - `super.x`
	// (class-static super) is legal inside. Save/restore so nested regular
	// functions inside still reset `in_method`.
	prev_in_method := p.in_method
	p.in_method = true
	defer p.in_method = prev_in_method
	// Static blocks are not constructors - `super(...)` is not legal here
	// even if the surrounding class has `extends`.
	prev_in_derived_ctor := p.in_derived_constructor
	p.in_derived_constructor = false
	defer p.in_derived_constructor = prev_in_derived_ctor
	// §15.7.5 - a static block is its own ClassStaticBlockBody function;
	// `new.target` and `return` are legal inside (§13.3.12 / §14.10).
	// Promote in_function so the new.target gate doesn't false-positive.
	// However, the static block is NOT a generator and NOT async - `yield`
	// and `await` from the enclosing function/generator do NOT propagate
	// (§15.7.5: ClassStaticBlockBody : ClassStaticBlockStatementList runs
	// under [~Yield, ~Await]). Reset both flags so a `function *g() {
	// class C { static { yield; } } }` correctly rejects the inner yield.
	prev_in_function_sb := p.in_function
	p.in_function = true
	defer p.in_function = prev_in_function_sb
	// Static block is a non-arrow function for new.target purposes.
	prev_in_non_arrow_sb := p.in_non_arrow_function
	p.in_non_arrow_function = true
	defer p.in_non_arrow_function = prev_in_non_arrow_sb
	prev_in_generator_sb := p.in_generator
	p.in_generator = false
	defer p.in_generator = prev_in_generator_sb
	prev_in_async_sb := p.in_async
	p.in_async = false
	defer p.in_async = prev_in_async_sb
	prev_in_static_block_sb := p.in_static_block
	p.in_static_block = true
	defer p.in_static_block = prev_in_static_block_sb
	// §15.7.5 - `break`/`continue` from the enclosing loop/switch do not
	// propagate into a static block. Reset the flags.
	prev_in_loop_sb := p.in_loop
	p.in_loop = false
	defer p.in_loop = prev_in_loop_sb
	prev_in_switch_sb := p.in_switch
	p.in_switch = false
	defer p.in_switch = prev_in_switch_sb
	// Class bodies (and therefore static blocks) are implicitly strict.
	prev_strict_sb := p.strict_mode
	p.strict_mode = true
	defer p.strict_mode = prev_strict_sb

	// Parse block statement. parse_block_statement returns a ^Statement
	// union wrapping a ^BlockStatement; extract the ^BlockStatement variant
	// via type assertion. The previous transmute read the union header as
	// if it were a BlockStatement struct - same UB class as Bug H, silently
	// zeroing `body` so static blocks emitted empty.
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
	static_block := new_node(p, FunctionExpression)
	static_block.loc = start
	static_block.id = nil
	static_block.params = make([dynamic]FunctionParameter, 0, 0, p.allocator)
	static_block.body = FunctionBody{
		loc = block.loc,
		body = block.body,
	}
	static_block.generator = false
	static_block.async = false
	static_block.loc.span.end = prev_end_offset(p)

	elem := new_node(p, ClassElement)
	elem.loc = start
	elem.key = nil  // Static blocks don't have a key
	elem.value = expression_from(p, static_block)
	elem.kind = .StaticBlock
	elem.computed = false
	elem.static = false  // Not marked as static - the kind implies it

	elem.loc.span.end = prev_end_offset(p)
	return elem
}

parse_variable_declaration :: proc(p: ^Parser, kind_override: Maybe(VariableKind), consume_semi: bool, in_for := false, is_declare := false) -> ^Statement {
	start := cur_loc(p)

	kind: VariableKind

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
			if k, ok := kind_override.(VariableKind); ok {
				kind = k
			} else {
				report_error(p, "Expected var, let, const, using, or await using")
				return nil
			}
		}
	case:
		if k, ok := kind_override.(VariableKind); ok {
			kind = k
		} else {
			report_error(p, "Expected var, let, or const")
			return nil
		}
	}

	eat(p)

	decl := new_node(p, VariableDeclaration)
	decl.loc = start
	decl.kind = kind
	// Cap bumped from 2 → 4 (S23). Most `var/let/const a = ...` are
	// single-declarator (~80%), but multi-declarator forms (`var a, b, c`)
	// triggered 1229 slow-path grows on monaco. cap=4 covers the long tail
	// without significant memory overhead.
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
		//
		// ASI for `let x\n/regex/`: after a complete VariableDeclarator with
		// no initializer, the next-line `/` cannot continue the declaration
		// as division (the binding has no value to divide). Per ASI rule 1
		// ("offending token is not allowed by any production"), insert a
		// semicolon. Relex the `/` as a regex so the next statement parses.
		// Test: babel/core/regression/2591/input.js (`let x\n/wow/;`).
		if p.cur_type == .Div && p.cur_tok.had_line_terminator {
			relex_as_regex(p.lexer)
			ft := p.lexer.cur
			p.cur_type = ft.kind
			p.cur_tok.type = ft.kind
			p.cur_tok.loc = LexerLoc(ft.start)
			p.cur_tok.raw_end = ft.end
			p.cur_tok.had_line_terminator = (ft.flags & FLAG_NEW_LINE) != 0
			if ft.kind == .RegularExpression {
				p.cur_tok.literal = p.lexer.cur_lit_value
			}
		}
		expect_semicolon_or_asi(p)
	}

	// ECMA-262 §14.3.1.1 - a LexicalDeclaration's BoundNames list must not
	// contain duplicates. `let x = 1, x = 2;` / `const a, b, a;` / using /
	// await-using are all SyntaxErrors; `var` is explicitly exempted
	// (B.3.3 "VarDeclaredNames of a Script may contain repeats").
	//
	// §14.3.1.1 also forbids BoundNames containing `"let"` for a
	// LexicalDeclaration - `let let;` / `const let;` are SyntaxErrors
	// in both strict and sloppy. The binding check lives here, not in
	// parse_binding_pattern, so `var let;` keeps working (B.3.4.4).
	if !is_declare && (kind == .Let || kind == .Const || kind == .Using || kind == .AwaitUsing) {
		// §14.3.1.1 `let` as lexically bound name: enforced by the
		// semantic checker (ck_check_var_decl_let_binding) for every
		// VariableDeclaration the walker visits.
	}

	// §Explicit Resource Management - `using` / `await using` create
	// runtime disposal state, so TS forbids them in ambient contexts
	// (`declare namespace`, `declare module`, and `.d.ts`).
	if kind == .Using || kind == .AwaitUsing {
		if is_declare || p.in_ambient || p.source_is_dts {
			kn := "using"
			if kind == .AwaitUsing { kn = "await using" }
			msg := fmt.tprintf("'%s' declarations are not allowed in ambient contexts.", kn)
			report_error(p, msg)
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
				report_error(p, msg)
			}
		}
		// §Explicit Resource Management placement: `using` / `await using`
		// are forbidden as a direct child of a CaseClause / DefaultClause
		// StatementList ("AwaitUsingDeclaration is contained directly
		// within the StatementList of either a CaseClause or DefaultClause").
		// They're allowed inside a sub-block within the case clause.
		if p.in_case_clause {
			kn := "using"
			if kind == .AwaitUsing { kn = "await using" }
			msg := fmt.tprintf("'%s' declaration is not allowed directly inside a switch case clause", kn)
			report_error(p, msg)
		}
	}

	// §14.3.3 `const` and §Explicit Resource Management `using` /
	// `await using` require an Initializer on every VariableDeclarator.
	// `const x;`, `using x;`, `await using x;` are all SyntaxErrors.
	// `in_for` skips the check so `for (const x of y)` / `for (using x
	// of y)` (where the binding is initialised by the loop iteration)
	// keeps working. `is_declare` for ambient TS (`declare const x;`)
	// also skips per TS rules. `let` allows no initializer.
	//
	// OXC's parser rejects missing initializers in normal TS/TSX files too.
	// Ambient forms (`declare const x;`, `.d.ts` sources) and for-of/in
	// declaration heads still skip because the value is supplied externally.
	if !is_declare && !p.in_ambient && !p.source_is_dts && !in_for && (kind == .Const || kind == .Using || kind == .AwaitUsing) {
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
					report_error(p, msg)
				}
			}
		}
	}

	// A destructuring declaration needs an initializer unless the binding is
	// supplied by a for-in/of head.
	if !is_declare && !p.in_ambient && !p.source_is_dts && !in_for {
		for d in decl.declarations {
			if _, have := d.init.(^Expression); have { continue }
			if _, is_ident := d.id.(^Identifier); !is_ident {
				report_error(p, "Missing initializer in destructuring declaration")
			}
		}
	}

	decl.loc.span.end = prev_end_offset(p)
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
//
// The "setter cannot have an initializer" rule is TYPESCRIPT-ONLY because
// the JS grammar (§15.4.5) routes through SingleNameBinding which permits
// `Initializer_opt`, so `set foo(v = null) {}` is legal JS (real-world
// example: three.js's Texture.image setter). Only the TS spec adds the
// extra restriction; OXC mirrors this gating, and we match here.
//
// Slice 15 (2026-05-07) promoted these checks from the semantic checker
// (formerly ck_check_accessor) to the parser, closing 14 of the 19
// OXC-corpus oxc-only-rejects (every class-accessor case).
//
// Diagnostic location convention matches OXC:
//   * arity errors anchor at the property key (so the underline lands on
//     `set foo` rather than `(`),
//   * setter param-shape errors anchor at the offending parameter.
//
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
			report_error_at(p, key_loc, "Getter must not have any formal parameters")
		}
		return
	}
	if real_n != 1 {
		report_error_at(p, key_loc, "Setter must have exactly one formal parameter")
		return
	}
	param := params[real_idx]
	param_loc := LexerLoc(param.loc.span.start)
	if _, is_rest := param.pattern.(^RestElement); is_rest {
		report_error_at(p, param_loc, "Setter parameter cannot be a rest element")
	}
	// TS-only: §15.4.5 + TS strictness forbid `set foo(v = ...) {}`. JS
	// permits it via SingleNameBinding's Initializer_opt; do not flag.
	if allow_ts_mode(p) {
		if _, has_default := param.default_val.(^Expression); has_default {
			report_error_at(p, param_loc, "A 'set' accessor cannot have an initializer.")
		}
	}
}

// NOTE — §15.2.1 StrictFormalParameters duplicate-name check
// (`report_duplicate_param_names`) and §14.3.1.1 per-LexicalDeclaration
// duplicate-name check (`report_duplicate_lexical_names`) were
// migrated to the semantic checker (ck_check_duplicate_param_names /
// ck_check_var_decl_lexical_dups) in slice 11; the parser-side stubs
// were deleted in the slice-13e cleanup once every call site was
// purged.

parse_variable_declarator :: proc(p: ^Parser, kind: VariableKind, in_for := false, is_declare := false) -> ^VariableDeclarator {
	start := cur_loc(p)

	pattern := parse_binding_pattern(p)

	// TS definite assignment assertion: `var x!: T`, `let y!: U[]`, etc.
	// The `!` appears between the binding pattern and the type annotation
	// `:` (NOT after the annotation, NOT before the `=` initializer). Same
	// `!:` syntax used on class fields, parsed identically there. Restricted
	// to plain Identifier bindings - TS spec disallows `!` on object/array
	// destructuring patterns. Closes ~50 OXC corpus rejects in the
	// "Expected '=', ',', or ';' after variable binding" cluster (S26 W6
	// phase 3 bug class #15).
	definite := false
	if is_token(p, .Not) {
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
	// pattern slot (S26 W4b) so `const {a}: Props = ...` and
	// `const [x]: T[] = ...` round-trip correctly. OXC also extends the
	// binding node's `end` over the annotation - mirror that here for
	// span parity (S26 W4d: 2 baseline divergences on tsx/002 and
	// typescript/015).
	has_type_ann := false
	if is_token(p, .Colon) && allow_ts_mode(p) {
		has_type_ann = true
		ann := parse_ts_type_annotation(p)
		#partial switch t in pattern {
		case ^Identifier:
			t.type_annotation = ann
			if ann != nil && ann.loc.span.end > t.loc.span.end {
				t.loc.span.end = ann.loc.span.end
			}
		case ^ObjectPattern:
			t.type_annotation = ann
			if ann != nil && ann.loc.span.end > t.loc.span.end {
				t.loc.span.end = ann.loc.span.end
			}
		case ^ArrayPattern:
			t.type_annotation = ann
			if ann != nil && ann.loc.span.end > t.loc.span.end {
				t.loc.span.end = ann.loc.span.end
			}
		}
	}

	// §14.3 / §14.7.5.1 - after the BindingIdentifier / BindingPattern
	// the only legal continuations are `=`, `,`, `;`, `in`, `of`, `)`,
	// `]`, `}`, EOF, or a line terminator (ASI). Anything else -
	// `var x += 1;`, `var x | y;`, `var x*1;`, `var x : T = ...` (TS, handled
	// above) - is a SyntaxError. Reporting here avoids the recovery path
	// silently swallowing the bad operator and salvaging a partial AST.
	if !p.cur_tok.had_line_terminator {
		#partial switch p.cur_type {
		case .Assign, .Comma, .Semi, .In, .Of,
		     .RParen, .RBracket, .RBrace, .EOF: // legal
		case:
			report_error(p, "Expected '=', ',', or ';' after variable binding")
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
				report_error(p, "Initializers are not allowed in ambient contexts.")
			}
		} else {
			if is_declare && has_type_ann {
				report_error(p, "Initializers are not allowed in ambient contexts.")
			} else if is_declare && kind != .Const {
				report_error(p, "Initializers are not allowed in ambient contexts.")
			} else if p.in_ambient && kind != .Const {
				report_error(p, "Initializers are not allowed in ambient contexts.")
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
			report_error(p, "Expected initializer expression after '='")
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
	decl.loc.span.end = prev_end_offset(p)

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
//
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
// when `p.strict_mode` is active.
is_strict_reserved_name :: #force_inline proc(name: string) -> bool {
	// Length range: implements=10, interface=9, protected=9, package=7,
	// private=7, public=6. Anything outside [6, 10] cannot match.
	//
	// First-letter gate: only `i` and `p` start any of these six words.
	// Real-world identifier names rarely start with `i` or `p`, so the
	// gate prunes the vast majority of calls to a single byte load + two
	// length compares. Only when the prefix matches do we run the actual
	// per-name compare.
	n := len(name)
	if n < 6 || n > 10 { return false }
	switch name[0] {
	case 'i':
		return name == "implements" || name == "interface"
	case 'p':
		return name == "package" || name == "private" ||
		       name == "protected" || name == "public"
	}
	return false
}

// `eval` and `arguments` are not keywords but are forbidden as binding
// identifiers in strict mode (ECMA-262 §13.1.1). The lexer emits them
// as plain .Identifier tokens, so the check happens on the string value.
is_eval_or_arguments :: #force_inline proc(name: string) -> bool {
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
	if p.in_ambient { return false }
	if p.in_async || p.in_async_params { return true }
	// §15.7.5 - class static blocks run under [~Await]; `await` is
	// a reserved word within ClassStaticBlockBody.
	if p.in_static_block { return true }
	// TS namespace / module body is NOT an async context. `await` is
	// an identifier there, even if the file is a module.
	if p.in_ts_namespace { return false }
	// ECMA-262 §13.1 says `await` is reserved when the goal symbol is
	// Module. V8 and Babel enforce this. OXC does NOT — it accepts
	// `export var await;`, `export function await() {}`, `let await = 1;`
	// in module top-level binding positions. Kessel's conformance oracle
	// is OXC (`parseSync` from npm `oxc-parser`), so we match OXC here.
	//
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
	return p.in_generator || p.in_generator_params || p.strict_mode
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
//
// Always-reserved keywords (if / var / return / function / ...) are
// rejected unconditionally. Strict-only FutureReservedWords (let /
// static / yield / implements / interface / package / private /
// protected / public) are rejected only when `p.strict_mode` is on.
// `yield` / `await` additionally flip to reserved inside a generator /
// async body even in sloppy mode. Non-reserved contextual keywords
// (async / of / from / as / let-in-sloppy / ...) pass through.
is_always_reserved_word_name :: #force_inline proc(name: string) -> bool {
	switch name {
	case "break", "case", "catch", "class", "const", "continue",
	     "debugger", "default", "delete", "do", "else", "enum",
	     "export", "extends", "false", "finally", "for", "function",
	     "if", "import", "in", "instanceof", "new", "null", "return",
	     "super", "switch", "this", "throw", "true", "try", "typeof",
	     "var", "void", "while", "with":
		return true
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
	if !p.cur_tok.has_escape { return }
	if p.cur_type != .Identifier { return }
	report_escaped_reserved_word_slow(p)
}

@(private="file")
report_escaped_reserved_word_slow :: proc(p: ^Parser) {
	name := p.cur_tok.value
	reserved := is_always_reserved_word_name(name)
	if !reserved && p.strict_mode {
		switch name {
		case "let", "static", "yield",
		     "implements", "interface", "package",
		     "private", "protected", "public":
			reserved = true
		}
	}
	if !reserved && p.in_generator && name == "yield" {
		reserved = true
	}
	if !reserved && name == "await" && await_is_reserved_here(p) {
		reserved = true
	}
	if reserved {
		msg := fmt.tprintf("Keyword '%s' must not contain escaped characters", name)
		report_error(p, msg)
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
// NOTE — the strict-mode parameter / assignment-target / update-target
// helper procs (`report_strict_param_names`, `report_strict_param_pattern`,
// `report_strict_eval_arguments_in_target`,
// `report_strict_update_on_eval_or_arguments`) were migrated to the
// semantic checker in slice 11 (ck_check_strict_param_pattern /
// ck_check_strict_binding_pattern / ck_check_strict_eval_arguments_in_target
// / ck_check_strict_update_eval_arguments) and the parser-side stubs
// were deleted in the slice-13e cleanup once every call site was
// purged.

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
//
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
			// `\0` alone is fine; `\0` followed by another digit is a
			// LegacyOctalEscapeSequence.
			if i + 2 < n {
				d := raw[i+2]
				if d >= '0' && d <= '9' { return true }
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
	// `start` was used by an earlier diagnostic path that no longer
	// exists; the leaf paths below all carry their own loc. Drop the
	// dead local; vet flags it as unused.
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
		report_error(p, msg)
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
	// enforced by the semantic checker (ck_check_strict_binding_pattern
	// via ck_walk_var_decl / ck_walk_function); the parser stays
	// permissive but still has to convert the strict-reserved-token
	// into an Identifier shape for the AST. Gate on p.strict_mode here
	// so sloppy code falls through to the contextual-yield / await /
	// identifier branches below (e.g. `var yield = 1` inside a sloppy
	// generator must reach the contextual `.Yield` branch and report a
	// structural error).
	if p.strict_mode && is_strict_reserved_word(p.cur_type) {
		id_loc := cur_loc(p)
		id_name := cur_value(p)
		eat(p)
		ident := new_node(p, Identifier)
		ident.loc = id_loc
		ident.name = id_name
		return ident
	}

	// Context-sensitive reserved words for bindings:
	//   * `yield` is reserved in a GeneratorBody / GeneratorDeclaration
	//     (ECMA-262 §13.2). `p.in_generator` carries exactly that
	//     context.
	//   * `await` is reserved in an AsyncFunction / AsyncGenerator /
	//     AsyncArrow / Module. We use `p.in_async` for the function
	//     forms; module top-level is covered by the caller that pins
	//     sourceType=module (future work).
	// Both tokens already have dedicated TokenTypes in Kessel's lexer,
	// so the check is a simple kind comparison.
	if (p.in_generator || p.in_generator_params) && p.cur_type == .Yield {
		report_error(p, "'yield' is reserved as a binding name inside a generator")
		id_loc := cur_loc(p)
		id_name := cur_value(p)
		eat(p)
		ident := new_node(p, Identifier)
		ident.loc = id_loc
		ident.name = id_name
		return ident
	}
	// Plain `await` lexes as TokenType.Await; only escaped forms
	// (`\u0061wait`) reach Identifier with cur_tok.value == "await". Gate
	// the string compare on has_escape so it stays off the hot path for
	// every ordinary identifier in a binding position.
	if (p.cur_type == .Await || (p.cur_type == .Identifier && p.cur_tok.has_escape && p.cur_tok.value == "await")) && await_is_reserved_here(p) {
		report_error(p, "'await' is reserved as a binding name in this context")
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
		//
		// has_escape == true takes the slow path via
		// `report_escaped_reserved_word(p)` already; we don't repeat the
		// full check here.
		if !p.cur_tok.has_escape && id_name == "enum" {
			msg := fmt.tprintf("'%s' is a reserved word and cannot be used as a binding identifier", id_name)
			report_error(p, msg)
		}
		eat(p)
		// §13.1.1 strict-mode `eval` / `arguments` and strict-reserved
		// FutureReservedWords (lex-as-Identifier forms) as a Binding
		// Identifier are SyntaxErrors. Enforced by the semantic checker
		// (ck_check_strict_binding_pattern via ck_walk_var_decl /
		// ck_walk_function); the parser stays permissive.
		ident := new_node(p, Identifier)
		ident.loc = id_loc
		ident.name = id_name
		return ident
	}

	report_error(p, "Expected binding pattern")
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
				report_error(p, "Expected identifier after ... in object pattern")
				return nil
			}
			rl := cur_loc(p); rn := cur_value(p)
			rest := new_node(p, RestElement)
			rest.loc = prop_start
			rest_ident := new_node(p, Identifier)
			rest_ident.loc = rl
			rest_ident.name = rn
			rest.argument = rest_ident
			rest.loc.span.end = rl.span.end
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
				report_error(p, "Rest element must be last in object pattern")
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
			prev_no_in_op := p.no_in
			p.no_in = false
			expr_key := parse_assignment_expression(p)
			p.no_in = prev_no_in_op
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
			current := get_current(p)
			str_lit := new_node(p, StringLiteral)
			str_lit.loc = loc_from_token(&current)
			str_lit.value = current.literal.(string) or_else ""
			str_lit.raw = current.value
			str_lit.loc.span.end = cur_offset(p) + u32(len(current.value))
			key = str_lit
			eat(p)
			// String-literal keys require `:` — they cannot be shorthand.
			// `{ "while" }` is invalid; must be `{ "while": binding }`.
			if !is_token(p, .Colon) {
				report_error(p, "Expected ':' after string property key in destructuring pattern")
			}
		} else if is_token(p, .Number) {
			// Numeric key: `{ 0: v, 1: w }` (§14.3.3 PropertyName :
			// NumericLiteral path). Must be followed by `:` - numeric
			// keys don't support shorthand.
			current := get_current(p)
			num_lit := new_node(p, NumericLiteral)
			num_lit.loc = loc_from_token(&current)
			num_lit.raw = current.value
			if v, ok := current.literal.(f64); ok {
				num_lit.value = v
			}
			num_lit.loc.span.end = cur_offset(p) + u32(len(current.value))
			key = num_lit
			eat(p)
		} else if is_token(p, .BigInt) {
			// BigInt key: `{ 1n: v }` - same as numeric. Must be followed
			// by `:`. Stored as ^Expression (the computed-key variant of
			// the union) since ObjectPatternPropertyKey doesn't include
			// BigIntLiteral directly. ESTree emit treats BigIntLiteral
			// like other Literal kinds.
			current := get_current(p)
			big := new_node(p, BigIntLiteral)
			big.loc = loc_from_token(&current)
			big.raw = current.value
			if len(current.value) > 0 && current.value[len(current.value)-1] == 'n' {
				big.value = current.value[:len(current.value)-1]
			} else {
				big.value = current.value
			}
			big.loc.span.end = cur_offset(p) + u32(len(current.value))
			key = (^Expression)(expression_from(p, big))
			eat(p)
		} else if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
			// Identifier or keyword used as key. When the property becomes
			// a shorthand binding (`{ foo }` = `{ foo: foo }`), the key
			// doubles as a BindingIdentifier - escaped-ReservedWord
			// (§12.7.2) must reject. Capture has_escape now, report below
			// only if the property ends up shorthand (explicit `key: val`
			// / `key = init` forms make the key an IdentifierName position,
			// where escapes stay legal).
			key_had_escape := p.cur_tok.has_escape
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
					report_error(p, msg)
				}
			}
		} else {
			report_error(p, "Expected property key in object pattern")
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
					msg := fmt.tprintf(
						"Identifier expected. '%s' is a reserved word that cannot be used here.",
						cur_value(p),
					)
					report_error(p, msg)
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
					prev_no_in := p.no_in; p.no_in = false
					default_val := parse_assignment_expression(p)
					p.no_in = prev_no_in
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
					assign.loc.span.end = prev_end_offset(p)

					prop := ObjectPatternProperty{
						loc       = prop_start,
						key       = key,
						value     = assign,
						computed  = computed,
						shorthand = false,
					}
					prop.loc.span.end = prev_end_offset(p)
					bump_append(&obj.properties, prop)
				} else {
					prop := ObjectPatternProperty{
						loc       = prop_start,
						key       = key,
						value     = value_ident,
						computed  = computed,
						shorthand = false,
					}
					prop.loc.span.end = value_ident.loc.span.end
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
					prev_no_in := p.no_in; p.no_in = false
					default_val := parse_assignment_expression(p)
					p.no_in = prev_no_in
					assign := new_node(p, AssignmentPattern)
					// Same LHS-start rule as the identifier case above - the
					// nested pattern's own span is the start of the
					// AssignmentPattern, not the outer property's key.
					assign.loc = get_pattern_loc(nested)
					assign.left = nested
					assign.right = default_val
					assign.loc.span.end = prev_end_offset(p)
					val = assign
				}
				prop := ObjectPatternProperty{
					loc       = prop_start,
						key       = key,
					value     = val,
					computed  = computed,
						shorthand = false,
				}
				prop.loc.span.end = prev_end_offset(p)
				bump_append(&obj.properties, prop)
			} else if is_token(p, .LBracket) {
				// Nested array pattern (possibly with default)
				nested := parse_array_pattern(p)
				if nested == nil {
					return nil
				}
				val: Pattern = nested
				if match_token(p, .Assign) {
					prev_no_in := p.no_in; p.no_in = false
					default_val := parse_assignment_expression(p)
					p.no_in = prev_no_in
					assign := new_node(p, AssignmentPattern)
					// Same LHS-start rule - see nested-object case above.
					assign.loc = get_pattern_loc(nested)
					assign.left = nested
					assign.right = default_val
					assign.loc.span.end = prev_end_offset(p)
					val = assign
				}
				prop := ObjectPatternProperty{
					loc       = prop_start,
					key       = key,
					value     = val,
					computed  = computed,
					shorthand = false,
				}
				prop.loc.span.end = prev_end_offset(p)
				bump_append(&obj.properties, prop)
			} else {
				report_error(p, "Expected pattern in object pattern value")
				return nil
			}
		} else if match_token(p, .Assign) {
			// { key = defaultValue } - shorthand with default
			prev_no_in := p.no_in; p.no_in = false
			default_val := parse_assignment_expression(p)
			p.no_in = prev_no_in
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
						report_error(p, msg)
					}
					left_ident := new_node(p, Identifier)
					left_ident.loc = v.loc
					left_ident.name = v.name
					assign := new_node(p, AssignmentPattern)
					// Shorthand: prop_start == v.loc.span.start in practice
					// (the key IS the LHS), but spell it out through
					// left_ident.loc to stay consistent with the other three
					// AssignmentPattern sites in parse_object_pattern.
					assign.loc = left_ident.loc
					assign.left = left_ident
					assign.right = default_val
					assign.loc.span.end = prev_end_offset(p)

					prop := ObjectPatternProperty{
						loc       = prop_start,
						key       = key,
						value     = assign,
						computed  = computed,
						shorthand = true,
					}
					prop.loc.span.end = prev_end_offset(p)
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
						report_error(p, msg)
					}
					// `yield` is reserved in generator bodies; `await` in async.
					if v.name == "yield" && yield_is_reserved_here(p) {
						report_error(p, "'yield' is reserved as a binding name inside a generator")
					}
					if v.name == "await" && await_is_reserved_here(p) {
						report_error(p, "'await' is reserved as a binding name inside an async function")
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
					prop.loc.span.end = left_ident.loc.span.end
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

	obj.loc.span.end = prev_end_offset(p)
	return obj
}

// Helper to create identifier from token info
new_identifier :: proc(p: ^Parser, tok: Token) -> ^Identifier {
	tok := tok  // re-bind to a mutable local; Odin parameters aren't addressable
	ident := new_node(p, Identifier)
	ident.loc = loc_from_token(&tok)
	ident.name = tok.value
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
					msg := fmt.tprintf(
						"Identifier expected. '%s' is a reserved word that cannot be used here.",
						cur_value(p),
					)
					report_error(p, msg)
				}
				arl := cur_loc(p); arn := cur_value(p)
				eat(p)
				rest_ident := new_node(p, Identifier)
				rest_ident.loc = arl
				rest_ident.name = arn
				rest.argument = rest_ident
			} else {
				report_error(p, "Expected identifier or pattern after ... in array pattern")
				return nil
			}
			rest.loc.span.end = prev_end_offset(p)

			bump_append(&elements, Maybe(Pattern)(rest))

			// Rest element must be last - and cannot take an Initializer
			// (§14.3.3: no `= default` on BindingRestElement).
			if !is_token(p, .RBracket) && !is_token(p, .EOF) {
				report_error(p, "Rest element must be last in array pattern")
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
			if (p.cur_type == .Await || (p.cur_type == .Identifier && p.cur_tok.has_escape && p.cur_tok.value == "await")) &&
			   await_is_reserved_here(p) {
				report_error(p, "'await' is reserved as a binding name in this context")
			}
			if (p.cur_type == .Yield || (p.cur_type == .Identifier && p.cur_tok.has_escape && p.cur_tok.value == "yield")) &&
			   yield_is_reserved_here(p) {
				report_error(p, "'yield' is reserved as a binding name in this context")
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
				prev_no_in := p.no_in; p.no_in = false
				default_val := parse_assignment_expression(p)
				p.no_in = prev_no_in
				assign := new_node(p, AssignmentPattern)
				assign.loc = eil
				assign.left = ident
				assign.right = default_val
				assign.loc.span.end = prev_end_offset(p)
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
				prev_no_in := p.no_in; p.no_in = false
				default_val := parse_assignment_expression(p)
				p.no_in = prev_no_in
				assign := new_node(p, AssignmentPattern)
				assign.loc = get_pattern_loc(nested)
				assign.left = nested
				assign.right = default_val
				assign.loc.span.end = prev_end_offset(p)
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
				prev_no_in := p.no_in; p.no_in = false
				default_val := parse_assignment_expression(p)
				p.no_in = prev_no_in
				assign := new_node(p, AssignmentPattern)
				assign.loc = get_pattern_loc(nested)
				assign.left = nested
				assign.right = default_val
				assign.loc.span.end = prev_end_offset(p)
				val = assign
			}
			bump_append(&elements, Maybe(Pattern)(val))
		} else {
			report_error(p, "Expected pattern in array pattern")
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
	arr.loc.span.end = prev_end_offset(p)
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
								bump_append(&decl_offs, decl.loc.span.start)
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
							// skip
						} else if id, ok := d.id.(BindingIdentifier); ok {
							bump_append(&decl_names, id.name)
							bump_append(&decl_offs, id.loc.span.start)
						}
					}
				case ^ClassDeclaration:
					if d != nil {
						if id, ok := d.id.(BindingIdentifier); ok {
							bump_append(&decl_names, id.name)
							bump_append(&decl_offs, id.loc.span.start)
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
							report_error_at(p, LexerLoc(off), msg)
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
					var_off = exported_name.loc.span.start
				case ^StringLiteral:
					if exported_name != nil {
						var_name = exported_name.value
						var_off = exported_name.loc.span.start
					}
				}
				if var_name != "" {
					if _, exists := scope_map_get(&exported, var_name); exists {
						if !allow_ts_mode(p) {
							msg := fmt.tprintf("Duplicate exported name '%s'", var_name)
							report_error_at(p, LexerLoc(var_off), msg)
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
			// rather than a syntax error - OXC and Babel both accept the
			// duplicate. Skip the syntactic flag in TS / TSX modes.
			if allow_ts_mode(p) { continue }
			if _, exists := scope_map_get(&exported, "default"); exists {
				report_error(p, "Duplicate exported name 'default'")
			} else { scope_map_set(&exported, "default", v.loc.span.start) }
		case ^ExportAllDeclaration:
			if v == nil { continue }
			// `export * as name from "m"` adds `name` to ExportedNames.
			if ns_name, has_ns := v.exported.(IdentifierName); has_ns {
				if _, exists := scope_map_get(&exported, ns_name.name); exists {
					if !allow_ts_mode(p) {
						msg := fmt.tprintf("Duplicate exported name '%s'", ns_name.name)
						report_error_at(p, LexerLoc(ns_name.loc.span.start), msg)
					}
				} else { scope_map_set(&exported, ns_name.name, ns_name.loc.span.start) }
			}
		}
	}
	// §16.2.2 "Export 'X' is not defined in the module" early error
	// is now enforced by the semantic checker (ck_check_export_local_defined).
	// The string-literal-without-from rule remains structural and is
	// reported here.
	for stmt in program.body {
		if stmt == nil { continue }
		export, is_export := stmt^.(^ExportNamedDeclaration)
		if !is_export || export == nil { continue }
		if _, from_source := export.source.(StringLiteral); from_source { continue }
		for spec in export.specifiers {
			if strlit, is_str := spec.local.(^StringLiteral); is_str && strlit != nil {
				err := ParseError{
					loc = LexerLoc(strlit.loc.span.start),
					message = "A string literal cannot be used as an exported binding without `from`",
				}
				bump_append(&p.errors, err)
			}
		}
	}
}

// ============================================================================
// OPT-6 - minimal scope / binding verification pass.
//
// ECMA-262 §14.2 / §14.3 / §16.1.1 LexicallyDeclaredNames rules: a
// LexicalDeclaration (let / const / class / function / import / using)
// cannot re-declare a name already bound in the same lexical scope, and
// a VariableStatement's BoundNames cannot clash with an enclosing
// lexically-bound name in the same scope.
//
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
@(private="file")
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

// scope_emit — forwards a scope-clash diagnostic to the active
// semantic checker. The caller passes the checker pointer explicitly
// (no parser-side bridge field) so the parser stays free of any
// reference to the checker. Nil c is a silent no-op (matches the
// ast-only / no-checker invocation paths).
scope_emit :: #force_inline proc(c: ^Checker, at: u32, message: string) {
	checker_append_error(c, LexerLoc(at), message)
}

scope_add :: proc(c: ^Checker, lex, vars: ^ScopeMap, name: string, at: u32, kind: ScopeBindingKind) {
	switch kind {
	case .Lexical:
		if _, have := scope_map_get(lex, name); have {
			scope_emit(c, at, fmt.tprintf("'%s' has already been declared", name))
			return
		}
		if _, have := scope_map_get(vars, name); have {
			scope_emit(c, at, fmt.tprintf("Identifier '%s' has already been declared", name))
		}
		scope_map_set(lex, name, at)
	case .Var:
		if _, have := scope_map_get(lex, name); have {
			scope_emit(c, at, fmt.tprintf("Identifier '%s' has already been declared", name))
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
				scope_emit(c, at, fmt.tprintf("'%s' has already been declared", name))
			}
			return
		}
		if _, have := scope_map_get(vars, name); have {
			// var-from-real-var before us. `{ var f; function f(){} }`
			// in sloppy rejects per Acorn / V8.
			scope_emit(c, at, fmt.tprintf("Identifier '%s' has already been declared", name))
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
			scope_map_set_first(vars, n, v.loc.span.start)
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

// Process one Statement and add its contributing lexical/var BoundNames
// to the scope maps. Nested scopes are NOT recursed here - the caller's
// walker handles that separately.
scope_process_statement :: proc(p: ^Parser, c: ^Checker, stmt: ^Statement, lex, vars: ^ScopeMap, is_block_scope: bool = false) {
	if stmt == nil { return }
	#partial switch v in stmt^ {
	case ^VariableDeclaration:
		if v == nil { return }
		kind: ScopeBindingKind = .Var
		if v.kind != .Var { kind = .Lexical }
		names := make([dynamic]string, 0, 4, context.temp_allocator)
		for decl in v.declarations { scope_collect_pattern(decl.id, &names) }
		for n in names { scope_add(c, lex, vars, n, v.loc.span.start, kind) }
	case ^BlockStatement:
		// §14.2.1 - Hoist `var` VarDeclaredNames from nested blocks into this
		// scope so lex/var clashes like `{ { var f; } let f; }` are detected.
		if v == nil { return }
		// Use a temporary vars map to collect only the hoisted var names,
		// then call scope_add for each so clash detection runs.
		hoisted := scope_map_make(4)
		for inner in v.body { scope_hoist_vars(p, inner, &hoisted) }
		for it in hoisted.items { scope_add(c, lex, vars, it.name, it.at, .Var) }
	case ^FunctionDeclaration:
		if v == nil { return }
		// TS overload signature (no `{ ... }` body): emits NO binding for
		// scope-clash purposes. Multiple overloads + one impl all share a
		// single name without colliding. Same relaxation applies to
		// `declare function` regardless of body shape.
		if allow_ts_mode(p) && (v.no_body || v.declare) {
			return
		}
		if id, ok := v.id.(BindingIdentifier); ok {
			// Annex B.3.2 / §14.1.3:
			//   - strict mode: FunctionDeclaration BoundName is always
			//     lexical.
			//   - sloppy async / generator / async-generator: always
			//     lexical (they don't qualify for B.3.2).
			//   - sloppy plain FunctionDeclaration in a BLOCK scope:
			//     .FunctionAnnexB - sibling dups legal (B.3.3), mixed
			//     let/const/class/var collisions error (§14.2.1).
			//   - sloppy plain FunctionDeclaration at function / Script
			//     Program scope: .Var - var-hoisted; clashes with same-
			//     name var are legal per long-standing convention.
			kind: ScopeBindingKind = .Lexical
			if !p.strict_mode && !v.async && !v.generator {
				if is_block_scope {
					kind = .FunctionAnnexB
				} else {
					kind = .Var
				}
			}
			scope_add(c, lex, vars, id.name, id.loc.span.start, kind)
		}
	case ^ClassDeclaration:
		if v == nil { return }
		if id, ok := v.id.(BindingIdentifier); ok {
			scope_add(c, lex, vars, id.name, id.loc.span.start, .Lexical)
		}
	case ^ImportDeclaration:
		if v == nil { return }
		for spec in v.specifiers {
			if spec == nil { continue }
			switch ss in spec^ {
			case ImportSpecifier:
				scope_add(c, lex, vars, ss.local.name, ss.local.loc.span.start, .Lexical)
			case ImportDefaultSpecifier:
				scope_add(c, lex, vars, ss.local.name, ss.local.loc.span.start, .Lexical)
			case ImportNamespaceSpecifier:
				scope_add(c, lex, vars, ss.local.name, ss.local.loc.span.start, .Lexical)
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
				for n in names { scope_add(c, lex, vars, n, inner.loc.span.start, kind) }
			case ^FunctionDeclaration:
				if inner == nil { break }
				// TS overload signature / `declare function` - see
				// scope_process_statement's plain-FunctionDeclaration arm
				// for the rationale.
				if allow_ts_mode(p) && (inner.no_body || inner.declare) {
					break
				}
				if id, ok := inner.id.(BindingIdentifier); ok {
					scope_add(c, lex, vars, id.name, id.loc.span.start, .Lexical)
				}
			case ^ClassDeclaration:
				if inner == nil { break }
				if id, ok := inner.id.(BindingIdentifier); ok {
					scope_add(c, lex, vars, id.name, id.loc.span.start, .Lexical)
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
		if v == nil { return }
		if d := v.declaration; d != nil {
			#partial switch inner in d^ {
			case ^Declaration:
				if inner != nil {
					#partial switch decl in inner^ {
					case ^FunctionDeclaration:
						if decl != nil {
							if id, ok := decl.id.(BindingIdentifier); ok {
								scope_add(c, lex, vars, id.name, id.loc.span.start, .Lexical)
							}
						}
					case ^ClassDeclaration:
						if decl != nil {
							if id, ok := decl.id.(BindingIdentifier); ok {
								scope_add(c, lex, vars, id.name, id.loc.span.start, .Lexical)
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
								scope_add(c, lex, vars, id.name, id.loc.span.start, .Lexical)
							}
						}
					case ^ClassExpression:
						if fn != nil {
							if id, ok := fn.id.(BindingIdentifier); ok {
								scope_add(c, lex, vars, id.name, id.loc.span.start, .Lexical)
							}
						}
					}
				}
			}
		}
	}
}

// Process a single body's lex / var bindings against fresh ScopeMap pairs.
// Replaces scope_verify_body's first half. The recursive second half
// (scope_recurse / scope_recurse_expr / scope_recurse_class_elements) is
// gone: every scope-bearing body now self-registers into p.scope_pending
// at parse time, and verify_scopes drains that queue directly.
//
// is_block_scope=true is the default for genuine BlockStatement / catch /
// finally / switch case-list scopes (Annex B.3.2 sloppy plain
// FunctionDecl follows the hybrid .FunctionAnnexB kind). false for
// FunctionBody / ArrowFunction block body / static-block bodies
// (function-scope; sloppy plain FunctionDecl hoists as .Var).
//
// Takes pre-allocated ScopeMap pointers so the caller (verify_scopes) can
// pool a single pair across all bodies. Clearing two dynamic-array headers
// (resize to 0, cap retained) and a possibly-allocated spill map per body
// is far cheaper than allocating fresh maps for every entry - on real
// bundles like antd.js that's 3,994 × 2 saved allocations.
scope_check_body :: #force_inline proc(p: ^Parser, c: ^Checker, body: []^Statement, is_block_scope: bool, lex, vars: ^ScopeMap) {
	for stmt in body {
		scope_process_statement(p, c, stmt, lex, vars, is_block_scope)
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

// NOTE — §15.2.1.1 / §15.5.1 formal-parameter vs body let/const
// redeclaration check (`check_params_vs_body_lex`) was migrated to
// the semantic checker (ck_check_params_vs_body_lex) in slice 13c
// and the parser-side stub was deleted in the slice-13e cleanup once
// every call site was purged.

// verify_scopes runs the lex/var clash check across every scope-bearing
// body in the program. The Program-level body is processed first, then
// every entry in p.scope_pending (queued at parse-EXIT by parse_function_body /
// parse_block_statement / parse_switch_statement; static-block and
// arrow-block bodies are re-stamped via mark_last_scope_function_scope).
//
// Each scope is verified independently with a fresh ScopeMap pair, so the
// iteration order doesn't affect correctness. We sort by start_offset
// before iterating so error messages surface in source order - parse-exit
// push order is innermost-first within a parent, which matches source
// only for left-to-right siblings, not for nested-vs-following-sibling.
// NOTE — the parser-side `verify_scopes` proc was deleted in slice 14
// once the semantic checker took over the AST walk. Each scope-bearing
// body is now visited by the checker's recursive walker (ck_walk_stmt /
// ck_walk_function / ck_walk_expr ArrowFunctionExpression / etc.) and
// the parser's `scope_check_body` is invoked from those entry points
// directly. The `scope_pending` queue, the parse-exit pushes that fed
// it, and the ScopePending struct are gone. See checker.odin's
// `ck_run_scope_check` for the new entry.

// =========================================================================
// §15.7.3 AllPrivateIdentifiersValid — migrated to checker.odin
// (ck_check_private_name_resolved + ck_walk_class private-name stack).
// =========================================================================

// Helper: Convert ExportSpecifierName to ESMExportNameEntry
convert_export_spec_name :: proc(name: ExportSpecifierName) -> ESMExportNameEntry {
	#partial switch n in name {
	case IdentifierName:
		return ESMExportNameEntry{
			kind = .Name,
			name = n.name,
			start = n.loc.span.start,
			end = n.loc.span.end,
		}
	case ^StringLiteral:
		return ESMExportNameEntry{
			kind = .Name,
			name = n.value,
			start = n.loc.span.start,
			end = n.loc.span.end,
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
			start = s.local.loc.span.start,
			end = s.local.loc.span.end,
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
			start = s.local.loc.span.start,
			end = s.local.loc.span.end,
		}
	case ImportSpecifier:
		// import { x, y as z } from "m"
		entry.importName = ESMNameEntry{
			kind = .Name,
			name = s.imported.name,
			start = s.imported.loc.span.start,
			end = s.imported.loc.span.end,
		}
		entry.localName = ESMNameEntry{
			kind = .Name,
			name = s.local.name,
			start = s.local.loc.span.start,
			end = s.local.loc.span.end,
		}
	}
	return entry
}

// append_import_spec promotes a ^ImportSpecifier / ^ImportDefaultSpecifier /
// ^ImportNamespaceSpecifier to a ^ImportSpecifierSpec (union) via assignment,
// so the union variant tag is written correctly. Directly casting the
// pointer `(^ImportSpecifierSpec)(spec)` preserves the address but not the
// tag - the emitter's `switch v in spec_ptr^` then falls through to no
// matching case and emits `{}`. Same union-cast bug class as the Statement/
// Declaration fix in print_declaration_ast.
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
	restore_module_syntax := p.in_ts_namespace
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
	if p.cur_type == .Identifier && p.cur_tok.value == "defer" {
		if p.lexer != nil && p.lexer.nxt.kind == .Mul {
			decl.phase = "defer"
			eat(p) // consume `defer`
		}
	} else if p.cur_type == .Identifier && p.cur_tok.value == "source" {
		if p.lexer != nil && p.lexer.nxt.kind == .Identifier {
			decl.phase = "source"
			eat(p) // consume `source`
		} else if p.lexer != nil && p.lexer.nxt.kind == .From {
			snap := lexer_snapshot(p)
			eat(p) // consume `source`
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
	if p.cur_type == .Identifier && p.cur_tok.value == "type" && allow_ts_mode(p) {
		// §12.7.2 - contextual keyword `type` must not use Unicode escapes.
		has_esc := p.cur_tok.has_escape
		nxt := p.lexer.nxt.kind
		if nxt == .LBrace || nxt == .Mul {
			if has_esc { report_error(p, "Keyword 'type' must not contain escaped characters") }
			decl.import_kind = .Type
			eat(p) // consume `type`
		} else if nxt == .Identifier || nxt == .From {
			// Could be `import type Foo from "m"` (type-only default) or
			// `import type from "m"` (default import of "type"). Only flag as
			// type-only when the identifier after `type` is NOT `from`.
			// Exception: `import type from from "m"` — the first `from` is
			// the binding name and `type` is the type-only keyword. Detect
			// via 3-token lookahead: if nxt="from" and nxt+1="from", it's
			// the type-only form. Matches OXC.
			nxt_val := p.lexer.source[p.lexer.nxt.start:p.lexer.nxt.end]
			if nxt_val != "from" {
				if has_esc { report_error(p, "Keyword 'type' must not contain escaped characters") }
				decl.import_kind = .Type
				eat(p) // consume `type`
			} else {
				// nxt is "from" — check if the token AFTER that is also "from".
				snap_tf := lexer_snapshot(p)
				advance_token(p) // consume `type` → cur="from" (binding)
				advance_token(p) // consume "from" → cur=third token
				// `import type from from "m"` or `import type from = require(...)`
				third_is_from := p.cur_type == .From ||
				                 (p.cur_type == .Identifier && p.cur_tok.value == "from") ||
				                 p.cur_type == .Assign
				lexer_restore(p, snap_tf)
				if third_is_from {
					if has_esc { report_error(p, "Keyword 'type' must not contain escaped characters") }
					decl.import_kind = .Type
					eat(p) // consume `type`
				}
			}
		}
	}

	// TS `import X = ...` / `import type X = ...` (TSImportEqualsDeclaration).
	// Detect by `Identifier` followed by `=`. The `import type X = ...` form is
	// also legal (type-only import-equals). Closes 291 kessel-only-rejects in
	// the OXC corpus (S26 W6 phase 3 bug class #4) - the largest single bug
	// cluster, all reporting "Expected from, got =" pre-fix.
	// Check for TS import-equals: `import X = ...`. Also handles
	// `import await = ...` (await as binding name in non-module).
	if allow_ts_mode(p) && (p.cur_type == .Identifier || p.cur_type == .Await ||
	   p.cur_type == .Yield || p.cur_type == .From) &&
	   p.lexer != nil && p.lexer.nxt.kind == .Assign {
		return parse_ts_import_equals(p, start, decl.import_kind)
	}

	// Past the TS-import-equals fork — this IS an ES ImportDeclaration.
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
			   p.cur_type == .Identifier && p.cur_tok.value == "type" {
				// `import type { type ... }` — distinguish `type` as the
				// imported NAME from `type` as an inline-type MODIFIER.
				// When followed by `as <ident>` or `,` or `}`, `type` is
				// the name being imported (valid). When followed by another
				// identifier (not `as`), `type` is a modifier (invalid in
				// type-only imports). Matches OXC.
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
					report_error(p, "The 'type' modifier cannot be used in a type-only import")
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
			report_error(p, "Expected string literal module specifier")
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
		spec := new_node(p, ImportNamespaceSpecifier)
		spec.loc = star_loc
		spec.local = BindingIdentifier{
			loc  = local.loc,
			name = local.name,
		}
		spec.loc.span.end = prev_end_offset(p)
		append_import_spec(&decl.specifiers, spec, p.allocator)

		if !expect_token(p, .From) {
			return nil
		}

		if !is_token(p, .String) {
			report_error(p, "Expected string literal module specifier")
		}
		decl.source = parse_string_literal(p)
	} else if is_token(p, .Identifier) || can_be_binding_identifier(p.cur_type) {
		// Default import: import name from "module" or import name, { x } from "module"
		// `await`, `yield`, `let` etc. are valid binding names in import context.
		local := parse_identifier(p)
		spec := new_node(p, ImportDefaultSpecifier)
		spec.loc = local.loc
		spec.local = BindingIdentifier{
			loc  = local.loc,
			name = local.name,
		}
		spec.loc.span.end = prev_end_offset(p)
		append_import_spec(&decl.specifiers, spec, p.allocator)

		// Check for comma followed by named imports
		if match_token(p, .Comma) {
			if decl.import_kind == .Type {
				report_error(p, "A type-only import cannot combine default and named bindings")
			}
			if is_token(p, .From) {
				report_error(p, "Expected import specifier after comma")
			} else if is_token(p, .LBrace) {
				eat(p) // consume {

				for !is_token(p, .RBrace) && !is_token(p, .EOF) {
					if decl.import_kind == .Type && allow_ts_mode(p) &&
					   p.cur_type == .Identifier && p.cur_tok.value == "type" {
						// Same disambiguation as the primary named-import loop above.
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
							report_error(p, "The 'type' modifier cannot be used in a type-only import")
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
				ns_spec.loc.span.end = prev_end_offset(p)
				append_import_spec(&decl.specifiers, ns_spec, p.allocator)
			}
		}

		if !expect_token(p, .From) {
			return nil
		}

		if !is_token(p, .String) {
			report_error(p, "Expected string literal module specifier")
		}
		decl.source = parse_string_literal(p)
	} else if allow_ts_mode(p) {
		report_error(p, "Expected import source or specifier")
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
				report_error(p, msg)
				break
			}
		}
	}

	decl.loc.span.end = prev_end_offset(p)

	// Collect ESM static import record
	p.has_module_syntax = true
	if len(decl.specifiers) > 0 {
		esm_import := ESMStaticImport{
			start = decl.loc.span.start,
			end = decl.loc.span.end,
			moduleRequest = {
				value = decl.source.value,
				start = decl.source.loc.span.start,
				end = decl.source.loc.span.end,
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
//
// Module reference shapes (TypeScript 5 grammar):
//   * `Identifier`              - simple alias               (id)
//   * `Identifier (`.` Identifier)+` - qualified entity name (member chain)
//   * `require ( StringLiteral )` - external module reference
//
// We store the entity-name forms as a plain ^Expression (Identifier or
// MemberExpression chain) and let the emitter fold member chains into the
// ESTree TSQualifiedName shape - same trick parse_ts_module_declaration
// uses for `namespace A.B.C { ... }` ids.
parse_ts_import_equals :: proc(p: ^Parser, start: Loc, import_kind: ImportExportKind) -> ^Statement {
	decl := new_node(p, TSImportEqualsDeclaration)
	decl.loc = start
	decl.import_kind = import_kind

	// Binding identifier.
	id_loc := cur_loc(p)
	id_name := cur_value(p)
	decl.id = Identifier{loc = id_loc, name = id_name}
	// `await` as binding in import-equals is forbidden in module code.
	if (p.cur_type == .Await || id_name == "await") && await_is_reserved_here(p) {
		report_error(p, "Cannot use 'await' as an identifier in module code")
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
	if p.cur_type == .Identifier && p.cur_tok.value == "module" &&
	   p.lexer != nil && p.lexer.nxt.kind == .LParen {
		report_error(p, "'module(...)' in import-equals is not supported; use 'require(...)' instead")
		// Consume `module("...")` for recovery.
		eat(p) // module
		eat(p) // (
		if is_token(p, .String) { eat(p) } // "..."
		if is_token(p, .RParen) { eat(p) } // )
		match_semicolon_or_asi(p)
		decl.loc.span.end = prev_end_offset(p)
		return statement_from(p, decl)
	}
	if p.cur_type == .Identifier && p.cur_tok.value == "require" &&
	   p.lexer != nil && p.lexer.nxt.kind == .LParen {
		req_start := cur_loc(p)
		eat(p)  // consume `require`
		if !expect_token(p, .LParen) { return nil }
		if !is_token(p, .String) {
			report_error(p, "Expected string literal in require() module reference")
			return nil
		}
		str := parse_string_literal(p)
		str_ptr := new_node(p, StringLiteral)
		str_ptr^ = str
		if !expect_token(p, .RParen) { return nil }
		ext := new_node(p, TSExternalModuleReference)
		ext.loc = req_start
		ext.expression = str_ptr
		ext.loc.span.end = prev_end_offset(p)
		decl.module_reference = ext
	} else {
		// Entity-name chain: parse a primary identifier, then any `.id` tail.
		// Mirrors parse_member_expr's non-computed dot path but kept inline so
		// we don't accidentally accept `[expr]`, calls, optional chains, etc.
		if p.cur_type != .Identifier {
			report_error(p, "Expected identifier in import-equals module reference")
			return nil
		}
		head_loc := cur_loc(p)
		head := new_node(p, Identifier)
		head.loc = head_loc
		head.name = cur_value(p)
		eat(p)
		current_expr := expression_from(p, head)
		for is_token(p, .Dot) {
			eat(p)  // consume `.`
			if p.cur_type != .Identifier && !is_keyword_usable_as_property_name(p.cur_type) &&
			   p.cur_type != .Await && p.cur_type != .Yield {
				report_error(p, "Expected identifier after '.' in import-equals module reference")
				break
			}
			rhs_loc := cur_loc(p)
			rhs := new_node(p, Identifier)
			rhs.loc = rhs_loc
			rhs.name = cur_value(p)
			eat(p)
			mem := new_node(p, MemberExpression)
			mem.loc = head_loc
			mem.object = current_expr
			rhs_expr := expression_from(p, rhs)
			mem.property = rhs_expr
			mem.computed = false
			mem.optional = false
			mem.loc.span.end = prev_end_offset(p)
			current_expr = expression_from(p, mem)
		}
		decl.module_reference = current_expr
	}

	match_semicolon_or_asi(p)
	decl.loc.span.end = prev_end_offset(p)

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
	if allow_ts_mode(p) && p.cur_type == .Identifier && p.cur_tok.value == "type" {
		if p.cur_tok.has_escape && p.lexer.nxt.kind == .As {
			report_error(p, "Keyword 'type' must not contain escaped characters")
		}
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
		current := get_current(p)
		val := current.literal.(string) or_else ""
		if string_has_unpaired_surrogate(val) {
			report_error(p, "Import name string must not contain unpaired surrogates")
		}
		imported = Identifier{loc = loc_from_token(&current), name = val}
		is_string_import = true
		eat(p)
	} else {
		imported = parse_identifier_name(p)
	}

	local := imported
	if match_token(p, .As) {
		if is_token(p, .String) {
			report_error(p, "Import binding name cannot be a string literal")
		}
		local = parse_identifier(p)
	} else if is_string_import {
		// String import names MUST have `as local`.
		report_error(p, "String import names require 'as' binding")
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
	spec.loc.span.end = prev_end_offset(p)

	// §16.2.2 — ImportedBinding `eval` / `arguments` early error is
	// enforced by the semantic checker (ck_check_import_specifier_local).
	// Always-reserved word as import binding stays a parser-side
	// structural error (`import { default }` etc).
	if is_always_reserved_word_name(local.name) {
		msg := fmt.tprintf("'%s' is a reserved word and cannot be used as an import binding", local.name)
		report_error(p, msg)
	}
	// §16.2.2 - When no `as` clause, the ImportedBinding is the same
	// identifier as the ModuleExportName.  Reserved words are valid
	// ModuleExportNames (`import { default as x }`) but NOT valid
	// BindingIdentifiers (`import { default }`).  The check only fires
	// when local == imported (no `as`).
	if local.loc.span.start == imported.loc.span.start && !is_string_import {
		if is_always_reserved_word_name(local.name) {
			msg := fmt.tprintf("'%s' is a reserved word and cannot be used as an import binding", local.name)
			report_error(p, msg)
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
	restore_module_syntax := p.in_ts_namespace
	prev_module_syntax := p.has_module_syntax
	prev_pre_scan_done := p.module_pre_scan_done
	defer if restore_module_syntax {
		p.has_module_syntax    = prev_module_syntax
		p.module_pre_scan_done = prev_pre_scan_done
	}

	// §16.2 "export only valid in module code" early error: enforced by
	// the semantic checker (ck_check_import_export_position).

	if is_token(p, .Export) {
		report_error(p, "'export' modifier already seen.")
		eat(p)
	}

	if match_token(p, .Default) {
		return parse_export_default(p, start)
	}

	if match_token(p, .Mul) {
		return parse_export_all(p, start, .Value)
	}

	if is_token(p, .LBrace) {
		return parse_export_named(p, start, .Value)
	}

	// `export = <expr>;` - TS legacy CommonJS-style export assignment.
	// `=` here is NOT a binding-init; it's a sentinel that introduces a
	// single expression-form export. The trailing semicolon (or ASI) is
	// part of the declaration; the span includes it.
	if is_token(p, .Assign) {
		eat(p) // consume `=`
		expr := parse_assignment_expression(p)
		if expr == nil {
			report_error(p, "Expected expression after 'export ='")
		}
		if !match_semicolon_or_asi(p) {
			report_error(p, "Expected semicolon after export assignment")
		}
		decl := new_node(p, TSExportAssignment)
		decl.loc = start; decl.expression = expr
		decl.loc.span.end = prev_end_offset(p)
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
			eat(p) // consume `as`
			eat(p) // consume `namespace`
			cur := get_current(p)
			id := Identifier{loc = loc_from_token(&cur), name = cur.value}
			eat(p) // consume identifier
			if !match_semicolon_or_asi(p) {
				report_error(p, "Expected semicolon after 'export as namespace'")
			}
			decl := new_node(p, TSNamespaceExportDeclaration)
			decl.loc = start; decl.id = id
			decl.loc.span.end = prev_end_offset(p)
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
	if p.cur_type == .Identifier && p.cur_tok.value == "type" && allow_ts_mode(p) {
		has_esc := p.cur_tok.has_escape
		nxt := peek_token(p)
		if nxt.type == .LBrace {
			if has_esc { report_error(p, "Keyword 'type' must not contain escaped characters") }
			eat(p) // consume `type`
			return parse_export_named(p, start, .Type)
		}
		if nxt.type == .Mul {
			if has_esc { report_error(p, "Keyword 'type' must not contain escaped characters") }
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
		    (p.cur_tok.value == "public" || p.cur_tok.value == "private" ||
		     p.cur_tok.value == "protected" || p.cur_tok.value == "static") &&
		    is_next_token(p, .Import) {
			eat(p)
		}
	}

	// After `export`, only `*`, `default`, `{`, or a declaration keyword
	// is valid. A bare string literal is always a SyntaxError.
	if is_token(p, .String) {
		report_error(p, "Unexpected string literal after 'export'")
	}

	// Export declaration. parse_statement_or_declaration returns a ^Statement
	// union wrapping the underlying declaration variant. The previous code
	// cast that ^Statement pointer directly to ^Declaration, reinterpreting
	// the Statement union's tag bytes as a Declaration tag - different
	// ordinal spaces (Declaration: 7 variants, Statement: 25), so downstream
	// dispatch hit the wrong variant or "Unknown". Same UB class as Bug H.
	//
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
		if v.declare { export_kind = .Type }
	case ^VariableDeclaration:
		decl_union^ = v
		if v.declare { export_kind = .Type }
		// §Explicit Resource Management - `export using x = ...` and
		// `export await using x = ...` are SyntaxErrors. Using
		// declarations must use the named-export form: `export { x }`.
		if v != nil && (v.kind == .Using || v.kind == .AwaitUsing) {
			report_error(p, "Using declarations cannot be exported directly")
		}
	case ^ClassDeclaration:
		decl_union^ = v
		if v.declare { export_kind = .Type }
	case ^ImportDeclaration:          decl_union^ = v
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
		if v.declare { export_kind = .Type }
	case ^TSModuleDeclaration:
		decl_union^ = v
		if v.declare { export_kind = .Type }
	case ^TSImportEqualsDeclaration:  decl_union^ = v
	case:
		// After `export` (non-default), only declarations are valid.
		// Expression statements, empty statements, and other non-declaration
		// statement types are SyntaxErrors. `export default <expr>` is handled
		// by parse_export_default above.
		report_error(p, "Unexpected token")
		return nil
	}

	export_decl := new_node(p, ExportNamedDeclaration)
	export_decl.loc = start
	export_decl.declaration = decl_union
	export_decl.export_kind = export_kind
	export_decl.loc.span.end = prev_end_offset(p)

	// Allocate Statement union and store the pointer
	stmt := new_node(p, Statement)
	stmt^ = (^ExportNamedDeclaration)(export_decl)
	return stmt
}

parse_export_default :: proc(p: ^Parser, start: Loc) -> ^Statement {
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
		if !p.cur_tok.had_line_terminator {
			#partial switch p.cur_type {
			case .LParen, .LBracket, .Dot, .OptionalChain,
			     .Template, .TemplateHead, .Arrow,
			     .PlusPlus, .MinusMinus:
				report_error(p, "Unexpected token after 'export default function' declaration")
			}
		}
	} else if is_token(p, .Class) ||
	          is_token(p, .At) ||
	          (is_token(p, .Abstract) && p.lexer.nxt.kind == .Class) {
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
	} else if p.cur_type == .Identifier && p.cur_tok.value == "interface" &&
	          allow_ts_mode(p) {
		// `export default interface X { ... }` - TS-only form.
		// `export default interface {}` - anonymous interface is rejected.
		if !is_next_token(p, .Identifier) && !is_keyword_usable_as_property_name(p.lexer.nxt.kind) {
			report_error(p, "Interface declaration must have a name")
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
		   (p.cur_type == .Let && !p.cur_tok.had_line_terminator) {
			report_error(p, "'export default' cannot be followed by a variable declaration")
		}
		if is_token(p, .Using) && p.lexer.nxt.kind != .Semi && p.lexer.nxt.kind != .EOF {
			report_error(p, "'export default' cannot be followed by a using declaration")
		}
		if is_token(p, .Await) && p.lexer.nxt.kind == .Using &&
		   (p.lexer.nxt.flags & FLAG_NEW_LINE) == 0 {
			report_error(p, "'export default' cannot be followed by a using declaration")
		}
		expr := parse_assignment_expression(p)
		if expr != nil {
			def^ = expr
		}
		if !match_semicolon_or_asi(p) && !p.cur_tok.had_line_terminator {
			// `export default null null;` - second literal follows without separator.
			#partial switch p.cur_type {
			case .Null, .True, .False, .Number, .String, .BigInt:
				report_error(p, "Unexpected token following export default expression")
			}
		}
	}

	decl := new_node(p, ExportDefaultDeclaration)
	decl.loc = start
	decl.declaration = def
	decl.loc.span.end = prev_end_offset(p)

	// Collect ESM static export record for export default
	p.has_module_syntax = true
	esm_export := ESMStaticExport{
		start = decl.loc.span.start,
		end = decl.loc.span.end,
		entries = make([dynamic]ESMStaticExportEntry, 1, p.allocator),
	}
	esm_export.entries[0] = ESMStaticExportEntry{
		exportName = ESMExportNameEntry{
			kind = .Default,
			name = "default",
			start = start.span.start,
			end = start.span.end,
		},
		localName = ESMExportNameEntry{
			kind = .Default,
			name = "default",
			start = start.span.start,
			end = start.span.end,
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
			current := get_current(p)
			val := current.literal.(string) or_else ""
			if string_has_unpaired_surrogate(val) {
				report_error(p, "Export name string must not contain unpaired surrogates")
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
		report_error(p, "Expected string literal module specifier after 'from'")
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
		report_error(p, "Expected semicolon after export declaration")
	}
	decl.loc.span.end = prev_end_offset(p)

	// Collect ESM static export record for export * from
	p.has_module_syntax = true
	esm_export := ESMStaticExport{
		start = decl.loc.span.start,
		end = decl.loc.span.end,
		moduleRequest = {
			value = decl.source.value,
			start = decl.source.loc.span.start,
			end = decl.source.loc.span.end,
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
			start = decl.source.loc.span.start,
			end = decl.source.loc.span.end,
		},
		localName = ESMExportNameEntry{
			kind = .Namespace,
			name = export_name,
			start = decl.source.loc.span.start,
			end = decl.source.loc.span.end,
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
		if allow_ts_mode(p) && p.cur_type == .Identifier && p.cur_tok.value == "type" {
			if p.cur_tok.has_escape && p.lexer.nxt.kind == .As {
				report_error(p, "Keyword 'type' must not contain escaped characters")
			}
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
				report_error(p, "The 'type' modifier cannot be used in a type-only export")
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
				current := get_current(p)
				str_lit := new_node(p, StringLiteral)
				str_lit.loc = loc_from_token(&current)
				str_lit.value = current.literal.(string) or_else ""
				str_lit.raw = current.value
				// §16.2.3 - ModuleExportName : StringLiteral must be well-formed Unicode.
				if string_has_unpaired_surrogate(str_lit.value) {
					report_error(p, "Export name string must not contain unpaired surrogates")
				}
				eat(p)
				return str_lit
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
		spec.loc.span.end = prev_end_offset(p)
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
	if is_token(p, .Identifier) && p.cur_tok.value == "from" {
		if p.cur_tok.has_escape {
			report_error(p, "'from' keyword must not contain Unicode escape sequences")
		}
		// Treat the identifier 'from' as the From keyword for recovery.
		p.cur_type = .From
		p.cur_tok.type = .From
	}
	if match_token(p, .From) {
		if !is_token(p, .String) {
			report_error(p, "Expected string literal module specifier")
		}
		decl.source = parse_string_literal(p)
		decl.attributes = parse_import_attributes(p)
	}

	if !match_semicolon_or_asi_export(p) {
		// `export {} null;` - unexpected token follows export clause on same line.
		report_error(p, "Expected semicolon after export declaration")
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
				report_error(p, "A reserved word 'default' cannot be used as a local exported binding without 'as'")
			}
		}
	}

	decl.loc.span.end = prev_end_offset(p)

	// Collect ESM static export record for named exports
	p.has_module_syntax = true
	if len(decl.specifiers) > 0 {
		esm_export := ESMStaticExport{
			start = decl.loc.span.start,
			end = decl.loc.span.end,
			entries = make([dynamic]ESMStaticExportEntry, 0, len(decl.specifiers), p.allocator),
		}
		// Handle export * from "m" case
		if v, ok := decl.source.?; ok {
			esm_export.moduleRequest.value = v.value
			esm_export.moduleRequest.start = v.loc.span.start
			esm_export.moduleRequest.end = v.loc.span.end
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
// Expressions
// ============================================================================

// Expression parsing with precedence climbing
// ES2025 Precedence (from lowest to highest):
Precedence :: enum {
	None,            // Not an operator - breaks the loop immediately
	Comma,           // ,
	Spread,          // ...
	Yield,           // yield
	Assignment,      // = += -= etc.
	Conditional,     // ? :
	LogicalOr,       // ||
	NullishCoalescing, // ?? (ES2020) - between || and &&
	LogicalAnd,      // &&
	BitwiseOr,       // |
	BitwiseXor,      // ^
	BitwiseAnd,      // &
	Equality,        // == != === !==
	Relational,      // < > <= >= in instanceof
	Shift,           // << >> >>>
	Additive,        // + -
	Multiplicative,  // * / %
	Exponentiation,  // **
	Unary,           // ! ~ - + typeof void delete
	Update,          // ++ --
	LeftHandSide,    // new call member
	Primary,         // literals, identifiers, ( ), [ ], { }
}

// Static precedence table for O(1) token-to-precedence lookup
// Initialized once at startup using a procedure with #init directive
precedence_table: [len(TokenType)]Precedence

@(init)
init_precedence_table :: proc "contextless" () {
	for i in 0..<len(precedence_table) { precedence_table[i] = .None }
	precedence_table[TokenType.Comma]       = .Comma
	precedence_table[TokenType.Dot3]        = .Spread
	precedence_table[TokenType.Arrow]       = .Assignment
	precedence_table[TokenType.Question]    = .Conditional
	precedence_table[TokenType.LogicalOr]   = .LogicalOr
	precedence_table[TokenType.Nullish]     = .NullishCoalescing
	precedence_table[TokenType.LogicalAnd]  = .LogicalAnd
	precedence_table[TokenType.BitOr]       = .BitwiseOr
	precedence_table[TokenType.BitXor]      = .BitwiseXor
	precedence_table[TokenType.BitAnd]      = .BitwiseAnd
	precedence_table[TokenType.Eq]          = .Equality
	precedence_table[TokenType.NotEq]       = .Equality
	precedence_table[TokenType.EqStrict]    = .Equality
	precedence_table[TokenType.NotEqStrict] = .Equality
	precedence_table[TokenType.LAngle]      = .Relational
	precedence_table[TokenType.RAngle]      = .Relational
	precedence_table[TokenType.LEq]         = .Relational
	precedence_table[TokenType.GEq]         = .Relational
	precedence_table[TokenType.In]          = .Relational
	precedence_table[TokenType.Instanceof]  = .Relational
	precedence_table[TokenType.LShift]      = .Shift
	precedence_table[TokenType.RShift]      = .Shift
	precedence_table[TokenType.URShift]     = .Shift
	precedence_table[TokenType.Plus]        = .Additive
	precedence_table[TokenType.Minus]       = .Additive
	precedence_table[TokenType.Mul]         = .Multiplicative
	precedence_table[TokenType.Div]         = .Multiplicative
	precedence_table[TokenType.Mod]         = .Multiplicative
	precedence_table[TokenType.Pow]         = .Exponentiation
	precedence_table[TokenType.Assign]          = .Assignment
	precedence_table[TokenType.AssignAdd]       = .Assignment
	precedence_table[TokenType.AssignSub]       = .Assignment
	precedence_table[TokenType.AssignMul]       = .Assignment
	precedence_table[TokenType.AssignDiv]       = .Assignment
	precedence_table[TokenType.AssignMod]       = .Assignment
	precedence_table[TokenType.AssignPow]       = .Assignment
	precedence_table[TokenType.AssignLShift]    = .Assignment
	precedence_table[TokenType.AssignRShift]    = .Assignment
	precedence_table[TokenType.AssignURShift]   = .Assignment
	precedence_table[TokenType.AssignBitAnd]    = .Assignment
	precedence_table[TokenType.AssignBitOr]     = .Assignment
	precedence_table[TokenType.AssignBitXor]    = .Assignment
	precedence_table[TokenType.AssignLogicalAnd] = .Assignment
	precedence_table[TokenType.AssignLogicalOr]  = .Assignment
	precedence_table[TokenType.AssignNullish]    = .Assignment
}

// Fast O(1) precedence lookup using precomputed table
precedence_for_token :: #force_inline proc(t: TokenType) -> Precedence {
	return precedence_table[t]
}

// Identifier-like tokens accepted by parse_unary_expr's identifier fast-path:
// plain Identifier plus the contextual keywords whose lex tokens always
// resolve to an IdentifierReference here (Get / Set / From / Of / As / Let /
// Static / Constructor / Using). The previous 10-clause OR chain compiled to
// 10 token-type compares per parse_unary_expr call - hit on every Identifier
// expression in the program. A single table load + nz-test replaces it.
is_id_like_for_unary_table: [len(TokenType)]bool

@(init)
init_is_id_like_for_unary_table :: proc "contextless" () {
	is_id_like_for_unary_table[TokenType.Identifier]  = true
	is_id_like_for_unary_table[TokenType.Get]         = true
	is_id_like_for_unary_table[TokenType.Set]         = true
	is_id_like_for_unary_table[TokenType.From]        = true
	is_id_like_for_unary_table[TokenType.Of]          = true
	is_id_like_for_unary_table[TokenType.As]          = true
	is_id_like_for_unary_table[TokenType.Let]         = true
	is_id_like_for_unary_table[TokenType.Static]      = true
	is_id_like_for_unary_table[TokenType.Constructor] = true
	is_id_like_for_unary_table[TokenType.Using]       = true
}

is_id_like_for_unary :: #force_inline proc(t: TokenType) -> bool {
	return is_id_like_for_unary_table[t]
}

// Parse expression using precedence climbing (efficient Pratt-style parsing)
// Parse full expression including comma operator
// Full expression including comma operator: AssignmentExpr (, AssignmentExpr)*
parse_expression :: proc(p: ^Parser) -> ^Expression {
	return parse_expr_with_prec(p, .Comma)
}

// Single assignment expression (no comma). Used for:
// - function arguments, array elements, object property values
// - for-in/of right-hand side
// - ternary branches
parse_assignment_expression :: proc(p: ^Parser) -> ^Expression {
	return parse_expr_with_prec(p, .Assignment)
}

parse_expr_with_prec :: proc(p: ^Parser, min_prec: Precedence) -> ^Expression {
	prev_private_in_allowed := p.private_in_allowed
	p.private_in_allowed = int(min_prec) <= int(Precedence.Relational)
	left := parse_unary_expr(p)
	p.private_in_allowed = prev_private_in_allowed
	if left == nil {
		return nil
	}

	// §14.4 / §15.5 - YieldExpression is an AssignmentExpression, not a
	// ShortCircuitExpression. It cannot be the subject of binary,
	// logical, coalescing, or conditional operators (unless parenthesised).
	// Assignment operators are allowed (they call parse_assignment_expr which
	// separately validates the target). The comma operator is always allowed
	// (e.g. `yield u, r.push(u)` is a SequenceExpression).
	if _, is_yield := left.(^YieldExpression); is_yield {
		// Detect whether the YieldExpression was parenthesised. With
		// --preserve-parens off, `(yield n)` is stripped to a bare
		// YieldExpression node; we recover the paren context by scanning
		// backwards from the span start, identical to the `**` and `??`
		// checks above.
		yield_start := int(loc_from_expr(left).span.start)
		paren_wrapped := false
		if p.lexer != nil && yield_start > 0 {
			yi := yield_start - 1
			for yi >= 0 {
				ych := p.lexer.source_bytes[yi]
				if ych == '(' { paren_wrapped = true; break }
				if ych == ' ' || ych == '\t' || ych == '\n' || ych == '\r' { yi -= 1; continue }
				break
			}
		}
		if !paren_wrapped {
			next_prec := precedence_for_token(p.cur_type)
			// §12.6 ASI: when there's a LineTerminator between the
			// YieldExpression and the next operator token, the YieldExpression
			// is a complete statement. The next operator becomes the start of
			// the next statement (which may be a syntax error in its own right,
			// e.g. `+ 1` as a stmt is valid; `/ 1 /g` parses as a regex).
			// Critical for the Babel `es2015/yield/regexp` fixture where
			//   `yield<nl>/ 1 /g`
			// must parse as `yield;` followed by a regex statement, not as
			// `yield / 1 / g` (a binary chain). OXC + V8 + SpiderMonkey all
			// apply ASI here.
			if p.cur_tok.had_line_terminator {
				return left
			}
			// .Conditional (5) and above covers ?, ||, &&, ??, |, ^, &,
			// ==, <, <<, +, *, **, etc. All forbidden as yield LHS without
			// parens. Assignment operators (.Assignment=4) are below the
			// threshold - let them through so parse_assignment_expr can
			// validate the target (e.g. `(yield) = 1` should be caught there).
			if int(next_prec) >= int(Precedence.Conditional) {
				// Structural parse error: by §14.4 / §15.5,
				// YieldExpression is at AssignmentExpression precedence
				// and cannot serve as operand to a conditional / binary /
				// logical / coalescing operator without parentheses. The
				// parser must return early here (return left below) to
				// avoid building a malformed binary-expression AST that
				// the post-parse semantic checker can't detect.
				report_error(p, "'yield' expression cannot be used as an operand of a conditional or binary operator")
			}
			// Return early for all operators EXCEPT comma (sequence) and
			// assignment (target validation needed in parse_assignment_expr).
			is_assign_like := int(next_prec) == int(Precedence.Assignment)
			if p.cur_type != .Comma && !is_assign_like {
				return left
			}
		}
	}

	// TypeScript: `expr as Type` and `expr satisfies Type`
	for is_token(p, .As) || is_token(p, .Satisfies) {
		if is_token(p, .As) {
			eat(p)
			ts_type := parse_ts_type(p)
			as_expr := new_node(p, TSAsExpression)
			as_expr.loc = loc_from_expr(left)
			as_expr.expression = left
			as_expr.type_annotation = ts_type
			as_expr.loc.span.end = prev_end_offset(p)
			left = expression_from(p, as_expr)
		} else {
			eat(p)
			ts_type := parse_ts_type(p)
			sat_expr := new_node(p, TSSatisfiesExpression)
			sat_expr.loc = loc_from_expr(left)
			sat_expr.expression = left
			sat_expr.type_annotation = ts_type
			sat_expr.loc.span.end = prev_end_offset(p)
			left = expression_from(p, sat_expr)
		}
	}

	for {
		if left == nil {
			return nil
		}
		cur_type := p.cur_type

		// Skip 'in' as binary op when parsing for-loop init
		if p.no_in && cur_type == .In {
			break
		}

		op_prec := precedence_for_token(cur_type)

		// Fast exit: non-operator tokens have .None precedence → immediate break
		if op_prec < min_prec {
			break
		}

		// Handle special operator-like tokens
		if op_prec == .Assignment {
			if cur_type == .Arrow {
				// ECMA-262 §15.3 Restricted Production:
				//   ArrowFunction : ArrowParameters [no LineTerminator here] => ConciseBody
				// A LineTerminator between the parameters and `=>` fails the
				// production. Report it but still parse the arrow so the rest of
				// the expression parses cleanly (the arrow body carries the
				// `=>` span regardless).
				if p.cur_tok.had_line_terminator {
					report_error(p, "Unexpected line terminator before '=>' (restricted production)")
				}
				// `({}=>0)` — bare ObjectExpression followed by `=>` inside a
				// paren group is not valid CoverParenthesizedExpression form.
				// V8 rejects: "Malformed arrow function parameter list".
				// Only reject when the object has NO properties and was not
				// preceded by `)` (which would mean `({}) =>` form).
				if left != nil {
					if obj, is_obj := left^.(^ObjectExpression); is_obj && len(obj.properties) == 0 {
						// Check if there's a `)` between the `}` and `=>`.
						if p.lexer != nil {
							arrow_off := int(cur_offset(p))
							has_rparen := false
							i := arrow_off - 1
							for i >= 0 {
								ch := p.lexer.source_bytes[i]
								if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { i -= 1; continue }
								if ch == ')' { has_rparen = true }
								break
							}
							if !has_rparen {
								report_error(p, "Malformed arrow function parameter list")
							}
						}
					}
				}
				left = parse_arrow_function(p, left)
				continue
			}
			if is_assignment_operator(cur_type) {
				// `/=` on a new line is ambiguous: it could be compound
				// assignment division or a regex `/=.../`. After expressions
				// that cannot be valid assignment targets (YieldExpression,
				// literals, etc.), treat the new-line `/=` as a statement
				// boundary and break out of the infix loop so ASI fires.
				if cur_type == .AssignDiv && p.cur_tok.had_line_terminator {
					break
				}
				left = parse_assignment_expr(p, left)
				continue
			}
		}

		if _, is_arrow := left.(^ArrowFunctionExpression); is_arrow {
			// ArrowFunction is an AssignmentExpression, but the ES grammar only
			// admits it where an AssignmentExpression is expected. It cannot be
			// used directly as the head of `?:` or a binary/logical expression;
			// callers must write `(() => {}) || x` to promote it through a
			// ParenthesizedExpression. Parameter parens in `() => {}` do not count.
			if left != p.last_paren_expr && int(op_prec) >= int(Precedence.Conditional) {
				report_error(p, "Arrow function cannot be used as an unparenthesized operand")
			}
		}

		if op_prec == .Conditional {
			left = parse_conditional_expr(p, left)
			continue
		}

		// Trailing comma in parenthesized expression: don't consume comma before )
		if cur_type == .Comma && is_next_token(p, .RParen) {
			// §15.3.1 - A trailing comma after a rest element `...x` in
			// `(...x, ) => body` is a SyntaxError. Check before eating.
			if _, is_spread := left.(^SpreadElement); is_spread {
				report_error(p, "Rest element may not have a trailing comma")
			}
			eat(p)
			break
		}

		// Comma operator → SequenceExpression
		if cur_type == .Comma {
			seq, seq_e := new_expr(p, SequenceExpression)
			seq.loc = loc_from_expr(left)
			// Cap bumped from 4 → 8 (S23). Profile on monaco: 1254 grow events
			// for sequence expressions with >4 commas. Common in `for (i = 0,
			// j = 0, k = 0; ...)` and minified `(a, b, c, d, e)` chains.
			seq.expressions = make([dynamic]^Expression, 0, 8, p.allocator)
			bump_append(&seq.expressions, left)
			for match_token(p, .Comma) {
				expr := parse_assignment_expression(p)
				if expr == nil { break }
				bump_append(&seq.expressions, expr)
			}
			seq.loc.span.end = prev_end_offset(p)
			left = seq_e
			continue
		}

		// Binary/logical operator
		// §13.6.1 - ExponentiationExpression : UnaryExpression `**`
		// ExponentiationExpression. The grammar specifically disallows an
		// unparenthesized UnaryExpression as the base, so `-3 ** 2`,
		// `!x ** 2`, `typeof x ** 2`, `delete o.x ** 2` etc. are all
		// SyntaxErrors. `(-3) ** 2` and `-(3 ** 2)` are legal because the
		// parentheses promote the inner UnaryExpression to a
		// PrimaryExpression (or because the unary applies to the whole
		// `**` form). Detect by inspecting the raw source span of the
		// left operand - a leading `(` means paren-wrapped.
		if cur_type == .Pow && left != nil {
			_, is_unary := left.(^UnaryExpression)
			_, is_await := left.(^AwaitExpression)
			if is_unary || is_await {
				lhs_loc := loc_from_expr(left)
				lhs_start := lhs_loc.span.start
				lhs_end   := lhs_loc.span.end
				paren_wrapped := false
				if p.lexer != nil && int(lhs_start) < len(p.lexer.source_bytes) {
					// Without --preserve-parens the UnaryExpression's span
					// is [unary_op, end) and the optional `(` lives one byte
					// before. Walk backwards over insignificant whitespace
					// (rare in practice) to detect the wrapper.
					i := int(lhs_start) - 1
					for i >= 0 {
						ch := p.lexer.source_bytes[i]
						if ch == '(' { paren_wrapped = true; break }
						if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { i -= 1; continue }
						break
					}
					// Found a '(' before the unary. Verify it closes
					// *before* the '**' - i.e. the ')' sits between the
					// UnaryExpression's end and the '**' token. If the ')'
					// is missing (or after '**') the '(' wraps the whole
					// binary expression, not just the unary operand:
					//   (-5) ** 6   → ')' at 3, before '**' at 5 → wrapped
					//   (-5 ** 6)   → ')' at 8, after  '**' at 4 → NOT
					if paren_wrapped {
						// Walk forward from lhs_end over whitespace looking
						// for ')'. Must appear before cur_tok (the '**').
						closing := false
						j := int(lhs_end)
						pow_off := int(cur_offset(p))
						for j < pow_off {
							ch := p.lexer.source_bytes[j]
							if ch == ')' { closing = true; break }
							if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { j += 1; continue }
							break
						}
						if !closing { paren_wrapped = false }
					}
				}
				if !paren_wrapped {
					report_error(p, "Unparenthesized unary expression cannot appear as the left operand of '**'")
				}
			}
		}

		eat(p)
		next_min_prec := Precedence(int(op_prec) + 1)

		// Track `in`-RHS context so PrivateIdentifier in primary-expr
		// position is rejected for `#x in #y` while staying legal for
		// `(#x in y)` (parens reset the flag in parse_primary_expr).
		prev_in_in_rhs := p.in_in_rhs
		if cur_type == .In { p.in_in_rhs = true }
		// Slice 14: scope_skip is tracked by the checker now
		// (CheckerContext.scope_skip), set by ck_walk_expr's
		// BinaryExpression / LogicalExpression cases for the duration
		// of operand-walks. The parser does not participate.
		right := parse_expr_with_prec(p, next_min_prec)
		p.in_in_rhs = prev_in_in_rhs
		if right == nil {
			report_error(p, "Expected expression after operator")
			return left
		}

		if _, is_arrow := right.(^ArrowFunctionExpression); is_arrow {
			paren_wrapped := false
			if p.lexer != nil {
				start := int(loc_from_expr(right).span.start)
				i := start - 1
				for i >= 0 {
					ch := p.lexer.source_bytes[i]
					if ch == '(' { paren_wrapped = true; break }
					if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { i -= 1; continue }
					break
				}
			}
			if !paren_wrapped {
				report_error(p, "Arrow function cannot be used as an unparenthesized operand")
			}
		}

		// §14.4 - YieldExpression cannot be the right-hand operand of any
		// binary or logical operator (it has assignment-expression precedence).
		// Exception: a parenthesised `(yield n)` promotes the expression to
		// primary-expression level; with --preserve-parens off the wrapper
		// is stripped, so we detect the paren by scanning backwards from the
		// yield's span start, mirroring the `**` unary check above.
		if _, is_yield := right.(^YieldExpression); is_yield && cur_type != .Comma {
			yield_start := int(loc_from_expr(right).span.start)
			paren_wrapped := false
			if p.lexer != nil && yield_start > 0 {
				i := yield_start - 1
				for i >= 0 {
					ch := p.lexer.source_bytes[i]
					if ch == '(' { paren_wrapped = true; break }
					if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { i -= 1; continue }
					break
				}
			}
			if !paren_wrapped {
				// Structural parse error: see the LHS-form rationale
				// above. YieldExpression has assignment-expression
				// precedence and the binary-operator grammar rejects it.
				report_error(p, "'yield' expression cannot be the right-hand side of a binary operator")
			}
		}

		// §13.4 - Nullish coalescing (??) cannot be mixed with && or ||
		// without parentheses, and vice versa. Parenthesised sub-expressions
		// are exempt: `(a && b) ?? c` and `a ?? (b || c)` are legal.
		// Detect parens by scanning backwards from the operand span start,
		// mirroring the yield and `**` checks above.
		if cur_type == .Nullish {
			if le, ok := left.(^LogicalExpression); ok &&
			   (le.operator == .And || le.operator == .Or) {
				le_start := int(le.loc.span.start)
				paren_ok := false
				if p.lexer != nil && le_start > 0 {
					pi := le_start - 1
					for pi >= 0 {
						pch := p.lexer.source_bytes[pi]
						if pch == '(' { paren_ok = true; break }
						if pch == ' ' || pch == '\t' || pch == '\n' || pch == '\r' { pi -= 1; continue }
						break
					}
				}
				if !paren_ok {
					report_error(p, "Nullish coalescing operator cannot be directly combined with '&&' or '||' operators without parentheses")
				}
			}
			if le, ok := right.(^LogicalExpression); ok &&
			   (le.operator == .And || le.operator == .Or) {
				le_start := int(le.loc.span.start)
				paren_ok := false
				if p.lexer != nil && le_start > 0 {
					pi := le_start - 1
					for pi >= 0 {
						pch := p.lexer.source_bytes[pi]
						if pch == '(' { paren_ok = true; break }
						if pch == ' ' || pch == '\t' || pch == '\n' || pch == '\r' { pi -= 1; continue }
						break
					}
				}
				if !paren_ok {
					report_error(p, "Nullish coalescing operator cannot be directly combined with '&&' or '||' operators without parentheses")
				}
			}
		} else if cur_type == .LogicalOr || cur_type == .LogicalAnd {
			if le, ok := left.(^LogicalExpression); ok &&
			   le.operator == .NullishCoalescing {
				le_start := int(le.loc.span.start)
				paren_ok := false
				if p.lexer != nil && le_start > 0 {
					pi := le_start - 1
					for pi >= 0 {
						pch := p.lexer.source_bytes[pi]
						if pch == '(' { paren_ok = true; break }
						if pch == ' ' || pch == '\t' || pch == '\n' || pch == '\r' { pi -= 1; continue }
						break
					}
				}
				if !paren_ok {
					report_error(p, "'&&' and '||' operators cannot be directly combined with '??' operator without parentheses")
				}
			}
			// Mirror check for the RIGHT operand: `0 || 0 ?? true` parses
			// the right-hand side at NullishCoalescing precedence (higher
			// than LogicalOr), producing `0 || (?? 0 true)`. Without this
			// the inner ?? slips past the spec rule. Test262: language/
			// expressions/coalesce/cannot-chain-head-with-logical-or.js.
			if le, ok := right.(^LogicalExpression); ok &&
			   le.operator == .NullishCoalescing {
				le_start := int(le.loc.span.start)
				paren_ok := false
				if p.lexer != nil && le_start > 0 {
					pi := le_start - 1
					for pi >= 0 {
						pch := p.lexer.source_bytes[pi]
						if pch == '(' { paren_ok = true; break }
						if pch == ' ' || pch == '\t' || pch == '\n' || pch == '\r' { pi -= 1; continue }
						break
					}
				}
				if !paren_ok {
					report_error(p, "'&&' and '||' operators cannot be directly combined with '??' operator without parentheses")
				}
			}
		}

		// Logical operators
		if cur_type == .LogicalOr || cur_type == .LogicalAnd || cur_type == .Nullish {
			logical, logical_e := new_expr(p, LogicalExpression)
			logical.loc = loc_from_expr(left)
			logical.operator = token_to_logical_op(cur_type)
			logical.left = left
			logical.right = right
			logical.loc.span.end = prev_end_offset(p)

			left = logical_e
			continue
		}

		// Regular binary operator
		binary, binary_e := new_expr(p, BinaryExpression)
		binary.loc = loc_from_expr(left)
		binary.operator = token_to_binary_op(cur_type)
		binary.left = left
		binary.right = right
		binary.loc.span.end = prev_end_offset(p)

		left = binary_e
	}

	return left
}

// Merged unary + update + left-hand-side to reduce call depth (5→3 frames)
parse_unary_expr :: proc(p: ^Parser) -> ^Expression {
	#partial switch p.cur_type {
	case .Plus, .Minus, .BitNot, .Not, .Typeof, .Void, .Delete:
		current := p.cur_tok
		eat(p)
		argument := parse_unary_expr(p)
		if argument == nil {
			report_error(p, "Expected expression after unary operator")
			return nil
		}
		// §13.5 UnaryExpression : <op> UnaryExpression. YieldExpression
		// is at AssignmentExpression precedence - the spec disallows it as
		// the operand of a unary operator. Catches `void yield`, `!yield`,
		// `typeof yield`, `delete yield`, `+yield`, `-yield`, `~yield` in a
		// generator body. (`yield` outside a generator is an Identifier,
		// which IS a valid UnaryExpression operand, so the check is fine.)
		// A parenthesised `(yield)` promotes the expression to primary-
		// expression level; with --preserve-parens off the wrapper is
		// stripped, so we detect the paren by scanning backwards from
		// the yield's span start, mirroring the binary-op checks above.
		// (Test262 / OXC parity: `void (yield)` inside a generator is
		// legal; only the bare-yield form is rejected.)
		if y, is_yield := argument.(^YieldExpression); is_yield {
			yield_start := int(y.loc.span.start)
			paren_wrapped := false
			if p.lexer != nil && yield_start > 0 {
				pi := yield_start - 1
				for pi >= 0 {
					pch := p.lexer.source_bytes[pi]
					if pch == '(' { paren_wrapped = true; break }
					if pch == ' ' || pch == '\t' || pch == '\n' || pch == '\r' { pi -= 1; continue }
					break
				}
			}
			if !paren_wrapped {
				report_error(p, "'yield' expression cannot be the operand of a unary operator")
			}
		}
		if _, is_arrow := argument.(^ArrowFunctionExpression); is_arrow {
			paren_wrapped := false
			if p.lexer != nil {
				start := int(loc_from_expr(argument).span.start)
				i := start - 1
				for i >= 0 {
					ch := p.lexer.source_bytes[i]
					if ch == '(' { paren_wrapped = true; break }
					if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { i -= 1; continue }
					break
				}
			}
			if !paren_wrapped {
				report_error(p, "Arrow function cannot be used as an unparenthesized operand")
			}
		}
		unary := new_node(p, UnaryExpression)
		unary.loc = loc_from_token(&current)
		unary.operator = token_to_unary_op(current.type)
		unary.argument = argument
		unary.prefix = true
		unary.loc.span.end = prev_end_offset(p)
		// §13.5.1 "delete IdentifierReference" in strict mode AND
		// "delete o.#priv" early errors are enforced by the semantic
		// checker (ck_check_unary_delete_local + ck_check_unary_delete_private).
		return expression_from(p, unary)

	case .PlusPlus, .MinusMinus:
		current := p.cur_tok
		eat(p)
		argument := parse_unary_expr(p)
		if argument == nil {
			// ECMA-262 §12.4.1 - prefix UpdateExpression requires a
			// UnaryExpression operand. `++;` / `--;` (no operand) and
			// `x\n++;` / `x\n--;` (line terminator splits postfix into
			// `x;` + bare `++;`) must be rejected. Test262 fixtures:
			//   language/asi/S7.9_A5.1_T1.js               // x \n ++;
			//   language/asi/S7.9_A5.3_T1.js               // x \n --;
			//   language/expressions/postfix-increment/    // (4 tests)
			//   language/expressions/postfix-decrement/    // (4 tests)
			op := "++" if current.type == .PlusPlus else "--"
			msg := fmt.tprintf("Unexpected token after prefix '%s'", op)
			report_error(p, msg)
			return nil
		}
		update := new_node(p, UpdateExpression)
		update.loc = loc_from_token(&current)
		update.operator = .Increment if current.type == .PlusPlus else .Decrement
		update.argument = argument
		update.prefix = true
		update.loc.span.end = prev_end_offset(p)
		if !is_simple_assignment_target(argument, !p.strict_mode) {
			report_error(p, "Invalid left-hand side expression in prefix operation")
		}
		return expression_from(p, update)

	case .Await:
		// ECMA-262 §15.8 - `await` is only valid as an AwaitExpression
		// inside an async function (or at module top level, handled via
		// the separate top-level-await detector below). In a non-async,
		// non-module context `await` is just an IdentifierReference -
		// `function f(await) { return await; }`, `await: 1;` (label),
		// `class await {}` (binding name) all need to fall through to
		// the identifier path. Mirror the `yield` handling: when the
		// lookahead is unambiguously NOT the start of an argument
		// (semicolon, operator, terminator), fall through. Otherwise
		// keep the long-standing diagnostic for `await expr` typos.
	if !p.in_async && !p.in_async_params {
		at_module_top := !p.in_function
		// In a Module file, `await` at top level (or any nested
		// non-function scope) is the AwaitExpression keyword - TLA.
		// Identifier fall-through only applies to Script source code.
		in_module_file := false
		if st, have := p.force_source_type.(SourceType); have && st == .Module {
			in_module_file = true
		}
		// Lazy pre-scan: TLA (top-level `await expr`) is module-only.
		ensure_module_syntax_resolved(p)
		if p.has_module_syntax {
			in_module_file = true
		}
		if p.in_static_block {
			// §15.7.5 await-in-class-static-block: enforced by the semantic
			// checker (^AwaitExpression case in ck_walk_expr). Parser still
			// treats this `await` as a keyword to keep the AST shape stable.
		} else if p.in_ts_namespace {
			// TS namespace body is not an async context. `await` is
			// an identifier, not a keyword, even in module-mode files.
			if yield_next_is_expression_argument(p) {
				report_error(p, "'await' is only allowed within async functions and at the top levels of modules")
			}
			break
		} else if at_module_top && in_module_file {
			// TLA - fall through to AwaitExpression parse below.
		} else if !at_module_top {
			// Inside a non-async function in script: `await` is an
			// identifier. Fall through unless the next token clearly
			// continues as an expression argument (typo case).
			if !yield_next_is_expression_argument(p) {
				break
			}
			report_error(p, "await outside of async function")
		} else {
			// At top level in Script (or auto-detect with no module
			// syntax yet seen). `await: 1;` (label), `await;` (bare
			// ref), `let await = 1;` etc. all want the identifier
			// path. Same lookahead heuristic as the in-function case.
			if !yield_next_is_expression_argument(p) {
				break
			}
		}
	}
		// §14.13.1 LabelIdentifier - in async context, "await" is a
		// reserved word, so `await:` as a LabelledStatement head is a
		// SyntaxError.
		if p.in_async && p.lexer != nil && p.lexer.nxt.kind == .Colon {
			report_error(p, "'await' cannot be used as a label identifier in an async function")
		}
		// Top-level `await` is Module syntax. When the caller pinned
		// `--source-type=script` it's a SyntaxError.
		if !p.in_function {
			if st, have := p.force_source_type.(SourceType); have && st == .Script {
				report_error(p, "Top-level 'await' is only valid in module code")
			}
		}
		// ECMA-262 §15.8.1 / §15.9.1 / §15.6.1 - "It is a Syntax Error if
		// FormalParameters (or CoverCallExpressionAndAsyncArrowHead)
		// Contains AwaitExpression is true." An AwaitExpression in a
		// parameter default of any async function-like form is forbidden
		// even though the body itself is async - params are evaluated in
		// the outer context.
		// §15.6.1 / §15.8.1 / §15.9.1 "AwaitExpression in formal
		// parameters" early error: enforced by the semantic checker
		// (^AwaitExpression case in ck_walk_expr) using its own
		// ctx.in_params tracker.
		current := p.cur_tok
		eat(p)
		prev_private_in_allowed := p.private_in_allowed
		p.private_in_allowed = false
		argument := parse_unary_expr(p)
		p.private_in_allowed = prev_private_in_allowed
		if argument == nil {
			// `await` without an operand. Legal only as an
			// IdentifierReference, which is forbidden in async context
			// anyway. Report and synthesise an identifier so the parse
			// tree stays structurally valid; the earlier
			// "await outside of async function" check at the top of
			// this branch already covers non-async contexts.
			if p.in_async || p.in_async_params || !p.in_function {
				report_error(p, "'await' expression requires an operand")
			}
			id := new_node(p, Identifier)
			id.loc = loc_from_token(&current)
			// S26 W5b: source-slice (current.value), not literal.
			// String literals are RODATA-pointing and break raw_transfer.
			id.name = current.value
			id.loc.span.end = current.raw_end
			return expression_from(p, id)
		}
		await := new_node(p, AwaitExpression)
		await.loc = loc_from_token(&current)
		await.argument = argument
		await.loc.span.end = prev_end_offset(p)
		// Top-level await is module syntax
		if !p.in_function {
			p.has_module_syntax = true
		}
		return expression_from(p, await)

	case .Dot3:
		current := p.cur_tok
		eat(p)
		argument := parse_unary_expr(p)
		if argument == nil { return nil }
		spread := new_node(p, SpreadElement)
		spread.loc = loc_from_token(&current)
		spread.argument = argument
		spread.loc.span.end = prev_end_offset(p)
		return expression_from(p, spread)

	case .Yield:
		// ECMA-262 §15.5 - YieldExpression is only grammatically
		// valid inside a GeneratorBody. Outside a generator `yield`
		// is an IdentifierReference (in sloppy mode) or a strict-
		// reserved word flagged by the binding checks. We still catch
		// the common `yield expr` mistake in a non-generator: if the
		// lookahead unambiguously starts an AssignmentExpression
		// argument (no newline, no operator / postfix / call /
		// terminator that could continue `yield` as an identifier)
		// we emit the "only allowed in a generator body" error and
		// still parse as YieldExpression for recovery. Otherwise we
		// fall through to the identifier path so `yield;`, `yield(1)`,
		// `yield.x`, `yield + 1`, `yield || 1`, `yield?1:2`,
		// `` yield`t` `` all behave as OXC / Acorn expect.
		if p.in_generator {
			return parse_yield_expr(p)
		}
		// §15.5.1 - inside a generator's FormalParameters, even bare
		// `yield` (no argument) is a YieldExpression and a SyntaxError.
		// parse_yield_expr's own in_generator_params check fires the
		// diagnostic; we just have to commit to the YieldExpression
		// production here so it actually runs.
		if p.in_generator_params {
			return parse_yield_expr(p)
		}
		if yield_next_is_expression_argument(p) {
			report_error(p, "'yield' expression is only allowed in a generator body")
			return parse_yield_expr(p)
		}
		// Fall through - `yield` is parsed as IdentifierReference by
		// parse_left_hand_side_expr → parse_primary_expr (line 5577).
	}

	// Common path: primary expression + optional postfix ++ / -- (inlined parse_update_expr)
	// Fast-path: identifier → member/call chain (covers ~60% of expressions)
	expr: ^Expression
	if is_id_like_for_unary(p.cur_type) {
		// ECMA-262 §12.7.2 - escaped-ReservedWord in IdentifierReference
		// position. This fast-path bypasses parse_primary_expr, so the
		// same check that lives on the slow path has to run here too.
		report_escaped_reserved_word(p)
		// §12.6.1.1 strict-mode IdentifierReference reservation check
		// is enforced by the semantic checker
		// (ck_check_identifier_reference_strict via ck_walk_expr's
		// ^Identifier case).
		// Escaped `async` before `function` is SyntaxError (fast path).
		if p.cur_tok.has_escape && p.cur_tok.value == "async" {
			nxt := peek_token(p)
			if nxt.type == .Function && !nxt.had_line_terminator {
				report_error(p, "'async' keyword must not contain Unicode escape sequences")
			}
		}
		// `arguments` as IdentifierReference in a class static block is
		// a SyntaxError per §15.7.5 (ContainsArguments). Includes the
		// escaped form `argument\u0073` since `cur_tok.value` is the
		// cooked name. Test262: language/statements/class/static-init-
		// invalid-arguments.js.
		// §15.7.5 arguments-in-class-static-block: enforced by the
		// semantic checker (ck_check_identifier_arguments). Parser stays
		// permissive.
		// §16.2 / §15.7.5 — `await` as IdentifierReference in async /
		// async-params / class-static-block context is enforced by the
		// semantic checker (ck_check_identifier_await_reserved). The
		// has_escape flag is propagated to ^Identifier below so the checker
		// can match the parser's narrow gating (only escaped forms reach
		// this code path with cooked name "await"; non-escaped `await`
		// lexes as `.Await` and parses as AwaitExpression).
		id_has_escape := p.cur_tok.has_escape
		// §12.1.1 - `enum` is a FutureReservedWord that is ALWAYS
		// reserved. The lexer emits it as .Identifier (contextual for
		// TS enum decls). Mirrors the check in parse_primary_expr.
		if !p.cur_tok.has_escape && p.cur_tok.value == "enum" {
			report_error(p, "'enum' is a reserved word")
		}
		// Inline identifier parse + LHS tail. Pull only the fields we need
		// out of p.cur_tok before eat() advances - a full Token copy is ~64
		// bytes and was showing up in the parse_unary_expr profile when this
		// fast path runs once per identifier in the program.
		//
		// `loc.line` / `loc.column` are NEVER written on `p.cur_tok` (verify
		// with `rg 'cur_tok\.loc\.line' src/`). The lexer only stores byte
		// offsets; line / column are computed lazily by `report_error` via
		// `offset_to_line_col` when an error is actually emitted. Reading
		// them here returned permanent 0, then we'd write 0 back into
		// `id.loc.{line,column}` - four wasted memory ops per identifier on
		// the hot path. Skip the loads, leave the Loc fields zero-initialised.
		id_offset := u32(p.cur_tok.loc)
		id_value  := p.cur_tok.value
		eat(p)
		id, id_e := new_expr(p, Identifier)
		id.loc.span.start = id_offset
		id.loc.span.end   = prev_end_offset(p)
		id.name = id_value
		id.has_escape = id_has_escape
		expr = id_e
		// Inline LHS tail loop (member access, calls)
		expr = parse_lhs_tail(p, expr, true)
	} else {
		expr = parse_left_hand_side_expr(p)
	}
	if expr == nil { return nil }

	// ECMA-262 §12.4 Restricted Production: no LineTerminator between the
	// LHS and postfix `++`/`--`. If there's a newline, ASI inserts a
	// semicolon so the operator starts the next statement as a prefix op.
	if (p.cur_type == .PlusPlus || p.cur_type == .MinusMinus) && !p.cur_tok.had_line_terminator {
		current := p.cur_tok
		eat(p)
		update := new_node(p, UpdateExpression)
		update.loc = loc_from_expr(expr)
		update.operator = .Increment if current.type == .PlusPlus else .Decrement
		update.argument = expr
		update.prefix = false
		update.loc.span.end = prev_end_offset(p)
		if !is_simple_assignment_target(expr, !p.strict_mode) {
			report_error(p, "Invalid left-hand side expression in postfix operation")
		}
		return expression_from(p, update)
	}

	return expr
}

// LHS tail: member access, computed access, calls, tagged templates, optional chaining
parse_lhs_tail :: #force_inline proc(p: ^Parser, start_expr: ^Expression, allow_call: bool) -> ^Expression {
	expr := start_expr
	chain_start: Loc
	is_chain := false
	for {
		#partial switch p.cur_type {
		case .Dot:
			if _, is_inst := expr^.(^TSInstantiationExpression); is_inst {
				report_error(p, "An instantiation expression cannot be followed by a property access.")
			}
			eat(p)
			// §13.3.1 - MemberExpression `.` IdentifierName | PrivateIdentifier.
			// String / Number / template literals after `.` are SyntaxErrors.
			// Test262: language/expressions/property-accessors/non-identifier-name.js.
			if !is_identifier_like_token(p.cur_type) && p.cur_type != .PrivateIdentifier &&
			   !is_keyword_usable_as_property_name(p.cur_type) {
				report_error(p, "Expected identifier after '.'")
				return expr
			}
			// `.in` / `.instanceof` etc.: the lexer's can_start_regex set
			// includes these as regex-starters (they're operators in most
			// contexts), so the next `/` was pre-fetched as a regex literal.
			// In property-access position (\`a.in / b\`) it's division. Relex
			// before consuming the property name. Test:
			// babel/core/uncategorised/326/input.ts (`a.in / b`).
			if (p.cur_type == .In || p.cur_type == .Instanceof) &&
			   p.lexer.nxt.kind == .RegularExpression {
				// Drop any "unterminated regex" lex error that came from
				// the speculative regex-lex.
				for len(p.lexer.lexer_errors) > 0 {
					last := p.lexer.lexer_errors[len(p.lexer.lexer_errors) - 1]
					if last.offset >= p.lexer.nxt.start {
						pop(&p.lexer.lexer_errors)
					} else { break }
				}
				p.lexer.offset = int(p.lexer.nxt.start)
				p.lexer.nxt = lex_slash_as_div(p.lexer)
			}
			prop := parse_identifier_name(p)
			member, member_e := new_expr(p, MemberExpression)
			member.loc = loc_from_expr(expr)
			// OXC includes the `(` in MemberExpression span when object was parenthesized.
			if p.pending_paren_start != max(u32) && p.pending_paren_start <= member.loc.span.start {
				member.loc.span.start = p.pending_paren_start
				p.pending_paren_start = max(u32)
			}
			member.object = expr
			// Check if this is a private identifier (starts with #)
			if len(prop.name) > 0 && prop.name[0] == '#' {
				// Create PrivateIdentifier, strip the # prefix
				pid, pid_e := new_expr(p, PrivateIdentifier)
				pid.loc = prop.loc
				pid.name = prop.name[1:]
				p.private_id_count += 1
				member.property = pid_e
				// Grammar: `PrivateName :: # IdentifierName` - there must be no
				// whitespace between `#` and the identifier. If `pid.name == ""`
				// the lexer saw only `#` with no following IdentifierName.
				if pid.name == "" {
					report_error(p, "Private identifier must not have whitespace after '#'")
				}
				// §15.7.3 "super.#name" early error: enforced by the
				// semantic checker (ck_check_member_super_private).
			} else {
				// Create regular Identifier
				id, id_e := new_expr(p, Identifier)
				id.loc = prop.loc
				id.name = prop.name
				member.property = id_e
			}
			member.computed = false
			member.optional = false
			member.loc.span.end = prev_end_offset(p)
			expr = member_e
		case .OptionalChain:
			if !allow_call {
				return expr
			}
			if !is_chain {
				chain_start = loc_from_expr(expr)
				is_chain = true
				// ECMA-262 §13.3.10 - OptionalExpression only chains from
				// MemberExpression or CallExpression.  NewExpression is
				// not listed, so `new Foo?.()` is a SyntaxError.
				if _, is_new := expr^.(^NewExpression); is_new {
					report_error(p, "Invalid optional chain from new expression")
				}
			}
			eat(p)
			if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) || is_token(p, .PrivateIdentifier) {
				if _, is_inst := expr^.(^TSInstantiationExpression); is_inst {
					report_error(p, "An instantiation expression cannot be followed by a property access.")
				}
				is_private_chain := is_token(p, .PrivateIdentifier)
				prop := parse_identifier_name(p)
				member := new_node(p, MemberExpression)
				member.loc = loc_from_expr(expr)
				member.object = expr
				// `obj?.#priv` - PrivateIdentifier on the RHS of an optional
				// chain is legal per the OptionalChain grammar (§13.3.10).
				if is_private_chain || (len(prop.name) > 0 && prop.name[0] == '#') {
					pid := new_node(p, PrivateIdentifier)
					pid.loc = prop.loc
					name := prop.name
					if len(name) > 0 && name[0] == '#' { name = name[1:] }
					pid.name = name
					p.private_id_count += 1
					member.property = expression_from(p, pid)
				} else {
					// Create regular Identifier
					ident := new_node(p, Identifier)
					ident.loc = prop.loc
					ident.name = prop.name
					member.property = expression_from(p, ident)
				}
				member.computed = false
				member.optional = false // optional flag handled by ChainExpression wrapper
				member.loc.span.end = prev_end_offset(p)
				expr = expression_from(p, member)
			} else if is_token(p, .LBracket) {
				if _, is_inst := expr^.(^TSInstantiationExpression); is_inst {
					report_error(p, "An instantiation expression cannot be followed by a property access.")
				}
				eat(p)
				// Same Expression-not-AssignmentExpression rule as the
				// non-optional `[...]` case above. Optional-chain subscript
				// `obj?.[0, 1]` is legal too.
				prev_no_in_opt := p.no_in
				p.no_in = false
				prop := parse_expression(p)
				p.no_in = prev_no_in_opt
				if prop == nil { return nil }
				if !expect_token(p, .RBracket) { return nil }
				member := new_node(p, MemberExpression)
				member.loc = loc_from_expr(expr)
				member.object = expr
				member.property = prop
				member.computed = true
				member.optional = false // optional flag handled by ChainExpression wrapper
				member.loc.span.end = prev_end_offset(p)
				expr = expression_from(p, member)
			} else if is_token(p, .LParen) {
				args := parse_arguments(p)
				call := new_node(p, CallExpression)
				call.loc = loc_from_expr(expr)
				call.callee = expr
				call.arguments = args
				call.optional = false // optional flag handled by ChainExpression wrapper
				call.loc.span.end = prev_end_offset(p)
				expr = expression_from(p, call)
			} else if is_open_angle_or_lshift(p) && (p.lang == .TS || p.lang == .TSX) {
				// `f?.<T>()` - optional-chain call with TS type arguments.
				// The type-arg list MUST be followed by `(args)` per babel /
				// OXC; otherwise it's a parse error. Build a CallExpression
				// with type_parameters inside the chain. Test:
				// babel/typescript/type-arguments/call-optional-chain/input.ts.
				targs := parse_ts_type_arguments(p)
				if !is_token(p, .LParen) {
					report_error(p, "Expected '(' after type arguments in optional call")
					return expr
				}
				args := parse_arguments(p)
				call := new_node(p, CallExpression)
				call.loc = loc_from_expr(expr)
				call.callee = expr
				call.arguments = args
				call.type_parameters = targs
				call.optional = false // optional flag handled by ChainExpression wrapper
				call.loc.span.end = prev_end_offset(p)
				expr = expression_from(p, call)
			} else {
				report_error(p, "Unexpected token after ?.")
				return expr
			}
		case .LBracket:
			if _, is_inst := expr^.(^TSInstantiationExpression); is_inst {
				report_error(p, "An instantiation expression cannot be followed by a property access.")
			}
			eat(p)
			// Consume pending_paren_start the same way the `.Dot` case
			// above does. When the object was parenthesized (`(expr)[0]`),
			// OXC extends the MemberExpression's start to the `(`. More
			// importantly, the stamp MUST be cleared here - otherwise it
			// leaks past this computed-member into sibling expressions and
			// later statements (observed on antd.js where a stray
			// `(a || b)[0]` expression dragged its paren-start into an
			// unrelated arrow function 83 UTF-16 units downstream).
			//
			// We clear even when we don't actually widen the span (the
			// `paren_start > member.start` branch), because the stamp was
			// set for THIS member access by the outer `(expr)` parser; its
			// intent doesn't survive past us.
			saved_bracket_paren := p.pending_paren_start
			p.pending_paren_start = max(u32)
			// MemberExpression [ Expression ] - Expression includes the
			// comma operator, so `a[0, 1]` is legal (evaluates to a[1]).
			// Reset no_in inside `[...]` so `for (x[a in b]; ...)` parses.
			prev_no_in_sub := p.no_in
			p.no_in = false
			prop := parse_expression(p)
			p.no_in = prev_no_in_sub
			if prop == nil { return nil }
			if !expect_token(p, .RBracket) { return nil }
			mem2, mem2_e := new_expr(p, MemberExpression)
			mem2.loc = loc_from_expr(expr)
			if saved_bracket_paren != max(u32) && saved_bracket_paren <= mem2.loc.span.start {
				mem2.loc.span.start = saved_bracket_paren
			}
			mem2.object = expr
			mem2.property = prop
			mem2.computed = true
			mem2.optional = false
			mem2.loc.span.end = prev_end_offset(p)
			expr = mem2_e
		case .LParen:
			if !allow_call {
				return expr
			}
			// ASI guard: `(` on a new line after an ArrowFunctionExpression
			// with a block body should NOT continue as a call expression.
			// In TS mode, try_parse_ts_arrow_params builds the full arrow
			// inside parse_primary_expr; without this guard the `(` would
			// chain as `(() => { ... })(nextArrow)` instead of ASI-separating
			// into two statements. Matches OXC/V8 behavior.
			if p.cur_tok.had_line_terminator {
				if _, is_arrow := expr^.(^ArrowFunctionExpression); is_arrow {
					return expr
				}
			}
			if _, is_arrow_call := expr^.(^ArrowFunctionExpression); is_arrow_call {
				if p.pending_paren_start == max(u32) {
					report_error(p, "Arrow function must be parenthesized before call")
				}
			}
			// §15.7.6 SuperCall outside derived constructor: enforced by
			// the semantic checker (ck_check_super_call) using its own
			// in_derived_constructor tracker. Parser stays permissive.
			// Save and clear pending_paren_start before parsing arguments.
			// The paren-start from the callee must not propagate into argument
			// sub-expressions (e.g. `(0,f)({prop: g(x)})` - g(x) must not
			// inherit the outer paren offset and shift its own start).
			saved_paren_start := p.pending_paren_start
			p.pending_paren_start = max(u32)
			args := parse_arguments(p)
			call, call_e := new_expr(p, CallExpression)
			call.loc = loc_from_expr(expr)
			if saved_paren_start != max(u32) && saved_paren_start <= call.loc.span.start {
				call.loc.span.start = saved_paren_start
			}
			call.callee = expr
			call.arguments = args
			call.optional = false
			call.loc.span.end = prev_end_offset(p)
			expr = call_e
		case .TemplateHead, .Template:
			// ECMA-262 §13.3.5 - `TaggedTemplateExpression` is a SyntaxError
			// when the tag is an OptionalExpression: the grammar rule
			// `MemberExpression : MemberExpression TemplateLiteral` (and the
			// CallExpression form) cannot compose with optional chaining
			// because the runtime would have to handle `undefined?.foo\`t\``
			// which the spec explicitly forbids. Once we're inside an
			// optional chain (`is_chain`), any template tail is an error.
			if is_chain {
				report_error(p, "Tagged template literals cannot appear in an optional chain")
			}
			tagged := new_node(p, TaggedTemplateExpression)
			tagged.loc = loc_from_expr(expr)
			tagged.tag = expr
			// Tagged template literals don't enforce the strict-mode
			// LegacyOctal/\8/\9 escape rules on their quasi; invalid
			// escapes surface via `cooked: null` at the consumer. Pass
			// `tagged=true` so parse_template_literal skips the check.
			tagged.quasi = parse_template_literal(p, true)
			tagged.loc.span.end = prev_end_offset(p)
			expr = expression_from(p, tagged)
		case .Not:
			// TS non-null assertion `x!`. Only consume `!` as a postfix when
			// the next token can't start a new expression - otherwise `a!b` is
			// ambiguous. Safe next-tokens: operator/punct/terminator.
			// Before checking nxt, handle the regex/division ambiguity.
			// The lexer's can_start_regex saw `!` (prefix-NOT) and lexed
			// the next `/` as regex. In TS mode, postfix `!` (non-null
			// assertion) means `/` is division. Re-lex the lookahead.
			if p.lexer.nxt.kind == .RegularExpression && allow_ts_mode(p) {
				// Remove any "Unterminated regular expression" error that
				// the lexer emitted when it mis-lexed the `/` as regex.
				for len(p.lexer.lexer_errors) > 0 {
					last := p.lexer.lexer_errors[len(p.lexer.lexer_errors) - 1]
					if last.offset >= p.lexer.nxt.start {
						pop(&p.lexer.lexer_errors)
					} else { break }
				}
				p.lexer.offset = int(p.lexer.nxt.start)
				p.lexer.nxt = lex_slash_as_div(p.lexer)
			}
			nxt := p.lexer.nxt.kind
			allow := false
			#partial switch nxt {
			case .Dot, .OptionalChain, .LBracket, .LParen, .Comma, .Semi,
			     .RParen, .RBracket, .RBrace, .Assign, .AssignAdd, .AssignSub,
			     .AssignMul, .AssignDiv, .AssignMod, .AssignPow, .AssignLShift,
			     .AssignRShift, .AssignURShift, .AssignBitAnd, .AssignBitOr,
			     .AssignBitXor, .AssignLogicalAnd, .AssignLogicalOr,
			     .AssignNullish, .Plus, .Minus, .Mul, .Div, .Mod, .Pow,
			     .LogicalAnd, .LogicalOr, .Nullish, .BitAnd, .BitOr, .BitXor,
			     .LShift, .RShift, .URShift, .Eq, .NotEq, .EqStrict, .NotEqStrict,
			     .LAngle, .RAngle, .LEq, .GEq, .Question, .Colon,
			     .Arrow, .EOF, .In, .Instanceof, .As, .Satisfies, .Not,
			     .PlusPlus, .MinusMinus:
				allow = true
			}
			// ASI follower: if the next token is on a new line, consuming
			// `!` here is safe - the next token will trigger ASI in the
			// caller's statement-end check. Without this, `null!\nlet x =
			// 2` reported "Expected semicolon" because the `!` lookahead
			// saw `let` (an Identifier-like) and refused to consume.
			if !allow && (p.lexer.nxt.flags & FLAG_NEW_LINE) != 0 {
				allow = true
			}
			// IMPORTANT: in Odin `break` inside `switch` inside `for` exits
			// the SWITCH only. If we just `break`, the for-loop reruns with
			// p.cur_type still == .Not - infinite loop. Must exit the tail
			// walk (the `!` isn't ours; leave it for the caller's expression
			// parser to treat as an error or binary context).
			if !allow {
				if is_chain {
					chain := new_node(p, ChainExpression)
					chain.loc = chain_start
					chain.expression = expr
					chain.loc.span.end = prev_end_offset(p)
					return expression_from(p, chain)
				}
				return expr
			}
			eat(p) // consume `!`
			// After consuming `!` as a non-null assertion, the next token
			// may have been mis-lexed as regex (because `!` is in the
			// lexer's can_start_regex set for the prefix-NOT case). The
			// postfix assertion means `/` is always division here.

			nn := new_node(p, TSNonNullExpression)
			nn.loc = loc_from_expr(expr)
			nn.expression = expr
			nn.loc.span.end = prev_end_offset(p)
			expr = expression_from(p, nn)
			continue
		case .LAngle, .LShift:
			if _, is_super := expr^.(^Super); is_super {
				report_error(p, "'super' can only be used with function calls or in property accesses")
			}
			// TS generic call / instantiation expression: `foo<T>(args)` or
			// `foo<T>` as a stand-alone TSInstantiationExpression. Only in
			// TS / TSX mode, and only via trial-parse because `<` is also
			// a binary operator. If the trial parses successfully AND the
			// token after `>` can legitimately follow type arguments (`(`,
			// `` ` ``, `.`, `?.`, `,`, `;`, etc.), commit; otherwise rollback
			// so the outer binary-expression parser handles the `<`.
			if p.lang != .TS && p.lang != .TSX {
				if is_chain {
					chain := new_node(p, ChainExpression)
					chain.loc = chain_start
					chain.expression = expr
					chain.loc.span.end = prev_end_offset(p)
					return expression_from(p, chain)
				}
				return expr
			}
			snap := lexer_snapshot(p)
			targs := parse_ts_type_arguments(p)
			// Decide: did the trial consume `<...>` cleanly and land on a
			// followable token? If not, rollback.
			//
			// Two follow sets:
			//   * `call_follow` - `(` / template head: this is a generic call
			//     (CallExpression with type_parameters) or tagged template.
			//   * `inst_follow` - anything that can follow a complete
			//     expression but not start one (binary / postfix / chain
			//     terminators / etc.). Commits to TSInstantiationExpression.
			// Tokens that can plausibly start a NEW expression on the RHS
			// (Identifier, Number, String, `[`, `{`, ...) are deliberately NOT
			// followers, so `f<x> y` rolls back and is reported as a binary-
			// expression error rather than mis-committed as instantiation.
			call_follow := false
			inst_follow := false
			if targs != nil && len(p.errors) == snap.errors_len {
				#partial switch p.cur_type {
				case .LParen, .TemplateHead, .Template:
					call_follow = true
				case .Dot, .OptionalChain,
				     .Comma, .Semi, .RParen, .RBracket, .RBrace,
				     .EOF, .Colon, .Question,
				     .Eq, .NotEq, .EqStrict, .NotEqStrict,
				     .LogicalAnd, .LogicalOr, .Nullish,
				     .As, .Satisfies,
				     // Relational / equality operators (TSInstantiation
				     // followed by binary continuation: `a<b> instanceof C`,
				     // `a<b> in c`, `a<b> < c`, `a<b> >= c`).
				     .Instanceof, .In, .LAngle, .RAngle, .LEq, .GEq,
				     // Arithmetic / bitwise (`a<b> + c`, `a<b> | c`, `a<b> << c`).
				     .Plus, .Minus, .Mul, .Div, .Mod, .Pow,
				     .BitAnd, .BitOr, .BitXor,
				     .LShift, .RShift, .URShift,
				     // Compound assignment lands on whatever target shape
				     // the outer parser permits - `a<b> += c` is invalid in
				     // the spec (instantiation expr isn't an assignment
				     // target) but we still want to commit so the error fires
				     // at the outer level rather than mis-rolling back to a
				     // bogus comparison parse.
				     .AssignAdd, .AssignSub, .AssignMul, .AssignDiv, .AssignMod,
				     .AssignPow, .AssignLShift, .AssignRShift, .AssignURShift,
				     .AssignBitAnd, .AssignBitOr, .AssignBitXor,
				     .AssignLogicalAnd, .AssignLogicalOr, .AssignNullish:
					inst_follow = true
				}
				// ASI follower: when the next token sits on a new line, a
				// freshly-completed `f<T>` is the end-of-statement form
				// (TSInstantiationExpression) and the next line begins a
				// new statement. Without this, `const x = f<true>\nlet y
				// = 0` rolled back to a comparison parse. Test:
				// babel/typescript/type-arguments/instantiation-expression-asi/
				// input.ts.
				if !inst_follow && !call_follow && p.cur_tok.had_line_terminator {
					inst_follow = true
				}
			}
			follow_ok := call_follow || inst_follow
			if !follow_ok {
				lexer_restore(p, snap)
				// Clear any phantom errors emitted by the speculative parse.
				if len(p.errors) > snap.errors_len {
					resize(&p.errors, snap.errors_len)
				}
				if is_chain {
					chain := new_node(p, ChainExpression)
					chain.loc = chain_start
					chain.expression = expr
					chain.loc.span.end = prev_end_offset(p)
					return expression_from(p, chain)
				}
				return expr
			}
			// `new Foo<T>(args)` callee parse: allow_call=false, the type
			// arguments belong to the outer NewExpression, not to us. Roll
			// back so parse_new_expression's own `parse_ts_type_arguments`
			// call picks them up. Same goes for the `(` follower (call_follow)
			// or any binary-style follower (inst_follow): in callee-of-new
			// position, `<T>` is unambiguously the new-expression's type
			// arguments.
			if !allow_call {
				lexer_restore(p, snap)
				if len(p.errors) > snap.errors_len {
					resize(&p.errors, snap.errors_len)
				}
				if is_chain {
					chain := new_node(p, ChainExpression)
					chain.loc = chain_start
					chain.expression = expr
					chain.loc.span.end = prev_end_offset(p)
					return expression_from(p, chain)
				}
				return expr
			}
			// Commit: if followed by `(` AND calls are allowed, it's a
			// CallExpression with type_parameters.
			if is_token(p, .LParen) && allow_call {
				saved_paren2 := p.pending_paren_start
				p.pending_paren_start = max(u32)
				args := parse_arguments(p)
				call, call_e := new_expr(p, CallExpression)
				call.loc = loc_from_expr(expr)
				call.callee = expr
				call.arguments = args
				call.type_parameters = targs
				call.optional = false
				if saved_paren2 != max(u32) && saved_paren2 <= call.loc.span.start {
					call.loc.span.start = saved_paren2
				}
				call.loc.span.end = prev_end_offset(p)
				expr = call_e
				continue
			}
			// Stand-alone TSInstantiationExpression: `f<T>` with no
			// trailing `(args)`. The follower test above already verified
			// the next token can legitimately end / continue an expression,
			// so commit. Per OXC / Babel, when the inner is an optional
			// chain (`a?.b<c>`), the ChainExpression wraps the chain and
			// then TSInstantiationExpression wraps the ChainExpression.
			inner := expr
			inst_start := loc_from_expr(expr)
			if is_chain {
				chain := new_node(p, ChainExpression)
				chain.loc = chain_start
				chain.expression = expr
				chain.loc.span.end = prev_end_offset(p)
				inner = expression_from(p, chain)
				inst_start = chain.loc
				is_chain = false  // we just sealed the chain
			}
			inst, inst_e := new_expr(p, TSInstantiationExpression)
			inst.loc = inst_start
			inst.expression = inner
			inst.type_arguments = targs
			inst.loc.span.end = prev_end_offset(p)
			expr = inst_e
			continue
		case:
			if is_chain {
				// Wrap the entire optional chain in ChainExpression
				chain := new_node(p, ChainExpression)
				chain.loc = chain_start
				chain.expression = expr
				chain.loc.span.end = prev_end_offset(p)
				return expression_from(p, chain)
			}
			return expr
		}
	}
	if is_chain {
		// Wrap the entire optional chain in ChainExpression
		chain := new_node(p, ChainExpression)
		chain.loc = chain_start
		chain.expression = expr
		chain.loc.span.end = prev_end_offset(p)
		return expression_from(p, chain)
	}
	return expr
}

// parse_member_expr is parse_left_hand_side_expr with call-expressions
// disallowed. Used for the callee position of `new EXPR(args)`, where
// the first `(args)` must be attributed to the NewExpression, not to
// the callee as a CallExpression.
parse_member_expr :: proc(p: ^Parser) -> ^Expression {
	expr := parse_primary_expr(p)
	if expr == nil {
		return nil
	}
	return parse_lhs_tail(p, expr, false)
}

parse_left_hand_side_expr :: proc(p: ^Parser) -> ^Expression {
	expr := parse_primary_expr(p)
	if expr == nil {
		return nil
	}
	return parse_lhs_tail(p, expr, true)
}

parse_primary_expr :: proc(p: ^Parser) -> ^Expression {
	current := get_current(p)

	// Statement-only keywords that should never start a primary
	// expression (`(debugger)`, `(else)`, `(extends)`, ...). Without
	// this gate the LParen handler silently swallows the `(` and the
	// remainder is parsed as a lone DebuggerStatement, dropping the
	// inner expression on the floor and emitting no diagnostic.
	if is_keyword_not_expression_start(current.type) {
		msg := fmt.tprintf("Unexpected reserved word '%s'", cur_value(p))
		report_error(p, msg)
		eat(p)
		return nil
	}

	#partial switch current.type {
	case .Import:
		// Check for dynamic import: import(specifier)
		if is_next_token(p, .LParen) {
			return parse_dynamic_import(p, "")
		}
		// Check for import.<property> forms:
		//   import.meta             - MetaProperty (§13.3.12)
		//   import.defer(specifier) - Phase Imports (stage-3, import-defer)
		//   import.source(specifier)- Phase Imports (stage-3, import-source)
		if is_next_token(p, .Dot) {
			eat(p) // consume import
			if !expect_token(p, .Dot) {
				return nil
			}
			meta_name := parse_identifier(p)

			// Phase-import call form: import.defer(...) / import.source(...).
			// Only matches when the property is a known phase AND the next
			// token is `(` - otherwise falls through to MetaProperty so an
			// error surfaces for the bare form.
			if is_token(p, .LParen) &&
			   (meta_name.name == "defer" || meta_name.name == "source") {
				// Hand off to parse_dynamic_import_tail so the import()
				// grammar (AssignmentExpression ,opt [, AssignmentExpression
				// ,opt ]) is shared. Start-loc is the `import` keyword
				// (current, before eat); the helper uses prev_end_offset for
				// the closing paren.
				return parse_dynamic_import_tail(p, loc_from_token(&current), meta_name.name)
			}

			// §Grammar Notation: the `meta` in `import.meta` must not
			// contain Unicode escape sequences.
			if meta_name.name == "meta" {
				// Check the raw source for escape sequences: parse_identifier
				// uses the cooked name but raw source may have \uXXXX.
				span_bytes := p.lexer.source_bytes[meta_name.loc.span.start:meta_name.loc.span.end]
				for b in span_bytes {
					if b == '\\' {
						report_error(p, "'import.meta' property name must not contain Unicode escape sequences")
						break
					}
				}
			}
			// §13.3.12 - The only valid meta property for `import` is
			// `import.meta`.  `import.then`, `import.foo`, etc. are
			// SyntaxErrors.
			if meta_name.name != "meta" {
				msg := fmt.tprintf("The only valid meta property for import is import.meta (got 'import.%s')", meta_name.name)
				report_error(p, msg)
			}
			meta_prop := new_node(p, MetaProperty)
			meta_prop.loc = loc_from_token(&current)
			meta_prop.meta = Identifier{
				loc  = loc_from_token(&current),
				name = "import",
			}
			meta_prop.property = Identifier{
				loc  = meta_name.loc,
				name = meta_name.name,
			}
			meta_prop.loc.span.end = prev_end_offset(p)
			p.has_module_syntax = true
			// `import.meta` is Module syntax. In script sourceType it's a
			// SyntaxError per ECMA-262 §13.3.12.
			if st, have := p.force_source_type.(SourceType); have && st == .Script {
				report_error(p, "'import.meta' is only valid in module code")
			}
			// Collect ESM import.meta record
			esm_import_meta := ESMImportMeta{
				start = meta_prop.loc.span.start,
				end = meta_prop.loc.span.end,
			}
			bump_append(&p.importMetas, esm_import_meta)
			return expression_from(p, meta_prop)
		}
		// Static import - not valid in expression context
		report_error(p, "Unexpected import in expression context")
		return nil

	case .This:
		eat(p)
		this := new_node(p, ThisExpression)
		this.loc = loc_from_token(&current)
		this.loc.span.end = prev_end_offset(p)
		return expression_from(p, this)

	case .PrivateIdentifier:
		// ECMA-262 §13.2 - `#foo` may appear as a PrimaryExpression ONLY
		// when it is the LHS of an `in` operator (ES2022 ergonomic brand
		// check: `#foo in obj`). Every other primary-position use is a
		// SyntaxError, including class-field usages outside a class body
		// and use as an assignment target. `obj.#foo` / `this.#foo` are
		// member accesses - those don't come through here because
		// `parse_lhs_tail` consumes the `#foo` after `.` directly.
		//
		// `#x in #y` (Test262 expressions/in/private-field-in-nested.js)
		// must reject the second `#y`: even though nxt.kind == .In here
		// (the OUTER `in` of `#x in #y in z`), this slot is the RHS of
		// the inner `in`, not its LHS. `in_in_rhs` distinguishes them.
		invalid_position := p.in_in_rhs || p.no_in || !p.private_in_allowed ||
		                    (p.lexer != nil && p.lexer.nxt.kind != .In)
		if invalid_position {
			report_error(p, "Private identifier can only appear as the LHS of an 'in' expression or as a class member")
		}
		// Private field reference: #x (used in expressions like #x in this)
		name := current.value
		if len(name) > 0 && name[0] == '#' {
			name = name[1:]
		}
		pid := new_node(p, PrivateIdentifier)
		pid.loc = loc_from_token(&current)
		pid.name = name
		p.private_id_count += 1
		eat(p)
		pid.loc.span.end = prev_end_offset(p)
		return expression_from(p, pid)

	case .Super:
		// §13.3.7 SuperProperty outside [[HomeObject]] context: enforced
		// by the semantic checker (^Super case in ck_walk_expr) using its
		// own in_method tracker. Parser stays permissive.
		if p.lexer.nxt.kind != .Dot && p.lexer.nxt.kind != .LBracket &&
		   p.lexer.nxt.kind != .LParen {
			report_error(p, "'super' can only be used with function calls or in property accesses")
		}
		eat(p)
		super := new_node(p, Super)
		super.loc = loc_from_token(&current)
		super.loc.span.end = prev_end_offset(p)
		return expression_from(p, super)

	case .Null:
		eat(p)
		nl, nl_e := new_expr(p, NullLiteral)
		nl.loc = loc_from_token(&current)
		nl.loc.span.end = prev_end_offset(p)
		return nl_e

	case .True, .False:
		eat(p)
		bl, bl_e := new_expr(p, BooleanLiteral)
		bl.loc = loc_from_token(&current)
		bl.value = current.type == .True
		bl.loc.span.end = prev_end_offset(p)
		return bl_e

	case .Number:
		eat(p)
		num, num_e := new_expr(p, NumericLiteral)
		num.loc = loc_from_token(&current)
		num.raw = current.value
		if val, ok := current.literal.(f64); ok {
			num.value = val
		}
		num.loc.span.end = prev_end_offset(p)
		// ECMA-262 Annex B.1.1 + §13.2.5.1 - LegacyOctalIntegerLiteral
		// (`0777`) and NonOctalDecimalIntegerLiteral (`078`) are
		// SyntaxErrors in strict mode. Both share the shape:
		// `0<digit>+` where the second char is a decimal digit (not
		// `x`/`X`/`o`/`O`/`b`/`B`/`.`/`e`/`E`/`n`).
		// §12.9.3.5 legacy octal in strict mode: enforced by the
		// semantic checker (ck_check_legacy_octal_number).
		return num_e

	case .String:
		eat(p)
		str, str_e := new_expr(p, StringLiteral)
		str.loc = loc_from_token(&current)
		str.raw = current.value
		if val, ok := current.literal.(string); ok {
			str.value = val
		}
		str.loc.span.end = prev_end_offset(p)
		// §12.9.4 octal / \8 / \9 escape in strict mode: enforced by
		// the semantic checker (ck_check_string_octal_escape). Note this
		// also covers the parser's old retroactive prologue scan: the
		// checker walks every StringLiteral in the function body with
		// strict_mode already lifted, so a bad escape in a directive
		// prologue PRECEDING `"use strict"` fires correctly.
		return str_e

	case .BigInt:
		eat(p)
		big := new_node(p, BigIntLiteral)
		big.loc = loc_from_token(&current)
		big.raw = current.value
		big.value = current.value  // Store as string
		// §12.9.3 legacy-octal BigInt: enforced by the semantic checker
		// (ck_check_legacy_octal_bigint). Always errors regardless of
		// strict mode.
		big.loc.span.end = prev_end_offset(p)
		return expression_from(p, big)

	case .Async:
		// async function expression or arrow function
		// Lookahead to check what follows async
		next := peek_dispatch(p)
		// ECMA-262 §15.8 / §15.9 Restricted Productions: no LineTerminator
		// between `async` and the following `function` / BindingIdentifier /
		// `(`. If there is one, the grammar rule fails and ASI treats `async`
		// as a bare IdentifierReference; the lookahead token starts a new
		// statement/expression.
		//
		// §Grammar Notation: terminal symbols must not contain Unicode escape
		// sequences. `\u0061sync` is NOT the `async` keyword. Detect by
		// checking the token's has_escape flag.
		if current.has_escape {
			// Escaped async: `\u0061sync function f(){}` is a SyntaxError
			// because the `async` keyword must appear literally. Report and
			// fall through to treat it as an identifier.
			report_error(p, "'async' keyword must not contain Unicode escape sequences")
			eat(p)
			ident := new_node(p, Identifier)
			ident.loc = loc_from_token(&current)
			// S26 W5b - use the SOURCE-SLICE name, not a string literal.
			// `"async"` is a compile-time literal whose `raw_data` lives in the
			// binary's RODATA segment - outside both the source-bytes range and
			// the parser arena range. raw_transfer's rewrite_string then writes
			// a garbage offset for the field, and the binary buffer surfaces
			// the Identifier with `name=""`. JSON path is correct (it just
			// prints the live Odin string), so the bug stayed silent until W5
			// extended verify_integration to walk Identifier names through every
			// reachable expression slot. Source slice is in-source, so
			// rewrite_string's source-base branch fires and produces a
			// well-formed offset.
			ident.name = current.value
			ident.loc.span.end = prev_end_offset(p)
			return expression_from(p, ident)
		}
		async_lt_break := next.had_line_terminator
		async_arrow_ctx_kw := false  // async <contextual-kw> => x
		if !async_lt_break && next.type == .Function {
			// async function() {} - function expression
			return parse_function_expression(p)
		} else if !async_lt_break && next.type != .Identifier && next.type != .LParen &&
		          is_identifier_like_token(next.type) {
			// `async <contextual-kw>`: ambiguous between async-arrow
			//   `async of => x`   (async arrow with `of` as binding)
			// and bare-async + for-of head
			//   `for await (async of x)`   (`async` is the LHS Identifier)
			// Disambiguate via SOURCE-BYTE lookahead: scan past the next
			// token to see whether the following non-whitespace bytes are
			// `=>`. If yes, commit to the arrow path; otherwise let the
			// `.Async`-as-Identifier fall-through below run, which keeps
			// the for-await-of test (head-lhs-async.js) parsing.
			if p.lexer != nil {
				src := p.lexer.source_bytes
				i := int(next.raw_end)
				src_len := len(src)
				for i < src_len {
					ch := src[i]
					if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { i += 1; continue }
					break
				}
				if i + 1 < src_len && src[i] == '=' && src[i+1] == '>' {
					async_arrow_ctx_kw = true
				}
			}
		}
		if !async_lt_break && (next.type == .Identifier || next.type == .LParen || async_arrow_ctx_kw ||
		   (allow_ts_mode(p) && next.type == .LAngle)) {
			// This might be an async arrow function: async x => x or async () => {}
			if next.type == .Identifier || async_arrow_ctx_kw {
				// async x => ...
				// Snapshot before consuming both tokens. If `=>` doesn't
				// follow the param identifier, roll back so only `async`
				// is consumed as a bare IdentifierReference. Without this,
				// `async functionX ()` loses `functionX` entirely.
				snap_async := lexer_snapshot(p)
				snap_errs := len(p.errors)
				eat(p) // consume async
				param_ident := parse_identifier(p)
				if is_token(p, .Arrow) {
					return parse_async_arrow_function(p, param_ident)
				}
				// Not an arrow — roll back to just after `async`, let the
				// LHS-tail / expression parser handle the next tokens.
				lexer_restore(p, snap_async)
				if len(p.errors) > snap_errs {
					resize(&p.errors, snap_errs)
				}
				eat(p) // re-consume only `async`
				ident := new_node(p, Identifier)
				ident.loc = loc_from_token(&current)
				ident.name = current.value
				ident.loc.span.end = prev_end_offset(p)
				return expression_from(p, ident)
			} else if next.type == .LParen {
				// `async (...)` is ambiguous: an async arrow head, OR a
				// regular call to `async`. Source-byte lookahead at the
				// matching `)` decides: if `=>` follows, it's an arrow;
				// otherwise treat `async` as a plain IdentifierReference
				// and let the LHS-tail parser build the CallExpression.
				// Test262: annexB/language/expressions/assignmenttargettype/
				// cover-callexpression-and-asyncarrowhead.js.
				is_arrow_head := false
				if p.lexer != nil {
					src := p.lexer.source_bytes
					lparen_off := int(next.raw_end) - 1
					// `next.raw_end` is just past `(`, so `lparen_off` is
					// the `(` byte. Walk forward tracking nesting depth
					// over parens/brackets/braces; stop at the matching `)`.
					// Skip string / template content so embedded brackets
					// don't break the depth count.
					depth := 0
					i := lparen_off
					src_len := len(src)
					end_off := -1
					scan: for i < src_len {
						ch := src[i]
						switch ch {
						case '(', '[', '{':
							depth += 1
						case ')', ']', '}':
							depth -= 1
							if depth == 0 && ch == ')' {
								end_off = i
								break scan
							}
						case '"', '\'':
							quote := ch
							i += 1
							for i < src_len && src[i] != quote {
								if src[i] == '\\' && i + 1 < src_len { i += 1 }
								i += 1
							}
						case '/':
							// Bare `/` could be division or comment;
							// skip a single-line `//` so we don't read
							// `=>` from inside a comment.
							if i + 1 < src_len && src[i+1] == '/' {
								for i < src_len && src[i] != '\n' { i += 1 }
							} else if i + 1 < src_len && src[i+1] == '*' {
								i += 2
								for i + 1 < src_len && !(src[i] == '*' && src[i+1] == '/') { i += 1 }
								if i + 1 < src_len { i += 1 }
							}
						}
						i += 1
					}
					if end_off >= 0 {
						j := end_off + 1
						// Skip whitespace AND comments (Test262 has
						// `... ) /* f */ => /* g */ { ... }`).
						for j < src_len {
							ch := src[j]
							if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { j += 1; continue }
							if ch == '/' && j + 1 < src_len && src[j+1] == '/' {
								for j < src_len && src[j] != '\n' { j += 1 }
								continue
							}
							if ch == '/' && j + 1 < src_len && src[j+1] == '*' {
								j += 2
								for j + 1 < src_len && !(src[j] == '*' && src[j+1] == '/') { j += 1 }
								if j + 1 < src_len { j += 2 }
								continue
							}
							break
						}
						// TS / TSX async arrow with return type annotation:
						// `async (): T => body`. After the matching `)` the
						// next non-trivia byte is `:`; the type annotation
						// extends until the `=>` (skipping balanced
						// `<>` / `()` / `[]` / `{}` and string content).
						// Pre-fix the lookahead bailed at the `:` and treated
						// `async (...)` as a plain CallExpression of `async`.
						// Closes ~30 OXC corpus rejects in the
						// "Expected semicolon" cluster (S26 W6 phase 3 #17).
						// TS return-type lookahead. When inside a ternary
						// consequent AND there's no extra wrapping paren
						// before `async`, the `:` after `async(b)` is the
						// ternary's alt separator, NOT a return type.
						// `(async(b): T => ...)` inside parens is fine.
						skip_return_type := false
						if p.conditional_depth > 0 {
							// Check if `async` is shielded by outer parens.
							async_pos := int(current.loc)
							shielded := false
							for k := async_pos - 1; k >= 0; k -= 1 {
								ch := src[k]
								if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { continue }
								if ch == '(' { shielded = true }
								break
							}
							skip_return_type = !shielded
						}
						if (p.lang == .TS || p.lang == .TSX) && !skip_return_type && j < src_len && src[j] == ':' {
							j += 1
							t_depth := 0
							ts_scan: for j < src_len {
								tch := src[j]
								switch tch {
								case '<', '(', '[', '{':
									t_depth += 1
								case '>', ')', ']', '}':
									if t_depth == 0 {
										// Hit a closer outside any nested
										// group - type ended without `=>`,
										// not an arrow head.
										break ts_scan
									}
									t_depth -= 1
								case '=':
									if t_depth == 0 && j + 1 < src_len && src[j+1] == '>' {
										is_arrow_head = true
										break ts_scan
									}
								case ',', ';':
									if t_depth == 0 { break ts_scan }
								case '"', '\'':
									quote := tch
									j += 1
									for j < src_len && src[j] != quote {
										if src[j] == '\\' && j + 1 < src_len { j += 1 }
										j += 1
									}
								case '/':
									if j + 1 < src_len && src[j+1] == '/' {
										for j < src_len && src[j] != '\n' { j += 1 }
									} else if j + 1 < src_len && src[j+1] == '*' {
										j += 2
										for j + 1 < src_len && !(src[j] == '*' && src[j+1] == '/') { j += 1 }
										if j + 1 < src_len { j += 1 }
									}
								}
								j += 1
							}
						} else if j + 1 < src_len && src[j] == '=' && src[j+1] == '>' {
							is_arrow_head = true
						}
					}
				}
				if is_arrow_head {
					eat(p) // consume async
					return parse_async_arrow_with_parens(p, current)
				}
				// Fall through: `async` will be re-parsed as a bare
				// IdentifierReference below; the LHS-tail loop then
				// consumes `(...)` as a CallExpression.
			} else if allow_ts_mode(p) && next.type == .LAngle {
				// TS async generic arrow: `async <T>(a: T): T => a`.
				// Trial-parse: consume `async`, parse `<T>` as type params,
				// then delegate to the paren-params path. On failure, roll
				// back and treat `async` as a plain identifier.
				snap := lexer_snapshot(p)
				eat(p) // consume async
				type_params := parse_ts_type_parameters(p)
				if is_token(p, .LParen) {
					arrow := parse_async_arrow_with_parens(p, current)
					if arrow != nil {
						// Attach the type parameters.
						if ae, ok := arrow^.(^ArrowFunctionExpression); ok && ae != nil {
							ae.type_parameters = type_params
						}
						if len(p.errors) == snap.errors_len {
							return arrow
						}
					}
				}
				lexer_restore(p, snap)
			}
		}
		// async as identifier
		// S26 W5b: source-slice name (see escaped-async branch for why a literal breaks raw_transfer).
		eat(p)
		ident := new_node(p, Identifier)
		ident.loc = loc_from_token(&current)
		ident.name = current.value
		ident.loc.span.end = prev_end_offset(p)
		return expression_from(p, ident)

	case .Identifier, .Get, .Set, .From, .Of, .As, .Let, .Static, .Constructor,
	     .Assert, .Asserts, .Abstract, .Declare, .Readonly, .Override,
	     .Keyof, .Infer, .Is, .Satisfies, .Never, .Unique, .Namespace, .Module,
	     .Implements, .Require, .Package, .Private, .Protected, .Public,
	     .Accessor, .Target, .Await, .Yield:
		// All contextual keywords are valid identifiers in expression context.
		// TS keywords (type, interface, enum) lex as Identifier and are
		// handled via string-value check in parse_statement_or_declaration.
		// ECMA-262 §12.7.2: if the identifier arrived via \uXXXX escape and
		// its cooked StringValue matches a ReservedWord, IdentifierReference
		// is a Syntax Error (check runs before eat so loc is correct).
		report_escaped_reserved_word(p)
		// §12.1.1 - `enum` is a FutureReservedWord that is ALWAYS
		// reserved (all modes, strict and sloppy). The lexer emits
		// `enum` as .Identifier (contextual for TS enum decls), so
		// we must check by value here in expression position.
		if current.value == "enum" {
			report_error(p, "'enum' is a reserved word")
		}
		// §12.6.1.1 - strict-mode IdentifierReference cannot be "let" /
		// "yield" / "implements" / "interface" / "package" /
		// "private" / "protected" / "public" / "static". The lexer emits
		// .Let / .Static / .Yield as dedicated tokens and the rest as
		// .Identifier, so check both channels. `yield` inside a generator
		// and `await` inside async are handled by the dedicated keyword
		// paths earlier in parse_unary_expr - we only reach here for
		// §12.6.1.1 strict-mode IdentifierReference reservation check is
		// enforced by the semantic checker
		// (ck_check_identifier_reference_strict).

		// §16.2 / §15.7.5 — `await` as IdentifierReference in async /
		// async-params / class-static-block context is enforced by the
		// semantic checker (ck_check_identifier_await_reserved). The
		// has_escape flag is propagated below to the Identifier so the
		// checker can match the parser's narrow gating.
		// Escaped `async` before `function` is SyntaxError. The lexer
		// emits `.Identifier` (not `.Async`) for `\u0061sync`, so the
		// `.Async` case's escape check doesn't fire.
		if current.has_escape && current.value == "async" {
			nxt := peek_token(p)
			if nxt.type == .Function && !nxt.had_line_terminator {
				report_error(p, "'async' keyword must not contain Unicode escape sequences")
			}
		}
		eat(p)
		id, id_expr := new_expr(p, Identifier)
		id.loc = loc_from_token(&current)
		id.name = current.value
		id.has_escape = current.has_escape
		id.loc.span.end = prev_end_offset(p)
		return id_expr

	case .LParen:
		// Check for arrow function with empty params: () => ...
		if is_next_token(p, .RParen) {
			// Potential empty arrow function params. In TS / TSX `(): T =>`
			// shape we need to drop into try_parse_ts_arrow_params so the
			// return-type annotation is consumed; defer the eat-pair to the
			// trial parser in that case.
			if allow_ts_mode(p) {
				// Peek past `()` to detect `: T =>`. Cheap byte-scan via
				// looks_like_ts_arrow_params (already does this for the
				// non-empty cases; the empty case lands here too because
				// the byte-scan doesn't depend on the token kind).
				if looks_like_ts_arrow_params(p) {
					if arrow := try_parse_ts_arrow_params(p, current); arrow != nil {
						return arrow
					}
				}
			}
			eat(p) // consume (
			eat(p) // consume )
			if is_token(p, .Arrow) {
				// This is () => ... - return a marker for empty params
				seq := new_node(p, SequenceExpression)
				seq.loc = loc_from_token(&current)
				seq.expressions = make([dynamic]^Expression, 0, 4, p.allocator)
				return expression_from(p, seq)
			}
			// Not an arrow, return nil (empty parens not valid expression)
			report_error(p, "Empty parenthesized expression")
			return nil
		}

		// TS trial-parse (K4): `(x: T) => x`, `(...rest: T[]) => ...`, etc.
		// The `:Type` annotation on a parameter is not valid JS syntax inside
		// plain paren-grouping, so parse_expr_with_prec would fail. When in
		// TS / TSX mode and the `(` clearly opens arrow parameters (rest
		// marker, or `Identifier :`), trial-parse as function parameters and
		// build the arrow directly. On failure we roll back cleanly and fall
		// through to the normal paren-grouping path.
		if allow_ts_mode(p) && looks_like_ts_arrow_params(p) {
			if arrow := try_parse_ts_arrow_params(p, current); arrow != nil {
				return arrow
			}
		}

		// Regular parenthesized expression. Use Comma precedence to handle
		// (x, y) => ... arrow function case.
		//
		// Record the `(` position BEFORE eating it. parse_arrow_function reads
		// pending_paren_start when the next token turns out to be `=>` so the
		// arrow span starts AT the paren, matching OXC/Acorn/Babel. A nested
		// `(` would overwrite the outer's stamp - harmless because the inner
		// is consumed and cleared before the outer reaches `=>`.
		paren_start := cur_loc(p).span.start
		eat(p)
		// Save and clear pending_paren_start so nested expressions don't use this paren.
		// We'll restore it below only if the next token is Arrow (for arrow function params).
		prev_pending_paren := p.pending_paren_start
		p.pending_paren_start = max(u32)
		prev_no_in := p.no_in
		p.no_in = false  // 'in' is always valid inside parentheses
		// Parens reset the in-RHS context so `(#x in y)` parses cleanly
		// even when the surrounding expression is the RHS of another `in`.
		prev_in_in_rhs := p.in_in_rhs
		p.in_in_rhs = false
		expr := parse_expr_with_prec(p, .Comma)
		p.in_in_rhs = prev_in_in_rhs
		p.no_in = prev_no_in
		if expr == nil {
			return nil
		}
		paren_expr_had_trailing_comma := false
		if p.lexer != nil && is_token(p, .RParen) {
			src := p.lexer.source_bytes
			k := int(cur_offset(p)) - 1
			for k >= 0 {
				c := src[k]
				if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
					k -= 1
					continue
				}
				paren_expr_had_trailing_comma = c == ','
				break
			}
		}
		if !expect_token(p, .RParen) {
			return nil
		}
		if paren_expr_had_trailing_comma && !is_token(p, .Arrow) {
			report_error(p, "Parenthesized expressions may not have a trailing comma.")
		}
		if _, is_spread_expr := expr.(^SpreadElement); is_spread_expr && !is_token(p, .Arrow) {
			report_error(p, "Expected `=>` after parenthesized rest parameter")
		}
		// Note: OXC/Acorn do NOT adjust the inner expression span to
		// include the parentheses in most cases. The parentheses are
		// syntactic, not semantic - the inner expression keeps its own
		// natural span. pending_paren_start handles the special cases
		// (arrow functions, call expressions).
		// Set pending_paren_start for this paren. Used by arrow function
		// parameters, CallExpressions, and MemberExpressions whose object
		// was parenthesized. OXC includes `(` in the span of calls,
		// member access, and arrow functions that follow `(expr)`.
		if is_token(p, .Arrow) || is_token(p, .LParen) || is_token(p, .Dot) ||
		   is_token(p, .LBracket) || is_token(p, .OptionalChain) {
			p.pending_paren_start = paren_start
		} else {
			p.pending_paren_start = prev_pending_paren
		}

		// EST-3 / OPT-3 `--preserve-parens`: wrap the inner expression in
		// a ParenthesizedExpression node matching Acorn/OXC's shape. Skip
		// when `=>` follows - that path is cover-for-arrow-params and the
		// downstream arrow builder expects the raw inner expression to
		// lower to FunctionParameter via expr_to_pattern.
		if p.preserve_parens && !is_token(p, .Arrow) {
			paren_node := new_node(p, ParenthesizedExpression)
			paren_node.loc.span.start = paren_start
			paren_node.loc.span.end = prev_end_offset(p)
			paren_node.expression = expr
			wrapped := expression_from(p, paren_node)
			p.last_paren_expr = wrapped
			return wrapped
		}
		// Stamp the bare inner expression as paren-wrapped so a subsequent
		// `=` triggers the AssignmentTargetType check in parse_assignment_expr.
		// Skip the stamp when `=>` follows: that path is the arrow-param
		// cover production, where the parens belong to the arrow's parameter
		// list, not to a value-grouping parenthesisation.
		if !is_token(p, .Arrow) {
			p.last_paren_expr = expr
			// SpreadElement/RestElement inside `(...)` without `=>`
			// is invalid — rest/spread in parens is only the
			// cover grammar for arrow function parameters.
			if expr_contains_spread(expr) {
				report_error(p, "Unexpected spread/rest element outside of arrow parameters")
			}
		}
		return expr

	case .LBracket:
		return parse_array_expr(p)

	case .LBrace:
		return parse_object_expr(p)

	case .Function:
		return parse_function_expression(p)

	case .Class:
		return parse_class_expression(p)

	case .At:
		// Decorator on a class expression: `@dec class {}`. Same
		// `parse_decorators` walker as the statement-position decorated
		// class. Decorator-on-expression is the stage-3 form (only
		// applies to ClassExpression - nothing else accepts decorators).
		decorators := parse_decorators(p)
		if !is_token(p, .Class) {
			report_error(p, "Decorators can only be applied to class expressions")
			return nil
		}
		cls := parse_class_expression(p)
		if cls != nil {
			if ce, ok := cls.(^ClassExpression); ok && ce != nil {
				ce.decorators = decorators
				if len(decorators) > 0 {
					ce.loc.span.start = decorators[0].loc.span.start
				}
			}
		}
		return cls

	case .New:
		return parse_new_expr(p)

	case .Template, .TemplateHead:
		return parse_template_literal(p, false)

	case .RegularExpression:
		eat(p)
		regex := new_node(p, RegExpLiteral)
		regex.loc = loc_from_token(&current)
		// Parse pattern and flags from token value (format: /pattern/flags)
		raw := current.value
		if len(raw) >= 2 && raw[0] == '/' {
			// Find the last / that separates pattern from flags
			last_slash := -1
			for i := len(raw) - 1; i >= 0; i -= 1 {
				if raw[i] == '/' {
					last_slash = i
					break
				}
			}
			if last_slash > 0 {
				regex.pattern = intern(p.interner, raw[1:last_slash])
				if last_slash + 1 < len(raw) {
					regex.flags = intern(p.interner, raw[last_slash + 1:])
				}
			}
		}
		regex.loc.span.end = prev_end_offset(p)
		return expression_from(p, regex)

	case .LAngle:
		// Dispatch depends on language mode:
		//   TS  → TS type assertion `<Type>expr` or generic arrow
		//          `<T>(x) => x`. No JSX ambiguity in pure TS mode.
		//   TSX → Genuine ambiguity. OXC/TS-ESTree rule:
		//          * `<T,>` (trailing comma) → generic arrow.
		//          * `<T extends ...>` → try generic arrow.
		//          * `<Type>expr` type-assertions are FORBIDDEN in .tsx
		//            (use `expr as Type` instead). Fall through to JSX.
		//          * Anything else → JSX element / fragment.
		//   JSX → JSX element / fragment (no TS types).
		//   JS  → syntax error (comparison needs a LHS operand).
		if p.lang == .TSX {
			// TSX Phase C: try generic arrow when trailing comma
			// or `extends` follows the type parameter identifier.
			// A 2-token speculative peek (no consume): peek past `<`
			// to the first token; if it's an Identifier, peek again
			// to see what follows.
			nxt_kind := p.lexer.nxt.kind
			if nxt_kind == .Identifier {
				snap := lexer_snapshot(p)
				eat(p)  // consume `<`
				eat(p)  // consume the identifier
				after := p.cur_type
				lexer_restore(p, snap)
				// Trailing comma `<T,>` or `extends` / `=` signal → try
				// as generic arrow. On failure fall through to JSX.
				if after == .Comma || after == .Extends || after == .Assign {
					lt_start := cur_loc(p)
					snap2 := lexer_snapshot(p)
					result := parse_ts_generic_arrow(p, lt_start)
					if result != nil && len(p.errors) == snap2.errors_len {
						return result
					}
					lexer_restore(p, snap2)
				}
			}
			// Fall through to JSX (covers tags, fragments, and the
			// forbidden-in-TSX `<Type>expr` form which JSX will
			// reject as a malformed element).
			return parse_jsx_element_or_fragment(p)
		}
		if allow_jsx_mode(p) {  // .JSX only (not .TSX - handled above)
			return parse_jsx_element_or_fragment(p)
		}
		if allow_ts_mode(p) {
			return parse_ts_lt_expression(p)
		}
		report_error(p, "Unexpected '<' at expression start")
		return nil
	case:
		// Unknown token type
		return nil
	}
}

parse_array_expr :: proc(p: ^Parser) -> ^Expression {
	start := cur_loc(p)

	if !expect_token(p, .LBracket) {
		return nil
	}

	arr := new_node(p, ArrayExpression)
	arr.loc = start
	// Lazy alloc - empty array literals (`[]`) are common as default
	// values, accumulator initializers (`reduce((acc=[], x) => ...)`),
	// and explicit no-op cases. Defer the bump reservation until we
	// know there's at least one element.
	if !is_token(p, .RBracket) && !is_token(p, .EOF) {
		// Cap bumped from 8 → 16 (S23). Array literals with >8 elements
		// triggered 520 slow-path grows on monaco. Common in const-data
		// arrays (lookup tables, error-code lists, opcode tables).
		arr.elements = make([dynamic]Maybe(^Expression), 0, 16, p.allocator)
	}

	// Inside an ArrayExpression literal, `in` is always valid as a
	// binary operator - the enclosing §no_in flag (used to peek for
	// for-in/of heads) must NOT leak into element sub-expressions.
	// `for ([ x = 'x' in {} ] of y)` needs the inner `'x' in {}` to
	// parse as a binary expression, not bail at `in`.
	prev_no_in := p.no_in
	p.no_in = false
	defer p.no_in = prev_no_in
	// Slice 14: scope_skip is now tracked by the checker; the parser
	// no longer suppresses anything during element-walk.

	for !is_token(p, .RBracket) && !is_token(p, .EOF) {
		if match_token(p, .Comma) {
			// Sparse element
			bump_append(&arr.elements, nil)
			continue
		}

		if is_token(p, .Dot3) {
			// Spread element
			spread_start := cur_loc(p) // Capture location of ... before eating
			eat(p)
			arg := parse_assignment_expression(p)
			if arg != nil {
				spread := new_node(p, SpreadElement)
				spread.loc = spread_start // Use location of ... token
				spread.argument = arg
				spread.loc.span.end = prev_end_offset(p)
				bump_append(&arr.elements, Maybe(^Expression)(expression_from(p, spread)))
			}
		} else {
			elem := parse_assignment_expression(p)
			if elem != nil {
				bump_append(&arr.elements, Maybe(^Expression)(elem))
			}
		}

		if !match_token(p, .Comma) {
			break
		}
	}

	if !expect_token(p, .RBracket) {
		return nil
	}

	arr.loc.span.end = prev_end_offset(p)
	return expression_from(p, arr)
}

// A Property qualifies as a literal `__proto__: ...` data property when:
//   - the key is a plain Identifier `__proto__` or a StringLiteral
//     whose value is `"__proto__"`,
//   - the property is NOT computed (`{ ["__proto__"]: x }` is fine),
//   - the kind is `.Init` (methods / getters / setters are fine),
//   - it is NOT a shorthand (`{ __proto__ }` references the local
//     binding, not the proto slot).
// Only literal-key init properties contribute to the §13.2.5.1
// duplicate-__proto__ early error.
property_is_literal_proto_init :: proc(prop: ^Property) -> bool {
	if prop == nil { return false }
	if prop.computed || prop.shorthand { return false }
	if prop.kind != .Init { return false }
	if prop.key == nil { return false }
	#partial switch k in prop.key^ {
	case ^Identifier:
		return k != nil && k.name == "__proto__"
	case ^StringLiteral:
		return k != nil && k.value == "__proto__"
	}
	return false
}

parse_object_expr :: proc(p: ^Parser) -> ^Expression {
	start := cur_loc(p)

	if !expect_token(p, .LBrace) {
		return nil
	}

	obj := new_node(p, ObjectExpression)
	obj.loc = start
	// Lazy alloc - empty object literals (`{}`) are common as default
	// argument values, options bags, factory return shapes, etc. Defer
	// the bump reservation until we know there's at least one property.
	if !is_token(p, .RBrace) && !is_token(p, .EOF) && !is_token(p, .Semi) {
		// Cap bumped from 4 → 8 (S23). Object literals with >4 properties
		// triggered 661 slow-path grows on monaco. Common in config objects
		// (`{ name, type, kind, value, span, comments }` etc).
		obj.properties = make([dynamic]Property, 0, 8, p.allocator)
	}

	// Inside an ObjectExpression literal, `in` is always valid as a
	// binary operator - same rule as parse_array_expr. Clear no_in so
	// `for ({a: 'x' in {}} of y)` works.
	prev_no_in := p.no_in
	p.no_in = false
	defer p.no_in = prev_no_in
	// Slice 14: scope_skip is now tracked by the checker; the parser
	// no longer suppresses anything during property-walk.

	// §13.2.5.1 duplicate __proto__ early error: enforced by the
	// semantic checker (ck_check_object_proto_dups). The parser is
	// permissive on this; the AST distinguishes ObjectExpression from
	// ObjectPattern, so the checker can decide cleanly post-parse.

	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		// Skip stray semicolons (error recovery)
		for is_token(p, .Semi) {
			eat(p)
		}
		if is_token(p, .RBrace) || is_token(p, .EOF) {
			break
		}

		prop := parse_property(p)
		if prop != nil {
			// Duplicate-__proto__ early error (§13.2.5.1) is enforced by
			// the semantic checker (slice 4) — see ck_check_object_proto_dups.
			bump_append(&obj.properties, prop^)
		}

		if !match_token(p, .Comma) {
			// Semicolons are not valid in object literals (spec §13.2.5).
			// Report the error and eat them for error recovery.
			if is_token(p, .Semi) {
				report_error(p, "Unexpected ';' in object literal")
				for is_token(p, .Semi) {
					eat(p)
				}
			} else {
				break
			}
		}
		// Double comma: `{x: 0,,}` - object literals don't allow elisions.
		for is_token(p, .Comma) {
			report_error(p, "Property assignment expected")
			eat(p)
		}
		// Also skip stray semicolons after comma
		for is_token(p, .Semi) {
			eat(p)
		}
	}

	if !expect_token(p, .RBrace) {
		return nil
	}

	obj.loc.span.end = prev_end_offset(p)
	return expression_from(p, obj)
}

parse_property :: proc(p: ^Parser) -> ^Property {
	start := cur_loc(p)

	computed := false
	key: ^Expression

	if is_token(p, .Dot3) {
		// Spread property: ...expr
		spread_start := cur_loc(p) // Capture location before eating the ...
		eat(p)
		arg := parse_assignment_expression(p)
		if arg == nil {
			return nil
		}

		// Wrap the argument in a SpreadElement
		spread := new_node(p, SpreadElement)
		spread.loc = spread_start // Use the location of the ... token, not the argument
		spread.argument = arg
		spread.loc.span.end = prev_end_offset(p)

		prop := new_node(p, Property)
		prop.loc = start
		prop.key = nil
		prop.value = expression_from(p, spread)
		prop.kind = .Init
		prop.computed = false
		prop.shorthand = false
		prop.loc.span.end = prev_end_offset(p)
		return prop
	}

	// Check for get/set keywords and generator/async modifiers
	is_getter := false
	is_setter := false
	is_generator := false
	is_async := false

	if is_token(p, .Get) || is_token(p, .Set) {
		// Only treat as getter/setter if followed by a property name (not : or ( directly).
		// Any keyword can be a property name (ES spec: PropertyName → IdentifierName).
		next := peek_token(p)
		if next.type == .Identifier || next.type == .String || next.type == .Number ||
		   next.type == .BigInt || next.type == .LBracket || next.type == .Mul ||
		   is_keyword_usable_as_property_name(next.type) {
			if is_token(p, .Get) {
				is_getter = true
			} else {
				is_setter = true
			}
			eat(p)
		}
	} else if is_token(p, .Async) {
		// Only treat as async if followed by a property name or `*`.
		// `{ async() {} }` is a method NAMED "async" (no async modifier),
		// not an async method with an empty name - LParen here exits the
		// async-modifier branch and falls through to the regular key path.
		next := peek_token(p)
		if next.type == .Identifier || next.type == .String || next.type == .Number ||
		   next.type == .BigInt || next.type == .LBracket || next.type == .Mul ||
		   is_keyword_usable_as_property_name(next.type) {
			// §15.8.1 Restricted Production - no LineTerminator between
			// `async` and the method name. With a newline, `async` is the
			// shorthand property name and what follows is the next member.
			if !next.had_line_terminator {
				eat(p)
				is_async = true
			}
		}
	}

	// Check for generator modifier (can come after async or before identifier)
	if is_token(p, .Mul) {
		eat(p)
		is_generator = true
		// After `*`, a property name must follow. `{ * }` is invalid.
		if is_token(p, .RBrace) || is_token(p, .Comma) || is_token(p, .RParen) {
			report_error(p, "Expected method name after '*'")
			return nil
		}
	}

	// Parse key
	if match_token(p, .LBracket) {
		computed = true
		// `[` clears the for-head no_in restriction - see parse_class_element /
		// parse_object_pattern for the parallel resets.
		prev_no_in_prop := p.no_in
		p.no_in = false
		key = parse_assignment_expression(p)
		p.no_in = prev_no_in_prop
		if key == nil {
			return nil
		}
		if !expect_token(p, .RBracket) {
			return nil
		}
	} else if is_token(p, .BigInt) {
		// BigInt literal key: `{ 1n: value }`. The numeric value is
		// the string representation of the BigInt, per §13.2.3.1.
		current := get_current(p)
		big := new_node(p, BigIntLiteral)
		big.loc = loc_from_token(&current)
		big.raw = current.value
		if len(current.value) > 0 && current.value[len(current.value)-1] == 'n' {
			big.value = current.value[:len(current.value)-1]
		} else {
			big.value = current.value
		}
		big.loc.span.end = prev_end_offset(p)
		key = expression_from(p, big)
		eat(p)
	} else if is_token(p, .Identifier) || is_token(p, .String) || is_token(p, .Number) ||
	          is_keyword_usable_as_property_name(p.cur_type) {
		// Capture has_escape + name BEFORE parse_property_name consumes
		// the token. Used below if the property ends up shorthand
		// (§12.7.2: escaped ReservedWord in IdentifierReference position,
		// §12.6.1.1 in strict mode).
		key_tok_type := p.cur_type
		key_had_escape := p.cur_tok.has_escape && p.cur_type == .Identifier
		key_name := p.cur_tok.value
		key = parse_property_name(p)
		// Shorthand-only post-check. `{ foo }` = `{ foo: foo }` where the
		// value is an IdentifierReference to `foo`; `{ key: value }` and
		// `{ key() { ... } }` exit through earlier branches. Distinguish by
		// looking at the next token.
		if !is_token(p, .Colon) && !is_token(p, .LParen) {
			if key_had_escape && is_always_reserved_word_name(key_name) {
				msg := fmt.tprintf("Keyword '%s' must not contain escaped characters", key_name)
				report_error(p, msg)
			}
			// Escaped strict-reserved word in BindingIdentifier position is
			// also forbidden by §12.7.2 (always, not just in strict mode):
			// `({ l\u0065t })`, `({ st\u0061tic })`, `({ yi\u0065ld })` are
			// SyntaxErrors regardless of enclosing strict / sloppy.
			if key_had_escape {
				if is_strict_reserved_name(key_name) ||
				   key_name == "let" || key_name == "static" ||
				   key_name == "yield" {
					msg := fmt.tprintf("Keyword '%s' must not contain escaped characters", key_name)
					report_error(p, msg)
				}
			}
			// §12.6.1.1 strict-mode IdentifierReference reservation check
			// for shorthand-property names is enforced by the semantic
			// checker (ck_check_identifier_reference_strict via the
			// ObjectExpression walker's shorthand-Identifier visit).
			_ = key_tok_type
			_ = key_name
		}
	} else {
		return nil
	}

	// Determine property kind and parse value
	kind := PropertyKind.Init
	value: ^Expression
	shorthand := false

	if is_getter || is_setter {
		// Getter or setter: get x() { } or set x(v) { }
		// After parsing key, expect ( for method body
		if is_generator {
			report_error(p, "An accessor cannot be a generator")
		}
		if is_getter {
			kind = .Get
		} else {
			kind = .Set
		}
		// Capture location of ( for the FunctionExpression
		fn_start := cur_loc(p)
		// Must be a method with () after key
		if !expect_token(p, .LParen) {
			return nil
		}
		// Parse params (getters have empty params, setters have one param).
		// §15.5.1 / §15.6.1 - yield-in-params guard for generator methods.
		// §15.8.1 - await-in-params guard for async accessors (rare but valid
		// syntactic reach via `async get`/`async set` in extended proposals;
		// keeps the invariant symmetric with method shorthand below).
		prev_gp_obj_acc := p.in_generator_params
		prev_ap_obj_acc := p.in_async_params
		prev_sb_obj_acc := p.in_static_block
		p.in_static_block = false
		p.in_generator_params = is_generator
		p.in_async_params = is_async
		// `super.x` is legal inside an object-literal accessor parameter
		// default (e.g. `{ get foo(x = super.bar()) {...} }`) because the
		// param scope inherits the method's [[HomeObject]]. Set in_method
		// BEFORE parse_function_params so the default-expression parse
		// sees it. Save / restore mirrors the body-side scoping.
		prev_in_method := p.in_method
		p.in_method = true
		prev_in_derived_ctor := p.in_derived_constructor
		p.in_derived_constructor = false
		params := parse_function_params(p)
		p.in_generator_params = prev_gp_obj_acc
		p.in_async_params = prev_ap_obj_acc
		p.in_static_block = prev_sb_obj_acc
		if !expect_token(p, .RParen) {
			return nil
		}
		// TypeScript return type annotation on object-literal accessor.
		accessor_return_type: Maybe(^TSTypeAnnotation)
		if is_token(p, .Colon) && allow_ts_mode(p) {
			accessor_return_type = parse_ts_return_type_annotation(p)
		}
		body := parse_function_body(p)
		body_strict := p.last_body_strict
		p.in_method = prev_in_method
		p.in_derived_constructor = prev_in_derived_ctor

		// Getters / setters always have UniqueFormalParameters
		// (ECMA-262 §15.4.3 / §15.4.4). A setter with two params named
		// the same is a SyntaxError regardless of strict mode. strict_override
		// = true forces the duplicate-name check independent of
		// p.strict_mode (which has been restored above).

		// §15.5.1 / §15.6.1 / §15.8.1 "ContainsUseStrict +
		// !IsSimpleParameterList" for object-literal accessors: enforced
		// by the semantic checker (ck_check_strict_directive_with_nonsimple_params).

		// Strict-mode param names (eval / arguments / let / yield / static
		// / FutureReservedWords). When the body opted in via "use strict",
		// param names must satisfy strict-mode reservation rules.
		if body_strict {
		}

		// §15.4.3 / §15.4.4 / §15.4.5 — PropertySetParameterList /
		// PropertyGetParameter enforce exact arity AND parameter shape:
		//   get  — zero parameters.
		//   set  — exactly one non-rest parameter, no default initializer.
		// Shared with the class-element accessor path. The default-initializer
		// rule was added in slice 15 alongside the class-side promotion so the
		// two contexts emit the same diagnostic surface (object literals were
		// previously silent on `{ set foo(v=0) {} }` at parse time and the
		// checker had to fire the message in --show-semantic-errors mode).
		acc_key_loc: LexerLoc
		if key != nil {
			acc_key_loc = LexerLoc(get_expression_loc(key).span.start)
		} else {
			acc_key_loc = LexerLoc(fn_start.span.start)
		}
		enforce_accessor_param_shape(p, is_setter, params[:], acc_key_loc)

		fn := new_node(p, FunctionExpression)
		fn.loc = fn_start
		fn.params = params
		fn.body = body
		fn.generator = is_generator
		fn.async = is_async
		fn.return_type = accessor_return_type
		fn.loc.span.end = prev_end_offset(p)
		value = expression_from(p, fn)
	} else if is_token(p, .LParen) || (allow_ts_mode(p) && is_open_angle_or_lshift(p)) {
		// Method shorthand: foo() {}
		// TS extension - generic method shorthand: foo<T>(a: T) { ... }
		// Mirrors the same dance parse_class_element does at the
		// `method_type_parameters` block. Closes the ~17 OXC corpus
		// rejects in the "Expected }, got <" cluster (typescript
		// fixtures like assignEveryTypeToAny.ts and
		// optionalParameterRetainsNull.ts that use
		// `{ f<T>(x: T) { return x; } }` shape).
		kind = .Method
		// Capture location of ( (or `<`) for the FunctionExpression.
		fn_start := cur_loc(p)
		method_type_parameters: Maybe(^TSTypeParameterDeclaration)
		if allow_ts_mode(p) && is_open_angle_or_lshift(p) {
			method_type_parameters = parse_ts_type_parameters(p)
		}
		if !expect_token(p, .LParen) {
			return nil
		}
		// §15.5.1 / §15.6.1 - yield-in-params guard for generator methods.
		// §15.8.1 / §15.6.1 - await-in-params guard for async methods
		// (including async generator method shorthand `async *m() {}`).
		prev_gp_obj_meth := p.in_generator_params
		prev_ap_obj_meth := p.in_async_params
		// Static-block context does not extend into method parameters.
		prev_sb_obj_meth := p.in_static_block
		p.in_static_block = false
		p.in_generator_params = is_generator
		p.in_async_params = is_async
		// `super.x` in a default param of an object-literal method shorthand
		// is legal (param scope inherits [[HomeObject]]). Same async / gen
		// context the body runs under has to apply to the params too -
		// `await` and `yield` in default-param positions are gated by
		// in_async_params / in_generator_params (already set above).
		prev_in_generator := p.in_generator
		prev_in_async := p.in_async
		prev_in_method := p.in_method
		prev_in_derived_ctor := p.in_derived_constructor
		p.in_generator = is_generator
		p.in_async = is_async
		// Object-literal method shorthand - [[HomeObject]] is the object
		// literal. `super.x` is legal inside. Object methods are not
		// constructors, so `super(...)` is not legal.
		p.in_method = true
		p.in_derived_constructor = false
		params := parse_function_params(p)
		p.in_generator_params = prev_gp_obj_meth
		p.in_async_params = prev_ap_obj_meth
		p.in_static_block = prev_sb_obj_meth
		if !expect_token(p, .RParen) {
			return nil
		}
		// TS return-type annotation on plain method shorthand:
		//   const o = { method(): void { ... }, async return(v: R): Promise<...> {} }
		// Mirrors the same hook on the getter/setter branch a few lines
		// above. Without this the `:` after `)` was parsed as the start of
		// a property-key shape, ending the property and tripping `Expected
		// {`. Closes ~22 OXC corpus rejects in the "Expected {, got :"
		// cluster.
		method_return_type: Maybe(^TSTypeAnnotation)
		if is_token(p, .Colon) && allow_ts_mode(p) {
			method_return_type = parse_ts_return_type_annotation(p)
		}
		body := parse_function_body(p)
		body_strict := p.last_body_strict
		p.in_generator = prev_in_generator
		p.in_async = prev_in_async
		p.in_method = prev_in_method
		p.in_derived_constructor = prev_in_derived_ctor

		// Object-literal methods run under UniqueFormalParameters rules
		// (ECMA-262 §15.4.1 / §15.4.5) - duplicates are always a
		// SyntaxError. strict_override = true forces the check even when
		// the surrounding context is sloppy.

		// §15.5.1 / §15.6.1 / §15.8.1 "ContainsUseStrict +
		// !IsSimpleParameterList" for object-literal methods: enforced by
		// the semantic checker (ck_check_strict_directive_with_nonsimple_params).

		// Strict-mode param-name reservation. See accessor case above.
		if body_strict {
		}

		// §15.2.1.1 - BoundNames of FormalParameters vs LexicallyDeclaredNames.

		fn := new_node(p, FunctionExpression)
		fn.loc = fn_start
		fn.params = params
		fn.body = body
		fn.generator = is_generator
		fn.async = is_async
		fn.type_parameters = method_type_parameters
		fn.return_type = method_return_type
		fn.loc.span.end = prev_end_offset(p)
		value = expression_from(p, fn)
	} else if match_token(p, .Colon) {
		// Regular property with value. `async a: v` / `*a: v` are not valid
		// data properties; `async` and `*` only modify method definitions.
		if is_async || is_generator {
			report_error(p, "Object property modifier requires a method definition")
		}
		// Use Assignment precedence - comma separates properties, not expressions
		value = parse_expr_with_prec(p, .Assignment)
	} else if match_token(p, .Assign) {
		// Shorthand with default: { foo = defaultValue } - only legal as
		// CoverInitializedName inside a destructuring assignment cover
		// (§13.2.5.1 / §13.15.5.2). Parse permissively here; record the
		// offset in p.pending_cover_inits. expr_to_pattern clears the
		// entry when the ObjectExpression gets promoted to an
		// ObjectPattern; anything left after parse_program is a
		// SyntaxError.
		default_val := parse_expr_with_prec(p, .Assignment)
		assign := new_node(p, AssignmentExpression)
		assign.loc = start
		assign.operator = .Assign
		// S26 W5b - don't alias `key`. Previously assign.left = key
		// shared the same ^Expression pointer with prop.key; raw_transfer
		// then walked that Expression union TWICE (once via prop.key, once
		// via assign.left), and the second walk dereferenced an
		// already-rewritten inner pointer (now an arena offset, not a real
		// pointer) and segfaulted. Surfaced via S26 W5b on yup.js -
		// `({excludeEmptyString = false, message, name} = options)` triggers
		// the alias inside a destructuring cover.
		//
		// Clone the inner Identifier into a fresh Expression union so each
		// AST slot owns its own node (matches ESTree shape - the JSON path
		// already emits two distinct Identifier objects at these positions).
		if key != nil {
			#partial switch k in key^ {
			case ^Identifier:
				if k != nil {
					cloned := new_node(p, Identifier)
					cloned.loc = k.loc
					cloned.name = k.name
					assign.left = expression_from(p, cloned)
				} else {
					assign.left = key
				}
			case:
				// Non-Identifier keys (StringLiteral, NumericLiteral) cannot
				// legally be the LHS of CoverInitializedName, but the parse
				// is permissive here and expr_to_pattern / parse-program
				// emits the SyntaxError later. Keep the alias for those
				// shapes - they don't hit the raw-transfer crash because the
				// node never round-trips successfully anyway.
				assign.left = key
			}
		} else {
			assign.left = key
		}
		assign.right = default_val
		assign.loc.span.end = prev_end_offset(p)
		shorthand = true
		value = expression_from(p, assign)
		bump_append(&p.pending_cover_inits, start.span.start)
	} else {
		// Shorthand property: { foo } means { foo: foo }
		// Not valid for generators/getters/setters
		if is_generator || is_async {
			report_error(p, "Generator/async shorthand property not allowed")
			return nil
		}
		// §13.2.5.1 PropertyDefinition shorthand only accepts an
		// IdentifierReference - computed `[expr]` and numeric / string
		// keys cannot stand alone. `({[x]})`, `({0})`, `({"foo"})` are
		// SyntaxErrors. Other key shapes (Identifier / contextual keyword)
		// fall through to the regular shorthand path.
		if computed {
			report_error(p, "Computed property name requires a value")
		} else if key != nil {
			#partial switch k in key^ {
			case ^NumericLiteral, ^StringLiteral, ^BigIntLiteral:
				report_error(p, "Numeric / string property name requires a value")
			case ^Identifier:
				// Shorthand binding name must be a valid IdentifierReference.
				// Hard reserved keywords (default, extends, class, function,
				// if, ...) cannot be used. Escaped-reserved variants are
				// caught at the IdentifierName branch above via the
				// has_escape pre-capture.
				if k != nil && is_always_reserved_word_name(k.name) {
					msg := fmt.tprintf("Reserved word '%s' is not a valid binding identifier", k.name)
					report_error(p, msg)
				}
				// Contextually reserved: `yield` in generators, `await` in async/static blocks.
				if k != nil && k.name == "yield" && yield_is_reserved_here(p) {
					report_error(p, "'yield' is reserved as a binding name inside a generator")
				}
				if k != nil && k.name == "await" && await_is_reserved_here(p) {
					report_error(p, "'await' is not allowed as a shorthand property identifier")
				}
			}
		}
		shorthand = true
		value = key
	}

	prop := new_node(p, Property)
	prop.loc = start
	prop.key = key
	prop.value = value
	prop.kind = kind
	prop.computed = computed
	prop.shorthand = shorthand
	prop.loc.span.end = prev_end_offset(p)

	return prop
}

parse_property_name :: proc(p: ^Parser) -> ^Expression {
	current := get_current(p)

	#partial switch current.type {
	case .Identifier:
		eat(p)
		ident := new_node(p, Identifier)
		ident.loc = loc_from_token(&current)
		ident.name = current.value
		ident.loc.span.end = prev_end_offset(p)
		return expression_from(p, ident)

	case .String:
		eat(p)
		str := new_node(p, StringLiteral)
		str.loc = loc_from_token(&current)
		str.raw = current.value
		if val, ok := current.literal.(string); ok {
			str.value = val
		}
		str.loc.span.end = prev_end_offset(p)
		return expression_from(p, str)

	case .BigInt:
		eat(p)
		big := new_node(p, BigIntLiteral)
		big.loc = loc_from_token(&current)
		big.raw = current.value
		if len(current.value) > 0 && current.value[len(current.value)-1] == 'n' {
			big.value = current.value[:len(current.value)-1]
		} else {
			big.value = current.value
		}
		big.loc.span.end = prev_end_offset(p)
		return expression_from(p, big)

	case .Number:
		eat(p)
		num := new_node(p, NumericLiteral)
		num.loc = loc_from_token(&current)
		num.raw = current.value
		if val, ok := current.literal.(f64); ok {
			num.value = val
		}
		num.loc.span.end = prev_end_offset(p)
		return expression_from(p, num)

	case:
		// All keywords can be used as property names in ES
		if is_keyword_usable_as_property_name(current.type) {
			eat(p)
			ident := new_node(p, Identifier)
			ident.loc = loc_from_token(&current)
			ident.name = current.value
			ident.loc.span.end = prev_end_offset(p)
			return expression_from(p, ident)
		}
		return nil
	}
}

parse_function_expression :: proc(p: ^Parser) -> ^Expression {
	// parse_function_declaration with is_expr=true returns a ^Statement
	// union wrapping an ^ExpressionStatement whose .expression is the
	// FunctionExpression (now boxed via expression_from). Extract it safely
	// via the union cast - the old transmute(^FunctionDeclaration)stmt was
	// undefined behavior that read the wrong struct layout.
	stmt := parse_function_declaration(p, true)
	if stmt == nil {
		return nil
	}
	expr_stmt, ok := stmt^.(^ExpressionStatement)
	if !ok {
		return nil
	}
	return expr_stmt.expression
}

parse_class_expression :: proc(p: ^Parser) -> ^Expression {
	start := cur_loc(p)
	eat(p) // consume class

	id: Maybe(BindingIdentifier)
	// In TS mode, `class implements Foo {}` has no name - `implements` is
	// the heritage clause keyword, not a class name. Don't consume it as
	// the identifier when the next token is a plausible interface name or
	// `{`. Same for `class extends Expr {}` which is already handled by
	// the `extends` path below.
	is_implements_keyword := (p.lang == .TS || p.lang == .TSX) &&
	                         is_token(p, .Identifier) && p.cur_tok.value == "implements" &&
	                         (p.lexer.nxt.kind == .Identifier || is_keyword_usable_as_property_name(p.lexer.nxt.kind) || p.lexer.nxt.kind == .LBrace)
	if can_be_binding_identifier(p.cur_type) && !is_implements_keyword {
		current := get_current(p)
		name_tok_type := p.cur_type
		id = BindingIdentifier{
			loc  = loc_from_token(&current),
			name = current.value,
		}
		// §15.7.1 strict-reserved / eval / arguments / await as class
		// name: enforced by the semantic checker (ck_check_class_name).
		_ = name_tok_type
		// §12.7.2 escaped-ReservedWord in BindingIdentifier position.
		// Class names are strict-mode-only (§15.7.1), so the strict-only
		// reservation list applies to escapes too.
		if p.cur_tok.has_escape {
			if is_always_reserved_word_name(current.value) ||
			   is_strict_reserved_name(current.value) ||
			   current.value == "let" || current.value == "static" ||
			   current.value == "yield" {
				msg := fmt.tprintf("Keyword '%s' must not contain escaped characters", current.value)
				report_error(p, msg)
			}
		}
		eat(p)
	}

	// TypeScript generic type parameters on class expression: `(class<T> {})`,
	// `(class C<T> {})`. Must come before the heritage clause, mirroring
	// parse_class_declaration. Closes OXC corpus "Expected {, got <" cluster
	// (S26 W7 bug class #40).
	type_parameters: Maybe(^TSTypeParameterDeclaration)
	if (p.lang == .TS || p.lang == .TSX) && is_token(p, .LAngle) {
		type_parameters = parse_ts_type_parameters(p)
	}

	super_class: Maybe(^Expression)
	// §15.7 - ClassExpression is always strict mode code.
	prev_strict_cls_expr := p.strict_mode
	p.strict_mode = true
	defer p.strict_mode = prev_strict_cls_expr
	super_type_arguments: Maybe(^TSTypeParameterInstantiation)
	if match_token(p, .Extends) {
		super_class = parse_left_hand_side_expr(p)
		if super_class == nil {
			report_error(p, "Expected expression after 'extends'")
		}
		// OXC parses type arguments on class heritage in all modes.
		// In JS mode, only plain `<` — `<<` stays as left-shift.
		if (allow_ts_mode(p) && is_open_angle_or_lshift(p)) ||
		   (!allow_ts_mode(p) && is_token(p, .LAngle)) {
			super_type_arguments = parse_ts_type_arguments(p)
		}
		// Unparenthesised arrow functions are AssignmentExpressions, not
		// LeftHandSideExpressions. Parenthesised arrows are fine.
		if sc, have := super_class.(^Expression); have && sc != nil {
			if arrow, is_arrow := sc^.(^ArrowFunctionExpression); is_arrow && arrow != nil {
				arrow_start := int(arrow.loc.span.start)
				paren_wrapped := false
				if p.lexer != nil && arrow_start > 0 {
					pi := arrow_start - 1
					for pi >= 0 {
						pch := p.lexer.source_bytes[pi]
						if pch == '(' { paren_wrapped = true; break }
						if pch == ' ' || pch == '\t' || pch == '\n' || pch == '\r' { pi -= 1; continue }
						break
					}
				}
				if !paren_wrapped {
					report_error(p, "Arrow function is not a valid class heritage expression")
				}
			}
		}
	}

	// TS: `class C extends Base implements I, J<T>` - same grammar as
	// parse_class_declaration. `implements` is a contextual keyword.
	implements_list: [dynamic]TSInterfaceHeritage
	if (p.lang == .TS || p.lang == .TSX) &&
	   is_token(p, .Identifier) && p.cur_tok.value == "implements" {
		eat(p)
		implements_list = parse_ts_heritage_list(p)
		if len(implements_list) == 0 {
			report_error(p, "Expected interface name after 'implements'")
		}
	}

	// See parse_class_declaration for the rationale - same save/restore.
	prev_class_has_extends := p.class_has_extends
	p.class_has_extends = (super_class != nil)
	defer p.class_has_extends = prev_class_has_extends

	body := parse_class_body(p)

	expr := new_node(p, ClassExpression)
	expr.loc = start
	expr.id = id
	expr.type_parameters = type_parameters
	expr.super_class = super_class
	expr.super_type_arguments = super_type_arguments
	expr.implements = implements_list
	expr.body = body
	expr.loc.span.end = prev_end_offset(p)

	return expression_from(p, expr)
}

parse_new_expr :: proc(p: ^Parser) -> ^Expression {
	start := cur_loc(p)
	eat(p) // consume new

	// new.target - MetaProperty
	if is_token(p, .Dot) {
		next := peek_token(p)
		if next.value == "target" {
			eat(p) // consume .
			target_tok := get_current(p)
			eat(p) // consume target
			// ECMA-262 §13.3.12 / §15.2 - `new.target` is only valid inside
			// a non-arrow function body. Arrow functions inherit
			// [[NewTarget]] from their enclosing scope, so an arrow at
			// script top-level has no new.target either. Test262:
			// language/global-code/new.target-arrow.js.
			// §13.3.12 / §15.2 new.target outside any function: enforced
			// by the semantic checker (ck_check_new_target) using its own
			// function_depth tracker. Parser stays permissive.
			meta := new_node(p, MetaProperty)
			meta.loc = start
			meta.meta = Identifier{loc = start, name = "new"}
			meta.property = Identifier{loc = loc_from_token(&target_tok), name = "target"}
			meta.loc.span.end = prev_end_offset(p)
			return expression_from(p, meta)
		}
	}

	// ECMA-262 §13.3.12 - `new import(x)` is a SyntaxError. The grammar
	// production NewExpression : `new` NewExpression has no arm that
	// reaches an ImportCall (`import(...)`). Catch it here at the start
	// so the diagnostic points at `import`, not somewhere downstream.
	// Same rule applies to phase-import call forms (§Phase Imports):
	//   `new import.defer(x)` / `new import.source(x)` are SyntaxErrors.
	// BUT `new import.meta()` is VALID syntax - it calls the MetaProperty
	// as a constructor (throws at runtime). Test262: language/expressions/
	// import.meta/import-meta-is-an-ordinary-object.js.
	if is_token(p, .Import) && p.lexer != nil {
		if p.lexer.nxt.kind == .LParen {
			report_error(p, "Dynamic 'import()' cannot be invoked with 'new'")
		} else if p.lexer.nxt.kind == .Dot {
			// Source-byte lookahead past the `.` to see whether the
			// property name is the legal `meta` MetaProperty or one of
			// the phase-import call forms (`defer` / `source`).
			dot_off := int(p.lexer.nxt.end)
			src := p.lexer.source_bytes
			// Skip whitespace after the `.`.
			for dot_off < len(src) {
				ch := src[dot_off]
				if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { dot_off += 1; continue }
				break
			}
			is_meta := dot_off + 4 <= len(src) &&
			           src[dot_off]   == 'm' && src[dot_off+1] == 'e' &&
			           src[dot_off+2] == 't' && src[dot_off+3] == 'a'
			if !is_meta {
				report_error(p, "Dynamic 'import()' cannot be invoked with 'new'")
			}
		}
	}

	callee := parse_member_expr(p)
	if callee == nil {
		report_error(p, "Expected expression after 'new'")
		return nil
	}
	if _, is_super := callee^.(^Super); is_super {
		report_error(p, "'new super()' is not allowed")
	}
	// `new <T>Foo()` — legacy TS type assertion after `new` is ambiguous
	// with type parameters. OXC rejects this form. Only fire when the
	// `<T>` is the direct callee (not parenthesized: `new (<T>x)` is OK).
	if ta, is_ta := callee^.(^TSTypeAssertion); is_ta {
		// Check if the assertion starts right after `new ` (no parens).
		if p.lexer != nil && ta.loc.span.start == start.span.start + 4 {
			report_error(p, "Type assertion is not allowed after 'new'")
		}
	}

	// TS generic type arguments: `new Foo<string>()`.
	// Ambiguity: `new Date<A;` is `(new Date) < A;` (relational), NOT
	// `new Date<A>` (type args). Use speculative parse: try to parse
	// type arguments and accept only if the closing `>` is found.
	targs: Maybe(^TSTypeParameterInstantiation)
	if allow_ts_mode(p) && is_open_angle_or_lshift(p) {
		snap := lexer_snapshot(p)
		ta := parse_ts_type_arguments(p)
		// On success the current token is past the `>`. If the parse
		// failed (error was pushed), backtrack - the `<` is the less-than
		// operator and this is a relational expression.
		// Also backtrack when type args parsed OK but the next token
		// can't follow `new Expr<T>` - only `(` (call) and `.` / `[`
		// (member) are valid. Anything else (identifier, `;`, EOF, ...)
		// means `<` was relational. Fixes `new A < B > C`.
		parse_failed := len(p.errors) > snap.errors_len
		next_valid := p.cur_type == .LParen || p.cur_type == .Dot ||
		              p.cur_type == .LBracket || p.cur_type == .OptionalChain ||
		              p.cur_type == .Template || p.cur_type == .TemplateHead ||
		              p.cur_type == .Semi || p.cur_type == .EOF ||
		              p.cur_type == .RBrace || p.cur_type == .RParen ||
		              p.cur_type == .RBracket || p.cur_type == .Comma
		if parse_failed || !next_valid {
			lexer_restore(p, snap)
		} else {
			targs = ta
		}
	}

	args: [dynamic]^Expression
	if is_token(p, .LParen) {
		// Clear pending_paren_start before the arg list. When the callee was
		// itself parenthesised (`new (expr)(args)`), parse_primary_expr sets
		// pending_paren_start for the next consumer. parse_lhs_tail with
		// allow_call=false returns early without consuming it (leaving the
		// `(` for US to consume as NewExpression args), but this leaves the
		// stamp stuck. parse_arguments doesn't touch it either, so the stamp
		// then leaks into the following statement where the first
		// MemberExpression / CallExpression / arrow widens its start span
		// backwards to the paren position. Observed on d3.js as a 86-byte
		// span drift on the `return m.isIdentity ? ... : ...` ternary
		// directly after `const m = new (typeof DOMMatrix === "function" ?
		// DOMMatrix : WebKitCSSMatrix)(value + "");`.
		p.pending_paren_start = max(u32)
		args = parse_arguments(p)
	}

	new_ := new_node(p, NewExpression)
	new_.loc = start
	new_.callee = callee
	new_.arguments = args
	new_.type_parameters = targs
	new_.loc.span.end = prev_end_offset(p)

	return expression_from(p, new_)
}

parse_arguments :: proc(p: ^Parser) -> [dynamic]^Expression {
	if !expect_token(p, .LParen) {
		return nil
	}

	// Inside function call arguments, the `in` operator is always allowed
	// even when we're in a for-init position (no_in=true). §13.16:
	// ArgumentList members are AssignmentExpressions, not restricted.
	// Fixes `for (a(b in c)[0] in d)` where `b in c` was rejected.
	saved_no_in := p.no_in
	p.no_in = false
	defer p.no_in = saved_no_in

	// Lazy allocation - zero-argument calls (`fn()`) are extremely common
	// (every method-chain step like `.map().filter().toArray()` has them)
	// and would otherwise burn a 32-byte bump-pool reservation per call
	// for an unused 4-pointer dynamic array. Defer the make until we know
	// the call has at least one argument.
	args: [dynamic]^Expression

	if !is_token(p, .RParen) {
		// Cap bumped from 4 → 8 (S23). Function calls with >4 args triggered
		// 945 slow-path grows on monaco. Many APIs take 5-8 args (e.g.
		// React.createElement(type, props, ...children) or fmt.Printf-style).
		args = make([dynamic]^Expression, 0, 8, p.allocator)
		for {
			// `(,)` and `(a,,b)` - elision is not allowed in Arguments
			// per §13.3.5. The grammar is `Arguments :: ( ArgumentList )`
			// with no holes. Test262: language/expressions/call/
			// S11.2.4_A1.3_T1.js (`f_arg(1,,2)`).
			if is_token(p, .Comma) {
				report_error(p, "Argument expression expected")
				eat(p) // consume the stray comma so we don't loop
				continue
			}
			if is_token(p, .Dot3) {
				spread_start := cur_loc(p) // Capture location of ... before eating
				eat(p)
				arg := parse_assignment_expression(p)
				if arg != nil {
					if _, nested_spread := arg.(^SpreadElement); nested_spread {
						report_error(p, "Spread argument cannot contain another spread element")
					}
					spread := new_node(p, SpreadElement)
					spread.loc = spread_start // Use location of ... token, not the argument
					spread.argument = arg
					spread.loc.span.end = prev_end_offset(p)
					bump_append(&args, expression_from(p, spread))
				} else {
					// `...` in argument position must be followed by an
					// AssignmentExpression (the spread target). `fn(..., x)`
					// and `fn(...)` (empty) are both SyntaxErrors. Report so
					// the recovery verifier and error-reporting consumers
					// see the problem; parse continues at `,` / `)`.
					report_error(p, "Expected expression after '...'")
				}
			} else {
				arg := parse_assignment_expression(p)
				if arg != nil {
					bump_append(&args, arg)
				}
			}

			if !match_token(p, .Comma) {
				break
			}
		}
	}

	if !expect_token(p, .RParen) {
		return nil
	}

	return args
}

// True when the token immediately following the current `yield`
// (at p.cur_tok) cleanly starts an AssignmentExpression argument -
// i.e. the user wrote `yield <expr>` rather than `yield;`,
// `yield + 1`, `yield.x`, `yield(x)`, `` yield`t` ``, etc. A
// line-terminator between `yield` and the next token triggers ASI
// and counts as no-argument. Used in non-generator contexts to
// distinguish the yield-expression form (SyntaxError) from `yield`
// used as an IdentifierReference.
yield_next_is_expression_argument :: proc(p: ^Parser) -> bool {
	nxt := peek_token(p)
	if nxt.had_line_terminator { return false }
	#partial switch nxt.type {
	// Statement / list terminators - no argument.
	case .Semi, .Comma, .Colon, .RParen, .RBracket, .RBrace, .EOF, .Invalid,
	// Binary / logical / coalescing operators - yield is LHS identifier.
	     .Plus, .Minus, .Mul, .Div, .Mod, .Pow,
	     .LShift, .RShift, .URShift,
	     .BitAnd, .BitOr, .BitXor,
	     .LogicalAnd, .LogicalOr, .Nullish,
	// Assignment operators - yield on the left of `=` / compound assigns.
	     .Assign, .AssignAdd, .AssignSub, .AssignMul, .AssignDiv,
	     .AssignMod, .AssignPow,
	     .AssignLShift, .AssignRShift, .AssignURShift,
	     .AssignBitAnd, .AssignBitOr, .AssignBitXor,
	     .AssignLogicalAnd, .AssignLogicalOr, .AssignNullish,
	// Comparisons / equality.
	     .Eq, .NotEq, .EqStrict, .NotEqStrict,
	     .LAngle, .RAngle, .LEq, .GEq,
	     .In, .Instanceof,
	// Ternary / arrow / postfix.
	     .Question, .Arrow,
	     .PlusPlus, .MinusMinus,
	// Member / call / tagged-template continuations.
	     .Dot, .OptionalChain, .LParen, .LBracket,
	     .Template, .TemplateHead:
		return false
	}
	// Everything else - identifiers, literals, `new`, `function`,
	// `class`, `this`, `super`, `typeof` / `void` / `delete`,
	// `!` / `~`, `{`, `/` regex (lexed as RegularExpression), etc.
	// - begins a fresh AssignmentExpression, so we read the
	// `yield` as yield-expression form.
	return true
}

parse_yield_expr :: proc(p: ^Parser) -> ^Expression {
	start := cur_loc(p)
	// ECMA-262 §15.5.1 - "It is a Syntax Error if FormalParameters
	// Contains YieldExpression is true." A YieldExpression that appears
	// inside a GeneratorFunction's / GeneratorMethod's FormalParameters
	// (typically the default initializer of a parameter) is forbidden;
	// the generator scope only starts INSIDE the body. We flag the
	// parent parser to mark this window with `in_generator_params`; the
	// yield-expression constructor here consults it.
	// §15.5.1 / arrow-cover "YieldExpression in formal parameters"
	// early error: enforced by the semantic checker (^YieldExpression
	// case in ck_walk_expr) using its own ctx.in_params tracker.
	// Note: `yield :` as a LabelledStatement head can't reach this
	// function in a generator. parse_expression_statement only forms
	// a label when the parsed expression is a plain ^Identifier; in a
	// generator the lexer emits .Yield and we always commit to a
	// YieldExpression here, so the labeled-statement detector skips
	// it. The previous "yield as label" check fired spuriously on
	// `(yield) ? yield : yield` and similar ternary expressions where
	// the colon is part of the surrounding ConditionalExpression.
	eat(p) // consume yield

	// ECMA-262 §15.5 Restricted Production: no LineTerminator between
	// `yield` and AssignmentExpression / `*`. If the next token has a
	// preceding newline, emit a bare `yield` expression; the rest starts
	// a new statement.
	has_newline := p.cur_tok.had_line_terminator
	delegate := false
	if !has_newline {
		delegate = match_token(p, .Mul)
	}
	// `yield /re/` inside a generator: the lexer no longer treats `.Yield`
	// as a regex-start (see can_start_regex), so a leading `/` was
	// classified as Div. Re-lex on demand here so the AssignmentExpression
	// argument sees the regex literal.
	if !has_newline && (p.cur_type == .Div || p.cur_type == .AssignDiv) {
		if p.lexer != nil {
			relex_as_regex(p.lexer)
			ft := p.lexer.cur
			p.cur_type = ft.kind
			p.cur_tok.type = ft.kind
			p.cur_tok.loc = LexerLoc(ft.start)
			if ft.kind < .LBrace && ft.start < ft.end {
				p.cur_tok.value = p.lexer.source[ft.start:ft.end]
			}
		}
	}

	argument: Maybe(^Expression)
	if !has_newline && !is_token(p, .Semi) && !is_token(p, .RParen) && !is_token(p, .RBracket) && !is_token(p, .RBrace) && !is_token(p, .Comma) {
		argument = parse_assignment_expression(p)
	}

	// §15.5.5 - `yield*` (YieldExpression with delegate=true) requires
	// an AssignmentExpression operand. `yield*` without one is a SyntaxError.
	if delegate && argument == nil {
		report_error(p, "'yield*' requires an operand")
	}

	yield := new_node(p, YieldExpression)
	yield.loc = start
	yield.argument = argument
	yield.delegate = delegate
	yield.loc.span.end = prev_end_offset(p)

	return expression_from(p, yield)
}

parse_template_literal :: proc(p: ^Parser, tagged: bool) -> ^Expression {
	start := cur_loc(p)
	current := get_current(p)

	tmpl := new_node(p, TemplateLiteral)
	tmpl.loc = start
	// Adjust start to include the opening backtick (lexer sets token after backtick)
	if tmpl.loc.span.start > 0 {
		tmpl.loc.span.start -= 1
	}
	tmpl.quasis = make([dynamic]TemplateElement, 0, 4, p.allocator)
	tmpl.expressions = make([dynamic]^Expression, 0, 4, p.allocator)

	// Handle simple template: `hello`
	if current.type == .Template {
		elem := TemplateElement{
			loc  = loc_from_token(&current),
			tail = true,
			raw  = current.value,
		}
		if cooked, ok := current.literal.(string); ok {
			elem.cooked = cooked
		}
		bump_append(&tmpl.quasis, elem)
		eat(p)
		tmpl.loc.span.end = prev_end_offset(p) + 1 // Include closing backtick
		p.prev_token_end = tmpl.loc.span.end // Update for parent nodes
		// §12.9.6 octal / \\8 / \\9 escape in untagged template:
		// enforced by the semantic checker (ck_check_template_octal).
		// Untagged templates reject §12.9.6 invalid EscapeSequences in
		// ALL modes - truncated \xH, \uH, \u{bad}, legacy-octal, etc.
		if !tagged && untagged_template_raw_has_invalid_escape(elem.raw) {
			report_error(p, "Invalid escape sequence in template literal")
		}
		return expression_from(p, tmpl)
	}

	// Handle template with expressions: `hello ${name} world`
	if current.type == .TemplateHead {
		// First quasi: `hello ${
		elem := TemplateElement{
			loc  = loc_from_token(&current),
			tail = false,
			raw  = current.value,
		}
		if cooked, ok := current.literal.(string); ok {
			elem.cooked = cooked
		}
		bump_append(&tmpl.quasis, elem)
		eat(p) // consume TemplateHead

		// Template substitution bodies (`${...}`) are independent
		// AssignmentExpressions - the enclosing no_in must not leak.
		prev_no_in := p.no_in
		p.no_in = false
		defer p.no_in = prev_no_in

		// Parse embedded expressions and middle/tail parts
		for {
			// Parse expression
			expr := parse_assignment_expression(p)
			if expr != nil {
				bump_append(&tmpl.expressions, expr)
			}

			// Expect TemplateMiddle or TemplateTail
			tok := get_current(p)
			if tok.type == .TemplateMiddle {
				mid := TemplateElement{
					loc  = loc_from_token(&tok),
					tail = false,
					raw  = tok.value,
				}
				if cooked, ok := tok.literal.(string); ok {
					mid.cooked = cooked
				}
				bump_append(&tmpl.quasis, mid)
				eat(p)
				// Continue to parse next expression
			} else if tok.type == .TemplateTail {
				tail := TemplateElement{
					loc  = loc_from_token(&tok),
					tail = true,
					raw  = tok.value,
				}
				if cooked, ok := tok.literal.(string); ok {
					tail.cooked = cooked
				}
				bump_append(&tmpl.quasis, tail)
				eat(p)
				break
			} else {
				report_error(p, "Expected template literal continuation")
				return nil
			}
		}

		tmpl.loc.span.end = prev_end_offset(p) + 1 // Include closing backtick
		p.prev_token_end = tmpl.loc.span.end // Update for parent nodes
		// §12.9.6 octal / \\8 / \\9 escape in untagged template (multi-quasi
		// shape): enforced by the semantic checker (ck_check_template_octal).
		if !tagged {
			for q in tmpl.quasis {
				if untagged_template_raw_has_invalid_escape(q.raw) {
					report_error(p, "Invalid escape sequence in template literal")
					break
				}
			}
		}
		return expression_from(p, tmpl)
	}

	report_error(p, "Expected template literal")
	return nil
}

// expr_to_pattern converts an Expression that's actually been parsed as the
// destructuring-target side of an arrow parameter default into the matching
// Pattern variant. Covers the simple targets required by real-world code
// (Identifier, ObjectExpression→ObjectPattern, ArrayExpression→ArrayPattern);
// returns `false` for anything else so the caller can emit a clean error
// rather than silently accepting invalid input.
//
// Deep-conversion of object/array destructuring internals (e.g. nested
// `{a: {b}} = {}`) is handled by later parse passes - this helper only needs
// to produce the outer Pattern wrapper.
expr_to_pattern :: proc(p: ^Parser, expr: ^Expression) -> (Pattern, bool) {
	if expr == nil { return nil, false }
	#partial switch e in expr^ {
	case ^Identifier:
		id_ptr := new_node(p, Identifier)
		id_ptr^ = e^
		return id_ptr, true
	case ^ObjectExpression:
		// Convert each ObjectExpression.Property into an ObjectPatternProperty.
		// Previously this dropped properties on the floor - emitting an empty
		// `ObjectPattern { properties: [] }` for every arrow-function param of
		// the form `({a, b: c = 1, ...rest}) => ...`. Symptom: every nested
		// default string / identifier inside destructured arrow params was
		// invisible to downstream walkers (framer-motion.js, swagger-ui.js).
		//
		// Clear any pending CoverInitializedName offsets that fall inside
		// this object's span - once promoted to an ObjectPattern, the
		// `{foo = init}` shorthand is legal (§13.2.5.1 / §13.15.5.2).
		// (Duplicate-__proto__ is now enforced post-parse by the semantic
		// checker on the resulting AST node type — ObjectExpression vs
		// ObjectPattern — so no parse-time clearing is needed.)
		if len(p.pending_cover_inits) > 0 {
			write := 0
			for off, read in p.pending_cover_inits {
				if off >= e.loc.span.start && off < e.loc.span.end {
					continue // swallow - this one's covered
				}
				p.pending_cover_inits[write] = off
				write += 1
				_ = read
			}
			resize(&p.pending_cover_inits, write)
		}
		op := new_node(p, ObjectPattern)
		op.loc = e.loc
		op.properties = make([dynamic]ObjectPatternProperty, 0, len(e.properties), p.allocator)
		prev_nested := p.in_nested_pattern_convert
		p.in_nested_pattern_convert = true
		defer p.in_nested_pattern_convert = prev_nested
		prop_count := len(e.properties)
		for prop, idx in e.properties {
			// Spread element in object expression -> RestElement in pattern.
			// Detected by nil key + SpreadElement value (parse_object_expression
			// stashes the SpreadElement in the value slot with key=nil).
			if prop.key == nil {
				if spread, ok := prop.value.(^SpreadElement); ok {
					// §13.15.5 Object destructuring: BindingRestProperty
					// must be the last element of the ObjectBindingPattern.
					// `for ({...rest, b} of ...)` is a SyntaxError.
					if idx != prop_count - 1 {
						report_error(p, "Rest element must be last in object pattern")
					} else if p.lexer != nil {
						src := p.lexer.source_bytes
						search_start := int(spread.loc.span.end)
						search_end := int(e.loc.span.end)
						if search_end > len(src) { search_end = len(src) }
						for k := search_start; k < search_end; k += 1 {
							c := src[k]
							if c == '}' { break }
							if c == ',' {
								report_error(p, "Rest property may not have a trailing comma")
								break
							}
						}
					}
					if _, is_array := spread.argument.(^ArrayExpression); is_array {
						report_error(p, "Rest property may not be a binding pattern")
					}
					if _, is_object := spread.argument.(^ObjectExpression); is_object {
						report_error(p, "Rest property may not be a binding pattern")
					}
					// TS `as T` on a rest argument: `{ ...{} as T}` is invalid
					// because the inner expression `{}` is not a valid assignment
					// target. But `{ ...a as T}` is valid (unwraps to `a`).
					// Only check when there IS a TS assertion wrapping a literal.
					if spread.argument != nil {
						has_ts_wrap := false
						unwrapped := spread.argument
						if ae, is_as := unwrapped^.(^TSAsExpression); is_as {
							unwrapped = ae.expression; has_ts_wrap = true
						}
						if ta, is_ta := unwrapped^.(^TSTypeAssertion); is_ta {
							unwrapped = ta.expression; has_ts_wrap = true
						}
						if has_ts_wrap && unwrapped != nil {
							if _, is_obj := unwrapped^.(^ObjectExpression); is_obj {
								report_error(p, "Invalid rest operator's argument")
							}
							if _, is_arr := unwrapped^.(^ArrayExpression); is_arr {
								report_error(p, "Invalid rest operator's argument")
							}
						}
					}
					inner, inner_ok := expr_to_pattern(p, spread.argument)
					if inner_ok {
						rest := new_node(p, RestElement)
						rest.loc = spread.loc
						rest.argument = inner
						pp := ObjectPatternProperty{
							loc = spread.loc,
							key = nil,
							value = rest,
						}
						bump_append(&op.properties, pp)
					}
				}
				continue
			}

			// Convert value:
			//   - AssignmentExpression (x = default) -> AssignmentPattern
			//   - anything else -> recurse via expr_to_pattern
			// Special case shorthand `{x}` where key == value == Identifier: the
			// parser may point both at the same node; either path converts
			// correctly below.
			//
			// Nil-guard: a malformed shorthand like `{ p: void }` (where `void`
			// has no argument because the next token is `}`) leaves prop.value
			// nil. The type assertion `prop.value.(^AssignmentExpression)` auto-
			// derefs and segfaults on nil. Skip the property; the upstream parse
			// error already explains what went wrong. Closes 2 babel discard-
			// binding SIGSEGVs (S26 W6 phase 3 bug class #2, second variant).
			if prop.value == nil { continue }
			value_pat: Pattern
			if ae, is_assign := prop.value.(^AssignmentExpression); is_assign && ae.operator == .Assign {
				lhs_pat, lhs_ok := expr_to_pattern(p, ae.left)
				if lhs_ok {
					asn := new_node(p, AssignmentPattern)
					asn.loc = ae.loc
					asn.left = lhs_pat
					asn.right = ae.right
					value_pat = asn
				}
			} else {
				inner, inner_ok := expr_to_pattern(p, prop.value)
				if inner_ok {
					value_pat = inner
				}
			}

			// Convert key: Property.key is ^Expression (Identifier / StringLiteral
			// / NumericLiteral / computed Expression). Map to
			// ObjectPatternPropertyKey (IdentifierName / ^StringLiteral /
			// ^Expression).
			pp_key: Maybe(ObjectPatternPropertyKey)
			if prop.computed {
				pp_key = prop.key
			} else if prop.key != nil {
				#partial switch k in prop.key^ {
				case ^Identifier:
					pp_key = IdentifierName{loc = k.loc, name = k.name}
				case ^StringLiteral:
					pp_key = k
				case:
					// Numeric / other literal keys: store as ^Expression via computed.
					pp_key = prop.key
				}
			}

			pp := ObjectPatternProperty{
				loc = prop.loc,
				key = pp_key,
				value = value_pat,
				computed = prop.computed,
				shorthand = prop.shorthand,
			}
			bump_append(&op.properties, pp)
		}
		return op, true
	case ^ArrayExpression:
		// Convert each ArrayExpression.element into an ArrayPattern element.
		// Same empty-pattern bug as ObjectExpression above.
		ap := new_node(p, ArrayPattern)
		ap.loc = e.loc
		elems := make([]Maybe(Pattern), len(e.elements), p.allocator)
		prev_nested := p.in_nested_pattern_convert
		p.in_nested_pattern_convert = true
		defer p.in_nested_pattern_convert = prev_nested
		for i := 0; i < len(e.elements); i += 1 {
			elem, has_elem := e.elements[i].(^Expression)
			if !has_elem || elem == nil {
				continue // sparse hole - leave as nil Maybe
			}
			// Spread element -> RestElement. Per §14.3.3:
			//   * BindingRestElement must be LAST in the list (no trailing
			//     elements allowed).
			//   * BindingRestElement does NOT accept an Initializer, unlike
			//     the other BindingElements.
			//   * No TRAILING comma after BindingRestElement. The cover path
			//     parses ArrayExpression which legally drops a trailing comma
			//     into nothing; re-detect by scanning the source between the
			//     spread's end and the array's end for a `,`.
			if spread, is_spread := elem^.(^SpreadElement); is_spread {
				if i != len(e.elements) - 1 {
					report_error(p, "Rest element must be last in array pattern")
				} else if p.lexer != nil {
					src := p.lexer.source_bytes
					search_start := int(spread.loc.span.end)
					search_end := int(e.loc.span.end)
					if search_end > len(src) { search_end = len(src) }
					for k := search_start; k < search_end; k += 1 {
						c := src[k]
						if c == ']' { break }
						if c == ',' {
							report_error(p, "Rest element may not have a trailing comma")
							break
						}
					}
				}
				inner_expr := spread.argument
				// `[...x = init]` - AssignmentExpression whose LHS is the rest
				// target. The cover keeps it legal as an ArrayExpression /
				// SpreadElement; reject at pattern conversion.
				if ae, is_ae := inner_expr^.(^AssignmentExpression); is_ae && ae.operator == .Assign {
					report_error(p, "Rest element cannot have a default initializer")
					inner_expr = ae.left
				}
				inner, ok := expr_to_pattern(p, inner_expr)
				if ok {
					rest := new_node(p, RestElement)
					rest.loc = spread.loc
					rest.argument = inner
					elems[i] = rest
				}
				continue
			}
			// AssignmentExpression -> AssignmentPattern.
			if ae, is_assign := elem^.(^AssignmentExpression); is_assign && ae.operator == .Assign {
				lhs_pat, lhs_ok := expr_to_pattern(p, ae.left)
				if lhs_ok {
					asn := new_node(p, AssignmentPattern)
					asn.loc = ae.loc
					asn.left = lhs_pat
					asn.right = ae.right
					elems[i] = asn
				}
				continue
			}
			if p_inner, ok := expr_to_pattern(p, elem); ok {
				elems[i] = p_inner
			}
		}
		ap.elements = elems
		return ap, true
	case ^MemberExpression:
		// ESTree allows MemberExpression as a destructure target.
		return e, true
	case ^ParenthesizedExpression:
		// Parenthesized binding element. OXC with preserveParens=false
		// (our oracle mode) strips paren wrappers, so `((a)) => 0` is
		// accepted (the inner `(a)` becomes plain `a`). But nested cases
		// like `([(a)]) => {}` or `({ a: (b) }) => {}` are still rejected
		// because the paren wraps a binding INSIDE a destructuring pattern.
		// Gate: reject when we're inside a recursive array/object pattern
		// conversion (in_nested_pattern_convert is set by the Array/Object
		// cases above). Top-level paren-around-identifier is OK.
		if e == nil { return nil, false }
		if p.in_nested_pattern_convert {
			report_error(p, "Binding element cannot be parenthesized")
		}
		return expr_to_pattern(p, e.expression)
	case ^TSNonNullExpression:
		// `x!` as a destructure target in TS mode - unwrap.
		if e == nil { return nil, false }
		return expr_to_pattern(p, e.expression)
	case ^TSAsExpression:
		if e == nil { return nil, false }
		return expr_to_pattern(p, e.expression)
	case ^TSSatisfiesExpression:
		if e == nil { return nil, false }
		return expr_to_pattern(p, e.expression)
	case ^TSTypeAssertion:
		if e == nil { return nil, false }
		return expr_to_pattern(p, e.expression)
	}
	// Everything else that reached here (Literal, SequenceExpression,
	// CallExpression, BinaryExpression, UnaryExpression, ...) is NOT a
	// legal AssignmentTarget per §12.6.2.3 / §13.15.5.2.
	report_error(p, "Invalid destructuring assignment target")
	return nil, false
}

// §15.3.1 / §15.9.1 "ArrowParameters Contains YieldExpression /
// CoverCallExpressionAndAsyncArrowHead Contains AwaitExpression" early
// errors are now enforced by the semantic checker (^YieldExpression /
// ^AwaitExpression cases in ck_walk_expr) using ctx.in_params /
// ctx.params_is_arrow. The bespoke retroactive cover-walk that used to
// live here (scan_arrow_cover_for_yield_await + scan_arrow_params_for_yield_only
// + arrow_cover_walk_pattern + arrow_cover_walk_expr) was deleted as
// part of slice 7 — the regular checker walk now visits arrow params
// (including nested ObjectPattern computed keys + AssignmentPattern
// defaults via ck_walk_pattern) under in_params=true, params_is_arrow=true.
//
// pattern_contains_member_expression is still needed by the arrow-param
// validity check at parse_arrow_function (a parameter pattern that
// destructures into a MemberExpression is not a valid binding pattern).
pattern_contains_member_expression :: proc(pat: Pattern) -> bool {
	if pat == nil { return false }
	switch pp in pat {
	case ^MemberExpression:
		return true
	case ^AssignmentPattern:
		return pattern_contains_member_expression(pp.left)
	case ^ObjectPattern:
		for prop in pp.properties {
			if pattern_contains_member_expression(prop.value) { return true }
		}
	case ^ArrayPattern:
		for elem in pp.elements {
			if inner, have := elem.(Pattern); have {
				if pattern_contains_member_expression(inner) { return true }
			}
		}
	case ^RestElement:
		return pattern_contains_member_expression(pp.argument)
	case ^Identifier:
		return false
	}
	return false
}

// check_parenthesized_binding detects inner `(...)` wrapping a binding
// element inside an arrow parameter list. Works by walking each pattern
// recursively: for every leaf Identifier, check if the byte before its
// span start (skipping whitespace) is `(` and the byte after its span
// end is `)`, and those parens are not the outer arrow parens.
check_parenthesized_binding :: proc(p: ^Parser, params: []FunctionParameter, src: []u8, outer_paren: int) {
	for param in params {
		check_pattern_parens(p, param.pattern, src, outer_paren)
		// Default values: `(x = (y)) =>` — the (y) is a grouping
		// paren in expression context, not a binding paren. Skip.
	}
}

@(private="file")
check_pattern_parens :: proc(p: ^Parser, pat: Pattern, src: []u8, outer_paren: int) {
	if pat == nil { return }
	switch pp in pat {
	case ^Identifier:
		check_span_for_inner_parens(p, int(pp.loc.span.start), int(pp.loc.span.end), src, outer_paren)
	case ^AssignmentPattern:
		// `(a) = []` — check the LHS pattern.
		check_pattern_parens(p, pp.left, src, outer_paren)
	case ^ArrayPattern:
		for elem in pp.elements {
			if inner, have := elem.(Pattern); have {
				check_pattern_parens(p, inner, src, outer_paren)
			}
		}
	case ^ObjectPattern:
		for prop in pp.properties {
			check_pattern_parens(p, prop.value, src, outer_paren)
		}
	case ^RestElement:
		check_pattern_parens(p, pp.argument, src, outer_paren)
	case ^MemberExpression:
		// Skip — MemberExpression as target is caught elsewhere.
	}
}

@(private="file")
check_span_for_inner_parens :: proc(p: ^Parser, span_start, span_end: int, src: []u8, outer_paren: int) {
	// Walk backwards from span_start to find `(`.
	i := span_start - 1
	for i >= 0 {
		c := src[i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' { i -= 1; continue }
		if c == '(' && i != outer_paren {
			// Found an inner `(`. Now check for matching `)` after span_end.
			j := span_end
			for j < len(src) {
				d := src[j]
				if d == ' ' || d == '\t' || d == '\n' || d == '\r' { j += 1; continue }
				if d == ')' {
					report_error(p, "Binding element cannot be parenthesized")
				}
				break
			}
		}
		break
	}
}

parse_arrow_function :: proc(p: ^Parser, left: ^Expression, is_async := false) -> ^Expression {
	start: Loc
	if left != nil {
		start = loc_from_expr(left)
		// If a `(` was opened immediately before this expression, use its
		// position as the arrow's start - matches ESTree/OXC/Acorn span
		// semantics (`(x, y) => ...` spans the entire parenthesised form).
		// A stamp of 0 means no paren was seen (bare identifier arrow
		// `x => ...`); in that case keep the identifier's own start.
		// Check if this is empty params - if so, don't adjust based on outer paren
		is_empty_params_local := false
		if seq, ok := left^.(^SequenceExpression); ok && len(seq.expressions) == 0 {
			is_empty_params_local = true
		}
		if !is_empty_params_local && p.pending_paren_start != max(u32) && p.pending_paren_start <= start.span.start {
			start.span.start = p.pending_paren_start
		}
	} else {
		start = cur_loc(p)
	}
	// For empty params, don't clear pending_paren_start yet - let CallExpression use it
	is_empty_params := false
	if left != nil {
		if seq, ok := left^.(^SequenceExpression); ok && len(seq.expressions) == 0 {
			is_empty_params = true
		}
	}
	if !is_empty_params {
		p.pending_paren_start = max(u32)
	}

	// left should be parameters (identifier or parenthesized expression)
	// nil left means empty params: () => ...
	eat(p) // consume =>

	// §15.3.1 Contains check is enforced by the semantic checker on the
	// finished AST: ck_walk_expr's ^ArrowFunctionExpression case sets
	// in_params=true, params_is_arrow=true around the params walk, and
	// ck_walk_pattern + the YieldExpression / AwaitExpression cases
	// emit the diagnostic. No retroactive cover-walk needed here.

	// Set async context for body parsing
	prev_async := p.in_async
	if is_async {
		p.in_async = true
	}
	// §15.3.4: ArrowFunction ConciseBody is parsed with [~Yield, ~Await]
	// (unless the arrow itself is async, in which case [~Yield, +Await]).
	// Arrow functions don't have their own [[Generator]] status, so
	// `yield` inside a non-generator arrow in a generator function is
	// just an identifier, not a YieldExpression. Reset `in_generator`
	// so the expression parser treats `yield` as an identifier.
	prev_in_generator := p.in_generator
	p.in_generator = false
	// Static block context does NOT propagate into arrow function bodies.
	prev_static_block_arrow := p.in_static_block
	p.in_static_block = false
	defer p.in_static_block = prev_static_block_arrow
	// Parse body. Capture block-vs-expression BEFORE consuming either,
	// because after parse_block_statement / parse_assignment_expression
	// the current token is no longer the '{' and the ESTree `expression`
	// flag would otherwise always read false.
	is_block_body := is_token(p, .LBrace)
	body: ArrowFunctionBody
	if is_block_body {
		// Block body - need to set in_function for return statement validation
		prev_in_function := p.in_function
		p.in_function = true
		block_stmt := parse_block_statement(p)
		p.in_function = prev_in_function
		// §15.3.1: arrow `{ FunctionBody }` is a function-scope, not a block-scope.
		if block_stmt != nil {
			// parse_block_statement returns ^Statement wrapping ^BlockStatement.
			// `cast(^BlockStatement)^Statement` here is the same UB class as Bug H:
			// the Statement union's 16-byte header was being read as the start of
			// BlockStatement's fields, so `body.body` iteration yielded garbage
			// pointers (e.g. 0x14). Crash symptom: SIGSEGV in
			// `get_statement_type_name` when emitting class methods that contain
			// arrow functions with block bodies (tone.js and 11 others).
			// Fix: extract the inner ^BlockStatement via union type assertion.
			if bs, ok := block_stmt^.(^BlockStatement); ok {
				body = bs
			}
		}
	} else {
		#partial switch p.cur_type {
		case .Semi, .Comma, .RParen, .RBracket, .RBrace, .EOF:
			report_error(p, "Unexpected token")
		}
		// Expression body - also set in_function so nested `await` / `yield`
		// / `return` within the expression are recognised as being inside
		// this arrow, not at module top level. Previously only the block-body
		// branch above did this, so `async () => expr_with_await` marked the
		// file as a Module (via the top-level-await detector in
		// parse_unary_expr `.Await`) even though the `await` was properly
		// scoped to the async arrow.
		prev_in_function := p.in_function
		p.in_function = true
		body = parse_assignment_expression(p)
		p.in_function = prev_in_function
		// TS arrow-in-conditional: when the concise body is a parenthesised
		// expression inside a ternary consequent and `:` follows, the `:`
		// might be a return-type annotation (not the ternary colon).
		// Pattern: `cond ? v => (params) : RetType => body : alt`.
		// Speculatively try `(params) : Type => body` as a nested arrow.
		if allow_ts_mode(p) && p.conditional_depth > 0 && is_token(p, .Colon) {
			snap := lexer_snapshot(p)
			snap_errs := len(p.errors)
			eat(p) // consume `:`
			ret_type := parse_ts_type(p)
			committed := false
			if ret_type != nil && is_token(p, .Arrow) {
				// Try: build inner arrow `(params): RetType => body`.
				body_expr, _ := body.(^Expression)
				p.pending_paren_start = loc_from_expr(body_expr).span.start
				inner_arrow := parse_arrow_function(p, body_expr)
				// Only commit if the parse succeeded AND a `:` for the
				// ternary alternate still follows.  Without this guard,
				// `0 ? v => (sum = v) : v => 0;` mis-parses the ternary
				// colon as a return-type annotation, consuming the alternate.
				if inner_arrow != nil && len(p.errors) == snap_errs &&
				   is_token(p, .Colon) {
					if ia, ok := inner_arrow^.(^ArrowFunctionExpression); ok {
						ann := new_node(p, TSTypeAnnotation)
						ann.type_annotation = ret_type
						ia.return_type = ann
					}
					body = inner_arrow
					committed = true
				}
			}
			if !committed {
				lexer_restore(p, snap)
				if len(p.errors) > snap_errs {
					resize(&p.errors, snap_errs)
				}
			}
		}
	}

	p.in_async = prev_async
	p.in_generator = prev_in_generator

	// Convert left to parameters
	params := make([dynamic]FunctionParameter, 0, 4, p.allocator)

	if left != nil {
		#partial switch e in left {
		case ^Identifier:
			// §15.3.1 - ArrowParameters BindingIdentifier checks. Strict
			// mode rejects `eval` / `arguments`, FutureReservedWords, `let`,
			// `static`, `yield`, and contextual `await` / `yield` checks
			// follow the same rule as parse_function_declaration.
			// Arrow parameter BindingIdentifier reservation rules: enforced
			// by the semantic checker (ck_check_arrow_param_pattern)
			// consulting strict_mode + in_async + in_generator + source_type.
			ident := new_node(p, Identifier)
			ident^ = e^
			param := FunctionParameter{
				loc     = e.loc,
				pattern = ident,
			}
			bump_append(&params, param)
		case ^AssignmentExpression:
			// Single-param default: `(x = 1) => ...` arrives as AssignmentExpression
			// when the parens don't produce a SequenceExpression (only one arg).
			if e.operator == .Assign {
				assign_pat := new_node(p, AssignmentPattern)
				assign_pat.loc = e.loc
				assign_pat.right = e.right
				lhs_pat, lhs_ok := expr_to_pattern(p, e.left)
				if lhs_ok {
					assign_pat.left = lhs_pat
					param := FunctionParameter{ loc = e.loc, pattern = assign_pat }
					bump_append(&params, param)
				}
			}
		case ^ObjectExpression:
			// Single destructure param: `({a, b}) => ...`. Route through
			// expr_to_pattern so the properties are carried across; previously
			// this allocated an empty ObjectPattern, silently dropping every
			// destructured binding (and every nested default value with it).
			if pat, ok := expr_to_pattern(p, left); ok {
				param := FunctionParameter{ loc = e.loc, pattern = pat }
				bump_append(&params, param)
			}
		case ^ArrayExpression:
			// Single destructure param: `([a, b]) => ...` - same fix as
			// ObjectExpression above.
			if pat, ok := expr_to_pattern(p, left); ok {
				param := FunctionParameter{ loc = e.loc, pattern = pat }
				bump_append(&params, param)
			}
		case ^SpreadElement:
			// Single rest parameter arrow: `(...rest) => body`. The paren
			// group parser handled `...strings` via parse_unary_expr, which
			// produced a ^SpreadElement wrapping the identifier. That slot was
			// previously uncovered in the single-param switch - the arrow was
			// built with `params: []`, silently dropping the rest binding
			// (observed on chalk.js `const chalk = (...strings) => ...` and
			// similar shapes across multiple frameworks). Promote the inner
			// argument to an Identifier pattern and wrap in a RestElement so
			// the emitter sees the ESTree-standard `{ type: "RestElement",
			// argument: Identifier }` shape.
			//
			// §15.3 ArrowParameters - a top-level rest must be wrapped in
			// parens (`(...x) => x`). Bare `...x => x` is a SyntaxError
			// because `...x` isn't a legal expression on its own. Detect via
			// the byte preceding the SpreadElement.
			paren_wrapped_spread := false
			if p.lexer != nil {
				i := int(e.loc.span.start) - 1
				for i >= 0 {
					ch := p.lexer.source_bytes[i]
					if ch == '(' { paren_wrapped_spread = true; break }
					if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { i -= 1; continue }
					break
				}
			}
			if !paren_wrapped_spread {
				report_error(p, "Rest parameter must be wrapped in parentheses")
			}
			inner := e.argument
			if inner != nil {
				inner_pat, ok := expr_to_pattern(p, inner)
				if ok {
					rest := new_node(p, RestElement)
					rest.loc = e.loc
					rest.argument = inner_pat
					param := FunctionParameter{ loc = e.loc, pattern = rest }
					bump_append(&params, param)
				} else {
					report_error(p, "Invalid rest parameter target in arrow function")
				}
			}
		case ^SequenceExpression:
			if len(e.expressions) == 0 {
				// Empty parameters: () => ... (marker from parse_primary_expr)
				// params stays empty
			} else {
				// Multiple parameters: (a, b) => ...
				// Each element in the sequence should be an identifier (or pattern)
				for expr_ptr, param_index in e.expressions {
					// Nil entries arise during error recovery when a cover-expression
					// element fails to parse. Concrete shape: `([]?, {}) => {}` parses
					// `[]?` as ConditionalExpression whose consequent is missing
					// (next token is `,`, not an expression start), so parse_conditional_
					// expr returns nil and the sequence captures a nil pointer for that
					// slot. Without this guard, `expr_ptr^` segfaults. Closes 5 SIGSEGVs
					// across babel/typescript optional-arrow / discard-binding fixtures
					// (S26 W6 phase 3 bug class #2).
					if expr_ptr == nil { continue }
					#partial switch arg in expr_ptr^ {
					case ^Identifier:
						param_ident := new_node(p, Identifier)
						param_ident^ = arg^
						param := FunctionParameter{
							loc     = arg.loc,
							pattern = param_ident,
						}
						bump_append(&params, param)
					case ^SpreadElement:
						// Rest parameter: (a, b, ...rest) => ... (multi-param case).
						if param_index != len(e.expressions) - 1 {
							report_error(p, "Rest parameter must be last in arrow function parameters")
						}
						// The SpreadElement was built during the earlier
						// parse_unary_expr pass over the paren-group; its span
						// ALREADY covers `...<ident>` exactly. By the time we get
						// here, the arrow body has also been parsed, so calling
						// prev_end_offset(p) returns the BODY'S end - which was
						// stamped onto rest.loc.span.end, blowing the RestElement's
						// span out to cover the entire function (observed on chalk.js
						// `(model, level, type, ...arguments_) => { ... }` where
						// params[3].end jumped 458 bytes past the argument name).
						// Reuse the SpreadElement's own span instead.
						rest := new_node(p, RestElement)
						rest.loc = arg.loc
						ident_expr := arg.argument
						if ident_expr != nil {
							// Rest element argument can be a BindingIdentifier OR a
							// nested BindingPattern (ObjectPattern / ArrayPattern) per
							// §15.2.1 / §15.3.1 - BindingRestElement[Yield, Await]:
							//   ... BindingIdentifier
							//   ... BindingPattern
							// Route through expr_to_pattern so destructuring rest
							// targets like `(...rest)`, `(...[a, b])`, `(...{x, y})`
							// are all carried through. Test262 language/expressions/
							// arrow-function/scope-param-rest-elem-var-open.js.
							if pat, ok := expr_to_pattern(p, ident_expr); ok {
								rest.argument = pat
							} else {
								report_error(p, "Expected identifier or pattern in rest parameter")
							}
						}
						// arg.loc already spans `...<ident>` - keep it as-is.
						param := FunctionParameter{
							loc     = arg.loc,
							pattern = rest,
						}
						bump_append(&params, param)
					case ^ObjectExpression:
						// Convert ObjectExpression -> ObjectPattern via expr_to_pattern
						// so nested properties, defaults, and rest elements are all
						// carried through. The old path allocated an empty pattern,
						// silently dropping every destructured field in multi-arrow
						// params like `(a, {x=1}, b) => ...`.
						if pat, ok := expr_to_pattern(p, expr_ptr); ok {
							param := FunctionParameter{ loc = arg.loc, pattern = pat }
							bump_append(&params, param)
						}
					case ^ArrayExpression:
						// Same fix as ObjectExpression above. The prior inline loop
						// only understood bare Identifier elements, dropping any
						// nested AssignmentExpression / SpreadElement / Pattern.
						if pat, ok := expr_to_pattern(p, expr_ptr); ok {
							param := FunctionParameter{ loc = arg.loc, pattern = pat }
							bump_append(&params, param)
						}
					case ^AssignmentExpression:
						// Default parameter: `(a = 1, b = 2) => ...`. The sequence
						// parser sees `a = 1` as an AssignmentExpression (operator `=`)
						// which we convert into an ESTree AssignmentPattern whose
						// `left` is the identifier/pattern and `right` is the default
						// value. Previously this fell through to the "Expected
						// identifier" error branch - breaking 34+ real-world files
						// (chalk.js, zod.js, vue.global.js, tinymce.js, etc.) which
						// use default params on arrow functions.
						if arg.operator != .Assign {
							report_error(p, "Arrow parameter default must use '=' operator")
							continue
						}
						assign_pat := new_node(p, AssignmentPattern)
						assign_pat.loc = arg.loc
						assign_pat.right = arg.right
						// Left side: Identifier, ObjectPattern (from ObjectExpression),
						// or ArrayPattern (from ArrayExpression). Convert via the same
						// Expression→Pattern promotion the outer arms use.
						lhs_pat, lhs_ok := expr_to_pattern(p, arg.left)
						if !lhs_ok {
							report_error(p, "Invalid target in arrow parameter default")
							continue
						}
						assign_pat.left = lhs_pat
						param := FunctionParameter{
							loc     = arg.loc,
							pattern = assign_pat,
						}
						bump_append(&params, param)
					case:
						report_error(p, "Expected identifier in arrow function parameters")
					}
				}
			}
		}
	}
	// Post-switch: handle unrecognized param expressions (e.g. CallExpression).
	// These arise when e.g. a LT between `async` and `(params)` prevented
	// async-arrow detection so `async(foo)` became a CallExpression.
	if left != nil {
		#partial switch _ in left {
		case ^Identifier, ^AssignmentExpression, ^ObjectExpression,
		     ^ArrayExpression, ^SpreadElement, ^SequenceExpression:
			// These are valid arrow param forms, handled by the switch above.
		case:
			report_error(p, "Invalid expression for arrow function parameters")
		}
	}
	// if left is nil, params stays empty (empty parentheses case)

	arrow := new_node(p, ArrowFunctionExpression)
	arrow.loc = start
	arrow.params = params
	arrow.body = body
	arrow.expression = !is_block_body
	arrow.async = false
	arrow.loc.span.end = prev_end_offset(p)

	for param in params {
		if pattern_contains_member_expression(param.pattern) {
			report_error(p, "Member expression cannot be used as a binding target")
		}
	}

	// §14.1.2 - CoverParenthesizedExpressionAndArrowFormalParameters.
	// Parenthesized binding elements in arrow params (`(a, (b)) => 42`,
	// `([(a)]) => {}`, etc.) are rejected by both V8 and OXC.
	// Exception: `((a)) => 0` — OXC with preserveParens=false strips
	// the inner parens so a single-identifier param works. Skip the
	// byte-level paren check only when the param list is a single
	// plain identifier (the paren is just extra grouping).
	is_single_ident_param := len(params) == 1
	if is_single_ident_param {
		if _, ok := params[0].pattern.(^Identifier); !ok {
			is_single_ident_param = false
		}
	}
	if !is_single_ident_param && p.lexer != nil && len(params) > 0 {
		src := p.lexer.source_bytes
		outer_paren := int(start.span.start)
		check_parenthesized_binding(p, params[:], src, outer_paren)
	}

	// ArrowFunction params are always UniqueFormalParameters
	// (ECMA-262 §15.3.1). No sloppy-mode escape hatch - pass
	// strict_override=true so the duplicate-check fires even when the
	// outer function isn't strict.

	// §15.3.1 / §15.9.1 "ContainsUseStrict + !IsSimpleParameterList"
	// early error: enforced by the semantic checker
	// (ck_check_arrow_strict_directive_with_nonsimple_params).
	if is_block_body {
		// §15.3.1 / §15.9.1 - BoundNames(FormalParameters) ∩
		// LexicallyDeclaredNames(ArrowConciseBody) must be empty.
		// `(bar) => { let bar; }` and `async(bar) => { let bar; }`
		// are SyntaxErrors. Test262 language/expressions/{,async-}
		// arrow-function/early-errors-arrow-formals-body-duplicate.js.
		if bs, ok := body.(^BlockStatement); ok && bs != nil {
		}
	}

	return expression_from(p, arrow)
}

parse_conditional_expr :: proc(p: ^Parser, test: ^Expression) -> ^Expression {
	start := loc_from_expr(test)
	eat(p) // consume ?

	// §13.14 ConditionalExpression: the consequent branch (`? expr`) gets
	// [+In] regardless of the enclosing [?In] context. This allows
	// `for (true ? '' in obj : alt; ...)` where `in` inside the true
	// branch is a relational operator, not a for-in separator.
	prev_no_in := p.no_in
	p.no_in = false
	// Track that we're inside a ternary consequent so that
	// looks_like_ts_arrow_params suppresses the aggressive
	// byte-scan that can mistake the ternary `:` for a TS
	// arrow return-type annotation.
	p.conditional_depth += 1
	consequent := parse_assignment_expression(p)
	p.conditional_depth -= 1
	p.no_in = prev_no_in
	if consequent == nil {
		report_error(p, "Expected expression after '?' in conditional expression")
		return nil
	}

	// TS arrow-in-conditional: `cond ? (params): RetType => body : alt`.
	// The `:` that the conditional expects may actually be a return-type
	// annotation on an arrow in the consequent position. Speculatively
	// try `(consequent): Type => body`; commit only if a ternary `:`
	// still follows. Only attempt when the consequent could plausibly be
	// arrow parameters (parenthesised expression, identifier, etc.).
	conseq_could_be_arrow := false
	if consequent != nil {
		#partial switch _ in consequent {
		case ^Identifier, ^AssignmentExpression, ^SequenceExpression,
		     ^ObjectExpression, ^ArrayExpression: conseq_could_be_arrow = true
		case: // ConditionalExpression, Literal, etc. - never arrow params
		}
	}
	if allow_ts_mode(p) && is_token(p, .Colon) && conseq_could_be_arrow {
		snap := lexer_snapshot(p)
		snap_errs := len(p.errors)
		eat(p) // consume `:`
		ret_type := parse_ts_type(p)
		committed := false
		if ret_type != nil && is_token(p, .Arrow) {
			p.pending_paren_start = start.span.start
			inner := parse_arrow_function(p, consequent)
			if inner != nil && len(p.errors) == snap_errs && is_token(p, .Colon) {
				if ia, ok := inner^.(^ArrowFunctionExpression); ok {
					ann := new_node(p, TSTypeAnnotation)
					ann.type_annotation = ret_type
					ia.return_type = ann
				}
				consequent = inner
				committed = true
			}
		}
		if !committed {
			lexer_restore(p, snap)
			if len(p.errors) > snap_errs { resize(&p.errors, snap_errs) }
		}
	}

	if !expect_token(p, .Colon) {
		return nil
	}

	alternate := parse_assignment_expression(p)
	if alternate == nil {
		report_error(p, "Expected expression after ':' in conditional expression")
		return nil
	}

	cond := new_node(p, ConditionalExpression)
	cond.loc = start
	cond.test = test
	cond.consequent = consequent
	cond.alternate = alternate
	cond.loc.span.end = prev_end_offset(p)

	return expression_from(p, cond)
}

// is_valid_assignment_target returns true if `left` is a legal LHS for an
// AssignmentExpression. Per ECMA-262 §13.15:
//
//   * SimpleAssignmentTarget: Identifier / MemberExpression /
//     CallExpression-with-valid-target (rare) / TSNonNullExpression (x!)
//     / ParenthesizedExpression whose inner is also a valid target.
//   * AssignmentPattern (for `=`): ArrayExpression / ObjectExpression that
//     can be reinterpreted as a destructuring pattern.
//
// Other expressions (BinaryExpression, UnaryExpression, literals, etc.)
// are SyntaxErrors in assignment position (`1 + 2 = 3`, `-x = 5`, etc.).
// Returns true if `left` is an Array / Object literal (or paren-wrapper
// thereof) - the only shapes that legitimately need expr_to_pattern
// conversion on an AssignmentExpression. Plain Identifier / Member /
// Call (Annex B.3.4 sloppy) / TS-escape-hatch targets go through
// is_valid_assignment_target directly and skip the pattern walker.
is_destructure_target_candidate :: proc(expr: ^Expression) -> bool {
	if expr == nil { return false }
	#partial switch e in expr^ {
	case ^ArrayExpression, ^ObjectExpression:
		return true
	case ^ParenthesizedExpression:
		return e != nil && is_destructure_target_candidate(e.expression)
	}
	return false
}

// Returns true when `expr` is a CallExpression (possibly wrapped in
// ParenthesizedExpression / TS escape-hatches) - used by the strict-mode
// gate in parse_assignment_expr because Annex B.3.4 only allows
// `f() = x` in sloppy script.
is_call_expression_target :: proc(expr: ^Expression) -> bool {
	if expr == nil { return false }
	#partial switch e in expr^ {
	case ^CallExpression:
		return true
	case ^ParenthesizedExpression:
		return e != nil && is_call_expression_target(e.expression)
	case ^TSNonNullExpression, ^TSAsExpression, ^TSSatisfiesExpression, ^TSTypeAssertion:
		// TS escape hatches re-export AssignmentTargetType of their
		// expression - unwrap and recurse.
		#partial switch v in expr^ {
		case ^TSNonNullExpression:
			return v != nil && is_call_expression_target(v.expression)
		case ^TSAsExpression:
			return v != nil && is_call_expression_target(v.expression)
		case ^TSSatisfiesExpression:
			return v != nil && is_call_expression_target(v.expression)
		case ^TSTypeAssertion:
			return v != nil && is_call_expression_target(v.expression)
		}
	}
	return false
}

is_valid_assignment_target :: proc(expr: ^Expression, is_destructure: bool) -> bool {
	if expr == nil { return false }
	#partial switch e in expr^ {
	case ^Identifier, ^MemberExpression,
	     ^TSNonNullExpression, ^TSAsExpression, ^TSSatisfiesExpression,
	     ^TSTypeAssertion:
		return true
	case ^CallExpression:
		return false
	case ^ParenthesizedExpression:
		return is_valid_assignment_target(e.expression, is_destructure)
	case ^ArrayExpression, ^ObjectExpression:
		// Only valid as destructuring targets (operator must be `=`).
		return is_destructure
	}
	return false
}

// is_simple_assignment_target returns true if `expr` has the spec's
// SIMPLE AssignmentTargetType per §12.6.2.3 - i.e. it's a legal operand
// for UpdateExpression (`++` / `--`) and for `delete` in strict mode.
// Narrower than is_valid_assignment_target: ImportCall /
// ArrayExpression-as-destructure / ObjectExpression-as-destructure are
// all INVALID here. Paren-wrapped simple targets stay simple.
//
// sloppy_legacy_call: Annex B.3.4 extends AssignmentTargetType of
// CallExpression to SIMPLE in sloppy (non-strict) mode. Passing true
// lets `f()++` through in sloppy mode; strict-mode callers must pass
// false so the early error fires.
is_simple_assignment_target :: proc(expr: ^Expression, sloppy_legacy_call: bool) -> bool {
	if expr == nil { return false }
	#partial switch e in expr^ {
	case ^Identifier, ^MemberExpression,
	     ^TSNonNullExpression, ^TSAsExpression, ^TSSatisfiesExpression,
	     ^TSTypeAssertion:
		return true
	case ^CallExpression:
		return sloppy_legacy_call
	case ^ParenthesizedExpression:
		return is_simple_assignment_target(e.expression, sloppy_legacy_call)
	}
	return false
}

parse_assignment_expr :: proc(p: ^Parser, left: ^Expression) -> ^Expression {
	start := loc_from_expr(left)

	current := get_current(p)
	op := token_to_assignment_op(current.type)

	// §12.10 / §13.15 ParenthesizedExpression AssignmentTargetType:
	// AssignmentTargetType of `(Expr)` = AssignmentTargetType of `Expr`.
	// ObjectLiteral / ArrayLiteral / ArrowFunction / AsyncArrowFunction
	// have AssignmentTargetType=invalid, so they're invalid as LHS even
	// though the same shape WITHOUT the parens converts to a valid
	// ObjectAssignmentPattern / ArrayAssignmentPattern. The pointer
	// equality check distinguishes `({}) = 1` (paren-wrapped, error)
	// from `{} = 1` (Pattern conversion, OK at expression position
	// like `({} = {a:1})`) and from `({}.x) = 1` (LHS-tail extended
	// to MemberExpression, OK).
	if left == p.last_paren_expr && left != nil {
		paren_invalid := false
		#partial switch _ in left^ {
		case ^ObjectExpression, ^ArrayExpression, ^ArrowFunctionExpression,
		     ^AssignmentExpression, ^SequenceExpression:
			paren_invalid = true
		}
		if paren_invalid {
			report_error(p, "Invalid left-hand side in assignment")
		}
	}
	// Clear the marker so it doesn't bleed into the RHS or the next
	// AssignmentExpression (e.g. `(a) = (b) = c` - the second `(b)`
	// re-stamps it before the second `=` runs).
	p.last_paren_expr = nil

	eat(p)

	right := parse_expr_with_prec(p, .Assignment)
	if right == nil {
		return nil
	}

	// Validate pattern conversion for = operator (destructuring assignment).
	// Only fire expr_to_pattern when the LHS is actually a destructure
	// candidate (Array / Object literal, or a paren-wrapped version);
	// otherwise CallExpression (§Annex B.3.4 `f() = x` in sloppy) and
	// TS-escape-hatch wrappers would trigger the "Invalid destructuring
	// assignment target" error added to expr_to_pattern's default arm.
	if op == .Assign && is_destructure_target_candidate(left) {
		_, _ = expr_to_pattern(p, left)
	}

	// LHS validity per §13.15. Only runs AFTER right is parsed so error
	// recovery keeps the full assignment tree structurally intact for
	// downstream consumers (emit, walker).
	if !is_valid_assignment_target(left, op == .Assign) {
		// ArrayExpression / ObjectExpression with compound operators
		// (+=, -=, etc.) are semantic errors, not structural ones -
		// OXC defers the check. All other invalid LHS patterns (e.g.
		// BinaryExpression `1 + 2 = 3`) are structural parse errors.
		is_semantic := false
		if op != .Assign && left != nil {
			#partial switch _ in left^ {
			case ^ArrayExpression, ^ObjectExpression:
				is_semantic = true
			case: // fall through
			}
		}
		if is_semantic {
			// §13.15.1 "Invalid LHS in destructured compound assignment":
			// enforced by the semantic checker (ck_check_assignment_invalid_lhs).
		} else {
			report_error(p, "Invalid left-hand side in assignment")
		}
	}
	// §13.15.1 - logical assignment operators (&&=, ||=, ??=) require a
	// SIMPLE assignment target. CallExpressions are NOT simple targets even
	// in sloppy mode for these operators (unlike plain `=` which has Annex
	// B.3.4 legacy relaxation for `f() = x`).
	is_logical_assign := op == .AssignLogicalAnd || op == .AssignLogicalOr || op == .AssignNullish
	if is_logical_assign && is_call_expression_target(left) {
		report_error(p, "Invalid left-hand side in assignment expression")
	}

	// ECMA-262 §13.15.1 - in strict mode it's a SyntaxError for the LHS
	// of an AssignmentExpression to be an IdentifierReference whose name
	// is `eval` or `arguments`. Applies at every target position inside a
	// destructuring pattern too: `[eval] = []`, `({x: arguments} = {})`,
	// and `[...eval] = []` are all SyntaxErrors.
	if p.strict_mode {
	}

	assign := new_node(p, AssignmentExpression)
	assign.loc = start
	assign.operator = op
	assign.left = left
	assign.right = right
	assign.loc.span.end = prev_end_offset(p)

	return expression_from(p, assign)
}

parse_identifier :: proc(p: ^Parser) -> Identifier {
	// Read loc / name from p.cur_tok BEFORE eat advances. Saves the
	// 64 B Token snapshot copy that `current := get_current(p)` was
	// doing once per identifier-name (called from member access, import
	// /export specifiers, JSX attribute names, dynamic imports, optional
	// chains, ~13 sites total). The string slice in p.cur_tok.value
	// points into the source bytes, which outlive eat(p).
	loc := loc_from_token(&p.cur_tok)
	name := p.cur_tok.value
	eat(p)
	return Identifier{loc = loc, name = name}
}

parse_identifier_name :: proc(p: ^Parser) -> Identifier {
	return parse_identifier(p)
}

parse_string_literal :: proc(p: ^Parser) -> StringLiteral {
	// Same shape as parse_identifier above: snapshot only the fields
	// we need before eat(p), avoiding the 64 B Token copy.
	loc := loc_from_token(&p.cur_tok)
	raw := p.cur_tok.value
	value := p.cur_tok.literal.(string) or_else ""
	eat(p)
	return StringLiteral{loc = loc, raw = raw, value = value}
}

// ============================================================================
// Async Arrow Function Helpers
// ============================================================================

parse_async_arrow_function :: proc(p: ^Parser, param: Identifier) -> ^Expression {
	start := param.loc

	if param.name == "await" {
		report_error(p, "'await' cannot be used as an async arrow parameter")
	}
	if p.cur_tok.had_line_terminator {
		report_error(p, "Line terminator not permitted before '=>'")
	}
	eat(p) // consume =>

	prev_async := p.in_async
	p.in_async = true

	// Parse body. Capture block-vs-expression BEFORE consuming the body,
	// so the ESTree `expression` flag reflects the source shape.
	is_block_body := is_token(p, .LBrace)
	body: ArrowFunctionBody
	if is_block_body {
		// Block body - need to set in_function for return statement validation
		prev_in_function := p.in_function
		p.in_function = true
		block_stmt := parse_block_statement(p)
		p.in_function = prev_in_function
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
		prev_in_function := p.in_function
		p.in_function = true
		body = parse_assignment_expression(p)
		p.in_function = prev_in_function
	}

	p.in_async = prev_async

	// Create single param
	params := make([dynamic]FunctionParameter, 0, 1, p.allocator)
	param_ident := new_node(p, Identifier)
	param_ident^ = param
	fn_param := FunctionParameter{
		loc     = param.loc,
		pattern = param_ident,
	}
	bump_append(&params, fn_param)

	arrow := new_node(p, ArrowFunctionExpression)
	arrow.loc = start
	arrow.params = params
	arrow.body = body
	arrow.expression = !is_block_body
	arrow.async = true
	arrow.loc.span.end = prev_end_offset(p)

	// Single-param async arrow: only one FormalParameter, so nothing
	// to dedupe. Still run the helper for consistency / future-proof.
	// Pass strict_override=true per §15.9.1 - async arrows always have
	// UniqueFormalParameters.

	// §15.9.1 - BoundNames(params) ∩ LexicallyDeclaredNames(body)
	// must be empty. `async bar => { let bar; }` is a SyntaxError.
	if is_block_body {
		if bs, ok := body.(^BlockStatement); ok && bs != nil {
		}
	}

	return expression_from(p, arrow)
}

parse_async_arrow_with_parens :: proc(p: ^Parser, async_tok: Token) -> ^Expression {
	async_tok := async_tok  // re-bind to a mutable local; Odin parameters aren't addressable
	start := loc_from_token(&async_tok)

	// Parse parenthesized parameter list
	if !expect_token(p, .LParen) {
		return nil
	}

	// §15.9.1 - CoverCallExpressionAndAsyncArrowHead Contains
	// AwaitExpression is a SyntaxError. Flag the params window so the
	// await-expression constructor reports on entry.
	prev_in_async_params := p.in_async_params
	p.in_async_params = true
	params := parse_function_params(p)
	report_parameter_modifiers_disallowed(p, params[:])
	p.in_async_params = prev_in_async_params

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
	// Closes ~30 OXC corpus rejects in the "Expected semicolon" cluster
	// (S26 W6 phase 3 bug class #17) plus the async-arrow type-predicate
	// follow-up (#18).
	async_return_type: Maybe(^TSTypeAnnotation)
	if (p.lang == .TS || p.lang == .TSX) && is_token(p, .Colon) {
		async_return_type = parse_ts_return_type_annotation(p)
	}

	if !is_token(p, .Arrow) {
		expect_token(p, .Arrow)
		return nil
	}
	if p.cur_tok.had_line_terminator {
		report_error(p, "Line terminator not permitted before '=>'")
	}
	eat(p)

	prev_async := p.in_async
	p.in_async = true

	// Parse body. Capture block-vs-expression before consuming.
	is_block_body := is_token(p, .LBrace)
	body: ArrowFunctionBody
	if is_block_body {
		// Block body - need to set in_function for return statement validation
		prev_in_function := p.in_function
		p.in_function = true
		block_stmt := parse_block_statement(p)
		p.in_function = prev_in_function
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
			report_error(p, "Unexpected token")
		}
		// Same in_function fix as parse_arrow_function's expression arm:
		// without this, a nested `await` inside an async arrow's expression
		// body (e.g. `async () => (<x title={await f()}/>)`) falls into the
		// top-level-await detector in parse_unary_expr `.Await` and spuriously
		// promotes the whole file to `sourceType: "module"`.
		prev_in_function := p.in_function
		p.in_function = true
		body = parse_assignment_expression(p)
		p.in_function = prev_in_function
	}

	p.in_async = prev_async

	arrow := new_node(p, ArrowFunctionExpression)
	arrow.loc = start
	arrow.params = params
	arrow.body = body
	arrow.expression = !is_block_body
	arrow.async = true
	if rt, ok := async_return_type.?; ok { arrow.return_type = rt }
	arrow.loc.span.end = prev_end_offset(p)

	// Async arrow with paren'd params: UniqueFormalParameters always.
	// Pass strict_override=true per §15.9.1.

	// §15.9.1 - BoundNames(params) ∩ LexicallyDeclaredNames(body)
	// must be empty. `async(bar) => { let bar; }` is the canonical
	// case. Test262 language/expressions/async-arrow-function/
	// early-errors-arrow-formals-body-duplicate.js.
	if is_block_body {
		if bs, ok := body.(^BlockStatement); ok && bs != nil {
		}
	}

	// §15.9.1 "ContainsUseStrict + !IsSimpleParameterList" early error
	// for async arrows: enforced by the semantic checker
	// (ck_check_arrow_strict_directive_with_nonsimple_params).

	return expression_from(p, arrow)
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
		report_error(p, "Expected ( after import")
		return nil
	}
	eat(p)

	// §13.3.10 ImportCall: the specifier AssignmentExpression is
	// mandatory. `import()` and `import.defer()` are SyntaxErrors.
	if is_token(p, .RParen) {
		report_error(p, "'import()' requires a specifier")
		eat(p)
		import_expr := new_node(p, ImportExpression)
		import_expr.loc = start
		import_expr.phase = phase
		import_expr.loc.span.end = prev_end_offset(p)
		return expression_from(p, import_expr)
	}

	// §13.3.10: spread (`...x`) is not allowed. ImportCall uses
	// AssignmentExpression directly, not Arguments, so the rest-element
	// production never reaches it.
	if is_token(p, .Dot3) {
		report_error(p, "'...' is not allowed in 'import()' call")
		eat(p) // consume ... and keep parsing so recovery stays reasonable
	}

	// §13.3.10: ImportCall arguments are AssignmentExpression[+In].
	prev_no_in := p.no_in
	p.no_in = false
	specifier := parse_assignment_expression(p)
	if specifier == nil {
		p.no_in = prev_no_in
		return nil
	}

	// ImportCall (§13.3.10):
	//   import( AssignmentExpression ,opt )
	//   import( AssignmentExpression , AssignmentExpression ,opt )
	//
	// Accept trailing comma after the specifier, plus the optional
	// second argument (import attributes object) with its own optional
	// trailing comma. Phase-import proposal does not currently allow a
	// second argument, but accepting it here degrades gracefully - the
	// spec will either adopt the same shape or reject at a later stage.
	options: ^Expression = nil
	if match_token(p, .Comma) {
		if !is_token(p, .RParen) {
			if is_token(p, .Dot3) {
				report_error(p, "'...' is not allowed in 'import()' call")
				eat(p)
			}
			options = parse_assignment_expression(p)
			match_token(p, .Comma)
		}
	}

	p.no_in = prev_no_in

	// consume )
	if !is_token(p, .RParen) {
		report_error(p, "Expected ) after import specifier")
		return nil
	}
	eat(p)

	import_expr := new_node(p, ImportExpression)
	import_expr.loc = start
	import_expr.source = specifier
	import_expr.options = options
	import_expr.phase = phase
	import_expr.loc.span.end = prev_end_offset(p)

	// Collect ESM dynamic import record.
	// NOTE: dynamic `import()` expressions are valid in both Scripts and
	// Modules per ECMA-262, so they do NOT imply module syntax. Only static
	// `import`/`export` declarations (and top-level `await`/`import.meta`)
	// flip has_module_syntax - matches OXC/Acorn/Babel behaviour.
	esm_dynamic := ESMDynamicImport{
		start = import_expr.loc.span.start,
		end = import_expr.loc.span.end,
		moduleRequest = {
			start = 0,
			end = 0,
		},
	}
	// Try to extract module request span from the specifier if it's a string literal
	if spec_expr, ok := specifier^.(^StringLiteral); ok {
		esm_dynamic.moduleRequest.start = spec_expr.loc.span.start
		esm_dynamic.moduleRequest.end = spec_expr.loc.span.end
	}
	bump_append(&p.dynamicImports, esm_dynamic)

	return expression_from(p, import_expr)
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
	if is_token(p, .Assert) && p.cur_tok.had_line_terminator { return attributes }
	eat(p)
	if !expect_token(p, .LBrace) { return attributes }
	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		attr_start := cur_loc(p)
		key: IdentifierName
		if is_token(p, .String) {
			current := get_current(p)
			key = IdentifierName{loc = loc_from_token(&current), name = current.literal.(string) or_else current.value}
			eat(p)
		} else {
			id := parse_identifier_name(p)
			key = IdentifierName{loc = id.loc, name = id.name}
		}
		if !expect_token(p, .Colon) { break }
		// §16.2.2 - attribute values must be string literals.
		if !is_token(p, .String) {
			report_error(p, "Only string literals are allowed as import attribute values")
		}
		value := parse_string_literal(p)
		// Span end must cover the value literal - `attr_start` captured only
		// the key's token span at entry (cur_loc), and was never extended
		// past the value. The previous shape `{ loc = attr_start, ... }` left
		// `loc.span.end` equal to the key's end, so `type: "json"` reported
		// end=39 (key) instead of end=47 (value).
		attr_loc := attr_start
		attr_loc.span.end = value.loc.span.end
		// £16.2.2 ImportDeclaration with Attributes: duplicate attribute keys
		// are a SyntaxError. Check before appending.
		for prev in attributes {
			if prev.key.name == key.name {
				msg := fmt.tprintf("Duplicate import attribute key '%s'", key.name)
				bump_append(&p.errors, ParseError{loc = LexerLoc(attr_loc.span.start), message = msg})
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
//
// The grammar deliberately excludes computed `[...]` member access. Pre
// S26 W6 phase 3 #31 the parser called parse_left_hand_side_expr which
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
	} else if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
		current := get_current(p)
		expr = expression_from(p, new_identifier(p, current))
		eat(p)
		// Dotted chain - allows identifiers, keywords-as-property, AND
		// private identifiers (`@C.#dec`, `@C.#self.#dec`). Reject
		// computed access by stopping at non-`.`.
		for is_token(p, .Dot) {
			eat(p)
			if is_token(p, .PrivateIdentifier) {
				// Private field access: `@obj.#priv`
				prop_tok := get_current(p)
				prop_id := new_identifier(p, prop_tok)
				eat(p)
				mem := new_node(p, MemberExpression)
				mem.loc = start
				mem.object = expr
				mem.property = expression_from(p, prop_id)
				mem.computed = false
				mem.optional = false
				mem.loc.span.end = prev_end_offset(p)
				expr = expression_from(p, mem)
			} else if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
				prop_tok := get_current(p)
				prop_id := new_identifier(p, prop_tok)
				eat(p)
				mem := new_node(p, MemberExpression)
				mem.loc = start
				mem.object = expr
				mem.property = expression_from(p, prop_id)
				mem.computed = false
				mem.optional = false
				mem.loc.span.end = prev_end_offset(p)
				expr = expression_from(p, mem)
			} else {
				report_error(p, "Expected identifier after '.' in decorator")
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
			call.loc.span.end = prev_end_offset(p)
			expr = expression_from(p, call)
			type_arguments = nil // consumed
		} else if is_token(p, .Dot) {
			eat(p)
			if is_token(p, .PrivateIdentifier) || is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
				prop_tok := get_current(p)
				prop_id := new_identifier(p, prop_tok)
				eat(p)
				mem := new_node(p, MemberExpression)
				mem.loc = start
				mem.object = expr
				mem.property = expression_from(p, prop_id)
				mem.computed = false
				mem.optional = false
				mem.loc.span.end = prev_end_offset(p)
				expr = expression_from(p, mem)
			} else {
				report_error(p, "Expected identifier after '.' in decorator")
				break
			}
		} else if allow_ts_mode(p) && is_open_angle_or_lshift(p) {
			type_arguments = parse_ts_type_arguments(p)
			// Type arguments must be followed by `(` for a call. If not,
			// they're dangling — e.g. `@g<number> class C {}` (same line).
			// But `@dec<T>\nclass` (newline) is accepted by OXC.
			if !is_token(p, .LParen) && !is_token(p, .Dot) && !p.cur_tok.had_line_terminator {
				report_error(p, "Type arguments in decorator must be followed by a call")
				break
			}
		} else if allow_ts_mode(p) && is_token(p, .Not) && !p.cur_tok.had_line_terminator {
			// TS non-null assertion postfix: `@x!`, `@x.y!`.
			eat(p)
			nna := new_node(p, TSNonNullExpression)
			nna.loc = start
			nna.expression = expr
			nna.loc.span.end = prev_end_offset(p)
			expr = expression_from(p, nna)
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
		d.loc.span.end = prev_end_offset(p)
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
			report_error(p, "Decorators may not appear after 'export' or 'export default' if they also appear before 'export'")
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
				report_error(p, "Decorators are not valid here.")
			}
		}
		return stmt
	}
	// `abstract class` after decorator - consume `abstract` and set the
	// flag, mirroring the statement-level `.Abstract` → `.Class` path.
	is_abstract_class := false
	if is_token(p, .Abstract) {
		if is_next_token(p, .Class) {
			is_abstract_class = true
			eat(p) // consume `abstract`
		}
	}
	if !is_token(p, .Class) {
		report_error(p, "Expected class after decorator")
		return nil
	}
	stmt := parse_class_declaration(p)
	if stmt != nil {
		#partial switch s in stmt^ {
		case ^ClassDeclaration:
			s.expr.decorators = decorators
			if is_abstract_class { s.expr.abstract = true }
			if len(decorators) > 0 { s.expr.loc.span.start = decorators[0].loc.span.start }
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
	if is_token(p, .RAngle) {
		eat(p)
		// Opening fragment `<>` spans [<, >] inclusive of both angle brackets
		// (2 bytes) - matches OXC's JSXOpeningFragment.{start,end}.
		opening_loc := start
		opening_loc.span.end = u32(prev_end_offset(p))
		children := parse_jsx_children(p)
		// Closing fragment `</>` spans [<, >] - start is at the `<`, not after `</`.
		closing_start := cur_loc(p)
		expect_token(p, .LAngle); expect_token(p, .Div)
		expect_token(p, .RAngle)
		closing_loc := closing_start
		closing_loc.span.end = u32(prev_end_offset(p))
		frag := new_node(p, JSXFragment)
		frag.loc = start
		frag.opening_fragment = JSXOpeningFragment{loc = opening_loc}
		frag.children = children
		frag.closing_fragment = JSXClosingFragment{loc = closing_loc}
		frag.loc.span.end = prev_end_offset(p)
		return expression_from(p, frag)
	}
	name := parse_jsx_element_name(p)
	opening := parse_jsx_opening_element(p, start, name)
	if opening.self_closing {
		elem := new_node(p, JSXElement)
		elem.loc = start
		elem.opening_element = opening
		elem.children = make([dynamic]JSXChild, 0, 0, p.allocator)
		elem.loc.span.end = prev_end_offset(p)
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
		report_error(p, fmt.tprintf("Expected corresponding JSX closing tag for '%s'.", opening_name))
	}
	elem := new_node(p, JSXElement)
	elem.loc = start
	elem.opening_element = opening
	elem.children = children
	elem.closing_element = closing
	elem.loc.span.end = prev_end_offset(p)
	return expression_from(p, elem)
}

// Extract a string representation of a JSXElementName for tag matching.
jsx_element_name_string :: proc(name: JSXElementName) -> string {
	switch n in name {
	case JSXIdentifier:
		return n.name
	case ^JSXNamespacedName:
		if n == nil { return "" }
		return n.name.name  // simplified - ignores namespace
	case ^JSXMemberExpression:
		if n == nil { return "" }
		return n.property.name  // simplified
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
		ns.loc.span.end = prev_end_offset(p)
		return ns
	}
	if is_token(p, .Dot) {
		obj: JSXMemberObject = ident
		for is_token(p, .Dot) {
			eat(p)
			prop := parse_jsx_identifier(p)
			member := new_node(p, JSXMemberExpression)
			member.loc = ident.loc; member.object = obj; member.property = prop
			member.loc.span.end = prev_end_offset(p)
			obj = member
		}
		#partial switch v in obj { case ^JSXMemberExpression: return v }
	}
	return ident
}

parse_jsx_identifier :: proc(p: ^Parser) -> JSXIdentifier {
	if !is_jsx_identifier_token(p) { return JSXIdentifier{} }
	start_loc := cur_loc(p)
	current := get_current(p)
	name := current.value
	// JSX spec: Unicode escapes are not allowed in JSX tag names or
	// attribute names. `<\u0061>` is invalid — must write `<a>`.
	// OXC keeps the raw source for tag comparison, so `<\u0061></a>`
	// gets a "closing tag mismatch" error. Match by using the raw
	// source span as the identifier name when escapes are present.
	if current.has_escape && p.lexer != nil {
		raw := p.lexer.source[int(current.loc):current.raw_end]
		name = raw
	}
	eat(p)
	if is_token(p, .Minus) {
		parts := make([dynamic]string, 0, 4, p.allocator)
		bump_append(&parts, name)
		for is_token(p, .Minus) {
			bump_append(&parts, "-")
			eat(p)
			c := get_current(p)
			bump_append(&parts, c.value)
			eat(p)
		}
		sb: strings.Builder
		strings.builder_init(&sb, p.allocator)
		for part in parts { strings.write_string(&sb, part) }
		name = strings.to_string(sb)
	}
	result := JSXIdentifier{loc = start_loc, name = name}
	result.loc.span.end = prev_end_offset(p)
	return result
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
			spread.loc.span.end = prev_end_offset(p)
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
				if (is_token(p, .LBrace) || is_token(p, .LAngle)) &&
				   p.lexer.nxt.kind == .String {
					// nxt is a String token lexed from inside a `{expr}`
					// or `<elem>` with jsx_string_mode=true.  Rewind the
					// lexer to nxt's start and re-lex in normal JS mode so
					// escape sequences like `\"` are honoured.  Other token
					// types (Template, Number, etc.) are unaffected by the
					// flag and must NOT be re-lexed.
					p.lexer.offset = int(p.lexer.nxt.start)
					p.lexer.nxt = lex_token(p.lexer)
				}
				if is_token(p, .String) {
					str := parse_string_literal(p)
					str_expr := new_node(p, StringLiteral); str_expr^ = str
					attr_value = expression_from(p, str_expr)
				} else if is_token(p, .LBrace) {
					container_start := cur_loc(p)
					// JSX attribute expression: `{expr}`. Use parse_expression
					// (not parse_assignment_expression) to allow the comma
					// operator: `{class1, class2}` is a SequenceExpression.
					// `attr={}` — empty expression container is invalid.
					if is_next_token(p, .RBrace) {
						report_error(p, "JSX attributes must only be assigned a non-empty expression")
					}
					eat(p); expr := parse_expression(p); expect_token(p, .RBrace)
					container := new_node(p, JSXExpressionContainer)
					container.loc = container_start; container.expression = expr
					container.loc.span.end = prev_end_offset(p)
					attr_value = expression_from(p, container)
				} else if is_token(p, .LAngle) {
					attr_value = parse_jsx_element_or_fragment(p)
				} else {
					// JSX attribute has `=` but no value expression.
					report_error(p, "JSX attributes must only be assigned a non-empty expression")
				}
			} else {
				// Boolean attribute (no `=`) - clear the JSX string flag.
				p.lexer.jsx_string_mode = false
			}
			attr: JSXAttribute
			attr.loc = attr_start; attr.name = attr_name; attr.value = attr_value
			attr.loc.span.end = prev_end_offset(p)
			bump_append(&opening.attributes, attr)
		} else { break }
	}
	if is_token(p, .Div) { eat(p); opening.self_closing = true }
	expect_token(p, .RAngle)
	opening.loc.span.end = prev_end_offset(p)
	return opening
}

parse_jsx_attribute_name :: proc(p: ^Parser) -> JSXAttributeName {
	ident := parse_jsx_identifier(p)
	if is_token(p, .Colon) {
		eat(p); name := parse_jsx_identifier(p)
		ns := new_node(p, JSXNamespacedName)
		ns.loc = ident.loc; ns.namespace = ident; ns.name = name
		ns.loc.span.end = prev_end_offset(p)
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
						report_error(p, "Unexpected token. Did you mean `{'>'}` or `&gt;`?")
						break
					}
				}
			}
			bump_append(&children, text)
		}
		if is_token(p, .LAngle) {
			if peek_dispatch(p).type == .Div { break }
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
			empty_start := start.span.start + 1
			eat(p)
			expr: ^Expression = nil
			if !is_token(p, .RBrace) { expr = parse_assignment_expression(p) }
			rbrace_start := u32(cur_offset(p))
			expect_token(p, .RBrace)
			container := new_node(p, JSXExpressionContainer)
			container.loc = start
			if expr != nil { container.expression = expr
			} else {
				empty := new_node(p, JSXEmptyExpression)
				empty.loc = Loc{span = Span{start = empty_start, end = rbrace_start}}
				container.expression = expression_from(p, empty)
			}
			container.loc.span.end = prev_end_offset(p)
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
	start := Loc{span = Span{start = u32(text_start), end = u32(text_start)}}
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
	p.lexer.nxt = lex_token(p.lexer)
	p.cur_type = p.lexer.cur.kind
	p.cur_tok.type = p.lexer.cur.kind
	p.cur_tok.loc = LexerLoc(p.lexer.cur.start)
	if p.lexer.cur.start < p.lexer.cur.end {
		p.cur_tok.value = p.lexer.source[p.lexer.cur.start:p.lexer.cur.end]
	}
	text := new_node(p, JSXText)
	text.loc = start; text.value = value; text.raw = value
	text.loc.span.end = u32(off)
	return text
}

parse_jsx_closing_element :: proc(p: ^Parser, expected: JSXElementName) -> ^JSXClosingElement {
	start := cur_loc(p)
	expect_token(p, .LAngle); expect_token(p, .Div)
	name := parse_jsx_element_name(p)
	expect_token(p, .RAngle)
	closing := new_node(p, JSXClosingElement)
	closing.loc = start; closing.name = name
	closing.loc.span.end = prev_end_offset(p)
	return closing
}

// ============================================================================
// TypeScript Type Parsing (Phase 3)
// ============================================================================

// parse_ts_return_type_annotation parses a function return type annotation
// starting at `:`, and supports the TS type-predicate forms:
//     : x is T          - TSTypePredicate { parameter_name, type_annotation, asserts:false }
//     : asserts x is T  - TSTypePredicate { parameter_name, type_annotation, asserts:true  }
//     : asserts x       - TSTypePredicate { parameter_name, type_annotation:nil, asserts:true }
// Falls back to a plain type annotation otherwise.
//
// The caller has NOT consumed `:`. This proc consumes the leading `:`.
parse_ts_return_type_annotation :: proc(p: ^Parser) -> ^TSTypeAnnotation {
	if !is_token(p, .Colon) { return nil }
	ann_start := cur_loc(p)
	eat(p) // consume `:`
	// Function return types re-allow conditional types.
	saved_disallow_ct := p.ts_disallow_conditional_types
	p.ts_disallow_conditional_types = 0
	defer p.ts_disallow_conditional_types = saved_disallow_ct

	// Detect "asserts <ident>" or "asserts <ident> is <type>" or "<ident> is <type>".
	// We need to peek WITHOUT committing, because the annotation can also be
	// a regular type like `string` or `T | null`.
	//
	// Heuristic: at this point the current token must be either
	//   - `.Asserts` identifier-keyword followed by an
	//     Identifier or This, optionally followed by `is <type>`. We can consume.
	//   - An Identifier followed by `.Is` - then it's `x is T`.
	//
	// "this is T" is also valid - where `this` is the parameter name.
	asserts := false
	pred_start := cur_loc(p)

	is_predicate := false
	if is_token(p, .Asserts) && (p.lexer.nxt.kind == .Identifier || p.lexer.nxt.kind == .This) {
		asserts = true
		eat(p) // consume `asserts`
		is_predicate = true
	} else if (is_token(p, .Identifier) || is_token(p, .This)) && p.lexer.nxt.kind == .Is && (p.lexer.nxt.flags & FLAG_NEW_LINE) == 0 {
		// Line break before `is` triggers ASI - `I\nis()` is two members, not a type predicate.
		is_predicate = true
	}

	if is_predicate {
		// Parse parameter name: Identifier or `this`. Each leaf carries
		// its own location; the previously-bound `name_loc` was unused.
		name_cur := get_current(p)
		name_ident := new_node(p, Identifier)
		name_ident.loc = loc_from_token(&name_cur)
		name_ident.name = name_cur.value
		eat(p) // consume identifier or `this`
		name_expr := expression_from(p, name_ident)

		// Optional `is <type>` (may be absent for pure `asserts x`).
		type_ann_opt: Maybe(^TSTypeAnnotation)
		if is_token(p, .Is) {
			eat(p) // consume `is`
			inner_start := cur_loc(p)
			inner_ty := parse_ts_type(p)
			inner_ann := new_node(p, TSTypeAnnotation)
			inner_ann.loc = inner_start
			inner_ann.type_annotation = inner_ty
			inner_ann.loc.span.end = prev_end_offset(p)
			type_ann_opt = inner_ann
		}

		// Build TSTypePredicate.
		pred := new_node(p, TSTypePredicate)
		pred.loc = pred_start
		pred.parameter_name = name_expr
		pred.type_annotation = type_ann_opt
		pred.asserts = asserts
		pred.loc.span.end = prev_end_offset(p)

		// Wrap in TSType then TSTypeAnnotation.
		tst := new_node(p, TSType); tst^ = pred
		ann := new_node(p, TSTypeAnnotation)
		ann.loc = ann_start
		ann.type_annotation = tst
		ann.loc.span.end = prev_end_offset(p)
		return ann
	}

	// Fallback: regular type annotation.
	inner := parse_ts_type(p)
	ann := new_node(p, TSTypeAnnotation)
	ann.loc = ann_start
	ann.type_annotation = inner
	ann.loc.span.end = prev_end_offset(p)
	return ann
}

parse_ts_type_annotation :: proc(p: ^Parser) -> ^TSTypeAnnotation {
	start := cur_loc(p); eat(p)
	// TS type predicates in non-return positions: OXC only accepts
	// `this is T` and `asserts x [is T]` in variable annotations.
	// `identifier is T` (e.g. `var y: z is number`) is rejected by OXC
	// at parse time — only parse_ts_return_type_annotation handles that.
	asserts := false
	is_predicate := false
	if is_token(p, .Asserts) && (p.lexer.nxt.kind == .Identifier || p.lexer.nxt.kind == .This) {
		asserts = true
		eat(p)
		is_predicate = true
	} else if is_token(p, .This) && p.lexer.nxt.kind == .Is && (p.lexer.nxt.flags & FLAG_NEW_LINE) == 0 {
		// `this is T` is unambiguous — allow in non-return positions.
		is_predicate = true
	}
	if is_predicate {
		pred_start := cur_loc(p)
		name_cur := get_current(p)
		name_ident := new_node(p, Identifier)
		name_ident.loc = loc_from_token(&name_cur)
		name_ident.name = name_cur.value
		eat(p)
		name_expr := expression_from(p, name_ident)
		inner_ann_opt: Maybe(^TSTypeAnnotation)
		if is_token(p, .Is) {
			eat(p)
			inner_start := cur_loc(p)
			inner_ty := parse_ts_type(p)
			inner_ann := new_node(p, TSTypeAnnotation)
			inner_ann.loc = inner_start
			inner_ann.type_annotation = inner_ty
			inner_ann.loc.span.end = prev_end_offset(p)
			inner_ann_opt = inner_ann
		}
		pred := new_node(p, TSTypePredicate)
		pred.loc = pred_start
		pred.parameter_name = name_expr
		pred.type_annotation = inner_ann_opt
		pred.asserts = asserts
		pred.loc.span.end = prev_end_offset(p)
		pred_ts := new_node(p, TSType)
		pred_ts^ = pred
		ann := new_node(p, TSTypeAnnotation)
		ann.loc = start
		ann.type_annotation = pred_ts
		ann.loc.span.end = prev_end_offset(p)
		return ann
	}
	ts_type := parse_ts_type(p)
	if ts_type == nil {
		report_error(p, "Expected type after ':'")
	}
	ann := new_node(p, TSTypeAnnotation)
	ann.loc = start; ann.type_annotation = ts_type
	ann.loc.span.end = prev_end_offset(p)
	return ann
}

// parse_ts_type_annotation_bare - like parse_ts_type_annotation but assumes
// the leading `:` or `=>` has already been consumed. The outer TSFunctionType
// needs a return type wrapped in TSTypeAnnotation, but the return type starts
// directly at the current token (no `:` delimiter between `=>` and the type).
// Also supports the TS TypePredicate forms when in return-type position:
//     x is T          - TSTypePredicate { parameter_name, type_annotation, asserts:false }
//     asserts x is T  - TSTypePredicate { parameter_name, type_annotation, asserts:true  }
//     asserts x       - TSTypePredicate { parameter_name, type_annotation:nil, asserts:true }
// `(node: T) => node is U` is the canonical use - the inner function-type's
// return slot can be a type predicate.
parse_ts_type_annotation_bare :: proc(p: ^Parser) -> ^TSTypeAnnotation {
	start := cur_loc(p)
	// Function return types re-allow conditional types - the `=>`
	// boundary acts like a grouping construct.
	saved_disallow_ct := p.ts_disallow_conditional_types
	p.ts_disallow_conditional_types = 0
	defer p.ts_disallow_conditional_types = saved_disallow_ct
	// Type-predicate fast path mirrors parse_ts_return_type_annotation but
	// without the leading `:` consumption.
	asserts := false
	is_predicate := false
	if is_token(p, .Asserts) && (p.lexer.nxt.kind == .Identifier || p.lexer.nxt.kind == .This) {
		asserts = true
		eat(p)
		is_predicate = true
	} else if (is_token(p, .Identifier) || is_token(p, .This)) && p.lexer.nxt.kind == .Is && (p.lexer.nxt.flags & FLAG_NEW_LINE) == 0 {
		// Line break before `is` triggers ASI - not a type predicate.
		is_predicate = true
	}
	if is_predicate {
		name_cur := get_current(p)
		name_ident := new_node(p, Identifier)
		name_ident.loc = loc_from_token(&name_cur)
		name_ident.name = name_cur.value
		eat(p)
		name_expr := expression_from(p, name_ident)
		inner_ann_opt: Maybe(^TSTypeAnnotation)
		if is_token(p, .Is) {
			eat(p)
			inner_start := cur_loc(p)
			inner_ty := parse_ts_type(p)
			inner_ann := new_node(p, TSTypeAnnotation)
			inner_ann.loc = inner_start
			inner_ann.type_annotation = inner_ty
			inner_ann.loc.span.end = prev_end_offset(p)
			inner_ann_opt = inner_ann
		}
		pred := new_node(p, TSTypePredicate)
		pred.loc = start
		pred.parameter_name = name_expr
		pred.type_annotation = inner_ann_opt
		pred.asserts = asserts
		pred.loc.span.end = prev_end_offset(p)
		pred_ts := new_node(p, TSType)
		pred_ts^ = pred
		ann := new_node(p, TSTypeAnnotation)
		ann.loc = start
		ann.type_annotation = pred_ts
		ann.loc.span.end = prev_end_offset(p)
		return ann
	}
	ts_type := parse_ts_type(p)
	if ts_type == nil {
		report_error(p, "Expected type in type annotation")
	}
	ann := new_node(p, TSTypeAnnotation)
	ann.loc = start; ann.type_annotation = ts_type
	ann.loc.span.end = prev_end_offset(p)
	return ann
}

// looks_like_ts_function_type - cheap detection for function type vs
// paren-wrapped type at a `(`. Caller is at `.LParen` in parse_ts_primary_type.
// See comments at the call site for the signal table.
looks_like_ts_function_type :: proc(p: ^Parser) -> bool {
	assert(p.cur_type == .LParen)
	nxt := p.lexer.nxt.kind
	if nxt == .RParen { return true }
	if nxt == .Dot3  { return true }
	// `this:` parameter - TS function types can declare an explicit
	// `this` parameter to type-check the callee's receiver:
	//   type Handler = (this: Element, ev: Event) => void;
	// `this` lexes as the .This keyword, not .Identifier, so the
	// existing Identifier branch missed it. Test ts-conformance:
	// @babel/types/lib/index-legacy.d.ts (TraversalHandler).
	if nxt == .This {
		snap := lexer_snapshot(p)
		eat(p) // consume `(`
		eat(p) // consume `this`
		after := p.cur_type
		lexer_restore(p, snap)
		return after == .Colon
	}
	// Destructured parameter - `({ name }: T) => U` or `([x]: T) => U`.
	// Skip the balanced `{...}` / `[...]` and check if `:`, `?`, `,` or
	// `)`+`=>` follows. Closes ~16 OXC corpus rejects in the
	// "Expected ), got :" cluster (typescript fixtures with shapes like
	// `let f: ({ name: alias }: Named) => void` and
	// `catch ({ x }: unknown)` patterns when used in function-type
	// positions).
	if nxt == .LBrace || nxt == .LBracket {
		snap := lexer_snapshot(p)
		eat(p) // consume `(`
		open_kind := p.cur_type
		close_kind: TokenType = .RBrace if open_kind == .LBrace else .RBracket
		eat(p)  // consume `{` or `[`
		depth := 1
		// Bounded scan - destructuring patterns rarely exceed a few hundred
		// tokens, but keep a hard cap to satisfy the no-unbounded-loop rule.
		for i := 0; i < 4096 && depth > 0 && p.cur_type != .EOF; i += 1 {
			#partial switch p.cur_type {
			case .LBrace, .LBracket, .LParen:
				depth += 1
			case .RBrace, .RBracket, .RParen:
				if p.cur_type == close_kind && depth == 1 {
					depth = 0
					continue // don't eat - want to inspect after
				}
				depth -= 1
			}
			eat(p)
		}
		after_close: TokenType = .EOF
		after_rparen: TokenType = .EOF
		if depth == 0 && p.cur_type == close_kind {
			eat(p) // consume the matching close `}` / `]`
			after_close = p.cur_type
			// `({a})=>R` - capture the token after the outer `)` BEFORE
			// restoring, since lexer_restore rewinds the cur/nxt cache.
			if after_close == .RParen {
				eat(p) // consume `)`
				after_rparen = p.cur_type
			}
		}
		lexer_restore(p, snap)
		// Function-type signals after a destructured parameter:
		//   `:` - parameter type annotation
		//   `?` - optional parameter
		//   `,` - more parameters follow
		//   `=` - default initializer (rare but legal in TS function types)
		if after_close == .Colon || after_close == .Question ||
		   after_close == .Comma || after_close == .Assign {
			return true
		}
		// Untyped destructured param: `({a})=>R`. The next non-trivia
		// after the matching `}` is `)`, then `=>`. Test:
		// typescript/compiler/renamingDestructuredPropertyInFunctionType.ts
		// (lines 12-19, including untyped \`({ a: string }) => typeof X\`).
		if after_close == .RParen && after_rparen == .Arrow {
			return true
		}
		return false
	}
	// Accept any token that can stand in for a BindingIdentifier in
	// parameter position - plain `.Identifier` plus every contextual
	// keyword (`from`, `of`, `as`, `async`, `let`, `static`, ...). Pre-fix
	// the check only allowed `.Identifier`, so a TS function type whose
	// inner param happened to be named `from` (`(from: T) => U`) failed
	// the cheap detect and fell through to parenthesized-type parsing,
	// which then tripped on the `:`. Test:
	// typescript/compiler/genericCallInferenceWithGenericLocalFunction.ts.
	if !is_identifier_like_token(nxt) { return false }

	snap := lexer_snapshot(p)
	eat(p) // consume `(`
	eat(p) // consume Identifier
	after := p.cur_type
	lexer_restore(p, snap)
	// `:` / `?` - parameter type annotation or optional marker.
	// `,` - multiple parameters `(a, b) => R`.
	// `=` - parameter default value `(a = 3) => R`.
	if after == .Colon || after == .Question || after == .Comma || after == .Assign { return true }
	// Single untyped parameter `(item) =>` - if `)` is immediately
	// followed by `=>`, this is a function type with an untyped param.
	// Without this check, `(item) => item is A` is mis-parsed as a
	// parenthesised type reference.
	if after == .RParen {
		snap2 := lexer_snapshot(p)
		eat(p) // consume `(`
		eat(p) // consume Identifier
		eat(p) // consume `)`
		arrow_follows := p.cur_type == .Arrow
		lexer_restore(p, snap2)
		return arrow_follows
	}
	return false
}

parse_ts_type :: proc(p: ^Parser) -> ^TSType {
	check := parse_ts_union_type(p)
	if check == nil { return nil }
	// Conditional type: `T extends U ? X : Y`
	// Suppressed when ts_disallow_conditional_types > 0 (e.g. inside
	// the constraint of an `infer T extends C` during speculative parse).
	// ASI guard: `extends` on a new line is NOT a conditional type
	// continuation - it's the start of the next member in an interface
	// or type literal. e.g. `a?: number\nextends?: string`.
	if is_token(p, .Extends) && p.ts_disallow_conditional_types == 0 && !p.cur_tok.had_line_terminator {
		eat(p)
		// The extends type of a conditional is parsed with conditional
		// types suppressed (matching TypeScript's
		// disallowConditionalTypesAnd). This ensures that `infer U
		// extends C` inside the extends position always treats `extends`
		// as a constraint (no speculative lookahead needed).
		p.ts_disallow_conditional_types += 1
		exts := parse_ts_type(p)
		p.ts_disallow_conditional_types -= 1
		expect_token(p, .Question)
		true_type := parse_ts_type(p)
		expect_token(p, .Colon)
		false_type := parse_ts_type(p)
		cond := new_node(p, TSConditionalType)
		if loc := get_ts_type_loc(check); loc != nil { cond.loc = loc^ }
		cond.check_type = check; cond.extends_type = exts
		cond.true_type = true_type; cond.false_type = false_type
		cond.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = cond; return r
	}
	return check
}

parse_ts_union_type :: proc(p: ^Parser) -> ^TSType {
	// TS allows an OPTIONAL leading `|` before the first union member, which
	// is idiomatic when each member starts on its own line:
	//   type X =
	//     | A
	//     | B
	//     | C;
	// The leading pipe is purely cosmetic - the union semantics are
	// unchanged. Same allowance applies to `&` for intersections (handled
	// in parse_ts_intersection_type below).
	leading_pipe_start := cur_loc(p).span.start
	has_leading_pipe := is_token(p, .BitOr)
	if has_leading_pipe {
		eat(p)
	}
	first := parse_ts_intersection_type(p)
	if first == nil { return nil }
	if !is_token(p, .BitOr) {
		// Single-element union with leading pipe: emit a TSUnionType so the
		// AST faithfully reflects the source. Otherwise, the lone leading
		// pipe would silently disappear and the round-tripper / position
		// invariant gates would lose track of it.
		if has_leading_pipe {
			types := make([dynamic]^TSType, 0, 1, p.allocator)
			bump_append(&types, first)
			u := new_node(p, TSUnionType); u.types = types
			u.loc.span.start = leading_pipe_start
			u.loc.span.end = prev_end_offset(p)
			r := new_node(p, TSType); r^ = u; return r
		}
		return first
	}
	types := make([dynamic]^TSType, 0, 4, p.allocator)
	bump_append(&types, first)
	for is_token(p, .BitOr) {
		eat(p)
		t := parse_ts_intersection_type(p)
		if t != nil {
			report_unparenthesized_function_type(p, t)
			bump_append(&types, t)
		}
	}
	// Check the first constituent too (only matters when there are >1).
	report_unparenthesized_function_type(p, first)
	u := new_node(p, TSUnionType); u.types = types
	if has_leading_pipe {
		u.loc.span.start = leading_pipe_start
	} else if loc := get_ts_type_loc(first); loc != nil {
		u.loc = loc^
	}
	u.loc.span.end = prev_end_offset(p)
	r := new_node(p, TSType); r^ = u; return r
}

parse_ts_intersection_type :: proc(p: ^Parser) -> ^TSType {
	// Optional leading `&` mirrors the leading-pipe allowance for unions.
	// `type X = & A & B` is equivalent to `type X = A & B`.
	leading_amp_start := cur_loc(p).span.start
	has_leading_amp := is_token(p, .BitAnd)
	if has_leading_amp {
		eat(p)
	}
	first := parse_ts_primary_type(p)
	if first == nil { return nil }
	if !is_token(p, .BitAnd) {
		if has_leading_amp {
			types := make([dynamic]^TSType, 0, 1, p.allocator)
			bump_append(&types, first)
			i := new_node(p, TSIntersectionType); i.types = types
			i.loc.span.start = leading_amp_start
			i.loc.span.end = prev_end_offset(p)
			r := new_node(p, TSType); r^ = i; return r
		}
		return first
	}
	types := make([dynamic]^TSType, 0, 4, p.allocator)
	bump_append(&types, first)
	for is_token(p, .BitAnd) {
		eat(p)
		t := parse_ts_primary_type(p)
		if t != nil {
			report_unparenthesized_function_type(p, t)
			bump_append(&types, t)
		}
	}
	// Check the first constituent too.
	report_unparenthesized_function_type(p, first)
	i := new_node(p, TSIntersectionType); i.types = types
	if has_leading_amp {
		i.loc.span.start = leading_amp_start
	} else if loc := get_ts_type_loc(first); loc != nil {
		i.loc = loc^
	}
	i.loc.span.end = prev_end_offset(p)
	r := new_node(p, TSType); r^ = i; return r
}

// §A.5 - TS grammar requires function / constructor types to be
// parenthesized when they appear as direct constituents of a union
// or intersection type. `string | () => void` is invalid — must be
// `string | (() => void)`. Report the error but keep the type so
// downstream processing continues.
report_unparenthesized_function_type :: proc(p: ^Parser, t: ^TSType) {
	if t == nil { return }
	#partial switch _ in t^ {
	case ^TSFunctionType:
		report_error(p, "Function type must be parenthesized in union or intersection")
	case ^TSConstructorType:
		report_error(p, "Constructor type must be parenthesized in union or intersection")
	}
}

parse_ts_kw :: proc(p: ^Parser, $T: typeid, start: Loc) -> ^TSType {
	eat(p)
	node := new_node(p, T); node.loc = start; node.loc.span.end = prev_end_offset(p)
	result := new_node(p, TSType); result^ = node
	return parse_ts_postfix(p, result, start)
}

// parse_ts_constructor_type parses a TS constructor type literal starting at
// the `new` token (which has not yet been consumed). `abstract` is true when
// the prefix `abstract` keyword has already been eaten by the caller. Shape
// matches OXC's TSConstructorType: { abstract, typeParameters, params, returnType }.
parse_ts_constructor_type :: proc(p: ^Parser, start: Loc, abstract: bool) -> ^TSType {
	eat(p) // consume `new`
	type_params: Maybe(^TSTypeParameterDeclaration)
	if is_token(p, .LAngle) {
		type_params = parse_ts_type_parameters(p)
	}
	if !is_token(p, .LParen) {
		report_error(p, "Expected '(' after 'new' in constructor type")
		return nil
	}
	params := parse_ts_sig_params(p)
	if !is_token(p, .Arrow) {
		report_error(p, "Expected '=>' in constructor type")
		return nil
	}
	arrow_start := u32(cur_offset(p))
	eat(p) // consume `=>`
	ret_type := parse_ts_type_annotation_bare(p)
	if ret_type != nil {
		ret_type.loc.span.start = arrow_start
	}
	ctor := new_node(p, TSConstructorType)
	ctor.loc = start
	ctor.type_parameters = type_params
	ctor.params = params
	ctor.return_type = ret_type
	ctor.abstract_ = abstract
	ctor.loc.span.end = prev_end_offset(p)
	r := new_node(p, TSType); r^ = ctor
	return parse_ts_postfix(p, r, start)
}

// Parse a TS template-literal type with substitutions starting at the
// .TemplateHead token. Mirrors parse_template_literal's quasi-collecting
// loop but parses each `${...}` slot as a TS type rather than an
// expression. Closes ~10 OXC corpus rejects in the variable-binding
// cluster (e.g. `noSubstitutionTemplateStringLiteralTypes.ts` neighbours)
// and is required for any `\`prefix-${T}-suffix\`` literal type.
parse_ts_template_literal_type :: proc(p: ^Parser, start: Loc) -> ^TSType {
	head := get_current(p)
	node := new_node(p, TSTemplateLiteralType); node.loc = start
	node.quasis = make([dynamic]TemplateElement, 0, 4, p.allocator)
	node.types  = make([dynamic]^TSType, 0, 4, p.allocator)
	head_elem := TemplateElement{loc = loc_from_token(&head), tail = false, raw = head.value}
	if cooked, ok := head.literal.(string); ok { head_elem.cooked = cooked }
	bump_append(&node.quasis, head_elem)
	eat(p) // consume TemplateHead
	for {
		t := parse_ts_type(p)
		if t != nil { bump_append(&node.types, t) }
		// After `>>` split inside type arguments, lex_template_resume
		// may have already fired (decrementing template_depth) during
		// the advance_token that produced `nxt`.  But the TemplateTail
		// was stored as `nxt`, then a subsequent `eat` consumed the
		// second `>` (making TemplateTail the new `cur`), then the outer
		// expect_close_angle consumed THAT and advanced again - leaving
		// `}` as the current token with template_depth already 0.
		// Fix: when cur is `}` (RBrace), re-lex it as a template
		// continuation regardless of template_depth.
		if is_token(p, .RBrace) {
			l := p.lexer
			l.offset = int(l.cur.start)
			l.template_depth += 1  // compensate for the premature decrement
			l.cur = lex_template_resume(l, l.cur.start, l.cur.flags)
			l.nxt = lex_token(l)
			p.cur_type = l.cur.kind
			p.cur_tok.type = l.cur.kind
			p.cur_tok.loc = LexerLoc(l.cur.start)
			if l.cur.start < l.cur.end {
				p.cur_tok.value = l.source[l.cur.start:l.cur.end]
			}
		}
		tok := get_current(p)
		if tok.type == .TemplateMiddle {
			mid_elem := TemplateElement{loc = loc_from_token(&tok), tail = false, raw = tok.value}
			if cooked, ok := tok.literal.(string); ok { mid_elem.cooked = cooked }
			bump_append(&node.quasis, mid_elem)
			eat(p)
			continue
		}
		if tok.type == .TemplateTail {
			tail_elem := TemplateElement{loc = loc_from_token(&tok), tail = true, raw = tok.value}
			if cooked, ok := tok.literal.(string); ok { tail_elem.cooked = cooked }
			bump_append(&node.quasis, tail_elem)
			eat(p)
			break
		}
		report_error(p, "Expected template middle / tail token in template literal type")
		break
	}
	node.loc.span.end = prev_end_offset(p) + 1 // include trailing backtick
	r := new_node(p, TSType); r^ = node
	return parse_ts_postfix(p, r, start)
}

parse_ts_primary_type :: proc(p: ^Parser) -> ^TSType {
	start := cur_loc(p)
	// `abstract new(...) => T` - TS abstract constructor type. `abstract`
	// lexes as .Identifier (contextual keyword); we require the next token
	// to be .New so the lookahead has zero false positives. Treated here
	// rather than inside the .New case so the `start` Loc captures the
	// `abstract` token (not the `new` after it).
	// `abstract new(...) => T` - the lexer emits `.Abstract` for the
	// keyword (see lexer.odin keyword-table). When followed by `new` it's
	// an abstract-constructor type prefix; otherwise it falls through and
	// is parsed as a TSTypeReference whose typeName is Identifier("abstract")
	// via the .Abstract case in the main switch below.
	if p.cur_type == .Abstract && peek_token(p).type == .New {
		eat(p) // consume `abstract`
		return parse_ts_constructor_type(p, start, true)
	}
	#partial switch p.cur_type {
	case .New:
		// TS constructor type literal: `new (x: T) => U`, optionally with
		// type parameters `new <T>(x: T) => U`. Closes ~80 OXC corpus
		// rejects in the "Expected '=', ',', or ';' after variable binding"
		// cluster (S26 W6 phase 3 bug class #14). Pre-fix the .New token
		// in type position fell through to the default `return nil` and the
		// outer parser surfaced `new` as a JS NewExpression in expression
		// position, breaking the variable binding. ESTree-TS shape:
		//   { type: "TSConstructorType", abstract, typeParameters, params,
		//     returnType }
		return parse_ts_constructor_type(p, start, false)
	case .LAngle:
		// TS generic function type: `<T>(x: T) => U`. The `<` in type
		// position has only one possible meaning - the start of TSFunctionType
		// with type parameters. Pre-fix kessel didn't recognize this, so
		// type annotations like `declare const f: <T>(x: T) => T` choked at
		// the `<` and the parser fell back to default-binding logic that
		// reported "Expected '=', ',', or ';' after variable binding". In
		// type-alias position (`type F = <T>(...) => T`) the same gap was
		// hidden because the parser silently treated `<T>(...) => T` as a
		// JS ArrowFunctionExpression in expression-statement position
		// (the trailing `;` made the test pass exit-cleanly while the AST
		// shape was wrong). Closes 130+ OXC corpus rejects in the
		// "Expected '=', ',', or ';' after variable binding" cluster
		// (S26 W6 phase 3 bug class #9).
		type_params := parse_ts_type_parameters(p)
		if !is_token(p, .LParen) {
			report_error(p, "Expected '(' after generic type parameters in function type")
			return nil
		}
		params := parse_ts_sig_params(p)
		if !is_token(p, .Arrow) {
			report_error(p, "Expected '=>' in generic function type")
			return nil
		}
		arrow_start := u32(cur_offset(p))
		eat(p) // consume `=>`
		ret_type := parse_ts_type_annotation_bare(p)
		if ret_type != nil {
			ret_type.loc.span.start = arrow_start
		}
		fn := new_node(p, TSFunctionType)
		fn.loc = start
		fn.type_parameters = type_params
		fn.params = params
		fn.return_type = ret_type
		fn.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = fn
		return parse_ts_postfix(p, r, start)
	case .LParen:
		// TS function type with named params: `(x: T, ...) => U`.
		// Detected cheaply via 1-2 token lookahead because the outer type
		// grammar has no ambiguity here - a `(` in a type position is
		// either a function type, a paren-wrapped type, or (illegally) a
		// tuple typo. Named params and rest params are only legal in a
		// function type, so their presence is a definitive signal.
		//
		// Signals (all require =>-terminated form):
		//   ()           - zero-arg function type (e.g. `() => void`).
		//   (...         - rest parameter.
		//   (Identifier : / (Identifier ?  - named param with annotation.
		if looks_like_ts_function_type(p) {
			params := parse_ts_sig_params(p)
			if !is_token(p, .Arrow) {
				report_error(p, "Expected '=>' in function type")
				return nil
			}
			// Capture the `=>` position BEFORE eating so the returnType's
			// TSTypeAnnotation can start there. OXC's `TSFunctionType.returnType`
			// TSTypeAnnotation spans `=> <inner>` - the wrapper's `start` is
			// the `=>` offset, not the inner type's start. Previously Kessel
			// started at the inner type, drifting 3-4 bytes on every function
			// type annotation.
			arrow_start := u32(cur_offset(p))
			eat(p) // consume `=>`
			ret_type := parse_ts_type_annotation_bare(p)
			if ret_type != nil {
				ret_type.loc.span.start = arrow_start
			}
			fn := new_node(p, TSFunctionType)
			fn.loc = start
			fn.params = params
			fn.return_type = ret_type
			fn.loc.span.end = prev_end_offset(p)
			r := new_node(p, TSType); r^ = fn
			return parse_ts_postfix(p, r, start)
		}

		// Parenthesized type: `(T)`. Note we deliberately DO NOT consume
		// a trailing `=>` here as if it made the whole `(T) => U` a function
		// type. TS function-type syntax requires NAMED parameters
		// (`(x: T) => U`); the named-params branch is handled above by
		// looks_like_ts_function_type. A bare `(T) => U` is therefore not a
		// type production at this position - the `=>` belongs to an outer
		// arrow expression whose return type is `(T)`. Test: TS
		// `parseArrowFunctionWithFunctionReturnType.ts` (`<T>(): (() => T) =>
		// null as any` - the outer `=>` belongs to the arrow function, the
		// inner `() => T` is the parenthesized return type).
		eat(p)
		// Inside parentheses, conditional types are re-allowed (matching
		// TypeScript's allowConditionalTypesAnd). This is critical for
		// `(infer U extends number ? 1 : 0)` where the `?` should parse
		// as a conditional type, not terminate the infer constraint.
		saved_disallow := p.ts_disallow_conditional_types
		p.ts_disallow_conditional_types = 0
		inner := parse_ts_type(p)
		p.ts_disallow_conditional_types = saved_disallow
		expect_token(p, .RParen)
		pn := new_node(p, TSParenthesizedType); pn.loc = start; pn.type_annotation = inner; pn.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = pn; return parse_ts_postfix(p, r, start)
	case .LBrace:
		// TS object type literal `{ ... }`. Must thread through parse_ts_postfix
		// so trailing `[]` (TSArrayType) and `[K]` (TSIndexedAccessType) attach
		// correctly. Pre-fix: `var t: { x: string }[] = []` reported "Expected
		// '=', ',', or ';' after variable binding" at the `[` because the
		// type ended at the `}` and the parser tried to parse `[]` as the
		// initializer of a different declarator. Closes 177 OXC corpus rejects
		// in the cluster of that exact error message (S26 W6 phase 3 bug class
		// #5).
		return parse_ts_postfix(p, parse_ts_type_object(p), start)
	case .LBracket:
		// TS tuple type, with support for variadic and optional/named elements:
		//   plain      `[T, U]`
		//   variadic   `[A, ...B[]]`,  `[...A, B]`,  `[...Elements, "abc"]`
		//   optional   `[T?, U]`  (TSOptionalType, postfix on the element)
		//   named      `[a: string, b?: number]`  (TSNamedTupleMember)
		// Closes ~30 OXC corpus rejects in the "Expected ], got ..." cluster
		// (S26 W6 phase 3 bug class #19). Pre-fix the inner loop called
		// parse_ts_type directly which doesn't recognise the leading `...` or
		// the `name:` / `name?:` named-element prefix.
		eat(p) // consume `[`
		// Re-allow conditional types inside brackets (tuple elements).
		saved_disallow_ct := p.ts_disallow_conditional_types
		p.ts_disallow_conditional_types = 0
		// Suppress JSDoc nullable `?` consumption in parse_ts_postfix
		// so that postfix `?` on tuple elements produces TSOptionalType.
		saved_in_tuple := p.ts_in_tuple_type
		p.ts_in_tuple_type = true
		types := make([dynamic]^TSType, 0, 4, p.allocator)
		optional_seen := false
		for !is_token(p, .RBracket) && !is_token(p, .EOF) {
			// Reject empty tuple element positions: `[number,,]`.
			if is_token(p, .Comma) {
				report_error(p, "Expected tuple element type, got ','")
				eat(p)
				continue
			}
			elem_start := cur_loc(p)
			elev: ^TSType
			if is_token(p, .Dot3) {
				eat(p) // consume `...`
				// Labeled rest tuple element `...name: T[]`. Detect via
				// 1-token lookahead - a label is an Identifier whose next
				// token is `:`. Wrap the resulting TSRestType inside a
				// TSNamedTupleMember to match OXC's ESTree shape (see
				// namedTupleMembers.ts WithOptAndRest / RecusiveRest).
				if p.cur_type == .Identifier && p.lexer.nxt.kind == .Colon {
					rest_label_tok := get_current(p)
					eat(p) // consume label
					eat(p) // consume `:`
					rest_inner := parse_ts_type(p)
					rest := new_node(p, TSRestType)
					rest.loc = elem_start
					rest.type_annotation = rest_inner
					rest.loc.span.end = prev_end_offset(p)
					rest_t := new_node(p, TSType); rest_t^ = rest
					named_rest := new_node(p, TSNamedTupleMember)
					named_rest.loc = elem_start
					named_rest.label = BindingIdentifier{
						loc = loc_from_token(&rest_label_tok),
						name = rest_label_tok.value,
					}
					named_rest.element_type = rest_t
					named_rest.optional = false
					named_rest.loc.span.end = prev_end_offset(p)
					elev = new_node(p, TSType); elev^ = named_rest
				} else {
					inner := parse_ts_type(p)
					rest := new_node(p, TSRestType)
					rest.loc = elem_start
					rest.type_annotation = inner
					rest.loc.span.end = prev_end_offset(p)
					elev = new_node(p, TSType); elev^ = rest
				}
			} else {
				// Named tuple element `name: T` or `name?: T` - detected
				// via 1-2 token lookahead. TS allows keywords as tuple
				// labels: `[function: T, string: U, void?: V]`. Accept
				// any identifier-like or keyword token that's followed by
				// `:` or `?:`.
				named := false
				if p.cur_type == .Identifier || is_keyword_usable_as_property_name(p.cur_type) {
					nxt := p.lexer.nxt.kind
					if nxt == .Colon { named = true }
					if nxt == .Question {
						snap := lexer_snapshot(p)
						eat(p) // ident
						eat(p) // ?
						if p.cur_type == .Colon { named = true }
						lexer_restore(p, snap)
					}
				}
				if named {
					label_tok := get_current(p)
					eat(p) // consume label identifier
					optional := false
					if is_token(p, .Question) { optional = true; eat(p) }
					expect_token(p, .Colon)
					inner := parse_ts_type(p)
					if inner != nil {
						if _, is_opt_type := inner^.(^TSOptionalType); is_opt_type {
							report_error(p, "A labeled tuple element cannot use postfix optional type syntax")
						}
					}
					if optional {
						optional_seen = true
					} else if optional_seen {
						report_error(p, "A required tuple element cannot follow an optional element")
					}
					named_member := new_node(p, TSNamedTupleMember)
					named_member.loc = elem_start
					named_member.label = BindingIdentifier{loc = loc_from_token(&label_tok), name = label_tok.value}
					named_member.element_type = inner
					named_member.optional = optional
					named_member.loc.span.end = prev_end_offset(p)
					elev = new_node(p, TSType); elev^ = named_member
				} else {
					elev = parse_ts_type(p)
					// Postfix `?` on a tuple element - TSOptionalType.
					if elev != nil && is_token(p, .Question) {
						eat(p)
						opt := new_node(p, TSOptionalType)
						opt.loc = elem_start
						opt.type_annotation = elev
						opt.loc.span.end = prev_end_offset(p)
						elev = new_node(p, TSType); elev^ = opt
						optional_seen = true
					} else if optional_seen {
						report_error(p, "A required tuple element cannot follow an optional element")
					}
				}
			}
			if elev != nil { bump_append(&types, elev) }
			if !match_token(p, .Comma) { break }
		}
		expect_token(p, .RBracket)
		p.ts_disallow_conditional_types = saved_disallow_ct
		p.ts_in_tuple_type = saved_in_tuple
		tup := new_node(p, TSTupleType); tup.loc = start; tup.element_types = types; tup.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = tup
		// Same chain as the LBrace branch above - `[T, U][]` (array of tuples)
		// and `[T, U][N]` (indexed access into a tuple) need parse_ts_postfix.
		return parse_ts_postfix(p, r, start)
	case .Void:   return parse_ts_kw(p, TSVoidKeyword, start)
	case .Null:   return parse_ts_kw(p, TSNullKeyword, start)
	case .This:   return parse_ts_kw(p, TSThisType, start)
	case .Never:  return parse_ts_kw(p, TSNeverKeyword, start)
	case .Const:
		// TS const assertion target: `expr as const`. `const` is a JS
		// reserved keyword (lexed as .Const), not a real type, but TS-ESTree
		// models the assertion's type as TSTypeReference whose typeName is
		// Identifier("const"). Pre-fix the parser fell through to
		// parse_ts_type_reference's `cur := get_current(p); id.name = cur.value`
		// which expects an Identifier kind - .Const failed and the as-arm
		// reported "Expected semicolon" / "Expected binding pattern". Closes
		// 50+ OXC corpus rejects in the "Expected semicolon" cluster (S26 W6
		// phase 3 bug class #13).
		cur_const := get_current(p)
		id := new_node(p, Identifier); id.loc = loc_from_token(&cur_const); id.name = "const"
		eat(p)
		ref := new_node(p, TSTypeReference); ref.loc = start
		ref.type_name = expression_from(p, id)
		ref.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = ref
		return parse_ts_postfix(p, r, start)
	case .Typeof:
		// TS type-query: `typeof X` / `typeof X.Y.Z` / `typeof X<TArgs>`
		// (the type-arguments form is TS 4.7+, used to instantiate generic
		// type-of references). Pre S26 W6 phase 3 #34 the branch called
		// parse_left_hand_side_expr which read `<` as the start of a JS
		// less-than comparison, breaking files like
		//   var v: typeof A<B>;
		// (parserTypeQuery8.ts) and the babel
		//   typescript/types/typeof-type-parameters/input.ts
		// fixture. Parse a dotted Identifier chain ourselves and
		// optionally consume a TS type-arguments list after.
		eat(p) // consume `typeof`
		tq_expr: ^Expression
		// `typeof import("...")` form must short-circuit BEFORE the
		// identifier / property-name fall-through, because `.Import` is
		// also in is_keyword_usable_as_property_name's whitelist (so an
		// `obj.import` member access works in expression position).
		if is_token(p, .Import) {
			imp_ts := parse_ts_primary_type(p)
			if imp_ts != nil {
				#partial switch v in imp_ts^ {
				case ^TSImportType:
					if v != nil { v.is_typeof = true }
				}
			}
			return imp_ts
		}
		// Allow keyword identifiers (Identifier / kw-as-name / Await / Yield).
		if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) ||
		   is_token(p, .Await) || is_token(p, .Yield) {
			tq_cur := get_current(p)
			tq_id := new_node(p, Identifier); tq_id.loc = loc_from_token(&tq_cur); tq_id.name = tq_cur.value
			eat(p)
			tq_expr = expression_from(p, tq_id)
			for is_token(p, .Dot) {
				eat(p)
				// `typeof A.` (trailing dot without property) is a
				// SyntaxError. Check that an identifier follows.
				if !is_token(p, .Identifier) && !is_keyword_usable_as_property_name(p.cur_type) {
					report_error(p, "Expected property name after '.'")
					break
				}
				tq_prop := parse_identifier_name(p)
				tq_mem := new_node(p, MemberExpression); tq_mem.loc = start; tq_mem.object = tq_expr
				tq_pid := new_node(p, Identifier); tq_pid.loc = tq_prop.loc; tq_pid.name = tq_prop.name
				tq_mem.property = expression_from(p, tq_pid); tq_mem.computed = false; tq_mem.optional = false
				tq_mem.loc.span.end = prev_end_offset(p)
				tq_expr = expression_from(p, tq_mem)
			}
		} else {
			// Fallback - keep the legacy expression-style parse so any
			// shape we don't handle here still produces a node.
			tq_expr = parse_left_hand_side_expr(p)
		}
		node := new_node(p, TSTypeQuery); node.loc = start; node.expr_name = tq_expr
		if is_open_angle_or_lshift(p) {
			node.type_parameters = parse_ts_type_arguments(p)
		}
		node.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = node; return parse_ts_postfix(p, r, start)
	case .Keyof:
		eat(p); operand := parse_ts_primary_type(p)
		node := new_node(p, TSTypeOperator); node.loc = start; node.operator = "keyof"; node.type_annotation = operand
		node.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = node; return r
	case .Unique:
		// `unique <type>`. The TS spec only defines `unique symbol`, but
		// OXC/Babel parse `unique <any-type>` syntactically and defer the
		// restriction to the type checker. Match that: accept `unique` as
		// a type operator whenever the next token can start a type (symbol,
		// number, object, etc.). Falls through to TypeReference for the
		// rare case of `unique` used as a plain identifier.
		nxt_kind := p.lexer.nxt.kind
		if nxt_kind == .Identifier || nxt_kind == .LParen || nxt_kind == .LBrace ||
		   nxt_kind == .LBracket || nxt_kind == .Typeof || nxt_kind == .Keyof ||
		   nxt_kind == .Unique || nxt_kind == .Infer || nxt_kind == .Import ||
		   nxt_kind == .Void || nxt_kind == .True || nxt_kind == .False ||
		   nxt_kind == .Null || nxt_kind == .This || nxt_kind == .Never ||
		   nxt_kind == .String || nxt_kind == .Number || nxt_kind == .BigInt ||
		   nxt_kind == .Readonly || nxt_kind == .Abstract || nxt_kind == .Asserts ||
		   nxt_kind == .New {
			eat(p) // consume `unique`
			operand := parse_ts_primary_type(p)
			node := new_node(p, TSTypeOperator); node.loc = start
			node.operator = "unique"; node.type_annotation = operand
			node.loc.span.end = prev_end_offset(p)
			r := new_node(p, TSType); r^ = node
			return parse_ts_postfix(p, r, start)
		}

	case .Infer:
		eat(p); pn := parse_identifier(p)
		node := new_node(p, TSInferType); node.loc = start
		node.type_parameter.name = BindingIdentifier{loc = pn.loc, name = pn.name}
		node.type_parameter.loc = pn.loc // span of the bare `V` - OXC shape
		// TS 4.7+ constrained infer: `infer A extends B`. The `extends`
		// here is the constraint on the inferred type parameter, NOT the
		// outer conditional's extends. Ambiguity: `infer U extends C ?`
		// could be a constrained infer followed by `?` (conditional type)
		// or just `infer U` with `extends C ? T : F` as a conditional.
		// Resolution (matches OXC / TypeScript 4.7+):
		//   - If already in a disallow-conditional-types context, the
		//     `extends` is always the constraint (no ambiguity).
		//   - Otherwise, speculatively parse the constraint with
		//     conditional types disabled. If `?` follows, backtrack:
		//     the `extends` belongs to the outer conditional, not infer.
		if is_token(p, .Extends) {
			if p.ts_disallow_conditional_types > 0 {
				// Already in a no-conditional context → constraint is unambiguous.
				eat(p)
				p.ts_disallow_conditional_types += 1
				constraint_type := parse_ts_type(p)
				p.ts_disallow_conditional_types -= 1
				node.type_parameter.constraint = constraint_type
			} else {
				// Speculative parse: snapshot, parse constraint with
				// conditional types disabled, then check for `?`.
				snap := lexer_snapshot(p)
				eat(p) // consume `extends`
				p.ts_disallow_conditional_types += 1
				constraint_type := parse_ts_type(p)
				p.ts_disallow_conditional_types -= 1
				if is_token(p, .Question) {
					// `?` follows → backtrack. The `extends` belongs
					// to the outer conditional type, not the infer
					// constraint. Rewind and leave `infer U` bare.
					// Note: we do NOT reclaim bump-pool memory because
					// nodes allocated during the trial may be pointed at
					// by other live structures; the arena reclaims them
					// at parse-file teardown.
					lexer_restore(p, snap)
				} else {
					// No `?` → constraint is real.
					node.type_parameter.constraint = constraint_type
				}
			}
		}
		node.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = node; return r
	case .Minus, .Plus:
		// TS prefixed numeric / bigint literal type: `let y: -1 = -1;`,
		// `let z: -1n = -1n`. ESTree shape: TSLiteralType whose literal is
		// a UnaryExpression(operator="-", argument=Literal). Only `-` and
		// `+` qualify, and only on a numeric or bigint literal. Anything
		// else (e.g. `-x`, `-(1)`) is a parse error in TS type position.
		op_tok := get_current(p)
		op_kind: UnaryOperator = op_tok.type == .Minus ? .Minus : .Plus
		eat(p) // consume `-` / `+`
		if p.cur_type != .Number && p.cur_type != .BigInt {
			report_error(p, "Expected numeric or bigint literal after unary operator in type")
			return nil
		}
		lit_start := cur_loc(p)
		lit_expr: ^Expression
		if p.cur_type == .Number {
			cur := get_current(p); nl := new_node(p, NumericLiteral); nl.loc = loc_from_token(&cur); nl.raw = cur.value
			if v, ok := cur.literal.(f64); ok { nl.value = v }
			eat(p)
			lit_expr = expression_from(p, nl)
		} else {
			cur := get_current(p); bl := new_node(p, BigIntLiteral); bl.loc = loc_from_token(&cur); bl.raw = cur.value
			if v, ok := cur.literal.(string); ok { bl.value = v }
			eat(p)
			lit_expr = expression_from(p, bl)
		}
		unary := new_node(p, UnaryExpression)
		unary.loc = start
		unary.operator = op_kind
		unary.argument = lit_expr
		unary.prefix = true
		unary.loc.span.end = prev_end_offset(p)
		_ = lit_start
		node := new_node(p, TSLiteralType); node.loc = start
		node.literal = expression_from(p, unary)
		node.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = node
		return parse_ts_postfix(p, r, start)
	case .Template:
		// TS no-substitution template-literal type: `const x: `foo` = "foo"`.
		// Shape: TSLiteralType whose literal is a TemplateLiteral with one
		// quasi and zero expressions. Reuse parse_template_literal so the
		// `cooked` decode and §12.9.6 escape validation match the JS
		// expression-position template handling exactly.
		lit := parse_template_literal(p, false)
		node := new_node(p, TSLiteralType); node.loc = start; node.literal = lit
		node.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = node
		return parse_ts_postfix(p, r, start)
	case .TemplateHead:
		// TS template-literal type with substitutions: `\`a${T}b\``. Each
		// `${...}` slot holds a TYPE, not an expression - so we can't reuse
		// parse_template_literal (which calls parse_assignment_expression).
		// Build TSTemplateLiteralType directly: alternating quasis and types.
		return parse_ts_template_literal_type(p, start)
	case .String, .Number, .BigInt, .True, .False:
		// TS literal-type postfix chain: `"abc"[]`, `1[]`, `42n[]`, `true[]`,
		// `1[][]`, `1 | 1[]`, etc. Pre-fix all four literal-type cases
		// returned `r` directly without going through parse_ts_postfix, so
		// `T = 1[]` reported "Expected '=', ',', or ';' after variable binding"
		// at the `[` (the parser ended the type at the literal and tried to
		// parse `[]` as a different declarator's initializer). Mirrors the
		// same parse_ts_postfix wrapping used by .LBrace / .LBracket / kw
		// cases above. Closes ~30 OXC corpus rejects in the "Expected '=',
		// ',', or ';' after variable binding" cluster (S26 W6 phase 3 bug
		// class #16). One return path covers all four literal kinds; the
		// inner switch only differs in the literal-node construction.
		lit_expr: ^Expression
		#partial switch p.cur_type {
		case .String:
			lit := parse_string_literal(p); le := new_node(p, StringLiteral); le^ = lit
			lit_expr = expression_from(p, le)
		case .Number:
			cur := get_current(p); nl := new_node(p, NumericLiteral); nl.loc = loc_from_token(&cur); nl.raw = cur.value
			if v, ok := cur.literal.(f64); ok { nl.value = v }
			eat(p)
			lit_expr = expression_from(p, nl)
		case .BigInt:
			// BigInt literal type: `const y: 12n = 12n`. (S26 W6 phase 3 #11.)
			cur := get_current(p); bl := new_node(p, BigIntLiteral); bl.loc = loc_from_token(&cur); bl.raw = cur.value
			if v, ok := cur.literal.(string); ok { bl.value = v }
			eat(p)
			lit_expr = expression_from(p, bl)
		case .True, .False:
			val := p.cur_type == .True; eat(p)
			bl := new_node(p, BooleanLiteral); bl.loc = start; bl.value = val
			lit_expr = expression_from(p, bl)
		}
		node := new_node(p, TSLiteralType); node.loc = start; node.literal = lit_expr; node.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = node
		return parse_ts_postfix(p, r, start)
	case .Import:
		// TS import type: `import("module").Member<TArgs>`
		// Grammar (TS 4.6+):
		//   ImportType: typeof? import ( StringLiteral ImportTypeAttributes? )
		//                 ( . QualifiedName )? TypeArguments?
		// Used to reference types from other modules without a top-level
		// `import` statement - the canonical form in `.d.ts` libraries
		// (oxc-parser/src-js/index.d.ts: `get program(): import("@oxc-
		// project/types").Program`).
		eat(p) // consume `import`
		if !expect_token(p, .LParen) { return nil }
		arg_type := parse_ts_type(p)
		// The argument must be a string literal type.  `import(foo)` with
		// a non-string argument is a SyntaxError.
		if arg_type != nil {
			if _, is_lit := arg_type^.(^TSLiteralType); !is_lit {
				report_error(p, "String literal expected in import type")
			}
		}
		// `with { ... }` import-type attributes - stage-3 since TS 5.3.
		// Eat permissively without strict shape validation; the type
		// checker handles semantics.
		if is_token(p, .Comma) {
			eat(p)
			// After the comma, `{` must follow (import-type attributes).
			// `import("foo", )` with trailing comma is a SyntaxError.
			if is_token(p, .RParen) {
				report_error(p, "Expected '{' after ',' in import type options")
			}
			// Parse import-type options object: `{ with: { key: "value" } }`.
			// Validate structural constraints that OXC/TSC enforce:
			//   - The key must be the bare identifier `with` (no escapes,
			//     not a string literal, not computed).
			//   - Inner attribute keys must be plain identifiers or string
			//     literals (no computed properties).
			//   - No spread elements in the inner object.
			if is_token(p, .LBrace) {
				eat(p) // consume outer {
				// Validate the `with` key.
				if is_token(p, .With) {
					// Good: bare `with` keyword.
				} else if is_token(p, .Identifier) && p.cur_tok.value == "with" {
					// `w\u0069th` — escaped form of `with`.
					if p.cur_tok.has_escape {
						report_error(p, "Expected 'with' in import type options")
					}
				} else if is_token(p, .String) {
					// `"with"` as string literal key.
					report_error(p, "Expected 'with' in import type options")
				}
				eat(p) // consume key (with / identifier / string)
				if is_token(p, .Colon) { eat(p) } // consume :
				// Inner value: `{ type: "json" }`. Validate contents.
				if is_token(p, .LBrace) {
					eat(p) // consume inner {
					for !is_token(p, .RBrace) && !is_token(p, .EOF) {
						if is_token(p, .Dot3) {
							report_error(p, "Spread elements are not allowed in import type options")
						}
						if is_token(p, .LBracket) {
							report_error(p, "Import attributes keys must be identifier or string literal")
						}
						// Skip tokens until comma or closing brace.
						inner_depth := 0
						for !is_token(p, .EOF) {
							if is_token(p, .LBrace) || is_token(p, .LBracket) { inner_depth += 1 }
							else if is_token(p, .RBrace) || is_token(p, .RBracket) {
								if inner_depth == 0 { break }
								inner_depth -= 1
							}
							else if is_token(p, .Comma) && inner_depth == 0 {
								eat(p) // consume comma
								break
							}
							eat(p)
						}
					}
					if is_token(p, .RBrace) { eat(p) } // consume inner }
				} else {
					// Non-object value — skip balanced.
					depth := 0
					for !is_token(p, .EOF) {
						if is_token(p, .LBrace) { depth += 1 }
						else if is_token(p, .RBrace) {
							if depth == 0 { break }
							depth -= 1
						}
						eat(p)
					}
				}
				// Trailing comma before outer `}`.
				match_token(p, .Comma)
				if is_token(p, .RBrace) { eat(p) } // consume outer }
			}
		}
		if !expect_token(p, .RParen) { return nil }
		it := new_node(p, TSImportType)
		it.loc = start
		it.argument = arg_type
		it.is_typeof = false
		// Optional `.QualifiedName` (one or more `.`-separated identifiers).
		if is_token(p, .Dot) {
			eat(p)
			qual_id := parse_identifier(p)
			id_node := new_node(p, Identifier)
			id_node^ = qual_id
			cur_qual := expression_from(p, id_node)
			for is_token(p, .Dot) {
				eat(p)
				prop_id := parse_identifier(p)
				prop_node := new_node(p, Identifier)
				prop_node^ = prop_id
				mem := new_node(p, MemberExpression)
				mem.loc = it.loc
				mem.object = cur_qual
				mem.property = expression_from(p, prop_node)
				mem.computed = false
				mem.optional = false
				mem.loc.span.end = prev_end_offset(p)
				cur_qual = expression_from(p, mem)
			}
			it.qualifier = cur_qual
		}
		// Optional `<TArgs>` type arguments.
		if is_open_angle_or_lshift(p) {
			targs := parse_ts_type_arguments(p)
			if targs != nil {
				it.type_parameters = targs
			}
		}
		it.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = it
		return parse_ts_postfix(p, r, start)
	case .Identifier: return parse_ts_identifier_type(p)
	case .Await, .Yield,
	     .Abstract, .Declare, .Override, .Readonly,
	     .Static, .Get, .Set, .Async, .Let, .Of, .From, .As,
	     .Constructor, .Accessor, .Module, .Namespace,
	     .Implements, .Require, .Package, .Private, .Protected, .Public,
	     .Target, .Using, .Assert, .Asserts, .Satisfies:
		// In TS type position, contextually-reserved keywords are
		// allowed as plain TypeReference names:
		//   type abstract = "abstract"; let x: abstract;
		//   var v: await;  var v: yield;  var v: static;
		// Catches every keyword token that can_be_binding_identifier
		// or is_keyword_usable_as_property_name accepts, except those
		// with dedicated type-level semantics (.Void, .Null, .This,
		// .Typeof, .Keyof, .Unique, .Infer, .Import, .New, .Never).
		return parse_ts_type_reference(p)
	case .Question:
		// TS / Flow nullable prefix: `?string`. OXC accepts this
		// permissively, parsing the inner type and ignoring the `?`.
		if allow_ts_mode(p) {
			eat(p) // consume `?`
			return parse_ts_primary_type(p)
		}
		return nil
	case .Not:
		// JSDoc non-nullable prefix: `!string`. OXC produces
		// TSJSDocNonNullableType. Accept permissively.
		if allow_ts_mode(p) {
			eat(p) // consume `!`
			return parse_ts_primary_type(p)
		}
		return nil
	case .Break, .Continue, .Return, .If, .Else, .For, .While, .Do,
	     .Switch, .Case, .Default, .Throw, .Try, .Catch, .Finally,
	     .With, .Debugger, .Delete, .In, .Instanceof, .Var,
	     .Class, .Function, .Extends, .Super, .Enum, .Export:
		// Hard-reserved JS keywords. OXC accepts them in type position
		// permissively (e.g. `x: break`). The semantic checker owns the
		// error; the parser just builds a TSTypeReference.
		if allow_ts_mode(p) {
			return parse_ts_type_reference(p)
		}
		return nil
	}
	return nil
}

parse_ts_identifier_type :: proc(p: ^Parser) -> ^TSType {
	start := cur_loc(p)
	value := get_current(p).value
	// Built-in keyword names like `string` / `number` / `any` are
	// pre-empted by a TSTypeReference whenever they form a qualified-name
	// chain. TS allows shadowing primitives with namespace declarations:
	//
	//   declare namespace string { interface X { } }
	//   var x: string.X;          // TypeReference, not TSStringKeyword
	//
	// Without this opt-out the keyword arm below short-circuits the
	// chain and the `.X` cascade ends up unconsumed, surfacing as
	// "Expected '=', ',', or ';' after variable binding". Closes a
	// handful of files in that cluster (parserModuleDeclaration11.ts,
	// uniqueSymbolsErrors.ts).
	if p.lexer.nxt.kind == .Dot {
		return parse_ts_type_reference(p)
	}
	switch value {
	case "any":       return parse_ts_kw(p, TSAnyKeyword, start)
	case "number":    return parse_ts_kw(p, TSNumberKeyword, start)
	case "string":    return parse_ts_kw(p, TSStringKeyword, start)
	case "boolean":   return parse_ts_kw(p, TSBooleanKeyword, start)
	case "bigint":    return parse_ts_kw(p, TSBigIntKeyword, start)
	case "symbol":    return parse_ts_kw(p, TSSymbolKeyword, start)
	case "object":    return parse_ts_kw(p, TSObjectKeyword, start)
	case "unknown":   return parse_ts_kw(p, TSUnknownKeyword, start)
	case "undefined": return parse_ts_kw(p, TSUndefinedKeyword, start)
	case "never":     return parse_ts_kw(p, TSNeverKeyword, start)
	case "intrinsic":
		// `intrinsic` is a TS keyword type. Parse it, then check for
		// disallowed postfix operators. `intrinsic["foo"]` is not valid.
		eat(p)
		node := new_node(p, TSIntrinsicKeyword); node.loc = start
		node.loc.span.end = prev_end_offset(p)
		result := new_node(p, TSType); result^ = node
		// Reject indexed access on intrinsic keyword.
		if is_token(p, .LBracket) {
			report_error(p, "Indexed access is not allowed on 'intrinsic' keyword type")
		}
		return parse_ts_postfix(p, result, start)
	case "readonly":
		// TS type operator on tuple / array: `readonly T[]`,
		// `readonly [A, B, C]`, `readonly unknown[]`, `readonly Foo[]`,
		// `readonly (string | number)[]`. The lexer emits .Identifier
		// for "readonly" (contextual keyword, not reserved), so the
		// dispatch happens here, not via a dedicated `.Readonly` case in
		// parse_ts_primary_type.
		//
		// Treat as a type operator when the NEXT token can start a type.
		// That set covers: LBracket (tuple), LParen (paren type / fn type),
		// Identifier (TypeReference / built-in keyword like `unknown`), and
		// the keyword tokens that begin a type (.This, .Void, .Null,
		// .Never, .Typeof, .Keyof, .Unique, .Infer, .Import, .True,
		// .False, .String, .Number). Bare `readonly` standing alone (very
		// rare - `Foo.readonly` IdentifierName) falls through to
		// TypeReference.
		#partial switch p.lexer.nxt.kind {
		case .LBracket, .LParen, .Identifier, .This, .Void, .Null,
		     .Never, .Typeof, .Keyof, .Unique, .Infer, .Import,
		     .True, .False, .String, .Number, .LBrace:
			eat(p)
			operand := parse_ts_primary_type(p)
			// Apply postfix (T[]) BEFORE wrapping in readonly, so
			// `readonly string[]` is readonly(string[]) not
			// (readonly string)[].
			operand = parse_ts_postfix(p, operand, start)
			// Validate: `readonly` is only legal on array types
			// (`T[]`) and tuple literal types (`[T, U]`).
			if operand != nil {
				_, is_arr := operand^.(^TSArrayType)
				_, is_tup := operand^.(^TSTupleType)
				if !is_arr && !is_tup {
					report_error(p, "'readonly' type modifier is only permitted on array and tuple literal types")
				}
			}
			node := new_node(p, TSTypeOperator); node.loc = start
			node.operator = "readonly"; node.type_annotation = operand
			node.loc.span.end = prev_end_offset(p)
			r := new_node(p, TSType); r^ = node
			return r
		}
	}
	return parse_ts_type_reference(p)
}

parse_ts_postfix :: proc(p: ^Parser, base: ^TSType, start: Loc) -> ^TSType {
	result := base
	for is_token(p, .LBracket) {
		// ASI-style guard: if the `[` is on a new line AND the contents
		// look like an index signature (`[Ident :` ...), this `[` is not
		// a postfix on the current type - it's the start of the next
		// interface / type-literal member. Without this guard, code like
		//
		//   interface I {
		//     thisIsNotATag(x: string): void
		//     [x: number]: I;
		//   }
		//
		// has `void` greedily extended to `void[x: number]` (TSIndexedAccessType)
		// and the index signature is consumed mid-type, then everything
		// downstream cascades. Closes most of the
		// taggedTemplateStringsWithTypedTags / indexer2A /
		// noPropertyAccessFromIndexSignature1 cluster.
		if p.cur_tok.had_line_terminator {
			nxt_kind := p.lexer.nxt.kind
			// `T\n[]` — empty brackets on new line = new member, not array postfix.
			if nxt_kind == .RBracket {
				break
			}
			// `T\n[<T>` — generic on new line = new member start (call/construct sig).
			if nxt_kind == .LAngle {
				break
			}
			if nxt_kind == .Identifier || nxt_kind == .String || nxt_kind == .Number {
				snap := lexer_snapshot(p)
				eat(p) // `[`
				eat(p) // identifier / string / number
				after := p.cur_type
				lexer_restore(p, snap)
				// `[Ident :` → index signature, not postfix.
				// `[Ident ]` → computed class/interface member.
				// `["str" ]` → computed method overload.
				if after == .Colon || after == .RBracket {
					break
				}
			}
		}
		if is_next_token(p, .RBracket) {
			// Array type: `T[]`.
			eat(p); eat(p)
			arr := new_node(p, TSArrayType); arr.loc = start; arr.element_type = result; arr.loc.span.end = prev_end_offset(p)
			result = new_node(p, TSType); result^ = arr
		} else {
			// Indexed access type: `T[K]`.
			eat(p) // consume `[`
			index := parse_ts_type(p)
			expect_token(p, .RBracket)
			iat := new_node(p, TSIndexedAccessType); iat.loc = start
			iat.object_type = result; iat.index_type = index
			iat.loc.span.end = prev_end_offset(p)
			result = new_node(p, TSType); result^ = iat
		}
	}
	// TS / JSDoc non-nullable postfix: `T!`. OXC produces
	// TSJSDocNonNullableType. Accept permissively - just consume the `!`
	// and return the inner type. Same-line only (ASI guard).
	if is_token(p, .Not) && !p.cur_tok.had_line_terminator {
		eat(p) // consume `!`
	}
	// TS / JSDoc nullable postfix: `T?`. OXC produces
	// TSJSDocNullableType. Accept permissively. Only consume when `?`
	// is NOT followed by `:` or another type-continuation (to avoid
	// eating the `?` of a conditional type or an optional param `?:`).
	// EXCEPTION: inside a tuple type, the postfix `?` is reserved for
	// TSOptionalType syntax (`[T?, U]`), not JSDoc nullable. The tuple
	// parser handles it after parse_ts_type returns.
	if is_token(p, .Question) && !p.cur_tok.had_line_terminator && !p.ts_in_tuple_type {
		nxt := p.lexer.nxt.kind
		if nxt == .RParen || nxt == .Comma || nxt == .Semi || nxt == .RBrace ||
		   nxt == .RBracket || nxt == .RAngle || nxt == .Assign || nxt == .EOF {
			eat(p) // consume `?`
		}
	}
	return result
}

parse_ts_type_reference :: proc(p: ^Parser) -> ^TSType {
	start := cur_loc(p)
	cur := get_current(p)
	id := new_node(p, Identifier); id.loc = loc_from_token(&cur); id.name = cur.value; eat(p)
	id_expr := expression_from(p, id)
	for is_token(p, .Dot) {
		eat(p); prop := parse_identifier_name(p)
		mem := new_node(p, MemberExpression); mem.loc = start; mem.object = id_expr
		pid := new_node(p, Identifier); pid.loc = prop.loc; pid.name = prop.name
		mem.property = expression_from(p, pid); mem.loc.span.end = prev_end_offset(p)
		id_expr = expression_from(p, mem)
	}
	targs: Maybe(^TSTypeParameterInstantiation)
	if is_open_angle_or_lshift(p) {
		// When `<` sits on a new line, speculatively try type arguments.
		// If the parse produces errors, roll back - the `<` likely starts
		// a new generic call signature in an overloaded object/interface
		// type (e.g. `T\n<U extends V>(...): W`).  Same-line `<` commits
		// unconditionally - `Map<string, number>` must never roll back.
		// Inside a type literal body (`{ A: B\n<T>; }`), a newline-
		// separated `<` is ALWAYS a new member start (OXC/V8 agree).
		if p.cur_tok.had_line_terminator && p.ts_in_type_literal > 0 {
			// Don't try type args at all — it's a new member.
		} else if p.cur_tok.had_line_terminator {
			snap := lexer_snapshot(p)
			snap_errs := len(p.errors)
			targs = parse_ts_type_arguments(p)
			if len(p.errors) > snap_errs {
				lexer_restore(p, snap)
				resize(&p.errors, snap_errs)
				targs = nil
			}
		} else {
			targs = parse_ts_type_arguments(p)
		}
	}
	ref := new_node(p, TSTypeReference); ref.loc = start; ref.type_name = id_expr; ref.type_parameters = targs
	ref.loc.span.end = prev_end_offset(p)
	r := new_node(p, TSType); r^ = ref
	return parse_ts_postfix(p, r, start)
}

// is_open_angle_or_lshift returns true when the current token is `<`
// or `<<` (which can be split into two `<`s for nested type arguments).
is_open_angle_or_lshift :: #force_inline proc(p: ^Parser) -> bool {
	return p.cur_type == .LAngle || p.cur_type == .LShift
}

// ensure_open_angle splits `<<` into `<` + `<` if needed, then syncs
// the parser's cur_type mirror. No-op when already at `<`.
ensure_open_angle :: proc(p: ^Parser) {
	if p.cur_type == .LShift || p.cur_type == .AssignLShift {
		if try_split_open_angle(p.lexer) {
			p.cur_type = .LAngle
		}
	}
}

parse_ts_type_arguments :: proc(p: ^Parser) -> ^TSTypeParameterInstantiation {
	ensure_open_angle(p)
	start := cur_loc(p); eat(p)
	empty_at_start := is_close_angle_token(p)
	// Re-allow conditional types inside angle brackets.
	saved_disallow_ct := p.ts_disallow_conditional_types
	p.ts_disallow_conditional_types = 0
	params := make([dynamic]^TSType, 0, 4, p.allocator)
	for !is_close_angle_token(p) && !is_token(p, .EOF) {
		// Reject empty type argument positions: `Foo<a,,b>` — the `,`
		// after `a` means a type must follow before the next `,` or `>`.
		if is_token(p, .Comma) {
			report_error(p, "Expected type argument, got ','")
			eat(p)
			continue
		}
		t := parse_ts_type(p); if t != nil { bump_append(&params, t) }; if !match_token(p, .Comma) { break }
	}
	if empty_at_start && len(params) == 0 {
		report_error(p, "Type argument list cannot be empty")
	}
	expect_close_angle(p)
	p.ts_disallow_conditional_types = saved_disallow_ct
	inst := new_node(p, TSTypeParameterInstantiation); inst.loc = start; inst.params = params; inst.loc.span.end = prev_end_offset(p)
	return inst
}

// Returns true iff the current token is RAngle OR a multi-`>` operator
// (RShift / URShift / GEq / AssignRShift / AssignURShift) whose leading
// `>` would close a TS type-argument list. Use as a loop-terminator
// predicate paired with expect_close_angle below.
is_close_angle_token :: #force_inline proc(p: ^Parser) -> bool {
	#partial switch p.cur_type {
	case .RAngle, .RShift, .URShift, .GEq, .AssignRShift, .AssignURShift:
		return true
	case:
		return false
	}
}

// Consume one closing `>` from the current token. If the current token
// is a multi-`>` operator (RShift, URShift, GEq, AssignRShift,
// AssignURShift), split it via try_split_close_angle so the leading `>`
// is consumed and the rest stays in the token stream for the next
// expression-level parser. Falls back to expect_token(.RAngle) when
// none of the above matches - this preserves the diagnostic for
// genuinely malformed code.
expect_close_angle :: proc(p: ^Parser) -> bool {
	#partial switch p.cur_type {
	case .RAngle:
		eat(p)
		return true
	case .RShift, .URShift, .GEq, .AssignRShift, .AssignURShift:
		if try_split_close_angle(p.lexer) {
			// After split, p.cur_type is RAngle. Sync the parser's mirror
			// of cur_type by consuming via eat (which calls advance_token
			// - reads the new fast cur into the parser's slow token).
			// First we need the parser to re-read the lexer's cur; eat(p)
			// advances PAST the current token, so we need to manually
			// resync. The cleanest path: drop into advance_token directly,
			// which copies l.cur into the parser's mirror and consumes one.
			// But l.cur is now RAngle, so we want to CONSUME it (advance to
			// the residual operator). One eat(p) does the job.
			p.cur_type = .RAngle
			eat(p)
			return true
		}
		return expect_token(p, .RAngle)
	case:
		return expect_token(p, .RAngle)
	}
}

// parse_ts_lt_expression handles `<` at expression start in TS / TSX mode.
// Two productions are possible here:
//
//   1. Type assertion:  `<Type>expr`                       → TSTypeAssertion
//   2. Generic arrow:   `<T[, U, ...]>(params) => body`    → ArrowFunctionExpression
//                                                              with .type_parameters set
//
// In pure `.ts` (no JSX), there's no ambiguity with a JSX opening tag - both
// productions are legal TS at expression position and nothing else starts
// with `<`. In `.tsx` (JSX enabled), this function is NOT reached because
// allow_jsx_mode(p) is true; TSX ambiguity is handled by JSX today and
// deferred to Phase C (trailing-comma rule for generic arrows).
//
// Discriminator (1-token lookahead after `<`):
//
//   * `<T ,`         → KNOWN generic arrow (multiple type params)
//   * `<T extends`   → KNOWN generic arrow (constrained type param)
//   * `<T =`         → KNOWN generic arrow (type param with default)
//   * `<string>`     → non-identifier type → assertion
//   * `<number>`     → non-identifier type → assertion
//   * `<T>`          → ambiguous (could be assertion on parenthesised
//                      expr OR generic arrow with single param). MVP
//                      heuristic: treat as assertion. The corner case
//                      `<T>(x) => x` with a single-char type param
//                      and identifier-only arg MISPARSES. Documented
//                      limitation; covered by Phase C proper trial-parse.
parse_ts_lt_expression :: proc(p: ^Parser) -> ^Expression {
	start := cur_loc(p)
	assert(p.cur_type == .LAngle)

	// Decision tree after `<`:
	//
	//   A. `<Identifier , ...`   → generic arrow, trial-parse it.
	//      `<Identifier extends` → generic arrow, trial-parse it.
	//      `<Identifier =`       → generic arrow, trial-parse it.
	//      `<Identifier >`       → AMBIGUOUS. Could be generic arrow
	//                              `<T>(x)=>x` or assertion `<T>(x+y)`.
	//                              Trial-parse as generic arrow; on
	//                              failure, restore and parse as assertion.
	//   B. `<Identifier <other>` → fall through to assertion (best effort).
	//   C. `<<non-identifier>`   → assertion (type params require an
	//                              identifier as the first token).
	//
	// Every trial-parse path uses lexer_snapshot/restore to undo state
	// and any errors introduced by the speculative parse. A genuine user
	// syntax error (e.g. "<T,>(x:T)=>x" where the arrow-param type
	// annotation hits a pre-existing parser gap) reports a SINGLE clean
	// error instead of cascading SIGSEGVs.
	nxt_kind := p.lexer.nxt.kind

	// TS type-parameter modifiers: `<const T>`, `<in T>`, `<out T>`.
	// These can only appear in generic-arrow position (not assertions).
	// `const` lexes as .Const keyword, `in` as .In. `out` is Identifier
	// but appears as a modifier only before another Identifier, so the
	// `<Identifier ...` path below catches `<out T>`.
	if nxt_kind == .Const || nxt_kind == .In {
		// `<const T>` / `<in T>` are type-parameter modifier syntax
		// for generic arrows. `<const>X` is also a TS 3.4-era "const
		// assertion" (TSTypeAssertion with `const` as the type name).
		// Try generic arrow first; on failure, fall through to the
		// assertion path so `<const>10` parses as TSTypeAssertion.
		snap := lexer_snapshot(p)
		result := parse_ts_generic_arrow(p, start)
		if result != nil && len(p.errors) == snap.errors_len {
			return result
		}
		lexer_restore(p, snap)
		// fall through to the assertion attempt below
	}

	if nxt_kind == .Identifier {
		snap := lexer_snapshot(p)
		eat(p)            // consume `<`
		eat(p)            // consume the identifier after `<`
		after := p.cur_type
		lexer_restore(p, snap)

		try_arrow := after == .Comma || after == .Extends || after == .Assign || after == .RAngle
		if try_arrow {
			snap2 := lexer_snapshot(p)
			result := parse_ts_generic_arrow(p, start)
			if result != nil && len(p.errors) == snap2.errors_len {
				return result
			}
			// Generic-arrow parse failed - roll back and, for the
			// ambiguous `<T>` case only, fall through to an assertion
			// attempt. For the KNOWN-arrow signals (`,`/`extends`/`=`)
			// nothing else is legal: emit one error and bail.
			lexer_restore(p, snap2)
			if after != .RAngle {
				report_error(p, "Malformed generic arrow function")
				return nil
			}
			// fall through to assertion for the ambiguous case
		}
	}

	// Assertion `<Type>expr`. Guarded fallback; reports errors via the
	// normal channel without ad-hoc panics.
	snap := lexer_snapshot(p)
	eat(p) // consume `<`
	type_ann := parse_ts_type(p)
	// `<>expr` — empty type assertion is not valid TS syntax.
	if type_ann == nil {
		lexer_restore(p, snap)
		report_error(p, "Unexpected token")
		return nil
	}
	if !expect_token(p, .RAngle) {
		lexer_restore(p, snap)
		report_error(p, "Unexpected '<': not a valid TS type assertion or generic arrow")
		return nil
	}
	// After the closing `>`, the assertion's expression starts. If the
	// next byte is `/` it's a regex literal (`<any>/re/g`), not
	// division. The lexer pre-fetched it in division context because the
	// previous token (`>`) sets can_start_regex=false; relex it as a
	// regex now that we know we're back in expression position. Test:
	// typescript/compiler/castExpressionParentheses.ts (`<any>/regexp/g`).
	if p.cur_type == .Div || p.cur_type == .AssignDiv {
		relex_as_regex(p.lexer)
		p.cur_type = p.lexer.cur.kind
		ft := p.lexer.cur
		p.cur_tok.type = ft.kind
		p.cur_tok.loc = LexerLoc(ft.start)
		p.cur_tok.raw_end = ft.end
		p.cur_tok.had_line_terminator = (ft.flags & FLAG_NEW_LINE) != 0
		if ft.kind == .RegularExpression {
			p.cur_tok.literal = p.lexer.cur_lit_value
		}
	}
	expr := parse_unary_expr(p)
	if expr == nil {
		lexer_restore(p, snap)
		report_error(p, "Unexpected '<': not a valid TS type assertion or generic arrow")
		return nil
	}
	// OXC rejects `<T>yield 0` in generators: `yield` directly after
	// `>` is treated as an identifier (§14.4.1), which is reserved.
	// `<T>(yield 0)` is fine (parens open AssignmentExpression context).
	// Distinguish by checking if the expression starts at the same
	// offset as the `>` end (no intervening paren).
	if p.in_generator {
		if ye, ok := expr^.(^YieldExpression); ok {
			// Check if `yield` directly follows `>` (bare form), or is
			// inside parens. Walk backwards from yield's start offset.
			ye_start := int(ye.loc.span.start)
			bare_yield := false
			if p.lexer != nil {
				src_bytes := p.lexer.source_bytes
				i := ye_start - 1
				for i >= 0 && (src_bytes[i] == ' ' || src_bytes[i] == '\t' ||
				               src_bytes[i] == '\n' || src_bytes[i] == '\r') {
					i -= 1
				}
				if i >= 0 && src_bytes[i] == '>' { bare_yield = true }
			}
			if bare_yield {
				report_error(p, "Cannot use `yield` as an identifier in a generator context")
			}
		}
	}
	node := new_node(p, TSTypeAssertion)
	node.loc = start
	node.type_annotation = type_ann
	node.expression = expr
	node.loc.span.end = prev_end_offset(p)
	return expression_from(p, node)
}

// Lexer + parser state snapshot used by parse_ts_lt_expression for its
// cheap 2-token lookahead. Does NOT cover dynamic arrays (templates,
// comments) because this trial-parse never touches template strings or
// emits comments; only scalar lex + parser fields matter.
TrialSnapshot :: struct {
	// Lexer scalars
	lex_offset:             int,
	lex_had_line_terminator: bool,
	lex_cur:                FastToken,
	lex_nxt:                FastToken,
	lex_last_lit_offset:    u32,
	lex_last_lit_value:     LiteralValue,
	lex_last_lit_type:      LiteralType,
	lex_cur_lit_offset:     u32,
	lex_cur_lit_value:      LiteralValue,
	lex_cur_lit_type:       LiteralType,
	lex_template_depth:     u8,
	lex_template_brace_stack: [8]u8,
	// Parser scalars
	cur_type:       TokenType,
	cur_tok:        Token,
	prev_token_end: u32,
	errors_len:     int,
}

lexer_snapshot :: proc(p: ^Parser) -> TrialSnapshot {
	l := p.lexer
	return TrialSnapshot{
		lex_offset              = l.offset,
		lex_had_line_terminator = l.had_line_terminator,
		lex_cur                 = l.cur,
		lex_nxt                 = l.nxt,
		lex_last_lit_offset     = l.last_lit_offset,
		lex_last_lit_value      = l.last_lit_value,
		lex_last_lit_type       = l.last_lit_type,
		lex_cur_lit_offset      = l.cur_lit_offset,
		lex_cur_lit_value       = l.cur_lit_value,
		lex_cur_lit_type        = l.cur_lit_type,
		lex_template_depth      = l.template_depth,
		lex_template_brace_stack = l.template_brace_stack,
		cur_type                = p.cur_type,
		cur_tok                 = p.cur_tok,
		prev_token_end          = p.prev_token_end,
		errors_len              = len(p.errors),
	}
}

lexer_restore :: proc(p: ^Parser, s: TrialSnapshot) {
	l := p.lexer
	l.offset                 = s.lex_offset
	l.had_line_terminator    = s.lex_had_line_terminator
	l.cur                    = s.lex_cur
	l.nxt                    = s.lex_nxt
	l.last_lit_offset        = s.lex_last_lit_offset
	l.last_lit_value         = s.lex_last_lit_value
	l.last_lit_type          = s.lex_last_lit_type
	l.cur_lit_offset         = s.lex_cur_lit_offset
	l.cur_lit_value          = s.lex_cur_lit_value
	l.cur_lit_type           = s.lex_cur_lit_type
	l.template_depth         = s.lex_template_depth
	l.template_brace_stack   = s.lex_template_brace_stack
	p.cur_type               = s.cur_type
	p.cur_tok                = s.cur_tok
	p.prev_token_end         = s.prev_token_end
	// Drop any parse errors accumulated during the speculative parse.
	if len(p.errors) > s.errors_len { resize(&p.errors, s.errors_len) }
}

// Parse a generic arrow `<T, ...>(params) [: RetType]? => body` after the
// caller has already confirmed (by 1-token lookahead) that the `<` opens a
// type parameter list. We're still positioned AT the `<`.
parse_ts_generic_arrow :: proc(p: ^Parser, start: Loc) -> ^Expression {
	type_params := parse_ts_type_parameters(p)

	// After the type params we must see `(` for the arrow's parameters.
	if !is_token(p, .LParen) {
		report_error(p, "Expected '(' after generic type parameters")
		return nil
	}

	// Let the normal primary-expression path parse `(params)` as a
	// parenthesised expression or SequenceExpression (the same shape
	// parse_arrow_function expects as its `left` argument).
	paren_expr := parse_primary_expr(p)
	if paren_expr == nil { return nil }

	// K4: the `.LParen` branch of parse_primary_expr may trial-parse the
	// paren-contents as TS arrow params and return a complete arrow
	// (for `<T>(x: U) => x` where the inner `(x: U)` forced the trial).
	// In that case, the arrow has consumed `=>` and body already; we just
	// decorate it with our type parameters and extend the span.
	if arrow_expr, is_arrow := paren_expr^.(^ArrowFunctionExpression); is_arrow {
		arrow_expr.type_parameters = type_params
		arrow_expr.loc.span.start = start.span.start
		return paren_expr
	}

	// Optional TS return-type annotation `: T` before `=>`.
	return_type: Maybe(^TSTypeAnnotation)
	if is_token(p, .Colon) { return_type = parse_ts_type_annotation(p) }

	if !is_token(p, .Arrow) {
		report_error(p, "Expected '=>' in generic arrow function")
		return nil
	}

	arrow := parse_arrow_function(p, paren_expr)
	if arrow == nil { return nil }

	// Attach the type parameters + return type to the arrow node, and
	// extend its span back to the `<` start.
	#partial switch a in arrow^ {
	case ^ArrowFunctionExpression:
		a.type_parameters = type_params
		if rt, ok := return_type.?; ok { a.return_type = rt }
		a.loc.span.start = start.span.start
	}
	return arrow
}

// looks_like_ts_arrow_params - cheap 2-token lookahead to decide whether
// a `(` definitely opens TS arrow parameters (as opposed to a paren-wrapped
// expression). Called only in TS / TSX mode. Used by parse_primary_expr
// to gate try_parse_ts_arrow_params.
//
// Conservative signals (each uniquely identifies arrow params):
//   * `(...`            - rest parameter is only legal inside arrow params.
//   * `(Identifier :`   - `:Type` after an identifier in a paren-group is
//                         only legal as a parameter type annotation.
//
// We intentionally DO NOT trigger the trial on `(Identifier ,` /
// `(Identifier )` / `(Identifier =` / `({...` / `([...` - these all have a
// working paren-grouping path today that flows into parse_arrow_function via
// expr_to_pattern when `=>` follows. Expanding coverage to destructured
// params with type annotations (`({a}: P) => a`) is a future extension and
// needs the same trial-parse plumbing.
looks_like_ts_arrow_params :: proc(p: ^Parser) -> bool {
	assert(p.cur_type == .LParen)
	nxt := p.lexer.nxt.kind
	if nxt == .Dot3 { return true }

	// Existing fast path: `(Identifier :` is unambiguously an arrow head.
	if nxt == .Identifier {
		snap := lexer_snapshot(p)
		eat(p) // consume `(`
		eat(p) // consume Identifier
		after := p.cur_type
		lexer_restore(p, snap)
		if after == .Colon { return true }
	}

	// Byte-level scan for `(...): T =>` arrow heads where the inner params
	// don't have a `: T` annotation but the return-type position does. This
	// covers:
	//   - empty `(): T => ...`
	//   - bare-ident `(t): T => ...`,  `(t): t is U => ...`
	//   - multi-ident `(a, b): T => ...`
	//   - destructured `({a}): T => ...`
	//   - rest-only is already caught by the .Dot3 fast path above.
	// The trial parser try_parse_ts_arrow_params rolls back on failure, so
	// over-broad detection here is safe - the cost of a false-positive is
	// one rollback. Closes ~30 OXC corpus rejects in the
	// "Expected ), got :" cluster (S26 W6 phase 3 bug class #18).
	//
	// EXCEPT inside a ternary consequent: the byte scan can misread the
	// ternary `:` + alternate `v => 0` as `): RetType => body`, eating the
	// colon and wrecking the ternary. When conditional_depth > 0 skip the
	// broad scan; the `(ident :` fast path above is unambiguous and still
	// fires. Closes OXC corpus "Expected :, got ;" sub-cluster (W7 #44).
	if p.lexer != nil && p.conditional_depth == 0 {
		src := p.lexer.source_bytes
		lparen_off := int(p.lexer.cur.start)
		depth := 0
		i := lparen_off
		src_len := len(src)
		end_off := -1
		scan: for i < src_len {
			ch := src[i]
			switch ch {
			case '(', '[', '{':
				depth += 1
			case ')', ']', '}':
				depth -= 1
				if depth == 0 && ch == ')' { end_off = i; break scan }
			case '"', '\'':
				quote := ch
				i += 1
				for i < src_len && src[i] != quote {
					if src[i] == '\\' && i + 1 < src_len { i += 1 }
					i += 1
				}
			case '/':
				if i + 1 < src_len && src[i+1] == '/' {
					for i < src_len && src[i] != '\n' { i += 1 }
				} else if i + 1 < src_len && src[i+1] == '*' {
					i += 2
					for i + 1 < src_len && !(src[i] == '*' && src[i+1] == '/') { i += 1 }
					if i + 1 < src_len { i += 1 }
				}
			}
			i += 1
		}
		if end_off < 0 { return false }
		j := end_off + 1
		for j < src_len {
			ch := src[j]
			if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { j += 1; continue }
			if ch == '/' && j + 1 < src_len && src[j+1] == '/' {
				for j < src_len && src[j] != '\n' { j += 1 }; continue
			}
			if ch == '/' && j + 1 < src_len && src[j+1] == '*' {
				j += 2
				for j + 1 < src_len && !(src[j] == '*' && src[j+1] == '/') { j += 1 }
				if j + 1 < src_len { j += 2 }
				continue
			}
			break
		}
		// Direct `=>` - plain arrow without return type, but the regular
		// non-TS path handles those. Returning true is harmless: the trial
		// parser will succeed and build the same arrow.
		if j + 1 < src_len && src[j] == '=' && src[j+1] == '>' { return true }
		// `:` here means a return-type annotation - walk past it tracking
		// balanced groups, looking for top-level `=>`.
		if j < src_len && src[j] == ':' {
			j += 1
			t_depth := 0
			ts_scan: for j < src_len {
				tch := src[j]
				switch tch {
				case '<', '(', '[', '{':
					t_depth += 1
				case '>', ')', ']', '}':
					if t_depth == 0 { return false }
					t_depth -= 1
				case '=':
					// `=>` arrow detection. At top-level it terminates the
					// scan with success. Inside a balanced group, the `>` is
					// PART of the arrow token - we must skip BOTH bytes so
					// the `>` isn't later mis-consumed as a group closer.
					// Test: `<T>(): (() => T) => null as any` (the inner
					// `=>` of the parenthesised function type).
					if j + 1 < src_len && src[j+1] == '>' {
						if t_depth == 0 { return true }
						j += 1  // outer loop adds one more, so we step past `>`
					}
				case ',', ';':
					if t_depth == 0 { break ts_scan }
				case '"', '\'':
					quote := tch
					j += 1
					for j < src_len && src[j] != quote {
						if src[j] == '\\' && j + 1 < src_len { j += 1 }
						j += 1
					}
				case '/':
					if j + 1 < src_len && src[j+1] == '/' {
						for j < src_len && src[j] != '\n' { j += 1 }
					} else if j + 1 < src_len && src[j+1] == '*' {
						j += 2
						for j + 1 < src_len && !(src[j] == '*' && src[j+1] == '/') { j += 1 }
						if j + 1 < src_len { j += 1 }
					}
				}
				j += 1
			}
		}
	}
	return false
}

// try_parse_ts_arrow_params - speculatively parse `(params) [:RetType]? =>
// body` starting at `(`. Returns the constructed ArrowFunctionExpression on
// success, or nil on failure with parser state fully restored to the `(`.
//
// The caller has already filtered via looks_like_ts_arrow_params(p), so the
// snapshot/rollback path is a safety net rather than the common case. On
// the happy path we build the arrow directly - no conversion from
// Expression→Pattern needed because parse_function_params already produced
// proper FunctionParameter nodes with type annotations attached.
try_parse_ts_arrow_params :: proc(p: ^Parser, lparen_tok: Token) -> ^Expression {
	lparen_tok := lparen_tok  // re-bind to a mutable local; Odin parameters aren't addressable
	start_loc := loc_from_token(&lparen_tok)
	snap := lexer_snapshot(p)
	prev_pending_paren := p.pending_paren_start

	eat(p) // consume `(`

	// parse_function_params already handles: rest (`...x`), optional (`x?`),
	// type annotation (`x: T`), default value (`x = 1`), and destructuring.
	params := parse_function_params(p)
	report_parameter_modifiers_disallowed(p, params[:])

	if !is_token(p, .RParen) {
		lexer_restore(p, snap)
		p.pending_paren_start = prev_pending_paren
		return nil
	}
	eat(p) // consume `)`

	// Optional return type annotation: `(params): T => body`. Use
	// parse_ts_return_type_annotation rather than parse_ts_type_annotation
	// so type-predicate forms `(x): x is T => ...`, `(x): asserts x => ...`,
	// and `(x): asserts x is T => ...` parse as TSTypePredicate (closes
	// ~25 OXC corpus rejects in the "Expected ), got :" cluster - S26 W6
	// phase 3 bug class #18). Pre-fix the plain parse_ts_type_annotation
	// path called parse_ts_type which doesn't recognise the predicate's
	// `is` / `asserts` keywords; the trial bailed at `is` and the outer
	// parser tried to re-parse the whole `(x: T)` as a paren-expr,
	// reporting "Expected ), got :" on the now-illegal type colon.
	return_type: Maybe(^TSTypeAnnotation)
	if is_token(p, .Colon) {
		snap_errs := len(p.errors)
		return_type = parse_ts_return_type_annotation(p)
		// `(a): => {}` — colon with no type before `=>`.
		if rt, ok := return_type.?; ok && rt != nil && rt.type_annotation == nil {
			report_error(p, "Expected type after ':' in arrow return type annotation")
		}
		// If the return type parse produced errors, bail out and let
		// the outer parser try a different interpretation.
		if len(p.errors) > snap_errs {
			lexer_restore(p, snap)
			p.pending_paren_start = prev_pending_paren
			resize(&p.errors, snap_errs)
			return nil
		}
	}

	if !is_token(p, .Arrow) {
		lexer_restore(p, snap)
		p.pending_paren_start = prev_pending_paren
		return nil
	}
	// §15.3 - ArrowParameters [no LineTerminator here] =>
	if p.cur_tok.had_line_terminator {
		report_error(p, "Line terminator not permitted before '=>'")
	}
	eat(p) // consume `=>`

	// Body - block or expression. Mirror parse_arrow_function's treatment.
	// §15.3.4: Arrow body is parsed with [~Yield, ~Await] (unless async).
	// Reset in_generator so `yield` inside the arrow body is an identifier.
	prev_in_generator := p.in_generator
	p.in_generator = false
	prev_static_block_ts := p.in_static_block
	p.in_static_block = false
	is_block_body := is_token(p, .LBrace)
	body: ArrowFunctionBody
	if is_block_body {
		prev_in_function := p.in_function
		p.in_function = true
		block_stmt := parse_block_statement(p)
		p.in_function = prev_in_function
		// §15.3.1: arrow `{ FunctionBody }` is a function-scope, not a block-scope.
		if block_stmt != nil {
			if bs, ok := block_stmt^.(^BlockStatement); ok {
				body = bs
			}
		}
	} else {
		#partial switch p.cur_type {
		case .Semi, .Comma, .RParen, .RBracket, .RBrace, .EOF:
			report_error(p, "Unexpected token")
		}
		body = parse_assignment_expression(p)
	}

	p.in_generator = prev_in_generator
	p.in_static_block = prev_static_block_ts

	arrow := new_node(p, ArrowFunctionExpression)
	arrow.loc = start_loc
	arrow.params = params
	arrow.body = body
	arrow.expression = !is_block_body
	arrow.async = false
	if rt, ok := return_type.?; ok { arrow.return_type = rt }
	arrow.loc.span.end = prev_end_offset(p)

	// TS generic arrow - same UniqueFormalParameters rule as plain arrow.

	return expression_from(p, arrow)
}

parse_ts_type_parameters :: proc(p: ^Parser) -> ^TSTypeParameterDeclaration {
	if !is_token(p, .LAngle) { return nil }
	start := cur_loc(p); eat(p) // consume `<`
	empty_at_start := is_close_angle_token(p)
	// Re-allow conditional types inside angle brackets.
	saved_disallow_ct := p.ts_disallow_conditional_types
	p.ts_disallow_conditional_types = 0
	params := make([dynamic]TSTypeParameter, 0, 4, p.allocator)
	for !is_token(p, .RAngle) && !is_token(p, .EOF) {
		// Reject empty type parameter positions: `<,T>` or `<,>`.
		if is_token(p, .Comma) {
			report_error(p, "Expected type parameter name, got ','")
			eat(p)
			continue
		}
		param_start := cur_loc(p)
		// TS type-parameter modifiers - may appear in any order before the
		// name. `const` (TS 5.0+) lexes as the .Const keyword; `in` lexes
		// as the .In keyword; `out` is a contextual identifier. They are
		// only modifiers if followed by something that can legitimately
		// start a type parameter (another modifier or an identifier name);
		// otherwise treat as the parameter name itself (TS allows using
		// reserved-ish words like `out` as a type-parameter name).
		in_mod, out_mod, const_mod := false, false, false
		for {
			nxt := peek_token(p)
			nxt_starts_param := nxt.type == .Identifier || nxt.type == .Const || nxt.type == .In
			if p.cur_type == .Const && nxt_starts_param {
				const_mod = true; eat(p); continue
			}
			if p.cur_type == .In && nxt_starts_param {
				in_mod = true; eat(p); continue
			}
			if p.cur_type == .Identifier && p.cur_tok.value == "out" && nxt_starts_param {
				out_mod = true; eat(p); continue
			}
			break
		}
		// After modifiers, the current token must be a valid type parameter
		// name (identifier). Reserved words like `in` are NOT valid names:
		// `type T<in in>` — the second `in` is a keyword, not a name.
		if is_reserved_word_for_binding(p.cur_type) {
			msg := fmt.tprintf("Identifier expected. '%s' is a reserved word that cannot be used here.", cur_value(p))
			report_error(p, msg)
		}
		cur := get_current(p)
		name := BindingIdentifier{loc = loc_from_token(&cur), name = cur.value}
		eat(p) // consume identifier
		constraint: Maybe(^TSType)
		default_: Maybe(^TSType)
		if is_token(p, .Extends) {
			eat(p)
			c := parse_ts_type(p)
			if c == nil {
				report_error(p, "Expected type after 'extends'")
			} else {
				constraint = c
			}
		}
		if is_token(p, .Assign) {
			eat(p)
			d := parse_ts_type(p)
			if d == nil {
				report_error(p, "Expected type after '='")
			} else {
				default_ = d
			}
		}
		param := TSTypeParameter{
			loc = param_start, name = name,
			constraint = constraint, default_ = default_,
			in_ = in_mod, out = out_mod, const_ = const_mod,
		}
		param.loc.span.end = prev_end_offset(p)
		bump_append(&params, param)
		if !match_token(p, .Comma) { break }
	}
	if empty_at_start && len(params) == 0 {
		report_error(p, "Type parameter list cannot be empty")
	}
	// Use expect_close_angle so `>=` splits into `>` + `=`.
	// Fixes: `type T<U>=U` where `>=` should close the type params.
	expect_close_angle(p)
	p.ts_disallow_conditional_types = saved_disallow_ct
	decl := new_node(p, TSTypeParameterDeclaration)
	decl.loc = start; decl.params = params
	decl.loc.span.end = prev_end_offset(p)
	return decl
}

parse_ts_type_object :: proc(p: ^Parser) -> ^TSType {
	start := cur_loc(p); eat(p) // consume `{`

	// Track type-literal depth so parse_ts_type_reference can suppress
	// newline-separated type arguments (they start a new member, not
	// a type-argument list on the preceding type).
	p.ts_in_type_literal += 1
	defer p.ts_in_type_literal -= 1

	// Re-allow conditional types inside braces (TypeScript's
	// allowConditionalTypesAnd). Conditional types are suppressed only
	// at the immediate level of the extends type in a conditional;
	// inside any grouping construct (`{`, `[`, `(`) they're re-enabled.
	saved_disallow_ct := p.ts_disallow_conditional_types
	p.ts_disallow_conditional_types = 0
	defer p.ts_disallow_conditional_types = saved_disallow_ct

	// Detect mapped type: `{ [K in T]: V }` or `{ readonly [K in T]?: V }`.
	// Use `is_next_identifier_value` for cheap lookahead without speculative parse.
	is_mapped := false
	readonly_mod := TSMappedTypeModifier.None
	// modifier_start: position of the first modifier token (readonly/+/-) before
	// `[`. Used to set the correct start on index signatures that have a modifier.
	modifier_start := cur_loc(p).span.start

	// Check `{ readonly [`  - readonly then bracket, plus `+readonly [` / `-readonly [`.
	// `.Readonly` is not in the lexer - check by string value.
	if (p.cur_type == .Plus || p.cur_type == .Minus) {
		sign := p.cur_type == .Plus ? TSMappedTypeModifier.Plus : TSMappedTypeModifier.Minus
		nxt := p.lexer.nxt
		if nxt.kind == .Identifier {
			nxt_val := p.lexer.source[nxt.start:nxt.end]
			if nxt_val == "readonly" {
				readonly_mod = sign
				eat(p); eat(p) // consume sign and `readonly`
			}
		}
	}
	if p.cur_type == .Identifier && p.cur_tok.value == "readonly" && is_next_token(p, .LBracket) {
		readonly_mod = .True; eat(p) // consume `readonly`, now at `[`
	}

	// Check `{ [K in` pattern. Mapped types REQUIRE the literal `in`
	// keyword between the type-parameter name and the source type, so a
	// 2-token-ahead probe is enough to disambiguate from:
	//   - index signature       `[k : T]: V`
	//   - computed property key `[Symbol.iterator]?(): R`
	is_index_sig_after_readonly := false
	if is_token(p, .LBracket) {
		nxt := p.lexer.nxt
		if nxt.kind == .Identifier || nxt.kind == .Let || nxt.kind == .As {
			snap := lexer_snapshot(p)
			eat(p) // `[`
			eat(p) // identifier
			after := p.cur_type
			lexer_restore(p, snap)
			if after == .In {
				is_mapped = true
			} else if after == .Colon {
				is_index_sig_after_readonly = readonly_mod != .None
			}
		}
	}

	// `readonly [id: T]: V` (index signature with readonly modifier) - we
	// already ate `readonly` above. Hand the rest off to
	// parse_ts_object_member but with the readonly flag preserved by
	// faking out a `.Readonly` arm. Easiest path: fall through to the
	// regular object loop, but seed `members` with this one index
	// signature parsed inline and reset the modifier so subsequent
	// members don't inherit it.
	if is_index_sig_after_readonly {
		members := make([dynamic]^TSSignature, 0, 4, p.allocator)
		lb_start := cur_loc(p)
		eat(p) // `[`
		param_start := cur_loc(p)
		param_name_tok := get_current(p)
		eat(p) // identifier
		colon_start := cur_loc(p)
		eat(p) // `:`
		idx_ann := parse_ts_type(p)
		key_type_end := prev_end_offset(p)
		expect_token(p, .RBracket)
		val_ann: Maybe(^TSTypeAnnotation)
		if is_token(p, .Colon) {
			val_ann = parse_ts_type_annotation(p)
		} else {
			report_error(p, "An index signature must have a type annotation.")
		}
		param_name_ident := new_node(p, Identifier)
		param_name_ident.loc = loc_from_token(&param_name_tok)
		param_name_ident.name = param_name_tok.value
		key_ann := new_node(p, TSTypeAnnotation)
		key_ann.loc.span.start = colon_start.span.start
		key_ann.loc.span.end   = key_type_end
		key_ann.type_annotation = idx_ann
		sig_loc_start := modifier_start
		idx_sig := TSIndexSignature{
			loc = Loc{span = Span{start = sig_loc_start, end = lb_start.span.end}},
			parameters = make([dynamic]TSFunctionParam, 0, 1, p.allocator),
			type_annotation = val_ann,
			readonly = readonly_mod == .True,
		}
		fp := TSFunctionParam{
			loc = param_start,
			pattern = param_name_ident,
			type_annotation = key_ann,
		}
		fp.loc.span.end = key_type_end
		bump_append(&idx_sig.parameters, fp)
		match_token(p, .Semi); match_token(p, .Comma)
		idx_sig.loc.span.end = prev_end_offset(p)
		first_sig := new_node(p, TSSignature); first_sig^ = idx_sig
		bump_append(&members, first_sig)
		readonly_mod = .None // consumed; subsequent members are independent
		for !is_token(p, .RBrace) && !is_token(p, .EOF) {
			prev_off := int(cur_offset(p))
			sig := parse_ts_object_member(p); if sig != nil { bump_append(&members, sig) }
			match_token(p, .Semi); match_token(p, .Comma)
			if int(cur_offset(p)) == prev_off { eat(p) }
		}
		expect_token(p, .RBrace)
		lit := new_node(p, TSTypeLiteral); lit.loc = start; lit.members = members
		lit.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = lit; return r
	}

	// If we ate readonly but it's not actually mapped, we need to treat
	// `readonly` as the first property key of a regular object type.
	// This can't easily be recovered (we consumed readonly), so report error.
	if readonly_mod != .None && !is_mapped {
		readonly_mod = .None
	}

	if is_mapped && is_token(p, .LBracket) {
		lb_start := cur_loc(p)
		eat(p) // consume `[`
		// Parse type parameter: `K in T`
		param_start := cur_loc(p)
		param_name := parse_identifier(p)
		// Computed-property name disambiguation: `{ [x]: T }` parses the
		// identifier `x` here too, but it's a computed key, not a mapped-
		// type or index-signature parameter. Detect via current `]`. We
		// already ate `[`; build the rest of a TSPropertySignature inline,
		// then continue the regular object-member loop for siblings. Closes
		// ~21 OXC corpus rejects in the "Expected :, got ]" cluster.
		if is_token(p, .RBracket) {
			eat(p) // consume `]`
			key_ident := new_node(p, Identifier)
			key_ident.loc = param_name.loc
			key_ident.name = param_name.name
			optional := match_token(p, .Question)
			prop := TSPropertySignature{
				loc = Loc{span = Span{start = lb_start.span.start}},
				key = expression_from(p, key_ident),
				computed = true, optional = optional,
				readonly = readonly_mod == .True,
			}
			if is_token(p, .Colon) { prop.type_annotation = parse_ts_type_annotation(p) }
			prop.loc.span.end = prev_end_offset(p)
			members := make([dynamic]^TSSignature, 0, 4, p.allocator)
			first_sig := new_node(p, TSSignature); first_sig^ = prop
			bump_append(&members, first_sig)
			match_token(p, .Semi); match_token(p, .Comma)
			for !is_token(p, .RBrace) && !is_token(p, .EOF) {
				prev_off := int(cur_offset(p))
				sig := parse_ts_object_member(p); if sig != nil { bump_append(&members, sig) }
				match_token(p, .Semi); match_token(p, .Comma)
				if int(cur_offset(p)) == prev_off { eat(p) }
			}
			expect_token(p, .RBrace)
			lit := new_node(p, TSTypeLiteral); lit.loc = start; lit.members = members
			lit.loc.span.end = prev_end_offset(p)
			r := new_node(p, TSType); r^ = lit; return r
		}
		if !is_token(p, .In) {
			// Not a mapped type after all - it's an index signature
			// `[ident : type]: value`. We've already eaten `[` and the
			// identifier, plus an optional leading `readonly`. Build an
			// index signature as the first member, then continue into the
			// regular object-member loop (which appends siblings).
			members := make([dynamic]^TSSignature, 0, 4, p.allocator)
			// key_type_start: position of `:` before the key type annotation.
			key_type_start := cur_loc(p)  // points to `:`
			expect_token(p, .Colon)
			idx_ann := parse_ts_type(p)
			// Capture end of key type BEFORE eating `]` and parsing value type.
			key_type_end := prev_end_offset(p)
			expect_token(p, .RBracket)
			val_ann: Maybe(^TSTypeAnnotation)
			if is_token(p, .Colon) {
				val_ann = parse_ts_type_annotation(p)
			} else {
				report_error(p, "An index signature must have a type annotation.")
			}
			param_name_ident := new_node(p, Identifier)
			param_name_ident.loc = param_name.loc
			param_name_ident.name = param_name.name
			// TSTypeAnnotation for the key: spans [colon, end-of-key-type].
			key_ann := new_node(p, TSTypeAnnotation)
			key_ann.loc.span.start = key_type_start.span.start
			key_ann.loc.span.end   = key_type_end
			key_ann.type_annotation = idx_ann
			// Parameter: spans [start-of-name, end-of-key-type].
			// OXC ends the parameter at the end of the key type annotation,
			// NOT at the `]` or the value type.
			// Use modifier_start as the index signature loc start when a
			// readonly/+/-readonly modifier preceded the `[`; otherwise use lb_start.
			sig_loc_start := modifier_start if readonly_mod != .None else lb_start.span.start
			idx_sig := TSIndexSignature{
				loc = Loc{span = Span{start = sig_loc_start, end = lb_start.span.end}},
				parameters = make([dynamic]TSFunctionParam, 0, 1, p.allocator),
				type_annotation = val_ann,
				readonly = readonly_mod == .True,
			}
			fp := TSFunctionParam{
				loc = param_start,
				pattern = param_name_ident,
				type_annotation = key_ann,
			}
			fp.loc.span.end = key_type_end
			bump_append(&idx_sig.parameters, fp)
			// Consume optional semi/comma BEFORE setting the end span so the
			// index signature span includes the terminator (matching OXC).
			match_token(p, .Semi); match_token(p, .Comma)
			idx_sig.loc.span.end = prev_end_offset(p)
			first_sig := new_node(p, TSSignature); first_sig^ = idx_sig
			bump_append(&members, first_sig)
			for !is_token(p, .RBrace) && !is_token(p, .EOF) {
				// Progress guard (TigerStyle: every loop must have a fixed upper
				// bound). Without this, an unsupported TS member shape that leaves
				// parse_ts_object_member at nil with no advance loops forever.
				prev_off := int(cur_offset(p))
				sig := parse_ts_object_member(p); if sig != nil { bump_append(&members, sig) }
				match_token(p, .Semi); match_token(p, .Comma)
				if int(cur_offset(p)) == prev_off { eat(p) }
			}
			expect_token(p, .RBrace)
			lit := new_node(p, TSTypeLiteral); lit.loc = start; lit.members = members; lit.loc.span.end = prev_end_offset(p)
			r := new_node(p, TSType); r^ = lit; return r
		}
		eat(p) // consume `in`
		constraint := parse_ts_type(p)
		name_type: Maybe(^TSType)
		if is_token(p, .As) {
			eat(p)
			name_type = parse_ts_type(p)
			if name_type == nil {
				report_error(p, "Expected type after 'as' in mapped type")
			}
		}
		expect_token(p, .RBracket)
		// Optional modifier: `?`, `+?`, `-?`.
		optional_mod := TSMappedTypeModifier.None
		if (is_token(p, .Plus) || is_token(p, .Minus)) && p.lexer.nxt.kind == .Question {
			optional_mod = p.cur_type == .Plus ? .Plus : .Minus
			eat(p); eat(p) // consume sign and `?`
		} else if match_token(p, .Question) {
			optional_mod = .True
		}
		// Type annotation
		value_type: Maybe(^TSType)
		if is_token(p, .Colon) { eat(p); value_type = parse_ts_type(p) }
		match_token(p, .Semi); match_token(p, .Comma)
		expect_token(p, .RBrace)
		mt := new_node(p, TSMappedType); mt.loc = start
		mt.type_parameter = TSTypeParameter{
			loc = param_start, name = BindingIdentifier{loc = param_name.loc, name = param_name.name},
			constraint = constraint,
		}
		mt.name_type = name_type; mt.type_annotation = value_type
		mt.optional = optional_mod; mt.readonly = readonly_mod
		mt.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = mt; return r
	}

	// Regular object type literal.
	members := make([dynamic]^TSSignature, 0, 4, p.allocator)
	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		prev_off := u32(cur_offset(p))
		sig := parse_ts_object_member(p); if sig != nil { bump_append(&members, sig) }
		// S26 W4d: extend the member's span over the trailing `;` / `,`
		// terminator so the TSPropertySignature / TSMethodSignature span
		// matches OXC's convention. Same widen pattern as the TSInterfaceBody
		// loop further down. Pre-fix: every TSTypeLiteral member ended one
		// byte short of OXC on `{ id: string; foo: number; }` and friends.
		has_term := is_token(p, .Semi) || is_token(p, .Comma)
		match_token(p, .Semi); match_token(p, .Comma)
		if has_term && sig != nil {
			set_ts_sig_end(sig, prev_end_offset(p))
		}
		// Defensive: parse_ts_object_member can return nil without consuming
		// (e.g. when cur is `.RBracket` left over from a malformed inner
		// type). Without this guard the loop spins forever - reproduced by
		// `let X: { o: readonly ["a", "b"] };` where the `readonly` token
		// isn't recognised as a type-operator-on-tuple, so parse_ts_type
		// returns nil leaving readonly + `["a", "b"]` unconsumed in the
		// outer object loop. Always advance at least one token per iteration.
		if u32(cur_offset(p)) == prev_off {
			report_error(p, "Unexpected token in TS object type")
			eat(p)
		}
	}
	expect_token(p, .RBrace)
	lit := new_node(p, TSTypeLiteral); lit.loc = start; lit.members = members; lit.loc.span.end = prev_end_offset(p)
	r := new_node(p, TSType); r^ = lit; return r
}

// parse_ts_sig_params parses parameter list for method/call/construct signatures.
// Assumes the opening `(` has NOT yet been consumed.
parse_ts_sig_params :: proc(p: ^Parser) -> [dynamic]TSFunctionParam {
	expect_token(p, .LParen)
	// Re-allow conditional types inside function signature parameters.
	saved_disallow_ct := p.ts_disallow_conditional_types
	p.ts_disallow_conditional_types = 0
	defer p.ts_disallow_conditional_types = saved_disallow_ct
	params := make([dynamic]TSFunctionParam, 0, 4, p.allocator)
	for !is_token(p, .RParen) && !is_token(p, .EOF) {
		param_start := cur_loc(p)
		param_is_rest := false
		// Allow `this:` as the first parameter (TS-only - binds the
		// callee receiver type). Treat `this` here as an Identifier-
		// shaped param pattern so the rest of the signature parses
		// uniformly. Position-checking (must be FIRST param) is the
		// type checker's job.
		pattern: Pattern
		if is_token(p, .This) {
			this_tok := get_current(p)
			eat(p)
			this_id := new_node(p, Identifier)
			this_id.loc = loc_from_token(&this_tok)
			// S26 W5b: source-slice (this_tok.value), not literal - same
			// RODATA bug as the .Async paths.
			this_id.name = this_tok.value
			pattern = this_id
		} else if is_token(p, .Dot3) {
			param_is_rest = true
			// TS rest parameter in function-type signature: `(...args: T) => U`.
			// parse_function_parameter (the JS-side analogue) handles this with
			// a Dot3 → RestElement-wrapping branch; parse_ts_sig_params shipped
			// without one, so every TS function type with rest reported
			// "Expected binding pattern" at the `...`. Closes 180 OXC corpus
			// rejects in the cluster of that exact error message (S26 W6 phase
			// 3 bug class #6).
			rest_start := cur_loc(p)
			eat(p)  // consume `...`
			inner := parse_binding_pattern(p)
			rest := new_node(p, RestElement)
			rest.loc = rest_start
			rest.argument = inner
			rest.loc.span.end = prev_end_offset(p)
			pattern = rest
		} else {
			pattern = parse_binding_pattern(p)
		}
		param_optional := false
		if is_token(p, .Question) {
			nxt := peek_token(p)
			if nxt.type == .Colon || nxt.type == .Comma || nxt.type == .RParen {
				eat(p); param_optional = true
			}
		}
		if param_is_rest && param_optional {
			report_error(p, "A rest parameter cannot be optional")
		}
		param_ann: Maybe(^TSTypeAnnotation)
		if is_token(p, .Colon) { param_ann = parse_ts_type_annotation(p) }
		// TS function-type params accept a default-value initializer
		// (`(a: number = 1) => number`). The TS spec marks this as an
		// error in pure type position, but every mainstream parser
		// (TypeScript, Babel, OXC) ACCEPTS the syntax and surfaces it as
		// an AssignmentPattern wrapping the binding. Match that
		// behaviour - test:
		// typescript/compiler/defaultValueInFunctionTypes.ts.
		if is_token(p, .Assign) {
			eat(p) // consume `=`
			default_expr := parse_assignment_expression(p)
			if default_expr != nil {
				#partial switch inner in pattern {
				case ^Identifier, ^ObjectPattern, ^ArrayPattern:
					ap := new_node(p, AssignmentPattern)
					ap.loc = param_start
					ap.left = pattern
					ap.right = default_expr
					ap.loc.span.end = prev_end_offset(p)
					pattern = ap
				}
			}
		}
		// S26 W4d: extend the inner pattern's span over the type annotation
		// so the emitted Identifier (or ObjectPattern/ArrayPattern) end
		// matches OXC's convention. The annotation lives on the
		// TSFunctionParam itself (not on the inner pattern); the span
		// extension is purely positional. parse_function_param already
		// applies the same widen to plain JS function parameters; this
		// closes the symmetric gap on TS function-type signatures
		// (3 baseline divergences on tsx/001).
		if ann, ok := param_ann.(^TSTypeAnnotation); ok && ann != nil {
			#partial switch t in pattern {
			case ^Identifier:
				if ann.loc.span.end > t.loc.span.end {
					t.loc.span.end = ann.loc.span.end
				}
			case ^ObjectPattern:
				if ann.loc.span.end > t.loc.span.end {
					t.loc.span.end = ann.loc.span.end
				}
			case ^ArrayPattern:
				if ann.loc.span.end > t.loc.span.end {
					t.loc.span.end = ann.loc.span.end
				}
			}
		}
		fp := TSFunctionParam{loc = param_start, pattern = pattern, type_annotation = param_ann, optional = param_optional}
		fp.loc.span.end = prev_end_offset(p)
		bump_append(&params, fp)
		if param_is_rest && is_token(p, .Comma) {
			if p.lexer.nxt.kind == .RParen {
				if !p.in_ambient && !p.source_is_dts {
					report_error(p, "A rest parameter or binding pattern may not have a trailing comma.")
				}
			} else {
				report_error(p, "A rest parameter must be last in a parameter list")
			}
		}
		if !match_token(p, .Comma) { break }
	}
	expect_token(p, .RParen)
	return params
}

// set_ts_sig_end widens a TSSignature's `loc.span.end` in place. Used
// after consuming a trailing `;` / `,` / `}` so the member's span
// includes the terminator (OXC convention). The signature is a tagged
// union over value-carrying structs; we have to pattern-match and mutate
// each variant.
set_ts_sig_end :: proc(sig: ^TSSignature, end: u32) {
	if sig == nil { return }
	switch v in sig^ {
	case TSPropertySignature:
		p := v; p.loc.span.end = end; sig^ = p
	case TSMethodSignature:
		p := v; p.loc.span.end = end; sig^ = p
	case TSCallSignatureDeclaration:
		p := v; p.loc.span.end = end; sig^ = p
	case TSConstructSignatureDeclaration:
		p := v; p.loc.span.end = end; sig^ = p
	case TSIndexSignature:
		p := v; p.loc.span.end = end; sig^ = p
	}
}

parse_ts_object_member :: proc(p: ^Parser) -> ^TSSignature {
	start := cur_loc(p)
	readonly := false
	idx_readonly := false  // Special handling for readonly index signature

	// TS type members permit `readonly` but not class/parameter modifiers.
	// Consume the invalid prefix anyway so the following member shape is still
	// parsed and the corpus smoke gate sees the parser-level error.
	for i := 0; i < 4; i += 1 {
		modifier_name := ""
		if is_token(p, .Static) {
			modifier_name = "static"
		} else if is_token(p, .Override) {
			modifier_name = "override"
		} else if is_token(p, .Identifier) {
			switch p.cur_tok.value {
			case "public", "private", "protected", "declare":
				modifier_name = p.cur_tok.value
			}
		}
		if modifier_name == "" { break }
		if (p.lexer.nxt.flags & FLAG_NEW_LINE) != 0 { break }
		nxt := p.lexer.nxt.kind
		if nxt == .Colon || nxt == .Question || nxt == .LParen || nxt == .Semi ||
		   nxt == .Comma || nxt == .RBrace {
			break
		}
		report_error(p, fmt.tprintf("'%s' modifier cannot appear on a type member.", modifier_name))
		eat(p)
	}

	// --- NEW: detect call signature `(...): T` or generic `<T>(...): T` ----------
	//   The generic call signature form is used in TS overload sets like
	//   `_default<T extends Statement>(node: T): T;` (canonical example:
	//   @babel/types/lib/index.d.ts). Both forms produce a
	//   TSCallSignatureDeclaration with type_parameters set from the leading
	//   `<...>` (or nil for the bare `(...)` form).
	if is_token(p, .LParen) || is_token(p, .LAngle) {
		type_params: Maybe(^TSTypeParameterDeclaration)
		if is_token(p, .LAngle) {
			type_params = parse_ts_type_parameters(p)
			if !is_token(p, .LParen) {
				report_error(p, "Expected '(' after type parameters in call signature")
				return nil
			}
		}
		params := parse_ts_sig_params(p)
		ret: Maybe(^TSTypeAnnotation)
		if is_token(p, .Colon) { ret = parse_ts_return_type_annotation(p) }
		call_sig := TSCallSignatureDeclaration{
			loc = start, type_parameters = type_params, params = params, return_type = ret,
		}
		call_sig.loc.span.end = prev_end_offset(p)
		sig := new_node(p, TSSignature); sig^ = call_sig; return sig
	}

	// --- NEW: detect construct signature `new (...): T` or `new <T>(...): T` -----
	if is_token(p, .New) && (p.lexer.nxt.kind == .LParen || p.lexer.nxt.kind == .LAngle) {
		eat(p) // consume `new`
		ctor_type_params: Maybe(^TSTypeParameterDeclaration)
		if is_token(p, .LAngle) {
			ctor_type_params = parse_ts_type_parameters(p)
		}
		params := parse_ts_sig_params(p)
		ret: Maybe(^TSTypeAnnotation)
		if is_token(p, .Colon) { ret = parse_ts_return_type_annotation(p) }
		ctor_sig := TSConstructSignatureDeclaration{
			loc = start, type_parameters = ctor_type_params, params = params, return_type = ret,
		}
		ctor_sig.loc.span.end = prev_end_offset(p)
		sig := new_node(p, TSSignature); sig^ = ctor_sig; return sig
	}

	// --- NEW: detect index signature `[ident : type]: type` or `readonly [ident : type]: type`
	if is_token(p, .Readonly) && p.lexer.nxt.kind == .LBracket {
		idx_readonly = true
		eat(p) // consume `readonly`
	}

	// §A.5 - Invalid index signature forms: `[]`, `[...x]`, etc.
	// in type members. Detect and report before falling through.
	if is_token(p, .LBracket) && p.lexer.nxt.kind == .RBracket {
		// `[]: T` - empty index signature.
		report_error(p, "An index signature must have a parameter")
		eat(p) // `[`
		eat(p) // `]`
		if is_token(p, .Colon) { eat(p); _ = parse_ts_type(p) }
		call_decl := TSCallSignatureDeclaration{loc = start}
		call_decl.loc.span.end = prev_end_offset(p)
		sig := new_node(p, TSSignature); sig^ = call_decl
		return sig
	}
	if is_token(p, .LBracket) && p.lexer.nxt.kind == .Dot3 {
		// `[...x]: T` - spread in index signature.
		report_error(p, "An index signature parameter cannot use a rest pattern")
		eat(p) // `[`
		for !is_token(p, .RBracket) && !is_token(p, .EOF) { eat(p) }
		if is_token(p, .RBracket) { eat(p) }
		if is_token(p, .Colon) { eat(p); _ = parse_ts_type(p) }
		call_decl2 := TSCallSignatureDeclaration{loc = start}
		call_decl2.loc.span.end = prev_end_offset(p)
		sig := new_node(p, TSSignature); sig^ = call_decl2
		return sig
	}
	if is_token(p, .LBracket) && p.lexer.nxt.kind == .Identifier {
		// Check if this is an index signature by peeking for `:` after the identifier.
		eat(p) // consume `[`.
		is_index_sig := false
		if is_token(p, .Identifier) {
			if p.lexer.nxt.kind == .Colon {
				is_index_sig = true
			} else if p.lexer.nxt.kind == .Question {
				snap := lexer_snapshot(p)
				eat(p) // identifier.
				eat(p) // question mark.
				is_index_sig = is_token(p, .Colon)
				lexer_restore(p, snap)
			}
		}
		if is_index_sig {
			// Confirmed: index signature.
			param_start := cur_loc(p)
			param_name_tok := get_current(p)
			param_name_ident := new_node(p, Identifier)
			param_name_ident.loc = loc_from_token(&param_name_tok)
			param_name_ident.name = param_name_tok.value
			eat(p) // consume identifier
			if match_token(p, .Question) {
				report_error(p, "An index signature parameter cannot have a question mark.")
			}
			colon_start := cur_loc(p)  // position of `:` before key type.
			expect_token(p, .Colon)
			idx_ann := parse_ts_type(p)
			key_type_end := prev_end_offset(p)  // end of key type, before `]`.
			expect_token(p, .RBracket)
			val_ann: Maybe(^TSTypeAnnotation)
			if is_token(p, .Colon) {
				val_ann = parse_ts_type_annotation(p)
			} else {
				report_error(p, "An index signature must have a type annotation.")
			}

			idx_sig := TSIndexSignature{
				loc = start,
				parameters = make([dynamic]TSFunctionParam, 0, 1, p.allocator),
				type_annotation = val_ann,
				readonly = idx_readonly,
			}
			// Build the sole parameter with correct span: ends at key-type end.
			key_ann := new_node(p, TSTypeAnnotation)
			key_ann.loc.span.start = colon_start.span.start
			key_ann.loc.span.end   = key_type_end
			key_ann.type_annotation = idx_ann
			fp := TSFunctionParam{
				loc = param_start,
				pattern = param_name_ident,
				type_annotation = key_ann,
			}
			fp.loc.span.end = key_type_end
			bump_append(&idx_sig.parameters, fp)
			// Consume optional semi/comma inside the function so the span includes
			// the terminator (matching OXC). The caller also tries to match them
			// but match_token is idempotent when the token is already consumed.
			match_token(p, .Semi); match_token(p, .Comma)
			idx_sig.loc.span.end = prev_end_offset(p)

			sig := new_node(p, TSSignature)
			sig^ = idx_sig
			return sig
		}
		// Not an index signature - fall through as computed property.
		// We already consumed `[`, so set computed = true and parse the rest.
		key := parse_assignment_expression(p)
		expect_token(p, .RBracket)
		optional := match_token(p, .Question)

		// Check if it's a method signature after computed property.
		if is_token(p, .LParen) {
			sig := new_node(p, TSSignature)
			method := TSMethodSignature{loc = start, key = key, computed = true, optional = optional, kind = .Method}
			method.params = parse_ts_sig_params(p)
			if is_token(p, .Colon) { method.return_type = parse_ts_return_type_annotation(p) }
			method.loc.span.end = prev_end_offset(p)
			sig^ = method; return sig
		}

		// Property signature with computed property.
		sig := new_node(p, TSSignature)
		prop := TSPropertySignature{loc = start, key = key, computed = true, optional = optional, readonly = readonly}
		if is_token(p, .Colon) { prop.type_annotation = parse_ts_type_annotation(p) }
		prop.loc.span.end = prev_end_offset(p)
		sig^ = prop; return sig
	}

	// Handle readonly modifier for non-index-signature members.
	if idx_readonly {
		readonly = true
	}

	// Parse contextual get/set accessor signatures. `get` / `set` are also
	// valid property names, so only treat them as accessors when another
	// property key follows on the same member.
	nxt_allows_accessor := false
	if (p.lexer.nxt.flags & FLAG_NEW_LINE) == 0 {
		#partial switch p.lexer.nxt.kind {
		case .LParen, .Question, .Colon, .Semi, .Comma, .RBrace:
			// `get()`, `get?: T`, `set;` are members named get/set.
		case:
			nxt_allows_accessor = true
		}
	}
	if ((is_token(p, .Get) || is_token(p, .Set)) ||
	    (is_token(p, .Identifier) && (p.cur_tok.value == "get" || p.cur_tok.value == "set"))) &&
	   nxt_allows_accessor {
		accessor_kind := TSMethodSignatureKind.Get
		if is_token(p, .Set) || (is_token(p, .Identifier) && p.cur_tok.value == "set") {
			accessor_kind = .Set
		}
		eat(p) // consume get/set modifier.

		accessor_key: ^Expression
		accessor_computed := false
		if is_token(p, .LBracket) {
			accessor_computed = true
			eat(p)
			accessor_key = parse_assignment_expression(p)
			expect_token(p, .RBracket)
		} else if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
			cur := get_current(p)
			id := new_node(p, Identifier)
			id.loc = loc_from_token(&cur)
			id.name = cur.value
			accessor_key = expression_from(p, id)
			eat(p)
		} else if is_token(p, .String) {
			str := parse_string_literal(p)
			sn := new_node(p, StringLiteral)
			sn^ = str
			accessor_key = expression_from(p, sn)
		} else if is_token(p, .Number) {
			cur := get_current(p)
			nm := new_node(p, NumericLiteral)
			nm.loc = loc_from_token(&cur)
			nm.raw = cur.value
			if v, ok := cur.literal.(f64); ok { nm.value = v }
			accessor_key = expression_from(p, nm)
			eat(p)
		} else {
			return nil
		}

		if is_token(p, .LAngle) {
			report_error(p, "An accessor cannot have type parameters")
			_ = parse_ts_type_parameters(p)
		}
		params := parse_ts_sig_params(p)
		if accessor_kind == .Get {
			if len(params) != 0 {
				report_error(p, "A get accessor cannot have parameters")
			}
		} else {
			if len(params) != 1 {
				report_error(p, "A set accessor must have exactly one parameter")
			}
			if len(params) == 1 {
				if params[0].optional {
					report_error(p, "A set accessor parameter cannot be optional")
				}
				if _, is_rest := params[0].pattern.(^RestElement); is_rest {
					report_error(p, "A set accessor parameter cannot be a rest parameter")
				}
				if id, is_id := params[0].pattern.(^Identifier); is_id && id.name == "this" {
					report_error(p, "A set accessor cannot have a this parameter")
				}
			}
		}
		ret: Maybe(^TSTypeAnnotation)
		if is_token(p, .Colon) {
			ret = parse_ts_return_type_annotation(p)
			if accessor_kind == .Set {
				report_error(p, "A set accessor cannot have a return type annotation")
			}
		}
		method := TSMethodSignature{
			loc = start, key = accessor_key, computed = accessor_computed,
			optional = false, kind = accessor_kind, params = params, return_type = ret,
		}
		method.loc.span.end = prev_end_offset(p)
		sig := new_node(p, TSSignature)
		sig^ = method
		return sig
	}

	// Parse key for method or property signature.
	key: ^Expression; computed := false
	if is_token(p, .LBracket) {
		computed = true; eat(p); key = parse_assignment_expression(p); expect_token(p, .RBracket)
	} else if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
		cur := get_current(p); id := new_node(p, Identifier); id.loc = loc_from_token(&cur); id.name = cur.value
		key = expression_from(p, id); eat(p)
	} else if is_token(p, .String) {
		str := parse_string_literal(p); sn := new_node(p, StringLiteral); sn^ = str; key = expression_from(p, sn)
	} else if is_token(p, .Number) {
		cur := get_current(p); nm := new_node(p, NumericLiteral); nm.loc = loc_from_token(&cur); nm.raw = cur.value
		if v, ok := cur.literal.(f64); ok { nm.value = v }; key = expression_from(p, nm); eat(p)
	} else { return nil }
	optional := match_token(p, .Question)

	// Method signature: key is followed by `(` (or `<` for generics).
	if is_token(p, .LParen) {
		sig := new_node(p, TSSignature)
		method := TSMethodSignature{loc = start, key = key, computed = computed, optional = optional, kind = .Method}
		method.params = parse_ts_sig_params(p)
		if is_token(p, .Colon) { method.return_type = parse_ts_return_type_annotation(p) }
		method.loc.span.end = prev_end_offset(p)
		sig^ = method; return sig
	}

	// Property signature.
	sig := new_node(p, TSSignature)
	prop := TSPropertySignature{loc = start, key = key, computed = computed, optional = optional, readonly = readonly}
	if is_token(p, .Colon) { prop.type_annotation = parse_ts_type_annotation(p) }
	prop.loc.span.end = prev_end_offset(p)
	sig^ = prop; return sig
}

get_ts_type_loc :: proc(t: ^TSType) -> ^Loc {
	if t == nil { return nil }
	#partial switch v in t^ {
	case ^TSAnyKeyword: return &v.loc
	case ^TSNumberKeyword: return &v.loc
	case ^TSStringKeyword: return &v.loc
	case ^TSBooleanKeyword: return &v.loc
	case ^TSVoidKeyword: return &v.loc
	case ^TSNullKeyword: return &v.loc
	case ^TSNeverKeyword: return &v.loc
	case ^TSUnknownKeyword: return &v.loc
	case ^TSUndefinedKeyword: return &v.loc
	case ^TSObjectKeyword: return &v.loc
	case ^TSTypeReference: return &v.loc
	case ^TSUnionType: return &v.loc
	case ^TSIntersectionType: return &v.loc
	case ^TSArrayType: return &v.loc
	case ^TSIndexedAccessType: return &v.loc
	case ^TSLiteralType: return &v.loc
	case ^TSParenthesizedType: return &v.loc
	case ^TSTypeLiteral: return &v.loc
	case ^TSConditionalType: return &v.loc
	case ^TSMappedType: return &v.loc
	case ^TSTypeOperator: return &v.loc
	case ^TSFunctionType: return &v.loc
	case ^TSTupleType: return &v.loc
	case ^TSInferType: return &v.loc
	case ^TSTypeQuery: return &v.loc
	case ^TSTypePredicate: return &v.loc
	}
	return nil
}

// parse_ts_declare_statement handles `declare function|class|const|let|var|
// interface|type|enum|namespace|module ...`. The `declare` modifier just sets
// a flag on the resulting declaration node. Call it when current token is
// `.Declare`.
parse_ts_declare_statement :: proc(p: ^Parser) -> ^Statement {
	// Capture the `declare` keyword's start BEFORE eating so we can
	// widen the resulting declaration's span to include it. OXC's TS-ESTree
	// shape spans the whole `declare <decl>` phrase on the declaration
	// node; Kessel previously started at whatever followed `declare`,
	// drifting the span by `len("declare ")` bytes on every ambient form.
	declare_start := u32(cur_offset(p))
	eat(p) // consume `declare`

	// Everything under `declare` is ambient: const has no initializer
	// requirement, function has no body requirement, and any nested
	// namespace / module body inherits the same. Save/restore around
	// the whole dispatch so nested ambient contexts compose correctly.
	prev_ambient := p.in_ambient
	p.in_ambient = true
	defer p.in_ambient = prev_ambient

	// Dispatch to the right declaration parser and then set `declare=true`
	// on the returned node. Many of our declaration parsers return
	// ^Statement holding a ^SpecificDecl pointer; type-assert and mutate.
	stmt: ^Statement
	#partial switch p.cur_type {
	case .Function:
		stmt = parse_function_declaration(p, false, true) // allow_no_body=true for declare
		if stmt != nil {
			if fn, ok := stmt^.(^FunctionDeclaration); ok { fn.declare = true }
		}
	case .Async:
		// `declare async function foo(): Promise<void>;` (TS). The
		// inner parse_function_declaration already consumes a leading
		// `.Async` token before `function`, so we just need to allow the
		// no-body ambient form. allow_no_body=true.
		if p.lexer.nxt.kind == .Function && !p.cur_tok.had_line_terminator {
			stmt = parse_function_declaration(p, false, true)
			if stmt != nil {
				if fn, ok := stmt^.(^FunctionDeclaration); ok { fn.declare = true }
			}
		}
	case .Class:
		stmt = parse_class_declaration(p)
		if stmt != nil {
			if cls, ok := stmt^.(^ClassDeclaration); ok { cls.declare = true }
		}
	case .Abstract:
		if p.lexer.nxt.kind == .Class {
			if (p.lexer.nxt.flags & FLAG_NEW_LINE) != 0 {
				report_error(p, "Line terminator not permitted between 'abstract' and 'class'")
			}
			eat(p) // consume `abstract`
			stmt = parse_class_declaration(p)
			if stmt != nil {
				if cls, ok := stmt^.(^ClassDeclaration); ok {
					cls.expr.abstract = true
					cls.declare = true
				}
			}
		}
	case .Import:
		// `declare import X = N` - ambient import-equals. TSImportEqualsDeclaration
		// has no declare flag in ESTree; just parse it normally.
		import_start := cur_loc(p)
		eat(p) // consume `import`
		if p.cur_type == .Identifier && p.lexer != nil && p.lexer.nxt.kind == .Assign {
			stmt = parse_ts_import_equals(p, import_start, .Value)
		}
	case .Const:
		if is_next_identifier_value(p, "enum") {
			stmt = parse_ts_enum_declaration(p)
			if stmt != nil {
				if en, ok := stmt^.(^TSEnumDeclaration); ok { en.declare = true }
			}
		} else {
			stmt = parse_variable_declaration(p, nil, true, false, true) // is_declare=true
			if stmt != nil {
				if vd, ok := stmt^.(^VariableDeclaration); ok { vd.declare = true }
			}
		}
	case .Let, .Var:
		stmt = parse_variable_declaration(p, nil, true, false, true) // is_declare=true
		if stmt != nil {
			if vd, ok := stmt^.(^VariableDeclaration); ok { vd.declare = true }
		}
	case .Identifier:
		val := p.cur_tok.value
		switch val {
		case "interface":
			// Newline between `interface` and its name triggers ASI.
			// `declare interface\nFoo {}` → error. OXC / TSC agree.
			if (p.lexer.nxt.flags & FLAG_NEW_LINE) != 0 {
				report_error(p, "Line terminator not permitted after 'interface'")
			}
			stmt = parse_ts_interface_declaration(p)
			if stmt != nil {
				if id, ok := stmt^.(^TSInterfaceDeclaration); ok { id.declare = true }
			}
		case "type":
			// Newline between `type` and its name triggers ASI.
			if (p.lexer.nxt.flags & FLAG_NEW_LINE) != 0 {
				report_error(p, "Line terminator not permitted after 'type'")
			}
			if is_next_token(p, .Identifier) {
				stmt = parse_ts_type_alias_declaration(p)
				if stmt != nil {
					if ta, ok := stmt^.(^TSTypeAliasDeclaration); ok { ta.declare = true }
				}
			}
		case "enum":
			stmt = parse_ts_enum_declaration(p)
			if stmt != nil {
				if en, ok := stmt^.(^TSEnumDeclaration); ok { en.declare = true }
			}
		// `declare` span widening for this branch handled at the bottom
		// alongside the other cases (see end of proc).
		case "namespace":
			// Newline between `namespace` and its name triggers ASI.
			if (p.lexer.nxt.flags & FLAG_NEW_LINE) != 0 {
				report_error(p, "Line terminator not permitted after 'namespace'")
			}
			if is_next_token(p, .Identifier) {
				stmt = parse_ts_module_declaration(p, .Namespace)
				if stmt != nil {
					if mod, ok := stmt^.(^TSModuleDeclaration); ok { mod.declare = true }
				}
			}
		case "module":
			// `declare module "name" {}` (string literal) or
			// `declare module Identifier {}` (ambient namespace).
			// Newline between `module` and its name triggers ASI.
			if (p.lexer.nxt.flags & FLAG_NEW_LINE) != 0 {
				report_error(p, "Line terminator not permitted after 'module'")
			}
			if is_next_token(p, .String) || is_next_token(p, .Identifier) || is_keyword_usable_as_property_name(p.lexer.nxt.kind) {
				stmt = parse_ts_module_declaration(p, .Module)
				if stmt != nil {
					if mod, ok := stmt^.(^TSModuleDeclaration); ok { mod.declare = true }
				}
			}
		case "global":
			// `declare global { ... }` - TS global augmentation. Unlike
			// `namespace X` / `module "x"`, the keyword IS the id (always
			// the literal identifier `global`) and there's no dotted form,
			// so we build the TSModuleDeclaration inline rather than
			// reusing parse_ts_module_declaration which eats one keyword
			// then expects a separate name token.
			if is_next_token(p, .LBrace) {
				stmt = parse_ts_global_declaration(p)
				if stmt != nil {
					if mod, ok := stmt^.(^TSModuleDeclaration); ok {
						mod.declare = true
						mod.global = true
					}
				}
			}
		}
	}

	if stmt == nil {
		report_error(p, "Expected declaration after 'declare'")
		return stmt
	}

	// Widen the resulting declaration's span so it starts at `declare`.
	// Every declaration variant returned above carries its own `loc` on the
	// inner pointer; find and overwrite span.start in place.
	#partial switch inner in stmt^ {
	case ^FunctionDeclaration:    inner.loc.span.start = declare_start
	case ^ClassDeclaration:       inner.expr.loc.span.start = declare_start
	case ^VariableDeclaration:    inner.loc.span.start = declare_start
	case ^TSEnumDeclaration:      inner.loc.span.start = declare_start
	case ^TSInterfaceDeclaration: inner.loc.span.start = declare_start
	case ^TSTypeAliasDeclaration: inner.loc.span.start = declare_start
	case ^TSModuleDeclaration:    inner.loc.span.start = declare_start
	}
	return stmt
}

// Parse the heritage list after `extends` (interface) or `implements`
// (class). Each entry is a `typeName [<typeArgs>]` pair where `typeName`
// may be a qualified member chain (`ns.Foo.Bar`). Shape matches OXC's
// `TSInterfaceHeritage` / `TSClassImplements` deep structure (expression
// + typeArguments). Previously interface-extends wasn't consumed at all,
// and the next iteration of the interface-body loop saw neither `}` nor
// a recognisable member, looping forever on any input like
// `interface A extends B {}`. Same heritage grammar is reused by
// `class X implements Y, Z` (see parse_class_declaration).
parse_ts_heritage_list :: proc(p: ^Parser) -> [dynamic]TSInterfaceHeritage {
	out := make([dynamic]TSInterfaceHeritage, 0, 2, p.allocator)
	for {
		entry_start := cur_loc(p)
		if !is_token(p, .Identifier) && !is_keyword_usable_as_property_name(p.cur_type) {
			break
		}
		tok := get_current(p)
		id := new_node(p, Identifier); id.loc = loc_from_token(&tok); id.name = tok.value; eat(p)
		expr := expression_from(p, id)
		for is_token(p, .Dot) {
			eat(p)
			prop := parse_identifier_name(p)
			mem := new_node(p, MemberExpression); mem.loc = entry_start; mem.object = expr
			pid := new_node(p, Identifier); pid.loc = prop.loc; pid.name = prop.name
			mem.property = expression_from(p, pid); mem.loc.span.end = prev_end_offset(p)
			expr = expression_from(p, mem)
		}
		type_args: Maybe(^TSTypeParameterInstantiation)
		if is_open_angle_or_lshift(p) { type_args = parse_ts_type_arguments(p) }
		entry_end := prev_end_offset(p)
		h := TSInterfaceHeritage{
			loc = Loc{span = Span{start = entry_start.span.start, end = entry_end}},
			expression = expr,
			type_parameters = type_args,
		}
		bump_append(&out, h)
		if !match_token(p, .Comma) { break }
	}
	return out
}

parse_ts_interface_declaration :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p); eat(p)
	cur := get_current(p)
	id := BindingIdentifier{loc = loc_from_token(&cur), name = cur.value}; eat(p)
	type_parameters: Maybe(^TSTypeParameterDeclaration)
	if is_token(p, .LAngle) { type_parameters = parse_ts_type_parameters(p) }
	extends_list: [dynamic]TSInterfaceHeritage
	if match_token(p, .Extends) {
		extends_list = parse_ts_heritage_list(p)
		if len(extends_list) == 0 {
			report_error(p, "Expected interface name after 'extends'")
		}
	}
	body_start := cur_loc(p)  // position of `{`
	expect_token(p, .LBrace)
	members := make([dynamic]^TSSignature, 0, 8, p.allocator)
	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		prev_member_off := cur_offset(p)
		sig := parse_ts_object_member(p); if sig != nil { bump_append(&members, sig) }
		// Extend the member's span to cover its trailing `;` or `,` - OXC
		// includes the terminator in the TSPropertySignature/TSMethodSignature
		// span, but `parse_ts_object_member` returns before we consume it
		// here. Without this widen, every interface member reports `end` one
		// byte short of OXC (`items: Array<T>;` - Kessel 408, OXC 409).
		has_term := is_token(p, .Semi) || is_token(p, .Comma)
		match_token(p, .Semi); match_token(p, .Comma)
		if has_term && sig != nil {
			set_ts_sig_end(sig, prev_end_offset(p))
		}
		// Progress guard - matches the same pattern we use in
		// parse_jsx_children and elsewhere. If a member parse neither
		// consumes a token nor hits a recognised terminator, break to
		// avoid an O(∞) loop on malformed input.
		if cur_offset(p) == prev_member_off { break }
	}
	expect_token(p, .RBrace)
	decl := new_node(p, TSInterfaceDeclaration); decl.loc = start; decl.id = id; decl.type_parameters = type_parameters
	decl.extends = extends_list
	decl.body = TSInterfaceBody{loc = body_start, body = members}; decl.body.loc.span.end = prev_end_offset(p)
	decl.loc.span.end = prev_end_offset(p)
	stmt := new_node(p, Statement); stmt^ = decl; return stmt
}

parse_ts_type_alias_declaration :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p); eat(p)
	cur := get_current(p)
	id := BindingIdentifier{loc = loc_from_token(&cur), name = cur.value}; eat(p)
	type_parameters: Maybe(^TSTypeParameterDeclaration)
	if is_token(p, .LAngle) { type_parameters = parse_ts_type_parameters(p) }
	expect_token(p, .Assign)
	type_ann := parse_ts_type(p)
	match_semicolon_or_asi(p)
	decl := new_node(p, TSTypeAliasDeclaration); decl.loc = start; decl.id = id; decl.type_parameters = type_parameters; decl.type_annotation = type_ann
	decl.loc.span.end = prev_end_offset(p)
	stmt := new_node(p, Statement); stmt^ = decl; return stmt
}

parse_ts_enum_declaration :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	is_const := false
	if is_token(p, .Const) { is_const = true; eat(p) }
	eat(p)
	cur := get_current(p)
	if !can_be_binding_identifier(p.cur_type) {
		msg := fmt.tprintf(
			"Identifier expected. '%s' is a reserved word that cannot be used here.",
			cur.value,
		)
		report_error(p, msg)
	}
	id := BindingIdentifier{loc = loc_from_token(&cur), name = cur.value}; eat(p)
	body_start := cur_loc(p); expect_token(p, .LBrace)
	members := make([dynamic]TSEnumMember, 0, 8, p.allocator)
	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		// Reject empty enum member positions: `enum E { , }`.
		if is_token(p, .Comma) {
			report_error(p, "Expected enum member name")
			eat(p)
			continue
		}
		// Private names are not valid enum member names.
		if is_token(p, .PrivateIdentifier) {
			report_error(p, "An enum member cannot have a private name")
		}
		ms := cur_loc(p); member_id: ^Expression; mc := get_current(p)
		if is_token(p, .String) {
			str := parse_string_literal(p); sn := new_node(p, StringLiteral); sn^ = str; member_id = expression_from(p, sn)
		} else if is_token(p, .Number) || is_token(p, .BigInt) {
			report_error(p, "An enum member cannot have a numeric name.")
			mid := new_node(p, Identifier); mid.loc = loc_from_token(&mc); mid.name = mc.value; eat(p)
			member_id = expression_from(p, mid)
		} else {
			mid := new_node(p, Identifier); mid.loc = loc_from_token(&mc); mid.name = mc.value; eat(p)
			member_id = expression_from(p, mid)
		}
		init: Maybe(^Expression)
		if match_token(p, .Assign) {
			prev_in_async := p.in_async
			prev_in_generator := p.in_generator
			p.in_async = false
			p.in_generator = false
			init = parse_assignment_expression(p)
			p.in_generator = prev_in_generator
			p.in_async = prev_in_async
		}
		m := TSEnumMember{loc = ms, id = member_id, initializer = init}; m.loc.span.end = prev_end_offset(p)
		bump_append(&members, m)
		if !match_token(p, .Comma) { break }
	}
	expect_token(p, .RBrace)
	decl := new_node(p, TSEnumDeclaration); decl.loc = start; decl.id = id
	decl.body = TSEnumBody{loc = body_start, members = members}; decl.body.loc.span.end = prev_end_offset(p)
	decl.const_ = is_const; decl.loc.span.end = prev_end_offset(p)
	stmt := new_node(p, Statement); stmt^ = decl; return stmt
}

// `declare global { ... }`. Caller has already eaten `declare`; current
// token is the identifier `global` and the lookahead has confirmed `{`.
// Produces a TSModuleDeclaration with kind=.Global and id=Identifier{"global"}.
// Body parsing mirrors parse_ts_module_declaration's brace-block branch
// (ambient context, progress-guarded statement loop, span widening).
parse_ts_global_declaration :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	cur := get_current(p)
	id_ident := new_node(p, Identifier); id_ident.loc = loc_from_token(&cur); id_ident.name = cur.value
	eat(p) // consume `global`

	decl := new_node(p, TSModuleDeclaration)
	decl.loc = start
	decl.id = expression_from(p, id_ident)
	decl.kind = .Global

	body_start := cur_loc(p); eat(p) // consume `{` (lookahead-confirmed)
	stmts := make([dynamic]^Statement, 0, 8, p.allocator)
	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		// Same progress guard as parse_ts_module_declaration (W6 phase 3 #1).
		prev_offset := int(cur_offset(p))
		s := parse_statement_or_declaration(p)
		if s != nil { bump_append(&stmts, s) }
		else if int(cur_offset(p)) == prev_offset {
			msg := fmt.tprintf("Unexpected token '%s' in module body", cur_value(p))
			report_error(p, msg)
			eat(p)
		}
	}
	expect_token(p, .RBrace)
	blk := new_node(p, TSModuleBlock)
	blk.loc = body_start; blk.body = stmts
	blk.loc.span.end = prev_end_offset(p)
	body_union := new_node(p, TSModuleBody); body_union^ = blk
	decl.body = body_union
	decl.loc.span.end = prev_end_offset(p)
	stmt := new_node(p, Statement); stmt^ = decl; return stmt
}

parse_ts_module_declaration :: proc(p: ^Parser, kind: TSModuleKind) -> ^Statement {
	start := cur_loc(p); eat(p) // consume `namespace` or `module`

	// Name: Identifier (possibly dotted) or StringLiteral.
	// A string-named `module "x" { ... }` is ALWAYS an ambient declaration
	// (per TS semantics): every declaration inside behaves as if prefixed
	// with `declare`. Track this so parse_variable_declarator and
	// parse_function_declaration can relax their body / initializer
	// requirements for the duration of the body scan.
	is_string_named := is_token(p, .String)
	id_expr: ^Expression
	if is_string_named {
		lit := parse_string_literal(p)
		sn := new_node(p, StringLiteral); sn^ = lit
		id_expr = expression_from(p, sn)
	} else {
		cur := get_current(p)
		id_ident := new_node(p, Identifier); id_ident.loc = loc_from_token(&cur); id_ident.name = cur.value
		eat(p)
		id_expr = expression_from(p, id_ident)
	}

	// Handle `namespace A.B.C { ... }` - produce nested TSModuleDeclarations.
	// If we see `.`, the current `id_expr` is the OUTER name and we'll
	// recurse to build the inner nested declaration as the body.
	if is_token(p, .Dot) {
		eat(p) // consume `.`
		inner := parse_ts_module_tail(p, cur_loc(p), kind)
		outer := new_node(p, TSModuleDeclaration)
		outer.loc = start; outer.id = id_expr
		outer.kind = kind
		// Wrap inner as module body (TSModuleBody union variant).
		if inner != nil {
			body_union := new_node(p, TSModuleBody)
			body_union^ = inner
			outer.body = body_union
		}
		outer.loc.span.end = prev_end_offset(p)
		stmt := new_node(p, Statement); stmt^ = outer; return stmt
	}

	// Optional body `{ ... }`. A `declare` context can elide it (`declare namespace X;`),
	// but that's H4 territory; REQUIRE the block here.
	decl := new_node(p, TSModuleDeclaration)
	decl.loc = start; decl.id = id_expr; decl.kind = kind
	if is_token(p, .LBrace) {
		body_start := cur_loc(p); eat(p) // consume `{`
		// Ambient context: string-named module, OR already-ambient caller
		// (nested namespace / module inside a `declare namespace X { ... }`).
		prev_ambient := p.in_ambient
		p.in_ambient = p.in_ambient || is_string_named
		defer p.in_ambient = prev_ambient
		// TS namespace body is not an async/module-level context for `await`.
		prev_in_ts_namespace := p.in_ts_namespace
		p.in_ts_namespace = true
		defer p.in_ts_namespace = prev_in_ts_namespace
		stmts := make([dynamic]^Statement, 0, 8, p.allocator)
		for !is_token(p, .RBrace) && !is_token(p, .EOF) {
			// Progress guard: when parse_statement_or_declaration hits an
			// unsupported TS form (e.g. `import X = Y;` import-equals) it can
			// return nil without advancing. Mirror parse_program_item's
			// recovery: report the offending token, force-eat one. Without
			// this, a single `import X = Y;` inside `namespace M { ... }`
			// loops the parser forever (S26 W6 phase 3 bug class #1; this
			// alone closed 146 typescript/compiler timeouts).
			prev_offset := int(cur_offset(p))
			s := parse_statement_or_declaration(p)
			if s != nil { bump_append(&stmts, s) }
			else if int(cur_offset(p)) == prev_offset {
				msg := fmt.tprintf("Unexpected token '%s' in module body", cur_value(p))
				report_error(p, msg)
				eat(p)
			}
		}
		expect_token(p, .RBrace)
		blk := new_node(p, TSModuleBlock)
		blk.loc = body_start; blk.body = stmts
		blk.loc.span.end = prev_end_offset(p)
		body_union := new_node(p, TSModuleBody)
		body_union^ = blk
		decl.body = body_union
	}
	decl.loc.span.end = prev_end_offset(p)
	stmt := new_node(p, Statement); stmt^ = decl; return stmt
}

// Parse the name + body portion of a nested namespace declaration.
// Called AFTER the outer `.` is consumed, so current token is the next name.
parse_ts_module_tail :: proc(p: ^Parser, start: Loc, kind: TSModuleKind) -> ^TSModuleDeclaration {
	cur := get_current(p)
	id_ident := new_node(p, Identifier); id_ident.loc = loc_from_token(&cur); id_ident.name = cur.value
	eat(p)
	id_expr := expression_from(p, id_ident)

	decl := new_node(p, TSModuleDeclaration)
	decl.loc = start; decl.id = id_expr; decl.kind = kind

	if is_token(p, .Dot) {
		eat(p)
		inner := parse_ts_module_tail(p, cur_loc(p), kind)
		if inner != nil {
			body_union := new_node(p, TSModuleBody)
			body_union^ = inner
			decl.body = body_union
		}
	} else if is_token(p, .LBrace) {
		body_start := cur_loc(p); eat(p)
		// Nested module bodies inherit the ambient context from the outer
		// call - same save/restore idiom as parse_ts_module_declaration.
		prev_ambient := p.in_ambient
		defer p.in_ambient = prev_ambient
		// Also propagate in_ts_namespace into the nested body. Without
		// this, `namespace Outer.Inner { export const X = 1 }` would let
		// the `export` decision run with in_ts_namespace=false and
		// incorrectly classify the file as sourceType=module. The outer
		// parse_ts_module_declaration sets the flag for the SINGLE-name
		// case but the dotted-name path skips it.
		prev_in_ts_namespace := p.in_ts_namespace
		p.in_ts_namespace = true
		defer p.in_ts_namespace = prev_in_ts_namespace
		stmts := make([dynamic]^Statement, 0, 8, p.allocator)
		for !is_token(p, .RBrace) && !is_token(p, .EOF) {
			// Same progress guard as parse_ts_module_declaration's body loop -
			// nested namespaces (`namespace A.B.C { ... }` / `module M.N { ... }`)
			// hit the same hang shape on unsupported TS forms.
			prev_offset := int(cur_offset(p))
			s := parse_statement_or_declaration(p)
			if s != nil { bump_append(&stmts, s) }
			else if int(cur_offset(p)) == prev_offset {
				msg := fmt.tprintf("Unexpected token '%s' in module body", cur_value(p))
				report_error(p, msg)
				eat(p)
			}
		}
		expect_token(p, .RBrace)
		blk := new_node(p, TSModuleBlock)
		blk.loc = body_start; blk.body = stmts
		blk.loc.span.end = prev_end_offset(p)
		body_union := new_node(p, TSModuleBody)
		body_union^ = blk
		decl.body = body_union
	}
	decl.loc.span.end = prev_end_offset(p)
	return decl
}

// ============================================================================
// Utility Functions
// ============================================================================

// Fast accessors - read directly from FastToken/cur_tok, no Token struct copy
cur_offset :: #force_inline proc(p: ^Parser) -> u32 {
	if p.lexer != nil {
		return p.lexer.cur.start
	}
	return u32(p.cur_tok.loc)
}

// prev_end_offset returns the end offset of the LAST consumed token. Use this
// for `loc.span.end` to match ESTree/OXC/Acorn/Babel span semantics, which
// END a node at the last character of its last token - excluding any trailing
// whitespace, newlines, or comments that precede the NEXT token.
//
// Example: for `export * from "./a";\nconst x = 1;`, the ExportAllDeclaration
// must span [0, 20) - through the `;`, not including the `\n`. `cur_offset`
// after parsing the export would be 21 (start of `const`); `prev_end_offset`
// correctly returns 20.
prev_end_offset :: #force_inline proc(p: ^Parser) -> u32 {
	return p.prev_token_end
}

cur_value :: #force_inline proc(p: ^Parser) -> string {
	if p.lexer != nil {
		ft := p.lexer.cur
		// Escaped identifier - prefer the cooked (decoded) name published
		// by lex_identifier_escaped via cur_lit_value. ECMA-262 §12.7.2
		// requires the identifier's logical name to be the decoded text,
		// not the \uXXXX source. Guarded by flag so the non-escape hot
		// path stays a single source slice.
		if ft.kind == .Identifier && (ft.flags & FLAG_HAS_ESCAPE) != 0 {
			if p.lexer.cur_lit_offset == ft.start && p.lexer.cur_lit_type == .Identifier {
				if s, ok := p.lexer.cur_lit_value.(string); ok { return s }
			}
		}
		if ft.start < ft.end { return p.lexer.source[ft.start:ft.end] }
		return ""
	}
	return p.cur_tok.value
}

cur_loc :: #force_inline proc(p: ^Parser) -> Loc {
	if p.lexer != nil {
		ft := p.lexer.cur
		return Loc{
			span = Span{start = ft.start, end = ft.end},
		}
	}
	return loc_from_token(&p.cur_tok)
}

loc_from_token :: #force_inline proc(t: ^Token) -> Loc {
	// Prefer t.raw_end: it's the true source-byte end from the FastToken,
	// which is correct even when .value has been replaced by the cooked
	// identifier name (escaped identifiers: source `C\u00e9` occupies 7 bytes
	// but cooked .value is 3 bytes UTF-8 - computing end from `offset +
	// len(value)` underestimated by 4, breaking span comparisons against OXC
	// for every \uXXXX identifier).
	//
	// Fall back to the old `offset + len(value)` for Tokens that predate
	// raw_end population (raw_end stays 0 until set by advance_token /
	// prime_token_cache / peek_token). This keeps the compile-time zero-init
	// safe for synthetic Tokens constructed outside the lexer pipeline.
	//
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
	return Loc{
		span   = Span{
			start = u32(t.loc),
			end   = end,
		},
	}
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
set_expr_start :: proc(e: ^Expression, start: u32) {
	if e == nil { return }
	loc := get_expr_loc_ptr(e)
	if loc != nil { loc.span.start = start }
}

set_expr_end :: proc(e: ^Expression, end: u32) {
	if e == nil { return }
	loc := get_expr_loc_ptr(e)
	if loc != nil { loc.span.end = end }
}

get_expr_loc_ptr :: proc(e: ^Expression) -> ^Loc {
	if e == nil { return nil }
	#partial switch v in e {
	case ^Identifier:              return &v.loc
	case ^NumericLiteral:           return &v.loc
	case ^StringLiteral:            return &v.loc
	case ^BooleanLiteral:           return &v.loc
	case ^NullLiteral:              return &v.loc
	case ^ThisExpression:            return &v.loc
	case ^Super:                     return &v.loc
	case ^ArrayExpression:           return &v.loc
	case ^ObjectExpression:          return &v.loc
	case ^FunctionExpression:        return &v.loc
	case ^ArrowFunctionExpression:   return &v.loc
	case ^MemberExpression:          return &v.loc
	case ^CallExpression:            return &v.loc
	case ^NewExpression:             return &v.loc
	case ^ConditionalExpression:     return &v.loc
	case ^UnaryExpression:           return &v.loc
	case ^BinaryExpression:          return &v.loc
	case ^LogicalExpression:         return &v.loc
	case ^AssignmentExpression:      return &v.loc
	case ^UpdateExpression:          return &v.loc
	case ^SpreadElement:             return &v.loc
	case ^YieldExpression:           return &v.loc
	case ^AwaitExpression:           return &v.loc
	case ^ImportExpression:          return &v.loc
	case ^MetaProperty:              return &v.loc
	case ^BigIntLiteral:             return &v.loc
	case ^RegExpLiteral:             return &v.loc
	case ^TemplateLiteral:           return &v.loc
	case ^TaggedTemplateExpression:  return &v.loc
	case ^SequenceExpression:        return &v.loc
	case ^ClassExpression:           return &v.loc
	case ^PrivateIdentifier:         return &v.loc
	case ^ChainExpression:           return &v.loc
	case ^ParenthesizedExpression:   return &v.loc
	}
	return nil
}

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
