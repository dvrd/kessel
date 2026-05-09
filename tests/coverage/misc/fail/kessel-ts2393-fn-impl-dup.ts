// TS2393 — two `function foo()` declarations with bodies in the same
// scope (top-level here, but the check also fires inside Block /
// FunctionBody / TSModuleBlock bodies). Each impl is flagged. Distinct
// from TS2391/TS2389 which fire on overload-signature chain mismatches.
function foo() { return 1; }
function foo() { return 2; }
