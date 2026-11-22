// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {AbstractPayer} from "reactive-lib-omni/base/AbstractPayer.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";
import {BorrowGate} from "../src/BorrowGate.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {ReferencePoolWitness} from "../src/ReferencePoolWitness.sol";
import {SpotPool} from "../src/SpotPool.sol";
import {MockCallbackProxy} from "./mocks/MockCallbackProxy.sol";

contract SecondWitnessCoreTest is Test {
  uint64 private constant NOW = 1000;
  uint64 private constant DEADLINE = 1100;
  address private constant ALICE = address(0xA11CE);
  address private constant BOB = address(0xB0B);
  address private constant WITNESS = address(0xBAD5EED);

  MockERC20 private weth;
  MockERC20 private usdc;
  SpotPool private spot;
  ReferencePoolWitness private referencePool;
  BorrowGate private gate;
  MockCallbackProxy private proxy;

  function setUp() public {
    vm.warp(NOW);
    weth = new MockERC20("Mock Ether", "mETH", 18);
    usdc = new MockERC20("Mock USDC", "mUSDC", 6);
    spot = new SpotPool(weth, usdc);
    referencePool = new ReferencePoolWitness(weth, usdc);
    proxy = new MockCallbackProxy();
    gate = new BorrowGate(IPayable(payable(address(proxy))), WITNESS, spot, 10e6, 30, 15, 2, 300);
    weth.mint(address(this), 101 ether);
    usdc.mint(address(this), 210_000e6);
    weth.approve(address(spot), type(uint256).max);
    usdc.approve(address(spot), type(uint256).max);
    weth.approve(address(referencePool), type(uint256).max);
    usdc.approve(address(referencePool), type(uint256).max);
    spot.addLiquidity(1 ether, 2000e6);
    referencePool.addLiquidity(20 ether, 40_000e6);
    usdc.mint(address(gate), 1000e6);
    weth.mint(ALICE, 2 ether);
    vm.startPrank(ALICE);
    weth.approve(address(gate), type(uint256).max);
    usdc.approve(address(gate), type(uint256).max);
    gate.depositCollateral(2 ether);
    vm.stopPrank();
  }

  function test_smallBorrowAtLimitAndLargeBorrowRejection() public {
    vm.prank(ALICE);
    gate.borrow(10e6);
    assertEq(usdc.balanceOf(ALICE), 10e6);
    assertEq(gate.totalDebt(ALICE), 10e6);
    assertEq(gate.lockedForActiveDebt(ALICE), 0.00625 ether);
    vm.prank(ALICE);
    vm.expectRevert(BorrowGate.UseAsyncRequestBorrow.selector);
    gate.borrow(10e6 + 1);
  }

  function test_repayUnlocksProportionallyAndWithdrawalCannotUseLocks() public {
    vm.prank(ALICE);
    gate.borrow(8e6);
    uint256 free = 2 ether - 0.005 ether;
    vm.prank(ALICE);
    vm.expectRevert(BorrowGate.InsufficientCollateral.selector);
    gate.withdrawCollateral(free + 1);
    vm.prank(ALICE);
    gate.withdrawCollateral(free);
    vm.prank(ALICE);
    gate.repay(3e6);
    assertEq(gate.freeCollateral(ALICE), 0.001875 ether);
    assertEq(gate.lockedForActiveDebt(ALICE), 0.003125 ether);
    assertEq(gate.totalDebt(ALICE), 5e6);
    vm.prank(ALICE);
    gate.repay(5e6);
    assertEq(gate.lockedForActiveDebt(ALICE), 0);
    assertEq(gate.freeCollateral(ALICE), 0.005 ether);
  }

  function test_zeroRepaymentReleasesCollateralAfterAlreadyRepaidHoldCloses() public {
    bytes32 id = _request(80e6, 0);
    _verdict(id, 1, 1000e18, NOW, 0);
    vm.startPrank(ALICE);
    gate.repay(40e6);
    gate.cancelRequest(id);
    assertEq(gate.requestState(id).keptCollateral, 0.05 ether);
    assertEq(gate.totalDebt(ALICE), 0);
    gate.repay(0);
    gate.withdrawCollateral(2 ether);
    vm.stopPrank();
    assertEq(weth.balanceOf(ALICE), 2 ether);
  }

  function test_belowMinimum80_75_72HoldsWithoutDisbursing() public {
    bytes32 id = _request(80e6, 75e6);
    _expectOutcome(id, 1, BorrowGate.Status.HELD, gate.REASON_BELOW_MIN_ACCEPTABLE(), 0, 0, 80e6, 2);
    _verdict(id, 1, 1800e18, NOW, 0);
    BorrowGate.Request memory req = gate.requestState(id);
    assertEq(uint256(req.status), uint256(BorrowGate.Status.HELD));
    assertEq(req.disbursedAmount, 0);
    assertEq(gate.totalDebt(ALICE), 0);
    assertEq(usdc.balanceOf(ALICE), 0);
    assertEq(usdc.balanceOf(address(gate)), 1000e6);
  }

  function test_divergentQuotesRespectFairCapAndStrictMinimum() public {
    SpotPool highSpot = new SpotPool(weth, usdc);
    weth.approve(address(highSpot), 1 ether);
    usdc.approve(address(highSpot), 10_000e6);
    highSpot.addLiquidity(1 ether, 10_000e6);
    gate = new BorrowGate(IPayable(payable(address(proxy))), WITNESS, highSpot, 10e6, 30, 15, 2, 300);
    usdc.mint(address(gate), 1000e6);
    weth.mint(ALICE, 1 ether);
    vm.startPrank(ALICE);
    weth.approve(address(gate), 1 ether);
    gate.depositCollateral(1 ether);
    vm.stopPrank();
    assertEq(highSpot.priceE18(), 10_000e18);
    bytes32 strictId = _request(400e6, 400e6);
    bytes32 flexibleId = _request(400e6, 0);
    _verdict(strictId, 1, referencePool.priceE18(), NOW, 0);
    _verdict(flexibleId, 1, referencePool.priceE18(), NOW, 0);
    assertEq(gate.requestState(strictId).disbursedAmount, 0);
    assertEq(gate.requestState(flexibleId).disbursedAmount, 80e6);
    assertEq(usdc.balanceOf(ALICE), 80e6);
  }

  function test_staleFutureAndZeroPriceHoldThenFreshTradesSettle() public {
    bytes32 stale = _request(80e6, 80e6);
    bytes32 future = _request(90e6, 90e6);
    bytes32 zero = _request(100e6, 100e6);
    _expectStale(stale, 80e6, 2000e18, NOW - 31);
    _expectStale(future, 90e6, 2000e18, NOW + 16);
    _expectStale(zero, 100e6, 0, NOW);
    assertEq(gate.totalDebt(ALICE), 0);

    vm.warp(NOW + 5);
    referencePool.swapUsdcForEth(100e6, 1);
    referencePool.swapUsdcForEth(100e6, 1);
    vm.expectEmit(address(gate));
    emit BorrowGate.BorrowClosed(stale, BorrowGate.Status.SETTLED);
    _expectOutcome(stale, 2, BorrowGate.Status.SETTLED, gate.REASON_DISBURSED(), 80e6, 80e6, 0, 0);
    _verdict(stale, 2, referencePool.priceE18(), NOW + 5, 2);
    assertEq(gate.requestState(stale).lastEffectivePrice, 2000e18);
    assertEq(gate.requestState(stale).keptCollateral, 0.05 ether);
    assertEq(gate.activePendingCount(), 2);
    assertEq(gate.totalDebt(ALICE), 80e6);
  }

  function test_inclusiveFreshnessEdgesAndSettlementAtEqualPrice() public {
    bytes32 past = _request(80e6, 80e6);
    bytes32 future = _request(80e6, 80e6);
    _verdict(past, 1, 2000e18, NOW - 30, 0);
    _verdict(future, 1, 2000e18, NOW + 15, 0);
    assertEq(uint256(gate.requestState(past).status), uint256(BorrowGate.Status.SETTLED));
    assertEq(uint256(gate.requestState(future).status), uint256(BorrowGate.Status.SETTLED));
    assertEq(gate.totalDebt(ALICE), 160e6);
  }

  function test_revisionsPayOnlyDeltaAndPreserveSnapshotsOnNoops() public {
    bytes32 id = _request(80e6, 1e6);
    _verdict(id, 2, 1000e18, NOW, 0);
    assertEq(gate.requestState(id).disbursedAmount, 40e6);
    _assertNoop(id, 2);
    _assertNoop(id, 1);
    _expectOutcome(id, 3, BorrowGate.Status.HELD, gate.REASON_DISBURSED(), 24e6, 64e6, 16e6, 0);
    _verdict(id, 3, 1600e18 + 1e12, NOW, 2);
    _verdict(id, 4, 900e18, NOW, 2);
    assertEq(gate.requestState(id).lastEffectivePrice, 1600e18 + 1e12);
    vm.warp(DEADLINE);
    _assertNoop(id, 5);
    vm.expectEmit(address(gate));
    emit BorrowGate.BorrowClosed(id, BorrowGate.Status.EXPIRED);
    vm.prank(BOB);
    gate.expireRequest(id);
    assertEq(gate.requestState(id).keptCollateral, 49_999_999_968_750_001);
    assertEq(gate.lockedForActiveDebt(ALICE), 49_999_999_968_750_001);
    assertEq(gate.lockedForPendingRequests(ALICE), 0);
    assertEq(gate.totalDebt(ALICE), 64e6);
    assertEq(usdc.balanceOf(ALICE), 64e6);
    assertEq(gate.activePendingCount(), 0);
    _assertNoop(id, 6);
  }

  function test_cancelAndExpireAuthorizeAndReleaseUndisbursedReservations() public {
    bytes32 cancelled = _request(80e6, 80e6);
    bytes32 expired = _request(80e6, 80e6);
    assertEq(gate.freeCollateral(ALICE), 1.9 ether);
    vm.prank(BOB);
    vm.expectRevert(BorrowGate.NotBorrower.selector);
    gate.cancelRequest(cancelled);
    vm.expectRevert(BorrowGate.NotExpired.selector);
    gate.expireRequest(expired);
    vm.expectEmit(address(gate));
    emit BorrowGate.BorrowClosed(cancelled, BorrowGate.Status.CANCELLED);
    vm.prank(ALICE);
    gate.cancelRequest(cancelled);
    assertEq(gate.freeCollateral(ALICE), 1.95 ether);
    _assertNoop(cancelled, 1);
    vm.warp(DEADLINE);
    vm.expectEmit(address(gate));
    emit BorrowGate.BorrowClosed(expired, BorrowGate.Status.EXPIRED);
    vm.prank(BOB);
    gate.expireRequest(expired);
    assertEq(gate.freeCollateral(ALICE), 2 ether);
    assertEq(gate.activePendingCount(), 0);
    vm.prank(ALICE);
    vm.expectRevert(BorrowGate.RequestNotOpen.selector);
    gate.cancelRequest(cancelled);
    vm.expectRevert(BorrowGate.RequestNotOpen.selector);
    gate.expireRequest(expired);
  }

  function test_cancelPartialAndSettledCallbackCannotMutate() public {
    bytes32 cancelled = _request(80e6, 0);
    bytes32 settled = _request(80e6, 80e6);
    _verdict(cancelled, 1, 1600e18 + 1e12, NOW, 0);
    _verdict(settled, 1, type(uint256).max, NOW, 0);
    vm.expectEmit(address(gate));
    emit BorrowGate.BorrowClosed(cancelled, BorrowGate.Status.CANCELLED);
    vm.prank(ALICE);
    gate.cancelRequest(cancelled);
    assertEq(gate.requestState(cancelled).keptCollateral, 49_999_999_968_750_001);
    _assertNoop(cancelled, 2);
    _assertNoop(settled, 2);
    _assertNoop(bytes32(0), 1);
    assertEq(gate.totalDebt(ALICE), 144e6);
  }

  function test_requestValidationGlobalHoldCapAndEvent() public {
    vm.prank(ALICE);
    vm.expectRevert(BorrowGate.InvalidRequest.selector);
    gate.requestBorrow(10e6, 0, DEADLINE);
    vm.prank(ALICE);
    vm.expectRevert(BorrowGate.InvalidRequest.selector);
    gate.requestBorrow(80e6, 80e6 + 1, DEADLINE);
    vm.prank(ALICE);
    vm.expectRevert(BorrowGate.InvalidRequest.selector);
    gate.requestBorrow(80e6, 0, NOW);
    vm.prank(ALICE);
    vm.expectRevert(BorrowGate.InvalidRequest.selector);
    gate.requestBorrow(80e6, 0, NOW + 301);
    vm.expectEmit(false, true, false, true, address(gate));
    emit BorrowGate.BorrowRequested(bytes32(0), ALICE, 80e6, 75e6, NOW, DEADLINE);
    bytes32 first = _request(80e6, 75e6);
    BorrowGate.Request memory req = gate.requestState(first);
    assertEq(uint256(req.status), uint256(BorrowGate.Status.PENDING));
    assertEq(req.reservedCollateral, 0.05 ether);
    assertEq(req.borrower, ALICE);
    assertEq(req.createdAt, NOW);
    bytes32 second = _request(80e6, 75e6);
    assertNotEq(first, second);
    _request(80e6, 75e6);
    _request(80e6, 75e6);
    vm.prank(BOB);
    vm.expectRevert(BorrowGate.HoldLimitReached.selector);
    gate.requestBorrow(80e6, 0, DEADLINE);
  }

  function test_callbackGuardsAndLiquidityHold() public {
    bytes32 id = _request(1600e6, 1600e6);
    vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), address(proxy)));
    gate.onWitnessVerdict(WITNESS, id, 1, 2000e18, NOW, 1, 0, bytes32(0), 0);
    vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, BOB, WITNESS));
    proxy.deliver(address(gate), 350_000, BOB, _payload(id, 1, 2000e18, NOW, 0));
    _expectOutcome(id, 1, BorrowGate.Status.HELD, gate.REASON_INSUFFICIENT_LIQUIDITY(), 0, 0, 1600e6, 2);
    _verdict(id, 1, 2000e18, NOW, 0);
    assertEq(gate.totalDebt(ALICE), 0);
    assertEq(gate.requestState(id).disbursedAmount, 0);
  }

  function test_referenceSwapsEmitNormalizedPriceTimeAndConsecutiveSequence() public {
    assertEq(weth.decimals(), 18);
    assertEq(usdc.decimals(), 6);
    assertEq(referencePool.priceE18(), 2000e18);
    vm.expectEmit(address(referencePool));
    emit ReferencePoolWitness.ReferenceTrade(8000e18, NOW, 1);
    assertEq(referencePool.swapUsdcForEth(40_000e6, 10 ether), 10 ether);
    assertEq(referencePool.reserveEth(), 10 ether);
    assertEq(referencePool.reserveUsdc(), 80_000e6);
    vm.warp(NOW + 1);
    vm.expectEmit(address(referencePool));
    emit ReferencePoolWitness.ReferenceTrade(2000e18, NOW + 1, 2);
    assertEq(referencePool.swapEthForUsdc(10 ether, 40_000e6), 40_000e6);
    assertEq(referencePool.tradeSeq(), 2);
    assertEq(weth.balanceOf(address(referencePool)), 20 ether);
    assertEq(usdc.balanceOf(address(referencePool)), 40_000e6);
  }

  function test_spotSwapsEnforceMinimumOutputAndChangeReserves() public {
    vm.expectRevert(SpotPool.InsufficientOutput.selector);
    spot.swapUsdcForEth(2000e6, 0.5 ether + 1);
    assertEq(spot.priceE18(), 2000e18);
    assertEq(spot.swapUsdcForEth(2000e6, 0.5 ether), 0.5 ether);
    assertEq(spot.reserveEth(), 0.5 ether);
    assertEq(spot.reserveUsdc(), 4000e6);
    assertEq(spot.swapEthForUsdc(0.5 ether, 2000e6), 2000e6);
    assertEq(spot.priceE18(), 2000e18);
  }

  function test_largeBorrowAndCloseUseFullPrecision() public {
    uint256 largePrice = 1e50;
    SpotPool highSpot = new SpotPool(weth, usdc);
    weth.mint(address(this), 1);
    usdc.mint(address(this), 1e20);
    weth.approve(address(highSpot), 1);
    usdc.approve(address(highSpot), 1e20);
    highSpot.addLiquidity(1, 1e20);
    gate = new BorrowGate(IPayable(payable(address(proxy))), WITNESS, highSpot, 10e6, 30, 15, 2, 300);
    weth.mint(ALICE, 2e37);
    usdc.mint(address(gate), 16e56);
    vm.startPrank(ALICE);
    weth.approve(address(gate), 2e37);
    gate.depositCollateral(2e37);
    vm.stopPrank();
    bytes32 id = _request(16e56, 0);
    assertEq(gate.requestState(id).reservedCollateral, 2e37);
    _verdict(id, 1, largePrice / 2, NOW, 0);
    assertEq(gate.requestState(id).disbursedAmount, 8e56);
    vm.prank(ALICE);
    gate.cancelRequest(id);
    assertEq(gate.requestState(id).keptCollateral, 2e37);
  }

  function _request(uint256 amount, uint256 minimum) private returns (bytes32) {
    vm.prank(ALICE);
    return gate.requestBorrow(amount, minimum, DEADLINE);
  }

  function _payload(bytes32 id, uint32 revision, uint256 price, uint64 tradedAt, uint32 count)
    private
    pure
    returns (bytes memory)
  {
    return abi.encodeCall(
      BorrowGate.onWitnessVerdict, (address(0), id, revision, price, tradedAt, 1, count, bytes32(0), 0)
    );
  }

  function _verdict(bytes32 id, uint32 revision, uint256 price, uint64 tradedAt, uint32 count) private {
    proxy.deliver(address(gate), 350_000, WITNESS, _payload(id, revision, price, tradedAt, count));
  }

  function _expectOutcome(
    bytes32 id,
    uint32 revision,
    BorrowGate.Status status,
    uint8 reason,
    uint256 delta,
    uint256 disbursed,
    uint256 remaining,
    uint32 missing
  ) private {
    vm.expectEmit(address(gate));
    emit BorrowGate.BorrowOutcome(id, revision, status, reason, delta, disbursed, remaining, missing);
  }

  function _expectStale(bytes32 id, uint256 requested, uint256 price, uint64 tradedAt) private {
    _expectOutcome(id, 1, BorrowGate.Status.HELD, gate.REASON_STALE_REFERENCE(), 0, 0, requested, 2);
    _verdict(id, 1, price, tradedAt, 0);
    assertEq(gate.requestState(id).disbursedAmount, 0);
    assertEq(gate.requestState(id).lastEffectivePrice, 0);
  }

  function _assertNoop(bytes32 id, uint32 revision) private {
    BorrowGate.Request memory before = gate.requestState(id);
    uint256 debt = gate.totalDebt(ALICE);
    uint256 balance = usdc.balanceOf(ALICE);
    _expectOutcome(
      id,
      revision,
      before.status,
      gate.REASON_NOOP_STALE_OR_CLOSED(),
      0,
      before.disbursedAmount,
      before.requestedAmount - before.disbursedAmount,
      0
    );
    _verdict(id, revision, 2000e18, uint64(vm.getBlockTimestamp()), 2);
    assertEq(abi.encode(gate.requestState(id)), abi.encode(before));
    assertEq(gate.totalDebt(ALICE), debt);
    assertEq(usdc.balanceOf(ALICE), balance);
  }
}
