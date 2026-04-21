// Complex operator precedence
const a = 1 + 2 * 3 ** 2;
const b = (1 + 2) * 3;
const c = ~15 << 2 >>> 1;
const d = 5 & 3 | 8 ^ 2;
const e = true && false || true;
const f = 1 === 1 && 2 !== 3;
const g = null ?? undefined ?? 'default';
const h = obj?.prop?.nested?.value;
const i = arr?.[0]?.method?.();

// Compound assignments
let x = 1;
x += 2;
x -= 1;
x *= 3;
x **= 2;
x &= 0xFF;
x |= 0x10;
x ^= 0x01;
