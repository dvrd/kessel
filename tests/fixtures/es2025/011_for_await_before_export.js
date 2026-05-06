// for-await at top level is valid when export appears later (module).
for await (const x of [1, 2]) {}
export {}
