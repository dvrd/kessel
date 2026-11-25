// The AST walk's default depth against the parser's default nesting limit.
//
// The parser counts syntactic levels and the walk counts nodes, and one level
// can be several nodes deep (a class in a method is five). For every shape
// below, the test finds the deepest nesting the parser accepts at its default
// limit and requires a default walk of that tree to complete. It also checks
// that a walk cut short by depth still calls `leave` for what it entered.
package coverage

import "core:strings"
import "core:testing"
import kessel "../../../src"

@(private = "file")
Shape :: struct { name, head, pre, mid, post, tail: string, lang: kessel.Lang }

@(private = "file")
shape_source :: proc(s: Shape, n: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, s.head)
	for _ in 0 ..< n { strings.write_string(&b, s.pre) }
	strings.write_string(&b, s.mid)
	for _ in 0 ..< n { strings.write_string(&b, s.post) }
	strings.write_string(&b, s.tail)
	return strings.to_string(b)
}

@(private = "file")
Balance :: struct { open, deepest: int }

@(private = "file")
balance_enter :: proc(user: rawptr, node: kessel.AstNode) -> kessel.AstWalkAction {
	b := cast(^Balance)user
	b.open += 1
	b.deepest = max(b.deepest, b.open)
	return .Continue
}

@(private = "file")
balance_leave :: proc(user: rawptr, node: kessel.AstNode) {
	(cast(^Balance)user).open -= 1
}

// Parse `s` nested `n` deep and walk it. `parsed` is false when the parser
// rejects the source.
@(private = "file")
shape_walk :: proc(
	s: Shape, n: int, depth_max: u32,
) -> (parsed: bool, status: kessel.AstWalkStatus, balance: Balance) {
	job: kessel.ParseJob
	config := kessel.ParseConfig{lang_override = s.lang}
	if !kessel.parse_job_open_inline(&job, shape_source(s, n), config, "walk-depth") { return }
	defer kessel.parse_job_close(&job)
	kessel.parse_job_run(&job)
	if len(job.parser.errors) != 0 { return }
	visitor := kessel.AstVisitor{user = &balance, enter = balance_enter, leave = balance_leave}
	status = kessel.ast_walk(job.program, visitor, context.allocator, depth_max)
	return true, status, balance
}

// The deepest nesting of `s` the parser accepts at its default limit.
@(private = "file")
shape_parser_max :: proc(s: Shape) -> int {
	lo, hi := 1, 700
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if parsed, _, _ := shape_walk(s, mid, 1); parsed { lo = mid } else { hi = mid - 1 }
	}
	return lo
}

@(private = "file")
walk_depth_shapes :: proc() -> []Shape {
	@(static) shapes := []Shape{
		{"parens", "x=", "(", "1", ")", ";", .JS}, {"arrays", "x=", "[", "1", "]", ";", .JS},
		{"objects", "x=", "{a:", "1", "}", ";", .JS}, {"calls", "", "f(", "1", ")", ";", .JS},
		{"blocks", "", "{", "", "}", "", .JS}, {"if", "", "if(a){", "", "}", "", .JS},
		{"else_if", "", "if(a){}else ", "{}", "", "", .JS}, {"functions", "", "function f(){", "", "}", "", .JS},
		{"arrows", "x=", "()=>", "1", "", ";", .JS}, {"fn_exprs", "x=", "function(){return ", "1", "}", ";", .JS},
		{"classes", "", "class A{m(){", "", "}}", "", .JS}, {"class_expr", "x=", "class{m(){return ", "1", "}}", ";", .JS},
		{"obj_method", "x=", "{m(){return ", "1", "}}", ";", .JS}, {"ternary", "x=", "a?", "1", ":2", ";", .JS},
		{"unary", "x=", "!", "a", "", ";", .JS}, {"assign", "", "a=", "1", "", ";", .JS},
		{"new", "x=", "new ", "X", "", ";", .JS}, {"switch", "", "switch(a){case 1:", "", "}", "", .JS},
		{"try", "", "try{", "", "}catch(e){}", "", .JS}, {"while", "", "while(a){", "", "}", "", .JS},
		{"for_of", "", "for(const a of b){", "", "}", "", .JS}, {"labels", "", "l:", ";", "", "", .JS},
		{"getter", "x=", "{get a(){return ", "1", "}}", ";", .JS}, {"static_block", "", "class A{static{", "", "}}", "", .JS},
		{"default_param", "x=", "(a=", "1", ")=>1", ";", .JS}, {"destructure", "", "var {a:", "b", "}", "=c;", .JS},
		{"array_pattern", "", "var [", "b", "]", "=c;", .JS}, {"template", "x=", "`${", "1", "}`", ";", .JS},
		{"jsx", "x=", "<a>", "x", "</a>", ";", .JSX}, {"jsx_expr", "x=", "<a>{", "1", "}</a>", ";", .JSX},
		{"jsx_attr", "x=", "<a b={", "1", "}/>", ";", .JSX},
		{"ts_tuple", "type T=", "[", "number", "]", ";", .TS}, {"ts_generic", "type T=", "A<", "B", ">", ";", .TS},
		{"ts_objtype", "type T=", "{a:", "number", "}", ";", .TS}, {"ts_fn_type", "type T=", "()=>", "void", "", ";", .TS},
		{"ts_array", "type T=number", "", "", "[]", ";", .TS}, {"ts_cond", "type T=", "A extends B?", "C", ":D", ";", .TS},
		{"ts_namespace", "", "namespace N{", "", "}", "", .TS}, {"ts_as", "x=a", "", "", " as T", ";", .TS},
		{"ts_paren_type", "type T=", "(", "A", ")", ";", .TS}, {"ts_keyof", "type T=", "keyof ", "A", "", ";", .TS},
		{"ts_class_prop", "", "class A{p=class{p=", "1", "}}", "", .TS},
	}
	return shapes
}

@(test)
test_ast_walk_default_covers_parser_default :: proc(t: ^testing.T) {
	deepest := 0
	for s in walk_depth_shapes() {
		n := shape_parser_max(s)
		parsed, status, balance := shape_walk(s, n, kessel.AST_WALK_DEPTH_DEFAULT)
		testing.expectf(t, parsed, "%s: nesting %d does not parse", s.name, n)
		testing.expectf(t, status == .Completed, "%s at nesting %d: %v", s.name, n, status)
		testing.expectf(t, balance.open == 0, "%s: %d nodes left open", s.name, balance.open)
		deepest = max(deepest, balance.deepest)
	}
	// The premise of the default: the parser's limit alone is not enough,
	// and the default has room to spare.
	testing.expect(t, deepest > kessel.PARSE_RESOURCE_AST_DEPTH)
	testing.expect(t, deepest < kessel.AST_WALK_DEPTH_DEFAULT)
}

@(test)
test_ast_walk_depth_exceeded_stays_balanced :: proc(t: ^testing.T) {
	exceeded := 0
	for s in walk_depth_shapes() {
		parsed, status, balance := shape_walk(s, 40, 16)
		if !parsed { continue } // shapes the parser only accepts once
		// Parentheses and array types leave no node per level, so those
		// trees stay shallow and the walk completes.
		if status == .DepthExceeded { exceeded += 1 } else {
			testing.expectf(t, status == .Completed, "%s: %v", s.name, status)
		}
		testing.expectf(t, balance.open == 0, "%s: %d nodes left open", s.name, balance.open)
		testing.expectf(t, balance.deepest <= 16, "%s: entered %d deep", s.name, balance.deepest)
	}
	testing.expect(t, exceeded >= 30)
}
