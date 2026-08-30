pragma solidity ^0.7.6;
pragma abicoder v2;

import {ILeafVoter as ICLGaugeLeafVoter} from 'contracts/gauge/interfaces/ILeafVoter.sol';

import '../CLGauge.t.sol';

contract SettleGaugeConcreteUnitTest is CLGaugeTest {
  function test_WhenTheCallerIsNotThePool(address _caller) external {
    // It should revert with {NA}
    vm.assume(_caller != address(0));
    vm.assume(_caller != address(pool));

    vm.prank(_caller);
    vm.expectRevert(abi.encodePacked('NA'));
    gauge.settleGauge();
  }

  modifier whenTheCallerIsThePool() {
    _;
  }

  function test_WhenTheVoterReportsNoNewCumulativeRewardShare(uint256 _cumulativeRewardShare)
    external
    whenTheCallerIsThePool
  {
    // It should settle the gauge in the LeafVoter
    // It should return zero
    // It should keep the cursor unchanged
    // It should not emit a {GaugeSettled} event

    // @dev Advance the cursor to the reported cumulative share
    _mockAndExpectSettleGauge(_cumulativeRewardShare);

    vm.prank(address(pool));
    gauge.settleGauge();

    // @dev A repeated settlement in the same block reports the same cumulative share
    vm.recordLogs();
    vm.prank(address(pool));
    uint256 _delta = gauge.settleGauge();

    assertEq(_delta, 0);
    assertEq(gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    assertEq(vm.getRecordedLogs().length, 0);
  }

  function test_WhenTheVoterReportsANewCumulativeRewardShare(
    uint256 _firstCumulativeRewardShare,
    uint256 _secondCumulativeRewardShare
  ) external whenTheCallerIsThePool {
    // It should settle the gauge in the LeafVoter
    // It should return the delta since the last settled cumulative reward share
    // It should advance the cursor to the new cumulative reward share
    // It should emit a {GaugeSettled} event
    _firstCumulativeRewardShare = bound(_firstCumulativeRewardShare, 1, type(uint256).max - 1);
    _secondCumulativeRewardShare =
      bound(_secondCumulativeRewardShare, _firstCumulativeRewardShare + 1, type(uint256).max);

    // @dev First settlement returns the full cumulative share since the cursor starts at zero
    _mockAndExpectSettleGauge(_firstCumulativeRewardShare);

    vm.expectEmit(address(gauge));
    emit GaugeSettled({_cumulativeRewardShare: _firstCumulativeRewardShare, _delta: _firstCumulativeRewardShare});

    vm.prank(address(pool));
    uint256 _delta = gauge.settleGauge();

    assertEq(_delta, _firstCumulativeRewardShare);
    assertEq(gauge.lastCumulativeRewardShare(), _firstCumulativeRewardShare);

    // @dev Second settlement returns only the increment since the advanced cursor
    _mockAndExpectSettleGauge(_secondCumulativeRewardShare);

    vm.expectEmit(address(gauge));
    emit GaugeSettled({
      _cumulativeRewardShare: _secondCumulativeRewardShare,
      _delta: _secondCumulativeRewardShare - _firstCumulativeRewardShare
    });

    vm.prank(address(pool));
    _delta = gauge.settleGauge();

    assertEq(_delta, _secondCumulativeRewardShare - _firstCumulativeRewardShare);
    assertEq(gauge.lastCumulativeRewardShare(), _secondCumulativeRewardShare);
  }

  function test_WhenTheVoterReportsALowerCumulativeRewardShare(
    uint256 _cumulativeRewardShare,
    uint256 _lowerCumulativeRewardShare
  ) external whenTheCallerIsThePool {
    // It should settle the gauge in the LeafVoter
    // It should return zero
    // It should keep the cursor unchanged
    // It should not emit a {GaugeSettled} event
    _cumulativeRewardShare = bound(_cumulativeRewardShare, 1, type(uint256).max);
    _lowerCumulativeRewardShare = bound(_lowerCumulativeRewardShare, 0, _cumulativeRewardShare - 1);

    // @dev Advance the cursor to the reported cumulative share
    _mockAndExpectSettleGauge(_cumulativeRewardShare);

    vm.prank(address(pool));
    gauge.settleGauge();

    // @dev A regressed cumulative share (e.g. a deregistered gauge reporting 0) must not underflow
    _mockAndExpectSettleGauge(_lowerCumulativeRewardShare);

    vm.recordLogs();
    vm.prank(address(pool));
    uint256 _delta = gauge.settleGauge();

    assertEq(_delta, 0);
    assertEq(gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    assertEq(vm.getRecordedLogs().length, 0);
  }

  function _mockAndExpectSettleGauge(uint256 _cumulativeRewardShare) internal {
    _mockAndExpect({
      _receiver: address(voter),
      _calldata: abi.encodeWithSelector(ICLGaugeLeafVoter.settleGauge.selector, address(gauge)),
      _returned: abi.encode(_cumulativeRewardShare)
    });
  }

  function _mockAndExpect(address _receiver, bytes memory _calldata, bytes memory _returned) internal {
    vm.mockCall(_receiver, _calldata, _returned);
    vm.expectCall(_receiver, _calldata);
  }
}
