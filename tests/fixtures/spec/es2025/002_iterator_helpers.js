const arr = [1, 2, 3, 4, 5];
const iter = arr.values();
const mapped = iter.map(x => x * 2);
const filtered = arr.values().filter(x => x > 2);
const taken = arr.values().take(3);
