// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Math512} from "./Math512.sol";
import {MockERC20} from "./MockERC20.sol";
import {SpotPool} from "./SpotPool.sol";

/// @notice Baseline single-chain spot-priced lending contract used strictly for side-by-side
///         testnet comparison against BorrowGate during SpotPool price manipulation demos.
contract UnprotectedLendingMock {
  error InvalidAmount();
  error InsufficientCollateral();
  error InsufficientLiquidity();
  error UnavailablePrice();
  error TransferFailed();

  uint256 public constant LTV_BPS = 8000;
  uint256 private constant LTV_SCALE = (1e30 * 10_000) / LTV_BPS;

  SpotPool public immutable spotPool;
  MockERC20 public immutable mETH;
  MockERC20 public immutable mUSDC;

  mapping(address => uint256) public collateral;
  mapping(address => uint256) public debt;

  constructor(SpotPool spotPool_) {
    spotPool = spotPool_;
    mETH = spotPool_.mETH();
    mUSDC = spotPool_.mUSDC();
  }

  function depositCollateral(uint256 amount) external {
    if (amount == 0) revert InvalidAmount();
    collateral[msg.sender] += amount;
    if (!mETH.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
  }

  function borrow(uint256 amount) external {
    if (amount == 0) revert InvalidAmount();
    uint256 price = spotPool.priceE18();
    if (price == 0) revert UnavailablePrice();
    uint256 maxBorrow = Math512.mulDiv(collateral[msg.sender], price, LTV_SCALE);
    uint256 nextDebt = debt[msg.sender] + amount;
    if (nextDebt > maxBorrow) revert InsufficientCollateral();
    if (mUSDC.balanceOf(address(this)) < amount) revert InsufficientLiquidity();
    debt[msg.sender] = nextDebt;
    if (!mUSDC.transfer(msg.sender, amount)) revert TransferFailed();
  }
}
