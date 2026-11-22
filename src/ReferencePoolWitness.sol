// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {MockERC20} from "./MockERC20.sol";
import {SpotPool} from "./SpotPool.sol";

contract ReferencePoolWitness is SpotPool {
  error TimestampOverflow();

  event ReferenceTrade(uint256 priceE18, uint64 tradedAt, uint64 tradeSeq);

  uint64 public tradeSeq;

  constructor(MockERC20 eth, MockERC20 usdc) SpotPool(eth, usdc) {}

  function _afterSwap() internal override {
    uint256 timestamp = block.timestamp;
    // The witness ABI cannot encode a timestamp outside uint64.
    // forge-lint: disable-next-line(block-timestamp)
    if (timestamp > type(uint64).max) revert TimestampOverflow();
    // forge-lint: disable-next-line(unsafe-typecast)
    emit ReferenceTrade(priceE18(), uint64(timestamp), ++tradeSeq);
  }
}
