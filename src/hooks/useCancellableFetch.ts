import { useEffect, useRef, useState } from "react";

/// Fetches on mount and whenever `dep` changes, ignoring the result if the
/// component unmounts or `dep` changes again before it resolves. Errors are
/// swallowed — for optional/enhancement data where the natural fallback is
/// to stay in the `initial` (usually empty) state.
export function useCancellableFetch<T>(
  fetcher: () => Promise<T>,
  initial: T,
  dep: unknown,
): T {
  const [value, setValue] = useState<T>(initial);
  const fetcherRef = useRef(fetcher);

  useEffect(() => {
    fetcherRef.current = fetcher;
  });

  useEffect(() => {
    let cancelled = false;
    fetcherRef
      .current()
      .then((v) => {
        if (!cancelled) setValue(v);
      })
      .catch(() => {
        // caller's initial/empty state covers this
      });
    return () => {
      cancelled = true;
    };
  }, [dep]);

  return value;
}
