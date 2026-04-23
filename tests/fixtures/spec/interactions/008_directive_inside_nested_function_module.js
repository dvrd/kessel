// Interaction: directive-prologue strings at multiple nesting levels.
// Each function body starts a fresh Directive Prologue region, so
// `"use strict"` at the top, inside `outer`, and inside `inner` must each
// be recognised as a Directive (ExpressionStatement with a string literal
// in the prologue slot), not as a plain expression statement further down.
"use strict";
function outer() {
  "use strict";
  function inner() {
    "use strict";
    return arguments.length;
  }
  return inner();
}
