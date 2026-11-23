import type { DashboardState } from '../state'
import { formatUsdE18 } from '../format'

type LiveValues = Extract<DashboardState, { mode: 'LIVE' }>['live']

interface LiveWitnessPanelProps {
  mode?: DashboardState['mode']
  live?: LiveValues
}

const utcTime = (unixSeconds: bigint) => `${new Date(Number(unixSeconds) * 1000).toISOString().slice(11, 19)} UTC`

export function LiveWitnessPanel({ mode, live }: LiveWitnessPanelProps) {
  if (!live) {
    return (
      <aside className="witness-panel idle" aria-label="Live witness">
        <p className="panel-title">Live witness</p>
        <p className="panel-empty">
          {mode === 'DETERMINISTIC_REPLAY'
            ? 'A live read failed, so this page is showing its bundled testnet receipts. Every one still links to a public explorer.'
            : 'Reading Base Sepolia, Unichain Sepolia and Reactive Lasna…'}
        </p>
      </aside>
    )
  }

  const rows = [
    { label: 'Unichain reference price', value: formatUsdE18(live.referencePriceE18) },
    { label: 'Lasna witness', value: `${formatUsdE18(live.latestPriceE18)} · trade #${live.latestTradeSeq}` },
    { label: 'Witness traded at', value: utcTime(live.latestTradedAt) },
    { label: 'Base spot price', value: formatUsdE18(live.spotPriceE18) },
    { label: 'Callback debt, Lasna / Base', value: `${live.lasnaDebt} / ${live.baseDebt} wei` },
  ]

  return (
    <aside className="witness-panel" aria-label="Live witness">
      <p className="panel-title"><span className="live-dot" aria-hidden="true" />Live witness · read at page load</p>
      <dl>
        {rows.map(({ label, value }) => (
          <div key={label}><dt>{label}</dt><dd>{value}</dd></div>
        ))}
      </dl>
    </aside>
  )
}
