const items = [
  { type: "fruit", name: "apple" },
  { type: "veggie", name: "carrot" },
  { type: "fruit", name: "banana" },
];
const grouped = Object.groupBy(items, item => item.type);
