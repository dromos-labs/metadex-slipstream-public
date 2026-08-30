// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {CLPoolTest} from '../CLPool.t.sol';
import {FullMath} from 'contracts/core/libraries/FullMath.sol';
import {MockCLPool} from 'contracts/core/test/MockCLPool.sol';

contract UnitCLPoolUpdateRewardsGrowthGlobal is CLPoolTest {
  MockCLPool internal _mockPool;

  function setUp() public override {
    _mockPool = new MockCLPool();
  }

  modifier whenStakedLiquidityIsGtZero() {
    _;
  }

  function test_WhenStakedLiquidityIsGtZero(
    uint256 _rewardsToDistribute,
    uint128 _stakedLiquidity,
    uint48 _lastUpdated,
    uint48 _previousLastUpdated,
    uint160 _previousCumulative,
    uint256 _previousRewardGrowthGlobalX128,
    uint256 _previousRollover
  ) external whenStakedLiquidityIsGtZero {
    _stakedLiquidity = uint128(bound(uint256(_stakedLiquidity), 1, type(uint128).max));
    _rewardsToDistribute = bound(
      _rewardsToDistribute,
      0,
      FullMath.mulDiv(type(uint256).max - _previousRewardGrowthGlobalX128, _stakedLiquidity, Q128)
    );
    _previousLastUpdated = uint48(bound(uint256(_previousLastUpdated), 0, type(uint48).max - 1));
    _lastUpdated = uint48(bound(uint256(_lastUpdated), uint256(_previousLastUpdated) + 1, type(uint48).max));

    _setStakedLiquidity(address(_mockPool), _stakedLiquidity);
    _setLastUpdated(address(_mockPool), _previousLastUpdated);
    _setSecondsPerStakedLiquidityCumulativeX128(address(_mockPool), _previousCumulative);
    _setPreviousRewardGrowthGlobalX128(address(_mockPool), _previousRewardGrowthGlobalX128);
    _setPreviousRollover(address(_mockPool), _previousRollover);

    _mockPool.externalUpdateRewardsGrowthGlobal(_rewardsToDistribute, _lastUpdated, _previousLastUpdated);

    // it should credit the reward growth accumulator
    assertEq(
      _mockPool.rewardGrowthGlobalX128(),
      _previousRewardGrowthGlobalX128 + FullMath.mulDiv(_rewardsToDistribute, Q128, _stakedLiquidity)
    );
    // it should credit the seconds per staked liquidity cumulative by elapsed over staked
    uint256 _elapsed = _lastUpdated - _previousLastUpdated;
    assertEq(
      uint256(_mockPool.secondsPerStakedLiquidityCumulativeX128()),
      uint256(_previousCumulative + uint160((_elapsed << 128) / _stakedLiquidity))
    );
    // it should not update the rollover
    assertEq(_mockPool.rollover(), _previousRollover);
    // it should update the lastUpdated
    assertEq(uint256(_mockPool.lastUpdated()), uint256(_lastUpdated));
  }

  function test_WhenGivenAConcreteRewardAndStakedLiquidity() external whenStakedLiquidityIsGtZero {
    _setStakedLiquidity(address(_mockPool), 3);
    _setLastUpdated(address(_mockPool), 10);
    _setSecondsPerStakedLiquidityCumulativeX128(address(_mockPool), 5);
    _setPreviousRewardGrowthGlobalX128(address(_mockPool), 4 * Q128 + 1);

    _mockPool.externalUpdateRewardsGrowthGlobal({_rewardsToDistribute: 7, _now: 17, _lastUpdated: 10});

    // it should add the rounded growth to the previous accumulator
    assertEq(_mockPool.rewardGrowthGlobalX128(), 2_155_121_657_165_943_601_934_705_847_067_865_339_222);
    // it should add the rounded elapsed over staked to the previous cumulative
    assertEq(
      uint256(_mockPool.secondsPerStakedLiquidityCumulativeX128()), 793_992_189_482_189_748_081_207_417_340_792_493_402
    );
  }

  function test_WhenStakedLiquidityIsEqToZero(
    uint256 _rewardsToDistribute,
    uint48 _lastUpdated,
    uint160 _previousCumulative,
    uint256 _previousRollover,
    uint256 _previousRewardGrowthGlobalX128
  ) external {
    _rewardsToDistribute = bound(_rewardsToDistribute, 0, type(uint256).max - _previousRollover);
    _setPreviousRollover(address(_mockPool), _previousRollover);
    _setSecondsPerStakedLiquidityCumulativeX128(address(_mockPool), _previousCumulative);
    _setPreviousRewardGrowthGlobalX128(address(_mockPool), _previousRewardGrowthGlobalX128);

    _mockPool.externalUpdateRewardsGrowthGlobal(_rewardsToDistribute, _lastUpdated, 0);

    // it should add the reward to the rollover
    assertEq(_mockPool.rollover(), _previousRollover + _rewardsToDistribute);
    // it should not update the reward growth accumulator
    assertEq(_mockPool.rewardGrowthGlobalX128(), _previousRewardGrowthGlobalX128);
    // it should not update the seconds per staked liquidity cumulative
    assertEq(uint256(_mockPool.secondsPerStakedLiquidityCumulativeX128()), uint256(_previousCumulative));
    // it should update the lastUpdated
    assertEq(uint256(_mockPool.lastUpdated()), uint256(_lastUpdated));
  }
}
