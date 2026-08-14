// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6;

/// @title IBasePoolTape
interface IBasePoolTape {
  /// @notice Pre-allocates buffer slots increasing the buffer capacity
  /// @param _pool The pool whose cardinality is being increased.
  /// @param _observationCardinalityNext The new target cardinality.
  function increaseObservationCardinalityNext(address _pool, uint16 _observationCardinalityNext) external;
}
