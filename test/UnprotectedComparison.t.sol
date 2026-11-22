// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";
import {BorrowGate} from "../src/BorrowGate.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {ReferencePoolWitness} from "../src/ReferencePoolWitness.sol";
import {SpotPool} from "../src/SpotPool.sol";
import {UnprotectedLendingMock} from "../src/UnprotectedLendingMock.sol";
import {MockCallbackProxy} from "./mocks/MockCallbackProxy.sol";

contract UnprotectedComparisonTest is Test {
  MockERC20 private eth;
  MockERC20 private usdc;
  SpotPool private spotPool;
  ReferencePoolWitness private refPool;
  UnprotectedLendingMock private naiveLender;
  BorrowGate private gate;
  MockCallbackProxy private proxy;

  address private constant REACTIVE = address(0xBEEF);
  address private constant TRADER = address(0xA11CE);

  function setUp() external {
    vm.warp(1_700_000_000);
    eth = new MockERC20("Mock ETH", "mETH", 18);
    usdc = new MockERC20("Mock USDC", "mUSDC", 6);
    spotPool = new SpotPool(eth, usdc);
    refPool = new ReferencePoolWitness(eth, usdc);
    proxy = new MockCallbackProxy();
    naiveLender = new UnprotectedLendingMock(spotPool);
    gate = new BorrowGate(IPayable(payable(address(proxy))), REACTIVE, spotPool, 500e6, 30, 15, 2, 300);

    // Seed both pools at $2,000 / mETH (100 mETH : 200,000 mUSDC)
    eth.mint(address(this), 200e18);
    usdc.mint(address(this), 400_000e6);
    eth.approve(address(spotPool), 100e18);
    usdc.approve(address(spotPool), 200_000e6);
    spotPool.addLiquidity(100e18, 200_000e6);
    eth.approve(address(refPool), 100e18);
    usdc.approve(address(refPool), 200_000e6);
    refPool.addLiquidity(100e18, 200_000e6);

    // Fund both lending pools with 50,000 mUSDC liquidity
    usdc.mint(address(naiveLender), 50_000e6);
    usdc.mint(address(gate), 50_000e6);

    // Fund trader with 1 mETH per lender + USDC to execute a real 5x spot swap
    eth.mint(TRADER, 2e18);
    usdc.mint(TRADER, 300_000e6);
  }

  function test_fiveXSpotSwapDrainsNaiveLenderWhileBorrowGateBlocksAndCaps() external {
    // 1. Real large swap inflates Base SpotPool price > 5x (~$10,000/mETH) while Unichain stays at ~$2,000/mETH
    vm.startPrank(TRADER);
    usdc.approve(address(spotPool), 250_000e6);
    spotPool.swapUsdcForEth(250_000e6, 1);
    uint256 inflatedSpot = spotPool.priceE18();
    assertGt(inflatedSpot, 10_000e18);
    assertEq(refPool.priceE18(), 2_000e18);

    // 2. With 1 mETH collateral (~$2,000 fair value -> $1,600 fair LTV), naive single-chain lender pays $8,000 in 1 tx
    eth.approve(address(naiveLender), 1e18);
    naiveLender.depositCollateral(1e18);
    uint256 beforeNaive = usdc.balanceOf(TRADER);
    naiveLender.borrow(8_000e6);
    assertEq(usdc.balanceOf(TRADER) - beforeNaive, 8_000e6);
    assertEq(naiveLender.debt(TRADER), 8_000e6);

    // 3. Same 1 mETH on BorrowGate requesting $8,000 (strict minAcceptable = $8,000) is blocked (0 disbursed)
    eth.approve(address(gate), 1e18);
    gate.depositCollateral(1e18);
    bytes32 reqId = gate.requestBorrow(8_000e6, 8_000e6, uint64(block.timestamp + 120));
    vm.stopPrank();

    uint256 beforeGate = usdc.balanceOf(TRADER);
    bytes memory payload = abi.encodeCall(
      BorrowGate.onWitnessVerdict,
      (address(0), reqId, 1, refPool.priceE18(), uint64(block.timestamp), 1, 1, bytes32(uint256(1)), 0)
    );
    proxy.deliver(address(gate), 350_000, REACTIVE, payload);

    assertEq(usdc.balanceOf(TRADER), beforeGate);
    BorrowGate.Request memory state = gate.requestState(reqId);
    assertEq(state.disbursedAmount, 0);
    assertEq(uint8(state.status), uint8(BorrowGate.Status.HELD));
  }
}
