// Template literal types keep their escapes: a cooked tab or CR LF is other text.
type T1 = `a\tb\r\n${string}\u0041\\`;
type T2 = `plain ${number} tail`;
