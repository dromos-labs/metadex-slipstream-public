// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {CLFactoryTest} from '../CLFactory.t.sol';

contract UnitCLFactorySetPoolSwapHook is CLFactoryTest {
  function test_WhenCallerIsntSwapFeeManager(address _caller) external {
    vm.assume(_caller != users.feeManager);
    vm.prank(_caller);

    // it reverts with NotSwapFeeManager
    vm.expectRevert('NotSwapFeeManager');
    poolFactory.setPoolSwapHook(new address[](0), new address[](0));
  }

  modifier whenCallerIsSwapFeeManager() {
    vm.startPrank(users.feeManager);
    _;
  }

  function test_WhenPoolsAndSwapHooksLengthsMismatch(
    address[] memory _pools,
    address[] memory _swapHooks
  ) external whenCallerIsSwapFeeManager {
    vm.assume(_pools.length != _swapHooks.length);

    // it reverts with LMM
    vm.expectRevert(bytes('LMM'));
    poolFactory.setPoolSwapHook(_pools, _swapHooks);
  }

  function test_WhenPoolsAndSwapHooksLengthsMatch(uint256 _length) external whenCallerIsSwapFeeManager {
    _length = bound(_length, 1, 10);

    address[] memory _pools = new address[](_length);
    address[] memory _swapHooks = new address[](_length);
    for (uint256 i = 0; i < _length; i++) {
      _pools[i] = makeAddr(string(abi.encodePacked('pool', vm.toString(i))));
      _swapHooks[i] = makeAddr(string(abi.encodePacked('hook', vm.toString(i))));
    }

    // it emits PoolSwapHookChanged per pool
    for (uint256 i = 0; i < _length; i++) {
      vm.expectEmit();
      emit PoolSwapHookChanged(_pools[i], _swapHooks[i]);
    }

    poolFactory.setPoolSwapHook(_pools, _swapHooks);

    // it sets each pool poolSwapHook to its swap hook
    for (uint256 i = 0; i < _length; i++) {
      assertEq(poolFactory.poolSwapHook(_pools[i]), _swapHooks[i]);
    }
  }
}
