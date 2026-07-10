// no-useless-catch (L2016): the catch only rethrows the caught error.
function run(task) {
  try {
    task();
  } catch (e) {
    throw e;
  }
}
