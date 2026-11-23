import type { ReactNode } from 'react'
import type { ReceiptBundle } from '../data/types'
import { flashLoanEvidence, MUSDC_DECIMALS } from '../data/showcase'
import { formatMs, formatSeconds, formatUnits } from '../format'
import { computeLatencyStats } from '../latency'

interface KpiStripProps {
  receipts: ReceiptBundle
  debts?: { lasna: bigint; base: bigint }
}

interface Kpi {
  key: string
  value: ReactNode
  label: string
  tone: 'versus' | 'accent' | 'muted' | 'danger' | 'ok'
}

export function KpiStrip({ receipts, debts }: KpiStripProps) {
  const { latencyBenchmark, chainlinkBaseline } = receipts
  const omni = computeLatencyStats(latencyBenchmark.samplesMs, latencyBenchmark.timeoutCount)
  const polling = computeLatencyStats(latencyBenchmark.polling?.samplesMs ?? [], latencyBenchmark.polling?.timeoutCount ?? 0)
  const usd = (raw: bigint) => `$${formatUnits(raw, MUSDC_DECIMALS)}`

  const kpis: Kpi[] = [
    { key: 'duel', value: <><span className="neg">{usd(flashLoanEvidence.drainedRaw)}</span> → <span className="pos">{usd(flashLoanEvidence.gatePaidRaw)}</span></>, label: 'paid out after the same 5× pump: naive lender → BorrowGate', tone: 'versus' },
    { key: 'p50', value: formatMs(omni.p50Ms), label: `Omni loop p50 · N = ${omni.sampleCount}`, tone: 'accent' },
    { key: 'p95', value: formatMs(omni.p95Ms), label: 'Omni loop p95', tone: 'accent' },
    { key: 'polling', value: formatMs(polling.p50Ms), label: '7 s polling p50 · same endpoints', tone: 'muted' },
    { key: 'feed', value: formatSeconds(chainlinkBaseline.stalenessSeconds), label: `Chainlink ETH/USD feed age · ${chainlinkBaseline.date}`, tone: 'danger' },
    debts
      ? { key: 'debt', value: `${debts.lasna} · ${debts.base}`, label: 'callback debt in wei, Lasna · Base (live)', tone: 'ok' }
      : { key: 'debt', value: '—', label: 'callback debt, read live at page load', tone: 'muted' },
  ]

  return (
    <dl className="kpis" aria-label="Key evidence">
      {kpis.map(({ key, value, label, tone }) => (
        <div key={key} className={`kpi ${tone}`}>
          <dt>{label}</dt>
          <dd>{value}</dd>
        </div>
      ))}
    </dl>
  )
}
