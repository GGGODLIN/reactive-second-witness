import { BASE_CALLBACK_PROXY, chains, isAddress, isBytes32, LASNA_SYSTEM } from './config/chains'
import type { Chain } from './config/chains'
import type { ReceiptBundle } from './data/types'
import verifiedReceipts from './data/verified-receipts.json'

// Widen only the JSON discriminant, then let ReceiptBundle check the rest of the schema.
const deploymentStatus = verifiedReceipts.deploymentStatus
if (deploymentStatus !== 'PENDING_LIVE_DEPLOYMENT' && deploymentStatus !== 'DEPLOYED') {
  throw new Error('Invalid receipt deployment status')
}
export const bundledReceipts: ReceiptBundle = { ...verifiedReceipts, deploymentStatus }

export type DashboardOptions = { receipts?: ReceiptBundle; fetcher?: typeof fetch; timeoutMs?: number }

const statusNames = ['NONE', 'PENDING', 'HELD', 'SETTLED', 'CANCELLED', 'EXPIRED'] as const

interface RequestState {
  borrower: string
  requestedAmount: bigint
  minAcceptableAmount: bigint
  reservedCollateral: bigint
  disbursedAmount: bigint
  keptCollateral: bigint
  lastEffectivePrice: bigint
  createdAt: bigint
  deadline: bigint
  lastRevision: bigint
  status: typeof statusNames[number]
}

interface LiveValues {
  lasnaDebt: bigint
  baseDebt: bigint
  latestPriceE18: bigint
  latestTradedAt: bigint
  latestTradeSeq: bigint
  spotPriceE18: bigint
  referencePriceE18: bigint
  requests: Record<string, RequestState>
}

export type DashboardState =
  | { mode: 'LIVE'; receipts: ReceiptBundle; live: LiveValues }
  | { mode: 'DETERMINISTIC_REPLAY'; receipts: ReceiptBundle; degradedReasons: string[] }

function decodeRequest(words: string[]): RequestState {
  const [borrower, ...values] = words
  const [requestedAmount, minAcceptableAmount, reservedCollateral, disbursedAmount,
    keptCollateral, lastEffectivePrice, createdAt, deadline, lastRevision, statusValue] =
    values.map((word) => BigInt(`0x${word}`))
  const status = statusNames[Number(statusValue)]
  if (!/^0{24}/.test(borrower) || !status || createdAt >= 2n ** 64n || deadline >= 2n ** 64n || lastRevision >= 2n ** 32n) {
    throw new Error('invalid requestState ABI fields')
  }
  return {
    borrower: `0x${borrower.slice(24)}`, requestedAmount, minAcceptableAmount, reservedCollateral,
    disbursedAmount, keptCollateral, lastEffectivePrice, createdAt, deadline, lastRevision, status,
  }
}

// Verify selectors against Solidity with `forge inspect <Contract> methodIdentifiers` or `cast sig`.
const selectors = {
  debt: '0x9b6c56ec',
  latestPriceE18: '0xc598c89d',
  latestTradedAt: '0xbfa8ea11',
  latestTradeSeq: '0x8bc9ed1b',
  priceE18: '0x3a06703c',
  requestState: '0x05b90773',
}

async function readResponse(fetcher: typeof fetch, url: string, to: string, data: string, signal: AbortSignal) {
  const id = 1
  let response: Response
  try {
    response = await fetcher(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id, method: 'eth_call', params: [{ to, data }, 'latest'] }),
      signal,
    })
  } catch {
    throw new Error('network request failed')
  }
  if (!response.ok) throw new Error(`HTTP ${response.status}`)

  let payload: unknown
  try {
    payload = await response.json()
  } catch {
    throw new Error('malformed JSON')
  }
  if (!payload || typeof payload !== 'object' || !('jsonrpc' in payload) || payload.jsonrpc !== '2.0'
    || !('id' in payload) || payload.id !== id) {
    throw new Error('malformed JSON-RPC response')
  }
  if ('error' in payload) {
    const error = payload.error
    const code = error && typeof error === 'object' && 'code' in error && Number.isInteger(error.code)
      ? ` ${error.code}` : ''
    throw new Error(`JSON-RPC error${code}`)
  }
  return 'result' in payload ? payload.result : undefined
}

export async function loadDashboardState({ receipts = bundledReceipts, fetcher, timeoutMs = 5000 }: DashboardOptions = {}): Promise<DashboardState> {
  const replay = (degradedReasons: string[]): DashboardState => ({ mode: 'DETERMINISTIC_REPLAY', receipts, degradedReasons })
  if (receipts.deploymentStatus === 'PENDING_LIVE_DEPLOYMENT') {
    return replay(['Awaiting Ticket 05 live 3-testnet deployment receipts'])
  }

  const { borrowGate, spotPool, referencePoolWitness, secondWitnessReactive } = receipts.contracts
  const requestIds = [...new Set(receipts.scenarios.map(({ requestId }) => requestId))]
  if (!isAddress(borrowGate) || !isAddress(spotPool) || !isAddress(referencePoolWitness)
    || !isAddress(secondWitnessReactive) || requestIds.length === 0 || !requestIds.every(isBytes32)) {
    return replay(['Receipt bundle is missing valid contract addresses or request IDs'])
  }

  const rpcFetch = fetcher ?? globalThis.fetch.bind(globalThis)
  async function call<T>(chain: Chain, label: string, to: string, data: string, wordCount: number, decode: (words: string[]) => T) {
    const { name, rpc } = chains[chain]
    const abort = new AbortController()
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      const timeout = new Promise<never>((_, reject) => {
        timer = setTimeout(() => {
          reject(new Error(`timed out after ${timeoutMs} ms`))
          abort.abort()
        }, timeoutMs)
      })
      const result = await Promise.race([readResponse(rpcFetch, rpc, to, data, abort.signal), timeout])
      if (typeof result !== 'string' || !new RegExp(`^0x[0-9a-fA-F]{${wordCount * 64}}$`).test(result)) {
        throw new Error('invalid ABI payload')
      }
      return decode(result.slice(2).match(/.{64}/g)!)
    } catch (error) {
      const reason = error instanceof Error ? error.message : 'RPC read failed'
      throw new Error(`${name} (${rpc}): ${reason} [${label}]`)
    } finally {
      clearTimeout(timer)
    }
  }

  const addressArg = (address: string) => address.slice(2).padStart(64, '0')
  const uint = (chain: Chain, label: string, to: string, data: string, bits = 256n) => (
    call(chain, label, to, data, 1, ([word]) => {
      const value = BigInt(`0x${word}`)
      if (value >= 2n ** bits) throw new Error('invalid ABI integer width')
      return value
    })
  )

  const results = await Promise.allSettled([
    uint('lasna', 'SYSTEM.debt', LASNA_SYSTEM, selectors.debt + addressArg(secondWitnessReactive)),
    uint('base', 'CallbackProxy.debt', BASE_CALLBACK_PROXY, selectors.debt + addressArg(borrowGate)),
    uint('lasna', 'latestPriceE18', secondWitnessReactive, selectors.latestPriceE18),
    uint('lasna', 'latestTradedAt', secondWitnessReactive, selectors.latestTradedAt, 64n),
    uint('lasna', 'latestTradeSeq', secondWitnessReactive, selectors.latestTradeSeq, 64n),
    uint('base', 'SpotPool.priceE18', spotPool, selectors.priceE18),
    uint('unichain', 'ReferencePoolWitness.priceE18', referencePoolWitness, selectors.priceE18),
    ...requestIds.map((id) => call('base', `requestState(${id})`, borrowGate, selectors.requestState + id.slice(2), 11, decodeRequest)),
  ] as const)

  const reasons = results.flatMap((result) => result.status === 'rejected' ? [String(result.reason.message)] : [])
  if (reasons.length > 0) return replay(reasons)

  const value = <T,>(result: PromiseSettledResult<T>): T => {
    if (result.status === 'rejected') throw result.reason
    return result.value
  }
  const [lasnaDebt, baseDebt, latestPriceE18, latestTradedAt, latestTradeSeq, spotPriceE18, referencePriceE18, ...requests] = results
  return {
    mode: 'LIVE', receipts,
    live: {
      lasnaDebt: value(lasnaDebt), baseDebt: value(baseDebt),
      latestPriceE18: value(latestPriceE18), latestTradedAt: value(latestTradedAt), latestTradeSeq: value(latestTradeSeq),
      spotPriceE18: value(spotPriceE18), referencePriceE18: value(referencePriceE18),
      requests: Object.fromEntries(requestIds.map((id, index) => [id, value(requests[index])])),
    },
  }
}
