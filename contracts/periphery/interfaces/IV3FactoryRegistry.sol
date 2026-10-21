// SPDX-License-Identifier: MIT
pragma solidity >=0.7.5;

/**
 * @title IV3FactoryRegistry
 * @notice View surface of the protocol registry the quoters authenticate pools against.
 * @dev Mirrors the metadex `FactoryRegistry` reads the Metarouter uses to validate pools (a pool is a "target" and a
 *      pool factory a "target factory"). This is intentionally distinct from `IFactoryRegistry` under
 *      `contracts/core`, which carries the write surface the CL factory and pool need.
 */
interface IV3FactoryRegistry {
  /**
   * @notice True when a target (pool) factory is in the approval set.
   * @dev Gates pool creation only: the quoters never read it, since unregistering a factory keeps its records.
   * @param targetFactory The pool factory to check.
   * @return Whether the factory is approved.
   */
  function isTargetFactoryApproved(address targetFactory) external view returns (bool);

  /**
   * @notice The target factory that deployed each target (pool). Written once when the factory records the target.
   * @dev Zero for an unknown target, so a nonzero result names the pool's factory without trusting its self-reported
   *      one. The quoters still require that factory to list the pool (`isPool`) before trusting it.
   * @param target The target (pool) to resolve.
   * @return The deploying target factory, or zero for an unknown target.
   */
  function targetToFactory(address target) external view returns (address);
}
