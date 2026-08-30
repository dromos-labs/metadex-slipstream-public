// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity =0.7.6;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import {IReward} from 'contracts/gauge/interfaces/IReward.sol';

contract MockFeesVotingReward is IReward {
  using SafeERC20 for IERC20;

  uint256 public flushFeesCalls;

  /// @inheritdoc IReward
  function notifyRewardAmount(address token, uint256 amount) external override {
    IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

    emit NotifyReward(msg.sender, token, amount);
  }

  function earned(address, uint256) external pure override returns (uint256) {
    return 0;
  }

  function getReward(uint256, address[] memory) external pure override {}

  function flushFees() external {
    flushFeesCalls++;
  }
}
