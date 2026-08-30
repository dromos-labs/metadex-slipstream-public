pragma solidity ^0.7.6;
pragma abicoder v2;

import '../CLGauge.t.sol';

contract ClaimEmissionsIntegrationConcreteTest is CLGaugeTest {
  function setUp() public override {
    super.setUp();

    vm.startPrank(users.bob);
    deal({token: address(token0), to: users.bob, give: TOKEN_1 * 10});
    deal({token: address(token1), to: users.bob, give: TOKEN_1 * 10});
    token0.approve(address(nft), type(uint256).max);
    token1.approve(address(nft), type(uint256).max);
    token0.approve(address(nftCallee), type(uint256).max);
    token1.approve(address(nftCallee), type(uint256).max);

    vm.startPrank(users.alice);

    skipToNextEpoch(0);
  }

  function labelContracts() internal override {
    super.labelContracts();

    vm.label({account: address(pool), newLabel: 'Pool'});
    vm.label({account: address(gauge), newLabel: 'Gauge'});
  }

  function _stakeFor(address account) internal returns (uint256 tokenId) {
    tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, account);
    vm.startPrank(account);
    nft.approve(address(gauge), tokenId);
    gauge.deposit(tokenId);
    vm.stopPrank();
  }

  function test_RevertIf_CallerIsNotAccountAndNotApproved() public {
    uint256 tokenId = _stakeFor(users.alice);

    vm.prank(users.charlie);
    vm.expectRevert(abi.encodePacked('NA'));
    gauge.claimEmissions(users.alice, users.charlie, _ids(tokenId));
  }

  function test_RevertIf_CallerIsNotAccountAndNotApprovedForAllPositions() public {
    _stakeFor(users.alice);

    vm.prank(users.charlie);
    vm.expectRevert(abi.encodePacked('NA'));
    gauge.claimEmissions(users.alice, users.charlie);
  }

  function test_ClaimAllPositionsAsApprovedOperatorToRecipient() public {
    uint256 tokenId = _stakeFor(users.alice);
    uint256 tokenId2 = _stakeFor(users.alice);

    vm.prank(users.alice);
    gauge.approveForClaim(users.charlie, true);

    vm.prank(users.charlie);
    gauge.claimEmissions(users.alice, users.bob);

    assertTrue(gauge.stakedContains(users.alice, tokenId));
    assertTrue(gauge.stakedContains(users.alice, tokenId2));
    assertTrue(gauge.approvedForClaim(users.alice, users.charlie));
  }
}
