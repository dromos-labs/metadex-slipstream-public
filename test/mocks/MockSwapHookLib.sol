// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {FullMath} from 'contracts/core/libraries/FullMath.sol';
import {SwapHookLib} from 'contracts/core/libraries/hook/SwapHookLib.sol';

import {ISwapHook} from 'contracts/core/interfaces/hook/ISwapHook.sol';

import {CLPool} from 'contracts/core/CLPool.sol';

contract MockSwapHookLib {
  using SwapHookLib for address;
  using SwapHookLib for CLPool.SwapState;
  using FullMath for uint256;

  uint24 public constant SWAP_FEE_CEIL = 100_000;
  uint256 public constant DENOMINATOR = 1e6;

  CLPool.GaugeFees public gaugeFees;

  /*////////////////////////////////////////////////////////////
                              WRAPPERS
  ////////////////////////////////////////////////////////////*/

  function beforeSwap(
    address _swapHook,
    ISwapHook.SwapParams memory _swapParams,
    address _factory,
    int24 _tickSpacing
  ) external returns (uint24 _fee) {
    return _swapHook.beforeSwap(_swapParams, _factory, _tickSpacing);
  }

  /// @return _amountCalculated Since memory struct CLPool.SwapState is mutated
  ///         inside an internal lib function we need to return the mutated value
  ///         of calculated amount, because at a top-level contract call
  ///         the struct won't be mutated.
  function afterSwap(
    address _swapHook,
    ISwapHook.SwapParams memory _swapParams,
    CLPool.SwapState memory _state
  ) external returns (int256 _amountCalculated) {
    /// @dev We don't care about `CLPool.SwapCache` in this particular case.
    _swapHook.afterSwap(_swapParams, _state, nilCache(), gaugeFees);
    _amountCalculated = _state.amountCalculated;
  }

  function beforeFlash(
    address _swapHook,
    ISwapHook.FlashParams memory _flashParams,
    address _factory,
    int24 _tickSpacing
  ) external returns (uint24 _fee) {
    return _swapHook.beforeFlash(_flashParams, _factory, _tickSpacing);
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  /// @param _swapAmount _exactInput ? uint256(-_state.amountCalculated) : uint256(_state.amountCalculated)
  function getFeeAmount(uint256 _swapAmount, uint24 _fee) external pure returns (uint256 _feeAmount) {
    _feeAmount = _swapAmount.mulDivRoundingUp(_fee, DENOMINATOR);
  }

  /// @dev Returns empty `CLPool.SwapCache` struct.
  function nilCache() public pure returns (CLPool.SwapCache memory _cache) {}
}
