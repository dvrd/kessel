// no-new-native-nonconstructor (L2019): Symbol/BigInt are not constructors.
const s = new Symbol("x");
const n = new BigInt(9);
