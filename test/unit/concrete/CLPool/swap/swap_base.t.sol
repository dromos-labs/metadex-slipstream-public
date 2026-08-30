// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {FixedPoint128} from 'contracts/core/libraries/FixedPoint128.sol';
import {FixedPoint96} from 'contracts/core/libraries/FixedPoint96.sol';
import {FullMath} from 'contracts/core/libraries/FullMath.sol';
import {SwapMath} from 'contracts/core/libraries/SwapMath.sol';
import {TickMath} from 'contracts/core/libraries/TickMath.sol';

import {ICLFactory} from 'contracts/core/interfaces/ICLFactory.sol';
import {IERC20Minimal} from 'contracts/core/interfaces/IERC20Minimal.sol';
import {ICLSwapCallback} from 'contracts/core/interfaces/callback/ICLSwapCallback.sol';
import {ISwapHook} from 'contracts/core/interfaces/hook/ISwapHook.sol';
import {ICLPoolState} from 'contracts/core/interfaces/pool/ICLPoolState.sol';

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {UnitCLPoolSwapBaseHelpers} from './swapBaseHelpers.sol';

/// forge-config: ci.fuzz.runs=2000
contract UnitCLPoolSwapBase is UnitCLPoolSwapBaseHelpers {
  function test_WhenAmountSpecifiedEqZero() external {
    // it reverts with AS
    vm.expectRevert(abi.encode('AS'));
    clPool.swap(address(0), false, 0, 0, '');
  }

  modifier whenAmountSpecifiedDoesntEqZero(int256 _amountSpecified, bool _exactInput) virtual {
    if (_exactInput) vm.assume(_amountSpecified > 0);
    else vm.assume(_amountSpecified < 0);
    _;
  }

  function test_WhenPoolIsLocked(int256 _amountSpecified)
    external
    whenAmountSpecifiedDoesntEqZero(_amountSpecified, true)
  {
    _setSlot0Unlocked(address(clPool), false);

    // it reverts with LOK
    vm.expectRevert(abi.encode('LOK'));
    clPool.swap(address(0), false, _amountSpecified, 0, '');
  }

  modifier whenPoolIsUnlocked() virtual {
    _setSlot0Unlocked(address(clPool), true);
    _;
  }

  modifier whenSwapIsZeroForOne() virtual {
    _;
  }

  function test_WhenSqrtPriceLimitGeqCurrentSqrtPriceOrLeqMIN_SQRT_RATIO(
    int256 _amountSpecified,
    uint160 _sqrtPriceLimitX96,
    bool _geq
  ) external whenAmountSpecifiedDoesntEqZero(_amountSpecified, true) whenPoolIsUnlocked whenSwapIsZeroForOne {
    (uint160 _slot0SqrtPriceX96,,,,,) = clPool.slot0();

    if (_geq) {
      _sqrtPriceLimitX96 = uint160(bound(uint256(_sqrtPriceLimitX96), uint256(_slot0SqrtPriceX96), type(uint160).max));
    } else {
      _sqrtPriceLimitX96 = uint160(bound(uint256(_sqrtPriceLimitX96), 0, TickMath.MIN_SQRT_RATIO));
    }

    // it reverts with SPL
    vm.expectRevert(abi.encode('SPL'));
    clPool.swap(address(0), _ZERO_FOR_ONE, _amountSpecified, _sqrtPriceLimitX96, '');
  }

  modifier whenSwapIsOneForZero() virtual {
    _;
  }

  function test_WhenSqrtPriceLimitLeqCurrentSqrtPriceOrGeqMAX_SQRT_RATIO(
    int256 _amountSpecified,
    uint160 _sqrtPriceLimitX96,
    bool _leq
  ) external whenAmountSpecifiedDoesntEqZero(_amountSpecified, true) whenPoolIsUnlocked whenSwapIsOneForZero {
    (uint160 _slot0SqrtPriceX96,,,,,) = clPool.slot0();

    if (_leq) {
      _sqrtPriceLimitX96 = uint160(bound(uint256(_sqrtPriceLimitX96), 0, uint256(_slot0SqrtPriceX96)));
    } else {
      _sqrtPriceLimitX96 = uint160(bound(uint256(_sqrtPriceLimitX96), TickMath.MAX_SQRT_RATIO, type(uint160).max));
    }

    // it reverts with SPL
    vm.expectRevert(abi.encode('SPL'));
    clPool.swap(address(0), _ONE_FOR_ZERO, _amountSpecified, _sqrtPriceLimitX96, '');
  }
}
