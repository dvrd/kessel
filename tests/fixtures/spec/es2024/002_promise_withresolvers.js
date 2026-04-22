const { promise, resolve, reject } = Promise.withResolvers();
setTimeout(() => resolve("done"), 100);
const result = await promise;
