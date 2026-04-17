// Arrow function devolviendo object literal
const createPerson = (name, age) => ({ name, age });
const withId = data => ({ ...data, id: Math.random() });

const items = ['a', 'b'].map((x, i) => ({
  key: x,
  index: i,
  timestamp: Date.now()
}));

const fn = x => ({ a: 1 });
const fn2 = x => ({ a: 1, b: 2 });
const fn3 = () => ({
  method: () => ({ nested: true })
});
