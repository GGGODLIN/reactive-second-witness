import { buildExplorerAddressUrl, buildExplorerTxUrl } from '../config/chains'
import type { ScenarioReceipt } from '../data/types'
import { flashLoanEvidence, MUSDC_DECIMALS, riskParameters } from '../data/showcase'
import { formatUnits, shortHash } from '../format'

export interface LiveRequestSummary {
  status: string
  disbursedAmount: bigint
  requestedAmount: bigint
}

interface FlashLoanDuelProps {
  scenario: ScenarioReceipt
  live?: LiveRequestSummary
}

const usd = (raw: bigint) => `$${formatUnits(raw, MUSDC_DECIMALS)}`

export function FlashLoanDuel({ scenario, live }: FlashLoanDuelProps) {
  const drainUrl = buildExplorerTxUrl('base', flashLoanEvidence.drainTx)
  const lenderUrl = buildExplorerAddressUrl('base', flashLoanEvidence.lenderAddress)
  const outcomeHash = scenario.transactions.baseOutcome
  const outcomeUrl = buildExplorerTxUrl('base', outcomeHash)
  const paid = flashLoanEvidence.gatePaidRaw

  return (
    <section aria-labelledby="duel-heading">
      <div className="section-heading">
        <h2 id="duel-heading">Same pump, two lenders</h2>
        <p className="section-kicker">Base Sepolia · live testnet receipts</p>
      </div>
      <p className="section-note">
        A real 5× swap pushed the Base SpotPool price up, then each lender received a large borrow. Both value collateral
        at {riskParameters.ltvPercent}% LTV; only one asks a second chain first.
      </p>
      <div className="duel">
        <div className="card duel-card drained">
          <p className="verdict"><span aria-hidden="true">✕</span> Drained</p>
          <h3>UnprotectedLendingMock</h3>
          <p className="duel-rule">Prices collateral from the Base spot pool alone.</p>
          <p className="duel-amount">{usd(flashLoanEvidence.drainedRaw)}</p>
          <p className="duel-caption">paid out in a single borrow transaction</p>
          <ul className="duel-links">
            {drainUrl && <li><a href={drainUrl} target="_blank" rel="noreferrer">Drain transaction<span aria-hidden="true"> ↗</span></a><code>{shortHash(flashLoanEvidence.drainTx)}</code></li>}
            {lenderUrl && <li><a href={lenderUrl} target="_blank" rel="noreferrer">Lender contract<span aria-hidden="true"> ↗</span></a><code>{shortHash(flashLoanEvidence.lenderAddress)}</code></li>}
          </ul>
        </div>
        <div className="card duel-card blocked">
          <p className="verdict"><span aria-hidden="true">✓</span> Blocked</p>
          <h3>BorrowGate + Second Witness</h3>
          <p className="duel-rule">Prices collateral at min(Base spot, Unichain witness).</p>
          <p className="duel-amount">{usd(paid)}</p>
          <p className="duel-caption">paid · request held with REASON_BELOW_MIN_ACCEPTABLE</p>
          <ul className="duel-links">
            {outcomeUrl && outcomeHash && <li><a href={outcomeUrl} target="_blank" rel="noreferrer">Outcome transaction<span aria-hidden="true"> ↗</span></a><code>{shortHash(outcomeHash)}</code></li>}
            {live && <li className="live-read"><span className="live-dot" aria-hidden="true" />{`Live read: ${live.status}, ${formatUnits(live.disbursedAmount, MUSDC_DECIMALS)} of ${formatUnits(live.requestedAmount, MUSDC_DECIMALS)} mUSDC paid`}</li>}
          </ul>
        </div>
      </div>
    </section>
  )
}
