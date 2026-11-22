// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

library Math512 {
  error QuotientOverflow();

  // Remco Bloemen's full-precision mulDiv algorithm (https://xn--2-umb.com/21/muldiv).
  function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
    unchecked {
      uint256 high = _highWord(x, y);
      uint256 low = x * y;
      if (high == 0) return low / denominator;
      if (high >= denominator) revert QuotientOverflow();

      // Subtract the remainder before exact division and carry the borrow across words.
      uint256 remainder = mulmod(x, y, denominator);
      high -= remainder > low ? 1 : 0;
      low -= remainder;
      uint256 twos = denominator & (0 - denominator);
      assembly ("memory-safe") {
        denominator := div(denominator, twos)
        low := div(low, twos)
        twos := add(div(sub(0, twos), twos), 1)
      }
      low |= high * twos;

      // For an odd denominator, each Newton iteration doubles precision of the modular inverse.
      uint256 inverse = (3 * denominator) ^ 2;
      inverse *= 2 - denominator * inverse;
      inverse *= 2 - denominator * inverse;
      inverse *= 2 - denominator * inverse;
      inverse *= 2 - denominator * inverse;
      inverse *= 2 - denominator * inverse;
      inverse *= 2 - denominator * inverse;
      result = low * inverse;
    }
  }

  function mulDivUp(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
    uint256 quotient = mulDiv(x, y, denominator);
    return mulmod(x, y, denominator) == 0 ? quotient : quotient + 1;
  }

  function mulDivCapped(uint256 x, uint256 y, uint256 denominator, uint256 cap) internal pure returns (uint256) {
    if (_highWord(x, y) >= denominator) return cap;
    uint256 quotient = mulDiv(x, y, denominator);
    return quotient < cap ? quotient : cap;
  }

  function _highWord(uint256 x, uint256 y) private pure returns (uint256 high) {
    assembly ("memory-safe") {
      let low := mul(x, y)
      let near := mulmod(x, y, not(0))
      high := sub(sub(near, low), lt(near, low))
    }
  }
}
