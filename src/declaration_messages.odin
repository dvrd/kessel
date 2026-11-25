package kessel

import "core:reflect"

// Diagnostics with a fixed text, named by their TypeScript code. The wording is
// TypeScript's, so tools that match on it treat both compilers alike.
DeclarationCode :: enum {
	TS9007, TS9008, TS9009, TS9010, TS9011, TS9012, TS9013, TS9014,
	TS9015, TS9016, TS9017, TS9018, TS9019, TS9020, TS9021, TS9022,
	TS9023, TS9025, TS9037, TS9038,
}

@(private, rodata)
dts_messages := [DeclarationCode]string{
	.TS9007 = "Function must have an explicit return type annotation with " +
		"--isolatedDeclarations.",
	.TS9008 = "Method must have an explicit return type annotation with " +
		"--isolatedDeclarations.",
	.TS9009 = "At least one accessor must have an explicit type annotation with " +
		"--isolatedDeclarations.",
	.TS9010 = "Variable must have an explicit type annotation with --isolatedDeclarations.",
	.TS9011 = "Parameter must have an explicit type annotation with --isolatedDeclarations.",
	.TS9012 = "Property must have an explicit type annotation with --isolatedDeclarations.",
	.TS9013 = "Expression type can't be inferred with --isolatedDeclarations.",
	.TS9014 = "Computed properties must be number or string literals, variables or dotted " +
		"expressions with --isolatedDeclarations.",
	.TS9015 = "Objects that contain spread assignments can't be inferred with " +
		"--isolatedDeclarations.",
	.TS9016 = "Objects that contain shorthand properties can't be inferred with " +
		"--isolatedDeclarations.",
	.TS9017 = "Only const arrays can be inferred with --isolatedDeclarations.",
	.TS9018 = "Arrays with spread elements can't inferred with --isolatedDeclarations.",
	.TS9019 = "Binding elements can't be exported directly with --isolatedDeclarations.",
	.TS9020 = "Enum member initializers must be computable without references to external " +
		"symbols with --isolatedDeclarations.",
	.TS9021 = "Extends clause can't contain an expression with --isolatedDeclarations.",
	.TS9022 = "Inference from class expressions is not supported with --isolatedDeclarations.",
	.TS9023 = "Assigning properties to functions without declaring them is not supported with" +
		" --isolatedDeclarations. Add an explicit declaration for the properties " +
		"assigned to this function.",
	.TS9025 = "Declaration emit for this parameter requires implicitly adding undefined to " +
		"its type. This is not supported with --isolatedDeclarations.",
	.TS9037 = "Default exports can't be inferred with --isolatedDeclarations.",
	.TS9038 = "Computed property names on class or object literals cannot be inferred with " +
		"--isolatedDeclarations.",
}

@(private)
dts_diagnose :: proc(state: ^DeclarationEmit, code: DeclarationCode, loc: Loc) {
	name, known := reflect.enum_name_from_value(code)
	assert(known)
	assert(loc.start <= loc.end)
	dts_error(state, name, dts_messages[code], loc)
}
