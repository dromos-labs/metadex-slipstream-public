// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {CLFactoryTest} from '../CLFactory.t.sol';
import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {ICLFactory} from 'contracts/core/interfaces/ICLFactory.sol';

contract UnitCLFactorySetDiscountRegistry is CLFactoryTest {
  using stdStorage for StdStorage;

  function test_WhenCallerIsntDiscountRegistryManager(address _caller) external {
    vm.assume(_caller != users.discountRegistryManager);
    vm.prank(_caller);
    // it reverts with NotDiscountRegistryManager
    vm.expectRevert('NotDiscountRegistryManager');
    poolFactory.setDiscountRegistry(address(0));
  }

  modifier whenCallerIsDiscountRegistryManager() {
    vm.startPrank(users.discountRegistryManager);
    _;
    vm.stopPrank();
  }

  function test_WhenNewDiscountRegistryIsAddressZero() external whenCallerIsDiscountRegistryManager {
    // it reverts with DiscountRegistryIsZero
    vm.expectRevert('DiscountRegistryIsZero');
    poolFactory.setDiscountRegistry(address(0));
  }

  function test_WhenNewDiscountRegistryIsntAddressZero(
    address _oldDiscountRegistry,
    address _newDiscountRegistry
  ) external whenCallerIsDiscountRegistryManager {
    /// @dev Sets up either zero or non-zero state before changing the DR.
    _setDiscountRegistry(_oldDiscountRegistry);

    vm.assume(_newDiscountRegistry != address(0));

    // it emits DiscountRegistryChanged
    vm.expectEmit();
    emit DiscountRegistryChanged(_newDiscountRegistry);

    poolFactory.setDiscountRegistry(_newDiscountRegistry);

    // it sets discountRegistry to new discountRegistry
    assertEq(address(poolFactory.discountRegistry()), _newDiscountRegistry);
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  function _setDiscountRegistry(address _discountRegistry) internal {
    stdstore.target(address(poolFactory)).sig(ICLFactory.discountRegistry.selector).checked_write(_discountRegistry);
  }
}
