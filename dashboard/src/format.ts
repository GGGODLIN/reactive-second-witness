const integer = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 })

export function formatInteger(value: number | bigint): string {
  return integer.format(value)
}

export function formatMs(ms: number | null): string {
  return ms === null ? '—' : `${integer.format(ms)} ms`
}

export function formatSeconds(seconds: number): string {
  return `${integer.format(seconds)} s`
}

export function formatUnits(raw: bigint, decimals: number): string {
  const negative = raw < 0n
  const value = negative ? -raw : raw
  const scale = 10n ** BigInt(decimals)
  const fraction = (value % scale).toString().padStart(decimals, '0').replace(/0+$/, '')
  return `${negative ? '-' : ''}${integer.format(value / scale)}${fraction ? `.${fraction}` : ''}`
}

export function formatUsdE18(priceE18: bigint): string {
  const cents = priceE18 / 10n ** 16n
  return `$${integer.format(cents / 100n)}.${(cents % 100n).toString().padStart(2, '0')}`
}

export function shortHash(hash: string, head = 6, tail = 4): string {
  return hash.length <= head + tail + 3 ? hash : `${hash.slice(0, head + 2)}…${hash.slice(-tail)}`
}

// Log axis keeps a 1.6 s loop and a 14-minute feed age readable on one chart.
export function logPercent(ms: number, minMs: number, maxMs: number): number {
  const clamped = Math.min(Math.max(ms, minMs), maxMs)
  return ((Math.log10(clamped) - Math.log10(minMs)) / (Math.log10(maxMs) - Math.log10(minMs))) * 100
}

export function linearPercent(ms: number, maxMs: number): number {
  return Math.min(Math.max(ms / maxMs, 0), 1) * 100
}

export function timesLarger(value: number, reference: number): number {
  return Math.round(value / reference)
}
