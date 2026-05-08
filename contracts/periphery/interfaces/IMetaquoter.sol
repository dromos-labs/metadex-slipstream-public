// SPDX-License-Identifier: MIT
pragma solidity >=0.7.5;

import {IV3FactoryRegistry} from 'contracts/periphery/interfaces/IV3FactoryRegistry.sol';

/**
 * @title IMetaquoter
 * @notice Quotes swaps and liquidity operations against CL and V2 pools without executing them, replacing the
 *         path-encoded mixed-route quoters and the view functions of the deprecated Router. Pools are addressed
 *         directly and validated through the FactoryRegistry, so no factory addresses or fee tiers are hardcoded.
 */
interface IMetaquoter {
  /**
   * @notice A pool's `metadata()` reads, held together so each quote reads them once.
   * @param decimals0 `10 ** token0.decimals()`.
   * @param decimals1 `10 ** token1.decimals()`.
   * @param reserve0 The reserve of `token0`.
   * @param reserve1 The reserve of `token1`.
   * @param token0 The pool's `token0`.
   * @param token1 The pool's `token1`.
   */
  struct PoolMetadata {
    uint256 decimals0;
    uint256 decimals1;
    uint256 reserve0;
    uint256 reserve1;
    address token0;
    address token1;
  }

  /**
   * @notice Quotes an exact-input swap through a single CL pool.
   * @dev The quote reports the output but not the input actually consumed, and a swap can stop before consuming all
   *      of `amountIn`: at a caller-supplied limit, or with no limit once the pool runs out of liquidity. The quoted
   *      output then corresponds to that partial input, without signalling the shortfall. Compare `sqrtPriceX96After`
   *      against the limit, or against the directional extreme when none was supplied, to detect it.
   * @param pool The CL pool.
   * @param tokenIn The input token.
   * @param amountIn The exact input amount.
   * @param sqrtPriceLimitX96 The square-root price limit, or zero for no limit.
   * @return amountOut The output amount.
   * @return sqrtPriceX96After The pool's square-root price after the swap.
   * @return initializedTicksCrossed The number of initialized ticks the swap crossed.
   */
  function quoteExactInputSingleV3(
    address pool,
    address tokenIn,
    uint256 amountIn,
    uint160 sqrtPriceLimitX96
  ) external returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed);

  /**
   * @notice Quotes an exact-output swap through a single CL pool.
   * @dev With no price limit the full output is guaranteed: a swap that cannot deliver it reverts. A caller-supplied
   *      limit lifts that guarantee, and a swap stopped at the limit quotes the input for the partial output it did
   *      reach, without signalling the shortfall. Compare `sqrtPriceX96After` against the limit to detect it.
   * @param pool The CL pool.
   * @param tokenIn The input token.
   * @param amountOut The exact output amount.
   * @param sqrtPriceLimitX96 The square-root price limit, or zero for no limit.
   * @return amountIn The input amount.
   * @return sqrtPriceX96After The pool's square-root price after the swap.
   * @return initializedTicksCrossed The number of initialized ticks the swap crossed.
   */
  function quoteExactOutputSingleV3(
    address pool,
    address tokenIn,
    uint256 amountOut,
    uint160 sqrtPriceLimitX96
  ) external returns (uint256 amountIn, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed);

  /**
   * @notice Quotes an exact-input swap through a forward-ordered route of CL and/or V2 pools.
   * @dev CL hops populate the returned lists at their route index; V2 hops leave those entries zero. Reverts `IO` if
   *      a V2 hop's quote rounds down to zero, which neither executes nor leaves the next hop anything to swap. If a
   *      pool repeats, each occurrence uses the pre-route state, so the quote can diverge from stateful execution.
   * @param pools The forward-ordered route pools.
   * @param tokenIn The input token for the first pool.
   * @param amountIn The exact input amount.
   * @return amountOut The final output amount.
   * @return sqrtPriceX96AfterList The post-swap square-root price of each CL hop, indexed by route position.
   * @return initializedTicksCrossedList The initialized ticks crossed by each CL hop, indexed by route position.
   */
  function quoteExactInput(
    address[] calldata pools,
    address tokenIn,
    uint256 amountIn
  )
    external
    returns (uint256 amountOut, uint160[] memory sqrtPriceX96AfterList, uint32[] memory initializedTicksCrossedList);

  /**
   * @notice Quotes an exact-output swap through a forward-ordered route of CL and/or V2 pools.
   * @dev Walks the route backward to size each hop's input. CL hops populate the returned lists at their route index;
   *      V2 hops leave those entries zero. Reverts `II` if a V2 hop's quote returns zero input, which no swap can
   *      pay. If a pool repeats, each occurrence uses the pre-route state, so the quote can diverge from stateful
   *      execution.
   * @param pools The forward-ordered route pools.
   * @param tokenIn The input token for the first pool.
   * @param amountOut The exact output amount the final pool must produce.
   * @return amountIn The input amount the route would require.
   * @return sqrtPriceX96AfterList The post-swap square-root price of each CL hop, indexed by route position.
   * @return initializedTicksCrossedList The initialized ticks crossed by each CL hop, indexed by route position.
   */
  function quoteExactOutput(
    address[] calldata pools,
    address tokenIn,
    uint256 amountOut
  )
    external
    returns (uint256 amountIn, uint160[] memory sqrtPriceX96AfterList, uint32[] memory initializedTicksCrossedList);

  /**
   * @notice Quotes an exact-input swap through a single V2 pool.
   * @dev Reverts `IO` when the pool's own quote rounds down to zero, as dust input does: the pool rejects a swap
   *      that moves nothing, so returning zero would describe a trade that cannot execute.
   * @param pool The V2 pool.
   * @param tokenIn The input token.
   * @param amountIn The exact input amount.
   * @return amountOut The output amount after the pool's total contextual fee.
   */
  function quoteExactInputSingleV2(
    address pool,
    address tokenIn,
    uint256 amountIn
  ) external view returns (uint256 amountOut);

  /**
   * @notice Quotes an exact-output swap through a single V2 pool.
   * @dev Reverts `II` when the pool's own quote returns zero input, as a zero `amountOut` does and as dust does when
   *      it rounds the pre-fee input down to zero: a swap that pays nothing cannot execute. The pool itself reverts
   *      when `amountOut` is not smaller than its reserve of the output token.
   * @param pool The V2 pool.
   * @param tokenIn The input token.
   * @param amountOut The exact output amount.
   * @return amountIn The input amount, including the pool's total contextual fee.
   */
  function quoteExactOutputSingleV2(
    address pool,
    address tokenIn,
    uint256 amountOut
  ) external view returns (uint256 amountIn);

  /**
   * @notice Quotes adding liquidity to a V2 pool: the amounts it would accept and the LP tokens it would mint.
   * @dev Amounts are expressed in the pool's `token0`/`token1` order. An unsynced donation is never credited to the
   *      quote, so the returned amounts and liquidity are a conservative floor of what mint would deposit. A stable
   *      pool's first mint is still validated against the amounts the pool would credit, so a successful quote never
   *      describes a mint that reverts. Assumes standard ERC20 transfers: a fee-on-transfer or rebasing token makes
   *      the pool credit something other than the amounts quoted here, breaking the floor in both directions. On a
   *      seeded pool the binding side is selected with full-precision math, so an oversized non-binding desired
   *      amount never overflows the quote, mirroring the Metarouter's `LiquidityLib`.
   * @param pool The V2 pool to quote.
   * @param amount0Desired The desired amount of `token0`.
   * @param amount1Desired The desired amount of `token1`.
   * @return amount0 The amount of `token0` that would be deposited.
   * @return amount1 The amount of `token1` that would be deposited.
   * @return liquidity The amount of LP tokens that would be minted.
   */
  function quoteAddLiquidityV2(
    address pool,
    uint256 amount0Desired,
    uint256 amount1Desired
  ) external view returns (uint256 amount0, uint256 amount1, uint256 liquidity);

  /**
   * @notice Quotes removing liquidity from a V2 pool: the underlying amounts burning the LP tokens would return.
   * @dev Amounts are expressed in the pool's `token0`/`token1` order. Each side is quoted from the lesser of the
   *      pool's live balance and its reserve: an unsynced donation is skimmable by anyone before the burn executes,
   *      so it is never credited and the quote is a conservative floor.
   * @dev `burn()` burns the pool's whole LP balance, so LP already sitting in the pool burns alongside `liquidity`.
   *      That surplus is left out of the returned amounts, keeping them a floor, but a stable pool's residual is
   *      validated against the combined burn, so a successful quote never describes a burn that reverts. Reverts
   *      `LTS` if `liquidity` exceeds the supply held outside the pool, which no single LP balance can.
   * @param pool The V2 pool to quote.
   * @param liquidity The amount of LP tokens to burn.
   * @return amount0 The amount of `token0` that would be returned.
   * @return amount1 The amount of `token1` that would be returned.
   */
  function quoteRemoveLiquidityV2(
    address pool,
    uint256 liquidity
  ) external view returns (uint256 amount0, uint256 amount1);

  /**
   * @notice Quotes adding liquidity to a CL pool over a tick range: the amounts the pool would pull and the position
   *         liquidity it would mint.
   * @dev Uses the pool's live price and returns amounts in `token0`/`token1` order. For one-sided sizing, pass the
   *      known amount and a sufficiently large finite desired amount for the other token. Do not use
   *      `type(uint256).max`, which can overflow the liquidity math while the price is inside the range.
   * @dev Matches `NonfungiblePositionManager` sizing and the amounts the pool rounds up on mint. Validates tick
   *      ordering, bounds and spacing, but not the live liquidity cap on each tick, so execution can still revert
   *      `LO`. Reverts `ILM` for zero liquidity and `LTM` above the pool's `int128` liquidity limit.
   * @param pool The CL pool to quote.
   * @param tickLower The lower tick of the position's range.
   * @param tickUpper The upper tick of the position's range.
   * @param amount0Desired The desired amount of `token0`.
   * @param amount1Desired The desired amount of `token1`.
   * @return amount0 The amount of `token0` that would be deposited.
   * @return amount1 The amount of `token1` that would be deposited.
   * @return liquidity The position liquidity that would be minted.
   */
  function quoteAddClLiquidityV3(
    address pool,
    int24 tickLower,
    int24 tickUpper,
    uint256 amount0Desired,
    uint256 amount1Desired
  ) external view returns (uint256 amount0, uint256 amount1, uint128 liquidity);

  /**
   * @notice Quotes removing liquidity from a CL pool position: the underlying amounts burning it would credit.
   * @dev Uses the pool's live price and returns amounts rounded down in `token0`/`token1` order. Fees are excluded and
   *      one amount is zero when the current price is outside the range. Reverts `LTM` above the pool's `int128`
   *      liquidity limit and `AO` if either amount cannot fit in the pool's `uint128` `tokensOwed` balance.
   * @dev Reverts `ILB` for zero liquidity, which no removal path executes: `decreaseLiquidity` rejects it and a zero
   *      burn is only a poke. Reverts `LS` when `liquidity` exceeds the liquidity referencing either boundary tick,
   *      since no position on the range could burn that much — an aggregate bound over every position on those ticks,
   *      gauge-staked liquidity included, not a check that the caller's own position holds enough.
   * @dev No owner is provided, so existing `tokensOwed` is not checked. A burn can still wrap if existing
   *      `tokensOwed` plus the quoted principal exceeds `uint128.max`.
   * @param pool The CL pool to quote.
   * @param tickLower The lower tick of the position's range.
   * @param tickUpper The upper tick of the position's range.
   * @param liquidity The position liquidity to burn.
   * @return amount0 The amount of `token0` that would be credited.
   * @return amount1 The amount of `token1` that would be credited.
   */
  function quoteRemoveClLiquidityV3(
    address pool,
    int24 tickLower,
    int24 tickUpper,
    uint128 liquidity
  ) external view returns (uint256 amount0, uint256 amount1);

  /**
   * @notice The minimum liquidity permanently locked on a pool's first mint; mirrors the pool's internal
   *         `MINIMUM_LIQUIDITY` constant, which has no getter.
   * @return The minimum liquidity locked on a pool's first mint.
   */
  function MINIMUM_LIQUIDITY() external view returns (uint256);

  /**
   * @notice The registry that gates which pool factories the quoter accepts.
   * @return The factory registry.
   */
  function factoryRegistry() external view returns (IV3FactoryRegistry);
}
