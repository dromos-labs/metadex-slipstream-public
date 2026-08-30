// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.6;
pragma abicoder v2;

import '../CLGauge.t.sol';
import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {ILeafVoter} from 'contracts/gauge/interfaces/ILeafVoter.sol';

contract CLGaugePendingFeesConcreteUnitTest is CLGaugeTest {
  uint256 internal constant GAUGE_FEES_SLOT = 10;

  function test_WhenTheGaugeHasNoCorrespondingPool() external {
    (CLGauge gaugeWithoutPool, CLPool poolWithoutGaugeFees) = _createGaugeWithoutPool();
    _setGaugeFees(poolWithoutGaugeFees, 11, 17);
    _mockActivation(address(gaugeWithoutPool), true);

    (uint256 amount0, uint256 amount1) = gaugeWithoutPool.pendingFees();

    // It should return zero amounts
    assertEq(amount0, 0);
    assertEq(amount1, 0);
  }

  function test_WhenTheGaugeIsNotActivated() external {
    _setGaugeFees(pool, 11, 17);
    _mockActivation(address(gauge), false);

    (uint256 amount0, uint256 amount1) = gauge.pendingFees();

    // It should return zero amounts
    assertEq(amount0, 0);
    assertEq(amount1, 0);
  }

  function test_WhenTheEmissionCapIsZero() external {
    _setGaugeFees(pool, 11, 17);
    _mockActivation(address(gauge), true);

    vm.prank(users.owner);
    gaugeFactory.setEmissionCap(address(gauge), 0);

    (uint256 amount0, uint256 amount1) = gauge.pendingFees();

    // It should return zero amounts
    assertEq(amount0, 0);
    assertEq(amount1, 0);
  }

  function test_WhenGaugeFeesAreZero() external {
    _mockActivation(address(gauge), true);

    (uint256 amount0, uint256 amount1) = gauge.pendingFees();

    // It should return zero amounts
    assertEq(amount0, 0);
    assertEq(amount1, 0);
  }

  function test_WhenGaugeFeesAreOneWei() external {
    _setGaugeFees(pool, 1, 1);
    _mockActivation(address(gauge), true);

    (uint256 amount0, uint256 amount1) = gauge.pendingFees();

    // It should return zero amounts
    assertEq(amount0, 0);
    assertEq(amount1, 0);
  }

  function test_WhenGaugeFeesAreGreaterThanOneWei() external {
    _setGaugeFees(pool, 11, 17);
    _mockActivation(address(gauge), true);

    (uint256 amount0, uint256 amount1) = gauge.pendingFees();

    // It should subtract the retained wei
    assertEq(amount0, 10);
    assertEq(amount1, 16);
  }

  function _createGaugeWithoutPool() internal returns (CLGauge gaugeWithoutPool, CLPool poolWithoutGaugeFees) {
    poolWithoutGaugeFees = CLPool(
      poolFactory.createPool({
        tokenA: address(token0),
        tokenB: address(token1),
        tickSpacing: TICK_SPACING_10,
        sqrtPriceX96: encodePriceSqrt(1, 1)
      })
    );

    // the factory only deploys gauges with _isPool = true, so clone and
    // initialize a non-pool gauge directly from the implementation
    gaugeWithoutPool = CLGauge(Clones.clone(gaugeFactory.implementation()));
    vm.prank(address(gaugeFactory));
    gaugeWithoutPool.initialize({
      _pool: address(poolWithoutGaugeFees),
      _votingRewardsManager: makeAddr('NoPoolVotingRewardsManager'),
      _token0: address(token0),
      _token1: address(token1),
      _tickSpacing: TICK_SPACING_10,
      _isPool: false
    });
  }

  function _setGaugeFees(CLPool targetPool, uint128 amount0, uint128 amount1) internal {
    vm.store(address(targetPool), bytes32(GAUGE_FEES_SLOT), _packGaugeFees(amount0, amount1));
    _assertGaugeFees(targetPool, amount0, amount1);
  }

  function _assertGaugeFees(CLPool targetPool, uint128 expected0, uint128 expected1) internal view {
    (uint128 amount0, uint128 amount1) = targetPool.gaugeFees();
    assertEq(uint256(amount0), uint256(expected0));
    assertEq(uint256(amount1), uint256(expected1));
  }

  function _packGaugeFees(uint128 amount0, uint128 amount1) internal pure returns (bytes32) {
    return bytes32(uint256(amount0) | (uint256(amount1) << 128));
  }

  function _mockActivation(address targetGauge, bool activated) internal {
    vm.mockCall(
      address(voter), abi.encodeWithSelector(ILeafVoter.isActivated.selector, targetGauge), abi.encode(activated)
    );
  }
}
