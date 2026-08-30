// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {TickMath} from 'contracts/core/libraries/TickMath.sol';

import {CLPoolTest} from '../CLPool.t.sol';

contract UnitCLPoolGetFeeGrowthInside is CLPoolTest {
  function test_WhenTickLowerIsGtTickUpper(int256 _tickLower, int256 _tickUpper) external {
    _tickUpper = bound(_tickUpper, type(int24).min, type(int24).max - 1);
    _tickLower = bound(_tickLower, _tickUpper, type(int24).max);

    // it reverts with TLU
    vm.expectRevert(bytes('TLU'));
    clPool.getFeeGrowthInside(int24(_tickLower), int24(_tickUpper));
  }

  function test_WhenTickLowerIsLtMIN_TICK() external {
    // it reverts with TLM
    vm.expectRevert(bytes('TLM'));
    clPool.getFeeGrowthInside(TickMath.MIN_TICK - 1, int24(0));
  }

  function test_WhenTickUpperIsGtMAX_TICK() external {
    // it reverts with TUM
    vm.expectRevert(bytes('TUM'));
    clPool.getFeeGrowthInside(int24(0), TickMath.MAX_TICK + 1);
  }

  struct FeeGrowthCache {
    uint256 lower0;
    uint256 lower1;
    uint256 upper0;
    uint256 upper1;
    uint256 global0;
    uint256 global1;
  }

  function test_WhenTickRangeIsValid(
    int256 _tickLower,
    int256 _tickUpper,
    int256 _currentTick,
    FeeGrowthCache memory _growth
  ) external {
    _tickLower = bound(_tickLower, TickMath.MIN_TICK, TickMath.MAX_TICK - 1);
    _tickUpper = bound(_tickUpper, _tickLower + 1, TickMath.MAX_TICK);
    _currentTick = bound(_currentTick, TickMath.MIN_TICK, TickMath.MAX_TICK);

    _growth.lower0 = bound(_growth.lower0, 1, type(uint128).max);
    _growth.lower1 = bound(_growth.lower1, 1, type(uint128).max);
    _growth.upper0 = bound(_growth.upper0, 1, type(uint128).max);
    _growth.upper1 = bound(_growth.upper1, 1, type(uint128).max);
    _growth.global0 = bound(_growth.global0, 1, type(uint128).max);
    _growth.global1 = bound(_growth.global1, 1, type(uint128).max);

    _setFeeGrowthGlobal0X128(address(clPool), _growth.global0);
    _setFeeGrowthGlobal1X128(address(clPool), _growth.global1);
    _setTickFeeGrowthOutside0X128(address(clPool), int24(_tickLower), _growth.lower0);
    _setTickFeeGrowthOutside1X128(address(clPool), int24(_tickLower), _growth.lower1);
    _setTickFeeGrowthOutside0X128(address(clPool), int24(_tickUpper), _growth.upper0);
    _setTickFeeGrowthOutside1X128(address(clPool), int24(_tickUpper), _growth.upper1);

    _setSlot0Tick(address(clPool), int24(_currentTick));

    // Compute expected inside growth using the same logic as in the Tick lib.
    uint256 _below0 = _currentTick >= _tickLower ? _growth.lower0 : _growth.global0 - _growth.lower0;
    uint256 _below1 = _currentTick >= _tickLower ? _growth.lower1 : _growth.global1 - _growth.lower1;
    uint256 _above0 = _currentTick < _tickUpper ? _growth.upper0 : _growth.global0 - _growth.upper0;
    uint256 _above1 = _currentTick < _tickUpper ? _growth.upper1 : _growth.global1 - _growth.upper1;

    uint256 _expectedInside0 = _growth.global0 - _below0 - _above0;
    uint256 _expectedInside1 = _growth.global1 - _below1 - _above1;

    (uint256 _inside0, uint256 _inside1) = clPool.getFeeGrowthInside(int24(_tickLower), int24(_tickUpper));

    // it returns a fee growth inside a given range
    assertEq(_inside0, _expectedInside0);
    assertEq(_inside1, _expectedInside1);
  }
}
