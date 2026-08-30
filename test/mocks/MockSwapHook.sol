// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity ^0.7.6;
pragma abicoder v2;

import {ISwapHook} from 'contracts/core/interfaces/hook/ISwapHook.sol';

contract MockSwapHook is ISwapHook {
  uint24 private immutable _CUSTOM_FEE;

  constructor(uint24 _customFee) {
    _CUSTOM_FEE = _customFee;
  }

  function getBeforeSwapFee(address, ISwapHook.SwapParams memory) external view override returns (uint24 _fee) {
    _fee = _CUSTOM_FEE;
  }

  function getAfterSwapFee(
    address,
    ISwapHook.SwapParams memory,
    ISwapHook.AfterSwapParams memory
  ) external view override returns (uint24 _fee) {
    _fee = 0;
  }

  function getFlashFee(address, ISwapHook.FlashParams memory) external pure override returns (uint24 _fee) {
    _fee = 0;
  }

  function beforeSwap(ISwapHook.SwapParams memory) external view override returns (uint24 _fee) {
    _fee = _CUSTOM_FEE;
  }

  function afterSwap(
    ISwapHook.SwapParams memory,
    ISwapHook.AfterSwapParams memory
  ) external pure override returns (uint24 _fee) {
    _fee = 0;
  }

  function beforeFlash(ISwapHook.FlashParams memory) external pure override returns (uint24 _fee) {
    _fee = 0;
  }
}
