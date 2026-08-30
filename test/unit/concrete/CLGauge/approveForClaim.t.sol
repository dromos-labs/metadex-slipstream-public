pragma solidity ^0.7.6;
pragma abicoder v2;

import './CLGauge.t.sol';

contract ApproveForClaimTest is CLGaugeTest {
  function test_WhenOperatorIsZeroAddress() public {
    // It should revert with {ZA}
    vm.prank(users.alice);
    vm.expectRevert(abi.encodePacked('ZA'));
    gauge.approveForClaim(address(0), true);
  }

  function test_WhenGrantingClaimApproval(address operator) public {
    vm.assume(operator != address(0));

    assertFalse(gauge.approvedForClaim(users.alice, operator));

    // It should emit ClaimApproval
    vm.expectEmit(true, true, false, true, address(gauge));
    emit ClaimApproval({_account: users.alice, _operator: operator, _approved: true});
    vm.prank(users.alice);
    gauge.approveForClaim(operator, true);

    // It should set claim approval
    assertTrue(gauge.approvedForClaim(users.alice, operator));
  }

  function test_WhenRevokingClaimApproval(address operator) public {
    vm.assume(operator != address(0));

    vm.startPrank(users.alice);
    gauge.approveForClaim(operator, true);
    assertTrue(gauge.approvedForClaim(users.alice, operator));

    // It should emit ClaimApproval
    vm.expectEmit(true, true, false, true, address(gauge));
    emit ClaimApproval({_account: users.alice, _operator: operator, _approved: false});
    gauge.approveForClaim(operator, false);
    vm.stopPrank();

    // It should clear claim approval
    assertFalse(gauge.approvedForClaim(users.alice, operator));
  }

  function test_WhenCheckingAnotherAccountOrOperator(
    address operator,
    address otherOperator,
    address otherAccount
  ) public {
    // It should keep approval scoped to account and operator
    vm.assume(operator != address(0));
    vm.assume(otherOperator != operator);
    vm.assume(otherAccount != users.alice);

    vm.prank(users.alice);
    gauge.approveForClaim(operator, true);

    assertFalse(gauge.approvedForClaim(users.alice, otherOperator));
    assertFalse(gauge.approvedForClaim(otherAccount, operator));
  }

  function test_WhenGrantingClaimApprovalTwice(address operator) public {
    // It should keep approval enabled
    vm.assume(operator != address(0));

    vm.startPrank(users.alice);
    gauge.approveForClaim(operator, true);
    gauge.approveForClaim(operator, true);
    vm.stopPrank();

    assertTrue(gauge.approvedForClaim(users.alice, operator));
  }

  function testGas_approveForClaim() public {
    vm.startPrank(users.alice);
    gauge.approveForClaim(users.bob, true);
    vm.snapshotGasLastCall('CLGauge_approveForClaim_grant');

    gauge.approveForClaim(users.bob, false);
    vm.snapshotGasLastCall('CLGauge_approveForClaim_revoke');
    vm.stopPrank();
  }
}
