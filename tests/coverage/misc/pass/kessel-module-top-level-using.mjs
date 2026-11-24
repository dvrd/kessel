// Explicit resource management at the top level of a module. A `using` declaration is a
// SyntaxError at the top level of a Script (misc/fail/script-top-level-using.cjs) and is
// allowed in a Module, a Block (misc/pass/script-using-in-block.js) and a function body.
using resource = open();
await using stream = connect();
export {};
