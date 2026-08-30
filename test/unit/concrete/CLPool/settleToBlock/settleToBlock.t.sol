// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {CLPoolTest} from '../CLPool.t.sol';
import {FullMath} from 'contracts/core/libraries/FullMath.sol';
import {MockCLPool} from 'contracts/core/test/MockCLPool.sol';
import {ICLGauge} from 'contracts/gauge/interfaces/ICLGauge.sol';

contract UnitCLPoolSettleToBlock is CLPoolTest {
  MockCLPool internal _mockPool;
  address internal _gauge = makeAddr('gauge');

  function setUp() public override {
    super.setUp();
    _mockPool = new MockCLPool();
  }

  function test_WhenTheBlockTimestampIsEqToLastUpdated(uint48 _lastUpdated) external {
    _setLastUpdated(address(_mockPool), _lastUpdated);
    _setGauge(address(_mockPool), _gauge);

    vm.warp(_lastUpdated);
    vm.record();
    _mockPool.externalSettleToBlock();
    (, bytes32[] memory _writes) = vm.accesses(address(_mockPool));

    // it should not update any values
    assertEq(_writes.length, 0);
  }

  modifier whenTheBlockTimestampIsGtLastUpdated() {
    _;
  }

  function test_WhenTheGaugeAddressEqZero(
    uint48 _lastUpdated,
    uint48 _blockTimestamp
  ) external whenTheBlockTimestampIsGtLastUpdated {
    _lastUpdated = uint48(bound(uint256(_lastUpdated), 0, type(uint48).max - 1));
    _blockTimestamp = uint48(bound(uint256(_blockTimestamp), uint256(_lastUpdated) + 1, type(uint48).max));
    _setLastUpdated(address(_mockPool), _lastUpdated);

    vm.warp(_blockTimestamp);
    _mockPool.externalSettleToBlock();

    // it should not update the lastUpdated
    assertEq(uint256(_mockPool.lastUpdated()), uint256(_lastUpdated));
    // it should leave the rollover at zero
    assertEq(_mockPool.rollover(), 0);
    // it should leave the reward growth global at zero
    assertEq(_mockPool.rewardGrowthGlobalX128(), 0);
  }

  modifier whenTheGaugeAddressDoesNotEqZero() {
    _setGauge(address(_mockPool), _gauge);
    _;
  }

  function test_WhenTheStakedLiquidityIsGtZero(
    uint256 _delta,
    uint128 _stakedLiquidity,
    uint48 _lastUpdated,
    uint48 _blockTimestamp,
    uint256 _previousRewardGrowthGlobalX128,
    uint256 _previousRollover
  ) external whenTheBlockTimestampIsGtLastUpdated whenTheGaugeAddressDoesNotEqZero {
    _lastUpdated = uint48(bound(uint256(_lastUpdated), 0, type(uint48).max - 1));
    _blockTimestamp = uint48(bound(uint256(_blockTimestamp), uint256(_lastUpdated) + 1, type(uint48).max));
    _stakedLiquidity = uint128(bound(uint256(_stakedLiquidity), 1, type(uint128).max));
    _delta =
      bound(_delta, 0, FullMath.mulDiv(type(uint256).max - _previousRewardGrowthGlobalX128, _stakedLiquidity, Q128));

    _setLastUpdated(address(_mockPool), _lastUpdated);
    _setStakedLiquidity(address(_mockPool), _stakedLiquidity);
    _setPreviousRewardGrowthGlobalX128(address(_mockPool), _previousRewardGrowthGlobalX128);
    _setPreviousRollover(address(_mockPool), _previousRollover);

    _mockAndExpect(_gauge, abi.encodeWithSelector(ICLGauge.settleGauge.selector), abi.encode(_delta));

    vm.warp(_blockTimestamp);
    _mockPool.externalSettleToBlock();

    // it should credit the reward growth accumulator with the settled delta
    assertEq(
      _mockPool.rewardGrowthGlobalX128(),
      _previousRewardGrowthGlobalX128 + FullMath.mulDiv(_delta, Q128, _stakedLiquidity)
    );
    // it should not update the rollover
    assertEq(_mockPool.rollover(), _previousRollover);
    // it should update the lastUpdated
    assertEq(uint256(_mockPool.lastUpdated()), uint256(_blockTimestamp));
  }

  function test_WhenTheStakedLiquidityIsEqZero(
    uint256 _delta,
    uint48 _lastUpdated,
    uint48 _blockTimestamp,
    uint256 _previousRewardGrowthGlobalX128,
    uint256 _previousRollover
  ) external whenTheBlockTimestampIsGtLastUpdated whenTheGaugeAddressDoesNotEqZero {
    _lastUpdated = uint48(bound(uint256(_lastUpdated), 0, type(uint48).max - 1));
    _blockTimestamp = uint48(bound(uint256(_blockTimestamp), uint256(_lastUpdated) + 1, type(uint48).max));
    _delta = bound(_delta, 0, type(uint256).max - _previousRollover);

    _setLastUpdated(address(_mockPool), _lastUpdated);
    _setPreviousRewardGrowthGlobalX128(address(_mockPool), _previousRewardGrowthGlobalX128);
    _setPreviousRollover(address(_mockPool), _previousRollover);

    _mockAndExpect(_gauge, abi.encodeWithSelector(ICLGauge.settleGauge.selector), abi.encode(_delta));

    vm.warp(_blockTimestamp);
    _mockPool.externalSettleToBlock();

    // it should add the settled delta to the rollover
    assertEq(_mockPool.rollover(), _previousRollover + _delta);
    // it should not update the reward growth accumulator
    assertEq(_mockPool.rewardGrowthGlobalX128(), _previousRewardGrowthGlobalX128);
    // it should update the lastUpdated
    assertEq(uint256(_mockPool.lastUpdated()), uint256(_blockTimestamp));
  }

  function test_RevertWhen_TheGaugeSettlementReverts(
    uint48 _lastUpdated,
    uint48 _blockTimestamp
  ) external whenTheBlockTimestampIsGtLastUpdated whenTheGaugeAddressDoesNotEqZero {
    _lastUpdated = uint48(bound(uint256(_lastUpdated), 0, type(uint48).max - 1));
    _blockTimestamp = uint48(bound(uint256(_blockTimestamp), uint256(_lastUpdated) + 1, type(uint48).max));
    _setLastUpdated(address(_mockPool), _lastUpdated);

    vm.mockCallRevert(_gauge, abi.encodeWithSelector(ICLGauge.settleGauge.selector), abi.encodePacked('error'));

    vm.warp(_blockTimestamp);
    // it should revert
    vm.expectRevert(abi.encodePacked('error'));
    _mockPool.externalSettleToBlock();
  }
}
