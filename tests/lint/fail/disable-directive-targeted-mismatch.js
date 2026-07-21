// Targeted disable directive naming a DIFFERENT rule (no-console) must not
// suppress the no-debugger diagnostic — it still fires (exit 1). This proves
// disable directives discriminate by rule name rather than blanket-suppressing.
// eslint-disable-next-line no-console
debugger;
