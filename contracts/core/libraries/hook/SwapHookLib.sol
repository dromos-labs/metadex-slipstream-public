// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import {FullMath} from '../FullMath.sol';

import {ICLFactory} from 'contracts/core/interfaces/ICLFactory.sol';
import {ISwapHook} from 'contracts/core/interfaces/hook/ISwapHook.sol';

import {CLPool} from 'contracts/core/CLPool.sol';

/// @notice Helper library for invoking swap hook methods and translating pool swap state into hook inputs.
library SwapHookLib {
  using SwapHookLib for CLPool.SwapState;
  using FullMath for uint256;

  /*////////////////////////////////////////////////////////////
                              CONSTANTS
  ////////////////////////////////////////////////////////////*/

  /// @dev A pips denominator.
  uint256 internal constant _DENOMINATOR = 1e6;

  /// @dev A ceil that fees returned from hook methods can not exceed.
  uint24 internal constant _SWAP_FEE_CEIL = 100_000;

  /*////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Calls the hook's `getBeforeSwapFee` entry point. Falls back to the pool's tick-spacing fee
  ///         when: swap hook is zero address; beforeSwap call reverted; returned fee is zero.
  /// @param _swapHook Address of the hook contract.
  /// @param _pool Address of the pool making the query.
  /// @param _swapParams Swap context and PRE-SWAP pool state.
  /// @param _factory Pool factory used to obtain the default tick-spacing fee.
  /// @param _tickSpacing Pool's tick spacing.
  /// @return The swap fee applied in the swap loop.
  function getBeforeSwapFee(
    address _swapHook,
    address _pool,
    ISwapHook.SwapParams memory _swapParams,
    address _factory,
    int24 _tickSpacing
  ) internal view returns (uint24) {
    if (_swapHook != address(0)) {
      try ISwapHook(_swapHook).getBeforeSwapFee(_pool, _swapParams) returns (uint24 _fee) {
        if (_fee > 0) return cap(_fee);
      } catch {}
    }

    return ICLFactory(_factory).tickSpacingToFee(_tickSpacing);
  }

  /// @notice Calls the hook's `getAfterSwapFee` entry point.
  /// @param _swapHook Address of the hook contract.
  /// @param _pool Address of the pool making the query.
  /// @param _swapParams Swap context and POST-SWAP pool state.
  /// @param _afterSwapParams POST-SWAP execution state and oracle/liquidity context.
  /// @return The swap fee applied after the swap loop.
  function getAfterSwapFee(
    address _swapHook,
    address _pool,
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams
  ) internal view returns (uint24) {
    if (_swapHook != address(0)) {
      try ISwapHook(_swapHook).getAfterSwapFee(_pool, _swapParams, _afterSwapParams) returns (uint24 _fee) {
        if (_fee > 0) return cap(_fee);
      } catch {}
    }
  }

  /// @notice Calls the hook's `getFlashFee` entry point. Falls back to the pool's tick-spacing fee
  ///         when: swap hook is zero address; `getFlashFee` call reverted.
  /// @param _swapHook Address of the hook contract.
  /// @param _pool Address of the pool making the query.
  /// @param _flashParams Arguments passed to the {CLPool.flash} function.
  /// @param _factory Pool factory used to obtain the default tick-spacing fee.
  /// @param _tickSpacing Pool's tick spacing.
  /// @return The flash fee.
  function getFlashFee(
    address _swapHook,
    address _pool,
    ISwapHook.FlashParams memory _flashParams,
    address _factory,
    int24 _tickSpacing
  ) internal view returns (uint24) {
    if (_swapHook != address(0)) {
      try ISwapHook(_swapHook).getFlashFee(_pool, _flashParams) returns (uint24 _fee) {
        return cap(_fee);
      } catch {}
    }

    return ICLFactory(_factory).tickSpacingToFee(_tickSpacing);
  }

  /*////////////////////////////////////////////////////////////
                              WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Calls the hook's `beforeSwap` entry point. Falls back to the pool's tick-spacing fee
  ///         when: swap hook is zero address; beforeSwap call reverted; returned fee is zero.
  /// @param _swapHook Address of the hook contract.
  /// @param _swapParams Swap context passed to the hook.
  /// @param _factory Pool factory used to obtain the default tick-spacing fee.
  /// @param _tickSpacing Pool's tick spacing.
  /// @return The fee to apply throughout the swap loop.
  function beforeSwap(
    address _swapHook,
    ISwapHook.SwapParams memory _swapParams,
    address _factory,
    int24 _tickSpacing
  ) internal returns (uint24) {
    if (_swapHook != address(0)) {
      try ISwapHook(_swapHook).beforeSwap(_swapParams) returns (uint24 _fee) {
        if (_fee > 0) return cap(_fee);
      } catch {}
    }

    return ICLFactory(_factory).tickSpacingToFee(_tickSpacing);
  }

  /// @notice Calls the hook's `afterSwap` entry point and credits any returned post-swap fee to gauge fees.
  /// @param _swapHook Address of the hook contract.
  /// @param _swapParams Swap context passed to the hook.
  /// @param _state Mutable swap state used to derive the post-swap adjustment.
  /// @param _cache Swap cache used to derive the post-swap hook parameters.
  /// @param gaugeFees Storage gauge fee accumulator updated with any computed post-swap fee.
  function afterSwap(
    address _swapHook,
    ISwapHook.SwapParams memory _swapParams,
    CLPool.SwapState memory _state,
    CLPool.SwapCache memory _cache,
    CLPool.GaugeFees storage gaugeFees
  ) internal {
    if (_swapHook == address(0)) return;

    try ISwapHook(_swapHook).afterSwap(_swapParams, _state.toAfterSwapParams(_cache)) returns (uint24 _fee) {
      if (_fee == 0) return;

      _fee = cap(_fee);

      bool _exactInput = _swapParams.amountSpecified > 0;

      // 1. Get the abs amount of the token that was swapped.
      //    exactInput  (output token)
      //    exactOutput (input token)
      uint256 _swapAmount = _exactInput ? uint256(-_state.amountCalculated) : uint256(_state.amountCalculated);

      // 2. Compute fee in token units.
      uint256 _feeAmount = _swapAmount.mulDivRoundingUp(_fee, _DENOMINATOR);

      // 3. Apply the fee directly to amountCalculated.
      //    exactInput:  amountCalculated is negative => adding a fee to it
      //                 decreases the output the swapper receives.
      //    exactOutput: amountCalculated is positive => adding a fee to it
      //                 increases the input taken from the swapper.
      _state.amountCalculated += int256(_feeAmount);

      // 4. Credit the fee difference to the gauge.
      //    We can't mutate "exact" amount, hence
      //    we're mutating calculated parts of the swap.
      if (_exactInput) {
        // Credit OUTPUT token difference to the gauge.
        if (_swapParams.zeroForOne) gaugeFees.token1 += uint128(_feeAmount);
        else gaugeFees.token0 += uint128(_feeAmount);
      } else {
        // Credit INPUT token difference to the gauge.
        if (_swapParams.zeroForOne) gaugeFees.token0 += uint128(_feeAmount);
        else gaugeFees.token1 += uint128(_feeAmount);
      }
    } catch {}
  }

  /// @notice Calls the hook's `beforeFlash` entry point. Falls back to the pool's tick-spacing fee
  ///         when: swap hook is zero address; beforeFlash call reverted.
  /// @param _swapHook Address of the hook contract.
  /// @param _flashParams Arguments passed to the {CLPool.flash} function.
  /// @param _factory Pool factory used to obtain the default tick-spacing fee.
  /// @param _tickSpacing Pool's tick spacing.
  /// @return The fee to apply to flash loaned amounts.
  function beforeFlash(
    address _swapHook,
    ISwapHook.FlashParams memory _flashParams,
    address _factory,
    int24 _tickSpacing
  ) internal returns (uint24) {
    if (_swapHook != address(0)) {
      try ISwapHook(_swapHook).beforeFlash(_flashParams) returns (uint24 _fee) {
        return cap(_fee);
      } catch {}
    }

    return ICLFactory(_factory).tickSpacingToFee(_tickSpacing);
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  /// @notice Converts pool swap state and cache values into the hook's after-swap parameter struct.
  /// @param _state Current swap state.
  /// @param _cache Current swap cache.
  /// @return _afterSwapParams Converted state and cache of the swap.
  function toAfterSwapParams(
    CLPool.SwapState memory _state,
    CLPool.SwapCache memory _cache
  ) internal pure returns (ISwapHook.AfterSwapParams memory _afterSwapParams) {
    _afterSwapParams = ISwapHook.AfterSwapParams({
      amountSpecifiedRemaining: _state.amountSpecifiedRemaining,
      amountCalculated: _state.amountCalculated,
      fee: _state.fee,
      hasUpdatedFees: _state.hasUpdatedFees,
      feeGrowthGlobalX128: _state.feeGrowthGlobalX128,
      gaugeFee: _state.gaugeFee,
      liquidity: _state.liquidity,
      stakedLiquidity: _state.stakedLiquidity,
      tickCumulative: _cache.tickCumulative,
      secondsPerLiquidityCumulativeX128: _cache.secondsPerLiquidityCumulativeX128,
      computedLatestObservation: _cache.computedLatestObservation
    });
  }

  /// @notice Caps the provided `_fee` with `_SWAP_FEE_CEIL`.
  /// @param _fee The fee returned from the hook method.
  /// @return _cappedFee Capped fee: min(_fee, _SWAP_FEE_CEIL)
  function cap(uint24 _fee) internal pure returns (uint24 _cappedFee) {
    _cappedFee = _fee < _SWAP_FEE_CEIL ? _fee : _SWAP_FEE_CEIL;
  }
}
