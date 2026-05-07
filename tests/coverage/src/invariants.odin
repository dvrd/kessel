// invariants.odin — AST structural integrity checker (Odin-native).
//
// Walks a parsed Program's statement-level nodes and asserts span invariants.
// Deep recursion into expressions is deferred to a future deepening pass;
// the Node.js verifier (tests/verifiers/verify_invariants.js) provides full
// depth-20 coverage of all 74 ESTree node types.
//
// Checked invariants:
//   I1. Every Statement has start <= end.
//   I2. Every Statement is contained within Program bounds.
//   I3. Program.source_type ∈ {script, module}.
//   I4. VariableDeclaration.kind is a valid enum value.
//   I5. No node has a span that escapes the parent.

package coverage

import "core:fmt"

import kessel "../../../src"

InvariantViolation :: struct {
	tag:     string,
	node:    string,
	message: string,
}

InvariantReport :: struct {
	violations:    [dynamic]InvariantViolation,
	node_types:    map[string]int,
	unknown_count: int,
}

invariant_report_init :: proc(r: ^InvariantReport, allocator := context.allocator) {
	r.violations = make([dynamic]InvariantViolation, 0, 8, allocator)
	r.node_types = make(map[string]int, 64, allocator)
}

invariant_report_destroy :: proc(r: ^InvariantReport) {
	delete(r.violations)
	delete(r.node_types)
}

invariant_report_ok :: proc(r: InvariantReport) -> bool {
	return len(r.violations) == 0 && r.unknown_count == 0
}

// ============================================================================
// check_program
// ============================================================================

check_program :: proc(program: ^kessel.Program, report: ^InvariantReport) {
	if program == nil { return }

	prog_start := program.loc.span.start
	prog_end   := program.loc.span.end

	// I3: source_type.
	if program.type != .Script && program.type != .Module {
		append(&report.violations, InvariantViolation{
			tag = "bad_source_type", node = "Program",
			message = fmt.tprintf("source_type = %v", program.type),
		})
	}

	for stmt in program.body {
		check_statement(stmt, prog_start, prog_end, report)
	}
}

// ============================================================================
// check_statement — walk one level deep into well-known child types
// ============================================================================

check_statement :: proc(stmt: ^kessel.Statement, parent_start, parent_end: u32, report: ^InvariantReport) {
	if stmt == nil { return }

	switch s in stmt {
	case ^kessel.ExpressionStatement:
		record("ExpressionStatement", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)
		check_expression(s.expression, s.loc.span.start, s.loc.span.end, report)

	case ^kessel.BlockStatement:
		record("BlockStatement", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)
		for sub in s.body { check_statement(sub, s.loc.span.start, s.loc.span.end, report) }

	case ^kessel.ReturnStatement:
		record("ReturnStatement", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)

	case ^kessel.IfStatement:
		record("IfStatement", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)
		check_statement(s.consequent, s.loc.span.start, s.loc.span.end, report)
		if s.alternate != nil { check_statement(s.alternate.?, s.loc.span.start, s.loc.span.end, report) }

	case ^kessel.ForStatement:
		record("ForStatement", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)
		check_statement(s.body, s.loc.span.start, s.loc.span.end, report)

	case ^kessel.ForInStatement:
		record("ForInStatement", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)
		check_statement(s.body, s.loc.span.start, s.loc.span.end, report)

	case ^kessel.ForOfStatement:
		record("ForOfStatement", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)
		check_statement(s.body, s.loc.span.start, s.loc.span.end, report)

	case ^kessel.WhileStatement:
		record("WhileStatement", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)
		check_statement(s.body, s.loc.span.start, s.loc.span.end, report)

	case ^kessel.DoWhileStatement:
		record("DoWhileStatement", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)
		check_statement(s.body, s.loc.span.start, s.loc.span.end, report)

	case ^kessel.SwitchStatement:
		record("SwitchStatement", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)
		for &c in s.cases {
			record("SwitchCase", c.loc.span.start, c.loc.span.end, s.loc.span.start, s.loc.span.end, report)
			for sub in c.consequent { check_statement(sub, c.loc.span.start, c.loc.span.end, report) }
		}

	case ^kessel.TryStatement:
		record("TryStatement", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)
		for sub in s.block.body { check_statement(sub, s.block.loc.span.start, s.block.loc.span.end, report) }
		if _, ok := s.handler.?; ok {
			h := s.handler.?
			record("CatchClause", h.loc.span.start, h.loc.span.end, s.loc.span.start, s.loc.span.end, report)
			for sub in h.body.body { check_statement(sub, h.body.loc.span.start, h.body.loc.span.end, report) }
		}
		if _, ok := s.finalizer.?; ok {
			f := s.finalizer.?
			for sub in f.body { check_statement(sub, f.loc.span.start, f.loc.span.end, report) }
		}

	case ^kessel.VariableDeclaration:
		record("VariableDeclaration", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)
		// I4: kind validity.
		switch s.kind {
		case .Var, .Let, .Const, .Using, .AwaitUsing: // ok
		case:
			append(&report.violations, InvariantViolation{
				tag = "bad_variable_kind", node = "VariableDeclaration",
				message = fmt.tprintf("kind = %v", s.kind),
			})
		}

	case ^kessel.FunctionDeclaration:
		record("FunctionDeclaration", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)
		for sub in s.body.body { check_statement(sub, s.loc.span.start, s.loc.span.end, report) }

	case ^kessel.ClassDeclaration:
		record("ClassDeclaration", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)
		for &m in s.body.body { record("ClassElement", m.loc.span.start, m.loc.span.end, s.loc.span.start, s.loc.span.end, report) }

	case ^kessel.ThrowStatement:
		record("ThrowStatement", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)

	case ^kessel.EmptyStatement:
		record("EmptyStatement", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)

	case ^kessel.DebuggerStatement:
		record("DebuggerStatement", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)

	case ^kessel.BreakStatement:
		record("BreakStatement", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)

	case ^kessel.ContinueStatement:
		record("ContinueStatement", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)

	case ^kessel.LabeledStatement:
		record("LabeledStatement", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)
		check_statement(s.body, s.loc.span.start, s.loc.span.end, report)

	case ^kessel.WithStatement:
		record("WithStatement", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)

	case ^kessel.ImportDeclaration:
		record("ImportDeclaration", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)

	case ^kessel.ExportNamedDeclaration:
		record("ExportNamedDeclaration", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)

	case ^kessel.ExportDefaultDeclaration:
		record("ExportDefaultDeclaration", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)

	case ^kessel.ExportAllDeclaration:
		record("ExportAllDeclaration", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)

	case ^kessel.TSInterfaceDeclaration:
		record("TSInterfaceDeclaration", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)

	case ^kessel.TSTypeAliasDeclaration:
		record("TSTypeAliasDeclaration", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)

	case ^kessel.TSEnumDeclaration:
		record("TSEnumDeclaration", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)

	case ^kessel.TSModuleDeclaration:
		record("TSModuleDeclaration", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)

	case ^kessel.TSImportEqualsDeclaration:
		record("TSImportEqualsDeclaration", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)

	case ^kessel.TSExportAssignment:
		record("TSExportAssignment", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)

	case ^kessel.TSNamespaceExportDeclaration:
		record("TSNamespaceExportDeclaration", s.loc.span.start, s.loc.span.end, parent_start, parent_end, report)
	}
}

// ============================================================================
// check_expression — minimal: records span, recurses one level
// ============================================================================

check_expression :: proc(expr: ^kessel.Expression, parent_start, parent_end: u32, report: ^InvariantReport) {
	if expr == nil { return }

	switch e in expr {
	case ^kessel.NullLiteral:         record("NullLiteral",         e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)
	case ^kessel.BooleanLiteral:      record("BooleanLiteral",      e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)
	case ^kessel.NumericLiteral:      record("NumericLiteral",      e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)
	case ^kessel.StringLiteral:       record("StringLiteral",       e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)
	case ^kessel.BigIntLiteral:       record("BigIntLiteral",       e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)
	case ^kessel.RegExpLiteral:       record("RegExpLiteral",       e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)
	case ^kessel.Identifier:          record("Identifier",          e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)
	case ^kessel.PrivateIdentifier:   record("PrivateIdentifier",   e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)
	case ^kessel.ThisExpression:      record("ThisExpression",      e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)
	case ^kessel.Super:               record("Super",               e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)
	case ^kessel.MetaProperty:        record("MetaProperty",        e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.ArrayExpression:
		record("ArrayExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.ObjectExpression:
		record("ObjectExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.FunctionExpression:
		record("FunctionExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)
		for sub in e.body.body { check_statement(sub, e.loc.span.start, e.loc.span.end, report) }

	case ^kessel.ArrowFunctionExpression:
		record("ArrowFunctionExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)
		switch b in e.body {
		case ^kessel.BlockStatement:
			for sub in b.body { check_statement(sub, b.loc.span.start, b.loc.span.end, report) }
		case ^kessel.Expression:
			check_expression(b, e.loc.span.start, e.loc.span.end, report)
		}

	case ^kessel.ClassExpression:
		record("ClassExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.CallExpression:
		record("CallExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.NewExpression:
		record("NewExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.MemberExpression:
		record("MemberExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.BinaryExpression:
		record("BinaryExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.UnaryExpression:
		record("UnaryExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.LogicalExpression:
		record("LogicalExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.AssignmentExpression:
		record("AssignmentExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.ConditionalExpression:
		record("ConditionalExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.TemplateLiteral:
		record("TemplateLiteral", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.TaggedTemplateExpression:
		record("TaggedTemplateExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.SequenceExpression:
		record("SequenceExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.SpreadElement:
		record("SpreadElement", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.YieldExpression:
		record("YieldExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.AwaitExpression:
		record("AwaitExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.ChainExpression:
		record("ChainExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.ImportExpression:
		record("ImportExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.UpdateExpression:
		record("UpdateExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.JSXElement:
		record("JSXElement", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.JSXFragment:
		record("JSXFragment", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.JSXText:
		record("JSXText", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.JSXExpressionContainer:
		record("JSXExpressionContainer", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.JSXEmptyExpression:
		record("JSXEmptyExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.JSXSpreadChild:
		record("JSXSpreadChild", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.TSAsExpression:
		record("TSAsExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.TSSatisfiesExpression:
		record("TSSatisfiesExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.TSNonNullExpression:
		record("TSNonNullExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.TSTypeAssertion:
		record("TSTypeAssertion", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.TSInstantiationExpression:
		record("TSInstantiationExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)

	case ^kessel.ParenthesizedExpression:
		record("ParenthesizedExpression", e.loc.span.start, e.loc.span.end, parent_start, parent_end, report)
	}
}

// ============================================================================
// record — check span invariants and count node types
// ============================================================================

@(private="file")
record :: proc(type_name: string, start, end, parent_start, parent_end: u32, report: ^InvariantReport) {
	report.node_types[type_name] += 1

	// I1: start <= end.
	if start > end {
		append(&report.violations, InvariantViolation{
			tag = "start_gt_end", node = type_name,
			message = fmt.tprintf("start=%d > end=%d", start, end),
		})
		return
	}

	// I2 / I5: containment within parent.
	if start < parent_start || end > parent_end {
		append(&report.violations, InvariantViolation{
			tag = "span_escape", node = type_name,
			message = fmt.tprintf("[%d..%d] escapes parent [%d..%d]", start, end, parent_start, parent_end),
		})
	}
}
