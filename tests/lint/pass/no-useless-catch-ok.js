// no-useless-catch (L2016) passing: the catch does real work (logs, wraps, or
// rethrows a different value), so it is not useless. An optional catch binding
// with a bare rethrow of a *different* name is also fine.
function run(task) {
  try {
    task();
  } catch (e) {
    console.error(e);
    throw new Error("wrapped: " + e.message);
  }
}
function guard(task) {
  try {
    task();
  } catch (e) {
    if (e.fatal) throw e;
  }
}
