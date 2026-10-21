// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

interface IVotingRewardsFactory {
  /// @notice Deploys a new VotingRewardsManager for a gauge
  /// @dev The gauge may be uninitialized or a predicted address with no deployed code and is never introspected.
  ///      The implementation MUST restrict callers to approved gauge factories (e.g. via the
  ///      FactoryRegistry): gauge addresses are publicly predictable via computeGaugeAddress and
  ///      the creation salt has no retry dimension, so a permissionless implementation that binds
  ///      at most one VotingRewardsManager per gauge would let anyone pre-claim a predicted gauge
  ///      address and permanently block gauge creation for that pool.
  /// @param _gauge The gauge the VotingRewardsManager is bound to
  /// @param _rewards Initial reward token addresses forwarded to the deployed VotingRewardsManager
  /// @return _votingRewardsManager The address of the deployed VotingRewardsManager
  function createRewards(address _gauge, address[] memory _rewards) external returns (address _votingRewardsManager);
}
