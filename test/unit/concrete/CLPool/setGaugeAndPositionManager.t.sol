pragma solidity ^0.7.6;
pragma abicoder v2;

import './CLPool.t.sol';

contract SetGaugeAndPositionManagerTest is CLPoolTest {
  CLPool public pool;

  function setUp() public override {
    super.setUp();

    vm.startPrank({msgSender: users.owner});

    // redeploy contracts
    factoryRegistry = IFactoryRegistry(new MockFactoryRegistry());
    voter = IVoter(
      new MockVoter({
        _rewardToken: address(rewardToken), _factoryRegistry: address(factoryRegistry), _ve: address(escrow)
      })
    );

    poolImplementation = new CLPool();
    poolFactory = new CLFactory({
      _owner: users.owner,
      _swapFeeManager: address(this),
      _unstakedFeeManager: address(this),
      _voter: address(voter),
      _poolImplementation: address(poolImplementation),
      _factoryRegistry: address(factoryRegistry),
      // TODO: Set default hook address
      _defaultSwapHook: address(0),
      _discountRegistryManager: users.discountRegistryManager,
      _clPoolTapeManager: users.clPoolTapeManager
    });

    nftDescriptor = new NonfungibleTokenPositionDescriptor({
      _WETH9: address(weth),
      _nativeCurrencyLabelBytes: 0x4554480000000000000000000000000000000000000000000000000000000000 // 'ETH' as bytes32 string
    });
    nft = new NonfungiblePositionManager({
      _owner: users.owner,
      _factory: address(poolFactory),
      _WETH9: address(weth),
      _tokenDescriptor: address(nftDescriptor),
      name: nftName,
      symbol: nftSymbol
    });

    gaugeFactory = new CLGaugeFactory({
      _leafVoter: address(voter),
      _gaugeManager: address(voter),
      _votingRewardsFactory: address(votingRewardsFactory),
      _nft: address(nft),
      _roles: CLGaugeFactory.RoleAddresses({
        capAdmin: users.owner, referralAdmin: users.owner, penaltyAdmin: users.owner, capOperator: users.owner
      }),
      _capConfig: CLGaugeFactory.CapConfig({
        defaultCap: uint128(TOKEN_1), operatorMinCap: 1, operatorMaxCap: uint128(TOKEN_1), maxMinStakeBlocks: 1 weeks
      })
    });
    gaugeImplementation = CLGauge(gaugeFactory.implementation());

    factoryRegistry.registerFactories({gaugeFactory: address(gaugeFactory), targetFactory: address(poolFactory)});
    vm.stopPrank();

    pool = CLPool(
      poolFactory.createPool({
        tokenA: address(token0),
        tokenB: address(token1),
        tickSpacing: TICK_SPACING_LOW,
        sqrtPriceX96: encodePriceSqrt(1, 1)
      })
    );

    vm.label(address(gaugeFactory), 'GF');
    vm.label(address(factoryRegistry), 'FR');
  }

  function test_RevertIf_AlreadyInitialized() public {
    _mockGaugeSettleGauge(address(1), 0);
    vm.prank(address(gaugeFactory));
    pool.setGaugeAndPositionManager({_gauge: address(1), _nft: address(nft)});

    vm.prank(address(gaugeFactory));
    vm.expectRevert();
    pool.setGaugeAndPositionManager({_gauge: address(1), _nft: address(nft)});
  }

  function test_RevertIf_NotGaugeFactory() public {
    vm.expectRevert(abi.encodePacked('NGF'));
    pool.setGaugeAndPositionManager({_gauge: address(1), _nft: address(nft)});
  }

  function test_SetGaugeAndPositionManager() public {
    address gauge = voter.createGauge({_poolFactory: address(poolFactory), _pool: address(pool)});

    assertEq(pool.gauge(), address(gauge));
    assertEq(pool.nft(), address(nft));

    // it initializes lastUpdated to the current block timestamp
    assertEq(uint256(pool.lastUpdated()), block.timestamp);

    // it initializes the gauge's cursor by settling it in the voter
    assertEq(MockVoter(address(voter)).settleGaugeCalls(gauge), 1);
  }

  function test_BanksPreConnectionAccrualIntoRollover(uint128 _accrued) public {
    vm.assume(_accrued > 0);
    address gauge = address(1);

    // it pulls the gauge's pre-connection accrual on connection
    _mockGaugeSettleGauge(gauge, _accrued);
    vm.expectCall(gauge, abi.encodeWithSignature('settleGauge()'));

    vm.prank(address(gaugeFactory));
    pool.setGaugeAndPositionManager({_gauge: gauge, _nft: address(nft)});

    // it banks the pre-connection accrual into rollover instead of the reward growth accumulator
    assertEq(pool.rollover(), uint256(_accrued));
    assertEq(pool.rewardGrowthGlobalX128(), 0);
    assertEq(uint256(pool.lastUpdated()), block.timestamp);
  }

  function _mockGaugeSettleGauge(address _gauge, uint256 _delta) internal {
    vm.mockCall(_gauge, abi.encodeWithSignature('settleGauge()'), abi.encode(_delta));
  }
}
