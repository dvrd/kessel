// no-self-assign (L2012) + no-async-promise-executor (L2013).
let count = 0;
count = count;
const p = new Promise(async (resolve) => {
  resolve(await work());
});
