// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity =0.7.6;
pragma abicoder v2;

import {IArbSys} from '../../../core/interfaces/external/IArbSys.sol';
import {CLInterfaceMulticall} from '../CLInterfaceMulticall.sol';

/// @notice Arbitrum multicall lens reporting L2 heights alongside aggregated results.
contract ArbCLInterfaceMulticall is CLInterfaceMulticall {
  /// @inheritdoc CLInterfaceMulticall
  function _blockNumber() internal view override returns (uint256) {
    return IArbSys(address(0x64)).arbBlockNumber();
  }
}
