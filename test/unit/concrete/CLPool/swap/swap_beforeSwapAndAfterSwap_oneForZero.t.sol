// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {FullMath} from 'contracts/core/libraries/FullMath.sol';
import {TickMath} from 'contracts/core/libraries/TickMath.sol';

import {ISwapHook} from 'contracts/core/interfaces/hook/ISwapHook.sol';

import {UnitCLPoolSwapBaseHelpers} from './swapBaseHelpers.sol';

/// forge-config: ci.fuzz.runs=2500
contract UnitCLPoolSwap_beforeSwapAndAfterSwap_oneForZero is UnitCLPoolSwapBaseHelpers {
  using FullMath for uint256;

  modifier whenHookUsesBeforeSwapAndAfterSwap(Params memory _params, bool _exactInput, uint24 _afterSwapFee) {
    _whenHookUsesBeforeSwapOnly(_params, _exactInput, _ONE_FOR_ZERO);

    _afterSwapFee = uint24(bound(uint256(_afterSwapFee), 1, _FEE_CEIL));

    vm.mockCall(_swapHook, 0, abi.encodeWithSelector(ISwapHook.afterSwap.selector), abi.encode(_afterSwapFee));

    vm.startPrank(_swapper);
    _;
    vm.stopPrank();
  }

  modifier whenPoolIsUnlocked() {
    _setSlot0Unlocked(address(clPool), true);
    _;
  }

  modifier whenLiquidityIsPositive(uint128 _liquidity, uint128 _stakedLiquidity) {
    _stakedLiquidity = uint128(bound(uint256(_stakedLiquidity), 0, _MAX_LIQUIDITY - _MIN_LIQUIDITY));
    _liquidity = uint128(bound(uint256(_liquidity), _stakedLiquidity + _MIN_LIQUIDITY, _MAX_LIQUIDITY));

    _setLiquidity(address(clPool), _liquidity);
    _setStakedLiquidity(address(clPool), _stakedLiquidity);
    _;
  }

  modifier whenSwapIsOneForZero() {
    _;
  }

  modifier whenSqrtPriceLimitIsValid() {
    _;
  }

  function test_WhenSwapIsExactInput(
    Params memory _params,
    uint24 _afterSwapFee
  )
    external
    whenPoolIsUnlocked
    whenLiquidityIsPositive(_params.liquidity, _params.stakedLiquidity)
    whenHookUsesBeforeSwapAndAfterSwap(_params, true, _afterSwapFee)
    whenSwapIsOneForZero
    whenSqrtPriceLimitIsValid
  {
    _swap(_params, true, _afterSwapFee);
  }

  function test_WhenSwapIsExactOutput(
    Params memory _params,
    uint24 _afterSwapFee
  )
    external
    whenPoolIsUnlocked
    whenLiquidityIsPositive(_params.liquidity, _params.stakedLiquidity)
    whenHookUsesBeforeSwapAndAfterSwap(_params, false, _afterSwapFee)
    whenSwapIsOneForZero
    whenSqrtPriceLimitIsValid
  {
    _swap(_params, false, _afterSwapFee);
  }

  /// @notice Generalized test function that branches assertions based on `_exactInput` flag.
  function _swap(Params memory _params, bool _exactInput, uint24 _afterSwapFee) internal {
    _params.stakedLiquidity = uint128(bound(uint256(_params.stakedLiquidity), 0, _MAX_LIQUIDITY - _MIN_LIQUIDITY));
    _params.liquidity =
      uint128(bound(uint256(_params.liquidity), _params.stakedLiquidity + _MIN_LIQUIDITY, _MAX_LIQUIDITY));

    _params.fee = uint24(bound(uint256(_params.fee), 0, _FEE_CEIL));
    _afterSwapFee = uint24(bound(uint256(_afterSwapFee), 1, _FEE_CEIL));

    (uint160 _slot0SqrtPriceX96,,,,,) = clPool.slot0();

    _params.sqrtPriceLimitX96 =
      uint160(bound(uint256(_params.sqrtPriceLimitX96), _slot0SqrtPriceX96 + 1, TickMath.MAX_SQRT_RATIO - 1));

    /// @dev Verify 1->0 condition
    assertGt(uint256(_params.sqrtPriceLimitX96), uint256(_slot0SqrtPriceX96));

    /// @dev Verify correctness of "exact" amount.
    if (_exactInput) assertGt(_params.amountSpecified, 0);
    else assertLt(_params.amountSpecified, 0);

    // it calls factory.swapHook

    // it calls swapHook.beforeSwap
    // => (already expected in `whenHookUsesBeforeSwapOnly`).

    // Provide the pool with the balanceOf answers it expects during the swap callback.
    _bypassBalanceOf(clPool.token1(), address(clPool));

    // Pre-load swap values that will be computed inside the swap loop.
    SwapStep memory _step = _computeSwapStep(_params, _ONE_FOR_ZERO);

    int256 _toBeAmount0;
    int256 _toBeAmount1;
    uint256 _afterSwapFeeAmount;

    // it decreases amountCalculated by after-swap fee amount
    if (_exactInput) {
      _afterSwapFeeAmount = uint256(_step.amountOut).mulDivRoundingUp(_afterSwapFee, _DENOMINATOR);
      _step.amountOut -= _afterSwapFeeAmount;
    } else {
      _afterSwapFeeAmount = uint256(_step.amountIn + _step.feeAmount).mulDivRoundingUp(_afterSwapFee, _DENOMINATOR);
      _step.amountIn += _afterSwapFeeAmount;
    }

    (_toBeAmount0, _toBeAmount1) = (-int256(_step.amountOut), int256(_step.amountIn + _step.feeAmount));

    // it calls uniswapV3SwapCallback on msg.sender
    _mockAndExpectSwapCallback(_swapper, _toBeAmount0, _toBeAmount1);

    // it transfers token1 with amount1 to the recipient
    if (_step.amountOut != 0) {
      _mockAndExpectTransfer(clPool.token0(), _swapper, uint256(-(_toBeAmount0)));
    }

    // it emits Swap event
    vm.expectEmit();
    emit Swap(
      _swapper,
      _swapper,
      _toBeAmount0,
      _toBeAmount1,
      _step.sqrtRatioNextX96,
      _params.liquidity,
      TickMath.getTickAtSqrtRatio(_step.sqrtRatioNextX96)
    );

    (int256 _amount0, int256 _amount1) =
      clPool.swap(_swapper, _ONE_FOR_ZERO, _params.amountSpecified, _params.sqrtPriceLimitX96, '');

    // =============== Calculation expectations

    // it computes amount0 as diff between specified and remaining amounts (exactInput)
    // it sets amount0 as amountCalculated (exactOutput)
    assertEq(_amount0, _toBeAmount0);

    // it sets amount1 as amountCalculated (exactInput)
    // it computes amount1 as diff between specified and remaining amounts (exactOutput)
    assertEq(_amount1, _toBeAmount1);

    // it splits feeAmount between staked and non-staked LPs
    (uint256 _feeGrowthGlobalX128, uint256 _stakedFeeAmount) =
      _calculateFees(_step.feeAmount, _params.liquidity, _params.stakedLiquidity);

    // it sets feeGrowthGlobal0x128 to state.feeGrowthGlobalX128
    assertEq(clPool.feeGrowthGlobal1X128(), _feeGrowthGlobalX128);
    assertEq(clPool.feeGrowthGlobal0X128(), 0);

    (uint128 _token0, uint128 _token1) = clPool.gaugeFees();

    if (_exactInput) {
      // it adds gaugeFee to gaugeFees.token1
      assertEq(uint256(_token1), _stakedFeeAmount);
      // it adds after-swap gaugeFee to gaugeFees.token0
      assertEq(uint256(_token0), _afterSwapFeeAmount);
    } else {
      // it adds gaugeFee to gaugeFees.token1
      // it adds after-swap gaugeFee to gaugeFees.token1
      assertEq(uint256(_token1), _stakedFeeAmount + _afterSwapFeeAmount);
      assertEq(uint256(_token0), 0);
    }
  }
}
