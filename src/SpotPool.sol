// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Math512} from "./Math512.sol";
import {MockERC20} from "./MockERC20.sol";

contract SpotPool {
  error InvalidTokens();
  error InvalidLiquidity();
  error InsufficientOutput();
  error TransferFailed();

  event ReservesUpdated(uint256 reserveEth, uint256 reserveUsdc);

  MockERC20 public immutable mETH;
  MockERC20 public immutable mUSDC;
  uint256 public reserveEth;
  uint256 public reserveUsdc;

  constructor(MockERC20 eth, MockERC20 usdc) {
    if (eth.decimals() != 18 || usdc.decimals() != 6) revert InvalidTokens();
    mETH = eth;
    mUSDC = usdc;
  }

  function priceE18() public view returns (uint256) {
    return reserveEth == 0 ? 0 : Math512.mulDiv(reserveUsdc, 1e30, reserveEth);
  }

  function addLiquidity(uint256 ethAmount, uint256 usdcAmount) external {
    if (ethAmount == 0 || usdcAmount == 0) revert InvalidLiquidity();
    reserveEth = _increasedReserve(reserveEth, ethAmount);
    reserveUsdc = _increasedReserve(reserveUsdc, usdcAmount);
    emit ReservesUpdated(reserveEth, reserveUsdc);
    if (!mETH.transferFrom(msg.sender, address(this), ethAmount)) revert TransferFailed();
    if (!mUSDC.transferFrom(msg.sender, address(this), usdcAmount)) revert TransferFailed();
  }

  function swapUsdcForEth(uint256 amountIn, uint256 minOut) external returns (uint256 amountOut) {
    uint256 nextUsdc = _increasedReserve(reserveUsdc, amountIn);
    amountOut = _swapOutput(amountIn, minOut, nextUsdc, reserveEth);
    reserveUsdc = nextUsdc;
    reserveEth -= amountOut;
    emit ReservesUpdated(reserveEth, reserveUsdc);
    _afterSwap();
    if (!mUSDC.transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();
    if (!mETH.transfer(msg.sender, amountOut)) revert TransferFailed();
  }

  function swapEthForUsdc(uint256 amountIn, uint256 minOut) external returns (uint256 amountOut) {
    uint256 nextEth = _increasedReserve(reserveEth, amountIn);
    amountOut = _swapOutput(amountIn, minOut, nextEth, reserveUsdc);
    reserveEth = nextEth;
    reserveUsdc -= amountOut;
    emit ReservesUpdated(reserveEth, reserveUsdc);
    _afterSwap();
    if (!mETH.transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();
    if (!mUSDC.transfer(msg.sender, amountOut)) revert TransferFailed();
  }

  function _afterSwap() internal virtual {}

  function _increasedReserve(uint256 reserve, uint256 amount) private pure returns (uint256) {
    // Bound the reserves so priceE18 always fits even at the smallest nonzero ETH reserve.
    if (amount > type(uint128).max - reserve) revert InvalidLiquidity();
    return reserve + amount;
  }

  function _swapOutput(uint256 amountIn, uint256 minOut, uint256 nextIn, uint256 reserveOut)
    private
    pure
    returns (uint256 amountOut)
  {
    if (amountIn == 0 || amountIn == nextIn || reserveOut == 0) revert InvalidLiquidity();
    amountOut = Math512.mulDiv(amountIn, reserveOut, nextIn);
    if (amountOut == 0 || amountOut < minOut) revert InsufficientOutput();
  }
}
