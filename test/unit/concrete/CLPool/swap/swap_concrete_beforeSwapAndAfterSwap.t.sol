// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {TickMath} from 'contracts/core/libraries/TickMath.sol';

import {ISwapHook} from 'contracts/core/interfaces/hook/ISwapHook.sol';

import {UnitCLPoolSwapBaseHelpers} from './swapBaseHelpers.sol';

contract UnitCLPoolSwap_concrete_beforeSwapAndAfterSwap is UnitCLPoolSwapBaseHelpers {
  /*////////////////////////////////////////////////////////////
                              State of the pool
  ////////////////////////////////////////////////////////////*/

  uint128 private _liquidity = 1e25;
  uint128 private _stakedLiquidity = 1e15;

  /*////////////////////////////////////////////////////////////
                              Inputs
  ////////////////////////////////////////////////////////////*/

  int256 private _amountSpecified = 1e20;
  uint160 private _sqrtPriceLimitX96 = TickMath.MIN_SQRT_RATIO + 1; // don't care about slippage here.

  /*////////////////////////////////////////////////////////////
                              Hooks fees
  ////////////////////////////////////////////////////////////*/

  uint24 private _beforeSwapFee = 50_000; // 5%
  uint24 private _afterSwapFee = 100_000; // 10%

  function setUp() public override {
    super.setUp();

    _setLiquidity(address(clPool), _liquidity);
    _setStakedLiquidity(address(clPool), _stakedLiquidity);
  }

  function test_BeforeAndAfterHooks_SwapExactInputZeroForOne_100K() external {
    /*
      ########### Calculations:

      1) sqrt_a = 79466191966197645195421774833 # slot0.sqrtPriceX96
      2) sqrt_b = ((10**25 << 96) * sqrt_a) / ((10**25 << 96) + 95000000000000000000 * sqrt_a)
                = ~79465434776515401024525298424
      3) amount_in = (10**25 << 96) * (sqrt_a - sqrt_b) / (sqrt_a * sqrt_b)
                   = 95000000000000000000
      4) amount_out = 10**25 * (sqrt_a - sqrt_b) / 0x1000000000000000000000000
                    = ~95570774105463510892
      5) fee_amount = 5000000000000000000

      # Fee is split between staked/non-staked LPs

      6) staked_fee_amt  = fee_amount * 10**15 / 10**25
                         = 500000000
      7) fee_growth_x128 = (fee_amount - staked_fee_amount) * 0x100000000000000000000000000000000 / (10**25 - 10**15)
                         = ~170141183460469231731687303715884

      8) after_swap_fee_amt = (amount_out * 100_000) / 10**6
                            = ~9557077410546351090
      9) amount_0 = amount_in

      # it's negative in actual swap calculations
      10) amount_1 = amount_out - after_swap_fee_amt
                   = 86013696694917159802

      ########### Fee updates
      11) fee_growth_0_x128 += fee_growth_x128
      12) gauge_fee_token1 += after_swap_fee_amt
      13) gauge_fee_token0 += staked_fee_amt
     */

    // (7)
    uint256 _feeGrowthGlobal0X128Expected = 170_141_183_460_469_231_731_687_303_715_884;
    // (8)
    int256 _afterSwapFeeAmountExpected = 9_557_077_410_546_351_090;
    // (9) and (10)
    (int256 _amount0Expected, int256 _amount1Expected) =
      (_amountSpecified, -(95_570_774_105_463_510_892 - _afterSwapFeeAmountExpected));

    _mockAndExpectBeforeSwap(_beforeSwapFee, abi.encodeWithSelector(ISwapHook.beforeSwap.selector));
    _mockAndExpectAfterSwap(_afterSwapFee, abi.encodeWithSelector(ISwapHook.afterSwap.selector));
    _mockAndExpectSwapCallback(_swapper, _amount0Expected, _amount1Expected);
    _mockAndExpectTransfer(clPool.token1(), _swapper, uint256(-(_amount1Expected)));
    _bypassBalanceOf(clPool.token0(), address(clPool));

    vm.prank(_swapper);
    (int256 _amount0, int256 _amount1) = clPool.swap(_swapper, _ZERO_FOR_ONE, _amountSpecified, _sqrtPriceLimitX96, '');

    // (9)
    assertEq(_amount0, _amount0Expected);
    // (10)
    assertEq(_amount1, _amount1Expected);

    // (11)
    assertEq(clPool.feeGrowthGlobal0X128(), _feeGrowthGlobal0X128Expected);
    assertEq(clPool.feeGrowthGlobal1X128(), 0);

    (uint128 _gaugeToken0, uint128 _gaugeToken1) = clPool.gaugeFees();

    // (12)
    assertEq(int256(_gaugeToken1), _afterSwapFeeAmountExpected);
    // (13)
    assertEq(uint256(_gaugeToken0), 500_000_000);
  }

  function test_BeforeAndAfterHooks_SwapExactOutputZeroForOne_100K_2to1Price() external {
    /*
      ########### Calculations:

      1) sqrt_a = 112045541949572279837463876454 # slot0.sqrtPriceX96
      2) sqrt_b = sqrt_a - (10**20 << 96) / 10**30
                = ~112044749667947137194087941014
      3) amount_in  = (10**25 << 96) * (sqrt_a - sqrt_b) / (sqrt_a * sqrt_b)
                    = ~50000353555890610952

      4) amount_out = 10**25 * (sqrt_a - sqrt_b) / 0x1000000000000000000000000
                    = 10**20
      5) fee_amount = (amount_in * 50_000) / (10**6 - 50_000)
                    = ~2631597555573190051

      # Fee is split between staked/non-staked LPs

      6) staked_fee_amt  = fee_amount * 10**15 / 10**25
                         = ~263159756
      7) fee_growth_x128 = (fee_amount - staked_fee_amount) * 0x100000000000000000000000000000000 / (10**25 - 10**15)
                         = ~89548624499380100585485034305640

      8) after_swap_fee_amt = ((amount_in + fee_amount) * 100_000) / 10**6
                            = ~5263195111146380101
      9) amount_0 = amount_in + fee_amount + after_swap_fee_amt

      # it's negative in actual swap calculations
      10) amount_1 = amount_out

      ########### Fee updates
      11) fee_growth_0_x128 += fee_growth_x128
      12) gauge_fee_token0 += after_swap_fee_amt + staked_fee_amt
     */
    _setSlot0SqrtPrice(address(clPool), encodePriceSqrt(2, 1));

    // (7)
    uint256 _feeGrowthGlobal0X128Expected = 89_548_624_499_380_100_585_485_034_305_640;
    // (8)
    int256 _afterSwapFeeAmountExpected = 5_263_195_111_146_380_101;
    // (9) and (10)
    (int256 _amount0Expected, int256 _amount1Expected) =
      (50_000_353_555_890_610_952 + 2_631_597_555_573_190_051 + _afterSwapFeeAmountExpected, -(_amountSpecified));

    _mockAndExpectBeforeSwap(_beforeSwapFee, abi.encodeWithSelector(ISwapHook.beforeSwap.selector));
    _mockAndExpectAfterSwap(_afterSwapFee, abi.encodeWithSelector(ISwapHook.afterSwap.selector));
    _mockAndExpectSwapCallback(_swapper, _amount0Expected, _amount1Expected);
    _mockAndExpectTransfer(clPool.token1(), _swapper, uint256(-(_amount1Expected)));
    _bypassBalanceOf(clPool.token0(), address(clPool));

    vm.prank(_swapper);
    (int256 _amount0, int256 _amount1) = clPool.swap(_swapper, _ZERO_FOR_ONE, -_amountSpecified, _sqrtPriceLimitX96, '');

    // (9)
    assertEq(_amount0, _amount0Expected);
    // (10)
    assertEq(_amount1, _amount1Expected);

    // (11)
    assertEq(clPool.feeGrowthGlobal0X128(), _feeGrowthGlobal0X128Expected);
    assertEq(clPool.feeGrowthGlobal1X128(), 0);

    (uint128 _gaugeToken0, uint128 _gaugeToken1) = clPool.gaugeFees();

    // (12)
    assertEq(int256(_gaugeToken0), _afterSwapFeeAmountExpected + 263_159_756);
    assertEq(uint256(_gaugeToken1), 0);
  }
}
