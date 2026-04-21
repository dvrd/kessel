package main

import "core:mem"
import "core:fmt"

// ============================================================================
// Token Access (cached in Parser for zero-overhead reads)
// ============================================================================

// Advance lexer: shift nxt → cur, lex new nxt. Writes minimal Token fields.
advance_token :: #force_inline proc(p: ^Parser) {
	if p.lexer != nil {
		a := p.lexer
		a.cur = a.nxt
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
				if a.last_lit_offset == ft.start && a.last_lit_type == .String {
					p.cur_tok.literal = a.last_lit_value
				} else if ft.end - ft.start >= 2 {
					p.cur_tok.literal = LiteralValue(a.source[ft.start+1:ft.end-1])
				} else {
					p.cur_tok.literal = LiteralValue(string(""))
				}
			} else if ft.kind <= .TemplateTail {
				if a.last_lit_offset == ft.start && a.last_lit_type != .None {
					p.cur_tok.literal = a.last_lit_value
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

// Prime the parser's token cache.
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
				if a.last_lit_offset == ft.start && a.last_lit_type == .String {
					p.cur_tok.literal = a.last_lit_value
				} else if ft.end - ft.start >= 2 {
					p.cur_tok.literal = LiteralValue(a.source[ft.start+1:ft.end-1])
				}
			} else if ft.kind <= .TemplateTail {
				if a.last_lit_offset == ft.start && a.last_lit_type != .None {
					p.cur_tok.literal = a.last_lit_value
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

	// JSX support
	allow_jsx:       bool,

	// Disallow 'in' as binary operator (for for-loop init parsing)
	no_in:           bool,

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
	case .Get, .Set, .Async, .Static, .Let, .Of, .From, .As, .Constructor,
	     .Yield, .Await, .If, .Else, .For, .While, .Do, .Switch, .Case,
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
init_parser :: proc(p: ^Parser, lexer: ^Lexer, alloc: mem.Allocator) {
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
	p.allow_jsx = false

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
	program.loc = cur_loc(p)
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
				// Also emit as ExpressionStatement in body (ESTree compat)
				str_lit := new_node(p, StringLiteral)
				str_lit.loc = loc_from_token(current)
				str_lit.value = current.literal.(string) or_else ""
				str_lit.raw = current.value
				expr_stmt, expr_stmt_s := new_stmt(p, ExpressionStatement)
				expr_stmt.loc = directive.loc
				expr_stmt.expression = expression_from(p, str_lit)
				append(&program.body, expr_stmt_s)
				eat(p)
				match_semicolon_or_asi(p)
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

	program.loc.span.end = cur_offset(p)
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
	case .Let, .Const, .Var:
		return parse_variable_declaration(p, nil, true)
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

	block.loc.span.end = cur_offset(p)
	return block_stmt
}

parse_empty_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p)

	empty := new_node(p, EmptyStatement)
	empty.loc = start
	empty.loc.span.end = cur_offset(p)
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

			return statement_from(p, labeled)
		}
	}

	expr_stmt, stmt := new_stmt(p, ExpressionStatement)
	expr_stmt.loc = start
	expr_stmt.expression = expr

	// Consume optional semicolon
	match_semicolon_or_asi(p)

	expr_stmt.loc.span.end = cur_offset(p)
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

	if_.loc.span.end = cur_offset(p)
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
	while_.loc.span.end = cur_offset(p)

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
	do_.loc.span.end = cur_offset(p)

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

	if is_token(p, .Var) || is_token(p, .Let) || is_token(p, .Const) {
		// Variable declaration - parse it
		decl_stmt := parse_variable_declaration(p, nil, false, true)
		if decl_stmt != nil {
			left_decl = transmute(^VariableDeclaration)decl_stmt
			left_expr = transmute(^Expression)decl_stmt
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
			for_in.loc.span.end = cur_offset(p)
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
			for_of.loc.span.end = cur_offset(p)
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
	for_.loc.span.end = cur_offset(p)

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
	if !is_token(p, .Semi) && !is_token(p, .RBrace) && !is_token(p, .EOF) {
		argument = parse_expression(p)
	}

	match_semicolon_or_asi(p)

	ret := new_node(p, ReturnStatement)
	ret.loc = start
	ret.argument = argument
	ret.loc.span.end = cur_offset(p)

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
	break_.loc.span.end = cur_offset(p)

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
	cont.loc.span.end = cur_offset(p)

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

	switch_.loc.span.end = cur_offset(p)
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

	case_.loc.span.end = cur_offset(p)
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

	if match_token(p, .Catch) {
		handler := parse_catch_clause(p)
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

	try_.loc.span.end = cur_offset(p)
	return statement_from(p, try_)
}

parse_catch_clause :: proc(p: ^Parser) -> Maybe(CatchClause) {
	start := cur_loc(p)

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
	clause.loc.span.end = cur_offset(p)

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
	throw_.loc.span.end = cur_offset(p)

	return statement_from(p, throw_)
}

parse_debugger_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume debugger

	match_semicolon_or_asi(p)

	debugger := new_node(p, DebuggerStatement)
	debugger.loc = start
	debugger.loc.span.end = cur_offset(p)

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
	with_.loc.span.end = cur_offset(p)

	return statement_from(p, with_)
}

// ============================================================================
// Declarations
// ============================================================================

parse_function_declaration :: proc(p: ^Parser, is_expr := false) -> ^Statement {
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

	if !expect_token(p, .LParen) {
		return nil
	}

	params := parse_function_params(p)

	if !expect_token(p, .RParen) {
		return nil
	}

	prev_async := p.in_async
	p.in_async = async
	prev_gen := p.in_generator
	p.in_generator = generator

	body := parse_function_body(p)

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
		expr.loc.span.end = cur_offset(p)

		// For function expressions, wrap in ExpressionStatement. The
		// .expression field is an ^Expression (a union ptr, not a raw ptr
		// to the concrete variant), so box via expression_from to get a
		// properly tagged union — a plain pointer cast produces a union
		// with tag=0 and corrupt contents on read.
		expr_stmt := new_node(p, ExpressionStatement)
		expr_stmt.loc = start
		expr_stmt.expression = expression_from(p, expr)
		expr_stmt.loc.span.end = cur_offset(p)

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
	}
	decl.expr.loc.span.end = cur_offset(p)

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
		rest.loc.span.end = cur_offset(p)

		// Store RestElement as the pattern
		param.pattern = rest
		// Rest parameters cannot have default values
		param.loc.span.end = cur_offset(p)
		return param
	}

	pattern := parse_binding_pattern(p)
	param.pattern = pattern

	if match_token(p, .Assign) {
		param.default_val = parse_assignment_expression(p)
	}

	param.loc.span.end = cur_offset(p)
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

	p.in_function = prev_in_function
	p.in_generator = prev_in_generator
	p.in_async = prev_in_async
	p.strict_mode = prev_strict

	if !match_token(p, .RBrace) {
		report_error(p, "Expected '}' at end of function body")
	}

	body.loc.span.end = cur_offset(p)
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

	super_class: Maybe(^Expression)
	if match_token(p, .Extends) {
		super_class = parse_left_hand_side_expr(p)
	}

	body := parse_class_body(p)

	// Allocate ClassDeclaration and Statement separately
	decl := new_node(p, ClassDeclaration)
	decl.expr = {
		loc         = start,
		id          = id,
		super_class = super_class,
		body        = body,
	}
	decl.expr.loc.span.end = cur_offset(p)

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

	body.loc.span.end = cur_offset(p)
	return body
}

parse_class_element :: proc(p: ^Parser) -> ^ClassElement {
	start := cur_loc(p)

	// Check for static block: static { ... }
	if is_token(p, .Static) && is_next_token(p, .LBrace) {
		return parse_static_block(p, start)
	}

	static_ := match_token(p, .Static)

	kind := ClassElementKind.Method
	is_async := false
	is_generator := false
	computed := false
	is_private := false

	// Check for async keyword
	if is_token(p, .Async) {
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
	} else if is_token(p, .Identifier) || is_token(p, .String) || is_token(p, .Number) ||
	          is_keyword_usable_as_property_name(p.cur_type) {
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

	// Check if this is a field (has = but no () ) or method
	if is_token(p, .Assign) || is_token(p, .Semi) || is_token(p, .Comma) || is_token(p, .RBrace) {
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

		elem.loc.span.end = cur_offset(p)
		return elem
	}

	// It's a method - parse parameters and body
	if !expect_token(p, .LParen) {
		return nil
	}

	params := parse_function_params(p)

	if !expect_token(p, .RParen) {
		return nil
	}

	// Parse body - set context flags
	prev_in_function := p.in_function
	prev_in_generator := p.in_generator
	prev_in_async := p.in_async

	p.in_function = true
	p.in_generator = is_generator
	p.in_async = is_async

	body := parse_function_body(p)

	p.in_function = prev_in_function
	p.in_generator = prev_in_generator
	p.in_async = prev_in_async

	// Create the method as a FunctionExpression
	fn_expr := new_node(p, FunctionExpression)
	fn_expr.loc = start
	fn_expr.id = nil // Methods don't have names in their function expression
	fn_expr.params = params
	fn_expr.body = body
	fn_expr.generator = is_generator
	fn_expr.async = is_async
	fn_expr.loc.span.end = cur_offset(p)

	elem := new_node(p, ClassElement)
	elem.loc = start
	elem.key = key
	elem.value = expression_from(p, fn_expr)
	elem.kind = kind
	elem.computed = computed
	elem.static = static_

	elem.loc.span.end = cur_offset(p)
	return elem
}

// Parse ES2022 static block: static { ... }
parse_static_block :: proc(p: ^Parser, start: Loc) -> ^ClassElement {
	match_token(p, .Static) // consume static

	// Parse block statement
	block_stmt := parse_block_statement(p)
	if block_stmt == nil {
		return nil
	}

	// Extract the block's body
	block := transmute(^BlockStatement)block_stmt

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
	static_block.loc.span.end = cur_offset(p)

	elem := new_node(p, ClassElement)
	elem.loc = start
	elem.key = nil  // Static blocks don't have a key
	elem.value = expression_from(p, static_block)
	elem.kind = .StaticBlock
	elem.computed = false
	elem.static = false  // Not marked as static - the kind implies it

	elem.loc.span.end = cur_offset(p)
	return elem
}

parse_variable_declaration :: proc(p: ^Parser, kind_override: Maybe(VariableKind), consume_semi: bool, in_for := false) -> ^Statement {
	start := cur_loc(p)

	kind: VariableKind

	#partial switch p.cur_type {
	case .Var:
		kind = .Var
	case .Let:
		kind = .Let
	case .Const:
		kind = .Const
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
		d := parse_variable_declarator(p, kind, in_for)
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

	decl.loc.span.end = cur_offset(p)
	stmt := new_node(p, Statement)
	stmt^ = decl
	return stmt
}

parse_variable_declarator :: proc(p: ^Parser, kind: VariableKind, in_for := false) -> ^VariableDeclarator {
	start := cur_loc(p)

	pattern := parse_binding_pattern(p)

	init: Maybe(^Expression)
	if match_token(p, .Assign) {
		init = parse_assignment_expression(p)
	} else if kind == .Const && !in_for {
		report_error(p, "const declarations must have an initializer")
	}

	decl := new_node(p, VariableDeclarator)
	decl.loc = start
	decl.id = pattern
	decl.init = init
	decl.loc.span.end = cur_offset(p)

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

	// Identifiers and contextual keywords that can be used as binding names
	if is_token(p, .Identifier) || is_token(p, .Get) || is_token(p, .Set) ||
	   is_token(p, .Async) || is_token(p, .From) || is_token(p, .Of) ||
	   is_token(p, .As) || is_token(p, .Let) || is_token(p, .Static) ||
	   is_token(p, .Constructor) || is_token(p, .Yield) {
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
		} else if is_token(p, .Identifier) || is_token(p, .String) ||
		          is_keyword_usable_as_property_name(p.cur_type) {
			// Identifier, string, or keyword used as key
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
					assign.loc.span.end = cur_offset(p)

					prop := ObjectPatternProperty{
						loc       = prop_start,
						key       = key,
						value     = assign,
						computed  = computed,
						shorthand = false,
					}
					append(&obj.properties, prop)
				} else {
					prop := ObjectPatternProperty{
						loc       = prop_start,
						key       = key,
						value     = value_ident,
						computed  = computed,
						shorthand = false,
					}
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
					assign.loc.span.end = cur_offset(p)
					val = assign
				}
				prop := ObjectPatternProperty{
					loc       = prop_start,
						key       = key,
					value     = val,
					computed  = computed,
						shorthand = false,
				}
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
					assign.loc.span.end = cur_offset(p)
					val = assign
				}
				prop := ObjectPatternProperty{
					loc       = prop_start,
					key       = key,
					value     = val,
					computed  = computed,
					shorthand = false,
				}
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
					assign.loc.span.end = cur_offset(p)
					
					prop := ObjectPatternProperty{
						loc       = prop_start,
						key       = key,
						value     = assign,
						computed  = computed,
						shorthand = true,
					}
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

	obj.loc.span.end = cur_offset(p)
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
		if match_token(p, .Dot3) {
			if !is_token(p, .Identifier) {
				report_error(p, "Expected identifier after ... in array pattern")
				return nil
			}
			arl := cur_loc(p); arn := cur_value(p)
			eat(p)

			rest := new_node(p, RestElement)
			rest.loc = arl
			rest_ident := new_node(p, Identifier)
			rest_ident.loc = arl
			rest_ident.name = arn
			rest.argument = rest_ident
			rest.loc.span.end = cur_offset(p)

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
				assign.loc.span.end = cur_offset(p)
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
	arr.loc.span.end = cur_offset(p)
	return arr
}

// ============================================================================
// Module Import/Export
// ============================================================================

parse_import_declaration :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume import

	decl := new_node(p, ImportDeclaration)
	decl.loc = start
	decl.specifiers = make([dynamic]^ImportSpecifierSpec, 0, 4, p.allocator)

	if is_token(p, .String) {
		// import "module"
		decl.source = parse_string_literal(p)
	} else if is_token(p, .LBrace) {
		// Named imports: import { x, y } from "module"
		eat(p) // consume {

		for !is_token(p, .RBrace) && !is_token(p, .EOF) {
			spec := parse_import_specifier(p)
			if spec != nil {
				append(&decl.specifiers, (^ImportSpecifierSpec)(spec))
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
		// Namespace import: import * as name from "module"
		eat(p)
		if !expect_token(p, .As) {
			return nil
		}
		local := parse_identifier(p)
		spec := new_node(p, ImportNamespaceSpecifier)
		spec.loc = local.loc
		spec.local = BindingIdentifier{
			loc  = local.loc,
			name = local.name,
		}
		spec.loc.span.end = cur_offset(p)
		append(&decl.specifiers, (^ImportSpecifierSpec)(spec))

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
		spec.loc.span.end = cur_offset(p)
		append(&decl.specifiers, (^ImportSpecifierSpec)(spec))

		// Check for comma followed by named imports
		if match_token(p, .Comma) {
			if is_token(p, .LBrace) {
				eat(p) // consume {

				for !is_token(p, .RBrace) && !is_token(p, .EOF) {
					spec2 := parse_import_specifier(p)
					if spec2 != nil {
						append(&decl.specifiers, (^ImportSpecifierSpec)(spec2))
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
				ns_spec.loc.span.end = cur_offset(p)
				append(&decl.specifiers, (^ImportSpecifierSpec)(ns_spec))
			}
		}

		if !expect_token(p, .From) {
			return nil
		}

		decl.source = parse_string_literal(p)
	}

	match_semicolon_or_asi(p)

	decl.loc.span.end = cur_offset(p)

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
	spec.loc.span.end = cur_offset(p)

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

	// Export declaration
	decl := parse_statement_or_declaration(p)
	if decl == nil {
		return nil
	}

	export_decl := new_node(p, ExportNamedDeclaration)
	export_decl.loc = start
	export_decl.declaration = (^Declaration)(decl)
	export_decl.loc.span.end = cur_offset(p)

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
	decl.loc.span.end = cur_offset(p)

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
	decl.loc.span.end = cur_offset(p)

	// Allocate Statement union and store the pointer
	match_semicolon_or_asi(p)
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
		local := parse_identifier_name(p)

		exported := local
		if match_token(p, .As) {
			exported = parse_identifier_name(p)
		}

		spec := ExportSpecifier{
			loc = start_spec,
			local = IdentifierName{
				loc  = local.loc,
				name = local.name,
			},
			exported = IdentifierName{
				loc  = exported.loc,
				name = exported.name,
			},
		}
		spec.loc.span.end = cur_offset(p)
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
	}

	match_semicolon_or_asi(p)

	decl.loc.span.end = cur_offset(p)

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
			seq.loc.span.end = cur_offset(p)
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
			logical.loc.span.end = cur_offset(p)

			left = logical_e
			continue
		}

		// Regular binary operator
		binary, binary_e := new_expr(p, BinaryExpression)
		binary.loc = loc_from_expr(left)
		binary.operator = token_to_binary_op(cur_type)
		binary.left = left
		binary.right = right
		binary.loc.span.end = cur_offset(p)

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
		unary.loc.span.end = cur_offset(p)
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
		update.loc.span.end = cur_offset(p)
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
		await.loc.span.end = cur_offset(p)
		return expression_from(p, await)

	case .Dot3:
		current := p.cur_tok
		eat(p)
		argument := parse_unary_expr(p)
		if argument == nil { return nil }
		spread := new_node(p, SpreadElement)
		spread.loc = loc_from_token(current)
		spread.argument = argument
		spread.loc.span.end = cur_offset(p)
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
		id.loc.span.end = cur_offset(p)
		expr = id_e
		// Inline LHS tail loop (member access, calls)
		expr = parse_lhs_tail(p, expr, true)
	} else {
		expr = parse_left_hand_side_expr(p)
	}
	if expr == nil { return nil }

	if p.cur_type == .PlusPlus || p.cur_type == .MinusMinus {
		current := p.cur_tok
		eat(p)
		update := new_node(p, UpdateExpression)
		update.loc = loc_from_expr(expr)
		update.operator = .Increment if current.type == .PlusPlus else .Decrement
		update.argument = expr
		update.prefix = false
		update.loc.span.end = cur_offset(p)
		return expression_from(p, update)
	}

	return expr
}

// LHS tail: member access, computed access, calls, tagged templates, optional chaining
parse_lhs_tail :: #force_inline proc(p: ^Parser, start_expr: ^Expression, allow_call: bool) -> ^Expression {
	expr := start_expr
	for {
		#partial switch p.cur_type {
		case .Dot:
			eat(p)
			prop := parse_identifier_name(p)
			member, member_e := new_expr(p, MemberExpression)
			member.loc = loc_from_expr(expr)
			member.object = expr
			id, id_e := new_expr(p, Identifier)
			id.loc = prop.loc
			id.name = prop.name
			member.property = id_e
			member.computed = false
			member.optional = false
			member.loc.span.end = cur_offset(p)
			expr = member_e
		case .OptionalChain:
			if !allow_call {
				return expr
			}
			eat(p)
			if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
				prop := parse_identifier_name(p)
				member := new_node(p, MemberExpression)
				member.loc = loc_from_expr(expr)
				member.object = expr
				ident := new_node(p, Identifier)
				ident.loc = prop.loc
				ident.name = prop.name
				member.property = expression_from(p, ident)
				member.computed = false
				member.optional = true
				member.loc.span.end = cur_offset(p)
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
				member.optional = true
				member.loc.span.end = cur_offset(p)
				expr = expression_from(p, member)
			} else if is_token(p, .LParen) {
				args := parse_arguments(p)
				call := new_node(p, CallExpression)
				call.loc = loc_from_expr(expr)
				call.callee = expr
				call.arguments = args
				call.optional = true
				call.loc.span.end = cur_offset(p)
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
			mem2.loc.span.end = cur_offset(p)
			expr = mem2_e
		case .LParen:
			if !allow_call {
				return expr
			}
			args := parse_arguments(p)
			call, call_e := new_expr(p, CallExpression)
			call.loc = loc_from_expr(expr)
			call.callee = expr
			call.arguments = args
			call.optional = false
			call.loc.span.end = cur_offset(p)
			expr = call_e
		case .TemplateHead, .Template:
			tagged := new_node(p, TaggedTemplateExpression)
			tagged.loc = loc_from_expr(expr)
			tagged.tag = expr
			tagged.quasi = parse_template_literal(p)
			tagged.loc.span.end = cur_offset(p)
			expr = expression_from(p, tagged)
		case:
			return expr
		}
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
			meta_prop.loc.span.end = cur_offset(p)
			return expression_from(p, meta_prop)
		}
		// Static import - not valid in expression context
		report_error(p, "Unexpected import in expression context")
		return nil

	case .This:
		eat(p)
		this := new_node(p, ThisExpression)
		this.loc = loc_from_token(current)
		this.loc.span.end = cur_offset(p)
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
		pid.loc.span.end = cur_offset(p)
		return expression_from(p, pid)

	case .Super:
		eat(p)
		super := new_node(p, Super)
		super.loc = loc_from_token(current)
		super.loc.span.end = cur_offset(p)
		return expression_from(p, super)

	case .Null:
		eat(p)
		nl, nl_e := new_expr(p, NullLiteral)
		nl.loc = loc_from_token(current)
		nl.loc.span.end = cur_offset(p)
		return nl_e

	case .True, .False:
		eat(p)
		bl, bl_e := new_expr(p, BooleanLiteral)
		bl.loc = loc_from_token(current)
		bl.value = current.type == .True
		bl.loc.span.end = cur_offset(p)
		return bl_e

	case .Number:
		eat(p)
		num, num_e := new_expr(p, NumericLiteral)
		num.loc = loc_from_token(current)
		num.raw = current.value
		if val, ok := current.literal.(f64); ok {
			num.value = val
		}
		num.loc.span.end = cur_offset(p)
		return num_e

	case .String:
		eat(p)
		str, str_e := new_expr(p, StringLiteral)
		str.loc = loc_from_token(current)
		str.raw = current.value
		if val, ok := current.literal.(string); ok {
			str.value = val
		}
		str.loc.span.end = cur_offset(p)
		return str_e

	case .BigInt:
		eat(p)
		big := new_node(p, BigIntLiteral)
		big.loc = loc_from_token(current)
		big.raw = current.value
		big.value = current.value  // Store as string
		big.loc.span.end = cur_offset(p)
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
				ident.loc.span.end = cur_offset(p)
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
		ident.loc.span.end = cur_offset(p)
		return expression_from(p, ident)

	case .Identifier, .Get, .Set, .From, .Of, .As, .Let, .Static, .Constructor:
		// Contextual keywords are valid identifiers in expression context
		eat(p)
		id, id_expr := new_expr(p, Identifier)
		id.loc = loc_from_token(current)
		id.name = current.value
		id.loc.span.end = cur_offset(p)
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

		// Regular parenthesized expression
		// Use Comma precedence to handle (x, y) => ... arrow function case
		eat(p)
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
		regex.loc.span.end = cur_offset(p)
		return expression_from(p, regex)

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
			eat(p)
			arg := parse_assignment_expression(p)
			if arg != nil {
				spread := new_node(p, SpreadElement)
				spread.loc = loc_from_expr(arg)
				spread.argument = arg
				spread.loc.span.end = cur_offset(p)
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

	arr.loc.span.end = cur_offset(p)
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

	obj.loc.span.end = cur_offset(p)
	return expression_from(p, obj)
}

parse_property :: proc(p: ^Parser) -> ^Property {
	start := cur_loc(p)

	computed := false
	key: ^Expression

	if is_token(p, .Dot3) {
		// Spread property: ...expr
		eat(p)
		arg := parse_assignment_expression(p)
		if arg == nil {
			return nil
		}

		prop := new_node(p, Property)
		prop.loc = start
		prop.key = nil
		prop.value = arg
		prop.kind = .Init
		prop.computed = false
		prop.shorthand = false
		prop.loc.span.end = cur_offset(p)
		return prop
	}

	// Check for get/set keywords and generator/async modifiers
	is_getter := false
	is_setter := false
	is_generator := false
	is_async := false

	if is_token(p, .Get) || is_token(p, .Set) {
		// Only treat as getter/setter if followed by a property name (not : or ( directly)
		next := peek_token(p)
		if next.type == .Identifier || next.type == .String || next.type == .Number ||
		   next.type == .LBracket || next.type == .Mul {
			if is_token(p, .Get) {
				is_getter = true
			} else {
				is_setter = true
			}
			eat(p)
		}
	} else if is_token(p, .Async) {
		// Only treat as async if followed by a property name or *
		next := peek_token(p)
		if next.type == .Identifier || next.type == .String || next.type == .Number ||
		   next.type == .LBracket || next.type == .Mul || next.type == .LParen {
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
		fn.loc = start
		fn.params = params
		fn.body = body
		fn.generator = is_generator
		fn.async = is_async
		value = expression_from(p, fn)
	} else if is_token(p, .LParen) {
		// Method shorthand: foo() {}
		kind = .Method
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
		fn.loc = start
		fn.params = params
		fn.body = body
		fn.generator = is_generator
		fn.async = is_async
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
		assign.loc.span.end = cur_offset(p)
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
	prop.loc.span.end = cur_offset(p)

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
		ident.loc.span.end = cur_offset(p)
		return expression_from(p, ident)

	case .String:
		eat(p)
		str := new_node(p, StringLiteral)
		str.loc = loc_from_token(current)
		str.raw = current.value
		if val, ok := current.literal.(string); ok {
			str.value = val
		}
		str.loc.span.end = cur_offset(p)
		return expression_from(p, str)

	case .Number:
		eat(p)
		num := new_node(p, NumericLiteral)
		num.loc = loc_from_token(current)
		num.raw = current.value
		if val, ok := current.literal.(f64); ok {
			num.value = val
		}
		num.loc.span.end = cur_offset(p)
		return expression_from(p, num)

	case:
		// All keywords can be used as property names in ES
		if is_keyword_usable_as_property_name(current.type) {
			eat(p)
			ident := new_node(p, Identifier)
			ident.loc = loc_from_token(current)
			ident.name = current.value
			ident.loc.span.end = cur_offset(p)
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
	expr.loc.span.end = cur_offset(p)

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
			meta.loc.span.end = cur_offset(p)
			return expression_from(p, meta)
		}
	}

	callee := parse_member_expr(p)
	if callee == nil {
		return nil
	}

	args: [dynamic]^Expression
	if is_token(p, .LParen) {
		args = parse_arguments(p)
	}

	new_ := new_node(p, NewExpression)
	new_.loc = start
	new_.callee = callee
	new_.arguments = args
	new_.loc.span.end = cur_offset(p)

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
				eat(p)
				arg := parse_assignment_expression(p)
				if arg != nil {
					spread := new_node(p, SpreadElement)
					spread.loc = loc_from_expr(arg)
					spread.argument = arg
					spread.loc.span.end = cur_offset(p)
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

	delegate := match_token(p, .Mul)

	argument: Maybe(^Expression)
	if !is_token(p, .Semi) && !is_token(p, .RParen) && !is_token(p, .RBracket) && !is_token(p, .RBrace) && !is_token(p, .Comma) {
		argument = parse_assignment_expression(p)
	}

	yield := new_node(p, YieldExpression)
	yield.loc = start
	yield.argument = argument
	yield.delegate = delegate
	yield.loc.span.end = cur_offset(p)

	return expression_from(p, yield)
}

parse_template_literal :: proc(p: ^Parser) -> ^Expression {
	start := cur_loc(p)
	current := get_current(p)

	tmpl := new_node(p, TemplateLiteral)
	tmpl.loc = start
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
		tmpl.loc.span.end = cur_offset(p)
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

		tmpl.loc.span.end = cur_offset(p)
		return expression_from(p, tmpl)
	}

	report_error(p, "Expected template literal")
	return nil
}

parse_arrow_function :: proc(p: ^Parser, left: ^Expression, is_async := false) -> ^Expression {
	start: Loc
	if left != nil {
		start = loc_from_expr(left)
	} else {
		start = cur_loc(p)
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
	body: ^Expression
	if is_block_body {
		// Block body - need to set in_function for return statement validation
		prev_in_function := p.in_function
		p.in_function = true
		block_stmt := parse_block_statement(p)
		p.in_function = prev_in_function
		if block_stmt != nil {
			// Block body - use transmute (arrow functions with block need special handling)
			body = transmute(^Expression)block_stmt
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
						rest.loc.span.end = cur_offset(p)
						param := FunctionParameter{
							loc     = arg.loc,
							pattern = rest,
						}
						append(&params, param)
					case ^ObjectExpression:
						// Convert ObjectExpression -> ObjectPattern for destructuring
						op := new_node(p, ObjectPattern)
						op.loc = arg.loc
						// skip property copy - different types
						param := FunctionParameter{
							loc     = arg.loc,
							pattern = op,
						}
						append(&params, param)
					case ^ArrayExpression:
						// Convert ArrayExpression -> ArrayPattern for destructuring
						ap := new_node(p, ArrayPattern)
						ap.loc = arg.loc
						// Convert each element expression to pattern
						elem_patterns := make([dynamic]Maybe(Pattern), 0, len(arg.elements), p.allocator)
						for elem in arg.elements {
							if elem == nil {
								append(&elem_patterns, Maybe(Pattern)(nil))
							} else {
								val := elem.? // unwrap Maybe(^Expression)
								#partial switch e in val^ {
								case ^Identifier:
									id_ptr := new_node(p, Identifier)
									id_ptr^ = e^
									append(&elem_patterns, id_ptr)
								case:
									append(&elem_patterns, Maybe(Pattern)(nil))
								}
							}
						}
						ap.elements = elem_patterns[:]
						param := FunctionParameter{
							loc     = arg.loc,
							pattern = ap,
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
	arrow.loc.span.end = cur_offset(p)

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
	cond.loc.span.end = cur_offset(p)

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

	assign := new_node(p, AssignmentExpression)
	assign.loc = start
	assign.operator = op
	assign.left = left
	assign.right = right
	assign.loc.span.end = cur_offset(p)

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
	body: ^Expression
	if is_block_body {
		// Block body - need to set in_function for return statement validation
		prev_in_function := p.in_function
		p.in_function = true
		block_stmt := parse_block_statement(p)
		p.in_function = prev_in_function
		if block_stmt != nil {
			body = transmute(^Expression)block_stmt
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
	arrow.loc.span.end = cur_offset(p)

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
	body: ^Expression
	if is_block_body {
		// Block body - need to set in_function for return statement validation
		prev_in_function := p.in_function
		p.in_function = true
		block_stmt := parse_block_statement(p)
		p.in_function = prev_in_function
		if block_stmt != nil {
			body = transmute(^Expression)block_stmt
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
	arrow.loc.span.end = cur_offset(p)

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
	import_expr.loc.span.end = cur_offset(p)

	return expression_from(p, import_expr)
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

cur_value :: #force_inline proc(p: ^Parser) -> string {
	if p.lexer != nil {
		ft := p.lexer.cur
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
