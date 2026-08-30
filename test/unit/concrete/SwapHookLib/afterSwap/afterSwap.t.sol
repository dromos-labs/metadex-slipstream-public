// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import {UnitSwapHookLib} from '../SwapHookLib.t.sol';

import {CLPool} from 'contracts/core/CLPool.sol';
import {ISwapHook} from 'contracts/core/interfaces/hook/ISwapHook.sol';

import {SwapHookLib} from 'contracts/core/libraries/hook/SwapHookLib.sol';

contract UnitSwapHookLibAfterSwap is UnitSwapHookLib {
  using SwapHookLib for CLPool.SwapState;

  // [floor, ceil] values for bounding `amountCalculated`.
  int256 private immutable AMT_CALC_FLOOR = int256(_DENOMINATOR); // prevent rounding to 0 during div by 1e6
  int256 private immutable AMT_CALC_CEIL = int256(type(int128).max) / int128(_FEE_CEIL);

  function test_WhenSwapHookIsAddressZero() external {
    ISwapHook.SwapParams memory _swapParams;
    CLPool.SwapState memory _state;

    vm.record();
    swapHookLib.afterSwap(address(0), _swapParams, _state);

    // it skips writing to gaugeFees
    _assertGaugeFeesUnmodified();
  }

  /// @dev Struct to avoid stack too deep.
  struct AfterSwap {
    ISwapHook.SwapParams swapParams;
    CLPool.SwapState state;
    bool zeroForOne;
    bool success;
    uint24 fee;
    uint256 feeFloor;
    uint256 feeCeil;
  }

  modifier whenSwapHookIsntAddressZero(AfterSwap memory _as) {
    _as.swapParams.zeroForOne = _as.zeroForOne;

    bytes memory _data = abi.encodeWithSelector(
      ISwapHook.afterSwap.selector, _as.swapParams, _as.state.toAfterSwapParams(swapHookLib.nilCache())
    );

    _as.fee = uint24(bound(uint256(_as.fee), _as.feeFloor, _as.feeCeil));
    _mockAndExpectHookCall(_data, _as.success, _as.fee);
    _;
  }

  function test_WhenCallFails(
    ISwapHook.SwapParams memory _swapParams,
    CLPool.SwapState memory _state
  )
    external
    whenSwapHookIsntAddressZero(AfterSwap({
        swapParams: _swapParams, state: _state, zeroForOne: false, success: false, fee: 0, feeFloor: 0, feeCeil: 0
      }))
  {
    vm.record();
    swapHookLib.afterSwap(swapHook, _swapParams, _state);

    _assertGaugeFeesUnmodified();
  }

  function test_WhenCallSucceedsButFeeIsGtFeeCeil(
    ISwapHook.SwapParams memory _swapParams,
    CLPool.SwapState memory _state,
    uint128 _gaugeToken1,
    uint24 _fee
  )
    external
    whenAmountSpecifiedIsGtZero(_swapParams, _state)
    whenSwapHookIsntAddressZero(AfterSwap({
        swapParams: _swapParams,
        state: _state,
        zeroForOne: true,
        success: true,
        fee: _fee,
        feeFloor: _FEE_CEIL + 1,
        feeCeil: type(uint24).max
      }))
  {
    _fee = uint24(bound(uint256(_fee), _FEE_CEIL + 1, type(uint24).max));
    _state.amountCalculated = bound(_state.amountCalculated, -AMT_CALC_CEIL, -AMT_CALC_FLOOR);

    // Fee is capped as that would mimic the behavior of the afterSwap function.
    uint256 _feeAmount = swapHookLib.getFeeAmount(uint256(-_state.amountCalculated), SwapHookLib._SWAP_FEE_CEIL);

    // Prevent overflow.
    _gaugeToken1 = uint128(bound(uint256(_gaugeToken1), 0, type(uint128).max - _feeAmount));

    _setGaugeFees(0, _gaugeToken1);

    int256 _amountCalculatedAfter = swapHookLib.afterSwap(swapHook, _swapParams, _state);

    (uint128 _token0, uint128 _token1) = swapHookLib.gaugeFees();

    // it writes to gaugeFees using _SWAP_FEE_CEIL
    assertEq(_amountCalculatedAfter, _state.amountCalculated + int256(_feeAmount));
    assertEq(_token1, _gaugeToken1 + _feeAmount);
    assertEq(uint256(_token0), 0);
  }

  modifier whenCallSucceedsAndFeeIsLeqFeeCeil(uint24 _fee) {
    _fee = uint24(bound(uint256(_fee), 1, _FEE_CEIL));
    _;
  }

  /*////////////////////////////////////////////////////////////
                          EXACT INPUT TESTS
  ////////////////////////////////////////////////////////////*/

  /// @dev Positive `amountSpecified` means that `amountCalculated` will be negative.
  /// @dev Positive `amountSpecified` => `exactInput` swap.
  modifier whenAmountSpecifiedIsGtZero(ISwapHook.SwapParams memory _swapParams, CLPool.SwapState memory _state) {
    /// @dev We don't care about amount's actual value, since we're only
    ///      using it to determine if the swap is exact input or output.
    _swapParams.amountSpecified = 1;
    // floor/ceil values are negated, cuz calculated amount is negative.
    _state.amountCalculated = bound(_state.amountCalculated, -AMT_CALC_CEIL, -AMT_CALC_FLOOR);
    _;
  }

  function test_WhenSwapIsZeroForOneAndExactInput(
    ISwapHook.SwapParams memory _swapParams,
    CLPool.SwapState memory _state,
    uint128 _gaugeToken1,
    uint24 _fee
  )
    external
    whenCallSucceedsAndFeeIsLeqFeeCeil(_fee)
    whenAmountSpecifiedIsGtZero(_swapParams, _state)
    whenSwapHookIsntAddressZero(AfterSwap({
        swapParams: _swapParams,
        state: _state,
        zeroForOne: true,
        success: true,
        fee: _fee,
        feeFloor: 1,
        feeCeil: _FEE_CEIL
      }))
  {
    _exactInputTest({
      _swapParams: _swapParams, _state: _state, _gaugeState: _gaugeToken1, _fee: _fee, _zeroForOne: true
    });
  }

  function test_WhenSwapIsOneForZeroAndExactInput(
    ISwapHook.SwapParams memory _swapParams,
    CLPool.SwapState memory _state,
    uint128 _gaugeToken0,
    uint24 _fee
  )
    external
    whenCallSucceedsAndFeeIsLeqFeeCeil(_fee)
    whenAmountSpecifiedIsGtZero(_swapParams, _state)
    whenSwapHookIsntAddressZero(AfterSwap({
        swapParams: _swapParams,
        state: _state,
        zeroForOne: false,
        success: true,
        fee: _fee,
        feeFloor: 1,
        feeCeil: _FEE_CEIL
      }))
  {
    _exactInputTest({
      _swapParams: _swapParams, _state: _state, _gaugeState: _gaugeToken0, _fee: _fee, _zeroForOne: false
    });
  }

  /*////////////////////////////////////////////////////////////
                          EXACT OUTPUT TESTS
  ////////////////////////////////////////////////////////////*/

  /// @dev Negative `amountSpecified` means that `amountCalculated` will be positive.
  /// @dev Negative `amountSpecified` => `exactOutput` swap.
  modifier whenAmountSpecifiedIsLtZero(ISwapHook.SwapParams memory _swapParams, CLPool.SwapState memory _state) {
    _swapParams.amountSpecified = -1;
    _state.amountCalculated = bound(_state.amountCalculated, AMT_CALC_FLOOR, AMT_CALC_CEIL);
    _;
  }

  function test_WhenSwapIsZeroForOneAndExactOutput(
    ISwapHook.SwapParams memory _swapParams,
    CLPool.SwapState memory _state,
    uint128 _gaugeToken0,
    uint24 _fee
  )
    external
    whenCallSucceedsAndFeeIsLeqFeeCeil(_fee)
    whenAmountSpecifiedIsLtZero(_swapParams, _state)
    whenSwapHookIsntAddressZero(AfterSwap({
        swapParams: _swapParams,
        state: _state,
        zeroForOne: true,
        success: true,
        fee: _fee,
        feeFloor: 1,
        feeCeil: _FEE_CEIL
      }))
  {
    _exactOutputTest({
      _swapParams: _swapParams, _state: _state, _gaugeState: _gaugeToken0, _fee: _fee, _zeroForOne: true
    });
  }

  function test_WhenSwapIsOneForZeroAndExactOutput(
    ISwapHook.SwapParams memory _swapParams,
    CLPool.SwapState memory _state,
    uint128 _gaugeToken1,
    uint24 _fee
  )
    external
    whenCallSucceedsAndFeeIsLeqFeeCeil(_fee)
    whenAmountSpecifiedIsLtZero(_swapParams, _state)
    whenSwapHookIsntAddressZero(AfterSwap({
        swapParams: _swapParams,
        state: _state,
        zeroForOne: false,
        success: true,
        fee: _fee,
        feeFloor: 1,
        feeCeil: _FEE_CEIL
      }))
  {
    _exactOutputTest({
      _swapParams: _swapParams, _state: _state, _gaugeState: _gaugeToken1, _fee: _fee, _zeroForOne: false
    });
  }

  /*////////////////////////////////////////////////////////////
                          INTERNAL TESTS
  ////////////////////////////////////////////////////////////*/

  function _exactInputTest(
    ISwapHook.SwapParams memory _swapParams,
    CLPool.SwapState memory _state,
    uint128 _gaugeState,
    uint24 _fee,
    bool _zeroForOne
  ) internal {
    _fee = uint24(bound(uint256(_fee), 1, _FEE_CEIL));
    _state.amountCalculated = bound(_state.amountCalculated, -AMT_CALC_CEIL, -AMT_CALC_FLOOR);

    uint256 _feeAmount = swapHookLib.getFeeAmount(uint256(-_state.amountCalculated), _fee);

    // Prevent overflow.
    _gaugeState = uint128(bound(uint256(_gaugeState), 0, type(uint128).max - _feeAmount));

    if (_zeroForOne) _setGaugeFees(0, _gaugeState);
    else _setGaugeFees(_gaugeState, 0);

    int256 _amountCalculatedAfter = swapHookLib.afterSwap(swapHook, _swapParams, _state);

    (uint128 _token0, uint128 _token1) = swapHookLib.gaugeFees();

    // it decreases SwapState.amountCalculated by fee amount
    assertEq(_amountCalculatedAfter, _state.amountCalculated + int256(_feeAmount));

    if (_zeroForOne) {
      // it increases gaugeFees.token1 by fee amount
      assertEq(_token1, _gaugeState + _feeAmount);
      assertEq(uint256(_token0), 0);
    } else {
      // it increases gaugeFees.token0 by fee amount
      assertEq(_token0, _gaugeState + _feeAmount);
      assertEq(uint256(_token1), 0);
    }
  }

  function _exactOutputTest(
    ISwapHook.SwapParams memory _swapParams,
    CLPool.SwapState memory _state,
    uint128 _gaugeState,
    uint24 _fee,
    bool _zeroForOne
  ) internal {
    _fee = uint24(bound(uint256(_fee), 1, _FEE_CEIL));
    _state.amountCalculated = bound(_state.amountCalculated, AMT_CALC_FLOOR, AMT_CALC_CEIL);

    uint256 _feeAmount = swapHookLib.getFeeAmount(uint256(_state.amountCalculated), _fee);

    // Prevent overflow.
    _gaugeState = uint128(bound(uint256(_gaugeState), 0, type(uint128).max - _feeAmount));

    if (_zeroForOne) _setGaugeFees(_gaugeState, 0);
    else _setGaugeFees(0, _gaugeState);

    int256 _amountCalculatedAfter = swapHookLib.afterSwap(swapHook, _swapParams, _state);

    (uint128 _token0, uint128 _token1) = swapHookLib.gaugeFees();

    // it increases SwapState.amountCalculated by fee amount
    assertEq(_amountCalculatedAfter, _state.amountCalculated + int256(_feeAmount));

    if (_zeroForOne) {
      // it increases gaugeFees.token0 by fee amount
      assertEq(_token0, (_gaugeState + _feeAmount));
      assertEq(uint256(_token1), 0);
    } else {
      // it increases gaugeFees.token1 by fee amount
      assertEq(_token1, (_gaugeState + _feeAmount));
      assertEq(uint256(_token0), 0);
    }
  }

  function _assertGaugeFeesUnmodified() internal {
    (bytes32[] memory _sloads, bytes32[] memory _sstores) = vm.accesses(address(swapHookLib));

    // it skips writing to gaugeFees
    assertEq(_sloads.length, 0);
    assertEq(_sstores.length, 0);

    (uint128 _token0, uint128 _token1) = swapHookLib.gaugeFees();
    assertEq(uint256(_token0), 0);
    assertEq(uint256(_token1), 0);
  }
}
