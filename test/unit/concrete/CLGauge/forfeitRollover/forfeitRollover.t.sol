pragma solidity ^0.7.6;
pragma abicoder v2;

import '../CLGauge.t.sol';

contract ForfeitRolloverConcreteUnitTest is CLGaugeTest {
  function test_WhenThePoolReportsNoRollover(address _caller) external {
    // It should settle the pool
    // It should not forfeit emissions
    vm.assume(_caller != address(0));

    vm.mockCall(address(pool), abi.encodeWithSignature('settleToBlock()'), abi.encode(uint256(0)));
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    vm.expectCall(address(voter), abi.encodeWithSignature('forfeitEmissions(uint128)'), 0);

    vm.prank(_caller);
    gauge.forfeitRollover();
  }

  function test_WhenThePoolReportsARollover(address _caller, uint128 _rollover) external {
    // It should settle the pool
    // It should forfeit the rollover to the LeafVoter
    vm.assume(_caller != address(0));
    _rollover = uint128(bound(uint256(_rollover), 1, type(uint128).max));

    vm.mockCall(address(pool), abi.encodeWithSignature('settleToBlock()'), abi.encode(uint256(_rollover)));
    vm.expectCall(address(pool), abi.encodeWithSignature('settleToBlock()'));
    vm.mockCall(address(voter), abi.encodeWithSignature('forfeitEmissions(uint128)', _rollover), abi.encode());
    vm.expectCall(address(voter), abi.encodeWithSignature('forfeitEmissions(uint128)', _rollover));

    vm.prank(_caller);
    gauge.forfeitRollover();
  }
}
