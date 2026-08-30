// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import {CLPool} from '../CLPool.sol';

contract MockCLPool is CLPool {
  function externalUpdateRewardsGrowthGlobal(uint256 _rewardsToDistribute, uint48 _now, uint48 _lastUpdated) external {
    _updateRewardsGrowthGlobal(_rewardsToDistribute, _now, _lastUpdated);
  }

  function externalSettleToBlock() external {
    _settleToBlock();
  }
}
