package kessel

import "core:strings"

// A declaration file can only name bindings that exist at its own scope. Two
// kinds of binding are visible to a signature in the source but not there:
// names declared inside a function body, and `var`s hoisted out of a nested
// block. TypeScript calls them private names and rejects the declaration.
DeclarationPrivateName :: struct { name: string, value, type: bool }

// What is being printed when a private name is found. TypeScript words the
// diagnostic after the declaration that uses the name. An inferred type has
// no such owner and reports TS9039.
DeclarationPrivateOwner :: enum {
	Inferred, Variable, Function, Method, StaticMethod, Constructor,
	Property, StaticProperty, Getter, StaticGetter, Accessor, Alias, Extends,
}

DeclarationRegionScan :: struct {
	done: bool,
	hoisted: [dynamic]string,                // `var` names declared in nested statements.
	assignments: [dynamic]^MemberExpression, // Targets of `a.b = value`, in source order.
}

@(private = "file")
DeclarationScanVisitor :: struct {
	hoisted: ^[dynamic]string,
	assignments: ^[dynamic]^MemberExpression,
}

// Functions, classes, object literals and namespaces are containers of their
// own: a `var` or a property assignment inside one belongs to that container.
@(private = "file")
dts_scan_enter :: proc(user: rawptr, node: AstNode) -> AstWalkAction {
	scan := cast(^DeclarationScanVisitor)user
	#partial switch n in node {
	case ^FunctionDeclaration, ^FunctionExpression, ^ArrowFunctionExpression: return .Skip
	case ^ClassDeclaration, ^ClassExpression, ^ObjectExpression: return .Skip
	case ^TSModuleDeclaration: return .Skip
	case ^VariableDeclaration:
		if n.kind == .Var {
			for declarator in n.declarations {
				collect_pattern_bound_names_list(declarator.id, scan.hoisted)
			}
		}
	case ^AssignmentExpression:
		if scan.assignments != nil && n.operator == .Assign {
			if member, property := n.left^.(^MemberExpression); property {
				append(scan.assignments, member)
			}
		}
	}
	return .Continue
}

// The shared walker handles long operator chains without recursion and bounds
// every other nesting, so a deep input ends the scan instead of the process.
@(private = "file")
dts_scan_statements :: proc(body: []^Statement, visitor: ^DeclarationScanVisitor) {
	for statement in body {
		assert(statement != nil)
		walker := AstVisitor{user = visitor, enter = dts_scan_enter}
		ast_walk_statement_tree(statement, walker, context.allocator)
	}
}

@(private)
dts_scan_region :: proc(state: ^DeclarationEmit, index: int) -> ^DeclarationRegionScan {
	assert(index >= 0)
	assert(index < len(state.regions))
	scan := &state.regions[index].scan
	if scan.done { return scan }
	scan.done = true
	visitor := DeclarationScanVisitor{&scan.hoisted, &scan.assignments}
	dts_scan_statements(state.regions[index].body, &visitor)
	return scan
}

// Enter a function body: its own declarations and hoisted `var`s are private
// to every type printed for that function. Returns the mark to pop back to.
@(private)
dts_private_push :: proc(state: ^DeclarationEmit, body: []^Statement) -> int {
	mark := len(state.private_names)
	locals := &state.private_names
	for statement in body {
		assert(statement != nil)
		#partial switch s in statement^ {
		case ^TSTypeAliasDeclaration: append(locals, DeclarationPrivateName{s.id.name, false, true})
		case ^TSInterfaceDeclaration: append(locals, DeclarationPrivateName{s.id.name, false, true})
		case ^TSEnumDeclaration: append(locals, DeclarationPrivateName{s.id.name, true, true})
		case ^ClassDeclaration:
			if id, ok := s.id.?; ok { append(locals, DeclarationPrivateName{id.name, true, true}) }
		case ^FunctionDeclaration:
			if id, ok := s.id.?; ok { append(locals, DeclarationPrivateName{id.name, true, false}) }
		case ^VariableDeclaration:
			names: [dynamic]string
			for declarator in s.declarations {
				collect_pattern_bound_names_list(declarator.id, &names)
			}
			for name in names { append(locals, DeclarationPrivateName{name, true, false}) }
		}
	}
	hoisted: [dynamic]string
	visitor := DeclarationScanVisitor{&hoisted, nil}
	dts_scan_statements(body, &visitor)
	for name in hoisted { append(locals, DeclarationPrivateName{name, true, false}) }
	return mark
}

@(private)
dts_private_pop :: proc(state: ^DeclarationEmit, mark: int) {
	assert(mark <= len(state.private_names))
	resize(&state.private_names, mark)
}

@(private)
dts_private_check :: proc(state: ^DeclarationEmit, ref: DeclarationReference) {
	if ref.loc == (Loc{}) { return }
	if dts_reference_is_local(state, ref) { return }
	value := ref.value || ref.qualified
	private := false
	#reverse for local in state.private_names {
		if local.name != ref.name { continue }
		private = local.value if value else local.type
		if private { break }
	}
	if !private && value { private = dts_hoisted_private(state, ref.name) }
	if !private { return }
	code, subject := dts_private_subject(state)
	message: string
	if code == "TS9039" {
		message = strings.concatenate({
			"Type containing private name '", ref.name,
			"' can't be used with --isolatedDeclarations.",
		})
	} else {
		message = strings.concatenate({subject, " has or is using private name '", ref.name, "'."})
	}
	dts_error(state, code, message, ref.loc)
}

// A `var` in a nested block is hoisted to its region, so a signature can read
// it, yet no declaration is emitted for it. A real binding of the same name
// in an enclosing region takes precedence.
@(private = "file")
dts_hoisted_private :: proc(state: ^DeclarationEmit, name: string) -> bool {
	if len(dts_lookup(state, name, .Value)) != 0 { return false }
	for region := state.region; region >= 0; region = state.regions[region].parent {
		for hoisted in dts_scan_region(state, region).hoisted {
			if hoisted == name { return true }
		}
	}
	return false
}

// The code and the opening words of TypeScript's message for each owner. `%s`
// stands for the quoted name of the parameter, or of the owner without one.
@(private = "file")
DeclarationPrivateText :: struct { code, text: string }

@(private = "file", rodata)
dts_private_parameter_texts := #partial [DeclarationPrivateOwner]DeclarationPrivateText{
	.Function     = {"TS4078", "Parameter %s of exported function"},
	.Method       = {"TS4073", "Parameter %s of public method from exported class"},
	.StaticMethod = {"TS4070", "Parameter %s of public static method from exported class"},
	.Constructor  = {"TS4063", "Parameter %s of constructor from exported class"},
	.Accessor     = {"TS4106", "Parameter %s of accessor"},
}

@(private = "file", rodata)
dts_private_owner_texts := #partial [DeclarationPrivateOwner]DeclarationPrivateText{
	.Variable       = {"TS4025", "Exported variable %s"},
	.Function       = {"TS4060", "Return type of exported function"},
	.Method         = {"TS4055", "Return type of public method from exported class"},
	.StaticMethod   = {"TS4052", "Return type of public static method from exported class"},
	.Property       = {"TS4031", "Public property %s of exported class"},
	.StaticProperty = {"TS4028", "Public static property %s of exported class"},
	.Getter         = {"TS4043", "Return type of public getter %s from exported class"},
	.StaticGetter   = {"TS4040", "Return type of public static getter %s from exported class"},
	.Alias          = {"TS4081", "Exported type alias %s"},
	.Extends        = {"TS4020", "'extends' clause of exported class %s"},
}

@(private = "file")
dts_private_subject :: proc(state: ^DeclarationEmit) -> (code, subject: string) {
	entry := dts_private_owner_texts[state.private_owner]
	name := state.private_name
	if state.private_parameter != "" {
		entry = dts_private_parameter_texts[state.private_owner]
		name = state.private_parameter
	}
	// An owner without an entry has no declaration to name: an inferred type.
	if entry.code == "" { return "TS9039", "" }
	quoted := strings.concatenate({"'", name, "'"})
	subject, _ = strings.replace(entry.text, "%s", quoted, 1)
	return entry.code, subject
}
