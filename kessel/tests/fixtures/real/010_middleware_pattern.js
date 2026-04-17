// Middleware pattern (Express/Koa style)
function compose(middlewares) {
  return function(ctx, next) {
    let index = -1;
    return dispatch(0);
    
    function dispatch(i) {
      if (i <= index) return Promise.reject(new Error('next() called multiple times'));
      index = i;
      let fn = middlewares[i];
      if (i === middlewares.length) fn = next;
      if (!fn) return Promise.resolve();
      return Promise.resolve(fn(ctx, dispatch.bind(null, i + 1)));
    }
  };
}

module.exports = compose;
