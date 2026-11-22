// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";

contract MockSystemContract {
  bytes public subscription;
  address public requestingContract;
  ISystemContract.CallbackConfiguration_V_1_0 private request;

  function subscribe(uint256 chainId, address origin, uint256 topic0, uint256 topic1, uint256 topic2, uint256 topic3)
    external
  {
    subscription = abi.encode(msg.sender, chainId, origin, topic0, topic1, topic2, topic3);
  }

  function react(IReactive reactiveContract, IReactive.LogRecord calldata log) external {
    reactiveContract.react(log);
  }

  function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 calldata config) external {
    requestingContract = msg.sender;
    request = config;
  }

  function callbackRequest() external view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) {
    return request;
  }
}
