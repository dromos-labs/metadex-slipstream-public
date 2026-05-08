// SPDX-License-Identifier: MIT
pragma solidity >=0.7.5;

/**
 * @title IPoolFactoryV3
 * @notice Minimal surface of the metadex V3 `PoolFactory` the quoters need.
 * @dev Mirrors `metadex/V3/src/factories/PoolFactory.sol`; intentionally distinct from the legacy
 *      `contracts/core/interfaces/IPoolFactory.sol`. The V2 pool gates its swaps on this factory's pause flag, so the
 *      quoter rejects V2 quotes while paused.
 */
interface IPoolFactoryV3 {
  /**
   * @notice Whether the factory (and therefore its pools' swaps) is paused.
   * @return Whether the factory is paused.
   */
  function isPaused() external view returns (bool);
}
