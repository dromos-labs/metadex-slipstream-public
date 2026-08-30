pragma solidity =0.7.6;

import 'contracts/core/libraries/SqrtPriceMath.sol';
import 'contracts/core/libraries/TickMath.sol';

contract Other {
  // prop #30
  function testEchidna_getNextSqrtPriceFromInAndOutput(
    uint160 sqrtPX96,
    uint128 liquidity,
    uint256 amount,
    bool add
  ) public pure {
    require(sqrtPX96 >= TickMath.MIN_SQRT_RATIO && sqrtPX96 < TickMath.MAX_SQRT_RATIO);
    require(liquidity < 3_121_856_577_256_316_178_563_069_792_952_001_939); // max liquidity per tick
    uint256 next_sqrt = SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPX96, liquidity, amount, add);
    assert(next_sqrt >= TickMath.MIN_SQRT_RATIO && next_sqrt < TickMath.MAX_SQRT_RATIO);
    next_sqrt = SqrtPriceMath.getNextSqrtPriceFromOutput(sqrtPX96, liquidity, amount, add);
    assert(next_sqrt >= TickMath.MIN_SQRT_RATIO && next_sqrt < TickMath.MAX_SQRT_RATIO);
  }
}
