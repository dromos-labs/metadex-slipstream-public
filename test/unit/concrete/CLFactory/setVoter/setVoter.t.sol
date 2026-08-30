// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import {CLFactory} from 'contracts/core/CLFactory.sol';

import {CLFactoryTest} from '../CLFactory.t.sol';

contract UnitCLFactorySetVoter is CLFactoryTest {
  CLFactory public voterlessFactory;

  function setUp() public override {
    super.setUp();
    // factory deployed before the voter exists, so voter starts unset
    vm.prank(users.owner);
    voterlessFactory = new CLFactory({
      _owner: users.owner,
      _swapFeeManager: users.owner,
      _unstakedFeeManager: users.owner,
      _voter: address(0),
      _poolImplementation: address(poolImplementation),
      _factoryRegistry: address(factoryRegistry),
      _defaultSwapHook: address(0),
      _discountRegistryManager: users.discountRegistryManager,
      _clPoolTapeManager: users.clPoolTapeManager
    });
  }

  function test_WhenCallerIsntOwner(address _caller) external {
    vm.assume(_caller != users.owner);
    // it reverts with NotOwner
    vm.prank(_caller);
    vm.expectRevert(bytes('NotOwner'));
    voterlessFactory.setVoter(address(voter));
  }

  modifier whenCallerIsOwner() {
    vm.startPrank(users.owner);
    _;
    vm.stopPrank();
  }

  function test_WhenVoterIsAlreadySet(address _new) external whenCallerIsOwner {
    // it reverts with VoterAlreadySet
    vm.expectRevert(bytes('VoterAlreadySet'));
    poolFactory.setVoter(_new);
  }

  modifier whenVoterIsntSet() {
    _;
  }

  function test_WhenNewVoterIsAddressZero() external whenCallerIsOwner whenVoterIsntSet {
    // it reverts with VoterIsZero
    vm.expectRevert(bytes('VoterIsZero'));
    voterlessFactory.setVoter(address(0));
  }

  function test_WhenNewVoterIsntAddressZero(address _new) external whenCallerIsOwner whenVoterIsntSet {
    vm.assume(_new != address(0));
    // it emits VoterSet
    vm.expectEmit();
    emit VoterSet(_new);
    voterlessFactory.setVoter(_new);
    // it sets voter to new voter
    assertEq(address(voterlessFactory.voter()), _new);
  }
}
