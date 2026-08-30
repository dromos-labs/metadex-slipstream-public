pragma solidity ^0.7.6;
pragma abicoder v2;

import '../../../BaseFixture.sol';
import {Position} from 'contracts/core/libraries/Position.sol';
import {ICLGaugeFactory} from 'contracts/gauge/interfaces/ICLGaugeFactory.sol';

contract CLGaugeTest is BaseFixture {
  CLPool public pool;
  CLGauge public gauge;

  function setUp() public virtual override {
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
    vm.mockCall(address(pool), abi.encodeWithSignature('settleToBlock()'), abi.encode(uint256(0)));
  }

  function _ids(uint256 tokenId) internal pure returns (uint256[] memory tokenIds) {
    tokenIds = new uint256[](1);
    tokenIds[0] = tokenId;
  }

  function test_InitialState() external view {
    assertEq(address(gauge.pool()), address(pool));
    assertEq(address(gauge.gaugeFactory()), address(gaugeFactory));
    assertEq(address(gauge.voter()), address(voter));
    assertEq(address(gauge.nft()), address(nft));
    assertEq(gauge.token0(), address(token0));
    assertEq(gauge.token1(), address(token1));
    assertEq(gauge.tickSpacing(), TICK_SPACING_60);
    assertNotEq(gauge.votingRewardsManager(), address(0));
    assertTrue(gauge.isPool());
    assertEq(gauge.lastCumulativeRewardShare(), 0);

    ICLGaugeFactory.PenaltyConfig memory config = gaugeFactory.penaltyConfig();
    assertEq(config.penaltyRate, 0);
    assertEq(config.minStakeBlocks, 0);
  }
}
