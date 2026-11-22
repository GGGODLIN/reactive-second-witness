// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

contract ProbeOrigin {
  event Ping(uint256 indexed pingId);

  uint256 private pingId;
  address private immutable operator = msg.sender;

  error NotOperator();

  function emitPing() external {
    // Each ping can spend the balances funding both chains.
    if (msg.sender != operator) revert NotOperator();
    emit Ping(++pingId);
  }
}
