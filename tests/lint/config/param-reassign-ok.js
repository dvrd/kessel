function mutate(param) {
  param.value = 1;
  function nested() {
    let param = 0;
    param++;
    return param;
  }
  return nested();
}

function named(param) {
  const fn = function param() {
    // eslint-disable-next-line no-func-assign -- This assignment targets the function's own name.
    param = 1;
  };
  return fn;
}
