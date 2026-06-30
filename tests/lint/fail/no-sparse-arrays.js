// no-sparse-arrays (L1002): array literal with a hole.
// Expected: kessel lint reports the diagnostic and exits 1.
const items = [1, , 3];
console.log(items);
