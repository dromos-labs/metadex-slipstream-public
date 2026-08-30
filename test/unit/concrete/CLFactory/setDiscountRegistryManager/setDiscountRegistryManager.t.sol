// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {CLFactoryTest} from '../CLFactory.t.sol';
import {StdStorage, stdStorage} from 'forge-std/Test.sol';

contract UnitCLFactorySetDiscountRegistryManager is CLFactoryTest {
  using stdStorage for StdStorage;

  function test_WhenCallerIsntDiscountRegistryManager(address _caller) external {
    vm.assume(_caller != users.discountRegistryManager);
    vm.prank(_caller);
    // it reverts with NotDiscountRegistryManager
    vm.expectRevert('NotDiscountRegistryManager');
    poolFactory.setDiscountRegistryManager(address(0));
  }

  modifier whenCallerIsDiscountRegistryManager() {
    vm.startPrank(users.discountRegistryManager);
    _;
    vm.stopPrank();
  }

  function test_WhenNewDiscountRegistryManagerIsAddressZero() external whenCallerIsDiscountRegistryManager {
    // it reverts with DiscountRegistryManagerIsZero
    vm.expectRevert('DiscountRegistryManagerIsZero');
    poolFactory.setDiscountRegistryManager(address(0));
  }

  function test_WhenNewDiscountRegistryManagerIsntAddressZero(address _newDiscountRegistryManager)
    external
    whenCallerIsDiscountRegistryManager
  {
    vm.assume(_newDiscountRegistryManager != address(0));

    // it emits DiscountRegistryManagerChanged
    vm.expectEmit();
    emit DiscountRegistryManagerChanged(_newDiscountRegistryManager);

    poolFactory.setDiscountRegistryManager(_newDiscountRegistryManager);

    // it sets discountRegistryManager to new discountRegistryManager
    assertEq(address(poolFactory.discountRegistryManager()), _newDiscountRegistryManager);
  }
}
