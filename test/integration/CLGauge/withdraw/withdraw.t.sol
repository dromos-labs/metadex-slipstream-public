pragma solidity ^0.7.6;
pragma abicoder v2;

import {FullMath} from 'contracts/core/libraries/FullMath.sol';

import {TestERC20} from 'contracts/periphery/test/TestERC20.sol';
import {MockLeafVoter} from 'contracts/test/MockLeafVoter.sol';

import '../CLGauge.t.sol';

contract WithdrawIntegrationConcreteTest is CLGaugeTest {
  using stdStorage for StdStorage;
  using SafeCast for uint128;

  TestERC20 public receiptToken;
  MockLeafVoter public mockLeafVoter;

  event MetadataUpdate(uint256 _tokenId);

  function setUp() public override {
    super.setUp();

    vm.prank(users.feeManager);
    customUnstakedFeeModule.setCustomFee(address(pool), 420);

    receiptToken = new TestERC20(0);
    mockLeafVoter = new MockLeafVoter(receiptToken);

    vm.startPrank(users.alice);
  }

  function test_RevertIf_CallerIsNotOwner() public {
    INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
      token0: address(token0),
      token1: address(token1),
      tickSpacing: TICK_SPACING_60,
      tickLower: getMinTick(TICK_SPACING_60),
      tickUpper: getMaxTick(TICK_SPACING_60),
      recipient: users.alice,
      amount0Desired: TOKEN_1,
      amount1Desired: TOKEN_1,
      amount0Min: 0,
      amount1Min: 0,
      deadline: 10,
      sqrtPriceX96: 0
    });
    (uint256 tokenId,,,) = nft.mint(params);

    nft.approve(address(gauge), tokenId);
    gauge.deposit({_lp: tokenId});

    vm.startPrank(users.charlie);
    vm.expectRevert(abi.encodePacked('NA'));
    gauge.withdraw({_lp: tokenId});
  }

  function test_WithdrawWithPositionInCurrentPrice() public {
    INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
      token0: address(token0),
      token1: address(token1),
      tickSpacing: TICK_SPACING_60,
      tickLower: -TICK_SPACING_60,
      tickUpper: TICK_SPACING_60,
      recipient: users.alice,
      amount0Desired: TOKEN_1,
      amount1Desired: TOKEN_1,
      amount0Min: 0,
      amount1Min: 0,
      deadline: 10,
      sqrtPriceX96: 0
    });
    (uint256 tokenId, uint128 liquidity,,) = nft.mint(params);
    nft.approve(address(gauge), tokenId);
    gauge.deposit({_lp: tokenId});

    (uint128 gaugeLiquidity,,,,) =
      pool.positions(keccak256(abi.encodePacked(address(gauge), -TICK_SPACING_60, TICK_SPACING_60)));
    assertEqUint(gaugeLiquidity, liquidity);
    uint256 rewardBalanceBefore = receiptToken.balanceOf(users.alice);

    vm.expectEmit(true, true, true, true, address(gauge));
    emit Withdraw({_caller: users.alice, _user: users.alice, _tokenId: tokenId, _liquidityToStake: liquidity});
    // It should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // It should not forfeit emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('forfeitEmissions(uint128)'), 0);
    // It should not mint emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('mintEmissions(address[],uint128[])'), 0);
    gauge.withdraw({_lp: tokenId});

    assertEq(nft.balanceOf(address(gauge)), 0);
    assertEq(nft.balanceOf(users.alice), 1);
    assertEq(nft.ownerOf(tokenId), address(users.alice));
    assertEq(gauge.stakedLength(users.alice), 0);
    assertEq(gauge.stakedContains(users.alice, 1), false);
    uint256[] memory staked = gauge.stakedValues(users.alice);
    assertEq(staked.length, 0);
    assertEq(gauge.rewardGrowthInside(tokenId), 0);
    // It should clear the deposit block
    assertEq(gauge.depositBlock(tokenId), 0);
    assertEq(receiptToken.balanceOf(users.alice), rewardBalanceBefore);
    assertEqUint(pool.liquidity(), liquidity);
    assertEqUint(pool.stakedLiquidity(), 0);
    (,, int128 stakedLiquidityNet,,,,,,,) = pool.ticks(-TICK_SPACING_60);
    assertEq(stakedLiquidityNet, 0);
    (,, stakedLiquidityNet,,,,,,,) = pool.ticks(TICK_SPACING_60);
    assertEq(stakedLiquidityNet, 0);

    (uint128 nftLiquidity,,,,) =
      pool.positions(keccak256(abi.encodePacked(address(nft), -TICK_SPACING_60, TICK_SPACING_60)));
    assertEqUint(nftLiquidity, liquidity);

    (gaugeLiquidity,,,,) =
      pool.positions(keccak256(abi.encodePacked(address(gauge), -TICK_SPACING_60, TICK_SPACING_60)));
    assertEqUint(gaugeLiquidity, 0);
  }

  function test_WithdrawWithPositionRightOfCurrentPrice() public {
    INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
      token0: address(token0),
      token1: address(token1),
      tickSpacing: TICK_SPACING_60,
      tickLower: TICK_SPACING_60,
      tickUpper: 2 * TICK_SPACING_60,
      recipient: users.alice,
      amount0Desired: TOKEN_1,
      amount1Desired: TOKEN_1,
      amount0Min: 0,
      amount1Min: 0,
      deadline: 10,
      sqrtPriceX96: 0
    });
    (uint256 tokenId, uint128 liquidity,,) = nft.mint(params);
    nft.approve(address(gauge), tokenId);
    gauge.deposit({_lp: tokenId});

    (uint128 gaugeLiquidity,,,,) =
      pool.positions(keccak256(abi.encodePacked(address(gauge), TICK_SPACING_60, 2 * TICK_SPACING_60)));
    assertEqUint(gaugeLiquidity, liquidity);
    uint256 rewardBalanceBefore = receiptToken.balanceOf(users.alice);

    vm.expectEmit(true, true, true, true, address(gauge));
    emit Withdraw({_caller: users.alice, _user: users.alice, _tokenId: tokenId, _liquidityToStake: liquidity});
    // It should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // It should not forfeit emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('forfeitEmissions(uint128)'), 0);
    // It should not mint emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('mintEmissions(address[],uint128[])'), 0);
    gauge.withdraw({_lp: tokenId});

    assertEq(nft.balanceOf(address(gauge)), 0);
    assertEq(nft.balanceOf(users.alice), 1);
    assertEq(nft.ownerOf(tokenId), address(users.alice));
    assertEq(gauge.stakedLength(users.alice), 0);
    assertEq(gauge.stakedContains(users.alice, 1), false);
    uint256[] memory staked = gauge.stakedValues(users.alice);
    assertEq(staked.length, 0);
    assertEq(gauge.rewardGrowthInside(tokenId), 0);
    // It should clear the deposit block
    assertEq(gauge.depositBlock(tokenId), 0);
    assertEq(receiptToken.balanceOf(users.alice), rewardBalanceBefore);
    assertEqUint(pool.liquidity(), 0);
    assertEqUint(pool.stakedLiquidity(), 0);
    (,, int128 stakedLiquidityNet,,,,,,,) = pool.ticks(TICK_SPACING_60);
    assertEq(stakedLiquidityNet, 0);
    (,, stakedLiquidityNet,,,,,,,) = pool.ticks(2 * TICK_SPACING_60);
    assertEq(stakedLiquidityNet, 0);

    (uint128 nftLiquidity,,,,) =
      pool.positions(keccak256(abi.encodePacked(address(nft), TICK_SPACING_60, 2 * TICK_SPACING_60)));
    assertEqUint(nftLiquidity, liquidity);

    (gaugeLiquidity,,,,) =
      pool.positions(keccak256(abi.encodePacked(address(gauge), TICK_SPACING_60, 2 * TICK_SPACING_60)));
    assertEqUint(gaugeLiquidity, 0);
  }

  function test_WithdrawWithPositionLeftOfCurrentPrice() public {
    INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
      token0: address(token0),
      token1: address(token1),
      tickSpacing: TICK_SPACING_60,
      tickLower: -2 * TICK_SPACING_60,
      tickUpper: -TICK_SPACING_60,
      recipient: users.alice,
      amount0Desired: TOKEN_1,
      amount1Desired: TOKEN_1,
      amount0Min: 0,
      amount1Min: 0,
      deadline: 10,
      sqrtPriceX96: 0
    });
    (uint256 tokenId, uint128 liquidity,,) = nft.mint(params);
    nft.approve(address(gauge), tokenId);
    gauge.deposit({_lp: tokenId});

    (uint128 gaugeLiquidity,,,,) =
      pool.positions(keccak256(abi.encodePacked(address(gauge), -2 * TICK_SPACING_60, -TICK_SPACING_60)));
    assertEqUint(gaugeLiquidity, liquidity);
    uint256 rewardBalanceBefore = receiptToken.balanceOf(users.alice);

    vm.expectEmit(true, true, true, true, address(gauge));
    emit Withdraw({_caller: users.alice, _user: users.alice, _tokenId: tokenId, _liquidityToStake: liquidity});
    // It should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // It should not forfeit emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('forfeitEmissions(uint128)'), 0);
    // It should not mint emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('mintEmissions(address[],uint128[])'), 0);
    gauge.withdraw({_lp: tokenId});

    assertEq(nft.balanceOf(address(gauge)), 0);
    assertEq(nft.balanceOf(users.alice), 1);
    assertEq(nft.ownerOf(tokenId), address(users.alice));
    assertEq(gauge.stakedLength(users.alice), 0);
    assertEq(gauge.stakedContains(users.alice, 1), false);
    uint256[] memory staked = gauge.stakedValues(users.alice);
    assertEq(staked.length, 0);
    assertEq(gauge.rewardGrowthInside(tokenId), 0);
    // It should clear the deposit block
    assertEq(gauge.depositBlock(tokenId), 0);
    assertEq(receiptToken.balanceOf(users.alice), rewardBalanceBefore);
    assertEqUint(pool.liquidity(), 0);
    assertEqUint(pool.stakedLiquidity(), 0);
    (,, int128 stakedLiquidityNet,,,,,,,) = pool.ticks(-2 * TICK_SPACING_60);
    assertEq(stakedLiquidityNet, 0);
    (,, stakedLiquidityNet,,,,,,,) = pool.ticks(-TICK_SPACING_60);
    assertEq(stakedLiquidityNet, 0);

    (uint128 nftLiquidity,,,,) =
      pool.positions(keccak256(abi.encodePacked(address(nft), -2 * TICK_SPACING_60, -TICK_SPACING_60)));
    assertEqUint(nftLiquidity, liquidity);

    (gaugeLiquidity,,,,) =
      pool.positions(keccak256(abi.encodePacked(address(gauge), -2 * TICK_SPACING_60, -TICK_SPACING_60)));
    assertEqUint(gaugeLiquidity, 0);
  }

  function test_WithdrawCollectsRewards() public {
    skipToNextEpoch(0);
    INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
      token0: address(token0),
      token1: address(token1),
      tickSpacing: TICK_SPACING_60,
      tickLower: -TICK_SPACING_60,
      tickUpper: TICK_SPACING_60,
      recipient: users.alice,
      amount0Desired: TOKEN_1,
      amount1Desired: TOKEN_1,
      amount0Min: 0,
      amount1Min: 0,
      deadline: block.timestamp,
      sqrtPriceX96: 0
    });
    (uint256 tokenId, uint128 liquidity,,) = nft.mint(params);
    nft.approve(address(gauge), tokenId);
    gauge.deposit({_lp: tokenId});

    uint128 rewardAmount = uint128(TOKEN_1 * 100);
    uint256 rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(rewardAmount), Q128, liquidity);

    vm.startPrank(users.alice);

    _setGaugeRewardGrowth(tokenId, 0);
    _mockPoolRewardGrowth(tokenId, rewardGrowthInside);
    // It should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // It should not forfeit emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('forfeitEmissions(uint128)'), 0);
    _mockAndExpectMintEmissions(users.alice, rewardAmount);

    vm.expectEmit(false, false, false, true, address(nft));
    emit MetadataUpdate(tokenId);
    // It should emit a {EmissionsClaimed} event
    vm.expectEmit(address(gauge));
    emit EmissionsClaimed(users.alice, tokenId, users.alice, rewardAmount);
    // It should emit a {Withdraw} event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit Withdraw({_caller: users.alice, _user: users.alice, _tokenId: tokenId, _liquidityToStake: liquidity});
    gauge.withdraw({_lp: tokenId});

    // It should mint full emissions to owner
    assertEq(receiptToken.balanceOf(users.alice), rewardAmount);

    assertEq(nft.balanceOf(address(gauge)), 0);
    assertEq(nft.balanceOf(users.alice), 1);
    assertEq(nft.ownerOf(tokenId), address(users.alice));
    assertEq(gauge.stakedLength(users.alice), 0);
    assertEq(gauge.stakedContains(users.alice, 1), false);
    // It should advance the position reward growth
    assertEq(gauge.rewardGrowthInside(tokenId), rewardGrowthInside);
    // It should clear the deposit block
    assertEq(gauge.depositBlock(tokenId), 0);
    assertEqUint(pool.liquidity(), liquidity);
    assertEqUint(pool.stakedLiquidity(), 0);
    (,, int128 stakedLiquidityNet,,,,,,,) = pool.ticks(-TICK_SPACING_60);
    assertEq(stakedLiquidityNet, 0);
    (,, stakedLiquidityNet,,,,,,,) = pool.ticks(TICK_SPACING_60);
    assertEq(stakedLiquidityNet, 0);
  }

  function test_WithdrawUpdatesPositionCorrectly() public {
    uint256 tokenId =
      nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1 * 10, TOKEN_1 * 10, users.alice);

    nft.approve(address(gauge), tokenId);
    gauge.deposit(tokenId);

    // swap 1 token0
    clCallee.swapExact0For1(address(pool), 1e18, users.alice, MIN_SQRT_RATIO + 1);

    // swap 1 token1
    clCallee.swapExact1For0(address(pool), 1e18, users.alice, MAX_SQRT_RATIO - 1);

    gauge.withdraw(tokenId);

    nft.approve(address(nftCallee), tokenId);
    // call collect to trigger update on the nft position
    nftCallee.collectOneAndOneForTokenId(tokenId, users.alice);

    Position.Info memory gp = Position.Info(0, 0, 0, 0, 0);

    (gp.liquidity, gp.feeGrowthInside0LastX128, gp.feeGrowthInside1LastX128, gp.tokensOwed0, gp.tokensOwed1) =
      pool.positions(
        keccak256(abi.encodePacked(address(gauge), getMinTick(TICK_SPACING_60), getMaxTick(TICK_SPACING_60)))
      );

    assertEqUint(gp.liquidity, 0);

    Position.Info memory np = Position.Info(0, 0, 0, 0, 0);

    (np.liquidity, np.feeGrowthInside0LastX128, np.feeGrowthInside1LastX128, np.tokensOwed0, np.tokensOwed1) =
      pool.positions(
        keccak256(abi.encodePacked(address(nft), getMinTick(TICK_SPACING_60), getMaxTick(TICK_SPACING_60)))
      );

    assertEqUint(np.liquidity, TOKEN_1 * 10);

    (
      ,,,,,,,,
      uint256 feeGrowthInside0LastX128NFT,
      uint256 feeGrowthInside1LastX128NFT,
      uint128 tokensOwed0NFT,
      uint128 tokensOwed1NFT
    ) = nft.positions(tokenId);

    assertEq(gp.feeGrowthInside0LastX128, feeGrowthInside0LastX128NFT);
    assertEq(gp.feeGrowthInside1LastX128, feeGrowthInside1LastX128NFT);
    assertEq(np.feeGrowthInside0LastX128, feeGrowthInside0LastX128NFT);
    assertEq(np.feeGrowthInside1LastX128, feeGrowthInside1LastX128NFT);
    assertEqUint(tokensOwed0NFT, 0);
    assertEqUint(tokensOwed1NFT, 0);
    assertEqUint(gp.tokensOwed0, 0);
    assertEqUint(gp.tokensOwed1, 0);
    // tokensOwed should be 0 in all cases for gauge
    assertEqUint(np.tokensOwed0, 0);
    assertEqUint(np.tokensOwed1, 0);
  }

  function test_WithdrawUpdatesPositionCorrectlyWithUnstakedPositions() public {
    uint256 tokenId =
      nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1 * 10, TOKEN_1 * 10, users.alice);

    nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1 * 10, TOKEN_1 * 10, users.alice);

    // swap 1 token0
    clCallee.swapExact0For1(address(pool), 1e18, users.alice, MIN_SQRT_RATIO + 1);

    // call collect to trigger update on the nft position
    nft.collect(
      INonfungiblePositionManager.CollectParams({
        tokenId: tokenId,
        recipient: users.alice,
        amount0Max: 1, // don't actually collect it all
        amount1Max: 1
      })
    );

    (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, uint128 tokensOwed0, uint128 tokensOwed1) = pool.positions(
      keccak256(abi.encodePacked(address(nft), getMinTick(TICK_SPACING_60), getMaxTick(TICK_SPACING_60)))
    );
    {
      // check tokenId
      (
        ,,,,,,,,
        uint256 feeGrowthInside0LastX128NFT,
        uint256 feeGrowthInside1LastX128NFT,
        uint128 tokensOwed0NFT,
        uint128 tokensOwed1NFT
      ) = nft.positions(tokenId);

      assertEq(feeGrowthInside0LastX128, feeGrowthInside0LastX128NFT);
      assertEq(feeGrowthInside1LastX128, feeGrowthInside1LastX128NFT);
      assertApproxEqAbs(uint256(tokensOwed0NFT), 15e14, 2);
      assertEqUint(tokensOwed1NFT, 0);
      assertApproxEqAbs(uint256(tokensOwed0), 3e15, 2);
      assertEqUint(tokensOwed1, 0);
    }
  }

  function test_WithdrawUpdatesPositionCorrectlyWithStakedAndUnstakedButStakedTriggersUpdate() public {
    uint256 tokenId =
      nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1 * 10, TOKEN_1 * 10, users.alice);

    uint256 tokenId2 =
      nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1 * 10, TOKEN_1 * 10, users.alice);

    // two identical nfts, deposit one of them
    nft.approve(address(gauge), tokenId);
    gauge.deposit(tokenId);

    // swap 1 token0
    clCallee.swapExact0For1(address(pool), 1e18, users.alice, MIN_SQRT_RATIO + 1);

    // staked triggers withdraw
    // triggers call to burn => position.update(staked=true)
    gauge.withdraw(tokenId);

    uint256 pre0Bal = token0.balanceOf(users.alice);
    nft.approve(address(nftCallee), tokenId);
    // call collect to trigger update on the nft position
    nftCallee.collectOneAndOneForTokenId(tokenId, users.alice);

    assertEq(token0.balanceOf(users.alice), pre0Bal); // values should be equal

    // gauge position in the pool (staked)
    (
      ,
      uint256 feeGrowthInside0LastX128Gauge,
      uint256 feeGrowthInside1LastX128Gauge,
      uint128 tokensOwed0Gauge,
      uint128 tokensOwed1Gauge
    ) = pool.positions(
      keccak256(abi.encodePacked(address(gauge), getMinTick(TICK_SPACING_60), getMaxTick(TICK_SPACING_60)))
    );

    // check tokenId
    {
      (
        ,,,,,,,,
        uint256 feeGrowthInside0LastX128Position,
        uint256 feeGrowthInside1LastX128Position,
        uint128 tokensOwed0Position,
        uint128 tokensOwed1Position
      ) = nft.positions(tokenId);

      assertEq(feeGrowthInside0LastX128Gauge, feeGrowthInside0LastX128Position);
      assertEq(feeGrowthInside1LastX128Gauge, feeGrowthInside1LastX128Position);
      assertEqUint(tokensOwed0Position, 0);
      assertEqUint(tokensOwed1Position, 0);
      // tokensOwed should be 0 in all cases for gauge
      assertEqUint(tokensOwed0Gauge, 0);
      assertEqUint(tokensOwed1Gauge, 0);
    }

    pre0Bal = token0.balanceOf(users.alice);
    nft.approve(address(nftCallee), tokenId2);
    nftCallee.collectOneAndOneForTokenId(tokenId2, users.alice);

    assertEq(token0.balanceOf(users.alice), pre0Bal + 1); // should collect 1 for tokenId2

    // nft position in the pool (unstaked)
    (
      ,
      uint256 feeGrowthInside0LastX128Nft,
      uint256 feeGrowthInside1LastX128Nft,
      uint128 tokensOwed0Nft,
      uint128 tokensOwed1Nft
    ) = pool.positions(
      keccak256(abi.encodePacked(address(nft), getMinTick(TICK_SPACING_60), getMaxTick(TICK_SPACING_60)))
    );
    // check tokenId2
    {
      (
        ,,,,,,,,
        uint256 feeGrowthInside0LastX128Position,
        uint256 feeGrowthInside1LastX128Position,
        uint128 tokensOwed0Position,
        uint128 tokensOwed1Position
      ) = nft.positions(tokenId2);

      assertEq(feeGrowthInside0LastX128Nft, feeGrowthInside0LastX128Position);
      assertEq(feeGrowthInside1LastX128Nft, feeGrowthInside1LastX128Position);
      assertApproxEqAbs(uint256(tokensOwed0Position), 15e14, 2);
      assertEqUint(tokensOwed1Position, 0);
      assertApproxEqAbs(uint256(tokensOwed0Nft), 15e14, 2);
      assertEqUint(tokensOwed1Nft, 0);
    }

    // feeGrowthInsideXLastX128 should be the same for staked and unstaked in all cases
    assertEq(feeGrowthInside0LastX128Gauge, feeGrowthInside0LastX128Nft);
    assertEq(feeGrowthInside1LastX128Gauge, feeGrowthInside1LastX128Nft);
  }

  function test_WithdrawUpdatesPositionCorrectlyWithStakedAndUnstakedButUnstakedTriggersUpdate() public {
    uint256 tokenId =
      nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1 * 10, TOKEN_1 * 10, users.alice);

    uint256 tokenId2 =
      nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1 * 10, TOKEN_1 * 10, users.alice);

    // two identical nfts, deposit one of them
    nft.approve(address(gauge), tokenId);
    gauge.deposit(tokenId);

    // swap 1 token0
    clCallee.swapExact0For1(address(pool), 1e18, users.alice, MIN_SQRT_RATIO + 1);

    // call collect to trigger update on the nft position
    // triggers call to burn => position.update(staked=false)
    uint256 pre0Bal = token0.balanceOf(users.alice);
    nft.approve(address(nftCallee), tokenId2);
    nftCallee.collectOneAndOneForTokenId(tokenId2, users.alice);

    assertEq(token0.balanceOf(users.alice), pre0Bal + 1); // should collect 1 for unstaked position

    gauge.withdraw(tokenId);

    pre0Bal = token0.balanceOf(users.alice);
    nft.approve(address(nftCallee), tokenId);
    nftCallee.collectOneAndOneForTokenId(tokenId, users.alice); // should be equal

    assertEq(token0.balanceOf(users.alice), pre0Bal);
    // gauge position in the pool (staked)
    (
      ,
      uint256 feeGrowthInside0LastX128Gauge,
      uint256 feeGrowthInside1LastX128Gauge,
      uint128 tokensOwed0Gauge,
      uint128 tokensOwed1Gauge
    ) = pool.positions(
      keccak256(abi.encodePacked(address(gauge), getMinTick(TICK_SPACING_60), getMaxTick(TICK_SPACING_60)))
    );

    // check tokenId
    {
      (
        ,,,,,,,,
        uint256 feeGrowthInside0LastX128Position,
        uint256 feeGrowthInside1LastX128Position,
        uint128 tokensOwed0Position,
        uint128 tokensOwed1Position
      ) = nft.positions(tokenId);

      assertEq(feeGrowthInside0LastX128Gauge, feeGrowthInside0LastX128Position);
      assertEq(feeGrowthInside1LastX128Gauge, feeGrowthInside1LastX128Position);
      assertEqUint(tokensOwed0Position, 0);
      assertEqUint(tokensOwed1Position, 0);
      // tokensOwed should be 0 in all cases for gauge
      assertEqUint(tokensOwed0Gauge, 0);
      assertEqUint(tokensOwed1Gauge, 0);
    }

    // nft position in the pool (unstaked)
    (
      ,
      uint256 feeGrowthInside0LastX128Nft,
      uint256 feeGrowthInside1LastX128Nft,
      uint128 tokensOwed0Nft,
      uint128 tokensOwed1Nft
    ) = pool.positions(
      keccak256(abi.encodePacked(address(nft), getMinTick(TICK_SPACING_60), getMaxTick(TICK_SPACING_60)))
    );
    // check tokenId2
    {
      (
        ,,,,,,,,
        uint256 feeGrowthInside0LastX128Position,
        uint256 feeGrowthInside1LastX128Position,
        uint128 tokensOwed0Position,
        uint128 tokensOwed1Position
      ) = nft.positions(tokenId2);

      assertEq(feeGrowthInside0LastX128Nft, feeGrowthInside0LastX128Position);
      assertEq(feeGrowthInside1LastX128Nft, feeGrowthInside1LastX128Position);
      assertApproxEqAbs(uint256(tokensOwed0Position), 15e14, 2);
      assertEqUint(tokensOwed1Position, 0);
      assertApproxEqAbs(uint256(tokensOwed0Nft), 15e14, 2);
      assertEqUint(tokensOwed1Nft, 0);
    }

    // feeGrowthInsideXLastX128 should be the same for staked and unstaked in all cases
    assertEq(feeGrowthInside0LastX128Gauge, feeGrowthInside0LastX128Nft);
    assertEq(feeGrowthInside1LastX128Gauge, feeGrowthInside1LastX128Nft);
  }

  // @dev Writes the position reward growth checkpoint in the gauge.
  function _setGaugeRewardGrowth(uint256 tokenId, uint256 rewardGrowthInside) internal {
    stdstore.target(address(gauge)).sig(gauge.rewardGrowthInside.selector).with_key(tokenId)
      .checked_write(rewardGrowthInside);
  }

  // @dev Mocks and expects the pool reward growth read for a position.
  function _mockPoolRewardGrowth(uint256 tokenId, uint256 rewardGrowthInside) internal {
    (,,,,, int24 tickLower, int24 tickUpper,,,,,) = nft.positions(tokenId);

    _mockAndExpect({
      _receiver: address(pool),
      _calldata: abi.encodeWithSignature(
        'getRewardGrowthInside(int24,int24,uint256)', tickLower, tickUpper, uint256(0)
      ),
      _returned: abi.encode(rewardGrowthInside)
    });
  }

  // @dev Redirects voter emission minting and expects a receipt token mint.
  function _mockAndExpectMintEmissions(address recipient, uint128 amount) internal {
    address[] memory recipients = new address[](1);
    recipients[0] = recipient;
    uint128[] memory amounts = new uint128[](1);
    amounts[0] = amount;

    bytes memory callData = abi.encodeWithSignature('mintEmissions(address[],uint128[])', recipients, amounts);
    vm.expectCall(address(receiptToken), abi.encodeWithSignature('mint(address,uint256)', recipient, amount));
    vm.mockFunction(address(voter), address(mockLeafVoter), callData);
  }

  // @dev Mocks a call and expects it to be made.
  function _mockAndExpect(address _receiver, bytes memory _calldata, bytes memory _returned) internal {
    vm.mockCall(_receiver, _calldata, _returned);
    vm.expectCall(_receiver, _calldata);
  }
}
