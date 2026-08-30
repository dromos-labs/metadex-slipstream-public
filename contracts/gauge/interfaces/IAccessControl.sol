// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

interface IAccessControl {
  function hasRole(bytes32 _role, address _account) external view returns (bool);
}
