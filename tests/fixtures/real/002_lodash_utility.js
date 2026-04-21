// Lodash-style utility patterns
const result = _.chain(data)
  .filter(item => item.active)
  .map(item => ({ id: item.id, name: item.name }))
  .orderBy(['name'], ['asc'])
  .groupBy('category')
  .value();

const debounced = _.debounce(handleSearch, 300);
const throttled = _.throttle(handleScroll, 100);
