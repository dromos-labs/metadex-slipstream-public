// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.7.6;
pragma abicoder v2;

import {DeployBase} from 'script/DeployBase.s.sol';

/// @notice Deploys the Slipstream CL stack on a leaf chain.
contract DeployLeaf is DeployBase {
  constructor() {
    _constantsFilename = 'leaf.json';
    _outputFilename = 'DeployLeaf.json';
  }
}
