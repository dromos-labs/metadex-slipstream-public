pragma solidity ^0.7.6;
pragma abicoder v2;

import '../../BaseFixture.sol';
import {Position} from 'contracts/core/libraries/Position.sol';

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
}
