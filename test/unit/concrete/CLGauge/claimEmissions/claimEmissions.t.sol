pragma solidity ^0.7.6;
pragma abicoder v2;

import {FullMath} from 'contracts/core/libraries/FullMath.sol';

import {TestERC20} from 'contracts/periphery/test/TestERC20.sol';
import {MockLeafVoter} from 'contracts/test/MockLeafVoter.sol';

import '../CLGauge.t.sol';

contract UnitCLGaugeClaimEmissions is CLGaugeTest {
  using stdStorage for StdStorage;

  TestERC20 public receiptToken;
  MockLeafVoter public mockLeafVoter;

  function setUp() public override {
    super.setUp();

    receiptToken = new TestERC20(0);
    mockLeafVoter = new MockLeafVoter(receiptToken);
  }

  function test_WhenTheCallerIsNotTheAccountOrAnApprovedOperator(address _caller) external {
    vm.assume(_caller != address(0) && _caller != users.alice);

    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,, int24 _tickLower, int24 _tickUpper, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);
    gauge.setApprovalForAll(_caller, true);
    vm.stopPrank();

    _setGaugeRewardGrowth(_tokenId, 0);
    // @dev Mock live emissions without expecting the read because authorization reverts first
    vm.mockCall(
      address(pool),
      abi.encodeWithSignature('getRewardGrowthInside(int24,int24,uint256)', _tickLower, _tickUpper, uint256(0)),
      abi.encode(_rewardGrowthInside)
    );
    _setDeferredEmissions(users.alice, _rewardAmount);

    vm.startPrank(_caller);
    // it should revert with NA
    vm.expectRevert(abi.encodePacked('NA'));
    gauge.claimEmissions(users.alice, users.bob, _ids(_tokenId));
    vm.expectRevert(abi.encodePacked('NA'));
    gauge.claimEmissions(users.alice, users.bob);
    vm.stopPrank();
  }

  modifier whenTheCallerIsAuthorized() {
    _;
  }

  modifier whenTheCallerIsTheAccount() {
    _;
  }

  modifier whenClaimingNoPositions() {
    _;
  }

  function test_WhenTheAccountHasNoDeferredEmissions(
    address _account,
    address _recipient
  ) external whenTheCallerIsAuthorized whenTheCallerIsTheAccount whenClaimingNoPositions {
    vm.assume(_account != address(0));
    vm.assume(_recipient != address(0));

    vm.prank(_account);
    // it should revert with NS
    vm.expectRevert(abi.encodePacked('NS'));
    gauge.claimEmissions(_account, _recipient, new uint256[](0));
  }

  function test_WhenTheAccountHasOnlyDeferredLPEmissions()
    external
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenClaimingNoPositions
  {
    uint128 _deferredAmount = uint128(TOKEN_1 * 100);
    _setDeferredEmissions(users.alice, _deferredAmount);

    // it should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _deferredAmount;
    _mockAndExpectMintEmissions(_recipients, _amounts);

    // it should emit DeferredEmissionsClaimed
    vm.expectEmit(true, true, false, true, address(gauge));
    emit DeferredEmissionsClaimed(users.alice, users.bob, _deferredAmount);
    vm.prank(users.alice);
    gauge.claimEmissions(users.alice, users.bob, new uint256[](0));

    // it should clear the deferred LP emissions
    assertEq(gauge.deferredEmissions(users.alice), 0);
    // it should mint the full deferred balance to the recipient
    assertEq(receiptToken.balanceOf(users.bob), _deferredAmount);
  }

  modifier whenClaimingOnePosition() {
    _;
  }

  function test_WhenTheTokenIdIsNotStakedByTheAccount(
    address _account,
    address _recipient
  ) external whenTheCallerIsAuthorized whenTheCallerIsTheAccount whenClaimingOnePosition {
    vm.assume(_account != address(0));
    vm.assume(_account != users.alice);

    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);
    vm.stopPrank();

    vm.prank(_account);
    // it should revert with NA
    vm.expectRevert(abi.encodePacked('NA'));
    gauge.claimEmissions(_account, _recipient, _ids(_tokenId));
  }

  modifier whenThePositionIsStakedByTheAccount() {
    _;
  }

  function test_WhenTheRecipientIsTheZeroAddress()
    external
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenClaimingOnePosition
    whenThePositionIsStakedByTheAccount
  {
    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);

    // it should revert with ZA
    vm.expectRevert(abi.encodePacked('ZA'));
    gauge.claimEmissions(users.alice, address(0), _ids(_tokenId));
  }

  function test_WhenThePositionHasNoAccruedEmissions(uint256 _rewardGrowthInside)
    external
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenClaimingOnePosition
    whenThePositionIsStakedByTheAccount
  {
    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);

    // @dev Set the same `_rewardGrowthInside` in gauge and pool to simulate no accrued emissions
    _setGaugeRewardGrowth(_tokenId, _rewardGrowthInside);
    _mockPoolRewardGrowth(_tokenId, _rewardGrowthInside);
    // it should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // it should not forfeit emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('forfeitEmissions(uint128)'), 0);
    // it should not mint emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('mintEmissions(address[],uint128[])'), 0);

    gauge.claimEmissions(users.alice, users.bob, _ids(_tokenId));

    // it should advance the position reward growth
    assertEq(gauge.rewardGrowthInside(_tokenId), _rewardGrowthInside);
    // @dev Bob's balance remains unchanged because no emissions were minted
    assertEq(receiptToken.balanceOf(users.bob), 0);
  }

  modifier whenThePositionHasAccruedEmissions() {
    _;
  }

  modifier whenThereIsNoPenaltyAndNoReferral() {
    _;
  }

  function test_WhenTheRewardGrowthIsKnown()
    external
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenClaimingOnePosition
    whenThePositionIsStakedByTheAccount
    whenThePositionHasAccruedEmissions
    whenThereIsNoPenaltyAndNoReferral
  {
    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);

    _setGaugeRewardGrowth(_tokenId, 0);
    _mockPoolRewardGrowth(_tokenId, _rewardGrowthInside);
    // it should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // it should not forfeit emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('forfeitEmissions(uint128)'), 0);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _rewardAmount;
    _mockAndExpectMintEmissions(_recipients, _amounts);

    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit EmissionsClaimed(users.alice, _tokenId, users.bob, _rewardAmount);

    gauge.claimEmissions(users.alice, users.bob, _ids(_tokenId));

    // it should advance the position reward growth
    assertEq(gauge.rewardGrowthInside(_tokenId), _rewardGrowthInside);
    // it should mint full emissions to the recipient
    assertEq(receiptToken.balanceOf(users.bob), _rewardAmount);
  }

  function test_WhenTheRewardGrowthVaries(
    uint256 _rewardGrowthBefore,
    uint256 _rewardGrowthAfter
  )
    external
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenClaimingOnePosition
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

    _setGaugeRewardGrowth(_tokenId, _rewardGrowthBefore);
    _mockPoolRewardGrowth(_tokenId, _rewardGrowthAfter);
    // it should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // it should not forfeit emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('forfeitEmissions(uint128)'), 0);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);

    // @dev Estimate accrued rewards based on reward growth delta
    uint256 _rewardGrowthDelta = _rewardGrowthAfter - _rewardGrowthBefore;
    uint128 _rewardAmount = uint128(FullMath.mulDiv(_rewardGrowthDelta, _liquidity, Q128));
    _amounts[0] = _rewardAmount;
    _mockAndExpectMintEmissions(_recipients, _amounts);

    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit EmissionsClaimed(users.alice, _tokenId, users.bob, _rewardAmount);

    gauge.claimEmissions(users.alice, users.bob, _ids(_tokenId));

    // it should advance the position reward growth
    assertEq(gauge.rewardGrowthInside(_tokenId), _rewardGrowthAfter);
    // it should mint full emissions to the recipient
    assertEq(receiptToken.balanceOf(users.bob), _rewardAmount);
  }

  modifier whenThereIsAPenaltyRate() {
    vm.prank(users.owner);
    gaugeFactory.setPenaltyConfig(10, 1);
    _;
  }

  modifier whenCalledWithinMinStakeBlocks() {
    _;
  }

  function test_WhenPenaltyRoundsDownToZero()
    external
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenClaimingOnePosition
    whenThePositionIsStakedByTheAccount
    whenThePositionHasAccruedEmissions
    whenThereIsAPenaltyRate
    whenCalledWithinMinStakeBlocks
  {
    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint128 _rewardAmount = 1;
    // @dev Advance rewardGrowthInside to simulate accrual of 1 wei
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);

    _setGaugeRewardGrowth(_tokenId, 0);
    _mockPoolRewardGrowth(_tokenId, _rewardGrowthInside);
    // it should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // it should not forfeit emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('forfeitEmissions(uint128)'), 0);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _rewardAmount;
    _mockAndExpectMintEmissions(_recipients, _amounts);

    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit EmissionsClaimed(users.alice, _tokenId, users.bob, _rewardAmount);

    gauge.claimEmissions(users.alice, users.bob, _ids(_tokenId));

    // it should advance the position reward growth
    assertEq(gauge.rewardGrowthInside(_tokenId), _rewardGrowthInside);
    // it should mint full emissions to the recipient
    assertEq(receiptToken.balanceOf(users.bob), _rewardAmount);
  }

  modifier whenPenaltyDoesNotRoundDownToZero() {
    _;
  }

  modifier whenThereAreNoRemainingEmissionsAfterPenalty() {
    _;
  }

  function test_WhenThereIsNoReferral()
    external
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenClaimingOnePosition
    whenThePositionIsStakedByTheAccount
    whenThePositionHasAccruedEmissions
    whenThereIsAPenaltyRate
    whenCalledWithinMinStakeBlocks
    whenPenaltyDoesNotRoundDownToZero
    whenThereAreNoRemainingEmissionsAfterPenalty
  {
    uint256 _maxPips = gaugeFactory.MAX_PIPS();
    vm.prank(users.owner);
    // @dev Set 100% penalty rate
    gaugeFactory.setPenaltyConfig(10, _maxPips);

    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);

    _setGaugeRewardGrowth(_tokenId, 0);
    _mockPoolRewardGrowth(_tokenId, _rewardGrowthInside);
    // it should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // it should forfeit all emissions
    _mockAndExpectForfeitEmissions(_rewardAmount);
    // it should not mint emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('mintEmissions(address[],uint128[])'), 0);

    // it should emit the EarlyWithdrawPenalty event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit EarlyWithdrawPenalty(users.alice, _tokenId, _rewardAmount);

    gauge.claimEmissions(users.alice, users.bob, _ids(_tokenId));

    // it should advance the position reward growth
    assertEq(gauge.rewardGrowthInside(_tokenId), _rewardGrowthInside);
    // @dev Bob's balance remains unchanged because no emissions were minted.
    assertEq(receiptToken.balanceOf(users.bob), 0);
  }

  function test_WhenThereIsAReferralConfig()
    external
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenClaimingOnePosition
    whenThePositionIsStakedByTheAccount
    whenThePositionHasAccruedEmissions
    whenThereIsAPenaltyRate
    whenCalledWithinMinStakeBlocks
    whenPenaltyDoesNotRoundDownToZero
    whenThereAreNoRemainingEmissionsAfterPenalty
  {
    uint256 _maxPips = gaugeFactory.MAX_PIPS();
    vm.startPrank(users.owner);
    // @dev Set 100% penalty rate and 50% referral share
    gaugeFactory.setPenaltyConfig(10, _maxPips);
    gaugeFactory.setMaxShareCap(_maxPips / 2);
    gaugeFactory.setReferralConfig(address(gauge), users.referral, _maxPips / 2);
    vm.stopPrank();

    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);

    _setGaugeRewardGrowth(_tokenId, 0);
    _mockPoolRewardGrowth(_tokenId, _rewardGrowthInside);
    // it should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // it should forfeit all emissions
    _mockAndExpectForfeitEmissions(_rewardAmount);
    // it should not mint emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('mintEmissions(address[],uint128[])'), 0);

    // it should emit the EarlyWithdrawPenalty event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit EarlyWithdrawPenalty(users.alice, _tokenId, _rewardAmount);

    gauge.claimEmissions(users.alice, users.bob, _ids(_tokenId));

    // it should advance the position reward growth
    assertEq(gauge.rewardGrowthInside(_tokenId), _rewardGrowthInside);
    // @dev Recipient balances remain unchanged because the full emissions amount was forfeited
    assertEq(receiptToken.balanceOf(users.bob), 0);
    assertEq(receiptToken.balanceOf(users.referral), 0);
  }

  function test_WhenThereAreRemainingEmissionsAfterPenalty(uint256 _elapsedBlocks)
    external
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenClaimingOnePosition
    whenThePositionIsStakedByTheAccount
    whenThePositionHasAccruedEmissions
    whenThereIsAPenaltyRate
    whenCalledWithinMinStakeBlocks
    whenPenaltyDoesNotRoundDownToZero
  {
    uint256 _maxPips = gaugeFactory.MAX_PIPS();
    uint256 _minStakeBlocks = 10;
    vm.prank(users.owner);
    // @dev Set 50% penalty rate
    gaugeFactory.setPenaltyConfig(_minStakeBlocks, _maxPips / 2);

    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    uint128 _penaltyAmount = _rewardAmount / 2;
    uint128 _remainingAmount = _rewardAmount - _penaltyAmount;

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);

    _elapsedBlocks = bound(_elapsedBlocks, 0, _minStakeBlocks - 1);
    vm.roll(gauge.depositBlock(_tokenId) + _elapsedBlocks);

    _setGaugeRewardGrowth(_tokenId, 0);
    _mockPoolRewardGrowth(_tokenId, _rewardGrowthInside);
    // it should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // it should forfeit the penalty emissions
    _mockAndExpectForfeitEmissions(_penaltyAmount);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _remainingAmount;
    _mockAndExpectMintEmissions(_recipients, _amounts);

    // it should emit the EarlyWithdrawPenalty event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit EarlyWithdrawPenalty(users.alice, _tokenId, _penaltyAmount);
    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit EmissionsClaimed(users.alice, _tokenId, users.bob, _remainingAmount);

    gauge.claimEmissions(users.alice, users.bob, _ids(_tokenId));

    // it should advance the position reward growth
    assertEq(gauge.rewardGrowthInside(_tokenId), _rewardGrowthInside);
    // it should mint the remaining emissions to the recipient
    assertEq(receiptToken.balanceOf(users.bob), _remainingAmount);
  }

  function test_WhenCalledAfterMinStakeBlocks(uint256 _elapsedBlocks)
    external
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenClaimingOnePosition
    whenThePositionIsStakedByTheAccount
    whenThePositionHasAccruedEmissions
    whenThereIsAPenaltyRate
  {
    uint256 _maxPips = gaugeFactory.MAX_PIPS();
    uint256 _minStakeBlocks = 10;
    vm.prank(users.owner);
    // @dev Set 50% penalty rate
    gaugeFactory.setPenaltyConfig(_minStakeBlocks, _maxPips / 2);

    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);

    _elapsedBlocks = bound(_elapsedBlocks, _minStakeBlocks, _minStakeBlocks * 100);
    vm.roll(gauge.depositBlock(_tokenId) + _elapsedBlocks);

    _setGaugeRewardGrowth(_tokenId, 0);
    _mockPoolRewardGrowth(_tokenId, _rewardGrowthInside);
    // it should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // it should not forfeit emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('forfeitEmissions(uint128)'), 0);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _rewardAmount;
    _mockAndExpectMintEmissions(_recipients, _amounts);

    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit EmissionsClaimed(users.alice, _tokenId, users.bob, _rewardAmount);

    gauge.claimEmissions(users.alice, users.bob, _ids(_tokenId));

    // it should advance the position reward growth
    assertEq(gauge.rewardGrowthInside(_tokenId), _rewardGrowthInside);
    // it should mint full emissions to the recipient
    assertEq(receiptToken.balanceOf(users.bob), _rewardAmount);
  }

  modifier whenThereIsAReferralShare() {
    _;
  }

  function test_WhenReferralShareRoundsDownToZero()
    external
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenClaimingOnePosition
    whenThePositionIsStakedByTheAccount
    whenThePositionHasAccruedEmissions
    whenThereIsAReferralShare
  {
    // @dev Simulate 5% referral share
    uint256 _referralShare = gaugeFactory.DEFAULT_MAX_SHARE_CAP();
    vm.prank(users.owner);
    gaugeFactory.setReferralConfig(address(gauge), users.referral, _referralShare);

    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint128 _rewardAmount = 1;
    // @dev Advance rewardGrowthInside to simulate accrual of 1 wei
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);

    _setGaugeRewardGrowth(_tokenId, 0);
    _mockPoolRewardGrowth(_tokenId, _rewardGrowthInside);
    // it should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // it should not forfeit emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('forfeitEmissions(uint128)'), 0);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _rewardAmount;
    _mockAndExpectMintEmissions(_recipients, _amounts);

    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit EmissionsClaimed(users.alice, _tokenId, users.bob, _rewardAmount);

    gauge.claimEmissions(users.alice, users.bob, _ids(_tokenId));

    // it should advance the position reward growth
    assertEq(gauge.rewardGrowthInside(_tokenId), _rewardGrowthInside);
    // it should mint full emissions to the recipient
    assertEq(receiptToken.balanceOf(users.bob), _rewardAmount);
    // @dev Referral balance remains unchanged because the referral amount rounded down to zero
    assertEq(receiptToken.balanceOf(users.referral), 0);
  }

  function test_WhenReferralShareDoesNotRoundDownToZero()
    external
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenClaimingOnePosition
    whenThePositionIsStakedByTheAccount
    whenThePositionHasAccruedEmissions
    whenThereIsAReferralShare
  {
    // @dev Simulate 5% referral share
    uint256 _referralShare = gaugeFactory.DEFAULT_MAX_SHARE_CAP();
    vm.prank(users.owner);
    gaugeFactory.setReferralConfig(address(gauge), users.referral, _referralShare);

    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    // @dev 5% referral share applied to 100 reward tokens
    uint128 _referralAmount = uint128(TOKEN_1 * 5);
    uint128 _lpAmount = _rewardAmount - _referralAmount;
    // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);

    _setGaugeRewardGrowth(_tokenId, 0);
    _mockPoolRewardGrowth(_tokenId, _rewardGrowthInside);
    // it should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // it should not forfeit emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('forfeitEmissions(uint128)'), 0);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _lpAmount;
    // it should apply the penalty before the referral
    // @dev Referral amount is 5% of the post-penalty emissions
    _mockAndExpectMintEmissions(_recipients, _amounts);

    // it should emit the ReferralEmissionsDeferred event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit ReferralEmissionsDeferred(users.alice, _tokenId, users.referral, _referralAmount);
    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit EmissionsClaimed(users.alice, _tokenId, users.bob, _lpAmount);

    gauge.claimEmissions(users.alice, users.bob, _ids(_tokenId));

    // it should advance the position reward growth
    assertEq(gauge.rewardGrowthInside(_tokenId), _rewardGrowthInside);
    // it should mint LP emissions to the recipient
    assertEq(receiptToken.balanceOf(users.bob), _lpAmount);
    // it should store the referral emissions on the referral
    assertEq(gauge.deferredReferralEmissions(users.referral), _referralAmount);
  }

  modifier whenThereIsAPenaltyRateAndAReferralShare() {
    _;
  }

  function test_WhenThePenaltyRateAndReferralShareAreKnown()
    external
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenClaimingOnePosition
    whenThePositionIsStakedByTheAccount
    whenThePositionHasAccruedEmissions
    whenThereIsAPenaltyRateAndAReferralShare
  {
    uint256 _maxPips = gaugeFactory.MAX_PIPS();
    uint256 _referralShare = gaugeFactory.DEFAULT_MAX_SHARE_CAP();
    vm.startPrank(users.owner);
    // @dev Set 50% penalty rate and 5% referral share
    gaugeFactory.setPenaltyConfig(10, _maxPips / 2);
    gaugeFactory.setReferralConfig(address(gauge), users.referral, _referralShare);
    vm.stopPrank();

    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    // @dev 50% penalty fee applied to 100 reward tokens
    uint128 _penaltyAmount = uint128(TOKEN_1 * 50);
    // @dev 5% referral share applied to the 50 reward tokens left after penalty
    uint128 _referralAmount = uint128(TOKEN_1 * 5 / 2);
    uint128 _lpAmount = _rewardAmount - _penaltyAmount - _referralAmount;
    // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);

    _setGaugeRewardGrowth(_tokenId, 0);
    _mockPoolRewardGrowth(_tokenId, _rewardGrowthInside);
    // it should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // it should forfeit the penalty emissions
    _mockAndExpectForfeitEmissions(_penaltyAmount);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _lpAmount;
    _mockAndExpectMintEmissions(_recipients, _amounts);

    // it should emit the EarlyWithdrawPenalty event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit EarlyWithdrawPenalty(users.alice, _tokenId, _penaltyAmount);
    // it should emit the ReferralEmissionsDeferred event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit ReferralEmissionsDeferred(users.alice, _tokenId, users.referral, _referralAmount);
    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit EmissionsClaimed(users.alice, _tokenId, users.bob, _lpAmount);

    gauge.claimEmissions(users.alice, users.bob, _ids(_tokenId));

    // it should advance the position reward growth
    assertEq(gauge.rewardGrowthInside(_tokenId), _rewardGrowthInside);
    // it should mint LP emissions to the recipient
    assertEq(receiptToken.balanceOf(users.bob), _lpAmount);
    // it should store the referral emissions on the referral
    assertEq(gauge.deferredReferralEmissions(users.referral), _referralAmount);
  }

  function test_WhenThePenaltyRateAndReferralShareVary(
    uint128 _rewardAmount,
    uint256 _penaltyRate,
    uint256 _referralShare
  )
    external
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenClaimingOnePosition
    whenThePositionIsStakedByTheAccount
    whenThePositionHasAccruedEmissions
    whenThereIsAPenaltyRateAndAReferralShare
  {
    uint256 _maxPips = gaugeFactory.MAX_PIPS();
    _rewardAmount = uint128(bound(uint256(_rewardAmount), TOKEN_1, TOKEN_1 * 1_000_000));
    _penaltyRate = bound(_penaltyRate, 1, _maxPips - 1);
    _referralShare = bound(_referralShare, 1, gaugeFactory.DEFAULT_MAX_SHARE_CAP());

    vm.startPrank(users.owner);
    gaugeFactory.setPenaltyConfig(10, _penaltyRate);
    gaugeFactory.setReferralConfig(address(gauge), users.referral, _referralShare);
    vm.stopPrank();

    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    uint256 _rewardGrowthInside;
    uint128 _accruedAmount;
    {
      (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
      _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);
      _accruedAmount = uint128(FullMath.mulDiv(_rewardGrowthInside, _liquidity, Q128));
    }

    uint128 _penaltyAmount = uint128(uint256(_accruedAmount) * _penaltyRate / _maxPips);
    // it should apply the penalty before the referral
    uint128 _referralAmount = uint128((uint256(_accruedAmount) - _penaltyAmount) * _referralShare / _maxPips);
    uint128 _lpAmount = _accruedAmount - _penaltyAmount - _referralAmount;

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);

    _setGaugeRewardGrowth(_tokenId, 0);
    _mockPoolRewardGrowth(_tokenId, _rewardGrowthInside);
    // it should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // it should forfeit the penalty emissions
    _mockAndExpectForfeitEmissions(_penaltyAmount);

    {
      address[] memory _recipients = new address[](1);
      _recipients[0] = users.bob;
      uint128[] memory _amounts = new uint128[](1);
      _amounts[0] = _lpAmount;
      _mockAndExpectMintEmissions(_recipients, _amounts);
    }

    // it should emit the EarlyWithdrawPenalty event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit EarlyWithdrawPenalty(users.alice, _tokenId, _penaltyAmount);
    // it should emit the ReferralEmissionsDeferred event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit ReferralEmissionsDeferred(users.alice, _tokenId, users.referral, _referralAmount);
    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit EmissionsClaimed(users.alice, _tokenId, users.bob, _lpAmount);

    gauge.claimEmissions(users.alice, users.bob, _ids(_tokenId));

    // it should advance the position reward growth
    assertEq(gauge.rewardGrowthInside(_tokenId), _rewardGrowthInside);
    // it should mint LP emissions to the recipient
    assertEq(receiptToken.balanceOf(users.bob), _lpAmount);
    // it should store the referral emissions on the referral
    assertEq(gauge.deferredReferralEmissions(users.referral), _referralAmount);
  }

  modifier whenThePoolReportsARollover() {
    _;
  }

  function test_WhenThereAreNoAccruedEmissions(uint128 _rollover)
    external
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenClaimingOnePosition
    whenThePositionIsStakedByTheAccount
    whenThePoolReportsARollover
  {
    _rollover = uint128(bound(uint256(_rollover), 1, type(uint128).max));

    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);

    // @dev Align the gauge and pool reward growth so the position has no accrued emissions
    _setGaugeRewardGrowth(_tokenId, 0);
    _mockPoolRewardGrowth(_tokenId, 0);
    // it should settle the pool rewards
    // @dev The pool settlement returns the rollover accrued while no staked liquidity was in range
    _mockAndExpect({
      _receiver: address(pool),
      _calldata: abi.encodeWithSignature('settleToBlock()'),
      _returned: abi.encode(uint256(_rollover))
    });
    // it should forfeit the rollover emissions
    _mockAndExpectForfeitEmissions(_rollover);
    // it should not mint emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('mintEmissions(address[],uint128[])'), 0);

    gauge.claimEmissions(users.alice, users.bob, _ids(_tokenId));

    // @dev Bob's balance remains unchanged because no emissions were minted
    assertEq(receiptToken.balanceOf(users.bob), 0);
  }

  function test_WhenThereIsAPenalty(uint128 _rollover)
    external
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenClaimingOnePosition
    whenThePositionIsStakedByTheAccount
    whenThePoolReportsARollover
  {
    _rollover = uint128(bound(uint256(_rollover), 1, uint128(TOKEN_1 * 1_000_000)));

    uint256 _maxPips = gaugeFactory.MAX_PIPS();
    vm.prank(users.owner);
    // @dev Set 50% penalty rate
    gaugeFactory.setPenaltyConfig(10, _maxPips / 2);

    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    // @dev 50% penalty fee applied to 100 reward tokens
    uint128 _penaltyAmount = uint128(TOKEN_1 * 50);
    uint128 _remainingAmount = _rewardAmount - _penaltyAmount;
    // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);

    _setGaugeRewardGrowth(_tokenId, 0);
    _mockPoolRewardGrowth(_tokenId, _rewardGrowthInside);
    // it should settle the pool rewards
    // @dev The pool settlement returns the rollover accrued while no staked liquidity was in range
    _mockAndExpect({
      _receiver: address(pool),
      _calldata: abi.encodeWithSignature('settleToBlock()'),
      _returned: abi.encode(uint256(_rollover))
    });
    // it should forfeit the rollover together with the penalty emissions
    _mockAndExpectForfeitEmissions(_penaltyAmount + _rollover);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _remainingAmount;
    _mockAndExpectMintEmissions(_recipients, _amounts);

    gauge.claimEmissions(users.alice, users.bob, _ids(_tokenId));

    // it should mint the remaining emissions to the recipient
    assertEq(receiptToken.balanceOf(users.bob), _remainingAmount);
  }

  modifier whenClaimingForMultiplePositions() {
    _;
  }

  function test_WhenClaimingSelectedStakedPositions()
    external
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenClaimingForMultiplePositions
  {
    vm.startPrank(users.owner);
    // @dev Set 50% penalty rate and 5% referral share
    gaugeFactory.setPenaltyConfig(10, gaugeFactory.MAX_PIPS() / 2);
    gaugeFactory.setReferralConfig(address(gauge), users.referral, gaugeFactory.DEFAULT_MAX_SHARE_CAP());
    vm.stopPrank();

    uint256 _tokenId1 = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    uint256 _tokenId2 = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    uint256 _tokenId3 = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId1);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    // @dev 50% penalty fee applied to 100 reward tokens
    uint128 _penaltyAmount = uint128(TOKEN_1 * 50);
    // @dev 5% referral share applied to the 50 reward tokens left after penalty
    uint128 _referralAmount = uint128(TOKEN_1 * 5 / 2);
    uint128 _lpAmount = _rewardAmount - _penaltyAmount - _referralAmount;
    uint128 _deferredAmount = uint128(TOKEN_1 * 25);
    uint128 _deferredReferralAmount = uint128(TOKEN_1 * 5);
    // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens per selected position
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId1);
    nft.approve(address(gauge), _tokenId2);
    nft.approve(address(gauge), _tokenId3);
    gauge.deposit(_tokenId1);
    gauge.deposit(_tokenId2);
    gauge.deposit(_tokenId3);

    _setDeferredEmissions(users.alice, _deferredAmount);
    _setDeferredReferralEmissions(users.referral, _deferredReferralAmount);

    _setGaugeRewardGrowth(_tokenId1, 0);
    _setGaugeRewardGrowth(_tokenId3, 0);
    _mockPoolRewardGrowth(_tokenId1, _rewardGrowthInside);
    _mockPoolRewardGrowth(_tokenId3, _rewardGrowthInside);

    {
      // @dev Only claim live position rewards for `_tokenId1` and `_tokenId3`
      uint256[] memory _tokenIds = new uint256[](2);
      _tokenIds[0] = _tokenId1;
      _tokenIds[1] = _tokenId3;

      // it should settle the pool rewards
      vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
      // it should forfeit the aggregate penalty emissions
      _mockAndExpectForfeitEmissions(_penaltyAmount * 2);

      address[] memory _recipients = new address[](1);
      _recipients[0] = users.bob;
      uint128[] memory _amounts = new uint128[](1);
      _amounts[0] = _lpAmount * 2 + _deferredAmount;
      // it should mint aggregate live and deferred emissions
      _mockAndExpectMintEmissions(_recipients, _amounts);

      for (uint256 i = 0; i < _tokenIds.length; i++) {
        // it should emit the EarlyWithdrawPenalty event for each penalized position
        vm.expectEmit(true, true, true, true, address(gauge));
        emit EarlyWithdrawPenalty(users.alice, _tokenIds[i], _penaltyAmount);
        // it should apply the penalty before the referral for each selected position
        // @dev Referral amount is 5% of the post-penalty emissions
        // it should emit the ReferralEmissionsDeferred event for each referred position
        vm.expectEmit(true, true, true, true, address(gauge));
        emit ReferralEmissionsDeferred(users.alice, _tokenIds[i], users.referral, _referralAmount);
        // it should emit the EmissionsClaimed event for each paid position
        vm.expectEmit(true, true, true, true, address(gauge));
        emit EmissionsClaimed(users.alice, _tokenIds[i], users.bob, _lpAmount);
      }

      // it should emit DeferredEmissionsClaimed
      vm.expectEmit(true, true, false, true, address(gauge));
      emit DeferredEmissionsClaimed(users.alice, users.bob, _deferredAmount);
      gauge.claimEmissions(users.alice, users.bob, _tokenIds);
    }

    // it should advance each selected position reward growth
    assertEq(gauge.rewardGrowthInside(_tokenId1), _rewardGrowthInside);
    assertEq(gauge.rewardGrowthInside(_tokenId3), _rewardGrowthInside);
    // @dev The unselected staked position is not advanced
    assertEq(gauge.rewardGrowthInside(_tokenId2), 0);
    // it should aggregate live and deferred recipient emissions
    assertEq(receiptToken.balanceOf(users.bob), _lpAmount * 2 + _deferredAmount);
    // it should aggregate live and existing deferred referral emissions on the referral
    assertEq(gauge.deferredReferralEmissions(users.referral), _referralAmount * 2 + _deferredReferralAmount);
    // it should clear the deferred LP emissions
    assertEq(gauge.deferredEmissions(users.alice), 0);
  }

  modifier whenClaimingAllStakedPositions() {
    _;
  }

  function test_WhenTheAccountHasNoStakedPositionsOrDeferredLPEmissions(
    address _account,
    address _recipient
  )
    external
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenClaimingForMultiplePositions
    whenClaimingAllStakedPositions
  {
    vm.assume(_account != address(0));
    vm.assume(_recipient != address(0));

    vm.prank(_account);
    // it should revert with NS
    vm.expectRevert(abi.encodePacked('NS'));
    gauge.claimEmissions(_account, _recipient);
  }

  function test_WhenTheAccountHasMultipleStakedPositions()
    external
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenClaimingForMultiplePositions
    whenClaimingAllStakedPositions
  {
    vm.startPrank(users.owner);
    // @dev Set 50% penalty rate and 5% referral share
    gaugeFactory.setPenaltyConfig(10, gaugeFactory.MAX_PIPS() / 2);
    gaugeFactory.setReferralConfig(address(gauge), users.referral, gaugeFactory.DEFAULT_MAX_SHARE_CAP());
    vm.stopPrank();

    uint256 _tokenId1 = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    uint256 _tokenId2 = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    uint256 _tokenId3 = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    uint256 _rewardGrowthInside;
    {
      (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId1);
      // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens per staked position
      _rewardGrowthInside = FullMath.mulDivRoundingUp(TOKEN_1 * 100, Q128, _liquidity);
    }

    // @dev 50% penalty fee applied to 100 reward tokens
    uint128 _penaltyAmount = uint128(TOKEN_1 * 50);
    // @dev 5% referral share applied to the 50 reward tokens left after penalty
    uint128 _referralAmount = uint128(TOKEN_1 * 5 / 2);
    uint128 _lpAmount = uint128(TOKEN_1 * 95 / 2);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId1);
    nft.approve(address(gauge), _tokenId2);
    nft.approve(address(gauge), _tokenId3);
    gauge.deposit(_tokenId1);
    gauge.deposit(_tokenId2);
    gauge.deposit(_tokenId3);

    _setGaugeRewardGrowth(_tokenId1, 0);
    _setGaugeRewardGrowth(_tokenId2, 0);
    _setGaugeRewardGrowth(_tokenId3, 0);
    _mockPoolRewardGrowth(_tokenId1, _rewardGrowthInside);
    _mockPoolRewardGrowth(_tokenId2, _rewardGrowthInside);
    _mockPoolRewardGrowth(_tokenId3, _rewardGrowthInside);

    {
      // it should settle the pool rewards
      vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
      // it should forfeit the aggregate penalty emissions
      _mockAndExpectForfeitEmissions(_penaltyAmount * 3);

      address[] memory _recipients = new address[](1);
      _recipients[0] = users.bob;
      uint128[] memory _amounts = new uint128[](1);
      _amounts[0] = _lpAmount * 3;
      // it should mint aggregate LP emissions to the recipient
      _mockAndExpectMintEmissions(_recipients, _amounts);

      uint256[] memory _tokenIds = new uint256[](3);
      _tokenIds[0] = _tokenId1;
      _tokenIds[1] = _tokenId2;
      _tokenIds[2] = _tokenId3;

      for (uint256 i = 0; i < _tokenIds.length; i++) {
        // it should emit the EarlyWithdrawPenalty event for each penalized position
        vm.expectEmit(true, true, true, true, address(gauge));
        emit EarlyWithdrawPenalty(users.alice, _tokenIds[i], _penaltyAmount);
        // it should apply the penalty before the referral for each staked position
        // @dev Referral amount is 5% of the post-penalty emissions
        // it should emit the ReferralEmissionsDeferred event for each referred position
        vm.expectEmit(true, true, true, true, address(gauge));
        emit ReferralEmissionsDeferred(users.alice, _tokenIds[i], users.referral, _referralAmount);
        // it should emit the EmissionsClaimed event for each paid position
        vm.expectEmit(true, true, true, true, address(gauge));
        emit EmissionsClaimed(users.alice, _tokenIds[i], users.bob, _lpAmount);
      }

      gauge.claimEmissions(users.alice, users.bob);
    }

    // it should advance each staked position reward growth
    assertEq(gauge.rewardGrowthInside(_tokenId1), _rewardGrowthInside);
    assertEq(gauge.rewardGrowthInside(_tokenId2), _rewardGrowthInside);
    assertEq(gauge.rewardGrowthInside(_tokenId3), _rewardGrowthInside);
    // it should aggregate recipient emissions across all staked positions
    assertEq(receiptToken.balanceOf(users.bob), _lpAmount * 3);
    // it should aggregate referral emissions on the referral
    assertEq(gauge.deferredReferralEmissions(users.referral), _referralAmount * 3);
  }

  function test_WhenTheCallerIsAnApprovedOperator() external whenTheCallerIsAuthorized {
    uint256 _maxPips = gaugeFactory.MAX_PIPS();
    uint256 _referralShare = gaugeFactory.DEFAULT_MAX_SHARE_CAP();
    vm.startPrank(users.owner);
    // @dev Set 50% penalty rate and 5% referral share
    gaugeFactory.setPenaltyConfig(10, _maxPips / 2);
    gaugeFactory.setReferralConfig(address(gauge), users.referral, _referralShare);
    vm.stopPrank();

    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    // @dev 50% penalty fee applied to 100 reward tokens
    uint128 _penaltyAmount = uint128(TOKEN_1 * 50);
    // @dev 5% referral share applied to the 50 reward tokens left after penalty
    uint128 _referralAmount = uint128(TOKEN_1 * 5 / 2);
    uint128 _lpAmount = _rewardAmount - _penaltyAmount - _referralAmount;
    uint128 _deferredLpAmount = uint128(TOKEN_1 * 95);
    // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);
    vm.stopPrank();

    // @dev Overwrite storage to simulate approved operator
    stdstore.target(address(gauge)).sig(gauge.approvedForClaim.selector).with_key(users.alice).with_key(users.bob)
      .checked_write(true);
    _setDeferredEmissions(users.alice, _deferredLpAmount);

    _setGaugeRewardGrowth(_tokenId, 0);
    _mockPoolRewardGrowth(_tokenId, _rewardGrowthInside);
    // it should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // it should forfeit the penalty emissions
    _mockAndExpectForfeitEmissions(_penaltyAmount);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _lpAmount + _deferredLpAmount;
    _mockAndExpectMintEmissions(_recipients, _amounts);

    // it should emit the EarlyWithdrawPenalty event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit EarlyWithdrawPenalty(users.alice, _tokenId, _penaltyAmount);
    // it should apply the penalty before the referral
    // @dev Referral amount is 5% of the post-penalty emissions
    // it should emit the ReferralEmissionsDeferred event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit ReferralEmissionsDeferred(users.alice, _tokenId, users.referral, _referralAmount);
    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(gauge));
    emit EmissionsClaimed(users.alice, _tokenId, users.bob, _lpAmount);
    // it should emit DeferredEmissionsClaimed
    vm.expectEmit(true, true, false, true, address(gauge));
    emit DeferredEmissionsClaimed(users.alice, users.bob, _deferredLpAmount);
    vm.prank(users.bob);
    gauge.claimEmissions(users.alice, users.bob);

    // it should advance the position reward growth
    assertEq(gauge.rewardGrowthInside(_tokenId), _rewardGrowthInside);
    // it should combine live and deferred emissions in one mint
    assertEq(receiptToken.balanceOf(users.bob), _lpAmount + _deferredLpAmount);
    // it should store the referral emissions on the referral
    assertEq(gauge.deferredReferralEmissions(users.referral), _referralAmount);
    // it should clear the deferred LP emissions
    assertEq(gauge.deferredEmissions(users.alice), 0);
  }

  function testGas_claimEmissions()
    external
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenClaimingOnePosition
    whenThePositionIsStakedByTheAccount
    whenThePositionHasAccruedEmissions
  {
    uint256 _maxPips = gaugeFactory.MAX_PIPS();
    uint256 _referralShare = gaugeFactory.DEFAULT_MAX_SHARE_CAP();
    vm.startPrank(users.owner);
    // @dev Set 50% penalty rate and 5% referral share
    gaugeFactory.setPenaltyConfig(10, _maxPips / 2);
    gaugeFactory.setReferralConfig(address(gauge), users.referral, _referralShare);
    vm.stopPrank();

    uint256 _tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint128 _rewardAmount = uint128(TOKEN_1 * 100);
    // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(_rewardAmount), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId);
    gauge.deposit(_tokenId);

    _setGaugeRewardGrowth(_tokenId, 0);
    _mockPoolRewardGrowth(_tokenId, _rewardGrowthInside);
    // it should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    // it should forfeit the penalty emissions
    _mockAndExpect({
      _receiver: address(voter), _calldata: abi.encodeWithSignature('forfeitEmissions(uint128)'), _returned: ''
    });
    _mockAndExpect({
      _receiver: address(voter), _calldata: abi.encodeWithSignature('mintEmissions(address[],uint128[])'), _returned: ''
    });

    gauge.claimEmissions(users.alice, users.bob, _ids(_tokenId));
    vm.snapshotGasLastCall('CLGauge_claimEmissions');
  }

  function testGas_claimEmissions_multiple()
    external
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenClaimingForMultiplePositions
  {
    vm.startPrank(users.owner);
    // @dev Set 50% penalty rate and 5% referral share
    gaugeFactory.setPenaltyConfig(10, gaugeFactory.MAX_PIPS() / 2);
    gaugeFactory.setReferralConfig(address(gauge), users.referral, gaugeFactory.DEFAULT_MAX_SHARE_CAP());
    vm.stopPrank();

    uint256 _tokenId1 = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    uint256 _tokenId2 = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    uint256 _tokenId3 = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 _liquidity,,,,) = nft.positions(_tokenId1);
    // @dev Advance rewardGrowthInside to simulate accrual of 100 tokens per selected position
    uint256 _rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(TOKEN_1 * 100), Q128, _liquidity);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), _tokenId1);
    nft.approve(address(gauge), _tokenId2);
    nft.approve(address(gauge), _tokenId3);
    gauge.deposit(_tokenId1);
    gauge.deposit(_tokenId2);
    gauge.deposit(_tokenId3);

    _setGaugeRewardGrowth(_tokenId1, 0);
    _setGaugeRewardGrowth(_tokenId2, 0);
    _setGaugeRewardGrowth(_tokenId3, 0);
    _mockPoolRewardGrowth(_tokenId1, _rewardGrowthInside);
    _mockPoolRewardGrowth(_tokenId2, _rewardGrowthInside);
    _mockPoolRewardGrowth(_tokenId3, _rewardGrowthInside);
    _mockAndExpect({
      _receiver: address(voter), _calldata: abi.encodeWithSignature('forfeitEmissions(uint128)'), _returned: ''
    });
    _mockAndExpect({
      _receiver: address(voter), _calldata: abi.encodeWithSignature('mintEmissions(address[],uint128[])'), _returned: ''
    });

    uint256[] memory _tokenIds = new uint256[](3);
    _tokenIds[0] = _tokenId1;
    _tokenIds[1] = _tokenId2;
    _tokenIds[2] = _tokenId3;

    gauge.claimEmissions(users.alice, users.bob, _tokenIds);
    vm.snapshotGasLastCall('CLGauge_claimEmissions_multiple');
  }

  function _setDeferredEmissions(address _account, uint256 _amount) internal {
    stdstore.target(address(gauge)).sig(gauge.deferredEmissions.selector).with_key(_account).checked_write(_amount);
  }

  function _setDeferredReferralEmissions(address _referral, uint256 _amount) internal {
    stdstore.target(address(gauge)).sig(gauge.deferredReferralEmissions.selector).with_key(_referral)
      .checked_write(_amount);
  }

  // @dev Writes the position reward growth checkpoint in the gauge.
  function _setGaugeRewardGrowth(uint256 _tokenId, uint256 _rewardGrowthInside) internal {
    stdstore.target(address(gauge)).sig(gauge.rewardGrowthInside.selector).with_key(_tokenId)
      .checked_write(_rewardGrowthInside);
  }

  // @dev Mocks and expects the pool reward growth read for a position.
  function _mockPoolRewardGrowth(uint256 _tokenId, uint256 _rewardGrowthInside) internal {
    (,,,,, int24 _tickLower, int24 _tickUpper,,,,,) = nft.positions(_tokenId);

    _mockAndExpect({
      _receiver: address(pool),
      _calldata: abi.encodeWithSignature(
        'getRewardGrowthInside(int24,int24,uint256)', _tickLower, _tickUpper, uint256(0)
      ),
      _returned: abi.encode(_rewardGrowthInside)
    });
  }

  // @dev Redirects voter emission minting and expects receipt token mints.
  function _mockAndExpectMintEmissions(address[] memory _recipients, uint128[] memory _amounts) internal {
    bytes memory _calldata = abi.encodeWithSignature('mintEmissions(address[],uint128[])', _recipients, _amounts);

    for (uint256 i = 0; i < _recipients.length; i++) {
      vm.expectCall(
        address(receiptToken), abi.encodeWithSignature('mint(address,uint256)', _recipients[i], _amounts[i])
      );
    }

    vm.mockFunction(address(voter), address(mockLeafVoter), _calldata);
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
