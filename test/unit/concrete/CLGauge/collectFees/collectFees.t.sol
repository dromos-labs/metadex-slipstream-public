// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.6;
pragma abicoder v2;

import '../CLGauge.t.sol';
import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {ILeafVoter} from 'contracts/gauge/interfaces/ILeafVoter.sol';

contract CLGaugeCollectFeesConcreteUnitTest is CLGaugeTest {
  uint256 internal constant GAUGE_FEES_SLOT = 10;

  address public votingRewardsManager;

  event ClaimFees(address indexed caller, uint256 claimed0, uint256 claimed1);

  function setUp() public override {
    super.setUp();

    votingRewardsManager = gauge.votingRewardsManager();
  }

  function test_WhenTheCallerIsNotTheVotingRewardsManager() external {
    // It should revert with {NVRM}
    vm.expectRevert(abi.encodePacked('NVRM'));
    gauge.collectFees();
  }

  function test_WhenTheGaugeHasNoCorrespondingPool() external {
    (CLGauge gaugeWithoutPool, CLPool poolWithoutGaugeFees) = _createGaugeWithoutPool();
    _setGaugeFees(poolWithoutGaugeFees, 11, 17);

    vm.prank(gaugeWithoutPool.votingRewardsManager());
    (uint256 amount0, uint256 amount1) = gaugeWithoutPool.collectFees();

    // It should return zero amounts
    assertEq(amount0, 0);
    assertEq(amount1, 0);

    // It should not transfer tokens
    assertEq(token0.balanceOf(gaugeWithoutPool.votingRewardsManager()), 0);
    assertEq(token1.balanceOf(gaugeWithoutPool.votingRewardsManager()), 0);
    _assertGaugeFees(poolWithoutGaugeFees, 11, 17);
  }

  function test_WhenTheGaugeIsNotActivated() external {
    _setGaugeFees(pool, 11, 17);
    _mockActivation(address(gauge), false);

    vm.prank(votingRewardsManager);
    (uint256 amount0, uint256 amount1) = gauge.collectFees();

    // It should return zero amounts
    assertEq(amount0, 0);
    assertEq(amount1, 0);

    // It should not transfer tokens
    assertEq(token0.balanceOf(votingRewardsManager), 0);
    assertEq(token1.balanceOf(votingRewardsManager), 0);
    _assertGaugeFees(pool, 11, 17);
  }

  function test_WhenTheEmissionCapIsZero() external {
    _setGaugeFees(pool, 11, 17);
    _mockActivation(address(gauge), true);

    vm.prank(users.owner);
    gaugeFactory.setEmissionCap(address(gauge), 0);

    vm.prank(votingRewardsManager);
    (uint256 amount0, uint256 amount1) = gauge.collectFees();

    // It should return zero amounts
    assertEq(amount0, 0);
    assertEq(amount1, 0);

    // It should not transfer tokens
    assertEq(token0.balanceOf(votingRewardsManager), 0);
    assertEq(token1.balanceOf(votingRewardsManager), 0);
    _assertGaugeFees(pool, 11, 17);
  }

  function test_WhenNoFeesAreClaimable() external {
    _setGaugeFees(pool, 1, 1);
    _mockActivation(address(gauge), true);

    vm.prank(votingRewardsManager);
    (uint256 amount0, uint256 amount1) = gauge.collectFees();

    // It should return zero amounts
    assertEq(amount0, 0);
    assertEq(amount1, 0);

    // It should not transfer tokens
    assertEq(token0.balanceOf(votingRewardsManager), 0);
    assertEq(token1.balanceOf(votingRewardsManager), 0);
    _assertGaugeFees(pool, 1, 1);
  }

  function test_WhenFeesArePending(uint128 _fees0, uint128 _fees1) external {
    _fees0 = uint128(bound(uint256(_fees0), 2, type(uint128).max));
    _fees1 = uint128(bound(uint256(_fees1), 2, type(uint128).max));
    _setGaugeFees(pool, _fees0, _fees1);
    _mockActivation(address(gauge), true);

    (uint256 pending0, uint256 pending1) = gauge.pendingFees();
    assertEq(pending0, uint256(_fees0) - 1);
    assertEq(pending1, uint256(_fees1) - 1);

    vm.prank(votingRewardsManager);

    // It should emit a {ClaimFees} event
    vm.expectEmit(address(gauge));
    emit ClaimFees(votingRewardsManager, pending0, pending1);
    (uint256 amount0, uint256 amount1) = gauge.collectFees();

    // It should return the claimed amounts
    assertEq(amount0, pending0);
    assertEq(amount1, pending1);

    // It should transfer fees directly to the voting rewards manager
    assertEq(token0.balanceOf(votingRewardsManager), pending0);
    assertEq(token1.balanceOf(votingRewardsManager), pending1);
    _assertGaugeFees(pool, 1, 1);
  }

  function testGas_collectFees() external {
    _setGaugeFees(pool, 11, 17);
    _mockActivation(address(gauge), true);

    vm.prank(votingRewardsManager);
    gauge.collectFees();
    vm.snapshotGasLastCall('CLGauge_collectFees');
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
    deal({token: address(token0), to: address(targetPool), give: amount0});
    deal({token: address(token1), to: address(targetPool), give: amount1});
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
