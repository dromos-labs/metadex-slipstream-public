// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {FixedPoint128} from 'contracts/core/libraries/FixedPoint128.sol';
import {FullMath} from 'contracts/core/libraries/FullMath.sol';
import {SwapHookLib} from 'contracts/core/libraries/hook/SwapHookLib.sol';

import {ICLFactory} from 'contracts/core/interfaces/ICLFactory.sol';
import {IERC20Minimal} from 'contracts/core/interfaces/IERC20Minimal.sol';
import {ICLFlashCallback} from 'contracts/core/interfaces/callback/ICLFlashCallback.sol';
import {ISwapHook} from 'contracts/core/interfaces/hook/ISwapHook.sol';

import {CLPoolTest} from '../CLPool.t.sol';

contract UnitCLPoolFlash is CLPoolTest {
  address internal _swapHook = makeAddr('swapHook');
  address internal _flashBorrower = makeAddr('flashBorrower');

  uint256 internal immutable _MIN_LIQUIDITY = 1;
  uint256 internal constant _MAX_LIQUIDITY = type(uint128).max / 1e6;

  function setUp() public override {
    super.setUp();

    /// @dev Returns address of a swap hook for all {CLPool.flash} calls.
    vm.mockCall(
      clPool.factory(),
      0,
      abi.encodeWithSelector(ICLFactory.getPoolSwapHook.selector, address(clPool)),
      abi.encode(_swapHook)
    );
  }

  function test_WhenOnlyAmount0IsGtZero(
    uint24 _fee,
    uint256 _amount0,
    uint128 _stakedLiquidity,
    uint128 _liquidity
  ) external {
    _flash({
      _fee: _fee,
      _amount0: _amount0,
      _amount1: 0,
      _stakedLiquidity: _stakedLiquidity,
      _liquidity: _liquidity,
      _loan0: true,
      _loan1: false
    });
  }

  function test_WhenOnlyAmount1IsGtZero(
    uint24 _fee,
    uint256 _amount1,
    uint128 _stakedLiquidity,
    uint128 _liquidity
  ) external {
    _flash({
      _fee: _fee,
      _amount0: 0,
      _amount1: _amount1,
      _stakedLiquidity: _stakedLiquidity,
      _liquidity: _liquidity,
      _loan0: false,
      _loan1: true
    });
  }

  function test_WhenAmount0AndAmount1AreGtZero(
    uint24 _fee,
    uint256 _amount0,
    uint256 _amount1,
    uint128 _stakedLiquidity,
    uint128 _liquidity
  ) external {
    _flash({
      _fee: _fee,
      _amount0: _amount0,
      _amount1: _amount1,
      _stakedLiquidity: _stakedLiquidity,
      _liquidity: _liquidity,
      _loan0: true,
      _loan1: true
    });
  }

  /// @notice Generalized {CLPool.flash} test function that branches assertions based
  ///         on `_amount0 > 0` and `_amount1 > 0`.
  function _flash(
    uint24 _fee,
    uint256 _amount0,
    uint256 _amount1,
    uint128 _stakedLiquidity,
    uint128 _liquidity,
    bool _loan0,
    bool _loan1
  ) internal {
    _fee = uint24(bound(uint256(_fee), 0, _FEE_CEIL));

    _amount0 = _loan0 ? bound(_amount0, 1e6, type(uint256).max / FixedPoint128.Q128) : 0;
    _amount1 = _loan1 ? bound(_amount1, 1e6, type(uint256).max / FixedPoint128.Q128) : 0;

    _stakedLiquidity = uint128(bound(uint256(_stakedLiquidity), 0, _MAX_LIQUIDITY - _MIN_LIQUIDITY));
    _liquidity = uint128(bound(uint256(_liquidity), _stakedLiquidity + _MIN_LIQUIDITY, _MAX_LIQUIDITY));

    _setLiquidity(address(clPool), _liquidity);
    _setStakedLiquidity(address(clPool), _stakedLiquidity);

    // it calls swapHook.beforeFlash
    _mockAndExpectBeforeFlash(
      ISwapHook.FlashParams({
        caller: _flashBorrower, recipient: _flashBorrower, amount0: _amount0, amount1: _amount1, data: ''
      }),
      _fee
    );

    // it computes fee0 using before flash fee
    uint256 _toBeFee0 = FullMath.mulDivRoundingUp(_amount0, _fee, _DENOMINATOR);
    // it computes fee1 using before flash fee
    uint256 _toBeFee1 = FullMath.mulDivRoundingUp(_amount1, _fee, _DENOMINATOR);

    /// @dev Verify that only the desired 0/1 side is nused.
    if (!_loan0) assertEq(_toBeFee0, 0);
    if (!_loan1) assertEq(_toBeFee1, 0);

    // it calls uniswapV3FlashCallback
    _mockAndExpectFlashCallback(_flashBorrower, _toBeFee0, _toBeFee1);

    // it calls token0.transfer with amount0
    if (_loan0) _mockAndExpectTransfer(clPool.token0(), _flashBorrower, _amount0);

    // it calls token1.transfer with amount1
    if (_loan1) _mockAndExpectTransfer(clPool.token1(), _flashBorrower, _amount1);

    // bypass balance checks.
    uint256[] memory _balances = new uint256[](2);
    _balances[0] = _amount0; // what we loan
    _balances[1] = _amount0 + _toBeFee0;
    _mockAndExpectBalanceOfCalls(clPool.token0(), address(clPool), _balances);

    _balances[0] = _amount1; // what we loan
    _balances[1] = _amount1 + _toBeFee1;
    _mockAndExpectBalanceOfCalls(clPool.token1(), address(clPool), _balances);

    // it emits Flash
    emit Flash(_flashBorrower, _flashBorrower, _amount0, 0, _toBeFee0, 0);

    vm.prank(_flashBorrower);
    clPool.flash(_flashBorrower, _amount0, _amount1, '');

    (uint256 _feeGrowthGlobal0X128, uint256 _stakedFeeAmount0) = _calculateFees(_toBeFee0, _liquidity, _stakedLiquidity);
    (uint256 _feeGrowthGlobal1X128, uint256 _stakedFeeAmount1) = _calculateFees(_toBeFee1, _liquidity, _stakedLiquidity);

    // it adds part of paid0 to feeGrowthGlobal0X128
    if (!_loan0) assertEq(_feeGrowthGlobal0X128, 0); // double-check
    assertEq(clPool.feeGrowthGlobal0X128(), _feeGrowthGlobal0X128);

    // it adds part of paid1 to feeGrowthGlobal1X128
    if (!_loan1) assertEq(_feeGrowthGlobal1X128, 0);
    assertEq(clPool.feeGrowthGlobal1X128(), _feeGrowthGlobal1X128);

    (uint128 _token0, uint128 _token1) = clPool.gaugeFees();

    // it adds part of paid0 to gaugeFees.token0
    if (!_loan0) assertEq(uint256(_token0), 0);
    assertEq(uint256(_token0), _stakedFeeAmount0);

    // it adds part of paid1 to gaugeFees.token1
    if (!_loan1) assertEq(uint256(_token1), 0);
    assertEq(uint256(_token1), _stakedFeeAmount1);
  }

  /*////////////////////////////////////////////////////////////
                          MOCK HELPERS
  ////////////////////////////////////////////////////////////*/

  function _mockAndExpectBeforeFlash(ISwapHook.FlashParams memory _flashParams, uint24 _fee) internal {
    bytes memory _data = abi.encodeWithSelector(ISwapHook.beforeFlash.selector, _flashParams);

    vm.mockCall(_swapHook, 0, _data, abi.encode(_fee));
    vm.expectCall(_swapHook, _data);
  }

  function _mockAndExpectFlashCallback(address _msgSender, uint256 _amount0, uint256 _amount1) internal {
    bytes memory _data =
      abi.encodeWithSelector(ICLFlashCallback.uniswapV3FlashCallback.selector, _amount0, _amount1, '');

    vm.mockCall(_msgSender, _data, '');
    vm.expectCall(_msgSender, _data);
  }

  function _mockAndExpectTransfer(address _token, address _user, uint256 _amount) internal {
    bytes memory _data = abi.encodeWithSelector(IERC20Minimal.transfer.selector, _user, _amount);

    vm.mockCall(_token, _data, abi.encode(_amount));
    vm.expectCall(_token, _data);
  }

  function _mockAndExpectBalanceOfCalls(address _token, address _user, uint256[] memory _retBalances) internal {
    bytes memory _data = abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, _user);
    bytes[] memory _mocks = new bytes[](_retBalances.length);

    for (uint256 _i = 0; _i < _retBalances.length; ++_i) {
      _mocks[_i] = abi.encode(_retBalances[_i]);
    }

    vm.mockCalls(_token, _data, _mocks);
    vm.expectCall(_token, _data);
  }
}
