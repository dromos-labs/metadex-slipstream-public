// SPDX-License-Identifier: MIT
pragma solidity >=0.7.5;

/**
 * @title IV3FactoryRegistry
 * @notice Minimal view surface the quoters need to authenticate a pool through the protocol registry.
 * @dev Mirrors the metadex `FactoryRegistry` reads the Metarouter uses to validate pools (a pool is a "target" and a
 *      pool factory a "target factory"). This is intentionally distinct from `IFactoryRegistry` under
 *      `contracts/core`, which carries the write surface the CL factory and pool need.
 */
interface IV3FactoryRegistry {
  /**
   * @notice True when a target (pool) factory is in the approval set.
   * @param targetFactory The pool factory to check.
   * @return Whether the factory is approved.
   */
  function isTargetFactoryApproved(address targetFactory) external view returns (bool);

  /**
   * @notice The target factory that deployed each target (pool). Written once when the factory records the target.
   * @dev Zero for an unknown target, so a nonzero result authenticates the pool without trusting its self-reported
   *      factory.
   * @param target The target (pool) to resolve.
   * @return The deploying target factory, or zero for an unknown target.
   */
  function targetToFactory(address target) external view returns (address);
}
