// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.6;
pragma abicoder v2;

import {FullMath} from 'contracts/core/libraries/FullMath.sol';

import {TestERC20} from 'contracts/periphery/test/TestERC20.sol';
import {MockLeafVoter} from 'contracts/test/MockLeafVoter.sol';

import '../CLGauge.t.sol';

contract UnitCLGaugeEarned is CLGaugeTest {
  using stdStorage for StdStorage;

  TestERC20 public receiptToken;
  MockLeafVoter public mockLeafVoter;

  function setUp() public override {
    super.setUp();

    receiptToken = new TestERC20(0);
    mockLeafVoter = new MockLeafVoter(receiptToken);
  }

  modifier whenCalculatingSelectedPositions() {
    _;
  }

  modifier whenNoPositionsAreRequested() {
    _;
  }

  function test_WhenTheAccountHasNoDeferredLPEmissions()
    external
    view
    whenCalculatingSelectedPositions
    whenNoPositionsAreRequested
  {
    // it should return zero
    assertEq(gauge.earned(users.alice, new uint256[](0)), 0);
  }

  function test_WhenTheAccountHasDeferredLPEmissions()
    external
    whenCalculatingSelectedPositions
    whenNoPositionsAreRequested
  {
    uint256 _deferredAmount = TOKEN_1 * 100;
    _setDeferredEmissions(users.alice, _deferredAmount);

    // it should return the full deferred balance
    assertEq(gauge.earned(users.alice, new uint256[](0)), _deferredAmount);
  }

  modifier whenCalculatingOnePosition() {
    _;
  }

  function test_WhenTheTokenIdIsNotStakedByTheAccount(address _account)
    external
    whenCalculatingSelectedPositions
    whenCalculatingOnePosition
  {
    vm.assume(_account != address(0) && _account != users.alice);

    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);
    vm.stopPrank();

    // it should revert with NA
    vm.expectRevert(abi.encodePacked('NA'));
    gauge.earned(_account, _ids(_tokenId));
  }

  modifier whenThePositionIsStakedByTheAccount() {
    _;
  }

  function test_WhenThePositionHasNoAccruedEmissions(uint256 _rewardGrowthInside)
    external
    whenCalculatingSelectedPositions
    whenCalculatingOnePosition
    whenThePositionIsStakedByTheAccount
  {
    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);
    vm.stopPrank();

    // @dev Align the gauge checkpoint with the mocked pool growth so no emissions accrue.
    _setGaugeRewardGrowth(_tokenId, _rewardGrowthInside);
    uint256 _rewardGrowthGlobalX128 = pool.rewardGrowthGlobalX128();
    // @dev Mock earned's pool reads using the current global growth as the settled block state.
    _mockPoolBaseRewardGrowth(_rewardGrowthGlobalX128);
    _mockPoolRewardGrowthInside(_tokenId, _rewardGrowthGlobalX128, _rewardGrowthInside);

    // it should return zero
    assertEq(gauge.earned(users.alice, _ids(_tokenId)), 0);
  }

  modifier whenThePositionHasAccruedEmissions() {
    _;
  }

  modifier whenThereIsNoPenaltyAndNoReferral() {
    _;
  }

  function test_WhenTheRewardGrowthIsKnown()
    external
    whenCalculatingSelectedPositions
    whenCalculatingOnePosition
    whenThePositionIsStakedByTheAccount
    whenThePositionHasAccruedEmissions
    whenThereIsNoPenaltyAndNoReferral
  {
    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens.
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);
    vm.stopPrank();

    // @dev Start the gauge checkpoint at zero before the mocked accrual
    _setGaugeRewardGrowth(_tokenId, 0);
    uint256 _rewardGrowthGlobalX128 = pool.rewardGrowthGlobalX128();
    // @dev Mock earned's pool reads using the current global growth as the settled block state.
    _mockPoolBaseRewardGrowth(_rewardGrowthGlobalX128);
    _mockPoolRewardGrowthInside(_tokenId, _rewardGrowthGlobalX128, _rewardGrowthInside);

    // it should return full emissions
    assertEq(gauge.earned(users.alice, _ids(_tokenId)), _rewardAmount);

    // @dev Claimed rewards align with earned
    _claimAndAssertBalance(users.alice, _tokenId, users.bob, _rewardGrowthInside, _rewardAmount);
  }

  function test_WhenTheRewardGrowthVaries(
    uint256 _rewardGrowthBefore,
    uint256 _rewardGrowthAfter
  )
    external
    whenCalculatingSelectedPositions
    whenCalculatingOnePosition
    whenThePositionIsStakedByTheAccount
    whenThePositionHasAccruedEmissions
    whenThereIsNoPenaltyAndNoReferral
  {
    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint256 _minRewardGrowthInside = FullMath.mulDivRoundingUp(1, Q128, _liquidity);
    uint256 _maxRewardGrowthInside = FullMath.mulDiv(uint256(type(uint128).max), Q128, _liquidity);
    _rewardGrowthBefore = bound(_rewardGrowthBefore, 0, type(uint256).max - _maxRewardGrowthInside);
    _rewardGrowthAfter = bound(
      _rewardGrowthAfter, _rewardGrowthBefore + _minRewardGrowthInside, _rewardGrowthBefore + _maxRewardGrowthInside
    );

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);
    vm.stopPrank();

    _setGaugeRewardGrowth(_tokenId, _rewardGrowthBefore);
    uint256 _rewardGrowthGlobalX128 = pool.rewardGrowthGlobalX128();
    // @dev Mock earned's pool reads using the current global growth as the settled block state.
    _mockPoolBaseRewardGrowth(_rewardGrowthGlobalX128);
    _mockPoolRewardGrowthInside(_tokenId, _rewardGrowthGlobalX128, _rewardGrowthAfter);

    // @dev Estimate accrued emissions based on reward growth delta.
    uint256 _rewardGrowthDelta = _rewardGrowthAfter - _rewardGrowthBefore;
    uint128 _rewardAmount = uint128(FullMath.mulDiv(_rewardGrowthDelta, _liquidity, Q128));

    // it should return full emissions
    assertEq(gauge.earned(users.alice, _ids(_tokenId)), _rewardAmount);

    // @dev Claimed rewards align with earned
    _claimAndAssertBalance(users.alice, _tokenId, users.bob, _rewardGrowthAfter, _rewardAmount);
  }

  modifier whenThereIsAPenaltyRate() {
    uint256 _penaltyRate = gaugeFactory.MAX_PIPS() / 2;
    vm.prank(users.owner);
    gaugeFactory.setPenaltyConfig(10, _penaltyRate);
    _;
  }

  function test_WhenCalledWithinMinStakeBlocks(uint256 _elapsedBlocks)
    external
    whenCalculatingSelectedPositions
    whenCalculatingOnePosition
    whenThePositionIsStakedByTheAccount
    whenThePositionHasAccruedEmissions
    whenThereIsAPenaltyRate
  {
    // it should return emissions after penalty
    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens.
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);
    uint256 _expectedEarned = _rewardAmount / 2;

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);
    vm.stopPrank();

    uint256 _minStakeBlocks = gaugeFactory.effectivePenaltyConfig(address(gauge)).minStakeBlocks;
    _elapsedBlocks = bound(_elapsedBlocks, 0, _minStakeBlocks - 1);
    vm.roll(gauge.depositBlock(_tokenId) + _elapsedBlocks);

    _setGaugeRewardGrowth(_tokenId, 0);
    uint256 _rewardGrowthGlobalX128 = pool.rewardGrowthGlobalX128();
    // @dev Mock earned's pool reads using the current global growth as the settled block state.
    _mockPoolBaseRewardGrowth(_rewardGrowthGlobalX128);
    _mockPoolRewardGrowthInside(_tokenId, _rewardGrowthGlobalX128, _rewardGrowthInside);

    assertEq(gauge.earned(users.alice, _ids(_tokenId)), _expectedEarned);
  }

  function test_WhenCalledAfterMinStakeBlocks(uint256 _elapsedBlocks)
    external
    whenCalculatingSelectedPositions
    whenCalculatingOnePosition
    whenThePositionIsStakedByTheAccount
    whenThePositionHasAccruedEmissions
    whenThereIsAPenaltyRate
  {
    // it should return full emissions
    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens.
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);
    vm.stopPrank();

    uint256 _minStakeBlocks = gaugeFactory.effectivePenaltyConfig(address(gauge)).minStakeBlocks;
    _elapsedBlocks = bound(_elapsedBlocks, _minStakeBlocks, _minStakeBlocks * 100);
    vm.roll(gauge.depositBlock(_tokenId) + _elapsedBlocks);

    _setGaugeRewardGrowth(_tokenId, 0);
    uint256 _rewardGrowthGlobalX128 = pool.rewardGrowthGlobalX128();
    // @dev Mock earned's pool reads using the current global growth as the settled block state.
    _mockPoolBaseRewardGrowth(_rewardGrowthGlobalX128);
    _mockPoolRewardGrowthInside(_tokenId, _rewardGrowthGlobalX128, _rewardGrowthInside);

    assertEq(gauge.earned(users.alice, _ids(_tokenId)), _rewardAmount);

    // @dev Claimed rewards align with earned.
    _claimAndAssertBalance(users.alice, _tokenId, users.bob, _rewardGrowthInside, _rewardAmount);
  }

  function test_WhenThereIsAReferralShare()
    external
    whenCalculatingSelectedPositions
    whenCalculatingOnePosition
    whenThePositionIsStakedByTheAccount
    whenThePositionHasAccruedEmissions
  {
    uint256 _referralShare = gaugeFactory.DEFAULT_MAX_SHARE_CAP();
    vm.prank(users.owner);
    gaugeFactory.setReferralConfig(address(gauge), users.referral, _referralShare);

    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    // @dev 5% referral share applied to 100 reward tokens.
    uint128 _referralAmount = uint128(TOKEN_1 * 5);
    uint128 _expectedEarned = _rewardAmount - _referralAmount;
    // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens.
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);
    vm.stopPrank();

    _setGaugeRewardGrowth(_tokenId, 0);
    uint256 _rewardGrowthGlobalX128 = pool.rewardGrowthGlobalX128();
    // @dev Mock earned's pool reads using the current global growth as the settled block state.
    _mockPoolBaseRewardGrowth(_rewardGrowthGlobalX128);
    _mockPoolRewardGrowthInside(_tokenId, _rewardGrowthGlobalX128, _rewardGrowthInside);

    // it should return emissions after referral
    assertEq(gauge.earned(users.alice, _ids(_tokenId)), _expectedEarned);

    // @dev Claimed LP rewards align with earned and the referral amount is deferred.
    _claimAndAssertReferralDeferred(
      users.alice, _tokenId, users.bob, _rewardGrowthInside, _expectedEarned, _referralAmount
    );
  }

  modifier whenThereIsAPenaltyRateAndAReferralShare() {
    _;
  }

  function test_WhenTheVoterHasNoNewCumulativeRewardShare()
    external
    whenCalculatingSelectedPositions
    whenCalculatingOnePosition
    whenThePositionIsStakedByTheAccount
    whenThePositionHasAccruedEmissions
    whenThereIsAPenaltyRateAndAReferralShare
  {
    {
      uint256 _maxPips = gaugeFactory.MAX_PIPS();
      uint256 _referralShare = gaugeFactory.DEFAULT_MAX_SHARE_CAP();
      vm.startPrank(users.owner);
      // @dev Set 50% penalty rate and 5% referral share.
      gaugeFactory.setPenaltyConfig(10, _maxPips / 2);
      gaugeFactory.setReferralConfig(address(gauge), users.referral, _referralShare);
      vm.stopPrank();
    }

    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    // @dev 50% penalty fee applied to 100 reward tokens.
    uint128 _penaltyAmount = uint128(TOKEN_1 * 50);
    // @dev 5% referral share applied to the 50 reward tokens left after penalty.
    uint128 _referralAmount = uint128(TOKEN_1 * 5 / 2);
    uint128 _expectedEarned = _rewardAmount - _penaltyAmount - _referralAmount;
    uint256 _rewardGrowthInside;
    {
      (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
      // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens.
      _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);
    }

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);
    vm.stopPrank();

    _setGaugeRewardGrowth(_tokenId, 0);
    uint256 _rewardGrowthGlobalX128 = pool.rewardGrowthGlobalX128();
    // @dev Mock earned's pool reads using the current global growth as the settled block state.
    _mockPoolBaseRewardGrowth(_rewardGrowthGlobalX128);
    _mockPoolRewardGrowthInside(_tokenId, _rewardGrowthGlobalX128, _rewardGrowthInside);

    // it should apply the penalty before the referral
    // it should return emissions after penalty and referral
    assertEq(gauge.earned(users.alice, _ids(_tokenId)), _expectedEarned);

    // @dev Claimed LP rewards align with earned and the referral amount is deferred.
    _mockAndExpectForfeitEmissions(_penaltyAmount);
    _claimAndAssertReferralDeferred(
      users.alice, _tokenId, users.bob, _rewardGrowthInside, _expectedEarned, _referralAmount
    );
  }

  function test_WhenTheVoterHasANewCumulativeRewardShare()
    external
    whenCalculatingSelectedPositions
    whenCalculatingOnePosition
    whenThePositionIsStakedByTheAccount
    whenThePositionHasAccruedEmissions
    whenThereIsAPenaltyRateAndAReferralShare
  {
    uint256 _maxPips = gaugeFactory.MAX_PIPS();
    uint256 _referralShare = gaugeFactory.DEFAULT_MAX_SHARE_CAP();
    vm.startPrank(users.owner);
    // @dev Set 50% penalty rate and 5% referral share.
    gaugeFactory.setPenaltyConfig(10, _maxPips / 2);
    gaugeFactory.setReferralConfig(address(gauge), users.referral, _referralShare);
    vm.stopPrank();

    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    // @dev 50% penalty fee applied to 100 reward tokens.
    uint128 _penaltyAmount = uint128(TOKEN_1 * 50);
    // @dev 5% referral share applied to the 50 reward tokens left after penalty.
    uint128 _referralAmount = uint128(TOKEN_1 * 5 / 2);
    uint128 _expectedEarned = _rewardAmount - _penaltyAmount - _referralAmount;
    // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens.
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);
    vm.stopPrank();

    // @dev Gauge Reward Growth starts at zero, and is fully projected during `earned()`
    _setGaugeRewardGrowth(_tokenId, 0);
    uint256 _estimatedRewardGrowthGlobalX128;
    {
      // @dev Mirror earned's in-memory reward growth advance with the voter's projected reward share delta.
      uint128 _stakedLiquidity = pool.stakedLiquidity();
      // @dev Convert the projected rewards into the growth value used to read the position's accrued emissions.
      _estimatedRewardGrowthGlobalX128 = FullMath.mulDiv(uint256(_rewardAmount), Q128, _stakedLiquidity);

      // @dev Return a stale global growth so earned advances it with the voter's projected reward share.
      _mockAndExpect({
        _receiver: address(pool),
        _calldata: abi.encodeWithSignature('rewardGrowthGlobalX128()'),
        _returned: abi.encode(0)
      });
      _mockAndExpect({
        _receiver: address(pool),
        _calldata: abi.encodeWithSignature('stakedLiquidity()'),
        _returned: abi.encode(_stakedLiquidity)
      });
      // @dev Project a cumulative reward share delta worth `_rewardAmount` since the gauge's cursor.
      _mockAndExpect({
        _receiver: address(voter),
        _calldata: abi.encodeWithSignature('projectedCumulativeRewardShare(address)', address(gauge)),
        _returned: abi.encode(uint256(_rewardAmount))
      });
    }

    // it should include the projected reward share
    _mockPoolRewardGrowthInside(_tokenId, _estimatedRewardGrowthGlobalX128, _rewardGrowthInside);
    // it should apply the penalty before the referral
    // it should return emissions after penalty and referral
    assertEq(gauge.earned(users.alice, _ids(_tokenId)), _expectedEarned);

    // @dev Claimed LP rewards align with earned and the referral amount is deferred.
    _mockAndExpectForfeitEmissions(_penaltyAmount);
    _claimAndAssertReferralDeferred(
      users.alice, _tokenId, users.bob, _rewardGrowthInside, _expectedEarned, _referralAmount
    );
  }

  function test_WhenTheVoterProjectsALowerCumulativeRewardShare()
    external
    whenCalculatingSelectedPositions
    whenCalculatingOnePosition
    whenThePositionIsStakedByTheAccount
  {
    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens.
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);
    vm.stopPrank();

    // @dev Advance the gauge's cursor past the projection the voter will report
    _mockAndExpect({
      _receiver: address(voter),
      _calldata: abi.encodeWithSignature('settleGauge(address)', address(gauge)),
      _returned: abi.encode(uint256(_rewardAmount))
    });
    vm.prank(address(pool));
    gauge.settleGauge();

    _setGaugeRewardGrowth(_tokenId, 0);
    uint256 _rewardGrowthGlobalX128 = pool.rewardGrowthGlobalX128();
    // @dev Mock earned's pool reads using the current global growth as the settled block state.
    _mockPoolBaseRewardGrowth(_rewardGrowthGlobalX128);
    _mockPoolRewardGrowthInside(_tokenId, _rewardGrowthGlobalX128, _rewardGrowthInside);
    // @dev Project a cumulative reward share below the gauge's cursor (e.g. a deregistered gauge reporting 0)
    _mockAndExpect({
      _receiver: address(voter),
      _calldata: abi.encodeWithSignature('projectedCumulativeRewardShare(address)', address(gauge)),
      _returned: abi.encode(uint256(_rewardAmount) - 1)
    });

    // it should ignore the regressed projection
    assertEq(gauge.earned(users.alice, _ids(_tokenId)), _rewardAmount);
  }

  function test_WhenThePoolHasNoStakedLiquidity()
    external
    whenCalculatingSelectedPositions
    whenCalculatingOnePosition
    whenThePositionIsStakedByTheAccount
  {
    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    // @dev Advance rewardGrowthInside to simulate settled accrual of 100 tokens.
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);
    vm.stopPrank();

    _setGaugeRewardGrowth(_tokenId, 0);
    uint256 _rewardGrowthGlobalX128 = pool.rewardGrowthGlobalX128();
    _mockAndExpect({
      _receiver: address(pool),
      _calldata: abi.encodeWithSignature('rewardGrowthGlobalX128()'),
      _returned: abi.encode(_rewardGrowthGlobalX128)
    });
    // @dev Report zero staked liquidity so earned skips the voter projection.
    _mockAndExpect({
      _receiver: address(pool),
      _calldata: abi.encodeWithSignature('stakedLiquidity()'),
      _returned: abi.encode(uint128(0))
    });
    // @dev A nonzero projected share is available but must not be consumed — dividing by
    //      zero staked liquidity would revert if the skip were removed.
    vm.mockCall(
      address(voter),
      abi.encodeWithSignature('projectedCumulativeRewardShare(address)', address(gauge)),
      abi.encode(uint256(_rewardAmount))
    );
    _mockPoolRewardGrowthInside(_tokenId, _rewardGrowthGlobalX128, _rewardGrowthInside);

    // it should return settled emissions without projecting the reward share
    assertEq(gauge.earned(users.alice, _ids(_tokenId)), _rewardAmount);
  }

  function test_WhenCalculatingMultipleSelectedPositions() external whenCalculatingSelectedPositions {
    vm.startPrank(users.owner);
    // @dev Set 50% penalty rate and 5% referral share.
    gaugeFactory.setPenaltyConfig(10, gaugeFactory.MAX_PIPS() / 2);
    gaugeFactory.setReferralConfig(address(gauge), users.referral, gaugeFactory.DEFAULT_MAX_SHARE_CAP());
    vm.stopPrank();

    uint256 _tokenId1 = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    uint256 _tokenId2 = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    uint256 _tokenId3 = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId1);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    // @dev 50% penalty fee applied to 100 reward tokens.
    uint128 _penaltyAmount = uint128(TOKEN_1 * 50);
    // @dev 5% referral share applied to the 50 reward tokens left after penalty.
    uint128 _referralAmount = uint128(TOKEN_1 * 5 / 2);
    uint128 _expectedEarned = _rewardAmount - _penaltyAmount - _referralAmount;
    uint256 _deferredAmount = TOKEN_1 * 25;
    // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens per selected position.
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId1);
    nft.approve(address(gauge), _tokenId2);
    nft.approve(address(gauge), _tokenId3);
    gauge.deposit(_tokenId1);
    gauge.deposit(_tokenId2);
    gauge.deposit(_tokenId3);
    vm.stopPrank();

    _setDeferredEmissions(users.alice, _deferredAmount);

    _setGaugeRewardGrowth(_tokenId1, 0);
    _setGaugeRewardGrowth(_tokenId3, 0);
    uint256 _rewardGrowthGlobalX128 = pool.rewardGrowthGlobalX128();
    // @dev Mock earned's pool reads using the current global growth as the settled block state.
    _mockPoolBaseRewardGrowth(_rewardGrowthGlobalX128);
    _mockPoolRewardGrowthInside(_tokenId1, _rewardGrowthGlobalX128, _rewardGrowthInside);
    _mockPoolRewardGrowthInside(_tokenId3, _rewardGrowthGlobalX128, _rewardGrowthInside);

    // @dev Only calculate live position rewards for `_tokenId1` and `_tokenId3`.
    uint256[] memory _tokenIds = new uint256[](2);
    _tokenIds[0] = _tokenId1;
    _tokenIds[1] = _tokenId3;

    // it should return selected and deferred LP emissions
    assertEq(gauge.earned(users.alice, _tokenIds), uint256(_expectedEarned) * 2 + _deferredAmount);
  }

  modifier whenCalculatingAllStakedPositions() {
    _;
  }

  function test_WhenTheAccountHasNoStakedPositionsOrDeferredEmissions()
    external
    view
    whenCalculatingSelectedPositions
    whenCalculatingAllStakedPositions
  {
    // it should return zero
    assertEq(gauge.earned(users.alice), 0);
  }

  function test_WhenTheAccountHasMultipleStakedPositions()
    external
    whenCalculatingSelectedPositions
    whenCalculatingAllStakedPositions
  {
    vm.startPrank(users.owner);
    // @dev Set 50% penalty rate and 5% referral share.
    gaugeFactory.setPenaltyConfig(10, gaugeFactory.MAX_PIPS() / 2);
    gaugeFactory.setReferralConfig(address(gauge), users.referral, gaugeFactory.DEFAULT_MAX_SHARE_CAP());
    vm.stopPrank();

    uint256 _tokenId1 = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    uint256 _tokenId2 = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    uint256 _tokenId3 = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId1);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    // @dev 50% penalty fee applied to 100 reward tokens.
    uint128 _penaltyAmount = uint128(TOKEN_1 * 50);
    // @dev 5% referral share applied to the 50 reward tokens left after penalty.
    uint128 _referralAmount = uint128(TOKEN_1 * 5 / 2);
    uint128 _expectedEarned = _rewardAmount - _penaltyAmount - _referralAmount;
    uint256 _deferredLpAmount = TOKEN_1 * 95;
    // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens per staked position.
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId1);
    nft.approve(address(gauge), _tokenId2);
    nft.approve(address(gauge), _tokenId3);
    gauge.deposit(_tokenId1);
    gauge.deposit(_tokenId2);
    gauge.deposit(_tokenId3);
    vm.stopPrank();

    _setDeferredEmissions(users.alice, _deferredLpAmount);

    _setGaugeRewardGrowth(_tokenId1, 0);
    _setGaugeRewardGrowth(_tokenId2, 0);
    _setGaugeRewardGrowth(_tokenId3, 0);
    uint256 _rewardGrowthGlobalX128 = pool.rewardGrowthGlobalX128();
    // @dev Mock earned's pool reads using the current global growth as the settled block state.
    _mockPoolBaseRewardGrowth(_rewardGrowthGlobalX128);
    _mockPoolRewardGrowthInside(_tokenId1, _rewardGrowthGlobalX128, _rewardGrowthInside);
    _mockPoolRewardGrowthInside(_tokenId2, _rewardGrowthGlobalX128, _rewardGrowthInside);
    _mockPoolRewardGrowthInside(_tokenId3, _rewardGrowthGlobalX128, _rewardGrowthInside);

    // it should return live and deferred LP emissions
    // it should apply the early withdrawal penalty only to live emissions
    assertEq(gauge.earned(users.alice), uint256(_expectedEarned) * 3 + _deferredLpAmount);
  }

  function _setDeferredEmissions(address _account, uint256 _amount) internal {
    stdstore.target(address(gauge)).sig(gauge.deferredEmissions.selector).with_key(_account).checked_write(_amount);
  }

  // @dev Writes the position's reward growth checkpoint in the gauge.
  function _setGaugeRewardGrowth(uint256 _tokenId, uint256 _rewardGrowthInside) internal {
    stdstore.target(address(gauge)).sig(gauge.rewardGrowthInside.selector).with_key(_tokenId)
      .checked_write(_rewardGrowthInside);
  }

  // @dev Mocks the pool base reads while keeping staked liquidity nonzero.
  function _mockPoolBaseRewardGrowth(uint256 _rewardGrowthGlobalX128) internal {
    uint128 _stakedLiquidity = pool.stakedLiquidity();

    _mockAndExpect({
      _receiver: address(pool),
      _calldata: abi.encodeWithSignature('rewardGrowthGlobalX128()'),
      _returned: abi.encode(_rewardGrowthGlobalX128)
    });
    _mockAndExpect({
      _receiver: address(pool),
      _calldata: abi.encodeWithSignature('stakedLiquidity()'),
      _returned: abi.encode(_stakedLiquidity)
    });
  }

  // @dev Mocks and expects the pool reward growth read for a position.
  function _mockPoolRewardGrowthInside(
    uint256 _tokenId,
    uint256 _rewardGrowthGlobalX128,
    uint256 _rewardGrowthInside
  ) internal {
    (,,,,, int24 _tickLower, int24 _tickUpper,,,,,) = nft.positions(_tokenId);

    _mockAndExpect({
      _receiver: address(pool),
      _calldata: abi.encodeWithSignature(
        'getRewardGrowthInside(int24,int24,uint256)', _tickLower, _tickUpper, _rewardGrowthGlobalX128
      ),
      _returned: abi.encode(_rewardGrowthInside)
    });
  }

  // @dev Claims emissions after mocking the same settled in-range growth used by earned.
  function _claimAndAssertBalance(
    address _account,
    uint256 _tokenId,
    address _recipient,
    uint256 _rewardGrowthInside,
    uint128 _rewardAmount
  ) internal {
    _mockPoolRewardGrowthInside(_tokenId, 0, _rewardGrowthInside);
    uint256 _recipientBalanceBefore = receiptToken.balanceOf(_recipient);

    address[] memory _recipients = new address[](1);
    _recipients[0] = _recipient;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _rewardAmount;
    bytes memory _calldata = abi.encodeWithSignature('mintEmissions(address[],uint128[])', _recipients, _amounts);
    vm.expectCall(address(receiptToken), abi.encodeWithSignature('mint(address,uint256)', _recipient, _rewardAmount));
    vm.mockFunction(address(voter), address(mockLeafVoter), _calldata);

    vm.prank(_account);
    gauge.claimEmissions(_account, _recipient, _ids(_tokenId));

    assertEq(receiptToken.balanceOf(_recipient), _recipientBalanceBefore + _rewardAmount);
  }

  // @dev Claims LP emissions and checks that the referral amount is deferred.
  function _claimAndAssertReferralDeferred(
    address _account,
    uint256 _tokenId,
    address _recipient,
    uint256 _rewardGrowthInside,
    uint128 _rewardAmount,
    uint128 _referralAmount
  ) internal {
    _mockPoolRewardGrowthInside(_tokenId, 0, _rewardGrowthInside);
    uint256 _recipientBalanceBefore = receiptToken.balanceOf(_recipient);
    uint256 _deferredReferralAmountBefore = gauge.deferredReferralEmissions(users.referral);

    address[] memory _recipients = new address[](1);
    _recipients[0] = _recipient;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _rewardAmount;
    bytes memory _calldata = abi.encodeWithSignature('mintEmissions(address[],uint128[])', _recipients, _amounts);
    vm.expectCall(address(receiptToken), abi.encodeWithSignature('mint(address,uint256)', _recipient, _rewardAmount));
    vm.mockFunction(address(voter), address(mockLeafVoter), _calldata);

    vm.prank(_account);
    gauge.claimEmissions(_account, _recipient, _ids(_tokenId));

    assertEq(receiptToken.balanceOf(_recipient), _recipientBalanceBefore + _rewardAmount);
    assertEq(gauge.deferredReferralEmissions(users.referral), _deferredReferralAmountBefore + _referralAmount);
  }

  // @dev Mocks and expects emission forfeiture through the voter.
  function _mockAndExpectForfeitEmissions(uint128 _amount) internal {
    _mockAndExpect({
      _receiver: address(voter), _calldata: abi.encodeWithSignature('forfeitEmissions(uint128)', _amount), _returned: ''
    });
  }

  // @dev Mocks a call and expects it to be made.
  function _mockAndExpect(address _receiver, bytes memory _calldata, bytes memory _returned) internal {
    vm.mockCall(_receiver, _calldata, _returned);
    vm.expectCall(_receiver, _calldata);
  }
}
