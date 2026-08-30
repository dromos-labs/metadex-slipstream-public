// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import {CLFactoryTest} from '../CLFactory.t.sol';

contract UnitCLFactorySetClPoolTape is CLFactoryTest {
  function test_WhenCallerIsntClPoolTapeManager(address _caller) external {
    vm.assume(_caller != users.clPoolTapeManager);
    // it reverts with NotClPoolTapeManager
    vm.prank(_caller);
    vm.expectRevert(bytes('NotClPoolTapeManager'));
    poolFactory.setClPoolTape(address(0));
  }

  function test_WhenCallerIsClPoolTapeManager(address _new) external {
    // it emits ClPoolTapeChanged
    vm.expectEmit();
    emit ClPoolTapeChanged(_new);
    vm.prank(users.clPoolTapeManager);
    poolFactory.setClPoolTape(_new);
    // it sets clPoolTape to new clPoolTape
    assertEq(poolFactory.clPoolTape(), _new);
  }
}
