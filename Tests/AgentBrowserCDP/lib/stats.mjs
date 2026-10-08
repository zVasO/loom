// Percentiles for latency.test.mjs: nearest rank on the sorted samples, so a
// p90 of 20 samples is the 18th — a measured value, never an interpolation.
const round = (value) => Math.round(value * 100) / 100;

export function percentile(values, p) {
  const sorted = values.filter(Number.isFinite).sort((a, b) => a - b);
  if (!sorted.length) return NaN;
  const rank = Math.max(1, Math.ceil((p / 100) * sorted.length));
  return sorted[rank - 1];
}

export function median(values) {
  const sorted = values.filter(Number.isFinite).sort((a, b) => a - b);
  if (!sorted.length) return NaN;
  const middle = sorted.length >> 1;
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

export const p90 = (values) => percentile(values, 90);

export function summary(values) {
  const finite = values.filter(Number.isFinite);
  return {
    n: finite.length,
    p50: round(median(finite)),
    p90: round(p90(finite)),
    min: round(Math.min(...finite)),
    max: round(Math.max(...finite)),
  };
}
