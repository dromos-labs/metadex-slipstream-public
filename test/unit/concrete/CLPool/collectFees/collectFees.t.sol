// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.6;
pragma abicoder v2;

import '../CLPool.t.sol';
import {CLGauge} from 'contracts/gauge/CLGauge.sol';

contract CLPoolCollectFeesConcreteUnitTest is CLPoolTest {
  uint256 internal constant SLOT0_SLOT = 6;
  uint256 internal constant GAUGE_FEES_SLOT = 10;

  CLPool public pool;
  CLGauge public gauge;
  address public recipient;

  event CollectFees(address indexed recipient, uint128 amount0, uint128 amount1);

  function setUp() public override {
    super.setUp();

    pool = CLPool(
      poolFactory.createPool({
        tokenA: address(token0),
        tokenB: address(token1),
        tickSpacing: TICK_SPACING_60,
        sqrtPriceX96: encodePriceSqrt(1, 1)
      })
    );
    gauge = CLGauge(voter.createGauge({_poolFactory: address(poolFactory), _pool: address(pool)}));
    recipient = users.bob;
  }

  function test_WhenTheCallerIsNotTheGauge() external {
    // It should revert with {NG}
    vm.expectRevert(abi.encodePacked('NG'));
    pool.collectFees(recipient);
  }

  function test_WhenThePoolIsLocked() external {
    vm.store(address(pool), bytes32(SLOT0_SLOT), bytes32(0));

    vm.prank(address(gauge));

    // It should revert with {LOK}
    vm.expectRevert(abi.encodePacked('LOK'));
    pool.collectFees(recipient);
  }

  function test_WhenGaugeFeesAreZero() external {
    vm.prank(address(gauge));

    // It should emit a {CollectFees} event with the recipient
    vm.expectEmit(address(pool));
    emit CollectFees(recipient, 0, 0);
    (uint128 amount0, uint128 amount1) = pool.collectFees(recipient);

    // It should return zero amounts
    assertEq(uint256(amount0), 0);
    assertEq(uint256(amount1), 0);

    // It should leave gauge fees at zero
    _assertGaugeFees(0, 0);

    // It should not transfer tokens
    assertEq(token0.balanceOf(recipient), 0);
    assertEq(token1.balanceOf(recipient), 0);
  }

  function test_WhenGaugeFeesAreOneWei() external {
    _setGaugeFees(1, 1);

    vm.prank(address(gauge));

    // It should emit a {CollectFees} event with the recipient
    vm.expectEmit(address(pool));
    emit CollectFees(recipient, 0, 0);
    (uint128 amount0, uint128 amount1) = pool.collectFees(recipient);

    // It should return zero amounts
    assertEq(uint256(amount0), 0);
    assertEq(uint256(amount1), 0);

    // It should retain one wei in the pool
    _assertGaugeFees(1, 1);

    // It should not transfer tokens
    assertEq(token0.balanceOf(recipient), 0);
    assertEq(token1.balanceOf(recipient), 0);
  }

  function test_WhenGaugeFeesAreTwoWei() external {
    _setGaugeFees(2, 2);

    vm.prank(address(gauge));

    // It should emit a {CollectFees} event with the recipient
    vm.expectEmit(address(pool));
    emit CollectFees(recipient, 1, 1);
    (uint128 amount0, uint128 amount1) = pool.collectFees(recipient);

    assertEq(uint256(amount0), 1);
    assertEq(uint256(amount1), 1);

    // It should retain one wei in the pool
    _assertGaugeFees(1, 1);

    // It should transfer one wei to the recipient
    assertEq(token0.balanceOf(recipient), 1);
    assertEq(token1.balanceOf(recipient), 1);
  }

  function test_WhenGaugeFeesAreGreaterThanOneWei() external {
    _setGaugeFees(11, 17);

    vm.prank(address(gauge));

    // It should emit a {CollectFees} event with the recipient
    vm.expectEmit(address(pool));
    emit CollectFees(recipient, 10, 16);
    (uint128 amount0, uint128 amount1) = pool.collectFees(recipient);

    assertEq(uint256(amount0), 10);
    assertEq(uint256(amount1), 16);

    // It should retain one wei in the pool
    _assertGaugeFees(1, 1);

    // It should transfer the claimable fees to the recipient
    assertEq(token0.balanceOf(recipient), 10);
    assertEq(token1.balanceOf(recipient), 16);
  }

  function _setGaugeFees(uint128 amount0, uint128 amount1) internal {
    vm.store(address(pool), bytes32(GAUGE_FEES_SLOT), _packGaugeFees(amount0, amount1));
    deal({token: address(token0), to: address(pool), give: amount0});
    deal({token: address(token1), to: address(pool), give: amount1});
    _assertGaugeFees(amount0, amount1);
  }

  function _assertGaugeFees(uint128 expected0, uint128 expected1) internal view {
    (uint128 amount0, uint128 amount1) = pool.gaugeFees();
    assertEq(uint256(amount0), uint256(expected0));
    assertEq(uint256(amount1), uint256(expected1));
  }

  function _packGaugeFees(uint128 amount0, uint128 amount1) internal pure returns (bytes32) {
    return bytes32(uint256(amount0) | (uint256(amount1) << 128));
  }
}
