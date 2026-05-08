// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

interface IVotingRewardsManager {
  /// @notice Flushes accrued gauge fees into the voting rewards accumulator.
  function flushFees() external;
}
