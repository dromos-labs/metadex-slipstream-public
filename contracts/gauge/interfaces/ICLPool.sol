// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

/// @title Minimal CLPool interface
/// @notice Used to support the integration with the core implementation
/// @dev For full context, please review the Uniswap implementation under GPL license.
interface ICLPool {
  function token0() external view returns (address);

  function token1() external view returns (address);

  function tickSpacing() external view returns (int24);

  /// @notice The reward growth as a Q128.128 rewards of emission collected per unit of liquidity for the entire life of the pool
  /// @dev This value can overflow the uint256
  function rewardGrowthGlobalX128() external view returns (uint256);

  /// @notice The currently in range staked liquidity available to the pool
  /// @dev This value has no relationship to the total staked liquidity across all ticks
  function stakedLiquidity() external view returns (uint128);

  /// @notice The amounts of token0 and token1 that are owed to the gauge
  /// @dev Gauge fees will never exceed uint128 max in either token
  function gaugeFees() external view returns (uint128 amount0, uint128 amount1);

  /// @notice Returns data about reward growth within a tick range.
  /// RewardGrowthGlobalX128 can be supplied as a parameter for claimable reward calculations.
  /// @dev Used in gauge reward/earned calculations
  /// @param tickLower The lower tick of the range
  /// @param tickUpper The upper tick of the range
  /// @param _rewardGrowthGlobalX128 a calculated rewardGrowthGlobalX128 or 0 (in case of 0 it means we use the rewardGrowthGlobalX128 from state)
  /// @return rewardGrowthInsideX128 The reward growth in the range
  function getRewardGrowthInside(
    int24 tickLower,
    int24 tickUpper,
    uint256 _rewardGrowthGlobalX128
  ) external view returns (uint256 rewardGrowthInsideX128);

  /// @notice Initialize gauge and nft manager
  /// @dev Callable only once, by the gauge factory
  /// @param _gauge The gauge corresponding to this pool
  /// @param _nft The position manager used for position management
  function setGaugeAndPositionManager(address _gauge, address _nft) external;

  /// @notice Convert existing liquidity into staked liquidity
  /// @notice Only callable by the gauge associated with this pool
  /// @param stakedLiquidityDelta The amount by which to increase or decrease the staked liquidity
  /// @param tickLower The lower tick of the position for which to stake liquidity
  /// @param tickUpper The upper tick of the position for which to stake liquidity
  function stake(int128 stakedLiquidityDelta, int24 tickLower, int24 tickUpper) external;

  /// @notice Settle the pool's reward growth to the current block timestamp and return the accrued rollover
  /// @return _rollover Emissions accrued while no staked liquidity was in range. Reset to 0 after this call.
  function settleToBlock() external returns (uint256 _rollover);

  /// @notice Collect the gauge fee accrued to the pool
  /// @param recipient The address that receives the claimed gauge fees
  /// @return amount0 The gauge fee collected in token0
  /// @return amount1 The gauge fee collected in token1
  function collectFees(address recipient) external returns (uint128 amount0, uint128 amount1);
}
