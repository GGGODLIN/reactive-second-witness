// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {BorrowGate} from "../src/BorrowGate.sol";

library SecondWitnessOracle {
  struct Ledger {
    uint256 collateral;
    uint256 active;
    uint256 pending;
    uint256 debt;
    uint256 ethBalance;
    uint256 usdcBalance;
  }

  struct VerdictStep {
    uint32 revision;
    uint256 price;
    uint256 timestamp;
    uint256 firstFresh;
    uint256 lastFresh;
    uint256 debtBefore;
    uint256 debtAfter;
    uint256 balanceBefore;
    uint256 balanceAfter;
    BorrowGate.Request beforeRequest;
    BorrowGate.Request afterRequest;
  }

  function p1(Ledger memory ledger) internal pure returns (bool) {
    return ledger.active <= ledger.collateral && ledger.pending <= ledger.collateral - ledger.active;
  }

  function p2(BorrowGate.Request memory req) internal pure returns (bool) {
    return req.disbursedAmount <= req.requestedAmount
      && (req.disbursedAmount == 0 || req.disbursedAmount >= req.minAcceptableAmount);
  }

  function p3(VerdictStep memory step) internal pure returns (bool) {
    return isFresh(step)
      || (step.afterRequest.disbursedAmount == step.beforeRequest.disbursedAmount
        && step.debtAfter == step.debtBefore
        && step.balanceAfter == step.balanceBefore);
  }

  function p4(VerdictStep memory step) internal pure returns (bool) {
    return step.revision > step.beforeRequest.lastRevision
      || (sameRequest(step.beforeRequest, step.afterRequest)
        && step.debtBefore == step.debtAfter
        && step.balanceBefore == step.balanceAfter);
  }

  function p5(BorrowGate.Request memory before, BorrowGate.Request memory after_) internal pure returns (bool) {
    return !isClosed(before.status) || sameRequest(before, after_);
  }

  function p6(BorrowGate.Request memory req, uint256 actualActive, uint256 modelActive) internal pure returns (bool) {
    return actualActive == modelActive
      && (!isClosed(req.status)
        || req.disbursedAmount == 0
        || covers(req.keptCollateral, req.lastEffectivePrice, req.disbursedAmount));
  }

  function isFresh(VerdictStep memory step) internal pure returns (bool) {
    return step.price != 0 && step.timestamp >= step.firstFresh && step.timestamp <= step.lastFresh;
  }

  function isClosed(BorrowGate.Status status) internal pure returns (bool) {
    return
      status == BorrowGate.Status.SETTLED || status == BorrowGate.Status.CANCELLED
        || status == BorrowGate.Status.EXPIRED;
  }

  function sameRequest(BorrowGate.Request memory a, BorrowGate.Request memory b) internal pure returns (bool) {
    return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
  }

  // Handler inputs fit 256-bit arithmetic; compare cross-products without the contract's mulDiv.
  function covers(uint256 collateral, uint256 price, uint256 amount) internal pure returns (bool) {
    return collateral * price * 8000 >= amount * 1e30 * 10_000;
  }

  function minimumCollateral(uint256 amount, uint256 price, uint256 upperBound) internal pure returns (uint256) {
    if (!covers(upperBound, price, amount)) return upperBound + 1;
    uint256 low;
    while (low < upperBound) {
      uint256 mid = low + (upperBound - low) / 2;
      if (covers(mid, price, amount)) upperBound = mid;
      else low = mid + 1;
    }
    return low;
  }

  function maximumLoan(uint256 collateral, uint256 price, uint256 cap) internal pure returns (uint256 low) {
    while (low < cap) {
      uint256 mid = cap - (cap - low) / 2;
      if (covers(collateral, price, mid)) low = mid;
      else cap = mid - 1;
    }
  }
}
