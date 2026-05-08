// SPDX-License-Identifier: MIT
pragma solidity >=0.7.5;

/**
 * @title IV2Pool
 * @notice The V2 pool surface the quoters need.
 * @dev Mirrors the metadex V2 pool reads introduced in PR #407 — `getAmountOutWithTotalFee` for exact-input swaps,
 *      `getAmountInWithTotalFee` for exact-output swaps, and `metadata` and `POOL_TYPE` for liquidity — which the
 *      canonical `IPool` in this repo does not declare with a matching shape.
 */
interface IV2Pool {
  /**
   * @notice Quotes the output for an exact input after applying the pool's total contextual fee.
   * @param amountIn The input token amount.
   * @param tokenIn The input token.
   * @return amountOut The output token amount.
   */
  function getAmountOutWithTotalFee(uint256 amountIn, address tokenIn) external view returns (uint256 amountOut);

  /**
   * @notice Quotes the input required for an exact output, including the pool's total contextual fee.
   * @dev Returns zero for a zero `amountOut` and when the pre-fee input rounds down to zero; reverts when `amountOut`
   *      is not smaller than the reserve of `tokenOut`, or when the fee gross-up does not converge.
   * @param amountOut The output token amount to receive.
   * @param tokenOut The output token.
   * @return amountIn The input token amount, fee included.
   */
  function getAmountInWithTotalFee(uint256 amountOut, address tokenOut) external view returns (uint256 amountIn);

  /**
   * @notice The pool's decimal scales, reserves and tokens in `token0`/`token1` order.
   * @return decimals0 `10 ** token0.decimals()`.
   * @return decimals1 `10 ** token1.decimals()`.
   * @return reserve0 The reserve of `token0`.
   * @return reserve1 The reserve of `token1`.
   * @return token0 The pool's `token0`.
   * @return token1 The pool's `token1`.
   */
  function metadata()
    external
    view
    returns (uint256 decimals0, uint256 decimals1, uint256 reserve0, uint256 reserve1, address token0, address token1);

  /**
   * @notice The canonical pool-type label, e.g. `V2_STABLE` or `V2_VOLATILE`.
   * @return The pool type.
   */
  function POOL_TYPE() external view returns (bytes32);

  /**
   * @notice The minimum invariant required for a stable pool's first mint.
   * @return The stable pool's minimum invariant.
   */
  function MINIMUM_K() external view returns (uint256);
}
