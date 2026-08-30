pragma solidity ^0.7.6;
pragma abicoder v2;

import '../CLGauge.t.sol';

contract SetApprovalForAllConcreteUnitTest is CLGaugeTest {
  function setUp() public override {
    super.setUp();
    skipToNextEpoch(0);
  }

  function test_WhenOperatorIsZeroAddress() external {
    // It should revert with {ZA}
    vm.prank(users.alice);
    vm.expectRevert(abi.encodePacked('ZA'));
    gauge.setApprovalForAll(address(0), true);
  }

  function test_WhenGrantingApproval(address operator) external {
    vm.assume(operator != address(0));

    assertFalse(gauge.isApprovedForAll(users.alice, operator));

    // It should emit ApprovalForAll
    vm.expectEmit(true, true, false, true, address(gauge));
    emit ApprovalForAll({_owner: users.alice, _operator: operator, _approved: true});
    vm.prank(users.alice);
    gauge.setApprovalForAll(operator, true);

    // It should set blanket approval
    assertTrue(gauge.isApprovedForAll(users.alice, operator));
  }

  function test_WhenRevokingApproval(address operator) external {
    vm.assume(operator != address(0));

    vm.startPrank(users.alice);
    gauge.setApprovalForAll(operator, true);
    assertTrue(gauge.isApprovedForAll(users.alice, operator));

    // It should emit ApprovalForAll
    vm.expectEmit(true, true, false, true, address(gauge));
    emit ApprovalForAll({_owner: users.alice, _operator: operator, _approved: false});
    gauge.setApprovalForAll(operator, false);
    vm.stopPrank();

    // It should clear blanket approval
    assertFalse(gauge.isApprovedForAll(users.alice, operator));
  }

  function test_WhenCheckingAnotherOwnerOrOperator(
    address operator,
    address otherOperator,
    address otherOwner
  ) external {
    // It should keep approval scoped to owner and operator
    vm.assume(operator != address(0));
    vm.assume(otherOperator != operator);
    vm.assume(otherOwner != users.alice);

    vm.prank(users.alice);
    gauge.setApprovalForAll(operator, true);

    assertFalse(gauge.isApprovedForAll(users.alice, otherOperator));
    assertFalse(gauge.isApprovedForAll(otherOwner, operator));
  }

  function testGas_setApprovalForAll() external {
    vm.startPrank(users.alice);
    gauge.setApprovalForAll(users.bob, true);
    vm.snapshotGasLastCall('CLGauge_setApprovalForAll_grant');

    gauge.setApprovalForAll(users.bob, false);
    vm.snapshotGasLastCall('CLGauge_setApprovalForAll_revoke');
    vm.stopPrank();
  }
}
