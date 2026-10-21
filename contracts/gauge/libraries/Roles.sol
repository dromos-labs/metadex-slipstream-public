// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity =0.7.6;

/**
 * @title Roles
 * @notice Central registry of AccessControl role identifiers used by Voter, GasGuard, and LeafVoter.
 */
library Roles {
  /// @notice Emergency actor authorized to zero a gauge's emission cap on the leaf.
  bytes32 public constant EMERGENCY_COUNCIL_ROLE = keccak256('EMERGENCY_COUNCIL_ROLE');
}
