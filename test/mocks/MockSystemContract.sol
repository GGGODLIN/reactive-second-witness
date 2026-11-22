// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";

contract MockSystemContract {
  uint256 private constant HEADER_SIZE = 60;
  address public requestingContract;
  bytes[] private subscriptions;
  address[] private callbacks;

  function subscribe(uint256 chainId, address origin, uint256 topic0, uint256 topic1, uint256 topic2, uint256 topic3)
    external
  {
    subscriptions.push(abi.encode(msg.sender, chainId, origin, topic0, topic1, topic2, topic3));
  }

  function subscription() external view returns (bytes memory) {
    return subscriptions.length == 0 ? bytes("") : subscriptions[subscriptions.length - 1];
  }

  function subscriptionCount() external view returns (uint256) {
    return subscriptions.length;
  }

  function subscriptionAt(uint256 index) external view returns (bytes memory) {
    return subscriptions[index];
  }

  function react(IReactive reactiveContract, IReactive.LogRecord calldata log) external {
    reactiveContract.react(log);
  }

  function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 calldata config) external {
    requestingContract = msg.sender;
    bytes memory data = abi.encodePacked(config.chainId, config.recipient, config.gasLimit, config.payload);
    callbacks.push(address(new RecordedCallback(data)));
  }

  function callbackRequest() external view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) {
    if (callbacks.length == 0) return ISystemContract.CallbackConfiguration_V_1_0(0, address(0), 0, "");
    return callbackRequestAt(callbacks.length - 1);
  }

  function callbackRequestCount() external view returns (uint256) {
    return callbacks.length;
  }

  function callbackRequestAt(uint256 index) public view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) {
    address record = callbacks[index];
    uint256 payloadOffset = 1 + HEADER_SIZE;
    bytes memory payload = new bytes(record.code.length - payloadOffset);
    uint256 chainId;
    address recipient;
    uint64 gasLimit;
    // The packed header is 32 bytes of chain ID, 20 of address and 8 of gas limit, after the STOP byte.
    assembly ("memory-safe") {
      extcodecopy(record, 0, 1, HEADER_SIZE)
      chainId := mload(0)
      recipient := shr(96, mload(32))
      gasLimit := and(shr(32, mload(32)), 0xffffffffffffffff)
      extcodecopy(record, add(payload, 32), payloadOffset, mload(payload))
    }
    return ISystemContract.CallbackConfiguration_V_1_0(chainId, recipient, gasLimit, payload);
  }

  function clearCallbackRequests() external {
    delete callbacks;
    delete requestingContract;
  }
}

// Store immutable mock payloads as code so per-word storage writes do not dominate the fan-out measurement.
contract RecordedCallback {
  constructor(bytes memory data) {
    bytes memory runtime = bytes.concat(hex"00", data);
    assembly ("memory-safe") {
      return(add(runtime, 32), mload(runtime))
    }
  }
}
