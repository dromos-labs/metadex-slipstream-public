// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {CLPoolTest} from '../CLPool.t.sol';
import {CLPool} from 'contracts/core/CLPool.sol';
import {ICLGauge} from 'contracts/gauge/interfaces/ICLGauge.sol';

contract UnitCLPoolPublicSettleToBlock is CLPoolTest {
  CLPool internal _pool;
  address internal _gauge;

  function setUp() public override {
    super.setUp();
    _pool = CLPool(
      poolFactory.createPool({
        tokenA: address(token0),
        tokenB: address(token1),
        tickSpacing: TICK_SPACING_60,
        sqrtPriceX96: encodePriceSqrt(1, 1)
      })
    );
    _gauge = voter.createGauge({_poolFactory: address(poolFactory), _pool: address(_pool)});
  }

  function test_WhenTheCallerIsNotTheGauge(address _caller) external {
    // it should revert with NG
    vm.assume(_caller != _gauge);
    vm.prank(_caller);
    vm.expectRevert(abi.encodePacked('NG'));
    _pool.settleToBlock();
  }

  modifier whenTheCallerIsTheGauge() {
    _;
  }

  function test_WhenThereIsNoRolloverAccumulated() external whenTheCallerIsTheGauge {
    vm.prank(_gauge);
    uint256 _rollover = _pool.settleToBlock();

    // it should return zero
    assertEq(_rollover, 0);
  }

  function test_WhenThereIsRolloverAccumulated(
    uint256 _previousRollover,
    uint256 _delta,
    uint32 _timeElapsed
  ) external whenTheCallerIsTheGauge {
    _timeElapsed = uint32(bound(uint256(_timeElapsed), 1, type(uint32).max));
    _delta = bound(_delta, 0, type(uint256).max - _previousRollover);
    _setPreviousRollover(address(_pool), _previousRollover);

    // no staked liquidity in range: the settled delta accrues to the rollover
    _mockAndExpect(_gauge, abi.encodeWithSelector(ICLGauge.settleGauge.selector), abi.encode(_delta));

    vm.warp(block.timestamp + _timeElapsed);
    vm.prank(_gauge);
    uint256 _rollover = _pool.settleToBlock();

    // it should settle to the current block
    assertEq(uint256(_pool.lastUpdated()), block.timestamp);
    // it should return the accumulated rollover
    assertEq(_rollover, _previousRollover + _delta);
    // it should clear the rollover
    assertEq(_pool.rollover(), 0);
  }
}
