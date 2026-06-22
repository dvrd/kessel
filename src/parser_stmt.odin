package kessel

import "core:fmt"
import "core:strings"

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

check_stmt_reserved_word_at_start :: proc(p: ^Parser) {
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
}

check_label_identifier_reserved :: proc(p: ^Parser, e: ^Identifier) {
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
}

check_labeled_item_body :: proc(p: ^Parser, labeled: ^LabeledStatement) {
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
}

build_labeled_statement :: proc(p: ^Parser, e: ^Identifier, start: Loc) -> ^Statement {
	eat(p) // consume :

	check_label_identifier_reserved(p, e)

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
	check_labeled_item_body(p, labeled)

	return statement_from(p, labeled)
}

parse_labeled_statement :: proc(p: ^Parser, expr: ^Expression, start: Loc) -> ^Statement {
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
			return build_labeled_statement(p, e, start)
		}
	}
	return nil
}

parse_expression_statement :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)

	check_stmt_reserved_word_at_start(p)

	expr := parse_expression(p)
	if expr == nil {
		return nil
	}

	if labeled := parse_labeled_statement(p, expr, start); labeled != nil {
		return labeled
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
		return parse_for_in_of_tail(p, left_expr, left_decl, await, start)
	}

	return parse_for_classic_tail(p, left_expr, left_decl, await, start)
}

// parse_for_in_of_tail builds the ForIn / ForOf node from an already-parsed
// for-head LHS (left_expr OR left_decl). Cursor is on the `in` / `of` keyword.
// Extracted from parse_for_statement to keep it under the 70-line limit; this
// is pure code motion (control flow and diagnostics unchanged).
parse_for_in_of_tail :: proc(p: ^Parser, left_expr: ^Expression, left_decl: ^VariableDeclaration, await: bool, start: Loc) -> ^Statement {
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
		for_in_of_check_expr_lhs(p, left_expr, is_in, await)
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
		for_in_of_check_decl_lhs(p, left_decl, is_in)
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

// parse_for_classic_tail builds the C-style ForStatement (init; test; update)
// from an already-parsed for-head init (left_expr OR left_decl). Cursor is on
// the first `;`. Extracted from parse_for_statement; pure code motion.
parse_for_classic_tail :: proc(p: ^Parser, left_expr: ^Expression, left_decl: ^VariableDeclaration, await: bool, start: Loc) -> ^Statement {
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

	id := parse_function_decl_name(p, is_expr, async, generator)

	// TypeScript generic type parameters: `function foo<T, U>(...)`
	type_parameters: Maybe(^TSTypeParameterDeclaration)
	if is_token(p, .LAngle) && allow_ts_mode(p) { type_parameters = parse_ts_type_parameters(p) }

	if !expect_token(p, .LParen) {
		return nil
	}

	params := parse_function_decl_params(p, start, async, generator)

	// TypeScript return type annotation
	return_type: Maybe(^TSTypeAnnotation)
	if is_token(p, .Colon) && allow_ts_mode(p) {
		return_type = parse_ts_return_type_annotation(p)
	}

	body, body_strict, is_ts_no_body := parse_function_decl_body(p, is_expr, allow_no_body, async, generator)

	check_function_decl_retro(p, start, id, params[:], body, body_strict, async, is_ts_no_body)

	return build_function_decl(p, start, id, params, body, generator, async, type_parameters, return_type, is_ts_no_body, is_expr)
}

// parse_function_decl_params parses the parenthesised FormalParameters of a
// FunctionDeclaration / FunctionExpression with the generator/async/static-block
// parameter-context save/set/restore dance, then runs the parameter-modifier +
// duplicate-name checks and the RParen error recovery. Control flow stays in
// parse_function_declaration.
parse_function_decl_params :: proc(p: ^Parser, start: Loc, async, generator: bool) -> [dynamic]FunctionParameter {
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
	return params
}

// parse_function_decl_body resolves the body-vs-no-body decision (TS overload /
// ambient signatures) and parses the FunctionBody under the nested function scope
// (the async/generator/method/derived-ctor/field-init context save/set/restore).
// Returns the body, whether it promoted to strict via a "use strict" directive,
// and whether it is a TS overload / ambient no-body signature.
parse_function_decl_body :: proc(p: ^Parser, is_expr, allow_no_body, async, generator: bool) -> (body: FunctionBody, body_strict: bool, is_ts_no_body: bool) {
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
	is_ts_no_body = is_no_body

	p.ctx.in_async = prev_async
	p.ctx.in_generator = prev_gen
	p.ctx.in_async_params = prev_in_async_params_body
	p.ctx.in_generator_params = prev_in_gen_params_body
	p.ctx.in_method = prev_in_method
	p.ctx.in_derived_constructor = prev_in_derived_ctor
	p.ctx.in_field_init = prev_in_field_init_fn
	return
}

// check_function_decl_retro runs the retroactive strict-mode / overload-signature
// early-error checks that can only fire after the body parses (a "use strict"
// directive may promote the body to strict): UniqueFormalParameters, K3052
// non-simple params, strict binding patterns, the strict function-name reservation,
// the params-vs-body lexical-name clash, and the TS signature parameter rules.
check_function_decl_retro :: proc(p: ^Parser, start: Loc, id: Maybe(BindingIdentifier), params: []FunctionParameter, body: FunctionBody, body_strict, async, is_ts_no_body: bool) {
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
		parser_check_dup_params(p, params, start.start, true, false)
	}

	// §15.1.1 / §15.5.1 / §15.6.1 / §15.8.1 — it is a SyntaxError if
	// the function body has a `"use strict"` directive AND the parameter
	// list is not simple.
	// The directive cannot promote params that have already been evaluated
	// (or contain destructuring / defaults), so the spec rejects the
	// combination outright.
	force_non_simple := !params_are_simple(params)
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
		report_strict_param_pattern_retro(p, params)
	}
	check_function_name_strict_retro(p, id, body_strict, strict_for_check, async)

	// §15.2.1.1 / §15.5.1 - It is a Syntax Error if any element of the
	// BoundNames of FormalParameters also occurs in the LexicallyDeclaredNames
	// of FunctionBody. e.g. `function f(a) { const a = 1; }` is SyntaxError.
	// Collect param names and check against body's lex declarations.
 if !p.ast_only {
	check_params_vs_body_lex(p, params, body.body[:])
 }

	check_ts_function_signature_params(p, params, is_ts_no_body)
}

// build_function_decl constructs the FunctionExpression-wrapped ExpressionStatement
// (is_expr) or the FunctionDeclaration node and boxes it into a ^Statement.
build_function_decl :: proc(p: ^Parser, start: Loc, id: Maybe(BindingIdentifier), params: [dynamic]FunctionParameter, body: FunctionBody, generator, async: bool, type_parameters: Maybe(^TSTypeParameterDeclaration), return_type: Maybe(^TSTypeAnnotation), is_ts_no_body, is_expr: bool) -> ^Statement {
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

// check_function_name_strict_retro enforces the retroactive §12.6.1.1 /
// §15.7.1 strict-mode function-name reservations (eval / arguments +
// strict-reserved word) for the case where the body promoted to strict via
// a "use strict" directive while the outer scope was sloppy. Emit-only leaf;
// control flow stays in parse_function_declaration.
check_function_name_strict_retro :: proc(p: ^Parser, id: Maybe(BindingIdentifier), body_strict, strict_for_check, async: bool) {
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
}

// check_ts_function_signature_params enforces the TS parameter-property /
// optional-destructuring rules that distinguish overload / ambient
// signatures (no body) from implementation signatures. Emit-only leaf;
// control flow stays in parse_function_declaration.
check_ts_function_signature_params :: proc(p: ^Parser, params: []FunctionParameter, is_ts_no_body: bool) {
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
}

// parse_function_decl_name parses the optional BindingIdentifier of a
// FunctionDeclaration / FunctionExpression and enforces the §15.x name
// reservation early errors (await / yield / enum / strict-reserved). Returns
// the parsed name, or nil for an anonymous function expression. Pure leaf:
// control flow stays in parse_function_declaration.
parse_function_decl_name :: proc(p: ^Parser, is_expr, async, generator: bool) -> Maybe(BindingIdentifier) {
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
			check_function_name_reservations(p, &current, is_expr, async, generator)
			eat(p)
		} else if !is_expr {
			report_error_coded(p, .K2070_RequiredFormOrBinding, "Function declaration requires a name")
		}
	}
	return id
}

// check_function_name_reservations enforces the §15.x BindingIdentifier
// reservation early errors for a function name token (await / yield / enum /
// strict-reserved). Emit-only leaf; the name value + node are built by the
// caller. `current` is the snapped name token.
check_function_name_reservations :: proc(p: ^Parser, current: ^TokenSnap, is_expr, async, generator: bool) {
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
		check_function_decl_name_context(p, current)
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
}

// check_function_decl_name_context enforces the declaration-context
// (§12.6.1.1) `await` / `yield` BindingIdentifier reservations for a
// FunctionDeclaration name. Split out of check_function_name_reservations
// to keep both helpers under the 70-line limit. Emit-only leaf.
check_function_decl_name_context :: proc(p: ^Parser, current: ^TokenSnap) {
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

parse_function_param_decorators :: proc(p: ^Parser, param: ^FunctionParameter) -> bool {
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
	return decorators_seen
}

parse_function_param_ts_modifiers :: proc(p: ^Parser, param: ^FunctionParameter) {
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
}

parse_function_param_rest :: proc(p: ^Parser, param: ^FunctionParameter) -> ^FunctionParameter {
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
	return nil
}

parse_function_param_type_annotation :: proc(p: ^Parser, pattern: Pattern) {
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
}

parse_function_param :: proc(p: ^Parser) -> ^FunctionParameter {
	param := new_node(p, FunctionParameter)
	param.loc = cur_loc(p)

	decorators_seen := parse_function_param_decorators(p, param)

	// TS "parameter properties" on constructors: access/readonly/override
	// modifiers before the binding. Save them on the FunctionParameter so
	// the emitter can wrap the param in TSParameterProperty when set.
	parse_function_param_ts_modifiers(p, param)

	if r := parse_function_param_rest(p, param); r != nil {
		return r
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

	parse_function_param_type_annotation(p, pattern)

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

FnBodyContextSave :: struct {
	in_function:  bool,
	in_non_arrow: bool,
	in_generator: bool,
	in_async:     bool,
	strict:       bool,
	label_floor:  int,
	no_in:        bool,
	static_block: bool,
	field_init:   bool,
	in_loop:      bool,
	in_switch:    bool,
}

fn_body_enter_context :: proc(p: ^Parser) -> FnBodyContextSave {
	saved := FnBodyContextSave{
		in_function  = p.ctx.in_function,
		in_non_arrow = p.ctx.in_non_arrow_function,
		in_generator = p.ctx.in_generator,
		in_async     = p.ctx.in_async,
		strict       = p.ctx.strict_mode,
		label_floor  = p.ctx.label_floor,
		no_in        = p.ctx.no_in,
		static_block = p.ctx.in_static_block,
		field_init   = p.ctx.in_field_init,
		in_loop      = p.ctx.in_loop,
		in_switch    = p.ctx.in_switch,
	}
	p.ctx.label_floor           = len(p.label_stack)
	p.ctx.no_in                 = false
	p.ctx.in_static_block       = false
	p.ctx.in_field_init         = false
	p.ctx.in_loop               = false
	p.ctx.in_switch             = false
	p.ctx.in_function           = true
	p.ctx.in_non_arrow_function = true
	return saved
}

fn_body_exit_context :: proc(p: ^Parser, saved: FnBodyContextSave) {
	p.ctx.in_function           = saved.in_function
	p.ctx.in_non_arrow_function = saved.in_non_arrow
	p.ctx.in_generator          = saved.in_generator
	p.ctx.in_async              = saved.in_async
	p.ctx.strict_mode           = saved.strict
	p.ctx.no_in                 = saved.no_in
	p.ctx.in_static_block       = saved.static_block
	p.ctx.in_field_init         = saved.field_init
	p.ctx.in_loop               = saved.in_loop
	p.ctx.in_switch             = saved.in_switch
	resize(&p.label_stack, p.ctx.label_floor)
	p.ctx.label_floor = saved.label_floor
}

fn_body_parse_statements :: proc(p: ^Parser, body: ^FunctionBody) -> (bool, [dynamic]^StringLiteral) {
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
	return body_use_strict, prologue_raws
}

fn_body_check_strict_escapes :: proc(p: ^Parser, body_use_strict: bool, prologue_raws: [dynamic]^StringLiteral) {
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

	saved := fn_body_enter_context(p)

	body_use_strict, prologue_raws := fn_body_parse_statements(p, &body)

	fn_body_check_strict_escapes(p, body_use_strict, prologue_raws)

	fn_body_exit_context(p, saved)
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

parse_class_name :: proc(p: ^Parser) -> Maybe(BindingIdentifier) {
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
	return id
}

parse_class_extends :: proc(p: ^Parser) -> (Maybe(^Expression), Maybe(^TSTypeParameterInstantiation)) {
	super_class: Maybe(^Expression)
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
	return super_class, super_type_arguments
}

parse_class_implements :: proc(p: ^Parser) -> [dynamic]TSInterfaceHeritage {
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
	return implements_list
}

parse_class_declaration :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	eat(p) // consume class

	id := parse_class_name(p)

	// TypeScript generic type parameters: `class Box<T> { ... }`
	type_parameters: Maybe(^TSTypeParameterDeclaration)
	if is_token(p, .LAngle) && allow_ts_mode(p) { type_parameters = parse_ts_type_parameters(p) }

	// §15.7 - ClassDeclaration / ClassExpression are always strict mode code.
	// Set strict mode before parsing the heritage expression so that
	// `class C extends (function() { with({}); })()` correctly rejects
	// the `with` statement inside the heritage function expression.
	prev_strict_class := p.ctx.strict_mode
	p.ctx.strict_mode = true
	defer p.ctx.strict_mode = prev_strict_class
	super_class, super_type_arguments := parse_class_extends(p)

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

	implements_list := parse_class_implements(p)

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
	if ts_overload_prepass_skip(body) { return }
	ts_overload_main_pass(p, body)
}

// ts_overload_prepass_skip returns true when the class body is a valid pure-
// signature / overload pattern (no implementation, single name or a modified /
// multi-sig overload set with consistent static-ness) that the main pass must
// not flag as a missing implementation.
ts_overload_prepass_skip :: proc(body: []ClassElement) -> bool {
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
		if name_count == 0 { return true }
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
		if (sig_count > 1 || has_modifier) && !has_static_mismatch { return true }
		// Single sig, single name, no modifiers, no body = missing implementation.
		// Fall through to main pass which will report it.
	}
	return false
}

// ts_overload_main_pass walks the class body tracking each consecutive
// same-name overload-signature chain and reports a missing or mis-named
// implementation when the chain ends without a matching method body.
// ts_overload_elem_fn returns the method's FunctionExpression, or is_field=true
// when the element is a class field / non-method (which breaks an overload chain).
ts_overload_elem_fn :: proc(elem: ClassElement) -> (fn: ^FunctionExpression, is_field: bool) {
	val, have := elem.value.?
	is_field = !have || val == nil
	if !is_field {
		ok: bool
		fn, ok = val^.(^FunctionExpression)
		if !ok || fn == nil { is_field = true }
	}
	return
}

// ts_overload_elem_name returns the method's property name (computed string-literal
// keys included), or has_name=false when the element has no static name.
ts_overload_elem_name :: proc(elem: ClassElement) -> (name: string, has_name: bool) {
	if elem.key != nil {
		if elem.computed {
			if sl, is_sl := elem.key^.(^StringLiteral); is_sl {
				name = sl.value; has_name = true
			}
		} else {
			n := class_element_prop_name(elem.key)
			if n != "" { name = n; has_name = true }
		}
	}
	return
}

ts_overload_main_pass :: proc(p: ^Parser, body: []ClassElement) {
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
		fn, is_field := ts_overload_elem_fn(elem)
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

		name, has_name := ts_overload_elem_name(elem)
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

	report_ts_fn_overload_chain(p, body)
	check_ts_fn_overload_ambient(p, body)
	check_ts_fn_duplicate_impl(p, body)
}

// report_ts_fn_overload_chain walks the statement list tracking each consecutive
// same-name FunctionDeclaration overload-signature chain and reports a missing /
// mis-named implementation (TS2389 / "implementation is missing").
report_ts_fn_overload_chain :: proc(p: ^Parser, body: []^Statement) {
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
}

// check_ts_fn_overload_ambient enforces TS2384: all overload signatures sharing a
// name must be uniformly ambient (declare) or non-ambient.
check_ts_fn_overload_ambient :: proc(p: ^Parser, body: []^Statement) {
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

// check_ts_fn_duplicate_impl enforces TS2393: two or more same-named
// FunctionDeclarations with a body in the same scope are each flagged.
check_ts_fn_duplicate_impl :: proc(p: ^Parser, body: []^Statement) {
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

// parse_class_accessor_keyword — `accessor` (Stage-3 decorators auto-accessor)
// is contextual: it is the modifier only when the NEXT token can start a class
// element name AND no LineTerminator intervenes. Otherwise it is a plain member
// name (`accessor = 42;`, `accessor() {}`, ASI-style `accessor\n a;`). The
// exclusion list mirrors the Stage-3 grammar production. Consumes the keyword
// and returns true when it acts as the modifier.
// Test262 staging/decorators/accessor-as-identifier.js.
parse_class_accessor_keyword :: proc(p: ^Parser) -> bool {
	if !is_token(p, .Accessor) { return false }
	next := peek_token(p)
	next_starts_name := next.type != .LParen && next.type != .Semi &&
	                    next.type != .RBrace && next.type != .Assign &&
	                    next.type != .Comma
	// peek_token returns the next non-whitespace token; its had_line_terminator
	// flag reflects whether a LT crossed BEFORE it, which is exactly the ASI
	// condition between `accessor` and the next token.
	if next_starts_name && !next.had_line_terminator {
		eat(p)
		return true
	}
	return false
}

// parse_class_async_keyword — `async` is the method modifier only when followed
// by something that starts a method name with no intervening LineTerminator.
// When `async` is followed by `(` or `<` it IS the method name (`async() {}`,
// `async<T>() {}`). Consumes the keyword and returns true when it modifies.
parse_class_async_keyword :: proc(p: ^Parser) -> bool {
	if !is_token(p, .Async) { return false }
	next := peek_token(p)
	looks_like_async_method := next.type == .Identifier || next.type == .PrivateIdentifier ||
		next.type == .LBracket || next.type == .String || next.type == .Number ||
		next.type == .BigInt || next.type == .Mul ||
		is_keyword_usable_as_property_name(next.type)
	if looks_like_async_method && !next.had_line_terminator {
		eat(p) // consume async
		return true
	}
	return false
}

// parse_class_get_set_keyword — `get` / `set` are contextual keywords, valid as
// plain class-member names too. The accessor promotion fires only when the next
// token can begin a property name (identifier, string, computed-name `[`,
// generator `*`, or any keyword usable as a property name). Tokens like `=`
// (field init), `:` (TS type annotation), `?` (TS optional field), `,` `;` `(`
// `}` keep `get` / `set` as the field name (`public get = function() {}`,
// `set: boolean;`). On promotion, consumes the keyword and returns (.Get/.Set,
// true); the `async get` combination is rejected here.
parse_class_get_set_keyword :: proc(p: ^Parser, is_async: bool) -> (ClassElementKind, bool) {
	if !is_token(p, .Get) && !is_token(p, .Set) { return .Method, false }
	is_getter := is_token(p, .Get)
	next := peek_token(p)
	looks_like_accessor_name := next.type == .Identifier || next.type == .String ||
		next.type == .Number || next.type == .BigInt || next.type == .LBracket ||
		next.type == .Mul || next.type == .PrivateIdentifier ||
		is_keyword_usable_as_property_name(next.type)
	if !looks_like_accessor_name { return .Method, false }
	kind := ClassElementKind.Set
	if is_getter { kind = .Get }
	if is_async {
		report_error_coded(p, .K3012_AsyncGeneratorMisplaced,
			"'async' modifier cannot be used here")
	}
	eat(p) // consume get/set keyword
	return kind, true
}

// parse_class_field_optional_definite consumes a TS class-field shape
// modifier that follows the member name: `?` (optional) or `!` (definite
// assignment assertion). Both are look-ahead gated — the token is only a
// field modifier when the FOLLOWING token is one that legally terminates
// or continues a class field/method head; otherwise it belongs to the
// next construct and is left on the cursor. Returns which modifier, if any,
// was consumed. Pure leaf: only advances the cursor across the `?` / `!`.
parse_class_field_optional_definite :: proc(p: ^Parser) -> (field_optional: bool, field_definite: bool) {
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
	return
}

// parse_class_field_initializer parses the `= <expr>` initializer of a class
// field, when present, and returns it (nil for a bare field declaration). The
// caller has already determined this element is a field, not a method.
// §15.7.10 ClassFieldDefinitionEvaluation: the initializer is the body of a
// SYNTHETIC non-async, non-generator function whose [[HomeObject]] is the
// class — so `super.x` is legal here but `super(...)` is not, and `await` /
// `yield` are NOT treated specially. This helper owns the whole parse-context
// save / parse / restore dance; control flow stays in the parent.
parse_class_field_initializer :: proc(p: ^Parser, is_declare, is_readonly, is_abstract: bool) -> Maybe(^Expression) {
	if !match_token(p, .Assign) {
		return nil
	}
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
	if init_expr == nil {
		return nil
	}
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
	return init_expr
}

// ClassElementName carries the result of parsing a class member's key:
// the key expression, the (possibly constructor-promoted) element kind, and
// whether the key was computed. drop=true means the element should be swallowed
// without materialising a node (a TS class index signature or a malformed
// computed key) — the caller returns nil.
ClassElementName :: struct {
	key:      ^Expression,
	kind:     ClassElementKind,
	computed: bool,
	drop:     bool,
}

// parse_class_element_name parses a class member's key — the private / string /
// numeric / bigint / identifier / computed-key dispatch — promoting `kind` to
// .Constructor where the name warrants it and enforcing the §15.7.6 constructor
// shape rules that are visible while the original modifiers and literal name are
// still in hand. Control flow (the field/method split) stays in the caller.
parse_class_element_name :: proc(
	p: ^Parser,
	kind_in: ClassElementKind,
	static_, is_async, is_generator: bool,
	accessibility: ClassAccessibility,
	access_name: string,
) -> ClassElementName {
	if is_token(p, .PrivateIdentifier) {
		return parse_class_name_private(p, kind_in, accessibility)
	} else if is_token(p, .String) {
		return parse_class_name_string(p, kind_in, is_async, is_generator, static_)
	} else if is_token(p, .Number) {
		return parse_class_name_number(p, kind_in)
	} else if is_token(p, .BigInt) {
		return parse_class_name_bigint(p, kind_in)
	} else if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
		return parse_class_name_identifier(p, kind_in, is_async, is_generator, static_)
	} else if is_token(p, .LBracket) {
		return parse_class_name_computed(p, kind_in, accessibility, access_name)
	}
	report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected method or property name")
	return ClassElementName{drop = true}
}

// parse_class_name_private builds the key for a private (#) class member name,
// rejecting an accessibility modifier on it.
parse_class_name_private :: proc(p: ^Parser, kind: ClassElementKind, accessibility: ClassAccessibility) -> ClassElementName {
	key: ^Expression
	// Private field or method: #field, #method
	current := snap_current(p)
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
	return ClassElementName{key = key, kind = kind, computed = false}
}

// parse_class_name_string builds a StringLiteral-keyed class member name and
// applies the string-"constructor" promotion + §15.7.6 shape checks.
parse_class_name_string :: proc(p: ^Parser, kind_in: ClassElementKind, is_async, is_generator, static_: bool) -> ClassElementName {
	kind := kind_in
	key: ^Expression
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
	return ClassElementName{key = key, kind = kind, computed = false}
}

// parse_class_name_number builds a NumericLiteral-keyed class member name.
parse_class_name_number :: proc(p: ^Parser, kind: ClassElementKind) -> ClassElementName {
	key: ^Expression
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
	return ClassElementName{key = key, kind = kind, computed = false}
}

// parse_class_name_bigint builds a BigIntLiteral-keyed class member name (§13.2.3).
parse_class_name_bigint :: proc(p: ^Parser, kind: ClassElementKind) -> ClassElementName {
	key: ^Expression
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
	return ClassElementName{key = key, kind = kind, computed = false}
}

// parse_class_name_identifier builds an Identifier-keyed class member name and
// applies the identifier-"constructor" promotion + §15.7.6 shape checks.
parse_class_name_identifier :: proc(p: ^Parser, kind_in: ClassElementKind, is_async, is_generator, static_: bool) -> ClassElementName {
	kind := kind_in
	key: ^Expression
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
	if !static_ &&
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
	return ClassElementName{key = key, kind = kind, computed = false}
}

// parse_class_name_computed builds a computed `[expr]` class member name (or
// drops a TS class index signature), rejecting an array-literal computed key.
parse_class_name_computed :: proc(p: ^Parser, kind: ClassElementKind, accessibility: ClassAccessibility, access_name: string) -> ClassElementName {
	key: ^Expression
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
		return ClassElementName{drop = true}
	}
	// Computed property: [expr]
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
		return ClassElementName{drop = true}
	}
	return ClassElementName{key = key, kind = kind, computed = true}
}

// Captured inputs for parse_class_field_element, gathered by the parent before
// the field-vs-method split so the helper only constructs the FieldDefinition
// node and does not touch control flow.
ClassFieldParts :: struct {
	start:           Loc,
	key:             ^Expression,
	type_annotation: Maybe(^TSTypeAnnotation),
	decorators:      [dynamic]Decorator,
	kind:            ClassElementKind,
	accessibility:   ClassAccessibility,
	computed:        bool,
	static_:         bool,
	is_accessor:     bool,
	is_abstract:     bool,
	is_declare:      bool,
	is_readonly:     bool,
	is_override:     bool,
	optional:        bool,
	definite:        bool,
}

// parse_class_field_element finishes a FieldDefinition ClassElement once the
// parent has decided this element is a field (not a method): it parses the
// optional `= <initializer>` (§15.7.10 synthetic function scope), enforces the
// §15.7.1 constructor-name + trailing-semicolon early errors, and builds the
// node. The field-vs-method dispatch stays in parse_class_element.
parse_class_field_element :: proc(p: ^Parser, parts: ClassFieldParts) -> ^ClassElement {
	// Class field with initializer or just declaration. The initializer
	// (if any) parses in a synthetic non-async / non-generator function
	// scope per §15.7.10; the helper owns that context dance.
	value := parse_class_field_initializer(p, parts.is_declare, parts.is_readonly, parts.is_abstract)

	// §15.7.1 ClassElement - a non-computed FieldDefinition (with or
	// without an initializer) cannot be named "constructor". The
	// non-computed restriction matches the spec: `class { ['constructor'
	// ] = 1 }` is allowed because the key is computed.
	// OXC's parser skips this check for StringLiteral-keyed fields
	// with an access modifier — `public "constructor" = 0;` is
	// accepted, deferred to the type checker.  Identifier-keyed
	// `public constructor;` is still caught.
	if !parts.computed {
		is_string_key := false
		if parts.key != nil {
			if _, ok := parts.key^.(^StringLiteral); ok { is_string_key = true }
		}
		skip := is_string_key && parts.accessibility != .None
		if !skip {
			name := class_element_prop_name(parts.key)
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
	elem.loc = parts.start
	elem.key = parts.key
	elem.value = value
	elem.kind = parts.kind  // Still .Method but value is not a function
	// Use the parsed `computed` flag so `static [propname]` fields
	// emit with computed=true - the §15.7.1 "static prototype" check
	// gates on !elem.computed, so the previous hardcoded `false` made
	// `class { static ['prototype'] = 42 }` falsely error.
	elem.computed = parts.computed
	elem.static = parts.static_
	elem.is_accessor = parts.is_accessor
	elem.abstract = parts.is_abstract
	elem.decorators = parts.decorators
	elem.type_annotation = parts.type_annotation
	elem.optional = parts.optional
	if parts.is_accessor && parts.optional {
		report_error_coded(p, .K4032_ModifierMisplaced, "An 'accessor' property cannot be declared optional")
	}
	elem.definite = parts.definite
	elem.accessibility = parts.accessibility
	elem.readonly = parts.is_readonly
	elem.override_ = parts.is_override

	elem.loc.end = prev_end_offset(p)
	return elem
}

// §15.4 / TS — shape rules for a class method after its signature is
// parsed: type parameters, return type, and `declare` placement. The
// constructor block is unguarded because its inputs (type parameters /
// return type / `declare`) are only ever populated in TS mode; the
// accessor block is TS-only.
check_ts_method_modifiers :: proc(
	p: ^Parser,
	kind: ClassElementKind,
	is_declare: bool,
	method_type_parameters: Maybe(^TSTypeParameterDeclaration),
	method_return_type: Maybe(^TSTypeAnnotation),
) {
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
}

// TS — a class method's parameter list may carry parameter-property
// modifiers (`public` / `private` / `readonly` / ...) only on the
// implementation constructor, and only on a plain identifier binding.
check_param_property_modifiers :: proc(p: ^Parser, kind: ClassElementKind, params: []FunctionParameter) {
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

// TS2371 — a method with no implementation body (overload signature or
// ambient method) may not carry parameter initializers or
// parameter-property modifiers.
check_no_body_param_properties :: proc(p: ^Parser, params: []FunctionParameter) {
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

// parse_class_method_params parses a class method's formal parameter list
// under the class-method context. Class bodies are implicitly strict
// (§15.7.3), so parameters parse with strict_mode = true; the generator /
// async param guards (§15.5.1 / §15.6.1 / §15.8.1) and the derived-
// constructor super-call eligibility are set for the parameter scope and
// restored on exit so they do not leak into the surrounding class body.
// `start_offset` is the element start used for the duplicate-parameter span.
parse_class_method_params :: proc(p: ^Parser, kind: ClassElementKind, static_, is_async, is_generator: bool, start_offset: u32) -> [dynamic]FunctionParameter {
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
		check_param_property_modifiers(p, kind, params[:])
	}
	p.ctx.in_method = prev_method_in_method
	p.ctx.strict_mode = prev_strict_params
	p.ctx.in_generator_params = prev_method_gen_params
	p.ctx.in_async_params = prev_method_async_params
	p.ctx.in_static_block = prev_static_block_mparams
	// §15.5.1 / §15.6.1 — class methods are always strict.
	parser_check_dup_params(p, params[:], start_offset, true, false)
	return params
}

// Parse a class method body under the class-method context. The flags below
// (always-strict, in_method, generator/async param guards, derived-constructor
// super-call eligibility per ECMA-262 §15.7.3) are saved on entry and restored
// on exit so they do not leak into the surrounding class body. Pure leaf:
// control flow (the abstract / overload / ambient body-vs-no-body dispatch)
// stays in parse_class_element.
parse_class_method_body :: proc(p: ^Parser, kind: ClassElementKind, static_, is_async, is_generator: bool) -> FunctionBody {
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

	body := parse_function_body(p)

	p.ctx.in_function = prev_in_function
	p.ctx.in_generator = prev_in_generator
	p.ctx.in_async = prev_in_async
	p.ctx.in_method = prev_in_method
	p.ctx.strict_mode = prev_strict
	p.ctx.in_derived_constructor = prev_in_derived_ctor
	return body
}

// ClassMethodParts carries the modifier/name decisions parse_class_element has
// already resolved into parse_class_method_element, which finishes a
// MethodDefinition ClassElement: type parameters, formal parameters, return
// type, the §15.4 body-vs-overload-signature decision, and node construction.
// The field-vs-method dispatch stays in parse_class_element.
ClassMethodParts :: struct {
	start:         Loc,
	key:           ^Expression,
	decorators:    [dynamic]Decorator,
	kind:          ClassElementKind,
	accessibility: ClassAccessibility,
	computed:      bool,
	static_:       bool,
	is_async:      bool,
	is_generator:  bool,
	is_accessor:   bool,
	is_abstract:   bool,
	is_declare:    bool,
	is_readonly:   bool,
	is_override:   bool,
	optional:      bool,
}

// parse_class_method_body_decision resolves the §15.4 body-vs-overload /
// ambient-method decision once parse_class_method_element has parsed the
// method header. It parses the implementation body (or leaves it empty for an
// overload signature / abstract / ambient method) and reports the associated
// early errors. Returns the body plus the two flags the caller folds into
// FunctionExpression.no_body.
parse_class_method_body_decision :: proc(
	p: ^Parser,
	kind: ClassElementKind,
	key: ^Expression,
	params: [dynamic]FunctionParameter,
	paren_loc: Loc,
	decorators: [dynamic]Decorator,
	static_, is_async, is_generator, is_abstract: bool,
) -> (body: FunctionBody, is_overload_sig: bool, is_ambient_method: bool) {
	// TS-mode ambient method: no `{` body. Three ways to identify it:
	//   1. explicit `;` terminator        (overload signature, declare class)
	//   2. ASI: line-terminator before next class element start (.d.ts files)
	//   3. immediately followed by `}` - last method in declare class.
	// Each branch leaves `body` empty. Test ts-conformance:
	//   bench/node_modules/oxc-parser/src-js/index.d.ts
	//     class ParseResult { get program(): T  /* no semi */
	//                         get module(): U
	//                       }
	is_overload_sig = allow_ts_mode(p) && is_token(p, .Semi)
	is_ambient_method = allow_ts_mode(p) && !is_token(p, .LBrace) &&
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
		// Parse the method body under the class-method context. The
		// §15.7.3 flags (always-strict, in_method, generator/async param
		// guards, derived-constructor super-call eligibility) are saved on
		// entry and restored on exit by the helper so they do not leak into
		// the surrounding class body.
		body = parse_class_method_body(p, kind, static_, is_async, is_generator)

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
	return body, is_overload_sig, is_ambient_method
}

parse_method_type_parameters :: proc(p: ^Parser) -> Maybe(^TSTypeParameterDeclaration) {
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
	return method_type_parameters
}

check_method_accessor_shape :: proc(p: ^Parser, kind: ClassElementKind, key: ^Expression, params: [dynamic]FunctionParameter, start: Loc) {
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
}

build_class_method_element :: proc(p: ^Parser, parts: ClassMethodParts, params: [dynamic]FunctionParameter, body: FunctionBody, paren_loc: Loc, method_type_parameters: Maybe(^TSTypeParameterDeclaration), method_return_type: Maybe(^TSTypeAnnotation), is_overload_sig: bool, is_ambient_method: bool) -> ^ClassElement {
	start := parts.start
	key := parts.key
	kind := parts.kind
	computed := parts.computed
	static_ := parts.static_
	is_async := parts.is_async
	is_generator := parts.is_generator
	is_accessor := parts.is_accessor
	is_abstract := parts.is_abstract
	decorators := parts.decorators
	accessibility := parts.accessibility
	is_readonly := parts.is_readonly
	is_override := parts.is_override
	field_optional := parts.optional
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
		check_no_body_param_properties(p, params[:])
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

parse_class_method_element :: proc(p: ^Parser, parts: ClassMethodParts) -> ^ClassElement {
	start := parts.start
	key := parts.key
	kind := parts.kind
	static_ := parts.static_
	is_async := parts.is_async
	is_generator := parts.is_generator
	is_abstract := parts.is_abstract
	is_declare := parts.is_declare
	is_readonly := parts.is_readonly
	is_override := parts.is_override
	decorators := parts.decorators

	method_type_parameters := parse_method_type_parameters(p)

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

	// Parse the method's formal parameter list under the class-method
	// context (always strict; in_method; generator/async param guards;
	// derived-constructor super-call eligibility). The §15.5.1/§15.6.1/
	// §15.8.1 flags are saved on entry and restored on exit by the helper
	// so they do not leak into the surrounding class body.
	params := parse_class_method_params(p, kind, static_, is_async, is_generator, start.start)

	if !expect_token(p, .RParen) {
		return nil
	}

	check_method_accessor_shape(p, kind, key, params, start)

	// TypeScript return type annotation on method - stored on FunctionExpression.
	method_return_type: Maybe(^TSTypeAnnotation)
	if is_token(p, .Colon) && allow_ts_mode(p) {
		method_return_type = parse_ts_return_type_annotation(p)
	}
	check_ts_method_modifiers(p, kind, is_declare, method_type_parameters, method_return_type)

	// For abstract methods and for TS overload signatures there's no body
	// - just a semicolon. Overload signature (TS-A10):
	//   class C {
	//     get(x: string): string;
	//     get(x: number): number;
	//     get(x: any): any { return x; }
	//   }
	// The parser tolerates the syntax; semantics (overload set shape,
	// implementation agreement) are the type checker's job.
	body, is_overload_sig, is_ambient_method := parse_class_method_body_decision(
		p, kind, key, params, paren_loc, decorators, static_, is_async, is_generator, is_abstract,
	)

	return build_class_method_element(p, parts, params, body, paren_loc, method_type_parameters, method_return_type, is_overload_sig, is_ambient_method)
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
	is_accessor := false

	// Contextual modifier keywords (`accessor`, `async`, `get` / `set`).
	// Each helper decides whether the keyword acts as a modifier here (vs.
	// being a plain member name) and consumes it when it does. Control flow
	// stays in this parent: the helpers only report their decision.
	is_accessor = parse_class_accessor_keyword(p)
	if !is_accessor && parse_class_async_keyword(p) {
		is_async = true
	}
	if k, ok := parse_class_get_set_keyword(p, is_async); ok {
		kind = k
	}

	// Check for generator method: *name()
	if !is_generator && is_token(p, .Mul) {
		is_generator = true
		eat(p) // consume *
	}

	// Parse method/property name (private / literal / identifier / computed).
	name_res := parse_class_element_name(p, kind, static_, is_async, is_generator, accessibility, access_name)
	if name_res.drop {
		return nil
	}
	key := name_res.key
	kind = name_res.kind
	computed = name_res.computed

	// (The generator `*` is parsed BEFORE the name above, around line
	// 4354. There's no `name *` form in JS / TS - a stray `*` here
	// belongs to the next class element, e.g. ASI-split
	// `async\n *foo() {}` where `async` is a bare field and `*foo` is a
	// generator method. Removing the post-name `*` consumption closes
	// the babel "async\n *a(){}" no-asi fixture.)

	// TS class field modifiers: `foo?:` (optional) or `foo!:` (definite
	// assignment). These appear BEFORE the `:` type annotation and coexist
	// with it. Detection (the `?` / `!` look-ahead + conditional consume)
	// lives in a leaf helper; control flow stays here.
	field_optional, field_definite := parse_class_field_optional_definite(p)

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
		return parse_class_field_element(p, ClassFieldParts{
			start           = start,
			key             = key,
			type_annotation = field_type_ann,
			decorators      = decorators,
			kind            = kind,
			accessibility   = accessibility,
			computed        = computed,
			static_         = static_,
			is_accessor     = is_accessor,
			is_abstract     = is_abstract,
			is_declare      = is_declare,
			is_readonly     = is_readonly,
			is_override     = is_override,
			optional        = field_optional,
			definite        = field_definite,
		})
	}

	return parse_class_method_element(p, ClassMethodParts{
		start         = start,
		key           = key,
		decorators    = decorators,
		kind          = kind,
		accessibility = accessibility,
		computed      = computed,
		static_       = static_,
		is_async      = is_async,
		is_generator  = is_generator,
		is_accessor   = is_accessor,
		is_abstract   = is_abstract,
		is_declare    = is_declare,
		is_readonly   = is_readonly,
		is_override   = is_override,
		optional      = field_optional,
	})
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

check_var_decl_kind_placement :: proc(p: ^Parser, kind: VariableKind, in_for: bool) {
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
}

parse_var_decl_empty_recovery :: proc(p: ^Parser, decl: ^VariableDeclaration, kind: VariableKind, consume_semi: bool, in_for: bool) -> ^Statement {
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
	return nil
}

match_var_decl_terminator :: proc(p: ^Parser, consume_semi: bool) {
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
}

check_var_decl_bound_names :: proc(p: ^Parser, decl: ^VariableDeclaration, kind: VariableKind, is_declare: bool) {
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
}

check_var_decl_using_restrictions :: proc(p: ^Parser, decl: ^VariableDeclaration, kind: VariableKind, is_declare: bool) {
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
}

check_var_decl_initializers :: proc(p: ^Parser, decl: ^VariableDeclaration, kind: VariableKind, in_for: bool, is_declare: bool) {
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
}

parse_variable_declaration :: proc(p: ^Parser, kind_override: Maybe(VariableKind), consume_semi: bool, in_for := false, is_declare := false) -> ^Statement {
	start := cur_loc(p)

	kind, kind_ok := parse_var_decl_kind(p, kind_override)
	if !kind_ok {
		return nil
	}

	eat(p)

	check_var_decl_kind_placement(p, kind, in_for)

	decl := new_node(p, VariableDeclaration)
	decl.loc = start
	decl.kind = kind

	if s := parse_var_decl_empty_recovery(p, decl, kind, consume_semi, in_for); s != nil {
		return s
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

	match_var_decl_terminator(p, consume_semi)

	check_var_decl_bound_names(p, decl, kind, is_declare)

	check_var_decl_using_restrictions(p, decl, kind, is_declare)

	check_var_decl_initializers(p, decl, kind, in_for, is_declare)

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

try_binding_reserved_word :: proc(p: ^Parser) -> Pattern {
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
	return nil
}

try_binding_strict_reserved :: proc(p: ^Parser) -> Pattern {
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
	return nil
}

try_binding_generator_yield :: proc(p: ^Parser) -> Pattern {
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
	return nil
}

try_binding_await :: proc(p: ^Parser) -> Pattern {
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
	return nil
}

parse_binding_identifier :: proc(p: ^Parser) -> Pattern {
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
	return nil
}

parse_binding_pattern :: proc(p: ^Parser) -> Pattern {
	if is_token(p, .LBrace) {
		return parse_object_pattern(p)
	}

	if is_token(p, .LBracket) {
		return parse_array_pattern(p)
	}

	if pat := try_binding_reserved_word(p); pat != nil { return pat }

	if pat := try_binding_strict_reserved(p); pat != nil { return pat }

	if pat := try_binding_generator_yield(p); pat != nil { return pat }
	if pat := try_binding_await(p); pat != nil { return pat }

	if pat := parse_binding_identifier(p); pat != nil { return pat }

	report_error_coded(p, .K3043_DestructuringInvalid, "Expected binding pattern")
	return nil
}

// parse_object_pattern_key parses a single object-pattern property key
// (computed `[expr]`, string / numeric / bigint literal, or
// identifier / usable-keyword name) and reports the §12.7.2 escaped-
// reserved-word and §14.3.3 literal-key-needs-colon early errors. `ok`
// is false when the caller must abort the pattern (`return nil`).
parse_object_pattern_key :: proc(p: ^Parser) -> (key: Maybe(ObjectPatternPropertyKey), computed: bool, ok: bool) {
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
			return key, computed, false
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
		return key, computed, false
	}
	return key, computed, true
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

		// Rest element: ...identifier. Must be last in an object pattern.
		if match_token(p, .Dot3) {
			rest_prop, ok := parse_object_pattern_rest(p, prop_start)
			if !ok { return nil }
			bump_append(&obj.properties, rest_prop)
			if !is_token(p, .RBrace) {
				report_error_coded(p, .K3040_RestNotLast, "Rest element must be last in object pattern")
			}
			break
		}

		// Parse key
		key, computed, key_ok := parse_object_pattern_key(p)
		if !key_ok {
			return nil
		}

		// Dispatch on the property shape: `{ key: value }`, `{ key = default }`
		// shorthand-with-default, or the bare `{ key }` shorthand.
		if is_token(p, .Colon) {
			eat(p)
			prop, ok := parse_object_pattern_colon_value(p, prop_start, key, computed)
			if !ok { return nil }
			bump_append(&obj.properties, prop)
		} else if match_token(p, .Assign) {
			if prop, has := parse_object_pattern_shorthand_default(p, prop_start, key, computed); has {
				bump_append(&obj.properties, prop)
			}
		} else {
			if prop, has := parse_object_pattern_shorthand(p, prop_start, key); has {
				bump_append(&obj.properties, prop)
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

// parse_object_pattern_rest parses `...BindingIdentifier` after the parent has
// consumed the `...`. Returns (property, true) on success; reports and returns
// (_, false) on error. The rest-must-be-last check and break stay in the
// caller ("push ifs up").
parse_object_pattern_rest :: proc(p: ^Parser, prop_start: Loc) -> (ObjectPatternProperty, bool) {
	if !is_token(p, .Identifier) {
		report_error_coded(p, .K2021_ExpectedIdentifier, "Expected identifier after ... in object pattern")
		return {}, false
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

	return ObjectPatternProperty{
		loc       = prop_start,
		key       = nil,
		value     = rest,
		shorthand = false,
	}, true
}

// parse_object_pattern_colon_value parses the value pattern after `key:` (the
// `:` already consumed by the caller). Returns (property, true) on success;
// reports and returns (_, false) on a syntax error so the caller bails.
parse_object_pattern_colon_value :: proc(p: ^Parser, prop_start: Loc, key: Maybe(ObjectPatternPropertyKey), computed: bool) -> (ObjectPatternProperty, bool) {
	if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
		return parse_object_pattern_colon_ident(p, prop_start, key, computed), true
	} else if is_token(p, .LBrace) {
		nested := parse_object_pattern(p)
		if nested == nil { return {}, false }
		val := parse_binding_pattern_nested_default(p, nested)
		prop := ObjectPatternProperty{
			loc       = prop_start,
			key       = key,
			value     = val,
			computed  = computed,
			shorthand = false,
		}
		prop.loc.end = prev_end_offset(p)
		return prop, true
	} else if is_token(p, .LBracket) {
		nested := parse_array_pattern(p)
		if nested == nil { return {}, false }
		val := parse_binding_pattern_nested_default(p, nested)
		prop := ObjectPatternProperty{
			loc       = prop_start,
			key       = key,
			value     = val,
			computed  = computed,
			shorthand = false,
		}
		prop.loc.end = prev_end_offset(p)
		return prop, true
	}
	report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected pattern in object pattern value")
	return {}, false
}

// parse_object_pattern_colon_ident parses an identifier value binding after
// `key:` with its reserved-word / strict-mode early-error checks and an
// optional `= default`. Always succeeds (errors are reported, not fatal):
// returns either a plain Identifier value or an AssignmentPattern.
parse_object_pattern_colon_ident :: proc(p: ^Parser, prop_start: Loc, key: Maybe(ObjectPatternPropertyKey), computed: bool) -> ObjectPatternProperty {
	// Reserved words cannot appear as binding targets in destructuring
	// patterns: `{ p: void }`, `{ p: null }` etc.
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

	// Check for default value: { key: value = defaultValue }. Restore
	// no_in=false inside the default so `for (let {x = 'a' in {}} in ...)`
	// parses the `in` as a binary op, not the for-in separator.
	if match_token(p, .Assign) {
		prev_no_in := p.ctx.no_in; p.ctx.no_in = false
		default_val := parse_assignment_expression(p)
		p.ctx.no_in = prev_no_in
		assign := new_node(p, AssignmentPattern)
		// AssignmentPattern.start is the start of the LHS pattern, NOT the
		// enclosing property key: OXC / ESTree emit [value_start, default_end].
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
		return prop
	}
	prop := ObjectPatternProperty{
		loc       = prop_start,
		key       = key,
		value     = value_ident,
		computed  = computed,
		shorthand = false,
	}
	prop.loc.end = value_ident.loc.end
	return prop
}

// parse_object_pattern_shorthand_default parses `{ key = default }` after the
// caller consumed `=`. Returns (property, true) when key is a binding
// identifier; (_, false) when it is not, in which case the property is
// silently dropped (the permissive parser defers the diagnostic to the
// checker).
parse_object_pattern_shorthand_default :: proc(p: ^Parser, prop_start: Loc, key: Maybe(ObjectPatternPropertyKey), computed: bool) -> (ObjectPatternProperty, bool) {
	prev_no_in := p.ctx.no_in; p.ctx.no_in = false
	default_val := parse_assignment_expression(p)
	p.ctx.no_in = prev_no_in
	k := key
	if k == nil { return {}, false }
	val := k.?
	v, is_ident := val.(IdentifierName)
	if !is_ident { return {}, false }
	// §13.2.5.1 / §12.6.1.1 - a shorthand key in an object pattern doubles
	// as a BindingIdentifier; reserved keywords (`default`, `class`, ...)
	// are not legal binding names.
	if is_always_reserved_word_name(v.name) {
		msg := fmt.tprintf("Reserved word '%s' is not a valid binding identifier", v.name)
		report_error_coded(p, .K3053_ReservedAsBindingIdentifier, msg)
	}
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
	// Shorthand: the key IS the LHS; spell the span out through left_ident.loc
	// to stay consistent with the other AssignmentPattern sites here.
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
	return prop, true
}

// parse_object_pattern_shorthand parses the bare `{ key }` shorthand (no `:`
// or `=`). Returns (property, true) when key is a binding identifier; (_,
// false) otherwise (silently dropped — the permissive parser defers the
// diagnostic to the checker).
parse_object_pattern_shorthand :: proc(p: ^Parser, prop_start: Loc, key: Maybe(ObjectPatternPropertyKey)) -> (ObjectPatternProperty, bool) {
	k := key
	if k == nil { return {}, false }
	val := k.?
	v, is_ident := val.(IdentifierName)
	if !is_ident { return {}, false }
	// Shorthand binding name must be a valid BindingIdentifier (§13.2.5.1).
	if is_always_reserved_word_name(v.name) {
		msg := fmt.tprintf("Reserved word '%s' is not a valid binding identifier", v.name)
		report_error_coded(p, .K3053_ReservedAsBindingIdentifier, msg)
	}
	if p.ctx.strict_mode && !(allow_ts_mode(p) && (p.ctx.in_ambient || p.source_is_dts)) {
		if is_strict_reserved_binding_name(v.name) {
			msg := fmt.tprintf("'%s' is a reserved identifier in strict mode", v.name)
			report_error_coded_span(p, .K3050_StrictModeReserved, u32(v.loc.start), u32(v.loc.start), msg)
		}
	}
	// `yield` is reserved in generator bodies; `await` in async / module.
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
	return prop, true
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

		// Rest element (§14.3.3). Must be last; takes no Initializer.
		if is_token(p, .Dot3) {
			rest, ok := parse_array_pattern_rest(p)
			if !ok { return nil }
			bump_append(&elements, Maybe(Pattern)(rest))
			// Rest element must be last - and cannot take an Initializer
			// (§14.3.3: no `= default` on BindingRestElement).
			if !is_token(p, .RBracket) && !is_token(p, .EOF) {
				report_error_coded(p, .K3040_RestNotLast, "Rest element must be last in array pattern")
			}
			break
		}

		// Parse regular element.
		if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
			bump_append(&elements, Maybe(Pattern)(parse_array_pattern_ident_element(p)))
		} else if is_token(p, .LBrace) {
			nested := parse_object_pattern(p)
			if nested == nil { return nil }
			bump_append(&elements, Maybe(Pattern)(parse_binding_pattern_nested_default(p, nested)))
		} else if is_token(p, .LBracket) {
			nested := parse_array_pattern(p)
			if nested == nil { return nil }
			bump_append(&elements, Maybe(Pattern)(parse_binding_pattern_nested_default(p, nested)))
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

// parse_array_pattern_rest parses a `... BindingIdentifier | BindingPattern`
// rest element (§14.3.3). Returns (rest, true) on success; on a syntax error
// it reports and returns (nil, false) so the caller bails. The rest-not-last
// and break control flow stays in the caller ("push ifs up").
parse_array_pattern_rest :: proc(p: ^Parser) -> (Pattern, bool) {
	rest_start := cur_loc(p) // Capture location of ... before eating
	eat(p) // consume ...

	rest := new_node(p, RestElement)
	rest.loc = rest_start

	if is_token(p, .LBracket) {
		nested := parse_array_pattern(p)
		if nested == nil { return nil, false }
		rest.argument = nested
	} else if is_token(p, .LBrace) {
		nested := parse_object_pattern(p)
		if nested == nil { return nil, false }
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
		return nil, false
	}
	rest.loc.end = prev_end_offset(p)
	return rest, true
}

// parse_array_pattern_ident_element parses a single identifier binding element
// with its early-error checks and an optional `= default` Initializer. Returns
// either the bare Identifier or an AssignmentPattern wrapping it.
parse_array_pattern_ident_element :: proc(p: ^Parser) -> Pattern {
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
		return assign
	}
	return ident
}

// parse_binding_pattern_nested_default wraps an already-parsed nested object /
// array BindingPattern in an AssignmentPattern when an `= Initializer` follows
// (§14.3.3 BindingElement : BindingPattern Initializer_opt). Shared by both
// parse_array_pattern and parse_object_pattern so `[{x} = {x: 1}]` and
// `{a: {x} = {x: 1}}` parse identically.
parse_binding_pattern_nested_default :: proc(p: ^Parser, nested: Pattern) -> Pattern {
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
	return val
}


// for_in_of_check_expr_lhs validates an expression for-in/of LHS:
// the §14.7.5.1 AssignmentTargetType rule, the `async` / `let` LHS
// restrictions, TS2491, and the destructuring-pattern reinterpretation.
// Extracted from parse_for_in_of_tail; pure code motion.
for_in_of_check_expr_lhs :: proc(p: ^Parser, left_expr: ^Expression, is_in: bool, await: bool) {
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

// for_in_of_check_decl_lhs validates a declaration for-in/of LHS: the
// using-in-for-in restriction, TS2491 destructuring, the single-declarator /
// no-initializer (Annex B.3.5) rules, and the TS2404 type-annotation ban.
// Extracted from parse_for_in_of_tail; pure code motion.
for_in_of_check_decl_lhs :: proc(p: ^Parser, left_decl: ^VariableDeclaration, is_in: bool) {
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
