package kessel

// ============================================================================
// Linter — Pass 4 of the kessel pipeline (opt-in via `kessel lint`).
//
// Walks a finished AST and reports lint diagnostics. Like the semantic
// checker (pass 3) it is a separate AST-walking pass and shares the parser's
// arena-only memory model: rule state allocates in the parse arena and nothing
// is freed.
//
// Design (see HANDOFF.md "Next Phase — Linter"):
//   • One walk. A single `#complete switch` visitor (lint_walk_stmt /
//     lint_walk_expr) dispatches every enabled rule per node — there is NOT
//     one full traversal per rule. Because the switches omit a `case:`
//     default, a newly-added AST variant fails the build.
//   • New code range. Lint diagnostics get their own `LintRule` namespace
//     (L1xxx style, L2xxx correctness, L3xxx TS-specific) kept out of the
//     parser/checker `K####` range. `lint_rule_info` mirrors `error_info`.
//   • Pure leaf rules. Each rule is a leaf `(l, ctx, node)` reporting via
//     `lint_report`; control flow (the walk) stays in the parent visitor.
//
// M1 (this slice): the visitor + rule engine skeleton. The traversal reaches
// every node and `lint_report` buffers diagnostics, but no rules are wired
// yet — `kessel lint` runs the empty pass and renders nothing. Rules land in
// M2.
// ============================================================================

import "core:fmt"
import "core:mem"
import "core:os"
import "core:encoding/json"

// LintRule is the stable, machine-readable identifier for a lint diagnostic.
// The numeric ranges mirror the planned rule families:
//   L1xxx (1000–1999): style
//   L2xxx (2000–2999): correctness
//   L3xxx (3000–3999): TypeScript-specific
//
// `None` (zero) is the sentinel for "no rule" (un-coded report).
LintRule :: enum u16 {
	None = 0,

	// L1xxx — style.
	L1001_NoEmpty        = 1001,
	L1002_NoSparseArrays = 1002,
	L1003_Eqeqeq         = 1003,
	L1004_NoVar          = 1004,

	// L2xxx — correctness.
	L2001_NoDebugger          = 2001,
	L2002_NoDupeKeys          = 2002,
	L2003_NoConstantCondition = 2003,
	L2004_NoDupeClassMembers  = 2004,
	L2005_NoRedeclare         = 2005,
	L2006_NoUndef             = 2006,
	L2007_NoUnusedVars        = 2007,
	L2008_NoShadow            = 2008,
	L2009_NoCondAssign         = 2009,
	L2010_NoUnsafeNegation     = 2010,
	L2011_NoCompareNegZero     = 2011,
	L2012_NoSelfAssign         = 2012,
	L2013_NoAsyncPromiseExecutor = 2013,
	L2014_NoDuplicateCase        = 2014,
	L2015_NoEmptyPattern         = 2015,
	L2016_NoUselessCatch         = 2016,
	L2017_NoSelfCompare          = 2017,
	L2018_UseIsnan               = 2018,
	L2019_NoNewNativeNonconstructor = 2019,
	L2020_NoObjCalls             = 2020,
	L2021_NoDeleteVar            = 2021,
	L2022_NoDupeArgs             = 2022,
	L2023_NoDupeElseIf           = 2023,
	L2024_NoPrototypeBuiltins    = 2024,
	L2025_NoCaseDeclarations     = 2025,
	L2026_ForDirection            = 2026,
	L2027_ValidTypeof             = 2027,
	L2028_NoWith                  = 2028,
	L2029_NoExAssign              = 2029,
	L2030_NoSetterReturn          = 2030,
	L2031_NoInnerDeclarations     = 2031,
	L2032_NoUnusedLabels          = 2032,
	L2033_RequireYield            = 2033,
	L2034_ConstructorSuper        = 2034,
	L2035_NoUnsafeOptionalChaining = 2035,
	L2036_NoLossOfPrecision       = 2036,
	L2037_NoUselessEscape         = 2037,
	L2038_NoIrregularWhitespace   = 2038,
	L2039_NoControlRegex          = 2039,
	L2040_NoEmptyCharacterClass   = 2040,
	L2041_NoRegexSpaces           = 2041,
	L2042_NoExtraBooleanCast      = 2042,
	L2043_NoNonoctalDecimalEscape = 2043,
	L2044_NoUnreachable           = 2044,
	L2045_NoFallthrough           = 2045,
	L2046_GetterReturn            = 2046,
	L2047_NoGlobalAssign          = 2047,
	L2048_NoImportAssign          = 2048,
	L2049_NoClassAssign           = 2049,
	L2050_NoFuncAssign            = 2050,
	L2051_NoPromiseExecReturn     = 2051,
	L2052_NoDuplicateImports      = 2052,
	L2053_NoThisBeforeSuper       = 2053,
	L2054_NoAwaitInLoop           = 2054,

	// L3xxx — TypeScript-specific.
	L3001_BanTsComment            = 3001,
	L3002_NoExplicitAny           = 3002,
	L3003_PreferAsConst           = 3003,
	L3004_NoNamespace             = 3004,
	L3005_NoNonNullAssertion      = 3005,
	L3006_ConsistentTypeImports   = 3006,
	L3007_NoInferrableTypes       = 3007,
	L3008_NoDuplicateEnumValues   = 3008,
	L3009_PreferTsExpectError     = 3009,
	L3010_NoEmptyInterface        = 3010,
	L3011_NoRequireImports        = 3011,
	L3012_NoTypeAlias             = 3012,

	// L4xxx — unicorn / best-practice.
	L4001_NoEmptyFunction          = 4001,
	L4002_NoConstantBinaryExpr     = 4002,
	L4003_NoDoubleEquals           = 4003,
	L4004_NoArrayConstructor       = 4004,
	L4005_NoThrowLiteral           = 4005,
	L4006_NoUnusedExpressions      = 4006,
	L4007_NoVoidZero               = 4007,
	L4008_NoEval                   = 4008,
	L4009_NoImpliedEval            = 4009,
	L4010_NoReturnAssign           = 4010,
	L4011_NoNewWrappers            = 4011,
	L4012_PreferConst              = 4012,
	L4013_NoLabelVar               = 4013,
	L4014_NoLoneBlocks             = 4014,
	L4015_NoMultiStr               = 4015,
	L4016_NoNewFunc                = 4016,
	L4017_NoOctalEscape            = 4017,
	L4018_NoProto                  = 4018,
	L4019_NoScriptUrl              = 4019,
	L4020_NoSequences              = 4020,
	L4021_NoUselessConcat          = 4021,
	L4022_NoIterator               = 4022,
	L4023_NoCallerCallee           = 4023,
	L4024_NoUnsafeFinally          = 4024,
	L4025_NoExtendNative           = 4025,
	L4026_PreferObjectSpread       = 4026,
	L4027_NoUselessRename          = 4027,
	L4028_SymbolDescription        = 4028,
	L4029_NoAlert                  = 4029,
	L4030_NoEmptyStaticBlock       = 4030,
	L4031_DefaultCaseLast          = 4031,
	L4032_NoConstructorReturn      = 4032,
	L4033_NoNewObject              = 4033,
	L4034_NoUselessConstructor     = 4034,
	L4035_NoCommaOperatorSeq       = 4035,
	L4036_PreferTemplate           = 4036,
	L4037_NoConsole                = 4037,
	L4038_GuardForIn               = 4038,
	L4039_NoTemplateCurlyInString  = 4039,
	L4040_NoNestedTernary          = 4040,
	L4041_NoUnneededTernary         = 4041,
	L4042_NoLonelyIf                = 4042,
	L4043_PreferNumericLiterals     = 4043,
	L4044_NoUselessCall             = 4044,
	L4045_NoVoid                    = 4045,
	L4046_NoBitwise                 = 4046,
	L4047_NoContinue                = 4047,
	L4048_NoPlusplus                = 4048,
	L4049_Yoda                      = 4049,
	L4050_NoUselessComputedKey      = 4050,
	L4051_NoUselessReturn           = 4051,
	L4052_PreferArrowCallback       = 4052,
	L4053_NoElseReturn              = 4053,
	L4054_AccessorPairs             = 4054,
	L4055_GroupedAccessorPairs      = 4055,
	L4056_PreferRestParams          = 4056,
	L4057_PreferSpread              = 4057,
	L4058_NoParamReassign           = 4058,
	L4059_NoUselessAssignment       = 4059,
	L4060_NoMixedOperators          = 4060,
	L4061_NoUndefined              = 4061,
	L4062_NoInstanceof             = 4062,
	L4063_NoExtraLabel             = 4063,
	L4064_NoComparisonWithNaN      = 4064,
	L4065_NoNewSymbol             = 4065,
	L4066_NoMultilineStrings       = 4066,
	L4067_NoStringCase            = 4067,
	L4068_PreferDotNotation       = 4068,
	L4069_NoUnsafeDeclaration      = 4069,
	L4070_NoMagicNumbers           = 4070,
	L4071_MaxDepth                 = 4071,
	L4072_MaxLines                 = 4072,
	L4073_MaxParams                = 4073,
	L4074_NoLoopFunc               = 4074,
	L4075_NoMagicStrings           = 4075,
	L4076_NoImplicitCoercion        = 4076,
	L4077_NoBufferConstructor       = 4077,
	L4078_NoOctalEscape             = 4078,
	L4079_NoImplicitGlobals         = 4079,
	L4080_NoRestrictedGlobals       = 4080,
	L4081_NoRestrictedSyntax        = 4081,
	L4082_PreferExponentiationOperator = 4082,
	L4084_NoUselessCatch             = 4084,
	L4085_NoUselessConstructor      = 4085,
	L4086_NoUselessRename            = 4086,
	L4087_PreferObjectHasOwn         = 4087,
	L4088_NoUselessUnary               = 4088,
	L4089_NoUselessOperator             = 4089,
	L4093_NoUselessElse              = 4093,
	L4094_PreferObjectLiteral        = 4094,
	L4095_NoObjectConstructor        = 4095,
	L4096_NoArrowFunctionsInClass    = 4096,
	L4097_NoClassAssignInClass       = 4097,
	L4098_NoNegatedCondition         = 4098,
	L4099_OperatorAssignment         = 4099,
}

// LintRuleInfo is the static record looked up by LintRule. Held in a
// `#partial switch` rather than a map to keep lookup branchless and avoid
// runtime initialisation. All strings are compile-time literals.
LintRuleInfo :: struct {
	name:             string,   // ESLint-style kebab-case rule name
	default_message:  string,   // canonical wording; call sites MAY override
	default_severity: Severity,
	default_enabled:  bool,     // whether the rule fires without explicit opt-in
}

// lint_rule_info returns the canonical record for a rule. Unknown rules
// return a zero `LintRuleInfo` (silent fallback — never crashes the linter).
// M1 ships the table scaffold; the rule bodies that consume these records
// land in M2.
lint_rule_info :: proc(rule: LintRule) -> LintRuleInfo {
	#partial switch rule {
	case .L1001_NoEmpty:
		return LintRuleInfo{
			name = "no-empty", default_message = "empty block statement",
			default_severity = .Warning, default_enabled = true,
		}
	case .L1002_NoSparseArrays:
		return LintRuleInfo{
			name = "no-sparse-arrays", default_message = "sparse array (unexpected array hole)",
			default_severity = .Warning, default_enabled = true,
		}
	case .L1003_Eqeqeq:
		return LintRuleInfo{
			name = "eqeqeq", default_message = "expected '===' and instead saw '=='",
			default_severity = .Warning, default_enabled = false,
		}
	case .L1004_NoVar:
		return LintRuleInfo{
			name = "no-var", default_message = "unexpected var, use let or const instead",
			default_severity = .Warning, default_enabled = false,
		}
	case .L2001_NoDebugger:
		return LintRuleInfo{
			name = "no-debugger", default_message = "unexpected 'debugger' statement",
			default_severity = .Error, default_enabled = true,
		}
	case .L2002_NoDupeKeys:
		return LintRuleInfo{
			name = "no-dupe-keys", default_message = "duplicate key in object literal",
			default_severity = .Error, default_enabled = true,
		}
	case .L2003_NoConstantCondition:
		return LintRuleInfo{
			name = "no-constant-condition",
			default_message = "unexpected constant condition",
			default_severity = .Error, default_enabled = false,
		}
	case .L2004_NoDupeClassMembers:
		return LintRuleInfo{
			name = "no-dupe-class-members", default_message = "duplicate class member",
			default_severity = .Error, default_enabled = true,
		}
	case .L2005_NoRedeclare:
		return LintRuleInfo{
			name = "no-redeclare",
			default_message = "identifier is already declared in this scope",
			default_severity = .Error, default_enabled = false,
		}
	case .L2006_NoUndef:
		return LintRuleInfo{
			name = "no-undef",
			default_message = "reference to undefined variable",
			default_severity = .Error, default_enabled = false,
		}
	case .L2007_NoUnusedVars:
		return LintRuleInfo{
			name = "no-unused-vars",
			default_message = "variable is declared but never used",
			default_severity = .Warning, default_enabled = false,
		}
	case .L2008_NoShadow:
		return LintRuleInfo{
			name = "no-shadow",
			default_message = "variable shadows one in an outer scope",
			default_severity = .Warning, default_enabled = false,
		}
	case .L2009_NoCondAssign:
		return LintRuleInfo{
			name = "no-cond-assign",
			default_message = "unexpected assignment within a conditional; did you mean '=='?",
			default_severity = .Error, default_enabled = true,
		}
	case .L2010_NoUnsafeNegation:
		return LintRuleInfo{
			name = "no-unsafe-negation",
			default_message = "unexpected negation of the left operand of a relational operator",
			default_severity = .Error, default_enabled = true,
		}
	case .L2011_NoCompareNegZero:
		return LintRuleInfo{
			name = "no-compare-neg-zero",
			default_message = "do not use the '===' operator to compare against -0",
			default_severity = .Error, default_enabled = true,
		}
	case .L2012_NoSelfAssign:
		return LintRuleInfo{
			name = "no-self-assign",
			default_message = "variable is assigned to itself",
			default_severity = .Error, default_enabled = true,
		}
	case .L2013_NoAsyncPromiseExecutor:
		return LintRuleInfo{
			name = "no-async-promise-executor",
			default_message = "promise executor functions should not be async",
			default_severity = .Error, default_enabled = true,
		}
	case .L2014_NoDuplicateCase:
		return LintRuleInfo{
			name = "no-duplicate-case",
			default_message = "duplicate case label",
			default_severity = .Error, default_enabled = true,
		}
	case .L2015_NoEmptyPattern:
		return LintRuleInfo{
			name = "no-empty-pattern",
			default_message = "unexpected empty destructuring pattern",
			default_severity = .Error, default_enabled = true,
		}
	case .L2016_NoUselessCatch:
		return LintRuleInfo{
			name = "no-useless-catch",
			default_message = "unnecessary catch clause that only rethrows the caught error",
			default_severity = .Error, default_enabled = true,
		}
	case .L2017_NoSelfCompare:
		return LintRuleInfo{
			name = "no-self-compare",
			default_message = "both sides of this comparison are the same",
			default_severity = .Error, default_enabled = true,
		}
	case .L2018_UseIsnan:
		return LintRuleInfo{
			name = "use-isnan",
			default_message = "use the isNaN function to compare with NaN",
			default_severity = .Error, default_enabled = true,
		}
	case .L2019_NoNewNativeNonconstructor:
		return LintRuleInfo{
			name = "no-new-native-nonconstructor",
			default_message = "this native function is not a constructor and cannot be called with 'new'",
			default_severity = .Error, default_enabled = true,
		}
	case .L2020_NoObjCalls:
		return LintRuleInfo{
			name = "no-obj-calls",
			default_message = "this global object is not a function and cannot be called",
			default_severity = .Error, default_enabled = true,
		}
	case .L2021_NoDeleteVar:
		return LintRuleInfo{
			name = "no-delete-var",
			default_message = "variables should not be deleted",
			default_severity = .Error, default_enabled = true,
		}
	case .L2022_NoDupeArgs:
		return LintRuleInfo{
			name = "no-dupe-args",
			default_message = "duplicate parameter name",
			default_severity = .Error, default_enabled = true,
		}
	case .L2023_NoDupeElseIf:
		return LintRuleInfo{
			name = "no-dupe-else-if",
			default_message = "this branch can never execute; its condition duplicates an earlier one",
			default_severity = .Error, default_enabled = true,
		}
	case .L2024_NoPrototypeBuiltins:
		return LintRuleInfo{
			name = "no-prototype-builtins",
			default_message = "do not call Object.prototype methods directly on an object",
			default_severity = .Error, default_enabled = true,
		}
	case .L2025_NoCaseDeclarations:
		return LintRuleInfo{
			name = "no-case-declarations",
			default_message = "unexpected lexical declaration in a case block; wrap it in a block",
			default_severity = .Error, default_enabled = true,
		}
	case .L2026_ForDirection:
		return LintRuleInfo{
			name = "for-direction",
			default_message = "for loop update moves in the wrong direction",
			default_severity = .Error, default_enabled = true,
		}
	case .L2027_ValidTypeof:
		return LintRuleInfo{
			name = "valid-typeof",
			default_message = "invalid typeof comparison value",
			default_severity = .Error, default_enabled = true,
		}
	case .L2028_NoWith:
		return LintRuleInfo{
			name = "no-with",
			default_message = "unexpected use of 'with' statement",
			default_severity = .Error, default_enabled = true,
		}
	case .L2029_NoExAssign:
		return LintRuleInfo{
			name = "no-ex-assign",
			default_message = "do not reassign exception parameter in catch clause",
			default_severity = .Error, default_enabled = true,
		}
	case .L2030_NoSetterReturn:
		return LintRuleInfo{
			name = "no-setter-return",
			default_message = "setter should not return a value",
			default_severity = .Error, default_enabled = true,
		}
	case .L2031_NoInnerDeclarations:
		return LintRuleInfo{
			name = "no-inner-declarations",
			default_message = "move function declaration to program or function body root",
			default_severity = .Error, default_enabled = true,
		}
	case .L2032_NoUnusedLabels:
		return LintRuleInfo{
			name = "no-unused-labels",
			default_message = "label is defined but never used",
			default_severity = .Error, default_enabled = true,
		}
	case .L2033_RequireYield:
		return LintRuleInfo{
			name = "require-yield",
			default_message = "generator function does not contain 'yield'",
			default_severity = .Error, default_enabled = true,
		}
	case .L2034_ConstructorSuper:
		return LintRuleInfo{
			name = "constructor-super",
			default_message = "derived class constructor must call super()",
			default_severity = .Error, default_enabled = true,
		}
	case .L2035_NoUnsafeOptionalChaining:
		return LintRuleInfo{
			name = "no-unsafe-optional-chaining",
			default_message = "unsafe use of optional chaining; if it short-circuits, the result is undefined",
			default_severity = .Error, default_enabled = true,
		}
	case .L2036_NoLossOfPrecision:
		return LintRuleInfo{
			name = "no-loss-of-precision",
			default_message = "numeric literal loses precision",
			default_severity = .Error, default_enabled = true,
		}
	case .L2037_NoUselessEscape:
		return LintRuleInfo{
			name = "no-useless-escape",
			default_message = "unnecessary escape character",
			default_severity = .Error, default_enabled = true,
		}
	case .L2038_NoIrregularWhitespace:
		return LintRuleInfo{
			name = "no-irregular-whitespace",
			default_message = "irregular whitespace not allowed",
			default_severity = .Error, default_enabled = true,
		}
	case .L2039_NoControlRegex:
		return LintRuleInfo{
			name = "no-control-regex",
			default_message = "unexpected control character in regular expression",
			default_severity = .Error, default_enabled = true,
		}
	case .L2040_NoEmptyCharacterClass:
		return LintRuleInfo{
			name = "no-empty-character-class",
			default_message = "empty character class in regular expression",
			default_severity = .Error, default_enabled = true,
		}
	case .L2041_NoRegexSpaces:
		return LintRuleInfo{
			name = "no-regex-spaces",
			default_message = "multiple consecutive spaces in regular expression; use a quantifier",
			default_severity = .Error, default_enabled = true,
		}
	case .L2042_NoExtraBooleanCast:
		return LintRuleInfo{
			name = "no-extra-boolean-cast",
			default_message = "redundant double negation or Boolean() call",
			default_severity = .Error, default_enabled = true,
		}
	case .L2043_NoNonoctalDecimalEscape:
		return LintRuleInfo{
			name = "no-nonoctal-decimal-escape",
			default_message = "'\\8' and '\\9' are not octal escape sequences",
			default_severity = .Error, default_enabled = true,
		}
	case .L2044_NoUnreachable:
		return LintRuleInfo{
			name = "no-unreachable",
			default_message = "unreachable code after return, throw, break, or continue",
			default_severity = .Error, default_enabled = true,
		}
	case .L2045_NoFallthrough:
		return LintRuleInfo{
			name = "no-fallthrough",
			default_message = "expected a 'break' or 'return' before 'case'",
			default_severity = .Error, default_enabled = true,
		}
	case .L2046_GetterReturn:
		return LintRuleInfo{
			name = "getter-return",
			default_message = "getter must return a value",
			default_severity = .Error, default_enabled = true,
		}
	case .L2047_NoGlobalAssign:
		return LintRuleInfo{
			name = "no-global-assign",
			default_message = "read-only global should not be modified",
			default_severity = .Error, default_enabled = true,
		}
	case .L2048_NoImportAssign:
		return LintRuleInfo{
			name = "no-import-assign",
			default_message = "imported binding should not be reassigned",
			default_severity = .Error, default_enabled = true,
		}
	case .L2049_NoClassAssign:
		return LintRuleInfo{
			name = "no-class-assign",
			default_message = "class declaration should not be reassigned",
			default_severity = .Error, default_enabled = true,
		}
	case .L2050_NoFuncAssign:
		return LintRuleInfo{
			name = "no-func-assign",
			default_message = "function declaration should not be reassigned",
			default_severity = .Error, default_enabled = true,
		}
	case .L2051_NoPromiseExecReturn:
		return LintRuleInfo{
			name = "no-promise-executor-return",
			default_message = "do not return a value from a Promise executor",
			default_severity = .Error, default_enabled = true,
		}
	case .L2052_NoDuplicateImports:
		return LintRuleInfo{
			name = "no-duplicate-imports",
			default_message = "duplicate import from the same module",
			default_severity = .Warning, default_enabled = true,
		}
	case .L2053_NoThisBeforeSuper:
		return LintRuleInfo{
			name = "no-this-before-super",
			default_message = "'this' used before 'super()' in constructor",
			default_severity = .Error, default_enabled = true,
		}
	case .L2054_NoAwaitInLoop:
		return LintRuleInfo{
			name = "no-await-in-loop",
			default_message = "unexpected 'await' inside a loop",
			default_severity = .Error, default_enabled = false,
		}
	case .L3001_BanTsComment:
		return LintRuleInfo{
			name = "ban-ts-comment",
			default_message = "do not use @ts-ignore or @ts-nocheck directives",
			default_severity = .Error, default_enabled = true,
		}
	case .L3002_NoExplicitAny:
		return LintRuleInfo{
			name = "no-explicit-any",
			default_message = "unexpected 'any' type; specify a more precise type",
			default_severity = .Warning, default_enabled = true,
		}
	case .L3003_PreferAsConst:
		return LintRuleInfo{
			name = "prefer-as-const",
			default_message = "expected 'as const' instead of literal type assertion",
			default_severity = .Warning, default_enabled = false,
		}
	case .L3004_NoNamespace:
		return LintRuleInfo{
			name = "no-namespace",
			default_message = "ES2015 module syntax is preferred over custom TypeScript namespaces",
			default_severity = .Warning, default_enabled = true,
		}
	case .L3005_NoNonNullAssertion:
		return LintRuleInfo{
			name = "no-non-null-assertion",
			default_message = "forbidden non-null assertion (postfix '!')",
			default_severity = .Warning, default_enabled = true,
		}
	case .L3006_ConsistentTypeImports:
		return LintRuleInfo{
			name = "consistent-type-imports",
			default_message = "use 'import type' for type-only imports",
			default_severity = .Warning, default_enabled = false,
		}
	case .L3007_NoInferrableTypes:
		return LintRuleInfo{
			name = "no-inferrable-types",
			default_message = "type can be trivially inferred from the initializer",
			default_severity = .Warning, default_enabled = true,
		}
	case .L3008_NoDuplicateEnumValues:
		return LintRuleInfo{
			name = "no-duplicate-enum-values",
			default_message = "duplicate enum member value",
			default_severity = .Error, default_enabled = true,
		}
	case .L3009_PreferTsExpectError:
		return LintRuleInfo{
			name = "prefer-ts-expect-error",
			default_message = "use '@ts-expect-error' instead of '@ts-ignore'",
			default_severity = .Warning, default_enabled = true,
		}
	case .L3010_NoEmptyInterface:
		return LintRuleInfo{
			name = "no-empty-interface",
			default_message = "empty interface declaration; use 'type' or 'Record' instead",
			default_severity = .Warning, default_enabled = true,
		}
	case .L3011_NoRequireImports:
		return LintRuleInfo{
			name = "no-require-imports",
			default_message = "use ES module imports instead of require()",
			default_severity = .Warning, default_enabled = false,
		}
	case .L3012_NoTypeAlias:
		return LintRuleInfo{
			name = "no-type-alias",
			default_message = "type aliases are not recommended",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4001_NoEmptyFunction:
		return LintRuleInfo{
			name = "no-empty-function",
			default_message = "unexpected empty function body",
			default_severity = .Warning, default_enabled = true,
		}
	case .L4002_NoConstantBinaryExpr:
		return LintRuleInfo{
			name = "no-constant-binary-expression",
			default_message = "this binary expression always evaluates to the same value",
			default_severity = .Error, default_enabled = true,
		}
	case .L4003_NoDoubleEquals:
		return LintRuleInfo{
			name = "no-eq-null",
			default_message = "use '===' when comparing to null",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4004_NoArrayConstructor:
		return LintRuleInfo{
			name = "no-array-constructor",
			default_message = "use array literal notation instead of new Array()",
			default_severity = .Error, default_enabled = true,
		}
	case .L4005_NoThrowLiteral:
		return LintRuleInfo{
			name = "no-throw-literal",
			default_message = "expected an error object to be thrown",
			default_severity = .Error, default_enabled = true,
		}
	case .L4006_NoUnusedExpressions:
		return LintRuleInfo{
			name = "no-unused-expressions",
			default_message = "expected an assignment or function call and instead saw an expression",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4007_NoVoidZero:
		return LintRuleInfo{
			name = "no-void",
			default_message = "expected 'undefined' and instead saw 'void'",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4008_NoEval:
		return LintRuleInfo{
			name = "no-eval",
			default_message = "eval can be harmful",
			default_severity = .Error, default_enabled = true,
		}
	case .L4009_NoImpliedEval:
		return LintRuleInfo{
			name = "no-implied-eval",
			default_message = "implied eval; use a function instead of a string argument",
			default_severity = .Error, default_enabled = true,
		}
	case .L4010_NoReturnAssign:
		return LintRuleInfo{
			name = "no-return-assign",
			default_message = "return statement should not contain assignment",
			default_severity = .Warning, default_enabled = true,
		}
	case .L4011_NoNewWrappers:
		return LintRuleInfo{
			name = "no-new-wrappers",
			default_message = "do not use String/Number/Boolean as a constructor",
			default_severity = .Error, default_enabled = true,
		}
	case .L4012_PreferConst:
		return LintRuleInfo{
			name = "prefer-const",
			default_message = "variable is never reassigned; use 'const' instead",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4013_NoLabelVar:
		return LintRuleInfo{
			name = "no-label-var",
			default_message = "label has the same name as a variable",
			default_severity = .Error, default_enabled = true,
		}
	case .L4014_NoLoneBlocks:
		return LintRuleInfo{
			name = "no-lone-blocks",
			default_message = "unnecessary block statement",
			default_severity = .Warning, default_enabled = true,
		}
	case .L4015_NoMultiStr:
		return LintRuleInfo{
			name = "no-multi-str",
			default_message = "multiline strings are not allowed",
			default_severity = .Warning, default_enabled = true,
		}
	case .L4016_NoNewFunc:
		return LintRuleInfo{
			name = "no-new-func",
			default_message = "the Function constructor is eval",
			default_severity = .Error, default_enabled = true,
		}
	case .L4017_NoOctalEscape:
		return LintRuleInfo{
			name = "no-octal-escape",
			default_message = "don't use octal escape sequences",
			default_severity = .Error, default_enabled = true,
		}
	case .L4018_NoProto:
		return LintRuleInfo{
			name = "no-proto",
			default_message = "use Object.getPrototypeOf instead of __proto__",
			default_severity = .Error, default_enabled = true,
		}
	case .L4019_NoScriptUrl:
		return LintRuleInfo{
			name = "no-script-url",
			default_message = "'javascript:' URLs are a form of eval",
			default_severity = .Error, default_enabled = true,
		}
	case .L4020_NoSequences:
		return LintRuleInfo{
			name = "no-sequences",
			default_message = "unexpected use of comma operator",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4021_NoUselessConcat:
		return LintRuleInfo{
			name = "no-useless-concat",
			default_message = "unnecessary concatenation of string literals",
			default_severity = .Warning, default_enabled = true,
		}
	case .L4022_NoIterator:
		return LintRuleInfo{
			name = "no-iterator",
			default_message = "reserved name '__iterator__'",
			default_severity = .Error, default_enabled = true,
		}
	case .L4023_NoCallerCallee:
		return LintRuleInfo{
			name = "no-caller",
			default_message = "deprecated: avoid arguments.caller and arguments.callee",
			default_severity = .Error, default_enabled = true,
		}
	case .L4024_NoUnsafeFinally:
		return LintRuleInfo{
			name = "no-unsafe-finally",
			default_message = "unsafe use of break/continue/return/throw in finally block",
			default_severity = .Error, default_enabled = true,
		}
	case .L4025_NoExtendNative:
		return LintRuleInfo{
			name = "no-extend-native",
			default_message = "do not extend native objects",
			default_severity = .Error, default_enabled = true,
		}
	case .L4026_PreferObjectSpread:
		return LintRuleInfo{
			name = "prefer-object-spread",
			default_message = "use object spread instead of Object.assign",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4027_NoUselessRename:
		return LintRuleInfo{
			name = "no-useless-rename",
			default_message = "destructuring rename to the same name is unnecessary",
			default_severity = .Warning, default_enabled = true,
		}
	case .L4028_SymbolDescription:
		return LintRuleInfo{
			name = "symbol-description",
			default_message = "expected Symbol to have a description",
			default_severity = .Warning, default_enabled = true,
		}
	case .L4029_NoAlert:
		return LintRuleInfo{
			name = "no-alert",
			default_message = "unexpected alert, confirm, or prompt",
			default_severity = .Warning, default_enabled = true,
		}
	case .L4030_NoEmptyStaticBlock:
		return LintRuleInfo{
			name = "no-empty-static-block",
			default_message = "unexpected empty class static block",
			default_severity = .Error, default_enabled = true,
		}
	case .L4031_DefaultCaseLast:
		return LintRuleInfo{
			name = "default-case-last",
			default_message = "default clause should be the last clause",
			default_severity = .Warning, default_enabled = true,
		}
	case .L4032_NoConstructorReturn:
		return LintRuleInfo{
			name = "no-constructor-return",
			default_message = "unexpected return statement in constructor",
			default_severity = .Error, default_enabled = true,
		}
	case .L4033_NoNewObject:
		return LintRuleInfo{
			name = "no-object-constructor",
			default_message = "use object literal notation instead of new Object()",
			default_severity = .Error, default_enabled = true,
		}
	case .L4034_NoUselessConstructor:
		return LintRuleInfo{
			name = "no-useless-constructor",
			default_message = "empty constructor is unnecessary",
			default_severity = .Warning, default_enabled = true,
		}
	case .L4035_NoCommaOperatorSeq:
		return LintRuleInfo{
			name = "no-sequences",
			default_message = "unexpected use of comma operator",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4036_PreferTemplate:
		return LintRuleInfo{
			name = "prefer-template",
			default_message = "use template literals instead of string concatenation",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4037_NoConsole:
		return LintRuleInfo{
			name = "no-console",
			default_message = "unexpected console statement",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4038_GuardForIn:
		return LintRuleInfo{
			name = "guard-for-in",
			default_message = "for-in loop body should be filtered with an if statement",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4039_NoTemplateCurlyInString:
		return LintRuleInfo{
			name = "no-template-curly-in-string",
			default_message = "unexpected template string expression in regular string",
			default_severity = .Warning, default_enabled = true,
		}
	case .L4040_NoNestedTernary:
		return LintRuleInfo{
			name = "no-nested-ternary",
			default_message = "do not nest ternary expressions",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4041_NoUnneededTernary:
		return LintRuleInfo{
			name = "no-unneeded-ternary",
			default_message = "unnecessary ternary; use the condition directly",
			default_severity = .Warning, default_enabled = true,
		}
	case .L4042_NoLonelyIf:
		return LintRuleInfo{
			name = "no-lonely-if",
			default_message = "unexpected 'if' as the only statement in an 'else' block",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4043_PreferNumericLiterals:
		return LintRuleInfo{
			name = "prefer-numeric-literals",
			default_message = "use binary, octal, or hex literal instead of parseInt",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4044_NoUselessCall:
		return LintRuleInfo{
			name = "no-useless-call",
			default_message = "unnecessary use of .call() or .apply()",
			default_severity = .Warning, default_enabled = true,
		}
	case .L4045_NoVoid:
		return LintRuleInfo{
			name = "no-void",
			default_message = "unexpected use of void operator",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4046_NoBitwise:
		return LintRuleInfo{
			name = "no-bitwise",
			default_message = "unexpected use of bitwise operator",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4047_NoContinue:
		return LintRuleInfo{
			name = "no-continue",
			default_message = "unexpected use of 'continue'",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4048_NoPlusplus:
		return LintRuleInfo{
			name = "no-plusplus",
			default_message = "unary operator '++/--' used",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4049_Yoda:
		return LintRuleInfo{
			name = "yoda",
			default_message = "expected literal to be on the right side of comparison",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4050_NoUselessComputedKey:
		return LintRuleInfo{
			name = "no-useless-computed-key",
			default_message = "unnecessary computed property key",
			default_severity = .Warning, default_enabled = true,
		}
	case .L4051_NoUselessReturn:
		return LintRuleInfo{
			name = "no-useless-return",
			default_message = "unnecessary return statement",
			default_severity = .Warning, default_enabled = true,
		}
	case .L4052_PreferArrowCallback:
		return LintRuleInfo{
			name = "prefer-arrow-callback",
			default_message = "prefer arrow function as callback",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4053_NoElseReturn:
		return LintRuleInfo{
			name = "no-else-return",
			default_message = "unnecessary 'else' after 'return'",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4054_AccessorPairs:
		return LintRuleInfo{
			name = "accessor-pairs",
			default_message = "expected getter and setter to be defined as a pair",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4055_GroupedAccessorPairs:
		return LintRuleInfo{
			name = "grouped-accessor-pairs",
			default_message = "getter and setter for the same property should be adjacent",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4056_PreferRestParams:
		return LintRuleInfo{
			name = "prefer-rest-params",
			default_message = "use rest parameters instead of 'arguments'",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4057_PreferSpread:
		return LintRuleInfo{
			name = "prefer-spread",
			default_message = "use spread syntax instead of '.apply()'",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4058_NoParamReassign:
		return LintRuleInfo{
			name = "no-param-reassign",
			default_message = "assignment to function parameter",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4059_NoUselessAssignment:
		return LintRuleInfo{
			name = "no-useless-assignment",
			default_message = "unnecessary assignment — value is never read",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4060_NoMixedOperators:
		return LintRuleInfo{
			name = "no-mixed-operators",
			default_message = "mixed binary operators should be parenthesized",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4061_NoUndefined:
		return LintRuleInfo{
			name = "no-undefined",
			default_message = "unexpected use of 'undefined'",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4062_NoInstanceof:
		return LintRuleInfo{
			name = "no-instanceof",
			default_message = "unexpected use of 'instanceof'",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4063_NoExtraLabel:
		return LintRuleInfo{
			name = "no-extra-label",
			default_message = "unnecessary label on statement",
			default_severity = .Warning, default_enabled = true,
		}
	case .L4064_NoComparisonWithNaN:
		return LintRuleInfo{
			name = "no-comparison-with-nan",
			default_message = "use isNaN() instead of comparing with NaN",
			default_severity = .Error, default_enabled = true,
		}
	case .L4065_NoNewSymbol:
		return LintRuleInfo{
			name = "no-new-symbol",
			default_message = "Symbol must not be called with 'new'",
			default_severity = .Error, default_enabled = true,
		}
	case .L4066_NoMultilineStrings:
		return LintRuleInfo{
			name = "no-multi-str",
			default_message = "multi-line string literal",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4067_NoStringCase:
		return LintRuleInfo{
			name = "no-string-case",
			default_message = "use toLowerCase/toUpperCase before case-insensitive comparison",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4068_PreferDotNotation:
		return LintRuleInfo{
			name = "prefer-dot-notation",
			default_message = "use dot notation instead of member expression",
			default_severity = .Warning, default_enabled = false,
		}
	case .L4069_NoUnsafeDeclaration:
		return LintRuleInfo{name="no-unsafe-declaration", default_message="unsafe 'declare' usage", default_severity=.Error, default_enabled=false}
	case .L4070_NoMagicNumbers:
		return LintRuleInfo{name="no-magic-numbers", default_message="magic number — extract to a named constant", default_severity=.Warning, default_enabled=false}
	case .L4071_MaxDepth:
		return LintRuleInfo{name="max-depth", default_message="maximum block nesting depth exceeded", default_severity=.Warning, default_enabled=false}
	case .L4072_MaxLines:
		return LintRuleInfo{name="max-lines", default_message="file has too many lines", default_severity=.Warning, default_enabled=false}
	case .L4073_MaxParams:
		return LintRuleInfo{name="max-params", default_message="too many function parameters", default_severity=.Warning, default_enabled=false}
	case .L4074_NoLoopFunc:
		return LintRuleInfo{name="no-loop-func", default_message="function declared inside a loop body", default_severity=.Error, default_enabled=true}
	case .L4075_NoMagicStrings:
		return LintRuleInfo{name="no-magic-strings", default_message="magic string literal — extract to a named constant", default_severity=.Warning, default_enabled=false}
	case .L4076_NoImplicitCoercion:
		return LintRuleInfo{name="no-implicit-coercion", default_message="use explicit conversion instead of shorthand coercion", default_severity=.Warning, default_enabled=false}
	case .L4077_NoBufferConstructor:
		return LintRuleInfo{name="no-buffer-constructor", default_message="Buffer() called without 'new'", default_severity=.Error, default_enabled=true}
	case .L4078_NoOctalEscape:
		return LintRuleInfo{name="no-octal-escape", default_message="octal escape sequence in string literal", default_severity=.Error, default_enabled=true}
	case .L4079_NoImplicitGlobals:
		return LintRuleInfo{name="no-implicit-globals", default_message="implicit global variable assignment", default_severity=.Error, default_enabled=false}
	case .L4080_NoRestrictedGlobals:
		return LintRuleInfo{name="no-restricted-globals", default_message="use of restricted global variable", default_severity=.Error, default_enabled=false}
	case .L4081_NoRestrictedSyntax:
		return LintRuleInfo{name="no-restricted-syntax", default_message="use of restricted syntax", default_severity=.Error, default_enabled=false}
	case .L4082_PreferExponentiationOperator:
		return LintRuleInfo{name="prefer-exponentiation-operator", default_message="use '** operator instead of Math.pow()", default_severity=.Warning, default_enabled=false}
	case .L4084_NoUselessCatch:
		return LintRuleInfo{name="no-useless-catch", default_message="unnecessary try/catch wrapper around throw", default_severity=.Error, default_enabled=true}
	case .L4085_NoUselessConstructor:
		return LintRuleInfo{name="no-useless-constructor", default_message="unnecessary constructor in class", default_severity=.Error, default_enabled=true}
	case .L4086_NoUselessRename:
		return LintRuleInfo{name="no-useless-rename", default_message="import/export renamed to same name", default_severity=.Warning, default_enabled=false}
	case .L4087_PreferObjectHasOwn:
		return LintRuleInfo{name="prefer-object-has-own", default_message="use Object.hasOwn() instead of Object.prototype.hasOwnProperty.call()", default_severity=.Warning, default_enabled=false}
	case .L4088_NoUselessUnary:
		return LintRuleInfo{name="no-useless-unary", default_message="unary operator applied to a literal", default_severity=.Warning, default_enabled=false}
	case .L4089_NoUselessOperator:
		return LintRuleInfo{name="no-useless-operator", default_message="operator applied with no effect", default_severity=.Warning, default_enabled=false}
	case .L4093_NoUselessElse:
		return LintRuleInfo{name="no-useless-else", default_message="'else' after a 'return' is unnecessary", default_severity=.Warning, default_enabled=false}
	case .L4094_PreferObjectLiteral:
		return LintRuleInfo{name="prefer-object-literal", default_message="use object literal instead of Object.create()", default_severity=.Warning, default_enabled=false}
	case .L4095_NoObjectConstructor:
		return LintRuleInfo{name="no-object-constructor", default_message="unnecessary Object constructor", default_severity=.Warning, default_enabled=false}
	case .L4096_NoArrowFunctionsInClass:
		return LintRuleInfo{name="no-arrow-functions-in-class", default_message="arrow function in class body", default_severity=.Warning, default_enabled=false}
	case .L4097_NoClassAssignInClass:
		return LintRuleInfo{name="no-class-assign-in-class", default_message="assignment to class name inside class body", default_severity=.Error, default_enabled=false}
	case .L4098_NoNegatedCondition:
		return LintRuleInfo{name="no-negated-condition", default_message="negated condition in an if/else — invert for readability", default_severity=.Warning, default_enabled=false}
	case .L4099_OperatorAssignment:
		return LintRuleInfo{name="operator-assignment", default_message="assignment can be shortened to a compound operator (e.g. x += y)", default_severity=.Warning, default_enabled=false}
	}
	return LintRuleInfo{}
}

// lint_rule_code_string returns the stable "L####" identifier used in JSON
// output and the pretty renderer. Returns "" for `.None`.
lint_rule_code_string :: proc(rule: LintRule) -> string {
	if rule == .None { return "" }
	return fmt.tprintf("L%04d", u16(rule))
}

// LintContext — mutable walker state threaded through the traversal. M1 keeps
// it minimal; scope-aware rules (M3) add binding/usage tables here. Bundling
// the walk state in one struct mirrors CheckerContext so save/restore around
// function / class boundaries collapses to a single struct copy.
LintContext :: struct {
	lang: Lang,
}

// Linter owns the diagnostic buffer and the enable/severity configuration.
// Mirrors `Checker`: diagnostics are `ParseError` so they share the existing
// pretty renderer (`render_pretty_diagnostics`) and JSON shape.
Linter :: struct {
	diagnostics: [dynamic]ParseError,
	allocator:   mem.Allocator,
	source:      string,
	// enabled / severity override maps. Empty in M1 (no rule fires); the
	// config surface (M4) populates these. A rule consults `lint_rule_enabled`
	// before reporting.
	enabled:  map[LintRule]bool,
	severity: map[LintRule]Severity,
	// dupe_else_if_seen memoises IfStatement chain links already covered by a
	// no-dupe-else-if (L2023) scan, so the whole-chain scan runs exactly once
	// per if/else-if chain (at its head) rather than re-firing on every link.
	dupe_else_if_seen: map[rawptr]bool,
	semantic: ^SemanticModel,
}

// init_linter constructs a Linter bound to the parse arena allocator.
init_linter :: proc(alloc: mem.Allocator) -> Linter {
	return Linter{
		diagnostics = make([dynamic]ParseError, 0, 8, alloc),
		enabled     = make(map[LintRule]bool, 0, alloc),
		severity    = make(map[LintRule]Severity, 0, alloc),
		dupe_else_if_seen = make(map[rawptr]bool, 0, alloc),
		allocator   = alloc,
	}
}

// lint_rule_enabled reports whether `rule` should fire. An explicit config
// override (M4) wins; otherwise the rule's `default_enabled` applies.
lint_rule_enabled :: proc(l: ^Linter, rule: LintRule) -> bool {
	if on, ok := l.enabled[rule]; ok { return on }
	return lint_rule_info(rule).default_enabled
}

// lint_report buffers a diagnostic. The severity comes from the per-run
// override map, falling back to the rule's default. A point span (start ==
// end) is used unless the caller supplies a real end offset.
lint_report :: proc(l: ^Linter, start, end: u32, rule: LintRule, message: string) {
	sev := lint_rule_info(rule).default_severity
	if s, ok := l.severity[rule]; ok { sev = s }
	bump_append(&l.diagnostics, ParseError{
		start     = start,
		end       = end if end > start else start,
		message   = message,
		severity  = sev,
		lint_code = rule,
	})
}

// ============================================================================
// Visitor — a single recursive traversal that reaches every node. Mirrors the
// dispatch shape of checker.odin's `ck_walk_*` family. The Statement and
// Expression switches are exhaustive (no `case:` default) so adding an AST
// variant fails the build until the visitor handles it.
//
// Recursion is bounded by AST depth (already bounded by the parser).
// ============================================================================

// lint_program is the entry point: walk every top-level statement.
lint_program :: proc(l: ^Linter, ctx: ^LintContext, program: ^Program) {
	if program == nil { return }
	lint_check_redeclare(l, ctx, program.body[:])
	lint_check_no_duplicate_imports(l, program.body[:])
	for stmt in program.body {
		lint_walk_stmt(l, ctx, stmt)
	}
	// Scope-aware rules (M3) run as a separate two-phase pass — collect
	// declarations + references, then diff them — rather than fold their
	// bookkeeping into the AST-local walk above. This mirrors regex.odin's
	// justified multi-pass design: the scope chain has different granularity
	// than the per-node rule fan-out. The pass is skipped entirely unless a
	// scope rule is enabled, so default `kessel lint` runs pay nothing.
	if lint_rule_enabled(l, .L2006_NoUndef) ||
	   lint_rule_enabled(l, .L2007_NoUnusedVars) ||
	   lint_rule_enabled(l, .L2008_NoShadow) {
		lint_scope_pass(l, ctx, program)
	}
}

lint_walk_stmt :: proc(l: ^Linter, ctx: ^LintContext, stmt: ^Statement) {
	if stmt == nil { return }
	switch v in stmt^ {
	case ^ExpressionStatement:
		if v != nil { lint_walk_expr(l, ctx, v.expression) }
	case ^BlockStatement:
		if v != nil {
			lint_check_redeclare(l, ctx, v.body[:])
			lint_check_no_inner_declarations(l, ctx, v.body[:], false)
			lint_check_no_unreachable(l, v.body[:])
			// no-empty (L1001): a bare `{}` block with no statements. Function
			// bodies are a distinct AST type (FunctionBody), so only standalone /
			// nested / control-flow-body blocks reach here — matching ESLint's
			// no-empty (empty function bodies are a separate rule).
			if len(v.body) == 0 && lint_rule_enabled(l, .L1001_NoEmpty) {
				info := lint_rule_info(.L1001_NoEmpty)
				lint_report(l, u32(v.loc.start), u32(v.loc.end), .L1001_NoEmpty, info.default_message)
			}
			for s in v.body { lint_walk_stmt(l, ctx, s) }
		}
	case ^IfStatement:
		if v != nil {
			lint_check_dupe_else_if(l, v)
			lint_check_no_lonely_if(l, v)
			lint_check_no_negated_condition(l, v)
			lint_check_no_else_return(l, v)
			lint_check_constant_condition(l, v.test, u32(v.loc.start), u32(v.loc.end))
			lint_check_cond_assign(l, v.test, u32(v.loc.start), u32(v.loc.end))
			lint_check_no_extra_boolean_cast(l, v.test, u32(v.loc.start), u32(v.loc.end))
			lint_walk_expr(l, ctx, v.test)
			lint_walk_stmt(l, ctx, v.consequent)
			if alt, ok := v.alternate.(^Statement); ok && alt != nil {
				lint_walk_stmt(l, ctx, alt)
			}
		}
	case ^WhileStatement:
		if v != nil {
			lint_check_constant_condition(l, v.test, u32(v.loc.start), u32(v.loc.end))
			lint_check_cond_assign(l, v.test, u32(v.loc.start), u32(v.loc.end))
			lint_walk_expr(l, ctx, v.test); lint_walk_stmt(l, ctx, v.body)
		}
	case ^DoWhileStatement:
		if v != nil {
			lint_check_constant_condition(l, v.test, u32(v.loc.start), u32(v.loc.end))
			lint_check_cond_assign(l, v.test, u32(v.loc.start), u32(v.loc.end))
			lint_walk_stmt(l, ctx, v.body); lint_walk_expr(l, ctx, v.test)
		}
	case ^ForStatement:
		lint_check_for_direction(l, v)
		lint_walk_for(l, ctx, v)
	case ^ForInStatement:
		if v != nil {
			if e, ok := v.left_expr.(^Expression); ok && e != nil { lint_walk_expr(l, ctx, e) }
			if d, ok := v.left_decl.(^VariableDeclaration); ok && d != nil { lint_walk_var_decl(l, ctx, d) }
			lint_walk_expr(l, ctx, v.right)
			lint_walk_stmt(l, ctx, v.body)
		}
	case ^ForOfStatement:
		if v != nil {
			if e, ok := v.left_expr.(^Expression); ok && e != nil { lint_walk_expr(l, ctx, e) }
			if d, ok := v.left_decl.(^VariableDeclaration); ok && d != nil { lint_walk_var_decl(l, ctx, d) }
			lint_walk_expr(l, ctx, v.right)
			lint_walk_stmt(l, ctx, v.body)
		}
	case ^SwitchStatement:
		lint_walk_switch(l, ctx, v)
	case ^ReturnStatement:
		if v != nil {
			lint_check_no_return_assign(l, v)
			if e, ok := v.argument.(^Expression); ok && e != nil { lint_walk_expr(l, ctx, e) }
		}
	case ^ThrowStatement:
		if v != nil { lint_check_no_throw_literal(l, v); lint_walk_expr(l, ctx, v.argument) }
	case ^TryStatement:
		lint_walk_try(l, ctx, v)
	case ^WithStatement:
		if v != nil { lint_check_no_with(l, v); lint_walk_expr(l, ctx, v.object); lint_walk_stmt(l, ctx, v.body) }
	case ^LabeledStatement:
		if v != nil { lint_check_no_unused_labels(l, v); lint_check_no_extra_label(l, v); lint_walk_stmt(l, ctx, v.body) }
	case ^VariableDeclaration:
		if v != nil { lint_check_no_inferrable_types(l, v); lint_walk_var_decl(l, ctx, v) }
	case ^FunctionDeclaration:
		if v != nil { lint_walk_function(l, ctx, &v.expr) }
	case ^ClassDeclaration:
		if v != nil { lint_walk_class(l, ctx, &v.expr) }
	case ^ExportNamedDeclaration:
		if v != nil {
			if d, ok := v.declaration.(^Declaration); ok && d != nil { lint_walk_decl(l, ctx, d) }
		}
	case ^ExportDefaultDeclaration:
		lint_walk_export_default(l, ctx, v)
	case ^DebuggerStatement:
		// no-debugger (L2001): a leaf rule — the visitor (parent) owns the walk
		// and enable gate; the rule only decides whether to report.
		if v != nil && lint_rule_enabled(l, .L2001_NoDebugger) {
			info := lint_rule_info(.L2001_NoDebugger)
			lint_report(l, u32(v.loc.start), u32(v.loc.end), .L2001_NoDebugger, info.default_message)
		}
	case ^TSModuleDeclaration:
		if v != nil { lint_check_ts_namespace(l, v) }
	case ^ContinueStatement:
		if v != nil { lint_check_no_continue(l, v) }
	case ^TSInterfaceDeclaration:
		if v != nil { lint_check_no_empty_interface(l, v) }
	case ^TSEnumDeclaration:
		if v != nil { lint_check_no_duplicate_enum_values(l, v) }
	case ^TSTypeAliasDeclaration:
		if v != nil { lint_check_no_type_alias(l, v) }
	case ^EmptyStatement, ^BreakStatement,
	     ^ImportDeclaration, ^ExportAllDeclaration,
	     ^TSImportEqualsDeclaration, ^TSExportAssignment, ^TSNamespaceExportDeclaration:
		// Leaf for traversal purposes: no JS statement/expression children the
		// current rule set inspects. TS type internals and namespace bodies are
		// not walked in M1 — M3 deepens this if a scope-aware rule needs it.
	}
}

// lint_check_dupe_else_if (no-dupe-else-if, L2023): within an if / else-if
// chain, a condition that repeats an earlier one makes its branch dead code.
// Conditions are compared by source text. The whole chain is scanned once from
// its head; every link is recorded in `dupe_else_if_seen` so the scan does not
// re-fire when the walk later reaches the nested else-if links.
lint_check_dupe_else_if :: proc(l: ^Linter, head: ^IfStatement) {
	if head == nil || !lint_rule_enabled(l, .L2023_NoDupeElseIf) { return }
	if l.dupe_else_if_seen[rawptr(head)] { return }
	seen_texts := make([dynamic]string, 0, 4, context.temp_allocator)
	cur := head
	for cur != nil {
		l.dupe_else_if_seen[rawptr(cur)] = true
		tloc := get_expression_loc(cur.test)
		if tloc.start < tloc.end && int(tloc.end) <= len(l.source) {
			text := l.source[tloc.start:tloc.end]
			is_dupe := false
			for prev in seen_texts {
				if prev == text { is_dupe = true; break }
			}
			if is_dupe {
				info := lint_rule_info(.L2023_NoDupeElseIf)
				lint_report(l, u32(tloc.start), u32(tloc.end), .L2023_NoDupeElseIf, info.default_message)
			}
			append(&seen_texts, text)
		}
		alt, ok := cur.alternate.(^Statement)
		if !ok || alt == nil { break }
		nxt, is_if := alt^.(^IfStatement)
		if !is_if || nxt == nil { break }
		cur = nxt
	}
}

lint_walk_for :: proc(l: ^Linter, ctx: ^LintContext, v: ^ForStatement) {
	if v == nil { return }
	if e, ok := v.init_expr.(^Expression); ok && e != nil { lint_walk_expr(l, ctx, e) }
	if d, ok := v.init_decl.(^VariableDeclaration); ok && d != nil { lint_walk_var_decl(l, ctx, d) }
	if t, ok := v.test.(^Expression); ok && t != nil { lint_walk_expr(l, ctx, t) }
	if u, ok := v.update.(^Expression); ok && u != nil { lint_walk_expr(l, ctx, u) }
	lint_walk_stmt(l, ctx, v.body)
}

lint_walk_switch :: proc(l: ^Linter, ctx: ^LintContext, v: ^SwitchStatement) {
	if v == nil { return }
	lint_walk_expr(l, ctx, v.discriminant)
	lint_check_duplicate_case(l, v)
	lint_check_no_fallthrough(l, v)
	lint_check_default_case_last(l, v)
	for sc in v.cases {
		if t, ok := sc.test.(^Expression); ok && t != nil { lint_walk_expr(l, ctx, t) }
		lint_check_case_declarations(l, sc.consequent[:])
		for s in sc.consequent { lint_walk_stmt(l, ctx, s) }
	}
}

// lint_check_case_declarations (no-case-declarations, L2025): a `let`, `const`,
// `function`, or `class` declared directly in a `case` block leaks across the
// whole switch (the case clauses share one lexical scope). Wrapping the case
// body in a block fixes it. `var` is unaffected (already function-scoped).
lint_check_case_declarations :: proc(l: ^Linter, body: []^Statement) {
	if !lint_rule_enabled(l, .L2025_NoCaseDeclarations) { return }
	for s in body {
		if s == nil { continue }
		flagged := false
		start, end: u32
		#partial switch d in s^ {
		case ^VariableDeclaration:
			if d != nil && (d.kind == .Let || d.kind == .Const) {
				flagged = true; start = u32(d.loc.start); end = u32(d.loc.end)
			}
		case ^FunctionDeclaration:
			if d != nil { flagged = true; start = u32(d.loc.start); end = u32(d.loc.end) }
		case ^ClassDeclaration:
			if d != nil { flagged = true; start = u32(d.loc.start); end = u32(d.loc.end) }
		}
		if flagged {
			info := lint_rule_info(.L2025_NoCaseDeclarations)
			lint_report(l, start, end, .L2025_NoCaseDeclarations, info.default_message)
		}
	}
}

// lint_check_duplicate_case (no-duplicate-case, L2014): reports a `case` label
// whose test expression is textually identical to an earlier label in the same
// switch. Duplicate labels are dead code — the first match always wins.
// Comparison uses the raw source text of each test (mirroring ESLint, which
// compares the tokenized source), so structurally identical labels collide
// regardless of the expression kind. The `default` clause (nil test) is
// skipped. The `seen` set lives in the temp allocator (scoped to the job).
lint_check_duplicate_case :: proc(l: ^Linter, v: ^SwitchStatement) {
	if v == nil || !lint_rule_enabled(l, .L2014_NoDuplicateCase) { return }
	seen := make(map[string]bool, 0, context.temp_allocator)
	for sc in v.cases {
		test, ok := sc.test.(^Expression)
		if !ok || test == nil { continue } // default clause
		loc := get_expression_loc(test)
		if int(loc.end) > len(l.source) || loc.start >= loc.end { continue }
		key := l.source[loc.start:loc.end]
		if seen[key] {
			info := lint_rule_info(.L2014_NoDuplicateCase)
			lint_report(l, u32(sc.loc.start), u32(sc.loc.end), .L2014_NoDuplicateCase, info.default_message)
		} else {
			seen[key] = true
		}
	}
}

lint_walk_try :: proc(l: ^Linter, ctx: ^LintContext, v: ^TryStatement) {
	if v == nil { return }
	lint_check_no_unsafe_finally(l, v)
	for s in v.block.body { lint_walk_stmt(l, ctx, s) }
	if h, ok := v.handler.(CatchClause); ok {
		lint_check_useless_catch(l, h)
		lint_check_no_ex_assign(l, h)
		for s in h.body.body { lint_walk_stmt(l, ctx, s) }
	}
	if f, ok := v.finalizer.(BlockStatement); ok {
		for s in f.body { lint_walk_stmt(l, ctx, s) }
	}
}

// lint_check_useless_catch (no-useless-catch, L2016): a catch clause whose
// entire body is `throw <e>;`, rethrowing the exact caught binding, adds
// nothing — the try/catch can be removed. Requires a named catch parameter
// (an optional-catch-binding `catch {}` cannot rethrow the caught value) and a
// single-statement body. Leaf rule: the parent walk owns traversal.
lint_check_useless_catch :: proc(l: ^Linter, h: CatchClause) {
	if !lint_rule_enabled(l, .L2016_NoUselessCatch) { return }
	if len(h.body.body) != 1 { return }
	pat, has_param := h.param.(Pattern)
	if !has_param { return }
	param_id, param_ok := pat.(^Identifier)
	if !param_ok || param_id == nil { return }
	throw, is_throw := h.body.body[0]^.(^ThrowStatement)
	if !is_throw || throw == nil { return }
	arg_id, arg_ok := throw.argument^.(^Identifier)
	if !arg_ok || arg_id == nil { return }
	if arg_id.name != param_id.name { return }
	info := lint_rule_info(.L2016_NoUselessCatch)
	lint_report(l, u32(h.loc.start), u32(h.loc.end), .L2016_NoUselessCatch, info.default_message)
}

lint_walk_var_decl :: proc(l: ^Linter, ctx: ^LintContext, d: ^VariableDeclaration) {
	if d == nil { return }
	// no-var (L1004, config-gated): `var` hoists and lacks block scope; prefer
	// let / const. Reported once per declaration statement.
	if d.kind == .Var && lint_rule_enabled(l, .L1004_NoVar) {
		info := lint_rule_info(.L1004_NoVar)
		lint_report(l, u32(d.loc.start), u32(d.loc.end), .L1004_NoVar, info.default_message)
	}
	for decl in d.declarations {
		lint_walk_pattern(l, ctx, decl.id)
		if init, ok := decl.init.(^Expression); ok && init != nil { lint_walk_expr(l, ctx, init) }
	}
}

lint_walk_decl :: proc(l: ^Linter, ctx: ^LintContext, d: ^Declaration) {
	if d == nil { return }
	#partial switch inner in d^ {
	case ^FunctionDeclaration: if inner != nil { lint_walk_function(l, ctx, &inner.expr) }
	case ^ClassDeclaration:    if inner != nil { lint_walk_class(l, ctx, &inner.expr) }
	case ^VariableDeclaration: if inner != nil { lint_walk_var_decl(l, ctx, inner) }
	}
}

lint_walk_export_default :: proc(l: ^Linter, ctx: ^LintContext, v: ^ExportDefaultDeclaration) {
	if v == nil || v.declaration == nil { return }
	#partial switch inner in v.declaration^ {
	case ^Expression:  if inner != nil { lint_walk_expr(l, ctx, inner) }
	case ^Declaration: if inner != nil { lint_walk_decl(l, ctx, inner) }
	}
}

lint_walk_pattern :: proc(l: ^Linter, ctx: ^LintContext, pat: Pattern) {
	if pat == nil { return }
	switch pp in pat {
	case ^Identifier, ^MemberExpression:
		// Leaf binding target (or destructuring member target).
	case ^AssignmentPattern:
		if pp != nil { lint_walk_pattern(l, ctx, pp.left); lint_walk_expr(l, ctx, pp.right) }
	case ^ObjectPattern:
		if pp != nil {
			// no-empty-pattern (L2015): `{}` binds nothing. A leaf report; the
			// parent walk owns traversal and the enable gate.
			if len(pp.properties) == 0 && lint_rule_enabled(l, .L2015_NoEmptyPattern) {
				info := lint_rule_info(.L2015_NoEmptyPattern)
				lint_report(l, u32(pp.loc.start), u32(pp.loc.end), .L2015_NoEmptyPattern, info.default_message)
			}
			for prop in pp.properties {
				if prop.computed {
					if key, have := prop.key.(ObjectPatternPropertyKey); have {
						if e, ok := key.(^Expression); ok && e != nil { lint_walk_expr(l, ctx, e) }
					}
				}
				lint_walk_pattern(l, ctx, prop.value)
			}
		}
	case ^ArrayPattern:
		if pp != nil {
			// no-empty-pattern (L2015): `[]` binds nothing.
			if len(pp.elements) == 0 && lint_rule_enabled(l, .L2015_NoEmptyPattern) {
				info := lint_rule_info(.L2015_NoEmptyPattern)
				lint_report(l, u32(pp.loc.start), u32(pp.loc.end), .L2015_NoEmptyPattern, info.default_message)
			}
			for elem in pp.elements {
				if inner, ok := elem.(Pattern); ok { lint_walk_pattern(l, ctx, inner) }
			}
		}
	case ^RestElement:
		if pp != nil { lint_walk_pattern(l, ctx, pp.argument) }
	}
}

// lint_check_delete_var (no-delete-var, L2021): `delete x` where `x` is a bare
// variable reference is a no-op in sloppy mode and a SyntaxError in strict mode
// — only object properties may be deleted. `delete obj.prop` is fine.
lint_check_delete_var :: proc(l: ^Linter, e: ^UnaryExpression) {
	if e == nil || e.operator != .Delete || !lint_rule_enabled(l, .L2021_NoDeleteVar) { return }
	if _, ok := e.argument^.(^Identifier); ok {
		info := lint_rule_info(.L2021_NoDeleteVar)
		lint_report(l, u32(e.loc.start), u32(e.loc.end), .L2021_NoDeleteVar, info.default_message)
	}
}

// lint_check_dupe_args (no-dupe-args, L2022): a function with two parameters of
// the same name. Legal only in sloppy mode (strict mode makes it a parse
// error), and always a bug — the later binding silently shadows the earlier.
// Only simple Identifier parameters participate; destructuring is skipped.
lint_check_dupe_args :: proc(l: ^Linter, params: []FunctionParameter, start, end: u32) {
	if !lint_rule_enabled(l, .L2022_NoDupeArgs) { return }
	seen := make(map[string]bool, 0, context.temp_allocator)
	for pr in params {
		id, ok := pr.pattern.(^Identifier)
		if !ok || id == nil { continue }
		if seen[id.name] {
			info := lint_rule_info(.L2022_NoDupeArgs)
			lint_report(l, start, end, .L2022_NoDupeArgs, info.default_message)
			return
		}
		seen[id.name] = true
	}
}

lint_walk_function :: proc(l: ^Linter, ctx: ^LintContext, fn: ^FunctionExpression) {
	if fn == nil { return }
	lint_check_dupe_args(l, fn.params[:], u32(fn.loc.start), u32(fn.loc.end))
	lint_check_require_yield(l, fn)
	lint_check_no_empty_function(l, fn)
	for pr in fn.params {
		lint_walk_pattern(l, ctx, pr.pattern)
		if d, ok := pr.default_val.(^Expression); ok && d != nil { lint_walk_expr(l, ctx, d) }
	}
	if !fn.no_body {
		lint_check_redeclare(l, ctx, fn.body.body[:])
		lint_check_no_unreachable(l, fn.body.body[:])
		lint_check_no_useless_return(l, fn.body.body[:])
		for s in fn.body.body { lint_walk_stmt(l, ctx, s) }
	}
}

lint_walk_arrow :: proc(l: ^Linter, ctx: ^LintContext, fn: ^ArrowFunctionExpression) {
	if fn == nil { return }
	lint_check_dupe_args(l, fn.params[:], u32(fn.loc.start), u32(fn.loc.end))
	for pr in fn.params {
		lint_walk_pattern(l, ctx, pr.pattern)
		if d, ok := pr.default_val.(^Expression); ok && d != nil { lint_walk_expr(l, ctx, d) }
	}
	switch b in fn.body {
	case ^Expression:     if b != nil { lint_walk_expr(l, ctx, b) }
	case ^BlockStatement: if b != nil { for s in b.body { lint_walk_stmt(l, ctx, s) } }
	}
}

// lint_check_dupe_class_members (no-dupe-class-members, L2004): reports a
// class member name declared more than once with the same static-ness, EXCEPT
// a single getter + single setter pair (which is legal). Computed keys,
// private names, the constructor, and static blocks are skipped. Both methods
// and data fields (kind .Method, value function-or-not) count as "data" slots;
// only kind .Get / .Set form the accessor pair exemption.
//
// Per-name slot flags: bit 0 = getter seen, bit 1 = setter seen, bit 2 = data
// seen. A member is a duplicate if its slot collides with anything already
// recorded that is not its complementary accessor.
lint_check_dupe_class_members :: proc(l: ^Linter, cls: ^ClassExpression) {
	if cls == nil || !lint_rule_enabled(l, .L2004_NoDupeClassMembers) { return }
	seen := make(map[string]u8, 0, context.temp_allocator)
	for elem in cls.body.body {
		if elem.computed || elem.key == nil { continue }
		if elem.kind == .Constructor || elem.kind == .StaticBlock { continue }
		name: string
		have := false
		#partial switch k in elem.key^ {
		case ^Identifier:    if k != nil { name = k.name;  have = true }
		case ^StringLiteral: if k != nil { name = k.value; have = true }
		}
		if !have { continue }
		key := name
		if elem.static { key = lint_static_key(name) }
		bit: u8 = 4 // data (method or field)
		if elem.kind == .Get { bit = 1 } else if elem.kind == .Set { bit = 2 }
		prev := seen[key]
		// Collision = anything seen that is not the complementary accessor.
		//   getter (1) only coexists with a lone setter (2).
		//   setter (2) only coexists with a lone getter (1).
		//   data (4) coexists with nothing.
		collides := false
		switch bit {
		case 1: collides = prev != 0 && prev != 2
		case 2: collides = prev != 0 && prev != 1
		case:   collides = prev != 0
		}
		if collides {
			info := lint_rule_info(.L2004_NoDupeClassMembers)
			lint_report(l, u32(elem.loc.start), u32(elem.loc.end), .L2004_NoDupeClassMembers, info.default_message)
		}
		seen[key] = prev | bit
	}
}

// lint_static_key namespaces a static member name so a static and an instance
// member of the same name do not collide. The "static " prefix contains a
// space, which can never appear in an identifier or quoted-string key, so the
// namespaces cannot alias.
lint_static_key :: proc(name: string) -> string {
	return fmt.tprintf("static %s", name)
}

lint_walk_class :: proc(l: ^Linter, ctx: ^LintContext, cls: ^ClassExpression) {
	if cls == nil { return }
	lint_check_dupe_class_members(l, cls)
	lint_check_constructor_super(l, cls)
	lint_check_no_this_before_super(l, cls)
	lint_check_accessor_pairs(l, cls)
	lint_check_grouped_accessor_pairs(l, cls)
	if sc, ok := cls.super_class.(^Expression); ok && sc != nil { lint_walk_expr(l, ctx, sc) }
	for elem in cls.body.body {
		lint_check_no_setter_return(l, elem)
		lint_check_getter_return(l, elem)
		lint_check_no_useless_computed_key_class(l, elem)
		if elem.computed && elem.key != nil { lint_walk_expr(l, ctx, elem.key) }
		if val, ok := elem.value.(^Expression); ok && val != nil { lint_walk_expr(l, ctx, val) }
	}
}

// lint_check_dupe_keys (no-dupe-keys, L2002): reports a duplicate property
// name within a single object literal. Computed keys are skipped (their value
// is not statically known). A get/set accessor pair is legal, so accessor
// properties (kind Get/Set) are excluded from the duplicate set; only data and
// method properties (Init/Method) participate. Allocates its `seen` set in the
// temp allocator (scoped to the parse job).
lint_check_dupe_keys :: proc(l: ^Linter, e: ^ObjectExpression) {
	if e == nil || !lint_rule_enabled(l, .L2002_NoDupeKeys) { return }
	seen := make(map[string]bool, 0, context.temp_allocator)
	for prop in e.properties {
		if prop.computed || prop.key == nil { continue }
		if prop.kind == .Get || prop.kind == .Set { continue }
		name: string
		have := false
		#partial switch k in prop.key^ {
		case ^Identifier:    if k != nil { name = k.name;  have = true }
		case ^StringLiteral: if k != nil { name = k.value; have = true }
		}
		if !have { continue }
		if seen[name] {
			info := lint_rule_info(.L2002_NoDupeKeys)
			lint_report(l, u32(prop.loc.start), u32(prop.loc.end), .L2002_NoDupeKeys, info.default_message)
		} else {
			seen[name] = true
		}
	}
}

// lint_check_sparse_array (no-sparse-arrays, L1002): reports an array literal
// that contains a hole (elision), e.g. `[1, , 3]` or `[, ]`. A trailing comma
// (`[1, 2,]`) does NOT create a hole and is not reported. Holes appear as an
// empty `Maybe(^Expression)` element. One diagnostic per array.
lint_check_sparse_array :: proc(l: ^Linter, e: ^ArrayExpression) {
	if e == nil || !lint_rule_enabled(l, .L1002_NoSparseArrays) { return }
	for el in e.elements {
		if _, ok := el.(^Expression); !ok {
			info := lint_rule_info(.L1002_NoSparseArrays)
			lint_report(l, u32(e.loc.start), u32(e.loc.end), .L1002_NoSparseArrays, info.default_message)
			return
		}
	}
}

// lint_redeclare_mark reports a duplicate declaration the second time a name is
// seen in the same scope list; otherwise records it.
lint_redeclare_mark :: proc(l: ^Linter, seen: ^map[string]bool, name: string, start, end: u32) {
	if seen[name] {
		info := lint_rule_info(.L2005_NoRedeclare)
		lint_report(l, start, end, .L2005_NoRedeclare, info.default_message)
	} else {
		seen[name] = true
	}
}

// lint_check_redeclare (no-redeclare, L2005): flags a name declared more than
// once in the SAME scope statement list — e.g. `var x; var x;` or
// `function x(){} var x;`. Only simple `Identifier` bindings are collected
// (destructuring is skipped to avoid false positives). Skipped entirely in
// TS/TSX where declaration merging makes same-name declarations legal.
// Config-gated (default-off): enable via `--rule no-redeclare:error`.
lint_check_redeclare :: proc(l: ^Linter, ctx: ^LintContext, body: []^Statement) {
	if !lint_rule_enabled(l, .L2005_NoRedeclare) { return }
	if ctx.lang == .TS || ctx.lang == .TSX { return }
	seen := make(map[string]bool, 0, context.temp_allocator)
	for s in body {
		if s == nil { continue }
		#partial switch v in s^ {
		case ^VariableDeclaration:
			if v != nil {
				for decl in v.declarations {
					if id, ok := decl.id.(^Identifier); ok && id != nil {
						lint_redeclare_mark(l, &seen, id.name, u32(id.loc.start), u32(id.loc.end))
					}
				}
			}
		case ^FunctionDeclaration:
			if v != nil {
				if id, ok := v.expr.id.(BindingIdentifier); ok {
					lint_redeclare_mark(l, &seen, id.name, u32(id.loc.start), u32(id.loc.end))
				}
			}
		case ^ClassDeclaration:
			if v != nil {
				if id, ok := v.expr.id.(BindingIdentifier); ok {
					lint_redeclare_mark(l, &seen, id.name, u32(id.loc.start), u32(id.loc.end))
				}
			}
		}
	}
}

// lint_check_eqeqeq (eqeqeq, L1003): flags loose equality (`==` / `!=`) and
// recommends the strict form. Config-gated (default-off); enable via
// `--rule eqeqeq:error`.
lint_check_eqeqeq :: proc(l: ^Linter, e: ^BinaryExpression) {
	if e == nil || !lint_rule_enabled(l, .L1003_Eqeqeq) { return }
	msg: string
	have := false
	#partial switch e.operator {
	case .Eq:    msg = "expected '===' and instead saw '=='"; have = true
	case .NotEq: msg = "expected '!==' and instead saw '!='"; have = true
	}
	if !have { return }
	lint_report(l, u32(e.loc.start), u32(e.loc.end), .L1003_Eqeqeq, msg)
}

// lint_is_constant_test reports whether an expression in a condition position
// is a compile-time constant literal (e.g. `if (true)`, `while (1)`). The
// minimal set covers the literal node kinds; compound constant folding is out
// of scope.
lint_is_constant_test :: proc(expr: ^Expression) -> bool {
	if expr == nil { return false }
	#partial switch _ in expr^ {
	case ^BooleanLiteral, ^NumericLiteral, ^StringLiteral, ^NullLiteral,
	     ^BigIntLiteral, ^RegExpLiteral:
		return true
	}
	return false
}

// lint_check_constant_condition (no-constant-condition, L2003): flags a loop /
// conditional whose test is a constant literal. Reports at the enclosing
// statement/expression span. Config-gated (default-off) — `while (true)` is a
// common intentional idiom, so the rule ships opt-in via `--rule`.
lint_check_constant_condition :: proc(l: ^Linter, test: ^Expression, start, end: u32) {
	if test == nil || !lint_rule_enabled(l, .L2003_NoConstantCondition) { return }
	if lint_is_constant_test(test) {
		info := lint_rule_info(.L2003_NoConstantCondition)
		lint_report(l, start, end, .L2003_NoConstantCondition, info.default_message)
	}
}

// lint_check_cond_assign (no-cond-assign, L2009): flags a bare assignment used
// directly as a conditional test, e.g. `if (x = 1)`. This is ESLint's
// "always" mode: kessel's AST does not preserve parentheses, so the default
// "except-parens" escape hatch (`if ((x = 1))`) cannot be honored. The common
// safe idiom `while ((m = re.exec(s)) !== null)` is unaffected — its test is a
// BinaryExpression, not a bare AssignmentExpression. Reports at the statement.
lint_check_cond_assign :: proc(l: ^Linter, test: ^Expression, start, end: u32) {
	if test == nil || !lint_rule_enabled(l, .L2009_NoCondAssign) { return }
	if a, ok := test.(^AssignmentExpression); ok && a != nil && a.operator == .Assign {
		info := lint_rule_info(.L2009_NoCondAssign)
		lint_report(l, start, end, .L2009_NoCondAssign, info.default_message)
	}
}

// lint_expr_is_neg_zero reports whether an expression is the literal `-0`
// (a unary minus applied to a numeric zero).
lint_expr_is_neg_zero :: proc(e: ^Expression) -> bool {
	if e == nil { return false }
	u, ok := e.(^UnaryExpression)
	if !ok || u == nil || u.operator != .Minus { return false }
	n, is_num := u.argument.(^NumericLiteral)
	return is_num && n != nil && n.value == 0
}

// lint_check_binary runs the AST-local BinaryExpression rules that do not need
// scope: no-unsafe-negation (L2010) — `!x in y` / `!x instanceof y`, which
// negates the wrong operand — and no-compare-neg-zero (L2011) — comparing
// against -0, which `===` cannot distinguish from +0.
lint_check_binary :: proc(l: ^Linter, e: ^BinaryExpression) {
	if e == nil { return }
	if lint_rule_enabled(l, .L2010_NoUnsafeNegation) {
		#partial switch e.operator {
		case .In, .Instanceof:
			if u, ok := e.left.(^UnaryExpression); ok && u != nil && u.operator == .LogicalNot {
				info := lint_rule_info(.L2010_NoUnsafeNegation)
				lint_report(l, u32(e.loc.start), u32(e.loc.end), .L2010_NoUnsafeNegation, info.default_message)
			}
		}
	}
	if lint_rule_enabled(l, .L2011_NoCompareNegZero) {
		#partial switch e.operator {
		case .Eq, .NotEq, .StrictEq, .StrictNotEq, .Lt, .LtEq, .Gt, .GtEq:
			if lint_expr_is_neg_zero(e.left) || lint_expr_is_neg_zero(e.right) {
				info := lint_rule_info(.L2011_NoCompareNegZero)
				lint_report(l, u32(e.loc.start), u32(e.loc.end), .L2011_NoCompareNegZero, info.default_message)
			}
		}
	}
	// use-isnan (L2018): `x === NaN` is always false — NaN is not equal to
	// anything, itself included. Callers must use `Number.isNaN(x)`.
	if lint_rule_enabled(l, .L2018_UseIsnan) {
		#partial switch e.operator {
		case .Eq, .NotEq, .StrictEq, .StrictNotEq, .Lt, .LtEq, .Gt, .GtEq:
			if lint_expr_is_nan(e.left) || lint_expr_is_nan(e.right) {
				info := lint_rule_info(.L2018_UseIsnan)
				lint_report(l, u32(e.loc.start), u32(e.loc.end), .L2018_UseIsnan, info.default_message)
			}
		}
	}
	// no-self-compare (L2017): comparing something to itself (`x === x`) is a
	// no-op or NaN check by accident. Operands are compared by source text, so
	// identifiers, member chains, and literals all match uniformly.
	if lint_rule_enabled(l, .L2017_NoSelfCompare) {
		#partial switch e.operator {
		case .Eq, .NotEq, .StrictEq, .StrictNotEq, .Lt, .LtEq, .Gt, .GtEq:
			lloc := get_expression_loc(e.left)
			rloc := get_expression_loc(e.right)
			if lloc.start < lloc.end && rloc.start < rloc.end &&
			   int(lloc.end) <= len(l.source) && int(rloc.end) <= len(l.source) &&
			   l.source[lloc.start:lloc.end] == l.source[rloc.start:rloc.end] {
				info := lint_rule_info(.L2017_NoSelfCompare)
				lint_report(l, u32(e.loc.start), u32(e.loc.end), .L2017_NoSelfCompare, info.default_message)
			}
		}
	}
}

// lint_expr_is_nan reports whether an expression is the bare global `NaN`
// identifier — the operand shape use-isnan (L2018) forbids in a comparison.
lint_expr_is_nan :: proc(e: ^Expression) -> bool {
	if e == nil { return false }
	id, ok := e^.(^Identifier)
	return ok && id != nil && id.name == "NaN"
}

// lint_check_new_native (no-new-native-nonconstructor, L2019): `new Symbol()`
// and `new BigInt()` throw at runtime — these natives are callable but not
// constructors. Only bare global identifier callees are checked.
lint_check_new_native :: proc(l: ^Linter, e: ^NewExpression) {
	if e == nil || !lint_rule_enabled(l, .L2019_NoNewNativeNonconstructor) { return }
	callee, ok := e.callee^.(^Identifier)
	if !ok || callee == nil { return }
	if callee.name == "Symbol" || callee.name == "BigInt" {
		info := lint_rule_info(.L2019_NoNewNativeNonconstructor)
		lint_report(l, u32(e.loc.start), u32(e.loc.end), .L2019_NoNewNativeNonconstructor, info.default_message)
	}
}

// lint_check_obj_calls (no-obj-calls, L2020): the namespace globals `Math`,
// `JSON`, `Reflect`, and `Atomics` are objects, not functions — calling them
// throws. Only bare global identifier callees are checked.
lint_check_obj_calls :: proc(l: ^Linter, e: ^CallExpression) {
	if e == nil || !lint_rule_enabled(l, .L2020_NoObjCalls) { return }
	callee, ok := e.callee^.(^Identifier)
	if !ok || callee == nil { return }
	switch callee.name {
	case "Math", "JSON", "Reflect", "Atomics":
		info := lint_rule_info(.L2020_NoObjCalls)
		lint_report(l, u32(e.loc.start), u32(e.loc.end), .L2020_NoObjCalls, info.default_message)
	}
}

// lint_check_prototype_builtins (no-prototype-builtins, L2024): calling an
// Object.prototype method directly on an object (`foo.hasOwnProperty(k)`)
// breaks on null-prototype objects and objects that shadow the method. The
// safe form is `Object.prototype.hasOwnProperty.call(foo, k)`. Only a direct,
// non-computed member call with the exact method name is flagged.
lint_check_prototype_builtins :: proc(l: ^Linter, e: ^CallExpression) {
	if e == nil || !lint_rule_enabled(l, .L2024_NoPrototypeBuiltins) { return }
	member, ok := e.callee^.(^MemberExpression)
	if !ok || member == nil || member.computed { return }
	prop, pok := member.property^.(^Identifier)
	if !pok || prop == nil { return }
	switch prop.name {
	case "hasOwnProperty", "isPrototypeOf", "propertyIsEnumerable":
		info := lint_rule_info(.L2024_NoPrototypeBuiltins)
		lint_report(l, u32(e.loc.start), u32(e.loc.end), .L2024_NoPrototypeBuiltins, info.default_message)
	}
}

// lint_check_self_assign (no-self-assign, L2012): flags `x = x`, an assignment
// of a bare identifier to the identically-named identifier (a no-op that is
// almost always a typo). Only simple Identifier=Identifier is checked to avoid
// false positives on member expressions with side effects.
lint_check_self_assign :: proc(l: ^Linter, e: ^AssignmentExpression) {
	if e == nil || e.operator != .Assign || !lint_rule_enabled(l, .L2012_NoSelfAssign) { return }
	lhs, lok := e.left.(^Identifier)
	rhs, rok := e.right.(^Identifier)
	if lok && rok && lhs != nil && rhs != nil && lhs.name == rhs.name {
		info := lint_rule_info(.L2012_NoSelfAssign)
		lint_report(l, u32(e.loc.start), u32(e.loc.end), .L2012_NoSelfAssign, info.default_message)
	}
}

// lint_expr_is_async_fn reports whether an expression is an async function or
// async arrow — the disallowed shape of a Promise executor.
lint_expr_is_async_fn :: proc(e: ^Expression) -> bool {
	if e == nil { return false }
	#partial switch v in e^ {
	case ^FunctionExpression:      return v != nil && v.async
	case ^ArrowFunctionExpression: return v != nil && v.async
	}
	return false
}

// lint_check_async_promise (no-async-promise-executor, L2013): flags
// `new Promise(async ...)`. An async executor swallows rejections thrown
// before the first await, so it is almost always a bug.
lint_check_async_promise :: proc(l: ^Linter, e: ^NewExpression) {
	if e == nil || !lint_rule_enabled(l, .L2013_NoAsyncPromiseExecutor) { return }
	callee, ok := e.callee.(^Identifier)
	if !ok || callee == nil || callee.name != "Promise" { return }
	if len(e.arguments) == 0 { return }
	if lint_expr_is_async_fn(e.arguments[0]) {
		info := lint_rule_info(.L2013_NoAsyncPromiseExecutor)
		lint_report(l, u32(e.loc.start), u32(e.loc.end), .L2013_NoAsyncPromiseExecutor, info.default_message)
	}
}

// lint_check_for_direction (for-direction, L2026): a for loop whose update
// moves the counter in the wrong direction relative to its test will never
// terminate. E.g. `for (i = 0; i < 10; i--)` or `for (i = 10; i > 0; i++)`.
lint_check_for_direction :: proc(l: ^Linter, v: ^ForStatement) {
	if v == nil || !lint_rule_enabled(l, .L2026_ForDirection) { return }
	test, tok := v.test.(^Expression)
	if !tok || test == nil { return }
	update, uok := v.update.(^Expression)
	if !uok || update == nil { return }
	bin, is_bin := test^.(^BinaryExpression)
	if !is_bin || bin == nil { return }
	// Identify the counter variable from the test's left side.
	counter_id, cok := bin.left^.(^Identifier)
	if !cok || counter_id == nil { return }
	// Check the update expression for UpdateExpression (i++/i--).
	upd, is_upd := update^.(^UpdateExpression)
	if !is_upd || upd == nil { return }
	upd_id, uid_ok := upd.argument^.(^Identifier)
	if !uid_ok || upd_id == nil || upd_id.name != counter_id.name { return }
	// `i < N` or `i <= N` expects i++ (increment). i-- is wrong.
	// `i > N` or `i >= N` expects i-- (decrement). i++ is wrong.
	wrong := false
	#partial switch bin.operator {
	case .Lt, .LtEq: if upd.operator == .Decrement { wrong = true }
	case .Gt, .GtEq: if upd.operator == .Increment { wrong = true }
	}
	if wrong {
		info := lint_rule_info(.L2026_ForDirection)
		lint_report(l, u32(v.loc.start), u32(v.loc.end), .L2026_ForDirection, info.default_message)
	}
}

// lint_check_valid_typeof (valid-typeof, L2027): flags `typeof x === "strang"`
// where the comparison value is not one of the valid typeof strings.
lint_check_valid_typeof :: proc(l: ^Linter, e: ^BinaryExpression) {
	if e == nil || !lint_rule_enabled(l, .L2027_ValidTypeof) { return }
	#partial switch e.operator {
	case .Eq, .NotEq, .StrictEq, .StrictNotEq:
	case: return
	}
	typeof_side: ^Expression = nil
	other_side:  ^Expression = nil
	if lint_is_typeof(e.left)  { typeof_side = e.left;  other_side = e.right }
	if lint_is_typeof(e.right) { typeof_side = e.right; other_side = e.left }
	if typeof_side == nil || other_side == nil { return }
	str, sok := other_side^.(^StringLiteral)
	if !sok || str == nil { return }
	switch str.value {
	case "undefined", "object", "boolean", "number", "string",
		"function", "symbol", "bigint":
		return // valid
	}
	info := lint_rule_info(.L2027_ValidTypeof)
	lint_report(l, u32(e.loc.start), u32(e.loc.end), .L2027_ValidTypeof, info.default_message)
}

lint_is_typeof :: proc(e: ^Expression) -> bool {
	if e == nil { return false }
	u, ok := e^.(^UnaryExpression)
	return ok && u != nil && u.operator == .Typeof
}

// lint_check_no_with (no-with, L2028): `with` is forbidden in strict mode and
// makes scope analysis impossible. Always flagged.
lint_check_no_with :: proc(l: ^Linter, v: ^WithStatement) {
	if v == nil || !lint_rule_enabled(l, .L2028_NoWith) { return }
	info := lint_rule_info(.L2028_NoWith)
	lint_report(l, u32(v.loc.start), u32(v.loc.end), .L2028_NoWith, info.default_message)
}

// lint_check_no_ex_assign (no-ex-assign, L2029): flags assignment to the catch
// parameter inside a catch block. Walks the catch body looking for assignments
// to the catch binding name.
lint_check_no_ex_assign :: proc(l: ^Linter, h: CatchClause) {
	if !lint_rule_enabled(l, .L2029_NoExAssign) { return }
	pat, has_param := h.param.(Pattern)
	if !has_param { return }
	param_id, param_ok := pat.(^Identifier)
	if !param_ok || param_id == nil { return }
	name := param_id.name
	for s in h.body.body {
		lint_scan_ex_assign(l, s, name)
	}
}

lint_scan_ex_assign :: proc(l: ^Linter, stmt: ^Statement, name: string) {
	if stmt == nil { return }
	#partial switch v in stmt^ {
	case ^ExpressionStatement:
		if v != nil { lint_scan_ex_assign_expr(l, v.expression, name) }
	case ^BlockStatement:
		if v != nil { for s in v.body { lint_scan_ex_assign(l, s, name) } }
	case ^IfStatement:
		if v != nil {
			lint_scan_ex_assign(l, v.consequent, name)
			if alt, ok := v.alternate.(^Statement); ok { lint_scan_ex_assign(l, alt, name) }
		}
	}
}

lint_scan_ex_assign_expr :: proc(l: ^Linter, expr: ^Expression, name: string) {
	if expr == nil { return }
	#partial switch e in expr^ {
	case ^AssignmentExpression:
		if e != nil {
			if lhs, ok := e.left.(^Identifier); ok && lhs != nil && lhs.name == name {
				info := lint_rule_info(.L2029_NoExAssign)
				lint_report(l, u32(e.loc.start), u32(e.loc.end), .L2029_NoExAssign, info.default_message)
			}
		}
	}
}

// lint_check_no_setter_return (no-setter-return, L2030): a setter should not
// return a value. Scans the body of setter methods for ReturnStatements with
// an argument. Only checks direct body statements (not nested functions).
lint_check_no_setter_return :: proc(l: ^Linter, elem: ClassElement) {
	if !lint_rule_enabled(l, .L2030_NoSetterReturn) { return }
	if elem.kind != .Set { return }
	val, vok := elem.value.(^Expression)
	if !vok || val == nil { return }
	fn, fok := val^.(^FunctionExpression)
	if !fok || fn == nil || fn.no_body { return }
	for s in fn.body.body {
		lint_scan_setter_return(l, s)
	}
}

lint_scan_setter_return :: proc(l: ^Linter, stmt: ^Statement) {
	if stmt == nil { return }
	#partial switch v in stmt^ {
	case ^ReturnStatement:
		if v != nil {
			if _, has := v.argument.(^Expression); has {
				info := lint_rule_info(.L2030_NoSetterReturn)
				lint_report(l, u32(v.loc.start), u32(v.loc.end), .L2030_NoSetterReturn, info.default_message)
			}
		}
	case ^BlockStatement:
		if v != nil { for s in v.body { lint_scan_setter_return(l, s) } }
	case ^IfStatement:
		if v != nil {
			lint_scan_setter_return(l, v.consequent)
			if alt, ok := v.alternate.(^Statement); ok { lint_scan_setter_return(l, alt) }
		}
	}
}

// lint_check_no_unused_labels (no-unused-labels, L2032): a label that is never
// referenced by break/continue is dead code. We scan the labeled statement's
// body for break/continue targeting this label.
lint_check_no_unused_labels :: proc(l: ^Linter, v: ^LabeledStatement) {
	if v == nil || !lint_rule_enabled(l, .L2032_NoUnusedLabels) { return }
	name := v.label.name
	if lint_label_used(v.body, name) { return }
	info := lint_rule_info(.L2032_NoUnusedLabels)
	lint_report(l, u32(v.loc.start), u32(v.loc.end), .L2032_NoUnusedLabels, info.default_message)
}

lint_label_used :: proc(stmt: ^Statement, name: string) -> bool {
	if stmt == nil { return false }
	#partial switch v in stmt^ {
	case ^BreakStatement:
		if v != nil { if lbl, ok := v.label.(LabelIdentifier); ok && lbl.name == name { return true } }
	case ^ContinueStatement:
		if v != nil { if lbl, ok := v.label.(LabelIdentifier); ok && lbl.name == name { return true } }
	case ^BlockStatement:
		if v != nil { for s in v.body { if lint_label_used(s, name) { return true } } }
	case ^IfStatement:
		if v != nil {
			if lint_label_used(v.consequent, name) { return true }
			if alt, ok := v.alternate.(^Statement); ok { if lint_label_used(alt, name) { return true } }
		}
	case ^WhileStatement:     if v != nil { return lint_label_used(v.body, name) }
	case ^DoWhileStatement:   if v != nil { return lint_label_used(v.body, name) }
	case ^ForStatement:       if v != nil { return lint_label_used(v.body, name) }
	case ^ForInStatement:     if v != nil { return lint_label_used(v.body, name) }
	case ^ForOfStatement:     if v != nil { return lint_label_used(v.body, name) }
	case ^SwitchStatement:
		if v != nil { for sc in v.cases { for s in sc.consequent { if lint_label_used(s, name) { return true } } } }
	case ^LabeledStatement:   if v != nil { return lint_label_used(v.body, name) }
	case ^TryStatement:
		if v != nil {
			for s in v.block.body { if lint_label_used(s, name) { return true } }
			if h, ok := v.handler.(CatchClause); ok { for s in h.body.body { if lint_label_used(s, name) { return true } } }
			if f, ok := v.finalizer.(BlockStatement); ok { for s in f.body { if lint_label_used(s, name) { return true } } }
		}
	}
	return false
}

// lint_check_require_yield (require-yield, L2033): a generator function
// (function*) that contains no `yield` expression is likely a mistake.
lint_check_require_yield :: proc(l: ^Linter, fn: ^FunctionExpression) {
	if fn == nil || !fn.generator || fn.no_body { return }
	if !lint_rule_enabled(l, .L2033_RequireYield) { return }
	if lint_body_has_yield(fn.body.body[:]) { return }
	info := lint_rule_info(.L2033_RequireYield)
	lint_report(l, u32(fn.loc.start), u32(fn.loc.end), .L2033_RequireYield, info.default_message)
}

lint_body_has_yield :: proc(body: []^Statement) -> bool {
	for s in body {
		if s == nil { continue }
		if lint_stmt_has_yield(s) { return true }
	}
	return false
}

lint_stmt_has_yield :: proc(stmt: ^Statement) -> bool {
	if stmt == nil { return false }
	#partial switch v in stmt^ {
	case ^ExpressionStatement: return v != nil && lint_expr_has_yield(v.expression)
	case ^ReturnStatement:
		if v != nil { if e, ok := v.argument.(^Expression); ok { return lint_expr_has_yield(e) } }
	case ^VariableDeclaration:
		if v != nil { for d in v.declarations { if i, ok := d.init.(^Expression); ok { if lint_expr_has_yield(i) { return true } } } }
	case ^BlockStatement:  if v != nil { return lint_body_has_yield(v.body[:]) }
	case ^IfStatement:
		if v != nil {
			if lint_stmt_has_yield(v.consequent) { return true }
			if alt, ok := v.alternate.(^Statement); ok { return lint_stmt_has_yield(alt) }
		}
	case ^WhileStatement:   if v != nil { return lint_stmt_has_yield(v.body) }
	case ^DoWhileStatement: if v != nil { return lint_stmt_has_yield(v.body) }
	case ^ForStatement:     if v != nil { return lint_stmt_has_yield(v.body) }
	case ^ForInStatement:   if v != nil { return lint_stmt_has_yield(v.body) }
	case ^ForOfStatement:   if v != nil { return lint_stmt_has_yield(v.body) }
	case ^TryStatement:
		if v != nil {
			if lint_body_has_yield(v.block.body[:]) { return true }
			if h, ok := v.handler.(CatchClause); ok { if lint_body_has_yield(h.body.body[:]) { return true } }
		}
	case ^LabeledStatement: if v != nil { return lint_stmt_has_yield(v.body) }
	case ^SwitchStatement:
		if v != nil { for sc in v.cases { if lint_body_has_yield(sc.consequent[:]) { return true } } }
	}
	return false
}

lint_expr_has_yield :: proc(expr: ^Expression) -> bool {
	if expr == nil { return false }
	#partial switch e in expr^ {
	case ^YieldExpression: return true
	case ^SequenceExpression: if e != nil { for s in e.expressions { if lint_expr_has_yield(s) { return true } } }
	case ^AssignmentExpression: if e != nil { return lint_expr_has_yield(e.right) }
	case ^ConditionalExpression: if e != nil { return lint_expr_has_yield(e.consequent) || lint_expr_has_yield(e.alternate) }
	case ^AwaitExpression: if e != nil { return lint_expr_has_yield(e.argument) }
	}
	return false
}

// lint_check_constructor_super (constructor-super, L2034): a derived class
// (with `extends`) must call `super()` in its constructor. A non-derived class
// must NOT call super(). Basic check: scan the constructor body for `super()`.
lint_check_constructor_super :: proc(l: ^Linter, cls: ^ClassExpression) {
	if cls == nil || !lint_rule_enabled(l, .L2034_ConstructorSuper) { return }
	has_extends := false
	if _, ok := cls.super_class.(^Expression); ok { has_extends = true }
	for elem in cls.body.body {
		if elem.kind != .Constructor { continue }
		val, vok := elem.value.(^Expression)
		if !vok || val == nil { continue }
		fn, fok := val^.(^FunctionExpression)
		if !fok || fn == nil || fn.no_body { continue }
		has_super := lint_body_has_super_call(fn.body.body[:])
		if has_extends && !has_super {
			info := lint_rule_info(.L2034_ConstructorSuper)
			lint_report(l, u32(elem.loc.start), u32(elem.loc.end), .L2034_ConstructorSuper, info.default_message)
		}
	}
}

lint_body_has_super_call :: proc(body: []^Statement) -> bool {
	for s in body {
		if s == nil { continue }
		#partial switch v in s^ {
		case ^ExpressionStatement:
			if v != nil && lint_expr_has_super_call(v.expression) { return true }
		case ^BlockStatement:
			if v != nil && lint_body_has_super_call(v.body[:]) { return true }
		case ^IfStatement:
			if v != nil {
				if lint_body_has_super_call({v.consequent}) { return true }
				if alt, ok := v.alternate.(^Statement); ok { if lint_body_has_super_call({alt}) { return true } }
			}
		}
	}
	return false
}

lint_expr_has_super_call :: proc(expr: ^Expression) -> bool {
	if expr == nil { return false }
	#partial switch e in expr^ {
	case ^CallExpression:
		if e != nil {
			if _, ok := e.callee^.(^Super); ok { return true }
		}
	}
	return false
}

// lint_check_no_extra_boolean_cast (no-extra-boolean-cast, L2042): flags
// `!!x` in boolean context (if/while/do-while/for test, ternary test) and
// `Boolean(x)` in the same positions. Only the double-negation form in
// boolean context is checked for simplicity.
// lint_check_no_inner_declarations (no-inner-declarations, L2031): function
// declarations inside blocks (if/for/while bodies) are only legal in ES2015+
// strict mode and confuse readers. Only FunctionDeclaration is checked (not
// VariableDeclaration, matching ESLint's default "functions" option).
// The check fires on FunctionDeclaration nodes found inside block statements
// that are NOT the direct body of a function or program.
lint_check_no_inner_declarations :: proc(l: ^Linter, ctx: ^LintContext, body: []^Statement, is_root: bool) {
	if is_root || !lint_rule_enabled(l, .L2031_NoInnerDeclarations) { return }
	for s in body {
		if s == nil { continue }
		if fd, ok := s^.(^FunctionDeclaration); ok && fd != nil {
			info := lint_rule_info(.L2031_NoInnerDeclarations)
			lint_report(l, u32(fd.loc.start), u32(fd.loc.end), .L2031_NoInnerDeclarations, info.default_message)
		}
	}
}

// lint_check_no_unsafe_optional_chaining (no-unsafe-optional-chaining, L2035):
// flags `(obj?.foo)()` or `new (obj?.bar)()` or `[...(obj?.arr)]` — optional
// chaining in a position where undefined would throw at runtime.
lint_check_no_unsafe_optional_chaining_call :: proc(l: ^Linter, callee: ^Expression) {
	if callee == nil || !lint_rule_enabled(l, .L2035_NoUnsafeOptionalChaining) { return }
	if lint_expr_is_optional_chain(callee) {
		info := lint_rule_info(.L2035_NoUnsafeOptionalChaining)
		lint_report(l, u32(get_expression_loc(callee).start), u32(get_expression_loc(callee).end), .L2035_NoUnsafeOptionalChaining, info.default_message)
	}
}

lint_expr_is_optional_chain :: proc(e: ^Expression) -> bool {
	if e == nil { return false }
	#partial switch v in e^ {
	case ^ChainExpression: return true
	case ^ParenthesizedExpression: if v != nil { return lint_expr_is_optional_chain(v.expression) }
	}
	return false
}

// lint_check_no_loss_of_precision (no-loss-of-precision, L2036): flags numeric
// literals that lose precision when parsed as IEEE 754 double. Checks by
// round-tripping: format the parsed f64 back to a string and compare to the
// source text (stripping underscores). Integers > 2^53 also lose precision.
lint_check_no_loss_of_precision :: proc(l: ^Linter, e: ^NumericLiteral) {
	if e == nil || !lint_rule_enabled(l, .L2036_NoLossOfPrecision) { return }
	// Check if a decimal integer literal exceeds Number.MAX_SAFE_INTEGER
	// by examining the source text length. Any decimal integer > 16 digits
	// risks precision loss. We also catch exactly-16-digit numbers > 2^53-1
	// by checking the parsed value differs from its i64 round-trip.
	if e.value == f64(i64(e.value)) && e.value >= 0 {
		ival := i64(e.value)
		// Re-convert and check if it matches. For values > 2^53, the f64
		// representation rounds, so f64(ival) == e.value but ival may not
		// be the original source integer. We detect this by checking if the
		// magnitude exceeds MAX_SAFE_INTEGER.
		if ival > 9007199254740991 || ival < -9007199254740991 {
			info := lint_rule_info(.L2036_NoLossOfPrecision)
			lint_report(l, u32(e.loc.start), u32(e.loc.end), .L2036_NoLossOfPrecision, info.default_message)
		}
	}
}

// lint_check_no_control_regex (no-control-regex, L2039): flags regex patterns
// containing ASCII control characters (0x01-0x1f) via \x00-\x1f hex escapes.
// Scans the pattern string for raw control chars.
lint_check_no_control_regex :: proc(l: ^Linter, e: ^RegExpLiteral) {
	if e == nil || !lint_rule_enabled(l, .L2039_NoControlRegex) { return }
	for ch in e.pattern {
		if ch >= 0x01 && ch <= 0x1f {
			info := lint_rule_info(.L2039_NoControlRegex)
			lint_report(l, u32(e.loc.start), u32(e.loc.end), .L2039_NoControlRegex, info.default_message)
			return
		}
	}
}

// lint_check_no_empty_character_class (no-empty-character-class, L2040): flags
// regex patterns containing `[]` — an empty character class that matches
// nothing, making the regex always fail.
lint_check_no_empty_character_class :: proc(l: ^Linter, e: ^RegExpLiteral) {
	if e == nil || !lint_rule_enabled(l, .L2040_NoEmptyCharacterClass) { return }
	in_class := false
	prev_backslash := false
	for ch in e.pattern {
		if prev_backslash { prev_backslash = false; continue }
		if ch == '\\' { prev_backslash = true; continue }
		if ch == '[' { in_class = true; continue }
		if ch == ']' && in_class {
			info := lint_rule_info(.L2040_NoEmptyCharacterClass)
			lint_report(l, u32(e.loc.start), u32(e.loc.end), .L2040_NoEmptyCharacterClass, info.default_message)
			return
		}
		in_class = false
	}
}

// lint_check_no_regex_spaces (no-regex-spaces, L2041): flags regex patterns
// containing two or more consecutive spaces. Use a quantifier `{2}` instead.
lint_check_no_regex_spaces :: proc(l: ^Linter, e: ^RegExpLiteral) {
	if e == nil || !lint_rule_enabled(l, .L2041_NoRegexSpaces) { return }
	in_class := false
	prev_backslash := false
	consecutive_spaces := 0
	for ch in e.pattern {
		if prev_backslash { prev_backslash = false; consecutive_spaces = 0; continue }
		if ch == '\\' { prev_backslash = true; consecutive_spaces = 0; continue }
		if ch == '[' { in_class = true; consecutive_spaces = 0; continue }
		if ch == ']' { in_class = false; consecutive_spaces = 0; continue }
		if !in_class && ch == ' ' {
			consecutive_spaces += 1
			if consecutive_spaces >= 2 {
				info := lint_rule_info(.L2041_NoRegexSpaces)
				lint_report(l, u32(e.loc.start), u32(e.loc.end), .L2041_NoRegexSpaces, info.default_message)
				return
			}
		} else {
			consecutive_spaces = 0
		}
	}
}

// lint_check_no_unreachable (no-unreachable, L2044): basic version without
// CFG. Flags statements that follow a return, throw, break, or continue in
// the same block — those statements can never execute.
lint_check_no_unreachable :: proc(l: ^Linter, body: []^Statement) {
	if !lint_rule_enabled(l, .L2044_NoUnreachable) { return }
	hit_terminator := false
	for s in body {
		if s == nil { continue }
		if hit_terminator {
			// Skip function/class declarations — they're hoisted.
			#partial switch _ in s^ {
			case ^FunctionDeclaration, ^ClassDeclaration: continue
			}
			loc := lint_stmt_loc(s)
			info := lint_rule_info(.L2044_NoUnreachable)
			lint_report(l, u32(loc.start), u32(loc.end), .L2044_NoUnreachable, info.default_message)
			return // one report per block
		}
		if lint_stmt_is_terminator(s) { hit_terminator = true }
	}
}

lint_stmt_is_terminator :: proc(s: ^Statement) -> bool {
	if s == nil { return false }
	#partial switch _ in s^ {
	case ^ReturnStatement, ^ThrowStatement, ^BreakStatement, ^ContinueStatement:
		return true
	}
	return false
}

lint_stmt_loc :: proc(s: ^Statement) -> Loc {
	if s == nil { return {} }
	#partial switch v in s^ {
	case ^ExpressionStatement:  if v != nil { return v.loc }
	case ^VariableDeclaration:  if v != nil { return v.loc }
	case ^ReturnStatement:      if v != nil { return v.loc }
	case ^ThrowStatement:       if v != nil { return v.loc }
	case ^IfStatement:          if v != nil { return v.loc }
	case ^BlockStatement:       if v != nil { return v.loc }
	case ^ForStatement:         if v != nil { return v.loc }
	case ^WhileStatement:       if v != nil { return v.loc }
	case ^FunctionDeclaration:  if v != nil { return v.loc }
	case ^ClassDeclaration:     if v != nil { return v.loc }
	case ^BreakStatement:       if v != nil { return v.loc }
	case ^ContinueStatement:    if v != nil { return v.loc }
	case ^EmptyStatement:       if v != nil { return v.loc }
	case ^DebuggerStatement:    if v != nil { return v.loc }
	case ^LabeledStatement:     if v != nil { return v.loc }
	case ^SwitchStatement:      if v != nil { return v.loc }
	case ^TryStatement:         if v != nil { return v.loc }
	case ^DoWhileStatement:     if v != nil { return v.loc }
	}
	return {}
}

// lint_check_no_fallthrough (no-fallthrough, L2045): basic version. Flags a
// case clause that has statements but does not end with break, return, throw,
// or continue — it falls through to the next case.
lint_check_no_fallthrough :: proc(l: ^Linter, v: ^SwitchStatement) {
	if v == nil || !lint_rule_enabled(l, .L2045_NoFallthrough) { return }
	for idx in 0..<len(v.cases) - 1 {
		sc := v.cases[idx]
		if len(sc.consequent) == 0 { continue } // empty case = intentional group
		last := sc.consequent[len(sc.consequent) - 1]
		if last == nil { continue }
		if lint_stmt_is_terminator(last) { continue }
		// Check if last is a block ending with a terminator.
		if blk, ok := last^.(^BlockStatement); ok && blk != nil && len(blk.body) > 0 {
			if lint_stmt_is_terminator(blk.body[len(blk.body) - 1]) { continue }
		}
		next_sc := v.cases[idx + 1]
		info := lint_rule_info(.L2045_NoFallthrough)
		lint_report(l, u32(next_sc.loc.start), u32(next_sc.loc.end), .L2045_NoFallthrough, info.default_message)
	}
}

// lint_check_getter_return (getter-return, L2046): every getter property or
// method must contain at least one return statement (basic scan, not CFG).
lint_check_getter_return :: proc(l: ^Linter, elem: ClassElement) {
	if !lint_rule_enabled(l, .L2046_GetterReturn) { return }
	if elem.kind != .Get { return }
	val, has_val := elem.value.(^Expression)
	if !has_val || val == nil { return }
	fn, is_fn := val^.(^FunctionExpression)
	if !is_fn || fn == nil || fn.no_body { return }
	if lint_body_has_return(fn.body.body[:]) { return }
	info := lint_rule_info(.L2046_GetterReturn)
	lint_report(l, u32(elem.loc.start), u32(elem.loc.end), .L2046_GetterReturn, info.default_message)
}

// lint_body_has_return scans a statement list for any return statement
// (shallow — does not descend into nested functions).
lint_body_has_return :: proc(body: []^Statement) -> bool {
	for s in body {
		if s == nil { continue }
		#partial switch v in s^ {
		case ^ReturnStatement:  return true
		case ^IfStatement:
			if v != nil {
				if lint_stmt_has_return(v.consequent) { return true }
				if alt, aok := v.alternate.(^Statement); aok {
					if lint_stmt_has_return(alt) { return true }
				}
			}
		case ^BlockStatement:
			if v != nil && lint_body_has_return(v.body[:]) { return true }
		case ^SwitchStatement:
			if v != nil {
				for sc in v.cases {
					if lint_body_has_return(sc.consequent[:]) { return true }
				}
			}
		case ^TryStatement:
			if v != nil {
				if lint_body_has_return(v.block.body[:]) { return true }
			}
		}
	}
	return false
}

lint_stmt_has_return :: proc(s: ^Statement) -> bool {
	if s == nil { return false }
	#partial switch v in s^ {
	case ^ReturnStatement: return true
	case ^BlockStatement:  if v != nil { return lint_body_has_return(v.body[:]) }
	}
	return false
}

// lint_check_getter_return_obj is the object-literal variant.
lint_check_getter_return_obj :: proc(l: ^Linter, prop: Property) {
	if !lint_rule_enabled(l, .L2046_GetterReturn) { return }
	if prop.kind != .Get { return }
	if prop.value == nil { return }
	fn, is_fn := prop.value^.(^FunctionExpression)
	if !is_fn || fn == nil || fn.no_body { return }
	if lint_body_has_return(fn.body.body[:]) { return }
	info := lint_rule_info(.L2046_GetterReturn)
	lint_report(l, u32(prop.loc.start), u32(prop.loc.end), .L2046_GetterReturn, info.default_message)
}

// lint_check_no_global_assign (no-global-assign, L2047): forbids assignment to
// well-known read-only globals (undefined, NaN, Infinity, eval, arguments, etc.).
lint_check_no_global_assign :: proc(l: ^Linter, e: ^AssignmentExpression) {
	if e == nil || !lint_rule_enabled(l, .L2047_NoGlobalAssign) { return }
	id, ok := e.left.(^Identifier)
	if !ok || id == nil { return }
	if lint_is_readonly_global(id.name) {
		info := lint_rule_info(.L2047_NoGlobalAssign)
		lint_report(l, u32(id.loc.start), u32(id.loc.end), .L2047_NoGlobalAssign, info.default_message)
	}
}

lint_is_readonly_global :: proc(name: string) -> bool {
	switch name {
	case "undefined", "NaN", "Infinity", "eval", "arguments",
	     "Object", "Array", "Function", "Number", "String",
	     "Boolean", "Symbol", "BigInt", "Math", "JSON",
	     "Reflect", "Proxy", "Promise", "Map", "Set",
	     "WeakMap", "WeakSet", "WeakRef", "Error", "TypeError",
	     "RangeError", "ReferenceError", "SyntaxError", "URIError",
	     "EvalError", "AggregateError", "parseInt", "parseFloat",
	     "isNaN", "isFinite", "decodeURI", "decodeURIComponent",
	     "encodeURI", "encodeURIComponent", "globalThis",
	     "ArrayBuffer", "SharedArrayBuffer", "DataView",
	     "Float32Array", "Float64Array", "Int8Array",
	     "Int16Array", "Int32Array", "Uint8Array",
	     "Uint16Array", "Uint32Array", "Uint8ClampedArray",
	     "Atomics", "Intl", "RegExp", "Date", "console":
		return true
	}
	return false
}

// lint_check_no_import_assign (no-import-assign, L2048): uses the semantic
// model to check whether any assignment target resolves to an import binding.
lint_check_no_import_assign :: proc(l: ^Linter, e: ^AssignmentExpression) {
	if e == nil || !lint_rule_enabled(l, .L2048_NoImportAssign) { return }
	if l.semantic == nil { return }
	id, ok := e.left.(^Identifier)
	if !ok || id == nil { return }
	// Search the semantic model for an import symbol with this name.
	for i in 1..<len(l.semantic.symbols) {
		sym := &l.semantic.symbols[i]
		if sym.name == id.name && sym.kind == .Import {
			info := lint_rule_info(.L2048_NoImportAssign)
			lint_report(l, u32(id.loc.start), u32(id.loc.end), .L2048_NoImportAssign, info.default_message)
			return
		}
	}
}

// lint_check_no_class_assign (no-class-assign, L2049): flags assignment to a
// name that was declared as a class in the same file.
lint_check_no_class_assign :: proc(l: ^Linter, e: ^AssignmentExpression) {
	if e == nil || !lint_rule_enabled(l, .L2049_NoClassAssign) { return }
	if l.semantic == nil { return }
	id, ok := e.left.(^Identifier)
	if !ok || id == nil { return }
	for i in 1..<len(l.semantic.symbols) {
		sym := &l.semantic.symbols[i]
		if sym.name == id.name && sym.kind == .Class {
			info := lint_rule_info(.L2049_NoClassAssign)
			lint_report(l, u32(id.loc.start), u32(id.loc.end), .L2049_NoClassAssign, info.default_message)
			return
		}
	}
}

// lint_check_no_func_assign (no-func-assign, L2050): flags assignment to a
// name that was declared as a function declaration in the same file.
lint_check_no_func_assign :: proc(l: ^Linter, e: ^AssignmentExpression) {
	if e == nil || !lint_rule_enabled(l, .L2050_NoFuncAssign) { return }
	if l.semantic == nil { return }
	id, ok := e.left.(^Identifier)
	if !ok || id == nil { return }
	for i in 1..<len(l.semantic.symbols) {
		sym := &l.semantic.symbols[i]
		if sym.name == id.name && sym.kind == .Function {
			info := lint_rule_info(.L2050_NoFuncAssign)
			lint_report(l, u32(id.loc.start), u32(id.loc.end), .L2050_NoFuncAssign, info.default_message)
			return
		}
	}
}

// lint_check_no_promise_exec_return (no-promise-executor-return, L2051):
// flags `return <value>` inside a `new Promise((resolve, reject) => { ... })`
// executor. The return value is ignored by the Promise constructor.
lint_check_no_promise_exec_return :: proc(l: ^Linter, e: ^NewExpression) {
	if e == nil || !lint_rule_enabled(l, .L2051_NoPromiseExecReturn) { return }
	// Callee must be `Promise`.
	id, ok := e.callee^.(^Identifier)
	if !ok || id == nil || id.name != "Promise" { return }
	if len(e.arguments) < 1 { return }
	arg := e.arguments[0]
	if arg == nil { return }
	// The executor can be a function expression or arrow.
	#partial switch fn in arg^ {
	case ^FunctionExpression:
		if fn != nil && !fn.no_body {
			lint_check_exec_body_return(l, fn.body.body[:])
		}
	case ^ArrowFunctionExpression:
		if fn != nil {
			if blk, bok := fn.body.(^BlockStatement); bok && blk != nil {
				lint_check_exec_body_return(l, blk.body[:])
			}
		}
	}
}

lint_check_exec_body_return :: proc(l: ^Linter, body: []^Statement) {
	for s in body {
		if s == nil { continue }
		ret, is_ret := s^.(^ReturnStatement)
		if !is_ret || ret == nil { continue }
		// `return;` (no argument) is fine — only `return <expr>` is flagged.
		if _, has_arg := ret.argument.(^Expression); has_arg {
			info := lint_rule_info(.L2051_NoPromiseExecReturn)
			lint_report(l, u32(ret.loc.start), u32(ret.loc.end), .L2051_NoPromiseExecReturn, info.default_message)
		}
	}
}

// lint_check_template_curly_in_string (no-template-curly-in-string, L4039):
// flags regular string literals that contain `${...}` — likely a mistaken
// use of quotes instead of backticks.
lint_check_template_curly_in_string :: proc(l: ^Linter, e: ^StringLiteral) {
	if e == nil || !lint_rule_enabled(l, .L4039_NoTemplateCurlyInString) { return }
	s := e.value
	for i in 0..<len(s) {
		if s[i] == '$' && i + 1 < len(s) && s[i+1] == '{' {
			info := lint_rule_info(.L4039_NoTemplateCurlyInString)
			lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4039_NoTemplateCurlyInString, info.default_message)
			return // one report per string
		}
	}
}

// lint_check_no_nested_ternary (no-nested-ternary, L4040): flags ternary
// expressions whose consequent or alternate is itself a ternary.
lint_check_no_nested_ternary :: proc(l: ^Linter, e: ^ConditionalExpression) {
	if e == nil || !lint_rule_enabled(l, .L4040_NoNestedTernary) { return }
	if e.consequent != nil {
		if _, ok := e.consequent^.(^ConditionalExpression); ok {
			info := lint_rule_info(.L4040_NoNestedTernary)
			lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4040_NoNestedTernary, info.default_message)
			return
		}
	}
	if e.alternate != nil {
		if _, ok := e.alternate^.(^ConditionalExpression); ok {
			info := lint_rule_info(.L4040_NoNestedTernary)
			lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4040_NoNestedTernary, info.default_message)
		}
	}
}

// lint_check_no_unneeded_ternary (no-unneeded-ternary, L4041): flags
// `x ? true : false` or `x ? false : true` — use the condition directly.
lint_check_no_unneeded_ternary :: proc(l: ^Linter, e: ^ConditionalExpression) {
	if e == nil || !lint_rule_enabled(l, .L4041_NoUnneededTernary) { return }
	if e.consequent == nil || e.alternate == nil { return }
	c_bool, c_ok := e.consequent^.(^BooleanLiteral)
	a_bool, a_ok := e.alternate^.(^BooleanLiteral)
	if !c_ok || !a_ok || c_bool == nil || a_bool == nil { return }
	if (c_bool.value && !a_bool.value) || (!c_bool.value && a_bool.value) {
		info := lint_rule_info(.L4041_NoUnneededTernary)
		lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4041_NoUnneededTernary, info.default_message)
	}
}

// lint_check_no_negated_condition (no-negated-condition, L4098): flags an
// `if` with an `else` whose test is negated (`!x`, `a != b`, `a !== b`).
// Inverting the test and swapping the branches reads more clearly. Only fires
// when an else branch exists (a bare negated `if` is fine).
lint_check_no_negated_condition :: proc(l: ^Linter, v: ^IfStatement) {
	if v == nil || !lint_rule_enabled(l, .L4098_NoNegatedCondition) { return }
	if _, ok := v.alternate.(^Statement); !ok { return }
	negated := false
	#partial switch t in v.test^ {
	case ^UnaryExpression:
		if t != nil && t.operator == .LogicalNot { negated = true }
	case ^BinaryExpression:
		if t != nil && (t.operator == .NotEq || t.operator == .StrictNotEq) { negated = true }
	}
	if !negated { return }
	info := lint_rule_info(.L4098_NoNegatedCondition)
	lint_report(l, u32(v.loc.start), u32(v.loc.end), .L4098_NoNegatedCondition, info.default_message)
}

// lint_check_operator_assignment (operator-assignment, L4099): flags a plain
// assignment `x = x <op> y` that could use a compound operator (`x += y`).
// Requires the assignment target and the binary expression's left operand to be
// the same identifier, and the binary operator to have a compound form.
lint_check_operator_assignment :: proc(l: ^Linter, e: ^AssignmentExpression) {
	if e == nil || !lint_rule_enabled(l, .L4099_OperatorAssignment) { return }
	if e.operator != .Assign { return }
	bin, ok := e.right^.(^BinaryExpression)
	if !ok || bin == nil { return }
	if !lint_binary_op_has_compound(bin.operator) { return }
	lhs, ok2 := e.left^.(^Identifier)
	if !ok2 || lhs == nil { return }
	blhs, ok3 := bin.left^.(^Identifier)
	if !ok3 || blhs == nil { return }
	if lhs.name != blhs.name { return }
	info := lint_rule_info(.L4099_OperatorAssignment)
	lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4099_OperatorAssignment, info.default_message)
}

// lint_binary_op_has_compound reports whether a binary operator has a compound
// assignment form (`+` → `+=`, etc.). Relational/equality operators do not.
lint_binary_op_has_compound :: proc(op: BinaryOperator) -> bool {
	#partial switch op {
	case .Add, .Sub, .Mul, .Div, .Mod, .Pow,
	     .BitOr, .BitXor, .BitAnd,
	     .ShiftLeft, .ShiftRight, .ShiftRightUnsigned:
		return true
	}
	return false
}

// lint_check_no_lonely_if (no-lonely-if, L4042): flags an `else` block whose
// only statement is an `if` — should be `else if` instead.
lint_check_no_lonely_if :: proc(l: ^Linter, v: ^IfStatement) {
	if v == nil || !lint_rule_enabled(l, .L4042_NoLonelyIf) { return }
	alt, has_alt := v.alternate.(^Statement)
	if !has_alt || alt == nil { return }
	blk, is_blk := alt^.(^BlockStatement)
	if !is_blk || blk == nil || len(blk.body) != 1 { return }
	only := blk.body[0]
	if only == nil { return }
	if _, is_if := only^.(^IfStatement); is_if {
		info := lint_rule_info(.L4042_NoLonelyIf)
		lint_report(l, u32(blk.loc.start), u32(blk.loc.end), .L4042_NoLonelyIf, info.default_message)
	}
}

// lint_check_prefer_numeric_literals (prefer-numeric-literals, L4043): flags
// parseInt("0xFF", 16) / parseInt("0b11", 2) / parseInt("0o77", 8) — use
// the literal directly.
lint_check_prefer_numeric_literals :: proc(l: ^Linter, e: ^CallExpression) {
	if e == nil || !lint_rule_enabled(l, .L4043_PreferNumericLiterals) { return }
	if len(e.arguments) != 2 { return }
	id, ok := e.callee^.(^Identifier)
	if !ok || id == nil || id.name != "parseInt" { return }
	str_arg := e.arguments[0]
	if str_arg == nil { return }
	sl, sl_ok := str_arg^.(^StringLiteral)
	if !sl_ok || sl == nil { return }
	val := sl.value
	if len(val) < 2 { return }
	// Check for 0x, 0b, 0o prefixes.
	if val[0] == '0' && (val[1] == 'x' || val[1] == 'X' || val[1] == 'b' || val[1] == 'B' || val[1] == 'o' || val[1] == 'O') {
		info := lint_rule_info(.L4043_PreferNumericLiterals)
		lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4043_PreferNumericLiterals, info.default_message)
	}
}

// lint_check_no_useless_call (no-useless-call, L4044): flags `foo.call(this)`
// and `foo.apply(this, args)` where the thisArg is the literal `this`.
lint_check_no_useless_call :: proc(l: ^Linter, e: ^CallExpression) {
	if e == nil || !lint_rule_enabled(l, .L4044_NoUselessCall) { return }
	if len(e.arguments) < 1 { return }
	mem, is_mem := e.callee^.(^MemberExpression)
	if !is_mem || mem == nil || mem.computed { return }
	prop_id, p_ok := mem.property^.(^Identifier)
	if !p_ok || prop_id == nil { return }
	if prop_id.name != "call" && prop_id.name != "apply" { return }
	// First argument must be literal `this`.
	first := e.arguments[0]
	if first == nil { return }
	if _, is_this := first^.(^ThisExpression); is_this {
		info := lint_rule_info(.L4044_NoUselessCall)
		lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4044_NoUselessCall, info.default_message)
	}
}

// lint_check_no_void (no-void, L4045): flags `void expr`.
lint_check_no_void :: proc(l: ^Linter, e: ^UnaryExpression) {
	if e == nil || !lint_rule_enabled(l, .L4045_NoVoid) { return }
	if e.operator != .Void { return }
	info := lint_rule_info(.L4045_NoVoid)
	lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4045_NoVoid, info.default_message)
}

// lint_check_no_bitwise (no-bitwise, L4046): flags bitwise operators.
lint_check_no_bitwise :: proc(l: ^Linter, e: ^BinaryExpression) {
	if e == nil || !lint_rule_enabled(l, .L4046_NoBitwise) { return }
	#partial switch e.operator {
	case .BitAnd, .BitOr, .BitXor, .ShiftLeft, .ShiftRight, .ShiftRightUnsigned:
		info := lint_rule_info(.L4046_NoBitwise)
		lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4046_NoBitwise, info.default_message)
	}
}

// lint_check_no_continue (no-continue, L4047): flags `continue` statements.
lint_check_no_continue :: proc(l: ^Linter, v: ^ContinueStatement) {
	if v == nil || !lint_rule_enabled(l, .L4047_NoContinue) { return }
	info := lint_rule_info(.L4047_NoContinue)
	lint_report(l, u32(v.loc.start), u32(v.loc.end), .L4047_NoContinue, info.default_message)
}

// lint_check_no_plusplus (no-plusplus, L4048): flags `++` and `--`.
lint_check_no_plusplus :: proc(l: ^Linter, e: ^UpdateExpression) {
	if e == nil || !lint_rule_enabled(l, .L4048_NoPlusplus) { return }
	info := lint_rule_info(.L4048_NoPlusplus)
	lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4048_NoPlusplus, info.default_message)
}

// lint_check_yoda (yoda, L4049): flags `"red" === color` style comparisons
// where the literal is on the left.
lint_check_yoda :: proc(l: ^Linter, e: ^BinaryExpression) {
	if e == nil || !lint_rule_enabled(l, .L4049_Yoda) { return }
	#partial switch e.operator {
	case .Eq, .NotEq, .StrictEq, .StrictNotEq:
		if e.left != nil && lint_is_literal(e.left) && e.right != nil && !lint_is_literal(e.right) {
			info := lint_rule_info(.L4049_Yoda)
			lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4049_Yoda, info.default_message)
		}
	}
}

lint_is_literal :: proc(expr: ^Expression) -> bool {
	if expr == nil { return false }
	#partial switch _ in expr^ {
	case ^StringLiteral, ^NumericLiteral, ^BooleanLiteral, ^NullLiteral, ^BigIntLiteral:
		return true
	}
	return false
}

// lint_check_no_duplicate_imports (no-duplicate-imports, L2052): flags
// multiple import declarations from the same module specifier.
lint_check_no_duplicate_imports :: proc(l: ^Linter, program_body: []^Statement) {
	if !lint_rule_enabled(l, .L2052_NoDuplicateImports) { return }
	seen := make(map[string]bool, 0, context.temp_allocator)
	for s in program_body {
		if s == nil { continue }
		imp, ok := s^.(^ImportDeclaration)
		if !ok || imp == nil { continue }
		src := imp.source.value
		if seen[src] {
			info := lint_rule_info(.L2052_NoDuplicateImports)
			lint_report(l, u32(imp.loc.start), u32(imp.loc.end), .L2052_NoDuplicateImports, info.default_message)
		} else {
			seen[src] = true
		}
	}
}

// lint_check_no_useless_computed_key (no-useless-computed-key, L4050): flags
// `{["foo"]: 1}` or `{[0]: 1}` where the computed key is a static literal.
lint_check_no_useless_computed_key :: proc(l: ^Linter, prop: Property) {
	if !lint_rule_enabled(l, .L4050_NoUselessComputedKey) { return }
	if !prop.computed || prop.key == nil { return }
	#partial switch _ in prop.key^ {
	case ^StringLiteral, ^NumericLiteral:
		info := lint_rule_info(.L4050_NoUselessComputedKey)
		lint_report(l, u32(prop.loc.start), u32(prop.loc.end), .L4050_NoUselessComputedKey, info.default_message)
	}
}

// lint_check_no_useless_computed_key_class (class variant of L4050).
lint_check_no_useless_computed_key_class :: proc(l: ^Linter, elem: ClassElement) {
	if !lint_rule_enabled(l, .L4050_NoUselessComputedKey) { return }
	if !elem.computed || elem.key == nil { return }
	#partial switch _ in elem.key^ {
	case ^StringLiteral, ^NumericLiteral:
		info := lint_rule_info(.L4050_NoUselessComputedKey)
		lint_report(l, u32(elem.loc.start), u32(elem.loc.end), .L4050_NoUselessComputedKey, info.default_message)
	}
}

// lint_check_no_useless_return (no-useless-return, L4051): flags a `return;`
// (no argument) as the last statement in a function body.
lint_check_no_useless_return :: proc(l: ^Linter, fn_body: []^Statement) {
	if !lint_rule_enabled(l, .L4051_NoUselessReturn) { return }
	if len(fn_body) == 0 { return }
	last := fn_body[len(fn_body) - 1]
	if last == nil { return }
	ret, is_ret := last^.(^ReturnStatement)
	if !is_ret || ret == nil { return }
	// Only flag bare `return;` — `return expr` is meaningful.
	if _, has_arg := ret.argument.(^Expression); has_arg { return }
	info := lint_rule_info(.L4051_NoUselessReturn)
	lint_report(l, u32(ret.loc.start), u32(ret.loc.end), .L4051_NoUselessReturn, info.default_message)
}

// lint_check_prefer_arrow_callback (prefer-arrow-callback, L4052): flags
// function expressions used as callbacks (arguments to calls).
lint_check_prefer_arrow_callback :: proc(l: ^Linter, e: ^CallExpression) {
	if e == nil || !lint_rule_enabled(l, .L4052_PreferArrowCallback) { return }
	for arg in e.arguments {
		if arg == nil { continue }
		if fn, ok := arg^.(^FunctionExpression); ok && fn != nil {
			// Skip named function expressions — they may reference themselves.
			if _, has_id := fn.id.(BindingIdentifier); has_id { continue }
			info := lint_rule_info(.L4052_PreferArrowCallback)
			lint_report(l, u32(fn.loc.start), u32(fn.loc.end), .L4052_PreferArrowCallback, info.default_message)
		}
	}
}

// lint_check_no_else_return (no-else-return, L4053): flags `else` after an
// `if` block that ends with `return`.
lint_check_no_else_return :: proc(l: ^Linter, v: ^IfStatement) {
	if v == nil || !lint_rule_enabled(l, .L4053_NoElseReturn) { return }
	// Must have an else branch.
	alt, has_alt := v.alternate.(^Statement)
	if !has_alt || alt == nil { return }
	// Consequent must end with return.
	if !lint_block_ends_with_return(v.consequent) { return }
	info := lint_rule_info(.L4053_NoElseReturn)
	lint_report(l, u32(alt^.(^BlockStatement).loc.start) if alt != nil else 0,
		u32(alt^.(^BlockStatement).loc.end) if alt != nil else 0,
		.L4053_NoElseReturn, info.default_message)
}

lint_block_ends_with_return :: proc(s: ^Statement) -> bool {
	if s == nil { return false }
	blk, ok := s^.(^BlockStatement)
	if !ok || blk == nil || len(blk.body) == 0 { return false }
	last := blk.body[len(blk.body) - 1]
	if last == nil { return false }
	_, is_ret := last^.(^ReturnStatement)
	return is_ret
}

// lint_check_no_this_before_super (no-this-before-super, L2053): in a
// derived class constructor, flags `this` or `this.x` before `super()`.
lint_check_no_this_before_super :: proc(l: ^Linter, cls: ^ClassExpression) {
	if cls == nil || !lint_rule_enabled(l, .L2053_NoThisBeforeSuper) { return }
	// Only derived classes (those with super_class).
	if _, has_super := cls.super_class.(^Expression); !has_super { return }
	for elem in cls.body.body {
		if elem.kind != .Constructor { continue }
		val, has_val := elem.value.(^Expression)
		if !has_val || val == nil { continue }
		fn, is_fn := val^.(^FunctionExpression)
		if !is_fn || fn == nil || fn.no_body { continue }
		// Scan body: flag any `this` that appears before a `super()` call.
		for s in fn.body.body {
			if s == nil { continue }
			// If this stmt is a super() call, we're done — everything after is fine.
			if lint_stmt_is_super_call(s) { break }
			// Check if statement uses `this`.
			if loc, found := lint_stmt_uses_this(s); found {
				info := lint_rule_info(.L2053_NoThisBeforeSuper)
				lint_report(l, u32(loc.start), u32(loc.end), .L2053_NoThisBeforeSuper, info.default_message)
				break // one report per constructor
			}
		}
	}
}

lint_stmt_is_super_call :: proc(s: ^Statement) -> bool {
	if s == nil { return false }
	expr_stmt, ok := s^.(^ExpressionStatement)
	if !ok || expr_stmt == nil || expr_stmt.expression == nil { return false }
	call, is_call := expr_stmt.expression^.(^CallExpression)
	if !is_call || call == nil || call.callee == nil { return false }
	_, is_super := call.callee^.(^Super)
	return is_super
}

lint_stmt_uses_this :: proc(s: ^Statement) -> (loc: Loc, found: bool) {
	if s == nil { return {}, false }
	expr_stmt, ok := s^.(^ExpressionStatement)
	if !ok || expr_stmt == nil { return {}, false }
	return lint_expr_uses_this(expr_stmt.expression)
}

lint_expr_uses_this :: proc(e: ^Expression) -> (loc: Loc, found: bool) {
	if e == nil { return {}, false }
	#partial switch v in e^ {
	case ^ThisExpression:    if v != nil { return v.loc, true }
	case ^MemberExpression:  if v != nil { return lint_expr_uses_this(v.object) }
	case ^CallExpression:    if v != nil { return lint_expr_uses_this(v.callee) }
	case ^AssignmentExpression: if v != nil {
		if l, f := lint_expr_uses_this(v.left); f { return l, f }
		return lint_expr_uses_this(v.right)
	}
	}
	return {}, false
}

// lint_check_accessor_pairs (accessor-pairs, L4054): flags an object or class
// that has a setter without a matching getter.
lint_check_accessor_pairs :: proc(l: ^Linter, cls: ^ClassExpression) {
	if cls == nil || !lint_rule_enabled(l, .L4054_AccessorPairs) { return }
	getters := make(map[string]bool, 0, context.temp_allocator)
	setters := make(map[string]Loc, 0, context.temp_allocator)
	for elem in cls.body.body {
		if elem.computed || elem.key == nil { continue }
		name: string
		#partial switch k in elem.key^ {
		case ^Identifier:    if k != nil { name = k.name }
		case ^StringLiteral: if k != nil { name = k.value }
		case: continue
		}
		if elem.kind == .Get { getters[name] = true }
		if elem.kind == .Set { setters[name] = elem.loc }
	}
	for name, loc in setters {
		if !getters[name] {
			info := lint_rule_info(.L4054_AccessorPairs)
			lint_report(l, u32(loc.start), u32(loc.end), .L4054_AccessorPairs, info.default_message)
		}
	}
}

// lint_check_grouped_accessor_pairs (grouped-accessor-pairs, L4055): flags
// getter and setter for the same property that are not adjacent.
lint_check_grouped_accessor_pairs :: proc(l: ^Linter, cls: ^ClassExpression) {
	if cls == nil || !lint_rule_enabled(l, .L4055_GroupedAccessorPairs) { return }
	// Map name -> index of first accessor seen.
	first_idx := make(map[string]int, 0, context.temp_allocator)
	for elem, idx in cls.body.body {
		if elem.computed || elem.key == nil { continue }
		if elem.kind != .Get && elem.kind != .Set { continue }
		name: string
		#partial switch k in elem.key^ {
		case ^Identifier:    if k != nil { name = k.name }
		case ^StringLiteral: if k != nil { name = k.value }
		case: continue
		}
		if prev, has := first_idx[name]; has {
			if idx != prev + 1 {
				info := lint_rule_info(.L4055_GroupedAccessorPairs)
				lint_report(l, u32(elem.loc.start), u32(elem.loc.end), .L4055_GroupedAccessorPairs, info.default_message)
			}
		} else {
			first_idx[name] = idx
		}
	}
}

// lint_check_prefer_rest_params (prefer-rest-params, L4056): flags use of
// the `arguments` identifier inside functions.
lint_check_prefer_rest_params :: proc(l: ^Linter, e: ^Identifier) {
	if e == nil || !lint_rule_enabled(l, .L4056_PreferRestParams) { return }
	if e.name != "arguments" { return }
	info := lint_rule_info(.L4056_PreferRestParams)
	lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4056_PreferRestParams, info.default_message)
}

// lint_check_prefer_spread (prefer-spread, L4057): flags `foo.apply(null, args)`
// or `foo.apply(undefined, args)` — use spread instead.
lint_check_prefer_spread :: proc(l: ^Linter, e: ^CallExpression) {
	if e == nil || !lint_rule_enabled(l, .L4057_PreferSpread) { return }
	if len(e.arguments) != 2 { return }
	mem, is_mem := e.callee^.(^MemberExpression)
	if !is_mem || mem == nil || mem.computed { return }
	prop_id, p_ok := mem.property^.(^Identifier)
	if !p_ok || prop_id == nil || prop_id.name != "apply" { return }
	first := e.arguments[0]
	if first == nil { return }
	#partial switch v in first^ {
	case ^NullLiteral:
		info := lint_rule_info(.L4057_PreferSpread)
		lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4057_PreferSpread, info.default_message)
	case ^Identifier:
		if v != nil && v.name == "undefined" {
			info := lint_rule_info(.L4057_PreferSpread)
			lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4057_PreferSpread, info.default_message)
		}
	}
}

// lint_check_no_param_reassign (no-param-reassign, L4058): flags assignment
// to a function parameter name. Uses the semantic model.
lint_check_no_param_reassign :: proc(l: ^Linter, e: ^AssignmentExpression) {
	if e == nil || !lint_rule_enabled(l, .L4058_NoParamReassign) { return }
	if l.semantic == nil { return }
	id, ok := e.left.(^Identifier)
	if !ok || id == nil { return }
	for i in 1..<len(l.semantic.symbols) {
		sym := &l.semantic.symbols[i]
		if sym.name == id.name && sym.kind == .Param {
			info := lint_rule_info(.L4058_NoParamReassign)
			lint_report(l, u32(id.loc.start), u32(id.loc.end), .L4058_NoParamReassign, info.default_message)
			return
		}
	}
}

// lint_check_no_inferrable_types (no-inferrable-types, L3007): flags
// `const x: number = 5` where the type annotation matches the initializer.
lint_check_no_inferrable_types :: proc(l: ^Linter, d: ^VariableDeclaration) {
	if d == nil || !lint_rule_enabled(l, .L3007_NoInferrableTypes) { return }
	// TODO: needs pattern type_annotation access — deferred.
}

// lint_check_no_duplicate_enum_values (no-duplicate-enum-values, L3008): flags
// TS enum members that share the same initializer value.
lint_check_no_duplicate_enum_values :: proc(l: ^Linter, v: ^TSEnumDeclaration) {
	if v == nil || !lint_rule_enabled(l, .L3008_NoDuplicateEnumValues) { return }
	seen := make(map[string]bool, 0, context.temp_allocator)
	for mem in v.body.members {
		init, has_init := mem.initializer.(^Expression)
		if !has_init || init == nil { continue }
		val_str: string
		have := false
		#partial switch iv in init^ {
		case ^NumericLiteral: if iv != nil { val_str = iv.raw; have = true }
		case ^StringLiteral:  if iv != nil { val_str = iv.value; have = true }
		}
		if !have { continue }
		if seen[val_str] {
			info := lint_rule_info(.L3008_NoDuplicateEnumValues)
			lint_report(l, u32(mem.loc.start), u32(mem.loc.end), .L3008_NoDuplicateEnumValues, info.default_message)
		} else {
			seen[val_str] = true
		}
	}
}

// lint_check_no_empty_interface (no-empty-interface, L3010): flags
// `interface Foo {}` with no members and no extends.
lint_check_no_empty_interface :: proc(l: ^Linter, v: ^TSInterfaceDeclaration) {
	if v == nil || !lint_rule_enabled(l, .L3010_NoEmptyInterface) { return }
	if len(v.body.body) > 0 { return }
	if len(v.extends) > 0 { return }
	info := lint_rule_info(.L3010_NoEmptyInterface)
	lint_report(l, u32(v.loc.start), u32(v.loc.end), .L3010_NoEmptyInterface, info.default_message)
}

// lint_check_no_require_imports (no-require-imports, L3011): flags
// `require(...)` calls.
lint_check_no_require_imports :: proc(l: ^Linter, e: ^CallExpression) {
	if e == nil || !lint_rule_enabled(l, .L3011_NoRequireImports) { return }
	if e.callee == nil { return }
	id, ok := e.callee^.(^Identifier)
	if !ok || id == nil || id.name != "require" { return }
	info := lint_rule_info(.L3011_NoRequireImports)
	lint_report(l, u32(e.loc.start), u32(e.loc.end), .L3011_NoRequireImports, info.default_message)
}

// lint_check_no_buffer_constructor (no-buffer-constructor, L4077): flags
// `Buffer()` called without `new`.
lint_check_no_buffer_constructor :: proc(l: ^Linter, e: ^CallExpression) {
	if e == nil || !lint_rule_enabled(l, .L4077_NoBufferConstructor) { return }
	id, ok := e.callee^.(^Identifier)
	if !ok || id == nil || id.name != "Buffer" { return }
	info := lint_rule_info(.L4077_NoBufferConstructor)
	lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4077_NoBufferConstructor, info.default_message)
}

// lint_check_no_octal_escape (no-octal-escape, L4078): flags string literals
// containing octal escape sequences (\1, \01, etc.).
lint_check_no_octal_escape :: proc(l: ^Linter, e: ^StringLiteral) {
	if e == nil || !lint_rule_enabled(l, .L4078_NoOctalEscape) { return }
	raw := e.raw
	for i in 0..<len(raw) {
		if raw[i] == '\\' && i + 1 < len(raw) {
			next := raw[i + 1]
			if next >= '0' && next <= '7' {
				info := lint_rule_info(.L4078_NoOctalEscape)
				lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4078_NoOctalEscape, info.default_message)
				return
			}
		}
	}
}

// lint_check_prefer_exponentiation_operator (prefer-exponentiation-operator,
// L4082): flags `Math.pow(a, b)` — should use `a ** b`.
lint_check_prefer_exponentiation_operator :: proc(l: ^Linter, e: ^CallExpression) {
	if e == nil || !lint_rule_enabled(l, .L4082_PreferExponentiationOperator) { return }
	mem, ok := e.callee^.(^MemberExpression)
	if !ok || mem == nil || mem.computed { return }
	obj_id, ok2 := mem.object^.(^Identifier)
	if !ok2 || obj_id == nil || obj_id.name != "Math" { return }
	prop_id, ok3 := mem.property^.(^Identifier)
	if !ok3 || prop_id == nil || prop_id.name != "pow" { return }
	info := lint_rule_info(.L4082_PreferExponentiationOperator)
	lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4082_PreferExponentiationOperator, info.default_message)
}

// lint_check_no_loop_func (no-loop-func, L4074): flags function declarations
// or function expressions inside a loop body.
lint_check_no_loop_func :: proc(l: ^Linter, body: []^Statement) {
	if !lint_rule_enabled(l, .L4074_NoLoopFunc) { return }
	for s in body {
		if s == nil { continue }
		#partial switch v in s^ {
		case ^FunctionDeclaration:
			if v != nil {
				info := lint_rule_info(.L4074_NoLoopFunc)
				lint_report(l, u32(v.loc.start), u32(v.loc.end), .L4074_NoLoopFunc, info.default_message)
			}
		case ^BlockStatement:
			if v != nil { lint_check_no_loop_func(l, v.body[:]) }
		}
	}
}

// lint_check_await_in_loop (no-await-in-loop, L2054): flags `await`
// inside for/while/do-while bodies (shallow scan).
lint_check_no_await_in_loop :: proc(l: ^Linter, body: []^Statement) {
	if !lint_rule_enabled(l, .L2054_NoAwaitInLoop) { return }
	lint_scan_await_in_loop(l, body)
}

lint_scan_await_in_loop :: proc(l: ^Linter, body: []^Statement) {
	for s in body {
		if s == nil { continue }
		#partial switch v in s^ {
		case ^ExpressionStatement:
			if v != nil && lint_expr_has_await(v.expression) {
				info := lint_rule_info(.L2054_NoAwaitInLoop)
				lint_report(l, u32(v.loc.start), u32(v.loc.end), .L2054_NoAwaitInLoop, info.default_message)
			}
		case ^ForStatement, ^WhileStatement, ^DoWhileStatement:
			// Recurse into loop body with await scan disabled
			// (we only flag await one level deep in non-async loops).
		case ^BlockStatement:
			if v != nil { lint_scan_await_in_loop(l, v.body[:]) }
		}
	}
}

lint_expr_has_await :: proc(e: ^Expression) -> bool {
	if e == nil { return false }
	#partial switch v in e^ {
	case ^AwaitExpression: return true
	case ^BinaryExpression: return lint_expr_has_await(v.left) || lint_expr_has_await(v.right)
	case ^CallExpression:
		if lint_expr_has_await(v.callee) { return true }
		for a in v.arguments { if lint_expr_has_await(a) { return true } }
		return false
	case ^MemberExpression: return lint_expr_has_await(v.object)
	}
	return false
}

// lint_check_no_type_alias (no-type-alias, L3012): flags `type X = ...`.
lint_check_no_type_alias :: proc(l: ^Linter, v: ^TSTypeAliasDeclaration) {
	if v == nil || !lint_rule_enabled(l, .L3012_NoTypeAlias) { return }
	info := lint_rule_info(.L3012_NoTypeAlias)
	lint_report(l, u32(v.loc.start), u32(v.loc.end), .L3012_NoTypeAlias, info.default_message)
}

// lint_check_no_undefined (no-undefined, L4061): flags `undefined` identifiers.
lint_check_no_undefined :: proc(l: ^Linter, e: ^Identifier) {
	if e == nil || !lint_rule_enabled(l, .L4061_NoUndefined) { return }
	if e.name != "undefined" { return }
	info := lint_rule_info(.L4061_NoUndefined)
	lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4061_NoUndefined, info.default_message)
}

// lint_check_no_instanceof (no-instanceof, L4062): flags `instanceof` operator.
lint_check_no_instanceof :: proc(l: ^Linter, e: ^BinaryExpression) {
	if e == nil || !lint_rule_enabled(l, .L4062_NoInstanceof) { return }
	if e.operator != .Instanceof { return }
	info := lint_rule_info(.L4062_NoInstanceof)
	lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4062_NoInstanceof, info.default_message)
}

// lint_check_no_mixed_operators (no-mixed-operators, L4060): flags `a + b * c`
// where different operator precedence levels are mixed without parens.
lint_check_no_mixed_operators :: proc(l: ^Linter, e: ^BinaryExpression) {
	if e == nil || !lint_rule_enabled(l, .L4060_NoMixedOperators) { return }
	// Check if left or right is a BinaryExpression with a different precedence.
	cur_prec := lint_op_precedence(e.operator)
	if e.left != nil {
		if left_bin, ok := e.left^.(^BinaryExpression); ok && left_bin != nil {
			if lint_op_precedence(left_bin.operator) != cur_prec {
				info := lint_rule_info(.L4060_NoMixedOperators)
				lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4060_NoMixedOperators, info.default_message)
				return
			}
		}
	}
	if e.right != nil {
		if right_bin, ok := e.right^.(^BinaryExpression); ok && right_bin != nil {
			if lint_op_precedence(right_bin.operator) != cur_prec {
				info := lint_rule_info(.L4060_NoMixedOperators)
				lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4060_NoMixedOperators, info.default_message)
			}
		}
	}
}

lint_op_precedence :: proc(op: BinaryOperator) -> u8 {
	switch op {
	case .Mul, .Div, .Mod, .Pow: return 5
	case .Add, .Sub: return 4
	case .ShiftLeft, .ShiftRight, .ShiftRightUnsigned: return 3
	case .BitAnd, .BitOr, .BitXor: return 2
	case .Eq, .NotEq, .StrictEq, .StrictNotEq, .Lt, .LtEq, .Gt, .GtEq, .Instanceof, .In: return 1
	}
	return 0
}

// lint_check_no_extra_label (no-extra-label, L4063): flags labels on statements
// that don't need them (anything that's not break/continue target).
lint_check_no_extra_label :: proc(l: ^Linter, v: ^LabeledStatement) {
	if v == nil || !lint_rule_enabled(l, .L4063_NoExtraLabel) { return }
	// A label is "extra" if the labeled statement is not a loop or block.
	// (break/continue only target loops; labels on non-loops are usually noise.)
	has_break := false
	#partial switch _ in v.body^ {
	case ^ForStatement, ^WhileStatement, ^DoWhileStatement, ^ForInStatement, ^ForOfStatement:
		has_break = true // loops legitimately use labels
	}
	if !has_break {
		info := lint_rule_info(.L4063_NoExtraLabel)
		lint_report(l, u32(v.loc.start), u32(v.loc.end), .L4063_NoExtraLabel, info.default_message)
	}
}

// lint_check_no_comparison_with_nan (no-comparison-with-nan, L4064):
// flags `x === NaN` or `NaN === x` etc.
lint_check_no_comparison_with_nan :: proc(l: ^Linter, e: ^BinaryExpression) {
	if e == nil || !lint_rule_enabled(l, .L4064_NoComparisonWithNaN) { return }
	if e.operator != .Eq && e.operator != .NotEq && e.operator != .StrictEq && e.operator != .StrictNotEq { return }
	if lint_expr_is_nan(e.left) || lint_expr_is_nan(e.right) {
		info := lint_rule_info(.L4064_NoComparisonWithNaN)
		lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4064_NoComparisonWithNaN, info.default_message)
	}
}

// lint_check_no_new_symbol (no-new-symbol, L4065): flags `new Symbol()`.
lint_check_no_new_symbol :: proc(l: ^Linter, e: ^NewExpression) {
	if e == nil || !lint_rule_enabled(l, .L4065_NoNewSymbol) { return }
	id, ok := e.callee^.(^Identifier)
	if !ok || id == nil || id.name != "Symbol" { return }
	info := lint_rule_info(.L4065_NoNewSymbol)
	lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4065_NoNewSymbol, info.default_message)
}

// lint_check_no_multiline_strings (no-multi-str, L4066): flags string literals
// whose value contains a newline (backslash continuation).
lint_check_no_multiline_strings :: proc(l: ^Linter, e: ^StringLiteral) {
	if e == nil || !lint_rule_enabled(l, .L4066_NoMultilineStrings) { return }
	for ch in e.value {
		if ch == '\n' {
			info := lint_rule_info(.L4066_NoMultilineStrings)
			lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4066_NoMultilineStrings, info.default_message)
			return
		}
	}
}

// lint_check_prefer_dot_notation (prefer-dot-notation, L4068): flags computed
// member expression with a string literal key that is a valid identifier.
lint_check_prefer_dot_notation :: proc(l: ^Linter, e: ^MemberExpression) {
	if e == nil || !lint_rule_enabled(l, .L4068_PreferDotNotation) { return }
	if !e.computed || e.property == nil { return }
	str, ok := e.property^.(^StringLiteral)
	if !ok || str == nil { return }
	if lint_valid_identifier(str.value) {
		info := lint_rule_info(.L4068_PreferDotNotation)
		lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4068_PreferDotNotation, info.default_message)
	}
}

lint_valid_identifier :: proc(s: string) -> bool {
	if len(s) == 0 { return false }
	// Must be a valid JS identifier: start with letter/_/$, rest alnum/_/$.
	c := s[0]
	if !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') && c != '_' && c != '$' { return false }
	for i in 1..<len(s) {
		c2 := s[i]
		if !(c2 >= 'a' && c2 <= 'z') && !(c2 >= 'A' && c2 <= 'Z') && !(c2 >= '0' && c2 <= '9') && c2 != '_' && c2 != '$' { return false }
	}
	return true
}

// lint_check_ts_non_null (no-non-null-assertion, L3005): flags `x!` postfix.
lint_check_ts_non_null :: proc(l: ^Linter, e: ^TSNonNullExpression) {
	if e == nil || !lint_rule_enabled(l, .L3005_NoNonNullAssertion) { return }
	info := lint_rule_info(.L3005_NoNonNullAssertion)
	lint_report(l, u32(e.loc.start), u32(e.loc.end), .L3005_NoNonNullAssertion, info.default_message)
}

// lint_check_ts_namespace (no-namespace, L3004): flags TSModuleDeclaration.
lint_check_ts_namespace :: proc(l: ^Linter, v: ^TSModuleDeclaration) {
	if v == nil || !lint_rule_enabled(l, .L3004_NoNamespace) { return }
	info := lint_rule_info(.L3004_NoNamespace)
	lint_report(l, u32(v.loc.start), u32(v.loc.end), .L3004_NoNamespace, info.default_message)
}

// lint_check_no_empty_function (no-empty-function, L4001): flags function
// bodies with zero statements. Distinct from no-empty (L1001) which checks
// block statements only.
lint_check_no_empty_function :: proc(l: ^Linter, fn: ^FunctionExpression) {
	if fn == nil || fn.no_body || !lint_rule_enabled(l, .L4001_NoEmptyFunction) { return }
	if len(fn.body.body) == 0 {
		info := lint_rule_info(.L4001_NoEmptyFunction)
		lint_report(l, u32(fn.loc.start), u32(fn.loc.end), .L4001_NoEmptyFunction, info.default_message)
	}
}

// lint_check_no_array_constructor (no-array-constructor, L4004): flags
// `new Array()` and `new Array(1, 2)`. Single-arg `new Array(n)` is also
// flagged since Array.from or literal `[]` is always clearer.
lint_check_no_array_constructor :: proc(l: ^Linter, e: ^NewExpression) {
	if e == nil || !lint_rule_enabled(l, .L4004_NoArrayConstructor) { return }
	callee, ok := e.callee^.(^Identifier)
	if !ok || callee == nil || callee.name != "Array" { return }
	info := lint_rule_info(.L4004_NoArrayConstructor)
	lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4004_NoArrayConstructor, info.default_message)
}

// lint_check_no_throw_literal (no-throw-literal, L4005): flags `throw` of a
// non-Error value (literal, identifier to a primitive). Only literal throws
// are checked for simplicity.
// lint_check_no_eval (no-eval, L4008): flags direct `eval()` calls.
// lint_check_no_new_func (no-new-func, L4016): flags `new Function()`.
lint_check_no_new_func :: proc(l: ^Linter, e: ^NewExpression) {
	if e == nil || !lint_rule_enabled(l, .L4016_NoNewFunc) { return }
	id, ok := e.callee^.(^Identifier)
	if !ok || id == nil || id.name != "Function" { return }
	info := lint_rule_info(.L4016_NoNewFunc)
	lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4016_NoNewFunc, info.default_message)
}

// lint_check_no_proto (no-proto, L4018): flags `obj.__proto__` access.
lint_check_no_proto :: proc(l: ^Linter, e: ^MemberExpression) {
	if e == nil || e.computed || !lint_rule_enabled(l, .L4018_NoProto) { return }
	prop, ok := e.property^.(^Identifier)
	if !ok || prop == nil || prop.name != "__proto__" { return }
	info := lint_rule_info(.L4018_NoProto)
	lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4018_NoProto, info.default_message)
}

// lint_check_no_iterator (no-iterator, L4022): flags `obj.__iterator__`.
lint_check_no_iterator :: proc(l: ^Linter, e: ^MemberExpression) {
	if e == nil || e.computed || !lint_rule_enabled(l, .L4022_NoIterator) { return }
	prop, ok := e.property^.(^Identifier)
	if !ok || prop == nil || prop.name != "__iterator__" { return }
	info := lint_rule_info(.L4022_NoIterator)
	lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4022_NoIterator, info.default_message)
}

// lint_check_no_caller (no-caller, L4023): flags `arguments.caller` and
// `arguments.callee`.
lint_check_no_caller :: proc(l: ^Linter, e: ^MemberExpression) {
	if e == nil || e.computed || !lint_rule_enabled(l, .L4023_NoCallerCallee) { return }
	obj, ook := e.object^.(^Identifier)
	if !ook || obj == nil || obj.name != "arguments" { return }
	prop, pok := e.property^.(^Identifier)
	if !pok || prop == nil { return }
	if prop.name == "caller" || prop.name == "callee" {
		info := lint_rule_info(.L4023_NoCallerCallee)
		lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4023_NoCallerCallee, info.default_message)
	}
}

// lint_check_no_script_url (no-script-url, L4019): flags string literals
// starting with "javascript:".
lint_check_no_script_url :: proc(l: ^Linter, e: ^StringLiteral) {
	if e == nil || !lint_rule_enabled(l, .L4019_NoScriptUrl) { return }
	if len(e.value) >= 11 && e.value[:11] == "javascript:" {
		info := lint_rule_info(.L4019_NoScriptUrl)
		lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4019_NoScriptUrl, info.default_message)
	}
}

// lint_check_no_useless_concat (no-useless-concat, L4021): flags "a" + "b".
lint_check_no_useless_concat :: proc(l: ^Linter, e: ^BinaryExpression) {
	if e == nil || e.operator != .Add || !lint_rule_enabled(l, .L4021_NoUselessConcat) { return }
	_, lok := e.left^.(^StringLiteral)
	_, rok := e.right^.(^StringLiteral)
	if lok && rok {
		info := lint_rule_info(.L4021_NoUselessConcat)
		lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4021_NoUselessConcat, info.default_message)
	}
}

// lint_check_no_unsafe_finally (no-unsafe-finally, L4024): flags
// break/continue/return/throw inside a finally block — these override the
// try/catch completion value and are almost always a bug.
// lint_check_no_alert (no-alert, L4029): flags alert/confirm/prompt calls.
lint_check_no_alert :: proc(l: ^Linter, e: ^CallExpression) {
	if e == nil || !lint_rule_enabled(l, .L4029_NoAlert) { return }
	id, ok := e.callee^.(^Identifier)
	if !ok || id == nil { return }
	switch id.name {
	case "alert", "confirm", "prompt":
		info := lint_rule_info(.L4029_NoAlert)
		lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4029_NoAlert, info.default_message)
	}
}

// lint_check_default_case_last (default-case-last, L4031): the default clause
// in a switch should be last.
lint_check_default_case_last :: proc(l: ^Linter, v: ^SwitchStatement) {
	if v == nil || !lint_rule_enabled(l, .L4031_DefaultCaseLast) { return }
	for idx in 0..<len(v.cases) {
		sc := v.cases[idx]
		_, has_test := sc.test.(^Expression)
		if !has_test && idx < len(v.cases) - 1 {
			info := lint_rule_info(.L4031_DefaultCaseLast)
			lint_report(l, u32(sc.loc.start), u32(sc.loc.end), .L4031_DefaultCaseLast, info.default_message)
			return
		}
	}
}

// lint_check_no_new_object (no-object-constructor, L4033): flags `new Object()`.
lint_check_no_new_object :: proc(l: ^Linter, e: ^NewExpression) {
	if e == nil || !lint_rule_enabled(l, .L4033_NoNewObject) { return }
	id, ok := e.callee^.(^Identifier)
	if !ok || id == nil || id.name != "Object" { return }
	info := lint_rule_info(.L4033_NoNewObject)
	lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4033_NoNewObject, info.default_message)
}

lint_check_no_unsafe_finally :: proc(l: ^Linter, v: ^TryStatement) {
	if v == nil || !lint_rule_enabled(l, .L4024_NoUnsafeFinally) { return }
	f, ok := v.finalizer.(BlockStatement)
	if !ok { return }
	for s in f.body {
		lint_scan_unsafe_finally(l, s)
	}
}

lint_scan_unsafe_finally :: proc(l: ^Linter, stmt: ^Statement) {
	if stmt == nil { return }
	#partial switch v in stmt^ {
	case ^ReturnStatement, ^ThrowStatement, ^BreakStatement, ^ContinueStatement:
		sloc := lint_stmt_loc(stmt)
		info := lint_rule_info(.L4024_NoUnsafeFinally)
		lint_report(l, u32(sloc.start), u32(sloc.end), .L4024_NoUnsafeFinally, info.default_message)
	case ^BlockStatement:
		if v != nil { for s in v.body { lint_scan_unsafe_finally(l, s) } }
	case ^IfStatement:
		if v != nil {
			lint_scan_unsafe_finally(l, v.consequent)
			if alt, ok := v.alternate.(^Statement); ok { lint_scan_unsafe_finally(l, alt) }
		}
	}
}

// lint_check_no_extend_native (no-extend-native, L4025): flags
// `Object.prototype.foo = ...` and similar native prototype extensions.
lint_check_no_extend_native :: proc(l: ^Linter, e: ^AssignmentExpression) {
	if e == nil || !lint_rule_enabled(l, .L4025_NoExtendNative) { return }
	member, ok := e.left.(^MemberExpression)
	if !ok || member == nil { return }
	// Check if the object is X.prototype where X is a known native.
	inner, iok := member.object^.(^MemberExpression)
	if !iok || inner == nil || inner.computed { return }
	prop, pok := inner.property^.(^Identifier)
	if !pok || prop == nil || prop.name != "prototype" { return }
	obj_id, oid_ok := inner.object^.(^Identifier)
	if !oid_ok || obj_id == nil { return }
	switch obj_id.name {
	case "Object", "Array", "String", "Number", "Boolean", "Function",
		"RegExp", "Date", "Error", "Map", "Set", "WeakMap", "WeakSet", "Promise":
		info := lint_rule_info(.L4025_NoExtendNative)
		lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4025_NoExtendNative, info.default_message)
	}
}

// lint_check_symbol_description (symbol-description, L4028): flags
// `Symbol()` without a description argument.
lint_check_symbol_description :: proc(l: ^Linter, e: ^CallExpression) {
	if e == nil || !lint_rule_enabled(l, .L4028_SymbolDescription) { return }
	id, ok := e.callee^.(^Identifier)
	if !ok || id == nil || id.name != "Symbol" { return }
	if len(e.arguments) == 0 {
		info := lint_rule_info(.L4028_SymbolDescription)
		lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4028_SymbolDescription, info.default_message)
	}
}

lint_check_no_eval :: proc(l: ^Linter, e: ^CallExpression) {
	if e == nil || !lint_rule_enabled(l, .L4008_NoEval) { return }
	id, ok := e.callee^.(^Identifier)
	if !ok || id == nil || id.name != "eval" { return }
	info := lint_rule_info(.L4008_NoEval)
	lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4008_NoEval, info.default_message)
}

// lint_check_no_implied_eval (no-implied-eval, L4009): flags setTimeout/
// setInterval with a string first argument (implied eval).
lint_check_no_implied_eval :: proc(l: ^Linter, e: ^CallExpression) {
	if e == nil || !lint_rule_enabled(l, .L4009_NoImpliedEval) { return }
	if len(e.arguments) == 0 { return }
	id, ok := e.callee^.(^Identifier)
	if !ok || id == nil { return }
	if id.name != "setTimeout" && id.name != "setInterval" { return }
	if _, sok := e.arguments[0]^.(^StringLiteral); sok {
		info := lint_rule_info(.L4009_NoImpliedEval)
		lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4009_NoImpliedEval, info.default_message)
	}
}

// lint_check_no_return_assign (no-return-assign, L4010): flags assignment
// expressions directly inside a return statement.
lint_check_no_return_assign :: proc(l: ^Linter, v: ^ReturnStatement) {
	if v == nil || !lint_rule_enabled(l, .L4010_NoReturnAssign) { return }
	arg, ok := v.argument.(^Expression)
	if !ok || arg == nil { return }
	if _, aok := arg^.(^AssignmentExpression); aok {
		info := lint_rule_info(.L4010_NoReturnAssign)
		lint_report(l, u32(v.loc.start), u32(v.loc.end), .L4010_NoReturnAssign, info.default_message)
	}
}

// lint_check_no_new_wrappers (no-new-wrappers, L4011): flags `new String()`,
// `new Number()`, `new Boolean()` — primitive wrapper objects are almost
// always a mistake.
lint_check_no_new_wrappers :: proc(l: ^Linter, e: ^NewExpression) {
	if e == nil || !lint_rule_enabled(l, .L4011_NoNewWrappers) { return }
	id, ok := e.callee^.(^Identifier)
	if !ok || id == nil { return }
	switch id.name {
	case "String", "Number", "Boolean":
		info := lint_rule_info(.L4011_NoNewWrappers)
		lint_report(l, u32(e.loc.start), u32(e.loc.end), .L4011_NoNewWrappers, info.default_message)
	}
}

lint_check_no_throw_literal :: proc(l: ^Linter, v: ^ThrowStatement) {
	if v == nil || !lint_rule_enabled(l, .L4005_NoThrowLiteral) { return }
	if v.argument == nil { return }
	#partial switch _ in v.argument^ {
	case ^StringLiteral, ^NumericLiteral, ^BooleanLiteral, ^NullLiteral, ^BigIntLiteral:
		info := lint_rule_info(.L4005_NoThrowLiteral)
		lint_report(l, u32(v.loc.start), u32(v.loc.end), .L4005_NoThrowLiteral, info.default_message)
	}
}

lint_check_no_extra_boolean_cast :: proc(l: ^Linter, test: ^Expression, start, end: u32) {
	if test == nil || !lint_rule_enabled(l, .L2042_NoExtraBooleanCast) { return }
	// Double negation: !!x
	u1, ok1 := test^.(^UnaryExpression)
	if ok1 && u1 != nil && u1.operator == .LogicalNot {
		u2, ok2 := u1.argument^.(^UnaryExpression)
		if ok2 && u2 != nil && u2.operator == .LogicalNot {
			info := lint_rule_info(.L2042_NoExtraBooleanCast)
			lint_report(l, u32(u1.loc.start), u32(u1.loc.end), .L2042_NoExtraBooleanCast, info.default_message)
			return
		}
	}
	// Boolean(x) call in boolean context.
	c, cok := test^.(^CallExpression)
	if cok && c != nil {
		id, iok := c.callee^.(^Identifier)
		if iok && id != nil && id.name == "Boolean" {
			info := lint_rule_info(.L2042_NoExtraBooleanCast)
			lint_report(l, u32(c.loc.start), u32(c.loc.end), .L2042_NoExtraBooleanCast, info.default_message)
		}
	}
}

lint_walk_expr :: proc(l: ^Linter, ctx: ^LintContext, expr: ^Expression) {
	if expr == nil { return }
	switch e in expr^ {
	case ^MemberExpression:
		if e != nil {
			lint_check_no_proto(l, e); lint_check_no_iterator(l, e); lint_check_no_caller(l, e); lint_check_prefer_dot_notation(l, e)
			lint_walk_expr(l, ctx, e.object)
			if e.computed && e.property != nil { lint_walk_expr(l, ctx, e.property) }
		}
	case ^CallExpression:
		if e != nil { lint_check_obj_calls(l, e); lint_check_prototype_builtins(l, e); lint_check_no_eval(l, e); lint_check_no_implied_eval(l, e); lint_check_symbol_description(l, e); lint_check_no_alert(l, e); lint_check_no_unsafe_optional_chaining_call(l, e.callee); lint_check_prefer_numeric_literals(l, e); lint_check_no_useless_call(l, e); lint_check_prefer_arrow_callback(l, e); lint_check_prefer_spread(l, e); lint_check_no_require_imports(l, e); lint_check_no_buffer_constructor(l, e); lint_check_prefer_exponentiation_operator(l, e); lint_walk_expr(l, ctx, e.callee); for a in e.arguments { lint_walk_expr(l, ctx, a) } }
	case ^NewExpression:
		if e != nil { lint_check_async_promise(l, e); lint_check_new_native(l, e); lint_check_no_array_constructor(l, e); lint_check_no_new_wrappers(l, e); lint_check_no_new_func(l, e); lint_check_no_new_object(l, e); lint_check_no_new_symbol(l, e); lint_check_no_unsafe_optional_chaining_call(l, e.callee); lint_check_no_promise_exec_return(l, e); lint_walk_expr(l, ctx, e.callee); for a in e.arguments { lint_walk_expr(l, ctx, a) } }
	case ^ConditionalExpression:
		if e != nil {
			lint_check_constant_condition(l, e.test, u32(e.loc.start), u32(e.loc.end))
			lint_check_cond_assign(l, e.test, u32(e.loc.start), u32(e.loc.end))
			lint_check_no_nested_ternary(l, e)
			lint_check_no_unneeded_ternary(l, e)
			lint_walk_expr(l, ctx, e.test)
			lint_walk_expr(l, ctx, e.consequent)
			lint_walk_expr(l, ctx, e.alternate)
		}
	case ^BinaryExpression:     if e != nil { lint_check_eqeqeq(l, e); lint_check_binary(l, e); lint_check_valid_typeof(l, e); lint_check_no_useless_concat(l, e); lint_check_no_bitwise(l, e); lint_check_yoda(l, e); lint_check_no_instanceof(l, e); lint_check_no_mixed_operators(l, e); lint_check_no_comparison_with_nan(l, e); lint_walk_expr(l, ctx, e.left); lint_walk_expr(l, ctx, e.right) }
	case ^LogicalExpression:    if e != nil { lint_walk_expr(l, ctx, e.left); lint_walk_expr(l, ctx, e.right) }
	case ^AssignmentExpression: if e != nil { lint_check_self_assign(l, e); lint_check_no_extend_native(l, e); lint_check_no_global_assign(l, e); lint_check_no_import_assign(l, e); lint_check_no_class_assign(l, e); lint_check_no_func_assign(l, e); lint_check_no_param_reassign(l, e); lint_check_operator_assignment(l, e); lint_walk_expr(l, ctx, e.left); lint_walk_expr(l, ctx, e.right) }
	case ^SequenceExpression:   if e != nil { for s in e.expressions { lint_walk_expr(l, ctx, s) } }
	case ^ArrayExpression:
		if e != nil {
			lint_check_sparse_array(l, e)
			for el in e.elements {
				if inner, ok := el.(^Expression); ok && inner != nil { lint_walk_expr(l, ctx, inner) }
			}
		}
	case ^ObjectExpression:
		if e != nil {
			lint_check_dupe_keys(l, e)
			for prop in e.properties {
				lint_check_getter_return_obj(l, prop)
				lint_check_no_useless_computed_key(l, prop)
				if prop.computed && prop.key != nil { lint_walk_expr(l, ctx, prop.key) }
				if prop.value != nil { lint_walk_expr(l, ctx, prop.value) }
			}
		}
	case ^SpreadElement:           if e != nil { lint_walk_expr(l, ctx, e.argument) }
	case ^UnaryExpression:         if e != nil { lint_check_delete_var(l, e); lint_check_no_void(l, e); lint_walk_expr(l, ctx, e.argument) }
	case ^UpdateExpression:        if e != nil { lint_check_no_plusplus(l, e); lint_walk_expr(l, ctx, e.argument) }
	case ^ParenthesizedExpression: if e != nil { lint_walk_expr(l, ctx, e.expression) }
	case ^AwaitExpression:         if e != nil { lint_walk_expr(l, ctx, e.argument) }
	case ^YieldExpression:
		if e != nil {
			if a, ok := e.argument.(^Expression); ok && a != nil { lint_walk_expr(l, ctx, a) }
		}
	case ^ChainExpression:           if e != nil { lint_walk_expr(l, ctx, e.expression) }
	case ^TaggedTemplateExpression:  if e != nil { lint_walk_expr(l, ctx, e.tag); lint_walk_expr(l, ctx, e.quasi) }
	case ^TemplateLiteral:           if e != nil { for s in e.expressions { lint_walk_expr(l, ctx, s) } }
	case ^ImportExpression:          if e != nil { lint_walk_expr(l, ctx, e.source); lint_walk_expr(l, ctx, e.options) }
	case ^FunctionExpression:        if e != nil { lint_walk_function(l, ctx, e) }
	case ^ArrowFunctionExpression:   lint_walk_arrow(l, ctx, e)
	case ^ClassExpression:           if e != nil { lint_walk_class(l, ctx, e) }
	case ^TSAsExpression:            if e != nil { lint_walk_expr(l, ctx, e.expression) }
	case ^TSSatisfiesExpression:     if e != nil { lint_walk_expr(l, ctx, e.expression) }
	case ^TSNonNullExpression:       if e != nil { lint_check_ts_non_null(l, e); lint_walk_expr(l, ctx, e.expression) }
	case ^TSTypeAssertion:           if e != nil { lint_walk_expr(l, ctx, e.expression) }
	case ^TSInstantiationExpression: if e != nil { lint_walk_expr(l, ctx, e.expression) }
	case ^JSXElement:
		if e != nil {
			if e.opening_element != nil {
				for attr in e.opening_element.attributes { lint_walk_jsx_attr(l, ctx, attr) }
			}
			for child in e.children { lint_walk_jsx_child(l, ctx, child) }
		}
	case ^JSXFragment:
		if e != nil { for child in e.children { lint_walk_jsx_child(l, ctx, child) } }
	case ^NumericLiteral:
		if e != nil { lint_check_no_loss_of_precision(l, e) }
	case ^RegExpLiteral:
		if e != nil { lint_check_no_control_regex(l, e); lint_check_no_empty_character_class(l, e); lint_check_no_regex_spaces(l, e) }
	case ^StringLiteral:
		if e != nil { lint_check_no_script_url(l, e); lint_check_template_curly_in_string(l, e); lint_check_no_multiline_strings(l, e); lint_check_no_octal_escape(l, e) }
	case ^NullLiteral, ^BooleanLiteral, ^BigIntLiteral,
	     ^Identifier, ^PrivateIdentifier, ^ThisExpression, ^Super,
	     ^MetaProperty, ^JSXText, ^JSXExpressionContainer, ^JSXEmptyExpression,
	     ^JSXSpreadChild:
		// Leaf / handled via JSX child walk. Literals, identifiers, this/super,
		// meta-property and JSXText carry no child Expression. JSXExpressionContainer
		// / JSXSpreadChild are reached as JSXChild via lint_walk_jsx_child when
		// they appear inside an element; as bare expressions they carry no
		// rule-relevant children for M1.
	}
}

lint_walk_jsx_child :: proc(l: ^Linter, ctx: ^LintContext, child: JSXChild) {
	#partial switch v in child {
	case ^JSXElement:
		if v != nil {
			if v.opening_element != nil {
				for attr in v.opening_element.attributes { lint_walk_jsx_attr(l, ctx, attr) }
			}
			for ch in v.children { lint_walk_jsx_child(l, ctx, ch) }
		}
	case ^JSXFragment:
		if v != nil { for ch in v.children { lint_walk_jsx_child(l, ctx, ch) } }
	case ^JSXExpressionContainer:
		if v != nil && v.expression != nil { lint_walk_expr(l, ctx, v.expression) }
	case ^JSXSpreadChild:
		if v != nil { lint_walk_expr(l, ctx, v.expression) }
	}
}

lint_walk_jsx_attr :: proc(l: ^Linter, ctx: ^LintContext, attr: JSXAttributeItem) {
	#partial switch a in attr {
	case JSXAttribute:
		if val, ok := a.value.(^Expression); ok && val != nil { lint_walk_expr(l, ctx, val) }
	case ^JSXSpreadAttribute:
		if a != nil && a.argument != nil { lint_walk_expr(l, ctx, a.argument) }
	}
}

// LintOverride is one `--rule name:level` / config entry resolved to a rule.
LintOverride :: struct {
	rule:         LintRule,
	enabled:      bool,
	severity:     Severity,
	set_severity: bool,
}

// lint_rule_by_name maps an ESLint-style kebab-case rule name to its LintRule.
// Returns (rule, true) on a hit, (.None, false) otherwise.
lint_rule_by_name :: proc(name: string) -> (LintRule, bool) {
	// Resolve by scanning the static info table so every rule — including the
	// L40xx set — is reachable by name without a hand-maintained parallel switch
	// (which historically drifted and left ~90 rules unaddressable via --rule).
	if name == "" { return .None, false }
	for rule in LintRule {
		if rule == .None { continue }
		if lint_rule_info(rule).name == name { return rule, true }
	}
	return .None, false
}

// lint_override_from_level resolves a level word (off|warn|error) for a rule.
lint_override_from_level :: proc(rule: LintRule, level: string) -> (LintOverride, bool) {
	switch level {
	case "off":   return LintOverride{rule = rule, enabled = false}, true
	case "warn":  return LintOverride{rule = rule, enabled = true, severity = .Warning, set_severity = true}, true
	case "error": return LintOverride{rule = rule, enabled = true, severity = .Error, set_severity = true}, true
	}
	return LintOverride{}, false
}

// lint_parse_rule_flag parses a `name:level` value (level ∈ off|warn|error)
// into a LintOverride. Returns ok=false on an unknown rule name or level.
lint_parse_rule_flag :: proc(value: string) -> (LintOverride, bool) {
	colon := -1
	for i in 0..<len(value) {
		if value[i] == ':' { colon = i; break }
	}
	if colon < 0 { return LintOverride{}, false }
	name  := value[:colon]
	level := value[colon + 1:]
	rule, have := lint_rule_by_name(name)
	if !have { return LintOverride{}, false }
	return lint_override_from_level(rule, level)
}

// lint_severity_alias resolves a rule name plus a fixed level word into a
// LintOverride. Backs the ESLint-style `--deny`/`--warn`/`--allow` flags, which
// are shorthands for `--rule name:error|warn|off`.
lint_severity_alias :: proc(name: string, level: string) -> (LintOverride, bool) {
	rule, have := lint_rule_by_name(name)
	if !have { return LintOverride{}, false }
	return lint_override_from_level(rule, level)
}

// lint_parse_rules_text parses a newline-separated list of `name:level` tokens
// (the wire format the FFI receives from the JS `opts.rules` object) into
// per-rule overrides, appending each valid entry to `out`. Blank tokens and
// unrecognised names/levels are skipped so callers stay forward-compatible
// with rule names this build does not know. The loop is bounded by the text
// length (TigerStyle: put a limit on everything).
lint_parse_rules_text :: proc(text: string, out: ^[dynamic]LintOverride) {
	start := 0
	for i := 0; i <= len(text); i += 1 {
		if i < len(text) && text[i] != '\n' { continue }
		token := text[start:i]
		start = i + 1
		if len(token) == 0 { continue }
		if ov, ok := lint_parse_rule_flag(token); ok { append(out, ov) }
	}
}

// lint_discover_config searches for a `kessel.lint.json` file starting at
// `start_dir` and walking up toward the filesystem root, returning the path of
// the first match (true) or "" (false) when none is found. This mirrors
// ESLint's upward config search so a bare `kessel lint <files>` picks up a
// project config without an explicit `--config`. The walk is capped at 64
// levels so a pathological path can never loop unbounded (TigerStyle).
lint_discover_config :: proc(start_dir: string) -> (string, bool) {
	dir := start_dir
	for _ in 0..<64 {
		candidate := fmt.tprintf("%s/kessel.lint.json", dir)
		if os.exists(candidate) { return candidate, true }
		parent := os.dir(dir)
		if parent == dir { break }
		dir = parent
	}
	return "", false
}

// lint_load_config reads a `kessel.lint.json` config file and appends the
// resolved per-rule overrides into `out`. Shape:
//   { "rules": { "no-debugger": "off", "eqeqeq": "error" } }
// Unknown rule names and non-string levels are skipped silently (forward-
// compatible). Returns false only when the file cannot be read or is not a
// valid JSON object. CLI `--rule` flags are applied AFTER these so the CLI
// wins.
lint_load_config :: proc(path: string, out: ^[dynamic]LintOverride) -> bool {
	data, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil { return false }
	v, err := json.parse(data, allocator = context.temp_allocator)
	if err != .None { return false }
	obj, is_obj := v.(json.Object)
	if !is_obj { return false }
	rules_v, has_rules := obj["rules"]
	if !has_rules { return true }
	rules, is_rules := rules_v.(json.Object)
	if !is_rules { return false }
	for name, lvl_v in rules {
		lvl, is_str := lvl_v.(json.String)
		if !is_str { continue }
		rule, have := lint_rule_by_name(name)
		if !have { continue }
		if ov, ok2 := lint_override_from_level(rule, string(lvl)); ok2 {
			append(out, ov)
		}
	}
	return true
}

// lint_run_for_job runs the lint pass over a parsed ParseJob, populating the
// returned Linter's diagnostics. `overrides` apply per-rule enable/severity
// config (from `--rule` flags or a config file) before the walk. The arena
// allocator is the job's parse arena (rule state is freed wholesale when the
// job closes). Returns the Linter by value so the caller can render
// `l.diagnostics`.
lint_run_for_job :: proc(job: ^ParseJob, overrides: []LintOverride = nil) -> Linter {
	l := init_linter(job.arena_alloc)
	for ov in overrides {
		l.enabled[ov.rule] = ov.enabled
		if ov.set_severity { l.severity[ov.rule] = ov.severity }
	}
	if job == nil || job.program == nil { return l }
	l.source = job.lexer.source
	ctx := LintContext{ lang = job.lang }
	lint_program(&l, &ctx, job.program)
	// Phase 8c: filter diagnostics suppressed by disable directives.
	if job.lexer.num_lines > 0 {
		lint_apply_disable_directives(&l, job.lexer.source, job.lexer.line_offsets[:job.lexer.num_lines])
	}
	return l
}

// ============================================================================
// Disable directives (Phase 8c)
//
// Scans source text for ESLint-style disable comments:
//   // eslint-disable-next-line [rule, ...]
//   /* eslint-disable [rule, ...] */
//   /* eslint-enable [rule, ...] */
//   // eslint-disable-line [rule, ...]
//
// After the lint walk, diagnostics on suppressed lines are removed.
// ============================================================================

// lint_offset_to_line returns the 0-based line number for a byte offset.
lint_offset_to_line :: proc(line_offsets: []u32, offset: u32) -> int {
	lo, hi := 0, len(line_offsets)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if line_offsets[mid] <= offset { lo = mid + 1 } else { hi = mid }
	}
	return lo - 1 if lo > 0 else 0
}

// lint_directive_rule_list returns the comma-separated rule names that follow a
// disable/enable directive keyword. An empty slice means "all rules", matching
// ESLint's bare `// eslint-disable-next-line` (no rule = suppress everything).
lint_directive_rule_list :: proc(comment_text: string, keyword: string) -> []string {
	if len(comment_text) < len(keyword) { return nil }
	rest := lint_trim_spaces(comment_text[len(keyword):])
	if len(rest) == 0 { return nil }
	out := make([dynamic]string, 0, context.temp_allocator)
	start := 0
	for j := 0; j <= len(rest); j += 1 {
		if j == len(rest) || rest[j] == ',' {
			name := lint_trim_spaces(rest[start:j])
			if len(name) > 0 { append(&out, name) }
			start = j + 1
		}
	}
	return out[:]
}

// lint_suppress_line records suppression for one line. An empty `rules` slice
// blanket-suppresses the line; otherwise only the named rules are suppressed.
lint_suppress_line :: proc(all_lines: ^map[int]bool, line_rules: ^map[int]map[string]bool, line: int, rules: []string) {
	if len(rules) == 0 {
		all_lines^[line] = true
		return
	}
	set, ok := line_rules^[line]
	if !ok { set = make(map[string]bool, 0, context.temp_allocator) }
	for r in rules { set[r] = true }
	line_rules^[line] = set
}

// lint_diag_suppressed reports whether a diagnostic on `line` for rule `code`
// is suppressed by a blanket line entry or a targeted per-rule entry.
lint_diag_suppressed :: proc(all_lines: map[int]bool, line_rules: map[int]map[string]bool, line: int, code: LintRule) -> bool {
	if all_lines[line] { return true }
	set, ok := line_rules[line]
	if !ok { return false }
	return set[lint_rule_info(code).name]
}

// lint_scan_directive applies a single disable/enable directive comment to the
// suppression maps and returns the updated open-range state. Centralizes all
// directive branching so the caller only walks source and slices comments.
lint_scan_directive :: proc(
	text: string, line: int,
	all_lines: ^map[int]bool, line_rules: ^map[int]map[string]bool,
	range_active: bool, range_start_line: int, range_rules: []string,
) -> (bool, int, []string) {
	if lint_starts_with(text, "eslint-disable-next-line") {
		lint_suppress_line(all_lines, line_rules, line + 1, lint_directive_rule_list(text, "eslint-disable-next-line"))
	} else if lint_starts_with(text, "eslint-disable-line") {
		lint_suppress_line(all_lines, line_rules, line, lint_directive_rule_list(text, "eslint-disable-line"))
	} else if lint_starts_with(text, "eslint-enable") {
		if range_active {
			for ln := range_start_line; ln <= line; ln += 1 {
				lint_suppress_line(all_lines, line_rules, ln, range_rules)
			}
			return false, 0, nil
		}
	} else if lint_starts_with(text, "eslint-disable") {
		return true, line, lint_directive_rule_list(text, "eslint-disable")
	}
	return range_active, range_start_line, range_rules
}

lint_apply_disable_directives :: proc(l: ^Linter, source: string, line_offsets: []u32) {
	if len(l.diagnostics) == 0 { return }

	// `suppressed_lines` blanket-suppresses a line; `suppressed_line_rules`
	// suppresses only the rules named on a `// eslint-disable-* rule, …` line.
	suppressed_lines := make(map[int]bool, 0, context.temp_allocator)
	suppressed_line_rules := make(map[int]map[string]bool, 0, context.temp_allocator)

	// Range tracking for /* eslint-disable [rules] */ … /* eslint-enable */.
	range_active := false
	range_start_line := 0
	range_rules: []string

	i := 0
	for i < len(source) {
		ch := source[i]
		if ch == '/' && i + 1 < len(source) && (source[i+1] == '/' || source[i+1] == '*') {
			block := source[i+1] == '*'
			comment_start := i + 2
			comment_end := comment_start
			if block {
				for comment_end + 1 < len(source) {
					if source[comment_end] == '*' && source[comment_end+1] == '/' { break }
					comment_end += 1
				}
			} else {
				for comment_end < len(source) && source[comment_end] != '\n' { comment_end += 1 }
			}
			text := lint_trim_spaces(source[comment_start:comment_end])
			line := lint_offset_to_line(line_offsets, u32(i))
			range_active, range_start_line, range_rules = lint_scan_directive(
				text, line, &suppressed_lines, &suppressed_line_rules,
				range_active, range_start_line, range_rules)
			if block {
				i = comment_end + 2 if comment_end + 1 < len(source) else len(source)
			} else {
				i = comment_end
			}
			continue
		}
		// Skip string literals to avoid false matches.
		if ch == '\'' || ch == '"' || ch == '`' {
			i += 1
			for i < len(source) && source[i] != ch {
				if source[i] == '\\' { i += 1 }
				i += 1
			}
		}
		i += 1
	}

	// An unclosed disable block suppresses through to end of file.
	if range_active {
		last_line := len(line_offsets)
		for ln := range_start_line; ln <= last_line; ln += 1 {
			lint_suppress_line(&suppressed_lines, &suppressed_line_rules, ln, range_rules)
		}
	}

	if len(suppressed_lines) == 0 && len(suppressed_line_rules) == 0 { return }

	// Compact diagnostics, dropping any that a directive suppresses.
	write_idx := 0
	for idx in 0..<len(l.diagnostics) {
		diag_line := lint_offset_to_line(line_offsets, l.diagnostics[idx].start)
		if lint_diag_suppressed(suppressed_lines, suppressed_line_rules, diag_line, l.diagnostics[idx].lint_code) {
			continue
		}
		l.diagnostics[write_idx] = l.diagnostics[idx]
		write_idx += 1
	}
	resize(&l.diagnostics, write_idx)
}

lint_trim_spaces :: proc(s: string) -> string {
	start := 0
	for start < len(s) && (s[start] == ' ' || s[start] == '\t') { start += 1 }
	end := len(s)
	for end > start && (s[end-1] == ' ' || s[end-1] == '\t') { end -= 1 }
	return s[start:end]
}

lint_starts_with :: proc(s: string, prefix: string) -> bool {
	if len(s) < len(prefix) { return false }
	return s[:len(prefix)] == prefix
}

// ============================================================================
// JSON output formatter (Phase 8e)
//
// `kessel lint --format=json` emits an array of diagnostic objects matching
// the ESLint JSON format: [{"filePath","messages":[{"ruleId","severity",
// "message","line","column","endLine","endColumn"}]}].
// ============================================================================

lint_render_json :: proc(source: string, file_path: string, line_offsets: []u32, diagnostics: []ParseError) {
	fmt.eprintf("[{{\"filePath\":\"%s\",\"messages\":[\n", file_path)
	for diag, idx in diagnostics {
		line := lint_offset_to_line(line_offsets, diag.start)
		col := int(diag.start) - int(line_offsets[line]) + 1 if line < len(line_offsets) else 1
		end_line := lint_offset_to_line(line_offsets, diag.end)
		end_col := int(diag.end) - int(line_offsets[end_line]) + 1 if end_line < len(line_offsets) else 1
		sev := 1 if diag.severity == .Warning else 2
		rule_id := lint_rule_info(diag.lint_code).name if diag.lint_code != .None else ""
		fmt.eprintf(
			"{{\"ruleId\":\"%s\",\"severity\":%d,\"message\":\"%s\",\"line\":%d,\"column\":%d,\"endLine\":%d,\"endColumn\":%d}}",
			rule_id, sev, diag.message, line + 1, col, end_line + 1, end_col,
		)
		if idx < len(diagnostics) - 1 { fmt.eprintf(",\n") }
	}
	fmt.eprintf("\n]}}]\n")
}

// lint_render_unix emits one diagnostic per line in the classic ESLint `unix`
// formatter shape: `path:line:column: message [severity/rule]`. Grep-friendly
// and consumable by editor quickfix lists.
lint_render_unix :: proc(source: string, file_path: string, line_offsets: []u32, diagnostics: []ParseError) {
	for diag in diagnostics {
		line := lint_offset_to_line(line_offsets, diag.start)
		col := int(diag.start) - int(line_offsets[line]) + 1 if line < len(line_offsets) else 1
		rule_id := lint_rule_info(diag.lint_code).name if diag.lint_code != .None else ""
		sev := "warning" if diag.severity == .Warning else "error"
		fmt.eprintf("%s:%d:%d: %s [%s/%s]\n", file_path, line + 1, col, diag.message, sev, rule_id)
	}
}

// lint_render_github emits GitHub Actions workflow-command annotations so lint
// findings surface inline on pull requests:
// `::error file=path,line=L,col=C::message (rule)`.
lint_render_github :: proc(source: string, file_path: string, line_offsets: []u32, diagnostics: []ParseError) {
	for diag in diagnostics {
		line := lint_offset_to_line(line_offsets, diag.start)
		col := int(diag.start) - int(line_offsets[line]) + 1 if line < len(line_offsets) else 1
		rule_id := lint_rule_info(diag.lint_code).name if diag.lint_code != .None else ""
		level := "warning" if diag.severity == .Warning else "error"
		fmt.eprintf("::%s file=%s,line=%d,col=%d::%s (%s)\n", level, file_path, line + 1, col, diag.message, rule_id)
	}
}

// lint_render_compact emits the ESLint `compact` formatter shape:
// `path: line L, col C, Severity - message (rule)`. One line per diagnostic.
lint_render_compact :: proc(source: string, file_path: string, line_offsets: []u32, diagnostics: []ParseError) {
	for diag in diagnostics {
		line := lint_offset_to_line(line_offsets, diag.start)
		col := int(diag.start) - int(line_offsets[line]) + 1 if line < len(line_offsets) else 1
		rule_id := lint_rule_info(diag.lint_code).name if diag.lint_code != .None else ""
		sev := "Warning" if diag.severity == .Warning else "Error"
		fmt.eprintf("%s: line %d, col %d, %s - %s (%s)\n", file_path, line + 1, col, sev, diag.message, rule_id)
	}
}

// lint_render_checkstyle emits a Checkstyle-compatible XML document for one
// file, consumable by Jenkins/GitLab CI and other Checkstyle-aware tooling.
lint_render_checkstyle :: proc(source: string, file_path: string, line_offsets: []u32, diagnostics: []ParseError) {
	fmt.eprintf("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<checkstyle version=\"4.3\">\n")
	fmt.eprintf("<file name=\"%s\">\n", file_path)
	for diag in diagnostics {
		line := lint_offset_to_line(line_offsets, diag.start)
		col := int(diag.start) - int(line_offsets[line]) + 1 if line < len(line_offsets) else 1
		rule_id := lint_rule_info(diag.lint_code).name if diag.lint_code != .None else ""
		sev := "warning" if diag.severity == .Warning else "error"
		fmt.eprintf(
			"<error line=\"%d\" column=\"%d\" severity=\"%s\" message=\"%s\" source=\"%s\" />\n",
			line + 1, col, sev, diag.message, rule_id,
		)
	}
	fmt.eprintf("</file>\n</checkstyle>\n")
}

// lint_render_gitlab emits a GitLab Code Quality report (JSON array) consumable
// by GitLab CI's `codequality` artifact. Severity maps warning->minor,
// error->major; the fingerprint is an FNV-1a hash of path + rule + message +
// line so the same finding keeps a stable id across runs.
lint_render_gitlab :: proc(source: string, file_path: string, line_offsets: []u32, diagnostics: []ParseError) {
	fmt.eprintf("[")
	for diag, idx in diagnostics {
		line := lint_offset_to_line(line_offsets, diag.start)
		rule_id := lint_rule_info(diag.lint_code).name if diag.lint_code != .None else ""
		severity := "minor" if diag.severity == .Warning else "major"
		fp: u64 = 0xcbf29ce484222325
		parts := [3]string{file_path, rule_id, diag.message}
		for part in parts {
			for i in 0..<len(part) {
				fp ~= u64(part[i])
				fp *= 0x100000001b3
			}
		}
		fp ~= u64(line + 1)
		fp *= 0x100000001b3
		fmt.eprintf(
			"{{\"description\":\"%s\",\"check_name\":\"%s\",\"fingerprint\":\"%016x\",\"severity\":\"%s\",\"location\":{{\"path\":\"%s\",\"lines\":{{\"begin\":%d}}}}}}",
			diag.message, rule_id, fp, severity, file_path, line + 1,
		)
		if idx < len(diagnostics) - 1 { fmt.eprintf(",") }
	}
	fmt.eprintf("]\n")
}

// lint_render_junit emits a JUnit XML report: one <testcase> per diagnostic,
// each carrying a <failure>, wrapped in a single <testsuite> for the file.
lint_render_junit :: proc(source: string, file_path: string, line_offsets: []u32, diagnostics: []ParseError) {
	n := len(diagnostics)
	fmt.eprintf("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n")
	fmt.eprintf("<testsuites>\n")
	fmt.eprintf("<testsuite name=\"kessel\" package=\"%s\" tests=\"%d\" failures=\"%d\">\n", file_path, n, n)
	for diag in diagnostics {
		line := lint_offset_to_line(line_offsets, diag.start)
		col := int(diag.start) - int(line_offsets[line]) + 1 if line < len(line_offsets) else 1
		rule_id := lint_rule_info(diag.lint_code).name if diag.lint_code != .None else ""
		sev := "warning" if diag.severity == .Warning else "error"
		fmt.eprintf("  <testcase name=\"%s\" classname=\"%s\">\n", rule_id, file_path)
		fmt.eprintf(
			"    <failure message=\"%s\" type=\"%s\">line %d, col %d</failure>\n",
			diag.message, sev, line + 1, col,
		)
		fmt.eprintf("  </testcase>\n")
	}
	fmt.eprintf("</testsuite>\n</testsuites>\n")
}
