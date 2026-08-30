// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

interface ICLGaugeFactory {
  struct ReferralConfig {
    address referral;
    uint256 share;
  }

  struct PenaltyConfig {
    uint256 minStakeBlocks;
    uint256 penaltyRate;
  }

  event GaugeCreated(address indexed _gauge, address indexed _pool, bool _isPool);
  event EmissionCapSet(address indexed _gauge, uint128 _cap, address indexed _caller);
  event FeeFlushFailed(address indexed _gauge);
  event DefaultCapSet(uint128 _cap);
  event OperatorCapRangeSet(uint128 _minCap, uint128 _maxCap);
  event MaxShareCapSet(uint256 _cap);
  event ReferralConfigSet(address indexed _gauge, address indexed _referral, uint256 _share);
  event PenaltyConfigSet(uint256 _minStakeBlocks, uint256 _penaltyRate);
  event MinStakeBlocksSet(address indexed _gauge, uint256 _minStakeBlocks);

  /// @notice PIPS denominator (1_000_000 = 100%).
  function MAX_PIPS() external view returns (uint256);

  /// @notice Initial factory-wide max referral share cap.
  function DEFAULT_MAX_SHARE_CAP() external view returns (uint256);

  /// @notice Initial factory-wide minimum-stake threshold in blocks.
  function DEFAULT_MIN_STAKE_BLOCKS() external view returns (uint256);

  /// @notice Initial factory-wide penalty rate in PIPS.
  function DEFAULT_PENALTY_RATE() external view returns (uint256);

  /// @notice Address of the LeafVoter contract.
  function leafVoter() external view returns (address);

  /// @notice GaugeManager authorized to call `createGauge`.
  function gaugeManager() external view returns (address);

  /// @notice VotingRewardsFactory deploying each gauge's VotingRewardsManager.
  function votingRewardsFactory() external view returns (address);

  /// @notice Short string label identifying this factory's gauge type.
  function GAUGE_TYPE() external view returns (string memory);

  /// @notice Address of the gauge implementation contract
  function implementation() external view returns (address);

  /// @notice Address of the NonfungiblePositionManager used to create nfts that gauges will accept
  function nft() external view returns (address);

  /// @notice Upper bound on minStakeBlocks, set at construction.
  function maxMinStakeBlocks() external view returns (uint256);

  function CAP_ADMIN_ROLE() external view returns (bytes32);

  function REFERRAL_ADMIN_ROLE() external view returns (bytes32);

  function PENALTY_ADMIN_ROLE() external view returns (bytes32);

  function CAP_OPERATOR_ROLE() external view returns (bytes32);

  /// @notice True if this factory deployed `gauge`.
  function isGauge(address _gauge) external view returns (bool);

  /// @notice Emission cap stored for `gauge`.
  function emissionCap(address _gauge) external view returns (uint128);

  /// @notice Factory-wide default emission cap.
  function defaultCap() external view returns (uint128);

  /// @notice Set the default emission cap for future gauges.
  /// @dev Existing gauges retain their stored emission caps.
  function setDefaultCap(uint128 _cap) external;

  /// @notice Set a per-gauge emission cap.
  function setEmissionCap(address _gauge, uint128 _cap) external;

  /**
   * @notice Sets a gauge's emission cap to zero without requiring a successful fee flush.
   * @dev Only callable by the emergency council.
   * @param _gauge Address of the gauge to deactivate.
   */
  function clearEmissionCap(address _gauge) external;

  /// @notice Minimum cap CAP_OPERATOR_ROLE may set.
  function operatorMinCap() external view returns (uint128);

  /// @notice Maximum cap CAP_OPERATOR_ROLE may set.
  function operatorMaxCap() external view returns (uint128);

  /// @notice Set operator cap range.
  function setOperatorCapRange(uint128 _minCap, uint128 _maxCap) external;

  /// @notice Factory-wide maximum referral share cap.
  function maxShareCap() external view returns (uint256);

  /// @notice Set factory-wide maximum referral share cap.
  function setMaxShareCap(uint256 _cap) external;

  /// @notice Returns (address(0), 0) when unconfigured.
  function referralConfig(address _gauge) external view returns (address _referral, uint256 _share);

  /// @notice Set or clear referral config.
  function setReferralConfig(address _gauge, address _referral, uint256 _share) external;

  /// @notice Factory-wide penalty config.
  function penaltyConfig() external view returns (PenaltyConfig memory);

  /**
   * @notice Effective penalty config for `_gauge`.
   * @param _gauge The gauge to query.
   * @return The penalty config with the effective minimum-stake threshold.
   */
  function effectivePenaltyConfig(address _gauge) external view returns (PenaltyConfig memory);

  /// @notice Effective minimum-stake threshold for `gauge`, in blocks.
  function minStakeBlocks(address _gauge) external view returns (uint256);

  /// @notice Set factory-wide penalty config.
  function setPenaltyConfig(uint256 _minStakeBlocks, uint256 _penaltyRate) external;

  /// @notice Set or clear per-gauge minimum-stake block override.
  function setMinStakeBlocks(address _gauge, uint256 _minStakeBlocks) external;

  /**
   * @notice Predicts the deterministic gauge address for `_pool`.
   * @dev The salt derives from the pool address, so the prediction is fixed
   *      and unique per pool. The registry links at most one gauge per
   *      target, so no second deployment ever needs a fresh address.
   * @param _pool The address of the pool.
   * @return _gauge Predicted gauge address.
   */
  function computeGaugeAddress(address _pool) external view returns (address _gauge);

  /**
   * @notice Called by the GaugeManager to deploy and initialize a CL gauge
   *         together with its VotingRewardsManager.
   * @dev The gauge is deployed and registered before the VotingRewardsManager
   *      is created through the VotingRewardsFactory, seeded with the pool's
   *      pair tokens as the initial reward tokens.
   * @param _target The address of the pool the gauge points at.
   * @param _factoryData Optional factory params. First byte 0x01 encodes a 65-byte referral config.
   * @return _gauge The address of the created gauge
   * @return _rewards The address of the deployed VotingRewardsManager
   */
  function createGauge(address _target, bytes calldata _factoryData) external returns (address _gauge, address _rewards);
}
