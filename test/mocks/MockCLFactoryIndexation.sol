// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import {CLFactoryIndexation} from '../../contracts/core/indexation/CLFactoryIndexation.sol';
import {ICLFactoryIndexation} from '../../contracts/core/interfaces/indexation/ICLFactoryIndexation.sol';

contract MockCLFactoryIndexation is CLFactoryIndexation {
  /// @dev Invokes an internal pool-creation hook that atomically updates indexes.
  function createPoolHook(address _tokenA, address _tokenB, address _pool) external {
    _createPoolHook(_tokenA, _tokenB, _pool);
  }
}
