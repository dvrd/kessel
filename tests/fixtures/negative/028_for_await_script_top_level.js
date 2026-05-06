// for-await at top level in script mode is a SyntaxError.
for await (const x of [1, 2]) {}
