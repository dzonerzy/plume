/** The smallest step performance.now() takes here (engines coarsen it). */
const resolution = (() => {
  const start = performance.now();
  let now = start;
  while (now === start) now = performance.now();
  return now - start;
})();

/** A measured duration for people: "4 µs", "1.2 ms", "1.5 s", or "under
 * 100 µs" when it was shorter than the clock can tell. */
export function duration(ms: number): string {
  if (ms <= 0) return `under ${format(resolution)}`;
  return format(ms);
}

function format(ms: number): string {
  if (ms < 1) return `${Math.max(1, Math.round(ms * 1000))} µs`;
  if (ms < 1000) return `${ms < 10 ? ms.toFixed(1).replace(/\.0$/, "") : ms.toFixed(0)} ms`;
  return `${(ms / 1000).toFixed(1)} s`;
}

/** How many steps the worker-thread demo counts. */
export const steps = 12;
