// Replacement for upstream-renamed Test262 fixture. Exercises the same
// syntactic surface as the original; treated as a positive parse test.

var a = 1;
a += 1;
a -= 1;
a *= 2;
a /= 2;
a %= 3;
a <<= 1;
a >>= 1;
a >>>= 1;
a &= 0xFF;
a |= 0x10;
a ^= 0x0F;
a **= 2;
a &&= 1;
a ||= 1;
a ??= 1;
