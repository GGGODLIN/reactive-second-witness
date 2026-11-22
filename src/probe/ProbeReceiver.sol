// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";

contract ProbeReceiver is AbstractCallback {
  event Pong(uint256 indexed pingId);

  mapping(uint256 => bool) public received;

  constructor(IPayable proxy, address reactiveContract) payable AbstractCallback(proxy, reactiveContract) {}

  function onPong(address callbackSender, uint256 pingId)
    external
    onlyServiceProvider
    onlyCallbackSender(callbackSender)
  {
    received[pingId] = true;
    emit Pong(pingId);
  }
}
