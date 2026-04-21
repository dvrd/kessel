// React hooks patterns
import { useState, useEffect, useCallback, useMemo } from 'react';

function useCounter(initialValue = 0) {
  const [count, setCount] = useState(initialValue);
  const increment = useCallback(() => setCount(c => c + 1), []);
  const doubled = useMemo(() => count * 2, [count]);
  return { count, increment, doubled };
}

function DataFetcher({ url }) {
  const [data, setData] = useState(null);
  useEffect(() => {
    fetch(url).then(r => r.json()).then(setData);
  }, [url]);
  return data;
}
