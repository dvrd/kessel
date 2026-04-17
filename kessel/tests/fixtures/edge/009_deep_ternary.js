// Nested ternaries muy profundos
const result = a > 0
  ? b > 0
    ? c > 0
      ? d > 0
        ? e > 0
          ? 'all positive'
          : 'e negative'
        : 'd negative'
      : 'c negative'
    : 'b negative'
  : 'a negative';

const value = condition1
  ? (condition2
    ? (condition3 ? value3 : value2)
    : (condition4 ? value4 : value1))
  : defaultValue;
