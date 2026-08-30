// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {ICLSwapCallback} from 'contracts/core/interfaces/callback/ICLSwapCallback.sol';

/// @notice Minimal CL pool stub that performs the real swap-callback round-trip.
/// @dev Unlike `vm.mockCall`, this actually invokes `uniswapV3SwapCallback` with pool-shaped signed deltas, so the
///      quoter's exact-input vs exact-output classification — which the mocked suites bypass — runs for real. Only the
///      surface the quoter reads is implemented; the pool math is canned via `configure`.
contract ClSwapProbe {
  bytes32 public constant POOL_TYPE = 'CL';
  int24 public constant tickSpacing = 1;

  address public immutable factory;
  address public immutable token0;
  address public immutable token1;

  uint160 private _configuredSqrtPriceX96;
  int24 private _configuredTick; // the pre-swap tick, and what the quoter reads once the callback has unwound
  int24 private _configuredTickAfter; // the tick the callback observes mid-swap
  uint256 private _configuredInputOwed; // amount the pool charges, reported as the positive delta on the input token
  uint256 private _configuredOutputSent; // amount the pool delivers, reported as the negative delta on the output token
  mapping(int16 => uint256) private _bitmaps;

  constructor(address _factory, address _token0, address _token1) {
    factory = _factory;
    token0 = _token0;
    token1 = _token1;
  }

  /// @notice Sets the deltas the next swap reports and the slot0 the quoter reads.
  /// @dev Holds the tick still across the swap, so no tick is crossed. Call `configureCrossing` afterwards to move it.
  function configure(uint256 _inputOwed, uint256 _outputSent, uint160 _sqrtPriceX96, int24 _tick) external {
    _configuredInputOwed = _inputOwed;
    _configuredOutputSent = _outputSent;
    _configuredSqrtPriceX96 = _sqrtPriceX96;
    _configuredTick = _tick;
    _configuredTickAfter = _tick;
  }

  /// @notice Moves the tick across the swap and populates one word of the tick bitmap, so the quoter counts a real
  ///         crossing rather than the degenerate zero of a still tick and an empty bitmap.
  /// @dev Must follow `configure`, which resets the post-swap tick to the pre-swap one.
  function configureCrossing(int24 _tickAfter, int16 _wordPos, uint256 _bitmap) external {
    _configuredTickAfter = _tickAfter;
    _bitmaps[_wordPos] = _bitmap;
  }

  /// @dev Reports the input token as owed to the pool (positive) and the output token as sent (negative), then hands
  ///      control to the callback, which reverts with the encoded quote.
  function swap(address, bool zeroForOne, int256, uint160, bytes calldata data) external returns (int256, int256) {
    (int256 amount0, int256 amount1) = zeroForOne
      ? (int256(_configuredInputOwed), -int256(_configuredOutputSent))
      : (-int256(_configuredOutputSent), int256(_configuredInputOwed));
    // a real pool's tick has already moved by the time it calls back; the callback's revert rolls this write back, so
    // the quoter's post-catch read sees the pre-swap tick, which is exactly the pairing it counts across
    _configuredTick = _configuredTickAfter;
    ICLSwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
    return (amount0, amount1); // unreachable: the callback always reverts
  }

  function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool) {
    return (_configuredSqrtPriceX96, _configuredTick, 0, 0, 0, false);
  }

  function tickBitmap(int16 _wordPos) external view returns (uint256) {
    return _bitmaps[_wordPos];
  }
}
