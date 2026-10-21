// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6;

interface IAccessControl {
  function hasRole(bytes32 _role, address _account) external view returns (bool);
  function getRoleAdmin(bytes32 _role) external view returns (bytes32);
  function getRoleMemberCount(bytes32 _role) external view returns (uint256);
  function getRoleMember(bytes32 _role, uint256 _index) external view returns (address);
  function grantRole(bytes32 _role, address _account) external;
  function revokeRole(bytes32 _role, address _account) external;
  function renounceRole(bytes32 _role, address _account) external;
}
