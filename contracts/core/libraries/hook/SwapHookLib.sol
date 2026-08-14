// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import {ExcessivelySafeCall} from '@nomad-xyz/excessively-safe-call/src/ExcessivelySafeCall.sol';

import {FullMath} from '../FullMath.sol';

import {ICLFactory} from 'contracts/core/interfaces/ICLFactory.sol';
import {ISwapHook} from 'contracts/core/interfaces/hook/ISwapHook.sol';

import {CLPool} from 'contracts/core/CLPool.sol';

/// @notice Helper library for invoking swap hook methods and translating pool swap state into hook inputs.
library SwapHookLib {
  using SwapHookLib for CLPool.SwapState;
  using ExcessivelySafeCall for address;
  using FullMath for uint256;

  /*////////////////////////////////////////////////////////////
                              CONSTANTS
  ////////////////////////////////////////////////////////////*/

  // TODO(future PRs/commits): review and assess sanity of these values.
  uint256 internal constant _SWAP_FEE_CEIL = 100_000;
  uint256 internal constant _DENOMINATOR = 1e6;

  uint256 private constant _SAFE_CALL_GAS_LIMIT = 500_000;
  uint16 private constant _SAFE_CALL_RETURN_DATA_SIZE = 32;

  /*////////////////////////////////////////////////////////////
                              FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Calls the hook's `beforeSwap` entry point or falls back to the pool's tick-spacing fee
  ///         when hook call: fails, returns malformed data, returns fee above the ceil.
  /// @param _swapHook Address of the hook contract.
  /// @param _swapParams Swap context passed to the hook.
  /// @param _factory Pool factory used to obtain the default tick-spacing fee.
  /// @param _tickSpacing Pool's tick spacing.
  /// @return _fee The fee to apply throughout the swap loop.
  function beforeSwap(
    address _swapHook,
    ISwapHook.SwapParams memory _swapParams,
    address _factory,
    int24 _tickSpacing
  ) internal returns (uint24 _fee) {
    if (_swapHook != address(0)) {
      (, _fee) = _safeCall(_swapHook, abi.encodeWithSelector(ISwapHook.beforeSwap.selector, _swapParams));
    }

    if (_fee == 0) _fee = ICLFactory(_factory).tickSpacingToFee(_tickSpacing);
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

    (, uint24 _fee) = _safeCall(
      _swapHook, abi.encodeWithSelector(ISwapHook.afterSwap.selector, _swapParams, _state.toAfterSwapParams(_cache))
    );

    if (_fee > 0) {
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
    }
  }

  /// @notice Calls the hook's `beforeFlash` entry point or falls back to the pool's tick-spacing fee
  ///         when hook call: fails, returns malformed data, returns fee above the ceil.
  /// @param _swapHook Address of the hook contract.
  /// @param _flashParams Arguments passed to the {CLPool.flash} function.
  /// @param _factory Pool factory used to obtain the default tick-spacing fee.
  /// @param _tickSpacing Pool's tick spacing.
  /// @return _fee Fee to apply to flash loaned amounts.
  function beforeFlash(
    address _swapHook,
    ISwapHook.FlashParams memory _flashParams,
    address _factory,
    int24 _tickSpacing
  ) internal returns (uint24 _fee) {
    bool _okFee;
    if (_swapHook != address(0)) {
      (_okFee, _fee) = _safeCall(_swapHook, abi.encodeWithSelector(ISwapHook.beforeFlash.selector, _flashParams));
    }

    if (!_okFee) _fee = ICLFactory(_factory).tickSpacingToFee(_tickSpacing);
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

  /// @notice Safely CALLs a hook function and returns a pips fee.
  /// @dev Returns 0 if the call: fails, returns malformed data, returns a fee above the ceiling.
  /// @param _swapHook Address of the hook contract to call.
  /// @param _hookData ABI-encoded hook's method selector and arguments.
  /// @return _okFee Whether the fee was succesfully obtained and decoded.
  /// @return _fee Decoded fee value, or 0.
  function _safeCall(address _swapHook, bytes memory _hookData) private returns (bool _okFee, uint24 _fee) {
    (bool _success, bytes memory _data) =
      _swapHook.excessivelySafeCall(_SAFE_CALL_GAS_LIMIT, _SAFE_CALL_RETURN_DATA_SIZE, _hookData);

    if (_success && _data.length == _SAFE_CALL_RETURN_DATA_SIZE) {
      uint256 _feeRaw = abi.decode(_data, (uint256));
      if (_feeRaw <= _SWAP_FEE_CEIL) {
        _fee = uint24(_feeRaw);
        _okFee = _success;
      }
    }
  }
}
