// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {CLFactoryTest} from '../CLFactory.t.sol';

contract UnitCLFactorySetDefaultSwapHook is CLFactoryTest {
  function test_WhenCallerIsntSwapFeeManager(address _caller) external {
    vm.assume(_caller != users.feeManager);
    vm.prank(_caller);

    // it reverts with NotSwapFeeManager
    vm.expectRevert('NotSwapFeeManager');
    poolFactory.setDefaultSwapHook(address(0));
  }

  function test_WhenCallerIsSwapFeeManager(address _newSwapHook) external {
    vm.assume(_newSwapHook != address(0));

    // it emits DefaultSwapHookChanged
    vm.expectEmit();
    emit DefaultSwapHookChanged(_newSwapHook);

    vm.prank(users.feeManager);
    poolFactory.setDefaultSwapHook(_newSwapHook);

    // it sets defaultSwapHook to the new swapHook
    assertEq(poolFactory.defaultSwapHook(), _newSwapHook);
  }
}
