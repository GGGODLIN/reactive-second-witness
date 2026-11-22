# Second Witness

A spot price can move inside the same Base transaction that uses it to value collateral. Second Witness keeps small borrows synchronous and asks for an independent Unichain price before disbursing a large borrow. Reactive Lasna relays the witness. Base's `BorrowGate` alone decides what can be paid and owns every collateral lock and debt balance.

## Two-minute verification without a wallet

Open the dashboard's **Request traces**. In this checkout, the public deployment URL, request IDs, and transaction hashes are pending Ticket 05. Use the named Foundry tests below to verify the expected behavior locally. Once receipts are published, choose a card and match `requestId` in the Base origin, Lasna verdict, and Base outcome events. Use the verdict's `refTxHash` and `refLogIndex` to locate the exact Unichain trade.

| Scenario | Base Origin | Unichain Reference | Lasna Verdict | Base Outcome | Local test |
| --- | --- | --- | --- | --- | --- | --- |
| Flash-loan blocked | `BorrowRequested` · pending | `ReferenceTrade` · pending | `WitnessVerdict` · pending | `HELD`, zero paid for a strict minimum above the witness-backed cap · pending | `test_fiveXSpotSwapDrainsNaiveLenderWhileBorrowGateBlocksAndCaps` |
| Synchronized settle | `BorrowRequested` · pending | Fresh `ReferenceTrade` · pending | Initial `WitnessVerdict` · pending | Full `SETTLED` in one callback · pending | `testFreshWitnessCorrelatesInitialVerdictAndSettlesThroughProxy` |
| Stale hold → auto-release | `BorrowRequested` · pending | Latest qualifying fresh trade · pending | Re-evaluation verdict · pending | `HELD` in request history, then `SETTLED` · pending | `testStaleWitnessSettlesOnlyAfterTwoNewReferenceTrades` |
| Local cancel / expire | `BorrowRequested` · pending | Optional earlier evidence | Optional earlier verdict | `CANCELLED` or `EXPIRED`, releasing unused collateral · pending | `test_cancelAndExpireAuthorizeAndReleaseUndisbursedReservations` |

`LIVE` means every required contract read succeeded at page load. `DETERMINISTIC_REPLAY` explains the failed endpoint and keeps published receipt links available. Before deployment the same badge identifies a pending evidence bundle with no testnet receipts. A live getter shows the current state, while the linked receipt proves what happened in that transaction.

| Evidence | Measurement | Successful samples | Timeouts / failures | Raw observations | p50 / p95 |
| --- | --- | ---: | --- | --- | --- |
| Reactive Omni full loop | Base request submission to Base outcome receipt observed | 0 | Pending | Pending Ticket 05 (~2 s target) | Pending |
| 7 s polling | Same start and end points, checked every 7,000 ms | 0 | Pending | Pending Ticket 05 | Pending |
| Chainlink Base Sepolia ETH/USD | Feed age relative to Base chain head, sampled 2026-11-23 | 1 | — | 419 s | — |

The 7,000 ms value is a polling interval. The 419 s value is the dated feed-age observation recorded in the project specification. The dashboard calculates nearest-rank p50 and p95 per loop method once it has at least 20 successful durations, and reports unsuccessful runs separately.

## Where decisions happen

```text
Unichain Sepolia 1301        Reactive Lasna 5318007              Base Sepolia 84532
ReferencePoolWitness ──────► SecondWitnessReactive ◄─────────── BorrowGate + SpotPool
       ReferenceTrade         latest witness + hold slots       BorrowRequested / BorrowClosed
                              │
                              └──── SYSTEM → CallbackProxy ───► BorrowGate
                                        witness verdict         collateral, debt, payouts
```

Base checks how old the witness is and caps the price at the lower of its local spot and the Unichain reference. If that price cannot support the borrower's minimum, Base holds the request. Fresh Unichain trades can trigger another verdict. If the callback path stalls, the borrower can cancel on Base, and anyone can expire the request at its deadline.

| Invariant | Base ledger property |
| --- | --- |
| P1 | Active debt locks plus pending reservations stay within the borrower's total collateral. |
| P2 | Cumulative payout stays within the request amount. Any positive payout meets the borrower's minimum. |
| P3 | A stale, too-far-future, or zero-price witness leaves the payout unchanged. |
| P4 | An older or repeated revision leaves the payout, debt, and status unchanged. |
| P5 | A closed request keeps its payout, retained collateral, and terminal status. |
| P6 | On close, retained collateral covers the payout at the effective price and LTV. Active debt locks match the accounting oracle. |

Deploy in this order because the Base callback receiver binds the Lasna sender in its constructor:

1. Deploy the mock token pair and `ReferencePoolWitness` on Unichain Sepolia.
2. Deploy the mock token pair, `SpotPool`, and `UnprotectedLendingMock` on Base Sepolia.
3. Deploy `SecondWitnessReactive` on Lasna, supplying the Unichain pool address and Lasna reserve funding. Its constructor subscribes to `ReferenceTrade`.
4. Deploy `BorrowGate` with the Base `CallbackProxy`, the Lasna contract as callback sender, and the Base spot pool. Fund the protocol reserves and verify both service-provider debt balances before running the demo.
5. Call `SecondWitnessReactive.configureBorrowGate` once as the owner to subscribe to Base `BorrowRequested` and `BorrowClosed`.

## Reproduce locally

From the repository root, run the two blocks in separate shells. Use [Foundry](https://getfoundry.sh/) for the contracts and Node.js 24 with [pnpm](https://pnpm.io/) for the dashboard.

```sh
forge test -vvv --gas-report
```

```sh
cd dashboard && pnpm install && pnpm test && pnpm build
pnpm preview
```

Open the local URL printed by `pnpm preview`. The static output is `dashboard/dist/`. No wallet, API key, or `.env` is required to build or load it.

## Read-only Cast diagnostics

Run from the repository root with Foundry's `cast` and `jq`. This block reads public values from the bundled JSON and exits early while Ticket 05 is pending. Choose `flash-loan`, `synchronized`, or `stale` to trace a request with all four hops.

```bash
(
  set -eu
  bundle=dashboard/src/data/verified-receipts.json
  scenario=synchronized
  if ! jq -e '.deploymentStatus == "DEPLOYED"' "$bundle" >/dev/null; then
    printf '%s\n' 'Awaiting Ticket 05 live 3-testnet deployment receipts.'
    exit 0
  fi

  base_rpc=https://sepolia.base.org
  unichain_rpc=https://sepolia.unichain.org
  lasna_rpc=https://lasna-rpc.rnk.dev/
  lasna_system=0x8888888888888888888888888888888888888888
  base_proxy=0x476F44b11F5C942c58f4c8E3d0300E5710743585
  reactive=$(jq -er '.contracts.secondWitnessReactive' "$bundle")
  gate=$(jq -er '.contracts.borrowGate' "$bundle")
  request=$(jq -ce --arg scenario "$scenario" '.scenarios[] | select(.id == $scenario)' "$bundle")
  request_id=$(jq -er '.requestId' <<< "$request")

  # Both service-provider debts should be zero for the funded demo.
  cast call --rpc-url "$lasna_rpc" "$lasna_system" 'debt(address)(uint256)' "$reactive"
  cast call --rpc-url "$base_rpc" "$base_proxy" 'debt(address)(uint256)' "$gate"
  cast call --rpc-url "$lasna_rpc" "$reactive" 'latestPriceE18()(uint256)'
  cast call --rpc-url "$lasna_rpc" "$reactive" 'latestTradedAt()(uint64)'
  cast call --rpc-url "$lasna_rpc" "$reactive" 'latestTradeSeq()(uint64)'
  cast call --rpc-url "$base_rpc" "$gate" \
    'requestState(bytes32)((address,uint256,uint256,uint256,uint256,uint256,uint256,uint64,uint64,uint32,uint8))' \
    "$request_id"

  # Find the Base BorrowRequested subscription and look up its UID.
  borrow_requested=$(cast keccak 'BorrowRequested(bytes32,address,uint256,uint256,uint64,uint64)')
  filters=$(cast rpc --rpc-url "$lasna_rpc" rnk_getFilters)
  filter_params=$(jq -ce --arg gate "$gate" --arg reactive "$reactive" --arg topic "$borrow_requested" '
    first(.topicFilters[] | select(.ChainId == 84532
      and ((.Contract // "") | ascii_downcase) == ($gate | ascii_downcase)
      and .Topics[0] == $topic and any(.Configs[];
        .Active == true and ((.Contract // "") | ascii_downcase) == ($reactive | ascii_downcase))))
    | [.Uid]
  ' <<< "$filters")
  cast rpc --rpc-url "$lasna_rpc" --raw rnk_getFilterById "$filter_params"

  cast receipt --rpc-url "$base_rpc" --json "$(jq -er '.transactions.baseOrigin' <<< "$request")"
  cast receipt --rpc-url "$unichain_rpc" --json "$(jq -er '.transactions.unichainReference' <<< "$request")"
  cast receipt --rpc-url "$lasna_rpc" --json "$(jq -er '.transactions.lasnaVerdict' <<< "$request")"
  cast receipt --rpc-url "$base_rpc" --json "$(jq -er '.transactions.baseOutcome' <<< "$request")"
)
```

For local cancellation or expiry, inspect the Base origin and outcome. The Unichain and Lasna hops are only relevant if the request received earlier cross-chain evidence. No diagnostic signs or sends a transaction.

## Updating the evidence bundle

Set `deploymentStatus` to `DEPLOYED` after collecting and verifying the addresses and receipt hashes in `dashboard/src/data/verified-receipts.json`. Keep each `requestId` with its matching `transactions`, and use `null` for unused local-only hops. Record successful durations in chronological order in `latencyBenchmark.samplesMs` and `latencyBenchmark.polling.samplesMs`. Record the number of timeouts and failures separately in each `timeoutCount`. Rebuild the dashboard after replacing the bundle.

## License

MIT. See the root `LICENSE`.
