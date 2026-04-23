// Interaction: `for await` iteration over an async iterable where the
// loop variable is a destructuring pattern that includes default values
// and a rest element. Three features stacked: for-await, destructuring
// with defaults, and rest in object pattern.
async function consume(iter) {
  for await (const { value, done = false, ...rest } of iter) {
    if (done) break;
    report(value, rest);
  }
}
