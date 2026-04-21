// Top-level await (module context)
const data = await fetch('/api/data');
const json = await data.json();
export { json };
