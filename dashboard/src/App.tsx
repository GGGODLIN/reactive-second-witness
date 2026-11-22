import { useEffect, useState } from 'react'
import { buildExplorerAddressUrl, buildExplorerTxUrl, chains, isBytes32 } from './config/chains'
import type { Chain } from './config/chains'
import type { ReceiptBundle, ReceiptHop, ScenarioReceipt } from './data/types'
import { computeLatencyStats, MIN_PERCENTILE_SAMPLES } from './latency'
import { bundledReceipts, loadDashboardState } from './state'
import type { DashboardOptions, DashboardState } from './state'

const hops: { key: ReceiptHop; label: string; chain: Chain }[] = [
  { key: 'baseOrigin', label: 'Base Origin', chain: 'base' },
  { key: 'unichainReference', label: 'Unichain Reference', chain: 'unichain' },
  { key: 'lasnaVerdict', label: 'Lasna Verdict', chain: 'lasna' },
  { key: 'baseOutcome', label: 'Base Outcome', chain: 'base' },
]

const contracts: { key: keyof ReceiptBundle['contracts']; label: string; chain: Chain }[] = [
  { key: 'borrowGate', label: 'BorrowGate', chain: 'base' },
  { key: 'spotPool', label: 'SpotPool', chain: 'base' },
  { key: 'referencePoolWitness', label: 'ReferencePoolWitness', chain: 'unichain' },
  { key: 'secondWitnessReactive', label: 'SecondWitnessReactive', chain: 'lasna' },
]

type RequestSnapshot = Extract<DashboardState, { mode: 'LIVE' }>['live']['requests'][string]

function RequestCard({ scenario, request, pending }: { scenario: ScenarioReceipt; request?: RequestSnapshot; pending: boolean }) {
  const { id, title, expected, requestId, transactions } = scenario
  const headingId = `scenario-${id}`
  return (
    <article className="card trace-card" aria-labelledby={headingId}>
      <h3 id={headingId}>{title}</h3>
      <p>{expected}</p>
      <dl className="request-id">
        <dt>requestId</dt>
        <dd><code>{isBytes32(requestId) ? requestId : pending ? 'Pending Ticket 05' : 'Unavailable'}</code></dd>
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
            <li key={key}>
              {url ? (
                <>
                  <a href={url} target="_blank" rel="noreferrer">{label}<span aria-hidden="true"> ↗</span></a>
                  <code>{hash}</code>
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

function LatencyTable({ latencyBenchmark, chainlinkBaseline, deploymentStatus }: ReceiptBundle) {
  const { samplesMs, timeoutCount, polling } = latencyBenchmark
  const omni = computeLatencyStats(samplesMs, timeoutCount)
  const pollingStats = computeLatencyStats(polling?.samplesMs ?? [], polling?.timeoutCount ?? 0)
  const { date, feed, stalenessSeconds, pollingBaselineMs } = chainlinkBaseline
  const pending = deploymentStatus === 'PENDING_LIVE_DEPLOYMENT'
  return (
    <section aria-labelledby="latency-heading">
      <h2 id="latency-heading">Latency evidence</h2>
      <p className="section-note">Both loop methods use the same start and end points: submission of the Base borrow request and observation of the Base outcome receipt. The Chainlink sample measures feed age separately.</p>
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
  const pending = evidence.deploymentStatus === 'PENDING_LIVE_DEPLOYMENT'
  const live = state?.mode === 'LIVE' ? state.live : undefined
  const readings = live ? [
    ['Lasna SYSTEM debt (wei)', live.lasnaDebt],
    ['Base CallbackProxy debt (wei)', live.baseDebt],
    ['latestPriceE18', live.latestPriceE18],
    ['latestTradedAt (Unix s)', live.latestTradedAt],
    ['latestTradeSeq', live.latestTradeSeq],
    ['Base SpotPool priceE18', live.spotPriceE18],
    ['Unichain ReferencePoolWitness priceE18', live.referencePriceE18],
  ] as const : []

  return (
    <main>
      <header className="hero">
        <p className="eyebrow">PUBLIC TESTNET EVIDENCE</p>
        <h1>Second Witness</h1>
        <p className="intro">Verify that large Base borrows use an independent Unichain price witness via Reactive Lasna. Follow the receipts without connecting a wallet.</p>
        <div className="network-list">
          {Object.values(chains).map(({ id, name, explorer }) => <a key={id} href={explorer}>{name} <code>{id}</code></a>)}
        </div>
      </header>

      <section aria-labelledby="status-heading">
        <div className="section-heading">
          <h2 id="status-heading">Contract status</h2>
          {state ? <span className={`badge ${live ? 'live' : 'replay'}`} role="status">{state.mode}</span> : <span className="badge checking">Checking evidence…</span>}
        </div>
        <div className="card status-card">
          <ul className="contract-list" aria-label="Deployment addresses">
            {contracts.map(({ key, label, chain }) => {
              const url = buildExplorerAddressUrl(chain, evidence.contracts[key])
              return <li key={key}>{url ? <a href={url}>{label}</a> : <span>{label} · pending</span>}</li>
            })}
          </ul>
          {live && <dl className="readings">{readings.map(([label, value]) => (
            <div key={label}><dt>{label}</dt><dd>{value.toString()}</dd></div>
          ))}</dl>}
          {state?.mode === 'DETERMINISTIC_REPLAY' && (
            <>
              <p><strong>Live contract values unavailable.</strong> {pending ? 'Scenario descriptions below are expected behavior.' : 'Bundled receipts remain available below.'}</p>
              <ul className="reasons">{state.degradedReasons.map((reason) => <li key={reason}>{reason}</li>)}</ul>
            </>
          )}
        </div>
      </section>

      <section aria-labelledby="trace-heading">
        <h2 id="trace-heading">Request traces</h2>
        <p className="section-note">Match the request ID on Base and Lasna. Use the verdict's reference transaction hash and log index to find the exact Unichain trade.</p>
        <div className="traces">
          {evidence.scenarios.map((scenario) => (
            <RequestCard
              key={scenario.requestId ?? scenario.id}
              scenario={scenario}
              request={scenario.requestId ? live?.requests[scenario.requestId] : undefined}
              pending={pending}
            />
          ))}
        </div>
      </section>

      <LatencyTable {...evidence} />
    </main>
  )
}
