import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import App from '../App'
import type { ReceiptBundle } from '../data/types'
import { flashLoanEvidence } from '../data/showcase'
import { formatMs, formatUnits, formatUsdE18, logPercent, shortHash, timesLarger } from '../format'
import { computeLatencyStats } from '../latency'
import { bundledReceipts } from '../state'

const offline = () => vi.fn<typeof fetch>(async () => { throw new Error('offline') })
const flashLoan = bundledReceipts.scenarios.find(({ id }) => id === 'flash-loan')!

function stubClipboard(writeText: (text: string) => Promise<void>) {
  Object.defineProperty(navigator, 'clipboard', { value: { writeText }, configurable: true })
}

afterEach(() => {
  cleanup()
  Reflect.deleteProperty(navigator, 'clipboard')
})

async function renderReplay(receipts: ReceiptBundle = bundledReceipts) {
  render(<App receipts={receipts} fetcher={offline()} timeoutMs={50} />)
  expect((await screen.findByRole('status')).textContent).toBe('DETERMINISTIC_REPLAY')
}

describe('format helpers', () => {
  it('formats on-chain integers without floating-point loss', () => {
    expect(formatUnits(8_000_000_000n, 6)).toBe('8,000')
    expect(formatUnits(80n, 6)).toBe('0.00008')
    expect(formatUsdE18(2_009_962_219_655_456_990_110n)).toBe('$2,009.96')
    expect(formatMs(1618)).toBe('1,618 ms')
    expect(formatMs(null)).toBe('—')
    expect(shortHash(flashLoanEvidence.drainTx)).toBe('0xe3be04…8821')
  })

  it('places log-axis values at decade fractions and clamps outliers', () => {
    expect(logPercent(1_000, 100, 1_000_000)).toBeCloseTo(25, 6)
    expect(logPercent(10, 100, 1_000_000)).toBe(0)
    expect(logPercent(10_000_000, 100, 1_000_000)).toBe(100)
  })

  it('derives the published Chainlink multiple from the bundled receipts', () => {
    const { samplesMs, timeoutCount } = bundledReceipts.latencyBenchmark
    const { p50Ms } = computeLatencyStats(samplesMs, timeoutCount)
    expect(p50Ms).toBe(1618)
    expect(timesLarger(bundledReceipts.chainlinkBaseline.stalenessSeconds * 1000, p50Ms!)).toBe(531)
  })
})

describe('evidence console', () => {
  it('keeps the bundled KPIs, duel and feed-age comparison visible when every RPC is offline', async () => {
    await renderReplay()
    const kpis = within(screen.getByLabelText('Key evidence'))
    for (const value of ['1,618 ms', '2,785 ms', '3,686 ms', '859 s']) expect(kpis.getByText(value)).toBeTruthy()

    const duel = within(screen.getByRole('region', { name: 'Same pump, two lenders' }))
    expect(duel.getByText('$8,000')).toBeTruthy()
    expect(duel.getByText('$0')).toBeTruthy()
    expect(duel.getByRole('link', { name: 'Drain transaction' }).getAttribute('href'))
      .toBe(`https://sepolia.basescan.org/tx/${flashLoanEvidence.drainTx}`)
    expect(duel.getByRole('link', { name: 'Outcome transaction' }).getAttribute('href'))
      .toBe(`https://sepolia.basescan.org/tx/${flashLoan.transactions.baseOutcome}`)

    expect(screen.getByText(/≈531×/).textContent).toContain('859 s')
    expect(screen.getByText(/different measurement from loop latency/)).toBeTruthy()
  })

  it('lists the four hops in the order Base, Unichain, Lasna, Base', async () => {
    await renderReplay()
    const topology = within(screen.getByRole('region', { name: 'Three chains, one verdict' }))
    const hops = topology.getAllByRole('listitem').map((item) => item.textContent)
    expect(hops).toHaveLength(4)
    ;['Base Sepolia', 'Unichain Sepolia', 'Reactive Lasna', 'Base Sepolia'].forEach((chain, index) => {
      expect(hops[index]).toContain(chain)
    })
  })

  it('copies the full requestId and announces success', async () => {
    const writeText = vi.fn<(text: string) => Promise<void>>().mockResolvedValue(undefined)
    stubClipboard(writeText)
    await renderReplay()
    fireEvent.click(screen.getByRole('button', { name: 'Copy requestId for Flash-loan blocked' }))
    await waitFor(() => expect(writeText).toHaveBeenCalledWith(flashLoan.requestId))
    expect(await screen.findByText('Copied to clipboard')).toBeTruthy()
  })

  it('reports a refused clipboard instead of claiming the copy worked', async () => {
    stubClipboard(vi.fn<(text: string) => Promise<void>>().mockRejectedValue(new Error('denied')))
    await renderReplay()
    fireEvent.click(screen.getByRole('button', { name: 'Copy requestId for Flash-loan blocked' }))
    expect(await screen.findByText('Copy failed', { selector: 'button' })).toBeTruthy()
    expect(screen.queryByText('Copied to clipboard')).toBeNull()
  })

  it('says the hero panel is showing bundled receipts when live reads fail', async () => {
    await renderReplay()
    const panel = within(screen.getByRole('complementary', { name: 'Live witness' }))
    expect(panel.getByText(/A live read failed/)).toBeTruthy()
  })

  it('shows live chain values in the hero panel and the duel once every read succeeds', async () => {
    const word = (value: bigint) => value.toString(16).padStart(64, '0')
    const liveValues: Record<string, bigint> = {
      '0x9b6c56ec': 0n,
      '0xbfa8ea11': 1_795_401_288n,
      '0x8bc9ed1b': 11n,
    }
    const fetcher = vi.fn<typeof fetch>(async (_input, init) => {
      const { id, params } = JSON.parse(String(init?.body))
      const data: string = params[0].data
      const selector = data.slice(0, 10)
      const result = selector === '0x05b90773'
        ? [37n, 8_000_000_000n, 8_000_000_000n, 9n, 0n, 0n, 0n, 20n, 30n, 3n, 2n].map(word).join('')
        : word(liveValues[selector] ?? 2_009_960_000_000_000_000_000n)
      return Response.json({ jsonrpc: '2.0', id, result: `0x${result}` })
    })
    render(<App fetcher={fetcher} />)
    expect((await screen.findByRole('status')).textContent).toBe('LIVE')
    const panel = within(screen.getByRole('complementary', { name: 'Live witness' }))
    expect(panel.getByText('$2,009.96 · trade #11')).toBeTruthy()
    expect(panel.getByText('0 / 0 wei')).toBeTruthy()
    expect(panel.getByText('02:34:48 UTC')).toBeTruthy()
    const duel = within(screen.getByRole('region', { name: 'Same pump, two lenders' }))
    expect(duel.getByText('Live read: HELD, 0 of 8,000 mUSDC paid')).toBeTruthy()
  })

  it('draws no percentile bars below 20 samples', async () => {
    const sparse: ReceiptBundle = {
      ...bundledReceipts,
      latencyBenchmark: { samplesMs: [1800, 2010, 2180], timeoutCount: 1 },
    }
    await renderReplay(sparse)
    expect(screen.getAllByText('Percentiles need 20+ samples')).toHaveLength(2)
    expect(within(screen.getByLabelText('Key evidence')).getAllByText('—').length).toBeGreaterThanOrEqual(3)
  })
})
