// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {SwapHookLib} from 'contracts/core/libraries/hook/SwapHookLib.sol';

import {ICLFactory} from 'contracts/core/interfaces/ICLFactory.sol';
import {ISwapHook} from 'contracts/core/interfaces/hook/ISwapHook.sol';

import {CLPoolTest} from '../CLPool.t.sol';

contract UnitCLPoolFee is CLPoolTest {
  address internal _swapHook = makeAddr('swapHook');
  address internal _caller = makeAddr('caller');

  function setUp() public override {
    super.setUp();
  }

  function test_WhenSwapHookIsAddressZero() external view {
    uint24 _tickSpacingFee = poolFactory.tickSpacingToFee(clPool.tickSpacing());

    // it returns tick-spacing fee from the factory
    assertEqUint(clPool.fee(), _tickSpacingFee);
  }

  modifier whenSwapHookIsntAddressZero() {
    vm.mockCall(
      clPool.factory(),
      0,
      abi.encodeWithSelector(ICLFactory.getPoolSwapHook.selector, address(clPool)),
      abi.encode(_swapHook)
    );
    vm.startPrank(_caller);
    _;
    vm.stopPrank();
  }

  function test_WhenCallFails() external whenSwapHookIsntAddressZero {
    ISwapHook.SwapParams memory _swapParams;
    _swapParams.caller = _caller;

    vm.mockCallRevert(
      _swapHook,
      abi.encodeWithSelector(ISwapHook.getBeforeSwapFee.selector, address(clPool), _swapParams),
      abi.encode('')
    );

    uint24 _tickSpacingFee = poolFactory.tickSpacingToFee(clPool.tickSpacing());

    // it returns tick-spacing fee from the factory call
    assertEqUint(clPool.fee(), _tickSpacingFee);
  }

  function test_WhenCallSucceedsButFeeIsGtFeeCeil(uint24 _fee) external whenSwapHookIsntAddressZero {
    _fee = uint24(bound(uint256(_fee), uint256(SwapHookLib._SWAP_FEE_CEIL + 1), type(uint24).max));

    ISwapHook.SwapParams memory _swapParams;
    _swapParams.caller = _caller;

    vm.mockCall(
      _swapHook,
      abi.encodeWithSelector(ISwapHook.getBeforeSwapFee.selector, address(clPool), _swapParams),
      abi.encode(_fee)
    );

    // it returns _SWAP_FEE_CEIL
    assertEqUint(clPool.fee(), SwapHookLib._SWAP_FEE_CEIL);
  }

  function test_WhenCallSucceedsAndFeeIsLeqFeeCeil(uint24 _fee) external whenSwapHookIsntAddressZero {
    _fee = uint24(bound(uint256(_fee), 1, uint256(SwapHookLib._SWAP_FEE_CEIL)));

    ISwapHook.SwapParams memory _swapParams;
    _swapParams.caller = _caller;

    vm.mockCall(
      _swapHook,
      abi.encodeWithSelector(ISwapHook.getBeforeSwapFee.selector, address(clPool), _swapParams),
      abi.encode(_fee)
    );

    // it returns fee
    assertEqUint(clPool.fee(), _fee);
  }
}
