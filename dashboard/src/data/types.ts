export type ReceiptHop = 'baseOrigin' | 'unichainReference' | 'lasnaVerdict' | 'baseOutcome'

export interface ScenarioReceipt {
  id: string
  title: string
  expected: string
  requestId: string | null
  transactions: Record<ReceiptHop, string | null>
}

interface LatencySamples {
  samplesMs: number[]
  timeoutCount: number
}

export interface ReceiptBundle {
  deploymentStatus: 'PENDING_LIVE_DEPLOYMENT' | 'DEPLOYED'
  contracts: {
    borrowGate: string | null
    spotPool: string | null
    referencePoolWitness: string | null
    secondWitnessReactive: string | null
  }
  scenarios: ScenarioReceipt[]
  latencyBenchmark: LatencySamples & { polling?: LatencySamples }
  chainlinkBaseline: {
    date: string
    feed: string
    stalenessSeconds: number
    pollingBaselineMs: number
  }
}
