// ECMA-262 §13.11.1 — WithStatement is a SyntaxError in strict mode.
// Allowed in sloppy script (TypeScript's bundled sources use it that way).
'use strict';
with (obj) {
	x;
}
