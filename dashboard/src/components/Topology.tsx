import { chains } from '../config/chains'
import type { Chain } from '../config/chains'
import { riskParameters } from '../data/showcase'
import { formatMs } from '../format'

interface TopologyProps {
  p50Ms: number | null
  p95Ms: number | null
  sampleCount: number
}

interface Hop {
  step: string
  chain: Chain
  contract: string
  call: string
  detail: string
}

const { ltvPercent, smallBorrowLimitUsdc, maxEvidenceAgeSeconds, requiredFreshTrades } = riskParameters

const hops: Hop[] = [
  {
    step: '01', chain: 'base', contract: 'BorrowGate', call: 'requestBorrow()',
    detail: `A borrow above ${smallBorrowLimitUsdc} mUSDC reserves collateral and emits BorrowRequested. No funds move yet.`,
  },
  {
    step: '02', chain: 'unichain', contract: 'ReferencePoolWitness', call: 'swap() → ReferenceTrade',
    detail: 'Each trade on an independent pool publishes price, timestamp and sequence. A Base flash loan cannot reach it.',
  },
  {
    step: '03', chain: 'lasna', contract: 'SecondWitnessReactive', call: 'react() → requestCallbackV_1_0',
    detail: 'Keeps the latest witness and up to 4 held requests, then sends the evidence back to Base.',
  },
  {
    step: '04', chain: 'base', contract: 'BorrowGate', call: 'onWitnessVerdict()',
    detail: `Base alone decides: a witness at most ${maxEvidenceAgeSeconds} s old pays up to min(spot, witness) at ${ltvPercent}% LTV. Otherwise it holds until ${requiredFreshTrades} fresh trades arrive.`,
  },
]

const lanes: { chain: Chain; y: number; role: string }[] = [
  { chain: 'unichain', y: 12, role: 'reference market' },
  { chain: 'lasna', y: 92, role: 'witness relay' },
  { chain: 'base', y: 172, role: 'lending ledger' },
]

const chips: { step: number; chain: Chain; x: number; y: number; label: string }[] = [
  { step: 1, chain: 'base', x: 238, y: 190, label: 'requestBorrow()' },
  { step: 2, chain: 'unichain', x: 468, y: 30, label: 'swap()' },
  { step: 3, chain: 'lasna', x: 698, y: 110, label: 'react()' },
  { step: 4, chain: 'base', x: 948, y: 190, label: 'onWitnessVerdict()' },
]

const flows: { d: string; label: string; x: number; y: number }[] = [
  { d: 'M422 208 H790 V150', label: 'BorrowRequested', x: 436, y: 200 },
  { d: 'M560 66 V128 H694', label: 'ReferenceTrade', x: 572, y: 120 },
  { d: 'M882 128 H1040 V186', label: 'requestCallbackV_1_0', x: 894, y: 120 },
]

function Schematic({ p50Ms, p95Ms, sampleCount }: TopologyProps) {
  return (
    <svg className="schematic" viewBox="0 0 1200 292" aria-hidden="true" focusable="false">
      <defs>
        <marker id="sw-arrow" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
          <path className="arrow-head" d="M0 0 L10 5 L0 10 z" />
        </marker>
      </defs>
      {lanes.map(({ chain, y, role }) => (
        <g key={chain} className={`lane lane-${chain}`}>
          <rect className="lane-bg" x="0" y={y} width="1200" height="72" rx="4" />
          <rect className="lane-edge" x="0" y={y} width="3" height="72" />
          <text className="lane-name" x="18" y={y + 32}>{chains[chain].name}</text>
          <text className="lane-meta" x="18" y={y + 52}>{`${chains[chain].id} · ${role}`}</text>
        </g>
      ))}
      {flows.map(({ d, label, x, y }) => (
        <g key={label}>
          <path className="flow" d={d} markerEnd="url(#sw-arrow)" />
          <text className="flow-label" x={x} y={y}>{label}</text>
        </g>
      ))}
      {chips.map(({ step, chain, x, y, label }) => (
        <g key={step} className={`chip chip-${chain}`}>
          <rect className="chip-bg" x={x} y={y} width="184" height="36" rx="4" />
          <circle className="chip-dot" cx={x + 18} cy={y + 18} r="10" />
          <text className="chip-step" x={x + 18} y={y + 22}>{step}</text>
          <text className="chip-label" x={x + 36} y={y + 23}>{label}</text>
        </g>
      ))}
      <path className="bracket" d="M238 248 V256 H1132 V248" />
      <text className="bracket-label" x="685" y="282">
        {`Base request mined → Base outcome observed · p50 ${formatMs(p50Ms)} · p95 ${formatMs(p95Ms)} · N = ${sampleCount}`}
      </text>
    </svg>
  )
}

export function Topology(props: TopologyProps) {
  return (
    <section aria-labelledby="topology-heading">
      <div className="section-heading">
        <h2 id="topology-heading">Three chains, one verdict</h2>
        <p className="section-kicker">4 hops · one Reactive Omni loop</p>
      </div>
      <p className="section-note">
        A large borrow never trusts a price that can move inside its own transaction. The witness comes from a pool on
        another chain, Reactive Lasna relays it, and Base alone pays or holds.
      </p>
      <div className="card topology">
        <Schematic {...props} />
        <ol className="hop-list">
          {hops.map(({ step, chain, contract, call, detail }) => (
            <li key={step} className={`hop-item hop-${chain}`}>
              <span className="hop-step">{step}</span>
              <span className="chain-chip">{chains[chain].name}</span>
              <strong>{contract}</strong>
              <code>{call}</code>
              <p>{detail}</p>
            </li>
          ))}
        </ol>
      </div>
    </section>
  )
}
