pragma solidity ^0.7.6;
pragma abicoder v2;

import {FullMath} from 'contracts/core/libraries/FullMath.sol';

import {TestERC20} from 'contracts/periphery/test/TestERC20.sol';
import {MockLeafVoter} from 'contracts/test/MockLeafVoter.sol';

import '../CLGauge.t.sol';

contract WithdrawConcreteUnitTest is CLGaugeTest {
  using stdStorage for StdStorage;

  uint256 public minStakeBlocks = 10;
  uint256 public penaltyRate = 1_000_000;

  TestERC20 public receiptToken;
  MockLeafVoter public mockLeafVoter;

  function setUp() public override {
    super.setUp();

    vm.prank(users.feeManager);
    customUnstakedFeeModule.setCustomFee(address(pool), 420);

    skipToNextEpoch(0);

    receiptToken = new TestERC20(0);
    mockLeafVoter = new MockLeafVoter(receiptToken);
  }

  function test_WhenTheCallerIsNotTheTokenOwner() external {
    // It should revert with {NA}
    uint256 tokenId = _mintAndDepositFullRange();

    vm.startPrank(users.charlie);
    vm.expectRevert(abi.encodePacked('NA'));
    gauge.withdraw({_lp: tokenId});
  }

  modifier whenTheCallerIsTheTokenOwner() {
    _;
  }

  function test_WhenThereAreNoAccruedRewards() external whenTheCallerIsTheTokenOwner {
    (uint256 tokenId, uint128 liquidity) = _mintAndDepositFullRangeWithLiquidity();
    uint256 rewardBalanceBefore = receiptToken.balanceOf(users.alice);
    uint256 rewardGrowthInside = gauge.rewardGrowthInside(tokenId);

    vm.startPrank(users.alice);
    _mockPoolRewardGrowth(tokenId, rewardGrowthInside);
    // It should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // It should not forfeit emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('forfeitEmissions(uint128)'), 0);
    // It should not mint emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('mintEmissions(address[],uint128[])'), 0);

    // It should emit a {Withdraw} event
    vm.expectEmit(address(gauge));
    emit Withdraw({_caller: users.alice, _user: users.alice, _tokenId: tokenId, _liquidityToStake: liquidity});
    gauge.withdraw({_lp: tokenId});

    // It should return the NFT to the owner
    assertEq(nft.ownerOf(tokenId), users.alice);
    // It should unstake liquidity from the pool
    assertEqUint(pool.stakedLiquidity(), 0);
    assertEq(gauge.stakedLength(users.alice), 0);
    // It should clear the deposit block
    assertEq(gauge.depositBlock(tokenId), 0);
    assertEq(receiptToken.balanceOf(users.alice), rewardBalanceBefore);
  }

  modifier whenThereAreAccruedRewards() {
    _;
  }

  modifier whenPenaltyRateIsZero() {
    // default: penalty params not configured
    _;
  }

  function test_WhenEmissionMintingReverts()
    external
    whenTheCallerIsTheTokenOwner
    whenThereAreAccruedRewards
    whenPenaltyRateIsZero
  {
    uint256 referralShare = gaugeFactory.DEFAULT_MAX_SHARE_CAP();
    vm.prank(users.owner);
    gaugeFactory.setReferralConfig(address(gauge), users.referral, referralShare);

    (uint256 tokenId, uint128 liquidity) = _mintAndDepositFullRangeWithLiquidity();
    uint128 rewardAmount = uint128(TOKEN_1 * 100);
    uint256 rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(rewardAmount), Q128, liquidity);
    uint128 referralAmount = uint128(uint256(rewardAmount) * referralShare / gaugeFactory.MAX_PIPS());
    uint128 lpAmount = rewardAmount - referralAmount;
    uint256 olderDeferredAmount = TOKEN_1 * 17;
    uint256 olderDeferredReferralAmount = TOKEN_1 * 3;
    address[] memory recipients = new address[](1);
    recipients[0] = users.alice;
    uint128[] memory amounts = new uint128[](1);
    amounts[0] = lpAmount;
    bytes memory callData = abi.encodeWithSignature('mintEmissions(address[],uint128[])', recipients, amounts);

    _setDeferredEmissions(users.alice, olderDeferredAmount);
    _setDeferredReferralEmissions(users.referral, olderDeferredReferralAmount);
    _setGaugeRewardGrowth(tokenId, 0);
    _mockPoolRewardGrowth(tokenId, rewardGrowthInside);
    // It should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // It should attempt to mint emissions
    vm.mockCallRevert(address(voter), callData, abi.encodeWithSignature('ChainNotActive()'));
    vm.expectCall(address(voter), callData);

    vm.startPrank(users.alice);
    // It should emit a {ReferralEmissionsDeferred} event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit ReferralEmissionsDeferred(users.alice, tokenId, users.referral, referralAmount);
    // It should emit an {EmissionsDeferred} event
    vm.expectEmit(true, true, false, true, address(gauge));
    emit EmissionsDeferred(users.alice, tokenId, lpAmount);
    // It should emit a {Withdraw} event
    vm.expectEmit(address(gauge));
    emit Withdraw({_caller: users.alice, _user: users.alice, _tokenId: tokenId, _liquidityToStake: liquidity});
    gauge.withdraw({_lp: tokenId});

    // It should advance the position reward growth
    assertEq(gauge.rewardGrowthInside(tokenId), rewardGrowthInside);
    // It should store the LP emissions on the account
    // It should preserve older deferred emissions
    assertEq(gauge.deferredEmissions(users.alice), olderDeferredAmount + lpAmount);
    // It should store the referral emissions on the referral
    assertEq(gauge.deferredReferralEmissions(users.referral), olderDeferredReferralAmount + referralAmount);
    // It should unstake liquidity from the pool
    assertEqUint(pool.stakedLiquidity(), 0);
    // It should return the NFT to the owner
    assertEq(nft.ownerOf(tokenId), users.alice);
  }

  function test_WhenEmissionMintingDoesNotRevert()
    external
    whenTheCallerIsTheTokenOwner
    whenThereAreAccruedRewards
    whenPenaltyRateIsZero
  {
    uint256 referralShare = gaugeFactory.DEFAULT_MAX_SHARE_CAP();
    vm.prank(users.owner);
    gaugeFactory.setReferralConfig(address(gauge), users.referral, referralShare);

    (uint256 tokenId, uint128 liquidity) = _mintAndDepositFullRangeWithLiquidity();
    uint128 rewardAmount = uint128(TOKEN_1 * 100);
    uint128 referralAmount = uint128(uint256(rewardAmount) * referralShare / gaugeFactory.MAX_PIPS());
    uint128 lpAmount = rewardAmount - referralAmount;
    uint256 rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(rewardAmount), Q128, liquidity);
    uint256 olderDeferredAmount = TOKEN_1 * 17;

    stdstore.target(address(gauge)).sig(gauge.deferredEmissions.selector).with_key(users.alice)
      .checked_write(olderDeferredAmount);
    _setGaugeRewardGrowth(tokenId, 0);
    _mockPoolRewardGrowth(tokenId, rewardGrowthInside);
    // It should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // It should not forfeit emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('forfeitEmissions(uint128)'), 0);
    _mockAndExpectMintEmissions(users.alice, lpAmount);

    vm.startPrank(users.alice);
    // It should emit a {ReferralEmissionsDeferred} event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit ReferralEmissionsDeferred(users.alice, tokenId, users.referral, referralAmount);
    // It should emit a {EmissionsClaimed} event
    vm.expectEmit(address(gauge));
    emit EmissionsClaimed(users.alice, tokenId, users.alice, lpAmount);
    // It should emit a {Withdraw} event
    vm.expectEmit(address(gauge));
    emit Withdraw({_caller: users.alice, _user: users.alice, _tokenId: tokenId, _liquidityToStake: liquidity});
    gauge.withdraw({_lp: tokenId});

    // It should advance the position reward growth
    assertEq(gauge.rewardGrowthInside(tokenId), rewardGrowthInside);
    // It should mint LP emissions to owner
    assertEq(receiptToken.balanceOf(users.alice), lpAmount);
    // It should store the referral emissions on the referral
    assertEq(gauge.deferredReferralEmissions(users.referral), referralAmount);
    // It should preserve older deferred emissions
    assertEq(gauge.deferredEmissions(users.alice), olderDeferredAmount);
    // It should return the NFT to the owner
    assertEq(nft.ownerOf(tokenId), users.alice);
    // It should unstake liquidity from the pool
    assertEqUint(pool.stakedLiquidity(), 0);
  }

  modifier whenPenaltyRateIsGreaterThanZero() {
    vm.startPrank(users.owner);
    gaugeFactory.setPenaltyConfig(minStakeBlocks, penaltyRate);
    vm.stopPrank();
    _;
  }

  modifier whenCalledWithinMinStakeBlocks() {
    _;
  }

  function test_WhenPenaltyRoundsDownToZero()
    external
    whenTheCallerIsTheTokenOwner
    whenThereAreAccruedRewards
    whenPenaltyRateIsGreaterThanZero
    whenCalledWithinMinStakeBlocks
  {
    // penaltyRate = 1 pip, reward = 1 wei -> penalty rounds to 0
    penaltyRate = 1;
    vm.startPrank(users.owner);
    gaugeFactory.setPenaltyConfig(minStakeBlocks, penaltyRate);
    vm.stopPrank();

    (uint256 tokenId, uint128 liquidity) = _mintAndDepositFullRangeWithLiquidity();
    uint256 rewardGrowthInside = FullMath.mulDivRoundingUp(1, Q128, liquidity);
    uint128 rewardAmount = uint128(FullMath.mulDiv(rewardGrowthInside, liquidity, Q128));

    _setGaugeRewardGrowth(tokenId, 0);
    _mockPoolRewardGrowth(tokenId, rewardGrowthInside);
    // It should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // It should not forfeit emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('forfeitEmissions(uint128)'), 0);
    _mockAndExpectMintEmissions(users.alice, rewardAmount);

    vm.startPrank(users.alice);
    // It should emit a {EmissionsClaimed} event
    vm.expectEmit(address(gauge));
    emit EmissionsClaimed(users.alice, tokenId, users.alice, rewardAmount);
    gauge.withdraw({_lp: tokenId});

    // It should advance the position reward growth
    assertEq(gauge.rewardGrowthInside(tokenId), rewardGrowthInside);
    // It should mint full emissions to owner
    assertEq(receiptToken.balanceOf(users.alice), rewardAmount);
  }

  modifier whenPenaltyDoesNotRoundDownToZero() {
    _;
  }

  modifier whenThereAreNoRemainingRewardsAfterPenalty() {
    _;
  }

  function test_WhenThereAreNoRemainingRewardsAfterPenalty()
    external
    whenTheCallerIsTheTokenOwner
    whenThereAreAccruedRewards
    whenPenaltyRateIsGreaterThanZero
    whenCalledWithinMinStakeBlocks
    whenPenaltyDoesNotRoundDownToZero
    whenThereAreNoRemainingRewardsAfterPenalty
  {
    (uint256 tokenId, uint128 liquidity) = _mintAndDepositFullRangeWithLiquidity();
    uint128 rewardAmount = uint128(TOKEN_1 * 100);
    uint256 rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(rewardAmount), Q128, liquidity);

    _setGaugeRewardGrowth(tokenId, 0);
    _mockPoolRewardGrowth(tokenId, rewardGrowthInside);
    // It should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // It should forfeit all emissions
    _mockAndExpectForfeitEmissions(rewardAmount);
    // It should not mint emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('mintEmissions(address[],uint128[])'), 0);

    vm.startPrank(users.alice);
    // It should emit a {EarlyWithdrawPenalty} event
    vm.expectEmit(address(gauge));
    emit EarlyWithdrawPenalty({_from: users.alice, _tokenId: tokenId, _penalty: rewardAmount});
    // It should emit a {Withdraw} event
    vm.expectEmit(address(gauge));
    emit Withdraw({_caller: users.alice, _user: users.alice, _tokenId: tokenId, _liquidityToStake: liquidity});
    gauge.withdraw({_lp: tokenId});

    // 100% penalty -- alice gets no emissions, all accrued emissions are forfeited
    // It should advance the position reward growth
    assertEq(gauge.rewardGrowthInside(tokenId), rewardGrowthInside);
    assertEq(receiptToken.balanceOf(users.alice), 0);
    // It should return the NFT to the owner
    assertEq(nft.ownerOf(tokenId), users.alice);
    // It should unstake liquidity from the pool
    assertEqUint(pool.stakedLiquidity(), 0);
  }

  modifier whenThereAreRemainingRewardsAfterPenalty() {
    _;
  }

  function test_WhenEmissionMintingDoesNotRevert_()
    external
    whenTheCallerIsTheTokenOwner
    whenThereAreAccruedRewards
    whenPenaltyRateIsGreaterThanZero
    whenCalledWithinMinStakeBlocks
    whenPenaltyDoesNotRoundDownToZero
    whenThereAreRemainingRewardsAfterPenalty
  {
    penaltyRate = 500_000;
    vm.startPrank(users.owner);
    gaugeFactory.setPenaltyConfig(minStakeBlocks, penaltyRate);
    vm.stopPrank();

    (uint256 tokenId, uint128 liquidity) = _mintAndDepositFullRangeWithLiquidity();
    uint128 rewardAmount = uint128(TOKEN_1 * 100);
    uint256 rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(rewardAmount), Q128, liquidity);
    uint128 expectedPenalty = rewardAmount / 2;
    uint128 remainingAmount = rewardAmount - expectedPenalty;

    _setGaugeRewardGrowth(tokenId, 0);
    _mockPoolRewardGrowth(tokenId, rewardGrowthInside);
    // It should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // It should forfeit the penalty emissions
    _mockAndExpectForfeitEmissions(expectedPenalty);
    _mockAndExpectMintEmissions(users.alice, remainingAmount);

    vm.startPrank(users.alice);
    // It should emit a {EarlyWithdrawPenalty} event
    vm.expectEmit(address(gauge));
    emit EarlyWithdrawPenalty({_from: users.alice, _tokenId: tokenId, _penalty: expectedPenalty});
    // It should emit a {EmissionsClaimed} event
    vm.expectEmit(address(gauge));
    emit EmissionsClaimed(users.alice, tokenId, users.alice, remainingAmount);
    // It should emit a {Withdraw} event
    vm.expectEmit(address(gauge));
    emit Withdraw({_caller: users.alice, _user: users.alice, _tokenId: tokenId, _liquidityToStake: liquidity});
    gauge.withdraw({_lp: tokenId});

    // It should advance the position reward growth
    assertEq(gauge.rewardGrowthInside(tokenId), rewardGrowthInside);
    // It should mint remaining emissions to owner
    assertEq(receiptToken.balanceOf(users.alice), remainingAmount);
    // It should return the NFT to the owner
    assertEq(nft.ownerOf(tokenId), users.alice);
    // It should unstake liquidity from the pool
    assertEqUint(pool.stakedLiquidity(), 0);
  }

  function test_WhenEmissionMintingReverts_(
    uint128 _rewardAmount,
    uint256 _penaltyRate,
    uint256 _referralShare,
    uint128 _rollover
  )
    external
    whenTheCallerIsTheTokenOwner
    whenThereAreAccruedRewards
    whenPenaltyRateIsGreaterThanZero
    whenCalledWithinMinStakeBlocks
    whenPenaltyDoesNotRoundDownToZero
    whenThereAreRemainingRewardsAfterPenalty
  {
    uint256 _maxPips = gaugeFactory.MAX_PIPS();
    _rewardAmount = uint128(bound(uint256(_rewardAmount), TOKEN_1, TOKEN_1 * 1_000_000));
    _penaltyRate = bound(_penaltyRate, 1, _maxPips - 1);
    _referralShare = bound(_referralShare, 1, gaugeFactory.DEFAULT_MAX_SHARE_CAP());
    _rollover = uint128(bound(uint256(_rollover), 1, TOKEN_1 * 1_000_000));

    vm.startPrank(users.owner);
    gaugeFactory.setPenaltyConfig(minStakeBlocks, _penaltyRate);
    gaugeFactory.setReferralConfig(address(gauge), users.referral, _referralShare);
    vm.stopPrank();

    (uint256 _tokenId, uint128 _liquidity) = _mintAndDepositFullRangeWithLiquidity();
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);
    uint128 _accruedAmount = uint128(FullMath.mulDiv(_rewardGrowthInside, _liquidity, Q128));
    uint128 _penaltyAmount = uint128(uint256(_accruedAmount) * _penaltyRate / _maxPips);
    // It should apply the penalty before the referral
    uint128 _referralAmount = uint128((uint256(_accruedAmount) - _penaltyAmount) * _referralShare / _maxPips);
    uint128 _lpAmount = _accruedAmount - _penaltyAmount - _referralAmount;

    bytes memory _callData;
    {
      address[] memory _recipients = new address[](1);
      _recipients[0] = users.alice;
      uint128[] memory _amounts = new uint128[](1);
      _amounts[0] = _lpAmount;
      _callData = abi.encodeWithSignature('mintEmissions(address[],uint128[])', _recipients, _amounts);
    }

    _setGaugeRewardGrowth(_tokenId, 0);
    _mockPoolRewardGrowth(_tokenId, _rewardGrowthInside);
    // It should settle the pool rewards
    _mockAndExpect({
      _receiver: address(pool),
      _calldata: abi.encodeWithSignature('settleToBlock()'),
      _returned: abi.encode(uint256(_rollover))
    });
    // It should forfeit the rollover together with the penalty emissions
    _mockAndExpectForfeitEmissions(_penaltyAmount + _rollover);
    // It should attempt to mint emissions
    vm.mockCallRevert(address(voter), _callData, abi.encodeWithSignature('ChainNotActive()'));
    vm.expectCall(address(voter), _callData);

    vm.startPrank(users.alice);
    // It should emit an {EarlyWithdrawPenalty} event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit EarlyWithdrawPenalty(users.alice, _tokenId, _penaltyAmount);
    // It should emit a {ReferralEmissionsDeferred} event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit ReferralEmissionsDeferred(users.alice, _tokenId, users.referral, _referralAmount);
    // It should emit an {EmissionsDeferred} event
    vm.expectEmit(true, true, false, true, address(gauge));
    emit EmissionsDeferred(users.alice, _tokenId, _lpAmount);
    // It should emit a {Withdraw} event
    vm.expectEmit(address(gauge));
    emit Withdraw({_caller: users.alice, _user: users.alice, _tokenId: _tokenId, _liquidityToStake: _liquidity});
    gauge.withdraw({_lp: _tokenId});

    // It should advance the position reward growth
    assertEq(gauge.rewardGrowthInside(_tokenId), _rewardGrowthInside);
    // It should store the post-penalty LP emissions on the account
    assertEq(gauge.deferredEmissions(users.alice), _lpAmount);
    // It should store the post-penalty referral emissions on the referral
    assertEq(gauge.deferredReferralEmissions(users.referral), _referralAmount);
    // It should unstake liquidity from the pool
    assertEqUint(pool.stakedLiquidity(), 0);
    // It should return the NFT to the owner
    assertEq(nft.ownerOf(_tokenId), users.alice);
  }

  modifier whenCalledAfterMinStakeBlocks() {
    _;
  }

  function test_WhenCalledAfterMinStakeBlocks()
    external
    whenTheCallerIsTheTokenOwner
    whenThereAreAccruedRewards
    whenPenaltyRateIsGreaterThanZero
    whenCalledAfterMinStakeBlocks
  {
    (uint256 tokenId, uint128 liquidity) = _mintAndDepositFullRangeWithLiquidity();
    uint128 rewardAmount = uint128(TOKEN_1 * 100);
    uint256 rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(rewardAmount), Q128, liquidity);

    vm.roll(gauge.depositBlock(tokenId) + minStakeBlocks); // exact block boundary, so penalty does not apply

    _setGaugeRewardGrowth(tokenId, 0);
    _mockPoolRewardGrowth(tokenId, rewardGrowthInside);
    // It should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // It should not forfeit emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('forfeitEmissions(uint128)'), 0);
    _mockAndExpectMintEmissions(users.alice, rewardAmount);

    vm.startPrank(users.alice);
    // It should emit a {EmissionsClaimed} event
    vm.expectEmit(address(gauge));
    emit EmissionsClaimed(users.alice, tokenId, users.alice, rewardAmount);
    // It should emit a {Withdraw} event
    vm.expectEmit(address(gauge));
    emit Withdraw({_caller: users.alice, _user: users.alice, _tokenId: tokenId, _liquidityToStake: liquidity});
    gauge.withdraw({_lp: tokenId});

    // It should advance the position reward growth
    assertEq(gauge.rewardGrowthInside(tokenId), rewardGrowthInside);
    // It should mint full emissions to owner
    assertEq(receiptToken.balanceOf(users.alice), rewardAmount);
    // It should return the NFT to the owner
    assertEq(nft.ownerOf(tokenId), users.alice);
    // It should unstake liquidity from the pool
    assertEqUint(pool.stakedLiquidity(), 0);
  }

  function _mintAndDepositFullRange() internal returns (uint256 tokenId) {
    (tokenId,) = _mintAndDepositFullRangeWithLiquidity();
  }

  function _mintAndDepositFullRangeWithLiquidity() internal returns (uint256 tokenId, uint128 liquidity) {
    vm.startPrank(users.alice);
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
    (tokenId, liquidity,,) = nft.mint(params);
    nft.approve(address(gauge), tokenId);
    gauge.deposit({_lp: tokenId});
  }

  // @dev Writes the position reward growth checkpoint in the gauge.
  function _setGaugeRewardGrowth(uint256 tokenId, uint256 rewardGrowthInside) internal {
    stdstore.target(address(gauge)).sig(gauge.rewardGrowthInside.selector).with_key(tokenId)
      .checked_write(rewardGrowthInside);
  }

  function _setDeferredEmissions(address account, uint256 amount) internal {
    stdstore.target(address(gauge)).sig(gauge.deferredEmissions.selector).with_key(account).checked_write(amount);
  }

  function _setDeferredReferralEmissions(address referral, uint256 amount) internal {
    stdstore.target(address(gauge)).sig(gauge.deferredReferralEmissions.selector).with_key(referral)
      .checked_write(amount);
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

  // @dev Mocks and expects emission forfeiture through the voter.
  function _mockAndExpectForfeitEmissions(uint128 amount) internal {
    _mockAndExpect({
      _receiver: address(voter), _calldata: abi.encodeWithSignature('forfeitEmissions(uint128)', amount), _returned: ''
    });
  }

  // @dev Mocks a call and expects it to be made.
  function _mockAndExpect(address _receiver, bytes memory _calldata, bytes memory _returned) internal {
    vm.mockCall(_receiver, _calldata, _returned);
    vm.expectCall(_receiver, _calldata);
  }

  function testGas_withdraw() external {
    (uint256 tokenId,) = _mintAndDepositFullRangeWithLiquidity();

    gauge.withdraw({_lp: tokenId});
    vm.snapshotGasLastCall('CLGauge_withdraw');
  }
}
