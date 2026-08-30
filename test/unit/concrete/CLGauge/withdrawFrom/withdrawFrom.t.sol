pragma solidity ^0.7.6;
pragma abicoder v2;

import {FullMath} from 'contracts/core/libraries/FullMath.sol';

import {TestERC20} from 'contracts/periphery/test/TestERC20.sol';
import {MockLeafVoter} from 'contracts/test/MockLeafVoter.sol';

import '../CLGauge.t.sol';

contract WithdrawFromConcreteUnitTest is CLGaugeTest {
  TestERC20 public receiptToken;
  MockLeafVoter public mockLeafVoter;

  function setUp() public override {
    super.setUp();
    skipToNextEpoch(0);

    receiptToken = new TestERC20(0);
    mockLeafVoter = new MockLeafVoter(receiptToken);
  }

  function test_WhenAccountIsZeroAddress(address caller) external {
    // It should revert with {ZA}
    vm.assume(caller != address(0));

    uint256 tokenId = _mintAndDeposit(users.alice);

    vm.prank(caller);
    vm.expectRevert(abi.encodePacked('ZA'));
    gauge.withdrawFrom(tokenId, address(0));
  }

  function test_WhenCallerIsNotApproved(address caller) external {
    // It should revert with {NW}
    vm.assume(caller != address(0));
    vm.assume(caller != users.alice);

    uint256 tokenId = _mintAndDeposit(users.alice);

    vm.prank(caller);
    vm.expectRevert(abi.encodePacked('NW'));
    gauge.withdrawFrom(tokenId, users.alice);
  }

  function test_WhenCallerIsAccountWithoutApproval() external {
    // It should revert with {NW}
    uint256 tokenId = _mintAndDeposit(users.alice);

    vm.prank(users.alice);
    vm.expectRevert(abi.encodePacked('NW'));
    gauge.withdrawFrom(tokenId, users.alice);
  }

  function test_WhenSuppliedAccountIsNotStakeOwner(address account) external {
    // It should revert with {NA}
    vm.assume(account != address(0));
    vm.assume(account != users.alice);

    uint256 tokenId = _mintAndDeposit(users.alice);

    vm.prank(users.alice);
    gauge.approve(users.bob, tokenId);

    vm.prank(users.bob);
    vm.expectRevert(abi.encodePacked('NA'));
    gauge.withdrawFrom(tokenId, account);
  }

  function test_WhenCallerHasPerTokenApproval() external {
    uint256 tokenId = _mintAndDeposit(users.alice);

    vm.prank(users.alice);
    gauge.approve(users.bob, tokenId);
    (,,,,,,, uint128 liquidity,,,,) = nft.positions(tokenId);

    vm.expectEmit(true, true, true, true, address(gauge));
    emit Withdraw({_caller: users.bob, _user: users.alice, _tokenId: tokenId, _liquidityToStake: liquidity});
    vm.prank(users.bob);
    gauge.withdrawFrom(tokenId, users.alice);

    // It should send the nft to caller
    assertEq(nft.ownerOf(tokenId), users.bob);

    // It should clear per token approval
    assertEq(gauge.getApproved(tokenId), address(0));

    // It should remove the stake from account
    assertEq(gauge.stakedLength(users.alice), 0);
  }

  function test_WhenCallerHasBlanketApproval() external {
    uint256 tokenId = _mintAndDeposit(users.alice);

    vm.prank(users.alice);
    gauge.setApprovalForAll(users.bob, true);

    vm.prank(users.bob);
    gauge.withdrawFrom(tokenId, users.alice);

    // It should send the nft to caller
    assertEq(nft.ownerOf(tokenId), users.bob);

    // It should remove the stake from account
    assertEq(gauge.stakedLength(users.alice), 0);

    // It should keep blanket approval active
    assertTrue(gauge.isApprovedForAll(users.alice, users.bob));
  }

  function test_WhenCallerHasNoClaimApproval() external {
    uint256 tokenId = _mintAndDeposit(users.alice);
    (,,,,,,, uint128 liquidity,,,,) = nft.positions(tokenId);
    uint128 rewardAmount = uint128(TOKEN_1 * 100);
    uint256 rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(rewardAmount), Q128, liquidity);
    vm.prank(users.alice);
    gauge.approve(users.bob, tokenId);

    _mockPoolRewardGrowth(tokenId, rewardGrowthInside);
    // It should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    _mockAndExpectMintEmissions(users.alice, rewardAmount);

    vm.prank(users.bob);
    // It should withdraw without requiring claim approval
    gauge.withdrawFrom(tokenId, users.alice);

    // It should mint claimed emissions to account
    assertEq(receiptToken.balanceOf(users.alice), rewardAmount);
    // It should not mint claimed emissions to caller
    assertEq(receiptToken.balanceOf(users.bob), 0);
    // It should send the nft to caller
    assertEq(nft.ownerOf(tokenId), users.bob);
  }

  modifier whenCallerHasClaimApproval() {
    _;
  }

  function test_WhenEmissionMintingDoesNotRevert() external whenCallerHasClaimApproval {
    uint256 tokenId = _mintAndDeposit(users.alice);
    (,,,,,,, uint128 liquidity,,,,) = nft.positions(tokenId);
    uint128 rewardAmount = uint128(TOKEN_1 * 100);
    uint256 rewardGrowthInside = FullMath.mulDivRoundingUp(uint256(rewardAmount), Q128, liquidity);

    vm.startPrank(users.alice);
    gauge.approve(users.bob, tokenId);
    gauge.approveForClaim(users.bob, true);
    vm.stopPrank();

    _mockPoolRewardGrowth(tokenId, rewardGrowthInside);
    // It should settle the pool rewards
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    _mockAndExpectMintEmissions(users.bob, rewardAmount);

    vm.prank(users.bob);
    gauge.withdrawFrom(tokenId, users.alice);

    // It should mint claimed emissions to caller
    assertEq(receiptToken.balanceOf(users.bob), rewardAmount);
    assertEq(receiptToken.balanceOf(users.alice), 0);
    // It should send the nft to caller
    assertEq(nft.ownerOf(tokenId), users.bob);
    // It should keep claim approval active after withdrawal
    assertTrue(gauge.approvedForClaim(users.alice, users.bob));
  }

  function test_WhenEmissionMintingReverts() external whenCallerHasClaimApproval {
    (uint256 tokenId, uint128 rewardAmount) = _depositAndAccrue(users.alice);
    vm.startPrank(users.alice);
    gauge.approve(users.bob, tokenId);
    gauge.approveForClaim(users.bob, true);
    vm.stopPrank();

    address[] memory recipients = new address[](1);
    recipients[0] = users.bob;
    uint128[] memory amounts = new uint128[](1);
    amounts[0] = rewardAmount;
    bytes memory callData = abi.encodeWithSignature('mintEmissions(address[],uint128[])', recipients, amounts);

    // It should collect position fees to the caller
    _expectCollect(tokenId, users.bob, 1);
    // It should attempt to mint emissions to the caller
    vm.mockCallRevert(address(voter), callData, abi.encodeWithSignature('ChainNotActive()'));
    vm.expectCall(address(voter), callData);

    // It should emit an {EmissionsDeferred} event
    vm.expectEmit(true, true, false, true, address(gauge));
    emit EmissionsDeferred(users.alice, tokenId, rewardAmount);
    vm.prank(users.bob);
    gauge.withdrawFrom(tokenId, users.alice);

    // It should credit deferred emissions to the account
    assertEq(gauge.deferredEmissions(users.alice), rewardAmount);
    // It should send the nft to caller
    assertEq(nft.ownerOf(tokenId), users.bob);
  }

  function testGas_withdrawFrom() external {
    uint256 tokenId = _mintAndDeposit(users.alice);

    vm.prank(users.alice);
    gauge.approve(users.bob, tokenId);

    vm.prank(users.bob);
    gauge.withdrawFrom(tokenId, users.alice);
    vm.snapshotGasLastCall('CLGauge_withdrawFrom_tokenApproval');

    uint256 blanketTokenId = _mintAndDeposit(users.alice);

    vm.prank(users.alice);
    gauge.setApprovalForAll(users.bob, true);

    vm.prank(users.bob);
    gauge.withdrawFrom(blanketTokenId, users.alice);
    vm.snapshotGasLastCall('CLGauge_withdrawFrom_approvalForAll');
  }

  function _mintAndDeposit(address account) internal returns (uint256 tokenId) {
    tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, account);
    vm.startPrank(account);
    nft.approve(address(gauge), tokenId);
    gauge.deposit(tokenId);
    vm.stopPrank();
  }

  function _depositAndAccrue(address account) internal returns (uint256 tokenId, uint128 rewardAmount) {
    tokenId = _mintAndDeposit(account);
    (,,,,,,, uint128 liquidity,,,,) = nft.positions(tokenId);
    uint256 rewardGrowthDelta = FullMath.mulDivRoundingUp(TOKEN_1 * 100, Q128, liquidity);
    rewardAmount = uint128(FullMath.mulDiv(rewardGrowthDelta, liquidity, Q128));
    _mockPoolRewardGrowth(tokenId, gauge.rewardGrowthInside(tokenId) + rewardGrowthDelta);
  }

  function _expectCollect(uint256 tokenId, address recipient, uint64 count) internal {
    INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
      tokenId: tokenId, recipient: recipient, amount0Max: type(uint128).max, amount1Max: type(uint128).max
    });
    vm.expectCall(address(nft), abi.encodeWithSelector(nft.collect.selector, params), count);
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
