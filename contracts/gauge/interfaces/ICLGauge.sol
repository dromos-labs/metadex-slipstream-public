// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

import {ICLPool} from 'contracts/gauge/interfaces/ICLPool.sol';
import {IGauge} from 'contracts/gauge/interfaces/IGauge.sol';
import {INonfungiblePositionManager} from 'contracts/gauge/interfaces/INonfungiblePositionManager.sol';

interface ICLGauge is IGauge {
  /**
   * @notice Emitted when a position is deposited into the gauge.
   * @param _caller The address that deposited the position.
   * @param _user The address credited as the staked owner.
   * @param _tokenId The tokenId of the deposited position.
   * @param _liquidityToStake The amount of liquidity staked in the pool.
   */
  event Deposit(address indexed _caller, address indexed _user, uint256 indexed _tokenId, uint128 _liquidityToStake);

  /**
   * @notice Emitted when a position is withdrawn from the gauge.
   * @param _caller The address that withdrew the position.
   * @param _user The address whose stake was withdrawn.
   * @param _tokenId The tokenId of the withdrawn position.
   * @param _liquidityToStake The amount of liquidity unstaked from the pool.
   */
  event Withdraw(address indexed _caller, address indexed _user, uint256 indexed _tokenId, uint128 _liquidityToStake);

  /**
   * @notice Emitted when accrued emissions are claimed for a staked position.
   * @param _account The address of the LP staker whose emissions were claimed.
   * @param _tokenId The tokenId of the staked position.
   * @param _recipient The recipient of the claimed emissions.
   * @param _rewardAmount The amount of emissions paid to the recipient.
   */
  event EmissionsClaimed(
    address indexed _account, uint256 indexed _tokenId, address indexed _recipient, uint256 _rewardAmount
  );

  /**
   * @notice Emitted when accrued emissions are stored instead of claimed during withdrawal.
   * @param _account The address of the LP staker credited with the deferred emissions.
   * @param _tokenId The tokenId whose emissions were stored.
   * @param _rewardAmount The post-penalty, post-referral emissions added to the account's deferred balance.
   */
  event EmissionsDeferred(address indexed _account, uint256 indexed _tokenId, uint256 _rewardAmount);

  /**
   * @notice Emitted when a position's referral emissions are stored for a later claim.
   * @param _account The address of the LP staker whose emissions paid the referral.
   * @param _tokenId The tokenId of the staked position.
   * @param _referral The referral address credited with the emissions.
   * @param _amount The referral emissions added to the referral's deferred balance.
   */
  event ReferralEmissionsDeferred(
    address indexed _account, uint256 indexed _tokenId, address indexed _referral, uint256 _amount
  );

  /**
   * @notice Emitted when an account's deferred emissions are claimed.
   * @param _account The account whose deferred emissions were claimed.
   * @param _recipient The recipient of the claimed emissions.
   * @param _amount The deferred emissions paid to the recipient after referral.
   */
  event DeferredEmissionsClaimed(address indexed _account, address indexed _recipient, uint256 _amount);

  /**
   * @notice Emitted when an early withdrawal penalty is applied to a position's accrued emissions.
   * @param _from The address of the LP staker whose emissions were penalized.
   * @param _tokenId The tokenId of the staked position.
   * @param _penalty The amount of emissions forfeited as the penalty.
   */
  event EarlyWithdrawPenalty(address indexed _from, uint256 indexed _tokenId, uint256 _penalty);

  /**
   * @notice Emitted when a per-tokenId withdrawal approval is set or cleared
   * @param _owner The position owner
   * @param _operator The approved operator (address(0) if cleared)
   * @param _tokenId The approved token ID
   */
  event Approval(address indexed _owner, address indexed _operator, uint256 indexed _tokenId);

  /**
   * @notice Emitted when the gauge settles emissions accrued in the LeafVoter
   * @dev Not emitted when a settlement accrues no new emissions
   * @param _cumulativeRewardShare The LeafVoter's cumulative reward share at this settlement
   * @param _delta The emissions accrued since the previous settlement
   */
  event GaugeSettled(uint256 _cumulativeRewardShare, uint256 _delta);

  /**
   * @notice Called on gauge creation by CLGaugeFactory
   * @dev Only callable by the gauge factory
   * @param _pool The address of the pool
   * @param _votingRewardsManager The address of the voting rewards manager contract
   * @param _token0 The address of token0 of the pool
   * @param _token1 The address of token1 of the pool
   * @param _tickSpacing The tick spacing of the pool
   * @param _isPool Whether the attached pool is a real pool or not
   */
  function initialize(
    address _pool,
    address _votingRewardsManager,
    address _token0,
    address _token1,
    int24 _tickSpacing,
    bool _isPool
  ) external;

  /**
   * @notice Settle the gauge in the LeafVoter and return the emissions accrued since the last settlement
   * @dev Only callable by the corresponding pool
   * @dev Pulls the gauge's cumulative reward share from the LeafVoter and advances the gauge's cursor
   * @return _delta The emissions accrued since the gauge's last settlement
   */
  function settleGauge() external returns (uint256 _delta);

  /**
   * @notice Settle the pool and forfeit any accumulated rollover back to the LeafVoter
   * @dev Permissionless. Emissions accrued while no staked liquidity is in range are banked in the
   *      pool as rollover and normally forfeited during claims; an idle gauge with no staked
   *      positions has no claims, so this entrypoint returns them to the voter directly.
   */
  function forfeitRollover() external;

  /**
   * @notice Claim the LP's accrued emissions across the given positions
   * @dev Also claims all account-level deferred LP emissions regardless of the requested positions
   * @param _account The address of the LP staker whose emissions are being claimed
   * @param _recipient The recipient of the claimed emissions
   * @param _tokenIds The staked positions to claim
   */
  function claimEmissions(address _account, address _recipient, uint256[] calldata _tokenIds) external;

  /**
   * @notice NonfungiblePositionManager used to create nfts accepted by this gauge.
   * @return The address of the NonfungiblePositionManager.
   */
  function nft() external view returns (INonfungiblePositionManager);

  /**
   * @notice Address of the CL pool linked to the gauge.
   * @return The address of the CL pool.
   */
  function pool() external view returns (ICLPool);

  /**
   * @notice Cached address of token0, corresponding to token0 of the pool.
   * @return The address of token0.
   */
  function token0() external view returns (address);

  /**
   * @notice Cached address of token1, corresponding to token1 of the pool.
   * @return The address of token1.
   */
  function token1() external view returns (address);

  /**
   * @notice Cached tick spacing of the pool.
   * @return The tick spacing of the pool.
   */
  function tickSpacing() external view returns (int24);

  /**
   * @notice Returns the rewardGrowthInside of the position at the last user action (deposit, withdraw, claimEmissions)
   * @param _tokenId The tokenId of the position
   * @return The rewardGrowthInside for the position
   */
  function rewardGrowthInside(uint256 _tokenId) external view returns (uint256);

  /**
   * @notice Returns the block number at which a position was deposited
   * @param _tokenId The tokenId of the position
   * @return The deposit block for the position
   */
  function depositBlock(uint256 _tokenId) external view returns (uint256);

  /**
   * @notice Returns net LP emissions stored for an account when emission minting fails during withdrawal
   * @param _account The account credited with the deferred emissions
   * @return The post-penalty, post-referral deferred LP emissions
   */
  function deferredEmissions(address _account) external view returns (uint256);

  /**
   * @notice Estimates the claimable emissions for a given account across the requested positions
   * @dev Assumes _tokenIds contains no duplicates
   * @dev Rewards accrued since the last settlement are an estimate
   * @dev Includes the account-level deferred LP emissions
   * @param _account The address of the LP staker
   * @param _tokenIds The staked positions
   * @return The estimated claimable amount
   */
  function earned(address _account, uint256[] memory _tokenIds) external view returns (uint256);

  /**
   * @notice Returns the operator approved to withdraw a specific staked position
   * @param _tokenId The staked NFT token ID
   * @return The approved operator, or address(0) if none
   */
  function getApproved(uint256 _tokenId) external view returns (address);

  /**
   * @notice Fetch all tokenIds staked by a given account
   * @param _depositor The address of the user
   * @return The tokenIds of the staked positions
   */
  function stakedValues(address _depositor) external view returns (uint256[] memory);

  /**
   * @notice Fetch a staked tokenId by index
   * @param _depositor The address of the user
   * @param _index The index of the staked tokenId
   * @return The tokenId of the staked position
   */
  function stakedByIndex(address _depositor, uint256 _index) external view returns (uint256);

  /**
   * @notice Check whether a position is staked in the gauge by a certain user
   * @param _depositor The address of the user
   * @param _tokenId The tokenId of the position
   * @return Whether the position is staked in the gauge
   */
  function stakedContains(address _depositor, uint256 _tokenId) external view returns (bool);

  /**
   * @notice The amount of positions staked in the gauge by a certain user
   * @param _depositor The address of the user
   * @return The amount of positions staked in the gauge
   */
  function stakedLength(address _depositor) external view returns (uint256);
}
