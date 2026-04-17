// Promise utility patterns (Bluebird/Native)
function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function retry(fn, attempts = 3, backoff = 1000) {
  for (let i = 0; i < attempts; i++) {
    try {
      return await fn();
    } catch (err) {
      if (i === attempts - 1) throw err;
      await delay(backoff * Math.pow(2, i));
    }
  }
}

Promise.allSettled([promise1, promise2]).then(results => {
  results.forEach(r => r.status === 'fulfilled' ? r.value : r.reason);
});
