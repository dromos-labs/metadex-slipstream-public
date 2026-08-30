pragma solidity ^0.7.6;
pragma abicoder v2;

import '../CLGauge.t.sol';

contract DepositConcreteUnitTest is CLGaugeTest {
  using stdStorage for StdStorage;
  using SafeCast for uint128;

  function setUp() public override {
    super.setUp();

    vm.startPrank(users.feeManager);
    customUnstakedFeeModule.setCustomFee(address(pool), 420);
    vm.startPrank(users.alice);
  }

  function test_WhenTheCallerIsNotTheTokenOwner() external {
    // It should revert with {NA}
    uint256 tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);

    vm.startPrank(users.charlie);
    vm.expectRevert(abi.encodePacked('NA'));
    gauge.deposit({_lp: tokenId});
  }

  modifier whenTheCallerIsTheTokenOwner() {
    _;
  }

  function test_WhenThePositionDoesNotMatchThePool() external whenTheCallerIsTheTokenOwner {
    // It should revert with {PM}
    poolFactory.createPool({
      tokenA: address(token0),
      tokenB: address(token1),
      tickSpacing: TICK_SPACING_10,
      sqrtPriceX96: encodePriceSqrt(1, 1)
    });

    vm.startPrank(users.charlie);
    INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
      token0: address(token0),
      token1: address(token1),
      tickSpacing: TICK_SPACING_10,
      tickLower: getMinTick(TICK_SPACING_10),
      tickUpper: getMaxTick(TICK_SPACING_10),
      recipient: users.charlie,
      amount0Desired: TOKEN_1,
      amount1Desired: TOKEN_1,
      amount0Min: 0,
      amount1Min: 0,
      deadline: 10,
      sqrtPriceX96: 0
    });
    (uint256 tokenId,,,) = nft.mint(params);

    nft.approve(address(gauge), tokenId);
    vm.expectRevert(abi.encodePacked('PM'));
    gauge.deposit({_lp: tokenId});
  }

  modifier whenThePositionMatchesThePool() {
    _;
  }

  function test_WhenThePositionMatchesThePool() external whenTheCallerIsTheTokenOwner whenThePositionMatchesThePool {
    // It should collect accumulated fees
    // It should stake liquidity in the pool
    // It should set the deposit block
    // It should emit a {Deposit} event
    uint256 tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 liquidity,,,,) = nft.positions(tokenId);

    nft.approve(address(gauge), tokenId);
    vm.expectEmit(address(gauge));
    emit Deposit({_caller: users.alice, _user: users.alice, _tokenId: tokenId, _liquidityToStake: liquidity});
    gauge.deposit({_lp: tokenId});

    assertEq(nft.ownerOf(tokenId), address(gauge));
    assertEqUint(pool.stakedLiquidity(), liquidity);
    assertEq(gauge.stakedLength(users.alice), 1);
    assertEq(gauge.depositBlock(tokenId), block.number);
  }

  function testGas_deposit() external {
    uint256 tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);

    nft.approve(address(gauge), tokenId);
    gauge.deposit({_lp: tokenId});
    vm.snapshotGasLastCall('CLGauge_deposit');
  }
}
