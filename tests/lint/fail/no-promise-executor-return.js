// no-promise-executor-return: return value from executor is ignored
const p = new Promise((resolve, reject) => {
  return 1;
});
