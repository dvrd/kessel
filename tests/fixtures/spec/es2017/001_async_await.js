async function fetchData(url) {
  const response = await fetch(url);
  const data = await response.json();
  return data;
}
const fn = async () => {
  try {
    await fetchData("/api");
  } catch (e) {
    console.error(e);
  }
};
