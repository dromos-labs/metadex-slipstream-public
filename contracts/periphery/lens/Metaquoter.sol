// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import {Math} from '@openzeppelin/contracts/math/Math.sol';
import {SafeMath} from '@openzeppelin/contracts/math/SafeMath.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Babylonian} from '@uniswap/lib/contracts/libraries/Babylonian.sol';

import {ICLPool} from 'contracts/core/interfaces/ICLPool.sol';
import {ICLSwapCallback} from 'contracts/core/interfaces/callback/ICLSwapCallback.sol';
import {FullMath} from 'contracts/core/libraries/FullMath.sol';
import {SafeCast} from 'contracts/core/libraries/SafeCast.sol';
import {SqrtPriceMath} from 'contracts/core/libraries/SqrtPriceMath.sol';
import {TickMath} from 'contracts/core/libraries/TickMath.sol';
import {IMetaquoter} from 'contracts/periphery/interfaces/IMetaquoter.sol';
import {IPoolFactoryV3} from 'contracts/periphery/interfaces/IPoolFactoryV3.sol';
import {IV2Pool} from 'contracts/periphery/interfaces/IV2Pool.sol';
import {IV3FactoryRegistry} from 'contracts/periphery/interfaces/IV3FactoryRegistry.sol';
import {LiquidityAmounts} from 'contracts/periphery/libraries/LiquidityAmounts.sol';
import {MetaquoterLib} from 'contracts/periphery/libraries/MetaquoterLib.sol';
import {PoolTicksCounter} from 'contracts/periphery/libraries/PoolTicksCounter.sol';

/**
 * @title Metaquoter
 * @notice Provides on chain quotes for CL and V2 swaps and liquidity operations, addressed by pool, without
 *         executing them.
 * @dev Quotes are hypothetical and point-in-time. V2 swap quotes revert if the pool's factory is paused at quote
 *      time, but pause and reserves can still change before execution. An eth_call quote can also omit a priority-fee
 *      MEV tax that applies to the executing transaction.
 * @dev CL fees assume swap-fee discounts are not granted to the router and are keyed to the end user (tx.origin).
 *      The DiscountRegistry resolves the caller's discount first and only falls back to tx.origin, so if the router
 *      were granted a discount that branch would always win and the end-user discount would be ignored.
 * @dev V2 fees are resolved with this contract as the caller: the `getAmountOutWithTotalFee` and
 *      `getAmountInWithTotalFee` quote getters forward their `msg.sender` to `PoolFactory.getFee`, which hands it to
 *      the configured fee module. At quote time that is the quoter; at execution it is whoever calls `swap`, normally
 *      the router. A fee module that prices by caller therefore quotes a fee the swap does not pay.
 */
contract Metaquoter is IMetaquoter, ICLSwapCallback {
  using SafeCast for uint256;
  using SafeMath for uint256;
  using PoolTicksCounter for ICLPool;

  /// @inheritdoc IMetaquoter
  uint256 public constant override MINIMUM_LIQUIDITY = 10 ** 3;

  /// @dev The canonical POOL_TYPE label a CL pool reports.
  bytes32 private constant CL_POOL_TYPE = 'CL';

  /// @dev The canonical POOL_TYPE label a stable V2 pool reports.
  bytes32 private constant V2_STABLE_POOL_TYPE = 'V2_STABLE';

  /// @dev The canonical POOL_TYPE label a volatile V2 pool reports.
  bytes32 private constant V2_VOLATILE_POOL_TYPE = 'V2_VOLATILE';

  /// @inheritdoc IMetaquoter
  IV3FactoryRegistry public immutable override factoryRegistry;

  /**
   * @notice Wires the registry that gates which pool factories the quotes are accepted from.
   * @param _factoryRegistry The factory registry.
   */
  constructor(address _factoryRegistry) {
    factoryRegistry = IV3FactoryRegistry(_factoryRegistry);
  }

  /// @inheritdoc IMetaquoter
  function quoteExactInputSingleV3(
    address pool,
    address tokenIn,
    uint256 amountIn,
    uint160 sqrtPriceLimitX96
  ) external override returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed) {
    (amountOut, sqrtPriceX96After, initializedTicksCrossed) =
      quoteClSwap(pool, resolveClDirection(pool, tokenIn), amountIn.toInt256(), sqrtPriceLimitX96);
  }

  /// @inheritdoc IMetaquoter
  function quoteExactOutputSingleV3(
    address pool,
    address tokenIn,
    uint256 amountOut,
    uint160 sqrtPriceLimitX96
  ) external override returns (uint256 amountIn, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed) {
    (amountIn, sqrtPriceX96After, initializedTicksCrossed) =
      quoteClSwap(pool, resolveClDirection(pool, tokenIn), -amountOut.toInt256(), sqrtPriceLimitX96);
  }

  /// @inheritdoc IMetaquoter
  function quoteExactInput(
    address[] calldata pools,
    address tokenIn,
    uint256 amountIn
  )
    external
    override
    returns (uint256 amountOut, uint160[] memory sqrtPriceX96AfterList, uint32[] memory initializedTicksCrossedList)
  {
    uint256 length = pools.length;
    require(length != 0, 'EP'); // empty path
    sqrtPriceX96AfterList = new uint160[](length);
    initializedTicksCrossedList = new uint32[](length);

    amountOut = amountIn;
    for (uint256 i = 0; i < length; i++) {
      (bytes32 poolType, address token0, address token1) = resolvePool(pools[i]);
      address tokenOut = hopTokenOut(tokenIn, token0, token1);

      if (poolType == CL_POOL_TYPE) {
        uint160 sqrtPriceX96After;
        uint32 initializedTicksCrossed;
        (amountOut, sqrtPriceX96After, initializedTicksCrossed) =
          quoteClSwap(pools[i], tokenIn == token0, amountOut.toInt256(), 0);
        sqrtPriceX96AfterList[i] = sqrtPriceX96After;
        initializedTicksCrossedList[i] = initializedTicksCrossed;
      } else {
        // resolvePool already narrowed the type, so anything not CL is a V2 pool
        amountOut = IV2Pool(pools[i]).getAmountOutWithTotalFee(amountOut, tokenIn);
        require(amountOut != 0, 'IO'); // insufficient output
      }

      tokenIn = tokenOut;
    }
  }

  /// @inheritdoc IMetaquoter
  function quoteExactOutput(
    address[] calldata pools,
    address tokenIn,
    uint256 amountOut
  )
    external
    override
    returns (uint256 amountIn, uint160[] memory sqrtPriceX96AfterList, uint32[] memory initializedTicksCrossedList)
  {
    uint256 length = pools.length;
    require(length != 0, 'EP'); // empty path
    sqrtPriceX96AfterList = new uint160[](length);
    initializedTicksCrossedList = new uint32[](length);

    // resolve the forward token sequence and each hop's type in one pass; the backward loop needs both, and
    // resolvePool must run exactly once per hop since it authenticates and pause-gates V2 pools
    address[] memory tokens = new address[](length + 1);
    bytes32[] memory poolTypes = new bytes32[](length);
    tokens[0] = tokenIn;
    for (uint256 i = 0; i < length; i++) {
      (bytes32 poolType, address token0, address token1) = resolvePool(pools[i]);
      poolTypes[i] = poolType;
      tokens[i + 1] = hopTokenOut(tokens[i], token0, token1);
    }

    amountIn = amountOut;
    for (uint256 i = length; i > 0; i--) {
      uint256 index = i - 1;
      if (poolTypes[index] == CL_POOL_TYPE) {
        uint160 sqrtPriceX96After;
        uint32 initializedTicksCrossed;
        (amountIn, sqrtPriceX96After, initializedTicksCrossed) =
          quoteClSwap(pools[index], tokens[index] < tokens[index + 1], -amountIn.toInt256(), 0);
        sqrtPriceX96AfterList[index] = sqrtPriceX96After;
        initializedTicksCrossedList[index] = initializedTicksCrossed;
      } else {
        // resolvePool already narrowed the type, so anything not CL is a V2 pool
        amountIn = IV2Pool(pools[index]).getAmountInWithTotalFee(amountIn, tokens[index + 1]);
        require(amountIn != 0, 'II'); // insufficient input
      }
    }
  }

  /// @inheritdoc IMetaquoter
  function quoteExactInputSingleV2(
    address pool,
    address tokenIn,
    uint256 amountIn
  ) external view override returns (uint256 amountOut) {
    (bytes32 poolType, address token0, address token1) = resolvePool(pool);
    require(poolType != CL_POOL_TYPE, 'PT'); // wrong pool type: resolvePool leaves only the two V2 labels
    hopTokenOut(tokenIn, token0, token1); // validates tokenIn belongs to the pool
    amountOut = IV2Pool(pool).getAmountOutWithTotalFee(amountIn, tokenIn);
    require(amountOut != 0, 'IO'); // insufficient output
  }

  /// @inheritdoc IMetaquoter
  function quoteExactOutputSingleV2(
    address pool,
    address tokenIn,
    uint256 amountOut
  ) external view override returns (uint256 amountIn) {
    (bytes32 poolType, address token0, address token1) = resolvePool(pool);
    require(poolType != CL_POOL_TYPE, 'PT'); // wrong pool type: resolvePool leaves only the two V2 labels
    // the pool getter is addressed by output token, while this API stays tokenIn-addressed like every other quote
    address tokenOut = hopTokenOut(tokenIn, token0, token1);
    amountIn = IV2Pool(pool).getAmountInWithTotalFee(amountOut, tokenOut);
    require(amountIn != 0, 'II'); // insufficient input
  }

  /// @inheritdoc IMetaquoter
  function quoteAddLiquidityV2(
    address pool,
    uint256 amount0Desired,
    uint256 amount1Desired
  ) external view override returns (uint256 amount0, uint256 amount1, uint256 liquidity) {
    bool stable = validateV2Pool(pool);
    uint256 totalSupply = IERC20(pool).totalSupply();
    PoolMetadata memory metadata = poolMetadata(pool);
    if (totalSupply == 0) {
      (amount0, amount1) = (amount0Desired, amount1Desired);
      liquidity = Babylonian.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
      if (stable) validateStableFirstMint(pool, metadata, amount0, amount1);
      require(liquidity >= MINIMUM_LIQUIDITY, 'ILM'); // insufficient liquidity minted
    } else {
      // Seeded pool: one side is trimmed to the live reserve ratio, the smaller quote winning.
      require(amount0Desired > 0, 'IA'); // insufficient amount
      require(metadata.reserve0 > 0 && metadata.reserve1 > 0, 'IL'); // insufficient liquidity
      // Preserve the floored forward quote whenever its quotient fits uint256. `mulDiv` can represent that quotient
      // iff the product's high word is below the denominator. Otherwise quoting forward would revert even though the
      // imbalanced pool can accept a valid token1-limited deposit, so only the reverse quote is calculated. This
      // mirrors the Metarouter's LiquidityLib, so the quote reverts exactly when the execution would.
      uint256 amount1Optimal;
      bool amount0Binds;
      if (MetaquoterLib.mul512High(amount0Desired, metadata.reserve1) < metadata.reserve0) {
        amount1Optimal = FullMath.mulDiv(amount0Desired, metadata.reserve1, metadata.reserve0);
        amount0Binds = amount1Optimal <= amount1Desired;
      }
      if (amount0Binds) {
        (amount0, amount1) = (amount0Desired, amount1Optimal);
      } else {
        require(amount1Desired > 0, 'IA'); // insufficient amount
        (amount0, amount1) = (FullMath.mulDiv(amount1Desired, metadata.reserve0, metadata.reserve1), amount1Desired);
      }
      liquidity = Math.min(amount0.mul(totalSupply) / metadata.reserve0, amount1.mul(totalSupply) / metadata.reserve1);
      require(liquidity > 0, 'ILM'); // insufficient liquidity minted
    }
  }

  /// @inheritdoc IMetaquoter
  function quoteRemoveLiquidityV2(
    address pool,
    uint256 liquidity
  ) external view override returns (uint256 amount0, uint256 amount1) {
    bool stable = validateV2Pool(pool);
    uint256 totalSupply = IERC20(pool).totalSupply();
    if (totalSupply == 0) return (0, 0); // unseeded pool: nothing to withdraw
    // burn() burns the pool's own LP balance, so anything already sitting there burns alongside the pushed amount
    uint256 held = IERC20(pool).balanceOf(pool);
    require(liquidity <= totalSupply.sub(held), 'LTS'); // liquidity exceeds the supply held outside the pool
    PoolMetadata memory metadata = poolMetadata(pool);
    // burn() pays pro-rata of live balances, but an un-synced donation is skimmable by anyone before execution, so
    // crediting it would inflate the quote at zero cost to an attacker. Cap each side at its reserve: a floor.
    uint256 balance0 = Math.min(IERC20(metadata.token0).balanceOf(pool), metadata.reserve0);
    uint256 balance1 = Math.min(IERC20(metadata.token1).balanceOf(pool), metadata.reserve1);
    amount0 = liquidity.mul(balance0) / totalSupply;
    amount1 = liquidity.mul(balance1) / totalSupply;
    require(amount0 > 0 && amount1 > 0, 'ILB'); // insufficient liquidity burned
    if (stable) {
      // the pool validates the residual left by the whole burn, not just the caller's share. Pool-held LP cannot be
      // recovered — only burned — so it always drains too, and modelling it away would pass a quote the pool reverts.
      uint256 burned = liquidity.add(held);
      uint256 residual0 = balance0.sub(burned.mul(balance0) / totalSupply).mul(1e18) / metadata.decimals0;
      uint256 residual1 = balance1.sub(burned.mul(balance1) / totalSupply).mul(1e18) / metadata.decimals1;
      require(MetaquoterLib.stableK(residual0, residual1) != 0, 'KZ'); // k is zero
    }
  }

  /// @inheritdoc IMetaquoter
  function quoteAddClLiquidityV3(
    address pool,
    int24 tickLower,
    int24 tickUpper,
    uint256 amount0Desired,
    uint256 amount1Desired
  ) external view override returns (uint256 amount0, uint256 amount1, uint128 liquidity) {
    validateClPool(pool);
    validateClTicks(pool, tickLower, tickUpper);
    // the price and the tick are read together: the sizing branches on the price, the amounts on the tick
    (uint160 sqrtPriceX96, int24 tick,,,,) = ICLPool(pool).slot0();
    // mirrors the sizing NonfungiblePositionManager runs before minting: the binding side wins
    liquidity = LiquidityAmounts.getLiquidityForAmounts(
      sqrtPriceX96,
      TickMath.getSqrtRatioAtTick(tickLower),
      TickMath.getSqrtRatioAtTick(tickUpper),
      amount0Desired,
      amount1Desired
    );
    require(liquidity > 0, 'ILM'); // insufficient liquidity minted
    require(liquidity <= uint128(type(int128).max), 'LTM'); // liquidity exceeds the type maximum
    (amount0, amount1) = clLiquidityAmounts(sqrtPriceX96, tick, tickLower, tickUpper, liquidity, true);
  }

  /// @inheritdoc IMetaquoter
  function quoteRemoveClLiquidityV3(
    address pool,
    int24 tickLower,
    int24 tickUpper,
    uint128 liquidity
  ) external view override returns (uint256 amount0, uint256 amount1) {
    validateClPool(pool);
    validateClTicks(pool, tickLower, tickUpper);
    require(liquidity > 0, 'ILB'); // insufficient liquidity burned
    require(liquidity <= uint128(type(int128).max), 'LTM'); // liquidity exceeds the type maximum
    // mirrors the `liquidityGross - liquidity` the pool runs on burn: no position on this range holds that much
    // liquidity, so every possible burn of it underflows and reverts `LS` in the pool
    (uint128 grossLower,,,,,,,,,) = ICLPool(pool).ticks(tickLower);
    (uint128 grossUpper,,,,,,,,,) = ICLPool(pool).ticks(tickUpper);
    require(liquidity <= grossLower && liquidity <= grossUpper, 'LS'); // liquidity subtraction underflow
    (uint160 sqrtPriceX96, int24 tick,,,,) = ICLPool(pool).slot0();
    (amount0, amount1) = clLiquidityAmounts(sqrtPriceX96, tick, tickLower, tickUpper, liquidity, false);
    require(amount0 <= type(uint128).max && amount1 <= type(uint128).max, 'AO'); // amount does not fit in tokensOwed
  }

  /// @inheritdoc ICLSwapCallback
  function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external view override {
    require(amount0Delta > 0 || amount1Delta > 0, 'ZL'); // zero-liquidity swap unsupported
    (address pool, bool isExactInput, uint256 amountOutExpected) = abi.decode(data, (address, bool, uint256));
    require(msg.sender == pool, 'MS'); // callback invariant: sender matches the pool supplied to the simulation

    // the positive delta is always what the pool is owed; the negative one is what it sends
    (uint256 amountToPay, uint256 amountReceived) = amount0Delta > 0
      ? (uint256(amount0Delta), uint256(-amount1Delta))
      : (uint256(amount1Delta), uint256(-amount0Delta));

    (uint160 sqrtPriceX96After, int24 tickAfter,,,,) = ICLPool(pool).slot0();

    // exact input quotes the output the pool sends, exact output the input it charges
    uint256 amount;
    if (isExactInput) {
      amount = amountReceived;
    } else {
      // a nonzero expected output means the swap ran without a price limit and must have produced the full output
      if (amountOutExpected != 0) require(amountReceived == amountOutExpected, 'OC'); // output not expected amount
      amount = amountToPay;
    }

    assembly {
      let ptr := mload(0x40)
      mstore(ptr, amount)
      mstore(add(ptr, 0x20), sqrtPriceX96After)
      mstore(add(ptr, 0x40), tickAfter)
      revert(ptr, 0x60)
    }
  }

  /**
   * @notice Runs the CL swap whose callback reverts with the encoded quote, and decodes it.
   * @dev Reverts `NC` if the pool returns without invoking the callback: no quote was produced, so failing loud
   *      beats returning zeros a caller could mistake for a real quote. An exact output swap unconstrained by a price
   *      limit carries its target in the callback data so the callback can assert the pool delivered it in full;
   *      under a caller-supplied limit no such assertion is made and a partial fill quotes silently.
   * @param pool The CL pool to simulate against.
   * @param zeroForOne Whether the swap sells `token0` for `token1`.
   * @param amountSpecified The swap amount; positive for exact input, negative for exact output.
   * @param sqrtPriceLimitX96 The square-root price limit, or zero to use the directional extreme.
   * @return amount The quoted amount: the output for exact input, the input for exact output.
   * @return sqrtPriceX96After The pool's square-root price after the swap.
   * @return initializedTicksCrossed The number of initialized ticks the swap crossed.
   */
  function quoteClSwap(
    address pool,
    bool zeroForOne,
    int256 amountSpecified,
    uint160 sqrtPriceLimitX96
  ) private returns (uint256 amount, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed) {
    bool isExactInput = amountSpecified > 0;
    uint160 limit = sqrtPriceLimitX96 == 0
      ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
      : sqrtPriceLimitX96;
    uint256 amountOutExpected = !isExactInput && sqrtPriceLimitX96 == 0 ? uint256(-amountSpecified) : 0;
    bytes memory data = abi.encode(pool, isExactInput, amountOutExpected);
    try ICLPool(pool).swap(address(this), zeroForOne, amountSpecified, limit, data) {
      // a genuine CL pool always reverts through the quoter's callback; a swap that returns produced no quote to
      // decode, so fail loud rather than fall through with a zeroed quote
      revert('NC'); // no callback
    } catch (bytes memory reason) {
      return handleRevert(reason, pool);
    }
  }

  /**
   * @notice Validates a stable pool's first mint against the amounts it would credit.
   * @dev Mirrors `StablePool._mintValidation`. `mint()` credits `balance - reserve`, and reserves are zero while the
   *      supply is, so an unsynced donation counts toward the deposit: validating the desired amounts alone would
   *      quote a mint the pool reverts. The donation is deliberately left out of the quoted liquidity, which stays a
   *      floor, and is skimmable by anyone before execution.
   * @param pool The V2 pool to quote.
   * @param metadata The pool's metadata.
   * @param amount0Desired The desired amount of `token0`.
   * @param amount1Desired The desired amount of `token1`.
   */
  function validateStableFirstMint(
    address pool,
    PoolMetadata memory metadata,
    uint256 amount0Desired,
    uint256 amount1Desired
  ) private view {
    uint256 deposit0 = IERC20(metadata.token0).balanceOf(pool).sub(metadata.reserve0).add(amount0Desired);
    uint256 deposit1 = IERC20(metadata.token1).balanceOf(pool).sub(metadata.reserve1).add(amount1Desired);
    uint256 credited0 = deposit0.mul(1e18) / metadata.decimals0;
    uint256 credited1 = deposit1.mul(1e18) / metadata.decimals1;
    require(credited0 == credited1, 'DE'); // deposits not equal
    require(MetaquoterLib.stableK(credited0, credited1) > IV2Pool(pool).MINIMUM_K(), 'BK'); // below minimum k
  }

  /**
   * @notice Reads the pool's decimal scales, reserves and tokens in a single call.
   * @param pool The V2 pool to read.
   * @return metadata The pool's metadata.
   */
  function poolMetadata(address pool) private view returns (PoolMetadata memory metadata) {
    (metadata.decimals0, metadata.decimals1, metadata.reserve0, metadata.reserve1, metadata.token0, metadata.token1) =
      IV2Pool(pool).metadata();
  }

  /**
   * @notice Authenticates a pool against the registry and reads its canonical pool type.
   * @dev Resolves the pool's factory from the registry (never the pool's self-reported `factory()`), so a spoofed
   *      pool cannot pass validation; reverts unless the pool is a registered target of an approved factory. Pools
   *      must implement `POOL_TYPE`; legacy pools without it are unsupported and revert here.
   * @param pool The pool to authenticate.
   * @return factory The registry-resolved factory that deployed the pool.
   * @return poolType The pool's canonical type label.
   */
  function authenticatePool(address pool) private view returns (address factory, bytes32 poolType) {
    factory = factoryRegistry.targetToFactory(pool);
    require(factory != address(0), 'IP'); // not a registered target
    require(factoryRegistry.isTargetFactoryApproved(factory), 'AF'); // factory not approved
    poolType = ICLPool(pool).POOL_TYPE();
  }

  /**
   * @notice Validates a pool for swap quotes and reads the fields shared by CL and V2 pools.
   * @dev Narrows the pool to one of the three supported types here, so an unsupported label fails on its type rather
   *      than on a getter its factory may not implement. Callers restricting to a single family still assert it.
   *      V2 swaps revert when the pool's factory is paused; CL pools have no pause, so only V2 quotes are gated.
   * @param pool The pool to validate.
   * @return poolType The pool's canonical type label.
   * @return token0 The pool's `token0`.
   * @return token1 The pool's `token1`.
   */
  function resolvePool(address pool) private view returns (bytes32 poolType, address token0, address token1) {
    address factory;
    (factory, poolType) = authenticatePool(pool);
    if (poolType != CL_POOL_TYPE) {
      require(poolType == V2_STABLE_POOL_TYPE || poolType == V2_VOLATILE_POOL_TYPE, 'PT'); // wrong pool type
      require(!IPoolFactoryV3(factory).isPaused(), 'PS'); // paused
    }
    token0 = ICLPool(pool).token0();
    token1 = ICLPool(pool).token1();
  }

  /**
   * @notice Validates that `pool` is a V2 pool of an approved factory, for liquidity quotes.
   * @dev Mint and burn are not gated by the factory pause, so unlike `resolvePool` this does not reject paused
   *      factories.
   * @param pool The pool to validate.
   * @return stable Whether the pool is stable.
   */
  function validateV2Pool(address pool) private view returns (bool stable) {
    (, bytes32 poolType) = authenticatePool(pool);
    require(poolType == V2_STABLE_POOL_TYPE || poolType == V2_VOLATILE_POOL_TYPE, 'PT'); // wrong pool type
    stable = poolType == V2_STABLE_POOL_TYPE;
  }

  /**
   * @notice Validates that `pool` is a CL pool of an approved factory, for liquidity quotes.
   * @dev CL pools have no pause, so unlike `resolvePool` there is nothing to gate here.
   * @param pool The pool to validate.
   */
  function validateClPool(address pool) private view {
    (, bytes32 poolType) = authenticatePool(pool);
    require(poolType == CL_POOL_TYPE, 'PT'); // wrong pool type
  }

  /**
   * @notice Validates a tick range against the range checks the pool enforces on a position.
   * @dev Mirrors the pool's ordering, bounds and spacing checks. It does not read the live per-tick liquidity cap, so
   *      a mint can still revert `LO`.
   * @param pool The CL pool the range belongs to.
   * @param tickLower The lower tick of the range.
   * @param tickUpper The upper tick of the range.
   */
  function validateClTicks(address pool, int24 tickLower, int24 tickUpper) private view {
    require(tickLower < tickUpper, 'TLU'); // lower tick not below upper
    require(tickLower >= TickMath.MIN_TICK, 'TLM'); // lower tick below the minimum
    require(tickUpper <= TickMath.MAX_TICK, 'TUM'); // upper tick above the maximum
    int24 tickSpacing = ICLPool(pool).tickSpacing();
    require(tickLower % tickSpacing == 0 && tickUpper % tickSpacing == 0, 'TS'); // ticks not spacing-aligned
  }

  /**
   * @notice Returns the token amounts a position of `liquidity` over the range is worth at the pool's live price.
   * @dev Mirrors `CLPool._modifyPosition` by branching on `slot0.tick` and using mint/burn rounding.
   * @param sqrtPriceX96 The pool's current square-root price.
   * @param tick The pool's current tick, read from the same `slot0` as `sqrtPriceX96`.
   * @param tickLower The lower tick of the range.
   * @param tickUpper The upper tick of the range.
   * @param liquidity The position liquidity being valued.
   * @param roundUp Whether to round the amounts up, as a mint does, or down, as a burn does.
   * @return amount0 The amount of `token0` the liquidity is worth.
   * @return amount1 The amount of `token1` the liquidity is worth.
   */
  function clLiquidityAmounts(
    uint160 sqrtPriceX96,
    int24 tick,
    int24 tickLower,
    int24 tickUpper,
    uint128 liquidity,
    bool roundUp
  ) private pure returns (uint256 amount0, uint256 amount1) {
    if (tick < tickLower) {
      // the range sits entirely above the price: it holds only token0
      amount0 = SqrtPriceMath.getAmount0Delta(
        TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity, roundUp
      );
    } else if (tick < tickUpper) {
      // the price sits inside the range: both sides are needed, split at the live price
      amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, TickMath.getSqrtRatioAtTick(tickUpper), liquidity, roundUp);
      amount1 = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtRatioAtTick(tickLower), sqrtPriceX96, liquidity, roundUp);
    } else {
      // the range sits entirely below the price: it holds only token1
      amount1 = SqrtPriceMath.getAmount1Delta(
        TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity, roundUp
      );
    }
  }

  /**
   * @notice Validates a CL pool and resolves the swap direction for a given input token.
   * @param pool The CL pool to validate.
   * @param tokenIn The input token.
   * @return zeroForOne Whether the swap sells `token0` for `token1`.
   */
  function resolveClDirection(address pool, address tokenIn) private view returns (bool zeroForOne) {
    (bytes32 poolType, address token0, address token1) = resolvePool(pool);
    require(poolType == CL_POOL_TYPE, 'PT'); // wrong pool type
    zeroForOne = tokenIn == token0;
    require(zeroForOne || tokenIn == token1, 'TI'); // token in not in pool
  }

  /**
   * @notice Decodes a swap callback revert into the quote and counts the initialized ticks crossed.
   * @dev The callback's revert rolls the simulated swap back before this runs, so `slot0` reads pre-swap state.
   * @param reason The revert payload carrying the encoded quote.
   * @param pool The CL pool that was simulated.
   * @return amount The quoted amount: the output for exact input, the input for exact output.
   * @return sqrtPriceX96After The pool's square-root price after the swap.
   * @return initializedTicksCrossed The number of initialized ticks the swap crossed.
   */
  function handleRevert(
    bytes memory reason,
    address pool
  ) private view returns (uint256 amount, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed) {
    (, int24 tickBefore,,,,) = ICLPool(pool).slot0();
    int24 tickAfter;
    (amount, sqrtPriceX96After, tickAfter) = MetaquoterLib.parseRevertReason(reason);
    initializedTicksCrossed = ICLPool(pool).countInitializedTicksCrossed(tickBefore, tickAfter);
  }

  /**
   * @notice Returns the counterpart pool token for `tokenIn`, reverting if it is not a pool token.
   * @param tokenIn The input token.
   * @param token0 The pool's `token0`.
   * @param token1 The pool's `token1`.
   * @return tokenOut The pool's other token.
   */
  function hopTokenOut(address tokenIn, address token0, address token1) private pure returns (address tokenOut) {
    if (tokenIn == token0) return token1;
    require(tokenIn == token1, 'TI'); // token in not in pool
    return token0;
  }
}
