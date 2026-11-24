package kessel

// Decides whether the expression being printed needs parentheses in its
// position. The parser's own parentheses are ignored: like Prettier, the
// printer removes redundant ones and adds the ones that syntax or clarity
// require. This is a port of Prettier's needs-parens rules.

@(private = "file")
format_binary_precedence :: proc(expr: ^Expression) -> (precedence: int, text: string) {
	#partial switch node in expr^ {
	case ^LogicalExpression:
		switch node.operator {
		case .NullishCoalescing: return 1, "??"
		case .Or: return 2, "||"
		case .And: return 3, "&&"
		}
	case ^BinaryExpression:
		switch node.operator {
		case .BitOr: return 4, "|"
		case .BitXor: return 5, "^"
		case .BitAnd: return 6, "&"
		case .Eq: return 7, "=="
		case .StrictEq: return 7, "==="
		case .NotEq: return 7, "!="
		case .StrictNotEq: return 7, "!=="
		case .Lt: return 8, "<"
		case .Gt: return 8, ">"
		case .LtEq: return 8, "<="
		case .GtEq: return 8, ">="
		case .In: return 8, "in"
		case .Instanceof: return 8, "instanceof"
		case .ShiftRight: return 9, ">>"
		case .ShiftLeft: return 9, "<<"
		case .ShiftRightUnsigned: return 9, ">>>"
		case .Add: return 10, "+"
		case .Sub: return 10, "-"
		case .Mul: return 11, "*"
		case .Div: return 11, "/"
		case .Mod: return 11, "%"
		case .Pow: return 12, "**"
		}
	}
	return 0, ""
}

format_binary_operator_text :: proc(expr: ^Expression) -> string {
	_, text := format_binary_precedence(expr)
	return text
}

@(private = "file")
format_is_equality :: proc(operator: string) -> bool {
	return operator == "==" || operator == "!=" || operator == "===" || operator == "!=="
}

@(private = "file")
format_is_multiplicative :: proc(operator: string) -> bool {
	return operator == "*" || operator == "/" || operator == "%"
}

@(private = "file")
format_is_shift :: proc(operator: string) -> bool {
	return operator == ">>" || operator == ">>>" || operator == "<<"
}

// Operators of equal precedence chain on one indentation level only when
// mixing them cannot mislead the reader.
format_should_flatten :: proc(parent, child: ^Expression) -> bool {
	parent_precedence, parent_operator := format_binary_precedence(parent)
	child_precedence, child_operator := format_binary_precedence(child)
	if parent_precedence == 0 || parent_precedence != child_precedence {return false}
	if parent_operator == "**" {return false}
	if format_is_equality(parent_operator) && format_is_equality(child_operator) {return false}
	if child_operator == "%" && format_is_multiplicative(parent_operator) {return false}
	if parent_operator == "%" && format_is_multiplicative(child_operator) {return false}
	if child_operator != parent_operator &&
	   format_is_multiplicative(child_operator) &&
	   format_is_multiplicative(parent_operator) {
		return false
	}
	if format_is_shift(parent_operator) && format_is_shift(child_operator) {return false}
	return true
}

format_is_binaryish :: proc(expr: ^Expression) -> bool {
	if expr == nil {return false}
	#partial switch _ in expr^ {
	case ^BinaryExpression, ^LogicalExpression: return true
	}
	return false
}

format_needs_parens :: proc(f: ^FormatContext) -> bool {
	current := format_path_at(f, 0)
	parent := format_parent(f)
	assert(current.expr != nil)
	if current.kind == .Identifier {
		// `let` and `async` have positions where they need parentheses.
		// They are rare enough as plain identifiers to leave unformatted.
		name := current.expr^.(^Identifier).name
		if name == "let" {f.failed = true}
		return false
	}
	if format_needs_parens_at_start(f, current) {return true}
	if current.chain_root && format_chain_needs_parens(f, current, parent) {return true}
	#partial switch parent.kind {
	case .Export_Default:
		leftmost := format_expr_leftmost(current.expr)
		if leftmost != nil {
			// Prettier keeps the source's parentheses here. They are gone
			// from the tree, so the statement stays as written.
			#partial switch _ in leftmost^ {
			case ^FunctionExpression, ^ClassExpression: f.failed = true
			}
		}
		return current.kind == .Sequence
	case .Class_Declaration, .Class_Expression:
		if current.key == .Super_Class {
			#partial switch current.kind {
			case .Arrow_Function, .Assignment, .Await, .Binary, .Conditional, .Logical, .New,
			     .Object, .Sequence, .Tagged_Template, .Unary, .Update, .Yield, .TS_Non_Null:
				return true
			}
		}
	case .Binary:
		if current.key == .Left && current.kind == .Unary {
			operator := parent.expr^.(^BinaryExpression).operator
			if operator == .In || operator == .Instanceof {return true}
		}
	}
	return format_kind_needs_parens(f, current, parent)
}

// The rules that depend first on the kind of the expression itself.
@(private = "file")
format_kind_needs_parens :: proc(f: ^FormatContext, current, parent: ^FormatPathEntry) -> bool {
	#partial switch current.kind {
	case .Update:
		if parent.kind == .Unary {
			update := current.expr^.(^UpdateExpression)
			unary := parent.expr^.(^UnaryExpression)
			if !update.prefix {return false}
			if update.operator == .Increment {return unary.operator == .Plus}
			return unary.operator == .Minus
		}
		return format_unary_needs_parens(current, parent)
	case .Unary:
		return format_unary_needs_parens(current, parent)
	case .Binary, .Logical, .TS_As, .TS_Satisfies, .TS_Type_Assertion:
		return format_binaryish_needs_parens(f, current, parent)
	case .Sequence:
		return parent.kind != .For
	case .Yield:
		if parent.kind == .Await || parent.kind == .TS_Type_Assertion {return true}
		return format_await_needs_parens(current, parent)
	case .Await:
		return format_await_needs_parens(current, parent)
	case .String:
		if parent.kind == .Expression_Statement {
			grandparent := format_path_at(f, 2)
			return grandparent.kind == .Program || grandparent.kind == .Block
		}
	case .Number:
		return current.key == .Object && parent.kind == .Member
	case .Assignment:
		return format_assignment_needs_parens(f, current, parent)
	case .Conditional:
		#partial switch parent.kind {
		case .Tagged_Template, .Unary, .Spread, .Binary, .Logical, .Export_Default, .Await,
		     .TS_Type_Assertion, .TS_As, .TS_Satisfies, .TS_Non_Null:
			return true
		case .New, .Call: return current.key == .Callee
		case .Conditional: return current.key == .Test
		case .Member: return current.key == .Object
		}
	case .Function_Expression:
		#partial switch parent.kind {
		case .New, .Call: return current.key == .Callee
		case .Tagged_Template: return true
		}
	case .Arrow_Function:
		#partial switch parent.kind {
		case .Binary, .TS_As, .TS_Satisfies, .TS_Non_Null, .Tagged_Template, .Unary, .Logical,
		     .Await, .TS_Type_Assertion:
			return true
		case .New, .Call: return current.key == .Callee
		case .Member: return current.key == .Object
		case .TS_Instantiation: return current.key == .Expression
		case .Conditional: return current.key == .Test
		}
	case .Class_Expression:
		return parent.kind == .New && current.key == .Callee
	case .Call, .Member, .Tagged_Template, .TS_Non_Null:
		if current.key == .Callee && parent.kind == .New {
			return format_callee_contains_call(current.expr)
		}
	}
	return false
}

// An object, function or class at the start of a statement would parse as a
// block or declaration. The same goes for an object that starts an arrow
// function's expression body.
@(private = "file")
format_needs_parens_at_start :: proc(f: ^FormatContext, current: ^FormatPathEntry) -> bool {
	#partial switch current.kind {
	case .Object, .Function_Expression, .Class_Expression:
	case: return false
	}
	found_statement, found_arrow := false, false
	for level := 1; level < len(f.path); level += 1 {
		ancestor := format_path_at(f, level)
		if ancestor.kind == .Expression_Statement && !found_statement {
			found_statement = true
			statement := ancestor.stmt^.(^ExpressionStatement)
			if format_expr_leftmost(statement.expression) == current.expr {return true}
		}
		if ancestor.kind == .Arrow_Function && !found_arrow && current.kind == .Object {
			found_arrow = true
			arrow := ancestor.expr^.(^ArrowFunctionExpression)
			body, is_expression := arrow.body.(^Expression)
			if !is_expression {continue}
			inner := format_expr_strip(body)
			if inner == nil {continue}
			#partial switch _ in inner^ {
			case ^SequenceExpression, ^AssignmentExpression: continue
			}
			if format_expr_leftmost(body) == current.expr {return true}
		}
	}
	return false
}

// `(a?.b).c` and `(a?.b)()` end the optional chain before the outer access.
// Without the parentheses the outer access would join the chain.
@(private = "file")
format_chain_needs_parens :: proc(f: ^FormatContext, current, parent: ^FormatPathEntry) -> bool {
	#partial switch parent.kind {
	case .Member:
		member := parent.expr^.(^MemberExpression)
		return current.key == .Object && !member.optional
	case .Call:
		call := parent.expr^.(^CallExpression)
		return current.key == .Callee && !call.optional
	case .New:
		return current.key == .Callee
	case .Tagged_Template:
		return current.key == .Tag
	case .TS_Non_Null:
		f.failed = true
	}
	return false
}

@(private = "file")
format_unary_needs_parens :: proc(current, parent: ^FormatPathEntry) -> bool {
	#partial switch parent.kind {
	case .Unary:
		if current.kind != .Unary {return false}
		operator := current.expr^.(^UnaryExpression).operator
		outer := parent.expr^.(^UnaryExpression).operator
		return operator == outer && (operator == .Plus || operator == .Minus)
	case .Member: return current.key == .Object
	case .Tagged_Template, .TS_Non_Null: return true
	case .New, .Call: return current.key == .Callee
	case .Binary:
		return current.key == .Left && parent.expr^.(^BinaryExpression).operator == .Pow
	}
	return false
}

@(private = "file")
format_await_needs_parens :: proc(current, parent: ^FormatPathEntry) -> bool {
	#partial switch parent.kind {
	case .Tagged_Template, .Unary, .Logical, .Spread, .TS_As, .TS_Satisfies, .TS_Non_Null,
	     .Binary:
		return true
	case .Member: return current.key == .Object
	case .New, .Call: return current.key == .Callee
	case .Conditional: return current.key == .Test
	}
	return false
}

@(private = "file")
format_binaryish_needs_parens :: proc(
	f: ^FormatContext,
	current, parent: ^FormatPathEntry,
) -> bool {
	is_cast := current.kind == .TS_As || current.kind == .TS_Satisfies
	if current.kind == .Binary {
		if parent.kind == .Update {return true}
		if current.expr^.(^BinaryExpression).operator == .In && format_inside_for_init(f) {
			return true
		}
	}
	#partial switch parent.kind {
	case .TS_As, .TS_Satisfies: return !is_cast
	case .Conditional:
		if is_cast {return true}
		logical, is_logical := current.expr^.(^LogicalExpression)
		return is_logical && logical.operator == .NullishCoalescing
	case .New, .Call: return current.key == .Callee
	case .Class_Declaration, .Class_Expression: return current.key == .Super_Class
	case .TS_Type_Assertion, .Tagged_Template, .Unary, .Spread, .Await, .TS_Non_Null, .Update:
		return true
	case .Member: return current.key == .Object
	case .Assignment, .Assignment_Pattern:
		return current.key == .Left && (is_cast || current.kind == .TS_Type_Assertion)
	case .Logical, .Binary:
		if parent.kind == .Logical && current.kind == .Logical {
			outer := format_binary_operator_text(parent.expr)
			same := outer == format_binary_operator_text(current.expr)
			// Prettier drops the parentheses of `a || (b || c)`, which changes
			// the tree's shape. The statement stays as written instead.
			if same && current.key == .Right {f.failed = true}
			return !same
		}
		if current.kind == .TS_Type_Assertion {return false}
		if is_cast {return true}
		precedence, operator := format_binary_precedence(current.expr)
		parent_precedence, parent_operator := format_binary_precedence(parent.expr)
		if parent_precedence > precedence {return true}
		if parent_precedence == precedence && current.key == .Right {return true}
		if parent_precedence == precedence && !format_should_flatten(parent.expr, current.expr) {
			return true
		}
		if parent_precedence < precedence && operator == "%" {
			if parent_operator == "+" || parent_operator == "-" {return true}
		}
		return format_is_shift(parent_operator) ||
			parent_operator == "|" ||
			parent_operator == "^" ||
			parent_operator == "&"
	}
	return false
}

// `in` inside the head of a for loop would be read as a for-in loop.
@(private = "file")
format_inside_for_init :: proc(f: ^FormatContext) -> bool {
	for level := 1; level < len(f.path); level += 1 {
		if format_path_at(f, level).kind == .For && format_path_at(f, level - 1).key == .Init {
			return true
		}
	}
	return false
}

@(private = "file")
format_assignment_needs_parens :: proc(
	f: ^FormatContext,
	current, parent: ^FormatPathEntry,
) -> bool {
	#partial switch parent.kind {
	case .For:
		return !(current.key == .Init || current.key == .Update)
	case .Expression_Statement:
		// `{ a } = b;` would parse as a block, so the statement is wrapped.
		target := format_expr_unwrap(current.expr^.(^AssignmentExpression).left)
		if target == nil {return false}
		_, object_target := target^.(^ObjectExpression)
		return object_target
	case .Assignment:
		return false
	case .Sequence:
		grandparent := format_path_at(f, 2)
		if grandparent.kind == .For && (parent.key == .Init || parent.key == .Update) {
			return false
		}
	}
	return true
}

// `new (a.b())()` must keep the call out of the constructor expression.
@(private = "file")
format_callee_contains_call :: proc(expr: ^Expression) -> bool {
	node := format_expr_strip(expr)
	for node != nil {
		#partial switch inner in node^ {
		case ^CallExpression: return true
		case ^MemberExpression: node = format_expr_strip(inner.object)
		case ^TaggedTemplateExpression: node = format_expr_strip(inner.tag)
		case ^TSNonNullExpression: node = format_expr_strip(inner.expression)
		case: return false
		}
	}
	return false
}
