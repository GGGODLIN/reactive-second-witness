// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {BorrowGate} from "../src/BorrowGate.sol";
import {SecondWitnessOracle as Oracle} from "./SecondWitnessOracle.sol";

contract OracleCalibrationTest is Test {
  function test_P1RejectsCombinedLocksAboveCollateral() public pure {
    Oracle.Ledger memory ledger = Oracle.Ledger(1 ether, 0.5 ether, 0.5 ether, 0, 0, 0);
    assertTrue(Oracle.p1(ledger));
    ++ledger.pending;
    assertFalse(Oracle.p1(ledger));
  }

  function test_P2RejectsNonzeroDisbursementBelowMinimum() public pure {
    BorrowGate.Request memory req = _held();
    req.minAcceptableAmount = 75e6;
    assertTrue(Oracle.p2(req));
    req.disbursedAmount = 72e6;
    assertFalse(Oracle.p2(req));
  }

  function test_P3RejectsDisbursementWithStaleEvidence() public pure {
    Oracle.VerdictStep memory step = _step();
    step.timestamp = step.lastFresh + 1;
    step.afterRequest.lastRevision = 2;
    assertTrue(Oracle.p3(step));
    step.afterRequest.disbursedAmount = 72e6;
    assertFalse(Oracle.p3(step));
  }

  function test_P4RejectsMutationAtEqualRevision() public pure {
    Oracle.VerdictStep memory step = _step();
    step.revision = step.beforeRequest.lastRevision;
    assertTrue(Oracle.p4(step));
    step.afterRequest.lastEffectivePrice = 1800e18;
    assertFalse(Oracle.p4(step));
  }

  function test_P5RejectsMutationAfterClose() public pure {
    BorrowGate.Request memory before = _closed();
    BorrowGate.Request memory after_ = _closed();
    assertTrue(Oracle.p5(before, after_));
    --after_.keptCollateral;
    assertFalse(Oracle.p5(before, after_));
  }

  function test_P6RejectsOneWeiCoverageShortfallAndLedgerMismatch() public pure {
    BorrowGate.Request memory req = _closed();
    assertTrue(Oracle.p6(req, 0.05 ether, 0.05 ether));
    assertFalse(Oracle.p6(req, 0.05 ether - 1, 0.05 ether));
    --req.keptCollateral;
    assertFalse(Oracle.p6(req, 0.05 ether, 0.05 ether));
  }

  function _held() private pure returns (BorrowGate.Request memory req) {
    req.status = BorrowGate.Status.HELD;
    req.lastRevision = 1;
    req.requestedAmount = 80e6;
    req.reservedCollateral = 0.05 ether;
  }

  function _closed() private pure returns (BorrowGate.Request memory req) {
    req = _held();
    req.status = BorrowGate.Status.SETTLED;
    req.disbursedAmount = 80e6;
    req.lastEffectivePrice = 2000e18;
    req.keptCollateral = 0.05 ether;
  }

  function _step() private pure returns (Oracle.VerdictStep memory step) {
    step.revision = 2;
    step.price = 2000e18;
    step.timestamp = 1000;
    step.firstFresh = 985;
    step.lastFresh = 1030;
    step.beforeRequest = _held();
    step.afterRequest = _held();
  }
}
