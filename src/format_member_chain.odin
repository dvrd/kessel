package kessel

// Chains of member accesses and calls such as `a.b().c().d()`. The chain is
// flattened into its links, the links are grouped so that each call stays
// with the accesses before it, and the groups print either on one line or
// one per line. A port of Prettier's member-chain rules.

@(private = "file")
FormatChainLink :: struct {
	node:                    ^Expression,
	printed:                 Doc,
	needs_parens:            bool,
	has_trailing_empty_line: bool,
	is_call:                 bool,
	is_member:               bool,
	is_computed_literal:     bool, // `[0]`, which stays with the link before it.
}

// A blank line after a link survives. A closing parenthesis right after the
// link belongs to it, so the search continues past that parenthesis.
@(private = "file")
format_chain_empty_line_after :: proc(f: ^FormatContext, expr: ^Expression) -> bool {
	end := get_expression_loc(expr).end
	next := format_next_code_index(f.source, end)
	if next < len(f.source) && f.source[next] == ')' {
		return format_is_next_line_empty(f.source, u32(next + 1))
	}
	return format_is_next_line_empty(f.source, end)
}

// Collects the links from the innermost object outwards. The path holds the
// link being collected, so that its pieces print in their real context.
@(private = "file")
format_chain_collect :: proc(
	f: ^FormatContext,
	links: ^[dynamic]FormatChainLink,
	expr: ^Expression,
	key: FormatKey,
) {
	inner, entered := format_expr_enter(f, expr, key)
	if !entered {return}
	defer format_path_pop(f)
	#partial switch node in inner^ {
	case ^CallExpression:
		if format_is_member(node.callee) || format_is_call(node.callee) {
			if _, typed := node.type_parameters.?; typed {f.failed = true}
			// The chain's own parentheses rules cover only its head.
			if format_needs_parens(f) {f.failed = true}
			format_chain_collect(f, links, node.callee, .Callee)
			empty_line := format_chain_empty_line_after(f, inner)
			printed := fc(
				f,
				ft(f, "?.") if node.optional else nil,
				format_call_arguments(f, format_call_parts(f, inner)),
				doc_hardline() if empty_line else nil,
			)
			link := FormatChainLink {
				node                    = inner,
				printed                 = printed,
				has_trailing_empty_line = empty_line,
				is_call                 = true,
			}
			append(links, link)
			return
		}
	case ^MemberExpression:
		needs_parens := format_needs_parens(f)
		format_chain_collect(f, links, node.object, .Object)
		link := FormatChainLink {
			node         = inner,
			printed      = format_member_lookup(f, node),
			needs_parens = needs_parens,
			is_member    = true,
		}
		if node.computed {
			property := format_expr_unwrap(node.property)
			if property != nil {
				_, link.is_computed_literal = property^.(^NumericLiteral)
			}
		}
		append(links, link)
		return
	case ^TSNonNullExpression:
		f.failed = true
		return
	}
	_, is_call := inner^.(^CallExpression)
	head := FormatChainLink{node = inner, printed = format_expr_entered(f), is_call = is_call}
	append(links, head)
}

@(private = "file")
format_chain_is_factory :: proc(name: string) -> bool {
	if len(name) == 0 {return false}
	if name[0] >= 'A' && name[0] <= 'Z' {return true}
	for char in name {
		if char != '$' && char != '_' {return false}
	}
	return true
}

@(private = "file")
format_chain_print_group :: proc(f: ^FormatContext, group: []FormatChainLink) -> Doc {
	if len(group) == 0 {return nil}
	parts := make([]Doc, len(group), f.alloc)
	for link, index in group {parts[index] = link.printed}
	if group[len(group) - 1].needs_parens {
		return fc(f, ft(f, "("), fc(f, ..parts), ft(f, ")"))
	}
	return fc(f, ..parts)
}

// The first group is the computation's head: the first link plus the calls
// and literal indexes directly on it and, when it is not a call, the
// accesses up to the one before the first call.
@(private = "file")
format_chain_groups :: proc(
	f: ^FormatContext,
	links: []FormatChainLink,
) -> [dynamic][]FormatChainLink {
	groups := make([dynamic][]FormatChainLink, f.alloc)
	index := 1
	for index < len(links) {
		link := links[index]
		if !link.is_call && !link.is_computed_literal {break}
		index += 1
	}
	if !links[0].is_call {
		for index + 1 < len(links) {
			if !links[index].is_member || !links[index + 1].is_member {break}
			index += 1
		}
	}
	append(&groups, links[:index])
	start := index
	seen_call := false
	for index < len(links) {
		link := links[index]
		if seen_call && link.is_member {
			if !link.is_computed_literal {
				append(&groups, links[start:index])
				start = index
				seen_call = false
			}
		}
		if link.is_call {seen_call = true}
		if _, is_import := link.node^.(^ImportExpression); is_import {seen_call = true}
		index += 1
	}
	if start < len(links) {append(&groups, links[start:])}
	return groups
}

// A short or capitalised head, as in `z.object()` or `Object.keys()`, keeps
// the first call on its line.
@(private = "file")
format_chain_should_merge :: proc(
	f: ^FormatContext,
	groups: [][]FormatChainLink,
	statement_level: bool,
) -> bool {
	if len(groups) < 2 || len(groups[1]) == 0 {return false}
	has_computed := false
	if member, is_member := groups[1][0].node^.(^MemberExpression); is_member {
		has_computed = member.computed
	}
	head := groups[0]
	if len(head) == 1 {
		#partial switch node in head[0].node^ {
		case ^ThisExpression:
			return true
		case ^Identifier:
			if format_chain_is_factory(node.name) || has_computed {return true}
			return statement_level && len(node.name) <= int(f.options.tab_width)
		}
		return false
	}
	member, is_member := head[len(head) - 1].node^.(^MemberExpression)
	if !is_member || member.property == nil {return false}
	property, named := member.property^.(^Identifier)
	return named && (format_chain_is_factory(property.name) || has_computed)
}

format_member_chain :: proc(f: ^FormatContext, expr: ^Expression) -> Doc {
	call := expr^.(^CallExpression)
	statement_level := format_parent(f).kind == .Expression_Statement
	links := make([dynamic]FormatChainLink, f.alloc)
	format_chain_collect(f, &links, call.callee, .Callee)
	top := fc(
		f,
		ft(f, "?.") if call.optional else nil,
		format_call_arguments(f, format_call_parts(f, expr)),
	)
	append(&links, FormatChainLink{node = expr, printed = top, is_call = true})
	if f.failed {return nil}

	groups := format_chain_groups(f, links[:])
	should_merge := format_chain_should_merge(f, groups[:], statement_level)
	printed_groups := make([]Doc, len(groups), f.alloc)
	any_trailing_empty_line := false
	for group, index in groups {
		printed_groups[index] = format_chain_print_group(f, group)
		if group[len(group) - 1].has_trailing_empty_line {any_trailing_empty_line = true}
	}
	one_line := fc(f, ..printed_groups)
	cutoff := 3 if should_merge else 2
	if len(groups) <= cutoff && !any_trailing_empty_line {
		if format_is_long_curried(f) {return one_line}
		return doc_group(f, one_line)
	}

	// The head's last link may be followed by a blank line in the source.
	head_last := groups[1 if should_merge else 0]
	head_node := head_last[len(head_last) - 1]
	empty_after_head := !head_node.is_call && format_chain_empty_line_after(f, head_node.node)
	rest_start := 2 if should_merge else 1
	rest := doc_join(f, doc_hardline(), printed_groups[rest_start:])
	expanded := fc(
		f,
		printed_groups[0],
		printed_groups[1] if should_merge else nil,
		doc_hardline() if empty_after_head else nil,
		fi(f, doc_hardline(), rest) if rest != nil else nil,
	)

	call_count := 0
	any_complex_arguments := false
	function_argument_before_last := false
	for link, index in links {
		if !link.is_call {continue}
		call_count += 1
		node, is_call := link.node^.(^CallExpression)
		if !is_call {continue}
		for argument in node.arguments {
			if !format_is_simple_call_argument(argument) {any_complex_arguments = true}
			if index < len(links) - 1 && format_is_function(argument) {
				function_argument_before_last = true
			}
		}
	}
	must_expand := call_count > 2 && any_complex_arguments
	for doc in printed_groups[:len(printed_groups) - 1] {
		must_expand = must_expand || doc_will_break(doc)
	}
	last_group := groups[len(groups) - 1]
	if last_group[len(last_group) - 1].is_call &&
	   doc_will_break(printed_groups[len(printed_groups) - 1]) &&
	   function_argument_before_last {
		must_expand = true
	}
	result: Doc
	if must_expand {
		result = doc_group(f, expanded)
	} else {
		result = fc(
			f,
			doc_break_parent() if doc_will_break(one_line) || empty_after_head else nil,
			doc_conditional_group(f, {one_line, expanded}),
		)
	}
	return doc_label(f, .Member_Chain, result)
}
