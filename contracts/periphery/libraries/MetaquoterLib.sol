// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import {SafeMath} from '@openzeppelin/contracts/math/SafeMath.sol';

/**
 * @title MetaquoterLib
 * @notice Holds the stateless helpers Metaquoter quotes with: the stable-pool invariant, the 512-bit product's high
 *         word, and the swap-callback revert decoder.
 * @dev Every function is `internal` and pure, so they inline into the quoter.
 */
library MetaquoterLib {
  using SafeMath for uint256;

  /**
   * @notice Parses the numeric quote from a swap callback revert payload, bubbling any other revert.
   * @param reason The revert payload to parse.
   * @return amount The quoted amount: the output for exact input, the input for exact output.
   * @return sqrtPriceX96After The pool's square-root price after the swap.
   * @return tickAfter The pool's tick after the swap.
   */
  function parseRevertReason(bytes memory reason)
    internal
    pure
    returns (uint256 amount, uint160 sqrtPriceX96After, int24 tickAfter)
  {
    if (reason.length != 0x60) {
      if (reason.length < 0x44) revert('Unexpected error');
      assembly {
        reason := add(reason, 0x04)
      }
      revert(abi.decode(reason, (string)));
    }
    return abi.decode(reason, (uint256, uint160, int24));
  }

  /**
   * @notice Returns the most significant 256 bits of the 512-bit product `a * b`.
   * @dev The low word is never needed: `FullMath.mulDiv(a, b, denominator)` can represent its quotient in a uint256
   *      iff this high word is below `denominator`, which is the only question the quoter asks of the product.
   *      Computed with the same `mulmod` prologue `mulDiv` uses internally; the wrapping `mul` is deliberate.
   * @param a The multiplicand.
   * @param b The multiplier.
   * @return high The high 256 bits of the product.
   */
  function mul512High(uint256 a, uint256 b) internal pure returns (uint256 high) {
    assembly {
      let mm := mulmod(a, b, not(0))
      let prod0 := mul(a, b)
      high := sub(sub(mm, prod0), lt(mm, prod0))
    }
  }

  /**
   * @notice Returns the stable-pool invariant for decimal-normalized token amounts.
   * @param amount0 The decimal-normalized amount of `token0`.
   * @param amount1 The decimal-normalized amount of `token1`.
   * @return k The stable-pool invariant.
   */
  function stableK(uint256 amount0, uint256 amount1) internal pure returns (uint256 k) {
    uint256 product = amount0.mul(amount1) / 1e18;
    uint256 squares = (amount0.mul(amount0) / 1e18).add(amount1.mul(amount1) / 1e18);
    k = product.mul(squares) / 1e18;
  }
}
