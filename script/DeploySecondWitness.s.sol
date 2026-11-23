// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";
import {BorrowGate} from "../src/BorrowGate.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {ReferencePoolWitness} from "../src/ReferencePoolWitness.sol";
import {SecondWitnessReactive} from "../src/SecondWitnessReactive.sol";
import {SpotPool} from "../src/SpotPool.sol";
import {UnprotectedLendingMock} from "../src/UnprotectedLendingMock.sol";

interface IReserveVault is IPayable {
  function depositTo(address) external payable;
}

contract DeploySecondWitness is Script {
  uint256 private constant UNICHAIN_SEPOLIA = 1_301;
  uint256 private constant BASE_SEPOLIA = 84_532;
  uint256 private constant REACTIVE_LASNA = 5_318_007;
  address private constant BASE_CALLBACK_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;

  uint256 private constant INITIAL_POOL_ETH = 100e18;
  uint256 private constant INITIAL_POOL_USDC = 200_000e6;
  uint256 private constant SMALL_BORROW_LIMIT = 500e6;
  uint64 private constant MAX_EVIDENCE_AGE = 30;
  uint64 private constant MAX_CLOCK_SKEW = 15;
  uint32 private constant REQUIRED_FRESH_TRADES = 2;
  uint64 private constant MAX_REQUEST_TTL = 300;
  uint64 private constant CALLBACK_GAS_LIMIT = 400_000;

  function deployUnichain() external {
    _selectChain("UNICHAIN_SEPOLIA_RPC", UNICHAIN_SEPOLIA);
    uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(pk);
    vm.startBroadcast(pk);
    MockERC20 eth = new MockERC20("Mock ETH", "mETH", 18);
    MockERC20 usdc = new MockERC20("Mock USDC", "mUSDC", 6);
    ReferencePoolWitness refPool = new ReferencePoolWitness(eth, usdc);

    eth.mint(deployer, 500e18);
    usdc.mint(deployer, 1_000_000e6);
    eth.approve(address(refPool), type(uint256).max);
    usdc.approve(address(refPool), type(uint256).max);
    refPool.addLiquidity(INITIAL_POOL_ETH, INITIAL_POOL_USDC);
    // Initial small swap establishes tradeSeq == 1 around $2,000/mETH
    refPool.swapUsdcForEth(200e6, 1);
    vm.stopBroadcast();

    console2.log("UNICHAIN_METH", address(eth));
    console2.log("UNICHAIN_MUSDC", address(usdc));
    console2.log("REFERENCE_POOL_WITNESS", address(refPool));
  }

  function deployBasePools() external {
    _selectChain("BASE_SEPOLIA_RPC", BASE_SEPOLIA);
    uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address deployer = vm.addr(pk);
    vm.startBroadcast(pk);
    MockERC20 eth = new MockERC20("Mock ETH", "mETH", 18);
    MockERC20 usdc = new MockERC20("Mock USDC", "mUSDC", 6);
    SpotPool spotPool = new SpotPool(eth, usdc);
    UnprotectedLendingMock unprotected = new UnprotectedLendingMock(spotPool);

    eth.mint(deployer, 500e18);
    usdc.mint(deployer, 2_000_000e6);
    usdc.mint(address(unprotected), 100_000e6);
    eth.approve(address(spotPool), type(uint256).max);
    usdc.approve(address(spotPool), type(uint256).max);
    eth.approve(address(unprotected), type(uint256).max);
    spotPool.addLiquidity(INITIAL_POOL_ETH, INITIAL_POOL_USDC);
    vm.stopBroadcast();

    console2.log("BASE_METH", address(eth));
    console2.log("BASE_MUSDC", address(usdc));
    console2.log("SPOT_POOL", address(spotPool));
    console2.log("UNPROTECTED_LENDING_MOCK", address(unprotected));
  }

  function deployLasnaReactive(address referencePool) external {
    require(referencePool != address(0), "Missing referencePool");
    _selectChain("REACTIVE_LASNA_RPC", REACTIVE_LASNA);
    uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    uint256 funding = vm.envUint("LASNA_FUND_WEI");
    require(funding != 0, "Missing LASNA_FUND_WEI");
    vm.startBroadcast(pk);
    SecondWitnessReactive reactive = new SecondWitnessReactive{value: funding}(
      UNICHAIN_SEPOLIA, referencePool, BASE_SEPOLIA, REQUIRED_FRESH_TRADES, CALLBACK_GAS_LIMIT
    );
    IReserveVault(payable(0x8888888888888888888888888888888888888888)).depositTo{value: funding}(address(reactive));
    vm.stopBroadcast();
    require(
      IReserveVault(payable(0x8888888888888888888888888888888888888888)).debt(address(reactive)) == 0,
      "Non-zero Lasna debt"
    );
    console2.log("SECOND_WITNESS_REACTIVE", address(reactive));
  }

  function deployBaseGate(address reactive, address spotPoolAddr) external {
    require(reactive != address(0) && spotPoolAddr != address(0), "Missing dependency");
    _selectChain("BASE_SEPOLIA_RPC", BASE_SEPOLIA);
    uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    uint256 funding = vm.envUint("BASE_GATE_FUND_WEI");
    require(funding != 0, "Missing BASE_GATE_FUND_WEI");
    SpotPool pool = SpotPool(spotPoolAddr);
    MockERC20 baseEth = pool.mETH();
    MockERC20 baseUsdc = pool.mUSDC();
    vm.startBroadcast(pk);
    BorrowGate gate = new BorrowGate(
      IPayable(payable(BASE_CALLBACK_PROXY)),
      reactive,
      pool,
      SMALL_BORROW_LIMIT,
      MAX_EVIDENCE_AGE,
      MAX_CLOCK_SKEW,
      REQUIRED_FRESH_TRADES,
      MAX_REQUEST_TTL
    );
    (bool funded,) = payable(address(gate)).call{value: funding}("");
    require(funded, "Funding BorrowGate failed");
    IReserveVault(payable(BASE_CALLBACK_PROXY)).depositTo{value: funding}(address(gate));
    baseUsdc.mint(address(gate), 500_000e6);
    baseEth.approve(address(gate), type(uint256).max);
    baseUsdc.approve(address(gate), type(uint256).max);
    gate.depositCollateral(100e18);
    vm.stopBroadcast();
    require(baseUsdc.balanceOf(address(gate)) >= 500_000e6, "Gate liquidity not funded");
    require(IReserveVault(payable(BASE_CALLBACK_PROXY)).debt(address(gate)) == 0, "Non-zero Base debt");
    console2.log("BORROW_GATE", address(gate));
  }

  function wireBorrowGate(address reactive, address gate) external {
    require(reactive != address(0) && gate != address(0), "Missing addresses");
    _selectChain("REACTIVE_LASNA_RPC", REACTIVE_LASNA);
    uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    vm.startBroadcast(pk);
    SecondWitnessReactive(payable(reactive)).configureBorrowGate(gate);
    vm.stopBroadcast();
    console2.log("WIRED_BORROW_GATE", gate);
  }

  function _selectChain(string memory rpcEnv, uint256 expectedChainId) private {
    vm.createSelectFork(vm.envString(rpcEnv));
    require(vm.getChainId() == expectedChainId, "Unexpected chain ID");
  }
}
