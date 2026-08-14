// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

import {ICLGaugeFactory} from 'contracts/gauge/interfaces/ICLGaugeFactory.sol';

interface IGauge {
  /**
   * @notice Emitted when the gauge collects pool fees through the VotingRewardsManager.
   * @param _caller The address that triggered fee collection.
   * @param _claimed0 The amount of token0 fees collected.
   * @param _claimed1 The amount of token1 fees collected.
   */
  event ClaimFees(address indexed _caller, uint256 _claimed0, uint256 _claimed1);

  /**
   * @notice Emitted when an account grants or revokes claim approval for an operator
   * @param _account The account whose approval state changed
   * @param _operator The operator being approved or revoked
   * @param _approved The new approval state
   */
  event ClaimApproval(address indexed _account, address indexed _operator, bool _approved);

  /**
   * @notice Emitted when an owner grants or revokes blanket withdrawal approval for an operator
   * @param _owner The owner whose approval changed
   * @param _operator The operator being approved or revoked
   * @param _approved The new approval state
   */
  event ApprovalForAll(address indexed _owner, address indexed _operator, bool _approved);

  /**
   * @notice Deposit a staked position
   * @param _lp A token amount for V2 gauges or an NFT token ID for CL gauges
   */
  function deposit(uint256 _lp) external;

  /**
   * @notice Deposit a staked position on behalf of an owner
   * @param _lp A token amount for V2 gauges or an NFT token ID for CL gauges
   * @param _owner The address credited as the staked owner
   */
  function depositFor(uint256 _lp, address _owner) external;

  /**
   * @notice Withdraw a staked position owned by the caller
   * @param _lp A token amount for V2 gauges or an NFT token ID for CL gauges
   */
  function withdraw(uint256 _lp) external;

  /**
   * @notice Withdraw a staked position on behalf of an account
   * @param _lp A token amount for V2 gauges or an NFT token ID for CL gauges
   * @param _account The position owner
   */
  function withdrawFrom(uint256 _lp, address _account) external;

  /**
   * @notice Claim accrued emissions
   * @dev Requires the caller to be the LP or an operator with claim approval
   * @param _account The address of the LP staker whose emissions are being claimed
   * @param _recipient The recipient of the claimed emissions
   */
  function claimEmissions(address _account, address _recipient) external;

  /**
   * @notice Collect currently claimable pool fees directly to the VotingRewardsManager.
   * @dev Only callable by the VotingRewardsManager.
   * @return _amount0 The token0 fees collected.
   * @return _amount1 The token1 fees collected.
   */
  function collectFees() external returns (uint256 _amount0, uint256 _amount1);

  /**
   * @notice Grant or revoke an operator's approval to claim emissions on behalf of the caller
   * @param _operator The operator to approve or revoke
   * @param _approved True to approve, false to revoke
   */
  function approveForClaim(address _operator, bool _approved) external;

  /**
   * @notice Whether an operator is approved to claim emissions on behalf of an account
   * @param _account The account that granted the approval
   * @param _operator The operator being queried
   * @return True if the operator is approved
   */
  function approvedForClaim(address _account, address _operator) external view returns (bool);

  /**
   * @notice Grant or revoke blanket withdrawal authorization for an operator over all staked positions
   * @param _operator The operator to authorize or revoke
   * @param _approved True to grant blanket approval, false to revoke
   */
  function setApprovalForAll(address _operator, bool _approved) external;

  /**
   * @notice Returns whether an operator has blanket withdrawal authorization for an owner's positions
   * @param _owner The staked position owner
   * @param _operator The candidate operator
   * @return True if blanket approval is active
   */
  function isApprovedForAll(address _owner, address _operator) external view returns (bool);

  /**
   * @notice Approve an operator to withdraw a staked position
   * @param _operator The operator to authorize
   * @param _lp A token amount for V2 gauges or an NFT token ID for CL gauges
   */
  function approve(address _operator, uint256 _lp) external;

  /**
   * @notice PIPS denominator (1_000_000 = 100%)
   * @return The PIPS denominator
   */
  function MAX_PIPS() external view returns (uint256);

  /**
   * @notice Address of the factory that created this gauge
   * @return The gauge factory
   */
  function gaugeFactory() external view returns (ICLGaugeFactory);

  /**
   * @notice Estimates the claimable emissions for a given account
   * @dev Rewards accrued since the last settlement are an estimate
   * @param _account The address of the LP staker
   * @return The estimated claimable amount
   */
  function earned(address _account) external view returns (uint256);

  /**
   * @notice Return currently claimable pool fees without moving tokens or mutating state.
   * @return _amount0 The currently pending token0 fees.
   * @return _amount1 The currently pending token1 fees.
   */
  function pendingFees() external view returns (uint256 _amount0, uint256 _amount1);
}
