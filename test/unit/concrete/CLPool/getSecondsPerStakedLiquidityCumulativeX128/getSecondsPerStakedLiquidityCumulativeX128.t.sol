// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {CLPoolTest} from '../CLPool.t.sol';
import {MockCLPool} from 'contracts/core/test/MockCLPool.sol';

contract UnitCLPoolGetSecondsPerStakedLiquidityCumulativeX128 is CLPoolTest {
  MockCLPool internal _mockPool;

  function setUp() public override {
    _mockPool = new MockCLPool();
  }

  function test_WhenStakedLiquidityIsEqToZero(uint160 _storedCumulative) external {
    _setSecondsPerStakedLiquidityCumulativeX128(address(_mockPool), _storedCumulative);

    // it should return the stored cumulative unchanged
    assertEq(uint256(_mockPool.getSecondsPerStakedLiquidityCumulativeX128()), uint256(_storedCumulative));
  }

  modifier whenStakedLiquidityIsGtZero() {
    _;
  }

  function test_WhenNoTimeHasElapsedSinceLastUpdated(
    uint160 _storedCumulative,
    uint128 _stakedLiquidity,
    uint48 _lastUpdated
  ) external whenStakedLiquidityIsGtZero {
    _stakedLiquidity = uint128(bound(uint256(_stakedLiquidity), 1, type(uint128).max));
    _lastUpdated = uint48(bound(uint256(_lastUpdated), 1, type(uint48).max));
    _setStakedLiquidity(address(_mockPool), _stakedLiquidity);
    _setLastUpdated(address(_mockPool), _lastUpdated);
    _setSecondsPerStakedLiquidityCumulativeX128(address(_mockPool), _storedCumulative);
    vm.warp(_lastUpdated);

    // it should return the stored cumulative unchanged
    assertEq(uint256(_mockPool.getSecondsPerStakedLiquidityCumulativeX128()), uint256(_storedCumulative));
  }

  modifier whenTimeHasElapsedSinceLastUpdated() {
    _;
  }

  function test_WhenTimeHasElapsedSinceLastUpdated(
    uint160 _storedCumulative,
    uint128 _stakedLiquidity,
    uint48 _lastUpdated,
    uint48 _now
  ) external whenStakedLiquidityIsGtZero whenTimeHasElapsedSinceLastUpdated {
    _stakedLiquidity = uint128(bound(uint256(_stakedLiquidity), 1, type(uint128).max));
    _lastUpdated = uint48(bound(uint256(_lastUpdated), 1, type(uint48).max - 1));
    _now = uint48(bound(uint256(_now), uint256(_lastUpdated) + 1, type(uint48).max));
    _setStakedLiquidity(address(_mockPool), _stakedLiquidity);
    _setLastUpdated(address(_mockPool), _lastUpdated);
    _setSecondsPerStakedLiquidityCumulativeX128(address(_mockPool), _storedCumulative);
    vm.warp(_now);

    // it should return the stored cumulative plus elapsed over staked
    uint256 _elapsed = _now - _lastUpdated;
    assertEq(
      uint256(_mockPool.getSecondsPerStakedLiquidityCumulativeX128()),
      uint256(_storedCumulative + uint160((_elapsed << 128) / _stakedLiquidity))
    );
  }

  function test_WhenGivenAConcreteStoredCumulativeAndStakedLiquidity()
    external
    whenStakedLiquidityIsGtZero
    whenTimeHasElapsedSinceLastUpdated
  {
    _setStakedLiquidity(address(_mockPool), 7);
    _setLastUpdated(address(_mockPool), 1000);
    _setSecondsPerStakedLiquidityCumulativeX128(address(_mockPool), 11);
    vm.warp(1000 + 1 hours);

    // it should return the stored cumulative plus the rounded elapsed over staked
    assertEq(
      uint256(_mockPool.getSecondsPerStakedLiquidityCumulativeX128()),
      175_002_360_130_768_352_638_306_940_964_909_365_891_668
    );
  }
}
