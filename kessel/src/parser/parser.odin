package parser

import "core:mem"
import "core:fmt"
import "core:strings"
import lexer_pkg "../lexer"
import ast_pkg "../ast"

// ============================================================================
// Token Access (cached in Parser for zero-overhead reads)
// ============================================================================

// Advance lexer and update cached token. Returns the OLD token.
// Advance: shift fast_nxt → cur, lex new nxt. Returns OLD cur as legacy Token.
// This is the ONLY place that touches the lexer.
advance_token :: #force_inline proc(p: ^Parser) -> lexer_pkg.Token {
	old := p.cur_tok
	if p.adapter != nil {
		a := p.adapter
		// Shift: cur = nxt, lex new nxt (FastToken by-value, no ring/SoA read)
		old_fast := a.opt.fast_cur
		a.opt.fast_cur = a.opt.fast_nxt
		if a.opt.fast_cur.kind != .EOF {
			a.opt.fast_nxt = lexer_pkg.lex_fast_token(&a.opt)
		} else {
			a.opt.fast_nxt = lexer_pkg.fast_token_eof(u32(a.opt.offset))
		}
		// Convert FastToken → cached parser Token fields
		ft := a.opt.fast_cur
		p.cur_type = ft.kind
		p.cur_tok.type = ft.kind
		p.cur_tok.loc.offset = int(ft.start)
		p.cur_tok.loc.line = 0
		p.cur_tok.loc.column = 0
		p.cur_tok.had_line_terminator = (ft.flags & lexer_pkg.FAST_FLAG_NEW_LINE) != 0
		// Lazy value: only create string slice for non-punctuation
		len16 := ft.end - ft.start
		p.cur_len = u16(len16)
		#partial switch ft.kind {
		case .LBrace, .RBrace, .LParen, .RParen, .LBracket, .RBracket,
		     .Semi, .Comma, .Colon, .Dot, .Dot3, .Arrow, .Question,
		     .OptionalChain, .BitNot,
		     .Plus, .Minus, .Mul, .Div, .Mod, .Pow,
		     .PlusPlus, .MinusMinus,
		     .Assign, .AssignAdd, .AssignSub, .AssignMul, .AssignDiv,
		     .AssignMod, .AssignPow, .AssignLShift, .AssignRShift,
		     .AssignURShift, .AssignBitAnd, .AssignBitOr, .AssignBitXor,
		     .AssignLogicalAnd, .AssignLogicalOr, .AssignNullish,
		     .Eq, .NotEq, .EqStrict, .NotEqStrict,
		     .LAngle, .RAngle, .LEq, .GEq,
		     .LShift, .RShift, .URShift,
		     .BitAnd, .BitOr, .BitXor, .Not,
		     .LogicalAnd, .LogicalOr, .Nullish,
		     .EOF:
			p.cur_tok.value = ""
			p.cur_tok.literal = nil
		case:
			p.cur_tok.value = a.source[ft.start:ft.end]
			p.cur_tok.literal = a.opt.token_soa.literal_values[a.opt.token_soa.count - 1]
		}
	} else if p.lexer != nil {
		lexer_pkg.next(p.lexer)
		p.cur_tok = lexer_pkg.get_current(p.lexer)
		p.cur_type = p.cur_tok.type
	}
	if p.profile_enabled {
		p.profile.next_calls += 1
	}
	return old
}

// Peek at the NEXT token (1-ahead). Not cached.
peek_token :: #force_inline proc(p: ^Parser) -> lexer_pkg.Token {
	if p.adapter != nil {
		return lexer_pkg.peek_adapter(p.adapter)
	}
	if p.lexer != nil {
		return lexer_pkg.peek(p.lexer)
	}
	return lexer_pkg.Token{type = .EOF}
}

// Prime the parser's token cache from the fast path.
prime_token_cache :: proc(p: ^Parser) {
	if p.adapter != nil {
		ft := p.adapter.opt.fast_cur
		p.cur_type = ft.kind
		p.cur_tok.type = ft.kind
		p.cur_tok.loc.offset = int(ft.start)
		p.cur_tok.loc.line = 0
		p.cur_tok.loc.column = 0
		p.cur_tok.had_line_terminator = (ft.flags & lexer_pkg.FAST_FLAG_NEW_LINE) != 0
		len16 := ft.end - ft.start
		p.cur_len = u16(len16)
		if ft.kind != .EOF && ft.start < ft.end {
			p.cur_tok.value = p.adapter.source[ft.start:ft.end]
			if p.adapter.opt.token_soa.count > 0 {
				p.cur_tok.literal = p.adapter.opt.token_soa.literal_values[p.adapter.opt.token_soa.count - 1]
			}
		}
	} else if p.lexer != nil {
		p.cur_tok = lexer_pkg.get_current(p.lexer)
		p.cur_type = p.cur_tok.type
	} else {
		p.cur_tok = lexer_pkg.Token{type = .EOF}
		p.cur_type = .EOF
	}
}

// Legacy shims for profiling compatibility
get_current_dispatch :: #force_inline proc(p: ^Parser) -> lexer_pkg.Token {
	if p.profile_enabled { p.profile.get_current_calls += 1 }
	return p.cur_tok
}

next_dispatch :: #force_inline proc(p: ^Parser) -> lexer_pkg.Token {
	return advance_token(p)
}

peek_dispatch :: #force_inline proc(p: ^Parser) -> lexer_pkg.Token {
	if p.profile_enabled { p.profile.peek_calls += 1 }
	return peek_token(p)
}

is_dispatch :: #force_inline proc(p: ^Parser, type_: lexer_pkg.TokenType) -> bool {
	if p.profile_enabled { p.profile.is_calls += 1 }
	return p.cur_type == type_
}

expect_dispatch :: #force_inline proc(p: ^Parser, type_: lexer_pkg.TokenType) -> (lexer_pkg.Token, bool) {
	if p.profile_enabled { p.profile.expect_calls += 1 }
	if p.cur_type == type_ {
		return advance_token(p), true
	}
	return p.cur_tok, false
}

// ============================================================================
// Bump allocator — zero-dispatch arena for AST node allocations
// ============================================================================

BumpPool :: struct {
	base:     [^]u8,
	offset:   int,
	capacity: int,
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
		return nil // caller must fall back
	}
	ptr := rawptr(uintptr(pool.base) + uintptr(aligned))
	pool.offset = new_offset
	return ptr
}

// Parser represents the recursive descent parser
Parser :: struct {
	// Lexer reference
	lexer: ^lexer_pkg.Lexer,

	// Lexer adapter (when using optimized lexer via adapter interface).
	// Per-parser field (not global) so parallel parsing via parse-many works.
	adapter: ^lexer_pkg.LexerAdapter,

	// Cached current token — updated ONLY by advance_token()
	cur_tok:  lexer_pkg.Token,
	cur_type: lexer_pkg.TokenType,

	// Token length (always set, even for punctuation where .value is skipped)
	cur_len: u16,

	// Allocator for AST allocations (used for [dynamic] arrays)
	allocator: mem.Allocator,

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

	// Position tracking
	last_pos:        lexer_pkg.Loc,

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
	loc:     lexer_pkg.Loc,
	message: string,
}

// String interner for identifier deduplication
StringInterner :: struct {
	allocator: mem.Allocator,
	entries: map[string]string,
}

// Parse result
ParseResult :: struct {
	program: ^ast_pkg.Program,
	errors:  []ParseError,
}

// Maximum iterations for error recovery to prevent infinite loops
MAX_ERROR_RECOVERY_ITERATIONS :: 10000

// Initialize string interner
init_interner :: proc(i: ^StringInterner, alloc: mem.Allocator) {
	i.allocator = alloc
	i.entries = make(map[string]string, alloc)
}

// Intern a string
intern :: proc(i: ^StringInterner, s: string) -> string {
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

// Initialize parser with legacy lexer
init_parser :: proc(p: ^Parser, l: ^lexer_pkg.Lexer, alloc: mem.Allocator) {
	p.lexer = l
	p.allocator = alloc
	p.errors = make([dynamic]ParseError, alloc)
	// Bump pool: ~20× typical AST bytes is safe
	bump_init(&p.node_pool, alloc, 8 * 1024 * 1024)
	p.in_function = false
	p.in_generator = false
	p.in_async = false
	p.in_loop = false
	p.in_switch = false
	p.strict_mode = false
	p.allow_jsx = false

	// Initialize interner
	interner := new(StringInterner, alloc)
	init_interner(interner, alloc)
	p.interner = interner

	// Prime token cache
	prime_token_cache(p)
}

// Adapter-based parser that works with optimized lexer
ParserAdapter :: struct {
	lexer_adapter: ^lexer_pkg.LexerAdapter,
	arena: ^mem.Arena,
	errors: [dynamic]ParseError,
	interner: ^StringInterner,
	in_function: bool,
	in_generator: bool,
	in_async: bool,
	in_loop: bool,
	in_switch: bool,
	strict_mode: bool,
	allow_jsx: bool,
	last_pos: lexer_pkg.Loc,
}

// Initialize parser adapter for optimized lexer
init_parser_adapter :: proc(p: ^Parser, adapter: ^lexer_pkg.LexerAdapter, alloc: mem.Allocator) {
	// Copy adapter reference - we use the adapter's functions directly
	p.lexer = nil  // Mark as using adapter
	p.allocator = alloc
	p.errors = make([dynamic]ParseError, alloc)
	// Bump pool: ~20× typical AST bytes is safe
	bump_init(&p.node_pool, alloc, 8 * 1024 * 1024)
	p.in_function = false
	p.in_generator = false
	p.in_async = false
	p.in_loop = false
	p.in_switch = false
	p.strict_mode = false
	p.allow_jsx = false

	// Initialize interner
	interner := new(StringInterner, alloc)
	init_interner(interner, alloc)
	p.interner = interner

	// Store adapter reference in the parser struct (per-parser, thread-safe)
	p.adapter = adapter

	// Prime token cache
	prime_token_cache(p)
}

// Create a new node allocated from bump pool (zero-dispatch)
new_node :: #force_inline proc(p: ^Parser, $T: typeid) -> ^T {
	if p.profile_enabled {
			p.profile.node_allocs += 1
			p.profile.node_alloc_bytes += u64(size_of(T))
			when T == ast_pkg.Expression {
				p.profile.expr_wrapper_allocs += 1
			}
			when T == ast_pkg.Statement {
				p.profile.stmt_wrapper_allocs += 1
			}
			when T == ast_pkg.Identifier {
				p.profile.identifier_allocs += 1
			}
			when T == ast_pkg.MemberExpression {
				p.profile.member_expr_allocs += 1
			}
			when T == ast_pkg.CallExpression {
				p.profile.call_expr_allocs += 1
			}
			when T == ast_pkg.BinaryExpression {
				p.profile.binary_expr_allocs += 1
			}
			when T == ast_pkg.LogicalExpression {
				p.profile.logical_expr_allocs += 1
			}
			when T == ast_pkg.Property {
				p.profile.property_allocs += 1
			}
			when T == ast_pkg.ObjectExpression {
				p.profile.object_expr_allocs += 1
			}
			when T == ast_pkg.ArrayExpression {
			p.profile.array_expr_allocs += 1
		}
	}
	// Try bump pool first (no function-pointer dispatch)
	ptr := bump_alloc(&p.node_pool, size_of(T), align_of(T))
	if ptr != nil {
		result := transmute(^T)ptr
		result^ = {} // zero-init struct
		return result
	}
	// Fallback to arena allocator
	result, _ := mem.new(T, p.allocator)
	return result
}

// Helper to convert any statement node to ^Statement union
// Uses transmute with proper type handling
statement_from :: proc(p: ^Parser, stmt_ptr: ^$T) -> ^ast_pkg.Statement {
	if stmt_ptr == nil {
		return nil
	}
	// Allocate a Statement from the arena and assign the concrete pointer
	result := new_node(p, ast_pkg.Statement)
	result^ = stmt_ptr
	return result
}

// Helper to convert any expression node to ^Expression union
expression_from :: #force_inline proc(p: ^Parser, expr_ptr: ^$T) -> ^ast_pkg.Expression {
	if expr_ptr == nil {
		return nil
	}
	expr := new_node(p, ast_pkg.Expression)
	expr^ = expr_ptr
	return expr
}

// Combined alloc: node T + Expression wrapper in one bump, returns ^Expression
// Saves one allocation for the very common pattern: alloc node + wrap.
new_expr :: #force_inline proc(p: ^Parser, $T: typeid) -> (^T, ^ast_pkg.Expression) {
	// Try to alloc both in one bump region (node then wrapper, contiguous)
	total_size := size_of(T) + size_of(ast_pkg.Expression)
	align := max(align_of(T), align_of(ast_pkg.Expression))
	ptr := bump_alloc(&p.node_pool, total_size, align)
	if ptr != nil {
		node := transmute(^T)ptr
		node^ = {}
		wrap_ptr := rawptr(uintptr(ptr) + uintptr(size_of(T)))
		// Align wrapper
		wrap_aligned := (uintptr(wrap_ptr) + uintptr(align_of(ast_pkg.Expression) - 1)) & ~uintptr(align_of(ast_pkg.Expression) - 1)
		wrap := transmute(^ast_pkg.Expression)wrap_aligned
		wrap^ = node
		return node, wrap
	}
	// Fallback: separate allocs
	node, _ := mem.new(T, p.allocator)
	expr := new_node(p, ast_pkg.Expression)
	expr^ = node
	return node, expr
}

// Combined alloc: node T + Statement wrapper in one bump
new_stmt :: #force_inline proc(p: ^Parser, $T: typeid) -> (^T, ^ast_pkg.Statement) {
	total_size := size_of(T) + size_of(ast_pkg.Statement)
	align := max(align_of(T), align_of(ast_pkg.Statement))
	ptr := bump_alloc(&p.node_pool, total_size, align)
	if ptr != nil {
		node := transmute(^T)ptr
		node^ = {}
		wrap_aligned := (uintptr(ptr) + uintptr(size_of(T)) + uintptr(align_of(ast_pkg.Statement) - 1)) & ~uintptr(align_of(ast_pkg.Statement) - 1)
		wrap := transmute(^ast_pkg.Statement)wrap_aligned
		wrap^ = node
		return node, wrap
	}
	node, _ := mem.new(T, p.allocator)
	stmt := new_node(p, ast_pkg.Statement)
	stmt^ = node
	return node, stmt
}

// Fast path for hot expression types - avoids allocation by using transmute
// Only safe when T is exactly one of the types in the Expression union
expression_from_fast :: proc(expr_ptr: ^$T) -> ^ast_pkg.Expression {
	if expr_ptr == nil {
		return nil
	}
	return transmute(^ast_pkg.Expression)expr_ptr
}

// Report an error
report_error :: proc(p: ^Parser, message: string) {
	loc := p.cur_tok.loc
	// Compute line/col lazily from line table (only on errors)
	if p.adapter != nil && loc.line == 0 {
		line, col := lexer_pkg.offset_to_line_col(p.adapter.opt.line_offsets, u32(loc.offset))
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

// Expect a specific token type
expect_token :: #force_inline proc(p: ^Parser, t: lexer_pkg.TokenType) -> bool {
	if p.cur_type != t {
		msg := fmt.tprintf("Expected %v, got %v", lexer_pkg.get_token_name(t), lexer_pkg.get_token_name(p.cur_type))
		report_error(p, msg)
		return false
	}
	advance_token(p)
	return true
}

// Check if current token matches type — zero cost, just a field read
is_token :: #force_inline proc(p: ^Parser, t: lexer_pkg.TokenType) -> bool {
	return p.cur_type == t
}

// Check if next token matches type — reads from fast_nxt (no indirection)
is_next_token :: #force_inline proc(p: ^Parser, t: lexer_pkg.TokenType) -> bool {
	if p.adapter != nil {
		return p.adapter.opt.fast_nxt.kind == t
	}
	return peek_token(p).type == t
}

// Consume current token if it matches
match_token :: #force_inline proc(p: ^Parser, t: lexer_pkg.TokenType) -> bool {
	if p.cur_type == t {
		advance_token(p)
		return true
	}
	return false
}

// Consume current token and return what was consumed
eat :: #force_inline proc(p: ^Parser) -> lexer_pkg.Token {
	return advance_token(p)
}

// Get current token — just return cached
get_current :: #force_inline proc(p: ^Parser) -> lexer_pkg.Token {
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

parse_program_item :: proc(p: ^Parser, body: ^[dynamic]^ast_pkg.Statement, start_offset: int) {
	stmt := parse_statement_or_declaration(p)
	if stmt != nil {
		append(body, stmt)
		return
	}

	// Try to parse as expression statement (e.g., dynamic import)
	if !is_token(p, .EOF) && get_current(p).loc.offset == start_offset {
		// Still at same position, try expression
		expr_stmt := parse_expression_statement(p)
		if expr_stmt != nil {
			append(body, expr_stmt)
			return
		}

		// Error recovery: we are stuck - consume tokens aggressively
		// Skip until we find a statement boundary or EOF
		stuck_count := 0
		for !is_token(p, .EOF) && get_current(p).loc.offset == start_offset {
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

parse_program :: proc(p: ^Parser, source_type: ast_pkg.SourceType) -> ^ast_pkg.Program {
	program := new_node(p, ast_pkg.Program)
	program.loc = loc_from_token(get_current(p))
	program.type = source_type
	program.body = make([dynamic]^ast_pkg.Statement, p.allocator)
	program.directives = make([dynamic]ast_pkg.Directive, p.allocator)

	// Parse body
	no_progress_count := 0
	for !is_token(p, .EOF) {
		loop_start_offset := get_current(p).loc.offset

		if is_token(p, .String) {
			// Check for "use strict" directive
			current := get_current(p)
			if current.literal == "use strict" {
				p.strict_mode = true
				directive := ast_pkg.Directive{
					loc   = loc_from_token(current),
					value = ast_pkg.StringLiteral{
						loc   = loc_from_token(current),
						value = "use strict",
						raw   = current.value,
					},
					raw = current.value,
				}
				append(&program.directives, directive)
				eat(p)
				if !match_token(p, .Semi) && !is_token(p, .EOF) {
					report_error(p, "Expected semicolon after directive")
				}
			} else {
				parse_program_item(p, &program.body, loop_start_offset)
			}
		} else {
			parse_program_item(p, &program.body, loop_start_offset)
		}

		if get_current(p).loc.offset == loop_start_offset {
			no_progress_count += 1
			if no_progress_count > MAX_ERROR_RECOVERY_ITERATIONS {
				report_error(p, "Maximum parsing iterations exceeded - possible infinite loop")
				break
			}
		} else {
			no_progress_count = 0
		}
	}

	program.loc.span.end = u32(get_current(p).loc.offset)
	return program
}

// ============================================================================
// Statements
// ============================================================================

parse_statement_or_declaration :: proc(p: ^Parser) -> ^ast_pkg.Statement {
	current := get_current(p)

	#partial switch current.type {
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

parse_block_statement :: proc(p: ^Parser) -> ^ast_pkg.Statement {
	start := loc_from_token(get_current(p))

	if !expect_token(p, .LBrace) {
		return nil
	}

	block, block_stmt := new_stmt(p, ast_pkg.BlockStatement)
	block.loc = start
	block.body = make([dynamic]^ast_pkg.Statement, p.allocator)

	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		prev_offset := p.cur_tok.loc.offset
		stmt := parse_statement_or_declaration(p)
		if stmt != nil {
			append(&block.body, stmt)
		} else if p.cur_tok.loc.offset == prev_offset {
			report_error(p, "Invalid statement in block")
			eat(p)
		}
	}

	if !match_token(p, .RBrace) {
		report_error(p, "Expected '}' at end of block")
	}

	block.loc.span.end = u32(p.cur_tok.loc.offset)
	return block_stmt
}

parse_empty_statement :: proc(p: ^Parser) -> ^ast_pkg.Statement {
	start := loc_from_token(get_current(p))
	eat(p)

	empty := new_node(p, ast_pkg.EmptyStatement)
	empty.loc = start
	empty.loc.span.end = u32(get_current(p).loc.offset)
	return statement_from(p, empty)
}

parse_expression_statement :: proc(p: ^Parser) -> ^ast_pkg.Statement {
	start := loc_from_token(get_current(p))

	expr := parse_expression(p)
	if expr == nil {
		return nil
	}

	// Check for labeled statement: identifier:
	if is_token(p, .Colon) {
		#partial switch e in expr {
		case ^ast_pkg.Identifier:
			eat(p) // consume :

			labeled := new_node(p, ast_pkg.LabeledStatement)
			labeled.loc = start
			labeled.label = ast_pkg.LabelIdentifier{
				loc  = e.loc,
				name = e.name,
			}
			labeled.body = parse_statement_or_declaration(p)

			return statement_from(p, labeled)
		}
	}

	expr_stmt, stmt := new_stmt(p, ast_pkg.ExpressionStatement)
	expr_stmt.loc = start
	expr_stmt.expression = expr

	// Consume optional semicolon
	match_semicolon_or_asi(p)

	expr_stmt.loc.span.end = u32(p.cur_tok.loc.offset)
	return stmt
}

parse_expression_or_labeled_statement :: proc(p: ^Parser) -> ^ast_pkg.Statement {
	return parse_expression_statement(p)
}

parse_if_statement :: proc(p: ^Parser) -> ^ast_pkg.Statement {
	start := loc_from_token(get_current(p))
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

	if_ := new_node(p, ast_pkg.IfStatement)
	if_.loc = start
	if_.test = test
	if_.consequent = consequent

	if match_token(p, .Else) {
		if_.alternate = parse_statement_or_declaration(p)
	}

	if_.loc.span.end = u32(get_current(p).loc.offset)
	return statement_from(p, if_)
}

parse_while_statement :: proc(p: ^Parser) -> ^ast_pkg.Statement {
	start := loc_from_token(get_current(p))
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

	while_ := new_node(p, ast_pkg.WhileStatement)
	while_.loc = start
	while_.test = test
	while_.body = body
	while_.loc.span.end = u32(get_current(p).loc.offset)

	return statement_from(p, while_)
}

parse_do_while_statement :: proc(p: ^Parser) -> ^ast_pkg.Statement {
	start := loc_from_token(get_current(p))
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

	do_ := new_node(p, ast_pkg.DoWhileStatement)
	do_.loc = start
	do_.body = body
	do_.test = test
	do_.loc.span.end = u32(get_current(p).loc.offset)

	return statement_from(p, do_)
}

parse_for_statement :: proc(p: ^Parser) -> ^ast_pkg.Statement {
	start := loc_from_token(get_current(p))
	eat(p) // consume for

	await := match_token(p, .Await)

	if !expect_token(p, .LParen) {
		return nil
	}

	// Check for for-in/for-of vs regular for
	// We need to look ahead to determine which type of for loop this is
	// Look for 'in' or 'of' after the left side

	left_expr: ^ast_pkg.Expression
	left_decl: ^ast_pkg.VariableDeclaration

	if is_token(p, .Var) || is_token(p, .Let) || is_token(p, .Const) {
		// Variable declaration - parse it
		decl_stmt := parse_variable_declaration(p, nil, false, true)
		if decl_stmt != nil {
			left_decl = transmute(^ast_pkg.VariableDeclaration)decl_stmt
			left_expr = transmute(^ast_pkg.Expression)decl_stmt
		}
	} else {
		// Parse left side as primary expression (not full expression)
		// to avoid consuming 'of' or 'in' as operators
		left_expr = parse_primary_expr(p)
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
			return nil
		}

		prev_in_loop := p.in_loop
		p.in_loop = true
		body := parse_statement_or_declaration(p)
		p.in_loop = prev_in_loop

		if is_in {
			// for-in - use separate fields for declaration vs expression
			for_in := new_node(p, ast_pkg.ForInStatement)
			for_in.loc = start
			if left_decl != nil {
				for_in.left_decl = left_decl
			} else {
				for_in.left_expr = left_expr
			}
			for_in.right = right
			for_in.body = body
			for_in.loc.span.end = u32(get_current(p).loc.offset)
			return statement_from(p, for_in)
		} else {
			// for-of or for-await-of - use separate fields
			for_of := new_node(p, ast_pkg.ForOfStatement)
			for_of.loc = start
			if left_decl != nil {
				for_of.left_decl = left_decl
			} else {
				for_of.left_expr = left_expr
			}
			for_of.right = right
			for_of.body = body
			for_of.await = await
			for_of.loc.span.end = u32(get_current(p).loc.offset)
			return statement_from(p, for_of)
		}
	}

	// Regular for statement: for (init; test; update)
	// Track init as either declaration or expression
	init_decl: Maybe(^ast_pkg.VariableDeclaration)
	init_expr: Maybe(^ast_pkg.Expression)
	if left_decl != nil {
		init_decl = left_decl
	} else if left_expr != nil {
		init_expr = left_expr
	}

	if !expect_token(p, .Semi) {
		return nil
	}

	test: Maybe(^ast_pkg.Expression)
	if !is_token(p, .Semi) {
		// Use Comma precedence to allow comma operator in test
		test = parse_expr_with_prec(p, .Comma)
	}

	if !expect_token(p, .Semi) {
		return nil
	}

	update: Maybe(^ast_pkg.Expression)
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

	for_ := new_node(p, ast_pkg.ForStatement)
	for_.loc = start
	for_.init_decl = init_decl
	for_.init_expr = init_expr
	for_.test = test
	for_.update = update
	for_.body = body
	for_.loc.span.end = u32(get_current(p).loc.offset)

	return statement_from(p, for_)
}

parse_return_statement :: proc(p: ^Parser) -> ^ast_pkg.Statement {
	start := loc_from_token(get_current(p))
	eat(p) // consume return

	if !p.in_function {
		report_error(p, "Return statement outside of function")
	}

	argument: Maybe(^ast_pkg.Expression)
	if !is_token(p, .Semi) && !is_token(p, .RBrace) && !is_token(p, .EOF) {
		argument = parse_expression(p)
	}

	match_semicolon_or_asi(p)

	ret := new_node(p, ast_pkg.ReturnStatement)
	ret.loc = start
	ret.argument = argument
	ret.loc.span.end = u32(get_current(p).loc.offset)

	return statement_from(p, ret)
}

parse_break_statement :: proc(p: ^Parser) -> ^ast_pkg.Statement {
	start := loc_from_token(get_current(p))
	eat(p) // consume break

	if !p.in_loop && !p.in_switch {
		report_error(p, "Break statement outside of loop or switch")
	}

	label: Maybe(ast_pkg.LabelIdentifier)
	if is_token(p, .Identifier) && !is_next_token(p, .Colon) {
		// It's a label reference, not start of labeled statement
		current := get_current(p)
		label = ast_pkg.LabelIdentifier{
			loc  = loc_from_token(current),
			name = current.value,
		}
		eat(p)
	}

	match_semicolon_or_asi(p)

	break_ := new_node(p, ast_pkg.BreakStatement)
	break_.loc = start
	break_.label = label
	break_.loc.span.end = u32(get_current(p).loc.offset)

	return statement_from(p, break_)
}

parse_continue_statement :: proc(p: ^Parser) -> ^ast_pkg.Statement {
	start := loc_from_token(get_current(p))
	eat(p) // consume continue

	if !p.in_loop {
		report_error(p, "Continue statement outside of loop")
	}

	label: Maybe(ast_pkg.LabelIdentifier)
	if is_token(p, .Identifier) {
		current := get_current(p)
		label = ast_pkg.LabelIdentifier{
			loc  = loc_from_token(current),
			name = current.value,
		}
		eat(p)
	}

	match_semicolon_or_asi(p)

	cont := new_node(p, ast_pkg.ContinueStatement)
	cont.loc = start
	cont.label = label
	cont.loc.span.end = u32(get_current(p).loc.offset)

	return statement_from(p, cont)
}

parse_switch_statement :: proc(p: ^Parser) -> ^ast_pkg.Statement {
	start := loc_from_token(get_current(p))
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

	switch_ := new_node(p, ast_pkg.SwitchStatement)
	switch_.loc = start
	switch_.discriminant = discriminant
	switch_.cases = make([dynamic]ast_pkg.SwitchCase, p.allocator)

	prev_in_switch := p.in_switch
	p.in_switch = true

	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		case_ := parse_switch_case(p)
		if case_ != nil {
			append(&switch_.cases, case_^)
		}
	}

	p.in_switch = prev_in_switch

	if !match_token(p, .RBrace) {
		report_error(p, "Expected '}' at end of switch statement")
	}

	switch_.loc.span.end = u32(get_current(p).loc.offset)
	return statement_from(p, switch_)
}

parse_switch_case :: proc(p: ^Parser) -> ^ast_pkg.SwitchCase {
	start := loc_from_token(get_current(p))

	test: Maybe(^ast_pkg.Expression)

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

	case_ := new_node(p, ast_pkg.SwitchCase)
	case_.loc = start
	case_.test = test
	case_.consequent = make([dynamic]^ast_pkg.Statement, p.allocator)

	for !is_token(p, .Case) && !is_token(p, .Default) && !is_token(p, .RBrace) && !is_token(p, .EOF) {
		stmt := parse_statement_or_declaration(p)
		if stmt != nil {
			append(&case_.consequent, stmt)
		}
	}

	case_.loc.span.end = u32(get_current(p).loc.offset)
	return case_
}

parse_try_statement :: proc(p: ^Parser) -> ^ast_pkg.Statement {
	start := loc_from_token(get_current(p))
	eat(p) // consume try

	block := parse_block_statement(p)
	if block == nil {
		return nil
	}

	try_ := new_node(p, ast_pkg.TryStatement)
	try_.loc = start
	try_.block = (transmute(^ast_pkg.BlockStatement)block)^

	if match_token(p, .Catch) {
		handler := parse_catch_clause(p)
		try_.handler = handler
	}

	if match_token(p, .Finally) {
		finalizer := parse_block_statement(p)
		if finalizer != nil {
			try_.finalizer = (transmute(^ast_pkg.BlockStatement)finalizer)^
		}
	}

	if try_.handler == nil && try_.finalizer == nil {
		report_error(p, "Try statement must have catch or finally clause")
	}

	try_.loc.span.end = u32(get_current(p).loc.offset)
	return statement_from(p, try_)
}

parse_catch_clause :: proc(p: ^Parser) -> Maybe(ast_pkg.CatchClause) {
	start := loc_from_token(get_current(p))

	param: Maybe(ast_pkg.Pattern)

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

	clause := ast_pkg.CatchClause{
		loc   = start,
		param = param,
		body  = (transmute(^ast_pkg.BlockStatement)body)^,
	}
	clause.loc.span.end = u32(get_current(p).loc.offset)

	return clause
}

parse_throw_statement :: proc(p: ^Parser) -> ^ast_pkg.Statement {
	start := loc_from_token(get_current(p))
	eat(p) // consume throw

	argument := parse_expression(p)
	if argument == nil {
		report_error(p, "Expected expression after throw")
		return nil
	}

	match_semicolon_or_asi(p)

	throw_ := new_node(p, ast_pkg.ThrowStatement)
	throw_.loc = start
	throw_.argument = argument
	throw_.loc.span.end = u32(get_current(p).loc.offset)

	return statement_from(p, throw_)
}

parse_debugger_statement :: proc(p: ^Parser) -> ^ast_pkg.Statement {
	start := loc_from_token(get_current(p))
	eat(p) // consume debugger

	match_semicolon_or_asi(p)

	debugger := new_node(p, ast_pkg.DebuggerStatement)
	debugger.loc = start
	debugger.loc.span.end = u32(get_current(p).loc.offset)

	return statement_from(p, debugger)
}

parse_with_statement :: proc(p: ^Parser) -> ^ast_pkg.Statement {
	start := loc_from_token(get_current(p))
	eat(p) // consume with

	if p.strict_mode {
		report_error(p, "With statement not allowed in strict mode")
	}

	if !expect_token(p, .LParen) {
		return nil
	}

	object := parse_expression(p)
	if object == nil {
		return nil
	}

	if !expect_token(p, .RParen) {
		return nil
	}

	body := parse_statement_or_declaration(p)

	with_ := new_node(p, ast_pkg.WithStatement)
	with_.loc = start
	with_.object = object
	with_.body = body
	with_.loc.span.end = u32(get_current(p).loc.offset)

	return statement_from(p, with_)
}

// ============================================================================
// Declarations
// ============================================================================

parse_function_declaration :: proc(p: ^Parser, is_expr := false) -> ^ast_pkg.Statement {
	start := loc_from_token(get_current(p))
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

	id: Maybe(ast_pkg.BindingIdentifier)

	if !is_expr || is_token(p, .Identifier) {
		if is_token(p, .Identifier) {
			current := get_current(p)
			id = ast_pkg.BindingIdentifier{
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
		expr := new_node(p, ast_pkg.FunctionExpression)
		expr.loc = start
		expr.id = id
		expr.params = params
		expr.body = body
		expr.generator = generator
		expr.async = async
		expr.loc.span.end = u32(get_current(p).loc.offset)

		// For function expressions, wrap in ExpressionStatement
		expr_stmt := new_node(p, ast_pkg.ExpressionStatement)
		expr_stmt.loc = start
		expr_stmt.expression = (^ast_pkg.Expression)(expr)
		expr_stmt.loc.span.end = u32(get_current(p).loc.offset)

		stmt := new_node(p, ast_pkg.Statement)
		stmt^ = expr_stmt
		return stmt
	}

	decl := new_node(p, ast_pkg.FunctionDeclaration)
	decl.expr = {
		loc = start,
		id = id,
		params = params,
		body = body,
		generator = generator,
		async = async,
	}
	decl.expr.loc.span.end = u32(get_current(p).loc.offset)

	// Allocate Statement union and store the pointer
	stmt := new_node(p, ast_pkg.Statement)
	stmt^ = (^ast_pkg.FunctionDeclaration)(decl)
	return stmt
}

parse_function_params :: proc(p: ^Parser) -> [dynamic]ast_pkg.FunctionParameter {
	params := make([dynamic]ast_pkg.FunctionParameter, 0, 3, p.allocator)

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

parse_function_param :: proc(p: ^Parser) -> ^ast_pkg.FunctionParameter {
	param := new_node(p, ast_pkg.FunctionParameter)
	param.loc = loc_from_token(get_current(p))

	// Check for rest parameter: ...identifier
	if match_token(p, .Dot3) {
		// Rest element - create RestElement as the pattern
		rest := new_node(p, ast_pkg.RestElement)
		rest.loc = param.loc

		// Parse the argument (identifier or destructuring pattern)
		arg_pattern := parse_binding_pattern(p)
		rest.argument = arg_pattern
		rest.loc.span.end = u32(get_current(p).loc.offset)

		// Store RestElement as the pattern
		param.pattern = rest
		// Rest parameters cannot have default values
		param.loc.span.end = u32(get_current(p).loc.offset)
		return param
	}

	pattern := parse_binding_pattern(p)
	param.pattern = pattern

	if match_token(p, .Assign) {
		param.default_val = parse_expression(p)
	}

	param.loc.span.end = u32(get_current(p).loc.offset)
	return param
}

parse_function_body :: proc(p: ^Parser) -> ast_pkg.FunctionBody {
	start := loc_from_token(get_current(p))

	if !expect_token(p, .LBrace) {
		return {}
	}

	body := ast_pkg.FunctionBody{
		loc        = start,
		body       = make([dynamic]^ast_pkg.Statement, p.allocator),
		directives = make([dynamic]ast_pkg.Directive, p.allocator),
	}

	prev_in_function := p.in_function
	prev_in_generator := p.in_generator
	prev_in_async := p.in_async
	prev_strict := p.strict_mode

	p.in_function = true

	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		stmt := parse_statement_or_declaration(p)
		if stmt != nil {
			append(&body.body, stmt)
		}
	}

	p.in_function = prev_in_function
	p.in_generator = prev_in_generator
	p.in_async = prev_in_async
	p.strict_mode = prev_strict

	if !match_token(p, .RBrace) {
		report_error(p, "Expected '}' at end of function body")
	}

	body.loc.span.end = u32(get_current(p).loc.offset)
	return body
}

parse_class_declaration :: proc(p: ^Parser) -> ^ast_pkg.Statement {
	start := loc_from_token(get_current(p))
	eat(p) // consume class

	id: Maybe(ast_pkg.BindingIdentifier)
	if is_token(p, .Identifier) {
		current := get_current(p)
		id = ast_pkg.BindingIdentifier{
			loc  = loc_from_token(current),
			name = current.value,
		}
		eat(p)
	}

	super_class: Maybe(^ast_pkg.Expression)
	if match_token(p, .Extends) {
		super_class = parse_left_hand_side_expr(p)
	}

	body := parse_class_body(p)

	// Allocate ClassDeclaration and Statement separately
	decl := new_node(p, ast_pkg.ClassDeclaration)
	decl.expr = {
		loc         = start,
		id          = id,
		super_class = super_class,
		body        = body,
	}
	decl.expr.loc.span.end = u32(get_current(p).loc.offset)

	// Allocate Statement union and store the pointer
	stmt := new_node(p, ast_pkg.Statement)
	stmt^ = (^ast_pkg.ClassDeclaration)(decl)

	return stmt
}

parse_class_body :: proc(p: ^Parser) -> ast_pkg.ClassBody {
	start := loc_from_token(get_current(p))

	if !expect_token(p, .LBrace) {
		return {}
	}

	body := ast_pkg.ClassBody{
		loc  = start,
		body = make([dynamic]ast_pkg.ClassElement, p.allocator),
	}

	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		prev_offset := get_current(p).loc.offset
		elem := parse_class_element(p)
		if elem != nil {
			append(&body.body, elem^)
		} else if get_current(p).loc.offset == prev_offset {
			// parse_class_element failed and didn't consume token - skip it to avoid infinite loop
			report_error(p, "Invalid class element")
			eat(p)
		}
	}

	if !match_token(p, .RBrace) {
		report_error(p, "Expected '}' at end of class body")
	}

	body.loc.span.end = u32(get_current(p).loc.offset)
	return body
}

parse_class_element :: proc(p: ^Parser) -> ^ast_pkg.ClassElement {
	start := loc_from_token(get_current(p))

	// Check for static block: static { ... }
	if is_token(p, .Static) && is_next_token(p, .LBrace) {
		return parse_static_block(p, start)
	}

	static_ := match_token(p, .Static)

	kind := ast_pkg.ClassElementKind.Method
	is_async := false
	is_generator := false
	computed := false
	is_private := false

	// Check for async keyword
	if is_token(p, .Async) {
		// Only treat as async if followed by something that starts a method name
		next := peek_dispatch(p)
		if next.type == .Identifier || next.type == .PrivateIdentifier || next.type == .LBracket ||
		   next.type == .String || next.type == .Number || next.type == .LParen {
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
	key: ^ast_pkg.Expression
	if is_token(p, .PrivateIdentifier) {
		// Private field or method: #field, #method
		current := get_current(p)
		is_private = true

		// Create PrivateIdentifier (strip the # prefix)
		name := current.value
		if len(name) > 0 && name[0] == '#' {
			name = name[1:]
		}

		private_ident := new_node(p, ast_pkg.PrivateIdentifier)
		private_ident.loc = loc_from_token(current)
		private_ident.name = name
		key = expression_from(p, private_ident)
		eat(p)
	} else if is_token(p, .Identifier) || is_token(p, .String) || is_token(p, .Number) || is_token(p, .Constructor) || is_token(p, .Get) || is_token(p, .Set) || is_token(p, .Async) || is_token(p, .Static) {
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
		key = parse_expression(p)
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
		value: Maybe(^ast_pkg.Expression)

		if match_token(p, .Assign) {
			init_expr := parse_expression(p)
			if init_expr != nil {
				value = init_expr
			}
		}

		// Consume optional semicolon
		match_semicolon_or_asi(p)

		elem := new_node(p, ast_pkg.ClassElement)
		elem.loc = start
		elem.key = key
		elem.value = value
		elem.kind = kind  // Still .Method but value is not a function
		elem.computed = false
		elem.static = static_

		elem.loc.span.end = u32(get_current(p).loc.offset)
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
	fn_expr := new_node(p, ast_pkg.FunctionExpression)
	fn_expr.loc = start
	fn_expr.id = nil // Methods don't have names in their function expression
	fn_expr.params = params
	fn_expr.body = body
	fn_expr.generator = is_generator
	fn_expr.async = is_async
	fn_expr.loc.span.end = u32(get_current(p).loc.offset)

	elem := new_node(p, ast_pkg.ClassElement)
	elem.loc = start
	elem.key = key
	elem.value = expression_from(p, fn_expr)
	elem.kind = kind
	elem.computed = computed
	elem.static = static_

	elem.loc.span.end = u32(get_current(p).loc.offset)
	return elem
}

// Parse ES2022 static block: static { ... }
parse_static_block :: proc(p: ^Parser, start: ast_pkg.Loc) -> ^ast_pkg.ClassElement {
	match_token(p, .Static) // consume static

	// Parse block statement
	block_stmt := parse_block_statement(p)
	if block_stmt == nil {
		return nil
	}

	// Extract the block's body
	block := transmute(^ast_pkg.BlockStatement)block_stmt

	// Create a StaticBlock value (stored as a FunctionExpression with no params)
	static_block := new_node(p, ast_pkg.FunctionExpression)
	static_block.loc = start
	static_block.id = nil
	static_block.params = make([dynamic]ast_pkg.FunctionParameter, p.allocator)
	static_block.body = ast_pkg.FunctionBody{
		loc = block.loc,
		body = block.body,
	}
	static_block.generator = false
	static_block.async = false
	static_block.loc.span.end = u32(get_current(p).loc.offset)

	elem := new_node(p, ast_pkg.ClassElement)
	elem.loc = start
	elem.key = nil  // Static blocks don't have a key
	elem.value = expression_from(p, static_block)
	elem.kind = .StaticBlock
	elem.computed = false
	elem.static = false  // Not marked as static - the kind implies it

	elem.loc.span.end = u32(get_current(p).loc.offset)
	return elem
}

parse_variable_declaration :: proc(p: ^Parser, kind_override: Maybe(ast_pkg.VariableKind), consume_semi: bool, in_for := false) -> ^ast_pkg.Statement {
	start := loc_from_token(get_current(p))

	kind: ast_pkg.VariableKind

	#partial switch get_current(p).type {
	case .Var:
		kind = .Var
	case .Let:
		kind = .Let
	case .Const:
		kind = .Const
	case:
		if k, ok := kind_override.(ast_pkg.VariableKind); ok {
			kind = k
		} else {
			report_error(p, "Expected var, let, or const")
			return nil
		}
	}

	eat(p)

	decl := new_node(p, ast_pkg.VariableDeclaration)
	decl.loc = start
	decl.kind = kind
	decl.declarations = make([dynamic]ast_pkg.VariableDeclarator, p.allocator)

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

	decl.loc.span.end = u32(p.cur_tok.loc.offset)
	stmt := new_node(p, ast_pkg.Statement)
	stmt^ = decl
	return stmt
}

parse_variable_declarator :: proc(p: ^Parser, kind: ast_pkg.VariableKind, in_for := false) -> ^ast_pkg.VariableDeclarator {
	start := loc_from_token(get_current(p))

	pattern := parse_binding_pattern(p)

	init: Maybe(^ast_pkg.Expression)
	if match_token(p, .Assign) {
		init = parse_expression(p)
	} else if kind == .Const && !in_for {
		report_error(p, "const declarations must have an initializer")
	}

	decl := new_node(p, ast_pkg.VariableDeclarator)
	decl.loc = start
	decl.id = pattern
	decl.init = init
	decl.loc.span.end = u32(get_current(p).loc.offset)

	return decl
}

parse_binding_pattern :: proc(p: ^Parser) -> ast_pkg.Pattern {
	start := loc_from_token(get_current(p))

	if is_token(p, .LBrace) {
		return parse_object_pattern(p)
	}

	if is_token(p, .LBracket) {
		return parse_array_pattern(p)
	}

	if is_token(p, .Identifier) {
		current := get_current(p)
		eat(p)
		ident := new_node(p, ast_pkg.Identifier)
		ident.loc = loc_from_token(current)
		ident.name = current.value
		return ident
	}

	report_error(p, "Expected binding pattern")
	return nil
}

parse_object_pattern :: proc(p: ^Parser) -> ast_pkg.Pattern {
	start := loc_from_token(get_current(p))

	if !expect_token(p, .LBrace) {
		return nil
	}

	obj := new_node(p, ast_pkg.ObjectPattern)
	obj.loc = start
	obj.properties = make([dynamic]ast_pkg.ObjectPatternProperty, 0, 4, p.allocator)

	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		prop_start := loc_from_token(get_current(p))

		// Check for rest element: ...identifier
		if match_token(p, .Dot3) {
			if !is_token(p, .Identifier) {
				report_error(p, "Expected identifier after ... in object pattern")
				return nil
			}
			current := get_current(p)
			rest := new_node(p, ast_pkg.RestElement)
			rest.loc = prop_start
			rest_loc := loc_from_token(current)
			rest_ident := new_node(p, ast_pkg.Identifier)
			rest_ident.loc = rest_loc
			rest_ident.name = current.value
			rest.argument = rest_ident
			rest.loc.span.end = u32(current.loc.offset + len(current.value))
			eat(p)

			rest_prop := ast_pkg.ObjectPatternProperty{
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
		key: Maybe(ast_pkg.ObjectPatternPropertyKey)
		computed := false

		if is_token(p, .LBracket) {
			// Computed property: [expr]
			computed = true
			eat(p)
			expr_key := parse_expression(p)
			if expr_key != nil {
				key = (^ast_pkg.Expression)(expr_key)
			}
			if !expect_token(p, .RBracket) {
				return nil
			}
		} else if is_token(p, .Identifier) || is_token(p, .String) {
			// Identifier or string key
			id_name := ast_pkg.IdentifierName{
				loc  = loc_from_token(get_current(p)),
				name = get_current(p).value,
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

			// Parse value as pattern
			if is_token(p, .Identifier) {
				current := get_current(p)
				value_ident := new_node(p, ast_pkg.Identifier)
				value_ident.loc = loc_from_token(current)
				value_ident.name = current.value
				eat(p)

				// Check for default value: { key: value = defaultValue }
				if match_token(p, .Assign) {
					default_val := parse_expression(p)
					assign := new_node(p, ast_pkg.AssignmentPattern)
					assign.loc = prop_start
					assign.left = value_ident
					assign.right = default_val
					assign.loc.span.end = u32(get_current(p).loc.offset)

					prop := ast_pkg.ObjectPatternProperty{
						loc       = prop_start,
						key       = key,
						value     = assign,
						computed  = computed,
						shorthand = false,
					}
					append(&obj.properties, prop)
				} else {
					prop := ast_pkg.ObjectPatternProperty{
						loc       = prop_start,
						key       = key,
						value     = value_ident,
						computed  = computed,
						shorthand = false,
					}
					append(&obj.properties, prop)
				}
			} else if is_token(p, .LBrace) {
				// Nested object pattern
				nested := parse_object_pattern(p)
				if nested == nil {
					return nil
				}
				prop := ast_pkg.ObjectPatternProperty{
					loc       = prop_start,
						key       = key,
					value     = nested,
					computed  = computed,
						shorthand = false,
				}
				append(&obj.properties, prop)
			} else if is_token(p, .LBracket) {
				// Nested array pattern
				nested := parse_array_pattern(p)
				if nested == nil {
					return nil
				}
				prop := ast_pkg.ObjectPatternProperty{
					loc       = prop_start,
					key       = key,
					value     = nested,
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
			default_val := parse_expression(p)
			// Create AssignmentPattern with key as left
			if k := key; k != nil {
				val := k.?  // unwrap Maybe
				#partial switch v in val {
				case ast_pkg.IdentifierName:
					left_ident := new_node(p, ast_pkg.Identifier)
					left_ident.loc = v.loc
					left_ident.name = v.name
					assign := new_node(p, ast_pkg.AssignmentPattern)
					assign.loc = prop_start
					assign.left = left_ident
					assign.right = default_val
					assign.loc.span.end = u32(get_current(p).loc.offset)
					
					prop := ast_pkg.ObjectPatternProperty{
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
				case ast_pkg.IdentifierName:
					left_ident := new_node(p, ast_pkg.Identifier)
					left_ident.loc = v.loc
					left_ident.name = v.name
					
					prop := ast_pkg.ObjectPatternProperty{
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

	obj.loc.span.end = u32(get_current(p).loc.offset)
	return obj
}

// Helper to create identifier from token info
new_identifier :: proc(p: ^Parser, tok: lexer_pkg.Token) -> ^ast_pkg.Identifier {
	ident := new_node(p, ast_pkg.Identifier)
	ident.loc = loc_from_token(tok)
	ident.name = tok.value
	return ident
}

parse_array_pattern :: proc(p: ^Parser) -> ast_pkg.Pattern {
	start := loc_from_token(get_current(p))

	if !expect_token(p, .LBracket) {
		return nil
	}

	arr := new_node(p, ast_pkg.ArrayPattern)
	arr.loc = start

	// Use dynamic array for elements - each element is Maybe(Pattern)
	elements := make([dynamic]Maybe(ast_pkg.Pattern), p.allocator)

	for !is_token(p, .RBracket) && !is_token(p, .EOF) {
		// Check for elision (hole): just a comma
		if is_token(p, .Comma) {
			// This is a hole in the array - add nil
			append(&elements, Maybe(ast_pkg.Pattern){})
			eat(p) // consume comma
			continue
		}

		// Check for rest element: ...identifier
		if match_token(p, .Dot3) {
			if !is_token(p, .Identifier) {
				report_error(p, "Expected identifier after ... in array pattern")
				return nil
			}
			current := get_current(p)
			eat(p)

			rest := new_node(p, ast_pkg.RestElement)
			rest.loc = loc_from_token(current)
			rest_ident := new_node(p, ast_pkg.Identifier)
			rest_ident.loc = loc_from_token(current)
			rest_ident.name = current.value
			rest.argument = rest_ident
			rest.loc.span.end = u32(get_current(p).loc.offset)

			append(&elements, Maybe(ast_pkg.Pattern)(rest))

			// Rest element must be last
			if !is_token(p, .RBracket) && !is_token(p, .EOF) {
				report_error(p, "Rest element must be last in array pattern")
			}
			break
		}

		// Parse regular element
		if is_token(p, .Identifier) {
			// Simple identifier binding
			current := get_current(p)
			eat(p)
			ident := new_node(p, ast_pkg.Identifier)
			ident.loc = loc_from_token(current)
			ident.name = current.value
			append(&elements, Maybe(ast_pkg.Pattern)(ident))
		} else if is_token(p, .LBrace) {
			// Nested object pattern
			nested := parse_object_pattern(p)
			if nested == nil {
				return nil
			}
			append(&elements, Maybe(ast_pkg.Pattern)(nested))
		} else if is_token(p, .LBracket) {
			// Nested array pattern (recursive)
			nested := parse_array_pattern(p)
			if nested == nil {
				return nil
			}
			append(&elements, Maybe(ast_pkg.Pattern)(nested))
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
	arr.loc.span.end = u32(get_current(p).loc.offset)
	return arr
}

// ============================================================================
// Module Import/Export
// ============================================================================

parse_import_declaration :: proc(p: ^Parser) -> ^ast_pkg.Statement {
	start := loc_from_token(get_current(p))
	eat(p) // consume import

	decl := new_node(p, ast_pkg.ImportDeclaration)
	decl.loc = start
	decl.specifiers = make([dynamic]^ast_pkg.ImportSpecifierSpec, p.allocator)

	if is_token(p, .String) {
		// import "module"
		decl.source = parse_string_literal(p)
	} else if is_token(p, .LBrace) {
		// Named imports: import { x, y } from "module"
		eat(p) // consume {

		for !is_token(p, .RBrace) && !is_token(p, .EOF) {
			spec := parse_import_specifier(p)
			if spec != nil {
				append(&decl.specifiers, (^ast_pkg.ImportSpecifierSpec)(spec))
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
		spec := new_node(p, ast_pkg.ImportNamespaceSpecifier)
		spec.loc = local.loc
		spec.local = ast_pkg.BindingIdentifier{
			loc  = local.loc,
			name = local.name,
		}
		spec.loc.span.end = u32(get_current(p).loc.offset)
		append(&decl.specifiers, (^ast_pkg.ImportSpecifierSpec)(spec))

		if !expect_token(p, .From) {
			return nil
		}

		decl.source = parse_string_literal(p)
	} else if is_token(p, .Identifier) {
		// Default import: import name from "module" or import name, { x } from "module"
		local := parse_identifier(p)
		spec := new_node(p, ast_pkg.ImportDefaultSpecifier)
		spec.loc = local.loc
		spec.local = ast_pkg.BindingIdentifier{
			loc  = local.loc,
			name = local.name,
		}
		spec.loc.span.end = u32(get_current(p).loc.offset)
		append(&decl.specifiers, (^ast_pkg.ImportSpecifierSpec)(spec))

		// Check for comma followed by named imports
		if match_token(p, .Comma) {
			if is_token(p, .LBrace) {
				eat(p) // consume {

				for !is_token(p, .RBrace) && !is_token(p, .EOF) {
					spec2 := parse_import_specifier(p)
					if spec2 != nil {
						append(&decl.specifiers, (^ast_pkg.ImportSpecifierSpec)(spec2))
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
				ns_spec := new_node(p, ast_pkg.ImportNamespaceSpecifier)
				ns_spec.loc = local2.loc
				ns_spec.local = ast_pkg.BindingIdentifier{
					loc  = local2.loc,
					name = local2.name,
				}
				ns_spec.loc.span.end = u32(get_current(p).loc.offset)
				append(&decl.specifiers, (^ast_pkg.ImportSpecifierSpec)(ns_spec))
			}
		}

		if !expect_token(p, .From) {
			return nil
		}

		decl.source = parse_string_literal(p)
	}

	match_semicolon_or_asi(p)

	decl.loc.span.end = u32(get_current(p).loc.offset)

	// Allocate Statement union and store the pointer
	stmt := new_node(p, ast_pkg.Statement)
	stmt^ = (^ast_pkg.ImportDeclaration)(decl)
	return stmt
}

parse_import_specifier :: proc(p: ^Parser) -> ^ast_pkg.ImportSpecifier {
	start := loc_from_token(get_current(p))

	imported := parse_identifier_name(p)

	local := imported
	if match_token(p, .As) {
		local = parse_identifier(p)
	}

	spec := new_node(p, ast_pkg.ImportSpecifier)
	spec.loc = start
	spec.imported = ast_pkg.IdentifierName{
		loc  = imported.loc,
		name = imported.name,
	}
	spec.local = ast_pkg.BindingIdentifier{
		loc  = local.loc,
		name = local.name,
	}
	spec.loc.span.end = u32(get_current(p).loc.offset)

	return spec
}

parse_export_declaration :: proc(p: ^Parser) -> ^ast_pkg.Statement {
	start := loc_from_token(get_current(p))
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

	export_decl := new_node(p, ast_pkg.ExportNamedDeclaration)
	export_decl.loc = start
	export_decl.declaration = (^ast_pkg.Declaration)(decl)
	export_decl.loc.span.end = u32(get_current(p).loc.offset)

	// Allocate Statement union and store the pointer
	stmt := new_node(p, ast_pkg.Statement)
	stmt^ = (^ast_pkg.ExportNamedDeclaration)(export_decl)
	return stmt
}

parse_export_default :: proc(p: ^Parser, start: ast_pkg.Loc) -> ^ast_pkg.Statement {
	def: ^ast_pkg.ExportDefaultDef

	if is_token(p, .Function) || is_token(p, .Class) || is_token(p, .Async) {
		decl := parse_statement_or_declaration(p)
		if decl != nil {
			def = transmute(^ast_pkg.ExportDefaultDef)decl
		}
	} else {
		expr := parse_expression(p)
		if expr != nil {
			def = transmute(^ast_pkg.ExportDefaultDef)expr
		}
		match_semicolon_or_asi(p)
	}

	decl := new_node(p, ast_pkg.ExportDefaultDeclaration)
	decl.loc = start
	decl.declaration = def
	decl.loc.span.end = u32(get_current(p).loc.offset)

	// Allocate Statement union and store the pointer
	stmt := new_node(p, ast_pkg.Statement)
	stmt^ = (^ast_pkg.ExportDefaultDeclaration)(decl)
	return stmt
}

parse_export_all :: proc(p: ^Parser, start: ast_pkg.Loc) -> ^ast_pkg.Statement {
	exported: Maybe(ast_pkg.IdentifierName)

	if match_token(p, .As) {
		name := parse_identifier_name(p)
		exported = ast_pkg.IdentifierName{
			loc  = name.loc,
			name = name.name,
		}
	}

	if !expect_token(p, .From) {
		return nil
	}

	source := parse_string_literal(p)

	decl := new_node(p, ast_pkg.ExportAllDeclaration)
	decl.loc = start
	decl.source = source
	decl.exported = exported
	decl.loc.span.end = u32(get_current(p).loc.offset)

	// Allocate Statement union and store the pointer
	stmt := new_node(p, ast_pkg.Statement)
	stmt^ = (^ast_pkg.ExportAllDeclaration)(decl)
	return stmt
}

parse_export_named :: proc(p: ^Parser, start: ast_pkg.Loc) -> ^ast_pkg.Statement {
	if !expect_token(p, .LBrace) {
		return nil
	}

	decl := new_node(p, ast_pkg.ExportNamedDeclaration)
	decl.loc = start
	decl.specifiers = make([dynamic]ast_pkg.ExportSpecifier, p.allocator)

	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		start_spec := loc_from_token(get_current(p))
		local := parse_identifier_name(p)

		exported := local
		if match_token(p, .As) {
			exported = parse_identifier_name(p)
		}

		spec := ast_pkg.ExportSpecifier{
			loc = start_spec,
			local = ast_pkg.IdentifierName{
				loc  = local.loc,
				name = local.name,
			},
			exported = ast_pkg.IdentifierName{
				loc  = exported.loc,
				name = exported.name,
			},
		}
		spec.loc.span.end = u32(get_current(p).loc.offset)
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

	decl.loc.span.end = u32(get_current(p).loc.offset)

	// Allocate Statement union and store the pointer
	stmt := new_node(p, ast_pkg.Statement)
	stmt^ = (^ast_pkg.ExportNamedDeclaration)(decl)
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
precedence_table: [len(lexer_pkg.TokenType)]Precedence

@(init)
init_precedence_table :: proc "contextless" () {
	// Default to None — non-operator tokens break the Pratt loop immediately
	for i in 0..<len(precedence_table) {
		precedence_table[i] = .None
	}

	// Set specific precedences
	precedence_table[lexer_pkg.TokenType.Comma]       = .Comma
	precedence_table[lexer_pkg.TokenType.Dot3]        = .Spread
	precedence_table[lexer_pkg.TokenType.Arrow]       = .Assignment
	precedence_table[lexer_pkg.TokenType.Question]    = .Conditional
	precedence_table[lexer_pkg.TokenType.LogicalOr]   = .LogicalOr
	precedence_table[lexer_pkg.TokenType.Nullish]     = .NullishCoalescing
	precedence_table[lexer_pkg.TokenType.LogicalAnd]  = .LogicalAnd
	precedence_table[lexer_pkg.TokenType.BitOr]       = .BitwiseOr
	precedence_table[lexer_pkg.TokenType.BitXor]      = .BitwiseXor
	precedence_table[lexer_pkg.TokenType.BitAnd]      = .BitwiseAnd
	precedence_table[lexer_pkg.TokenType.Eq]          = .Equality
	precedence_table[lexer_pkg.TokenType.NotEq]        = .Equality
	precedence_table[lexer_pkg.TokenType.EqStrict]     = .Equality
	precedence_table[lexer_pkg.TokenType.NotEqStrict]  = .Equality
	precedence_table[lexer_pkg.TokenType.LAngle]       = .Relational
	precedence_table[lexer_pkg.TokenType.RAngle]       = .Relational
	precedence_table[lexer_pkg.TokenType.LEq]          = .Relational
	precedence_table[lexer_pkg.TokenType.GEq]          = .Relational
	precedence_table[lexer_pkg.TokenType.In]           = .Relational
	precedence_table[lexer_pkg.TokenType.Instanceof]   = .Relational
	precedence_table[lexer_pkg.TokenType.LShift]       = .Shift
	precedence_table[lexer_pkg.TokenType.RShift]       = .Shift
	precedence_table[lexer_pkg.TokenType.URShift]      = .Shift
	precedence_table[lexer_pkg.TokenType.Plus]         = .Additive
	precedence_table[lexer_pkg.TokenType.Minus]        = .Additive
	precedence_table[lexer_pkg.TokenType.Mul]          = .Multiplicative
	precedence_table[lexer_pkg.TokenType.Div]          = .Multiplicative
	precedence_table[lexer_pkg.TokenType.Mod]          = .Multiplicative
	precedence_table[lexer_pkg.TokenType.Pow]          = .Exponentiation

	// Assignment operators
	precedence_table[lexer_pkg.TokenType.Assign]           = .Assignment
	precedence_table[lexer_pkg.TokenType.AssignAdd]          = .Assignment
	precedence_table[lexer_pkg.TokenType.AssignSub]          = .Assignment
	precedence_table[lexer_pkg.TokenType.AssignMul]          = .Assignment
	precedence_table[lexer_pkg.TokenType.AssignDiv]          = .Assignment
	precedence_table[lexer_pkg.TokenType.AssignMod]          = .Assignment
	precedence_table[lexer_pkg.TokenType.AssignPow]          = .Assignment
	precedence_table[lexer_pkg.TokenType.AssignLShift]       = .Assignment
	precedence_table[lexer_pkg.TokenType.AssignRShift]       = .Assignment
	precedence_table[lexer_pkg.TokenType.AssignURShift]      = .Assignment
	precedence_table[lexer_pkg.TokenType.AssignBitAnd]       = .Assignment
	precedence_table[lexer_pkg.TokenType.AssignBitOr]        = .Assignment
	precedence_table[lexer_pkg.TokenType.AssignBitXor]       = .Assignment
	precedence_table[lexer_pkg.TokenType.AssignLogicalAnd]   = .Assignment
	precedence_table[lexer_pkg.TokenType.AssignLogicalOr]    = .Assignment
	precedence_table[lexer_pkg.TokenType.AssignNullish]      = .Assignment
}

// Fast O(1) precedence lookup using precomputed table
precedence_for_token :: #force_inline proc(t: lexer_pkg.TokenType) -> Precedence {
	return precedence_table[t]
}

// Parse expression using precedence climbing (efficient Pratt-style parsing)
// Parse full expression including comma operator
parse_expression :: proc(p: ^Parser) -> ^ast_pkg.Expression {
	return parse_expr_with_prec(p, .Assignment)
}

parse_expr_with_prec :: proc(p: ^Parser, min_prec: Precedence) -> ^ast_pkg.Expression {
	left := parse_unary_expr(p)
	if left == nil {
		return nil
	}

	for {
		cur_type := p.cur_type
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
			if lexer_pkg.is_assignment_operator(cur_type) {
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
			logical, logical_e := new_expr(p, ast_pkg.LogicalExpression)
			logical.loc = loc_from_expr(left)
			logical.operator = token_to_logical_op(cur_type)
			logical.left = left
			logical.right = right
			logical.loc.span.end = u32(p.cur_tok.loc.offset)

			left = logical_e
			continue
		}

		// Regular binary operator
		binary, binary_e := new_expr(p, ast_pkg.BinaryExpression)
		binary.loc = loc_from_expr(left)
		binary.operator = token_to_binary_op(cur_type)
		binary.left = left
		binary.right = right
		binary.loc.span.end = u32(p.cur_tok.loc.offset)

		left = binary_e
	}

	return left
}

// Merged unary + update + left-hand-side to reduce call depth (5→3 frames)
parse_unary_expr :: proc(p: ^Parser) -> ^ast_pkg.Expression {
	#partial switch p.cur_type {
	case .Plus, .Minus, .BitNot, .Not, .Typeof, .Void, .Delete:
		current := p.cur_tok
		eat(p)
		argument := parse_unary_expr(p)
		if argument == nil { return nil }
		unary := new_node(p, ast_pkg.UnaryExpression)
		unary.loc = loc_from_token(current)
		unary.operator = token_to_unary_op(current.type)
		unary.argument = argument
		unary.prefix = true
		unary.loc.span.end = u32(p.cur_tok.loc.offset)
		return expression_from(p, unary)

	case .PlusPlus, .MinusMinus:
		current := p.cur_tok
		eat(p)
		argument := parse_unary_expr(p)
		if argument == nil { return nil }
		update := new_node(p, ast_pkg.UpdateExpression)
		update.loc = loc_from_token(current)
		update.operator = .Increment if current.type == .PlusPlus else .Decrement
		update.argument = argument
		update.prefix = true
		update.loc.span.end = u32(p.cur_tok.loc.offset)
		return expression_from(p, update)

	case .Await:
		if p.strict_mode && !p.in_async && p.in_function {
			report_error(p, "await outside of async function")
		}
		current := p.cur_tok
		eat(p)
		argument := parse_unary_expr(p)
		if argument == nil { return nil }
		await := new_node(p, ast_pkg.AwaitExpression)
		await.loc = loc_from_token(current)
		await.argument = argument
		await.loc.span.end = u32(p.cur_tok.loc.offset)
		return expression_from(p, await)

	case .Dot3:
		current := p.cur_tok
		eat(p)
		argument := parse_unary_expr(p)
		if argument == nil { return nil }
		spread := new_node(p, ast_pkg.SpreadElement)
		spread.loc = loc_from_token(current)
		spread.argument = argument
		spread.loc.span.end = u32(p.cur_tok.loc.offset)
		return expression_from(p, spread)

	case .Yield:
		if !p.in_generator {
			report_error(p, "yield outside of generator function")
		}
		return parse_yield_expr(p)
	}

	// Common path: primary expression + optional postfix ++ / -- (inlined parse_update_expr)
	expr := parse_left_hand_side_expr(p)
	if expr == nil { return nil }

	if p.cur_type == .PlusPlus || p.cur_type == .MinusMinus {
		current := p.cur_tok
		eat(p)
		update := new_node(p, ast_pkg.UpdateExpression)
		update.loc = loc_from_expr(expr)
		update.operator = .Increment if current.type == .PlusPlus else .Decrement
		update.argument = expr
		update.prefix = false
		update.loc.span.end = u32(p.cur_tok.loc.offset)
		return expression_from(p, update)
	}

	return expr
}

parse_left_hand_side_expr :: proc(p: ^Parser) -> ^ast_pkg.Expression {
	expr := parse_primary_expr(p)
	if expr == nil {
		return nil
	}

	for {
		#partial switch p.cur_type {
		case .Dot:
			eat(p)
			prop := parse_identifier_name(p)

			member, member_e := new_expr(p, ast_pkg.MemberExpression)
			member.loc = loc_from_expr(expr)
			member.object = expr
			id, id_e := new_expr(p, ast_pkg.Identifier)
			id.loc = prop.loc
			id.name = prop.name
			member.property = id_e
			member.computed = false
			member.optional = false
			member.loc.span.end = u32(p.cur_tok.loc.offset)

			expr = member_e

		case .OptionalChain:
			// Optional chaining: obj?.prop, arr?.[0], fn?.()
			eat(p) // consume ?.

			// Check what follows ?.
			if is_token(p, .Identifier) {
				// obj?.property
				prop := parse_identifier_name(p)

				member := new_node(p, ast_pkg.MemberExpression)
				member.loc = loc_from_expr(expr)
				member.object = expr
				ident := new_node(p, ast_pkg.Identifier)
				ident.loc = prop.loc
				ident.name = prop.name
				member.property = expression_from(p, ident)
				member.computed = false
				member.optional = true
				member.loc.span.end = u32(get_current(p).loc.offset)

				expr = expression_from(p, member)
			} else if is_token(p, .LBracket) {
				// arr?.[index]
				eat(p) // consume [
				prop := parse_expression(p)
				if prop == nil {
					return nil
				}
				if !expect_token(p, .RBracket) {
					return nil
				}

				member := new_node(p, ast_pkg.MemberExpression)
				member.loc = loc_from_expr(expr)
				member.object = expr
				member.property = prop
				member.computed = true
				member.optional = true
				member.loc.span.end = u32(get_current(p).loc.offset)

				expr = expression_from(p, member)
			} else if is_token(p, .LParen) {
				// fn?.() - optional call
				args := parse_arguments(p)

				call := new_node(p, ast_pkg.CallExpression)
				call.loc = loc_from_expr(expr)
				call.callee = expr
				call.arguments = args
				call.optional = true
				call.loc.span.end = u32(get_current(p).loc.offset)

				expr = expression_from(p, call)
			} else {
				report_error(p, "Unexpected token after ?.")
				return expr
			}

		case .LBracket:
			eat(p)
			prop := parse_expression(p)
			if prop == nil {
				return nil
			}

			if !expect_token(p, .RBracket) {
				return nil
			}

			mem2, mem2_e := new_expr(p, ast_pkg.MemberExpression)
			mem2.loc = loc_from_expr(expr)
			mem2.object = expr
			mem2.property = prop
			mem2.computed = true
			mem2.optional = false
			mem2.loc.span.end = u32(p.cur_tok.loc.offset)

			expr = mem2_e

		case .LParen:
			args := parse_arguments(p)

			call, call_e := new_expr(p, ast_pkg.CallExpression)
			call.loc = loc_from_expr(expr)
			call.callee = expr
			call.arguments = args
			call.optional = false
			call.loc.span.end = u32(p.cur_tok.loc.offset)

			expr = call_e

		case .TemplateHead, .Template:
			// Tagged template literal: expr`...` or expr`${...}`
			tagged := new_node(p, ast_pkg.TaggedTemplateExpression)
			tagged.loc = loc_from_expr(expr)
			tagged.tag = expr
			tagged.quasi = parse_template_literal(p)
			tagged.loc.span.end = u32(get_current(p).loc.offset)
			expr = expression_from(p, tagged)

		case:
			return expr
		}
	}

	return expr
}

parse_primary_expr :: proc(p: ^Parser) -> ^ast_pkg.Expression {
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

			meta_prop := new_node(p, ast_pkg.MetaProperty)
			meta_prop.loc = loc_from_token(current)
			meta_prop.meta = ast_pkg.Identifier{
				loc  = loc_from_token(current),
				name = "import",
			}
			meta_prop.property = ast_pkg.Identifier{
				loc  = meta_name.loc,
				name = meta_name.name,
			}
			meta_prop.loc.span.end = u32(get_current(p).loc.offset)
			return expression_from(p, meta_prop)
		}
		// Static import - not valid in expression context
		report_error(p, "Unexpected import in expression context")
		return nil

	case .This:
		eat(p)
		this := new_node(p, ast_pkg.ThisExpression)
		this.loc = loc_from_token(current)
		this.loc.span.end = u32(get_current(p).loc.offset)
		return expression_from(p, this)

	case .PrivateIdentifier:
		// Private field reference: #x (used in expressions like #x in this)
		name := current.value
		if len(name) > 0 && name[0] == '#' {
			name = name[1:]
		}
		pid := new_node(p, ast_pkg.PrivateIdentifier)
		pid.loc = loc_from_token(current)
		pid.name = name
		eat(p)
		pid.loc.span.end = u32(get_current(p).loc.offset)
		return expression_from(p, pid)

	case .Super:
		eat(p)
		super := new_node(p, ast_pkg.Super)
		super.loc = loc_from_token(current)
		super.loc.span.end = u32(get_current(p).loc.offset)
		return expression_from(p, super)

	case .Null:
		eat(p)
		nl, nl_e := new_expr(p, ast_pkg.NullLiteral)
		nl.loc = loc_from_token(current)
		nl.loc.span.end = u32(p.cur_tok.loc.offset)
		return nl_e

	case .True, .False:
		eat(p)
		bl, bl_e := new_expr(p, ast_pkg.BooleanLiteral)
		bl.loc = loc_from_token(current)
		bl.value = current.type == .True
		bl.loc.span.end = u32(p.cur_tok.loc.offset)
		return bl_e

	case .Number:
		eat(p)
		num, num_e := new_expr(p, ast_pkg.NumericLiteral)
		num.loc = loc_from_token(current)
		num.raw = current.value
		if val, ok := current.literal.(f64); ok {
			num.value = val
		}
		num.loc.span.end = u32(p.cur_tok.loc.offset)
		return num_e

	case .String:
		eat(p)
		str, str_e := new_expr(p, ast_pkg.StringLiteral)
		str.loc = loc_from_token(current)
		str.raw = current.value
		if val, ok := current.literal.(string); ok {
			str.value = val
		}
		str.loc.span.end = u32(p.cur_tok.loc.offset)
		return str_e

	case .BigInt:
		eat(p)
		big := new_node(p, ast_pkg.BigIntLiteral)
		big.loc = loc_from_token(current)
		big.raw = current.value
		big.value = current.value  // Store as string
		big.loc.span.end = u32(get_current(p).loc.offset)
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
				ident := new_node(p, ast_pkg.Identifier)
				ident.loc = loc_from_token(current)
				ident.name = "async"
				ident.loc.span.end = u32(get_current(p).loc.offset)
				return expression_from(p, ident)
			} else if next.type == .LParen {
				// async () => ...
				eat(p) // consume async
				return parse_async_arrow_with_parens(p, current)
			}
		}
		// async as identifier
		eat(p)
		ident := new_node(p, ast_pkg.Identifier)
		ident.loc = loc_from_token(current)
		ident.name = "async"
		ident.loc.span.end = u32(get_current(p).loc.offset)
		return expression_from(p, ident)

	case .Identifier:
		eat(p)
		id, id_expr := new_expr(p, ast_pkg.Identifier)
		id.loc = loc_from_token(current)
		id.name = current.value
		id.loc.span.end = u32(p.cur_tok.loc.offset)
		return id_expr

	case .LParen:
		// Check for arrow function with empty params: () => ...
		if is_next_token(p, .RParen) {
			// Potential empty arrow function params
			eat(p) // consume (
			eat(p) // consume )
			if is_token(p, .Arrow) {
				// This is () => ... - return a marker for empty params
				seq := new_node(p, ast_pkg.SequenceExpression)
				seq.loc = loc_from_token(current)
				seq.expressions = make([dynamic]^ast_pkg.Expression, p.allocator)
				return expression_from(p, seq)
			}
			// Not an arrow, return nil (empty parens not valid expression)
			return nil
		}

		// Regular parenthesized expression
		// Use Comma precedence to handle (x, y) => ... arrow function case
		eat(p)
		expr := parse_expr_with_prec(p, .Comma)
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
		regex := new_node(p, ast_pkg.RegExpLiteral)
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
		regex.loc.span.end = u32(get_current(p).loc.offset)
		return expression_from(p, regex)

	case:
		// Unknown token type
		return nil
	}
}

parse_array_expr :: proc(p: ^Parser) -> ^ast_pkg.Expression {
	start := loc_from_token(get_current(p))

	if !expect_token(p, .LBracket) {
		return nil
	}

	arr := new_node(p, ast_pkg.ArrayExpression)
	arr.loc = start
	arr.elements = make([dynamic]Maybe(^ast_pkg.Expression), p.allocator)

	for !is_token(p, .RBracket) && !is_token(p, .EOF) {
		if match_token(p, .Comma) {
			// Sparse element
			append(&arr.elements, nil)
			continue
		}

		if is_token(p, .Dot3) {
			// Spread element
			eat(p)
			arg := parse_expression(p)
			if arg != nil {
				spread := new_node(p, ast_pkg.SpreadElement)
				spread.loc = loc_from_expr(arg)
				spread.argument = arg
				spread.loc.span.end = u32(get_current(p).loc.offset)
				append(&arr.elements, Maybe(^ast_pkg.Expression)(expression_from(p, spread)))
			}
		} else {
			elem := parse_expression(p)
			if elem != nil {
				append(&arr.elements, Maybe(^ast_pkg.Expression)(elem))
			}
		}

		if !match_token(p, .Comma) {
			break
		}
	}

	if !expect_token(p, .RBracket) {
		return nil
	}

	arr.loc.span.end = u32(get_current(p).loc.offset)
	return expression_from(p, arr)
}

parse_object_expr :: proc(p: ^Parser) -> ^ast_pkg.Expression {
	start := loc_from_token(get_current(p))

	if !expect_token(p, .LBrace) {
		return nil
	}

	obj := new_node(p, ast_pkg.ObjectExpression)
	obj.loc = start
	obj.properties = make([dynamic]ast_pkg.Property, 0, 4, p.allocator)

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

	obj.loc.span.end = u32(get_current(p).loc.offset)
	return expression_from(p, obj)
}

parse_property :: proc(p: ^Parser) -> ^ast_pkg.Property {
	start := loc_from_token(get_current(p))

	computed := false
	key: ^ast_pkg.Expression

	if is_token(p, .Dot3) {
		// Spread property: ...expr
		eat(p)
		arg := parse_expression(p)
		if arg == nil {
			return nil
		}

		prop := new_node(p, ast_pkg.Property)
		prop.loc = start
		prop.key = nil
		prop.value = arg
		prop.kind = .Init
		prop.computed = false
		prop.shorthand = false
		prop.loc.span.end = u32(get_current(p).loc.offset)
		return prop
	}

	// Check for get/set keywords and generator/async modifiers
	is_getter := false
	is_setter := false
	is_generator := false
	is_async := false

	if is_token(p, .Get) {
		// Look ahead: if next token is an identifier and then () or :, it's a getter
		eat(p)
		is_getter = true
	} else if is_token(p, .Set) {
		eat(p)
		is_setter = true
	} else if is_token(p, .Async) {
		eat(p)
		is_async = true
	}

	// Check for generator modifier (can come after async or before identifier)
	if is_token(p, .Mul) {
		eat(p)
		is_generator = true
	}

	// Parse key
	if match_token(p, .LBracket) {
		computed = true
		key = parse_expression(p)
		if key == nil {
			return nil
		}
		if !expect_token(p, .RBracket) {
			return nil
		}
	} else if is_token(p, .Identifier) || is_token(p, .String) || is_token(p, .Number) {
		key = parse_property_name(p)
	} else {
		return nil
	}

	// Determine property kind and parse value
	kind := ast_pkg.PropertyKind.Init
	value: ^ast_pkg.Expression
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

		fn := new_node(p, ast_pkg.FunctionExpression)
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

		fn := new_node(p, ast_pkg.FunctionExpression)
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

	prop := new_node(p, ast_pkg.Property)
	prop.loc = start
	prop.key = key
	prop.value = value
	prop.kind = kind
	prop.computed = computed
	prop.shorthand = shorthand
	prop.loc.span.end = u32(get_current(p).loc.offset)

	return prop
}

parse_property_name :: proc(p: ^Parser) -> ^ast_pkg.Expression {
	current := get_current(p)

	#partial switch current.type {
	case .Identifier:
		eat(p)
		ident := new_node(p, ast_pkg.Identifier)
		ident.loc = loc_from_token(current)
		ident.name = current.value
		ident.loc.span.end = u32(get_current(p).loc.offset)
		return expression_from(p, ident)

	case .String:
		eat(p)
		str := new_node(p, ast_pkg.StringLiteral)
		str.loc = loc_from_token(current)
		str.raw = current.value
		if val, ok := current.literal.(string); ok {
			str.value = val
		}
		str.loc.span.end = u32(get_current(p).loc.offset)
		return expression_from(p, str)

	case .Number:
		eat(p)
		num := new_node(p, ast_pkg.NumericLiteral)
		num.loc = loc_from_token(current)
		num.raw = current.value
		if val, ok := current.literal.(f64); ok {
			num.value = val
		}
		num.loc.span.end = u32(get_current(p).loc.offset)
		return expression_from(p, num)

	case:
		return nil
	}
}

parse_function_expression :: proc(p: ^Parser) -> ^ast_pkg.Expression {
	// Parse as function expression (not declaration)
	stmt := parse_function_declaration(p, true)
	if stmt == nil {
		return nil
	}
	// Extract FunctionExpression from FunctionDeclaration
	// FunctionDeclaration has 'using expr: FunctionExpression'
	decl := transmute(^ast_pkg.FunctionDeclaration)stmt
	fn_expr := new_node(p, ast_pkg.FunctionExpression)
	fn_expr^ = decl.expr
	return expression_from(p, fn_expr)
}

parse_class_expression :: proc(p: ^Parser) -> ^ast_pkg.Expression {
	start := loc_from_token(get_current(p))
	eat(p) // consume class

	id: Maybe(ast_pkg.BindingIdentifier)
	if is_token(p, .Identifier) {
		current := get_current(p)
		id = ast_pkg.BindingIdentifier{
			loc  = loc_from_token(current),
			name = current.value,
		}
		eat(p)
	}

	super_class: Maybe(^ast_pkg.Expression)
	if match_token(p, .Extends) {
		super_class = parse_left_hand_side_expr(p)
	}

	body := parse_class_body(p)

	expr := new_node(p, ast_pkg.ClassExpression)
	expr.loc = start
	expr.id = id
	expr.super_class = super_class
	expr.body = body
	expr.loc.span.end = u32(get_current(p).loc.offset)

	return expression_from(p, expr)
}

parse_new_expr :: proc(p: ^Parser) -> ^ast_pkg.Expression {
	start := loc_from_token(get_current(p))
	eat(p) // consume new

	callee := parse_left_hand_side_expr(p)
	if callee == nil {
		return nil
	}

	args: [dynamic]^ast_pkg.Expression
	if is_token(p, .LParen) {
		args = parse_arguments(p)
	}

	new_ := new_node(p, ast_pkg.NewExpression)
	new_.loc = start
	new_.callee = callee
	new_.arguments = args
	new_.loc.span.end = u32(get_current(p).loc.offset)

	return expression_from(p, new_)
}

parse_arguments :: proc(p: ^Parser) -> [dynamic]^ast_pkg.Expression {
	if !expect_token(p, .LParen) {
		return nil
	}

	args := make([dynamic]^ast_pkg.Expression, 0, 4, p.allocator)

	if !is_token(p, .RParen) {
		for {
			if is_token(p, .Dot3) {
				eat(p)
				arg := parse_expression(p)
				if arg != nil {
					spread := new_node(p, ast_pkg.SpreadElement)
					spread.loc = loc_from_expr(arg)
					spread.argument = arg
					spread.loc.span.end = u32(get_current(p).loc.offset)
					append(&args, expression_from(p, spread))
				}
			} else {
				arg := parse_expression(p)
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

parse_yield_expr :: proc(p: ^Parser) -> ^ast_pkg.Expression {
	start := loc_from_token(get_current(p))
	eat(p) // consume yield

	delegate := match_token(p, .Mul)

	argument: Maybe(^ast_pkg.Expression)
	if !is_token(p, .Semi) && !is_token(p, .RParen) && !is_token(p, .RBracket) && !is_token(p, .RBrace) && !is_token(p, .Comma) {
		argument = parse_expression(p)
	}

	yield := new_node(p, ast_pkg.YieldExpression)
	yield.loc = start
	yield.argument = argument
	yield.delegate = delegate
	yield.loc.span.end = u32(get_current(p).loc.offset)

	return expression_from(p, yield)
}

parse_template_literal :: proc(p: ^Parser) -> ^ast_pkg.Expression {
	start := loc_from_token(get_current(p))
	current := get_current(p)

	tmpl := new_node(p, ast_pkg.TemplateLiteral)
	tmpl.loc = start
	tmpl.quasis = make([dynamic]ast_pkg.TemplateElement, p.allocator)
	tmpl.expressions = make([dynamic]^ast_pkg.Expression, p.allocator)

	// Handle simple template: `hello`
	if current.type == .Template {
		elem := ast_pkg.TemplateElement{
			loc  = loc_from_token(current),
			tail = true,
			raw  = current.value,
		}
		if cooked, ok := current.literal.(string); ok {
			elem.cooked = cooked
		}
		append(&tmpl.quasis, elem)
		eat(p)
		tmpl.loc.span.end = u32(get_current(p).loc.offset)
		return expression_from(p, tmpl)
	}

	// Handle template with expressions: `hello ${name} world`
	if current.type == .TemplateHead {
		// First quasi: `hello ${
		elem := ast_pkg.TemplateElement{
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
			expr := parse_expression(p)
			if expr != nil {
				append(&tmpl.expressions, expr)
			}

			// Expect TemplateMiddle or TemplateTail
			tok := get_current(p)
			if tok.type == .TemplateMiddle {
				elem := ast_pkg.TemplateElement{
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
				elem := ast_pkg.TemplateElement{
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

		tmpl.loc.span.end = u32(get_current(p).loc.offset)
		return expression_from(p, tmpl)
	}

	report_error(p, "Expected template literal")
	return nil
}

parse_arrow_function :: proc(p: ^Parser, left: ^ast_pkg.Expression, is_async := false) -> ^ast_pkg.Expression {
	start: ast_pkg.Loc
	if left != nil {
		start = loc_from_expr(left)
	} else {
		start = loc_from_token(get_current(p))
	}

	// left should be parameters (identifier or parenthesized expression)
	// nil left means empty params: () => ...
	eat(p) // consume =>

	// Set async context for body parsing
	prev_async := p.in_async
	if is_async {
		p.in_async = true
	}

	// Parse body
	body: ^ast_pkg.Expression
	if is_token(p, .LBrace) {
		// Block body - need to set in_function for return statement validation
		prev_in_function := p.in_function
		p.in_function = true
		block_stmt := parse_block_statement(p)
		p.in_function = prev_in_function
		if block_stmt != nil {
			// Block body - use transmute (arrow functions with block need special handling)
			body = transmute(^ast_pkg.Expression)block_stmt
		}
	} else {
		body = parse_expression(p)
	}

	p.in_async = prev_async

	// Convert left to parameters
	params := make([dynamic]ast_pkg.FunctionParameter, p.allocator)

	if left != nil {
		#partial switch e in left {
		case ^ast_pkg.Identifier:
			ident := new_node(p, ast_pkg.Identifier)
			ident^ = e^
			param := ast_pkg.FunctionParameter{
				loc     = e.loc,
				pattern = ident,
			}
			append(&params, param)
		case ^ast_pkg.SequenceExpression:
			if len(e.expressions) == 0 {
				// Empty parameters: () => ... (marker from parse_primary_expr)
				// params stays empty
			} else {
				// Multiple parameters: (a, b) => ...
				// Each element in the sequence should be an identifier (or pattern)
				for expr_ptr in e.expressions {
					#partial switch arg in expr_ptr^ {
					case ^ast_pkg.Identifier:
						param_ident := new_node(p, ast_pkg.Identifier)
						param_ident^ = arg^
						param := ast_pkg.FunctionParameter{
							loc     = arg.loc,
							pattern = param_ident,
						}
						append(&params, param)
					case ^ast_pkg.SpreadElement:
						// Rest parameter: (...rest) => ...
						rest := new_node(p, ast_pkg.RestElement)
						rest.loc = arg.loc
						// SpreadElement.argument is ^Expression
						// For arrow params, the argument should be an Identifier
						// RestElement.argument expects Pattern (^Identifier), so we need to create a new pointer
						ident_expr := arg.argument
						if ident_expr != nil {
							#partial switch id in ident_expr^ {
							case ^ast_pkg.Identifier:
								ident_ptr := new_node(p, ast_pkg.Identifier)
								ident_ptr^ = id^
								rest.argument = ident_ptr
							case:
								report_error(p, "Expected identifier in rest parameter")
							}
						}
						rest.loc.span.end = u32(get_current(p).loc.offset)
						param := ast_pkg.FunctionParameter{
							loc     = arg.loc,
							pattern = rest,
						}
						append(&params, param)
					case ^ast_pkg.ObjectExpression:
						// Convert ObjectExpression -> ObjectPattern for destructuring
						op := new_node(p, ast_pkg.ObjectPattern)
						op.loc = arg.loc
						// skip property copy - different types
						param := ast_pkg.FunctionParameter{
							loc     = arg.loc,
							pattern = op,
						}
						append(&params, param)
					case ^ast_pkg.ArrayExpression:
						// Convert ArrayExpression -> ArrayPattern for destructuring
						ap := new_node(p, ast_pkg.ArrayPattern)
						ap.loc = arg.loc
						// Convert each element expression to pattern
						elem_patterns := make([dynamic]Maybe(ast_pkg.Pattern), 0, len(arg.elements), p.allocator)
						for elem in arg.elements {
							if elem == nil {
								append(&elem_patterns, Maybe(ast_pkg.Pattern)(nil))
							} else {
								val := elem.? // unwrap Maybe(^Expression)
								#partial switch e in val^ {
								case ^ast_pkg.Identifier:
									id_ptr := new_node(p, ast_pkg.Identifier)
									id_ptr^ = e^
									append(&elem_patterns, id_ptr)
								case:
									append(&elem_patterns, Maybe(ast_pkg.Pattern)(nil))
								}
							}
						}
						ap.elements = elem_patterns[:]
						param := ast_pkg.FunctionParameter{
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

	arrow := new_node(p, ast_pkg.ArrowFunctionExpression)
	arrow.loc = start
	arrow.params = params
	arrow.body = body
	arrow.expression = !is_token(p, .LBrace) // Simple expression or block
	arrow.async = false
	arrow.loc.span.end = u32(get_current(p).loc.offset)

	return expression_from(p, arrow)
}

parse_conditional_expr :: proc(p: ^Parser, test: ^ast_pkg.Expression) -> ^ast_pkg.Expression {
	start := loc_from_expr(test)
	eat(p) // consume ?

	consequent := parse_expression(p)
	if consequent == nil {
		return nil
	}

	if !expect_token(p, .Colon) {
		return nil
	}

	alternate := parse_expression(p)
	if alternate == nil {
		return nil
	}

	cond := new_node(p, ast_pkg.ConditionalExpression)
	cond.loc = start
	cond.test = test
	cond.consequent = consequent
	cond.alternate = alternate
	cond.loc.span.end = u32(get_current(p).loc.offset)

	return expression_from(p, cond)
}

parse_assignment_expr :: proc(p: ^Parser, left: ^ast_pkg.Expression) -> ^ast_pkg.Expression {
	start := loc_from_expr(left)

	current := get_current(p)
	op := token_to_assignment_op(current.type)

	eat(p)

	right := parse_expr_with_prec(p, .Assignment)
	if right == nil {
		return nil
	}

	assign := new_node(p, ast_pkg.AssignmentExpression)
	assign.loc = start
	assign.operator = op
	assign.left = left
	assign.right = right
	assign.loc.span.end = u32(get_current(p).loc.offset)

	return expression_from(p, assign)
}

parse_identifier :: proc(p: ^Parser) -> ast_pkg.Identifier {
	current := get_current(p)
	eat(p)
	return ast_pkg.Identifier{
		loc  = loc_from_token(current),
		name = current.value,
	}
}

parse_identifier_name :: proc(p: ^Parser) -> ast_pkg.Identifier {
	return parse_identifier(p)
}

parse_string_literal :: proc(p: ^Parser) -> ast_pkg.StringLiteral {
	current := get_current(p)
	eat(p)
	return ast_pkg.StringLiteral{
		loc   = loc_from_token(current),
		raw   = current.value,
		value = current.literal.(string) or_else "",
	}
}

// ============================================================================
// Async Arrow Function Helpers
// ============================================================================

parse_async_arrow_function :: proc(p: ^Parser, param: ast_pkg.Identifier) -> ^ast_pkg.Expression {
	start := param.loc

	eat(p) // consume =>

	prev_async := p.in_async
	p.in_async = true

	// Parse body
	body: ^ast_pkg.Expression
	if is_token(p, .LBrace) {
		// Block body - need to set in_function for return statement validation
		prev_in_function := p.in_function
		p.in_function = true
		block_stmt := parse_block_statement(p)
		p.in_function = prev_in_function
		if block_stmt != nil {
			body = transmute(^ast_pkg.Expression)block_stmt
		}
	} else {
		body = parse_expression(p)
	}

	p.in_async = prev_async

	// Create single param
	params := make([dynamic]ast_pkg.FunctionParameter, p.allocator)
	param_ident := new_node(p, ast_pkg.Identifier)
	param_ident^ = param
	fn_param := ast_pkg.FunctionParameter{
		loc     = param.loc,
		pattern = param_ident,
	}
	append(&params, fn_param)

	arrow := new_node(p, ast_pkg.ArrowFunctionExpression)
	arrow.loc = start
	arrow.params = params
	arrow.body = body
	arrow.expression = !is_token(p, .LBrace)
	arrow.async = true
	arrow.loc.span.end = u32(get_current(p).loc.offset)

	return expression_from(p, arrow)
}

parse_async_arrow_with_parens :: proc(p: ^Parser, async_tok: lexer_pkg.Token) -> ^ast_pkg.Expression {
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

	// Parse body
	body: ^ast_pkg.Expression
	if is_token(p, .LBrace) {
		// Block body - need to set in_function for return statement validation
		prev_in_function := p.in_function
		p.in_function = true
		block_stmt := parse_block_statement(p)
		p.in_function = prev_in_function
		if block_stmt != nil {
			body = transmute(^ast_pkg.Expression)block_stmt
		}
	} else {
		body = parse_expression(p)
	}

	p.in_async = prev_async

	arrow := new_node(p, ast_pkg.ArrowFunctionExpression)
	arrow.loc = start
	arrow.params = params
	arrow.body = body
	arrow.expression = !is_token(p, .LBrace)
	arrow.async = true
	arrow.loc.span.end = u32(get_current(p).loc.offset)

	return expression_from(p, arrow)
}

// ============================================================================
// Dynamic Import Helper
// ============================================================================

parse_dynamic_import :: proc(p: ^Parser) -> ^ast_pkg.Expression {
	start := loc_from_token(get_current(p))

	eat(p) // consume import

	// consume (
	if !is_token(p, .LParen) {
		report_error(p, "Expected ( after import")
		return nil
	}
	eat(p)

	specifier := parse_expression(p)
	if specifier == nil {
		return nil
	}

	// consume )
	if !is_token(p, .RParen) {
		report_error(p, "Expected ) after import specifier")
		return nil
	}
	eat(p)

	import_expr := new_node(p, ast_pkg.ImportExpression)
	import_expr.loc = start
	import_expr.source = specifier
	import_expr.loc.span.end = u32(get_current(p).loc.offset)

	return expression_from(p, import_expr)
}

// ============================================================================
// Utility Functions
// ============================================================================

loc_from_token :: #force_inline proc(t: lexer_pkg.Token) -> ast_pkg.Loc {
	return ast_pkg.Loc{
		span   = ast_pkg.Span{
			start = u32(t.loc.offset),
			end   = u32(t.loc.offset + len(t.value)),
		},
		line   = u32(t.loc.line),
		column = u32(t.loc.column),
	}
}

// Extract loc from any Expression variant. All variants have `loc` as first field.
loc_from_expr :: #force_inline proc(e: ^ast_pkg.Expression) -> ast_pkg.Loc {
	if e == nil { return {} }
	#partial switch v in e {
	case ^ast_pkg.Identifier:             return v.loc
	case ^ast_pkg.NumericLiteral:          return v.loc
	case ^ast_pkg.StringLiteral:           return v.loc
	case ^ast_pkg.BooleanLiteral:          return v.loc
	case ^ast_pkg.NullLiteral:             return v.loc
	case ^ast_pkg.ThisExpression:           return v.loc
	case ^ast_pkg.Super:                    return v.loc
	case ^ast_pkg.ArrayExpression:          return v.loc
	case ^ast_pkg.ObjectExpression:         return v.loc
	case ^ast_pkg.FunctionExpression:       return v.loc
	case ^ast_pkg.ArrowFunctionExpression:  return v.loc
	case ^ast_pkg.MemberExpression:         return v.loc
	case ^ast_pkg.CallExpression:           return v.loc
	case ^ast_pkg.NewExpression:            return v.loc
	case ^ast_pkg.ConditionalExpression:    return v.loc
	case ^ast_pkg.UnaryExpression:          return v.loc
	case ^ast_pkg.BinaryExpression:         return v.loc
	case ^ast_pkg.LogicalExpression:        return v.loc
	case ^ast_pkg.AssignmentExpression:     return v.loc
	case ^ast_pkg.UpdateExpression:         return v.loc
	case ^ast_pkg.SpreadElement:            return v.loc
	case ^ast_pkg.YieldExpression:          return v.loc
	case ^ast_pkg.AwaitExpression:          return v.loc
	case ^ast_pkg.ImportExpression:         return v.loc
	case ^ast_pkg.MetaProperty:             return v.loc
	case ^ast_pkg.BigIntLiteral:            return v.loc
	case ^ast_pkg.RegExpLiteral:            return v.loc
	case ^ast_pkg.TemplateLiteral:          return v.loc
	case ^ast_pkg.TaggedTemplateExpression: return v.loc
	case ^ast_pkg.SequenceExpression:       return v.loc
	case ^ast_pkg.ClassExpression:          return v.loc
	case ^ast_pkg.PrivateIdentifier:        return v.loc
	}
	return {}
}

token_to_unary_op :: proc(t: lexer_pkg.TokenType) -> ast_pkg.UnaryOperator {
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

token_to_binary_op :: proc(t: lexer_pkg.TokenType) -> ast_pkg.BinaryOperator {
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

token_to_assignment_op :: proc(t: lexer_pkg.TokenType) -> ast_pkg.AssignmentOperator {
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

token_to_logical_op :: proc(t: lexer_pkg.TokenType) -> ast_pkg.LogicalOperator {
	#partial switch t {
	case .LogicalOr:  return .Or
	case .LogicalAnd: return .And
	case .Nullish:    return .NullishCoalescing
	}
	return .Or // Default
}
