pragma solidity ^0.7.6;
pragma abicoder v2;

import {CLGaugeTest} from './CLGauge.t.sol';
import {CLGauge} from 'contracts/gauge/CLGauge.sol';

contract InitializeTest is CLGaugeTest {
  function test_RevertIf_NotGaugeFactory() public {
    CLGauge uninitializedGauge =
      new CLGauge({_voter: address(voter), _nft: address(nft), _gaugeFactory: address(gaugeFactory)});

    vm.expectRevert(abi.encodePacked('NA'));
    uninitializedGauge.initialize({
      _pool: address(pool),
      _votingRewardsManager: makeAddr('votingRewardsManager'),
      _token0: address(token0),
      _token1: address(token1),
      _tickSpacing: TICK_SPACING_60,
      _isPool: true
    });
  }

  function test_RevertIf_AlreadyInitialized() public {
    address pool = poolFactory.createPool({
      tokenA: TEST_TOKEN_0, tokenB: TEST_TOKEN_1, tickSpacing: TICK_SPACING_LOW, sqrtPriceX96: encodePriceSqrt(1, 1)
    });
    address gauge = voter.createGauge({_poolFactory: address(poolFactory), _pool: address(pool)});
    address votingRewardsManager = voter.gaugeToFees(gauge);

    vm.prank(address(gaugeFactory));
    vm.expectRevert(abi.encodePacked('AI'));
    CLGauge(gauge)
      .initialize({
      _pool: pool,
      _votingRewardsManager: votingRewardsManager,
      _token0: address(token0),
      _token1: address(token1),
      _tickSpacing: TICK_SPACING_60,
      _isPool: true
    });
  }
}
