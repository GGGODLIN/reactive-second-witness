export const chains = {
  base: { id: 84532, name: 'Base Sepolia', rpc: 'https://sepolia.base.org', explorer: 'https://sepolia.basescan.org' },
  unichain: { id: 1301, name: 'Unichain Sepolia', rpc: 'https://sepolia.unichain.org', explorer: 'https://sepolia.uniscan.xyz' },
  lasna: { id: 5318007, name: 'Reactive Lasna', rpc: 'https://lasna-rpc.rnk.dev/', explorer: 'https://lasna.reactscan.net' },
} as const

export type Chain = keyof typeof chains

export const LASNA_SYSTEM = '0x8888888888888888888888888888888888888888'
export const BASE_CALLBACK_PROXY = '0x476F44b11F5C942c58f4c8E3d0300E5710743585'

export function isBytes32(value: string | null): value is string {
  return value !== null && /^0x[\da-fA-F]{64}$/.test(value)
}

export function isAddress(value: string | null): value is string {
  return value !== null && /^0x[\da-fA-F]{40}$/.test(value)
}

export function buildExplorerTxUrl(chain: Chain, hash: string | null): string | null {
  return isBytes32(hash) ? `${chains[chain].explorer}/tx/${hash}` : null
}

export function buildExplorerAddressUrl(chain: Chain, address: string | null): string | null {
  return isAddress(address) ? `${chains[chain].explorer}/address/${address}` : null
}
