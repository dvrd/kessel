package kessel

import "core:crypto/hash"
import "core:fmt"
import "core:strings"

// React Fast Refresh instrumentation, after react-refresh/babel and the OXC
// transformer. It edits the tree before the printer runs.
//
// Registration tells the runtime which top-level bindings are components:
//
//     function App() {}        const Memo = memo(_c2 = () => null);
//     _c = App;                _c3 = Memo;
//     ...
//     var _c, _c2, _c3;
//     $RefreshReg$(_c, "App"); $RefreshReg$(_c2, "Memo$memo"); ...
//
// A signature lets the runtime notice that the Hooks a function calls have
// changed, in which case its state cannot be preserved:
//
//     var _s = $RefreshSig$();
//     function App() { _s(); const [n] = useState(0); ... }
//     _s(App, "<hash of the Hook calls>", false, function () { return [useCustom]; });
//
// The second call names the function. A declaration, or a function that a
// variable declarator would name, is named by a statement after it; any
// other function expression is wrapped where it stands, together with every
// call it is an argument of, so higher-order components carry the signature.

RefreshOptions :: struct {
	enabled:              bool,
	emit_full_signatures: bool,
	reg, sig:             string,
}

RefreshHookCall :: struct {
	name:   string,
	key:    string,
	callee: ^Expression,
}

RefreshSignature :: struct {
	handle:  string,
	key:     string,
	force:   bool,
	hooks:   [dynamic]^Expression,
	at:      u32,
}

// The statement list in which a signature handle is declared.
RefreshScope :: struct {
	handles: [dynamic]string,
}

RefreshFunction :: struct {
	calls:  [dynamic]RefreshHookCall,
	loc:    Loc,
	blocks: int, // Open block scopes between the function body and the walk.
}

RefreshRegistration :: struct {
	handle, id: string,
}

Refresh :: struct {
	cg:            ^Codegen,
	state:         ^TransformState,
	options:       RefreshOptions,
	source:        string,
	registrations: [dynamic]RefreshRegistration,
	handles:       map[^Expression]string,  // Expression boxes to wrap as `handle = value`.
	used_as_type:  map[string]bool,         // Names used as a JSX tag or element type.
	symbols:       map[u32]SymbolId,        // Identifier offsets to the binding they read.
	scopes:        [dynamic]^RefreshScope,
	functions:     [dynamic]^RefreshFunction,
	pending:       [dynamic]^Statement,     // To insert after the statement being walked.
	signature_count, registration_count: int,
	force_reset:   bool,
}

REFRESH_BUILTIN_HOOKS :: [?]string{
	"useState", "useReducer", "useEffect", "useLayoutEffect", "useMemo", "useCallback", "useRef",
	"useContext", "useImperativeHandle", "useDebugValue", "useId", "useDeferredValue",
	"useTransition", "useInsertionEffect", "useSyncExternalStore", "useFormStatus", "useFormState",
	"useActionState", "useOptimistic",
}

// Runs once, before printing. The semantic model is built first, from the
// tree as written, so later lookups by source offset stay valid.
transform_refresh_program :: proc(cg: ^Codegen, program: ^Program, comments: []Comment) {
	state := cg.transform
	if state == nil || !state.refresh.enabled { return }
	model := transform_model(cg)
	r := Refresh{cg = cg, state = state, options = state.refresh, source = cg.source}
	allocator := state.allocator
	r.registrations.allocator = allocator
	r.scopes.allocator = allocator
	r.functions.allocator = allocator
	r.pending.allocator = allocator
	r.handles = make(map[^Expression]string, 16, allocator)
	r.used_as_type = make(map[string]bool, 16, allocator)
	r.symbols = make(map[u32]SymbolId, len(model.refs), allocator)
	for ref in model.refs {
		if ref.resolved != SYMBOL_UNRESOLVED { r.symbols[ref.start] = ref.resolved }
	}
	for comment in comments {
		if strings.contains(comment.value, "@refresh reset") { r.force_reset = true }
	}
	for statement in program.body { refresh_collect_types(&r, statement) }
	refresh_scope_push(&r)
	refresh_walk_list(&r, &program.body, true)
	refresh_scope_pop(&r, &program.body, refresh_prologue_end(program.body[:]), {0, 0})
	refresh_emit_registrations(&r, program)
}

// Directives and imports stay ahead of the handle declarations.
refresh_prologue_end :: proc(body: []^Statement) -> int {
	index := codegen_directive_count(body)
	for index < len(body) {
		if _, imported := body[index]^.(^ImportDeclaration); !imported { break }
		index += 1
	}
	return index
}

refresh_name :: proc(r: ^Refresh, prefix: string, counter: ^int) -> string {
	for {
		counter^ += 1
		name := prefix
		if counter^ > 1 {
			name = fmt.aprintf("%s%d", prefix, counter^, allocator = r.state.allocator)
		}
		// A textual test is enough: a name that appears nowhere cannot be bound.
		if !strings.contains(r.source, name) { return name }
	}
}

refresh_is_component_name :: proc(name: string) -> bool {
	return len(name) > 0 && name[0] >= 'A' && name[0] <= 'Z'
}

// `use` itself counts, as in OXC; the Babel plugin requires a capital after it.
refresh_is_hook_name :: proc(name: string) -> bool {
	if !strings.has_prefix(name, "use") { return false }
	return len(name) == 3 || (name[3] >= 'A' && name[3] <= 'Z')
}

// ----------------------------------------------------------------------------
// Tree builders
// ----------------------------------------------------------------------------

refresh_identifier :: proc(r: ^Refresh, name: string, at: u32) -> ^Expression {
	return transform_identifier(r.state, name, at)
}

refresh_statement :: proc(r: ^Refresh, expression: ^Expression, at: u32) -> ^Statement {
	node := new(ExpressionStatement, r.state.allocator)
	node^ = {loc = {at, at}, expression = expression}
	statement := new(Statement, r.state.allocator)
	statement^ = node
	return statement
}

refresh_call :: proc(
	r: ^Refresh, callee: string, arguments: []^Expression, at: u32,
) -> ^Expression {
	return target_call(r.state, refresh_identifier(r, callee, at), arguments, {at, at})
}

refresh_string :: proc(r: ^Refresh, value: string, at: u32) -> ^Expression {
	node := new(StringLiteral, r.state.allocator)
	node^ = {loc = {at, at}, value = value}
	return transform_expression(r.state, node)
}

// ----------------------------------------------------------------------------
// Scopes for signature handles
// ----------------------------------------------------------------------------

refresh_scope_push :: proc(r: ^Refresh) -> ^RefreshScope {
	scope := new(RefreshScope, r.state.allocator)
	scope.handles.allocator = r.state.allocator
	append(&r.scopes, scope)
	return scope
}

// Declares `var _s = $RefreshSig$(), ...` at `index` of the list.
refresh_scope_pop :: proc(r: ^Refresh, list: ^[dynamic]^Statement, index: int, loc: Loc) {
	scope := pop(&r.scopes)
	if len(scope.handles) == 0 { return }
	// Keep statement positions increasing, which comment placement relies on.
	at := loc.start
	if index < len(list) { at = get_statement_loc(list[index]).start }
	declaration := new(VariableDeclaration, r.state.allocator)
	declaration.loc = {at, at}
	declaration.kind = .Var
	count := len(scope.handles)
	declaration.declarations = make([dynamic]VariableDeclarator, 0, count, r.state.allocator)
	for handle in scope.handles {
		id := refresh_identifier(r, handle, at)^.(^Identifier)
		append(&declaration.declarations, VariableDeclarator{
			loc = {at, at}, id = id, init = refresh_call(r, r.options.sig, nil, at),
		})
	}
	statement := new(Statement, r.state.allocator)
	statement^ = declaration
	refresh_insert(r, list, index, statement)
}

refresh_insert :: proc(r: ^Refresh, list: ^[dynamic]^Statement, index: int, statement: ^Statement) {
	assert(index >= 0)
	assert(index <= len(list))
	grown := make([dynamic]^Statement, 0, len(list) + 4, r.state.allocator)
	append(&grown, ..list[:index])
	append(&grown, statement)
	append(&grown, ..list[index:])
	list^ = grown
}

// ----------------------------------------------------------------------------
// Names used as element types
// ----------------------------------------------------------------------------

// A top-level `const Name = something()` is a component when the name is used
// as a JSX tag or passed to an element factory. Collected by name: a nested
// binding that shadows it counts too, which can only register one value more.
refresh_collect_types :: proc(r: ^Refresh, statement: ^Statement) {
	visitor := RefreshVisitor{r = r, collect = true}
	refresh_visit_statement(&visitor, statement)
}

refresh_note_factory_call :: proc(r: ^Refresh, call: ^CallExpression) {
	if len(call.arguments) == 0 { return }
	name := ""
	#partial switch callee in call.callee^ {
	case ^Identifier: name = callee.name
	case ^MemberExpression:
		if property, ok := callee.property^.(^Identifier); ok && !callee.computed {
			name = property.name
		}
	}
	switch name {
	case "createElement", "jsx", "jsxs", "jsxDEV":
		if id, ok := call.arguments[0]^.(^Identifier); ok { r.used_as_type[id.name] = true }
	}
}

// ----------------------------------------------------------------------------
// Walk
// ----------------------------------------------------------------------------

// Walks a statement list, inserting the statements each item asked for after it.
refresh_walk_list :: proc(r: ^Refresh, list: ^[dynamic]^Statement, top_level := false) {
	index := 0
	for index < len(list) {
		statement := list[index]
		outer := r.pending
		r.pending = make([dynamic]^Statement, 0, 2, r.state.allocator)
		if top_level { refresh_register_statement(r, statement) }
		// A signature is attached before the registration that follows it.
		registered := r.pending
		r.pending = make([dynamic]^Statement, 0, 2, r.state.allocator)
		visitor := RefreshVisitor{r = r}
		refresh_visit_statement(&visitor, statement, in_list = true)
		append(&r.pending, ..registered[:])
		after := r.pending
		r.pending = outer
		for extra, offset in after { refresh_insert(r, list, index + 1 + offset, extra) }
		index += 1 + len(after)
	}
}

refresh_walk_block :: proc(r: ^Refresh, block: ^BlockStatement) {
	refresh_enter_block(r, 1)
	refresh_scope_push(r)
	refresh_walk_list(r, &block.body)
	refresh_scope_pop(r, &block.body, 0, block.loc)
	refresh_enter_block(r, -1)
}

// Like OXC, a signature lists only the Hook calls made in the function's own
// scope. A call inside a nested block scope breaks the Rules of Hooks anyway.
refresh_enter_block :: proc(r: ^Refresh, change: int) {
	if len(r.functions) == 0 { return }
	r.functions[len(r.functions) - 1].blocks += change
	assert(r.functions[len(r.functions) - 1].blocks >= 0)
}

// A function body: its own hook calls are collected while it is walked.
refresh_walk_function_body :: proc(
	r: ^Refresh, body: ^FunctionBody, loc: Loc) -> Maybe(RefreshSignature,
) {
	function := new(RefreshFunction, r.state.allocator)
	function.calls.allocator = r.state.allocator
	function.loc = loc
	append(&r.functions, function)
	refresh_scope_push(r)
	refresh_walk_list(r, &body.body)
	directives := min(len(body.directives), len(body.body))
	refresh_scope_pop(r, &body.body, directives, body.loc)
	pop(&r.functions)
	signature, signed := refresh_signature(r, function).?
	if !signed { return nil }
	// The first statement reports each call of the function to the runtime.
	at := body.loc.start
	report := refresh_statement(r, refresh_call(r, signature.handle, nil, at), at)
	refresh_insert(r, &body.body, directives, report)
	return signature
}

// An arrow with an expression body gets a block, so the report has a place.
refresh_walk_arrow :: proc(
	r: ^Refresh, arrow: ^ArrowFunctionExpression) -> Maybe(RefreshSignature,
) {
	body := FunctionBody{loc = arrow.loc}
	switch inner in arrow.body {
	case ^BlockStatement:
		body.loc = inner.loc
		body.body = inner.body
		signature := refresh_walk_function_body(r, &body, arrow.loc)
		inner.body = body.body
		return signature
	case ^Expression:
		at := loc_from_expr(inner).start
		result := new(ReturnStatement, r.state.allocator)
		result^ = {loc = {at, at}, argument = inner}
		statement := new(Statement, r.state.allocator)
		statement^ = result
		body.body = make([dynamic]^Statement, 0, 3, r.state.allocator)
		append(&body.body, statement)
		signature := refresh_walk_function_body(r, &body, arrow.loc)
		if len(body.body) == 1 { return signature }
		block := new(BlockStatement, r.state.allocator)
		block^ = {loc = {at, at}, body = body.body}
		arrow.body = block
		arrow.expression = false
		return signature
	}
	return nil
}

// Builds the signature of a function from the Hook calls directly inside it.
refresh_signature :: proc(r: ^Refresh, function: ^RefreshFunction) -> Maybe(RefreshSignature) {
	if len(function.calls) == 0 { return nil }
	key := strings.builder_make(r.state.allocator)
	signature := RefreshSignature{force = r.force_reset, at = function.loc.end}
	signature.hooks.allocator = r.state.allocator
	for call, index in function.calls {
		// OXC separates the calls with a backslash and an `n`, where the Babel
		// plugin uses a line feed. The key is opaque; this keeps its hash equal.
		if index != 0 { strings.write_string(&key, "\\n") }
		strings.write_string(&key, call.name)
		strings.write_byte(&key, '{')
		strings.write_string(&key, call.key)
		strings.write_byte(&key, '}')
		builtin := false
		for name in REFRESH_BUILTIN_HOOKS { if name == call.name { builtin = true } }
		if builtin { continue }
		if hook := refresh_custom_hook(r, call.callee, function.loc); hook != nil {
			append(&signature.hooks, hook)
		} else {
			// The Hook cannot be listed, so an edit to it would go unnoticed.
			signature.force = true
		}
	}
	signature.key = strings.to_string(key)
	if !r.options.emit_full_signatures {
		digest := hash.hash_string(.Insecure_SHA1, signature.key, context.temp_allocator)
		signature.key = strings.clone(string(base64_encode(digest)), r.state.allocator)
	}
	signature.handle = refresh_name(r, "_s", &r.signature_count)
	append(&r.scopes[len(r.scopes) - 1].handles, signature.handle)
	return signature
}

// The callee as it can be read where the signature is attached, outside the
// function: `useThing` or `Module.useThing`, bound to a declaration that is
// not local to the function. Nil when there is no such reading.
refresh_custom_hook :: proc(r: ^Refresh, callee: ^Expression, function: Loc) -> ^Expression {
	root: ^Identifier
	property: ^Expression
	#partial switch node in callee^ {
	case ^Identifier: root = node
	case ^MemberExpression:
		if node.computed { return nil }
		root, _ = node.object^.(^Identifier)
		property = node.property
	}
	if root == nil { return nil }
	symbol, bound := r.symbols[root.loc.start]
	if !bound { return nil }
	declared := transform_model(r.cg).symbols[symbol].decl_start
	if declared >= function.start && declared < function.end { return nil }
	if property == nil { return callee }
	object := transform_expression(r.state, root)
	return target_member(r.state, object, property, false, {function.end, function.end})
}

// `handle(target, key[, force[, function () { return [hooks]; }]])`
refresh_signature_call :: proc(
	r: ^Refresh, signature: RefreshSignature, target: ^Expression,
) -> ^Expression {
	at := signature.at
	arguments := make([dynamic]^Expression, 0, 4, context.temp_allocator)
	append(&arguments, target, refresh_string(r, signature.key, at))
	if signature.force || len(signature.hooks) != 0 {
		flag := new(BooleanLiteral, r.state.allocator)
		flag^ = {loc = {at, at}, value = signature.force}
		append(&arguments, transform_expression(r.state, flag))
	}
	if len(signature.hooks) != 0 {
		list := new(ArrayExpression, r.state.allocator)
		list.loc = {at, at}
		count := len(signature.hooks)
		list.elements = make([dynamic]Maybe(^Expression), 0, count, r.state.allocator)
		for hook in signature.hooks { append(&list.elements, hook) }
		result := new(ReturnStatement, r.state.allocator)
		result^ = {loc = {at, at}, argument = transform_expression(r.state, list)}
		statement := new(Statement, r.state.allocator)
		statement^ = result
		getter := new(FunctionExpression, r.state.allocator)
		getter.loc = {at, at}
		getter.body.loc = {at, at}
		getter.body.body = make([dynamic]^Statement, 0, 1, r.state.allocator)
		append(&getter.body.body, statement)
		append(&arguments, transform_expression(r.state, getter))
	}
	return refresh_call(r, signature.handle, arguments[:], at)
}

// Replaces the expression in its box by `handle(expression, ...)`.
refresh_wrap :: proc(r: ^Refresh, box: ^Expression, signature: RefreshSignature) {
	inner := new(Expression, r.state.allocator)
	inner^ = box^
	box^ = refresh_signature_call(r, signature, inner)^
}

// The name is read at the offset of its own declaration, where no reference
// of the source starts, so the printer resolves it like any other use.
refresh_name_later :: proc(r: ^Refresh, signature: RefreshSignature, name: BindingIdentifier) {
	target := transform_identifier_exact(r.state, name.name, name.loc.start)
	call := refresh_signature_call(r, signature, target)
	append(&r.pending, refresh_statement(r, call, signature.at))
}

// ----------------------------------------------------------------------------
// Registration
// ----------------------------------------------------------------------------

refresh_handle :: proc(r: ^Refresh, id: string) -> string {
	handle := refresh_name(r, "_c", &r.registration_count)
	append(&r.registrations, RefreshRegistration{handle, id})
	return handle
}

// `handle = Name;` after the statement being walked.
refresh_register_later :: proc(r: ^Refresh, name: BindingIdentifier, at: u32) {
	handle := refresh_identifier(r, refresh_handle(r, name.name), at)
	value := transform_identifier_exact(r.state, name.name, name.loc.start)
	append(&r.pending, refresh_statement(r, transform_assignment(r.state, handle, value, at), at))
}

refresh_register_statement :: proc(r: ^Refresh, statement: ^Statement) {
	#partial switch node in statement^ {
	case ^FunctionDeclaration:
		refresh_register_function(r, &node.expr)
	case ^VariableDeclaration:
		refresh_register_variable(r, node)
	case ^ExportNamedDeclaration:
		declaration, present := node.declaration.?
		if !present || declaration == nil { return }
		#partial switch inner in declaration^ {
		case ^FunctionDeclaration: refresh_register_function(r, &inner.expr)
		case ^VariableDeclaration: refresh_register_variable(r, inner)
		}
	case ^ExportDefaultDeclaration:
		switch inner in node.declaration^ {
		case ^Declaration:
			if function, ok := inner^.(^FunctionDeclaration); ok {
				refresh_register_function(r, &function.expr)
			}
		case ^Expression:
			// Only a possible higher-order component call is considered here.
			if function, ok := inner^.(^FunctionExpression); ok && function.id != nil {
				refresh_register_function(r, function)
			} else if _, is_call := inner^.(^CallExpression); is_call {
				refresh_find_components(r, "%default%", inner, false)
			}
		}
	}
}

refresh_register_function :: proc(r: ^Refresh, function: ^FunctionExpression) {
	id, named := function.id.?
	if !named || function.no_body || function.declare || !refresh_is_component_name(id.name) {
		return
	}
	refresh_register_later(r, id, function.loc.end)
}

refresh_register_variable :: proc(r: ^Refresh, declaration: ^VariableDeclaration) {
	if declaration.declare || len(declaration.declarations) != 1 { return }
	declarator := declaration.declarations[0]
	id, plain := declarator.id.(^Identifier)
	init, initialized := declarator.init.?
	if !plain || !initialized || init == nil || !refresh_is_component_name(id.name) { return }
	value := target_unwrap(r.cg, init)
	#partial switch node in value^ {
	case ^ArrowFunctionExpression, ^FunctionExpression, ^TaggedTemplateExpression:
	case ^CallExpression:
		// `require(...)` and `import(...)` produce modules, not components.
		if callee, ok := node.callee^.(^Identifier); ok {
			loads := strings.has_prefix(callee.name, "require")
			if loads || strings.has_prefix(callee.name, "import") {
				return
			}
		}
	case:
		return
	}
	found := refresh_find_components(r, id.name, value, true)
	if found || r.used_as_type[id.name] {
		refresh_register_later(r, BindingIdentifier{id.loc, id.name}, declaration.loc.end)
	}
}

// Marks the functions inside a possible chain of higher-order component
// calls. `outermost` is the expression a declarator already names, which
// is registered by a statement instead of in place.
refresh_find_components :: proc(
	r: ^Refresh, id: string, box: ^Expression, outermost: bool,
) -> bool {
	value := target_unwrap(r.cg, box)
	#partial switch node in value^ {
	case ^Identifier:
		// `hoc(Foo)`: Foo was registered where it was defined.
		return refresh_is_component_name(node.name)
	case ^ArrowFunctionExpression:
		if body, expression := node.body.(^Expression); expression {
			if _, curried := target_unwrap(r.cg, body)^.(^ArrowFunctionExpression); curried {
				return false
			}
		}
		if !outermost { r.handles[value] = refresh_handle(r, id) }
		return true
	case ^FunctionExpression:
		if !outermost { r.handles[value] = refresh_handle(r, id) }
		return true
	case ^CallExpression:
		if len(node.arguments) == 0 { return false }
		callee := target_unwrap(r.cg, node.callee)
		#partial switch _ in callee^ {
		case ^Identifier, ^MemberExpression:
		case: return false
		}
		location := loc_from_expr(callee)
		written := r.source[location.start:location.end]
		inner := fmt.aprintf("%s$%s", id, written, allocator = r.state.allocator)
		if !refresh_find_components(r, inner, node.arguments[0], false) { return false }
		if !outermost { r.handles[value] = refresh_handle(r, id) }
		return true
	}
	return false
}

// `var _c, _c2; $RefreshReg$(_c, "App"); ...` at the end of the program.
refresh_emit_registrations :: proc(r: ^Refresh, program: ^Program) {
	if len(r.registrations) == 0 { return }
	at := u32(len(r.source))
	declaration := new(VariableDeclaration, r.state.allocator)
	declaration.loc = {at, at}
	declaration.kind = .Var
	count := len(r.registrations)
	declaration.declarations = make([dynamic]VariableDeclarator, 0, count, r.state.allocator)
	for registration in r.registrations {
		id := refresh_identifier(r, registration.handle, at)^.(^Identifier)
		append(&declaration.declarations, VariableDeclarator{loc = {at, at}, id = id})
	}
	statement := new(Statement, r.state.allocator)
	statement^ = declaration
	refresh_insert(r, &program.body, len(program.body), statement)
	for registration in r.registrations {
		arguments := [2]^Expression{
			refresh_identifier(r, registration.handle, at), refresh_string(r, registration.id, at),
		}
		call := refresh_call(r, r.options.reg, arguments[:], at)
		refresh_insert(r, &program.body, len(program.body), refresh_statement(r, call, at))
	}
}

// ----------------------------------------------------------------------------
// Visitor
// ----------------------------------------------------------------------------

// One traversal serves two passes. With `collect` it only records names used
// as element types; otherwise it signs and wraps functions as it leaves them.
RefreshVisitor :: struct {
	r:       ^Refresh,
	collect: bool,
}

refresh_visit_statement :: proc(v: ^RefreshVisitor, statement: ^Statement, in_list := false) {
	if statement == nil { return }
	#partial switch node in statement^ {
	case ^ExpressionStatement: refresh_visit_expression(v, node.expression)
	case ^ReturnStatement:
		if argument, ok := node.argument.?; ok { refresh_visit_expression(v, argument) }
	case ^ThrowStatement:      refresh_visit_expression(v, node.argument)
	case ^BlockStatement:      refresh_visit_block(v, node)
	case ^LabeledStatement:    refresh_visit_statement(v, node.body)
	case ^IfStatement:
		refresh_visit_expression(v, node.test)
		refresh_visit_statement(v, node.consequent)
		if alternate, ok := node.alternate.?; ok { refresh_visit_statement(v, alternate) }
	case ^WhileStatement:
		refresh_visit_expression(v, node.test)
		refresh_visit_statement(v, node.body)
	case ^DoWhileStatement:
		refresh_visit_statement(v, node.body)
		refresh_visit_expression(v, node.test)
	case ^WithStatement:
		refresh_visit_expression(v, node.object)
		refresh_visit_statement(v, node.body)
	case ^ForStatement, ^ForInStatement, ^ForOfStatement, ^SwitchStatement, ^TryStatement:
		refresh_visit_control(v, statement)
	case ^FunctionDeclaration: refresh_visit_function_declaration(v, &node.expr, in_list)
	case ^VariableDeclaration: refresh_visit_variables(v, node, in_list)
	case ^ClassDeclaration:    refresh_visit_class(v, &node.expr)
	case ^ExportNamedDeclaration:
		if declaration, ok := node.declaration.?; ok && declaration != nil {
			inner := decl_to_stmt(declaration^)
			refresh_visit_statement(v, &inner, in_list)
		}
	case ^ExportDefaultDeclaration:
		switch inner in node.declaration^ {
		case ^Declaration:
			exported := decl_to_stmt(inner^)
			refresh_visit_statement(v, &exported, in_list)
		case ^Expression:
			// `export default function Name() {}` declares Name; it is not wrapped.
			if function, declared := inner^.(^FunctionExpression); declared {
				refresh_visit_function_declaration(v, function, in_list)
			} else {
				refresh_visit_expression(v, inner)
			}
		}
	case ^TSExportAssignment: refresh_visit_expression(v, node.expression)
	case ^TSModuleDeclaration:
		if body, ok := node.body.?; ok && body != nil && !node.declare {
			if block, is_block := body^.(^TSModuleBlock); is_block {
				stand_in := BlockStatement{loc = block.loc, body = block.body}
				refresh_visit_block(v, &stand_in, &block.body)
			}
		}
	}
}

// Loops, switches and try statements, whose parts are scopes of their own.
refresh_visit_control :: proc(v: ^RefreshVisitor, statement: ^Statement) {
	#partial switch node in statement^ {
	case ^ForStatement:
		// A loop head, a switch body and a catch clause are scopes of their own.
		if !v.collect { refresh_enter_block(v.r, 1) }
		if declaration, ok := node.init_decl.?; ok {
			refresh_visit_variables(v, declaration, false)
		}
		if init, ok := node.init_expr.?; ok { refresh_visit_expression(v, init) }
		if test, ok := node.test.?; ok { refresh_visit_expression(v, test) }
		if update, ok := node.update.?; ok { refresh_visit_expression(v, update) }
		refresh_visit_statement(v, node.body)
		if !v.collect { refresh_enter_block(v.r, -1) }
	case ^ForInStatement:
		refresh_visit_expression(v, node.right)
		if !v.collect { refresh_enter_block(v.r, 1) }
		refresh_visit_statement(v, node.body)
		if !v.collect { refresh_enter_block(v.r, -1) }
	case ^ForOfStatement:
		refresh_visit_expression(v, node.right)
		if !v.collect { refresh_enter_block(v.r, 1) }
		refresh_visit_statement(v, node.body)
		if !v.collect { refresh_enter_block(v.r, -1) }
	case ^SwitchStatement:
		refresh_visit_expression(v, node.discriminant)
		if !v.collect { refresh_enter_block(v.r, 1) }
		for &clause in node.cases {
			if test, ok := clause.test.?; ok { refresh_visit_expression(v, test) }
			refresh_visit_list(v, &clause.consequent)
		}
		if !v.collect { refresh_enter_block(v.r, -1) }
	case ^TryStatement:
		refresh_visit_block(v, &node.block)
		if handler, ok := &node.handler.?; ok { refresh_visit_block(v, &handler.body) }
		if finalizer, ok := &node.finalizer.?; ok { refresh_visit_block(v, finalizer) }
	}
}

refresh_visit_list :: proc(v: ^RefreshVisitor, list: ^[dynamic]^Statement) {
	if v.collect {
		for statement in list { refresh_visit_statement(v, statement) }
	} else {
		refresh_walk_list(v.r, list)
	}
}

// `store` receives the statement list back when the block is a stand-in for
// a body that is not a BlockStatement in the tree.
refresh_visit_block :: proc(
	v: ^RefreshVisitor, block: ^BlockStatement, store: ^[dynamic]^Statement = nil,
) {
	if v.collect {
		for statement in block.body { refresh_visit_statement(v, statement) }
	} else {
		refresh_walk_block(v.r, block)
		if store != nil { store^ = block.body }
	}
}

refresh_visit_params :: proc(v: ^RefreshVisitor, params: []FunctionParameter) {
	for param in params {
		if value, ok := param.default_val.?; ok { refresh_visit_expression(v, value) }
	}
}

// Walks a function body. `sign` is false for methods and accessors, which
// cannot be wrapped: their Hook calls are theirs but go unreported.
refresh_visit_body :: proc(
	v: ^RefreshVisitor, function: ^FunctionExpression, sign: bool) -> Maybe(RefreshSignature,
) {
	refresh_visit_params(v, function.params[:])
	if function.no_body { return nil }
	if v.collect {
		for statement in function.body.body { refresh_visit_statement(v, statement) }
		return nil
	}
	r := v.r
	if sign { return refresh_walk_function_body(r, &function.body, function.loc) }
	ignored := new(RefreshFunction, r.state.allocator)
	ignored.calls.allocator = r.state.allocator
	append(&r.functions, ignored)
	refresh_walk_list(r, &function.body.body)
	pop(&r.functions)
	return nil
}

refresh_visit_function_declaration :: proc(
	v: ^RefreshVisitor, function: ^FunctionExpression, in_list: bool,
) {
	id, named := function.id.?
	// Without a name or a following statement there is nothing to attach to.
	signature, signed := refresh_visit_body(v, function, named && in_list).?
	if signed { refresh_name_later(v.r, signature, id) }
}

refresh_visit_variables :: proc(
	v: ^RefreshVisitor, declaration: ^VariableDeclaration, in_list: bool,
) {
	if declaration.declare { return }
	for &declarator in declaration.declarations {
		init, initialized := declarator.init.?
		if !initialized || init == nil { continue }
		id, plain := declarator.id.(^Identifier)
		if plain && in_list && !v.collect {
			// The declarator names the function, so it must stay unwrapped.
			signature: Maybe(RefreshSignature)
			named := true
			#partial switch function in init^ {
			case ^ArrowFunctionExpression:
				refresh_visit_params(v, function.params[:])
				signature = refresh_walk_arrow(v.r, function)
			case ^FunctionExpression:
				signature = refresh_visit_body(v, function, true)
			case:
				named = false
			}
			if value, signed := signature.?; signed {
				refresh_name_later(v.r, value, BindingIdentifier{id.loc, id.name})
			}
			if named { continue }
		}
		refresh_visit_expression(v, init, &declarator)
	}
}

refresh_visit_class :: proc(v: ^RefreshVisitor, class: ^ClassExpression) {
	if class.declare { return }
	if super, ok := class.super_class.?; ok { refresh_visit_expression(v, super) }
	for &element in class.body.body {
		if element.computed && element.key != nil { refresh_visit_expression(v, element.key) }
		value, present := element.value.?
		if !present || value == nil { continue }
		function, is_function := value^.(^FunctionExpression)
		switch {
		case element.kind == .Field:
			refresh_visit_expression(v, value)
		case element.kind == .StaticBlock && is_function:
			block := BlockStatement{loc = function.body.loc, body = function.body.body}
			refresh_visit_block(v, &block, &function.body.body)
		case is_function:
			refresh_visit_body(v, function, false)
		}
	}
}

// Records `useThing(...)` against the function it is called in.
refresh_note_hook :: proc(r: ^Refresh, call: ^CallExpression, declarator: ^VariableDeclarator) {
	if len(r.functions) == 0 { return }
	name := ""
	#partial switch callee in call.callee^ {
	case ^Identifier: name = callee.name
	case ^MemberExpression:
		if property, ok := callee.property^.(^Identifier); ok && !callee.computed {
			name = property.name
		}
	}
	if !refresh_is_hook_name(name) { return }
	if r.functions[len(r.functions) - 1].blocks != 0 { return }
	key := strings.builder_make(r.state.allocator)
	if declarator != nil {
		// The binding as written, without its type annotation.
		#partial switch id in declarator.id {
		case ^Identifier:    strings.write_string(&key, id.name)
		case ^ObjectPattern:
			strings.write_string(&key, refresh_pattern_text(r, id.loc, id.type_annotation))
		case ^ArrayPattern:
			strings.write_string(&key, refresh_pattern_text(r, id.loc, id.type_annotation))
		}
	}
	// State Hooks reset when their initial state is edited.
	initial := -1
	if name == "useState" && len(call.arguments) > 0 { initial = 0 }
	if name == "useReducer" && len(call.arguments) > 1 { initial = 1 }
	if initial >= 0 {
		location := loc_from_expr(call.arguments[initial])
		strings.write_byte(&key, '(')
		strings.write_string(&key, r.source[location.start:location.end])
		strings.write_byte(&key, ')')
	}
	function := r.functions[len(r.functions) - 1]
	hook := RefreshHookCall{name = name, key = strings.to_string(key), callee = call.callee}
	append(&function.calls, hook)
}

refresh_pattern_text :: proc(
	r: ^Refresh, loc: Loc, annotation: Maybe(^TSTypeAnnotation),
) -> string {
	end := loc.end
	node, annotated := annotation.?
	if annotated && node.loc.start > loc.start && node.loc.start < end {
		end = node.loc.start
	}
	return strings.trim_right(r.source[loc.start:end], " \t\r\n:")
}

// Returns the signatures of functions that the expression is, or is a call
// on. An enclosing call wraps itself with each of them.
refresh_visit_expression :: proc(
	v: ^RefreshVisitor, box: ^Expression, declarator: ^VariableDeclarator = nil, in_chain := false,
) -> []RefreshSignature {
	if box == nil { return nil }
	if expr_is_spine_node(box) { return refresh_visit_spine(v, box, declarator, in_chain) }
	r := v.r
	signatures: [dynamic]RefreshSignature
	signatures.allocator = context.temp_allocator
	#partial switch node in box^ {
	case ^ArrowFunctionExpression:
		refresh_visit_params(v, node.params[:])
		if v.collect {
			switch body in node.body {
			case ^Expression:     refresh_visit_expression(v, body)
			case ^BlockStatement: refresh_visit_block(v, body)
			}
			return nil
		}
		if signature, signed := refresh_walk_arrow(r, node).?; signed {
			append(&signatures, signature)
		}
	case ^FunctionExpression:
		if signature, signed := refresh_visit_body(v, node, true).?; signed {
			append(&signatures, signature)
		}
	case ^ClassExpression:          refresh_visit_class(v, node)
	case ^ObjectExpression:         refresh_visit_object(v, node)
	case ^ChainExpression:          refresh_visit_expression(v, node.expression, nil, true)
	case ^ParenthesizedExpression:  refresh_visit_expression(v, node.expression)
	case ^TSAsExpression:           refresh_visit_expression(v, node.expression)
	case ^TSSatisfiesExpression:    refresh_visit_expression(v, node.expression)
	case ^TSNonNullExpression:      refresh_visit_expression(v, node.expression, nil, in_chain)
	case ^TSTypeAssertion:          refresh_visit_expression(v, node.expression)
	case ^TSInstantiationExpression: refresh_visit_expression(v, node.expression)
	case ^JSXElement:             refresh_visit_jsx_element(v, node)
	case ^JSXFragment:            refresh_visit_jsx_children(v, node.children[:])
	case ^JSXExpressionContainer: refresh_visit_expression(v, node.expression)
	case ^JSXSpreadChild:         refresh_visit_expression(v, node.expression)
	case:
		refresh_visit_operands(v, box, in_chain)
	}
	if v.collect { return nil }
	refresh_finish(r, box, signatures[:])
	return signatures[:]
}

// Wraps the expression with each signature, then registers it if asked to.
refresh_finish :: proc(r: ^Refresh, box: ^Expression, signatures: []RefreshSignature) {
	for signature in signatures { refresh_wrap(r, box, signature) }
	if handle, registered := r.handles[box]; registered {
		// `handle = value`, outside any signature wrapper.
		at := loc_from_expr(box).end
		inner := new(Expression, r.state.allocator)
		inner^ = box^
		box^ = transform_assignment(r.state, refresh_identifier(r, handle, at), inner, at)^
	}
}

// Binary, logical, member and call chains nest to the left once per link and
// are not bounded by the parser's depth limit, so they are walked in a loop.
// The order matches a recursive visit: each call is noted on the way in, the
// innermost operand is visited, and the other operands follow on the way out.
refresh_visit_spine :: proc(
	v: ^RefreshVisitor, top: ^Expression, declarator: ^VariableDeclarator, in_chain: bool,
) -> []RefreshSignature {
	r := v.r
	spine: ExprSpine = ---
	if !expr_spine_open(&spine, top) { return nil }
	defer expr_spine_close(&spine)
	for box, index in spine.nodes {
		call, is_call := box^.(^CallExpression)
		if !is_call { continue }
		if v.collect {
			refresh_note_factory_call(r, call)
		} else {
			refresh_note_hook(r, call, declarator if index == 0 else nil)
		}
	}
	// The flag travels down a member or call chain only; a binary link ends it.
	chained := in_chain
	for box in spine.nodes {
		#partial switch _ in box^ { case ^BinaryExpression, ^LogicalExpression: chained = false }
	}
	refresh_visit_expression(v, spine.leaf, nil, chained)
	result: [dynamic]RefreshSignature
	result.allocator = context.temp_allocator
	#reverse for box, index in spine.nodes {
		#partial switch node in box^ {
		case ^BinaryExpression:  refresh_visit_expression(v, node.right)
		case ^LogicalExpression: refresh_visit_expression(v, node.right)
		case ^MemberExpression:  if node.computed { refresh_visit_expression(v, node.property) }
		case ^CallExpression:
			signatures: [dynamic]RefreshSignature
			signatures.allocator = context.temp_allocator
			for argument in node.arguments {
				append(&signatures, ..refresh_visit_expression(v, argument))
			}
			// A call inside an optional chain stays as written, so the chain keeps its shape.
			if in_chain || node.optional { clear(&signatures) }
			if v.collect { continue }
			refresh_finish(r, box, signatures[:])
			if index == 0 { append(&result, ..signatures[:]) }
		}
	}
	return result[:]
}

// Expressions that are neither functions nor calls: only their operands matter.
refresh_visit_operands :: proc(v: ^RefreshVisitor, box: ^Expression, in_chain: bool) {
	#partial switch node in box^ {
	case ^NewExpression:
		refresh_visit_expression(v, node.callee)
		for argument in node.arguments { refresh_visit_expression(v, argument) }
	case ^ConditionalExpression:
		refresh_visit_expression(v, node.test)
		refresh_visit_expression(v, node.consequent)
		refresh_visit_expression(v, node.alternate)
	case ^AssignmentExpression:
		refresh_visit_expression(v, node.left)
		refresh_visit_expression(v, node.right)
	case ^SequenceExpression:
		for item in node.expressions { refresh_visit_expression(v, item) }
	case ^ArrayExpression:
		for element in node.elements {
			if item, ok := element.?; ok { refresh_visit_expression(v, item) }
		}
	case ^TemplateLiteral:
		for item in node.expressions { refresh_visit_expression(v, item) }
	case ^TaggedTemplateExpression:
		refresh_visit_expression(v, node.tag)
		refresh_visit_expression(v, node.quasi)
	case ^UnaryExpression:  refresh_visit_expression(v, node.argument)
	case ^UpdateExpression: refresh_visit_expression(v, node.argument)
	case ^SpreadElement:    refresh_visit_expression(v, node.argument)
	case ^AwaitExpression:  refresh_visit_expression(v, node.argument)
	case ^YieldExpression:
		if argument, ok := node.argument.?; ok { refresh_visit_expression(v, argument) }
	case ^ImportExpression: refresh_visit_expression(v, node.source)
	}
}

refresh_visit_object :: proc(v: ^RefreshVisitor, object: ^ObjectExpression) {
	for &property in object.properties {
		if property.computed && property.key != nil { refresh_visit_expression(v, property.key) }
		if property.value == nil { continue }
		function, is_function := property.value^.(^FunctionExpression)
		if is_function && property.kind != .Init {
			refresh_visit_body(v, function, false)
		} else if is_function && refresh_is_method(v.r, property) {
			refresh_visit_body(v, function, false)
		} else {
			refresh_visit_expression(v, property.value)
		}
	}
}

// `name() {}` and `name: function () {}` are both a function-valued property
// in this tree. Only the second can be wrapped, and it is the one whose
// function starts with a keyword rather than at the key.
refresh_is_method :: proc(r: ^Refresh, property: Property) -> bool {
	function := property.value^.(^FunctionExpression)
	key := loc_from_expr(property.key)
	if function.loc.start <= key.start { return true }
	text := r.source[function.loc.start:]
	return !strings.has_prefix(text, "function") && !strings.has_prefix(text, "async")
}

refresh_visit_jsx_element :: proc(v: ^RefreshVisitor, element: ^JSXElement) {
	opening := element.opening_element
	if opening != nil {
		if name, plain := opening.name.(JSXIdentifier); plain && v.collect {
			v.r.used_as_type[name.name] = true
		}
		for attribute in opening.attributes {
			switch item in attribute {
			case JSXAttribute:
				if value, ok := item.value.?; ok { refresh_visit_expression(v, value) }
			case ^JSXSpreadAttribute: refresh_visit_expression(v, item.argument)
			}
		}
	}
	refresh_visit_jsx_children(v, element.children[:])
}

refresh_visit_jsx_children :: proc(v: ^RefreshVisitor, children: []JSXChild) {
	for child in children {
		switch item in child {
		case ^JSXElement:             refresh_visit_jsx_element(v, item)
		case ^JSXFragment:            refresh_visit_jsx_children(v, item.children[:])
		case ^JSXExpressionContainer: refresh_visit_expression(v, item.expression)
		case ^JSXSpreadChild:         refresh_visit_expression(v, item.expression)
		case ^JSXText:
		}
	}
}

// A dotted name such as `$RefreshReg$` or `import.meta.hot.register`.
refresh_binding_valid :: proc(value: string) -> bool {
	return jsx_pragma_valid(value)
}
