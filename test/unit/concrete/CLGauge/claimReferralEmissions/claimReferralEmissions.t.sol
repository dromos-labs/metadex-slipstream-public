pragma solidity ^0.7.6;
pragma abicoder v2;

import {TestERC20} from 'contracts/periphery/test/TestERC20.sol';
import {MockLeafVoter} from 'contracts/test/MockLeafVoter.sol';

import '../CLGauge.t.sol';

contract UnitCLGaugeClaimReferralEmissions is CLGaugeTest {
  using stdStorage for StdStorage;

  TestERC20 public receiptToken;
  MockLeafVoter public mockLeafVoter;

  function setUp() public override {
    super.setUp();

    receiptToken = new TestERC20(0);
    mockLeafVoter = new MockLeafVoter(receiptToken);
  }

  function test_WhenTheCallerIsNotTheReferralOrAnApprovedOperator(address _caller) external {
    vm.assume(_caller != address(0) && _caller != users.referral);

    vm.prank(_caller);
    // it should revert with NA
    vm.expectRevert(abi.encodePacked('NA'));
    gauge.claimReferralEmissions(users.referral, users.bob);
  }

  function test_WhenTheRecipientIsTheZeroAddress() external {
    vm.prank(users.referral);
    // it should revert with ZA
    vm.expectRevert(abi.encodePacked('ZA'));
    gauge.claimReferralEmissions(users.referral, address(0));
  }

  function test_WhenTheReferralHasNoDeferredEmissions() external {
    // it should not mint emissions
    vm.expectCall(address(voter), abi.encodeWithSignature('mintEmissions(address[],uint128[])'), 0);
    vm.prank(users.referral);
    gauge.claimReferralEmissions(users.referral, users.bob);
  }

  function test_RevertWhen_EmissionMintingReverts(uint128 _amount) external {
    vm.assume(_amount > 0);
    _setDeferredReferralEmissions(users.referral, _amount);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _amount;
    bytes memory _calldata = abi.encodeWithSignature('mintEmissions(address[],uint128[])', _recipients, _amounts);
    vm.mockCallRevert(address(voter), _calldata, bytes(''));
    vm.expectCall(address(voter), _calldata);

    vm.prank(users.referral);
    // it should revert
    vm.expectRevert(bytes(''));
    gauge.claimReferralEmissions(users.referral, users.bob);

    // it should preserve the deferred referral emissions
    assertEq(gauge.deferredReferralEmissions(users.referral), _amount);
  }

  function test_WhenTheCallerIsTheReferral(uint128 _amount) external {
    vm.assume(_amount > 0);
    _setDeferredReferralEmissions(users.referral, _amount);
    _mockAndExpectMintEmissions(users.bob, _amount);

    // it should emit ReferralEmissionsClaimed
    vm.expectEmit(true, true, false, true, address(gauge));
    emit ReferralEmissionsClaimed(users.referral, users.bob, _amount);
    vm.prank(users.referral);
    gauge.claimReferralEmissions(users.referral, users.bob);

    // it should clear the deferred referral emissions
    assertEq(gauge.deferredReferralEmissions(users.referral), 0);
    // it should mint the full balance to the recipient
    assertEq(receiptToken.balanceOf(users.bob), _amount);
  }

  function test_WhenTheCallerIsAnApprovedOperator(uint128 _amount) external {
    vm.assume(_amount > 0);
    vm.prank(users.referral);
    gauge.approveForClaim(users.alice, true);

    _setDeferredReferralEmissions(users.referral, _amount);
    _mockAndExpectMintEmissions(users.bob, _amount);

    // it should emit ReferralEmissionsClaimed
    vm.expectEmit(true, true, false, true, address(gauge));
    emit ReferralEmissionsClaimed(users.referral, users.bob, _amount);
    vm.prank(users.alice);
    gauge.claimReferralEmissions(users.referral, users.bob);

    // it should clear the deferred referral emissions
    assertEq(gauge.deferredReferralEmissions(users.referral), 0);
    // it should mint the full balance to the recipient
    assertEq(receiptToken.balanceOf(users.bob), _amount);
  }

  function testGas_claimReferralEmissions() external {
    uint128 _amount = uint128(TOKEN_1 * 100);
    _setDeferredReferralEmissions(users.referral, _amount);
    _mockAndExpectMintEmissions(users.bob, _amount);

    vm.prank(users.referral);
    gauge.claimReferralEmissions(users.referral, users.bob);
    vm.snapshotGasLastCall('CLGauge_claimReferralEmissions');
  }

  function _setDeferredReferralEmissions(address _referral, uint256 _amount) internal {
    stdstore.target(address(gauge)).sig(gauge.deferredReferralEmissions.selector).with_key(_referral)
      .checked_write(_amount);
  }

  function _mockAndExpectMintEmissions(address _recipient, uint128 _amount) internal {
    address[] memory _recipients = new address[](1);
    _recipients[0] = _recipient;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _amount;
    bytes memory _calldata = abi.encodeWithSignature('mintEmissions(address[],uint128[])', _recipients, _amounts);

    vm.expectCall(address(receiptToken), abi.encodeWithSignature('mint(address,uint256)', _recipient, _amount));
    vm.mockFunction(address(voter), address(mockLeafVoter), _calldata);
  }
}
