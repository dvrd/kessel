package kessel

import "core:mem"
import "core:fmt"

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
	check_export_duplicate_names(p, program)

	// §16.2.2 "Export 'X' is not defined in the module" early error.
	// Collect all module-level declared names only for JS modules with no
	// prior parse errors (error recovery / TS global augmentation produce
	// false positives otherwise); leaving the map empty is intentional for
	// the JS-with-errors case so check_undefined_exports stays a no-op there.
	module_names: map[string]bool
	module_names.allocator = context.temp_allocator
	if !allow_ts_mode(p) && len(p.errors) == 0 {
		module_names = collect_module_declared_names(p, program)
	}
	check_undefined_exports(p, program, module_names)
}

// register_exported_name records an ExportedName, reporting the §16.2.1
// duplicate-exported-name early error (JS mode only — TS resolves type-vs-value
// merge / overload edge cases in the semantic checker). An empty name is ignored.
register_exported_name :: proc(p: ^Parser, exported: ^ScopeMap, name: string, off: u32) {
	if name == "" { return }
	if _, exists := scope_map_get(exported, name); exists {
		if !allow_ts_mode(p) {
			msg := fmt.tprintf("Duplicate exported name '%s'", name)
			report_error_coded_span(p, .K3020_ImportExportNameOrBinding, off, off, msg)
		}
	} else {
		scope_map_set(exported, name, off)
	}
}

// collect_export_decl_bound_names appends the BoundNames (and their source
// offsets) of an `export <Decl>` declaration that contribute to ExportedNames:
// VariableDeclaration pattern names and the FunctionDeclaration / ClassDeclaration
// binding identifier (a no-body TS overload signature contributes none).
collect_export_decl_bound_names :: proc(p: ^Parser, decl_ptr: ^Declaration, names: ^[dynamic]string, offs: ^[dynamic]u32) {
	#partial switch d in decl_ptr^ {
	case ^VariableDeclaration:
		if d != nil {
			for decl in d.declarations {
				prev_len := len(names^)
				collect_pattern_bound_names_list(decl.id, names)
				// Pad offsets so the list aligns with names.
				for _ in prev_len ..< len(names^) {
					bump_append(offs, decl.loc.start)
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
				bump_append(names, id.name)
				bump_append(offs, id.loc.start)
			}
		}
	case ^ClassDeclaration:
		if d != nil {
			if id, ok := d.id.(BindingIdentifier); ok {
				bump_append(names, id.name)
				bump_append(offs, id.loc.start)
			}
		}
	}
}

// check_export_duplicate_names enforces §16.2.1: the ExportedNames of the module
// item list must be unique. Walks every export form (declaration BoundNames,
// named specifiers, `export default`, `export * as ns`) into one ScopeMap.
check_export_duplicate_names :: proc(p: ^Parser, program: ^Program) {
	exported := scope_map_make(16)
	for stmt in program.body {
		if stmt == nil { continue }
		#partial switch v in stmt^ {
		case ^ExportNamedDeclaration:
			if v == nil { continue }
			if decl_ptr, has_decl := v.declaration.?; has_decl && decl_ptr != nil {
				decl_names := make([dynamic]string, 0, 8, context.temp_allocator)
				decl_offs  := make([dynamic]u32, 0, 8, context.temp_allocator)
				collect_export_decl_bound_names(p, decl_ptr, &decl_names, &decl_offs)
				for i in 0 ..< len(decl_names) {
					register_exported_name(p, &exported, decl_names[i], decl_offs[i])
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
				register_exported_name(p, &exported, var_name, var_off)
			}
		case ^ExportDefaultDeclaration:
			if v == nil { continue }
			// In TS mode `export default` may repeat (type-space default does not
			// shadow a value default; TS surfaces this as a semantic, not syntax,
			// error — OXC and Babel both accept the duplicate).
			if allow_ts_mode(p) { continue }
			if _, exists := scope_map_get(&exported, "default"); exists {
				report_error_coded(p, .K2040_UnexpectedToken, "Duplicate exported name 'default'")
			} else { scope_map_set(&exported, "default", v.loc.start) }
		case ^ExportAllDeclaration:
			if v == nil { continue }
			// `export * as name from "m"` adds `name` to ExportedNames.
			if ns_name, has_ns := v.exported.(IdentifierName); has_ns {
				register_exported_name(p, &exported, ns_name.name, ns_name.loc.start)
			}
		}
	}
}

// collect_module_declared_names gathers every module-level declared binding (var,
// lexical, function, class, import locals, and hoisted nested vars) into a set so
// check_undefined_exports can flag a bare `export { x }` whose `x` is undeclared.

// collect_export_default_binding adds the names an `export default` introduces to
// the module binding set: always "default", plus the inner FunctionDeclaration /
// ClassDeclaration / FunctionExpression / ClassExpression binding identifier when
// the default exports a named declaration or expression.
collect_export_default_binding :: proc(v: ^ExportDefaultDeclaration, module_names: ^map[string]bool) {
	module_names^["default"] = true
	// `export default function foo(){}` also binds `foo`.
	if v != nil && v.declaration != nil {
		#partial switch dd in v.declaration^ {
		case ^Declaration:
			if dd != nil {
				#partial switch inner in dd^ {
				case ^FunctionDeclaration:
					if inner != nil { if id, ok := inner.id.(BindingIdentifier); ok { module_names^[id.name] = true } }
				case ^ClassDeclaration:
					if inner != nil { if id, ok := inner.id.(BindingIdentifier); ok { module_names^[id.name] = true } }
				}
			}
		case ^Expression:
			if dd != nil {
				#partial switch expr in dd^ {
				case ^FunctionExpression:
					if expr != nil { if id, ok := expr.id.(BindingIdentifier); ok { module_names^[id.name] = true } }
				case ^ClassExpression:
					if expr != nil { if id, ok := expr.id.(BindingIdentifier); ok { module_names^[id.name] = true } }
				}
			}
		}
	}
}
collect_module_declared_names :: proc(p: ^Parser, program: ^Program) -> map[string]bool {
	module_names: map[string]bool
	module_names.allocator = context.temp_allocator
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
			collect_export_default_binding(v, &module_names)
		}
		// Also hoist var names from nested blocks/loops/etc.
		hoisted_vars := scope_map_make(4)
		scope_hoist_vars(p, stmt, &hoisted_vars)
		for it in hoisted_vars.items { module_names[it.name] = true }
	}
	return module_names
}

// check_undefined_exports enforces the §16.2.2 structural rules: a string-literal
// local without `from` is illegal, and (JS only) a bare `export { x }` whose `x`
// is not in module_names is "Export 'x' is not defined in the module".
check_undefined_exports :: proc(p: ^Parser, program: ^Program, module_names: map[string]bool) {
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
scope_process_for_in :: proc(p: ^Parser, lex, vars: ^ScopeMap, v: ^ForInStatement) {
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
}

scope_process_for_of :: proc(p: ^Parser, lex, vars: ^ScopeMap, v: ^ForOfStatement) {
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
}

scope_process_for_stmt :: proc(p: ^Parser, lex, vars: ^ScopeMap, v: ^ForStatement) {
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
}

scope_process_function_decl :: proc(p: ^Parser, lex, vars: ^ScopeMap, v: ^FunctionDeclaration, is_block_scope: bool) {
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
}

scope_process_import :: proc(p: ^Parser, lex, vars: ^ScopeMap, v: ^ImportDeclaration) {
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
}

scope_process_export_named :: proc(p: ^Parser, lex, vars: ^ScopeMap, v: ^ExportNamedDeclaration) {
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
}

scope_process_export_default :: proc(p: ^Parser, lex, vars: ^ScopeMap, v: ^ExportDefaultDeclaration) {
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
		scope_process_for_in(p, lex, vars, v)
	case ^ForOfStatement:
		scope_process_for_of(p, lex, vars, v)
	case ^ForStatement:
		scope_process_for_stmt(p, lex, vars, v)
	case ^FunctionDeclaration:
		scope_process_function_decl(p, lex, vars, v, is_block_scope)
	case ^ClassDeclaration:
		if v == nil { return }
		// TS: class declarations also participate in declaration
		// merging — same reasoning as FunctionDeclaration above.
		if allow_ts_mode(p) { return }
		if id, ok := v.id.(BindingIdentifier); ok {
			scope_add(p, lex, vars, id.name, id.loc.start, .Lexical)
		}
	case ^ImportDeclaration:
		scope_process_import(p, lex, vars, v)
	case ^ExportNamedDeclaration:
		scope_process_export_named(p, lex, vars, v)
	case ^ExportDefaultDeclaration:
		scope_process_export_default(p, lex, vars, v)
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

	// Collect all top-level declaration names with their TS binding kind, then
	// flag any pair whose kinds are not allowed to share a name (ts_conflicts).
	entries := make([dynamic]TSBindingEntry, 0, 16, context.temp_allocator)
	for stmt in body {
		if stmt == nil { continue }
		if ex, is_export := stmt^.(^ExportNamedDeclaration); is_export {
			if ex != nil {
				if d, have := ex.declaration.(^Declaration); have && d != nil {
					collect_ts_export_binding(d, &entries)
				}
			}
			continue
		}
		collect_ts_stmt_binding(stmt, &entries)
	}
	report_ts_scope_conflicts(p, entries[:])
}

// collect_ts_export_binding appends the TSBindingEntry for the declaration behind
// an `export <Decl>` (class/function/var/enum/interface/type-alias/namespace).
collect_ts_export_binding :: proc(d: ^Declaration, entries: ^[dynamic]TSBindingEntry) {
	#partial switch inner in d^ {
	case ^ClassDeclaration:
		if inner != nil {
			if id, ok := inner.id.(BindingIdentifier); ok {
				append(entries, TSBindingEntry{name = id.name, at = id.loc.start, kind = .Class})
			}
		}
	case ^FunctionDeclaration:
		if inner != nil {
			if id, ok := inner.id.(BindingIdentifier); ok {
				append(entries, TSBindingEntry{name = id.name, at = id.loc.start, kind = .Function})
			}
		}
	case ^VariableDeclaration:
		if inner != nil {
			names := make([dynamic]string, 0, 4, context.temp_allocator)
			for decl in inner.declarations { scope_collect_pattern(decl.id, &names) }
			for n in names {
				append(entries, TSBindingEntry{name = n, at = inner.loc.start, kind = .VarLike})
			}
		}
	case ^TSEnumDeclaration:
		if inner != nil {
			kind: TSBindingKind = inner.const_ ? .ConstEnum : .Enum
			append(entries, TSBindingEntry{name = inner.id.name, at = inner.id.loc.start, kind = kind})
		}
	case ^TSInterfaceDeclaration:
		if inner != nil {
			append(entries, TSBindingEntry{name = inner.id.name, at = inner.id.loc.start, kind = .Interface})
		}
	case ^TSTypeAliasDeclaration:
		if inner != nil {
			append(entries, TSBindingEntry{name = inner.id.name, at = inner.id.loc.start, kind = .TypeAlias})
		}
	case ^TSModuleDeclaration:
		if inner != nil {
			// Get name from the id expression
			if inner.id != nil {
				if ident, ok := inner.id^.(^Identifier); ok && ident != nil {
					append(entries, TSBindingEntry{name = ident.name, at = ident.loc.start, kind = .Namespace})
				}
			}
		}
	}
}

// collect_ts_stmt_binding appends the TSBindingEntry(s) for a top-level statement
// declaration (the same declaration forms plus import bindings).
collect_ts_stmt_binding :: proc(stmt: ^Statement, entries: ^[dynamic]TSBindingEntry) {
	#partial switch v in stmt^ {
	case ^ClassDeclaration:
		if v != nil {
			if id, ok := v.id.(BindingIdentifier); ok {
				append(entries, TSBindingEntry{name = id.name, at = id.loc.start, kind = .Class})
			}
		}
	case ^FunctionDeclaration:
		if v != nil {
			if id, ok := v.id.(BindingIdentifier); ok {
				append(entries, TSBindingEntry{name = id.name, at = id.loc.start, kind = .Function})
			}
		}
	case ^VariableDeclaration:
		if v != nil {
			names := make([dynamic]string, 0, 4, context.temp_allocator)
			for decl in v.declarations { scope_collect_pattern(decl.id, &names) }
			for n in names {
				append(entries, TSBindingEntry{name = n, at = v.loc.start, kind = .VarLike})
			}
		}
	case ^TSEnumDeclaration:
		if v != nil {
			kind: TSBindingKind = v.const_ ? .ConstEnum : .Enum
			append(entries, TSBindingEntry{name = v.id.name, at = v.id.loc.start, kind = kind})
		}
	case ^TSInterfaceDeclaration:
		if v != nil {
			append(entries, TSBindingEntry{name = v.id.name, at = v.id.loc.start, kind = .Interface})
		}
	case ^TSTypeAliasDeclaration:
		if v != nil {
			append(entries, TSBindingEntry{name = v.id.name, at = v.id.loc.start, kind = .TypeAlias})
		}
	case ^TSModuleDeclaration:
		if v != nil {
			if v.id != nil {
				if ident, ok := v.id^.(^Identifier); ok && ident != nil {
					append(entries, TSBindingEntry{name = ident.name, at = ident.loc.start, kind = .Namespace})
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
					append(entries, TSBindingEntry{name = ss.local.name, at = ss.local.loc.start, kind = kind})
				case ImportDefaultSpecifier:
					append(entries, TSBindingEntry{name = ss.local.name, at = ss.local.loc.start, kind = kind})
				case ImportNamespaceSpecifier:
					append(entries, TSBindingEntry{name = ss.local.name, at = ss.local.loc.start, kind = kind})
				}
			}
		}
	}
}

// report_ts_scope_conflicts emits "Identifier already declared" for each pair of
// same-named bindings whose TS kinds conflict (O(n^2), bounded by scope size).
report_ts_scope_conflicts :: proc(p: ^Parser, entries: []TSBindingEntry) {
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

// parse_import_phase_keyword consumes a Phase-Imports stage-3 leading
// contextual keyword (`defer` before `* as ns`, or `source` before a
// default binding) and records it on decl.phase. Lifted out of
// parse_import_declaration as pure code motion; no-op when absent.
parse_import_phase_keyword :: proc(p: ^Parser, decl: ^ImportDeclaration) {
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
}

// parse_import_type_keyword consumes a TS `import type ...` leading
// contextual keyword and records it on decl.import_kind, disambiguating
// from a value import of a binding named `type`. Lifted out of
// parse_import_declaration as pure code motion; no-op when absent.
parse_import_type_keyword :: proc(p: ^Parser, decl: ^ImportDeclaration) {
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
}

// reject_inline_type_modifier_in_type_only_import rejects the inline
// `type` modifier inside a type-only import, e.g. `import type { type X }`
// (TS K4010). Distinguishes `type` as the imported NAME (valid: followed
// by `as` / `,` / `}`) from `type` as a redundant modifier (invalid).
// Lifted out of parse_import_declaration as pure code motion; the
// import_kind == .Type / `type`-name guard stays in the caller.
reject_inline_type_modifier_in_type_only_import :: proc(p: ^Parser) {
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

// check_import_binding_name enforces the reserved-name rules on an import
// binding (default `import name` or namespace `import * as name`): §16.2.2
// `await` is reserved in module code, and strict-reserved words are
// rejected outside ambient TS. Lifted out of parse_import_declaration.
check_import_binding_name :: proc(p: ^Parser, local: Identifier) {
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

	parse_import_phase_keyword(p, decl)

	parse_import_type_keyword(p, decl)

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

	if !parse_import_clause(p, decl) { return nil }

	decl.attributes = parse_import_attributes(p)

	match_semicolon_or_asi(p)

	check_import_duplicate_bindings(p, decl)

	decl.loc.end = prev_end_offset(p)

	record_esm_import(p, decl)

	// Allocate Statement union and store the pointer
	stmt := new_node(p, Statement)
	stmt^ = (^ImportDeclaration)(decl)
	return stmt
}

// parse_named_import_list parses the `{ a, b as c, ... }` import specifier list up
// to the closing `}` (left unconsumed), rejecting inline `type` in a type-only import.
parse_named_import_list :: proc(p: ^Parser, decl: ^ImportDeclaration) {
	for !is_token(p, .RBrace) && !is_token(p, .EOF) {
		if decl.import_kind == .Type && allow_ts_mode(p) &&
		   p.cur_type == .Identifier && cur_value_eq(p, "type") {
			reject_inline_type_modifier_in_type_only_import(p)
		}
		spec := parse_import_specifier(p)
		if spec != nil {
			append_import_spec(&decl.specifiers, spec, p.allocator)
		}

		if !match_token(p, .Comma) {
			break
		}
	}
}

// parse_import_namespace_clause parses `* as name from "module"`. Returns false on
// an unrecoverable error (so the caller returns nil).
parse_import_namespace_clause :: proc(p: ^Parser, decl: ^ImportDeclaration) -> bool {
	// Namespace import: import * as name from "module". Spec.start must
	// cover the leading `*` (OXC parity), not just the `name`.
	star_loc := cur_loc(p)
	eat(p)
	if !expect_token(p, .As) {
		return false
	}
	local := parse_identifier(p)
	check_import_binding_name(p, local)
	spec := new_node(p, ImportNamespaceSpecifier)
	spec.loc = star_loc
	spec.local = BindingIdentifier{
		loc  = local.loc,
		name = local.name,
	}
	spec.loc.end = prev_end_offset(p)
	append_import_spec(&decl.specifiers, spec, p.allocator)

	if !expect_token(p, .From) {
		return false
	}

	if !is_token(p, .String) {
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected string literal module specifier")
	}
	decl.source = parse_string_literal(p)
	return true
}

// parse_import_default_clause parses `name [, { ... } | * as ns] from "module"`.
// Returns false on an unrecoverable error (so the caller returns nil).
parse_import_default_clause :: proc(p: ^Parser, decl: ^ImportDeclaration) -> bool {
	// Default import: import name from "module" or import name, { x } from "module"
	local := parse_identifier(p)
	check_import_binding_name(p, local)
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

			parse_named_import_list(p, decl)

			if !expect_token(p, .RBrace) {
				return false
			}
		} else if is_token(p, .Mul) {
			// import name, * as namespace from "module"
			eat(p)
			if !expect_token(p, .As) {
				return false
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
		return false
	}

	if !is_token(p, .String) {
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected string literal module specifier")
	}
	decl.source = parse_string_literal(p)
	return true
}

// parse_import_clause dispatches the ES ImportClause forms (bare string, named,
// namespace, default). Returns false on an unrecoverable error.
parse_import_clause :: proc(p: ^Parser, decl: ^ImportDeclaration) -> bool {
	if is_token(p, .String) {
		decl.source = parse_string_literal(p)
	} else if is_token(p, .LBrace) {
		eat(p)
		parse_named_import_list(p, decl)
		if !expect_token(p, .RBrace) { return false }
		if !expect_token(p, .From) { return false }
		if !is_token(p, .String) {
			report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected string literal module specifier")
		}
		decl.source = parse_string_literal(p)
	} else if is_token(p, .Mul) {
		if !parse_import_namespace_clause(p, decl) { return false }
	} else if is_token(p, .Identifier) || can_be_binding_identifier(p.cur_type) {
		if !parse_import_default_clause(p, decl) { return false }
	} else if allow_ts_mode(p) {
		report_error_coded(p, .K2023_ExpectedKeywordOrPunct, "Expected import source or specifier")
	}
	return true
}

// check_import_duplicate_bindings enforces §16.2.2: BoundNames of the ImportClause
// must be unique (O(n^2) over the small specifier list).
check_import_duplicate_bindings :: proc(p: ^Parser, decl: ^ImportDeclaration) {
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
}

// record_esm_import records the ESM static-import entries (specifiers + module
// request) on the parser.
record_esm_import :: proc(p: ^Parser, decl: ^ImportDeclaration) {
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

	parse_import_spec_type_modifier(p)

	imported, is_string_import := parse_import_spec_name(p)

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

	check_import_spec_binding_name(p, local, imported, is_string_import)

	return spec
}

// parse_import_spec_type_modifier consumes a per-specifier TS `type` modifier
// (`import { type x as y }`) when the 4-token disambiguation says `type` is a
// modifier and not the imported name itself.
parse_import_spec_type_modifier :: proc(p: ^Parser) {
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
}

// parse_import_spec_name parses the ImportedBinding / ModuleExportName slot:
// a string-literal name (ES2022 arbitrary module export names), a rejected
// numeric/bigint literal, or a plain identifier name.
parse_import_spec_name :: proc(p: ^Parser) -> (imported: Identifier, is_string_import: bool) {
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
	return
}

// check_import_spec_binding_name enforces the §16.2.2 ImportedBinding early errors on
// the local name: eval/arguments, strict-reserved words, and always-reserved
// words (the last both with an alias and in the no-alias same-name case).
check_import_spec_binding_name :: proc(p: ^Parser, local, imported: Identifier, is_string_import: bool) {
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
}

// parse_export_assignment handles the TS `export = <expr>;` legacy
// CommonJS-style export assignment. Returns nil when the next token is not
// `=`, so the caller can continue with the ES ExportDeclaration forms.
// Lifted out of parse_export_declaration as pure code motion.
parse_export_assignment :: proc(p: ^Parser, start: Loc) -> ^Statement {
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
	return nil
}

// parse_export_as_namespace handles the TS UMD-style `export as namespace
// <Identifier>;` declaration. Returns nil when the form does not match, so
// the caller can continue with the remaining export forms. Lifted out of
// parse_export_declaration as pure code motion.
parse_export_as_namespace :: proc(p: ^Parser, start: Loc) -> ^Statement {
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
	return nil
}

// check_ts_namespace_export_named enforces TS1233: a named re-export inside
// a non-ambient TS namespace body is invalid (only `export <declaration>` is
// allowed; `declare namespace` permits internal re-exports but never a
// `from` source). Lifted out of parse_export_declaration as pure code motion.
check_ts_namespace_export_named :: proc(p: ^Parser, result_named: ^Statement, start: Loc) {
	if !(p.ctx.in_ts_namespace && allow_ts_mode(p) && !p.ctx.in_ts_module_block) {
		return
	}
	if result_named == nil {
		return
	}
	// Check: if it has a `from` source OR we're in a non-ambient namespace.
	has_from := false
	if en, ok := result_named^.(^ExportNamedDeclaration); ok && en != nil {
		has_from = en.source != nil
	}
	if has_from {
		report_error_coded_span(p, .K3022_ModuleSyntaxInScript, u32(start.start), u32(start.start), "Export declarations are not permitted in a namespace")
	} else if !p.ctx.in_ambient {
		report_error_coded_span(p, .K3022_ModuleSyntaxInScript, u32(start.start), u32(start.start), "Export declarations are not permitted in a namespace")
	}
}

// try_parse_export_type_prefix handles the TS type-only re-export prefixes
// `export type { ... }` and `export type * ...` (with the namespace-body
// TS1233 + escaped-`type` early errors). Returns (stmt, true) when it
// dispatched; (nil, false) leaves `export type X = ...` to fall through to
// the declaration path. Lifted out of parse_export_declaration.
try_parse_export_type_prefix :: proc(p: ^Parser, start: Loc) -> (^Statement, bool) {
	if !(p.cur_type == .Identifier && cur_value_eq(p, "type") && allow_ts_mode(p)) {
		return nil, false
	}
	has_esc := cur_has_escape(p)
	nxt := peek_token(p)
	if nxt.type == .LBrace {
		if has_esc { report_error_coded(p, .K3015_KeywordContainsEscape, "Keyword 'type' must not contain escaped characters") }
		if p.ctx.in_ts_namespace && !p.ctx.in_ts_module_block {
			report_error_coded_span(p, .K3022_ModuleSyntaxInScript, u32(start.start), u32(start.start), "Export declarations are not permitted in a namespace")
		}
		eat(p) // consume `type`
		return parse_export_named(p, start, .Type), true
	}
	if nxt.type == .Mul {
		if has_esc { report_error_coded(p, .K3015_KeywordContainsEscape, "Keyword 'type' must not contain escaped characters") }
		if p.ctx.in_ts_namespace && !p.ctx.in_ts_module_block {
			report_error_coded_span(p, .K3022_ModuleSyntaxInScript, u32(start.start), u32(start.start), "Export declarations are not permitted in a namespace")
		}
		eat(p) // consume `type`
		eat(p) // consume `*`
		return parse_export_all(p, start, .Type), true
	}
	return nil, false
}

// skip_ts_export_import_modifiers consumes leading TS class-modifier
// keywords (public/private/protected/static) before `import` in legacy
// `export public import a = x.c;` forms — syntactic no-ops. Lifted out of
// parse_export_declaration as pure code motion.
skip_ts_export_import_modifiers :: proc(p: ^Parser) {
	if allow_ts_mode(p) {
		for (p.cur_type == .Identifier || p.cur_type == .Public || p.cur_type == .Private ||
		     p.cur_type == .Protected || p.cur_type == .Static) &&
		    (cur_value_eq(p, "public") || cur_value_eq(p, "private") ||
		     cur_value_eq(p, "protected") || cur_value_eq(p, "static")) &&
		    is_next_token(p, .Import) {
			eat(p)
		}
	}
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
		result_named := parse_export_named(p, start, .Value)
		check_ts_namespace_export_named(p, result_named, start)
		return result_named
	}

	if stmt := parse_export_assignment(p, start); stmt != nil {
		return stmt
	}

	// Past the TS-export-assign fork — this IS an ES ExportDeclaration.
	// Flag module syntax now so error recovery can't lose it. (The
	// save/restore at the top of this function ensures the flag only
	// takes effect outside a TS namespace body — see fixture
	// spec/typescript/015_namespace_module which exercises the case.)
	p.has_module_syntax = true
	p.module_pre_scan_done = true

	if stmt := parse_export_as_namespace(p, start); stmt != nil {
		return stmt
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
	if stmt, ok := try_parse_export_type_prefix(p, start); ok {
		return stmt
	}

	skip_ts_export_import_modifiers(p)

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

// report_export_default_function_tail flags an LHS-tail token that would
// extend the `export default [async] function() {}` declaration into an
// expression. Per §16.2.3 the FunctionDeclaration ends at `}`; a SAME-line
// `(`/`[`/`.`/`` `tag` ``/`=>`/postfix `++`/`--` makes the production fail,
// while a token on the NEXT line is a fresh statement (ASI applies at the
// declaration boundary). Only same-line continuations are errors. Test262:
// language/module-code/parse-err-invoke-anon-{fun,gen}-decl.js.
report_export_default_function_tail :: proc(p: ^Parser) {
	if cur_has_newline(p) { return }
	#partial switch p.cur_type {
	case .LParen, .LBracket, .Dot, .OptionalChain,
	     .Template, .TemplateHead, .Arrow,
	     .PlusPlus, .MinusMinus:
		report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token after 'export default function' declaration")
	}
}

// parse_export_default_function handles `export default [async] function`,
// the §16.2.3 HoistableDeclaration form. parse_function_declaration(is_expr
// = true) returns a ^Statement wrapping an ExpressionStatement whose
// .expression is the FunctionExpression, so unwrap that as the default def.
parse_export_default_function :: proc(p: ^Parser) -> (def: ExportDefaultDef) {
	p.in_export_default = true
	fn_stmt := parse_function_declaration(p, true)
	p.in_export_default = false
	if fn_stmt != nil {
		if expr_stmt, ok := fn_stmt^.(^ExpressionStatement); ok {
			def = expr_stmt.expression
		}
	}
	report_export_default_function_tail(p)
	return
}

// default_export_class_decl parses `export default class {}` (also the
// decorated `@dec class` / `@dec abstract class` forms) and wraps the
// resulting ClassDeclaration in a Declaration union for the default export.
default_export_class_decl :: proc(p: ^Parser) -> (def: ExportDefaultDef) {
	cls_stmt := parse_statement_or_declaration(p)
	if cls_stmt != nil {
		if cls_decl, ok := cls_stmt^.(^ClassDeclaration); ok {
			decl_union := new_node(p, Declaration)
			decl_union^ = cls_decl
			def = decl_union
		}
	}
	return
}

// parse_export_default_interface handles the TS-only `export default
// interface X { ... }` form. An anonymous `export default interface {}` is
// rejected (TS4051 — interface declarations must have a name).
parse_export_default_interface :: proc(p: ^Parser) -> (def: ExportDefaultDef) {
	ensure_nxt(p)
	if !is_next_token(p, .Identifier) && !is_keyword_usable_as_property_name(p.lexer.nxt.kind) {
		report_error_coded(p, .K4051_TSDeclarationStructure, "Interface declaration must have a name")
	}
	iface_stmt := parse_ts_interface_declaration(p)
	if iface_stmt != nil {
		if iface, ok := iface_stmt^.(^TSInterfaceDeclaration); ok {
			decl_union := new_node(p, Declaration)
			decl_union^ = iface
			def = decl_union
		}
	}
	return
}

// report_export_default_expr_restrictions rejects the declaration forms that
// §16.2.3 disallows after `export default` (only AssignmentExpression /
// FunctionDeclaration / ClassDeclaration are permitted). `using` is a
// contextual keyword, so a 3-token lookahead distinguishes the declaration
// form from a plain `using` / `await using` identifier expression. Mirrors
// babel + OXC.
report_export_default_expr_restrictions :: proc(p: ^Parser) {
	// §16.2.3 — LexicalDeclaration (`const`, `let`) and VariableStatement
	// (`var`) are NOT allowed after `export default`.
	if p.cur_type == .Const || p.cur_type == .Var ||
	   (p.cur_type == .Let && !cur_has_newline(p)) {
		report_error_coded(p, .K3021_ExportDefaultRestrictions, "'export default' cannot be followed by a variable declaration")
	}
	if is_token(p, .Using) && using_starts_decl(p) {
		report_error_coded(p, .K3021_ExportDefaultRestrictions, "'export default' cannot be followed by a using declaration")
	}
	ensure_nxt(p)
	if is_token(p, .Await) && p.lexer.nxt.kind == .Using &&
	   (p.lexer.nxt.flags & FLAG_NEW_LINE) == 0 &&
	   await_using_starts_decl(p) {
		report_error_coded(p, .K3021_ExportDefaultRestrictions, "'export default' cannot be followed by a using declaration")
	}
}

// parse_export_default_expr handles the §16.2.3 AssignmentExpression form.
// Declaration forms are rejected up front (for recovery the trailing
// expression is still parsed), and a dangling literal with no separator
// (`export default null null;`) is flagged.
parse_export_default_expr :: proc(p: ^Parser) -> (def: ExportDefaultDef) {
	report_export_default_expr_restrictions(p)
	expr := parse_assignment_expression(p)
	if expr != nil {
		def = expr
	}
	if !match_semicolon_or_asi(p) && !cur_has_newline(p) {
		// `export default null null;` - second literal follows without separator.
		#partial switch p.cur_type {
		case .Null, .True, .False, .Number, .String, .BigInt:
			report_error_coded(p, .K2040_UnexpectedToken, "Unexpected token following export default expression")
		}
	}
	return
}

// export_default_collect_esm records the ESM static-export entry for an
// `export default` declaration (a single entry, named "default").
export_default_collect_esm :: proc(p: ^Parser, decl: ^ExportDefaultDeclaration, start: Loc) {
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
}

parse_export_default :: proc(p: ^Parser, start: Loc) -> ^Statement {
	// TS1319 — `export default` inside a namespace is invalid.
	// Exception: inside string-named module declarations (`declare module "m" { ... }`).
	if p.ctx.in_ts_namespace && allow_ts_mode(p) && !p.ctx.in_ts_module_block {
		report_error_coded_span(p, .K3022_ModuleSyntaxInScript, u32(start.start), u32(start.start), "Export declarations are not permitted in a namespace")
	}

	// ExportDefaultDef is union { ^Declaration, ^Expression }; each default
	// form below fills it in (see the parse_export_default_* helpers). The
	// dispatch CONDITIONS stay here ("push ifs up"); each branch body is a
	// leaf helper.
	def := new_node(p, ExportDefaultDef)
	if is_token(p, .Function) || (is_token(p, .Async) && is_next_token(p, .Function)) {
		def^ = parse_export_default_function(p)
	} else if is_token(p, .Class) ||
	          is_token(p, .At) ||
	          (is_token(p, .Abstract) && is_next_token(p, .Class) && (p.lexer.nxt.flags & FLAG_NEW_LINE) == 0) {
		// `export default class {}` / `@dec class` / `@dec abstract class`.
		def^ = default_export_class_decl(p)
	} else if is_token(p, .Abstract) && is_next_token(p, .At) {
		// `export default abstract @dec class C {}` is INVALID. Decorators
		// must come before `abstract`, not after.
		report_error_coded(p, .K4033_DecoratorOrder, "Decorators must precede the 'abstract' modifier on a class declaration")
		def^ = default_export_class_decl(p)
	} else if p.cur_type == .Identifier && cur_value_eq(p, "interface") &&
	          allow_ts_mode(p) {
		def^ = parse_export_default_interface(p)
	} else {
		def^ = parse_export_default_expr(p)
	}

	decl := new_node(p, ExportDefaultDeclaration)
	decl.loc = start
	decl.declaration = def
	decl.loc.end = prev_end_offset(p)

	export_default_collect_esm(p, decl, start)

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

		parse_export_spec_type_modifier(p, export_kind)


		local := parse_export_spec_name(p)
		exported := local
		has_as := match_token(p, .As)
		if has_as {
			exported = parse_export_spec_name(p)
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

	parse_export_from_clause(p, decl)

	if !match_semicolon_or_asi_export(p) {
		// `export {} null;` - unexpected token follows export clause on same line.
		report_error_coded(p, .K2010_ExpectedSemicolon, "Expected semicolon after export declaration")
	}

	check_export_default_without_as(p, decl)

	decl.loc.end = prev_end_offset(p)

	record_esm_named_export(p, decl)

	// Allocate Statement union and store the pointer
	stmt := new_node(p, Statement)
	stmt^ = (^ExportNamedDeclaration)(decl)
	return stmt
}

// ES2022 allows either an identifier OR a string literal on either
// side of `as`. Parse each slot independently.
parse_export_spec_name :: proc(p: ^Parser) -> ExportSpecifierName {
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

// parse_export_spec_type_modifier consumes a per-specifier TS `type` modifier
// (`export { type Foo as Bar }`) when the disambiguation says `type` is a
// modifier and not the local name itself, rejecting it inside a type-only export.
parse_export_spec_type_modifier :: proc(p: ^Parser, export_kind: ImportExportKind) {
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
}

// parse_export_from_clause consumes the optional `from "module"` re-export source
// (treating an escaped `from` identifier as the keyword) plus import attributes.
parse_export_from_clause :: proc(p: ^Parser, decl: ^ExportNamedDeclaration) {
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
}

// check_export_default_without_as enforces §16.2.3: `export { default }` with no
// `as` and no `from` clause is a SyntaxError (the reserved word cannot bind).
check_export_default_without_as :: proc(p: ^Parser, decl: ^ExportNamedDeclaration) {
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
}

// record_esm_named_export records the ESM static-export entries for the named
// export (its specifiers and optional module request) on the parser.
record_esm_named_export :: proc(p: ^Parser, decl: ^ExportNamedDeclaration) {
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
}

