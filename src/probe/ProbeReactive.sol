// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib-omni/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";
import {ProbeOrigin} from "./ProbeOrigin.sol";
import {ProbeReceiver} from "./ProbeReceiver.sol";

contract ProbeReactive is AbstractReactive {
  uint256 private constant BASE_SEPOLIA = 84_532;
  uint64 private constant CALLBACK_GAS_LIMIT = 350_000;

  uint256 private immutable pingTopic = uint256(ProbeOrigin.Ping.selector);
  address private immutable owner = msg.sender;
  address private immutable origin;
  address private receiver;

  error NotOwner();
  error InvalidOrigin();
  error InvalidReceiver();
  error AlreadySubscribed();

  event PingRelayed(uint256 indexed pingId);

  constructor(address pingOrigin) payable {
    if (pingOrigin == address(0)) revert InvalidOrigin();
    origin = pingOrigin;
  }

  function subscribeToPing(address callbackReceiver) external {
    if (msg.sender != owner) revert NotOwner();
    if (callbackReceiver == address(0)) revert InvalidReceiver();
    if (receiver != address(0)) revert AlreadySubscribed();

    // The receiver needs this contract's address before it can authenticate a callback.
    receiver = callbackReceiver;
    SYSTEM.subscribe(BASE_SEPOLIA, origin, pingTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
  }

  function react(LogRecord calldata log) external override onlySystem {
    if (
      receiver == address(0) || log.chainId != BASE_SEPOLIA || log.contractAddress != origin || log.topic0 != pingTopic
    ) {
      return;
    }

    // The relay event rolls back if SYSTEM rejects the request.
    emit PingRelayed(log.topic1);
    // Omni fills the first argument with the Reactive contract's address.
    SYSTEM.requestCallbackV_1_0(
      ISystemContract.CallbackConfiguration_V_1_0({
        chainId: BASE_SEPOLIA,
        recipient: receiver,
        gasLimit: CALLBACK_GAS_LIMIT,
        payload: abi.encodeCall(ProbeReceiver.onPong, (address(0), log.topic1))
      })
    );
  }
}
