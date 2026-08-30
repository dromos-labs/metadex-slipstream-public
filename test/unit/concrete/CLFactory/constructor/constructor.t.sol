// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import {CLFactory} from 'contracts/core/CLFactory.sol';

import {CLFactoryTest} from '../CLFactory.t.sol';

contract UnitCLFactoryConstructor is CLFactoryTest {
  function test_WhenOwnerIsAddressZero() external {
    // it reverts with OwnerIsZero
    vm.expectRevert(bytes('OwnerIsZero'));
    new CLFactory({
      _owner: address(0),
      _swapFeeManager: users.owner,
      _unstakedFeeManager: users.owner,
      _voter: address(voter),
      _poolImplementation: address(poolImplementation),
      _factoryRegistry: address(factoryRegistry),
      // TODO: Set default hook address
      _defaultSwapHook: address(0),
      _discountRegistryManager: users.discountRegistryManager,
      _clPoolTapeManager: users.clPoolTapeManager
    });
  }

  function test_WhenSwapFeeManagerIsAddressZero() external {
    // it reverts with SwapFeeManagerIsZero
    vm.expectRevert(bytes('SwapFeeManagerIsZero'));
    new CLFactory({
      _owner: users.owner,
      _swapFeeManager: address(0),
      _unstakedFeeManager: users.owner,
      _voter: address(voter),
      _poolImplementation: address(poolImplementation),
      _factoryRegistry: address(factoryRegistry),
      // TODO: Set default hook address
      _defaultSwapHook: address(0),
      _discountRegistryManager: users.discountRegistryManager,
      _clPoolTapeManager: users.clPoolTapeManager
    });
  }

  function test_WhenUnstakedFeeManagerIsAddressZero() external {
    // it reverts with UnstakedFeeManagerIsZero
    vm.expectRevert(bytes('UnstakedFeeManagerIsZero'));
    new CLFactory({
      _owner: users.owner,
      _swapFeeManager: users.owner,
      _unstakedFeeManager: address(0),
      _voter: address(voter),
      _poolImplementation: address(poolImplementation),
      _factoryRegistry: address(factoryRegistry),
      // TODO: Set default hook address
      _defaultSwapHook: address(0),
      _discountRegistryManager: users.discountRegistryManager,
      _clPoolTapeManager: users.clPoolTapeManager
    });
  }

  function test_WhenPoolImplementationIsAddressZero() external {
    // it reverts with PoolImplementationIsZero
    vm.expectRevert(bytes('PoolImplementationIsZero'));
    new CLFactory({
      _owner: users.owner,
      _swapFeeManager: users.owner,
      _unstakedFeeManager: users.owner,
      _voter: address(voter),
      _poolImplementation: address(0),
      _factoryRegistry: address(factoryRegistry),
      // TODO: Set default hook address
      _defaultSwapHook: address(0),
      _discountRegistryManager: users.discountRegistryManager,
      _clPoolTapeManager: users.clPoolTapeManager
    });
  }

  function test_WhenFactoryRegistryIsAddressZero() external {
    // it reverts with FactoryRegistryIsZero
    vm.expectRevert(bytes('FactoryRegistryIsZero'));
    new CLFactory({
      _owner: users.owner,
      _swapFeeManager: users.owner,
      _unstakedFeeManager: users.owner,
      _voter: address(voter),
      _poolImplementation: address(poolImplementation),
      _factoryRegistry: address(0),
      // TODO: Set default hook address
      _defaultSwapHook: address(0),
      _discountRegistryManager: users.discountRegistryManager,
      _clPoolTapeManager: users.clPoolTapeManager
    });
  }

  function test_WhenDiscountRegistryManagerIsAddressZero() external {
    // it reverts with DiscountRegistryManagerIsZero
    vm.expectRevert(bytes('DiscountRegistryManagerIsZero'));
    new CLFactory({
      _owner: users.owner,
      _swapFeeManager: users.owner,
      _unstakedFeeManager: users.owner,
      _voter: address(voter),
      _poolImplementation: address(poolImplementation),
      _factoryRegistry: address(factoryRegistry),
      // TODO: Set default hook address
      _defaultSwapHook: address(0),
      _discountRegistryManager: address(0),
      _clPoolTapeManager: users.clPoolTapeManager
    });
  }

  function test_WhenClPoolTapeManagerIsAddressZero() external {
    // it reverts with ClPoolTapeManagerIsZero
    vm.expectRevert(bytes('ClPoolTapeManagerIsZero'));
    new CLFactory({
      _owner: users.owner,
      _swapFeeManager: users.owner,
      _unstakedFeeManager: users.owner,
      _voter: address(voter),
      _poolImplementation: address(poolImplementation),
      _factoryRegistry: address(factoryRegistry),
      // TODO: Set default hook address
      _defaultSwapHook: address(0),
      _discountRegistryManager: users.discountRegistryManager,
      _clPoolTapeManager: address(0)
    });
  }

  function test_WhenAllParametersAreValid() external {
    // pranked as the owner since the constructor calls the owner-gated enableTickSpacing
    vm.prank(users.owner);
    CLFactory _factory = new CLFactory({
      _owner: users.owner,
      _swapFeeManager: users.owner,
      _unstakedFeeManager: users.owner,
      _voter: address(voter),
      _poolImplementation: address(poolImplementation),
      _factoryRegistry: address(factoryRegistry),
      // TODO: Set default hook address
      _defaultSwapHook: address(0),
      _discountRegistryManager: users.discountRegistryManager,
      _clPoolTapeManager: users.clPoolTapeManager
    });

    // it sets the factoryRegistry
    assertEq(address(_factory.factoryRegistry()), address(factoryRegistry));
  }
}
