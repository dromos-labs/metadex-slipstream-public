// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.7.6;
pragma abicoder v2;

import {DeployBase} from 'script/DeployBase.s.sol';

/// @notice Deploys the Slipstream CL stack on the root chain.
contract DeployRoot is DeployBase {
  constructor() {
    _constantsFilename = 'root.json';
    _outputFilename = 'DeployRoot.json';
  }
}
