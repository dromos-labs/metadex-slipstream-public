// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import {SwapHookLib} from 'contracts/core/libraries/hook/SwapHookLib.sol';

import {ICLFactory} from 'contracts/core/interfaces/ICLFactory.sol';

import {BaseFixture} from 'test/BaseFixture.sol';
import {MockSwapHookLib} from 'test/mocks/MockSwapHookLib.sol';

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

contract UnitSwapHookLib is BaseFixture {
  using stdStorage for StdStorage;

  MockSwapHookLib internal swapHookLib;
  address public swapHook = makeAddr('SwapHookTestSwapHook');
  address public factory = makeAddr('SwapHookTestFactory');

  uint256 internal _FEE_CEIL = SwapHookLib._SWAP_FEE_CEIL;
  uint256 internal _DENOMINATOR = SwapHookLib._DENOMINATOR;

  function setUp() public virtual override {
    super.setUp();

    swapHookLib = new MockSwapHookLib();
  }

  /*////////////////////////////////////////////////////////////
                              STORAGE HELPERS
  ////////////////////////////////////////////////////////////*/

  /// @dev Writes to {MockSwapHookLib.gaugeFees} storage variable (slot 0).
  function _setGaugeFees(uint128 _token0, uint128 _token1) internal {
    stdstore.target(address(swapHookLib)).sig('gaugeFees()').enable_packed_slots().depth(0).checked_write(_token0);
    stdstore.target(address(swapHookLib)).sig('gaugeFees()').enable_packed_slots().depth(1).checked_write(_token1);
  }

  /*///////////////////////////////////////////////////////////////
                              MOCK HELPERS
  //////////////////////////////////////////////////////////////*/

  function _mockAndExpectHookCall(bytes memory _data, bool _success, uint24 _fee) internal {
    if (_success) {
      vm.mockCall(swapHook, 0, _data, abi.encode(_fee));
      vm.expectCall(swapHook, _data);
    } else {
      vm.mockCallRevert(swapHook, 0, _data, abi.encode(0));
    }
  }

  function _mockAndExpectTickSpacingToFee(int24 _tickSpacing, uint24 _fee) internal {
    bytes memory _data = abi.encodeWithSelector(ICLFactory.tickSpacingToFee.selector, _tickSpacing);

    vm.mockCall(factory, 0, _data, abi.encode(_fee));
    vm.expectCall(factory, 0, _data);
  }
}
