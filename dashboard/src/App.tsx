import { useEffect, useState } from 'react'
import { CopyButton } from './components/CopyButton'
import { FlashLoanDuel } from './components/FlashLoanDuel'
import { KpiStrip } from './components/KpiStrip'
import { LatencyCharts } from './components/LatencyCharts'
import { LiveWitnessPanel } from './components/LiveWitnessPanel'
import { Topology } from './components/Topology'
import { buildExplorerAddressUrl, buildExplorerTxUrl, chains, isBytes32 } from './config/chains'
import type { Chain } from './config/chains'
import type { ReceiptBundle, ReceiptHop, ScenarioReceipt } from './data/types'
import { flashLoanEvidence, scenarioOutcomes, synchronizedLoopMs } from './data/showcase'
import { formatMs, formatUsdE18, shortHash } from './format'
import { computeLatencyStats, MIN_PERCENTILE_SAMPLES } from './latency'
import { bundledReceipts, loadDashboardState } from './state'
import type { DashboardOptions, DashboardState } from './state'

const hops: { key: ReceiptHop; label: string; chain: Chain }[] = [
  { key: 'baseOrigin', label: 'Base Origin', chain: 'base' },
  { key: 'unichainReference', label: 'Unichain Reference', chain: 'unichain' },
  { key: 'lasnaVerdict', label: 'Lasna Verdict', chain: 'lasna' },
  { key: 'baseOutcome', label: 'Base Outcome', chain: 'base' },
]

const contracts: { label: string; chain: Chain; address: (bundle: ReceiptBundle) => string | null }[] = [
  { label: 'BorrowGate', chain: 'base', address: (bundle) => bundle.contracts.borrowGate },
  { label: 'SpotPool', chain: 'base', address: (bundle) => bundle.contracts.spotPool },
  { label: 'UnprotectedLendingMock', chain: 'base', address: () => flashLoanEvidence.lenderAddress },
  { label: 'ReferencePoolWitness', chain: 'unichain', address: (bundle) => bundle.contracts.referencePoolWitness },
  { label: 'SecondWitnessReactive', chain: 'lasna', address: (bundle) => bundle.contracts.secondWitnessReactive },
]

type LiveValues = Extract<DashboardState, { mode: 'LIVE' }>['live']
type RequestSnapshot = LiveValues['requests'][string]

function outcomeLabel(id: string): { label: string; tone: string } | undefined {
  const outcome = scenarioOutcomes[id]
  if (!outcome) return undefined
  return id === 'synchronized' ? { ...outcome, label: `SETTLED in ${formatMs(synchronizedLoopMs)}` } : outcome
}

interface RequestCardProps {
  scenario: ScenarioReceipt
  request?: RequestSnapshot
  pending: boolean
  order: number
}

function RequestCard({ scenario, request, pending, order }: RequestCardProps) {
  const { id, title, expected, requestId, transactions } = scenario
  const headingId = `scenario-${id}`
  const outcome = outcomeLabel(id)
  return (
    <article className="card trace-card" aria-labelledby={headingId}>
      <div className="trace-head">
        <span className="trace-index" aria-hidden="true">{String(order).padStart(2, '0')}</span>
        <h3 id={headingId}>{title}</h3>
        {outcome && <span className={`outcome ${outcome.tone}`}>{outcome.label}</span>}
      </div>
      <p>{expected}</p>
      <dl className="request-id">
        <dt>requestId</dt>
        <dd className="id-row">
          <code>{isBytes32(requestId) ? requestId : pending ? 'Pending Ticket 05' : 'Unavailable'}</code>
          {isBytes32(requestId) && <CopyButton value={requestId} label={`Copy requestId for ${title}`} />}
        </dd>
      </dl>
      {request && (
        <dl className="request-id">
          <dt>requestState</dt>
          <dd><strong>{request.status} · revision {request.lastRevision.toString()}</strong></dd>
          <dt>Disbursed / requested (raw mUSDC)</dt>
          <dd><code>{request.disbursedAmount.toString()} / {request.requestedAmount.toString()}</code></dd>
        </dl>
      )}
      <ol className="hops">
        {hops.map(({ key, label, chain }) => {
          const hash = transactions[key]
          const url = buildExplorerTxUrl(chain, hash)
          const localOnly = id === 'cancel-expire' && (key === 'unichainReference' || key === 'lasnaVerdict')
          return (
            <li key={key} className={`hop chain-${chain}`}>
              <span className="hop-chain">{chains[chain].name}</span>
              {url ? (
                <>
                  <a href={url} target="_blank" rel="noreferrer" title={`${title}: ${label} transaction on ${chains[chain].name}`}>
                    {label}<span aria-hidden="true"> ↗</span>
                  </a>
                  <code title={hash ?? undefined}>{shortHash(hash ?? '')}</code>
                </>
              ) : (
                <><strong>{label}</strong><span>{localOnly ? 'Not applicable' : pending ? 'Pending' : 'Receipt unavailable'}</span></>
              )}
            </li>
          )
        })}
      </ol>
    </article>
  )
}

function LatencyRow({ label, stats, pending }: { label: string; stats: ReturnType<typeof computeLatencyStats>; pending: boolean }) {
  const { sampleCount, timeoutCount, rawSamplesMs, minMs, maxMs, p50Ms, p95Ms } = stats
  return (
    <tr>
      <th scope="row">{label}</th>
      <td>{sampleCount}</td>
      <td>{pending ? 'Pending' : timeoutCount}</td>
      <td className="samples">{rawSamplesMs.length > 0 ? rawSamplesMs.join(', ') : 'Pending measurements'}</td>
      <td>{minMs === null ? '—' : `${minMs}–${maxMs}`}</td>
      <td>{p50Ms ?? '—'}</td>
      <td>{p95Ms ?? '—'}</td>
    </tr>
  )
}

function LatencySection({ latencyBenchmark, chainlinkBaseline, deploymentStatus }: ReceiptBundle) {
  const { samplesMs, timeoutCount, polling } = latencyBenchmark
  const omni = computeLatencyStats(samplesMs, timeoutCount)
  const pollingStats = computeLatencyStats(polling?.samplesMs ?? [], polling?.timeoutCount ?? 0)
  const { date, feed, stalenessSeconds, pollingBaselineMs } = chainlinkBaseline
  const pending = deploymentStatus === 'PENDING_LIVE_DEPLOYMENT'
  return (
    <section aria-labelledby="latency-heading">
      <div className="section-heading">
        <h2 id="latency-heading">Latency evidence</h2>
        <p className="section-kicker">{`${omni.sampleCount} loops · ${timeoutCount} timeouts`}</p>
      </div>
      <p className="section-note">Both loop methods use the same start and end points: submission of the Base borrow request and observation of the Base outcome receipt. The Chainlink sample measures feed age separately.</p>
      <LatencyCharts latencyBenchmark={latencyBenchmark} chainlinkBaseline={chainlinkBaseline} />
      <div className="card table-wrap" tabIndex={0} role="region" aria-label="Scrollable latency table">
        <table>
          <caption className="sr-only">Latency comparison</caption>
          <thead><tr>
            <th scope="col">Method</th><th scope="col">N</th><th scope="col">Timeouts / failures</th>
            <th scope="col">Raw observations</th><th scope="col">Range (ms)</th><th scope="col">p50 (ms)</th><th scope="col">p95 (ms)</th>
          </tr></thead>
          <tbody>
            <LatencyRow label="Omni full loop (ms)" stats={omni} pending={pending} />
            <LatencyRow label={`7s polling (${pollingBaselineMs} ms interval)`} stats={pollingStats} pending={pending || !polling} />
            <tr>
              <th scope="row">Chainlink · {feed} · <time dateTime={date}>{date}</time></th>
              <td>1</td><td>—</td><td>{stalenessSeconds} s feed age</td><td colSpan={3}>—</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p className="section-note">{`Per loop method, p50/p95 require N >= ${MIN_PERCENTILE_SAMPLES} successful samples (nearest rank). Timeouts and failures are counted separately.`}</p>
    </section>
  )
}

function readingHint(label: string, value: bigint): string | undefined {
  if (label.endsWith('debt (wei)')) return value === 0n ? 'settled · no unpaid callbacks' : 'unpaid callback fees outstanding'
  if (label.toLowerCase().includes('pricee18')) return formatUsdE18(value)
  if (label.startsWith('latestTradedAt')) return `${new Date(Number(value) * 1000).toISOString().replace('T', ' ').slice(0, 19)} UTC`
  return undefined
}

function BrandMark() {
  return (
    <svg className="brand-mark" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <circle cx="9" cy="12" r="6.5" />
      <circle cx="15" cy="12" r="6.5" />
    </svg>
  )
}

const modeNotes = {
  checking: 'Reading Base, Unichain and Lasna RPCs…',
  LIVE: 'Every contract read succeeded at page load',
  DETERMINISTIC_REPLAY: 'A live read failed · showing bundled receipts',
} as const

function TopBar({ state }: { state?: DashboardState }) {
  return (
    <header className="topbar">
      <div className="shell topbar-inner">
        <a className="brand" href="#top"><BrandMark />Second Witness</a>
        <nav className="network-list" aria-label="Block explorers">
          {Object.entries(chains).map(([key, { id, name, explorer }]) => (
            <a key={id} className={`chain-${key}`} href={explorer}>{name} <code>{id}</code></a>
          ))}
        </nav>
        <div className="mode">
          {state
            ? <span className={`badge ${state.mode === 'LIVE' ? 'live' : 'replay'}`} role="status">{state.mode}</span>
            : <span className="badge checking">Checking evidence…</span>}
          <span className="mode-note">{modeNotes[state?.mode ?? 'checking']}</span>
        </div>
      </div>
    </header>
  )
}

interface EvidenceSectionProps {
  evidence: ReceiptBundle
  live?: LiveValues
}

function TraceSection({ evidence, live }: EvidenceSectionProps) {
  const pending = evidence.deploymentStatus === 'PENDING_LIVE_DEPLOYMENT'
  return (
    <section aria-labelledby="trace-heading">
      <div className="section-heading">
        <h2 id="trace-heading">Request traces</h2>
        <p className="section-kicker">4 hops per requestId</p>
      </div>
      <p className="section-note">Match the request ID on Base and Lasna. Use the verdict&apos;s reference transaction hash and log index to find the exact Unichain trade.</p>
      <div className="traces">
        {evidence.scenarios.map((scenario, index) => (
          <RequestCard
            key={scenario.requestId ?? scenario.id}
            scenario={scenario}
            request={scenario.requestId ? live?.requests[scenario.requestId] : undefined}
            pending={pending}
            order={index + 1}
          />
        ))}
      </div>
    </section>
  )
}

function liveReadings(live: LiveValues) {
  return [
    ['Lasna SYSTEM debt (wei)', live.lasnaDebt],
    ['Base CallbackProxy debt (wei)', live.baseDebt],
    ['latestPriceE18', live.latestPriceE18],
    ['latestTradedAt (Unix s)', live.latestTradedAt],
    ['latestTradeSeq', live.latestTradeSeq],
    ['Base SpotPool priceE18', live.spotPriceE18],
    ['Unichain ReferencePoolWitness priceE18', live.referencePriceE18],
  ] as const
}

function ContractStatus({ evidence, live, degradedReasons }: EvidenceSectionProps & { degradedReasons?: string[] }) {
  const pending = evidence.deploymentStatus === 'PENDING_LIVE_DEPLOYMENT'
  return (
    <section aria-labelledby="status-heading">
      <div className="section-heading">
        <h2 id="status-heading">Contract status</h2>
        <p className="section-kicker">{live ? 'read live at page load' : 'bundled receipts'}</p>
      </div>
      <div className="card status-card">
        <ul className="contract-list" aria-label="Deployment addresses">
          {contracts.map(({ label, chain, address }) => {
            const value = address(evidence)
            const url = buildExplorerAddressUrl(chain, value)
            return (
              <li key={label} className={`chain-${chain}`}>
                <span className="hop-chain">{chains[chain].name}</span>
                {url ? <a href={url}>{label}</a> : <span>{label} · pending</span>}
                {value && <code>{shortHash(value)}</code>}
              </li>
            )
          })}
        </ul>
        {live && <dl className="readings">{liveReadings(live).map(([label, value]) => {
          const hint = readingHint(label, value)
          return (
            <div key={label}><dt>{label}</dt><dd>{value.toString()}</dd>{hint && <dd className="hint">{hint}</dd>}</div>
          )
        })}</dl>}
        {degradedReasons && (
          <>
            <p><strong>Live contract values unavailable.</strong> {pending ? 'Scenario descriptions below are expected behavior.' : 'Bundled receipts remain available below.'}</p>
            <ul className="reasons">{degradedReasons.map((reason) => <li key={reason}>{reason}</li>)}</ul>
          </>
        )}
      </div>
    </section>
  )
}

export default function App({ receipts = bundledReceipts, fetcher, timeoutMs }: DashboardOptions = {}) {
  const [state, setState] = useState<DashboardState>()
  useEffect(() => {
    let current = true
    void loadDashboardState({ receipts, fetcher, timeoutMs }).then((result) => {
      if (current) setState(result)
    })
    return () => { current = false }
  }, [receipts, fetcher, timeoutMs])

  const evidence = state?.receipts ?? receipts
  const live = state?.mode === 'LIVE' ? state.live : undefined
  const omni = computeLatencyStats(evidence.latencyBenchmark.samplesMs, evidence.latencyBenchmark.timeoutCount)
  const flashLoan = evidence.scenarios.find(({ id }) => id === 'flash-loan')
  const flashLoanLive = flashLoan?.requestId ? live?.requests[flashLoan.requestId] : undefined

  return (
    <>
      <TopBar state={state} />

      <main id="top" className="shell">
        <section className="hero" aria-labelledby="hero-heading">
          <div className="hero-grid">
            <div>
              <p className="eyebrow">Public testnet evidence · Reactive Omni · Every Second Counts</p>
              <h1 id="hero-heading">Second Witness</h1>
              <p className="claim">A flash loan can move Base&apos;s price. <em>It can&apos;t move Unichain&apos;s.</em></p>
              <p className="intro">
                On Base Sepolia&apos;s 200 ms blocks, a lender that values collateral at its own spot price can be drained
                by a single transaction. Second Witness makes every large borrow wait one Reactive Omni loop
                ({formatMs(omni.p50Ms)} p50) for an independent Unichain price before any money moves. Every number
                below links to a public testnet receipt. No wallet needed.
              </p>
            </div>
            <LiveWitnessPanel mode={state?.mode} live={live} />
          </div>
          <KpiStrip receipts={evidence} debts={live && { lasna: live.lasnaDebt, base: live.baseDebt }} />
        </section>

        {flashLoan && <FlashLoanDuel scenario={flashLoan} live={flashLoanLive} />}

        <Topology p50Ms={omni.p50Ms} p95Ms={omni.p95Ms} sampleCount={omni.sampleCount} />

        <LatencySection {...evidence} />

        <TraceSection evidence={evidence} live={live} />

        <ContractStatus
          evidence={evidence}
          live={live}
          degradedReasons={state?.mode === 'DETERMINISTIC_REPLAY' ? state.degradedReasons : undefined}
        />
      </main>

      <footer className="footer">
        <div className="shell footer-inner">
          <p>Second Witness · MIT licensed · Reactive Omni Buildathon, Every Second Counts track</p>
          <a href="https://github.com/GGGODLIN/reactive-second-witness">Source and README on GitHub<span aria-hidden="true"> ↗</span></a>
        </div>
      </footer>
    </>
  )
}
