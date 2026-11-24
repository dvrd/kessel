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
		ast_walk_statement_tree(statement, {user = visitor, enter = dts_scan_enter}, context.allocator)
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
	for statement in body {
		assert(statement != nil)
		#partial switch s in statement^ {
		case ^TSTypeAliasDeclaration: append(&state.private_names, DeclarationPrivateName{s.id.name, false, true})
		case ^TSInterfaceDeclaration: append(&state.private_names, DeclarationPrivateName{s.id.name, false, true})
		case ^TSEnumDeclaration: append(&state.private_names, DeclarationPrivateName{s.id.name, true, true})
		case ^ClassDeclaration:
			if id, ok := s.id.?; ok { append(&state.private_names, DeclarationPrivateName{id.name, true, true}) }
		case ^FunctionDeclaration:
			if id, ok := s.id.?; ok { append(&state.private_names, DeclarationPrivateName{id.name, true, false}) }
		case ^VariableDeclaration:
			names: [dynamic]string
			for declarator in s.declarations { collect_pattern_bound_names_list(declarator.id, &names) }
			for name in names { append(&state.private_names, DeclarationPrivateName{name, true, false}) }
		}
	}
	hoisted: [dynamic]string
	visitor := DeclarationScanVisitor{&hoisted, nil}
	dts_scan_statements(body, &visitor)
	for name in hoisted { append(&state.private_names, DeclarationPrivateName{name, true, false}) }
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
		message = strings.concatenate({"Type containing private name '", ref.name, "' can't be used with --isolatedDeclarations."})
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

@(private = "file")
dts_private_subject :: proc(state: ^DeclarationEmit) -> (code, subject: string) {
	name := state.private_name
	parameter := state.private_parameter
	quoted := strings.concatenate({"'", parameter if parameter != "" else name, "'"})
	if parameter != "" {
		#partial switch state.private_owner {
		case .Function: return "TS4078", strings.concatenate({"Parameter ", quoted, " of exported function"})
		case .Method: return "TS4073", strings.concatenate({"Parameter ", quoted, " of public method from exported class"})
		case .StaticMethod: return "TS4070", strings.concatenate({"Parameter ", quoted, " of public static method from exported class"})
		case .Constructor: return "TS4063", strings.concatenate({"Parameter ", quoted, " of constructor from exported class"})
		case .Accessor: return "TS4106", strings.concatenate({"Parameter ", quoted, " of accessor"})
		}
		return "TS9039", ""
	}
	#partial switch state.private_owner {
	case .Variable: return "TS4025", strings.concatenate({"Exported variable ", quoted})
	case .Function: return "TS4060", "Return type of exported function"
	case .Method: return "TS4055", "Return type of public method from exported class"
	case .StaticMethod: return "TS4052", "Return type of public static method from exported class"
	case .Property: return "TS4031", strings.concatenate({"Public property ", quoted, " of exported class"})
	case .StaticProperty: return "TS4028", strings.concatenate({"Public static property ", quoted, " of exported class"})
	case .Getter: return "TS4043", strings.concatenate({"Return type of public getter ", quoted, " from exported class"})
	case .StaticGetter: return "TS4040", strings.concatenate({"Return type of public static getter ", quoted, " from exported class"})
	case .Alias: return "TS4081", strings.concatenate({"Exported type alias ", quoted})
	case .Extends: return "TS4020", strings.concatenate({"'extends' clause of exported class ", quoted})
	}
	return "TS9039", ""
}
