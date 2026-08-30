pragma solidity ^0.7.6;
pragma abicoder v2;

import '../CLGauge.t.sol';

contract DepositForConcreteUnitTest is CLGaugeTest {
  function setUp() public override {
    super.setUp();
    skipToNextEpoch(0);
  }

  function test_WhenOwnerIsZeroAddress() external {
    // It should revert with {ZA}
    uint256 tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), tokenId);
    vm.expectRevert(abi.encodePacked('ZA'));
    gauge.depositFor(tokenId, address(0));
  }

  function test_WhenCallerIsNotTokenOwner(address caller, address owner) external {
    // It should revert with {NA}
    vm.assume(caller != address(0));
    vm.assume(caller != users.alice);
    vm.assume(owner != address(0));

    uint256 tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);

    vm.prank(caller);
    vm.expectRevert(abi.encodePacked('NA'));
    gauge.depositFor(tokenId, owner);
  }

  function test_WhenCreditingADifferentOwner(address owner) external {
    vm.assume(owner != address(0));
    vm.assume(owner != users.alice);

    uint256 tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);
    (,,,,,,, uint128 liquidity,,,,) = nft.positions(tokenId);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), tokenId);

    // It should emit Deposit for owner
    vm.expectEmit(true, true, true, true, address(gauge));
    emit Deposit({_caller: users.alice, _user: owner, _tokenId: tokenId, _liquidityToStake: liquidity});
    gauge.depositFor(tokenId, owner);
    vm.stopPrank();

    // It should credit stake to owner
    assertTrue(gauge.stakedContains(owner, tokenId));
    assertEq(gauge.stakedLength(owner), 1);
    assertEq(gauge.stakedLength(users.alice), 0);

    // It should transfer the nft to the gauge
    assertEq(nft.ownerOf(tokenId), address(gauge));
  }

  function test_WhenCreditedOwnerWithdraws() external {
    // It should return the nft to credited owner
    uint256 tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), tokenId);
    gauge.depositFor(tokenId, users.bob);
    vm.stopPrank();

    vm.prank(users.bob);
    gauge.withdraw(tokenId);

    assertEq(nft.ownerOf(tokenId), users.bob);
    assertEq(gauge.stakedLength(users.bob), 0);
  }

  function test_WhenDepositingForSelf() external {
    // It should behave like deposit
    uint256 tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), tokenId);
    gauge.depositFor(tokenId, users.alice);
    vm.stopPrank();

    assertTrue(gauge.stakedContains(users.alice, tokenId));
    assertEq(gauge.stakedLength(users.alice), 1);
  }

  function testGas_depositFor() external {
    uint256 tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);

    vm.startPrank(users.alice);
    nft.approve(address(gauge), tokenId);
    gauge.depositFor(tokenId, users.bob);
    vm.snapshotGasLastCall('CLGauge_depositFor');
    vm.stopPrank();
  }
}
