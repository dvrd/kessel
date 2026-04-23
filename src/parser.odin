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
		// current token BEFORE this advance — after the swap it will be gone.
		// `prev_token_end` lets `prev_end_offset` return the end of the last
		// consumed meaningful token (excluding trailing whitespace/comments),
		// which matches OXC/Acorn/Babel span semantics.
		p.prev_token_end = a.cur.end
		a.cur = a.nxt
		// Snapshot the literal slot that was written when a.nxt (now a.cur)
		// was lexed on the previous advance. The upcoming lex_token for the
		// NEW a.nxt will overwrite last_lit_* — we must capture it first or
		// we'll lose the cooked value and fall back to raw source for cur
		// (broke any string-with-escape followed by another cooking literal,
		// e.g. a string inside template `${...}`).
		a.cur_lit_offset = a.last_lit_offset
		a.cur_lit_value  = a.last_lit_value
		a.cur_lit_type   = a.last_lit_type
		if a.cur.kind != .EOF {
			a.nxt = lex_token(a)
		} else {
			a.nxt = token_eof(u32(a.offset))
		}
		ft := a.cur
		p.cur_type = ft.kind
		p.cur_tok.type = ft.kind
		p.cur_tok.loc.offset = int(ft.start)
		// Branchless: always write (avoids conditional branch per token)
		p.cur_tok.had_line_terminator = (ft.flags & FLAG_NEW_LINE) != 0
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
				// Escaped identifier — override the raw span with the cooked
				// (decoded) name published by lex_identifier_escaped. The raw
				// span is still the source text including \uXXXX; only the .value
				// used for AST emission changes. Mirrored in prime_token_cache
				// and cur_value (the hot-path read site).
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
		tok.loc.offset = int(ft.start)
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
		p.cur_tok.loc.offset = int(ft.start)
		p.cur_tok.had_line_terminator = (ft.flags & FLAG_NEW_LINE) != 0
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
// Bump allocator — zero-dispatch arena for AST node allocations
// ============================================================================

BumpPool :: struct {
	base:           [^]u8,
	offset:         int,
	capacity:       int,
	overflow_count: int,  // Track fallbacks to backing allocator
}

bump_init :: proc(pool: ^BumpPool, backing: mem.Allocator, capacity: int) {
	raw, _ := mem.alloc_bytes(capacity, 16, backing)
	pool.base = raw_data(raw)
	pool.offset = 0
	pool.capacity = capacity
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

// Parser represents the recursive descent parser
Parser :: struct {
	// Lexer reference (per-parser, thread-safe for parallel parsing)
	lexer: ^Lexer,

	// Cached current token — updated ONLY by advance_token()
	cur_tok:  Token,
	cur_type: TokenType,

	// End offset of the LAST consumed token. Used by `prev_end_offset` to
	// produce ESTree-correct span.end values that don't include trailing
	// whitespace or comments (which `cur_offset` would include because it
	// returns the start of the NEXT token). Updated at the top of
	// `advance_token` before the cur/nxt swap.
	prev_token_end: u32,

	// Remembered `(` position for arrow-function parameter parens — used
	// when a parenthesized expression turns out to be arrow-function
	// parameters. ESTree spans the full `(x, y) => ...` starting AT the
	// opening paren, not at the first parameter. Set by parse_primary_expr
	// when it opens a `(` that could be an arrow param list; consumed (and
	// cleared) by parse_arrow_function. max(u32) = "unset" sentinel so
	// position 0 (file start) is a valid stamped value.
	pending_paren_start: u32,

	// Token length (always set, even for punctuation where .value is skipped)
	cur_len: u16,

	// Allocator for AST allocations (used for [dynamic] arrays)
	allocator: mem.Allocator,

	// Source length — used for pre-sizing heuristics
	source_len: int,

	// Fast bump pool for AST nodes (bypasses allocator dispatch)
	node_pool: BumpPool,

	// Error handling
	errors: [dynamic]ParseError,

	// String interner for identifiers
	interner: ^StringInterner,

	// Context flags
	in_function:     bool,
	in_generator:    bool,
	in_async:        bool,
	in_loop:         bool,
	in_switch:       bool,
	strict_mode:     bool,

	// Language mode — controls JSX / TS syntax admissibility.
	//   .JS  : plain JavaScript. `<` at expression start → syntax error.
	//   .JSX : JS + JSX. `<` at expression start → JSX element.
	//   .TS  : TypeScript, no JSX. `<` at expression start → type
	//          assertion `<Type>expr` or generic arrow `<T>(x)=>x`.
	//   .TSX : TS + JSX. `<` is ambiguous; OXC rule: assertion is
	//          forbidden, generic arrow requires trailing comma.
	lang:            Lang,

	// Disallow 'in' as binary operator (for for-loop init parsing)
	no_in:           bool,

	// CLI `--source-type` override. When set, disables the auto-upgrade
	// from Script to Module that parse_program normally performs when it
	// sees top-level import / export / import.meta. The caller passes the
	// requested SourceType directly to parse_program; this flag just tells
	// parse_program to leave it alone. nil = unambiguous (auto-detect).
	force_source_type: Maybe(SourceType),

	// Inside an ambient TS module / namespace body: every declaration is
	// implicitly `declare`-modified. Matches `declare module "x" { ... }`
	// semantics and also the string-named `module "x" { ... }` shortcut
	// (always ambient, no explicit declare needed). Propagates through
	// nested modules. Saved/restored around the body scan.
	in_ambient:      bool,

	// Track if module syntax was detected (import/export or import.meta)
	has_module_syntax: bool,

	// ESM module record arrays (populated when module-record flag is enabled)
	staticImports:  [dynamic]ESMStaticImport,
	staticExports:  [dynamic]ESMStaticExport,
	dynamicImports: [dynamic]ESMDynamicImport,
	importMetas:    [dynamic]ESMImportMeta,

	// Position tracking
	last_pos:        LexerLoc,

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

// Maximum iterations for error recovery to prevent infinite loops
MAX_ERROR_RECOVERY_ITERATIONS :: 10000

// Initialize string interner — map allocated lazily on first intern() call
init_interner :: proc(i: ^StringInterner, alloc: mem.Allocator, capacity_hint: int = 0) {
	i.allocator = alloc
	i.capacity_hint = capacity_hint
	// Map NOT allocated here — deferred to first intern() call
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
	JSX,  // JavaScript + JSX — legacy Kessel default
	TS,   // TypeScript, no JSX
	TSX,  // TypeScript + JSX
}

// Helpers — branch once on lang, let the compiler inline.
allow_jsx_mode :: #force_inline proc(p: ^Parser) -> bool {
	return p.lang == .JSX || p.lang == .TSX
}

allow_ts_mode :: #force_inline proc(p: ^Parser) -> bool {
	return p.lang == .TS || p.lang == .TSX
}

init_parser :: proc(p: ^Parser, lexer: ^Lexer, alloc: mem.Allocator, lang: Lang = .JSX) {
	p.allocator = alloc
	p.source_len = len(lexer.source)
	p.errors = make([dynamic]ParseError, alloc)

	// Bump pool: scale with source size
	// Small files (<64KB): tight pool to avoid wasting init time on mmap
	// Large files: 15× source for dense code (antd patterns)
	pool_size := p.source_len * 15
	if pool_size < 256 * 1024 {
		pool_size = max(p.source_len * 20, 4096)  // Tiny files: minimal pool
	}
	bump_init(&p.node_pool, alloc, pool_size)

	p.in_function = false
	p.in_generator = false
	p.in_async = false
	p.in_loop = false
	p.in_switch = false
	p.strict_mode = false
	p.lang = lang
	p.has_module_syntax = false
	p.pending_paren_start = max(u32) // sentinel: "no `(` pending"

	// Initialize interner — pre-allocate capacity based on source size
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
	// Memory from virtual arena is pre-zeroed by OS — skip explicit zero-init
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
new_expr :: #force_inline proc(p: ^Parser, $T: typeid) -> (^T, ^Expression) {
	// Try to alloc both in one bump region (node then wrapper, contiguous)
	total_size := size_of(T) + size_of(Expression)
	align := max(align_of(T), align_of(Expression))
	ptr := bump_alloc(&p.node_pool, total_size, align)
	if ptr != nil {
		node := transmute(^T)ptr
		wrap_ptr := rawptr(uintptr(ptr) + uintptr(size_of(T)))
		wrap_aligned := (uintptr(wrap_ptr) + uintptr(align_of(Expression) - 1)) & ~uintptr(align_of(Expression) - 1)
		wrap := transmute(^Expression)wrap_aligned
		wrap^ = node
		return node, wrap
	}
	node, _ := mem.new(T, p.allocator)
	expr := new_node(p, Expression)
	expr^ = node
	return node, expr
}

new_stmt :: #force_inline proc(p: ^Parser, $T: typeid) -> (^T, ^Statement) {
	total_size := size_of(T) + size_of(Statement)
	align := max(align_of(T), align_of(Statement))
	ptr := bump_alloc(&p.node_pool, total_size, align)
	if ptr != nil {
		node := transmute(^T)ptr
		wrap_aligned := (uintptr(ptr) + uintptr(size_of(T)) + uintptr(align_of(Statement) - 1)) & ~uintptr(align_of(Statement) - 1)
		wrap := transmute(^Statement)wrap_aligned
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
report_error :: proc(p: ^Parser, message: string) {
	loc := LexerLoc{offset = int(cur_offset(p))}
	// Compute line/col lazily from line table (only on errors)
	if p.lexer != nil && loc.line == 0 {
		// Lazy line table build — only on first error
		if p.lexer.num_lines == 0 {
			build_line_table(p.lexer)
		}
		line, col := offset_to_line_col(p.lexer.line_offsets, u32(loc.offset))
		loc.line = int(line)
		loc.column = int(col)
	}
	err := ParseError{
		loc     = loc,
		message = message,
	}
	append(&p.errors, err)
	if p.profile_enabled {
		p.profile.errors_reported += 1
	}
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

// Advance without returning old token — avoids 58-byte struct copy
// Use for match_token and discard sites where old token isn't needed
skip_token :: #force_inline proc(p: ^Parser) {
	advance_token(p)
}

// Check if current token matches type — zero cost, just a field read
is_token :: #force_inline proc(p: ^Parser, t: TokenType) -> bool {
	return p.cur_type == t
}

// Check if next token matches type — reads from nxt (no indirection)
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

// Consume current token (return value rarely used — prefer skip_token path)
eat :: #force_inline proc(p: ^Parser) {
	advance_token(p)
}

// Get current token — just return cached
get_current :: #force_inline proc(p: ^Parser) -> Token {
	return p.cur_tok
}

// ============================================================================
// Automatic Semicolon Insertion (ASI)
// ============================================================================

// can_insert_semicolon checks if ASI is allowed according to ECMAScript spec
// Rule 1: Token preceded by line terminator, or token is } or EOF
// Special case: Don't insert semicolon if next line starts with [, (, `, +, -, /, or .
// as these indicate expression continuation
can_insert_semicolon :: #force_inline proc(p: ^Parser) -> bool {
	// Check if current token had a line terminator before it
	if p.cur_tok.had_line_terminator {
		// Check for tokens that indicate expression continuation (no ASI)
		#partial switch p.cur_type {
		case .LBracket, .LParen, .Template, .TemplateHead, .Plus, .Minus, .Div, .Dot:
			return false
		}
		return true
	}

	// Check if current token is RBrace or EOF
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

// match_semicolon_or_asi tries to match a semicolon or allows ASI (for optional cases)
match_semicolon_or_asi :: #force_inline proc(p: ^Parser) -> bool {
	if p.cur_type == .Semi {
		advance_token(p)
		return true
	}
	return can_insert_semicolon(p)
}

// ============================================================================
// Entry Point - Parse Program
// ============================================================================

parse_program_item :: proc(p: ^Parser, body: ^[dynamic]^Statement, start_offset: int) {
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

		// Error recovery: we are stuck - consume tokens aggressively
		// Skip until we find a statement boundary or EOF
		stuck_count := 0
		for !is_token(p, .EOF) && int(cur_offset(p)) == start_offset {
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

		if is_token(p, .String) {
			// Check for "use strict" directive
			current := get_current(p)
			if current.literal == "use strict" {
				p.strict_mode = true
				directive := Directive{
					loc   = loc_from_token(current),
					value = StringLiteral{
						loc   = loc_from_token(current),
						value = "use strict",
						raw   = current.value,
					},
					raw = current.value,
				}
				append(&program.directives, directive)
				// Also emit as ExpressionStatement in body (ESTree compat). Mark
				// the ExpressionStatement as a directive prologue via its `directive`
				// field so the emitter writes ESTree's `directive: "use strict"`.
				str_lit := new_node(p, StringLiteral)
				str_lit.loc = loc_from_token(current)
				str_lit.value = current.literal.(string) or_else ""
				str_lit.raw = current.value
				expr_stmt, expr_stmt_s := new_stmt(p, ExpressionStatement)
				expr_stmt.loc = directive.loc
				expr_stmt.expression = expression_from(p, str_lit)
				expr_stmt.directive = "use strict"
				append(&program.body, expr_stmt_s)
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
	// `.Module` explicitly (upgrade-only — we never downgrade Module → Script).
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

	return program
}

// ============================================================================
// Statements
// ============================================================================

parse_statement_or_declaration :: proc(p: ^Parser) -> ^Statement {
	// At statement start, `/` must be regex (not division) — re-lex if needed
	if p.cur_type == .Div || p.cur_type == .AssignDiv {
		if p.lexer != nil {
			relex_as_regex(p.lexer)
			// Update parser's cached token from the re-lexed result
			ft := p.lexer.cur
			p.cur_type = ft.kind
			p.cur_tok.type = ft.kind
			p.cur_tok.loc.offset = int(ft.start)
			if ft.kind < .LBrace && ft.start < ft.end {
				p.cur_tok.value = p.lexer.source[ft.start:ft.end]
			}
		}
	}

	#partial switch p.cur_type {
	case .Function:
		return parse_function_declaration(p)
	case .Async:
		// async function declaration or async expression
		if is_next_token(p, .Function) {
			return parse_function_declaration(p)
		}
		return parse_expression_or_labeled_statement(p)
	case .Class:
		return parse_class_declaration(p)
	case .Abstract:
		// `abstract class Foo { ... }` — consume `abstract` and set the flag
		// on the parsed class declaration.
		if is_next_token(p, .Class) {
			eat(p) // consume `abstract`
			stmt := parse_class_declaration(p)
			if stmt != nil {
				if cls, ok := stmt^.(^ClassDeclaration); ok { cls.expr.abstract = true }
			}
			return stmt
		}
		// Not followed by class — fall through to expression (treat `abstract`
		// as an identifier). Best to defer to the generic identifier path.
		return parse_expression_or_labeled_statement(p)
	case .At:
		return parse_decorated_class(p)
	case .Let, .Var:
		return parse_variable_declaration(p, nil, true)
	case .Using:
		// `using x = ...` is a declaration; `using(...)` or `using.foo` is an expression.
		// A using declaration requires an identifier or destructuring as the next token.
		if is_next_token(p, .Identifier) || is_keyword_usable_as_property_name(peek_token(p).type) ||
		   is_next_token(p, .LBracket) || is_next_token(p, .LBrace) {
			return parse_variable_declaration(p, nil, true)
		}
		return parse_expression_or_labeled_statement(p)
	case .Const:
		// `const enum Foo { ... }` — TS enum with const modifier.
		// `enum` now lexes as Identifier, so check string value.
		if is_next_identifier_value(p, "enum") {
			return parse_ts_enum_declaration(p)
		}
		return parse_variable_declaration(p, nil, true)
	case .Await:
		if is_next_token(p, .Using) {
			return parse_variable_declaration(p, nil, true)
		}
		return parse_expression_or_labeled_statement(p)
	case .Identifier:
		// TS contextual keywords: `type`, `interface`, `enum`, `declare` lex as Identifier
		// so that `var type = 1` and similar JS code parses correctly.
		// We check string value here at the statement level.
		val := p.cur_tok.value
		if val == "declare" {
			return parse_ts_declare_statement(p)
		}
		if val == "interface" {
			return parse_ts_interface_declaration(p)
		}
		if val == "type" {
			// `type Foo = ...` — next token must be an identifier (the alias name).
			if is_next_token(p, .Identifier) {
				return parse_ts_type_alias_declaration(p)
			}
			return parse_expression_or_labeled_statement(p)
		}
		if val == "enum" {
			return parse_ts_enum_declaration(p)
		}
		if val == "namespace" {
			// `namespace Foo { ... }` or `namespace A.B { ... }`
			if is_next_token(p, .Identifier) {
				return parse_ts_module_declaration(p, .Namespace)
			}
			return parse_expression_or_labeled_statement(p)
		}
		if val == "module" && is_next_token(p, .String) {
			// `module "external-name" { ... }` — quoted name is the module form
			return parse_ts_module_declaration(p, .Module)
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
	case .Import:
		// Check if this is a dynamic import (import followed by ()
		if is_next_token(p, .LParen) {
			// Dynamic import expression - treat as expression, not statement
			return nil  // Let expression parsing handle it
		}
		return parse_import_declaration(p)
	case .Export:
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
	// Pre-size: large files have bigger blocks on average
	block_cap := 8 + (p.source_len >> 16)  // +1 per 64KB
	block.body = make([dynamic]^Statement, 0, block_cap, p.allocator)

	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		prev_offset := int(cur_offset(p))
		stmt := parse_statement_or_declaration(p)
		if stmt != nil {
			append(&block.body, stmt)
		} else if int(cur_offset(p)) == prev_offset {
			report_error(p, "Invalid statement in block")
			eat(p)
		}
	}

	if !match_token(p, .RBrace) {
		report_error(p, "Expected '}' at end of block")
	}

	block.loc.span.end = prev_end_offset(p)
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

	expr := parse_expression(p)
	if expr == nil {
		return nil
	}

	// Check for labeled statement: identifier:
	if is_token(p, .Colon) {
		#partial switch e in expr {
		case ^Identifier:
			eat(p) // consume :

			labeled := new_node(p, LabeledStatement)
			labeled.loc = start
			labeled.label = LabelIdentifier{
				loc  = e.loc,
				name = e.name,
			}
			labeled.body = parse_statement_or_declaration(p)
			labeled.loc.span.end = prev_end_offset(p)

			return statement_from(p, labeled)
		}
	}

	expr_stmt, stmt := new_stmt(p, ExpressionStatement)
	expr_stmt.loc = start
	expr_stmt.expression = expr

	// Consume optional semicolon
	match_semicolon_or_asi(p)

	expr_stmt.loc.span.end = prev_end_offset(p)
	return stmt
}

parse_expression_or_labeled_statement :: proc(p: ^Parser) -> ^Statement {
	return parse_expression_statement(p)
}

parse_if_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume if

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

	consequent := parse_statement_or_declaration(p)

	if_ := new_node(p, IfStatement)
	if_.loc = start
	if_.test = test
	if_.consequent = consequent

	if match_token(p, .Else) {
		if_.alternate = parse_statement_or_declaration(p)
	}

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
	body := parse_statement_or_declaration(p)
	p.in_loop = prev_in_loop

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
	body := parse_statement_or_declaration(p)
	p.in_loop = prev_in_loop

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

	if !expect_token(p, .LParen) {
		return nil
	}

	// Check for for-in/for-of vs regular for
	// We need to look ahead to determine which type of for loop this is
	// Look for 'in' or 'of' after the left side

	left_expr: ^Expression
	left_decl: ^VariableDeclaration

	if is_token(p, .Var) || is_token(p, .Let) || is_token(p, .Const) || is_token(p, .Using) ||
	   (is_token(p, .Await) && peek_dispatch(p).type == .Using) {
		// Variable declaration - parse it. parse_variable_declaration returns a
		// ^Statement union wrapping a ^VariableDeclaration; extract the inner
		// variant via type assertion. Prior code transmuted the union pointer
		// directly into a ^VariableDeclaration, reading the Statement union's
		// header bytes as if they were VariableDeclaration fields — same UB
		// class as Bug H. Symptom: the for-in/of emit would later cast back
		// via `(^Statement)(decl)` and dereference garbage, crashing deep
		// inside class method bodies (latent because class body emit was
		// previously a stub). left_expr was also transmuted here, but that
		// branch is dead — downstream only reads left_expr when left_decl is
		// nil, which never happens in this arm.
		decl_stmt := parse_variable_declaration(p, nil, false, true)
		if decl_stmt != nil {
			if vd, ok := decl_stmt^.(^VariableDeclaration); ok {
				left_decl = vd
			}
		}
	} else if !is_token(p, .Semi) {
		// Parse as full expression (including comma) but stop at 'in'/'of'.
		// The no_in flag prevents 'in' from being consumed as binary operator.
		p.no_in = true
		left_expr = parse_expr_with_prec(p, .Comma)
		p.no_in = false
	}

	// Now check if this is for-in, for-of, or regular for
	if is_token(p, .In) || is_token(p, .Of) {
		// for-in or for-of
		is_in := is_token(p, .In)
		eat(p) // consume in/of

		right := parse_expression(p)
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
		body := parse_statement_or_declaration(p)
		p.in_loop = prev_in_loop

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
	body := parse_statement_or_declaration(p)
	p.in_loop = prev_in_loop

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

	if !p.in_function {
		// Relaxed: don't report — nested function context tracking is imperfect
		_ = p.in_function
	}

	argument: Maybe(^Expression)
	// ECMA-262 §12.10 Restricted Production: `return` followed by a
	// LineTerminator triggers ASI — the argument belongs to the NEXT
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

parse_break_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume break

	// Note: we don't validate break context here — nested functions
	// reset in_loop/in_switch, causing false positives.

	label: Maybe(LabelIdentifier)
	// Label only if on same line (no LineTerminator between break and identifier)
	if is_token(p, .Identifier) && !p.cur_tok.had_line_terminator {
		label = LabelIdentifier{
			loc  = cur_loc(p),
			name = cur_value(p),
		}
		eat(p)
	}

	match_semicolon_or_asi(p)

	break_ := new_node(p, BreakStatement)
	break_.loc = start
	break_.label = label
	break_.loc.span.end = prev_end_offset(p)

	return statement_from(p, break_)
}

parse_continue_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume continue

	if !p.in_loop {
		// Relaxed: don't report — nested function context tracking is imperfect
		_ = p.in_loop
	}

	label: Maybe(LabelIdentifier)
	// Label only if on same line (no LineTerminator between continue and identifier)
	if is_token(p, .Identifier) && !p.cur_tok.had_line_terminator {
		label = LabelIdentifier{
			loc  = cur_loc(p),
			name = cur_value(p),
		}
		eat(p)
	}

	match_semicolon_or_asi(p)

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

	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		prev_offset := int(cur_offset(p))
		case_ := parse_switch_case(p)
		if case_ != nil {
			append(&switch_.cases, case_^)
		} else if int(cur_offset(p)) == prev_offset {
			eat(p)
		}
	}

	p.in_switch = prev_in_switch

	if !match_token(p, .RBrace) {
		report_error(p, "Expected '}' at end of switch statement")
	}

	switch_.loc.span.end = prev_end_offset(p)
	return statement_from(p, switch_)
}

parse_switch_case :: proc(p: ^Parser) -> ^SwitchCase {
	start := cur_loc(p)

	test: Maybe(^Expression)

	if match_token(p, .Default) {
		test = nil
	} else if match_token(p, .Case) {
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

	for !is_token(p, .Case) && !is_token(p, .Default) && !is_token(p, .RBrace) && !is_token(p, .EOF) {
		prev_offset := int(cur_offset(p))
		stmt := parse_statement_or_declaration(p)
		if stmt != nil {
			append(&case_.consequent, stmt)
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
	// struct — UB that silently truncated the block body.
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
		// `(` or `{` that follows — matches OXC/Acorn/Babel. Capture the
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

	// Optional catch binding: try {} catch {} or try {} catch (e) {}
	if is_token(p, .LParen) {
		eat(p)
		if !is_token(p, .RParen) {
			// Parse catch parameter
			param = parse_binding_pattern(p)
		}
		if !expect_token(p, .RParen) {
			return nil
		}
	}

	body := parse_block_statement(p)
	if body == nil {
		return nil
	}
	body_ptr, body_ok := body^.(^BlockStatement)
	if !body_ok {
		return nil
	}

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

	if p.strict_mode {
		// Relaxed: don't error on with-in-strict (typescript.js uses it in non-strict context)
		_ = p.strict_mode
	}

	if !expect_token(p, .LParen) {
		return nil
	}

	object := parse_assignment_expression(p)
	if object == nil {
		return nil
	}

	if !expect_token(p, .RParen) {
		return nil
	}

	body := parse_statement_or_declaration(p)

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

	has_name := is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type)
	if !is_expr || has_name {
		if has_name {
			current := get_current(p)
			id = BindingIdentifier{
				loc  = loc_from_token(current),
				name = current.value,
			}
			eat(p)
		} else if !is_expr {
			report_error(p, "Function declaration requires a name")
		}
	}

	// TypeScript generic type parameters: `function foo<T, U>(...)`
	type_parameters: Maybe(^TSTypeParameterDeclaration)
	if is_token(p, .LAngle) { type_parameters = parse_ts_type_parameters(p) }

	if !expect_token(p, .LParen) {
		return nil
	}

	params := parse_function_params(p)

	if !expect_token(p, .RParen) {
		return nil
	}

	// TypeScript return type annotation
	return_type: Maybe(^TSTypeAnnotation)
	if is_token(p, .Colon) {
		return_type = parse_ts_return_type_annotation(p)
	}

	prev_async := p.in_async
	p.in_async = async
	prev_gen := p.in_generator
	p.in_generator = generator

	// In declare / ambient-module context, allow no body (just a semicolon).
	// An ambient module body (`module "x" { function f(): void; }`) or a
	// `declare function f(): void;` both elide the implementation.
	body: FunctionBody
	allow_no_body_here := allow_no_body || p.in_ambient
	if allow_no_body_here && is_token(p, .Semi) {
		eat(p) // consume semicolon
		body = FunctionBody{
			loc = cur_loc(p),
			body = make([dynamic]^Statement, 0, 0, p.allocator),
			directives = make([dynamic]Directive, 0, 0, p.allocator),
		}
	} else {
		body = parse_function_body(p)
	}

	p.in_async = prev_async
	p.in_generator = prev_gen

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
		expr.loc.span.end = prev_end_offset(p)

		// For function expressions, wrap in ExpressionStatement. The
		// .expression field is an ^Expression (a union ptr, not a raw ptr
		// to the concrete variant), so box via expression_from to get a
		// properly tagged union — a plain pointer cast produces a union
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
	}
	decl.expr.loc.span.end = prev_end_offset(p)

	// Allocate Statement union and store the pointer
	stmt := new_node(p, Statement)
	stmt^ = (^FunctionDeclaration)(decl)
	return stmt
}

parse_function_params :: proc(p: ^Parser) -> [dynamic]FunctionParameter {
	params := make([dynamic]FunctionParameter, 0, 3, p.allocator)

	if is_token(p, .RParen) {
		return params
	}

	for {
		// Trailing comma: if we see ')' after comma, stop
		if is_token(p, .RParen) {
			break
		}

		param := parse_function_param(p)
		if param != nil {
			append(&params, param^)
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

	// Check for rest parameter: ...identifier
	if match_token(p, .Dot3) {
		// Rest element - create RestElement as the pattern
		rest := new_node(p, RestElement)
		rest.loc = param.loc

		// Parse the argument (identifier or destructuring pattern)
		arg_pattern := parse_binding_pattern(p)
		rest.argument = arg_pattern

		// TS: type annotation on a rest parameter — `...args: T[]`.
		// Store on the inner Identifier so the emitter surfaces it;
		// extend the RestElement span to cover the annotation.
		if is_token(p, .Colon) {
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

	pattern := parse_binding_pattern(p)
	param.pattern = pattern

	// TypeScript: optional parameter marker `?` comes AFTER the name.
	// Only consume if followed by `:`, `,`, `)`, or `=` — not a ternary.
	if is_token(p, .Question) {
		nxt := peek_token(p)
		if nxt.type == .Colon || nxt.type == .Comma || nxt.type == .RParen || nxt.type == .Assign {
			eat(p) // consume `?`
		}
	}

	// TypeScript type annotation on parameter — store on Identifier node.
	// OXC extends the Identifier.end to include the annotation; mirror it.
	if is_token(p, .Colon) {
		ann := parse_ts_type_annotation(p)
		if ident, ok := pattern.(^Identifier); ok {
			ident.type_annotation = ann
			if ann != nil && ann.loc.span.end > ident.loc.span.end {
				ident.loc.span.end = ann.loc.span.end
			}
		}
	}

	if match_token(p, .Assign) {
		param.default_val = parse_assignment_expression(p)
	}

	param.loc.span.end = prev_end_offset(p)
	return param
}

parse_function_body :: proc(p: ^Parser) -> FunctionBody {
	start := cur_loc(p)

	if !expect_token(p, .LBrace) {
		return {}
	}

	body := FunctionBody{
		loc        = start,
		body       = make([dynamic]^Statement, 0, 8, p.allocator),
		directives = make([dynamic]Directive, 0, 1, p.allocator),
	}

	prev_in_function := p.in_function
	prev_in_generator := p.in_generator
	prev_in_async := p.in_async
	prev_strict := p.strict_mode

	p.in_function = true

	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		prev_offset := int(cur_offset(p))
		stmt := parse_statement_or_declaration(p)
		if stmt != nil {
			append(&body.body, stmt)
		} else if int(cur_offset(p)) == prev_offset {
			eat(p)
		}
	}

	// Mark directive-prologue ExpressionStatements. Per ECMA-262 §14.1.1 the
	// prologue is the leading sequence of ExpressionStatement whose expression
	// is an unparenthesised StringLiteral. Each such statement carries a
	// `directive: <raw>` field in ESTree; everything after the first non-
	// directive statement is regular code even if it looks like a string.
	for stmt_ptr in body.body {
		if stmt_ptr == nil { break }
		es, ok := stmt_ptr^.(^ExpressionStatement)
		if !ok { break }
		if es == nil { break }
		str_lit, is_str := es.expression.(^StringLiteral)
		if !is_str || str_lit == nil { break }
		// Mark as directive — ESTree's `directive` field is the unquoted
		// content, e.g. `"use strict"` token → `directive: "use strict"`.
		es.directive = str_lit.value
	}

	p.in_function = prev_in_function
	p.in_generator = prev_in_generator
	p.in_async = prev_in_async
	p.strict_mode = prev_strict

	if !match_token(p, .RBrace) {
		report_error(p, "Expected '}' at end of function body")
	}

	body.loc.span.end = prev_end_offset(p)
	return body
}

parse_class_declaration :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume class

	id: Maybe(BindingIdentifier)
	if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
		current := get_current(p)
		id = BindingIdentifier{
			loc  = loc_from_token(current),
			name = current.value,
		}
		eat(p)
	}

	// TypeScript generic type parameters: `class Box<T> { ... }`
	type_parameters: Maybe(^TSTypeParameterDeclaration)
	if is_token(p, .LAngle) { type_parameters = parse_ts_type_parameters(p) }

	super_class: Maybe(^Expression)
	if match_token(p, .Extends) {
		super_class = parse_left_hand_side_expr(p)
	}

	body := parse_class_body(p)

	// Allocate ClassDeclaration and Statement separately
	decl := new_node(p, ClassDeclaration)
	decl.expr = {
		loc             = start,
		id              = id,
		super_class     = super_class,
		body            = body,
		type_parameters = type_parameters,
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
		body = make([dynamic]ClassElement, 0, 8, p.allocator),
	}

	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		// Skip empty semicolons (valid class element separators in ES2022+)
		if is_token(p, .Semi) { eat(p); continue }

		prev_offset := int(cur_offset(p))
		elem := parse_class_element(p)
		if elem != nil {
			append(&body.body, elem^)
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
	return body
}

parse_class_element :: proc(p: ^Parser) -> ^ClassElement {
	decorators := parse_decorators(p)
	start := cur_loc(p)
	if len(decorators) > 0 { start.span.start = decorators[0].loc.span.start }

	// Check for static block: static { ... }
	if is_token(p, .Static) && is_next_token(p, .LBrace) {
		elem := parse_static_block(p, start)
		if elem != nil { elem.decorators = decorators }
		return elem
	}

	static_ := match_token(p, .Static)
	is_abstract := match_token(p, .Abstract)

	kind := ClassElementKind.Method
	is_async := false
	is_generator := false
	computed := false
	is_private := false
	is_accessor := false

	// Check for `accessor` keyword
	if is_token(p, .Accessor) {
		next := peek_dispatch(p)
		if next.type != .LParen && next.type != .Semi && next.type != .RBrace {
			is_accessor = true
			eat(p)
		}
	}

	// Check for async keyword
	if !is_accessor && is_token(p, .Async) {
		// Only treat as async if followed by something that starts a method name
		next := peek_dispatch(p)
		if next.type == .Identifier || next.type == .PrivateIdentifier || next.type == .LBracket ||
		   next.type == .String || next.type == .Number || next.type == .LParen ||
		   next.type == .Mul || is_keyword_usable_as_property_name(next.type) {
			is_async = true
			eat(p) // consume async
		}
	}

	// Check for get/set accessor keywords
	if is_token(p, .Get) || is_token(p, .Set) {
		is_getter := is_token(p, .Get)
		// Only treat as accessor if followed by a method name (not LParen directly)
		next := peek_dispatch(p)
		if next.type != .LParen && next.type != .Semi && next.type != .RBrace {
			if is_getter {
				kind = .Get
			} else {
				kind = .Set
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

		// Create PrivateIdentifier (strip the # prefix)
		name := current.value
		if len(name) > 0 && name[0] == '#' {
			name = name[1:]
		}

		private_ident := new_node(p, PrivateIdentifier)
		private_ident.loc = loc_from_token(current)
		private_ident.name = name
		key = expression_from(p, private_ident)
		eat(p)
	} else if is_token(p, .String) {
		// String key: `get 'trusting-append'()` / `'method-name'()`. ESTree emits
		// this as a Literal key, not an Identifier. Previously stuffed into
		// new_identifier which copied the quoted raw source into `name`,
		// hiding the real string from downstream walkers (ember.js etc.).
		current := get_current(p)
		str_lit := new_node(p, StringLiteral)
		str_lit.loc = loc_from_token(current)
		str_lit.value = current.literal.(string) or_else ""
		str_lit.raw = current.value
		key = expression_from(p, str_lit)
		eat(p)
	} else if is_token(p, .Number) {
		// Numeric key: `1234()`. Similarly emit as NumericLiteral-backed Literal
		// rather than an Identifier whose name is the numeric text.
		current := get_current(p)
		num_lit := new_node(p, NumericLiteral)
		num_lit.loc = loc_from_token(current)
		num_lit.raw = current.value
		if v, ok := current.literal.(f64); ok {
			num_lit.value = v
		}
		key = expression_from(p, num_lit)
		eat(p)
	} else if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
		current := get_current(p)
		key = expression_from(p, new_identifier(p, current))
		eat(p)

		// Check if it's actually a constructor
		if current.type == .Constructor || (current.type == .Identifier && current.value == "constructor") {
			kind = .Constructor
		}
	} else if is_token(p, .LBracket) {
		// Computed property: [expr]
		computed = true
		eat(p)
		key = parse_assignment_expression(p)
		if !expect_token(p, .RBracket) {
			return nil
		}
	} else {
		report_error(p, "Expected method or property name")
		return nil
	}

	// Check for generator star (not valid for private identifiers)
	if !is_private && match_token(p, .Mul) {
		is_generator = true
	}

	// TS class field modifiers: `foo?:` (optional) or `foo!:` (definite assignment).
	// These appear BEFORE the `:` type annotation and coexist with it.
	field_optional := false
	field_definite := false
	if is_token(p, .Question) {
		// Only consume `?` when we're clearly on a class field (next is `:` or `=` or `;`).
		nxt := p.lexer.nxt.kind
		if nxt == .Colon || nxt == .Assign || nxt == .Semi || nxt == .Comma || nxt == .RBrace {
			field_optional = true
			eat(p)
		}
	} else if is_token(p, .Not) {
		// `foo!:` — definite assignment assertion. `.Not` = logical-not token.
		nxt := p.lexer.nxt.kind
		if nxt == .Colon {
			field_definite = true
			eat(p)
		}
	}

	// TS class field type annotation: `foo: T`. Parsed before the field/method split.
	field_type_ann: Maybe(^TSTypeAnnotation)
	if is_token(p, .Colon) {
		field_type_ann = parse_ts_type_annotation(p)
	}

	// Check if this is a field (has = but no () ) or method. `.Colon` was
	// consumed above as part of the type annotation, so after that point the
	// next token is either `;`/`,`/`}` (bare field) or `=` (initializer).
	if field_type_ann != nil || is_token(p, .Assign) || is_token(p, .Semi) || is_token(p, .Comma) || is_token(p, .RBrace) {
		// Class field with initializer or just declaration
		value: Maybe(^Expression)

		if match_token(p, .Assign) {
			init_expr := parse_assignment_expression(p)
			if init_expr != nil {
				value = init_expr
			}
		}

		// Consume optional semicolon
		match_semicolon_or_asi(p)

		elem := new_node(p, ClassElement)
		elem.loc = start
		elem.key = key
		elem.value = value
		elem.kind = kind  // Still .Method but value is not a function
		elem.computed = false
		elem.static = static_
		elem.is_accessor = is_accessor
		elem.abstract = is_abstract
		elem.decorators = decorators
		elem.type_annotation = field_type_ann
		elem.optional = field_optional
		elem.definite = field_definite

		elem.loc.span.end = prev_end_offset(p)
		return elem
	}

	// It's a method - parse parameters and body
	// Capture paren position for FunctionExpression start
	paren_loc := cur_loc(p)
	if !expect_token(p, .LParen) {
		return nil
	}

	params := parse_function_params(p)

	if !expect_token(p, .RParen) {
		return nil
	}

	// TypeScript return type annotation on method — stored on FunctionExpression.
	method_return_type: Maybe(^TSTypeAnnotation)
	if is_token(p, .Colon) {
		method_return_type = parse_ts_return_type_annotation(p)
	}

	// For abstract methods, there's no body — just a semicolon
	body: FunctionBody
	if is_abstract && is_token(p, .Semi) {
		match_semicolon_or_asi(p)
		// Leave body empty
	} else {
		// Parse body - set context flags
		prev_in_function := p.in_function
		prev_in_generator := p.in_generator
		prev_in_async := p.in_async

		p.in_function = true
		p.in_generator = is_generator
		p.in_async = is_async

		body = parse_function_body(p)

		p.in_function = prev_in_function
		p.in_generator = prev_in_generator
		p.in_async = prev_in_async
	}

	// Create the method as a FunctionExpression
	fn_expr := new_node(p, FunctionExpression)
	fn_expr.loc = paren_loc
	fn_expr.id = nil // Methods don't have names in their function expression
	fn_expr.params = params
	fn_expr.body = body
	fn_expr.generator = is_generator
	fn_expr.async = is_async
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

	elem.loc.span.end = prev_end_offset(p)
	return elem
}

// Parse ES2022 static block: static { ... }
parse_static_block :: proc(p: ^Parser, start: Loc) -> ^ClassElement {
	match_token(p, .Static) // consume static

	// Parse block statement. parse_block_statement returns a ^Statement
	// union wrapping a ^BlockStatement; extract the ^BlockStatement variant
	// via type assertion. The previous transmute read the union header as
	// if it were a BlockStatement struct — same UB class as Bug H, silently
	// zeroing `body` so static blocks emitted empty.
	block_stmt := parse_block_statement(p)
	if block_stmt == nil {
		return nil
	}
	block, ok := block_stmt^.(^BlockStatement)
	if !ok {
		return nil
	}

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
	decl.declarations = make([dynamic]VariableDeclarator, 0, 2, p.allocator)

	for {
		d := parse_variable_declarator(p, kind, in_for, is_declare)
		if d != nil {
			append(&decl.declarations, d^)
		}

		if !match_token(p, .Comma) {
			break
		}
	}

	if consume_semi {
		match_semicolon_or_asi(p)
	}

	decl.loc.span.end = prev_end_offset(p)
	stmt := new_node(p, Statement)
	stmt^ = decl
	return stmt
}

parse_variable_declarator :: proc(p: ^Parser, kind: VariableKind, in_for := false, is_declare := false) -> ^VariableDeclarator {
	start := cur_loc(p)

	pattern := parse_binding_pattern(p)

	// TypeScript type annotation — store on Identifier binding node.
	if is_token(p, .Colon) {
		ann := parse_ts_type_annotation(p)
		if ident, ok := pattern.(^Identifier); ok {
			ident.type_annotation = ann
		}
	}

	init: Maybe(^Expression)
	if match_token(p, .Assign) {
		init = parse_assignment_expression(p)
	} else if kind == .Const && !in_for && !is_declare && !p.in_ambient {
		// `const x;` without init is legal inside an ambient module body.
		report_error(p, "const declarations must have an initializer")
	}

	decl := new_node(p, VariableDeclarator)
	decl.loc = start
	decl.id = pattern
	decl.init = init
	decl.loc.span.end = prev_end_offset(p)

	return decl
}

parse_binding_pattern :: proc(p: ^Parser) -> Pattern {
	start := cur_loc(p)

	if is_token(p, .LBrace) {
		return parse_object_pattern(p)
	}

	if is_token(p, .LBracket) {
		return parse_array_pattern(p)
	}

	// Identifiers and contextual keywords that can be used as binding names.
	// All contextual keywords are valid binding identifiers in JS.
	if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
		id_loc := cur_loc(p)
		id_name := cur_value(p)
		eat(p)
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
	obj.properties = make([dynamic]ObjectPatternProperty, 0, 4, p.allocator)

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
			append(&obj.properties, rest_prop)

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
			// Computed property: [expr]
			computed = true
			eat(p)
			expr_key := parse_assignment_expression(p)
			if expr_key != nil {
				key = (^Expression)(expr_key)
			}
			if !expect_token(p, .RBracket) {
				return nil
			}
		} else if is_token(p, .String) {
			// String key: `{ 'aria-label': x }`. Store as ^StringLiteral so
			// the emitter can render a Literal node — previously stuffed into
			// an IdentifierName whose `name` field contained the quoted raw
			// source (`'aria-label'` literally), producing an Identifier with
			// quoted name in the JSON and hiding the real string value from
			// every downstream string-walker.
			current := get_current(p)
			str_lit := new_node(p, StringLiteral)
			str_lit.loc = loc_from_token(current)
			str_lit.value = current.literal.(string) or_else ""
			str_lit.raw = current.value
			str_lit.loc.span.end = cur_offset(p) + u32(len(current.value))
			key = str_lit
			eat(p)
		} else if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
			// Identifier or keyword used as key.
			id_name := IdentifierName{
				loc  = cur_loc(p),
				name = cur_value(p),
			}
			key = id_name
			eat(p)
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
				vl := cur_loc(p); vn := cur_value(p)
				value_ident := new_node(p, Identifier)
				value_ident.loc = vl
				value_ident.name = vn
				eat(p)

				// Check for default value: { key: value = defaultValue }
				if match_token(p, .Assign) {
					default_val := parse_assignment_expression(p)
					assign := new_node(p, AssignmentPattern)
					assign.loc = prop_start
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
					append(&obj.properties, prop)
				} else {
					prop := ObjectPatternProperty{
						loc       = prop_start,
						key       = key,
						value     = value_ident,
						computed  = computed,
						shorthand = false,
					}
					prop.loc.span.end = value_ident.loc.span.end
					append(&obj.properties, prop)
				}
			} else if is_token(p, .LBrace) {
				// Nested object pattern (possibly with default)
				nested := parse_object_pattern(p)
				if nested == nil {
					return nil
				}
				val: Pattern = nested
				if match_token(p, .Assign) {
					default_val := parse_assignment_expression(p)
					assign := new_node(p, AssignmentPattern)
					assign.loc = prop_start
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
				append(&obj.properties, prop)
			} else if is_token(p, .LBracket) {
				// Nested array pattern (possibly with default)
				nested := parse_array_pattern(p)
				if nested == nil {
					return nil
				}
				val: Pattern = nested
				if match_token(p, .Assign) {
					default_val := parse_assignment_expression(p)
					assign := new_node(p, AssignmentPattern)
					assign.loc = prop_start
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
				append(&obj.properties, prop)
			} else {
				report_error(p, "Expected pattern in object pattern value")
				return nil
			}
		} else if match_token(p, .Assign) {
			// { key = defaultValue } - shorthand with default
			default_val := parse_assignment_expression(p)
			// Create AssignmentPattern with key as left
			if k := key; k != nil {
				val := k.?  // unwrap Maybe
				#partial switch v in val {
				case IdentifierName:
					left_ident := new_node(p, Identifier)
					left_ident.loc = v.loc
					left_ident.name = v.name
					assign := new_node(p, AssignmentPattern)
					assign.loc = prop_start
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
					append(&obj.properties, prop)
				}
			}
		} else {
			// Shorthand: { key } means { key: key }
			if k := key; k != nil {
				val := k.?  // unwrap Maybe
				#partial switch v in val {
				case IdentifierName:
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
					append(&obj.properties, prop)
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
	ident := new_node(p, Identifier)
	ident.loc = loc_from_token(tok)
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
			append(&elements, Maybe(Pattern){})
			eat(p) // consume comma
			continue
		}

		// Check for rest element: ...identifier
		if is_token(p, .Dot3) {
			rest_start := cur_loc(p) // Capture location of ... before eating
			eat(p) // consume ...
			if !is_token(p, .Identifier) {
				report_error(p, "Expected identifier after ... in array pattern")
				return nil
			}
			arl := cur_loc(p); arn := cur_value(p)
			eat(p)

			rest := new_node(p, RestElement)
			rest.loc = rest_start
			rest_ident := new_node(p, Identifier)
			rest_ident.loc = arl
			rest_ident.name = arn
			rest.argument = rest_ident
			rest.loc.span.end = prev_end_offset(p)

			append(&elements, Maybe(Pattern)(rest))

			// Rest element must be last
			if !is_token(p, .RBracket) && !is_token(p, .EOF) {
				report_error(p, "Rest element must be last in array pattern")
			}
			break
		}

		// Parse regular element
		if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
			// Simple identifier binding, possibly with default value
			eil := cur_loc(p); ein := cur_value(p)
			eat(p)
			ident := new_node(p, Identifier)
			ident.loc = eil
			ident.name = ein

			// Check for default value: [x = defaultValue]
			if match_token(p, .Assign) {
				default_val := parse_assignment_expression(p)
				assign := new_node(p, AssignmentPattern)
				assign.loc = eil
				assign.left = ident
				assign.right = default_val
				assign.loc.span.end = prev_end_offset(p)
				append(&elements, Maybe(Pattern)(assign))
			} else {
				append(&elements, Maybe(Pattern)(ident))
			}
		} else if is_token(p, .LBrace) {
			// Nested object pattern
			nested := parse_object_pattern(p)
			if nested == nil {
				return nil
			}
			append(&elements, Maybe(Pattern)(nested))
		} else if is_token(p, .LBracket) {
			// Nested array pattern (recursive)
			nested := parse_array_pattern(p)
			if nested == nil {
				return nil
			}
			append(&elements, Maybe(Pattern)(nested))
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

// Helper: Convert ImportSpecifierSpec to ESMNameEntry + ESMStaticImportEntry
collect_esm_import_entry :: proc(spec: ^ImportSpecifierSpec) -> ESMStaticImportEntry {
	entry := ESMStaticImportEntry{}

	#partial switch s in spec^ {
	case ImportDefaultSpecifier:
		// import X from "m" — X is the local binding
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
// tag — the emitter's `switch v in spec_ptr^` then falls through to no
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

	decl := new_node(p, ImportDeclaration)
	decl.loc = start
	decl.specifiers = make([dynamic]^ImportSpecifierSpec, 0, 4, p.allocator)

	// TS `import type ...` — type-only import. `type` lexes as Identifier.
	// Disambiguate from `import type from "m"` (value import of default binding
	// named "type"): after `type`, the next token must be `{`, `*`, or an
	// identifier followed by `,`/`from` (but NOT `from` directly).
	if p.cur_type == .Identifier && p.cur_tok.value == "type" {
		nxt := p.lexer.nxt.kind
		if nxt == .LBrace || nxt == .Mul {
			decl.import_kind = .Type
			eat(p) // consume `type`
		} else if nxt == .Identifier {
			// Could be `import type Foo from "m"` (type-only default) or
			// `import type from "m"` (default import of "type"). Only flag as
			// type-only when the identifier after `type` is NOT `from`.
			nxt_val := p.lexer.source[p.lexer.nxt.start:p.lexer.nxt.end]
			if nxt_val != "from" {
				decl.import_kind = .Type
				eat(p) // consume `type`
			}
		}
	}

	if is_token(p, .String) {
		// import "module"
		decl.source = parse_string_literal(p)
	} else if is_token(p, .LBrace) {
		// Named imports: import { x, y } from "module"
		eat(p) // consume {

		for !is_token(p, .RBrace) && !is_token(p, .EOF) {
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

		decl.source = parse_string_literal(p)
	} else if is_token(p, .Identifier) {
		// Default import: import name from "module" or import name, { x } from "module"
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
			if is_token(p, .LBrace) {
				eat(p) // consume {

				for !is_token(p, .RBrace) && !is_token(p, .EOF) {
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

		decl.source = parse_string_literal(p)
	}

	decl.attributes = parse_import_attributes(p)

	match_semicolon_or_asi(p)

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
			append(&esm_import.entries, entry)
		}
		append(&p.staticImports, esm_import)
	}

	// Allocate Statement union and store the pointer
	stmt := new_node(p, Statement)
	stmt^ = (^ImportDeclaration)(decl)
	return stmt
}

parse_import_specifier :: proc(p: ^Parser) -> ^ImportSpecifier {
	start := cur_loc(p)

	imported := parse_identifier_name(p)

	local := imported
	if match_token(p, .As) {
		local = parse_identifier(p)
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

	return spec
}

parse_export_declaration :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume export

	if match_token(p, .Default) {
		return parse_export_default(p, start)
	}

	if match_token(p, .Mul) {
		return parse_export_all(p, start)
	}

	if is_token(p, .LBrace) {
		return parse_export_named(p, start)
	}

	// Export declaration. parse_statement_or_declaration returns a ^Statement
	// union wrapping the underlying declaration variant. The previous code
	// cast that ^Statement pointer directly to ^Declaration, reinterpreting
	// the Statement union's tag bytes as a Declaration tag — different
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
	#partial switch v in decl^ {
	case ^FunctionDeclaration:      decl_union^ = v
	case ^VariableDeclaration:       decl_union^ = v
	case ^ClassDeclaration:           decl_union^ = v
	case ^ImportDeclaration:          decl_union^ = v
	case ^ExportNamedDeclaration:     decl_union^ = v
	case ^ExportDefaultDeclaration:   decl_union^ = v
	case ^ExportAllDeclaration:       decl_union^ = v
	}

	export_decl := new_node(p, ExportNamedDeclaration)
	export_decl.loc = start
	export_decl.declaration = decl_union
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
	// ExportDefaultDef union — UB that happened to not crash only because
	// the union tag slots sometimes aligned. Same class as the FunctionExpression
	// and TryStatement UB fixes.
	def := new_node(p, ExportDefaultDef)

	if is_token(p, .Function) || (is_token(p, .Async) && is_next_token(p, .Function)) {
		// export default [async] function() {}  — parsed as expression form.
		// parse_function_declaration(is_expr=true) returns a ^Statement union
		// wrapping a ^ExpressionStatement whose .expression is the FunctionExpression.
		fn_stmt := parse_function_declaration(p, true)
		if fn_stmt != nil {
			if expr_stmt, ok := fn_stmt^.(^ExpressionStatement); ok {
				def^ = expr_stmt.expression
			}
		}
	} else if is_token(p, .Class) {
		cls_stmt := parse_statement_or_declaration(p)
		if cls_stmt != nil {
			if cls_decl, ok := cls_stmt^.(^ClassDeclaration); ok {
				// ^ClassDeclaration assigns into the ^Declaration variant.
				decl_union := new_node(p, Declaration)
				decl_union^ = cls_decl
				def^ = decl_union
			}
		}
	} else {
		expr := parse_assignment_expression(p)
		if expr != nil {
			def^ = expr
		}
		match_semicolon_or_asi(p)
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
	append(&p.staticExports, esm_export)

	stmt := new_node(p, Statement)
	stmt^ = (^ExportDefaultDeclaration)(decl)
	return stmt
}

parse_export_all :: proc(p: ^Parser, start: Loc) -> ^Statement {
	exported: Maybe(IdentifierName)

	if match_token(p, .As) {
		name := parse_identifier_name(p)
		exported = IdentifierName{
			loc  = name.loc,
			name = name.name,
		}
	}

	if !expect_token(p, .From) {
		return nil
	}

	source := parse_string_literal(p)

	decl := new_node(p, ExportAllDeclaration)
	decl.loc = start
	decl.source = source
	decl.exported = exported
	decl.attributes = parse_import_attributes(p)

	// Consume the trailing semicolon BEFORE stamping the span end so the
	// ExportAllDeclaration includes its own `;` — matches ESTree/OXC/Acorn
	// semantics. Previously the span stopped at the last token of `source`.
	match_semicolon_or_asi(p)
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
	append(&p.staticExports, esm_export)

	stmt := new_node(p, Statement)
	stmt^ = (^ExportAllDeclaration)(decl)
	return stmt
}

parse_export_named :: proc(p: ^Parser, start: Loc) -> ^Statement {
	if !expect_token(p, .LBrace) {
		return nil
	}

	decl := new_node(p, ExportNamedDeclaration)
	decl.loc = start
	decl.specifiers = make([dynamic]ExportSpecifier, 0, 4, p.allocator)

	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		start_spec := cur_loc(p)

		// ES2022 allows either an identifier OR a string literal on either
		// side of `as`. Parse each slot independently.
		parse_spec_name :: proc(p: ^Parser) -> ExportSpecifierName {
			if is_token(p, .String) {
				current := get_current(p)
				str_lit := new_node(p, StringLiteral)
				str_lit.loc = loc_from_token(current)
				str_lit.value = current.literal.(string) or_else ""
				str_lit.raw = current.value
				eat(p)
				return str_lit
			}
			id := parse_identifier_name(p)
			return IdentifierName{loc = id.loc, name = id.name}
		}

		local := parse_spec_name(p)
		exported := local
		if match_token(p, .As) {
			exported = parse_spec_name(p)
		}

		spec := ExportSpecifier{
			loc = start_spec,
			local = local,
			exported = exported,
		}
		spec.loc.span.end = prev_end_offset(p)
		append(&decl.specifiers, spec)

		if !match_token(p, .Comma) {
			break
		}
	}

	if !expect_token(p, .RBrace) {
		return nil
	}

	if match_token(p, .From) {
		decl.source = parse_string_literal(p)
		decl.attributes = parse_import_attributes(p)
	}

	match_semicolon_or_asi(p)

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
			append(&esm_export.entries, entry)
		}
		append(&p.staticExports, esm_export)
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
	None,            // Not an operator — breaks the loop immediately
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
	left := parse_unary_expr(p)
	if left == nil {
		return nil
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
				return parse_arrow_function(p, left)
			}
			if is_assignment_operator(cur_type) {
				left = parse_assignment_expr(p, left)
				continue
			}
		}

		if op_prec == .Conditional {
			left = parse_conditional_expr(p, left)
			continue
		}

		// Trailing comma in parenthesized expression: don't consume comma before )
		if cur_type == .Comma && is_next_token(p, .RParen) {
			eat(p)
			break
		}

		// Comma operator → SequenceExpression
		if cur_type == .Comma {
			seq, seq_e := new_expr(p, SequenceExpression)
			seq.loc = loc_from_expr(left)
			seq.expressions = make([dynamic]^Expression, 0, 4, p.allocator)
			append(&seq.expressions, left)
			for match_token(p, .Comma) {
				expr := parse_assignment_expression(p)
				if expr == nil { break }
				append(&seq.expressions, expr)
			}
			seq.loc.span.end = prev_end_offset(p)
			left = seq_e
			continue
		}

		// Binary/logical operator
		eat(p)
		next_min_prec := Precedence(int(op_prec) + 1)

		right := parse_expr_with_prec(p, next_min_prec)
		if right == nil {
			report_error(p, "Expected expression after operator")
			return left
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
		if argument == nil { return nil }
		unary := new_node(p, UnaryExpression)
		unary.loc = loc_from_token(current)
		unary.operator = token_to_unary_op(current.type)
		unary.argument = argument
		unary.prefix = true
		unary.loc.span.end = prev_end_offset(p)
		return expression_from(p, unary)

	case .PlusPlus, .MinusMinus:
		current := p.cur_tok
		eat(p)
		argument := parse_unary_expr(p)
		if argument == nil { return nil }
		update := new_node(p, UpdateExpression)
		update.loc = loc_from_token(current)
		update.operator = .Increment if current.type == .PlusPlus else .Decrement
		update.argument = argument
		update.prefix = true
		update.loc.span.end = prev_end_offset(p)
		return expression_from(p, update)

	case .Await:
		if p.strict_mode && !p.in_async && p.in_function {
			report_error(p, "await outside of async function")
		}
		current := p.cur_tok
		eat(p)
		argument := parse_unary_expr(p)
		if argument == nil { return nil }
		await := new_node(p, AwaitExpression)
		await.loc = loc_from_token(current)
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
		spread.loc = loc_from_token(current)
		spread.argument = argument
		spread.loc.span.end = prev_end_offset(p)
		return expression_from(p, spread)

	case .Yield:
		// Relaxed: don't validate yield context (nested function tracking imperfect)
		return parse_yield_expr(p)
	}

	// Common path: primary expression + optional postfix ++ / -- (inlined parse_update_expr)
	// Fast-path: identifier → member/call chain (covers ~60% of expressions)
	expr: ^Expression
	if p.cur_type == .Identifier || p.cur_type == .Get || p.cur_type == .Set ||
	   p.cur_type == .From || p.cur_type == .Of || p.cur_type == .As ||
	   p.cur_type == .Let || p.cur_type == .Static || p.cur_type == .Constructor {
		// Inline identifier parse + LHS tail
		id_tok := p.cur_tok
		eat(p)
		id, id_e := new_expr(p, Identifier)
		id.loc = loc_from_token(id_tok)
		id.name = id_tok.value
		id.loc.span.end = prev_end_offset(p)
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
			eat(p)
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
				member.property = pid_e
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
			}
			eat(p)
			if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
				prop := parse_identifier_name(p)
				member := new_node(p, MemberExpression)
				member.loc = loc_from_expr(expr)
				member.object = expr
				// Check if this is a private identifier (starts with #)
				if len(prop.name) > 0 && prop.name[0] == '#' {
					// Create PrivateIdentifier, strip the # prefix
					pid := new_node(p, PrivateIdentifier)
					pid.loc = prop.loc
					pid.name = prop.name[1:]
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
				eat(p)
				prop := parse_assignment_expression(p)
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
			} else {
				report_error(p, "Unexpected token after ?.")
				return expr
			}
		case .LBracket:
			eat(p)
			prop := parse_assignment_expression(p)
			if prop == nil { return nil }
			if !expect_token(p, .RBracket) { return nil }
			mem2, mem2_e := new_expr(p, MemberExpression)
			mem2.loc = loc_from_expr(expr)
			mem2.object = expr
			mem2.property = prop
			mem2.computed = true
			mem2.optional = false
			mem2.loc.span.end = prev_end_offset(p)
			expr = mem2_e
		case .LParen:
			// Identical recording path for the had-line-terminator branch below;
			// see the main .LParen case above for the rationale.
			if !allow_call {
				return expr
			}
			args := parse_arguments(p)
			call, call_e := new_expr(p, CallExpression)
			call.loc = loc_from_expr(expr)
			// If parenthesized, use pending_paren_start for CallExpression start
			if p.pending_paren_start != max(u32) && p.pending_paren_start <= call.loc.span.start {
				call.loc.span.start = p.pending_paren_start
			}
			call.callee = expr
			call.arguments = args
			call.optional = false
			call.loc.span.end = prev_end_offset(p)
			expr = call_e
		case .TemplateHead, .Template:
			tagged := new_node(p, TaggedTemplateExpression)
			tagged.loc = loc_from_expr(expr)
			tagged.tag = expr
			tagged.quasi = parse_template_literal(p)
			tagged.loc.span.end = prev_end_offset(p)
			expr = expression_from(p, tagged)
		case .Not:
			// TS non-null assertion `x!`. Only consume `!` as a postfix when
			// the next token can't start a new expression — otherwise `a!b` is
			// ambiguous. Safe next-tokens: operator/punct/terminator.
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
			     .Arrow, .EOF, .In, .Instanceof, .As, .Satisfies:
				allow = true
			}
			// IMPORTANT: in Odin `break` inside `switch` inside `for` exits
			// the SWITCH only. If we just `break`, the for-loop reruns with
			// p.cur_type still == .Not — infinite loop. Must exit the tail
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
			nn := new_node(p, TSNonNullExpression)
			nn.loc = loc_from_expr(expr)
			nn.expression = expr
			nn.loc.span.end = prev_end_offset(p)
			expr = expression_from(p, nn)
			continue
		case .LAngle:
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
			follow_ok := false
			if targs != nil && len(p.errors) == snap.errors_len {
				#partial switch p.cur_type {
				case .LParen, .TemplateHead, .Template,
				     .Dot, .OptionalChain,
				     .Comma, .Semi, .RParen, .RBracket, .RBrace,
				     .EOF, .Colon, .Question,
				     .Eq, .NotEq, .EqStrict, .NotEqStrict,
				     .LogicalAnd, .LogicalOr, .Nullish,
				     .As, .Satisfies:
					follow_ok = true
				}
			}
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
			// Commit: if followed by `(`, it's a CallExpression with
			// type_parameters; other stand-alone `foo<T>` uses (ES2023 TS
			// TSInstantiationExpression) are not yet modelled — rollback
			// those and let the outer parser handle them.
			if is_token(p, .LParen) {
				args := parse_arguments(p)
				call, call_e := new_expr(p, CallExpression)
				call.loc = loc_from_expr(expr)
				call.callee = expr
				call.arguments = args
				call.type_parameters = targs
				call.optional = false
				call.loc.span.end = prev_end_offset(p)
				expr = call_e
				continue
			}
			// No `(` follows — stand-alone TSInstantiationExpression isn't
			// modelled yet. Rollback and let outer parser take the `<` as
			// a binary operator (which will likely error, matching OXC on
			// those rare forms).
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

	#partial switch current.type {
	case .Import:
		// Check for dynamic import: import(specifier)
		if is_next_token(p, .LParen) {
			return parse_dynamic_import(p)
		}
		// Check for import.meta
		if is_next_token(p, .Dot) {
			eat(p) // consume import
			if !expect_token(p, .Dot) {
				return nil
			}
			meta_name := parse_identifier(p)

			meta_prop := new_node(p, MetaProperty)
			meta_prop.loc = loc_from_token(current)
			meta_prop.meta = Identifier{
				loc  = loc_from_token(current),
				name = "import",
			}
			meta_prop.property = Identifier{
				loc  = meta_name.loc,
				name = meta_name.name,
			}
			meta_prop.loc.span.end = prev_end_offset(p)
			p.has_module_syntax = true
			// Collect ESM import.meta record
			esm_import_meta := ESMImportMeta{
				start = meta_prop.loc.span.start,
				end = meta_prop.loc.span.end,
			}
			append(&p.importMetas, esm_import_meta)
			return expression_from(p, meta_prop)
		}
		// Static import - not valid in expression context
		report_error(p, "Unexpected import in expression context")
		return nil

	case .This:
		eat(p)
		this := new_node(p, ThisExpression)
		this.loc = loc_from_token(current)
		this.loc.span.end = prev_end_offset(p)
		return expression_from(p, this)

	case .PrivateIdentifier:
		// Private field reference: #x (used in expressions like #x in this)
		name := current.value
		if len(name) > 0 && name[0] == '#' {
			name = name[1:]
		}
		pid := new_node(p, PrivateIdentifier)
		pid.loc = loc_from_token(current)
		pid.name = name
		eat(p)
		pid.loc.span.end = prev_end_offset(p)
		return expression_from(p, pid)

	case .Super:
		eat(p)
		super := new_node(p, Super)
		super.loc = loc_from_token(current)
		super.loc.span.end = prev_end_offset(p)
		return expression_from(p, super)

	case .Null:
		eat(p)
		nl, nl_e := new_expr(p, NullLiteral)
		nl.loc = loc_from_token(current)
		nl.loc.span.end = prev_end_offset(p)
		return nl_e

	case .True, .False:
		eat(p)
		bl, bl_e := new_expr(p, BooleanLiteral)
		bl.loc = loc_from_token(current)
		bl.value = current.type == .True
		bl.loc.span.end = prev_end_offset(p)
		return bl_e

	case .Number:
		eat(p)
		num, num_e := new_expr(p, NumericLiteral)
		num.loc = loc_from_token(current)
		num.raw = current.value
		if val, ok := current.literal.(f64); ok {
			num.value = val
		}
		num.loc.span.end = prev_end_offset(p)
		return num_e

	case .String:
		eat(p)
		str, str_e := new_expr(p, StringLiteral)
		str.loc = loc_from_token(current)
		str.raw = current.value
		if val, ok := current.literal.(string); ok {
			str.value = val
		}
		str.loc.span.end = prev_end_offset(p)
		return str_e

	case .BigInt:
		eat(p)
		big := new_node(p, BigIntLiteral)
		big.loc = loc_from_token(current)
		big.raw = current.value
		big.value = current.value  // Store as string
		big.loc.span.end = prev_end_offset(p)
		return expression_from(p, big)

	case .Async:
		// async function expression or arrow function
		// Lookahead to check what follows async
		next := peek_dispatch(p)
		if next.type == .Function {
			// async function() {} - function expression
			return parse_function_expression(p)
		} else if next.type == .Identifier || next.type == .LParen {
			// This might be an async arrow function: async x => x or async () => {}
			if next.type == .Identifier {
				// async x => ...
				eat(p) // consume async
				param_ident := parse_identifier(p)
				if is_token(p, .Arrow) {
					return parse_async_arrow_function(p, param_ident)
				}
				// Not an arrow, return the identifier as expression (async becomes identifier)
				ident := new_node(p, Identifier)
				ident.loc = loc_from_token(current)
				ident.name = "async"
				ident.loc.span.end = prev_end_offset(p)
				return expression_from(p, ident)
			} else if next.type == .LParen {
				// async () => ...
				eat(p) // consume async
				return parse_async_arrow_with_parens(p, current)
			}
		}
		// async as identifier
		eat(p)
		ident := new_node(p, Identifier)
		ident.loc = loc_from_token(current)
		ident.name = "async"
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
		eat(p)
		id, id_expr := new_expr(p, Identifier)
		id.loc = loc_from_token(current)
		id.name = current.value
		id.loc.span.end = prev_end_offset(p)
		return id_expr

	case .LParen:
		// Check for arrow function with empty params: () => ...
		if is_next_token(p, .RParen) {
			// Potential empty arrow function params
			eat(p) // consume (
			eat(p) // consume )
			if is_token(p, .Arrow) {
				// This is () => ... - return a marker for empty params
				seq := new_node(p, SequenceExpression)
				seq.loc = loc_from_token(current)
				seq.expressions = make([dynamic]^Expression, 0, 4, p.allocator)
				return expression_from(p, seq)
			}
			// Not an arrow, return nil (empty parens not valid expression)
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
		// `(` would overwrite the outer's stamp — harmless because the inner
		// is consumed and cleared before the outer reaches `=>`.
		paren_start := cur_loc(p).span.start
		eat(p)
		// Save and clear pending_paren_start so nested expressions don't use this paren.
		// We'll restore it below only if the next token is Arrow (for arrow function params).
		prev_pending_paren := p.pending_paren_start
		p.pending_paren_start = max(u32)
		prev_no_in := p.no_in
		p.no_in = false  // 'in' is always valid inside parentheses
		expr := parse_expr_with_prec(p, .Comma)
		p.no_in = prev_no_in
		if expr == nil {
			return nil
		}
		if !expect_token(p, .RParen) {
			return nil
		}
		// Note: OXC/Acorn do NOT adjust the inner expression span to
		// include the parentheses in most cases. The parentheses are
		// syntactic, not semantic — the inner expression keeps its own
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
		return expr

	case .LBracket:
		return parse_array_expr(p)

	case .LBrace:
		return parse_object_expr(p)

	case .Function:
		return parse_function_expression(p)

	case .Class:
		return parse_class_expression(p)

	case .New:
		return parse_new_expr(p)

	case .Template, .TemplateHead:
		return parse_template_literal(p)

	case .RegularExpression:
		eat(p)
		regex := new_node(p, RegExpLiteral)
		regex.loc = loc_from_token(current)
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
		//   JSX / TSX → JSX element (existing behaviour).
		//   TS       → TS type assertion `<Type>expr` or generic arrow
		//               `<T>(x) => x`. No JSX ambiguity in pure TS mode.
		//   JS       → syntax error (comparison operator needs a LHS).
		if allow_jsx_mode(p) {
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
	arr.elements = make([dynamic]Maybe(^Expression), 0, 8, p.allocator)

	for !is_token(p, .RBracket) && !is_token(p, .EOF) {
		if match_token(p, .Comma) {
			// Sparse element
			append(&arr.elements, nil)
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
				append(&arr.elements, Maybe(^Expression)(expression_from(p, spread)))
			}
		} else {
			elem := parse_assignment_expression(p)
			if elem != nil {
				append(&arr.elements, Maybe(^Expression)(elem))
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

parse_object_expr :: proc(p: ^Parser) -> ^Expression {
	start := cur_loc(p)

	if !expect_token(p, .LBrace) {
		return nil
	}

	obj := new_node(p, ObjectExpression)
	obj.loc = start
	obj.properties = make([dynamic]Property, 0, 4, p.allocator)

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
			append(&obj.properties, prop^)
		}

		if !match_token(p, .Comma) {
			// Treat semicolons as property separators too (error recovery)
			if is_token(p, .Semi) {
				for is_token(p, .Semi) {
					eat(p)
				}
			} else {
				break
			}
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
		   next.type == .LBracket || next.type == .Mul ||
		   is_keyword_usable_as_property_name(next.type) {
			if is_token(p, .Get) {
				is_getter = true
			} else {
				is_setter = true
			}
			eat(p)
		}
	} else if is_token(p, .Async) {
		// Only treat as async if followed by a property name or *.
		next := peek_token(p)
		if next.type == .Identifier || next.type == .String || next.type == .Number ||
		   next.type == .LBracket || next.type == .Mul || next.type == .LParen ||
		   is_keyword_usable_as_property_name(next.type) {
			eat(p)
			is_async = true
		}
	}

	// Check for generator modifier (can come after async or before identifier)
	if is_token(p, .Mul) {
		eat(p)
		is_generator = true
	}

	// Parse key
	if match_token(p, .LBracket) {
		computed = true
		key = parse_assignment_expression(p)
		if key == nil {
			return nil
		}
		if !expect_token(p, .RBracket) {
			return nil
		}
	} else if is_token(p, .Identifier) || is_token(p, .String) || is_token(p, .Number) ||
	          is_keyword_usable_as_property_name(p.cur_type) {
		key = parse_property_name(p)
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
		// Parse params (getters have empty params, setters have one param)
		params := parse_function_params(p)
		if !expect_token(p, .RParen) {
			return nil
		}
		body := parse_function_body(p)

		fn := new_node(p, FunctionExpression)
		fn.loc = fn_start
		fn.params = params
		fn.body = body
		fn.generator = is_generator
		fn.async = is_async
		fn.loc.span.end = prev_end_offset(p)
		value = expression_from(p, fn)
	} else if is_token(p, .LParen) {
		// Method shorthand: foo() {}
		kind = .Method
		// Capture location of ( for the FunctionExpression
		fn_start := cur_loc(p)
		if !expect_token(p, .LParen) {
			return nil
		}
		params := parse_function_params(p)
		if !expect_token(p, .RParen) {
			return nil
		}
		// Set generator context before parsing body
		prev_in_generator := p.in_generator
		if is_generator {
			p.in_generator = true
		}
		body := parse_function_body(p)
		p.in_generator = prev_in_generator

		fn := new_node(p, FunctionExpression)
		fn.loc = fn_start
		fn.params = params
		fn.body = body
		fn.generator = is_generator
		fn.async = is_async
		fn.loc.span.end = prev_end_offset(p)
		value = expression_from(p, fn)
	} else if match_token(p, .Colon) {
		// Regular property with value
		// Use Assignment precedence - comma separates properties, not expressions
		value = parse_expr_with_prec(p, .Assignment)
	} else if match_token(p, .Assign) {
		// Shorthand with default: { foo = defaultValue } (destructuring assignment pattern)
		// Parsed as AssignmentExpression with = operator
		default_val := parse_expr_with_prec(p, .Assignment)
		assign := new_node(p, AssignmentExpression)
		assign.loc = start
		assign.operator = .Assign
		assign.left = key
		assign.right = default_val
		assign.loc.span.end = prev_end_offset(p)
		shorthand = true
		value = expression_from(p, assign)
	} else {
		// Shorthand property: { foo } means { foo: foo }
		// Not valid for generators/getters/setters
		if is_generator || is_async {
			report_error(p, "Generator/async shorthand property not allowed")
			return nil
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
		ident.loc = loc_from_token(current)
		ident.name = current.value
		ident.loc.span.end = prev_end_offset(p)
		return expression_from(p, ident)

	case .String:
		eat(p)
		str := new_node(p, StringLiteral)
		str.loc = loc_from_token(current)
		str.raw = current.value
		if val, ok := current.literal.(string); ok {
			str.value = val
		}
		str.loc.span.end = prev_end_offset(p)
		return expression_from(p, str)

	case .Number:
		eat(p)
		num := new_node(p, NumericLiteral)
		num.loc = loc_from_token(current)
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
			ident.loc = loc_from_token(current)
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
	// via the union cast — the old transmute(^FunctionDeclaration)stmt was
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
	if is_token(p, .Identifier) {
		current := get_current(p)
		id = BindingIdentifier{
			loc  = loc_from_token(current),
			name = current.value,
		}
		eat(p)
	}

	super_class: Maybe(^Expression)
	if match_token(p, .Extends) {
		super_class = parse_left_hand_side_expr(p)
	}

	body := parse_class_body(p)

	expr := new_node(p, ClassExpression)
	expr.loc = start
	expr.id = id
	expr.super_class = super_class
	expr.body = body
	expr.loc.span.end = prev_end_offset(p)

	return expression_from(p, expr)
}

parse_new_expr :: proc(p: ^Parser) -> ^Expression {
	start := cur_loc(p)
	eat(p) // consume new

	// new.target — MetaProperty
	if is_token(p, .Dot) {
		next := peek_token(p)
		if next.value == "target" {
			eat(p) // consume .
			target_tok := get_current(p)
			eat(p) // consume target
			meta := new_node(p, MetaProperty)
			meta.loc = start
			meta.meta = Identifier{loc = start, name = "new"}
			meta.property = Identifier{loc = loc_from_token(target_tok), name = "target"}
			meta.loc.span.end = prev_end_offset(p)
			return expression_from(p, meta)
		}
	}

	callee := parse_member_expr(p)
	if callee == nil {
		return nil
	}

	// TS generic type arguments: `new Foo<string>()`.
	targs: Maybe(^TSTypeParameterInstantiation)
	if is_token(p, .LAngle) {
		targs = parse_ts_type_arguments(p)
	}

	args: [dynamic]^Expression
	if is_token(p, .LParen) {
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

	args := make([dynamic]^Expression, 0, 4, p.allocator)

	if !is_token(p, .RParen) {
		for {
			if is_token(p, .Dot3) {
				spread_start := cur_loc(p) // Capture location of ... before eating
				eat(p)
				arg := parse_assignment_expression(p)
				if arg != nil {
					spread := new_node(p, SpreadElement)
					spread.loc = spread_start // Use location of ... token, not the argument
					spread.argument = arg
					spread.loc.span.end = prev_end_offset(p)
					append(&args, expression_from(p, spread))
				}
			} else {
				arg := parse_assignment_expression(p)
				if arg != nil {
					append(&args, arg)
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

parse_yield_expr :: proc(p: ^Parser) -> ^Expression {
	start := cur_loc(p)
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

	argument: Maybe(^Expression)
	if !has_newline && !is_token(p, .Semi) && !is_token(p, .RParen) && !is_token(p, .RBracket) && !is_token(p, .RBrace) && !is_token(p, .Comma) {
		argument = parse_assignment_expression(p)
	}

	yield := new_node(p, YieldExpression)
	yield.loc = start
	yield.argument = argument
	yield.delegate = delegate
	yield.loc.span.end = prev_end_offset(p)

	return expression_from(p, yield)
}

parse_template_literal :: proc(p: ^Parser) -> ^Expression {
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
			loc  = loc_from_token(current),
			tail = true,
			raw  = current.value,
		}
		if cooked, ok := current.literal.(string); ok {
			elem.cooked = cooked
		}
		append(&tmpl.quasis, elem)
		eat(p)
		tmpl.loc.span.end = prev_end_offset(p) + 1 // Include closing backtick
		p.prev_token_end = tmpl.loc.span.end // Update for parent nodes
		return expression_from(p, tmpl)
	}

	// Handle template with expressions: `hello ${name} world`
	if current.type == .TemplateHead {
		// First quasi: `hello ${
		elem := TemplateElement{
			loc  = loc_from_token(current),
			tail = false,
			raw  = current.value,
		}
		if cooked, ok := current.literal.(string); ok {
			elem.cooked = cooked
		}
		append(&tmpl.quasis, elem)
		eat(p) // consume TemplateHead

		// Parse embedded expressions and middle/tail parts
		for {
			// Parse expression
			expr := parse_assignment_expression(p)
			if expr != nil {
				append(&tmpl.expressions, expr)
			}

			// Expect TemplateMiddle or TemplateTail
			tok := get_current(p)
			if tok.type == .TemplateMiddle {
				elem := TemplateElement{
					loc  = loc_from_token(tok),
					tail = false,
					raw  = tok.value,
				}
				if cooked, ok := tok.literal.(string); ok {
					elem.cooked = cooked
				}
				append(&tmpl.quasis, elem)
				eat(p)
				// Continue to parse next expression
			} else if tok.type == .TemplateTail {
				elem := TemplateElement{
					loc  = loc_from_token(tok),
					tail = true,
					raw  = tok.value,
				}
				if cooked, ok := tok.literal.(string); ok {
					elem.cooked = cooked
				}
				append(&tmpl.quasis, elem)
				eat(p)
				break
			} else {
				report_error(p, "Expected template literal continuation")
				return nil
			}
		}

		tmpl.loc.span.end = prev_end_offset(p) + 1 // Include closing backtick
		p.prev_token_end = tmpl.loc.span.end // Update for parent nodes
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
// `{a: {b}} = {}`) is handled by later parse passes — this helper only needs
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
		// Previously this dropped properties on the floor — emitting an empty
		// `ObjectPattern { properties: [] }` for every arrow-function param of
		// the form `({a, b: c = 1, ...rest}) => ...`. Symptom: every nested
		// default string / identifier inside destructured arrow params was
		// invisible to downstream walkers (framer-motion.js, swagger-ui.js).
		op := new_node(p, ObjectPattern)
		op.loc = e.loc
		op.properties = make([dynamic]ObjectPatternProperty, 0, len(e.properties), p.allocator)
		for prop in e.properties {
			// Spread element in object expression -> RestElement in pattern.
			// Detected by nil key + SpreadElement value (parse_object_expression
			// stashes the SpreadElement in the value slot with key=nil).
			if prop.key == nil {
				if spread, ok := prop.value.(^SpreadElement); ok {
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
						append(&op.properties, pp)
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
			append(&op.properties, pp)
		}
		return op, true
	case ^ArrayExpression:
		// Convert each ArrayExpression.element into an ArrayPattern element.
		// Same empty-pattern bug as ObjectExpression above.
		ap := new_node(p, ArrayPattern)
		ap.loc = e.loc
		elems := make([]Maybe(Pattern), len(e.elements), p.allocator)
		for i := 0; i < len(e.elements); i += 1 {
			elem, has_elem := e.elements[i].(^Expression)
			if !has_elem || elem == nil {
				continue // sparse hole — leave as nil Maybe
			}
			// Spread element -> RestElement (must be last, but we don't enforce here).
			if spread, is_spread := elem^.(^SpreadElement); is_spread {
				inner, ok := expr_to_pattern(p, spread.argument)
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
	}
	return nil, false
}

parse_arrow_function :: proc(p: ^Parser, left: ^Expression, is_async := false) -> ^Expression {
	start: Loc
	if left != nil {
		start = loc_from_expr(left)
		// If a `(` was opened immediately before this expression, use its
		// position as the arrow's start — matches ESTree/OXC/Acorn span
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

	// Set async context for body parsing
	prev_async := p.in_async
	if is_async {
		p.in_async = true
	}

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
		body = parse_assignment_expression(p)
	}

	p.in_async = prev_async

	// Convert left to parameters
	params := make([dynamic]FunctionParameter, 0, 4, p.allocator)

	if left != nil {
		#partial switch e in left {
		case ^Identifier:
			ident := new_node(p, Identifier)
			ident^ = e^
			param := FunctionParameter{
				loc     = e.loc,
				pattern = ident,
			}
			append(&params, param)
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
					append(&params, param)
				}
			}
		case ^ObjectExpression:
			// Single destructure param: `({a, b}) => ...`. Route through
			// expr_to_pattern so the properties are carried across; previously
			// this allocated an empty ObjectPattern, silently dropping every
			// destructured binding (and every nested default value with it).
			if pat, ok := expr_to_pattern(p, left); ok {
				param := FunctionParameter{ loc = e.loc, pattern = pat }
				append(&params, param)
			}
		case ^ArrayExpression:
			// Single destructure param: `([a, b]) => ...` — same fix as
			// ObjectExpression above.
			if pat, ok := expr_to_pattern(p, left); ok {
				param := FunctionParameter{ loc = e.loc, pattern = pat }
				append(&params, param)
			}
		case ^SequenceExpression:
			if len(e.expressions) == 0 {
				// Empty parameters: () => ... (marker from parse_primary_expr)
				// params stays empty
			} else {
				// Multiple parameters: (a, b) => ...
				// Each element in the sequence should be an identifier (or pattern)
				for expr_ptr in e.expressions {
					#partial switch arg in expr_ptr^ {
					case ^Identifier:
						param_ident := new_node(p, Identifier)
						param_ident^ = arg^
						param := FunctionParameter{
							loc     = arg.loc,
							pattern = param_ident,
						}
						append(&params, param)
					case ^SpreadElement:
						// Rest parameter: (...rest) => ...
						rest := new_node(p, RestElement)
						rest.loc = arg.loc
						// SpreadElement.argument is ^Expression
						// For arrow params, the argument should be an Identifier
						// RestElement.argument expects Pattern (^Identifier), so we need to create a new pointer
						ident_expr := arg.argument
						if ident_expr != nil {
							#partial switch id in ident_expr^ {
							case ^Identifier:
								ident_ptr := new_node(p, Identifier)
								ident_ptr^ = id^
								rest.argument = ident_ptr
							case:
								report_error(p, "Expected identifier in rest parameter")
							}
						}
						rest.loc.span.end = prev_end_offset(p)
						param := FunctionParameter{
							loc     = arg.loc,
							pattern = rest,
						}
						append(&params, param)
					case ^ObjectExpression:
						// Convert ObjectExpression -> ObjectPattern via expr_to_pattern
						// so nested properties, defaults, and rest elements are all
						// carried through. The old path allocated an empty pattern,
						// silently dropping every destructured field in multi-arrow
						// params like `(a, {x=1}, b) => ...`.
						if pat, ok := expr_to_pattern(p, expr_ptr); ok {
							param := FunctionParameter{ loc = arg.loc, pattern = pat }
							append(&params, param)
						}
					case ^ArrayExpression:
						// Same fix as ObjectExpression above. The prior inline loop
						// only understood bare Identifier elements, dropping any
						// nested AssignmentExpression / SpreadElement / Pattern.
						if pat, ok := expr_to_pattern(p, expr_ptr); ok {
							param := FunctionParameter{ loc = arg.loc, pattern = pat }
							append(&params, param)
						}
					case ^AssignmentExpression:
						// Default parameter: `(a = 1, b = 2) => ...`. The sequence
						// parser sees `a = 1` as an AssignmentExpression (operator `=`)
						// which we convert into an ESTree AssignmentPattern whose
						// `left` is the identifier/pattern and `right` is the default
						// value. Previously this fell through to the "Expected
						// identifier" error branch — breaking 34+ real-world files
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
						append(&params, param)
					case:
						report_error(p, "Expected identifier in arrow function parameters")
					}
				}
			}
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

	return expression_from(p, arrow)
}

parse_conditional_expr :: proc(p: ^Parser, test: ^Expression) -> ^Expression {
	start := loc_from_expr(test)
	eat(p) // consume ?

	consequent := parse_assignment_expression(p)
	if consequent == nil {
		return nil
	}

	if !expect_token(p, .Colon) {
		return nil
	}

	alternate := parse_assignment_expression(p)
	if alternate == nil {
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

parse_assignment_expr :: proc(p: ^Parser, left: ^Expression) -> ^Expression {
	start := loc_from_expr(left)

	current := get_current(p)
	op := token_to_assignment_op(current.type)

	eat(p)

	right := parse_expr_with_prec(p, .Assignment)
	if right == nil {
		return nil
	}

	// Validate pattern conversion for = operator (destructuring assignment)
	if op == .Assign {
		_, _ = expr_to_pattern(p, left)
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
	current := get_current(p)
	eat(p)
	return Identifier{
		loc  = loc_from_token(current),
		name = current.value,
	}
}

parse_identifier_name :: proc(p: ^Parser) -> Identifier {
	return parse_identifier(p)
}

parse_string_literal :: proc(p: ^Parser) -> StringLiteral {
	current := get_current(p)
	eat(p)
	return StringLiteral{
		loc   = loc_from_token(current),
		raw   = current.value,
		value = current.literal.(string) or_else "",
	}
}

// ============================================================================
// Async Arrow Function Helpers
// ============================================================================

parse_async_arrow_function :: proc(p: ^Parser, param: Identifier) -> ^Expression {
	start := param.loc

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
		if block_stmt != nil {
			// Same Bug-H class as the multi-param arrow arm above. Extract the
			// inner ^BlockStatement via type assertion, not a raw pointer cast.
			if bs, ok := block_stmt^.(^BlockStatement); ok {
				body = bs
			}
		}
	} else {
		body = parse_assignment_expression(p)
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
	append(&params, fn_param)

	arrow := new_node(p, ArrowFunctionExpression)
	arrow.loc = start
	arrow.params = params
	arrow.body = body
	arrow.expression = !is_block_body
	arrow.async = true
	arrow.loc.span.end = prev_end_offset(p)

	return expression_from(p, arrow)
}

parse_async_arrow_with_parens :: proc(p: ^Parser, async_tok: Token) -> ^Expression {
	start := loc_from_token(async_tok)

	// Parse parenthesized parameter list
	if !expect_token(p, .LParen) {
		return nil
	}

	params := parse_function_params(p)

	if !expect_token(p, .RParen) {
		return nil
	}

	if !expect_token(p, .Arrow) {
		return nil
	}

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
		if block_stmt != nil {
			// Same Bug-H class as the other two arrow-function arms above.
			// Extract the inner ^BlockStatement via type assertion, not a raw
			// pointer cast. prettier.js is the third-site canary.
			if bs, ok := block_stmt^.(^BlockStatement); ok {
				body = bs
			}
		}
	} else {
		body = parse_assignment_expression(p)
	}

	p.in_async = prev_async

	arrow := new_node(p, ArrowFunctionExpression)
	arrow.loc = start
	arrow.params = params
	arrow.body = body
	arrow.expression = !is_block_body
	arrow.async = true
	arrow.loc.span.end = prev_end_offset(p)

	return expression_from(p, arrow)
}

// ============================================================================
// Dynamic Import Helper
// ============================================================================

parse_dynamic_import :: proc(p: ^Parser) -> ^Expression {
	start := cur_loc(p)

	eat(p) // consume import

	// consume (
	if !is_token(p, .LParen) {
		report_error(p, "Expected ( after import")
		return nil
	}
	eat(p)

	specifier := parse_assignment_expression(p)
	if specifier == nil {
		return nil
	}

	// consume )
	if !is_token(p, .RParen) {
		report_error(p, "Expected ) after import specifier")
		return nil
	}
	eat(p)

	import_expr := new_node(p, ImportExpression)
	import_expr.loc = start
	import_expr.source = specifier
	import_expr.loc.span.end = prev_end_offset(p)

	// Collect ESM dynamic import record.
	// NOTE: dynamic `import()` expressions are valid in both Scripts and
	// Modules per ECMA-262, so they do NOT imply module syntax. Only static
	// `import`/`export` declarations (and top-level `await`/`import.meta`)
	// flip has_module_syntax — matches OXC/Acorn/Babel behaviour.
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
	append(&p.dynamicImports, esm_dynamic)

	return expression_from(p, import_expr)
}

// ============================================================================
// Import Attributes (Phase 1)
// ============================================================================

parse_import_attributes :: proc(p: ^Parser) -> [dynamic]ImportAttribute {
	attributes := make([dynamic]ImportAttribute, 0, 4, p.allocator)
	if !is_token(p, .With) && !is_token(p, .Assert) { return attributes }
	eat(p)
	if !expect_token(p, .LBrace) { return attributes }
	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		attr_start := cur_loc(p)
		key: IdentifierName
		if is_token(p, .String) {
			current := get_current(p)
			key = IdentifierName{loc = loc_from_token(current), name = current.literal.(string) or_else current.value}
			eat(p)
		} else {
			id := parse_identifier_name(p)
			key = IdentifierName{loc = id.loc, name = id.name}
		}
		if !expect_token(p, .Colon) { break }
		value := parse_string_literal(p)
		append(&attributes, ImportAttribute{loc = attr_start, key = key, value = value})
		if !match_token(p, .Comma) { break }
	}
	expect_token(p, .RBrace)
	return attributes
}

parse_decorators :: proc(p: ^Parser) -> [dynamic]Decorator {
	decorators := make([dynamic]Decorator, 0, 4, p.allocator)
	for is_token(p, .At) {
		start := cur_loc(p)
		eat(p)
		expr := parse_left_hand_side_expr(p)
		d := Decorator{loc = start, expression = expr}
		d.loc.span.end = prev_end_offset(p)
		append(&decorators, d)
	}
	return decorators
}

parse_decorated_class :: proc(p: ^Parser) -> ^Statement {
	decorators := parse_decorators(p)
	if is_token(p, .Export) {
		stmt := parse_export_declaration(p)
		if stmt != nil {
			#partial switch s in stmt^ {
			case ^ExportNamedDeclaration:
				if decl, ok := s.declaration.(^Declaration); ok && decl != nil {
					if cd, ok2 := decl^.(^ClassDeclaration); ok2 {
						cd.expr.decorators = decorators
					}
				}
			}
		}
		return stmt
	}
	if !is_token(p, .Class) { report_error(p, "Expected class after decorator"); return nil }
	stmt := parse_class_declaration(p)
	if stmt != nil {
		#partial switch s in stmt^ {
		case ^ClassDeclaration:
			s.expr.decorators = decorators
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
		// (2 bytes) — matches OXC's JSXOpeningFragment.{start,end}.
		opening_loc := start
		opening_loc.span.end = u32(prev_end_offset(p))
		children := parse_jsx_children(p)
		// Closing fragment `</>` spans [<, >] — start is at the `<`, not after `</`.
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
	elem := new_node(p, JSXElement)
	elem.loc = start
	elem.opening_element = opening
	elem.children = children
	elem.closing_element = closing
	elem.loc.span.end = prev_end_offset(p)
	return expression_from(p, elem)
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
	eat(p)
	if is_token(p, .Minus) {
		parts := make([dynamic]string, 0, 4, p.allocator)
		append(&parts, name)
		for is_token(p, .Minus) {
			append(&parts, "-")
			eat(p)
			c := get_current(p)
			append(&parts, c.value)
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
	opening.attributes = make([dynamic]JSXAttributeItem, 0, 4, p.allocator)
	for !is_token(p, .RAngle) && !is_token(p, .Div) && !is_token(p, .EOF) {
		if is_token(p, .LBrace) {
			start := cur_loc(p)
			eat(p); expect_token(p, .Dot3)
			expr := parse_assignment_expression(p)
			expect_token(p, .RBrace)
			spread := new_node(p, JSXSpreadAttribute)
			spread.loc = start; spread.argument = expr
			spread.loc.span.end = prev_end_offset(p)
			append(&opening.attributes, spread)
		} else if is_jsx_identifier_token(p) {
			attr_start := cur_loc(p)
			attr_name := parse_jsx_attribute_name(p)
			attr_value: Maybe(^Expression)
			if is_token(p, .Assign) {
				eat(p)
				if is_token(p, .String) {
					str := parse_string_literal(p)
					str_expr := new_node(p, StringLiteral); str_expr^ = str
					attr_value = expression_from(p, str_expr)
				} else if is_token(p, .LBrace) {
					start := cur_loc(p)
					eat(p); expr := parse_assignment_expression(p); expect_token(p, .RBrace)
					container := new_node(p, JSXExpressionContainer)
					container.loc = start; container.expression = expr
					container.loc.span.end = prev_end_offset(p)
					attr_value = expression_from(p, container)
				} else if is_token(p, .LAngle) {
					attr_value = parse_jsx_element_or_fragment(p)
				}
			}
			attr: JSXAttribute
			attr.loc = attr_start; attr.name = attr_name; attr.value = attr_value
			attr.loc.span.end = prev_end_offset(p)
			append(&opening.attributes, attr)
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
		if is_token(p, .LAngle) {
			if peek_dispatch(p).type == .Div { break }
			nested := parse_jsx_element_or_fragment(p)
			if nested != nil {
				#partial switch v in nested^ {
				case ^JSXElement:  append(&children, v)
				case ^JSXFragment: append(&children, v)
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
			append(&children, container)
		} else {
			text := parse_jsx_text(p)
			if text != nil && text.value != "" { append(&children, text) }
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
	// closing `/>`), NOT at the current token's start — the lexer may have
	// skipped leading whitespace that JSX semantics require preserved.
	// e.g. `<div>Before {expr} after</div>` — after parsing `{expr}`, the
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
	p.lexer.offset = off
	p.lexer.cur = lex_token(p.lexer)
	p.lexer.nxt = lex_token(p.lexer)
	p.cur_type = p.lexer.cur.kind
	p.cur_tok.type = p.lexer.cur.kind
	p.cur_tok.loc.offset = int(p.lexer.cur.start)
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
//     : x is T          — TSTypePredicate { parameter_name, type_annotation, asserts:false }
//     : asserts x is T  — TSTypePredicate { parameter_name, type_annotation, asserts:true  }
//     : asserts x       — TSTypePredicate { parameter_name, type_annotation:nil, asserts:true }
// Falls back to a plain type annotation otherwise.
//
// The caller has NOT consumed `:`. This proc consumes the leading `:`.
parse_ts_return_type_annotation :: proc(p: ^Parser) -> ^TSTypeAnnotation {
	if !is_token(p, .Colon) { return nil }
	ann_start := cur_loc(p)
	eat(p) // consume `:` 

	// Detect "asserts <ident>" or "asserts <ident> is <type>" or "<ident> is <type>".
	// We need to peek WITHOUT committing, because the annotation can also be
	// a regular type like `string` or `T | null`.
	//
	// Heuristic: at this point the current token must be either
	//   - `.Asserts` identifier-keyword followed by an
	//     Identifier or This, optionally followed by `is <type>`. We can consume.
	//   - An Identifier followed by `.Is` — then it's `x is T`.
	//
	// "this is T" is also valid — where `this` is the parameter name.
	asserts := false
	pred_start := cur_loc(p)

	is_predicate := false
	if is_token(p, .Asserts) && (p.lexer.nxt.kind == .Identifier || p.lexer.nxt.kind == .This) {
		asserts = true
		eat(p) // consume `asserts`
		is_predicate = true
	} else if (is_token(p, .Identifier) || is_token(p, .This)) && p.lexer.nxt.kind == .Is {
		is_predicate = true
	}

	if is_predicate {
		// Parse parameter name: Identifier or `this`.
		name_loc := cur_loc(p)
		name_cur := get_current(p)
		name_ident := new_node(p, Identifier)
		name_ident.loc = loc_from_token(name_cur)
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
	ts_type := parse_ts_type(p)
	ann := new_node(p, TSTypeAnnotation)
	ann.loc = start; ann.type_annotation = ts_type
	ann.loc.span.end = prev_end_offset(p)
	return ann
}

// parse_ts_type_annotation_bare — like parse_ts_type_annotation but assumes
// the leading `:` or `=>` has already been consumed. The outer TSFunctionType
// needs a return type wrapped in TSTypeAnnotation, but the return type starts
// directly at the current token (no `:` delimiter between `=>` and the type).
parse_ts_type_annotation_bare :: proc(p: ^Parser) -> ^TSTypeAnnotation {
	start := cur_loc(p)
	ts_type := parse_ts_type(p)
	ann := new_node(p, TSTypeAnnotation)
	ann.loc = start; ann.type_annotation = ts_type
	ann.loc.span.end = prev_end_offset(p)
	return ann
}

// looks_like_ts_function_type — cheap detection for function type vs
// paren-wrapped type at a `(`. Caller is at `.LParen` in parse_ts_primary_type.
// See comments at the call site for the signal table.
looks_like_ts_function_type :: proc(p: ^Parser) -> bool {
	assert(p.cur_type == .LParen)
	nxt := p.lexer.nxt.kind
	if nxt == .RParen { return true }
	if nxt == .Dot3  { return true }
	if nxt != .Identifier { return false }

	snap := lexer_snapshot(p)
	eat(p) // consume `(`
	eat(p) // consume Identifier
	after := p.cur_type
	lexer_restore(p, snap)
	return after == .Colon || after == .Question
}

parse_ts_type :: proc(p: ^Parser) -> ^TSType {
	check := parse_ts_union_type(p)
	if check == nil { return nil }
	// Conditional type: `T extends U ? X : Y`
	if is_token(p, .Extends) {
		eat(p)
		exts := parse_ts_union_type(p)
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
	first := parse_ts_intersection_type(p)
	if first == nil { return nil }
	if !is_token(p, .BitOr) { return first }
	types := make([dynamic]^TSType, 0, 4, p.allocator)
	append(&types, first)
	for is_token(p, .BitOr) { eat(p); t := parse_ts_intersection_type(p); if t != nil { append(&types, t) } }
	u := new_node(p, TSUnionType); u.types = types
	if loc := get_ts_type_loc(first); loc != nil { u.loc = loc^ }
	u.loc.span.end = prev_end_offset(p)
	r := new_node(p, TSType); r^ = u; return r
}

parse_ts_intersection_type :: proc(p: ^Parser) -> ^TSType {
	first := parse_ts_primary_type(p)
	if first == nil { return nil }
	if !is_token(p, .BitAnd) { return first }
	types := make([dynamic]^TSType, 0, 4, p.allocator)
	append(&types, first)
	for is_token(p, .BitAnd) { eat(p); t := parse_ts_primary_type(p); if t != nil { append(&types, t) } }
	i := new_node(p, TSIntersectionType); i.types = types
	if loc := get_ts_type_loc(first); loc != nil { i.loc = loc^ }
	i.loc.span.end = prev_end_offset(p)
	r := new_node(p, TSType); r^ = i; return r
}

parse_ts_kw :: proc(p: ^Parser, $T: typeid, start: Loc) -> ^TSType {
	eat(p)
	node := new_node(p, T); node.loc = start; node.loc.span.end = prev_end_offset(p)
	result := new_node(p, TSType); result^ = node
	return parse_ts_postfix(p, result, start)
}

parse_ts_primary_type :: proc(p: ^Parser) -> ^TSType {
	start := cur_loc(p)
	#partial switch p.cur_type {
	case .LParen:
		// TS function type with named params: `(x: T, ...) => U`.
		// Detected cheaply via 1–2 token lookahead because the outer type
		// grammar has no ambiguity here — a `(` in a type position is
		// either a function type, a paren-wrapped type, or (illegally) a
		// tuple typo. Named params and rest params are only legal in a
		// function type, so their presence is a definitive signal.
		//
		// Signals (all require =>-terminated form):
		//   ()           — zero-arg function type (e.g. `() => void`).
		//   (...         — rest parameter.
		//   (Identifier : / (Identifier ?  — named param with annotation.
		if looks_like_ts_function_type(p) {
			params := parse_ts_sig_params(p)
			if !is_token(p, .Arrow) {
				report_error(p, "Expected '=>' in function type")
				return nil
			}
			eat(p) // consume `=>`
			ret_type := parse_ts_type_annotation_bare(p)
			fn := new_node(p, TSFunctionType)
			fn.loc = start
			fn.params = params
			fn.return_type = ret_type
			fn.loc.span.end = prev_end_offset(p)
			r := new_node(p, TSType); r^ = fn
			return parse_ts_postfix(p, r, start)
		}

		eat(p); inner := parse_ts_type(p); expect_token(p, .RParen)
		if is_token(p, .Arrow) {
			eat(p); parse_ts_type(p)
			fn := new_node(p, TSFunctionType); fn.loc = start; fn.loc.span.end = prev_end_offset(p)
			r := new_node(p, TSType); r^ = fn; return r
		}
		pn := new_node(p, TSParenthesizedType); pn.loc = start; pn.type_annotation = inner; pn.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = pn; return parse_ts_postfix(p, r, start)
	case .LBrace: return parse_ts_type_object(p)
	case .LBracket:
		eat(p); types := make([dynamic]^TSType, 0, 4, p.allocator)
		for !is_token(p, .RBracket) && !is_token(p, .EOF) { t := parse_ts_type(p); if t != nil { append(&types, t) }; if !match_token(p, .Comma) { break } }
		expect_token(p, .RBracket)
		tup := new_node(p, TSTupleType); tup.loc = start; tup.element_types = types; tup.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = tup; return r
	case .Void:   return parse_ts_kw(p, TSVoidKeyword, start)
	case .Null:   return parse_ts_kw(p, TSNullKeyword, start)
	case .This:   return parse_ts_kw(p, TSThisType, start)
	case .Never:  return parse_ts_kw(p, TSNeverKeyword, start)
	case .Typeof:
		eat(p); expr := parse_left_hand_side_expr(p)
		node := new_node(p, TSTypeQuery); node.loc = start; node.expr_name = expr; node.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = node; return parse_ts_postfix(p, r, start)
	case .Keyof:
		eat(p); operand := parse_ts_primary_type(p)
		node := new_node(p, TSTypeOperator); node.loc = start; node.operator = "keyof"; node.type_annotation = operand
		node.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = node; return r
	case .Infer:
		eat(p); pn := parse_identifier(p)
		node := new_node(p, TSInferType); node.loc = start
		node.type_parameter.name = BindingIdentifier{loc = pn.loc, name = pn.name}
		node.type_parameter.loc = pn.loc // span of the bare `V` — OXC shape
		node.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = node; return r
	case .String:
		lit := parse_string_literal(p); le := new_node(p, StringLiteral); le^ = lit
		node := new_node(p, TSLiteralType); node.loc = start; node.literal = expression_from(p, le); node.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = node; return r
	case .Number:
		cur := get_current(p); nl := new_node(p, NumericLiteral); nl.loc = loc_from_token(cur); nl.raw = cur.value
		if v, ok := cur.literal.(f64); ok { nl.value = v }; eat(p)
		node := new_node(p, TSLiteralType); node.loc = start; node.literal = expression_from(p, nl); node.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = node; return r
	case .True, .False:
		val := p.cur_type == .True; eat(p)
		bl := new_node(p, BooleanLiteral); bl.loc = start; bl.value = val
		node := new_node(p, TSLiteralType); node.loc = start; node.literal = expression_from(p, bl); node.loc.span.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = node; return r
	case .Identifier: return parse_ts_identifier_type(p)
	}
	return nil
}

parse_ts_identifier_type :: proc(p: ^Parser) -> ^TSType {
	start := cur_loc(p)
	value := get_current(p).value
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
	}
	return parse_ts_type_reference(p)
}

parse_ts_postfix :: proc(p: ^Parser, base: ^TSType, start: Loc) -> ^TSType {
	result := base
	for is_token(p, .LBracket) {
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
	return result
}

parse_ts_type_reference :: proc(p: ^Parser) -> ^TSType {
	start := cur_loc(p)
	cur := get_current(p)
	id := new_node(p, Identifier); id.loc = loc_from_token(cur); id.name = cur.value; eat(p)
	id_expr := expression_from(p, id)
	for is_token(p, .Dot) {
		eat(p); prop := parse_identifier_name(p)
		mem := new_node(p, MemberExpression); mem.loc = start; mem.object = id_expr
		pid := new_node(p, Identifier); pid.loc = prop.loc; pid.name = prop.name
		mem.property = expression_from(p, pid); mem.loc.span.end = prev_end_offset(p)
		id_expr = expression_from(p, mem)
	}
	targs: Maybe(^TSTypeParameterInstantiation)
	if is_token(p, .LAngle) { targs = parse_ts_type_arguments(p) }
	ref := new_node(p, TSTypeReference); ref.loc = start; ref.type_name = id_expr; ref.type_parameters = targs
	ref.loc.span.end = prev_end_offset(p)
	r := new_node(p, TSType); r^ = ref
	return parse_ts_postfix(p, r, start)
}

parse_ts_type_arguments :: proc(p: ^Parser) -> ^TSTypeParameterInstantiation {
	start := cur_loc(p); eat(p)
	params := make([dynamic]^TSType, 0, 4, p.allocator)
	for !is_token(p, .RAngle) && !is_token(p, .EOF) {
		t := parse_ts_type(p); if t != nil { append(&params, t) }; if !match_token(p, .Comma) { break }
	}
	expect_token(p, .RAngle)
	inst := new_node(p, TSTypeParameterInstantiation); inst.loc = start; inst.params = params; inst.loc.span.end = prev_end_offset(p)
	return inst
}

// parse_ts_lt_expression handles `<` at expression start in TS / TSX mode.
// Two productions are possible here:
//
//   1. Type assertion:  `<Type>expr`                       → TSTypeAssertion
//   2. Generic arrow:   `<T[, U, ...]>(params) => body`    → ArrowFunctionExpression
//                                                              with .type_parameters set
//
// In pure `.ts` (no JSX), there's no ambiguity with a JSX opening tag — both
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
			// Generic-arrow parse failed — roll back and, for the
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
	if !expect_token(p, .RAngle) {
		lexer_restore(p, snap)
		report_error(p, "Unexpected '<': not a valid TS type assertion or generic arrow")
		return nil
	}
	expr := parse_unary_expr(p)
	if expr == nil {
		lexer_restore(p, snap)
		report_error(p, "Unexpected '<': not a valid TS type assertion or generic arrow")
		return nil
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

// looks_like_ts_arrow_params — cheap 2-token lookahead to decide whether
// a `(` definitely opens TS arrow parameters (as opposed to a paren-wrapped
// expression). Called only in TS / TSX mode. Used by parse_primary_expr
// to gate try_parse_ts_arrow_params.
//
// Conservative signals (each uniquely identifies arrow params):
//   * `(...`            — rest parameter is only legal inside arrow params.
//   * `(Identifier :`   — `:Type` after an identifier in a paren-group is
//                         only legal as a parameter type annotation.
//
// We intentionally DO NOT trigger the trial on `(Identifier ,` /
// `(Identifier )` / `(Identifier =` / `({...` / `([...` — these all have a
// working paren-grouping path today that flows into parse_arrow_function via
// expr_to_pattern when `=>` follows. Expanding coverage to destructured
// params with type annotations (`({a}: P) => a`) is a future extension and
// needs the same trial-parse plumbing.
looks_like_ts_arrow_params :: proc(p: ^Parser) -> bool {
	assert(p.cur_type == .LParen)
	nxt := p.lexer.nxt.kind
	if nxt == .Dot3 { return true }
	if nxt != .Identifier { return false }

	// Need 2-token lookahead: current = `(`, nxt = Identifier, after
	// that = ? Use the trial snapshot to peek without committing.
	snap := lexer_snapshot(p)
	eat(p) // consume `(`
	eat(p) // consume Identifier
	after := p.cur_type
	lexer_restore(p, snap)
	return after == .Colon
}

// try_parse_ts_arrow_params — speculatively parse `(params) [:RetType]? =>
// body` starting at `(`. Returns the constructed ArrowFunctionExpression on
// success, or nil on failure with parser state fully restored to the `(`.
//
// The caller has already filtered via looks_like_ts_arrow_params(p), so the
// snapshot/rollback path is a safety net rather than the common case. On
// the happy path we build the arrow directly — no conversion from
// Expression→Pattern needed because parse_function_params already produced
// proper FunctionParameter nodes with type annotations attached.
try_parse_ts_arrow_params :: proc(p: ^Parser, lparen_tok: Token) -> ^Expression {
	start_loc := loc_from_token(lparen_tok)
	snap := lexer_snapshot(p)
	prev_pending_paren := p.pending_paren_start

	eat(p) // consume `(`

	// parse_function_params already handles: rest (`...x`), optional (`x?`),
	// type annotation (`x: T`), default value (`x = 1`), and destructuring.
	params := parse_function_params(p)

	if !is_token(p, .RParen) {
		lexer_restore(p, snap)
		p.pending_paren_start = prev_pending_paren
		return nil
	}
	eat(p) // consume `)`

	// Optional return type annotation: `(params): T => body`.
	return_type: Maybe(^TSTypeAnnotation)
	if is_token(p, .Colon) {
		return_type = parse_ts_type_annotation(p)
	}

	if !is_token(p, .Arrow) {
		lexer_restore(p, snap)
		p.pending_paren_start = prev_pending_paren
		return nil
	}
	eat(p) // consume `=>`

	// Body — block or expression. Mirror parse_arrow_function's treatment.
	is_block_body := is_token(p, .LBrace)
	body: ArrowFunctionBody
	if is_block_body {
		prev_in_function := p.in_function
		p.in_function = true
		block_stmt := parse_block_statement(p)
		p.in_function = prev_in_function
		if block_stmt != nil {
			if bs, ok := block_stmt^.(^BlockStatement); ok {
				body = bs
			}
		}
	} else {
		body = parse_assignment_expression(p)
	}

	arrow := new_node(p, ArrowFunctionExpression)
	arrow.loc = start_loc
	arrow.params = params
	arrow.body = body
	arrow.expression = !is_block_body
	arrow.async = false
	if rt, ok := return_type.?; ok { arrow.return_type = rt }
	arrow.loc.span.end = prev_end_offset(p)
	return expression_from(p, arrow)
}

parse_ts_type_parameters :: proc(p: ^Parser) -> ^TSTypeParameterDeclaration {
	if !is_token(p, .LAngle) { return nil }
	start := cur_loc(p); eat(p) // consume `<`
	params := make([dynamic]TSTypeParameter, 0, 4, p.allocator)
	for !is_token(p, .RAngle) && !is_token(p, .EOF) {
		param_start := cur_loc(p)
		cur := get_current(p)
		name := BindingIdentifier{loc = loc_from_token(cur), name = cur.value}
		eat(p) // consume identifier
		constraint: Maybe(^TSType)
		default_: Maybe(^TSType)
		if is_token(p, .Extends) { eat(p); constraint = parse_ts_type(p) }
		if is_token(p, .Assign)  { eat(p); default_  = parse_ts_type(p) }
		param := TSTypeParameter{
			loc = param_start, name = name,
			constraint = constraint, default_ = default_,
		}
		param.loc.span.end = prev_end_offset(p)
		append(&params, param)
		if !match_token(p, .Comma) { break }
	}
	expect_token(p, .RAngle)
	decl := new_node(p, TSTypeParameterDeclaration)
	decl.loc = start; decl.params = params
	decl.loc.span.end = prev_end_offset(p)
	return decl
}

parse_ts_type_object :: proc(p: ^Parser) -> ^TSType {
	start := cur_loc(p); eat(p) // consume `{`

	// Detect mapped type: `{ [K in T]: V }` or `{ readonly [K in T]?: V }`.
	// Use `is_next_identifier_value` for cheap lookahead without speculative parse.
	is_mapped := false
	readonly_mod := TSMappedTypeModifier.None

	// Check `{ readonly [`  — readonly then bracket, plus `+readonly [` / `-readonly [`.
	// `.Readonly` is not in the lexer — check by string value.
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

	// Check `{ [K in` pattern. After optional readonly, `[` is current.
	if is_token(p, .LBracket) {
		nxt := p.lexer.nxt
		if nxt.kind == .Identifier || nxt.kind == .Let || nxt.kind == .As {
			is_mapped = true
		}
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
		if !is_token(p, .In) {
			// Not a mapped type after all — it's an index signature
			// `[ident : type]: value`. We've already eaten `[` and the
			// identifier, plus an optional leading `readonly`. Build an
			// index signature as the first member, then continue into the
			// regular object-member loop (which appends siblings).
			members := make([dynamic]^TSSignature, 0, 4, p.allocator)
			key_type_start := cur_loc(p)
			_ = key_type_start
			expect_token(p, .Colon)
			idx_ann := parse_ts_type(p)
			expect_token(p, .RBracket)
			val_ann: Maybe(^TSTypeAnnotation)
			if is_token(p, .Colon) { val_ann = parse_ts_type_annotation(p) }
			param_name_ident := new_node(p, Identifier)
			param_name_ident.loc = param_name.loc
			param_name_ident.name = param_name.name
			key_ann := new_node(p, TSTypeAnnotation)
			key_ann.loc = param_start
			key_ann.type_annotation = idx_ann
			key_ann.loc.span.end = prev_end_offset(p)
			idx_sig := TSIndexSignature{
				loc = lb_start,
				parameters = make([dynamic]TSFunctionParam, 0, 1, p.allocator),
				type_annotation = val_ann,
				readonly = readonly_mod == .True,
			}
			fp := TSFunctionParam{
				loc = param_start,
				pattern = param_name_ident,
				type_annotation = key_ann,
			}
			fp.loc.span.end = prev_end_offset(p)
			append(&idx_sig.parameters, fp)
			idx_sig.loc.span.end = prev_end_offset(p)
			first_sig := new_node(p, TSSignature); first_sig^ = idx_sig
			append(&members, first_sig)
			match_token(p, .Semi); match_token(p, .Comma)
			for !is_token(p, .RBrace) && !is_token(p, .EOF) {
				sig := parse_ts_object_member(p); if sig != nil { append(&members, sig) }
				match_token(p, .Semi); match_token(p, .Comma)
			}
			expect_token(p, .RBrace)
			lit := new_node(p, TSTypeLiteral); lit.loc = start; lit.members = members; lit.loc.span.end = prev_end_offset(p)
			r := new_node(p, TSType); r^ = lit; return r
		}
		eat(p) // consume `in`
		constraint := parse_ts_type(p)
		name_type: Maybe(^TSType)
		if is_token(p, .As) { eat(p); name_type = parse_ts_type(p) }
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
		sig := parse_ts_object_member(p); if sig != nil { append(&members, sig) }
		match_token(p, .Semi); match_token(p, .Comma)
	}
	expect_token(p, .RBrace)
	lit := new_node(p, TSTypeLiteral); lit.loc = start; lit.members = members; lit.loc.span.end = prev_end_offset(p)
	r := new_node(p, TSType); r^ = lit; return r
}

// parse_ts_sig_params parses parameter list for method/call/construct signatures.
// Assumes the opening `(` has NOT yet been consumed.
parse_ts_sig_params :: proc(p: ^Parser) -> [dynamic]TSFunctionParam {
	expect_token(p, .LParen)
	params := make([dynamic]TSFunctionParam, 0, 4, p.allocator)
	for !is_token(p, .RParen) && !is_token(p, .EOF) {
		param_start := cur_loc(p)
		pattern := parse_binding_pattern(p)
		param_optional := false
		if is_token(p, .Question) {
			nxt := peek_token(p)
			if nxt.type == .Colon || nxt.type == .Comma || nxt.type == .RParen {
				eat(p); param_optional = true
			}
		}
		param_ann: Maybe(^TSTypeAnnotation)
		if is_token(p, .Colon) { param_ann = parse_ts_type_annotation(p) }
		fp := TSFunctionParam{loc = param_start, pattern = pattern, type_annotation = param_ann, optional = param_optional}
		fp.loc.span.end = prev_end_offset(p)
		append(&params, fp)
		if !match_token(p, .Comma) { break }
	}
	expect_token(p, .RParen)
	return params
}

parse_ts_object_member :: proc(p: ^Parser) -> ^TSSignature {
	start := cur_loc(p)
	readonly := false
	idx_readonly := false  // Special handling for readonly index signature

	// --- NEW: detect call signature `(...): T` ------------------------------------
	if is_token(p, .LParen) {
		params := parse_ts_sig_params(p)
		ret: Maybe(^TSTypeAnnotation)
		if is_token(p, .Colon) { ret = parse_ts_type_annotation(p) }
		call_sig := TSCallSignatureDeclaration{
			loc = start, params = params, return_type = ret,
		}
		call_sig.loc.span.end = prev_end_offset(p)
		sig := new_node(p, TSSignature); sig^ = call_sig; return sig
	}

	// --- NEW: detect construct signature `new (...): T` ---------------------------
	if is_token(p, .New) && p.lexer.nxt.kind == .LParen {
		eat(p) // consume `new`
		params := parse_ts_sig_params(p)
		ret: Maybe(^TSTypeAnnotation)
		if is_token(p, .Colon) { ret = parse_ts_type_annotation(p) }
		ctor_sig := TSConstructSignatureDeclaration{
			loc = start, params = params, return_type = ret,
		}
		ctor_sig.loc.span.end = prev_end_offset(p)
		sig := new_node(p, TSSignature); sig^ = ctor_sig; return sig
	}

	// --- NEW: detect index signature `[ident : type]: type` or `readonly [ident : type]: type`
	if is_token(p, .Readonly) && p.lexer.nxt.kind == .LBracket {
		idx_readonly = true
		eat(p) // consume `readonly`
	}

	if is_token(p, .LBracket) && p.lexer.nxt.kind == .Identifier {
		// Check if this is an index signature by peeking for `:` after the identifier.
		eat(p) // consume `[`
		if is_token(p, .Identifier) && p.lexer.nxt.kind == .Colon {
			// Confirmed: index signature.
			param_start := cur_loc(p)
			param_name_tok := get_current(p)
			param_name_ident := new_node(p, Identifier)
			param_name_ident.loc = loc_from_token(param_name_tok)
			param_name_ident.name = param_name_tok.value
			eat(p) // consume identifier
			eat(p) // consume colon
			idx_ann := parse_ts_type(p)
			expect_token(p, .RBracket)
			val_ann: Maybe(^TSTypeAnnotation)
			if is_token(p, .Colon) { val_ann = parse_ts_type_annotation(p) }

			idx_sig := TSIndexSignature{
				loc = start,
				parameters = make([dynamic]TSFunctionParam, 0, 1, p.allocator),
				type_annotation = val_ann,
				readonly = idx_readonly,
			}
			// Build the sole parameter: pattern is the identifier, type_annotation is the index key's type.
			key_ann := new_node(p, TSTypeAnnotation)
			key_ann.loc = param_start
			key_ann.type_annotation = idx_ann
			key_ann.loc.span.end = prev_end_offset(p)
			fp := TSFunctionParam{
				loc = param_start,
				pattern = param_name_ident,
				type_annotation = key_ann,
			}
			fp.loc.span.end = prev_end_offset(p)
			append(&idx_sig.parameters, fp)
			idx_sig.loc.span.end = prev_end_offset(p)

			sig := new_node(p, TSSignature)
			sig^ = idx_sig
			return sig
		}
		// Not an index signature — fall through as computed property.
		// We already consumed `[`, so set computed = true and parse the rest.
		key := parse_assignment_expression(p)
		expect_token(p, .RBracket)
		optional := match_token(p, .Question)

		// Check if it's a method signature after computed property.
		if is_token(p, .LParen) {
			sig := new_node(p, TSSignature)
			method := TSMethodSignature{loc = start, key = key, computed = true, optional = optional, kind = .Method}
			method.params = parse_ts_sig_params(p)
			if is_token(p, .Colon) { method.return_type = parse_ts_type_annotation(p) }
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

	// Parse key for method or property signature.
	key: ^Expression; computed := false
	if is_token(p, .LBracket) {
		computed = true; eat(p); key = parse_assignment_expression(p); expect_token(p, .RBracket)
	} else if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
		cur := get_current(p); id := new_node(p, Identifier); id.loc = loc_from_token(cur); id.name = cur.value
		key = expression_from(p, id); eat(p)
	} else if is_token(p, .String) {
		str := parse_string_literal(p); sn := new_node(p, StringLiteral); sn^ = str; key = expression_from(p, sn)
	} else if is_token(p, .Number) {
		cur := get_current(p); nm := new_node(p, NumericLiteral); nm.loc = loc_from_token(cur); nm.raw = cur.value
		if v, ok := cur.literal.(f64); ok { nm.value = v }; key = expression_from(p, nm); eat(p)
	} else { return nil }
	optional := match_token(p, .Question)

	// Method signature: key is followed by `(` (or `<` for generics).
	if is_token(p, .LParen) {
		sig := new_node(p, TSSignature)
		method := TSMethodSignature{loc = start, key = key, computed = computed, optional = optional, kind = .Method}
		method.params = parse_ts_sig_params(p)
		if is_token(p, .Colon) { method.return_type = parse_ts_type_annotation(p) }
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
// interface|type|enum|namespace|module …`. The `declare` modifier just sets
// a flag on the resulting declaration node. Call it when current token is
// `.Declare`.
parse_ts_declare_statement :: proc(p: ^Parser) -> ^Statement {
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
	case .Class:
		stmt = parse_class_declaration(p)
		if stmt != nil {
			if cls, ok := stmt^.(^ClassDeclaration); ok { cls.declare = true }
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
			stmt = parse_ts_interface_declaration(p)
			if stmt != nil {
				if id, ok := stmt^.(^TSInterfaceDeclaration); ok { id.declare = true }
			}
		case "type":
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
		case "namespace":
			if is_next_token(p, .Identifier) {
				stmt = parse_ts_module_declaration(p, .Namespace)
				if stmt != nil {
					if mod, ok := stmt^.(^TSModuleDeclaration); ok { mod.declare = true }
				}
			}
		case "module":
			if is_next_token(p, .String) {
				stmt = parse_ts_module_declaration(p, .Module)
				if stmt != nil {
					if mod, ok := stmt^.(^TSModuleDeclaration); ok { mod.declare = true }
				}
			}
		}
	}

	if stmt == nil {
		report_error(p, "Expected declaration after 'declare'")
	}
	return stmt
}

parse_ts_interface_declaration :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p); eat(p)
	cur := get_current(p)
	id := BindingIdentifier{loc = loc_from_token(cur), name = cur.value}; eat(p)
	type_parameters: Maybe(^TSTypeParameterDeclaration)
	if is_token(p, .LAngle) { type_parameters = parse_ts_type_parameters(p) }
	expect_token(p, .LBrace)
	members := make([dynamic]^TSSignature, 0, 8, p.allocator)
	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		sig := parse_ts_object_member(p); if sig != nil { append(&members, sig) }
		match_token(p, .Semi); match_token(p, .Comma)
	}
	expect_token(p, .RBrace)
	decl := new_node(p, TSInterfaceDeclaration); decl.loc = start; decl.id = id; decl.type_parameters = type_parameters
	decl.body = TSInterfaceBody{loc = start, body = members}; decl.body.loc.span.end = prev_end_offset(p)
	decl.loc.span.end = prev_end_offset(p)
	stmt := new_node(p, Statement); stmt^ = decl; return stmt
}

parse_ts_type_alias_declaration :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p); eat(p)
	cur := get_current(p)
	id := BindingIdentifier{loc = loc_from_token(cur), name = cur.value}; eat(p)
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
	id := BindingIdentifier{loc = loc_from_token(cur), name = cur.value}; eat(p)
	body_start := cur_loc(p); expect_token(p, .LBrace)
	members := make([dynamic]TSEnumMember, 0, 8, p.allocator)
	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		ms := cur_loc(p); member_id: ^Expression; mc := get_current(p)
		if is_token(p, .String) {
			str := parse_string_literal(p); sn := new_node(p, StringLiteral); sn^ = str; member_id = expression_from(p, sn)
		} else {
			mid := new_node(p, Identifier); mid.loc = loc_from_token(mc); mid.name = mc.value; eat(p)
			member_id = expression_from(p, mid)
		}
		init: Maybe(^Expression)
		if match_token(p, .Assign) { init = parse_assignment_expression(p) }
		m := TSEnumMember{loc = ms, id = member_id, initializer = init}; m.loc.span.end = prev_end_offset(p)
		append(&members, m)
		if !match_token(p, .Comma) { break }
	}
	expect_token(p, .RBrace)
	decl := new_node(p, TSEnumDeclaration); decl.loc = start; decl.id = id
	decl.body = TSEnumBody{loc = body_start, members = members}; decl.body.loc.span.end = prev_end_offset(p)
	decl.const_ = is_const; decl.loc.span.end = prev_end_offset(p)
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
		id_ident := new_node(p, Identifier); id_ident.loc = loc_from_token(cur); id_ident.name = cur.value
		eat(p)
		id_expr = expression_from(p, id_ident)
	}

	// Handle `namespace A.B.C { ... }` — produce nested TSModuleDeclarations.
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
		stmts := make([dynamic]^Statement, 0, 8, p.allocator)
		for !is_token(p, .RBrace) && !is_token(p, .EOF) {
			s := parse_statement_or_declaration(p)
			if s != nil { append(&stmts, s) }
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
	id_ident := new_node(p, Identifier); id_ident.loc = loc_from_token(cur); id_ident.name = cur.value
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
		// call — same save/restore idiom as parse_ts_module_declaration.
		prev_ambient := p.in_ambient
		defer p.in_ambient = prev_ambient
		stmts := make([dynamic]^Statement, 0, 8, p.allocator)
		for !is_token(p, .RBrace) && !is_token(p, .EOF) {
			s := parse_statement_or_declaration(p)
			if s != nil { append(&stmts, s) }
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

// Fast accessors — read directly from FastToken/cur_tok, no Token struct copy
cur_offset :: #force_inline proc(p: ^Parser) -> u32 {
	if p.lexer != nil {
		return p.lexer.cur.start
	}
	return u32(p.cur_tok.loc.offset)
}

// prev_end_offset returns the end offset of the LAST consumed token. Use this
// for `loc.span.end` to match ESTree/OXC/Acorn/Babel span semantics, which
// END a node at the last character of its last token — excluding any trailing
// whitespace, newlines, or comments that precede the NEXT token.
//
// Example: for `export * from "./a";\nconst x = 1;`, the ExportAllDeclaration
// must span [0, 20) — through the `;`, not including the `\n`. `cur_offset`
// after parsing the export would be 21 (start of `const`); `prev_end_offset`
// correctly returns 20.
prev_end_offset :: #force_inline proc(p: ^Parser) -> u32 {
	return p.prev_token_end
}

cur_value :: #force_inline proc(p: ^Parser) -> string {
	if p.lexer != nil {
		ft := p.lexer.cur
		// Escaped identifier — prefer the cooked (decoded) name published
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
	return loc_from_token(p.cur_tok)
}

loc_from_token :: #force_inline proc(t: Token) -> Loc {
	return Loc{
		span   = Span{
			start = u32(t.loc.offset),
			end   = u32(t.loc.offset + len(t.value)),
		},
		line   = u32(t.loc.line),
		column = u32(t.loc.column),
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
