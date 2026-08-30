// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

/**
 * @title IFactoryRegistry
 * @notice Surface of the metadex `FactoryRegistry` the CL stack calls.
 * @dev A pool is a "target" and a pool factory a "target factory". The periphery keeps its own read-only mirror in
 *      `contracts/periphery/interfaces/IV3FactoryRegistry.sol` for the quoters.
 */
interface IFactoryRegistry {
  /**
   * @notice Registers a gauge factory and the target factory it serves as a pair, writing their permanent link.
   * @param gaugeFactory The gauge factory to register.
   * @param targetFactory The target (pool) factory the gauge factory serves.
   */
  function registerFactories(address gaugeFactory, address targetFactory) external;

  /**
   * @notice Records a freshly deployed target. Called by the target factory inside its own creation function.
   * @param target The deployed target (pool).
   */
  function registerTarget(address target) external;

  /**
   * @notice True when a target (pool) factory is in the approval set.
   * @param targetFactory The target factory to check.
   * @return Whether the factory is approved.
   */
  function isTargetFactoryApproved(address targetFactory) external view returns (bool);

  /**
   * @notice The gauge factory serving a target factory.
   * @param targetFactory The target factory to resolve.
   * @return The linked gauge factory, zero for an unlinked factory.
   */
  function targetFactoryToGaugeFactory(address targetFactory) external view returns (address);

  /**
   * @notice The gauge over a target (pool).
   * @param target The target to resolve.
   * @return The gauge for `target`, zero when none is recorded.
   */
  function targetToGauge(address target) external view returns (address);

  /**
   * @notice Effective emission cap for a gauge, resolved through the factory that deployed it.
   * @dev Returns zero when the gauge is unknown or the factory call reverts.
   * @param gauge The gauge to resolve.
   * @return The effective cap in tokens per second.
   */
  function emissionCap(address gauge) external view returns (uint128);
}
