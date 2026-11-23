import type { ReceiptBundle } from '../data/types'
import { formatInteger, formatMs, formatSeconds, linearPercent, logPercent, timesLarger } from '../format'
import { computeLatencyStats } from '../latency'

type LatencyStats = ReturnType<typeof computeLatencyStats>

const LOG_MIN_MS = 100
const LOG_MAX_MS = 1_000_000
const logTicks = [
  { ms: 100, label: '0.1 s' },
  { ms: 1_000, label: '1 s' },
  { ms: 10_000, label: '10 s' },
  { ms: 100_000, label: '100 s' },
  { ms: 1_000_000, label: '1,000 s' },
]

const logWidth = (ms: number) => `${logPercent(ms, LOG_MIN_MS, LOG_MAX_MS).toFixed(2)}%`

function withStableKeys(samplesMs: number[]) {
  const seen = new Map<number, number>()
  return samplesMs.map((ms) => {
    const occurrence = (seen.get(ms) ?? 0) + 1
    seen.set(ms, occurrence)
    return { ms, key: `${ms}#${occurrence}` }
  })
}

interface LoopBarProps {
  label: string
  detail: string
  stats: LatencyStats
  tone: 'omni' | 'polling'
}

function LoopBar({ label, detail, stats, tone }: LoopBarProps) {
  const { p50Ms, p95Ms } = stats
  return (
    <li className={`bar-row ${tone}`}>
      <div className="bar-label"><strong>{label}</strong><span>{detail}</span></div>
      <div className="bar-track" aria-hidden="true">
        {p95Ms !== null && <span className="bar bar-p95" style={{ width: logWidth(p95Ms) }} />}
        {p50Ms !== null && <span className="bar bar-p50" style={{ width: logWidth(p50Ms) }} />}
      </div>
      <div className="bar-value">
        {p50Ms === null ? 'Percentiles need 20+ samples' : <>{formatMs(p50Ms)} <small>p50</small> · {formatMs(p95Ms)} <small>p95</small></>}
      </div>
    </li>
  )
}

interface StripProps {
  label: string
  stats: LatencyStats
  maxMs: number
  tone: 'omni' | 'polling'
}

function Strip({ label, stats, maxMs, tone }: StripProps) {
  const { sampleCount, timeoutCount, minMs, maxMs: slowestMs, p50Ms, p95Ms, rawSamplesMs } = stats
  const range = minMs === null ? 'no samples yet' : `${formatInteger(minMs)}–${formatMs(slowestMs)}`
  return (
    <li className={`strip-row ${tone}`}>
      <div className="strip-label">
        <strong>{label}</strong>
        <span>{`N = ${sampleCount} · ${range}${timeoutCount > 0 ? ` · ${timeoutCount} timeouts not plotted` : ''}`}</span>
      </div>
      <div className="strip-track" aria-hidden="true">
        {withStableKeys(rawSamplesMs).map(({ ms, key }, order) => (
          <span key={key} className="dot" style={{ left: `${linearPercent(ms, maxMs).toFixed(2)}%`, top: `${8 + (order % 4) * 6}px` }} />
        ))}
        {p50Ms !== null && <span className="marker" style={{ left: `${linearPercent(p50Ms, maxMs).toFixed(2)}%` }}><span>p50</span></span>}
        {p95Ms !== null && <span className="marker" style={{ left: `${linearPercent(p95Ms, maxMs).toFixed(2)}%` }}><span>p95</span></span>}
      </div>
    </li>
  )
}

export function LatencyCharts({ latencyBenchmark, chainlinkBaseline }: Pick<ReceiptBundle, 'latencyBenchmark' | 'chainlinkBaseline'>) {
  const omni = computeLatencyStats(latencyBenchmark.samplesMs, latencyBenchmark.timeoutCount)
  const polling = computeLatencyStats(latencyBenchmark.polling?.samplesMs ?? [], latencyBenchmark.polling?.timeoutCount ?? 0)
  const { stalenessSeconds, date } = chainlinkBaseline
  const feedAgeMs = stalenessSeconds * 1000
  const stripMaxMs = Math.max(1000, Math.ceil(Math.max(0, ...omni.rawSamplesMs, ...polling.rawSamplesMs) / 1000) * 1000)
  const stripTicks = Array.from({ length: stripMaxMs / 1000 + 1 }, (_, second) => second)

  return (
    <div className="charts">
      <figure className="card chart">
        <figcaption>
          <strong>Time to a usable price decision</strong>
          <span>Log scale · loop latency vs oracle feed age</span>
        </figcaption>
        <ul className="bars">
          <LoopBar label="Second Witness" detail="Reactive Omni full loop" stats={omni} tone="omni" />
          <LoopBar label="7 s polling bot" detail="same start and end points" stats={polling} tone="polling" />
          <li className="bar-row feed">
            <div className="bar-label"><strong>Chainlink ETH/USD</strong><span>{`feed age, 1 sample · ${date}`}</span></div>
            <div className="bar-track" aria-hidden="true"><span className="bar bar-feed" style={{ width: logWidth(feedAgeMs) }} /></div>
            <div className="bar-value">
              {formatSeconds(stalenessSeconds)} <small>old</small>
              {omni.p50Ms !== null && <> · ≈{timesLarger(feedAgeMs, omni.p50Ms)}× <small>the Omni p50</small></>}
            </div>
          </li>
        </ul>
        <div className="axis log-axis" aria-hidden="true">
          {logTicks.map(({ ms, label }) => <span key={ms} style={{ left: logWidth(ms) }}>{label}</span>)}
        </div>
        <p className="chart-note">Feed age is how long ago the on-chain price was last updated. It is a different measurement from loop latency and is shown for scale.</p>
      </figure>

      <figure className="card chart">
        <figcaption>
          <strong>Every successful sample</strong>
          <span>{`Linear scale · 0–${stripMaxMs / 1000} s`}</span>
        </figcaption>
        <ul className="strips">
          <Strip label="Second Witness" stats={omni} maxMs={stripMaxMs} tone="omni" />
          <Strip label="7 s polling bot" stats={polling} maxMs={stripMaxMs} tone="polling" />
        </ul>
        <div className="axis linear-axis" aria-hidden="true">
          {stripTicks.map((second) => <span key={second} style={{ left: `${linearPercent(second * 1000, stripMaxMs).toFixed(2)}%` }}>{`${second} s`}</span>)}
        </div>
      </figure>
    </div>
  )
}
