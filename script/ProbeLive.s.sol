// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";
import {ProbeOrigin} from "../src/probe/ProbeOrigin.sol";
import {ProbeReactive} from "../src/probe/ProbeReactive.sol";
import {ProbeReceiver} from "../src/probe/ProbeReceiver.sol";

contract ProbeLive is Script {
  uint256 private constant BASE_SEPOLIA = 84_532;
  uint256 private constant REACTIVE_LASNA = 5_318_007;
  address private constant BASE_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;

  function deployOrigin() external {
    _selectChain("BASE_SEPOLIA_RPC", BASE_SEPOLIA);
    vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
    ProbeOrigin origin = new ProbeOrigin();
    vm.stopBroadcast();
    console2.log("ProbeOrigin", address(origin));
  }

  function deployReactive(address origin) external {
    require(origin != address(0), "Missing origin");
    _selectChain("REACTIVE_LASNA_RPC", REACTIVE_LASNA);
    uint256 funding = vm.envUint("PROBE_LASNA_FUND_WEI");
    require(funding != 0, "Fund ProbeReactive at deployment");
    vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
    ProbeReactive reactiveContract = new ProbeReactive{value: funding}(origin);
    vm.stopBroadcast();
    console2.log("ProbeReactive", address(reactiveContract));
  }

  function deployReceiver(address reactiveContract) external {
    require(reactiveContract != address(0), "Missing Reactive contract");
    _selectChain("BASE_SEPOLIA_RPC", BASE_SEPOLIA);
    require(BASE_PROXY.code.length != 0, "Base proxy has no code");
    uint256 funding = vm.envUint("PROBE_BASE_FUND_WEI");
    require(funding != 0, "Fund ProbeReceiver at deployment");
    vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
    ProbeReceiver receiver = new ProbeReceiver{value: funding}(IPayable(payable(BASE_PROXY)), reactiveContract);
    vm.stopBroadcast();
    console2.log("ProbeReceiver", address(receiver));
  }

  function subscribe(address reactiveContract, address receiver) external {
    _selectChain("BASE_SEPOLIA_RPC", BASE_SEPOLIA);
    require(receiver.code.length != 0, "Receiver has no code on Base Sepolia");
    require(ProbeReceiver(payable(receiver))._CALLBACK_SENDER() == reactiveContract, "Receiver expects another sender");
    _selectChain("REACTIVE_LASNA_RPC", REACTIVE_LASNA);
    require(reactiveContract.code.length != 0, "Reactive contract has no code on Lasna");
    vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
    ProbeReactive(payable(reactiveContract)).subscribeToPing(receiver);
    vm.stopBroadcast();
  }

  function ping(address origin) external {
    _selectChain("BASE_SEPOLIA_RPC", BASE_SEPOLIA);
    require(origin.code.length != 0, "Origin has no code on Base Sepolia");
    vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
    ProbeOrigin(origin).emitPing();
    vm.stopBroadcast();
  }

  function _selectChain(string memory rpcEnv, uint256 chainId) private {
    vm.createSelectFork(vm.envString(rpcEnv));
    require(vm.getChainId() == chainId, "Unexpected RPC chain ID");
  }
}
