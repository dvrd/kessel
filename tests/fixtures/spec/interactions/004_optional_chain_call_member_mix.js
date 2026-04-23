// Interaction: optional chaining across every chain-link kind the spec
// permits — `?.` into a property, `?.` into a computed member, `?.` into
// a call, and then non-optional `.` and `[...]` continuations once the
// chain is live. All in one expression so the parser can't split them.
//
// `??` (nullish coalescing) is deliberately right at the outside so the
// fallback expression exercises the operator-precedence boundary between
// the chain and the coalesce.
const out = obj?.a?.[0]?.fn?.(x).b?.['c']?.d ?? 'fallback';
const any = obj?.method?.() ?? null;
const deep = config?.['db']?.connection?.credentials?.username ?? 'guest';
