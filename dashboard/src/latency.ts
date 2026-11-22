export const MIN_PERCENTILE_SAMPLES = 20

export function computeLatencyStats(samplesMs: number[], timeoutCount: number) {
  const sorted = [...samplesMs].sort((a, b) => a - b)
  const sampleCount = sorted.length
  const percentile = (fraction: number) => sampleCount >= MIN_PERCENTILE_SAMPLES
    ? sorted[Math.ceil(fraction * sampleCount) - 1]
    : null

  return {
    sampleCount,
    timeoutCount,
    minMs: sorted[0] ?? null,
    maxMs: sorted[sampleCount - 1] ?? null,
    rawSamplesMs: [...samplesMs],
    p50Ms: percentile(0.5),
    p95Ms: percentile(0.95),
  }
}
