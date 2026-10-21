// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity =0.7.6;
pragma abicoder v2;

import {CLGaugeFactory} from '../CLGaugeFactory.sol';
import {ArbCLGauge} from './ArbCLGauge.sol';

/// @notice CL factory creating Arbitrum gauge implementations and their clones.
contract ArbCLGaugeFactory is CLGaugeFactory {
  /// @notice Constructs the factory using the ordinary configuration and an Arbitrum implementation.
  /// @param _leafVoter The leaf voter.
  /// @param _gaugeManager The authorized gauge manager.
  /// @param _votingRewardsFactory The voting rewards factory.
  /// @param _nft The position manager.
  /// @param _roles Initial role holders.
  /// @param _capConfig Initial emission-cap and penalty-window limits.
  constructor(
    address _leafVoter,
    address _gaugeManager,
    address _votingRewardsFactory,
    address _nft,
    RoleAddresses memory _roles,
    CapConfig memory _capConfig
  ) CLGaugeFactory(_leafVoter, _gaugeManager, _votingRewardsFactory, _nft, _roles, _capConfig) {}

  /// @inheritdoc CLGaugeFactory
  function _deployGaugeImplementation(address _voter, address _nft) internal override returns (address) {
    return address(new ArbCLGauge({_voter: _voter, _nft: _nft, _gaugeFactory: address(this)}));
  }
}
