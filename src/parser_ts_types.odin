package kessel

import "core:mem"
import "core:fmt"
import "core:strings"

// ============================================================================
// TypeScript Type Parsing (Phase 3)
// ============================================================================

// parse_ts_return_type_annotation parses a function return type annotation
// starting at `:`, and supports the TS type-predicate forms:
//     : x is T          - TSTypePredicate { parameter_name, type_annotation, asserts:false }
//     : asserts x is T  - TSTypePredicate { parameter_name, type_annotation, asserts:true  }
//     : asserts x       - TSTypePredicate { parameter_name, type_annotation:nil, asserts:true }
// Falls back to a plain type annotation otherwise.
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
	// Heuristic: at this point the current token must be either
	//   - `.Asserts` identifier-keyword followed by an
	//     Identifier or This, optionally followed by `is <type>`. We can consume.
	//   - An Identifier followed by `.Is` - then it's `x is T`.
	// "this is T" is also valid - where `this` is the parameter name.
	asserts := false
	pred_start := cur_loc(p)

	ensure_nxt(p)
	is_predicate := false
	if is_token(p, .Asserts) && (p.lexer.nxt.kind == .Identifier || p.lexer.nxt.kind == .This) {
		asserts = true
		eat(p) // consume `asserts`
		is_predicate = true
 ensure_nxt(p)
	} else if (is_token(p, .Identifier) || is_token(p, .This)) && p.lexer.nxt.kind == .Is && (p.lexer.nxt.flags & FLAG_NEW_LINE) == 0 {
		// Line break before `is` triggers ASI - `I\nis()` is two members, not a type predicate.
		is_predicate = true
	}

	if is_predicate {
		// Parse parameter name: Identifier or `this`. Each leaf carries
		// its own location; the previously-bound `name_loc` was unused.
		name_cur := snap_current(p)
		name_ident, name_ident_e := new_expr(p, Identifier)
		name_ident.loc = loc_from_token(&name_cur)
		name_ident.name = name_cur.value
		eat(p) // consume identifier or `this`
		name_expr := name_ident_e

		// Optional `is <type>` (may be absent for pure `asserts x`).
		type_ann_opt: Maybe(^TSTypeAnnotation)
		if is_token(p, .Is) {
			eat(p) // consume `is`
			inner_start := cur_loc(p)
			inner_ty := parse_ts_type(p)
			inner_ann := new_node(p, TSTypeAnnotation)
			inner_ann.loc = inner_start
			inner_ann.type_annotation = inner_ty
			inner_ann.loc.end = prev_end_offset(p)
			type_ann_opt = inner_ann
		}

		// Build TSTypePredicate.
		pred := new_node(p, TSTypePredicate)
		pred.loc = pred_start
		pred.parameter_name = name_expr
		pred.type_annotation = type_ann_opt
		pred.asserts = asserts
		pred.loc.end = prev_end_offset(p)

		// Wrap in TSType then TSTypeAnnotation.
		tst := new_node(p, TSType); tst^ = pred
		ann := new_node(p, TSTypeAnnotation)
		ann.loc = ann_start
		ann.type_annotation = tst
		ann.loc.end = prev_end_offset(p)
		return ann
	}

	// Fallback: regular type annotation.
	inner := parse_ts_type(p)
	ann := new_node(p, TSTypeAnnotation)
	ann.loc = ann_start
	ann.type_annotation = inner
	ann.loc.end = prev_end_offset(p)
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
 ensure_nxt(p)
	if is_token(p, .Asserts) && (p.lexer.nxt.kind == .Identifier || p.lexer.nxt.kind == .This) {
		asserts = true
		eat(p)
		is_predicate = true
 ensure_nxt(p)
	} else if is_token(p, .This) && p.lexer.nxt.kind == .Is && (p.lexer.nxt.flags & FLAG_NEW_LINE) == 0 {
		// `this is T` is unambiguous — allow in non-return positions.
		is_predicate = true
	}
	if is_predicate {
		pred_start := cur_loc(p)
		name_cur := snap_current(p)
		name_ident, name_ident_e := new_expr(p, Identifier)
		name_ident.loc = loc_from_token(&name_cur)
		name_ident.name = name_cur.value
		eat(p)
		name_expr := name_ident_e
		inner_ann_opt: Maybe(^TSTypeAnnotation)
		if is_token(p, .Is) {
			eat(p)
			inner_start := cur_loc(p)
			inner_ty := parse_ts_type(p)
			inner_ann := new_node(p, TSTypeAnnotation)
			inner_ann.loc = inner_start
			inner_ann.type_annotation = inner_ty
			inner_ann.loc.end = prev_end_offset(p)
			inner_ann_opt = inner_ann
		}
		pred := new_node(p, TSTypePredicate)
		pred.loc = pred_start
		pred.parameter_name = name_expr
		pred.type_annotation = inner_ann_opt
		pred.asserts = asserts
		pred.loc.end = prev_end_offset(p)
		pred_ts := new_node(p, TSType)
		pred_ts^ = pred
		ann := new_node(p, TSTypeAnnotation)
		ann.loc = start
		ann.type_annotation = pred_ts
		ann.loc.end = prev_end_offset(p)
		return ann
	}
	ts_type := parse_ts_type(p)
	if ts_type == nil {
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected type after ':'")
	}
	ann := new_node(p, TSTypeAnnotation)
	ann.loc = start; ann.type_annotation = ts_type
	ann.loc.end = prev_end_offset(p)
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
 ensure_nxt(p)
	if is_token(p, .Asserts) && (p.lexer.nxt.kind == .Identifier || p.lexer.nxt.kind == .This) {
		asserts = true
		eat(p)
		is_predicate = true
 ensure_nxt(p)
	} else if (is_token(p, .Identifier) || is_token(p, .This)) && p.lexer.nxt.kind == .Is && (p.lexer.nxt.flags & FLAG_NEW_LINE) == 0 {
		// Line break before `is` triggers ASI - not a type predicate.
		is_predicate = true
	}
	if is_predicate {
		name_cur := snap_current(p)
		name_ident, name_ident_e := new_expr(p, Identifier)
		name_ident.loc = loc_from_token(&name_cur)
		name_ident.name = name_cur.value
		eat(p)
		name_expr := name_ident_e
		inner_ann_opt: Maybe(^TSTypeAnnotation)
		if is_token(p, .Is) {
			eat(p)
			inner_start := cur_loc(p)
			inner_ty := parse_ts_type(p)
			inner_ann := new_node(p, TSTypeAnnotation)
			inner_ann.loc = inner_start
			inner_ann.type_annotation = inner_ty
			inner_ann.loc.end = prev_end_offset(p)
			inner_ann_opt = inner_ann
		}
		pred := new_node(p, TSTypePredicate)
		pred.loc = start
		pred.parameter_name = name_expr
		pred.type_annotation = inner_ann_opt
		pred.asserts = asserts
		pred.loc.end = prev_end_offset(p)
		pred_ts := new_node(p, TSType)
		pred_ts^ = pred
		ann := new_node(p, TSTypeAnnotation)
		ann.loc = start
		ann.type_annotation = pred_ts
		ann.loc.end = prev_end_offset(p)
		return ann
	}
	ts_type := parse_ts_type(p)
	if ts_type == nil {
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected type in type annotation")
	}
	ann := new_node(p, TSTypeAnnotation)
	ann.loc = start; ann.type_annotation = ts_type
	ann.loc.end = prev_end_offset(p)
	return ann
}

// looks_like_ts_function_type - cheap detection for function type vs
// paren-wrapped type at a `(`. Caller is at `.LParen` in parse_ts_primary_type.
// See comments at the call site for the signal table.
looks_like_ts_function_type :: proc(p: ^Parser) -> bool {
	assert(p.cur_type == .LParen)
 ensure_nxt(p)
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
	// `)`+`=>` follows.	// "Expected ), got :" cluster (typescript fixtures with shapes like
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
	// keyword (`from`, `of`, `as`, `async`, `let`, `static`, ...).
	// Without this, a TS function type whose param is named `from`
	// (`(from: T) => U`) would fail
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
	if is_token(p, .Extends) && p.ts_disallow_conditional_types == 0 && !cur_has_newline(p) {
		eat(p)
		// The extends type of a conditional is parsed with conditional
		// types suppressed (matching TypeScript's
		// disallowConditionalTypesAnd). This ensures that `infer U
		// extends C` inside the extends position always treats `extends`
		// as a constraint (no speculative lookahead needed).
		p.ts_disallow_conditional_types += 1
		p.ts_in_conditional_extends += 1
		exts := parse_ts_type(p)
		p.ts_in_conditional_extends -= 1
		p.ts_disallow_conditional_types -= 1
		expect_token(p, .Question)
		true_type := parse_ts_type(p)
		expect_token(p, .Colon)
		false_type := parse_ts_type(p)
		cond := new_node(p, TSConditionalType)
		if loc := get_ts_type_loc(check); loc != nil { cond.loc = loc^ }
		cond.check_type = check; cond.extends_type = exts
		cond.true_type = true_type; cond.false_type = false_type
		cond.loc.end = prev_end_offset(p)
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
	leading_pipe_start := cur_loc(p).start
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
			u.loc.start = leading_pipe_start
			u.loc.end = prev_end_offset(p)
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
		u.loc.start = leading_pipe_start
	} else if loc := get_ts_type_loc(first); loc != nil {
		u.loc = loc^
	}
	u.loc.end = prev_end_offset(p)
	r := new_node(p, TSType); r^ = u; return r
}

parse_ts_intersection_type :: proc(p: ^Parser) -> ^TSType {
	// Optional leading `&` mirrors the leading-pipe allowance for unions.
	// `type X = & A & B` is equivalent to `type X = A & B`.
	leading_amp_start := cur_loc(p).start
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
			i.loc.start = leading_amp_start
			i.loc.end = prev_end_offset(p)
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
		i.loc.start = leading_amp_start
	} else if loc := get_ts_type_loc(first); loc != nil {
		i.loc = loc^
	}
	i.loc.end = prev_end_offset(p)
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
		report_error_coded(p, .K2070_RequiredFormOrBinding, "Function type must be parenthesized in union or intersection")
	case ^TSConstructorType:
		report_error_coded(p, .K2070_RequiredFormOrBinding, "Constructor type must be parenthesized in union or intersection")
	}
}

parse_ts_kw :: proc(p: ^Parser, kind: TSKeywordKind, start: Loc) -> ^TSType {
	eat(p)
	node := new_node(p, TSKeywordType); node.loc = start; node.loc.end = prev_end_offset(p); node.kind = kind
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
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected '(' after 'new' in constructor type")
		return nil
	}
	params := parse_ts_sig_params(p)
	if !is_token(p, .Arrow) {
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected '=>' in constructor type")
		return nil
	}
	arrow_start := u32(cur_offset(p))
	eat(p) // consume `=>`
	ret_type := parse_ts_type_annotation_bare(p)
	if ret_type != nil {
		ret_type.loc.start = arrow_start
	}
	ctor := new_node(p, TSConstructorType)
	ctor.loc = start
	ctor.type_parameters = type_params
	ctor.params = params
	ctor.return_type = ret_type
	ctor.abstract_ = abstract
	ctor.loc.end = prev_end_offset(p)
	r := new_node(p, TSType); r^ = ctor
	return parse_ts_postfix(p, r, start)
}

// Parse a TS template-literal type with substitutions starting at the
// .TemplateHead token. Mirrors parse_template_literal's quasi-collecting
// loop but parses each `${...}` slot as a TS type rather than an
// expression, which is required for `\`prefix-${T}-suffix\`` literal types.
parse_ts_template_literal_type :: proc(p: ^Parser, start: Loc) -> ^TSType {
	head := snap_current(p)
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
			l.lit_write_idx ~= 1
			l.nxt_valid = false
			p.cur_type = l.cur.kind
		}
		tok := snap_current(p)
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
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected template middle / tail token in template literal type")
		break
	}
	node.loc.end = prev_end_offset(p) + 1 // include trailing backtick
	r := new_node(p, TSType); r^ = node
	return parse_ts_postfix(p, r, start)
}

parse_ts_tuple_type :: proc(p: ^Parser, start: Loc) -> ^TSType {
	// TS tuple type, with support for variadic and optional/named elements:
	//   plain      `[T, U]`
	//   variadic   `[A, ...B[]]`,  `[...A, B]`,  `[...Elements, "abc"]`
	//   optional   `[T?, U]`  (TSOptionalType, postfix on the element)
	//   named      `[a: string, b?: number]`  (TSNamedTupleMember)
	// The inner loop must use a dedicated tuple-element parser rather
	// than parse_ts_type directly, since plain parse_ts_type doesn't
	// recognise the leading `...` or `name:` / `name?:` prefix.
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
			report_error_coded(p, .K2003_ExpectedTypeElement, "Expected tuple element type, got ','")
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
    ensure_nxt(p)
			if p.cur_type == .Identifier && p.lexer.nxt.kind == .Colon {
				rest_label_tok := snap_current(p)
				eat(p) // consume label
				eat(p) // consume `:`
				rest_inner := parse_ts_type(p)
				rest := new_node(p, TSRestType)
				rest.loc = elem_start
				rest.type_annotation = rest_inner
				rest.loc.end = prev_end_offset(p)
				rest_t := new_node(p, TSType); rest_t^ = rest
				named_rest := new_node(p, TSNamedTupleMember)
				named_rest.loc = elem_start
				named_rest.label = BindingIdentifier{
					loc = loc_from_token(&rest_label_tok),
					name = rest_label_tok.value,
				}
				named_rest.element_type = rest_t
				named_rest.optional = false
				named_rest.loc.end = prev_end_offset(p)
				elev = new_node(p, TSType); elev^ = named_rest
			} else {
				inner := parse_ts_type(p)
				rest := new_node(p, TSRestType)
				rest.loc = elem_start
				rest.type_annotation = inner
				rest.loc.end = prev_end_offset(p)
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
     ensure_nxt(p)
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
				label_tok := snap_current(p)
				eat(p) // consume label identifier
				optional := false
				if is_token(p, .Question) { optional = true; eat(p) }
				expect_token(p, .Colon)
				inner := parse_ts_type(p)
				if inner != nil {
					if _, is_opt_type := inner^.(^TSOptionalType); is_opt_type {
						report_error_coded(p, .K4051_TSDeclarationStructure, "A labeled tuple element cannot use postfix optional type syntax")
					}
				}
				if optional {
					optional_seen = true
				} else if optional_seen {
					report_error_coded(p, .K4051_TSDeclarationStructure, "A required tuple element cannot follow an optional element")
				}
				named_member := new_node(p, TSNamedTupleMember)
				named_member.loc = elem_start
				named_member.label = BindingIdentifier{loc = loc_from_token(&label_tok), name = label_tok.value}
				named_member.element_type = inner
				named_member.optional = optional
				named_member.loc.end = prev_end_offset(p)
				elev = new_node(p, TSType); elev^ = named_member
			} else {
				elev = parse_ts_type(p)
				// Postfix `?` on a tuple element - TSOptionalType.
				if elev != nil && is_token(p, .Question) {
					eat(p)
					opt := new_node(p, TSOptionalType)
					opt.loc = elem_start
					opt.type_annotation = elev
					opt.loc.end = prev_end_offset(p)
					elev = new_node(p, TSType); elev^ = opt
					optional_seen = true
				} else if optional_seen {
					report_error_coded(p, .K4051_TSDeclarationStructure, "A required tuple element cannot follow an optional element")
				}
			}
		}
		if elev != nil { bump_append(&types, elev) }
		if !match_token(p, .Comma) { break }
	}
	expect_token(p, .RBracket)
	p.ts_disallow_conditional_types = saved_disallow_ct
	p.ts_in_tuple_type = saved_in_tuple
	tup := new_node(p, TSTupleType); tup.loc = start; tup.element_types = types; tup.loc.end = prev_end_offset(p)
	r := new_node(p, TSType); r^ = tup
	// Same chain as the LBrace branch above - `[T, U][]` (array of tuples)
	// and `[T, U][N]` (indexed access into a tuple) need parse_ts_postfix.
	return parse_ts_postfix(p, r, start)
}

parse_ts_import_type :: proc(p: ^Parser, start: Loc) -> ^TSType {
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
			report_error_coded(p, .K2070_RequiredFormOrBinding, "String literal expected in import type")
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
			report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected '{' after ',' in import type options")
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
			} else if is_token(p, .Identifier) && cur_value_eq(p, "with") {
				// `w\u0069th` — escaped form of `with`.
				if cur_has_escape(p) {
					report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected 'with' in import type options")
				}
			} else if is_token(p, .String) {
				// `"with"` as string literal key.
				report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected 'with' in import type options")
			}
			eat(p) // consume key (with / identifier / string)
			if is_token(p, .Colon) { eat(p) } // consume :
			// Inner value: `{ type: "json" }`. Validate contents.
			if is_token(p, .LBrace) {
				eat(p) // consume inner {
				for !is_token(p, .RBrace) && !is_token(p, .EOF) {
					if is_token(p, .Dot3) {
						report_error_coded(p, .K3024_ImportAttributeInvalid, "Spread elements are not allowed in import type options")
					}
					if is_token(p, .LBracket) {
						report_error_coded(p, .K2070_RequiredFormOrBinding, "Import attributes keys must be identifier or string literal")
					}
					// Validate the key: must be Identifier, String, or keyword-as-name.
					// Numeric / BigInt literals as keys are invalid here.
					if is_token(p, .Number) || is_token(p, .BigInt) {
						report_error_coded(p, .K3024_ImportAttributeInvalid, "Numeric or bigint literal cannot be an import attribute key")
					}
					eat(p) // consume key
					if !is_token(p, .Colon) && !is_token(p, .RBrace) && !is_token(p, .Comma) {
						report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected ':' after import attribute key")
					}
					if is_token(p, .Colon) {
						eat(p) // consume :
						// Skip value tokens until comma or closing brace.
						inner_depth := 0
						for !is_token(p, .EOF) {
							if is_token(p, .LBrace) || is_token(p, .LBracket) { inner_depth += 1 }
							else if is_token(p, .RBrace) || is_token(p, .RBracket) {
								if inner_depth == 0 { break }
								inner_depth -= 1
							}
							else if is_token(p, .Comma) && inner_depth == 0 {
								break
							}
							eat(p)
						}
					}
					if is_token(p, .Comma) { eat(p) } // consume comma
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
		id_node, id_node_e := new_expr(p, Identifier)
		id_node^ = qual_id
		cur_qual := id_node_e
		for is_token(p, .Dot) {
			eat(p)
			prop_id := parse_identifier(p)
			prop_node, prop_node_e := new_expr(p, Identifier)
			prop_node^ = prop_id
			mem := new_node(p, MemberExpression)
			mem.loc = it.loc
			mem.object = cur_qual
			mem.property = prop_node_e
			mem.computed = false
			mem.optional = false
			mem.loc.end = prev_end_offset(p)
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
	it.loc.end = prev_end_offset(p)
	r := new_node(p, TSType); r^ = it
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
		// Without this, `new` in type position falls through to default
		// and the outer parser surfaces it as a JS NewExpression in expression
		// position, breaking the variable binding. ESTree-TS shape:
		//   { type: "TSConstructorType", abstract, typeParameters, params,
		//     returnType }
		return parse_ts_constructor_type(p, start, false)
	case .LAngle:
		// TS generic function type: `<T>(x: T) => U`. The `<` in type
		// position has only one possible meaning - the start of TSFunctionType
		// with type parameters. Without this, type annotations like
		// `declare const f: <T>(x: T) => T` choke at `<` and the parser
		// falls back to default-binding logic that
		// reported "Expected '=', ',', or ';' after variable binding". In
		// type-alias position (`type F = <T>(...) => T`) the same gap was
		// hidden because the parser silently treated `<T>(...) => T` as a
		// JS ArrowFunctionExpression in expression-statement position
		// (the trailing `;` made the test pass exit-cleanly while the AST
		// shape was wrong).		// "Expected '=', ',', or ';' after variable binding" cluster
		type_params := parse_ts_type_parameters(p)
		if !is_token(p, .LParen) {
			report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected '(' after generic type parameters in function type")
			return nil
		}
		params := parse_ts_sig_params(p)
		if !is_token(p, .Arrow) {
			report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected '=>' in generic function type")
			return nil
		}
		arrow_start := u32(cur_offset(p))
		eat(p) // consume `=>`
		ret_type := parse_ts_type_annotation_bare(p)
		if ret_type != nil {
			ret_type.loc.start = arrow_start
		}
		fn := new_node(p, TSFunctionType)
		fn.loc = start
		fn.type_parameters = type_params
		fn.params = params
		fn.return_type = ret_type
		fn.loc.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = fn
		return parse_ts_postfix(p, r, start)
	case .LParen:
		// TS function type with named params: `(x: T, ...) => U`.
		// Detected cheaply via 1-2 token lookahead because the outer type
		// grammar has no ambiguity here - a `(` in a type position is
		// either a function type, a paren-wrapped type, or (illegally) a
		// tuple typo. Named params and rest params are only legal in a
		// function type, so their presence is a definitive signal.
		// Signals (all require =>-terminated form):
		//   ()           - zero-arg function type (e.g. `() => void`).
		//   (...         - rest parameter.
		//   (Identifier : / (Identifier ?  - named param with annotation.
		if looks_like_ts_function_type(p) {
			params := parse_ts_sig_params(p)
			if !is_token(p, .Arrow) {
				report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected '=>' in function type")
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
				ret_type.loc.start = arrow_start
			}
			fn := new_node(p, TSFunctionType)
			fn.loc = start
			fn.params = params
			fn.return_type = ret_type
			fn.loc.end = prev_end_offset(p)
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
		pn := new_node(p, TSParenthesizedType); pn.loc = start; pn.type_annotation = inner; pn.loc.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = pn; return parse_ts_postfix(p, r, start)
	case .LBrace:
		// TS object type literal `{ ... }`. Must thread through parse_ts_postfix
		// so trailing `[]` (TSArrayType) and `[K]` (TSIndexedAccessType) attach
		// correctly. Without this, `var t: { x: string }[] = []` reports
		// "Expected '=', ',', or ';'" at `[` because the type ends at `}`
		// and the parser tries to parse `[]` as the
		// initializer of a different declarator.
		return parse_ts_postfix(p, parse_ts_type_object(p), start)
	case .LBracket:
		return parse_ts_tuple_type(p, start)
	case .Void:   return parse_ts_kw(p, .Void, start)
	case .Null:   return parse_ts_kw(p, .Null, start)
	case .This:   return parse_ts_kw(p, .This, start)
	case .Never:  return parse_ts_kw(p, .Never, start)
	case .Const:
		// TS const assertion target: `expr as const`. `const` is a JS
		// reserved keyword (lexed as .Const), not a real type, but TS-ESTree
		// models the assertion's type as TSTypeReference whose typeName is
		// Identifier("const"). Must be handled explicitly because
		// parse_ts_type_reference expects an Identifier token — .Const
		// reported "Expected semicolon" / "Expected binding pattern". Closes
		// 50+ OXC corpus rejects in the "Expected semicolon" cluster
		cur_const := snap_current(p)
		id, id_e := new_expr(p, Identifier); id.loc = loc_from_token(&cur_const); id.name = "const"
		eat(p)
		ref := new_node(p, TSTypeReference); ref.loc = start
		ref.type_name = id_e
		ref.loc.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = ref
		return parse_ts_postfix(p, r, start)
	case .Typeof:
		// TS type-query: `typeof X` / `typeof X.Y.Z` / `typeof X<TArgs>`
		// (the type-arguments form is TS 4.7+, used to instantiate generic
		// type-of references). Must use a dedicated typeof-qualifier
		// parser rather than parse_left_hand_side_expr, which would read
		// `<` as JS less-than, breaking files like
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
			tq_cur := snap_current(p)
			tq_id, tq_id_e := new_expr(p, Identifier); tq_id.loc = loc_from_token(&tq_cur); tq_id.name = tq_cur.value
			eat(p)
			tq_expr = tq_id_e
			for is_token(p, .Dot) {
				eat(p)
				// `typeof A.` (trailing dot without property) is a
				// SyntaxError. Check that an identifier follows.
				if !is_token(p, .Identifier) && !is_keyword_usable_as_property_name(p.cur_type) {
					report_error_coded(p, .K2021_ExpectedIdentifier, "Expected property name after '.'")
					break
				}
				tq_prop := parse_identifier_name(p)
				tq_mem, tq_mem_e := new_expr(p, MemberExpression); tq_mem.loc = start; tq_mem.object = tq_expr
				tq_pid, tq_pid_e := new_expr(p, Identifier); tq_pid.loc = tq_prop.loc; tq_pid.name = tq_prop.name
				tq_mem.property = tq_pid_e; tq_mem.computed = false; tq_mem.optional = false
				tq_mem.loc.end = prev_end_offset(p)
				tq_expr = tq_mem_e
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
		node.loc.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = node; return parse_ts_postfix(p, r, start)
	case .Keyof:
		eat(p); operand := parse_ts_primary_type(p)
		node := new_node(p, TSTypeOperator); node.loc = start; node.operator = "keyof"; node.type_annotation = operand
		node.loc.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = node; return r
	case .Unique:
		// `unique <type>`. The TS spec only defines `unique symbol`, but
		// OXC/Babel parse `unique <any-type>` syntactically and defer the
		// restriction to the type checker. Match that: accept `unique` as
		// a type operator whenever the next token can start a type (symbol,
		// number, object, etc.). Falls through to TypeReference for the
		// rare case of `unique` used as a plain identifier.
  ensure_nxt(p)
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
			node.loc.end = prev_end_offset(p)
			r := new_node(p, TSType); r^ = node
			return parse_ts_postfix(p, r, start)
		}

	case .Infer:
		// TS1338: 'infer' is only valid in the extends clause of a conditional type.
		if p.ts_in_conditional_extends == 0 && allow_ts_mode(p) {
			report_error_coded(p, .K2040_UnexpectedToken, "'infer' declarations are only permitted in the 'extends' clause of a conditional type.")
		}
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
		node.loc.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = node; return r
	case .Minus, .Plus:
		// TS prefixed numeric / bigint literal type: `let y: -1 = -1;`,
		// `let z: -1n = -1n`. ESTree shape: TSLiteralType whose literal is
		// a UnaryExpression(operator="-", argument=Literal). Only `-` and
		// `+` qualify, and only on a numeric or bigint literal. Anything
		// else (e.g. `-x`, `-(1)`) is a parse error in TS type position.
		op_tok := snap_current(p)
		op_kind: UnaryOperator = op_tok.type == .Minus ? .Minus : .Plus
		eat(p) // consume `-` / `+`
		if p.cur_type != .Number && p.cur_type != .BigInt {
			report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected numeric or bigint literal after unary operator in type")
			return nil
		}
		lit_start := cur_loc(p)
		lit_expr: ^Expression
		if p.cur_type == .Number {
			cur := snap_current(p); nl, nl_e := new_expr(p, NumericLiteral); nl.loc = loc_from_token(&cur); nl.raw = cur.value
			if v, ok := cur.literal.(f64); ok { nl.value = v }
			eat(p)
			lit_expr = nl_e
		} else {
			cur := snap_current(p); bl := new_node(p, BigIntLiteral); bl.loc = loc_from_token(&cur); bl.raw = cur.value
			if v, ok := cur.literal.(string); ok { bl.value = v }
			eat(p)
			lit_expr = expression_from(p, bl)
		}
		unary, unary_e := new_expr(p, UnaryExpression)
		unary.loc = start
		unary.operator = op_kind
		unary.argument = lit_expr
		unary.prefix = true
		unary.loc.end = prev_end_offset(p)
		_ = lit_start
		node := new_node(p, TSLiteralType); node.loc = start
		node.literal = unary_e
		node.loc.end = prev_end_offset(p)
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
		node.loc.end = prev_end_offset(p)
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
		// `1[][]`, `1 | 1[]`, etc. Must route through parse_ts_postfix
		// so trailing `[]` / `[K]` attaches. Without it, `T = 1[]`
		// reports "Expected '=', ',', or ';' after variable binding"
		// at the `[` (the parser ended the type at the literal and tried to
		// parse `[]` as a different declarator's initializer). Mirrors the
		// same parse_ts_postfix wrapping used by .LBrace / .LBracket / kw
		// cases above. One return path covers all four literal kinds; the
		// inner switch only differs in the literal-node construction.
		lit_expr: ^Expression
		#partial switch p.cur_type {
		case .String:
			lit := parse_string_literal(p); le, le_e := new_expr(p, StringLiteral); le^ = lit
			lit_expr = le_e
		case .Number:
			cur := snap_current(p); nl, nl_e := new_expr(p, NumericLiteral); nl.loc = loc_from_token(&cur); nl.raw = cur.value
			if v, ok := cur.literal.(f64); ok { nl.value = v }
			eat(p)
			lit_expr = nl_e
		case .BigInt:
			// BigInt literal type: `const y: 12n = 12n`.
			cur := snap_current(p); bl := new_node(p, BigIntLiteral); bl.loc = loc_from_token(&cur); bl.raw = cur.value
			if v, ok := cur.literal.(string); ok { bl.value = v }
			eat(p)
			lit_expr = expression_from(p, bl)
		case .True, .False:
			val := p.cur_type == .True; eat(p)
			bl := new_node(p, BooleanLiteral); bl.loc = start; bl.value = val
			lit_expr = expression_from(p, bl)
		}
		node := new_node(p, TSLiteralType); node.loc = start; node.literal = lit_expr; node.loc.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = node
		return parse_ts_postfix(p, r, start)
	case .Import:
		return parse_ts_import_type(p, start)
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
		// TS / Flow nullable prefix: `?string`. Accepted permissively in
		// type arguments (JSDoc patterns like `foo<string?>`), but flagged
		// outside type arguments (TS17020).
		if allow_ts_mode(p) {
			if p.ts_in_type_arguments == 0 {
				report_error_coded(p, .K4052_AccessorOrTypeParamForm, "'?' at the start of a type is not valid TypeScript syntax")
			}
			eat(p) // consume `?`
			return parse_ts_primary_type(p)
		}
		return nil
	case .Not:
		// JSDoc non-nullable prefix: `!string`. OXC produces
		// TSJSDocNonNullableType. Accept permissively.
		// TS17020: `!` at the start of a type is not valid TypeScript syntax.
		if allow_ts_mode(p) {
			report_error_coded(p, .K4052_AccessorOrTypeParamForm, "'!' at the start of a type is not valid TypeScript syntax")
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
	value := snap_current(p).value
	// Built-in keyword names like `string` / `number` / `any` are
	// pre-empted by a TSTypeReference whenever they form a qualified-name
	// chain. TS allows shadowing primitives with namespace declarations:
	//   declare namespace string { interface X { } }
	//   var x: string.X;          // TypeReference, not TSStringKeyword
	// Without this opt-out the keyword arm below short-circuits the
	// chain and the `.X` cascade ends up unconsumed, surfacing as
	// "Expected '=', ',', or ';' after variable binding". Closes a
	// handful of files in that cluster (parserModuleDeclaration11.ts,
	// uniqueSymbolsErrors.ts).
 ensure_nxt(p)
	if p.lexer.nxt.kind == .Dot {
		return parse_ts_type_reference(p)
	}
	switch value {
	case "any":       return parse_ts_kw(p, .Any, start)
	case "number":    return parse_ts_kw(p, .Number, start)
	case "string":    return parse_ts_kw(p, .String, start)
	case "boolean":   return parse_ts_kw(p, .Boolean, start)
	case "bigint":    return parse_ts_kw(p, .BigInt, start)
	case "symbol":    return parse_ts_kw(p, .Symbol, start)
	case "object":    return parse_ts_kw(p, .Object, start)
	case "unknown":   return parse_ts_kw(p, .Unknown, start)
	case "undefined": return parse_ts_kw(p, .Undefined, start)
	case "never":     return parse_ts_kw(p, .Never, start)
	case "intrinsic":
		// `intrinsic` is a TS keyword type. Parse it, then check for
		// disallowed postfix operators. `intrinsic["foo"]` is not valid.
		eat(p)
		node := new_node(p, TSKeywordType); node.loc = start; node.kind = .Intrinsic
		node.loc.end = prev_end_offset(p)
		result := new_node(p, TSType); result^ = node
		// Reject indexed access on intrinsic keyword.
		if is_token(p, .LBracket) {
			report_error_coded(p, .K4052_AccessorOrTypeParamForm, "Indexed access is not allowed on 'intrinsic' keyword type")
		}
		return parse_ts_postfix(p, result, start)
	case "readonly":
		// TS type operator on tuple / array: `readonly T[]`,
		// `readonly [A, B, C]`, `readonly unknown[]`, `readonly Foo[]`,
		// `readonly (string | number)[]`. The lexer emits .Identifier
		// for "readonly" (contextual keyword, not reserved), so the
		// dispatch happens here, not via a dedicated `.Readonly` case in
		// parse_ts_primary_type.
		// Treat as a type operator when the NEXT token can start a type.
		// That set covers: LBracket (tuple), LParen (paren type / fn type),
		// Identifier (TypeReference / built-in keyword like `unknown`), and
		// the keyword tokens that begin a type (.This, .Void, .Null,
		// .Never, .Typeof, .Keyof, .Unique, .Infer, .Import, .True,
		// .False, .String, .Number). Bare `readonly` standing alone (very
		// rare - `Foo.readonly` IdentifierName) falls through to
		// TypeReference.
  ensure_nxt(p)
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
					report_error_coded(p, .K4032_ModifierMisplaced, "'readonly' type modifier is only permitted on array and tuple literal types")
				}
			}
			node := new_node(p, TSTypeOperator); node.loc = start
			node.operator = "readonly"; node.type_annotation = operand
			node.loc.end = prev_end_offset(p)
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
		//   interface I {
		//     thisIsNotATag(x: string): void
		//     [x: number]: I;
		//   }
		// has `void` greedily extended to `void[x: number]` (TSIndexedAccessType)
		// and the index signature is consumed mid-type, then everything
		// downstream cascades. Closes most of the
		// taggedTemplateStringsWithTypedTags / indexer2A /
		// noPropertyAccessFromIndexSignature1 cluster.
		if cur_has_newline(p) {
   ensure_nxt(p)
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
			arr := new_node(p, TSArrayType); arr.loc = start; arr.element_type = result; arr.loc.end = prev_end_offset(p)
			result = new_node(p, TSType); result^ = arr
		} else {
			// Indexed access type: `T[K]`.
			eat(p) // consume `[`
			index := parse_ts_type(p)
			expect_token(p, .RBracket)
			iat := new_node(p, TSIndexedAccessType); iat.loc = start
			iat.object_type = result; iat.index_type = index
			iat.loc.end = prev_end_offset(p)
			result = new_node(p, TSType); result^ = iat
		}
	}
	// TS / JSDoc non-nullable postfix: `T!`. OXC produces
	// TSJSDocNonNullableType. Accept permissively - just consume the `!`
	// and return the inner type. Same-line only (ASI guard).
	// TS17019: `!` at the end of a type is not valid TypeScript syntax.
	if is_token(p, .Not) && !cur_has_newline(p) {
		if allow_ts_mode(p) {
			report_error_coded(p, .K4052_AccessorOrTypeParamForm, "'!' at the end of a type is not valid TypeScript syntax")
		}
		eat(p) // consume `!`
	}
	// TS / JSDoc nullable postfix: `T?`. OXC produces
	// TSJSDocNullableType. Accept permissively. Only consume when `?`
	// is NOT followed by `:` or another type-continuation (to avoid
	// eating the `?` of a conditional type or an optional param `?:`).
	// EXCEPTION: inside a tuple type, the postfix `?` is reserved for
	// TSOptionalType syntax (`[T?, U]`), not JSDoc nullable. The tuple
	// parser handles it after parse_ts_type returns.
	// TS17019: `?` at the end of a type. Flagged outside type arguments;
	// suppressed inside `<...>` for JSDoc patterns like `foo<string?>`.
	if is_token(p, .Question) && !cur_has_newline(p) && !p.ts_in_tuple_type {
		ensure_nxt(p)
		nxt := p.lexer.nxt.kind
		if nxt == .RParen || nxt == .Comma || nxt == .Semi || nxt == .RBrace ||
		   nxt == .RBracket || nxt == .RAngle || nxt == .Assign || nxt == .EOF {
			if allow_ts_mode(p) && p.ts_in_type_arguments == 0 {
				report_error_coded(p, .K4052_AccessorOrTypeParamForm, "'?' at the end of a type is not valid TypeScript syntax")
			}
			eat(p) // consume `?`
		}
	}
	return result
}

parse_ts_type_reference :: proc(p: ^Parser) -> ^TSType {
	start := cur_loc(p)
	cur := snap_current(p)
	id, id_e := new_expr(p, Identifier); id.loc = loc_from_token(&cur); id.name = cur.value; eat(p)
	id_expr := id_e
	for is_token(p, .Dot) {
		eat(p); prop := parse_identifier_name(p)
		mem := new_node(p, MemberExpression); mem.loc = start; mem.object = id_expr
		pid, pid_e := new_expr(p, Identifier); pid.loc = prop.loc; pid.name = prop.name
		mem.property = pid_e; mem.loc.end = prev_end_offset(p)
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
		if cur_has_newline(p) && p.ts_in_type_literal > 0 {
			// Don't try type args at all — it's a new member.
		} else if cur_has_newline(p) {
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
	ref.loc.end = prev_end_offset(p)
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
	// Track type-argument context for JSDoc ? suppression.
	p.ts_in_type_arguments += 1
	params := make([dynamic]^TSType, 0, 4, p.allocator)
	for !is_close_angle_token(p) && !is_token(p, .EOF) {
		// Reject empty type argument positions: `Foo<a,,b>` — the `,`
		// after `a` means a type must follow before the next `,` or `>`.
		if is_token(p, .Comma) {
			report_error_coded(p, .K2003_ExpectedTypeElement, "Expected type argument, got ','")
			eat(p)
			continue
		}
		t := parse_ts_type(p); if t != nil { bump_append(&params, t) }; if !match_token(p, .Comma) { break }
	}
	if empty_at_start && len(params) == 0 {
		report_error_coded(p, .K4052_AccessorOrTypeParamForm, "Type argument list cannot be empty")
	}
	expect_close_angle(p)
	p.ts_in_type_arguments -= 1
	p.ts_disallow_conditional_types = saved_disallow_ct
	inst := new_node(p, TSTypeParameterInstantiation); inst.loc = start; inst.params = params; inst.loc.end = prev_end_offset(p)
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
//   1. Type assertion:  `<Type>expr`                       → TSTypeAssertion
//   2. Generic arrow:   `<T[, U, ...]>(params) => body`    → ArrowFunctionExpression
//                                                              with .type_parameters set
// In pure `.ts` (no JSX), there's no ambiguity with a JSX opening tag - both
// productions are legal TS at expression position and nothing else starts
// with `<`. In `.tsx` (JSX enabled), this function is NOT reached because
// allow_jsx_mode(p) is true; TSX ambiguity is handled by JSX today and
// deferred to Phase C (trailing-comma rule for generic arrows).
// Discriminator (1-token lookahead after `<`):
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
	// Every trial-parse path uses lexer_snapshot/restore to undo state
	// and any errors introduced by the speculative parse. A genuine user
	// syntax error (e.g. "<T,>(x:T)=>x" where the arrow-param type
	// annotation hits a pre-existing parser gap) reports a SINGLE clean
	// error instead of cascading SIGSEGVs.
 ensure_nxt(p)
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
			check_ts_ambiguous_jsx_like_arrow(p, result)
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
				check_ts_ambiguous_jsx_like_arrow(p, result)
				return result
			}
			// Generic-arrow parse failed - roll back and, for the
			// ambiguous `<T>` case only, fall through to an assertion
			// attempt. For the KNOWN-arrow signals (`,`/`extends`/`=`)
			// nothing else is legal: emit one error and bail.
			lexer_restore(p, snap2)
			if after != .RAngle {
				report_error_coded(p, .K2040_UnexpectedToken, "Malformed generic arrow function")
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
		report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token")
		return nil
	}
	if !expect_token(p, .RAngle) {
		lexer_restore(p, snap)
		report_error_coded(p, .K2040_UnexpectedToken, "Unexpected '<': not a valid TS type assertion or generic arrow")
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
	}
	expr := parse_unary_expr(p)
	if expr == nil {
		lexer_restore(p, snap)
		report_error_coded(p, .K2040_UnexpectedToken, "Unexpected '<': not a valid TS type assertion or generic arrow")
		return nil
	}
	// OXC rejects `<T>yield 0` in generators: `yield` directly after
	// `>` is treated as an identifier (§14.4.1), which is reserved.
	// `<T>(yield 0)` is fine (parens open AssignmentExpression context).
	// Distinguish by checking if the expression starts at the same
	// offset as the `>` end (no intervening paren).
	if p.ctx.in_generator {
		if ye, ok := expr^.(^YieldExpression); ok {
			// Check if `yield` directly follows `>` (bare form), or is
			// inside parens. Walk backwards from yield's start offset.
			ye_start := int(ye.loc.start)
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
				report_error_coded(p, .K3010_AwaitYieldAsBindingName,
			"'yield' cannot be used as an identifier in a generator context")
			}
		}
	}
	node, node_e := new_expr(p, TSTypeAssertion)
	node.loc = start
	node.type_annotation = type_ann
	node.expression = expr
	node.loc.end = prev_end_offset(p)

	if p.disallow_ambiguous_jsx_like {
		report_error_coded_span(p, .K4053_TSOnlyInJS, u32(start.start), u32(start.start), "This syntax is reserved in files with the .mts or .cts extension. Use an `as` expression instead")
	}

	return node_e
}

// When `disallow_ambiguous_jsx_like` is true, generic arrows with a
// single un-constrained type parameter and no trailing comma are
// reserved syntax (TSX-like rule for .mts/.cts and Babel option).
check_ts_ambiguous_jsx_like_arrow :: proc(p: ^Parser, expr: ^Expression) {
	if !p.disallow_ambiguous_jsx_like { return }
	arrow, ok := expr^.(^ArrowFunctionExpression)
	if !ok { return }
	tp_opt := arrow.type_parameters
	tp, has_tp := tp_opt.?
	if !has_tp { return }
	if len(tp.params) == 1 && tp.params[0].constraint == nil && !tp.trailing_comma {
		report_error_coded_span(p, .K4053_TSOnlyInJS, u32(tp.loc.start), u32(tp.loc.start), "This syntax is reserved in files with the .mts or .cts extension. Add a trailing comma, as in `<T,>() => ...`")
	}
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
	lex_nxt_valid:          bool,
	lex_lit_offset:     [2]u32,
	lex_lit_value:      [2]LiteralValue,
	lex_lit_type:       [2]LiteralType,
	lex_lit_write_idx:  u8,
	lex_template_depth:     u8,
	lex_template_brace_stack: [8]u8,
	// Parser scalars — re-derived from lexer on restore
	cur_type:       TokenType,
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
		lex_nxt_valid           = l.nxt_valid,
		lex_lit_offset          = l.lit_offset,
		lex_lit_value           = l.lit_value,
		lex_lit_type            = l.lit_type,
		lex_lit_write_idx       = l.lit_write_idx,
		lex_template_depth      = l.template_depth,
		lex_template_brace_stack = l.template_brace_stack,
		cur_type                = p.cur_type,
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
	l.nxt_valid              = s.lex_nxt_valid
	l.lit_offset             = s.lex_lit_offset
	l.lit_value              = s.lex_lit_value
	l.lit_type               = s.lex_lit_type
	l.lit_write_idx          = s.lex_lit_write_idx
	l.template_depth         = s.lex_template_depth
	l.template_brace_stack   = s.lex_template_brace_stack
	p.cur_type               = s.cur_type
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
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected '(' after generic type parameters")
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
		arrow_expr.loc.start = start.start
		return paren_expr
	}

	// Optional TS return-type annotation `: T` before `=>`.
	return_type: Maybe(^TSTypeAnnotation)
	if is_token(p, .Colon) { return_type = parse_ts_type_annotation(p) }

	if !is_token(p, .Arrow) {
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected '=>' in generic arrow function")
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
		a.loc.start = start.start
	}
	return arrow
}

// looks_like_ts_arrow_params - cheap 2-token lookahead to decide whether
// a `(` definitely opens TS arrow parameters (as opposed to a paren-wrapped
// expression). Called only in TS / TSX mode. Used by parse_primary_expr
// to gate try_parse_ts_arrow_params.
// Conservative signals (each uniquely identifies arrow params):
//   * `(...`            - rest parameter is only legal inside arrow params.
//   * `(Identifier :`   - `:Type` after an identifier in a paren-group is
//                         only legal as a parameter type annotation.
// We intentionally DO NOT trigger the trial on `(Identifier ,` /
// `(Identifier )` / `(Identifier =` / `({...` / `([...` - these all have a
// working paren-grouping path today that flows into parse_arrow_function via
// expr_to_pattern when `=>` follows. Expanding coverage to destructured
// params with type annotations (`({a}: P) => a`) is a future extension and
// needs the same trial-parse plumbing.
looks_like_ts_arrow_params :: proc(p: ^Parser) -> bool {
	assert(p.cur_type == .LParen)
 ensure_nxt(p)
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
	// one rollback.	// "Expected ), got :" cluster.
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
// The caller has already filtered via looks_like_ts_arrow_params(p), so the
// snapshot/rollback path is a safety net rather than the common case. On
// the happy path we build the arrow directly - no conversion from
// Expression→Pattern needed because parse_function_params already produced
// proper FunctionParameter nodes with type annotations attached.
try_parse_ts_arrow_params :: proc(p: ^Parser, lparen_tok: TokenSnap) -> ^Expression {
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
	// ~25 OXC corpus rejects in the "Expected ), got :" cluster.
	// The return-type parser must handle predicates directly because
	// plain parse_ts_type doesn't recognise `is` / `asserts` keywords;
	// without this, the trial bails at `is` and the outer
	// parser tried to re-parse the whole `(x: T)` as a paren-expr,
	// reporting "Expected ), got :" on the now-illegal type colon.
	return_type: Maybe(^TSTypeAnnotation)
	if is_token(p, .Colon) {
		snap_errs := len(p.errors)
		return_type = parse_ts_return_type_annotation(p)
		// `(a): => {}` — colon with no type before `=>`.
		if rt, ok := return_type.?; ok && rt != nil && rt.type_annotation == nil {
			report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected type after ':' in arrow return type annotation")
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
	if cur_has_newline(p) {
		report_error_coded(p, .K3064_LineTerminatorRestricted, "Line terminator not permitted before '=>'")
	}
	eat(p) // consume `=>`

	// Body - block or expression. Mirror parse_arrow_function's treatment.
	// §15.3.4: Arrow body is parsed with [~Yield, ~Await] (unless async).
	// Reset in_generator so `yield` inside the arrow body is an identifier.
	prev_in_generator := p.ctx.in_generator
	p.ctx.in_generator = false
	prev_static_block_ts := p.ctx.in_static_block
	p.ctx.in_static_block = false
	is_block_body := is_token(p, .LBrace)
	body: ArrowFunctionBody
	if is_block_body {
		prev_in_function := p.ctx.in_function
		p.ctx.in_function = true
		block_stmt := parse_block_statement(p)
		p.ctx.in_function = prev_in_function
		// §15.3.1: arrow `{ FunctionBody }` is a function-scope, not a block-scope.
		if block_stmt != nil {
			if bs, ok := block_stmt^.(^BlockStatement); ok {
				body = bs
			}
		}
	} else {
		#partial switch p.cur_type {
		case .Semi, .Comma, .RParen, .RBracket, .RBrace, .EOF:
			report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token")
		}
		body = parse_assignment_expression(p)
	}

	p.ctx.in_generator = prev_in_generator
	p.ctx.in_static_block = prev_static_block_ts

	arrow, arrow_e := new_expr(p, ArrowFunctionExpression)
	arrow.loc = start_loc
	arrow.params = params
	arrow.body = body
	arrow.expression = !is_block_body
	arrow.async = false
	if rt, ok := return_type.?; ok { arrow.return_type = rt }
	arrow.loc.end = prev_end_offset(p)

	// TS1689 — destructuring pattern `?` in arrow function (always has body).
	if allow_ts_mode(p) {
		for pr in params {
			if pr.optional_destructuring {
				report_error_coded_span(p, .K4063_OptionalAndInit, u32(pr.loc.start), u32(pr.loc.start), "A binding pattern parameter cannot be optional in an implementation signature")
			}
		}
	}
	parser_check_dup_params(p, params[:], start_loc.start, p.ctx.strict_mode, true)
	if is_block_body {
		if arrow_body_lifts_strict(body) {
			if !params_are_simple(params[:]) {
				report_error_coded_span(p, .K3052_UseStrictWithComplexParams, u32(start_loc.start), u32(start_loc.start), "Illegal 'use strict' directive in function with non-simple parameter list")
			}
			if !p.ctx.strict_mode {
				report_strict_param_pattern_retro(p, params[:])
			}
		}
	}

	return arrow_e
}

parse_ts_type_parameters :: proc(p: ^Parser) -> ^TSTypeParameterDeclaration {
	if !is_token(p, .LAngle) { return nil }
	start := cur_loc(p); eat(p) // consume `<`
	empty_at_start := is_close_angle_token(p)
	// Re-allow conditional types inside angle brackets.
	saved_disallow_ct := p.ts_disallow_conditional_types
	p.ts_disallow_conditional_types = 0
	params := make([dynamic]TSTypeParameter, 0, 4, p.allocator)
	had_trailing_comma := false
	for !is_token(p, .RAngle) && !is_token(p, .EOF) {
		// Reject empty type parameter positions: `<,T>` or `<,>`.
		if is_token(p, .Comma) {
			report_error_coded(p, .K2003_ExpectedTypeElement, "Expected type parameter name, got ','")
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
			if p.cur_type == .Identifier && cur_value_eq(p, "out") && nxt_starts_param {
				out_mod = true; eat(p); continue
			}
			break
		}
		// After modifiers, the current token must be a valid type parameter
		// name (identifier). Reserved words like `in` are NOT valid names:
		// `type T<in in>` — the second `in` is a keyword, not a name.
		if is_reserved_word_for_binding(p.cur_type) {
			msg := fmt.tprintf("Identifier expected. '%s' is a reserved word that cannot be used here.", cur_value(p))
			report_error_coded(p, .K3053_ReservedAsBindingIdentifier, msg)
		}
		cur := snap_current(p)
		name := BindingIdentifier{loc = loc_from_token(&cur), name = cur.value}
		// TS2368 — type parameter name cannot be a primitive type name.
		check_ts_primitive_decl_name(p, "Type parameter", name.name, name.loc)
		eat(p) // consume identifier
		constraint: Maybe(^TSType)
		default_: Maybe(^TSType)
		if is_token(p, .Extends) {
			eat(p)
			c := parse_ts_type(p)
			if c == nil {
				report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected type after 'extends'")
			} else {
				constraint = c
			}
		}
		if is_token(p, .Assign) {
			eat(p)
			d := parse_ts_type(p)
			if d == nil {
				report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected type after '='")
			} else {
				default_ = d
			}
		}
		param := TSTypeParameter{
			loc = param_start, name = name,
			constraint = constraint, default_ = default_,
			in_ = in_mod, out = out_mod, const_ = const_mod,
		}
		param.loc.end = prev_end_offset(p)
		bump_append(&params, param)
		had_trailing_comma = match_token(p, .Comma)
		if !had_trailing_comma { break }
	}
	if empty_at_start && len(params) == 0 {
		report_error_coded(p, .K4052_AccessorOrTypeParamForm, "Type parameter list cannot be empty")
	}
	// Use expect_close_angle so `>=` splits into `>` + `=`.
	// Fixes: `type T<U>=U` where `>=` should close the type params.
	expect_close_angle(p)
	p.ts_disallow_conditional_types = saved_disallow_ct
	decl := new_node(p, TSTypeParameterDeclaration)
	decl.loc = start; decl.params = params
	decl.trailing_comma = had_trailing_comma
	decl.loc.end = prev_end_offset(p)
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
	modifier_start := cur_loc(p).start

	// Check `{ readonly [`  - readonly then bracket, plus `+readonly [` / `-readonly [`.
	// `.Readonly` is not in the lexer - check by string value.
	if (p.cur_type == .Plus || p.cur_type == .Minus) {
		sign := p.cur_type == .Plus ? TSMappedTypeModifier.Plus : TSMappedTypeModifier.Minus
  ensure_nxt(p)
		nxt := p.lexer.nxt
		if nxt.kind == .Identifier {
			nxt_val := p.lexer.source[nxt.start:nxt.end]
			if nxt_val == "readonly" {
				readonly_mod = sign
				eat(p); eat(p) // consume sign and `readonly`
			}
		}
	}
	if p.cur_type == .Identifier && cur_value_eq(p, "readonly") && is_next_token(p, .LBracket) {
		readonly_mod = .True; eat(p) // consume `readonly`, now at `[`
	}

	// Check `{ [K in` pattern. Mapped types REQUIRE the literal `in`
	// keyword between the type-parameter name and the source type, so a
	// 2-token-ahead probe is enough to disambiguate from:
	//   - index signature       `[k : T]: V`
	//   - computed property key `[Symbol.iterator]?(): R`
	is_index_sig_after_readonly := false
	if is_token(p, .LBracket) {
  ensure_nxt(p)
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
		param_name_tok := snap_current(p)
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
			report_error_coded(p, .K4055_IndexSignatureForm, "An index signature must have a type annotation")
		}
		param_name_ident := new_node(p, Identifier)
		param_name_ident.loc = loc_from_token(&param_name_tok)
		param_name_ident.name = param_name_tok.value
		key_ann := new_node(p, TSTypeAnnotation)
		key_ann.loc.start = colon_start.start
		key_ann.loc.end   = key_type_end
		key_ann.type_annotation = idx_ann
		sig_loc_start := modifier_start
		idx_sig := TSIndexSignature{
			loc = Loc{start = sig_loc_start, end = lb_start.end},
			parameters = make([dynamic]TSFunctionParam, 0, 1, p.allocator),
			type_annotation = val_ann,
			readonly = readonly_mod == .True,
		}
		fp := TSFunctionParam{
			loc = param_start,
			pattern = param_name_ident,
			type_annotation = key_ann,
		}
		fp.loc.end = key_type_end
		bump_append(&idx_sig.parameters, fp)
		match_token(p, .Semi); match_token(p, .Comma)
		idx_sig.loc.end = prev_end_offset(p)
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
		lit.loc.end = prev_end_offset(p)
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
			key_ident, key_ident_e := new_expr(p, Identifier)
			key_ident.loc = param_name.loc
			key_ident.name = param_name.name
			optional := match_token(p, .Question)
			prop := TSPropertySignature{
				loc = Loc{start = lb_start.start},
				key = key_ident_e,
				computed = true, optional = optional,
				readonly = readonly_mod == .True,
			}
			if is_token(p, .Colon) { prop.type_annotation = parse_ts_type_annotation(p) }
			prop.loc.end = prev_end_offset(p)
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
			lit.loc.end = prev_end_offset(p)
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
				report_error_coded(p, .K4055_IndexSignatureForm, "An index signature must have a type annotation")
			}
			param_name_ident := new_node(p, Identifier)
			param_name_ident.loc = param_name.loc
			param_name_ident.name = param_name.name
			// TSTypeAnnotation for the key: spans [colon, end-of-key-type].
			key_ann := new_node(p, TSTypeAnnotation)
			key_ann.loc.start = key_type_start.start
			key_ann.loc.end   = key_type_end
			key_ann.type_annotation = idx_ann
			// Parameter: spans [start-of-name, end-of-key-type].
			// OXC ends the parameter at the end of the key type annotation,
			// NOT at the `]` or the value type.
			// Use modifier_start as the index signature loc start when a
			// readonly/+/-readonly modifier preceded the `[`; otherwise use lb_start.
			sig_loc_start := modifier_start if readonly_mod != .None else lb_start.start
			idx_sig := TSIndexSignature{
				loc = Loc{start = sig_loc_start, end = lb_start.end},
				parameters = make([dynamic]TSFunctionParam, 0, 1, p.allocator),
				type_annotation = val_ann,
				readonly = readonly_mod == .True,
			}
			fp := TSFunctionParam{
				loc = param_start,
				pattern = param_name_ident,
				type_annotation = key_ann,
			}
			fp.loc.end = key_type_end
			bump_append(&idx_sig.parameters, fp)
			// Consume optional semi/comma BEFORE setting the end span so the
			// index signature span includes the terminator (matching OXC).
			match_token(p, .Semi); match_token(p, .Comma)
			idx_sig.loc.end = prev_end_offset(p)
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
			lit := new_node(p, TSTypeLiteral); lit.loc = start; lit.members = members; lit.loc.end = prev_end_offset(p)
			r := new_node(p, TSType); r^ = lit; return r
		}
		eat(p) // consume `in`
		constraint := parse_ts_type(p)
		name_type: Maybe(^TSType)
		if is_token(p, .As) {
			eat(p)
			name_type = parse_ts_type(p)
			if name_type == nil {
				report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected type after 'as' in mapped type")
			}
		}
		expect_token(p, .RBracket)
		// Optional modifier: `?`, `+?`, `-?`.
		optional_mod := TSMappedTypeModifier.None
		ensure_nxt(p)
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
		mt.loc.end = prev_end_offset(p)
		r := new_node(p, TSType); r^ = mt; return r
	}

	// Regular object type literal.
	members := make([dynamic]^TSSignature, 0, 4, p.allocator)
	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		prev_off := u32(cur_offset(p))
		sig := parse_ts_object_member(p); if sig != nil { bump_append(&members, sig) }
		// terminator so the TSPropertySignature / TSMethodSignature span
		// matches OXC's convention. Same widen pattern as the TSInterfaceBody
		// loop further down. Without this, every TSTypeLiteral member ends
		// one byte short of OXC on `{ id: string; foo: number; }`.
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
			report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token in TS object type")
			eat(p)
		}
	}
	expect_token(p, .RBrace)
	report_duplicate_interface_member_errors(p, members[:])
	lit := new_node(p, TSTypeLiteral); lit.loc = start; lit.members = members; lit.loc.end = prev_end_offset(p)
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
			this_tok := snap_current(p)
			eat(p)
			this_id := new_node(p, Identifier)
			this_id.loc = loc_from_token(&this_tok)
			// source-slice (this_tok.value), not literal - same
			// RODATA bug as the .Async paths.
			this_id.name = this_tok.value
			pattern = this_id
		} else if is_token(p, .Dot3) {
			param_is_rest = true
			// TS rest parameter in function-type signature: `(...args: T) => U`.
			// parse_function_parameter (the JS-side analogue) handles this with
			// a Dot3 → RestElement-wrapping branch; parse_ts_sig_params shipped
			// without one, so every TS function type with rest reported
			// "Expected binding pattern" at the `...`. Closes OXC corpus
			rest_start := cur_loc(p)
			eat(p)  // consume `...`
			inner := parse_binding_pattern(p)
			rest := new_node(p, RestElement)
			rest.loc = rest_start
			rest.argument = inner
			rest.loc.end = prev_end_offset(p)
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
			report_error_coded(p, .K3041_RestForm, "A rest parameter cannot be optional")
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
					ap.loc.end = prev_end_offset(p)
					pattern = ap
				}
			}
		}
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
				if ann.loc.end > t.loc.end {
					t.loc.end = ann.loc.end
				}
			case ^ObjectPattern:
				if ann.loc.end > t.loc.end {
					t.loc.end = ann.loc.end
				}
			case ^ArrayPattern:
				if ann.loc.end > t.loc.end {
					t.loc.end = ann.loc.end
				}
			}
		}
		fp := TSFunctionParam{loc = param_start, pattern = pattern, type_annotation = param_ann, optional = param_optional}
		fp.loc.end = prev_end_offset(p)
		bump_append(&params, fp)
		if param_is_rest && is_token(p, .Comma) {
   ensure_nxt(p)
			if p.lexer.nxt.kind == .RParen {
				if !p.ctx.in_ambient && !p.source_is_dts {
					report_error_coded(p, .K3041_RestForm, "A rest parameter or binding pattern may not have a trailing comma")
				}
			} else {
				report_error_coded(p, .K3040_RestNotLast, "A rest parameter must be last in a parameter list")
			}
		}
		if !match_token(p, .Comma) { break }
	}
	expect_token(p, .RParen)
	return params
}

// set_ts_sig_end widens a TSSignature's `loc.end` in place. Used
// after consuming a trailing `;` / `,` / `}` so the member's span
// includes the terminator (OXC convention). The signature is a tagged
// union over value-carrying structs; we have to pattern-match and mutate
// each variant.
set_ts_sig_end :: proc(sig: ^TSSignature, end: u32) {
	if sig == nil { return }
	switch v in sig^ {
	case TSPropertySignature:
		p := v; p.loc.end = end; sig^ = p
	case TSMethodSignature:
		p := v; p.loc.end = end; sig^ = p
	case TSCallSignatureDeclaration:
		p := v; p.loc.end = end; sig^ = p
	case TSConstructSignatureDeclaration:
		p := v; p.loc.end = end; sig^ = p
	case TSIndexSignature:
		p := v; p.loc.end = end; sig^ = p
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
		} else if is_token(p, .Const) {
			modifier_name = "const"
		} else if is_token(p, .Default) {
			modifier_name = "default"
		} else if is_token(p, .Export) {
			modifier_name = "export"
		} else if is_token(p, .Async) {
			modifier_name = "async"
		} else if is_token(p, .Abstract) {
			modifier_name = "abstract"
		} else if is_token(p, .Accessor) {
			modifier_name = "accessor"
		} else if is_token(p, .Identifier) {
			switch cur_value(p) {
			case "public", "private", "protected", "declare", "abstract", "accessor", "async":
				modifier_name = cur_value(p)
			}
		}
		if modifier_name == "" { break }
  ensure_nxt(p)
		if (p.lexer.nxt.flags & FLAG_NEW_LINE) != 0 { break }
  ensure_nxt(p)
		nxt := p.lexer.nxt.kind
		if nxt == .Colon || nxt == .Question || nxt == .LParen || nxt == .Semi ||
		   nxt == .Comma || nxt == .RBrace {
			break
		}
		// Differentiate index signature messages
		is_idx_sig := nxt == .LBracket
		if is_idx_sig {
			report_error_coded(p, .K4032_ModifierMisplaced, fmt.tprintf("'%s' modifier cannot appear on an index signature", modifier_name))
		} else {
			report_error_coded(p, .K4032_ModifierMisplaced, fmt.tprintf("'%s' modifier cannot appear on a type member", modifier_name))
		}
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
				report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected '(' after type parameters in call signature")
				return nil
			}
		}
		params := parse_ts_sig_params(p)
		ret: Maybe(^TSTypeAnnotation)
		if is_token(p, .Colon) { ret = parse_ts_return_type_annotation(p) }
		call_sig := TSCallSignatureDeclaration{
			loc = start, type_parameters = type_params, params = params, return_type = ret,
		}
		call_sig.loc.end = prev_end_offset(p)
		sig := new_node(p, TSSignature); sig^ = call_sig; return sig
	}

	// --- NEW: detect construct signature `new (...): T` or `new <T>(...): T` -----
 ensure_nxt(p)
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
		ctor_sig.loc.end = prev_end_offset(p)
		sig := new_node(p, TSSignature); sig^ = ctor_sig; return sig
	}

	// Handle `readonly` modifier on a property / method / index signature.
	// `readonly` is a contextual keyword, NOT a reserved word, so the lexer
	// emits it as `.Identifier` with value "readonly" rather than a dedicated
	// token type — mirror the convention used elsewhere in this file (see the
	// comment at line ~18485 "`.Readonly` is not in the lexer").
	// Distinguish from a member literally named `readonly` (e.g. `readonly: T`,
	// `readonly?: T`, `readonly()`, `readonly;`, `readonly,`, `readonly}`,
	// or `readonly` followed by a newline).
	// Covers BOTH index-sig (`readonly [k: K]: V`) and ordinary property /
	// method members (`readonly _A: T`, `readonly m(): U`). The previous
	// implementation only matched `readonly [` which let the parser drop the
	// modifier and re-parse the property as a separate bare signature.
	if p.cur_type == .Identifier && cur_value_eq(p, "readonly") {
		readonly_is_modifier := false
  ensure_nxt(p)
		if (p.lexer.nxt.flags & FLAG_NEW_LINE) == 0 {
			#partial switch p.lexer.nxt.kind {
			case .LParen, .Question, .Colon, .Semi, .Comma, .RBrace:
				// `readonly` IS the member name — leave it alone.
			case:
				readonly_is_modifier = true
			}
		}
		if readonly_is_modifier {
   ensure_nxt(p)
			if p.lexer.nxt.kind == .LBracket {
				idx_readonly = true   // signal to the index-sig branch below
			} else {
				readonly = true
			}
			eat(p) // consume `readonly`
		}
	}

	// §A.5 - Invalid index signature forms: `[]`, `[...x]`, etc.
	// in type members. Detect and report before falling through.
 ensure_nxt(p)
	if is_token(p, .LBracket) && p.lexer.nxt.kind == .RBracket {
		// `[]: T` - empty index signature.
		report_error_coded(p, .K2070_RequiredFormOrBinding, "An index signature must have a parameter")
		eat(p) // `[`
		eat(p) // `]`
		if is_token(p, .Colon) { eat(p); _ = parse_ts_type(p) }
		call_decl := TSCallSignatureDeclaration{loc = start}
		call_decl.loc.end = prev_end_offset(p)
		sig := new_node(p, TSSignature); sig^ = call_decl
		return sig
	}
 ensure_nxt(p)
	if is_token(p, .LBracket) && p.lexer.nxt.kind == .Dot3 {
		// `[...x]: T` - spread in index signature.
		report_error_coded(p, .K4040_TSRestInvalid, "An index signature parameter cannot use a rest pattern")
		eat(p) // `[`
		for !is_token(p, .RBracket) && !is_token(p, .EOF) { eat(p) }
		if is_token(p, .RBracket) { eat(p) }
		if is_token(p, .Colon) { eat(p); _ = parse_ts_type(p) }
		call_decl2 := TSCallSignatureDeclaration{loc = start}
		call_decl2.loc.end = prev_end_offset(p)
		sig := new_node(p, TSSignature); sig^ = call_decl2
		return sig
	}
 ensure_nxt(p)
	if is_token(p, .LBracket) && p.lexer.nxt.kind == .Identifier {
		// Check if this is an index signature by peeking for `:` after the identifier.
		eat(p) // consume `[`.
		is_index_sig := false
		if is_token(p, .Identifier) {
			ensure_nxt(p)
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
			param_name_tok := snap_current(p)
			param_name_ident := new_node(p, Identifier)
			param_name_ident.loc = loc_from_token(&param_name_tok)
			param_name_ident.name = param_name_tok.value
			eat(p) // consume identifier
			if match_token(p, .Question) {
				report_error_coded(p, .K4063_OptionalAndInit, "An index signature parameter cannot have a question mark")
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
				report_error_coded(p, .K4055_IndexSignatureForm, "An index signature must have a type annotation")
			}

			idx_sig := TSIndexSignature{
				loc = start,
				parameters = make([dynamic]TSFunctionParam, 0, 1, p.allocator),
				type_annotation = val_ann,
				readonly = idx_readonly,
			}
			// Build the sole parameter with correct span: ends at key-type end.
			key_ann := new_node(p, TSTypeAnnotation)
			key_ann.loc.start = colon_start.start
			key_ann.loc.end   = key_type_end
			key_ann.type_annotation = idx_ann
			fp := TSFunctionParam{
				loc = param_start,
				pattern = param_name_ident,
				type_annotation = key_ann,
			}
			fp.loc.end = key_type_end
			bump_append(&idx_sig.parameters, fp)
			// Consume optional semi/comma inside the function so the span includes
			// the terminator (matching OXC). The caller also tries to match them
			// but match_token is idempotent when the token is already consumed.
			match_token(p, .Semi); match_token(p, .Comma)
			idx_sig.loc.end = prev_end_offset(p)

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
		// `[expr]<T>(): U` — generic computed-key method, same fix as the
		// non-computed path below. Match LAngle in addition to LParen.
		if is_token(p, .LParen) || is_token(p, .LAngle) {
			sig := new_node(p, TSSignature)
			method := TSMethodSignature{loc = start, key = key, computed = true, optional = optional, kind = .Method}
			if is_token(p, .LAngle) {
				method.type_parameters = parse_ts_type_parameters(p)
			}
			method.params = parse_ts_sig_params(p)
			if is_token(p, .Colon) { method.return_type = parse_ts_return_type_annotation(p) }
			method.loc.end = prev_end_offset(p)
			sig^ = method; return sig
		}

		// Property signature with computed property.
		sig := new_node(p, TSSignature)
		prop := TSPropertySignature{loc = start, key = key, computed = true, optional = optional, readonly = readonly}
		if is_token(p, .Colon) { prop.type_annotation = parse_ts_type_annotation(p) }
		prop.loc.end = prev_end_offset(p)
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
 ensure_nxt(p)
	if (p.lexer.nxt.flags & FLAG_NEW_LINE) == 0 {
		#partial switch p.lexer.nxt.kind {
		case .LParen, .Question, .Colon, .Semi, .Comma, .RBrace:
			// `get()`, `get?: T`, `set;` are members named get/set.
		case:
			nxt_allows_accessor = true
		}
	}
	if ((is_token(p, .Get) || is_token(p, .Set)) ||
	    (is_token(p, .Identifier) && (cur_value_eq(p, "get") || cur_value_eq(p, "set")))) &&
	   nxt_allows_accessor {
		accessor_kind := TSMethodSignatureKind.Get
		if is_token(p, .Set) || (is_token(p, .Identifier) && cur_value_eq(p, "set")) {
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
			cur := snap_current(p)
			id, id_e := new_expr(p, Identifier)
			id.loc = loc_from_token(&cur)
			id.name = cur.value
			accessor_key = id_e
			eat(p)
		} else if is_token(p, .String) {
			str := parse_string_literal(p)
			sn, sn_e := new_expr(p, StringLiteral)
			sn^ = str
			accessor_key = sn_e
		} else if is_token(p, .Number) {
			cur := snap_current(p)
			nm, nm_e := new_expr(p, NumericLiteral)
			nm.loc = loc_from_token(&cur)
			nm.raw = cur.value
			if v, ok := cur.literal.(f64); ok { nm.value = v }
			accessor_key = nm_e
			eat(p)
		} else {
			return nil
		}

		if is_token(p, .LAngle) {
			report_error_coded(p, .K4052_AccessorOrTypeParamForm, "An accessor cannot have type parameters")
			_ = parse_ts_type_parameters(p)
		}
		params := parse_ts_sig_params(p)
		if accessor_kind == .Get {
			if len(params) != 0 {
				report_error_coded(p, .K4061_GetSetForm, "A get accessor cannot have parameters")
			}
		} else {
			if len(params) != 1 {
				report_error_coded(p, .K2070_RequiredFormOrBinding, "A set accessor must have exactly one parameter")
			}
			if len(params) == 1 {
				if params[0].optional {
					report_error_coded(p, .K4061_GetSetForm, "A set accessor parameter cannot be optional")
				}
				if _, is_rest := params[0].pattern.(^RestElement); is_rest {
					report_error_coded(p, .K4040_TSRestInvalid, "A set accessor parameter cannot be a rest parameter")
				}
				if id, is_id := params[0].pattern.(^Identifier); is_id && id.name == "this" {
					report_error_coded(p, .K4061_GetSetForm, "A set accessor cannot have a this parameter")
				}
			}
		}
		ret: Maybe(^TSTypeAnnotation)
		if is_token(p, .Colon) {
			ret = parse_ts_return_type_annotation(p)
			if accessor_kind == .Set {
				report_error_coded(p, .K4052_AccessorOrTypeParamForm, "A set accessor cannot have a return type annotation")
			}
		}
		method := TSMethodSignature{
			loc = start, key = accessor_key, computed = accessor_computed,
			optional = false, kind = accessor_kind, params = params, return_type = ret,
		}
		method.loc.end = prev_end_offset(p)
		sig := new_node(p, TSSignature)
		sig^ = method
		return sig
	}

	// Parse key for method or property signature.
	key: ^Expression; computed := false
	if is_token(p, .LBracket) {
		computed = true; eat(p); key = parse_assignment_expression(p); expect_token(p, .RBracket)
	} else if is_token(p, .Identifier) || is_keyword_usable_as_property_name(p.cur_type) {
		cur := snap_current(p); id, id_e := new_expr(p, Identifier); id.loc = loc_from_token(&cur); id.name = cur.value
		key = id_e; eat(p)
	} else if is_token(p, .String) {
		str := parse_string_literal(p); sn := new_node(p, StringLiteral); sn^ = str; key = expression_from(p, sn)
	} else if is_token(p, .Number) {
		cur := snap_current(p); nm, nm_e := new_expr(p, NumericLiteral); nm.loc = loc_from_token(&cur); nm.raw = cur.value
		if v, ok := cur.literal.(f64); ok { nm.value = v }; key = nm_e; eat(p)
	} else { return nil }
	optional := match_token(p, .Question)

	// Method signature: key is followed by `(` (or `<` for generics).
	// Generic interface methods (`m<U>(): T;`, `m<T extends X>?(arg: T): T;`)
	// were previously misparsed as a bare `TSPropertySignature(m)` followed by
	// a separate `TSCallSignatureDeclaration(<U>(): T)`. Recognise the LAngle
	// here so the result is a single TSMethodSignature with type_parameters.
	if is_token(p, .LParen) || is_token(p, .LAngle) {
		// `readonly method(): T` — the `readonly` modifier is only valid on
		// PropertySignature and IndexSignature, not on MethodSignature.
		// TSC: TS1024. OXC: "'readonly' modifier can only appear on a
		// property declaration or index signature.".
		if readonly {
			report_error_coded(p, .K4032_ModifierMisplaced, "'readonly' modifier can only appear on a property declaration or index signature")
		}
		sig := new_node(p, TSSignature)
		method := TSMethodSignature{loc = start, key = key, computed = computed, optional = optional, kind = .Method}
		if is_token(p, .LAngle) {
			method.type_parameters = parse_ts_type_parameters(p)
		}
		method.params = parse_ts_sig_params(p)
		if is_token(p, .Colon) { method.return_type = parse_ts_return_type_annotation(p) }
		method.loc.end = prev_end_offset(p)
		sig^ = method; return sig
	}

	// Property signature.
	sig := new_node(p, TSSignature)
	prop := TSPropertySignature{loc = start, key = key, computed = computed, optional = optional, readonly = readonly}
	if is_token(p, .Colon) { prop.type_annotation = parse_ts_type_annotation(p) }
	prop.loc.end = prev_end_offset(p)
	sig^ = prop; return sig
}

get_ts_type_loc :: proc(t: ^TSType) -> ^Loc {
	if t == nil { return nil }
	#partial switch v in t^ {
	case ^TSKeywordType: return &v.loc
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
	// TS1038 — "`declare` cannot be used in an already ambient context."
	// Inside `declare namespace/module`, every declaration is implicitly
	// ambient. An explicit `declare` on a child is redundant. Only
	// fire for in_ambient (set by enclosing declare namespace/module),
	// NOT for source_is_dts — .d.ts files commonly use top-level
	// `declare` despite being implicitly ambient, and OXC accepts them.
	if p.ctx.in_ambient {
		report_error_coded(p, .K4032_ModifierMisplaced, "A 'declare' modifier cannot be used in an already ambient context")
	}

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
	prev_ambient := p.ctx.in_ambient
	p.ctx.in_ambient = true
	defer p.ctx.in_ambient = prev_ambient

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
  ensure_nxt(p)
		if p.lexer.nxt.kind == .Function && !cur_has_newline(p) {
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
  ensure_nxt(p)
		if p.lexer.nxt.kind == .Class {
			if (p.lexer.nxt.flags & FLAG_NEW_LINE) != 0 {
				report_error_coded(p, .K4034_AbstractNewline, "Line terminator not permitted between 'abstract' and 'class'")
			}
			eat(p) // consume `abstract`
			prev_abs := p.ctx.class_is_abstract
			p.ctx.class_is_abstract = true
			stmt = parse_class_declaration(p)
			p.ctx.class_is_abstract = prev_abs  // prevent leak
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
  ensure_nxt(p)
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
		val := cur_value(p)
		switch val {
		case "interface":
			// Newline between `interface` and its name triggers ASI.
			// `declare interface\nFoo {}` → error. OXC / TSC agree.
   ensure_nxt(p)
			if (p.lexer.nxt.flags & FLAG_NEW_LINE) != 0 {
				report_error_coded(p, .K4051_TSDeclarationStructure, "Line terminator not permitted after 'interface'")
			}
			stmt = parse_ts_interface_declaration(p)
			if stmt != nil {
				if id, ok := stmt^.(^TSInterfaceDeclaration); ok { id.declare = true }
			}
		case "type":
			// Newline between `type` and its name triggers ASI.
   ensure_nxt(p)
			if (p.lexer.nxt.flags & FLAG_NEW_LINE) != 0 {
				report_error_coded(p, .K3064_LineTerminatorRestricted, "Line terminator not permitted after 'type'")
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
   ensure_nxt(p)
			if (p.lexer.nxt.flags & FLAG_NEW_LINE) != 0 {
				report_error_coded(p, .K4051_TSDeclarationStructure, "Line terminator not permitted after 'namespace'")
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
   ensure_nxt(p)
			if (p.lexer.nxt.flags & FLAG_NEW_LINE) != 0 {
				report_error_coded(p, .K3064_LineTerminatorRestricted, "Line terminator not permitted after 'module'")
			}
   ensure_nxt(p)
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
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected declaration after 'declare'")
		return stmt
	}

	// Widen the resulting declaration's span so it starts at `declare`.
	// Every declaration variant returned above carries its own `loc` on the
	// inner pointer; find and overwrite span.start in place.
	#partial switch inner in stmt^ {
	case ^FunctionDeclaration:    inner.loc.start = declare_start
	case ^ClassDeclaration:       inner.expr.loc.start = declare_start
	case ^VariableDeclaration:    inner.loc.start = declare_start
	case ^TSEnumDeclaration:      inner.loc.start = declare_start
	case ^TSInterfaceDeclaration: inner.loc.start = declare_start
	case ^TSTypeAliasDeclaration: inner.loc.start = declare_start
	case ^TSModuleDeclaration:    inner.loc.start = declare_start
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
		tok := snap_current(p)
		id, id_e := new_expr(p, Identifier); id.loc = loc_from_token(&tok); id.name = tok.value; eat(p)
		expr := id_e
		for is_token(p, .Dot) {
			eat(p)
			prop := parse_identifier_name(p)
			mem := new_node(p, MemberExpression); mem.loc = entry_start; mem.object = expr
			pid, pid_e := new_expr(p, Identifier); pid.loc = prop.loc; pid.name = prop.name
			mem.property = pid_e; mem.loc.end = prev_end_offset(p)
			expr = expression_from(p, mem)
		}
		type_args: Maybe(^TSTypeParameterInstantiation)
		if is_open_angle_or_lshift(p) { type_args = parse_ts_type_arguments(p) }
		entry_end := prev_end_offset(p)
		h := TSInterfaceHeritage{
			loc = Loc{start = entry_start.start, end = entry_end},
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
	cur := snap_current(p)
	id := BindingIdentifier{loc = loc_from_token(&cur), name = cur.value}
	check_strict_ts_decl_name(p, id.name, id.loc)
	check_ts_primitive_decl_name(p, "Interface", id.name, id.loc)
	eat(p)
	type_parameters: Maybe(^TSTypeParameterDeclaration)
	if is_token(p, .LAngle) { type_parameters = parse_ts_type_parameters(p) }
	extends_list: [dynamic]TSInterfaceHeritage
	if match_token(p, .Extends) {
		extends_list = parse_ts_heritage_list(p)
		if len(extends_list) == 0 {
			report_error_coded(p, .K4051_TSDeclarationStructure, "Expected interface name after 'extends'")
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
	report_duplicate_interface_member_errors(p, members[:])
	decl := new_node(p, TSInterfaceDeclaration); decl.loc = start; decl.id = id; decl.type_parameters = type_parameters
	decl.extends = extends_list
	decl.body = TSInterfaceBody{loc = body_start, body = members}; decl.body.loc.end = prev_end_offset(p)
	decl.loc.end = prev_end_offset(p)
	stmt := new_node(p, Statement); stmt^ = decl; return stmt
}

parse_ts_type_alias_declaration :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p); eat(p)
	cur := snap_current(p)
	id := BindingIdentifier{loc = loc_from_token(&cur), name = cur.value}
	check_strict_ts_decl_name(p, id.name, id.loc)
	check_ts_primitive_decl_name(p, "Type alias", id.name, id.loc)
	eat(p)
	type_parameters: Maybe(^TSTypeParameterDeclaration)
	if is_token(p, .LAngle) { type_parameters = parse_ts_type_parameters(p) }
	// TS1277 — `const` modifier on type parameters is only allowed in
	// function/method/constructor declarations, not type aliases.
	if tp, have := type_parameters.?; have && tp != nil {
		for &param in tp.params {
			if param.const_ {
				report_error_coded_span(p, .K4032_ModifierMisplaced, u32(param.loc.start), u32(param.loc.start), "'const' modifier can only appear on a type parameter of a function, method or class")
			}
		}
	}
	expect_token(p, .Assign)
	type_ann := parse_ts_type(p)
	if type_ann == nil {
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected type annotation after '='")
	}
	match_semicolon_or_asi(p)
	decl := new_node(p, TSTypeAliasDeclaration); decl.loc = start; decl.id = id; decl.type_parameters = type_parameters; decl.type_annotation = type_ann
	decl.loc.end = prev_end_offset(p)
	stmt := new_node(p, Statement); stmt^ = decl; return stmt
}

parse_ts_enum_declaration :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	is_const := false
	if is_token(p, .Const) { is_const = true; eat(p) }
	eat(p)
	cur := snap_current(p)
	if !can_be_binding_identifier(p.cur_type) {
		report_error_coded(p, .K3053_ReservedAsBindingIdentifier,
			fmt.tprintf("Identifier expected. '%s' is a reserved word that cannot be used here", cur.value))
	}
	id := BindingIdentifier{loc = loc_from_token(&cur), name = cur.value}
	check_strict_ts_decl_name(p, id.name, id.loc)
	check_ts_primitive_decl_name(p, "Enum", id.name, id.loc)
	eat(p)
	body_start := cur_loc(p); expect_token(p, .LBrace)
	members := make([dynamic]TSEnumMember, 0, 8, p.allocator)
	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		// Reject empty enum member positions: `enum E { , }`.
		if is_token(p, .Comma) {
			report_error_coded(p, .K4054_EnumInvalid, "Expected enum member name")
			eat(p)
			continue
		}
		// Private names are not valid enum member names.
		if is_token(p, .PrivateIdentifier) {
			report_error_coded(p, .K3032_PrivateNameInvalid, "An enum member cannot have a private name")
		}
		ms := cur_loc(p); member_id: ^Expression; mc := snap_current(p)
		if is_token(p, .String) {
			str := parse_string_literal(p); sn := new_node(p, StringLiteral); sn^ = str; member_id = expression_from(p, sn)
		} else if is_token(p, .Number) || is_token(p, .BigInt) {
			report_error_coded(p, .K4054_EnumInvalid, "An enum member cannot have a numeric name")
			mid := new_node(p, Identifier); mid.loc = loc_from_token(&mc); mid.name = mc.value; eat(p)
			member_id = expression_from(p, mid)
		} else if is_token(p, .LBracket) {
			// Computed enum member names. OXC accepts `['baz']` (string
			// literal in brackets) because a computed enum member with a
			// static string key is indistinguishable (at parse time) from
			// a regular named enum member. OXC rejects every other
			// computed form (`[foo]`, `[1]`, `` [`test${foo}`] ``,
			// `['baz' + 'baz']`) with "Computed property names are not
			// allowed in enums" (TS1164). Mirror that two-part rule.
			eat(p) // consume `[`
			inner := parse_assignment_expression(p)
			expect_token(p, .RBracket)
			// Only `['literal']` and `` [`no-expr`] `` (template literal with
			// zero interpolations) escape the rejection. Both produce a
			// static, known-at-compile-time string key indistinguishable
			// from a regular named enum member.
			if inner != nil {
				is_static := false
				if _, is_str := inner^.(^StringLiteral); is_str {
					is_static = true
				} else if tmpl, is_tmpl := inner^.(^TemplateLiteral); is_tmpl && len(tmpl.expressions) == 0 {
					is_static = true
				}
				if !is_static {
					report_error_coded(p, .K4054_EnumInvalid, "Computed property names are not allowed in enums")
				}
				member_id = inner
			} else {
				mid := new_node(p, Identifier); mid.loc = ms; mid.name = ""
				member_id = expression_from(p, mid)
			}
		} else if is_token(p, .Template) || is_token(p, .TemplateHead) {
			// Template literals are not valid enum member names.
			report_error_coded(p, .K4054_EnumInvalid, "Enum member expected")
			member_id = parse_template_literal(p, false)
		} else {
			mid := new_node(p, Identifier); mid.loc = loc_from_token(&mc); mid.name = mc.value; eat(p)
			member_id = expression_from(p, mid)
		}
		init: Maybe(^Expression)
		if match_token(p, .Assign) {
			prev_in_async := p.ctx.in_async
			prev_in_generator := p.ctx.in_generator
			p.ctx.in_async = false
			p.ctx.in_generator = false
			init = parse_assignment_expression(p)
			p.ctx.in_generator = prev_in_generator
			p.ctx.in_async = prev_in_async
		}
		m := TSEnumMember{loc = ms, id = member_id, initializer = init}; m.loc.end = prev_end_offset(p)
		bump_append(&members, m)
		if !match_token(p, .Comma) { break }
	}
	expect_token(p, .RBrace)

	// TS2300 — duplicate enum member names.
	{
		seen_names: map[string]bool
		seen_names.allocator = context.temp_allocator
		for m in members {
			if m.id == nil { continue }
			name := class_element_prop_name(m.id)
			if name == "" { continue }
			if name in seen_names {
				loc := u32(0)
				if id, ok := m.id^.(^Identifier); ok && id != nil { loc = id.loc.start }
				else if sl, ok2 := m.id^.(^StringLiteral); ok2 && sl != nil { loc = sl.loc.start }
				msg := fmt.tprintf("Duplicate identifier '%s'.", name)
				report_error_coded_span(p, .K3037_DuplicateIdentifier, u32(loc), u32(loc), msg)
			}
			seen_names[name] = true
		}
	}

	// TS1061 — enum member without initializer following a member with
	// a non-literal (computed) initializer. In a non-ambient context,
	// the auto-increment only works after literal values.
	if !p.ctx.in_ambient && !p.source_is_dts && !is_const {
		// Collect member names for self-reference detection.
		member_names: map[string]bool
		member_names.allocator = context.temp_allocator
		for m in members {
			if m.id == nil { continue }
			n := class_element_prop_name(m.id)
			if n != "" { member_names[n] = true }
		}
		prev_needs_init := false
		for m in members {
			if _, have := m.initializer.?; have {
				init := m.initializer.(^Expression)
				is_constant := ts_enum_init_is_constant(init, &member_names)
				prev_needs_init = !is_constant
			} else {
				if prev_needs_init {
					loc := u32(0)
					if m.id != nil {
						if id, ok := m.id^.(^Identifier); ok && id != nil { loc = id.loc.start }
					}
					report_error_coded_span(p, .K2070_RequiredFormOrBinding, u32(loc), u32(loc), "Enum member must have initializer.")
				}
				prev_needs_init = false
			}
		}
	}

	decl := new_node(p, TSEnumDeclaration); decl.loc = start; decl.id = id
	decl.body = TSEnumBody{loc = body_start, members = members}; decl.body.loc.end = prev_end_offset(p)
	decl.const_ = is_const; decl.loc.end = prev_end_offset(p)
	stmt := new_node(p, Statement); stmt^ = decl; return stmt
}

// `declare global { ... }`. Caller has already eaten `declare`; current
// token is the identifier `global` and the lookahead has confirmed `{`.
// Produces a TSModuleDeclaration with kind=.Global and id=Identifier{"global"}.
// Body parsing mirrors parse_ts_module_declaration's brace-block branch
// (ambient context, progress-guarded statement loop, span widening).
parse_ts_global_declaration :: proc(p: ^Parser) -> ^Statement {
	start := cur_loc(p)
	cur := snap_current(p)
	id_ident, id_ident_e := new_expr(p, Identifier); id_ident.loc = loc_from_token(&cur); id_ident.name = cur.value
	eat(p) // consume `global`

	decl := new_node(p, TSModuleDeclaration)
	decl.loc = start
	decl.id = id_ident_e
	decl.kind = .Global

	// TS2669 — `declare global {}` is only valid at the top level of a
	// module file or inside an ambient module declaration.
	// Inside a namespace, inside a function, or in a script → error.
	if allow_ts_mode(p) && !p.source_is_dts {
		global_ok := false
		if p.ctx.in_ambient {
			global_ok = true
		} else if !p.ctx.in_ts_namespace && !p.ctx.in_function {
			global_ok = true
		}
		if !global_ok {
			report_error_coded_span(p, .K4050_AmbientContextRestriction, u32(start.start), u32(start.start), "Augmentations for the global scope can only be directly nested in external modules or ambient module declarations")
		}
	}

	body_start := cur_loc(p); eat(p) // consume `{` (lookahead-confirmed)
	stmts := make([dynamic]^Statement, 0, 8, p.allocator)
	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		// Same progress guard as parse_ts_module_declaration 
		prev_offset := int(cur_offset(p))
		s := parse_statement_or_declaration(p)
		if s != nil { bump_append(&stmts, s) }
		else if int(cur_offset(p)) == prev_offset {
			msg := fmt.tprintf("Unexpected token '%s' in module body", cur_value(p))
			report_error_coded(p, .K2040_UnexpectedToken, msg)
			recovery_eat(p)
		}
	}
	expect_token(p, .RBrace)
	blk := new_node(p, TSModuleBlock)
	blk.loc = body_start; blk.body = stmts
	blk.loc.end = prev_end_offset(p)
	if allow_ts_mode(p) {
		if p.ctx.in_ambient || p.source_is_dts {
			report_ts_ambient_function_errors(p, stmts[:])
		} else {
			report_ts_function_overload_errors(p, stmts[:])
		}
		// TS2309 — `export =` inside module bodies.
		report_ts2309_export_assignment(p, stmts[:])
	}
	body_union := new_node(p, TSModuleBody); body_union^ = blk
	decl.body = body_union
	decl.loc.end = prev_end_offset(p)
	stmt := new_node(p, Statement); stmt^ = decl; return stmt
}

parse_ts_module_declaration :: proc(p: ^Parser, kind: TSModuleKind) -> ^Statement {
	start := cur_loc(p)
	// TS1235 — namespace/module declarations are only allowed at the
	// top level of a file, namespace, or module body. Inside a block,
	// function body, class body, etc. they're a SyntaxError.
	// Valid positions: program top-level, or inside a namespace body.
	if allow_ts_mode(p) && (p.block_depth > 0 || p.ctx.in_function) && !p.ctx.in_ts_namespace {
		report_error_coded_span(p, .K4051_TSDeclarationStructure, u32(start.start), u32(start.start), "A namespace declaration is only allowed at the top level of a namespace or module")
	}
	eat(p) // consume `namespace` or `module`

	// Name: Identifier (possibly dotted) or StringLiteral.
	// A string-named `module "x" { ... }` is ALWAYS an ambient declaration
	// (per TS semantics): every declaration inside behaves as if prefixed
	// with `declare`. Track this so parse_variable_declarator and
	// parse_function_declaration can relax their body / initializer
	// requirements for the duration of the body scan.
	is_string_named := is_token(p, .String)
	// TS1199 — `module M {}` with an identifier name (not string literal)
	// without `declare` is deprecated. Must use `namespace M {}` instead.
	// `declare module M {}` is valid (standard ambient namespace syntax).
	// Also exempt .d.ts files where everything is implicitly ambient.
	if kind == .Module && !is_string_named && !p.ctx.in_ambient && !p.source_is_dts {
		report_error_coded_span(p, .K4051_TSDeclarationStructure, u32(start.start), u32(start.start), "`module` declarations must have a string name. Use `namespace` instead")
	}
	id_expr: ^Expression
	if is_string_named {
		lit := parse_string_literal(p)
		sn, sn_e := new_expr(p, StringLiteral); sn^ = lit
		id_expr = sn_e
	} else {
		cur := snap_current(p)
		id_ident, id_ident_e := new_expr(p, Identifier); id_ident.loc = loc_from_token(&cur); id_ident.name = cur.value
		check_strict_ts_decl_name(p, id_ident.name, id_ident.loc)
		eat(p)
		id_expr = id_ident_e
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
		outer.loc.end = prev_end_offset(p)
		stmt := new_node(p, Statement); stmt^ = outer; return stmt
	}

	// Optional body `{ ... }`. A `declare` context can elide it (`declare namespace X;`),
	// but otherwise the block is required.
	decl := new_node(p, TSModuleDeclaration)
	decl.loc = start; decl.id = id_expr; decl.kind = kind
	if !is_token(p, .LBrace) && !p.ctx.in_ambient {
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected `{` but found `;`")
	}
	if is_token(p, .LBrace) {
		body_start := cur_loc(p); eat(p) // consume `{`
		// Ambient context: string-named module, OR already-ambient caller
		// (nested namespace / module inside a `declare namespace X { ... }`),
		// OR .d.ts file (all bodies are implicitly ambient).
		prev_ambient := p.ctx.in_ambient
		p.ctx.in_ambient = p.ctx.in_ambient || is_string_named || p.source_is_dts
		defer p.ctx.in_ambient = prev_ambient
		// TS namespace body is not an async/module-level context for `await`.
		prev_in_ts_namespace := p.ctx.in_ts_namespace
		p.ctx.in_ts_namespace = true
		defer p.ctx.in_ts_namespace = prev_in_ts_namespace
		// Track whether we're in a string-named module body (ES imports/exports valid)
		// vs an identifier-named namespace body (ES imports/exports forbidden).
		prev_in_ts_module_block := p.ctx.in_ts_module_block
		p.ctx.in_ts_module_block = is_string_named
		defer p.ctx.in_ts_module_block = prev_in_ts_module_block
		stmts := make([dynamic]^Statement, 0, 8, p.allocator)
		for !is_token(p, .RBrace) && !is_token(p, .EOF) {
			// Progress guard: when parse_statement_or_declaration hits an
			// unsupported TS form (e.g. `import X = Y;` import-equals) it can
			// return nil without advancing. Mirror parse_program_item's
			// recovery: report the offending token, force-eat one. Without
			// this, a single `import X = Y;` inside `namespace M { ... }`
			// loops the parser forever (			// alone closed 146 typescript/compiler timeouts).
			prev_offset := int(cur_offset(p))
			s := parse_statement_or_declaration(p)
			if s != nil { bump_append(&stmts, s) }
			else if int(cur_offset(p)) == prev_offset {
				msg := fmt.tprintf("Unexpected token '%s' in module body", cur_value(p))
				report_error_coded(p, .K2040_UnexpectedToken, msg)
				recovery_eat(p)
			}
		}
		expect_token(p, .RBrace)
		blk := new_node(p, TSModuleBlock)
		blk.loc = body_start; blk.body = stmts
		blk.loc.end = prev_end_offset(p)
		if allow_ts_mode(p) {
			if p.ctx.in_ambient || p.source_is_dts {
				report_ts_ambient_function_errors(p, stmts[:])
			} else {
				report_ts_function_overload_errors(p, stmts[:])
			}
		}
		body_union := new_node(p, TSModuleBody)
		body_union^ = blk
		decl.body = body_union
	}
	decl.loc.end = prev_end_offset(p)
	stmt := new_node(p, Statement); stmt^ = decl; return stmt
}

// Parse the name + body portion of a nested namespace declaration.
// Called AFTER the outer `.` is consumed, so current token is the next name.
parse_ts_module_tail :: proc(p: ^Parser, start: Loc, kind: TSModuleKind) -> ^TSModuleDeclaration {
	cur := snap_current(p)
	id_ident, id_ident_e := new_expr(p, Identifier); id_ident.loc = loc_from_token(&cur); id_ident.name = cur.value
	check_strict_ts_decl_name(p, id_ident.name, id_ident.loc)
	eat(p)
	id_expr := id_ident_e

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
		prev_ambient := p.ctx.in_ambient
		defer p.ctx.in_ambient = prev_ambient
		// Also propagate in_ts_namespace into the nested body. Without
		// this, `namespace Outer.Inner { export const X = 1 }` would let
		// the `export` decision run with in_ts_namespace=false and
		// incorrectly classify the file as sourceType=module. The outer
		// parse_ts_module_declaration sets the flag for the SINGLE-name
		// case but the dotted-name path skips it.
		prev_in_ts_namespace := p.ctx.in_ts_namespace
		p.ctx.in_ts_namespace = true
		defer p.ctx.in_ts_namespace = prev_in_ts_namespace
		// Nested namespace bodies (dotted names) are never string-named modules.
		prev_in_ts_module_block := p.ctx.in_ts_module_block
		p.ctx.in_ts_module_block = false
		defer p.ctx.in_ts_module_block = prev_in_ts_module_block
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
				report_error_coded(p, .K2040_UnexpectedToken, msg)
				recovery_eat(p)
			}
		}
		expect_token(p, .RBrace)
		blk := new_node(p, TSModuleBlock)
		blk.loc = body_start; blk.body = stmts
		blk.loc.end = prev_end_offset(p)
		if allow_ts_mode(p) {
			if p.ctx.in_ambient || p.source_is_dts {
				report_ts_ambient_function_errors(p, stmts[:])
			} else {
				report_ts_function_overload_errors(p, stmts[:])
			}
		}
		body_union := new_node(p, TSModuleBody)
		body_union^ = blk
		decl.body = body_union
	}
	decl.loc.end = prev_end_offset(p)
	return decl
}

