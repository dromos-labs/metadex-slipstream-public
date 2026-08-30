pragma solidity ^0.7.6;
pragma abicoder v2;

import '../CLGauge.t.sol';

contract ApproveConcreteUnitTest is CLGaugeTest {
  function setUp() public override {
    super.setUp();
    skipToNextEpoch(0);
  }

  function test_WhenCallerIsNotStakeOwner(address caller) external {
    // It should revert with {NA}
    vm.assume(caller != address(0));
    vm.assume(caller != users.alice);

    uint256 tokenId = _mintAndDeposit(users.alice);

    vm.prank(caller);
    vm.expectRevert(abi.encodePacked('NA'));
    gauge.approve(users.bob, tokenId);
  }

  function test_WhenPositionIsNotStaked() external {
    // It should revert with {NA}
    uint256 tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, users.alice);

    vm.prank(users.alice);
    vm.expectRevert(abi.encodePacked('NA'));
    gauge.approve(users.bob, tokenId);
  }

  function test_WhenCallerIsStakeOwner(address operator) external {
    vm.assume(operator != address(0));

    uint256 tokenId = _mintAndDeposit(users.alice);

    // It should emit Approval
    vm.expectEmit(true, true, true, true, address(gauge));
    emit Approval({_owner: users.alice, _operator: operator, _tokenId: tokenId});
    vm.prank(users.alice);
    gauge.approve(operator, tokenId);

    // It should set per token approval
    assertEq(gauge.getApproved(tokenId), operator);
  }

  function test_WhenClearingApproval() external {
    // It should clear per token approval
    uint256 tokenId = _mintAndDeposit(users.alice);

    vm.startPrank(users.alice);
    gauge.approve(users.bob, tokenId);
    assertEq(gauge.getApproved(tokenId), users.bob);

    gauge.approve(address(0), tokenId);
    vm.stopPrank();

    assertEq(gauge.getApproved(tokenId), address(0));
  }

  function test_WhenApprovedPositionIsWithdrawn() external {
    // It should clear per token approval
    uint256 tokenId = _mintAndDeposit(users.alice);

    vm.startPrank(users.alice);
    gauge.approve(users.bob, tokenId);
    gauge.withdraw(tokenId);
    vm.stopPrank();

    assertEq(gauge.getApproved(tokenId), address(0));
  }

  function _mintAndDeposit(address account) internal returns (uint256 tokenId) {
    tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1, TOKEN_1, account);
    vm.startPrank(account);
    nft.approve(address(gauge), tokenId);
    gauge.deposit(tokenId);
    vm.stopPrank();
  }

  function testGas_approve() external {
    uint256 tokenId = _mintAndDeposit(users.alice);

    vm.startPrank(users.alice);
    gauge.approve(users.bob, tokenId);
    vm.snapshotGasLastCall('CLGauge_approve_token');

    gauge.approve(address(0), tokenId);
    vm.snapshotGasLastCall('CLGauge_approve_clear');
    vm.stopPrank();
  }
}
