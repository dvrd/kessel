package kessel

@(require) import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import mvirtual "core:mem/virtual"

// ============================================================================
// Regular expression tree builder (ES2025 §22.2.1 plus Annex B.1.2).
//
// The builder is a strict parser of the whole pattern grammar: it produces a
// tree exactly when `new RegExp(pattern, flags)` would compile. It does not
// lean on the validator in regex.odin, which is a fast approximation for the
// lexer. The dependency runs the other way: regex_validate_literal asks
// regex_pattern_verdict below whenever the approximation is not enough.
//
// The grammar is spread over three files:
//   regex_ast.odin         disjunctions, groups, group names, quantifiers
//   regex_ast_escape.odin  atoms and escapes
//   regex_ast_class.odin   character classes, including `v`-mode set notation
//
// Nothing here recurses. Groups and nested classes use explicit frame stacks
// with a fixed depth, so stack use is bounded for any input.
// ============================================================================

RegexAstKind :: enum {
	Pattern, Alternative, Group, Character_Class, Character, Dot,
	Start_Assertion, End_Assertion, Boundary_Assertion,
	Character_Class_Escape, Property_Escape, Escape, Indexed_Reference,
	Named_Reference, Quantifier,
	Class_Range, Class_Intersection, Class_Subtraction, Class_String,
}

RegexGroupKind :: enum {
	Capture, Named_Capture, Noncapturing, Lookahead, Negative_Lookahead,
	Lookbehind, Negative_Lookbehind, Modifiers,
}

RegexAstFlag :: enum {
	Indices, Global, Ignore_Case, Multiline, Dot_All, Unicode, Unicode_Sets, Sticky,
}
RegexAstFlags :: bit_set[RegexAstFlag]

RegexRepeatBound :: struct {
	value: u64,
	digits: Loc,
	overflow: bool,
}

RegexRepeat :: struct {
	min: RegexRepeatBound,
	max: Maybe(RegexRepeatBound),
	greedy: bool,
}

// Flags a modifier group switches for its body: `(?i-m:…)` adds Ignore_Case
// and removes Multiline. Only Ignore_Case, Multiline and Dot_All can appear.
RegexModifiers :: struct {
	add, remove: RegexAstFlags,
}

RegexClassRelation :: enum { Union, Intersection, Subtraction }

RegexAstNode :: struct {
	kind: RegexAstKind,
	span: Loc,
	first_child, next_sibling: u32,
	group_kind: RegexGroupKind,
	capture_index: u32,
	// Group name, reference name, property name, `\q{…}` body, or the flag
	// letters of a modifier group.
	name: Loc,
	property_value: Maybe(Loc),
	code_point: Maybe(u32),
	negative: bool,
	may_contain_strings: bool,
	repeat: RegexRepeat,
	modifiers: RegexModifiers,
	// How the members of a `v`-mode class combine. Always Union otherwise.
	class_relation: RegexClassRelation,
}

RegexAst :: struct {
	// Nodes use index zero for an absent link. Root points to the Pattern.
	nodes: [dynamic]RegexAstNode,
	root: u32,
	flags: RegexAstFlags,
	capture_count: u32,
	has_named_captures: bool,
}

RegexAstErrorKind :: enum {
	None, Invalid_Pattern, Invalid_Flags, Source_Too_Large, Depth_Limit, Allocation_Error,
}

RegexAstError :: struct {
	kind: RegexAstErrorKind,
	offset: u32,
	message: string,
}

// Groups and `v`-mode classes may each nest this deep.
REGEX_AST_DEPTH_MAX :: 256

RegexAstFrame :: struct {
	container, alternative, previous_term, last_term: u32,
}

// Parse state shared by the three grammar files.
@(private)
RegexAstParser :: struct {
	ast: ^RegexAst,
	pattern: string,
	unicode: bool,      // `u` or `v`: the grammar's UnicodeMode parameter
	unicode_sets: bool, // `v`: UnicodeSetsMode
	// The grammar's NamedCaptureGroups parameter. Without `u`/`v`, `\k` is a
	// reference only when the pattern declares a named group (Annex B).
	named_groups: bool,
	next_capture: u32,
	// Decoded group name to the most recent group that declares it.
	names: map[string]u32,
	scratch: mem.Allocator,
}

// Build a source-preserving tree from a regexp body without slash delimiters.
// Spans address UTF-8 bytes in the supplied pattern. The caller owns the
// node buffer and keeps the original pattern for access to source spellings.
regex_parse_ast :: proc(
	pattern, flags: string,
	allocator: mem.Allocator,
) -> (RegexAst, RegexAstError) {
	assert(allocator.procedure != nil)
	if u64(len(pattern)) >= u64(max(u32)) || u64(len(flags)) >= u64(max(u32)) {
		return {}, {kind = .Source_Too_Large}
	}
	parsed_flags, flag_err := regex_ast_flags(flags)
	if flag_err.kind != .None { return {}, flag_err }

	scratch: RegexScratch
	if !regex_scratch_init(&scratch) {
		return {}, {kind = .Allocation_Error}
	}
	defer regex_scratch_destroy(&scratch)

	return regex_ast_parse(pattern, parsed_flags, allocator, regex_scratch_allocator(&scratch))
}

// Scratch memory for one run of the grammar. WebAssembly has no virtual
// memory: core:mem/virtual reserves nothing there and still reports success,
// so a growing arena would be placed at address zero. The WASI build stopped
// on a runtime assertion inside that arena at the first `u` or `v` literal.
// Those targets take blocks from the heap instead.
REGEX_SCRATCH_ON_HEAP :: ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32

when REGEX_SCRATCH_ON_HEAP {
	RegexScratch     :: mem.Dynamic_Arena
	RegexScratchMark :: struct {}
} else {
	RegexScratch     :: mvirtual.Arena
	RegexScratchMark :: mvirtual.Arena_Temp
}

@(private="file")
regex_scratch_init :: proc(scratch: ^RegexScratch) -> bool {
	when REGEX_SCRATCH_ON_HEAP {
		// Named explicitly: the caller's context allocator may be a parse
		// arena, which would keep every block until the job ends.
		heap := runtime.default_allocator()
		mem.dynamic_arena_init(scratch, heap, heap)
		return true
	} else {
		return mvirtual.arena_init_growing(scratch) == nil
	}
}

@(private="file")
regex_scratch_allocator :: proc(scratch: ^RegexScratch) -> mem.Allocator {
	when REGEX_SCRATCH_ON_HEAP {
		return mem.dynamic_arena_allocator(scratch)
	} else {
		return mvirtual.arena_allocator(scratch)
	}
}

@(private="file")
regex_scratch_destroy :: proc(scratch: ^RegexScratch) {
	when REGEX_SCRATCH_ON_HEAP {
		mem.dynamic_arena_destroy(scratch)
	} else {
		mvirtual.arena_destroy(scratch)
	}
}

// Remember how much of a long-lived scratch is in use, to rewind to later.
@(private="file")
regex_scratch_mark :: proc(scratch: ^RegexScratch) -> RegexScratchMark {
	when REGEX_SCRATCH_ON_HEAP {
		return {}
	} else {
		return mvirtual.arena_temp_begin(scratch)
	}
}

// Release what was allocated since `mark` and keep the memory for the next
// use. The heap variant is only ever marked while empty, so it resets.
@(private="file")
regex_scratch_rewind :: proc(scratch: ^RegexScratch, mark: RegexScratchMark) {
	when REGEX_SCRATCH_ON_HEAP {
		mem.dynamic_arena_reset(scratch)
	} else {
		mvirtual.arena_temp_end(mark)
	}
}

// Run the grammar over `pattern`. Nodes go to `allocator`; `scratch` holds the
// group-name table and is the caller's to release.
@(private="file")
regex_ast_parse :: proc(
	pattern: string,
	flags: RegexAstFlags,
	allocator, scratch: mem.Allocator,
) -> (RegexAst, RegexAstError) {
	assert(allocator.procedure != nil)
	assert(scratch.procedure != nil)
	assert(u64(len(pattern)) < u64(max(u32)))
	ast: RegexAst
	ast.flags = flags
	ast.capture_count, ast.has_named_captures = regex_ast_capture_summary(pattern, flags)
	ast.nodes.allocator = allocator
	if _, err := append(&ast.nodes, RegexAstNode{}); err != nil {
		return {}, {kind = .Allocation_Error}
	}
	parser := RegexAstParser{
		ast = &ast,
		pattern = pattern,
		unicode = .Unicode in flags || .Unicode_Sets in flags,
		unicode_sets = .Unicode_Sets in flags,
		scratch = scratch,
	}
	parser.named_groups = parser.unicode || ast.has_named_captures
	parser.names = make(map[string]u32, 0, parser.scratch)
	err := regex_ast_scan(&parser)
	if err.kind == .None { err = regex_ast_resolve_references(&parser) }
	if err.kind != .None {
		regex_ast_destroy(&ast)
		return {}, err
	}
	// The summary pass and the parser count captures independently; backreference
	// versus legacy octal decisions were made from the summary.
	assert(parser.next_capture == ast.capture_count)
	assert(ast.root == 1)
	return ast, {}
}

// What the grammar says about a pattern when no tree is wanted. Unknown means
// the question could not be answered (nesting past REGEX_AST_DEPTH_MAX, or no
// memory); the caller must fall back on some other judgement.
RegexVerdict :: enum { Accepted, Rejected, Unknown }

// Per-thread memory for regex_pattern_verdict. The lexer asks for a verdict on
// regexp literals while it tokenizes, so the tree must not cost a system call
// per literal (regex_parse_ast maps and unmaps an arena on every call) and must
// not pile up in the parse arena, which is only released with the whole job.
// The arena is created on a thread's first verdict, rewound after each one, and
// lives as long as the thread.
@(thread_local, private="file") regex_verdict_arena: RegexScratch
@(thread_local, private="file") regex_verdict_arena_ready: bool

// Decide whether `new RegExp(pattern, flags)` would compile, using exactly the
// grammar regex_parse_ast builds trees with, and discard the tree. The error
// is meaningful for Rejected and carries a byte offset into `pattern`.
regex_pattern_verdict :: proc(
	pattern: string,
	flags: RegexAstFlags,
) -> (RegexVerdict, RegexAstError) {
	if u64(len(pattern)) >= u64(max(u32)) { return .Unknown, {kind = .Source_Too_Large} }
	if !regex_verdict_arena_ready {
		if !regex_scratch_init(&regex_verdict_arena) {
			return .Unknown, {kind = .Allocation_Error}
		}
		when !REGEX_SCRATCH_ON_HEAP {
			// Keep one byte in use so that rewinding never returns the first
			// block to the operating system.
			if _, err := mvirtual.arena_alloc(&regex_verdict_arena, 1, 1); err != nil {
				mvirtual.arena_destroy(&regex_verdict_arena)
				return .Unknown, {kind = .Allocation_Error}
			}
		}
		regex_verdict_arena_ready = true
	}

	mark := regex_scratch_mark(&regex_verdict_arena)
	defer regex_scratch_rewind(&regex_verdict_arena, mark)

	allocator := regex_scratch_allocator(&regex_verdict_arena)
	_, err := regex_ast_parse(pattern, flags, allocator, allocator)
	verdict := RegexVerdict.Unknown
	switch err.kind {
	case .None:            verdict = .Accepted
	case .Invalid_Pattern: verdict = .Rejected
	case .Invalid_Flags, .Source_Too_Large, .Depth_Limit, .Allocation_Error:
	}
	return verdict, err
}

regex_ast_destroy :: proc(ast: ^RegexAst) {
	delete(ast.nodes)
	ast^ = {}
}

@(private="file")
regex_ast_flags :: proc(flags: string) -> (RegexAstFlags, RegexAstError) {
	if len(flags) > 8 { return {}, {kind = .Invalid_Flags, message = "Too many regexp flags"} }
	result: RegexAstFlags
	for ch, index in transmute([]byte)flags {
		flag: RegexAstFlag
		switch ch {
		case 'd': flag = .Indices
		case 'g': flag = .Global
		case 'i': flag = .Ignore_Case
		case 'm': flag = .Multiline
		case 's': flag = .Dot_All
		case 'u': flag = .Unicode
		case 'v': flag = .Unicode_Sets
		case 'y': flag = .Sticky
		case:
			return {}, {kind = .Invalid_Flags, offset = u32(index), message = "Unknown regexp flag"}
		}
		if flag in result {
			return {}, {
				kind = .Invalid_Flags, offset = u32(index), message = "Duplicate regexp flag",
			}
		}
		conflict := (flag == .Unicode && .Unicode_Sets in result) ||
		            (flag == .Unicode_Sets && .Unicode in result)
		if conflict {
			return {}, {
				kind = .Invalid_Flags, offset = u32(index), message = "Conflicting Unicode flags",
			}
		}
		result += {flag}
	}
	return result, {}
}

@(private)
regex_ast_invalid :: proc(offset: int, message: string) -> RegexAstError {
	assert(offset >= 0)
	return {kind = .Invalid_Pattern, offset = u32(offset), message = message}
}

@(private)
regex_ast_push :: proc(ast: ^RegexAst, node: RegexAstNode) -> (u32, RegexAstError) {
	assert(len(ast.nodes) > 0) // Index zero is the reserved absent link.
	if u64(len(ast.nodes)) >= u64(max(u32)) { return 0, {kind = .Source_Too_Large} }
	id := u32(len(ast.nodes))
	if _, err := append(&ast.nodes, node); err != nil { return 0, {kind = .Allocation_Error} }
	return id, {}
}

@(private)
regex_ast_new_alternative :: proc(
	ast: ^RegexAst,
	frame: ^RegexAstFrame,
	start: int,
) -> RegexAstError {
	node := RegexAstNode{kind = .Alternative, span = {start = u32(start)}}
	id, err := regex_ast_push(ast, node)
	if err.kind != .None { return err }
	if frame.alternative == 0 {
		ast.nodes[frame.container].first_child = id
	} else {
		ast.nodes[frame.alternative].next_sibling = id
	}
	frame.alternative = id
	frame.previous_term, frame.last_term = 0, 0
	return {}
}

@(private)
regex_ast_append_term :: proc(
	ast: ^RegexAst,
	frame: ^RegexAstFrame,
	node: RegexAstNode,
) -> (u32, RegexAstError) {
	assert(frame.alternative != 0)
	id, err := regex_ast_push(ast, node)
	if err.kind != .None { return 0, err }
	if frame.last_term == 0 {
		ast.nodes[frame.alternative].first_child = id
	} else {
		ast.nodes[frame.last_term].next_sibling = id
	}
	frame.previous_term, frame.last_term = frame.last_term, id
	return id, {}
}

// Count capturing groups and detect named ones before parsing. Both facts
// change how earlier text parses: `\2` is a backreference only if a second
// group exists anywhere, and `\k` is a reference only if some group is named.
//
// Only escapes and classes can hide a `(`. A wrong count is impossible for a
// pattern the parser accepts, because the parser skips the same text.
@(private="file")
regex_ast_capture_summary :: proc(
	pattern: string,
	flags: RegexAstFlags,
) -> (count: u32, has_named: bool) {
	class_depth := 0
	for i := 0; i < len(pattern); i += 1 {
		switch pattern[i] {
		case '\\':
			i += 1
		case '[':
			// Classes nest only in `v` mode; elsewhere `[` inside a class is literal.
			if class_depth == 0 || .Unicode_Sets in flags { class_depth += 1 }
		case ']':
			if class_depth > 0 { class_depth -= 1 }
		case '(':
			if class_depth != 0 { continue }
			if i + 1 == len(pattern) || pattern[i + 1] != '?' {
				count += 1
				continue
			}
			named := i + 3 < len(pattern) && pattern[i + 2] == '<' &&
			         pattern[i + 3] != '=' && pattern[i + 3] != '!'
			if named {
				count += 1
				has_named = true
			}
		}
	}
	return count, has_named
}

@(private="file")
regex_ast_scan :: proc(p: ^RegexAstParser) -> RegexAstError {
	ast, pattern := p.ast, p.pattern
	root, root_err := regex_ast_push(ast, {kind = .Pattern, span = {end = u32(len(pattern))}})
	if root_err.kind != .None { return root_err }
	ast.root = root
	frames: [REGEX_AST_DEPTH_MAX]RegexAstFrame
	frames[0].container = root
	if err := regex_ast_new_alternative(ast, &frames[0], 0); err.kind != .None { return err }
	depth := 1
	for cursor := 0; cursor < len(pattern); {
		frame := &frames[depth - 1]
		switch pattern[cursor] {
		case '|':
			ast.nodes[frame.alternative].span.end = u32(cursor)
			cursor += 1
			err := regex_ast_new_alternative(ast, frame, cursor)
			if err.kind != .None { return err }
		case '(':
			if depth == len(frames) { return {kind = .Depth_Limit, offset = u32(cursor)} }
			next, err := regex_ast_open_group(p, frames[:depth + 1], cursor)
			if err.kind != .None { return err }
			cursor = next
			depth += 1
		case ')':
			if depth == 1 { return regex_ast_invalid(cursor, "Unmatched closing group") }
			ast.nodes[frame.alternative].span.end = u32(cursor)
			cursor += 1
			ast.nodes[frame.container].span.end = u32(cursor)
			depth -= 1
		case '[', '*', '+', '?', '{':
			next, err := regex_ast_special(p, frame, cursor)
			if err.kind != .None { return err }
			cursor = next
		case:
			node, next, parse_err := regex_ast_atom(p, cursor)
			if parse_err.kind != .None { return parse_err }
			assert(next > cursor)
			cursor = next
			if err := regex_ast_append_atom(p, frame, node); err.kind != .None { return err }
		}
	}
	if depth != 1 { return regex_ast_invalid(len(pattern), "Unterminated group") }
	ast.nodes[frames[0].alternative].span.end = u32(len(pattern))
	return {}
}

// Open the group at `start`. `frames` holds the enclosing frames followed by
// the slot for the new group's frame.
@(private="file")
regex_ast_open_group :: proc(
	p: ^RegexAstParser,
	frames: []RegexAstFrame,
	start: int,
) -> (int, RegexAstError) {
	assert(len(frames) >= 2)
	enclosing := frames[:len(frames) - 1]
	node, cursor, parse_err := regex_ast_group(p, start)
	if parse_err.kind != .None { return 0, parse_err }
	if node.group_kind == .Named_Capture {
		// The group's node is pushed next, so its index is the current length.
		upcoming := u32(len(p.ast.nodes))
		if err := regex_ast_declare_name(p, enclosing, node.name, upcoming); err.kind != .None {
			return 0, err
		}
	}
	id, push_err := regex_ast_append_term(p.ast, &enclosing[len(enclosing) - 1], node)
	if push_err.kind != .None { return 0, push_err }
	frames[len(frames) - 1] = {container = id}
	err := regex_ast_new_alternative(p.ast, &frames[len(frames) - 1], cursor)
	return cursor, err
}

@(private="file")
regex_ast_special :: proc(
	p: ^RegexAstParser,
	frame: ^RegexAstFrame,
	start: int,
) -> (int, RegexAstError) {
	pattern := p.pattern
	if pattern[start] == '[' {
		class := RegexAstNode{kind = .Character_Class, span = {start = u32(start)}}
		id, push_err := regex_ast_append_term(p.ast, frame, class)
		if push_err.kind != .None { return 0, push_err }
		if p.unicode_sets { return regex_ast_class_sets(p, id, start) }
		return regex_ast_class_legacy(p, id, start)
	}
	if pattern[start] == '{' {
		if !regex_is_braced_quantifier(transmute([]u8)pattern, start, len(pattern)) {
			// Annex B: a `{` that does not begin a quantifier is an ordinary character.
			if p.unicode { return 0, regex_ast_invalid(start, "Unescaped regexp delimiter") }
			brace := RegexAstNode{
				kind = .Character, span = {u32(start), u32(start + 1)}, code_point = u32('{'),
			}
			_, err := regex_ast_append_term(p.ast, frame, brace)
			return start + 1, err
		}
	}
	return regex_ast_quantifier(p, frame, start)
}

@(private="file")
regex_ast_group :: proc(p: ^RegexAstParser, start: int) -> (RegexAstNode, int, RegexAstError) {
	pattern := p.pattern
	assert(pattern[start] == '(')
	group := RegexAstNode{kind = .Group, span = {start = u32(start)}}
	cursor := start + 1
	if cursor < len(pattern) && pattern[cursor] == '?' {
		cursor += 1
		if cursor == len(pattern) {
			return {}, 0, regex_ast_invalid(cursor, "Incomplete group prefix")
		}
		lookbehind := cursor + 1 < len(pattern) && pattern[cursor] == '<' &&
		              (pattern[cursor + 1] == '=' || pattern[cursor + 1] == '!')
		switch {
		case pattern[cursor] == ':':
			group.group_kind = .Noncapturing
			cursor += 1
		case pattern[cursor] == '=':
			group.group_kind = .Lookahead
			cursor += 1
		case pattern[cursor] == '!':
			group.group_kind = .Negative_Lookahead
			cursor += 1
		case lookbehind:
			positive := pattern[cursor + 1] == '='
			group.group_kind = .Lookbehind if positive else .Negative_Lookbehind
			cursor += 2
		case pattern[cursor] == '<':
			name_end, err := regex_ast_group_name(pattern, cursor + 1)
			if err.kind != .None { return {}, 0, err }
			group.group_kind = .Named_Capture
			group.name = {u32(cursor + 1), u32(name_end)}
			cursor = name_end + 1
		case:
			next, err := regex_ast_modifiers(pattern, &group, cursor)
			if err.kind != .None { return {}, 0, err }
			cursor = next
		}
	}
	if group.group_kind == .Capture || group.group_kind == .Named_Capture {
		p.next_capture += 1
		group.capture_index = p.next_capture
	}
	return group, cursor, {}
}

// Parse `ims-ims:` after `(?`. Each flag may appear once across both sides and
// the two sides may not both be empty (`(?-:` is an error; `(?:` never gets here).
@(private="file")
regex_ast_modifiers :: proc(
	pattern: string,
	group: ^RegexAstNode,
	start: int,
) -> (int, RegexAstError) {
	removing := false
	for cursor := start; cursor < len(pattern); cursor += 1 {
		flag: RegexAstFlag
		switch pattern[cursor] {
		case ':':
			if group.modifiers.add == {} && group.modifiers.remove == {} {
				return 0, regex_ast_invalid(start, "Modifier group changes no flags")
			}
			group.group_kind = .Modifiers
			group.name = {u32(start), u32(cursor)}
			return cursor + 1, {}
		case '-':
			if removing { return 0, regex_ast_invalid(cursor, "Repeated '-' in modifiers") }
			removing = true
			continue
		case 'i': flag = .Ignore_Case
		case 'm': flag = .Multiline
		case 's': flag = .Dot_All
		case:
			if cursor == start { return 0, regex_ast_invalid(cursor, "Unknown group prefix") }
			return 0, regex_ast_invalid(cursor, "Invalid modifier flag")
		}
		if flag in group.modifiers.add || flag in group.modifiers.remove {
			return 0, regex_ast_invalid(cursor, "Repeated modifier flag")
		}
		if removing {
			group.modifiers.remove += {flag}
		} else {
			group.modifiers.add += {flag}
		}
	}
	return 0, regex_ast_invalid(start, "Unterminated modifier group")
}

// Record a named group and reject a duplicate name unless the two groups sit
// in different alternatives (ES2025 duplicate named groups).
//
// Node indices grow in source order, so an earlier group lies inside an open
// frame exactly when its index exceeds that frame's container, and inside the
// frame's current alternative exactly when it exceeds that alternative. The
// innermost frame holding the earlier group is where the two groups part: they
// can both participate only if the earlier one is in the current alternative.
//
// Checking the most recent group of a name is enough. If an older group
// conflicted while the most recent did not, those two would share an
// alternative and the most recent one would already have been rejected.
@(private="file")
regex_ast_declare_name :: proc(
	p: ^RegexAstParser,
	frames: []RegexAstFrame,
	name: Loc,
	group: u32,
) -> RegexAstError {
	assert(len(frames) > 0)
	key, key_err := regex_ast_name_key(p, name)
	if key_err.kind != .None { return key_err }
	if earlier, found := p.names[key]; found {
		assert(earlier < group)
		located := false
		#reverse for frame in frames {
			if frame.container < earlier {
				if earlier > frame.alternative {
					return regex_ast_invalid(int(name.start), "Duplicate capture group name")
				}
				located = true
				break
			}
		}
		assert(located) // The root frame's container precedes every group.
	}
	p.names[key] = group
	return {}
}

// Every `\k<name>` must name a group somewhere in the pattern, before or after.
@(private="file")
regex_ast_resolve_references :: proc(p: ^RegexAstParser) -> RegexAstError {
	for node in p.ast.nodes[1:] {
		if node.kind != .Named_Reference { continue }
		assert(p.named_groups)
		key, key_err := regex_ast_name_key(p, node.name)
		if key_err.kind != .None { return key_err }
		if key not_in p.names {
			return regex_ast_invalid(int(node.span.start), "Reference to an undefined group name")
		}
	}
	return {}
}

@(private="file")
regex_ast_append_atom :: proc(
	p: ^RegexAstParser,
	frame: ^RegexAstFrame,
	atom: RegexAstNode,
) -> RegexAstError {
	first, second := regex_ast_code_units(p, atom)
	if _, err := regex_ast_append_term(p.ast, frame, first); err.kind != .None { return err }
	if trailing, ok := second.?; ok {
		if _, err := regex_ast_append_term(p.ast, frame, trailing); err.kind != .None { return err }
	}
	return {}
}

// Without `u`/`v` the grammar consumes UTF-16 code units, so an astral source
// character is two pattern characters. Both keep the UTF-8 span of the source
// character: half of a UTF-8 sequence is not addressable text.
@(private)
regex_ast_code_units :: proc(
	p: ^RegexAstParser,
	atom: RegexAstNode,
) -> (RegexAstNode, Maybe(RegexAstNode)) {
	if p.unicode { return atom, nil }
	value, ok := atom.code_point.?
	if !ok || value <= 0xffff { return atom, nil }
	assert(atom.kind == .Character || atom.kind == .Escape)
	assert(value <= 0x10ffff)
	supplement := value - 0x10000
	leading := atom
	leading.code_point = u32(0xd800) + (supplement >> 10)
	trailing := atom
	// `\` followed by an astral character escapes only its first code unit.
	trailing.kind = .Character
	if atom.kind == .Escape { trailing.span.start += 1 }
	trailing.code_point = u32(0xdc00) + (supplement & 0x3ff)
	return leading, trailing
}

@(private)
regex_ast_read_decimal :: proc(pattern: string, start: int) -> (RegexRepeatBound, int) {
	result := RegexRepeatBound{digits = {start = u32(start)}}
	end := start
	for end < len(pattern) && pattern[end] >= '0' && pattern[end] <= '9' {
		digit := u64(pattern[end] - '0')
		if result.value > (max(u64) - digit) / 10 {
			result.overflow = true
		}
		if !result.overflow { result.value = 10 * result.value + digit }
		end += 1
	}
	result.digits.end = u32(end)
	return result, end
}

@(private="file")
regex_ast_quantifier :: proc(
	p: ^RegexAstParser,
	frame: ^RegexAstFrame,
	start: int,
) -> (int, RegexAstError) {
	ast, pattern := p.ast, p.pattern
	if frame.last_term == 0 {
		return 0, regex_ast_invalid(start, "Quantifier without preceding term")
	}
	term := ast.nodes[frame.last_term]
	#partial switch term.kind {
	case .Quantifier, .Start_Assertion, .End_Assertion, .Boundary_Assertion:
		return 0, regex_ast_invalid(start, "Term cannot be quantified")
	case .Group:
		#partial switch term.group_kind {
		case .Lookbehind, .Negative_Lookbehind:
			return 0, regex_ast_invalid(start, "Lookbehind cannot be quantified")
		case .Lookahead, .Negative_Lookahead:
			// Annex B keeps quantified lookahead for patterns without `u`/`v`.
			if p.unicode {
				return 0, regex_ast_invalid(start, "Lookahead cannot be quantified in this mode")
			}
		}
	}
	repeat, end := regex_ast_repeat(pattern, start)
	if max_bound, finite := repeat.max.?; finite {
		if regex_ast_bound_exceeds(repeat.min, max_bound, pattern) {
			return 0, regex_ast_invalid(start, "Quantifier minimum exceeds maximum")
		}
	}
	wrapper, err := regex_ast_push(ast, {
		kind = .Quantifier, span = {term.span.start, u32(end)},
		repeat = repeat, first_child = frame.last_term,
	})
	if err.kind != .None { return 0, err }
	if frame.previous_term == 0 {
		ast.nodes[frame.alternative].first_child = wrapper
	} else {
		ast.nodes[frame.previous_term].next_sibling = wrapper
	}
	frame.last_term = wrapper
	return end, {}
}

// The caller has checked that a `{` here starts a complete braced quantifier.
@(private="file")
regex_ast_repeat :: proc(pattern: string, start: int) -> (RegexRepeat, int) {
	repeat := RegexRepeat{greedy = true}
	end := start + 1
	switch pattern[start] {
	case '*':
	case '+': repeat.min.value = 1
	case '?': repeat.max = RegexRepeatBound{value = 1}
	case '{':
		repeat.min, end = regex_ast_read_decimal(pattern, end)
		if pattern[end] == ',' {
			end += 1
			if pattern[end] != '}' {
				maximum, max_end := regex_ast_read_decimal(pattern, end)
				repeat.max, end = maximum, max_end
			}
		} else {
			repeat.max = repeat.min
		}
		assert(pattern[end] == '}')
		end += 1
	case: unreachable()
	}
	if end < len(pattern) && pattern[end] == '?' {
		repeat.greedy = false
		end += 1
	}
	return repeat, end
}

// Compare bounds that may not fit in 64 bits by their digit strings.
@(private="file")
regex_ast_bound_exceeds :: proc(minimum, maximum: RegexRepeatBound, pattern: string) -> bool {
	if !minimum.overflow && !maximum.overflow { return minimum.value > maximum.value }
	if minimum.overflow != maximum.overflow { return minimum.overflow }
	left := regex_ast_trim_zeros(pattern[minimum.digits.start:minimum.digits.end])
	right := regex_ast_trim_zeros(pattern[maximum.digits.start:maximum.digits.end])
	if len(left) != len(right) { return len(left) > len(right) }
	return left > right
}

@(private="file")
regex_ast_trim_zeros :: proc(digits: string) -> string {
	start := 0
	for start < len(digits) && digits[start] == '0' { start += 1 }
	return digits[start:]
}

@(private)
cli_regexp_ast :: proc(args: []string) -> int {
	if len(args) != 1 && (len(args) != 3 || args[1] != "--flags") {
		fmt.eprintln("Usage: kessel regexp <pattern> [--flags <flags>]")
		return 2
	}
	flags := ""
	if len(args) == 3 { flags = args[2] }
	ast, err := regex_parse_ast(args[0], flags, context.allocator)
	if err.kind != .None {
		fmt.eprintf("Error: %v at byte %d (%s)\n", err.kind, err.offset, err.message)
		return 1
	}
	defer regex_ast_destroy(&ast)
	encoded, json_err := json.marshal(
		ast, {use_enum_names = true}, allocator = context.temp_allocator,
	)
	if json_err != nil {
		fmt.eprintln("Error: could not encode regexp tree")
		return 1
	}
	out_println(string(encoded))
	return 0
}
