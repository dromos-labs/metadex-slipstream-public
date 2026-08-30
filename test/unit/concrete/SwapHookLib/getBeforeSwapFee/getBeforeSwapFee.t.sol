// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {SwapHookLib} from 'contracts/core/libraries/hook/SwapHookLib.sol';

import {ISwapHook} from 'contracts/core/interfaces/hook/ISwapHook.sol';

import {UnitSwapHookLib} from '../SwapHookLib.t.sol';

contract UnitSwapHookLibGetBeforeSwapFee is UnitSwapHookLib {
  address internal _pool = makeAddr('getBeforeSwapFeePool');

  function test_WhenSwapHookIsAddressZero(uint24 _tickSpacingFee) external {
    _tickSpacingFee = uint24(bound(uint256(_tickSpacingFee), 0, uint256(swapHookLib.SWAP_FEE_CEIL())));

    ISwapHook.SwapParams memory _swapParams;

    // it calls tickSpacingToFee on the factory
    _mockAndExpectTickSpacingToFee(TICK_SPACING_60, _tickSpacingFee);

    uint24 _hookFee = SwapHookLib.getBeforeSwapFee(address(0), _pool, _swapParams, factory, TICK_SPACING_60);

    // it returns tick-spacing fee from the factory call
    assertEq(uint256(_hookFee), uint256(_tickSpacingFee));
  }

  modifier whenSwapHookIsntAddressZero(
    ISwapHook.SwapParams memory _swapParams,
    bool _success,
    uint24 _fee,
    uint256 _feeFloor,
    uint256 _feeCeil
  ) {
    bytes memory _data = abi.encodeWithSelector(ISwapHook.getBeforeSwapFee.selector, _pool, _swapParams);

    _fee = uint24(bound(uint256(_fee), _feeFloor, _feeCeil));
    _mockAndExpectHookCall(_data, _success, _fee);
    _;
  }

  function test_WhenCallFails(
    ISwapHook.SwapParams memory _swapParams,
    uint24 _tickSpacingFee
  ) external whenSwapHookIsntAddressZero(_swapParams, false, 0, 0, 1) {
    _tickSpacingFee = uint24(bound(uint256(_tickSpacingFee), 0, uint256(swapHookLib.SWAP_FEE_CEIL())));

    // it calls tickSpacingToFee on the factory
    _mockAndExpectTickSpacingToFee(TICK_SPACING_60, _tickSpacingFee);

    uint24 _hookFee = SwapHookLib.getBeforeSwapFee(swapHook, _pool, _swapParams, factory, TICK_SPACING_60);

    // it returns tick-spacing fee from the factory call
    assertEq(uint256(_hookFee), uint256(_tickSpacingFee));
  }

  function test_WhenCallSucceedsButFeeIsGtFeeCeil(
    ISwapHook.SwapParams memory _swapParams,
    uint24 _fee
  )
    external
    whenSwapHookIsntAddressZero(_swapParams, true, _fee, uint256(swapHookLib.SWAP_FEE_CEIL() + 1), type(uint24).max)
  {
    _fee = uint24(bound(uint256(_fee), uint256(swapHookLib.SWAP_FEE_CEIL() + 1), type(uint24).max));

    uint24 _hookFee = SwapHookLib.getBeforeSwapFee(swapHook, _pool, _swapParams, factory, TICK_SPACING_60);

    // it returns tick-spacing fee from the factory call
    assertEq(uint256(_hookFee), swapHookLib.SWAP_FEE_CEIL());
  }

  function test_WhenCallSucceedsAndFeeIsLeqFeeCeil(
    ISwapHook.SwapParams memory _swapParams,
    uint24 _fee
  ) external whenSwapHookIsntAddressZero(_swapParams, true, _fee, 1, uint256(swapHookLib.SWAP_FEE_CEIL())) {
    _fee = uint24(bound(uint256(_fee), 1, uint256(swapHookLib.SWAP_FEE_CEIL())));

    // it returns fee from returndata of the call
    uint24 _hookFee = SwapHookLib.getBeforeSwapFee(swapHook, _pool, _swapParams, factory, TICK_SPACING_60);

    assertEq(uint256(_hookFee), uint256(_fee));
  }
}
