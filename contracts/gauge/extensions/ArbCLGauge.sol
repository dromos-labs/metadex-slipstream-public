// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity =0.7.6;
pragma abicoder v2;

import {IArbSys} from '../../core/interfaces/external/IArbSys.sol';
import {CLGauge} from '../CLGauge.sol';

/// @notice CL gauge measuring deposit stamps and penalty windows in Arbitrum L2 blocks.
contract ArbCLGauge is CLGauge {
  /// @notice Binds the Arbitrum gauge to its voter, position manager and factory.
  /// @param _voter The leaf voter.
  /// @param _nft The position manager.
  /// @param _gaugeFactory The gauge factory.
  constructor(address _voter, address _nft, address _gaugeFactory) CLGauge(_voter, _nft, _gaugeFactory) {}

  /// @notice Reads the Arbitrum system precompile for the local block height.
  /// @return The current Arbitrum L2 block height.
  function _blockNumber() internal view override returns (uint256) {
    return IArbSys(address(0x64)).arbBlockNumber();
  }
}
