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

	prog_start := program.loc.start
	prog_end   := program.loc.end

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
		record("ExpressionStatement", s.loc.start, s.loc.end, parent_start, parent_end, report)
		check_expression(s.expression, s.loc.start, s.loc.end, report)

	case ^kessel.BlockStatement:
		record("BlockStatement", s.loc.start, s.loc.end, parent_start, parent_end, report)
		for sub in s.body { check_statement(sub, s.loc.start, s.loc.end, report) }

	case ^kessel.ReturnStatement:
		record("ReturnStatement", s.loc.start, s.loc.end, parent_start, parent_end, report)

	case ^kessel.IfStatement:
		record("IfStatement", s.loc.start, s.loc.end, parent_start, parent_end, report)
		check_statement(s.consequent, s.loc.start, s.loc.end, report)
		if s.alternate != nil { check_statement(s.alternate.?, s.loc.start, s.loc.end, report) }

	case ^kessel.ForStatement:
		record("ForStatement", s.loc.start, s.loc.end, parent_start, parent_end, report)
		check_statement(s.body, s.loc.start, s.loc.end, report)

	case ^kessel.ForInStatement:
		record("ForInStatement", s.loc.start, s.loc.end, parent_start, parent_end, report)
		check_statement(s.body, s.loc.start, s.loc.end, report)

	case ^kessel.ForOfStatement:
		record("ForOfStatement", s.loc.start, s.loc.end, parent_start, parent_end, report)
		check_statement(s.body, s.loc.start, s.loc.end, report)

	case ^kessel.WhileStatement:
		record("WhileStatement", s.loc.start, s.loc.end, parent_start, parent_end, report)
		check_statement(s.body, s.loc.start, s.loc.end, report)

	case ^kessel.DoWhileStatement:
		record("DoWhileStatement", s.loc.start, s.loc.end, parent_start, parent_end, report)
		check_statement(s.body, s.loc.start, s.loc.end, report)

	case ^kessel.SwitchStatement:
		record("SwitchStatement", s.loc.start, s.loc.end, parent_start, parent_end, report)
		for &c in s.cases {
			record("SwitchCase", c.loc.start, c.loc.end, s.loc.start, s.loc.end, report)
			for sub in c.consequent { check_statement(sub, c.loc.start, c.loc.end, report) }
		}

	case ^kessel.TryStatement:
		record("TryStatement", s.loc.start, s.loc.end, parent_start, parent_end, report)
		for sub in s.block.body { check_statement(sub, s.block.loc.start, s.block.loc.end, report) }
		if _, ok := s.handler.?; ok {
			h := s.handler.?
			record("CatchClause", h.loc.start, h.loc.end, s.loc.start, s.loc.end, report)
			for sub in h.body.body { check_statement(sub, h.body.loc.start, h.body.loc.end, report) }
		}
		if _, ok := s.finalizer.?; ok {
			f := s.finalizer.?
			for sub in f.body { check_statement(sub, f.loc.start, f.loc.end, report) }
		}

	case ^kessel.VariableDeclaration:
		record("VariableDeclaration", s.loc.start, s.loc.end, parent_start, parent_end, report)
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
		record("FunctionDeclaration", s.loc.start, s.loc.end, parent_start, parent_end, report)
		for sub in s.body.body { check_statement(sub, s.loc.start, s.loc.end, report) }

	case ^kessel.ClassDeclaration:
		record("ClassDeclaration", s.loc.start, s.loc.end, parent_start, parent_end, report)
		for &m in s.body.body { record("ClassElement", m.loc.start, m.loc.end, s.loc.start, s.loc.end, report) }

	case ^kessel.ThrowStatement:
		record("ThrowStatement", s.loc.start, s.loc.end, parent_start, parent_end, report)

	case ^kessel.EmptyStatement:
		record("EmptyStatement", s.loc.start, s.loc.end, parent_start, parent_end, report)

	case ^kessel.DebuggerStatement:
		record("DebuggerStatement", s.loc.start, s.loc.end, parent_start, parent_end, report)

	case ^kessel.BreakStatement:
		record("BreakStatement", s.loc.start, s.loc.end, parent_start, parent_end, report)

	case ^kessel.ContinueStatement:
		record("ContinueStatement", s.loc.start, s.loc.end, parent_start, parent_end, report)

	case ^kessel.LabeledStatement:
		record("LabeledStatement", s.loc.start, s.loc.end, parent_start, parent_end, report)
		check_statement(s.body, s.loc.start, s.loc.end, report)

	case ^kessel.WithStatement:
		record("WithStatement", s.loc.start, s.loc.end, parent_start, parent_end, report)

	case ^kessel.ImportDeclaration:
		record("ImportDeclaration", s.loc.start, s.loc.end, parent_start, parent_end, report)

	case ^kessel.ExportNamedDeclaration:
		record("ExportNamedDeclaration", s.loc.start, s.loc.end, parent_start, parent_end, report)

	case ^kessel.ExportDefaultDeclaration:
		record("ExportDefaultDeclaration", s.loc.start, s.loc.end, parent_start, parent_end, report)

	case ^kessel.ExportAllDeclaration:
		record("ExportAllDeclaration", s.loc.start, s.loc.end, parent_start, parent_end, report)

	case ^kessel.TSInterfaceDeclaration:
		record("TSInterfaceDeclaration", s.loc.start, s.loc.end, parent_start, parent_end, report)

	case ^kessel.TSTypeAliasDeclaration:
		record("TSTypeAliasDeclaration", s.loc.start, s.loc.end, parent_start, parent_end, report)

	case ^kessel.TSEnumDeclaration:
		record("TSEnumDeclaration", s.loc.start, s.loc.end, parent_start, parent_end, report)

	case ^kessel.TSModuleDeclaration:
		record("TSModuleDeclaration", s.loc.start, s.loc.end, parent_start, parent_end, report)

	case ^kessel.TSImportEqualsDeclaration:
		record("TSImportEqualsDeclaration", s.loc.start, s.loc.end, parent_start, parent_end, report)

	case ^kessel.TSExportAssignment:
		record("TSExportAssignment", s.loc.start, s.loc.end, parent_start, parent_end, report)

	case ^kessel.TSNamespaceExportDeclaration:
		record("TSNamespaceExportDeclaration", s.loc.start, s.loc.end, parent_start, parent_end, report)
	}
}

// ============================================================================
// check_expression — minimal: records span, recurses one level
// ============================================================================

check_expression :: proc(expr: ^kessel.Expression, parent_start, parent_end: u32, report: ^InvariantReport) {
	if expr == nil { return }

	switch e in expr {
	case ^kessel.NullLiteral:         record("NullLiteral",         e.loc.start, e.loc.end, parent_start, parent_end, report)
	case ^kessel.BooleanLiteral:      record("BooleanLiteral",      e.loc.start, e.loc.end, parent_start, parent_end, report)
	case ^kessel.NumericLiteral:      record("NumericLiteral",      e.loc.start, e.loc.end, parent_start, parent_end, report)
	case ^kessel.StringLiteral:       record("StringLiteral",       e.loc.start, e.loc.end, parent_start, parent_end, report)
	case ^kessel.BigIntLiteral:       record("BigIntLiteral",       e.loc.start, e.loc.end, parent_start, parent_end, report)
	case ^kessel.RegExpLiteral:       record("RegExpLiteral",       e.loc.start, e.loc.end, parent_start, parent_end, report)
	case ^kessel.Identifier:          record("Identifier",          e.loc.start, e.loc.end, parent_start, parent_end, report)
	case ^kessel.PrivateIdentifier:   record("PrivateIdentifier",   e.loc.start, e.loc.end, parent_start, parent_end, report)
	case ^kessel.ThisExpression:      record("ThisExpression",      e.loc.start, e.loc.end, parent_start, parent_end, report)
	case ^kessel.Super:               record("Super",               e.loc.start, e.loc.end, parent_start, parent_end, report)
	case ^kessel.MetaProperty:        record("MetaProperty",        e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.ArrayExpression:
		record("ArrayExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.ObjectExpression:
		record("ObjectExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.FunctionExpression:
		record("FunctionExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)
		for sub in e.body.body { check_statement(sub, e.loc.start, e.loc.end, report) }

	case ^kessel.ArrowFunctionExpression:
		record("ArrowFunctionExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)
		switch b in e.body {
		case ^kessel.BlockStatement:
			for sub in b.body { check_statement(sub, b.loc.start, b.loc.end, report) }
		case ^kessel.Expression:
			check_expression(b, e.loc.start, e.loc.end, report)
		}

	case ^kessel.ClassExpression:
		record("ClassExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.CallExpression:
		record("CallExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.NewExpression:
		record("NewExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.MemberExpression:
		record("MemberExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.BinaryExpression:
		record("BinaryExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.UnaryExpression:
		record("UnaryExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.LogicalExpression:
		record("LogicalExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.AssignmentExpression:
		record("AssignmentExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.ConditionalExpression:
		record("ConditionalExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.TemplateLiteral:
		record("TemplateLiteral", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.TaggedTemplateExpression:
		record("TaggedTemplateExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.SequenceExpression:
		record("SequenceExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.SpreadElement:
		record("SpreadElement", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.YieldExpression:
		record("YieldExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.AwaitExpression:
		record("AwaitExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.ChainExpression:
		record("ChainExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.ImportExpression:
		record("ImportExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.UpdateExpression:
		record("UpdateExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.JSXElement:
		record("JSXElement", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.JSXFragment:
		record("JSXFragment", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.JSXText:
		record("JSXText", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.JSXExpressionContainer:
		record("JSXExpressionContainer", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.JSXEmptyExpression:
		record("JSXEmptyExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.JSXSpreadChild:
		record("JSXSpreadChild", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.TSAsExpression:
		record("TSAsExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.TSSatisfiesExpression:
		record("TSSatisfiesExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.TSNonNullExpression:
		record("TSNonNullExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.TSTypeAssertion:
		record("TSTypeAssertion", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.TSInstantiationExpression:
		record("TSInstantiationExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)

	case ^kessel.ParenthesizedExpression:
		record("ParenthesizedExpression", e.loc.start, e.loc.end, parent_start, parent_end, report)
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
