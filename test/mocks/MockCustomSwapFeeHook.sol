// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {ISwapHook} from 'contracts/core/interfaces/hook/ISwapHook.sol';

import {ICLFactory} from 'contracts/core/interfaces/ICLFactory.sol';
import {ICLPool} from 'contracts/core/interfaces/ICLPool.sol';

contract MockCustomSwapFeeHook is ISwapHook {
  ICLFactory public immutable factory;
  mapping(address => uint24) public customFee;

  uint256 public constant MAX_FEE = 30_000; // 3%
  // Override to indicate there is custom 0% fee - as a 0 value in the customFee mapping indicates
  // that no custom fee rate has been set
  uint256 public constant ZERO_FEE_INDICATOR = 420;

  constructor(address _factory) {
    factory = ICLFactory(_factory);
  }

  function setCustomFee(address _pool, uint24 _fee) external {
    require(msg.sender == factory.swapFeeManager());
    require(_fee <= MAX_FEE || _fee == ZERO_FEE_INDICATOR);
    require(factory.isPool(_pool));

    customFee[_pool] = _fee;
  }

  function getBeforeSwapFee(address _pool, ISwapHook.SwapParams memory) external view override returns (uint24 _fee) {
    _fee = getFee(_pool);
  }

  function getAfterSwapFee(
    address _pool,
    ISwapHook.SwapParams memory,
    ISwapHook.AfterSwapParams memory
  ) external view override returns (uint24 _fee) {
    _fee = 0;
  }

  function getFlashFee(address _pool, ISwapHook.FlashParams memory) external view override returns (uint24 _fee) {
    _fee = getFee(_pool);
  }

  function beforeSwap(ISwapHook.SwapParams memory) external view override returns (uint24 _fee) {
    _fee = getFee(msg.sender);
  }

  function afterSwap(
    ISwapHook.SwapParams memory,
    ISwapHook.AfterSwapParams memory
  ) external pure override returns (uint24 _fee) {
    _fee = 0;
  }

  function beforeFlash(ISwapHook.FlashParams memory) external view override returns (uint24 _fee) {
    _fee = getFee(msg.sender);
  }

  function getFee(address _pool) public view returns (uint24) {
    uint24 fee = customFee[_pool];
    int24 tickSpacing = ICLPool(_pool).tickSpacing();
    return fee == ZERO_FEE_INDICATOR ? 0 : fee != 0 ? fee : factory.tickSpacingToFee(tickSpacing);
  }
}
