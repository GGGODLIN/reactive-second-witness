// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AbstractPayer} from "reactive-lib-omni/base/AbstractPayer.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";
import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";
import {BorrowGate} from "../src/BorrowGate.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {ReferencePoolWitness} from "../src/ReferencePoolWitness.sol";
import {SecondWitnessReactive} from "../src/SecondWitnessReactive.sol";
import {SpotPool} from "../src/SpotPool.sol";
import {UnprotectedLendingMock} from "../src/UnprotectedLendingMock.sol";
import {MockCallbackProxy} from "./mocks/MockCallbackProxy.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";

contract SecondWitnessIntegrationTest is Test {
  uint256 private constant BASE = 84_532;
  uint256 private constant UNICHAIN = 1_301;
  uint256 private constant LASNA = 5_318_007;
  uint64 private constant START = 1_700_000_000;
  uint64 private constant DEADLINE = START + 120;
  uint64 private constant CALLBACK_GAS_LIMIT = 400_000;
  uint256 private constant AMOUNT = 1_000e6;
  uint256 private constant ANY_TOPIC = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
  address private constant SYSTEM = 0x8888888888888888888888888888888888888888;
  address private constant BORROWER = address(0xA11CE);
  address private constant OUTSIDER = address(0xCAFE);

  MockSystemContract private constant SYSTEM_MOCK = MockSystemContract(SYSTEM);
  MockCallbackProxy private proxy;
  MockERC20 private baseEth;
  MockERC20 private baseUsdc;
  MockERC20 private refUsdc;
  SpotPool private spot;
  ReferencePoolWitness private referencePool;
  SecondWitnessReactive private witness;
  BorrowGate private gate;
  UnprotectedLendingMock private comparison;
  uint256 private txNonce;

  function setUp() public {
    vm.warp(START);
    vm.chainId(UNICHAIN);
    MockERC20 refEth = new MockERC20("Unichain ETH", "mETH", 18);
    refUsdc = new MockERC20("Unichain USDC", "mUSDC", 6);
    referencePool = new ReferencePoolWitness(refEth, refUsdc);
    _seed(referencePool, 200_000e6);
    refUsdc.mint(address(this), 10_000e6);
    refUsdc.approve(address(referencePool), type(uint256).max);

    vm.chainId(BASE);
    baseEth = new MockERC20("Base ETH", "mETH", 18);
    baseUsdc = new MockERC20("Base USDC", "mUSDC", 6);
    spot = new SpotPool(baseEth, baseUsdc);
    _seed(spot, 200_000e6);
    comparison = new UnprotectedLendingMock(spot);
    proxy = new MockCallbackProxy();

    vm.chainId(LASNA);
    vm.etch(SYSTEM, type(MockSystemContract).runtimeCode);
    witness = new SecondWitnessReactive(UNICHAIN, address(referencePool), BASE, 2, CALLBACK_GAS_LIMIT);

    vm.chainId(BASE);
    gate = new BorrowGate(IPayable(payable(address(proxy))), address(witness), spot, 500e6, 30, 15, 2, 300);
    baseUsdc.mint(address(gate), 50_000e6);
    baseUsdc.mint(address(comparison), 50_000e6);
    baseEth.mint(BORROWER, 11e18);
    vm.startPrank(BORROWER);
    baseEth.approve(address(gate), 10e18);
    gate.depositCollateral(10e18);
    baseEth.approve(address(comparison), 1e18);
    comparison.depositCollateral(1e18);
    vm.stopPrank();
  }

  function testDeploymentSubscribesToThreeExactRoutesAndOnlyOwnerCanWireOnce() public {
    vm.chainId(LASNA);
    assertEq(witness.owner(), address(this));
    assertEq(SYSTEM_MOCK.subscriptionCount(), 1);
    _assertSubscription(0, UNICHAIN, address(referencePool), ReferencePoolWitness.ReferenceTrade.selector);

    vm.expectRevert(SecondWitnessReactive.NotOwner.selector);
    vm.prank(OUTSIDER);
    witness.configureBorrowGate(address(gate));
    vm.expectRevert(SecondWitnessReactive.InvalidConfiguration.selector);
    witness.configureBorrowGate(address(0));

    witness.configureBorrowGate(address(gate));
    assertEq(witness.borrowGate(), address(gate));
    assertEq(SYSTEM_MOCK.subscriptionCount(), 3);
    _assertSubscription(1, BASE, address(gate), BorrowGate.BorrowRequested.selector);
    _assertSubscription(2, BASE, address(gate), BorrowGate.BorrowClosed.selector);
    assertEq(SYSTEM_MOCK.subscription(), SYSTEM_MOCK.subscriptionAt(2));

    vm.expectRevert(SecondWitnessReactive.AlreadyConfigured.selector);
    witness.configureBorrowGate(OUTSIDER);
    assertEq(witness.borrowGate(), address(gate));
    assertEq(SYSTEM_MOCK.subscriptionCount(), 3);
  }

  function testRejectsInvalidConstructorConfiguration() public {
    vm.chainId(LASNA);
    _assertInvalidDeployment(0, address(referencePool), BASE, 2, CALLBACK_GAS_LIMIT);
    _assertInvalidDeployment(UNICHAIN, address(0), BASE, 2, CALLBACK_GAS_LIMIT);
    _assertInvalidDeployment(UNICHAIN, address(referencePool), 0, 2, CALLBACK_GAS_LIMIT);
    _assertInvalidDeployment(UNICHAIN, address(referencePool), BASE, 0, CALLBACK_GAS_LIMIT);
    _assertInvalidDeployment(UNICHAIN, address(referencePool), BASE, 2, 349_999);
  }

  function testOnlySystemUpdatesWitnessAndOlderOrDuplicateTradeCannotOverwriteIt() public {
    IReactive.LogRecord memory older = _trade();
    vm.warp(START + 1);
    IReactive.LogRecord memory newer = _trade();

    vm.chainId(LASNA);
    vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, OUTSIDER, SYSTEM));
    vm.prank(OUTSIDER);
    witness.react(newer);
    _relay(newer);
    _assertLatest(newer);
    _relay(older);
    _assertLatest(newer);

    newer.data = abi.encode(3_000e18, uint64(START + 2), uint64(2));
    _relay(newer);
    assertEq(witness.latestPriceE18(), referencePool.priceE18());
    assertEq(witness.latestTradedAt(), START + 1);
    assertEq(witness.latestTradeSeq(), 2);
  }

  function testFreshWitnessCorrelatesInitialVerdictAndSettlesThroughProxy() public {
    _configure();
    IReactive.LogRecord memory trade = _trade();
    _relay(trade);
    IReactive.LogRecord memory requested = _request(AMOUNT, AMOUNT, DEADLINE);
    bytes32 requestId = bytes32(requested.topic1);
    _expectVerdict(requestId, 1, 0, trade);
    _relay(requested);
    assertEq(SYSTEM_MOCK.callbackRequestCount(), 1);
    assertEq(SYSTEM_MOCK.requestingContract(), address(witness));
    _assertCallback(0, requestId, 1, 0, trade);
    assertEq(witness.activeHoldCount(), 1);
    _assertHold(0, requestId, DEADLINE, 1, 0);

    _relay(requested);
    assertEq(SYSTEM_MOCK.callbackRequestCount(), 1);
    assertEq(witness.activeHoldCount(), 1);

    vm.recordLogs();
    vm.expectEmit(address(gate));
    emit BorrowGate.BorrowOutcome(requestId, 1, BorrowGate.Status.SETTLED, 0, AMOUNT, AMOUNT, 0, 0);
    _deliver(0);
    IReactive.LogRecord memory closed = _takeLog(BorrowGate.BorrowClosed.selector, address(gate));
    assertEq(bytes32(closed.topic1), requestId);
    assertEq(uint8(abi.decode(closed.data, (BorrowGate.Status))), uint8(BorrowGate.Status.SETTLED));
    assertEq(baseUsdc.balanceOf(BORROWER), AMOUNT);
    _assertRequest(requestId, BorrowGate.Status.SETTLED, 1, AMOUNT);
    _relay(closed);
    assertEq(witness.activeHoldCount(), 0);
    assertEq(witness.holdSlot(0).requestId, bytes32(0));
  }

  function testStaleWitnessSettlesOnlyAfterTwoNewReferenceTrades() public {
    _configure();
    _relay(_trade());
    vm.warp(START + 31);
    IReactive.LogRecord memory requested = _request(AMOUNT, AMOUNT, DEADLINE);
    bytes32 requestId = bytes32(requested.topic1);
    _relay(requested);
    vm.expectEmit(address(gate));
    emit BorrowGate.BorrowOutcome(requestId, 1, BorrowGate.Status.HELD, 1, 0, 0, AMOUNT, 2);
    assertEq(SYSTEM_MOCK.callbackRequestCount(), 1);
    _deliver(0);
    _assertRequest(requestId, BorrowGate.Status.HELD, 1, 0);
    assertEq(baseUsdc.balanceOf(BORROWER), 0);
    _assertHold(0, requestId, DEADLINE, 1, 0);

    IReactive.LogRecord memory firstFresh = _trade();
    _relay(firstFresh);
    _relay(firstFresh);
    assertEq(SYSTEM_MOCK.callbackRequestCount(), 1);
    _assertHold(0, requestId, DEADLINE, 1, 1);

    IReactive.LogRecord memory secondFresh = _trade();
    _expectVerdict(requestId, 2, 2, secondFresh);
    _relay(secondFresh);
    assertEq(SYSTEM_MOCK.callbackRequestCount(), 2);
    _assertCallback(1, requestId, 2, 2, secondFresh);
    _assertHold(0, requestId, DEADLINE, 2, 0);
    vm.expectEmit(address(gate));
    emit BorrowGate.BorrowOutcome(requestId, 2, BorrowGate.Status.SETTLED, 0, AMOUNT, AMOUNT, 0, 0);
    _deliver(1);
    _assertRequest(requestId, BorrowGate.Status.SETTLED, 2, AMOUNT);
    assertEq(baseUsdc.balanceOf(BORROWER), AMOUNT);
  }

  function testDivergentPoolPricesKeepStrictRequestHeldAndCapFlexibleRequest() public {
    _configure();
    vm.chainId(BASE);
    _seed(spot, 300_000e6);
    vm.prank(BORROWER);
    comparison.borrow(AMOUNT);
    assertEq(comparison.debt(BORROWER), AMOUNT);
    _relay(_trade());
    assertGt(spot.priceE18(), witness.latestPriceE18());

    IReactive.LogRecord memory strictRequest = _request(AMOUNT, AMOUNT, DEADLINE);
    _relay(strictRequest);
    assertEq(SYSTEM_MOCK.callbackRequestCount(), 1);
    bytes32 strictId = bytes32(strictRequest.topic1);
    vm.expectEmit(address(gate));
    emit BorrowGate.BorrowOutcome(strictId, 1, BorrowGate.Status.HELD, 2, 0, 0, AMOUNT, 2);
    _deliver(0);
    _assertRequest(strictId, BorrowGate.Status.HELD, 1, 0);
    assertEq(baseUsdc.balanceOf(BORROWER), AMOUNT);

    IReactive.LogRecord memory flexibleRequest = _request(AMOUNT, 0, DEADLINE);
    _relay(flexibleRequest);
    _deliver(1);
    // The reference trade leaves the witness just above $2,000 and Base's seeded price is $2,500.
    uint256 capped = 800_400_049;
    _assertRequest(bytes32(flexibleRequest.topic1), BorrowGate.Status.HELD, 1, capped);
    assertEq(gate.totalDebt(BORROWER), capped);
    assertEq(baseUsdc.balanceOf(BORROWER), AMOUNT + capped);
  }

  function testClosedOnlyFreesMatchingSlotAndMissedClosuresEvictAfterStrictBuffer() public {
    _configure();
    IReactive.LogRecord memory first = _request(AMOUNT, AMOUNT, DEADLINE);
    IReactive.LogRecord memory second = _request(AMOUNT, AMOUNT, DEADLINE);
    _relay(first);
    _relay(second);
    assertEq(witness.activeHoldCount(), 2);

    _relay(_cancel(bytes32(first.topic1)));
    assertEq(witness.activeHoldCount(), 1);
    assertFalse(witness.holdSlot(0).active);
    bytes32 secondId = bytes32(second.topic1);
    _assertHold(1, secondId, DEADLINE, 1, 0);

    vm.warp(DEADLINE - 1);
    _relay(_trade());
    _assertHold(1, secondId, DEADLINE, 1, 1);
    vm.warp(DEADLINE);
    vm.chainId(BASE);
    vm.prank(OUTSIDER);
    gate.expireRequest(secondId);
    assertEq(gate.freeCollateral(BORROWER), 10e18);

    vm.warp(DEADLINE + 75);
    _relay(_trade());
    _assertHold(1, secondId, DEADLINE, 2, 0);
    assertEq(SYSTEM_MOCK.callbackRequestCount(), 3);
    vm.warp(DEADLINE + 76);
    _relay(_trade());
    assertEq(witness.activeHoldCount(), 0);
    assertFalse(witness.holdSlot(1).active);
    assertEq(SYSTEM_MOCK.callbackRequestCount(), 3);
  }

  function testFullTableStillSendsInitialCallbackAndNextRequestReusesExpiredSlots() public {
    _configure();
    bytes32[4] memory ids = _openFour();
    _cancel(ids[0]);
    IReactive.LogRecord memory overflowRequest = _request(AMOUNT, AMOUNT, DEADLINE);
    _relay(overflowRequest);
    assertEq(SYSTEM_MOCK.callbackRequestCount(), 5);
    assertEq(witness.activeHoldCount(), 4);
    for (uint256 i = 0; i < ids.length; ++i) {
      _assertHold(i, ids[i], DEADLINE, 1, 0);
    }
    _deliver(4);
    _assertRequest(bytes32(overflowRequest.topic1), BorrowGate.Status.HELD, 1, 0);
    _cancel(bytes32(overflowRequest.topic1));

    vm.warp(DEADLINE + 76);
    uint64 newDeadline = DEADLINE + 196;
    IReactive.LogRecord memory newRequest = _request(AMOUNT, AMOUNT, newDeadline);
    _relay(newRequest);
    assertEq(witness.activeHoldCount(), 1);
    _assertHold(0, bytes32(newRequest.topic1), newDeadline, 1, 0);
  }

  function testFourSlotFanOutGasAndAllCallbacksSettle() public {
    _configure();
    bytes32[4] memory ids = _openFour();
    for (uint256 i = 0; i < ids.length; ++i) {
      _deliver(i);
      _assertRequest(ids[i], BorrowGate.Status.HELD, 1, 0);
    }
    _relay(_trade());
    assertEq(SYSTEM_MOCK.callbackRequestCount(), 4);
    IReactive.LogRecord memory trade = _trade();
    SYSTEM_MOCK.clearCallbackRequests();
    assertEq(SYSTEM_MOCK.callbackRequestCount(), 0);

    vm.chainId(LASNA);
    vm.cool(SYSTEM);
    vm.cool(address(witness));
    vm.recordLogs();
    uint256 gasBefore = gasleft();
    SYSTEM_MOCK.react(witness, trade);
    uint256 gasUsed = gasBefore - gasleft();
    Vm.Log[] memory verdicts = vm.getRecordedLogs();
    emit log_named_uint("Four-slot react fan-out gas (includes system mock)", gasUsed);
    assertLt(gasUsed, 800_000);
    assertEq(verdicts.length, 4);
    assertEq(SYSTEM_MOCK.callbackRequestCount(), 4);
    for (uint256 i = 0; i < ids.length; ++i) {
      assertEq(verdicts[i].emitter, address(witness));
      assertEq(verdicts[i].topics[0], SecondWitnessReactive.WitnessVerdict.selector);
      assertEq(verdicts[i].topics[1], ids[i]);
      _assertCallback(i, ids[i], 2, 2, trade);
      _deliver(i);
      _assertRequest(ids[i], BorrowGate.Status.SETTLED, 2, AMOUNT);
    }
    assertEq(gate.activePendingCount(), 0);
    assertEq(baseUsdc.balanceOf(BORROWER), 4 * AMOUNT);
  }

  function testWrongRouteAndMalformedPayloadsLeaveWitnessAndHoldIntact() public {
    _configure();
    IReactive.LogRecord memory trade = _trade();
    _relay(trade);
    IReactive.LogRecord memory requested = _request(AMOUNT, AMOUNT, DEADLINE);
    _relay(requested);
    bytes32 requestId = bytes32(requested.topic1);
    IReactive.LogRecord memory validClose = _cancel(requestId);
    IReactive.LogRecord memory invalid = _trade();

    invalid.chainId = BASE;
    _relay(invalid);
    invalid.chainId = UNICHAIN;
    invalid.contractAddress = address(spot);
    _relay(invalid);
    invalid.contractAddress = address(referencePool);
    invalid.topic0 = uint256(keccak256("Unrelated()"));
    _relay(invalid);
    invalid.topic0 = uint256(ReferencePoolWitness.ReferenceTrade.selector);
    invalid.data = abi.encode(uint256(2));
    _relay(invalid);
    invalid.data = abi.encode(uint256(2_000e18), uint256(type(uint64).max) + 1, uint256(2));
    _relay(invalid);
    invalid.data = abi.encode(uint256(2_000e18), uint64(START), uint256(type(uint64).max) + 1);
    _relay(invalid);

    requested.topic1 = 99;
    requested.data = abi.encode(AMOUNT);
    _relay(requested);
    requested.data = abi.encode(AMOUNT, AMOUNT, uint256(type(uint64).max) + 1, DEADLINE);
    _relay(requested);
    requested.data = abi.encode(AMOUNT, AMOUNT, START, uint256(type(uint64).max) + 1);
    _relay(requested);

    bytes memory closeData = validClose.data;
    validClose.data = "";
    _relay(validClose);
    validClose.data = abi.encode(uint256(256));
    _relay(validClose);
    validClose.data = closeData;
    validClose.chainId = UNICHAIN;
    _relay(validClose);
    validClose.chainId = BASE;
    validClose.contractAddress = OUTSIDER;
    _relay(validClose);

    _assertLatest(trade);
    assertEq(SYSTEM_MOCK.callbackRequestCount(), 1);
    assertEq(witness.activeHoldCount(), 1);
    _assertHold(0, requestId, DEADLINE, 1, 0);
    validClose.contractAddress = address(gate);
    _relay(validClose);
    assertEq(witness.activeHoldCount(), 0);
  }

  function _assertInvalidDeployment(
    uint256 unichainId,
    address origin,
    uint256 baseId,
    uint32 required,
    uint64 gasLimit
  ) private {
    try new SecondWitnessReactive(unichainId, origin, baseId, required, gasLimit) {
      fail("invalid configuration accepted");
    } catch (bytes memory reason) {
      assertEq(reason, abi.encodeWithSelector(SecondWitnessReactive.InvalidConfiguration.selector));
    }
  }

  function _configure() private {
    vm.chainId(LASNA);
    witness.configureBorrowGate(address(gate));
  }

  function _seed(SpotPool pool, uint256 quote) private {
    MockERC20 eth = pool.mETH();
    MockERC20 usdc = pool.mUSDC();
    eth.mint(address(this), 100e18);
    usdc.mint(address(this), quote);
    eth.approve(address(pool), 100e18);
    usdc.approve(address(pool), quote);
    pool.addLiquidity(100e18, quote);
  }

  function _trade() private returns (IReactive.LogRecord memory) {
    vm.chainId(UNICHAIN);
    vm.recordLogs();
    referencePool.swapUsdcForEth(50e6, 1);
    return _takeLog(ReferencePoolWitness.ReferenceTrade.selector, address(referencePool));
  }

  function _request(uint256 amount, uint256 minimum, uint64 deadline) private returns (IReactive.LogRecord memory) {
    vm.chainId(BASE);
    vm.recordLogs();
    vm.prank(BORROWER);
    bytes32 requestId = gate.requestBorrow(amount, minimum, deadline);
    IReactive.LogRecord memory requested = _takeLog(BorrowGate.BorrowRequested.selector, address(gate));
    assertEq(bytes32(requested.topic1), requestId);
    return requested;
  }

  function _cancel(bytes32 requestId) private returns (IReactive.LogRecord memory) {
    vm.chainId(BASE);
    vm.recordLogs();
    vm.prank(BORROWER);
    gate.cancelRequest(requestId);
    return _takeLog(BorrowGate.BorrowClosed.selector, address(gate));
  }

  function _openFour() private returns (bytes32[4] memory ids) {
    for (uint256 i = 0; i < ids.length; ++i) {
      IReactive.LogRecord memory requested = _request(AMOUNT, AMOUNT, DEADLINE);
      ids[i] = bytes32(requested.topic1);
      _relay(requested);
    }
    assertEq(witness.activeHoldCount(), 4);
  }

  function _takeLog(bytes32 topic, address emitter) private returns (IReactive.LogRecord memory log) {
    Vm.Log[] memory logs = vm.getRecordedLogs();
    for (uint256 i = 0; i < logs.length; ++i) {
      Vm.Log memory entry = logs[i];
      if (entry.emitter != emitter || entry.topics[0] != topic) continue;
      log.chainId = vm.getChainId();
      log.contractAddress = entry.emitter;
      log.topic0 = uint256(entry.topics[0]);
      if (entry.topics.length > 1) log.topic1 = uint256(entry.topics[1]);
      if (entry.topics.length > 2) log.topic2 = uint256(entry.topics[2]);
      log.data = entry.data;
      // Foundry's recorded logs do not supply receipt metadata.
      log.txHash = uint256(keccak256(abi.encode(log.chainId, ++txNonce)));
      log.logIndex = i;
      return log;
    }
    revert("expected origin event not emitted");
  }

  function _relay(IReactive.LogRecord memory log) private {
    vm.chainId(LASNA);
    SYSTEM_MOCK.react(witness, log);
  }

  function _deliver(uint256 index) private {
    vm.chainId(BASE);
    ISystemContract.CallbackConfiguration_V_1_0 memory callback = SYSTEM_MOCK.callbackRequestAt(index);
    proxy.deliver(callback.recipient, callback.gasLimit, SYSTEM_MOCK.requestingContract(), callback.payload);
  }

  function _assertSubscription(uint256 index, uint256 chainId, address origin, bytes32 topic) private view {
    assertEq(
      SYSTEM_MOCK.subscriptionAt(index),
      abi.encode(address(witness), chainId, origin, uint256(topic), ANY_TOPIC, ANY_TOPIC, ANY_TOPIC)
    );
  }

  function _assertLatest(IReactive.LogRecord memory trade) private view {
    (uint256 price, uint64 tradedAt, uint64 seq) = abi.decode(trade.data, (uint256, uint64, uint64));
    assertEq(witness.latestPriceE18(), price);
    assertEq(witness.latestTradedAt(), tradedAt);
    assertEq(witness.latestTradeSeq(), seq);
    assertEq(witness.latestTxHash(), bytes32(trade.txHash));
    assertEq(witness.latestLogIndex(), trade.logIndex);
  }

  function _expectVerdict(bytes32 requestId, uint32 revision, uint32 fresh, IReactive.LogRecord memory trade) private {
    (uint256 price, uint64 tradedAt, uint64 seq) = abi.decode(trade.data, (uint256, uint64, uint64));
    vm.expectEmit(address(witness));
    // The recorded position comes from the small local swap receipt.
    // forge-lint: disable-next-line(unsafe-typecast)
    emit SecondWitnessReactive.WitnessVerdict(
      requestId, revision, price, tradedAt, seq, fresh, bytes32(trade.txHash), uint32(trade.logIndex)
    );
  }

  function _assertCallback(
    uint256 index,
    bytes32 requestId,
    uint32 revision,
    uint32 fresh,
    IReactive.LogRecord memory trade
  ) private view {
    ISystemContract.CallbackConfiguration_V_1_0 memory callback = SYSTEM_MOCK.callbackRequestAt(index);
    (uint256 price, uint64 tradedAt, uint64 seq) = abi.decode(trade.data, (uint256, uint64, uint64));
    assertEq(callback.chainId, BASE);
    assertEq(callback.recipient, address(gate));
    assertEq(callback.gasLimit, CALLBACK_GAS_LIMIT);
    assertGe(callback.gasLimit, 350_000);
    // The recorded position comes from the small local swap receipt.
    // forge-lint: disable-next-line(unsafe-typecast)
    uint32 logIndex = uint32(trade.logIndex);
    assertEq(
      callback.payload,
      abi.encodeCall(
        BorrowGate.onWitnessVerdict,
        (address(0), requestId, revision, price, tradedAt, seq, fresh, bytes32(trade.txHash), logIndex)
      )
    );
  }

  function _assertHold(uint256 index, bytes32 requestId, uint64 deadline, uint32 revision, uint32 seen) private view {
    SecondWitnessReactive.HoldSlot memory slot = witness.holdSlot(index);
    assertTrue(slot.active);
    assertEq(slot.requestId, requestId);
    assertEq(slot.deadline, deadline);
    assertEq(slot.revision, revision);
    assertEq(slot.tradesSeenSinceHold, seen);
  }

  function _assertRequest(bytes32 id, BorrowGate.Status status, uint32 revision, uint256 disbursed) private view {
    BorrowGate.Request memory request = gate.requestState(id);
    assertEq(uint8(request.status), uint8(status));
    assertEq(request.lastRevision, revision);
    assertEq(request.disbursedAmount, disbursed);
  }
}
