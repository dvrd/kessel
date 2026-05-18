// Duplicate-import detection. The decl-merge table treats two
// declarations of the same import binding (Import / ImportEquals /
// ImportType in any combination) as a conflict. Mirrors OXC, which
// closes the babel `typescript/scope/redeclaration-import-type-import`
// negative fixture and the TSC `importAndVariableDeclarationConflict3`
// (two `import x = m.m`) family.
namespace m { export var m = ''; }
import x = m.m;
import x = m.m;
