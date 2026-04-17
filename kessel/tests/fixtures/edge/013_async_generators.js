// Async generators
async function* fetchPages(url) {
  let nextUrl = url;
  while (nextUrl) {
    const response = await fetch(nextUrl);
    const data = await response.json();
    yield data.results;
    nextUrl = data.next;
  }
}

async function* streamLines(file) {
  const reader = file.stream().getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    yield value;
  }
}

for await (const chunk of fetchPages('/api/data')) {
  process(chunk);
}
