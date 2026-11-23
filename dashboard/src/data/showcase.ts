// Recorded by the same live testnet run as verified-receipts.json. Kept in a separate module so the
// receipt bundle that the README and cast diagnostics read stays exactly as it was published.
export const flashLoanEvidence = {
  lenderAddress: '0x133aB0676E36dbB3227eBe12Fe1f100b8Fb5B734',
  drainTx: '0xe3be041129202009e89f3c0f8c90e69aa699df6b7f26ec0a0ad802e3f4d98821',
  drainedRaw: 8_000_000_000n,
  gatePaidRaw: 0n,
} as const

export const MUSDC_DECIMALS = 6

// Constructor arguments used by script/DeploySecondWitness.s.sol for the deployed BorrowGate.
export const riskParameters = {
  ltvPercent: 80,
  smallBorrowLimitUsdc: 500,
  maxEvidenceAgeSeconds: 30,
  requiredFreshTrades: 2,
} as const

export const synchronizedLoopMs = 2937

export const scenarioOutcomes: Record<string, { label: string; tone: 'held' | 'settled' | 'released' }> = {
  'flash-loan': { label: 'HELD · $0 paid', tone: 'held' },
  synchronized: { label: 'SETTLED · 1 callback', tone: 'settled' },
  stale: { label: 'HELD → SETTLED · rev 2', tone: 'settled' },
  'cancel-expire': { label: 'CANCELLED · collateral released', tone: 'released' },
}
