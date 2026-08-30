// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {ICLFactory} from 'contracts/core/interfaces/ICLFactory.sol';

import {CLFactoryTest} from '../CLFactory.t.sol';

contract UnitCLFactoryGetPoolSwapHook is CLFactoryTest {
  using stdStorage for StdStorage;

  function test_WhenThePoolSwapHookIsSet(address _pool, address _poolSwapHook) external {
    vm.assume(_poolSwapHook != address(0));

    stdstore.target(address(poolFactory)).sig(ICLFactory.poolSwapHook.selector).with_key(_pool)
      .checked_write(_poolSwapHook);

    // it returns the pool swap hook
    assertEq(poolFactory.getPoolSwapHook(_pool), _poolSwapHook);
  }

  function test_WhenThePoolSwapHookIsntSet(address _pool, address _defaultSwapHook) external {
    stdstore.target(address(poolFactory)).sig(ICLFactory.defaultSwapHook.selector).checked_write(_defaultSwapHook);

    // it returns the default swap hook
    assertEq(poolFactory.getPoolSwapHook(_pool), _defaultSwapHook);
  }
}
