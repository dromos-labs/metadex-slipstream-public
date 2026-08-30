// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {SwapHookLib} from 'contracts/core/libraries/hook/SwapHookLib.sol';

import {ISwapHook} from 'contracts/core/interfaces/hook/ISwapHook.sol';

import {UnitSwapHookLib} from '../SwapHookLib.t.sol';

contract UnitSwapHookLibGetAfterSwapFee is UnitSwapHookLib {
  address internal _pool = makeAddr('getAfterSwapFeePool');

  function test_WhenSwapHookIsAddressZero() external {
    ISwapHook.SwapParams memory _swapParams;
    ISwapHook.AfterSwapParams memory _afterSwapParams;

    uint24 _hookFee = SwapHookLib.getAfterSwapFee(address(0), _pool, _swapParams, _afterSwapParams);

    // it returns 0
    assertEq(uint256(_hookFee), 0);
  }

  modifier whenSwapHookIsntAddressZero(
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams,
    bool _success,
    uint24 _fee,
    uint256 _feeFloor,
    uint256 _feeCeil
  ) {
    bytes memory _data =
      abi.encodeWithSelector(ISwapHook.getAfterSwapFee.selector, _pool, _swapParams, _afterSwapParams);

    _fee = uint24(bound(uint256(_fee), _feeFloor, _feeCeil));
    _mockAndExpectHookCall(_data, _success, _fee);
    _;
  }

  function test_WhenCallFails(
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams
  ) external whenSwapHookIsntAddressZero(_swapParams, _afterSwapParams, false, 0, 0, 1) {
    uint24 _hookFee = SwapHookLib.getAfterSwapFee(swapHook, _pool, _swapParams, _afterSwapParams);

    // it returns 0
    assertEq(uint256(_hookFee), 0);
  }

  function test_WhenCallSucceedsButFeeIsGtFeeCeil(
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams,
    uint24 _fee
  )
    external
    whenSwapHookIsntAddressZero(
      _swapParams, _afterSwapParams, true, _fee, uint256(swapHookLib.SWAP_FEE_CEIL() + 1), type(uint24).max
    )
  {
    _fee = uint24(bound(uint256(_fee), uint256(swapHookLib.SWAP_FEE_CEIL() + 1), type(uint24).max));

    uint24 _hookFee = SwapHookLib.getAfterSwapFee(swapHook, _pool, _swapParams, _afterSwapParams);

    // it returns _SWAP_FEE_CEIL
    assertEq(uint256(_hookFee), swapHookLib.SWAP_FEE_CEIL());
  }

  function test_WhenCallSucceedsAndFeeIsLeqFeeCeil(
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams,
    uint24 _fee
  )
    external
    whenSwapHookIsntAddressZero(_swapParams, _afterSwapParams, true, _fee, 1, uint256(swapHookLib.SWAP_FEE_CEIL()))
  {
    _fee = uint24(bound(uint256(_fee), 1, uint256(swapHookLib.SWAP_FEE_CEIL())));

    uint24 _hookFee = SwapHookLib.getAfterSwapFee(swapHook, _pool, _swapParams, _afterSwapParams);

    // it returns fee
    assertEq(uint256(_hookFee), uint256(_fee));
  }
}
