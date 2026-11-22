import { cleanup, render, screen, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import App from '../App'
import { buildExplorerAddressUrl, buildExplorerTxUrl } from '../config/chains'
import { computeLatencyStats } from '../latency'
import { loadDashboardState } from '../state'
import type { ReceiptBundle } from '../data/types'

// Synthetic ABI responses are scoped to this test. The shipped bundle has no testnet hashes yet.
const bytes32 = (number: number) => `0x${number.toString(16).padStart(64, '0')}`
const address = (number: number) => `0x${number.toString(16).padStart(40, '0')}`
const deployed: ReceiptBundle = {
  deploymentStatus: 'DEPLOYED',
  contracts: {
    borrowGate: address(1), spotPool: address(2),
    referencePoolWitness: address(3), secondWitnessReactive: address(4),
  },
  scenarios: [
    { id: 'flash-loan', title: 'Flash-loan blocked', expected: 'HELD with zero disbursement', requestId: bytes32(10), transactions: { baseOrigin: bytes32(11), unichainReference: bytes32(12), lasnaVerdict: bytes32(13), baseOutcome: bytes32(14) } },
    { id: 'synchronized', title: 'Synchronized settle', expected: 'SETTLED', requestId: bytes32(20), transactions: { baseOrigin: bytes32(21), unichainReference: bytes32(22), lasnaVerdict: bytes32(23), baseOutcome: bytes32(24) } },
    { id: 'stale', title: 'Stale hold → auto-release', expected: 'HELD → SETTLED', requestId: bytes32(30), transactions: { baseOrigin: bytes32(31), unichainReference: bytes32(32), lasnaVerdict: bytes32(33), baseOutcome: bytes32(34) } },
    { id: 'cancel-expire', title: 'Local cancel / expire', expected: 'CANCELLED or EXPIRED', requestId: bytes32(40), transactions: { baseOrigin: bytes32(41), unichainReference: null, lasnaVerdict: null, baseOutcome: bytes32(44) } },
  ],
  latencyBenchmark: { samplesMs: [1800, 2010, 2180, 1900, 2040], timeoutCount: 2 },
  chainlinkBaseline: { date: '2026-11-23', feed: 'Base Sepolia ETH/USD', stalenessSeconds: 419, pollingBaselineMs: 7000 },
}

const base = 'https://sepolia.base.org'
const unichain = 'https://sepolia.unichain.org'
const lasna = 'https://lasna-rpc.rnk.dev/'
const abiWord = (number: number | bigint) => number.toString(16).padStart(64, '0')
const successResponses = new Map([
  [`${lasna}|0x8888888888888888888888888888888888888888|0x9b6c56ec${address(4).slice(2).padStart(64, '0')}`, abiWord(17)],
  [`${base}|0x476F44b11F5C942c58f4c8E3d0300E5710743585|0x9b6c56ec${address(1).slice(2).padStart(64, '0')}`, abiWord(0)],
  [`${lasna}|${address(4)}|0xc598c89d`, abiWord(2000n * 10n ** 18n)],
  [`${lasna}|${address(4)}|0xbfa8ea11`, abiWord(1760000000)],
  [`${lasna}|${address(4)}|0x8bc9ed1b`, abiWord(42)],
  [`${base}|${address(2)}|0x3a06703c`, abiWord(2200n * 10n ** 18n)],
  [`${unichain}|${address(3)}|0x3a06703c`, abiWord(1999n * 10n ** 18n)],
  ...[10, 20, 30, 40].map((id, i) => [
    `${base}|${address(1)}|0x05b90773${bytes32(id).slice(2)}`,
    [37, 100, 50, 9, 80, 6, 10, 20, 30, 2, [2, 3, 3, 5][i]].map(abiWord).join(''),
  ] as const),
])

const makeFetch = (override?: (id: number) => Response | Promise<Response>) => vi.fn<typeof fetch>(async (input, init) => {
  const { id, method, params } = JSON.parse(String(init?.body))
  if (String(input) === unichain && override) return override(id)
  const result = successResponses.get(`${input}|${params[0].to}|${params[0].data}`)
  if (method !== 'eth_call' || params[1] !== 'latest' || result === undefined) {
    return Response.json({ jsonrpc: '2.0', id, error: { code: -32602 } })
  }
  return Response.json({ jsonrpc: '2.0', id, result: `0x${result}` })
})

afterEach(cleanup)

describe('loadDashboardState', () => {
  it('keeps a pending bundle in replay without making an RPC request', async () => {
    const receipts: ReceiptBundle = {
      ...deployed,
      deploymentStatus: 'PENDING_LIVE_DEPLOYMENT',
      contracts: { borrowGate: null, spotPool: null, referencePoolWitness: null, secondWitnessReactive: null },
      scenarios: [{ ...deployed.scenarios[0], requestId: null, transactions: {
        baseOrigin: null, unichainReference: null, lasnaVerdict: null, baseOutcome: null,
      } }],
      latencyBenchmark: { samplesMs: [], timeoutCount: 0 },
    }
    const fetcher = makeFetch()
    expect(await loadDashboardState({ receipts, fetcher })).toMatchObject({
      mode: 'DETERMINISTIC_REPLAY',
      degradedReasons: ['Awaiting Ticket 05 live 3-testnet deployment receipts'],
      receipts: { scenarios: expect.arrayContaining([expect.objectContaining({ requestId: null })]) },
    })
    expect(fetcher).not.toHaveBeenCalled()
  })

  it('decodes three-chain data without losing uint256 precision', async () => {
    const fetcher = makeFetch()
    const state = await loadDashboardState({ receipts: deployed, fetcher })
    expect(state).toMatchObject({
      mode: 'LIVE',
      live: {
        lasnaDebt: 17n, baseDebt: 0n, latestPriceE18: 2000000000000000000000n,
        latestTradedAt: 1760000000n, latestTradeSeq: 42n,
        spotPriceE18: 2200000000000000000000n, referencePriceE18: 1999000000000000000000n,
        requests: { [bytes32(10)]: { borrower: address(37), lastRevision: 2n, status: 'HELD', disbursedAmount: 80n } },
      },
    })
    expect(fetcher).toHaveBeenCalledTimes(11)
  })

  const failures: [string, (id: number) => Response, string][] = [
    ['HTTP 503', () => new Response(null, { status: 503 }), 'HTTP 503'],
    ['HTTP 429', () => new Response(null, { status: 429 }), 'HTTP 429'],
    ['malformed JSON', () => new Response('{'), 'malformed JSON'],
    ['JSON-RPC error', (id) => Response.json({ jsonrpc: '2.0', id, error: { code: -32000 } }), 'JSON-RPC error -32000'],
    ['non-hex result', (id) => Response.json({ jsonrpc: '2.0', id, result: '0xNOTHEX' }), 'invalid ABI payload'],
    ['truncated hex result', (id) => Response.json({ jsonrpc: '2.0', id, result: '0x01' }), 'invalid ABI payload'],
  ]

  it.each(failures)('preserves receipts on %s and identifies the failed endpoint', async (_label, response, reason) => {
    expect(await loadDashboardState({ receipts: deployed, fetcher: makeFetch(response) })).toEqual({
      mode: 'DETERMINISTIC_REPLAY', receipts: deployed,
      degradedReasons: [expect.stringContaining(`Unichain Sepolia (${unichain}): ${reason}`)],
    })
  })

  it('degrades on timeout even if a fetch never settles', async () => {
    const fetcher = makeFetch(() => new Promise<Response>(() => {}))
    expect(await loadDashboardState({ receipts: deployed, fetcher, timeoutMs: 20 })).toMatchObject({
      mode: 'DETERMINISTIC_REPLAY',
      degradedReasons: [expect.stringMatching(/Unichain Sepolia.*timed out after 20 ms/)],
    })
  })
})

describe('latency evidence', () => {
  it('renders an empty sample set without invented values', () => {
    expect(computeLatencyStats([], 2)).toEqual({
      sampleCount: 0, timeoutCount: 2, minMs: null, maxMs: null, rawSamplesMs: [], p50Ms: null, p95Ms: null,
    })
  })

  it('preserves raw sample order and suppresses percentiles below 20 samples', () => {
    const samples = [900, 100, 500, 300, 700]
    expect(computeLatencyStats(samples, 1)).toEqual({
      sampleCount: 5, timeoutCount: 1, minMs: 100, maxMs: 900, rawSamplesMs: [900, 100, 500, 300, 700], p50Ms: null, p95Ms: null,
    })
    expect(samples).toEqual([900, 100, 500, 300, 700])
  })

  it('computes nearest-rank percentiles for 25 successes', () => {
    const samples = Array.from({ length: 25 }, (_, index) => (25 - index) * 100)
    expect(computeLatencyStats(samples, 3)).toMatchObject({
      sampleCount: 25, timeoutCount: 3, minMs: 100, maxMs: 2500, p50Ms: 1300, p95Ms: 2400,
    })
  })
})

it('builds absolute links only for full transaction hashes and addresses', () => {
  expect(buildExplorerTxUrl('base', bytes32(1))).toBe(`https://sepolia.basescan.org/tx/${bytes32(1)}`)
  expect(buildExplorerTxUrl('unichain', bytes32(2))).toBe(`https://sepolia.uniscan.xyz/tx/${bytes32(2)}`)
  expect(buildExplorerTxUrl('lasna', bytes32(3))).toBe(`https://lasna.reactscan.net/tx/${bytes32(3)}`)
  expect(buildExplorerAddressUrl('lasna', address(1))).toBe(`https://lasna.reactscan.net/address/${address(1)}`)
  expect(buildExplorerTxUrl('lasna', address(1))).toBeNull()
  expect(buildExplorerTxUrl('base', null)).toBeNull()
  expect(buildExplorerAddressUrl('base', '0xgarbage')).toBeNull()
})

describe('verification dashboard', () => {
  it('displays the live values and links every published hop under its requestId', async () => {
    render(<App receipts={deployed} fetcher={makeFetch()} />)
    expect((await screen.findByRole('status')).textContent).toContain('LIVE')
    expect(screen.getByText('42').previousElementSibling?.textContent).toBe('latestTradeSeq')
    expect(screen.getByText('HELD · revision 2')).toBeTruthy()
    for (const scenario of deployed.scenarios.slice(0, 3)) {
      const card = within(screen.getByRole('article', { name: scenario.title }))
      expect(card.getByText(scenario.requestId!)).toBeTruthy()
      expect(card.getByRole('link', { name: 'Base Origin' }).getAttribute('href')).toBe(`https://sepolia.basescan.org/tx/${scenario.transactions.baseOrigin}`)
      expect(card.getByRole('link', { name: 'Unichain Reference' }).getAttribute('href')).toBe(`https://sepolia.uniscan.xyz/tx/${scenario.transactions.unichainReference}`)
      expect(card.getByRole('link', { name: 'Lasna Verdict' }).getAttribute('href')).toBe(`https://lasna.reactscan.net/tx/${scenario.transactions.lasnaVerdict}`)
      expect(card.getByRole('link', { name: 'Base Outcome' }).getAttribute('href')).toBe(`https://sepolia.basescan.org/tx/${scenario.transactions.baseOutcome}`)
    }
    const local = within(screen.getByRole('article', { name: 'Local cancel / expire' }))
    expect(local.getByRole('link', { name: 'Base Outcome' }).getAttribute('href')).toContain(bytes32(44))
    expect(local.getAllByText('Not applicable')).toHaveLength(2)
    const table = within(screen.getByRole('table', { name: 'Latency comparison' }))
    expect(table.getByRole('row', { name: /Omni full loop.*5.*2.*1800.*2010/ })).toBeTruthy()
    expect(table.getByRole('row', { name: /7s polling.*7000 ms/ })).toBeTruthy()
    expect(table.getByRole('row', { name: /Chainlink.*2026-11-23.*419 s/ })).toBeTruthy()
    expect(screen.getByText(/p50\/p95 require N >= 20/)).toBeTruthy()
  })

  it('displays the failed endpoint and keeps receipt links when RPC times out', async () => {
    render(<App receipts={deployed} fetcher={makeFetch(() => new Promise<Response>(() => {}))} timeoutMs={20} />)
    expect((await screen.findByRole('status')).textContent).toBe('DETERMINISTIC_REPLAY')
    expect(screen.getByText(/Unichain Sepolia.*timed out after 20 ms/)).toBeTruthy()
    const card = within(screen.getByRole('article', { name: 'Flash-loan blocked' }))
    expect(card.getByRole('link', { name: 'Base Outcome' }).getAttribute('href')).toContain(bytes32(14))
    expect(screen.getByText('Live contract values unavailable.')).toBeTruthy()
  })
})
