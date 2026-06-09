package kessel

import "core:fmt"
import "core:strings"

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

