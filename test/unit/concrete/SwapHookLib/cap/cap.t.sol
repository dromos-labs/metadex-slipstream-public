// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {UnitSwapHookLib} from '../SwapHookLib.t.sol';

import {SwapHookLib} from 'contracts/core/libraries/hook/SwapHookLib.sol';

contract UnitSwapHookLibCap is UnitSwapHookLib {
  using SwapHookLib for uint24;

  function test_WhenFeeIsLtSwapFeeCeil(uint24 _fee) external {
    _fee = uint24(bound(_fee, 0, uint256(SwapHookLib._SWAP_FEE_CEIL - 1)));

    // it returns fee
    assertEqUint(_fee.cap(), _fee);
  }

  function test_WhenFeeIsGeqSwapFeeCeil(uint24 _fee) external {
    _fee = uint24(bound(_fee, uint256(SwapHookLib._SWAP_FEE_CEIL), type(uint24).max));

    // it returns _SWAP_FEE_CEIL
    assertEqUint(_fee.cap(), SwapHookLib._SWAP_FEE_CEIL);
  }
}
