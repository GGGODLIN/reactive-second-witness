// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";
import {BorrowGate} from "../src/BorrowGate.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {SpotPool} from "../src/SpotPool.sol";
import {SecondWitnessOracle as Oracle} from "./SecondWitnessOracle.sol";
import {MockCallbackProxy} from "./mocks/MockCallbackProxy.sol";

contract SecondWitnessHandler is Test {
  uint256 private constant SPOT = 2000e18;
  uint256 private constant SMALL = 10e6;
  uint256 private constant STARTING_CASH = 400e6;
  address private constant WITNESS = address(0xBAD5EED);

  address[2] private actors = [address(0xA11CE), address(0xB0B)];
  mapping(address => Oracle.Ledger) private shadow;
  mapping(bytes32 => BorrowGate.Request) private requests;
  bytes32[] private ids;
  uint256 private modelCash = STARTING_CASH;
  uint256 private modelPending;
  Oracle.VerdictStep private lastVerdict;

  MockERC20 private immutable eth;
  MockERC20 private immutable usdc;
  BorrowGate private immutable gate;
  MockCallbackProxy private immutable proxy;

  constructor() {
    vm.warp(1000);
    eth = new MockERC20("Mock Ether", "mETH", 18);
    usdc = new MockERC20("Mock USDC", "mUSDC", 6);
    SpotPool spot = new SpotPool(eth, usdc);
    proxy = new MockCallbackProxy();
    gate = new BorrowGate(IPayable(payable(address(proxy))), WITNESS, spot, SMALL, 30, 15, 2, 300);
    eth.mint(address(this), 1 ether);
    usdc.mint(address(this), 2000e6);
    eth.approve(address(spot), type(uint256).max);
    usdc.approve(address(spot), type(uint256).max);
    spot.addLiquidity(1 ether, 2000e6);
    usdc.mint(address(gate), STARTING_CASH);
    for (uint256 i; i < actors.length; ++i) {
      address actor = actors[i];
      eth.mint(actor, 10 ether);
      usdc.mint(actor, 100e6);
      shadow[actor] = Oracle.Ledger(0, 0, 0, 0, 10 ether, 100e6);
      vm.startPrank(actor);
      eth.approve(address(gate), type(uint256).max);
      usdc.approve(address(gate), type(uint256).max);
      vm.stopPrank();
    }
    deposit(0, 1 ether - 1);
    deposit(1, 1 ether - 1);
  }

  modifier checked() {
    _;
    assertProperties();
  }

  function deposit(uint256 who, uint256 seed) public checked {
    address actor = _actor(who);
    Oracle.Ledger storage model = shadow[actor];
    uint256 amount = _min(seed % 1 ether + 1, model.ethBalance);
    vm.prank(actor);
    gate.depositCollateral(amount);
    model.collateral += amount;
    model.ethBalance -= amount;
  }

  function withdraw(uint256 who, uint256 seed) external checked {
    address actor = _actor(who);
    Oracle.Ledger storage model = shadow[actor];
    uint256 available = _free(model);
    uint256 amount = seed % 4 == 0 ? available + 1 : _min(seed % 0.5 ether + 1, available);
    vm.prank(actor);
    if (amount > available) {
      vm.expectRevert(BorrowGate.InsufficientCollateral.selector);
      gate.withdrawCollateral(amount);
    } else {
      gate.withdrawCollateral(amount);
      model.collateral -= amount;
      model.ethBalance += amount;
    }
  }

  function borrow(uint256 who, uint256 seed) external checked {
    address actor = _actor(who);
    Oracle.Ledger storage model = shadow[actor];
    uint256 amount = seed % 5 == 0 ? SMALL + 1 : seed % SMALL + 1;
    uint256 available = _free(model);
    uint256 lock = Oracle.minimumCollateral(amount, SPOT, available);
    vm.prank(actor);
    if (amount > SMALL) {
      vm.expectRevert(BorrowGate.UseAsyncRequestBorrow.selector);
      gate.borrow(amount);
    } else if (lock > available) {
      vm.expectRevert(BorrowGate.InsufficientCollateral.selector);
      gate.borrow(amount);
    } else if (amount > modelCash) {
      vm.expectRevert(MockERC20.InsufficientBalance.selector);
      gate.borrow(amount);
    } else {
      gate.borrow(amount);
      model.active += lock;
      _credit(model, amount);
    }
  }

  function request(uint256 who, uint256 seed, uint256 minSeed, uint256 ttlSeed) external checked {
    address actor = _actor(who);
    Oracle.Ledger storage model = shadow[actor];
    uint256 amount = SMALL + 1 + seed % 120e6;
    uint256 minimum = minSeed % 3 == 0 ? 0 : minSeed % (amount + 1);
    uint256 now_ = vm.getBlockTimestamp();
    uint64 deadline = _boundedTime(now_ + 1 + ttlSeed % 300);
    uint256 available = _free(model);
    uint256 reserve = Oracle.minimumCollateral(amount, SPOT, available);
    vm.prank(actor);
    if (modelPending == 4) {
      vm.expectRevert(BorrowGate.HoldLimitReached.selector);
      gate.requestBorrow(amount, minimum, deadline);
    } else if (reserve > available) {
      vm.expectRevert(BorrowGate.InsufficientCollateral.selector);
      gate.requestBorrow(amount, minimum, deadline);
    } else {
      bytes32 id = gate.requestBorrow(amount, minimum, deadline);
      assertTrue(requests[id].status == BorrowGate.Status.NONE && id != bytes32(0), "unique request identity");
      ids.push(id);
      requests[id] = BorrowGate.Request({
        borrower: actor,
        requestedAmount: amount,
        minAcceptableAmount: minimum,
        reservedCollateral: reserve,
        disbursedAmount: 0,
        keptCollateral: 0,
        lastEffectivePrice: 0,
        createdAt: _boundedTime(now_),
        deadline: deadline,
        lastRevision: 0,
        status: BorrowGate.Status.PENDING
      });
      model.pending += reserve;
      ++modelPending;
    }
  }

  function verdict(uint256 key, uint256 revisionMode, uint256 priceSeed, uint256 ageMode) external checked {
    bytes32 id = _pick(key);
    BorrowGate.Request storage model = requests[id];
    Oracle.VerdictStep memory step;
    step.revision = _revision(model.lastRevision, revisionMode);
    step.timestamp = vm.getBlockTimestamp();
    uint64 tradedAt = _witnessTime(step.timestamp, ageMode);
    step.firstFresh = tradedAt > 15 ? tradedAt - 15 : 0;
    step.lastFresh = uint256(tradedAt) + 30;
    uint256 priceMode = priceSeed % 5;
    if (priceMode == 1) step.price = type(uint256).max;
    else if (priceMode == 2) step.price = 1;
    else if (priceMode >= 3) step.price = 1 + priceSeed % 2400e18;

    step.beforeRequest = gate.requestState(id);
    step.debtBefore = gate.totalDebt(model.borrower);
    step.balanceBefore = usdc.balanceOf(model.borrower);
    proxy.deliver(
      address(gate),
      350_000,
      WITNESS,
      abi.encodeCall(
        BorrowGate.onWitnessVerdict,
        (address(0), id, step.revision, step.price, tradedAt, 1, priceMode % 2 == 0 ? 0 : 2, bytes32(0), 0)
      )
    );
    step.afterRequest = gate.requestState(id);
    step.debtAfter = gate.totalDebt(model.borrower);
    step.balanceAfter = usdc.balanceOf(model.borrower);
    lastVerdict = step;
    _modelVerdict(model, step);
  }

  function cancel(uint256 key, uint256 mode) external checked {
    bytes32 id = _pick(key);
    BorrowGate.Request storage model = requests[id];
    address actor = mode % 3 == 0 ? _actor(mode) : model.borrower;
    vm.prank(actor);
    if (!_open(model.status)) {
      vm.expectRevert(BorrowGate.RequestNotOpen.selector);
      gate.cancelRequest(id);
    } else if (actor != model.borrower) {
      vm.expectRevert(BorrowGate.NotBorrower.selector);
      gate.cancelRequest(id);
    } else {
      gate.cancelRequest(id);
      _closeEarly(model, BorrowGate.Status.CANCELLED);
    }
  }

  function expire(uint256 who, uint256 key) external checked {
    bytes32 id = _pick(key);
    BorrowGate.Request storage model = requests[id];
    vm.prank(_actor(who));
    if (!_open(model.status)) {
      vm.expectRevert(BorrowGate.RequestNotOpen.selector);
      gate.expireRequest(id);
    } else if (vm.getBlockTimestamp() < model.deadline) {
      vm.expectRevert(BorrowGate.NotExpired.selector);
      gate.expireRequest(id);
    } else {
      gate.expireRequest(id);
      _closeEarly(model, BorrowGate.Status.EXPIRED);
    }
  }

  function repay(uint256 who, uint256 seed) external checked {
    address actor = _actor(who);
    Oracle.Ledger storage model = shadow[actor];
    uint256 ceiling = _min(model.debt, model.usdcBalance);
    uint256 amount = seed % 5 == 0 ? model.debt + 1 : (seed % 3 == 0 ? ceiling : seed % (ceiling + 1));
    vm.prank(actor);
    if (amount > model.debt) {
      vm.expectRevert(BorrowGate.InvalidAmount.selector);
      gate.repay(amount);
    } else {
      gate.repay(amount);
      uint256 remaining = model.debt - amount;
      // Independent form: ceil(active * remaining / debt) is the still-locked share.
      model.active = remaining == 0 ? 0 : (model.active * remaining + model.debt - 1) / model.debt;
      model.debt = remaining;
      model.usdcBalance -= amount;
      modelCash += amount;
    }
  }

  function warp(uint256 secondsSeed) external checked {
    vm.warp(vm.getBlockTimestamp() + secondsSeed % 151);
  }

  function assertProperties() public view {
    uint256 deposits;
    for (uint256 i; i < actors.length; ++i) {
      address actor = actors[i];
      Oracle.Ledger memory actual = _readLedger(actor);
      Oracle.Ledger memory expected = shadow[actor];
      assertTrue(Oracle.p1(actual), "P1 collateral conservation");
      assertTrue(Oracle.p6(lastVerdict.beforeRequest, actual.active, expected.active), "P6 active ledger");
      assertEq(abi.encode(actual), abi.encode(expected), "independent borrower ledger and token balances");
      assertEq(gate.freeCollateral(actor), _free(expected), "free collateral");
      deposits += expected.collateral;
    }
    assertEq(eth.balanceOf(address(gate)), deposits, "gate collateral balance");
    assertEq(usdc.balanceOf(address(gate)), modelCash, "gate liquidity balance");
    assertEq(gate.activePendingCount(), modelPending, "global open requests");
    assertTrue(Oracle.p3(lastVerdict), "P3 stale callbacks cannot disburse");
    assertTrue(Oracle.p4(lastVerdict), "P4 older or equal revisions are no-ops");
    assertTrue(Oracle.p5(lastVerdict.beforeRequest, lastVerdict.afterRequest), "P5 callback on closed request");
    for (uint256 i; i < ids.length; ++i) {
      BorrowGate.Request memory actual = gate.requestState(ids[i]);
      BorrowGate.Request memory expected = requests[ids[i]];
      assertTrue(Oracle.p2(actual), "P2 bounded and min-acceptable");
      assertTrue(Oracle.p5(expected, actual), "P5 closed request snapshots remain immutable");
      assertTrue(
        Oracle.p6(actual, gate.lockedForActiveDebt(actual.borrower), shadow[expected.borrower].active),
        "P6 coverage at close and active ledger"
      );
      assertTrue(Oracle.sameRequest(expected, actual), "independent request state");
    }
  }

  function _modelVerdict(BorrowGate.Request storage req, Oracle.VerdictStep memory step) private {
    if (_open(req.status) && step.timestamp < req.deadline && step.revision > req.lastRevision) {
      req.lastRevision = step.revision;
      req.status = BorrowGate.Status.HELD;
      if (Oracle.isFresh(step)) {
        uint256 price = _min(SPOT, step.price);
        uint256 approved = Oracle.maximumLoan(req.reservedCollateral, price, req.requestedAmount);
        if (approved >= req.minAcceptableAmount && approved > req.disbursedAmount) {
          uint256 delta = approved - req.disbursedAmount;
          if (delta <= modelCash) {
            _credit(shadow[req.borrower], delta);
            req.disbursedAmount = approved;
            req.lastEffectivePrice = price;
            if (approved == req.requestedAmount) _close(req, BorrowGate.Status.SETTLED, req.reservedCollateral);
          }
        }
      }
    }
  }

  function _closeEarly(BorrowGate.Request storage req, BorrowGate.Status status) private {
    uint256 kept = Oracle.minimumCollateral(req.disbursedAmount, req.lastEffectivePrice, req.reservedCollateral);
    _close(req, status, kept);
  }

  function _close(BorrowGate.Request storage req, BorrowGate.Status status, uint256 kept) private {
    Oracle.Ledger storage model = shadow[req.borrower];
    model.pending -= req.reservedCollateral;
    model.active += kept;
    --modelPending;
    req.status = status;
    req.keptCollateral = kept;
  }

  function _credit(Oracle.Ledger storage model, uint256 amount) private {
    model.debt += amount;
    model.usdcBalance += amount;
    modelCash -= amount;
  }

  function _readLedger(address actor) private view returns (Oracle.Ledger memory) {
    return Oracle.Ledger({
      collateral: gate.totalCollateral(actor),
      active: gate.lockedForActiveDebt(actor),
      pending: gate.lockedForPendingRequests(actor),
      debt: gate.totalDebt(actor),
      ethBalance: eth.balanceOf(actor),
      usdcBalance: usdc.balanceOf(actor)
    });
  }

  function _pick(uint256 seed) private view returns (bytes32) {
    if (ids.length == 0 || seed % 11 == 0) return bytes32(0);
    if (seed % 3 == 0) return ids[ids.length - 1];
    return ids[seed % ids.length];
  }

  function _actor(uint256 seed) private view returns (address) {
    return actors[seed % actors.length];
  }

  function _witnessTime(uint256 now_, uint256 seed) private pure returns (uint64) {
    uint256 mode = seed % 6;
    if (mode == 0) return _boundedTime(now_ - 31);
    if (mode == 1) return _boundedTime(now_ + 16);
    if (mode == 2) return _boundedTime(now_ - 30);
    if (mode == 3) return _boundedTime(now_ + 15);
    return _boundedTime(now_);
  }

  function _boundedTime(uint256 timestamp) private pure returns (uint64) {
    require(timestamp <= type(uint64).max);
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint64(timestamp);
  }

  function _revision(uint32 latest, uint256 seed) private pure returns (uint32) {
    if (seed % 5 == 0) return latest;
    if (seed % 5 == 1 && latest != 0) return latest - 1;
    return latest + 1;
  }

  function _free(Oracle.Ledger memory model) private pure returns (uint256) {
    return model.collateral - model.active - model.pending;
  }

  function _open(BorrowGate.Status status) private pure returns (bool) {
    return status == BorrowGate.Status.PENDING || status == BorrowGate.Status.HELD;
  }

  function _min(uint256 a, uint256 b) private pure returns (uint256) {
    return a < b ? a : b;
  }
}

contract SecondWitnessInvariantTest is StdInvariant, Test {
  SecondWitnessHandler private handler;

  function setUp() public {
    handler = new SecondWitnessHandler();
    bytes4[] memory selectors = new bytes4[](9);
    selectors[0] = SecondWitnessHandler.deposit.selector;
    selectors[1] = SecondWitnessHandler.withdraw.selector;
    selectors[2] = SecondWitnessHandler.borrow.selector;
    selectors[3] = SecondWitnessHandler.request.selector;
    selectors[4] = SecondWitnessHandler.verdict.selector;
    selectors[5] = SecondWitnessHandler.cancel.selector;
    selectors[6] = SecondWitnessHandler.expire.selector;
    selectors[7] = SecondWitnessHandler.repay.selector;
    selectors[8] = SecondWitnessHandler.warp.selector;
    targetContract(address(handler));
    targetSelector(FuzzSelector(address(handler), selectors));
  }

  /// forge-config: default.invariant.runs = 256
  /// forge-config: default.invariant.depth = 32
  /// forge-config: default.invariant.fail-on-revert = true
  function invariant_P1ThroughP6AndIndependentOracle() public view {
    handler.assertProperties();
  }
}
