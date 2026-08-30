// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import {CLFactoryTest} from '../CLFactory.t.sol';

contract UnitCLFactorySetClPoolTapeManager is CLFactoryTest {
  function test_WhenCallerIsntClPoolTapeManager(address _caller) external {
    vm.assume(_caller != users.clPoolTapeManager);
    // it reverts with NotClPoolTapeManager
    vm.prank(_caller);
    vm.expectRevert(bytes('NotClPoolTapeManager'));
    poolFactory.setClPoolTapeManager(address(0));
  }

  modifier whenCallerIsClPoolTapeManager() {
    vm.startPrank(users.clPoolTapeManager);
    _;
    vm.stopPrank();
  }

  function test_WhenNewClPoolTapeManagerIsAddressZero() external whenCallerIsClPoolTapeManager {
    // it reverts with ClPoolTapeManagerIsZero
    vm.expectRevert(bytes('ClPoolTapeManagerIsZero'));
    poolFactory.setClPoolTapeManager(address(0));
  }

  function test_WhenNewClPoolTapeManagerIsntAddressZero(address _new) external whenCallerIsClPoolTapeManager {
    vm.assume(_new != address(0));
    // it emits ClPoolTapeManagerChanged
    vm.expectEmit();
    emit ClPoolTapeManagerChanged(_new);
    poolFactory.setClPoolTapeManager(_new);
    // it sets clPoolTapeManager to new clPoolTapeManager
    assertEq(poolFactory.clPoolTapeManager(), _new);
  }
}
