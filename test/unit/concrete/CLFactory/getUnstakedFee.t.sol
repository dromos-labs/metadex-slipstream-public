pragma solidity ^0.7.6;
pragma abicoder v2;

import './CLFactory.t.sol';

contract GetUnstakedFeeTest is CLFactoryTest {
  CLGauge public gauge;

  function test_KilledGaugeReturnsZeroUnstakedFee() public {
    address pool = createAndCheckPool({
      factory: poolFactory,
      token0: TEST_TOKEN_1,
      token1: TEST_TOKEN_0,
      tickSpacing: TICK_SPACING_LOW,
      sqrtPriceX96: encodePriceSqrt(1, 1)
    });

    gauge = CLGauge(voter.createGauge({_poolFactory: address(poolFactory), _pool: address(pool)}));

    assertEq(voter.isAlive(address(gauge)), true);
    assertEq(uint256(poolFactory.getUnstakedFee(pool)), 100_000);

    voter.killGauge(address(gauge));

    assertEq(voter.isAlive(address(gauge)), false);
    assertEq(uint256(poolFactory.getUnstakedFee(pool)), 0);
  }

  function test_ZeroEmissionCapReturnsZeroUnstakedFee() public {
    address pool = createAndCheckPool({
      factory: poolFactory,
      token0: TEST_TOKEN_1,
      token1: TEST_TOKEN_0,
      tickSpacing: TICK_SPACING_LOW,
      sqrtPriceX96: encodePriceSqrt(1, 1)
    });

    gauge = CLGauge(voter.createGauge({_poolFactory: address(poolFactory), _pool: address(pool)}));

    assertEq(voter.isAlive(address(gauge)), true);
    assertEq(uint256(poolFactory.getUnstakedFee(pool)), 100_000);

    vm.prank(users.owner);
    gaugeFactory.setEmissionCap(address(gauge), 0);

    assertEq(voter.isAlive(address(gauge)), true);
    assertEq(uint256(gaugeFactory.emissionCap(address(gauge))), 0);
    // with a zero emission cap the gauge can never collect fees, so no unstaked fee should be charged
    assertEq(uint256(poolFactory.getUnstakedFee(pool)), 0);
  }

  function test_UnsetVoterReturnsZeroUnstakedFee() public {
    vm.prank(users.owner);
    CLFactory voterlessFactory = new CLFactory({
      _owner: users.owner,
      _swapFeeManager: users.owner,
      _unstakedFeeManager: users.owner,
      _voter: address(0),
      _poolImplementation: address(poolImplementation),
      _factoryRegistry: address(factoryRegistry),
      _defaultSwapHook: address(0),
      _discountRegistryManager: users.discountRegistryManager,
      _clPoolTapeManager: users.clPoolTapeManager
    });
    factoryRegistry.registerFactories({gaugeFactory: address(gaugeFactory), targetFactory: address(voterlessFactory)});

    address pool = createAndCheckPool({
      factory: voterlessFactory,
      token0: TEST_TOKEN_1,
      token1: TEST_TOKEN_0,
      tickSpacing: TICK_SPACING_LOW,
      sqrtPriceX96: encodePriceSqrt(1, 1)
    });

    assertEq(uint256(voterlessFactory.getUnstakedFee(pool)), 0);
  }

  function test_NoGaugeReturnsZeroUnstakedFee() public {
    address pool = createAndCheckPool({
      factory: poolFactory,
      token0: TEST_TOKEN_1,
      token1: TEST_TOKEN_0,
      tickSpacing: TICK_SPACING_LOW,
      sqrtPriceX96: encodePriceSqrt(1, 1)
    });

    assertEq(uint256(poolFactory.getUnstakedFee(pool)), 0);
  }
}
