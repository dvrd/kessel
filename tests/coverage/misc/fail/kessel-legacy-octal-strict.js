// A LegacyOctalIntegerLiteral is a SyntaxError in strict mode code (§12.9.3.1);
// only its value in sloppy code changed, the rejection must stay.
"use strict";
var eight = 010;
