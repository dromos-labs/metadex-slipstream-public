// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity =0.7.6;

import {MockFeesVotingReward} from './MockFeesVotingReward.sol';
import {IVotingRewardsFactory} from 'contracts/gauge/interfaces/IVotingRewardsFactory.sol';

/// @dev called by CLGaugeFactory.createGauge on every gauge creation in tests;
///      the returned MockFeesVotingReward acts as the gauge's VotingRewardsManager.
///      See fork tests for more rigorous integration testing including voting rewards.
contract MockVotingRewardsFactory is IVotingRewardsFactory {
  /// @inheritdoc IVotingRewardsFactory
  function createRewards(
    address, // _gauge
    address[] memory // _rewards
  ) external override returns (address _votingRewardsManager) {
    _votingRewardsManager = address(new MockFeesVotingReward());
  }
}
