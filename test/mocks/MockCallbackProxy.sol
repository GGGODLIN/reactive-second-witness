// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

contract MockCallbackProxy {
  uint64 private constant OVERHEAD = 130_000;

  function deliver(address recipient, uint64 gasLimit, address callbackSender, bytes memory payload) external {
    // Omni replaces the first ABI argument while preserving the selector and all trailing arguments.
    assembly ("memory-safe") {
      mstore(add(payload, 36), callbackSender)
    }
    (bool success, bytes memory reason) = recipient.call{gas: gasLimit - OVERHEAD}(payload);
    if (!success) {
      assembly ("memory-safe") {
        revert(add(reason, 32), mload(reason))
      }
    }
  }
}
