// Lock-in: `import a = M; var a;` is accepted (no diagnostic). TSC
// fires TS2440 here, but OXC's checker accepts it (per the babel
// `typescript/scope/redeclaration-import-equals-var` positive fixture).
// Mirroring OXC keeps that babel positive fixture clean. The decl-
// merge legality table only flags import vs import collisions, not
// import vs var/let/const/function/class.
namespace M { export var x = 1; }
import a = M;
var a: number;
